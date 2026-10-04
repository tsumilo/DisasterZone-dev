"""Where each shipped floor map lies in the world, measured: the creatures wowhead places on that very picture
(data/npc_spots.json, percent of the map) against where the server spawns them (AzerothCore creature.sql).

Retail's UiMapAssignment gives most floors' world rectangle, but the pictures we ship (wowhead's maps of the TBC
zones) are framed their own way on some floors (Karazhan's upper floors are 30 - 100 yd off). So each floor is fitted
from the data: the map is north up with square pixels, so a picture point (u, v in 0..1) is world
x = C - s * v, y = A - 1.5 * s * u (s = yards the picture spans top to bottom). RANSAC over pairs (a creature's spot
on the picture, one of its spawns on the map): two pairs give a frame, a spot counts when one of its creature's
spawns lies within 4 yd; the frame with the most inliers is refitted on them by least squares.

-> art/rooms/floor_fits.json: { mapfile: { xMin, xMax, yMin, yMax, inliers, rms, uimap_diff } }.
Run: luaenv\\Scripts\\python.exe generators\\floor_fits.py
"""
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_rooms as R  # noqa: E402

FLOORS = {"Gruul": (3923, "0"), "Magtheridon": (3836, "1"), "Serpentshrine": (3607, "1"), "TheEye": (3845, "1"),
          "Hyjal": (3606, "0"), "ZulAman": (3805, "0"), "Sunwell": (4075, "1"), "Sunwell0": (4075, "0")}
FLOORS.update({"Kara%02d" % i: (3457, str(i)) for i in range(1, 18)})
FLOORS.update({"BT%02d" % i: (3959, str(i)) for i in range(0, 8)})
ZONE_MAP = {3457: 532, 3923: 565, 3836: 544, 3607: 548, 3845: 550, 3606: 534, 3959: 564, 3805: 568, 4075: 580}
ASPECT = 1.5                    # the pictures are 3:2 with square pixels
TOL = 4.0                       # yd: a spot and a spawn this close are the same creature
OUT = os.path.join(R.CACHE, "floor_fits.json")


def lsq(rows):
    """Least squares for wx = C - s v, wy = A - 1.5 s u: rows (u, v, wx, wy) -> (A, C, s)."""
    # unknowns A, C, s: equations C - s v = wx ; A - 1.5 s u = wy
    import numpy as np
    M, b = [], []
    for u, v, wx, wy in rows:
        M.append([0.0, 1.0, -v])
        b.append(wx)
        M.append([1.0, 0.0, -ASPECT * u])
        b.append(wy)
    sol, *_ = np.linalg.lstsq(np.array(M), np.array(b), rcond=None)
    return tuple(float(x) for x in sol)


def calibrate(mapfile, spots, sp, rng):
    zone, fl = FLOORS[mapfile]
    mapid = ZONE_MAP[zone]
    groups = []                                    # per creature: its spots here, its spawns on the map
    for nid, n in spots.items():
        if n["zone"] != zone:
            continue
        pts = n["spots"].get(fl)
        if not pts:
            continue
        ss = [(s[1], s[2]) for s in sp.get(int(nid), []) if s[0] == mapid]
        if ss:
            groups.append(([(p[0] / 100.0, p[1] / 100.0) for p in pts], ss))
    if not groups:
        return None
    cands = [(u, v, wx, wy, gi) for gi, (pts, ss) in enumerate(groups) for (u, v) in pts for (wx, wy) in ss]
    best, best_n = None, 0
    for _ in range(6000):
        a, b = rng.sample(cands, 2) if len(cands) >= 2 else (cands[0], cands[0])
        if a[4] == b[4] and a[:2] == b[:2]:
            continue
        dv = a[1] - b[1]
        du = a[0] - b[0]
        if abs(dv) < 0.02 and abs(du) < 0.02:
            continue
        A, C, s = lsq([a[:4], b[:4]])
        if not (20 < s < 4000):
            continue
        n = 0
        for pts, ss in groups:
            for u, v in pts:
                wx, wy = C - s * v, A - ASPECT * s * u
                if min((x - wx) ** 2 + (y - wy) ** 2 for x, y in ss) < TOL * TOL:
                    n += 1
        if n > best_n:
            best, best_n = (A, C, s), n
    if not best:
        return None
    # refit on the inliers, twice
    for _ in range(2):
        A, C, s = best
        rows = []
        for pts, ss in groups:
            for u, v in pts:
                wx, wy = C - s * v, A - ASPECT * s * u
                x, y = min(ss, key=lambda q: (q[0] - wx) ** 2 + (q[1] - wy) ** 2)
                if (x - wx) ** 2 + (y - wy) ** 2 < TOL * TOL:
                    rows.append((u, v, x, y))
        if len(rows) >= 2:
            best = lsq(rows)
    A, C, s = best
    res = [math.hypot(C - s * v - x, A - ASPECT * s * u - y) for u, v, x, y in rows]
    return dict(xMin=C - s, xMax=C, yMin=A - ASPECT * s, yMax=A, inliers=len(rows),
                rms=math.sqrt(sum(r * r for r in res) / max(1, len(res))))


def main():
    spots = json.load(open(os.path.join(HERE, "data", "npc_spots.json")))
    sp = R.spawns()
    rng = random.Random(3)
    out = {}
    for mf in sorted(FLOORS):
        f = calibrate(mf, spots, sp, rng)
        um = R.uimap_rect(R.UIMAP[mf])
        if f:
            f["uimap_diff"] = max(abs(f["xMin"] - um[0]), abs(f["xMax"] - um[3]), abs(f["yMin"] - um[1]),
                                  abs(f["yMax"] - um[4]))
            out[mf] = f
            print("%-14s inliers %3d rms %5.2f yd   x %9.1f .. %9.1f  y %9.1f .. %9.1f   uiMap differs by %6.1f yd"
                  % (mf, f["inliers"], f["rms"], f["xMin"], f["xMax"], f["yMin"], f["yMax"], f["uimap_diff"]))
        else:
            print("%-14s no data" % mf)
    json.dump(out, open(OUT, "w"), indent=1)


if __name__ == "__main__":
    main()
