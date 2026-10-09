"""Azeromon / Disastercraft overworld: fine collision, SUB x SUB cells a tile (a tile is 4.17 yd: ~1 yd a cell).

The tile layers (gen_azeromon_world: G, O) made a whole 4-yard tile solid for a tree trunk, a barrel or a building
wall. This module draws what really stops a body, from the client's own collision data, at cell size:
    doodads  the .m2's collision mesh (header 0xD8 / 0xE0; a bush or a gravestone has none: walk through, as in
             WoW), placed as its sprite is drawn (azw_scenery: organic kinds unturned, small props PROP_SCALE
             bigger), cut to the band a body fills over the model's foot (BAND)
    WMOs     their collidable faces steeper than 50 degrees (azw_struct), cut to the band over the floor the tile
             stands on; in a building's roof tiles (O "R") also every cell under its indoor groups' ceilings
A cell is solid when a face reaches into its middle (the square shrunk by INSET a side); a doodad thinner than
that still takes the cell under its middle. Door tiles (O "D") stay open: stepping on one walks you inside.

build(world, gbox) -> {(cx, cy) fine cell: True} for the cells in the grid box gbox (tiles gx0, gx1, gy0, gy1)
masks(world, cells, bx, by, block) -> [16-bit mask per tile of the block, row by row] (bit = sy * SUB + sx)"""
import math

import adt_tools as A
import azw_classify as K
import azw_raw as R
import azw_render as RD
import azw_struct as ST
import azw_wmo as WM
import casc_local as C

SUB = 4
BAND = (0.3, 2.0)            # yards over the foot a body fills (low kerbs and the floor under it stay out)
INSET = 0.25                 # cells: a face must come this far into a cell to take it
WALKABLE_NZ = ST.WALKABLE_NZ


def m2_collision(fid):
    """-> (positions [(x, y, z)], triangles [(a, b, c)]) of the model's collision mesh (empty: none)."""
    d = C.read_fid(fid)
    md = d[8:] if d[:4] == b"MD21" else d
    ni, oi = RD._arr(md, 0xD8)
    npos, op = RD._arr(md, 0xE0)
    if not ni or not npos:
        return [], []
    import struct
    idx = struct.unpack_from("<%dH" % ni, md, oi)
    pos = [struct.unpack_from("<3f", md, op + i * 12) for i in range(npos)]
    tris = [idx[k:k + 3] for k in range(0, ni - ni % 3, 3) if max(idx[k:k + 3]) < npos]
    return pos, tris


def _clip(poly, k, lo, hi):
    """Sutherland-Hodgman: the polygon's part with lo <= p[k] <= hi."""
    for bound, keep in ((lo, lambda v: v >= lo), (hi, lambda v: v <= hi)):
        out = []
        n = len(poly)
        for i in range(n):
            a, b = poly[i], poly[(i + 1) % n]
            ia, ib = keep(a[k]), keep(b[k])
            if ia:
                out.append(a)
            if ia != ib:
                t = (bound - a[k]) / (b[k] - a[k])
                out.append(tuple(a[j] + (b[j] - a[j]) * t for j in range(3)))
        poly = out
        if not poly:
            return []
    return poly


def _poly_box(pts, x, y, inset):
    """Separating axes: the convex 2D polygon (or segment / point) against the cell square at (x, y) shrunk by
    inset on each side."""
    a0, a1 = x + inset, x + 1 - inset
    b0, b1 = y + inset, y + 1 - inset
    if min(p[0] for p in pts) > a1 or max(p[0] for p in pts) < a0 or \
       min(p[1] for p in pts) > b1 or max(p[1] for p in pts) < b0:
        return False
    box = ((a0, b0), (a1, b0), (a1, b1), (a0, b1))
    n = len(pts)
    for i in range(n):
        p, q = pts[i], pts[(i + 1) % n]
        nx, ny = q[1] - p[1], p[0] - q[0]
        if abs(nx) + abs(ny) < 1e-9:
            continue
        tmin = min(nx * v[0] + ny * v[1] for v in pts)
        tmax = max(nx * v[0] + ny * v[1] for v in pts)
        bmin = min(nx * v[0] + ny * v[1] for v in box)
        bmax = max(nx * v[0] + ny * v[1] for v in box)
        if bmax < tmin - 1e-9 or bmin > tmax + 1e-9:
            return False
    return True


