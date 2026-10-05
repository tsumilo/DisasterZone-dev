"""Room stand-ins: invisible proxy models that give the strategy board's 3D view per-pixel occlusion by the room.

All ModelScenes share one depth buffer, and that depth survives the opaque UI textures the room is painted with
(dev/docs/DEPTH_RESEARCH.md, in-game facts of 2026-10-05). So a scene under the room's textures that holds models
standing just behind every opaque room surface writes the room's depth: a boss in a scene over the room is then
hidden per pixel wherever a room surface is in front of it. This generator places those models ("stand-ins": the
client's unit cube) for one room and checks offline that they never hide anything the room does not hide.

For a room key (Render3D/Rooms/<Key>.lua, decoded as Render3D/Rooms.lua unpacks it, so the stand-ins follow exactly
what the renderer draws):
  1. regions   the opaque faces (blend D: ALPHAKEY and BLEND faces let models show through, so they get none)
               grouped into planar regions: connected faces on one plane within 2 cm. v1 turns cubes about z only
               (the client's yaw / pitch / roll order is not known yet), so floors, ceilings and upright walls get
               stand-ins - within FLOOR_TILT / WALL_TILT of that, with cubes small enough that the wedge between the
               tilted face and the cube stays under TILT_GAP - and sloped faces none.
  2. exposure  columns of probe points behind every region (PROBE_STEP apart, from the cube's front down to the back
               of a cube of each LEVELS size) are tested against the room's z-buffer from every training pose: a
               point some pose sees past the room (nothing drawn in front of it, or something drawn behind it) may
               not be inside a cube that pose would show. The edges where a region meets nothing (the room's outer
               walls face away from a camera outside them; their tops end at the room's cut) let a camera see under
               a floor or behind a wall, the more the deeper: cubes there are kept shallow, so small.
  3. placement per region, squares in the region's plane (a GRID yd grid along its longest edges), greedy from the
               largest that fits down to MIN_SIZE: every square lies inside the region's outline (a cube's sides
               must not hide models seen past the edge), its cube wholly behind the face with its front MARGIN
               behind it, MARGIN + its size away from any exposed probe, and BACK_GAP from every other room face
               (exact triangle-box tests), so it never pokes out of the back of a thin wall or into a pillar.
  4. repair    an offline z-buffer (numpy) renders every training pose at the check's size: the room's opaque faces
               that face the camera, and the stand-ins the runtime would show (shown()). A stand-in nearer than the
               drawn room, or where the room draws nothing at all, hides a model the room does not hide
               ("over-occlusion"): one seen doing that (past the 1-pixel erosion) is cut into quarters, again
               until the pose is clean (under MIN_SIZE it goes).
  5. check     over-occlusion (must be 0 after a 1-pixel erosion), coverage (opaque room pixels with a stand-in
               within MARGIN + EPS_UNDER behind them, and looser tolerances), stand-ins shown per pose, on the
               training poses and on random poses the placement never saw; pictures (--sheet).
Training poses (poses()): the board's orbit round the room and the boss at pitches 0.15 - 1.5 out to the farthest
distance it allows, low orbits close by the floor's outer edge looking in, walking and eye-level poses.

Writes addon Render3D/Standins/<Key>.lua (the data contract; Render3D/Standins.lua reads it):
    ns.RoomStandins["<Key>"] = { version = 1, prims = { [1] = { fid = 167145, kind = "cube", half = 0.5 } },
                                 n = <count>, stride = 12, data = { <numbers> } }
  12 numbers per stand-in: prim, x, y, z (the primitive's origin in room coordinates: yd, x east, y north, z over
  the boss' floor), yaw, pitch, roll (radians, SetYaw / SetPitch / SetRoll in room coordinates before any mirroring;
  v1 yaw only), scale (uniform: the primitive's size times scale is its size in yd), nx, ny, nz (the unit normal of
  the surface it stands behind, to the side it is seen from), face (the region's id, for debugging). Show a stand-in
  only while its surface faces the camera (shown(): the camera farther out along n than the cube reaches, plus the
  near clip). The primitive is spells/unitcube.m2 (FileDataID 167145): an opaque white 1 yd cube centred on its
  origin; PRIMS is a table so a flat square can join when one is found (a kind with no depth: its probe levels
  would be its front alone).

Run from dev/:  luaenv\\Scripts\\python.exe generators\\gen_standins.py [Key ...] [--fast] [--no-write] [--sheet]
  [--json FILE] (no key: MagtheridonsLair_Magtheridon; about half an hour). --fast: fewer and smaller poses (the
  tests); --sheet: dev/docs/img/standins_<boss>.png (room | stand-ins | errors on six poses) and _top.png.
"""
import argparse
import collections
import json
import math
import os
import re
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (HERE, os.path.join(HERE, "..", "tools")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from patchlib import decode_for_print, inflate_raw  # noqa: E402

ADDON = os.path.normpath(os.path.join(HERE, "..", "..", "addon", "DisasterZone"))
ROOMS_DIR = os.path.join(ADDON, "Render3D", "Rooms")
OUT_DIR = os.path.join(ADDON, "Render3D", "Standins")
IMG_DIR = os.path.normpath(os.path.join(HERE, "..", "docs", "img"))
DEFAULT_KEY = "MagtheridonsLair_Magtheridon"

# The primitives a stand-in can use (index = the data's prim number). half: the model's half size in its own units,
# so a stand-in's size in yd is 2 * half * scale. A flat one-sided square would be kind "square" (no depth).
PRIMS = {1: dict(fid=167145, kind="cube", half=0.5)}
CUBE = 1

# Placement (yd unless said otherwise)
PLANE_TOL = 0.02          # a face joins a region when its corners lie this close to the region's plane ...
PLANE_COS = math.cos(math.radians(3.0))   # ... and its normal is this close to the region's
MARGIN = 0.05             # the cube's front lies this far behind the face (measured along the face's normal). Bigger
                          # than the depth buffer's step (24 bit, near 0.5 / far 500: 1 mm at 100 yd, 5 mm at 200 yd)
                          # ten times over, so a model standing on the face never fights it; small enough that a foot
                          # sinking 5 cm into the floor still shows, deeper is cut as the room would cut it
BACK_GAP = 0.05           # every other room face stays at least this far from a cube (thin walls, pillars, steps)
EDGE_INSET = 0.01         # squares keep this far inside the region's outline (no edge shared to the last bit)
GRID = 0.05               # the placement grid in the region's plane (coarser for very large regions)
MAX_CELLS = 6_000_000     # cells per region grid at most
MIN_SIZE = 0.7            # the smallest cube
MAX_SIZE = 8.0            # the largest cube
SIZE_STEP = 0.8           # the size ladder: each step this much smaller
MIN_GAIN = 0.6            # a cube must cover at least this share of new (uncovered) area
PICKS = 20000             # candidates looked at per round of the greedy placement
LEVELS = (0.3, 0.45, 0.7, 1.0, 1.5, 2.3, 3.4, 5.1, 8.0)   # cube sizes the exposure probes are laid out for
PROBE_STEP = 0.2          # yd between exposure probe columns
TOL_PX = 1.5              # px (the check's screen): a sliver of a stand-in seen past the room thinner than this
                          # is what the check's 1-pixel erosion forgives
FLOOR_TILT = math.radians(5.0)    # floors / ceilings: normal within this of straight up / down
WALL_TILT = math.radians(5.0)     # walls: normal within this of level
TILT_GAP = 0.15           # a cube under a tilted face is kept small enough that the wedge between them stays under this

# Validation
EPS_OVER = 0.005          # yd along the ray: a stand-in nearer than the room by more than this hides too much
EPS_UNDER = 0.02          # coverage: a stand-in within MARGIN + this (along the face's normal) behind the drawn face
LOOSE = (0.25, 1.0)       # looser coverage tolerances reported too (yd behind the face)
AIR_H, AIR_RUN = 12.0, 60.0   # 'harmful' over-occlusion: the ray past the stand-in meets the air a model could
                              # stand in (this high over the boss' floor), looked for this far
FOV, NEAR = 1.1, 0.5      # Render3D/View.lua's scenes
EYE, WALK_EYE = 1.9, 2.2  # UI/StrategyMap3D.lua: the eye all the way in; the point the walking camera turns round
PITCH_MIN, PITCH_TOP = 0.12, 1.5
RULE = "guard"            # which stand-ins show (shown())
POSES_CHECKED = 606        # training + random poses of a full run (the data file says so)
KIND_CODES = {"floor": 0, "ceiling": 1, "wall": 2, "slope": 3, "other": 4}   # the check's breakdown


# ---------------------------------------------------------------------------------------------------------------
# The room as the renderer draws it: the shipped format 3 file decoded (Render3D/Rooms.lua's Unpack)
# ---------------------------------------------------------------------------------------------------------------
class Room:
    """V (n, 3) vertices, T (m, 3) triangles (0-based), blend per triangle ('D', 'A', 'B'), N unit normals (the
    renderer draws a face only to cameras on its N side), d plane offsets (N . x = d), area; heights: the height
    grid (rows south to north, nan = no floor), cell yd per cell."""


def load_room(key, path=None):
    path = path or os.path.join(ROOMS_DIR, key + ".lua")
    with open(path, "rb") as fh:
        src = fh.read().decode("utf-8")
    head = re.search(r'ns\.RoomFloors\["([^"]+)"\] = \{ version = 3, w = (\d+), h = (\d+), cell = (\d+), '
                     r'base = ([-\d.]+), step = ([-\d.]+), alphabet = "([^"]+)", size = (\d+),', src)
    if not head or head.group(1) != key:
        raise ValueError("%s: not a format 3 room file of %s" % (path, key))
    pieces = re.findall(r'^\s*"([^"]*)",\s*$', src, re.M)
    raw = inflate_raw(decode_for_print("".join(pieces)))
    if len(raw) != int(head.group(8)):
        raise ValueError("%s: unpacked %d bytes, the file says %s" % (path, len(raw), head.group(8)))
    parts = raw.decode("ascii").split("|")
    if len(parts) not in (7, 11):
        raise ValueError("%s: %d sections" % (path, len(parts)))
    r = Room()
    r.key, r.path = key, path
    r.w, r.h, r.cell = int(head.group(2)), int(head.group(3)), int(head.group(4))
    base, step, alphabet = float(head.group(5)), float(head.group(6)), head.group(7)
    idx = {c: i for i, c in enumerate(alphabet)}
    r.heights = np.array([[np.nan if ch == " " else idx[ch] * step + base for ch in row]
                          for row in parts[0].split("\n")])
    r.textures = [int(x) for x in parts[1].split()]
    r.blend_codes = parts[2].split()
    v = np.array(parts[3].split(), dtype=float).reshape(-1, 6)
    t = np.array(parts[4].split(), dtype=np.int64).reshape(-1, 4)
    r.V = v[:, :3].copy()
    r.T = t[:, :3] - 1
    r.blend = np.array([r.blend_codes[i - 1] for i in t[:, 3]])
    A, B, C = r.V[r.T[:, 0]], r.V[r.T[:, 1]], r.V[r.T[:, 2]]
    n = np.cross(B - A, C - A)
    ln = np.linalg.norm(n, axis=1)
    r.area = 0.5 * ln
    r.N = n / np.maximum(ln, 1e-12)[:, None]
    r.d = np.einsum("ij,ij->i", r.N, A)
    r.opaque = (r.blend == "D") & (r.area > 1e-9)
    r.lo, r.hi = r.V.min(0), r.V.max(0)
    return r


def floor_at(room, x, y):
    """The height grid's floor at a room point (nan where there is none)."""
    i, j = int(math.floor(x / room.cell)), int(math.floor(y / room.cell))
    if 0 <= j < room.heights.shape[0] and 0 <= i < room.heights.shape[1]:
        return room.heights[j, i]
    return float("nan")


# ---------------------------------------------------------------------------------------------------------------
# Planar regions
# ---------------------------------------------------------------------------------------------------------------
class Region:
    pass


def planar_regions(room):
    """Opaque faces grouped into planar regions: connected (a shared corner) and on one plane (corners within
    PLANE_TOL, normals within 3 degrees of the region's first, largest face). Every region gets its fitted plane,
    the spread of its corners about it and its kind: floor, ceiling, wall or slope."""
    key = np.round(room.V * 1000).astype(np.int64)
    _, vid = np.unique(key, axis=0, return_inverse=True)
    T = vid.reshape(-1)[room.T]
    vert_faces = collections.defaultdict(list)
    for f in np.nonzero(room.opaque)[0]:
        for x in T[f]:
            vert_faces[x].append(f)
    reg = -np.ones(len(T), np.int64)
    regions = []
    for s in np.argsort(-room.area):
        if not room.opaque[s] or reg[s] >= 0:
            continue
        rid = len(regions)
        reg[s] = rid
        n0, d0 = room.N[s], room.d[s]
        stack, members = [s], [s]
        while stack:
            f = stack.pop()
            for x in T[f]:
                for g in vert_faces[x]:
                    if reg[g] >= 0 or room.N[g] @ n0 < PLANE_COS:
                        continue
                    if np.abs(room.V[room.T[g]] @ n0 - d0).max() > PLANE_TOL:
                        continue
                    reg[g] = rid
                    stack.append(g)
                    members.append(g)
        g = Region()
        g.id = rid + 1
        g.tris = np.array(sorted(members))
        w = room.area[g.tris]
        n = (room.N[g.tris] * w[:, None]).sum(0)
        g.n = n / np.linalg.norm(n)
        P = room.V[room.T[g.tris]].reshape(-1, 3)
        off = P @ g.n
        g.d = float((off.max() + off.min()) / 2)
        g.dlo, g.dhi = float(off.min() - g.d), float(off.max() - g.d)
        g.area = float(w.sum())
        nz = g.n[2]
        if nz >= math.cos(FLOOR_TILT):
            g.kind = "floor"
        elif nz <= -math.cos(FLOOR_TILT):
            g.kind = "ceiling"
        elif abs(nz) <= math.sin(WALL_TILT):
            g.kind = "wall"
        else:
            g.kind = "slope"
        g.tilt = math.degrees(math.acos(min(1.0, abs(nz)))) if g.kind in ("floor", "ceiling") else \
            math.degrees(math.asin(min(1.0, abs(nz))))
        regions.append(g)
    room.region_of = reg
    # every face's kind for the check's breakdown: its region's (slope: left out), or 'other' (see-through, specks)
    kinds = np.array([KIND_CODES.get(g.kind, KIND_CODES["slope"]) for g in regions] + [KIND_CODES["other"]])
    room.face_kind = kinds[np.where(reg >= 0, reg, len(regions))]
    return regions


# ---------------------------------------------------------------------------------------------------------------
# Geometry helpers: sliding window min / max, the triangle-box test, a spatial index of the room's faces
# ---------------------------------------------------------------------------------------------------------------
def _slide(a, k, axis, op):
    """op (np.minimum / np.maximum) over windows of k along axis, anchored at the window's first element; the
    result is k - 1 shorter along that axis."""
    a = np.moveaxis(a, axis, 0)
    out, p = a, 1
    while p * 2 <= k:
        out = op(out[:-p], out[p:])
        p *= 2
    if p < k:
        out = op(out[:len(a) - k + 1], out[k - p:k - p + len(a) - k + 1])
    else:
        out = out[:len(a) - k + 1]
    return np.moveaxis(out, 0, axis)


def window(a, k, op):
    return _slide(_slide(a, k, 0, op), k, 1, op)


def box_sums(c, k):
    """Sums over k x k windows (anchored at their first cell) from the integral image c (padded with a 0 row and
    column)."""
    return c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]


