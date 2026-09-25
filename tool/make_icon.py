# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Regenerate the icon: python3 tool/make_icon.py assets/icon   (needs Pillow)
"""Agora icon, v2: the stoa that lined the Athenian agora, drawn black-figure
(glaze-black on Attic terracotta), with people gathered in the open square in
front of it. The square and the gathering are the point; the colonnade only
says where.

Writes the SVG source and PNGs rendered from the same geometry.
"""
import math, sys
from PIL import Image, ImageDraw

out = sys.argv[1]
CLAY, CLAY_DARK, GLAZE = '#C2562A', '#9E4220', '#1F1A17'
BG_R = 52

ROOF = [(26, 74), (128, 40), (230, 74)]            # a stoa's shallow gable
ENTABLATURE = (30, 76, 226, 90)
COLS = [(cx, 96, 138) for cx in (46, 79, 112, 144, 177, 210)]
COL_W = 13
STYLOBATE = (24, 140, 232, 150)
# five people on an arc that opens toward the viewer, as if gathered to talk
PEOPLE = []
for i, dx in enumerate((-72, -36, 0, 36, 72)):
    cx = 128 + dx
    lift = (abs(dx) / 72) ** 2 * 14                 # outer figures stand further back
    PEOPLE.append((cx, 182 - lift))                 # head centre
HEAD_R, BODY_W, BODY_H = 10, 30, 22                 # body = half-ellipse under the head

def rects():
    r = [ENTABLATURE, STYLOBATE]
    r += [(cx - COL_W / 2, y0, cx + COL_W / 2, y1) for cx, y0, y1 in COLS]
    return r

def body_box(cx, hy):
    top = hy + HEAD_R + 3
    return (cx - BODY_W / 2, top, cx + BODY_W / 2, top + 2 * BODY_H)

def svg():
    b = [f'<rect x="4" y="4" width="248" height="248" rx="{BG_R}" fill="{CLAY}" stroke="{CLAY_DARK}" stroke-width="4"/>',
         '<polygon points="' + ' '.join(f'{x},{y}' for x, y in ROOF) + f'" fill="{GLAZE}"/>']
    b += [f'<rect x="{x0:g}" y="{y0:g}" width="{x1-x0:g}" height="{y1-y0:g}" fill="{GLAZE}"/>' for x0, y0, x1, y1 in rects()]
    for cx, hy in PEOPLE:
        x0, y0, x1, y1 = body_box(cx, hy)
        cy = y0 + BODY_H
        b.append(f'<circle cx="{cx:g}" cy="{hy:g}" r="{HEAD_R}" fill="{GLAZE}"/>')
        b.append(f'<path d="M{x0:g},{cy:g} A{BODY_W/2:g},{BODY_H:g} 0 0 1 {x1:g},{cy:g} Z" fill="{GLAZE}"/>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">\n'
            '  <title>Agora</title>\n  ' + '\n  '.join(b) + '\n</svg>\n')

def png(size):
    ss = 8; S = size * ss / 256; sc = lambda v: v * S
    im = Image.new('RGBA', (size * ss,) * 2, (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    d.rounded_rectangle([sc(4), sc(4), sc(252), sc(252)], radius=sc(BG_R), fill=CLAY,
                        outline=CLAY_DARK, width=max(1, round(sc(4))))
    d.polygon([(sc(x), sc(y)) for x, y in ROOF], fill=GLAZE)
    for x0, y0, x1, y1 in rects():
        d.rectangle([sc(x0), sc(y0), sc(x1), sc(y1)], fill=GLAZE)
    for cx, hy in PEOPLE:
        d.ellipse([sc(cx - HEAD_R), sc(hy - HEAD_R), sc(cx + HEAD_R), sc(hy + HEAD_R)], fill=GLAZE)
        x0, y0, x1, y1 = body_box(cx, hy)
        d.pieslice([sc(x0), sc(y0), sc(x1), sc(y1)], 180, 360, fill=GLAZE)
    return im.resize((size, size), Image.LANCZOS)

open(f'{out}/agora.svg', 'w').write(svg())
sizes = (16, 32, 48, 64, 128, 256, 512)
for s in sizes:
    png(s).save(f'{out}/agora-{s}.png', optimize=True)
sheet = Image.new('RGBA', (sum(sizes) + 10 * (len(sizes) + 1), 520), (245, 241, 234, 255)); x = 10
for s in reversed(sizes):
    sheet.alpha_composite(Image.open(f'{out}/agora-{s}.png'), (x, 520 - s - 4)); x += s + 10
sheet.save(f"{out}/../icon-sheet.png") if "--sheet" in sys.argv else None
