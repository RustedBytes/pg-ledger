CREATE DOMAIN money_minor AS text;
CREATE DOMAIN money_with_currency AS text;

CREATE FUNCTION money_make(amount numeric, currency text)
RETURNS money_with_currency
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS 'SELECT format(''%s %s'', currency, amount)::money_with_currency';
