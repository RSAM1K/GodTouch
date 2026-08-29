#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="/Applications/Touch.app"
BUILD="/tmp/Touch-build.app"
BIN="$BUILD/Contents/MacOS"
RES="$BUILD/Contents/Resources"
VENDOR="$ROOT/vendor"
ZAPRET="/tmp/zapret"

# Build tg-proxy (patched DC map for all Telegram DCs)
TGPROXY="/tmp/tg-proxy"
PATCH="$ROOT/scripts/patches/tg-proxy-ip_map.rs"
if [[ ! -d "$TGPROXY" ]]; then
  git clone --depth 1 https://github.com/SmOkEnksp/tg-proxy.git "$TGPROXY"
fi
cp "$PATCH" "$TGPROXY/src/ip_map.rs"
python3 "$ROOT/scripts/patches/apply-tg-proxy-patches.py" "$TGPROXY"
echo "Building tg-proxy…"
export PATH="/opt/homebrew/bin:$PATH"
(cd "$TGPROXY" && cargo build --release)
cp "$(cd "$TGPROXY" && cargo metadata --format-version 1 | python3 -c "import sys,json; print(json.load(sys.stdin)['target_directory'])")/release/tg-proxy" "$VENDOR/tg-proxy"

if [[ ! -x "$VENDOR/tpws" ]]; then
  echo "Building tpws from zapret…"
  if [[ ! -d "$ZAPRET" ]]; then
    git clone --depth 1 https://github.com/bol-van/zapret.git "$ZAPRET"
  fi
  make -C "$ZAPRET" mac
  cp "$ZAPRET/binaries/my/tpws" "$VENDOR/tpws"
fi

if [[ ! -x "$VENDOR/spoofdpi" ]]; then
  echo "Building spoofdpi…"
  SPOOF="/tmp/SpoofDPI"
  if [[ ! -d "$SPOOF" ]]; then
    git clone --depth 1 https://github.com/xvzc/SpoofDPI.git "$SPOOF"
  fi
  export PATH="/opt/homebrew/bin:$PATH"
  (cd "$SPOOF" && go build -o "$VENDOR/spoofdpi" ./cmd/spoofdpi/)
fi

echo "Building touchcore…"
export PATH="/opt/homebrew/bin:$PATH"
(cd "$ROOT/touchcore" && cargo build --release)
TOUCHCORE_OUT="$(cd "$ROOT/touchcore" && cargo metadata --format-version 1 | python3 -c "import sys,json; print(json.load(sys.stdin)['target_directory'])")/release/touchcore"
cp "$TOUCHCORE_OUT" "$VENDOR/touchcore"

pkill -f "/Touch.app/Contents/MacOS/Touch" 2>/dev/null || true
sleep 0.4

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
cp "$VENDOR/tpws" "$RES/tpws"
cp "$VENDOR/ciadpi" "$RES/ciadpi"
cp "$VENDOR/spoofdpi" "$RES/spoofdpi"
cp "$VENDOR/touchcore" "$RES/touchcore"
cp "$VENDOR/tg-proxy" "$RES/tg-proxy"
cp "$ROOT/Resources/lists/"*.txt "$RES/"
cp "$ROOT/Resources/menubar-hand.png" "$RES/"
cp "$ROOT/Resources/hands-"*.png "$RES/"
chmod +x "$BIN/Touch" "$RES/tpws" "$RES/ciadpi" "$RES/spoofdpi" "$RES/touchcore" "$RES/tg-proxy"

rm -rf "$INSTALL"
cp -R "$BUILD" "$INSTALL"
rm -rf "$BUILD"
codesign --force --deep -s - "$INSTALL" 2>/dev/null || true
xattr -cr "$INSTALL" 2>/dev/null || true

echo "Installed $INSTALL (единственная копия)"
