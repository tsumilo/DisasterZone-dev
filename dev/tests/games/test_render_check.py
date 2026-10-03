"""tools/render_check.py: the offline reference renderer works (not that the trainer's renderer is good).

Covers: the mock ModelScene's Project3DPointTo2D is a pinhole camera that honours SetCameraOrientationByYawPitchRoll and
keeps the old formula bit for bit for (math.pi, 0, 0); render_check's camera is that projection; the mock's rectangle
resolver (anchors, sizes, scales, line end points) and API call counting; on a synthetic room (a floor and a wall in
front of it) drawn the way the trainer draws (1 x 1 textures bent with SetVertexOffset): correct triangles drawn whole
- so with a lot of affine distortion - count as right and only show up as misplacement; a far floor painted after the
near wall is flagged as painted over; a wall left out shows as never drawn / holes; two regions on one frame, layer
and sublevel are ambiguous; an actor behind the wall drawn by a ModelScene above the room is an actor error, and not
when the wall is lifted above the scene; one real pose of Teron's hall runs end to end.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_render_check.py [-k name]
"""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(os.path.dirname(TESTS), "tools"))

from _common import case, run_all, solo, no_errors  # noqa: E402
import render_check as rc  # noqa: E402

W, H = 300, 200


# ------------------------------------------------------------------------------------------------------------------
# a synthetic room and captures in render_check.lua's text format
# ------------------------------------------------------------------------------------------------------------------
def synthetic_mesh():
    """A floor (z = 0, x 2..25, y -10..10, texture 1001) and a wall facing +x at x = 12 (y -3..3, z 0..4, 1002)."""
    V, T = [], []

    def quad(p, tex):
        base = len(V)
        for (x, y, z, u, v) in p:
            V.append((x, y, z, u, v, 1.0))
        T.append((base + 1, base + 2, base + 3, tex))
        T.append((base + 1, base + 3, base + 4, tex))

    f = [(2, -10, 0), (25, -10, 0), (25, 10, 0), (2, 10, 0)]                 # counter-clockwise from above
    quad([(x, y, z, x / 2.0, y / 2.0) for x, y, z in f], 1)
    w = [(12, -3, 0), (12, 3, 0), (12, 3, 4), (12, -3, 4)]                   # counter-clockwise seen from +x
    quad([(x, y, z, y / 2.0, z / 2.0) for x, y, z in w], 2)
    return rc.Mesh(np.array(V, float).ravel(), np.array(T, int).ravel(), [1001, 1002])


CAM_POS, CAM_YPR = (30.0, 0.5, 3.0), (math.pi, 0.15, 0.0)


def camera():
    return rc.Camera(CAM_POS, CAM_YPR, 1.1, 0.5, (0.0, 0.0), W, H)


def capture_text(regions, actors=()):
    """regions: (mesh triangle, frame, layer, sublevel); frames: 1 view, 2 room (level 10), 3 ModelScene (level 20),
    4 a frame above the scene (level 30)."""
    mesh, cam = synthetic_mesh(), camera()
    lines = ["C %r %r %r %r %r %r 1.1 0.5 0 0 %d %d %d %d 1 1" % (CAM_POS + CAM_YPR + (W, H, W, H))]
    lines += ["F 1 0 5 4 1 1 1 1 0 0 %d %d" % (W, H), "F 2 1 10 4 0 1 1 2 0 0 %d %d" % (W, H),
              "F 3 1 20 4 0 1 2 3 0 0 %d %d" % (W, H), "F 4 1 30 4 0 1 1 4 0 0 %d %d" % (W, H)]
    for seq, (t, frame, layer, sub) in enumerate(regions):
        P = mesh.corners[t] * np.array([1.0, 1.0, 1.0])
        sx, sy, d = cam.project(P)
        uv = mesh.uv[t]
        # the trainer's way: a 1 x 1 texture at the bottom-left, UL = a, LL = b, UR = LR = c
        off = (sx[0], sy[0] - 1, sx[1], sy[1], sx[2] - 1, sy[2] - 1, sx[2] - 1, sy[2])
        tc = (uv[0][0], uv[0][1], uv[1][0], uv[1][1], uv[2][0], uv[2][1], uv[2][0], uv[2][1])
        nums = [1, 100 + seq, frame, layer, sub, mesh.file[t], 1, 1, 1, 1] + list(tc) + [0, 0, 1, 1] + list(off) + \
            [1, 1, 1, 1, 1, 1]
        lines.append("R " + " ".join(repr(float(v)) for v in nums))
    for k, (x, y, z) in enumerate(actors):
        lines.append("A %d %d %r %r %r 1 1 2.6 1.2 1" % (k + 1, k + 1, x, y, z))
    return "\n".join(lines)


