"""The loose-model probe (dev/docs/DEPTH_RESEARCH.md, 'the single probe'): model files in the addon folder that tell,
in one client session, whether the 2.5.6 client loads an .m2 shipped under Interface\\AddOns, whether it finds a
skin next to it by name, whether our own vertices can be drawn through a Blizzard skin, and whether an invisible
material can write depth.

Writes addon Media/Probe/ (the names are the contract with the probe UI):
  probe_copy.m2                    byte copy of spells/unitcube.m2 (167145): does a loose copy load at all (it may
                                   come from the client's model cache, which is keyed by content: md21 is the proof)
  probe_box_md21.m2                the unit cube moved to a 3 x 1 x 2 yd box at x 0..3, y 0..1, z 0..2 (size and
                                   handedness), its SFID (skin 492738) and TXID (spells/white1.blp, 167204) kept
  probe_box_noskin.m2 + 00.skin    the same box without an SFID chunk, with its own skin next to it
  probe_box_md20.m2 + 00.skin      the same box as a legacy non-chunked MD20 file (version 274, as the client's own
                                   model blocks), the texture named 'SPELLS\\WHITE1.BLP' (no TXID), its own skin
  probe_checker.m2                 hellfiresupplies_01 (193019) with its skin 496338 (434 separate quads) laid out
                                   as an 8 x 8 checkerboard of 0.5 yd cells over x 0..4, y 0..4 (32 quads used, the
                                   rest collapsed to a point): our own geometry through a Blizzard skin
  probe_depth.m2                   the unit cube's body reduced to one 4 x 4 yd square (x 0..4, y 0..4, z 0), unlit,
                                   unfogged, Mod blend (frame x texture) over particles/white_64.blp (1097337, every
                                   texel exactly 255, 255, 255) with depth test and depth write on: invisible if it
                                   works, and it hides what is drawn after it behind it (Mod is a transparent blend:
                                   the client draws it after the opaque pass, so only scenes drawn later)
  manifest.txt                     what each file should look like
Every file is checked with m2_write's validator (and the copy against the client's own bytes) before any is written;
one failed check writes nothing.

Run from dev/:  luaenv\\Scripts\\python.exe generators\\gen_probe.py [--out DIR]
"""
import argparse
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import casc_local  # noqa: E402
import m2_write as W  # noqa: E402

OUT = os.path.normpath(os.path.join(HERE, "..", "..", "addon", "DisasterZone", "Media", "Probe"))
GAME_DIR = "Interface\\AddOns\\DisasterZone\\Media\\Probe\\"

UNITCUBE, UNITCUBE_SKIN, WHITE1 = 167145, 492738, 167204          # spells/unitcube.m2, its skin, spells/white1.blp
CHECKER_MODEL, CHECKER_SKIN = 193019, 496338                       # hellfiresupplies_01.m2 and its skin
WHITE = 1097337                                                    # particles/white_64.blp
WHITE1_NAME = "SPELLS\\WHITE1.BLP"

BOX = (3.0, 1.0, 2.0)                  # the box's size along x, y, z (yd); its corner at the origin
BOARD, CELLS = 4.0, 8                  # the checkerboard: 4 x 4 yd, 8 x 8 cells, a cell where (i + j) is even
SQUARE = 4.0                           # the depth writer's square
MOD = 5                                # blend mode Mod: frame colour x texel
UNLIT, UNFOGGED, TWO_SIDED = 0x1, 0x2, 0x4

NAMES = ("probe_copy.m2", "probe_box_md21.m2", "probe_box_noskin.m2", "probe_box_noskin00.skin", "probe_box_md20.m2",
         "probe_box_md2000.skin", "probe_checker.m2", "probe_depth.m2", "manifest.txt")


class ProbeError(Exception):
    pass


def game_file(fid):
    return casc_local.read_fid(fid)


# ---------------------------------------------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------------------------------------------

def triangles(skin):
    """The skin's triangles as model vertex indices."""
    lk, ix = skin.lookup, skin.indices
    return [(lk[ix[i]], lk[ix[i + 1]], lk[ix[i + 2]]) for i in range(0, len(ix), 3)]


