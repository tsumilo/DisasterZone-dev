"""Boss portraits for the strategy boards (Addendum K): the creatures of every TBC raid encounter, with their names and
creature display IDs, so a strategy can show the boss AND its adds (Attumen + Midnight, Moroes' guests, Kael'thas'
advisors, ...).

Sources:
  ROSTER below         - which creatures belong to each encounter (by English name; hand-written)
  Questie tbcNpcDB.lua - name -> creature (npc) ID, picking the one in the raid's zone (local file)
  wowhead.com/tbc      - npc ID -> display ID (the "model" of the npc page); cached in data/boss_creatures.json so a
                         re-run works offline. Delete the cache entry to refetch.
Writes addon/DisasterZone/Data/BossPortraits.lua:
  ns.Data.BossPortraits["<Raid>:<Boss>"] = { { d = displayID, n = "Name", id = npcID }, ... } (boss first).
Run: luaenv\\Scripts\\python.exe generators\\gen_boss_portraits.py
"""
import json
import os
import re
import time
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "..", "..", "addon", "DisasterZone")
ADDONS = r"C:\World of Warcraft\_anniversary_\Interface\AddOns"
QUESTIE = os.path.join(ADDONS, "Questie", "Database", "TBC", "tbcNpcDB.lua")
CACHE = os.path.join(HERE, "data", "boss_creatures.json")
OUT = os.path.join(ADDON, "Data", "BossPortraits.lua")

# Raid key -> zone (area) ID as Questie stores spawns.
ZONES = {
    "Karazhan": 3457, "GruulsLair": 3923, "MagtheridonsLair": 3836, "SerpentshrineCavern": 3607,
    "TempestKeep": 3845, "HyjalSummit": 3606, "BlackTemple": 3959, "ZulAman": 3805, "SunwellPlateau": 4075,
}

