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
        blank=True, floor_top=6.0, floor_bottom=-27.0, mesh_top=6.0, radius=100.0, band=7.0, max_edge=24.0,
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


def build_mesh(root, group, room):
    """-> (textures, verts [(x, y, z, u, v, light)], tris [(a, b, c, texture index)]) in arena coordinates."""
    textures, tex_index = [], {}
    verts, vert_index, tris = [], {}, []
    to_arena, z_main = room["to_arena"], room["z_main"]
    radius = room.get("radius")
    cx, cy = room["w"] / 2.0, room["h"] / 2.0

    def vert(p):
        key = tuple(round(v, 2) for v in p)
        if key not in vert_index:
            vert_index[key] = len(verts)
            verts.append(key)
        return vert_index[key]

    def emit(pa, pb, pc, tex):
        # a vertex = (x, y, z, u, v, light); split the longest edge until every edge is short enough
        edges = [(math.dist(pa[:3], pb[:3]), 0), (math.dist(pb[:3], pc[:3]), 1), (math.dist(pc[:3], pa[:3]), 2)]
        longest, which = max(edges)
        zs = (pa[2], pb[2], pc[2])
        n = normal(pa[:3], pb[:3], pc[:3])
        steep = n is not None and abs(n[2]) < 0.5
        if steep and longest <= room.get("max_edge", MAX_EDGE) and max(zs) - min(zs) > room.get("band", BAND) and longest > 1.5:
            # a tall piece (a wall, a pillar): cut it into height bands, so the renderer can layer the room by
            # height. Split the edge that climbs the most.
            pts = [pa, pb, pc]
            climbs = [(abs(pts[i][2] - pts[(i + 1) % 3][2]), i) for i in range(3)]
            which = max(climbs)[1]
            longest = MAX_EDGE * 1000
        if longest > room.get("max_edge", MAX_EDGE):
            pts = [pa, pb, pc]
            p, q, r = pts[which], pts[(which + 1) % 3], pts[(which + 2) % 3]
            m = tuple((p[i] + q[i]) / 2 for i in range(6))
            emit(p, m, r, tex)
            emit(m, q, r, tex)
            return
        if radius and min(math.hypot(p[0] - cx, p[1] - cy) for p in (pa, pb, pc)) > radius:
            return                                       # outside the part of the room the fight uses
        tris.append((vert(pa), vert(pb), vert(pc), tex))

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
        if file_id not in tex_index:
            tex_index[file_id] = len(textures) + 1       # Lua index
            textures.append(file_id)
        # both rooms are turned, not mirrored, so the winding (and with it the front face) stays
        emit(pts[0], pts[1], pts[2], tex_index[file_id])
    # textures of triangles that were all cut away are harmless
    return textures, verts, tris


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
    textures, verts, mesh_tris = build_mesh(root, group, room)
    out = os.path.join(OUT_DIR, room["out"])
    rel = "Games/Trainer/Encounters/" + room["out"]
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end -- DisasterZone %s' % (rel, rel),
        "-- %s, in the trainer's" % room["title"],
        "-- coordinates (yards, x east, y north, height 0 = the main floor).",
        "-- rows: the floor's height, one character per square yard, south to north, west to east:",
        "--       height = (its place in alphabet, from 0) * step + base; a space = no floor there.",
        "-- mesh: the room's own triangles. textures = texture file IDs; verts = x, y, z, u, v, light for each vertex;",
        "--       tris = vertex a, b, c (1-based) and texture (index into textures) for each triangle.",
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
    lines += ["  },", "} }", ""]
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    print("wrote %s: %d x %d, heights %.2f .. %.2f, %d cells without floor; mesh %d vertices, %d triangles, %d textures, %d KB"
          % (os.path.normpath(out), room["w"], room["h"], lo, hi, holes, len(verts), len(mesh_tris), len(textures),
             os.path.getsize(out) // 1024))


for which in (sys.argv[1:] or sorted(ROOMS)):
    generate(which)
