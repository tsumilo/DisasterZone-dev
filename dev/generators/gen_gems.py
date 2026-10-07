"""Generates DisasterZone Data/Gems.lua: the sockets of every TBC item, every gem and enchant, the meta gems' rules
and the suggested gems / enchants per class guide and phase (My BiS gems and enchants, Core/Gems.lua).

Sources:
  - WoWSims TBC's item database (github.com/wowsims/tbc-new, assets/database/db.json): items' gemSockets and
    socketBonus, gems (colour, stats, phase, quality, Jewelcrafting-only), enchants (effectId = the number item links
    carry, spellId, the item that applies it, item type / enchantType, stats, required profession).
  - Wowhead's TBC tooltips (nether.wowhead.com/tbc/tooltip/item/<id>) for what the database leaves out: the meta
    gems' requirements ("Requires at least 2 Blue Gems", "Requires more Red gems than Blue gems") and the effect text
    of gems without plain stats (cached in dev/generators/data/gems_wowhead.json).
  - WoWSims' spec presets (ui/specs/<class>/<spec>/presets.ts, presets/ep/*.ep.json): the stat weights per phase
    that rank gems; its gear sets (gear_sets/*.gear.json): the enchant per slot and the meta gem the sims use.
  - LoonBestInSlot's class guides (the same files as gen_bis_lists.py): LBIS:AddGem / LBIS:AddEnchant lines. A line
    registered for phase N counts from phase N on (LoonBestInSlot shows it while its phase setting is >= N); the
    latest phase's enchant for a slot wins, gems are listed newest phase first, then in the guide's order. Enchant
    lines name a spell / item id of LoonBestInSlot's own DB (DB/EnchantSources.lua); they are matched by name.

Run: python generators/gen_gems.py [--write]     (without --write: the report only)
"""
import html
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
LOON = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\LoonBestInSlot"
OUT = os.path.join(ADDON, "Data", "Gems.lua")
CACHE_DIR = os.path.join(HERE, "data")
DB_CACHE = os.path.join(CACHE_DIR, "wowsims_tbc_db.json")      # 3 MB download, git-ignored
WH_CACHE = os.path.join(CACHE_DIR, "gems_wowhead.json")
DB_URL = "https://raw.githubusercontent.com/wowsims/tbc-new/master/assets/database/db.json"

