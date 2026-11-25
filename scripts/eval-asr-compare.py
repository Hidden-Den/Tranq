#!/usr/bin/env python3
"""Сводная таблица прогонов eval-asr.py.

Использование: eval-asr-compare.py <каталог прогона>...

Из cases.jsonl каждого прогона берёт WER по всему набору и по фразам без чисел
и латиницы, долю терминов, записанных как в эталоне, и время на минуту речи,
если прогон его записал в timing.json.
"""
import json
import re
import sys
from pathlib import Path


def squash(text):
    return "".join(re.findall(r"[a-zа-я0-9]+", (text or "").lower().replace("ё", "е")))


def main():
    print("| Прогон | WER, % | WER чистых фраз, % | Термины, % | Секунд на минуту речи |")
    print("|---|---|---|---|---|")
    for run in map(Path, sys.argv[1:]):
        cases = [json.loads(l) for l in (run / "cases.jsonl").read_text(encoding="utf-8").splitlines()]
        ref = sum(c["ref_words"] for c in cases)
        clean = [c for c in cases if not c["numbers"] and not c["latin"]]
        clean_ref = sum(c["ref_words"] for c in clean)
        terms = [(t, c["hyp"]) for c in cases for t in c.get("terms", [])]
        hit = sum(squash(t) in squash(h) for t, h in terms)
        timing = run / "timing.json"
        speed = "—"
        if timing.exists():
            seconds = json.loads(timing.read_text())["seconds"]
            audio = sum(c["seconds"] for c in cases)
            speed = f"{60 * seconds / audio:.1f}"
        print(f"| {run.parent.name}/{run.name} | {100 * sum(c['errors'] for c in cases) / ref:.1f} | "
              f"{100 * sum(c['errors'] for c in clean) / clean_ref if clean_ref else 0:.1f} | "
              f"{f'{100 * hit / len(terms):.0f}' if terms else '—'} | {speed} |")


if __name__ == "__main__":
    main()