def pieces(skin):
    """The skin's vertex-disjoint pieces: (quads, others). A quad is (t0, t1), two triangles sharing one edge (its
    diagonal); others are the vertex sets of every other piece (collapsed when the skin is borrowed)."""
    tris = triangles(skin)
    parent = {}

    def root(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for a, b, c in tris:
        parent[root(b)] = root(a)
        parent[root(c)] = root(a)
    groups = {}
    for t in tris:
        g = groups.setdefault(root(t[0]), [set(), []])
        g[0].update(t)
        g[1].append(t)
    quads, others = [], []
    for key in sorted(groups, key=lambda k: min(groups[k][0])):
        verts, ts = groups[key]
        if len(verts) == 4 and len(ts) == 2 and len(set(ts[0]) & set(ts[1])) == 2:
            quads.append(tuple(ts))
        else:
            others.append(verts)
    return quads, others


def _area_z(p, q, r):
    return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])


def place_quad(pos, quad, x0, y0, x1, y1, z=0.0):
    """Put a quad's four vertices on the rectangle's corners so both triangles cover it facing up (+z).
    Returns {vertex: (u, v)}."""
    t0, t1 = quad
    s0, s1 = sorted(set(t0) & set(t1))
    o0 = next(v for v in t0 if v not in (s0, s1))
    o1 = next(v for v in t1 if v not in (s0, s1))
    corner = {s0: (x0, y0), s1: (x1, y1), o0: (x1, y0), o1: (x0, y1)}
    if _area_z(*[corner[v] for v in t0]) < 0:
        corner[o0], corner[o1] = (x0, y1), (x1, y0)
    for t in (t0, t1):
        if _area_z(*[corner[v] for v in t]) <= 0:
            raise ProbeError("a quad's triangles wind differently: it cannot be laid flat facing up")
    uv = {}
    for v, (x, y) in corner.items():
        pos[v] = (x, y, z)
        uv[v] = ((x - x0) / (x1 - x0), 1.0 - (y - y0) / (y1 - y0))
    return uv


def flat_vertices(m2, placed, uv):
    """The model's vertices with `placed` {index: position} laid flat (normal up, uv from `uv`), every other vertex
    collapsed onto the origin (its triangles have no area: nothing is drawn)."""
    out = []
    for i, v in enumerate(m2.vertices()):
        if i in placed:
            out.append(v._replace(pos=placed[i], normal=(0.0, 0.0, 1.0), uv0=uv[i], uv1=(0.0, 0.0)))
        else:
            out.append(v._replace(pos=(0.0, 0.0, 0.0), normal=(0.0, 0.0, 1.0), uv0=(0.0, 0.0), uv1=(0.0, 0.0)))
    return out


# ---------------------------------------------------------------------------------------------------------------
# Client lookups
# ---------------------------------------------------------------------------------------------------------------

_M32 = 0xFFFFFFFF


def _rot(x, k):
    return ((x << k) | (x >> (32 - k))) & _M32


def name_hash(path):
    """The root file's 64-bit name hash of a game path: Jenkins' lookup3 hashlittle2 over the upper-case path with
    backslashes, high word c, low word b (checked: 'spells/unitcube.m2' gives 167145's hash)."""
    data = path.upper().replace("/", "\\").encode("ascii")
    a = b = c = (0xDEADBEEF + len(data)) & _M32
    rest = data
    while len(rest) > 12:
        x, y, z = struct.unpack_from("<3I", rest, 0)
        a, b, c = (a + x) & _M32, (b + y) & _M32, (c + z) & _M32
        # mix(): each step subtracts, xors a rotation, then adds; the three words take turns
        for shift, order in ((4, "acb"), (6, "bac"), (8, "cba"), (16, "acb"), (19, "bac"), (4, "cba")):
            v = {"a": a, "b": b, "c": c}
            p, q, r = order
            v[p] = ((v[p] - v[q]) & _M32) ^ _rot(v[q], shift)
            v[q] = (v[q] + v[r]) & _M32
            a, b, c = v["a"], v["b"], v["c"]
        rest = rest[12:]
    if rest:
        x, y, z = struct.unpack_from("<3I", rest + bytes(12), 0)
        a, b, c = (a + x) & _M32, (b + y) & _M32, (c + z) & _M32
        # final(): c ^= b, c -= rot(b, 14); a ^= c, a -= rot(c, 11); ... with the shifts below
        for shift, (p, q) in ((14, "cb"), (11, "ac"), (25, "ba"), (16, "cb"), (4, "ac"), (14, "ba"), (24, "cb")):
            v = {"a": a, "b": b, "c": c}
            v[p] = ((v[p] ^ v[q]) - _rot(v[q], shift)) & _M32
            a, b, c = v["a"], v["b"], v["c"]
    return (c << 32) | b


