SELECT ledger_transfer(
    (ledger_account('race:idempotency:matching:source')).id,
    (ledger_account('race:idempotency:matching:destination')).id,
    '1 USD',
    reference => 'matching idempotency race',
    idempotency_key => 'race:idempotency:matching',
    event_at => '2026-08-31 00:00:00+00'
);
