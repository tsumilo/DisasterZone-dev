"""Room stand-ins: invisible proxy models that give the strategy board's 3D view per-pixel occlusion by the room.

All ModelScenes share one depth buffer, and that depth survives the opaque UI textures the room is painted with
(dev/docs/DEPTH_RESEARCH.md, in-game facts of 2026-10-05). So a scene under the room's textures that holds models
standing just behind every opaque room surface writes the room's depth: a boss in a scene over the room is then
hidden per pixel wherever a room surface is in front of it. This generator places those models ("stand-ins") for one
room and checks offline that they never hide anything the room does not hide. Version 2: flat quads (the client's
653518, a one-sided, unlit, opaque 48.93 x 32.99 menu quad; in game it filled its outline and cut a hole in a model
from a lower scene, probe tiles 53, 54, 60) turned by yaw, pitch and roll in the client's order (Y.P.R, probe tile
38: ypr_matrix()) lie in every opaque planar region - floors, walls and slopes alike -, and unit cubes (167145, v1's
only primitive) fill gaps the quads leave where they fit by v1's rules.

For a room key (Render3D/Rooms/<Key>.lua, decoded as Render3D/Rooms.lua unpacks it, so the stand-ins follow exactly
what the renderer draws - including which side each face is drawn to, decided as Render3D/Room.lua decides it, by
the plane of the BSP node the face is filed under: drawn()):
  1. regions   the opaque faces (blend D: ALPHAKEY and BLEND faces let models show through, so they get none)
               grouped into planar regions: connected faces on one plane within 2 cm. Each gets a frame in its own
               plane (its fitted normal; the grid along its outline's main heading, exactly: _edge_heading()), so a
               stand-in lies flat behind it whatever its tilt.
  2. exposure  columns of probe points behind every region (PROBE_STEP apart, from the stand-ins' front - the plane
               a quad lies in - down to the back of a cube of each LEVELS size) are tested against the room's
               z-buffer from every training pose: a point some pose sees past the room (nothing drawn in front of it,
               or something drawn behind it) may not be inside a stand-in that pose would show. The edges where a
               region meets nothing (the room's outer walls face away from a camera outside them; their tops end at
               the room's cut) let a camera see under a floor or behind a wall. The board and stress poses count a
               point only where a model could stand behind it (harmful_only).
  3. open edges whatever the poses saw: lines through points just under every region's outline, rising out of its
               back side past the edge in every direction, kept where the board's camera could stand along one with
               no face it draws in between (CamDomain: V:ClampOrb's whole range, under the floor a little too) and
               where the line then runs through air a model can stand in before the room behind (open_lines): a
               panel's open bottom, a lintel's underside, a wall's open top. No quad may lie where one crosses its
               plane from the front (the placement keeps them LINE_TOL off: quad_crossings()), no cube may touch one
               (cut_on_lines: whatever still does is cut).
  4. placement per region on a GRID yd grid in its plane, greedy from the largest down: quads (each of the quad's
               fixed shape, long side along either grid axis, scale QUAD_MAX_SCALE down to MIN_SCALE) lying in the
               plane MARGIN behind the face - zero thick, so they go right up to the outline less EDGE_INSET -, then
               cubes (MAX_SIZE down to MIN_SIZE) in the gaps they leave, their front in that plane. Every stand-in
               lies inside the region's outline, away from any exposed probe (PROBE_STEP), and BACK_GAP from every
               other room face (exact triangle-box tests: round it and behind it; in front only half that), so it
               never pokes out of the back of a thin wall or into a pillar. Quads may overlap each other.
  5. repair    an offline z-buffer (numpy) renders every training pose at the check's size: the room's faces as the
               renderer draws them, and the stand-ins the runtime would show (shown()) as the client draws them (a
               quad from its front only: one-sided). A stand-in nearer than the drawn room, or where the room draws
               nothing at all, hides a model the room does not hide ("over-occlusion"): one seen doing that (past
               the 1-pixel erosion; on the board and stress poses only where a model could be) is cut into quarters
               (a quad's keep its shape), again until the pose is clean (under MIN_SCALE / MIN_SIZE it goes).
  6. check     (the held-out poses on the data as written - record_arrays(): rounded as the file has it, turned as
               the runtime turns it) over-occlusion (after a 1-pixel erosion; 'harmful' where the ray past the stand-in runs through air
               a model can stand in), coverage (opaque room pixels with a stand-in within MARGIN + EPS_UNDER behind
               them, and looser tolerances, by the kind of face drawn), stand-ins shown per pose, on the training
               poses, on random poses, on held-out board poses over the board camera's whole range (board_poses(),
               another seed: what a user can do), on held-out stress poses (stress_poses(): by walls at eye level and
               inside the near clip's guard, under floors, grazing floors) and on the poses a review found faults at
               (REVIEW_POSES); pictures (--sheet).
Training poses: poses() - the board's orbit round the room and the boss at pitches 0.15 - 1.5 out to the farthest
distance it allows, low orbits close by the floor's outer edge looking in, walking and eye-level poses; nothing may
be seen past the room - and board_poses() over the camera's whole range and stress_poses(), where only harmful
over-occlusion counts: low over the floor from outside the room a camera sees far under the floor past its cut edges,
where nothing can stand, and keeping those clean too would strip the floors.

Writes addon Render3D/Standins/<Key>.lua (the data contract, version 2; Render3D/Standins.lua reads it):
    ns.RoomStandins["<Key>"] = { version = 2,
        prims = { [1] = { fid = 167145, kind = "cube", half = 0.5 },
                  [2] = { fid = 653518, kind = "quad", w = 48.9309, h = 32.9853, cx = -4.03583, cy = 0.86901,
                          cz = 18.25718 } },
        room = { size = <packed size>, verts = <count>, tris = <count> }, n = <count>, stride = 12, data = { .. } }
  12 numbers per stand-in: prim; x, y, z (its anchor in room coordinates - yd, x east, y north, z over the boss'
  floor: a cube's centre, a quad's middle); yaw, pitch, roll (radians, room coordinates, i.e. the client's for a scene
  mirror of +1: the turn R = Rz(yaw) Ry(pitch) Rx(roll), SetYaw / SetPitch / SetRoll as the client applies them, roll
  first); scale (the actor's); nx, ny, nz (the unit normal of the surface it stands behind, to the side it is seen
  from); face (the region's id, for debugging; a region's stand-ins come together). A prim's model point q stands at
  anchor + scale R (q - c), c = (cx, cy, cz) its middle (a cube's is its origin): the runtime puts the model's origin
  at anchor - scale R c. A cube is 2 half x scale yd a side; a quad is the w x h x scale rectangle in its model's y-z
  plane, its front (model +x, R's first column) along n, drawn from the front only. Show a stand-in only while
  dot(n, camera - anchor) > reach + near (shown(), rule 'guard'): reach = scale x the sum over its turned axes a of
  its half extent along a x |n . a| (0 for a quad), near = the near clip (0.5 yd). room: the room file it was made for
  (ns.RoomFloors[key].size and the unpacked mesh's counts); data made for another build of the room hides the wrong
  things. Version 1 (cubes turned about z, one prim) reads the same way.
Known limit (the runtime's): a camera within the near clip of a room face sees that face clipped away and the
stand-ins behind its neighbours through the hole (REVIEW_POSES 'air': under the floor or in solid room, harmless).

Run from dev/:  luaenv\\Scripts\\python.exe generators\\gen_standins.py [Key ...] [--fast] [--no-write] [--no-cubes]
  [--sheet] [--json FILE] (no key: MagtheridonsLair_Magtheridon). --fast: fewer and smaller poses (the tests);
  --no-cubes: quads alone; --sheet: dev/docs/img/standins_<boss>_v2.png (room | stand-ins | errors on six poses) and
  _v2_top.png.
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

# The primitives a stand-in can use (index = the data's prim number). cube: centred on its origin, half = its half
# size in its own units (a stand-in's size in yd is 2 * half * scale). quad: a one-sided rectangle w x h model units
# in its model's y-z plane, its front facing model +x, c = its middle in model units - off the model's origin, so the
# runtime moves the origin to put the middle where the data says (the client's own file, read with casc_local.py:
# 4 vertices at x = -4.0358, y -23.5964 .. 25.3344, z 1.7645 .. 34.7498, both triangles wound to +x, opaque, unlit).
PRIMS = {1: dict(fid=167145, kind="cube", half=0.5),
         2: dict(fid=653518, kind="quad", w=48.9309, h=32.9853, c=(-4.03583, 0.86901, 18.25718))}
CUBE, QUAD = 1, 2
QUAD_W, QUAD_H = PRIMS[QUAD]["w"], PRIMS[QUAD]["h"]
MIN_SCALE = 0.018         # no stand-in's actor scale below this: in game a quad at 0.0066 cut no hole in a model while
                          # 0.0179 - 0.022 did (probe tiles 59 - 61); the smallest quad is 0.88 x 0.59 yd
QUAD_MAX_SCALE = 1.0      # the largest quad: 49 x 33 yd

# Placement (yd unless said otherwise)
PLANE_TOL = 0.02          # a face joins a region when its corners lie this close to the region's plane ...
PLANE_COS = math.cos(math.radians(3.0))   # ... and its normal is this close to the region's
MARGIN = 0.05             # the cube's front lies this far behind the face (measured along the face's normal). Bigger
                          # than the depth buffer's step (24 bit, near 0.5 / far 500: 1 mm at 100 yd, 5 mm at 200 yd)
                          # ten times over, so a model standing on the face never fights it; small enough that a foot
                          # sinking 5 cm into the floor still shows, deeper is cut as the room would cut it
BACK_GAP = 0.05           # every other room face stays at least this far from a cube (thin walls, pillars, steps)
EDGE_INSET = 0.01         # stand-ins keep this far inside the region's outline (no edge shared to the last bit)
GRID = 0.05               # the placement grid in the region's plane (coarser for very large regions)
MAX_CELLS = 6_000_000     # cells per region grid at most
MIN_SIZE = 0.7            # the smallest cube (proven in game at 0.7 yd and up: v1)
MAX_SIZE = 2.3            # the largest cube: cubes only fill what the quads leave, near edges and in corners
SIZE_STEP = 0.8           # the size ladders: each step this much smaller
MIN_GAIN = 0.6            # a stand-in must cover at least this share of new (uncovered) area
PICKS = 20000             # candidates looked at per round of the greedy placement
LEVELS = (0.3, 0.45, 0.7, 1.0, 1.5, 2.3)   # cube sizes the exposure probes are laid out for (behind the front)
PROBE_STEP = 0.2          # yd between exposure probe columns
TOL_PX = 1.5              # px (the check's screen): a sliver of a stand-in seen past the room thinner than this
                          # is what the check's 1-pixel erosion forgives
FLOOR_TILT = math.radians(5.0)    # floors / ceilings: normal within this of straight up / down (the report's kinds;
WALL_TILT = math.radians(5.0)     # walls: normal within this of level                  every kind gets stand-ins)

# Validation
EPS_OVER = 0.005          # yd along the ray: a stand-in nearer than the room by more than this hides too much
EPS_UNDER = 0.02          # coverage: a stand-in within MARGIN + this (along the face's normal) behind the drawn face
LOOSE = (0.25, 1.0)       # looser coverage tolerances reported too (yd behind the face)
AIR_H, AIR_RUN = 12.0, 60.0   # 'harmful' over-occlusion: the ray past the stand-in meets the air a model could
                              # stand in (this high over the boss' floor), looked for this far
AIR_STEP = 0.5                # yd between the air tests along a ray
FOV, NEAR = 1.1, 0.5      # Render3D/View.lua's scenes
EYE, WALK_EYE = 1.9, 2.2  # UI/StrategyMap3D.lua: the eye all the way in; the point the walking camera turns round
PITCH_MIN, PITCH_TOP = 0.12, 1.5
PITCH_LOOKUP, DIST_MIN = -0.5, 0.3   # UI/StrategyMap3D.lua: the pitch allowed under 3 yd out; all the way in
RULE = "guard"            # which stand-ins show (shown())
POSES_CHECKED = 1937      # training, random, board, stress and review poses of a full run (the data file says so)
KIND_CODES = {"floor": 0, "ceiling": 1, "wall": 2, "slope": 3, "other": 4}   # the check's breakdown


# ---------------------------------------------------------------------------------------------------------------
# The room as the renderer draws it: the shipped format 3 file decoded (Render3D/Rooms.lua's Unpack)
# ---------------------------------------------------------------------------------------------------------------
class Room:
    """V (n, 3) vertices, T (m, 3) triangles (0-based), blend per triangle ('D', 'A', 'B'), N unit normals of each
    triangle's own winding, d plane offsets (N . x = d), area; heights: the height grid (rows south to north, nan =
    no floor), cell yd per cell. Which faces a camera sees is decided as Render3D/Room.lua decides it, by the BSP
    node each triangle is filed under: NP / NPd its node's plane (NP . x + NPd = the side), QO +1 / -1 / 0 its prim's
    winding against that plane (drawn(): the camera on side QO, by more than EPS_SIDE). size, nverts, ntris: the
    room file's stamp (the stand-in data records it)."""


EPS_SIDE = 1e-4           # Render3D/Room.lua: a node seen exactly edge-on draws nothing


def _walks(t3, q, p):
    """Does triangle t3 (three vertex numbers) walk the edge q -> p? (Room.lua's Walks)"""
    a, b, c = t3
    return (a == q and b == p) or (b == q and c == p) or (c == q and a == p)


def _prim_orientation(V, tris1, nodes, pair):
    """Room.lua's PreparePrims: every triangle's node (0-based) and QO, the sign of its prim's winding against the
    node's plane normal. A triangle and its quad mate (pair, 1-based, filed under the same node and sharing an edge
    walked the other way) are one prim, oriented by the first of the two."""
    n = len(tris1)
    node_of = -np.ones(n, np.int64)
    qo = np.zeros(n, np.int64)
    solo = np.zeros(n + 1, bool)
    for k in range(len(nodes)):
        first, cnt = int(nodes[k, 6]), int(nodes[k, 7])
        last = first + cnt - 1
        nrm = nodes[k, :3]
        for i in range(first, last + 1):
            node_of[i - 1] = k
            j = int(pair[i - 1]) if len(pair) else 0
            if j != 0 and (j < first or j > last or int(pair[j - 1]) != i or solo[i]):
                j = 0
            if j != 0 and j < i:
                continue                                  # (in the prim of its mate, oriented there)
            a, b, c = (int(x) for x in tris1[i - 1, :3])
            mate = 0
            if j > i:
                tj = tuple(int(x) for x in tris1[j - 1, :3])
                if _walks(tj, b, a) or _walks(tj, a, c) or _walks(tj, c, b):
                    mate = j
                else:
                    solo[j] = True                        # (no shared edge after all: both alone)
            # (turning a, b, c round to put the shared edge first keeps the winding: QO is the triangle's own)
            A, B, C = V[a - 1], V[b - 1], V[c - 1]
            dot = float(np.cross(B - A, C - A) @ nrm)
            o = 1 if dot > 1e-9 else (-1 if dot < -1e-9 else 0)
            qo[i - 1] = o
            if mate:
                qo[mate - 1] = o
    return node_of, qo