def root_name_hashes(fids):
    """{fid: {name hashes}} from the installed client's root file (casc_local keeps only FileDataID -> content)."""
    cfg = casc_local.build_config()
    d = casc_local.read_ekey(casc_local.encoding()[bytes.fromhex(cfg["root"][0])])
    if d[:4] != b"TSFM":
        raise ProbeError("the root file is not the MFST format casc_local reads")
    hsize, version = struct.unpack_from("<II", d, 4)
    total, named = struct.unpack_from("<II", d, 12)
    pos = hsize if hsize == 0x18 else 12
    want, out = set(fids), {}
    while pos < len(d):
        n = struct.unpack_from("<I", d, pos)[0]
        if version >= 2:
            loc, u1, u2, u3 = struct.unpack_from("<IIIB", d, pos + 4)
            cflags = u1 | u2 | (u3 << 17)
            pos += 17
        else:
            cflags, loc = struct.unpack_from("<II", d, pos + 4)
            pos += 12
        deltas = struct.unpack_from("<%di" % n, d, pos)
        pos += 4 * n + 16 * n
        fid, ids = -1, []
        for dl in deltas:
            fid += 1 + dl
            ids.append(fid)
        if named and not cflags & 0x10000000:
            hashes = struct.unpack_from("<%dQ" % n, d, pos)
            pos += 8 * n
            for f, h in zip(ids, hashes):
                if f in want:
                    out.setdefault(f, set()).add(h)
    return out


def white_texels(blp):
    """True when every texel of every mip of a BLP2 is exactly (255, 255, 255) and opaque (DXT1 without alpha or
    uncompressed BGRA)."""
    if blp[:4] != b"BLP2":
        return False
    comp, alpha_depth = blp[8], blp[9]
    offs = struct.unpack_from("<16I", blp, 20)
    sizes = struct.unpack_from("<16I", blp, 84)
    if not any(sizes):
        return False
    for o, s in zip(offs, sizes):
        if not s:
            continue
        d = blp[o:o + s]
        if len(d) != s:
            return False
        if comp == 2 and alpha_depth == 0:
            for k in range(0, s, 8):
                c0, c1, bits = struct.unpack_from("<HHI", d, k)
                for i in range(16):
                    j = (bits >> 2 * i) & 3
                    if c0 <= c1 and j == 3:
                        return False                      # transparent black in three-colour mode
                    if (j == 0 and c0 != 0xFFFF) or (j == 1 and c1 != 0xFFFF) or (j > 1 and (c0, c1) != (0xFFFF, 0xFFFF)):
                        return False
        elif comp == 3:
            if set(d) != {255}:
                return False
        else:
            return False
    return True


# ---------------------------------------------------------------------------------------------------------------
# The probe files
# ---------------------------------------------------------------------------------------------------------------

def box_vertices(cube):
    """The unit cube (+-0.5) stretched to BOX with its corner at the origin (positive scales keep the winding and
    the axis-aligned face normals)."""
    out = []
    for v in cube.vertices():
        out.append(v._replace(pos=tuple((v.pos[k] + 0.5) * BOX[k] for k in range(3))))
    return out


