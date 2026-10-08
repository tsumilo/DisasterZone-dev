"""The strategy board's 3D rooms: one per raid encounter that has a starter strategy, from Blizzard's own geometry.

For every encounter (Data/StarterStrategies.lua) the room is what the starter's page shows on its floor map: the board's
1000 x 666 units at the page's pan and zoom, as a box in world coordinates (the floor map's world rectangle: retail
UiMapAssignment). The boss stands where the server spawns it (AzerothCore creature.sql, the creature nearest the
starter's portrait) or, for a creature the server summons, at the portrait, on the floor at the height of another
creature of that map floor (else the middle height of the creatures spawned within 90 yd: the Lurker's pool).

Geometry in the box:
  * every WMO placed in it (a global WMO of the map's WDT, or the MODF placements of the ADT tiles under the box),
    every group whose box meets it, each face cut exactly at the box's sides and at a height band round the boss'
    floor (ROOM_DOWN below, ROOM_UP above: walls end there, a cut-away model; ceilings and faces turned down go);
  * on maps with terrain the ADT height maps (MCVT; holes left out), textured with the game's own minimap tiles,
    kept TERRAIN_BAND yd over and under the boss (hills have no ceilings).
A room over MAX_TRIS faces or MAX_NODES BSP nodes shrinks round the page's middle (the boss kept 15 yd inside) until it
fits (the renderer's frame budget); as small as rooms get, its walls get lower, then loose objects go, then the finest carving.
The height grid (where drawings stand) is the highest floor up to FLOOR_UP yd over the boss', the ground's at any
height; the first view looks at the middle of the floor within 10 yd of the boss' height.

World <-> WMO local through the placement: wx = C - (pos.z + z'), wy = C - (pos.x + x'), wz = pos.y + local z, with
(x', z') the local (x, -y) turned by rot.y - 90 degrees; C = 17066.67 for ADT placements and 0 for a WDT's global WMO
(checked: Teron's spawn lands 0.08 yd from group 17's floor, Lady Vashj's on her platform).

Room coordinates: yards, x east (0 at the box's west side), y north (0 at its south side), height 0 = the boss' floor.
The fit to the shipped floor map is exact (both are axis-aligned): room x = ax * map px + bx, y = ay * map py + by.

Writes Render3D/Rooms/<Raid>_<Boss>.lua (data format 3: the version 2 tables of gen_trainer_heights.py as text,
deflated and printable-encoded for LibDeflate; Render3D/Rooms.lua unpacks a room when its 3D view opens) and
Render3D/Rooms/Index.lua (per boss: its room, the map, the fit, the first view, the boss' spot), and lists the rooms
in DisasterZone.toc (the lines between Render3D\\View.lua and Render3D\\Rooms.lua).
Blizzard's files are read from the installed client (casc_local.py; the bytes cached per build in dev/art/casc/files).
A map file (WMO root or group, WDT, ADT) it lacks fails the room, and the room is not written. wago.tools' copy can be
of another build, and a root and its groups from different builds put faces on the wrong texture (Karazhan in 1.3.0).
--allow-wago takes the copy anyway; each room then lists the files it took. Other files (creature models) fall back to
wago.tools with a logged line. The wago copies are cached in dev/art/rooms. Both caches are git-ignored.

Run: luaenv\\Scripts\\python.exe generators\\gen_rooms.py [Raid:Boss ...] [--jobs N] [--index-only] [--allow-wago]
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
import casc_local  # noqa: E402
from patchlib import deflate_raw, encode_for_print  # noqa: E402

ADDON = os.path.join(HERE, "..", "..", "addon", "DisasterZone")
OUT_DIR = os.path.join(ADDON, "Render3D", "Rooms")
CACHE = os.path.join(HERE, "..", "art", "rooms")
WMO_CACHE = os.path.join(HERE, "..", "art", "wmo")
LOCAL_CACHE = os.path.join(HERE, "..", "art", "casc", "files")   # (the installed client's files, per build)

MAX_TRIS = 7000                 # faces per room at most (the board's 3D view: 327 cluster frames of 32 nodes)
MAX_NODES = 2990                # BSP nodes at most (the 3D view's frames hold about 10 each; the self-check: 3000)
MAX_EDGE = 40.0                 # yd: longer faces are halved (the renderer subdivides on screen; this only keeps
                                # texture coordinates from growing huge)
MIN_HALF = 30.0                 # yd: a shrinking room keeps at least this round the boss
ROOM_UP, ROOM_DOWN = 14.0, 30.0  # yd over / under the boss' floor the room keeps
FLOOR_UP = 9.0                  # yd: the height grid's floors at most this over the boss' (Teron's hall: 6.2)
TERRAIN, TERRAIN_BAND = -1, 60.0  # the flag of a ground face; yd over and under the boss it is kept
LIQUID = -2                     # the flag of a liquid's face
WATER_TEX = 219885              # xtextures/river/fast_a.1.blp (grey ripples), tinted blue by the renderer (Render3D/Room.lua
                                # TINT); opaque: a see-through piece the 3D view redraws over a model shows twice
LIQUID_TEX = {0: (WATER_TEX, 0), 1: (WATER_TEX, 0), 2: (219795, 0), 3: (219991, 0)}   # (+ lava.1.blp, slime.1.blp)
WALK_COS = math.cos(math.radians(50))   # the steepest ground the client walks on (gen_trainer_heights.py)
SLIDE_COS = math.cos(math.radians(80))  # steeper up to here: a slope you slide down; steeper still: a wall
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
            part = "%s.part%d" % (path, os.getpid())      # (parallel jobs fetch the same files)
            subprocess.run(["curl", "-s", "-L", "-A", "Mozilla/5.0", "-o", part, url], check=False)
            if os.path.exists(part) and os.path.getsize(part) > 0:
                try:
                    os.replace(part, path)
                except OSError:
                    if not os.path.exists(path):
                        raise
                    os.remove(part)
                break
            if os.path.exists(path) and os.path.getsize(path) > 0:
                break
            time.sleep(1 + attempt)
    if not os.path.exists(path):
        raise SystemExit("could not download %s" % url)
    return path


_LOCAL = []                     # [build] once the installed client was found, [None] when it was not
_FELL_BACK = {}                 # file ID -> why the installed client could not give it
_ALLOW_WAGO = [False]           # --allow-wago (set per room by run_one: parallel jobs are other processes)
_WAGO_USED = []                 # the files the room being built took from wago.tools


def local_build():
    """The installed client's build (casc_local), or None without one (every file then comes from wago.tools)."""
    if not _LOCAL:
        try:
            casc_local.root()
            casc_local.names()                  # (both tables cached now, or each parallel job parses the root)
            _LOCAL.append(casc_local.build_name())
        except (OSError, KeyError, ValueError, SystemExit) as ex:
            print("no installed client to read (%s): every game file from wago.tools" % ex, flush=True)
            _LOCAL.append(None)
    return _LOCAL[0]


