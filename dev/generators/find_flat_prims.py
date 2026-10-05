"""Finds stock models in the installed client that can stand in for room surfaces in the 3D board's depth pre-pass
("stand-ins": opaque models in a scene under the room's textures, drawn only into the depth buffer).

The probe (Render3D/Probe.lua, "/dz 3d probe") showed in the real client (2026-10-05) that depth written by a lower
ModelScene survives the opaque UI textures painted over it, so any opaque model can hide a boss behind a room face.
Blizzard's unit cube (spells/unitcube.m2, 167145) works; a FLAT stand-in would cover a wall or a floor with one actor
instead of a thin box. This scans every model of the installed build (casc_local) and keeps:

  flat   every drawn vertex within FLAT_TOL of one plane; exactly 4 vertices or a full regular grid; the drawn triangles
         cover the outline rectangle once per facing side (no holes, no overlaps); the header box matches the mesh
  box    8 distinct corners of an axis-aligned box, every face covered (like 167145)

and for both: opaque materials only (blend 0, or 1 = alpha key, noted), depth test and write on (no material flag
0x8 / 0x10), no batch flag 0x4 / 0x20 ("projected texture" on wowdev: how it draws is unknown), no billboard bone
(flags 0x8, 0x10, 0x20, 0x40), no bone that moves a vertex (no key frames, no constant non-identity transform), no
colour or transparency below 1, no particles / ribbons, texture by file (type 0).

For each it reports the FileDataID, the path (found by the root's name hash from the model's internal name and a list
of known folders, else '?'), the size, the plane's normal as a local axis and the side its front faces look at,
one- or two-sided (material flag 0x4, or both windings in the mesh), its batches' flags and shader IDs (shown, not
judged, but for the projected flags), and why the others were refused (counts).

Only models whose first bytes read 'MD21' / 'MD20' in this build are ever listed: SetModelByFileID with any other file
ID can crash the client (WoWUIBugs #67), so Probe.lua may only use IDs from this report.

Run: luaenv\\Scripts\\python.exe generators\\find_flat_prims.py [--json out.json] [--all] [--fid N ...]
     (--all lists every model that passed, not only the best; --fid explains the verdict on given IDs)
The first run peeks at every file of the build (two or three minutes) and caches the model list under dev/art/casc.

Found on 2.5.6.69795 (2026-10-05; Render3D/Probe.lua page 6 shows them in game): 23 flat models and 29 boxes pass
(24 flat before the projected-batch rule refused 200893 G_Blanket; every other projected batch of the build is a spell
ground effect, refused for its blend anyway).
Opaque flat ones: 198111 DNRDeadMinesCaveRoof (two-sided, 89.7 x 109.1, plane z = 17.06), 653518 / 1067658 /
1396283 the low-bandwidth menu quads (one-sided, unlit, facing +x); the rest are alpha-keyed rugs and mats. Boxes:
167145 spells/UnitCube.m2, the world/scale/<n>x<n>.m2 cubes (one-sided, base on the origin), 166046
spells/ErrorCube.m2 (unlit), 203154 IronforgeHouseElevator (a slab), crates. Rejected: 191087 EarthRift (a 7x7 grid,
but particles and a header box 2.7 units off its mesh), the InvisibleTrap squares (billboards).
"""
import argparse
import json
import math
import os
import pickle
import re
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import casc_local as C  # noqa: E402
import m2_write as W  # noqa: E402

DEV = os.path.dirname(HERE)
FLAT_TOL = 0.01              # largest distance from the plane, as a share of the mesh's largest side
BOX_TOL = 0.01               # a corner's distance from the box's corner, same share
AREA_TOL = 0.01              # covered area against the outline's, relative
MAX_VERTS = 2048             # (a stand-in is a handful of triangles; a big grid would only cost)
MAX_BYTES = 512 * 1024
BILLBOARD = 0x8 | 0x10 | 0x20 | 0x40
# Batch (texture unit) flags wowdev names "projected texture" (0x4, and 0x20 with a question mark); in this build
# they sit on spell ground effects (auras, shouts) and on 200893 G_Blanket. How the client draws such a batch - and
# whether it writes depth where the mesh is - is not known, so it is refused: G_Blanket (flags 0x14) passed before
# this rule and stays on the probe's page 6 as a comparison only.
PROJECTED = 0x4 | 0x20
BLEND = W.BLEND_NAMES