def analyse(regions, actors=()):
    mesh = synthetic_mesh()
    cap = rc.Capture(capture_text(regions, actors), W, H)
    g = rc.Grid(W, H)
    tr = rc.render_truth(mesh, cap, g, 1.0, backfaces=True)
    pt = rc.render_painter(mesh, cap, tr, g, 1.0)
    return rc.compare(mesh, cap, tr, pt, g, 1.0), tr, pt


FLOOR, WALL = (0, 1), (2, 3)


# ------------------------------------------------------------------------------------------------------------------
# cases
# ------------------------------------------------------------------------------------------------------------------
@case
def the_mock_projection_is_a_pinhole_that_keeps_the_old_formula():
    w, c = solo("Alice", tick=1)
    c.eval("RC_SC = CreateFrame('ModelScene', nil, UIParent)  RC_SC:SetSize(%d, %d)  RC_SC:SetCameraFieldOfView(1.1)" % (W, H))
    pts = [(5.0, 1.0, 2.0), (-3.0, -4.0, 0.5), (12.0, 6.0, -2.0), (-20.0, 2.5, 9.0)]
    # (math.pi, 0, 0) and no orientation at all: exactly the original formula
    for setup in ("RC_SC:SetCameraOrientationByYawPitchRoll(math.pi, 0, 0)", ""):
        c.eval("RC_SC = CreateFrame('ModelScene', nil, UIParent)  RC_SC:SetSize(%d, %d)  RC_SC:SetCameraFieldOfView(1.1) "
               "RC_SC:SetCameraPosition(30, 1, 2) %s" % (W, H, setup))
        for x, y, z in pts:
            same = c.eval_py("local x, y, z = %r, %r, %r  local sx, sy, d = RC_SC:Project3DPointTo2D(x, y, z) "
                             "local cd = 30 - x  local f = (%d / 2) / math.tan(1.1 / 2) "
                             "return { sx == (%d / 2 - (y - 1) / cd * f), sy == (%d / 2 + (z - 2) / cd * f), d == cd }"
                             % (x, y, z, W, W, H))
            assert same == [True, True, True], (setup, x, y, z, same)
    # any orientation: render_check's camera is the mock's projection
    for ypr in ((1.0, 0.3, 0.0), (-2.5, 1.2, 0.0), (0.4, 0.05, 0.3), (-math.pi, 0.0, 0.0)):
        c.eval("RC_SC:SetCameraPosition(3, -4, 6)  RC_SC:SetCameraOrientationByYawPitchRoll(%r, %r, %r)" % ypr)
        cam = rc.Camera((3, -4, 6), ypr, 1.1, 0.5, (0.0, 0.0), W, H)
        P = np.array(cam.C) + cam.F * 15 + np.array([[1, 2, -1], [-3, 0.5, 2], [0, 0, 0], [4, -2, -3]], float)
        for p in P:
            got = c.eval_py("local sx, sy, d = RC_SC:Project3DPointTo2D(%.17g, %.17g, %.17g) return { sx, sy, d }"
                            % tuple(float(v) for v in p))
            sx, sy, d = cam.project(p)
            assert abs(got[0] - sx) < 1e-9 and abs(got[1] - sy) < 1e-9 and abs(got[2] - d) < 1e-9, (ypr, p, got, sx, sy, d)
        # the point straight ahead lands in the middle; a positive pitch looks down
        mid = c.eval_py("local sx, sy = RC_SC:Project3DPointTo2D(%.17g, %.17g, %.17g) return { sx, sy }"
                        % tuple(float(v) for v in cam.C + cam.F * 10))
        assert abs(mid[0] - W / 2) < 1e-9 and abs(mid[1] - H / 2) < 1e-9, mid
        if ypr[1] > 0 and ypr[2] == 0:
            assert cam.F[2] < 0
    # behind the camera: nothing
    assert c.eval_py("return RC_SC:Project3DPointTo2D(3 - 10 * %.17g, -4 - 10 * %.17g, 6 - 10 * %.17g)"
                     % tuple(float(v) for v in cam.F)) is None
    no_errors(w)