def integral(a):
    c = np.zeros((a.shape[0] + 1, a.shape[1] + 1))
    c[1:, 1:] = np.cumsum(np.cumsum(a, 0), 1)
    return c


def tri_box_overlap(centre, axes, half, tris):
    """Does each triangle (n, 3, 3) touch the box (centre, rows of axes = its unit axes, half sizes)? The separating
    axis test (Akenine-Moller): the box's 3 axes, the triangle's normal, the 9 edge cross products."""
    v = (tris - centre) @ axes.T
    h = np.asarray(half, float)
    sep = np.zeros(len(v), bool)
    for k in range(3):
        sep |= (v[:, :, k].min(1) > h[k]) | (v[:, :, k].max(1) < -h[k])
    e = [v[:, 1] - v[:, 0], v[:, 2] - v[:, 1], v[:, 0] - v[:, 2]]
    n = np.cross(e[0], e[1])
    r = np.abs(n) @ h
    p = np.einsum("ij,ij->i", n, v[:, 0])
    sep |= np.abs(p) > r + 1e-12
    unit = np.eye(3)
    for ed in e:
        for k in range(3):
            ax = np.cross(unit[k], ed)
            p = np.einsum("ntj,nj->nt", v, ax)
            r = np.abs(ax) @ h
            sep |= (p.min(1) > r + 1e-12) | (p.max(1) < -r - 1e-12)
    return ~sep


class FaceIndex:
    """The room's faces (all of them, any blend and either side) by CELL yd square columns, for box queries."""
    CELL = 4.0

    def __init__(self, room):
        self.room = room
        P = room.V[room.T]
        self.P = P
        lo, hi = P.min(1), P.max(1)
        self.lo, self.hi = lo, hi
        self.cells = collections.defaultdict(list)
        c0 = np.floor(lo[:, :2] / self.CELL).astype(int)
        c1 = np.floor(hi[:, :2] / self.CELL).astype(int)
        for f in range(len(P)):
            for i in range(c0[f, 0], c1[f, 0] + 1):
                for j in range(c0[f, 1], c1[f, 1] + 1):
                    self.cells[(i, j)].append(f)
        self.cells = {k: np.array(v) for k, v in self.cells.items()}

    def near(self, lo, hi):
        i0, j0 = (int(math.floor(lo[0] / self.CELL)), int(math.floor(lo[1] / self.CELL)))
        i1, j1 = (int(math.floor(hi[0] / self.CELL)), int(math.floor(hi[1] / self.CELL)))
        got = [self.cells[(i, j)] for i in range(i0, i1 + 1) for j in range(j0, j1 + 1) if (i, j) in self.cells]
        if not got:
            return np.zeros(0, np.int64)
        f = np.unique(np.concatenate(got))
        ok = np.all(self.lo[f] <= hi, axis=1) & np.all(self.hi[f] >= lo, axis=1)
        return f[ok]

    def box_clear(self, centre, axes, half, skip=None):
        """No face touches the box (half sizes) -> True."""
        ext = np.abs(axes).T @ np.asarray(half, float)
        f = self.near(centre - ext, centre + ext)
        if skip is not None and len(f):
            f = f[~np.isin(f, skip)]
        if not len(f):
            return True
        return not tri_box_overlap(centre, axes, half, self.P[f]).any()


# ---------------------------------------------------------------------------------------------------------------
# Placement: squares in a region's plane, cubes behind it
# ---------------------------------------------------------------------------------------------------------------
class Frame:
    """A region's placement frame: a = the cube axis that faces out of the surface (the front side), e1, e2 = the
    cube's other axes (the grid's u, v); yaw = the cube's SetYaw."""


def region_frame(room, g):
    if g.kind in ("floor", "ceiling"):
        a = np.array([0.0, 0.0, 1.0 if g.kind == "floor" else -1.0])
        # the grid follows the region's longest outline edges (squares fit a straight edge exactly)
        psi = _edge_heading(room, g)
        e1 = np.array([math.cos(psi), math.sin(psi), 0.0])
        e2 = np.cross(a, e1)
        yaw = psi
    else:
        h = math.atan2(g.n[1], g.n[0])
        a = np.array([math.cos(h), math.sin(h), 0.0])
        e1 = np.array([-a[1], a[0], 0.0])
        e2 = np.array([0.0, 0.0, 1.0])
        yaw = h
    fr = Frame()
    fr.a, fr.e1, fr.e2, fr.yaw = a, e1, e2, yaw
    fr.R = np.stack([e1, e2, a])                 # rows: the cube's axes in room coordinates
    return fr


def _edge_heading(room, g):
    """The heading (mod 90 degrees) most of the region's outline runs along, length weighted."""
    cnt = collections.Counter()
    for f in g.tris:
        for i in range(3):
            a, b = room.T[f, i], room.T[f, (i + 1) % 3]
            cnt[(min(a, b), max(a, b))] += 1
    hist = np.zeros(90)
    for (i, j), c in cnt.items():
        if c != 1:
            continue                              # (inside the region: shared by two of its faces)
        p, q = room.V[i], room.V[j]
        dx, dy = q[0] - p[0], q[1] - p[1]
        ln = math.hypot(dx, dy)
        if ln < 1e-6:
            continue
        hist[int(math.degrees(math.atan2(dy, dx)) % 90) % 90] += ln
    if hist.sum() <= 0:
        return 0.0
    sm = hist + 0.5 * (np.roll(hist, 1) + np.roll(hist, -1))
    return math.radians(float(np.argmax(sm)))


