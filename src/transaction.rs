use std::collections::{BTreeMap, BTreeSet, HashMap};

use num_bigint::BigInt;
use num_traits::Zero;
use pgrx::JsonB;
use pgrx::datum::DatumWithOid;
use pgrx::prelude::*;

use crate::amount::{ledger_amount, ledger_negate};
use crate::asset::ledger_asset;
use crate::errors::{
    fail_check, fail_foreign_key, fail_internal, fail_null, fail_parameter, fail_serialization,
};
use crate::idempotency;
use crate::ledger_balance_policy;
use crate::posting::ledger_posting;

struct AccountState {
    asset: ledger_asset,
    balance: ledger_amount,
    version: i64,
    policy: ledger_balance_policy,
}

fn spi_failure(context: &str, error: &pgrx::spi::Error) -> ! {
    fail_internal(&format!("{context}: {error}"))
}

pub(crate) struct PostRequest<'a> {
    pub(crate) postings: Vec<ledger_posting>,
    pub(crate) reference: Option<&'a str>,
    pub(crate) idempotency_key: Option<&'a str>,
    pub(crate) event_at: Option<TimestampWithTimeZone>,
    pub(crate) metadata: Option<&'a JsonB>,
    pub(crate) reverses_transaction_id: Option<pgrx::Uuid>,
}

enum InsertOutcome {
    Created(pgrx::Uuid),
    Replayed(pgrx::Uuid),
}

fn validate_postings(postings: &[ledger_posting]) {
    if postings.len() < 2 {
        fail_parameter("a ledger transaction requires at least two postings");
    }

    let mut totals = BTreeMap::<ledger_asset, BigInt>::new();
    for posting in postings {
        if posting.amount_ref().units_ref().is_zero() {
            fail_parameter("ledger postings cannot have zero amounts");
        }
        totals
            .entry(posting.amount_ref().asset_ref().clone())
            .and_modify(|total| *total += posting.amount_ref().units_ref())
            .or_insert_with(|| posting.amount_ref().units_ref().clone());
    }
    if let Some((asset, total)) = totals.into_iter().find(|(_, total)| !total.is_zero()) {
        fail_check(&format!(
            "transaction is not balanced for asset {asset} (net units: {total})"
        ));
    }
}

fn lock_accounts(
    client: &mut pgrx::spi::SpiClient<'_>,
    postings: &[ledger_posting],
) -> HashMap<uuid::Uuid, AccountState> {
    let ids = postings
        .iter()
        .map(ledger_posting::account_id)
        .collect::<BTreeSet<_>>();
    let bound_ids = ids
        .iter()
        .map(|id| pgrx::Uuid::from_bytes(*id.as_bytes()))
        .collect::<Vec<_>>();
    let table = client
        .update(
            "SELECT id, asset, balance, version, balance_policy \
             FROM ledger_accounts WHERE id = ANY($1) ORDER BY id FOR UPDATE",
            None,
            &[bound_ids.into()],
        )
        .unwrap_or_else(|error| spi_failure("could not lock ledger accounts", &error));
    if table.len() != ids.len() {
        fail_foreign_key("one or more posting accounts do not exist");
    }

    let mut accounts = HashMap::with_capacity(ids.len());
    for row in table {
        let id = row
            .get_by_name::<pgrx::Uuid, _>("id")
            .unwrap_or_else(|error| spi_failure("could not read account id", &error))
            .unwrap_or_else(|| fail_internal("locked account id is NULL"));
        let asset = row
            .get_by_name::<ledger_asset, _>("asset")
            .unwrap_or_else(|error| spi_failure("could not read account asset", &error))
            .unwrap_or_else(|| fail_internal("locked account asset is NULL"));
        let balance = row
            .get_by_name::<ledger_amount, _>("balance")
            .unwrap_or_else(|error| spi_failure("could not read account balance", &error))
            .unwrap_or_else(|| fail_internal("locked account balance is NULL"));
        let version = row
            .get_by_name::<i64, _>("version")
            .unwrap_or_else(|error| spi_failure("could not read account version", &error))
            .unwrap_or_else(|| fail_internal("locked account version is NULL"));
        let policy = row
            .get_by_name::<ledger_balance_policy, _>("balance_policy")
            .unwrap_or_else(|error| spi_failure("could not read account policy", &error))
            .unwrap_or_else(|| fail_internal("locked account policy is NULL"));
        accounts.insert(
            uuid::Uuid::from_bytes(*id.as_bytes()),
            AccountState {
                asset,
                balance,
                version,
                policy,
            },
        );
    }
    accounts
}