def build():
    """-> ({file name: bytes}, {file name: description}, facts for the manifest). Checks nothing yet."""
    cube_bytes = game_file(UNITCUBE)
    cube = W.M2.parse(cube_bytes)
    if cube.file_ids("SFID") != [UNITCUBE_SKIN] or cube.file_ids("TXID") != [WHITE1]:
        raise ProbeError("spells/unitcube.m2 no longer uses skin %d / texture %d" % (UNITCUBE_SKIN, WHITE1))
    cube_skin = W.Skin.parse(game_file(UNITCUBE_SKIN))
    files, about = {}, {}

    files["probe_copy.m2"] = cube_bytes

    box = W.M2.parse(cube_bytes)
    box.set_vertices(box_vertices(cube))
    box.update_bounds()
    files["probe_box_md21.m2"] = box.to_bytes()

    own_skin = W.single_mesh_skin(box, triangles(cube_skin), cube_skin).to_bytes()
    noskin = W.M2.parse(files["probe_box_md21.m2"])
    noskin.drop_chunk("SFID")
    files["probe_box_noskin.m2"] = noskin.to_bytes()
    files["probe_box_noskin00.skin"] = own_skin

    files["probe_box_md20.m2"] = W.legacy_md20(W.M2.parse(files["probe_box_md21.m2"]), [WHITE1_NAME]).to_bytes()
    files["probe_box_md2000.skin"] = own_skin

    sup = W.M2.parse(game_file(CHECKER_MODEL))
    if sup.file_ids("SFID") != [CHECKER_SKIN]:
        raise ProbeError("hellfiresupplies_01.m2 no longer uses skin %d" % CHECKER_SKIN)
    quads, others = pieces(W.Skin.parse(game_file(CHECKER_SKIN)))
    if others:
        raise ProbeError("skin %d is no longer only separate quads (%d other pieces)" % (CHECKER_SKIN, len(others)))
    cell = BOARD / CELLS
    spots = [(i, j) for j in range(CELLS) for i in range(CELLS) if (i + j) % 2 == 0]
    if len(quads) < len(spots):
        raise ProbeError("skin %d has %d quads for %d cells" % (CHECKER_SKIN, len(quads), len(spots)))
    pos, uv = {}, {}
    for (i, j), q in zip(spots, quads):
        uv.update(place_quad(pos, q, i * cell, j * cell, (i + 1) * cell, (j + 1) * cell))
    sup.set_vertices(flat_vertices(sup, pos, uv))
    flags, blend = sup.materials()[0]
    sup.set_material(0, flags | TWO_SIDED, blend)      # (seen from below too: the probe must not hide by angle)
    sup.clear_collision()                              # (the crate's collision mesh has nothing to do with a board)
    sup = W.relayout(sup)                              # (closes the gap the collision data left)
    sup.update_bounds()
    files["probe_checker.m2"] = sup.to_bytes()

    depth = W.M2.parse(cube_bytes)
    cq, rest = pieces(cube_skin)
    if len(cq) != 6 or rest:
        raise ProbeError("skin %d is no longer six quads" % UNITCUBE_SKIN)
    pos, uv = {}, {}
    uv.update(place_quad(pos, cq[0], 0.0, 0.0, SQUARE, SQUARE))
    depth.set_vertices(flat_vertices(depth, pos, uv))
    # depth test and depth write stay on (0x8, 0x10 clear); unfogged, so a scene's fog colour cannot tint through
    depth.set_material(0, UNLIT | UNFOGGED | TWO_SIDED, MOD)
    depth.set_file_id("TXID", 0, WHITE)
    depth.update_bounds()
    files["probe_depth.m2"] = depth.to_bytes()

    facts = {"build": casc_local.build_name(), "checker_quads": len(quads), "checker_cells": len(spots)}
    about.update({
        "probe_copy.m2": ("Byte-identical copy of spells/unitcube.m2 (FileDataID %d): a grey-white cube, 1 x 1 x 1 yd, "
                          "centred on the actor position (-0.5..0.5 on every axis). Skin %d and texture %d by "
                          "FileDataID. Control: does a loose byte copy load at all? A cube here may still be the "
                          "cached game cube (the client caches models by content key, and these are the very same "
                          "bytes): the proof that loose files are read is probe_box_md21.m2 filling its 3 x 1 x 2 "
                          "frame (its bounding box and GetModelFileID)." % (UNITCUBE, UNITCUBE_SKIN, WHITE1)),
        "probe_box_md21.m2": ("The unit cube's file with its 24 vertices moved: a box 3 yd along +x, 1 yd along +y, "
                              "2 yd up (+z), bounds x 0..3, y 0..1, z 0..2, one corner exactly on the actor position "
                              "(SetUseCenterForOrigin(false, false, false)). Same SFID (skin %d) and TXID (%d) as the "
                              "cube. A 3 x 1 x 2 box proves the loose body was read (not the cached game cube); its "
                              "long side on +x and its height on +z show the axes and handedness. Showing nothing: "
                              "see forceLODCheck under Loading above." % (UNITCUBE_SKIN, WHITE1)),
        "probe_box_noskin.m2": ("The same box (x 0..3, y 0..1, z 0..2) without the SFID chunk. Its triangles exist only "
                                "in probe_box_noskin00.skin next to it: the box shows only if the client finds a loose "
                                "skin by name for an MD21 model. Texture by TXID %d. No client model loads this way: "
                                "load it alone (see Loading above)." % WHITE1),
        "probe_box_noskin00.skin": ("Skin of probe_box_noskin.m2: 24 vertices, 12 triangles, 1 submesh, 1 batch "
                                    "(Blizzard's unit cube skin %d with the submesh centre and radius of the box)." % UNITCUBE_SKIN),
        "probe_box_md20.m2": ("The same box (x 0..3, y 0..1, z 0..2) as a legacy non-chunked MD20 file (version 274, "
                              "no SFID/TXID/TXAC/LDV1 chunks); its texture is named '%s' (the client's root maps that "
                              "name to %d). Shows only if the client loads a non-chunked model, finds "
                              "probe_box_md2000.skin by name and the texture by name. No client model loads this way: "
                              "load it alone (see Loading above)." % (WHITE1_NAME, WHITE1)),
        "probe_box_md2000.skin": "Skin of probe_box_md20.m2 (the same bytes as probe_box_noskin00.skin).",
        "probe_checker.m2": ("A flat checkerboard 4 x 4 yd at z 0 (x 0..4, y 0..4): 8 x 8 cells of 0.5 yd, the cell at "
                             "the actor position filled and every other one after it (32 filled), each showing the "
                             "whole texture of hellfiresupplies_01 (a 2 x 2 atlas of wooden crate sides; the quarter "
                             "with a red emblem should sit in each cell's +x / -y quarter if texture coordinate 0, 0 is "
                             "the image's top left). Body: model %d with its %d vertices "
                             "rewritten (32 of skin %d's %d separate quads laid on the cells, the rest collapsed "
                             "onto the origin); two-sided; SFID %d and TXID kept; collision removed. Proves our own "
                             "geometry can be drawn through a Blizzard skin." % (CHECKER_MODEL, len(sup.vertices()),
                                                                                CHECKER_SKIN, len(quads), CHECKER_SKIN)),
        "probe_depth.m2": ("A 4 x 4 yd square at z 0 (x 0..4, y 0..4), unlit, unfogged (a scene's fog colour cannot "
                           "tint through it), blend Mod (frame colour x texel) over particles/white_64.blp "
                           "(FileDataID %d: every texel exactly 255, 255, 255), two-sided, depth test and depth write "
                           "on. If it works it is INVISIBLE yet hides models drawn after it (in scenes drawn later) "
                           "behind it. Mod is a transparent blend: the client draws it after the opaque pass, so it "
                           "never hides an opaque model of its own scene, and which of two scenes draws first is not "
                           "known: call depth write broken only if no arrangement shows a hole (the square's scene "
                           "below and above the cube's, created before and after it). Keep it alone in its scene: its "
                           "borrowed skin sorts it by the unit cube's sphere (centre 0, 0, 0, radius 0.866), wrongly "
                           "against other transparent things such as particle glows. Built from the unit cube (skin "
                           "%d by SFID): one face moved, the other five collapsed onto the origin." % (WHITE, UNITCUBE_SKIN)),
    })
    return files, about, facts


