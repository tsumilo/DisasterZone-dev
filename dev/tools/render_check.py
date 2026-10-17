#!/usr/bin/env python
"""Render check: an offline reference renderer that measures how correct and how stable the Raid Trainer's software
room renderer (DisasterZone_Trainer/UI.lua: PrepareMesh / DrawMesh / PlaceTex / UpdateOcclusion) is.

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
the mesh triangle it is a piece of: same texture file, its four corner texture coordinates inside that triangle's
texture triangle, and the points of the triangle they stand for, projected through the camera, landing on its four
corners (within the match tolerance). A triangle and its quad mate (the data format v2 pair list: same node and
texture, one shared edge, matching texture coordinates) count as one surface: the renderer draws them as one texture
whose second GPU triangle lies on the mate, so a corner may lie on either and a pixel of the piece is right where the
truth shows either. A texture maps its picture affinely, but a correctly placed piece can only ever show
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

Renderer v2 additions (docs/trainer_renderer_v2/spec.md section 9.2):
  actors           --billboard axis (default): each billboard is upright through the actor's axis and faces the camera
                   position (its lateral vector is perpendicular to the horizontal camera -> actor vector), the plane
                   the v2 renderer clips copies with; --billboard forward: the old camera-parallel billboards.
                   --actors thick: each actor is an upright 12-sided prism (radius max(0.4, w/2), feet + 0.15 to the
                   head) in the truth and in the painter's ModelScene stamp.
  match tolerance  a region is a piece of T when its corners sit within 1 + tau (+ dilate) of T's, tau from UI._Render()
                   (2.0 when the hook does not exist): morphed midpoints and Lua-clipped copy corners lie on the base
                   piece, whose affine error is at most tau.
  copies           room regions in frames above the ModelScene's level: copyTextures (and copyLines); the others:
                   shownTexturesBelowScene. Actor pixels where the painter's top is a line are not actor errors.
  actorErrByUnit   per unit id: its pixels, hidden wrongly, shown wrongly, hidden by the truth.
  ambiguousSameNodePct  ties between two room regions matched to triangles of the same BSP node (coplanar; not an
                   order error), kept out of ambiguousPct.
  line truth       (only with UI._Marks) every 3D mark segment the renderer drew, sampled at 1 px steps: the truth
                   sees a sample when its 1/d is at least the room's and the actors' z-buffer at that pixel; the
                   painter when a line is on top there. Over the sample's pixel and its 8 neighbours, only pixels where
                   the painter drew some line count (elsewhere a line is not evidence either way): a sample is wrong
                   when painter and truth disagree at every such pixel, or - no line drawn anywhere there - when the
                   truth sees it at all 9 pixels. -> wrongLinePct, lineTruthVisiblePct.
  order invariants (only when UI._Order has the v2 fields) after every frame: wrong, distinct = nodes, mark lines on
                   odd positions or in the bottom line frame; SetParent per frame after a session's first.
  walks            set UI._RenderOpts{camDt = step / 7} when that hook exists (camera smoothing as in game while the
                   sim stays frozen).
  new poses        8 poses with preconditions that fail loudly (NEW_POSES).
  --gate           runs the runs of spec section 10 (R1..R5, Bench) and checks its criteria in a pass / fail table.
                   --criteria 1,2,8 and --runs R1,R5 run a subset; a check whose hook does not exist yet is SKIPPED.
                   Exit code 0: every check passed; 1: something failed; 2: nothing failed but something was skipped.
  --bench          null setters in the mock (M.null_setters), no image analysis, the wall time of each UI._Tick.

Run:  luaenv\\Scripts\\python.exe tools\\render_check.py --enc teron|vashj|both [--png OUTDIR] [--quick] [--json FILE]
      [--size 600x400] [--scale 1] [--poses a,b] [--no-walk] [--no-new] [--compare OLD.json]
      [--billboard axis|forward] [--actors billboard|thick] [--gate [--criteria 1,2] [--runs R1,R5]] [--bench]
"""
import argparse
import json
import math
import os
import re
import subprocess
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
DEFAULT_TAU = 2.0            # the renderer's screen-error bound when UI._Render() does not report one
MATCH_BASE = 1.0             # view units: MATCH_TOL = MATCH_BASE + tau + dilate
BILLBOARD = "axis"           # default actor billboard: "axis" (faces the camera position) or "forward" (camera plane)
ACTOR_MODE = "billboard"     # "billboard" or "thick" (12-sided prisms)
# the spec's default render options (Room.opts) that a pose's own options are put back to when render_check has not
# set them itself
OPT_DEFAULTS = {"collision": True, "morph": True, "copies": True, "siblingQuads": False, "camDt": False}

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
# The v2 poses (spec 9.2.10). Each one has a precondition ("pre") that is checked on the measured frame and fails
# loudly when it does not hold: units = (kind, index among the living, x, y) moved there for the pose (put back
# afterwards); steep = two raiders placed relative to the camera's ground point (1.0 yd in front, 0.15 yd behind);
# marks = render_check's own floor marks (x, y, r, column); opts = render options for this pose only (applied only
# when UI._RenderOpts exists).
NEW_POSES = {
    "teron": [
        dict(name="actor_chain_pillar", x=25.5, y=8, facing=PI / 2, pitch=0.3, dist=14, pre="chain",
             units=[("raider", 1, 24.0, 24.5), ("raider", 2, 26.5, 25.5), ("raider", 3, 27.5, 16.0)],
             note="raiders 1 and 2 behind the west pillar, raider 3 in front of them and overlapping on screen"),
        dict(name="boss_by_pillar", x=25.5, y=8, facing=PI / 2, pitch=0.3, dist=14, pre="boss",
             units=[("boss", 1, 22.5, 26.0)],
             note="Teron beside the west pillar: the pillar hides part of him"),
        dict(name="steep_pitch_13", x=30, y=14, facing=PI / 2, pitch=1.3, dist=14, pre="steep", steep=True,
             note="pitch 1.3: a raider 1.0 yd in front of the camera's ground point, one 0.15 yd behind it"),
        dict(name="camera_grazing_wall", x=0.4, y=20, facing=PI / 2, pitch=0.1, dist=6, pre="grazing",
             opts={"collision": False},
             note="the camera about 0.6 yd from the west wall, looking north along it (camera collision off)"),
    ],
    "vashj": [
        dict(name="steep_pitch_13", x=105, y=70, facing=PI / 2, pitch=1.3, dist=14, pre="steep", steep=True,
             note="pitch 1.3: a raider 1.0 yd in front of the camera's ground point, one 0.15 yd behind it"),
        dict(name="camera_grazing_wall", x=108.1, y=172, facing=-PI / 2, pitch=0.1, dist=6, pre="grazing",
             opts={"collision": False},
             note="north of the platform: the camera about 0.6 yd from a wall face, looking south along it "
                  "(camera collision off)"),
        dict(name="ring_marks_steps", x=105, y=48, facing=-PI / 2, pitch=0.5, dist=14, pre="ring",
             marks=[(105, 44, 6, 4)],
             note="a ring with a column across the top edge of the steps: the edge hides its far half "
                  "(spec: the mark at 105, 32 - from this pose the 29 degree steps are as steep as the camera "
                  "pitch, so that ring was 99.5% hidden)"),
        dict(name="generator_over_steps", x=54.32, y=156.11, facing=-0.789, pitch=0.3, dist=14, pre="generator",
             units=[("generator", 1, 82.97, 127.22)],
             note="down the north-west steps looking up at a Shield Generator on the ring: the top step hides its "
                  "pedestal (the model's origin is mid-height, 2.8 yd over its base: in-game report 2026-10-04)"),
    ],
}
ENC_DIFF = {"teron": "quick", "vashj": "looter"}
API_KEYS = ("SetVertexOffset", "SetPoint", "ClearAllPoints", "SetTexCoord", "SetTexture", "SetParent", "SetDrawLayer",
            "SetFrameLevel", "Show", "Hide", "CreateTexture", "CreateLine", "SetVertexColor", "SetStartPoint",
            "SetEndPoint", "SetThickness", "SetColorTexture", "SetBlendMode")


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
        self.hooks = set()               # the trainer's optional test hooks that exist (H record)
        self.tau, self.dilate = DEFAULT_TAU, 0.0      # (T record, only with UI._Render)
        self.has_tau = False
        self.marks = None                # 3D mark segments (M records; None = no UI._Marks hook)
        self.billboard = BILLBOARD       # how the actors are modelled (Session sets these from its options)
        self.actor_mode = ACTOR_MODE
        marks = []
        for line in text.split("\n"):
            if not line:
                continue
            tag, rest = line[0], line[2:]
            if tag == "H":
                self.hooks = set(rest.split())
            elif tag == "T":
                v = [float(x) for x in rest.split()]
                self.tau, self.dilate, self.has_tau = v[0], (v[1] if len(v) > 1 else 0.0), True
            elif tag == "M":
                marks.append(tuple(float(x) for x in rest.split()))
            elif tag == "R":
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
                                   kind=int(v[9]), bottom=float(v[10]) if len(v) > 10 else 0.0))
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
        if marks or "_Marks" in self.hooks:
            self.marks = marks

    @property
    def match_tol(self):
        """A region is a piece of triangle T when its corners sit within this of T's (view units)."""
        return MATCH_BASE + self.tau + self.dilate


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
    def __init__(self, V, T, textures, node_of=None, pair=None):
        self.V = np.asarray(V, float).reshape(-1, 6)
        T = np.asarray(T, int).reshape(-1, 4)
        self.tri = T[:, :3] - 1
        # the BSP node of each triangle (1-based; 0 = none). Without it every triangle is its own node.
        if node_of is not None and len(node_of) == len(T):
            self.node_of = np.asarray(node_of, dtype=np.int64)
        else:
            self.node_of = np.arange(1, len(T) + 1, dtype=np.int64)
        # each triangle's quad mate (0-based; -1 = none), from the data format v2 pair list (1-based, 0 = none): the
        # renderer draws a triangle and its mate - same node, same texture, one shared edge, matching texture
        # coordinates - as one texture. Only mutual pairs count.
        self.mate = np.full(len(T), -1, dtype=np.int64)
        if pair is not None and len(pair) == len(T):
            p = np.asarray(pair, dtype=np.int64) - 1
            ok = (p >= 0) & (p < len(T))
            ok[ok] &= p[p[ok]] == np.nonzero(ok)[0]
            self.mate[ok] = p[ok]
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
        parts = text.split("|")
        v, t, x = parts[:3]
        node_of = np.array(parts[3].split(), int) if len(parts) > 3 and parts[3].strip() else None
        pair = np.array(parts[4].split(), int) if len(parts) > 4 and parts[4].strip() else None
        return cls(np.array(v.split(), float), np.array(t.split(), int), x.split(), node_of, pair)


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


PRISM_SIDES = 12
PRISM_MIN_RADIUS = 0.4


def billboard_tris(actors, cam, billboard=None):
    """Each actor as an upright rectangle: -> list of (actor index, 3 scene points) x 2. billboard "axis" (default):
    the rectangle stands on the actor's axis and faces the camera position (lateral vector perpendicular to the
    horizontal camera -> actor vector, the plane of the v2 renderer's family A); "forward": parallel to the camera's
    image plane (the camera's right vector). A camera straight above the actor falls back to "forward"."""
    billboard = billboard or BILLBOARD
    rh = np.array([cam.R[0], cam.R[1], 0.0])
    n = np.linalg.norm(rh)
    rh = rh / n if n > 1e-9 else np.array([0.0, 1.0, 0.0])
    out = []
    for k, a in enumerate(actors):
        if a["kind"] != 1 or a["height"] <= FEET:
            continue
        # (from where the model's own box ends - its feet, or lower for a model whose origin is mid-height - up to
        # its body height over its origin)
        p = np.array(a["pos"]) + np.array([0.0, 0.0, a.get("bottom", 0.0) + FEET])
        lat = rh
        if billboard == "axis":
            vx, vy = p[0] - cam.C[0], p[1] - cam.C[1]
            hd = math.hypot(vx, vy)
            if hd > 1e-6:
                lat = np.array([-vy / hd, vx / hd, 0.0])
        hw = lat * a["width"] / 2
        up = np.array([0, 0, a["height"] - a.get("bottom", 0.0) - FEET])
        bl, br, tl, tr = p - hw, p + hw, p - hw + up, p + hw + up
        out.append((k, (bl, br, tr)))
        out.append((k, (bl, tr, tl)))
    return out