# Folders tried for a model's internal name (plus every folder named in the dev kit's own text files).
FOLDERS = [
    "spells", "world/generic/passivedoodads/particleemitters", "world/generic/passivedoodads/collision",
    "world/generic/passivedoodads", "world/generic/activedoodads", "world/generic/human/passive doodads",
    "world/generic/pvp", "world/generic/collision", "world/generic", "world/critter", "world/arttest",
    "world/expansion01/doodads/generic", "world/expansion01/doodads/generic/collision",
    "world/goober", "world/scale", "creature", "interface/glues/models", "character",
    "world/khazmodan/ironforge/passivedoodads/elevators",
]


# ---------------------------------------------------------------------------------------------------------------
# Every model of the build (the first bytes of every file, read once and cached)
# ---------------------------------------------------------------------------------------------------------------

def _first_bytes(fh, off, size, want=0x140):
    """The first `want` decoded bytes of an archive entry, reading as little as possible (a BLTE file's first chunk
    holds the M2 header)."""
    fh.seek(off)
    raw = fh.read(min(size, 30 + 8 + 4096))
    b = raw[30:]
    if b[:4] != b"BLTE":
        return b""
    hs = struct.unpack_from(">I", b, 4)[0]
    if hs and hs + 1 > len(b):
        fh.seek(off)
        raw = fh.read(min(size, 30 + hs + 4096))
        b = raw[30:]
    o = 8 if hs == 0 else hs
    mode = b[o:o + 1]
    if mode == b"N":
        return b[o + 1:o + 1 + want]
    if mode == b"Z":
        try:
            return zlib.decompressobj().decompress(b[o + 1:], want)
        except zlib.error:
            return b""
    return b""                                  # (encrypted or nested: no stand-in hides there)


def model_list():
    """{FileDataID: (magic, vertices, bones, particles + ribbons, stored size)} for every M2 of the build: each file's
    first bytes only, read once and cached."""
    cache = os.path.join(C.CACHE, "m2_headers_%s.pickle" % C.build_name())
    if os.path.exists(cache):
        return pickle.load(open(cache, "rb"))
    root, enc, idx = C.root(), C.encoding(), C.load_indices()
    jobs = []
    for fid, ck in root.items():
        ek = enc.get(ck)
        ent = idx.get(ek[:9]) if ek else None
        if ent:
            jobs.append((ent[0], ent[1], ent[2], fid))
    jobs.sort()                                 # (archive by archive, in file order)
    out, fhs = {}, {}
    for arch, off, size, fid in jobs:
        fh = fhs.get(arch)
        if fh is None:
            fh = fhs[arch] = open(os.path.join(C.DATA, "data", "data.%03d" % arch), "rb")
        head = _first_bytes(fh, off, size)
        if head[:4] == b"MD21":
            md = head[8:]
        elif head[:4] == b"MD20":
            md = head
        else:
            continue
        if len(md) < 0x130 or md[:4] != b"MD20":
            out[fid] = (head[:4].decode("latin1"), -1, -1, -1, size)
            continue
        nv = struct.unpack_from("<I", md, 0x3C)[0]
        nb = struct.unpack_from("<I", md, 0x2C)[0]
        fx = struct.unpack_from("<I", md, 0x128)[0] + struct.unpack_from("<I", md, 0x120)[0]
        out[fid] = (head[:4].decode("latin1"), nv, nb, fx, size)
    for fh in fhs.values():
        fh.close()
    C._save(out, cache)
    return out


# ---------------------------------------------------------------------------------------------------------------
# One model
# ---------------------------------------------------------------------------------------------------------------

def _arr(md, off):
    return struct.unpack_from("<2I", md, off)


def _quat(raw):
    return [(s + 32768 if s < 0 else s - 32767) / 32767.0 for s in raw]


