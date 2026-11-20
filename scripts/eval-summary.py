#!/usr/bin/env python3
"""Сводка отчёта scripts/eval-external.sh.

Использование:
  python3 -I scripts/eval-summary.py <отчёт.json>                 итоги, причины, время, обрывы
  python3 -I scripts/eval-summary.py <отчёт.json> --reason <вид>  примеры отказов этого вида
  python3 -I scripts/eval-summary.py <отчёт.json> --tone-review   для уровня с тоном: что прошло
                                                                  валидатор, но похоже на отказ
                                                                  или на подмену смысла

Виды причин: пересказ, потеряно число, придумано число, потерян термин, новый термин,
слишком длинно, ответ вместо очистки, мета-зачин.

Отчёт содержит текст личных диктовок: в репозиторий его не кладите и удаляйте после разбора.
"""
import json
import re
import sys
from collections import Counter

KINDS = [
    (r'переписала речь', 'пересказ'), (r'Пропущено исходное число', 'потеряно число'),
    (r'Модель придумала число', 'придумано число'), (r'Пропущен исходный термин', 'потерян термин'),
    (r'Новый термин', 'новый термин'), (r'превысил', 'слишком длинно'),
    (r'ответила на вопрос|ответить на вопрос', 'ответ вместо очистки'), (r'мета-префикс', 'мета-зачин'),
    (r'обрезан', 'обрезан'),
]

# Признаки ответа модели вместо текста говорящего: просьба, отказ, разговор о самой задаче
REFUSAL = re.compile(r'(?i)прошу|не могу|не буду|переформулир|корректн\w* форм|оскорб|недопустим|'
                     r'извините|к сожалению|пришлите|расшифровк|не содержит|моя роль')
STOP = set("это этот эта эти который которая которые чтобы когда если потом тоже только очень можно "
           "нужно надо будет было были есть себя свой своя свои такой такая такие также просто вообще "
           "тогда здесь сейчас именно ещё еще даже уже либо или как что так там тут вот".split())
ENDINGS = set('аеиоуыэюяьй')


def kind(reason):
    for pattern, name in KINDS:
        if reason and re.search(pattern, reason):
            return name
    return (reason or '')[:40]


def content_words(text):
    text = text.lower().replace('ё', 'е')
    return {w for w in re.findall(r'[a-zа-я]+', text) if len(w) >= 4 and w not in STOP}


def same_lexeme(a, b):
    """Та же лексема в другой форме, как GroundingValidator.sameLexeme."""
    if a == b:
        return True
    n = min(len(a), len(b))
    if n < 3:
        return False
    p = 0
    while p < n and a[p] == b[p]:
        p += 1
    if n >= 5:
        return p >= max(4, n - 3)
    return p >= n - 1 and set(a[p:]) <= ENDINGS and set(b[p:]) <= ENDINGS


def summary(rows):
    verdicts = Counter(r['verdict'] for r in rows)
    print(f"кусков {len(rows)}: прошло {verdicts['valid']}, отклонено {verdicts['rejected']}, "
          f"без ответа {verdicts['failed']}  ->  {100 * verdicts['valid'] // max(1, len(rows))}% проходит")
    print("причины отказов:", Counter(kind(r.get('reason')) for r in rows if r['verdict'] != 'valid').most_common())
    for verdict in ('valid', 'rejected'):
        ratios = sorted(len(r.get('output') or '') / max(1, len(r['input'])) for r in rows if r['verdict'] == verdict)
        if ratios:
            print(f"  сжатие {verdict}: медиана {ratios[len(ratios) // 2]:.2f}")
    seconds = sorted(r['seconds'] for r in rows if r.get('seconds') is not None)
    if seconds:
        print(f"время на кусок: медиана {seconds[len(seconds) // 2]:.1f} с, 90% {seconds[int(len(seconds) * 0.9)]:.1f} с, "
              f"макс {seconds[-1]:.1f} с")


def examples(rows, wanted):
    for r in rows:
        if r['verdict'] != 'valid' and kind(r.get('reason')) == wanted:
            print('---', r.get('reason'))
            print('S:', r['input'][:240])
            print('T:', (r.get('output') or '')[:240])


def tone_review(rows):
    print('=== прошли валидатор, но похожи на отказ ===')
    for r in rows:
        out = r.get('output') or ''
        if r['verdict'] == 'valid' and REFUSAL.search(out) and not REFUSAL.search(r['input']):
            print('  S:', r['input'][:160])
            print('  T:', out[:200])
    print('=== прошли валидатор, меньше всего общих слов с речью ===')
    scored = []
    for r in rows:
        spoken = content_words(r['input'])
        if r['verdict'] != 'valid' or len(spoken) < 3:
            continue
        written = content_words(r.get('output') or '')
        shared = sum(1 for w in spoken if any(same_lexeme(w, x) for x in written))
        scored.append((shared / len(spoken), shared, len(spoken), r))
    for share, shared, total, r in sorted(scored, key=lambda x: x[0])[:8]:
        print(f'  общих {shared}/{total} ({share:.0%})')
        print('  S:', r['input'][:160])
        print('  T:', (r.get('output') or '')[:200])


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    rows = json.load(open(sys.argv[1], encoding='utf-8'))
    if len(sys.argv) >= 4 and sys.argv[2] == '--reason':
        examples(rows, sys.argv[3])
    elif len(sys.argv) >= 3 and sys.argv[2] == '--tone-review':
        tone_review(rows)
    else:
        summary(rows)


if __name__ == '__main__':
    main()