def _mark(cells, pts, inset=INSET):
    """Marks the cells the 2D polygon pts (fine-cell units) reaches into; -> how many."""
    x0, x1 = int(math.floor(min(p[0] for p in pts))), int(math.floor(max(p[0] for p in pts)))
    y0, y1 = int(math.floor(min(p[1] for p in pts))), int(math.floor(max(p[1] for p in pts)))
    n = 0
    for cy in range(y0, y1 + 1):
        for cx in range(x0, x1 + 1):
            if _poly_box(pts, cx, cy, inset):
                cells[(cx, cy)] = True
                n += 1
    return n


def _fill(mine):
    """A collision mesh is a closed shell (a trunk's cylinder): its faces mark only the outline, so the cells it
    encloses (not reachable from outside its box, 4-way) are marked too."""
    if not mine:
        return
    xs = [k[0] for k in mine]
    ys = [k[1] for k in mine]
    x0, x1, y0, y1 = min(xs) - 1, max(xs) + 1, min(ys) - 1, max(ys) + 1
    seen = {(x0, y0)}
    todo = [(x0, y0)]
    while todo:
        x, y = todo.pop()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if x0 <= nx <= x1 and y0 <= ny <= y1 and (nx, ny) not in seen and (nx, ny) not in mine:
                seen.add((nx, ny))
                todo.append((nx, ny))
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if (x, y) not in seen:
                mine[(x, y)] = True


def _doodad_frame(fid, p, rot, sc, kind):
    """The model -> grid transform its sprite is drawn with (azw_scenery.build): -> f(v) = (gx, gy, z), or None."""
    import azw_scenery as SCN
    try:
        mesh = RD.m2_mesh(fid)
    except Exception:
        return None
    if not mesh or not mesh["tris"]:
        return None
    import numpy as np
    ext = np.asarray(mesh["verts"]).max(0) - np.asarray(mesh["verts"]).min(0)
    boost = SCN.PROP_SCALE if max(ext[0], ext[1], ext[2]) * sc < SCN.SMALL else 1.0
    step = round(((rot[1] - 180) % 360) / (360 / SCN.YAW_STEPS)) % SCN.YAW_STEPS
    if kind in SCN.ORGANIC:
        step, s = 0, boost * sc
    else:
        s = round(sc * boost, 1)
    yaw = math.radians(step * 360 / SCN.YAW_STEPS)
    c, sn = math.cos(yaw), math.sin(yaw)
    ox, oy, oz = p[0] / A.TS, p[2] / A.TS, p[1]

    def f(v):
        fx, fy, fz = v[0] * s, v[1] * s, v[2] * s
        # (azw_render._transform: north = fx c - fy s, east = -(fx s + fy c); the grid's y runs south)
        return ox - (fx * sn + fy * c) / A.TS, oy - (fx * c - fy * sn) / A.TS, oz + fz
    return f, s, mesh


_BAND = {}


def _band_polys(key, verts, tris, s):
    """The model's triangles cut to the body band (model space, the band divided by the scale s): cached per
    model and scale. tris: (a, b, c, ...) vertex indices."""
    if key in _BAND:
        return _BAND[key]
    lo, hi = BAND[0] / s, BAND[1] / s
    out = []
    for t in tris:
        p3 = [tuple(float(x) for x in verts[i]) for i in t[:3]]
        if min(q[2] for q in p3) > hi or max(q[2] for q in p3) < lo:
            continue
        poly = _clip(p3, 2, lo, hi)
        if poly:
            out.append(poly)
    _BAND[key] = out
    return out


TRUNK_MAX = 2.0              # yards: a tree's trunk is never wider than this round its middle


