#!/usr/bin/env python3
"""Замер распознавания речи на наборе чужих голосов.

Использование: eval-asr.py <набор> [--model gigaam.gguf] [--cli transcribe-cli] [--out каталог]

Набор устроен как FLEURS: test.tsv и каталог audio/test с wav. В test.tsv семь
колонок без заголовка: id, файл, исходный текст, нормализованный текст, буквы,
число отсчётов при 16 кГц, пол диктора.

Считает долю ошибочных слов, WER, по всему набору и по срезам: пол, темп речи,
фразы с числами, фразы с латиницей. Пишет hyp.jsonl с распознанным текстом,
cases.jsonl с ошибками каждой фразы и report.md. Готовый hyp.jsonl не пересчитывает,
поэтому повторный запуск после правки отчёта быстрый.
"""
import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def words(text):
    text = text.lower().replace("ё", "е")
    return re.findall(r"[a-zа-я0-9]+", text)


def edits(ref, hyp):
    """Число правок слов, которые превращают ref в hyp."""
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


def load_cases(dataset):
    cases = []
    for line in (dataset / "test.tsv").read_text(encoding="utf-8").splitlines():
        cols = line.split("\t")
        if len(cols) < 7:
            continue
        cases.append({
            "file": str(dataset / "audio" / "test" / cols[1]),
            "raw": cols[2],
            "ref": cols[3],
            "seconds": int(cols[5]) / 16000,
            "speaker": cols[6].lower(),
            "terms": [t for t in cols[7].split("|") if t] if len(cols) > 7 else [],
        })
    return cases


def read_hyps(lines):
    rows = (json.loads(l) for l in lines if l.startswith("{"))
    # Первая строка пакета служебная, без файла
    return {r["file"]: r["text"] for r in rows if "file" in r}


def recognize_whisper(cases, model, cli, prompt):
    """whisper-cli как в приложении: русский язык, без меток времени, подсказка словаря."""
    files = [c["file"] for c in cases]
    hyps = {}
    # Модель грузится один раз на пачку файлов; текст каждого файла пишется рядом с ним
    for start in range(0, len(files), 50):
        chunk = files[start:start + 50]
        args = [str(cli), "-m", str(model), "-l", "ru", "-nt", "-np", "-otxt"]
        if prompt:
            args += ["--prompt", prompt]
        for f in chunk:
            args += ["-f", f]
        subprocess.run(args, capture_output=True, text=True, check=True)
        for f in chunk:
            txt = Path(f + ".txt")
            hyps[f] = " ".join(txt.read_text(encoding="utf-8").split()) if txt.exists() else ""
            txt.unlink(missing_ok=True)
        print(f"\r{start + len(chunk)}/{len(files)}", end="", file=sys.stderr, flush=True)
    print(file=sys.stderr)
    return hyps


def recognize(cases, out, model, cli, prompt="", lang=""):
    hyp_path = out / "hyp.jsonl"
    if hyp_path.exists():
        return read_hyps(hyp_path.read_text().splitlines())
    if model.suffix == ".bin":
        print(f"Распознаю {len(cases)} записей через whisper-cli…", file=sys.stderr)
        hyps = recognize_whisper(cases, model, cli, prompt)
        hyp_path.write_text("".join(json.dumps({"file": f, "text": t}, ensure_ascii=False) + "\n"
                                    for f, t in hyps.items()), encoding="utf-8")
        return hyps
    listing = out / "files.list"
    listing.write_text("\n".join(c["file"] for c in cases) + "\n")
    print(f"Распознаю {len(cases)} записей…", file=sys.stderr)
    result = subprocess.run(
        [str(cli), "-q", "-m", str(model), "--batch", str(listing), "--batch-jsonl"]
        + (["-l", lang] if lang else []),
        capture_output=True, text=True, check=True,
    )
    rows = [l for l in result.stdout.splitlines() if l.startswith("{")]
    hyp_path.write_text("\n".join(rows) + "\n")
    return read_hyps(rows)


def squash(text):
    return "".join(re.findall(r"[a-zа-я0-9]+", text.lower().replace("ё", "е")))


def term_found(term, hyp):
    """Термин записан в тексте как в эталоне, без учёта регистра, пробелов и знаков."""
    return squash(term) in squash(hyp)


