#!/bin/bash
# Прогон замера очистки на одной локальной модели.
# Использование: scripts/eval-run-local.sh <модель.gguf>
# Набор и отчёты лежат в $GOLOSOK_EVAL_DIR, по умолчанию ~/golosok-eval.
set -euo pipefail
[ $# -eq 1 ] || { echo "Использование: $0 <модель.gguf>" >&2; exit 2; }

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="${GOLOSOK_EVAL_DIR:-$HOME/golosok-eval}"
model="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
name="$(basename "$model" .gguf)"
mkdir -p "$dir/logs"
log="$dir/logs/eval-$name.log"

cd "$root"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
TEST_RUNNER_GOLOSOK_EVAL_DIR="$dir" \
TEST_RUNNER_GOLOSOK_EVAL_LOCAL_MODEL="$model" \
xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' \
  -only-testing:GolosokTests/CleanupEvalTests CODE_SIGN_IDENTITY=- > "$log" 2>&1 || {
  grep -E "error:|liveEval|\*\* TEST" "$log" | tail -5 >&2
  echo "Прогон не удался, лог: $log" >&2
  exit 1
}

ls -t "$dir"/report-"$name"-*.md | head -1
