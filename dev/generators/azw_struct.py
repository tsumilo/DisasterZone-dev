"""Azeromon world: WMO placements (buildings, walls, bridges, caves) rasterised onto the tile grid.

Per placed WMO, every collidable triangle (MOPY 0x08, or 0x20 without 0x04, as the Raid Trainer's walking) is
projected onto the grid. Per tile we keep:
    floors  heights of walkable faces (normal z >= cos 50 deg) over the tile centre
    walls   (zmin, zmax) of steep faces crossing the tile square
    top     the highest point of ANY face over the tile centre (roofs are often non-colliding)
Then, with the ground height g of the tile (terrain, or the water surface):
    stand  = the walkable WMO floor nearest above g - 1 within 6 yd (a bridge deck, a porch), else g
    solid  if a wall spans [stand + 0.4, stand + 1.8] (it stops a person) - walls, railings, closed gates
    roof   if the WMO has indoor groups and some face is > stand + 3 yd over the tile (a building seen from above)
Doors are the portals between an indoor and an outdoor group (or the outside): their centre tile stays open.
"""
import math

import numpy as np

import adt_tools as A
import azw_wmo as WM

WALKABLE_NZ = math.cos(math.radians(50))
# a wall blocks a tile when it comes within the tile's middle (the square shrunk by this much, in tiles, per side):
# a 2.6-tile-wide diagonal bridge keeps a walkable lane between its railings, solid walls stay closed
WALL_INSET = 0.2


def _collides(f):
    return bool(f & 0x08) or (bool(f & 0x20) and not (f & 0x04))


def _tri_tiles(p0, p1, p2, inset=0.0):
    """Tiles whose square (shrunk by inset tiles on each side) the 2D triangle touches."""
    xs = (p0[0], p1[0], p2[0])
    ys = (p0[1], p1[1], p2[1])
    x0, x1 = int(math.floor(min(xs))), int(math.floor(max(xs)))
    y0, y1 = int(math.floor(min(ys))), int(math.floor(max(ys)))
    if inset == 0 and (x1 - x0 + 1) * (y1 - y0 + 1) <= 2:
        return [(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
    out = []
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            if _tri_box(p0, p1, p2, x, y, inset):
                out.append((x, y))
    return out


def _tri_box(p0, p1, p2, x, y, inset=0.0):
    """Separating-axis test: triangle vs the unit square at (x, y), shrunk by inset on each side."""
    pts = (p0, p1, p2)
    a0, a1 = inset, 1 - inset
    box = ((x + a0, y + a0), (x + a1, y + a0), (x + a1, y + a1), (x + a0, y + a1))
    if min(p[0] for p in pts) > x + a1 or max(p[0] for p in pts) < x + a0 or             min(p[1] for p in pts) > y + a1 or max(p[1] for p in pts) < y + a0:
        return False
    for i in range(3):
        a, b = pts[i], pts[(i + 1) % 3]
        nx, ny = b[1] - a[1], a[0] - b[0]
        tmin = min(nx * p[0] + ny * p[1] for p in pts)
        tmax = max(nx * p[0] + ny * p[1] for p in pts)
        bmin = min(nx * p[0] + ny * p[1] for p in box)
        bmax = max(nx * p[0] + ny * p[1] for p in box)
        if bmax < tmin or bmin > tmax:
            return False
    return True


def _z_at(p0, p1, p2, x, y):
    """z of the 3D triangle at 2D point (x, y), or None outside."""
    (x0, y0, z0), (x1, y1, z1), (x2, y2, z2) = p0, p1, p2
    det = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
    if abs(det) < 1e-9:
        return None
    l0 = ((y1 - y2) * (x - x2) + (x2 - x1) * (y - y2)) / det
    l1 = ((y2 - y0) * (x - x2) + (x0 - x2) * (y - y2)) / det
    l2 = 1 - l0 - l1
    if l0 < -1e-6 or l1 < -1e-6 or l2 < -1e-6:
        return None
    return l0 * z0 + l1 * z1 + l2 * z2


def rasterise(w):
    """One placement -> dict tile -> {floors, walls, top, indoor_top}, and its doors [(gx, gy, z, group)]."""
    o = WM.load(w[0])
    f = WM.transform(w)
    cells = {}
    has_indoor = any(g["flags"] & 0x2000 for g in o["groups"])
    for g in o["groups"]:
        indoor = bool(g["flags"] & 0x2000)
        vs = [f(v) for v in g["verts"]]
        mopy = g["mopy"] or [(0, 0)] * len(g["tris"])
        for t, (fl, _mat) in zip(g["tris"], mopy):
            p = [vs[i] for i in t]
            ux, uy, uz = p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2]
            vx, vy, vz = p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2]
            # (x, y in tiles, z in yards: scale x / y back to yards for the normal)
            ux, uy, vx, vy = ux * A.TS, uy * A.TS, vx * A.TS, vy * A.TS
            nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            ln = math.sqrt(nx * nx + ny * ny + nz * nz) or 1
            nzn = abs(nz) / ln
            coll = _collides(fl)
            zmin, zmax = min(q[2] for q in p), max(q[2] for q in p)
            wall = coll and nzn < WALKABLE_NZ
            hit = set(_tri_tiles(p[0], p[1], p[2], WALL_INSET)) if wall else ()
            for tile in _tri_tiles(p[0], p[1], p[2]):
                c = cells.get(tile)
                if c is None:
                    c = cells[tile] = {"floors": [], "walls": [], "top": -1e9, "indoor_top": -1e9}
                zc = _z_at(p[0], p[1], p[2], tile[0] + 0.5, tile[1] + 0.5)
                if zc is not None:
                    c["top"] = max(c["top"], zc)
                    if indoor:
                        c["indoor_top"] = max(c["indoor_top"], zc)
                    if coll and nzn >= WALKABLE_NZ:
                        c["floors"].append(zc)
                if wall and tile in hit:
                    c["walls"].append((zmin, zmax))
    doors = []
    pverts = o.get("portal_verts", [])
    links = {}
    for g in o["groups"]:
        s, n = g.get("portal_start", 0), g.get("portal_count", 0)
        for k in range(s, s + n):
            pi, gi, side = o["portal_refs"][k]
            links.setdefault(pi, set()).update((g["index"], gi))
    for pi, groups in links.items():
        kinds = {bool(o["groups"][gi]["flags"] & 0x2000) for gi in groups if gi < len(o["groups"])}
        if kinds == {True, False}:
            start, count, plane = o["portals"][pi]
            ps = [f(pverts[i]) for i in range(start, start + count)]
            cx = sum(q[0] for q in ps) / len(ps)
            cy = sum(q[1] for q in ps) / len(ps)
            cz = min(q[2] for q in ps)
            outdoor = [gi for gi in groups if not (o["groups"][gi]["flags"] & 0x2000)]
            doors.append((cx, cy, cz, outdoor[0] if outdoor else None, pi))
    return cells, doors, has_indoor


def apply(world, placements, kinds):
    """Writes WMO effects into the world arrays (see gen_azeromon_world): returns per placement its info."""
    infos = []
    for w in placements:
        kind = kinds.get(w[0], "auto")
        if kind == "skip":
            continue
        cells, doors, has_indoor = rasterise(w)
        infos.append({"w": w, "cells": cells, "doors": doors, "indoor": has_indoor, "kind": kind})
    return infos
