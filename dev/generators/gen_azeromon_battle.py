"""Azeromon battle scenes in layers (0.45, "battles where you stand"; the fidelity mockup's section 1).

The old backdrops (azeromon_battle.py, baked by gen_azeromon_ground.py into Media/Ground/battle_<scene>.tga) are one
picture per zone. Here every outdoor scene is painted again with the same painter, but kept as layers the game can
drift at their own speeds and swap by the time of day:
  <scene>_sky_<p>     the sky for period p (day, dusk, night, rain): 240 x 64 of 256 x 64
  <scene>_far_<p>     the far silhouettes, hazed and darkened for p: 240 x 64 of 256 x 64 (see-through)
  <scene>_near_<p>    the near silhouettes (+ cottages, their windows lit at dusk and night)
  <scene>_ground_<p>  the ground with its platforms, lamps and features, lit for p (lamp pools baked in):
                      rows GROUND_TOP .. 143, 240 x 128 of 256 x 128
  <scene>_refl_<p>    on scenes with water: the sky, far and near mirrored into it (rows WATER_Y0 ..)
  <scene>_wmask       the water's own shape (a MaskTexture keeps the rippling rows in the water)
  blades_<kind>       grass or reeds in front of your beast, four frames of sway (240 x 50 each)
Spots ("where you stand"): Elwynn's town edge, pond and road, Redridge's lake (Lakeshire). Scenes underground or
indoors (mine, depths, molten, room) keep their old picture; this file only lists their lights.
Layers are 240 wide: 8 px spare each side for the camera's drift (the screen is 224 x 144 game pixels).

Writes addon/DisasterZone_Azeromon/Media/Battle/*.tga and BattleScenes.lua.
Run: luaenv\\Scripts\\python.exe generators\\gen_azeromon_battle.py
"""
import hashlib
import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import azeromon_battle as AB  # noqa: E402
import azeromon_props as P  # noqa: E402
from azeromon_props import H  # noqa: E402

DEV = os.path.dirname(HERE)
PACK = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone_Azeromon")
MEDIA = os.path.join(PACK, "Media")
OUT = os.path.join(MEDIA, "Battle")
LUA = os.path.join(PACK, "BattleScenes.lua")
ASSET = 17

W, Ht, HOR, OFF = 240, 144, 56, 8
GROUND_TOP = 16                         # the ground layer's first row (lamp posts rise above the horizon)
FOE = (AB.FOE[0] + OFF, AB.FOE[1], AB.FOE[2], AB.FOE[3])
ALLY = (AB.ALLY[0] + OFF, AB.ALLY[1], AB.ALLY[2], AB.ALLY[3])
PERIODS = ("day", "dusk", "night", "rain")

SKY_DUSK = [(58, 56, 112), (112, 76, 124), (186, 104, 112), (236, 146, 100), (250, 196, 132)]
SKY_NIGHT = [(10, 14, 34), (16, 22, 48), (26, 34, 66), (40, 50, 86), (58, 66, 104)]
SKY_RAIN = [(84, 92, 104), (100, 108, 120), (118, 126, 136), (138, 144, 150), (156, 160, 164)]
MOON = (196, 15)
SUN = (34, HOR - 7)
# a period's air between us and the far layers (mixed in), and its darkness (multiplied over everything but the sky)
HAZE = {"dusk": ((250, 196, 132), 0.34, 0.16), "night": ((40, 50, 86), 0.42, 0.2), "rain": ((150, 154, 158), 0.4, 0.2)}
DARK = {"day": (255, 255, 255), "dusk": (236, 190, 168), "night": (78, 92, 150), "rain": (186, 194, 208)}
GRASS = ((40, 88, 46), (66, 124, 60), (122, 176, 86))
REEDS = ((104, 80, 36), (150, 122, 58), (198, 172, 100))


def blank():
    return np.full((Ht, W, 3), np.nan)


def to_rgba(img, rows=None):
    a = ~np.isnan(img[..., 0])
    out = np.zeros(img.shape[:2] + (4,), dtype=np.uint8)
    out[..., :3] = np.clip(np.round(np.nan_to_num(img)), 0, 255).astype(np.uint8)
    out[..., 3] = np.where(a, 255, 0)
    return out if rows is None else out[rows[0]:rows[1]]


def save(arr, name, tw, th):
    """arr (h, w, 3|4) into a power-of-two texture tw x th, top-left"""
    ch = arr.shape[2]
    tex = np.zeros((th, tw, ch), dtype=np.uint8)
    tex[:arr.shape[0], :arr.shape[1]] = arr
    Image.fromarray(tex, "RGBA" if ch == 4 else "RGB").save(os.path.join(OUT, name + ".tga"))