@case
def the_mock_resolves_rectangles_lines_and_counts_api_calls():
    w, c = solo("Alice", tick=1)
    r = c.eval_py("""
        local M = __MOCK
        local root = CreateFrame('Frame', nil, UIParent)  root:SetSize(400, 300)  root:SetPoint('BOTTOMLEFT', 100, 50)
        local a = root:CreateTexture()  a:SetAllPoints()
        local b = root:CreateTexture()  b:SetSize(1, 1)  b:SetPoint('BOTTOMLEFT', root, 'BOTTOMLEFT', 0, 0)
        local cc = CreateFrame('Frame', nil, root)  cc:SetPoint('TOPLEFT', 10, -20)  cc:SetPoint('BOTTOMRIGHT', -30, 40)
        local d = root:CreateTexture()  d:SetSize(20, 10)  d:SetPoint('CENTER', root, 'BOTTOMLEFT', 50, 60)
        local e = CreateFrame('Frame', nil, root)  e:SetScale(0.5)  e:SetSize(100, 100)  e:SetPoint('TOPRIGHT', root, 'TOPRIGHT', -20, -20)
        local l = root:CreateLine()  l:SetStartPoint('BOTTOMLEFT', root, 5, 6)  l:SetEndPoint('TOPRIGHT', cc, -1, -2)
        local n = root:CreateTexture()
        local function r(o) return { M.region_rect(o, root) } end
        local x1, y1, x2, y2 = M.line_points(l, root)
        local counts = {}
        M.set_api_count(counts)
        for _ = 1, 3 do b:SetVertexOffset(1, 1, 1) end
        b:Show()  b:Hide()
        M.set_api_count(nil)
        b:SetVertexOffset(2, 0, 0)
        return { a = r(a), b = r(b), c = r(cc), d = r(d), e = r(e), line = { x1, y1, x2, y2 }, none = r(n),
                 abs = { M.region_rect(b) }, counts = counts }
    """)
    assert r["a"] == [0, 0, 400, 300] and r["b"] == [0, 0, 1, 1], r
    assert r["c"] == [10, 40, 360, 240], r                     # two corners
    assert r["d"] == [40, 55, 20, 10], r                       # centre + size
    assert r["e"] == [340, 240, 50, 50], r                     # half scale: offsets and size in its own units
    assert r["line"] == [5, 6, 369, 278], r
    assert not r["none"], r                                    # no anchors: no rectangle
    assert r["abs"] == [100, 50, 1, 1], r                      # from UIParent
    assert r["counts"] == {"SetVertexOffset": 3, "Show": 1, "Hide": 1}, r
    no_errors(w)


@case
def correct_triangles_drawn_whole_are_right_however_warped():
    res, tr, pt = analyse([(t, 2, 0, -8) for t in FLOOR] + [(t, 2, 0, -7) for t in WALL])
    assert tr.id.max() >= 0 and res["truthCoveredPct"] > 30, res
    assert res["matchedRegions"] == 4 and res["unmatchedRegions"] == 0, res
    assert res["wrongSurfacePct"] < 0.3 and res["holesPct"] < 0.3 and res["extraPct"] < 0.3, res
    assert res["misplacementMaxPx"] > 5, res                   # the floor runs far into the room: warped, not wrong
    assert res["ambiguousPct"] == 0 and res["diagonalSensitiveQuads"] == 0, res


def floor_coverage():
    """Pixels the floor's two triangles cover on screen (whatever is in front of them)."""
    mesh, cam, g = synthetic_mesh(), camera(), rc.Grid(W, H)
    cov = np.zeros((H, W), bool)
    for t in FLOOR:
        sx, sy, _ = cam.project(mesh.corners[t])
        res = rc.tri_pixels(g, sx[0], sy[0], sx[1], sy[1], sx[2], sy[2])
        if res:
            r0, c0, m, _, _, _ = res
            cov[r0:r0 + m.shape[0], c0:c0 + m.shape[1]] |= m
    return cov


