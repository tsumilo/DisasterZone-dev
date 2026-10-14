"""Azeromon battle backdrops (the world art pass): one painted scene per zone at the battle screen's pixel size
(UI.lua SW x SH / 3: 224 x 144 game pixels), drawn by the game at 3x like the world.

Each scene: a banded sky with pixel clouds (or a rock wall underground, or a room's wall indoors), a hazy far
layer and a nearer one (tree lines, hills, palms, the arena's wall), ground in the zone's own style, and the two
platforms the beasts stand on, with a rim and a shadow. Clouds also come as a separate seamless strip the game
drifts across the sky. Platform centres (FOE, ALLY) are exported so the game puts the beasts exactly on them."""
import math

import numpy as np

from azeromon_props import H

W, Ht = 224, 144                     # the battle screen in game pixels (672 x 432 at 3x)
HORIZON = 56                         # where the ground meets the far layer
FOE = (166, 59, 27, 7)               # platform centre x, y and radii (the foe, far away)
ALLY = (58, 99, 32, 8)               # (the player's beast, near)

SCENES = {
    "elwynn": dict(sky=[(110, 172, 226), (148, 198, 236), (186, 220, 240), (214, 234, 240)], far=(120, 166, 150),
                   near=(58, 112, 66), nearHi=(84, 140, 80), ground="grass1", ground2="grass2", rim=(108, 74, 44),
                   haze=(200, 226, 222), clouds=True, layer="trees"),
    "westfall": dict(sky=[(132, 184, 222), (172, 206, 228), (214, 220, 210), (240, 228, 196)], far=(196, 176, 120),
                     near=(170, 140, 76), nearHi=(200, 170, 100), ground="wgrass1", ground2="wgrass2",
                     rim=(120, 86, 46), haze=(236, 222, 190), clouds=True, layer="hills"),
    "duskwood": dict(sky=[(30, 28, 56), (48, 44, 80), (78, 70, 110), (112, 100, 136)], far=(46, 54, 70),
                     near=(22, 34, 38), nearHi=(34, 50, 52), ground="dgrass1", ground2="dgrass2", rim=(56, 46, 40),
                     haze=(96, 100, 128), clouds=False, moon=True, layer="pines", mist=True),
    "jungle": dict(dim=(0.82, 0.86, 0.84), sky=[(96, 178, 214), (136, 202, 222), (184, 224, 226), (216, 238, 226)], far=(92, 150, 116),
                   near=(34, 96, 54), nearHi=(58, 130, 64), ground="jgrass1", ground2="jgrass2", rim=(126, 64, 40),
                   haze=(196, 226, 210), clouds=True, layer="palms"),
    "mine": dict(ground="mfloor1", ground2="mfloor2", rim=(60, 50, 46), haze=(40, 34, 32), layer="cave"),
    "arena": dict(sky=[(120, 176, 220), (160, 200, 228), (206, 222, 226), (238, 230, 210)], far=(196, 170, 130),
                  near=(150, 120, 86), nearHi=(176, 146, 106), ground="sand1", ground2="sand2", rim=(150, 116, 70),
                  haze=(236, 224, 200), clouds=True, layer="arena"),
    "room": dict(ground=None, rim=(78, 48, 32), layer="room"),
}
SCENE_OF = {"room": "room", None: "elwynn", "elwynn": "elwynn", "westfall": "westfall", "duskwood": "duskwood", "jungle": "jungle",
            "mine": "mine", "arena": "arena", "hall": "room"}


def _vn(x, y, s):
    x0, y0 = math.floor(x), math.floor(y)
    fx, fy = x - x0, y - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b, c, d = H(x0, y0, s), H(x0 + 1, y0, s), H(x0, y0 + 1, s), H(x0 + 1, y0 + 1, s)
    return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy


def _sky(img, bands, top, bottom):
    """banded sky, dithered where bands meet"""
    n = len(bands)
    bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
    for y in range(top, bottom):
        f = (y - top) / max(1, bottom - top) * (n - 1)
        i = min(n - 2, int(f))
        frac = f - i
        for x in range(W):
            th = bayer[(y & 3) * 4 + (x & 3)] / 16.0
            # a short dithered blend where two bands meet, solid colour elsewhere
            k = min(1.0, max(0.0, (frac - 0.7) / 0.3))
            img[y, x] = bands[i + 1] if k > th else bands[i]


