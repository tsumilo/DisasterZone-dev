"""Starter strategies for the strategy boards (Addendum K): one per encounter, just the boss' floor map framed on its
room and the encounter's creatures where they stand at the pull. "New strategy" starts from it.

Spots were read off Blizzard's floor maps (dev/art/blizzard_maps, the skull each map draws on its bosses) and are
given in map units: 0-1000 across the map's width and 0-1000 down its height. The view is the room's centre (same
units) and a zoom (100 = the whole map); creatures become board icons with the portrait of that name.
Each boss spot is checked against wowhead's spawn data (data/npc_spots.json, fetch_npc_spots.py) when it is there.
Writes addon/DisasterZone/Data/StarterStrategies.lua.

Run: luaenv\\Scripts\\python.exe generators\\gen_starter_strategies.py
"""
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "..", "..", "addon", "DisasterZone")
OUT = os.path.join(ADDON, "Data", "StarterStrategies.lua")
SPOTS = os.path.join(HERE, "data", "npc_spots.json")

# The board (Core/Strategy.lua BOARD_W/H) over a 1024 x 683 map layer (UI/StrategyMap.lua SHIPPED_LAYER).
BW, BH = 1000, 666
LW, LH = 1024, 683
BASE = min(BW / LW, BH / LH)

BOSS_Z, ADD_Z = 48, 40

