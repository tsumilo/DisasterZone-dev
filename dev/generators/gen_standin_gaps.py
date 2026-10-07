"""The stand-in gaps: for every room with stand-in data, the opaque room triangles that no stand-in covers (well enough).

Stand-in mode (Render3D/Standins.lua) hides a model per pixel only where a stand-in lies behind the room's surface;
thin walls, pillars, railings and small steps have none (gen_standins.py can't fit one without poking out), so a model
showed straight through them (Attumen through a Karazhan stable pillar, 2026-10-07). The runtime now keeps the box
mode's copies for these triangles only: exact where a stand-in exists, the copies elsewhere - never worse than box mode.

A triangle sample point is covered when some stand-in's front face (a quad's face, a cube's face along its normal)
lies behind it within MARGIN + TOL along that normal, the point inside the face's rectangle, and the triangle is drawn
to the same side. A triangle is a gap when more than GAP_SHARE of its area is uncovered. Every see-through triangle
(alpha-keyed or blended: fences, gratings, foliage, banners) is a gap too: no stand-in can copy its holes, the copies
draw its texture holes and all.

Writes Render3D/Standins/Gaps.lua:
  ns.RoomStandinGaps[key] = { size = <room payload size>, tris = "a-b,c,..." }   (1-based triangle numbers of the
  room file, ranges; the runtime ignores it when size differs from the room's).

  python gen_standin_gaps.py [key ...]        (all rooms with data by default)
"""
import math
import os
import re
import sys

import numpy as np
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_standins as G  # noqa: E402

TOL = 0.08          # yd past MARGIN a stand-in's front may lie behind the drawn face (regions are 0.02 yd flat)
EDGE_TOL = 0.02     # yd round a front face's rectangle
STEP = 0.25         # yd between sample points
MAX_SUB = 64        # subdivisions of a triangle's longest edge at most
GAP_SHARE = 0.90    # a triangle with more than this share uncovered is a gap
ALIGN = 0.95        # a stand-in's normal against the drawn face's
OUT = os.path.join(G.OUT_DIR, "Gaps.lua")


def samples(room, tris):
    """Sample points of the triangles: (points, triangle index per point, weight = area share per point)."""
    P, I, W = [], [], []
    V, T = room.V, room.T
    for t in tris:
        a, b, c = V[T[t, 0]], V[T[t, 1]], V[T[t, 2]]
        L = max(np.linalg.norm(b - a), np.linalg.norm(c - b), np.linalg.norm(a - c))
        n = int(min(MAX_SUB, max(1, math.ceil(L / STEP))))
        # the centres of the n*n small triangles of the subdivision (equal areas)
        pts = []
        for i in range(n):
            for j in range(n - i):
                pts.append(((i + 1 / 3) / n, (j + 1 / 3) / n))
                if i + j < n - 1:
                    pts.append(((i + 2 / 3) / n, (j + 2 / 3) / n))
        uv = np.array(pts)
        p = a + uv[:, :1] * (b - a) + uv[:, 1:] * (c - a)
        P.append(p)
        I.append(np.full(len(p), t))
        W.append(np.full(len(p), 1.0 / len(p)))
    return np.concatenate(P), np.concatenate(I), np.concatenate(W)


