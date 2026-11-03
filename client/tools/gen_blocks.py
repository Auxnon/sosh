#!/usr/bin/env python3
"""The block tiles, 32x32, and the dust puff sprite, into client/assets/
(gen_assets.py runs this too).

Run alone: `python3 client/tools/gen_blocks.py`. Needs Pillow.

Every tile wraps: its noise is periodic and anything drawn near an edge
continues on the other side, so a wall of blocks shows no seams. All of it is
deterministic (seeded), so regenerating changes nothing unless this does.
"""

import math
from pathlib import Path

from PIL import Image

ASSETS = Path(__file__).resolve().parents[1] / "assets"
N = 32


def rng(seed):
    """A tiny LCG: the same numbers on every machine and Python."""
    x = seed & 0x7FFFFFFF

    def next_int(n):
        nonlocal x
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        return (x >> 8) % n

    return next_int


def noise(seed, cells, rows=None):
    """Periodic value noise over the tile, 0..1, `cells` lattice cells across
    and `rows` down (as many as across unless given)."""
    rows = rows or cells
    r = rng(seed)
    lat = [[r(1000) / 999 for _ in range(cells)] for _ in range(rows)]

    def at(x, y):
        fx, fy = x * cells / N, y * rows / N
        ix, iy = int(fx), int(fy)
        tx, ty = fx - ix, fy - iy
        tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
        a = lat[iy % rows][ix % cells]
        b = lat[iy % rows][(ix + 1) % cells]
        c = lat[(iy + 1) % rows][ix % cells]
        d = lat[(iy + 1) % rows][(ix + 1) % cells]
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty

    return at


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3)) + (255,)


def shade(c, f):
    return tuple(max(0, min(255, round(v * f))) for v in c[:3]) + (255,)


def mottled(dark, base, light, seed, cells=4, fine=8):
    """Two octaves of noise banded into three tones, as painted pixel art is."""
    big, small = noise(seed, cells), noise(seed + 101, fine)
    im = Image.new("RGBA", (N, N))
    for y in range(N):
        for x in range(N):
            v = big(x, y) * 0.65 + small(x, y) * 0.35
            im.putpixel((x, y), dark if v < 0.38 else light if v > 0.64 else base)
    return im


def put(im, x, y, c):
    im.putpixel((x % N, y % N), c)


def tuft(im, x, y, c, tip):
    # a little upside-down V of blades, its tip lighter
    put(im, x, y, c)
    put(im, x - 1, y + 1, c)
    put(im, x + 1, y + 1, c)
    put(im, x, y - 1, tip)


def grass():
    dark, base, light = (78, 140, 70, 255), (100, 166, 84, 255), (124, 186, 98, 255)
    im = mottled(dark, base, light, 7)
    r = rng(71)
    for _ in range(22):
        tuft(im, r(N), r(N), (140, 200, 108, 255), (170, 220, 128, 255))
    for _ in range(10):
        tuft(im, r(N), r(N), (70, 128, 62, 255), (84, 146, 72, 255))
    # a couple of tiny flowers
    for c in ((248, 236, 200, 255), (246, 196, 92, 255)):
        x, y = r(N), r(N)
        put(im, x, y, c)
        put(im, x + 1, y, shade(c, 0.85))
    return im


def dirt():
    im = mottled((108, 76, 52, 255), (132, 94, 64, 255), (150, 110, 76, 255), 13)
    pebbles(im, 131, 9, (166, 132, 98, 255), (96, 66, 46, 255))
    return im


def pebbles(im, seed, count, top, under):
    # a lit pixel or two over a shadowed one
    r = rng(seed)
    for _ in range(count):
        x, y = r(N), r(N)
        put(im, x, y, top)
        if r(2):
            put(im, x + 1, y, top)
        put(im, x, y + 1, under)
        put(im, x + 1, y + 1, under)


def path():
    im = mottled((176, 156, 118, 255), (196, 178, 140, 255), (212, 196, 160, 255), 3, cells=4, fine=16)
    pebbles(im, 33, 14, (226, 214, 184, 255), (156, 136, 100, 255))
    return im


