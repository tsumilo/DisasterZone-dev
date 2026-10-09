"""Disastercraft's world map (M) and minimap data: everything is the client's own art, referenced by FileDataID, so
the addon ships no pictures for it.

- Minimap: WoW's minimap tiles (world/minimaps/azeroth/map<X>_<Y>.blp, one 256 px picture per ADT = 128 of our grid
  tiles) for every ADT of the built world (gen_azeromon_world.BOX).
- World map: per UiMap (Elwynn Forest 1429, Eastern Kingdoms 1415) its art (UiMapXMapArt -> UiMapArtTile, 256 px
  tiles row by row, the classic 1002 x 668 detail frame), where our grid lands on it (UiMapAssignment's world
  rectangle -> u = au * gx + bu, v = av * gy + bv), and its explored-area overlays (WorldMapOverlay +
  WorldMapOverlayTile) with the areas that reveal each one.
- Exploration: each area's ExplorationLevel (AreaTable) and WoW's base exploration XP per level
  (exploration_basexp), for "Discovered <area>: N experience gained".

Writes addon/DisasterZone/Games/Disastercraft/MapData.lua (ns.CraftMaps).
Run from dev: luaenv\\Scripts\\python.exe generators\\gen_dc_maps.py
"""
import csv
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import casc_local as C  # noqa: E402
import gen_map_overlays as MO  # noqa: E402

DEV = os.path.dirname(HERE)
OUT = os.path.join(DEV, "..", "addon", "DisasterZone", "Games", "Disastercraft", "MapData.lua")
MAPS = [1429, 1415]                  # Elwynn Forest (Northshire is part of it), Eastern Kingdoms
BOX = (29, 36, 46, 50)               # (gen_azeromon_world.BOX: the ADTs read)
TS = 533.33333 / 128
EDGE = 17066.66656                   # 32 ADTs: world coordinate of the grid's north-west corner


def num(v):
    f = float(v)
    return int(f) if f == int(f) else round(f, 6)


def lua(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(num(v))
    if isinstance(v, str):
        return '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(lua(x) for x in v) + " }"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            key = k if isinstance(k, str) and k.isidentifier() else "[%s]" % lua(k)
            parts.append("%s = %s" % (key, lua(x)))
        return "{ " + ", ".join(parts) + " }"
    raise TypeError(type(v))


def main():
    um = {int(r["ID"]): r for r in MO.table("UiMap")}
    xart = {int(r["UiMapID"]): int(r["UiMapArtID"]) for r in MO.table("UiMapXMapArt")}
    tiles = defaultdict(list)
    for r in MO.table("UiMapArtTile"):
        tiles[int(r["UiMapArtID"])].append((int(r["RowIndex"]), int(r["ColIndex"]), int(r["FileDataID"])))
    assign = defaultdict(list)
    for r in MO.table("UiMapAssignment"):
        assign[int(r["UiMapID"])].append(r)
    otiles = defaultdict(list)
    for r in MO.table("WorldMapOverlayTile"):
        otiles[int(r["WorldMapOverlayID"])].append((int(r["RowIndex"]), int(r["ColIndex"]), int(r["FileDataID"])))
    overlays = defaultdict(list)
    for r in MO.table("WorldMapOverlay"):
        overlays[int(r["UiMapArtID"])].append(r)

    maps = {}
    for mid in MAPS:
        art = xart[mid]
        t = sorted(tiles[art])
        rows, cols = max(x[0] for x in t) + 1, max(x[1] for x in t) + 1
        # the world rectangle on map 0 (Eastern Kingdoms): Region_0/1 = min x / y, Region_3/4 = max x / y;
        # u runs west -> east (world y falls), v north -> south (world x falls); grid: wy = EDGE - gx * TS
        a = next(r for r in sorted(assign[mid], key=lambda r: int(r["OrderIndex"])) if r["MapID"] == "0")
        x0, y0, x1, y1 = float(a["Region_0"]), float(a["Region_1"]), float(a["Region_3"]), float(a["Region_4"])
        u0, v0, u1, v1 = float(a["UiMin_0"]), float(a["UiMin_1"]), float(a["UiMax_0"]), float(a["UiMax_1"])
        su, sv = (u1 - u0) / (y1 - y0), (v1 - v0) / (x1 - x0)
        # u = u0 + (y1 - wy) * su = u0 + (y1 - EDGE + gx * TS) * su
        au, bu = TS * su, u0 + (y1 - EDGE) * su
        av, bv = TS * sv, v0 + (x1 - EDGE) * sv
        ovs = []
        for o in overlays[art]:
            ts = sorted(otiles[int(o["ID"])])
            if not ts:
                continue
            areas = [int(o["AreaID_%d" % i]) for i in range(4) if int(o["AreaID_%d" % i] or 0)]
            ovs.append({"areas": areas, "w": int(o["TextureWidth"]), "h": int(o["TextureHeight"]),
                        "x": int(o["OffsetX"]), "y": int(o["OffsetY"]),
                        "cols": max(x[1] for x in ts) + 1, "fids": [x[2] for x in ts]})
        maps[mid] = {"name": um[mid]["Name_lang"], "parent": int(um[mid]["ParentUiMapID"] or 0),
                     "rows": rows, "cols": cols, "art": [x[2] for x in t],
                     "au": au, "bu": bu, "av": av, "bv": bv, "overlays": ovs}
        print(um[mid]["Name_lang"], "art", rows, "x", cols, "overlays", len(ovs))

    mini = {}
    for ax in range(BOX[0], BOX[1] + 1):
        for ay in range(BOX[2], BOX[3] + 1):
            fid = C.fdid_of("world/minimaps/azeroth/map%d_%d.blp" % (ax, ay))
            if fid:
                mini["%d_%d" % (ax, ay)] = fid
    print("minimap tiles", len(mini))

    areas = {}
    with open(os.path.join(DEV, "art", "tbcdb", "db2", "AreaTable.csv"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["ContinentID"] == "0" and int(r["AreaBit"] or -1) >= 0:
                areas[int(r["ID"])] = int(r["ExplorationLevel"] or 0)
    import dc_db
    xp = {int(r["level"]): int(r["basexp"]) for r in dc_db.load().rows("exploration_basexp")}

    with open(OUT, "wb") as f:
        out = ['if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/MapData.lua", ...) then return end '
               '-- DisasterZone Games/Disastercraft/MapData.lua  (GENERATED by dev/generators/gen_dc_maps.py - do '
               'not edit)\n',
               "-- The world map and minimap: the client's own art by FileDataID (see gen_dc_maps.py)\n",
               "local addonName, ns = ...\nlocal M = {}\nns.CraftMaps = M\n",
               "-- [uiMapID] = { name, parent, rows, cols, art (256 px tiles row by row), grid -> map: u = au * gx + bu,"
               " v = av * gy + bv, overlays = { { areas, w, h, x, y, cols, fids } } }\n",
               "M.maps = {\n"]
        for mid, m in maps.items():
            out.append("    [%d] = %s,\n" % (mid, lua(m)))
        out.append("}\n-- minimap tiles: [\"<ADT x>_<ADT y>\"] = FileDataID (an ADT = 128 grid tiles, 256 px)\n")
        out.append("M.minimap = %s\n" % lua(mini))
        out.append("-- exploration: area -> ExplorationLevel (areas with an explore bit); level -> base exploration XP\n")
        out.append("M.areaLevel = %s\n" % lua(areas))
        out.append("M.exploreXP = %s\n" % lua(dict(sorted(xp.items()))))
        f.write("".join(out).encode("utf-8"))
    print("wrote", OUT, os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
    main()
