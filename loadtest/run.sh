#!/usr/bin/env bash
# Runs the scenario x clients matrix and stores everything under results/<label>/.
#
#   ./run.sh <label> [--apply tuning/file.sql ...] [--db some_copy] [--prepare file.sql]
#
# It runs the built-in metric scenarios from config.sh. A workload captured by pglab is replayed by
# pglab's replay.py (https://github.com/constantine2nd/postgresql-lab), which refuses any database pglab did not create.
#
# Before each scenario $TEST_DB is re-cloned from $BASE_DB (so every scenario starts from identical data),
# then the --apply files are run on it; --db <name> uses that database as it is instead of cloning.
# Server settings (shared_buffers, ...) are recorded, not changed.
# Quick smoke test:  DURATION=20 WARMUP=5 CLIENTS="4" ./run.sh smoke
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

label=${1:-}; [[ $label =~ ^[A-Za-z0-9_.-]+$ ]] || die "usage: ./run.sh <label> [--apply tuning/file.sql ...]"
shift
applies=()
target_db="" ; prepare=""
while (($#)); do
  case $1 in
    --apply) [[ -f ${2:-} ]] || die "--apply needs an existing .sql file"; applies+=("$(readlink -f "$2")"); shift 2 ;;
    --workload) die "--workload moved to pglab (https://github.com/constantine2nd/postgresql-lab): pglab/replay.py <label> --workload DIR --db <playground>" ;;
    --db) target_db=${2:?--db needs a database name}; shift 2 ;;
    --prepare) [[ -f ${2:-} ]] || die "--prepare needs an existing .sql file"; prepare="$(readlink -f "$2")"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

: "${STAT_TABLES:="'metric', 'metricarchive'"}"

if [[ -n $target_db ]]; then
  db_exists "$target_db" || die "$target_db does not exist"
  TEST_DB="$target_db"
else
  db_exists "$BASE_DB" || die "$BASE_DB does not exist, run ./01_build_base.sh first"
fi
run_ts=$(date +%Y-%m-%d_%H%M%S)
out="$LT_DIR/results/${run_ts}__${label}"          # timestamped, so runs never overwrite each other
[[ -e $out ]] && die "$out already exists"
if [[ -z $target_db ]]; then
  base_gb=$(db_size_gb "$BASE_DB")
  (( $(free_gb) >= base_gb + 5 )) || die "need $((base_gb + 5)) GB free for the test clone, have $(free_gb) GB"
else
  base_gb=$(db_size_gb "$TEST_DB")
fi

mkdir -p "$out"
{
  echo "label: $label   started: $(date '+%F %T')   database: ${target_db:-$BASE_DB -> $TEST_DB} ($base_gb GB)"
  echo "scenarios: $SCENARIOS   clients: $CLIENTS   duration: ${DURATION}s   warmup: ${WARMUP}s"
  echo "applied: ${applies[*]:-(none)}"
  echo
  psql -X -d postgres -P footer=off -c "SELECT name, setting, unit FROM pg_settings WHERE name IN
    ('shared_buffers','work_mem','effective_cache_size','random_page_cost','maintenance_work_mem','max_wal_size',
     'synchronous_commit','checkpoint_timeout','autovacuum_vacuum_scale_factor','autovacuum_vacuum_cost_limit',
     'track_io_timing','max_parallel_workers_per_gather','jit') ORDER BY name"
} > "$out/run_info.txt"
for f in "${applies[@]}"; do cp "$f" "$out/"; done

fresh_clone() {
  if [[ -z $target_db ]]; then
    dropdb --if-exists "$TEST_DB"
    createdb -T "$BASE_DB" "$TEST_DB" || die "clone failed (is someone, e.g. DBeaver, connected to $BASE_DB?)"
  fi
  for f in "${applies[@]}"; do q -d "$TEST_DB" -f "$f"; done
  [[ -n $prepare ]] && q -d "$TEST_DB" -f "$prepare" > /dev/null
}

# -D variables the scripts need: the pools and time spans the built-in metric scenarios refer to.
pgbench_vars() {
  psql -X -d "$TEST_DB" -tA <<SQL
SELECT string_agg(v, ' ') FROM (
  SELECT '-D n_' || kind || '=' || count(*) AS v FROM lt_values GROUP BY kind
  UNION ALL SELECT '-D n_tpl_metric=' || count(*) FROM lt_tpl_metric
  UNION ALL SELECT '-D max_metric_id=' || last_value FROM metric_id_seq
) x;
SQL
  echo "-D metric_days=$METRIC_DAYS -D archive_days=$ARCHIVE_DAYS -D keep_days=$KEEP_DAYS" \
       "-D archive_batch=$ARCHIVE_BATCH -D expire_days=$EXPIRE_DAYS -D expire_batch=$EXPIRE_BATCH"
}

