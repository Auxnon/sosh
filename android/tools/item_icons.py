#!/usr/bin/env python3
"""The bag's item icons for the app, into app/src/main/res/drawable-nodpi/.

Run from anywhere: `python3 android/tools/item_icons.py`. Needs Pillow.

Blocks use the game's own 16x16 textures (client/assets, made by
client/tools/gen_assets.py); the rest (pot, carrot, drawer, stool) are
drawn here at the same size, so the app shows them pixelated like the game.
The app falls back to a lettered tile for anything without an icon.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
TEXTURES = ROOT.parent / "client" / "assets"
OUT = ROOT / "app" / "src" / "main" / "res" / "drawable-nodpi"

BLOCKS = ["grass", "dirt", "stone", "wood", "path", "deck", "hull", "balloon", "rail", "helm"]


def canvas():
    im = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def pot():
    im, d = canvas()
    d.rectangle([3, 3, 12, 4], fill=(176, 98, 62))
    d.polygon([(4, 5), (11, 5), (10, 13), (5, 13)], fill=(201, 116, 74))
    d.line([(5, 7), (10, 7)], fill=(160, 84, 52))
    d.rectangle([5, 4, 10, 4], fill=(110, 80, 50))
    return im


def carrot():
    im, d = canvas()
    d.polygon([(6, 5), (10, 5), (8, 14)], fill=(242, 140, 40))
    d.line([(7, 8), (8, 8)], fill=(200, 100, 30))
    d.line([(8, 11), (9, 11)], fill=(200, 100, 30))
    d.line([(8, 5), (6, 1)], fill=(90, 170, 60))
    d.line([(8, 5), (8, 1)], fill=(110, 190, 70))
    d.line([(8, 5), (10, 2)], fill=(90, 170, 60))
    return im


def drawer():
    im, d = canvas()
    d.rectangle([2, 3, 13, 13], fill=(176, 122, 69))
    d.rectangle([3, 4, 12, 7], fill=(196, 142, 86))
    d.rectangle([3, 9, 12, 12], fill=(196, 142, 86))
    d.rectangle([7, 5, 8, 5], fill=(90, 60, 30))
    d.rectangle([7, 10, 8, 10], fill=(90, 60, 30))
    return im


def stool():
    im, d = canvas()
    d.rectangle([3, 4, 12, 6], fill=(196, 142, 86))
    d.rectangle([4, 7, 5, 13], fill=(140, 92, 50))
    d.rectangle([10, 7, 11, 13], fill=(140, 92, 50))
    d.rectangle([5, 10, 10, 10], fill=(140, 92, 50))
    return im


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name in BLOCKS:
        Image.open(TEXTURES / f"{name}.png").convert("RGBA").save(OUT / f"item_{name}.png")
    for name, draw in [("pot", pot), ("carrot", carrot), ("drawer", drawer), ("stool", stool)]:
        draw().save(OUT / f"item_{name}.png")
    print(f"wrote item icons to {OUT}")


if __name__ == "__main__":
    main()