def local_file(fdid):
    """The installed client's own copy of a game file, cached as dev/art/casc/files/<build>/<fdid>.bin; None when
    this build does not have it on disk (or has it encrypted)."""
    build = local_build()
    if not build:
        return None
    path = os.path.join(LOCAL_CACHE, build, "%d.bin" % fdid)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    try:
        data = casc_local.read_fid(fdid)
    except (KeyError, ValueError) as ex:
        _FELL_BACK[fdid] = str(ex.args[0] if ex.args else ex)[:80]
        return None
    os.makedirs(os.path.dirname(path), exist_ok=True)
    part = "%s.part%d" % (path, os.getpid())         # (parallel jobs read the same files)
    with open(part, "wb") as fh:
        fh.write(data)
    try:
        # (rename, not replace: on Windows replacing a copy another job has open fails, or fails its open)
        os.rename(part, path)
    except OSError:
        os.remove(part)
        if not os.path.exists(path):
            raise
    return path


def casc(fdid, folder=CACHE):
    """A game file by its ID -> a path: the installed client's copy, else (logged) wago.tools' download, which is
    not tied to a build: the old downloads mixed builds (Karazhan's root had a material list shifted by one against
    its groups: up to 66% of a room on the wrong texture, Prince's platform dropped; 114 room groups differed)."""
    path = local_file(fdid)
    if path:
        return path
    why = _FELL_BACK.get(fdid, "no installed client")
    if local_build():
        _WAGO_USED.append(fdid)
    for d in (WMO_CACHE, folder):
        for ext in (".wmo", ".bin", ".adt", ".wdt"):
            p = os.path.join(d, "%d%s" % (fdid, ext))
            if os.path.exists(p) and os.path.getsize(p) > 0:
                print("file %d not in the installed client (%s): wago.tools' copy %s" % (fdid, why, p), flush=True)
                return p
    print("file %d not in the installed client (%s): downloading it from wago.tools" % (fdid, why), flush=True)
    return _get("https://wago.tools/api/casc/%d?download" % fdid, os.path.join(folder, "%d.bin" % fdid))


def map_file(fdid):
    """A WMO root or group, WDT or ADT by its ID -> a path, as casc, but never wago.tools' copy next to the installed
    client's files without --allow-wago: these files point into each other (a group's material numbers into its
    root's list), so one file of another build among them retextures or drops faces with no error (the shipped Hyjal
    rooms lost the Alliance base's tower that way). SystemExit fails the room (run_one), and nothing is written."""
    if local_build() and not _ALLOW_WAGO[0] and not local_file(fdid):
        raise SystemExit("map file %d is not in the installed client %s (%s); wago.tools' copy may be of another "
                         "build: --allow-wago takes it anyway" % (fdid, local_build(), _FELL_BACK.get(fdid, "?")))
    return casc(fdid)


_FDIDS = None


def fdid_of(filename):
    """A file's ID by its path: the installed client's own name table (casc_local), else wago.tools' file search,
    cached in dev/art/rooms/fdids.json; None when unknown. With a client, a path its table lacks is a file it does
    not have (every file there has its name): None, as the search would find another build's (unless --allow-wago)."""
    global _FDIDS
    if local_build():
        fid = casc_local.fdid_of(filename)
        if fid is not None or not _ALLOW_WAGO[0]:
            return fid
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


