"""Raid Trainer: each encounter room's real floor heights and its real mesh, from Blizzard's building geometry
(WMO root + group files). Files are fetched from wago.tools into dev/art/wmo/ (git-ignored, Blizzard's data).

Teron Gorefiend's hall: group 31 of world/wmo/dungeon/blacktemple/blacktemple.wmo (root 108713, group file 108745,
WMOGroupID 22426, "Gorefiend's Vigil"). Its floor spans local x -675..-615 and y -817..-759; the entrance corridor
leaves on the +y side, which is south on Blizzard's map, so the room is turned half round:
arena x = -615 - local x, arena y = -759 - local y, height = local z - 371.75 (the hall's main floor).

Lady Vashj's room: group 6 of world/wmo/dungeon/ol_coilfang/coilfang_raid.wmo (root 112018, group file 112025).
The map's one WMO sits at the origin unturned, which makes world = (-local x, -local y, local z); Vashj's spot
(world 29.83, -923.27, 42.90, the boss scripts' centre point) is local (-29.83, 923.27). The arena is a 210 yd
square round her with x east and y north (the game's world x is north, world y is west):
arena x = local y - 923.27 + 105, arena y = -local x - 29.83 + 105, height = local z - 42.9 (her platform).

Writes Games/Trainer/Encounters/<Name>Floor.lua:
  rows: one character per square yard, south to north, west to east: height = index in `alphabet` * step + base;
        a space = no floor there (not walkable);
  mesh: the room's own triangles (floor, steps, walls up to mesh_top yd; ceilings and what faces down left out),
        with their texture files, texture coordinates and baked light. Triangles longer than MAX_EDGE are split.
        Data format version 2 (see dev/docs/trainer_renderer_v2/spec.md section 2):
          version  = 2;
          textures = file IDs, one per texture index; a file may repeat when it is used with another blend;
          blend    = per texture index: "DISABLE" (MOMT blend 0, opaque), "ALPHAKEY" (1) or "BLEND" (anything else);
          verts    = x, y, z (3 decimals), u, v (4 decimals), light (2 decimals);
          tris     = a, b, c, texture index, listed node by node;
          nodes    = plane a, b, c (4 decimals), d (2 decimals), front, back, first triangle, count;
          pair     = per triangle the 1-based index of its quad mate (same node and texture, one shared edge walked
                     the other way, a strictly convex union, the mate's UV on the triangle's affine map, light
                     span <= 0.15) or 0. The renderer may draw a pair as one quad texture (a, b, d, c).
        The run checks itself (triangles on their node's plane, every pair re-checked, node count, vertex indices)
        and fails if anything is off. Each file is written to a temporary file first and then moved into place.

Run: luaenv\\Scripts\\python.exe generators\\gen_trainer_heights.py [teron|vashj]
"""
import collections
import math
import os
import sys
import urllib.request

import wmo_tools as W

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "art", "wmo")
OUT_DIR = os.path.join(HERE, "..", "..", "addon", "DisasterZone", "Games", "Trainer", "Encounters")
MAX_EDGE = 9.0
FORMAT_VERSION = 2
BLEND_NAMES = {0: "DISABLE", 1: "ALPHAKEY"}       # MOMT blend mode -> SetBlendMode; anything else is "BLEND"
PAIR_CONVEX_MARGIN = 1e-4   # yd, in the plane: the quad's diagonals must cross at least this far from any end
PAIR_UV_TOL = 1e-3          # the mate's lone vertex UV against the triangle's affine map
PAIR_LIGHT_SPAN = 0.15      # light range over the quad's 4 corners
PLANE_TOL = 0.03            # yd: a triangle's vertices off its node's (written) plane
MAX_NODES = 3000
ALPHA62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

ROOMS = {
    "teron": dict(
        out="TeronGorefiendFloor.lua", key="teron", root=108713, group=108745,
        title="Teron Gorefiend's hall as Blizzard built it (blacktemple.wmo, group \"Gorefiend's Vigil\")",
        w=60, h=58, z_main=371.75, base=-3.0, step=0.25, top=2.0, alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        blank=False, floor_top=4.5, floor_bottom=-50, mesh_top=12.0,
        to_arena=lambda x, y: (-615.0 - x, -759.0 - y),
        to_local=lambda ax, ay: (-615.0 - ax, -759.0 - ay),
    ),
    "vashj": dict(
        out="LadyVashjFloor.lua", key="vashj", root=112018, group=112025,
        title="Lady Vashj's room as Blizzard built it (coilfang_raid.wmo, group 6)",
        w=210, h=210, z_main=42.9, base=-26.0, step=0.5, top=4.5, alphabet=ALPHA62,
        blank=True, floor_top=6.0, floor_bottom=-27.0, mesh_top=6.0, radius=100.0, band=7.0, max_edge=40.0,
        to_arena=lambda x, y: (y - 923.27 + 105.0, -x - 29.83 + 105.0),
        to_local=lambda ax, ay: (-(ay - 105.0) - 29.83, ax - 105.0 + 923.27),
    ),
}


