\set ON_ERROR_STOP on

DO $body$
DECLARE
    conflicting_amount numeric;
    origin_id uuid;
    reversal_id uuid;
BEGIN
    ASSERT (SELECT count(*) FROM ledger_transactions
            WHERE idempotency_key = 'race:idempotency:matching') = 1;
    ASSERT (SELECT count(*) FROM ledger_entries e
            JOIN ledger_transactions t ON t.id = e.transaction_id
            WHERE t.idempotency_key = 'race:idempotency:matching') = 2;
    ASSERT (ledger_account('race:idempotency:matching:source')).balance::text = '-1 USD';
    ASSERT (ledger_account('race:idempotency:matching:destination')).balance::text = '1 USD';

    ASSERT (SELECT count(*) FROM ledger_transactions
            WHERE idempotency_key = 'race:idempotency:conflicting') = 1;
    ASSERT (SELECT count(*) FROM ledger_entries e
            JOIN ledger_transactions t ON t.id = e.transaction_id
            WHERE t.idempotency_key = 'race:idempotency:conflicting') = 2;
    ASSERT (SELECT is_called FROM ledger_race_conflict_count);
    conflicting_amount := ledger_amount_value(
        (ledger_account('race:idempotency:conflicting:destination')).balance
    );
    ASSERT conflicting_amount IN (1, 2);
    ASSERT ledger_amount_value(
        (ledger_account('race:idempotency:conflicting:source')).balance
    ) = -conflicting_amount;

    SELECT id INTO STRICT origin_id FROM ledger_transactions
    WHERE idempotency_key = 'race:reversal:origin';
    SELECT id INTO STRICT reversal_id FROM ledger_transactions
    WHERE reverses_transaction_id = origin_id;
    ASSERT (SELECT count(*) FROM ledger_transactions
            WHERE reverses_transaction_id = origin_id) = 1;
    ASSERT (SELECT count(*) FROM ledger_entries
            WHERE transaction_id = reversal_id) = 2;
    ASSERT (ledger_account('race:reversal:source')).balance::text = '0 USD';
    ASSERT (ledger_account('race:reversal:destination')).balance::text = '0 USD';

    ASSERT NOT EXISTS (SELECT 1 FROM ledger_validate() WHERE status <> 'OK');
END
$body$;

DROP FUNCTION ledger_race_conflicting_idempotency(integer);
DROP SEQUENCE ledger_race_conflict_count;
