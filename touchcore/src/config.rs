use anyhow::{bail, Result};
use clap::Parser;
use std::fmt;

pub const MAX_SPLITS: usize = 8;

#[derive(Parser)]
pub struct Cli {
    /// Run loopback SOCKS5 + tamper self-test and exit.
    #[arg(long)]
    pub self_test: bool,

    #[arg(long, default_value = "127.0.0.1:1080")]
    pub listen: String,

    /// Single split marker: 1, 2, 3, sni, midsld
    #[arg(long)]
    pub split: Option<String>,

    /// Comma-separated split markers (tpws --split-pos): e.g. 1,sni,midsld
    #[arg(long)]
    pub split_pos: Option<String>,

    #[arg(long)]
    pub disorder: bool,

    #[arg(long)]
    pub tlsrec: Option<String>,

    #[arg(long)]
    pub oob: bool,

    #[arg(long, default_value_t = 0)]
    pub seg_delay_ms: u64,

    #[arg(long, default_value_t = 1)]
    pub fake_count: u8,

    /// TTL for disorder segments (tpws uses 1 on even parts)
    #[arg(long, default_value_t = 1)]
    pub disorder_ttl: u8,

    /// Default TTL restored after disorder sends
    #[arg(long, default_value_t = 0)]
    pub default_ttl: u8,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub listen: String,
    pub split_positions: Vec<SplitPos>,
    pub disorder: bool,
    pub tlsrec: Option<TlsRecKind>,
    pub oob: bool,
    pub seg_delay_ms: u64,
    pub fake_count: u8,
    pub disorder_ttl: u8,
    pub default_ttl: u8,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SplitPos {
    B1,
    B2,
    B3,
    Sni,
    MidSld,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TlsRecKind {
    B1,
    MidSld,
}

impl Config {
    pub fn from_cli(cli: Cli) -> Result<Self> {
        let mut split_positions = Vec::new();
        if let Some(ref list) = cli.split_pos {
            for part in list.split(',') {
                let p = part.trim();
                if p.is_empty() {
                    continue;
                }
                split_positions.push(SplitPos::parse(p)?);
            }
        } else if let Some(ref single) = cli.split {
            split_positions.push(SplitPos::parse(single)?);
        }

        if split_positions.len() > MAX_SPLITS {
            bail!("too many split positions (max {MAX_SPLITS})");
        }

        let tlsrec = match cli.tlsrec.as_deref() {
            None => None,
            Some(s) => Some(TlsRecKind::parse(s)?),
        };

        if cli.disorder && split_positions.is_empty() {
            bail!("--disorder requires --split or --split-pos");
        }
        if cli.oob && cli.disorder {
            bail!("do not combine --oob with --disorder");
        }
        if cli.oob && tlsrec.is_some() {
            bail!("do not combine --oob with --tlsrec");
        }
        if cli.seg_delay_ms > 50 {
            bail!("--seg-delay-ms must be 0–50");
        }
        if !(1..=3).contains(&cli.fake_count) {
            bail!("--fake-count must be 1–3");
        }
        if cli.disorder_ttl == 0 {
            bail!("--disorder-ttl must be 1–255");
        }

        let default_ttl = if cli.default_ttl == 0 {
            net_default_ttl()
        } else {
            cli.default_ttl
        };

        Ok(Self {
            listen: cli.listen,
            split_positions,
            disorder: cli.disorder,
            tlsrec,
            oob: cli.oob,
            seg_delay_ms: cli.seg_delay_ms,
            fake_count: cli.fake_count,
            disorder_ttl: cli.disorder_ttl,
            default_ttl,
        })
    }

    pub fn has_tamper(&self) -> bool {
        !self.split_positions.is_empty() || self.tlsrec.is_some() || self.oob
    }

    pub fn summary(&self) -> String {
        let mut parts = Vec::new();
        if !self.split_positions.is_empty() {
            let markers: Vec<String> = self.split_positions.iter().map(|p| p.to_string()).collect();
            parts.push(format!("split-pos={}", markers.join(",")));
        }
        if self.disorder {
            parts.push(format!("disorder:ttl={}", self.disorder_ttl));
        }
        if let Some(t) = self.tlsrec {
            if self.fake_count > 1 {
                parts.push(format!("tlsrec={t}×{}", self.fake_count));
            } else {
                parts.push(format!("tlsrec={t}"));
            }
        }
        if self.oob {
            parts.push("oob".into());
        }
        if self.seg_delay_ms > 0 {
            parts.push(format!("delay={}ms", self.seg_delay_ms));
        }
        if parts.is_empty() {
            "passthrough".into()
        } else {
            parts.join(" ")
        }
    }
}

impl SplitPos {
    pub fn parse(s: &str) -> Result<Self> {
        match s.to_ascii_lowercase().as_str() {
            "1" => Ok(Self::B1),
            "2" => Ok(Self::B2),
            "3" => Ok(Self::B3),
            "sni" => Ok(Self::Sni),
            "midsld" => Ok(Self::MidSld),
            _ => bail!("invalid split marker {s:?} (use 1, 2, 3, sni, midsld)"),
        }
    }
}

impl fmt::Display for SplitPos {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::B1 => write!(f, "1"),
            Self::B2 => write!(f, "2"),
            Self::B3 => write!(f, "3"),
            Self::Sni => write!(f, "sni"),
            Self::MidSld => write!(f, "midsld"),
        }
    }
}

impl TlsRecKind {
    fn parse(s: &str) -> Result<Self> {
        match s.to_ascii_lowercase().as_str() {
            "1" => Ok(Self::B1),
            "midsld" => Ok(Self::MidSld),
            _ => bail!("invalid --tlsrec {s:?} (use 1, midsld)"),
        }
    }
}

impl fmt::Display for TlsRecKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::B1 => write!(f, "1"),
            Self::MidSld => write!(f, "midsld"),
        }
    }
}

fn net_default_ttl() -> u8 {
    crate::net::probe_default_ttl().unwrap_or(64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_split_pos_list() {
        let cfg = Config::from_cli(Cli {
            self_test: false,
            listen: "127.0.0.1:1080".into(),
            split: None,
            split_pos: Some("1,sni,midsld".into()),
            disorder: true,
            tlsrec: None,
            oob: false,
            seg_delay_ms: 0,
            fake_count: 1,
            disorder_ttl: 1,
            default_ttl: 64,
        })
        .unwrap();
        assert_eq!(cfg.split_positions.len(), 3);
    }
}
