"""Bakes each outdoor Azeromon map's ground into images (the world art pass, 2026-10-14; look mockup in
dev/art/casc/azeromon_looks).

Everything that never moves and lies under the sprites goes into one picture per map: grass with large light and
dark patches, worn paths with soft edges, round shores, meadows with ragged edges, the forest floor under the trees,
a darker tree tucked between neighbouring trees (the forest wall), troll ruin walls joined to their neighbours,
flowers / pebbles / reeds, and the shadow of every static sprite (3 px right, 2 px down, 30% black). The game draws
the picture under the over tiles (trees, houses, props) and the people, and moves it with the camera.

The picture is cut into chunks of at most 256 x 256 px (power-of-two textures, 24-bit TGA), so the camera's view
(11 x 9 tiles) never needs more than four of them.

Outputs:
  addon/DisasterZone/Media/Azeromon/Ground/<map>_<cx>_<cy>.tga
  addon/DisasterZone/Games/Azeromon/Ground.lua   ns.AzeroGround[map] = { v = <inputs hash>, chunks = { {x, y, w, h, tw, th}, ... } }

The maths (hash, value noise, masks) matches the mockup's JavaScript, so the game looks like the mockup.
Run: luaenv\\Scripts\\python.exe generators\\gen_azeromon_ground.py [map ...]     (default: GROUND_THEMES' maps)
"""
import hashlib
import json
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(DEV, "tests", "boot-ui"))
import azeromon_props  # noqa: E402
import azeromon_interiors as interiors  # noqa: E402

ADDON = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone")
MEDIA = os.path.join(ADDON, "Media", "Azeromon")
OUT_DIR = os.path.join(MEDIA, "Ground")
GROUND_LUA = os.path.join(ADDON, "Games", "Azeromon", "Ground.lua")
VERSION = 3                      # bump when the look changes without an input change
CHUNK = 256
SHADE = 0.74                     # forest floor (gen_azeromon_art.SHADE: the atlas' *_shade tiles match)

# small props that stand on a pool of shadow (their foot) instead of casting a silhouette
FEET = {"sign", "wantedboard", "lamppost", "anvil", "forge", "alchemy", "chest", "mailbox_0_1", "totem_0_1",
        "scarecrow_0_1", "gravestone", "crate", "barrel", "pumpkin", "hay", "cannon", "plinth", "plinthempty",
        "trophyboard"}

# the margin baked round each map (tiles): the camera sees up to HX + 1, HY + 1 tiles past an edge (UI.lua HX = 5,
# HY = 4). Past the edge the map goes on: a road or water at the edge carries straight on, the rest is forest.
MX, MY = 6, 5

# lights for dusk and night: over tile -> (x, y, radius in px, flickers) (the mockup's LIGHT_TILES)
LIGHT_TILES = {"lamppost": (8, 3, 30, 0), "forge": (8, 9, 34, 1), "torch1": (8, 4, 26, 1), "fire1": (8, 8, 30, 1),
               "chandelier": (8, 8, 34, 1)}
NIGHT = {"dusk": (238, 188, 156), "night": (100, 112, 172)}     # the darkness colour (multiplied over the world)
WARM = (255, 226, 176)
LIGHT_SCALE = 2                                                # light maps are stored at half resolution

# which map themes get a baked ground (more zones are added as they are checked in game)
GROUND_THEMES = ("elwynn",)

# ------------------------------------------------------------------------------------------- noise (as the mockup)

M32 = np.uint32(0xFFFFFFFF)


def _u32(a):
    return (np.asarray(a, dtype=np.int64) & 0xFFFFFFFF).astype(np.uint32)


def hash_(x, y, s):
    """the mockup's hash(x, y, s) -> [0, 1), on arrays (32-bit wrapping like Math.imul)"""
    with np.errstate(over="ignore"):
        h = _u32(x) * np.uint32(374761393) + _u32(y) * np.uint32(668265263) + _u32(np.asarray(s) + 1) * np.uint32(1442695041)
        h = (h ^ (h >> np.uint32(13))) * np.uint32(1274126177)
        h = h ^ (h >> np.uint32(16))
    return h.astype(np.float64) / 4294967296.0


def sm(t):
    return t * t * (3 - 2 * t)


def vnoise(x, y, s):
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)
    x0, y0 = np.floor(x), np.floor(y)
    fx, fy = sm(x - x0), sm(y - y0)
    x0, y0 = x0.astype(np.int64), y0.astype(np.int64)
    a, b = hash_(x0, y0, s), hash_(x0 + 1, y0, s)
    c, d = hash_(x0, y0 + 1, s), hash_(x0 + 1, y0 + 1, s)
    top = a + (b - a) * fx
    return top + ((c + (d - c) * fx) - top) * fy


def fbm(x, y, s):
    return 0.6 * vnoise(x, y, s) + 0.3 * vnoise(x * 2.1, y * 2.1, s + 7) + 0.1 * vnoise(x * 4.3, y * 4.3, s + 13)


BAYER = np.array([0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5], dtype=np.float64).reshape(4, 4) / 16


# ------------------------------------------------------------------------------------------- themes and decor

THEMES = {
    "elwynn": dict(g1="grass1", g2="grass2", tall="tall_", path="path_", tree="tree",
                   water=dict(out=(38, 66, 100), foam=(214, 238, 240), light=(124, 186, 228), mid=(88, 150, 212), deep=(66, 120, 196)),
                   decor=dict(flowers=["daisy", "butter", "pinkf", "daisy"], edge=["tuft", "pebble", "tuft", "pebble2"],
                              tree=["shroom", "tuft"], bank=["reeds", "pebble"])),
    "duskwood": dict(g1="dgrass1", g2="dgrass2", tall="dtall_", path="dpath_", tree="dtree", sparse=True,
                     water=dict(out=(22, 30, 48), foam=(150, 168, 190), light=(72, 98, 132), mid=(54, 76, 110), deep=(40, 58, 90)),
                     decor=dict(flowers=["leaves", "glowshroom", "leaves"], edge=["tuft", "pebble", "leaves", "bones"],
                                tree=["glowshroom", "leaves"], bank=["reeds", "pebble"])),
    "jungle": dict(g1="jgrass1", g2="jgrass2", tall="jtall_", path="jpath_", tree="jtree",
                   water=dict(out=(20, 58, 66), foam=(204, 242, 230), light=(84, 184, 192), mid=(50, 150, 170), deep=(34, 118, 148)),
                   decor=dict(flowers=["redflower", "fern", "fern"], edge=["fern", "pebble", "tuft"],
                              tree=["fern", "shroom"], bank=["reeds", "fern"])),
}

