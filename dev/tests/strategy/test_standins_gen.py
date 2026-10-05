"""The stand-in generator (dev/generators/gen_standins.py) and the stand-ins it ships for Magtheridon's room.

Covers: the room file decodes as Render3D/Rooms.lua unpacks it (its size, every face's plane and the side the
renderer draws it to: its BSP node's plane, not its own winding); the offline z-buffer gives a face's exact depth per
pixel and clips at the near plane; the triangle-box test; where the board's camera can stand; the generator runs end
to end (fast settings, the largest regions) and what it makes keeps its promises on its own poses and on held-out
board poses; the shipped file (Render3D/Standins/MagtheridonsLair_Magtheridon.lua) has the data contract's shape as
Lua itself reads it (line 1 guard, version 1, prims, the room file it was made for, n, stride 12, 12 finite numbers
per stand-in, yaw only, unit normals, sizes in range, a size under 300 KB), every stand-in lies behind its face (the
side the face is seen from) and keeps clear of every room face, none lies on a line of sight past an open edge (the
panels' and the lintel's undersides), and it hides nothing the room does not: over-occlusion 0 after the 1-pixel
erosion on a few poses (the first view, a low orbit, the top view, inside, walking, eye level) and on the poses a
review found faults at, and none where a model could be on a spread of board poses over the camera's whole range.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_standins_gen.py [-k name]
"""
import math
import os
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


def shipped():
    """The shipped file run by Lua 5.1 as the client runs it (the addon's name and namespace as its varargs)."""
    with open(SHIPPED, "rb") as fh:
        src = fh.read().decode("utf-8")
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    ns = L.table()
    run = L.eval("function(src, ns) local f = assert(loadstring(src, '=standins')); f('DisasterZone', ns) "
                 "return ns.RoomStandins end")
    rs = run(src, ns)
    rec = rs[KEY]
    data = [rec.data[i + 1] for i in range(len(rec.data))]
    prim = rec.prims[1]
    room_ = dict(size=rec.room.size, verts=rec.room.verts, tris=rec.room.tris) if rec.room else None
    return src, dict(version=rec.version, n=rec.n, stride=rec.stride, data=data, room=room_,
                     prim=dict(fid=prim.fid, kind=prim.kind, half=prim.half), nprims=len(rec.prims))


def arrays(data, stride=12):
    """Stand-in arrays (centres, axes, sizes, normals) from the contract's numbers, as the runtime turns them:
    a unit cube at x, y, z turned by yaw, size = 2 * half * scale."""
    a = np.array(data, float).reshape(-1, stride)
    C = a[:, 1:4]
    yaw = a[:, 4]
    c, s = np.cos(yaw), np.sin(yaw)
    R = np.zeros((len(a), 3, 3))
    R[:, 0, 0], R[:, 0, 1] = c, s
    R[:, 1, 0], R[:, 1, 1] = -s, c
    R[:, 2, 2] = 1.0
    S = a[:, 7] * 2 * G.PRIMS[1]["half"]
    N = a[:, 8:11]
    return (C, R, S, N), a


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
    for cam in cams + G.review_poses(64, 48):
        assert cam.C[2] >= float(dom.low(cam.C)) - 1e-6, (cam.name, cam.C)


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
    assert not G.on_lines(lines, arr)


@case
def test_generator_runs_and_keeps_its_promises():
    logs = []
    b = G.build(KEY, fast=True, limit=6, log=logs.append)
    assert b["cubes"], logs
    assert b["train"]["over_eroded"] == 0, b["train"]
    assert b["train"]["coverage_any"] > 0.2, b["train"]
    # the board poses: placed against (harm only) and held out
    assert b["btrain"]["over_air"] == 0 and b["board"]["over_air"] == 0, (b["btrain"], b["board"])
    for r_ in b["res_review"]:
        assert r_["over_air"] == 0 and (r_["need"] == "air" or r_["over_eroded"] == 0), r_
    assert b["lines"]["counts"]["lines"] > 0
    text = G.lua_text(KEY, b["cubes"])
    assert text.startswith('if DisasterZoneBoot and DisasterZoneBoot.Run("Render3D/Standins/%s.lua", ...) then '
                           'return end -- DisasterZone Render3D/Standins/%s.lua\n' % (KEY, KEY))
    # what it writes reads back as what it placed
    L = lua51.LuaRuntime()
    ns = L.table()
    L.eval("function(src, ns) assert(loadstring(src))('DisasterZone', ns) end")(text, ns)
    rec = ns.RoomStandins[KEY]
    assert rec.n == len(b["cubes"]) and len(rec.data) == 12 * rec.n
    (C, R, S, N), a = arrays([rec.data[i + 1] for i in range(len(rec.data))])
    want = np.array([list(c.centre) + [c.s] for c in b["cubes"]])
    dist = np.linalg.norm(C[:, None, :] - want[None, :, :3], axis=2)       # (every written one: its placed twin)
    twin = dist.argmin(1)
    assert dist.min(1).max() < 0.002 and len(set(twin.tolist())) == len(want)
    assert np.abs(S - want[twin, 3]).max() < 0.0011
    assert np.abs(N - np.array([b["cubes"][k].n for k in twin])).max() < 1e-4


