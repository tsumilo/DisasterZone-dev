"""Azeromon world: the inside of a building (a WMO with indoor groups) as small maps, one per floor.

The floors are the WMO's own walkable, colliding faces, rasterised at FINE cells per world tile (interiors are drawn
twice as large as the outside, like Pokemon's houses, so a 3 yd doorway is still a tile and a half). A floor
"level" is the ground floor (the door's height) plus every height an NPC stands at. Cells whose floor lies within
LEVEL_BAND of a level belong to it; cells between two levels are the stairs, and their two ends become stair
tiles (L) warping between the floors. Furniture comes from the WMO's default doodad set.

build(placement, doors, creatures) -> list of level dicts:
    { id, level, z, x0, y0 (fine-cell origin), rows = [str], warps = [...], npcs = [(creature, fx, fy)] }"""
import math

import adt_tools as A
import azw_raw as R
import azw_struct as ST
import azw_wmo as WM

FINE = 2                 # interior cells per world tile
LEVEL_BAND = 1.6         # yd: a floor face this close to a level's height belongs to it
WALKABLE_NZ = math.cos(math.radians(50))

# furniture: (pattern on the doodad name, interior char) - first match wins; chars as Maps.lua interiors
FURNITURE = [
    ("bookshelf|bookcase", "d"), ("bed", "b"), ("table|desk|altar", "t"), ("counter|bar", "c"),
    ("chest|footlocker", "C"), ("barrel|keg", "g"), ("crate|box", "k"), ("jar|pot|urn|vase", "p"),
    ("chandelier", "*"), ("torch|candle|brazier|sconce|lantern", "i"), ("anvil|forge", "k"),
]


def _faces(o, f):
    """Walkable colliding faces of every group, in fine cells: [(p0, p1, p2)] with x, y in fine cells, z yd."""
    out = []
    for g in o["groups"]:
        vs = [f(v) for v in g["verts"]]
        mopy = g["mopy"] or [(0, 0)] * len(g["tris"])
        for t, (fl, _m) in zip(g["tris"], mopy):
            if not ST._collides(fl):
                continue
            p = [vs[i] for i in t]
            ux, uy, uz = (p[1][0] - p[0][0]) * A.TS, (p[1][1] - p[0][1]) * A.TS, p[1][2] - p[0][2]
            vx, vy, vz = (p[2][0] - p[0][0]) * A.TS, (p[2][1] - p[0][1]) * A.TS, p[2][2] - p[0][2]
            nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            ln = math.sqrt(nx * nx + ny * ny + nz * nz) or 1
            if abs(nz) / ln < WALKABLE_NZ:
                continue
            out.append(tuple((q[0] * FINE, q[1] * FINE, q[2]) for q in p))
    return out


def _floor_cells(faces):
    """fine cell (x, y) -> sorted floor heights over its centre."""
    cells = {}
    for p in faces:
        for (cx, cy) in ST._tri_tiles(p[0], p[1], p[2]):
            z = ST._z_at(p[0], p[1], p[2], cx + 0.5, cy + 0.5)
            if z is not None:
                cells.setdefault((cx, cy), []).append(z)
    for k in cells:
        cells[k].sort()
    return cells


def _levels(door_z, npc_zs):
    lv = [door_z]
    for z in sorted(npc_zs):
        if all(abs(z - l) > 3.0 for l in lv):
            lv.append(z)
    return sorted(lv)


def _components(cells):
    seen, comps = set(), []
    for c in cells:
        if c in seen:
            continue
        stack, comp = [c], []
        seen.add(c)
        while stack:
            x, y = stack.pop()
            comp.append((x, y))
            for n in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if n in cells and n not in seen:
                    seen.add(n)
                    stack.append(n)
        comps.append(comp)
    return comps


