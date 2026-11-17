#!/usr/bin/env python3
"""Сравнивает отчёты замера очистки до и после изменения.

Использование: eval-compare.py <каталог до> <каталог после>

В каждом каталоге лежат report-<модель>-<дата>.md. Модели сопоставляются по имени.
Печатает сводку по моделям, разбор фраз категории «термины» и оставшиеся отказы.
"""
import difflib
import glob
import os
import re
import statistics as st
import sys
from collections import Counter

LATIN = re.compile(r"[A-Za-z][A-Za-z0-9&+.#-]*[A-Za-z0-9+#]|[A-Za-z]")


def norm(t):
    return re.sub(r"[^\wё ]+", " ", t.lower().replace("ё", "е")).split()


def stems(t):
    return {w[:5] for w in re.findall(r"[a-zа-яё0-9]+", t.lower().replace("ё", "е")) if len(w) > 2}


def latin(t):
    return [w.lower() for w in LATIN.findall(t)]


def load(path):
    rows = {}
    for line in open(path, encoding="utf-8"):
        if not line.startswith("| p"):
            continue
        c = [x.strip().replace("\\|", "|") for x in re.split(r"(?<!\\)\|", line)[1:-1]]
        id_, cat, raw, exp, res, fb, sec = c[:7]
        rows[id_] = dict(
            cat=cat, raw=raw, exp=exp, res=res, fb=fb, sec=float(sec),
            sim=difflib.SequenceMatcher(None, norm(res), norm(exp)).ratio(),
            lost=len((stems(exp) & stems(raw)) - stems(res)) >= 2,
        )
    return rows


def summary(rows):
    if not rows:
        return dict(sim=0.0, other=0.0, terms=0.0, extra=0, acc=0, lost=0, med=0.0, p95=0.0)
    secs = sorted(r["sec"] for r in rows.values())
    expected_terms = found_terms = extra_terms = 0
    for r in rows.values():
        exp, res, raw = latin(r["exp"]), set(latin(r["res"])), set(latin(r["raw"]))
        expected_terms += len(exp)
        found_terms += sum(1 for w in exp if w in res)
        extra_terms += sum(1 for w in res if w not in exp and w not in raw)
    other = [r["sim"] for r in rows.values() if r["cat"] != "термины"]
    return dict(
        sim=st.mean(r["sim"] for r in rows.values()),
        other=st.mean(other) if other else 0.0,
        terms=found_terms / expected_terms if expected_terms else 0.0,
        extra=extra_terms,
        acc=sum(r["fb"] == "нет" for r in rows.values()),
        lost=sum(r["lost"] for r in rows.values()),
        med=st.median(secs),
        p95=secs[max(0, -(-95 * len(secs) // 100) - 1)],
    )


def comma(x, digits):
    return f"{x:.{digits}f}".replace(".", ",")


def model_name(path):
    return re.sub(r"report-(.*)-\d{8}-\d{4}\.md", r"\1", os.path.basename(path))


def latest(directory):
    reports = {}
    for path in sorted(glob.glob(os.path.join(directory, "report-*.md"))):
        reports[model_name(path)] = load(path)
    return reports


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    before, after = latest(sys.argv[1]), latest(sys.argv[2])
    models = [m for m in before if m in after]
    if not models:
        sys.exit("Нет общих моделей в двух каталогах")

    print("| Модель | Похожесть | Вне терминов | Термины на месте | Лишние термины | Принято | Потери смысла | Медиана | p95 |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for m in sorted(models, key=lambda m: -summary(after[m])["sim"]):
        b, a = summary(before[m]), summary(after[m])
        print(
            f"| {m} | {comma(b['sim'], 3)} → {comma(a['sim'], 3)} | {comma(b['other'], 3)} → {comma(a['other'], 3)} "
            f"| {comma(b['terms'], 2)} → {comma(a['terms'], 2)} | {b['extra']} → {a['extra']} | {b['acc']} → {a['acc']} "
            f"| {b['lost']} → {a['lost']} | {comma(b['med'], 2)} → {comma(a['med'], 2)} с | {comma(b['p95'], 2)} → {comma(a['p95'], 2)} с |"
        )

    for m in models:
        print(f"\n### {m}: термины\n")
        print("| id | Распознано | До | После |")
        print("| --- | --- | --- | --- |")
        for id_, r in sorted(after[m].items()):
            if r["cat"] == "термины" and id_ in before[m]:
                print(f"| {id_} | {r['raw']} | {before[m][id_]['res']} | {r['res']} |")

    reasons = Counter()
    for m in models:
        for r in after[m].values():
            if r["fb"] not in ("нет", "shortPhrase"):
                reasons[re.sub(r"\d+", "N", re.sub(r"термин [^\")]+", "термин X", r["fb"]))] += 1
    if reasons:
        print("\nОставшиеся отказы:")
        for k, v in reasons.most_common():
            print(f"  {v} {k}")


if __name__ == "__main__":
    main()
