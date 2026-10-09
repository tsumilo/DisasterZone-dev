"""Disastercraft world: a building walked in place - no inside maps, no doors that teleport.

Every WMO with indoor groups (houses, the Abbey, mines) becomes a "building": a fine walk grid over its footprint
(SUB x SUB cells a tile, ~1 yd, aligned with the outdoor collision cells of azw_collide) where each cell holds every
height a body can stand at - the building's own walkable, colliding faces (floors, stairs, porches, tunnel floors)
and the terrain - and, per such layer and direction, the layer of the neighbouring cell it leads to:

    standable   nothing collidable inside the cell's column between CLEAR_LO and CLEAR_HI over the floor (a wall,
                a pillar, the floor above too low over head)
    a link      the neighbour's standable layer nearest in height, at most STEP away, with no steep collidable face
                crossing the line between the two cell centres at body height (walls, railings); a stair is just
                floor that rises a little from cell to cell, so you walk up it
    outdoors    across the grid's edge: the terrain there, within STEP

Layers nobody can reach from outdoors (roofs, a tower's leads) are dropped. The building's indoor layers are put
into storeys (its floors, by height); the game draws the building cut away above the storey you stand on, and the
storey changes half way up the stairs. Heights are yards over the WMO's origin, the same frame its pictures are
rendered in (azw_scenery), so a body at height h is drawn 0.6 h yards up the screen (RD.OBLIQUE), like the picture.

grid(r, w, kind) -> dict (see _encode for the Lua form); art(...) -> the storeys' cut-away pictures."""
import math

import numpy as np

import adt_tools as A
import azw_render as RD
import azw_struct as ST
import azw_wmo as WM

SUB = 4                      # cells a tile (as azw_collide)
CELL_YD = A.TS / SUB         # ~1.04 yd
STEP = 1.3                   # yd a body climbs between neighbouring cells (WoW: slopes to 50 degrees = 1.24 a cell)
CLEAR_LO, CLEAR_HI = 0.55, 1.9   # the body's band over its floor: nothing collidable may be in it
WALL_LO, WALL_HI = 0.35, 1.7     # ... over the higher floor of two cells: a face crossing between them there stops you
MERGE = 0.55                 # floors this close in one cell are one layer (and terrain this close joins the floor)
INSET = 0.2                  # cells: a steep face must come this far into a cell to stand in it
MARGIN = 3                   # cells of terrain round the WMO's footprint (the way in from every side)
STOREY_MIN_CELLS = 40        # a flat stretch of floor this big at one height makes a storey
STOREY_GAP = 2.6             # yd: floors closer than this are one storey (a raised dais, two steps)
HEAD_CLIP = 3.4              # yd over a storey's floor: everything higher is taken off its picture
SWITCH_AT = 2.2              # yd over a storey's floor (at most half way to the next): the next storey begins
OBLIQUE = RD.OBLIQUE


def _normal_up(p):
    """|n.z| of a triangle in (cells, cells, yd)."""
    ux, uy, uz = (p[1][0] - p[0][0]) * CELL_YD, (p[1][1] - p[0][1]) * CELL_YD, p[1][2] - p[0][2]
    vx, vy, vz = (p[2][0] - p[0][0]) * CELL_YD, (p[2][1] - p[0][1]) * CELL_YD, p[2][2] - p[0][2]
    nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    ln = math.sqrt(nx * nx + ny * ny + nz * nz)
    return abs(nz) / ln if ln > 1e-9 else 1.0, ln > 1e-9


def _clip_box(poly, x0, y0, x1, y1):
    """Sutherland-Hodgman: a 3D polygon clipped to the 2D box (keeps z)."""
    def clip(pts, axis, val, keep_ge):
        out = []
        n = len(pts)
        for i in range(n):
            a, b = pts[i], pts[(i + 1) % n]
            ina = (a[axis] >= val) if keep_ge else (a[axis] <= val)
            inb = (b[axis] >= val) if keep_ge else (b[axis] <= val)
            if ina:
                out.append(a)
            if ina != inb:
                t = (val - a[axis]) / (b[axis] - a[axis])
                out.append(tuple(a[k] + (b[k] - a[k]) * t for k in range(3)))
        return out
    pts = list(poly)
    for axis, val, ge in ((0, x0, True), (0, x1, False), (1, y0, True), (1, y1, False)):
        if not pts:
            return []
        pts = clip(pts, axis, val, ge)
    return pts


