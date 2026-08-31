#![allow(clippy::needless_pass_by_value)]

use pgrx::StringInfo;
use pgrx::prelude::*;
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize};
use std::ffi::CStr;
use std::fmt::{Display, Formatter};

use crate::errors::{fail_input, fail_parameter};

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, PostgresEnum,
)]
#[allow(non_camel_case_types)]
pub enum ledger_asset_kind {
    fiat,
    crypto,
}

#[derive(
    Debug,
    Clone,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    Hash,
    Serialize,
    PostgresType,
    PostgresEq,
    PostgresOrd,
    PostgresHash,
)]
#[inoutfuncs]
#[pg_binary_protocol]
#[allow(non_camel_case_types)]
pub struct ledger_asset {
    version: u8,
    kind: ledger_asset_kind,
    symbol: String,
    network: Option<String>,
    scale: u8,
}

impl<'de> Deserialize<'de> for ledger_asset {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct WireAsset {
            version: u8,
            kind: ledger_asset_kind,
            symbol: String,
            network: Option<String>,
            scale: u8,
        }

        let wire = WireAsset::deserialize(deserializer)?;
        if wire.version != 1 {
            return Err(D::Error::custom(format!(
                "unsupported ledger_asset binary version {}",
                wire.version
            )));
        }
        validate_symbol(&wire.symbol).map_err(D::Error::custom)?;
        if wire.symbol != wire.symbol.to_ascii_uppercase() {
            return Err(D::Error::custom("asset symbol is not canonical uppercase"));
        }
        match (&wire.kind, &wire.network) {
            (ledger_asset_kind::fiat, None) => {}
            (ledger_asset_kind::crypto, Some(network)) => {
                validate_network(network).map_err(D::Error::custom)?;
                if network != &network.to_ascii_lowercase() {
                    return Err(D::Error::custom("asset network is not canonical lowercase"));
                }
                if let Some(canonical_scale) = crypto_scale(&wire.symbol, network)
                    && wire.scale != canonical_scale
                {
                    return Err(D::Error::custom(format!(
                        "{}@{} has canonical scale {}",
                        wire.symbol, network, canonical_scale
                    )));
                }
            }
            _ => return Err(D::Error::custom("asset kind and network are inconsistent")),
        }
        Ok(Self {
            version: 1,
            kind: wire.kind,
            symbol: wire.symbol,
            network: wire.network,
            scale: wire.scale,
        })
    }
}

impl ledger_asset {
    pub(crate) fn parse(input: &str) -> Result<Self, String> {
        if input.len() > 128 {
            return Err("asset identifier exceeds 128 bytes".to_owned());
        }
        if let Some(rest) = input.strip_prefix("v1|") {
            return Self::parse_canonical(rest);
        }
        let input = input.trim();
        let (identity, explicit_scale) = match input.rsplit_once('/') {
            Some((identity, scale)) if scale.bytes().all(|byte| byte.is_ascii_digit()) => {
                let scale = scale
                    .parse::<u8>()
                    .map_err(|_| "asset scale must be between 0 and 255")?;
                (identity, Some(scale))
            }
            _ => (input, None),
        };
        let (symbol, network) = match identity.split_once('@') {
            Some((symbol, network)) => (symbol, Some(network)),
            None => (identity, None),
        };
        validate_symbol(symbol)?;
        let symbol = symbol.to_ascii_uppercase();
        if let Some(network) = network {
            validate_network(network)?;
            let network = network.to_ascii_lowercase();
            let canonical_scale = crypto_scale(&symbol, &network);
            if let (Some(provided), Some(canonical)) = (explicit_scale, canonical_scale)
                && provided != canonical
            {
                return Err(format!(
                    "{symbol}@{network} has canonical scale {canonical}"
                ));
            }
            let scale = explicit_scale
                .or(canonical_scale)
                .ok_or_else(|| {
                    format!(
                        "unknown crypto asset {symbol}@{network}; append '/<decimals>' to declare its scale"
                    )
                })?;
            Ok(Self {
                version: 1,
                kind: ledger_asset_kind::crypto,
                symbol,
                network: Some(network),
                scale,
            })
        } else if let Some((network, scale)) = native_crypto(&symbol) {
            if explicit_scale.is_some_and(|provided| provided != scale) {
                return Err(format!("{symbol} has canonical scale {scale}"));
            }
            Ok(Self {
                version: 1,
                kind: ledger_asset_kind::crypto,
                symbol,
                network: Some(network.to_owned()),
                scale,
            })
        } else if symbol.len() == 3 && symbol.bytes().all(|byte| byte.is_ascii_alphabetic()) {
            Ok(Self {
                version: 1,
                kind: ledger_asset_kind::fiat,
                scale: explicit_scale.unwrap_or_else(|| fiat_scale(&symbol)),
                symbol,
                network: None,
            })
        } else {
            Err("fiat assets use a 3-letter code; crypto assets require a network".to_owned())
        }
    }

    fn parse_canonical(rest: &str) -> Result<Self, String> {
        let fields = rest.split('|').collect::<Vec<_>>();
        if fields.len() != 4 {
            return Err(
                "canonical asset must be v1|<kind>|<symbol>|<network-or->|<scale>".to_owned(),
            );
        }
        let kind = match fields[0] {
            "fiat" => ledger_asset_kind::fiat,
            "crypto" => ledger_asset_kind::crypto,
            _ => return Err("asset kind must be fiat or crypto".to_owned()),
        };
        validate_symbol(fields[1])?;
        let symbol = fields[1].to_ascii_uppercase();
        let scale = fields[3]
            .parse::<u8>()
            .map_err(|_| "asset scale must be between 0 and 255".to_owned())?;
        let network = match kind {
            ledger_asset_kind::fiat if fields[2] == "-" => None,
            ledger_asset_kind::crypto => {
                validate_network(fields[2])?;
                Some(fields[2].to_ascii_lowercase())
            }
            ledger_asset_kind::fiat => return Err("fiat assets cannot have a network".to_owned()),
        };
        if let Some(network) = &network
            && let Some(canonical_scale) = crypto_scale(&symbol, network)
            && scale != canonical_scale
        {
            return Err(format!(
                "{symbol}@{network} has canonical scale {canonical_scale}"
            ));
        }
        Ok(Self {
            version: 1,
            kind,
            symbol,
            network,
            scale,
        })
    }