# hand-placed decor; "a"/"b" = the ground's own dark/light green
SPR = {
    "daisy": ({"w": (250, 248, 232), "y": (240, 196, 64), "s": "a"}, ["..w....", ".wyw.w.", "..w.wyw", "..s..w.", "..s..s."]),
    "butter": ({"y": (246, 214, 70), "o": (214, 150, 40), "s": "a"}, [".y...", "yoy.y", ".y.yo", ".s..y", ".s..s"]),
    "pinkf": ({"p": (236, 128, 170), "c": (255, 230, 120), "s": "a"}, ["p.p..", ".c..p", "p.ppc", ".s..p", ".s..s"]),
    "pebble": ({"l": (206, 202, 188), "m": (150, 146, 136), "d": (88, 86, 80)}, ["..lm.", ".lmmd", "..dd."]),
    "pebble2": ({"l": (196, 190, 176), "m": (140, 134, 124), "d": (84, 80, 74)}, ["lm...", "md.lm", "...md"]),
    "shroom": ({"R": (204, 56, 44), "w": (252, 244, 230), "s": (232, 222, 196), "d": "a"}, [".RR.", "RwRR", ".ss.", "dssd"]),
    "tuft": ({"a": "a", "b": "b"}, ["a.a..", ".a.ab", "ab.a.", ".aaa."]),
    "reeds": ({"b": (116, 72, 40), "g": (52, 104, 52), "G": (76, 136, 64)}, ["..b..", "b.g..", "g.G.b", "g.g.g", ".gGg."]),
    "leaves": ({"o": (196, 116, 52), "b": (128, 74, 40), "r": (168, 64, 42)}, ["o..b.", ".oo.r", "b.o..", "..r.o"]),
    "glowshroom": ({"P": (150, 92, 204), "L": (222, 196, 255), "s": (196, 186, 210), "d": "a"}, [".PP.", "PLPP", ".ss.", "dssd"]),
    "bones": ({"w": (226, 220, 204), "d": (120, 116, 108)}, ["w...w", ".wdw.", "w...w"]),
    "fern": ({"f": (38, 110, 52), "F": (72, 158, 64)}, ["f.....f", ".f.F.f.", "..fFf..", ".FfFfF.", "...f..."]),
    "redflower": ({"r": (214, 48, 60), "y": (252, 214, 90), "s": (40, 100, 46)}, [".r...", "ryr.r", ".r.ry", ".s..r", ".s..s"]),
}


# ------------------------------------------------------------------------------------------- atlas

class Atlas:
    def __init__(self):
        import re
        self.img = np.array(Image.open(os.path.join(MEDIA, "atlas.tga")).convert("RGBA"), dtype=np.float64)
        src = open(os.path.join(ADDON, "Games", "Azeromon", "Atlas.lua"), encoding="utf-8").read()
        self.index = {m.group(1): int(m.group(2)) for m in re.finditer(r"^\s+(\w+) = (\d+),", src, re.M)}

    def tile(self, name):
        i = self.index.get(name)
        if i is None:
            return None
        c, r = i % 16, i // 16
        return self.img[r * 16:r * 16 + 16, c * 16:c * 16 + 16]

    def avg(self, name):
        t = self.tile(name)
        m = t[..., 3] > 128
        return t[..., :3][m].mean(0) if m.any() else np.array([128.0, 128, 128])

    def darkest(self, name):
        t = self.tile(name)
        m = t[..., 3] > 128
        px = t[..., :3][m]
        return px[px.sum(1).argmin()]


def blit(dst, src, x, y):
    """alpha-composite src (h, w, 4 floats 0..255) onto dst (H, W, 3) at x, y (clipped)"""
    H, W = dst.shape[:2]
    h, w = src.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x0 >= x1 or y0 >= y1:
        return
    s = src[y0 - y:y1 - y, x0 - x:x1 - x]
    a = s[..., 3:4] / 255.0
    dst[y0:y1, x0:x1] = dst[y0:y1, x0:x1] * (1 - a) + s[..., :3] * a


# ------------------------------------------------------------------------------------------- the bake

