CREATE CAST (varchar AS ledger_asset) WITH INOUT;
CREATE CAST (varchar AS ledger_amount) WITH INOUT;
CREATE CAST (varchar AS ledger_posting) WITH INOUT;

CREATE OPERATOR + (
    LEFTARG = ledger_amount,
    RIGHTARG = ledger_amount,
    FUNCTION = ledger_add
);

CREATE OPERATOR - (
    LEFTARG = ledger_amount,
    RIGHTARG = ledger_amount,
    FUNCTION = ledger_subtract
);

CREATE OPERATOR - (
    RIGHTARG = ledger_amount,
    FUNCTION = ledger_negate
);

CREATE TABLE ledger_accounts (
    id uuid PRIMARY KEY DEFAULT ledger_uuidv7(),
    name text NOT NULL UNIQUE CHECK (btrim(name) = name AND name <> ''),
    asset ledger_asset NOT NULL,
    balance ledger_amount NOT NULL,
    version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
    balance_policy ledger_balance_policy NOT NULL DEFAULT 'NON_NEGATIVE',
    metadata jsonb,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (ledger_amount_asset(balance) = asset)
);

COMMENT ON TABLE ledger_accounts IS
    'Ledger accounts with an atomically maintained balance and monotonically increasing version';
COMMENT ON COLUMN ledger_accounts.balance IS
    'Cached balance; ledger_entries remain the accounting source of truth';

CREATE TABLE ledger_transactions (
    id uuid PRIMARY KEY DEFAULT ledger_uuidv7(),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    event_at timestamptz NOT NULL,
    reference text,
    idempotency_key text UNIQUE,
    payload_hash text NOT NULL,
    reverses_transaction_id uuid UNIQUE REFERENCES ledger_transactions(id),
    metadata jsonb
);

CREATE TABLE ledger_entries (
    id uuid PRIMARY KEY DEFAULT ledger_uuidv7(),
    transaction_id uuid NOT NULL REFERENCES ledger_transactions(id),
    account_id uuid NOT NULL REFERENCES ledger_accounts(id),
    amount ledger_amount NOT NULL,
    account_version bigint NOT NULL CHECK (account_version > 0),
    previous_balance ledger_amount NOT NULL,
    current_balance ledger_amount NOT NULL,
    created_at timestamptz NOT NULL,
    UNIQUE (account_id, account_version),
    CHECK (NOT ledger_amount_is_zero(amount)),
    CHECK (ledger_amount_asset(amount) = ledger_amount_asset(previous_balance)),
    CHECK (ledger_amount_asset(amount) = ledger_amount_asset(current_balance)),
    CHECK (previous_balance + amount = current_balance)
);

COMMENT ON TABLE ledger_entries IS
    'Immutable journal entries; corrections are represented by reversal transactions';

CREATE FUNCTION ledger_posting(account_name text, amount ledger_amount)
RETURNS ledger_posting
LANGUAGE plpgsql STABLE STRICT PARALLEL SAFE
SET search_path = @extschema@, pg_catalog
AS $body$
DECLARE
    account_id uuid;
BEGIN
    SELECT id INTO account_id FROM ledger_accounts WHERE name = account_name;
    IF account_id IS NULL THEN
        RAISE EXCEPTION 'ledger account % does not exist', account_name
            USING ERRCODE = '23503';
    END IF;
    RETURN ledger_posting(account_id, amount);
END
$body$;

CREATE FUNCTION ledger_entry(account_name text, amount ledger_amount)
RETURNS ledger_posting
LANGUAGE sql STABLE STRICT PARALLEL SAFE
SET search_path = @extschema@, pg_catalog
AS 'SELECT ledger_posting(account_name, amount)';

CREATE FUNCTION ledger_reject_immutable_change()
RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    RAISE EXCEPTION '% is immutable; post a reversal instead', TG_TABLE_NAME
        USING ERRCODE = '55000';
END
$body$;

CREATE TRIGGER ledger_entries_immutable
BEFORE UPDATE OR DELETE ON ledger_entries
FOR EACH ROW EXECUTE FUNCTION ledger_reject_immutable_change();

CREATE TRIGGER ledger_transactions_immutable
BEFORE UPDATE OR DELETE ON ledger_transactions
FOR EACH ROW EXECUTE FUNCTION ledger_reject_immutable_change();

CREATE FUNCTION ledger_accounts_balance_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    IF current_setting('pg_ledger.internal_posting', true) IS DISTINCT FROM 'on'
       AND ROW(NEW.balance::text, NEW.version)
           IS DISTINCT FROM ROW(OLD.balance::text, OLD.version) THEN
        RAISE EXCEPTION 'ledger account balances can only be changed by the posting engine'
            USING ERRCODE = '55000';
    END IF;
    IF NEW.asset IS DISTINCT FROM OLD.asset THEN
        RAISE EXCEPTION 'ledger account assets are immutable'
            USING ERRCODE = '55000';
    END IF;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END
$body$;

CREATE TRIGGER ledger_accounts_balance_guard
BEFORE UPDATE ON ledger_accounts
FOR EACH ROW EXECUTE FUNCTION ledger_accounts_balance_guard();

CREATE FUNCTION _ledger_post(
    p_postings ledger_posting[],
    p_reference text,
    p_idempotency_key text,
    p_event_at timestamptz,
    p_metadata jsonb,
    p_reverses_transaction_id uuid
) RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
    SELECT _ledger_post_rust(
        p_postings, p_reference, p_idempotency_key, p_event_at,
        p_metadata, p_reverses_transaction_id
    )
