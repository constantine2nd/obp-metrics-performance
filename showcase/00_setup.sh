#!/usr/bin/env bash
# Creates obp_showcase as a copy of the load-test base (5M metric + 15M metricarchive rows).
# Demos add and drop their own indexes there; obp_loadtest_base and obp_mapped are not touched.
set -euo pipefail
SRC=${SRC_DB:-obp_loadtest_base}
DB=${SHOWCASE_DB:-obp_showcase}
if [[ $(psql -X -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB'") == 1 ]]; then
  [[ ${1:-} == --force ]] || { echo "$DB already exists (--force to recreate)" >&2; exit 1; }
  dropdb "$DB"
fi
createdb -T "$SRC" "$DB" || { echo "clone failed: is someone (e.g. DBeaver) connected to $SRC?" >&2; exit 1; }
psql -X -q -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm" -c "CREATE EXTENSION IF NOT EXISTS pg_buffercache"
echo "Created $DB ($(psql -X -d postgres -tAc "SELECT pg_size_pretty(pg_database_size('$DB'))")). Next: ./showcase.py"