# ---------------------------------------------------------------------------------------------------------- skies
def sky(bands, kind, seed, extra=None):
    img = np.zeros((Ht, W, 3))
    AB._sky(img, bands, 0, HOR + 4)
    if extra:
        extra(img)
    if kind == "night":
        for i in range(70):
            x, y = int(H(i, 1, seed) * W), int(H(i, 2, seed) * (HOR - 8))
            v = 150 + int(H(i, 3, seed) * 100)
            img[y, x] = (v, v, min(255, v + 20))
        cx, cy = MOON
        for y in range(cy - 8, cy + 9):
            for x in range(cx - 8, cx + 9):
                d = (x - cx) ** 2 + (y - cy) ** 2
                if d <= 36:
                    lit = (x - cx + 3) ** 2 + (y - cy + 1) ** 2 > 20
                    img[y, x] = (238, 236, 214) if lit else (40, 48, 80)
                elif d <= 64:
                    img[y, x] = img[y, x] * 0.75 + np.array((90, 100, 140)) * 0.25
    if kind == "dusk":
        cx, cy = SUN
        for y in range(cy - 14, cy + 15):
            for x in range(cx - 14, cx + 15):
                d = math.hypot(x - cx, y - cy)
                if 0 <= x < W and 0 <= y < Ht:
                    if d <= 6:
                        img[y, x] = (255, 238, 184)
                    elif d <= 14:
                        k = (1 - (d - 6) / 8) * 0.5
                        img[y, x] = img[y, x] * (1 - k) + np.array((255, 214, 150)) * k
    if kind == "rain":
        for i in range(6):
            cx, cy = int(H(i, 4, seed) * W), 6 + int(H(i, 5, seed) * 32)
            AB._cloud(img, cx, cy, 30 + int(H(i, 6, seed) * 20), 7, seed + i, hi=(128, 134, 142), lo=(100, 106, 116))
    return np.clip(np.round(img[:64]), 0, 255).astype(np.uint8)


# ------------------------------------------------------------------------------------------------ small painters
def cottage(img, x0, base, roof, wall, haze, k=0.3):
    """a small timbered cottage at the field's edge, seen from afar; returns its windows and chimney top"""
    hz = np.array(haze, dtype=float)
    mix = lambda c: np.array(c, dtype=float) * (1 - k) + hz * k
    w, wall_h, roof_h = 28, 11, 12
    cx = x0 + w / 2
    timber = (84, 56, 36)
    for y in range(base - wall_h, base + 1):
        for x in range(x0 + 1, x0 + w - 1):
            c = wall
            if x in (x0 + 1, x0 + w - 2, int(cx)) or y == base - wall_h + 4:
                c = timber
            elif (x - x0) % 5 == 0 and y > base - wall_h + 4:
                c = np.array(wall) * 0.9
            if x > cx + 6:
                c = np.array(c) * 0.86
            img[y, x] = mix(c)
    for y in range(base - 6, base + 1):
        for x in range(int(cx) - 1, int(cx) + 2):
            img[y, x] = mix((60, 38, 24) if x < cx + 1 else (48, 30, 20))
    wins = [(x0 + 5, base - 7), (x0 + w - 9, base - 7)]
    for wx, wy in wins:
        img[wy - 1, wx - 1:wx + 4] = mix(timber)
        img[wy:wy + 3, wx:wx + 3] = mix((30, 36, 44))
        img[wy + 3, wx - 1:wx + 4] = mix(timber)
    top = base - wall_h - roof_h
    for y in range(top, base - wall_h + 1):
        t = (y - top) / roof_h
        half = 1 + t * (w / 2 + 1)
        for x in range(int(cx - half - 1), int(cx + half + 2)):
            if not (0 <= x < W) or abs(x + 0.5 - cx) > half:
                continue
            left = x + 0.5 < cx
            r = np.array(roof, dtype=float) * (1.08 if left else 0.8)
            if (y - top) % 3 == 2:
                r = r * 0.82
            elif (y - top) % 3 == 0 and (x + (y // 3) * 2) % 4 == 0:
                r = r * 0.9
            if abs(x + 0.5 - cx) < 1:
                r = np.array(roof, dtype=float) * 1.25
            if y == base - wall_h:
                r = np.array(roof, dtype=float) * 0.5
            img[y, x] = mix(np.minimum(255, r))
    chim = (x0 + w - 9, top + 3)
    for y in range(chim[1] - 4, chim[1] + 5):
        for x in range(chim[0], chim[0] + 3):
            img[y, x] = mix((112, 108, 104) if x < chim[0] + 2 else (84, 80, 78))
    img[chim[1] - 5, chim[0] - 1:chim[0] + 4] = mix((70, 66, 64))
    return wins, (chim[0] + 1, chim[1] - 6)


def reeds(img, x0, x1, base, seed, ramp=((46, 84, 40), (70, 118, 52), (110, 150, 70))):
    for x in range(x0, x1):
        if H(x, 1, seed) < 0.55:
            h = 3 + int(H(x, 2, seed) * 7)
            for k in range(h):
                c = ramp[2] if k > h - 2 else ramp[1] if (x + k) % 3 else ramp[0]
                xx = x + (1 if k > h * 0.7 and H(x, 3, seed) < 0.4 else 0)
                if 0 <= xx < W and 0 <= base - k < Ht:
                    img[base - k, xx] = c
            if H(x, 4, seed) < 0.12:
                img[base - h - 1:base - h + 2, x] = (110, 70, 40)


def lamppost(img, x, base):
    """a street lamp at battle size, shaded like the overworld one (azeromon_props IRON / GLASS); its glass"""
    s = P.Spr(12, 38)
    I, G = P.IRON, P.GLASS
    s.rect(5, 11, 6, 35, I[2]); s.rect(6, 11, 6, 35, I[1])
    s.rect(3, 34, 8, 37, I[1]); s.rect(3, 34, 8, 34, I[2]); s.rect(4, 33, 7, 33, I[2])
    s.rect(2, 1, 9, 2, I[3]); s.rect(4, 0, 7, 0, I[2])
    s.rect(2, 3, 9, 9, G[2]); s.rect(3, 4, 8, 8, G[3]); s.rect(4, 4, 5, 6, G[3])
    for xx in (2, 9):
        s.rect(xx, 3, xx, 9, I[2])
    s.rect(2, 10, 9, 10, I[2]); s.rect(4, 11, 7, 11, I[1])
    s.outline()
    for yy in range(s.h):
        for xx in range(s.w):
            c = s.get(xx, yy)
            if c is not None:
                img[base - s.h + 1 + yy, x - 6 + xx] = c[:3]
    return (x, base - s.h + 7)


def fence(img, pts):
    wood = ((92, 62, 38), (128, 88, 52), (160, 116, 70))
    for i, (x, y) in enumerate(pts):
        h = 4 + int((y - HOR) / 9)
        for k in range(h):
            img[y - k, x] = wood[1]
            img[y - k, x + 1] = wood[0]
        img[y - h, x] = wood[2]
        if i:
            px_, py_ = pts[i - 1]
            ph = 4 + int((py_ - HOR) / 9)
            n = max(abs(x - px_), 1)
            for t in range(n + 1):
                xx = px_ + (x - px_) * t / n
                yy = py_ + (y - py_) * t / n
                hh = ph + (h - ph) * t / n
                for r in (0.35, 0.75):
                    img[int(yy - hh * r), int(xx)] = wood[2] if r < 0.5 else wood[1]


def platform_rock(img, cx, cy, rx, ry, seed):
    AB._platform(img, cx, cy, rx, ry, (112, 132, 70), (86, 80, 76), seed)
    for y in range(int(cy), int(cy + ry + 4)):
        for x in range(int(cx - rx - 1), int(cx + rx + 2)):
            d = ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy - 3) / ry) ** 2
            if d <= 1 and y > cy and (x * 3 + y * 5) % 11 == 0:
                img[y, x] = (110, 104, 96)


