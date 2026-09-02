#!/usr/bin/env python3
"""Apply God Touch patches to upstream tg-proxy sources."""
from pathlib import Path
import sys

TGPROXY = Path(sys.argv[1])

proxy_rs = TGPROXY / "src" / "proxy.rs"
text = proxy_rs.read_text()

if "media not blacklisted" not in text:
    old_blacklist = """    if any_redirect && all_redirects {
        ws_blacklist.lock().await.insert(*dc_key);
        warn!("[{}] DC{}{} blacklisted (all 302)", label, dc, media_tag);
    } else {"""

    new_blacklist = """    if any_redirect && all_redirects {
        // Media DCs (video/voice) must keep WS — TCP fallback is blocked by DPI.
        if !dc_key.1 {
            ws_blacklist.lock().await.insert(*dc_key);
            warn!("[{}] DC{}{} blacklisted (all 302)", label, dc, media_tag);
        } else {
            warn!("[{}] DC{}m WS redirect — media not blacklisted", label, dc);
        }
    } else {"""

    if old_blacklist not in text:
        print("tg-proxy patch: blacklist block not found", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_blacklist, new_blacklist)

if "video needs WebSocket" not in text:
    old_fallback = """    let Some(ws_stream) = ws_stream else {
        info!("[{}] DC{}{} -> TCP fallback to {}:{}", label, dc, media_tag, dst_host, port);
        tcp_fallback(reader, writer, &dst_host, port, &init_bytes, &label, &stats, Some(dc), is_media)
            .await;
        return Ok(());
    };"""

    new_fallback = """    let Some(ws_stream) = ws_stream else {
        if is_media {
            warn!(
                "[{}] DC{}m WS failed for {}:{} — retrying (video needs WebSocket)",
                label, dc, dst_host, port
            );
            tokio::time::sleep(Duration::from_millis(250)).await;
            if let Some(retry) = try_ws_connect(
                target_ip, &domains, &dc_key, &label, dc, media_tag, &dst_host, port,
                &config, &tls, &pool, &stats, &ws_blacklist, &dc_fail_until,
            ).await {
                stats.ws.fetch_add(1, Relaxed);
                dc_fail_until.lock().await.remove(&dc_key);
                let splitter = if was_patched { MsgSplitter::new(&init_bytes) } else { None };
                let (ws_read, mut ws_write) = tokio::io::split(retry);
                if let Err(e) = send_frame(&mut ws_write, &init_bytes).await {
                    warn!("[{}] failed to send init frame (retry): {}", label, e);
                    return Ok(());
                }
                bridge_ws(
                    reader, writer, ws_read, ws_write,
                    splitter, label, stats, dc, media_tag, dst_host, port,
                ).await;
                return Ok(());
            }
        }
        info!("[{}] DC{}{} -> TCP fallback to {}:{}", label, dc, media_tag, dst_host, port);
        tcp_fallback(reader, writer, &dst_host, port, &init_bytes, &label, &stats, Some(dc), is_media)
            .await;
        return Ok(());
    };"""

    if old_fallback not in text:
        print("tg-proxy patch: WS fallback block not found", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_fallback, new_fallback)

# ── Compiler warning fixes (idempotent) ─────────────────────────────────────

if "let (mut rr, mut rw) = remote.into_split();" in text:
    text = text.replace(
        "let (mut rr, mut rw) = remote.into_split();",
        "let (rr, rw) = remote.into_split();",
        1,
    )

if "let (mut rr, mut rw) = remote.into_split();" in text:
    text = text.replace(
        "let (mut rr, mut rw) = remote.into_split();",
        "let (rr, mut rw) = remote.into_split();",
        1,
    )

old_ok_branch = """            Ok(stream) => {
                all_redirects = false;
                return Some(stream);
            }"""
new_ok_branch = """            Ok(stream) => {
                return Some(stream);
            }"""
if old_ok_branch in text:
    text = text.replace(old_ok_branch, new_ok_branch)

