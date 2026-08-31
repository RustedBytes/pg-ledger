# pg_ledger

`pg_ledger` is an asset-aware, exact, double-entry ledger for PostgreSQL. Its
fundamental operation is an N-posting journal transaction, so transfers, fees,
foreign exchange, and reversals all use the same posting engine.

The extension supports PostgreSQL 14–18, Rust 1.96+, and pgrx 0.19.2.

## Why this model

- Every transaction balances independently for every asset.
- Amounts use signed arbitrary-precision integer smallest units, not floating
  point or unconstrained `numeric` ledger balances.
- A transaction can contain any number of accounts and assets.
- Repeated lines for one account remain distinct entries; policies apply to the
  transaction's final net effect.
- A deterministic, sorted `FOR UPDATE` lock prevents account-order deadlocks.
- Cached balances and versions are updated atomically while immutable entries
  retain each previous and current balance.
- Idempotency keys include a SHA-256 payload fingerprint, so a matching replay
  returns the original transaction and a conflicting replay fails.
- Corrections are explicit reversal transactions; journal rows are never edited.

## Build and install

```bash
cargo install cargo-pgrx --version 0.19.2 --locked
cargo pgrx init --pg18=/path/to/pg_config
./install.sh --pg-config /path/to/pg_config
```

Install the packaged files into PostgreSQL's configured directories, then:

```sql
CREATE EXTENSION pg_ledger;
```

The extension is non-relocatable after installation because its
`SECURITY DEFINER` entry points pin a safe schema-qualified search path. It can
still be installed initially into a chosen schema:

```sql
CREATE SCHEMA accounting;
CREATE EXTENSION pg_ledger SCHEMA accounting;
```

## Quick start

```sql
SELECT ledger_create_account('treasury:usd', 'USD', 'ANY') AS treasury \gset
SELECT ledger_create_account('customer:usd', 'USD', 'NON_NEGATIVE') AS customer \gset

SELECT ledger_post(
    ARRAY[
        ledger_posting(:'treasury'::uuid, '-1000 USD'),
        ledger_posting(:'customer'::uuid,  '1000 USD')
    ],
    reference => 'deposit:123',
    idempotency_key => 'bank:event:88342',
    metadata => '{"provider":"bank"}'
);
```

An FX journal balances both assets inside one transaction:

```sql
SELECT ledger_post(ARRAY[
    ledger_posting(customer_usd,  '-100 USD'),
    ledger_posting(liquidity_usd,  '100 USD'),
    ledger_posting(liquidity_eur,  '-85 EUR'),
    ledger_posting(customer_eur,    '85 EUR')
]);
```

Run operational integrity checks at any time:

```sql
SELECT * FROM ledger_validate();
```

## Exact assets and amounts

```sql
SELECT 'USD'::ledger_asset;                    -- USD
SELECT 'BTC'::ledger_asset;                    -- BTC@bitcoin
SELECT 'USDC@ethereum'::ledger_asset;          -- scale 6
SELECT 'TOK@private-chain/8'::ledger_asset;    -- explicit custom scale

SELECT 'USD 12.34'::ledger_amount;             -- 12.34 USD
SELECT '1.00000001 BTC'::ledger_amount;        -- 100000001 units
SELECT ledger_amount_units('1.00000001 BTC'); -- 100000001
```

Known ISO fiat exponents and common native/token crypto exponents are built in.
An unknown crypto identity must include `/decimals`. The scale is part of asset
identity, and input with excess fractional precision is rejected.

## Optional extension interoperability

`pg_ledger` has no hard dependency on `pg_money` or `pg_crypto`. If either is
installed first, conversion overloads are enabled during installation. If it is
installed later, call:

```sql
SELECT ledger_enable_pg_money();
SELECT ledger_enable_pg_crypto();
```

The generated adapters include `ledger_amount(money_minor)`,
`ledger_to_money_minor(ledger_amount)`, `ledger_amount(money_with_currency)`,
`ledger_to_money(ledger_amount)`, `ledger_amount(crypto_amount)`, and
`ledger_to_crypto(ledger_amount)` when the corresponding source types exist.

See [docs/API.md](docs/API.md) and [docs/SECURITY.md](docs/SECURITY.md).

## Development

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --no-default-features --features pg18 -- \
    -D warnings -W clippy::pedantic
cargo pgrx test pg18 --no-default-features --features pg18
./ci/test-extension.sh "$(cargo pgrx info pg-config 18)"
```

The integration test also runs 400 concurrent opposite-direction transfers and
then verifies every ledger invariant.