def _rot(axis, deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    if axis == "x":
        return ((1, 0, 0), (0, c, -s), (0, s, c))
    if axis == "y":
        return ((c, 0, s), (0, 1, 0), (-s, 0, c))
    return ((c, -s, 0), (s, c, 0), (0, 0, 1))


def _mul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


class Placement:
    """A WMO placed in the world: local -> world. In the placement space (x, y up, z) the local point (x, -y... as
    (lx, lz, -ly)) is turned by Ry(rot.y - 90) Rz(-rot.x) Rx(rot.z) and moved to pos: checked against the world box
    each MODF entry carries (13 tilted buildings of Black Temple, Zul'Aman and Hyjal to 0.002 yd)."""

    def __init__(self, p, global_wmo):
        self.file, self.uid = p["file"], p["uid"]
        self.px, self.py, self.pz = p["pos"]
        self.s = p["scale"]
        rx, ry, rz = p["rot"]
        self.M = _mul(_mul(_rot("y", ry - 90.0), _rot("z", -rx)), _rot("x", rz))
        self.C = 0.0 if global_wmo else ADT_C

    def to_world(self, lx, ly, lz):
        g = (lx * self.s, lz * self.s, -ly * self.s)
        M = self.M
        X = M[0][0] * g[0] + M[0][1] * g[1] + M[0][2] * g[2]
        Y = M[1][0] * g[0] + M[1][1] * g[1] + M[1][2] * g[2]
        Z = M[2][0] * g[0] + M[2][1] * g[1] + M[2][2] * g[2]
        return self.C - (self.pz + Z), self.C - (self.px + X), self.py + Y


_ROOTS, _GROUPS = {}, {}


def root(fid):
    if fid not in _ROOTS:
        _ROOTS[fid] = W.read_root(map_file(fid))
    return _ROOTS[fid]


def group(fid):
    if fid not in _GROUPS:
        _GROUPS[fid] = W.read_group(map_file(fid))
    return _GROUPS[fid]


def placements(mapdir, box):
    """The WMOs placed over a world box (x0, y0, x1, y1): a WDT's global WMO, else the ADT tiles' MODF entries."""
    wdt = fdid_of("world/maps/%s/%s.wdt" % (mapdir.lower(), mapdir.lower()))
    b = open(map_file(wdt), "rb").read()
    for tag, off, size in chunks(b):
        if tag == "MODF" and size:
            return [Placement(p, True) for p in read_modf(b, off, size)], False
    out, seen = [], set()
    for tx, ty in tiles(box):
        fid = fdid_of("world/maps/%s/%s_%d_%d_obj0.adt" % (mapdir.lower(), mapdir.lower(), tx, ty))
        if not fid:
            continue
        b = open(map_file(fid), "rb").read()
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


def wmo_faces(pl, box, zlo, zhi, coll=None):
    """World faces of a placed WMO inside a box: [(texture key, [(x, y, z, u, v, light)] * 3, flags)]. coll: a list
    that gets the faces the client collides with that are no steeper than SLIDE_COS ([(x, y, z)] * 3, "walk" or
    "slide", False): the ground walking units stand on (the invisible ramps over stairs included)."""
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
            if coll is not None and G.collidable(fl):
                P = [pl.to_world(*gr["verts"][i]) for i in t]
                if not (max(q[0] for q in P) < x0 or min(q[0] for q in P) > x1 or max(q[1] for q in P) < y0
                        or min(q[1] for q in P) > y1):
                    n = G.normal(*P)
                    if n and n[2] >= SLIDE_COS:
                        coll.append((P, "walk" if n[2] >= WALK_COS else "slide", False))
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
        if gr.get("liquid"):
            out += liquid_faces(pl, gr["liquid"])
    return out


def liquid_faces(pl, liq):
    """A WMO group's liquid as flat faces (LIQUID): runs of tiles of one kind at one height merged into rectangles.
    Water and ocean: WATER_TEX (a grey texture the renderer tints, Render3D/Room.lua TINT); magma and slime: the
    game's own textures."""
    xt, yt, xv = liq["xtiles"], liq["ytiles"], liq["xverts"]
    hs, tiles = liq["heights"], liq["tiles"]
    cx, cy, _ = liq["corner"]
    unit = W.LIQUID_UNIT
    cell = {}
    for j in range(yt):
        for i in range(xt):
            t = tiles[j * xt + i]
            if t & 0x0F == 0x0F:
                continue
            kind = t & 3                             # (SSC's water groups say 15: "see the tiles")
            c = [hs[j * xv + i], hs[j * xv + i + 1], hs[(j + 1) * xv + i + 1], hs[(j + 1) * xv + i]]
            flat = max(c) - min(c) < 0.05
            cell[(i, j)] = (kind, round(sum(c) / 4, 2) if flat else None, c)
    out, done = [], set()

    def face(kind, quad):
        tex, blend = LIQUID_TEX[kind]
        pts = []
        for lx, ly, lz in quad:
            wx, wy, wz = pl.to_world(lx, ly, lz)
            pts.append((wx, wy, wz, lx / 16.0, ly / 16.0, 1.0))
        a, b_, c_, d = pts
        n = G.normal(a[:3], b_[:3], c_[:3])
        if n and n[2] < 0:
            a, b_, c_, d = a, d, c_, b_
        out.append(((tex, blend), [a, b_, c_], LIQUID))
        out.append(((tex, blend), [a, c_, d], LIQUID))
    for j in range(yt):
        for i in range(xt):
            if (i, j) in done or (i, j) not in cell:
                continue
            kind, h, c = cell[(i, j)]
            if h is None:                            # (a sloped tile: on its own, its corners' heights)
                done.add((i, j))
                x0, y0 = cx + i * unit, cy + j * unit
                face(kind, [(x0, y0, c[0]), (x0 + unit, y0, c[1]), (x0 + unit, y0 + unit, c[2]), (x0, y0 + unit, c[3])])
                continue
            i1 = i
            while (i1 + 1, j) not in done and cell.get((i1 + 1, j), (None, None))[:2] == (kind, h):
                i1 += 1
            j1 = j
            while all((k, j1 + 1) not in done and cell.get((k, j1 + 1), (None, None))[:2] == (kind, h)
                      for k in range(i, i1 + 1)):
                j1 += 1
            for jj in range(j, j1 + 1):
                for ii in range(i, i1 + 1):
                    done.add((ii, jj))
            x0, y0, x1, y1 = cx + i * unit, cy + j * unit, cx + (i1 + 1) * unit, cy + (j1 + 1) * unit
            face(kind, [(x0, y0, h), (x1, y0, h), (x1, y1, h), (x0, y1, h)])
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
        b = open(map_file(fid), "rb").read()
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
                    out.append(((mini, 0), [a, d, cq], TERRAIN))
                    out.append(((mini, 0), [a, cq, bq], TERRAIN))
    return out


def clip_faces(faces, box, zlo, zhi, zb):
    """The parts of faces inside a box and a height band (exact cuts; the ground's: TERRAIN_BAND yd round zb, its
    hills have no ceilings over them), turned-down faces dropped."""
    x0, y0, x1, y1 = box
    out = []
    for key, pts, fl in faces:
        n = G.normal(pts[0][:3], pts[1][:3], pts[2][:3])
        if not n or n[2] < -0.3:
            continue
        if fl == TERRAIN:
            lo, hi = (x0, y0, zb - TERRAIN_BAND), (x1, y1, zb + TERRAIN_BAND)
        else:
            lo, hi = (x0, y0, zlo), (x1, y1, zhi)
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


CLUTTER = 4.0                   # yd: as small as a room gets, loose objects up to this size across are left out
MERGE_TOL = 0.3                 # yd: faces fused into one piece stay this close to the piece's plane


def _affine(st, vals):
    """a, b, c with a*s + b*t + c = val at the three points, or None (a sliver)."""
    (s0, t0), (s1, t1), (s2, t2) = st
    det = (s1 - s0) * (t2 - t0) - (s2 - s0) * (t1 - t0)
    if abs(det) < 1e-9:
        return None
    v0, v1, v2 = vals
    a = ((v1 - v0) * (t2 - t0) - (v2 - v0) * (t1 - t0)) / det
    b = ((s1 - s0) * (v2 - v0) - (s2 - s0) * (v1 - v0)) / det
    return a, b, v0 - a * s0 - b * t0


def _fit(points):
    """h = a*s + b*t + c through points (s, t, h) by least squares (numpy), or None."""
    import numpy as np
    A = np.array([(q[0], q[1], 1.0) for q in points])
    h = np.array([q[2] for q in points])
    try:
        sol, *_ = np.linalg.lstsq(A, h, rcond=None)
    except Exception:
        return None
    return tuple(float(c) for c in sol)


def merge_faces(faces):
    """Fewer, bigger faces for the same picture. Faces are seen along their normal's main axis (a floor from above,
    a wall from the side): (s, t) = the other two world axes, h = that axis. Neighbours (a shared edge) of one
    texture and one texture mapping (u, v an affine function of s, t, up to whole repeats) grow into a region while
    every corner stays MERGE_TOL yd from the region's plane; a region is fused (the union of its outlines) and cut
    into triangles again. Every corner of the outline keeps its own height, texture coordinates and light, so the
    pieces round it meet it without cracks; the game's floors and walls are built of many small faces."""
    import shapely
    from shapely.geometry import Polygon
    info = []
    for f in faces:
        key, pts, fl = f
        n = G.normal(*[q[:3] for q in pts])
        if not n:
            info.append(None)
            continue
        ax = max(range(3), key=lambda i: abs(n[i]))
        a_, b_ = [i for i in range(3) if i != ax]
        st = [(q[a_], q[b_]) for q in pts]
        mu, mv = _affine(st, [q[3] for q in pts]), _affine(st, [q[4] for q in pts])
        if not mu or not mv:
            info.append(None)
            continue
        mk = (key, fl, ax, n[ax] > 0, round(mu[0], 3), round(mu[1], 3), round((mu[2] % 1.0) * 100) % 100,
              round(mv[0], 3), round(mv[1], 3), round((mv[2] % 1.0) * 100) % 100)
        info.append((mk, ax, a_, b_, st, mu, mv))
    # edges -> faces of the same class
    def vk(q):
        return (round(q[0], 2), round(q[1], 2), round(q[2], 2))
    edge_faces = collections.defaultdict(list)
    for k, f in enumerate(faces):
        if info[k] is None:
            continue
        ks = [vk(q) for q in f[1]]
        for e in range(3):
            a, b = ks[e], ks[(e + 1) % 3]
            edge_faces[(info[k][0], min(a, b), max(a, b))].append(k)
    nbrs = collections.defaultdict(set)
    for (mk, _, _), ks in edge_faces.items():
        for x in ks:
            for y in ks:
                if x != y:
                    nbrs[x].add(y)
    done = [False] * len(faces)
    out = []
    for seed in range(len(faces)):
        if done[seed]:
            continue
        done[seed] = True
        if info[seed] is None:
            out.append(faces[seed])
            continue
        mk, ax, a_, b_, _, mu, mv = info[seed]
        region = [seed]
        pts = [(q[a_], q[b_], q[ax]) for q in faces[seed][1]]
        plane = _fit(pts)
        frontier = list(nbrs[seed])
        while frontier:
            k = frontier.pop()
            if done[k] or k in region:
                continue
            cand = [(q[a_], q[b_], q[ax]) for q in faces[k][1]]
            if any(abs(plane[0] * c[0] + plane[1] * c[1] + plane[2] - c[2]) > MERGE_TOL for c in cand):
                continue
            trial = _fit(pts + cand) if len(region) % 16 == 0 else plane
            if trial is None or any(abs(trial[0] * c[0] + trial[1] * c[1] + trial[2] - c[2]) > MERGE_TOL
                                    for c in cand):
                continue
            region.append(k)
            done[k] = True
            pts += cand
            plane = trial
            frontier += [x for x in nbrs[k] if not done[x]]
        if len(region) < 3:
            out += [faces[k] for k in region]
            for k in region[1:]:
                done[k] = True
            continue
        # the corners as they are (height, light) by their (s, t)
        corner = {}
        for k in region:
            for q in faces[k][1]:
                corner[(round(q[a_], 3), round(q[b_], 3))] = q
        try:
            merged = shapely.union_all([Polygon(info[k][4]) for k in region if Polygon(info[k][4]).area > 1e-8])
            tris = []
            for poly in getattr(merged, "geoms", [merged]):
                if poly.geom_type == "Polygon" and poly.area > 1e-6:
                    tris += [list(t.exterior.coords)[:3] for t in shapely.constrained_delaunay_triangles(poly).geoms]
        except Exception:
            tris = None
        if not tris or len(tris) >= len(region):
            out += [faces[k] for k in region]
            continue
        n0 = G.normal(*[q[:3] for q in faces[seed][1]])
        for tri in tris:
            new = []
            for s_, t_ in tri:
                q = corner.get((round(s_, 3), round(t_, 3)))
                w = [0.0, 0.0, 0.0]
                w[a_], w[b_] = s_, t_
                w[ax] = q[ax] if q else plane[0] * s_ + plane[1] * t_ + plane[2]
                light = q[5] if q else faces[seed][1][0][5]
                new.append((w[0], w[1], w[2], mu[0] * s_ + mu[1] * t_ + mu[2], mv[0] * s_ + mv[1] * t_ + mv[2], light))
            nn = G.normal(*[q[:3] for q in new])
            if not nn:
                continue
            if sum(nn[i] * n0[i] for i in range(3)) < 0:
                new = [new[0], new[2], new[1]]
            out.append((faces[seed][0], tuple(new), faces[seed][2]))
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
        if not n or n[2] < 0.6:                      # (turned up: a ceiling is no floor)
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


def num2(v):
    s = ("%.2f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def walk_tables(coll, box, zb, to_room):
    """The ground walking units stand on, in room coordinates: (verts [(x, y, z)], walk, slide, swim [(a, b, c)]):
    the collision faces cut to the box, those reaching into the room's height band (the ground's: TERRAIN_BAND),
    vertices welded at 1 cm (Render3D/Rooms.lua R3.GroundFn reads them)."""
    x0, y0, x1, y1 = box
    verts, index, out = [], {}, {"walk": [], "slide": [], "swim": []}
    lo, hi = zb - ROOM_DOWN - 2, zb + ROOM_UP
    for P, kind, ground in coll:
        zs = [q[2] for q in P]
        if ground:
            if max(zs) < zb - TERRAIN_BAND or min(zs) > zb + TERRAIN_BAND:
                continue
        elif max(zs) < lo or min(zs) > hi:
            continue
        poly = [tuple(q) for q in P]
        for axis, a0, a1 in ((0, x0, x1), (1, y0, y1)):
            if min(q[axis] for q in poly) >= a0 and max(q[axis] for q in poly) <= a1:
                continue
            poly = G.clip_poly(poly, axis, a0, False)
            if len(poly) >= 3:
                poly = G.clip_poly(poly, axis, a1, True)
            if len(poly) < 3:
                break
        if len(poly) < 3:
            continue
        ids = []
        for q in poly:
            rx, ry, rz = to_room(q[0], q[1], q[2])
            key = (round(rx, 2), round(ry, 2), round(rz, 2))
            if key not in index:
                index[key] = len(verts)
                verts.append(key)
            ids.append(index[key])
        for k in range(1, len(ids) - 1):
            if len({ids[0], ids[k], ids[k + 1]}) == 3:
                out[kind].append((ids[0], ids[k], ids[k + 1]))
    return verts, out["walk"], out["slide"], out["swim"]


def num5(v):
    s = ("%.5f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def num3(v):
    return G.num3(v)




def safe_key(ref):
    return re.sub(r"[^A-Za-z0-9]", "_", ref)


# The boss' floor height where the guesses pick the wrong level of a stacked building: Nightbane lands on the Master's
# Terrace (91.5), but the chess pieces of the Gamesman's Hall (232) stand nearer his map spot.
LEVEL = {"Karazhan:Nightbane": 91.5}
# The box (world x0, y0, x1, y1) where the starter page frames more than the fight: the terrace disc (~53 yd round
# its centre) instead of the page, whose middle is the tower beside it.
BOX = {"Karazhan:Nightbane": (-11125.6 - 57, -1925.0 - 57, -11125.6 + 57, -1925.0 + 57),
       # the whole chess board (boss_chess_event.cpp SetupBoard: cell (c, r) at x = -11108.1 + 3.49c + 4.4r,
       # y = -1872.91 - 4.4c + 3.45r, 5.6 yd squares turned 38 degrees) and 3 yd past its corners: the Games hub's
       # Karazhan Chess plays on all 64 squares (shrinking round Medivh cut two corners off)
       "Karazhan:Chess": (-11080.48 - 34.5, -1876.24 - 34.5, -11080.48 + 34.5, -1876.24 + 34.5)}
# Rooms whose box must stay whole: over budget they lower their walls and drop clutter instead of shrinking.
KEEP_BOX = {"Karazhan:Chess"}
# yd under the boss' floor a room keeps, where ROOM_DOWN would fill it with what is under a roof (the terrace sits on
# top of the tower's rooms).
DOWN = {"Karazhan:Nightbane": 4.0}
# yd over it, likewise (the tower walls beside the terrace would leave room for only half of it).
UP = {"Karazhan:Nightbane": 8.0}


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
    # without a spawn: the height of another creature on the same floor map that has one (the room's level)
    ref_z = None
    if not spot:
        for other, ost in sorted(starters.items()):
            if ost["p"][0].get("map") != mapfile or not other.startswith(raid + ":"):
                continue
            for cr in portraits.get(other) or []:
                ss = [s for s in spawns().get(cr["id"], []) if s[0] == mapid
                      and (s[1] - wx) ** 2 + (s[2] - wy) ** 2 < 150 ** 2]
                if ss and ref_z is None:
                    ref_z = min(ss, key=lambda s: (s[1] - wx) ** 2 + (s[2] - wy) ** 2)[3]
        if ref_z is None:
            # (else the middle height of every creature spawned within 90 yd: the Lurker's pool has fish and
            # technicians round it, but a world trigger hangs in the air)
            zs = sorted(s[3] for ss in spawns().values() for s in ss
                        if s[0] == mapid and (s[1] - wx) ** 2 + (s[2] - wy) ** 2 < 90 ** 2)
            if zs:
                ref_z = zs[len(zs) // 2]
    corners = [board_to_world(page, rect, x, y) for x, y in ((0, 0), (BW, 0), (0, BH), (BW, BH))]
    box = (min(c[0] for c in corners), min(c[1] for c in corners), max(c[0] for c in corners), max(c[1] for c in corners))
    box = BOX.get(ref, box)
    name = (boss["n"] if boss else ref.split(":")[1])
    return dict(ref=ref, key=safe_key(ref), raid=raid, mapid=mapid, mapdir=mapdir, mapfile=mapfile, rect=rect,
                page=page, box=box, portrait=(wx, wy), spot=spot, how=how, name=name, ref_z=ref_z)


def gather(p):
    """The room's faces in world coordinates, the boss' spot and floor height, the box used."""
    box = p["box"]
    pls, has_terrain = placements(p["mapdir"], box)
    raw, coll = [], []
    for pl in pls:
        raw += wmo_faces(pl, box, -1e9, 1e9, coll)
    # terrain: every vertex up to 1500 faces in the box, else every 2nd, 4th or 8th (a terrain face is a BSP node of
    # its own: bumps are never in one plane)
    step = 1
    while step < 8 and (box[2] - box[0]) * (box[3] - box[1]) / (TILE / 128 * step) ** 2 * 2 > 1500:
        step *= 2
    if has_terrain:
        raw += terrain_faces(p["mapdir"], box, step)
    # the ground, and the water you swim in (the ground's faces and the liquids' as they are drawn)
    for _, pts, fl in raw:
        if fl == TERRAIN or fl == LIQUID:
            P = [q[:3] for q in pts]
            n = G.normal(*P)
            if fl == LIQUID:
                coll.append((P, "swim", False))
            elif n and n[2] >= SLIDE_COS:
                coll.append((P, "walk" if n[2] >= WALK_COS else "slide", True))
    # the boss' floor
    if p["ref"] in LEVEL:
        sx, sy = p["portrait"]
        z0 = LEVEL[p["ref"]]
        fl = [z for z in floors_at(raw, sx, sy) if abs(z - z0) < 8]
        zb = min(fl, key=lambda z: abs(z - z0)) if fl else z0
    elif p["spot"]:
        sx, sy, sz = p["spot"]
        fl = [z for z in floors_at(raw, sx, sy) if z <= sz + 1.5]
        zb = max(fl) if fl else sz
    else:
        sx, sy = p["portrait"]
        zmin = p["rect"][2]
        fl = floors_at(raw, sx, sy)
        # the floor the creatures spawned within 60 yd stand on (one up to 3 yd under them: not a flier, a fish or a
        # trigger in the air; Kil'jaeden's Anveena floats 42 yd over his terrace), those within 20 yd of the plan's
        # guess first (Karazhan is a tower: under Nightbane's terrace are the stables), else the plan's guess
        near = sorted((math.hypot(s[1] - sx, s[2] - sy), s) for ss in spawns().values() for s in ss
                      if s[0] == p["mapid"] and (s[1] - sx) ** 2 + (s[2] - sy) ** 2 < 60 ** 2)[:40]
        stand = []
        for _, s in near:
            under = [z for z in floors_at(raw, s[1], s[2]) if s[3] - 3 <= z <= s[3] + 1]
            if under:
                stand.append(max(under))
        if p.get("ref_z") is not None and any(abs(z - p["ref_z"]) <= 20 for z in stand):
            stand = [z for z in stand if abs(z - p["ref_z"]) <= 20]
        if stand:
            p = dict(p, ref_z=sorted(stand)[len(stand) // 2])
        if p.get("ref_z") is not None:
            # a floor under the spot near that height, else the one with the most area round it (the Lurker
            # comes up from water: under his spot is the pool's bottom)
            near = [z for z in fl if abs(z - p["ref_z"]) < 8]
            if near:
                zb = min(near, key=lambda z: abs(z - p["ref_z"]))
            else:
                zb = main_floor(raw, sx, sy, 60.0, p["ref_z"])
                zb = p["ref_z"] if zb is None else zb
        elif zmin > -9999 and fl:
            above = [z for z in fl if z >= zmin - 2]
            zb = min(above) if above else max(fl)
        else:
            zb = max(fl) if fl else 0.0
    return raw, (sx, sy, zb), box, coll


def shrink(box, spot, centre):
    """The box 12% smaller round the room the starter frames (its centre), the boss kept 15 yd inside, not past the
    old box; None when it is as small as a room gets. (Round the boss alone cut the chess board off: the Echo of
    Medivh stands at its edge.)"""
    sx, sy, _ = spot
    hx, hy = (box[2] - box[0]) / 2 * 0.88, (box[3] - box[1]) / 2 * 0.88
    if hx < MIN_HALF and hy < MIN_HALF:
        return None
    hx, hy = max(MIN_HALF, hx), max(MIN_HALF, hy)
    cx, cy = centre
    cx = min(max(cx, sx - hx + 15), sx + hx - 15)
    cy = min(max(cy, sy - hy + 15), sy + hy - 15)
    cx = min(max(cx, box[0] + hx), box[2] - hx)
    cy = min(max(cy, box[1] + hy), box[3] - hy)
    return (cx - hx, cy - hy, cx + hx, cy + hy)


def main_floor(faces, x, y, r, z0):
    """The height with the most floor (faces turned up, by area, 1 yd steps) within r yd of a point and 15 yd of
    a height, or None."""
    bins = collections.Counter()
    for _, pts, _ in faces:
        a, b, c = (q[:3] for q in pts)
        mx, my = (a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3
        if (mx - x) ** 2 + (my - y) ** 2 > r * r:
            continue
        ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
        vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
        nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
        area = 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz)
        z = (a[2] + b[2] + c[2]) / 3
        if area > 0 and nz / (2 * area) > 0.7 and abs(z - z0) < 15:
            bins[round(z)] += area
    return float(bins.most_common(1)[0][0]) if bins else None


def build(p):
    """The room: its faces cut to the box (shrunk while it has more than MAX_TRIS faces or MAX_NODES BSP nodes)."""
    raw, spot, box, coll = gather(p)
    zb = spot[2]
    clutter = 0.0
    up, down, fine = UP.get(p["ref"], ROOM_UP), DOWN.get(p["ref"], ROOM_DOWN), 0.0
    centre = ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
    while True:
        faces = clip_faces(raw, box, zb - down, zb + up, zb)
        smaller = None if p["ref"] in KEEP_BOX else shrink(box, spot, centre)
        if len(faces) > MAX_TRIS and smaller:
            box = smaller
            continue
        r = make(p, raw, spot, box, faces, coll)
        if len(r["nodes"]) > MAX_NODES or (p["ref"] in KEEP_BOX and len(faces) > MAX_TRIS):
            if smaller:
                box = smaller
                continue
            if up > 4:                               # as small as rooms get: lower walls (fewer pieces) instead
                up, down = up - 3, min(down, max(8.0, down - 6))
                continue
            if clutter < CLUTTER:                    # then leave out loose objects (never a wall's faces)
                clutter = clutter * 2 if clutter else 0.5
                raw = drop_clutter(raw, clutter)
                continue
            if fine < 4.0:                           # last: the finest carving (never a floor)
                fine = fine * 2 if fine else 0.05
                raw = [f for f in raw if not small(f, fine)]
                continue
            raise SystemExit("%s: %d BSP nodes even at the smallest room" % (p["ref"], len(r["nodes"])))
        return r


def drop_clutter(faces, size):
    """The faces without the loose objects up to `size` yd across: an object = faces joined by shared corners; one
    with a floor in it (a face turned up, over 1 sq yd) stays. A wall is one big piece, so it never loses faces."""
    def vk(q):
        return (round(q[0], 2), round(q[1], 2), round(q[2], 2))
    parent = list(range(len(faces)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    owner = {}
    for k, (_, pts, _) in enumerate(faces):
        for q in pts:
            j = owner.setdefault(vk(q), k)
            if j != k:
                a, b = find(j), find(k)
                if a != b:
                    parent[a] = b
    lo, hi, floor_ = {}, {}, set()
    for k, (_, pts, fl) in enumerate(faces):
        r = find(k)
        for q in pts:
            l, h = lo.get(r), hi.get(r)
            lo[r] = tuple(min(l[i], q[i]) for i in range(3)) if l else tuple(q[:3])
            hi[r] = tuple(max(h[i], q[i]) for i in range(3)) if h else tuple(q[:3])
        if fl == TERRAIN or not small(faces[k], 1.0):
            a, b, c = (q[:3] for q in pts)
            n = G.normal(a, b, c)
            if fl == TERRAIN or (n and n[2] > 0.7):
                floor_.add(r)
    out = []
    for k, f in enumerate(faces):
        r = find(k)
        if r not in floor_ and math.dist(lo[r], hi[r]) < size:
            continue
        out.append(f)
    return out


def small(face, limit):
    """Is a face smaller than `limit` square yards and no floor?"""
    a, b, c = (q[:3] for q in face[1])
    ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
    vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
    nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    area = 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz)
    return area < limit and not (area > 0 and nz / (2 * area) > 0.7)


def make(p, raw, spot, box, faces, coll=()):
    sx, sy, zb = spot
    x0, y0, x1, y1 = box
    # room coordinates: x east from the box's west side (largest world y), y north from its south side (smallest x)
    W_ = int(math.ceil(y1 - y0))
    H_ = int(math.ceil(x1 - x0))

    def to_room(wx, wy, wz):
        return y1 - wy, wx - x0, wz - zb
    tex_index, textures, blends, tris, ground, water_z = {}, [], [], [], set(), set()
    for (fid, blend), pts, fl in faces:
        key = (fid, blend)
        if key not in tex_index:
            tex_index[key] = len(textures) + 1
            textures.append(fid)
            blends.append(G.BLEND_NAMES.get(blend, "BLEND"))
        tris.append((tex_index[key], tuple(to_room(*q[:3]) + tuple(q[3:]) for q in pts)))
        if fl == TERRAIN:
            ground.add(len(tris) - 1)
        elif fl == LIQUID:
            water_z.add(round(tris[-1][1][0][2], 3))
    # the height grid: the highest floor at each cell up to FLOOR_UP yd over the boss' (else a roof or a balcony),
    # the ground's at any height
    cell = 1 if max(W_, H_) <= 180 else 2
    grid = collections.defaultdict(list)
    for k, (_, pts) in enumerate(tris):
        n = G.normal(pts[0][:3], pts[1][:3], pts[2][:3])
        if n and n[2] > 0.6:
            xs, ys = [q[0] for q in pts], [q[1] for q in pts]
            for gx in range(int(min(xs) // 8), int(max(xs) // 8) + 1):
                for gy in range(int(min(ys) // 8), int(max(ys) // 8) + 1):
                    grid[(gx, gy)].append((pts, k in ground))

    def height(x, y):
        best = None
        for pts, is_ground in grid.get((int(x // 8), int(y // 8)), ()):
            (ax, ay, az), (bx, by, bz), (cx, cy, cz) = (q[:3] for q in pts)
            d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(d) < 1e-9:
                continue
            w1 = ((by - cy) * (x - cx) + (cx - bx) * (y - cy)) / d
            w2 = ((cy - ay) * (x - cx) + (ax - cx) * (y - cy)) / d
            w3 = 1 - w1 - w2
            if min(w1, w2, w3) >= -1e-4:
                z = w1 * az + w2 * bz + w3 * cz
                if (z <= FLOOR_UP or is_ground) and (best is None or z > best):
                    best = z
        return best
    cols, rws = (W_ + cell - 1) // cell, (H_ + cell - 1) // cell
    hs = [[height((i + 0.5) * cell, (j + 0.5) * cell) for i in range(cols)] for j in range(rws)]
    vals = [h for row in hs for h in row if h is not None] or [0.0]
    # where the camera first looks: the middle of the floor near the boss' height (a starter's page can show
    # much more than the room: Bloodboil's), far enough back to see all of it
    near = [((i + 0.5) * cell, (j + 0.5) * cell) for j, row in enumerate(hs) for i, h in enumerate(row)
            if h is not None and abs(h) <= 10]
    if near:
        nx0, nx1 = min(q[0] for q in near) - cell, max(q[0] for q in near) + cell
        ny0, ny1 = min(q[1] for q in near) - cell, max(q[1] for q in near) + cell
        view = ((nx0 + nx1) / 2, (ny0 + ny1) / 2, max(40.0, max(nx1 - nx0, ny1 - ny0) * 0.85))
    else:
        view = (W_ / 2.0, H_ / 2.0, max(W_, H_) * 0.85)
    lo, hi = min(vals), max(vals)
    base = math.floor(lo * 4) / 4
    step = 0.25
    while base + step * (len(G.ALPHA62) - 1) < hi:
        step *= 2
    rows = ["".join(" " if h is None else G.ALPHA62[max(0, min(61, int(round((h - base) / step))))] for h in row)
            for row in hs]
    # the mesh: BSP order, long pieces cut, quad pairs (gen_trainer_heights' format version 2)
    nodes = G.build_bsp(tris, random.Random(7), [(0.0, 0.0, 1.0, -z) for z in sorted(water_z)])
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
        if longest > MAX_EDGE and textures[tex - 1] != WATER_TEX:      # (water: one big flat piece stays one)
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
    if len(out_nodes) <= MAX_NODES:                 # (over the budget the room is cut smaller first: build)
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
                walk=walk_tables(coll, box, zb, to_room),
                bossSpot=(rx, ry), faces=len(faces), raw=len(raw), view=view)


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
    wv, wt, ws, wsw = r.get("walk") or ([], [], [], [])
    parts += [" ".join("%s %s %s" % (num2(v[0]), num2(v[1]), num2(v[2])) for v in wv)]
    parts += [" ".join("%d %d %d" % (a + 1, b + 1, c + 1) for a, b, c in faces) for faces in (wt, ws, wsw)]
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
    return dict(ref=r["ref"], floor=r["key"], name=r["name"], map=r["mapfile"], fit=r["fit"],
                view=r["view"], spot=r["bossSpot"], w=r["w"], h=r["h"])


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


def display_parts(portraits):
    """display id -> [(x0, y0, z0, x1, y1, z1)] in model units: the creature as the client shows it standing (its
    Stand animation's first frame, m2_tools.py) cut into up to 6 boxes where it has volume (k-means over the
    occupied cells of an 8-cell grid over its longest side; one box under 4 yd), for the 3D view's occlusion: each
    box is drawn over by the room pieces in front of it (UI/StrategyMap3D.lua). Models: CreatureDisplayInfo.ModelID
    -> CreatureModelData.FileDataID (wago.tools, build 2.5.6.69795), the .m2 from the installed client (casc);
    cached in dev/art/rooms/parts.json (an .m2 downloaded from wago.tools is not kept)."""
    import m2_tools
    cache_path = os.path.join(CACHE, "parts.json")
    cache = json.load(open(cache_path)) if os.path.exists(cache_path) else {}
    cdi = {int(r["ID"]): r for r in csv.DictReader(open(_get(
        "https://wago.tools/db2/CreatureDisplayInfo/csv?build=2.5.6.69795", os.path.join(CACHE, "CreatureDisplayInfo.csv")),
        encoding="utf-8"))}
    cmd = {int(r["ID"]): r for r in csv.DictReader(open(_get(
        "https://wago.tools/db2/CreatureModelData/csv?build=2.5.6.69795", os.path.join(CACHE, "CreatureModelData.csv")),
        encoding="utf-8"))}
    out = {}
    for d in sorted({int(c["d"]) for cs in portraits.values() for c in cs}):
        if str(d) in cache:
            out[d] = cache[str(d)]
            continue
        row = cdi.get(d)
        model = row and cmd.get(int(row["ModelID"]))
        if not model:
            continue
        scale = float(row["CreatureModelScale"] or 1) or 1.0
        geo = [float(model["GeoBox_%d" % i]) for i in range(6)]
        parts = [geo]
        fid = int(model["FileDataID"] or 0)
        path = None
        try:
            if fid:
                path = casc(fid)
                vs, _ = m2_tools.standing_vertices(open(path, "rb").read())
                if vs:
                    parts = split_parts(vs, scale)
        except Exception as ex:                       # (a model that cannot be read keeps its GeoBox)
            print("display %d: %s" % (d, ex))
        finally:
            if path and path.startswith(os.path.abspath(CACHE)) or (path and CACHE in path):
                try:
                    os.remove(path)
                except OSError:
                    pass
        out[d] = cache[str(d)] = [[round(v, 2) for v in box] for box in parts]
    json.dump(cache, open(cache_path, "w"))
    return out


def file_parts():
    """model file ID -> boxes (as display_parts) for the game objects of Data/EncounterObjects.lua: entry -> display,
    size (AzerothCore gameobject_template) -> FileDataID (GameObjectDisplayInfo, build 2.5.6.69795) -> the .m2 from
    the installed client, standing. Cached in parts.json as "f<file id>". (Not the states' effect models: the barrier
    on Vashj, 166541, is a sheet facing the camera with no standing vertices; its size is in the definition.)"""
    import m2_tools
    import gen_model_index as MI
    src = open(os.path.join(ADDON, "Data", "EncounterObjects.lua"), encoding="utf-8").read()
    block = src[src.index("    entries = {"):]
    block = block[:block.index("\n    },")]                        # (the game objects, not the npcs that follow)
    entries = sorted({int(m) for m in re.findall(r'\[(\d+)\]\s*=\s*"\w+"', block)})
    got = {row[0]: (row[2], row[7] or 1.0) for row in MI.sql_rows(_get(
        MI.ACORE + "gameobject_template.sql", os.path.join(CACHE, "gameobject_template.sql")))}
    godi = {int(r["ID"]): int(r["FileDataID"] or 0) for r in csv.DictReader(open(_get(
        MI.WAGO % "GameObjectDisplayInfo", os.path.join(CACHE, "GameObjectDisplayInfo.csv")), encoding="utf-8"))}
    files = {}
    for entry in entries:
        disp, size = got[entry]
        files.setdefault(godi[disp], float(size))
    cache_path = os.path.join(CACHE, "parts.json")
    cache = json.load(open(cache_path)) if os.path.exists(cache_path) else {}
    out = {}
    for fid, size in sorted(files.items()):
        key = "f%d" % fid
        if key not in cache:
            vs, _ = m2_tools.standing_vertices(open(casc(fid), "rb").read())
            cache[key] = [[round(v, 2) for v in box] for box in split_parts(vs, size)]
        out[fid] = cache[key]
    json.dump(cache, open(cache_path, "w"))
    return out


def split_parts(vs, scale):
    """Standing vertices -> up to 6 boxes (model units) where the model has volume."""
    xs, ys, zs = zip(*vs)
    lo = (min(xs), min(ys), min(zs))
    hi = (max(xs), max(ys), max(zs))
    size = max(hi[i] - lo[i] for i in range(3))
    k = 1 if size * scale < 4 else min(6, int(math.ceil(size * scale / 5)))
    if k == 1:
        return [list(lo) + list(hi)]
    cell = size / 8.0
    cells = {}
    for v in vs:
        key = tuple(int((v[i] - lo[i]) / cell) for i in range(3))
        cells.setdefault(key, []).append(v)
    pts = [tuple(lo[i] + (key[i] + 0.5) * cell for i in range(3)) for key in cells]
    keys = list(cells)
    # farthest-point start, then Lloyd's steps
    cent = [pts[0]]
    while len(cent) < min(k, len(pts)):
        cent.append(max(pts, key=lambda q: min(sum((q[i] - c[i]) ** 2 for i in range(3)) for c in cent)))
    for _ in range(25):
        groups = [[] for _ in cent]
        for q in pts:
            groups[min(range(len(cent)), key=lambda j: sum((q[i] - cent[j][i]) ** 2 for i in range(3)))].append(q)
        cent = [tuple(sum(q[i] for q in g) / len(g) for i in range(3)) if g else cent[j] for j, g in enumerate(groups)]
    boxes = []
    for j in range(len(cent)):
        members = [v for key, q in zip(keys, pts) if min(range(len(cent)), key=lambda c: sum(
            (q[i] - cent[c][i]) ** 2 for i in range(3))) == j for v in cells[key]]
        if members:
            mx, my, mz = zip(*members)
            boxes.append([min(mx), min(my), min(mz), max(mx), max(my), max(mz)])
    return boxes


def display_centres(portraits):
    """display id -> (x, y): the middle of CreatureModelData.GeoBox (model units; the Stand animation's own box),
    where it is off the model's origin by more than 0.02. The client turns and places a ModelScene creature by that
    middle sideways, not by its origin (Kil'jaeden's is 29 yd off at his scale): the 3D view moves the actor back by
    it so the origin stands on its spot (UI/StrategyMap3D.lua)."""
    cdi = {int(r["ID"]): r for r in csv.DictReader(open(os.path.join(CACHE, "CreatureDisplayInfo.csv"), encoding="utf-8"))}
    cmd = {int(r["ID"]): r for r in csv.DictReader(open(os.path.join(CACHE, "CreatureModelData.csv"), encoding="utf-8"))}
    out = {}
    for d in sorted({int(c["d"]) for cs in portraits.values() for c in cs}):
        row = cdi.get(d)
        model = row and cmd.get(int(row["ModelID"]))
        if not model:
            continue
        g = [float(model["GeoBox_%d" % i]) for i in range(6)]
        cx, cy = (g[0] + g[3]) / 2, (g[1] + g[4]) / 2
        if abs(cx) > 0.02 or abs(cy) > 0.02:
            out[d] = (round(cx, 3), round(cy, 3))
    return out


def write_index(entries, scales=None, parts=None, centres=None, fparts=None):
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
    lines.append("-- Every creature on a boss portrait as it stands (model units, x forward, y left, z up from its feet; times the")
    lines.append("-- scale above): up to 6 boxes x0, y0, z0, x1, y1, z1 in a row (gen_rooms.py display_parts), what the 3D view")
    lines.append("-- has the room drawn over where it lies in front of them.")
    lines.append("ns.Render3D.DISPLAY_PARTS = {")
    for d, boxes in sorted((parts or {}).items()):
        lines.append("    [%d] = { %s }," % (d, ", ".join(G.num(v) for box in boxes for v in box)))
    lines.append("}")
    lines.append("-- Where the client centres each creature sideways (the middle of CreatureModelData.GeoBox, model units x, y;")
    lines.append("-- gen_rooms.py display_centres): the 3D view moves the actor back by it so the model's origin is on its spot.")
    lines.append("ns.Render3D.DISPLAY_CENTRE = {")
    items = sorted((centres or {}).items())
    for i in range(0, len(items), 4):
        lines.append("    " + " ".join("[%d] = { %s, %s }," % (d, G.num(c[0]), G.num(c[1])) for d, c in items[i:i + 4]))
    lines.append("}")
    lines.append("-- The game objects of Data/EncounterObjects.lua by model file ID, as they stand (as DISPLAY_PARTS; times the")
    lines.append("-- object's size; gen_rooms.py file_parts).")
    lines.append("ns.Render3D.FILE_PARTS = {")
    for f, boxes in sorted((fparts or {}).items()):
        lines.append("    [%d] = { %s }," % (f, ", ".join(G.num(v) for box in boxes for v in box)))
    lines.append("}")
    path = os.path.join(OUT_DIR, "Index.lua")
    tmp = G.write_temp(path, "\n".join(lines) + "\n")
    G.move_into_place(tmp, path)


def write_toc(entries):
    """The TOC loads every room, then the index, before Render3D\\Rooms.lua (the lines between View.lua and it)."""
    toc = os.path.join(OUT_DIR, "..", "..", "DisasterZone.toc")
    lines = open(toc, "rb").read().decode("utf-8").split("\n")
    i, j = lines.index("Render3D\\View.lua"), lines.index("Render3D\\Rooms.lua")
    keep = ["Render3D\\Rooms\\TeronGorefiendFloor.lua", "Render3D\\Rooms\\LadyVashjFloor.lua"]   # (the trainer's)
    rooms = ["Render3D\\Rooms\\%s.lua" % e["floor"] for e in sorted(entries, key=lambda e: e["floor"])]
    lines[i + 1:j] = keep + rooms + ["Render3D\\Rooms\\Index.lua"]
    open(toc, "wb").write("\n".join(lines).encode("utf-8"))


def run_one(ref, allow_wago=False):
    _ALLOW_WAGO[0] = allow_wago
    del _WAGO_USED[:]
    try:
        ref, e, msg = _run_one(ref)
    except BaseException as ex:              # (one room failing must not stop the others)
        return ref, None, "FAILED: %s" % str(ex).replace(chr(10), " / ")[:400]
    if _WAGO_USED:                           # (--allow-wago: say which files may be of another build)
        ids = sorted(set(_WAGO_USED))
        msg += "\n    %d files from wago.tools: %s" % (len(ids), " ".join(str(f) for f in ids[:20]))
    return ref, e, msg


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
    msg = ("%-32s %4dx%-4d faces %5d (of %6d), tris %5d, nodes %4d, textures %3d, %4.0f KB -> %4.0f KB, spot %s, %.0f s"
           % (ref, r["w"], r["h"], r["faces"], r["raw"], len(r["tris"]), len(r["nodes"]), len(r["textures"]),
              n_raw / 1024, n_enc / 1024, p["how"], time.time() - t0))
    return ref, e, msg


def main(argv):
    jobs = 1
    if "--jobs" in argv:
        jobs = int(argv[argv.index("--jobs") + 1])
        del argv[argv.index("--jobs"):argv.index("--jobs") + 2]
    index_only = "--index-only" in argv
    allow_wago = _ALLOW_WAGO[0] = "--allow-wago" in argv
    argv = [a for a in argv if a not in ("--index-only", "--allow-wago")]
    os.makedirs(os.path.join(CACHE, "index"), exist_ok=True)
    local_build()                               # (the client's tables read and cached once, before parallel jobs)
    starters, portraits, _ = addon_data()
    refs = argv or sorted(starters)
    failed = []
    if not index_only:
        if jobs > 1:
            from concurrent.futures import ProcessPoolExecutor
            with ProcessPoolExecutor(jobs) as ex:
                results = ex.map(run_one, refs, [allow_wago] * len(refs))
                for ref, e, msg in results:
                    print(msg if e else "%s: %s" % (ref, msg), flush=True)
                    if msg.startswith("FAILED"):
                        failed.append(ref)
        else:
            for ref in refs:
                ref, e, msg = run_one(ref, allow_wago)
                print(msg if e else "%s: %s" % (ref, msg), flush=True)
                if msg.startswith("FAILED"):
                    failed.append(ref)
    entries = []
    for f in sorted(os.listdir(os.path.join(CACHE, "index"))):
        e = json.load(open(os.path.join(CACHE, "index", f)))
        if os.path.exists(os.path.join(OUT_DIR, e["floor"] + ".lua")):
            entries.append(e)
    write_index(entries, display_scales(portraits), display_parts(portraits), display_centres(portraits), file_parts())
    write_toc(entries)
    print("wrote the index: %d rooms" % len(entries))
    if failed:                                  # (said again at the end: a --jobs run's lines are easy to miss)
        print("%d rooms FAILED, their old files kept: %s" % (len(failed), ", ".join(failed)), flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