class Cube:
    __slots__ = ("region", "u0", "v0", "s", "tf", "centre", "axes", "yaw", "n", "parent")


def _make_cube(g, fr, u0, v0, s):
    """The cube whose face square is [u0, u0 + s] x [v0, v0 + s] in the region's grid, its front as far out as the
    face allows: every corner of its front MARGIN behind the face (the plane's lowest corner, dlo)."""
    na, n1, n2 = g.n @ fr.a, g.n @ fr.e1, g.n @ fr.e2
    # n . (u e1 + v e2 + t a) <= d + dlo - MARGIN at the front's four corners
    worst = max(n1 * u + n2 * v for u in (u0, u0 + s) for v in (v0, v0 + s))
    tf = (g.d + g.dlo - MARGIN - worst) / na
    c = Cube()
    c.region, c.u0, c.v0, c.s, c.tf = g, u0, v0, s, tf
    c.centre = (u0 + s / 2) * fr.e1 + (v0 + s / 2) * fr.e2 + (tf - s / 2) * fr.a
    c.axes = fr.R
    c.yaw = fr.yaw
    c.n = g.n
    c.parent = None
    return c


def prepare_region(room, g, max_size=MAX_SIZE):
    """A region's frame, outline (in its grid's u, v) and the largest cube its tilt allows. -> False when it gets
    no stand-ins at all."""
    import shapely
    from shapely.geometry import Polygon
    from shapely.ops import unary_union
    fr = region_frame(room, g)
    g.frame = fr
    P = room.V[room.T[g.tris]]
    uv = np.stack([P @ fr.e1, P @ fr.e2], axis=-1)
    a2 = ((uv[:, 1, 0] - uv[:, 0, 0]) * (uv[:, 2, 1] - uv[:, 0, 1])
          - (uv[:, 2, 0] - uv[:, 0, 0]) * (uv[:, 1, 1] - uv[:, 0, 1]))
    poly = unary_union([Polygon(t) for t, a_ in zip(uv, a2) if abs(a_) > 1e-12])
    g.poly = poly
    g.inner = None
    if poly.is_empty:
        return False
    inner = poly.buffer(-EDGE_INSET, join_style=2)
    if inner.is_empty:
        return False
    shapely.prepare(inner)
    g.inner = inner
    na, n1, n2 = g.n @ fr.a, g.n @ fr.e1, g.n @ fr.e2
    g.na, g.n1, g.n2 = na, n1, n2
    # a tilted face over a cube of side s leaves a wedge s (|n1| + |n2|) / na deep: kept under TILT_GAP
    g.tiltk = (abs(n1) + abs(n2)) / na
    g.cap = max_size if g.tiltk < 1e-9 else min(max_size, TILT_GAP / g.tiltk)
    return g.cap >= MIN_SIZE


def size_ladder(cap, min_size):
    sizes, s = [], cap
    while s >= min_size - 1e-9:
        sizes.append(s)
        s *= SIZE_STEP
    if not sizes or sizes[-1] > min_size + 1e-9:
        sizes.append(min_size)
    return sizes


def level_of(g, s):
    """The probe level whose depth covers a cube of side s (the probes lie as deep as such a cube's back)."""
    for j, L in enumerate(LEVELS):
        if L >= s - 1e-9:
            return j
    return len(LEVELS) - 1


# ---------------------------------------------------------------------------------------------------------------
# Exposure: which points behind a region some pose could see past the room
# ---------------------------------------------------------------------------------------------------------------
class Probes:
    """Columns of points behind the placed regions, PROBE_STEP apart in each region's grid (and that far round its
    outline): per column its region (index into regs) and u, v; per column and depth (the cube's front, then the
    back of a cube of each LEVELS size) the room point P, the n . camera a cube there shows from (shown()) and
    whether a pose saw it (exposed)."""


def make_probes(room, regs):
    import shapely
    P, reg, uu, vv, thr = [], [], [], [], []
    depths = np.array((0.0,) + LEVELS)                 # (beyond MARGIN: the front, then each level's back)
    for ri, g in enumerate(regs):
        fr = g.frame
        h = PROBE_STEP
        zone = g.inner.buffer(h, join_style=2)
        u0, v0, u1, v1 = zone.bounds
        us = np.arange(math.floor(u0 / h), math.ceil(u1 / h) + 1) * h
        vs = np.arange(math.floor(v0 / h), math.ceil(v1 / h) + 1) * h
        U, Vv = np.meshgrid(us, vs)
        U, Vv = U.reshape(-1), Vv.reshape(-1)
        ok = shapely.contains_xy(zone, U, Vv)
        U, Vv = U[ok], Vv[ok]
        if not len(U):
            continue
        deep = MARGIN + depths * (1 + g.tiltk)                                  # (ncol, nlev) below the face
        t = ((g.d + g.dlo - g.n1 * U - g.n2 * Vv) / g.na)[:, None] - deep[None, :]
        X = (U[:, None, None] * fr.e1 + Vv[:, None, None] * fr.e2 + t[:, :, None] * fr.a)
        P.append(X)
        reg.append(np.full(len(U), ri))
        uu.append(U)
        vv.append(Vv)
        # a cube shows to cameras farther out along n than it reaches: its front, MARGIN behind the face (shown()),
        # whatever its size (a hair more, to be safe)
        thr.append(np.full((len(U), len(depths)), g.d + g.dlo - MARGIN - 0.01))
    pr = Probes()
    pr.P = np.concatenate(P)
    pr.reg = np.concatenate(reg)
    pr.u, pr.v = np.concatenate(uu), np.concatenate(vv)
    pr.thr = np.concatenate(thr)
    pr.n = np.array([g.n for g in regs])[pr.reg]
    pr.exposed = np.zeros(pr.P.shape[:2], bool)
    return pr


def expose(room, pr, cams, val_F=None, log=None):
    """Marks the probes some camera sees past the room: in view, shown by the facing rule, and the room face
    drawn at its pixel (the pixel's centre, as the check samples) not in front of it along the probe's own ray
    (that face's plane: far off, at a grazing angle, a pixel's centre and the probe can lie yards apart on it).
    The check forgives slivers its 1-pixel erosion removes, so neither does this: a probe counts only when the run
    of seen points down its column (from the last hidden one) is TOL_PX or more long on a screen of focal length
    val_F (the check's; default this camera's)."""
    nc, nl = pr.P.shape[:2]
    flatP = pr.P.reshape(-1, 3)
    for ci, cam in enumerate(cams):
        scale = (val_F or cam.F) / cam.F
        _, fb = render_room(room, cam)
        facing = (np.einsum("ij,j->i", pr.n, cam.C)[:, None] > pr.thr)
        seen = np.zeros(nc * nl, bool)
        sxy = np.zeros((nc * nl, 2))
        idx = np.nonzero(facing.reshape(-1))[0]
        q = cam.to_cam(flatP[idx])
        front = q[:, 2] > cam.near
        idx, q = idx[front], q[front]
        sx = cam.cx + cam.F * q[:, 0] / q[:, 2]
        sy = cam.cy - cam.F * q[:, 1] / q[:, 2]
        sxy[idx, 0], sxy[idx, 1] = sx, sy
        inv = (sx >= 0) & (sx < cam.W) & (sy >= 0) & (sy < cam.H)
        idx, sx, sy = idx[inv], sx[inv], sy[inv]
        f = fb[sy.astype(int), sx.astype(int)]
        d = flatP[idx] - cam.C
        dist = np.linalg.norm(d, axis=1)
        hid = np.zeros(len(idx), bool)
        k = f >= 0
        if k.any():
            Nf, df = room.N[f[k]], room.d[f[k]]
            den = np.einsum("ij,ij->i", Nf, d[k]) / dist[k]
            with np.errstate(divide="ignore", invalid="ignore"):
                zp = (df - Nf @ cam.C) / den
            hid[k] = np.isfinite(zp) & (zp > 0) & (zp < dist[k] - EPS_OVER)
        seen[idx[~hid]] = True
        seen = seen.reshape(nc, nl)
        if not seen.any():
            continue
        # the run of seen points down each column, from the last hidden one above it (or the front)
        lev = np.arange(nl)[None, :]
        last_hidden = np.maximum.accumulate(np.where(seen, -1, lev), axis=1)
        start = np.maximum(last_hidden, 0)
        S = sxy.reshape(nc, nl, 2)
        rows = np.arange(nc)[:, None]
        run = np.linalg.norm(S - S[rows, start], axis=2) * scale
        pr.exposed |= seen & (run >= TOL_PX)
        if log and (ci + 1) % 100 == 0:
            log("  exposure %d/%d poses: %.1f%% of probes seen" % (ci + 1, len(cams), 100 * pr.exposed.mean()))
    return pr


def blocked_masks(g, ri, pr, us, vs, r):
    """Per level: the grid cells a cube of that size may not cover (within PROBE_STEP of a column a pose saw at
    that depth or less), as cumulative masks."""
    nv, nu = len(vs) - 1, len(us) - 1
    sel = np.nonzero(pr.reg == ri)[0]
    seen = np.logical_or.accumulate(pr.exposed[sel], axis=1)       # (deeper sees whatever shallower did)
    i = np.floor((pr.u[sel] - us[0]) / r).astype(int)
    j = np.floor((pr.v[sel] - vs[0]) / r).astype(int)
    i, j = np.clip(i, 0, nu - 1), np.clip(j, 0, nv - 1)     # (a column just outside the outline blocks the edge)
    rad = int(math.ceil(PROBE_STEP / r))
    out = []
    for lv in range(1, seen.shape[1]):
        m = np.zeros((nv, nu), bool)
        k = seen[:, lv]
        m[j[k], i[k]] = True
        m = window(np.pad(m, rad, constant_values=False), 2 * rad + 1, np.maximum)
        out.append(m)
    return out


