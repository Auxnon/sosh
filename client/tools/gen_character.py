"""Character parts for the creator (scripts/character.lua), from the converted
player rig (assets/player.glb, see gen_assets.player_model):

  body.glb         the player's body without its head, plain white: tinted
                   with the skin colour
  cl_<name>.glb    clothes: the body's own triangles for that piece, pushed
                   out along their normals. Same skeleton, same joints and
                   weights per vertex, same clips, so they move as the body
                   does and stretch with it. White, tinted
  head_<name>.glb  heads, rigid, origin at the head bone: the engine keeps
                   them on it
  hair_<name>.glb, hat_<name>.glb   rigid on the head too, white
  fp_<part><n>.glb face sprites: a square facing +X, one unit across,
                   centred on its origin, its shape white on clear: placed,
                   turned, scaled and tinted one by one on the front of
                   the head

Also writes scripts/character_rig.lua: where things are on the rig (head
fronts, the bones' rest translations for stretching) for the client.

World axes are Z-up and the rig faces +X, as everywhere in sosh.
"""

import json
import math
import struct
from pathlib import Path

from PIL import Image, ImageDraw

WHITE = (255, 255, 255, 255)

# Bones whose rest translations scale with height (thigh, shin; spine; arm)
STRETCH = ["leg.l", "foot.l", "leg.r", "foot.r", "chest", "neck",
           "arm.l", "wrist.l", "hand.l", "arm.r", "wrist.r", "hand.r"]

# clothes: which bones' skin they cover, and how far out they sit
CLOTHES = {
    "tee": (["tummy", "chest", "shoulder.l", "shoulder.r", "root"], 0.018),
    "jacket": (["tummy", "chest", "shoulder.l", "shoulder.r", "arm.l", "arm.r", "wrist.l", "wrist.r", "root"], 0.03),
    "sweater": (["tummy", "chest", "neck", "shoulder.l", "shoulder.r", "arm.l", "arm.r", "wrist.l", "wrist.r", "root"], 0.024),
    "pants": (["root", "waist.l", "waist.r", "calf.l", "calf.r", "leg.l", "leg.r"], 0.016),
    "shorts": (["root", "waist.l", "waist.r", "calf.l", "calf.r"], 0.02),
    "skirt": (["root", "waist.l", "waist.r", "calf.l", "calf.r"], 0.05),
    "shoes": (["foot.l", "foot.r"], 0.016),
    "boots": (["foot.l", "foot.r", "leg.l", "leg.r"], 0.022),
}


def png_bytes(im):
    import io
    b = io.BytesIO()
    im.save(b, "PNG")
    return b.getvalue()


def plain(size=4):
    return Image.new("RGBA", (size, size), WHITE)


# -- glb writing

class Builder:
    """Accessors and buffer views packed into one binary."""

    def __init__(self):
        self.bin = bytearray()
        self.views = []
        self.accessors = []

    def view(self, data, target=None):
        self.bin += b"\0" * (-len(self.bin) % 4)
        v = {"buffer": 0, "byteOffset": len(self.bin), "byteLength": len(data)}
        if target:
            v["target"] = target
        self.views.append(v)
        self.bin += data
        return len(self.views) - 1

    def accessor(self, rows, ctype, atype, target=None, minmax=False):
        fmt = {5126: "f", 5123: "H", 5121: "B"}[ctype]
        width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[atype]
        data = b"".join(
            struct.pack("<" + fmt * width, *(r if isinstance(r, (tuple, list)) else (r,))) for r in rows
        )
        a = {"bufferView": self.view(data, target), "componentType": ctype, "count": len(rows), "type": atype}
        if minmax:
            cols = list(zip(*rows))
            a["min"] = [min(c) for c in cols]
            a["max"] = [max(c) for c in cols]
        self.accessors.append(a)
        return len(self.accessors) - 1

    def glb(self, j):
        self.bin += b"\0" * (-len(self.bin) % 4)
        j["buffers"] = [{"byteLength": len(self.bin)}]
        j["bufferViews"] = self.views
        j["accessors"] = self.accessors
        js = json.dumps(j, separators=(",", ":")).encode()
        js += b" " * (-len(js) % 4)
        out = struct.pack("<III", 0x46546C67, 2, 28 + len(js) + len(self.bin))
        out += struct.pack("<II", len(js), 0x4E4F534A) + js
        out += struct.pack("<II", len(self.bin), 0x004E4942) + bytes(self.bin)
        return out


