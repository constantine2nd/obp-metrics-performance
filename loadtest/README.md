# metric / metricarchive load test

Load test for the OBP metric tables, run against a generated copy. `obp_mapped` is only read.

| Database | Contents |
|---|---|
| `obp_loadtest_base` | Copy of `metric`, `metricarchive`, `metricsarchiverun`, pseudonymized (`anonymize.sql`) and scaled to 5M + 15M rows. Built once, never modified by test runs. |
| `obp_loadtest` | Cloned fresh from the base before every scenario, dropped at the end of a run. |

## Steps

```bash
./01_build_base.sh                       # once (~7 GB); --force to rebuild
./run.sh baseline                        # full matrix, ~70 min
./run.sh no_dup_idx --apply tuning/01_drop_duplicate_indexes.sql
./compare.py baseline no_dup_idx         # add --scripts for per-query-type latency
./99_cleanup.sh --yes                    # drop both databases (results/ is kept)
```

Quick check: `DURATION=20 WARMUP=5 CLIENTS="4" ./run.sh smoke`.

## Any other table: a workload captured by pglab

That lives in [pglab](https://github.com/constantine2nd/postgresql-lab), whose `replay.py` replays
a captured workload with the same pgbench settings and writes the same folder layout, but only
against a database pglab created. `./run.sh --workload` says so and stops. `compare.py` and
`summarize.py` here are copies of pglab's, reading `results/` only.

## Other flags

| Flag | Means |
|---|---|
| `--db NAME` | use that database as it is, instead of cloning `$BASE_DB` into `$TEST_DB` |
| `--prepare FILE` | run this before each scenario |
| `--apply FILE` | the change under test, applied after the clone/prepare |

To test a server setting (e.g. `shared_buffers`), change it with `ALTER SYSTEM`, restart PostgreSQL,
then run with a new label. `run_info.txt` records the settings of every run.

## Scenarios (config.sh)

| Scenario | Mix |
|---|---|
| `read` | metrics list (40%), aggregates, top APIs, top consumers, correlation id lookup, archive search |
| `write` | inserts only, one metric row per API call |
| `mixed` | 70% inserts + reads, while a background job archives 1,000 rows/s and expires old archive rows |
| `archive_rowwise` | Not in the default set. Tests the hypothesis that OBP archives row by row with an unindexed `metricid` check. |

Each scenario runs at 1, 4, 8 and 16 clients for 5 minutes. Everything can be overridden via env,
e.g. `SCENARIOS="read" CLIENTS="8 16" DURATION=120`.

## Results: `results/<timestamp>__<label>/<scenario>_c<clients>/`

Every run gets its own timestamped folder, so nothing is ever overwritten and runs of the same label
can be repeated. `compare.py` and `report.py` accept either the folder name or just the label, in
which case the newest run with that label is used. Each run folder carries `run_info.txt` (settings,
start, finish, total) and each measurement carries `timing.txt` (started, finished, elapsed).

`report.py` writes `REPORT.html` / `REPORT.md` as the latest, and keeps a dated copy of both under
`reports/`.

### Inside a run folder

- `summary.json`: tps and p50/p95/p99 latency, overall and per script (used by `compare.py`)
- `pgbench.txt`: pgbench report including per-statement latency (`-r`)
- `progress.txt`: tps and latency every 10 s, which shows stalls such as checkpoints or autovacuum
- `statements.txt`: top 25 statements from pg_stat_statements
- `tables.txt`: seq vs index scans, inserts/deletes, dead rows, autovacuum runs, index usage and sizes
- `archive_job.txt`: background archive job report (mixed only)

The workload queries are modelled on what OBP does with these tables, not captured from the application.