# ref: (map file, (view x, view y, zoom), [(creature, x, y), ...]) - the first creature is the boss.
STARTERS = {
    # Karazhan
    "Karazhan:Attumen": ("Kara01", (447, 840, 330), [("Attumen the Huntsman", 472, 835), ("Midnight", 447, 840)]),
    # the three rares share one spawn point: one of them is up per reset
    "Karazhan:Rokad": ("Kara01", (560, 330, 200), [("Rokad the Ravager", 596, 287)]),
    "Karazhan:Shadikith": ("Kara01", (560, 330, 200), [("Shadikith the Glider", 596, 287)]),
    "Karazhan:Hyakiss": ("Kara01", (560, 330, 200), [("Hyakiss the Lurker", 596, 287)]),
    "Karazhan:Moroes": ("Kara03", (330, 640, 250), [("Moroes", 267, 630)]),
    "Karazhan:Maiden": ("Kara04", (827, 490, 380), [("Maiden of Virtue", 827, 490)]),
    "Karazhan:OperaOz": ("Kara04", (250, 340, 280), [("Dorothee", 177, 340), ("Strawman", 155, 305),
                                                     ("Tinhead", 200, 305), ("Roar", 177, 380)]),
    "Karazhan:OperaWolf": ("Kara04", (250, 340, 280), [("The Big Bad Wolf", 177, 340)]),
    "Karazhan:OperaRomulo": ("Kara04", (250, 340, 280), [("Julianne", 177, 330), ("Romulo", 177, 380)]),
    "Karazhan:Curator": ("Kara09", (455, 280, 290), [("The Curator", 490, 365)]),
    # (Aran's library is Kara10, the Repository with Illhoof Kara11: their spawns say so, 2026-10-04)
    "Karazhan:Aran": ("Kara10", (705, 255, 400), [("Shade of Aran", 710, 255)]),
    "Karazhan:Illhoof": ("Kara11", (523, 680, 240), [("Terestian Illhoof", 523, 690), ("Kil'rek", 498, 720)]),
    "Karazhan:Netherspite": ("Kara13", (370, 400, 190), [("Netherspite", 357, 410)]),
    "Karazhan:Chess": ("Kara14", (350, 600, 140), [("Echo of Medivh", 357, 610)]),
    "Karazhan:Prince": ("Kara17", (505, 340, 200), [("Prince Malchezaar", 510, 305)]),
    "Karazhan:Nightbane": ("Kara06", (510, 820, 320), [("Nightbane", 465, 905)]),
    # Gruul's Lair
    "GruulsLair:Maulgar": ("Gruul", (547, 600, 300), [("High King Maulgar", 548, 530), ("Blindeye the Seer", 521, 525),
                                                      ("Olm the Summoner", 569, 523), ("Krosh Firehand", 589, 532),
                                                      ("Kiggler the Crazed", 501, 543)]),
    "GruulsLair:Gruul": ("Gruul", (208, 300, 320), [("Gruul the Dragonkiller", 200, 280)]),
    # Magtheridon's Lair
    # (his five Hellfire Channelers come with their cage beams: encounter_assets.py)
    "MagtheridonsLair:Magtheridon": ("Magtheridon", (685, 740, 260), [("Magtheridon", 685, 732)]),
    # Serpentshrine Cavern
    "SerpentshrineCavern:Hydross": ("Serpentshrine", (360, 840, 450), [("Hydross the Unstable", 363, 847)]),
    "SerpentshrineCavern:Lurker": ("Serpentshrine", (400, 580, 320), [("The Lurker Below", 402, 581)]),
    # (the three Spellbinders channel on him until pulled: encounter_assets.py, from their spawns)
    "SerpentshrineCavern:Leotheras": ("Serpentshrine", (405, 255, 450), [("Leotheras the Blind", 417, 255)]),
    "SerpentshrineCavern:Karathress": ("Serpentshrine", (495, 160, 500), [
        ("Fathom-Lord Karathress", 504, 176), ("Fathom-Guard Sharkkis", 480, 152),
        ("Fathom-Guard Tidalvess", 528, 152), ("Fathom-Guard Caribdis", 504, 210)]),
    "SerpentshrineCavern:Morogrim": ("Serpentshrine", (592, 255, 550), [("Morogrim Tidewalker", 596, 260)]),
    "SerpentshrineCavern:Vashj": ("Serpentshrine", (718, 585, 420), [("Lady Vashj", 722, 589)]),
    # Tempest Keep
    "TempestKeep:Alar": ("TheEye", (497, 575, 400), [("Al'ar", 497, 582)]),
    "TempestKeep:VoidReaver": ("TheEye", (262, 480, 380), [("Void Reaver", 257, 490)]),
    "TempestKeep:Solarian": ("TheEye", (733, 480, 330), [("High Astromancer Solarian", 733, 485)]),
    # (his four advisors come with their states: encounter_assets.py)
    "TempestKeep:Kaelthas": ("TheEye", (497, 165, 360), [("Kael'thas Sunstrider", 497, 140)]),
    # Hyjal Summit
    "HyjalSummit:Winterchill": ("Hyjal", (110, 650, 420), [("Rage Winterchill", 127, 633)]),
    "HyjalSummit:Anetheron": ("Hyjal", (110, 650, 420), [("Anetheron", 85, 681)]),
    "HyjalSummit:Kazrogal": ("Hyjal", (400, 360, 450), [("Kaz'rogal", 424, 358)]),
    "HyjalSummit:Azgalor": ("Hyjal", (400, 360, 450), [("Azgalor", 357, 378)]),
    "HyjalSummit:Archimonde": ("Hyjal", (780, 330, 420), [("Archimonde", 762, 277)]),
    # Black Temple
    "BlackTemple:Najentus": ("BT01", (360, 175, 450), [("High Warlord Naj'entus", 435, 190)]),
    "BlackTemple:Supremus": ("BT00", (470, 450, 145), [("Supremus", 660, 468)]),
    # (Akama and the six Ashtongue Channelers that hold the Shade come with their beams: encounter_assets.py)
    "BlackTemple:ShadeOfAkama": ("BT02", (405, 840, 360), [("Shade of Akama", 409, 889)]),
    "BlackTemple:Teron": ("BT04", (390, 220, 280), [("Teron Gorefiend", 390, 115)]),
    "BlackTemple:Bloodboil": ("BT03", (545, 340, 240), [("Gurtogg Bloodboil", 533, 465)]),
    "BlackTemple:Reliquary": ("BT03", (635, 860, 440), [("Essence of Suffering", 612, 840)]),
    "BlackTemple:Shahraz": ("BT05", (680, 375, 450), [("Mother Shahraz", 665, 365)]),
    "BlackTemple:Council": ("BT06", (471, 505, 360), [
        ("Gathios the Shatterer", 461, 429), ("High Nethermancer Zerevor", 443, 429),
        ("Lady Malande", 479, 429), ("Veras Darkshadow", 497, 429)]),
    "BlackTemple:Illidan": ("BT07", (525, 520, 120), [("Illidan Stormrage", 523, 695)]),
    # Zul'Aman
    "ZulAman:Akilzon": ("ZulAman", (345, 215, 450), [("Akil'zon", 348, 215)]),
    "ZulAman:Nalorakk": ("ZulAman", (400, 765, 450), [("Nalorakk", 405, 773)]),
    "ZulAman:Janalai": ("ZulAman", (550, 715, 500), [("Jan'alai", 554, 709)]),
    "ZulAman:Halazzi": ("ZulAman", (585, 230, 450), [("Halazzi", 578, 230)]),
    "ZulAman:Malacrass": ("ZulAman", (705, 525, 550), [("Hex Lord Malacrass", 708, 525)]),
    "ZulAman:Zuljin": ("ZulAman", (900, 525, 450), [("Zul'jin", 897, 525)]),
    # Sunwell Plateau
    "SunwellPlateau:Kalecgos": ("Sunwell0", (303, 505, 400), [("Kalecgos", 303, 503)]),
    "SunwellPlateau:Brutallus": ("Sunwell0", (655, 845, 330), [("Brutallus", 658, 864)]),
    "SunwellPlateau:Felmyst": ("Sunwell0", (680, 830, 300), [("Felmyst", 727, 826)]),
    "SunwellPlateau:EredarTwins": ("Sunwell0", (640, 320, 500), [("Lady Sacrolash", 626, 321),
                                                                 ("Grand Warlock Alythess", 656, 321)]),
    "SunwellPlateau:Muru": ("Sunwell", (465, 215, 450), [("M'uru", 467, 238)]),
    # the Hands of the Deceiver channel Kil'jaeden's arrival at the start
    "SunwellPlateau:Kiljaeden": ("Sunwell", (455, 615, 280), [
        ("Kil'jaeden", 460, 616), ("Hand of the Deceiver", 420, 575), ("Hand of the Deceiver", 500, 575),
        ("Hand of the Deceiver", 460, 680)]),
}