def place_region(room, g, ri, index, pr=None, min_size=MIN_SIZE, stats=None):
    """Cubes behind one prepared region: greedy squares on the region's grid, largest first. -> list of Cube."""
    import shapely
    from shapely.geometry import box as sbox
    fr, inner = g.frame, g.inner
    u_lo, v_lo, u_hi, v_hi = inner.bounds
    r = GRID
    while ((u_hi - u_lo) / r + 2) * ((v_hi - v_lo) / r + 2) > MAX_CELLS:
        r *= 1.25
    nu, nv = int(math.ceil((u_hi - u_lo) / r)) + 1, int(math.ceil((v_hi - v_lo) / r)) + 1
    us, vs = u_lo + np.arange(nu + 1) * r, v_lo + np.arange(nv + 1) * r
    # cells inside the outline (less the inset): their four corners and centre in it
    U, Vv = np.meshgrid(us, vs)
    pts = shapely.contains_xy(inner, U, Vv) | shapely.intersects_xy(inner.boundary, U, Vv)
    Uc, Vc = np.meshgrid(us[:-1] + r / 2, vs[:-1] + r / 2)
    ctr = shapely.contains_xy(inner, Uc, Vc)
    cell_in = pts[:-1, :-1] & pts[1:, :-1] & pts[:-1, 1:] & pts[1:, 1:] & ctr
    if not cell_in.any():
        return []
    # thickness: how far behind the face the next other room face lies, per cell (sampled points of every face
    # near the region's box; the exact triangle-box test below has the last word)
    thick = _thickness(room, g, fr, index, us, vs, r, g.cap)
    blocked = blocked_masks(g, ri, pr, us, vs, r) if pr is not None else None
    inside_sum = integral(cell_in.astype(np.float64))
    covered = ~cell_in
    out = []
    bad_total = 0
    for s in size_ladder(g.cap, min_size):
        k = int(math.floor(s / r + 1e-9))
        if k < 1 or k > min(cell_in.shape):
            continue
        s_eff = k * r
        fit = box_sums(inside_sum, k) >= k * k - 0.5
        fit &= window(thick, k, np.minimum) >= s_eff * (1 + g.tiltk) + MARGIN + BACK_GAP
        if blocked is not None:
            fit &= box_sums(integral(blocked[level_of(g, s_eff)].astype(np.float64)), k) < 0.5
        if not fit.any():
            continue
        bad = np.zeros_like(fit)
        while True:
            gain = box_sums(integral((~covered).astype(np.float64)), k)
            cand = fit & ~bad & (gain >= max(1.0, MIN_GAIN * k * k))
            if not cand.any():
                break
            # one round: the candidates by gain (ties: grid order, so squares pack flush from the first one that
            # fits), each taken unless it overlaps one taken this round (so every gain stays exact)
            flat = np.flatnonzero(cand)
            gv = gain.reshape(-1)[flat]
            if len(flat) > PICKS:
                top = np.argpartition(-gv, PICKS)[:PICKS]
                flat, gv = flat[top], gv[top]
            order = flat[np.lexsort((flat, -gv))]
            claimed = np.zeros(covered.shape, bool)
            tried = 0
            for f in order:
                j, i = divmod(int(f), cand.shape[1])
                if claimed[j:j + k, i:i + k].any():
                    continue
                tried += 1
                u0, v0 = us[i], vs[j]
                c = _make_cube(g, fr, u0, v0, s_eff)
                # inside the outline exactly; every other face BACK_GAP away (in front: half that, the cube's front
                # is MARGIN back); the region's own faces clear of the cube itself
                ok = inner.contains(sbox(u0, v0, u0 + s_eff, v0 + s_eff)) and \
                    index.box_clear(c.centre, fr.R, np.array([s_eff / 2 + BACK_GAP] * 2 + [s_eff / 2 + BACK_GAP / 2]),
                                    skip=g.tris) and \
                    index.box_clear(c.centre, fr.R, np.array([s_eff / 2 + BACK_GAP] * 2 + [s_eff / 2]))
                if not ok:
                    bad[j, i] = True
                    bad_total += 1
                    continue
                claimed[j:j + k, i:i + k] = True
                covered[j:j + k, i:i + k] = True
                out.append(c)
            if tried == 0:
                break
    if stats is not None:
        stats["rejected"] += bad_total
    return out


def _thickness(room, g, fr, index, us, vs, r, cap):
    """Per grid cell: the distance behind the region's face to the nearest other room face (inf when none within
    cap + margins), from points sampled on those faces every 0.7 cells."""
    nv, nu = len(vs) - 1, len(us) - 1
    thick = np.full((nv, nu), np.inf)
    depth = cap + MARGIN + BACK_GAP + 0.5
    # the region's box in room coordinates, pushed depth behind
    corners = []
    for u in (us[0], us[-1]):
        for v in (vs[0], vs[-1]):
            base = u * fr.e1 + v * fr.e2
            t_s = (g.d - g.n @ base) / (g.n @ fr.a)
            corners += [base + (t_s + 0.1) * fr.a, base + (t_s - depth) * fr.a]
    corners = np.array(corners)
    f = index.near(corners.min(0) - 0.1, corners.max(0) + 0.1)
    f = f[~np.isin(f, g.tris)]
    if not len(f):
        return thick
    na, n1, n2 = g.n @ fr.a, g.n @ fr.e1, g.n @ fr.e2
    step = 0.7 * r
    P = room.V[room.T[f]]
    for k0 in range(0, len(f), 256):
        Q = P[k0:k0 + 256]
        pts = []
        for t in Q:
            e1, e2 = t[1] - t[0], t[2] - t[0]
            m1 = max(1, int(math.ceil(np.linalg.norm(e1) / step)))
            m2 = max(1, int(math.ceil(np.linalg.norm(e2) / step)))
            m = max(m1, m2)
            if m > 4000:
                m = 4000
            a_, b_ = np.meshgrid(np.arange(m + 1), np.arange(m + 1))
            keep = a_ + b_ <= m
            a_, b_ = a_[keep] / m, b_[keep] / m
            pts.append(t[0] + a_[:, None] * e1 + b_[:, None] * e2)
        X = np.concatenate(pts)
        u, v, t = X @ fr.e1, X @ fr.e2, X @ fr.a
        t_surf = (g.d - n1 * u - n2 * v) / na
        behind = t_surf - t
        # (faces between the face and the cube's front are in front of the cube: no obstacle)
        sel = (behind > MARGIN * 0.5) & (behind < depth)
        if not sel.any():
            continue
        i = np.floor((u[sel] - us[0]) / r).astype(int)
        j = np.floor((v[sel] - vs[0]) / r).astype(int)
        b = behind[sel]
        # a sample counts for its cell and the neighbours (it may sit on a cell's edge)
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                ii, jj = i + di, j + dj
                okk = (ii >= 0) & (ii < nu) & (jj >= 0) & (jj < nv)
                np.minimum.at(thick, (jj[okk], ii[okk]), b[okk])
    return thick


# ---------------------------------------------------------------------------------------------------------------
# A z-buffer rasterizer (numpy): exact per-pixel depth from each triangle's plane, near plane clipped
# ---------------------------------------------------------------------------------------------------------------
class Camera:
    def __init__(self, pos, heading, pitch, W=480, H=320, fov=FOV, near=NEAR, name=""):
        self.C = np.asarray(pos, float)
        cp, sp, ch, sh = math.cos(pitch), math.sin(pitch), math.cos(heading), math.sin(heading)
        self.f = np.array([cp * ch, cp * sh, -sp])
        self.r = np.array([sh, -ch, 0.0])
        self.u = np.cross(self.r, self.f)
        self.W, self.H, self.near = W, H, near
        self.F = (H / 2.0) / math.tan(fov / 2.0)
        self.cx, self.cy = W / 2.0, H / 2.0
        self.heading, self.pitch, self.name = heading, pitch, name

    def to_cam(self, P):
        d = np.asarray(P, float) - self.C
        return np.stack([d @ self.r, d @ self.u, d @ self.f], axis=-1)

    def ray_dirs(self):
        jj, ii = np.mgrid[0:self.H, 0:self.W]
        a = (ii + 0.5 - self.cx) / self.F
        b = -(jj + 0.5 - self.cy) / self.F
        d = a[..., None] * self.r + b[..., None] * self.u + self.f
        return d / np.linalg.norm(d, axis=-1)[..., None]

    def sees_sphere(self, centres, radii):
        """Which spheres touch the view frustum (near plane and the four sides)."""
        q = self.to_cam(centres)
        tx = (self.W / 2.0) / self.F
        ty = (self.H / 2.0) / self.F
        ok = q[:, 2] + radii >= self.near
        for s, t in ((1, tx), (-1, tx)):
            ok &= (q[:, 2] * t - s * q[:, 0]) / math.sqrt(1 + t * t) >= -radii
        for s, t in ((1, ty), (-1, ty)):
            ok &= (q[:, 2] * t - s * q[:, 1]) / math.sqrt(1 + t * t) >= -radii
        return ok


def orbit(target, heading, pitch, dist, **kw):
    """The board's View:Orbit: the camera dist back from the target, looking along heading / pitch."""
    cp, sp = math.cos(pitch), math.sin(pitch)
    f = np.array([cp * math.cos(heading), cp * math.sin(heading), -sp])
    return Camera(np.asarray(target, float) - f * dist, heading, pitch, **kw)


def _clip_near(P, near):
    out = []
    n = len(P)
    for i in range(n):
        a, b = P[i], P[(i + 1) % n]
        ina, inb = a[2] >= near, b[2] >= near
        if ina:
            out.append(a)
        if ina != inb:
            t = (near - a[2]) / (b[2] - a[2])
            out.append(a + (b - a) * t)
    return out


BUCKETS = (2, 4, 8, 16, 32, 64)