fn verify_final_balances(
    postings: &[ledger_posting],
    accounts: &HashMap<uuid::Uuid, AccountState>,
) {
    let mut final_balances = accounts
        .iter()
        .map(|(id, state)| (*id, state.balance.clone()))
        .collect::<HashMap<_, _>>();

    for posting in postings {
        let account = accounts
            .get(&posting.account_id())
            .unwrap_or_else(|| fail_internal("posting account was not locked"));
        if posting.amount_ref().asset_ref() != &account.asset {
            fail_parameter(&format!(
                "posting asset {} does not match account {} asset {}",
                posting.amount_ref().asset_ref(),
                posting.account_id(),
                account.asset
            ));
        }
        let balance = final_balances
            .get_mut(&posting.account_id())
            .unwrap_or_else(|| fail_internal("posting account has no final balance"));
        *balance = balance
            .checked_add(posting.amount_ref())
            .unwrap_or_else(|error| fail_parameter(&error));
    }

    for (id, final_balance) in final_balances {
        let policy = accounts
            .get(&id)
            .unwrap_or_else(|| fail_internal("account policy is missing"))
            .policy;
        let units = final_balance.units_ref();
        let violates = match policy {
            ledger_balance_policy::ANY => false,
            ledger_balance_policy::NON_NEGATIVE => units < &BigInt::ZERO,
            ledger_balance_policy::NON_POSITIVE => units > &BigInt::ZERO,
            ledger_balance_policy::ZERO => !units.is_zero(),
        };
        if violates {
            fail_check(&format!(
                "posting violates {policy:?} balance policy for account {id}"
            ));
        }
    }
}

fn insert_transaction(
    client: &mut pgrx::spi::SpiClient<'_>,
    request: &PostRequest<'_>,
    created_at: TimestampWithTimeZone,
) -> InsertOutcome {
    let payload_hashes = idempotency::payload_hashes(request);
    let effective_event_at = request.event_at.unwrap_or(created_at);
    let args: [DatumWithOid<'_>; 7] = [
        effective_event_at.into(),
        request.reference.map(str::to_owned).into(),
        request.idempotency_key.map(str::to_owned).into(),
        payload_hashes.current.clone().into(),
        request.reverses_transaction_id.into(),
        request.metadata.map(|value| JsonB(value.0.clone())).into(),
        created_at.into(),
    ];
    let inserted_rows = client
        .update(
            "INSERT INTO ledger_transactions (event_at, reference, idempotency_key, \
             payload_hash, reverses_transaction_id, metadata, created_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7) \
             ON CONFLICT (idempotency_key) DO NOTHING RETURNING id",
            Some(1),
            &args,
        )
        .unwrap_or_else(|error| spi_failure("could not create ledger transaction", &error));
    let inserted = if inserted_rows.is_empty() {
        None
    } else {
        inserted_rows
            .first()
            .get_one::<pgrx::Uuid>()
            .unwrap_or_else(|error| spi_failure("could not read ledger transaction id", &error))
    };
    if let Some(id) = inserted {
        return InsertOutcome::Created(id);
    }

    let key = request.idempotency_key.map_or_else(
        || fail_internal("transaction insert returned no row without an idempotency key"),
        str::to_owned,
    );
    let rows = client
        .update(
            "SELECT id, payload_hash FROM ledger_transactions WHERE idempotency_key = $1",
            Some(1),
            &[key.into()],
        )
        .unwrap_or_else(|error| spi_failure("could not resolve idempotency key", &error));
    if rows.is_empty() {
        fail_serialization("could not resolve idempotency key conflict");
    }
    let row = rows.first();
    let id = row
        .get_by_name::<pgrx::Uuid, _>("id")
        .unwrap_or_else(|error| spi_failure("could not read idempotent transaction", &error))
        .unwrap_or_else(|| fail_internal("idempotent transaction id is NULL"));
    let existing_hash = row
        .get_by_name::<String, _>("payload_hash")
        .unwrap_or_else(|error| spi_failure("could not read idempotency hash", &error))
        .unwrap_or_else(|| fail_internal("transaction payload hash is NULL"));
    if existing_hash != payload_hashes.current && existing_hash != payload_hashes.legacy {
        fail_parameter("idempotency key was already used with a different ledger transaction");
    }
    InsertOutcome::Replayed(id)
}

