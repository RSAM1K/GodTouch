use std::net::{Ipv4Addr, Ipv6Addr};

/// Telegram IP ranges (used to detect Telegram traffic)
const TG_RANGES: &[(u32, u32)] = &[
    // 185.76.151.0/24
    (ip_to_u32([185, 76, 151, 0]), ip_to_u32([185, 76, 151, 255])),
    // 149.154.160.0/20
    (ip_to_u32([149, 154, 160, 0]), ip_to_u32([149, 154, 175, 255])),
    // 91.105.192.0/23
    (ip_to_u32([91, 105, 192, 0]), ip_to_u32([91, 105, 193, 255])),
    // 91.108.0.0/16
    (ip_to_u32([91, 108, 0, 0]), ip_to_u32([91, 108, 255, 255])),
];

const fn ip_to_u32(o: [u8; 4]) -> u32 {
    ((o[0] as u32) << 24) | ((o[1] as u32) << 16) | ((o[2] as u32) << 8) | (o[3] as u32)
}

pub fn is_telegram_ip(ip: Ipv4Addr) -> bool {
    let n = u32::from(ip);
    TG_RANGES.iter().any(|&(lo, hi)| n >= lo && n <= hi)
}

/// Telegram publishes these IPv6 prefixes for DC / media endpoints.
pub fn is_telegram_ipv6(ip: Ipv6Addr) -> bool {
    dc_from_ipv6(ip).is_some() || {
        let s = ip.segments();
        s[0] == 0x2a0a && s[1] == 0xf280
    }
}

/// Map Telegram IPv6 → (dc_id, is_media). Media flag is a weak hint —
/// MTProto init (`extract_dc`) always wins when present.
pub fn dc_from_ipv6(ip: Ipv6Addr) -> Option<(u8, bool)> {
    let s = ip.segments();
    let is_media = matches!(s[7], 0x000b | 0x000d | 0x010b | 0x010d);

    let dc = if s[0] == 0x2a0a && s[1] == 0xf280 {
        // 2a0a:f280::/32 — current Telegram IPv6 (Desktop prefers this)
        2
    } else if s[0] != 0x2001 {
        return None;
    } else if s[1] == 0x067c && s[2] == 0x04e8 {
        // 2001:67c:4e8:f00X::  — DC2 (f002) / DC4 (f004)
        match s[3] {
            0xf002 | 0xf012 | 0xf00a => 2,
            0xf004 | 0xf014 | 0xf00c => 4,
            _ => 2,
        }
    } else if s[1] == 0x0b28 && s[2] == 0xf23d {
        // 2001:b28:f23d:f00X:: — DC1 / DC3
        match s[3] {
            0xf001 | 0xf011 => 1,
            0xf003 | 0xf013 => 3,
            _ => 1,
        }
    } else if s[1] == 0x0b28 && s[2] == 0xf23f {
        // 2001:b28:f23f:f005:: — DC5
        5
    } else if s[1] == 0x0b28 && s[2] == 0xf23c {
        2
    } else {
        return None;
    };

    Some((dc, is_media))
}

/// Known Telegram DC server IPs mapped to (dc_id, is_media)
pub fn dc_from_ip(ip: Ipv4Addr) -> Option<(u8, bool)> {
    let s = ip.to_string();
    if let Some(dc) = dc_from_ip_exact(&s) {
        return Some(dc);
    }
    // Subnet fallback for new/changed DC IPs inside Telegram ranges.
    let o = ip.octets();
    if o[0] == 149 && o[1] == 154 {
        let is_media = o[2] == 162 || o[2] == 164 || o[2] == 165 || o[2] == 166
            || matches!(o[3], 102 | 111 | 118 | 120 | 121 | 123 | 151 | 152 | 222 | 223 | 250);
        let dc = match o[2] {
            164..=166 => 4,
            168..=175 => 1,
            160..=167 => 2,
            _ => 2,
        };
        return Some((dc, is_media));
    }
    if o[0] == 91 && o[1] == 108 {
        let is_media = matches!(o[3], 102 | 128 | 151);
        return Some((5, is_media));
    }
    if o[0] == 91 && o[1] == 105 {
        return Some((5, false));
    }
    if o[0] == 185 && o[1] == 76 {
        return Some((2, false));
    }
    if o[0] == 95 && o[1] == 161 {
        return Some((2, false));
    }
    None
}

fn dc_from_ip_exact(s: &str) -> Option<(u8, bool)> {
    Some(match s {
        // DC1
        "149.154.175.50" | "149.154.175.51" | "149.154.175.53" | "149.154.175.54" => (1, false),
        "149.154.175.52" => (1, true),
        // DC2
        "149.154.167.41" | "149.154.167.50" | "149.154.167.51"
        | "149.154.167.220" | "95.161.76.100" => (2, false),
        "149.154.167.151" | "149.154.167.222" | "149.154.167.223" | "149.154.162.123" => {
            (2, true)
        }
        // DC3
        "149.154.175.100" | "149.154.175.101" => (3, false),
        "149.154.175.102" => (3, true),
        // DC4
        "149.154.167.91" | "149.154.167.92" => (4, false),
        "149.154.164.250" | "149.154.166.120" | "149.154.166.121" | "149.154.167.118"
        | "149.154.165.111" => (4, true),
        // DC5
        "91.108.56.100" | "91.108.56.101" | "91.108.56.103" | "91.108.56.116" | "91.108.56.126"
        | "149.154.171.5" => (5, false),
        "91.108.56.102" | "91.108.56.128" | "91.108.56.151" => (5, true),
        _ => return None,
    })
}

/// Community CF fronts only have `kwsN` (not `kwsN-1`). Same origin IP in Flowseal.
pub fn ws_domains(dc: u8, _is_media: bool) -> [String; 4] {
    let n = dc.clamp(1, 5);
    [
        format!("kws{n}.cakeisalie.co.uk"),
        format!("kws{n}.fixtelega.co.uk"),
        format!("kws{n}.pclead.co.uk"),
        format!("kws{n}.lovetrue.co.uk"),
    ]
}