def raster(cam, tris_cam, ids, zbuf=None, idbuf=None):
    """Z-buffers triangles given in camera coordinates (n, 3, 3) into zbuf (distance along the pixel's ray, inf =
    nothing) and idbuf (the nearest one's id, -1 = none). Draws every triangle given, whichever way it faces."""
    W, H, near, F = cam.W, cam.H, cam.near, cam.F
    if zbuf is None:
        zbuf = np.full((H, W), np.inf)
        idbuf = np.full((H, W), -1, dtype=np.int64)
    if len(tris_cam) == 0:
        return zbuf, idbuf
    tris_cam = np.asarray(tris_cam, float)
    ids = np.asarray(ids)
    pn = np.cross(tris_cam[:, 1] - tris_cam[:, 0], tris_cam[:, 2] - tris_cam[:, 0])
    pk = np.einsum("ij,ij->i", pn, tris_cam[:, 0])
    z = tris_cam[:, :, 2]
    keep = z.max(axis=1) >= near
    tri_list, plane_idx = [], []
    allin = keep & (z.min(axis=1) >= near)
    if allin.any():
        tri_list.append(tris_cam[allin])
        plane_idx.append(np.nonzero(allin)[0])
    for k in np.nonzero(keep & ~allin)[0]:
        poly = _clip_near(list(tris_cam[k]), near)
        for j in range(1, len(poly) - 1):
            tri_list.append(np.array([[poly[0], poly[j], poly[j + 1]]]))
            plane_idx.append(np.array([k]))
    if not tri_list:
        return zbuf, idbuf
    T = np.concatenate(tri_list)
    src = np.concatenate(plane_idx)
    sx = cam.cx + F * T[:, :, 0] / T[:, :, 2]
    sy = cam.cy - F * T[:, :, 1] / T[:, :, 2]
    with np.errstate(invalid="ignore"):
        i0 = np.maximum(0, np.ceil(sx.min(1) - 0.5)).astype(np.int64)
        i1 = np.minimum(W - 1, np.floor(sx.max(1) - 0.5)).astype(np.int64)
        j0 = np.maximum(0, np.ceil(sy.min(1) - 0.5)).astype(np.int64)
        j1 = np.minimum(H - 1, np.floor(sy.max(1) - 0.5)).astype(np.int64)
    ok = (i1 >= i0) & (j1 >= j0)
    area2 = (sx[:, 1] - sx[:, 0]) * (sy[:, 2] - sy[:, 0]) - (sx[:, 2] - sx[:, 0]) * (sy[:, 1] - sy[:, 0])
    ok &= np.abs(area2) > 1e-12
    bw, bh = i1 - i0 + 1, j1 - j0 + 1
    size = np.maximum(bw, bh)
    pix_all, dist_all, id_all = [], [], []

    def emit(sel, Bw, Bh):
        n = len(sel)
        if n == 0:
            return
        oy, ox = np.mgrid[0:Bh, 0:Bw]
        step = max(1, 3_000_000 // (Bw * Bh))
        for c0 in range(0, n, step):
            s = sel[c0:c0 + step]
            px = i0[s][:, None, None] + ox[None]
            py = j0[s][:, None, None] + oy[None]
            inside = (ox[None] < bw[s][:, None, None]) & (oy[None] < bh[s][:, None, None])
            fx, fy = px + 0.5, py + 0.5
            sgn = np.sign(area2[s])[:, None, None]
            for e in range(3):
                ax, ay = sx[s, e][:, None, None], sy[s, e][:, None, None]
                bx, by = sx[s, (e + 1) % 3][:, None, None], sy[s, (e + 1) % 3][:, None, None]
                inside &= sgn * ((bx - ax) * (fy - ay) - (by - ay) * (fx - ax)) >= 0
            if not inside.any():
                continue
            tt, yy, xx = np.nonzero(inside)
            gx, gy = px[tt, yy, xx], py[tt, yy, xx]
            so = src[s][tt]
            a = (gx + 0.5 - cam.cx) / F
            b = -(gy + 0.5 - cam.cy) / F
            den = pn[so, 0] * a + pn[so, 1] * b + pn[so, 2]
            with np.errstate(divide="ignore", invalid="ignore"):
                depth = pk[so] / den
            good = np.isfinite(depth) & (depth >= near * 0.999)
            dist = depth * np.sqrt(1 + a * a + b * b)
            pix_all.append((gy * W + gx)[good])
            dist_all.append(dist[good])
            id_all.append(ids[so][good])
    prev = 0
    for B in BUCKETS:
        emit(np.nonzero(ok & (size > prev) & (size <= B))[0], B, B)
        prev = B
    for k in np.nonzero(ok & (size > prev))[0]:
        emit(np.array([k]), int(bw[k]), int(bh[k]))
    if pix_all:
        pix = np.concatenate(pix_all)
        dist = np.concatenate(dist_all)
        idv = np.concatenate(id_all)
        flat = zbuf.reshape(-1)
        np.minimum.at(flat, pix, dist)
        win = dist <= flat[pix]
        idbuf.reshape(-1)[pix[win]] = idv[win]
    return zbuf, idbuf


# the unit cube's six faces as quads (local coordinates, outward normals): two triangles each
_CUBE_FACES = []
for _ax in range(3):
    for _sg in (1, -1):
        _n = np.zeros(3)
        _n[_ax] = _sg
        _o = [k for k in range(3) if k != _ax]
        _q = []
        for (_a, _b) in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            _p = np.zeros(3)
            _p[_ax] = _sg
            _p[_o[0]], _p[_o[1]] = _a, _b
            _q.append(_p * 0.5)
        _CUBE_FACES.append((_n, np.array(_q)))


def render_room(room, cam):
    """The room as the renderer draws it, opaque faces only: (distance, face id) per pixel."""
    A = room.V[room.T]
    front = room.opaque & (room.N @ cam.C - room.d > 0)
    f = np.nonzero(front)[0]
    return raster(cam, cam.to_cam(A[f]), f)


def standin_arrays(cubes):
    """Centres (n, 3), axes (n, 3, 3) rows, sizes (n,), normals (n, 3) of a cube list."""
    if not cubes:
        return np.zeros((0, 3)), np.zeros((0, 3, 3)), np.zeros(0), np.zeros((0, 3))
    return (np.array([c.centre for c in cubes]), np.array([c.axes for c in cubes]),
            np.array([c.s for c in cubes]), np.array([c.n for c in cubes]))


def shown(cam, arr, rule=RULE):
    """Which stand-ins show: their surface faces the camera and they are in view. Rule 'reach' (Render3D/Standins.lua
    today): the camera farther out along n than the stand-in reaches (the surface lies at least that far out, so a
    camera less far is behind it). Rule 'guard' (this generator's default): farther out than that by the near clip
    too - a camera nearer a surface than the near clip sees it clipped away and would see the stand-in behind it
    with nothing drawn in front. Rule 'centre': the data contract's looser wording, dot(n, camera - origin) > 0,
    which also shows a stand-in to a camera between its surface and its centre."""
    C, R, S, N = arr
    if not len(C):
        return np.zeros(0, bool)
    out = 0.0
    if rule in ("reach", "guard"):
        out = S / 2 * np.abs(np.einsum("ij,ikj->ik", N, R)).sum(1)
        if rule == "guard":
            out = out + cam.near
    facing = np.einsum("ij,ij->i", N, cam.C - C) > out
    return facing & cam.sees_sphere(C, S * math.sqrt(3) / 2)


def render_standins(cam, arr, show=None):
    """The stand-ins the runtime shows: (distance, stand-in index) per pixel."""
    C, R, S, N = arr
    if show is None:
        show = shown(cam, arr)
    idx = np.nonzero(show)[0]
    if not len(idx):
        return np.full((cam.H, cam.W), np.inf), np.full((cam.H, cam.W), -1, np.int64)
    tris, ids = [], []
    for n_loc, q in _CUBE_FACES:
        nw = np.einsum("j,ijk->ik", n_loc, R[idx])               # the face's normal in room coordinates
        ctr = C[idx] + np.einsum("j,ijk->ik", n_loc * 0.5, R[idx]) * S[idx][:, None]
        vis = np.einsum("ij,ij->i", nw, cam.C - ctr) > 0          # (a closed box: its front faces are enough)
        if not vis.any():
            continue
        sel = idx[vis]
        corners = C[sel][:, None, :] + np.einsum("qj,ijk->iqk", q, R[sel]) * S[sel][:, None, None]
        tris.append(corners[:, [0, 1, 2]])
        tris.append(corners[:, [0, 2, 3]])
        ids += [sel, sel]
    T = np.concatenate(tris)
    I = np.concatenate(ids)
    return raster(cam, cam.to_cam(T), I)


def erode(m):
    """A 1-pixel erosion (3 x 3 cross)."""
    e = m.copy()
    e[1:, :] &= m[:-1, :]
    e[:-1, :] &= m[1:, :]
    e[:, 1:] &= m[:, :-1]
    e[:, :-1] &= m[:, 1:]
    e[0, :] = e[-1, :] = False
    e[:, 0] = e[:, -1] = False
    return e


def dilate(m):
    e = m.copy()
    e[1:, :] |= m[:-1, :]
    e[:-1, :] |= m[1:, :]
    e[:, 1:] |= m[:, :-1]
    e[:, :-1] |= m[:, 1:]
    return e


def _over_air(room, cam, d, zs, zr, mask):
    """How many of the masked pixels could hide a model: the ray past the stand-in (up to the room, or AIR_RUN yd)
    runs through the air over the boss' floor (up to AIR_H over the height grid's floor)."""
    jj, ii = np.nonzero(mask)
    if not len(jj):
        return 0
    t0 = zs[jj, ii]
    t1 = np.minimum(zr[jj, ii], t0 + AIR_RUN)
    hit = np.zeros(len(jj), bool)
    for f in np.linspace(0.0, 1.0, int(AIR_RUN / 0.25) + 1):
        X = cam.C + d[jj, ii] * (t0 + (t1 - t0) * f)[:, None]
        ci = np.floor(X[:, 0] / room.cell).astype(int)
        cj = np.floor(X[:, 1] / room.cell).astype(int)
        ok = (ci >= 0) & (ci < room.heights.shape[1]) & (cj >= 0) & (cj < room.heights.shape[0])
        h = np.full(len(jj), np.nan)
        h[ok] = room.heights[cj[ok], ci[ok]]
        with np.errstate(invalid="ignore"):
            hit |= np.isfinite(h) & (np.abs(h) <= 3.0) & (X[:, 2] >= h + 0.1) & (X[:, 2] <= h + AIR_H)
    return int(hit.sum())


def measure(room, cam, arr, room_buf=None, rule=None):
    """One pose: the over-occlusion and coverage numbers, the stand-ins seen doing it, the buffers for pictures."""
    zr, fr = room_buf if room_buf is not None else render_room(room, cam)
    show = shown(cam, arr, rule or RULE)
    zs, ids = render_standins(cam, arr, show)
    drawn = fr >= 0
    has = ids >= 0
    over = has & (~drawn | (zs < zr - EPS_OVER))
    over_e = erode(over)
    # the gap behind the drawn face along its normal: (distance difference) x |cos| of the ray and the face
    d = cam.ray_dirs()
    cosn = np.zeros(zr.shape)
    cosn[drawn] = np.abs(np.einsum("ij,ij->i", d[drawn], room.N[fr[drawn]]))
    with np.errstate(invalid="ignore"):
        gap = np.where(drawn & has, (zs - zr) * cosn, np.inf)
    res = dict(name=cam.name, drawn=int(drawn.sum()), over=int(over.sum()), over_eroded=int(over_e.sum()),
               shown=int(show.sum()),
               covered=int((drawn & (gap <= MARGIN + EPS_UNDER)).sum()),
               covered_any=int((drawn & has & (zs >= zr - EPS_OVER)).sum()))
    for t in LOOSE:
        res["covered_%g" % t] = int((drawn & (gap <= t)).sum())
    res["over_air"] = _over_air(room, cam, d, zs, zr, over_e) if res["over_eroded"] else 0
    # by the kind of face drawn (room.face_kind, when planar_regions has run): drawn, covered (strict), covered (any)
    fk = getattr(room, "face_kind", None)
    if fk is not None:
        k = np.where(drawn, fk[np.maximum(fr, 0)], -1)
        good = drawn & (gap <= MARGIN + EPS_UNDER)
        anyc = drawn & has & (zs >= zr - EPS_OVER)
        for name, code in KIND_CODES.items():
            m = k == code
            res["k_" + name] = (int(m.sum()), int((m & good).sum()), int((m & anyc).sum()))
    culprits = np.unique(ids[dilate(over_e) & over & has]) if res["over_eroded"] else np.zeros(0, np.int64)
    bufs = dict(zr=zr, fr=fr, zs=zs, ids=ids, over=over, over_e=over_e, gap=gap)
    return res, culprits, bufs


# ---------------------------------------------------------------------------------------------------------------
# Camera poses: orbits round the room (the board's camera) and walking poses inside it
# ---------------------------------------------------------------------------------------------------------------
def _ray_hit(room, o, d, tmax):
    """The first face (either side) along o + t d, 0 < t <= tmax: t or None (Moller-Trumbore over all faces)."""
    P = room.V[room.T]
    e1, e2 = P[:, 1] - P[:, 0], P[:, 2] - P[:, 0]
    p = np.cross(d, e2)
    det = np.einsum("ij,ij->i", e1, p)
    ok = np.abs(det) > 1e-12
    inv = np.where(ok, 1.0 / np.where(ok, det, 1), 0)
    s = o - P[:, 0]
    u = np.einsum("ij,ij->i", s, p) * inv
    q = np.cross(s, e1)
    v = (q @ d) * inv
    t = np.einsum("ij,ij->i", e2, q) * inv
    hit = ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (t > 1e-4) & (t <= tmax)
    return float(t[hit].min()) if hit.any() else None


def _floor_cells(room):
    """The height grid's cells near the boss' floor (within 3 yd): where the board's camera looks and you walk."""
    hs = room.heights
    return np.isfinite(hs) & (np.abs(hs) <= 3.0)


def _walk_spots(room, n, rng):
    """Points on the boss' floor away from its edges (two cells of floor all round)."""
    ok = _floor_cells(room)
    good = ok.copy()
    for dj in (-2, -1, 0, 1, 2):
        for di in (-2, -1, 0, 1, 2):
            good &= np.roll(np.roll(ok, dj, 0), di, 1)
    jj, ii = np.nonzero(good)
    pick = rng.choice(len(jj), size=min(n, len(jj)), replace=False)
    return [((ii[k] + 0.5) * room.cell, (jj[k] + 0.5) * room.cell, room.heights[jj[k], ii[k]]) for k in pick]


def _rim_spots(room, centre, n):
    """n points on the boss' floor next to its outer edge, spread round the centre: where a camera close by and
    low sees the floor past the room's walls (they face away from it)."""
    ok = _floor_cells(room)
    edge = np.zeros_like(ok)
    for dj in range(-3, 4):
        for di in range(-3, 4):
            edge |= ~np.roll(np.roll(ok, dj, 0), di, 1)
    jj, ii = np.nonzero(ok & edge)
    x, y = (ii + 0.5) * room.cell, (jj + 0.5) * room.cell
    ang = np.arctan2(y - centre[1], x - centre[0])
    rad = np.hypot(x - centre[0], y - centre[1])
    out = []
    for k in range(n):
        a = -math.pi + (k + 0.5) * 2 * math.pi / n
        sel = np.abs((ang - a + math.pi) % (2 * math.pi) - math.pi) < math.pi / n
        if sel.any():
            m = np.nonzero(sel)[0][np.argmax(rad[sel])]
            out.append((x[m], y[m], room.heights[jj[m], ii[m]]))
    return out


def poses(room, view, spot, kind="train", W=480, H=320, seed=1):
    """The camera poses the stand-ins are placed and checked against (UI/StrategyMap3D.lua's cameras):
    'train': orbits round the room's first view point (6 pitches 0.15 - 1.5, a quarter of its distance, its
    distance and the farthest the board allows, 12 headings) and the boss (6 pitches, 6 headings); low orbits close
    by the floor's outer edge looking in (the camera stands outside the room's walls, which face away from it);
    walking poses (behind and over your character, 7 yd back, pulled in where the room is in the way) and eye-level
    poses at spots on the floor.
    'random': orbits round random floor points (heading, pitch 0.12 - 1.5, distance 2 yd - the farthest, log
    uniform) and random walking poses: poses the placement never saw."""
    rng = np.random.default_rng(seed)
    out = []
    vx, vy, vdist = view
    far = vdist * 2.2

    def ground(x, y):
        z = floor_at(room, x, y)
        return 0.0 if not np.isfinite(z) else float(z)

    def lift(dist):
        return EYE * max(0.0, min(1.0, (5 - dist) / (5 - 0.3)))

    def add_orbit(x, y, h, p, dist, name):
        out.append(orbit((x, y, ground(x, y) + lift(dist)), h, p, dist, W=W, H=H, name=name))

    def add_walk(x, y, z, h, p, dist, name):
        tgt = np.array([x, y, z + WALK_EYE])
        cp = math.cos(p)
        f = np.array([cp * math.cos(h), cp * math.sin(h), -math.sin(p)])
        r = np.array([math.sin(h), -math.cos(h), 0.0])
        u = np.cross(r, f)
        best = None
        for (a, b) in ((0, 0), (0.35, 0.25), (0.35, -0.25), (-0.35, 0.25), (-0.35, -0.25)):
            dd = -f * dist + a * r + b * u
            ln = np.linalg.norm(dd)
            t = _ray_hit(room, tgt, dd / ln, ln)
            if t is not None:
                best = t / ln if best is None else min(best, t / ln)
        allowed = dist if best is None else min(dist, max(0.8, best * dist - 0.6))
        out.append(orbit(tgt, h, p, allowed, W=W, H=H, name=name))

    if kind == "train":
        heads = [k * math.pi / 6 + 0.13 for k in range(12)]
        for p in (0.15, 0.35, 0.6, 0.9, 1.2, 1.5):
            for dist in (vdist * 0.25, vdist, far):
                for h in heads:
                    add_orbit(vx, vy, h, p, dist, "view h%.2f p%.2f d%.0f" % (h, p, dist))
            for h in heads[::2]:
                add_orbit(spot[0], spot[1], h, p, vdist * 0.45, "boss h%.2f p%.2f" % (h, p))
        for (x, y, z) in _rim_spots(room, (vx, vy), 12):
            inward = math.atan2(vy - y, vx - x)
            for p in (0.15, 0.4):
                for dist in (8.0, 20.0, 45.0):
                    add_orbit(x, y, inward, p, dist, "rim %.0f,%.0f p%.2f d%.0f" % (x, y, p, dist))
                for dh in (-0.6, 0.6):
                    add_orbit(x, y, inward + dh, p, 20.0, "rim %.0f,%.0f h%+.1f p%.2f" % (x, y, dh, p))
        for (x, y, z) in _walk_spots(room, 12, rng):
            for k in range(6):
                h = k * math.pi / 3 + 0.4
                add_walk(x, y, z, h, 0.32, 7.0, "walk %.0f,%.0f h%.2f" % (x, y, h))
                add_walk(x, y, z, h + 0.5, -0.1, 0.3, "eye %.0f,%.0f h%.2f" % (x, y, h + 0.5))
    else:
        ok = _floor_cells(room)
        jj, ii = np.nonzero(ok)
        for k in range(60):
            m = rng.integers(len(jj))
            x, y = (ii[m] + rng.uniform()) * room.cell, (jj[m] + rng.uniform()) * room.cell
            h = rng.uniform(0, 2 * math.pi)
            p = rng.uniform(PITCH_MIN, PITCH_TOP)
            dist = math.exp(rng.uniform(math.log(2.0), math.log(far)))
            add_orbit(x, y, h, p, dist, "rand %d" % k)
        for (x, y, z) in _walk_spots(room, 30, rng):
            h = rng.uniform(0, 2 * math.pi)
            p = rng.uniform(-0.5, 1.2)
            add_walk(x, y, z, h, p, rng.uniform(1.5, 15.0), "rwalk %.0f,%.0f" % (x, y))
    return out


# ---------------------------------------------------------------------------------------------------------------
# The whole run: place, repair against the poses, report, write
# ---------------------------------------------------------------------------------------------------------------
def room_view(key):
    """The room's first view (x, y, dist) and boss spot (x, y) from Render3D/Rooms/Index.lua."""
    with open(os.path.join(ROOMS_DIR, "Index.lua"), "rb") as fh:
        src = fh.read().decode("utf-8")
    m = re.search(r'floor = "%s".*?view = \{ x = ([-\d.]+), y = ([-\d.]+), dist = ([-\d.]+) \}, '
                  r'spot = \{ x = ([-\d.]+), y = ([-\d.]+) \}' % re.escape(key), src, re.S)
    if not m:
        raise ValueError("%s: not in Render3D/Rooms/Index.lua" % key)
    v = [float(x) for x in m.groups()]
    return (v[0], v[1], v[2]), (v[3], v[4])


def split(c):
    """A cube's four quarters (half size, the same front plane: each lies inside it, so it hides nothing the
    cube did not)."""
    g, fr, h = c.region, c.region.frame, c.s / 2
    out = []
    for du in (0, h):
        for dv in (0, h):
            k = Cube()
            k.region, k.u0, k.v0, k.s, k.tf = g, c.u0 + du, c.v0 + dv, h, c.tf
            k.centre = (k.u0 + h / 2) * fr.e1 + (k.v0 + h / 2) * fr.e2 + (c.tf - h / 2) * fr.a
            k.axes, k.yaw, k.n, k.parent = c.axes, c.yaw, c.n, c
            out.append(k)
    return out


def repair(room, cubes, cams, log=print, min_size=MIN_SIZE):
    """Pose by pose: every stand-in that hides something the room does not (after the 1-pixel erosion) is cut
    into quarters, again until the pose is clean; under min_size it goes. Quarters lie inside their cube and show
    for no more cameras (their front is the cube's), so a pose made clean stays clean. -> cubes, counts, every
    pose's last numbers, the index of the last pose that changed the set (numbers of the poses before it are of
    an older set)."""
    counts = collections.Counter()
    results, last = [], -1
    for pi, cam in enumerate(cams):
        rb = render_room(room, cam)
        rounds = 0
        while True:
            arr = standin_arrays(cubes)
            res, culprits, _ = measure(room, cam, arr, rb)
            if not len(culprits):
                break
            rounds += 1
            bad = set(int(i) for i in culprits)
            keep = [c for i, c in enumerate(cubes) if i not in bad]
            for i in bad:
                c = cubes[i]
                if c.s / 2 >= min_size - 1e-9:
                    keep += split(c)
                    counts["split"] += 1
                else:
                    counts["removed"] += 1
            cubes = keep
            last = pi
            if rounds > 40:
                raise RuntimeError("repair does not converge at pose %s" % cam.name)
        results.append(res)
        if rounds:
            counts["poses"] += 1
            log("  repair %3d/%d %-28s %d rounds, %d stand-ins" % (pi + 1, len(cams), cam.name, rounds, len(cubes)))
    return cubes, counts, results, last


def evaluate(room, cubes, cams, rule=None):
    """Every pose's numbers (measure) -> list of dicts."""
    arr = standin_arrays(cubes)
    return [measure(room, cam, arr, rule=rule)[0] for cam in cams]


def summarize(results):
    drawn = np.array([r["drawn"] for r in results], float)
    cov = np.array([r["covered"] for r in results], float)
    s = dict(poses=len(results),
             over_eroded=int(sum(r["over_eroded"] for r in results)),
             over_raw=int(sum(r["over"] for r in results)),
             over_air=int(sum(r["over_air"] for r in results)),
             coverage=float(cov.sum() / max(1.0, drawn.sum())),
             coverage_any=float(sum(r["covered_any"] for r in results) / max(1.0, drawn.sum())),
             shown_median=float(np.median([r["shown"] for r in results])),
             shown_p90=float(np.percentile([r["shown"] for r in results], 90)),
             shown_max=int(max(r["shown"] for r in results)))
    for t in LOOSE:
        s["coverage_%g" % t] = float(sum(r["covered_%g" % t] for r in results) / max(1.0, drawn.sum()))
    per = sorted((r["covered"] / r["drawn"] if r["drawn"] else 1.0, r["name"]) for r in results)
    s["worst"] = per[:5]
    for name in KIND_CODES:
        t = np.array([r.get("k_" + name, (0, 0, 0)) for r in results], float).sum(0)
        s["kind_" + name] = (float(t[0] / max(1.0, drawn.sum())), float(t[1] / max(1.0, t[0])),
                             float(t[2] / max(1.0, t[0])))
    return s


def region_areas(room, regions, cubes):
    """Areas (yd^2): opaque / see-through faces, regions by kind, and how much of the placed regions' outline
    the stand-ins' squares cover."""
    from shapely.geometry import box as sbox
    from shapely.ops import unary_union
    a = dict(opaque=float(room.area[room.opaque].sum()),
             alphakey=float(room.area[room.blend == "A"].sum()),
             blend=float(room.area[room.blend == "B"].sum()))
    for g in regions:
        a[g.kind] = a.get(g.kind, 0.0) + g.area
    by = collections.defaultdict(list)
    for c in cubes:
        by[c.region.id].append(sbox(c.u0, c.v0, c.u0 + c.s, c.v0 + c.s))
    cov = collections.Counter()
    for g in regions:
        if g.kind != "slope" and g.id in by and hasattr(g, "poly"):
            cov[g.kind] += unary_union(by[g.id]).intersection(g.poly).area
    for k, v in cov.items():
        a["%s_covered" % k] = float(v)
    return a


def build(key=DEFAULT_KEY, fast=False, log=print, W=None, H=None, limit=None):
    """The whole run for one room. fast: fewer and smaller poses (tests); limit: only the largest regions."""
    t0 = time.time()
    room = load_room(key)
    view, spot = room_view(key)
    regions = planar_regions(room)
    index = FaceIndex(room)
    stats = collections.Counter()
    regs = [g for g in sorted(regions, key=lambda g: -g.area) if g.kind != "slope" and prepare_region(room, g)]
    if limit:
        regs = regs[:limit]
    if W is None:
        W, H = (320, 214) if fast else (960, 640)
    EW, EH = (240, 160) if fast else (480, 320)
    train = poses(room, view, spot, "train", W=W, H=H)
    train_e = poses(room, view, spot, "train", W=EW, H=EH)
    if fast:
        train, train_e = train[::7], train_e[::7]
    pr = make_probes(room, regs)
    expose(room, pr, train_e, val_F=(H / 2.0) / math.tan(FOV / 2.0), log=log)
    log("%s: %d regions (%d get stand-ins), %d probes, %d seen by a pose (%.0f s)"
        % (key, len(regions), len(regs), len(pr.P), pr.exposed.sum(), time.time() - t0))
    cubes = []
    for ri, g in enumerate(regs):
        cubes += place_region(room, g, ri, index, pr, stats=stats)
    placed = len(cubes)
    log("%d stand-ins placed (%.0f s)" % (placed, time.time() - t0))
    cubes, rc, res_train, last = repair(room, cubes, train, log=log)
    log("repair: %d stand-ins (%d split, %d removed, %d poses needed it) (%.0f s)"
        % (len(cubes), rc["split"], rc["removed"], rc["poses"], time.time() - t0))
    if last > 0:                                   # (the poses before the last change saw an older set)
        res_train[:last] = evaluate(room, cubes, train[:last])
    rand = poses(room, view, spot, "random", W=W, H=H, seed=7)
    if fast:
        rand = rand[::6]
    res_rand = evaluate(room, cubes, rand)
    # the same random poses under the runtime's rule as it is today (no near-plane guard): what changes is only
    # cameras nearer a surface than the near clip
    res_rand_reach = evaluate(room, cubes, rand, rule="reach")
    return dict(key=key, room=room, regions=regions, cubes=cubes, placed=placed, repair=dict(rc),
                train=summarize(res_train), random=summarize(res_rand), random_reach=summarize(res_rand_reach),
                res_train=res_train, res_rand=res_rand, res_rand_reach=res_rand_reach,
                areas=region_areas(room, regions, cubes), stats=dict(stats), view=view, spot=spot,
                seconds=time.time() - t0, size=(W, H), probes=pr)


def _num(v, places):
    s = ("%." + str(places) + "f") % v
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def records(cubes):
    """The data contract's 12 numbers per stand-in (prim, x, y, z, yaw, pitch, roll, scale, nx, ny, nz, face)."""
    out = []
    for c in sorted(cubes, key=lambda c: (c.region.id, c.u0, c.v0)):
        yaw = (c.yaw + math.pi) % (2 * math.pi) - math.pi
        out.append((CUBE, c.centre[0], c.centre[1], c.centre[2], yaw, 0.0, 0.0, c.s / (2 * PRIMS[CUBE]["half"]),
                    c.n[0], c.n[1], c.n[2], c.region.id))
    return out


def lua_text(key, cubes=None, recs=None):
    """The data file's text, from the cubes or from the records (records(); read_records() of a written file)."""
    rel = "Render3D/Standins/%s.lua" % key
    recs = records(cubes) if recs is None else recs
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end -- DisasterZone %s' % (rel, rel),
        "-- %s: the room's stand-ins (Render3D/Standins.lua shows them): unit cubes just behind its" % key,
        "-- opaque floors and walls, drawn in a scene under the room's textures; models in the scenes over it are then",
        "-- hidden per pixel wherever the room is in front of them (all model scenes share one depth buffer). 12 numbers",
        "-- per stand-in: prim, x, y, z (the prim's origin, room yards), yaw, pitch, roll (radians, room coordinates",
        "-- before mirroring), scale, nx, ny, nz (its face's normal, to the side the face is seen from), face (the",
        "-- face's region, for debugging). One matters only while its face faces the camera: the camera farther out",
        "-- along n than the cube reaches (and than the near clip). Checked offline against the room's z-buffer from",
        "-- %d poses. AUTO-GENERATED by dev/generators/gen_standins.py; do not edit by hand." % POSES_CHECKED,
        "local _, ns = ...",
        "ns.RoomStandins = ns.RoomStandins or {}",
        'ns.RoomStandins["%s"] = { version = 1, prims = { [1] = { fid = %d, kind = "%s", half = %s } },'
        % (key, PRIMS[CUBE]["fid"], PRIMS[CUBE]["kind"], _num(PRIMS[CUBE]["half"], 3)),
        "  n = %d, stride = 12, data = {" % len(recs),
    ]
    for r in recs:
        lines.append("    " + ", ".join([str(int(r[0])), _num(r[1], 3), _num(r[2], 3), _num(r[3], 3), _num(r[4], 5),
                                         _num(r[5], 5), _num(r[6], 5), _num(r[7], 3), _num(r[8], 4),
                                         _num(r[9], 4), _num(r[10], 4), str(int(r[11]))]) + ",")
    lines.append("} }")
    return "\n".join(lines) + "\n"


