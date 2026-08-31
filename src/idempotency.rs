use pgrx::{JsonB, prelude::*};
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::errors::fail_internal;
use crate::transaction::PostRequest;

const FINGERPRINT_VERSION: u8 = 1;

#[derive(Serialize)]
struct PostingFingerprint {
    account_id: String,
    amount: String,
}

#[derive(Serialize)]
struct VersionedFingerprint<'a> {
    version: u8,
    postings: &'a [PostingFingerprint],
    reference: Option<&'a str>,
    event_at: Option<pg_sys::TimestampTz>,
    metadata: Option<&'a JsonB>,
    reverses_transaction_id: Option<String>,
}

// Kept byte-for-byte compatible with the original unversioned fingerprint so
// retries can still resolve transactions created before fingerprint versioning.
#[derive(Serialize)]
struct LegacyFingerprint<'a> {
    postings: &'a [PostingFingerprint],
    reference: Option<&'a str>,
    event_at: Option<pg_sys::TimestampTz>,
    metadata: Option<&'a JsonB>,
    reverses_transaction_id: Option<String>,
}

pub(crate) struct PayloadHashes {
    pub(crate) current: String,
    pub(crate) legacy: String,
}

fn digest<T: Serialize>(value: &T) -> String {
    let bytes = serde_json::to_vec(value)
        .unwrap_or_else(|error| fail_internal(&format!("could not serialize request: {error}")));
    hex::encode(Sha256::digest(bytes))
}

pub(crate) fn payload_hashes(request: &PostRequest<'_>) -> PayloadHashes {
    let mut postings = request
        .postings
        .iter()
        .map(|posting| PostingFingerprint {
            account_id: posting.account_id().to_string(),
            amount: posting.amount_ref().to_string(),
        })
        .collect::<Vec<_>>();
    postings.sort_by(|left, right| {
        left.account_id
            .cmp(&right.account_id)
            .then_with(|| left.amount.cmp(&right.amount))
    });

    let event_at = request.event_at.map(pg_sys::TimestampTz::from);
    let reverses_transaction_id = request
        .reverses_transaction_id
        .map(|transaction_id| transaction_id.to_string());

    let current = VersionedFingerprint {
        version: FINGERPRINT_VERSION,
        postings: &postings,
        reference: request.reference,
        event_at,
        metadata: request.metadata,
        reverses_transaction_id: reverses_transaction_id.clone(),
    };
    let legacy = LegacyFingerprint {
        postings: &postings,
        reference: request.reference,
        event_at,
        metadata: request.metadata,
        reverses_transaction_id,
    };

    PayloadHashes {
        current: format!("v{FINGERPRINT_VERSION}:{}", digest(&current)),
        legacy: digest(&legacy),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::amount::ledger_amount;
    use crate::posting::ledger_posting;

    fn request(postings: Vec<ledger_posting>) -> PostRequest<'static> {
        PostRequest {
            postings,
            reference: Some("test"),
            idempotency_key: Some("test:1"),
            event_at: None,
            metadata: None,
            reverses_transaction_id: None,
        }
    }

    #[test]
    fn fingerprints_are_versioned_and_posting_order_independent() {
        let first = ledger_posting::new(
            pgrx::Uuid::from_bytes([1; 16]),
            ledger_amount::parse("-1 USD").unwrap(),
        );
        let second = ledger_posting::new(
            pgrx::Uuid::from_bytes([2; 16]),
            ledger_amount::parse("1 USD").unwrap(),
        );
        let forward = payload_hashes(&request(vec![first.clone(), second.clone()]));
        let reversed = payload_hashes(&request(vec![second, first]));

        assert!(forward.current.starts_with("v1:"));
        assert!(!forward.legacy.contains(':'));
        assert_eq!(forward.current, reversed.current);
        assert_eq!(forward.legacy, reversed.legacy);
    }
}
