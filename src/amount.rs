#![allow(clippy::needless_pass_by_value)]

use num_bigint::BigInt;
use num_traits::{Signed, Zero};
use pgrx::prelude::*;
use pgrx::{AnyNumeric, StringInfo};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::ffi::CStr;
use std::fmt::{Display, Formatter};

use crate::asset::ledger_asset;
use crate::errors::{fail_input, fail_parameter};

#[derive(
    Debug,
    Clone,
    PartialEq,
    Eq,
    Hash,
    Serialize,
    Deserialize,
    PostgresType,
    PostgresEq,
    PostgresOrd,
    PostgresHash,
)]
#[inoutfuncs]
#[pg_binary_protocol]
#[allow(non_camel_case_types)]
pub struct ledger_amount {
    asset: ledger_asset,
    units: BigInt,
}

impl ledger_amount {
    pub(crate) fn new(asset: ledger_asset, units: BigInt) -> Self {
        Self { asset, units }
    }

    pub(crate) fn asset_ref(&self) -> &ledger_asset {
        &self.asset
    }

    pub(crate) fn units_ref(&self) -> &BigInt {
        &self.units
    }

    pub(crate) fn checked_add(&self, other: &Self) -> Result<Self, String> {
        self.require_same_asset(other)?;
        Ok(Self::new(self.asset.clone(), &self.units + &other.units))
    }

    pub(crate) fn parse(input: &str) -> Result<Self, String> {
        if input.len() > 640 {
            return Err("ledger amount input exceeds 640 bytes".to_owned());
        }
        let parts = input.split_ascii_whitespace().collect::<Vec<_>>();
        if parts.len() != 2 {
            return Err("expected '<amount> <asset>' or '<asset> <amount>'".to_owned());
        }
        let first_numeric = looks_numeric(parts[0]);
        let second_numeric = looks_numeric(parts[1]);
        let (number, asset_text) = match (first_numeric, second_numeric) {
            (true, false) => (parts[0], parts[1]),
            (false, true) => (parts[1], parts[0]),
            _ => return Err("expected exactly one decimal amount and one asset".to_owned()),
        };
        let asset = ledger_asset::parse(asset_text)?;
        let units = decimal_to_units(number, asset.scale())?;
        Ok(Self::new(asset, units))
    }

    pub(crate) fn require_same_asset(&self, other: &Self) -> Result<(), String> {
        if self.asset == other.asset {
            Ok(())
        } else {
            Err(format!(
                "ledger asset mismatch: {} and {}",
                self.asset, other.asset
            ))
        }
    }
    pub(crate) fn canonical(&self) -> String {
        format!(
            "{} {}",
            units_to_decimal(&self.units, self.asset.scale()),
            self.asset
        )
    }
}

impl PartialOrd for ledger_amount {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ledger_amount {
    fn cmp(&self, other: &Self) -> Ordering {
        self.asset
            .cmp(&other.asset)
            .then_with(|| self.units.cmp(&other.units))
    }
}

impl Display for ledger_amount {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.canonical())
    }
}

