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

    # Cart icon (game root, required by `pack`): the smiling head on dusk blue.
    icon = Image.new("RGBA", (64, 64), (70, 110, 170, 255))
    head = Image.new("RGBA", (48, 48), HEAD_RGB)
    head.alpha_composite(faces.crop((5 * 64, 0, 6 * 64, 64)).resize((48, 48), Image.NEAREST))
    icon.alpha_composite(head, (8, 8))
    icon.save(ROOT / "icon.png")

    print(f"wrote {count} heads, body, arm and ground tiles to {ASSETS}")


if __name__ == "__main__":
    main()