def _cross_z(p, ax, ay, bx, by):
    """The z range where triangle p (cells, cells, yd) cuts the vertical plane through segment a-b, within the
    segment; None if it does not."""
    dx, dy = bx - ax, by - ay
    ln2 = dx * dx + dy * dy
    nx, ny = -dy, dx
    d = [(q[0] - ax) * nx + (q[1] - ay) * ny for q in p]
    pts = []
    for i in range(3):
        j = (i + 1) % 3
        if d[i] == 0:
            pts.append(p[i])
        if (d[i] < 0 < d[j]) or (d[j] < 0 < d[i]):
            t = d[i] / (d[i] - d[j])
            pts.append(tuple(p[i][k] + (p[j][k] - p[i][k]) * t for k in range(3)))
    if len(pts) < 2:
        return None
    ts = [((q[0] - ax) * dx + (q[1] - ay) * dy) / ln2 for q in pts]
    (t0, z0), (t1, z1) = min(zip(ts, (q[2] for q in pts))), max(zip(ts, (q[2] for q in pts)))
    lo, hi = max(t0, 0.0), min(t1, 1.0)
    if lo > hi:
        return None
    if t1 - t0 < 1e-9:
        return (min(z0, z1), max(z0, z1))
    za = z0 + (z1 - z0) * (lo - t0) / (t1 - t0)
    zb = z0 + (z1 - z0) * (hi - t0) / (t1 - t0)
    return (min(za, zb), max(za, zb))


def _terrain(r, cx, cy):
    """Ground (or water surface) height at a cell's centre, bilinear between tile centres; None on a hole / off the
    data."""
    gx, gy = (cx + 0.5) / SUB - r["gx0"] - 0.5, (cy + 0.5) / SUB - r["gy0"] - 0.5
    x0, y0 = int(math.floor(gx)), int(math.floor(gy))
    tx, ty = int(math.floor((cx + 0.5) / SUB)) - r["gx0"], int(math.floor((cy + 0.5) / SUB)) - r["gy0"]
    if not (0 <= tx < r["W"] and 0 <= ty < r["H"]) or r["hole"][ty, tx] or not r["present"][ty, tx]:
        return None
    fx, fy = gx - x0, gy - y0
    tot, acc = 0.0, 0.0
    for (ix, iy, wt) in ((x0, y0, (1 - fx) * (1 - fy)), (x0 + 1, y0, fx * (1 - fy)),
                         (x0, y0 + 1, (1 - fx) * fy), (x0 + 1, y0 + 1, fx * fy)):
        if 0 <= ix < r["W"] and 0 <= iy < r["H"] and r["present"][iy, ix]:
            z = float(r["z"][iy, ix]) + (float(r["depth"][iy, ix]) if r["liq"][iy, ix] else 0.0)
            acc += z * wt
            tot += wt
    return acc / tot if tot > 0 else None