def prism_faces(actors):
    """Each actor as an upright 12-sided prism (radius max(0.4, w / 2), from the feet + 0.15 to the head): -> list of
    (actor index, polygon of scene points): the 12 sides and both caps."""
    out = []
    ang = np.arange(PRISM_SIDES) * (2 * math.pi / PRISM_SIDES)
    for k, a in enumerate(actors):
        if a["kind"] != 1 or a["height"] <= FEET:
            continue
        x, y, z = a["pos"]
        rad = max(PRISM_MIN_RADIUS, a["width"] / 2)
        z0, z1 = z + a.get("bottom", 0.0) + FEET, z + a["height"]
        bot = [np.array([x + rad * math.cos(t), y + rad * math.sin(t), z0]) for t in ang]
        top = [np.array([x + rad * math.cos(t), y + rad * math.sin(t), z1]) for t in ang]
        for i in range(PRISM_SIDES):
            j = (i + 1) % PRISM_SIDES
            out.append((k, (bot[i], bot[j], top[j], top[i])))
        out.append((k, tuple(top)))
        out.append((k, tuple(bot[::-1])))
    return out


def actor_shapes(actors, cam, billboard=None, mode=None):
    """The actors as the truth and the painter's ModelScene stamp model them: billboards or thick prisms."""
    if (mode or ACTOR_MODE) == "thick":
        return prism_faces(actors)
    return billboard_tris(actors, cam, billboard)


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
    # with the actors: their billboards (or prisms) depth tested against the room
    tr.actor_polys = []
    tr.actor_boxes = {}                                   # actor index -> pixel box (x0, y0, x1, y1) of its shape
    for k, pts3 in actor_shapes(cap.actors, cam, getattr(cap, "billboard", None), getattr(cap, "actor_mode", None)):
        P3 = np.array(pts3)
        cr, cu, cd = cam.to_cam(P3)
        cv = _clip_near([(cr[i], cu[i], cd[i], 0.0, 0.0) for i in range(len(P3))], near)
        if len(cv) < 3:
            continue
        pts = [((cam.cx + cam.f * q[0] / q[2]) * S, (cam.cy + cam.f * q[1] / q[2]) * S, 1.0 / q[2]) for q in cv]
        tr.actor_polys.append((k, pts))
        xs_, ys_ = [p[0] for p in pts], [p[1] for p in pts]
        b = tr.actor_boxes.get(k)
        nb = (min(xs_), min(ys_), max(xs_), max(ys_))
        tr.actor_boxes[k] = nb if b is None else (min(b[0], nb[0]), min(b[1], nb[1]), max(b[2], nb[2]),
                                                  max(b[3], nb[3]))
    zfull = zb.copy()
    idfull = idb.copy()
    _raster_depth(g, [(mesh.nt + k, pts) for k, pts in tr.actor_polys], zfull, idfull, S)
    tr.actor_visible = idfull >= mesh.nt
    # the actors among themselves (what the ModelScene draws): nearest actor per pixel
    za = np.zeros((g.Hp, g.Wp))
    ida = np.full((g.Hp, g.Wp), -1, dtype=np.int32)
    _raster_depth(g, tr.actor_polys, za, ida, S)
    tr.actor_only = ida
    tr.actor_invd = za                                    # 1/depth of the nearest actor (0: none)
    return tr


# ---------------------------------------------------------------------------------------------------------------
# which mesh triangle a painted region shows: from its own API data only
# ---------------------------------------------------------------------------------------------------------------
MATCH_TOL = MATCH_BASE + DEFAULT_TAU   # (the default; a capture's own is cap.match_tol = 1 + tau + dilate)