def dock(img, x0, x1, y):
    plank = ((96, 64, 38), (132, 92, 54), (168, 124, 76))
    for x in range(x0, x1):
        img[y, x] = plank[2] if (x // 6) % 2 else plank[1]
        img[y + 1, x] = plank[1]
        for k in range(2, 5):
            img[y + k, x] = plank[0] if k < 4 else np.array(plank[0]) * 0.7
        if x % 12 == 3 or x == x1 - 2:
            for k in range(5, 14):
                img[y + k, x] = (70, 48, 30)
                img[y + k, x + 1] = (54, 36, 22)


def grass_top(atlas, tile, dim=(1, 1, 1)):
    return tuple(min(255, v * 1.04 * d + 6) for v, d in zip(atlas.tile(tile)[..., :3].reshape(-1, 3).mean(0), dim))


# ------------------------------------------------------------------------------------------------- the scenes
def base_scene(key, atlas):
    """a zone's own field, as layers: (sky bands, sky extra painter, far, near, ground, scene info)"""
    s = {"key": key, "water": None, "lights": [], "smoke": [], "blades": "grass", "flies": False, "clouds": False,
         "windows": []}
    far, near, ground = blank(), blank(), blank()
    if key in ("elwynn", "westfall", "duskwood", "jungle", "arena"):
        sc = dict(AB.SCENES[key], name=key)
        seed = len(key) * 7
        layer = sc["layer"]
        AB._far_layer(far, "trees" if layer == "palms" else layer, sc["far"], tuple(min(255, v + 18) for v in sc["far"]),
                      HOR - 4, seed)
        if layer in ("trees", "pines"):
            AB._far_layer(near, layer, sc["near"], sc["nearHi"], HOR, seed + 9)
        elif layer == "palms":
            AB._far_layer(near, "trees", sc["near"], sc["nearHi"], HOR, seed + 9)
            AB._palms(near, sc["near"], sc["nearHi"], HOR, seed)
        AB._ground(ground, atlas, sc, HOR, seed)
        if sc.get("mist"):
            AB._mist(ground, HOR, HOR + 14, (170, 180, 210), 0.35)
        AB._decor(ground, sc, HOR, seed)
        top = grass_top(atlas, sc["ground"], sc.get("dim", (1, 1, 1)))
        for cx, cy, rx, ry in (FOE, ALLY):
            AB._platform(ground, cx, cy, rx, ry, top, sc["rim"], seed)
        s.update(bands=sc["sky"], clouds=bool(sc.get("clouds")), flies=key in ("elwynn", "jungle", "duskwood"),
                 haze=sc["haze"], moon=bool(sc.get("moon")))
        if key == "arena":
            s["blades"] = None
        return far, near, ground, s
    sc = AB.SCENES[key]
    seed = sum(map(ord, key))
    extra = None
    if key == "redridge":
        AB._ridge(far, HOR - 8, (130, 140, 170), (156, 164, 190), seed, "crags", amp=24, scale=18)
        AB._trees(far, HOR - 2, (176, 84, 40), (220, 130, 50), seed, "round")
        AB._trees(near, HOR + 1, (140, 60, 34), (196, 100, 40), seed + 9, "pines")

        def extra(img):
            for i, (cx, cy, w, h) in enumerate(((40, 12, 20, 6), (150, 20, 28, 7), (206, 8, 14, 4))):
                AB._cloud(img, cx, cy, w, h, seed + i, hi=sc["cl"][0], lo=sc["cl"][1])
    elif key == "steppes":
        AB._peak(far, 70, HOR - 2, 50, (30, 26, 28), (44, 38, 40))
        AB._ridge(near, HOR, (40, 34, 34), (60, 50, 48), seed, "crags", amp=16, scale=12)

        def extra(img):
            AB._glow(img, 112, HOR, 120, (255, 90, 30), 0.35)
            for i in range(40):
                img[int(H(i, 2, 7) * HOR), int(H(i, 1, 7) * W)] = (255, 170, 70)
    elif key == "gorge":
        AB._ridge(far, HOR - 4, (190, 120, 80), (214, 150, 100), seed, "mesas", amp=34, scale=26)
        AB._ridge(near, HOR, (150, 84, 50), (180, 110, 70), seed + 5, "mesas", amp=18, scale=14)
    AB._bk_ground(ground, atlas, sc, HOR, seed)
    if key == "steppes":
        AB._mist(ground, HOR, HOR + 8, (110, 80, 70), 0.35)
    AB._bk_decor(ground, sc, HOR, seed)
    t1 = AB._ramp_tile(atlas, sc["tile"], *sc["ramp"]).reshape(-1, 3).mean(0)
    top = tuple(min(255, v * 1.08 + 8) for v in t1)
    for cx, cy, rx, ry in (FOE, ALLY):
        AB._platform(ground, cx, cy, rx, ry, top, sc["rim"], seed)
    s.update(bands=sc["sky"], extra=extra, haze=sc["haze"], clouds=False, flies=False,
             blades="grass" if key == "redridge" else None)
    return far, near, ground, s


def spot_town(atlas):
    far, near, ground, s = base_scene("elwynn", atlas)
    sc = AB.SCENES["elwynn"]
    wins, chimney = cottage(near, 192, HOR, (156, 62, 50), (206, 184, 146), sc["haze"], 0.32)
    s["windows"] = [(wx + 1, wy + 1) for wx, wy in wins]
    s["smoke"] = [chimney]
    return far, near, ground, s


def spot_pond(atlas):
    sc = dict(AB.SCENES["elwynn"], name="elwynn")
    seed = 23
    far, near, ground = blank(), blank(), blank()
    AB._far_layer(far, "trees", sc["far"], tuple(min(255, v + 18) for v in sc["far"]), HOR - 4, seed)
    AB._far_layer(near, "trees", sc["near"], sc["nearHi"], HOR, seed + 9)
    AB._ground(ground, atlas, sc, HOR, seed)
    AB._decor(ground, sc, HOR, seed)
    water = np.zeros((Ht, W), dtype=bool)
    cx, cy, rx, ry = 72, 70, 66, 10
    shore = (150, 140, 96)
    for y in range(HOR + 1, Ht):
        for x in range(W):
            d = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2
            wob = 0.12 * AB._vn(x / 7, y / 3, seed)
            if d < 0.86 + wob:
                k = (y - (cy - ry)) / (2 * ry)
                ground[y, x] = np.array((58, 116, 150)) * (1 - k * 0.25) + np.array((40, 70, 90)) * k * 0.25
                water[y, x] = True
            elif d < 1.04 + wob:
                ground[y, x] = shore if H(x, y, seed) < 0.7 else np.array(shore) * 0.85
    for i in range(9):
        lx, ly = int(cx - rx * 0.7 + H(i, 1, seed) * rx * 1.4), int(cy - ry * 0.4 + H(i, 2, seed) * ry * 0.9)
        if water[ly, lx]:
            for dx in range(-2, 3):
                for dy in (0, 1):
                    if abs(dx) + dy < 3 and water[ly + dy, lx + dx]:
                        ground[ly + dy, lx + dx] = (70, 132, 60) if dy == 0 else (48, 98, 46)
                        water[ly + dy, lx + dx] = False
            if H(i, 3, seed) < 0.4:
                ground[ly, lx] = (244, 214, 230)
    reeds(ground, 0, 26, cy + 2, seed)
    reeds(ground, 118, 140, cy - 2, seed + 1)
    top = grass_top(atlas, "grass1")
    for cx_, cy_, rx_, ry_ in (FOE, ALLY):
        AB._platform(ground, cx_, cy_, rx_, ry_, top, sc["rim"], seed)
    s = {"key": "elwynn_pond", "bands": sc["sky"], "haze": sc["haze"], "water": water, "waterCol": (58, 116, 150),
         "lights": [], "smoke": [], "blades": "grass", "flies": True, "clouds": True, "windows": [], "moon": False}
    return far, near, ground, s


def spot_road(atlas):
    sc = dict(AB.SCENES["elwynn"], name="elwynn")
    seed = 37
    far, near, ground = blank(), blank(), blank()
    AB._far_layer(far, "hills", (128, 164, 150), (146, 180, 164), HOR - 6, seed)
    AB._far_layer(far, "trees", sc["far"], tuple(min(255, v + 18) for v in sc["far"]), HOR - 3, seed + 4)
    AB._far_layer(near, "trees", sc["near"], sc["nearHi"], HOR, seed + 9)
    for y in range(HOR - 24, HOR + 1):
        half = 4 + (HOR - y) * 0.55
        for x in range(110, 170):
            if abs(x + 0.5 - 139) < half + 2 * AB._vn(x / 2, y / 2, seed):
                near[y, x] = np.nan
    AB._ground(ground, atlas, sc, HOR, seed)
    AB._decor(ground, sc, HOR, seed)
    DIRT = np.array([(122, 86, 52), (150, 110, 70), (172, 130, 86), (192, 152, 104)], dtype=float)
    for y in range(HOR, Ht):
        t = (y - HOR) / (Ht - HOR)
        cxr = 139 - 52 * t * t - 10 * t
        half = 3 + 24 * t
        for x in range(W):
            e = abs(x + 0.5 - cxr) - half - 1.5 * AB._vn(x / 3, y / 2, seed)
            if e < 0:
                v = 0.55 * AB._vn(x / 6, y / 3, seed + 5) + 0.45 * H(x, y, seed)
                c = DIRT[min(3, int(v * 3.6))].copy()
                if H(x, y, seed + 1) < 0.05:
                    c = DIRT[0] * 0.85
                if -e < 1.5:
                    c = c * 0.9
                c = c * (1 - 0.1 * t)
                k = max(0.0, 1 - (y - HOR) / 34) * 0.4
                ground[y, x] = c * (1 - k) + np.array(sc["haze"]) * k
            elif e < 1.2 and H(x, y, seed) < 0.6:
                ground[y, x] = ground[y, x] * 0.8
    fence(ground, [(100, 62), (92, 68), (82, 76), (70, 86)])
    top = grass_top(atlas, "grass1")
    for cx, cy, rx, ry in (FOE, ALLY):
        AB._platform(ground, cx, cy, rx, ry, top, sc["rim"], seed)
    lamp = lamppost(ground, 124, 64)
    s = {"key": "elwynn_road", "bands": sc["sky"], "haze": sc["haze"], "water": None,
         "lights": [{"x": lamp[0], "y": lamp[1], "gx": 124, "gy": 64, "r": 84, "col": (255, 214, 140)}],
         "smoke": [], "blades": "grass", "flies": True, "clouds": True, "windows": [], "moon": False}
    return far, near, ground, s


def spot_lake(atlas):
    sc = AB.SCENES["redridge"]
    seed = sum(map(ord, "lake"))
    far, near, ground = blank(), blank(), blank()
    AB._ridge(far, HOR - 8, (130, 140, 170), (156, 164, 190), seed, "crags", amp=24, scale=18)
    AB._trees(far, HOR - 3, (176, 84, 40), (220, 130, 50), seed, "round")
    AB._trees(near, HOR + 1, (140, 60, 34), (196, 100, 40), seed + 9, "pines")
    wins, smoke = [], []
    for hx in (10, 44):
        w_, ch = cottage(near, hx, HOR, (150, 58, 40), (196, 160, 118), sc["haze"], 0.3)
        wins += w_
        smoke.append(ch)
    AB._bk_ground(ground, atlas, dict(sc, feature=None), HOR, seed)
    water = np.zeros((Ht, W), dtype=bool)
    shore_y = lambda x: 84 + int(4 * AB._vn(x / 22, 0, seed)) + (6 * (x - 160) / 80 if x > 160 else 0)
    for y in range(HOR + 1, Ht):
        for x in range(W):
            sy = shore_y(x)
            if y < sy:
                k = (y - HOR) / max(1, sy - HOR)
                ground[y, x] = np.array((70, 120, 150)) * (1 - 0.18 * k)
                water[y, x] = True
            elif y < sy + 2:
                ground[y, x] = (196, 170, 120) if H(x, y, seed) < 0.6 else (160, 136, 96)
    AB._bk_decor(ground, dict(sc, decor=[("tuft",), ("pebble", (150, 110, 70)), ("tuft",), ("flower", (230, 120, 40), (255, 220, 120))]),
                 int(shore_y(0)) + 6, seed)
    reeds(ground, 0, 34, 88, seed, ramp=((90, 70, 30), (140, 110, 50), (190, 160, 80)))
    dock(ground, 0, 74, 66)
    water[66:80, 0:76] = False
    lamp = lamppost(ground, 66, 66)
    platform_rock(ground, FOE[0], FOE[1], FOE[2], FOE[3], seed)
    for y in range(FOE[1] - FOE[3] - 1, FOE[1] + FOE[3] + 5):
        for x in range(FOE[0] - FOE[2] - 2, FOE[0] + FOE[2] + 3):
            d = ((x + 0.5 - FOE[0]) / FOE[2]) ** 2 + ((y + 0.5 - FOE[1] - 3) / FOE[3]) ** 2
            d2 = ((x + 0.5 - FOE[0]) / FOE[2]) ** 2 + ((y + 0.5 - FOE[1]) / FOE[3]) ** 2
            if d <= 1.05 or d2 <= 1.05:
                water[y, x] = False
    t1 = AB._ramp_tile(atlas, sc["tile"], *sc["ramp"]).reshape(-1, 3).mean(0)
    AB._platform(ground, ALLY[0], ALLY[1], ALLY[2], ALLY[3], tuple(min(255, v * 1.08 + 8) for v in t1), sc["rim"], seed)
    s = {"key": "redridge_lake", "bands": sc["sky"], "haze": sc["haze"], "water": water, "waterCol": (70, 120, 150),
         "lights": [{"x": lamp[0], "y": lamp[1], "gx": 66, "gy": 66, "r": 76, "col": (255, 200, 120)}],
         "smoke": smoke, "blades": "reeds", "flies": False, "clouds": False,
         "windows": [(wx + 1, wy + 1) for wx, wy in wins], "moon": False, "foeReflects": True}

    def extra(img):
        for i, (cx, cy, w, h) in enumerate(((40, 12, 20, 6), (150, 20, 28, 7), (206, 8, 14, 4))):
            AB._cloud(img, cx, cy, w, h, seed + i, hi=sc["cl"][0], lo=sc["cl"][1])
    s["extra"] = extra
    return far, near, ground, s


# --------------------------------------------------------------------------------------------- periods, light
def hazed(layer, period, which):
    out = layer.copy()
    a = ~np.isnan(out[..., 0])
    if period in HAZE:
        col, kf, kn = HAZE[period]
        k = kf if which == "far" else kn
        out[a] = out[a] * (1 - k) + np.array(col) * k
    out[a] = out[a] * np.array(DARK[period]) / 255
    return out


def light_map(s, period):
    """the period's darkness with the lamps' pools let through (dusk lamps smaller), multiplied over the ground"""
    lm = np.tile(np.array(DARK[period], dtype=float), (Ht, W, 1))
    if period in ("dusk", "night"):
        for L in s["lights"]:
            r = L["r"] * (0.75 if period == "dusk" else 1)
            cx, cy = L["x"], L["y"] + 14
            ys, xs = np.mgrid[0:Ht, 0:W]
            d = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2) / r
            # (the mockup's radial: full at the centre, 0.75 by a third, 0.25 by 0.7, nothing at the edge)
            k = np.interp(d, [0, 0.35, 0.7, 1.0], [1.0, 0.75, 0.25, 0.0])
            col = np.array(L["col"], dtype=float)
            lit = col[None, None, :] * k[..., None]
            lm = np.maximum(lm, lit)
    return lm


