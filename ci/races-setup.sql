\set ON_ERROR_STOP on

SELECT ledger_create_account('race:idempotency:matching:source', 'USD', 'ANY');
SELECT ledger_create_account('race:idempotency:matching:destination', 'USD', 'NON_NEGATIVE');
SELECT ledger_create_account('race:idempotency:conflicting:source', 'USD', 'ANY');
SELECT ledger_create_account('race:idempotency:conflicting:destination', 'USD', 'NON_NEGATIVE');
SELECT ledger_create_account('race:reversal:source', 'USD', 'ANY');
SELECT ledger_create_account('race:reversal:destination', 'USD', 'NON_NEGATIVE');

SELECT ledger_transfer(
    (ledger_account('race:reversal:source')).id,
    (ledger_account('race:reversal:destination')).id,
    '10 USD',
    reference => 'race reversal origin',
    idempotency_key => 'race:reversal:origin',
    event_at => '2026-08-31 00:00:00+00'
);

CREATE SEQUENCE ledger_race_conflict_count;

CREATE FUNCTION ledger_race_conflicting_idempotency(client_number integer)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $body$
BEGIN
    RETURN ledger_transfer(
        (ledger_account('race:idempotency:conflicting:source')).id,
        (ledger_account('race:idempotency:conflicting:destination')).id,
        (CASE WHEN client_number % 2 = 0 THEN '1 USD' ELSE '2 USD' END)::ledger_amount,
        reference => 'conflicting idempotency race',
        idempotency_key => 'race:idempotency:conflicting',
        event_at => '2026-08-31 00:00:00+00'
    );
EXCEPTION WHEN invalid_parameter_value THEN
    PERFORM nextval('ledger_race_conflict_count');
    RETURN NULL;
END
$body$;
