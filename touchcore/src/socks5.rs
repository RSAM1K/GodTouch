use std::io;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::timeout;

use crate::config::Config;
use crate::net::set_nodelay;
use crate::relay;

const CONNECT_TRY: Duration = Duration::from_millis(900);
const CONNECT_BUDGET: Duration = Duration::from_secs(4);

pub async fn serve(cfg: Config) -> io::Result<()> {
    let listener = TcpListener::bind(&cfg.listen).await?;
    tracing::info!("listening on {}", cfg.listen);
    serve_listener(listener, cfg).await
}

pub async fn serve_listener(listener: TcpListener, cfg: Config) -> io::Result<()> {
    loop {
        let (client, _) = listener.accept().await?;
        let cfg = cfg.clone();
        tokio::spawn(async move {
            if let Err(e) = handle(client, cfg).await {
                tracing::debug!("connection: {e}");
            }
        });
    }
}

async fn handle(mut client: TcpStream, cfg: Config) -> io::Result<()> {
    set_nodelay(&client)?;
    let (host, port) = handshake(&mut client).await?;
    let server = connect_upstream(&host, port).await?;
    set_nodelay(&server)?;
    reply_ok(&mut client).await?;
    relay::relay(client, server, cfg).await
}

/// Prefer IPv4. macOS often returns IPv4-mapped IPv6 first; connecting to it can hang.
async fn connect_upstream(host: &str, port: u16) -> io::Result<TcpStream> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return timeout(CONNECT_BUDGET, TcpStream::connect(SocketAddr::new(normalize_ip(ip), port)))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "upstream connect timeout"))?;
    }

    let raw: Vec<SocketAddr> = timeout(Duration::from_secs(2), tokio::net::lookup_host((host, port)))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "dns timeout"))??
        .map(|a| SocketAddr::new(normalize_ip(a.ip()), a.port()))
        .collect();

    if raw.is_empty() {
        return Err(io::Error::new(io::ErrorKind::NotFound, format!("no addresses for {host}")));
    }

    let mut v4 = Vec::new();
    let mut v6 = Vec::new();
    for a in raw {
        if a.is_ipv4() {
            v4.push(a);
        } else {
            v6.push(a);
        }
    }

    let mut last_err = None;
    let deadline = tokio::time::Instant::now() + CONNECT_BUDGET;
    for addr in v4.into_iter().chain(v6) {
        let remain = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remain.is_zero() {
            break;
        }
        let slice = remain.min(CONNECT_TRY);
        match timeout(slice, TcpStream::connect(addr)).await {
            Ok(Ok(s)) => return Ok(s),
            Ok(Err(e)) => last_err = Some(e),
            Err(_) => {
                last_err = Some(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!("connect {addr} timeout"),
                ));
            }
        }
    }
    Err(last_err.unwrap_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "upstream connect failed")))
}

fn normalize_ip(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
        other => other,
    }
}

async fn handshake(client: &mut TcpStream) -> io::Result<(String, u16)> {
    let mut byte = [0u8; 1];

    client.read_exact(&mut byte).await?;
    if byte[0] != 0x05 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "bad socks version"));
    }
    client.read_exact(&mut byte).await?;
    let nmethods = byte[0] as usize;
    if nmethods > 0 {
        let mut methods = vec![0u8; nmethods];
        client.read_exact(&mut methods).await?;
    }
    client.write_all(&[0x05, 0x00]).await?;
    client.flush().await?;

    let mut head = [0u8; 4];
    client.read_exact(&mut head).await?;
    if head[0] != 0x05 || head[1] != 0x01 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "only CONNECT"));
    }

    let (host, port) = match head[3] {
        0x01 => {
            let mut ip = [0u8; 4];
            client.read_exact(&mut ip).await?;
            let port = read_port(client).await?;
            (
                format!("{}.{}.{}.{}", ip[0], ip[1], ip[2], ip[3]),
                port,
            )
        }
        0x03 => {
            client.read_exact(&mut byte).await?;
            let len = byte[0] as usize;
            let mut host = vec![0u8; len];
            client.read_exact(&mut host).await?;
            let port = read_port(client).await?;
            (String::from_utf8_lossy(&host).into_owned(), port)
        }
        0x04 => {
            let mut ip = [0u8; 16];
            client.read_exact(&mut ip).await?;
            let port = read_port(client).await?;
            (std::net::Ipv6Addr::from(ip).to_string(), port)
        }
        _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "bad atyp")),
    };

    Ok((host, port))
}

async fn read_port(client: &mut TcpStream) -> io::Result<u16> {
    let mut port_buf = [0u8; 2];
    client.read_exact(&mut port_buf).await?;
    Ok(u16::from_be_bytes(port_buf))
}

async fn reply_ok(client: &mut TcpStream) -> io::Result<()> {
    client
        .write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv6Addr;

    #[test]
    fn mapped_v6_becomes_v4() {
        let mapped = IpAddr::V6(Ipv6Addr::new(0, 0, 0, 0, 0, 0xffff, 0xa29f, 0x89e8));
        match normalize_ip(mapped) {
            IpAddr::V4(v4) => assert_eq!(v4.octets(), [162, 159, 137, 232]),
            other => panic!("expected v4, got {other}"),
        }
    }
}
