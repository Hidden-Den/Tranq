#!/bin/bash
# Замер очистки по кускам на настоящих диктовках.
# Использование: scripts/eval-external.sh <расшифровки.json> <отчёт.json> [промпт.txt]
#                scripts/eval-external.sh --local <модель.gguf> [срок, с] <расшифровки.json> <отчёт.json> [промпт.txt]
#                scripts/eval-external.sh --replay <прежний отчёт.json> <отчёт.json>
#
# --local гонит локальную модель через свой llama-server вместо провайдера. Срок на кусок
# по умолчанию боевой, 6 с; с большим сроком видно настоящее время каждого куска.
# TRANQ_PIECE_EVAL_MAX_TOKENS в окружении занижает лимит ответа: так проверяется обрыв.
# TRANQ_PIECE_EVAL_TONE=business или casual в окружении меряет уровень с тоном правила.
#
# --replay не зовёт модель: прежние ответы заново проходят валидатор. Так правка
# валидатора сравнивается на тех же самых текстах.
#
# <расшифровки.json> — JSON-массив сырых расшифровок, например поле spoken из истории.
# Провайдер берётся из настроек приложения: адрес, модель и ключ OpenRouter.
# Ключ уходит тесту через окружение и нигде не печатается. Диктовки и отчёт
# в репозиторий не кладите: это личные тексты.
set -euo pipefail
local_model=""; local_timeout=""
if [ "${1:-}" = "--local" ]; then
  [ $# -ge 4 ] || { echo "Использование: $0 --local <модель.gguf> [срок, с] <расшифровки.json> <отчёт.json> [промпт.txt]" >&2; exit 2; }
  local_model="$(cd "$(dirname "$2")" && echo "$(pwd)/$(basename "$2")")"; shift 2
  if [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then local_timeout="$1"; shift; fi
fi
replay=""
if [ "${1:-}" = "--replay" ]; then
  [ $# -eq 3 ] || { echo "Использование: $0 --replay <прежний отчёт.json> <отчёт.json>" >&2; exit 2; }
  replay="$2"; shift 2
  set -- "$replay" "$1"
fi
[ $# -ge 2 ] && [ $# -le 3 ] || { echo "Использование: $0 <расшифровки.json> <отчёт.json> [промпт.txt]" >&2; exit 2; }

root="$(cd "$(dirname "$0")/.." && pwd)"
abs() { (cd "$(dirname "$1")" && echo "$(pwd)/$(basename "$1")"); }
cases="$(abs "$1")"; out="$(abs "$2")"
prompt=""; [ $# -eq 3 ] && prompt="$(abs "$3")"
[ -n "$replay" ] && replay="$(abs "$replay")"

base=""; model=""; key=""
# Повтор не зовёт модель: настройки провайдера ему не нужны
if [ -z "$local_model" ] && [ -z "$replay" ]; then
  base="$(defaults read nuter.Tranq ai.baseURL)"
  model="$(defaults read nuter.Tranq ai.model)"
  key="$(defaults read nuter.Tranq keystore.ai.apiKey)"
fi
log="$(mktemp -t tranq-piece-eval)"

cd "$root"
env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  TEST_RUNNER_TRANQ_PIECE_EVAL_CASES="$cases" \
  TEST_RUNNER_TRANQ_PIECE_EVAL_OUT="$out" \
  TEST_RUNNER_TRANQ_PIECE_EVAL_BASE="$base" \
  TEST_RUNNER_TRANQ_PIECE_EVAL_MODEL="$model" \
  TEST_RUNNER_TRANQ_PIECE_EVAL_KEY="$key" \
  ${prompt:+TEST_RUNNER_TRANQ_PIECE_EVAL_PROMPT="$prompt"} \
  ${replay:+TEST_RUNNER_TRANQ_PIECE_EVAL_REPLAY="$replay"} \
  ${local_model:+TEST_RUNNER_TRANQ_PIECE_EVAL_LOCAL_MODEL="$local_model"} \
  ${local_timeout:+TEST_RUNNER_TRANQ_PIECE_EVAL_TIMEOUT="$local_timeout"} \
  ${TRANQ_PIECE_EVAL_MAX_TOKENS:+TEST_RUNNER_TRANQ_PIECE_EVAL_MAX_TOKENS="$TRANQ_PIECE_EVAL_MAX_TOKENS"} \
  ${TRANQ_PIECE_EVAL_TONE:+TEST_RUNNER_TRANQ_PIECE_EVAL_TONE="$TRANQ_PIECE_EVAL_TONE"} \
  xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' \
    -only-testing:TranqTests/PieceEvalTests -derivedDataPath build/DerivedData-ci \
    CODE_SIGN_IDENTITY=- > "$log" 2>&1 || {
  grep -E "error:|\*\* TEST" "$log" | tail -5 >&2 || true
  echo "Прогон не удался, лог: $log" >&2
  exit 1
}
rm -f "$log"
echo "Отчёт: $out"