def _track_values(md, toff, fmt, size):
    """Every key value of an M2Track (all sequences), and whether it has a global sequence."""
    gseq = struct.unpack_from("<h", md, toff + 2)[0]
    vn, vo = _arr(md, toff + 12)
    vals = []
    for i in range(vn):
        n, o = struct.unpack_from("<2I", md, vo + 8 * i)
        for k in range(n):
            if o + size * (k + 1) <= len(md):
                vals.append(struct.unpack_from(fmt, md, o + size * k))
    return vals, gseq


def bone_report(md):
    """-> (billboard bones, moving bones) as index lists: a bone moves a vertex when any key frame (or its one
    constant key) is not the identity."""
    nb, ob = _arr(md, 0x2C)
    bill, moving = [], []
    for i in range(nb):
        o = ob + 88 * i
        flags = struct.unpack_from("<I", md, o + 4)[0]
        if flags & BILLBOARD:
            bill.append(i)
        tr, _ = _track_values(md, o + 16, "<3f", 12)
        ro, _ = _track_values(md, o + 36, "<4h", 8)
        sc, _ = _track_values(md, o + 56, "<3f", 12)
        moves = any(max(abs(x) for x in v) > 1e-5 for v in tr)
        for q in ro:
            x, y, z, w = _quat(q)
            if max(abs(x), abs(y), abs(z)) > 1e-4 or abs(abs(w) - 1) > 1e-4:
                moves = True
        moves = moves or any(max(abs(x - 1) for x in v) > 1e-5 for v in sc)
        if moves:
            moving.append(i)
    return bill, moving


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


AXES = {(1, 0, 0): "+x", (-1, 0, 0): "-x", (0, 1, 0): "+y", (0, -1, 0): "-y", (0, 0, 1): "+z", (0, 0, -1): "-z"}


def _axis_name(n):
    for k, name in AXES.items():
        if _dot(n, k) > 0.9995:
            return name
    return "(%.3f, %.3f, %.3f)" % n


def _plane(points):
    """(unit normal, offset, largest distance) of the best plane through points (least squares)."""
    import numpy as np
    p = np.array(points, dtype=float)
    c = p.mean(axis=0)
    _, _, vt = np.linalg.svd(p - c)
    n = vt[2]
    d = float(np.dot(n, c))
    dist = float(np.max(np.abs(p @ n - d)))
    return tuple(float(x) for x in n), d, dist


