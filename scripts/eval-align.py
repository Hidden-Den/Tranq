#!/usr/bin/env python3
"""Сопоставляет диктовки из журнала с фразами замера по тексту, а не по порядку.

Использование: eval-align.py <диктовки.json> <эталоны.jsonl> <каталог>

Диктовки — JSON-массив записей журнала в порядке записи. Повторные попытки, обрывки
и посторонние диктовки между фразами пропускаются: выравнивание ищет лучшую
последовательность совпадений, сохраняя порядок фраз.
Пишет в каталог cases.jsonl и review.md.
"""
import json
import re
import sys

THRESHOLD = 0.35


def stems(text):
    words = re.findall(r"[a-zа-яё0-9]+", text.lower().replace("ё", "е"))
    return {w[:5] for w in words if len(w) > 2}


def similarity(a, b):
    sa, sb = stems(a), stems(b)
    if not sa or not sb:
        return 0.0
    return 2 * len(sa & sb) / (len(sa) + len(sb))


def align(phrases, dictations):
    n, m = len(phrases), len(dictations)
    sim = [[similarity(p["say"], d.get("rawText") or "") for d in dictations] for p in phrases]
    best = [[0.0] * (m + 1) for _ in range(n + 1)]
    move = [[None] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        for j in range(m + 1):
            if i == 0 and j == 0:
                continue
            options = []
            if i > 0:
                options.append((best[i - 1][j], "skip_phrase"))
            if j > 0:
                options.append((best[i][j - 1], "skip_dictation"))
            if i > 0 and j > 0 and sim[i - 1][j - 1] >= THRESHOLD:
                options.append((best[i - 1][j - 1] + sim[i - 1][j - 1], "match"))
            best[i][j], move[i][j] = max(options, key=lambda o: o[0])
    matched = [None] * n
    i, j = n, m
    while i > 0 or j > 0:
        step = move[i][j]
        if step == "match":
            matched[i - 1] = dictations[j - 1]
            i, j = i - 1, j - 1
        elif step == "skip_phrase":
            i -= 1
        else:
            j -= 1
    return matched


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as f:
        dictations = json.load(f)
    with open(sys.argv[2], encoding="utf-8") as f:
        phrases = [json.loads(line) for line in f if line.strip()]
    outdir = sys.argv[3]

    matched = align(phrases, dictations)

    with open(f"{outdir}/cases.jsonl", "w", encoding="utf-8") as f:
        for p, d in zip(phrases, matched):
            if d is not None:
                case = {"id": p["id"], "category": p["category"], "raw": d["rawText"], "expected": p["expected"]}
                f.write(json.dumps(case, ensure_ascii=False) + "\n")

    lines = ["# Разбор диктовок", ""]
    for p, d in zip(phrases, matched):
        mark = "" if d is None or not d.get("isFallback") else " · откат"
        lines += [f"## {p['id']} · {p['category']}{mark}", "", f"- Фраза: {p['say']}"]
        if d is None:
            lines.append("- Диктовка не найдена")
        else:
            lines += [f"- Распознано: {d['rawText']}", f"- Вставлено: {d.get('finalPastedText') or 'нет'}"]
        lines += [f"- Ожидалось: {p['expected']}", ""]
    with open(f"{outdir}/review.md", "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    missing = [p["id"] for p, d in zip(phrases, matched) if d is None]
    print(f"Сопоставлено {len(phrases) - len(missing)} из {len(phrases)} фраз")
    if missing:
        print("Без диктовки: " + ", ".join(missing))


if __name__ == "__main__":
    main()