def read_records(path):
    """The 12-number records of a written data file (Python side)."""
    with open(path, "rb") as fh:
        src = fh.read().decode("utf-8")
    body = src.split("data = {", 1)[1].rsplit("} }", 1)[0]
    nums = [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?(?:e-?\d+)?", body)]
    return [tuple(nums[i:i + 12]) for i in range(0, len(nums), 12)]


def write_lua(key, cubes=None, out_dir=OUT_DIR, recs=None):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, key + ".lua")
    text = lua_text(key, cubes, recs)
    tmp = os.path.join(out_dir, "." + key + ".lua.tmp")
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    os.replace(tmp, path)
    return path, len(text.encode("utf-8"))


# ---------------------------------------------------------------------------------------------------------------
# Pictures
# ---------------------------------------------------------------------------------------------------------------
def _shade(normals, base):
    L = np.array([0.35, -0.45, 0.82])
    L /= np.linalg.norm(L)
    k = np.clip(normals @ L, 0, 1) * 0.65 + 0.35
    return base * k[..., None]


def pose_pictures(room, cam, arr):
    """Three pictures of one pose: the room, the stand-ins, the error overlay. -> list of uint8 (H, W, 3), numbers."""
    res, _, b = measure(room, cam, arr)
    H, W = b["zr"].shape
    room_img = np.full((H, W, 3), 18.0)
    m = b["fr"] >= 0
    if m.any():
        room_img[m] = _shade(room.N[b["fr"][m]], np.array([200.0, 190.0, 175.0]))
    si_img = np.full((H, W, 3), 18.0)
    s = b["ids"] >= 0
    if s.any():
        C, R, S, N = arr
        size = S[b["ids"][s]]
        hue = np.clip(np.log2(np.maximum(size, 0.1) / 0.1) / 6.5, 0, 1)
        col = np.stack([60 + 180 * hue, 200 - 80 * hue, 240 - 180 * hue], axis=-1)
        si_img[s] = _shade(N[b["ids"][s]], col)
    err = np.full((H, W, 3), 18.0)
    if m.any():
        err[m] = _shade(room.N[b["fr"][m]], np.array([120.0, 120.0, 120.0]))
    gap = b["gap"]
    good = m & (gap <= MARGIN + EPS_UNDER)
    loose = m & (gap > MARGIN + EPS_UNDER) & (gap <= LOOSE[-1])
    under = m & ~good & ~loose
    err[good] = err[good] * 0.35 + np.array([60, 200, 90]) * 0.65
    err[loose] = err[loose] * 0.35 + np.array([230, 200, 60]) * 0.65
    err[under] = err[under] * 0.35 + np.array([230, 70, 50]) * 0.65
    err[b["over"]] = np.array([255, 0, 255])
    return [np.clip(x, 0, 255).astype(np.uint8) for x in (room_img, si_img, err)], res