def bake(m, atlas, walls):
    """m: the compiled map (w, h, rows, base, over, stamps, chests, theme) -> (H, W, 3) uint8"""
    th = THEMES.get(m["theme"], THEMES["elwynn"])
    w, h = m["w"], m["h"]
    W, H = w * 16, h * 16
    rows = m["rows"]

    def T(x, y):
        if 0 <= y < h and 0 <= x < w:
            return rows[y][x]
        return None

    base = [[m["base"][y * w + x] for x in range(w)] for y in range(h)]
    over = [[m["over"][y * w + x] for x in range(w)] for y in range(h)]
    # tile classes: 0 ground, 1 path, 2 water, 3 tall, 4 fixed
    tcls = np.zeros((h, w), dtype=np.int8)
    for y in range(h):
        for x in range(w):
            ch, b = rows[y][x], base[y][x]
            tcls[y, x] = (0 if ch == "R" else 1 if ch == "=" else 2 if ch == "w" else 3 if ch in "\";" else
                          0 if b in (th["g1"], th["g2"]) else 4)
    img = np.zeros((H, W, 3))
    for y in range(h):
        for x in range(w):
            t = atlas.tile(th["g1"] if rows[y][x] == "R" else base[y][x])
            if t is not None:
                img[y * 16:y * 16 + 16, x * 16:x * 16 + 16] = t[..., :3]
    orig = img.copy()

    ys, xs = np.mgrid[0:H, 0:W]
    tx_, ty_ = xs >> 4, ys >> 4
    tc = tcls[ty_, tx_]

    def mask(c, amp, s):
        fx, fy = (xs + 0.5) / 16 - 0.5, (ys + 0.5) / 16 - 0.5
        x0, y0 = np.floor(fx).astype(np.int64), np.floor(fy).astype(np.int64)
        ax, ay = sm(fx - x0), sm(fy - y0)
        cl = lambda xx, yy: (tcls[np.clip(yy, 0, h - 1), np.clip(xx, 0, w - 1)] == c).astype(np.float64)
        a, b, cc, d = cl(x0, y0), cl(x0 + 1, y0), cl(x0, y0 + 1), cl(x0 + 1, y0 + 1)
        n = a + b + cc + d
        top = a + (b - a) * ax
        v = top + ((cc + (d - cc) * ax) - top) * ay
        v = v + (vnoise(xs / 4, ys / 4, s) - 0.5) * amp + (hash_(xs, ys, s) - 0.5) * amp * 0.25
        return np.where(n == 4, True, np.where(n == 0, False, v > 0.5))

    mw, mp, mt = mask(2, 0.16, 11), mask(1, 0.34, 21), mask(3, 0.55, 31)
    cls = np.where(tc == 4, 4, np.where(mw, 2, np.where(mp, 1, np.where(mt, 3, 0)))).astype(np.int8)

    # distance (4-way) to the nearest pixel of another class, capped at 12
    dist = np.full((H, W), 12, dtype=np.int16)
    edge = np.zeros((H, W), dtype=bool)
    edge[:, 1:] |= cls[:, 1:] != cls[:, :-1]
    edge[:, :-1] |= cls[:, :-1] != cls[:, 1:]
    edge[1:, :] |= cls[1:, :] != cls[:-1, :]
    edge[:-1, :] |= cls[:-1, :] != cls[1:, :]
    dist[edge] = 1
    d = dist.tolist()
    c_ = cls.tolist()
    for y in range(H):
        row, cr = d[y], c_[y]
        up, cu = (d[y - 1], c_[y - 1]) if y else (None, None)
        for x in range(W):
            v = row[x]
            if x and cr[x - 1] == cr[x] and row[x - 1] + 1 < v:
                v = row[x - 1] + 1
            if up is not None and cu[x] == cr[x] and up[x] + 1 < v:
                v = up[x] + 1
            row[x] = v
    for y in range(H - 1, -1, -1):
        row, cr = d[y], c_[y]
        dn, cd = (d[y + 1], c_[y + 1]) if y < H - 1 else (None, None)
        for x in range(W - 1, -1, -1):
            v = row[x]
            if x < W - 1 and cr[x + 1] == cr[x] and row[x + 1] + 1 < v:
                v = row[x + 1] + 1
            if dn is not None and cd[x] == cr[x] and dn[x] + 1 < v:
                v = dn[x] + 1
            row[x] = v
    dist = np.array(d, dtype=np.int16)

    def near(c, r):
        """pixels within Manhattan distance r of class c"""
        out = cls == c
        for _ in range(r):
            g = out.copy()
            g[1:, :] |= out[:-1, :]
            g[:-1, :] |= out[1:, :]
            g[:, 1:] |= out[:, :-1]
            g[:, :-1] |= out[:, 1:]
            out = g
        return out

    def tex(name):
        return np.tile(atlas.tile(name)[..., :3], (h, w, 1))

    g1, g2 = tex(th["g1"]), tex(th["g2"])
    pathC, tallC = atlas.tile(th["path"] + "c"), atlas.tile(th["tall"] + "c")
    tallT = np.tile(tallC[..., :3], (h, w, 1))
    pm = atlas.avg(th["path"] + "c")
    pl, pd, pr = pm + (255 - pm) * 0.2, pm * 0.8, pm * 0.6
    tdark = atlas.darkest(th["tall"] + "c") * 0.8
    gavg = atlas.avg(th["g1"])
    wp = {k: np.array(v, dtype=np.float64) for k, v in th["water"].items()}
    out = img.copy()

    # ground: grass (a tile of grass2 here and there), large light and dark patches, the forest floor
    useg2 = hash_(tx_, ty_, 9) < 0.16
    grass = np.where(useg2[..., None], g2, g1)
    fx, fy = (xs + 0.5) / 16 - 0.5, (ys + 0.5) / 16 - 0.5
    x0, y0 = np.floor(fx).astype(np.int64), np.floor(fy).astype(np.int64)
    isT = np.zeros((h + 2, w + 2))
    for y in range(-1, h + 1):
        for x in range(-1, w + 1):
            isT[y + 1, x + 1] = 1.0 if T(min(max(x, 0), w - 1), min(max(y, 0), h - 1)) == "T" else 0.0
    ax, ay = sm(fx - x0), sm(fy - y0)
    t_ = lambda xx, yy: isT[np.clip(yy, -1, h) + 1, np.clip(xx, -1, w) + 1]
    top = t_(x0, y0) + (t_(x0 + 1, y0) - t_(x0, y0)) * ax
    bot = t_(x0, y0 + 1) + (t_(x0 + 1, y0 + 1) - t_(x0, y0 + 1)) * ax
    forest = top + (bot - top) * ay + (BAYER[ys & 3, xs & 3] - 0.5) * 0.12
    pv = fbm(xs / 60, ys / 60, 3) + (BAYER[ys & 3, xs & 3] - 0.5) * 0.09
    col = grass.copy()
    patch_ok = forest <= 0.66                       # no patches under the trees: the shade matches the outer tiles
    dark = (pv < 0.4) & patch_ok
    light = (pv > 0.63) & patch_ok
    col[dark] = col[dark] * [0.84, 0.88, 0.9] + [0, 0, 4]
    col[light] = col[light] * [1.05, 1.04, 0.9] + [12, 7, 0]
    col[forest > 0.66] *= SHADE
    col[(forest > 0.36) & (forest <= 0.66)] *= 0.86
    gnd = cls == 0
    near_w2 = near(2, 2)
    near_p1 = near(1, 1)
    d3 = dist <= 3
    bank = gnd & d3 & near_w2
    col[bank & (dist == 1)] *= 0.6
    col[bank & (dist > 1)] *= 0.8
    rut = gnd & (dist == 1) & near_p1 & ~bank
    col[rut] *= 0.86
    above = np.zeros_like(gnd)
    above[1:] = cls[:-1] == 3
    above2 = np.zeros_like(gnd)
    above2[2:] = cls[:-2] == 3
    sh1 = gnd & d3 & above
    sh2 = gnd & d3 & above2 & ~above
    col[sh1] *= 0.72
    col[sh2] *= 0.86
    below = np.zeros_like(gnd)
    below[:-1] = cls[1:] == 3
    below2 = np.zeros_like(gnd)
    below2[:-2] = cls[2:] == 3
    colh = hash_(xs, 77, 5)
    tip1 = gnd & d3 & below & (colh < 0.5)
    tip2 = gnd & d3 & below2 & ~tip1 & (colh < 0.18)
    col[tip1] = tallT[tip1] * 0.9
    col[tip2] = tallT[tip2]
    out[gnd] = col[gnd]

    # paths: worn dirt, light worn patches, pebbles, a darker rim, grass growing over the edge
    pth = cls == 1
    n = vnoise(xs / 5, ys / 5, 41)
    pc = np.empty_like(out)
    pc[:] = pm
    pc[n > 0.7] = pl
    pc[n < 0.14] = pd
    hp = hash_(xs, ys, 43) < 0.022
    hs = hash_(xs - 1, ys - 1, 43) < 0.022
    hd = hash_(xs, ys, 44) < 0.05
    pc[hd] = pd
    pc[hs] = pr
    pc[hp] = pl
    pc[dist == 2] = pd
    pc[dist == 1] = pr
    blade = (dist <= 3) & (hash_(xs, ys >> 1, 45) < 0.16)
    pc[blade] = grass[blade] * [0.82, 0.86, 0.82]
    out[pth] = pc[pth]

    # water: outline, foam, shallow, mid, deep, with ripple streaks
    wat = cls == 2
    wc = np.empty_like(out)
    wc[:] = wp["deep"]
    wc[dist <= 8] = wp["mid"]
    wc[dist <= 4] = wp["light"]
    foam = (dist == 2) & (hash_(xs, ys, 51) < 0.7)
    wc[dist == 2] = wp["light"]
    wc[foam] = wp["foam"]
    wc[dist == 1] = wp["out"]
    rip = (dist > 4) & (vnoise(xs / 7, ys / 2.2, 53) > 0.74)
    wc[rip & (dist <= 8)] = wp["light"]
    wc[rip & (dist > 8)] = wp["mid"]
    out[wat] = wc[wat]

    # meadows: the tall grass texture with a dark rim and a shaded underside
    tal = cls == 3
    tcol = tallT.copy()
    b1 = np.ones_like(tal)
    b1[:-1] = cls[1:] == 3
    b2 = np.ones_like(tal)
    b2[:-2] = cls[2:] == 3
    under = ~(b1 & b2)
    tcol[under] *= 0.72
    tcol[dist == 1] = tdark
    out[tal] = tcol[tal]

    out = np.clip(out, 0, 255)

    # shadows of every static sprite: its silhouette, 3 px right and 2 px down, 30% black
    sil = np.zeros((H, W), dtype=bool)

    def stamp_sil(t, x, y):
        if t is None:
            return
        a = t[..., 3] > 0
        hh, ww = a.shape
        x0_, y0_, x1_, y1_ = max(0, x), max(0, y), min(W, x + ww), min(H, y + hh)
        if x0_ < x1_ and y0_ < y1_:
            sil[y0_:y1_, x0_:x1_] |= a[y0_ - y:y1_ - y, x0_ - x:x1_ - x]

    feet = []                                  # small props stand in a pool of shadow instead (below)
    for y in range(h):
        for x in range(w):
            o = over[y][x]
            if o and o in FEET:
                feet.append((x, y, atlas.tile(o)))
            elif o:
                stamp_sil(atlas.tile(o), x * 16 + 3, y * 16 + 2)
            if rows[y][x] == "R":
                stamp_sil(walls[wall_mask(T, x, y)], x * 16 + 3, y * 16 + 2)
    for c in m["chests"]:
        feet.append((c["x"], c["y"], atlas.tile("chest")))
    out[sil] = out[sil] * 0.7 + np.array([8, 18, 24]) * 0.3

    # small props: a soft oval of shadow under the foot (spilling past the tile), grass blades beside it
    gdark = atlas.avg(th["g1"]) * [0.62, 0.68, 0.62]
    for x, y, t in feet:
        a = t[..., 3] > 0
        rows_ = np.where(a.any(1))[0]
        if not len(rows_):
            continue
        by = rows_[-1]
        cols = np.where(a[by])[0]
        cx = x * 16 + (cols[0] + cols[-1]) / 2 + 0.5
        cy = y * 16 + by + 1
        rx = (cols[-1] - cols[0]) / 2 + 3.5
        for yy in range(int(cy) - 3, int(cy) + 3):
            for xx in range(int(cx - rx) - 1, int(cx + rx) + 2):
                if not (0 <= xx < W and 0 <= yy < H):
                    continue
                d = ((xx + 0.5 - cx) / rx) ** 2 + ((yy + 0.5 - cy) / 2.6) ** 2
                if d <= 1:
                    k = 0.62 if d < 0.45 else 0.8
                    out[yy, xx] = out[yy, xx] * k + np.array([8, 18, 24]) * (1 - k) * 0.5
        for bx in (cols[0] - 1, cols[-1] + 1, cols[0] - 2, cols[-1] + 2):
            gx = x * 16 + bx
            for dy in range(2 if bx in (cols[0] - 1, cols[-1] + 1) else 1):
                gy = y * 16 + by - dy
                if 0 <= gx < W and 0 <= gy < H and cls[gy, gx] == 0 and float(hash_(gx, gy, 81)) < 0.8:
                    out[gy, gx] = gdark

    # decor, clustered: flowers in fields, tufts and pebbles at edges, mushrooms by trees, reeds at the water
    occupied = {(n_["x"], n_["y"]) for n_ in m["npcs"]}
    used = np.zeros((H, W), dtype=bool)
    dA = gavg * [0.7, 0.74, 0.7]
    bA = gavg * [1.1, 1.08, 0.95] + [10, 8, 0]
    for cy in range(2, H - 6, 6):
        for cx in range(2, W - 8, 6):
            x = cx + int(hash_(cx, cy, 61) * 5)
            y = cy + int(hash_(cx, cy, 62) * 4)
            tx, ty = x >> 4, y >> 4
            if over[ty][tx] or (tx, ty) in occupied or rows[ty][tx] == "R" or cls[y, x] != 0:
                continue
            near_water = False
            for r in range(1, 10, 2):
                for dx, dy in ((r, 0), (-r, 0), (0, r), (0, -r)):
                    xx, yy = x + dx, y + dy
                    j = yy * W + xx
                    if 0 <= j < W * H and cls.flat[j] == 2:
                        near_water = True
            near_tree = any(T(tx + dx, ty + dy) == "T" for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)))
            field = float(fbm(np.array(x / 34), np.array(y / 34), 5))
            p, kind = 0.035, th["decor"]["edge"]
            if near_water:
                p, kind = 0.5, th["decor"]["bank"]
            elif field > 0.6:
                p, kind = 0.42, th["decor"]["flowers"]
            elif near_tree:
                p, kind = 0.2, th["decor"]["tree"]
            elif dist[y, x] <= 7:
                p = 0.16
            if th.get("sparse"):
                p *= 0.5
            if float(hash_(x, y, 63)) > p:
                continue
            name = kind[int(float(hash_(x, y, 64)) * len(kind))]
            pal, rws = SPR[name]
            ok = True
            for yy, rw in enumerate(rws):
                for xx, k in enumerate(rw):
                    if k == ".":
                        continue
                    if x + xx >= W or y + yy >= H or cls[y + yy, x + xx] != 0 or used[y + yy, x + xx]:
                        ok = False
                        break
                if not ok:
                    break
            if not ok:
                continue
            for yy, rw in enumerate(rws):
                for xx, k in enumerate(rw):
                    if k == ".":
                        continue
                    c = pal[k]
                    c = dA if c == "a" else bA if c == "b" else c
                    out[y + yy, x + xx] = [int(v) for v in c]
                    used[y + yy, x + xx] = True

    # the forest wall: a darker tree tucked between neighbouring trees, behind them
    tree = atlas.tile(th["tree"]).copy()
    tree[..., :3] = np.floor(tree[..., :3] * [0.62, 0.7, 0.74])
    for y in range(h):
        for x in range(w):
            if T(x, y) != "T":
                continue
            if T(x + 1, y) == "T":
                blit(out, tree, x * 16 + 8, y * 16 - 3)
            if T(x, y + 1) == "T":
                blit(out, tree, x * 16 + (-2 if float(hash_(x, y, 71)) < 0.5 else 2), y * 16 + 8)
    # troll ruin walls, joined to their neighbours
    for y in range(h):
        for x in range(w):
            if rows[y][x] == "R":
                blit(out, walls[wall_mask(T, x, y)], x * 16, y * 16)
    return np.clip(np.round(out), 0, 255).astype(np.uint8), cls, dist


