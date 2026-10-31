#!/usr/bin/env bash
# Builds $BASE_DB: the metric tables copied from $SRC_DB and scaled to N_METRIC / N_ARCHIVE rows.
# The source database is only read. Usage: ./01_build_base.sh [--force]   (--force rebuilds)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

if db_exists "$BASE_DB"; then
  [[ ${1:-} == --force ]] || die "$BASE_DB already exists (use --force to drop and rebuild it)"
  dropdb "$BASE_DB"
fi

# ~450 bytes per row including indexes, plus WAL headroom.
need_gb=$(( (N_METRIC + N_ARCHIVE) * 450 / 1024**3 + 3 ))
(( $(free_gb) >= need_gb )) || die "need about ${need_gb} GB free on $PGDATA_MOUNT, have $(free_gb) GB"

echo "Building $BASE_DB: $N_METRIC metric + $N_ARCHIVE metricarchive rows (needs ~${need_gb} GB, $(free_gb) GB free)"
createdb "$BASE_DB"

tables=(metric metric_id_seq metricarchive metricarchive_id_seq metricsarchiverun metricsarchiverun_id_seq)
pg_dump --no-owner --no-privileges "${tables[@]/#/--table=public.}" "$SRC_DB" | q -d "$BASE_DB" >/dev/null
echo "Copied tables from $SRC_DB"
q -d "$BASE_DB" -f "$LT_DIR/anonymize.sql"
echo "Pseudonymized identifiers (consumers, users, e-mails, UUIDs in URLs, ...)"

PGOPTIONS="-c lt.n_metric=$N_METRIC -c lt.n_archive=$N_ARCHIVE -c lt.metric_days=$METRIC_DAYS -c lt.archive_days=$ARCHIVE_DAYS" \
  q -d "$BASE_DB" -f "$LT_DIR/generate.sql"

echo "Done: $BASE_DB is $(db_size_gb "$BASE_DB") GB, $(free_gb) GB free. Next: ./run.sh baseline"
