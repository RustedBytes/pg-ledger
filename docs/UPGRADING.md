# Extension upgrades

`0.1.0` is the migration baseline. No version newer than `0.1.0` may be
released until its PostgreSQL extension update script and replay tests are in
the repository.

## Release policy

For every release, append the version to `ci/extension-versions.txt` and add a
consecutive script named:

```text
sql/pg_ledger--<previous>--<new>.sql
```

Keep every historical script. PostgreSQL selects an update path from the
installed version to `pg_ledger.control`'s `default_version`; removing an old
edge strands databases on that version. `ci/check-upgrade-path.py` verifies
that the Cargo version, control version, release ledger, and migration graph
agree.

Update scripts run inside `ALTER EXTENSION`, so they must not contain
`BEGIN`, `COMMIT`, or `ROLLBACK`. Prefer additive DDL, backfill in bounded and
restartable steps where practical, then add constraints. A destructive or
rewriting migration needs an explicit operator note with its lock level,
estimated duration, disk headroom, and rollback/restore procedure.

The extension currently uses an unversioned `module_pathname`. Rust entry-point
ABIs must therefore remain compatible for an in-place update, and PostgreSQL
sessions opened before `ALTER EXTENSION` should be drained or restarted before
serving traffic with the new version.

## Compatibility invariants

- Never change an existing binary encoding version for `ledger_asset`,
  `ledger_amount`, or `ledger_posting`. Add a new reader/writer version and
  migrate stored values deliberately.
- Never reinterpret an existing idempotency fingerprint. New writes may use a
  new prefixed format, but replay must continue accepting every historical
  format. The fixed legacy fixture is a release gate.
- Do not rewrite immutable journal history merely to fit a new schema. Derived
  columns or indexes should be rebuilt from entries while preserving account
  versions, transaction IDs, and reversal links.
- Run `ledger_validate()` before and after every update.

## Required release rehearsal

1. Build and install the previous tagged extension into a fresh database.
2. Load the fixed legacy fixture and a representative production-shaped data
   set, including idempotency keys and reversals.
3. Install the new package files and run `ALTER EXTENSION pg_ledger UPDATE TO
   '<new>';`.
4. Confirm `pg_extension.extversion`, replay old and current idempotency keys,
   race a reversal, and require every `ledger_validate()` row to be `OK`.
5. Exercise the update from every version listed in
   `ci/extension-versions.txt`, not only the immediately previous release.

If any rehearsal cannot update in one transaction within the stated operator
window, stop the release and publish a staged migration plan first.
