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
    main_rs.write_text(main)