def _trunk(fid, pos, tris, s, f):
    """A tree: its crown is drawn over everyone, so only a trunk you could believe under it may block. The
    collision shell of Elwynn's canopy trees is a cone of roots ~25 yd wide at the ground: its cross-section in
    the body band, no wider than TRUNK_MAX round its middle, stands for it (a thin tree keeps its own)."""
    got, _ = _footprint(_band_polys(("c", fid, s), pos, tris, s), f)
    if not got:
        return {}
    mx = sum(k[0] + 0.5 for k in got) / len(got)
    my = sum(k[1] + 0.5 for k in got) / len(got)
    rad = TRUNK_MAX / A.TS * SUB
    out = {k: True for k in got if (k[0] + 0.5 - mx) ** 2 + (k[1] + 0.5 - my) ** 2 <= rad * rad}
    if not out:
        out[(int(math.floor(mx)), int(math.floor(my)))] = True
    return out


def _footprint(polys, f):
    """Cells the band polygons (placed by f) reach into, their enclosed inside filled; -> (cells, the cell under
    their middle or None)."""
    mine = {}
    cxs, cys, cn = 0.0, 0.0, 0
    for poly in polys:
        pts = []
        for v in poly:
            q = f(v)
            pts.append((q[0] * SUB, q[1] * SUB))
            cxs, cys, cn = cxs + pts[-1][0], cys + pts[-1][1], cn + 1
        _mark(mine, pts)
    centre = (int(math.floor(cxs / cn)), int(math.floor(cys / cn))) if cn else None
    if centre and not mine:
        mine[centre] = True
    _fill(mine)
    return mine, centre


def _tile_stand(world, tx, ty):
    r = world["r"]
    x, y = tx - r["gx0"], ty - r["gy0"]
    if not (0 <= x < r["W"] and 0 <= y < r["H"]):
        return None
    z = float(r["z"][y, x])
    if r["liq"][y, x]:
        z += float(r["depth"][y, x])
    return z


