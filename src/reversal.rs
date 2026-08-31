use pgrx::JsonB;
use pgrx::prelude::*;

use crate::errors::{fail_foreign_key, fail_internal};
use crate::posting::ledger_posting;
use crate::transaction::{PostRequest, post};

fn spi_failure(context: &str, error: &pgrx::spi::Error) -> ! {
    fail_internal(&format!("{context}: {error}"))
}

#[pg_extern(volatile, parallel_unsafe)]
pub fn _ledger_reverse_rust(
    transaction_id: pgrx::Uuid,
    reference: Option<String>,
    idempotency_key: Option<String>,
    event_at: Option<TimestampWithTimeZone>,
    metadata: Option<JsonB>,
) -> pgrx::Uuid {
    let existing = Spi::connect_mut(|client| {
        let found = client
            .update(
                "SELECT id FROM ledger_transactions WHERE id = $1 FOR UPDATE",
                Some(1),
                &[transaction_id.into()],
            )
            .unwrap_or_else(|error| spi_failure("could not lock ledger transaction", &error));
        if found.is_empty() {
            fail_foreign_key(&format!(
                "ledger transaction {transaction_id} does not exist"
            ));
        }
        let rows = client
            .update(
                "SELECT id FROM ledger_transactions WHERE reverses_transaction_id = $1",
                Some(1),
                &[transaction_id.into()],
            )
            .unwrap_or_else(|error| spi_failure("could not find existing reversal", &error));
        if rows.is_empty() {
            None
        } else {
            rows.first()
                .get_one::<pgrx::Uuid>()
                .unwrap_or_else(|error| spi_failure("could not read existing reversal", &error))
        }
    });
    if let Some(existing) = existing {
        return existing;
    }

    let postings = Spi::connect_mut(|client| {
        let rows = client
            .update(
                "SELECT ledger_posting(account_id, -amount) AS posting \
                 FROM ledger_entries WHERE transaction_id = $1 \
                 ORDER BY account_id, account_version DESC",
                None,
                &[transaction_id.into()],
            )
            .unwrap_or_else(|error| spi_failure("could not construct reversal", &error));
        rows.into_iter()
            .map(|row| {
                row.get_by_name::<ledger_posting, _>("posting")
                    .unwrap_or_else(|error| spi_failure("could not read reversal posting", &error))
                    .unwrap_or_else(|| fail_internal("reversal posting is NULL"))
            })
            .collect::<Vec<_>>()
    });
    let reference = reference.or_else(|| Some(format!("reversal:{transaction_id}")));
    let idempotency_key =
        idempotency_key.or_else(|| Some(format!("ledger:reversal:{transaction_id}")));
    let metadata = metadata.or_else(|| {
        Some(JsonB(serde_json::json!({
            "reverses_transaction_id": transaction_id.to_string()
        })))
    });
    post(PostRequest {
        postings,
        reference: reference.as_deref(),
        idempotency_key: idempotency_key.as_deref(),
        event_at,
        metadata: metadata.as_ref(),
        reverses_transaction_id: Some(transaction_id),
    })
}
