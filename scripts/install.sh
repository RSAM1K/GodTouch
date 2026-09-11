#!/bin/zsh
# God Touch — установка одной командой:
#   /bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/RSAM1K/GodTouch/main/scripts/install.sh)"
set -euo pipefail

REPO_URL="https://github.com/RSAM1K/GodTouch.git"
REPO_RAW="https://raw.githubusercontent.com/RSAM1K/GodTouch/main"
DEFAULT_DIR="${HOME}/GodTouch"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

die() { echo "Ошибка: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ "$(uname -s)" == "Darwin" ]] || die "только macOS"
[[ "$(uname -m)" == "arm64" ]] || die "нужен Apple Silicon (M1–M4)"

# --- Xcode CLT ---
if ! xcode-select -p >/dev/null 2>&1; then
  info "Ставлю Xcode Command Line Tools (откроется окно — нажми Install и дождись конца)…"
  xcode-select --install || true
  echo "Когда CLT установятся, снова запусти ту же однострочную команду."
  exit 0
fi

# --- Homebrew ---
if ! command -v brew >/dev/null 2>&1; then
  info "Ставлю Homebrew…"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
command -v brew >/dev/null 2>&1 || die "Homebrew не найден после установки"

# Persist PATH for next shells (once)
if [[ -x /opt/homebrew/bin/brew ]] && ! grep -q 'brew shellenv' "${HOME}/.zprofile" 2>/dev/null; then
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "${HOME}/.zprofile"
fi

# --- deps ---
info "Ставлю go, rust, python…"
brew install go rust python

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v go >/dev/null || die "go не в PATH"
command -v rustc >/dev/null || die "rustc не в PATH"
command -v cargo >/dev/null || die "cargo не в PATH"
command -v python3 >/dev/null || die "python3 не в PATH"
command -v swiftc >/dev/null || die "swiftc не найден (CLT?)"

# --- clone / update ---
DIR="${GODTOUCH_DIR:-$DEFAULT_DIR}"
if [[ -d "$DIR/.git" ]]; then
  info "Обновляю $DIR…"
  git -C "$DIR" fetch --depth 1 origin main
  git -C "$DIR" checkout -B main origin/main
else
  info "Клонирую в $DIR…"
  rm -rf "$DIR"
  git clone --depth 1 --branch main "$REPO_URL" "$DIR"
fi

chmod +x "$DIR/scripts/build.sh"
info "Собираю Touch.app (первая сборка долго — 10–20 мин)…"
# fresh caches if previous fail left junk
rm -rf /tmp/tg-proxy /tmp/Touch-build.app 2>/dev/null || true
"$DIR/scripts/build.sh"

info "Готово. Запускаю…"
open /Applications/Touch.app
echo ""
echo "God Touch установлен: /Applications/Touch.app"
echo "Исходники: $DIR"
echo "Обновить позже той же командой curl | zsh"
