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
    # Blackrock (0.25; the approved mockup's scenes.py): the atlas' own ground tiles re-ramped to the zone's colours
    "redridge": dict(bk=True, sky=[(100, 160, 214), (140, 186, 224), (190, 210, 222), (226, 222, 204)], haze=(214, 200, 180),
                     tile="grass1", tile2="wgrass1", ramp=((126, 110, 50), (186, 160, 70)), ramp2=((150, 100, 44), (210, 150, 70)),
                     rim=(110, 66, 40), feature="pools", water=(70, 120, 150),
                     decor=[("flower", (230, 120, 40), (255, 220, 120)), ("tuft",), ("flower", (200, 60, 40), (250, 200, 100))],
                     cl=((252, 250, 244), (222, 220, 214))),
    "steppes": dict(bk=True, sky=[(40, 26, 26), (80, 40, 30), (140, 66, 36), (200, 104, 50)], haze=(120, 76, 60),
                    tile="mfloor1", tile2="mfloor2", ramp=((44, 40, 40), (94, 86, 80)), rim=(40, 30, 28), feature="lava",
                    decor=[("ember",), ("pebble", (90, 84, 80)), ("bone",)]),
    "gorge": dict(bk=True, sky=[(150, 110, 90), (190, 140, 100), (220, 170, 120), (236, 200, 150)], haze=(220, 170, 130),
                  tile="sand1", tile2="mfloor1", ramp=((150, 84, 46), (214, 140, 76)), ramp2=((120, 70, 44), (180, 110, 64)),
                  rim=(110, 60, 36), decor=[("pebble", (170, 110, 70)), ("pebble", (90, 70, 60))]),
    "molten": dict(bk=True, cave=True, wall=(84, 34, 24), haze=(120, 50, 30), tile="mfloor1", tile2="mfloor2",
                   ramp=((60, 30, 24), (140, 80, 56)), rim=(60, 26, 20), feature="lava",
                   decor=[("ember",), ("ember",), ("pebble", (110, 70, 60))]),
    "depths": dict(bk=True, cave=True, wall=(50, 40, 40), haze=(70, 44, 36), tile="mfloor1", tile2="mfloor2",
                   ramp=((46, 38, 38), (100, 82, 74)), rim=(40, 30, 28), feature="lava",
                   decor=[("ember",), ("pebble", (90, 80, 74))]),
}
# map theme -> scene; a map id here overrides its theme (the Molten Core is a blackrock cave with its own scene).
# Ground.lua's AzeroBattleArt.scenes carries both (UI.lua looks the map id up first).
SCENE_OF = {"room": "room", None: "elwynn", "elwynn": "elwynn", "westfall": "westfall", "duskwood": "duskwood", "jungle": "jungle",
            "mine": "mine", "arena": "arena", "hall": "room", "redridge": "redridge", "steppes": "steppes", "gorge": "gorge",
            "blackrock": "depths", "moltencore": "molten"}


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
    """the battle backdrop for a map theme (or a scene's own name) -> (Ht, W, 3) uint8"""
    key = SCENE_OF.get(theme, theme if theme in SCENES else "elwynn")
    if SCENES[key].get("bk"):
        return _bk_scene(key, atlas)
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


# ------------------------------------------------------------------------------------ Blackrock's scenes (0.25)
# Ported from the approved mockup (dev/art/casc/zone_mockup/scenes.py): ridges, autumn trees, a dark peak, lava
# falls in the caves, the ground as the atlas' tiles re-ramped to two colours, lava cracks or pools, embers.

def _mix(a, b, k):
    return tuple(a[i] * (1 - k) + b[i] * k for i in range(3))


def _ramp_tile(atlas, name, lo, hi):
    t = atlas.tile(name)[..., :3]
    L = t.mean(2)
    lo_, hi_ = np.percentile(L, 3), np.percentile(L, 97)
    L = np.clip((L - lo_) / max(1, hi_ - lo_), 0, 1) * 0.8 + 0.1
    return np.array(lo)[None, None, :] * (1 - L[..., None]) + np.array(hi)[None, None, :] * L[..., None]


def _ridge(img, base_y, col, hi, seed, kind, amp=10, scale=20):
    for x in range(W):
        if kind == "crags":
            top = base_y - 4 - int(amp * _vn(x / scale, 0, seed) + amp * 0.5 * abs(math.sin(x * 0.37 + seed)) * _vn(x / 5, 2, seed))
        else:                                  # mesas
            v = _vn(x / scale, 0, seed)
            top = base_y - (amp if v > 0.5 else int(amp * 0.25 + 2 * _vn(x / 4, 1, seed)))
        for y in range(max(0, top), base_y + 1):
            c = col
            if y < top + 2 and H(x, y, seed) < 0.6:
                c = hi
            if kind == "mesas" and (x * 3 + y) % 9 == 0 and y > top + 2:
                c = _mix(col, (0, 0, 0), 0.15)
            img[y, x] = c