def sheet_cams(room, view, spot, W, H):
    vx, vy, vd = view
    cams = [orbit((vx, vy, 0.0), h, p, d, W=W, H=H, name=nm)
            for (h, p, d, nm) in ((math.pi / 2, 0.9, vd, "first view"), (0.6, 0.35, vd, "low orbit"),
                                  (2.4, 1.5, vd * 0.6, "top"), (3.9, 0.6, vd * 0.3, "inside orbit"))]
    tr = poses(room, view, spot, "train", W=W, H=H)
    cams += [[c for c in tr if c.name.startswith("walk")][3], [c for c in tr if c.name.startswith("eye")][5]]
    return cams


def contact_sheet(b, path, W=480, H=320):
    from PIL import Image, ImageDraw
    room, cubes = b["room"], b["cubes"]
    arr = standin_arrays(cubes)
    pad = 22
    rows = []
    for cam in sheet_cams(room, b["view"], b["spot"], W, H):
        pics, res = pose_pictures(room, cam, arr)
        row = Image.new("RGB", (3 * W + 4, H + pad), (30, 30, 30))
        for k, p in enumerate(pics):
            row.paste(Image.fromarray(p), (k * (W + 2), pad))
        d = ImageDraw.Draw(row)
        d.text((6, 5), "%s   shown %d   over-occlusion %d px (eroded %d)   coverage %.1f%% within %.2f yd, any %.1f%%"
               % (cam.name, res["shown"], res["over"], res["over_eroded"], 100 * res["covered"] / max(1, res["drawn"]),
                  MARGIN + EPS_UNDER, 100 * res["covered_any"] / max(1, res["drawn"])), fill=(235, 235, 235))
        rows.append(row)
    sheet = Image.new("RGB", (3 * W + 4, 40 + len(rows) * (H + pad)), (30, 30, 30))
    d = ImageDraw.Draw(sheet)
    d.text((6, 4), "%s: %d unit-cube stand-ins. Columns: the room (opaque faces facing the camera) | the stand-ins "
                   "shown (blue small .. orange big) | errors" % (b["key"], len(cubes)), fill=(235, 235, 235))
    d.text((6, 22), "green: a stand-in within %.2f yd behind the face; yellow: within %g yd; red: none; magenta: "
                    "over-occlusion (a stand-in in front of the room or over nothing)" % (MARGIN + EPS_UNDER, LOOSE[-1]),
           fill=(235, 235, 235))
    for k, row in enumerate(rows):
        sheet.paste(row, (0, 40 + k * (H + pad)))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sheet.save(path, optimize=True)
    return path


