#!/usr/bin/env python3
"""Fail releases whose PostgreSQL extension migration graph is incomplete."""

from __future__ import annotations

import re
import sys
import tomllib
from collections import defaultdict, deque
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
EXTENSION = "pg_ledger"
BASELINE = "0.1.0"


def fail(message: str) -> None:
    print(f"upgrade-path check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def reachable(graph: dict[str, set[str]], start: str, target: str) -> bool:
    queue = deque([start])
    visited = {start}
    while queue:
        version = queue.popleft()
        if version == target:
            return True
        for next_version in graph.get(version, set()):
            if next_version not in visited:
                visited.add(next_version)
                queue.append(next_version)
    return False


with (ROOT / "Cargo.toml").open("rb") as cargo_file:
    cargo_version = tomllib.load(cargo_file)["package"]["version"]

control_text = (ROOT / f"{EXTENSION}.control").read_text(encoding="utf-8")
control_match = re.search(r"^default_version\s*=\s*'([^']+)'\s*$", control_text, re.MULTILINE)
if not control_match:
    fail("pg_ledger.control has no default_version")
control_version = control_match.group(1)
if cargo_version != control_version:
    fail(f"Cargo version {cargo_version} differs from control version {control_version}")

release_versions = [
    line.strip()
    for line in (ROOT / "ci" / "extension-versions.txt").read_text(encoding="utf-8").splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
if not release_versions or release_versions[0] != BASELINE:
    fail(f"release ledger must begin with {BASELINE}")
if len(release_versions) != len(set(release_versions)):
    fail("release ledger contains duplicate versions")
if release_versions[-1] != cargo_version:
    fail(f"append current version {cargo_version} to ci/extension-versions.txt")

script_pattern = re.compile(rf"^{EXTENSION}--(.+)--(.+)\.sql$")
graph: dict[str, set[str]] = defaultdict(set)
for script in sorted((ROOT / "sql").glob(f"{EXTENSION}--*--*.sql")):
    match = script_pattern.match(script.name)
    if not match:
        fail(f"invalid migration filename {script.name}")
    source, target = match.groups()
    body = script.read_text(encoding="utf-8")
    if not body.strip():
        fail(f"migration {script.name} is empty")
    if re.search(r"^\s*(BEGIN|COMMIT|ROLLBACK)\s*;", body, re.IGNORECASE | re.MULTILINE):
        fail(f"migration {script.name} contains transaction control")
    graph[source].add(target)

for old_version in release_versions[:-1]:
    if not reachable(graph, old_version, cargo_version):
        fail(f"no migration path from {old_version} to {cargo_version}")

for previous, current in zip(release_versions[:-1], release_versions[1:], strict=True):
    if current not in graph.get(previous, set()):
        fail(f"missing consecutive migration {EXTENSION}--{previous}--{current}.sql")

print(f"upgrade path OK: {cargo_version} ({len(release_versions)} recorded release(s))")
