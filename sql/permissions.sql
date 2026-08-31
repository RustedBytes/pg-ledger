REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ledger_entries FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ledger_transactions FROM PUBLIC;
REVOKE INSERT, DELETE, TRUNCATE ON ledger_accounts FROM PUBLIC;
REVOKE UPDATE (asset, balance, version, created_at, updated_at) ON ledger_accounts FROM PUBLIC;

REVOKE ALL ON FUNCTION _ledger_post(
    ledger_posting[], text, text, timestamptz, jsonb, uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION _ledger_post_rust(
    ledger_posting[], text, text, timestamptz, jsonb, uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION _ledger_transfer_rust(
    uuid, uuid, ledger_amount, text, text, timestamptz, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION _ledger_reverse_rust(
    uuid, text, text, timestamptz, jsonb
) FROM PUBLIC;

GRANT SELECT ON ledger_accounts, ledger_transactions, ledger_entries,
    ledger_account_balances, ledger_transaction_summary TO PUBLIC;

GRANT EXECUTE ON FUNCTION ledger_create_account(text, ledger_asset, ledger_balance_policy, jsonb) TO PUBLIC;
GRANT EXECUTE ON FUNCTION ledger_post(ledger_posting[], text, text, timestamptz, jsonb) TO PUBLIC;
GRANT EXECUTE ON FUNCTION ledger_transfer(uuid, uuid, ledger_amount, text, text, timestamptz, jsonb) TO PUBLIC;
GRANT EXECUTE ON FUNCTION ledger_reverse(uuid, text, text, timestamptz, jsonb) TO PUBLIC;
