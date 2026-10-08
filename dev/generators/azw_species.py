"""Azeromon world: a battle species for every creature that is fought on the real map.

Each creature entry (tbcdb creature_template) becomes one species: its real name, its own model (DisplayId1),
an element from its creature type / family / name, base stats from an archetype grown with its level (a level 30
creature is a stronger species than a level 3 one, like a later Pokemon form), moves from the archetype's pool, and
whether it can be tamed (the user's rule: beasts, critters and the non-player races - kobolds, murlocs, gnolls,
trolls, undead... - can; humans, orcs, dwarves, gnomes, elves cannot, they are fought directly).

Evolutions are real variants of the same family, hand-picked in CHAINS (into = the next form, at its real level)."""
import re

import tbcdb

# --- elements ---------------------------------------------------------------------------------------------------
FAMILY_TYPE = {1: "BEAST", 2: "BEAST", 3: "SHADOW", 4: "BEAST", 5: "BEAST", 6: "WATER", 7: "AIR", 8: "WATER",
               9: "BEAST", 11: "BEAST", 12: "BEAST", 20: "EARTH", 21: "WATER", 24: "AIR", 25: "BEAST", 26: "AIR",
               27: "AIR", 30: "FIRE", 31: "BEAST", 32: "SHADOW", 33: "SHADOW", 34: "BEAST", 35: "NATURE"}
NAME_TYPE = [  # (pattern, element) for humanoids and the rest, first match wins
    (r"kobold", "EARTH"), (r"murloc|saltscale|murkgill", "WATER"), (r"gnoll|riverpaw|redridge", "BEAST"),
    (r"troll|bloodscalp|skullsplitter|gurubashi|hakkari", "NATURE"), (r"ogre|splinter fist|mosh'ogg", "EARTH"),
    (r"worgen|nightbane", "SHADOW"), (r"frog|toad", "WATER"), (r"snake|moccasin", "NATURE"),
    (r"fire|flame|ember|lava|magma|scalding", "FIRE"), (r"water|tide|sea|swamp", "WATER"),
    (r"dust|wind|air|whirl", "AIR"), (r"rock|stone|obsidian|earth", "EARTH"),
    (r"golem|harvest|reaper|shredder|mechan", "MECH"), (r"mage|conjurer|wizard|mystic|witch|shaman|warlock", "SHADOW"),
]
TYPE_BY_CREATURE_TYPE = {2: "FIRE", 3: "SHADOW", 4: "EARTH", 6: "SHADOW", 9: "MECH", 10: "NATURE"}

# who can be tamed: humanoid races that are not player races
UNTAMEABLE = r"defias|human|guard|bandit|thug|cutpurse|pillager|smuggler|footpad|highwayman|blackrock|orc|" \
             r"dwarf|dark iron|gnome|venture co|kurzen|bloodsail|elf|paladin|knight|marshal|thief|rogue|" \
             r"poacher|brigand|watchman|messenger|rioter|scout|pirate|stonard|grom'gol|steamwheedle|garrick"


def element(t):
    name = (t["Name"] or "").lower()
    if t["CreatureType"] in (1, 8) and t["Family"] in FAMILY_TYPE:
        return FAMILY_TYPE[t["Family"]]
    for pat, el in NAME_TYPE:
        if re.search(pat, name):
            return el
    if t["CreatureType"] in TYPE_BY_CREATURE_TYPE:
        return TYPE_BY_CREATURE_TYPE[t["CreatureType"]]
    return "BEAST" if t["CreatureType"] in (1, 8) else "SHADOW"


def tameable(t):
    name = (t["Name"] or "").lower()
    if t["CreatureType"] == 7 and re.search(UNTAMEABLE, name):
        return False
    if t["CreatureType"] == 7 and not re.search(r"kobold|murloc|gnoll|riverpaw|troll|bloodscalp|skullsplitter|"
                                                 r"ogre|worgen|nightbane|saltscale|murkgill|mosh'ogg|splinter fist|"
                                                 r"redridge|gurubashi|hakkari|harpy|quilboar|centaur|kurzen war", name):
        return False                  # (other humanoids with a personal name: people)
    return True


# --- stats --------------------------------------------------------------------------------------------------------
# archetype -> base stat shape { hp, atk, def, spa, spd, spe } (sums to 1)
SHAPES = {
    "wolf":    (0.15, 0.21, 0.14, 0.11, 0.13, 0.26),
    "cat":     (0.14, 0.22, 0.13, 0.11, 0.12, 0.28),
    "bear":    (0.24, 0.22, 0.20, 0.08, 0.14, 0.12),
    "boar":    (0.21, 0.23, 0.21, 0.07, 0.13, 0.15),
    "spider":  (0.15, 0.19, 0.15, 0.14, 0.14, 0.23),
    "bird":    (0.15, 0.18, 0.13, 0.14, 0.14, 0.26),
    "kobold":  (0.18, 0.20, 0.21, 0.10, 0.15, 0.16),
    "murloc":  (0.17, 0.17, 0.17, 0.17, 0.16, 0.16),
    "caster":  (0.15, 0.10, 0.14, 0.25, 0.20, 0.16),
    "fighter": (0.18, 0.22, 0.18, 0.09, 0.14, 0.19),
    "critter": (0.20, 0.15, 0.15, 0.15, 0.15, 0.20),
    "golem":   (0.18, 0.21, 0.24, 0.08, 0.17, 0.12),
    "undead":  (0.17, 0.19, 0.17, 0.16, 0.16, 0.15),
    "crawler": (0.18, 0.18, 0.24, 0.12, 0.16, 0.12),
}
FAMILY_SHAPE = {1: "wolf", 2: "cat", 3: "spider", 4: "bear", 5: "boar", 6: "crawler", 7: "bird", 8: "crawler",
                9: "bear", 11: "cat", 12: "boar", 20: "crawler", 21: "crawler", 24: "bird", 25: "wolf", 26: "bird",
                27: "bird"}