@case
def the_far_floor_painted_over_the_near_wall_is_flagged():
    res, tr, pt = analyse([(t, 2, 0, -7) for t in WALL] + [(t, 2, 0, -6) for t in FLOOR])
    wall = np.isin(tr.id, WALL)
    # where the floor behind the wall lands on it, less the 1 px band next to visible floor (edge tolerance)
    floor_seen = np.isin(tr.id, FLOOR)
    near_floor = np.zeros_like(floor_seen)
    for dr in (-1, 0, 1):
        for dc in (-1, 0, 1):
            near_floor |= np.roll(np.roll(floor_seen, dr, axis=0), dc, axis=1)
    expected = int((wall & floor_coverage() & ~near_floor).sum())
    flagged = int((res.cls == rc.WRONG_OVER).sum())
    assert wall.sum() > 500 and expected > 200, (int(wall.sum()), expected)
    assert abs(flagged - expected) <= 0.02 * expected + 20, (flagged, expected, res)
    assert res["wrongMissingPct"] < 0.3, res
    # the same order across two frames: the frame level decides, the sublevel does not
    res2, _, _ = analyse([(t, 4, 0, -8) for t in WALL] + [(t, 2, 4, 7) for t in FLOOR])
    assert res2["wrongSurfacePct"] < 0.3, res2


@case
def a_wall_left_out_is_never_drawn_and_holes():
    res, tr, pt = analyse([(t, 2, 0, -8) for t in FLOOR])
    assert res["wrongMissingPct"] > 1, res                    # the floor behind it shows through
    assert res["holesPct"] > 1, res                           # above the floor: the background
    assert res["wrongPaintedOverPct"] < 0.3, res


@case
def two_regions_on_one_frame_layer_and_sublevel_are_ambiguous():
    res, _, _ = analyse([(t, 2, 0, -8) for t in FLOOR] + [(t, 2, 0, -8) for t in WALL])
    assert res["ambiguousPct"] > 0.5, res
    res2, _, _ = analyse([(t, 2, 0, -8) for t in FLOOR] + [(t, 4, 0, -8) for t in WALL])
    assert res2["ambiguousPct"] == 0, res2


@case
def an_actor_behind_the_wall_needs_the_wall_above_the_scene():
    behind = [(8.0, 0.0, 0.0)]
    res, tr, pt = analyse([(t, 2, 0, -8) for t in FLOOR] + [(t, 2, 0, -7) for t in WALL], behind)
    assert res["actorPx"] > 100 and int(tr.actor_visible.sum()) == 0, res
    assert res["actorErrPct"] > 90 and res["actorShownWronglyPct"] > 90, res
    res, tr, pt = analyse([(t, 2, 0, -8) for t in FLOOR] + [(t, 4, 0, -7) for t in WALL], behind)
    assert res["actorErrPct"] < 2, res
    # in front of the wall it must stay visible: lifting the wall over it is wrong the other way
    front = [(18.0, 0.0, 0.0)]
    res, tr, pt = analyse([(t, 2, 0, -8) for t in FLOOR] + [(t, 4, 0, -7) for t in WALL], front)
    assert res["actorHiddenWronglyPct"] > 50, res
    res, tr, pt = analyse([(t, 2, 0, -8) for t in FLOOR] + [(t, 2, 0, -7) for t in WALL], front)
    assert res["actorErrPct"] < 2, res


@case
def one_real_pose_runs_end_to_end():
    sess = rc.Session("teron", (W, H), 1.0)
    name, x, y, facing, pitch, dist, note = rc.resolve_pose(sess, rc.POSES["teron"][0])
    sess.pose(x, y, facing + 0.004, pitch, dist)
    sess.frame()
    sess.pose(x, y, facing, pitch, dist)
    counts, ms = sess.frame()
    cap = sess.capture()
    tr, pt, res = rc.analyse(sess, cap, backfaces=True)
    assert res["truthCoveredPct"] > 30 and res["shownTextures"] > 100, res
    assert res["matchedRegions"] > 0.9 * res["shownTextures"], res
    for k in ("wrongSurfacePct", "holesPct", "misplacementP95px", "actorErrPct", "ambiguousPct", "seeThroughPct"):
        assert math.isfinite(res[k]), (k, res)
    assert counts.get("SetVertexOffset", 0) > 0 and ms > 0, counts
    sess.w.assert_no_errors()


if __name__ == "__main__":
    run_all(sys.argv)
