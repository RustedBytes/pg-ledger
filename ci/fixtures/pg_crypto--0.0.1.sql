CREATE DOMAIN crypto_amount AS text;

CREATE FUNCTION crypto_amount_value(value crypto_amount)
RETURNS numeric
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS 'SELECT split_part(value::text, '' '', 1)::numeric';

CREATE FUNCTION crypto_amount_symbol(value crypto_amount)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS 'SELECT split_part(split_part(value::text, '' '', 2), ''@'', 1)';

CREATE FUNCTION crypto_amount_network(value crypto_amount)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $body$
    SELECT CASE
        WHEN strpos(split_part(value::text, ' ', 2), '@') > 0
        THEN split_part(split_part(value::text, ' ', 2), '@', 2)
        WHEN crypto_amount_symbol(value) = 'BTC' THEN 'bitcoin'
        WHEN crypto_amount_symbol(value) = 'ETH' THEN 'ethereum'
        ELSE 'unknown'
    END
$body$;

CREATE FUNCTION crypto_amount_decimals(value crypto_amount)
RETURNS integer
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $body$
    SELECT CASE crypto_amount_symbol(value)
        WHEN 'BTC' THEN 8
        WHEN 'ETH' THEN 18
        WHEN 'USDC' THEN 6
        ELSE 8
    END
$body$;