impl InOutFuncs for ledger_amount {
    fn input(input: &CStr) -> Self {
        let text = input.to_str().unwrap_or_else(|_| {
            fail_input(
                "ledger_amount",
                "input is not UTF-8",
                "Use '100.00 USD' or '0.025 BTC'.",
            )
        });
        Self::parse(text).unwrap_or_else(|error| {
            fail_input(
                "ledger_amount",
                &error,
                "Use '100.00 USD', 'USD 100.00', or '0.025 BTC'.",
            )
        })
    }
    fn output(&self, buffer: &mut StringInfo) {
        buffer.push_str(&self.canonical());
    }
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_amount(input: &str) -> ledger_amount {
    ledger_amount::parse(input).unwrap_or_else(|error| fail_parameter(&error))
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_amount_from_units(units: AnyNumeric, asset: ledger_asset) -> ledger_amount {
    let units = parse_integer(&units.to_string()).unwrap_or_else(|error| fail_parameter(&error));
    ledger_amount::new(asset, units)
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_amount_zero(asset: ledger_asset) -> ledger_amount {
    ledger_amount::new(asset, BigInt::ZERO)
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_amount_asset(value: ledger_amount) -> ledger_asset {
    value.asset
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_amount_units(value: ledger_amount) -> AnyNumeric {
    AnyNumeric::try_from(value.units.to_string().as_str()).unwrap_or_else(|error| {
        fail_parameter(&format!("could not produce PostgreSQL numeric: {error}"))
    })
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_amount_value(value: ledger_amount) -> AnyNumeric {
    let scale = usize::from(value.asset.scale());
    let decimal = units_to_decimal(&value.units, value.asset.scale());
    let text = if scale == 0 {
        value.units.to_string()
    } else {
        decimal
    };
    AnyNumeric::try_from(text.as_str()).unwrap_or_else(|error| {
        fail_parameter(&format!("could not produce PostgreSQL numeric: {error}"))
    })
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_amount_is_zero(value: ledger_amount) -> bool {
    value.units.is_zero()
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_amount_is_positive(value: ledger_amount) -> bool {
    value.units.is_positive()
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_amount_is_negative(value: ledger_amount) -> bool {
    value.units.is_negative()
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_add(left: ledger_amount, right: ledger_amount) -> ledger_amount {
    left.require_same_asset(&right)
        .unwrap_or_else(|error| fail_parameter(&error));
    ledger_amount::new(left.asset, left.units + right.units)
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_subtract(left: ledger_amount, right: ledger_amount) -> ledger_amount {
    left.require_same_asset(&right)
        .unwrap_or_else(|error| fail_parameter(&error));
    ledger_amount::new(left.asset, left.units - right.units)
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_negate(value: ledger_amount) -> ledger_amount {
    ledger_amount::new(value.asset, -value.units)
}

#[pg_cast(assignment, immutable, parallel_safe)]
pub fn ledger_amount_to_text(value: ledger_amount) -> String {
    value.canonical()
}

fn looks_numeric(input: &str) -> bool {
    let unsigned = input.strip_prefix(['+', '-']).unwrap_or(input);
    !unsigned.is_empty()
        && unsigned
            .bytes()
            .all(|byte| byte.is_ascii_digit() || byte == b'.')
}

fn decimal_to_units(input: &str, scale: u8) -> Result<BigInt, String> {
    let (negative, unsigned) = if let Some(rest) = input.strip_prefix('-') {
        (true, rest)
    } else {
        (false, input.strip_prefix('+').unwrap_or(input))
    };
    let mut pieces = unsigned.split('.');
    let whole = pieces.next().unwrap_or_default();
    let fraction = pieces.next().unwrap_or_default();
    if pieces.next().is_some()
        || whole.is_empty()
        || !whole.bytes().all(|b| b.is_ascii_digit())
        || !fraction.bytes().all(|b| b.is_ascii_digit())
    {
        return Err("amount must be a plain signed decimal".to_owned());
    }
    if fraction.len() > usize::from(scale) {
        return Err(format!(
            "amount has more than {scale} fractional digits for this asset"
        ));
    }
    let mut digits = String::with_capacity(whole.len() + usize::from(scale));
    digits.push_str(whole);
    digits.push_str(fraction);
    digits.extend(std::iter::repeat_n(
        '0',
        usize::from(scale) - fraction.len(),
    ));
    let mut units = parse_integer(&digits)?;
    if negative {
        units = -units;
    }
    Ok(units)
}

fn parse_integer(input: &str) -> Result<BigInt, String> {
    BigInt::parse_bytes(input.as_bytes(), 10).ok_or_else(|| "units must be an integer".to_owned())
}

fn units_to_decimal(units: &BigInt, scale: u8) -> String {
    if units.is_zero() {
        return "0".to_owned();
    }
    let negative = units.is_negative();
    let digits = units.abs().to_str_radix(10);
    if scale == 0 {
        return format!("{}{digits}", if negative { "-" } else { "" });
    }
    let scale = usize::from(scale);
    let mut output = if digits.len() <= scale {
        format!("0.{}{}", "0".repeat(scale - digits.len()), digits)
    } else {
        let point = digits.len() - scale;
        format!("{}.{}", &digits[..point], &digits[point..])
    };
    while output.ends_with('0') {
        output.pop();
    }
    if output.ends_with('.') {
        output.pop();
    }
    if negative {
        output.insert(0, '-');
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_to_exact_smallest_units() {
        let usd = ledger_amount::parse("USD 12.34").unwrap();
        assert_eq!(usd.units.to_string(), "1234");
        assert_eq!(usd.canonical(), "12.34 USD");
        let btc = ledger_amount::parse("1.00000001 BTC").unwrap();
        assert_eq!(btc.units.to_string(), "100000001");
        assert_eq!(btc.canonical(), "1.00000001 BTC@bitcoin");
    }
}