# First WS domain failure used to `break`, so media never tried kwsN after kwsN-1.
old_break = """            Err(e) => {
                stats.ws_errors.fetch_add(1, Relaxed);
                all_redirects = false;
                warn!("[{}] DC{}{} WS failed: {}", label, dc, media_tag, e);
                break;
            }"""
new_continue = """            Err(e) => {
                stats.ws_errors.fetch_add(1, Relaxed);
                all_redirects = false;
                warn!("[{}] DC{}{} WS failed: {}", label, dc, media_tag, e);
                continue;
            }"""
if old_break in text:
    text = text.replace(old_break, new_continue)

# Media must stay on WebSocket — TCP to media IPs is DPI-shaped / crawling.
if "media stays on WebSocket" not in text:
    old_media_tcp = """        info!("[{}] DC{}{} -> TCP fallback to {}:{}", label, dc, media_tag, dst_host, port);
        tcp_fallback(reader, writer, &dst_host, port, &init_bytes, &label, &stats, Some(dc), is_media)
            .await;
        return Ok(());
    };"""
    new_media_tcp = """        if is_media {
            warn!(
                "[{}] DC{}m refusing TCP fallback for {}:{} — media stays on WebSocket",
                label, dc, dst_host, port
            );
            dc_fail_until.lock().await.remove(&dc_key);
            return Ok(());
        }
        info!("[{}] DC{}{} -> TCP fallback to {}:{}", label, dc, media_tag, dst_host, port);
        tcp_fallback(reader, writer, &dst_host, port, &init_bytes, &label, &stats, Some(dc), is_media)
            .await;
        return Ok(());
    };"""
    if old_media_tcp not in text:
        print("tg-proxy patch: media TCP skip block not found", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_media_tcp, new_media_tcp, 1)

# Don't put media DCs on a 60s cooldown (that forces every photo onto TCP).
old_cd = """    } else {
        let until = Instant::now() + Duration::from_secs(COOLDOWN_SECS);
        dc_fail_until.lock().await.insert(*dc_key, until);
        info!("[{}] DC{}{} WS cooldown for {}s", label, dc, media_tag, COOLDOWN_SECS);
    }"""
new_cd = """    } else if !dc_key.1 {
        let until = Instant::now() + Duration::from_secs(COOLDOWN_SECS);
        dc_fail_until.lock().await.insert(*dc_key, until);
        info!("[{}] DC{}{} WS cooldown for {}s", label, dc, media_tag, COOLDOWN_SECS);
    } else {
        info!("[{}] DC{}m WS failed — no cooldown (retry next photo)", label, dc);
    }"""
if old_cd in text:
    text = text.replace(old_cd, new_cd)

# Never open raw TCP to Telegram IPs — SYN_SENT hangs and media crawls.
if "skip TCP fallback (DPI shapes" not in text:
    import re
    text2, n = re.subn(
        r"async fn tcp_fallback\([\s\S]*?info!\(\"\[\{\}\] \{\} TCP fallback closed\", label, dc_tag\);\n\}",
        """async fn tcp_fallback(
    _reader: OwnedReadHalf,
    _writer: OwnedWriteHalf,
    dst: &str,
    port: u16,
    _init: &[u8],
    label: &str,
    _stats: &Stats,
    dc: Option<u8>,
    is_media: bool,
) {
    // skip TCP fallback (DPI shapes Telegram IPs into a trickle / SYN_SENT blackhole)
    let tag = match dc {
        Some(d) => format!("DC{}{}", d, if is_media { "m" } else { "" }),
        None => "DC?".to_string(),
    };
    warn!(
        "[{}] {} skip TCP fallback to {}:{} (DPI shapes Telegram IPs)",
        label, tag, dst, port
    );
}""",
        text,
        count=1,
    )
    if n != 1:
        print("tg-proxy patch: tcp_fallback fn not replaced", file=sys.stderr)
        sys.exit(1)
    text = text2