def material(j, b, png):
    j["images"] = [{"bufferView": b.view(png), "mimeType": "image/png"}]
    j["samplers"] = [{"magFilter": 9728, "minFilter": 9728}]
    j["textures"] = [{"source": 0, "sampler": 0}]
    j["materials"] = [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}]


def static_glb(path, pos, uvs, idx, png, normals=None):
    b = Builder()
    attrs = {"POSITION": b.accessor(pos, 5126, "VEC3", 34962, minmax=True),
             "TEXCOORD_0": b.accessor(uvs, 5126, "VEC2", 34962)}
    if normals:
        attrs["NORMAL"] = b.accessor(normals, 5126, "VEC3", 34962)
    ind = b.accessor(idx, 5123, "SCALAR", 34963)
    j = {"asset": {"version": "2.0", "generator": "sosh gen_character.py"},
         "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"name": path.stem, "primitives": [{"attributes": attrs, "indices": ind, "material": 0}]}]}
    material(j, b, png)
    path.write_bytes(b.glb(j))


def skinned_glb(path, rig, mesh, png):
    """A glb with `rig`'s nodes, skin and clips and a new skinned mesh:
    `mesh` is (positions, normals, uvs, joints, weights, indices)."""
    src = rig.json
    j = {k: json.loads(json.dumps(src[k])) for k in ("asset", "scene", "scenes", "nodes", "skins", "animations")}
    j["asset"]["generator"] = "sosh gen_character.py"
    b = Builder()
    # the rig's own data: inverse binds, clip times and keys
    remap = {}

    def copy(i):
        if i not in remap:
            a = src["accessors"][i]
            rows = rig.read(i)
            remap[i] = b.accessor(rows, a["componentType"], a["type"], minmax="min" in a)
        return remap[i]

    for s in j["skins"]:
        s["inverseBindMatrices"] = copy(s["inverseBindMatrices"])
    for an in j["animations"]:
        for sm in an["samplers"]:
            sm["input"] = copy(sm["input"])
            sm["output"] = copy(sm["output"])

    pos, nrm, uvs, jts, wts, idx = mesh
    prim = {
        "attributes": {
            "POSITION": b.accessor(pos, 5126, "VEC3", 34962, minmax=True),
            "NORMAL": b.accessor(nrm, 5126, "VEC3", 34962),
            "TEXCOORD_0": b.accessor(uvs, 5126, "VEC2", 34962),
            "JOINTS_0": b.accessor(jts, 5121, "VEC4", 34962),
            "WEIGHTS_0": b.accessor(wts, 5126, "VEC4", 34962),
        },
        "indices": b.accessor(idx, 5123, "SCALAR", 34963),
        "material": 0,
    }
    j["meshes"] = [{"name": path.stem, "primitives": [prim]}]
    material(j, b, png)
    path.write_bytes(b.glb(j))


# -- the rig

class Rig:
    def __init__(self, glb):
        self.g = glb
        j = glb.json
        self.skin = j["skins"][0]
        self.joint_nodes = self.skin["joints"]
        self.names = [j["nodes"][n].get("name") for n in self.joint_nodes]
        prim = j["meshes"][0]["primitives"][0]
        a = prim["attributes"]
        self.pos = glb.read(a["POSITION"])
        self.nrm = glb.read(a["NORMAL"])
        self.jts = glb.read(a["JOINTS_0"])
        self.wts = glb.read(a["WEIGHTS_0"])
        idx = [i[0] for i in glb.read(prim["indices"])]
        self.tris = [tuple(idx[k:k + 3]) for k in range(0, len(idx), 3)]
        ibms = glb.read(self.skin["inverseBindMatrices"])
        self.rest = {}
        for i, name in enumerate(self.names):
            m = ibms[i]
            cols, t = [m[0:3], m[4:7], m[8:11]], m[12:15]
            self.rest[name] = tuple(-sum(cols[r][k] * t[k] for k in range(3)) for r in range(3))

    def bone_of(self, v):
        """The bone vertex `v` follows most."""
        k = max(range(4), key=lambda k: self.wts[v][k])
        return self.names[self.jts[v][k]]

    def translation(self, name):
        n = self.g.json["nodes"][self.joint_nodes[self.names.index(name)]]
        return tuple(n.get("translation", (0, 0, 0)))

    def piece(self, keep, push, flare=0.0):
        """The triangles all of whose vertices `keep` holds, as a mesh pushed
        `push` out along the normals (and `flare` more the lower it is, for
        skirts). Vertices keep their joints and weights."""
        tris = [t for t in self.tris if all(keep(v) for v in t)]
        used = sorted({v for t in tris for v in t})
        new = {v: i for i, v in enumerate(used)}
        hip = self.rest["root"][2] + 0.35
        pos = []
        for v in used:
            p, n = self.pos[v], self.nrm[v]
            d = push + max(0.0, hip - p[2]) * flare
            pos.append((p[0] + n[0] * d, p[1] + n[1] * d, p[2] + n[2] * d))
        nrm = [self.nrm[v] for v in used]
        uvs = [(0.5, 0.5)] * len(used)
        jts = [self.jts[v] for v in used]
        wts = [self.wts[v] for v in used]
        idx = [new[v] for t in tris for v in t]
        return pos, nrm, uvs, jts, wts, idx


# -- rigid shapes, built about the head bone (origin) in its rest frame

def ellipsoid(cx, cy, cz, rx, ry, rz, rings=8, segs=12, keep=None):
    """A UV ellipsoid; `keep(centre)` -> False drops a quad (for hair and caps)."""
    pos, uvs, idx = [], [], []
    for i in range(rings + 1):
        th = math.pi * i / rings
        for k in range(segs + 1):
            ph = 2 * math.pi * k / segs
            x = cx + rx * math.sin(th) * math.cos(ph)
            y = cy + ry * math.sin(th) * math.sin(ph)
            z = cz + rz * math.cos(th)
            pos.append((x, y, z))
            uvs.append((k / segs, i / rings))
    for i in range(rings):
        for k in range(segs):
            a = i * (segs + 1) + k
            b = a + segs + 1
            if keep:
                quad = [pos[a], pos[b], pos[a + 1], pos[b + 1]]
                centre = tuple(sum(p[c] for p in quad) / 4 for c in range(3))
                if not keep(centre):
                    continue
            idx += [a, b, a + 1, a + 1, b, b + 1]
    return pos, uvs, idx


def cuboid(cx, cy, z0, hx, hy, h, taper=1.0):
    """A box from z0 up h, narrowing by `taper` at the top, all faces outward."""
    tx, ty = hx * taper, hy * taper
    c = [(cx - hx, cy - hy, z0), (cx + hx, cy - hy, z0), (cx + hx, cy + hy, z0), (cx - hx, cy + hy, z0),
         (cx - tx, cy - ty, z0 + h), (cx + tx, cy - ty, z0 + h), (cx + tx, cy + ty, z0 + h), (cx - tx, cy + ty, z0 + h)]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    pos, uvs, idx = [], [], []
    for f in faces:
        base = len(pos)
        for q, uv in zip(f, [(0, 1), (1, 1), (1, 0), (0, 0)]):
            pos.append(c[q])
            uvs.append(uv)
        idx += [base, base + 1, base + 2, base, base + 2, base + 3]
    return pos, uvs, idx


def join(*parts):
    pos, uvs, idx = [], [], []
    for p, u, i in parts:
        base = len(pos)
        pos += p
        uvs += u
        idx += [base + x for x in i]
    return pos, uvs, idx


# Heads: (mesh, where the face goes: front x, centre z, half width, half
# height, and the crown: how high the top of it is). Hair and hats are made
# for the round head's crown and moved up or down to each head's.
def heads():
    out = {}
    out["round"] = (ellipsoid(0.0, 0.0, 0.25, 0.25, 0.27, 0.26), (0.245, 0.24, 0.2, 0.2, 0.51))
    out["square"] = (cuboid(0.0, 0.0, 0.0, 0.23, 0.25, 0.48), (0.232, 0.23, 0.21, 0.2, 0.48))
    out["long"] = (ellipsoid(0.0, 0.0, 0.31, 0.22, 0.22, 0.34), (0.212, 0.29, 0.17, 0.25, 0.65))
    out["bean"] = (ellipsoid(0.0, 0.0, 0.22, 0.25, 0.32, 0.22), (0.244, 0.21, 0.24, 0.16, 0.44))
    return out


CROWN = 0.51  # the round head's, which hair and hats are made for
FRINGE = 0.42  # in front, hair stops here: above the brows


def scalp(down_back, out=0.025):
    """Hair over the round head: down to `down_back` behind, to the fringe in front."""
    def keep(c):
        x, _, z = c
        if x > 0.08:
            return z > FRINGE
        return z > down_back
    return ellipsoid(-0.005, 0.0, 0.25, 0.25 + out, 0.27 + out, 0.26 + out, keep=keep)


def hair():
    out = {}
    out["short"] = scalp(0.3)
    out["tuft"] = join(scalp(0.3), cuboid(0.06, 0.0, CROWN - 0.04, 0.05, 0.04, 0.16, taper=0.2))
    out["bob"] = join(scalp(0.05, out=0.04), cuboid(-0.13, 0.0, 0.02, 0.15, 0.3, 0.32))
    out["spikes"] = join(scalp(0.3), *[
        cuboid(0.1 * math.cos(a) - 0.03, 0.14 * math.sin(a), CROWN - 0.1, 0.05, 0.05, 0.2, taper=0.1)
        for a in [k * math.pi / 3 for k in range(6)]])
    out["long"] = join(scalp(0.0, out=0.035), cuboid(-0.17, 0.0, -0.32, 0.11, 0.28, 0.62))
    return out


def hats():
    def brim_cap(c):
        return c[2] > 0.36
    out = {}
    out["cap"] = join(ellipsoid(-0.01, 0.0, 0.26, 0.28, 0.3, 0.28, keep=brim_cap),
                      cuboid(0.22, 0.0, 0.36, 0.14, 0.2, 0.02))
    out["beanie"] = join(ellipsoid(-0.01, 0.0, 0.27, 0.3, 0.32, 0.3, keep=lambda c: c[2] > FRINGE - 0.02),
                         ellipsoid(-0.01, 0.0, CROWN + 0.1, 0.05, 0.05, 0.05))
    out["tophat"] = join(cuboid(0.0, 0.0, CROWN - 0.06, 0.34, 0.34, 0.02),
                         cuboid(0.0, 0.0, CROWN - 0.04, 0.2, 0.2, 0.36))
    return out


# -- face sprites: white shapes on clear, 32px

def sprite(draw):
    im = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    draw(ImageDraw.Draw(im))
    return im


def face_parts():
    W = WHITE
    eyes = [
        lambda d: d.ellipse((10, 9, 22, 23), fill=W),                                    # round
        lambda d: d.ellipse((8, 12, 24, 20), fill=W),                                    # wide
        lambda d: d.rectangle((13, 8, 19, 24), fill=W),                                  # bar
        lambda d: d.arc((7, 10, 25, 26), 200, 340, fill=W, width=4),                     # happy
        lambda d: [d.ellipse((9, 9, 23, 23), fill=W), d.ellipse((13, 13, 19, 19), fill=(0, 0, 0, 0))],  # ring
        lambda d: d.line((8, 16, 24, 16), fill=W, width=4),                              # closed
    ]
    brows = [
        lambda d: d.rectangle((6, 14, 26, 18), fill=W),
        lambda d: d.line((6, 19, 26, 13), fill=W, width=4),
        lambda d: d.arc((6, 12, 26, 28), 200, 340, fill=W, width=4),
        lambda d: d.polygon([(6, 18), (16, 12), (26, 18), (26, 20), (16, 15), (6, 20)], fill=W),
    ]
    mouths = [
        lambda d: d.arc((6, 2, 26, 22), 20, 160, fill=W, width=3),                       # smile
        lambda d: d.line((8, 16, 24, 16), fill=W, width=3),                              # flat
        lambda d: d.ellipse((11, 10, 21, 22), fill=W),                                   # o
        lambda d: d.chord((6, 4, 26, 24), 0, 180, fill=W),                               # grin
        lambda d: d.arc((6, 12, 26, 32), 200, 340, fill=W, width=3),                     # frown
        lambda d: d.polygon([(8, 14), (12, 18), (16, 14), (20, 18), (24, 14)], outline=W, width=2),  # wavy
    ]
    noses = [
        lambda d: d.ellipse((12, 12, 20, 20), fill=W),
        lambda d: d.polygon([(16, 8), (21, 22), (11, 22)], fill=W),
        lambda d: d.line((16, 8, 14, 22), fill=W, width=3),
        lambda d: [d.ellipse((10, 15, 14, 19), fill=W), d.ellipse((18, 15, 22, 19), fill=W)],
    ]
    cheeks = [
        lambda d: d.ellipse((4, 9, 28, 23), fill=W),
        lambda d: [d.line((6, 12, 12, 20), fill=W, width=2), d.line((13, 12, 19, 20), fill=W, width=2),
                   d.line((20, 12, 26, 20), fill=W, width=2)],
    ]
    marks = [
        lambda d: [d.ellipse((8, 10, 12, 14), fill=W), d.ellipse((16, 16, 20, 20), fill=W), d.ellipse((22, 9, 26, 13), fill=W)],  # freckles
        lambda d: d.polygon([(16, 4), (19, 13), (28, 13), (21, 19), (24, 28), (16, 22), (8, 28), (11, 19), (4, 13), (13, 13)], fill=W),  # star
        lambda d: d.polygon([(16, 26), (5, 14), (9, 7), (16, 12), (23, 7), (27, 14)], fill=W),  # heart
        lambda d: d.line((8, 8, 24, 24), fill=W, width=3),                               # scar
    ]
    return {"eye": eyes, "brow": brows, "mouth": mouths, "nose": noses, "cheek": cheeks, "mark": marks}


def quad():
    """One unit square facing +X, centred on the origin."""
    h = 0.5
    pos = [(0.0, -h, -h), (0.0, h, -h), (0.0, h, h), (0.0, -h, h)]
    # the viewer's left is -y: the image's left edge there
    uvs = [(0, 1), (1, 1), (1, 0), (0, 0)]
    return pos, uvs, [0, 1, 2, 0, 2, 3]


def build(glb_class, assets, scripts):
    rig = Rig(glb_class(assets / "player.glb"))
    white = png_bytes(plain())
    head_bone = rig.rest["head"]

    # the body without its head (whatever follows the head bone)
    body = rig.piece(lambda v: rig.bone_of(v) != "head", 0.0)
    skinned_glb(assets / "body.glb", rig.g, body, white)

    for name, (bones, push) in CLOTHES.items():
        mesh = rig.piece(lambda v, b=bones: rig.bone_of(v) in b, push, flare=0.25 if name == "skirt" else 0.0)
        skinned_glb(assets / f"cl_{name}.glb", rig.g, mesh, white)

    fronts = {}
    for name, ((pos, uvs, idx), front) in heads().items():
        static_glb(assets / f"head_{name}.glb", pos, uvs, idx, white)
        fronts[name] = front
    for name, (pos, uvs, idx) in hair().items():
        static_glb(assets / f"hair_{name}.glb", pos, uvs, idx, white)
    for name, (pos, uvs, idx) in hats().items():
        static_glb(assets / f"hat_{name}.glb", pos, uvs, idx, white)

    pos, uvs, idx = quad()
    counts = {}
    for part, shapes in face_parts().items():
        counts[part] = len(shapes)
        for i, draw in enumerate(shapes):
            static_glb(assets / f"fp_{part}{i}.glb", pos, uvs, idx, png_bytes(sprite(draw)))

    lua = ["-- character_rig — generated by tools/gen_character.py; don't edit.",
           "-- Where things are on the player rig, for character.lua.", "",
           "RIG = {}",
           "-- each head: where its face goes, from the head bone: front x, centre z,",
           "-- half width, half height; then how far its crown is above the round",
           "-- head's, which hair and hats are made for",
           "RIG.faces = {"]
    for name, (fx, fz, hw, hh, crown) in fronts.items():
        lua.append(f"\t{name} = {{ {fx}, {fz}, {hw}, {hh}, {crown - CROWN:.3f} }},")
    lua += ["}", "-- how many shapes each face part has", "RIG.parts = {"]
    for part, n in counts.items():
        lua.append(f"\t{part} = {n},")
    lua += ["}", "-- bones stretched with height, and their rest translations", "RIG.stretch = {"]
    for name in STRETCH:
        t = rig.translation(name)
        lua.append(f'\t["{name}"] = {{ {t[0]:.4f}, {t[1]:.4f}, {t[2]:.4f} }},')
    hip, foot = rig.rest["calf.l"][2], rig.rest["foot.l"][2]
    lua += ["}",
            "-- how far the feet drop per unit of stretch, so the body is lifted that much",
            f"RIG.leg_drop = {hip - foot:.4f}",
            f"RIG.head_z = {head_bone[2]:.4f}", ""]
    (scripts / "character_rig.lua").write_text("\n".join(lua))
