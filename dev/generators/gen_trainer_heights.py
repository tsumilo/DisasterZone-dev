"""Raid Trainer: an encounter room's real floor heights and its real mesh, from Blizzard's building geometry
(WMO root + group files).

Teron Gorefiend's hall is group 31 of world/wmo/dungeon/blacktemple/blacktemple.wmo (root file 108713, group file
108745, WMOGroupID 22426, "Gorefiend's Vigil"); files are fetched from wago.tools into dev/art/wmo/ (git-ignored,
Blizzard's data). The hall's floor spans local x -675..-615 and y -817..-759; the entrance corridor leaves on the
+y side, which is south on Blizzard's map, so the room is turned half round:
arena x = -615 - local x, arena y = -759 - local y, height = local z - 371.75 (the hall's main floor).

Writes Games/Trainer/Encounters/TeronGorefiendFloor.lua:
  rows: one letter per square yard, 'A' + (height - base) / step;
  mesh: the room's own triangles (floor, steps, walls up to MESH_TOP yd; ceilings and what faces down left out),
        with their texture files, texture coordinates and baked light. Triangles longer than MAX_EDGE are split.

Run: luaenv\\Scripts\\python.exe generators\\gen_trainer_heights.py
"""
import math
import os
import urllib.request

import wmo_tools as W

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "art", "wmo")
OUT = os.path.join(HERE, "..", "..", "addon", "DisasterZone", "Games", "Trainer", "Encounters", "TeronGorefiendFloor.lua")

ROOT_FILE, GROUP_FILE = 108713, 108745
X_EAST, Y_SOUTH, Z_MAIN = -615.0, -759.0, 371.75
W_YD, H_YD = 60, 58
BASE, STEP, TOP = -3.0, 0.25, 2.0
MESH_TOP = 12.0        # triangles that start higher than this above the floor are left out
MAX_EDGE = 9.0


def fetch(fdid):
    path = os.path.join(ART, "%d.wmo" % fdid)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
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


def floor_tris(group):
    out = []
    for t in group["tris"]:
        a, b, c = [group["verts"][i] for i in t]
        n = normal(a, b, c)
        # faces you can stand on, below head height over the main floor (not the ceiling)
        if n and abs(n[2]) > 0.5 and max(a[2], b[2], c[2]) < Z_MAIN + 4.5:
            out.append((a, b, c))
    return out


def height_at(tris, x, y):
    best = None
    for a, b, c in tris:
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


def build_mesh(root, group):
    """-> (textures, verts [(x, y, z, u, v, light)], tris [(a, b, c, texture index)]) in arena coordinates."""
    textures, tex_index = [], {}
    verts, vert_index, tris = [], {}, []

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
        if longest > MAX_EDGE:
            pts = [pa, pb, pc]
            p, q, r = pts[which], pts[(which + 1) % 3], pts[(which + 2) % 3]
            m = tuple((p[i] + q[i]) / 2 for i in range(6))
            emit(p, m, r, tex)
            emit(m, q, r, tex)
            return
        tris.append((vert(pa), vert(pb), vert(pc), tex))

    colors = group.get("colors")
    for t, mat in zip(group["tris"], group["mats"]):
        if mat == 255:                                   # collision only
            continue
        raw = [group["verts"][i] for i in t]
        n = normal(*raw)
        if not n or n[2] < -0.3:                         # faces down: a ceiling, the underside of a ledge
            continue
        if min(p[2] for p in raw) > Z_MAIN + MESH_TOP:
            continue
        file_id = root["materials"][mat]["texture"]
        if not file_id:
            continue
        if file_id not in tex_index:
            tex_index[file_id] = len(textures) + 1       # Lua index
            textures.append(file_id)
        pts = []
        for i in t:
            x, y, z = group["verts"][i]
            u, v = group["uvs"][i]
            light = 1.0
            if colors:
                b, g, r, _ = colors[i]
                light = (0.3 * r + 0.59 * g + 0.11 * b) / 127.0      # 127 = the texture as it is
            pts.append((X_EAST - x, Y_SOUTH - y, z - Z_MAIN, u, v, max(0.25, min(1.0, light))))
        # the half turn keeps the winding, so front faces stay front faces
        emit(pts[0], pts[1], pts[2], tex_index[file_id])
    return textures, verts, tris


def num(v, digits=2):
    s = ("%." + str(digits) + "f") % v
    s = s.rstrip("0").rstrip(".") if "." in s else s
    return "0" if s in ("-0", "") else s


def main():
    root = W.read_root(fetch(ROOT_FILE))
    group = W.read_group(fetch(GROUP_FILE))
    tris = floor_tris(group)
    rows, lo, hi = [], 99, -99
    for j in range(H_YD):                      # south to north
        row = ""
        for i in range(W_YD):                  # west to east
            z = height_at(tris, X_EAST - (i + 0.5), Y_SOUTH - (j + 0.5))
            h = 0.0 if z is None else max(BASE, min(TOP, z - Z_MAIN))
            lo, hi = min(lo, h), max(hi, h)
            row += chr(ord("A") + int(round((h - BASE) / STEP)))
        rows.append(row)
    textures, verts, mesh_tris = build_mesh(root, group)
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Trainer/Encounters/TeronGorefiendFloor.lua", ...) then return end -- DisasterZone Games/Trainer/Encounters/TeronGorefiendFloor.lua',
        "-- Teron Gorefiend's hall as Blizzard built it (blacktemple.wmo, group \"Gorefiend's Vigil\"), in the trainer's",
        "-- coordinates (yards, x east, y north, height 0 = the hall's main floor).",
        "-- rows: the floor's height, one letter per square yard, south to north, west to east:",
        "--       height = (letter - 'A') * step + base.",
        "-- mesh: the room's own triangles. textures = texture file IDs; verts = x, y, z, u, v, light for each vertex;",
        "--       tris = vertex a, b, c (1-based) and texture (index into textures) for each triangle.",
        "-- AUTO-GENERATED by gen_trainer_heights.py; do not edit by hand.",
        "local _, ns = ...",
        "ns.TrainerFloors = ns.TrainerFloors or {}",
        "ns.TrainerFloors.teron = { w = %d, h = %d, base = %s, step = %s, rows = {" % (W_YD, H_YD, BASE, STEP),
    ]
    lines += ['  "%s",' % r for r in rows]
    lines += ["}, mesh = {", "  textures = { %s }," % ", ".join(str(t) for t in textures), "  verts = {"]
    for i in range(0, len(verts), 6):
        lines.append("    " + " ".join(",".join(num(c, 2 if k != 5 else 2) for k, c in enumerate(v)) + "," for v in verts[i:i + 6]))
    lines += ["  },", "  tris = {"]
    for i in range(0, len(mesh_tris), 12):
        lines.append("    " + " ".join("%d,%d,%d,%d," % (a + 1, b + 1, c + 1, t) for a, b, c, t in mesh_tris[i:i + 12]))
    lines += ["  },", "} }", ""]
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    print("wrote %s: %d x %d, heights %.2f .. %.2f; mesh %d vertices, %d triangles, %d textures, %d KB"
          % (os.path.normpath(OUT), W_YD, H_YD, lo, hi, len(verts), len(mesh_tris), len(textures), os.path.getsize(OUT) // 1024))


main()
