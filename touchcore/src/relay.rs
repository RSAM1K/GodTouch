use std::io::{self, Write};
use std::net::TcpStream as StdTcpStream;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::config::Config;
use crate::net::{seg_delay, segment_ttl, send_segment, set_ip_ttl, set_nodelay};
use crate::tamper::{build_tx_plan, is_client_hello, prepare_send_plan, record_len};

const MAX_FIRST: usize = 16 * 1024;
const FIRST_WAIT_MS: u64 = 1500;

pub async fn read_initial(client: &mut (impl AsyncRead + Unpin)) -> io::Result<Vec<u8>> {
    let mut buf = Vec::with_capacity(4096);
    let deadline = tokio::time::Instant::now() + Duration::from_millis(FIRST_WAIT_MS);

    loop {
        if buf.len() >= MAX_FIRST {
            return Ok(buf);
        }
        let remain = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remain.is_zero() {
            return Ok(buf);
        }
        let mut tmp = [0u8; 4096];
        match tokio::time::timeout(remain, client.read(&mut tmp)).await {
            Ok(Ok(0)) => return Ok(buf),
            Ok(Ok(n)) => {
                buf.extend_from_slice(&tmp[..n]);
                if let Some(need) = record_len(&buf) {
                    if buf.len() >= need {
                        return Ok(buf);
                    }
                } else if buf.len() >= 5 && !looks_like_tls(&buf) {
                    return Ok(buf);
                }
            }
            Ok(Err(e)) => {
                if buf.is_empty() {
                    return Err(e);
                }
                return Ok(buf);
            }
            Err(_) => return Ok(buf),
        }
    }
}

fn looks_like_tls(buf: &[u8]) -> bool {
    matches!(buf[0], 0x14 | 0x15 | 0x16 | 0x17)
}

pub fn write_tampered_blocking(server: &mut StdTcpStream, data: &[u8], cfg: &Config) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    if !cfg.has_tamper() || !is_client_hello(data) {
        server.write_all(data)?;
        return Ok(());
    }

    let (record, rest) = if let Some(need) = record_len(data) {
        if data.len() >= need {
            data.split_at(need)
        } else {
            (data, &[][..])
        }
    } else {
        (data, &[][..])
    };

    let plan = prepare_send_plan(build_tx_plan(record, cfg), cfg);
    let delay = seg_delay(cfg.seg_delay_ms);
    let send_total = plan.iter().filter(|s| !s.data.is_empty()).count();

    let mut send_index = 0usize;
    for (i, seg) in plan.iter().enumerate() {
        if seg.data.is_empty() {
            continue;
        }
        send_segment(server, seg, segment_ttl(cfg, seg, send_index, send_total))?;
        send_index += 1;
        if i + 1 < plan.len() && !delay.is_zero() {
            std::thread::sleep(delay);
        }
    }
    let _ = set_ip_ttl(server, cfg.default_ttl);

    if !rest.is_empty() {
        server.write_all(rest)?;
    }
    Ok(())
}

pub async fn write_tampered(server: &mut TcpStream, data: &[u8], cfg: &Config) -> io::Result<()> {
    use std::os::unix::io::{AsRawFd, FromRawFd};

    let fd = server.as_raw_fd();
    let dup_fd = unsafe { libc::dup(fd) };
    if dup_fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut std = unsafe { StdTcpStream::from_raw_fd(dup_fd) };
    write_tampered_blocking(&mut std, data, cfg)
}

fn relay_blocking(
    mut client_read: StdTcpStream,
    mut client_write: StdTcpStream,
    mut server: StdTcpStream,
    cfg: Config,
    initial: Vec<u8>,
) -> io::Result<()> {
    client_read.set_nonblocking(false).ok();
    client_write.set_nonblocking(false).ok();
    server.set_nonblocking(false)?;

    if !initial.is_empty() {
        write_tampered_blocking(&mut server, &initial, &cfg)?;
    }

    let mut server_read = server.try_clone()?;
    let mut server_write = server;
    let upstream_to_client = std::thread::spawn(move || {
        let _ = io::copy(&mut server_read, &mut client_write);
    });
    let _ = io::copy(&mut client_read, &mut server_write);
    let _ = upstream_to_client.join();
    Ok(())
}

pub async fn relay(mut client: TcpStream, server: TcpStream, cfg: Config) -> io::Result<()> {
    set_nodelay(&client)?;
    set_nodelay(&server)?;

    if !cfg.has_tamper() {
        let (mut cr, mut cw) = client.into_split();
        let (mut sr, mut sw) = server.into_split();
        let c2s = tokio::spawn(async move {
            let _ = tokio::io::copy(&mut cr, &mut sw).await;
            let _ = sw.shutdown().await;
        });
        let s2c = tokio::spawn(async move {
            let _ = tokio::io::copy(&mut sr, &mut cw).await;
            let _ = cw.shutdown().await;
        });
        let _ = tokio::join!(c2s, s2c);
        return Ok(());
    }

    let initial = read_initial(&mut client).await?;
    let client_std = client
        .into_std()
        .map_err(|e| io::Error::other(e.to_string()))?;
    let client_read = client_std.try_clone()?;
    let client_write = client_std;
    let server = server
        .into_std()
        .map_err(|e| io::Error::other(e.to_string()))?;

    tokio::task::spawn_blocking(move || relay_blocking(client_read, client_write, server, cfg, initial))
        .await
        .map_err(|e| io::Error::other(e.to_string()))?
}

