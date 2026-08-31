# SQL API

## Types

### `ledger_asset`

An immutable asset identity with kind (`fiat` or `crypto`), symbol, optional
network, and decimal scale. Equality includes every identity field.

Accessors: `ledger_asset_kind`, `ledger_asset_symbol`,
`ledger_asset_network`, and `ledger_asset_scale`.

### `ledger_amount`

A signed arbitrary-precision integer unit count paired with a `ledger_asset`.
Addition and subtraction reject different assets. Unary negation is supported.

Accessors: `ledger_amount_asset`, `ledger_amount_units`,
`ledger_amount_value`, `ledger_amount_is_zero`,
`ledger_amount_is_positive`, and `ledger_amount_is_negative`.

### `ledger_posting`

An account and a `ledger_amount`. Construct one with
`ledger_posting(account_id, amount)`, `ledger_posting(account_name, amount)`,
or the corresponding `ledger_entry` alias.

## Account API

```sql
ledger_create_account(
    name text,
    asset ledger_asset,
    balance_policy ledger_balance_policy DEFAULT 'NON_NEGATIVE',
    metadata jsonb DEFAULT NULL
) RETURNS uuid
```

Names are unique. New accounts always start at exactly zero. Policies are:

- `ANY`: any signed balance.
- `NON_NEGATIVE`: zero or positive.
- `NON_POSITIVE`: zero or negative.
- `ZERO`: postings may not move the account away from zero.

Read with `ledger_account(uuid)`, `ledger_account(text)`, and
`ledger_balance(uuid)`.

## Posting API

```sql
ledger_post(
    postings ledger_posting[],
    reference text DEFAULT NULL,
    idempotency_key text DEFAULT NULL,
    event_at timestamptz DEFAULT NULL,
    metadata jsonb DEFAULT NULL
) RETURNS uuid
```

At least two non-zero postings are required. An account may appear more than
once; each occurrence remains a distinct entry and advances its account
version. For every distinct asset, posting units must sum to zero. Balance
policies apply to each account's final net balance for the whole transaction.
All unique accounts are locked in UUID order before any balance changes are
made. The PostgreSQL transaction is the atomicity boundary.

If `idempotency_key` already exists and the canonical request fingerprint is
identical, the existing transaction UUID is returned. A different request with
the same key raises an error. Fingerprints are format-versioned; newly written
hashes use `v1:`, while retries remain compatible with the original unversioned
format.

`created_at` is the write time. `event_at` is the real-world event time and
defaults to the write time only when omitted.

## Convenience and correction API

```sql
ledger_transfer(from_account uuid, to_account uuid, amount ledger_amount, ...)
ledger_reverse(transaction_id uuid, ...)
```

`ledger_transfer` accepts a positive amount and delegates to the same posting
engine with one debit and one credit. `ledger_reverse` creates an immutable,
linked transaction whose postings negate the original. Reversing the same
transaction again returns its existing reversal.

Read transactions with `ledger_transaction(uuid)` and their entries with
`ledger_entries(uuid)`.

## Integrity API

`ledger_validate()` reports `OK` or `FAIL` plus a violation count for:

- transaction balance by asset;
- cached account balances;
- account version sequences;
- previous/current balance chains;
- the minimum two-entry rule;
- entry/account asset consistency;
- reversal consistency.

The `ledger_account_balances` and `ledger_transaction_summary` views cover
common operational reads.
