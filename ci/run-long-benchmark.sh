#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
    echo "usage: $0 /path/to/pg_config [duration-seconds] [clients]" >&2
    exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PG_LEDGER_BENCH_DURATION="${2:-180}"
export PG_LEDGER_BENCH_CLIENTS="${3:-32}"
export PG_LEDGER_BENCH_JOBS="${PG_LEDGER_BENCH_JOBS:-8}"

exec "$project_dir/ci/test-extension.sh" "$1"
