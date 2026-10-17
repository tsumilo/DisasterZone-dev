"""Azeromon water that reflects (0.46, the fidelity mockup's section 3).

For every baked outdoor map with open water: what stands near a shore (the over tiles, the canopy, the forest past
the map's edge) mirrored into the water. Each column is mirrored about its own shore, so something further back
from the water shows further out, as on a real lake; the picture fades with distance, takes on the water's colour
and covers only open water. The game draws it as one-pixel rows that ripple (Water.lua), kept to the water by the
map's water mask, and mirrors the people standing at a shore or wading.

Writes addon/DisasterZone_Azeromon/Media/Water/<map>_r.tga (the reflection, cropped to where it shows) and
<map>_m.tga (the water's shape at a quarter of the size, for a MaskTexture), and WaterArt.lua.
Run after gen_azeromon_ground.py: luaenv\\Scripts\\python.exe generators\\gen_azeromon_water.py
"""
import hashlib
import json
import os
import re
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(DEV, "tests", "boot-ui"))
PACK = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone_Azeromon")
MEDIA = os.path.join(PACK, "Media")
GROUND = os.path.join(MEDIA, "Ground")
OUT = os.path.join(MEDIA, "Water")
LUA = os.path.join(PACK, "WaterArt.lua")
ASSET = 17
REACH = 72                  # how far below its shore a thing still shows (picture pixels)
MASK_SCALE = 4

LOAD = """local out = {}
for id, g in pairs(ns.AzeroGround) do
  local def = ns.AzeroMaps[id]
  if def and def.outdoor and not g.indoor and not g.hall and def.rows then
    local m = ns.Azero.Compile(id)
    local over, top = {}, {}
    for y = 0, m.h - 1 do for x = 0, m.w - 1 do
      local k = m.key(x, y)
      over[#over + 1] = (type(m.over[k]) == 'string' and m.over[k]) or ''
      top[#top + 1] = (m.top and type(m.top[k]) == 'string' and m.top[k]) or ''
    end end
    local rows = {}
    for i, r in ipairs(def.rows) do rows[i] = r end
    out[id] = { w = m.w, h = m.h, mx = g.mx, my = g.my, v = g.v, chunks = g.chunks, over = over, top = top,
                rows = rows, tree = m.theme.tree }
  end
end
return out"""


def load_maps():
    from _common import solo
    _, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame()")
    return c.eval_py(LOAD)


