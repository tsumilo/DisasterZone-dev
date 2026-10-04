"""The strategy board's 3D rooms: one per raid encounter that has a starter strategy, from Blizzard's own geometry.

For every encounter (Data/StarterStrategies.lua) the room is what the starter's page shows on its floor map: the board's
1000 x 666 units at the page's pan and zoom, as a box in world coordinates (the floor map's world rectangle: retail
UiMapAssignment). The boss stands where the server spawns it (AzerothCore creature.sql, the creature nearest the
starter's portrait) or, for a creature the server summons, at the portrait on the floor of that map floor.

Geometry in the box:
  * every WMO placed in it (a global WMO of the map's WDT, or the MODF placements of the ADT tiles under the box),
    every group whose box meets it, each face cut exactly at the box's sides and at a height band round the boss'
    floor (ROOM_DOWN below, ROOM_UP above: walls end there, a cut-away model; ceilings and faces turned down go);
  * on maps with terrain the ADT height maps (MCVT; holes left out), textured with the game's own minimap tiles.
A room over MAX_TRIS faces shrinks round the boss until it fits (the renderer's frame budget).

World <-> WMO local through the placement: wx = C - (pos.z + z'), wy = C - (pos.x + x'), wz = pos.y + local z, with
(x', z') the local (x, -y) turned by rot.y - 90 degrees; C = 17066.67 for ADT placements and 0 for a WDT's global WMO
(checked: Teron's spawn lands 0.08 yd from group 17's floor, Lady Vashj's on her platform).

Room coordinates: yards, x east (0 at the box's west side), y north (0 at its south side), height 0 = the boss' floor.
The fit to the shipped floor map is exact (both are axis-aligned): room x = ax * map px + bx, y = ay * map py + by.

Writes Render3D/Rooms/<Raid>_<Boss>.lua (data format 3: the version 2 tables of gen_trainer_heights.py as text,
deflated and printable-encoded for LibDeflate; Render3D/Rooms.lua unpacks a room when its 3D view opens) and
Render3D/Rooms/Index.lua (per boss: its room, the map, the fit, the first view, the boss' spot).
Blizzard's files are cached in dev/art/rooms (git-ignored).

Run: luaenv\\Scripts\\python.exe generators\\gen_rooms.py [Raid:Boss ...] [--jobs N] [--index-only]
"""
import collections
import csv
import json
import math
import os
import random
import re
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import wmo_tools as W  # noqa: E402
import gen_trainer_heights as G  # noqa: E402
from patchlib import deflate_raw, encode_for_print  # noqa: E402

ADDON = os.path.join(HERE, "..", "..", "addon", "DisasterZone")
OUT_DIR = os.path.join(ADDON, "Render3D", "Rooms")
CACHE = os.path.join(HERE, "..", "art", "rooms")
WMO_CACHE = os.path.join(HERE, "..", "art", "wmo")

MAX_TRIS = 7000                 # faces per room at most (the board's 3D view: 327 cluster frames of 32 nodes)
MAX_NODES = 2900                # BSP nodes at most (the 3D view's frames hold about 10 each)
MAX_EDGE = 40.0                 # yd: longer faces are halved (the renderer subdivides on screen; this only keeps
                                # texture coordinates from growing huge)
MIN_HALF = 30.0                 # yd: a shrinking room keeps at least this round the boss
ROOM_UP, ROOM_DOWN = 14.0, 30.0 # yd over / under the boss' floor the room keeps
TILE = 533.3333333              # an ADT tile
ADT_C = 17066.6666667           # 32 tiles

RAIDS = {
    "Karazhan": (532, "Karazahn"), "GruulsLair": (565, "GruulsLair"), "MagtheridonsLair": (544, "HellfireRaid"),
    "SerpentshrineCavern": (548, "CoilfangRaid"), "TempestKeep": (550, "TempestKeepRaid"), "HyjalSummit": (534, "HyjalPast"),
    "BlackTemple": (564, "BlackTemple"), "ZulAman": (568, "ZulAman"), "SunwellPlateau": (580, "SunwellPlateau"),
}
# shipped floor map (Data/RaidMaps.lua file) -> uiMapID
UIMAP = {"Gruul": 330, "Magtheridon": 331, "Serpentshrine": 332, "TheEye": 334, "Hyjal": 329, "ZulAman": 333,
         "Sunwell": 336, "Sunwell0": 335}
UIMAP.update({"Kara%02d" % i: 349 + i for i in range(1, 18)})
UIMAP.update({"BT%02d" % i: 339 + i for i in range(0, 8)})
MAP_W, MAP_H = 1024, 683        # a shipped map's size
BW, BH = 1000, 666              # the board


