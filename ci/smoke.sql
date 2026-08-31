\set ON_ERROR_STOP on

CREATE EXTENSION pg_ledger;

DO $body$
BEGIN
    ASSERT 'USD'::ledger_asset::text = 'USD';
    ASSERT 'BTC'::ledger_asset::text = 'BTC@bitcoin';
    ASSERT 'USD 12.34'::ledger_amount::text = '12.34 USD';
    ASSERT ledger_amount_units('1.00000001 BTC') = 100000001;
    ASSERT substring(ledger_uuidv7()::text FROM 15 FOR 1) = '7';

    BEGIN
        PERFORM 'v1|crypto|BTC|bitcoin|9'::ledger_asset;
        RAISE EXCEPTION 'expected canonical crypto scale rejection';
    EXCEPTION WHEN invalid_text_representation THEN
        NULL;
    END;
END
$body$;

BEGIN;
DO $body$
BEGIN
    ASSERT txid_current_if_assigned() IS NULL;
    ASSERT NOT EXISTS (SELECT 1 FROM ledger_validate() WHERE status <> 'OK');
    ASSERT txid_current_if_assigned() IS NULL;
END
$body$;
ROLLBACK;

SELECT ledger_create_account('source:usd', 'USD', 'ANY') AS source_usd \gset
SELECT ledger_create_account('customer:usd', 'USD', 'NON_NEGATIVE') AS customer_usd \gset
SELECT ledger_create_account('merchant:usd', 'USD', 'NON_NEGATIVE') AS merchant_usd \gset
SELECT ledger_create_account('liquidity:usd', 'USD', 'ANY') AS liquidity_usd \gset
SELECT ledger_create_account('liquidity:eur', 'EUR', 'ANY') AS liquidity_eur \gset
SELECT ledger_create_account('customer:eur', 'EUR', 'NON_NEGATIVE') AS customer_eur \gset
SELECT ledger_create_account('concurrency:a', 'USD', 'ANY');
SELECT ledger_create_account('concurrency:b', 'USD', 'ANY');
SELECT ledger_create_account('duplicate:a', 'USD', 'NON_NEGATIVE') AS duplicate_a \gset
SELECT ledger_create_account('duplicate:b', 'USD', 'ANY') AS duplicate_b \gset
SELECT ledger_create_account('fee:payer', 'USD', 'ANY') AS fee_payer \gset
SELECT ledger_create_account('fee:recipient', 'USD', 'NON_NEGATIVE') AS fee_recipient \gset
SELECT ledger_create_account('fee:income', 'USD', 'NON_NEGATIVE') AS fee_income \gset

SELECT set_config('smoke.source_usd', :'source_usd', false);
SELECT set_config('smoke.customer_usd', :'customer_usd', false);
SELECT set_config('smoke.merchant_usd', :'merchant_usd', false);
SELECT set_config('smoke.liquidity_usd', :'liquidity_usd', false);
SELECT set_config('smoke.liquidity_eur', :'liquidity_eur', false);
SELECT set_config('smoke.customer_eur', :'customer_eur', false);
SELECT set_config('smoke.duplicate_a', :'duplicate_a', false);
SELECT set_config('smoke.duplicate_b', :'duplicate_b', false);
SELECT set_config('smoke.fee_payer', :'fee_payer', false);
SELECT set_config('smoke.fee_recipient', :'fee_recipient', false);
SELECT set_config('smoke.fee_income', :'fee_income', false);

SELECT ledger_post(
    ARRAY[
        ledger_entry('source:usd', '-1000 USD'),
        ledger_entry('customer:usd', '1000 USD')
    ],
    reference => 'initial funding',
    idempotency_key => 'funding:1'
) AS funding_tx \gset

SELECT ledger_post(
    ARRAY[
        ledger_posting(:'source_usd'::uuid, '-1000 USD'),
        ledger_posting(:'customer_usd'::uuid, '1000 USD')
    ],
    reference => 'initial funding',
    idempotency_key => 'funding:1'
) AS funding_replay \gset

