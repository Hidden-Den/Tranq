#!/usr/bin/env python3
"""Озвучивает фразы с англицизмами для замера распознавания.

Использование: eval-synth.py [фразы.jsonl] [--out каталог]

Каждая фраза в jsonl: spoken — как её произносят по-русски, ref — как она должна
быть записана, terms — латинские термины, которые обязаны дожить до текста.
Озвучивает каждым русским голосом macOS и раскладывает на несколько «дикторов»:
темп и высота меняются через ffmpeg. Пишет набор в формате FLEURS, который читает
eval-asr.py: test.tsv и audio/test/*.wav, 16 кГц моно. Восьмая колонка test.tsv —
термины через «|», шестая — диктор вместо пола.
"""
import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Диктор: темп и высота относительно исходного голоса
SPEAKERS = {
    "base": (1.0, 1.0),
    "slow-low": (0.85, 0.88),
    "fast-high": (1.25, 1.12),
    "deep": (1.0, 0.78),
}


def russian_voices():
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, check=True).stdout
    names = []
    for line in out.splitlines():
        if "ru_RU" in line:
            name = re.split(r"\s+\(|\s{2,}", line.strip())[0]
            if name not in names:
                names.append(name)
    return names


def render(text, voice, speed, pitch, dest):
    with tempfile.NamedTemporaryFile(suffix=".aiff") as tmp:
        subprocess.run(["say", "-v", voice, "--data-format=BEI16@22050", "-o", tmp.name, text], check=True)
        # asetrate меняет высоту вместе с темпом, atempo возвращает темп к нужному
        filt = f"asetrate=22050*{pitch},aresample=16000,atempo={speed / pitch:.4f}"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", tmp.name, "-af", filt,
                        "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(dest)], check=True)


def samples(path):
    # Заголовок wav 44 байта, 2 байта на отсчёт
    return (path.stat().st_size - 44) // 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("phrases", type=Path, nargs="?", default=ROOT / "scripts" / "eval-terms.jsonl")
    ap.add_argument("--out", type=Path, default=ROOT / "eval-data" / "terms-ru")
    args = ap.parse_args()

    voices = russian_voices()
    if not voices:
        raise SystemExit("Нет русских голосов macOS")
    rows = [json.loads(l) for l in args.phrases.read_text(encoding="utf-8").splitlines() if l.strip()]
    audio = args.out / "audio" / "test"
    audio.mkdir(parents=True, exist_ok=True)

    tsv = []
    for i, row in enumerate(rows):
        for voice in voices:
            for name, (speed, pitch) in SPEAKERS.items():
                speaker = f"{voice.lower()}-{name}"
                wav = audio / f"{i:03d}-{speaker}.wav"
                if not wav.exists():
                    render(row["spoken"], voice, speed, pitch, wav)
                normalized = " ".join(re.findall(r"[a-zа-яё0-9']+", row["ref"].lower()))
                tsv.append("\t".join([str(i), wav.name, row["ref"], normalized, "",
                                      str(samples(wav)), speaker, "|".join(row["terms"])]))
        print(f"\r{i + 1}/{len(rows)}", end="", flush=True)
    (args.out / "test.tsv").write_text("\n".join(tsv) + "\n", encoding="utf-8")
    print(f"\n{len(tsv)} записей, голоса: {', '.join(voices)} → {args.out}")


if __name__ == "__main__":
    main()