# Every encounter's assets in groups (encounter_assets.py: the curated list, positions from the spawn tables and the
# research files of the boss scripts).
from encounter_assets import ASSETS  # noqa: E402
ASSET_REACH = 80
ASSET_Z = {"obj": 32, "npc": 40, "boss": 40}
PLACED = {}                      # ref -> [(group, [placed item])], by from_spawns(): an icon (key, mx, my, face, state),
                                 # an arrow ("arrow", mx, my, mx2, my2, colour)


_GOS = None
_NPCS = None


def npc_spawns():
    """NPC ID -> [(map, x, y, z, orientation)] from AzerothCore's creature table (dev/art/rooms cache)."""
    global _NPCS
    if _NPCS is None:
        import re
        import gen_rooms as R
        path = R._get("https://raw.githubusercontent.com/azerothcore/azerothcore-wotlk/master/data/sql/base/db_world/"
                      "creature.sql", os.path.join(R.CACHE, "creature.sql"))
        _NPCS = {}
        # (guid, id1, id2, id3, map, zoneId, areaId, spawnMask, phaseMask, equipment_id, x, y, z, orientation, ...)
        for m in re.finditer(r"\(\d+,(\d+),\d+,\d+,(\d+),\d+,\d+,\d+,\d+,-?\d+,(-?[\d.]+),(-?[\d.]+),(-?[\d.]+),"
                             r"(-?[\d.]+),", open(path, encoding="utf-8", errors="replace").read()):
            _NPCS.setdefault(int(m.group(1)), []).append(
                (int(m.group(2)), float(m.group(3)), float(m.group(4)), float(m.group(5)), float(m.group(6))))
    return _NPCS