    pub(crate) fn canonical(&self) -> String {
        match &self.network {
            Some(network) if crypto_scale(&self.symbol, network) == Some(self.scale) => {
                format!("{}@{}", self.symbol, network)
            }
            Some(network) => format!("{}@{}/{}", self.symbol, network, self.scale),
            None if fiat_scale(&self.symbol) == self.scale => self.symbol.clone(),
            None => format!("{}/{}", self.symbol, self.scale),
        }
    }

    pub(crate) fn scale(&self) -> u8 {
        self.scale
    }
}

impl Display for ledger_asset {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.canonical())
    }
}

impl InOutFuncs for ledger_asset {
    fn input(input: &CStr) -> Self {
        let text = input.to_str().unwrap_or_else(|_| {
            fail_input(
                "ledger_asset",
                "input is not UTF-8",
                "Use 'USD', 'BTC', or 'USDC@ethereum'.",
            )
        });
        Self::parse(text).unwrap_or_else(|error| {
            fail_input(
                "ledger_asset",
                &error,
                "Use 'USD', 'BTC', 'USDC@ethereum', or 'TOKEN@network/decimals'.",
            )
        })
    }

    fn output(&self, buffer: &mut StringInfo) {
        buffer.push_str(&self.canonical());
    }
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_asset(input: &str) -> ledger_asset {
    ledger_asset::parse(input).unwrap_or_else(|error| fail_parameter(&error))
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_asset_kind(value: ledger_asset) -> ledger_asset_kind {
    value.kind
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_asset_symbol(value: ledger_asset) -> String {
    value.symbol
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_asset_network(value: ledger_asset) -> Option<String> {
    value.network
}

#[pg_extern(immutable, parallel_safe)]
pub fn ledger_asset_scale(value: ledger_asset) -> i16 {
    i16::from(value.scale)
}

#[pg_cast(assignment, immutable, parallel_safe)]
pub fn ledger_asset_to_text(value: ledger_asset) -> String {
    value.canonical()
}

fn validate_symbol(symbol: &str) -> Result<(), String> {
    if !(2..=16).contains(&symbol.len())
        || !symbol
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(
            "asset symbol must contain 2-16 ASCII letters, digits, '.', '_', or '-'".to_owned(),
        );
    }
    Ok(())
}

fn validate_network(network: &str) -> Result<(), String> {
    if network.is_empty()
        || network.len() > 32
        || !network
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err("network must contain 1-32 ASCII letters, digits, '_' or '-'".to_owned());
    }
    Ok(())
}

fn fiat_scale(symbol: &str) -> u8 {
    if matches!(
        symbol,
        "BIF"
            | "CLP"
            | "DJF"
            | "GNF"
            | "ISK"
            | "JPY"
            | "KMF"
            | "KRW"
            | "PYG"
            | "RWF"
            | "UGX"
            | "UYI"
            | "VND"
            | "VUV"
            | "XAF"
            | "XOF"
            | "XPF"
    ) {
        0
    } else if matches!(symbol, "CLF" | "UYW") {
        4
    } else if matches!(
        symbol,
        "BHD" | "IQD" | "JOD" | "KWD" | "LYD" | "OMR" | "TND"
    ) {
        3
    } else {
        2
    }
}

fn native_crypto(symbol: &str) -> Option<(&'static str, u8)> {
    match symbol {
        "BTC" => Some(("bitcoin", 8)),
        "ETH" => Some(("ethereum", 18)),
        "SOL" => Some(("solana", 9)),
        "TRX" => Some(("tron", 6)),
        "ADA" => Some(("cardano", 6)),
        "DOT" => Some(("polkadot", 10)),
        "AVAX" => Some(("avalanche", 18)),
        _ => None,
    }
}

fn crypto_scale(symbol: &str, network: &str) -> Option<u8> {
    native_crypto(symbol)
        .and_then(|(canonical_network, scale)| (network == canonical_network).then_some(scale))
        .or(match (symbol, network) {
            (
                "USDC" | "USDT",
                "ethereum" | "solana" | "tron" | "arbitrum" | "optimism" | "base" | "polygon"
                | "avalanche",
            ) => Some(6),
            ("ETH", "arbitrum" | "optimism" | "base") | ("DAI", "ethereum") => Some(18),
            _ => None,
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_fiat_and_native_crypto() {
        assert_eq!(ledger_asset::parse("USD").unwrap().scale(), 2);
        let btc = ledger_asset::parse("BTC").unwrap();
        assert_eq!(btc.canonical(), "BTC@bitcoin");
        assert_eq!(btc.scale(), 8);
        assert_eq!(
            ledger_asset::parse("TOK@chain/7").unwrap().canonical(),
            "TOK@chain/7"
        );
        assert!(ledger_asset::parse("BTC@bitcoin/9").is_err());
        assert!(ledger_asset::parse("v1|crypto|BTC|bitcoin|9").is_err());
        assert_eq!(
            ledger_asset::parse("v1|crypto|BTC|bitcoin|8")
                .unwrap()
                .canonical(),
            "BTC@bitcoin"
        );
    }
}