# Cooldown used to force the next 60s onto TCP. Always retry WS.
if "always retry WS" not in text:
    text = text.replace(
        """    } else if !dc_key.1 {
        let until = Instant::now() + Duration::from_secs(COOLDOWN_SECS);
        dc_fail_until.lock().await.insert(*dc_key, until);
        info!("[{}] DC{}{} WS cooldown for {}s", label, dc, media_tag, COOLDOWN_SECS);
    } else {
        info!("[{}] DC{}m WS failed — no cooldown (retry next photo)", label, dc);
    }""",
        """    } else {
        // always retry WS — cooldown used to dump the next minute onto TCP
        info!("[{}] DC{}{} WS failed — retry next attempt", label, dc, media_tag);
    }""",
    )

# Don't take the blacklist/cooldown TCP path either.
if "blacklisted -> skip TCP" not in text:
    text = text.replace(
        """    if ws_blacklist.lock().await.contains(&dc_key) {
        debug!("[{}] DC{}{} blacklisted -> TCP fallback", label, dc, media_tag);
        tcp_fallback(reader, writer, &dst_host, port, &init_bytes, &label, &stats, Some(dc), is_media)
            .await;
        return Ok(());
    }""",
        """    if ws_blacklist.lock().await.contains(&dc_key) {
        debug!("[{}] DC{}{} blacklisted -> skip TCP", label, dc, media_tag);
        return Ok(());
    }""",
    )
    text = text.replace(
        """            debug!("[{}] DC{}{} cooldown ({}s) -> TCP fallback", label, dc, media_tag, secs);
            tcp_fallback(reader, writer, &dst_host, port, &init_bytes, &label, &stats, Some(dc), is_media)
                .await;
            return Ok(());""",
        """            debug!("[{}] DC{}{} cooldown ({}s) -> skip TCP", label, dc, media_tag, secs);
            return Ok(());""",
    )

# Telegram Desktop prefers IPv6 DCs — rejecting them makes media crawl.
if "dc_from_ipv6" not in text:
    text = text.replace(
        "use crate::ip_map::{dc_from_ip, is_telegram_ip, ws_domains};",
        "use crate::ip_map::{dc_from_ip, dc_from_ipv6, is_telegram_ip, is_telegram_ipv6, ws_domains};",
    )

