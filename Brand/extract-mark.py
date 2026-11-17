#!/usr/bin/env python3
"""Собирает монограмму из букв Knewave в один SVG с векторным контуром.

Запуск из окружения с fonttools, вне репозитория:
    python3 Brand/extract-mark.py Tranq/Fonts/Knewave-Regular.ttf Brand/tq.svg [текст] [сдвиг]

Текст по умолчанию Tq: заглавная T и строчная q. Сдвиг в единицах шрифта
добавляется к промежутку между буквами, отрицательный сближает их.
"""
import sys

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

font_path, out_path = sys.argv[1], sys.argv[2]
text = sys.argv[3] if len(sys.argv) > 3 else "Tq"
gap = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0

font = TTFont(font_path)
glyphs = font.getGlyphSet()
cmap = font.getBestCmap()
advances = font["hmtx"]

# Буквы идут слева направо по ширине глифа плюс сдвиг.
placed, x = [], 0.0
for ch in text:
    name = cmap[ord(ch)]
    placed.append((name, x))
    x += advances[name][0] + gap

bounds = BoundsPen(glyphs)
for name, dx in placed:
    glyphs[name].draw(TransformPen(bounds, (1, 0, 0, 1, dx, 0)))
x_min, y_min, x_max, y_max = bounds.bounds

# В шрифте ось Y смотрит вверх, в SVG вниз: переворачиваем и сдвигаем в начало координат.
pen = SVGPathPen(glyphs)
for name, dx in placed:
    glyphs[name].draw(TransformPen(pen, (1, 0, 0, -1, dx - x_min, y_max)))

width, height = x_max - x_min, y_max - y_min
with open(out_path, "w", encoding="utf-8") as f:
    f.write(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:g} {height:g}" '
        f'width="{width:g}" height="{height:g}">'
        f'<path fill="#000000" d="{pen.getCommands()}"/></svg>\n'
    )
print(f"{text}: {width:g} x {height:g} -> {out_path}")