def grid(r, w, kind="auto"):
    """The building's walk grid. Returns {uid, cx0, cy0, w, h, cells: {(cx, cy): [layer]}, storeys, cave, oz} with
    layer = {h, indoor, ter, links: [n, e, s, w] (index | "o" | None), st}; heights in yd over the WMO's origin."""
    o = WM.load(w[0])
    f = WM.transform(w)
    oz = w[1][1]
    cave = kind == "cave"
    floors = {}                      # cell -> [(h, indoor)]
    steep = []                       # [(p, indoor)] in (cells, cells, yd over origin)
    steep_at = {}                    # cell -> [steep index] (its inset square touched)
    edge_tris = {}                   # ("e" | "s", cx, cy) -> [steep index] crossing that centre-to-centre segment
    xs, ys = [], []
    for g in o["groups"]:
        indoor = bool(g["flags"] & 0x2000)
        vs = [f(v) for v in g["verts"]]
        mopy = g["mopy"] or [(0, 0)] * len(g["tris"])
        for t, (fl, _m) in zip(g["tris"], mopy):
            if not ST._collides(fl):
                continue
            p = [(vs[i][0] * SUB, vs[i][1] * SUB, vs[i][2] - oz) for i in t]
            xs += [q[0] for q in p]
            ys += [q[1] for q in p]
            nz, ok = _normal_up(p)
            if not ok:
                continue
            if nz >= ST.WALKABLE_NZ:
                for (cx, cy) in ST._tri_tiles(p[0], p[1], p[2]):
                    z = None
                    for sx, sy in ((0.5, 0.5), (0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)):
                        z = ST._z_at(p[0], p[1], p[2], cx + sx, cy + sy)
                        if z is not None:
                            break
                    if z is not None:
                        floors.setdefault((cx, cy), []).append((z, indoor))
            else:
                k = len(steep)
                steep.append(p)
                for c in ST._tri_tiles(p[0], p[1], p[2], INSET):
                    steep_at.setdefault(c, []).append(k)
                # the centre-to-centre segments its footprint may cross
                x0, x1 = int(math.floor(min(q[0] for q in p) - 0.5)), int(math.floor(max(q[0] for q in p) - 0.5))
                y0, y1 = int(math.floor(min(q[1] for q in p) - 0.5)), int(math.floor(max(q[1] for q in p) - 0.5))
                for cy in range(y0 - 1, y1 + 2):
                    for cx in range(x0 - 1, x1 + 2):
                        if _cross_z(p, cx + 0.5, cy + 0.5, cx + 1.5, cy + 0.5) is not None:
                            edge_tris.setdefault(("e", cx, cy), []).append(k)
                        if _cross_z(p, cx + 0.5, cy + 0.5, cx + 0.5, cy + 1.5) is not None:
                            edge_tris.setdefault(("s", cx, cy), []).append(k)
    if not xs:
        return None
    cx0, cx1 = int(math.floor(min(xs))) - MARGIN, int(math.floor(max(xs))) + MARGIN
    cy0, cy1 = int(math.floor(min(ys))) - MARGIN, int(math.floor(max(ys))) + MARGIN

    # the layers of each cell: merged floors, the terrain
    cells = {}
    for cy in range(cy0, cy1 + 1):
        for cx in range(cx0, cx1 + 1):
            hs = sorted(floors.get((cx, cy), ()), key=lambda v: v[0])
            lay = []
            for z, ind in hs:
                if lay and z - lay[-1]["h"] <= MERGE:
                    lay[-1]["h"] = max(lay[-1]["h"], z)
                    lay[-1]["indoor"] = lay[-1]["indoor"] or ind
                else:
                    lay.append({"h": z, "indoor": ind, "ter": False})
            tz = _terrain(r, cx, cy)
            if tz is not None:
                tz -= oz
                near = [l_ for l_ in lay if abs(l_["h"] - tz) <= MERGE]
                if near:
                    near[0]["ter"] = True
                else:
                    lay.append({"h": tz, "indoor": False, "ter": True})
                    lay.sort(key=lambda v: v["h"])
            # standable: nothing in the body's band over it
            ok = []
            for i, l_ in enumerate(lay):
                lo, hi = l_["h"] + CLEAR_LO, l_["h"] + CLEAR_HI
                if any(lo < m["h"] < hi for m in lay if m is not l_):
                    continue
                blocked = False
                for k in steep_at.get((cx, cy), ()):
                    poly = _clip_box(steep[k], cx + INSET, cy + INSET, cx + 1 - INSET, cy + 1 - INSET)
                    if poly and min(q[2] for q in poly) < hi and max(q[2] for q in poly) > lo:
                        blocked = True
                        break
                if not blocked:
                    ok.append(l_)
            for l_ in ok:
                l_["links"] = [None, None, None, None]
            cells[(cx, cy)] = ok

    def blocked_between(key, ha, hb):
        top = max(ha, hb)
        lo, hi = top + WALL_LO, top + WALL_HI
        cx, cy = key[1], key[2]
        bx, by = (cx + 1.5, cy + 0.5) if key[0] == "e" else (cx + 0.5, cy + 1.5)
        for k in edge_tris.get(key, ()):
            zr = _cross_z(steep[k], cx + 0.5, cy + 0.5, bx, by)
            if zr and zr[0] < hi and zr[1] > lo:
                return True
        return False

    # links east and south (and back): the nearest layer within a step, nothing in between (a link holds the
    # neighbour's layer itself until the end, then its index)
    DIRS = ((0, -1), (1, 0), (0, 1), (-1, 0))          # n e s w
    for (cx, cy), lay in cells.items():
        for d, key in ((1, ("e", cx, cy)), (2, ("s", cx, cy))):
            nb = (cx + DIRS[d][0], cy + DIRS[d][1])
            other = cells.get(nb)
            for l_ in lay:
                if other is None:
                    # past the grid's edge: the terrain there
                    tz = _terrain(r, nb[0], nb[1])
                    if tz is not None and (l_["ter"] or abs(tz - oz - l_["h"]) <= STEP) and                        not blocked_between(key, l_["h"], tz - oz):
                        l_["links"][d] = "o"
                    continue
                best = None
                for m in other:
                    dh = abs(m["h"] - l_["h"])
                    # (terrain to terrain: the outdoor rules - any slope the world lets you walk)
                    if (dh <= STEP or (l_["ter"] and m["ter"])) and (best is None or dh < best[0]):
                        best = (dh, m)
                if best and not blocked_between(key, l_["h"], best[1]["h"]):
                    m = best[1]
                    # (two layers may both pick one neighbour: keep the nearer pair)
                    back = m["links"][(d + 2) % 4]
                    if back is None or abs(back["h"] - m["h"]) > best[0]:
                        if back is not None:
                            back["links"][d] = None
                        l_["links"][d] = m
                        m["links"][(d + 2) % 4] = l_
        # west / north edges of the grid
        for d in (0, 3):
            nb = (cx + DIRS[d][0], cy + DIRS[d][1])
            if nb in cells:
                continue
            key = ("s", nb[0], nb[1]) if d == 0 else ("e", nb[0], nb[1])
            tz = _terrain(r, nb[0], nb[1])
            for l_ in lay:
                if tz is not None and (l_["ter"] or abs(tz - oz - l_["h"]) <= STEP) and                    not blocked_between(key, l_["h"], tz - oz):
                    l_["links"][d] = "o"

    # reachable from outdoors: everything else goes (roofs, ledges); links are both ways, so a kept layer only
    # links to kept ones
    seen = set()
    stack = [l_ for lay in cells.values() for l_ in lay if "o" in l_["links"]]
    seen.update(id(l_) for l_ in stack)
    while stack:
        l_ = stack.pop()
        for m in l_["links"]:
            if isinstance(m, dict) and id(m) not in seen:
                seen.add(id(m))
                stack.append(m)
    dropped = 0
    for c in list(cells):
        keep = [l_ for l_ in cells[c] if id(l_) in seen]
        dropped += len(cells[c]) - len(keep)
        cells[c] = keep
    # plain ground: a cell with only its terrain, open every way to terrain - the outdoor rules hold there (the
    # world's collision cells), so it is left out of the grid; links into it read "outdoors"
    plain = set()
    for c, lay in cells.items():
        if len(lay) == 1 and lay[0]["ter"] and not lay[0]["indoor"] and            all(m == "o" or (isinstance(m, dict) and m["ter"]) for m in lay[0]["links"]):
            plain.add(c)
    for c in plain:
        for d, m in enumerate(cells[c][0]["links"]):
            if isinstance(m, dict):
                m["links"][(d + 2) % 4] = "o"
    for c in plain:
        cells[c] = []
    for c, lay in cells.items():
        for l_ in lay:
            l_["links"] = [m if not isinstance(m, dict) else
                           cells[(c[0] + DIRS[d][0], c[1] + DIRS[d][1])].index(m)
                           for d, m in enumerate(l_["links"])]

    # storeys: the big flat floors of the indoor layers, by height
    storeys = _storeys(cells, cave)
    for lay in cells.values():
        for l_ in lay:
            l_["st"] = storey_of(storeys, l_["h"]) if l_["indoor"] else None
    return {"uid": w[7], "fid": w[0], "cx0": cx0, "cy0": cy0, "w": cx1 - cx0 + 1, "h": cy1 - cy0 + 1,
            "cells": cells, "storeys": storeys, "cave": cave, "oz": oz, "dropped": dropped,
            "ox": w[1][0] / A.TS, "oy": w[1][2] / A.TS}