def drawn(room, C):
    """The faces Render3D/Room.lua draws to a camera at C: opaque, and C on its node plane's side QO (by more than
    EPS_SIDE)."""
    s = room.NP @ np.asarray(C, float) + room.NPd
    return room.opaque & (room.QO * s > EPS_SIDE)


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
    r.size = int(head.group(8))
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
    r.nverts, r.ntris = len(r.V), len(r.T)
    # the side each face is drawn to, as the renderer decides it (its BSP node's plane, not its own winding: a
    # sliver filed under a node can lean far off that plane)
    nodes = np.array(parts[5].split(), dtype=float).reshape(-1, 8)
    pair = np.array(parts[6].split(), dtype=np.int64)
    r.node_of, r.QO = _prim_orientation(r.V, t, nodes, pair)
    if (r.node_of < 0).any():
        raise ValueError("%s: %d triangles under no BSP node" % (path, int((r.node_of < 0).sum())))
    r.NP, r.NPd = nodes[r.node_of, :3], nodes[r.node_of, 3]
    # opaque: drawn with blending off (ALPHAKEY and BLEND faces let models show through) and drawn at all (QO 0:
    # never)
    r.opaque = (r.blend == "D") & (r.area > 1e-9) & (r.QO != 0)
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
    room.Tm = T                                   # (the triangles' corners as merged vertices: outlines)
    # every face's kind for the check's breakdown: its region's, or 'other' (see-through, specks)
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


def window(a, k, op, k2=None):
    """op over k x k2 windows (rows x columns; k2 = k by default)."""
    return _slide(_slide(a, k, 0, op), k if k2 is None else k2, 1, op)


def box_sums(c, k, k2=None):
    """Sums over k x k2 windows (rows x columns, k2 = k by default; anchored at their first cell) from the integral
    image c (padded with a 0 row and column)."""
    k2 = k if k2 is None else k2
    return c[k:, k2:] - c[:-k, k2:] - c[k:, :-k2] + c[:-k, :-k2]


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
# Orientation: the client's yaw, pitch and roll
# ---------------------------------------------------------------------------------------------------------------
# An actor turned by SetYaw(y), SetPitch(p) and SetRoll(r) draws its model's point q at R q (times its scale, plus its
# position), R = Rz(y) Ry(p) Rx(r): roll turns the model first, then pitch, then yaw (Y.P.R, outer to inner), each
# the standard right-handed turn about the scene's z, y and x - Render3D/Probe.lua's AXIS and Rot("ypr"), which the
# in-game probe confirmed (tiles 35 - 37 the signs, tile 38 the order; 2026-10-05). Matrices here hold the model's
# axes as columns, in room coordinates (scene coordinates with the mirror +1).
def ypr_matrix(yaw, pitch, roll):
    cy, sy, cp, sp, cr, sr = (math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch), math.cos(roll),
                              math.sin(roll))
    Rz = np.array([[cy, -sy, 0.0], [sy, cy, 0.0], [0.0, 0.0, 1.0]])
    Ry = np.array([[cp, 0.0, sp], [0.0, 1.0, 0.0], [-sp, 0.0, cp]])
    Rx = np.array([[1.0, 0.0, 0.0], [0.0, cr, -sr], [0.0, sr, cr]])
    return Rz @ Ry @ Rx


def ypr_matrices(yaw, pitch, roll):
    """ypr_matrix for arrays of angles -> (n, 3, 3)."""
    yaw, pitch, roll = (np.asarray(x, float) for x in (yaw, pitch, roll))
    cy, sy, cp, sp, cr, sr = np.cos(yaw), np.sin(yaw), np.cos(pitch), np.sin(pitch), np.cos(roll), np.sin(roll)
    M = np.empty(yaw.shape + (3, 3))
    M[..., 0, 0], M[..., 1, 0], M[..., 2, 0] = cy * cp, sy * cp, -sp
    M[..., 0, 1] = -sy * cr + cy * sp * sr
    M[..., 1, 1] = cy * cr + sy * sp * sr
    M[..., 2, 1] = cp * sr
    M[..., 0, 2] = sy * sr + cy * sp * cr
    M[..., 1, 2] = -cy * sr + sy * sp * cr
    M[..., 2, 2] = cp * cr
    return M


def ypr_angles(M):
    """The yaw, pitch, roll (radians, yaw and roll in -pi .. pi, pitch in -pi/2 .. pi/2) whose ypr_matrix is the
    rotation M. With the model's x axis straight up or down (a floor's or a ceiling's quad) only yaw + roll is
    fixed: yaw is then 0."""
    M = np.asarray(M, float)
    cp = math.hypot(M[0, 0], M[1, 0])
    if cp > 1e-7:
        yaw = math.atan2(M[1, 0], M[0, 0])
        pitch = math.atan2(-M[2, 0], cp)
        roll = math.atan2(M[2, 1], M[2, 2])
    elif M[2, 0] < 0:                             # pitch +90: R = Ry(90) Rx(r), its row 0 = (0, sin r, cos r)
        yaw, pitch, roll = 0.0, math.pi / 2, math.atan2(M[0, 1], M[1, 1])
    else:                                         # pitch -90: row 0 = (0, -sin r, -cos r)
        yaw, pitch, roll = 0.0, -math.pi / 2, math.atan2(-M[0, 1], M[1, 1])
    return yaw, pitch, roll


# a cube looks the same turned by any of these (its axes permuted in turn, or two of them reversed): the data takes
# the one with the least pitch and roll, so a level floor's and an upright wall's cubes turn about z alone
_CUBE_SYMS = [np.array(P, float) @ np.diag(D) for P in ([[1, 0, 0], [0, 1, 0], [0, 0, 1]],
                                                       [[0, 0, 1], [1, 0, 0], [0, 1, 0]],
                                                       [[0, 1, 0], [0, 0, 1], [1, 0, 0]])
              for D in ((1, 1, 1), (1, -1, -1), (-1, 1, -1), (-1, -1, 1))]


def standin_angles(c):
    """The data's yaw, pitch, roll of a stand-in: a quad's exactly (its model x = its axes' first row, the front),
    a cube's by the turn of its symmetries with the least pitch and roll."""
    M = np.asarray(c.axes, float).T
    if c.kind == "quad":
        return ypr_angles(M)
    best = None
    for Q in _CUBE_SYMS:
        a = ypr_angles(M @ Q)
        k = abs(a[1]) + abs(a[2])
        if best is None or k < best[0] - 1e-9:
            best = (k, a)
    return best[1]


# ---------------------------------------------------------------------------------------------------------------
# Placement: rectangles in a region's plane - quads lying MARGIN behind it, cubes in the gaps they leave
# ---------------------------------------------------------------------------------------------------------------
class Frame:
    """A region's placement frame: a = its normal (the side its face is seen from; a stand-in's front faces it), e1,
    e2 = the grid's u, v in its plane (e1 along most of its outline, so rectangles fit straight edges; e1 x e2 = a);
    R: rows e1, e2, a."""


def region_frame(room, g):
    a = np.asarray(g.n, float)
    # a reference direction in the plane: east for floors and ceilings (a level floor's grid heads as v1's did),
    # level along the plane for the rest
    if abs(a[2]) > 0.9:
        r1 = np.array([1.0, 0.0, 0.0]) - a[0] * a
    else:
        r1 = np.cross([0.0, 0.0, 1.0], a)
    r1 /= np.linalg.norm(r1)
    r2 = np.cross(a, r1)
    psi = _edge_heading(room, g, r1, r2)
    e1 = math.cos(psi) * r1 + math.sin(psi) * r2
    e2 = np.cross(a, e1)
    fr = Frame()
    fr.a, fr.e1, fr.e2 = a, e1, e2
    fr.R = np.stack([e1, e2, a])
    return fr


def _edge_heading(room, g, r1, r2):
    """The heading in the plane (radians from r1 towards r2, mod 90 degrees) most of the region's outline runs
    along, length weighted."""
    cnt = collections.Counter()
    for f in g.tris:
        for i in range(3):
            a, b = room.T[f, i], room.T[f, (i + 1) % 3]
            cnt[(min(a, b), max(a, b))] += 1
    hist = np.zeros(90)
    degs, lens = [], []
    for (i, j), c in cnt.items():
        if c != 1:
            continue                              # (inside the region: shared by two of its faces)
        e = room.V[j] - room.V[i]
        dx, dy = float(e @ r1), float(e @ r2)
        ln = math.hypot(dx, dy)
        if ln < 1e-6:
            continue
        deg = math.degrees(math.atan2(dy, dx)) % 90
        hist[int(round(deg)) % 90] += ln
        degs.append(deg)
        lens.append(ln)
    if hist.sum() <= 0:
        return 0.0
    sm = hist + 0.5 * (np.roll(hist, 1) + np.roll(hist, -1))
    peak = float(np.argmax(sm))
    # then exactly: the length-weighted mean of the edges within 0.6 degree of it (a whole degree off a 40 yd edge
    # would leave 0.7 yd of it uncovered)
    off = (np.array(degs) - peak + 45) % 90 - 45
    near = np.abs(off) <= 0.6
    w = np.array(lens)[near]
    if w.sum() <= 0:
        return math.radians(peak)                 # (the smoothing's pick between two headings)
    return math.radians(peak + float((off[near] * w).sum() / w.sum()))


class Standin:
    """One stand-in. kind 'quad' (prim QUAD) or 'cube' (prim CUBE); its footprint [u0, u0 + du] x [v0, v0 + dv] in
    its region's grid; s: a quad's actor scale, a cube's size in yd; ori: a quad's long side along e1 (0) or e2 (1);
    tf: the plane of its front (along the region's normal); centre: the data's anchor (a quad's middle, a cube's
    centre); axes: rows = its model's x, y, z turned into room coordinates (a quad's x is its front); half: its half
    extents along them; n: its region's normal; parent: the stand-in it was cut from."""
    __slots__ = ("region", "kind", "u0", "v0", "du", "dv", "s", "ori", "tf", "centre", "axes", "half", "n", "parent")


def quad_dims(s, ori):
    """A quad's footprint (along e1, along e2) at scale s."""
    return (QUAD_W * s, QUAD_H * s) if ori == 0 else (QUAD_H * s, QUAD_W * s)


def make_quad(g, u0, v0, s, ori, parent=None):
    """The quad whose footprint starts at (u0, v0) in the region's grid, in the plane MARGIN behind the region's
    lowest corner (dlo), its front facing the region's normal."""
    fr = g.frame
    du, dv = quad_dims(s, ori)
    c = Standin()
    c.region, c.kind, c.u0, c.v0, c.du, c.dv, c.s, c.ori = g, "quad", u0, v0, du, dv, s, ori
    c.tf = g.d + g.dlo - MARGIN
    c.centre = (u0 + du / 2) * fr.e1 + (v0 + dv / 2) * fr.e2 + c.tf * fr.a
    y = fr.e1 if ori == 0 else fr.e2
    c.axes = np.stack([fr.a, y, np.cross(fr.a, y)])
    c.half = np.array([0.0, QUAD_W * s / 2, QUAD_H * s / 2])
    c.n = g.n
    c.parent = parent
    return c


def make_cube(g, u0, v0, s, parent=None):
    """The cube whose face square is [u0, u0 + s] x [v0, v0 + s] in the region's grid, its front MARGIN behind the
    region's lowest corner."""
    fr = g.frame
    c = Standin()
    c.region, c.kind, c.u0, c.v0, c.du, c.dv, c.s, c.ori = g, "cube", u0, v0, s, s, s, 0
    c.tf = g.d + g.dlo - MARGIN
    c.centre = (u0 + s / 2) * fr.e1 + (v0 + s / 2) * fr.e2 + (c.tf - s / 2) * fr.a
    c.axes = fr.R
    c.half = np.full(3, s / 2)
    c.n = g.n
    c.parent = parent
    return c


def prepare_region(room, g, max_size=MAX_SIZE):
    """A region's frame and outline (in its grid's u, v, less EDGE_INSET). -> False when nothing fits in it (no
    stand-ins at all)."""
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
    # (the frame's normal is the region's own: a stand-in lies flat behind its plane, whatever its tilt)
    g.na, g.n1, g.n2, g.tiltk = 1.0, 0.0, 0.0, 0.0
    g.cap = max_size
    if poly.is_empty:
        return False
    inner = poly.buffer(-EDGE_INSET, join_style=2)
    smallest = min(QUAD_W * QUAD_H * MIN_SCALE ** 2, MIN_SIZE ** 2)
    if inner.is_empty or inner.area < smallest:
        return False
    shapely.prepare(inner)
    g.inner = inner
    return True


def size_ladder(cap, min_size):
    sizes, s = [], cap
    while s >= min_size - 1e-9:
        sizes.append(s)
        s *= SIZE_STEP
    if not sizes or sizes[-1] > min_size + 1e-9:
        sizes.append(min_size)
    return sizes


def level_of(g, s):
    """The probe level (index into LEVELS) whose depth covers a cube of side s (the probes lie as deep as such a
    cube's back)."""
    for j, L in enumerate(LEVELS):
        if L >= s - 1e-9:
            return j
    return len(LEVELS) - 1


