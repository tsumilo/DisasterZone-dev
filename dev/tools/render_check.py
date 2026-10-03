#!/usr/bin/env python
"""Render check: an offline reference renderer that measures how correct and how stable the Raid Trainer's software
room renderer (Games/Trainer/UI.lua: PrepareMesh / DrawMesh / PlaceTex / UpdateOcclusion) is.

It boots DisasterZone in the harness (wowmock), puts the player at a list of poses that stress the renderer (and
walks a short path in small steps), and for every frame builds two images of the 3D view:

  PAINTER  what WoW would draw, worked out from nothing but the widget state the mock recorded from the API calls:
           every shown texture and line under the view frame with its rectangle resolved from its anchors, its
           vertex offsets (UL=1, LL=2, UR=3, LR=4), texture file and texture coordinates (interpolated affinely,
           as the GPU does with w = 1; a quad is two triangles split along LL-UR), drawn in WoW's order: strata,
           frame level, then inside a frame draw layer (BACKGROUND < BORDER < ARTWORK < OVERLAY < HIGHLIGHT) and
           sublevel, clipped by SetClipsChildren frames. The ModelScene is drawn at its own frame level; each actor
           is an upright billboard (body height from its unit, about 1.2 yd wide, starting 0.15 yd above the feet)
           at its SetPosition (times its scale), depth tested against the other actors only.
  TRUTH    a z-buffered rasterization of the same room mesh (ns.TrainerFloors.<key>.mesh, scene = (x, mirror*y, z))
           with back faces culled (front = counter-clockwise, the renderer's own facing test), the near plane clipped
           at the scene's near clip, perspective-correct texture coordinates, through exactly the camera the mock
           ModelScene uses (Project3DPointTo2D), with the actors' billboards depth tested against the room.

Which surface a painted pixel shows. Every room texture the painter draws is first matched, from its own API data, to
the mesh triangle it is a piece of: same texture file, its three corner texture coordinates inside that triangle's
texture triangle, and the points of the triangle they stand for, projected through the camera, landing on its three
corners (within 1 UI unit). A texture maps its picture affinely, but a correctly placed piece can only ever show
texels of its own triangle, so the affine distortion never makes a correct pixel count as wrong; how far the texel is
off is reported separately as misplacement. Regions that match no triangle fall back to a texture rule: the texture
file is the truth triangle's and the texel lies inside its texture triangle (barycentric >= -0.002). Both tests also
accept the truth triangle of any of the 8 neighbouring pixels (edges).

Metrics per frame (percentages are of the pixels where the truth shows room surface, "truth-covered"):
  wrongSurfacePct  the painter shows a room texture there, but not the surface the truth sees, split into
    wrongPaintedOverPct  the truth's triangle WAS drawn at that pixel, and something else (behind it) was drawn over it
                   later: an order error ("background drawn in front of the foreground"); wrongOverAboveScenePct is
                   the part of it drawn by regions above the ModelScene (lifted over the models);
    wrongMissingPct  the truth's triangle was never drawn at that pixel, so what lies behind it shows through
                   ("triangles disappear");
    wrongUnmatchedPct  wrong pixels of regions that match no triangle.
  holesPct         the truth shows room surface, the painter nothing (the background shows through).
  extraPct         the painter shows room texture where the truth shows none (back faces, culled geometry).
  misplacement     for right-surface pixels: how far, in view pixels (UI units), the texel drawn there really is from
                   that pixel: the texel's point on its triangle (its texture coordinate mapped back through the
                   triangle) projected through the camera. Exact, no linearisation. p95, p99 and max are reported.
  seeThroughPct    (poses) view pixels where a back face is nearer than anything facing the camera: the camera looks
                   out from behind or inside the room's geometry (both renderers then show what is beyond it).
  popMaxPx / popP99Px  (walk path) the largest / 99th percentile change of a pixel's misplacement vector between two
                   consecutive frames, over pixels that show the same truth triangle and are right in both.
  flickerPct       (walk path) pixels (same truth triangle in both frames) whose class (right / wrong / hole) changes
                   from one frame to the next: triangles that blink.
  actorErrPct      pixels inside the actors' billboards where "the actor is visible" differs between painter and
                   truth (a pillar that should hide someone does not, or the room covers someone it should not).
  ambiguousPct     painted pixels whose final colour depends on an order WoW does not define: two regions of the same
                   frame, layer and sublevel, or two different frames with the same strata and level, both covering it
                   (ties between two lines - the segments of one floor mark - are counted apart, ambiguousLinesPct).
  shownTextures    shown textures that carry one of the room's texture files.
  apiCallsPerFrame widget method calls in that frame (the camera moved: a pose is reached from a 0.004 rad turn),
                   with a breakdown of the calls that matter (SetVertexOffset, SetPoint, ...).
  luaMsPerFrame    wall time of one panel tick in the mock (lupa, plain Lua 5.1). Indicative only: the mock's widget
                   calls cost something else than the client's (e.g. its SetParent is linear in the children).

Run:  luaenv\\Scripts\\python.exe tools\\render_check.py --enc teron|vashj|both [--png OUTDIR] [--quick] [--json FILE]
      [--size 600x400] [--scale 1] [--poses a,b] [--no-walk] [--compare OLD.json]
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

LUA_HELPER = os.path.join(HERE, "render_check.lua")

RIGHT_EPS = 0.002            # barycentric tolerance of "the texel lies inside the truth triangle"
NF = 36                      # numbers per R record (see render_check.lua)

# ---------------------------------------------------------------------------------------------------------------
# poses
# ---------------------------------------------------------------------------------------------------------------
PI = math.pi
# name, x, y, facing (0 = east, pi/2 = north), camera pitch, camera distance, what it stresses
POSES = {
    "teron": [
        ("open_floor_north", 30, 8, PI / 2, 0.3, 14, "open floor of the south half, looking north along the hall into the pit"),
        ("cam_behind_west_wall", 10, 12, 0, 0.3, 14, "facing east near the west wall: the camera hangs outside the hall, behind the wall"),
        ("facing_west_wall", 12, 30, PI, 0.3, 14, "facing the west wall from 12 yd, the camera over the pit's west steps"),
        ("behind_west_pillar", 25.5, 26, PI / 2, 0.3, 14, "north of the west pillar by the walkway: the pillar stands between the camera and you"),
        ("camera_in_pillar", 25.5, 28, PI / 2, 0.3, 7, "the camera (7 yd back) ends up inside the west pillar"),
        ("pit_up_west_steps", 28, 40, PI, 0.3, 14, "down in the pit looking west up the steps, the camera over the east steps"),
        ("rim_down_into_pit", 12, 40, 0, 0.8, 14, "on the west rim looking down into the pit (pitch 0.8)"),
        ("grazing_pitch_005", 30, 14, PI / 2, 0.05, 14, "camera almost level with the floor (pitch 0.05): long thin floor triangles"),
        ("overhead_pitch_12", 40, 12, PI / 2, 1.2, 14, "camera high above, looking down (pitch 1.2)"),
        ("close_dist5_east_rim", 46, 36, PI / 2, 0.3, 5, "camera close behind you (5 yd) on the east rim by the steps"),
        ("far_dist30_pit", 30, 50, PI / 2, 0.3, 30, "camera far back (30 yd) over the walkway, looking at the boss and the north wall"),
        ("nw_statue", 15, 44, 3 * PI / 4, 0.3, 14, "facing the north-west statue up close"),
        ("past_east_pillar", 34.5, 12, PI / 2, 0.3, 14, "the east pillar right ahead, hiding part of the walkway and the pit"),
        ("facing_south_wall", 10, 4, -PI / 2, 0.3, 14, "the south wall right in front of you, the camera 14 yd back inside the hall"),
    ],
    "vashj": [
        ("platform_north", 105, 112, PI / 2, 0.3, 14, "on Vashj's platform looking out north across the ring and down the steps"),
        ("bottom_up_platform", 105, 22, PI / 2, 0.3, 8, "at the bottom ring looking up the steps at the platform (8 yd back)"),
        ("bottom_cam_behind_wall", 105, 18, PI / 2, 0.3, 14, "at the bottom ring, the camera 14 yd back: behind the room's wall"),
        ("next_to_generator", "gen1", None, None, 0.3, 14, "3 yd out from a shield generator, facing it and the platform"),
        ("ring_east_steps", 150, 105, 0, 0.3, 14, "on the east steps looking east down to the bottom"),
        ("overhead_pitch_12", 105, 70, PI / 2, 1.2, 14, "camera high above the ring, looking down (pitch 1.2)"),
        ("far_dist30", 105, 60, PI / 2, 0.3, 30, "camera far back (30 yd) looking north at the platform"),
        ("grazing_pitch_005", 70, 105, 0, 0.05, 14, "camera almost level (pitch 0.05) across the platform"),
        ("close_dist5_edge", 125, 105, 0, 0.3, 5, "camera close behind you (5 yd) at the platform's east edge"),
        ("sw_pipe", 55, 70, -3 * PI / 4, 0.3, 14, "facing the pipe / wall piece in the south-west"),
        ("facing_south_wall", 105, 20, -PI / 2, 0.3, 14, "the room's wall right in front at the bottom, the camera up on the steps"),
        ("ring_south_pitch_08", 105, 140, -PI / 2, 0.8, 14, "north ring looking south over the platform (pitch 0.8)"),
    ],
}
QUICK_POSES = {"teron": ["open_floor_north", "behind_west_pillar", "pit_up_west_steps", "grazing_pitch_005"],
               "vashj": ["platform_north", "bottom_up_platform", "next_to_generator", "grazing_pitch_005"]}
# x, y, facing, pitch, dist, frames, step (yd), turn per frame after `turnAfter` frames
WALKS = {
    "teron": dict(x=24, y=6, facing=PI / 2, pitch=0.3, dist=14, frames=30, step=0.25, turn=0.02, turnAfter=20,
                  note="from the entrance north towards the west pillar, 0.25 yd a frame, a slow left turn at the end"),
    "vashj": dict(x=105, y=60, facing=PI / 2, pitch=0.3, dist=14, frames=30, step=0.25, turn=0.02, turnAfter=20,
                  note="up the ring towards the platform, 0.25 yd a frame, a slow left turn at the end"),
}
# the camera stands still while a raider walks a straight line behind something (the occlusion pass re-runs every
# third frame while the view stands still): player x, y, facing, pitch, dist; which raider; path from / to; frames
ACTOR_WALKS = {
    "teron": dict(player=(25.5, 8, PI / 2), pitch=0.3, dist=14, raider=1, path=((19.0, 24.0), (32.0, 24.0)), frames=27,
                  note="the camera stands still south of the west pillar; a raider walks west to east right behind it"),
    "vashj": dict(player=(105, 150, PI / 2), pitch=0.3, dist=14, raider=1, path=((92.0, 186.0), (118.0, 186.0)),
                  frames=27, note="the camera stands still on the north ring; a raider walks along the bottom below the steps"),
}
ENC_DIFF = {"teron": "quick", "vashj": "looter"}
API_KEYS = ("SetVertexOffset", "SetPoint", "ClearAllPoints", "SetTexCoord", "SetTexture", "SetParent", "SetDrawLayer",
            "SetFrameLevel", "Show", "Hide", "CreateTexture", "CreateLine")


# ---------------------------------------------------------------------------------------------------------------
# the camera: exactly the mock ModelScene's Project3DPointTo2D (tools/wowmock/objects.lua)
# ---------------------------------------------------------------------------------------------------------------
class Camera:
    """pos, ypr (None = never set), fov (horizontal), near clip, the scene's rectangle in the view (l, b, w, h) and its
    width / height. project() returns view units (the scene's bottom-left + the mock's pixels / effective scale)."""

    def __init__(self, pos, ypr, fov, near, rect, W, H):
        self.C = np.asarray(pos, float)
        self.ypr = ypr
        self.legacy = ypr is None or (ypr[0] == math.pi and ypr[1] == 0 and ypr[2] == 0)
        if self.legacy:
            F, R, U = (-1.0, 0.0, 0.0), (0.0, -1.0, 0.0), (0.0, 0.0, 1.0)
        else:
            yaw, pitch, roll = ypr
            cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
            F = (cp * cy, cp * sy, -sp)
            R = (-sy, cy, 0.0)
            U = (sp * cy, sp * sy, cp)
            if roll:
                cr, sr = math.cos(roll), math.sin(roll)
                R, U = (tuple(cr * r + sr * u for r, u in zip(R, U)), tuple(cr * u - sr * r for r, u in zip(R, U)))
        self.F, self.R, self.U = np.array(F), np.array(R), np.array(U)
        self.W, self.H = float(W), float(H)
        self.f = (self.W / 2) / math.tan(fov / 2)
        self.cx = rect[0] + self.W / 2
        self.cy = rect[1] + self.H / 2
        self.near = near if near and near > 0 else 0.1

    def to_cam(self, P):
        D = np.asarray(P, float) - self.C
        return D @ self.R, D @ self.U, D @ self.F

    def project(self, P):
        r, u, d = self.to_cam(P)
        with np.errstate(divide="ignore", invalid="ignore"):
            return self.cx + self.f * r / d, self.cy + self.f * u / d, d


# ---------------------------------------------------------------------------------------------------------------
# capture parsing
# ---------------------------------------------------------------------------------------------------------------
class Capture:
    """One frame of the view as the API calls left it (see render_check.lua for the record layout)."""

    def __init__(self, text, view_w, view_h):
        self.view_w, self.view_h = float(view_w), float(view_h)
        self.frames = {}
        rows, actors = [], []
        self.player = None
        for line in text.split("\n"):
            if not line:
                continue
            tag, rest = line[0], line[2:]
            if tag == "R":
                rows.append(rest)
            elif tag == "F":
                v = rest.split()
                i = int(v[0])
                self.frames[i] = dict(parent=int(v[1]), level=int(v[2]), strata=int(v[3]), clips=v[4] == "1",
                                      visible=v[5] == "1", kind=int(v[6]), seq=int(v[7]),
                                      rect=tuple(float(x) for x in v[8:12]))
            elif tag == "A":
                v = rest.split()
                actors.append(dict(index=int(v[0]), unit=int(float(v[1])), pos=(float(v[2]), float(v[3]), float(v[4])),
                                   scale=float(v[5]), alpha=float(v[6]), height=float(v[7]), width=float(v[8]),
                                   kind=int(v[9])))
            elif tag == "C":
                v = [float(x) for x in rest.split()]
                self.cam_raw = v
            elif tag == "P":
                self.player = tuple(float(x) for x in rest.split())
        self.regions = (np.array(" ".join(rows).split(), dtype=float).reshape(-1, NF) if rows
                        else np.zeros((0, NF)))
        self.actors = actors
        v = self.cam_raw
        ypr = None if math.isnan(v[3]) else (v[3], v[4], v[5])
        rect = (0.0 if math.isnan(v[8]) else v[8], 0.0 if math.isnan(v[9]) else v[9])
        self.cam = Camera((v[0], v[1], v[2]), ypr, v[6], v[7], rect, v[12], v[13])
        self.mirror = v[15]
        self.scene_frame = next((i for i, f in self.frames.items() if f["kind"] == 2), None)


# ---------------------------------------------------------------------------------------------------------------
# rasterization core
# ---------------------------------------------------------------------------------------------------------------
class Grid:
    def __init__(self, Wp, Hp):
        self.Wp, self.Hp = Wp, Hp
        self.xs = np.arange(Wp, dtype=float) + 0.5
        self.ys = (np.arange(Hp, dtype=float) + 0.5)[:, None]


def _owns(ax, ay, bx, by):
    """Top-left style fill rule: of the two directions an edge can be walked in, exactly one owns pixel centres
    lying exactly on it (so neighbouring triangles never both draw an edge pixel)."""
    return by < ay or (by == ay and bx < ax)


def tri_pixels(g, x0, y0, x1, y1, x2, y2, clip=None):
    """Pixels whose centre lies inside triangle (pixel coordinates, y up). -> (r0, c0, mask, l0, l1, l2) with the
    screen-linear barycentric weights over the bounding box, or None."""
    area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if not abs(area) > 1e-9:
        return None
    flip = area < 0
    if flip:
        x1, y1, x2, y2 = x2, y2, x1, y1
        area = -area
    cl = (0, 0, g.Wp - 1, g.Hp - 1) if clip is None else clip
    c0 = max(int(math.ceil(min(x0, x1, x2) - 0.5)), cl[0])
    c1 = min(int(math.floor(max(x0, x1, x2) - 0.5)), cl[2])
    r0 = max(int(math.ceil(min(y0, y1, y2) - 0.5)), cl[1])
    r1 = min(int(math.floor(max(y0, y1, y2) - 0.5)), cl[3])
    if c0 > c1 or r0 > r1:
        return None
    px = g.xs[c0:c1 + 1]
    py = g.ys[r0:r1 + 1]
    e0 = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
    e1 = (x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)
    e2 = (x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)
    m = (e0 >= 0) if _owns(x1, y1, x2, y2) else (e0 > 0)
    m &= (e1 >= 0) if _owns(x2, y2, x0, y0) else (e1 > 0)
    m &= (e2 >= 0) if _owns(x0, y0, x1, y1) else (e2 > 0)
    if not m.any():
        return None
    l0, l1, l2 = e0 / area, e1 / area, e2 / area
    if flip:
        l1, l2 = l2, l1
    return r0, c0, m, l0, l1, l2


def affine_coefs(xy, vals):
    """Coefficients c (3, k) with [x, y, 1] @ c = vals for the 3 points xy (3, 2); None if degenerate."""
    M = np.array([[xy[0][0], xy[0][1], 1.0], [xy[1][0], xy[1][1], 1.0], [xy[2][0], xy[2][1], 1.0]])
    if not abs(np.linalg.det(M)) > 1e-9:
        return None
    return np.linalg.solve(M, np.asarray(vals, float))


# ---------------------------------------------------------------------------------------------------------------
# the room mesh
# ---------------------------------------------------------------------------------------------------------------
class Mesh:
    def __init__(self, V, T, textures):
        self.V = np.asarray(V, float).reshape(-1, 6)
        T = np.asarray(T, int).reshape(-1, 4)
        self.tri = T[:, :3] - 1
        self.textures = list(int(t) for t in textures)
        self.tex_index = T[:, 3] - 1
        self.file = np.array(self.textures)[self.tex_index]
        self.nt = len(self.tri)
        P = self.V[:, :3]
        a, b, c = P[self.tri[:, 0]], P[self.tri[:, 1]], P[self.tri[:, 2]]
        self.normal = np.cross(b - a, c - a)
        self.a = a
        self.corners = np.stack([a, b, c], axis=1)                     # (nt, 3, 3) arena
        self.light = self.V[self.tri, 5].mean(axis=1)
        uv = self.V[self.tri][:, :, 3:5]                                # (nt, 3, 2)
        self.uv = uv
        M = np.ones((self.nt, 3, 3))
        M[:, 0, :] = uv[:, :, 0]
        M[:, 1, :] = uv[:, :, 1]
        det = np.linalg.det(M)
        self.uv_ok = np.abs(det) > 1e-8
        self.binv = np.zeros((self.nt, 3, 3))
        self.binv[self.uv_ok] = np.linalg.inv(M[self.uv_ok])           # barycentric = binv @ [u, v, 1]
        self.room_files = set(self.textures)

    @classmethod
    def from_text(cls, text):
        v, t, x = text.split("|")
        return cls(np.array(v.split(), float), np.array(t.split(), int), x.split())


# ---------------------------------------------------------------------------------------------------------------
# the truth: z-buffer, perspective-correct, near plane clipped, back faces culled
# ---------------------------------------------------------------------------------------------------------------
class Truth:
    pass


def _clip_near(verts, near):
    """Sutherland-Hodgman against depth >= near. verts: list of (r, u, d, tu, tv)."""
    out = []
    n = len(verts)
    for i in range(n):
        a, b = verts[i], verts[(i + 1) % n]
        ina, inb = a[2] >= near, b[2] >= near
        if ina:
            out.append(a)
        if ina != inb:
            t = (near - a[2]) / (b[2] - a[2])
            out.append(tuple(a[k] + (b[k] - a[k]) * t for k in range(5)))
    return out


FEET = 0.15                  # yd: billboards start this far above the actor's position (feet that stand on the
                             # floor, or a hair under it - the sim's height grid lies up to ~0.1 yd under the mesh -
                             # are not occlusion errors)


def billboard_tris(actors, cam):
    """Each actor as an upright rectangle facing the camera: -> list of (actor index, 3 scene points) x 2."""
    rh = np.array([cam.R[0], cam.R[1], 0.0])
    n = np.linalg.norm(rh)
    rh = rh / n if n > 1e-9 else np.array([0.0, 1.0, 0.0])
    out = []
    for k, a in enumerate(actors):
        if a["kind"] != 1 or a["height"] <= FEET:
            continue
        p = np.array(a["pos"]) + np.array([0.0, 0.0, FEET])
        hw = rh * a["width"] / 2
        up = np.array([0, 0, a["height"] - FEET])
        bl, br, tl, tr = p - hw, p + hw, p - hw + up, p + hw + up
        out.append((k, (bl, br, tr)))
        out.append((k, (bl, tr, tl)))
    return out


def _raster_depth(g, polys, zb, idb, S):
    """polys: list of (id, [(x, y, invd) ...] pixel coords). z-test on 1/depth (bigger = nearer)."""
    for pid, pts in polys:
        for k in range(1, len(pts) - 1):
            p0, p1, p2 = pts[0], pts[k], pts[k + 1]
            res = tri_pixels(g, p0[0], p0[1], p1[0], p1[1], p2[0], p2[1])
            if res is None:
                continue
            r0, c0, m, l0, l1, l2 = res
            iv = l0 * p0[2] + l1 * p1[2] + l2 * p2[2]
            hh, ww = m.shape
            zv = zb[r0:r0 + hh, c0:c0 + ww]
            iw = idb[r0:r0 + hh, c0:c0 + ww]
            m = m & (iv > zv)
            zv[m] = iv[m]
            iw[m] = pid


def _tri_polys(mesh, sel, r, u, d, cam, g, S):
    """Screen polygons (pixels; near plane clipped) of the triangles in sel: {t: [(x, y, 1/d, u/d, v/d), ...]}."""
    near = cam.near
    dv = d[mesh.tri]
    with np.errstate(divide="ignore", invalid="ignore"):
        sx = (cam.cx + cam.f * r / d) * S
        sy = (cam.cy + cam.f * u / d) * S
        invd = 1.0 / d
    tx, ty = sx[mesh.tri], sy[mesh.tri]
    off = (tx.max(1) < 0) | (tx.min(1) > g.Wp) | (ty.max(1) < 0) | (ty.min(1) > g.Hp)
    cand = sel & (dv.max(axis=1) > near)
    allin = cand & (dv.min(axis=1) >= near)
    out = {}
    for t in np.nonzero(allin & ~off)[0]:
        out[int(t)] = [(sx[i], sy[i], invd[i], mesh.V[i, 3] * invd[i], mesh.V[i, 4] * invd[i]) for i in mesh.tri[t]]
    for t in np.nonzero(cand & ~allin)[0]:
        cv = _clip_near([(r[i], u[i], d[i], mesh.V[i, 3], mesh.V[i, 4]) for i in mesh.tri[t]], near)
        if len(cv) < 3:
            continue
        pts = [((cam.cx + cam.f * q[0] / q[2]) * S, (cam.cy + cam.f * q[1] / q[2]) * S, 1.0 / q[2],
                q[3] / q[2], q[4] / q[2]) for q in cv]
        xs_, ys_ = [p[0] for p in pts], [p[1] for p in pts]
        if max(xs_) < 0 or min(xs_) > g.Wp or max(ys_) < 0 or min(ys_) > g.Hp:
            continue
        out[int(t)] = pts
    return out


def render_truth(mesh, cap, g, S, backfaces=False):
    cam, mirror = cap.cam, cap.mirror
    near = cam.near
    P = mesh.V[:, :3] * np.array([1.0, mirror, 1.0])
    r, u, d = cam.to_cam(P)
    eye = np.array([cam.C[0], mirror * cam.C[1], cam.C[2]])
    front = np.einsum("ij,ij->i", mesh.normal, eye - mesh.a) > 0
    tr = Truth()
    tr.poly = _tri_polys(mesh, front, r, u, d, cam, g, S)   # triangle -> clipped polygon (pixels)
    zb = np.zeros((g.Hp, g.Wp))
    idb = np.full((g.Hp, g.Wp), -1, dtype=np.int32)
    _raster_depth(g, list(tr.poly.items()), zb, idb, S)
    tr.seethrough = None
    if backfaces:
        # a back face nearer than anything facing the camera: the camera looks out from behind / inside geometry
        zbb = np.zeros((g.Hp, g.Wp))
        idbb = np.full((g.Hp, g.Wp), -1, dtype=np.int32)
        _raster_depth(g, list(_tri_polys(mesh, ~front, r, u, d, cam, g, S).items()), zbb, idbb, S)
        tr.seethrough = zbb > zb
    # perspective-correct texture coordinates from each triangle's plane: 1/d, u/d, v/d are affine on screen
    coef = np.zeros((mesh.nt, 3, 3))
    have = np.zeros(mesh.nt, bool)
    for t, pts in tr.poly.items():
        c = affine_coefs([(p[0], p[1]) for p in pts[:3]], [[p[2], p[3], p[4]] for p in pts[:3]])
        if c is not None:
            coef[t] = c
            have[t] = True
    tr.id = idb
    tr.invd = zb
    tr.uv = np.full((g.Hp, g.Wp, 2), np.nan)
    rr, cc = np.nonzero(idb >= 0)
    if len(rr):
        t = idb[rr, cc]
        X = np.stack([g.xs[cc], g.ys[rr, 0], np.ones(len(rr))], axis=1)
        vals = np.einsum("ni,nij->nj", X, coef[t])
        with np.errstate(divide="ignore", invalid="ignore"):
            tr.uv[rr, cc, 0] = vals[:, 1] / vals[:, 0]
            tr.uv[rr, cc, 1] = vals[:, 2] / vals[:, 0]
    # with the actors: their billboards depth tested against the room
    tr.actor_polys = []
    for k, pts3 in billboard_tris(cap.actors, cam):
        cr, cu, cd = cam.to_cam(np.array(pts3))
        cv = _clip_near([(cr[i], cu[i], cd[i], 0.0, 0.0) for i in range(3)], near)
        if len(cv) < 3:
            continue
        pts = [((cam.cx + cam.f * q[0] / q[2]) * S, (cam.cy + cam.f * q[1] / q[2]) * S, 1.0 / q[2]) for q in cv]
        tr.actor_polys.append((k, pts))
    zfull = zb.copy()
    idfull = idb.copy()
    _raster_depth(g, [(mesh.nt + k, pts) for k, pts in tr.actor_polys], zfull, idfull, S)
    tr.actor_visible = idfull >= mesh.nt
    # the actors among themselves (what the ModelScene draws): nearest actor per pixel
    za = np.zeros((g.Hp, g.Wp))
    ida = np.full((g.Hp, g.Wp), -1, dtype=np.int32)
    _raster_depth(g, tr.actor_polys, za, ida, S)
    tr.actor_only = ida
    return tr


# ---------------------------------------------------------------------------------------------------------------
# which mesh triangle a painted region shows: from its own API data only
# ---------------------------------------------------------------------------------------------------------------
MATCH_TOL = 1.0              # view units: a region is a piece of triangle T when its corners sit within this of T


def match_regions(mesh, cap, rows_idx):
    """For the room regions rows_idx: the mesh triangle each one is a correctly placed piece of, or -1. A region is a
    piece of T when its texture file is T's, its three corner texture coordinates (UL, LL, UR) lie inside T's texture
    triangle and the points of T they stand for, projected through the camera, land on the region's corners (within
    MATCH_TOL). -> (src array aligned with rows_idx, corner error)."""
    R = cap.regions
    n = len(rows_idx)
    src = np.full(n, -1, dtype=np.int64)
    err = np.full(n, np.inf)
    if n == 0:
        return src, err
    rows = R[rows_idx]
    l, b, w, h = rows[:, 18], rows[:, 19], rows[:, 20], rows[:, 21]
    o = rows[:, 22:30]
    sc = np.stack([np.stack([l + o[:, 0], b + h + o[:, 1]], 1),           # UL
                   np.stack([l + o[:, 2], b + o[:, 3]], 1),               # LL
                   np.stack([l + w + o[:, 4], b + h + o[:, 5]], 1)], 1)   # UR      (n, 3, 2)
    tc = np.stack([rows[:, 10:12], rows[:, 12:14], rows[:, 14:16]], 1)      # (n, 3, 2)
    files = rows[:, 5].astype(np.int64)
    uvmin_t, uvmax_t = mesh.uv.min(axis=1), mesh.uv.max(axis=1)
    eps = 1e-3
    mirror = np.array([1.0, cap.mirror, 1.0])
    for f in np.unique(files):
        ri = np.nonzero(files == f)[0]
        ti = np.nonzero((mesh.file == f) & mesh.uv_ok)[0]
        if len(ti) == 0:
            continue
        rmin, rmax = tc[ri].min(axis=1), tc[ri].max(axis=1)
        for c0 in range(0, len(ri), 512):                                   # (bounded memory)
            rs = ri[c0:c0 + 512]
            cont = ((uvmin_t[ti][None, :, :] <= rmin[c0:c0 + 512][:, None, :] + eps).all(-1) &
                    (uvmax_t[ti][None, :, :] >= rmax[c0:c0 + 512][:, None, :] - eps).all(-1))
            pr, pc = np.nonzero(cont)
            if len(pr) == 0:
                continue
            rr, tt = rs[pr], ti[pc]
            X = np.concatenate([tc[rr], np.ones((len(rr), 3, 1))], axis=2)      # (m, 3, 3) corner [u, v, 1]
            beta = np.einsum("mij,mkj->mki", mesh.binv[tt], X)                  # (m, 3 corners, 3)
            inside = (beta >= -eps).all(axis=(1, 2))
            if not inside.any():
                continue
            rr, tt, beta = rr[inside], tt[inside], beta[inside]
            Q = np.einsum("mki,mij->mkj", beta, mesh.corners[tt]) * mirror      # (m, 3, 3) scene points
            qx, qy, qd = cap.cam.project(Q.reshape(-1, 3))
            qx, qy, qd = qx.reshape(-1, 3), qy.reshape(-1, 3), qd.reshape(-1, 3)
            e = np.hypot(qx - sc[rr, :, 0], qy - sc[rr, :, 1]).max(axis=1)
            e[(qd <= 0).any(axis=1) | np.isnan(e)] = np.inf
            order = np.lexsort((e, rr))                                       # per region, the smallest error
            rr, e, tt = rr[order], e[order], tt[order]
            first = np.ones(len(rr), bool)
            first[1:] = rr[1:] != rr[:-1]
            rr, e, tt = rr[first], e[first], tt[first]
            better = e < err[rr]
            err[rr[better]] = e[better]
            src[rr[better]] = tt[better]
    src[err > MATCH_TOL] = -1
    return src, err


# ---------------------------------------------------------------------------------------------------------------
# the painter: what WoW draws from the recorded widget state
# ---------------------------------------------------------------------------------------------------------------
class Painter:
    pass


def _clip_rect(cap, fid, S, g):
    """Pixel bounds (c0, r0, c1, r1) of the frames with SetClipsChildren above (and at) a region's frame."""
    c0, r0, c1, r1 = 0, 0, g.Wp - 1, g.Hp - 1
    f = cap.frames.get(fid)
    while f is not None:
        if f["clips"]:
            l, b, w, h = f["rect"]
            if not any(math.isnan(v) for v in (l, b, w, h)):
                c0 = max(c0, int(math.ceil(l * S - 0.5)))
                r0 = max(r0, int(math.ceil(b * S - 0.5)))
                c1 = min(c1, int(math.floor((l + w) * S - 0.5)))
                r1 = min(r1, int(math.floor((b + h) * S - 0.5)))
        f = cap.frames.get(f["parent"])
    return c0, r0, c1, r1


