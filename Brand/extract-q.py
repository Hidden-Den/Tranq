#!/usr/bin/env python3
"""Вытаскивает контур строчной буквы q из Knewave в Brand/q.svg.

Запуск из окружения с fonttools, вне репозитория:
    python3 Brand/extract-q.py Tranq/Fonts/Knewave-Regular.ttf Brand/q.svg [буква]

Буква по умолчанию q, строчная.
"""
import sys

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

font_path, out_path = sys.argv[1], sys.argv[2]
letter = sys.argv[3] if len(sys.argv) > 3 else "q"
font = TTFont(font_path)
glyphs = font.getGlyphSet()
name = font.getBestCmap()[ord(letter)]

bounds = BoundsPen(glyphs)
glyphs[name].draw(bounds)
x_min, y_min, x_max, y_max = bounds.bounds

# В шрифте ось Y смотрит вверх, в SVG вниз: переворачиваем и сдвигаем в начало координат.
pen = SVGPathPen(glyphs)
glyphs[name].draw(TransformPen(pen, (1, 0, 0, -1, -x_min, y_max)))

width, height = x_max - x_min, y_max - y_min
with open(out_path, "w", encoding="utf-8") as f:
    f.write(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:g} {height:g}" '
        f'width="{width:g}" height="{height:g}">'
        f'<path fill="#000000" d="{pen.getCommands()}"/></svg>\n'
    )
print(f"{letter}: {width:g} x {height:g} -> {out_path}")
