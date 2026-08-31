\set ON_ERROR_STOP on

-- Frozen representation of a transaction written before payload fingerprints
-- gained their v1: prefix.  UUIDs, timestamps, metadata, and the legacy hash
-- are deliberately constants: changing fingerprint serialization must not
-- silently rewrite this fixture.
INSERT INTO ledger_accounts (
    id, name, asset, balance, version, balance_policy, created_at, updated_at
) VALUES
    ('00000000-0000-0000-0000-000000000101', 'fixture:legacy:source',
     'USD', '-25 USD', 1, 'ANY', '2020-01-01 00:00:00+00', '2020-01-01 00:00:00+00'),
    ('00000000-0000-0000-0000-000000000102', 'fixture:legacy:destination',
     'USD', '25 USD', 1, 'NON_NEGATIVE', '2020-01-01 00:00:00+00', '2020-01-01 00:00:00+00');

INSERT INTO ledger_transactions (
    id, created_at, event_at, reference, idempotency_key, payload_hash, metadata
) VALUES (
    '00000000-0000-0000-0000-000000000201',
    '2020-01-01 00:00:01+00',
    '2020-01-01 00:00:00+00',
    'legacy-fixture',
    'legacy-fixture:1',
    'f90f6f74ba4d2e983285031bcd0d107addd726e126a91c1a1b775498d65c91d2',
    '{"fixture":"legacy-v0"}'
);

INSERT INTO ledger_entries (
    id, transaction_id, account_id, amount, account_version,
    previous_balance, current_balance, created_at
) VALUES
    ('00000000-0000-0000-0000-000000000301',
     '00000000-0000-0000-0000-000000000201',
     '00000000-0000-0000-0000-000000000101',
     '-25 USD', 1, '0 USD', '-25 USD', '2020-01-01 00:00:01+00'),
    ('00000000-0000-0000-0000-000000000302',
     '00000000-0000-0000-0000-000000000201',
     '00000000-0000-0000-0000-000000000102',
     '25 USD', 1, '0 USD', '25 USD', '2020-01-01 00:00:01+00');

SELECT ledger_transfer(
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000102',
    '25 USD',
    reference => 'legacy-fixture',
    idempotency_key => 'legacy-fixture:1',
    event_at => '2020-01-01 00:00:00+00',
    metadata => '{"fixture":"legacy-v0"}'
) AS replayed_transaction \gset

SELECT set_config('fixture.replayed_transaction', :'replayed_transaction', false);

DO $body$
BEGIN
    ASSERT current_setting('fixture.replayed_transaction')::uuid =
        '00000000-0000-0000-0000-000000000201'::uuid;
    ASSERT (SELECT count(*) FROM ledger_transactions
            WHERE idempotency_key = 'legacy-fixture:1') = 1;
    ASSERT (SELECT count(*) FROM ledger_entries
            WHERE transaction_id = current_setting('fixture.replayed_transaction')::uuid) = 2;
    ASSERT ledger_balance('00000000-0000-0000-0000-000000000101')::text = '-25 USD';
    ASSERT ledger_balance('00000000-0000-0000-0000-000000000102')::text = '25 USD';
END
$body$;
