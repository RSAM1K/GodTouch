//! TLS ClientHello parsing and tamper (techniques from zapret/tpws, MIT).

use crate::config::{Config, SplitPos, TlsRecKind};

const RECORD_HANDSHAKE: u8 = 0x16;

/// One outbound TCP segment plan.
#[derive(Debug, Clone)]
pub struct TxSegment {
    pub data: Vec<u8>,
    pub oob: bool,
}

impl TxSegment {
    fn data(data: Vec<u8>) -> Self {
        Self { data, oob: false }
    }

    fn oob_byte(data: Vec<u8>) -> Self {
        Self { data, oob: true }
    }
}

pub fn is_client_hello(buf: &[u8]) -> bool {
    if buf.len() < 5 || buf[0] != RECORD_HANDSHAKE || buf[1] != 0x03 {
        return false;
    }
    let rec_len = u16::from_be_bytes([buf[3], buf[4]]) as usize;
    if buf.len() < 5 + rec_len {
        return false;
    }
    let payload = &buf[5..];
    payload.len() >= 4 && payload[0] == 0x01
}

pub fn record_len(buf: &[u8]) -> Option<usize> {
    if buf.len() < 5 {
        return None;
    }
    let rec_len = u16::from_be_bytes([buf[3], buf[4]]) as usize;
    Some(5 + rec_len)
}

pub fn split_position(buf: &[u8], pos: SplitPos) -> usize {
    match pos {
        SplitPos::B1 => 1,
        SplitPos::B2 => buf.len().min(2).max(1),
        SplitPos::B3 => buf.len().min(3).max(1),
        SplitPos::Sni => sni_host_offset(buf)
            .map(|(_, off)| off)
            .filter(|&off| off > 1 && off < buf.len())
            .unwrap_or(1),
        SplitPos::MidSld => {
            if let Some((name_len, off)) = sni_host_offset(buf) {
                let mid = off + name_len / 2;
                if mid > 1 && mid < buf.len() {
                    return mid;
                }
            }
            1
        }
    }
}

/// Resolve, sort, dedupe split byte offsets inside ClientHello.
pub fn resolve_multisplit(buf: &[u8], markers: &[SplitPos]) -> Vec<usize> {
    let mut pos: Vec<usize> = markers
        .iter()
        .map(|m| split_position(buf, *m))
        .filter(|&p| p > 0 && p < buf.len())
        .collect();
    pos.sort_unstable();
    pos.dedup();
    pos
}

pub fn split_at_positions(hello: &[u8], positions: &[usize]) -> Vec<Vec<u8>> {
    let mut parts = Vec::new();
    let mut from = 0;
    for &pos in positions {
        if pos <= from || pos >= hello.len() {
            continue;
        }
        parts.push(hello[from..pos].to_vec());
        from = pos;
    }
    parts.push(hello[from..].to_vec());
    parts
}

fn sni_host_offset(buf: &[u8]) -> Option<(usize, usize)> {
    if buf.len() < 5 {
        return None;
    }
    let rec_len = u16::from_be_bytes([buf[3], buf[4]]) as usize;
    if buf.len() < 5 + rec_len {
        return None;
    }
    let p = &buf[5..];
    if p.len() < 39 || p[0] != 0x01 {
        return None;
    }
    let hs_len = (usize::from(p[1]) << 16) | (usize::from(p[2]) << 8) | usize::from(p[3]);
    if hs_len + 4 > p.len() {
        return None;
    }
    let sess_len = usize::from(p[38]);
    let mut i = 39 + sess_len;
    if i + 2 > p.len() {
        return None;
    }
    let cipher_len = u16::from_be_bytes([p[i], p[i + 1]]) as usize;
    i += 2 + cipher_len;
    if i >= p.len() {
        return None;
    }
    let comp_len = usize::from(p[i]);
    i += 1 + comp_len;
    if i + 2 > p.len() {
        return None;
    }
    let ext_len = u16::from_be_bytes([p[i], p[i + 1]]) as usize;
    i += 2;
    let ext_end = i + ext_len;
    if ext_end > p.len() {
        return None;
    }
    while i + 4 <= ext_end {
        let typ = u16::from_be_bytes([p[i], p[i + 1]]);
        let ln = u16::from_be_bytes([p[i + 2], p[i + 3]]) as usize;
        i += 4;
        if i + ln > ext_end {
            break;
        }
        if typ == 0 {
            if ln < 5 {
                break;
            }
            let name_len = u16::from_be_bytes([p[i + 3], p[i + 4]]) as usize;
            let name_start = i + 5;
            if name_start + name_len > i + ln {
                break;
            }
            let abs = 5 + name_start;
            return Some((name_len, abs));
        }
        i += ln;
    }
    None
}

