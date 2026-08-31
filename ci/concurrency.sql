\set direction random(0, 1)
SELECT ledger_transfer(
    (ledger_account(CASE WHEN :direction = 0 THEN 'concurrency:a' ELSE 'concurrency:b' END)).id,
    (ledger_account(CASE WHEN :direction = 0 THEN 'concurrency:b' ELSE 'concurrency:a' END)).id,
    '0.01 USD'
);