@case
def test_shipped_file_has_the_contract_shape():
    src, rec = shipped()
    rel = "Render3D/Standins/%s.lua" % KEY
    first = src.split("\n", 1)[0]
    assert first == 'if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end -- DisasterZone %s' % (
        rel, rel), first
    assert len(src.encode("utf-8")) < 300_000, len(src)
    assert rec["version"] == 1 and rec["stride"] == 12 and rec["nprims"] == 1
    assert rec["prim"] == dict(fid=167145, kind="cube", half=0.5), rec["prim"]
    # made for the room file shipped next to it (made for another build of the room it would hide the wrong things)
    assert rec["room"] == G.room_stamp(KEY, room()), (rec["room"], G.room_stamp(KEY, room()))
    n = rec["n"]
    assert n > 100 and len(rec["data"]) == 12 * n, (n, len(rec["data"]))
    a = np.array(rec["data"], float).reshape(-1, 12)
    assert np.isfinite(a).all()
    assert (a[:, 0] == 1).all()                                       # the cube
    assert (np.abs(a[:, 4]) <= math.pi + 1e-6).all()                  # yaw in -pi .. pi
    assert (a[:, 5] == 0).all() and (a[:, 6] == 0).all()              # v1: yaw only
    assert (a[:, 7] >= G.MIN_SIZE - 1e-6).all() and (a[:, 7] <= G.MAX_SIZE + 1e-6).all()
    assert np.abs(np.linalg.norm(a[:, 8:11], axis=1) - 1).max() < 2e-4
    assert (a[:, 11] >= 1).all() and (a[:, 11] == np.round(a[:, 11])).all()
    r = room()
    lo, hi = r.V.min(0) - G.MAX_SIZE, r.V.max(0) + G.MAX_SIZE
    assert ((a[:, 1:4] >= lo) & (a[:, 1:4] <= hi)).all()


@case
def test_shipped_standins_lie_behind_their_faces_and_clear_of_the_room():
    _, rec = shipped()
    (C, R, S, N), a = arrays(rec["data"])
    import shapely
    r = room()
    regions = {g.id: g for g in G.planar_regions(r)}
    index = G.FaceIndex(r)
    ready = set()
    for i in range(len(C)):
        g = regions[int(a[i, 11])]
        assert g.kind in ("floor", "ceiling", "wall"), g.kind
        assert abs(N[i] @ g.n - 1) < 1e-3                                  # the normal of the face it is behind
        corners = C[i] + (np.array([[x, y, z] for x in (-.5, .5) for y in (-.5, .5) for z in (-.5, .5)]) * S[i]) @ R[i]
        # wholly behind its face's plane, MARGIN or more (the corners' rounding to 1 mm aside)
        assert (corners @ g.n - (g.d + g.dlo)).max() <= -G.MARGIN + 2e-3, i
        # never past the face's outline: its square, seen along the cube's axis out of the face, lies inside it
        if g.id not in ready:
            G.prepare_region(r, g)
            g.zone = g.poly.buffer(0.003)
            ready.add(g.id)
        uv = np.c_[corners @ g.frame.e1, corners @ g.frame.e2]
        assert shapely.contains_xy(g.zone, uv[:, 0], uv[:, 1]).all(), i
        # no room face inside it or within half the gap the generator keeps
        assert index.box_clear(C[i], R[i], np.full(3, S[i] / 2 + G.BACK_GAP / 2 - 0.003)), i


@case
def test_shipped_file_is_what_the_generator_writes():
    # (its header current: the writer turns the file's own numbers back into the same text)
    with open(SHIPPED, "rb") as fh:
        src = fh.read().decode("utf-8")
    assert G.lua_text(KEY, recs=G.read_records(SHIPPED)) == src


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
    for cam in G.board_poses(r, view, W=960, H=640, tag="b", **G.BOARD_CHECK)[::12]:
        res, _, _ = G.measure(r, cam, arr)
        if res["over_air"]:
            bad.append((cam.name, res["over_eroded"], res["over_air"]))
    assert not bad, bad


def run_all(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    flt = argv[argv.index("-k") + 1] if "-k" in argv else None
    failed, passed, t_all = [], 0, time.time()
    for fn in _CASES:
        if flt and flt not in fn.__name__:
            continue
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
