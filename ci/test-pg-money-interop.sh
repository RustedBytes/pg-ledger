#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/pg_config" >&2
    exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pg_config="$1"
pg_bindir="$($pg_config --bindir)"
pg_sharedir="$($pg_config --sharedir)"
pg_major="$($pg_config --version | sed -n 's/.* \([0-9][0-9]*\).*/\1/p')"
test_port="$((55600 + pg_major))"
test_root="$(mktemp -d "/tmp/pg-ledger-money-pg${pg_major}.XXXXXX")"
fixture_control="$pg_sharedir/extension/pg_money.control"
fixture_sql="$pg_sharedir/extension/pg_money--0.0.1.sql"
installed_fixture=false

cleanup() {
    "$pg_bindir/pg_ctl" -D "$test_root/data" -m immediate stop >/dev/null 2>&1 || true
    if [[ "$installed_fixture" == true ]]; then
        rm -f "$fixture_control" "$fixture_sql"
    fi
    rm -rf "$test_root"
}
trap cleanup EXIT

if [[ ! -e "$fixture_control" ]]; then
    cp "$project_dir/ci/fixtures/pg_money.control" "$fixture_control"
    installed_fixture=true
    cp "$project_dir/ci/fixtures/pg_money--0.0.1.sql" "$fixture_sql"
fi

"$pg_bindir/initdb" -D "$test_root/data" --no-locale --encoding=UTF8 >/dev/null
"$pg_bindir/pg_ctl" -D "$test_root/data" -o "-F -p $test_port -k $test_root" -w start >/dev/null
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_ledger_money
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_ledger_money -f "$project_dir/ci/pg-money-interop.sql"
