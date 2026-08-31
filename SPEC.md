Yes. `pgr0ss/pgledger` is a very good reference, but I would not simply port its PL/pgSQL into Rust. I would keep PostgreSQL responsible for storage, locking, constraints, and transactions, while using pgrx to define a stronger domain API and integrate directly with `pg_money` / `pg_cryptocurrency`.

The reference implementation has three core tables: accounts, transfers, and entries. Accounts hold a cached balance/version; a transfer moves a positive amount between two same-currency accounts; and two immutable entry rows record the resulting debit/credit plus previous/current balances.  It also sorts and locks all affected accounts before processing a batch, specifically to avoid deadlocks.

I would build `pg-ledger` around that same model, but strengthen it considerably.

## 1. Core model

The first version can remain conceptually simple:

```text
ledger_account
    id
    name
    asset
    balance
    version
    balance_policy
    metadata
    created_at
    updated_at

ledger_transaction
    id
    created_at
    event_at
    reference
    idempotency_key
    metadata

ledger_entry
    id
    transaction_id
    account_id
    amount
    account_version
    previous_balance
    current_balance
    created_at
```

The major difference from `pgledger` is that I would introduce a **transaction/journal object above individual transfers**.

Instead of:

```text
transfer
    account A -> account B
```

the fundamental primitive becomes:

```text
transaction
    entry 1
    entry 2
    entry 3
    entry 4
    ...
```

That becomes important immediately for an exchange.

For example:

```text
Exchange USD → EUR

transaction tx_123

user.usd
    -1000 USD

liquidity.usd
    +1000 USD

liquidity.eur
    -850 EUR

user.eur
    +850 EUR
```

A simple two-account transfer is then just a convenience wrapper around a two-entry transaction.

That's more general than the reference implementation, where cross-currency exchange is represented as two transfers involving four accounts.

---

# 2. Do not use `NUMERIC amount`

This is where your existing extensions give you a major advantage over `pgledger`.

The reference uses:

```sql
currency TEXT
amount NUMERIC
balance NUMERIC
```

For your project I would make ledger storage asset-aware.

For fiat accounts:

```sql
balance money_with_currency
```

or, preferably for a high-throughput ledger:

```sql
balance money_minor
```

because `money_minor` is integer-backed.

For cryptocurrency:

```sql
crypto_amount
```

But there's a design problem: a single SQL column can't trivially alternate between `money_minor` and `crypto_amount`.

So I recommend introducing one additional type into `pg-ledger`:

```rust
LedgerAsset
LedgerAmount
```

Conceptually:

```text
LedgerAsset =
    Fiat(pg_money currency)
    Crypto(pg_cryptocurrency asset)

LedgerAmount =
    Fiat(money_minor)
    Crypto(crypto_units)
```

This is better than using `numeric`.

For example:

```sql
SELECT 'USD'::ledger_asset;
SELECT 'BTC@bitcoin'::ledger_asset;

SELECT 'USD 100.00'::ledger_amount;
SELECT '0.025 BTC'::ledger_amount;
```

Internally, however, I'd strongly consider storing amounts in **integer smallest units**.

So:

```text
USD 12.34
→ 1234

USDC 12.345678
→ 12345678

BTC 1.00000001
→ 100000001
```

This gives the ledger one universal invariant:

```text
amount_units: arbitrary precision signed integer
asset: ledger_asset
```

That's ideal for accounting.

---

# 3. Proposed pgrx types

Something roughly like:

```rust
#[derive(
    PostgresType,
    Serialize,
    Deserialize,
    Debug,
    Clone,
    PartialEq,
    Eq,
    Hash
)]
pub struct LedgerAsset {
    pub kind: AssetKind,
    pub identity: String,
}

#[derive(
    PostgresType,
    Serialize,
    Deserialize,
    Debug,
    Clone,
    PartialEq,
    Eq
)]
pub struct LedgerAmount {
    pub asset: LedgerAsset,
    pub units: Numeric,
}
```

Though for production I'd probably avoid `String` as the final binary representation and use stable compact asset identifiers.

You could expose:

```rust
#[pg_extern]
fn ledger_asset(input: &str) -> LedgerAsset
```

and:

```rust
#[pg_extern]
fn ledger_amount(input: &str) -> LedgerAmount
```

But because you already own `pg_money` and `pg_cryptocurrency`, an even cleaner architecture would be interoperability functions:

```sql
ledger_amount('USD 100'::money_minor)

ledger_amount('1 BTC'::crypto_amount)
```