def region_quad(row):
    """-> corners UL, LL, UR, LR (view units) and their texture coordinates, from rect + vertex offsets."""
    l, b, w, h = row[18:22]
    o = row[22:30]
    ul = (l + o[0], b + h + o[1])
    ll = (l + o[2], b + o[3])
    ur = (l + w + o[4], b + h + o[5])
    lr = (l + w + o[6], b + o[7])
    tc = row[10:18]
    return (ul, ll, ur, lr), ((tc[0], tc[1]), (tc[2], tc[3]), (tc[4], tc[5]), (tc[6], tc[7]))


def render_painter(mesh, cap, tr, g, S):
    R = cap.regions
    pt = Painter()
    pt.room_top = np.full((g.Hp, g.Wp), -1, dtype=np.int32)      # room-only image: triangle id (2 * region + k)
    pt.kind = np.zeros((g.Hp, g.Wp), dtype=np.int8)              # full image: 0 none, 1 room, 2 actor, 3 line
    pt.full_top = np.full((g.Hp, g.Wp), -1, dtype=np.int32)      # room triangle id / actor index / line region
    pt.amb = np.zeros((g.Hp, g.Wp), dtype=bool)                  # ties that involve the room or the actors
    pt.amb_lines = np.zeros((g.Hp, g.Wp), dtype=bool)            # ties between lines only (one mark's segments)
    pt.above_scene = np.zeros((g.Hp, g.Wp), dtype=bool)          # the room pixel was drawn above the ModelScene
    own = np.full((g.Hp, g.Wp), -1, dtype=np.int64)              # entry painted last (for ties)
    own_kind = np.zeros((g.Hp, g.Wp), dtype=np.int8)             # its kind: 1 room, 2 scene, 3 line
    fkey = np.full((g.Hp, g.Wp), -1, dtype=np.int64)             # its frame's strata / level
    fid_ = np.full((g.Hp, g.Wp), -1, dtype=np.int64)             # its frame
    lsk = np.full((g.Hp, g.Wp), -1, dtype=np.int64)              # its layer / sublevel
    entries = []
    for i, row in enumerate(R):
        if row[35] <= 0.001:                                     # alpha 0
            continue
        f = cap.frames.get(int(row[2]))
        if f is None or not f["visible"]:
            continue
        kind = int(row[0])
        if kind == 1:
            what = "room" if (row[5] >= 0 and int(row[5]) in mesh.room_files) else "other"
        else:
            what = "line"
        entries.append(((f["strata"], f["level"], f["seq"], int(row[3]), int(row[4]), int(row[1])), what, i, int(row[2])))
    if cap.scene_frame is not None:
        f = cap.frames[cap.scene_frame]
        if f["visible"]:
            entries.append(((f["strata"], f["level"], f["seq"], 2, 0, 1 << 40), "scene", -1, cap.scene_frame))
    entries.sort(key=lambda e: e[0])
    room_rows = np.array([e[2] for e in entries if e[1] == "room" and not np.isnan(R[e[2], 18:22]).any()],
                         dtype=np.int64)
    src, serr = match_regions(mesh, cap, room_rows)
    pt.region_src = dict(zip(room_rows.tolist(), src.tolist()))   # region -> mesh triangle it shows (-1: none)
    pt.matched = int((src >= 0).sum())
    pt.unmatched = int((src < 0).sum())
    pt.painted_truth = np.zeros((g.Hp, g.Wp), dtype=bool)        # the truth's triangle was painted here at some point
    pt.uvc = {}                                                  # room triangle id -> affine uv coefficients
    pt.file_of = {}
    pt.light_of = {}
    pt.region_tri_count = 0
    pt.diag_sensitive = 0
    pt.shown_room = 0
    pt.lines = 0
    scene_key = None
    if cap.scene_frame is not None:
        sf = cap.frames[cap.scene_frame]
        scene_key = (sf["strata"], sf["level"])
    for n, (key, what, i, fidx) in enumerate(entries):
        if what == "other":
            continue
        fk = key[0] * 1000000 + key[1]
        ls = key[3] * 100 + key[4] + 8
        clip = _clip_rect(cap, fidx, S, g)
        above = scene_key is not None and (key[0], key[1]) > scene_key
        my_kind = {"room": 1, "scene": 2, "line": 3}[what]

        def stamp(r0, c0, m, value, room, src_tri=-1):
            hh, ww = m.shape
            sl = (slice(r0, r0 + hh), slice(c0, c0 + ww))
            o, ok_, fk_, fi_, ls_ = own[sl], own_kind[sl], fkey[sl], fid_[sl], lsk[sl]
            tie = (o >= 0) & (o != n) & (fk_ == fk) & ((fi_ != fidx) | (ls_ == ls))
            lines_only = (ok_ == 3) & (my_kind == 3)
            pt.amb[sl][m] = (tie & ~lines_only)[m]
            pt.amb_lines[sl][m] = (tie & lines_only)[m]
            o[m], ok_[m], fk_[m], fi_[m], ls_[m] = n, my_kind, fk, fidx, ls
            if room:
                pt.room_top[sl][m] = value
                pt.above_scene[sl][m] = above
                pt.kind[sl][m] = 1
                pt.full_top[sl][m] = value
                if src_tri >= 0:
                    pt.painted_truth[sl][m & (tr.id[sl] == src_tri)] = True
            else:
                pt.kind[sl][m] = 3 if what == "line" else 2
                pt.full_top[sl][m] = value

        if what == "room":
            row = R[i]
            if any(math.isnan(v) for v in row[18:22]):
                continue
            pt.shown_room += 1
            (ul, ll, ur, lr), (tul, tll, tur, tlr) = region_quad(row)
            tris = ((ul, ll, ur, tul, tll, tur), (ll, lr, ur, tll, tlr, tur))
            corners = [ul, ll, ur, lr]
            distinct = all(math.hypot(corners[a][0] - corners[b][0], corners[a][1] - corners[b][1]) > 1e-6
                           for a in range(4) for b in range(a + 1, 4))
            cA = affine_coefs([(p[0] * S, p[1] * S) for p in (ul, ll, ur)], [tul, tll, tur])
            if distinct and cA is not None:
                pred = np.array([lr[0] * S, lr[1] * S, 1.0]) @ cA
                if abs(pred[0] - tlr[0]) > 1e-6 or abs(pred[1] - tlr[1]) > 1e-6:
                    pt.diag_sensitive += 1
            for k, (p0, p1, p2, t0, t1, t2) in enumerate(tris):
                xy = [(p0[0] * S, p0[1] * S), (p1[0] * S, p1[1] * S), (p2[0] * S, p2[1] * S)]
                res = tri_pixels(g, xy[0][0], xy[0][1], xy[1][0], xy[1][1], xy[2][0], xy[2][1], clip)
                if res is None:
                    continue
                c = affine_coefs(xy, [t0, t1, t2])
                if c is None:
                    continue
                tid = 2 * i + k
                pt.uvc[tid] = c
                pt.file_of[tid] = int(row[5])
                pt.light_of[tid] = float(row[6])
                pt.region_tri_count += 1
                r0, c0, m, _, _, _ = res
                stamp(r0, c0, m, tid, True, pt.region_src.get(i, -1))
        elif what == "line":
            row = R[i]
            x1, y1, x2, y2 = row[18:22]
            if any(math.isnan(v) for v in (x1, y1, x2, y2)):
                continue
            pt.lines += 1
            dx, dy = (x2 - x1), (y2 - y1)
            ln = math.hypot(dx, dy)
            if ln < 1e-9:
                continue
            th = max(row[30], 0.5) / 2
            nx, ny = -dy / ln * th, dx / ln * th
            q = [((x1 + nx) * S, (y1 + ny) * S), ((x1 - nx) * S, (y1 - ny) * S),
                 ((x2 - nx) * S, (y2 - ny) * S), ((x2 + nx) * S, (y2 + ny) * S)]
            for a, b, c in ((0, 1, 2), (0, 2, 3)):
                res = tri_pixels(g, q[a][0], q[a][1], q[b][0], q[b][1], q[c][0], q[c][1], clip)
                if res is not None:
                    r0, c0, m, _, _, _ = res
                    stamp(r0, c0, m, i, False)
        elif what == "scene":
            ida = tr.actor_only
            m = ida >= 0
            c0, r0, c1, r1 = clip
            cm = np.zeros_like(m)
            cm[r0:r1 + 1, c0:c1 + 1] = True
            m &= cm
            if m.any():
                rr, cc = np.nonzero(m)
                rmin, cmin = rr.min(), cc.min()
                sub = np.zeros((rr.max() - rmin + 1, cc.max() - cmin + 1), bool)
                sub[rr - rmin, cc - cmin] = True
                stamp(rmin, cmin, sub, -1, False)
                pt.full_top[m] = ida[m]
    # room-only texture coordinates and files
    pt.uv = np.full((g.Hp, g.Wp, 2), np.nan)
    pt.file = np.full((g.Hp, g.Wp), -9, dtype=np.int64)
    pt.light = np.ones((g.Hp, g.Wp))
    rr, cc = np.nonzero(pt.room_top >= 0)
    if len(rr):
        ids = pt.room_top[rr, cc]
        uniq, inv = np.unique(ids, return_inverse=True)
        C = np.stack([pt.uvc[int(t)] for t in uniq])
        X = np.stack([g.xs[cc], g.ys[rr, 0], np.ones(len(rr))], axis=1)
        uv = np.einsum("ni,nij->nj", X, C[inv])
        pt.uv[rr, cc] = uv
        pt.file[rr, cc] = np.array([pt.file_of[int(t)] for t in uniq])[inv]
        pt.light[rr, cc] = np.array([pt.light_of[int(t)] for t in uniq])[inv]
    return pt


