"""The stand-in generator (dev/generators/gen_standins.py) and the stand-ins it ships for Magtheridon's room.

Covers: the room file decodes as Render3D/Rooms.lua unpacks it (its size, every face's plane and the side the
renderer draws it to: its BSP node's plane, not its own winding); the offline z-buffer gives a face's exact depth per
pixel and clips at the near plane, and draws a quad stand-in from its front only (one-sided, as the client); the
triangle-box test; the yaw-pitch-roll turn is Render3D/Probe.lua's own (its AXIS and Rot("ypr") run in Lua: the
client's order, roll first, confirmed in game) and turns back into its angles, floors' and ceilings' quads (pitch
+-90) too, and a level floor's or an upright wall's cube turns about z alone; a quad's quarters lie in it and keep
its shape down to the smallest actor scale; where the board's camera can stand (the board, stress and review poses
stand there); the generator runs end to end (fast settings, the largest regions) and what it makes keeps its
promises on its own poses and on held-out board and stress poses, a held-out pose that finds harm brings a review
round (it joins the repair, fresh held-out poses are checked); the packed text round-trips and the TOC helper rewrites
only the block of data files after Render3D\\Standins.lua, the file's line ends kept; the rooms' water is an opaque
floor that gets stand-ins under its surface; every shipped file (Render3D/Standins/*.lua) has the data contract's
shape as Lua itself reads it (line 1 guard, version 3 - packed, unpacked as LibDeflate does -, both prims - the
quad's size and middle as the client's file has them -, the room file it was made for and the rooms it also serves
the same room, n, stride 12, 12 finite numbers per stand-in, angles in range, unit normals, a quad's front along its
normal, scales in range: no actor under 0.018 or the room's own smallest, a size under 400 KB), is what the generator
writes and is listed in the TOC, and packed a file keeps a sixth or less of the Lua memory the plain table did; for
Magtheridon's Lair: stand-ins on floors, walls and slopes, every one lies
behind its face (the side the face is seen from), inside its outline, and keeps clear of every room face, none lies on
a line of sight past an open edge (the panels' and the lintel's undersides), and it hides nothing the room does not:
over-occlusion 0 after the 1-pixel erosion on a few poses (the first view, a low orbit, the top view, inside, walking,
eye level) and on the poses a review found faults at, and none where a model could be on a spread of board poses over
the camera's whole range and of stress poses (by walls at eye level, under floors, grazing floors).

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_standins_gen.py [-k name]
"""
import collections
import math
import os
import re
import sys
import time
import traceback

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(os.path.dirname(HERE))
for p in (os.path.join(DEV, "generators"), os.path.join(DEV, "tools")):
    if p not in sys.path:
        sys.path.insert(0, p)

import gen_standins as G  # noqa: E402
from lupa import lua51  # noqa: E402
import harness  # noqa: E402

KEY = G.DEFAULT_KEY
SHIPPED = os.path.join(G.OUT_DIR, KEY + ".lua")
_CASES = []
_ROOM = []


def case(fn):
    _CASES.append(fn)
    return fn


def room():
    if not _ROOM:
        _ROOM.append(G.load_room(KEY))
    return _ROOM[0]


def shipped(path=SHIPPED, key=KEY):
    """A shipped file run by Lua 5.1 as the client runs it (the addon's name and namespace as its varargs): its table's
    fields, the keys it sets (each to that table), and its numbers - the packed text unpacked as Render3D/Standins.lua
    unpacks it (patchlib's EncodeForPrint and raw deflate are LibDeflate's, byte for byte)."""
    with open(path, "rb") as fh:
        src = fh.read().decode("utf-8")
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    ns = L.table()
    run = L.eval("function(src, ns) local f = assert(loadstring(src, '=standins')); f('DisasterZone', ns) "
                 "return ns.RoomStandins end")
    rs = run(src, ns)
    rec = rs[key]
    same = L.eval("rawequal")      # (two lupa wrappers of one Lua table are not == in Python)
    keys = sorted(k for k in rs.keys() if same(rs[k], rec))
    room_ = dict(size=rec.room.size, verts=rec.room.verts, tris=rec.room.tris) if rec.room else None
    prims = {k: {f: rec.prims[k][f] for f in ("fid", "kind", "half", "w", "h", "cx", "cy", "cz")
                 if rec.prims[k][f] is not None} for k in rec.prims.keys()}
    pieces = [rec.packed[i + 1] for i in range(len(rec.packed))] if rec.packed else []
    data = [x for r in G.read_file(path)["recs"] for x in r]
    return src, dict(version=rec.version, n=rec.n, stride=rec.stride, data=data, room=room_, prims=prims,
                     nprims=len(rec.prims), size=rec.size, pieces=pieces, plain=rec.data is not None, keys=keys)


def arrays(data, stride=12):
    """Stand-in arrays from the contract's numbers, as the runtime places them (G.record_arrays: the anchor turned by
    yaw, pitch, roll in the client's order; a cube 2 half x scale a side, a quad w x h x scale) and the numbers."""
    a = np.array(data, float).reshape(-1, stride)
    return G.record_arrays(a), a


