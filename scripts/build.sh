#!/bin/zsh
# God Touch — сборка Touch.app в /Applications
# Требует: Apple Silicon, macOS 14+, Xcode CLT, Homebrew (go, rust), python3
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="/Applications/Touch.app"
BUILD="/tmp/Touch-build.app"
BIN="$BUILD/Contents/MacOS"
RES="$BUILD/Contents/Resources"
VENDOR="$ROOT/vendor"
ZAPRET="/tmp/zapret"
TGPROXY="/tmp/tg-proxy"
SPOOF="/tmp/SpoofDPI"
BYEDPI="/tmp/byedpi"
PATCH="$ROOT/scripts/patches/tg-proxy-ip_map.rs"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

die() { echo "Ошибка: $*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "не найден «$1». Установи зависимости из README (раздел Установка)."
}

echo "==> Проверка окружения"
[[ "$(uname -m)" == "arm64" ]] || die "нужен Apple Silicon (arm64), сейчас: $(uname -m)"
need git
need python3
need swiftc
need xcrun
need cargo
need rustc
need go
need make
xcrun --show-sdk-path >/dev/null 2>&1 || die "нет macOS SDK. Выполни: xcode-select --install"
mkdir -p "$VENDOR"

# --- tg-proxy ---
build_tg_proxy() {
  echo "==> tg-proxy"
  if [[ ! -f "$TGPROXY/src/proxy.rs" ]]; then
    rm -rf "$TGPROXY"
    git clone --depth 1 https://github.com/SmOkEnksp/tg-proxy.git "$TGPROXY"
  fi
  cp "$PATCH" "$TGPROXY/src/ip_map.rs"
  if ! python3 "$ROOT/scripts/patches/apply-tg-proxy-patches.py" "$TGPROXY"; then
    echo "Патчи не легли на старый клон — качаю tg-proxy заново…"
    rm -rf "$TGPROXY"
    git clone --depth 1 https://github.com/SmOkEnksp/tg-proxy.git "$TGPROXY"
    cp "$PATCH" "$TGPROXY/src/ip_map.rs"
    python3 "$ROOT/scripts/patches/apply-tg-proxy-patches.py" "$TGPROXY"
  fi
  (cd "$TGPROXY" && cargo build --release)
  local out
  out="$(cd "$TGPROXY" && cargo metadata --format-version 1 | python3 -c "import sys,json; print(json.load(sys.stdin)['target_directory'])")/release/tg-proxy"
  cp "$out" "$VENDOR/tg-proxy"
  chmod +x "$VENDOR/tg-proxy"
}

# --- tpws (zapret) ---
build_tpws() {
  [[ -x "$VENDOR/tpws" ]] && { echo "==> tpws уже есть"; return; }
  echo "==> tpws (zapret)"
  if [[ ! -d "$ZAPRET" ]]; then
    git clone --depth 1 https://github.com/bol-van/zapret.git "$ZAPRET"
  fi
  make -C "$ZAPRET" mac
  local bin=""
  for cand in "$ZAPRET/binaries/my/tpws" "$ZAPRET/tpws/tpws" "$ZAPRET/binaries/mac64/tpws"; do
    [[ -x "$cand" ]] && { bin="$cand"; break; }
  done
  [[ -n "$bin" ]] || die "tpws не собрался. Смотри вывод make в $ZAPRET"
  cp "$bin" "$VENDOR/tpws"
  chmod +x "$VENDOR/tpws"
}

# --- spoofdpi ---
build_spoofdpi() {
  [[ -x "$VENDOR/spoofdpi" ]] && { echo "==> spoofdpi уже есть"; return; }
  echo "==> spoofdpi"
  if [[ ! -d "$SPOOF" ]]; then
    git clone --depth 1 https://github.com/xvzc/SpoofDPI.git "$SPOOF"
  fi
  (cd "$SPOOF" && go build -o "$VENDOR/spoofdpi" ./cmd/spoofdpi/)
  chmod +x "$VENDOR/spoofdpi"
}

# --- ciadpi (ByeDPI) ---
build_ciadpi() {
  [[ -x "$VENDOR/ciadpi" ]] && { echo "==> ciadpi уже есть"; return; }
  echo "==> ciadpi (byedpi)"
  if [[ ! -d "$BYEDPI" ]]; then
    git clone --depth 1 https://github.com/hufrea/byedpi.git "$BYEDPI"
  fi
  make -C "$BYEDPI"
  [[ -x "$BYEDPI/ciadpi" ]] || die "ciadpi не собрался в $BYEDPI"
  cp "$BYEDPI/ciadpi" "$VENDOR/ciadpi"
  chmod +x "$VENDOR/ciadpi"
}

# --- touchcore ---
build_touchcore() {
  echo "==> touchcore"
  (cd "$ROOT/touchcore" && cargo build --release)
  local out
  out="$(cd "$ROOT/touchcore" && cargo metadata --format-version 1 | python3 -c "import sys,json; print(json.load(sys.stdin)['target_directory'])")/release/touchcore"
  cp "$out" "$VENDOR/touchcore"
  chmod +x "$VENDOR/touchcore"
}

build_tg_proxy
build_tpws
build_spoofdpi
build_ciadpi
build_touchcore

for b in tpws ciadpi spoofdpi touchcore tg-proxy; do
  [[ -x "$VENDOR/$b" ]] || die "нет бинарника vendor/$b"
done

echo "==> Swift UI → Touch.app"
pkill -x Touch 2>/dev/null || true
sleep 0.3

rm -rf "$BUILD" "$ROOT/Touch.app"
mkdir -p "$BIN" "$RES"

swiftc -parse-as-library \
  -O \
  -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework SwiftUI -framework AppKit -framework Combine -framework Network \
  -o "$BIN/Touch" \
  "$ROOT"/Sources/*.swift

cp "$ROOT/Resources/Info.plist" "$BUILD/Contents/Info.plist"
cp "$VENDOR/tpws" "$VENDOR/ciadpi" "$VENDOR/spoofdpi" "$VENDOR/touchcore" "$VENDOR/tg-proxy" "$RES/"
cp "$ROOT/Resources/lists/"*.txt "$RES/"
cp "$ROOT/Resources/menubar-hand.png" "$RES/"
cp "$ROOT/Resources/hands-"*.png "$RES/"
chmod +x "$BIN/Touch" "$RES/tpws" "$RES/ciadpi" "$RES/spoofdpi" "$RES/touchcore" "$RES/tg-proxy"

rm -rf "$INSTALL"
cp -R "$BUILD" "$INSTALL"
rm -rf "$BUILD"
codesign --force --deep -s - "$INSTALL" 2>/dev/null || true
xattr -cr "$INSTALL" 2>/dev/null || true

echo ""
echo "Готово: $INSTALL"
echo "Запуск: open $INSTALL"
