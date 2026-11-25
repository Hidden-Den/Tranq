#!/usr/bin/env python3
"""Где модели распознавания расходятся на терминах: для записей без эталона.

Использование: eval-asr-diff.py <набор> <каталог прогона>... > diff.md

Набор как у eval-asr.py; в третьей колонке test.tsv итоговый текст Tranq. Для каждой
записи, где в итоговом тексте или у какой-нибудь модели есть латиница, печатает
итог Tranq и ответы всех моделей, если модели записали латинские слова по-разному.
Отчёт содержит личные диктовки: в репозиторий его не кладите.
"""
import json
import re
import sys
from pathlib import Path

LATIN = re.compile(r"[A-Za-z][A-Za-z0-9.+'-]*")


def latin(text):
    return {w.lower().strip(".'-") for w in LATIN.findall(text or "")}


def main():
    dataset = Path(sys.argv[1])
    runs = [Path(p) for p in sys.argv[2:]]
    final = {}
    for line in (dataset / "test.tsv").read_text(encoding="utf-8").splitlines():
        cols = line.split("\t")
        final[str(dataset / "audio" / "test" / cols[1])] = cols[2]
    hyps = {}
    for run in runs:
        for line in (run / "cases.jsonl").read_text(encoding="utf-8").splitlines():
            c = json.loads(line)
            hyps.setdefault(c["file"], {})[run.name.removeprefix("run-")] = c["hyp"]

    shown = 0
    for file, text in final.items():
        by_model = hyps.get(file, {})
        sets = {m: latin(h) for m, h in by_model.items()}
        if not latin(text) and not any(sets.values()):
            continue
        if len({frozenset(s) for s in sets.values()}) <= 1:
            continue
        shown += 1
        print(f"### {Path(file).stem[:8]}")
        print(f"- **Tranq, итог:** {text}")
        for m, h in by_model.items():
            print(f"- {m}: {h}")
        print()
    print(f"Записей с расхождениями: {shown} из {len(final)}", file=sys.stderr)


if __name__ == "__main__":
    main()
