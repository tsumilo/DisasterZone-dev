"""Where each shipped floor map lies in the world, measured against the geometry: the picture's drawn walls against the
outline of the floors the game has at that level (the WMO's faces turned up, and terrain).

The pictures we ship (wowhead's maps of the TBC zones) are not always framed like the client's UiMapAssignment says:
Karazhan's upper floors are 30 - 100 yd off, and wowhead's own creature spots for some bosses are those of later
remakes (Zul'Aman's), so neither can be trusted alone. This aligns the picture with what the 3D view draws.

Per floor: the level is the height of a boss of that floor (its AzerothCore spawn); the floors within LEVEL of it, in
a window round the UiMapAssignment rectangle, are drawn into a 1 yd mask and their outline taken. The picture's edges
(blurred gradient). For each scale (the picture's height in yards, around UiMapAssignment's) the outline is drawn in
picture pixels and cross-correlated with the edges by FFT: the peak is the best shift. The best scale and shift give
the frame (north up, square pixels: x = xMax - s v, y = yMax - 1.5 s u).

-> art/rooms/floor_register.json: { mapfile: { xMin, xMax, yMin, yMax, score, scale, shift, uimap_diff } }
Run: luaenv\\Scripts\\python.exe generators\\floor_register.py [mapfile ...] [--png]
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_rooms as R  # noqa: E402
import floor_fits as F  # noqa: E402

ART = os.path.join(HERE, "..", "art", "blizzard_maps")
OUT = os.path.join(R.CACHE, "floor_register.json")
SOURCE = {"Gruul": "3923-1", "Magtheridon": "3836-1", "Serpentshrine": "3607-1", "TheEye": "3845-1", "Hyjal": "3606",
          "ZulAman": "3805", "Sunwell": "4075-1", "Sunwell0": "4075"}
SOURCE.update({"Kara%02d" % i: "3457-%d" % i for i in range(1, 18)})
SOURCE.update({"BT%02d" % i: ("3959-%d" % i if i else "3959") for i in range(0, 8)})
LEVEL_DOWN, LEVEL_UP = 6.0, 5.0


def edges(path):
    im = np.asarray(Image.open(path).convert("L"), dtype=np.float64) / 255.0
    # blur (separable box x3 ~ gaussian), then gradient magnitude
    k = np.ones(3) / 3.0
    for _ in range(2):
        im = np.apply_along_axis(lambda r: np.convolve(r, k, mode="same"), 1, im)
        im = np.apply_along_axis(lambda c: np.convolve(c, k, mode="same"), 0, im)
    gy, gx = np.gradient(im)
    g = np.hypot(gx, gy)
    g = np.clip(g / (np.percentile(g, 99) + 1e-9), 0, 1)
    return g - g.mean()


def outline(faces, box, zlo, zhi):
    """World points on the outline of the floors in a height band: a 1 yd mask's border cells."""
    x0, y0, x1, y1 = box
    W, H = int(y1 - y0) + 1, int(x1 - x0) + 1
    mask = np.zeros((H, W), dtype=bool)
    for _, pts, _ in faces:
        (ax, ay, az), (bx, by, bz), (cx, cy, cz) = (p[:3] for p in pts)
        if max(az, bz, cz) < zlo or min(az, bz, cz) > zhi:
            continue
        n = R.G.normal((ax, ay, az), (bx, by, bz), (cx, cy, cz))
        if not n or n[2] < 0.6:
            continue
        # cells whose centres lie in the triangle (grid: row = x1 - wx, col = y1 - wy)
        r0, r1 = int(max(0, math.floor(x1 - max(ax, bx, cx)))), int(min(H - 1, math.ceil(x1 - min(ax, bx, cx))))
        c0, c1 = int(max(0, math.floor(y1 - max(ay, by, cy)))), int(min(W - 1, math.ceil(y1 - min(ay, by, cy))))
        if r1 < r0 or c1 < c0:
            continue
        rr, cc = np.mgrid[r0:r1 + 1, c0:c1 + 1]
        px, py = x1 - (rr + 0.5), y1 - (cc + 0.5)
        d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(d) < 1e-9:
            continue
        w1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / d
        w2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / d
        inside = (w1 >= 0) & (w2 >= 0) & (w1 + w2 <= 1)
        mask[rr[inside], cc[inside]] = True
    er = mask.copy()
    er[1:, :] &= mask[:-1, :]
    er[:-1, :] &= mask[1:, :]
    er[:, 1:] &= mask[:, :-1]
    er[:, :-1] &= mask[:, 1:]
    border = mask & ~er
    rr, cc = np.nonzero(border)
    return x1 - (rr + 0.5), y1 - (cc + 0.5), mask


