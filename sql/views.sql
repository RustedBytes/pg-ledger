CREATE VIEW ledger_account_balances AS
SELECT id, name, asset, balance, version, balance_policy, updated_at
FROM ledger_accounts;

CREATE VIEW ledger_transaction_summary AS
SELECT t.id, t.created_at, t.event_at, t.reference, t.idempotency_key,
       t.reverses_transaction_id, t.metadata, count(e.id)::bigint AS entry_count
FROM ledger_transactions t
LEFT JOIN ledger_entries e ON e.transaction_id = t.id
GROUP BY t.id;
