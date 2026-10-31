#!/usr/bin/env bash
# Drops obp_showcase (REPORT.md and results/ are kept). Usage: ./99_cleanup.sh --yes
set -euo pipefail
[[ ${1:-} == --yes ]] || { echo "this drops ${SHOWCASE_DB:-obp_showcase}; run with --yes" >&2; exit 1; }
dropdb --if-exists "${SHOWCASE_DB:-obp_showcase}"