def stone():
    """Cobbles: points on a wrapping grid, each pixel its nearest point's
    stone, mortar where two are nearly as near, lit up-left."""
    r = rng(11)
    pts = []
    for gy in range(4):
        for gx in range(4):
            pts.append((gx * 8 + 2 + r(5), gy * 8 + 2 + r(5), 0.86 + r(30) / 100))
    fine = noise(111, 16)
    im = Image.new("RGBA", (N, N))
    base = (132, 136, 148, 255)
    mortar = (84, 86, 98, 255)
    for y in range(N):
        for x in range(N):
            ds = []
            for px, py, tone in pts:
                dx = min(abs(x - px), N - abs(x - px))
                dy = min(abs(y - py), N - abs(y - py))
                ds.append((math.hypot(dx, dy), tone, px, py))
            ds.sort()
            d0, tone, px, py = ds[0]
            if ds[1][0] - d0 < 1.3:
                im.putpixel((x, y), mortar)
                continue
            c = shade(base, tone + (fine(x, y) - 0.5) * 0.12)
            # lit from up-left, shadowed down-right, near the stone's edge
            ox = ((x - px + N // 2) % N) - N // 2
            oy = ((y - py + N // 2) % N) - N // 2
            edge = ds[1][0] - d0
            if edge < 3.2 and ox + oy < 0:
                c = shade(c, 1.14)
            elif edge < 3.2 and ox + oy > 0:
                c = shade(c, 0.86)
            im.putpixel((x, y), c)
    return im


def planks(light, base, dark, seam, seed, rows=4, rivets=None):
    """Boards across the tile, `rows` of them, with grain, staggered ends and
    a knot or two; `rivets` puts a pin at each board's ends."""
    h = N // rows
    r = rng(seed)
    # long along the boards, tight across them
    grain = noise(seed + 5, 2, 16)
    im = Image.new("RGBA", (N, N))
    for y in range(N):
        for x in range(N):
            g = grain(x, y)
            im.putpixel((x, y), dark if g < 0.3 else light if g > 0.72 else base)
    for row in range(rows):
        y0 = row * h
        for x in range(N):
            put(im, x, y0, seam)
            put(im, x, y0 + 1, shade(light, 1.06))
        end = (row * 13 + r(8)) % N
        for y in range(y0, y0 + h):
            put(im, end, y, seam)
            put(im, end + 1, y, shade(light, 1.06))
        if rivets is not None:
            for x in (end + 3, end - 3):
                put(im, x, y0 + h // 2, rivets)
                put(im, x, y0 + h // 2 + 1, shade(rivets, 0.7))
        if r(3) == 0:
            kx, ky = r(N), y0 + 2 + r(max(1, h - 4))
            put(im, kx, ky, seam)
            put(im, kx + 1, ky, dark)
            put(im, kx - 1, ky, dark)
    return im


def wood():
    return planks((186, 136, 86, 255), (168, 120, 72, 255), (148, 104, 62, 255), (110, 76, 44, 255), 17)


def deck():
    return planks((210, 166, 112, 255), (196, 150, 98, 255), (178, 134, 86, 255), (140, 100, 60, 255), 31, rows=4)


def hull():
    return planks(
        (126, 90, 60, 255), (112, 78, 52, 255), (98, 68, 46, 255), (70, 48, 32, 255), 37, rows=3,
        rivets=(200, 180, 128, 255),
    )


def water():
    im = mottled((70, 124, 186, 255), (86, 140, 196, 255), (100, 154, 206, 255), 5, cells=2, fine=4)
    r = rng(55)
    for _ in range(7):
        # a ripple: a short bright arc with a darker line under it
        x, y, w = r(N), r(N), 4 + r(4)
        for i in range(w):
            lift = 1 if 0 < i < w - 1 else 0
            put(im, x + i, y - lift, (170, 206, 236, 255))
            put(im, x + i, y + 1 - lift, (72, 122, 180, 255))
    return im


def balloon():
    im = mottled((214, 202, 178, 255), (226, 216, 194, 255), (236, 228, 210, 255), 41, cells=2, fine=8)
    # the canvas's weave, and a red band with a stitched edge
    for y in range(N):
        for x in range(N):
            if (x + y) % 4 == 0 and (x // 2 + y) % 3 == 0:
                im.putpixel((x, y), shade(im.getpixel((x, y)), 0.94))
    for y in range(12, 20):
        for x in range(N):
            c = (200, 80, 64, 255) if 13 < y < 18 else (176, 64, 52, 255)
            if y in (13, 18) and x % 3 == 0:
                c = (236, 220, 196, 255)
            im.putpixel((x, y), c)
    return im


def rail():
    im = wood()
    frame, shadow = (120, 84, 48, 255), (146, 102, 60, 255)
    for y in range(N):
        for x in range(N):
            if y < 6 or x in (0, 1, 30, 31, 14, 15, 16, 17):
                im.putpixel((x, y), shade(frame, 1.0 + ((x * 7 + y * 3) % 5 - 2) * 0.03))
            elif y > 25:
                im.putpixel((x, y), shadow)
    for x in range(N):
        im.putpixel((x, 0), (156, 112, 68, 255))
    return im


def helm():
    im = wood()
    gold, brass = (226, 190, 102, 255), (176, 140, 66, 255)
    hub = (120, 84, 48, 255)
    for y in range(N):
        for x in range(N):
            dx, dy = x - 15.5, y - 15.5
            d = math.hypot(dx, dy)
            spoke = d < 13 and (abs(dx) < 1.2 or abs(dy) < 1.2 or abs(abs(dx) - abs(dy)) < 1.2)
            if 9.5 <= d <= 12.5:
                im.putpixel((x, y), gold if dx + dy < 0 else brass)
            elif spoke and d > 3.2:
                im.putpixel((x, y), brass)
            elif d < 3.2:
                im.putpixel((x, y), gold if d < 1.6 else hub)
    return im


TILES = {
    "grass": grass,
    "dirt": dirt,
    "stone": stone,
    "wood": wood,
    "path": path,
    "water": water,
    "deck": deck,
    "hull": hull,
    "balloon": balloon,
    "rail": rail,
    "helm": helm,
}


def dust():
    """A skid's puff (avatar.lua's Dust): a lumpy 16x16 cloud, lit on top,
    clear around it (the engine draws it as a billboard)."""
    n = 16
    lumps = ((8, 9, 5.2), (5, 7, 3.4), (11, 6.5, 3.6), (8, 5, 3.2))
    light, base, dark = (240, 228, 204, 255), (222, 206, 176, 255), (190, 172, 140, 255)
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    for y in range(n):
        for x in range(n):
            # how deep inside the nearest lump, and where in it
            best = None
            for cx, cy, r in lumps:
                d = math.hypot(x + 0.5 - cx, y + 0.5 - cy) / r
                if d < 1 and (best is None or d < best[0]):
                    best = (d, y + 0.5 - cy)
            if best is None:
                continue
            d, dy = best
            c = light if dy < -0.35 * d * 4 else dark if dy > 1.2 or d > 0.84 else base
            im.putpixel((x, y), c)
    return im


SPRITES = {"dust": dust}


def build(assets=ASSETS):
    assets.mkdir(parents=True, exist_ok=True)
    for name, make in {**TILES, **SPRITES}.items():
        make().save(assets / f"{name}.png")


if __name__ == "__main__":
    build()