def check_all(files, facts):
    """Every check before anything is written. Returns {name: Report}; raises ProbeError listing every failure."""
    failures, reports = [], {}

    def need(cond, msg):
        if not cond:
            failures.append(msg)

    cube_bytes = game_file(UNITCUBE)
    need(files["probe_copy.m2"] == cube_bytes, "probe_copy.m2 differs from the client's %d" % UNITCUBE)
    skins = {
        "probe_box_noskin.m2": {0: files["probe_box_noskin00.skin"]},
        "probe_box_md20.m2": {0: files["probe_box_md2000.skin"]},
    }
    for name in ("probe_copy.m2", "probe_box_md21.m2", "probe_box_noskin.m2", "probe_box_md20.m2", "probe_checker.m2",
                 "probe_depth.m2"):
        rep = W.validate_m2(files[name], loose_skins=skins.get(name), game_file=game_file, label=name)
        reports[name] = rep
        for p in rep.problems:
            failures.append("%s: %s" % (name, p))

    def geo(name):
        rep = reports[name]
        sk = rep.info.get("skin_reports", {}).get(0)
        return rep.info.get("points", []), (sk.info.get("triangles_list", []) if sk else []), rep

    def drawn(points, tris):
        """The triangles with area, and their normals' direction."""
        out = []
        for a, b, c in tris:
            p, q, r = points[a], points[b], points[c]
            u = [q[k] - p[k] for k in range(3)]
            v = [r[k] - p[k] for k in range(3)]
            n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
            if any(abs(x) > 1e-9 for x in n):
                out.append(((p, q, r), n))
        return out

    # the box variants: 12 outward-facing triangles inside 0..3 x 0..1 x 0..2
    for name in ("probe_box_md21.m2", "probe_box_noskin.m2", "probe_box_md20.m2"):
        pts, tris, rep = geo(name)
        need(rep.info.get("box") == (0.0, 0.0, 0.0) + BOX, "%s: bounds %s" % (name, rep.info.get("box")))
        d = drawn(pts, tris)
        need(len(d) == 12, "%s: %d drawn triangles, a box has 12" % (name, len(d)))
        centre = [BOX[k] / 2 for k in range(3)]
        for (p, q, r), n in d:
            mid = [(p[k] + q[k] + r[k]) / 3 for k in range(3)]
            need(sum(n[k] * (mid[k] - centre[k]) for k in range(3)) > 0, "%s: a face winds inward" % name)
    need(files["probe_box_noskin00.skin"] == files["probe_box_md2000.skin"], "the two box skins differ")
    rep = reports["probe_box_md21.m2"]
    need(rep.info.get("sfid") == (UNITCUBE_SKIN,), "probe_box_md21.m2: SFID %s" % (rep.info.get("sfid"),))
    need(rep.info.get("textures_files") == [WHITE1], "probe_box_md21.m2: textures %s" % rep.info.get("textures_files"))
    need("SFID" not in reports["probe_box_noskin.m2"].info.get("chunks", []), "probe_box_noskin.m2 has an SFID")
    need(reports["probe_box_md20.m2"].info.get("chunks") == [], "probe_box_md20.m2 is chunked")
    need(reports["probe_box_md20.m2"].info.get("version") == W.VERSION, "probe_box_md20.m2: version")
    need(reports["probe_box_md20.m2"].info.get("textures_files") == [WHITE1_NAME], "probe_box_md20.m2: texture name")
    hashes = root_name_hashes([WHITE1])
    need(name_hash(WHITE1_NAME) in hashes.get(WHITE1, ()), "the client's root does not map %s to %d" % (WHITE1_NAME, WHITE1))

    # the flat ones: every drawn triangle in the z = 0 plane, inside the square, facing up
    for name, size, count in (("probe_checker.m2", BOARD, 2 * facts["checker_cells"]), ("probe_depth.m2", SQUARE, 2)):
        pts, tris, rep = geo(name)
        need(rep.info.get("box") == (0.0, 0.0, 0.0, size, size, 0.0), "%s: bounds %s" % (name, rep.info.get("box")))
        d = drawn(pts, tris)
        need(len(d) == count, "%s: %d drawn triangles, expected %d" % (name, len(d), count))
        area = 0.0
        for (p, q, r), n in d:
            need(n[2] > 0 and abs(n[0]) < 1e-9 and abs(n[1]) < 1e-9, "%s: a triangle not flat facing up" % name)
            need(all(0 <= x[0] <= size and 0 <= x[1] <= size and x[2] == 0 for x in (p, q, r)),
                 "%s: a triangle outside the square" % name)
            area += n[2] / 2
        want = size * size / (2 if name == "probe_checker.m2" else 1)
        need(abs(area - want) < 1e-6, "%s: drawn area %.4f, expected %.4f" % (name, area, want))
    rep = reports["probe_depth.m2"]
    need(rep.info.get("materials") == [(UNLIT | UNFOGGED | TWO_SIDED, MOD)],
         "probe_depth.m2: material %s" % rep.info.get("materials"))
    need(rep.info.get("textures_files") == [WHITE], "probe_depth.m2: texture %s" % rep.info.get("textures_files"))
    need(white_texels(game_file(WHITE)), "texture %d is not exactly white" % WHITE)
    need(reports["probe_checker.m2"].info.get("sfid") == (CHECKER_SKIN,), "probe_checker.m2: SFID")
    for name, rep in reports.items():
        need(rep.info.get("static") is True, "%s: animated bones" % name)
        need(not any("not referenced" in n for n in rep.notes), "%s: bytes nothing points at" % name)
    if failures:
        raise ProbeError("probe files not written:\n  " + "\n  ".join(failures))
    return reports


