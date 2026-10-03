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
BAND = 2.5              # no triangle is taller than this (see the renderer's height layers)
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
    """-> (textures, verts [(x, y, z, u, v, light)], tris [(a, b, c, texture index)], nodes [(plane, front, back,
    first triangle, count)]) in arena coordinates. The triangles are listed node by node."""
    import random
    textures, tex_index = [], {}
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
        if file_id not in tex_index:
            tex_index[file_id] = len(textures) + 1       # Lua index
            textures.append(file_id)
        # both rooms are turned, not mirrored, so the winding (and with it the front face) stays
        raw_tris.append((tex_index[file_id], (pts[0], pts[1], pts[2])))

    nodes = build_bsp(raw_tris, random.Random(7))

    verts, vert_index, tris, out_nodes = [], {}, [], []

    def vert(p):
        key = tuple(round(v, 2) for v in p)
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
    return textures, verts, tris, out_nodes


def num4(v):
    s = ("%.4f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def num(v):
    s = ("%.2f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


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
    textures, verts, mesh_tris, nodes = build_mesh(root, group, room)
    out = os.path.join(OUT_DIR, room["out"])
    rel = "Games/Trainer/Encounters/" + room["out"]
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end -- DisasterZone %s' % (rel, rel),
        "-- %s, in the trainer's" % room["title"],
        "-- coordinates (yards, x east, y north, height 0 = the main floor).",
        "-- rows: the floor's height, one character per square yard, south to north, west to east:",
        "--       height = (its place in alphabet, from 0) * step + base; a space = no floor there.",
        "-- mesh: the room's own triangles. textures = texture file IDs; verts = x, y, z, u, v, light for each vertex;",
        "--       tris = vertex a, b, c (1-based) and texture (index into textures) for each triangle;",
        "--       nodes = a BSP tree of the triangles: plane a, b, c, d, front child, back child (0 = none), first",
        "--       triangle and count for each node. Far side, the node, near side: back to front from anywhere.",
        "-- AUTO-GENERATED by gen_trainer_heights.py; do not edit by hand.",
        "local _, ns = ...",
        "ns.TrainerFloors = ns.TrainerFloors or {}",
        'ns.TrainerFloors.%s = { w = %d, h = %d, base = %s, step = %s, alphabet = "%s", rows = {'
        % (room["key"], room["w"], room["h"], base, step, alphabet),
    ]
    lines += ['  "%s",' % r for r in rows]
    lines += ["}, mesh = {", "  textures = { %s }," % ", ".join(str(t) for t in textures), "  verts = {"]
    for i in range(0, len(verts), 6):
        lines.append("    " + " ".join(",".join(num(c) for c in v) + "," for v in verts[i:i + 6]))
    lines += ["  },", "  tris = {"]
    for i in range(0, len(mesh_tris), 12):
        lines.append("    " + " ".join("%d,%d,%d,%d," % (a + 1, b + 1, c + 1, t) for a, b, c, t in mesh_tris[i:i + 12]))
    lines += ["  },", "  nodes = {"]
    for i in range(0, len(nodes), 4):
        lines.append("    " + " ".join("%s,%s,%s,%s,%d,%d,%d,%d," % (num4(pl[0]), num4(pl[1]), num4(pl[2]), num(pl[3]), f, b, st, n)
                                       for pl, f, b, st, n in nodes[i:i + 4]))
    lines += ["  },", "} }", ""]
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    print("wrote %s: %d x %d, heights %.2f .. %.2f, %d cells without floor; mesh %d vertices, %d triangles, %d nodes, %d textures, %d KB"
          % (os.path.normpath(out), room["w"], room["h"], lo, hi, holes, len(verts), len(mesh_tris), len(nodes), len(textures),
             os.path.getsize(out) // 1024))


for which in (sys.argv[1:] or sorted(ROOMS)):
    generate(which)