if "IPv6 Telegram -> WS" not in text:
    old_v6 = """        4 => {
            let mut raw = [0u8; 16];
            timeout(reader.read_exact(&mut raw), 10).await??;
            let mut port_buf = [0u8; 2];
            timeout(reader.read_exact(&mut port_buf), 10).await??;
            let port = u16::from_be_bytes(port_buf);
            let addr = std::net::Ipv6Addr::from(raw);
            warn!(
                "[{}] IPv6 not supported: [{}]:{} — disable IPv6 in Telegram settings",
                label, addr, port
            );
            writer.write_all(&socks5_reply(0x05)).await?;
            writer.flush().await?;
            return Ok(());
        }"""
    new_v6 = """        4 => {
            // Port is read below with IPv4/domain — keep the same shape.
            let mut raw = [0u8; 16];
            timeout(reader.read_exact(&mut raw), 10).await??;
            let addr = std::net::Ipv6Addr::from(raw);
            // Marker host; real routing uses ipv6_hint after port parse.
            (format!("[{addr}]"), None)
        }"""
    if old_v6 not in text:
        print("tg-proxy patch: IPv6 reject block not found", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_v6, new_v6)

    old_dest = """    let (dst_host, dst_ipv4): (String, Option<Ipv4Addr>) = match atyp {"""
    new_dest = """    let mut ipv6_hint: Option<(u8, bool)> = None;
    let (dst_host, dst_ipv4): (String, Option<Ipv4Addr>) = match atyp {"""
    if old_dest not in text:
        print("tg-proxy patch: dest match not found", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_dest, new_dest, 1)

    # After parsing atyp=4 host, stash DC hint once we have the addr in dst_host.
    # Simpler: after port parse, detect IPv6 Telegram from dst_host.
    old_tg = """    // ── Non-Telegram: passthrough ─────────────────────────────────────────────
    let tg_ip = match dst_ipv4.filter(|ip| is_telegram_ip(*ip)) {
        Some(ip) => ip,
        None => {
            stats.passthrough.fetch_add(1, Relaxed);
            debug!("[{}] passthrough -> {}:{}", label, dst_host, port);"""
    new_tg = """    // ── IPv6 Telegram → WS (Desktop prefers AAAA) ────────────────────────────
    // IPv6 Telegram -> WS
    if dst_host.starts_with('[') {
        if let Ok(v6) = dst_host.trim_matches(|c| c == '[' || c == ']').parse::<std::net::Ipv6Addr>() {
            if is_telegram_ipv6(v6) {
                ipv6_hint = dc_from_ipv6(v6);
                info!(
                    "[{}] IPv6 Telegram [{}]:{} -> WS hint={:?}",
                    label, v6, port, ipv6_hint
                );
            } else {
                warn!("[{}] non-Telegram IPv6 [{}]:{} rejected", label, v6, port);
                writer.write_all(&socks5_reply(0x05)).await?;
                writer.flush().await?;
                return Ok(());
            }
        }
    }

    // ── Non-Telegram: passthrough ─────────────────────────────────────────────
    let tg_ip = if ipv6_hint.is_some() {
        // Synthetic IPv4 key — real DC comes from init / ipv6_hint.
        Ipv4Addr::new(149, 154, 167, 220)
    } else {
        match dst_ipv4.filter(|ip| is_telegram_ip(*ip)) {
        Some(ip) => ip,
        None => {
            stats.passthrough.fetch_add(1, Relaxed);
            debug!("[{}] passthrough -> {}:{}", label, dst_host, port);"""
    if old_tg not in text:
        print("tg-proxy patch: telegram detect block not found", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_tg, new_tg, 1)

    # Close the new else-branch for ipv6_hint — the old match ends with `};`
    # After passthrough return, we have `        }\n    };` closing the match.
    old_close = """            return Ok(());
        }
    };

    // ── Telegram DC: send SOCKS5 success, read MTProto init ──────────────────"""
    new_close = """            return Ok(());
        }
    }
    };

    // ── Telegram DC: send SOCKS5 success, read MTProto init ──────────────────"""
    if old_close not in text:
        print("tg-proxy patch: tg_ip close block not found", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_close, new_close, 1)

    old_resolve = """    let (dc, is_media, init_bytes, was_patched) = resolve_dc(tg_ip, &init, &config);"""
    new_resolve = """    let (dc, is_media, init_bytes, was_patched) =
        resolve_dc(tg_ip, &init, &config, ipv6_hint);"""
    if old_resolve not in text:
        print("tg-proxy patch: resolve_dc call not found", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_resolve, new_resolve, 1)

    old_fn = """fn resolve_dc(ip: Ipv4Addr, init: &[u8; 64], config: &Config) -> (Option<u8>, bool, Vec<u8>, bool) {
    if let Some((dc, is_media)) = extract_dc(init) {
        if config.dc_ip(dc).is_some() {
            return (Some(dc), is_media, init.to_vec(), false);
        }
    }
    if let Some((dc, is_media)) = dc_from_ip(ip) {
        if config.dc_ip(dc).is_some() {
            let mut patched = init.to_vec();
            patch_dc(&mut patched, dc, is_media);
            return (Some(dc), is_media, patched, true);
        }
    }
    (None, false, init.to_vec(), false)
}"""
    new_fn = """fn resolve_dc(
    ip: Ipv4Addr,
    init: &[u8; 64],
    config: &Config,
    ipv6_hint: Option<(u8, bool)>,
) -> (Option<u8>, bool, Vec<u8>, bool) {
    if let Some((dc, is_media)) = extract_dc(init) {
        if config.dc_ip(dc).is_some() {
            return (Some(dc), is_media, init.to_vec(), false);
        }
        // Packet DC not configured — keep media flag, remap onto a configured hub.
        if let Some(hub_dc) = preferred_hub_dc(config) {
            let mut patched = init.to_vec();
            patch_dc(&mut patched, hub_dc, is_media);
            return (Some(hub_dc), is_media, patched, true);
        }
    }
    if let Some((dc, is_media)) = ipv6_hint.or_else(|| dc_from_ip(ip)) {
        if config.dc_ip(dc).is_some() {
            let mut patched = init.to_vec();
            patch_dc(&mut patched, dc, is_media);
            return (Some(dc), is_media, patched, true);
        }
        if let Some(hub_dc) = preferred_hub_dc(config) {
            let mut patched = init.to_vec();
            patch_dc(&mut patched, hub_dc, is_media);
            return (Some(hub_dc), is_media, patched, true);
        }
    }
    (None, false, init.to_vec(), false)
}

fn preferred_hub_dc(config: &Config) -> Option<u8> {
    for d in [2u8, 4, 1, 3, 5] {
        if config.dc_ip(d).is_some() {
            return Some(d);
        }
    }
    None
}"""
    if old_fn not in text:
        print("tg-proxy patch: resolve_dc fn not found", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_fn, new_fn, 1)

