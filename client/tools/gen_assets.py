#!/usr/bin/env python3
"""Generate the sosh client's models and textures into client/assets/.

Run from anywhere: `python3 client/tools/gen_assets.py`. Needs Pillow.

Why generated .glb files rather than `mod()` in Lua: on the web build Lua runs
in a worker and `mod()` has no route to the renderer there, while models in
assets/ are loaded on the main thread and work on both targets. Each model
embeds its own texture, because a model entity takes its texture from the
model it was made with.

World axes are Z-up (petrichor convention) and an avatar faces +X at rz=0.
"""

import io
import json
import struct
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
FACES = ROOT.parent / "front" / "public" / "assets" / "faces.png"

HEAD_RGB = (244, 232, 212, 255)
WHITE = (255, 255, 255, 255)


def png_bytes(im):
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return buf.getvalue()


def write_glb(path, positions, uvs, indices, png):
    """Minimal single-mesh, single-texture glTF 2.0 binary."""
    pos_b = b"".join(struct.pack("<3f", *p) for p in positions)
    uv_b = b"".join(struct.pack("<2f", *t) for t in uvs)
    idx_b = b"".join(struct.pack("<H", i) for i in indices)

    def pad(b):
        return b + b"\0" * (-len(b) % 4)

    parts = [pad(pos_b), pad(uv_b), pad(idx_b), pad(png)]
    offsets, o = [], 0
    for p in parts:
        offsets.append(o)
        o += len(p)
    binary = b"".join(parts)

    xs, ys, zs = zip(*positions)
    gltf = {
        "asset": {"version": "2.0", "generator": "sosh gen_assets.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [
            {
                "name": path.stem,
                "primitives": [
                    {
                        "attributes": {"POSITION": 0, "TEXCOORD_0": 1},
                        "indices": 2,
                        "material": 0,
                    }
                ],
            }
        ],
        "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9728, "minFilter": 9728}],
        "images": [{"bufferView": 3, "mimeType": "image/png"}],
        "buffers": [{"byteLength": len(binary)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": offsets[0], "byteLength": len(pos_b), "target": 34962},
            {"buffer": 0, "byteOffset": offsets[1], "byteLength": len(uv_b), "target": 34962},
            {"buffer": 0, "byteOffset": offsets[2], "byteLength": len(idx_b), "target": 34963},
            {"buffer": 0, "byteOffset": offsets[3], "byteLength": len(png)},
        ],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": 5126,
                "count": len(positions),
                "type": "VEC3",
                "min": [min(xs), min(ys), min(zs)],
                "max": [max(xs), max(ys), max(zs)],
            },
            {"bufferView": 1, "componentType": 5126, "count": len(uvs), "type": "VEC2"},
            {"bufferView": 2, "componentType": 5123, "count": len(indices), "type": "SCALAR"},
        ],
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(binary))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js
    out += struct.pack("<II", len(binary), 0x004E4942) + binary
    path.write_bytes(out)


