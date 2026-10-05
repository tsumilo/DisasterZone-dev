"""Every encounter's assets for the strategy boards, in groups (gen_starter_strategies.py turns them into the starters'
icons and Data/EncounterSpawns.lua; Data/EncounterObjects.lua gives each icon key its look and states).

A group: n (its name in the icon menu, "<n> at their spots"), starter (True: on the starter page, there at the pull;
else only from the menu), l (the label its icons get), items:
  (icon key, where, state[, label])  where = "spawn" (every spawn of that object / NPC near the boss: AzerothCore
                                     gameobject.sql / creature.sql) or [(x, y, z, orientation), ...]
  ("arrow", (x, y), (x2, y2), colour)            a route or a line the boss draws (colour: UI/StrategyMap.lua COLORS)
  ("zone", (x, y), radius yd, colour, label)     a circle; ("rect", (x, y), (x2, y2), colour, label) a rectangle
Positions come from the research files (data/encounter_assets/assets_<raid>.json): each position there names the
script line or table row it was read from; at() picks them. Creatures without states use their NPC's own key too
(their name: Data/BossPortraits.lua, else the label given here).
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data", "encounter_assets")
RED, BLUE, ORANGE, GREEN, PURPLE, YELLOW, CYAN, PINK, WHITE, GREY = range(1, 11)
_FILES = {}


def entry(raid, ref, ident, name=None):
    if raid not in _FILES:
        _FILES[raid] = json.load(open(os.path.join(DATA, "assets_%s.json" % raid), encoding="utf-8"))
    for a in _FILES[raid][ref]:
        if a["id"] == ident and (name is None or name in a["name"]):
            return a
    raise KeyError((raid, ref, ident, name))


def at(raid, ref, ident, name=None, pick=None):
    """The researched positions of an asset, [(x, y, z, orientation)]: all, or those pick(position) accepts."""
    out = [(p["x"], p["y"], p["z"], p.get("o")) for p in entry(raid, ref, ident, name)["positions"]
           if pick is None or pick(p)]
    assert out, (raid, ref, ident, name, "no position")
    return out


def label(text, key="label"):
    """A pick for at(): positions whose label (or another field) holds text."""
    return lambda p: text in str(p.get(key, ""))


def nth(*idx):
    """A pick for at(): positions by their place in the research list (0-based)."""
    want = set(idx)
    seen = []

    def pick(p):
        seen.append(p)
        return len(seen) - 1 in want
    return pick


def chain(points, colour):
    """Arrows from point to point [(x, y, ...), ...]."""
    return [("arrow", (a[0], a[1]), (b[0], b[1]), colour) for a, b in zip(points, points[1:])]


def _netherspite():
    # boss_netherspite.cpp SummonPortals (L108-123): r = rand() % 4 lays the colours on the three spots PortalCoord[0]
    # left, [1] right, [2] back: r0 red-left / green-right / blue-back, r1 red-right / green-left / blue-back,
    # r2 red-left / green-back / blue-right, r3 red-back / green-left / blue-right
    spots = at("karazhan", "Karazhan:Netherspite", 17369)          # (the three spots, in PortalCoord order)
    layouts = [("red left, green right, blue back", 0, 1, 2), ("red right, green left, blue back", 1, 0, 2),
               ("red left, green back, blue right", 0, 2, 1), ("red back, green left, blue right", 2, 1, 0)]
    out = []
    for k, (text, r, g, b) in enumerate(layouts):
        out.append({"n": "Portals, layout %d: %s" % (k + 1, text), "starter": k == 0,
                    "items": [("npc:17369", [spots[r]], None), ("npc:17367", [spots[g]], None),
                              ("npc:17368", [spots[b]], None)]})
    return out


def _chess():
    # every piece on its start square (boss_chess_event.cpp; creature.sql)
    entry("karazhan", "Karazhan:Chess", 17211)                       # (loads the file)
    return [("npc:%d" % a["id"], at("karazhan", "Karazhan:Chess", a["id"]), None, a["name"])
            for a in _FILES["karazhan"]["Karazhan:Chess"]]


def _kael_weapons():
    keys = [21274, 21270, 21272, 21269, 21273, 21271, 21268]
    return [("npc:%d" % k, at("ssc_tk", "TempestKeep:Kaelthas", k), None) for k in keys]


def _hatcher_routes():
    r = entry("za", "ZulAman:Janalai", 23818)["route"]
    return chain([(p["x"], p["y"]) for p in r["west"]], ORANGE) + chain([(p["x"], p["y"]) for p in r["east"]], ORANGE)


def _eye_blast():
    # each Eye Blast runs from eyeBeamPos[i] to eyeBeamPos[i + 4] (boss_illidan.cpp L507-509)
    pts = at("bt", "BlackTemple:Illidan", 23070)
    return [("arrow", pts[i][:2], pts[i + 4][:2], RED) for i in range(4)]


def _felmyst_lanes():
    out = []
    for lane in ("TOP", "MIDDLE", "BOTTOM"):
        a = at("sunwell", "SunwellPlateau:Felmyst", 25038, "air-phase", label("lane %s, left" % lane))[0]
        b = at("sunwell", "SunwellPlateau:Felmyst", 25038, "air-phase", label("lane %s, right" % lane))[0]
        out.append(("arrow", a[:2], b[:2], GREEN))
    return out


def _aran_blizzard():
    path = entry("karazhan", "Karazhan:Aran", 17161)["path"]
    pts = [(p["x"], p["y"]) for p in path]
    return chain(pts + pts[:1], CYAN)                               # (a loop)


def _hydross_field():
    p = at("ssc_tk", "SerpentshrineCavern:Hydross", 21934)[0]
    r = entry("ssc_tk", "SerpentshrineCavern:Hydross", 21934)["radius"]
    return [("zone", p[:2], r, BLUE, "Cleansing Field")]


def _archimonde_radius():
    e = entry("gruul_mag_hyjal", "HyjalSummit:Archimonde", 22418)["enrageRadius"]
    return [("zone", tuple(e["center"]), e["yd"], RED, "Enrage radius")]


def _janalai_bombs():
    a = entry("za", "ZulAman:Janalai", 23920, "Fire Bomb area")["area"]
    return [("rect", (a["xMin"], a["yMin"]), (a["xMax"], a["yMax"]), ORANGE, "Fire Bomb area")]


def _solarian_rings():
    rings = entry("ssc_tk", "TempestKeep:Solarian", 18928)["rings"]
    out = []
    for r in rings:
        out.append(("zone", (r["x"], r["y"]), r["r"], PURPLE, "Portal ring %d yd" % int(r["r"])))
    return out


ASSETS = {
    # ---------------------------------------------------------------- Serpentshrine Cavern
    "SerpentshrineCavern:Vashj": [
        # the four generators that hold Lady Vashj's Magic Barrier in phase 2 (objects 185051-185054, one spawn each)
        {"n": "Shield Generators", "starter": True, "l": "Generator",
         "items": [("obj:185051", "spawn", None), ("obj:185052", "spawn", None), ("obj:185053", "spawn", None),
                   ("obj:185054", "spawn", None)]},
        {"n": "Elemental spawns (P2)", "starter": False,
         "items": [("npc:21958", at("ssc_tk", "SerpentshrineCavern:Vashj", 21958), None)]},
        {"n": "Elite and Strider spawns (P2)", "starter": False,
         "items": [("npc:22055", at("ssc_tk", "SerpentshrineCavern:Vashj", 22055), None)]},
        {"n": "Sporebat spawns (P3)", "starter": False,
         "items": [("npc:22140", at("ssc_tk", "SerpentshrineCavern:Vashj", 22140), None)]},
    ],
    "SerpentshrineCavern:Hydross": [
        {"n": "Beam Helpers and the Cleansing Field", "starter": True,
         "items": [("npc:21933", at("ssc_tk", "SerpentshrineCavern:Hydross", 21933), None)] + _hydross_field()},
    ],
    "SerpentshrineCavern:Lurker": [
        {"n": "Strange Pool", "starter": True, "items": [("obj:184956", "spawn", None)]},
        {"n": "Submerge adds", "starter": False,
         "items": [("npc:21865", at("ssc_tk", "SerpentshrineCavern:Lurker", 21865), None, "Ambusher"),
                   ("npc:21873", at("ssc_tk", "SerpentshrineCavern:Lurker", 21873), None, "Guardian")]},
    ],
    "SerpentshrineCavern:Leotheras": [
        {"n": "Greyheart Spellbinders", "starter": True, "l": "Greyheart Spellbinder",
         "items": [("npc:21806", at("ssc_tk", "SerpentshrineCavern:Leotheras", 21806), None)]},
    ],
    "SerpentshrineCavern:Morogrim": [
        {"n": "Water Globule spots (25%)", "starter": False,
         "items": [("npc:21913", at("ssc_tk", "SerpentshrineCavern:Morogrim", 21913), None, "Globule")]},
        {"n": "Murloc spawns", "starter": False,
         "items": [("npc:21920", at("ssc_tk", "SerpentshrineCavern:Morogrim", 21920), None, "Murloc")]},
    ],
    # ---------------------------------------------------------------- Tempest Keep
    "TempestKeep:Alar": [
        {"n": "Platforms", "starter": True,
         # (platforms 1-4 only: the pre-nerf 5 and 6 are unused, boss_alar.cpp L150)
         "items": [("npc:19514", at("ssc_tk", "TempestKeep:Alar", 19514, None,
                                     lambda p: str(p.get("label", "")).startswith("platform")), None)]},
        {"n": "Ember spawns", "starter": False,
         "items": [("npc:19551", at("ssc_tk", "TempestKeep:Alar", 19551), None, "Ember")]},
    ],
    "TempestKeep:Solarian": [
        {"n": "Portal rings", "starter": False, "items": _solarian_rings()},
    ],
    "TempestKeep:Kaelthas": [
        {"n": "Advisors", "starter": True,
         "items": [("npc:%d" % k, at("ssc_tk", "TempestKeep:Kaelthas", k), None,
                    entry("ssc_tk", "TempestKeep:Kaelthas", k)["name"]) for k in (20064, 20060, 20062, 20063)]},
        {"n": "Weapons (P2)", "starter": False, "items": _kael_weapons()},
    ],
    # ---------------------------------------------------------------- Magtheridon's Lair
    "MagtheridonsLair:Magtheridon": [
        # (labelled: the board suggests a job block per label - who kills which Channeler, who clicks which Cube)
        {"n": "Hellfire Channelers", "starter": True, "l": "Hellfire Channeler", "items": [("npc:17256", "spawn", None)]},
        {"n": "Manticron Cubes", "starter": True, "l": "Cube", "items": [("obj:181713", "spawn", None)]},
        # (not the "Magtheridon Column" objects 184634-184639: their model, raid_column_fx 192772, is the cave-in's
        # falling debris 55-75 yd up by the ceiling, not the pillars - those are the room's own mesh)
        {"n": "Debris points (30%)", "starter": False,
         "items": [("npc:17474", at("gruul_mag_hyjal", "MagtheridonsLair:Magtheridon", 17474), None)]},
    ],
    # ---------------------------------------------------------------- Hyjal Summit
    "HyjalSummit:Winterchill": [
        {"n": "Jaina and the waves", "starter": True,
         "items": [("npc:17772", at("gruul_mag_hyjal", "HyjalSummit:Winterchill", 17772), None),
                   ("npc:17895", at("gruul_mag_hyjal", "HyjalSummit:Winterchill", 17895), None)]},
    ],
    "HyjalSummit:Anetheron": [
        {"n": "Jaina and the waves", "starter": True,
         "items": [("npc:17772", at("gruul_mag_hyjal", "HyjalSummit:Anetheron", 17772), None),
                   ("npc:17895", at("gruul_mag_hyjal", "HyjalSummit:Anetheron", 17895), None)]},
    ],
    "HyjalSummit:Kazrogal": [
        {"n": "Thrall and the waves", "starter": True,
         "items": [("npc:17852", at("gruul_mag_hyjal", "HyjalSummit:Kazrogal", 17852), None, "Thrall"),
                   ("npc:17895", at("gruul_mag_hyjal", "HyjalSummit:Kazrogal", 17895), None)]},
        {"n": "Frost Wyrm spawns", "starter": False,
         "items": [("npc:17907", at("gruul_mag_hyjal", "HyjalSummit:Kazrogal", 17907), None, "Frost Wyrm")]},
    ],
    "HyjalSummit:Azgalor": [
        {"n": "Thrall and the waves", "starter": True,
         "items": [("npc:17852", at("gruul_mag_hyjal", "HyjalSummit:Azgalor", 17852), None, "Thrall"),
                   ("npc:17895", at("gruul_mag_hyjal", "HyjalSummit:Azgalor", 17895), None)]},
        {"n": "Infernal landing spots", "starter": False,
         "items": [("npc:21075", at("gruul_mag_hyjal", "HyjalSummit:Azgalor", 21075), None)]},
        {"n": "Frost Wyrm spawn", "starter": False,
         "items": [("npc:17907", at("gruul_mag_hyjal", "HyjalSummit:Azgalor", 17907), None, "Frost Wyrm")]},
    ],
    "HyjalSummit:Archimonde": [
        {"n": "Nordrassil and Tyrande", "starter": True,
         "items": [("npc:22418", at("gruul_mag_hyjal", "HyjalSummit:Archimonde", 22418, None, nth(0)), None),
                   ("npc:17948", at("gruul_mag_hyjal", "HyjalSummit:Archimonde", 17948), None, "Tyrande")]},
        {"n": "Enrage radius", "starter": False, "items": _archimonde_radius()},
        {"n": "Night Elf wave", "starter": False,
         "items": [("npc:17895", at("gruul_mag_hyjal", "HyjalSummit:Archimonde", 17895), None)]},
    ],
    # ---------------------------------------------------------------- Black Temple
    "BlackTemple:ShadeOfAkama": [
        {"n": "Channelers and Akama", "starter": True,
         "items": [("npc:23421", at("bt", "BlackTemple:ShadeOfAkama", 23421), None, "Ashtongue Channeler"),
                   ("npc:23191", at("bt", "BlackTemple:ShadeOfAkama", 23191, None, nth(0)), None, "Akama")]},
        {"n": "Add doors", "starter": False,
         "items": [("npc:23216", at("bt", "BlackTemple:ShadeOfAkama", 23216), None, "Defenders"),
                   ("npc:23215", at("bt", "BlackTemple:ShadeOfAkama", 23215), None, "Sorcerers")]},
    ],
    "BlackTemple:Reliquary": [
        {"n": "Soul spawns", "starter": False,
         "items": [("npc:23469", at("bt", "BlackTemple:Reliquary", 23469), None)]},
    ],
    "BlackTemple:Illidan": [
        {"n": "Blades of Azzinoth (P2)", "starter": False,
         "items": [("npc:22996", at("bt", "BlackTemple:Illidan", 22996), None, "Blade")]},
        {"n": "Flight spots (P2)", "starter": False,
         "items": [("npc:22917", at("bt", "BlackTemple:Illidan", 22917, "flight spots"), None)]},
        {"n": "Eye Blast lines (P2)", "starter": False, "items": _eye_blast()},
    ],
    # ---------------------------------------------------------------- Zul'Aman
    "ZulAman:Janalai": [
        {"n": "Eggs, west", "starter": False,
         "items": [("npc:23817", at("za", "ZulAman:Janalai", 23817, None, label("west", "side")), None)]},
        {"n": "Eggs, east", "starter": False,
         "items": [("npc:23817", at("za", "ZulAman:Janalai", 23817, None, label("east", "side")), None)]},
        {"n": "Hatchers and their routes", "starter": False,
         "items": [("npc:23818", at("za", "ZulAman:Janalai", 23818), None)] + _hatcher_routes()},
        {"n": "Fire walls", "starter": False,
         "items": [("npc:23920", at("za", "ZulAman:Janalai", 23920, "Fire Wall"), None)]},
        {"n": "Fire Bomb area", "starter": False, "items": _janalai_bombs()},
    ],
    "ZulAman:Malacrass": [
        # each slot holds one of two adds, picked per instance (boss_hexlord.cpp AddEntrySets)
        {"n": "Adds: Thurg, Raadan, Gazakroth, Darkheart", "starter": False,
         "items": [("npc:%d" % k, at("za", "ZulAman:Malacrass", k), None) for k in (24241, 24243, 24244, 24246)]},
        {"n": "Adds: Alyson, Slither, Fenstalker, Koragg", "starter": False,
         "items": [("npc:%d" % k, at("za", "ZulAman:Malacrass", k), None) for k in (24240, 24242, 24245, 24247)]},
    ],
    "ZulAman:Zuljin": [
        {"n": "Spirits", "starter": True,
         "items": [("npc:23878", at("za", "ZulAman:Zuljin", 23878), None, "Bear spirit"),
                   ("npc:23880", at("za", "ZulAman:Zuljin", 23880), None, "Eagle spirit"),
                   ("npc:23877", at("za", "ZulAman:Zuljin", 23877), None, "Lynx spirit"),
                   ("npc:23879", at("za", "ZulAman:Zuljin", 23879), None, "Dragonhawk spirit")]},
    ],
    # ---------------------------------------------------------------- Karazhan
    "Karazhan:Moroes": [
        # 4 of the 6 guests attend: one of each trio is left out at random (boss_moroes.cpp InitializeGuests)
        {"n": "Guests (4 of these 6 attend)", "starter": False,
         "items": [("npc:%d" % k, at("karazhan", "Karazhan:Moroes", k), None, entry("karazhan", "Karazhan:Moroes", k)["name"])
                   for k in (17007, 19872, 19873, 19874, 19875, 19876)]},
    ],
    "Karazhan:OperaOz": [
        # (stage props unlabelled: a label would make the board suggest a job block for them)
        {"n": "Hay bales", "starter": True, "items": [("obj:183496", "spawn", None)]},
        {"n": "The Crone and Tito", "starter": False,
         "items": [("npc:18168", at("karazhan", "Karazhan:OperaOz", 18168), None, "The Crone"),
                   ("npc:17548", at("karazhan", "Karazhan:OperaOz", 17548), None, "Tito")]},
    ],
    "Karazhan:OperaWolf": [
        {"n": "Stage", "starter": True,
         "items": [("obj:183493", "spawn", None), ("obj:183492", "spawn", None),
                   ("npc:17603", at("karazhan", "Karazhan:OperaWolf", 17603), None, "Grandmother")]},
    ],
    "Karazhan:OperaRomulo": [
        {"n": "Balcony", "starter": True, "items": [("obj:183495", "spawn", None)]},
        {"n": "Romulo's entrance", "starter": False,
         "items": [("npc:17533", at("karazhan", "Karazhan:OperaRomulo", 17533), None, "Romulo")]},
    ],
    "Karazhan:Aran": [
        {"n": "Blink spot", "starter": True, "items": [("npc:17176", at("karazhan", "Karazhan:Aran", 17176), None)]},
        {"n": "Water Elementals (40%)", "starter": False,
         "items": [("npc:17167", at("karazhan", "Karazhan:Aran", 17167), None, "Elemental")]},
        {"n": "Blizzard's path", "starter": False, "items": _aran_blizzard()},
    ],
    "Karazhan:Illhoof": [
        {"n": "Portals and the circle", "starter": True,
         "items": [("npc:17265", at("karazhan", "Karazhan:Illhoof", 17265), None, "Portal"),
                   ("obj:181273", "spawn", None)]},
    ],
    "Karazhan:Netherspite": _netherspite(),
    "Karazhan:Chess": [
        {"n": "Pieces on their start squares", "starter": False, "items": _chess()},
    ],
    "Karazhan:Prince": [
        {"n": "Infernal landing spots", "starter": False,
         "items": [("npc:17646", at("karazhan", "Karazhan:Prince", 17646), None, "Infernal")]},
    ],
    "Karazhan:Nightbane": [
        {"n": "Blackened Urn", "starter": True, "items": [("obj:194092", "spawn", None)]},
        {"n": "Landing and air spots", "starter": False,
         "items": [("npc:17225", at("karazhan", "Karazhan:Nightbane", 17225), None)]},
    ],
    # ---------------------------------------------------------------- Sunwell Plateau
    "SunwellPlateau:Kalecgos": [
        {"n": "Spectral realm (127 yd below)", "starter": False,
         "items": [("npc:24892", at("sunwell", "SunwellPlateau:Kalecgos", 24892), None),
                   ("npc:24891", at("sunwell", "SunwellPlateau:Kalecgos", 24891), None)]},
    ],
    "SunwellPlateau:Felmyst": [
        {"n": "Deep Breath lanes", "starter": False, "items": _felmyst_lanes()},
        {"n": "Hover and landing points", "starter": False,
         "items": [("npc:25038", at("sunwell", "SunwellPlateau:Felmyst", 25038, "air-phase", label("hover")), None,
                    "Hover"),
                   ("npc:25038", at("sunwell", "SunwellPlateau:Felmyst", 25038, "landing"), None, "Landing")]},
    ],
    "SunwellPlateau:Muru": [
        {"n": "Portals", "starter": True, "items": [("npc:25770", at("sunwell", "SunwellPlateau:Muru", 25770), None)]},
        {"n": "Add entrances", "starter": False,
         "items": [("npc:25798", at("sunwell", "SunwellPlateau:Muru", 25798), None, "Berserker"),
                   ("npc:25799", at("sunwell", "SunwellPlateau:Muru", 25799), None, "Fury Mage")]},
    ],
    "SunwellPlateau:Kiljaeden": [
        {"n": "Orbs of the Blue Flight", "starter": True, "l": "Orb",
         "items": [("obj:%d" % k, "spawn", None) for k in (187869, 188114, 188115, 188116)]},
    ],
}