def go_spawns():
    """object entry -> [(map, x, y, z, orientation)] from AzerothCore's gameobject table (dev/art/rooms cache)."""
    global _GOS
    if _GOS is None:
        import re
        import gen_rooms as R
        path = R._get("https://raw.githubusercontent.com/azerothcore/azerothcore-wotlk/master/data/sql/base/db_world/"
                      "gameobject.sql", os.path.join(R.CACHE, "gameobject.sql"))
        _GOS = {}
        # (guid, id, map, zoneId, areaId, spawnMask, phaseMask, x, y, z, orientation, ...)
        for m in re.finditer(r"\(\d+,(\d+),(\d+),\d+,\d+,\d+,\d+,(-?[\d.]+),(-?[\d.]+),(-?[\d.]+),(-?[\d.]+),",
                             open(path, encoding="utf-8", errors="replace").read()):
            _GOS.setdefault(int(m.group(1)), []).append(
                (int(m.group(2)), float(m.group(3)), float(m.group(4)), float(m.group(5)), float(m.group(6))))
    return _GOS


def to_board(view, x, y):
    """Map units -> board coordinates under the page's view (the board's own math, UI/StrategyMap.lua)."""
    vx, vy, vz = view
    sc = BASE * vz / 100
    bx = BW / 2 + (x - vx) / 1000 * LW * sc
    by = BH / 2 + (y - vy) / 1000 * LH * sc
    return int(round(bx)), int(round(by))


