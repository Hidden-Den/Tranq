#!/bin/bash
# Выгружает последние диктовки из журнала в заготовку набора замеров.
# Использование: scripts/eval-export-journal.sh <сколько> <каталог>
# Журнал по умолчанию: ~/Library/Application Support/Golosok/transcript_journal.jsonl,
# другой путь можно задать через GOLOSOK_JOURNAL.
set -euo pipefail

if [ "$#" -ne 2 ] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
    echo "Использование: $0 <сколько> <каталог>" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "Нужен jq: brew install jq" >&2
    exit 1
fi

count="$1"
outdir="$2"
journal="${GOLOSOK_JOURNAL:-$HOME/Library/Application Support/Golosok/transcript_journal.jsonl}"
target="$outdir/cases.jsonl"

if [ ! -f "$journal" ]; then
    echo "Журнал не найден: $journal" >&2
    exit 1
fi
mkdir -p "$outdir"
if [ -e "$target" ]; then
    echo "Уже есть $target. Заполненные эталоны не перезаписываем." >&2
    exit 1
fi

tail -n "$count" "$journal" \
    | jq -c 'select(.rawText != null and .rawText != "") | {id: .id, category: "", raw: .rawText, expected: ""}' \
    > "$target"
echo "Записано строк: $(wc -l < "$target" | tr -d ' ') в $target"