def build(world, gbox):
    r = world["r"]
    O = world["O"]
    gx0, gx1, gy0, gy1 = gbox
    cells = {}

    def over(tx, ty):
        x, y = tx - r["gx0"], ty - r["gy0"]
        if 0 <= x < r["W"] and 0 <= y < r["H"]:
            return O[y, x]
        return " "

    # --- doodads: their own collision meshes ---
    cache = {}
    n_dood = 0
    for fid, p, rot, sc, uid in r["doodads"]:
        gx, gy = p[0] / A.TS, p[2] / A.TS
        if not (gx0 - 4 <= gx < gx1 + 4 and gy0 - 4 <= gy < gy1 + 4):
            continue
        kind, _tile = K.doodad_kind(R.m2_name(fid))
        if kind in (None, "skip"):
            continue                                    # (not drawn: nothing to bump into either)
        if fid not in cache:
            cache[fid] = m2_collision(fid)
        pos, tris = cache[fid]
        if not tris:
            continue
        got = _doodad_frame(fid, p, rot, sc, kind)
        if not got:
            continue
        f, s, mesh = got
        if kind == "tree":
            mine = _trunk(fid, pos, tris, s, f)
            for k in mine:
                if over(k[0] // SUB, k[1] // SUB) != "D":
                    cells[k] = True
            n_dood += 1
            continue
        # the collision shell's cross-section in the body band...
        coll, centre = _footprint(_band_polys(("c", fid, s), pos, tris, s), f)
        # ... no bigger than the model as drawn there (the canopy trees' hull is a wide cone around the roots)
        vis, _ = _footprint(_band_polys(("m", fid, s), mesh["verts"], mesh["tris"], s), f)
        mine = {k: True for k in coll if k in vis}
        if not mine and coll and vis and centre:
            mine[centre] = True                     # (a thin post: the cell under its middle)
        for k in mine:
            if over(k[0] // SUB, k[1] // SUB) != "D":
                cells[k] = True
        n_dood += 1
    # --- WMOs: walls in the body band, and what is under a building's indoor ceilings ---
    n_wmo = 0
    for w in r["wmos"]:
        kind = world.get("wmo_kinds", {}).get(w[0], "auto")
        if kind == "skip":
            continue
        bb = w[3]
        if bb[3] / A.TS < gx0 or bb[0] / A.TS > gx1 or bb[5] / A.TS < gy0 or bb[2] / A.TS > gy1:
            continue
        if max(bb[3] - bb[0], bb[5] - bb[2]) > 400:
            continue
        coarse, _doors, has_indoor = ST.rasterise(w)
        stand = {}

        def st_of(tx, ty):
            k = (tx, ty)
            if k not in stand:
                g = _tile_stand(world, tx, ty)
                if g is None:
                    stand[k] = None
                else:
                    c = coarse.get(k)
                    floors = [z for z in (c["floors"] if c else ()) if g - 1.5 <= z <= g + 6]
                    stand[k] = max(floors) if floors else g
            return stand[k]

        o = WM.load(w[0])
        f = WM.transform(w)
        cave = kind == "cave"
        for g_ in o["groups"]:
            indoor = bool(g_["flags"] & 0x2000)
            vs = [f(v) for v in g_["verts"]]
            mopy = g_["mopy"] or [(0, 0)] * len(g_["tris"])
            for t, (fl, _mat) in zip(g_["tris"], mopy):
                p3 = [vs[i] for i in t]
                cx_, cy_ = sum(q[0] for q in p3) / 3, sum(q[1] for q in p3) / 3
                tx, ty = int(math.floor(cx_)), int(math.floor(cy_))
                if not (gx0 - 1 <= tx < gx1 + 1 and gy0 - 1 <= ty < gy1 + 1):
                    continue
                st = st_of(tx, ty)
                if st is None:
                    continue
                ux, uy, uz = (p3[1][0] - p3[0][0]) * A.TS, (p3[1][1] - p3[0][1]) * A.TS, p3[1][2] - p3[0][2]
                vx, vy, vz = (p3[2][0] - p3[0][0]) * A.TS, (p3[2][1] - p3[0][1]) * A.TS, p3[2][2] - p3[0][2]
                nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
                ln = math.sqrt(nx * nx + ny * ny + nz * nz) or 1
                if ST._collides(fl) and abs(nz) / ln < WALKABLE_NZ:
                    oc = over(tx, ty)
                    if cave and oc not in ("#", "R"):
                        continue                        # (a mine: only its mouth stands above the ground)
                    poly = _clip(p3, 2, st + 0.4, st + 1.8)
                    if poly:
                        mine = {}
                        _mark(mine, [(q[0] * SUB, q[1] * SUB) for q in poly])
                        for k in mine:
                            if over(k[0] // SUB, k[1] // SUB) not in ("D", "="):
                                cells[k] = True
                elif indoor and has_indoor and not cave and max(q[2] for q in p3) > st + 3:
                    # a ceiling / roof over a room: the cells whose middle it covers, in roof tiles
                    pts = [(q[0] * SUB, q[1] * SUB, q[2]) for q in p3]
                    x0, x1 = int(math.floor(min(q[0] for q in pts))), int(math.floor(max(q[0] for q in pts)))
                    y0, y1 = int(math.floor(min(q[1] for q in pts))), int(math.floor(max(q[1] for q in pts)))
                    for fy in range(y0, y1 + 1):
                        for fx in range(x0, x1 + 1):
                            if (fx, fy) in cells or over(fx // SUB, fy // SUB) != "R":
                                continue
                            z = ST._z_at(pts[0], pts[1], pts[2], fx + 0.5, fy + 0.5)
                            if z is not None:
                                s2 = st_of(fx // SUB, fy // SUB)
                                if s2 is not None and z > s2 + 3:
                                    cells[(fx, fy)] = True
        n_wmo += 1
    print("collision: %d doodads, %d WMOs, %d solid cells" % (n_dood, n_wmo, len(cells)))
    return cells


def masks(cells, bx, by, block):
    out = []
    for j in range(block):
        for i in range(block):
            tx, ty = bx * block + i, by * block + j
            m = 0
            for sy in range(SUB):
                for sx in range(SUB):
                    if (tx * SUB + sx, ty * SUB + sy) in cells:
                        m |= 1 << (sy * SUB + sx)
            out.append(m)
    return out