fn tlsrec_split_pos(kind: TlsRecKind) -> SplitPos {
    match kind {
        TlsRecKind::B1 => SplitPos::B1,
        TlsRecKind::MidSld => SplitPos::MidSld,
    }
}

fn map_cut_after_tlsrec(cut: usize, tpos: usize) -> usize {
    if cut > tpos { cut + 5 } else { cut }
}

/// Split one ClientHello TLS record into two Handshake records (tpws --tlsrec).
pub fn apply_tlsrec_stream(hello: &[u8], kind: TlsRecKind) -> Option<(Vec<u8>, usize)> {
    if hello.len() < 6 || hello[0] != RECORD_HANDSHAKE {
        return None;
    }
    let pos = split_position(hello, tlsrec_split_pos(kind));
    if pos <= 5 || pos >= hello.len() {
        return None;
    }

    let tail = &hello[pos..];
    let mut first = hello[..pos].to_vec();
    let first_payload_len = first.len().saturating_sub(5);
    first[3..5].copy_from_slice(&(first_payload_len as u16).to_be_bytes());

    let mut stream = Vec::with_capacity(first.len() + 5 + tail.len());
    stream.extend_from_slice(&first);
    stream.push(RECORD_HANDSHAKE);
    stream.push(hello[1]);
    stream.push(hello[2]);
    stream.extend_from_slice(&(tail.len() as u16).to_be_bytes());
    stream.extend_from_slice(tail);
    Some((stream, pos))
}

/// Build segment send plan (tlsrec + multisplit + disorder flags).
pub fn build_tx_plan(hello: &[u8], cfg: &Config) -> Vec<TxSegment> {
    if cfg.oob {
        let mut plan = Vec::new();
        if hello.len() >= 2 {
            plan.push(TxSegment::oob_byte(vec![hello[0]]));
            plan.push(TxSegment::data(hello[1..].to_vec()));
        } else {
            plan.push(TxSegment::oob_byte(hello.to_vec()));
        }
        return plan;
    }

    if let Some(kind) = cfg.tlsrec {
        if let Some((stream, tpos)) = apply_tlsrec_stream(hello, kind) {
            if cfg.split_positions.is_empty() {
                return vec![
                    TxSegment::data(stream[..tpos].to_vec()),
                    TxSegment::data(stream[tpos..].to_vec()),
                ];
            }
            let cuts: Vec<usize> = resolve_multisplit(hello, &cfg.split_positions)
                .into_iter()
                .map(|c| map_cut_after_tlsrec(c, tpos))
                .filter(|&c| c > 0 && c < stream.len())
                .collect();
            let parts = split_at_positions(&stream, &cuts);
            return parts.into_iter().map(TxSegment::data).collect();
        }
    }

    if cfg.split_positions.is_empty() {
        return vec![TxSegment::data(hello.to_vec())];
    }

    let cuts = resolve_multisplit(hello, &cfg.split_positions);
    let parts = if cuts.is_empty() {
        vec![hello.to_vec()]
    } else {
        split_at_positions(hello, &cuts)
    };

    parts.into_iter().map(TxSegment::data).collect()
}

/// Wire send order (disorder uses TTL trick, not segment reversal — same as tpws).
pub fn prepare_send_plan(plan: Vec<TxSegment>, _cfg: &Config) -> Vec<TxSegment> {
    plan
}

/// Concatenate non-OOB plan segments in send order.
pub fn plan_real_payload(plan: &[TxSegment]) -> Vec<u8> {
    plan.iter().flat_map(|s| s.data.clone()).collect()
}

/// Handshake message bytes carried by plan segments (ignores record headers).
pub fn plan_handshake_payload(plan: &[TxSegment]) -> Vec<u8> {
    let mut out = Vec::new();
    for seg in plan {
        if seg.data.len() > 5 && seg.data[0] == RECORD_HANDSHAKE {
            out.extend_from_slice(&seg.data[5..]);
        }
    }
    out
}