capture_stats() {
  local dir=$1
  if [[ $(psql -X -d "$TEST_DB" -tAc "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'") == 0 ]]; then
    echo "pg_stat_statements is not installed in $TEST_DB: no per-statement figures for this run" \
      > "$dir/statements.txt"
  else
  q -d "$TEST_DB" -P footer=off > "$dir/statements.txt" <<'SQL'
SELECT calls, round(total_exec_time::numeric, 1) AS total_ms, round(mean_exec_time::numeric, 3) AS mean_ms,
       round(max_exec_time::numeric, 1) AS max_ms, rows, shared_blks_hit AS cache_blks,
       shared_blks_read AS disk_blks, round(blk_read_time::numeric, 1) AS read_ms, temp_blks_written AS temp_blks,
       left(regexp_replace(query, '\s+', ' ', 'g'), 120) AS query
  FROM pg_stat_statements
 WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
 ORDER BY total_exec_time DESC LIMIT 25;
SQL
  fi
  q -d "$TEST_DB" -P footer=off > "$dir/tables.txt" <<SQL
SELECT relname, seq_scan, seq_tup_read, idx_scan, n_tup_ins AS ins, n_tup_del AS del,
       (SELECT reltuples::bigint FROM pg_class WHERE oid = relid) AS est_rows, n_dead_tup AS dead, autovacuum_count AS autovac, autoanalyze_count AS autoanalyze,
       pg_size_pretty(pg_table_size(relid)) AS data, pg_size_pretty(pg_indexes_size(relid)) AS indexes
  FROM pg_stat_user_tables WHERE relname IN ($STAT_TABLES) ORDER BY relname;
SELECT relname, indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
  FROM pg_stat_user_indexes WHERE relname IN ($STAT_TABLES) ORDER BY relname, idx_scan DESC;
SQL
}

started_all=$(date +%s)
echo "Results: $out"
for scen in $SCENARIOS; do
  [[ -n ${SCENARIO_SCRIPTS[$scen]:-} ]] || die "unknown scenario '$scen' (see config.sh)"
  echo "== $scen: cloning $BASE_DB -> $TEST_DB"
  fresh_clone
  files=(); for s in ${SCENARIO_SCRIPTS[$scen]}; do files+=(-f "$LT_DIR/workloads/$s"); done
  read -ra vars <<< "$(pgbench_vars | tr '\n' ' ')"
  pgb=(pgbench -n -M prepared "${vars[@]}" "$TEST_DB")

  if (( WARMUP > 0 )); then
    echo "   warmup ${WARMUP}s"
    "${pgb[@]}" -c 4 -j 4 -T "$WARMUP" "${files[@]}" > /dev/null 2>&1
  fi

  for c in $CLIENTS; do
    dir="$out/${scen}_c$c"; mkdir -p "$dir"
    q -d "$TEST_DB" -c "SELECT pg_stat_reset()" -c "CHECKPOINT" > /dev/null
    # pg_stat_statements may not be installed in the database under test (a scratch copy, say)
    q -d "$TEST_DB" -c "DO \$\$ BEGIN
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
          PERFORM pg_stat_statements_reset(0, (SELECT oid FROM pg_database WHERE datname = current_database()), 0);
        END IF; END \$\$" > /dev/null

    bg=""
    if [[ $scen == mixed ]]; then
      "${pgb[@]}" -c 1 -j 1 -T "$DURATION" -R "$ARCHIVE_RATE" -f "$LT_DIR/workloads/job_archive_batch.sql" \
        > "$dir/archive_job.txt" 2>&1 &
      bg=$!
    fi

    run_started=$(date +%s)
    printf '   %-16s %3s clients, %ss ... ' "$scen" "$c" "$DURATION"
    "${pgb[@]}" -c "$c" -j $(( c < 8 ? c : 8 )) -T "$DURATION" -P 10 -r \
      --log --sampling-rate="$SAMPLE_RATE" --log-prefix="$dir/txlog" "${files[@]}" \
      > "$dir/pgbench.txt" 2> "$dir/progress.txt" \
      || { echo "FAILED"; tail -5 "$dir/progress.txt" >&2; exit 1; }
    [[ -n $bg ]] && wait "$bg"

    run_finished=$(date +%s)
    { echo "started:  $(date -d @$run_started '+%F %T')"
      echo "finished: $(date -d @$run_finished '+%F %T')"
      echo "elapsed:  $((run_finished - run_started)) s (${DURATION}s measured + warm-up, statistics and clean-up)"
    } > "$dir/timing.txt"
    capture_stats "$dir"
    python3 "$LT_DIR/summarize.py" "$dir" "$scen" "$c"
    rm -f "$dir"/txlog*
  done
done
[[ -z $target_db ]] && dropdb --if-exists "$TEST_DB"
{ echo; echo "finished: $(date '+%F %T')   total: $(( $(date +%s) - started_all )) s"; } >> "$out/run_info.txt"
echo "Results: $out"

echo
python3 "$LT_DIR/compare.py" "$(basename "$out")"