ROSTER = {
    "Karazhan:Attumen": ["Attumen the Huntsman", "Midnight"],
    "Karazhan:Rokad": ["Rokad the Ravager"],
    "Karazhan:Shadikith": ["Shadikith the Glider"],
    "Karazhan:Hyakiss": ["Hyakiss the Lurker"],
    "Karazhan:Moroes": ["Moroes", "Baroness Dorothea Millstipe", "Lady Catriona Von'Indi", "Lady Keira Berrybuck",
                        "Baron Rafe Dreuger", "Lord Robin Daris", "Lord Crispin Ference"],
    "Karazhan:Maiden": ["Maiden of Virtue"],
    "Karazhan:OperaOz": ["Dorothee", "Tito", "Strawman", "Tinhead", "Roar", "The Crone"],
    "Karazhan:OperaWolf": ["The Big Bad Wolf"],
    "Karazhan:OperaRomulo": ["Romulo", "Julianne"],
    "Karazhan:Curator": ["The Curator", "Astral Flare"],
    "Karazhan:Illhoof": ["Terestian Illhoof", "Kil'rek", "Demon Chains"],
    "Karazhan:Aran": ["Shade of Aran", "Conjured Elemental"],
    "Karazhan:Netherspite": ["Netherspite"],
    "Karazhan:Chess": ["Echo of Medivh"],
    "Karazhan:Prince": ["Prince Malchezaar", "Netherspite Infernal"],
    "Karazhan:Nightbane": ["Nightbane", "Restless Skeleton"],
    "GruulsLair:Maulgar": ["High King Maulgar", "Kiggler the Crazed", "Blindeye the Seer", "Olm the Summoner",
                           "Krosh Firehand"],
    "GruulsLair:Gruul": ["Gruul the Dragonkiller"],
    "MagtheridonsLair:Magtheridon": ["Magtheridon", "Hellfire Channeler"],
    "WorldBosses:Doomwalker": ["Doomwalker"],
    "WorldBosses:Kazzak": ["Doom Lord Kazzak"],
    "SerpentshrineCavern:Hydross": ["Hydross the Unstable", "Pure Spawn of Hydross", "Tainted Spawn of Hydross"],
    "SerpentshrineCavern:Lurker": ["The Lurker Below", "Coilfang Guardian", "Coilfang Ambusher"],
    "SerpentshrineCavern:Leotheras": ["Leotheras the Blind", "Shadow of Leotheras", "Greyheart Spellbinder"],
    "SerpentshrineCavern:Karathress": ["Fathom-Lord Karathress", "Fathom-Guard Sharkkis", "Fathom-Guard Tidalvess",
                                       "Fathom-Guard Caribdis"],
    "SerpentshrineCavern:Morogrim": ["Morogrim Tidewalker", "Tidewalker Lurker"],
    "SerpentshrineCavern:Vashj": ["Lady Vashj", "Coilfang Elite", "Coilfang Strider", "Tainted Elemental",
                                  "Enchanted Elemental"],
    "TempestKeep:Alar": ["Al'ar", "Ember of Al'ar"],
    "TempestKeep:VoidReaver": ["Void Reaver"],
    "TempestKeep:Solarian": ["High Astromancer Solarian", "Solarium Agent", "Solarium Priest"],
    "TempestKeep:Kaelthas": ["Kael'thas Sunstrider", "Thaladred the Darkener", "Lord Sanguinar",
                             "Grand Astromancer Capernian", "Master Engineer Telonicus", "Phoenix"],
    "HyjalSummit:Winterchill": ["Rage Winterchill"],
    "HyjalSummit:Anetheron": ["Anetheron", "Towering Infernal"],
    "HyjalSummit:Kazrogal": ["Kaz'rogal"],
    "HyjalSummit:Azgalor": ["Azgalor", "Lesser Doomguard"],
    "HyjalSummit:Archimonde": ["Archimonde", "Doomfire"],
    "BlackTemple:Najentus": ["High Warlord Naj'entus"],
    "BlackTemple:Supremus": ["Supremus"],
    "BlackTemple:ShadeOfAkama": ["Shade of Akama", "Akama", "Ashtongue Channeler", "Ashtongue Sorcerer",
                                 "Ashtongue Defender"],
    "BlackTemple:Bloodboil": ["Gurtogg Bloodboil"],
    "BlackTemple:Reliquary": ["Essence of Suffering", "Essence of Desire", "Essence of Anger"],
    "BlackTemple:Teron": ["Teron Gorefiend", "Shadowy Construct"],
    "BlackTemple:Shahraz": ["Mother Shahraz"],
    "BlackTemple:Council": ["Gathios the Shatterer", "High Nethermancer Zerevor", "Lady Malande",
                            "Veras Darkshadow"],
    "BlackTemple:Illidan": ["Illidan Stormrage", "Flame of Azzinoth", "Maiev Shadowsong", "Shadow Demon",
                            "Parasitic Shadowfiend"],
    "ZulAman:Akilzon": ["Akil'zon", "Soaring Eagle"],
    "ZulAman:Nalorakk": ["Nalorakk"],
    "ZulAman:Janalai": ["Jan'alai", "Amani'shi Hatcher", "Amani Dragonhawk Hatchling"],
    "ZulAman:Halazzi": ["Halazzi", "Spirit of the Lynx", "Corrupted Lightning Totem"],
    "ZulAman:Malacrass": ["Hex Lord Malacrass", "Alyson Antille", "Thurg", "Slither", "Lord Raadan", "Gazakroth",
                          "Fenstalker", "Darkheart", "Koragg"],
    "ZulAman:Zuljin": ["Zul'jin"],
    "SunwellPlateau:Kalecgos": ["Kalecgos", "Sathrovarr the Corruptor"],
    "SunwellPlateau:Brutallus": ["Brutallus", "Madrigosa"],
    "SunwellPlateau:Felmyst": ["Felmyst"],
    "SunwellPlateau:EredarTwins": ["Lady Sacrolash", "Grand Warlock Alythess"],
    "SunwellPlateau:Muru": ["M'uru", "Entropius", "Shadowsword Berserker", "Shadowsword Fury Mage", "Void Sentinel"],
    "SunwellPlateau:Kiljaeden": ["Kil'jaeden", "Hand of the Deceiver", "Sinister Reflection"],
}


