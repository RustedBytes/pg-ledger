SELECT ledger_reverse(
    (SELECT id FROM ledger_transactions
     WHERE idempotency_key = 'race:reversal:origin')
);
