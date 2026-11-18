#!/usr/bin/env bash
# Собирает MCP-сервер tranq-mcp из папки mcp/ и подписывает его.
#
#   scripts/build-tranq-mcp.sh <путь>   # вручную, бинарник ляжет в <путь>
#
# Из Xcode скрипт зовёт фаза «Build tranq-mcp» цели Tranq без аргументов:
# бинарник кладётся в Tranq.app/Contents/MacOS/tranq-mcp и подписывается до
# подписи бандла, иначе внешняя подпись его не запечатает.
#
# Сборка без сети: зависимости лежат в mcp/vendor, toolchain только локальный.
# Нет Go — сборка падает, а не пропускается: иначе выйдет приложение без сервера.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# У Xcode, запущенного из Finder, PATH минимальный, поэтому Go ищется и в
# обычных местах установки.
find_go() {
  local dir
  if command -v go >/dev/null 2>&1; then
    command -v go
    return 0
  fi
  for dir in /opt/homebrew/bin /usr/local/go/bin /usr/local/bin "$HOME/go/bin" "$HOME/.local/bin"; do
    if [[ -x "$dir/go" ]]; then
      echo "$dir/go"
      return 0
    fi
  done
  return 1
}

# Версия приложения из проекта, когда скрипт запущен не из Xcode
project_version() {
  awk '/MARKETING_VERSION = / { v = $3; sub(/;$/, "", v) }
       /PRODUCT_BUNDLE_IDENTIFIER = "nuter.Tranq";/ { print v; exit }' \
    "$ROOT/Tranq.xcodeproj/project.pbxproj"
}

if [[ $# -ge 1 ]]; then
  DEST="$1"
  CACHE_DIR="$ROOT/build/go-cache"
elif [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${EXECUTABLE_FOLDER_PATH:-}" ]]; then
  DEST="$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH/tranq-mcp"
  CACHE_DIR="${DERIVED_FILE_DIR:?}/go-cache"
else
  die "укажите путь к бинарнику: scripts/build-tranq-mcp.sh <путь>"
fi

GO="$(find_go)" || die "нет Go, установите toolchain, https://go.dev/dl"

VERSION="${MARKETING_VERSION:-$(project_version)}"
[[ -n "$VERSION" ]] || die "не удалось узнать MARKETING_VERSION"

mkdir -p "$(dirname "$DEST")" "$CACHE_DIR"

# Кэш сборки внутри папки сборки, а не общий кэш пользователя. go build
# инкрементален: без изменений в mcp/ повторный запуск занимает доли секунды.
(
  cd "$ROOT/mcp"
  env GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
    GOFLAGS=-mod=vendor GOTOOLCHAIN=local GOPROXY=off GOCACHE="$CACHE_DIR" \
    "$GO" build -mod=vendor -trimpath \
      -ldflags "-s -w -X main.version=$VERSION" \
      -o "$DEST" .
) || die "сборка tranq-mcp не удалась"

# Подпись той же личностью, что и приложение: ad-hoc, если личности нет.
# Hardened runtime — если он включён у цели; вне Xcode включён всегда.
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]]; then
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  [[ -n "$IDENTITY" ]] || IDENTITY="-"
  # Постоянный идентификатор вместо хэша, который ставит компоновщик Go
  SIGN_ARGS=(--force --sign "$IDENTITY" --timestamp=none
    --identifier "${PRODUCT_BUNDLE_IDENTIFIER:-nuter.Tranq}.tranq-mcp")
  [[ "${ENABLE_HARDENED_RUNTIME:-YES}" == "YES" ]] && SIGN_ARGS+=(--options runtime)
  codesign "${SIGN_ARGS[@]}" "$DEST" || die "не удалось подписать tranq-mcp"
fi

echo "tranq-mcp $VERSION: $DEST"
