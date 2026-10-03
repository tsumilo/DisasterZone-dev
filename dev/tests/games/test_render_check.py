"""tools/render_check.py: the offline reference renderer works (not that the trainer's renderer is good).

Covers: the mock ModelScene's Project3DPointTo2D is a pinhole camera that honours SetCameraOrientationByYawPitchRoll and
keeps the old formula bit for bit for (math.pi, 0, 0); render_check's camera is that projection; the mock's rectangle
resolver (anchors, sizes, scales, line end points) and API call counting; on a synthetic room (a floor and a wall in
front of it) drawn the way the trainer draws (1 x 1 textures bent with SetVertexOffset): correct triangles drawn whole
- so with a lot of affine distortion - count as right and only show up as misplacement; a far floor painted after the
near wall is flagged as painted over; a wall left out shows as never drawn / holes; two regions on one frame, layer
and sublevel are ambiguous; an actor behind the wall drawn by a ModelScene above the room is an actor error, and not
when the wall is lifted above the scene; one real pose of Teron's hall runs end to end.
Renderer v2 tools (docs/trainer_renderer_v2/spec.md 9.1 - 9.3): the mock rejects SetDrawLayer / CreateLine sublevels
outside -8..7, has GetVertexOffset and a null-setter bench mode; billboards stand on the actor's axis facing the camera
position (and the old camera-plane ones on request), thick actors are 12-sided prisms whose front can reach past a wall
their billboard stands behind; the line truth sees a mark segment behind a wall as hidden and catches a hidden line drawn
on top and a visible one never drawn; a copy (an exact duplicate, or a piece clipped in Lua with screen-affine texture
coordinates) above the scene over an identical base region changes no pixel's class; ties between pieces of one BSP node
are kept out of ambiguousPct; a quad texture over a triangle and its quad mate (pair list) is one right piece and its
fourth corner counts; the camera's distance to the room; --gate runs a subset and reports hook-less checks as
SKIPPED with a consistent exit code.

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


def region_record(seq, frame, layer, sub, file_id, corners, tcs):
    """An R record of a 1 x 1 texture at the view's bottom-left bent onto corners UL, LL, UR, LR (view units) with
    texture coordinates tcs (UL, LL, UR, LR)."""
    (ul, ll, ur, lr) = corners
    off = (ul[0], ul[1] - 1, ll[0], ll[1], ur[0] - 1, ur[1] - 1, lr[0] - 1, lr[1])
    tc = [v for p in tcs for v in p]
    nums = [1, seq, frame, layer, sub, file_id, 1, 1, 1, 1] + tc + [0, 0, 1, 1] + list(off) + [1, 1, 1, 1, 1, 1]
    return "R " + " ".join(repr(float(v)) for v in nums)


def line_record(seq, frame, layer, sub, p1, p2, thick=2.0):
    """An R record of a Line between two scene points (projected through the synthetic camera)."""
    cam = camera()
    x1, y1, _ = cam.project(np.array(p1, float))
    x2, y2, _ = cam.project(np.array(p2, float))
    nums = [2, seq, frame, layer, sub, -1, 1, 1, 1, 1] + [0, 0, 0, 1, 1, 0, 1, 1] + [x1, y1, x2, y2] + [0] * 8 + \
        [thick, 1, 0.8, 0.1, 1, 1]
    return "R " + " ".join(repr(float(v)) for v in nums)


def capture_text(regions, actors=(), extra=(), marks=None):
    """regions: (mesh triangle, frame, layer, sublevel); frames: 1 view, 2 room (level 10), 3 ModelScene (level 20),
    4 a frame above the scene (level 30). extra: more record lines (region_record / line_record); marks: 3D mark
    segments (x1, y1, z1, x2, y2, z2, thickness) as UI._Marks would report them (None: no hook)."""
    mesh, cam = synthetic_mesh(), camera()
    lines = ["C %r %r %r %r %r %r 1.1 0.5 0 0 %d %d %d %d 1 1" % (CAM_POS + CAM_YPR + (W, H, W, H))]
    lines += ["F 1 0 5 4 1 1 1 1 0 0 %d %d" % (W, H), "F 2 1 10 4 0 1 1 2 0 0 %d %d" % (W, H),
              "F 3 1 20 4 0 1 2 3 0 0 %d %d" % (W, H), "F 4 1 30 4 0 1 1 4 0 0 %d %d" % (W, H)]
    for seq, (t, frame, layer, sub) in enumerate(regions):
        P = mesh.corners[t] * np.array([1.0, 1.0, 1.0])
        sx, sy, d = cam.project(P)
        uv = mesh.uv[t]
        # the trainer's way: a 1 x 1 texture at the bottom-left, UL = a, LL = b, UR = LR = c
        lines.append(region_record(100 + seq, frame, layer, sub, mesh.file[t],
                                   ((sx[0], sy[0]), (sx[1], sy[1]), (sx[2], sy[2]), (sx[2], sy[2])),
                                   (uv[0], uv[1], uv[2], uv[2])))
    lines += list(extra)
    for k, (x, y, z) in enumerate(actors):
        lines.append("A %d %d %r %r %r 1 1 2.6 1.2 1" % (k + 1, k + 1, x, y, z))
    if marks is not None:
        lines.append("H _Marks")
        for m in marks:
            lines.append("M " + " ".join(repr(float(v)) for v in m))
    return "\n".join(lines)


def analyse(regions, actors=(), extra=(), marks=None, actor_mode=None, billboard=None, mesh=None):
    mesh = mesh or synthetic_mesh()
    cap = rc.Capture(capture_text(regions, actors, extra, marks), W, H)
    if actor_mode:
        cap.actor_mode = actor_mode
    if billboard:
        cap.billboard = billboard
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
def the_mock_rejects_bad_sublevels_and_can_null_its_setters():
    w, c = solo("Alice", tick=1)
    r = c.eval_py("""
        local M = __MOCK
        local f = CreateFrame('Frame', nil, UIParent)
        local t = f:CreateTexture(nil, 'ARTWORK')
        t:SetDrawLayer('OVERLAY', -8)  t:SetDrawLayer('BORDER', 7)  t:SetDrawLayer('ARTWORK')
        local bad = {}
        for _, s in ipairs({ 8, -9, 16 }) do bad[#bad + 1] = not pcall(t.SetDrawLayer, t, 'ARTWORK', s) end
        local badLine = not pcall(f.CreateLine, f, nil, 'ARTWORK', nil, 9)
        t:SetVertexOffset(2, 3.5, -1)
        local ox, oy = t:GetVertexOffset(2)
        local zx, zy = t:GetVertexOffset(3)
        local l = f:CreateLine()
        M.null_setters(true)
        t:SetVertexOffset(2, 9, 9)  t:SetTexCoord(0, 1, 0, 1)  t:SetDrawLayer('ARTWORK', 99)  t:Hide()
        l:SetStartPoint('BOTTOMLEFT', f, 1, 2)  l:SetThickness(5)
        local nx = t:GetVertexOffset(2)
        local shown, thick = t:IsShown(), l:GetThickness()
        M.null_setters(false)
        t:SetVertexOffset(2, 7, 7)
        local rx = t:GetVertexOffset(2)
        return { bad = bad, badLine = badLine, o = { ox, oy, zx, zy }, nx = nx, shown = shown, thick = thick, rx = rx }
    """)
    assert r["bad"] == [True, True, True] and r["badLine"], r          # sublevels outside -8..7 raise, like in game
    assert r["o"] == [3.5, -1, 0, 0], r
    assert r["nx"] == 3.5 and r["shown"] is True and r["thick"] == 1, r  # null setters: nothing recorded
    assert r["rx"] == 7, r                                              # and the real ones are back
    no_errors(w)


@case
def billboards_face_the_camera_position_through_the_actor_axis():
    cam = rc.Camera((0.0, 0.0, 3.0), (0.0, 0.1, 0.0), 1.1, 0.5, (0.0, 0.0), W, H)    # looking along +x
    actors = [dict(kind=1, height=2.6, width=1.2, pos=(10.0, 6.0, 0.0), unit=1),
              dict(kind=1, height=2.6, width=1.2, pos=(10.0, 0.0, 0.0), unit=2)]
    axis = rc.billboard_tris(actors, cam, "axis")
    fwd = rc.billboard_tris(actors, cam, "forward")
    for k in range(2):
        bl, br, _ = axis[2 * k][1]
        lat = (np.array(br) - np.array(bl))[:2]
        to = np.array(actors[k]["pos"][:2]) - cam.C[:2]
        assert abs(lat @ to) < 1e-9 and abs(np.linalg.norm(lat) - 1.2) < 1e-9, (k, lat, to)   # perpendicular to it
        mid = (np.array(bl) + np.array(br)) / 2
        assert abs(mid[0] - 10) < 1e-9 and abs(mid[1] - actors[k]["pos"][1]) < 1e-9          # through the axis
        flat = (np.array(fwd[2 * k][1][1]) - np.array(fwd[2 * k][1][0]))[:2]
        assert abs(flat @ cam.F[:2]) < 1e-9                               # forward: the camera's image plane
    # off to the side the two differ, straight ahead they agree
    assert not np.allclose(axis[0][1][1], fwd[0][1][1]) and np.allclose(axis[2][1][1], fwd[2][1][1])
    # a camera straight above the actor falls back to the camera plane
    top = rc.Camera((10.0, 6.0, 20.0), (0.0, 1.5, 0.0), 1.1, 0.5, (0.0, 0.0), W, H)
    a = rc.billboard_tris(actors[:1], top, "axis")
    assert np.all(np.isfinite(np.array(a[0][1])))
    # the prisms: 12 sides and 2 caps per actor, radius max(0.4, w / 2), from the feet + 0.15 to the head
    faces = rc.prism_faces(actors)
    assert len(faces) == 28 and len(faces[12][1]) == 12, len(faces)
    pts = np.array([p for _, f in faces[:14] for p in f])
    r_ = np.hypot(pts[:, 0] - 10, pts[:, 1] - 6)
    assert abs(r_.max() - 0.6) < 1e-9 and abs(pts[:, 2].min() - 0.15) < 1e-9 and abs(pts[:, 2].max() - 2.6) < 1e-9


@case
def a_thick_actor_reaches_past_a_wall_its_billboard_stands_behind():
    # 0.3 yd behind the wall: its billboard (the axis plane) is hidden, the front of its 0.6 yd prism is not
    behind = [(11.7, 0.0, 0.0)]
    regions = [(t, 2, 0, -8) for t in FLOOR] + [(t, 4, 0, -7) for t in WALL]          # the wall above the scene
    res_b, tr_b, _ = analyse(regions, behind)
    res_t, tr_t, _ = analyse(regions, behind, actor_mode="thick")
    assert res_b["actorPx"] > 100 and int(tr_b.actor_visible.sum()) == 0, res_b
    assert res_b["actorErrPct"] < 2, res_b
    assert int(tr_t.actor_visible.sum()) > 50 and res_t["actorPx"] > res_b["actorPx"], res_t
    assert res_t["actorHiddenWronglyPct"] > 5 and res_t["actorShownWronglyPct"] < 2, res_t
    by = res_t["actorErrByUnit"]["1"]
    assert by["px"] == res_t["actorPx"] and by["hiddenWrongly"] > 0 and by["shownWrongly"] == 0, by


SEG_BEHIND = (10.0, -2.5, 1.0, 10.0, 2.5, 1.0, 2.0)          # behind the wall (x 12, y -3..3, z 0..4)
SEG_FRONT = (16.0, -2.0, 0.3, 16.0, 2.0, 0.3, 2.0)           # in front of it, above the floor


@case
def the_line_truth_sees_a_segment_behind_a_wall_as_hidden():
    room = [(t, 2, 0, -8) for t in FLOOR] + [(t, 2, 0, -6) for t in WALL]
    marks = [SEG_BEHIND, SEG_FRONT]
    hid = line_record(900, 2, 0, -7, SEG_BEHIND[:3], SEG_BEHIND[3:6])     # before the wall: it covers the line
    vis = line_record(901, 2, 0, -5, SEG_FRONT[:3], SEG_FRONT[3:6])       # after it
    on_top = line_record(902, 4, 0, -7, SEG_BEHIND[:3], SEG_BEHIND[3:6])  # above everything: wrongly shown
    res, tr, pt = analyse(room, extra=[hid, vis], marks=marks)
    assert res["lineSamples"] > 60, res
    assert 25 < res["lineTruthVisiblePct"] < 75, res                    # the front one seen, the one behind not
    assert res["wrongLinePct"] < 3, res
    res2, _, _ = analyse(room, extra=[on_top, vis], marks=marks)        # the hidden one drawn over the wall
    assert res2["wrongLinePct"] > 25, res2
    res3, _, _ = analyse(room, extra=[hid], marks=marks)                # the visible one never drawn
    assert res3["wrongLinePct"] > 25, res3
    res4, _, _ = analyse(room, extra=[hid, vis])                        # no UI._Marks: no line truth
    assert "wrongLinePct" not in res4, res4


@case
def a_copy_over_an_identical_base_region_is_never_wrong():
    mesh, cam = synthetic_mesh(), camera()
    room = [(t, 2, 0, -8) for t in FLOOR] + [(t, 2, 0, -7) for t in WALL]
    extra, seq = [], 500
    # an exact copy of wall triangle 2 above the scene, and a piece of wall triangle 3 clipped in Lua: corners on
    # the base triangle, texture coordinates interpolated affinely on screen (as the base texture shows them)
    t = WALL[0]
    sx, sy, _ = cam.project(mesh.corners[t])
    uv = mesh.uv[t]
    extra.append(region_record(seq, 4, 0, -8, mesh.file[t], ((sx[0], sy[0]), (sx[1], sy[1]), (sx[2], sy[2]),
                                                             (sx[2], sy[2])), (uv[0], uv[1], uv[2], uv[2])))
    t = WALL[1]
    sx, sy, _ = cam.project(mesh.corners[t])
    uv = mesh.uv[t]
    A = np.array([[sx[0], sy[0], 1.0], [sx[1], sy[1], 1.0], [sx[2], sy[2], 1.0]])
    coef = np.linalg.solve(A, np.array(uv))
    w0, w1, w2 = np.array([sx[0], sy[0]]), np.array([sx[1], sy[1]]), np.array([sx[2], sy[2]])
    q = [w0, 0.5 * (w0 + w1), (w0 + w1 + w2) / 3, 0.5 * (w0 + w2)]          # a quad inside the triangle
    tq = [np.array([p[0], p[1], 1.0]) @ coef for p in q]
    extra.append(region_record(seq + 1, 4, 0, -8, mesh.file[t], (q[0], q[1], q[3], q[2]), (tq[0], tq[1], tq[3], tq[2])))
    base, tr0, _ = analyse(room)
    res, tr, pt = analyse(room, extra=extra)
    assert res["copyTextures"] == 2 and res["shownTexturesBelowScene"] == 4, res
    assert res["matchedRegions"] == 6 and res["unmatchedRegions"] == 0, res
    assert (res.cls == base.cls).all(), int((res.cls != base.cls).sum())        # not one pixel changes class
    m0, m1 = np.nan_to_num(base.mis), np.nan_to_num(res.mis)
    assert np.abs(m0 - m1).max() < 1e-6, np.abs(m0 - m1).max()
    assert res["wrongSurfacePct"] < 0.3 and res["ambiguousPct"] == 0, res
    # with an actor behind the wall, the copies above the scene hide it where the wall does
    res_a, _, _ = analyse(room, [(8.0, 0.0, 0.0)], extra=extra)
    assert res_a["actorShownWronglyPct"] > 0 and res_a["actorHiddenWronglyPct"] == 0, res_a


@case
def ties_between_pieces_of_one_node_are_kept_apart():
    m = synthetic_mesh()
    tris = np.concatenate([m.tri + 1, (m.tex_index + 1)[:, None]], axis=1)
    node_mesh = rc.Mesh(m.V.ravel(), tris.ravel(), m.textures, node_of=[1, 1, 2, 2])     # floor node 1, wall node 2
    res, _, _ = analyse([(0, 2, 0, -8), (0, 2, 0, -8)], mesh=node_mesh)                # one floor piece drawn twice
    assert res["ambiguousSameNodePct"] > 1 and res["ambiguousPct"] == 0, res
    res2, _, _ = analyse([(t, 2, 0, -8) for t in FLOOR] + [(t, 2, 0, -8) for t in WALL], mesh=node_mesh)
    assert res2["ambiguousPct"] > 0.5, res2                                            # two nodes: an order WoW lacks


@case
def a_quad_over_a_triangle_and_its_mate_is_one_right_piece():
    # renderer v2 draws a triangle and its quad mate (data format v2 pair list) as one texture whose second GPU
    # triangle (LL, LR, UR) lies on the mate: every pixel of it shows the right surface, and all four corners count
    m = synthetic_mesh()
    tris = np.concatenate([m.tri + 1, (m.tex_index + 1)[:, None]], axis=1)
    qmesh = rc.Mesh(m.V.ravel(), tris.ravel(), m.textures, node_of=[1, 1, 2, 2], pair=[2, 1, 0, 0])
    assert list(qmesh.mate) == [1, 0, -1, -1], qmesh.mate
    lone = rc.Mesh(m.V.ravel(), tris.ravel(), m.textures, node_of=[1, 1, 2, 2], pair=[2, 0, 0, 0])
    assert list(lone.mate) == [-1, -1, -1, -1], lone.mate                       # only mutual pairs
    cam = camera()
    sx, sy, _ = cam.project(qmesh.V[:4, :3])
    uv = qmesh.V[:4, 3:5]

    def floor_quad(lr_shift=0.0):
        # cyclic (a, b, d, c) = vertices 1, 2, 3, 0: triangle 0 turned so that the edge it shares with triangle 1
        # (0 - 2) is the LL - UR diagonal; UL = 1, LL = 2, UR = 0, LR = 3
        return region_record(700, 2, 0, -8, 1001, ((sx[1], sy[1]), (sx[2], sy[2]), (sx[0], sy[0]),
                                                   (sx[3] + lr_shift, sy[3])), (uv[1], uv[2], uv[0], uv[3]))

    walls = [(t, 2, 0, -7) for t in WALL]
    base, _, _ = analyse([(t, 2, 0, -8) for t in FLOOR] + walls, mesh=qmesh)
    res, tr, pt = analyse(walls, extra=[floor_quad()], mesh=qmesh)
    assert res["matchedRegions"] == 3 and res["unmatchedRegions"] == 0, res
    assert (res.cls == base.cls).all(), int((res.cls != base.cls).sum())        # the same as the two triangles
    m0, m1 = np.nan_to_num(base.mis), np.nan_to_num(res.mis)
    assert np.abs(m0 - m1).max() < 1e-6, np.abs(m0 - m1).max()
    assert res["wrongSurfacePct"] < 0.3 and res["holesPct"] < 0.3, res
    # a misplaced fourth corner is not a piece of the quad; without the pair list the quad is no piece either
    res2, _, _ = analyse(walls, extra=[floor_quad(25.0)], mesh=qmesh)
    assert res2["matchedRegions"] == 2 and res2["unmatchedRegions"] == 1, res2
    res3, _, _ = analyse(walls, extra=[floor_quad()], mesh=lone)
    assert res3["matchedRegions"] == 2 and res3["unmatchedRegions"] == 1, res3


@case
def the_camera_distance_to_the_room():
    T = np.array([[[0, 0, 0], [4, 0, 0], [0, 4, 0]]], float)
    assert abs(rc.point_tri_dist((1, 1, 2), T)[0] - 2) < 1e-12                     # above it: the plane
    assert abs(rc.point_tri_dist((-3, 0, 4), T)[0] - 5) < 1e-12                    # beside it: the corner
    assert abs(rc.point_tri_dist((2, -1, 0), T)[0] - 1) < 1e-12                    # off an edge
    mesh, cap = synthetic_mesh(), rc.Capture(capture_text([]), W, H)
    d = rc.cam_min_dist(mesh, cap)                                                 # (30, 0.5, 3): the floor's x = 25 edge
    assert abs(d - math.hypot(5, 3)) < 1e-9, d


@case
def the_gate_runs_a_subset_and_reports_skipped_checks():
    import json
    import shutil
    import tempfile
    tmp = tempfile.mkdtemp(prefix="rc_gate_")
    try:
        out = os.path.join(tmp, "m.json")
        code = rc.main(["--gate", "--enc", "teron", "--criteria", "2,7,8", "--runs", "R1", "--poses",
                        "open_floor_north", "--no-walk", "--size", "%dx%d" % (W, H), "--json", out])
        with open(out, encoding="utf-8") as fh:
            data = json.load(fh)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    assert list(data["runs"]) == ["R1"], list(data["runs"])
    rows = data["gate"]["rows"]
    assert {r["crit"] for r in rows} == {2, 7, 8}, rows
    hooks = set(data["runs"]["R1"]["hooks"])
    c7 = [r for r in rows if r["crit"] == 7]
    assert all(r["status"] == ("SKIPPED" if "_Marks" not in hooks else r["status"]) for r in c7), c7
    if "_Marks" not in hooks:
        assert data["gate"]["summary"]["7"] == "SKIPPED", data["gate"]["summary"]
    c2 = [r for r in rows if r["crit"] == 2][0]
    assert c2["status"] in ("PASS", "FAIL") and math.isfinite(c2["value"]), c2
    st = [r["status"] for r in rows]
    assert code == (1 if "FAIL" in st else 2 if "SKIPPED" in st else 0), (code, st)
    assert data["gate"]["exit"] == code


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