def _cloud(img, cx, cy, w, h, s, hi=(250, 252, 255), lo=(214, 226, 238)):
    for y in range(cy - h, cy + h + 1):
        for x in range(cx - w, cx + w + 1):
            if not (0 <= x < W and 0 <= y < Ht):
                continue
            d = ((x - cx) / w) ** 2 + ((y - cy) / h) ** 2 * 1.6
            bump = _vn(x / 5, 0, s) * 0.5
            if d < 0.75 + bump * 0.6 and y <= cy + h * 0.5:
                img[y, x] = lo if y > cy + h * 0.1 else hi


def clouds_strip(w=256, h=48):
    """clouds on clear, repeating sideways (the game drifts them across the sky)"""
    out = np.zeros((h, w, 4), dtype=np.uint8)
    for i, (cx, cy, cw, ch) in enumerate(((30, 14, 22, 7), (110, 26, 30, 8), (190, 12, 18, 6), (238, 30, 16, 5))):
        tmp = np.zeros((Ht, W, 3))
        mark = np.zeros((Ht, W), dtype=bool)
        for y in range(cy - ch, cy + ch + 1):
            for x in range(cx - cw, cx + cw + 1):
                d = ((x - cx) / cw) ** 2 + ((y - cy) / ch) ** 2 * 1.6
                if d < 0.75 + _vn(x / 5, 0, i) * 0.3 and y <= cy + ch * 0.5 and 0 <= y < h:
                    xx = x % w
                    out[y, xx, :3] = (214, 226, 238) if y > cy + ch * 0.1 else (250, 252, 255)
                    out[y, xx, 3] = 255
    return out


