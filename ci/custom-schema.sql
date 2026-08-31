\set ON_ERROR_STOP on

CREATE SCHEMA accounting;
CREATE EXTENSION pg_ledger SCHEMA accounting;
SET search_path = accounting, pg_catalog;

SELECT ledger_create_account('schema:a', 'USD', 'ANY') AS account_a \gset
SELECT ledger_create_account('schema:b', 'USD', 'ANY') AS account_b \gset
SELECT ledger_transfer(:'account_a'::uuid, :'account_b'::uuid, '1 USD');

DO $body$
BEGIN
    ASSERT (ledger_account('schema:a')).balance::text = '-1 USD';
    ASSERT (ledger_account('schema:b')).balance::text = '1 USD';
    ASSERT NOT EXISTS (SELECT 1 FROM ledger_validate() WHERE status <> 'OK');
END
$body$;
