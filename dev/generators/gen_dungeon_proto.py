"""Portal crawler prototype (2026-10-09): Hellfire Ramparts' entrance as a 3D room, through gen_rooms.py's pipeline.

The raid rooms come from a strategy page (gen_rooms.plan); a dungeon room has none, so its plan is written here: the
map (HellfireRampart, map 543), a world box from the instance's entrance (AzerothCore's teleport target -1355.24 /
1641.12 / 68.25) past the first pack on the ground floor (Bonechewer Hungerers 17259 and a Ravener 17264 at height
~68; the archers on the wall above stay out), and the entrance as the room's spot. Also writes the pack's spawns in
room coordinates (dev/art/crawler/ramparts_entrance.json) for the Trainer encounter.

Run: luaenv\\Scripts\\python.exe generators\\gen_dungeon_proto.py
-> Render3D/Rooms/HellfireRamparts_Entrance.lua (data format 3, as gen_rooms.write_room writes) + the json.
The room is not listed in Render3D/Rooms/Index.lua (no strategy board page) or the TOC: add the TOC line by hand.
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_rooms as R  # noqa: E402

# The rooms this script makes: key -> map id, map folder, world box (x0, y0, x1, y1; x north, y west), the spot
# (height 0 of the room: the floor there), a name. "hub" is the Portal game's hub: the Stair of Destiny, where the
# Dark Portal lets out in Outland (AzerothCore's game_tele "darkportal" on the Outland side, -248.15 / 922.91 /
# 84.35 on map 530), the Portal behind it and the ramp down.
ROOMS = {
    "ramparts": dict(key="HellfireRamparts_Entrance", ref="HellfireRamparts:Entrance", mapid=543,
                     mapdir="HellfireRampart", box=(-1380.0, 1605.0, -1290.0, 1695.0),
                     spot=(-1355.24, 1641.12, 68.25), name="Hellfire Ramparts"),
    # the hub's live floor: the platform and the Stair of Destiny in FRONT of the gate (west of its plane, world
    # y 946.8: the Portal faces Hellfire Peninsula), low walls only; the gate itself is a pre-rendered backdrop
    # standing in its plane (gen_portal_facade.py: 46k faces are far over the renderer's budget)
    "hub": dict(key="Portal_StairOfDestiny", ref="Portal:StairOfDestiny", mapid=530, mapdir="Expansion01",
                box=(-320.0, 948.0, -170.0, 1078.0), spot=(-245.7, 965.0, 84.35), name="The Stair of Destiny",
                up=8.0, down=40.0),
    # the hub since 2026-10-10: the Caverns of Time's hall round the great hourglass (Tanaris, map 1), height 0 at
    # Zaladormu (-8509 / -4356 / -208, under the hourglass); the rock outcrops kept whole (a 12 yd cut left their
    # hollow tops open), the cave's walls cut 30 yd up; the hourglass and the dragons are models (Games/Portal/Hub.lua), not room faces
    "cot": dict(key="Portal_CavernsOfTime", ref="Portal:CavernsOfTime", mapid=1, mapdir="Kalimdor",
                box=(-8620.0, -4460.0, -8380.0, -4160.0), spot=(-8509.0, -4356.0, -208.0), name="Caverns of Time",
                up=30.0, down=15.0),
    # the hub since 2026-10-10 (the Caverns of Time looked empty from above): the World's End Tavern in Shattrath's
    # Lower City (map 530), height 0 = the bar's floor (world -37.1); the walls cut 7 yd up so the follow camera looks
    # into it as Diablo shows buildings; its furniture (the WMO's M2 doodads) baked in as faces, biggest first
    # (generators/doodad_faces.py)
    "tavern": dict(key="Portal_WorldsEndTavern", ref="Portal:WorldsEndTavern", mapid=530, mapdir="Expansion01",
                   box=(-1785.0, 5116.0, -1721.0, 5180.0), spot=(-1753.0, 5148.0, -37.1),
                   name="World's End Tavern", up=6.0, down=7.0, doodads=3600, caps=True,
                   # the furniture, most wanted first (at most this many of each, the nearest the middle)
                   keep={"DwarvenTableLarge": 3, "DwarvenTableSmall": 4, "RoundTable": 1, "DuskwoodBench": 2,
                         "GeneralChairLoEnd01": 12, "BE_Rug_Large01": 1, "BE_Rug_MediumRuined01": 1,
                         "StormwindRug02": 3, "StormwindRug01": 4, "Barrel01": 8,
                         "Painting14": 1, "BeerKeg02": 1, "BeerKeg01": 1, "StormwindCrate01": 8}),
}


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "ramparts"
    cfg = ROOMS[which]
    MAPID, BOX, ENTRANCE = cfg["mapid"], cfg["box"], cfg["spot"]
    p = dict(ref=cfg["ref"], key=cfg["key"], raid=cfg["ref"].split(":")[0], mapid=MAPID,
             mapdir=cfg["mapdir"], mapfile=None, rect=(BOX[0], BOX[1], 0, BOX[2], BOX[3], 0), page={}, box=BOX,
             portrait=ENTRANCE[:2], spot=ENTRANCE, how="instance entrance", name=cfg["name"], ref_z=None)
    # a room's height band round its spot (gen_rooms ROOM_UP / ROOM_DOWN by ref): the hub keeps the Portal's arch and
    # the stair down
    if "up" in cfg:
        R.UP[cfg["ref"]] = cfg["up"]
    if "down" in cfg:
        R.DOWN[cfg["ref"]] = cfg["down"]
    if cfg.get("doodads"):
        import doodad_faces as DF
        gather = R.gather

        def with_doodads(pp):
            raw, spot, box, coll = gather(pp)
            zb = spot[2]
            if cfg.get("posts"):
                raw = DF.drop_posts(raw, zb + cfg.get("up", 7.0), cfg["posts"])
            if cfg.get("drop_textures"):             # (the columns the ceiling cut leaves as open boxes)
                n = len(raw)
                raw = [f for f in raw if f[0][0] not in cfg["drop_textures"]]
                print("dropped textures %s: %d faces" % (cfg["drop_textures"], n - len(raw)))
            raw += DF.faces(cfg["mapdir"], box, zb - cfg.get("down", 4.0), zb + cfg.get("up", 7.0), cfg["doodads"],
                            keep=cfg.get("keep"))
            return raw, spot, box, coll
        R.gather = with_doodads
    if cfg.get("caps"):
        import doodad_faces as DF
        clip = R.clip_faces

        def with_caps(raw, box, zlo, zhi, zb, *a, **kw):
            faces = clip(raw, box, zlo, zhi, zb, *a, **kw)
            return faces + DF.caps(faces, zhi)
        R.clip_faces = with_caps
    r = R.build(p)
    path, size, enc = R.write_room(r)
    print("room: %s (%d faces, %d nodes, %d bytes packed, %d as text)" % (path, len(r["tris"]), len(r["nodes"]), size, enc))
    # the first pack in room coordinates (x east from the box's west side, y north from its south side, z over the
    # entrance floor); world x north / y west -> room x = y1 - wy, y = wx - x0 (gen_rooms' to_room for this box)
    x0, y0, x1, y1 = r["roombox"]
    zb = r["zb"]
    pack = []
    for npc, ss in R.spawns().items():
        for m, wx, wy, wz in ss:
            if m == MAPID and BOX[0] <= wx <= BOX[2] and BOX[1] <= wy <= BOX[3] and abs(wz - zb) < 6:
                pack.append(dict(npc=npc, x=round(y1 - wy, 2), y=round(wx - x0, 2), z=round(wz - zb, 2)))
    ex, ey = y1 - ENTRANCE[1], ENTRANCE[0] - x0
    out = dict(room=r["key"], w=r["w"], h=r["h"], entrance=dict(x=round(ex, 2), y=round(ey, 2)), mobs=pack)
    jpath = os.path.join(HERE, "..", "art", "crawler", "%s.json" % cfg["key"])
    os.makedirs(os.path.dirname(jpath), exist_ok=True)
    json.dump(out, open(jpath, "w"), indent=1)
    print("spawns: %d on the entrance floor -> %s" % (len(pack), jpath))
    for m in pack:
        print("  npc %5d at %.1f, %.1f (z %.1f), %.0f yd from the entrance" % (m["npc"], m["x"], m["y"], m["z"],
              math.hypot(m["x"] - ex, m["y"] - ey)))


if __name__ == "__main__":
    main()