def gaps(key):
    room = G.load_room(key)
    path = os.path.join(G.OUT_DIR, G.data_key(key) + ".lua") if hasattr(G, "data_key") else None
    if not path or not os.path.exists(path):
        path = os.path.join(G.OUT_DIR, key + ".lua")
    d = G.read_file(path)
    if d["stamp"] and d["stamp"]["size"] != room.size:
        raise ValueError("%s: stand-in data is stale" % key)
    C, R, H, N, K = G.record_arrays(d["recs"])
    tris = np.nonzero(room.opaque)[0]
    # the drawn side of each triangle: its node plane's normal times QO
    DN = room.NP[tris] * room.QO[tris][:, None]
    DN /= np.maximum(np.linalg.norm(DN, axis=1), 1e-12)[:, None]
    dn_of = np.zeros((room.ntris, 3))
    dn_of[tris] = DN
    P, TI, Wt = samples(room, tris)
    cov = np.zeros(len(P), bool)
    tree = cKDTree(P)
    # each stand-in's front face: the axis most along its normal
    dots = np.einsum("ij,ikj->ik", N, R)                    # (n, 3): N . axis k
    k = np.abs(dots).argmax(1)
    sg = np.sign(dots[np.arange(len(k)), k])
    for s in range(len(C)):
        ks = k[s]
        ax = R[s, ks] * sg[s]
        cf = C[s] + ax * H[s, ks]
        others = [j for j in (0, 1, 2) if j != ks]
        rad = math.hypot(H[s, others[0]], H[s, others[1]]) + G.MARGIN + TOL + EDGE_TOL
        idx = tree.query_ball_point(cf, rad)
        if not idx:
            continue
        idx = np.asarray(idx)
        idx = idx[~cov[idx]]
        if not len(idx):
            continue
        q = P[idx] - cf
        h = q @ N[s]
        ok = (h >= -0.005) & (h <= G.MARGIN + TOL)
        for j in others:
            ok &= np.abs(q @ R[s, j]) <= H[s, j] + EDGE_TOL
        ok &= (dn_of[TI[idx]] @ N[s]) >= ALIGN
        cov[idx[ok]] = True
    unc = np.bincount(TI, weights=Wt * ~cov, minlength=room.ntris)
    gap = tris[unc[tris] > GAP_SHARE]
    see = np.nonzero((room.blend != "D") & (room.area > 1e-9) & (room.QO != 0))[0]
    gap = np.union1d(gap, see)
    area = room.area[tris].sum()
    garea = room.area[np.intersect1d(gap, tris)].sum()
    print("%s: %d gaps (%d see-through) of %d opaque triangles (%.0f%% of the opaque area)" % (
          key, len(gap), len(see), len(tris),
          100 * garea / max(area, 1e-9)))
    return room.size, gap + 1, d.get("same") or []


def ranges(ids):
    out, i = [], 0
    ids = sorted(int(x) for x in ids)
    while i < len(ids):
        j = i
        while j + 1 < len(ids) and ids[j + 1] == ids[j] + 1:
            j += 1
        out.append(str(ids[i]) if i == j else "%d-%d" % (ids[i], ids[j]))
        i = j + 1
    return ",".join(out)


def data_files():
    keys = []
    for f in sorted(os.listdir(G.OUT_DIR)):
        if f.endswith(".lua") and f != "Gaps.lua":
            with open(os.path.join(G.OUT_DIR, f), "rb") as fh:
                m = re.search(rb'ns\.RoomStandins\["([^"]+)"\] = \{ version', fh.read())
            if m:
                keys.append(m.group(1).decode())
    return keys


def read_existing():
    if not os.path.exists(OUT):
        return {}
    with open(OUT, "rb") as fh:
        src = fh.read().decode("utf-8")
    return {m.group(1): m.group(0) for m in re.finditer(r'^G\["([^"]+)"\] = .*$', src, re.M)}


def main(argv):
    keys = argv or data_files()
    lines = read_existing()
    for key in keys:
        size, ids, same = gaps(key)
        line = 'G["%s"] = { size = %d, tris = "%s" }' % (key, size, ranges(ids))
        lines[key] = line
        for other in same:
            lines[other] = 'G["%s"] = G["%s"]' % (other, key)
    body = "\n".join(lines[k] for k in sorted(lines, key=lambda k: (lines[k].startswith('G["%s"] = G[' % k), k)))
    src = ("if DisasterZoneBoot and DisasterZoneBoot.Run(\"Render3D/Standins/Gaps.lua\", ...) then return end "
           "-- DisasterZone Render3D/Standins/Gaps.lua\n"
           "-- Generated by dev/generators/gen_standin_gaps.py: per room, the opaque triangles (1-based, ranges) no "
           "stand-in covers;\n-- stand-in mode keeps the box mode's copies for these (Render3D/Room.lua "
           "Room.SetCopyOnly). size = the room payload's.\nlocal _, ns = ...\nns.RoomStandinGaps = "
           "ns.RoomStandinGaps or {}\nlocal G = ns.RoomStandinGaps\n" + body + "\n")
    with open(OUT, "wb") as fh:
        fh.write(src.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
    print("wrote", OUT)


if __name__ == "__main__":
    main(sys.argv[1:])