def build(w, doors, creatures, name, single=False):
    o = WM.load(w[0])
    f = WM.transform(w)
    faces = _faces(o, f)
    cells = _floor_cells(faces)
    if not cells or not doors:
        return []
    door_z = min(d["z"] for d in doors)
    inside = [c for c in creatures]
    levels = _levels(door_z, [c["z"] for c in inside if c["z"] > door_z + 3])
    if single:                    # a mine: one map of every tunnel (its floors slope; NPCs at any height)
        levels = [door_z]
    out = []
    level_cells = []
    for li, lz in enumerate(levels):
        band = 60.0 if single else LEVEL_BAND
        fl = {c for c, zs in cells.items() if any(abs(z - lz) <= band for z in zs)}
        # keep the part connected to the door (ground floor) or to the level's NPCs
        comps = _components(fl)
        keep = set()
        anchors = []
        if li == 0:
            anchors = [(int(d["px"] * FINE), int(d["py"] * FINE)) for d in doors]
        for c in inside:
            if abs(c["z"] - lz) <= 3.0:
                anchors.append((int(c["x"] * FINE), int(c["y"] * FINE)))
        for comp in comps:
            cs = set(comp)
            if any(min(abs(ax - x) + abs(ay - y) for x, y in comp) <= 3 for ax, ay in anchors) and len(comp) >= 4:
                keep |= cs
        # fill the specks a floor's faces leave open (pillar bases, gaps between floor meshes): a cell with
        # three or four floor neighbours is floor
        for _ in range(3):
            add = set()
            xs = [c[0] for c in keep] or [0]
            ys = [c[1] for c in keep] or [0]
            for y in range(min(ys), max(ys) + 1):
                for x in range(min(xs), max(xs) + 1):
                    if (x, y) in keep:
                        continue
                    n = sum((x + dx, y + dy) in keep for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
                    if n >= 3:
                        add.add((x, y))
            if not add:
                break
            keep |= add
        level_cells.append(keep)
    # stairs between consecutive levels: cells whose floor lies between the two heights, touching both
    stairs = []
    for li in range(len(levels) - 1):
        lo, hi = levels[li], levels[li + 1]
        mid = {c for c, zs in cells.items() if any(lo + LEVEL_BAND < z < hi - LEVEL_BAND for z in zs)}
        best = None
        for comp in _components(mid | level_cells[li] | level_cells[li + 1]):
            cs = set(comp)
            a = cs & level_cells[li]
            b = cs & level_cells[li + 1]
            if a and b:
                # the ends: the lower floor's cell nearest the top end and vice versa
                ma = [c for c in mid if c in cs]
                if not ma:
                    continue
                top = max(ma, key=lambda c: max(cells[c]))
                bot = min(ma, key=lambda c: min(cells[c]))
                ea = min(a, key=lambda c: abs(c[0] - bot[0]) + abs(c[1] - bot[1]))
                eb = min(b, key=lambda c: abs(c[0] - top[0]) + abs(c[1] - top[1]))
                best = (ea, eb)
                break
        if best is None:
            # no ramp found (a ladder, a lift): stairs at the closest cells of the two floors
            a, b = level_cells[li], level_cells[li + 1]
            if a and b:
                best = min(((ca, cb) for ca in list(a)[::7] for cb in list(b)[::7]),
                           key=lambda p: abs(p[0][0] - p[1][0]) + abs(p[0][1] - p[1][1]))
        stairs.append(best)
    # doodads (furniture)
    furn = {}
    try:
        dset = o["sets"][0] if o["sets"] else ("", 0, len(o["doodads"]))
        fids = o.get("doodad_fids") or []
        for d in o["doodads"][dset[1]:dset[1] + dset[2]]:
            fid = fids[d["name"]] if d["name"] < len(fids) else 0
            nm = (R.m2_name(fid) or "").lower() if fid else ""
            ch = None
            for pat, c in FURNITURE:
                import re
                if re.search(pat, nm):
                    ch = c
                    break
            if ch:
                gx, gy, gz = f(d["pos"])
                furn[(int(gx * FINE), int(gy * FINE))] = (ch, gz)
    except Exception:
        pass
    for li, lz in enumerate(levels):
        fl = level_cells[li]
        if not fl:
            continue
        xs = [c[0] for c in fl]
        ys = [c[1] for c in fl]
        x0, x1, y0, y1 = min(xs) - 1, max(xs) + 1, min(ys) - 2, max(ys) + 1
        rows = []
        for y in range(y0, y1 + 1):
            row = []
            for x in range(x0, x1 + 1):
                if (x, y) in fl:
                    ch = "f"
                    fu = furn.get((x, y))
                    if fu and abs(fu[1] - lz) < 3:
                        ch = fu[0]
                    row.append(ch)
                elif any((x + dx, y + dy) in fl for dx in (-1, 0, 1) for dy in (-1, 0, 1, 2)):
                    row.append("W")
                else:
                    row.append("X")
            rows.append(row)
        lvl = {"level": li, "z": lz, "x0": x0, "y0": y0, "rows": rows, "warps": [], "npcs": [], "name": name}
        out.append(lvl)
    by_level = {l["level"]: l for l in out}

    def put(l, cell, ch):
        x, y = cell[0] - l["x0"], cell[1] - l["y0"]
        if 0 <= y < len(l["rows"]) and 0 <= x < len(l["rows"][0]):
            l["rows"][y][x] = ch
        return x, y

    # doors on the ground floor: the floor cell nearest the portal becomes the exit mat
    if 0 in by_level:
        l0 = by_level[0]
        for d in doors:
            px, py = d["px"] * FINE, d["py"] * FINE
            cell = min(level_cells[0], key=lambda c: (c[0] + 0.5 - px) ** 2 + (c[1] + 0.5 - py) ** 2)
            x, y = put(l0, cell, "r")
            d["inside"] = (x, y)
    for li, st in enumerate(stairs):
        if not st or li not in by_level or li + 1 not in by_level:
            continue
        a, b = st
        la, lb = by_level[li], by_level[li + 1]
        ax, ay = put(la, a, "L")
        bx, by = put(lb, b, "L")
        la["warps"].append({"x": ax, "y": ay, "to": li + 1, "tx": bx, "ty": by})
        lb["warps"].append({"x": bx, "y": by, "to": li, "tx": ax, "ty": ay})
    # NPCs: the level nearest their height, on the nearest floor cell
    for c in inside:
        li = min(range(len(levels)), key=lambda i: abs(levels[i] - c["z"]))
        if li not in by_level or not level_cells[li]:
            continue
        l = by_level[li]
        fx, fy = c["x"] * FINE, c["y"] * FINE
        cell = min(level_cells[li], key=lambda cc: (cc[0] + 0.5 - fx) ** 2 + (cc[1] + 0.5 - fy) ** 2)
        x, y = cell[0] - l["x0"], cell[1] - l["y0"]
        if l["rows"][y][x] not in "f":
            l["rows"][y][x] = "f"
        l["npcs"].append((c, x, y))
    for l in out:
        l["rows"] = ["".join(r) for r in l["rows"]]
    return out
