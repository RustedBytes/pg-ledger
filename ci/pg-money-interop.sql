\set ON_ERROR_STOP on

CREATE EXTENSION pg_money;
CREATE EXTENSION pg_ledger;

DO $body$
BEGIN
    ASSERT ledger_enable_pg_money();
    ASSERT to_regprocedure('ledger_amount(money_minor)') IS NOT NULL;
    ASSERT to_regprocedure('ledger_to_money_minor(ledger_amount)') IS NOT NULL;
    ASSERT to_regprocedure('ledger_amount(money_with_currency)') IS NOT NULL;
    ASSERT to_regprocedure('ledger_to_money(ledger_amount)') IS NOT NULL;
    ASSERT ledger_amount('USD 12.34'::money_minor)::text = '12.34 USD';
    ASSERT ledger_to_money_minor('12.34 USD'::ledger_amount)::text = 'USD 12.34';
    ASSERT ledger_amount('USD 12.34'::money_with_currency)::text = '12.34 USD';
    ASSERT ledger_to_money('12.34 USD'::ledger_amount)::text = 'USD 12.34';
END
$body$;