# ---------------------------------------------------------------------------------------------------------------
# Exposure: which points behind a region some pose could see past the room
# ---------------------------------------------------------------------------------------------------------------
class Probes:
    """Columns of points behind the placed regions, PROBE_STEP apart in each region's grid (and that far round its
    outline): per column its region (index into regs) and u, v; per column and depth (the stand-ins' front - the
    plane a quad lies in -, then the back of a cube of each LEVELS size) the room point P, the n . camera a stand-in
    there shows from (shown()) and whether a pose saw it (exposed)."""


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
        # a stand-in shows to cameras farther out along n than it reaches (its front lies MARGIN behind the face,
        # whatever its size) and, by the guard rule, than the near clip (shown(); a hair less, to be safe)
        thr.append(np.full((len(U), len(depths)), g.d + g.dlo - MARGIN + (NEAR if RULE == "guard" else 0.0) - 0.01))
    pr = Probes()
    pr.P = np.concatenate(P)
    pr.reg = np.concatenate(reg)
    pr.u, pr.v = np.concatenate(uu), np.concatenate(vv)
    pr.thr = np.concatenate(thr)
    pr.n = np.array([g.n for g in regs])[pr.reg]
    pr.exposed = np.zeros(pr.P.shape[:2], bool)
    return pr


def expose(room, pr, cams, val_F=None, log=None, harmful_only=False):
    """Marks the probes some camera sees past the room: in view, shown by the facing rule, and the room face
    drawn at its pixel (the pixel's centre, as the check samples) not in front of it along the probe's own ray
    (that face's plane: far off, at a grazing angle, a pixel's centre and the probe can lie yards apart on it).
    The check forgives slivers its 1-pixel erosion removes, so neither does this, on a screen of focal length val_F
    (the check's; default this camera's): a deeper point counts only when the run of seen points down its column
    (from the last hidden one) is TOL_PX or more long; a front point (where a quad lies) only when the quad's drop
    of MARGIN under the face, seen from there, is that long on the screen (the sliver of a quad seen past a free edge
    is no wider than that drop looks). harmful_only: only where the ray on past the probe runs through air a model
    can stand in before the room drawn there (a stand-in there would hide one; seen under a floor it hides
    nothing)."""
    nc, nl = pr.P.shape[:2]
    flatP = pr.P.reshape(-1, 3)
    for ci, cam in enumerate(cams):
        scale = (val_F or cam.F) / cam.F
        zb, fb = render_room(room, cam)
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
        # a front point: the drop from the face above it (the face point nearer than the near clip: no bound)
        c0 = np.nonzero(seen[:, 0])[0]
        if len(c0):
            qf = cam.to_cam(pr.P[c0, 0] + MARGIN * pr.n[c0])
            ok0 = qf[:, 2] > cam.near
            r0 = np.full(len(c0), np.inf)
            fx = cam.cx + cam.F * qf[ok0, 0] / qf[ok0, 2]
            fy = cam.cy - cam.F * qf[ok0, 1] / qf[ok0, 2]
            r0[ok0] = np.hypot(fx - S[c0[ok0], 0, 0], fy - S[c0[ok0], 0, 1]) * scale
            run[c0, 0] = r0
        got = (seen & (run >= TOL_PX)).reshape(-1)
        if harmful_only:
            # then only those a model could be behind (as the check erodes first, then asks where a model could
            # be), asked of the points no pose has marked yet
            vis = np.nonzero(~hid)[0]
            vis = vis[got[idx[vis]] & ~pr.exposed.reshape(-1)[idx[vis]]]
            got[:] = False
            if len(vis):
                zr = zb[sy[vis].astype(int), sx[vis].astype(int)]
                got[idx[vis]] = _air_beyond(room, cam.C, d[vis] / dist[vis][:, None], dist[vis], zr)
        pr.exposed |= got.reshape(nc, nl)
        if log and (ci + 1) % 100 == 0:
            log("  exposure %d/%d poses: %.1f%% of probes seen" % (ci + 1, len(cams), 100 * pr.exposed.mean()))
    return pr


def blocked_masks(g, ri, pr, us, vs, r):
    """The grid cells a stand-in may not cover (within PROBE_STEP of a column a pose saw at its depth or less): [0]
    for a quad (the front), [1 + level_of(cube)] for a cube; cumulative down the column."""
    nv, nu = len(vs) - 1, len(us) - 1
    sel = np.nonzero(pr.reg == ri)[0]
    seen = np.logical_or.accumulate(pr.exposed[sel], axis=1)       # (deeper sees whatever shallower did)
    i = np.floor((pr.u[sel] - us[0]) / r).astype(int)
    j = np.floor((pr.v[sel] - vs[0]) / r).astype(int)
    i, j = np.clip(i, 0, nu - 1), np.clip(j, 0, nv - 1)     # (a column just outside the outline blocks the edge)
    rad = int(math.ceil(PROBE_STEP / r))
    out = []
    for lv in range(seen.shape[1]):
        m = np.zeros((nv, nu), bool)
        k = seen[:, lv]
        m[j[k], i[k]] = True
        m = window(np.pad(m, rad, constant_values=False), 2 * rad + 1, np.maximum)
        out.append(m)
    return out


def _greedy(covered, fit, kv, ku, fv, fu, try_at):
    """Greedy rounds at one footprint (kv x ku grid cells to fit, the fv x fu it surely covers: a quad's sides are not
    whole cells). Each round: the candidates by gain (uncovered cells under them; ties: grid order, so they pack
    flush from the first one that fits), each tried (try_at(j, i) -> a stand-in or None) unless it overlaps one taken
    this round (so every gain stays exact). -> stand-ins, how many try_at refused."""
    out = []
    bad = np.zeros_like(fit)
    rejected = 0
    while True:
        gain = box_sums(integral((~covered).astype(np.float64)), kv, ku)
        cand = fit & ~bad & (gain >= max(1.0, MIN_GAIN * kv * ku))
        if not cand.any():
            break
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
            if claimed[j:j + kv, i:i + ku].any():
                continue
            tried += 1
            bad[j, i] = True                     # (tried once: taken now, or refused for good)
            c = try_at(j, i)
            if c is None:
                rejected += 1
                continue
            claimed[j:j + fv, i:i + fu] = True
            covered[j:j + fv, i:i + fu] = True
            out.append(c)
        if tried == 0:
            break
    return out, rejected


def quad_scales(g):
    """The quad scales tried in a region, largest first: from what its outline's box could hold down to
    MIN_SCALE."""
    u0, v0, u1, v1 = g.inner.bounds
    big, small = max(u1 - u0, v1 - v0), min(u1 - u0, v1 - v0)
    cap = min(QUAD_MAX_SCALE, big / QUAD_W, small / QUAD_H)
    return size_ladder(cap, MIN_SCALE) if cap >= MIN_SCALE else []


def place_region(room, g, ri, index, pr=None, stats=None, cubes=True, avoid=None):
    """The stand-ins behind one prepared region: quads, largest first, then cubes where they leave room (cubes:
    False leaves those out). avoid: grid points (u, v) no stand-in may come within LINE_TOL of (quad_crossings():
    where the harmful lines past open edges cross the plane the stand-ins' fronts lie in; placed round them they fit
    flush, where cut afterwards they would leave a staircase). -> list of Standin."""
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
    # near the region's box; the exact triangle-box tests below have the last word)
    thick = _thickness(room, g, fr, index, us, vs, r, g.cap)
    blocked = blocked_masks(g, ri, pr, us, vs, r) if pr is not None else None
    near_line = None
    if avoid is not None and len(avoid):
        near_line = np.zeros(cell_in.shape, bool)
        i = np.floor((avoid[:, 0] - us[0]) / r).astype(int)
        j = np.floor((avoid[:, 1] - vs[0]) / r).astype(int)
        rad = int(math.ceil(LINE_TOL / r)) + 1
        k = (i >= -rad) & (i < cell_in.shape[1] + rad) & (j >= -rad) & (j < cell_in.shape[0] + rad)
        m = np.zeros((cell_in.shape[0] + 2 * rad, cell_in.shape[1] + 2 * rad), bool)
        m[j[k] + rad, i[k] + rad] = True
        near_line = window(m, 2 * rad + 1, np.maximum)
        near_line = integral(near_line.astype(np.float64))
    inside_sum = integral(cell_in.astype(np.float64))
    covered = ~cell_in
    out = []
    rejected = 0

    def quad_at(s, ori):
        du, dv = quad_dims(s, ori)

        def try_at(j, i):
            u0, v0 = us[i], vs[j]
            c = make_quad(g, u0, v0, s, ori)
            # inside the outline exactly; every other face BACK_GAP away round it and behind it (in front only half
            # that: a neighbour in the face's own plane lies MARGIN in front); the region's own faces clear of it
            ctr_ = c.centre - (BACK_GAP / 4) * fr.a
            ok = inner.contains(sbox(u0, v0, u0 + du, v0 + dv)) and \
                index.box_clear(ctr_, fr.R, np.array([du / 2 + BACK_GAP, dv / 2 + BACK_GAP, 0.75 * BACK_GAP]),
                                skip=g.tris) and \
                index.box_clear(c.centre, fr.R, np.array([du / 2 + BACK_GAP, dv / 2 + BACK_GAP, MARGIN / 2]))
            return c if ok else None
        return du, dv, try_at

    for s in quad_scales(g):
        for ori in (0, 1):
            du, dv, try_at = quad_at(s, ori)
            ku, kv = int(math.ceil(du / r - 1e-9)), int(math.ceil(dv / r - 1e-9))
            if ku > cell_in.shape[1] or kv > cell_in.shape[0]:
                continue
            fit = box_sums(inside_sum, kv, ku) >= kv * ku - 0.5
            fit &= window(thick, kv, np.minimum, ku) >= MARGIN + BACK_GAP
            if blocked is not None:
                fit &= box_sums(integral(blocked[0].astype(np.float64)), kv, ku) < 0.5
            if near_line is not None:
                fit &= box_sums(near_line, kv, ku) < 0.5
            if not fit.any():
                continue
            got, rej = _greedy(covered, fit, kv, ku, max(1, int(du / r + 1e-9)), max(1, int(dv / r + 1e-9)),
                               try_at)
            out += got
            rejected += rej
    if cubes:
        for s in size_ladder(g.cap, MIN_SIZE):
            k = int(math.floor(s / r + 1e-9))
            if k < 1 or k > min(cell_in.shape):
                continue
            s_eff = k * r
            if s_eff < MIN_SIZE - 1e-9:
                continue
            fit = box_sums(inside_sum, k) >= k * k - 0.5
            fit &= window(thick, k, np.minimum) >= s_eff + MARGIN + BACK_GAP
            if blocked is not None:
                fit &= box_sums(integral(blocked[1 + level_of(g, s_eff)].astype(np.float64)), k) < 0.5
            if near_line is not None:
                # (where a line crosses the front plane it runs through a cube's front too: such a cube is cut)
                fit &= box_sums(near_line, k) < 0.5
            if not fit.any():
                continue

            def try_cube(j, i, s_eff=s_eff):
                u0, v0 = us[i], vs[j]
                c = make_cube(g, u0, v0, s_eff)
                # as v1: inside the outline exactly; every other face BACK_GAP away (in front: half that, the
                # cube's front is MARGIN back); the region's own faces clear of the cube itself
                ok = inner.contains(sbox(u0, v0, u0 + s_eff, v0 + s_eff)) and \
                    index.box_clear(c.centre, fr.R, np.array([s_eff / 2 + BACK_GAP] * 2 + [s_eff / 2 + BACK_GAP / 2]),
                                    skip=g.tris) and \
                    index.box_clear(c.centre, fr.R, np.array([s_eff / 2 + BACK_GAP] * 2 + [s_eff / 2]))
                return c if ok else None
            got, rej = _greedy(covered, fit, k, k, k, k, try_cube)
            out += got
            rejected += rej
    if stats is not None:
        stats["rejected"] += rejected
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
        # (faces between the face and the stand-ins' front are in front of them: no obstacle)
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


# a box's six faces as quads (local signs, outward normals): two triangles each. A quad stand-in is the face +x alone
# (its half extent along x is 0), drawn only from in front: one-sided, as the client draws it
_BOX_FACES = []
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
            _q.append(_p)
        _BOX_FACES.append((_ax, _sg, _n, np.array(_q)))
KIND_CUBE, KIND_QUAD = 0, 1


def render_room(room, cam):
    """The room as the renderer draws it, opaque faces only: (distance, face id) per pixel. The faces drawn are
    Render3D/Room.lua's (drawn(): by each face's BSP node plane, not its own winding)."""
    A = room.V[room.T]
    f = np.nonzero(drawn(room, cam.C))[0]
    return raster(cam, cam.to_cam(A[f]), f)


def standin_arrays(sis):
    """A stand-in list as arrays: centres (n, 3), axes (n, 3, 3: rows = the model's x, y, z turned), half extents
    along them (n, 3), normals (n, 3), kinds (n,: KIND_CUBE / KIND_QUAD)."""
    if not sis:
        return np.zeros((0, 3)), np.zeros((0, 3, 3)), np.zeros((0, 3)), np.zeros((0, 3)), np.zeros(0, np.int64)
    return (np.array([c.centre for c in sis]), np.array([c.axes for c in sis]), np.array([c.half for c in sis]),
            np.array([c.n for c in sis]), np.array([KIND_QUAD if c.kind == "quad" else KIND_CUBE for c in sis]))


def record_arrays(recs):
    """standin_arrays of the data contract's records (records(), read_records(), the numbers of a written file) as
    the runtime places them: the anchor, turned by ypr_matrix(yaw, pitch, roll), a cube 2 half x scale a side, a
    quad w x h x scale."""
    a = np.asarray(recs, float).reshape(-1, 12)
    M = ypr_matrices(a[:, 4], a[:, 5], a[:, 6])
    R = np.transpose(M, (0, 2, 1))
    quad = a[:, 0] == QUAD
    H = np.zeros((len(a), 3))
    H[~quad] = (PRIMS[CUBE]["half"] * a[~quad, 7])[:, None]
    H[quad, 1] = QUAD_W / 2 * a[quad, 7]
    H[quad, 2] = QUAD_H / 2 * a[quad, 7]
    return a[:, 1:4].copy(), R, H, a[:, 8:11].copy(), np.where(quad, KIND_QUAD, KIND_CUBE)


def reach(arr):
    """How far each stand-in reaches out along its normal from its anchor: sum over its axes of half x |n . axis|."""
    C, R, H, N, K = arr
    return (H * np.abs(np.einsum("ij,ikj->ik", N, R))).sum(1)


