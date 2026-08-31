ALTER FUNCTION @extschema@.ledger_enable_pg_crypto()
    RENAME TO ledger_enable_pg_cryptocurrency;

CREATE OR REPLACE FUNCTION @extschema@.ledger_enable_pg_cryptocurrency()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    ledger_schema name;
    crypto_schema name;
BEGIN
    SELECT n.nspname INTO ledger_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_ledger';
    SELECT n.nspname INTO crypto_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_cryptocurrency';
    IF ledger_schema IS NULL OR crypto_schema IS NULL THEN RETURN false; END IF;
    EXECUTE format(
        'CREATE OR REPLACE FUNCTION %I.ledger_amount(value %I.crypto_amount) RETURNS %I.ledger_amount '
        'LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS %L',
        ledger_schema, crypto_schema, ledger_schema,
        format(
            'SELECT %I.ledger_amount(format(''%%s %%s@%%s/%%s'', '
            ' %I.crypto_amount_value(value), %I.crypto_amount_symbol(value), '
            ' %I.crypto_amount_network(value), %I.crypto_amount_decimals(value)))',
            ledger_schema, crypto_schema, crypto_schema, crypto_schema, crypto_schema
        )
    );
    EXECUTE format(
        $create$
        CREATE OR REPLACE FUNCTION %I.ledger_to_crypto(value %I.ledger_amount)
        RETURNS %I.crypto_amount
        LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
        AS $function$
        BEGIN
            IF %I.ledger_asset_kind(%I.ledger_amount_asset(value)) <> 'crypto' THEN
                RAISE EXCEPTION 'ledger amount is not a cryptocurrency amount'
                    USING ERRCODE = '22023';
            END IF;
            RETURN format('%%s %%s@%%s',
                %I.ledger_amount_value(value),
                %I.ledger_asset_symbol(%I.ledger_amount_asset(value)),
                %I.ledger_asset_network(%I.ledger_amount_asset(value))
            )::%I.crypto_amount;
        END
        $function$
        $create$,
        ledger_schema, ledger_schema, crypto_schema,
        ledger_schema, ledger_schema,
        ledger_schema,
        ledger_schema, ledger_schema,
        ledger_schema, ledger_schema,
        crypto_schema
    );
    RETURN true;
END
$body$;

SELECT @extschema@.ledger_enable_pg_cryptocurrency();
