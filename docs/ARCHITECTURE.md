# Architecture

PostgreSQL owns tables, constraints, row locks, transactions, permissions,
indexes, and views. Rust/pgrx owns the binary asset, amount, and posting types,
exact smallest-unit arithmetic, comparisons, parsing, UUIDv7 generation,
versioned SHA-256 request fingerprints, posting orchestration, idempotency decisions,
reversal construction, and integrity-check orchestration.

The public SQL functions are thin, schema-pinned `SECURITY DEFINER` boundaries.
They call one internal Rust balance mutation engine. That engine validates
per-asset zero sums, establishes idempotency, sorts and locks every affected
account through PostgreSQL SPI, checks asset and final balance-policy
compatibility, updates cached balances and versions, and inserts immutable
entries in the caller's PostgreSQL transaction. Transfers and reversals route
through the same Rust engine.

A transaction may contain repeated postings for one account. They remain
separate journal entries with contiguous account versions, while balance-policy
validation is applied to the transaction's final net effect on that account.

The journal entry stream is the accounting source of truth. Cached account
balances are deliberately redundant for fast reads, and `ledger_validate()`
checks that redundancy plus the version and balance chains.