def shown(cam, arr, rule=RULE):
    """Which stand-ins show: their surface faces the camera and they are in view. Rule 'reach': the camera farther
    out along n than the stand-in reaches (the surface lies at least that far out, so a camera less far is behind
    it). Rule 'guard' (Render3D/Standins.lua's and this generator's): farther out than that by the near clip too - a
    camera nearer a surface than the near clip sees it clipped away and would see the stand-in behind it with
    nothing drawn in front. Rule 'centre': dot(n, camera - anchor) > 0, which also shows a cube to a camera between
    its surface and its centre."""
    C, R, H, N, K = arr
    if not len(C):
        return np.zeros(0, bool)
    out = 0.0
    if rule in ("reach", "guard"):
        out = reach(arr)
        if rule == "guard":
            out = out + cam.near
    facing = np.einsum("ij,ij->i", N, cam.C - C) > out
    return facing & cam.sees_sphere(C, np.linalg.norm(H, axis=1))


def render_standins(cam, arr, show=None):
    """The stand-ins the runtime shows: (distance, stand-in index) per pixel. A cube's faces turned to the camera; a
    quad's front only, and only from in front of it (one-sided: from behind it draws, and so hides, nothing)."""
    C, R, H, N, K = arr
    if show is None:
        show = shown(cam, arr)
    idx = np.nonzero(show)[0]
    if not len(idx):
        return np.full((cam.H, cam.W), np.inf), np.full((cam.H, cam.W), -1, np.int64)
    tris, ids = [], []
    for ax, sg, n_loc, q in _BOX_FACES:
        sel = idx if (ax == 0 and sg == 1) else idx[K[idx] == KIND_CUBE]
        if not len(sel):
            continue
        nw = sg * R[sel, ax]                                       # the face's normal in room coordinates
        ctr = C[sel] + nw * H[sel, ax][:, None]
        vis = np.einsum("ij,ij->i", nw, cam.C - ctr) > 0          # (a closed box: its front faces are enough)
        if not vis.any():
            continue
        sel = sel[vis]
        corners = C[sel][:, None, :] + np.einsum("qj,ij,ijk->iqk", q, H[sel], R[sel])
        tris.append(corners[:, [0, 1, 2]])
        tris.append(corners[:, [0, 2, 3]])
        ids += [sel, sel]
    if not tris:
        return np.full((cam.H, cam.W), np.inf), np.full((cam.H, cam.W), -1, np.int64)
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


def _air_box(room):
    """The box any air a model can stand in lies in (_air): the height grid, from 0.1 yd over its lowest floor near
    the boss' up to AIR_H over the highest."""
    if getattr(room, "air_box", None) is None:
        hs = np.where(np.abs(room.heights) <= 3.0, room.heights, np.nan)
        room.air_box = (np.array([0.0, 0.0, float(np.nanmin(hs)) + 0.1]),
                        np.array([room.heights.shape[1] * room.cell, room.heights.shape[0] * room.cell,
                                  float(np.nanmax(hs)) + AIR_H]))
    return room.air_box


def _air_beyond(room, C, u, t0, t1, step=AIR_STEP):
    """Do the rays C + u t (u unit, (n, 3)) run through the air a model can stand in (_air) somewhere between t0
    and t1 (at most AIR_RUN past t0)? Sampled every step inside the box that air lies in. -> (n,) bool"""
    lo, hi = _air_box(room)
    ta, tb = _slab(np.broadcast_to(np.asarray(C, float), u.shape), u, lo, hi)
    ta = np.maximum(ta, t0)
    tb = np.minimum(np.minimum(tb, t1), t0 + AIR_RUN)
    out = np.zeros(len(u), bool)
    live = np.nonzero(tb > ta)[0]
    ns = int(math.ceil(AIR_RUN / step))
    for c0 in range(0, len(live), 20000):
        k = live[c0:c0 + 20000]
        t = ta[k][:, None] + (np.arange(ns) + 0.5)[None] * step
        out[k] = (_air(room, C + u[k][:, None, :] * t[:, :, None]) & (t < tb[k][:, None])).any(1)
    return out


def _over_air(room, cam, d, zs, zr, mask, as_mask=False):
    """How many of the masked pixels could hide a model: the ray past the stand-in (up to the room, or AIR_RUN yd)
    runs through the air over the boss' floor (up to AIR_H over the height grid's floor). as_mask: those pixels."""
    jj, ii = np.nonzero(mask)
    if not len(jj):
        return np.zeros(mask.shape, bool) if as_mask else 0
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
    if as_mask:
        out = np.zeros(mask.shape, bool)
        out[jj[hit], ii[hit]] = True
        return out
    return int(hit.sum())


def measure(room, cam, arr, room_buf=None, rule=None, harm=False):
    """One pose: the over-occlusion and coverage numbers, the stand-ins seen doing it (harm: only where a model could
    be hidden), the buffers for pictures."""
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
    air_e = _over_air(room, cam, d, zs, zr, over_e, as_mask=True) if res["over_eroded"] else np.zeros_like(over_e)
    res["over_air"] = int(air_e.sum())
    # by the kind of face drawn (room.face_kind, when planar_regions has run): drawn, covered (strict), covered (any)
    fk = getattr(room, "face_kind", None)
    if fk is not None:
        k = np.where(drawn, fk[np.maximum(fr, 0)], -1)
        good = drawn & (gap <= MARGIN + EPS_UNDER)
        anyc = drawn & has & (zs >= zr - EPS_OVER)
        for name, code in KIND_CODES.items():
            m = k == code
            res["k_" + name] = (int(m.sum()), int((m & good).sum()), int((m & anyc).sum()))
    worst = air_e if harm else over_e
    culprits = np.unique(ids[dilate(worst) & over & has]) if worst.any() else np.zeros(0, np.int64)
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
        out.append(orbit(tgt, h, p, _walk_allowed(room, tgt, h, p, dist), W=W, H=H, name=name))

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


def height_fn(room, x, y):
    """Render3D/Rooms.lua's HeightFn: the height grid smooth between cell centres, the edge value outside, at a
    hole's edge the floor next to it (0 where there is none at all)."""
    hs, size = room.heights, room.cell
    rows, cols = hs.shape
    fx, fy = x / size - 0.5, y / size - 0.5
    i, j = math.floor(fx), math.floor(fy)
    tx, ty = fx - i, fy - j

    def cell(ii, jj):
        v = hs[max(0, min(rows - 1, jj)), max(0, min(cols - 1, ii))]
        return float(v) if np.isfinite(v) else None
    a, b, c, d = cell(i, j), cell(i + 1, j), cell(i, j + 1), cell(i + 1, j + 1)
    anyv = next((v for v in (a, b, c, d) if v is not None), 0.0)
    a, b, c, d = [anyv if v is None else v for v in (a, b, c, d)]
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty


def lift(dist):
    """UI/StrategyMap3D.lua's Lift: the point looked at rides EYE over the floor all the way in, on it from 5 yd."""
    return EYE * max(0.0, min(1.0, (5 - dist) / (5 - DIST_MIN)))


def board_poses(room, view, seed, n_orbit=0, n_low=0, n_close=0, n_walk=0, W=480, H=320, tag="b"):
    """Poses the strategy board's camera can take, drawn over its whole range (UI/StrategyMap3D.lua V:ClampOrb and
    V:Place): orbits round any point of the room and 30 yd round it (V:Limits), 0.3 yd to the farthest it allows,
    pitch -0.5 (under 3 yd) or 0.12 up to 1.5, the point looked at Lift over the floor; low orbits (pitch 0.12 -
    0.45, what a board user mostly drags to); close looks all the way in (under 3 yd, pitch -0.5 - 0.6); walking
    poses over a character on any floor (pitch -0.6 - 1.45, 1.5 - 40 yd back, pulled in where the room is in the
    way as Room.CameraDistance does). Unlike poses(), nothing here follows the room's views: a check on these is a
    check on what a user can do."""
    rng = np.random.default_rng(seed)
    far = view[2] * 2.2
    out = []

    def target(xlo, xhi, ylo, yhi, dist):
        x, y = rng.uniform(xlo, xhi), rng.uniform(ylo, yhi)
        return (x, y, height_fn(room, x, y) + lift(dist))
    for k in range(n_orbit):
        d = math.exp(rng.uniform(math.log(DIST_MIN), math.log(far)))
        t = target(-30, room.w + 30, -30, room.h + 30, d)
        p = rng.uniform(PITCH_LOOKUP if d < 3 else PITCH_MIN, PITCH_TOP)
        out.append(orbit(t, rng.uniform(0, 2 * math.pi), p, d, W=W, H=H, name="%s-orbit%d" % (tag, k)))
    for k in range(n_low):
        d = math.exp(rng.uniform(math.log(3.0), math.log(far)))
        t = target(-30, room.w + 30, -30, room.h + 30, d)
        out.append(orbit(t, rng.uniform(0, 2 * math.pi), rng.uniform(PITCH_MIN, 0.45), d, W=W, H=H,
                         name="%s-low%d" % (tag, k)))
    for k in range(n_close):
        d = rng.uniform(DIST_MIN, 2.999)
        t = target(0, room.w, 0, room.h, d)
        out.append(orbit(t, rng.uniform(0, 2 * math.pi), rng.uniform(PITCH_LOOKUP, 0.6), d, W=W, H=H,
                         name="%s-close%d" % (tag, k)))
    if n_walk:
        fl = np.nonzero(room.opaque & (room.N[:, 2] > 0.95) & (room.area > 0.3))[0]
        prob = room.area[fl] / room.area[fl].sum()
        for k in range(n_walk):
            f = fl[rng.choice(len(fl), p=prob)]
            a_, b_ = rng.uniform(), rng.uniform()
            if a_ + b_ > 1:
                a_, b_ = 1 - a_, 1 - b_
            P = room.V[room.T[f]]
            piv = P[0] + a_ * (P[1] - P[0]) + b_ * (P[2] - P[0]) + np.array([0.0, 0.0, WALK_EYE])
            h, p = rng.uniform(0, 2 * math.pi), rng.uniform(-0.6, 1.45)
            want = math.exp(rng.uniform(math.log(1.5), math.log(40.0)))
            out.append(orbit(piv, h, p, _walk_allowed(room, piv, h, p, want), W=W, H=H, name="%s-walk%d" % (tag, k)))
    return out


def _walk_allowed(room, piv, h, p, want):
    """How far back the walking camera may stand (Room.CameraDistance's way): five rays from the point it turns
    round, back past its corners; the nearest room face less 0.6 yd, at least 0.8."""
    cp = math.cos(p)
    f = np.array([cp * math.cos(h), cp * math.sin(h), -math.sin(p)])
    r = np.array([math.sin(h), -math.cos(h), 0.0])
    u = np.cross(r, f)
    best = None
    for (a, b) in ((0, 0), (0.35, 0.25), (0.35, -0.25), (-0.35, 0.25), (-0.35, -0.25)):
        dd = -f * want + a * r + b * u
        ln = np.linalg.norm(dd)
        t = _ray_hit(room, piv, dd / ln, ln)
        if t is not None:
            best = t / ln if best is None else min(best, t / ln)
    return want if best is None else min(want, max(0.8, best * want - 0.6))


def _face_point(room, faces, rng):
    """A random point on one of the faces (picked by area) -> point, face."""
    prob = room.area[faces] / room.area[faces].sum()
    f = faces[rng.choice(len(faces), p=prob)]
    a_, b_ = rng.uniform(), rng.uniform()
    if a_ + b_ > 1:
        a_, b_ = 1 - a_, 1 - b_
    P = room.V[room.T[f]]
    return P[0] + a_ * (P[1] - P[0]) + b_ * (P[2] - P[0]), f


def stress_poses(room, view, seed, n_wall=0, n_under=0, n_graze=0, W=480, H=320, tag="s", dom=None):
    """The hardest cameras the board allows (each where CamDomain lets it stand): close to walls and slopes at any
    height, 0.3 - 4 yd out (the nearest inside the near clip's guard, where their own stand-ins must not show), looking
    along them at grazing angles; under floors (as deep as a close look goes) looking up or level; low over floors
    looking level, grazing the floor towards the walls and the floor's edges. Checked like the board poses: nothing
    hidden where a model could be."""
    rng = np.random.default_rng(seed)
    dom = dom or CamDomain(room, view)
    up = np.array([0.0, 0.0, 1.0])
    ok = room.opaque & (room.area > 0.05)
    walls = np.nonzero(ok & (np.abs(room.N[:, 2]) < 0.8))[0]
    floors = np.nonzero(ok & (room.N[:, 2] > 0.95) & (np.abs(room.V[room.T[:, 0], 2]) <= 3.0))[0]
    out = []

    def add(C, h, p, name):
        if C[2] >= float(dom.low(C)):
            out.append(Camera(C, h, p, W=W, H=H, name=name))
            return True
        return False
    k = tries = 0
    while k < n_wall and len(walls) and tries < 50 * n_wall:
        tries += 1
        p, f = _face_point(room, walls, rng)
        n = room.N[f]
        C = p + n * math.exp(rng.uniform(math.log(0.3), math.log(4.0)))
        t = np.cross(up, n)
        t /= max(np.linalg.norm(t), 1e-9)
        nh = n - n[2] * up
        nh /= max(np.linalg.norm(nh), 1e-9)
        g = rng.uniform(0.0, 0.6)
        look = math.cos(g) * t * rng.choice((-1.0, 1.0)) - math.sin(g) * nh
        if add(C, math.atan2(look[1], look[0]), rng.uniform(-0.4, 0.5), "%s-wall%d" % (tag, k)):
            k += 1
    k = tries = 0
    while k < n_under and len(floors) and tries < 50 * n_under:
        tries += 1
        p, f = _face_point(room, floors, rng)
        C = p - up * rng.uniform(0.02, 0.65)
        if add(C, rng.uniform(0, 2 * math.pi), rng.uniform(PITCH_LOOKUP, 0.3), "%s-under%d" % (tag, k)):
            k += 1
    k = tries = 0
    while k < n_graze and len(floors) and tries < 50 * n_graze:
        tries += 1
        p, f = _face_point(room, floors, rng)
        C = p + up * rng.uniform(0.25, 2.5)
        if add(C, rng.uniform(0, 2 * math.pi), rng.uniform(-0.05, 0.15), "%s-graze%d" % (tag, k)):
            k += 1
    return out