def top_view(b, path, S=8):
    """The room from above: every region's outline (floors grey, walls blue, slopes left out dark red), the floor
    stand-ins' squares (blue small .. orange big) and the walls' as ticks along them."""
    from PIL import Image, ImageDraw
    room = b["room"]
    W, H = int(math.ceil(room.w * S)) + 2, int(math.ceil(room.h * S)) + 2

    def px(p):
        return (p[0] * S, (room.h - p[1]) * S)
    img = Image.new("RGB", (W, H + 30), (18, 18, 18))
    d = ImageDraw.Draw(img)
    A = room.V[room.T]
    for f in np.nonzero(room.opaque)[0]:
        rg = b["regions"][room.region_of[f]] if room.region_of[f] >= 0 else None
        col = {"floor": (70, 70, 70), "wall": (50, 70, 110), "ceiling": (70, 70, 70)}.get(
            rg.kind if rg else "", (90, 35, 35))
        if rg is not None and rg.kind == "floor" and room.N[f, 2] > 0:
            d.polygon([px(q) for q in A[f]], fill=col)
    for f in np.nonzero(room.opaque)[0]:
        rg = b["regions"][room.region_of[f]]
        if rg.kind != "floor":
            col = (50, 70, 110) if rg.kind == "wall" else (110, 40, 40)
            d.line([px(q) for q in A[f]] + [px(A[f][0])], fill=col, width=1)
    for c in sorted(b["cubes"], key=lambda c: -c.s):
        h = min(1.0, max(0.0, math.log2(c.s / MIN_SIZE) / 3.5))
        col = (int(60 + 190 * h), int(200 - 60 * h), int(240 - 200 * h))
        fr = c.region.frame
        if c.region.kind == "floor":
            pts = [(c.u0 + x) * fr.e1 + (c.v0 + y) * fr.e2 for x, y in ((0, 0), (c.s, 0), (c.s, c.s), (0, c.s))]
            d.polygon([px(q) for q in pts], outline=col)
        else:
            a0 = c.u0 * fr.e1 + c.tf * fr.a
            a1 = (c.u0 + c.s) * fr.e1 + c.tf * fr.a
            d.line([px(a0), px(a1)], fill=col, width=2)
    d.text((6, H + 8), "%s from above: floor stand-ins as squares, wall ones as ticks (blue %.1f yd .. orange %.0f yd); "
                       "grey floors, blue walls, red: sloped faces left out" % (b["key"], MIN_SIZE, MAX_SIZE),
           fill=(230, 230, 230))
    img.save(path, optimize=True)
    return path


def report(b, size=None):
    a = b["areas"]
    cubes = b["cubes"]
    sizes = np.array([c.s for c in cubes]) if cubes else np.zeros(1)
    kinds = collections.Counter(c.region.kind for c in cubes)
    lines = ["%s: %d stand-ins (placed %d; repair %s), %.0f s" % (b["key"], len(cubes), b["placed"], b["repair"],
                                                                   b["seconds"]),
             "  by kind %s; size yd min %.2f median %.2f max %.2f" % (dict(kinds), sizes.min(), np.median(sizes),
                                                                      sizes.max()),
             "  areas yd2: " + ", ".join("%s %.0f" % (k, v) for k, v in sorted(a.items()))]
    for tag, label in (("train", "train"), ("random", "random"), ("random_reach", "random, rule 'reach'")):
        s = b[tag]
        lines.append("  %s poses %d (%dx%d): over-occlusion %d px eroded (%d raw, %d where a model could be); "
                     "coverage %.1f%% within %.2f yd, %s, any %.1f%%; shown median %.0f p90 %.0f max %d"
                     % (label, s["poses"], b["size"][0], b["size"][1], s["over_eroded"], s["over_raw"],
                        s["over_air"], 100 * s["coverage"], MARGIN + EPS_UNDER,
                        ", ".join("%.1f%% within %g" % (100 * s["coverage_%g" % t], t) for t in LOOSE),
                        100 * s["coverage_any"], s["shown_median"], s["shown_p90"], s["shown_max"]))
        if tag != "random_reach":
            lines.append("    worst coverage: " + "; ".join("%s %.0f%%" % (n, 100 * c) for c, n in s["worst"]))
            lines.append("    by face drawn (share of pixels: covered strict / any): " + "; ".join(
                "%s %.1f%%: %.1f%% / %.1f%%" % (k, 100 * s["kind_" + k][0], 100 * s["kind_" + k][1],
                                               100 * s["kind_" + k][2]) for k in KIND_CODES if s["kind_" + k][0]))
        bad = sorted(((r["over_eroded"], r["name"]) for r in b["res_" + tag.replace("random", "rand")]
                      if r["over_eroded"]), reverse=True)[:5]
        if bad:
            lines.append("    over-occlusion at: " + "; ".join("%s %d px" % (n, v) for v, n in bad))
    if size is not None:
        lines.append("  file %d bytes" % size)
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("keys", nargs="*", default=[DEFAULT_KEY])
    ap.add_argument("--fast", action="store_true", help="fewer, smaller poses (tests)")
    ap.add_argument("--no-write", action="store_true")
    ap.add_argument("--sheet", action="store_true", help="write dev/docs/img/standins_<short>.png")
    ap.add_argument("--json", help="write the numbers here")
    args = ap.parse_args(argv)
    allres = {}
    for key in args.keys:
        b = build(key, fast=args.fast)
        size = None
        if not args.no_write:
            path, size = write_lua(key, b["cubes"])
            print("wrote", path)
        print(report(b, size))
        if args.sheet:
            short = key.split("_", 1)[-1].lower()
            print("wrote", contact_sheet(b, os.path.join(IMG_DIR, "standins_%s.png" % short)))
            print("wrote", top_view(b, os.path.join(IMG_DIR, "standins_%s_top.png" % short)))
        allres[key] = dict(train=b["train"], random=b["random"], random_reach=b["random_reach"], areas=b["areas"],
                           n=len(b["cubes"]),
                           placed=b["placed"], repair=b["repair"], size=size)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(allres, fh, indent=1, default=float)
    return allres


if __name__ == "__main__":
    main()