# ---------------------------------------------------------------------------------------------------------------
# metrics
# ---------------------------------------------------------------------------------------------------------------
NEIGHBOURS = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]


def _surface_test(mesh, cam, mirror, S, tri, uvp, filep, px, py, inside_test=True):
    """For pixels (px, py pixel centres) showing (filep, uvp) in the painter, against candidate truth triangles tri:
    -> ok (right surface), misplacement (view units, nan if not measurable), misplacement vector (2,). The texel's
    point on the triangle (its texture coordinate mapped back through it) is projected through the camera; the
    misplacement is how far that lands from the pixel."""
    n = len(tri)
    ok = np.zeros(n, bool)
    mis = np.full(n, np.nan)
    vec = np.full((n, 2), np.nan)
    valid = tri >= 0
    t = np.where(valid, tri, 0)
    valid &= mesh.file[t] == filep
    deg = valid & ~mesh.uv_ok[t]
    ok |= deg
    test = valid & mesh.uv_ok[t]
    if test.any():
        idx = np.nonzero(test)[0]
        tt = t[idx]
        X = np.stack([uvp[idx, 0], uvp[idx, 1], np.ones(len(idx))], axis=1)
        beta = np.einsum("nij,nj->ni", mesh.binv[tt], X)
        inside = (beta >= -RIGHT_EPS).all(axis=1) if inside_test else np.ones(len(idx), bool)
        Q = np.einsum("ni,nij->nj", beta, mesh.corners[tt]) * np.array([1.0, mirror, 1.0])
        qx, qy, qd = cam.project(Q)
        good = inside & (qd > cam.near * 0.999)
        dx = qx * S - px[idx]
        dy = qy * S - py[idx]
        ok[idx[good]] = True
        mis[idx[good]] = np.hypot(dx[good], dy[good]) / S
        vec[idx[good], 0] = dx[good] / S
        vec[idx[good], 1] = dy[good] / S
    return ok, mis, vec