proxy_rs.write_text(text)
print("tg-proxy patches applied")

config_rs = TGPROXY / "src" / "config.rs"
cfg = config_rs.read_text()
if "pub skip_tls_verify: bool," in cfg:
    cfg = cfg.replace("    pub skip_tls_verify: bool,\n", "")
    config_rs.write_text(cfg)

main_rs = TGPROXY / "src" / "main.rs"
main = main_rs.read_text()
if "        skip_tls_verify: cli.skip_tls_verify,\n" in main:
    main = main.replace("        skip_tls_verify: cli.skip_tls_verify,\n", "")
if ".with_writer(std::io::stderr)" not in main:
    main = main.replace(
        """    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(level)),
        )
        .with_target(false)
        .init();""",
        """    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(level)),
        )
        .with_writer(std::io::stderr)
        .with_target(false)
        .init();""",
    )
main_rs.write_text(main)

ws_rs = TGPROXY / "src" / "websocket.rs"
ws = ws_rs.read_text()
# Keep per-frame flush on the init path; only batch-flush send_frames.
# Stripping flush from send_frame made Telegram get no MTProto reply → error -444
# and "proxy not configured correctly and will be disabled".
old_tcp = """    let tcp = timeout(connect_timeout, TcpStream::connect((ip, 443u16)))
        .await
        .map_err(|_| WsError::Timeout)?
        .map_err(WsError::Io)?;"""
new_tcp = """    let tcp = timeout(connect_timeout, connect_tcp(ip, domain))
        .await
        .map_err(|_| WsError::Timeout)?
        .map_err(WsError::Io)?;"""
if old_tcp in ws and "async fn connect_tcp" not in ws:
    if "std::collections::HashMap" not in ws:
        ws = ws.replace(
            "use std::io;\n",
            "use std::collections::HashMap;\nuse std::io;\nuse std::net::SocketAddr;\nuse std::time::Instant;\n",
            1,
        )
        ws = ws.replace("use std::sync::Arc;\n", "use std::sync::{Arc, Mutex};\n", 1)
    ws = ws.replace(
        "/// Connect to `ip:443` via TLS with `domain` as SNI, then perform WebSocket upgrade.\n",
        """const DNS_TTL: Duration = Duration::from_secs(120);

fn dns_cache() -> &'static Mutex<HashMap<String, (SocketAddr, Instant)>> {
    static CACHE: std::sync::OnceLock<Mutex<HashMap<String, (SocketAddr, Instant)>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// TCP to `domain:443` (Cloudflare fronts) or to `ip:443` for telegram.org SNI.
async fn connect_tcp(ip: Ipv4Addr, domain: &str) -> io::Result<TcpStream> {
    if domain.ends_with(".web.telegram.org") {
        return TcpStream::connect((ip, 443u16)).await;
    }
    let cached = dns_cache().lock().ok().and_then(|g| {
        g.get(domain)
            .filter(|(_, at)| at.elapsed() < DNS_TTL)
            .map(|(addr, _)| *addr)
    });
    if let Some(addr) = cached {
        return TcpStream::connect(addr).await;
    }
    let addr = tokio::net::lookup_host((domain, 443u16))
        .await?
        .find(|a| a.is_ipv4())
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no IPv4 for WS host"))?;
    if let Ok(mut cache) = dns_cache().lock() {
        cache.insert(domain.to_string(), (addr, Instant::now()));
    }
    TcpStream::connect(addr).await
}

/// Connect via TLS with `domain` as SNI, then perform WebSocket upgrade.
""",
        1,
    )
    ws = ws.replace(old_tcp, new_tcp, 1)