# ---------------------------------------------------------------------------------------------------------------
# downloads (cached)
# ---------------------------------------------------------------------------------------------------------------
def _get(url, path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        for attempt in range(4):
            subprocess.run(["curl", "-s", "-L", "-A", "Mozilla/5.0", "-o", path + ".part", url], check=False)
            if os.path.exists(path + ".part") and os.path.getsize(path + ".part") > 0:
                os.replace(path + ".part", path)
                break
            time.sleep(1 + attempt)
    if not os.path.exists(path):
        raise SystemExit("could not download %s" % url)
    return path


def casc(fdid, folder=CACHE):
    for d in (WMO_CACHE, folder):
        for ext in (".wmo", ".bin", ".adt", ".wdt"):
            p = os.path.join(d, "%d%s" % (fdid, ext))
            if os.path.exists(p) and os.path.getsize(p) > 0:
                return p
    return _get("https://wago.tools/api/casc/%d?download" % fdid, os.path.join(folder, "%d.bin" % fdid))


_FDIDS = None


def fdid_of(filename):
    """A file's ID by its path (wago.tools' file search), cached in dev/art/rooms/fdids.json; None when unknown."""
    global _FDIDS
    path = os.path.join(CACHE, "fdids.json")
    if _FDIDS is None:
        _FDIDS = json.load(open(path)) if os.path.exists(path) else {}
    name = filename.lower()
    if name in _FDIDS:
        return _FDIDS[name]
    page = _get("https://wago.tools/files?search=" + name,
                os.path.join(CACHE, "search", re.sub(r"[^a-z0-9_.]", "_", name) + ".html"))
    s = open(page, encoding="utf-8", errors="replace").read().replace("&quot;", '"').replace("\\/", "/")
    found = None
    for fid, fn in re.findall(r'"fdid":(\d+),"filename":"([^"]+)"', s):
        if fn.lower() == name:
            found = int(fid)
    _FDIDS[name] = found
    tmp = path + ".tmp"
    json.dump(_FDIDS, open(tmp, "w"), indent=0, sort_keys=True)
    os.replace(tmp, path)
    return found


def uimap_rect(ui):
    rows = list(csv.DictReader(open(_get("https://wago.tools/db2/UiMapAssignment/csv?filter%%5BUiMapID%%5D=exact:%d" % ui,
                                         os.path.join(CACHE, "uma_%d.csv" % ui)), encoding="utf-8")))
    r = rows[0]
    x0, y0, z0 = float(r["Region_0"]), float(r["Region_1"]), float(r["Region_2"])
    x1, y1, z1 = float(r["Region_3"]), float(r["Region_4"]), float(r["Region_5"])
    return x0, y0, z0, x1, y1, z1


_SPAWNS = None


def spawns():
    """npc id -> [(map, x, y, z)] from AzerothCore's creature table."""
    global _SPAWNS
    if _SPAWNS is None:
        path = _get("https://raw.githubusercontent.com/azerothcore/azerothcore-wotlk/master/data/sql/base/db_world/"
                    "creature.sql", os.path.join(CACHE, "creature.sql"))
        _SPAWNS = collections.defaultdict(list)
        for m in re.finditer(r"\((\d+),(\d+),\d+,\d+,(\d+),\d+,\d+,\d+,\d+,-?\d+,(-?[\d.]+),(-?[\d.]+),(-?[\d.]+),",
                             open(path, encoding="utf-8", errors="replace").read()):
            _SPAWNS[int(m.group(2))].append((int(m.group(3)), float(m.group(4)), float(m.group(5)), float(m.group(6))))
    return _SPAWNS


# ---------------------------------------------------------------------------------------------------------------
# the addon's data (loaded in real Lua 5.1)
# ---------------------------------------------------------------------------------------------------------------
def addon_data():
    from lupa import lua51 as lupa
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    ns = lua.eval("{ Data = {} }")
    run = lua.eval("function(src, ns) local f = assert(loadstring(src)) f('DisasterZone', ns) end")
    for name in ("StarterStrategies", "BossPortraits", "RaidMaps"):
        src = open(os.path.join(ADDON, "Data", name + ".lua"), encoding="utf-8").read()
        src = re.sub(r"^if DisasterZoneBoot.*?\n", "", src)
        run(src, ns)
    conv = lua.eval("""function(t)
        local function c(v) if type(v) ~= 'table' then return v end local o = {} for k, x in pairs(v) do o[k] = c(x) end return o end
        return c(t) end""")

    def py(v):
        if lupa.lua_type(v) == "table":
            keys = list(v.keys())
            if keys and all(isinstance(k, int) for k in keys):
                return [py(v[k]) for k in sorted(keys)]
            return {k: py(v[k]) for k in keys}
        return v
    return py(conv(ns.Data.StarterStrategies)), py(conv(ns.Data.BossPortraits)), py(conv(ns.Data.RaidMaps))


# ---------------------------------------------------------------------------------------------------------------
# placements, WMO groups, terrain
# ---------------------------------------------------------------------------------------------------------------
def chunks(b, start=0, end=None):
    pos, end = start, len(b) if end is None else end
    while pos + 8 <= end:
        tag = b[pos:pos + 4][::-1].decode("latin1")
        size = struct.unpack_from("<I", b, pos + 4)[0]
        yield tag, pos + 8, size
        pos += 8 + size


def read_modf(b, data_off, size):
    out = []
    for k in range(0, size, 64):
        nid, uid, px, py, pz, rx, ry, rz = struct.unpack_from("<II6f", b, data_off + k)
        flags, dset, nset, scale = struct.unpack_from("<4H", b, data_off + k + 56)
        out.append(dict(file=nid, uid=uid, pos=(px, py, pz), rot=(rx, ry, rz), flags=flags, scale=(scale or 1024) / 1024.0))
    return out


class Placement:
    """A WMO placed in the world: local <-> world."""

    def __init__(self, p, global_wmo):
        self.file, self.uid = p["file"], p["uid"]
        self.px, self.py, self.pz = p["pos"]
        self.s = p["scale"]
        rx, ry, rz = p["rot"]
        if abs(rx) > 0.01 or abs(rz) > 0.01:
            TILTED[self.uid] = (rx, rz)
        phi = math.radians(ry - 90.0)
        self.c, self.s_ = math.cos(phi), math.sin(phi)
        self.C = 0.0 if global_wmo else ADT_C

    def to_world(self, lx, ly, lz):
        gx, gy, gz = lx * self.s, lz * self.s, -ly * self.s
        x2 = gx * self.c + gz * self.s_
        z2 = -gx * self.s_ + gz * self.c
        return self.C - (self.pz + z2), self.C - (self.px + x2), self.py + gy


_ROOTS, _GROUPS = {}, {}


def root(fid):
    if fid not in _ROOTS:
        _ROOTS[fid] = W.read_root(casc(fid))
    return _ROOTS[fid]


def group(fid):
    if fid not in _GROUPS:
        _GROUPS[fid] = W.read_group(casc(fid))
    return _GROUPS[fid]


def placements(mapdir, box):
    """The WMOs placed over a world box (x0, y0, x1, y1): a WDT's global WMO, else the ADT tiles' MODF entries."""
    wdt = fdid_of("world/maps/%s/%s.wdt" % (mapdir.lower(), mapdir.lower()))
    b = open(casc(wdt), "rb").read()
    for tag, off, size in chunks(b):
        if tag == "MODF" and size:
            return [Placement(p, True) for p in read_modf(b, off, size)], False
    out, seen = [], set()
    for tx, ty in tiles(box):
        fid = fdid_of("world/maps/%s/%s_%d_%d_obj0.adt" % (mapdir.lower(), mapdir.lower(), tx, ty))
        if not fid:
            continue
        b = open(casc(fid), "rb").read()
        for tag, off, size in chunks(b):
            if tag == "MODF":
                for p in read_modf(b, off, size):
                    if p["uid"] not in seen and p["flags"] & 0x8:          # (0x8: the name is a file ID)
                        seen.add(p["uid"])
                        out.append(Placement(p, False))
    return out, True


def tiles(box):
    x0, y0, x1, y1 = box
    txs = range(int(math.floor(32 - y1 / TILE)), int(math.floor(32 - y0 / TILE)) + 1)
    tys = range(int(math.floor(32 - x1 / TILE)), int(math.floor(32 - x0 / TILE)) + 1)
    return [(tx, ty) for tx in txs for ty in tys]


def wmo_faces(pl, box, zlo, zhi):
    """World faces of a placed WMO inside a box: [(texture key, [(x, y, z, u, v, light)] * 3, flags)]."""
    x0, y0, x1, y1 = box
    r = root(pl.file)
    out = []
    for gi, g in enumerate(r["groups"]):
        bx0, by0, bz0, bx1, by1, bz1 = g["bbox"]
        corners = [pl.to_world(x, y, z) for x in (bx0, bx1) for y in (by0, by1) for z in (bz0, bz1)]
        if (max(c[0] for c in corners) < x0 or min(c[0] for c in corners) > x1 or max(c[1] for c in corners) < y0
                or min(c[1] for c in corners) > y1 or max(c[2] for c in corners) < zlo
                or min(c[2] for c in corners) > zhi):
            continue
        if gi >= len(r["gfid"]) or not r["gfid"][gi]:
            continue
        gr = group(r["gfid"][gi])
        cols = gr.get("colors")
        mats = r["materials"]
        for t, mat, fl in zip(gr["tris"], gr["mats"], gr["flags"]):
            if mat == 255 or mat >= len(mats) or not mats[mat]["texture"]:
                continue
            pts = []
            for i in t:
                wx, wy, wz = pl.to_world(*gr["verts"][i])
                u, v = gr["uvs"][i] if "uvs" in gr else (0.0, 0.0)
                light = 1.0
                if cols:
                    bb, gg, rr, _ = cols[i]
                    light = max(0.25, min(1.0, (0.3 * rr + 0.59 * gg + 0.11 * bb) / 127.0))
                pts.append((wx, wy, wz, u, v, light))
            out.append(((mats[mat]["texture"], mats[mat]["blend"]), pts, fl))
    return out


def terrain_faces(mapdir, box, step):
    """World faces of the ADT terrain inside a box (2 per cell of `step` vertices), textured with the minimap tiles."""
    x0, y0, x1, y1 = box
    out = []
    for tx, ty in tiles(box):
        fid = fdid_of("world/maps/%s/%s_%d_%d.adt" % (mapdir.lower(), mapdir.lower(), tx, ty))
        mini = fdid_of("world/minimaps/%s/map%02d_%02d.blp" % (mapdir.lower(), tx, ty))
        if not fid or not mini:
            continue
        b = open(casc(fid), "rb").read()
        top_y, top_x = (32 - tx) * TILE, (32 - ty) * TILE           # the tile's north-west corner (world)
        for tag, off, size in chunks(b):
            if tag != "MCNK":
                continue
            flags, ix, iy = struct.unpack_from("<3I", b, off)
            holes_lo = struct.unpack_from("<H", b, off + 0x3C)[0]
            holes_hi = b[off + 0x14:off + 0x1C] if flags & 0x10000 else None
            base_z = struct.unpack_from("<f", b, off + 0x68 + 8)[0]
            heights = None
            for sub, soff, ssize in chunks(b, off + 128, off + size):
                if sub == "MCVT":
                    heights = struct.unpack_from("<145f", b, soff)
            if heights is None:
                continue
            cx, cy = top_x - iy * (TILE / 16), top_y - ix * (TILE / 16)    # the chunk's north-west corner
            if cx < x0 - 40 or cx - TILE / 16 > x1 + 40 or cy < y0 - 40 or cy - TILE / 16 > y1 + 40:
                continue
            cell = TILE / 128

            def vert(r, c):
                wx, wy = cx - r * cell, cy - c * cell
                u, v = (top_y - wy) / TILE, (top_x - wx) / TILE
                return (wx, wy, base_z + heights[r * 17 + c], u, v, 1.0)
            for r in range(0, 8, step):
                for c in range(0, 8, step):
                    if holes_hi is not None:
                        if holes_hi[r] & (1 << c):
                            continue
                    elif holes_lo & (1 << ((r // 2) * 4 + (c // 2))):
                        continue
                    r2, c2 = min(8, r + step), min(8, c + step)
                    a, bq, cq, d = vert(r, c), vert(r, c2), vert(r2, c2), vert(r2, c)
                    # (north-west, north-east, south-east, south-west: counter-clockwise seen from above)
                    out.append(((mini, 0), [a, d, cq], 0))
                    out.append(((mini, 0), [a, cq, bq], 0))
    return out


def clip_faces(faces, box, zlo, zhi):
    """The parts of faces inside a box and a height band (exact cuts), turned-down faces dropped."""
    x0, y0, x1, y1 = box
    lo, hi = (x0, y0, zlo), (x1, y1, zhi)
    out = []
    for key, pts, fl in faces:
        n = G.normal(pts[0][:3], pts[1][:3], pts[2][:3])
        if not n or n[2] < -0.3:
            continue
        poly = pts
        for axis in range(3):
            if min(p[axis] for p in poly) >= lo[axis] and max(p[axis] for p in poly) <= hi[axis]:
                continue
            poly = G.clip_poly(poly, axis, lo[axis], False)
            if len(poly) >= 3:
                poly = G.clip_poly(poly, axis, hi[axis], True)
            if len(poly) < 3:
                break
        if len(poly) < 3:
            continue
        for k in range(1, len(poly) - 1):
            out.append((key, (poly[0], poly[k], poly[k + 1]), fl))
    return out


# ---------------------------------------------------------------------------------------------------------------
# one encounter
# ---------------------------------------------------------------------------------------------------------------
def board_to_world(page, rect, bx, by):
    """A board point of a page on its floor map -> world x, y."""
    xMin, yMin, _, xMax, yMax, _ = rect
    vx, vy, vz = page.get("vx", 500), page.get("vy", 500), page.get("vz", 100)
    k = min(BW / MAP_W, BH / MAP_H) * vz / 100.0
    px = vx / 1000.0 * MAP_W + (bx - BW / 2) / k
    py = vy / 1000.0 * MAP_H + (by - BH / 2) / k
    return xMax - (xMax - xMin) * py / MAP_H, yMax - (yMax - yMin) * px / MAP_W


def floors_at(faces, x, y):
    """Heights of the faces turned up over a point."""
    out = []
    for _, pts, _ in faces:
        (ax, ay, az), (bx, by, bz), (cx, cy, cz) = (p[:3] for p in pts)
        if x < min(ax, bx, cx) or x > max(ax, bx, cx) or y < min(ay, by, cy) or y > max(ay, by, cy):
            continue
        n = G.normal((ax, ay, az), (bx, by, bz), (cx, cy, cz))
        if not n or abs(n[2]) < 0.6:
            continue
        d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(d) < 1e-9:
            continue
        w1 = ((by - cy) * (x - cx) + (cx - bx) * (y - cy)) / d
        w2 = ((cy - ay) * (x - cx) + (ax - cx) * (y - cy)) / d
        w3 = 1 - w1 - w2
        if min(w1, w2, w3) >= -1e-4:
            out.append(w1 * az + w2 * bz + w3 * cz)
    return out


def num5(v):
    s = ("%.5f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def num3(v):
    return G.num3(v)


TILTED = {}                     # placement uid -> its rotation about the level axes (left out)


def safe_key(ref):
    return re.sub(r"[^A-Za-z0-9]", "_", ref)


def plan(ref, starters, portraits, maps):
    """Where an encounter's room is: -> dict (or None without a starter page on a known map)."""
    raid = ref.split(":")[0]
    st = starters.get(ref)
    if not st or raid not in RAIDS:
        return None
    page = st["p"][0]
    mapfile = page.get("map")
    if mapfile not in UIMAP:
        return None
    rect = uimap_rect(UIMAP[mapfile])
    mapid, mapdir = RAIDS[raid]
    creatures = portraits.get(ref) or []
    boss = creatures[0] if creatures else None
    icon = None
    for e in page.get("e") or []:
        if e.get("t") == "i" and isinstance(e.get("i"), str) and e["i"].startswith("@"):
            icon = e
            break
    bx, by = (icon["x"], icon["y"]) if icon else (BW / 2, BH / 2)
    wx, wy = board_to_world(page, rect, bx, by)
    spot, how = None, "the starter's portrait"
    if boss:
        cands = [s for s in spawns().get(boss["id"], []) if s[0] == mapid]
        if cands:
            s = min(cands, key=lambda s: (s[1] - wx) ** 2 + (s[2] - wy) ** 2)
            if math.hypot(s[1] - wx, s[2] - wy) < 60:
                spot, how = (s[1], s[2], s[3]), "AzerothCore spawn of %d" % boss["id"]
    corners = [board_to_world(page, rect, x, y) for x, y in ((0, 0), (BW, 0), (0, BH), (BW, BH))]
    box = (min(c[0] for c in corners), min(c[1] for c in corners), max(c[0] for c in corners), max(c[1] for c in corners))
    name = (boss["n"] if boss else ref.split(":")[1])
    return dict(ref=ref, key=safe_key(ref), raid=raid, mapid=mapid, mapdir=mapdir, mapfile=mapfile, rect=rect,
                page=page, box=box, portrait=(wx, wy), spot=spot, how=how, name=name)


def gather(p):
    """The room's faces in world coordinates, the boss' spot and floor height, the box used."""
    box = p["box"]
    pls, has_terrain = placements(p["mapdir"], box)
    raw = []
    p["tilted"] = []
    for pl in pls:
        got = wmo_faces(pl, box, -1e9, 1e9)
        if pl.uid in TILTED and got:
            p["tilted"].append((pl.uid, TILTED[pl.uid], len(got)))
        raw += got
    span = max(box[2] - box[0], box[3] - box[1])
    if has_terrain:
        raw += terrain_faces(p["mapdir"], box, 1 if span < 160 else 2)
    # the boss' floor
    if p["spot"]:
        sx, sy, sz = p["spot"]
        fl = [z for z in floors_at(raw, sx, sy) if z <= sz + 1.5]
        zb = max(fl) if fl else sz
    else:
        sx, sy = p["portrait"]
        zmin = p["rect"][2]
        fl = floors_at(raw, sx, sy)
        if zmin > -9999 and fl:
            above = [z for z in fl if z >= zmin - 2]
            zb = min(above) if above else max(fl)
        else:
            zb = max(fl) if fl else 0.0
    return raw, (sx, sy, zb), box


def shrink(box, spot):
    """The box 12% smaller round the boss (not past the old one); None when it is as small as a room gets."""
    sx, sy, _ = spot
    hx, hy = (box[2] - box[0]) / 2 * 0.88, (box[3] - box[1]) / 2 * 0.88
    if hx < MIN_HALF and hy < MIN_HALF:
        return None
    hx, hy = max(MIN_HALF, hx), max(MIN_HALF, hy)
    cx = min(max(sx, box[0] + hx), box[2] - hx)
    cy = min(max(sy, box[1] + hy), box[3] - hy)
    return (cx - hx, cy - hy, cx + hx, cy + hy)


def build(p):
    """The room: its faces cut to the box (shrunk while it has more than MAX_TRIS faces or MAX_NODES BSP nodes)."""
    raw, spot, box = gather(p)
    zb = spot[2]
    while True:
        faces = clip_faces(raw, box, zb - ROOM_DOWN, zb + ROOM_UP)
        smaller = shrink(box, spot)
        if len(faces) > MAX_TRIS and smaller:
            box = smaller
            continue
        r = make(p, raw, spot, box, faces)
        if len(r["nodes"]) > MAX_NODES and smaller:
            box = smaller
            continue
        return r


def make(p, raw, spot, box, faces):
    sx, sy, zb = spot
    x0, y0, x1, y1 = box
    # room coordinates: x east from the box's west side (largest world y), y north from its south side (smallest x)
    W_ = int(math.ceil(y1 - y0))
    H_ = int(math.ceil(x1 - x0))

    def to_room(wx, wy, wz):
        return y1 - wy, wx - x0, wz - zb
    tex_index, textures, blends, tris = {}, [], [], []
    for (fid, blend), pts, fl in faces:
        key = (fid, blend)
        if key not in tex_index:
            tex_index[key] = len(textures) + 1
            textures.append(fid)
            blends.append(G.BLEND_NAMES.get(blend, "BLEND"))
        tris.append((tex_index[key], tuple(to_room(*q[:3]) + tuple(q[3:]) for q in pts)))
    # the height grid: the highest floor in the band at each cell
    cell = 1 if max(W_, H_) <= 180 else 2
    grid = collections.defaultdict(list)
    for _, pts in tris:
        n = G.normal(pts[0][:3], pts[1][:3], pts[2][:3])
        if n and n[2] > 0.6:
            xs, ys = [q[0] for q in pts], [q[1] for q in pts]
            for gx in range(int(min(xs) // 8), int(max(xs) // 8) + 1):
                for gy in range(int(min(ys) // 8), int(max(ys) // 8) + 1):
                    grid[(gx, gy)].append(pts)

    def height(x, y):
        best = None
        for pts in grid.get((int(x // 8), int(y // 8)), ()):
            (ax, ay, az), (bx, by, bz), (cx, cy, cz) = (q[:3] for q in pts)
            d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(d) < 1e-9:
                continue
            w1 = ((by - cy) * (x - cx) + (cx - bx) * (y - cy)) / d
            w2 = ((cy - ay) * (x - cx) + (ax - cx) * (y - cy)) / d
            w3 = 1 - w1 - w2
            if min(w1, w2, w3) >= -1e-4:
                z = w1 * az + w2 * bz + w3 * cz
                if z <= 6.0 and (best is None or z > best):
                    best = z
        return best
    cols, rws = (W_ + cell - 1) // cell, (H_ + cell - 1) // cell
    hs = [[height((i + 0.5) * cell, (j + 0.5) * cell) for i in range(cols)] for j in range(rws)]
    vals = [h for row in hs for h in row if h is not None] or [0.0]
    lo, hi = min(vals), max(vals)
    base = math.floor(lo * 4) / 4
    step = 0.25
    while base + step * (len(G.ALPHA62) - 1) < hi:
        step *= 2
    rows = ["".join(" " if h is None else G.ALPHA62[max(0, min(61, int(round((h - base) / step))))] for h in row)
            for row in hs]
    # the mesh: BSP order, long pieces cut, quad pairs (gen_trainer_heights' format version 2)
    nodes = G.build_bsp(tris, random.Random(7))
    verts, vert_index, mtris, out_nodes = [], {}, [], []

    def vert(q):
        # (1 mm as format 2; texture coordinates to a thousandth, light in steps of 0.05: smaller once deflated)
        key = (round(q[0], 3), round(q[1], 3), round(q[2], 3), round(q[3], 3), round(q[4], 3),
               round(q[5] * 20) / 20)
        if key not in vert_index:
            vert_index[key] = len(verts)
            verts.append(key)
        return vert_index[key]

    def emit(pa, pb, pc, tex):
        edges = [(math.dist(pa[:3], pb[:3]), 0), (math.dist(pb[:3], pc[:3]), 1), (math.dist(pc[:3], pa[:3]), 2)]
        longest, which = max(edges)
        if longest > MAX_EDGE:
            pts = [pa, pb, pc]
            a, b_, c_ = pts[which], pts[(which + 1) % 3], pts[(which + 2) % 3]
            m = tuple((a[i] + b_[i]) / 2 for i in range(6))
            emit(a, m, c_, tex)
            emit(m, b_, c_, tex)
            return
        a, b_, c_ = vert(pa), vert(pb), vert(pc)
        if a != b_ and b_ != c_ and a != c_:
            mtris.append((a, b_, c_, tex))
    for node in nodes[1:]:
        first = len(mtris)
        for tex, tri in node["tris"]:
            emit(tri[0], tri[1], tri[2], tex)
        out_nodes.append((node["plane"], node["front"], node["back"], first + 1, len(mtris) - first))
    pair, node_of = G.pair_tris(verts, mtris, out_nodes)
    # (the planes are written with one decimal more than format 2: rooms reach 400 yd from their corner)
    n4, n2 = G.num4, G.num
    G.num4, G.num = num5, num3
    try:
        G.self_check(p["ref"], textures, blends, verts, mtris, out_nodes, pair, node_of)
    finally:
        G.num4, G.num = n4, n2
    # the fit: shipped map pixel -> room
    xMin, yMin, _, xMax, yMax, _ = p["rect"]
    fit = dict(ax=(yMax - yMin) / MAP_W, bx=y1 - yMax, ay=-(xMax - xMin) / MAP_H, by=xMax - x0)
    rx, ry, _ = to_room(sx, sy, zb)
    return dict(p, w=W_, h=H_, cell=cell, base=base, step=step, rows=rows, textures=textures, blends=blends,
                verts=verts, tris=mtris, nodes=out_nodes, pair=pair, fit=fit, roombox=box, zb=zb,
                bossSpot=(rx, ry), faces=len(faces), raw=len(raw))


def payload(r):
    """The room's tables as text, sections split by '|'."""
    N3, N4, N = G.num3, G.num4, G.num
    parts = ["\n".join(r["rows"]),
             " ".join(str(t) for t in r["textures"]),
             " ".join({"DISABLE": "D", "ALPHAKEY": "A"}.get(b, "B") for b in r["blends"]),
             " ".join("%s %s %s %s %s %s" % (N3(v[0]), N3(v[1]), N3(v[2]), N3(v[3]), N3(v[4]), N(v[5])) for v in r["verts"]),
             " ".join("%d %d %d %d" % (a + 1, b + 1, c + 1, t) for a, b, c, t in r["tris"]),
             " ".join("%s %s %s %s %d %d %d %d" % (num5(pl[0]), num5(pl[1]), num5(pl[2]), num3(pl[3]), f, b, s, n)
                      for pl, f, b, s, n in r["nodes"]),
             " ".join(str(m) for m in r["pair"])]
    return "|".join(parts).encode("ascii")


def write_room(r):
    raw = payload(r)
    enc = encode_for_print(deflate_raw(raw))
    rel = "Render3D/Rooms/%s.lua" % r["key"]
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end -- DisasterZone %s' % (rel, rel),
        "-- %s (%s): the room the strategy board's 3D view draws, as Blizzard built it. Data format 3: the" % (r["name"], r["ref"]),
        "-- tables of gen_trainer_heights.py's format 2 (rows, textures, blend, verts, tris, nodes, pair) as text, deflated",
        "-- and encoded for print (LibDeflate); Render3D/Rooms.lua unpacks it when the room is first drawn. Room",
        "-- coordinates: yards, x east, y north, height 0 = the boss' floor.",
        "-- AUTO-GENERATED by gen_rooms.py; do not edit by hand.",
        "local _, ns = ...",
        "ns.RoomFloors = ns.RoomFloors or {}",
        'ns.RoomFloors["%s"] = { version = 3, w = %d, h = %d, cell = %d, base = %s, step = %s, alphabet = "%s", size = %d,'
        % (r["key"], r["w"], r["h"], r["cell"], G.num(r["base"]), G.num(r["step"]), G.ALPHA62, len(raw)),
        "  data = {",                   # (pieces joined when unpacked: a long chain of .. would nest too deep)
    ]
    for i in range(0, len(enc), 200):
        lines.append('    "%s",' % enc[i:i + 200])
    lines.append("} }")
    path = os.path.join(OUT_DIR, r["key"] + ".lua")
    tmp = G.write_temp(path, "\n".join(lines) + "\n")
    G.move_into_place(tmp, path)
    return path, len(raw), len(enc)


def index_entry(r):
    v_dist = max(r["w"], r["h"]) * 0.85
    return dict(ref=r["ref"], floor=r["key"], name=r["name"], map=r["mapfile"], fit=r["fit"],
                view=(r["w"] / 2.0, r["h"] / 2.0, v_dist), spot=r["bossSpot"], w=r["w"], h=r["h"])


def display_scales(portraits):
    """display id -> CreatureModelScale (build 2.5.6.69795) of every creature on a portrait (when not 1)."""
    path = _get("https://wago.tools/db2/CreatureDisplayInfo/csv?build=2.5.6.69795", os.path.join(CACHE, "CreatureDisplayInfo.csv"))
    scale = {int(r["ID"]): float(r["CreatureModelScale"]) for r in csv.DictReader(open(path, encoding="utf-8"))}
    out = {}
    for creatures in portraits.values():
        for c in creatures:
            s = scale.get(int(c["d"]))
            if s and abs(s - 1) > 1e-6:
                out[int(c["d"])] = s
    return out


def write_index(entries, scales=None):
    rel = "Render3D/Rooms/Index.lua"
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end -- DisasterZone %s' % (rel, rel),
        "-- The strategy board's 3D rooms (Render3D/Rooms/<Raid>_<Boss>.lua): per encounter its room's floor key, name,",
        "-- the shipped floor map its pages must use, the fit (map pixel -> room yards: x = ax * px + bx, y = ay * py + by),",
        "-- the first view (room x, y, distance) and where the boss stands (room x, y).",
        "-- AUTO-GENERATED by gen_rooms.py; do not edit by hand.",
        "local _, ns = ...",
        "ns.Render3D = ns.Render3D or {}",
        "ns.Render3D.ROOM_INDEX = {",
    ]
    for e in sorted(entries, key=lambda e: e["ref"]):
        f = e["fit"]
        lines.append('    ["%s"] = { floor = "%s", name = "%s", map = "%s",' % (e["ref"], e["floor"], e["name"].replace('"', '\\"'),
                                                                             e["map"]))
        lines.append("        fit = { ax = %.7f, bx = %.4f, ay = %.7f, by = %.4f }," % (f["ax"], f["bx"], f["ay"], f["by"]))
        lines.append("        view = { x = %.1f, y = %.1f, dist = %.0f }, spot = { x = %.2f, y = %.2f } }," % (
            e["view"][0], e["view"][1], e["view"][2], e["spot"][0], e["spot"][1]))
    lines.append("}")
    lines.append("-- The size of every creature on a boss portrait (CreatureDisplayInfo.CreatureModelScale, build 2.5.6.69795; 1 when")
    lines.append("-- not listed): the client draws a ModelScene actor at scale 1.")
    lines.append("ns.Render3D.DISPLAY_SCALE = {")
    items = sorted((scales or {}).items())
    for i in range(0, len(items), 8):
        lines.append("    " + " ".join("[%d] = %s," % (d, G.num(s)) for d, s in items[i:i + 8]))
    lines.append("}")
    path = os.path.join(OUT_DIR, "Index.lua")
    tmp = G.write_temp(path, "\n".join(lines) + "\n")
    G.move_into_place(tmp, path)


def run_one(ref):
    try:
        return _run_one(ref)
    except BaseException as ex:              # (one room failing must not stop the others)
        return ref, None, "FAILED: %s" % str(ex).replace(chr(10), " / ")[:400]


def _run_one(ref):
    starters, portraits, maps = addon_data()
    p = plan(ref, starters, portraits, maps)
    if not p:
        return ref, None, "no starter page on a known map"
    t0 = time.time()
    r = build(p)
    path, n_raw, n_enc = write_room(r)
    e = index_entry(r)
    with open(os.path.join(CACHE, "index", r["key"] + ".json"), "w") as fh:
        json.dump(e, fh)
    tilt = "".join(" TILTED %d %s: %d faces;" % (u, rot, n) for u, rot, n in p.get("tilted", []))
    msg = ("%-32s %4dx%-4d faces %5d (of %6d), tris %5d, nodes %4d, textures %3d, %4.0f KB -> %4.0f KB, spot %s, %.0f s"
           % (ref, r["w"], r["h"], r["faces"], r["raw"], len(r["tris"]), len(r["nodes"]), len(r["textures"]),
              n_raw / 1024, n_enc / 1024, p["how"], time.time() - t0)) + tilt
    return ref, e, msg


def main(argv):
    jobs = 1
    if "--jobs" in argv:
        jobs = int(argv[argv.index("--jobs") + 1])
        del argv[argv.index("--jobs"):argv.index("--jobs") + 2]
    index_only = "--index-only" in argv
    argv = [a for a in argv if a != "--index-only"]
    os.makedirs(os.path.join(CACHE, "index"), exist_ok=True)
    starters, portraits, _ = addon_data()
    refs = argv or sorted(starters)
    if not index_only:
        if jobs > 1:
            from concurrent.futures import ProcessPoolExecutor
            with ProcessPoolExecutor(jobs) as ex:
                for ref, e, msg in ex.map(run_one, refs):
                    print(msg if e else "%s: %s" % (ref, msg), flush=True)
        else:
            for ref in refs:
                ref, e, msg = run_one(ref)
                print(msg if e else "%s: %s" % (ref, msg), flush=True)
    entries = []
    for f in sorted(os.listdir(os.path.join(CACHE, "index"))):
        e = json.load(open(os.path.join(CACHE, "index", f)))
        if os.path.exists(os.path.join(OUT_DIR, e["floor"] + ".lua")):
            entries.append(e)
    write_index(entries, display_scales(portraits))
    print("wrote the index: %d rooms" % len(entries))


if __name__ == "__main__":
    main(sys.argv[1:])