# Poses a review of the shipped stand-ins found over-occlusion at (2026-10-05), kept as a regression set: name,
# what the numbers are ('orbit': target, heading, pitch, distance; 'eye': the camera itself, heading, pitch), and
# whether only harmful over-occlusion must be 0 ('air': the camera stands within the near clip of a room face, which
# the runtime clips away so stand-ins behind its neighbours show through - over solid room or under the floor; or it
# looks low past the floor's cut edge, far under the floor, where nothing can stand: the board poses' rule).
REVIEW_POSES = (
    ("b-close86 (panel from below)", "orbit", (27.26, 54.463, 1.15), 4.936, -0.32, 2.156, "all"),
    ("b-orbit48 (panel from below)", "orbit", (28.314, 17.953, 1.772), 2.2844, -0.1917, 0.616, "all"),
    ("panel, near a wall", "eye", (22.267, 50.54, 0.634), 3.883, -0.156, None, "all"),
    ("b-close104 (mirror panel)", "orbit", (109.273, 25.976, 1.741), 0.6862, -0.1089, 0.693, "all"),
    ("lintel from below", "eye", (102.03, 11.89, 0.08), 4.281, 0.105, None, "all"),
    ("lintel, far orbit", "orbit", (38.33, 9.56, 0.0), 3.689, 0.463, 186.0, "all"),
    ("b-low121 (floor edge)", "orbit", (108.099, 83.921, 0.0), 3.8566, 0.1937, 6.073, "air"),
    ("b-orbit189 (floor edge)", "orbit", (117.012, 51.451, 0.0), 3.7223, 0.149, 7.298, "air"),
    ("b-walk8 (pulled in 0.8 yd)", "eye", (103.93759551, 70.04963556, 1.92517999), 2.77803603, -0.35014524, None,
     "all"),
    ("floor6 (on a ledge top)", "orbit", (71.51, 5.41, 0.02), 0.049, 0.198, 5.43, "air"),
    ("lookup3 (near a ledge)", "orbit", (77.71, 9.09, 1.15), 2.569, -0.425, 2.78, "air"),
)


def review_poses(W=960, H=640):
    """REVIEW_POSES as cameras (each with .need: 'all' or 'air')."""
    out = []
    for (name, kind, pos, h, p, dist, need) in REVIEW_POSES:
        cam = orbit(pos, h, p, dist, W=W, H=H, name=name) if kind == "orbit" else \
            Camera(pos, h, p, W=W, H=H, name=name)
        cam.need = need
        out.append(cam)
    return out


# ---------------------------------------------------------------------------------------------------------------
# Open edges: the lines of sight past a region's outline that any camera the board allows could look along
# ---------------------------------------------------------------------------------------------------------------
# A stand-in shows to every camera in front of its face, and a camera low over the face sees past the face's free
# edges (a panel's open bottom, a lintel's underside, the floor's cut edges) into the space behind it, where the
# stand-ins are. Poses only sample that; here the lines themselves are drawn from the geometry: through points just
# under every outline edge, in every direction that rises out of the face's back side past the edge, and kept when
# the board's camera could stand somewhere along it with no room face it would draw in between (a face within the
# near clip of the camera does not count: the runtime clips it away). Such a line continued behind the edge is a
# ray some camera sees along; where it then runs through the air a model can stand in before it meets a face that
# camera draws, a stand-in on it would hide models the room does not ("harmful"), and none may touch it. Lines that
# run only under the floor or out of the room are left to the poses (repair): they hide nothing a model can be in.
EDGE_STEP = 0.3                        # yd between samples along an outline
EDGE_IN = 0.02                         # the lines cross this far inside the outline, under the face
CURTAIN = (MARGIN + 0.01, 0.8, 2.0)   # yd behind the face the lines cross under the outline (a quad's plane, then
                                      # the cubes' depths: a line inside the outline only runs deeper)
KAPPAS = tuple(0.01 * 1.3 ** k for k in range(27))         # a line's slope: yd deeper per yd it runs inward
LAMBDAS = (-6.0, -3.0, -1.5, -0.7, 0.0, 0.7, 1.5, 3.0, 6.0)  # and how far it runs along the edge per yd inward
LINE_TOL = 0.15                        # yd: a stand-in this close to a line counts as on it (the lines' spacing)
HGUARD = NEAR - MARGIN - 0.02          # the least a camera a stand-in shows to stands out of its face (shown())
# a face nearer the camera than this, along the line, may be clipped away by the near plane (seen at the corner of
# a 3:2 view, where the clip plane is nearest)
CLIP = NEAR / math.cos(math.atan(math.tan(FOV / 2) * math.sqrt(1 + 1.5 ** 2)))
CAM_T = tuple(0.05 * 1.15 ** k for k in range(68))        # yd along a line where a camera is looked for (.05 - 650)


class CamDomain:
    """Where the board's camera can stand: zmin(x, y), the lowest it can be over a map point. Orbiting (V:ClampOrb):
    the point looked at anywhere in the room and 30 yd round it, Lift over the floor (HeightFn), the camera dist back
    at pitch -0.5 (under 3 yd) or 0.12 and more: 0.63 yd under the floor of a point 2.6 yd away at the lowest, or
    r tan 0.12 over the floor of one r yd away. Walking cameras stay inside the room, over those. A 1 yd grid out to
    the farthest the camera may stand. under: how far under the floor the close cameras may go (the board: 0.65)."""

    def __init__(self, room, view, under=0.65):
        far = view[2] * 2.2
        pad = int(math.ceil(30 + far))
        self.x0, self.y0 = -pad, -pad
        nx, ny = int(math.ceil(room.w)) + 2 * pad + 1, int(math.ceil(room.h)) + 2 * pad + 1
        # the floor under every point the camera can look at (+inf where it may not look)
        xs = self.x0 + np.arange(nx) + 0.5
        ys = self.y0 + np.arange(ny) + 0.5
        G = np.full((ny, nx), np.inf)
        ii = np.nonzero((xs >= -30) & (xs <= room.w + 30))[0]
        jj = np.nonzero((ys >= -30) & (ys <= room.h + 30))[0]
        for j in jj:
            for i in ii:
                G[j, i] = height_fn(room, xs[i], ys[j])
        # the lowest camera over the floor of a point r yd away: under 3 yd out at pitch -0.5 down to -0.63 (r 2.6);
        # from 3 yd at pitch 0.12, Lift(dist) + r tan(0.12): 0.87 at r 4, 0.6 at r 5, then growing. Every window
        # (a square of half side r) takes the lowest over the distances it adds to the one before (0.6 at r 4 - 5,
        # then the inner distance's), so the domain is never too small
        best = np.full((ny, nx), np.inf)
        radii = (5, 7, 10, 14, 20, 28, 40, 56, 80, 112, 160, 224, pad)
        steps = [(3, -under), (4, 0.85), (5, 0.6)] + [(r, r0 * math.tan(PITCH_MIN)) for r0, r in
                                                      zip(radii, radii[1:])]
        for r, off in steps:
            k = 2 * r + 1
            m = window(np.pad(G, r, constant_values=np.inf), k, np.minimum)
            best = np.minimum(best, m + off)
        self.zmin = best - 0.05                      # (FloorZ: the floor triangle nearest the grid's height)

    def low(self, P):
        """The lowest a camera can stand over each point's map position (+inf where it cannot stand at all)."""
        i = np.floor(P[..., 0] - self.x0).astype(np.int64)
        j = np.floor(P[..., 1] - self.y0).astype(np.int64)
        ok = (i >= 0) & (i < self.zmin.shape[1]) & (j >= 0) & (j < self.zmin.shape[0])
        out = np.full(P.shape[:-1], np.inf)
        out[ok] = self.zmin[j[ok], i[ok]]
        return out


def _outline(room, g):
    """A region's outline: its edges that only one of its faces has (holes too) -> A, B (k, 3) the ends, M (k, 3) the
    unit direction in the face's plane pointing out of the region."""
    cnt = collections.Counter()
    own = {}
    Tm = room.Tm
    for f in g.tris:
        for i in range(3):
            a, b = Tm[f, i], Tm[f, (i + 1) % 3]
            key = (min(a, b), max(a, b))
            cnt[key] += 1
            own[key] = (f, i)
    A, B, M = [], [], []
    for key, c in cnt.items():
        if c != 1:
            continue
        f, i = own[key]
        P = room.V[room.T[f]]
        a, b, other = P[i], P[(i + 1) % 3], P[(i + 2) % 3]
        e = b - a
        ln = np.linalg.norm(e)
        if ln < 1e-4:
            continue
        m = np.cross(e / ln, g.n)
        m /= max(np.linalg.norm(m), 1e-12)
        if m @ (other - a) > 0:
            m = -m
        A.append(a)
        B.append(b)
        M.append(m)
    if not A:
        return np.zeros((0, 3)), np.zeros((0, 3)), np.zeros((0, 3))
    return np.array(A), np.array(B), np.array(M)


def _air(room, X):
    """Points (..., 3) in the air a model can stand in: over a floor of the height grid within 3 yd of the boss'
    floor, 0.1 to AIR_H yd up (as _over_air)."""
    ci = np.floor(X[..., 0] / room.cell).astype(np.int64)
    cj = np.floor(X[..., 1] / room.cell).astype(np.int64)
    ok = (ci >= 0) & (ci < room.heights.shape[1]) & (cj >= 0) & (cj < room.heights.shape[0])
    h = np.full(X.shape[:-1], np.nan)
    h[ok] = room.heights[cj[ok], ci[ok]]
    with np.errstate(invalid="ignore"):
        return np.isfinite(h) & (np.abs(h) <= 3.0) & (X[..., 2] >= h + 0.1) & (X[..., 2] <= h + AIR_H)


class Caster:
    """Rays against the room's opaque faces (Moller-Trumbore, numpy), the faces a batch of rays could meet picked by
    its bounding box from a FaceIndex."""

    def __init__(self, room, index):
        self.room, self.index = room, index
        P = room.V[room.T]
        self.P0, self.E1, self.E2 = P[:, 0], P[:, 1] - P[:, 0], P[:, 2] - P[:, 0]

    def hits(self, O, D, tmax, chunk=64, seg=6.0):
        """Every opaque face met by O + t D, 1e-4 < t <= tmax -> ray indices, faces, t (flat arrays; a face met
        right where two pieces of a ray join may come twice). Long rays are cut into pieces of seg yd, and the pieces
        are taken in chunks by where they lie, so each chunk's box - the faces it is tested against - stays small (a
        long slanted ray's own box holds a good share of the room)."""
        O, D, tmax = np.asarray(O, float), np.asarray(D, float), np.asarray(tmax, float)
        npc = np.maximum(1, np.ceil(tmax / seg).astype(np.int64))
        rep = np.repeat(np.arange(len(O)), npc)
        k = np.arange(len(rep)) - np.repeat(np.cumsum(npc) - npc, npc)
        t0 = k * seg
        t1 = np.minimum(t0 + seg, tmax[rep])
        Op, Dp, Tm = O[rep] + D[rep] * t0[:, None], D[rep], t1 - t0
        Tlo = np.where(k == 0, 1e-4, 0.0)
        cell = np.floor((Op + Dp * (Tm / 2)[:, None]) / 4.0).astype(np.int64)
        order = np.lexsort((cell[:, 2], cell[:, 1], cell[:, 0]))
        out_r, out_f, out_t = [], [], []
        for c0 in range(0, len(order), chunk):
            sel = order[c0:c0 + chunk]
            o, d, tm, tl = Op[sel], Dp[sel], Tm[sel], Tlo[sel]
            ends = o + d * tm[:, None]
            lo = np.minimum(o, ends).min(0) - 1e-3
            hi = np.maximum(o, ends).max(0) + 1e-3
            f = self.index.near(lo, hi)
            f = f[self.room.opaque[f]]
            if not len(f):
                continue
            # (component by component: np.cross on (rays, faces, 3) arrays copies a lot)
            e1x, e1y, e1z = (self.E1[f, q][None, :] for q in range(3))
            e2x, e2y, e2z = (self.E2[f, q][None, :] for q in range(3))
            dx, dy, dz = (d[:, q][:, None] for q in range(3))
            px, py, pz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
            det = e1x * px + e1y * py + e1z * pz
            ok = np.abs(det) > 1e-12
            inv = np.where(ok, 1.0 / np.where(ok, det, 1.0), 0.0)
            sx = o[:, 0][:, None] - self.P0[f, 0][None, :]
            sy = o[:, 1][:, None] - self.P0[f, 1][None, :]
            sz = o[:, 2][:, None] - self.P0[f, 2][None, :]
            u = (sx * px + sy * py + sz * pz) * inv
            qx, qy, qz = sy * e1z - sz * e1y, sz * e1x - sx * e1z, sx * e1y - sy * e1x
            v = (dx * qx + dy * qy + dz * qz) * inv
            t = (e2x * qx + e2y * qy + e2z * qz) * inv
            hit = ok & (u >= -1e-9) & (v >= -1e-9) & (u + v <= 1 + 1e-9) & (t > tl[:, None]) & (t <= tm[:, None])
            r_, k_ = np.nonzero(hit)
            out_r.append(rep[sel[r_]])
            out_f.append(f[k_])
            out_t.append(t[r_, k_] + t0[sel[r_]])
        if not out_r:
            z = np.zeros(0, np.int64)
            return z, z, np.zeros(0)
        return np.concatenate(out_r), np.concatenate(out_f), np.concatenate(out_t)


def _slab(P, Dv, lo, hi):
    """Where the rays P + t Dv (n, 3) run inside the box lo .. hi: t from, t to (from > to: never)."""
    ta, tb = np.full(len(P), -np.inf), np.full(len(P), np.inf)
    for k in range(3):
        d = Dv[:, k]
        par = np.abs(d) < 1e-12
        with np.errstate(divide="ignore", invalid="ignore"):
            u = (lo[k] - P[:, k]) / d
            v = (hi[k] - P[:, k]) / d
        out = par & ((P[:, k] < lo[k]) | (P[:, k] > hi[k]))
        ta = np.where(par, np.where(out, np.inf, ta), np.maximum(ta, np.minimum(u, v)))
        tb = np.where(par, np.where(out, -np.inf, tb), np.minimum(tb, np.maximum(u, v)))
    return ta, tb


