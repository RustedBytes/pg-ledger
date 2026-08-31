use pgrx::prelude::*;

use crate::errors::fail_internal;

const CHECKS: [(&str, &str); 7] = [
    (
        "transaction_balance",
        "SELECT count(*)::bigint FROM (\
         SELECT e.transaction_id, ledger_amount_asset(e.amount) FROM ledger_entries e \
         GROUP BY e.transaction_id, ledger_amount_asset(e.amount) \
         HAVING sum(ledger_amount_units(e.amount)) <> 0) invalid",
    ),
    (
        "cached_balances",
        "SELECT count(*)::bigint FROM ledger_accounts a \
         WHERE ledger_amount_units(a.balance) <> coalesce((\
         SELECT sum(ledger_amount_units(e.amount)) FROM ledger_entries e \
         WHERE e.account_id = a.id), 0)",
    ),
    (
        "version_sequence",
        "SELECT count(*)::bigint FROM ledger_accounts a WHERE \
         a.version <> coalesce((SELECT count(*) FROM ledger_entries e WHERE e.account_id = a.id), 0) \
         OR (a.version > 0 AND ((SELECT min(e.account_version) FROM ledger_entries e WHERE e.account_id = a.id) <> 1 \
         OR (SELECT max(e.account_version) FROM ledger_entries e WHERE e.account_id = a.id) <> a.version)) \
         OR EXISTS (SELECT 1 FROM ledger_entries e WHERE e.account_id = a.id \
         GROUP BY e.account_version HAVING count(*) > 1)",
    ),
    (
        "balance_chain",
        "SELECT count(*)::bigint FROM (SELECT e.*, lag(e.current_balance) OVER (\
         PARTITION BY e.account_id ORDER BY e.account_version) AS prior FROM ledger_entries e) chained \
         WHERE (account_version = 1 AND NOT ledger_amount_is_zero(previous_balance)) \
         OR (account_version > 1 AND prior IS DISTINCT FROM previous_balance) \
         OR previous_balance + amount IS DISTINCT FROM current_balance",
    ),
    (
        "minimum_entries",
        "SELECT count(*)::bigint FROM (SELECT t.id FROM ledger_transactions t \
         LEFT JOIN ledger_entries e ON e.transaction_id = t.id \
         GROUP BY t.id HAVING count(e.id) < 2) invalid",
    ),
    (
        "asset_consistency",
        "SELECT count(*)::bigint FROM ledger_entries e JOIN ledger_accounts a ON a.id = e.account_id \
         WHERE ledger_amount_asset(e.amount) IS DISTINCT FROM a.asset",
    ),
    (
        "reversal_consistency",
        "SELECT count(*)::bigint FROM ledger_transactions reversal \
         WHERE reversal.reverses_transaction_id IS NOT NULL AND EXISTS (\
           WITH original AS (SELECT account_id, ledger_amount_asset(amount) AS asset, \
             ledger_amount_units(amount) AS units, count(*) AS copies FROM ledger_entries \
             WHERE transaction_id = reversal.reverses_transaction_id \
             GROUP BY account_id, ledger_amount_asset(amount), ledger_amount_units(amount)), \
           reversed AS (SELECT account_id, ledger_amount_asset(amount) AS asset, \
             -ledger_amount_units(amount) AS units, count(*) AS copies FROM ledger_entries \
             WHERE transaction_id = reversal.id \
             GROUP BY account_id, ledger_amount_asset(amount), -ledger_amount_units(amount)) \
           SELECT account_id, asset, units, copies FROM original \
           FULL JOIN reversed USING (account_id, asset, units, copies) \
           WHERE original.account_id IS NULL OR reversed.account_id IS NULL)",
    ),
];

#[pg_extern(stable, parallel_restricted)]
pub fn _ledger_validate_rust() -> TableIterator<
    'static,
    (
        name!(check_name, String),
        name!(status, String),
        name!(violations, i64),
    ),
> {
    let mut results = Spi::connect(|client| {
        CHECKS
            .into_iter()
            .map(|(name, query)| {
                let rows = client.select(query, Some(1), &[]).unwrap_or_else(|error| {
                    fail_internal(&format!("could not run {name} ledger validation: {error}"))
                });
                if rows.is_empty() {
                    fail_internal(&format!("{name} ledger validation returned no row"));
                }
                let violations = rows
                    .first()
                    .get_one::<i64>()
                    .unwrap_or_else(|error| {
                        fail_internal(&format!("could not read {name} ledger validation: {error}"))
                    })
                    .unwrap_or_else(|| {
                        fail_internal(&format!("{name} ledger validation count is NULL"))
                    });
                (
                    name.to_owned(),
                    if violations == 0 { "OK" } else { "FAIL" }.to_owned(),
                    violations,
                )
            })
            .collect::<Vec<_>>()
    });
    results.sort_by(|left, right| left.0.cmp(&right.0));
    TableIterator::new(results)
}