$body$;

CREATE FUNCTION ledger_post(
    postings ledger_posting[],
    reference text DEFAULT NULL,
    idempotency_key text DEFAULT NULL,
    event_at timestamptz DEFAULT NULL,
    metadata jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
    SELECT _ledger_post(postings, reference, idempotency_key, event_at, metadata, NULL)
$body$;

CREATE FUNCTION ledger_create_account(
    name text,
    asset ledger_asset,
    balance_policy ledger_balance_policy DEFAULT 'NON_NEGATIVE',
    metadata jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
    INSERT INTO ledger_accounts (name, asset, balance, balance_policy, metadata)
    VALUES (name, asset, ledger_amount_zero(asset), balance_policy, metadata)
    RETURNING id
$body$;

CREATE FUNCTION ledger_transfer(
    from_account uuid,
    to_account uuid,
    amount ledger_amount,
    reference text DEFAULT NULL,
    idempotency_key text DEFAULT NULL,
    event_at timestamptz DEFAULT NULL,
    metadata jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
    SELECT _ledger_transfer_rust(
        from_account, to_account, amount, reference,
        idempotency_key, event_at, metadata
    )
$body$;

CREATE FUNCTION ledger_reverse(
    transaction_id uuid,
    reference text DEFAULT NULL,
    idempotency_key text DEFAULT NULL,
    event_at timestamptz DEFAULT NULL,
    metadata jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
    SELECT _ledger_reverse_rust(
        transaction_id, reference, idempotency_key, event_at, metadata
    )
$body$;

CREATE FUNCTION ledger_account(account_id uuid)
RETURNS ledger_accounts
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = @extschema@, pg_catalog
AS 'SELECT * FROM ledger_accounts WHERE id = account_id';

CREATE FUNCTION ledger_account(account_name text)
RETURNS ledger_accounts
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = @extschema@, pg_catalog
AS 'SELECT * FROM ledger_accounts WHERE name = account_name';

CREATE FUNCTION ledger_balance(account_id uuid)
RETURNS ledger_amount
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = @extschema@, pg_catalog
AS 'SELECT balance FROM ledger_accounts WHERE id = account_id';

CREATE FUNCTION ledger_transaction(transaction_id uuid)
RETURNS ledger_transactions
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = @extschema@, pg_catalog
AS 'SELECT * FROM ledger_transactions WHERE id = transaction_id';

CREATE FUNCTION ledger_entries(transaction_id uuid)
RETURNS SETOF ledger_entries
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = @extschema@, pg_catalog
AS 'SELECT * FROM ledger_entries WHERE ledger_entries.transaction_id = $1 ORDER BY account_id';

CREATE FUNCTION ledger_validate()
RETURNS TABLE(check_name text, status text, violations bigint)
LANGUAGE sql STABLE PARALLEL RESTRICTED
SET search_path = @extschema@, pg_catalog
AS $body$
    SELECT * FROM _ledger_validate_rust()
$body$;

CREATE FUNCTION ledger_enable_pg_money()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    ledger_schema name;
    money_schema name;
    enabled boolean := false;
BEGIN
    SELECT n.nspname INTO ledger_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_ledger';
    SELECT n.nspname INTO money_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_money';
    IF ledger_schema IS NULL OR money_schema IS NULL THEN RETURN false; END IF;

    IF to_regtype(format('%I.money_minor', money_schema)) IS NOT NULL THEN
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION %I.ledger_amount(value %I.money_minor) RETURNS %I.ledger_amount '
            'LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS %L',
            ledger_schema, money_schema, ledger_schema,
            format('SELECT %I.ledger_amount(value::text)', ledger_schema)
        );
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION %I.ledger_to_money_minor(value %I.ledger_amount) '
            'RETURNS %I.money_minor LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS %L',
            ledger_schema, ledger_schema, money_schema,
            format(
                'SELECT format(''%%s %%s'', %I.ledger_asset_symbol(%I.ledger_amount_asset(value)), '
                ' %I.ledger_amount_value(value))::%I.money_minor',
                ledger_schema, ledger_schema, ledger_schema, money_schema
            )
        );
        enabled := true;
    END IF;

    IF to_regtype(format('%I.money_with_currency', money_schema)) IS NOT NULL
       AND to_regprocedure(format('%I.money_make(numeric,text)', money_schema)) IS NOT NULL THEN
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION %I.ledger_amount(value %I.money_with_currency) '
            'RETURNS %I.ledger_amount LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS %L',
            ledger_schema, money_schema, ledger_schema,
            format('SELECT %I.ledger_amount(value::text)', ledger_schema)
        );
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION %I.ledger_to_money(value %I.ledger_amount) '
            'RETURNS %I.money_with_currency LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS %L',
            ledger_schema, ledger_schema, money_schema,
            format(
                'SELECT %I.money_make(%I.ledger_amount_value(value), '
                ' %I.ledger_asset_symbol(%I.ledger_amount_asset(value)))',
                money_schema, ledger_schema, ledger_schema, ledger_schema
            )
        );
        enabled := true;
    END IF;
    RETURN enabled;
END
$body$;

CREATE FUNCTION ledger_enable_pg_crypto()
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
    WHERE e.extname = 'pg_crypto';
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

DO $body$
BEGIN
    PERFORM ledger_enable_pg_money();
    PERFORM ledger_enable_pg_crypto();
END
$body$;
