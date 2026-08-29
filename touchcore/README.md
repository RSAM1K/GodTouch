# touchcore

Native Rust DPI engine for **God Touch** — deep macOS socket control.

Techniques ported from [zapret/tpws](https://github.com/bol-van/zapret) (MIT).

## v0.3

- **tlsrec v2** — two real TLS Handshake records (`0x16`), tpws-style split at marker
- **`--self-test`** — loopback SOCKS5 + tamper check, prints `self-test OK`

## v0.2

- **Multisplit** — `--split-pos 1,sni,midsld` (up to 8 markers)
- **macOS TCP_NOPUSH** cork + raw `send()` per segment (reliable split on wire)
- **MSG_OOB** for `--oob`
- **Integration tests** — split/combo/oob preserve ClientHello payload

## macOS notes

- Upstream SOCKS relay keeps **byte-stream order** for real ClientHello parts.
- `--tlsrec` splits one record into two Handshake records (+5 bytes on wire); handshake body unchanged.
- Disorder + multisplit = separate corked TCP segments.

## Flags

| Flag | Effect |
|------|--------|
| `--split-pos LIST` | comma-separated: 1, 2, 3, sni, midsld |
| `--split MARKER` | single split (shortcut) |
| `--disorder` | multisplit + corked segments |
| `--disorder-ttl N` | reserved (future decoys) |
| `--tlsrec 1\|midsld` | split ClientHello into 2 Handshake records |
| `--self-test` | loopback SOCKS5 tamper check, then exit |
| `--oob` | OOB byte segment |
| `--seg-delay-ms N` | optional delay between segments |

### Recommended

```bash
touchcore --self-test --split-pos midsld --disorder --tlsrec midsld
```

Touch profiles: `combo-midsld`, `combo-sni`, `multi-sni-midsld`.

Auto-fallback: if touchcore fails probe, Touch switches to equivalent tpws profile.