class Result(dict):
    pass


RIGHT, WRONG_OVER, HOLE, EXTRA, WRONG_MISSING, WRONG_UNMATCHED = 1, 2, 3, 4, 5, 6


def _neighbour_ids(tr, g, rr, cc, dr, dc):
    r2, c2 = rr + dr, cc + dc
    inb = (r2 >= 0) & (r2 < g.Hp) & (c2 >= 0) & (c2 < g.Wp)
    tri = np.full(len(rr), -1, dtype=np.int64)
    tri[inb] = tr.id[r2[inb], c2[inb]]
    return tri


def compare(mesh, cap, tr, pt, g, S):
    """Classify every pixel. Where the painter's top region is a matched piece of mesh triangle X: right when X is the
    truth's triangle there or at one of the 8 neighbours; otherwise wrong, either PAINTED OVER (the truth's triangle
    was drawn here and something else was drawn over it later: an order error) or MISSING (the truth's triangle was
    never drawn here, so what lies behind it shows). Unmatched regions (corners that are not where their texture
    coordinates say) fall back to the texture rule: same file and texel inside the truth triangle (or a neighbour's)."""
    D = tr.id >= 0
    P = pt.room_top >= 0
    both = D & P
    res = Result()
    res.cls = np.zeros((g.Hp, g.Wp), dtype=np.int8)
    res.mis = np.full((g.Hp, g.Wp), np.nan)
    res.vec = np.full((g.Hp, g.Wp, 2), np.nan)
    rr, cc = np.nonzero(both)
    n = len(rr)
    right = np.zeros(n, bool)
    mis = np.full(n, np.nan)
    vec = np.full((n, 2), np.nan)
    srcs = np.full(n, -1, dtype=np.int64)
    if n:
        uvp = pt.uv[rr, cc]
        filep = pt.file[rr, cc]
        px, py = g.xs[cc], g.ys[rr, 0]
        regs = pt.room_top[rr, cc] // 2
        lut = np.full(int(regs.max()) + 1, -1, dtype=np.int64)
        for reg, s in pt.region_src.items():
            if reg < len(lut):
                lut[reg] = s
        srcs = lut[regs]
        matched = srcs >= 0
        # matched regions: the triangle itself decides
        for dr, dc in [(0, 0)] + NEIGHBOURS:
            right |= matched & (_neighbour_ids(tr, g, rr, cc, dr, dc) == srcs)
        idx = np.nonzero(matched & right)[0]
        if len(idx):
            ok, m_, v_ = _surface_test(mesh, cap.cam, cap.mirror, S, srcs[idx], uvp[idx], filep[idx], px[idx], py[idx],
                                       inside_test=False)
            mis[idx], vec[idx] = m_, v_
        # unmatched regions: the texture rule against the truth triangle, then its neighbours
        best = np.full(n, np.inf)
        for k, (dr, dc) in enumerate([(0, 0)] + NEIGHBOURS):
            idx = np.nonzero(~matched & ~right)[0] if k else np.nonzero(~matched)[0]
            if not len(idx):
                break
            tri = _neighbour_ids(tr, g, rr[idx], cc[idx], dr, dc)
            ok, m_, v_ = _surface_test(mesh, cap.cam, cap.mirror, S, tri, uvp[idx], filep[idx], px[idx], py[idx])
            right[idx[ok]] = True
            sel = ~np.isnan(m_) & (m_ < best[idx])
            best[idx[sel]] = m_[sel]
            mis[idx[sel]] = m_[sel]
            vec[idx[sel]] = v_[sel]
    cls = res.cls
    cls[D & ~P] = HOLE
    cls[~D & P] = EXTRA
    if n:
        wrong = ~right
        painted = pt.painted_truth[rr, cc]
        cls[rr[right], cc[right]] = RIGHT
        w_over = wrong & (srcs >= 0) & painted
        w_miss = wrong & (srcs >= 0) & ~painted
        w_un = wrong & (srcs < 0)
        cls[rr[w_over], cc[w_over]] = WRONG_OVER
        cls[rr[w_miss], cc[w_miss]] = WRONG_MISSING
        cls[rr[w_un], cc[w_un]] = WRONG_UNMATCHED
        ms = right & ~np.isnan(mis)
        res.mis[rr[ms], cc[ms]] = mis[ms]
        res.vec[rr[ms], cc[ms]] = vec[ms]
    covered = int(D.sum())
    res.covered = covered
    pct = (lambda k: 100.0 * k / covered) if covered else (lambda k: 0.0)
    nw = int(np.isin(cls, (WRONG_OVER, WRONG_MISSING, WRONG_UNMATCHED)).sum())
    res["wrongSurfacePct"] = pct(nw)
    res["wrongPaintedOverPct"] = pct(int((cls == WRONG_OVER).sum()))
    res["wrongOverAboveScenePct"] = pct(int(((cls == WRONG_OVER) & pt.above_scene).sum()))
    res["wrongMissingPct"] = pct(int((cls == WRONG_MISSING).sum()))
    res["wrongUnmatchedPct"] = pct(int((cls == WRONG_UNMATCHED).sum()))
    res["holesPct"] = pct(int((cls == HOLE).sum()))
    res["extraPct"] = pct(int((cls == EXTRA).sum()))
    res["matchedRegions"] = pt.matched
    res["unmatchedRegions"] = pt.unmatched
    mv = res.mis[cls == 1]
    mv = mv[~np.isnan(mv)]
    res["misplacementP95px"] = float(np.percentile(mv, 95)) if len(mv) else 0.0
    res["misplacementP99px"] = float(np.percentile(mv, 99)) if len(mv) else 0.0
    res["misplacementMaxPx"] = float(mv.max()) if len(mv) else 0.0
    res["misplacementMeanPx"] = float(mv.mean()) if len(mv) else 0.0
    res["over5pxPct"] = pct(int((mv > 5).sum()))
    # actors: where their billboards are, is the actor visible in both?
    dom = tr.actor_only >= 0
    nd = int(dom.sum())
    pvis = pt.kind == 2
    err = dom & (pvis != tr.actor_visible)
    res.actor_err = err
    res["actorErrPct"] = 100.0 * int(err.sum()) / nd if nd else 0.0
    res["actorHiddenWronglyPct"] = 100.0 * int((dom & tr.actor_visible & ~pvis).sum()) / nd if nd else 0.0
    res["actorShownWronglyPct"] = 100.0 * int((dom & ~tr.actor_visible & pvis).sum()) / nd if nd else 0.0
    res["actorPx"] = nd
    res["ambiguousPct"] = pct(int(pt.amb.sum()))
    res["ambiguousLinesPct"] = pct(int(pt.amb_lines.sum()))
    res["shownTextures"] = int(pt.shown_room)
    res["diagonalSensitiveQuads"] = int(pt.diag_sensitive)
    res["truthCoveredPct"] = 100.0 * covered / (g.Wp * g.Hp)
    if tr.seethrough is not None:
        res["seeThroughPct"] = 100.0 * int(tr.seethrough.sum()) / (g.Wp * g.Hp)
    return res