def analyse(fid, data=None):
    """-> dict: what the model is and every reason it cannot be a stand-in ('why'); 'kind' is flat / box / None."""
    rep = {"fid": fid, "why": []}
    why = rep["why"]
    try:
        data = data if data is not None else C.read_fid(fid)
        m = W.M2.parse(data)
    except Exception as e:                      # (not a model this parser reads: never used)
        why.append("parse: %s" % e)
        return rep
    md = bytes(m.md)
    rep["magic"] = data[:4].decode("latin1")
    nn, no = _arr(md, 0x08)
    rep["name"] = md[no:no + nn].split(b"\0")[0].decode("latin1", "replace") if nn else ""
    for name in ("particles", "ribbons", "lights"):
        if m.arr(name)[0]:
            why.append("has %s" % name)
    verts = m.vertices()
    sfid = m.file_ids("SFID")
    if not sfid:
        why.append("no SFID (skin by name)")
        return rep
    try:
        skin = W.Skin.parse(C.read_fid(sfid[0]))
    except Exception as e:
        why.append("skin: %s" % e)
        return rep
    rep["skin"] = sfid[0]
    mats = m.materials()
    textures = m.elements("textures")
    tex_lookup = [struct.unpack_from("<H", e)[0] for e in m.elements("tex_lookup")]
    transp_lookup = [struct.unpack_from("<H", e)[0] for e in m.elements("transp_lookup")]
    _, otw = m.arr("tex_weights")
    _, ocol = m.arr("colors")
    ncol = m.arr("colors")[0]
    tris, used_mats, tex_types, two_sided, drawn = [], set(), set(), False, set()
    batch_flags, shaders = set(), set()
    for bt in skin.batches:
        if bt.section >= len(skin.sections):
            why.append("batch section out of range")
            continue
        # (kept for the report: the opaque candidates have flags 0x10 and shader 0, the alpha-keyed ones shader 0x10)
        batch_flags.add(bt.flags)
        shaders.add(bt.shader_id)
        s = skin.sections[bt.section]
        start = s.index_start + (s.level << 16)
        if bt.section not in drawn:             # (a section drawn by two batches - two texture layers - once)
            drawn.add(bt.section)
            for k in range(start, start + s.index_count - 2, 3):
                tris.append(tuple(skin.lookup[skin.indices[k + j]] for j in range(3)))
        fl, blend = mats[bt.material] if bt.material < len(mats) else (0, 99)
        used_mats.add((fl, blend))
        if fl & 0x4:
            two_sided = True
        for j in range(bt.texture_count):
            ti = tex_lookup[bt.texture_combo + j] if bt.texture_combo + j < len(tex_lookup) else None
            if ti is not None and ti < len(textures):
                tex_types.add(struct.unpack_from("<I", textures[ti], 0)[0])
        # transparency (texture weight) and colour alpha below 1: the client may draw it blended, without depth
        if bt.weight_combo < len(transp_lookup):
            tw = transp_lookup[bt.weight_combo]
            vals, _ = _track_values(md, otw + 20 * tw, "<h", 2)
            if any(v[0] < 32700 for v in vals):
                why.append("transparency below 1")
        if bt.color != 0xFFFF and bt.color < ncol:
            vals, _ = _track_values(md, ocol + 40 * bt.color + 20, "<h", 2)
            if any(v[0] < 32700 for v in vals):
                why.append("colour alpha below 1")
    rep["batchFlags"] = ["0x%x" % f for f in sorted(batch_flags)]
    rep["shaders"] = ["0x%x" % s for s in sorted(shaders)]
    projected = [f for f in sorted(batch_flags) if f & PROJECTED]
    if projected:
        why.append("projected texture batch (flags %s)" % " ".join("0x%x" % f for f in projected))
    if not tris:
        why.append("no drawn triangles")
        return rep
    rep["materials"] = sorted("0x%x %s" % (fl, BLEND[b] if b < len(BLEND) else b) for fl, b in used_mats)
    for fl, b in used_mats:
        if b > 1:
            why.append("blend %s" % (BLEND[b] if b < len(BLEND) else b))
        if fl & 0x8:
            why.append("depth test off (0x8)")
        if fl & 0x10:
            why.append("depth write off (0x10)")
    rep["alphaKey"] = any(b == 1 for _, b in used_mats)
    if tex_types - {0}:
        why.append("replaceable texture (type %s)" % sorted(tex_types - {0}))
    # its textures by file ID (TXID) or by name, each present in this build (a missing one may draw nothing); the
    # names' folders help find the model's own path
    txid, root = m.file_ids("TXID"), C.root()
    rep["textures"], rep["texDirs"] = [], []
    for i, e in enumerate(textures):
        nn2, no2 = struct.unpack_from("<2I", e, 8)
        tname = md[no2:no2 + nn2].split(b"\0")[0].decode("latin1") if nn2 else ""
        tfid = txid[i] if i < len(txid) and txid[i] else (C.fdid_of(tname) if tname else None)
        rep["textures"].append(tfid if tfid else tname)
        if tname:
            rep["texDirs"].append(tname.replace("\\", "/").rsplit("/", 1)[0].lower())
        if struct.unpack_from("<I", e, 0)[0] == 0 and (tfid is None or tfid not in root):
            why.append("texture not in this build")
    bill, moving = bone_report(md)
    used_v = sorted({v for t in tris for v in t})
    used_bones = {b for v in used_v for w, b in zip(verts[v].weights, verts[v].bones) if w}
    if set(bill) & used_bones:
        why.append("billboard bone")
    if set(moving) & used_bones:
        why.append("a bone moves it")
    P = [verts[v].pos for v in range(len(verts))]
    pts = [P[v] for v in used_v]
    mn = [min(p[k] for p in pts) for k in range(3)]
    mx = [max(p[k] for p in pts) for k in range(3)]
    size = [mx[k] - mn[k] for k in range(3)]
    ext = max(size)
    rep["mesh"] = [round(x, 4) for x in mn + mx]
    rep["header"] = [round(x, 4) for x in struct.unpack_from("<6f", md, W.OFF_BOX)]
    rep["verts"], rep["tris"] = len(used_v), len(tris)
    rep["twoSided"] = two_sided
    if ext <= 1e-6:
        why.append("degenerate")
        return rep
    hdr = rep["header"]
    rep["headerOff"] = round(max(abs(hdr[k] - (mn + mx)[k]) for k in range(6)), 4)
    if rep["headerOff"] > 0.01 * ext + 1e-3:
        why.append("header box off the mesh by %.3f" % rep["headerOff"])
    # front-facing area per triangle (cross(b - a, c - a) points to the side the face is seen from)
    tri_n = []
    for a, b, c in tris:
        cr = _cross(_sub(P[b], P[a]), _sub(P[c], P[a]))
        tri_n.append(cr)
    n, _, dist = _plane(pts)
    rep["flatness"] = round(dist / ext, 5)
    if dist <= FLAT_TOL * ext:
        _flat(rep, pts, tri_n, n, ext)
    else:
        _box(rep, pts, tris, tri_n, mn, mx, size, ext, P)
    if rep.get("kind") is None and not any(w.startswith("shape") for w in why):
        why.append("shape: neither flat nor a box")
    return rep