SELECT ledger_transfer(
    :'customer_usd'::uuid,
    :'merchant_usd'::uuid,
    '100 USD',
    reference => 'order:42',
    idempotency_key => 'order:42'
) AS payment_tx \gset

SELECT ledger_post(
    ARRAY[
        ledger_posting(:'customer_usd'::uuid, '-200 USD'),
        ledger_posting(:'liquidity_usd'::uuid, '200 USD'),
        ledger_posting(:'liquidity_eur'::uuid, '-170 EUR'),
        ledger_posting(:'customer_eur'::uuid, '170 EUR')
    ],
    reference => 'exchange:1',
    idempotency_key => 'exchange:1',
    event_at => '2026-01-02 03:04:05+00',
    metadata => '{"pair":"USD/EUR","rate":"0.85"}'
) AS exchange_tx \gset

SELECT ledger_post(ARRAY[
    ledger_posting(:'fee_payer'::uuid, '-100 USD'),
    ledger_posting(:'fee_recipient'::uuid, '98 USD'),
    ledger_posting(:'fee_income'::uuid, '2 USD')
], reference => 'payment with fee') AS fee_tx \gset

SELECT set_config('smoke.funding_tx', :'funding_tx', false);
SELECT set_config('smoke.funding_replay', :'funding_replay', false);
SELECT set_config('smoke.payment_tx', :'payment_tx', false);
SELECT set_config('smoke.exchange_tx', :'exchange_tx', false);

SELECT ledger_post(ARRAY[
    ledger_posting(:'duplicate_a'::uuid, '-10 USD'),
    ledger_posting(:'duplicate_b'::uuid, '10 USD'),
    ledger_posting(:'duplicate_a'::uuid, '10 USD'),
    ledger_posting(:'duplicate_b'::uuid, '-10 USD')
], reference => 'repeated account lines', idempotency_key => 'duplicates:1') AS duplicate_tx \gset

SELECT ledger_post(ARRAY[
    ledger_posting(:'duplicate_b'::uuid, '-10 USD'),
    ledger_posting(:'duplicate_a'::uuid, '10 USD'),
    ledger_posting(:'duplicate_b'::uuid, '10 USD'),
    ledger_posting(:'duplicate_a'::uuid, '-10 USD')
], reference => 'repeated account lines', idempotency_key => 'duplicates:1') AS duplicate_replay \gset

SELECT set_config('smoke.duplicate_tx', :'duplicate_tx', false);
SELECT set_config('smoke.duplicate_replay', :'duplicate_replay', false);

DO $body$
DECLARE
    customer_usd uuid := current_setting('smoke.customer_usd')::uuid;
    merchant_usd uuid := current_setting('smoke.merchant_usd')::uuid;
BEGIN
    ASSERT current_setting('smoke.funding_tx')::uuid = current_setting('smoke.funding_replay')::uuid;
    ASSERT (SELECT payload_hash LIKE 'v1:%' FROM ledger_transactions
            WHERE id = current_setting('smoke.funding_tx')::uuid);
    ASSERT ledger_balance(customer_usd)::text = '700 USD';
    ASSERT ledger_balance(merchant_usd)::text = '100 USD';
    ASSERT (ledger_account('customer:eur')).balance::text = '170 EUR';
    ASSERT (SELECT count(*) FROM ledger_entries(current_setting('smoke.exchange_tx')::uuid)) = 4;
    ASSERT (ledger_transaction(current_setting('smoke.exchange_tx')::uuid)).event_at
        = '2026-01-02 03:04:05+00'::timestamptz;
    ASSERT ledger_balance(current_setting('smoke.fee_recipient')::uuid)::text = '98 USD';
    ASSERT ledger_balance(current_setting('smoke.fee_income')::uuid)::text = '2 USD';
    ASSERT (SELECT count(*) FROM ledger_entries(current_setting('smoke.duplicate_tx')::uuid)) = 4;
    ASSERT current_setting('smoke.duplicate_tx')::uuid
        = current_setting('smoke.duplicate_replay')::uuid;
    ASSERT (SELECT count(*) FROM ledger_entries(current_setting('smoke.duplicate_tx')::uuid)
            WHERE account_id = current_setting('smoke.duplicate_a')::uuid) = 2;
    ASSERT ledger_balance(current_setting('smoke.duplicate_a')::uuid)::text = '0 USD';

    BEGIN
        PERFORM ledger_transfer(
            customer_usd, merchant_usd, '101 USD',
            reference => 'order:42', idempotency_key => 'order:42'
        );
        RAISE EXCEPTION 'expected idempotency conflict';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    BEGIN
        PERFORM ledger_post(ARRAY[
            ledger_posting(customer_usd, '-1 USD'),
            ledger_posting(merchant_usd, '0.50 USD')
        ]);
        RAISE EXCEPTION 'expected unbalanced transaction failure';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
