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
    "Karazhan:Illhoof": ("Kara10", (705, 255, 400), [("Terestian Illhoof", 710, 255), ("Kil'rek", 685, 285)]),
    "Karazhan:Aran": ("Kara11", (523, 680, 240), [("Shade of Aran", 523, 690)]),
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
    "MagtheridonsLair:Magtheridon": ("Magtheridon", (685, 740, 260), [
        ("Magtheridon", 685, 732), ("Hellfire Channeler", 650, 655), ("Hellfire Channeler", 727, 655),
        ("Hellfire Channeler", 612, 770), ("Hellfire Channeler", 755, 770), ("Hellfire Channeler", 686, 833)]),
    # Serpentshrine Cavern
    "SerpentshrineCavern:Hydross": ("Serpentshrine", (360, 840, 450), [("Hydross the Unstable", 363, 847)]),
    "SerpentshrineCavern:Lurker": ("Serpentshrine", (400, 580, 320), [("The Lurker Below", 402, 581)]),
    # the three Spellbinders channel on him until pulled (wowhead has no spots for them)
    "SerpentshrineCavern:Leotheras": ("Serpentshrine", (405, 255, 450), [
        ("Leotheras the Blind", 417, 255), ("Greyheart Spellbinder", 392, 236), ("Greyheart Spellbinder", 442, 236),
        ("Greyheart Spellbinder", 417, 292)]),
    "SerpentshrineCavern:Karathress": ("Serpentshrine", (495, 160, 500), [
        ("Fathom-Lord Karathress", 504, 176), ("Fathom-Guard Sharkkis", 480, 152),
        ("Fathom-Guard Tidalvess", 528, 152), ("Fathom-Guard Caribdis", 504, 210)]),
    "SerpentshrineCavern:Morogrim": ("Serpentshrine", (592, 255, 550), [("Morogrim Tidewalker", 596, 260)]),
    "SerpentshrineCavern:Vashj": ("Serpentshrine", (718, 585, 420), [("Lady Vashj", 722, 589)]),
    # Tempest Keep
    "TempestKeep:Alar": ("TheEye", (497, 575, 400), [("Al'ar", 497, 582)]),
    "TempestKeep:VoidReaver": ("TheEye", (262, 480, 380), [("Void Reaver", 257, 490)]),
    "TempestKeep:Solarian": ("TheEye", (733, 480, 330), [("High Astromancer Solarian", 733, 485)]),
    "TempestKeep:Kaelthas": ("TheEye", (497, 165, 360), [
        ("Kael'thas Sunstrider", 497, 140), ("Thaladred the Darkener", 455, 190), ("Lord Sanguinar", 540, 190),
        ("Grand Astromancer Capernian", 455, 240), ("Master Engineer Telonicus", 540, 240)]),
    # Hyjal Summit
    "HyjalSummit:Winterchill": ("Hyjal", (110, 650, 420), [("Rage Winterchill", 127, 633)]),
    "HyjalSummit:Anetheron": ("Hyjal", (110, 650, 420), [("Anetheron", 85, 681)]),
    "HyjalSummit:Kazrogal": ("Hyjal", (400, 360, 450), [("Kaz'rogal", 424, 358)]),
    "HyjalSummit:Azgalor": ("Hyjal", (400, 360, 450), [("Azgalor", 357, 378)]),
    "HyjalSummit:Archimonde": ("Hyjal", (780, 330, 420), [("Archimonde", 762, 277)]),
    # Black Temple
    "BlackTemple:Najentus": ("BT01", (360, 175, 450), [("High Warlord Naj'entus", 435, 190)]),
    "BlackTemple:Supremus": ("BT00", (470, 450, 145), [("Supremus", 660, 468)]),
    # Akama waits at the door; six Ashtongue Channelers hold the Shade until they die
    "BlackTemple:ShadeOfAkama": ("BT02", (405, 840, 360), [("Shade of Akama", 409, 889), ("Akama", 403, 725),
        ("Ashtongue Channeler", 409, 847), ("Ashtongue Channeler", 433, 868), ("Ashtongue Channeler", 433, 910), ("Ashtongue Channeler", 409, 931), ("Ashtongue Channeler", 385, 910), ("Ashtongue Channeler", 385, 868)]),
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


def main():
    check_spots()
    lines = [
        "-- DisasterZone: starter strategies for the strategy boards (Addendum K): a new strategy for a boss starts from its",
        "-- starter: the boss' floor map framed on the room and the encounter's creatures where they stand at the pull.",
        "-- Same shape as a strategy page (Core/Strategy.lua) with two conveniences resolved when loaded:",
        "--   page.map = a Data/RaidMaps.lua file name (instead of the map id m)",
        "--   \"@Creature Name\" as an icon key = that creature's portrait from Data/BossPortraits.lua",
        "-- AUTO-GENERATED by gen_starter_strategies.py (spots read off the floor maps); do not edit by hand.",
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
            bx, by = to_board(view, x, y)
            # on the board, with room for the icon (the save check allows 50 outside the edges)
            assert 20 <= bx <= BW - 20 and 20 <= by <= BH - 20, (ref, name, bx, by)
            lines.append("                  { t = \"i\", x = %d, y = %d, i = %s, z = %d, l = %s }," % (
                bx, by, lua_str("@" + name), BOSS_Z if i == 0 else ADD_Z, lua_str(name)))
        lines.append("              },")
        lines.append("              k = {} },")
        lines.append("        },")
        lines.append("    },")
    lines.append("}")
    open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("starters: %d" % len(STARTERS))


if __name__ == "__main__":
    main()