ws_rs.write_text(ws)

# Reply SOCKS success before passthrough TCP (telegram.org is blocked, 0x05 disables Desktop).
old_pass = """        None => {
            stats.passthrough.fetch_add(1, Relaxed);
            debug!("[{}] passthrough -> {}:{}", label, dst_host, port);

            let remote = match timeout(
                TcpStream::connect(format!("{}:{}", dst_host, port)),
                10,
            )
            .await
            {
                Ok(Ok(s)) => s,
                _ => {
                    warn!("[{}] passthrough connect failed to {}:{}", label, dst_host, port);
                    writer.write_all(&socks5_reply(0x05)).await?;
                    writer.flush().await?;
                    return Ok(());
                }
            };
            let _ = remote.set_nodelay(true);

            writer.write_all(&socks5_reply(0x00)).await?;
            writer.flush().await?;

            let (rr, rw) = remote.into_split();
            let t1 = tokio::spawn(async move { pipe_drain(reader, rw).await });
            let t2 = tokio::spawn(async move { pipe_drain(rr, writer).await });
            let _ = tokio::join!(t1, t2);
            return Ok(());
        }"""
new_pass = """        None => {
            stats.passthrough.fetch_add(1, Relaxed);
            debug!("[{}] passthrough -> {}:{}", label, dst_host, port);

            writer.write_all(&socks5_reply(0x00)).await?;
            writer.flush().await?;

            let remote = match timeout(
                TcpStream::connect(format!("{}:{}", dst_host, port)),
                2,
            )
            .await
            {
                Ok(Ok(s)) => s,
                _ => {
                    warn!("[{}] passthrough connect failed to {}:{}", label, dst_host, port);
                    return Ok(());
                }
            };
            let _ = remote.set_nodelay(true);

            let (rr, rw) = remote.into_split();
            let t1 = tokio::spawn(async move { pipe_drain(reader, rw).await });
            let t2 = tokio::spawn(async move { pipe_drain(rr, writer).await });
            let _ = tokio::join!(t1, t2);
            return Ok(());
        }"""
if old_pass in text:
    text = text.replace(old_pass, new_pass)
text = text.replace(
    """            } else {
                warn!("[{}] non-Telegram IPv6 [{}]:{} rejected", label, v6, port);
                writer.write_all(&socks5_reply(0x05)).await?;
                writer.flush().await?;
                return Ok(());
            }""",
    """            } else {
                warn!("[{}] non-Telegram IPv6 [{}]:{} — still WS (Desktop check)", label, v6, port);
                ipv6_hint = Some((2, false));
            }""",
)
text = text.replace("&[String; 2]", "&[String]")
proxy_rs.write_text(text)

pool_rs = TGPROXY / "src" / "pool.rs"
pool = pool_rs.read_text()
pool = pool.replace("&[String; 2]", "&[String]")
pool = pool.replace(
    """            Err(e) => {
                warn!("Pool pre-connect {} failed: {}", domain, e);
                return None;
            }""",
    """            Err(e) => {
                warn!("Pool pre-connect {} failed: {}", domain, e);
                continue;
            }""",
)
pool = pool.replace("let domains = domains.clone();", "let domains = domains.to_vec();")
if "if dc != 2" not in pool:
    pool = pool.replace(
        "        for (dc, ip) in dc_ips {\n            for is_media in [false, true] {",
        "        for (dc, ip) in dc_ips {\n            if dc != 2 {\n                continue;\n            }\n            for is_media in [false, true] {",
        1,
    )
pool_rs.write_text(pool)