def _flat(rep, pts, tri_n, n, ext):
    """Fills rep for a flat mesh (pts its drawn vertices, tri_n each triangle's cross product, n the plane's normal):
    kind 'flat', its outline, size, normal axis and the side its faces look at, or a 'shape' reason why not."""
    why = rep["why"]
    # in-plane axes: the model's own when the normal lies along one
    ax = None
    for k in range(3):
        if abs(n[k]) > 0.9995:
            ax = k
    if ax is not None:
        n = tuple(float(round(n[k])) if k == ax else 0.0 for k in range(3))
        u_ax, v_ax = [k for k in range(3) if k != ax]
        u = tuple(1.0 if k == u_ax else 0.0 for k in range(3))
        v = tuple(1.0 if k == v_ax else 0.0 for k in range(3))
    else:
        why.append("shape: plane not along a model axis")
        return
    uv = [(_dot(p, u), _dot(p, v)) for p in pts]
    us = sorted({round(x / ext, 3) for x, _ in uv})
    vs = sorted({round(y / ext, 3) for _, y in uv})
    distinct = {(round(x / ext, 3), round(y / ext, 3)) for x, y in uv}
    rep["grid"] = "%dx%d" % (len(us), len(vs))
    if len(distinct) != len(us) * len(vs):
        why.append("shape: vertices not a full grid (%d of %dx%d)" % (len(distinct), len(us), len(vs)))
        return
    steps = lambda a: [round(a[i + 1] - a[i], 3) for i in range(len(a) - 1)]
    if len(set(steps(us))) > 1 or len(set(steps(vs))) > 1:
        rep["uneven"] = True                  # (a grid with uneven spacing still covers its rectangle)
    rect = (max(x for x, _ in uv) - min(x for x, _ in uv)) * (max(y for _, y in uv) - min(y for _, y in uv))
    if rect <= 1e-9 * ext * ext:
        why.append("shape: a line, not a surface")
        return
    front = sum(_dot(c, n) for c in tri_n if _dot(c, n) > 0) / 2
    back = -sum(_dot(c, n) for c in tri_n if _dot(c, n) < 0) / 2
    rep["normal"] = _axis_name(n)
    rep["front"] = None
    if abs(front - rect) <= AREA_TOL * rect and back <= AREA_TOL * rect:
        rep["front"] = _axis_name(n)
    elif abs(back - rect) <= AREA_TOL * rect and front <= AREA_TOL * rect:
        rep["front"] = _axis_name(tuple(-x for x in n))
    elif abs(front - rect) <= AREA_TOL * rect and abs(back - rect) <= AREA_TOL * rect:
        rep["front"] = "both (both windings)"
        rep["twoSided"] = True
    else:
        why.append("shape: covers %.0f%% / %.0f%% of its outline" % (100 * front / rect, 100 * back / rect))
        return
    lo = [min(_dot(p, a) for p in pts) for a in (u, v)]
    hi = [max(_dot(p, a) for p in pts) for a in (u, v)]
    # (the outline: its two in-plane model axes, their ranges, and the plane's coordinate on the third axis)
    rep["outline"] = {"axes": "xyz"[u_ax] + "xyz"[v_ax], "lo": [round(x, 4) for x in lo],
                      "hi": [round(x, 4) for x in hi], "at": round(sum(p[ax] for p in pts) / len(pts), 4)}
    rep["size"] = [round(hi[0] - lo[0], 4), round(hi[1] - lo[1], 4)]
    rep["kind"] = "flat"