def lit_ground(ground, s, period):
    out = ground.copy()
    a = ~np.isnan(out[..., 0])
    lm = light_map(s, period)
    out[a] = out[a] * lm[a] / 255
    if period in ("dusk", "night"):
        for L in s["lights"]:                                      # the lamp's glass glows
            for y in range(L["y"] - 3, L["y"] + 3):
                for x in range(L["x"] - 3, L["x"] + 3):
                    if 0 <= y < Ht and 0 <= x < W and a[y, x] and ground[y, x].sum() > 400:
                        out[y, x] = (255, 236, 170)
    return out


def lit_near(near, s, period):
    out = hazed(near, period, "near")
    if period in ("dusk", "night"):
        for wx, wy in s["windows"]:
            for y in range(wy - 1, wy + 2):
                for x in range(wx - 1, wx + 2):
                    out[y, x] = (255, 206, 120) if period == "night" else (240, 186, 110)
    return out


def reflection(sky_img, far_p, near_p, water, wcol):
    """the sky, far and near mirrored about the far shore into the water (pulled down a third so the tree line shows)"""
    up = sky_img[:64].astype(float).copy()
    up = np.concatenate([up, np.zeros((Ht - 64, W, 3))])
    for lay in (far_p, near_p):
        a = ~np.isnan(lay[..., 0])
        up[a] = lay[a]
    rows = np.flatnonzero(water.any(axis=1))
    y0, y1 = int(rows[0]), int(rows[-1])
    out = np.zeros((y1 - y0 + 1, W, 4), dtype=np.uint8)
    for y in range(y0, y1 + 1):
        sy = int(round(HOR - (y - HOR) * 1.35))
        if sy < 0:
            continue
        row = up[sy] * 0.55 + np.array(wcol) * 0.45
        out[y - y0, :, :3] = np.clip(row, 0, 255).astype(np.uint8)
        out[y - y0, :, 3] = np.where(water[y], 184, 0)
    return y0, y1, out