def _storeys(cells, cave):
    hs = sorted(l_["h"] for lay in cells.values() for l_ in lay if l_["indoor"])
    if not hs:
        return []
    if cave:
        return [{"f": hs[0], "top": 1e9, "clip": None}]
    # the heights many indoor cells share (a floor), lowest first
    bins = {}
    for h in hs:
        b = round(h * 4) / 4
        bins[b] = bins.get(b, 0) + 1
    flats = []
    for b in sorted(bins):
        n = sum(bins.get(round((b + k * 0.25) * 4) / 4, 0) for k in (-1, 0, 1))
        if n >= STOREY_MIN_CELLS:
            flats.append(b)
    floors = []
    for b in flats:
        if floors and b - floors[-1] < STOREY_GAP:
            continue
        floors.append(b)
    if not floors:
        floors = [hs[0]]
    out = []
    for k, fz in enumerate(floors):
        nxt = floors[k + 1] if k + 1 < len(floors) else None
        top = min(fz + SWITCH_AT, (fz + nxt) / 2) if nxt is not None else 1e9
        out.append({"f": fz, "top": top, "clip": fz + HEAD_CLIP})
    # (the first storey also takes everything under it: a cellar step, the porch)
    return out


def storey_of(storeys, h):
    for k, s in enumerate(storeys):
        if h < s["top"]:
            return k
    return len(storeys) - 1 if storeys else None