def load_questie():
    """name -> [(npcID, zones spawned in, rank)]"""
    out = {}
    pat = re.compile(r"^\[(\d+)\] = \{'((?:[^'\\]|\\.)*)',[^,]*,[^,]*,[^,]*,[^,]*,([^,]*),(.*)$")
    for line in open(QUESTIE, encoding="utf-8"):
        m = pat.match(line)
        if not m:
            continue
        npc, name, rank, rest = int(m.group(1)), m.group(2).replace("\\'", "'"), m.group(3), m.group(4)
        zones = set(int(z) for z in re.findall(r"\[(\d+)\]=", rest))
        zm = re.match(r"(?:nil|\{.*?\}\}?),(?:nil|\{.*?\}\}?),(\d+)", rest)
        out.setdefault(name, []).append((npc, zones, int(rank) if rank.strip().isdigit() else 0))
    return out


def pick(cands, zone):
    # the highest rank first (a boss over its 1-hp script helper of the same name), then one spawned in the raid,
    # then the lowest id (the original creature, not a later event copy)
    pool = sorted(cands, key=lambda c: (-c[2], not (zone and zone in c[1]), c[0]))
    return pool[0][0]


def model_of(npc, cache):
    key = str(npc)
    if key in cache:
        return cache[key]
    # curl, not urllib: wowhead refuses Python's TLS client
    html = subprocess.run(["curl", "-sL", "-A", "Mozilla/5.0", "https://www.wowhead.com/tbc/npc=%d" % npc],
                          capture_output=True, timeout=60).stdout.decode("utf-8", "replace")
    # the page's own model viewer ("displayId = N"); the first "model" on a page can be a related creature's
    m = re.search(r'displayId = (\d+)', html) or re.search(r'"model":(\d+)', html)
    if not m and "<title>" not in html:
        raise SystemExit("wowhead refused npc %d (rate limit?); re-run later, the cache keeps what was fetched" % npc)
    cache[key] = int(m.group(1)) if m else None
    time.sleep(1.5)
    return cache[key]


def main():
    q = load_questie()
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    cache = json.load(open(CACHE)) if os.path.exists(CACHE) else {}
    lines = [
        "-- DisasterZone: boss portraits for the strategy boards: the creatures of each encounter (boss first, then its adds)",
        "-- with their creature display IDs. AUTO-GENERATED by gen_boss_portraits.py (names -> ids from Questie's",
        "-- database, display ids from wowhead); do not edit by hand.",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "ns.Data.BossPortraits = {",
    ]
    missing = []
    for ref, names in ROSTER.items():
        zone = ZONES.get(ref.split(":")[0])
        entries = []
        for name in names:
            cands = q.get(name)
            if not cands:
                missing.append("%s: '%s' not in Questie" % (ref, name))
                continue
            npc = pick(cands, zone)
            d = model_of(npc, cache)
            if not d:
                missing.append("%s: '%s' (%d) has no model" % (ref, name, npc))
                continue
            entries.append('{ d = %d, n = "%s", id = %d }' % (d, name.replace('"', '\\"'), npc))
        json.dump(cache, open(CACHE, "w"), indent=0, sort_keys=True)
        if entries:
            lines.append('  ["%s"] = { %s },' % (ref, ", ".join(entries)))
    lines.append("}")
    open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("encounters: %d" % len(ROSTER))
    # the same display id in two encounters is suspicious (a wrong model), unless it's the same creature name
    seen = {}
    for line in lines:
        for d, n in re.findall(r'd = (\d+), n = "([^"]+)"', line):
            if d in seen and seen[d] != n:
                print("SAME DISPLAY ID", d, seen[d], "/", n)
            seen.setdefault(d, n)
    for m in missing:
        print("MISSING", m)


if __name__ == "__main__":
    main()