#[cfg(test)]
mod tests {
    use std::io;
    use std::time::Duration;

    use tokio::io::AsyncReadExt;
    use tokio::net::{TcpListener, TcpStream};
    use tokio::time::timeout;

    use crate::config::{Config, SplitPos, TlsRecKind};
    use crate::tamper::{plan_handshake_payload, plan_real_payload, test_hello};

    fn tamper_cfg() -> Config {
        Config {
            listen: "127.0.0.1:0".into(),
            split_positions: vec![SplitPos::B1, SplitPos::MidSld],
            disorder: true,
            tlsrec: Some(TlsRecKind::MidSld),
            oob: false,
            seg_delay_ms: 0,
            fake_count: 1,
            disorder_ttl: 1,
            default_ttl: 64,
        }
    }

    fn combo_cfg() -> Config {
        Config {
            listen: "127.0.0.1:0".into(),
            split_positions: vec![SplitPos::MidSld],
            disorder: true,
            tlsrec: Some(TlsRecKind::MidSld),
            oob: false,
            seg_delay_ms: 0,
            fake_count: 1,
            disorder_ttl: 1,
            default_ttl: 64,
        }
    }

    #[tokio::test]
    async fn tamper_plan_has_multiple_segments() {
        let cfg = tamper_cfg();
        let hello = test_hello("segment.test");
        let plan = crate::tamper::build_tx_plan(&hello, &cfg);
        assert!(
            plan.len() >= 3,
            "combo tlsrec + multisplit should yield >=3 segments, got {}",
            plan.len()
        );
    }

    async fn recv_upstream(listener: TcpListener) -> io::Result<Vec<u8>> {
        let (mut sock, _) = listener.accept().await?;
        let mut buf = Vec::new();
        let _ = timeout(Duration::from_secs(2), sock.read_to_end(&mut buf)).await??;
        Ok(buf)
    }

    #[tokio::test]
    async fn disorder_ttl64_matches_split_wire() {
        let hello = test_hello("127.0.0.1");
        let mut split_cfg = combo_cfg();
        split_cfg.tlsrec = None;
        split_cfg.disorder = false;
        split_cfg.split_positions = vec![SplitPos::MidSld];
        split_cfg.default_ttl = 64;
        split_cfg.disorder_ttl = 64;

        let mut dis_cfg = split_cfg.clone();
        dis_cfg.disorder = true;

        async fn recv_upstream(listener: TcpListener) -> io::Result<Vec<u8>> {
            let (mut sock, _) = listener.accept().await?;
            let mut buf = Vec::new();
            let _ = timeout(Duration::from_secs(2), sock.read_to_end(&mut buf)).await??;
            Ok(buf)
        }

        for (name, cfg) in [("split", split_cfg), ("disorder64", dis_cfg)] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let hello = hello.clone();
            let read_task = tokio::spawn(async move { recv_upstream(listener).await });
            {
                let mut upstream = TcpStream::connect(addr).await.unwrap();
                super::write_tampered(&mut upstream, &hello, &cfg)
                    .await
                    .unwrap_or_else(|e| panic!("{name}: {e}"));
            }
            let got = read_task.await.unwrap().unwrap();
            if name == "split" {
                assert_eq!(got, hello, "{name}: wire mismatch");
            } else {
                assert_eq!(got, hello, "{name}: must match split wire when disorder_ttl=default_ttl");
            }
        }
    }

    #[tokio::test]
    async fn write_tampered_preserves_client_hello() {
        let hello = test_hello("www.youtube.com");
        let cases = [
            ("split", {
                let mut c = tamper_cfg();
                c.tlsrec = None;
                c.disorder = false;
                c
            }),
            ("combo", combo_cfg()),
            ("oob", {
                let mut c = tamper_cfg();
                c.tlsrec = None;
                c.split_positions.clear();
                c.disorder = false;
                c.oob = true;
                c
            }),
        ];

        for (name, cfg) in cases {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let hello = hello.clone();
            let cfg = cfg.clone();

            let read_task = tokio::spawn(async move { recv_upstream(listener).await });

            {
                let mut upstream = TcpStream::connect(addr).await.unwrap();
                super::write_tampered(&mut upstream, &hello, &cfg)
                    .await
                    .unwrap_or_else(|e| panic!("{name}: write failed: {e}"));
            }

            let got = read_task
                .await
                .unwrap()
                .unwrap_or_else(|e| panic!("{name}: read failed: {e}"));

            let plan = crate::tamper::build_tx_plan(&hello, &cfg);
            let wire_plan = crate::tamper::prepare_send_plan(plan.clone(), &cfg);

            if name == "oob" {
                assert_eq!(got, hello[1..]);
            } else if cfg.tlsrec.is_some() {
                let expected: Vec<u8> = wire_plan.iter().flat_map(|s| s.data.clone()).collect();
                assert_eq!(got, expected, "{name}: tlsrec wire mismatch");
                assert_eq!(plan_handshake_payload(&plan), hello[5..]);
            } else {
                assert_eq!(plan_real_payload(&plan), hello);
                let expected: Vec<u8> = wire_plan.iter().flat_map(|s| s.data.clone()).collect();
                assert_eq!(got, expected, "{name}: upstream wire payload mismatch");
            }
        }
    }
}
