use std::io::{self, Write};
use std::net::TcpStream as StdTcpStream;
use std::time::Duration;

use libc::{c_void, send, MSG_OOB};
use socket2::SockRef;
use tokio::net::TcpStream;

use crate::config::Config;
use crate::tamper::TxSegment;

#[cfg(target_os = "linux")]
const TCP_CORK: i32 = 3;

/// Enable TCP_NODELAY — each write becomes its own segment (best-effort on macOS).
pub fn set_nodelay(stream: &TcpStream) -> io::Result<()> {
    SockRef::from(stream).set_nodelay(true)
}

pub fn set_nodelay_off(stream: &TcpStream) -> io::Result<()> {
    SockRef::from(stream).set_nodelay(false)
}

pub fn set_nodelay_std(stream: &StdTcpStream) -> io::Result<()> {
    SockRef::from(stream).set_nodelay(true)
}

pub fn set_nodelay_off_std(stream: &StdTcpStream) -> io::Result<()> {
    SockRef::from(stream).set_nodelay(false)
}

pub fn probe_default_ttl() -> Option<u8> {
    use std::net::UdpSocket;
    let sock = UdpSocket::bind("0.0.0.0:0").ok()?;
    let ttl = sock.ttl().ok()?;
    Some(ttl.min(255) as u8)
}

pub fn set_ip_ttl(stream: &StdTcpStream, ttl: u8) -> io::Result<()> {
    let sock = SockRef::from(stream);
    let v4 = sock.set_ttl(u32::from(ttl));
    let v6 = sock.set_unicast_hops_v6(u32::from(ttl));
    if v4.is_err() && v6.is_err() {
        return v4;
    }
    Ok(())
}

/// TTL for a tamper segment. tpws disorder: even-indexed parts use low TTL before the last.
pub fn segment_ttl(cfg: &Config, _seg: &TxSegment, send_index: usize, send_total: usize) -> u8 {
    if cfg.disorder && send_total >= 2 && send_index % 2 == 0 && send_index + 1 < send_total {
        cfg.disorder_ttl
    } else {
        cfg.default_ttl
    }
}

#[cfg(target_os = "linux")]
fn cork_push(fd: std::os::unix::io::RawFd, enable: bool) {
    let v: i32 = if enable { 1 } else { 0 };
    unsafe {
        libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            TCP_CORK,
            &v as *const _ as *const c_void,
            std::mem::size_of::<i32>() as libc::socklen_t,
        );
    }
}

/// Send one tamper segment with optional cork + OOB + TTL (tpws: cork is Linux-only).
pub fn send_segment(stream: &mut StdTcpStream, seg: &TxSegment, ttl: u8) -> io::Result<()> {
    set_ip_ttl(stream, ttl)?;
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::io::AsRawFd;
        cork_push(stream.as_raw_fd(), true);
    }

    let result = if seg.oob && seg.data.len() == 1 {
        use std::os::unix::io::AsRawFd;
        let fd = stream.as_raw_fd();
        let n = unsafe {
            send(
                fd,
                seg.data.as_ptr() as *const c_void,
                seg.data.len(),
                MSG_OOB,
            )
        };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    } else {
        stream.write_all(&seg.data)
    };

    #[cfg(target_os = "linux")]
    {
        use std::os::unix::io::AsRawFd;
        cork_push(stream.as_raw_fd(), false);
    }
    result
}

#[allow(dead_code)]
/// Send full tamper plan over a connected tokio socket (tests / legacy).
pub fn send_tx_plan(_stream: &TcpStream, _plan: &[TxSegment], _cfg: &Config) -> io::Result<()> {
    Ok(())
}

pub fn seg_delay(cfg_ms: u64) -> Duration {
    Duration::from_millis(cfg_ms)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, TlsRecKind};
    use crate::tamper::{apply_tlsrec_stream, build_tx_plan, test_hello};

    #[test]
    fn tlsrec_stream_longer_by_one_header() {
        let hello = test_hello("youtube.com");
        let (stream, _) = apply_tlsrec_stream(&hello, TlsRecKind::MidSld).unwrap();
        assert_eq!(stream.len(), hello.len() + 5);
        let plan = build_tx_plan(
            &hello,
            &Config {
                listen: "127.0.0.1:0".into(),
                split_positions: vec![],
                disorder: false,
                tlsrec: Some(TlsRecKind::MidSld),
                oob: false,
                seg_delay_ms: 0,
                fake_count: 1,
                disorder_ttl: 1,
                default_ttl: 64,
            },
        );
        assert_eq!(plan.len(), 2);
        assert_eq!(segment_ttl(&Config {
            listen: String::new(),
            split_positions: vec![],
            disorder: true,
            tlsrec: None,
            oob: false,
            seg_delay_ms: 0,
            fake_count: 1,
            disorder_ttl: 3,
            default_ttl: 64,
        }, &plan[0], 0, 3), 3);
        assert_eq!(segment_ttl(&Config {
            listen: String::new(),
            split_positions: vec![],
            disorder: true,
            tlsrec: None,
            oob: false,
            seg_delay_ms: 0,
            fake_count: 1,
            disorder_ttl: 3,
            default_ttl: 64,
        }, &plan[0], 2, 3), 64);
    }
}