def _box(rep, pts, tris, tri_n, mn, mx, size, ext, P):
    """Fills rep for a mesh that is not flat: kind 'box' when every drawn vertex sits on a corner of its bounding box,
    all 8 corners are used and each face is covered once (outward, or either way when two-sided)."""
    why = rep["why"]
    if min(size) < 0.05 * ext:
        why.append("shape: a thin slab, not flat within %.0f%%" % (100 * FLAT_TOL))
        return
    for p in pts:
        if any(min(abs(p[k] - mn[k]), abs(p[k] - mx[k])) > BOX_TOL * ext for k in range(3)):
            return                              # (a vertex off the box's corners: not a box)
    corners = {tuple(0 if abs(p[k] - mn[k]) <= BOX_TOL * ext else 1 for k in range(3)) for p in pts}
    if len(corners) != 8:
        return
    # every face covered once from outside
    for k in range(3):
        for side, val in ((-1, mn[k]), (1, mx[k])):
            face = (size[(k + 1) % 3]) * (size[(k + 2) % 3])
            area = 0.0
            for (a, b, c), cr in zip(tris, tri_n):
                if all(abs(P[i][k] - val) <= BOX_TOL * ext for i in (a, b, c)):
                    area += side * cr[k] / 2
            # (outward once; a two-sided material may also wind it inward)
            inward_ok = rep["twoSided"] and abs(area + face) <= AREA_TOL * face
            if abs(area - face) > AREA_TOL * face and not inward_ok:
                why.append("shape: box face %s%s covered %.0f%%" % ("-+"[side > 0], "xyz"[k], 100 * area / face))
                return
    rep["size"] = [round(x, 4) for x in size]
    rep["kind"] = "box"


# ---------------------------------------------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------------------------------------------

def folders():
    """FOLDERS plus every folder of a .m2 path named in the dev kit's text files."""
    out = list(FOLDERS)
    seen = set(out)
    pat = re.compile(r"([A-Za-z0-9_ \-]+(?:[\\/]+[A-Za-z0-9_ \-]+)+)[\\/]+[A-Za-z0-9_ \-]+\.m2", re.I)
    for sub in ("generators", "docs", "tools", "tests"):
        for dp, _, fs in os.walk(os.path.join(DEV, sub)):
            for f in fs:
                if not f.endswith((".py", ".md", ".txt", ".lua", ".json")):
                    continue
                try:
                    text = open(os.path.join(dp, f), encoding="utf-8", errors="ignore").read()
                except OSError:
                    continue
                for mt in pat.finditer(text):
                    d = mt.group(1).replace("\\\\", "/").replace("\\", "/").strip().lower()
                    d = re.sub(r"/+", "/", d)
                    if d not in seen:
                        seen.add(d)
                        out.append(d)
    return out


def path_of(fid, name, dirs, extra=()):
    """A model's path: its internal name tried in each folder (its own textures' folders first), else '?'. The root
    keeps only name hashes and this build's WMOs list their doodads by file ID (MODI), so a path is found only when
    a folder guess hashes to the model's ID."""
    if not name:
        return "?"
    # (in the folder, or in a folder of its own name there: Blizzard's usual layout for UI and doodad models)
    for d in list(extra) + dirs:
        for p in ("%s/%s.m2" % (d, name), "%s/%s/%s.m2" % (d, name.lower(), name)):
            if C.fdid_of(p) == fid:
                return p
    return "?"


