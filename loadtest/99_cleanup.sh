#!/usr/bin/env bash
# Drops the load test databases (results/ is kept). Usage: ./99_cleanup.sh --yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
[[ ${1:-} == --yes ]] || die "this drops $TEST_DB and $BASE_DB; run with --yes to confirm"
dropdb --if-exists "$TEST_DB"
dropdb --if-exists "$BASE_DB"
echo "Dropped $TEST_DB and $BASE_DB. $(free_gb) GB free."