def _harmful(room, g, cast, dom, P, Wd, D, box, counts):
    """One batch of lines through P (behind g's outline, D yd under its face) rising along Wd (unit) out of its
    back side: the harmful ones (open edges, above) -> P0, P1, C (as open_lines)."""
    n = g.n
    counts["lines"] += len(P)
    # 1. air somewhere behind: the back ray's run through the box of the height grid's air, every AIR_STEP
    ta, tb = _slab(P, -Wd, box[0], box[1])
    ta, tb = np.maximum(ta, 0.0), np.minimum(tb, AIR_RUN)
    cand = np.nonzero(tb > ta)[0]
    if not len(cand):
        return None
    ns = int(math.ceil(AIR_RUN / AIR_STEP))
    s = ta[cand][:, None] + (np.arange(ns) + 0.5)[None] * AIR_STEP
    a = _air(room, P[cand][:, None, :] - Wd[cand][:, None, :] * s[:, :, None]) & (s <= tb[cand][:, None])
    any_ = a.any(1)
    cand, s, a = cand[any_], s[any_], a[any_]
    counts["air"] += len(cand)
    if not len(cand):
        return None
    # 2. the first place along the line a camera could stand: the board lets it stand there, and it stands out of
    # the face as far as a camera any stand-in shows to
    Pc, Wc = P[cand], Wd[cand]
    cam_t = np.array(CAM_T)
    X = Pc[:, None, :] + Wc[:, None, :] * cam_t[None, :, None]
    ok = (X[:, :, 2] >= dom.low(X)) & (X @ n - (g.d + g.dlo) >= HGUARD)
    has = ok.any(1)
    Pc, Wc, s, a = Pc[has], Wc[has], s[has], a[has]
    tv = cam_t[np.argmax(ok[has], axis=1)]
    counts["camera"] += len(Pc)
    if not len(Pc):
        return None
    Cv = Pc + Wc * tv[:, None]
    # 3. open: no face that camera draws between it and the line's start, past the near clip (farther cameras
    # along the line only have more faces in between)
    tmax = tv - CLIP
    blocked = np.zeros(len(Pc), bool)
    sel = np.nonzero(tmax > 1e-4)[0]
    if len(sel):
        r_, f_, _ = cast.hits(Pc[sel], Wc[sel], tmax[sel])
        if len(r_):
            sv = np.einsum("ij,ij->i", room.NP[f_], Cv[sel][r_]) + room.NPd[f_]
            dr = room.QO[f_] * sv > EPS_SIDE
            blocked[sel[np.unique(r_[dr])]] = True
    keep = ~blocked
    Pc, Wc, Cv, s, a = Pc[keep], Wc[keep], Cv[keep], s[keep], a[keep]
    counts["open"] += len(Pc)
    if not len(Pc):
        return None
    # 4. what that camera sees behind: the first face it draws along the line on from the start. Harmful when air
    # comes before it; a cube on the line matters only where air lies behind the point the line enters it, so the
    # line is kept up to its last air before that face
    last_any = np.where(a, s, -np.inf).max(1)
    r_, f_, t_ = cast.hits(Pc, -Wc, last_any + AIR_STEP)
    back = np.full(len(Pc), np.inf)
    if len(r_):
        sv = np.einsum("ij,ij->i", room.NP[f_], Cv[r_]) + room.NPd[f_]
        dr = room.QO[f_] * sv > EPS_SIDE
        np.minimum.at(back, r_[dr], t_[dr])
    last = np.where(a & (s + AIR_STEP / 2 < back[:, None]), s + AIR_STEP / 2, -np.inf).max(1)
    harm = np.isfinite(last)
    counts["harmful"] += int(harm.sum())
    if not harm.any():
        return None
    Pc, Wc, Cv, last = Pc[harm], Wc[harm], Cv[harm], last[harm]
    tc = D / np.maximum(Wc @ n, 1e-9)                    # (where it comes out of the face's plane)
    return Pc + Wc * tc[:, None], Pc - Wc * last[:, None], Cv