# ---------------------------------------------------------------------------------------------------------------
# The Lua form
# ---------------------------------------------------------------------------------------------------------------

B64 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-"
H_OFF, H_RES = 128.0, 16.0          # a height is (h + H_OFF) * H_RES in two digits (0 .. 4095)


def _link_char(link):
    if link is None:
        return "."
    if link == "o":
        return "o"
    return B64[link]


def encode_rows(b):
    """One string a row: runs of equal cells, each `run digit` + `cell`; a cell is its layer count digit and per
    layer 7 digits: height (2), flags (1: 1 indoor, 2 terrain, 4 * (storey + 1)), links n e s w ('.' none, 'o' out,
    else the layer's index in the neighbour)."""
    rows = []
    for j in range(b["h"]):
        toks = []
        for i in range(b["w"]):
            lay = b["cells"].get((b["cx0"] + i, b["cy0"] + j), [])
            s = B64[len(lay)]
            for l_ in lay:
                v = int(round((l_["h"] + H_OFF) * H_RES))
                v = max(0, min(4095, v))
                fl = (1 if l_["indoor"] else 0) | (2 if l_["ter"] else 0) | (4 * ((l_["st"] + 1) if l_["st"] is not None else 0))
                s += B64[v // 64] + B64[v % 64] + B64[fl] + "".join(_link_char(x) for x in l_["links"])
            toks.append(s)
        out, k = [], 0
        while k < len(toks):
            n = 1
            while k + n < len(toks) and toks[k + n] == toks[k] and n < 64:
                n += 1
            out.append(B64[n - 1] + toks[k])
            k += n
        rows.append("".join(out))
    return rows


def layer_for(b, gx, gy, z_rel, reach=3.0):
    """The standable layer nearest height z_rel at grid point (gx, gy) tiles: (cell, index, layer) or None."""
    c = (int(math.floor(gx * SUB)), int(math.floor(gy * SUB)))
    lay = b["cells"].get(c)
    if not lay:
        return None
    best = min(range(len(lay)), key=lambda i: abs(lay[i]["h"] - z_rel))
    if abs(lay[best]["h"] - z_rel) > reach:
        return None
    return c, best, lay[best]


def report(b):
    n = sum(len(v) for v in b["cells"].values())
    ind = sum(1 for v in b["cells"].values() for l_ in v if l_["indoor"])
    return "building %d: %dx%d cells, %d layers (%d indoor, %d dropped unreachable), storeys %s" % (
        b["uid"], b["w"], b["h"], n, ind, b["dropped"], [round(s["f"], 1) for s in b["storeys"]])