def extend(m, th):
    """the map with its margin: MX / MY tiles all round, the edge carried outward"""
    w, h = m["w"], m["h"]
    W2, H2 = w + 2 * MX, h + 2 * MY
    rows = []
    for y in range(H2):
        r = []
        for x in range(W2):
            ix, iy = x - MX, y - MY
            if 0 <= ix < w and 0 <= iy < h:
                r.append(m["rows"][iy][ix])
            else:
                ch = m["rows"][min(max(iy, 0), h - 1)][min(max(ix, 0), w - 1)]
                r.append(ch if ch in "=w" else "T")
        rows.append("".join(r))
    base, over = [], []
    for y in range(H2):
        for x in range(W2):
            ix, iy = x - MX, y - MY
            if 0 <= ix < w and 0 <= iy < h:
                base.append(m["base"][iy * w + ix])
                over.append(m["over"][iy * w + ix])
            else:
                ch = rows[y][x]
                base.append(th["g1"] if ch == "T" else "water1" if ch == "w" else th["path"] + "c")
                over.append(th["tree"] if ch == "T" else "")
    shift = lambda lst: [dict(o, x=o["x"] + MX, y=o["y"] + MY) for o in lst]
    return dict(m, w=W2, h=H2, rows=rows, base=base, over=over, stamps=shift(m["stamps"]),
                chests=shift(m["chests"]), npcs=shift(m["npcs"]))