# WoWSims Stat enum (proto/common.proto) -> the words the addon shows.
STAT = {
    0: "Strength", 1: "Agility", 2: "Stamina", 3: "Intellect", 4: "Healing", 5: "Spell Damage",
    6: "Arcane Damage", 7: "Fire Damage", 8: "Frost Damage", 9: "Holy Damage", 10: "Nature Damage",
    11: "Shadow Damage", 12: "Spell Hit", 13: "Spell Crit", 14: "Spell Haste", 15: "Spell Penetration",
    16: "Spirit", 17: "Attack Power", 18: "Ranged AP", 19: "Feral Attack Power", 20: "Hit",
    21: "Crit", 22: "Haste", 23: "Armor Penetration", 24: "Expertise", 25: "Defense", 26: "Block Rating",
    27: "Block Value", 28: "Dodge", 29: "Parry", 30: "Resilience", 31: "Armor", 32: "Armor", 33: "Health",
    34: "Mana", 35: "Mp5", 36: "Arcane Resistance", 37: "Fire Resistance", 38: "Frost Resistance",
    39: "Nature Resistance", 40: "Shadow Resistance", 41: "Weapon Damage",
}
ALL_RES = {36, 37, 38, 39, 40}
# GemColor: 1 Meta, 2 Red, 3 Blue, 4 Yellow, 5 Green, 6 Orange, 7 Purple, 8 Prismatic -> the letter the data uses.
COLOR = {1: "M", 2: "R", 3: "B", 4: "Y", 5: "G", 6: "O", 7: "P", 8: "X"}
SOCKET = {1: "M", 2: "R", 3: "B", 4: "Y"}
PROF = {3: "Enchanting", 4: "Engineering", 7: "Jewelcrafting", 8: "Leatherworking", 11: "Tailoring"}
# LoonBestInSlot's enchant slot words -> DisasterZone slot ids (ns.SLOTS).
LOON_SLOTS = {
    "Head": [1], "Shoulder": [3], "Back": [4], "Chest": [5], "Wrist": [6], "Hands": [7], "Legs": [9],
    "Feet": [10], "Ring": [11, 12], "Main Hand": [15], "Off Hand": [16], "Main Hand~Off Hand": [15, 16],
    "Ranged/Relic": [17], "Shoulder~Legs": [3, 9],
}
# Enchants LoonBestInSlot names that the WoWSims database lacks: name -> effect id (Wowhead).
EXTRA_ENCHANTS = {
    "Enchant Boots - Minor Speed": {"effectId": 911, "spellId": 13890, "name": "Enchant Boots - Minor Speed",
                                    "icon": "trade_engraving", "type": 10, "stats": [], "quality": 1,
                                    "text": "Minor Speed Increase"},
}
# Gems LoonBestInSlot suggests that the WoWSims database lacks (Wowhead TBC): BoP quest / PvP gems.
EXTRA_GEMS = {
    35489: {"id": 35489, "name": "Teardrop Crimson Spinel", "icon": "inv_jewelcrafting_crimsonspinel_02", "color": 2,
            "quality": 4, "phase": 3, "stats": [], "text": "+22 Healing  +8 Spell Damage"},
    38547: {"id": 38547, "name": "Inscribed Ornate Topaz", "icon": "inv_misc_gem_opal_01", "color": 6, "quality": 4,
            "phase": 1, "stats": [], "text": "+10 Attack Power  +5 Crit"},
    38549: {"id": 38549, "name": "Runed Ornate Ruby", "icon": "inv_misc_gem_bloodstone_01", "color": 2, "quality": 4,
            "phase": 1, "stats": [], "text": "+12 Spell Damage"},
}
PHASES = range(0, 6)


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())


