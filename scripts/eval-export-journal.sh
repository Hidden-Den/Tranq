#!/bin/bash
# Выгружает последние диктовки из журнала в набор замеров.
# Использование: scripts/eval-export-journal.sh <сколько> <каталог> [эталоны.jsonl]
#
# Журнал пишет две строки на диктовку: после распознавания и после очистки.
# Скрипт берёт по одной, последней, строке на диктовку в порядке записи.
#
# С файлом эталонов, например docs/eval/expected.jsonl, <сколько> — число фраз. Диктовки
# сопоставляются с фразами по тексту, повторные попытки и обрывки пропускаются.
# Рядом с cases.jsonl пишется review.md: фраза, что распознано, что вставлено и что ожидалось.
#
# Журнал по умолчанию: ~/Library/Application Support/Tranq/transcript_journal.jsonl,
# другой путь можно задать через TRANQ_JOURNAL.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
    echo "Использование: $0 <сколько> <каталог> [эталоны.jsonl]" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "Нужен jq: brew install jq" >&2
    exit 1
fi

count="$1"
outdir="$2"
expected="${3:-}"
journal="${TRANQ_JOURNAL:-$HOME/Library/Application Support/Tranq/transcript_journal.jsonl}"
target="$outdir/cases.jsonl"

if [ ! -f "$journal" ]; then
    echo "Журнал не найден: $journal" >&2
    exit 1
fi
if [ -n "$expected" ] && [ ! -f "$expected" ]; then
    echo "Файл эталонов не найден: $expected" >&2
    exit 1
fi
mkdir -p "$outdir"
if [ -e "$target" ]; then
    echo "Уже есть $target. Заполненные эталоны не перезаписываем." >&2
    exit 1
fi

# Одна запись на диктовку, последняя по времени, в порядке первого появления
dictations="$(jq -s --argjson n "$count" '
    reduce .[] as $r ({order: [], byId: {}};
        (if .byId[$r.id] == null then .order += [$r.id] else . end) | .byId[$r.id] = $r)
    | [.order[] as $id | .byId[$id]]
    | map(select(.rawText != null and .rawText != ""))
    | .[-$n:]
' "$journal")"

found="$(jq 'length' <<<"$dictations")"
if [ "$found" -lt "$count" ]; then
    echo "В журнале только $found диктовок, запрошено $count" >&2
    exit 1
fi

if [ -z "$expected" ]; then
    jq -c '.[] | {id: .id, category: "", raw: .rawText, expected: ""}' <<<"$dictations" > "$target"
    echo "Записано строк: $(wc -l < "$target" | tr -d ' ') в $target"
    exit 0
fi

# Сопоставление по тексту: повторные попытки, обрывки и посторонние диктовки
# пропускаются, поэтому берём окно вдвое больше числа фраз.
window="$(jq -s --argjson n "$((count * 2))" '
    reduce .[] as $r ({order: [], byId: {}};
        (if .byId[$r.id] == null then .order += [$r.id] else . end) | .byId[$r.id] = $r)
    | [.order[] as $id | .byId[$id]]
    | map(select(.rawText != null and .rawText != ""))
    | .[-$n:]
' "$journal")"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '%s' "$window" > "$tmp"
python3 -I "$(dirname "$0")/eval-align.py" "$tmp" "$expected" "$outdir"
echo "Разбор: $outdir/review.md"