def wer(cases):
    total = sum(c["ref_words"] for c in cases)
    return 100 * sum(c["errors"] for c in cases) / total if total else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset", type=Path)
    ap.add_argument("--model", type=Path, default=ROOT / "Tranq" / "gigaam.gguf")
    ap.add_argument("--cli", type=Path, help="по умолчанию whisper-cli для .bin, иначе transcribe-cli")
    ap.add_argument("--prompt", default="", help="подсказка Whisper, как слова словаря в приложении")
    ap.add_argument("--prompt-terms", action="store_true",
                    help="подсказать Whisper все термины набора, как очень длинный словарь")
    ap.add_argument("--lang", default="", help="подсказка языка для transcribe-cli, например ru")
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()
    if args.cli is None:
        args.cli = ROOT / "Tranq" / ("whisper-cli" if args.model.suffix == ".bin" else "transcribe-cli")

    out = args.out or args.dataset / f"run-{args.model.stem}"
    out.mkdir(parents=True, exist_ok=True)
    cases = load_cases(args.dataset)
    prompt = args.prompt
    if args.prompt_terms:
        prompt = ", ".join(dict.fromkeys(t for c in cases for t in c["terms"]))
    started = time.monotonic()
    fresh = not (out / "hyp.jsonl").exists()
    hyps = recognize(cases, out, args.model, args.cli, prompt, args.lang)
    if fresh:
        # Время всего прогона с загрузкой модели: для сравнения скорости движков
        (out / "timing.json").write_text(json.dumps({"seconds": time.monotonic() - started}))

    for c in cases:
        ref, hyp = words(c["ref"]), words(hyps.get(c["file"], ""))
        c["hyp"] = hyps.get(c["file"], "")
        c["ref_words"] = len(ref)
        c["errors"] = edits(ref, hyp)
        c["wps"] = len(ref) / c["seconds"] if c["seconds"] else 0
        c["numbers"] = bool(re.search(r"\d", c["raw"]))
        c["latin"] = bool(re.search(r"[A-Za-z]", c["raw"]))

    by_speed = sorted(cases, key=lambda c: c["wps"])
    third = len(by_speed) // 3
    slices = [
        ("Весь набор", cases),
    ] + [
        (f"Диктор {s}", [c for c in cases if c["speaker"] == s])
        for s in sorted({c["speaker"] for c in cases})
    ] + [
        ("Медленная речь", by_speed[:third]),
        ("Средний темп", by_speed[third:2 * third]),
        ("Быстрая речь", by_speed[2 * third:]),
        ("Без чисел и латиницы", [c for c in cases if not c["numbers"] and not c["latin"]]),
        ("С числами", [c for c in cases if c["numbers"]]),
        ("С латиницей", [c for c in cases if c["latin"]]),
    ]

    lines = [f"# Замер распознавания: {args.model.stem}", "", f"Набор: {args.dataset}", "",
             "| Срез | Фраз | WER, % |", "|---|---|---|"]
    for name, part in slices:
        lines.append(f"| {name} | {len(part)} | {wer(part):.1f} |")
    lines += ["", "Числа эталон пишет цифрами, а модель словами: их ошибки отчасти ложные.", ""]

    termed = [(c, t) for c in cases for t in c["terms"]]
    if termed:
        hits = [(c, t) for c, t in termed if term_found(t, c["hyp"])]
        lines += ["## Термины", "",
                  f"Записано как в эталоне: {len(hits)} из {len(termed)}, {100 * len(hits) / len(termed):.0f}%.", "",
                  "| Диктор | Термины, % |", "|---|---|"]
        for s in sorted({c["speaker"] for c in cases}):
            part = [(c, t) for c, t in termed if c["speaker"] == s]
            ok = sum(term_found(t, c["hyp"]) for c, t in part)
            lines.append(f"| {s} | {100 * ok / len(part):.0f} |")
        by_term = {}
        for c, t in termed:
            by_term.setdefault(t, []).append(c)
        lines += ["", "### Что вышло вместо термина", ""]
        for t, part in sorted(by_term.items(), key=lambda kv: sum(term_found(kv[0], c["hyp"]) for c in kv[1])):
            ok = sum(term_found(t, c["hyp"]) for c in part)
            if ok == len(part):
                continue
            lines.append(f"- **{t}** {ok}/{len(part)}: " + " · ".join(c["hyp"] for c in part))
        lines += ["", "### Записаны верно у всех дикторов", "",
                  ", ".join(t for t, part in sorted(by_term.items())
                            if all(term_found(t, c["hyp"]) for c in part)), ""]

    lines += ["## Фразы с латиницей", ""]
    for c in [c for c in cases if c["latin"] and not c["terms"]][:20]:
        lines += [f"- эталон: {c['raw']}", f"  распознано: {c['hyp']}"]

    clean = [c for c in cases if not c["numbers"] and not c["latin"]]
    lines += ["", "## Худшие фразы без чисел и латиницы", ""]
    for c in sorted(clean, key=lambda c: c["errors"] / max(c["ref_words"], 1), reverse=True)[:15]:
        lines += [f"- {c['speaker']}, {c['wps']:.1f} сл/с, ошибок {c['errors']} из {c['ref_words']}",
                  f"  эталон: {c['ref']}", f"  распознано: {c['hyp']}"]

    (out / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    with open(out / "cases.jsonl", "w", encoding="utf-8") as f:
        for c in cases:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    print(out / "report.md")


if __name__ == "__main__":
    main()