FLICKER_CLASS = np.array([0, 1, 2, 3, 4, 2, 2], dtype=np.int8)     # right / wrong (any kind) / hole / extra


def stability(prev, cur):
    """Between two consecutive walk frames: (popMax, popP99, flickerPct)."""
    same = (prev["id"] >= 0) & (prev["id"] == cur["id"])
    both_right = same & (prev["cls"] == RIGHT) & (cur["cls"] == RIGHT)
    d = np.hypot(cur["vec"][..., 0] - prev["vec"][..., 0], cur["vec"][..., 1] - prev["vec"][..., 1])
    d = d[both_right & ~np.isnan(d)]
    pop_max = float(d.max()) if len(d) else 0.0
    pop99 = float(np.percentile(d, 99)) if len(d) else 0.0
    ns = int(same.sum())
    changed = FLICKER_CLASS[prev["cls"]] != FLICKER_CLASS[cur["cls"]]
    flick = 100.0 * int((same & changed).sum()) / ns if ns else 0.0
    return pop_max, pop99, flick


# ---------------------------------------------------------------------------------------------------------------
# pictures
# ---------------------------------------------------------------------------------------------------------------
PALETTE = np.array([
    (0.85, 0.55, 0.35), (0.45, 0.65, 0.85), (0.55, 0.80, 0.45), (0.85, 0.75, 0.40), (0.70, 0.50, 0.80),
    (0.40, 0.75, 0.75), (0.85, 0.45, 0.55), (0.60, 0.60, 0.60), (0.75, 0.65, 0.95), (0.95, 0.60, 0.25),
    (0.50, 0.85, 0.65), (0.65, 0.45, 0.35), (0.35, 0.50, 0.95), (0.90, 0.85, 0.65)])


