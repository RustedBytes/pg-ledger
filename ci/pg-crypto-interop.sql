\set ON_ERROR_STOP on

CREATE EXTENSION pg_crypto;
CREATE EXTENSION pg_ledger;

DO $body$
BEGIN
    ASSERT ledger_enable_pg_crypto();
    ASSERT to_regprocedure('ledger_amount(crypto_amount)') IS NOT NULL;
    ASSERT to_regprocedure('ledger_to_crypto(ledger_amount)') IS NOT NULL;
    ASSERT ledger_amount('1.25 BTC'::crypto_amount)::text = '1.25 BTC@bitcoin';
    ASSERT ledger_amount(ledger_to_crypto('1.25 BTC'::ledger_amount))
        = '1.25 BTC'::ledger_amount;
    ASSERT ledger_amount('1500 USDC@ethereum'::crypto_amount)::text = '1500 USDC@ethereum';
    ASSERT ledger_amount(ledger_to_crypto('1500 USDC@ethereum'::ledger_amount))
        = '1500 USDC@ethereum'::ledger_amount;
END
$body$;
