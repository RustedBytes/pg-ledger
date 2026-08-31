#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/pg_config" >&2
    exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pg_config="$1"
pg_bindir="$($pg_config --bindir)"
pg_major="$($pg_config --version | sed -n 's/.* \([0-9][0-9]*\).*/\1/p')"
test_port="$((55400 + pg_major))"
test_root="$(mktemp -d "/tmp/pg-ledger-pg${pg_major}.XXXXXX")"

cleanup() {
    "$pg_bindir/pg_ctl" -D "$test_root/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$test_root"
}
trap cleanup EXIT

cd "$project_dir"
cargo pgrx install --pg-config "$pg_config" --no-default-features --features "pg${pg_major}"
"$pg_bindir/initdb" -D "$test_root/data" --no-locale --encoding=UTF8 >/dev/null
"$pg_bindir/pg_ctl" -D "$test_root/data" -o "-F -p $test_port -k $test_root" -w start >/dev/null
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_ledger_test
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_ledger_test -f "$project_dir/ci/smoke.sql"
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_ledger_test -f "$project_dir/ci/fixtures/legacy-idempotency.sql"
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_ledger_test -f "$project_dir/ci/failure-injection.sql"

ledger_bench_clients="${PG_LEDGER_BENCH_CLIENTS:-8}"
ledger_bench_jobs="${PG_LEDGER_BENCH_JOBS:-4}"
if [[ ! "$ledger_bench_clients" =~ ^[1-9][0-9]*$ || ! "$ledger_bench_jobs" =~ ^[1-9][0-9]*$ ]]; then
    echo "PG_LEDGER_BENCH_CLIENTS and PG_LEDGER_BENCH_JOBS must be positive integers" >&2
    exit 2
fi
ledger_bench_run=(-t 50)
if [[ -n "${PG_LEDGER_BENCH_DURATION:-}" ]]; then
    if [[ ! "$PG_LEDGER_BENCH_DURATION" =~ ^[1-9][0-9]*$ ]]; then
        echo "PG_LEDGER_BENCH_DURATION must be a positive integer number of seconds" >&2
        exit 2
    fi
    ledger_bench_run=(-T "$PG_LEDGER_BENCH_DURATION" -P 30)
fi
ledger_pgbench_output="$("$pg_bindir/pgbench" -n \
    -h "$test_root" -p "$test_port" -d pg_ledger_test \
    -c "$ledger_bench_clients" -j "$ledger_bench_jobs" "${ledger_bench_run[@]}" \
    -f "$project_dir/ci/concurrency.sql" 2>&1)"
printf '%s\n' "$ledger_pgbench_output" | tail -n 12

"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_ledger_test -f "$project_dir/ci/races-setup.sql"
for ledger_race_script in \
    race-idempotency-matching.sql \
    race-idempotency-conflicting.sql \
    race-reversal.sql
do
    "$pg_bindir/pgbench" -n \
        -h "$test_root" -p "$test_port" -d pg_ledger_test \
        -c 16 -j 4 -t 20 -f "$project_dir/ci/$ledger_race_script"
done
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_ledger_test -f "$project_dir/ci/races-verify.sql"
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_ledger_test -c \
    "DO \$\$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM ledger_validate() WHERE status <> 'OK'); END \$\$;"
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_ledger_schema_test
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_ledger_schema_test -f "$project_dir/ci/custom-schema.sql"