def manifest(files, about, facts, reports):
    lines = [
        "DisasterZone loose-model probe (dev/generators/gen_probe.py; never shipped: release.py leaves Media/Probe out)",
        "Built from the installed client %s. Load each with actor:SetModelByPath(\"%s<file>\")." % (facts["build"], GAME_DIR),
        "Positions in yards with SetUseCenterForOrigin(false, false, false): the model's origin on the actor position.",
        "Control: the stock cube, actor:SetModelByFileID(%d) (centred, 1 yd)." % UNITCUBE,
        "",
        "Loading (a malformed loose file may crash the client, and a crash loses every result of that run):",
        "  - probe_copy, probe_box_md21, probe_checker and probe_depth in one run; /reload to save its results.",
        "  - Then probe_box_noskin and probe_box_md20, each alone (/dz 3d probe only noskin, only md20): no client",
        "    model loads that way (MD21 without SFID, non-chunked MD20), so either may be the one that crashes.",
        "  - Note GetCVar(\"forceLODCheck\"). By default the client takes a model's LOD count from its ModelFileData",
        "    row (a loose file has none); with forceLODCheck on it scans the model's folder for skin files instead (the",
        "    setting's help text in the executable). If md21, noskin or md20 shows nothing, load it once more with",
        "    forceLODCheck 1, then set it back.",
        "",
    ]
    for name in NAMES[:-1]:
        data = files[name]
        rep = reports.get(name)
        lines.append(name)
        lines.append("  %d bytes, sha256 %s" % (len(data), hashlib.sha256(data).hexdigest()[:16]))
        if rep is not None:
            box = rep.info["box"]
            lines.append("  bounds x %g..%g, y %g..%g, z %g..%g yd, radius %.3f" % (
                box[0], box[3], box[1], box[4], box[2], box[5], rep.info["radius"]))
            lines.append("  %s, version %d, chunks %s" % ("MD21" if rep.info["chunks"] else "MD20 (not chunked)",
                                                           rep.info["version"], ",".join(rep.info["chunks"]) or "none"))
            for note in rep.notes:
                lines.append("  note: " + note)
        text = about[name]
        while text:
            cut = text.rfind(" ", 0, 112) if len(text) > 112 else len(text)
            lines.append("  " + text[:cut].strip())
            text = text[cut:].strip()
        lines.append("")
    return ("\n".join(lines).rstrip() + "\n").encode("ascii")


def generate(out_dir=OUT):
    """Build, check, then write every probe file into out_dir (nothing is written when a check fails)."""
    files, about, facts = build()
    reports = check_all(files, facts)
    files["manifest.txt"] = manifest(files, about, facts, reports)
    os.makedirs(out_dir, exist_ok=True)
    for name in NAMES:
        with open(os.path.join(out_dir, name), "wb") as fh:
            fh.write(files[name])
    return files, reports


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=OUT, help="folder to write (default: the addon's Media/Probe)")
    args = ap.parse_args()
    try:
        files, reports = generate(args.out)
    except (ProbeError, W.M2Error, W.ValidationError) as e:
        print(str(e))
        sys.exit(1)
    for name in NAMES:
        print("  %-26s %7d bytes" % (name, len(files[name])))
    for name, rep in reports.items():
        for note in rep.notes:
            print("  note %s: %s" % (name, note))
    print("probe files written to %s (client %s)" % (args.out, casc_local.build_name()))


if __name__ == "__main__":
    main()
