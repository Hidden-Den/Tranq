#!/usr/bin/env python3
"""Сколько латинских терминов очистка восстановила после распознавания.

Использование: eval-terms-cleanup.py <meta.json> <отчёт.json>

meta.json — список {raw, hyp, terms} в порядке входов eval-external.sh: эталон,
распознанный текст и термины. Отчёт — вывод scripts/eval-external.sh.
Итог фразы как в приложении: ответ модели, если валидатор его принял, иначе
распознанный текст. Отдельно считается, что предлагала модель до валидатора:
так видно, сколько верных терминов он отклонил.
"""
import json
import re
import sys
from collections import Counter, defaultdict


def squash(text):
    return "".join(re.findall(r"[a-zа-я0-9]+", (text or "").lower().replace("ё", "е")))


def found(term, text):
    return squash(term) in squash(text)


def main():
    meta = json.load(open(sys.argv[1], encoding="utf-8"))
    rows = json.load(open(sys.argv[2], encoding="utf-8"))
    pieces = defaultdict(list)
    for r in rows:
        pieces[r["caseIndex"]].append(r)

    counts = Counter()
    reasons = Counter()
    blocked, missed, fixed = [], [], []
    for i, m in enumerate(meta):
        parts = sorted(pieces.get(i, []), key=lambda r: r["pieceIndex"])
        valid = all(p["verdict"] == "valid" for p in parts) and parts
        proposed = " ".join(p.get("output") or "" for p in parts)
        final = proposed if valid else m["hyp"]
        for p in parts:
            if p["verdict"] != "valid":
                reasons[re.sub(r" \S+$", "", p.get("reason") or p["verdict"])[:60]] += 1
        for t in m["terms"]:
            before, after, model = found(t, m["hyp"]), found(t, final), found(t, proposed)
            counts["terms"] += 1
            counts["before"] += before
            counts["after"] += after
            counts["model"] += model
            if model and not after:
                blocked.append((t, m, proposed, [p.get("reason") for p in parts if p["verdict"] != "valid"]))
            elif not after:
                missed.append((t, m, final))
            elif not before:
                fixed.append((t, m, final))

    n = counts["terms"]
    print(f"Терминов: {n}")
    print(f"После распознавания: {counts['before']} ({100 * counts['before'] / n:.0f}%)")
    print(f"Модель предложила верно: {counts['model']} ({100 * counts['model'] / n:.0f}%)")
    print(f"В итоговом тексте: {counts['after']} ({100 * counts['after'] / n:.0f}%)")
    print(f"Отклонено валидатором при верном термине: {len(blocked)}")
    print("\nПричины отказов:")
    for r, k in reasons.most_common():
        print(f"  {k:3d}  {r}")
    print("\nОчистка исправила:")
    for t, m, final in fixed:
        print(f"  {t}: {m['hyp']} → {final}")
    print("\nВалидатор отклонил верный термин:")
    for t, m, proposed, why in blocked:
        print(f"  {t}: {proposed}  ⟵ {'; '.join(w or '' for w in why)}")
    print("\nНе восстановлено:")
    for t, m, final in missed:
        print(f"  {t}: {final}")


if __name__ == "__main__":
    main()
