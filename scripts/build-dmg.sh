#!/usr/bin/env bash
# Собирает Release-версию и упаковывает её в build/Tranq.dmg.
#
#   scripts/fetch-deps.sh   # один раз: модель и llama-server
#   scripts/build-dmg.sh
#   TRANQ_DMG=/tmp/test.dmg scripts/build-dmg.sh   # другой путь вывода
#
# Подпись ad-hoc с hardened runtime: платного аккаунта Apple Developer нет,
# поэтому нотаризации нет и пользователям по-прежнему нужен `xattr -cr`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
DERIVED="$BUILD_DIR/DerivedData-release"
DMG="${TRANQ_DMG:-$BUILD_DIR/Tranq.dmg}"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# xcodebuild не работает, если xcode-select указывает на Command Line Tools
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p)" == *CommandLineTools* ]] && [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

[[ -f "$ROOT/Tranq/gigaam.gguf" ]] || die "нет Tranq/gigaam.gguf — запустите scripts/fetch-deps.sh"
[[ -x "$ROOT/Vendor/llama/llama-server" ]] || die "нет Vendor/llama/llama-server — запустите scripts/fetch-deps.sh"

log "Сборка Release"
xcodebuild build \
  -project "$ROOT/Tranq.xcodeproj" \
  -scheme Tranq \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 \
  CODE_SIGN_IDENTITY=- \
  > "$BUILD_DIR/build-release.log" 2>&1 || { grep -E "error:" "$BUILD_DIR/build-release.log" | head -20; die "сборка не удалась, лог: build/build-release.log"; }

APP="$DERIVED/Build/Products/Release/Tranq.app"
[[ -d "$APP" ]] || die "сборка не удалась, Tranq.app не найден"

log "Проверка подписи"
codesign --verify --strict "$APP" || die "подпись приложения не прошла проверку"
SIGN_INFO="$(codesign -dv "$APP" 2>&1)"
[[ "$SIGN_INFO" == *"runtime"* ]] || die "hardened runtime не включён"
for res in gigaam.gguf llama/llama-server; do
  [[ -e "$APP/Contents/Resources/$res" ]] || die "в бандле нет $res"
done

VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
log "Упаковка Tranq $VERSION"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Tranq" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

log "Готово: $DMG ($(du -h "$DMG" | awk '{print $1}'))"