def fetch(fdid):
    for ext in (".wmo", ".bin"):
        path = os.path.join(ART, "%d%s" % (fdid, ext))
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return path
    path = os.path.join(ART, "%d.wmo" % fdid)
    os.makedirs(ART, exist_ok=True)
    req = urllib.request.Request("https://wago.tools/api/casc/%d?download" % fdid, headers={"User-Agent": "Mozilla/5.0"})
    open(path, "wb").write(urllib.request.urlopen(req, timeout=120).read())
    return path


def normal(a, b, c):
    ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
    vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
    nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    ln = math.sqrt(nx * nx + ny * ny + nz * nz)
    return (nx / ln, ny / ln, nz / ln) if ln > 1e-6 else None


class Floor:
    """The faces you can stand on, bucketed for point lookups."""

    def __init__(self, group, room):
        self.grid = collections.defaultdict(list)
        lo, hi = room["z_main"] + room["floor_bottom"], room["z_main"] + room["floor_top"]
        for t in group["tris"]:
            a, b, c = [group["verts"][i] for i in t]
            n = normal(a, b, c)
            if n and abs(n[2]) > 0.5 and max(a[2], b[2], c[2]) < hi and min(a[2], b[2], c[2]) > lo:
                xs, ys = [p[0] for p in (a, b, c)], [p[1] for p in (a, b, c)]
                for gx in range(int(min(xs) // 8), int(max(xs) // 8) + 1):
                    for gy in range(int(min(ys) // 8), int(max(ys) // 8) + 1):
                        self.grid[(gx, gy)].append((a, b, c))

    def height(self, x, y):
        best = None
        for a, b, c in self.grid.get((int(x // 8), int(y // 8)), ()):
            d = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
            if abs(d) < 1e-9:
                continue
            w1 = ((b[1] - c[1]) * (x - c[0]) + (c[0] - b[0]) * (y - c[1])) / d
            w2 = ((c[1] - a[1]) * (x - c[0]) + (a[0] - c[0]) * (y - c[1])) / d
            w3 = 1 - w1 - w2
            if w1 >= -1e-4 and w2 >= -1e-4 and w3 >= -1e-4:
                z = w1 * a[2] + w2 * b[2] + w3 * c[2]
                if best is None or z > best:
                    best = z
        return best


EPS = 0.02


def plane_of(tri):
    n = normal(tri[0][:3], tri[1][:3], tri[2][:3])
    if not n:
        return None
    return (n[0], n[1], n[2], -(n[0] * tri[0][0] + n[1] * tri[0][1] + n[2] * tri[0][2]))


def split_tri(tri, plane):
    """Cut a triangle (3 vertices of x, y, z, u, v, light) by a plane -> (front pieces, back pieces)."""
    d = [plane[0] * p[0] + plane[1] * p[1] + plane[2] * p[2] + plane[3] for p in tri]
    front, back = [], []
    for k in range(3):
        a, b, da, db = tri[k], tri[(k + 1) % 3], d[k], d[(k + 1) % 3]
        if da >= -EPS:
            front.append(a)
        if da <= EPS:
            back.append(a)
        if (da > EPS and db < -EPS) or (da < -EPS and db > EPS):
            t = da / (da - db)
            m = tuple(a[i] + (b[i] - a[i]) * t for i in range(6))
            front.append(m)
            back.append(m)

    def fan(poly):
        return [(poly[0], poly[i], poly[i + 1]) for i in range(1, len(poly) - 1)] if len(poly) >= 3 else []
    return fan(front), fan(back)


def build_bsp(tris, rng):
    """tris: [(tex, (v0, v1, v2))] -> nodes [{plane, front, back, tris}] (children are node indices, 0 = none).
    Painting a node's far side, then its own triangles, then its near side gives an exact back-to-front order
    from any viewpoint."""
    nodes = [None]                                    # 1-based, like Lua
    work = [(tris, None, None)]                       # (triangles, parent node index, 'front' / 'back')
    while work:
        items, parent, side = work.pop()
        if not items:
            continue
        # the splitter: of a few candidates the one that cuts the fewest triangles and balances best
        best, best_score = None, None
        cands = items if len(items) <= 14 else rng.sample(items, 14)
        sample = items if len(items) <= 400 else rng.sample(items, 400)
        for _, tri in cands:
            pl = plane_of(tri)
            if not pl:
                continue
            f = b = sp = 0
            for _, other in sample:
                d = [pl[0] * p[0] + pl[1] * p[1] + pl[2] * p[2] + pl[3] for p in other]
                if max(d) <= EPS and min(d) >= -EPS:
                    continue
                if min(d) >= -EPS:
                    f += 1
                elif max(d) <= EPS:
                    b += 1
                else:
                    sp += 1
            score = sp * 6 + abs(f - b)
            if best_score is None or score < best_score:
                best, best_score = pl, score
        if best is None:                              # only degenerate triangles left
            continue
        node = {"plane": best, "front": 0, "back": 0, "tris": []}
        nodes.append(node)
        me = len(nodes) - 1
        if parent:
            nodes[parent][side] = me
        fr, bk = [], []
        for tex, tri in items:
            d = [best[0] * p[0] + best[1] * p[1] + best[2] * p[2] + best[3] for p in tri]
            if max(d) <= EPS and min(d) >= -EPS:
                node["tris"].append((tex, tri))
            elif min(d) >= -EPS:
                fr.append((tex, tri))
            elif max(d) <= EPS:
                bk.append((tex, tri))
            else:
                f, b = split_tri(tri, best)
                fr += [(tex, t) for t in f if plane_of(t)]
                bk += [(tex, t) for t in b if plane_of(t)]
        work.append((fr, me, "front"))
        work.append((bk, me, "back"))
    return nodes


def build_mesh(root, group, room):
    """-> (textures, blends, verts [(x, y, z, u, v, light)], tris [(a, b, c, texture index)], nodes [(plane, front,
    back, first triangle, count)]) in arena coordinates. The triangles are listed node by node. A texture index
    stands for a (file ID, MOMT blend) pair; blends holds its SetBlendMode name."""
    import random
    textures, blends, tex_index = [], [], {}
    to_arena, z_main = room["to_arena"], room["z_main"]
    radius = room.get("radius")
    cx, cy = room["w"] / 2.0, room["h"] / 2.0
    raw_tris = []
    colors = group.get("colors")
    for t, mat in zip(group["tris"], group["mats"]):
        if mat == 255:                                   # collision only
            continue
        raw = [group["verts"][i] for i in t]
        n = normal(*raw)
        if not n or n[2] < -0.3:                         # faces down: a ceiling, the underside of a ledge
            continue
        if min(p[2] for p in raw) > z_main + room["mesh_top"]:
            continue
        file_id = root["materials"][mat]["texture"]
        blend = root["materials"][mat]["blend"]
        if not file_id:
            continue
        pts = []
        for i in t:
            x, y, z = group["verts"][i]
            u, v = group["uvs"][i]
            light = 1.0
            if colors:
                b, g, r, _ = colors[i]
                light = (0.3 * r + 0.59 * g + 0.11 * b) / 127.0      # 127 = the texture as it is
            ax, ay = to_arena(x, y)
            pts.append((ax, ay, z - z_main, u, v, max(0.25, min(1.0, light))))
        if radius and min(math.hypot(p[0] - cx, p[1] - cy) for p in pts) > radius:
            continue                                     # outside the part of the room the fight uses
        tkey = (file_id, blend)
        if tkey not in tex_index:
            tex_index[tkey] = len(textures) + 1          # Lua index
            textures.append(file_id)
            blends.append(BLEND_NAMES.get(blend, "BLEND"))
        # both rooms are turned, not mirrored, so the winding (and with it the front face) stays
        raw_tris.append((tex_index[tkey], (pts[0], pts[1], pts[2])))

    nodes = build_bsp(raw_tris, random.Random(7))

    verts, vert_index, tris, out_nodes = [], {}, [], []

    def vert(p):
        key = (round(p[0], 3), round(p[1], 3), round(p[2], 3), round(p[3], 4), round(p[4], 4), round(p[5], 2))
        if key not in vert_index:
            vert_index[key] = len(verts)
            verts.append(key)
        return vert_index[key]

    def emit(pa, pb, pc, tex):
        # long pieces are cut (inside their node: the order does not care) so textures do not swim
        edges = [(math.dist(pa[:3], pb[:3]), 0), (math.dist(pb[:3], pc[:3]), 1), (math.dist(pc[:3], pa[:3]), 2)]
        longest, which = max(edges)
        if longest > room.get("max_edge", MAX_EDGE):
            pts = [pa, pb, pc]
            p, q, r = pts[which], pts[(which + 1) % 3], pts[(which + 2) % 3]
            m = tuple((p[i] + q[i]) / 2 for i in range(6))
            emit(p, m, r, tex)
            emit(m, q, r, tex)
            return
        a, b, c = vert(pa), vert(pb), vert(pc)
        if a != b and b != c and a != c:
            tris.append((a, b, c, tex))

    for node in nodes[1:]:
        first = len(tris)
        for tex, tri in node["tris"]:
            emit(tri[0], tri[1], tri[2], tex)
        out_nodes.append((node["plane"], node["front"], node["back"], first + 1, len(tris) - first))
    return textures, blends, verts, tris, out_nodes


def num3(v):
    s = ("%.3f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def num4(v):
    s = ("%.4f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def num(v):
    s = ("%.2f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def _sub(p, q):
    return (p[0] - q[0], p[1] - q[1], p[2] - q[2])


def _dot(p, q):
    return p[0] * q[0] + p[1] * q[1] + p[2] * q[2]


def _cross(p, q):
    return (p[1] * q[2] - p[2] * q[1], p[2] * q[0] - p[0] * q[2], p[0] * q[1] - p[1] * q[0])


def pair_reason(verts, tris, node_of, i, j):
    """None when triangles i and j (0-based) may be drawn as one quad (spec section 2, rule 3), else why not.
    The rules are tested from both triangles (each one as i), so the answer does not depend on the order: the
    convexity margin and the UV tolerance are measured in the plane of i, which differs from j's by rounding."""
    return _pair_reason_from(verts, tris, node_of, i, j) or _pair_reason_from(verts, tris, node_of, j, i)


def _pair_reason_from(verts, tris, node_of, i, j):
    if i == j:
        return "same triangle"
    if node_of[i] != node_of[j]:
        return "other node"
    ti, tj = tris[i], tris[j]
    if ti[3] != tj[3]:
        return "other texture"
    shared = set(ti[:3]) & set(tj[:3])
    if len(shared) != 2:
        return "shares %d vertices" % len(shared)
    k = next((k for k in range(3) if ti[k] in shared and ti[(k + 1) % 3] in shared), None)
    if k is None:
        return "no shared edge"
    b, c, a = ti[k], ti[(k + 1) % 3], ti[(k + 2) % 3]            # i = (a, b, c), the shared edge is (b, c)
    m = next((m for m in range(3) if tj[m] == c and tj[(m + 1) % 3] == b), None)
    if m is None:
        return "winding"
    d = tj[(m + 2) % 3]                                         # j's lone vertex; the quad is (a, b, d, c)
    pa, pb, pc, pd = verts[a], verts[b], verts[c], verts[d]
    ni, nj = normal(pa[:3], pb[:3], pc[:3]), normal(pc[:3], pb[:3], pd[:3])
    if not ni or not nj or _dot(ni, nj) <= 0:
        return "normals"
    # 2D coordinates in the plane of i, relative to b: e1 along b->c, e2 = ni x e1
    bc = _sub(pc, pb)
    lbc = math.sqrt(_dot(bc, bc))
    e1 = (bc[0] / lbc, bc[1] / lbc, bc[2] / lbc)
    e2 = _cross(ni, e1)

    def p2(p):
        r = _sub(p, pb)
        return (_dot(r, e1), _dot(r, e2))
    A, B, C, D = p2(pa), p2(pb), p2(pc), p2(pd)

    def side(o, t, q):                      # signed distance (yd) of q from the line o->t
        dx, dy = t[0] - o[0], t[1] - o[1]
        ln = math.hypot(dx, dy)
        if ln < 1e-9:
            return 0.0
        return (dx * (q[1] - o[1]) - dy * (q[0] - o[0])) / ln
    sa, sd = side(B, C, A), side(B, C, D)
    sb, sc = side(A, D, B), side(A, D, C)
    mg = PAIR_CONVEX_MARGIN
    if not ((sa > mg and sd < -mg) or (sa < -mg and sd > mg)) or not ((sb > mg and sc < -mg) or (sb < -mg and sc > mg)):
        return "not strictly convex"
    # UV: d's UV against triangle i's affine map (3D position -> UV) evaluated at d's position, and (so the rule
    # does not depend on which of the two is called i) a's UV against triangle j's map
    def uv_off(P, Q, R, S, uP, uQ, uR, uS):
        den = (Q[1] - R[1]) * (P[0] - R[0]) + (R[0] - Q[0]) * (P[1] - R[1])
        if abs(den) < 1e-12:
            return None
        w1 = ((Q[1] - R[1]) * (S[0] - R[0]) + (R[0] - Q[0]) * (S[1] - R[1])) / den
        w2 = ((R[1] - P[1]) * (S[0] - R[0]) + (P[0] - R[0]) * (S[1] - R[1])) / den
        w3 = 1.0 - w1 - w2
        return max(abs(w1 * uP[q] + w2 * uQ[q] + w3 * uR[q] - uS[q]) for q in (3, 4))
    e_i = uv_off(A, B, C, D, pa, pb, pc, pd)
    e_j = uv_off(D, C, B, A, pd, pc, pb, pa)
    if e_i is None or e_j is None:
        return "degenerate"
    if e_i > PAIR_UV_TOL or e_j > PAIR_UV_TOL:
        return "uv"
    lights = (pa[5], pb[5], pc[5], pd[5])
    if max(lights) - min(lights) > PAIR_LIGHT_SPAN + 1e-9:
        return "light"
    return None


def pair_tris(verts, tris, nodes):
    """Greedy quad pairing, node by node in triangle order; for each triangle its edges longest first.
    -> (pair: 1-based mate per triangle or 0, node_of: 0-based node per triangle)"""
    n = len(tris)
    node_of = [0] * n
    for ni, (_, _, _, first, count) in enumerate(nodes):
        for t in range(first - 1, first - 1 + count):
            node_of[t] = ni
    pair = [0] * n
    for _, _, _, first, count in nodes:
        lo, hi = first - 1, first - 1 + count
        by_edge = collections.defaultdict(list)          # directed edge (x, y) -> triangles walking x -> y
        for t in range(lo, hi):
            a, b, c, _ = tris[t]
            for x, y in ((a, b), (b, c), (c, a)):
                by_edge[(x, y)].append(t)
        for i in range(lo, hi):
            if pair[i]:
                continue
            a, b, c, _ = tris[i]
            edges = sorted(((a, b), (b, c), (c, a)), key=lambda e: -math.dist(verts[e[0]][:3], verts[e[1]][:3]))
            for p, q in edges:
                mate = None
                for j in by_edge.get((q, p), ()):
                    if j != i and not pair[j] and pair_reason(verts, tris, node_of, i, j) is None:
                        mate = j
                        break
                if mate is not None:
                    pair[i], pair[mate] = mate + 1, i + 1
                    break
    return pair, node_of


def self_check(name, textures, blends, verts, tris, nodes, pair, node_of):
    """The run fails on any of these (spec section 2, rule 5). -> the worst triangle-to-plane distance."""
    errors = []
    nv, nt, nn, nx = len(verts), len(tris), len(nodes), len(textures)
    if nn > MAX_NODES:
        errors.append("%d nodes > %d" % (nn, MAX_NODES))
    if len(blends) != nx or any(b not in ("DISABLE", "ALPHAKEY", "BLEND") for b in blends):
        errors.append("blend list does not match the textures")
    for t, (a, b, c, x) in enumerate(tris):
        if not (0 <= a < nv and 0 <= b < nv and 0 <= c < nv):
            errors.append("triangle %d: vertex index out of range" % (t + 1))
        if not 1 <= x <= nx:
            errors.append("triangle %d: texture index %d out of range" % (t + 1, x))
    covered = 0
    worst = 0.0
    for k, (pl, f, b, first, count) in enumerate(nodes):
        if not (0 <= f <= nn and 0 <= b <= nn):
            errors.append("node %d: child out of range" % (k + 1))
        if first != covered + 1:
            errors.append("node %d: triangles not contiguous" % (k + 1))
        covered = first - 1 + count
        A, B, C, D = float(num4(pl[0])), float(num4(pl[1])), float(num4(pl[2])), float(num(pl[3]))   # as written
        for t in range(first - 1, min(nt, first - 1 + count)):
            for vi in tris[t][:3]:
                if 0 <= vi < nv:
                    x, y, z = verts[vi][:3]
                    dist = abs(A * x + B * y + C * z + D)
                    worst = max(worst, dist)
                    if dist > PLANE_TOL:
                        errors.append("triangle %d: %.4f yd off node %d's plane" % (t + 1, dist, k + 1))
    if covered != nt:
        errors.append("nodes cover %d of %d triangles" % (covered, nt))
    if len(pair) != nt:
        errors.append("pair list has %d entries for %d triangles" % (len(pair), nt))
    for i, m in enumerate(pair):
        if m == 0:
            continue
        if not 1 <= m <= nt or pair[m - 1] != i + 1:
            errors.append("triangle %d: pair %d not mutual" % (i + 1, m))
            continue
        why = pair_reason(verts, tris, node_of, i, m - 1)
        if why:
            errors.append("triangle %d + %d: %s" % (i + 1, m, why))
    if errors:
        raise SystemExit("%s: self-check FAILED (%d problems):\n  %s" % (name, len(errors), "\n  ".join(errors[:30])))
    return worst


def round_trip(path, key, textures, blends, verts, tris, nodes, pair):
    """Load the written file in real Lua 5.1 (lupa, when available) and compare it with what was meant."""
    try:
        from lupa import lua51 as lupa
    except ImportError:
        return "skipped (no lupa)"
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    src = open(path, encoding="utf-8").read()
    ns = lua.eval("{}")
    run = lua.eval("function(src, ns) local f = assert(loadstring(src)) f('DisasterZone', ns) end")
    run(src, ns)
    m = ns.TrainerFloors[key].mesh
    lens = lua.eval("function(m) return m.version, #m.textures, #m.blend, #m.verts, #m.tris, #m.nodes, #m.pair end")
    got = tuple(lens(m))
    want = (FORMAT_VERSION, len(textures), len(blends), 6 * len(verts), 4 * len(tris), 8 * len(nodes), len(pair))
    if got != want:
        raise SystemExit("%s: the written file does not load back as written: %r != %r" % (path, got, want))
    for i in range(len(verts)):
        for q in range(6):
            if abs(m.verts[6 * i + q + 1] - verts[i][q]) > 1e-9:
                raise SystemExit("%s: vertex %d differs after loading" % (path, i + 1))
    for i in range(len(pair)):
        if m.pair[i + 1] != pair[i]:
            raise SystemExit("%s: pair %d differs after loading" % (path, i + 1))
    for i in range(len(blends)):
        if m.blend[i + 1] != blends[i] or m.textures[i + 1] != textures[i]:
            raise SystemExit("%s: texture %d differs after loading" % (path, i + 1))
    return "ok"


def write_temp(path, text):
    """Another process may load the file at any moment: write a temporary file next to it first."""
    tmp = os.path.join(os.path.dirname(path), "." + os.path.basename(path) + ".tmp")
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    return tmp


def move_into_place(tmp, path):
    import time
    for attempt in range(20):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:                         # Windows: the target is open in another process right now
            if attempt == 19:
                raise
            time.sleep(0.25)


def generate(name):
    room = ROOMS[name]
    root = W.read_root(fetch(room["root"]))
    group = W.read_group(fetch(room["group"]))
    floor = Floor(group, room)
    alphabet, base, step = room["alphabet"], room["base"], room["step"]
    rows, lo, hi, holes = [], 99, -99, 0
    for j in range(room["h"]):                 # south to north
        row = ""
        for i in range(room["w"]):             # west to east
            lx, ly = room["to_local"](i + 0.5, j + 0.5)
            z = floor.height(lx, ly)
            if z is None and room["blank"]:
                row += " "
                holes += 1
                continue
            h = 0.0 if z is None else max(base, min(room["top"], z - room["z_main"]))
            lo, hi = min(lo, h), max(hi, h)
            row += alphabet[max(0, min(len(alphabet) - 1, int(round((h - base) / step))))]
        rows.append(row)
    textures, blends, verts, mesh_tris, nodes = build_mesh(root, group, room)
    pair, node_of = pair_tris(verts, mesh_tris, nodes)
    worst = self_check(name, textures, blends, verts, mesh_tris, nodes, pair, node_of)
    out = os.path.join(OUT_DIR, room["out"])
    rel = "Games/Trainer/Encounters/" + room["out"]
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end -- DisasterZone %s' % (rel, rel),
        "-- %s, in the trainer's" % room["title"],
        "-- coordinates (yards, x east, y north, height 0 = the main floor).",
        "-- rows: the floor's height, one character per square yard, south to north, west to east:",
        "--       height = (its place in alphabet, from 0) * step + base; a space = no floor there.",
        "-- mesh (data format version 2): the room's own triangles.",
        "--       textures = texture file IDs, one per texture index (a file may repeat with another blend);",
        "--       blend = per texture index its blend mode: \"DISABLE\" (opaque), \"ALPHAKEY\" or \"BLEND\";",
        "--       verts = x, y, z (3 decimals), u, v (4 decimals), light for each vertex;",
        "--       tris = vertex a, b, c (1-based) and texture (index into textures) for each triangle, node by node;",
        "--       nodes = a BSP tree of the triangles: plane a, b, c, d (front = a*x+b*y+c*z+d > 0), front child,",
        "--       back child (0 = none), first triangle and count for each node. Far side, the node, near side:",
        "--       back to front from anywhere;",
        "--       pair = per triangle its quad mate (1-based) or 0: same node and texture, one shared edge, a convex",
        "--       union and matching texture coordinates, so the two can be drawn as one quad (a, b, d, c).",
        "-- AUTO-GENERATED by gen_trainer_heights.py; do not edit by hand.",
        "local _, ns = ...",
        "ns.TrainerFloors = ns.TrainerFloors or {}",
        'ns.TrainerFloors.%s = { w = %d, h = %d, base = %s, step = %s, alphabet = "%s", rows = {'
        % (room["key"], room["w"], room["h"], base, step, alphabet),
    ]
    lines += ['  "%s",' % r for r in rows]
    lines += ["}, mesh = {", "  version = %d," % FORMAT_VERSION,
              "  textures = { %s }," % ", ".join(str(t) for t in textures),
              "  blend = { %s }," % ", ".join('"%s"' % b for b in blends), "  verts = {"]
    for i in range(0, len(verts), 6):
        lines.append("    " + " ".join("%s,%s,%s,%s,%s,%s," % (num3(v[0]), num3(v[1]), num3(v[2]), num4(v[3]), num4(v[4]), num(v[5]))
                                       for v in verts[i:i + 6]))
    lines += ["  },", "  tris = {"]
    for i in range(0, len(mesh_tris), 12):
        lines.append("    " + " ".join("%d,%d,%d,%d," % (a + 1, b + 1, c + 1, t) for a, b, c, t in mesh_tris[i:i + 12]))
    lines += ["  },", "  nodes = {"]
    for i in range(0, len(nodes), 4):
        lines.append("    " + " ".join("%s,%s,%s,%s,%d,%d,%d,%d," % (num4(pl[0]), num4(pl[1]), num4(pl[2]), num(pl[3]), f, b, st, n)
                                       for pl, f, b, st, n in nodes[i:i + 4]))
    lines += ["  },", "  pair = {"]
    for i in range(0, len(pair), 24):
        lines.append("    " + " ".join("%d," % m for m in pair[i:i + 24]))
    lines += ["  },", "} }", ""]
    tmp = write_temp(out, "\n".join(lines))
    try:
        rt = round_trip(tmp, room["key"], textures, blends, verts, mesh_tris, nodes, pair)
    except BaseException:
        os.remove(tmp)
        raise
    move_into_place(tmp, out)
    paired = sum(1 for m in pair if m)
    print("wrote %s: %d x %d, heights %.2f .. %.2f, %d cells without floor"
          % (os.path.normpath(out), room["w"], room["h"], lo, hi, holes))
    print("  self-checks passed (worst plane distance %.4f yd, load-back %s)" % (worst, rt))
    print("  triangles %d, vertices %d, nodes %d, pairs %d (%d triangles paired, %.1f%%), distinct textures %d"
          " (%d files, blend %s), %d KB"
          % (len(mesh_tris), len(verts), len(nodes), paired // 2, paired, 100.0 * paired / max(1, len(mesh_tris)),
             len(textures), len(set(textures)), "/".join(sorted(set(blends))), os.path.getsize(out) // 1024))


for which in (sys.argv[1:] or sorted(ROOMS)):
    generate(which)