pub(crate) fn post(request: PostRequest<'_>) -> pgrx::Uuid {
    validate_postings(&request.postings);
    Spi::connect_mut(|client| {
        let created_at = clock_timestamp();
        let transaction_id = match insert_transaction(client, &request, created_at) {
            InsertOutcome::Created(transaction_id) => transaction_id,
            InsertOutcome::Replayed(transaction_id) => return transaction_id,
        };

        let mut accounts = lock_accounts(client, &request.postings);
        verify_final_balances(&request.postings, &accounts);
        client
            .update(
                "SELECT set_config('pg_ledger.internal_posting', 'on', true)",
                None,
                &[],
            )
            .unwrap_or_else(|error| spi_failure("could not enable posting guard", &error));

        let update_account = client
            .prepare_mut(
                "UPDATE ledger_accounts SET balance = $1, version = $2 WHERE id = $3",
                &oids_of![ledger_amount, i64, pgrx::Uuid],
            )
            .unwrap_or_else(|error| spi_failure("could not prepare account update", &error));
        let insert_entry = client
            .prepare_mut(
                "INSERT INTO ledger_entries (transaction_id, account_id, amount, \
                 account_version, previous_balance, current_balance, created_at) \
                 VALUES ($1, $2, $3, $4, $5, $6, $7)",
                &oids_of![
                    pgrx::Uuid,
                    pgrx::Uuid,
                    ledger_amount,
                    i64,
                    ledger_amount,
                    ledger_amount,
                    TimestampWithTimeZone,
                ],
            )
            .unwrap_or_else(|error| spi_failure("could not prepare ledger entry insert", &error));

        for posting in request.postings {
            let (account_id, amount) = posting.into_parts();
            let key = uuid::Uuid::from_bytes(*account_id.as_bytes());
            let account = accounts
                .get_mut(&key)
                .unwrap_or_else(|| fail_internal("posting account was not locked"));
            let previous = account.balance.clone();
            let current = previous
                .checked_add(&amount)
                .unwrap_or_else(|error| fail_parameter(&error));
            account.version += 1;
            account.balance = current.clone();

            client
                .update(
                    &update_account,
                    None,
                    &[
                        current.clone().into(),
                        account.version.into(),
                        account_id.into(),
                    ],
                )
                .unwrap_or_else(|error| spi_failure("could not update ledger account", &error));
            client
                .update(
                    &insert_entry,
                    None,
                    &[
                        transaction_id.into(),
                        account_id.into(),
                        amount.into(),
                        account.version.into(),
                        previous.into(),
                        current.into(),
                        created_at.into(),
                    ],
                )
                .unwrap_or_else(|error| spi_failure("could not insert ledger entry", &error));
        }
        client
            .update(
                "SELECT set_config('pg_ledger.internal_posting', 'off', true)",
                None,
                &[],
            )
            .unwrap_or_else(|error| spi_failure("could not disable posting guard", &error));
        transaction_id
    })
}

#[pg_extern(volatile, parallel_unsafe)]
#[allow(clippy::needless_pass_by_value)]
pub fn _ledger_post_rust(
    p_postings: Array<'_, ledger_posting>,
    p_reference: Option<String>,
    p_idempotency_key: Option<String>,
    p_event_at: Option<TimestampWithTimeZone>,
    p_metadata: Option<JsonB>,
    p_reverses_transaction_id: Option<pgrx::Uuid>,
) -> pgrx::Uuid {
    let postings = p_postings
        .iter()
        .map(|posting| posting.unwrap_or_else(|| fail_null("ledger postings cannot contain NULL")))
        .collect();
    post(PostRequest {
        postings,
        reference: p_reference.as_deref(),
        idempotency_key: p_idempotency_key.as_deref(),
        event_at: p_event_at,
        metadata: p_metadata.as_ref(),
        reverses_transaction_id: p_reverses_transaction_id,
    })
}

#[pg_extern(volatile, parallel_unsafe)]
#[allow(clippy::needless_pass_by_value)]
pub fn _ledger_transfer_rust(
    from_account: pgrx::Uuid,
    to_account: pgrx::Uuid,
    amount: ledger_amount,
    reference: Option<String>,
    idempotency_key: Option<String>,
    event_at: Option<TimestampWithTimeZone>,
    metadata: Option<JsonB>,
) -> pgrx::Uuid {
    if from_account == to_account {
        fail_parameter("transfer accounts must be distinct");
    }
    if amount.units_ref() <= &BigInt::ZERO {
        fail_parameter("transfer amount must be positive");
    }
    post(PostRequest {
        postings: vec![
            ledger_posting::new(from_account, ledger_negate(amount.clone())),
            ledger_posting::new(to_account, amount),
        ],
        reference: reference.as_deref(),
        idempotency_key: idempotency_key.as_deref(),
        event_at,
        metadata: metadata.as_ref(),
        reverses_transaction_id: None,
    })
}
