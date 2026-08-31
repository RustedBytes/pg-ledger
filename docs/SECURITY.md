# Security model

Journal integrity depends on using the public API rather than granting direct
write privileges to ledger tables.

The extension revokes public mutation of `ledger_entries` and
`ledger_transactions`, and revokes direct account creation, deletion, balance,
version, asset, and timestamp mutation. Public mutation entry points are
`SECURITY DEFINER` functions with the extension schema and `pg_catalog` pinned
in `search_path`. The internal `_ledger_post`, `_ledger_post_rust`,
`_ledger_transfer_rust`, and `_ledger_reverse_rust` functions are not
executable by `PUBLIC`.

The tables remain readable by `PUBLIC` so applications can build statements and
reconciliation queries. Revoke those grants after installation if ledger
visibility should be restricted:

```sql
REVOKE SELECT ON ledger_accounts, ledger_transactions, ledger_entries FROM PUBLIC;
GRANT SELECT ON ledger_accounts, ledger_transactions, ledger_entries TO ledger_reader;
```

PostgreSQL owners and superusers can bypass ordinary table privileges. Use a
dedicated extension-owner role that application sessions cannot assume. Do not
grant application roles direct table mutation or execution on any internal
underscore-prefixed mutation function.

Entries and transactions also have rejecting update/delete triggers as defense
in depth. Corrections must use `ledger_reverse`.

Idempotency fingerprints use SHA-256 over sorted canonical posting data plus
the request metadata fields. They protect retry semantics, not authorization.
Idempotency keys should be scoped to the upstream event identity and must not
contain secrets.

The extension never performs network access, price discovery, or currency
conversion. FX prices belong in application logic and transaction metadata;
the ledger only verifies exact per-asset balance.
