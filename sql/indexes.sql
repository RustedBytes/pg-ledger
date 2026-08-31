CREATE INDEX ledger_entries_account_history_idx
    ON ledger_entries (account_id, account_version);

CREATE INDEX ledger_entries_transaction_idx
    ON ledger_entries (transaction_id, account_id);

CREATE INDEX ledger_transactions_event_at_idx
    ON ledger_transactions (event_at, id);

CREATE INDEX ledger_transactions_reference_idx
    ON ledger_transactions (reference)
    WHERE reference IS NOT NULL;

CREATE INDEX ledger_transactions_reversal_idx
    ON ledger_transactions (reverses_transaction_id)
    WHERE reverses_transaction_id IS NOT NULL;