def blades(kind, frames=4):
    """clumps of grass or reeds: the near corners and the front of your beast's platform, `frames` sway phases"""
    ramp = REEDS if kind == "reeds" else GRASS
    clumps = []
    for i in range(9):
        clumps.append((round(2 + i * 6.5 + H(i, 1, 4) * 4), 144, 3 + int(H(i, 2, 4) * 3), round(15 - i * 0.9 + H(i, 3, 4) * 4)))
    for i in range(8):
        clumps.append((round(238 - i * 6.5 - H(i, 4, 4) * 4), 144, 3 + int(H(i, 5, 4) * 3), round(14 - i * 0.9 + H(i, 6, 4) * 4)))
    for x, b, h in ((36, 108, 6), (46, 110, 5), (86, 110, 6), (97, 108, 5), (108, 112, 7), (24, 112, 7)):
        clumps.append((x, b, 3, h))
    y0 = 94                                                      # the strip's first row (layer coordinates)
    out = np.zeros((frames * 51, W, 4), dtype=np.uint8)
    for f in range(frames):
        ph = f / frames * 2 * math.pi
        for x0, base, n, hmax in clumps:
            for j in range(n):
                lean = (j - (n - 1) / 2) * 0.5
                h = max(2, round(hmax * (0.6 + 0.4 * H(x0, j, 3)) * (1 - abs(lean) * 0.3)))
                sway = math.sin(ph + x0 * 0.13 + j * 0.7) * 1.1
                for k in range(h):
                    t = k / h
                    x = round(x0 + j * 1.4 + lean * k * 0.55 + sway * t * t)
                    y = base - k - y0
                    if 0 <= x < W and 0 <= y < 51:
                        c = ramp[2] if k >= h - 2 else ramp[0] if k < h * 0.35 else ramp[1]
                        out[f * 51 + y, x, :3] = c
                        out[f * 51 + y, x, 3] = 255
    return y0, out


