# Shared settings for the metric load test. Every value can be overridden from the environment,
# e.g.  N_METRIC=50000 N_ARCHIVE=150000 ./01_build_base.sh

SRC_DB=${SRC_DB:-obp_mapped}            # real data, only read (pg_dump of the metric tables)
BASE_DB=${BASE_DB:-obp_loadtest_base}   # generated once, never modified by test runs
TEST_DB=${TEST_DB:-obp_loadtest}        # re-cloned from BASE_DB before every scenario

# Data volume and time spans (metric = last METRIC_DAYS, metricarchive = the ARCHIVE_DAYS before that)
N_METRIC=${N_METRIC:-5000000}
N_ARCHIVE=${N_ARCHIVE:-15000000}
METRIC_DAYS=${METRIC_DAYS:-365}
ARCHIVE_DAYS=${ARCHIVE_DAYS:-1095}

# Test matrix
SCENARIOS=${SCENARIOS:-"read write mixed"}
CLIENTS=${CLIENTS:-"1 4 8 16"}
DURATION=${DURATION:-300}               # seconds per run
WARMUP=${WARMUP:-30}                    # seconds, once per scenario, not recorded
SAMPLE_RATE=${SAMPLE_RATE:-0.1}         # share of transactions logged for latency percentiles

# Background archive job in the "mixed" scenario (batches per second x rows per batch)
ARCHIVE_RATE=${ARCHIVE_RATE:-2}
ARCHIVE_BATCH=${ARCHIVE_BATCH:-500}
KEEP_DAYS=${KEEP_DAYS:-270}             # metric rows older than this are moved to metricarchive
EXPIRE_DAYS=${EXPIRE_DAYS:-1440}        # metricarchive rows older than this are deleted
EXPIRE_BATCH=${EXPIRE_BATCH:-100}

# Workload mix per scenario: script@weight (pgbench picks a script per transaction by weight)
declare -A SCENARIO_SCRIPTS=(
  [read]="r_list.sql@40 r_aggregate.sql@15 r_top_apis.sql@10 r_top_consumers.sql@10 r_lookup.sql@15 r_archive_search.sql@10"
  [write]="w_insert.sql@100"
  [mixed]="w_insert.sql@70 r_list.sql@12 r_aggregate.sql@4 r_top_apis.sql@3 r_top_consumers.sql@3 r_lookup.sql@5 r_archive_search.sql@3"
  [archive_rowwise]="job_archive_rowwise.sql@100"
)

LT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PGDATA_MOUNT=/var/lib/postgresql

q()  { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
die() { echo "error: $*" >&2; exit 1; }
db_exists() { [[ $(psql -X -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$1'") == 1 ]]; }
free_gb() { df -B1G --output=avail "$PGDATA_MOUNT" | tail -1 | tr -d ' '; }
db_size_gb() { psql -X -d postgres -tAc "SELECT ceil(pg_database_size('$1') / 1024.0^3)"; }