def texel_rgb(mesh, files, uv, light):
    """A made-up texture per file (a hue, an 8 x 8 checker per texture unit, dark lines on the unit grid) so that
    stretching and sliding show; light = the vertex colour."""
    out = np.zeros(files.shape + (3,))
    tf = np.array(mesh.textures)
    order = np.argsort(tf)
    pos = np.clip(np.searchsorted(tf[order], files), 0, len(tf) - 1)
    fi = np.where(tf[order][pos] == files, order[pos], -1)
    ok = fi >= 0
    if not ok.any():
        return out
    u, v = uv[..., 0], uv[..., 1]
    cu, cv = u * 8, v * 8
    chk = (np.floor(cu) + np.floor(cv)) % 2
    base = PALETTE[np.where(ok, fi, 0) % len(PALETTE)] * (0.78 + 0.22 * chk)[..., None]
    fu, fv = u - np.floor(u), v - np.floor(v)
    major = (fu < 0.03) | (fv < 0.03)
    minor = ((cu - np.floor(cu)) < 0.07) | ((cv - np.floor(cv)) < 0.07)
    base = np.where(minor[..., None], base * 0.8, base)
    base = np.where(major[..., None], base * 0.3, base)
    out[ok] = (base * np.clip(light, 0.25, 1.2)[..., None])[ok]
    return out


def picture_painter(mesh, cap, pt, g):
    img = np.zeros((g.Hp, g.Wp, 3)) + np.array([0.05, 0.04, 0.07])
    room = pt.kind == 1
    # full image: the room texel under each room pixel of the full painter
    full_uv = np.full((g.Hp, g.Wp, 2), np.nan)
    full_file = np.full((g.Hp, g.Wp), -9, dtype=np.int64)
    full_light = np.ones((g.Hp, g.Wp))
    rr, cc = np.nonzero(room)
    if len(rr):
        ids = pt.full_top[rr, cc]
        uniq, inv = np.unique(ids, return_inverse=True)
        C = np.stack([pt.uvc[int(t)] for t in uniq])
        X = np.stack([g.xs[cc], g.ys[rr, 0], np.ones(len(rr))], axis=1)
        full_uv[rr, cc] = np.einsum("ni,nij->nj", X, C[inv])
        full_file[rr, cc] = np.array([pt.file_of[int(t)] for t in uniq])[inv]
        full_light[rr, cc] = np.array([pt.light_of[int(t)] for t in uniq])[inv]
    tex = texel_rgb(mesh, full_file, full_uv, full_light)
    img[room] = tex[room]
    img[pt.kind == 2] = (0.95, 0.25, 0.85)
    lines = pt.kind == 3
    if lines.any():
        R = cap.regions
        rr, cc = np.nonzero(lines)
        rows = pt.full_top[rr, cc]
        img[rr, cc] = np.clip(R[rows][:, 31:34], 0, 1)
    return img


def picture_truth(mesh, tr, g):
    img = np.zeros((g.Hp, g.Wp, 3)) + np.array([0.05, 0.04, 0.07])
    D = tr.id >= 0
    files = np.where(D, mesh.file[np.where(D, tr.id, 0)], -9)
    light = np.where(D, mesh.light[np.where(D, tr.id, 0)], 1.0)
    tex = texel_rgb(mesh, files, tr.uv, light)
    img[D] = tex[D]
    img[tr.actor_visible] = (0.95, 0.25, 0.85)
    return img


DIFF_LEGEND = ("DIFF: grey = right (brighter = misplaced, white >= 12 px), red = painted over by what is behind, "
               "green = never drawn (what is behind shows), purple = unmatched + wrong, cyan = hole, orange = extra, "
               "magenta = actor wrong, yellow tint = ambiguous order")


def picture_diff(res, pt, tr, g):
    img = np.zeros((g.Hp, g.Wp, 3))
    cls = res.cls
    m = np.nan_to_num(res.mis, nan=0.0)
    k = np.clip(m / 12.0, 0, 1)[..., None]
    grey = np.broadcast_to(0.18 + 0.82 * k, img.shape)
    img[cls == RIGHT] = grey[cls == RIGHT]
    img[cls == WRONG_OVER] = (0.95, 0.1, 0.1)
    img[cls == WRONG_MISSING] = (0.1, 0.9, 0.25)
    img[cls == WRONG_UNMATCHED] = (0.6, 0.25, 1.0)
    img[cls == HOLE] = (0.0, 0.75, 1.0)
    img[cls == EXTRA] = (1.0, 0.55, 0.0)
    img[res.actor_err] = (1.0, 0.0, 1.0)
    amb = pt.amb
    img[amb] = img[amb] * 0.4 + np.array([1.0, 0.9, 0.0]) * 0.6
    return img


def save_png(path, img):
    from PIL import Image
    a = (np.clip(np.flipud(img), 0, 1) * 255).astype(np.uint8)
    Image.fromarray(a).save(path)


SHEET_LABELS = ("PAINTER (what WoW draws from the API calls)", "TRUTH (z-buffer, perspective)",
                "DIFF: grey right (white = 12+ px off)  red painted over  green never drawn  cyan hole  magenta actor")


def save_sheet(path, title, lines, painter, truth, diff, labels=SHEET_LABELS):
    """Three pictures side by side with a title, a metrics line and a label under each (for reading with an image
    viewer: one file per pose)."""
    from PIL import Image, ImageDraw
    ims = [(np.clip(np.flipud(x), 0, 1) * 255).astype(np.uint8) for x in (painter, truth, diff)]
    h, w = ims[0].shape[:2]
    gap, head = 6, 18 + 14 * len(lines)
    sheet = Image.new("RGB", (w * 3 + gap * 2, h + head + 16), (20, 20, 24))
    for k, im in enumerate(ims):
        sheet.paste(Image.fromarray(im), (k * (w + gap), head))
    dr = ImageDraw.Draw(sheet)
    dr.text((4, 2), title, fill=(255, 255, 255))
    for k, l in enumerate(lines):
        dr.text((4, 18 + 14 * k), l, fill=(210, 210, 210))
    for k, l in enumerate(labels):
        dr.text((k * (w + gap) + 4, head + h + 2), l, fill=(230, 230, 120))
    sheet.save(path)


# ---------------------------------------------------------------------------------------------------------------
# the session: boot the addon, poses, frames
# ---------------------------------------------------------------------------------------------------------------
def boot_trainer(enc, size, seed=3):
    from harness import World, Client
    w = World()
    c = Client(w, "Alice", class_file="PALADIN", guild_rank=3, guild="Casual Disaster")
    c.load_addon()
    w.tick(2.0)
    c.slash("/dz play trainer")
    w.tick(0.3)
    with open(LUA_HELPER, encoding="utf-8") as fh:
        c.eval(fh.read())
    c.eval("ns.TrainerUI._Select('%s', '%s')" % (enc, ENC_DIFF[enc]))
    c.eval("local v = ns.TrainerUI._View() v:SetSize(%d, %d)" % size)
    c.eval("ns.TrainerUI._Start(%d)" % seed)
    if enc == "vashj":
        for _ in range(40):                       # the round starts: an elemental, the raiders on their spots
            c.eval("ns.TrainerUI._Tick(0.1)")
    c.eval("ns.TrainerUI._Tick(0.001)")
    return w, c