def regions(mask):
    """connected regions of a boolean mask -> [(x0, y0, x1, y1, ys, xs)]"""
    H, W = mask.shape
    seen = np.zeros_like(mask)
    out = []
    for sy, sx in zip(*np.nonzero(mask)):
        if seen[sy, sx]:
            continue
        stack, pts = [(sy, sx)], []
        seen[sy, sx] = True
        while stack:
            y, x = stack.pop()
            pts.append((y, x))
            for yy, xx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                if 0 <= yy < H and 0 <= xx < W and mask[yy, xx] and not seen[yy, xx]:
                    seen[yy, xx] = True
                    stack.append((yy, xx))
        ys_, xs_ = np.array([q[0] for q in pts]), np.array([q[1] for q in pts])
        out.append((int(xs_.min()), int(ys_.min()), int(xs_.max()) + 1, int(ys_.max()) + 1, ys_, xs_))
    return out


def meadows(img, cls):
    """each meadow as a cut-out (its pixels, transparent elsewhere): the game lays it over the legs of whoever stands
    in it, and bends thin strips of it as a gust of wind passes"""
    out = []
    for x0, y0, x1, y1, ys_, xs_ in regions(cls == 3):
        if len(ys_) < 24:
            continue                                  # a stray speck of the ragged edge: nobody stands in it
        cut = np.zeros((y1 - y0, x1 - x0, 4), dtype=np.uint8)
        cut[ys_ - y0, xs_ - x0, :3] = img[ys_, xs_]
        cut[ys_ - y0, xs_ - x0, 3] = 255
        out.append((x0, y0, x1 - x0, y1 - y0, cut))
    return out