# moves an archetype learns: (level, move id) - existing Azeromon moves
POOLS = {
    "wolf":    [(1, "tackle"), (1, "growl"), (4, "quickbite"), (8, "howl"), (11, "bite"), (16, "rend"), (26, "maul")],
    "cat":     [(1, "scratch"), (1, "growl"), (5, "quickbite"), (10, "rend"), (16, "bite"), (26, "maul")],
    "bear":    [(1, "tackle"), (1, "growl"), (6, "scratch"), (12, "maul"), (20, "howl"), (30, "rend")],
    "boar":    [(1, "tackle"), (1, "leer"), (6, "mudslap"), (10, "tuskgore"), (18, "rend")],
    "spider":  [(1, "venomsting"), (1, "web"), (7, "bite"), (14, "carrion")],
    "bird":    [(1, "peck"), (1, "squawk"), (6, "gust"), (14, "carrion"), (22, "whirlwind")],
    "kobold":  [(1, "scratch"), (1, "mudslap"), (4, "leer"), (7, "rockthrow"), (14, "sandblast")],
    "murloc":  [(1, "tackle"), (1, "leer"), (5, "waterjet"), (10, "bite"), (16, "bubblebeam"), (24, "tidal")],
    "caster":  [(1, "ember"), (1, "leer"), (6, "fireball"), (12, "hoot"), (20, "flamebuffet")],
    "fighter": [(1, "tackle"), (1, "leer"), (4, "cutlass"), (8, "sprint"), (14, "cleave")],
    "critter": [(1, "tackle"), (1, "growl"), (6, "quickbite")],
    "golem":   [(1, "gears"), (1, "rust"), (8, "scythe"), (16, "thrash")],
    "undead":  [(1, "scratch"), (1, "leer"), (6, "bite"), (12, "carrion"), (20, "cleave")],
    "crawler": [(1, "pincer"), (1, "shell"), (8, "waterjet"), (16, "tidal")],
}


def archetype(t):
    name = (t["Name"] or "").lower()
    if t["CreatureType"] == 8:
        return "critter"
    if t["CreatureType"] == 1:
        return FAMILY_SHAPE.get(t["Family"], "wolf")
    if t["CreatureType"] == 9:
        return "golem"
    if t["CreatureType"] == 6:
        return "undead"
    if "kobold" in name:
        return "kobold"
    if "murloc" in name or "saltscale" in name or "murkgill" in name:
        return "murloc"
    if t["UnitClass"] in (8, 2, 5) or re.search(r"mage|wizard|conjurer|mystic|shaman|witch|oracle|geomancer", name):
        return "caster"
    return "fighter"


def base_stats(t):
    lvl = t["MinLevel"] or 1
    total = 250 + 7 * min(lvl, 60)
    if t["Rank"] in (1, 2):           # elite / rare elite
        total *= 1.15
    elif t["Rank"] == 4:              # rare
        total *= 1.08
    elif t["Rank"] == 3:              # boss
        total *= 1.3
    if t["CreatureType"] == 8:
        total *= 0.8
    shape = SHAPES[archetype(t)]
    return [max(10, int(round(total * s))) for s in shape]


def slug(name):
    s = re.sub(r"[^a-z0-9]+", "_", (name or "").lower()).strip("_")
    return s


# Evolutions (into, at level) - real variants of the same family, by creature entry.
CHAINS = {
    299: (525, 5),       # Young Wolf -> Mangy Wolf
    69: (1922, 7),       # Timber Wolf -> Gray Forest Wolf
    525: (118, 9),       # Mangy Wolf -> Prowler
    1922: (118, 9),      # Gray Forest Wolf -> Prowler
    118: (213, 19),      # Prowler -> Starving Dire Wolf
    6: (257, 3),         # Kobold Vermin -> Kobold Worker
    257: (80, 4),        # Kobold Worker -> Kobold Laborer
    80: (40, 6),         # Kobold Laborer -> Kobold Miner
    40: (476, 8),        # Kobold Miner -> Kobold Geomancer
}


def species_for(entries):
    """entry -> species dict (keys as in Data.lua) for these creature entries and their evolution targets."""
    db = tbcdb.load()
    ct = db.index("creature_template", "Entry")
    want = set(entries)
    for e in list(want):
        k = e
        while k in CHAINS:
            k = CHAINS[k][0]
            want.add(k)
    out = {}
    used = {}
    for e in sorted(want):
        t = ct.get(e)
        if not t:
            continue
        key = slug(t["Name"])
        if key in used and used[key] != e:
            key = "%s_%d" % (key, e)
        used[key] = e
        arch = archetype(t)
        lvl = t["MinLevel"] or 1
        learn = [(l, m) for (l, m) in POOLS[arch]]
        catch = 0
        if tameable(t):
            catch = 255 if t["CreatureType"] == 8 else max(30, 200 - lvl * 4)
            if t["Rank"] in (1, 2, 4):
                catch = 45
            if t["Rank"] == 3:
                catch = 3
        out[e] = {"key": key, "entry": e, "name": t["Name"], "type": element(t), "display": t["DisplayId1"],
                  "base": base_stats(t), "learn": learn, "catch": catch, "exp": int(40 + 5 * lvl * (1.5 if t["Rank"] else 1)),
                  "lvl": (t["MinLevel"], t["MaxLevel"]), "rank": t["Rank"], "arch": arch,
                  "scale": t["Scale"] or 1}
    for e, sp in out.items():
        if e in CHAINS and CHAINS[e][0] in out:
            into, at = CHAINS[e]
            sp["evolve"] = (out[into]["key"], at)
    return out