class Session:
    def __init__(self, enc, size, scale):
        self.enc = enc
        self.size = size
        self.S = scale
        self.w, self.c = boot_trainer(enc, size)
        self.mesh = Mesh.from_text(self.c.eval("return __RC.mesh('%s')" % enc))
        self.g = Grid(int(round(size[0] * scale)), int(round(size[1] * scale)))
        self.gens = self.c.eval_py("local t = {} for _, g in ipairs(ns.TrainerUI._Sim().generators or {}) do "
                                   "t[#t+1] = { g.x, g.y } end return t") or []
        self.check_projection()

    def check_projection(self):
        """The Python camera must be the mock's: project a few points both ways."""
        self.c.eval("__RC.pose(%f, %f, %f, 0.4, 12)  ns.TrainerUI._Tick(0.001)" % (30, 30, 0.7))
        cap = self.capture()
        rng = np.random.RandomState(1)
        pts = cap.cam.C + cap.cam.F * 20 + rng.uniform(-8, 8, (12, 3))
        s = self.c.eval("return __RC.project(select(2, ns.TrainerUI._View()), '%s')" %
                        " ".join("%.10g" % v for v in pts.ravel()))
        got = np.array(s.split(), float).reshape(-1, 3)
        es = cap.cam_raw[14] or 1.0
        px, py, d = cap.cam.project(pts)
        ox, oy = cap.cam.cx - cap.cam.W / 2, cap.cam.cy - cap.cam.H / 2       # the scene's corner in the view
        err = max(np.nanmax(np.abs(got[:, 0] / es + ox - px)), np.nanmax(np.abs(got[:, 1] / es + oy - py)))
        if not err < 1e-6:
            raise AssertionError("render_check's camera does not match the mock's Project3DPointTo2D (%g)" % err)

    def capture(self):
        return Capture(self.c.eval("return __RC.capture_trainer()"), *self.size)

    def pose(self, x, y, facing, pitch, dist):
        self.c.eval("__RC.pose(%.10g, %.10g, %.10g, %.10g, %.10g)" % (x, y, facing, pitch, dist))

    def frame(self, dt=0.001):
        t0 = time.perf_counter()
        s = self.c.eval("return __RC.counted_tick(%g)" % dt)
        ms = (time.perf_counter() - t0) * 1000
        counts = {}
        for part in (s or "").split():
            k, _, v = part.partition("=")
            counts[k] = int(v)
        return counts, ms


def resolve_pose(sess, spec):
    name, x, y, facing, pitch, dist, note = spec
    if x == "gen1":
        gx, gy = sess.gens[0]
        cx, cy = 105.0, 105.0
        dx, dy = gx - cx, gy - cy
        ln = math.hypot(dx, dy)
        x, y = gx + dx / ln * 3, gy + dy / ln * 3
        facing = math.atan2(-dy, -dx)
    return name, x, y, facing, pitch, dist, note


def analyse(sess, cap, backfaces=False):
    tr = render_truth(sess.mesh, cap, sess.g, sess.S, backfaces)
    pt = render_painter(sess.mesh, cap, tr, sess.g, sess.S)
    res = compare(sess.mesh, cap, tr, pt, sess.g, sess.S)
    return tr, pt, res


def summarize_api(counts):
    total = sum(counts.values())
    main = {k: counts.get(k, 0) for k in API_KEYS}
    return total, main


def run_encounter(enc, args, out):
    size = tuple(int(v) for v in args.size.lower().split("x"))
    sess = Session(enc, size, args.scale)
    poses = POSES[enc]
    if args.quick:
        poses = [p for p in poses if p[0] in QUICK_POSES[enc]]
    if args.poses:
        want = set(args.poses.split(","))
        poses = [p for p in poses if p[0] in want]
    results = []
    png = args.png
    for spec in poses:
        name, x, y, facing, pitch, dist, note = resolve_pose(sess, spec)
        t0 = time.perf_counter()
        sess.pose(x, y, facing + 0.004, pitch, dist)
        sess.frame()
        sess.pose(x, y, facing, pitch, dist)
        counts, ms = sess.frame()
        cap = sess.capture()
        tr, pt, res = analyse(sess, cap, backfaces=True)
        total, main = summarize_api(counts)
        rec = dict(enc=enc, pose=name, note=note, x=x, y=y, facing=facing, pitch=pitch, dist=dist)
        rec.update({k: v for k, v in res.items()})
        rec["apiCallsPerFrame"] = total
        rec["api"] = main
        rec["luaMsPerFrame"] = ms
        if cap.player and (abs(cap.player[0] - x) > 1e-6 or abs(cap.player[1] - y) > 1e-6):
            rec["warning"] = "the sim moved the player to %.2f, %.2f" % cap.player[:2]
        results.append(rec)
        if png:
            base = os.path.join(png, "%s_%s" % (enc, name))
            pimg, timg, dimg = picture_painter(sess.mesh, cap, pt, sess.g), picture_truth(sess.mesh, tr, sess.g), \
                picture_diff(res, pt, tr, sess.g)
            save_png(base + "_painter.png", pimg)
            save_png(base + "_truth.png", timg)
            save_png(base + "_diff.png", dimg)
            save_sheet(base + "_sheet.png", "%s / %s: %s" % (enc, name, note), [metric_line(rec)], pimg, timg, dimg)
        print_row(rec)
        rec["seconds"] = time.perf_counter() - t0
    walks = []
    if not args.no_walk:
        walks.append(run_walk(sess, enc, args))
        walks.append(run_actor_walk(sess, enc, args))
    out.extend(results)
    return results, walks