/// Synthetic TLS ClientHello for tests and self-test.
pub fn test_hello(host: &str) -> Vec<u8> {
    let mut name_list = Vec::new();
    name_list.push(0u8);
    name_list.extend_from_slice(&(host.len() as u16).to_be_bytes());
    name_list.extend_from_slice(host.as_bytes());
    let mut sni_payload = Vec::new();
    sni_payload.extend_from_slice(&(name_list.len() as u16).to_be_bytes());
    sni_payload.extend_from_slice(&name_list);
    let mut ext = Vec::new();
    ext.extend_from_slice(&[0x00, 0x00]);
    ext.extend_from_slice(&(sni_payload.len() as u16).to_be_bytes());
    ext.extend_from_slice(&sni_payload);
    let mut body = Vec::new();
    body.extend_from_slice(&[0x03, 0x03]);
    body.extend_from_slice(&[0u8; 32]);
    body.push(0);
    body.extend_from_slice(&[0x00, 0x02, 0x00, 0x2f]);
    body.extend_from_slice(&[0x01, 0x00]);
    body.extend_from_slice(&(ext.len() as u16).to_be_bytes());
    body.extend_from_slice(&ext);
    let mut rec = vec![0u8; 5 + 1 + 3 + body.len()];
    rec[0] = 0x16;
    rec[1] = 0x03;
    rec[2] = 0x01;
    let hs_len = body.len() + 4;
    rec[3..5].copy_from_slice(&(hs_len as u16).to_be_bytes());
    rec[5] = 0x01;
    rec[6..9].copy_from_slice(&(body.len() as u32).to_be_bytes()[1..]);
    rec[9..].copy_from_slice(&body);
    rec
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    fn test_cfg(split: Vec<SplitPos>, disorder: bool) -> Config {
        Config {
            listen: "127.0.0.1:1080".into(),
            split_positions: split,
            disorder,
            tlsrec: None,
            oob: false,
            seg_delay_ms: 0,
            fake_count: 1,
            disorder_ttl: 1,
            default_ttl: 64,
        }
    }

    #[test]
    fn client_hello_detect() {
        assert!(is_client_hello(&test_hello("example.com")));
    }

    #[test]
    fn multisplit_three_parts() {
        let h = test_hello("youtube.com");
        let cuts = resolve_multisplit(&h, &[SplitPos::B1, SplitPos::Sni, SplitPos::MidSld]);
        assert!(cuts.len() >= 2);
        let parts = split_at_positions(&h, &cuts);
        assert!(parts.len() >= 3);
    }

    #[test]
    fn tlsrec_splits_into_two_handshake_records() {
        let h = test_hello("example.com");
        let (stream, tpos) = apply_tlsrec_stream(&h, TlsRecKind::MidSld).unwrap();
        assert_eq!(stream[..tpos].len(), tpos);
        assert_eq!(stream[tpos], RECORD_HANDSHAKE);
        assert_eq!(plan_handshake_payload(&build_tx_plan(&h, &tlsrec_cfg())), &h[5..]);
    }

    fn tlsrec_cfg() -> Config {
        Config {
            listen: "127.0.0.1:1080".into(),
            split_positions: vec![],
            disorder: false,
            tlsrec: Some(TlsRecKind::MidSld),
            oob: false,
            seg_delay_ms: 0,
            fake_count: 1,
            disorder_ttl: 1,
            default_ttl: 64,
        }
    }

    #[test]
    fn disorder_marks_first_segment_ttl() {
        let h = test_hello("test.local");
        let cfg = test_cfg(vec![SplitPos::B1, SplitPos::MidSld], true);
        let plan = build_tx_plan(&h, &cfg);
        assert!(plan.len() >= 3);
        assert_eq!(crate::net::segment_ttl(&cfg, &plan[0], 0, plan.len()), cfg.disorder_ttl);
        assert_eq!(
            crate::net::segment_ttl(&cfg, &plan[1], 1, plan.len()),
            cfg.default_ttl
        );
    }

    #[test]
    fn disorder_keeps_logical_payload() {
        let h = test_hello("test.local");
        let normal = build_tx_plan(&h, &test_cfg(vec![SplitPos::B1, SplitPos::MidSld], false));
        let disorder = prepare_send_plan(
            build_tx_plan(&h, &test_cfg(vec![SplitPos::B1, SplitPos::MidSld], true)),
            &test_cfg(vec![SplitPos::B1, SplitPos::MidSld], true),
        );
        assert_eq!(plan_real_payload(&normal), h);
        assert!(normal.len() >= 3);
        assert_eq!(normal.len(), disorder.len());
    }
}