def lights(m, atlas):
    """the map's lights in picture pixels: lamps, the forge, torches, and every window of a house"""
    w, h = m["w"], m["h"]
    out = []
    for y in range(h):
        for x in range(w):
            lt = LIGHT_TILES.get(m["over"][y * w + x])
            if lt:
                out.append((x * 16 + lt[0], y * 16 + lt[1], lt[2], lt[3], 0))
    for s in m["stamps"]:
        if "house" not in s["kind"]:
            continue
        for dy in range(6):
            for dx in range(5):
                t_ = atlas.tile("%s_%d_%d" % (s["kind"], dx, dy))
                if t_ is None:
                    continue
                r, g, b, a = t_[..., 0], t_[..., 1], t_[..., 2], t_[..., 3]
                glass = (a > 200) & (b > 150) & (b > r + 45) & (g > 90)
                if glass.any():
                    yy, xx = np.nonzero(glass)
                    out.append((int(round((s["x"] + dx) * 16 + xx.mean())),
                                int(round((s["y"] + dy) * 16 + yy.mean() + 2)), 16, 0, 1))
    return out


def light_map(W, H, ls, dark):
    """the darkness for dusk or night with stepped warm pools round each light, at 1 / LIGHT_SCALE size"""
    w, h = -(-W // LIGHT_SCALE), -(-H // LIGHT_SCALE)
    ys, xs = np.mgrid[0:h, 0:w]
    px, py = xs * LIGHT_SCALE + LIGHT_SCALE / 2, ys * LIGHT_SCALE + LIGHT_SCALE / 2
    img = np.zeros((h, w, 3))
    img[:] = dark
    dark, warm = np.array(dark, dtype=np.float64), np.array(WARM, dtype=np.float64)
    for k, f in ((1, 0.22), (0.8, 0.45), (0.6, 0.7), (0.4, 1)):
        for x, y, r, flick, win in ls:
            inside = (px - x) ** 2 + (py - y) ** 2 <= (r * k) ** 2
            img[inside] = dark + (warm - dark) * f * (0.85 if win else 1)
    return np.clip(np.round(img), 0, 255).astype(np.uint8)


WATER_FRAMES = 12            # the water loop: 12 frames, shown at 4 a second (UI.lua WATER_FPS)


def water_frames(img, cls, dist, th):
    """The moving water: per pond (connected water), a strip of WATER_FRAMES overlays on its bounding box - glints
    that drift (two sine waves, looping) and foam that comes and goes at the shore. Transparent elsewhere.
    Returns [(x, y, w, h, cols, rows, frames RGBA (rows*h, cols*w, 4))]."""
    H, W = cls.shape
    wat = cls == 2
    seen = np.zeros_like(wat)
    out = []
    light = np.array(th["water"]["light"], dtype=np.float64)
    for sy, sx in zip(*np.nonzero(wat)):
        if seen[sy, sx]:
            continue
        stack, pts = [(sy, sx)], []
        seen[sy, sx] = True
        while stack:
            y, x = stack.pop()
            pts.append((y, x))
            for yy, xx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                if 0 <= yy < H and 0 <= xx < W and wat[yy, xx] and not seen[yy, xx]:
                    seen[yy, xx] = True
                    stack.append((yy, xx))
        ys_, xs_ = np.array([p[0] for p in pts]), np.array([p[1] for p in pts])
        x0, y0, x1, y1 = xs_.min(), ys_.min(), xs_.max() + 1, ys_.max() + 1
        w, h = x1 - x0, y1 - y0
        cols = max(1, min(WATER_FRAMES, 256 // w))
        rows = -(-WATER_FRAMES // cols)
        strip = np.zeros((rows * h, cols * w, 4), dtype=np.uint8)
        d = dist[ys_, xs_]
        base = img[ys_, xs_].astype(np.float64)
        for f in range(WATER_FRAMES):
            ph = 2 * np.pi * f / WATER_FRAMES
            v = np.sin(xs_ * 0.42 + ys_ * 1.3 + 2 * ph) + np.sin(xs_ * 0.15 - ys_ * 0.6 - ph)
            glint = (d >= 3) & (v > 1.62)
            foam = (d == 2) & (hash_(xs_, ys_, f + 1) < 0.35)
            fy, fx = (f // cols) * h, (f % cols) * w
            gl = np.minimum(255, base[glint] * [1.25, 1.2, 1.1] + [30, 30, 24])
            strip[fy + ys_[glint] - y0, fx + xs_[glint] - x0, :3] = gl
            strip[fy + ys_[glint] - y0, fx + xs_[glint] - x0, 3] = 255
            strip[fy + ys_[foam] - y0, fx + xs_[foam] - x0, :3] = light
            strip[fy + ys_[foam] - y0, fx + xs_[foam] - x0, 3] = 255
        out.append((int(x0), int(y0), int(w), int(h), cols, rows, strip))
    return out


def clouds(size=256):
    """cloud shadows: dark blobs on clear, seamless both ways (the noise blended with its copy one size over), so the
    game can scroll it with REPEAT texture coordinates; drawn at low alpha over the world by day"""
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float64)
    f = lambda u, v: fbm(u / 70, v / 52, 91)
    fx, fy = xs / size, ys / size
    v = (f(xs, ys) * (1 - fx) + f(xs - size, ys) * fx) * (1 - fy) + (f(xs, ys - size) * (1 - fx) + f(xs - size, ys - size) * fx) * fy
    v = 0.5 + (v - 0.5) * (1 + 0.35 * (fx * (1 - fx) + fy * (1 - fy)) * 2)
    img = np.zeros((size, size, 4), dtype=np.uint8)
    on = v > 0.6
    img[on] = (10, 22, 30, 255)
    return img


def vignette(size=128):
    """the soft dark frame round the screen (multiplied): white in the middle, a cool shade at the edges"""
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float64)
    d = np.hypot((xs + 0.5) / size - 0.5, (ys + 0.5) / size - 0.5) / np.hypot(0.5, 0.5)
    k = np.clip((d - 0.58) / 0.42, 0, 1) ** 1.6
    edge = np.array([150, 140, 175], dtype=np.float64)
    img = 255 + (edge - 255) * k[..., None]
    return np.clip(np.round(img), 0, 255).astype(np.uint8)


def wall_mask(T, x, y):
    return ((1 if T(x, y - 1) == "R" else 0) | (2 if T(x + 1, y) == "R" else 0) |
            (4 if T(x, y + 1) == "R" else 0) | (8 if T(x - 1, y) == "R" else 0))


# ------------------------------------------------------------------------------------------- maps, hash, output

LOAD = """local out = {}
for id, def in pairs(ns.AzeroMaps) do
  if type(def) == 'table' and def.rows and not def.dynamic and (def.outdoor or not def.theme) then
    local m = ns.Azero.Compile(id)
    local base, over = {}, {}
    for y = 0, m.h - 1 do for x = 0, m.w - 1 do
      local k = m.key(x, y)
      base[#base + 1] = m.base[k] or ''
      over[#over + 1] = (type(m.over[k]) == 'string' and m.over[k]) or ''
    end end
    local rows, npcs, stamps, chests = {}, {}, {}, {}
    for i, r in ipairs(def.rows) do rows[i] = r end
    for _, n in ipairs(def.npcs or {}) do if type(n.x) == 'number' then npcs[#npcs + 1] = { x = n.x, y = n.y } end end
    for _, s in ipairs(def.stamps or {}) do stamps[#stamps + 1] = { kind = s.kind, x = s.x, y = s.y } end
    for _, c in ipairs(def.chests or {}) do chests[#chests + 1] = { x = c.x, y = c.y } end
    for _, o in ipairs(def.objects or {}) do
      if type(o.tile) == 'string' then over[m.key(o.x, o.y) + 1] = o.tile end
    end
    out[id] = { id = id, w = m.w, h = m.h, base = base, over = over, rows = rows, npcs = npcs, stamps = stamps,
                chests = chests, theme = def.theme or 'elwynn', indoor = not def.outdoor }
  end
end
return out"""


def load_maps():
    from _common import solo
    _, c = solo("Alice", tick=2, members=[("Bob", "MAGE", 3)])
    c.eval("ns.Azero:NewGame()")
    if not c.eval("return ns.Azero.Compile ~= nil"):
        c.eval("ns.Azero.Compile = ns.Azero.Compile or ns.AzeroGame and ns.AzeroGame.Compile")
    return c.eval_py(LOAD)


def _src_digest():
    h = hashlib.sha1()
    for p in (__file__, azeromon_props.__file__, interiors.__file__):
        h.update(open(p, "rb").read().replace(b"\r\n", b"\n"))
    h.update(open(os.path.join(MEDIA, "atlas.tga"), "rb").read())
    return h.hexdigest()


def inputs_hash(m, src=None):
    """what a map's picture depends on: its tiles, stamps, chests and NPC spots, the atlas and this code"""
    key = json.dumps({k: m[k] for k in ("w", "h", "base", "over", "rows", "stamps", "chests", "npcs", "theme")},
                     sort_keys=True)
    h = hashlib.sha1((src or _src_digest()).encode() + key.encode() + str(VERSION).encode())
    return h.hexdigest()[:16]


def pot(n):
    p = 1
    while p < n:
        p *= 2
    return p


def chunks(img):
    H, W = img.shape[:2]
    out = []
    for cy in range(0, H, CHUNK):
        for cx in range(0, W, CHUNK):
            part = img[cy:cy + CHUNK, cx:cx + CHUNK]
            uh, uw = part.shape[:2]
            th_, tw_ = pot(uh), pot(uw)
            tex = np.zeros((th_, tw_, 3), dtype=np.uint8)
            tex[:uh, :uw] = part
            tex[uh:, :uw] = part[-1:, :, :]             # pad with the edge (no dark seam under filtering)
            tex[:, uw:] = tex[:, uw - 1:uw]
            out.append((cx, cy, uw, uh, tw_, th_, tex))
    return out


def write_lua(entries):
    row = lambda c: "{ " + ", ".join("%d" % v for v in c) + " }"
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Ground.lua", ...) then return end '
        "-- DisasterZone Games/Azeromon/Ground.lua  (GENERATED by dev/generators/gen_azeromon_ground.py - do not edit)",
        "-- Baked ground per outdoor map, in pixels of the baked picture, which reaches mx, my tiles past the map's edges",
        "-- (map pixel = picture pixel - mx * 16, - my * 16). Files in Media/Azeromon/Ground:",
        "--   chunks       { x, y, w, h, tw, th }  <map>_<cx>_<cy>.tga: the chunk at x, y, the size used, the texture size",
        "--   water        { x, y, w, h, cols, rows, tw, th }  <map>_w<i>.tga: a pond's box and its %d moving-water frames"
        % WATER_FRAMES,
        "--   meadows      { x, y, w, h, tw, th }  <map>_m<i>.tga: a meadow's cut-out (legs in the grass, wind)",
        "--   lights       { x, y, radius, flickers, window }",
        "--   lightChunks  like chunks, at 1/%d size: <map>_d_<cx>_<cy>.tga (dusk), <map>_n_<cx>_<cy>.tga (night)"
        % LIGHT_SCALE,
        "--   shafts       { x, y, w }: sun through a window (interiors, by day: dust drifts in it)",
        "--   indoor       an interior: <map>_e_<cx>_<cy>.tga is the room by evening (night windows); its light map is _n_",
        "--   v            a hash of what the picture was made from (the ground test checks it against the maps)",
        "local addonName, ns = ...",
        "ns.AzeroGround = {",
    ]
    for mid in sorted(entries):
        e_ = entries[mid]
        lines.append('    %s = {' % mid)
        lines.append('        v = "%s", mx = %d, my = %d, lightScale = %d,%s' % (
            e_["v"], e_.get("mx", MX), e_.get("my", MY), LIGHT_SCALE, " indoor = true," if e_.get("indoor") else ""))
        for key in ("chunks", "water", "meadows", "lights", "lightChunks", "shafts"):
            lines.append("        %s = { %s }," % (key, ", ".join(row(c) for c in e_.get(key, []))))
        lines.append("    },")
    lines.append("}")
    with open(GROUND_LUA, "w", newline="\n", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def selected(maps):
    """outdoor maps of GROUND_THEMES, and every interior (houses and inns)"""
    return sorted(n for n, m in maps.items() if m.get("indoor") or m["theme"] in GROUND_THEMES)


INDOOR_DARK = (112, 96, 120)        # an interior's evening, multiplied (the light map), warm pools round its lights


def bake_interior(mid, m, atlas, src):
    """an interior: the room by day (sun shafts, bright windows) and by evening (night windows, no shafts), and its
    evening light map; the room's 16 px wall thickness is the margin (mx = my = 1)"""
    furn = {k: interiors._img(fn()) for k, fn in interiors.FURNITURE.items()}
    day, lights, shafts, span = interiors.bake_room(m, atlas, furn, "day")
    day = interiors.light_room(day, lights, shafts, span, "day")
    eve, _, _, _ = interiors.bake_room(m, atlas, furn, "night")
    cs = []
    for prefix, img in (("", day), ("e_", eve)):
        img = np.clip(np.round(img), 0, 255).astype(np.uint8)
        cs = []
        for cx, cy, uw, uh, tw_, th_, tex in chunks(img):
            Image.fromarray(tex, "RGB").save(os.path.join(OUT_DIR, "%s_%s%d_%d.tga" % (mid, prefix, cx // CHUNK, cy // CHUNK)))
            cs.append((cx, cy, uw, uh, tw_, th_))
    ls = [(int(x), int(y), int(r * 1.6), f, 0) for x, y, r, f in lights]
    lm = light_map(day.shape[1], day.shape[0], ls, INDOOR_DARK)
    lc = []
    for cx, cy, uw, uh, tw_, th_, tex in chunks(lm):
        Image.fromarray(tex, "RGB").save(os.path.join(OUT_DIR, "%s_n_%d_%d.tga" % (mid, cx // CHUNK, cy // CHUNK)))
        lc.append((cx, cy, uw, uh, tw_, th_))
    return {"v": inputs_hash(m, src), "chunks": cs, "water": [], "meadows": [], "lights": ls, "lightChunks": lc,
            "shafts": [(int(x), int(y), int(w)) for x, y, w in shafts], "indoor": True, "mx": 1, "my": 1}


def main():
    atlas = Atlas()
    walls = {}
    for name, img in azeromon_props.images().items():
        if name.startswith("ruinwall_"):
            walls[int(name.split("_")[1])] = np.array(img, dtype=np.float64)
    maps = load_maps()
    src = _src_digest()
    os.makedirs(OUT_DIR, exist_ok=True)
    entries = {}
    for mid in selected(maps):
        if maps[mid].get("indoor"):
            entries[mid] = bake_interior(mid, maps[mid], atlas, src)
            print("baked", mid, "(interior)")
            continue
        th = THEMES.get(maps[mid]["theme"], THEMES["elwynn"])
        m = extend(maps[mid], th)
        img, cls, dist = bake(m, atlas, walls)
        cs = []
        for cx, cy, uw, uh, tw_, th_, tex in chunks(img):
            Image.fromarray(tex, "RGB").save(os.path.join(OUT_DIR, "%s_%d_%d.tga" % (mid, cx // CHUNK, cy // CHUNK)))
            cs.append((cx, cy, uw, uh, tw_, th_))
        ws = []
        for i, (x, y, w, h, cols, rows, strip) in enumerate(water_frames(img, cls, dist, th)):
            tw_, th_ = pot(strip.shape[1]), pot(strip.shape[0])
            tex = np.zeros((th_, tw_, 4), dtype=np.uint8)
            tex[:strip.shape[0], :strip.shape[1]] = strip
            Image.fromarray(tex, "RGBA").save(os.path.join(OUT_DIR, "%s_w%d.tga" % (mid, i + 1)))
            ws.append((x, y, w, h, cols, rows, tw_, th_))
        ms = []
        for i, (x, y, w, h, cut) in enumerate(meadows(img, cls)):
            tw_, th_ = pot(w), pot(h)
            tex = np.zeros((th_, tw_, 4), dtype=np.uint8)
            tex[:h, :w] = cut
            Image.fromarray(tex, "RGBA").save(os.path.join(OUT_DIR, "%s_m%d.tga" % (mid, i + 1)))
            ms.append((x, y, w, h, tw_, th_))
        ls = lights(m, atlas)
        lc = []
        for period, dark in NIGHT.items():
            lm = light_map(img.shape[1], img.shape[0], ls, dark)
            lc = []
            for cx, cy, uw, uh, tw_, th_, tex in chunks(lm):
                Image.fromarray(tex, "RGB").save(os.path.join(
                    OUT_DIR, "%s_%s_%d_%d.tga" % (mid, period[0], cx // CHUNK, cy // CHUNK)))
                lc.append((cx, cy, uw, uh, tw_, th_))
        entries[mid] = {"v": inputs_hash(maps[mid], src), "chunks": cs, "water": ws, "meadows": ms, "lights": ls,
                        "lightChunks": lc}
        print("baked", mid, img.shape[1], "x", img.shape[0], len(cs), "chunks")
    keep = {"%s_%d_%d.tga" % (mid, c[0] // CHUNK, c[1] // CHUNK) for mid, e in entries.items() for c in e["chunks"]}
    keep |= {"%s_w%d.tga" % (mid, i + 1) for mid, e in entries.items() for i in range(len(e["water"]))}
    keep |= {"%s_m%d.tga" % (mid, i + 1) for mid, e in entries.items() for i in range(len(e["meadows"]))}
    keep |= {"%s_%s_%d_%d.tga" % (mid, q, c[0] // CHUNK, c[1] // CHUNK) for mid, e in entries.items()
             for c in e["lightChunks"] for q in "dn"}
    keep |= {"%s_e_%d_%d.tga" % (mid, c[0] // CHUNK, c[1] // CHUNK) for mid, e in entries.items()
             if e.get("indoor") for c in e["chunks"]}
    keep |= {"clouds.tga", "vignette.tga"}
    for f in os.listdir(OUT_DIR):
        if f.endswith(".tga") and f not in keep:
            os.remove(os.path.join(OUT_DIR, f))
    Image.fromarray(clouds(), "RGBA").save(os.path.join(OUT_DIR, "clouds.tga"))
    Image.fromarray(vignette(), "RGB").save(os.path.join(OUT_DIR, "vignette.tga"))
    write_lua(entries)
    print("wrote Ground.lua", len(entries), "maps")


if __name__ == "__main__":
    main()