def _far_layer(img, kind, col, hi, base_y, seed):
    """a silhouette along base_y: rounded canopies, pines, palms, hills or the arena's wall"""
    for x in range(W):
        if kind == "trees":
            top = base_y - 9 - int(6 * _vn(x / 7, 0, seed) + 3 * _vn(x / 2.5, 1, seed))
        elif kind == "pines":
            ph = (x + int(H(x // 9, 0, seed) * 4)) % 9
            top = base_y - 6 - int(10 * _vn(x / 9, 0, seed)) - (4 - abs(ph - 4)) * 2
        elif kind == "palms":
            top = base_y - 8 - int(7 * _vn(x / 6, 0, seed))
        elif kind == "hills":
            top = base_y - 4 - int(10 * _vn(x / 26, 0, seed))
        elif kind == "arena":
            top = base_y - 22 + (3 if (x // 6) % 2 else 0)            # crenellations
        else:
            top = base_y
        for y in range(max(0, top), base_y + 1):
            c = col
            if kind in ("trees", "palms") and y < top + 2 and H(x, y, seed) < 0.5:
                c = hi
            if kind == "arena":
                c = col if ((x + (4 if (y // 4) % 2 else 0)) % 12 and y % 4) else hi
            img[y, x] = c


def _palms(img, near, hi, base_y, seed):
    for i, x0 in enumerate((14, 82, 128, 200)):
        h = 26 + int(H(i, 2, seed) * 8)
        for k in range(h):
            x = x0 + int(math.sin(k * 0.12 + i) * 2)
            img[base_y - k, x] = (110, 80, 50)
            img[base_y - k, x + 1] = (86, 60, 38)
        cx, cy = x0 + int(math.sin(h * 0.12 + i) * 2), base_y - h
        for a in range(7):
            ang = -math.pi + a * math.pi / 6
            for r in range(1, 10):
                xx = int(cx + math.cos(ang) * r)
                yy = int(cy + math.sin(ang) * r * 0.6 + r * r * 0.05)
                if 0 <= xx < W and 0 <= yy < Ht:
                    img[yy, xx] = hi if r < 5 else near


def _ground(img, atlas, scene, top, seed):
    g1 = atlas.tile(scene["ground"])[..., :3]
    g2 = atlas.tile(scene["ground2"])[..., :3]
    for y in range(top, Ht):
        for x in range(W):
            t = g2 if H(x // 16, y // 16, seed) < 0.18 else g1
            c = t[y % 16, x % 16].copy()
            v = 0.6 * _vn(x / 40, y / 22, seed + 3) + 0.4 * _vn(x / 13, y / 8, seed + 4)
            if v < 0.36:
                c = c * [0.86, 0.9, 0.92]
            elif v > 0.66:
                c = c * [1.05, 1.04, 0.92] + [10, 6, 0]
            c = c * scene.get("dim", (1, 1, 1))
            # the near ground a touch darker, the far ground lighter and hazier
            c = c * (1 - 0.1 * (y - top) / (Ht - top))
            k = max(0.0, 1 - (y - top) / 34) * 0.45
            c = c * (1 - k) + np.array(scene["haze"]) * k
            img[y, x] = c


def _decor(img, scene, top, seed):
    pal = {"elwynn": [((250, 248, 232), (240, 196, 64)), ((236, 128, 170), (255, 230, 120))],
           "westfall": [((246, 214, 70), (214, 150, 40))], "jungle": [((214, 48, 60), (252, 214, 90))],
           "duskwood": [((150, 92, 204), (222, 196, 255))], "arena": [], "mine": []}
    flowers = pal.get(scene.get("name"), [])
    for i in range(70):
        x = int(H(i, 1, seed) * W)
        y = top + 6 + int(H(i, 2, seed) * (Ht - top - 8))
        if not flowers:
            if H(i, 3, seed) < 0.5:                                     # pebbles
                img[y, x] = (176, 170, 156)
                img[min(Ht - 1, y + 1), min(W - 1, x + 1)] = (100, 96, 88)
            continue
        if H(i, 4, seed) < 0.55:
            pet, mid = flowers[i % len(flowers)]
            for dx, dy in ((0, -1), (-1, 0), (1, 0), (0, 1)):
                xx, yy = x + dx, y + dy
                if 0 <= xx < W and top < yy < Ht:
                    img[yy, xx] = pet
            img[y, x] = mid
        else:                                                           # a grass tuft
            for dx, h in ((-1, 2), (0, 3), (1, 2)):
                for k in range(h):
                    if 0 <= x + dx < W and top < y - k < Ht:
                        img[y - k, x + dx] = img[y - k, x + dx] * 0.72


def _platform(img, cx, cy, rx, ry, top_col, rim, seed):
    """a raised oval of ground: lit top, a rim of earth below it, a shadow on the field"""
    for y in range(int(cy - ry - 1), int(cy + ry + 6)):
        for x in range(int(cx - rx - 2), int(cx + rx + 3)):
            if not (0 <= x < W and 0 <= y < Ht):
                continue
            d_sh = ((x + 0.5 - cx - 2) / (rx + 2)) ** 2 + ((y + 0.5 - cy - 4) / (ry + 1.5)) ** 2
            if d_sh <= 1:
                img[y, x] = img[y, x] * 0.66                             # shadow
    for y in range(int(cy - ry), int(cy + ry + 4)):
        for x in range(int(cx - rx - 1), int(cx + rx + 2)):
            if not (0 <= x < W and 0 <= y < Ht):
                continue
            d_rim = ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy - 3) / ry) ** 2
            d_top = ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2
            if d_top <= 1:
                k = 1.12 if (x - cx) / rx + (y - cy) / ry * 0.8 < -0.4 else 1.0
                c = np.array(top_col) * k
                if d_top > 0.78:
                    c = c * 0.86                                         # the edge of the top
                if H(x, y, seed) < 0.08:
                    c = c * 0.82
                img[y, x] = c
            elif d_rim <= 1 and y > cy:
                c = np.array(rim)
                if (x + y) % 5 == 0:
                    c = c * 0.8
                img[y, x] = c if d_rim < 0.8 else c * 0.7


def scene(theme, atlas, interiors=None):
    """the battle backdrop for a map theme -> (Ht, W, 3) uint8"""
    key = SCENE_OF.get(theme, "elwynn")
    sc = dict(SCENES[key], name=key)
    img = np.zeros((Ht, W, 3))
    seed = len(key) * 7
    if key == "room":
        floor = interiors.floor(W, Ht - 40, seed=3)
        img[40:] = floor
        img[:40] = interiors.back_wall(W, 0, 40, seed=3)[:40]
        for k, f in ((0, 0.62), (1, 0.72), (2, 0.82)):
            img[40 + k] *= f
        top_col, rim = (156, 50, 46), (90, 30, 30)                       # rugs for platforms
    elif key == "mine":
        for y in range(HORIZON):
            for x in range(W):
                n = _vn(x / 6, y / 4, 5)
                c = np.array((58, 50, 46)) * (0.75 + n * 0.5)
                if (x // 28) % 2 == 0 and x % 28 in (0, 1, 2) and y > 8:
                    c = np.array((96, 66, 40)) if x % 28 != 2 else np.array((70, 48, 30))   # timber
                if y in (10, 11) and (x // 28) % 2 == 0:
                    c = np.array((96, 66, 40))
                img[y, x] = c
        for lx in (42, 154):                                             # lanterns
            for dy in range(-12, 13):
                for dx in range(-12, 13):
                    d = math.hypot(dx, dy)
                    if d < 12 and 0 <= 26 + dy < HORIZON:
                        img[26 + dy, lx + dx] = np.minimum(255, img[26 + dy, lx + dx] + np.array((60, 40, 14)) * (1 - d / 12))
            img[24:28, lx - 1:lx + 2] = (255, 210, 110)
        _ground(img, atlas, dict(sc, haze=(60, 50, 44)), HORIZON, seed)
        top_col, rim = (120, 104, 92), sc["rim"]
    else:
        _sky(img, sc["sky"], 0, HORIZON)
        if sc.get("moon"):
            for y in range(6, 20):
                for x in range(168, 182):
                    if (x - 175) ** 2 + (y - 13) ** 2 <= 36:
                        img[y, x] = (236, 232, 210) if (x - 177) ** 2 + (y - 11) ** 2 > 30 else (210, 206, 190)
        # (the clouds are the game's drifting strip, battle_clouds.tga, not painted here)
        _far_layer(img, sc["layer"] if sc["layer"] != "palms" else "trees", sc["far"],
                   tuple(min(255, v + 18) for v in sc["far"]), HORIZON - 4, seed)
        if sc["layer"] in ("trees", "pines"):
            _far_layer(img, sc["layer"], sc["near"], sc["nearHi"], HORIZON, seed + 9)
        elif sc["layer"] == "palms":
            _far_layer(img, "trees", sc["near"], sc["nearHi"], HORIZON, seed + 9)
            _palms(img, sc["near"], sc["nearHi"], HORIZON, seed)
        _ground(img, atlas, sc, HORIZON, seed)
        if sc.get("mist"):
            for y in range(HORIZON - 6, HORIZON + 14):
                for x in range(W):
                    k = (1 - abs(y - HORIZON - 3) / 11) * 0.35 * (0.6 + 0.4 * _vn(x / 20, y / 6, 8))
                    if k > 0 and ((x + y) % 2 == 0 or k > 0.2):
                        img[y, x] = img[y, x] * (1 - k) + np.array((170, 180, 210)) * k
        t1 = atlas.tile(sc["ground"])[..., :3].reshape(-1, 3).mean(0)
        dim = sc.get("dim", (1, 1, 1))
        top_col, rim = tuple(min(255, v * 1.04 * d + 6) for v, d in zip(t1, dim)), sc["rim"]
    _decor(img, sc, HORIZON if key != "room" else 40, seed)
    for cx, cy, rx, ry in (FOE, ALLY):
        _platform(img, cx, cy, rx, ry, top_col, rim, seed)
    return np.clip(np.round(img), 0, 255).astype(np.uint8)


THEMES = sorted(set(SCENE_OF.values()))