def open_lines(room, regs, index, dom, log=None, batch=4000, curtains=CURTAIN):
    """The harmful lines of sight past the regions' outlines (see above), crossing under them at the depths
    `curtains` -> dict of arrays: reg (index into regs), rid (the region's id), P0 (where the line comes out of the
    face's plane, outside the outline), P1 (its last point in the air before the first face the camera draws
    behind), C (a camera the board allows that sees along it); counts, seconds."""
    t0 = time.time()
    cast = Caster(room, index)
    hmin = float(np.nanmin(np.where(np.abs(room.heights) <= 3.0, room.heights, np.nan)))
    box = (np.array([0.0, 0.0, hmin + 0.1]),
           np.array([room.heights.shape[1] * room.cell, room.heights.shape[0] * room.cell, 3.0 + AIR_H]))
    kk, ll = np.meshgrid(np.array(KAPPAS), np.array(LAMBDAS), indexing="ij")
    kk, ll = kk.reshape(-1), ll.reshape(-1)
    res = collections.defaultdict(list)
    counts = collections.Counter()
    for ri, g in enumerate(regs):
        A, B, M = _outline(room, g)
        if not len(A):
            continue
        Q, Mq, Eq = [], [], []
        for a, b, m in zip(A, B, M):
            ln = np.linalg.norm(b - a)
            nk = max(1, int(math.ceil(ln / EDGE_STEP)))
            f = (np.arange(nk) + 0.5) / nk
            Q.append(a + f[:, None] * (b - a))
            Mq.append(np.repeat(m[None], nk, 0))
            Eq.append(np.repeat(((b - a) / ln)[None], nk, 0))
        Q, Mq, Eq = np.concatenate(Q), np.concatenate(Mq), np.concatenate(Eq)
        per = max(1, batch // len(kk))
        for D in curtains:
            for q0 in range(0, len(Q), per):
                q = slice(q0, q0 + per)
                p = Q[q] - EDGE_IN * Mq[q] - D * g.n
                w = Mq[q][:, None, :] + ll[None, :, None] * Eq[q][:, None, :] + kk[None, :, None] * g.n
                w /= np.linalg.norm(w, axis=2)[:, :, None]
                got = _harmful(room, g, cast, dom, np.repeat(p, len(kk), 0), w.reshape(-1, 3), D, box, counts)
                if got is not None:
                    res["reg"].append(np.full(len(got[0]), ri))
                    res["rid"].append(np.full(len(got[0]), g.id))
                    for k, v in zip(("P0", "P1", "C"), got):
                        res[k].append(v)
        if log and (ri + 1) % 50 == 0:
            log("  open lines: %d/%d regions, %d lines, %d harmful (%.0f s)" % (
                ri + 1, len(regs), counts["lines"], counts["harmful"], time.time() - t0))
    out = {k: np.concatenate(v) for k, v in res.items()} if res else \
        dict(reg=np.zeros(0, np.int64), rid=np.zeros(0, np.int64), P0=np.zeros((0, 3)), P1=np.zeros((0, 3)),
             C=np.zeros((0, 3)))
    out["counts"] = dict(counts)
    out["seconds"] = time.time() - t0
    return out


def merge_lines(a, b):
    """Two open_lines results as one (reg dropped: it indexes each one's own region list; rid stays)."""
    out = {k: np.concatenate([a[k], b[k]]) for k in ("rid", "P0", "P1", "C")}
    out["counts"] = dict(collections.Counter(a["counts"]) + collections.Counter(b["counts"]))
    out["seconds"] = a["seconds"] + b["seconds"]
    return out


def _seg_box(P0, P1, centre, axes, half):
    """Do the segments P0 -> P1 (n, 3) touch the boxes (centre (n, 3) or (3,), rows of axes (n, 3, 3) or (3, 3),
    half sizes (n, 3) or (3,))? (slab test)"""
    centre, axes, half = np.asarray(centre, float), np.asarray(axes, float), np.asarray(half, float)
    if axes.ndim == 2:
        a, b = (P0 - centre) @ axes.T, (P1 - centre) @ axes.T
    else:
        a = np.einsum("nkj,nj->nk", axes, P0 - centre)
        b = np.einsum("nkj,nj->nk", axes, P1 - centre)
    h = np.broadcast_to(half, a.shape)
    d = b - a
    t0, t1 = np.zeros(len(a)), np.ones(len(a))
    for k in range(3):
        par = np.abs(d[:, k]) < 1e-12
        with np.errstate(divide="ignore", invalid="ignore"):
            u = (-h[:, k] - a[:, k]) / d[:, k]
            v = (h[:, k] - a[:, k]) / d[:, k]
        inside = np.abs(a[:, k]) <= h[:, k]
        t0 = np.maximum(t0, np.where(par, np.where(inside, -np.inf, np.inf), np.minimum(u, v)))
        t1 = np.minimum(t1, np.where(par, np.where(inside, np.inf, -np.inf), np.maximum(u, v)))
    return t0 <= t1


def _line_candidates(lines, C, ext, vox=2.0, step=2.0, chunk=20000):
    """The (line, thing) pairs to test, chunk by chunk: things (centres C, ball radii ext) are filed by vox yd cells
    (each in the cells its ball and one cell round it touch), and every line's segment P0 -> P1 is looked up there
    every step yd of its run through their box (a step of up to two cells cannot pass a thing by: some look-up lands
    within half a step of where the segment meets its ball, so in the cell ring round it). Yields line indices and
    thing indices (unique pairs)."""
    lo_all, hi_all = (C - ext[:, None]).min(0) - vox, (C + ext[:, None]).max(0) + vox
    dims = np.floor((hi_all - lo_all) / vox).astype(np.int64) + 1

    def key(v):
        return (v[..., 0] * dims[1] + v[..., 1]) * dims[2] + v[..., 2]
    # the cell table (sorted keys, each with its things)
    ks, cs = [], []
    for i in range(len(C)):
        a = np.floor((C[i] - ext[i] - lo_all) / vox).astype(np.int64) - 1
        b = np.floor((C[i] + ext[i] - lo_all) / vox).astype(np.int64) + 1
        a, b = np.maximum(a, 0), np.minimum(b, dims - 1)
        g = np.stack(np.meshgrid(*[np.arange(a[k], b[k] + 1) for k in range(3)], indexing="ij"), -1).reshape(-1, 3)
        ks.append(key(g))
        cs.append(np.full(len(g), i))
    ks, cs = np.concatenate(ks), np.concatenate(cs)
    o = np.argsort(ks, kind="stable")
    ks, cs = ks[o], cs[o]
    tk, start = np.unique(ks, return_index=True)
    stop = np.append(start[1:], len(ks))
    P0, P1 = lines["P0"], lines["P1"]
    Dv = P1 - P0
    ta, tb = _slab(P0, Dv, lo_all, hi_all)
    ta, tb = np.maximum(ta, 0.0), np.minimum(tb, 1.0)
    live = np.nonzero(tb > ta)[0]
    ln = np.linalg.norm(Dv, axis=1)
    for c0 in range(0, len(live), chunk):
        li = live[c0:c0 + chunk]
        n_s = np.ceil((tb[li] - ta[li]) * ln[li] / step).astype(np.int64) + 1
        rep = np.repeat(li, n_s)
        k = np.arange(len(rep)) - np.repeat(np.cumsum(n_s) - n_s, n_s)
        f = ta[rep] + (tb[rep] - ta[rep]) * k / np.maximum(np.repeat(n_s, n_s) - 1, 1)
        X = P0[rep] + Dv[rep] * f[:, None]
        kv = key(np.clip(np.floor((X - lo_all) / vox).astype(np.int64), 0, dims - 1))
        kl = np.unique(np.stack([kv, rep], 1), axis=0)
        pos = np.searchsorted(tk, kl[:, 0])
        hit = (pos < len(tk)) & (tk[np.minimum(pos, len(tk) - 1)] == kl[:, 0])
        kl, pos = kl[hit], pos[hit]
        if not len(kl):
            continue
        cnt = stop[pos] - start[pos]
        line = np.repeat(kl[:, 1], cnt)
        j = np.repeat(start[pos], cnt) + (np.arange(cnt.sum()) - np.repeat(np.cumsum(cnt) - cnt, cnt))
        pr = np.unique(line * len(C) + cs[j])
        yield pr // len(C), pr % len(C)


def _plane_cross(lines, line, centre, normal):
    """Where each line's segment P0 -> P1 crosses the plane through centre (normal: its front) from the front:
    -> crosses (bool), the point (n, 3)."""
    P0, P1 = lines["P0"][line], lines["P1"][line]
    s0 = np.einsum("ij,ij->i", P0 - centre, normal)
    s1 = np.einsum("ij,ij->i", P1 - centre, normal)
    x = (s0 >= 0) & (s1 <= 0) & (s0 - s1 > 1e-12)
    f = np.where(x, s0 / np.where(x, s0 - s1, 1.0), 0.0)
    return x, P0 + f[:, None] * (P1 - P0)


def on_lines(lines, cubes, tol=LINE_TOL, vox=2.0, step=2.0):
    """The stand-ins (a list, or standin_arrays() of one) a harmful line runs through (a cube: within tol of its sides
    and back; a quad: crossing its plane from the front within tol of its rectangle) while the camera that sees along
    it shows them (a cube: rule 'reach', a hair looser than shown(); a quad: the near clip's guard less 2 cm - a
    camera nearer its plane never sees it, and the cameras farther out along the line are not known to see along
    it) -> set of indices (_line_candidates() finds the pairs to test)."""
    arr = cubes if isinstance(cubes, tuple) else standin_arrays(cubes)
    C, R, H, N, K = arr
    if not len(lines["P0"]) or not len(C):
        return set()
    P0, P1, Cam = lines["P0"], lines["P1"], lines["C"]
    out_n = np.where(K == KIND_QUAD, NEAR - 0.02, reach(arr))
    # a cube's box tested: tol wider round the sides and the back, but its front where it is (MARGIN behind the face:
    # a line ending in the air just in front of the face must not catch it)
    along = np.einsum("ikj,ij->ik", R, N)
    kf = np.argmax(np.abs(along), axis=1)
    rows = np.arange(len(C))
    half = H + tol
    half[rows, kf] -= tol / 2
    Cb = C - (tol / 2) * np.sign(along[rows, kf])[:, None] * R[rows, kf]
    bad = np.zeros(len(C), bool)
    for line, si in _line_candidates(lines, C, np.linalg.norm(H, axis=1) + tol, vox, step):
        keep = ~bad[si] & (np.einsum("ij,ij->i", Cam[line] - C[si], N[si]) > out_n[si])
        line, si = line[keep], si[keep]
        if not len(line):
            continue
        hit = np.zeros(len(line), bool)
        cb = K[si] == KIND_CUBE
        if cb.any():
            hit[cb] = _seg_box(P0[line[cb]], P1[line[cb]], Cb[si[cb]], R[si[cb]], half[si[cb]])
        # a quad has no inside: a line hits it where it crosses its plane from the front within its rectangle
        # (tol wider round it: the lines' spacing), not where it runs under it
        qd = ~cb
        if qd.any():
            lq, sq = line[qd], si[qd]
            x, X = _plane_cross(lines, lq, C[sq], R[sq, 0])
            X = X - C[sq]
            a_ = np.abs(np.einsum("ij,ij->i", X, R[sq, 1]))
            b_ = np.abs(np.einsum("ij,ij->i", X, R[sq, 2]))
            hit[qd] = x & (a_ <= H[sq, 1] + tol) & (b_ <= H[sq, 2] + tol)
        bad[np.unique(si[hit])] = True
    return set(np.nonzero(bad)[0].tolist())


def quad_crossings(lines, regs, tol=LINE_TOL):
    """Where the harmful lines - any region's - cross the plane each region's quads lie in (MARGIN behind its face)
    from the front, within its outline's box and tol round it, while their camera stands far enough out of that
    plane to see a quad there (on_lines' rule): per region (index into regs) the points' grid u, v. A quad there
    would hide what the line's camera sees past an open edge, so the placement keeps quads tol away from them."""
    out = [np.zeros((0, 2)) for _ in regs]
    if not len(lines["P0"]) or not regs:
        return out
    C, Nn, E1, E2, B = [], [], [], [], []
    for g in regs:
        fr = g.frame
        u0, v0, u1, v1 = g.inner.bounds
        tq = g.d + g.dlo - MARGIN
        C.append(((u0 + u1) / 2) * fr.e1 + ((v0 + v1) / 2) * fr.e2 + tq * fr.a)
        Nn.append(fr.a)
        E1.append(fr.e1)
        E2.append(fr.e2)
        B.append(((u1 - u0) / 2, (v1 - v0) / 2))
    C, Nn, E1, E2, B = (np.array(x) for x in (C, Nn, E1, E2, B))
    got = collections.defaultdict(list)
    for line, ri in _line_candidates(lines, C, np.hypot(B[:, 0], B[:, 1]) + tol):
        x, X = _plane_cross(lines, line, C[ri], Nn[ri])
        X = X - C[ri]
        a_, b_ = np.einsum("ij,ij->i", X, E1[ri]), np.einsum("ij,ij->i", X, E2[ri])
        k = x & (np.abs(a_) <= B[ri, 0] + tol) & (np.abs(b_) <= B[ri, 1] + tol) & \
            (np.einsum("ij,ij->i", lines["C"][line] - C[ri], Nn[ri]) > NEAR - 0.02)
        for r_ in np.unique(ri[k]):
            m = k & (ri == r_)
            got[int(r_)].append(np.c_[a_[m], b_[m]] + np.array([C[r_] @ E1[r_], C[r_] @ E2[r_]]))
    for r_, v in got.items():
        out[r_] = np.concatenate(v)
    return out


def cut_on_lines(lines, cubes, log=None):
    """Every stand-in a harmful line runs through is cut into quarters, and those again until none is (quarters
    under the smallest size go); only the new quarters are looked at again. -> stand-ins, counts."""
    counts = collections.Counter()
    out, todo = [], list(cubes)
    while todo:
        bad = on_lines(lines, todo)
        nxt = []
        for i, c in enumerate(todo):
            if i not in bad:
                out.append(c)
            elif can_split(c):
                nxt += split(c)
                counts["split"] += 1
            else:
                counts["removed"] += 1
        todo = nxt
    if log:
        log("open lines: %d stand-ins cut, %d removed" % (counts["split"], counts["removed"]))
    return out, counts


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


def can_split(c):
    """Are a stand-in's quarters big enough to keep (a quad's scale MIN_SCALE, a cube MIN_SIZE)?"""
    return c.s / 2 >= (MIN_SCALE - 1e-12 if c.kind == "quad" else MIN_SIZE - 1e-9)


def split(c):
    """A stand-in's four quarters (half the size, the same front plane: each lies inside it, so it hides nothing
    the whole did not; a quad's quarters keep its shape)."""
    g, h = c.region, c.s / 2
    out = []
    for du in (0, c.du / 2):
        for dv in (0, c.dv / 2):
            if c.kind == "quad":
                out.append(make_quad(g, c.u0 + du, c.v0 + dv, h, c.ori, parent=c))
            else:
                out.append(make_cube(g, c.u0 + du, c.v0 + dv, h, parent=c))
    return out


def repair(room, cubes, cams, log=print, harm=False):
    """Pose by pose: every stand-in that hides something the room does not (after the 1-pixel erosion; harm: only
    where a model could be) is cut into quarters, again until the pose is clean; quarters under the smallest size
    go. Quarters lie inside their stand-in and show for no more cameras (their front is its front), so a pose made
    clean stays clean. -> stand-ins, counts, every pose's last numbers, the index of the last pose that changed the
    set (numbers of the poses before it are of an older set)."""
    counts = collections.Counter()
    results, last = [], -1
    for pi, cam in enumerate(cams):
        rb = render_room(room, cam)
        rounds = 0
        while True:
            arr = standin_arrays(cubes)
            res, culprits, _ = measure(room, cam, arr, rb, harm=harm)
            if not len(culprits):
                break
            rounds += 1
            bad = set(int(i) for i in culprits)
            keep = [c for i, c in enumerate(cubes) if i not in bad]
            for i in bad:
                c = cubes[i]
                if can_split(c):
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
    """Every pose's numbers (measure) -> list of dicts. cubes: stand-ins, or standin_arrays() / record_arrays()."""
    arr = cubes if isinstance(cubes, tuple) else standin_arrays(cubes)
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
    """Areas (yd^2): opaque / see-through faces, regions by kind, and how much of each kind's outline the stand-ins'
    footprints cover (<kind>_covered: all of them, <kind>_quads: the quads alone)."""
    from shapely.geometry import box as sbox
    from shapely.ops import unary_union
    a = dict(opaque=float(room.area[room.opaque].sum()),
             alphakey=float(room.area[room.blend == "A"].sum()),
             blend=float(room.area[room.blend == "B"].sum()))
    for g in regions:
        a[g.kind] = a.get(g.kind, 0.0) + g.area
    by, byq = collections.defaultdict(list), collections.defaultdict(list)
    for c in cubes:
        b = sbox(c.u0, c.v0, c.u0 + c.du, c.v0 + c.dv)
        by[c.region.id].append(b)
        if c.kind == "quad":
            byq[c.region.id].append(b)
    cov = collections.Counter()
    for g in regions:
        if g.id in by and getattr(g, "poly", None) is not None:
            cov[g.kind + "_covered"] += unary_union(by[g.id]).intersection(g.poly).area
            if g.id in byq:
                cov[g.kind + "_quads"] += unary_union(byq[g.id]).intersection(g.poly).area
    for k, v in cov.items():
        a[k] = float(v)
    return a


# the board poses (board_poses()) placed against and checked on: orbits, low orbits, close looks, walking
BOARD_TRAIN = dict(seed=11, n_orbit=240, n_low=160, n_close=120, n_walk=80)
BOARD_CHECK = dict(seed=23, n_orbit=120, n_low=80, n_close=60, n_walk=40)
# the stress poses (stress_poses()): close to walls, under floors, grazing floors
STRESS_TRAIN = dict(seed=31, n_wall=140, n_under=60, n_graze=80)
STRESS_CHECK = dict(seed=37, n_wall=70, n_under=30, n_graze=40)


def build(key=DEFAULT_KEY, fast=False, log=print, W=None, H=None, limit=None, cubes=True):
    """The whole run for one room. fast: fewer and smaller poses (tests); limit: only the largest regions; cubes:
    False places quads alone."""
    t0 = time.time()
    room = load_room(key)
    view, spot = room_view(key)
    regions = planar_regions(room)
    index = FaceIndex(room)
    stats = collections.Counter()
    regs = [g for g in sorted(regions, key=lambda g: -g.area) if prepare_region(room, g)]
    if limit:
        regs = regs[:limit]
    if W is None:
        W, H = (320, 214) if fast else (960, 640)
    EW, EH = (240, 160) if fast else (480, 320)
    dom = CamDomain(room, view)
    # the training poses: the room's own views (nothing seen past the room at all) and the board camera's whole
    # range and its hardest corners (nothing seen past the room where a model could be: low over the floor from
    # outside the room, a camera sees far under the floor past its cut edges, where nothing can stand)
    train = poses(room, view, spot, "train", W=W, H=H)
    train_e = poses(room, view, spot, "train", W=EW, H=EH)
    btrain = board_poses(room, view, W=W, H=H, tag="t", **BOARD_TRAIN)
    btrain_e = board_poses(room, view, W=EW, H=EH, tag="t", **BOARD_TRAIN)
    strain = stress_poses(room, view, W=W, H=H, tag="t", dom=dom, **STRESS_TRAIN)
    strain_e = stress_poses(room, view, W=EW, H=EH, tag="t", dom=dom, **STRESS_TRAIN)
    if fast:
        train, train_e, btrain, btrain_e = train[::7], train_e[::7], btrain[::7], btrain_e[::7]
        strain, strain_e = strain[::7], strain_e[::7]
    pr = make_probes(room, regs)
    vf = (H / 2.0) / math.tan(FOV / 2.0)
    expose(room, pr, train_e, val_F=vf, log=log)
    expose(room, pr, btrain_e + strain_e, val_F=vf, log=log, harmful_only=True)
    t_exp = time.time() - t0
    log("%s: %d regions (%d get stand-ins), %d probes, %d seen by a pose (%.0f s)"
        % (key, len(regions), len(regs), len(pr.P), pr.exposed.sum(), time.time() - t0))
    # the lines of sight past open edges any board camera has (whatever the poses saw): under every outline at the
    # quads' depth first (the placement keeps quads off them); at the cubes' depths only where cubes were placed
    lines = open_lines(room, regs, index, dom, log=log, curtains=CURTAIN[:1])
    log("open lines: %s (%.0f s)" % (lines["counts"], time.time() - t0))
    cross = quad_crossings(lines, regs)
    t1 = time.time()
    sis = []
    for ri, g in enumerate(regs):
        sis += place_region(room, g, ri, index, pr, stats=stats, cubes=cubes, avoid=cross[ri])
    placed = len(sis)
    placed_kinds = dict(collections.Counter(c.kind for c in sis))
    t_place = time.time() - t1
    log("%d stand-ins placed %s (%.0f s)" % (placed, placed_kinds, time.time() - t0))
    with_cubes = [g for g in regs if any(c.kind == "cube" and c.region is g for c in sis)]
    if with_cubes:
        deep = open_lines(room, with_cubes, index, dom, log=log, curtains=CURTAIN[1:])
        log("open lines at the cubes' depths, %d regions: %s (%.0f s)" % (len(with_cubes), deep["counts"],
                                                                         time.time() - t0))
        lines = merge_lines(lines, deep)
    t1 = time.time()
    sis, lc = cut_on_lines(lines, sis, log=log)
    sis, rc, res_train, last = repair(room, sis, train, log=log)
    sis, bc, res_btrain, blast = repair(room, sis, btrain, log=log, harm=True)
    sis, sc, res_strain, slast = repair(room, sis, strain, log=log, harm=True)
    t_repair = time.time() - t1
    rc.update({"lines_" + k: v for k, v in lc.items()})
    rc.update({"board_" + k: v for k, v in bc.items()})
    rc.update({"stress_" + k: v for k, v in sc.items()})
    log("repair: %d stand-ins (%d split, %d removed, %d poses needed it; board poses %d, %d, %d; stress poses %d, %d, "
        "%d) (%.0f s)" % (len(sis), rc["split"], rc["removed"], rc["poses"], bc["split"], bc["removed"], bc["poses"],
                          sc["split"], sc["removed"], sc["poses"], time.time() - t0))
    # the held-out numbers are of the data as written (rounded as the file has it, turned as the runtime turns it);
    # the training poses' again where a later change made them stale (the poses before a set's last change, and
    # every pose of a set before one that changed it)
    t1 = time.time()
    arr = record_arrays(records(sis))
    if last > 0 or blast >= 0 or slast >= 0:
        res_train = evaluate(room, arr, train)
    if slast >= 0:
        res_btrain = evaluate(room, arr, btrain)
    elif blast > 0:
        res_btrain[:blast] = evaluate(room, arr, btrain[:blast])
    if slast > 0:
        res_strain[:slast] = evaluate(room, arr, strain[:slast])
    rand = poses(room, view, spot, "random", W=W, H=H, seed=7)
    board = board_poses(room, view, W=W, H=H, tag="b", **BOARD_CHECK)
    stress = stress_poses(room, view, W=W, H=H, tag="s", dom=dom, **STRESS_CHECK)
    review = review_poses(W, H)
    if fast:
        rand, board, stress, review = rand[::6], board[::10], stress[::10], review[::3]
    res_rand = evaluate(room, arr, rand)
    # the same random poses with no near clip in the rule: what changes is only cameras nearer a surface than it
    res_rand_reach = evaluate(room, arr, rand, rule="reach")
    # poses the placement never saw, over the board camera's whole range and its hardest corners, and the review's
    res_board = evaluate(room, arr, board)
    res_stress = evaluate(room, arr, stress)
    res_review = evaluate(room, arr, review)
    for r, cam in zip(res_review, review):
        r["need"] = cam.need
    t_check = time.time() - t1
    checked = len(train) + len(btrain) + len(strain) + len(rand) + len(board) + len(stress) + len(review)
    if not fast and not limit and checked != POSES_CHECKED:
        log("note: %d poses checked, POSES_CHECKED says %d (the data file's header)" % (checked, POSES_CHECKED))
    return dict(key=key, room=room, regions=regions, cubes=sis, placed=placed, placed_kinds=placed_kinds,
                repair=dict(rc), arr=arr,
                train=summarize(res_train), btrain=summarize(res_btrain), strain=summarize(res_strain),
                random=summarize(res_rand), random_reach=summarize(res_rand_reach), board=summarize(res_board),
                stress=summarize(res_stress), review=summarize(res_review),
                res_train=res_train, res_btrain=res_btrain, res_strain=res_strain, res_rand=res_rand,
                res_rand_reach=res_rand_reach, res_board=res_board, res_stress=res_stress, res_review=res_review,
                lines=lines, checked=checked, areas=region_areas(room, regions, sis), stats=dict(stats), view=view,
                spot=spot, seconds=time.time() - t0, size=(W, H), probes=pr,
                timings=dict(exposure=t_exp, lines=lines["seconds"], place=t_place, repair=t_repair, check=t_check),
                crossings=int(sum(len(c) for c in cross)))


def _num(v, places):
    s = ("%." + str(places) + "f") % v
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def records(cubes):
    """The data contract's 12 numbers per stand-in (prim, x, y, z, yaw, pitch, roll, scale, nx, ny, nz, face), in
    the file's order (by region, so a region's stand-ins form one run) and rounded as the file writes them."""
    out = []
    for c in sorted(cubes, key=lambda c: (c.region.id, c.kind != "quad", c.u0, c.v0)):
        yaw, pitch, roll = standin_angles(c)
        prim = QUAD if c.kind == "quad" else CUBE
        scale = c.s if c.kind == "quad" else c.s / (2 * PRIMS[CUBE]["half"])
        # (1 mm, 1e-5 rad and a scale to 1e-5: a 49 yd quad's corner moves 0.3 mm at most - MARGIN is 50)
        r = (prim, round(c.centre[0], 3), round(c.centre[1], 3), round(c.centre[2], 3), round(yaw, 5),
             round(pitch, 5), round(roll, 5), round(scale, 5 if c.kind == "quad" else 3), round(c.n[0], 5),
             round(c.n[1], 5), round(c.n[2], 5), c.region.id)
        out.append(tuple(0.0 if (isinstance(x, float) and x == 0) else x for x in r))
    return out


def room_stamp(key, room=None):
    """What the stand-ins were made from: the room file's packed size (ns.RoomFloors[key].size, the runtime has
    it) and its vertex and triangle counts."""
    room = room or load_room(key)
    return dict(size=room.size, verts=room.nverts, tris=room.ntris)


def _prims_text():
    c, q = PRIMS[CUBE], PRIMS[QUAD]
    return ('prims = { [1] = { fid = %d, kind = "%s", half = %s }, [2] = { fid = %d, kind = "%s", w = %s, h = %s, '
            'cx = %s, cy = %s, cz = %s } },' % (c["fid"], c["kind"], _num(c["half"], 3), q["fid"], q["kind"],
                                               _num(q["w"], 4), _num(q["h"], 4), _num(q["c"][0], 5),
                                               _num(q["c"][1], 5), _num(q["c"][2], 5)))


def lua_text(key, cubes=None, recs=None, stamp=None):
    """The data file's text, from the stand-ins or from the records (records(); read_records() of a written file);
    stamp: room_stamp() (read from the room file when not given)."""
    rel = "Render3D/Standins/%s.lua" % key
    recs = records(cubes) if recs is None else recs
    stamp = stamp or room_stamp(key)
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end -- DisasterZone %s' % (rel, rel),
        "-- %s: the room's stand-ins (Render3D/Standins.lua shows them): one-sided quads lying just behind" % key,
        "-- its opaque floors, walls and slopes, and cubes in the gaps they leave, drawn in a scene under the room's",
        "-- textures; models in the scenes over it are then hidden per pixel wherever the room is in front of them (all",
        "-- model scenes share one depth buffer). Version 2. 12 numbers per stand-in: prim; x, y, z (room yards: a",
        "-- quad's middle, a cube's centre); yaw, pitch, roll (radians, room coordinates: the turn R = Rz(yaw) Ry(pitch)",
        "-- Rx(roll) - SetYaw, SetPitch, SetRoll as the client applies them, roll first); scale (the actor's); nx, ny, nz",
        "-- (its face's normal, to the side the face is seen from; a quad's front, R's first column, faces it); face",
        "-- (the face's region, for debugging). A prim's model point q stands at (x, y, z) + scale R (q - c), c = the",
        "-- prim's middle (cx, cy, cz; a cube's is its origin): its origin goes to (x, y, z) - scale R c. A quad is the",
        "-- prim's w x h rectangle in its y-z plane, drawn from its front only; a cube is 2 half x scale a side. Show",
        "-- one only while dot(n, camera - (x, y, z)) > reach + near: reach = scale x the sum over its turned axes a",
        "-- of its half extent along a x |n.a| (0 for a quad), near = the view's near clip (0.5 yd); nearer than that,",
        "-- its face may be clipped away while the stand-in is not. room: the room file these were made for (its",
        "-- packed size, vertices and triangles); made for another build of the room they hide the wrong things.",
        "-- Checked offline against the room's z-buffer from %d poses. AUTO-GENERATED by" % POSES_CHECKED,
        "-- dev/generators/gen_standins.py; do not edit by hand.",
        "local _, ns = ...",
        "ns.RoomStandins = ns.RoomStandins or {}",
        'ns.RoomStandins["%s"] = { version = 2,' % key,
        "  " + _prims_text(),
        "  room = { size = %d, verts = %d, tris = %d }," % (stamp["size"], stamp["verts"], stamp["tris"]),
        "  n = %d, stride = 12, data = {" % len(recs),
    ]
    for r in recs:
        quad = int(r[0]) == QUAD
        lines.append("    " + ", ".join([str(int(r[0])), _num(r[1], 3), _num(r[2], 3), _num(r[3], 3), _num(r[4], 5),
                                         _num(r[5], 5), _num(r[6], 5), _num(r[7], 5 if quad else 3), _num(r[8], 5),
                                         _num(r[9], 5), _num(r[10], 5), str(int(r[11]))]) + ",")
    lines.append("} }")
    return "\n".join(lines) + "\n"