def register(mapfile, level_z, png=False):
    x0u, y0u, _, x1u, y1u, _ = R.uimap_rect(R.UIMAP[mapfile])
    zone, _ = F.FLOORS[mapfile]
    raid = next(k for k, v in R.RAIDS.items() if v[0] == F.ZONE_MAP[zone])
    mapdir = R.RAIDS[raid][1]
    pad = 0.25 * max(x1u - x0u, y1u - y0u)
    box = (x0u - pad, y0u - pad, x1u + pad, y1u + pad)
    pls, has_terrain = R.placements(mapdir, box)
    faces = []
    for pl in pls:
        faces += R.wmo_faces(pl, box, level_z - LEVEL_DOWN - 1, level_z + LEVEL_UP + 1)
    if has_terrain:
        faces += R.terrain_faces(mapdir, box, 2)
    wx, wy, mask = outline(faces, box, level_z - LEVEL_DOWN, level_z + LEVEL_UP)
    if len(wx) < 50:
        return None
    G = edges(os.path.join(ART, SOURCE[mapfile] + ".jpg"))
    Hi, Wi = G.shape
    PH, PW = 2 * Hi, 2 * Wi                          # padded: shifts up to half the picture
    FG = np.fft.rfft2(G, s=(PH, PW))
    s0 = x1u - x0u                                   # UiMapAssignment's height in yards
    best = None
    for k in np.arange(0.70, 1.45, 0.01):
        s = s0 * k
        # outline in picture pixels with the frame's top-left corner at UiMapAssignment's (shift found by FFT)
        pu = (y1u - wy) / (1.5 * s) * Wi
        pv = (x1u - wx) / s * Hi
        img = np.zeros((PH, PW))
        iu = np.round(pu).astype(int) + Wi // 2
        iv = np.round(pv).astype(int) + Hi // 2
        ok = (iu >= 0) & (iu < PW) & (iv >= 0) & (iv < PH)
        np.add.at(img, (iv[ok], iu[ok]), 1.0)
        corr = np.fft.irfft2(FG * np.conj(np.fft.rfft2(img)), s=(PH, PW))
        score = corr.max() / max(1, ok.sum())
        if best is None or score > best[0]:
            dv, du = np.unravel_index(corr.argmax(), corr.shape)
            best = (score, s, du, dv)
    score, s, du, dv = best
    # corr[d] = sum G[x + d] img[x]: the outline drawn at (pu + Wi/2, pv + Hi/2) lies on picture pixel that + d, so
    # where the picture really shows a point is the UiMapAssignment guess moved by d + (Wi/2, Hi/2)
    sh_u = (du if du < PW // 2 else du - PW) + Wi // 2
    sh_v = (dv if dv < PH // 2 else dv - PH) + Hi // 2
    yMax = y1u + sh_u * 1.5 * s / Wi
    xMax = x1u + sh_v * s / Hi
    out = dict(xMin=xMax - s, xMax=xMax, yMin=yMax - 1.5 * s, yMax=yMax, score=float(score), scale=float(s / s0),
               shift=(int(sh_u), int(sh_v)))
    out["uimap_diff"] = float(max(abs(out["xMin"] - x0u), abs(out["xMax"] - x1u), abs(out["yMin"] - y0u),
                                  abs(out["yMax"] - y1u)))
    if png:
        pic = np.asarray(Image.open(os.path.join(ART, SOURCE[mapfile] + ".jpg")).convert("RGB")).copy()
        pu = (out["yMax"] - wy) / (1.5 * s) * Wi
        pv = (out["xMax"] - wx) / s * Hi
        for u, v in zip(pu.astype(int), pv.astype(int)):
            if 0 <= u < Wi and 0 <= v < Hi:
                pic[v, u] = (255, 0, 0)
        Image.fromarray(pic).save(os.path.join(R.CACHE, "register_%s.png" % mapfile))
    return out


def register_pinned(mapfile, pin_uv, pin_world, png=False):
    """The frame of a picture on which one point is known (a boss: where the picture draws it, u v in 0..1, and its
    spawn, world x y z): only the scale is free. For each picture height s in yards the boss pins the corner
    (xMax = x + s v, yMax = y + 1.5 s u); the outline of the floors at the boss' level, drawn with that frame, scores
    the picture's edges under it. -> the best frame and its score."""
    u0, v0 = pin_uv
    bx, by, bz = pin_world
    zone, _ = F.FLOORS[mapfile]
    raid = next(k for k, v in R.RAIDS.items() if v[0] == F.ZONE_MAP[zone])
    box = (bx - 400, by - 600, bx + 400, by + 600)
    pls, _ = R.placements(R.RAIDS[raid][1], box)
    faces = []
    for pl in pls:
        faces += R.wmo_faces(pl, box, bz - LEVEL_DOWN - 1, bz + LEVEL_UP + 1)
    wx, wy, _ = outline(faces, box, bz - LEVEL_DOWN, bz + LEVEL_UP)
    G = edges(os.path.join(ART, SOURCE[mapfile] + ".jpg"))
    Hi, Wi = G.shape
    best = None
    for s in np.arange(80.0, 900.0, 0.5):
        xMax, yMax = bx + s * v0, by + 1.5 * s * u0
        pu = ((yMax - wy) / (1.5 * s) * Wi).astype(int)
        pv = ((xMax - wx) / s * Hi).astype(int)
        ok = (pu >= 0) & (pu < Wi) & (pv >= 0) & (pv < Hi)
        if ok.sum() < 200:
            continue
        score = G[pv[ok], pu[ok]].mean()
        if best is None or score > best[0]:
            best = (float(score), float(s), float(xMax), float(yMax), int(ok.sum()))
    if not best:
        return None
    score, s, xMax, yMax, n = best
    out = dict(xMin=xMax - s, xMax=xMax, yMin=yMax - 1.5 * s, yMax=yMax, score=score, points=n)
    if png:
        pic = np.asarray(Image.open(os.path.join(ART, SOURCE[mapfile] + ".jpg")).convert("RGB")).copy()
        pu = ((yMax - wy) / (1.5 * s) * Wi).astype(int)
        pv = ((xMax - wx) / s * Hi).astype(int)
        for u, v in zip(pu, pv):
            if 0 <= u < Wi and 0 <= v < Hi:
                pic[v, u] = (255, 0, 0)
        Image.fromarray(pic).save(os.path.join(R.CACHE, "pinned_%s.png" % mapfile))
    return out


def level_of(mapfile, starters, portraits):
    """A boss of that floor with a spawn: its height."""
    sp = R.spawns()
    for ref, st in sorted(starters.items()):
        if st["p"][0].get("map") != mapfile:
            continue
        for c in portraits.get(ref) or []:
            mapid = R.RAIDS[ref.split(":")[0]][0]
            ss = [s for s in sp.get(c["id"], []) if s[0] == mapid]
            if ss:
                return ss[0][3], c["n"]
    return None, None


def main(argv):
    png = "--png" in argv
    argv = [a for a in argv if a != "--png"]
    starters, portraits, _ = R.addon_data()
    out = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for mf in (argv or sorted(SOURCE)):
        z, who = level_of(mf, starters, portraits)
        if z is None:
            print("%-14s no boss with a spawn on it" % mf)
            continue
        r = register(mf, z, png)
        if not r:
            print("%-14s too little floor at %s's level" % (mf, who))
            continue
        out[mf] = r
        print("%-14s at %-26s score %.3f scale %.3f shift %4d %4d px -> differs from UiMapAssignment by %6.1f yd"
              % (mf, who, r["score"], r["scale"], r["shift"][0], r["shift"][1], r["uimap_diff"]))
    json.dump(out, open(OUT, "w"), indent=1)


if __name__ == "__main__":
    main(sys.argv[1:])
