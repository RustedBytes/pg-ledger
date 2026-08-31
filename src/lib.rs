mod amount;
mod asset;
mod errors;
mod idempotency;
mod posting;
mod reversal;
mod transaction;
mod validation;

use pgrx::prelude::*;
use sha2::{Digest, Sha256};

pgrx::pg_module_magic!();

#[derive(Debug, Clone, Copy, PartialEq, Eq, PostgresEnum)]
#[allow(non_camel_case_types, clippy::upper_case_acronyms)]
pub enum ledger_balance_policy {
    ANY,
    NON_NEGATIVE,
    NON_POSITIVE,
    ZERO,
}

#[pg_extern(volatile, parallel_unsafe)]
fn ledger_uuidv7() -> pgrx::Uuid {
    pgrx::Uuid::from_bytes(*uuid::Uuid::now_v7().as_bytes())
}

#[pg_extern(immutable, strict, parallel_safe)]
fn ledger_payload_hash(input: &str) -> String {
    hex::encode(Sha256::digest(input.as_bytes()))
}

extension_sql_file!(
    "../sql/schema.sql",
    name = "ledger_schema",
    requires = [
        asset::ledger_asset,
        asset::ledger_asset_eq,
        amount::ledger_amount,
        amount::ledger_amount_eq,
        posting::ledger_posting,
        posting::ledger_posting_eq,
        ledger_balance_policy,
        ledger_uuidv7,
        ledger_payload_hash,
        asset::ledger_asset_to_text,
        amount::ledger_amount_to_text,
        posting::ledger_posting_to_text,
        amount::ledger_add,
        amount::ledger_subtract,
        amount::ledger_negate,
        amount::ledger_amount_asset,
        amount::ledger_amount_units,
        amount::ledger_amount_is_zero,
        amount::ledger_amount_is_positive,
        amount::ledger_amount_is_negative,
        amount::ledger_amount_zero,
        posting::ledger_posting,
        posting::ledger_posting_account_id,
        posting::ledger_posting_amount,
        transaction::_ledger_post_rust,
        transaction::_ledger_transfer_rust,
        reversal::_ledger_reverse_rust,
        validation::_ledger_validate_rust
    ]
);

extension_sql_file!(
    "../sql/indexes.sql",
    name = "ledger_indexes",
    requires = ["ledger_schema"]
);

extension_sql_file!(
    "../sql/views.sql",
    name = "ledger_views",
    requires = ["ledger_indexes"]
);

extension_sql_file!(
    "../sql/permissions.sql",
    name = "ledger_permissions",
    requires = ["ledger_views"],
    finalize
);

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn uuidv7_has_version_seven() {
        let version =
            Spi::get_one::<String>("SELECT substring(ledger_uuidv7()::text FROM 15 FOR 1)")
                .unwrap();
        assert_eq!(version.as_deref(), Some("7"));
    }
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        Vec::new()
    }
}