@case
def test_room_decodes_as_the_renderer_draws_it():
    r = room()
    with open(r.path, "rb") as fh:
        size = int(fh.read().decode("utf-8").split("size = ", 1)[1].split(",", 1)[0])
    assert size == 580835, size
    assert r.V.shape[1] == 3 and len(r.T) == len(r.blend) and r.T.min() == 0 and r.T.max() < len(r.V)
    assert set(r.blend) <= {"D", "A", "B"}
    assert np.allclose(np.linalg.norm(r.N[r.area > 1e-9], axis=1), 1.0)
    # every face's plane holds its corners; the side it is drawn to is Render3D/Room.lua's: its BSP node's plane
    # times QO (+1 / -1 its prim's winding against that plane), which leans the winding's way: a camera 1 yd out
    # along it sees the face, one 1 yd behind does not
    P = r.V[r.T]
    assert np.abs(np.einsum("ij,ikj->ik", r.N, P) - r.d[:, None]).max() < 1e-6
    assert (r.node_of >= 0).all() and set(np.unique(r.QO).tolist()) <= {-1, 0, 1}
    F = r.QO[:, None] * r.NP
    o = r.opaque
    assert (np.einsum("ij,ij->i", F[o], r.N[o]) > 0).all()
    k = int(np.argmax(r.area))
    ctr = P[k].mean(0)
    assert G.drawn(r, ctr + F[k])[k] and not G.drawn(r, ctr - F[k])[k]
    # ... but many lean off it (slivers by up to ~90 degrees): there a camera in front of the face's own plane can
    # be behind its node's, and the renderer does not draw it
    cos = np.einsum("ij,ij->i", F, r.N)
    assert (o & (cos < math.cos(math.radians(0.5)))).sum() > 1000
    k = int(np.argmin(np.where(o & (r.area > 1e-3), cos, 2.0)))
    a = math.acos(min(1.0, cos[k]))
    assert a > math.radians(20), math.degrees(a)
    ctr = P[k].mean(0)
    w = (r.N[k] - cos[k] * F[k]) / math.sin(a)
    q = r.QO[k] * (r.NP[k] @ ctr + r.NPd[k])
    cam = ctr + (2 * (abs(q) + 0.05) / math.tan(a) + 0.1) * w - (q + 0.05) * F[k]
    assert r.N[k] @ cam - r.d[k] > 0 and not G.drawn(r, cam)[k]
    # the boss' floor is at height 0 under the boss
    view, spot = G.room_view(KEY)
    assert abs(G.floor_at(r, spot[0], spot[1])) < 0.5