# ------------------------------------------------------------------------------------------------------ writing
FLAT = {   # scenes that keep their old picture: their lights for the beasts (screen coordinates, 224 wide)
    "mine": [(42, 26, 70, (255, 210, 110)), (154, 26, 70, (255, 210, 110))],
    "depths": [(20, 50, 90, (255, 110, 40)), (112, 50, 90, (255, 110, 40)), (204, 50, 90, (255, 110, 40))],
    "molten": [(60, 50, 90, (255, 110, 40)), (164, 50, 90, (255, 110, 40))],
    "room": [],
}


def digest():
    h = hashlib.sha1()
    for p in (__file__, AB.__file__, P.__file__, os.path.join(MEDIA, "atlas.tga")):
        h.update(open(p, "rb").read().replace(b"\r\n", b"\n"))
    return h.hexdigest()[:16]


def main():
    import gen_azeromon_ground as GG
    atlas = GG.Atlas()
    AB.W = W
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".tga"):
            os.remove(os.path.join(OUT, f))
    painters = [(k, (lambda k=k: base_scene(k, atlas))) for k in
                ("elwynn", "westfall", "duskwood", "jungle", "arena", "redridge", "steppes", "gorge")]
    painters += [("elwynn_town", lambda: spot_town(atlas)), ("elwynn_pond", lambda: spot_pond(atlas)),
                 ("elwynn_road", lambda: spot_road(atlas)), ("redridge_lake", lambda: spot_lake(atlas))]
    entries = []
    for key, paint in painters:
        far, near, ground, s = paint()
        seed = len(key) * 13
        own = s["bands"]
        dark_sky = key in ("duskwood", "steppes")             # (always a dim sky of their own)
        skies = {"day": own, "dusk": own if dark_sky else SKY_DUSK, "night": SKY_NIGHT, "rain": SKY_RAIN}
        info = []
        for p in PERIODS:
            sk = sky(skies[p], "day" if (dark_sky and p == "dusk") else p, seed, s.get("extra") if p == "day" or dark_sky else None)
            if s.get("moon") and p == "day":
                sk = sky(skies[p], "night", seed, s.get("extra"))           # Duskwood: its moon is always up
            save(sk, "%s_sky_%s" % (key, p), 256, 64)
            pl = "day" if (dark_sky and p == "dusk") else p          # (their own dim light all evening)
            far_p, near_p = hazed(far, pl, "far"), lit_near(near, s, pl)
            save(to_rgba(far_p, (0, 64)), "%s_far_%s" % (key, p), 256, 64)
            save(to_rgba(near_p, (0, 64)), "%s_near_%s" % (key, p), 256, 64)
            save(to_rgba(lit_ground(ground, s, pl), (GROUND_TOP, Ht)), "%s_ground_%s" % (key, p), 256, 128)
            if s["water"] is not None:
                y0, y1, refl = reflection(sk, far_p, near_p, s["water"], s["waterCol"])
                save(refl, "%s_refl_%s" % (key, p), 256, 32 if y1 - y0 < 32 else 64)
                info = (y0, y1)
        if s["water"] is not None:
            y0, y1 = info
            m = np.zeros((y1 - y0 + 1, W, 4), dtype=np.uint8)
            m[..., :3] = 255
            m[..., 3] = np.where(s["water"][y0:y1 + 1], 255, 0)
            save(m, "%s_wmask" % key, 256, 32 if y1 - y0 < 32 else 64)
        entries.append((key, s, info))
        print("painted", key)
    for kind in ("grass", "reeds"):
        y0, strip = blades(kind)
        save(strip, "blades_%s" % kind, 256, 256)
    write_lua(entries, y0)


