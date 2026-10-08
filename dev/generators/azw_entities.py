"""Azeromon world: creatures and objects from the cMaNGOS TBC database (tbcdb), placed on the tile grid.

creatures(box) -> list of dicts, one per spawn: guid, entry, name, sub, lvl (min, max), x, y (tiles, float),
z, face (0..2pi, WoW orientation), wander (yd), respawn (s), move (0 idle, 1 random, 2 waypoints), path, type,
family, rank, display, npcflags, reaction ("hostile" | "neutral" | "friendly"), events excluded.
objects(box) -> gameobjects likewise (entry, name, type, display, x, y, z, face, respawn).

Reaction to a (human) Alliance player = FactionTemplate rules (TrinityCore FactionTemplateEntry): hostile if the
template lists the player's faction (1) among its enemies or its EnemyGroup has the player / Alliance bits (1 | 2);
friendly if it lists it among its friends or its FriendGroup has those bits; else neutral."""
import csv
import math
import os

import adt_tools as A
import tbcdb

HERE = os.path.dirname(os.path.abspath(__file__))
DB2 = os.path.join(HERE, "..", "art", "tbcdb", "db2")

PLAYER_FACTION, PLAYER_MASK = 1, 3

# never placed: test / event / placeholder creatures
SKIP_NAME = ("[DND]", "TAR Pedestal", "(DND)", "Trigger", "Spirit Healer", "Invisible", "Stalker", "Bunny",
             "Battlemaster", "[PH]")


def _faction_templates():
    out = {}
    with open(os.path.join(DB2, "FactionTemplate.csv"), encoding="utf-8") as f:
        for row in csv.DictReader(f):
            out[int(row["ID"])] = row
    return out


_FT = None


def reaction(template_id):
    global _FT
    if _FT is None:
        _FT = _faction_templates()
    t = _FT.get(template_id)
    if not t:
        return "neutral"
    enemies = {int(t["Enemies_%d" % i]) for i in range(8)} - {0}
    friends = {int(t["Friend_%d" % i]) for i in range(8)} - {0}
    if PLAYER_FACTION in enemies:
        return "hostile"
    if PLAYER_FACTION in friends:
        return "friendly"
    if int(t["EnemyGroup"]) & PLAYER_MASK:
        return "hostile"
    # the "monster" group (FactionGroup 8) attacks players unless it names them a friend: Kobold Vermin (25)
    if int(t["FactionGroup"]) & 8 and not int(t["FriendGroup"]) & PLAYER_MASK:
        return "hostile"
    if int(t["FriendGroup"]) & PLAYER_MASK or int(t["FactionGroup"]) & 2:
        return "friendly"
    return "neutral"


def tile_of(wx, wy):
    return (A.MAP_HALF - wy) / A.TS, (A.MAP_HALF - wx) / A.TS


def creatures(gx0, gx1, gy0, gy1, mapid=0):
    db = tbcdb.load()
    ct = db.index("creature_template", "Entry")
    spawn_entry = db.multi("creature_spawn_entry", "guid")
    events = {r["guid"] for r in db.rows("game_event_creature")}
    addon = db.index("creature_addon", "guid")
    paths = db.multi("creature_movement", "Id")
    tpaths = db.multi("creature_movement_template", "Entry")
    pools = db.index("pool_creature", "guid")
    out = []
    for c in db.rows("creature"):
        if c["map"] != mapid or c["guid"] in events:
            continue
        x, y = tile_of(c["position_x"], c["position_y"])
        if not (gx0 <= x < gx1 and gy0 <= y < gy1):
            continue
        entries = [c["id"]] if c["id"] else [e["entry"] for e in spawn_entry.get(c["guid"], [])]
        if not entries:
            continue
        t = ct.get(entries[0])
        if not t or any(s in (t["Name"] or "") for s in SKIP_NAME):
            continue
        path = []
        mv = c["MovementType"]
        if mv == 2:
            pts = paths.get(c["guid"]) or [p for p in tpaths.get(entries[0], []) if p["PathId"] == 0]
            for p in sorted(pts, key=lambda p: p["Point"]):
                px, py = tile_of(p["PositionX"], p["PositionY"])
                path.append((round(px, 2), round(py, 2), p["WaitTime"]))
        ad = addon.get(c["guid"])
        out.append({
            "guid": c["guid"], "entry": entries[0], "entries": entries, "name": t["Name"], "sub": t["SubName"] or "",
            "lvl": (t["MinLevel"], t["MaxLevel"]), "x": x, "y": y, "z": c["position_z"], "face": c["orientation"],
            "wander": c["spawndist"], "respawn": c["spawntimesecsmin"], "move": mv, "path": path,
            "type": t["CreatureType"], "family": t["Family"], "rank": t["Rank"],
            "display": [d for d in (t["DisplayId1"], t["DisplayId2"], t["DisplayId3"], t["DisplayId4"]) if d],
            "npcflags": t["NpcFlags"], "faction": t["Faction"], "reaction": reaction(t["Faction"]),
            "stand": ad["stand_state"] if ad else 0, "emote": ad["emote"] if ad else 0,
            "pool": pools[c["guid"]]["pool_entry"] if c["guid"] in pools else None,
            "gossip": t["GossipMenuId"], "unit_class": t["UnitClass"],
        })
    return out


def objects(gx0, gx1, gy0, gy1, mapid=0):
    db = tbcdb.load()
    gt = db.index("gameobject_template", "entry")
    events = {r["guid"] for r in db.rows("game_event_gameobject")}
    spawn_entry = db.multi("gameobject_spawn_entry", "guid")
    pools = db.index("pool_gameobject", "guid")
    out = []
    for o in db.rows("gameobject"):
        if o["map"] != mapid or o["guid"] in events:
            continue
        x, y = tile_of(o["position_x"], o["position_y"])
        if not (gx0 <= x < gx1 and gy0 <= y < gy1):
            continue
        entry = o["id"] or (spawn_entry.get(o["guid"]) or [{"entry": 0}])[0]["entry"]
        t = gt.get(entry)
        if not t:
            continue
        out.append({"guid": o["guid"], "entry": entry, "name": t["name"], "type": t["type"], "display": t["displayId"],
                    "x": x, "y": y, "z": o["position_z"], "face": o["orientation"],
                    "respawn": o.get("spawntimesecsmin") or 0, "data0": t["data0"],
                    "pool": pools[o["guid"]]["pool_entry"] if o["guid"] in pools else None})
    return out


def facing(orientation):
    """WoW orientation (radians, 0 = north, counter-clockwise) -> the nearest of up / left / down / right on the map
    (north = up)."""
    a = orientation % (2 * math.pi)
    k = int((a + math.pi / 4) // (math.pi / 2)) % 4
    return ("up", "left", "down", "right")[k]