@case
def test_zbuffer_depth_is_exact_and_clips_at_the_near_plane():
    cam = G.Camera((0.0, 0.0, 0.0), 0.0, 0.0, W=64, H=48)         # looking east from the origin
    # a wall 10 yd east, facing the camera, across the whole view
    quad = np.array([[10.0, -50, -50], [10.0, 50, -50], [10.0, 50, 50], [10.0, -50, 50]])
    tris = np.array([quad[[0, 1, 2]], quad[[0, 2, 3]]])
    z, ids = G.raster(cam, cam.to_cam(tris), np.array([7, 7]))
    assert (ids == 7).all()
    d = cam.ray_dirs()
    assert np.abs(z - 10.0 / d[..., 0]).max() < 1e-9           # distance along each pixel's ray
    # a floor under the camera running from behind it to far ahead: clipped, never dropped
    floor = np.array([[-5.0, -20, -1], [50.0, -20, -1], [50.0, 20, -1], [-5.0, 20, -1]])
    z2, ids2 = G.raster(cam, cam.to_cam(np.array([floor[[0, 1, 2]], floor[[0, 2, 3]]])), np.array([1, 1]))
    lower = ids2[cam.H // 2 + 2:, :]
    assert (lower == 1).all() and (ids2[:cam.H // 2, :] == -1).all()
    t = -1.0 / d[cam.H // 2 + 2:, :, 2]
    assert np.abs(z2[cam.H // 2 + 2:, :] - t).max() < 1e-9


@case
def test_triangle_box_overlap():
    axes = np.eye(3)
    tri = np.array([[[2.0, -1, -1], [2.0, 1, -1], [2.0, 0, 1]]])
    assert not G.tri_box_overlap(np.zeros(3), axes, [1.0, 1, 1], tri)[0]           # 1 yd clear of the face
    assert G.tri_box_overlap(np.zeros(3), axes, [2.01, 1, 1], tri)[0]               # touching it
    big = np.array([[[-9.0, -9, 0.5], [9.0, -9, 0.5], [0.0, 9, 0.5]]])              # through the box's top half
    assert G.tri_box_overlap(np.zeros(3), axes, [1.0, 1, 1], big)[0]
    # turned 45 degrees: the corner reaches sqrt(2) along x
    c, s = math.cos(math.pi / 4), math.sin(math.pi / 4)
    turned = np.array([[c, s, 0], [-s, c, 0], [0, 0, 1]])
    edge = np.array([[[1.3, -5, -5], [1.3, 5, -5], [1.3, 0, 5]]])
    assert G.tri_box_overlap(np.zeros(3), turned, [1.0, 1, 1], edge)[0]
    assert not G.tri_box_overlap(np.zeros(3), axes, [1.0, 1, 1], edge)[0]


PROBE = os.path.join(G.ADDON, "Render3D", "Probe.lua")


def probe_rot():
    """Render3D/Probe.lua's own rotation code (Mul, AXIS, Rot) run by Lua 5.1: the turns the in-game probe's tile 38
    showed (red dots, 'Y.P.R', all signs +). -> f(order, yaw, pitch, roll) -> 3 x 3 rows."""
    with open(PROBE, "rb") as fh:
        src = fh.read().decode("utf-8")
    parts = []
    for pat in (r"local function Mul\(a, b\).*?\nend\n", r"local AXIS = \{.*?\n\}\n",
                r"local function Rot\(order, ang\).*?\nend\n"):
        m = re.search(pat, src, re.S)
        assert m, pat
        parts.append(m.group(0))
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    f = L.execute("local cos, sin = math.cos, math.sin\n" + "".join(parts) +
                  "return function(order, y, p, r) local m = Rot(order, { y = y, p = p, r = r }) "
                  "return m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9] end")

    def rot(order, y, p, r):
        return np.array(f(order, y, p, r), float).reshape(3, 3)
    return rot


@case
def test_turn_is_the_probes_yaw_pitch_roll():
    rot = probe_rot()
    rng = np.random.default_rng(3)
    for _ in range(200):
        y, p, r = rng.uniform(-math.pi, math.pi), rng.uniform(-1.5, 1.5), rng.uniform(-math.pi, math.pi)
        M = G.ypr_matrix(y, p, r)
        assert np.abs(M - rot("ypr", y, p, r)).max() < 1e-12
        assert np.abs(G.ypr_matrices([y], [p], [r])[0] - M).max() < 1e-12
        # (another order is another turn: the order matters)
        assert np.abs(M - rot("yrp", y, p, r)).max() > 1e-6
        a = G.ypr_angles(M)
        assert np.abs(G.ypr_matrix(*a) - M).max() < 1e-9
    # straight up or down (a floor's or a ceiling's quad): yaw 0, the rest in roll
    for M in (G.ypr_matrix(0.4, math.pi / 2, -1.1), G.ypr_matrix(-2.0, -math.pi / 2, 0.3)):
        a = G.ypr_angles(M)
        assert a[0] == 0 and abs(abs(a[1]) - math.pi / 2) < 1e-12 and np.abs(G.ypr_matrix(*a) - M).max() < 1e-9
    # a cube under a level floor or behind an upright wall, its grid level, turns about z alone (as v1's did)
    for h in (0.0, 0.7, 2.5, -1.9):
        level = [math.cos(h), math.sin(h), 0.0]
        for a, e1 in (([0.0, 0.0, 1.0], level), ([0.0, 0.0, -1.0], level), (level, [-level[1], level[0], 0.0]),
                      (level, [0.0, 0.0, 1.0])):
            a, e1 = np.array(a), np.array(e1)
            c = G.Standin()
            c.kind, c.axes = "cube", np.stack([e1, np.cross(a, e1), a])
            y, p, rr = G.standin_angles(c)
            M = G.ypr_matrix(y, p, rr)
            # (the same cube: each of its axes along one of the frame's)
            assert np.allclose(np.sort(np.abs(M.T @ c.axes.T), axis=1), [[0, 0, 1]] * 3, atol=1e-9)
            assert abs(p) < 1e-9 and abs(rr) < 1e-9, (h, a, e1, p, rr)
    # and a region's grid runs along its outline's main heading exactly: wall 87's 47 yd of edges run 1.4 degrees off
    # level (its grid once ran on whole degrees, 0.6 off: 0.5 yd over that length)
    r = room()
    g = next(g for g in G.planar_regions(r) if g.id == 87)
    assert g.kind == "wall" and G.prepare_region(r, g)
    A, B, _ = G._outline(r, g)
    ln = np.linalg.norm(B - A, axis=1)
    k = int(np.argmax(ln))
    e = (B[k] - A[k]) / ln[k]
    assert ln[k] > 10 and min(abs(e @ g.frame.e1), abs(e @ g.frame.e2)) < math.sin(math.radians(0.05)), (ln[k], e)


@case
def test_quads_draw_from_their_front_only_and_split_into_quarters_of_their_shape():
    r = room()
    g = next(g for g in sorted(G.planar_regions(r), key=lambda g: -g.area) if g.kind == "floor")
    assert G.prepare_region(r, g)
    u, v = g.inner.representative_point().coords[0]
    q = G.make_quad(g, u, v, 0.1, 1)
    M = q.axes.T
    assert np.allclose(M.T @ M, np.eye(3)) and abs(np.linalg.det(M) - 1) < 1e-9       # (a turn: the client's kind)
    assert np.allclose(q.axes[0], g.n) and abs(q.centre @ g.n - (g.d + g.dlo - G.MARGIN)) < 1e-9
    assert np.allclose(q.half, [0, G.QUAD_W * 0.05, G.QUAD_H * 0.05])
    arr = G.standin_arrays([q])
    assert np.allclose(G.reach(arr), 0)
    # from in front (over the floor, looking down at it) it draws; from behind (under it, looking up) nothing
    for side, want in ((1, True), (-1, False)):
        cam = G.Camera(q.centre + side * 6.0 * g.n, 0.0, side * (math.pi / 2 - 1e-6), W=64, H=48)
        z, ids = G.render_standins(cam, arr, show=np.array([True]))
        assert (ids == 0).any() == want, side
        if want:
            # the quad's middle is 6 yd away along the view's centre line
            assert abs(z[24, 32] - 6.0) < 0.05, z[24, 32]
    # its quarters: half the scale, the same shape and plane, inside it; the smallest quarter is not cut again
    parts = G.split(q)
    assert len(parts) == 4 and all(abs(p.s - 0.05) < 1e-12 and p.ori == q.ori for p in parts)
    for p in parts:
        assert abs(p.centre @ g.n - q.centre @ g.n) < 1e-9
        assert q.u0 - 1e-9 <= p.u0 and p.u0 + p.du <= q.u0 + q.du + 1e-9
        assert q.v0 - 1e-9 <= p.v0 and p.v0 + p.dv <= q.v0 + q.dv + 1e-9
    assert abs(sum(p.du * p.dv for p in parts) - q.du * q.dv) < 1e-9
    small = G.make_quad(g, q.u0, q.v0, G.MIN_SCALE * 1.5, 0)
    assert not G.can_split(small) and G.can_split(G.make_quad(g, q.u0, q.v0, G.MIN_SCALE * 2, 0))


@case
def test_where_the_board_camera_can_stand():
    r = room()
    view, _ = G.room_view(KEY)
    dom = G.CamDomain(r, view)
    # over the boss' floor: down to 0.63 yd under it (pitch -0.5 under 3 yd out, the point looked at lifted less)
    low = float(dom.low(np.array([view[0], view[1], 0.0])))
    assert -0.75 < low < -0.6, low
    # 100 yd past the box the point looked at stays in (the room and 30 yd round it): pitch 0.12 at least, 12 yd up
    # (the grid's bound is a little lower, never higher: it takes 80 yd's)
    far = float(dom.low(np.array([r.w + 130.0, view[1], 0.0])))
    assert 80 * math.tan(G.PITCH_MIN) - 0.5 < far <= 100 * math.tan(G.PITCH_MIN), far
    # the board poses stand there, and so do the review's
    cams = G.board_poses(r, view, seed=5, n_orbit=40, n_low=20, n_close=20, n_walk=8, W=64, H=48)
    stress = G.stress_poses(r, view, seed=5, n_wall=30, n_under=15, n_graze=15, W=64, H=48, dom=dom)
    assert len(stress) == 60
    for cam in cams + stress + G.review_poses(64, 48):
        assert cam.C[2] >= float(dom.low(cam.C)) - 1e-6, (cam.name, cam.C)
    # the stress poses are what they say: the 'under' ones under a floor
    for c in stress:
        if "under" in c.name:
            h = G.floor_at(r, c.C[0], c.C[1])
            assert not np.isfinite(h) or h > c.C[2] - 0.05, (c.name, c.C, h)


@case
def test_open_lines_see_the_panels_and_no_shipped_standin_lies_on_one():
    # the hanging panels (regions 165, 164) and the lintel over the passage (29): open below, air behind; a low
    # camera in front sees up under them (the review's b-close86, b-close104, the lintel cameras)
    r = room()
    view, _ = G.room_view(KEY)
    regs = [g for g in G.planar_regions(r) if g.id in (165, 164, 29, 11) and G.prepare_region(r, g)]
    assert len(regs) == 4
    lines = G.open_lines(r, regs, G.FaceIndex(r), G.CamDomain(r, view))
    per = {regs[i].id for i in np.unique(lines["reg"])}
    assert {165, 164, 29} <= per, (per, lines["counts"])
    # every line's camera stands out in front of its face, and the line comes out of the face's plane
    for i in range(0, len(lines["reg"]), 997):
        g = regs[lines["reg"][i]]
        assert lines["C"][i] @ g.n - (g.d + g.dlo) >= G.HGUARD - 1e-6
        assert abs(lines["P0"][i] @ g.n - g.d) < 0.2
    _, rec = shipped()
    arr, _ = arrays(rec["data"])
    # no quad where a line under the outline at the quads' depth crosses its plane (the generator's rule; the deeper
    # lines cross it farther out still), no cube on any line
    first = G.open_lines(r, regs, G.FaceIndex(r), G.CamDomain(r, view), curtains=G.CURTAIN[:1])
    assert len(first["P0"]) and len(first["P0"]) < len(lines["P0"])
    assert not G.on_lines(first, arr)
    cube = arr[4] == G.KIND_CUBE
    assert not G.on_lines(lines, tuple(x[cube] for x in arr))


@case
def test_generator_runs_and_keeps_its_promises():
    logs = []
    # (the first look at the random poses is told its first pose found harm: a review round must follow - that pose
    # joins the repair, fresh held-out poses are checked - and the room still ships clean)
    orig, told = G.evaluate, []

    def evaluate(room_, cubes, cams, rule=None):
        res = orig(room_, cubes, cams, rule)
        if cams and cams[0].name.startswith("rand ") and rule is None and not told:
            told.append(cams[0].name)
            res[0]["over_air"] = max(res[0]["over_air"], 3)
        return res
    G.evaluate = evaluate
    try:
        b = G.build(KEY, fast=True, limit=6, log=logs.append)
    finally:
        G.evaluate = orig
    assert b["cubes"], logs
    assert [r["reviewed"] for r in b["rounds"]] == [told], b["rounds"]
    assert {"random1", "board1", "stress1"} <= set(b["harm"]) and b["rounds"][0]["board"]["poses"] > 0, b["harm"]
    assert b["train"]["over_eroded"] == 0, b["train"]
    assert b["train"]["coverage_any"] > 0.2, b["train"]
    # the board and stress poses: placed against (harm only) and held out
    assert b["btrain"]["over_air"] == 0 and b["board"]["over_air"] == 0, (b["btrain"], b["board"])
    assert b["strain"]["over_air"] == 0 and b["stress"]["over_air"] == 0, (b["strain"], b["stress"])
    # the quads keep off the open edges' lines as placed: the cut finds next to nothing of theirs
    assert b["repair"].get("lines_split", 0) + b["repair"].get("lines_removed", 0) < 0.1 * b["placed"], b["repair"]
    for r_ in b["res_review"]:
        assert r_["over_air"] == 0 and (r_["need"] == "air" or r_["over_eroded"] == 0), r_
    assert b["lines"]["counts"]["lines"] > 0
    # (nothing harmful on any pose set: it would be written)
    assert b["harm"]["total"] == 0, b["harm"]
    text = G.lua_text(KEY, b["cubes"], checked=b["checked"])
    assert text.startswith('-- DisasterZone_Rooms Standins/%s.lua\n' % KEY)   # (DisasterZone_Rooms: no hot-patch guard)
    # what it writes reads back as what it placed
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, KEY + ".lua")
        with open(path, "wb") as fh:
            fh.write(text.encode("utf-8"))
        _, rec = shipped(path)
    assert rec["version"] == 3 and not rec["plain"] and rec["n"] == len(b["cubes"]) and len(rec["data"]) == 12 * rec["n"]
    (C, R, H, N, K), a = arrays(rec["data"])
    sis = b["cubes"]
    assert "quad" in {c.kind for c in sis}
    want = np.array([c.centre for c in sis])
    dist = np.linalg.norm(C[:, None, :] - want[None, :, :], axis=2)       # (every written one: its placed twin)
    twin = dist.argmin(1)
    assert dist.min(1).max() < 0.002 and len(set(twin.tolist())) == len(want)
    # turned as placed (a cube up to its symmetries), as big, the same normal
    for i, k in enumerate(twin):
        c = sis[k]
        assert np.abs(H[i] - c.half).max() < 0.0011, (H[i], c.half)
        if c.kind == "quad":
            assert np.abs(R[i] - c.axes).max() < 5e-5, (R[i], c.axes)
        else:
            assert np.allclose(np.sort(np.abs(R[i] @ c.axes.T), axis=1), [[0, 0, 1]] * 3, atol=5e-5)
    assert np.abs(N - np.array([sis[k].n for k in twin])).max() < 1e-4


def contract_shape(path, key, r):
    """One shipped data file has the data contract's shape as Lua reads it (r: its room)."""
    src, rec = shipped(path, key)
    first = src.split("\n", 1)[0]
    assert first == '-- DisasterZone_Rooms Standins/%s.lua' % key, first
    assert len(src.encode("utf-8")) < 400_000, (key, len(src))
    lines = src.split("\n")
    assert all(len(x) <= 120 for x in lines if x.startswith("--")), key        # (the comments the code's width)
    assert rec["version"] == 3 and rec["stride"] == 12 and rec["nprims"] == 2 and not rec["plain"], key
    assert rec["pieces"] and all(len(p) <= G.PIECE for p in rec["pieces"][:-1]), key
    assert rec["size"] == G.read_file(path)["size"], key
    # it sets its own key and those of its SAME_ROOM, each to the one table
    assert rec["keys"] == sorted((key,) + tuple(G.SAME_ROOM.get(key, ()))), (key, rec["keys"])
    assert rec["prims"][1] == dict(fid=167145, kind="cube", half=0.5), rec["prims"]
    # the quad as the client's file has it (casc_local + m2_write read 653518: 4 vertices at x -4.0358, y -23.5964 ..
    # 25.3344, z 1.7645 .. 34.7498)
    q = rec["prims"][2]
    assert q["fid"] == 653518 and q["kind"] == "quad", q
    assert abs(q["w"] - 48.9309) < 1e-4 and abs(q["h"] - 32.9853) < 1e-4, q
    assert abs(q["cx"] + 4.03583) < 1e-5 and abs(q["cy"] - 0.86901) < 1e-5 and abs(q["cz"] - 18.25718) < 1e-5, q
    # made for the room file shipped next to it (made for another build of the room it would hide the wrong things)
    assert rec["room"] == G.room_stamp(key, r), (key, rec["room"], G.room_stamp(key, r))
    n = rec["n"]
    assert n > 100 and len(rec["data"]) == 12 * n, (key, n, len(rec["data"]))
    a = np.array(rec["data"], float).reshape(-1, 12)
    assert np.isfinite(a).all()
    quad, cube = a[:, 0] == 2, a[:, 0] == 1
    assert (quad | cube).all() and quad.sum() > 100, key
    assert (np.abs(a[:, 4]) <= math.pi + 1e-6).all() and (np.abs(a[:, 6]) <= math.pi + 1e-6).all()
    assert (np.abs(a[:, 5]) <= math.pi / 2 + 1e-5).all()                # (+-pi/2 written as 1.5708)
    # no actor under the scale that cut a hole in game (0.018) - nor under the room's own smallest quad -; quads up to
    # 49 x 33 yd, cubes 0.7 .. 2.3 yd
    small = G.ROOM_SETTINGS.get(key, {}).get("min_scale", G.MIN_SCALE)
    cube_min = G.ROOM_SETTINGS.get(key, {}).get("min_size", G.MIN_SIZE)
    assert small >= 0.018 and (a[quad, 7] >= small - 1e-9).all() and (a[quad, 7] <= G.QUAD_MAX_SCALE + 1e-9).all()
    assert cube_min >= 0.7 and (a[cube, 7] >= cube_min - 1e-6).all() and (a[cube, 7] <= G.MAX_SIZE + 1e-6).all()
    assert np.abs(np.linalg.norm(a[:, 8:11], axis=1) - 1).max() < 2e-5
    # a quad's front (its turned model x) lies along its normal (the runtime refuses one off by 0.1 degree; the
    # normal as written is a unit vector to 1e-5)
    M = G.ypr_matrices(a[quad, 4], a[quad, 5], a[quad, 6])
    nq = a[quad, 8:11] / np.linalg.norm(a[quad, 8:11], axis=1)[:, None]
    assert (np.einsum("ij,ij->i", M[:, :, 0], nq) > 0.9999985).all(), key
    assert (a[:, 11] >= 1).all() and (a[:, 11] == np.round(a[:, 11])).all()
    lo, hi = r.V.min(0) - G.MAX_SIZE, r.V.max(0) + G.MAX_SIZE
    assert ((a[:, 1:4] >= lo) & (a[:, 1:4] <= hi)).all(), key
    return src, rec


@case
def test_shipped_file_has_the_contract_shape():
    contract_shape(SHIPPED, KEY, room())


def data_keys():
    """The keys of the shipped data files (DisasterZone_Rooms/Standins/<Key>.lua, one per room file Rooms/<Key>.lua; not
    Gaps.lua and Modes.lua, which gen_standin_gaps.py and occlusion_check.py write next to them for every room)."""
    rooms = os.path.join(os.path.dirname(G.OUT_DIR), "Rooms")
    return sorted(f[:-4] for f in os.listdir(G.OUT_DIR) if f.endswith(".lua") and not f.startswith(".")
                  and os.path.exists(os.path.join(rooms, f)))


@case
def test_every_shipped_data_file_has_the_contract_shape_and_the_toc_loads_it():
    """Every data file: the contract's shape, made for the room file shipped next to it, the rooms it also serves the
    same room (their room files unpack to the same payload); DisasterZone_Rooms.toc lists exactly these, sorted, as
    one block of Standins\\ lines (after the rooms: a room's stand-ins check its floor's size); and packed, a file
    keeps a sixth or less of the Lua memory the plain table did."""
    keys = data_keys()
    assert KEY in keys, keys
    for key in keys:
        r = G.load_room(key)
        _, rec = contract_shape(os.path.join(G.OUT_DIR, key + ".lua"), key, r)
        for other in G.SAME_ROOM.get(key, ()):
            assert G._payload(other) == G._payload(key), (key, other)
            assert G.room_stamp(other) == rec["room"], (key, other)
        assert key not in {k for v in G.SAME_ROOM.values() for k in v}, key      # (no file of its own)
    with open(G.TOC, "rb") as fh:
        lines = fh.read().decode("utf-8").splitlines()
    at = [k for k, s in enumerate(lines) if s.startswith("Standins\\")]
    # (what gen_standins.write_toc writes: every file of the folder, the rooms' data files and Gaps.lua / Modes.lua)
    files = sorted(f[:-4] for f in os.listdir(G.OUT_DIR) if f.endswith(".lua") and not f.startswith("."))
    assert set(keys) <= set(files), (keys, files)
    block = ["Standins\\%s.lua" % k for k in files]
    assert [lines[k] for k in at] == block, [lines[k] for k in at]
    assert at == list(range(at[0], at[0] + len(block))), at
    assert max(k for k, s in enumerate(lines) if s.startswith("Rooms\\")) < at[0]
    # (Magtheridon's Lair, measured by Lua 5.1 itself: the file's memory once run, against the version 2 table)
    f = G.read_file(SHIPPED)
    with open(SHIPPED, "rb") as fh:
        packed = G.lua_memory(fh.read().decode("utf-8"))
    plain = G.lua_memory(G.lua_text_v2(KEY, f["recs"], f["stamp"]))
    assert packed < plain / 6 and plain > 500_000, (packed, plain)


@case
def test_packed_text_round_trips_and_the_toc_block_is_all_that_changes():
    recs = [(2, 40.245, 77.382, -0.065, -3.003, -1.57069, 1.69397, 0.02252, -0.0001, -0.00001, 1, 1),
            (1, -0.0004, 1e-7, 12.5, 0.0, 0.0, 0.0, 1.6, 0.0, 0.0, -1.0, 12)]
    text = G.pack_text(recs)
    # 12 lines, line k the k-th numbers; written as the files round them (-0.0004 to 3 places: 0)
    assert text.split("\n") == ["2 1", "40.245 0", "77.382 0", "-0.065 12.5", "-3.003 0", "-1.57069 0",
                                "1.69397 0", "0.02252 1.6", "-0.0001 0", "-0.00001 0", "1 -1", "1 12"], text
    back = G.unpack_text(text, 2)
    assert back[0] == recs[0] and back[1] == (1, 0, 0, 12.5, 0, 0, 0, 1.6, 0, 0, -1, 12), back
    try:
        G.unpack_text(text, 3)
        raise AssertionError("3 stand-ins read from 2")
    except ValueError:
        pass
    # the TOC helper: only the block of Standins\ lines changes, the file's own line ends kept
    import tempfile
    for eol in ("\n", "\r\n"):
        with tempfile.TemporaryDirectory() as tmp:
            toc = os.path.join(tmp, "x.toc")
            before = ["## Title: x", "Load.lua", "Rooms\\A_B.lua", "Standins\\Old.lua", "Standins\\B.lua",
                      "# after", ""]
            with open(toc, "wb") as fh:
                fh.write(eol.join(before).encode("utf-8"))
            assert G.write_toc(["C", "A"], toc=toc) == ["Standins\\A.lua", "Standins\\C.lua"]
            with open(toc, "rb") as fh:
                after = fh.read().decode("utf-8")
            assert after == eol.join(before[:3] + ["Standins\\A.lua", "Standins\\C.lua"] + before[5:]), after


@case
def test_water_is_an_opaque_floor_that_gets_stand_ins():
    """The rooms' water (fast_a.1.blp, 219885) is drawn opaque, from above (gen_rooms.py LIQUID_TEX, Room.lua TINT):
    the generator takes its faces as opaque floors, and where a room with a pool has shipped data, quads lie under its
    surface - what stands in the pool is hidden under the water."""
    for key in ("SerpentshrineCavern_Lurker", "BlackTemple_Najentus", "SerpentshrineCavern_Hydross",
                "SerpentshrineCavern_Morogrim", "SerpentshrineCavern_Vashj", "BlackTemple_Bloodboil"):
        r = G.load_room(key)
        mat = water_faces(r)
        assert mat.any(), key
        assert r.opaque[mat].all() and (r.QO[mat] == 1).all() and (r.N[mat, 2] > 0.999).all(), key
        regions = G.planar_regions(r)
        ids = set(int(x) for x in r.region_of[mat])
        assert all(regions[i].kind == "floor" for i in ids), key
        path = os.path.join(G.OUT_DIR, key + ".lua")
        if not os.path.exists(path):
            continue
        a = np.array(G.read_records(path), float)
        # quads of the water's regions: the share of its area under them
        from shapely.geometry import Polygon, box
        from shapely.ops import unary_union
        got, area = 0.0, 0.0
        for i in ids:
            g = regions[i]
            assert G.prepare_region(r, g)
            mine = a[(a[:, 11] == g.id) & (a[:, 0] == G.QUAD)]
            assert (mine[:, 3] < g.d - G.MARGIN + 0.002).all(), key            # (under the surface)
            rects = []
            for row in mine:
                M = G.ypr_matrix(row[4], row[5], row[6])
                c = row[1:4]
                hw, hh = G.QUAD_W / 2 * row[7], G.QUAD_H / 2 * row[7]
                pts = [c + s1 * hw * M[:, 1] + s2 * hh * M[:, 2] for s1, s2 in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
                rects.append(Polygon([(p @ g.frame.e1, p @ g.frame.e2) for p in pts]))
            got += unary_union(rects).intersection(g.poly).area if rects else 0.0
            area += g.poly.area
        assert got > 0.5 * area, (key, got, area)


def water_faces(r):
    """The room's faces drawn with the water texture (219885)."""
    with open(r.path, "rb") as fh:
        src = fh.read().decode("utf-8")
    pieces = re.findall(r'^\s*"([^"]*)",\s*$', src, re.M)
    from patchlib import decode_for_print, inflate_raw
    parts = inflate_raw(decode_for_print("".join(pieces))).decode("ascii").split("|")
    t = np.array(parts[4].split(), dtype=np.int64).reshape(-1, 4)
    tex = np.array(r.textures)[t[:, 3] - 1]
    return tex == 219885


@case
def test_shipped_standins_lie_behind_their_faces_and_clear_of_the_room():
    _, rec = shipped()
    (C, R, H, N, K), a = arrays(rec["data"])
    import shapely
    r = room()
    regions = {g.id: g for g in G.planar_regions(r)}
    index = G.FaceIndex(r)
    ready = set()
    kinds = collections.Counter()
    signs = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)], float)
    for i in range(len(C)):
        g = regions[int(a[i, 11])]
        kinds[g.kind] += 1
        assert abs(N[i] @ g.n - 1) < 1e-4                                  # the normal of the face it is behind
        corners = C[i] + (signs * H[i]) @ R[i]
        # wholly behind its face's plane, MARGIN or more (the rounding to 1 mm aside)
        assert (corners @ g.n - (g.d + g.dlo)).max() <= -G.MARGIN + 2e-3, i
        # never past the face's outline: its rectangle, seen along the face's normal, lies inside it
        if g.id not in ready:
            G.prepare_region(r, g)
            g.zone = g.poly.buffer(0.003)
            ready.add(g.id)
        uv = np.c_[corners @ g.frame.e1, corners @ g.frame.e2]
        assert shapely.contains_xy(g.zone, uv[:, 0], uv[:, 1]).all(), i
        # no room face inside it or within half the gap the generator keeps (a quad: round it, and that far
        # behind and in front of it - its own face lies MARGIN in front)
        assert index.box_clear(C[i], R[i], H[i] + G.BACK_GAP / 2 - 0.003), i
    # floors, walls and slopes all have some
    assert kinds["floor"] > 50 and kinds["wall"] > 50 and kinds["slope"] > 50, kinds


@case
def test_shipped_file_is_what_the_generator_writes():
    # (every file's header current: the writer turns the file's own numbers - and the poses it says were checked -
    # back into the same text)
    for key in data_keys():
        path = os.path.join(G.OUT_DIR, key + ".lua")
        with open(path, "rb") as fh:
            src = fh.read().decode("utf-8")
        f = G.read_file(path)
        assert f["key"] == key and f["same"] == list(G.SAME_ROOM.get(key, ())), (key, f["same"])
        assert G.lua_text(key, recs=f["recs"], stamp=f["stamp"], checked=f["checked"]) == src, key


@case
def test_shipped_standins_hide_nothing_the_room_does_not():
    _, rec = shipped()
    arr, _ = arrays(rec["data"])
    r = room()
    view, spot = G.room_view(KEY)
    bad = []
    for cam in G.sheet_cams(r, view, spot, 960, 640):
        res, _, _ = G.measure(r, cam, arr)
        if res["over_eroded"]:
            bad.append((cam.name, res["over_eroded"]))
        assert res["drawn"] > 0
    assert not bad, bad


@case
def test_shipped_standins_on_the_review_poses():
    # the poses a review of the first shipped set found over-occlusion at, by the runtime's rule with the near clip
    # (shown()): none at all, or - where the camera stands within the near clip of a face (the runtime's known
    # limit) or looks under the floor past its cut edge - none where a model could be
    _, rec = shipped()
    arr, _ = arrays(rec["data"])
    r = room()
    bad = []
    for cam in G.review_poses(960, 640):
        res, _, _ = G.measure(r, cam, arr)
        if res["over_air"] or (cam.need == "all" and res["over_eroded"]):
            bad.append((cam.name, res["over_eroded"], res["over_air"]))
    assert not bad, bad


@case
def test_shipped_standins_on_board_poses():
    # a spread of the generator's held-out board poses (every 12th): nothing hidden where a model could be
    _, rec = shipped()
    arr, _ = arrays(rec["data"])
    r = room()
    view, _ = G.room_view(KEY)
    bad = []
    cams = G.board_poses(r, view, W=960, H=640, tag="b", **G.BOARD_CHECK)[::12]
    cams += G.stress_poses(r, view, W=960, H=640, tag="s", **G.STRESS_CHECK)[::7]
    for cam in cams:
        res, _, _ = G.measure(r, cam, arr)
        if res["over_air"]:
            bad.append((cam.name, res["over_eroded"], res["over_air"]))
    assert not bad, bad


def run_all(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    flt = argv[argv.index("-k") + 1] if "-k" in argv else None
    failed, passed, t_all = [], 0, time.time()
    picked = [fn for fn in _CASES if not flt or flt in fn.__name__]
    for fn in [fn for i, fn in enumerate(picked) if harness.in_shard(i)]:
        t0 = time.time()
        try:
            fn()
        except Exception as e:  # noqa: BLE001 - report every failure, keep going
            failed.append(fn.__name__)
            print("FAIL %s (%.2fs)" % (fn.__name__, time.time() - t0))
            msg = "".join(traceback.format_exception(type(e), e, e.__traceback__))
            print("    " + msg.replace("\n", "\n    ").rstrip())
        else:
            passed += 1
            print("PASS %s (%.2fs)" % (fn.__name__, time.time() - t0))
    print("-- stand-in generator: %d case(s), %d passed, %d failed (%.1fs)" % (
        passed + len(failed), passed, len(failed), time.time() - t_all))
    if failed:
        print("-- failed: " + ", ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(run_all())
