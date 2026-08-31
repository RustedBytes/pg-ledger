#![allow(clippy::needless_pass_by_value)]

use pgrx::StringInfo;
use pgrx::prelude::*;
use serde::{Deserialize, Serialize};
use std::ffi::CStr;
use std::fmt::{Display, Formatter};

use crate::amount::ledger_amount;
use crate::errors::{fail_input, fail_parameter};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, PostgresType, PostgresEq)]
#[inoutfuncs]
#[pg_binary_protocol]
#[allow(non_camel_case_types)]
pub struct ledger_posting {
    account_id: uuid::Uuid,
    amount: ledger_amount,
}

impl ledger_posting {
    pub(crate) fn new(account_id: pgrx::Uuid, amount: ledger_amount) -> Self {
        Self {
            account_id: uuid::Uuid::from_bytes(*account_id.as_bytes()),
            amount,
        }
    }

    fn parse(input: &str) -> Result<Self, String> {
        let (account, amount) = input
            .split_once('|')
            .ok_or_else(|| "expected '<account-uuid>|<amount> <asset>'".to_owned())?;
        let account_id = uuid::Uuid::parse_str(account)
            .map_err(|_| "posting account identifier is not a UUID".to_owned())?;
        Ok(Self {
            account_id,
            amount: ledger_amount::parse(amount)?,
        })
    }

    fn account_uuid(&self) -> pgrx::Uuid {
        pgrx::Uuid::from_bytes(*self.account_id.as_bytes())
    }

    pub(crate) fn account_id(&self) -> uuid::Uuid {
        self.account_id
    }

    pub(crate) fn amount_ref(&self) -> &ledger_amount {
        &self.amount
    }

    pub(crate) fn into_parts(self) -> (pgrx::Uuid, ledger_amount) {
        (self.account_uuid(), self.amount)
    }

    fn canonical(&self) -> String {
        format!("{}|{}", self.account_id, self.amount)
    }
}

impl Display for ledger_posting {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.canonical())
    }
}

impl InOutFuncs for ledger_posting {
    fn input(input: &CStr) -> Self {
        let text = input.to_str().unwrap_or_else(|_| {
            fail_input(
                "ledger_posting",
                "input is not UTF-8",
                "Use '<account-uuid>|<amount> <asset>'.",
            )
        });
        Self::parse(text).unwrap_or_else(|error| {
            fail_input(
                "ledger_posting",
                &error,
                "Prefer ledger_posting(account_id, amount).",
            )
        })
    }
    fn output(&self, buffer: &mut StringInfo) {
        buffer.push_str(&self.canonical());
    }
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_posting(account_id: pgrx::Uuid, amount: ledger_amount) -> ledger_posting {
    ledger_posting::new(account_id, amount)
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_entry(account_id: pgrx::Uuid, amount: ledger_amount) -> ledger_posting {
    ledger_posting::new(account_id, amount)
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_posting_account_id(value: ledger_posting) -> pgrx::Uuid {
    value.account_uuid()
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_posting_amount(value: ledger_posting) -> ledger_amount {
    value.amount
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_posting_negate(value: ledger_posting) -> ledger_posting {
    ledger_posting {
        account_id: value.account_id,
        amount: crate::amount::ledger_negate(value.amount),
    }
}

#[pg_cast(assignment, immutable, parallel_safe)]
pub fn ledger_posting_to_text(value: ledger_posting) -> String {
    value.canonical()
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_posting_parse(input: &str) -> ledger_posting {
    ledger_posting::parse(input).unwrap_or_else(|error| fail_parameter(&error))
}