def atlas():
    img = Image.open(os.path.join(MEDIA, "atlas.tga")).convert("RGBA")
    names = dict((m.group(1), int(m.group(2))) for m in
                 re.finditer(r"^\s+(\w+) = (\d+),", open(os.path.join(PACK, "Atlas.lua")).read(), re.M))
    cache = {}

    def tile(name):
        if name not in cache:
            i = names.get(name)
            cache[name] = None if i is None else np.array(
                img.crop(((i % 16) * 16, (i // 16) * 16, (i % 16) * 16 + 16, (i // 16) * 16 + 16)))
        return cache[name]
    return tile


def picture(mid, m):
    W, H = (m["w"] + 2 * m["mx"]) * 16, (m["h"] + 2 * m["my"]) * 16
    pic = np.zeros((H, W, 3), dtype=np.uint8)
    for x0, y0, cw, ch, tw, th in m["chunks"]:
        im = np.array(Image.open(os.path.join(GROUND, "%s_%d_%d.tga" % (mid, x0 // 256, y0 // 256))).convert("RGB"))
        pic[y0:y0 + ch, x0:x0 + cw] = im[:ch, :cw]
    return pic


def objects(m, tile):
    """what stands on the ground: over tiles, the canopy, the margin's forest (as UI.lua draws them)"""
    mx, my = m["mx"], m["my"]
    W, H = (m["w"] + 2 * mx) * 16, (m["h"] + 2 * my) * 16
    obj = np.zeros((H, W, 4), dtype=np.uint8)

    def put(t, px, py):
        if t is None:
            return
        a = t[..., 3:4].astype(float) / 255
        dst = obj[py:py + 16, px:px + 16].astype(float)
        dst[..., :3] = dst[..., :3] * (1 - a) + t[..., :3] * a
        dst[..., 3:4] = np.maximum(dst[..., 3:4], t[..., 3:4])
        obj[py:py + 16, px:px + 16] = dst.astype(np.uint8)
    for wy in range(-my, m["h"] + my):
        for wx in range(-mx, m["w"] + mx):
            if 0 <= wx < m["w"] and 0 <= wy < m["h"]:
                o = m["over"][wy * m["w"] + wx]
                if o:
                    put(tile(o), (wx + mx) * 16, (wy + my) * 16)
            else:
                cx, cy = max(0, min(m["w"] - 1, wx)), max(0, min(m["h"] - 1, wy))
                if m["rows"][cy][cx] not in "=w":
                    put(tile(m["tree"]), (wx + mx) * 16, (wy + my) * 16)
    for wy in range(m["h"]):
        for wx in range(m["w"]):
            o = m["top"][wy * m["w"] + wx]
            if o:
                put(tile(o), (wx + mx) * 16, (wy + my) * 16)
    return obj


def water_mask(pic, m):
    """open water: blue-dominant pixels within a tile of the map's water ('w') cells"""
    mx, my = m["mx"], m["my"]
    H, W = pic.shape[:2]
    cells = np.zeros((H // 16, W // 16), dtype=bool)
    for y, row in enumerate(m["rows"]):
        for x, ch in enumerate(row):
            if ch == "w":
                cells[y + my, x + mx] = True
    if not cells.any():
        return None
    near = np.kron(_grow(cells), np.ones((16, 16), dtype=bool))[:H, :W]
    p = pic.astype(int)
    blue = (p[..., 2] > p[..., 0] + 35) & (p[..., 2] > p[..., 1] + 4)
    m_ = _grow(_shrink(_shrink(_grow(_grow(blue & near)))))          # close twice (pinholes: glints, foam), open once
    m_ = _grow(_shrink(m_))
    return m_ if m_.sum() > 64 else None


def _grow(a):
    """3 x 3 binary dilation"""
    p = np.pad(a, 1)
    out = np.zeros_like(a)
    for dy in (0, 1, 2):
        for dx in (0, 1, 2):
            out |= p[dy:dy + a.shape[0], dx:dx + a.shape[1]]
    return out


def _shrink(a):
    """3 x 3 binary erosion"""
    p = np.pad(a, 1, constant_values=True)
    out = np.ones_like(a)
    for dy in (0, 1, 2):
        for dx in (0, 1, 2):
            out &= p[dy:dy + a.shape[0], dx:dx + a.shape[1]]
    return out


def reflect(pic, obj, mask):
    H, W = mask.shape
    col = pic[mask].mean(0)
    out = np.zeros((H, W, 4), dtype=np.uint8)
    for x in range(W):
        start, land0, last = -1, 0, -1       # this run of water's first row; the land above it starts at land0
        colm = mask[:, x]
        for y in range(H):
            if not colm[y]:
                if start >= 0:
                    last = y - 1
                start = -1
                continue
            if start < 0:
                start = y
                land0 = last + 1             # (only the land between this water and the water above it shows)
            dist = y - start
            if dist >= REACH:
                continue
            sy = start - 1 - dist
            if sy < land0:
                continue
            o = obj[sy, x]
            if o[3] < 40:
                continue
            a = (o[3] / 255) * (0.82 - 0.35 * dist / REACH)
            c = o[:3].astype(float) * 0.7 + col * 0.3
            out[y, x, :3] = np.clip(c * np.array([0.9, 0.9, 0.94]), 0, 255).astype(np.uint8)
            out[y, x, 3] = int(a * 255)
    return out, col


def pot(n):
    p = 16
    while p < n:
        p *= 2
    return p


def digest():
    h = hashlib.sha1()
    for p in (__file__, os.path.join(MEDIA, "atlas.tga")):
        h.update(open(p, "rb").read().replace(b"\r\n", b"\n"))
    return h.hexdigest()[:16]


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".tga"):
            os.remove(os.path.join(OUT, f))
    tile = atlas()
    maps = load_maps()
    entries = {}
    src = digest()
    for mid in sorted(maps):
        m = maps[mid]
        pic = picture(mid, m)
        mask = water_mask(pic, m)
        if mask is None:
            continue
        obj = objects(m, tile)
        refl, col = reflect(pic, obj, mask)
        ys, xs = np.nonzero(refl[..., 3])
        if len(ys) == 0:
            continue
        x0, x1, y0, y1 = int(xs.min()), int(xs.max()) + 1, int(ys.min()), int(ys.max()) + 1
        crop = refl[y0:y1, x0:x1]
        tw, th = pot(x1 - x0), pot(y1 - y0)
        tex = np.zeros((th, tw, 4), dtype=np.uint8)
        tex[:y1 - y0, :x1 - x0] = crop
        Image.fromarray(tex, "RGBA").save(os.path.join(OUT, "%s_r.tga" % mid))
        H, W = mask.shape
        mh, mw = (H + MASK_SCALE - 1) // MASK_SCALE, (W + MASK_SCALE - 1) // MASK_SCALE
        small = np.zeros((mh * MASK_SCALE, mw * MASK_SCALE), dtype=float)
        small[:H, :W] = mask
        small = small.reshape(mh, MASK_SCALE, mw, MASK_SCALE).mean(axis=(1, 3))
        mtw, mth = pot(mw), pot(mh)
        mtex = np.zeros((mth, mtw, 4), dtype=np.uint8)
        mtex[..., :3] = 255
        mtex[:mh, :mw, 3] = (small * 255).astype(np.uint8)
        Image.fromarray(mtex, "RGBA").save(os.path.join(OUT, "%s_m.tga" % mid))
        entries[mid] = {"v": m["v"], "refl": (x0, y0, x1 - x0, y1 - y0, tw, th), "mask": (mtw, mth), "col": col}
        print("water", mid, "reflection", x1 - x0, "x", y1 - y0)
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/WaterArt.lua", ...) then return end '
        "-- DisasterZone_Azeromon/WaterArt.lua  (GENERATED by dev/generators/gen_azeromon_water.py - do not edit)",
        "-- Water that reflects (Water.lua): per map, refl = { x, y, w, h, tw, th } where Media/Water/<map>_r.tga sits in",
        "-- the baked picture (picture pixels), mask = { tw, th } of <map>_m.tga (the water at 1/%d size, from the" % MASK_SCALE,
        "-- picture's top left), col = the water's colour; v = the baked ground it was made from (Ground.lua).",
        "local addonName, ns = ...",
        "ns.AzeroWaterArt = {",
        '    asset = %d, src = "%s", maskScale = %d,' % (ASSET, src, MASK_SCALE),
        "    maps = {",
    ]
    for mid, e in sorted(entries.items()):
        lines.append('        %s = { v = "%s", refl = { %d, %d, %d, %d, %d, %d }, mask = { %d, %d }, col = { %.3f, %.3f, %.3f } },' % (
            (mid, e["v"]) + tuple(e["refl"]) + tuple(e["mask"]) + tuple(c / 255 for c in e["col"])))
    lines += ["    },", "}"]
    with open(LUA, "w", newline="\n", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote WaterArt.lua", len(entries), "maps")


if __name__ == "__main__":
    main()