and:

```sql
ledger_to_money(...)
ledger_to_crypto(...)
```

---

# 4. Tables should mostly be SQL supplied by the extension

pgrx doesn't mean you need to create every table through Rust SPI calls.

Ship them through extension SQL:

```rust
extension_sql!(
    r#"
    CREATE TABLE ledger_accounts (
        id uuid PRIMARY KEY DEFAULT uuidv7(),

        name text NOT NULL,

        asset ledger_asset NOT NULL,

        balance ledger_amount NOT NULL,
        version bigint NOT NULL DEFAULT 0,

        allow_negative boolean NOT NULL DEFAULT true,
        allow_positive boolean NOT NULL DEFAULT true,

        metadata jsonb,

        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
    );
    "#,
    name = "create_ledger_accounts"
);
```

Likewise:

```sql
CREATE TABLE ledger_transactions (
    id uuid PRIMARY KEY DEFAULT uuidv7(),

    reference text,
    idempotency_key text UNIQUE,

    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    event_at timestamptz NOT NULL,

    metadata jsonb
);
```

and:

```sql
CREATE TABLE ledger_entries (
    id uuid PRIMARY KEY DEFAULT uuidv7(),

    transaction_id uuid NOT NULL
        REFERENCES ledger_transactions(id),

    account_id uuid NOT NULL
        REFERENCES ledger_accounts(id),

    amount ledger_amount NOT NULL,

    account_version bigint NOT NULL,

    previous_balance ledger_amount NOT NULL,
    current_balance ledger_amount NOT NULL,

    created_at timestamptz NOT NULL
);
```

---

# 5. Make `ledger_post()` the fundamental API

I would not make:

```text
create_transfer()
```

the core primitive.

I'd expose something closer to:

```sql
SELECT *
FROM ledger_post(
    ARRAY[
        ledger_entry('customer_usd', '-100 USD'),
        ledger_entry('exchange_usd', '+100 USD')
    ]
);
```

Eventually:

```sql
SELECT ledger_post(
    entries => ARRAY[
        ('account-a', '-100 USD')::ledger_posting,
        ('account-b', '+100 USD')::ledger_posting
    ],
    reference => 'withdrawal_123',
    idempotency_key => 'stripe:event:xyz',
    metadata => '{"order": 123}'
);
```

So create a pgrx composite type:

```rust
#[derive(PostgresType, Serialize, Deserialize)]
pub struct Posting {
    account_id: Uuid,
    amount: LedgerAmount,
}
```

Then:

```rust
#[pg_extern]
fn ledger_post(
    postings: Vec<Posting>,
    reference: default!(Option<String>, "NULL"),
    idempotency_key: default!(Option<String>, "NULL"),
    event_at: default!(Option<TimestampWithTimeZone>, "NULL"),
    metadata: default!(Option<JsonB>, "NULL"),
) -> Uuid
```

---

# 6. Balancing rule

This is the central invariant.

Within each asset:

```text
Σ entries = 0
```

So:

```text
-100 USD
+100 USD
= 0
```

valid.

And:

```text
-1 BTC
+1 BTC
= 0
```

valid.

But:

```text
-100 USD
+90 EUR
```

invalid.

An FX transaction:

```text
-100 USD
+100 USD

-90 EUR
+90 EUR
```

is valid because every asset balances independently.

The Rust implementation can group postings by `LedgerAsset`:

```rust
HashMap<LedgerAsset, BigInt>
```

then verify:

```rust
for (_, total) in totals {
    if !total.is_zero() {
        error!("transaction is not balanced");
    }
}
```

This is a particularly good thing to put in Rust because it becomes difficult to bypass accidentally through your public API.

---

# 7. Lock accounts deterministically

This is one thing `pgledger` gets exactly right.

It gathers unique affected account IDs:

```text
A
B
C
D
```

sorts them, and does:

```sql
SELECT ...
FOR UPDATE
```

in deterministic order.

You absolutely want to keep that behavior.

Inside pgrx:

```rust
let mut ids = postings
    .iter()
    .map(|p| p.account_id)
    .collect::<Vec<_>>();

ids.sort();
ids.dedup();
```

Then through SPI:

```sql
SELECT ...
FROM ledger_accounts
WHERE id = ANY($1)
ORDER BY id
FOR UPDATE
```

One SQL query is preferable to issuing one query for every account.

That gives you:

```text
T1 locks A,B
T2 locks A,B
```

rather than potentially:

```text
T1 locks A then waits B
T2 locks B then waits A
```

---

# 8. Update cached balances atomically

Although entries should be the accounting source of truth, maintaining:

```text
ledger_accounts.balance
ledger_accounts.version
```

is very useful.

The reference implementation does exactly this and stores previous/current balances inside every entry.

I would retain that.

Example:

```text
before:

balance = USD 120
version = 48

posting = -USD 20

after:

balance = USD 100
version = 49
```

Entry:

```text
amount            -USD 20
previous_balance   USD 120
current_balance    USD 100
account_version    49
```

That gives historical balance queries essentially for free.

---

# 9. But make entries actually immutable

This is one area where I'd go further than a conventional schema.

Users of the extension should not be able to do:

```sql
UPDATE ledger_entries ...
DELETE FROM ledger_entries ...
```

or:

```sql
UPDATE ledger_accounts
SET balance = ...
```

Your installation script can:

```sql
REVOKE INSERT, UPDATE, DELETE
ON ledger_entries
FROM PUBLIC;

REVOKE UPDATE
ON ledger_accounts
FROM PUBLIC;
```

And expose mutations only through `SECURITY DEFINER` functions where appropriate.

Corrections should use:

```text
ledger_reverse(transaction_id)
```

not mutation.

Example:

```text
original:

customer     -100
merchant     +100
```

reversal:

```text
customer     +100
merchant     -100
```

with:

```text
reverses_transaction_id
```

stored on the new transaction.

---

# 10. Idempotency should be first class

This is something I would absolutely add for an exchange.

Imagine your service receives the same:

```text
bank webhook
blockchain deposit
withdrawal callback
payment event
```

twice.

You want:

```sql
SELECT ledger_post(
    ...,
    idempotency_key => 'bank:monobank:transaction:88342'
);
```

to guarantee exactly one ledger transaction.

Schema:

```sql
idempotency_key text UNIQUE
```

Then return the existing transaction if the same operation is replayed.

Potentially also save a request hash:

```text
idempotency_key
payload_hash
```

so:

```text
same key + same transaction
→ return existing result

same key + different transaction
→ ERROR
```

That's a major production safety feature.

---

# 11. Introduce balance policies rather than two booleans

The reference has:

```text
allow_negative_balance
allow_positive_balance
```

That works, but we can make the type clearer.

For example:

```rust
enum BalancePolicy {
    Any,
    NonNegative,
    NonPositive,
    Zero,
}
```

SQL:

```text
'ANY'
'NON_NEGATIVE'
'NON_POSITIVE'
'ZERO'
```

Examples:

```text
customer wallet
    NON_NEGATIVE

liability account
    NON_POSITIVE

internal clearing
    ANY
```

Potentially later:

```text
min_balance
max_balance
```

---

# 12. Separate `created_at` from `event_at`

Definitely keep this feature from pgledger.

They explicitly distinguish the moment something was written to the ledger from when the real-world financial event occurred.

That is critical for:

```text
bank reconciliation
blockchain confirmations
late webhooks
backfilled transactions
statements
accounting periods
```

I'd possibly add a third timestamp eventually:

```text
created_at
event_at
effective_at
```

but `created_at + event_at` is enough initially.

---

# 13. Exchange becomes beautifully straightforward

With this model:

```text
User exchanges:
1000 USD → 850 EUR
```

You post:

```sql
SELECT ledger_post(
    ARRAY[
        ledger_posting(customer_usd, '-1000 USD'),
        ledger_posting(liquidity_usd, '+1000 USD'),

        ledger_posting(liquidity_eur, '-850 EUR'),
        ledger_posting(customer_eur, '+850 EUR')
    ],
    reference => 'exchange:123'
);
```

Then separately record pricing metadata:

```json
{
  "pair": "USD/EUR",
  "market_rate": "0.85341",
  "customer_rate": "0.85000",
  "spread": "0.00341",
  "quote_id": "..."
}
```

Even better, if we later build `pg_fx`, that can become a typed reference.

---

# 14. Fees are just postings

Suppose:

```text
customer pays $100
fee = $2
recipient receives $98
```

Then:

```text
customer.cash       -100 USD
recipient.cash       +98 USD
exchange.fee_income  +2 USD
```

Sum:

```text
-100 + 98 + 2 = 0
```

No special fee field is needed in the ledger engine.

That's exactly why generalized postings are superior to only supporting transfers.

---

# 15. Rust/pgrx project structure

I'd use something like:

```text
pg-ledger/
├── Cargo.toml
├── pg-ledger.control
├── src/
│   ├── lib.rs
│   ├── account.rs
│   ├── amount.rs
│   ├── asset.rs
│   ├── posting.rs
│   ├── transaction.rs
│   ├── balance.rs
│   ├── reversal.rs
│   ├── idempotency.rs
│   ├── errors.rs
│   └── spi.rs
│
├── sql/
│   ├── schema.sql
│   ├── indexes.sql
│   ├── permissions.sql
│   └── views.sql
│
└── tests/
    ├── basic.rs
    ├── balancing.rs
    ├── concurrency.rs
    ├── idempotency.rs
    ├── currencies.rs
    ├── crypto.rs
    └── reversals.rs
```

`lib.rs`:

```rust
use pgrx::prelude::*;

pgrx::pg_module_magic!();

mod account;
mod amount;
mod asset;
mod balance;
mod errors;
mod idempotency;
mod posting;
mod reversal;
mod spi;
mod transaction;
```

---

# 16. Public API

I would keep the first API fairly small:

```text
ledger_create_account()
ledger_account()
ledger_balance()

ledger_post()
ledger_transfer()

ledger_reverse()

ledger_transaction()
ledger_entries()

ledger_validate()
```

For example:

```sql
SELECT ledger_create_account(
    name => 'customer:123:USD',
    asset => 'USD',
    balance_policy => 'NON_NEGATIVE'
);
```

and convenience API:

```sql
SELECT ledger_transfer(
    from_account => ...,
    to_account => ...,
    amount => 'USD 100'
);
```

Internally:

```text
ledger_transfer()
       ↓
ledger_post([
   -100,
   +100
])
```

There should be only **one actual posting engine**.

---

# 17. `ledger_validate()` is important

Add a database integrity checker.

```sql
SELECT * FROM ledger_validate();
```

It should verify:

```text
every transaction balances by asset
every account cached balance == reconstructed balance
entry versions are contiguous
previous_balance → current_balance chains are valid
every transaction has >= 2 entries
all entry assets match account assets
no duplicate versions
reversals point to valid transactions
```

Maybe output:

```text
check                   status   violations
-------------------------------------------------
transaction_balance     OK       0
cached_balances         OK       0
version_sequence        OK       0
balance_chain           OK       0
asset_consistency       OK       0
```

This would be extremely useful operationally.

---

# 18. Important architectural rule: don't overuse Rust

The tempting pgrx design is:

```text
everything → Rust SPI
```

I wouldn't do that.

Use PostgreSQL directly for:

```text
tables
indexes
FKs
CHECK constraints
UNIQUE constraints
row locks
transactions
permissions
views
```

Use Rust for:

```text
typed ledger amounts
asset compatibility
posting validation
balance arithmetic
API orchestration
idempotency validation
reversal logic
complex integrity checks
integration with pg_money
integration with pg_cryptocurrency
```

That gets the best of both worlds.

Postgres' concurrency/transaction machinery is considerably more important to the correctness of this extension than Rust itself.

---

## Recommended v1 architecture

I'd therefore diverge from `pgr0ss/pgledger` in four significant ways:

| pgledger                             | Our `pg-ledger`                                  |
| ------------------------------------ | ------------------------------------------------ |
| `currency TEXT`                      | typed `ledger_asset`                             |
| `NUMERIC`                            | exact smallest-unit `ledger_amount`              |
| transfer is fundamental              | arbitrary balanced transaction is fundamental    |
| two-account debit/credit             | N-account postings                               |
| cross-FX = 2 transfers               | cross-FX = 1 transaction / 4 postings            |
| prefixed text ULID                   | native UUIDv7 internally                         |
| balance flags                        | typed balance policy                             |
| no mandatory idempotency abstraction | first-class idempotency                          |
| PL/pgSQL engine                      | Rust/pgrx domain engine + PostgreSQL concurrency |

The reference project's concurrency technique—ordered `FOR UPDATE` account locking—and its balance/version history are worth preserving almost verbatim conceptually.

The part I would **not** copy is making a two-account transfer the fundamental accounting primitive. For the exchange service you're building, an **N-posting, per-asset-balanced journal transaction** will age much better.

If we're going to build this as another RustedBytes extension alongside `pg-money` and `pg-cryptocurrency`, I'd target **pgrx 0.19.2, PostgreSQL 14–18, with optional runtime interoperability with both extensions**, matching the compatibility strategy you're already using.