def run_walk(sess, enc, args):
    wk = dict(WALKS[enc])
    frames = 8 if args.quick else wk["frames"]
    x, y, f = wk["x"], wk["y"], wk["facing"]
    prev = None
    pops, pops99, flicks = [], [], []
    per = []
    worst = (-1.0, None)
    keep = {}
    want = {0, frames // 2, frames - 1}
    sess.pose(x, y, f + 0.004, wk["pitch"], wk["dist"])
    sess.frame()
    for k in range(frames):
        if k > 0:
            if k >= wk["turnAfter"]:
                f += wk["turn"]
            x += math.cos(f) * wk["step"]
            y += math.sin(f) * wk["step"]
        sess.pose(x, y, f, wk["pitch"], wk["dist"])
        counts, ms = sess.frame()
        cap = sess.capture()
        tr, pt, res = analyse(sess, cap)
        total, main = summarize_api(counts)
        cur = dict(id=tr.id, cls=res.cls, vec=res.vec)
        rec = {kk: v for kk, v in res.items()}
        rec.update(frame=k, x=x, y=y, facing=f, apiCallsPerFrame=total, api=main, luaMsPerFrame=ms)
        if prev is not None:
            pm, p99, fl = stability(prev, cur)
            rec.update(popMaxPx=pm, popP99Px=p99, flickerPct=fl)
            pops.append(pm)
            pops99.append(p99)
            flicks.append(fl)
            if pm > worst[0]:
                worst = (pm, k)
        per.append(rec)
        if args.png:
            keep[k] = (cap, tr, pt, res, cur)
            hold = want | {k}
            if worst[1] is not None:
                hold |= {worst[1], worst[1] - 1}
            for old in list(keep):
                if old not in hold:
                    del keep[old]
        prev = cur
    agg = dict(enc=enc, pose="walk", note=wk["note"], frames=frames)
    for key in ("wrongSurfacePct", "wrongPaintedOverPct", "wrongOverAboveScenePct", "wrongMissingPct", "holesPct",
                "extraPct", "misplacementP95px", "misplacementMaxPx", "actorErrPct", "ambiguousPct",
                "ambiguousLinesPct", "shownTextures", "apiCallsPerFrame", "luaMsPerFrame"):
        vals = [r[key] for r in per]
        agg[key] = float(np.mean(vals))
        agg[key + "_max"] = float(np.max(vals))
    agg["popMaxPx"] = float(max(pops)) if pops else 0.0
    agg["popP99Px"] = float(np.max(pops99)) if pops99 else 0.0
    agg["popP99PxMean"] = float(np.mean(pops99)) if pops99 else 0.0
    agg["flickerPct"] = float(np.mean(flicks)) if flicks else 0.0
    agg["flickerPct_max"] = float(np.max(flicks)) if flicks else 0.0
    agg["worstPopFrame"] = worst[1]
    api = {}
    for r in per:
        for kk, v in r["api"].items():
            api[kk] = api.get(kk, 0) + v / len(per)
    agg["api"] = {kk: round(v, 1) for kk, v in api.items()}
    agg["perFrame"] = [{kk: (round(v, 4) if isinstance(v, float) else v) for kk, v in r.items() if kk != "api"}
                       for r in per]
    if args.png:
        for k in sorted(kk for kk in keep if kk in want):
            cap, tr, pt, res, _ = keep[k]
            pimg, timg, dimg = (picture_painter(sess.mesh, cap, pt, sess.g), picture_truth(sess.mesh, tr, sess.g),
                                picture_diff(res, pt, tr, sess.g))
            save_sheet(os.path.join(args.png, "%s_walk%02d_sheet.png" % (enc, k)), "%s / walk frame %d" % (enc, k),
                       [metric_line(per[k])], pimg, timg, dimg)
        wk_ = worst[1]
        if wk_ is not None and wk_ in keep and wk_ - 1 in keep:
            cap0, tr0, pt0, res0, cur0 = keep[wk_ - 1]
            cap1, tr1, pt1, res1, cur1 = keep[wk_]
            p0 = picture_painter(sess.mesh, cap0, pt0, sess.g)
            p1 = picture_painter(sess.mesh, cap1, pt1, sess.g)
            save_sheet(os.path.join(args.png, "%s_walk_pop_sheet.png" % enc),
                       "%s / the largest pop of the walk: frame %d -> %d (%.1f px)" % (enc, wk_ - 1, wk_, worst[0]),
                       [metric_line(per[wk_])], p0, p1, picture_pop(cur0, cur1, sess.g),
                       labels=("PAINTER frame %d" % (wk_ - 1), "PAINTER frame %d (0.25 yd further)" % wk_,
                               "how far each pixel's texel jumped between them (white = 12+ px; dark = edge)"))
    print_row(agg)
    return agg


def run_actor_walk(sess, enc, args):
    """The view stands still, a raider walks: what the occlusion pass makes of it, frame by frame."""
    aw = ACTOR_WALKS[enc]
    frames = 9 if args.quick else aw["frames"]
    px_, py_, pf = aw["player"]
    sess.pose(px_, py_, pf + 0.004, aw["pitch"], aw["dist"])
    sess.frame()
    sess.pose(px_, py_, pf, aw["pitch"], aw["dist"])
    sess.frame()
    (x0, y0), (x1, y1) = aw["path"]
    per, flicks = [], []
    prev = None
    worst = (-1.0, None, None)
    for k in range(frames):
        t = k / max(1, frames - 1)
        x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
        sess.c.eval("local r = ns.TrainerUI._Sim():Alive('raider')[%d] if r then r.x, r.y, r.goal = %.10g, %.10g, nil end"
                    % (aw["raider"], x, y))
        counts, ms = sess.frame()
        cap = sess.capture()
        tr, pt, res = analyse(sess, cap)
        total, main = summarize_api(counts)
        cur = dict(id=tr.id, cls=res.cls, vec=res.vec)
        rec = {kk: v for kk, v in res.items()}
        rec.update(frame=k, raiderX=x, raiderY=y, apiCallsPerFrame=total, api=main, luaMsPerFrame=ms)
        if prev is not None:
            pm, p99, fl = stability(prev, cur)
            rec.update(popMaxPx=pm, popP99Px=p99, flickerPct=fl)
            flicks.append(fl)
        bad = rec["actorErrPct"] + rec["wrongSurfacePct"]
        if args.png and bad > worst[0]:
            worst = (bad, k, (cap, tr, pt, res))
        per.append(rec)
        prev = cur
    agg = dict(enc=enc, pose="actor_walk", note=aw["note"], frames=frames)
    for key in ("wrongSurfacePct", "wrongPaintedOverPct", "wrongOverAboveScenePct", "wrongMissingPct", "holesPct",
                "extraPct", "misplacementP95px", "misplacementMaxPx", "actorErrPct", "actorHiddenWronglyPct",
                "actorShownWronglyPct", "ambiguousPct", "ambiguousLinesPct", "shownTextures", "apiCallsPerFrame",
                "luaMsPerFrame"):
        vals = [r[key] for r in per]
        agg[key] = float(np.mean(vals))
        agg[key + "_max"] = float(np.max(vals))
    agg["popMaxPx"] = float(max(r.get("popMaxPx", 0) for r in per))
    agg["popP99Px"] = float(max(r.get("popP99Px", 0) for r in per))
    agg["flickerPct"] = float(np.mean(flicks)) if flicks else 0.0
    agg["flickerPct_max"] = float(np.max(flicks)) if flicks else 0.0
    agg["framesWithActorErrorOver5Pct"] = int(sum(1 for r in per if r["actorErrPct"] > 5))
    api = {}
    for r in per:
        for kk, v in r["api"].items():
            api[kk] = api.get(kk, 0) + v / len(per)
    agg["api"] = {kk: round(v, 1) for kk, v in api.items()}
    agg["perFrame"] = [{kk: (round(v, 4) if isinstance(v, float) else v) for kk, v in r.items() if kk != "api"}
                       for r in per]
    if args.png and worst[1] is not None:
        cap, tr, pt, res = worst[2]
        save_sheet(os.path.join(args.png, "%s_actor_walk_worst_sheet.png" % enc),
                   "%s / actor walk, its worst frame %d: %s" % (enc, worst[1], aw["note"]), [metric_line(per[worst[1]])],
                   picture_painter(sess.mesh, cap, pt, sess.g), picture_truth(sess.mesh, tr, sess.g),
                   picture_diff(res, pt, tr, sess.g))
    print_row(agg)
    return agg


def picture_pop(prev, cur, g):
    same = (prev["id"] >= 0) & (prev["id"] == cur["id"]) & (prev["cls"] == RIGHT) & (cur["cls"] == RIGHT)
    d = np.hypot(cur["vec"][..., 0] - prev["vec"][..., 0], cur["vec"][..., 1] - prev["vec"][..., 1])
    d = np.where(same & ~np.isnan(d), d, 0.0)
    k = np.clip(d / 12.0, 0, 1)
    img = np.zeros((g.Hp, g.Wp, 3))
    img[..., 0] = k
    img[..., 1] = k
    img[..., 2] = k
    img[~same] = (0.12, 0.05, 0.12)
    return img


# ---------------------------------------------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------------------------------------------
def metric_line(r):
    s = "wrong %.2f%% (painted over %.2f%%, never drawn %.2f%%)  holes %.2f%%  extra %.2f%%  misplaced p95 %.1f px " \
        "max %.1f px  actor %.1f%%  ambiguous %.2f%%  textures %d  api %d" % (
            r.get("wrongSurfacePct", 0), r.get("wrongPaintedOverPct", 0), r.get("wrongMissingPct", 0),
            r.get("holesPct", 0), r.get("extraPct", 0), r.get("misplacementP95px", 0), r.get("misplacementMaxPx", 0),
            r.get("actorErrPct", 0), r.get("ambiguousPct", 0), r.get("shownTextures", 0), r.get("apiCallsPerFrame", 0))
    if "seeThroughPct" in r:
        s += "  see-through %.1f%%" % r["seeThroughPct"]
    if "popMaxPx" in r:
        s += "  pop %.1f px  flicker %.2f%%" % (r["popMaxPx"], r.get("flickerPct", 0))
    return s


HEADER = "%-6s %-22s %7s %6s %6s %7s %7s %6s %7s %7s %6s %6s %7s %6s %6s" % (
    "enc", "pose", "wrong%", "over%", "miss%", "holes%", "extra%", "mis95", "misMax", "actor%", "amb%", "tex", "api",
    "luaMs", "see%")


def print_row(r):
    line = "%-6s %-22s %7.2f %6.2f %6.2f %7.2f %7.2f %6.1f %7.1f %7.1f %6.2f %6d %7d %6.1f %6s" % (
        r["enc"], r["pose"], r["wrongSurfacePct"], r.get("wrongPaintedOverPct", 0), r.get("wrongMissingPct", 0),
        r["holesPct"], r["extraPct"], r["misplacementP95px"], r["misplacementMaxPx"], r["actorErrPct"],
        r["ambiguousPct"], int(r["shownTextures"]), int(r["apiCallsPerFrame"]), r["luaMsPerFrame"],
        ("%.1f" % r["seeThroughPct"]) if "seeThroughPct" in r else "-")
    if r["pose"] in ("walk", "actor_walk"):
        line += "  popMax %.1f px  popP99 %.1f px  flicker %.2f%% (max %.2f%%)" % (
            r["popMaxPx"], r["popP99Px"], r["flickerPct"], r["flickerPct_max"])
    if r["pose"] == "actor_walk":
        line += "  actor max %.1f%%" % r["actorErrPct_max"]
    if r.get("warning"):
        line += "  [%s]" % r["warning"]
    print(line, flush=True)


def compare_runs(old_path, new):
    with open(old_path, encoding="utf-8") as fh:
        old = json.load(fh)
    idx = {(r["enc"], r["pose"]): r for r in old.get("results", [])}
    print("\nchange against %s (new - old):" % old_path)
    keys = ("wrongSurfacePct", "wrongPaintedOverPct", "wrongMissingPct", "holesPct", "misplacementP95px",
            "misplacementMaxPx", "popMaxPx", "actorErrPct", "apiCallsPerFrame")
    for r in new:
        o = idx.get((r["enc"], r["pose"]))
        if not o:
            continue
        print("%-6s %-22s " % (r["enc"], r["pose"]) + "  ".join(
            "%s %+.2f" % (k, r.get(k, 0) - o.get(k, 0)) for k in keys))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--enc", default="both", choices=("teron", "vashj", "both"))
    ap.add_argument("--png", metavar="OUTDIR", help="save painter / truth / diff PNGs and a sheet per pose here")
    ap.add_argument("--quick", action="store_true", help="4 poses per room and an 8 frame walk")
    ap.add_argument("--json", metavar="FILE", help="write every number here (default: OUTDIR/metrics.json with --png)")
    ap.add_argument("--size", default="600x400", help="the view's size in UI units (default 600x400)")
    ap.add_argument("--scale", type=float, default=1.0, help="pixels per UI unit of the pictures (default 1)")
    ap.add_argument("--poses", help="only these poses (comma separated names)")
    ap.add_argument("--no-walk", action="store_true", help="skip the walk path")
    ap.add_argument("--compare", metavar="JSON", help="print the change against an earlier run's metrics.json")
    args = ap.parse_args(argv)
    if args.png:
        os.makedirs(args.png, exist_ok=True)
        with open(os.path.join(args.png, "README.txt"), "w", encoding="utf-8") as fh:
            fh.write("Pictures of tools/render_check.py. Per pose: <room>_<pose>_sheet.png = painter | truth | diff side by "
                     "side with the numbers; _painter / _truth / _diff.png = the same at full size. Walk: "
                     "<room>_walkNN_sheet.png and <room>_walk_pop_sheet.png (the largest jump between two frames).\n"
                     "The room textures are made up (a hue per texture file, an 8 x 8 checker per texture unit, dark "
                     "lines on whole units) so that stretching shows; actors are magenta billboards.\n\n%s\n\n%s\n"
                     % (DIFF_LEGEND, __doc__))
    encs = ("teron", "vashj") if args.enc == "both" else (args.enc,)
    t0 = time.perf_counter()
    print(HEADER)
    results, walks = [], []
    for enc in encs:
        _, ws = run_encounter(enc, args, results)
        walks.extend(ws)
    print("-- %d frames in %.1f s" % (len(results) + sum(w["frames"] for w in walks), time.perf_counter() - t0))
    data = dict(size=args.size, scale=args.scale, results=results + walks)
    path = args.json or (os.path.join(args.png, "metrics.json") if args.png else None)
    if path:
        def clean(o):
            if isinstance(o, dict):
                return {k: clean(v) for k, v in o.items()}
            if isinstance(o, (list, tuple)):
                return [clean(v) for v in o]
            if isinstance(o, (np.floating,)):
                return float(o)
            if isinstance(o, (np.integer,)):
                return int(o)
            return o
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(clean(data), fh, indent=1)
        print("-- metrics: %s" % path)
    if args.compare:
        compare_runs(args.compare, results + walks)
    return data


if __name__ == "__main__":
    main()