def _trees(img, base_y, col, hi, seed, kind="round", step=7):
    for x in range(W):
        if kind == "round":
            top = base_y - 9 - int(6 * _vn(x / step, 0, seed) + 3 * _vn(x / 2.5, 1, seed))
        else:
            ph = (x + int(H(x // 9, 0, seed) * 4)) % 9
            top = base_y - 6 - int(10 * _vn(x / 9, 0, seed)) - (4 - abs(ph - 4)) * 2
        for y in range(max(0, top), base_y + 1):
            img[y, x] = hi if (y < top + 2 and H(x, y, seed) < 0.5) else col


def _glow(img, cx, cy, r, col, k=0.6):
    for y in range(max(0, cy - r), min(Ht, cy + r)):
        for x in range(max(0, cx - r), min(W, cx + r)):
            d = math.hypot(x - cx, (y - cy) * 1.3) / r
            if d < 1:
                img[y, x] = img[y, x] * (1 - k * (1 - d)) + np.array(col) * k * (1 - d)


def _peak(img, cx, base_y, h, col, hi):
    for y in range(base_y - h, base_y + 1):
        hw = int((y - (base_y - h)) * 1.6 + 2 * _vn(y / 3, 0, 4))
        for x in range(cx - hw, cx + hw):
            if 0 <= x < W:
                img[y, x] = hi if x < cx else col


def _mist(img, y0, y1, col, k0=0.35, seed=8):
    for y in range(y0, y1):
        for x in range(W):
            mid = (y0 + y1) / 2
            k = (1 - abs(y - mid) / ((y1 - y0) / 2)) * k0 * (0.6 + 0.4 * _vn(x / 20, y / 6, seed))
            if k > 0 and ((x + y) % 2 == 0 or k > 0.2):
                img[y, x] = img[y, x] * (1 - k) + np.array(col) * k


def _bk_ground(img, atlas, sc, top, seed):
    g1 = _ramp_tile(atlas, sc["tile"], *sc["ramp"])
    g2 = _ramp_tile(atlas, sc.get("tile2", sc["tile"]), *sc.get("ramp2", sc["ramp"]))
    for y in range(top, Ht):
        for x in range(W):
            b = min(1.0, max(0.0, (_vn(x / 34, y / 12, seed + 11) - 0.5) * 4 + 0.5))
            c = g1[y % 16, x % 16] * (1 - b) + g2[(y + 5) % 16, (x + 7) % 16] * b
            v = 0.6 * _vn(x / 40, y / 22, seed + 3) + 0.4 * _vn(x / 13, y / 8, seed + 4)
            if v < 0.36:
                c = c * 0.88
            elif v > 0.66:
                c = c * 1.05 + 6
            c = c * (1 - 0.12 * (y - top) / (Ht - top))
            k = max(0.0, 1 - (y - top) / 34) * 0.45
            img[y, x] = c * (1 - k) + np.array(sc["haze"]) * k
    f = sc.get("feature")
    if f == "pools":
        for i in range(5):
            cx, cy = int(H(i, 7, seed) * W), top + 10 + int(H(i, 8, seed) * (Ht - top - 14))
            rx, ry = 10 + int(H(i, 9, seed) * 16), 3 + int(H(i, 10, seed) * 3)
            for y in range(cy - ry, cy + ry + 1):
                for x in range(cx - rx, cx + rx + 1):
                    if 0 <= x < W and top < y < Ht:
                        d = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2
                        if d < 0.85 + 0.3 * _vn(x / 4, y / 2, i):
                            c = np.array(sc["water"]) * (0.9 + 0.2 * _vn(x / 6, y, i))
                            if (x + y * 3) % 17 == 0:
                                c = c + 40
                            img[y, x] = c
                        elif d < 1.15 and H(x, y, i) < 0.4:
                            img[y, x] = img[y, x] * 0.75
    if f == "lava":
        col = (255, 128, 36)
        for i in range(6):
            x, y = H(i, 3, seed) * W, top + 8 + H(i, 4, seed) * (Ht - top - 12)
            ang = (H(i, 6, seed) - 0.5) * 0.6
            n = 26 + int(H(i, 5, seed) * 30)
            for k in range(n):
                ang += (H(i, k, 1) - 0.5) * 0.9
                x += math.cos(ang) * 1.4
                y += math.sin(ang) * 0.5
                xi, yi = int(x), int(y)
                wdt = 2 if 4 < k < n - 6 else 1
                for dy in range(wdt):
                    if 0 <= xi < W and top < yi + dy < Ht:
                        img[yi + dy, xi] = col
                if 0 <= xi < W and top < yi - 1 < Ht:
                    img[yi - 1, xi] = _mix(img[yi - 1, xi], (255, 190, 90), 0.5)
            _glow(img, int(x), int(y), 10, (255, 90, 20), 0.35)


def _bk_decor(img, sc, top, seed):
    kinds = sc.get("decor", [])
    for i in range(80):
        x = int(H(i, 1, seed) * W)
        y = top + 6 + int(H(i, 2, seed) * (Ht - top - 8))
        kd = kinds[i % len(kinds)]
        if kd[0] == "flower":
            for dx, dy in ((0, -1), (-1, 0), (1, 0), (0, 1)):
                if 0 <= x + dx < W and top < y + dy < Ht:
                    img[y + dy, x + dx] = kd[1]
            img[y, x] = kd[2]
        elif kd[0] == "tuft":
            for dx, h in ((-1, 2), (0, 3), (1, 2)):
                for k in range(h):
                    if 0 <= x + dx < W and top < y - k < Ht:
                        img[y - k, x + dx] = img[y - k, x + dx] * 0.7
        elif kd[0] == "pebble":
            img[y, x] = kd[1]
            if x + 1 < W and y + 1 < Ht:
                img[y + 1, x + 1] = _mix(kd[1], (0, 0, 0), 0.45)
        elif kd[0] == "bone":
            for dx in range(-1, 2):
                if 0 <= x + dx < W:
                    img[y, x + dx] = (226, 220, 200)
        elif kd[0] == "ember":
            img[y, x] = (255, 170, 60)


def _bk_scene(key, atlas):
    sc = SCENES[key]
    seed = sum(map(ord, key))
    img = np.zeros((Ht, W, 3))
    if sc.get("cave"):
        for y in range(HORIZON):
            for x in range(W):
                img[y, x] = np.array(sc["wall"]) * (0.7 + _vn(x / 6, y / 4, 5) * 0.5)
        for cx in ((20, 112, 204) if key != "molten" else (10, 60, 112, 164, 214)):     # lava falls
            for y in range(4, HORIZON):
                for dx in range(-2, 3):
                    v = 0.7 + 0.3 * math.sin(y * 0.8 + dx)
                    if 0 <= cx + dx < W:
                        img[y, cx + dx] = (255 * v, 120 * v, 30 * v)
            _glow(img, cx, HORIZON - 6, 28, (255, 90, 20), 0.7)
        for cx in (66, 158):                                              # chains
            for y in range(0, 34):
                if y % 3:
                    img[y, cx] = (30, 26, 26)
                    img[y, cx + 1] = (70, 60, 58)
    else:
        _sky(img, sc["sky"], 0, HORIZON)
        if "cl" in sc:
            for i, (cx, cy, w, h) in enumerate(((40, 12, 20, 6), (150, 20, 28, 7), (206, 8, 14, 4))):
                _cloud(img, cx, cy, w, h, seed + i, hi=sc["cl"][0], lo=sc["cl"][1])
    if key == "redridge":
        _ridge(img, HORIZON - 8, (130, 140, 170), (156, 164, 190), seed, "crags", amp=24, scale=18)
        _trees(img, HORIZON - 2, (176, 84, 40), (220, 130, 50), seed, "round")
        _trees(img, HORIZON + 1, (140, 60, 34), (196, 100, 40), seed + 9, "pines")
    elif key == "steppes":
        _glow(img, 112, HORIZON, 120, (255, 90, 30), 0.35)
        _peak(img, 70, HORIZON - 2, 50, (30, 26, 28), (44, 38, 40))
        _ridge(img, HORIZON, (40, 34, 34), (60, 50, 48), seed, "crags", amp=16, scale=12)
        for i in range(40):
            img[int(H(i, 2, 7) * HORIZON), int(H(i, 1, 7) * W)] = (255, 170, 70)
        _mist(img, HORIZON - 8, HORIZON + 8, (110, 80, 70), 0.35)
    elif key == "gorge":
        _ridge(img, HORIZON - 4, (190, 120, 80), (214, 150, 100), seed, "mesas", amp=34, scale=26)
        _ridge(img, HORIZON, (150, 84, 50), (180, 110, 70), seed + 5, "mesas", amp=18, scale=14)
    _bk_ground(img, atlas, sc, HORIZON, seed)
    _bk_decor(img, sc, HORIZON, seed)
    t1 = _ramp_tile(atlas, sc["tile"], *sc["ramp"]).reshape(-1, 3).mean(0)
    top_col = tuple(min(255, v * 1.08 + 8) for v in t1)
    for cx, cy, rx, ry in (FOE, ALLY):
        _platform(img, cx, cy, rx, ry, top_col, sc["rim"], seed)
    return np.clip(np.round(img), 0, 255).astype(np.uint8)
