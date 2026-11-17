#!/usr/bin/env bash
# Скачивает и проверяет зависимости, которые не хранятся в git.
#
#   scripts/fetch-deps.sh
#
# Для сборки и unit-тестов, в том числе в CI, скрипт не нужен: без моделей и
# бинарников проект собирается, недостающие функции просто отключаются.
#
# Версии и контрольные суммы зафиксированы ниже. Чтобы обновить зависимость,
# поменяйте версию и сумму вместе: shasum -a 256 <файл>.
# TranscribeCpp.xcframework сюда не входит: его скачивает Xcode через
# Packages/TranscribeCppBinary с проверкой собственной контрольной суммы.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/Golosok"
LLAMA_DIR="$ROOT/Vendor/llama"
CACHE_DIR="${GOLOSOK_DEPS_CACHE:-$ROOT/build/deps-cache}"

GIGAAM_URL="https://huggingface.co/memoravox/gigaam-v3-e2e-rnnt-gguf/resolve/main/gigaam-v3-e2e-rnnt-Q8_0.gguf"
GIGAAM_SHA256="78d63b47723b7f8d78c6113a6ef983b5a86e2a86f6c273e1f5cb6967b1c4467a"

LLAMA_TAG="b12441"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/llama-${LLAMA_TAG}-bin-macos-arm64.tar.gz"
LLAMA_SHA256="60cd8f23385a2f0548c4aed783472174f67c8ff2a1ba171b72a17223f9706d76"
# llama-server и его библиотеки по именам, под которыми они ссылаются друг на друга
LLAMA_FILES=(
  llama-server
  libllama-server-impl.dylib
  libllama-common.1.dylib
  libllama.1.dylib
  libmtmd.1.dylib
  libggml.1.dylib
  libggml-base.1.dylib
  libggml-cpu.1.dylib
  libggml-metal.1.dylib
  libggml-blas.1.dylib
  libggml-rpc.1.dylib
)

# Бинарники, которые пока поставляются вручную: проверяем, что на месте именно известная сборка
MANUAL_FILES=(
  "whisper-cli:aff85e776f3e0f2cd7fe266daa5b58ec86b61ec751bf88944a043d64b81935e8"
  "llama-cli:af14ac6ecc9bc19db2a07662a392b4218a96679d97da4c255e5eba451103c06b"
  "ffmpeg:ec83fcf58e073f0e421d102ea8ffbfcfe94f29d880dca40a3f7e184062f79d87"
)

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

# download URL DEST SHA256 — скачивает во временный файл и кладёт на место только при совпадении суммы
download() {
  local url="$1" dest="$2" expected="$3"
  if [[ -f "$dest" && "$(sha256 "$dest")" == "$expected" ]]; then
    log "$(basename "$dest") уже на месте"
    return
  fi
  log "Скачиваю $(basename "$dest")"
  mkdir -p "$(dirname "$dest")"
  local tmp="$dest.partial"
  curl --fail --location --retry 3 --progress-bar -o "$tmp" "$url"
  local actual; actual="$(sha256 "$tmp")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$tmp"
    die "контрольная сумма $(basename "$dest") не совпала: ожидалась $expected, получена $actual"
  fi
  mv "$tmp" "$dest"
}

fetch_llama_server() {
  local archive="$CACHE_DIR/llama-${LLAMA_TAG}.tar.gz"
  download "$LLAMA_URL" "$archive" "$LLAMA_SHA256"
  local unpack="$CACHE_DIR/llama-${LLAMA_TAG}"
  rm -rf "$unpack" && mkdir -p "$unpack"
  tar -xzf "$archive" -C "$unpack"
  local src; src="$(find "$unpack" -maxdepth 2 -name llama-server -type f -exec dirname {} \; | head -1)"
  [[ -n "$src" ]] || die "llama-server не найден в архиве"

  find "$LLAMA_DIR" -mindepth 1 ! -name .gitkeep -delete 2>/dev/null || true
  mkdir -p "$LLAMA_DIR"
  for name in "${LLAMA_FILES[@]}"; do
    [[ -e "$src/$name" ]] || die "в архиве нет $name"
    # Разыменовываем символьные ссылки: в бандле лежат настоящие файлы под именами из install name
    cp -L "$src/$name" "$LLAMA_DIR/$name"
  done
  chmod +x "$LLAMA_DIR/llama-server"
  log "llama-server ${LLAMA_TAG}: $(du -sh "$LLAMA_DIR" | awk '{print $1}') в Vendor/llama"
}

check_manual_files() {
  local missing=0
  for entry in "${MANUAL_FILES[@]}"; do
    local name="${entry%%:*}" expected="${entry#*:}" path="$APP_DIR/${entry%%:*}"
    if [[ ! -f "$path" ]]; then
      warn "нет Golosok/$name — соответствующая функция работать не будет"
      missing=1
    elif [[ "$(sha256 "$path")" != "$expected" ]]; then
      warn "Golosok/$name отличается от проверенной сборки, сумма $(sha256 "$path")"
    else
      log "$name проверен"
    fi
  done
  if (( missing )); then
    warn "whisper-cli и llama-cli — резервные пути, ffmpeg нужен для WebM и MKV; приложение соберётся и без них"
  fi
}

mkdir -p "$CACHE_DIR"

download "$GIGAAM_URL" "$APP_DIR/gigaam.gguf" "$GIGAAM_SHA256"
fetch_llama_server
check_manual_files
log "Готово"