def lua_str(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def check_spots():
    """Warns about a boss placed away from where wowhead has it spawn (on the same floor)."""
    if not os.path.exists(SPOTS):
        return
    sys_path = __import__("sys").path
    sys_path.insert(0, HERE)
    from gen_raid_maps import MAPS
    floors = {m[1]: m[0].partition("-") for m in MAPS}
    spots = json.load(open(SPOTS, encoding="utf-8"))
    for ref, (mapfile, view, creatures) in sorted(STARTERS.items()):
        zone, _, floor = floors[mapfile]
        name, x, y = creatures[0]
        for v in spots.values():
            if v["name"] != name or str(v["zone"]) != zone:
                continue
            pts = v["spots"].get(floor) or v["spots"].get("0") or []
            if pts:
                d = min(math.hypot(px * 10 - x, (py * 10 - y) * LH / LW) for px, py in pts)
                if d > 30:
                    print("  %s: %s is %.0f map units from wowhead's spawn %s" % (ref, name, d, pts[:2]))


def from_spawns():
    """Every creature the server spawns where the starter puts it (AzerothCore creature.sql, the spawn of that creature
    nearest the hand-read spot, within 80 yd), through the floor map's world rectangle (gen_rooms.py: retail
    UiMapAssignment, checked against the geometry): the hand-read skulls were up to 45 yd off. A view that no longer
    shows its boss moves onto it."""
    import gen_rooms as R
    # creatures whose spawn is not where they are fought: Nightbane circles the tower until the urn calls him down
    # onto the Master's Terrace (his spawn is in the air outside the walls)
    keep = {"Nightbane"}
    _, portraits, _ = R.addon_data()
    sp = R.spawns()
    for ref in sorted(STARTERS):
        mapfile, view, creatures = STARTERS[ref]
        mapid = R.RAIDS[ref.split(":")[0]][0]
        x0, y0, _, x1, y1, _ = R.uimap_rect(R.UIMAP[mapfile])
        ids = {c["n"]: c["id"] for c in portraits.get(ref, [])}
        used, out = set(), []
        boss = None                                  # the boss' spawn and how far its spot moved (map units)
        for i, (name, mx, my) in enumerate(creatures):
            wx, wy = x1 - (x1 - x0) * my / 1000.0, y1 - (y1 - y0) * mx / 1000.0
            cands = [s for s in sp.get(ids.get(name), []) if s[0] == mapid and (s[1], s[2]) not in used
                     and name not in keep]
            if i > 0 and boss:
                # an add: one of its kind standing with the boss (another pack's is not it)
                cands = [s for s in cands if math.hypot(s[1] - boss[0][1], s[2] - boss[0][2]) < 35]
            best = min(cands, key=lambda s: math.hypot(s[1] - wx, s[2] - wy)) if cands else None
            # (a boss with one spawn on the map is that spawn wherever the skull was drawn: retail maps show some
            # bosses where Cataclysm's remakes put them - Zul'Aman's Nalorakk 127 yd away)
            unique = i == 0 and len(cands) == 1
            if best and (unique or math.hypot(best[1] - wx, best[2] - wy) < 80):
                used.add((best[1], best[2]))
                nx, ny = (y1 - best[2]) / (y1 - y0) * 1000, (x1 - best[1]) / (x1 - x0) * 1000
                moved = math.hypot(best[1] - wx, best[2] - wy)
                if moved > 3:
                    print("  %-30s %-28s moved %5.1f yd to its spawn" % (ref, name, moved))
                if i == 0:
                    boss = (best, nx - mx, ny - my)
                out.append((name, nx, ny))
            elif i > 0 and boss:
                out.append((name, mx + boss[1], my + boss[2]))       # (where it stood from the boss)
            else:
                out.append((name, mx, my))
        if ref in ASSETS:
            # (the spawns that count: round the boss' spawn, else round the middle of the starter's view)
            if boss:
                bwx, bwy = boss[0][1], boss[0][2]
            else:
                bwx, bwy = x1 - (x1 - x0) * view[1] / 1000.0, y1 - (y1 - y0) * view[0] / 1000.0
            def to_map(wx, wy):
                return (y1 - wy) / (y1 - y0) * 1000, (x1 - wx) / (x1 - x0) * 1000

            groups = []
            for grp in ASSETS[ref]:
                placed = []
                for item in grp["items"]:
                    if item[0] == "arrow":
                        _, (ax, ay), (bx2, by2), colour = item
                        placed.append(("arrow",) + to_map(ax, ay) + to_map(bx2, by2) + (colour,))
                        continue
                    if item[0] in ("zone", "rect"):
                        # a circle (centre, radius yd) or a rectangle (two corners): its middle and half sizes in map
                        # units across and down (a yard is (y1 - y0) / 1000 map units across, (x1 - x0) / 1000 down)
                        if item[0] == "zone":
                            _, (cx, cy), r, colour, label = item
                            mx, my = to_map(cx, cy)
                            hx, hy = r / (y1 - y0) * 1000, r / (x1 - x0) * 1000
                        else:
                            _, (ax, ay), (bx2, by2), colour, label = item
                            (ma, na), (mb, nb) = to_map(ax, ay), to_map(bx2, by2)
                            mx, my, hx, hy = (ma + mb) / 2, (na + nb) / 2, abs(mb - ma) / 2, abs(nb - na) / 2
                        placed.append(("zone", "c" if item[0] == "zone" else "r", mx, my, hx, hy, colour, label))
                        continue
                    key, where, st = item[:3]
                    label = item[3] if len(item) > 3 else None
                    kind, ident = key.split(":")
                    if where == "spawn":
                        table = go_spawns() if kind == "obj" else npc_spawns()
                        assert kind in ("obj", "npc"), (ref, key, "a spawn needs an object entry or an NPC ID")
                        found = [s[1:] for s in table.get(int(ident), []) if s[0] == mapid
                                 and math.hypot(s[1] - bwx, s[2] - bwy) <= ASSET_REACH]
                        assert found, (ref, key, "no spawn near the boss")
                    else:
                        found = where
                    for wx, wy, _, o in found:
                        # (orientation: radians from north (+x) towards west (+y); the board's facing: degrees from
                        # east towards north; none given: east)
                        face = int(round(math.degrees(o) + 90)) % 360 if o is not None else 0
                        placed.append((key,) + to_map(wx, wy) + (face, st, label))
                groups.append((grp, placed))
            PLACED[ref] = groups
        vx, vy, vz = view
        bx, by = to_board(view, out[0][1], out[0][2])
        if not (100 <= bx <= BW - 100 and 80 <= by <= BH - 80):
            view = (int(round(min(1000, max(0, out[0][1])))), int(round(min(1000, max(0, out[0][2])))), vz)
            print("  %-30s view moved onto the boss" % ref)
        STARTERS[ref] = (mapfile, view, out)


def main():
    from_spawns()
    check_spots()
    lines = [
        "-- DisasterZone: starter strategies for the strategy boards (Addendum K): a new strategy for a boss starts from its",
        "-- starter: the boss' floor map framed on the room and the encounter's creatures where they stand at the pull.",
        "-- Same shape as a strategy page (Core/Strategy.lua) with two conveniences resolved when loaded:",
        "--   page.map = a Data/RaidMaps.lua file name (instead of the map id m)",
        "--   \"@Creature Name\" as an icon key = that creature's portrait from Data/BossPortraits.lua",
        "-- \"obj:<entry>\" / \"npc:<id>\" icons: the encounter's assets where its script puts them (Data/EncounterObjects.lua).",
        "-- AUTO-GENERATED by gen_starter_strategies.py (the server's spawns where it has them, else spots read off the",
        "-- floor maps); do not edit by hand.",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "",
        "ns.Data.StarterStrategies = {",
    ]
    for ref in sorted(STARTERS):
        mapfile, view, creatures = STARTERS[ref]
        vx, vy, vz = view
        assert 0 <= vx <= 1000 and 0 <= vy <= 1000 and 100 <= vz <= 1000, ref
        lines.append("    [%s] = {" % lua_str(ref))
        lines.append("        p = {")
        lines.append('            { id = "p1", n = "P1", map = %s, vx = %d, vy = %d, vz = %d,' % (lua_str(mapfile), vx, vy, vz))
        lines.append("              e = {")
        for i, (name, x, y) in enumerate(creatures):
            bx, by = to_board(view, x, y)          # (map units may be fractions now: from the spawns)
            # on the board, with room for the icon (the save check allows 50 outside the edges)
            assert 20 <= bx <= BW - 20 and 20 <= by <= BH - 20, (ref, name, bx, by)
            lines.append("                  { t = \"i\", x = %d, y = %d, i = %s, z = %d, l = %s }," % (
                bx, by, lua_str("@" + name), BOSS_Z if i == 0 else ADD_Z, lua_str(name)))
        for grp, placed in PLACED.get(ref, []):
            if not grp["starter"]:
                continue
            for it in placed:
                if it[0] == "arrow":
                    _, ax, ay, bx2, by2, colour = it
                    (x1b, y1b), (x2b, y2b) = to_board(view, ax, ay), to_board(view, bx2, by2)
                    if all(-50 <= v <= (BW if k % 2 == 0 else BH) + 50 for k, v in enumerate((x1b, y1b, x2b, y2b))):
                        lines.append("                  { t = \"a\", x = %d, y = %d, x2 = %d, y2 = %d, h = true, c = %d },"
                                     % (x1b, y1b, x2b, y2b, colour))
                    else:
                        print("  %-30s %s: an arrow off the starter's page, left to the menu" % (ref, grp["n"]))
                    continue
                if it[0] == "zone":
                    _, shape, mx, my, hx, hy, colour, label = it
                    zx, zy = to_board(view, mx, my)
                    sc = BASE * view[2] / 100
                    w = min(BW, max(4, int(round(2 * hx / 1000 * LW * sc))))
                    h = min(BW, max(4, int(round(2 * hy / 1000 * LH * sc))))
                    lines.append("                  { t = \"z\", s = \"%s\", x = %d, y = %d, w = %d, h = %d, c = %d%s }," % (
                        shape, zx, zy, w, h, colour, (", l = %s" % lua_str(label)) if label else ""))
                    continue
                key, x, y, face, st, label = it
                bx, by = to_board(view, x, y)
                if not (20 <= bx <= BW - 20 and 20 <= by <= BH - 20):
                    print("  %-30s %s: %s off the starter's page (%d, %d), left to the menu" % (ref, grp["n"], key, bx, by))
                    continue
                label = label or grp.get("l")
                extra = (", l = %s" % lua_str(label) if label else "") + (", st = %d" % st if st else "")
                lines.append("                  { t = \"i\", x = %d, y = %d, i = %s, z = %d, f = %d%s }," % (
                    bx, by, lua_str(key), ASSET_Z[key.split(":")[0]], face, extra))
        lines.append("              },")
        lines.append("              k = {} },")
        lines.append("        },")
        lines.append("    },")
    lines.append("}")
    open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("starters: %d" % len(STARTERS))
    write_spawns()


def write_spawns():
    """Data/EncounterSpawns.lua: every encounter's asset groups in map units of its starter's floor map."""
    lines = [
        "-- DisasterZone: where each encounter's script puts its assets (Data/EncounterObjects.lua), in groups, for the",
        "-- strategy boards' icon menu (\"<group> at their spots\") and the starters. Per boss: map = the floor map file the",
        "-- spots are on; groups = { { n = name, l = the icons' label, e = { { i = icon key, mx, my = map units (0-1000",
        "-- across / down the map), f = facing (degrees from east), st = state, l = label } or { a = true (an arrow),",
        "-- mx, my, mx2, my2, c = colour } or { z = \"c\" / \"r\" (a circle / rectangle zone), mx, my, hx, hy = half",
        "-- sizes in map units, c, l }, ... } } }.",
        "-- AUTO-GENERATED by gen_starter_strategies.py from AzerothCore's spawn tables and boss scripts; do not edit by hand.",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "",
        "ns.Data.EncounterSpawns = {",
    ]
    for ref in sorted(PLACED):
        mapfile = STARTERS[ref][0]
        lines.append("    [%s] = { map = %s, groups = {" % (lua_str(ref), lua_str(mapfile)))
        for grp, placed in PLACED[ref]:
            lines.append("        { n = %s%s, e = {" % (lua_str(grp["n"]), (", l = %s" % lua_str(grp["l"])) if grp.get("l") else ""))
            for it in placed:
                if it[0] == "arrow":
                    _, ax, ay, bx2, by2, colour = it
                    lines.append("            { a = true, mx = %.1f, my = %.1f, mx2 = %.1f, my2 = %.1f, c = %d }," % (
                        ax, ay, bx2, by2, colour))
                    continue
                if it[0] == "zone":
                    _, shape, mx, my, hx, hy, colour, label = it
                    lines.append("            { z = \"%s\", mx = %.1f, my = %.1f, hx = %.1f, hy = %.1f, c = %d%s }," % (
                        shape, mx, my, hx, hy, colour, (", l = %s" % lua_str(label)) if label else ""))
                    continue
                key, x, y, face, st, label = it
                lines.append("            { i = %s, mx = %.1f, my = %.1f, f = %d%s%s }," % (
                    lua_str(key), x, y, face, (", st = %d" % st) if st else "",
                    (", l = %s" % lua_str(label)) if label else ""))
            lines.append("        } },")
        lines.append("    } },")
    lines.append("}")
    out = os.path.join(ADDON, "Data", "EncounterSpawns.lua")
    open(out, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("spawns: %d encounters, %d groups" % (len(PLACED), sum(len(g) for g in PLACED.values())))


if __name__ == "__main__":
    main()