def match_regions(mesh, cap, rows_idx):
    """For the room regions rows_idx: the mesh triangle each one is a correctly placed piece of, or -1. A region is a
    piece of T when its texture file is T's, its four corner texture coordinates (UL, LL, UR, LR) lie inside T's
    texture triangle - or, when T has a quad mate M (mesh.mate), inside T's or M's - and the points they stand for
    (mapped back through the triangle whose texture triangle holds them), projected through the camera, land on the
    region's corners (within cap.match_tol = 1 + tau + dilate view units: a morphed midpoint or a Lua-clipped copy
    corner lies on a piece whose affine error is at most tau). A triangle's UR and LR are one corner; a quad texture
    (its second GPU triangle LL, LR, UR lies on M) is a piece of T's quad. -> (src array aligned with rows_idx, corner
    error)."""
    tol = getattr(cap, "match_tol", MATCH_TOL)
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
                   np.stack([l + w + o[:, 4], b + h + o[:, 5]], 1),       # UR
                   np.stack([l + w + o[:, 6], b + o[:, 7]], 1)], 1)       # LR      (n, 4, 2)
    tc = np.stack([rows[:, 10:12], rows[:, 12:14], rows[:, 14:16], rows[:, 16:18]], 1)      # (n, 4, 2)
    files = rows[:, 5].astype(np.int64)
    mate = getattr(mesh, "mate", None)
    if mate is None:
        mate = np.full(mesh.nt, -1, dtype=np.int64)
    has_m = mate >= 0
    mi_all = np.where(has_m, mate, np.arange(mesh.nt))
    # the texture box of a triangle, or of its quad (with its mate)
    uvmin_t, uvmax_t = mesh.uv.min(axis=1), mesh.uv.max(axis=1)
    uvmin_q = np.where(has_m[:, None], np.minimum(uvmin_t, uvmin_t[mi_all]), uvmin_t)
    uvmax_q = np.where(has_m[:, None], np.maximum(uvmax_t, uvmax_t[mi_all]), uvmax_t)
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
            cont = ((uvmin_q[ti][None, :, :] <= rmin[c0:c0 + 512][:, None, :] + eps).all(-1) &
                    (uvmax_q[ti][None, :, :] >= rmax[c0:c0 + 512][:, None, :] - eps).all(-1))
            pr, pc = np.nonzero(cont)
            if len(pr) == 0:
                continue
            rr, tt = rs[pr], ti[pc]
            X = np.concatenate([tc[rr], np.ones((len(rr), 4, 1))], axis=2)      # (m, 4, 3) corner [u, v, 1]
            beta = np.einsum("mij,mkj->mki", mesh.binv[tt], X)                  # (m, 4 corners, 3)
            in_t = (beta >= -eps).all(axis=2)                                   # (m, 4)
            mm = mi_all[tt]
            hm = has_m[tt] & mesh.uv_ok[mm]
            beta_m = np.einsum("mij,mkj->mki", mesh.binv[mm], X)
            in_m = hm[:, None] & (beta_m >= -eps).all(axis=2) & ~in_t           # (on T first)
            inside = (in_t | in_m).all(axis=1)
            if not inside.any():
                continue
            rr, tt, mm = rr[inside], tt[inside], mm[inside]
            beta, beta_m, in_m = beta[inside], beta_m[inside], in_m[inside]
            Q = np.einsum("mki,mij->mkj", beta, mesh.corners[tt])               # (m, 4, 3) arena points
            Qm = np.einsum("mki,mij->mkj", beta_m, mesh.corners[mm])
            Q = np.where(in_m[:, :, None], Qm, Q) * mirror                       # scene points
            qx, qy, qd = cap.cam.project(Q.reshape(-1, 3))
            qx, qy, qd = qx.reshape(-1, 4), qy.reshape(-1, 4), qd.reshape(-1, 4)
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
    src[err > tol] = -1
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
    pt.amb_same_node = np.zeros((g.Hp, g.Wp), dtype=bool)        # ties between room pieces of one BSP node
    pt.above_scene = np.zeros((g.Hp, g.Wp), dtype=bool)          # the room pixel was drawn above the ModelScene
    pt.line_cov = np.zeros((g.Hp, g.Wp), dtype=bool)             # some line was drawn here (whatever came later)
    own = np.full((g.Hp, g.Wp), -1, dtype=np.int64)              # entry painted last (for ties)
    own_kind = np.zeros((g.Hp, g.Wp), dtype=np.int8)             # its kind: 1 room, 2 scene, 3 line
    own_node = np.full((g.Hp, g.Wp), -1, dtype=np.int64)         # its BSP node (matched room regions; else -1)
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
    pt.below_scene = 0                                           # room textures at or under the ModelScene's level
    pt.copy_textures = 0                                         # room textures in frames above it (copies)
    pt.copy_lines = 0                                            # lines in frames above it
    pt.lines = 0
    node_of = getattr(mesh, "node_of", None)
    mate_of = getattr(mesh, "mate", None)
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

        def stamp(r0, c0, m, value, room, src_tri=-1, node=-1, mate_tri=-1):
            hh, ww = m.shape
            sl = (slice(r0, r0 + hh), slice(c0, c0 + ww))
            o, ok_, fk_, fi_, ls_, on_ = own[sl], own_kind[sl], fkey[sl], fid_[sl], lsk[sl], own_node[sl]
            tie = (o >= 0) & (o != n) & (fk_ == fk) & ((fi_ != fidx) | (ls_ == ls))
            lines_only = (ok_ == 3) & (my_kind == 3)
            same_node = (on_ == node) & (node >= 0)              # two matched room pieces of one BSP node
            pt.amb[sl][m] = (tie & ~lines_only & ~same_node)[m]
            pt.amb_lines[sl][m] = (tie & lines_only)[m]
            pt.amb_same_node[sl][m] = (tie & same_node)[m]
            o[m], ok_[m], fk_[m], fi_[m], ls_[m], on_[m] = n, my_kind, fk, fidx, ls, node
            if what == "line":
                pt.line_cov[sl][m] = True
            if room:
                pt.room_top[sl][m] = value
                pt.above_scene[sl][m] = above
                pt.kind[sl][m] = 1
                pt.full_top[sl][m] = value
                if src_tri >= 0:
                    own_t = tr.id[sl] == src_tri
                    if mate_tri >= 0:                            # a piece of a quad: either of its two triangles
                        own_t |= tr.id[sl] == mate_tri
                    pt.painted_truth[sl][m & own_t] = True
            else:
                pt.kind[sl][m] = 3 if what == "line" else 2
                pt.full_top[sl][m] = value

        if what == "room":
            row = R[i]
            if any(math.isnan(v) for v in row[18:22]):
                continue
            pt.shown_room += 1
            if above:
                pt.copy_textures += 1
            else:
                pt.below_scene += 1
            src_i = pt.region_src.get(i, -1)
            node_i = int(node_of[src_i]) if (node_of is not None and src_i >= 0) else -1
            mate_i = int(mate_of[src_i]) if (mate_of is not None and src_i >= 0) else -1
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
                stamp(r0, c0, m, tid, True, src_i, node_i, mate_i)
        elif what == "line":
            row = R[i]
            x1, y1, x2, y2 = row[18:22]
            if any(math.isnan(v) for v in (x1, y1, x2, y2)):
                continue
            pt.lines += 1
            if above:
                pt.copy_lines += 1
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
        # a piece of a quad shows either of its two triangles (the mate of the one it was matched to)
        mate = getattr(mesh, "mate", None)
        mates = np.full(n, -1, dtype=np.int64)
        if mate is not None:
            mates[matched] = mate[srcs[matched]]
        # matched regions: the triangle itself (or its quad mate) decides
        for dr, dc in [(0, 0)] + NEIGHBOURS:
            nb = _neighbour_ids(tr, g, rr, cc, dr, dc)
            right |= matched & ((nb == srcs) | ((mates >= 0) & (nb == mates)))
        idx = np.nonzero(matched & right)[0]
        if len(idx):
            # the texel mapped back through the triangle the truth shows at the pixel (of the two of a quad)
            tsel = srcs.copy()
            here = tr.id[rr, cc]
            sw = (mates >= 0) & (here == mates)
            tsel[sw] = mates[sw]
            ok, m_, v_ = _surface_test(mesh, cap.cam, cap.mirror, S, tsel[idx], uvp[idx], filep[idx], px[idx], py[idx],
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
    # actors: where their billboards are, is the actor visible in both? (pixels where the painter's top is a line -
    # a mark drawn over an actor - are left out)
    dom = (tr.actor_only >= 0) & (pt.kind != 3)
    nd = int(dom.sum())
    pvis = pt.kind == 2
    vis = tr.actor_visible
    err = dom & (pvis != vis)
    hid_w = dom & vis & ~pvis
    shw_w = dom & ~vis & pvis
    res.actor_err = err
    res["actorErrPct"] = 100.0 * int(err.sum()) / nd if nd else 0.0
    res["actorHiddenWronglyPct"] = 100.0 * int(hid_w.sum()) / nd if nd else 0.0
    res["actorShownWronglyPct"] = 100.0 * int(shw_w.sum()) / nd if nd else 0.0
    res["actorPx"] = nd
    # per unit: its pixels (where it is the nearest actor), hidden wrongly, shown wrongly, hidden by the truth
    by = {}
    if nd:
        ids = tr.actor_only[dom]
        hw_, sw_, th_ = hid_w[dom], shw_w[dom], ~vis[dom]
        for k in np.unique(ids):
            sel = ids == k
            px_ = int(sel.sum())
            uid = cap.actors[int(k)]["unit"] if int(k) < len(cap.actors) else -1
            e = by.setdefault(str(uid), dict(px=0, hiddenWrongly=0, shownWrongly=0, truthHidden=0))
            e["px"] += px_
            e["hiddenWrongly"] += int(hw_[sel].sum())
            e["shownWrongly"] += int(sw_[sel].sum())
            e["truthHidden"] += int(th_[sel].sum())
        for e in by.values():
            e["errPct"] = 100.0 * (e["hiddenWrongly"] + e["shownWrongly"]) / e["px"]
            e["truthHiddenPct"] = 100.0 * e["truthHidden"] / e["px"]
    res["actorErrByUnit"] = by
    res["ambiguousPct"] = pct(int(pt.amb.sum()))
    res["ambiguousLinesPct"] = pct(int(pt.amb_lines.sum()))
    res["ambiguousSameNodePct"] = pct(int(pt.amb_same_node.sum()))
    res["shownTextures"] = int(pt.shown_room)
    res["shownTexturesBelowScene"] = int(getattr(pt, "below_scene", pt.shown_room))
    res["copyTextures"] = int(getattr(pt, "copy_textures", 0))
    res["copyLines"] = int(getattr(pt, "copy_lines", 0))
    res["diagonalSensitiveQuads"] = int(pt.diag_sensitive)
    res["truthCoveredPct"] = 100.0 * covered / (g.Wp * g.Hp)
    res["matchTol"] = float(getattr(cap, "match_tol", MATCH_TOL))
    if getattr(cap, "has_tau", False):
        res["tau"] = float(cap.tau)
    if tr.seethrough is not None:
        res["seeThroughPct"] = 100.0 * int(tr.seethrough.sum()) / (g.Wp * g.Hp)
    lt = line_truth(cap, tr, pt, g, S)
    if lt is not None:
        res.update(lt)
    return res


def line_truth(cap, tr, pt, g, S):
    """The marks (cap.marks: 3D segments from UI._Marks, arena coordinates) against the painter. Each segment is
    clipped at the near plane, projected and sampled at 1 px steps (the 3D point of screen parameter s is
    t = s dA / ((1 - s) dB + s dA)). Truth: the sample is seen at a pixel when its 1/d is at least the room's and
    the actors' z-buffer there. Painter: a line is on top there. Over the sample's pixel and its 8 neighbours only
    pixels where the painter drew some line count: the sample is wrong when painter and truth disagree at every one
    of them; when no line was drawn at any of the 9, it is wrong when the truth sees it at all 9 (a missing line).
    -> {wrongLinePct, lineSamples, lineTruthVisiblePct, lineTruthHiddenPct} or None without the hook."""
    if getattr(cap, "marks", None) is None:
        return None
    cam, mirror, near = cap.cam, cap.mirror, cap.cam.near
    zr, za = tr.invd, tr.actor_invd
    total = wrong = seen = 0
    for sg in cap.marks:
        A = np.array([sg[0], mirror * sg[1], sg[2]], float)
        B = np.array([sg[3], mirror * sg[4], sg[5]], float)
        da, db = float(cam.to_cam(A)[2]), float(cam.to_cam(B)[2])
        if da < near and db < near:
            continue
        if da < near:
            A = A + (B - A) * ((near - da) / (db - da))
        elif db < near:
            B = B + (A - B) * ((near - db) / (da - db))
        xa, ya, da = cam.project(A)
        xb, yb, db = cam.project(B)
        xa, ya, xb, yb = xa * S, ya * S, xb * S, yb * S
        L = math.hypot(xb - xa, yb - ya)
        n = max(1, int(math.ceil(L)))
        s = (np.arange(n) + 0.5) / n
        t = s * da / ((1 - s) * db + s * da)
        P = A[None, :] + (B - A)[None, :] * t[:, None]
        invd = 1.0 / cam.to_cam(P)[2]
        px, py = xa + (xb - xa) * s, ya + (yb - ya) * s
        c, r = np.floor(px).astype(np.int64), np.floor(py).astype(np.int64)
        inb = (c >= 0) & (c < g.Wp) & (r >= 0) & (r < g.Hp)
        if not inb.any():
            continue
        c, r, invd = c[inb], r[inb], invd[inb]
        agree = np.zeros(len(c), bool)
        covered = np.zeros(len(c), bool)
        seen_all = np.ones(len(c), bool)
        seen_c = None
        for dr, dc in [(0, 0)] + NEIGHBOURS:
            r2, c2 = r + dr, c + dc
            ok = (r2 >= 0) & (r2 < g.Hp) & (c2 >= 0) & (c2 < g.Wp)
            r2c, c2c = np.clip(r2, 0, g.Hp - 1), np.clip(c2, 0, g.Wp - 1)
            tv = (invd >= zr[r2c, c2c]) & (invd >= za[r2c, c2c])
            if seen_c is None:
                seen_c = tv.copy()
            cov = ok & pt.line_cov[r2c, c2c]
            pv = pt.kind[r2c, c2c] == 3
            agree |= cov & (pv == tv)
            covered |= cov
            seen_all &= ~ok | tv
        bad = np.where(covered, ~agree, seen_all)
        total += len(c)
        wrong += int(bad.sum())
        seen += int(seen_c.sum())
    pc = (lambda k: 100.0 * k / total) if total else (lambda k: 0.0)
    return {"wrongLinePct": pc(wrong), "lineSamples": total, "lineTruthVisiblePct": pc(seen),
            "lineTruthHiddenPct": pc(total - seen) if total else 0.0}


def point_tri_dist(p, T):
    """Distances from point p (3,) to triangles T (n, 3, 3)."""
    p = np.asarray(p, float)
    a, b, c = T[:, 0], T[:, 1], T[:, 2]
    ab, ac, ap = b - a, c - a, p[None, :] - a

    def seg(a_, b_):
        d = b_ - a_
        dd = np.einsum("ij,ij->i", d, d)
        with np.errstate(divide="ignore", invalid="ignore"):
            t = np.clip(np.einsum("ij,ij->i", p[None, :] - a_, d) / dd, 0.0, 1.0)
        t = np.where(dd > 1e-18, t, 0.0)
        q = a_ + d * t[:, None]
        return np.linalg.norm(p[None, :] - q, axis=1)

    d00 = np.einsum("ij,ij->i", ab, ab)
    d01 = np.einsum("ij,ij->i", ab, ac)
    d11 = np.einsum("ij,ij->i", ac, ac)
    d20 = np.einsum("ij,ij->i", ap, ab)
    d21 = np.einsum("ij,ij->i", ap, ac)
    den = d00 * d11 - d01 * d01
    ok = np.abs(den) > 1e-18
    with np.errstate(divide="ignore", invalid="ignore"):
        v = (d11 * d20 - d01 * d21) / den
        w = (d00 * d21 - d01 * d20) / den
    inside = ok & (v >= 0) & (w >= 0) & (v + w <= 1)
    nrm = np.cross(ab, ac)
    nn = np.linalg.norm(nrm, axis=1)
    with np.errstate(divide="ignore", invalid="ignore"):
        dplane = np.abs(np.einsum("ij,ij->i", ap, nrm)) / nn
    dedge = np.minimum(np.minimum(seg(a, b), seg(b, c)), seg(c, a))
    return np.where(inside, dplane, dedge)


def cam_min_dist(mesh, cap):
    """The smallest distance (yd) from the camera to any room triangle (scene = (x, mirror * y, z))."""
    T = mesh.corners * np.array([1.0, cap.mirror, 1.0])
    return float(point_tri_dist(cap.cam.C, T).min())


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


class PreconditionError(AssertionError):
    """A v2 pose does not show what it was made for (spec 9.2.10: it fails loudly)."""


class RunCfg:
    """One run: its name, the render options (None = the renderer's own; applied only through UI._RenderOpts), the
    sets it measures in that order (P = the 26 poses, N = the 7 v2 poses, W = the walk, AW = the actor walk), how the
    actors are modelled, warm-up frames before each pose (+-0.002 rad turns), idle frames after each pose (3 frames
    with nothing moving), bench mode (null setters, timing only), and which poses (None = all)."""

    def __init__(self, name="default", opts=None, sets=("P", "N", "W", "AW"), actors=None, billboard=None, warmup=0,
                 idle=False, bench=False, poses=None, quick=False, walk_frames=None, aw_frames=None):
        self.name, self.opts, self.sets = name, opts, tuple(sets)
        self.actors, self.billboard = actors or ACTOR_MODE, billboard or BILLBOARD
        self.warmup, self.idle, self.bench = warmup, idle, bench
        self.poses, self.quick = poses, quick
        self.walk_frames, self.aw_frames = walk_frames, aw_frames


class Session:
    def __init__(self, enc, size, scale, billboard=None, actors=None, opts=None):
        self.enc = enc
        self.size = size
        self.S = scale
        self.billboard = billboard or BILLBOARD
        self.actor_mode = actors or ACTOR_MODE
        self.w, self.c = boot_trainer(enc, size)
        self.mesh = Mesh.from_text(self.c.eval("return __RC.mesh('%s')" % enc))
        self.g = Grid(int(round(size[0] * scale)), int(round(size[1] * scale)))
        self.gens = self.c.eval_py("local t = {} for _, g in ipairs(ns.TrainerUI._Sim().generators or {}) do "
                                   "t[#t+1] = { g.x, g.y } end return t") or []
        self.hooks = set((self.c.eval("return __RC.hooks()") or "").split())
        self.opts_now = {}               # what render_check set through UI._RenderOpts
        self.opts_applied = None         # None: no options asked; True / False: applied / no hook
        self.nframes = 0                 # counted frames of this session
        self.setparent = []              # (frame, SetParent calls) of every counted frame with any
        self.order_bad = []              # (frame, summary) of frames that broke an order invariant
        self.order_checked = 0
        self.last_order = None
        self._tick = None
        if opts:
            self.opts_applied = self.set_opts(opts)
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
        cap = Capture(self.c.eval("return __RC.capture_trainer()"), *self.size)
        cap.billboard, cap.actor_mode = self.billboard, self.actor_mode
        return cap

    def pose(self, x, y, facing, pitch, dist):
        self.c.eval("__RC.pose(%.10g, %.10g, %.10g, %.10g, %.10g)" % (x, y, facing, pitch, dist))

    def frame(self, dt=0.001):
        """One counted panel tick: -> (API calls by name, ms). Also tracks SetParent and the order invariants."""
        t0 = time.perf_counter()
        s = self.c.eval("return __RC.counted_tick(%.10g)" % dt)
        ms = (time.perf_counter() - t0) * 1000
        counts = {}
        for part in (s or "").split():
            k, _, v = part.partition("=")
            counts[k] = int(v)
        self.nframes += 1
        if counts.get("SetParent", 0):
            self.setparent.append((self.nframes, counts["SetParent"]))
        self.check_order()
        return counts, ms

    def bench_frame(self, dt=0.001):
        """One panel tick, timed, without counting (the setters may be no-ops: M.null_setters)."""
        if self._tick is None:
            self._tick = self.c.eval("return ns.TrainerUI._Tick")
        t0 = time.perf_counter()
        self._tick(dt)
        ms = (time.perf_counter() - t0) * 1000
        self.nframes += 1
        return ms

    def check_order(self):
        """The order invariants after a frame, when UI._Order has the v2 fields (else None)."""
        if "_Order" not in self.hooks:
            self.last_order = None
            return None
        s = self.c.eval("return __RC.order_summary()")
        if not s:
            self.last_order = None
            return None
        v = [int(x) for x in s.split()]
        o = dict(nodes=v[0], distinct=v[1], wrong=v[2], badLines=v[3], lines=v[4], pieces=v[5])
        self.order_checked += 1
        if o["wrong"] != 0 or o["distinct"] != o["nodes"] or o["badLines"] != 0:
            self.order_bad.append((self.nframes, o))
        self.last_order = o
        return o

    def set_opts(self, opts):
        """Render options through UI._RenderOpts. -> False when the hook does not exist."""
        if "_RenderOpts" not in self.hooks:
            return False
        ok = self.c.eval("return __RC.set_opts(...)", dict(opts))
        self.opts_now.update(opts)
        return bool(ok)

    def null_setters(self, on):
        return self.c.eval("return __RC.null_setters(%s)" % ("true" if on else "false"))

    def place_unit(self, kind, index, x, y):
        return self.c.eval("return __RC.place_unit('%s', %d, %.10g, %.10g)" % (kind, index, x, y))

    def save_units(self):
        self.c.eval("__RC.save_units()")

    def restore_units(self):
        self.c.eval("__RC.restore_units()")

    def add_mark(self, x, y, r, column):
        return self.c.eval("return __RC.add_mark(%.10g, %.10g, %.10g, %.10g)" % (x, y, r, column))

    def clear_marks(self):
        self.c.eval("__RC.clear_marks()")

    def camera(self):
        """-> [x, y, z, fx, fy, fz, mirror, cur, dist, pitch] (scene coordinates)."""
        return self.c.eval_py("return __RC.camera()")

    def render_stats(self):
        return self.c.eval_py("return __RC.render_stats()")

    def occluders(self):
        return self.c.eval_py("return __RC.occluders()")

    def marks(self):
        return self.c.eval_py("return __RC.marks()")

    def cam_min_dist(self, cap=None):
        return cam_min_dist(self.mesh, cap or self.capture())


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


def _png_dir(args, cfg):
    """Where a run's pictures go: OUT for the default run and R1, OUT/<run> for the others, none for the bench."""
    if not args.png or cfg.bench:
        return None
    if cfg.name in ("default", "R1"):
        return args.png
    d = os.path.join(args.png, cfg.name)
    os.makedirs(d, exist_ok=True)
    return d


def _save_pose_pictures(sess, png, enc, name, note, rec, cap, tr, pt, res, full=True):
    base = os.path.join(png, "%s_%s" % (enc, name))
    pimg, timg, dimg = picture_painter(sess.mesh, cap, pt, sess.g), picture_truth(sess.mesh, tr, sess.g), \
        picture_diff(res, pt, tr, sess.g)
    if full:
        save_png(base + "_painter.png", pimg)
        save_png(base + "_truth.png", timg)
        save_png(base + "_diff.png", dimg)
    save_sheet(base + "_sheet.png", "%s / %s: %s" % (enc, name, note), [metric_line(rec)], pimg, timg, dimg)


def measure_pose(sess, cfg, enc, setname, name, x, y, facing, pitch, dist, note):
    """Reach the pose from a 0.004 rad turn (plus the run's warm-up turns) and analyse the frame."""
    sess.pose(x, y, facing + 0.004, pitch, dist)
    sess.frame()
    for k in range(cfg.warmup):
        sess.pose(x, y, facing + (0.002 if k % 2 == 0 else -0.002), pitch, dist)
        sess.frame()
    sess.pose(x, y, facing, pitch, dist)
    counts, ms = sess.frame()
    cap = sess.capture()
    tr, pt, res = analyse(sess, cap, backfaces=True)
    total, main = summarize_api(counts)
    rec = dict(enc=enc, run=cfg.name, set=setname, pose=name, note=note, x=x, y=y, facing=facing, pitch=pitch,
               dist=dist)
    rec.update({k: v for k, v in res.items()})
    rec["apiCallsPerFrame"] = total
    rec["api"] = main
    rec["luaMsPerFrame"] = ms
    rec["order"] = sess.last_order
    rec["sessionFrame"] = sess.nframes
    if cap.player and (abs(cap.player[0] - x) > 1e-6 or abs(cap.player[1] - y) > 1e-6):
        rec["warning"] = "the sim moved the player to %.2f, %.2f" % cap.player[:2]
    return rec, cap, tr, pt, res


def idle_frames(sess, cfg, enc, name, n=3):
    """n frames with nothing moving (dt 0: the sim does not step, the camera does not move)."""
    out = []
    for k in range(n):
        if cfg.bench:
            counts, ms = {}, sess.bench_frame(0.0)
        else:
            counts, ms = sess.frame(0.0)
        total, main = summarize_api(counts)
        out.append(dict(enc=enc, run=cfg.name, set="idle", pose=name, frame=k, apiCallsPerFrame=total, api=main,
                        luaMsPerFrame=ms))
    return out


def _overlap(a, b):
    return a is not None and b is not None and a[0] <= b[2] and b[0] <= a[2] and a[1] <= b[3] and b[1] <= a[3]


def check_precondition(sess, spec, rec, cap, tr, res):
    """-> (ok, message, skipped) for a v2 pose's precondition on its measured frame."""
    kind = spec.get("pre")
    by = res.get("actorErrByUnit", {})
    units = rec.get("units", {})

    def unit(key):
        return by.get(str(units.get(key)), dict(px=0, truthHidden=0, hiddenWrongly=0, shownWrongly=0))

    boxes = {}
    for k, bx in getattr(tr, "actor_boxes", {}).items():
        if k < len(cap.actors):
            boxes[cap.actors[k]["unit"]] = bx
    if kind == "chain":
        e1, e2 = unit("raider1"), unit("raider2")
        px = e1["px"] + e2["px"]
        frac = (e1["truthHidden"] + e2["truthHidden"]) / px if px else 0.0
        b3 = boxes.get(units.get("raider3"))
        ov = _overlap(b3, boxes.get(units.get("raider1"))) or _overlap(b3, boxes.get(units.get("raider2")))
        ok = px > 0 and frac >= 0.30 and ov
        return ok, "truth hides %.1f%% of raiders 1-2 (want >= 30%%); raider 3's box overlaps raider 1's or 2's: %s" % (
            100 * frac, ov), False
    if kind == "boss":
        e = unit("boss1")
        frac = e["truthHidden"] / e["px"] if e["px"] else 0.0
        ok = e["px"] > 0 and 0.20 <= frac <= 0.70
        return ok, "truth hides %.1f%% of the boss (want 20-70%%)" % (100 * frac), False
    if kind == "steep":
        ef, eb = unit("front"), unit("behind")
        ok = ef["px"] >= 10 and eb["px"] >= 10
        msg = "raider in front: %d px, raider behind: %d px on screen (want >= 10 each)" % (ef["px"], eb["px"])
        if "_Occluders" in sess.hooks:
            fam = {}
            for o in sess.occluders() or []:
                if isinstance(o, dict):
                    fam[o.get("id")] = o.get("family")
            ff, fb = fam.get(units.get("front")), fam.get(units.get("behind"))
            ok = ok and ff == "A" and fb == "B"
            msg += "; families %s / %s (want A / B)" % (ff, fb)
        else:
            msg += "; families not checked (no UI._Occluders)"
        return ok, msg, False
    if kind == "generator":
        e = unit("generator1")
        frac = e["truthHidden"] / e["px"] if e["px"] else 0.0
        ok = e["px"] > 0 and 0.10 <= frac <= 0.90
        return ok, "truth hides %.1f%% of the generator (want 10-90%%)" % (100 * frac), False
    if kind == "grazing":
        d = rec.get("camMinDist", float("inf"))
        return d <= 0.8, "the camera is %.2f yd from the nearest room triangle (want <= 0.8)" % d, False
    if kind == "ring":
        if cap.marks is None:
            return True, "not checked: no UI._Marks (the line truth needs it)", True
        v, h = res.get("lineTruthVisiblePct", 0.0), res.get("lineTruthHiddenPct", 0.0)
        return (v >= 10 and h >= 10 and res.get("lineSamples", 0) > 0,
                "line truth: %.1f%% of %d samples visible, %.1f%% hidden (want >= 10%% each)" % (
                    v, res.get("lineSamples", 0), h), False)
    return True, "", False


def run_new_pose(sess, cfg, enc, spec, png):
    """A v2 pose: move units / add marks / set its own options, measure, check the precondition, put it all back."""
    name = spec["name"]
    sess.save_units()
    restore = {}
    try:
        if spec.get("opts") and "_RenderOpts" in sess.hooks:
            for k in spec["opts"]:
                restore[k] = sess.opts_now.get(k, OPT_DEFAULTS.get(k))
            sess.set_opts(spec["opts"])
        units = {}
        for kind, idx, ux, uy in spec.get("units", ()):
            uid = sess.place_unit(kind, idx, ux, uy)
            if uid is None:
                raise PreconditionError("%s/%s: there is no living %s number %d" % (enc, name, kind, idx))
            units["%s%d" % (kind, idx)] = uid
        if spec.get("steep"):
            # the camera's ground point at this pose: one raider 1.0 yd in front of it, one 0.15 yd behind it
            sess.pose(spec["x"], spec["y"], spec["facing"], spec["pitch"], spec["dist"])
            sess.frame()
            cm = sess.camera()
            gx, gy = cm[0], cm[1] * cm[6]
            fx, fy = math.cos(spec["facing"]), math.sin(spec["facing"])
            units["front"] = sess.place_unit("raider", 1, gx + fx * 1.0, gy + fy * 1.0)
            units["behind"] = sess.place_unit("raider", 2, gx - fx * 0.15, gy - fy * 0.15)
            if units["front"] is None or units["behind"] is None:
                raise PreconditionError("%s/%s: needs two living raiders" % (enc, name))
        for mk in spec.get("marks", ()):
            sess.add_mark(*mk)
        rec, cap, tr, pt, res = measure_pose(sess, cfg, enc, "N", name, spec["x"], spec["y"], spec["facing"],
                                             spec["pitch"], spec["dist"], spec["note"])
        rec["units"] = units
        rec["camMinDist"] = cam_min_dist(sess.mesh, cap)
        ok, msg, skipped = check_precondition(sess, spec, rec, cap, tr, res)
        rec["precondition"] = msg
        rec["preconditionSkipped"] = skipped
        rec["preconditionOk"] = bool(ok)
        if png:
            _save_pose_pictures(sess, png, enc, name, spec["note"], rec, cap, tr, pt, res, full=cfg.name in
                                ("default", "R1"))
        print_row(rec)
        if not ok:
            raise PreconditionError("%s/%s: precondition failed: %s" % (enc, name, msg))
        return rec
    finally:
        sess.clear_marks()
        sess.restore_units()
        if restore:
            sess.set_opts(restore)


def pose_lists(enc, cfg):
    """The P and N pose specs of a run (filtered by --quick / --poses)."""
    P = list(POSES[enc])
    N = list(NEW_POSES[enc])
    if cfg.quick:
        P = [p for p in P if p[0] in QUICK_POSES[enc]]
        N = []
    if cfg.poses:
        want = set(cfg.poses)
        P = [p for p in P if p[0] in want]
        N = [p for p in N if p["name"] in want]
    return P, N


def run_encounter(enc, args, out=None, cfg=None):
    """Run one configuration on one room. -> (pose records, walk aggregates) for the default run; the full per-set
    data is in the returned records' "set" fields and in run_config()."""
    cfg = cfg or default_cfg(args)
    ed = run_config(enc, args, cfg)
    results = ed.get("P", []) + ed.get("N", [])
    walks = [ed[k] for k in ("W", "AW") if ed.get(k)]
    if out is not None:
        out.extend(results)
    return results, walks


def run_config(enc, args, cfg, errors=None):
    """Run the sets of cfg on one room in a fresh session. -> {P: [...], N: [...], W: agg, AW: agg, idle: [...],
    session: {...}}. Precondition failures raise, unless errors is a list (then they are collected there)."""
    size = tuple(int(v) for v in args.size.lower().split("x"))
    sess = Session(enc, size, args.scale, billboard=cfg.billboard, actors=cfg.actors, opts=cfg.opts)
    png = _png_dir(args, cfg)
    ed = dict(P=[], N=[], idle=[])
    if cfg.bench:
        sess.null_setters(True)
    try:
        P, N = pose_lists(enc, cfg)
        for s in cfg.sets:
            if s == "P":
                for spec in P:
                    name, x, y, facing, pitch, dist, note = resolve_pose(sess, spec)
                    if cfg.bench:
                        ed["P"].append(bench_pose(sess, cfg, enc, name, x, y, facing, pitch, dist))
                    else:
                        t0 = time.perf_counter()
                        rec, cap, tr, pt, res = measure_pose(sess, cfg, enc, "P", name, x, y, facing, pitch, dist,
                                                             note)
                        if png:
                            _save_pose_pictures(sess, png, enc, name, note, rec, cap, tr, pt, res,
                                                full=cfg.name in ("default", "R1"))
                        print_row(rec)
                        rec["seconds"] = time.perf_counter() - t0
                        ed["P"].append(rec)
                    if cfg.idle:
                        ed["idle"].extend(idle_frames(sess, cfg, enc, name))
            elif s == "N" and not cfg.bench:
                for spec in N:
                    try:
                        ed["N"].append(run_new_pose(sess, cfg, enc, spec, png))
                    except PreconditionError as e:
                        if errors is None:
                            raise
                        print("!! %s" % e, flush=True)
                        errors.append(dict(run=cfg.name, enc=enc, pose=spec["name"], error=str(e)))
            elif s == "W":
                ed["W"] = bench_walk(sess, enc, args, cfg) if cfg.bench else run_walk(sess, enc, args, cfg)
            elif s == "AW":
                ed["AW"] = bench_actor_walk(sess, enc, args, cfg) if cfg.bench else run_actor_walk(sess, enc, args,
                                                                                                    cfg)
    finally:
        if cfg.bench:
            sess.null_setters(False)
    ed["session"] = dict(hooks=sorted(sess.hooks), optsApplied=sess.opts_applied, frames=sess.nframes,
                         setParentFrames=sess.setparent, orderChecked=sess.order_checked,
                         orderBad=[dict(frame=f, **o) for f, o in sess.order_bad])
    return ed


def default_cfg(args):
    sets = ["P"] + ([] if (args.no_new or args.quick) else ["N"]) + ([] if args.no_walk else ["W", "AW"])
    return RunCfg("default", None, sets, actors=args.actors, billboard=args.billboard,
                  poses=args.poses.split(",") if args.poses else None, quick=args.quick)


def _walk_path(wk, frames):
    """The walk's poses: (x, y, facing) per frame."""
    x, y, f = wk["x"], wk["y"], wk["facing"]
    out = []
    for k in range(frames):
        if k > 0:
            if k >= wk["turnAfter"]:
                f += wk["turn"]
            x += math.cos(f) * wk["step"]
            y += math.sin(f) * wk["step"]
        out.append((x, y, f))
    return out


def _walk_frames(args, cfg, default):
    if cfg.walk_frames:
        return cfg.walk_frames
    return 8 if (args.quick or cfg.quick) else default


def run_walk(sess, enc, args, cfg=None):
    cfg = cfg or default_cfg(args)
    wk = dict(WALKS[enc])
    frames = _walk_frames(args, cfg, wk["frames"])
    prev = None
    pops, pops99, flicks = [], [], []
    per = []
    worst = (-1.0, None)
    keep = {}
    want = {0, frames // 2, frames - 1}
    png = _png_dir(args, cfg)
    camdt = "_RenderOpts" in sess.hooks
    if camdt:
        sess.set_opts({"camDt": wk["step"] / 7.0})
    try:
        path = _walk_path(wk, frames)
        sess.pose(path[0][0], path[0][1], path[0][2] + 0.004, wk["pitch"], wk["dist"])
        sess.frame()
        for k, (x, y, f) in enumerate(path):
            sess.pose(x, y, f, wk["pitch"], wk["dist"])
            counts, ms = sess.frame()
            cap = sess.capture()
            tr, pt, res = analyse(sess, cap)
            total, main = summarize_api(counts)
            cur = dict(id=tr.id, cls=res.cls, vec=res.vec)
            rec = {kk: v for kk, v in res.items()}
            rec.update(frame=k, x=x, y=y, facing=f, apiCallsPerFrame=total, api=main, luaMsPerFrame=ms,
                       order=sess.last_order, sessionFrame=sess.nframes)
            if prev is not None:
                pm, p99, fl = stability(prev, cur)
                rec.update(popMaxPx=pm, popP99Px=p99, flickerPct=fl)
                pops.append(pm)
                pops99.append(p99)
                flicks.append(fl)
                if pm > worst[0]:
                    worst = (pm, k)
            per.append(rec)
            if png:
                keep[k] = (cap, tr, pt, res, cur)
                hold = want | {k}
                if worst[1] is not None:
                    hold |= {worst[1], worst[1] - 1}
                for old in list(keep):
                    if old not in hold:
                        del keep[old]
            prev = cur
    finally:
        if camdt:
            sess.set_opts({"camDt": False})
    agg = dict(enc=enc, run=cfg.name, set="W", pose="walk", note=wk["note"], frames=frames)
    for key in ("wrongSurfacePct", "wrongPaintedOverPct", "wrongOverAboveScenePct", "wrongMissingPct", "holesPct",
                "extraPct", "misplacementP95px", "misplacementP99px", "misplacementMaxPx", "actorErrPct",
                "ambiguousPct", "ambiguousLinesPct", "ambiguousSameNodePct", "shownTextures",
                "shownTexturesBelowScene", "copyTextures", "apiCallsPerFrame", "luaMsPerFrame"):
        vals = [r[key] for r in per]
        agg[key] = float(np.mean(vals))
        agg[key + "_max"] = float(np.max(vals))
    if any("wrongLinePct" in r for r in per):
        vals = [r.get("wrongLinePct", 0.0) for r in per]
        agg["wrongLinePct"], agg["wrongLinePct_max"] = float(np.mean(vals)), float(np.max(vals))
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
    agg["perFrame"] = [_round_rec(r) for r in per]
    if png:
        for k in sorted(kk for kk in keep if kk in want):
            cap, tr, pt, res, _ = keep[k]
            pimg, timg, dimg = (picture_painter(sess.mesh, cap, pt, sess.g), picture_truth(sess.mesh, tr, sess.g),
                                picture_diff(res, pt, tr, sess.g))
            save_sheet(os.path.join(png, "%s_walk%02d_sheet.png" % (enc, k)), "%s / walk frame %d" % (enc, k),
                       [metric_line(per[k])], pimg, timg, dimg)
        wk_ = worst[1]
        if wk_ is not None and wk_ in keep and wk_ - 1 in keep:
            cap0, tr0, pt0, res0, cur0 = keep[wk_ - 1]
            cap1, tr1, pt1, res1, cur1 = keep[wk_]
            p0 = picture_painter(sess.mesh, cap0, pt0, sess.g)
            p1 = picture_painter(sess.mesh, cap1, pt1, sess.g)
            save_sheet(os.path.join(png, "%s_walk_pop_sheet.png" % enc),
                       "%s / the largest pop of the walk: frame %d -> %d (%.1f px)" % (enc, wk_ - 1, wk_, worst[0]),
                       [metric_line(per[wk_])], p0, p1, picture_pop(cur0, cur1, sess.g),
                       labels=("PAINTER frame %d" % (wk_ - 1), "PAINTER frame %d (0.25 yd further)" % wk_,
                               "how far each pixel's texel jumped between them (white = 12+ px; dark = edge)"))
    print_row(agg)
    return agg


def _round_rec(r):
    return {kk: (round(v, 4) if isinstance(v, float) else v) for kk, v in r.items()}


def _set_raider(sess, aw, x, y):
    sess.c.eval("local r = ns.TrainerUI._Sim():Alive('raider')[%d] if r then r.x, r.y, r.goal = %.10g, %.10g, nil end"
                % (aw["raider"], x, y))


def run_actor_walk(sess, enc, args, cfg=None):
    """The view stands still, a raider walks: what the occlusion pass makes of it, frame by frame."""
    cfg = cfg or default_cfg(args)
    aw = ACTOR_WALKS[enc]
    frames = cfg.aw_frames or (9 if (args.quick or cfg.quick) else aw["frames"])
    png = _png_dir(args, cfg)
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
        _set_raider(sess, aw, x, y)
        counts, ms = sess.frame()
        cap = sess.capture()
        tr, pt, res = analyse(sess, cap)
        total, main = summarize_api(counts)
        cur = dict(id=tr.id, cls=res.cls, vec=res.vec)
        rec = {kk: v for kk, v in res.items()}
        rec.update(frame=k, raiderX=x, raiderY=y, apiCallsPerFrame=total, api=main, luaMsPerFrame=ms,
                   order=sess.last_order, sessionFrame=sess.nframes)
        if prev is not None:
            pm, p99, fl = stability(prev, cur)
            rec.update(popMaxPx=pm, popP99Px=p99, flickerPct=fl)
            flicks.append(fl)
        bad = rec["actorErrPct"] + rec["wrongSurfacePct"]
        if png and bad > worst[0]:
            worst = (bad, k, (cap, tr, pt, res))
        per.append(rec)
        prev = cur
    agg = dict(enc=enc, run=cfg.name, set="AW", pose="actor_walk", note=aw["note"], frames=frames)
    for key in ("wrongSurfacePct", "wrongPaintedOverPct", "wrongOverAboveScenePct", "wrongMissingPct", "holesPct",
                "extraPct", "misplacementP95px", "misplacementP99px", "misplacementMaxPx", "actorErrPct",
                "actorHiddenWronglyPct", "actorShownWronglyPct", "ambiguousPct", "ambiguousLinesPct",
                "ambiguousSameNodePct", "shownTextures", "shownTexturesBelowScene", "copyTextures", "apiCallsPerFrame",
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
    agg["perFrame"] = [_round_rec(r) for r in per]
    if png and worst[1] is not None:
        cap, tr, pt, res = worst[2]
        save_sheet(os.path.join(png, "%s_actor_walk_worst_sheet.png" % enc),
                   "%s / actor walk, its worst frame %d: %s" % (enc, worst[1], aw["note"]), [metric_line(per[worst[1]])],
                   picture_painter(sess.mesh, cap, pt, sess.g), picture_truth(sess.mesh, tr, sess.g),
                   picture_diff(res, pt, tr, sess.g))
    print_row(agg)
    return agg


# ---------------------------------------------------------------------------------------------------------------
# bench (spec 9.2.12 / section 11): null setters, no image analysis, the wall time of each UI._Tick
# ---------------------------------------------------------------------------------------------------------------
def _ms_stats(vals):
    return dict(n=len(vals), mean=float(np.mean(vals)) if vals else 0.0, max=float(np.max(vals)) if vals else 0.0,
                frames=[round(v, 3) for v in vals])


def bench_pose(sess, cfg, enc, name, x, y, facing, pitch, dist):
    sess.pose(x, y, facing + 0.004, pitch, dist)
    sess.bench_frame()
    for k in range(cfg.warmup):
        sess.pose(x, y, facing + (0.002 if k % 2 == 0 else -0.002), pitch, dist)
        sess.bench_frame()
    sess.pose(x, y, facing, pitch, dist)
    ms = sess.bench_frame()
    rec = dict(enc=enc, run=cfg.name, set="P", pose=name, luaMsPerFrame=ms)
    print("%-6s %-6s %-22s bench %7.2f ms" % (cfg.name, enc, name, ms), flush=True)
    return rec


def bench_walk(sess, enc, args, cfg):
    wk = dict(WALKS[enc])
    frames = _walk_frames(args, cfg, wk["frames"])
    camdt = "_RenderOpts" in sess.hooks
    if camdt:
        sess.set_opts({"camDt": wk["step"] / 7.0})
    ms = []
    try:
        path = _walk_path(wk, frames)
        sess.pose(path[0][0], path[0][1], path[0][2] + 0.004, wk["pitch"], wk["dist"])
        sess.bench_frame()
        for x, y, f in path:
            sess.pose(x, y, f, wk["pitch"], wk["dist"])
            ms.append(sess.bench_frame())
    finally:
        if camdt:
            sess.set_opts({"camDt": False})
    agg = dict(enc=enc, run=cfg.name, set="W", pose="walk", frames=frames, bench=_ms_stats(ms),
               luaMsPerFrame=float(np.mean(ms)))
    print("%-6s %-6s %-22s bench mean %6.2f ms  max %6.2f ms" % (cfg.name, enc, "walk", agg["bench"]["mean"],
                                                                agg["bench"]["max"]), flush=True)
    return agg


def bench_actor_walk(sess, enc, args, cfg):
    aw = ACTOR_WALKS[enc]
    frames = cfg.aw_frames or (9 if (args.quick or cfg.quick) else aw["frames"])
    px_, py_, pf = aw["player"]
    sess.pose(px_, py_, pf + 0.004, aw["pitch"], aw["dist"])
    sess.bench_frame()
    sess.pose(px_, py_, pf, aw["pitch"], aw["dist"])
    sess.bench_frame()
    (x0, y0), (x1, y1) = aw["path"]
    ms = []
    for k in range(frames):
        t = k / max(1, frames - 1)
        _set_raider(sess, aw, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)
        ms.append(sess.bench_frame())
    agg = dict(enc=enc, run=cfg.name, set="AW", pose="actor_walk", frames=frames, bench=_ms_stats(ms),
               luaMsPerFrame=float(np.mean(ms)))
    print("%-6s %-6s %-22s bench mean %6.2f ms  max %6.2f ms" % (cfg.name, enc, "actor_walk", agg["bench"]["mean"],
                                                                agg["bench"]["max"]), flush=True)
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
# the gate (spec section 10)
# ---------------------------------------------------------------------------------------------------------------
R1_OPTS = dict(tau=2.0, adaptive=False, adaptiveTime=False, hardCap=8000, morph=True, copies=True, collision=True,
               siblingQuads=False)
GATE_RUNS = [
    ("R1", dict(opts=R1_OPTS, sets=("P", "N", "W", "AW"))),
    ("R2", dict(opts={"adaptiveTime": False}, sets=("P", "W", "AW"), warmup=6, idle=True)),
    ("R3", dict(opts=R1_OPTS, sets=("P", "N"), actors="thick")),
    ("R4", dict(opts=dict(R1_OPTS, collision=False), sets=("P",))),
    ("R5", dict(opts=dict(R1_OPTS, morph=False), sets=("W",))),
    ("Bench", dict(opts={"adaptiveTime": False}, sets=("W", "AW", "P"), warmup=6, idle=True, bench=True)),
]
RUN_NAMES = [n for n, _ in GATE_RUNS]
# the runs each criterion reads (8: every run but the bench, which counts no API calls; 11: no run, the suites)
CRITERIA_RUNS = {1: ("R1", "R2", "R4"), 2: ("R1",), 3: ("R1", "R2", "R4", "R5"), 4: ("R1", "R5"), 5: ("R1",),
                 6: ("R3",), 7: ("R1",), 8: ("R1", "R2", "R3", "R4", "R5"), 9: ("R2",), 10: ("Bench", "R2"), 11: ()}
CRITERIA_NAMES = {1: "order and coverage", 2: "see-through", 3: "accuracy", 4: "stability", 5: "actors (billboards)",
                  6: "actors (thick)", 7: "marks", 8: "order invariants", 9: "budget", 10: "Lua time",
                  11: "suites and static checks"}
BASELINE_LUA_MS = {"teron": 12.9, "vashj": 23.2}       # spec 10.10: the v1 walk's mock ms (findings.md)
SUITES = ["tests/games/test_trainer.py", "tests/games/test_trainer_vashj.py", "tests/games/test_render_check.py",
          "tests/boot-ui/test_boot.py"]


class Gate:
    def __init__(self):
        self.rows = []

    def add(self, crit, check, run, value, limit, ok, where="", note="", skipped=False):
        status = "SKIPPED" if skipped else ("PASS" if ok else "FAIL")
        self.rows.append(dict(crit=crit, check=check, run=run, value=value, limit=limit, status=status, where=where,
                              note=note))

    def skip(self, crit, check, run, why):
        self.add(crit, check, run, None, "", False, note=why, skipped=True)

    def le(self, crit, check, run, value, limit, where="", note=""):
        self.add(crit, check, run, value, "<= %g" % limit, value is not None and value <= limit + 1e-12, where, note)

    def summary(self, criteria):
        out = {}
        for c in criteria:
            st = [r["status"] for r in self.rows if r["crit"] == c]
            if not st:
                out[c] = "NOT RUN"
            elif "FAIL" in st:
                out[c] = "FAIL"
            elif "SKIPPED" in st:
                out[c] = "SKIPPED"
            else:
                out[c] = "PASS"
        return out


def _frames(rd, sets):
    """Every analysed frame of these sets in run data rd: [(label, record)]."""
    out = []
    for enc, ed in rd["encs"].items():
        for s in sets:
            if s in ("P", "N"):
                out.extend(("%s/%s" % (enc, r["pose"]), r) for r in ed.get(s, []))
            elif s in ("W", "AW") and ed.get(s) and "perFrame" in ed[s]:
                out.extend(("%s/%s#%d" % (enc, ed[s]["pose"], r["frame"]), r) for r in ed[s]["perFrame"])
    return out


def _worst(frames, key, default=0.0):
    best, where = None, ""
    for label, r in frames:
        v = r.get(key)
        if v is None:
            continue
        if best is None or v > best:
            best, where = v, label
    return (default if best is None else best), where


def evaluate_gate(runs, criteria, baseline=None, suites=None):
    """runs: {name: run data} -> Gate with one row per check."""
    G = Gate()

    def has(name):
        return name in runs

    def hooks(name):
        return set(runs[name].get("hooks", ())) if has(name) else set()

    # 1. order and coverage
    if 1 in criteria:
        lim = [("wrongSurfacePct", 0.02), ("wrongPaintedOverPct", 0.01), ("wrongOverAboveScenePct", 0.005),
               ("wrongMissingPct", 0.01), ("holesPct", 0.01), ("extraPct", None), ("ambiguousPct", 0.0049999),
               ("ambiguousLinesPct", 0.3)]
        for rn in ("R1", "R2", "R4"):
            if not has(rn):
                continue
            fr = _frames(runs[rn], ("P", "N", "W", "AW"))
            dil = (runs[rn].get("opts") or {}).get("dilate", 0) or 0
            for key, L in lim:
                if L is None:
                    L = 0.3 if dil > 0 else 0.05
                v, wh = _worst(fr, key)
                if key == "ambiguousPct":
                    G.add(1, key + " (all frames) = 0.00", rn, v, "= 0.00", v < 0.005, wh)
                else:
                    G.le(1, key + " (all frames)", rn, v, L, wh)
    # 2. see-through
    if 2 in criteria and has("R1"):
        fr = [(l, r) for l, r in _frames(runs["R1"], ("P", "N")) if r["pose"] != "camera_grazing_wall"]
        v, wh = _worst(fr, "seeThroughPct")
        G.le(2, "seeThroughPct (P, N but the grazing poses)", "R1", v, 0.1, wh)
    # 3. accuracy
    if 3 in criteria:
        if has("R1"):
            fr = _frames(runs["R1"], ("P", "N", "W"))
            for key, L in (("misplacementP95px", 1.6), ("misplacementP99px", 2.5), ("misplacementMaxPx", 4.5)):
                v, wh = _worst(fr, key)
                G.le(3, key + " (P, N, W)", "R1", v, L, wh)
        if has("R5"):
            v, wh = _worst(_frames(runs["R5"], ("W",)), "misplacementMaxPx")
            G.le(3, "misplacementMaxPx (W, morph off)", "R5", v, 2.6, wh)
        if has("R2"):
            fr = _frames(runs["R2"], ("P", "W", "AW"))
            if not any("tau" in r for _, r in fr):
                G.skip(3, "misplacementMaxPx <= 2 tau + 0.5, tau <= 5", "R2", "no UI._Render (tau unknown)")
            else:
                over, wh, tmax, twh = -1e9, "", 0.0, ""
                for label, r in fr:
                    t = r.get("tau", DEFAULT_TAU)
                    d = r.get("misplacementMaxPx", 0.0) - (2 * t + 0.5)
                    if d > over:
                        over, wh = d, label
                    if t > tmax:
                        tmax, twh = t, label
                G.add(3, "misplacementMaxPx - (2 tau + 0.5) (every frame)", "R2", over, "<= 0", over <= 1e-12, wh)
                G.le(3, "tau used (every frame)", "R2", tmax, 5.0, twh)
        if has("R4"):
            v, wh = _worst(_frames(runs["R4"], ("P",)), "misplacementMaxPx")
            G.le(3, "misplacementMaxPx (P, collision off)", "R4", v, 8.0, wh)
    # 4. stability
    if 4 in criteria:
        for rn, lim_pop in (("R1", 2.0), ("R5", 2.6)):
            if not has(rn):
                continue
            for enc, ed in runs[rn]["encs"].items():
                W = ed.get("W")
                if not W or "popMaxPx" not in W:
                    continue
                G.le(4, "popMaxPx (W)", rn, W["popMaxPx"], lim_pop, enc)
                if rn == "R1":
                    G.le(4, "popP99Px (W, worst frame)", rn, W["popP99Px"], 0.8, enc)
                    G.le(4, "flickerPct mean (W)", rn, W["flickerPct"], 0.05, enc)
                    G.le(4, "flickerPct max (W)", rn, W["flickerPct_max"], 0.2, enc)
    # 5. actors, billboard truth
    if 5 in criteria and has("R1"):
        rd = runs["R1"]
        worst_err, werr, worst_hw, whw = -1.0, "", -1.0, ""
        for label, r in _frames(rd, ("P", "N")):
            lim = 0.5 if (r["enc"] == "teron" and r["pose"] == "actor_chain_pillar") else 0.3
            d = r["actorErrPct"] - lim
            if d > worst_err:
                worst_err, werr = d, "%s (%.3f%%, limit %.1f)" % (label, r["actorErrPct"], lim)
            if r["actorHiddenWronglyPct"] > worst_hw:
                worst_hw, whw = r["actorHiddenWronglyPct"], label
            units = r.get("units") or {}
            by = r.get("actorErrByUnit") or {}
            if r["pose"] == "actor_chain_pillar" and units.get("raider3") is not None:
                e = by.get(str(units["raider3"]), {})
                G.add(5, "raider 3 hidden wrongly (px)", "R1", e.get("hiddenWrongly", 0), "= 0",
                      e.get("hiddenWrongly", 0) == 0, label)
            if r["pose"] == "steep_pitch_13":
                for key in ("front", "behind"):
                    if units.get(key) is None:
                        continue
                    e = by.get(str(units[key]), {})
                    G.add(5, "steep pitch: raider %s hidden wrongly (px)" % key, "R1", e.get("hiddenWrongly", 0), "= 0",
                          e.get("hiddenWrongly", 0) == 0, label)
        if worst_err > -1.0:
            G.add(5, "actorErrPct - limit (per pose; 0.3, chain pose 0.5)", "R1", worst_err, "<= 0",
                  worst_err <= 1e-12, werr)
            G.le(5, "actorHiddenWronglyPct (per pose)", "R1", worst_hw, 0.1, whw)
        for enc, ed in rd["encs"].items():
            A = ed.get("AW")
            if not A or "actorErrPct" not in A:
                continue
            G.le(5, "actorErrPct mean (AW)", "R1", A["actorErrPct"], 0.5, enc)
            G.le(5, "actorErrPct max frame (AW)", "R1", A["actorErrPct_max"], 2.0, enc)
            G.add(5, "AW frames with actorErrPct > 5", "R1", A["framesWithActorErrorOver5Pct"], "= 0",
                  A["framesWithActorErrorOver5Pct"] == 0, enc)
    # 6. actors, thick truth
    if 6 in criteria and has("R3"):
        fr = _frames(runs["R3"], ("P", "N"))
        v, wh = _worst(fr, "actorErrPct")
        G.le(6, "actorErrPct (per pose, thick)", "R3", v, 3.0, wh)
        v, wh = _worst(fr, "actorHiddenWronglyPct")
        G.le(6, "actorHiddenWronglyPct (per pose, thick)", "R3", v, 1.0, wh)
    # 7. marks
    if 7 in criteria and has("R1"):
        fr = _frames(runs["R1"], ("P", "N"))
        if "_Marks" not in hooks("R1") or not any("wrongLinePct" in r for _, r in fr):
            G.skip(7, "wrongLinePct (per pose)", "R1", "no UI._Marks (no line truth)")
        else:
            v, wh = _worst(fr, "wrongLinePct")
            G.le(7, "wrongLinePct (per pose)", "R1", v, 1.0, wh)
    # 8. order invariants
    if 8 in criteria:
        for rn in ("R1", "R2", "R3", "R4", "R5"):
            if not has(rn):
                continue
            rd = runs[rn]
            sess = [ed["session"] for ed in rd["encs"].values()]
            if not any(s["orderChecked"] for s in sess):
                G.skip(8, "_Order: wrong = 0, distinct = nodes, lines odd / bottom", rn, "UI._Order has no v2 fields")
            else:
                bad = [dict(enc=e, **b) for e, ed in rd["encs"].items() for b in ed["session"]["orderBad"]]
                n = sum(s["orderChecked"] for s in sess)
                G.add(8, "_Order invariants (every frame)", rn, len(bad), "= 0 bad frames", not bad,
                      ("%s frame %d: %s" % (bad[0]["enc"], bad[0]["frame"], bad[0])) if bad else "",
                      "%d frames checked" % n)
            sp = [(e, f, c) for e, ed in rd["encs"].items() for f, c in ed["session"]["setParentFrames"]]
            G.add(8, "SetParent = 0 (every frame after a session's first)", rn, len(sp), "= 0 frames", not sp,
                  ("%s frame %d: %d calls" % sp[0]) if sp else "")
    # 9. budget
    if 9 in criteria and has("R2"):
        rd = runs["R2"]
        fr = _frames(rd, ("P", "W", "AW"))
        v, wh = _worst(fr, "shownTexturesBelowScene")
        G.le(9, "shownTexturesBelowScene (per frame)", "R2", v, 2800, wh)
        v, wh = _worst(fr, "copyTextures")
        G.le(9, "copyTextures (per frame)", "R2", v, 600, wh)
        for enc, ed in rd["encs"].items():
            W, A = ed.get("W"), ed.get("AW")
            if W and "perFrame" in W:
                G.le(9, "shownTexturesBelowScene mean (W)", "R2", W["shownTexturesBelowScene"], 1800, enc)
                G.le(9, "apiCallsPerFrame mean (W)", "R2", W["apiCallsPerFrame"], 8500, enc)
                G.le(9, "apiCallsPerFrame max (W)", "R2", W["apiCallsPerFrame_max"], 13500, enc)
                late = [r for r in W["perFrame"] if r["frame"] >= 5] + (A["perFrame"] if A and "perFrame" in A else [])
                v = max((r["api"].get("CreateTexture", 0) for r in late), default=0)
                G.le(9, "CreateTexture per frame (after the first 5 walk frames)", "R2", v, 50, enc)
            if A and "perFrame" in A:
                G.le(9, "apiCallsPerFrame mean (AW)", "R2", A["apiCallsPerFrame"], 600, enc)
                G.le(9, "apiCallsPerFrame max (AW)", "R2", A["apiCallsPerFrame_max"], 1500, enc)
        idle = [r for ed in rd["encs"].values() for r in ed.get("idle", [])]
        if idle:
            for k in ("SetVertexOffset", "SetTexCoord", "SetDrawLayer", "SetFrameLevel", "SetParent", "CreateTexture"):
                v = max(r["api"].get(k, 0) for r in idle)
                wh = next(("%s/%s idle %d" % (r["enc"], r["pose"], r["frame"]) for r in idle
                           if r["api"].get(k, 0) == v and v > 0), "")
                G.add(9, "idle: %s" % k, "R2", v, "= 0", v == 0, wh)
            v = max(r["api"].get("SetStartPoint", 0) + r["api"].get("SetEndPoint", 0) for r in idle)
            G.le(9, "idle: SetStartPoint + SetEndPoint", "R2", v, 4)
        if fr:
            for k, lm, lx in (("SetDrawLayer", 100, 600), ("SetFrameLevel", 20, 200)):
                vals = [r["api"].get(k, 0) for _, r in fr if "api" in r]
                if vals:
                    G.le(9, "%s mean (P, W, AW)" % k, "R2", float(np.mean(vals)), lm)
                    G.le(9, "%s max (P, W, AW)" % k, "R2", float(np.max(vals)), lx)
    # 10. Lua time
    if 10 in criteria:
        if has("Bench"):
            for enc, ed in runs["Bench"]["encs"].items():
                if ed.get("W"):
                    G.le(10, "bench W mean ms", "Bench", ed["W"]["bench"]["mean"], 4.5, enc)
                if ed.get("P"):
                    v = max(r["luaMsPerFrame"] for r in ed["P"])
                    wh = next(r["pose"] for r in ed["P"] if r["luaMsPerFrame"] == v)
                    G.le(10, "bench P frame ms (max)", "Bench", v, 8.0, "%s/%s" % (enc, wh))
                if ed.get("AW"):
                    G.le(10, "bench AW mean ms", "Bench", ed["AW"]["bench"]["mean"], 0.8, enc)
                if ed.get("idle"):
                    G.le(10, "bench idle mean ms", "Bench", float(np.mean([r["luaMsPerFrame"] for r in ed["idle"]])),
                         0.3, enc)
        if has("R2"):
            for enc, ed in runs["R2"]["encs"].items():
                if ed.get("W") and "luaMsPerFrame" in ed["W"]:
                    ref, src = _baseline_walk_ms(baseline, enc)
                    G.le(10, "mock luaMsPerFrame mean (W) vs baseline", "R2", ed["W"]["luaMsPerFrame"], ref, enc,
                         "baseline: %s" % src)
    # 11. suites and static checks
    if 11 in criteria:
        for r in (suites or []):
            if r.get("skipped"):
                G.skip(11, r["check"], "-", r.get("note", ""))
            else:
                G.add(11, r["check"], "-", r.get("value"), r.get("limit", ""), r["ok"], note=r.get("note", ""))
    return G


def _baseline_walk_ms(baseline, enc):
    """The R2 (else the default run's) walk luaMsPerFrame of the baseline file, else the spec's numbers."""
    if baseline:
        for rn in ("R2", "R1", None):
            rows = baseline.get("runs", {}).get(rn, {}).get("results", []) if rn else baseline.get("results", [])
            for r in rows:
                if r.get("enc") == enc and r.get("pose") == "walk" and "luaMsPerFrame" in r:
                    return float(r["luaMsPerFrame"]), "%s %s" % (baseline.get("_path", "baseline"), rn or "results")
    return BASELINE_LUA_MS[enc], "spec 10.10 (findings.md v1 walk)"


def _warning_keys(text):
    """check.py WARN lines without their line numbers (so that edits elsewhere in a file do not make them new)."""
    keys = []
    for line in text.splitlines():
        if " WARN " not in line:
            continue
        head, _, msg = line.partition(" WARN ")
        f = head.split(":")[0]
        keys.append("%s: %s" % (f, msg.strip()))
    return sorted(keys)


def run_suites(baseline=None):
    """Criterion 11: the suites and tools/check.py, each in its own process (timeout 300 s). -> rows."""
    py = sys.executable
    rows = []
    tests = list(SUITES) + sorted("tests/games/" + f for f in os.listdir(os.path.join(DEV, "tests", "games"))
                                  if f.startswith("test_azeromon") and f.endswith(".py"))
    for t in tests:
        t0 = time.perf_counter()
        try:
            p = subprocess.run([py, t], cwd=DEV, capture_output=True, text=True, timeout=300, encoding="utf-8",
                               errors="replace")
            ok, tail = p.returncode == 0, (p.stdout or "").strip().splitlines()[-1:] or [""]
        except subprocess.TimeoutExpired:
            ok, tail = False, ["timed out after 300 s"]
        rows.append(dict(check=t, value="exit ok" if ok else "FAILED", limit="passes", ok=ok,
                         note="%s (%.0f s)" % (tail[0][:90], time.perf_counter() - t0)))
        print("   %s %s" % ("PASS" if ok else "FAIL", t), flush=True)
    static = {}
    for label, argv in (("check.py DisasterZone_Trainer", ["tools/check.py", "DisasterZone_Trainer"]), ("check.py", ["tools/check.py"])):
        try:
            p = subprocess.run([py] + argv, cwd=DEV, capture_output=True, text=True, timeout=300, encoding="utf-8",
                               errors="replace")
            out = p.stdout or ""
        except subprocess.TimeoutExpired:
            out = ""
        m = re.search(r"(\d+) syntax error\(s\), (\d+) global write\(s\), (\d+) warning\(s\)", out)
        if not m:
            rows.append(dict(check=label, value="no summary", limit="0 / 0", ok=False, note="check.py did not finish"))
            continue
        syn, glo, nw = int(m.group(1)), int(m.group(2)), int(m.group(3))
        keys = _warning_keys(out)
        static[label] = dict(syntax=syn, globals=glo, warnings=nw, warningKeys=keys)
        rows.append(dict(check=label + ": syntax errors + global writes", value=syn + glo, limit="= 0",
                         ok=syn == 0 and glo == 0, note="%d syntax, %d global writes" % (syn, glo)))
        old = ((baseline or {}).get("static") or {}).get(label)
        if old is None:
            rows.append(dict(check=label + ": no new warnings", skipped=True,
                             note="%d warnings; no warning list in the baseline to compare with" % nw))
        else:
            new = sorted(set(keys) - set(old.get("warningKeys", [])))
            rows.append(dict(check=label + ": no new warnings", value=len(new), limit="= 0", ok=not new,
                             note=("new: " + "; ".join(new[:3])) if new else "%d warnings, none new" % nw))
    return rows, static


def print_gate(G, criteria):
    print("\nGATE (spec section 10)")
    print("%-4s %-8s %-58s %-6s %12s %-14s %s" % ("crit", "status", "check", "run", "value", "limit", "where / note"))
    for r in G.rows:
        v = r["value"]
        vs = "-" if v is None else (("%.4g" % v) if isinstance(v, float) else str(v))
        extra = r["where"] + ((" | " + r["note"]) if r["note"] else "")
        print("%-4s %-8s %-58s %-6s %12s %-14s %s" % (r["crit"], r["status"], r["check"][:58], r["run"], vs,
                                                   r["limit"], extra))
    summ = G.summary(criteria)
    print("\ncriteria:")
    for c in criteria:
        print("  %2d %-28s %s" % (c, CRITERIA_NAMES[c], summ[c]))
    return summ


def _parse_list(s, kind):
    if not s:
        return None
    out = []
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        out.append(int(part) if kind is int else part)
    return out


def run_gate(args):
    criteria = _parse_list(args.criteria, int) or sorted(CRITERIA_RUNS)
    bad = [c for c in criteria if c not in CRITERIA_RUNS]
    if bad:
        raise SystemExit("unknown criteria: %s (1..11)" % bad)
    want_runs = _parse_list(args.runs, str)
    if want_runs:
        unknown = [r for r in want_runs if r not in RUN_NAMES]
        if unknown:
            raise SystemExit("unknown runs: %s (%s)" % (unknown, ", ".join(RUN_NAMES)))
    needed = set()
    for c in criteria:
        needed |= set(CRITERIA_RUNS[c])
    if want_runs:
        needed &= set(want_runs)
    baseline = None
    if args.compare and os.path.exists(args.compare):
        with open(args.compare, encoding="utf-8") as fh:
            baseline = json.load(fh)
        baseline["_path"] = args.compare
    encs = ("teron", "vashj") if args.enc == "both" else (args.enc,)
    t0 = time.perf_counter()
    runs, errors = {}, []
    print(HEADER)
    for name, spec in GATE_RUNS:
        if name not in needed:
            continue
        cfg = RunCfg(name, spec.get("opts"), spec["sets"], actors=spec.get("actors", args.actors),
                     billboard=args.billboard, warmup=spec.get("warmup", 0), idle=spec.get("idle", False),
                     bench=spec.get("bench", False), poses=args.poses.split(",") if args.poses else None,
                     quick=args.quick)
        if args.no_walk:
            cfg.sets = tuple(s for s in cfg.sets if s not in ("W", "AW"))
        rd = dict(name=name, opts=cfg.opts, sets=list(cfg.sets), actors=cfg.actors, encs={})
        print("-- run %s: options %s, sets %s%s" % (name, cfg.opts, "/".join(cfg.sets),
                                                   ", thick actors" if cfg.actors == "thick" else ""), flush=True)
        for enc in encs:
            rd["encs"][enc] = run_config(enc, args, cfg, errors)
        s0 = next(iter(rd["encs"].values()))["session"]
        rd["hooks"] = s0["hooks"]
        rd["optsApplied"] = s0["optsApplied"]
        if cfg.opts and not s0["optsApplied"]:
            print("   (UI._RenderOpts does not exist: run %s used the renderer's own options)" % name, flush=True)
        runs[name] = rd
    suites, static = None, None
    if 11 in criteria and not want_runs:
        print("-- criterion 11: suites and static checks", flush=True)
        suites, static = run_suites(baseline)
    G = evaluate_gate(runs, criteria, baseline, suites)
    for e in errors:
        G.add("pre", "precondition of %s/%s" % (e["enc"], e["pose"]), e["run"], None, "holds", False, note=e["error"])
    summ = print_gate(G, criteria)
    st = [r["status"] for r in G.rows]
    code = 1 if "FAIL" in st else (2 if "SKIPPED" in st else 0)
    print("-- gate: %s (%d checks: %d pass, %d fail, %d skipped) in %.1f s" % (
        {0: "PASS", 1: "FAIL", 2: "INCOMPLETE (nothing failed, something skipped)"}[code], len(st), st.count("PASS"),
        st.count("FAIL"), st.count("SKIPPED"), time.perf_counter() - t0), flush=True)
    results = []
    if "R1" in runs:
        for ed in runs["R1"]["encs"].values():
            results += ed.get("P", []) + ed.get("N", []) + [ed[k] for k in ("W", "AW") if ed.get(k)]
    data = dict(size=args.size, scale=args.scale, billboard=args.billboard, results=results,
                runs={n: dict(opts=rd["opts"], sets=rd["sets"], actors=rd["actors"], hooks=rd["hooks"],
                              optsApplied=rd["optsApplied"],
                              results=[r for ed in rd["encs"].values()
                                       for r in ed.get("P", []) + ed.get("N", []) +
                                       [ed[k] for k in ("W", "AW") if ed.get(k)]],
                              idle=[r for ed in rd["encs"].values() for r in ed.get("idle", [])],
                              sessions={e: ed["session"] for e, ed in rd["encs"].items()})
                      for n, rd in runs.items()},
                gate=dict(criteria=criteria, rows=G.rows, summary={str(k): v for k, v in summ.items()}, exit=code,
                          preconditionErrors=errors))
    if static:
        data["static"] = static
    write_json(args, data)
    if baseline:
        compare_runs(args.compare, results, data)
    return code


def run_bench_only(args):
    """--bench without --gate: the bench run (R2's options when UI._RenderOpts exists) and a timing table."""
    cfg = RunCfg("Bench", {"adaptiveTime": False}, ("W", "AW", "P"), warmup=6, idle=True, bench=True,
                 poses=args.poses.split(",") if args.poses else None, quick=args.quick)
    if args.no_walk:
        cfg.sets = ("P",)
    encs = ("teron", "vashj") if args.enc == "both" else (args.enc,)
    out = {}
    for enc in encs:
        ed = run_config(enc, args, cfg)
        out[enc] = ed
        print("bench %s: W mean %s ms, AW mean %s ms, P max %s ms, idle mean %s ms" % (
            enc, ("%.2f" % ed["W"]["bench"]["mean"]) if ed.get("W") else "-",
            ("%.2f" % ed["AW"]["bench"]["mean"]) if ed.get("AW") else "-",
            ("%.2f" % max(r["luaMsPerFrame"] for r in ed["P"])) if ed["P"] else "-",
            ("%.3f" % float(np.mean([r["luaMsPerFrame"] for r in ed["idle"]]))) if ed["idle"] else "-"), flush=True)
    data = dict(size=args.size, bench={e: {k: v for k, v in ed.items()} for e, ed in out.items()})
    write_json(args, data)
    return data


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
    if r.get("copyTextures"):
        s += "  copies %d" % r["copyTextures"]
    if "wrongLinePct" in r:
        s += "  lines wrong %.2f%%" % r["wrongLinePct"]
    return s


HEADER = "%-5s %-6s %-22s %7s %6s %6s %7s %7s %6s %7s %7s %6s %6s %7s %6s %6s" % (
    "run", "enc", "pose", "wrong%", "over%", "miss%", "holes%", "extra%", "mis95", "misMax", "actor%", "amb%", "tex",
    "api", "luaMs", "see%")


def print_row(r):
    line = "%-5s %-6s %-22s %7.2f %6.2f %6.2f %7.2f %7.2f %6.1f %7.1f %7.1f %6.2f %6d %7d %6.1f %6s" % (
        str(r.get("run", "-"))[:5], r["enc"], r["pose"], r["wrongSurfacePct"], r.get("wrongPaintedOverPct", 0),
        r.get("wrongMissingPct", 0), r["holesPct"], r["extraPct"], r["misplacementP95px"], r["misplacementMaxPx"],
        r["actorErrPct"], r["ambiguousPct"], int(r["shownTextures"]), int(r["apiCallsPerFrame"]), r["luaMsPerFrame"],
        ("%.1f" % r["seeThroughPct"]) if "seeThroughPct" in r else "-")
    if r["pose"] in ("walk", "actor_walk"):
        line += "  popMax %.1f px  popP99 %.1f px  flicker %.2f%% (max %.2f%%)" % (
            r["popMaxPx"], r["popP99Px"], r["flickerPct"], r["flickerPct_max"])
    if r["pose"] == "actor_walk":
        line += "  actor max %.1f%%" % r["actorErrPct_max"]
    if r.get("copyTextures"):
        line += "  copies %d" % r["copyTextures"]
    if "wrongLinePct" in r:
        line += "  lines %.2f%%" % r["wrongLinePct"]
    if r.get("precondition"):
        line += "  [pre: %s]" % r["precondition"]
    if r.get("warning"):
        line += "  [%s]" % r["warning"]
    print(line, flush=True)


COMPARE_KEYS = ("wrongSurfacePct", "wrongPaintedOverPct", "wrongMissingPct", "holesPct", "misplacementP95px",
                "misplacementMaxPx", "popMaxPx", "actorErrPct", "apiCallsPerFrame")


def compare_runs(old_path, new, new_data=None):
    with open(old_path, encoding="utf-8") as fh:
        old = json.load(fh)

    def show(title, old_rows, new_rows):
        idx = {(r["enc"], r["pose"]): r for r in old_rows}
        print("\nchange against %s%s (new - old):" % (old_path, title))
        for r in new_rows:
            o = idx.get((r["enc"], r["pose"]))
            if not o:
                continue
            print("%-6s %-22s " % (r["enc"], r["pose"]) + "  ".join(
                "%s %+.2f" % (k, r.get(k, 0) - o.get(k, 0)) for k in COMPARE_KEYS))

    old_runs = old.get("runs") or {}
    new_runs = (new_data or {}).get("runs") or {}
    if old_runs and new_runs:
        for n, rd in new_runs.items():
            if n in old_runs and n != "Bench":
                show(" run %s" % n, old_runs[n].get("results", []), rd.get("results", []))
    else:
        show("", old.get("results", []), new)


def write_json(args, data):
    path = args.json or (os.path.join(args.png, "metrics.json") if args.png else None)
    if not path:
        return None

    def clean(o):
        if isinstance(o, dict):
            return {str(k): clean(v) for k, v in o.items()}
        if isinstance(o, (list, tuple)):
            return [clean(v) for v in o]
        if isinstance(o, (np.floating,)):
            return float(o)
        if isinstance(o, (np.integer,)):
            return int(o)
        if isinstance(o, (np.bool_,)):
            return bool(o)
        if isinstance(o, float) and not math.isfinite(o):
            return None
        return o
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(clean(data), fh, indent=1)
    print("-- metrics: %s" % path)
    return path


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--enc", default="both", choices=("teron", "vashj", "both"))
    ap.add_argument("--png", metavar="OUTDIR", help="save painter / truth / diff PNGs and a sheet per pose here")
    ap.add_argument("--quick", action="store_true", help="4 poses per room, no v2 poses, an 8 frame walk")
    ap.add_argument("--json", metavar="FILE", help="write every number here (default: OUTDIR/metrics.json with --png)")
    ap.add_argument("--size", default="600x400", help="the view's size in UI units (default 600x400)")
    ap.add_argument("--scale", type=float, default=1.0, help="pixels per UI unit of the pictures (default 1)")
    ap.add_argument("--poses", help="only these poses (comma separated names, the 26 and the 8 v2 poses)")
    ap.add_argument("--no-walk", action="store_true", help="skip the walk and the actor walk")
    ap.add_argument("--no-new", action="store_true", help="skip the 8 v2 poses (default run)")
    ap.add_argument("--compare", metavar="JSON", help="print the change against an earlier run's metrics.json (the "
                    "gate also takes its R2 walk ms and its check.py warnings from it)")
    ap.add_argument("--billboard", default="axis", choices=("axis", "forward"),
                    help="actor billboards facing the camera position (axis, default) or the camera plane (forward)")
    ap.add_argument("--actors", default="billboard", choices=("billboard", "thick"),
                    help="actors as billboards (default) or 12-sided prisms (thick)")
    ap.add_argument("--gate", action="store_true", help="run the acceptance runs of spec section 10 and print a pass / "
                    "fail table (exit 0 pass, 1 fail, 2 nothing failed but something skipped)")
    ap.add_argument("--criteria", help="with --gate: only these criteria (e.g. 1,2,8)")
    ap.add_argument("--runs", help="with --gate: only these runs (e.g. R1,R5; R1..R5, Bench)")
    ap.add_argument("--bench", action="store_true", help="time UI._Tick with null setters, no image analysis")
    args = ap.parse_args(argv)
    if args.png:
        os.makedirs(args.png, exist_ok=True)
        with open(os.path.join(args.png, "README.txt"), "w", encoding="utf-8") as fh:
            fh.write("Pictures of tools/render_check.py. Per pose: <room>_<pose>_sheet.png = painter | truth | diff side by "
                     "side with the numbers; _painter / _truth / _diff.png = the same at full size. Walk: "
                     "<room>_walkNN_sheet.png and <room>_walk_pop_sheet.png (the largest jump between two frames). "
                     "With --gate, R1 is here and the other runs in sub-folders (sheets only).\n"
                     "The room textures are made up (a hue per texture file, an 8 x 8 checker per texture unit, dark "
                     "lines on whole units) so that stretching shows; actors are magenta billboards.\n\n%s\n\n%s\n"
                     % (DIFF_LEGEND, __doc__))
    if args.gate:
        code = run_gate(args)
        if __name__ == "__main__":
            sys.exit(code)
        return code
    if args.bench:
        return run_bench_only(args)
    encs = ("teron", "vashj") if args.enc == "both" else (args.enc,)
    t0 = time.perf_counter()
    print(HEADER)
    results, walks = [], []
    cfg = default_cfg(args)
    for enc in encs:
        _, ws = run_encounter(enc, args, results, cfg)
        walks.extend(ws)
    print("-- %d frames in %.1f s" % (len(results) + sum(w["frames"] for w in walks), time.perf_counter() - t0))
    data = dict(size=args.size, scale=args.scale, billboard=args.billboard, actors=args.actors, results=results + walks)
    write_json(args, data)
    if args.compare:
        compare_runs(args.compare, results + walks)
    return data


if __name__ == "__main__":
    main()