def frustum(bx, by, tx, ty, z0, z1, face_uv):
    """Box from z0 to z1, bottom half-extents (bx, by), top (tx, ty).

    face_uv(name) -> (u0, v0, u1, v1) picks each face's texture rect; glTF v
    runs top-down, so v0 is the top edge.
    """
    b = [(-bx, -by, z0), (bx, -by, z0), (bx, by, z0), (-bx, by, z0)]
    t = [(-tx, -ty, z1), (tx, -ty, z1), (tx, ty, z1), (-tx, ty, z1)]
    # Each face: corners listed top-left, top-right, bottom-right, bottom-left
    # as seen from outside.
    faces = {
        "front": [t[1], t[2], b[2], b[1]],  # +X, viewer's right is +Y
        "back": [t[3], t[0], b[0], b[3]],  # -X
        "left": [t[2], t[3], b[3], b[2]],  # +Y
        "right": [t[0], t[1], b[1], b[0]],  # -Y
        "top": [t[0], t[3], t[2], t[1]],
        "bottom": [b[1], b[2], b[3], b[0]],
    }
    pos, uv, idx = [], [], []
    for name, quad in faces.items():
        u0, v0, u1, v1 = face_uv(name)
        n = len(pos)
        pos += quad
        uv += [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
        # Two triangles, wound counter-clockwise from outside.
        idx += [n, n + 3, n + 2, n, n + 2, n + 1]
    return pos, uv, idx


def box(cx, cy, hx, hy, z0, z1, face_uv, top=None):
    """frustum() moved to (cx, cy); `top` gives a tapered top's half-extents."""
    tx, ty = top if top else (hx, hy)
    pos, uv, idx = frustum(hx, hy, tx, ty, z0, z1, face_uv)
    return [(x + cx, y + cy, z) for x, y, z in pos], uv, idx


def merge(*parts):
    """Several (pos, uv, idx) meshes as one."""
    pos, uv, idx = [], [], []
    for p, u, i in parts:
        n = len(pos)
        pos += p
        uv += u
        idx += [n + k for k in i]
    return pos, uv, idx


def rect(x0, y0, x1, y1, w, h):
    """Pixel rect of a w x h atlas as a face_uv for every face."""
    r = (x0 / w, y0 / h, x1 / w, y1 / h)
    return lambda n: r


COW_WHITE = (240, 236, 228, 255)
COW_SPOT = (48, 42, 44, 255)
COW_PINK = (232, 164, 164, 255)
COW_HOOF = (70, 60, 56, 255)


def cow_texture():
    """32x16 atlas: spotted hide (0-15), snout pink (16-23, top), hoof
    (24-31, top), and the face (16-31, bottom)."""
    im = Image.new("RGBA", (32, 16), COW_WHITE)
    x = 29
    for _ in range(5):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        sx, sy = x % 13, (x >> 8) % 13
        for dx in range(4):
            for dy in range(3 + (x >> 16) % 2):
                if (dx, dy) not in ((0, 0), (3, 0)):
                    im.putpixel(((sx + dx) % 16, (sy + dy) % 16), COW_SPOT)
    for px in range(16, 24):
        for py in range(8):
            im.putpixel((px, py), COW_PINK)
    for px in range(24, 32):
        for py in range(8):
            im.putpixel((px, py), COW_HOOF)
    # face: eyes up top, a pink muzzle along the bottom with nostrils
    for px in (18, 19, 28, 29):
        im.putpixel((px, 10), COW_SPOT)
        im.putpixel((px, 11), COW_SPOT)
    for px in range(17, 31):
        for py in (13, 14, 15):
            im.putpixel((px, py), COW_PINK)
    im.putpixel((20, 14), (150, 90, 90, 255))
    im.putpixel((27, 14), (150, 90, 90, 255))
    return im


def cow_mesh():
    """Faces +X, feet at z = 0, about a block long."""
    W, H = 32, 16
    hide = rect(0, 0, 16, 16, W, H)
    hoof = rect(24, 0, 32, 8, W, H)
    pink = rect(16, 0, 24, 8, W, H)
    face = rect(16, 8, 32, 16, W, H)
    head_uv = lambda n: face(n) if n == "front" else hide(n)
    parts = [box(-0.05, 0.0, 0.5, 0.27, 0.45, 0.95, hide)]
    for lx in (-0.38, 0.3):
        for ly in (-0.16, 0.16):
            parts.append(box(lx, ly, 0.08, 0.08, 0.0, 0.47, hoof))
    parts.append(box(0.6, 0.0, 0.17, 0.19, 0.68, 1.08, head_uv))
    for ey in (-0.25, 0.25):
        parts.append(box(0.56, ey, 0.04, 0.07, 0.98, 1.04, pink))
    parts.append(box(-0.58, 0.0, 0.03, 0.03, 0.5, 0.88, hoof))  # tail
    return merge(*parts)


def crop_texture():
    """16x8: leafy green (0-7), carrot orange (8-15)."""
    im = Image.new("RGBA", (16, 8), (86, 170, 72, 255))
    for px in range(8):
        for py in range(8):
            if (px * 3 + py * 5) % 7 == 0:
                im.putpixel((px, py), (60, 138, 56, 255))
    for px in range(8, 16):
        for py in range(8):
            im.putpixel((px, py), (238, 132, 42, 255) if py % 3 else (214, 110, 32, 255))
    return im


def carrot_mesh(stage):
    """A 2x2 patch in one block cell, growing taller by stage; ripe (3)
    shows the orange tops."""
    leaf = rect(0, 0, 8, 8, 16, 8)
    orange = rect(8, 0, 16, 8, 16, 8)
    leaf_w = (0.04, 0.06, 0.08, 0.09)[stage]
    leaf_h = (0.1, 0.22, 0.36, 0.42)[stage]
    parts = []
    for ox in (-0.2, 0.2):
        for oy in (-0.2, 0.2):
            base = 0.0
            if stage == 3:
                parts.append(box(ox, oy, 0.08, 0.08, 0.0, 0.12, orange, top=(0.07, 0.07)))
                base = 0.12
            parts.append(box(ox, oy, leaf_w * 0.5, leaf_w * 0.5, base, base + leaf_h, leaf, top=(leaf_w, leaf_w)))
    return merge(*parts)


def pot_texture():
    """16x8: terracotta with a darker band (0-7), soil (8-15)."""
    im = Image.new("RGBA", (16, 8), (196, 104, 62, 255))
    for px in range(8):
        for py in (5, 6):
            im.putpixel((px, py), (164, 82, 48, 255))
    for px in range(8, 16):
        for py in range(8):
            im.putpixel((px, py), (74, 52, 38, 255) if (px + py * 3) % 4 else (58, 40, 30, 255))
    return im


def pot_mesh(cx, cy):
    """A clay pot most of a block high, centred on (cx, cy), base at z = 0.
    Every corner sits on a 1/16 step: the engine stores model vertices in
    sixteenths of a tile."""
    clay = rect(0, 0, 8, 8, 16, 8)
    soil = rect(8, 0, 16, 8, 16, 8)
    rim_uv = lambda n: soil(n) if n == "top" else clay(n)
    s = 1 / 16
    return merge(
        box(cx, cy, 4 * s, 4 * s, 0.0, 8 * s, clay, top=(6 * s, 6 * s)),
        box(cx, cy, 6 * s, 6 * s, 8 * s, 11 * s, clay, top=(4 * s, 4 * s)),
        box(cx, cy, 5 * s, 5 * s, 11 * s, 13 * s, rim_uv),
    )


def solid(rgb, size=8):
    return Image.new("RGBA", (size, size), rgb)


def head_texture(face):
    """128x64: left half plain head colour, right half the face on it."""
    im = Image.new("RGBA", (128, 64), HEAD_RGB)
    im.alpha_composite(face, (64, 0))
    return im


def tile_texture(base, speckle, seed):
    """16x16 pixel-art ground tile: base colour with deterministic speckles."""
    im = Image.new("RGBA", (16, 16), base)
    x = seed
    for _ in range(18):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        im.putpixel((x % 16, (x >> 8) % 16), speckle)
    return im


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)

    faces = Image.open(FACES).convert("RGBA")
    count = faces.width // 64
    for i in range(count):
        face = faces.crop((i * 64, 0, i * 64 + 64, 64))
        uv = lambda n: (0.5, 0.0, 1.0, 1.0) if n == "front" else (0.0, 0.0, 0.5, 1.0)
        pos, uvs, idx = frustum(0.3, 0.3, 0.3, 0.3, 0.0, 0.6, uv)
        write_glb(ASSETS / f"head{i}.glb", pos, uvs, idx, png_bytes(head_texture(face)))

    # Body and arm are white so per-player tint colours them.
    whole = lambda n: (0.0, 0.0, 1.0, 1.0)
    pos, uvs, idx = frustum(0.34, 0.3, 0.2, 0.18, 0.0, 0.85, whole)
    write_glb(ASSETS / "body.glb", pos, uvs, idx, png_bytes(solid(WHITE)))
    pos, uvs, idx = frustum(0.07, 0.07, 0.07, 0.07, -0.5, 0.0, whole)
    write_glb(ASSETS / "arm.glb", pos, uvs, idx, png_bytes(solid(WHITE)))

    tile_texture((112, 168, 96, 255), (92, 146, 80, 255), 7).save(ASSETS / "grass.png")
    tile_texture((196, 178, 140, 255), (176, 158, 120, 255), 3).save(ASSETS / "path.png")
    tile_texture((120, 124, 136, 255), (100, 104, 116, 255), 11).save(ASSETS / "stone.png")
    tile_texture((86, 140, 196, 255), (110, 160, 210, 255), 5).save(ASSETS / "water.png")
    tile_texture((134, 96, 66, 255), (112, 78, 52, 255), 13).save(ASSETS / "dirt.png")
    wood = tile_texture((168, 120, 72, 255), (146, 102, 60, 255), 17)
    for y in (0, 5, 10, 15):
        for x in range(16):
            wood.putpixel((x, y), (120, 84, 48, 255))
    wood.save(ASSETS / "wood.png")

    # Block cursor: an outline cube a touch larger than a block, so it shows
    # around the hovered block. Spans a block placed at (x, y, z): x/y centred,
    # z from the base (the world's tile convention, see scripts/blocks.lua).
    edge = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    for i in range(16):
        for t in (0, 15):
            edge.putpixel((i, t), (255, 236, 160, 255))
            edge.putpixel((t, i), (255, 236, 160, 255))
    pos, uvs, idx = frustum(0.52, 0.52, 0.52, 0.52, -0.02, 1.02, whole)
    write_glb(ASSETS / "cursor.glb", pos, uvs, idx, png_bytes(edge))

    pos, uvs, idx = cow_mesh()
    write_glb(ASSETS / "cow.glb", pos, uvs, idx, png_bytes(cow_texture()))
    for stage in range(4):
        pos, uvs, idx = carrot_mesh(stage)
        write_glb(ASSETS / f"carrot{stage}.glb", pos, uvs, idx, png_bytes(crop_texture()))

    # The pot block, drawn as an entity in its cell (blocks.lua) and when
    # carried.
    pos, uvs, idx = pot_mesh(0.0, 0.0)
    write_glb(ASSETS / "pot.glb", pos, uvs, idx, png_bytes(pot_texture()))

    # Cart icon (game root, required by `pack`): the smiling head on dusk blue.
    icon = Image.new("RGBA", (64, 64), (70, 110, 170, 255))
    head = Image.new("RGBA", (48, 48), HEAD_RGB)
    head.alpha_composite(faces.crop((5 * 64, 0, 6 * 64, 64)).resize((48, 48), Image.NEAREST))
    icon.alpha_composite(head, (8, 8))
    icon.save(ROOT / "icon.png")

    print(f"wrote {count} heads, body, arm, cow, carrots, pots and ground tiles to {ASSETS}")


if __name__ == "__main__":
    main()