def lua_list(items, fmt):
    return "{ %s }" % ", ".join(fmt % tuple(i) for i in items)


def write_lua(entries, blades_y0):
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/BattleScenes.lua", ...) then return end '
        "-- DisasterZone_Azeromon/BattleScenes.lua  (GENERATED by dev/generators/gen_azeromon_battle.py - do not edit)",
        "-- Battle scenes in layers (BattleScene.lua): Media/Battle/<scene>_<layer>_<period>.tga, layer coordinates 240 x 144",
        "-- (the screen shows x 8 .. 232), the horizon at row %d, the ground layer from row %d. Per scene: lights { x, y" % (HOR, GROUND_TOP),
        "-- of the glass, gx, gy the foot, reach, r, g, b }, windows { x, y }, smoke { x, y } (chimney tops), water",
        "-- { first row, last row, r, g, b } (its reflection and mask), blades (grass / reeds in front), flies (at night),",
        "-- clouds (the drifting strip by day). flat: underground or indoors, the old picture, with lights for the beasts.",
        "local addonName, ns = ...",
        "ns.AzeroBattleScenes = {",
        '    asset = %d, src = "%s", dir = "Interface\\\\AddOns\\\\DisasterZone_Azeromon\\\\Media\\\\Battle\\\\",' % (ASSET, digest()),
        "    w = %d, h = %d, horizon = %d, off = %d, groundTop = %d, bladesY = %d, bladesH = 51," % (W, Ht, HOR, OFF, GROUND_TOP, blades_y0),
        "    foe = { %d, %d }, ally = { %d, %d }, sun = { %d, %d }, moon = { %d, %d }," % (FOE[0], FOE[1], ALLY[0], ALLY[1],
                                                                                         SUN[0], SUN[1], MOON[0], MOON[1]),
        "    scenes = {",
    ]
    for key, s, info in entries:
        lights = lua_list([(L["x"], L["y"], L["gx"], L["gy"], L["r"]) + tuple(c / 255 for c in L["col"]) for L in s["lights"]],
                          "{ %d, %d, %d, %d, %d, %.3f, %.3f, %.3f }")
        parts = ["lights = %s" % lights, "windows = %s" % lua_list(s["windows"], "{ %d, %d }"),
                 "smoke = %s" % lua_list(s["smoke"], "{ %d, %d }")]
        if s["water"] is not None:
            parts.append("water = { %d, %d, %.3f, %.3f, %.3f }" % ((info[0], info[1]) + tuple(c / 255 for c in s["waterCol"])))
        if s.get("blades"):
            parts.append('blades = "%s"' % s["blades"])
        for flag in ("flies", "clouds", "foeReflects"):
            if s.get(flag):
                parts.append("%s = true" % flag)
        lines.append("        %s = { %s }," % (key, ", ".join(parts)))
    for key, ls in FLAT.items():
        lines.append("        %s = { flat = true, lights = %s }," % (
            key, lua_list([(x + OFF, y, x + OFF, y + 30, r) + tuple(c / 255 for c in col) for x, y, r, col in ls],
                          "{ %d, %d, %d, %d, %d, %.3f, %.3f, %.3f }")))
    lines += [
        "    },",
        "    -- where you stand: a zone's spots (BattleScene.SpotFor picks one from the tiles round you)",
        '    spots = { elwynn = { town = "elwynn_town", pond = "elwynn_pond", road = "elwynn_road" }, redridge = { lake = "redridge_lake" } },',
        "}",
    ]
    with open(LUA, "w", newline="\n", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote BattleScenes.lua", len(entries), "scenes")


if __name__ == "__main__":
    main()