def read_records(path):
    """The 12-number records of a written data file (Python side)."""
    with open(path, "rb") as fh:
        src = fh.read().decode("utf-8")
    body = src.split("data = {", 1)[1].rsplit("} }", 1)[0]
    nums = [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?(?:e-?\d+)?", body)]
    return [tuple(nums[i:i + 12]) for i in range(0, len(nums), 12)]


def write_lua(key, cubes=None, out_dir=OUT_DIR, recs=None, stamp=None):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, key + ".lua")
    text = lua_text(key, cubes, recs, stamp)
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


def _size_colour(size, kind):
    """A stand-in's colour in the pictures: quads blue (small) .. orange (big), cubes pink .. red."""
    if kind == KIND_QUAD:
        h = np.clip(np.log2(np.maximum(size, 0.5) / 0.5) / 6.0, 0, 1)
        return np.stack([60 + 190 * h, 200 - 60 * h, 240 - 200 * h], axis=-1)
    h = np.clip(np.log2(np.maximum(size, MIN_SIZE) / MIN_SIZE) / 2.0, 0, 1)
    return np.stack([240 + 0 * h, 120 - 80 * h, 200 - 150 * h], axis=-1)


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
        C, R, Hh, N, K = arr
        ids = b["ids"][s]
        size = 2 * Hh[ids].max(1)
        col = np.where((K[ids] == KIND_QUAD)[:, None], _size_colour(size, KIND_QUAD), _size_colour(size, KIND_CUBE))
        si_img[s] = _shade(N[ids], col)
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
    arr = b.get("arr") or standin_arrays(cubes)
    kinds = collections.Counter(c.kind for c in cubes)
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
    d.text((6, 4), "%s, stand-ins v2: %d quads (653518, one-sided) + %d cubes. Columns: the room (opaque faces facing "
                   "the camera) | the stand-ins shown (quads blue small .. orange big, cubes pink .. red) | errors"
           % (b["key"], kinds.get("quad", 0), kinds.get("cube", 0)), fill=(235, 235, 235))
    d.text((6, 22), "green: a stand-in within %.2f yd behind the face; yellow: within %g yd; red: none; magenta: "
                    "over-occlusion (a stand-in in front of the room or over nothing)" % (MARGIN + EPS_UNDER, LOOSE[-1]),
           fill=(235, 235, 235))
    for k, row in enumerate(rows):
        sheet.paste(row, (0, 40 + k * (H + pad)))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sheet.save(path, optimize=True)
    return path


def top_view(b, path, S=8):
    """The room from above: every region's faces (floors grey, walls blue, slopes red outlines) and the stand-ins'
    footprints in their planes, seen from above (quads blue small .. orange big, cubes pink .. red; a wall's as a
    line along it)."""
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
        if rg is not None and rg.kind == "floor" and room.N[f, 2] > 0:
            d.polygon([px(q) for q in A[f]], fill=(70, 70, 70))
    for f in np.nonzero(room.opaque)[0]:
        rg = b["regions"][room.region_of[f]]
        if rg.kind != "floor":
            col = (50, 70, 110) if rg.kind == "wall" else (110, 40, 40)
            d.line([px(q) for q in A[f]] + [px(A[f][0])], fill=col, width=1)
    for c in sorted(b["cubes"], key=lambda c: -(c.du * c.dv)):
        kind = KIND_QUAD if c.kind == "quad" else KIND_CUBE
        col = tuple(int(x) for x in _size_colour(np.array([max(c.du, c.dv)]), kind)[0])
        fr = c.region.frame
        pts = [(c.u0 + x) * fr.e1 + (c.v0 + y) * fr.e2 + c.tf * fr.a
               for x, y in ((0, 0), (c.du, 0), (c.du, c.dv), (0, c.dv))]
        d.polygon([px(q) for q in pts], outline=col)
    d.text((6, H + 8), "%s from above: stand-in footprints in their planes (quads blue .. orange by size, cubes pink "
                       ".. red); grey floors, blue walls, red sloped faces" % b["key"], fill=(230, 230, 230))
    img.save(path, optimize=True)
    return path


POSE_SETS = (("train", "train"), ("btrain", "board train (harm only)"), ("strain", "stress train (harm only)"),
             ("random", "random"), ("random_reach", "random, rule 'reach'"), ("board", "board (held out)"),
             ("stress", "stress (held out)"), ("review", "review"))


def report(b, size=None):
    a = b["areas"]
    sis = b["cubes"]
    kinds = collections.Counter(c.kind for c in sis)
    by_kind = collections.Counter((c.region.kind, c.kind) for c in sis)
    qs = np.array([c.s for c in sis if c.kind == "quad"]) if kinds.get("quad") else np.zeros(1)
    cs = np.array([c.s for c in sis if c.kind == "cube"]) if kinds.get("cube") else np.zeros(1)
    lines = ["%s: %d stand-ins: %d quads, %d cubes (placed %d %s; repair %s), %.0f s %s"
             % (b["key"], len(sis), kinds.get("quad", 0), kinds.get("cube", 0), b["placed"], b.get("placed_kinds"),
                b["repair"], b["seconds"], {k: int(v) for k, v in b.get("timings", {}).items()}),
             "  by surface %s" % dict(sorted(by_kind.items())),
             "  quad scale min %.3f median %.3f max %.3f (%.2f .. %.1f yd long); cube size min %.2f median %.2f "
             "max %.2f" % (qs.min(), np.median(qs), qs.max(), qs.min() * QUAD_W, qs.max() * QUAD_W, cs.min(),
                           np.median(cs), cs.max()),
             "  areas yd2: " + ", ".join("%s %.0f" % (k, v) for k, v in sorted(a.items()))]
    for k in ("floor", "wall", "slope", "ceiling"):
        if a.get(k):
            lines.append("    %s: %.1f%% of its area under a stand-in (%.1f%% under quads)"
                         % (k, 100 * a.get(k + "_covered", 0) / a[k], 100 * a.get(k + "_quads", 0) / a[k]))
    if "lines" in b:
        lines.append("  open lines (any board camera, past open edges): %s, %.0f s" % (b["lines"]["counts"],
                                                                                   b["lines"]["seconds"]))
    for tag, label in POSE_SETS:
        if tag not in b:
            continue
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
        res = b["res_" + tag.replace("random", "rand")]
        bad = sorted(((r["over_air"], r["over_eroded"], r["name"]) for r in res if r["over_eroded"]),
                     reverse=True)[:5]
        if bad:
            lines.append("    over-occlusion at (eroded px where a model could be / all): "
                         + "; ".join("%s %d / %d" % (n, va, ve) for va, ve, n in bad))
    for r in b.get("res_review", ()):
        lines.append("    review %-30s over-occlusion %6d px eroded, %5d where a model could be (must be 0: %s)"
                     % (r["name"], r["over_eroded"], r["over_air"], "both" if r["need"] == "all" else "the latter"))
    if size is not None:
        lines.append("  file %d bytes" % size)
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("keys", nargs="*", default=[DEFAULT_KEY])
    ap.add_argument("--fast", action="store_true", help="fewer, smaller poses (tests)")
    ap.add_argument("--no-write", action="store_true")
    ap.add_argument("--no-cubes", action="store_true", help="quads alone")
    ap.add_argument("--sheet", action="store_true", help="write dev/docs/img/standins_<short>_v2.png and _v2_top.png")
    ap.add_argument("--json", help="write the numbers here")
    args = ap.parse_args(argv)
    allres = {}
    for key in args.keys:
        b = build(key, fast=args.fast, cubes=not args.no_cubes)
        size = None
        if not args.no_write:
            path, size = write_lua(key, b["cubes"], stamp=room_stamp(key, b["room"]))
            print("wrote", path)
        print(report(b, size))
        if args.sheet:
            short = key.split("_", 1)[-1].lower()
            print("wrote", contact_sheet(b, os.path.join(IMG_DIR, "standins_%s_v2.png" % short)))
            print("wrote", top_view(b, os.path.join(IMG_DIR, "standins_%s_v2_top.png" % short)))
        allres[key] = dict({t: b[t] for t, _ in POSE_SETS}, areas=b["areas"], lines=b["lines"]["counts"],
                           n=len(b["cubes"]), kinds=dict(collections.Counter(c.kind for c in b["cubes"])),
                           placed=b["placed"], repair=b["repair"], size=size, timings=b.get("timings"),
                           seconds=b["seconds"],
                           worst={t: sorted(((r["over_air"], r["over_eroded"], r["name"])
                                             for r in b["res_" + t.replace("random", "rand")]), reverse=True)[:5]
                                  for t, _ in POSE_SETS})
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(allres, fh, indent=1, default=float)
    return allres


if __name__ == "__main__":
    main()
