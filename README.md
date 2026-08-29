# Touch

Menubar-приложение для macOS: обход DPI (YouTube, Discord…) + прокси для Telegram.

## Установка с GitHub (любой Mac)

**Нужно:** macOS 14+, Apple Silicon (M1/M2/M3/M4), интернет при первой сборке.

```bash
# 1. Инструменты разработчика (если ещё не стоят)
xcode-select --install

# 2. Homebrew — для сборки движков при первом build
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install go rust

# 3. Скачать и собрать
git clone https://github.com/RSAM1K/GodTouch.git
cd GodTouch
./scripts/build.sh

# 4. Запустить
open /Applications/Touch.app
```

`build.sh` ставит приложение в `/Applications/Touch.app`.

## Как пользоваться

1. Иконка в menubar → **CONNECT**
2. При первом запуске Telegram предложит SOCKS `127.0.0.1:1081` — **Подключить**
3. **CFG** — SCAN (подбор стратегии), PING (проверка сайтов), автозапуск

В браузере включи Secure DNS (например `https://dns.google/dns-query`).

## Что внутри

| Компонент | Роль |
|-----------|------|
| tpws / ciadpi / spoofdpi | DPI bypass, SOCKS `:1080` |
| PAC `:9877` | список доменов → прокси |
| tg-proxy | Telegram Desktop, SOCKS `:1081` |

Домены — `Resources/lists/`. Стратегии подбирает SCAN.

## Сборка вручную

```bash
./scripts/build.sh
```

При первом запуске скрипт сам скачает и соберёт `tpws`, `spoofdpi`, `tg-proxy`, если их нет в `vendor/`.

## Ветки

| Ветка | Назначение |
|-------|------------|
| `main` | стабильная версия |
| `beta` | тестовые изменения |

```bash
git checkout beta   # тестовая ветка
git checkout main   # стабильная
```