def load_db():
    if not os.path.isfile(DB_CACHE):
        os.makedirs(CACHE_DIR, exist_ok=True)
        print("downloading", DB_URL)
        data = fetch_json(DB_URL)
        with open(DB_CACHE, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
    with open(DB_CACHE, encoding="utf-8") as fh:
        return json.load(fh)


_wh = None


def wowhead_tooltip(kind, wid):
    """The tooltip HTML of a Wowhead TBC item / spell (cached)."""
    global _wh
    if _wh is None:
        _wh = json.load(open(WH_CACHE, encoding="utf-8")) if os.path.isfile(WH_CACHE) else {}
    key = "%s:%d" % (kind, wid)
    if key not in _wh:
        try:
            _wh[key] = fetch_json("https://nether.wowhead.com/tbc/tooltip/%s/%d" % (kind, wid)).get("tooltip", "")
        except Exception as e:  # noqa: BLE001
            print("  wowhead %s failed: %s" % (key, e))
            _wh[key] = ""
        with open(WH_CACHE, "w", encoding="utf-8") as fh:
            json.dump(_wh, fh, indent=0, sort_keys=True)
    return _wh[key]


def stats_text(stats):
    """"+18 Healing +6 Spell Damage" from a WoWSims stats array (all five resistances as one)."""
    vals = {i: v for i, v in enumerate(stats or []) if v}
    parts = []
    if ALL_RES <= set(vals) and len({vals[i] for i in ALL_RES}) == 1:
        parts.append("+%g All Resistances" % vals[36])
        for i in ALL_RES:
            vals.pop(i)
    # the five base stats alike: "+6 All Stats" (Exceptional Stats, Prismatic gems)
    BASE = (0, 1, 2, 3, 16)
    if all(vals.get(i) for i in BASE) and len({vals[i] for i in BASE}) == 1:
        parts.append("+%g All Stats" % vals[0])
        for i in BASE:
            vals.pop(i)
    # TBC's attack power counts for ranged too: the database lists both; one is enough
    if vals.get(17) and vals.get(18) == vals.get(17):
        vals.pop(18)
    for i in sorted(vals):
        v = vals[i]
        parts.append("+%s %s" % (("%g" % v), STAT[i]))
    return "  ".join(parts)


def plain(text):
    return html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", text))).strip()


def gem_effect_text(gid):
    """Effect line of a gem whose stats the database leaves empty (most meta gems' procs)."""
    t = wowhead_tooltip("item", gid)
    m = re.search(r'<span class="q1">(.*?)</span>', t)
    return plain(m.group(1)) if m else ""


def meta_rule(gid):
    """'2R2Y2B' / 'B>Y' etc. from the meta gem's 'Requires ...' lines; '' when none."""
    t = plain(wowhead_tooltip("item", gid))
    rules = []
    for n, c in re.findall(r"Requires at least (\d+) (Red|Blue|Yellow) Gems?", t):
        rules.append("%s%s" % (n, c[0]))
    for a, b in re.findall(r"Requires more (Red|Blue|Yellow) gems than (Red|Blue|Yellow) gems", t):
        rules.append("%s>%s" % (a[0], b[0]))
    return ",".join(rules)


def enchant_effect_text(e):
    if e.get("text"):
        return e["text"]
    t = stats_text(e.get("stats"))
    if t:
        return t
    # (no text without stats: Wowhead's spell tooltips of the database's spell ids are not the enchant; the name
    # says enough, "Mongoose", "Exceptional Mana", and the game's own tooltip shows the effect)
    return ""


def short_enchant(name):
    m = re.match(r"Enchant [^-]+ - (.+)$", name)
    return m.group(1) if m else name


def lua_str(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def parse_guides(gems, enchant_by_name):
    loon_names = {}
    with open(os.path.join(LOON, "DB", "EnchantSources.lua"), encoding="utf-8") as fh:
        for line in fh:
            m = re.search(r'\[(\d+)\] = \{ Name = "([^"]+)"', line)
            if m:
                loon_names[int(m.group(1))] = m.group(2)
    guides, problems = {}, []
    gdir = os.path.join(LOON, "Guides")
    for fn in sorted(os.listdir(gdir)):
        if not fn.endswith(".lua"):
            continue
        name, specs, gem_rows, ench_rows = None, {}, [], []
        with open(os.path.join(gdir, fn), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"^function LBIS:Load(\w+)\(\)", line)
                if m:
                    name = m.group(1)
                m = re.match(r'^\s*local (\w+) = LBIS:RegisterSpec\([^,]+,[^,]+,\s*"(\d+)"', line)
                if m:
                    specs[m.group(1)] = int(m.group(2))
                m = re.match(r'^\s*LBIS:AddGem\((\w+),\s*"(\d+)"', line)
                if m:
                    gem_rows.append((specs[m.group(1)], int(m.group(2))))
                m = re.match(r'^\s*LBIS:AddEnchant\((\w+),\s*"(\d+)",\s*LBIS\.L\["([^"]+)"\]', line)
                if m:
                    ench_rows.append((specs[m.group(1)], int(m.group(2)), m.group(3)))
        if not name:
            continue
        per_phase = {}
        for p in PHASES:
            g = []
            for ph in sorted({r[0] for r in gem_rows if r[0] <= p}, reverse=True):
                for rp, gid in gem_rows:
                    if rp == ph and gid not in g:
                        if gid in gems:
                            g.append(gid)
                        elif (name, gid) not in [x[:2] for x in problems]:
                            problems.append((name, gid, "gem not in the database"))
            e = {}
            for rp, lid, slot in sorted(ench_rows, key=lambda r: r[0]):
                if rp > p:
                    continue
                ename = loon_names.get(lid)
                ench = enchant_by_name.get((ename or "").lower())
                if not ench:
                    if (name, lid) not in [x[:2] for x in problems]:
                        problems.append((name, lid, "enchant %s not found" % ename))
                    continue
                for sid in LOON_SLOTS.get(slot, []):
                    e[sid] = ench["effectId"]
            if g or e:
                per_phase[p] = (g, e)
        guides[name] = per_phase
    return guides, problems


# ---------------------------------------------------------------------------------------------------------------
# WoWSims per-spec data: stat weights (EP) per phase and the sims' gear sets (their enchants and meta gems)
# ---------------------------------------------------------------------------------------------------------------
SPEC_DIR = os.path.join(CACHE_DIR, "wowsims_specs")        # git-ignored download cache
TREE_URL = "https://api.github.com/repos/wowsims/tbc-new/git/trees/master?recursive=1"
RAW = "https://raw.githubusercontent.com/wowsims/tbc-new/master/"

# guide -> (spec folder, a word the EP block's name must have, a word a gear set's path must not have)
SPEC_SOURCES = {
    "DruidBalance": ("druid/balance", None, None),
    "DruidBear": ("druid/feralbear", None, "hydross"),
    "DruidCat": ("druid/feralcat", None, None),
    "DruidRestoration": ("druid/restoration", None, None),
    "HunterBeastMastery": ("hunter/dps", "BM", "/sv/"),
    "HunterMarksmanship": ("hunter/dps", "BM", "/sv/"),
    "HunterSurvival": ("hunter/dps", "SV", "/bm/"),
    "MageArcane": ("mage/dps", "Arcane", None),
    "MageFire": ("mage/dps", "Arcane", None),
    "MageFrost": ("mage/dps", "Arcane", None),
    "PaladinHoly": ("paladin/holy", None, None),
    "PaladinProtection": ("paladin/protection", None, None),
    "PaladinRetribution": ("paladin/retribution", None, "bulwark"),
    "PriestHoly": ("priest/healer", None, None),
    "PriestShadow": ("priest/dps", None, None),
    "RogueDps": ("rogue/dps", None, None),
    "ShamanElemental": ("shaman/elemental", None, "simtest"),
    "ShamanEnhancement": ("shaman/enhancement", None, "simtest"),
    "ShamanRestoration": ("shaman/restoration", None, None),
    "WarlockAffliction": ("warlock/dps", "Affli", "fire"),
    "WarlockDemonology": ("warlock/dps", "Affli", "fire"),
    "WarlockDestruction": ("warlock/dps", "Affli", None),
    "WarriorArms": ("warrior/dps", "Arms", "_fury"),
    "WarriorFury": ("warrior/dps", "Fury", "_arms"),
    "WarriorProtection": ("warrior/protection", None, "hydross"),
}
GEAR_PHASE = [(r"pre_?raid|prebis", 0), (r"(?:^|[_/])p(?:hase_)?([1-5])", None), (r"(?:^|[_/])t4", 1),
              (r"(?:^|[_/])t5", 2), (r"(?:^|[_/])t6", 3), (r"(?:^|[_/])za", 4), (r"(?:^|[_/])swp", 5)]


def fetch_raw(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"}),
                                  timeout=60).read()


def stat_index():
    """'StatStrength' -> 0 ... from WoWSims' proto file (cached)."""
    os.makedirs(SPEC_DIR, exist_ok=True)
    path = os.path.join(SPEC_DIR, "common.proto")
    if not os.path.isfile(path):
        open(path, "wb").write(fetch_raw(RAW + "proto/common.proto"))
    text = open(path, encoding="utf-8").read()
    block = text[text.index("enum Stat {"):]
    block = block[:block.index("}")]
    return {m.group(1): int(m.group(2)) for m in re.finditer(r"(Stat\w+) = (\d+);", block)}


def spec_files(folder):
    """{ path under the spec folder: text } of its presets.ts, *.ep.json and *.gear.json (cached)."""
    os.makedirs(SPEC_DIR, exist_ok=True)
    index = os.path.join(SPEC_DIR, "tree.json")
    if not os.path.isfile(index):
        open(index, "wb").write(fetch_raw(TREE_URL))
    tree = json.load(open(index, encoding="utf-8"))["tree"]
    prefix = "ui/specs/%s/" % folder
    out = {}
    for e in tree:
        p = e["path"]
        if e["type"] != "blob" or not p.startswith(prefix):
            continue
        if not (p.endswith("presets.ts") or p.endswith(".ep.json") or p.endswith(".gear.json")):
            continue
        local = os.path.join(SPEC_DIR, p.replace("/", "__"))
        if not os.path.isfile(local):
            open(local, "wb").write(fetch_raw(RAW + p))
        out[p[len(prefix):]] = open(local, encoding="utf-8").read()
    return out


def block_phases(name):
    """The phases an EP block's name covers ("P2, P3, P4 & P5 - Fury" -> {2,3,4,5}); None = any phase."""
    if re.search(r"pre-?raid", name, re.I):
        return {0}
    found = {int(d) for d in re.findall(r"(?:\bP|Phase )(\d)(?!\.\d)", name)}
    if found:
        found |= {int(d) for d in re.findall(r"(?:,|&)\s*P?(\d)\b", name)}
    return found or None


def spec_weights(guide, files, idx):
    """{ phase 0..5: { stat index: weight } } for a guide."""
    word = SPEC_SOURCES[guide][1]
    blocks = []
    for path, text in sorted(files.items()):
        if path.endswith("presets.ts"):
            for m in re.finditer(r"makePresetEpWeights\(\s*'([^']+)',\s*Stats\.fromMap\(\s*\{(.*?)\}", text, re.S):
                w = {idx[k]: float(v) for k, v in re.findall(r"\[Stat\.(Stat\w+)\]:\s*([\d.]+)", m.group(2))}
                blocks.append((m.group(1), w))
        elif path.endswith(".ep.json"):
            j = json.loads(text)
            blocks.append((j.get("name", "Default"), {idx[k]: float(v) for k, v in j["stats"].items() if k in idx}))
    if word:
        blocks = [b for b in blocks if word.lower() in b[0].lower()] or blocks
    out = {}
    for p in PHASES:
        exact = [w for n, w in blocks if block_phases(n) and p in block_phases(n)]
        anyb = [w for n, w in blocks if block_phases(n) is None]
        if exact:
            out[p] = exact[0]
        elif anyb:
            out[p] = anyb[0]
        else:
            ranked = sorted(((abs(q - p) + (0.5 if q > p else 0), i) for i, (n, w) in enumerate(blocks)
                             for q in (block_phases(n) or [])))
            if ranked:
                out[p] = blocks[ranked[0][1]][1]
    return out


def gear_phase(name):
    low = name.lower()
    for pat, ph in GEAR_PHASE:
        m = re.search(pat, low)
        if m:
            return ph if ph is not None else int(m.group(1))
    return None


def spec_gear(guide, files):
    """{ phase: [ items (17, in our slot order) ... ] } of the sims' gear sets for a guide."""
    exclude = SPEC_SOURCES[guide][2]
    out = {}
    for path, text in sorted(files.items()):
        if not path.endswith(".gear.json") or "blank" in path or (exclude and exclude in path.lower()):
            continue
        ph = gear_phase(path.split("gear_sets/")[-1])
        if ph is None:
            continue
        out.setdefault(ph, []).append(json.loads(text).get("items", []))
    return out


def vec(stats):
    return ",".join("%d:%g" % (i, v) for i, v in enumerate(stats or []) if v)


def main():
    write = "--write" in sys.argv
    db = load_db()
    gems = {g["id"]: g for g in db["gems"]}
    # Several entries can share one effect id (the same enchant from two spells / slots, e.g. 2617 is both the
    # bracer's Superior Healing and the gloves' Healing Power): one entry, every item type, the guides' name.
    guide_names = set()
    with open(os.path.join(LOON, "DB", "EnchantSources.lua"), encoding="utf-8") as fh:
        for line in fh:
            m = re.search(r'Name = "([^"]+)"', line)
            if m:
                guide_names.add(m.group(1).lower())
    enchants = {}
    for e in list(db["enchants"]) + list(EXTRA_ENCHANTS.values()):
        prev = enchants.get(e["effectId"])
        if prev is None:
            enchants[e["effectId"]] = dict(e)
            continue
        types = [prev.get("type")] + list(prev.get("extraTypes") or [])
        for t in [e.get("type")] + list(e.get("extraTypes") or []):
            if t not in types:
                types.append(t)
        if e["name"].lower() in guide_names and prev["name"].lower() not in guide_names:
            keep = dict(e)
            types.remove(e.get("type"))
            types.insert(0, e.get("type"))
        else:
            keep = prev
        keep["extraTypes"] = types[1:]
        enchants[e["effectId"]] = keep
    for g in EXTRA_GEMS.values():
        gems.setdefault(g["id"], g)
    # by name from the full list: several enchants share one effect id (the same enchant, two spells)
    enchant_by_name = {e["name"].lower(): e for e in list(db["enchants"]) + list(EXTRA_ENCHANTS.values())}

    # The Enchanting crafts the Atlas knows (Data/Atlas.lua AtlasNames: [-spell] = "Enchant ...") by name.
    atlas_crafts = {}
    with open(os.path.join(ADDON, "Data", "Atlas.lua"), encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r'\s*\[-(\d+)\] = "(Enchant [^"]+)"', line)
            if m:
                atlas_crafts.setdefault(m.group(2).lower(), int(m.group(1)))
    out = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("Data/Gems.lua", ...) then return end -- DisasterZone sockets, '
        "gems, enchants and suggested gems / enchants (My BiS).",
        "-- AUTO-GENERATED by gen_gems.py - do not edit by hand; re-run the generator instead.",
        "-- Sources: WoWSims TBC's item database (wowsims/tbc-new assets/database/db.json), Wowhead TBC tooltips (meta",
        "-- gem rules, effect texts) and LoonBestInSlot's class guides (suggested gems / enchants).",
        "local addonName, ns = ...",
        "ns.Data = ns.Data or {}",
        "",
        "-- [itemID] = \"sockets|bonus|stats\": socket letters in order (M meta, R red, Y yellow, B blue), the bonus text",
        "-- and its stats (\"stat:value,...\", WoWSims' Stat numbers; a gem's / enchant's st likewise).",
        "ns.Data.Sockets = {",
    ]
    n_items = 0
    for it in sorted(db["items"], key=lambda i: i["id"]):
        socks = it.get("gemSockets")
        if not socks:
            continue
        letters = "".join(SOCKET.get(s, "") for s in socks)
        if not letters:
            continue
        out.append("  [%d] = %s," % (it["id"], lua_str("%s|%s|%s" % (letters, stats_text(it.get("socketBonus")),
                                                                   vec(it.get("socketBonus"))))))
        n_items += 1
    out.append("}")
    out += [
        "",
        "-- [gemID] = { colour (R Y B, O orange, P purple, G green, X prismatic, M meta), quality, phase, \"effect\", name,",
        "--   icon, jc = Jewelcrafter only, u = unique-equipped, req = meta rule (\"2R,2Y,2B\" at least, \"B>Y\" more than) }",
        "ns.Data.Gems = {",
    ]
    no_text = []
    for gid in sorted(gems):
        g = gems[gid]
        color = COLOR.get(g["color"])
        if not color:
            continue
        text = g.get("text") or stats_text(g.get("stats"))
        if color == "M" or not text:
            extra = gem_effect_text(gid)
            if extra and extra not in text:
                text = (text + "  " + extra).strip() if color != "M" or not text else extra
        if not text:
            no_text.append(gid)
        fields = ["%s" % lua_str(color), str(g.get("quality", 2)), str(g.get("phase", 1)), lua_str(text),
                  lua_str(g["name"]), lua_str(g.get("icon", ""))]
        if vec(g.get("stats")):
            fields.append("st = %s" % lua_str(vec(g.get("stats"))))
        if g.get("requiredProfession") == 7:
            fields.append("jc = true")
        if g.get("unique"):
            fields.append("u = true")
        if color == "M":
            rule = meta_rule(gid)
            if rule:
                fields.append("req = %s" % lua_str(rule))
        out.append("  [%d] = { %s }," % (gid, ", ".join(fields)))
    out.append("}")
    out += [
        "",
        "-- [effectID] (the enchant number item links carry) = { item type (1 Head .. 10 Feet, 11 Finger, 13 Weapon,",
        "--   14 Ranged; 0 any), \"name\", \"effect\", icon, craft spell (the Enchanting recipe, as the Atlas knows it;",
        "--   0 none), item (the scroll / glyph / kit / spellthread; 0 none),",
        "--   et = 1 two-hand, 2 shield, 3 kit, 4 staff, 5 off-hand only, x = \"also these item types\",",
        "--   prof = profession the wearer needs (Enchanting for rings) }",
        "ns.Data.Enchants = {",
    ]
    for eid in sorted(enchants):
        e = enchants[eid]
        craft = atlas_crafts.get(e["name"].lower(), 0)
        fields = [str(e.get("type", 0)), lua_str(e["name"]), lua_str(enchant_effect_text(e)),
                  lua_str(e.get("icon", "")), str(craft), str(e.get("itemId", 0))]
        if vec(e.get("stats")):
            fields.append("st = %s" % lua_str(vec(e.get("stats"))))
        if e.get("enchantType"):
            fields.append("et = %d" % e["enchantType"])
        if e.get("extraTypes"):
            fields.append("x = %s" % lua_str(",".join(str(t) for t in e["extraTypes"])))
        if e.get("requiredProfession") in PROF:
            fields.append("prof = %s" % lua_str(PROF[e["requiredProfession"]]))
        out.append("  [%d] = { %s }," % (eid, ", ".join(fields)))
    out.append("}")

    guides, problems = parse_guides(gems, enchant_by_name)
    out += [
        "",
        "-- [guide] = { [phase 0..5] = { gems = \"id,...\" (LoonBestInSlot's, newest first), enchants = \"sid:effect,...\"",
        "--   (the WoWSims gear sets' most used per slot, else LoonBestInSlot's), meta = the sets' meta gem, sim = the",
        "--   other gems the sets use (most used first),",
        "--   w = \"stat:weight,...\" (WoWSims' EP weights for the spec and phase: what a gem or bonus is worth) } }",
        "-- (guide keys as in BiSLists.lua; a guide line counts from its phase on, the latest enchant per slot wins)",
        "ns.Data.GemGuides = {",
    ]
    idx = stat_index()
    from collections import Counter
    for name in sorted(set(guides) | set(SPEC_SOURCES)):
        files = spec_files(SPEC_SOURCES[name][0]) if name in SPEC_SOURCES else {}
        weights = spec_weights(name, files, idx) if files else {}
        gear = spec_gear(name, files) if files else {}
        if not weights:
            problems.append((name, 0, "no stat weights"))
        out.append("  %s = {" % name)
        for p in PHASES:
            g, e = guides.get(name, {}).get(p, ([], {}))
            e = dict(e)
            # the sims' gear sets of this phase (else the nearest earlier one): their most used enchant per slot
            # (over the guide's) and meta gem
            sets = next((gear[q] for q in range(p, -1, -1) if gear.get(q)), None) or gear.get(min(gear) if gear else -1, [])
            ench, metas, used = {}, Counter(), Counter()
            for items in sets:
                for sid, it in enumerate(items[:17], 1):
                    if it.get("enchant") in enchants:
                        ench.setdefault(sid, Counter())[it["enchant"]] += 1
                    for gid in it.get("gems") or []:
                        if gid in gems and gems[gid]["color"] == 1:
                            metas[gid] += 1
                        elif gid in gems:
                            used[gid] += 1
            for sid, cnt in ench.items():
                e[sid] = cnt.most_common(1)[0][0]
            fields = ['gems = "%s"' % ",".join(str(x) for x in g),
                      'enchants = "%s"' % ",".join("%d:%d" % (s, e[s]) for s in sorted(e))]
            if metas:
                fields.append("meta = %d" % metas.most_common(1)[0][0])
            if used:
                fields.append('sim = "%s"' % ",".join(str(gid) for gid, _ in used.most_common()))
            if weights.get(p):
                fields.append('w = "%s"' % ",".join("%d:%g" % (k, v) for k, v in sorted(weights[p].items())))
            out.append("    [%d] = { %s }," % (p, ", ".join(fields)))
        out.append("  },")
    out.append("}")
    out.append("")
    text = "\n".join(out)
    print("%d socketed items, %d gems, %d enchants, %d guides, %d bytes" % (
        n_items, len(gems), len(enchants), len(guides), len(text)))
    for p in problems:
        print("  guide problem: %s %s %s" % p)
    if no_text:
        print("  gems without an effect text:", no_text)
    if write:
        with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        print("wrote", OUT)


if __name__ == "__main__":
    main()
