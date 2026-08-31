\set ON_ERROR_STOP on

SELECT ledger_create_account('failure:post:source', 'USD', 'ANY');
SELECT ledger_create_account('failure:post:destination', 'USD', 'NON_NEGATIVE');

CREATE FUNCTION ledger_inject_account_update_failure()
RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    RAISE EXCEPTION 'injected account update failure';
END
$body$;

CREATE TRIGGER ledger_failure_account_update
BEFORE UPDATE ON ledger_accounts
FOR EACH ROW EXECUTE FUNCTION ledger_inject_account_update_failure();

DO $body$
BEGIN
    BEGIN
        PERFORM ledger_transfer(
            (ledger_account('failure:post:source')).id,
            (ledger_account('failure:post:destination')).id,
            '5 USD',
            idempotency_key => 'failure:after-transaction-insert'
        );
        RAISE EXCEPTION 'expected injected account update failure';
    EXCEPTION WHEN raise_exception THEN
        ASSERT SQLERRM = 'injected account update failure';
    END;

    ASSERT NOT EXISTS (SELECT 1 FROM ledger_transactions
                       WHERE idempotency_key = 'failure:after-transaction-insert');
    ASSERT (ledger_account('failure:post:source')).balance::text = '0 USD';
    ASSERT (ledger_account('failure:post:destination')).balance::text = '0 USD';
END
$body$;

DROP TRIGGER ledger_failure_account_update ON ledger_accounts;
DROP FUNCTION ledger_inject_account_update_failure();

CREATE SEQUENCE ledger_failure_entry_step;

CREATE FUNCTION ledger_inject_second_entry_failure()
RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    IF nextval('ledger_failure_entry_step') = 2 THEN
        RAISE EXCEPTION 'injected second entry failure';
    END IF;
    RETURN NEW;
END
$body$;

CREATE TRIGGER ledger_failure_second_entry
BEFORE INSERT ON ledger_entries
FOR EACH ROW EXECUTE FUNCTION ledger_inject_second_entry_failure();

SELECT setval('ledger_failure_entry_step', 1, false);

DO $body$
BEGIN
    BEGIN
        PERFORM ledger_transfer(
            (ledger_account('failure:post:source')).id,
            (ledger_account('failure:post:destination')).id,
            '7 USD',
            idempotency_key => 'failure:mid-journal'
        );
        RAISE EXCEPTION 'expected injected second entry failure';
    EXCEPTION WHEN raise_exception THEN
        ASSERT SQLERRM = 'injected second entry failure';
    END;

    ASSERT NOT EXISTS (SELECT 1 FROM ledger_transactions
                       WHERE idempotency_key = 'failure:mid-journal');
    ASSERT NOT EXISTS (SELECT 1 FROM ledger_entries e
                       JOIN ledger_transactions t ON t.id = e.transaction_id
                       WHERE t.idempotency_key = 'failure:mid-journal');
    ASSERT (ledger_account('failure:post:source')).balance::text = '0 USD';
    ASSERT (ledger_account('failure:post:source')).version = 0;
    ASSERT (ledger_account('failure:post:destination')).balance::text = '0 USD';
    ASSERT (ledger_account('failure:post:destination')).version = 0;
END
$body$;

DROP TRIGGER ledger_failure_second_entry ON ledger_entries;

SELECT ledger_transfer(
    (ledger_account('failure:post:source')).id,
    (ledger_account('failure:post:destination')).id,
    '9 USD',
    idempotency_key => 'failure:reversal-origin'
) AS failure_origin \gset

CREATE TRIGGER ledger_failure_second_entry
BEFORE INSERT ON ledger_entries
FOR EACH ROW EXECUTE FUNCTION ledger_inject_second_entry_failure();
SELECT setval('ledger_failure_entry_step', 1, false);
SELECT set_config('failure.origin', :'failure_origin', false);

DO $body$
BEGIN
    BEGIN
        PERFORM ledger_reverse(current_setting('failure.origin')::uuid);
        RAISE EXCEPTION 'expected injected reversal entry failure';
    EXCEPTION WHEN raise_exception THEN
        ASSERT SQLERRM = 'injected second entry failure';
    END;

    ASSERT NOT EXISTS (SELECT 1 FROM ledger_transactions
                       WHERE reverses_transaction_id = current_setting('failure.origin')::uuid);
    ASSERT (ledger_account('failure:post:source')).balance::text = '-9 USD';
    ASSERT (ledger_account('failure:post:destination')).balance::text = '9 USD';
END
$body$;

DROP TRIGGER ledger_failure_second_entry ON ledger_entries;
DROP FUNCTION ledger_inject_second_entry_failure();
DROP SEQUENCE ledger_failure_entry_step;

SELECT ledger_reverse(:'failure_origin'::uuid);

DO $body$
BEGIN
    ASSERT (ledger_account('failure:post:source')).balance::text = '0 USD';
    ASSERT (ledger_account('failure:post:destination')).balance::text = '0 USD';
    ASSERT NOT EXISTS (SELECT 1 FROM ledger_validate() WHERE status <> 'OK');
END
$body$;