END
$body$;

SELECT ledger_reverse(:'payment_tx'::uuid) AS reversal_tx \gset
SELECT ledger_reverse(:'duplicate_tx'::uuid) AS duplicate_reversal_tx \gset

SELECT set_config('smoke.reversal_tx', :'reversal_tx', false);

DO $body$
DECLARE
    customer_usd uuid := current_setting('smoke.customer_usd')::uuid;
    merchant_usd uuid := current_setting('smoke.merchant_usd')::uuid;
    source_usd uuid := current_setting('smoke.source_usd')::uuid;
BEGIN
    ASSERT ledger_balance(customer_usd)::text = '800 USD';
    ASSERT ledger_balance(merchant_usd)::text = '0 USD';
    ASSERT (ledger_transaction(current_setting('smoke.reversal_tx')::uuid)).reverses_transaction_id
        = current_setting('smoke.payment_tx')::uuid;
    ASSERT ledger_balance(current_setting('smoke.duplicate_a')::uuid)::text = '0 USD';
    ASSERT (ledger_account(current_setting('smoke.duplicate_a')::uuid)).version = 4;

    BEGIN
        PERFORM ledger_transfer(merchant_usd, source_usd, '1 USD');
        RAISE EXCEPTION 'expected non-negative balance policy failure';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    ASSERT NOT EXISTS (SELECT 1 FROM ledger_validate() WHERE status <> 'OK');
END
$body$;

CREATE ROLE ledger_app;
GRANT USAGE ON SCHEMA public TO ledger_app;
SET ROLE ledger_app;

DO $body$
BEGIN
    ASSERT NOT has_function_privilege(
        current_user,
        '_ledger_post_rust(ledger_posting[],text,text,timestamptz,jsonb,uuid)',
        'EXECUTE'
    );
    ASSERT NOT has_function_privilege(
        current_user,
        '_ledger_transfer_rust(uuid,uuid,ledger_amount,text,text,timestamptz,jsonb)',
        'EXECUTE'
    );
    ASSERT NOT has_function_privilege(
        current_user,
        '_ledger_reverse_rust(uuid,text,text,timestamptz,jsonb)',
        'EXECUTE'
    );
END
$body$;

SELECT ledger_create_account('app:usd', 'USD', 'NON_NEGATIVE');

DO $body$
BEGIN
    BEGIN
        UPDATE ledger_entries SET account_version = 999;
        RAISE EXCEPTION 'expected entries mutation to be forbidden';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        UPDATE ledger_accounts SET balance = '999 USD';
        RAISE EXCEPTION 'expected account balance mutation to be forbidden';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        UPDATE ledger_transactions SET reference = 'tampered';
        RAISE EXCEPTION 'expected transaction mutation to be forbidden';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END
$body$;

RESET ROLE;
REVOKE ALL ON SCHEMA public FROM ledger_app;
DROP ROLE ledger_app;

SELECT check_name, status, violations FROM ledger_validate() ORDER BY check_name;
