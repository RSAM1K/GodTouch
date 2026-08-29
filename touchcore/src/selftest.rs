use std::net::{IpAddr, SocketAddr};

use anyhow::{bail, Context, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::{timeout, Duration};

use crate::config::Config;
use crate::socks5;
use crate::tamper::{build_tx_plan, plan_handshake_payload, plan_real_payload, test_hello};

const TIMEOUT: Duration = Duration::from_secs(5);

/// End-to-end SOCKS5 + tamper check on loopback.
pub async fn run(cfg: Config) -> Result<()> {
    let hello = test_hello("self-test.touch.local");
    let hello_body = hello[5..].to_vec();

    let upstream = TcpListener::bind("127.0.0.1:0")
        .await
        .context("bind upstream")?;
    let upstream_addr = upstream.local_addr()?;

    let proxy = TcpListener::bind("127.0.0.1:0")
        .await
        .context("bind proxy")?;
    let proxy_addr = proxy.local_addr()?;

    let proxy_cfg = cfg.clone();
    let proxy_task = tokio::spawn(async move { socks5::serve_listener(proxy, proxy_cfg).await });

    let upstream_task = tokio::spawn(async move {
        let (mut sock, _) = upstream
            .accept()
            .await
            .context("upstream accept")?;
        let mut buf = Vec::new();
        sock.read_to_end(&mut buf)
            .await
            .context("upstream read")?;
        Ok::<_, anyhow::Error>(buf)
    });

    let mut client = timeout(TIMEOUT, TcpStream::connect(proxy_addr))
        .await
        .context("proxy connect timeout")?
        .context("proxy connect")?;

    socks5_connect(&mut client, upstream_addr)
        .await
        .context("socks5 handshake")?;

    client
        .write_all(&hello)
        .await
        .context("write ClientHello")?;
    client.shutdown().await.ok();

    let got = timeout(TIMEOUT, upstream_task)
        .await
        .context("upstream wait timeout")?
        .context("upstream task join")??;

    proxy_task.abort();

    let plan = build_tx_plan(&hello, &cfg);
    let expected_wire: Vec<u8> = plan.iter().flat_map(|s| s.data.clone()).collect();

    if cfg.oob {
        if got != hello[1..] {
            bail!(
                "oob: upstream payload mismatch ({} vs {} bytes)",
                got.len(),
                hello.len() - 1
            );
        }
    } else if cfg.tlsrec.is_some() {
        if got != expected_wire {
            bail!(
                "tlsrec: wire mismatch ({} vs {} bytes)",
                got.len(),
                expected_wire.len()
            );
        }
        if plan_handshake_payload(&plan) != hello_body {
            bail!("tlsrec: handshake body changed");
        }
    } else if cfg.has_tamper() {
        if got != expected_wire {
            bail!(
                "tamper: wire mismatch ({} vs {} bytes)",
                got.len(),
                expected_wire.len()
            );
        }
        if plan_real_payload(&plan) != hello {
            bail!("tamper: ClientHello record changed");
        }
    } else if got != hello {
        bail!(
            "passthrough: expected {} bytes, got {}",
            hello.len(),
            got.len()
        );
    }

    let mode = if cfg.has_tamper() {
        cfg.summary()
    } else {
        "passthrough".into()
    };
    println!("self-test OK · {mode} · upstream {} bytes", got.len());
    Ok(())
}

async fn socks5_connect(stream: &mut TcpStream, target: SocketAddr) -> std::io::Result<()> {
    stream.write_all(&[0x05, 0x01, 0x00]).await?;
    let mut method = [0u8; 2];
    stream.read_exact(&mut method).await?;
    if method != [0x05, 0x00] {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "socks5 method rejected",
        ));
    }

    let mut req = Vec::with_capacity(22);
    req.extend_from_slice(&[0x05, 0x01, 0x00]);
    match target.ip() {
        IpAddr::V4(ip) => {
            req.push(0x01);
            req.extend_from_slice(&ip.octets());
        }
        IpAddr::V6(ip) => {
            req.push(0x04);
            req.extend_from_slice(&ip.octets());
        }
    }
    req.extend_from_slice(&target.port().to_be_bytes());
    stream.write_all(&req).await?;

    let mut head = [0u8; 4];
    stream.read_exact(&mut head).await?;
    if head[0] != 0x05 || head[1] != 0x00 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("socks5 connect failed: status {}", head[1]),
        ));
    }

    match head[3] {
        0x01 => {
            let mut rest = [0u8; 6];
            stream.read_exact(&mut rest).await?;
        }
        0x03 => {
            let mut len = [0u8; 1];
            stream.read_exact(&mut len).await?;
            let mut host = vec![0u8; len[0] as usize + 2];
            stream.read_exact(&mut host).await?;
        }
        0x04 => {
            let mut rest = [0u8; 18];
            stream.read_exact(&mut rest).await?;
        }
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "socks5 bad reply atyp",
            ));
        }
    }
    Ok(())
}