# ---------------------------------------------------------------------------------------------------------------

def score(r):
    """Lower is better: few triangles (each one costs the client), a header box that fits, opaque rather than alpha
    keyed (its see-through texels write no depth); a box nearer a cube (one actor scale fits more places)."""
    s = r["tris"] / 2.0 + 10 * r.get("headerOff", 0) + (5 if r.get("alphaKey") else 0)
    if r.get("uneven"):
        s += 3
    if r["kind"] == "box":
        s += 4 * (max(r["size"]) / max(min(r["size"]), 1e-6) - 1)
    return s


def _batch_text(r):
    """The batches' flags and shader IDs as one short phrase for the listing."""
    return "batch flags %s shader %s" % (" ".join(r.get("batchFlags", [])) or "-",
                                         " ".join(r.get("shaders", [])) or "-")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", help="write the report here")
    ap.add_argument("--all", action="store_true", help="list every passing model")
    ap.add_argument("--fid", type=int, nargs="*", help="explain these models only")
    a = ap.parse_args()
    if a.fid:
        dirs = folders()
        for fid in a.fid:
            r = analyse(fid)
            r["path"] = path_of(fid, r.get("name"), dirs, r.get("texDirs", ()))
            print(json.dumps(r, indent=None))
        return
    models = model_list()
    print("build %s: %d models" % (C.build_name(), len(models)))
    todo = [f for f, (_, nv, nb, fx, size) in models.items() if 3 <= nv <= MAX_VERTS and size <= MAX_BYTES and not fx]
    print("%d with 3..%d vertices, no particles or ribbons, under %d KB" % (len(todo), MAX_VERTS, MAX_BYTES // 1024))
    refused, passed = {}, []
    for fid in sorted(todo):
        r = analyse(fid)
        if r.get("kind") and not r["why"]:
            passed.append(r)
            continue
        if r.get("kind"):
            key = "%s but: %s" % (r["kind"], r["why"][0].split(" (")[0])
        else:
            key = (r["why"] or ["?"])[0]
            key = re.sub(r"[\d.]+", "N", key)
        refused[key] = refused.get(key, 0) + 1
    dirs = folders()
    for r in passed:
        r["path"] = path_of(r["fid"], r.get("name"), dirs, r.get("texDirs", ()))
        r["score"] = round(score(r), 3)
    passed.sort(key=lambda r: (r["kind"] != "flat", r["score"], r["fid"]))
    print("\nrefused (first reason, counts):")
    for k, n in sorted(refused.items(), key=lambda kv: -kv[1])[:30]:
        print("  %6d  %s" % (n, k))
    flats = [r for r in passed if r["kind"] == "flat"]
    boxes = [r for r in passed if r["kind"] == "box"]
    print("\n%d flat stand-ins, %d boxes passed every check" % (len(flats), len(boxes)))
    show = passed if a.all else flats[:8] + boxes[:6]
    for r in show:
        if r["kind"] == "flat":
            o = r["outline"]
            print("  flat %8d %-55s %s grid %s, %s x %s yd in %s (plane %s = %.3f), normal %s, front %s, %s%s, "
                  "header box off %.4f, %s, %s" % (r["fid"], r["path"], r["name"], r["grid"], r["size"][0],
                                                    r["size"][1], o["axes"], r["normal"][1], o["at"], r["normal"],
                                                    r["front"], "two-sided" if r["twoSided"] else "one-sided",
                                                    ", alpha key" if r.get("alphaKey") else "", r["headerOff"],
                                                    " ".join(r["materials"]), _batch_text(r)))
        else:
            print("  box  %8d %-55s %s %s yd, mesh %s, %s, header box off %.4f, %s, %s" % (
                r["fid"], r["path"], r["name"], r["size"], r["mesh"],
                "two-sided" if r["twoSided"] else "one-sided", r["headerOff"], " ".join(r["materials"]),
                _batch_text(r)))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump({"build": C.build_name(), "flat": flats, "box": boxes, "refused": refused}, fh, indent=1)
        print("wrote", a.json)


if __name__ == "__main__":
    main()
