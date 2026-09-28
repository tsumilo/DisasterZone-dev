#!/usr/bin/env python3
"""
Generator for CDLoot's crafted / reputation / Badge-of-Justice item database (SPEC_ADDENDUM_F section 37).

Companion of gen_cdloot_data.py (raids) and gen_cdloot_dungeons.py (5-mans): it IMPORTS them and reuses the Lua
tokenizer / table parser, the file reader, the Questie NPC loader and the LoonBestInSlot loader. Neither earlier
generator nor its output is touched.

Reads (read-only) from the installed WoW AddOns folder:
  * AtlasLootClassic_Crafting/data-tbc.lua          -> TBC profession tables; rows are CRAFT SPELL IDs (TableType
                                                       PROF_ITTYPE); BS specialisation sub-tables (Armorsmith, ...)
  * AtlasLootClassic/Data/Profession.lua            -> PROFESSION_DATA.{CLASSIC,BCC,WRATH}: [spellID] = { createdItemID,
                                                       profID, minSkill, low, high, {reagents}, {counts}, numCreated }
  * AtlasLootClassic/Data/Recipe.lua                -> RECIPE_DATA.{CLASSIC,BCC}: [recipeItemID] = { profID, rank, spellID }
  * AtlasLootClassic_Factions/data-tbc.lua          -> TBC faction tables (FactionID, ContentPhaseBC, per-standing lists)
  * AtlasLootClassic_Collections/data-tbc.lua       -> Badge of Justice vendor tables (BadgeofJustice / ...4 / ...P5)
  * AtlasLootClassic/Data/VendorPrice.lua           -> VENDOR_PRICES_RAW.BCC: [itemID] = "BoJ:<n>" (badge cost)
  * AtlasLootClassic_DungeonsAndRaids/data-tbc.lua  -> where recipes / rare reagents drop (+ ContentPhaseBC) for phases
  * AtlasLootClassic_TBC_Phase_{0..3}_*/..DB.lua    -> per-phase BiS lists (phase CONSISTENCY check only)
  * Questie/Database/TBC/tbcItemDB.lua              -> item class/subclass (equippability), names, level, vendors
  * Questie/Database/TBC/tbcNpcDB.lua               -> vendor NPC names
  * Questie/Database/Corrections/ContentPhases/BurningCrusade.lua -> phase of the 2.1 factions (Ogri'la/Skyguard,
                                                       Netherwing, BT chain) - verified by the comment markers
  * LoonBestInSlot/DB/ItemSources.lua               -> CROSS-CHECK ONLY (no license: nothing is copied to the output)
  * CDLoot/Data/Items.lua, CDLoot/Data/Dungeons.lua -> overlap report only (never written)

Writes:
  * <ADDON>/Data/Sources.lua                    (the only file written inside the addon)
  * <SCRATCH>/gen_sources_report.json           (exclusions, phases, overlaps, Loon cross-check, spot-checks)

Usage:  luaenv\\Scripts\\python.exe gen_cdloot_sources.py [--out PATH] [--no-curated-specs]
"""
import argparse
import json
import os
import re
import sys
from collections import OrderedDict, defaultdict, Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "tools"))
import gen_cdloot_data as G  # noqa: E402  (raid generator; main() is __name__-guarded)
import gen_cdloot_dungeons as GD  # noqa: E402  (dungeon generator; main() is __name__-guarded)
from gen_cdloot_data import LuaTable, Parser, tokenize, read  # noqa: E402
import luabc  # noqa: E402,F401  (puts lupa on sys.path)
from lupa import lua51  # noqa: E402

ADDONS = G.ADDONS
ADDON_DIR = os.path.join(ADDONS, "CDLoot")
OUT_LUA_DEFAULT = os.path.join(ADDON_DIR, "Data", "Sources.lua")
OUT_REPORT = os.path.join(HERE, "gen_sources_report.json")

P_CRAFTING = os.path.join(ADDONS, "AtlasLootClassic_Crafting", "data-tbc.lua")
P_FACTIONS = os.path.join(ADDONS, "AtlasLootClassic_Factions", "data-tbc.lua")
P_COLLECTIONS = os.path.join(ADDONS, "AtlasLootClassic_Collections", "data-tbc.lua")
P_PROFESSION = os.path.join(ADDONS, "AtlasLootClassic", "Data", "Profession.lua")
P_RECIPE = os.path.join(ADDONS, "AtlasLootClassic", "Data", "Recipe.lua")
P_VENDORPRICE = os.path.join(ADDONS, "AtlasLootClassic", "Data", "VendorPrice.lua")
P_DUNGEONSRAIDS = G.P_ATLAS_RAIDS
P_PHASE_MODULES = [  # (path, BiS-list phase; P0 "pre-BiS" lists are phase-1 content)
    (os.path.join(ADDONS, "AtlasLootClassic_TBC_Phase_0_PreBis", "prebisDB.lua"), 1),
    (os.path.join(ADDONS, "AtlasLootClassic_TBC_Phase_1_Karazhan", "phaseoneDB.lua"), 1),
    (os.path.join(ADDONS, "AtlasLootClassic_TBC_Phase_2_SSC_TK", "phasetwoDB.lua"), 2),
    (os.path.join(ADDONS, "AtlasLootClassic_TBC_Phase_3_BT_Hyjal", "phasethreeDB.lua"), 3),
]
P_PVP = os.path.join(ADDONS, "AtlasLootClassic_PvP", "data-tbc.lua")
P_ITEMSET = os.path.join(ADDONS, "AtlasLootClassic", "Data", "ItemSet.lua")
P_QUESTIE_ITEMS = G.P_QUESTIE_ITEMS
P_QUESTIE_TBC_PHASES = os.path.join(ADDONS, "Questie", "Database", "Corrections", "ContentPhases", "BurningCrusade.lua")
P_RAID_ITEMS = os.path.join(ADDON_DIR, "Data", "Items.lua")
P_DUNGEON_ITEMS = os.path.join(ADDON_DIR, "Data", "Dungeons.lua")

# --------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------
# AtlasLoot crafting table key -> (CDLoot key, display name, AtlasLoot/Profession.lua profession ID)
PROFESSIONS = OrderedDict([
    ("BlacksmithingBC",  ("Blacksmithing",  "Blacksmithing",  2)),
    ("LeatherworkingBC", ("Leatherworking", "Leatherworking", 3)),
    ("TailoringBC",      ("Tailoring",      "Tailoring",      8)),
    ("JewelcraftingBC",  ("Jewelcrafting",  "Jewelcrafting",  14)),
    ("EngineeringBC",    ("Engineering",    "Engineering",    9)),
    ("AlchemyBC",        ("Alchemy",        "Alchemy",        4)),
])
PROF_ID_TO_KEY = {v[2]: k for k, v in PROFESSIONS.items()}

# "TBC/Outland content only": the Outland (Master) tier of every profession starts at skill 300. Lower recipes that
# AtlasLoot's TBC tables also list (the whole 1-300 Jewelcrafting ladder, 260-skill spec-quest items, holiday
# clothes, Heavy Copper Longsword...) are excluded.
MIN_CRAFT_SKILL = 300

# Blacksmithing specialisation sub-tables in AtlasLoot's BlacksmithingBC (resolved ALIL names) -> spec label
BS_SPEC_TABLES = OrderedDict([("Armorsmith", "Armorsmith"), ("Weaponsmith", "Weaponsmith"), ("Axesmith", "Axesmith"),
                              ("Hammersmith", "Hammersmith"), ("Swordsmith", "Swordsmith")])

# CURATED specialisation labels (NOT in any installed data file: AtlasLoot's TBC Leatherworking / Tailoring /
# Engineering tables have no specialisation sub-tables and LoonBestInSlot labels only the skill).  Matched on the
# created item's name.  These are the well-known specialisation-only TBC recipes; disable with --no-curated-specs.
CURATED_SPECS = OrderedDict([
    ("Tailoring", [(r"^Spellfire (Belt|Gloves|Robe)$", "Spellfire"),
                   (r"^Primal Mooncloth (Belt|Shoulders|Robe)$", "Mooncloth"),
                   (r"^Frozen Shadoweave (Shoulders|Boots|Robe)$", "Shadoweave")]),
    ("Leatherworking", [(r"^Ebon Netherscale (Breastplate|Belt|Bracers)$", "Dragonscale"),
                        (r"^Netherstrike (Breastplate|Belt|Bracers)$", "Dragonscale"),
                        (r"^Primalstrike (Vest|Belt|Bracers)$", "Elemental"),
                        (r"^Windhawk (Hauberk|Belt|Bracers)$", "Tribal")]),
    ("Engineering", [(r"^Gnomish (Power|Battle) Goggles$", "Gnomish"),
                     (r"^Gnomish Poultryizer$", "Gnomish"),
                     (r"^Ultrasafe Transporter", "Gnomish"),
                     (r"^Goblin Rocket Launcher$", "Goblin"),
                     (r"^Foreman's (Enchanted|Reinforced) Helmet$", "Goblin"),
                     (r"^Dimensional Ripper", "Goblin")]),
])
SPEC_ORDER = [None, "Armorsmith", "Weaponsmith", "Axesmith", "Hammersmith", "Swordsmith",
              "Dragonscale", "Elemental", "Tribal", "Spellfire", "Mooncloth", "Shadoweave", "Gnomish", "Goblin"]

# Alchemy: Questie's TBC DB files the four 2.4 Alchemist Stones as class 7/11 (Trade Goods); they are trinkets.
# Only created items of AtlasLoot's Alchemy "Stones" sub-table whose name ends in "Alchemist Stone" are treated as
# equippable (the Mercurial Stone in the same sub-table is a reagent and stays excluded).
ALCHEMY_TRINKET_RX = re.compile(r"Alchemist Stone$")

# AtlasLoot faction table key -> (CDLoot key, display name).  AtlasLoot's tables carry only FactionID (the game
# resolves the name at runtime); the English faction names are fixed.
FACTIONS = OrderedDict([
    ("TheAldor", ("Aldor", "The Aldor")),
    ("TheScryers", ("Scryers", "The Scryers")),
    ("TheShatar", ("Shatar", "The Sha'tar")),
    ("LowerCity", ("LowerCity", "Lower City")),
    ("KeepersOfTime", ("KeepersOfTime", "Keepers of Time")),
    ("TheVioletEye", ("VioletEye", "The Violet Eye")),
    ("TheScaleOfTheSands", ("ScaleOfTheSands", "The Scale of the Sands")),
    ("CenarionExpedition", ("CenarionExpedition", "Cenarion Expedition")),
    ("TheConsortium", ("Consortium", "The Consortium")),
    ("AshtongueDeathsworn", ("AshtongueDeathsworn", "Ashtongue Deathsworn")),
    ("ShatteredSunOffensive", ("ShatteredSunOffensive", "Shattered Sun Offensive")),
    ("ShatariSkyguard", ("ShatariSkyguard", "Sha'tari Skyguard")),
    ("Netherwing", ("Netherwing", "Netherwing")),
    ("Sporeggar", ("Sporeggar", "Sporeggar")),
    ("Ogrila", ("Ogrila", "Ogri'la")),
    ("Tranquillien", ("Tranquillien", "Tranquillien")),
    ("Thrallmar", ("Thrallmar", "Thrallmar")),
    ("TheMaghar", ("Maghar", "The Mag'har")),
    ("HonorHold", ("HonorHold", "Honor Hold")),
    ("Kurenai", ("Kurenai", "Kurenai")),
])
STANDINGS = {5: "Friendly", 6: "Honored", 7: "Revered", 8: "Exalted"}
STANDING_RANK = {v: k for k, v in STANDINGS.items()}
DIFF_SIDE = {"ALLIANCE_DIFF": "Alliance", "HORDE_DIFF": "Horde"}
# Rep items below Outland level (Tranquillien's level 10-21 gear) are not TBC endgame content.
REP_MIN_REQ_LEVEL = 58  # items with 0 < requiredLevel < 58 are excluded; requiredLevel 0 (rings/trinkets) is kept

# Faction phases beyond AtlasLoot's own ContentPhaseBC (only Shattered Sun Offensive has one).  Each entry names the
# evidence: a comment marker inside Questie's TBC content-phase blacklist (verified at run time), or the CDLoot raid
# phase of the raid that is the only source of that reputation.
FACTION_PHASE_RULES = {
    "Ogrila":              {"phase": 2, "questie_marker": (2, "Ogri'la & Sha'tari Skyguard")},
    "ShatariSkyguard":     {"phase": 2, "questie_marker": (2, "Ogri'la & Sha'tari Skyguard")},
    "Netherwing":          {"phase": 3, "questie_marker": (3, "Netherwing")},
    # Ashtongue reputation comes from Black Temple (CDLoot raid phase 3); Questie phase 3 also holds the "BT chain".
    "AshtongueDeathsworn": {"phase": 3, "questie_marker": (3, "BT chain"), "raid": "BlackTemple"},
    # Scale of the Sands: the Friendly ring is the reward of the Hyjal attunement ("Mount Hyjal ring quests" are in
    # Questie's phase-2 list); every higher standing needs Hyjal reputation (CDLoot raid phase 3).
    "ScaleOfTheSands":     {"phase": 3, "questie_marker": (2, "Mount Hyjal ring quests"), "raid": "HyjalSummit",
                            "standing_phase": {"Friendly": 2}},
}

# Badge of Justice
BOJ_ITEM = 29434
BOJ_PRICE_KEY = "BoJ"
# Questie NPCs that are GM/test placeholders (they "sell" everything; level-1 health, no spawns)
def is_placeholder_npc(npc_row):
    """GM/test NPCs in Questie's DB ("Accessories Vendor" etc.) have 1 health and list every item."""
    return npc_row is None or (npc_row.get("hp") or 0) <= 1


def load_questie_npcs_full():
    """npcID -> {name, hp, zone, friendly ('A'/'H'/'AH'/None), sub} (QuestieDB.npcKeys 1,2,9,13,14)."""
    def conv(a):
        at = GD._at
        return {"name": GD._str(at(a, 0)), "hp": at(a, 1) if isinstance(at(a, 1), int) else 0,
                "zone": at(a, 8) if isinstance(at(a, 8), int) else None,
                "friendly": GD._str(at(a, 12)), "sub": GD._str(at(a, 13))}
    return GD.LazyRows(GD.P_QUESTIE_NPCS, conv)


def vendor_sides(iid, Q, NPC):
    """Set of sides ('A','H') whose players can buy the item from its (non-placeholder) Questie vendors; None if no vendor."""
    sides, any_v = set(), False
    for v in (Q.get(iid) or {}).get("vendors", []):
        row = NPC.get(v)
        if is_placeholder_npc(row):
            continue
        any_v = True
        sides |= set(row.get("friendly") or "")
    return sides if any_v else None


# PvP (AtlasLootClassic_PvP/data-tbc.lua).  AtlasLoot table key -> (CDLoot group key, display name, phase or None).
# Tables are processed in this order and an item is kept only in the FIRST group that lists it (the shared
# PVP_INSIGNIA list is referenced by the Honor, Reputation and Season 1 tables -> kept under Honor).
PVP_TABLES = OrderedDict([
    ("HonorSetBCC",          ("Honor",    "Honor vendors", 1)),
    ("ReputationSetBCC",     ("RepPvP",   "Reputation PvP sets", 1)),
    ("ArenaS1PvP",           ("S1",       "Arena Season 1 (Gladiator)", None)),
    ("ArenaS2PvP",           ("S2",       "Arena Season 2 (Merciless Gladiator)", None)),
    ("ArenaS3PvP",           ("S3",       "Arena Season 3 (Vengeful Gladiator)", None)),
    ("ArenaS4PvP",           ("S4",       "Arena Season 4 (Brutal Gladiator)", None)),
    ("HellfirePeninsulaPvP", ("WorldPvP", "World PvP (Hellfire, Nagrand, Terokkar, Zangarmarsh)", 1)),
    ("NagrandPvP",           ("WorldPvP", None, 1)),
    ("TerokkarPvP",          ("WorldPvP", None, 1)),
    ("ZangarmarshPvP",       ("WorldPvP", None, 1)),
])
PVP_GROUP_ORDER = ["S1", "S2", "S3", "S4", "Honor", "RepPvP", "WorldPvP"]
# AtlasLoot's PvP data has the arena SEASON number (table name "Season N") but no ContentPhaseBC; the season -> phase
# mapping for the Anniversary realms is the one the spec prescribes (S1 = P1, S2 = P2, S3 = P3, S4 = P5).
SEASON_PHASE = {1: 1, 2: 2, 3: 3, 4: 5}
# Price keys of AtlasLoot's PRICE_EXTRA strings / VendorPrice.lua -> display unit
PRICE_UNITS = OrderedDict([
    ("arena", "arena"), ("honor", "honor"), ("honorA", "honor"), ("honorH", "honor"),
    ("pvpEye", "EotS marks"), ("pvpAlterac", "AV marks"), ("pvpArathi", "AB marks"), ("pvpWarsong", "WSG marks"),
    ("HalaaBT", "Halaa Battle Tokens"), ("HalaaRT", "Halaa Research Tokens"),
    ("MarkOfHonorHold", "Marks of Honor Hold"), ("MarkOfThrallmar", "Marks of Thrallmar"),
    ("SpiritShard", "Spirit Shards"), ("BoJ", "badges"),
])

# Questie item class IDs (QuestieDB.itemKeys class = 12)
QCLASS = {0: "Consumable", 1: "Container", 2: "Weapon", 3: "Gem", 4: "Armor", 5: "Reagent", 6: "Projectile",
          7: "Trade Goods", 9: "Recipe", 11: "Quiver", 12: "Quest", 13: "Key", 15: "Miscellaneous"}
WEAPON_EXCLUDED_SUB = {14: "misc weapon", 20: "fishing pole"}
ARMOR_EXCLUDED_NAME_RX = re.compile(r"\bTabard\b|\bShirt\b", re.I)


# --------------------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------------------
def ident(node):
    return node[1] if isinstance(node, tuple) and node[0] == "ident" else None


def scan_local_consts(toks):
    """name -> parsed expr for file-level `local NAME = <expr>` (used for SPLIT_FORMAT / GEM_FORMAT1 ...)."""
    out = {}
    for i in range(len(toks) - 3):
        t = toks[i]
        if t.kind == "name" and t.val == "local" and toks[i + 1].kind == "name" and toks[i + 2].kind == "op" \
                and toks[i + 2].val == "=":
            p = Parser(toks)
            p.i = i + 3
            try:
                out[toks[i + 1].val] = p.parse_expr()
            except Exception:
                pass
    return out


def rtext(node, consts=None, depth=0):
    """Resolve AL["x"], ALIL["x"], "x", local string constants, format(...), concatenations to English text."""
    consts = consts or {}
    if depth > 20 or node is None:
        return None
    if isinstance(node, (int, float)):
        return str(node)
    if isinstance(node, tuple):
        k = node[0]
        if k in ("AL", "str"):
            return node[1]
        if k == "index" and node[1] in (("ident", "ALIL"), ("ident", "AL")) and isinstance(node[2], tuple) \
                and node[2][0] == "str":
            return node[2][1]
        if k == "ident":
            if node[1] in consts:
                return rtext(consts[node[1]], consts, depth + 1)
            return node[1]
        if k == "concat":
            return (rtext(node[1], consts, depth + 1) or "") + (rtext(node[2], consts, depth + 1) or "")
        if k == "call" and node[1] in ("format", "string.format") and node[2]:
            fmt = rtext(node[2][0], consts, depth + 1) or ""
            args = [rtext(a, consts, depth + 1) or "" for a in node[2][1:]]
            try:
                return fmt.replace("%d", "%s") % tuple(args)
            except Exception:
                return fmt
    return str(node)


def find_data_tables(toks):
    """OrderedDict AtlasLoot key -> LuaTable for every `data["KEY"] = { ... }` in a token stream."""
    found = OrderedDict()
    for i in range(len(toks) - 5):
        if toks[i].kind == "name" and toks[i].val == "data" and toks[i + 1].val == "[" and toks[i + 2].kind == "str" \
                and toks[i + 3].val == "]" and toks[i + 4].val == "=" and toks[i + 5].val == "{":
            p = Parser(toks)
            p.i = i + 5
            found[toks[i + 2].val] = p.parse_table()
    return found


def version_table(path, varname, ver):
    """Parse `VARNAME.VER = { ... }` (e.g. PROFESSION_DATA.BCC) -> LuaTable or None."""
    toks, _ = tokenize(read(path))
    for i in range(len(toks) - 4):
        if toks[i].kind == "name" and toks[i].val == varname and toks[i + 1].val == "." and toks[i + 2].val == ver \
                and toks[i + 3].val == "=":
            p = Parser(toks)
            p.i = i + 4
            return p.parse_table()
    return None


def iter_rows(sub):
    """Yield (diffName, rowTable) for every loot-row list of an AtlasLoot sub-table (keys like [NORMAL_DIFF])."""
    for dk, rows in sub.hash.items():
        if isinstance(rows, LuaTable) and isinstance(dk, tuple) and dk[0] == "ident" and dk[1].endswith("_DIFF"):
            for r in rows.array:
                if isinstance(r, LuaTable):
                    yield dk[1], r


def row_id(r):
    a = r.array
    return a[1] if len(a) >= 2 and isinstance(a[1], int) and not isinstance(a[1], bool) else None


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def cmt(s):
    return re.sub(r"[\r\n]+", " ", s or "").strip()


# --------------------------------------------------------------------------------------
# Loaders
# --------------------------------------------------------------------------------------
def load_questie_items():
    """itemID -> {name, ilvl, req, cls, sub, vendors[]} from Questie's TBC item DB (executed in Lua 5.1)."""
    text = read(P_QUESTIE_ITEMS)
    i = text.index("QuestieDB.itemData = [[") + len("QuestieDB.itemData = [[")
    j = text.index("]]", i)
    rt = lua51.LuaRuntime(unpack_returned_tuples=True, register_eval=False, register_builtins=False)
    conv = rt.execute("""
        local src = ...
        local t = assert(loadstring(src))()
        local out = {}
        for id, r in pairs(t) do
          local v = {}
          if type(r[14]) == 'table' then for _, n in ipairs(r[14]) do v[#v + 1] = n end end
          out[#out + 1] = { id, r[1] or "", r[9] or 0, r[10] or 0, r[12] or -1, r[13] or -1, table.concat(v, ",") }
        end
        return out
    """, text[i:j])
    db = {}
    for k in range(1, len(conv) + 1):
        r = conv[k]
        db[int(r[1])] = {"name": r[2], "ilvl": int(r[3]), "req": int(r[4]), "cls": int(r[5]), "sub": int(r[6]),
                         "vendors": [int(x) for x in r[7].split(",") if x]}
    return db


def load_professions():
    """spellID -> dict(ver, item, prof, skill, reagents[(id,count)], num) from Profession.lua (all versions)."""
    out = {}
    for ver in ("CLASSIC", "BCC", "WRATH"):
        t = version_table(P_PROFESSION, "PROFESSION_DATA", ver)
        for sp, v in t.hash.items():
            a = v.array
            reag = [int(x) for x in a[5].array] if len(a) > 5 and isinstance(a[5], LuaTable) else []
            cnt = [int(x) for x in a[6].array] if len(a) > 6 and isinstance(a[6], LuaTable) else []
            out.setdefault(sp, {"ver": ver, "item": a[0] if isinstance(a[0], int) else None, "prof": a[1],
                                "skill": a[2], "reagents": list(zip(reag, cnt + [1] * (len(reag) - len(cnt)))),
                                "num": a[7] if len(a) > 7 else 1})
    return out


def load_recipes():
    """spellID -> [recipeItemID...] and recipeItemID -> (prof, rank, spell) from Recipe.lua (CLASSIC + BCC)."""
    by_spell, by_item = defaultdict(list), {}
    for ver in ("CLASSIC", "BCC"):
        t = version_table(P_RECIPE, "RECIPE_DATA", ver)
        for it, v in t.hash.items():
            a = v.array
            if len(a) >= 3 and isinstance(a[2], int):
                by_item[it] = (a[0], a[1], a[2])
                if it not in by_spell[a[2]]:
                    by_spell[a[2]].append(it)
    return by_spell, by_item


def load_vendor_prices():
    text = read(P_VENDORPRICE)
    a = text.index("VENDOR_PRICES_RAW.BCC")
    b = text.index("VENDOR_PRICES_RAW.WRATH", a)
    out = {}
    for m in re.finditer(r'^\s*\[(\d+)\]\s*=\s*"([^"]*)"', text[a:b], re.M):  # commented rows (--[x]) don't match
        parts = m.group(2).split(":")
        out[int(m.group(1))] = {parts[i]: int(parts[i + 1]) for i in range(0, len(parts) - 1, 2)
                                if parts[i + 1].isdigit()}
    return out


def load_loot_sources():
    """itemID -> [(phase, 'AtlasKey/Boss')] for every item in AtlasLoot's TBC dungeon/raid loot tables."""
    toks, _ = tokenize(read(P_DUNGEONSRAIDS))
    out = defaultdict(list)
    for key, tbl in find_data_tables(toks).items():
        ph = tbl.get("ContentPhaseBC")
        ph = ph if isinstance(ph, int) else 1
        items = tbl.get("items")
        if not isinstance(items, LuaTable):
            continue
        for boss in items.array:
            if not isinstance(boss, LuaTable):
                continue
            bname = rtext(boss.get("name")) or "?"
            for _, r in iter_rows(boss):
                iid = row_id(r)
                if iid:
                    out[iid].append((ph, f"{key}/{bname}"))
    return out


def load_phase_module_items():
    """itemID -> earliest phase whose AtlasLoot TBC BiS module lists it (P0 pre-BiS counts as phase 1)."""
    out = {}
    for path, ph in P_PHASE_MODULES:
        if not os.path.exists(path):
            continue
        toks, _ = tokenize(read(path))
        for tbl in find_data_tables(toks).values():
            items = tbl.get("items")
            for sub in (items.array if isinstance(items, LuaTable) else []):
                if isinstance(sub, LuaTable):
                    for _, r in iter_rows(sub):
                        iid = row_id(r)
                        if iid and (iid not in out or ph < out[iid]):
                            out[iid] = ph
    return out


def load_questie_phase_markers():
    """phase -> [comment markers] inside Questie's TBC questsToBlacklistByPhase table."""
    out = defaultdict(list)
    if not os.path.exists(P_QUESTIE_TBC_PHASES):
        return out
    cur = None
    for line in read(P_QUESTIE_TBC_PHASES).splitlines():
        m = re.match(r"^\s*\[(\d)\]\s*=\s*\{", line)
        if m:
            cur = int(m.group(1))
            continue
        m = re.match(r"^\s*--\s*(.+?)\s*$", line)
        if m and cur:
            out[cur].append(m.group(1))
        if re.match(r"^\}", line):
            cur = None
    return out


def load_cdloot_ids(lua):
    """(raid itemID -> [raid/boss], dungeon itemID -> [dungeon/boss]) from CDLoot's own data files (read-only)."""
    def run(path):
        if not os.path.exists(path):
            return None
        src = open(path, encoding="utf-8").read()
        f = lua.eval("function(s, n) return loadstring(s, n) end")(src, "@" + os.path.basename(path))
        ns = lua.table()
        f("CDLoot", ns)
        return ns
    raid, dung = defaultdict(list), defaultdict(list)
    ns = run(P_RAID_ITEMS)
    if ns is not None and ns.Data and ns.Data.Raids:
        for _, r in ns.Data.Raids.items():
            for _, b in (r.bosses or {}).items():
                for _, iid in (b["items"] or {}).items():
                    raid[int(iid)].append(f"{r.key}/{b.key}")
    ns = run(P_DUNGEON_ITEMS)
    if ns is not None and ns.Data and ns.Data.Dungeons:
        for _, d in ns.Data.Dungeons.items():
            for _, b in (d.bosses or {}).items():
                for fld in ("items", "heroicItems"):
                    for _, iid in (b[fld] or {}).items():
                        dung[int(iid)].append(f"{d.key}/{b.key}")
    return raid, dung


# --------------------------------------------------------------------------------------
# Equippability
# --------------------------------------------------------------------------------------
GEAR_SECTION_RX = re.compile(r"^(Armor - |Weapons - |Non Set |Relic$|Neck$|Finger$|Trinket$|Back$|Cloak$|Off Hand$|Wand$|set \d+)")


def equip_check(iid, Q, allow_alchemy_stone=False, section=None):
    """Return (True, None) if the item is equippable gear, else (False, reason).
    Items missing from Questie's TBC DB count as gear only when the AtlasLoot section they are listed in is a gear
    section (e.g. "Non Set 'Cloth'", "Armor - Head", a PvP set) - the caller supplies that section."""
    q = Q.get(iid)
    if q is None:
        if section and GEAR_SECTION_RX.search(section):
            return True, "equippable per AtlasLoot section (not in Questie TBC DB)"
        return False, "not in Questie TBC item DB (unknown/unobtainable item)"
    cls, sub, name = q["cls"], q["sub"], q["name"]
    if allow_alchemy_stone and ALCHEMY_TRINKET_RX.search(name or ""):
        return True, None
    if cls == 2:
        if sub in WEAPON_EXCLUDED_SUB:
            return False, "weapon subclass " + WEAPON_EXCLUDED_SUB[sub]
        return True, None
    if cls == 4:
        if sub == 0 and ARMOR_EXCLUDED_NAME_RX.search(name or ""):
            return False, "tabard/shirt"
        return True, None
    return False, "not equippable (Questie class %s %s)" % (cls, QCLASS.get(cls, "?"))


# --------------------------------------------------------------------------------------
# Crafted
# --------------------------------------------------------------------------------------
def build_crafted(Q, PROF, REC_BY_SPELL, LOOT, FAC_RECIPE_PHASE, use_curated, report):
    toks, comments = tokenize(read(P_CRAFTING))
    consts = scan_local_consts(toks)
    tables = find_data_tables(toks)
    excluded = []
    comment_skill_mismatch = []
    listed_spells = set()
    out = []
    for al_key, (key, disp, prof_id) in PROFESSIONS.items():
        tbl = tables[al_key]
        top_type = ident(tbl.get("TableType"))
        entries = OrderedDict()  # itemID -> record
        order = 0
        for sub in tbl.get("items").array:
            sname = rtext(sub.get("name"), consts)
            sub_type = ident(sub.get("TableType")) or top_type
            spec_from_table = BS_SPEC_TABLES.get(sname) if al_key == "BlacksmithingBC" else None
            for diff, r in iter_rows(sub):
                rid = row_id(r)
                if rid is None:
                    continue  # header row ("INV_...", nil, text) or faction variant
                line = r.line_start
                c = comments.get(r.array_lines[1] if len(r.array_lines) > 1 else line, "")
                if sub_type != "PROF_ITTYPE":
                    excluded.append({"prof": key, "section": sname, "id": rid, "reason": "item row (raw gems table), not a craft", "line": line})
                    continue
                sp = rid
                listed_spells.add(sp)
                pv = PROF.get(sp)
                if pv is None:
                    excluded.append({"prof": key, "section": sname, "spell": sp, "reason": "spell not in Profession.lua", "line": line, "comment": c})
                    continue
                if pv["ver"] != "BCC":
                    excluded.append({"prof": key, "section": sname, "spell": sp, "item": pv["item"], "reason": f"{pv['ver']} recipe (not TBC content)", "line": line, "comment": c})
                    continue
                iid = pv["item"]
                if not iid:
                    excluded.append({"prof": key, "section": sname, "spell": sp, "reason": "spell creates no item", "line": line, "comment": c})
                    continue
                m = re.search(r"\((\d+)\)\s*$", c)
                if m and int(m.group(1)) != pv["skill"]:
                    comment_skill_mismatch.append({"spell": sp, "item": iid, "comment": c, "professionLua": pv["skill"]})
                if pv["skill"] < MIN_CRAFT_SKILL:
                    excluded.append({"prof": key, "section": sname, "spell": sp, "item": iid, "name": (Q.get(iid) or {}).get("name"), "reason": f"skill {pv['skill']} < {MIN_CRAFT_SKILL} (pre-Outland recipe)", "line": line})
                    continue
                cname = (Q.get(iid) or {}).get("name") or re.sub(r"\s*\(\S+\)\s*$", "", c).strip()
                if iid not in Q:
                    recs = REC_BY_SPELL.get(sp, [])
                    if recs and not any(ri in Q for ri in recs):
                        excluded.append({"prof": key, "section": sname, "spell": sp, "item": iid, "name": cname, "line": line,
                                         "reason": f"item and its pattern(s) {recs} not in Questie TBC DB (never obtainable)"})
                        continue
                ok, why = equip_check(iid, Q, allow_alchemy_stone=(al_key == "AlchemyBC" and sname == "Stones"),
                                      section=("Armor - " + sname) if spec_from_table else sname)
                if not ok:
                    excluded.append({"prof": key, "section": sname, "spell": sp, "item": iid, "name": cname, "reason": why, "line": line})
                    continue
                if why:
                    report["equippable_by_section"].append({"kind": "Crafted", "id": iid, "name": cname, "section": sname})
                rec = entries.get(iid)
                if rec is None:
                    rec = {"id": iid, "spell": sp, "skill": pv["skill"], "spec": None, "sections": [], "order": order,
                           "name": cname, "line": line, "comment": c}
                    order += 1
                    entries[iid] = rec
                elif rec["spell"] != sp:
                    report["warnings"].append(f"{key}: item {iid} created by two spells {rec['spell']} and {sp}")
                rec["sections"].append(f"{sname} [{diff}]")
                if spec_from_table:
                    if rec["spec"] and rec["spec"] != spec_from_table:
                        report["warnings"].append(f"{key}: item {iid} in two spec tables {rec['spec']}/{spec_from_table}")
                    rec["spec"] = spec_from_table
                    rec["specSource"] = "AtlasLoot sub-table"
        # Supplement: TBC craft spells of this profession that AtlasLoot's category tables do not list
        for sp, pv in sorted(PROF.items()):
            if pv["ver"] != "BCC" or pv["prof"] != prof_id or sp in listed_spells or not pv["item"]:
                continue
            iid = pv["item"]
            if pv["skill"] < MIN_CRAFT_SKILL or iid in entries:
                continue
            ok, _ = equip_check(iid, Q)
            if ok:
                entries[iid] = {"id": iid, "spell": sp, "skill": pv["skill"], "spec": None, "order": order,
                                "sections": ["(not in AtlasLoot crafting tables; Profession.lua BCC)"],
                                "name": Q[iid]["name"], "supplement": True}
                order += 1
                report["crafted_supplements"].append({"prof": key, "spell": sp, "item": iid, "name": Q[iid]["name"]})
        # Curated specialisations (LW / Tailoring / Engineering)
        if use_curated and key in CURATED_SPECS:
            for rec in entries.values():
                for rx, spec in CURATED_SPECS[key]:
                    if re.search(rx, rec["name"]):
                        rec["spec"] = spec
                        rec["specSource"] = "curated"
                        report["curated_specs"].append({"prof": key, "item": rec["id"], "name": rec["name"], "spec": spec})
                        break
        # Phase: AtlasLoot's own rule (Profession.GetSpellIDPhase = max over recipe item, created item, reagents),
        # with the per-item phase read from where AtlasLoot lists that item (raid/dungeon ContentPhaseBC, faction phase)
        for rec in entries.values():
            pv = PROF[rec["spell"]]
            ph, why = 1, "default (no AtlasLoot phase info)"
            recipes = REC_BY_SPELL.get(rec["spell"], [])
            rph = []
            for rit in recipes:
                srcs = [(p, w) for p, w in LOOT.get(rit, [])] + [(p, w) for p, w in FAC_RECIPE_PHASE.get(rit, [])]
                if srcs:
                    rph.append(min(srcs))
            rec["recipes"] = recipes
            if rph:
                best = min(rph)
                if best[0] > ph:
                    ph, why = best[0], f"recipe {recipes} from {best[1]} (phase {best[0]})"
                elif why.startswith("default"):
                    why = f"recipe from {best[1]} (phase {best[0]})"
            rare = []
            for rg, cnt in pv["reagents"]:
                srcs = LOOT.get(rg)
                if srcs:
                    p0 = min(srcs)
                    rare.append((rg, cnt, p0))
                    if p0[0] > ph:
                        ph, why = p0[0], f"reagent {rg} ({(Q.get(rg) or {}).get('name')}) drops in {p0[1]} (phase {p0[0]})"
            rec["phase"], rec["phaseWhy"] = ph, why
            if rare:
                rec["reagentsNote"] = ", ".join(f"{cnt}x {(Q.get(rg) or {}).get('name') or rg}" for rg, cnt, _ in rare)
        items = sorted(entries.values(), key=lambda r: (SPEC_ORDER.index(r["spec"]), r["order"]))
        out.append({"key": key, "name": disp, "professionID": prof_id, "items": items})
    report["crafted_excluded"] = excluded
    report["crafted_comment_skill_mismatch"] = comment_skill_mismatch
    return out


# --------------------------------------------------------------------------------------
# Reputation
# --------------------------------------------------------------------------------------
def parse_factions():
    toks, comments = tokenize(read(P_FACTIONS))
    return find_data_tables(toks), comments, scan_local_consts(toks)


def faction_phase(key, tbl, standing, markers, raid_phases, report):
    ph = tbl.get("ContentPhaseBC")
    if isinstance(ph, int):
        return ph, "AtlasLoot ContentPhaseBC"
    rule = FACTION_PHASE_RULES.get(key)
    if not rule:
        return 1, "default"
    mk = rule.get("questie_marker")
    if mk and mk[1] not in markers.get(mk[0], []):
        report["warnings"].append(f"Questie phase marker {mk!r} for {key} not found - phase rule unverified")
    if rule.get("raid") and raid_phases.get(rule["raid"]) not in (None, rule["phase"]):
        report["warnings"].append(f"{key}: CDLoot raid {rule['raid']} phase {raid_phases.get(rule['raid'])} != rule {rule['phase']}")
    sp = rule.get("standing_phase", {}).get(standing)
    if sp:
        return sp, f"Questie phase-{mk[0]} marker '{mk[1]}'"
    return rule["phase"], (f"Questie phase-{mk[0]} marker '{mk[1]}'" if mk and mk[0] == rule["phase"] else "") + \
        (f" + CDLoot raid {rule['raid']} phase" if rule.get("raid") else "")


def build_reputation(Q, markers, raid_phases, report):
    tables, comments, consts = parse_factions()
    out, excluded = [], []
    fac_recipe_phase = defaultdict(list)  # recipe item -> [(phase, faction)]  (for crafted phases)
    for al_key, tbl in tables.items():
        if al_key == "DUMMY":
            continue
        if al_key not in FACTIONS:
            report["warnings"].append(f"unmapped AtlasLoot faction table {al_key}")
            continue
        key, disp = FACTIONS[al_key]
        fid = tbl.get("FactionID")
        items, sides = OrderedDict(), set()
        for sub in tbl.get("items").array:
            sname = rtext(sub.get("name"), consts)
            for diff, r in iter_rows(sub):
                a = r.array
                if len(a) >= 2 and isinstance(a[1], tuple) and a[1][0] == "str":
                    m = re.match(r"^f(\d+)rep(\d)$", a[1][1])
                    if m and (int(m.group(1)) != fid or STANDINGS.get(int(m.group(2))) != sname):
                        report["warnings"].append(f"{al_key}: marker {a[1][1]} under '{sname}' (FactionID {fid})")
                    continue
                iid = row_id(r)
                if iid is None:
                    continue
                if sname not in STANDING_RANK:
                    report["warnings"].append(f"{al_key}: unknown standing section {sname!r}")
                    continue
                line = r.line_start
                c = comments.get(r.array_lines[1] if len(r.array_lines) > 1 else line, "")
                ph, why = faction_phase(key, tbl, sname, markers, raid_phases, report)
                q = Q.get(iid)
                if q and q["cls"] == 9:
                    fac_recipe_phase[iid].append((ph, f"faction {disp} ({sname})"))
                ok, reason = equip_check(iid, Q)
                if ok and 0 < q["req"] < REP_MIN_REQ_LEVEL:
                    ok, reason = False, f"requiredLevel {q['req']} (pre-Outland gear)"
                if not ok:
                    excluded.append({"faction": key, "standing": sname, "id": iid, "name": (q or {}).get("name") or c, "reason": reason, "line": line})
                    continue
                if diff in DIFF_SIDE:
                    sides.add(DIFF_SIDE[diff])
                prev = items.get(iid)
                if prev:
                    if STANDING_RANK[sname] < STANDING_RANK[prev["standing"]]:
                        prev["standing"] = sname
                    report["warnings"].append(f"{al_key}: item {iid} listed under two standings")
                    continue
                items[iid] = {"id": iid, "standing": sname, "phase": ph, "phaseWhy": why, "name": q["name"],
                              "line": line, "comment": c}
        entry = {"key": key, "name": disp, "factionID": fid, "items": list(items.values())}
        if len(sides) == 1:
            entry["side"] = sides.pop()
        if entry["items"]:
            out.append(entry)
        else:
            report["factions_without_items"].append({"faction": key, "name": disp})
    report["rep_excluded"] = excluded
    return out, fac_recipe_phase


# --------------------------------------------------------------------------------------
# Badges
# --------------------------------------------------------------------------------------
def build_badges(Q, NPC, PRICES, report):
    toks, comments = tokenize(read(P_COLLECTIONS))
    consts = scan_local_consts(toks)
    tables = find_data_tables(toks)
    table_items = OrderedDict()  # itemID -> (phase, table, line, comment)
    for al_key, tbl in tables.items():
        name = rtext(tbl.get("name"), consts) or ""
        if "Badge of Justice" not in name:
            continue
        m = re.search(r"\bP(\d)\b", name)
        ph = int(m.group(1)) if m else 1
        report["badge_tables"].append({"table": al_key, "name": name, "phase": ph})
        for sub in tbl.get("items").array:
            for _, r in iter_rows(sub):
                iid = row_id(r)
                if iid is None:
                    continue
                c = comments.get(r.array_lines[1] if len(r.array_lines) > 1 else r.line_start, "")
                if iid in table_items:
                    report["warnings"].append(f"badge item {iid} listed twice ({table_items[iid][1]} / {al_key})")
                    continue
                table_items[iid] = (ph, al_key, r.line_start, c)
    boj_priced = {i: p[BOJ_PRICE_KEY] for i, p in PRICES.items() if BOJ_PRICE_KEY in p}
    # Rank vendors by how many BoJ-priced items Questie says they sell (placeholder/test NPCs ignored)
    vend_count = Counter()
    for iid in boj_priced:
        for v in (Q.get(iid) or {}).get("vendors", []):
            if not is_placeholder_npc(NPC.get(v)):
                vend_count[v] += 1
    report["badge_vendor_ranking"] = [{"npc": v, "name": (NPC.get(v) or {}).get("name", "?"), "bojItems": n}
                                      for v, n in vend_count.most_common()]
    groups = OrderedDict()
    excluded = []
    all_ids = list(table_items) + [i for i in sorted(boj_priced) if i not in table_items]
    vendor_phases = defaultdict(Counter)
    for iid in all_ids:
        ok, why = equip_check(iid, Q)
        q = Q.get(iid)
        if not ok:
            excluded.append({"id": iid, "name": (q or {}).get("name") or (table_items.get(iid) or (0, 0, 0, ""))[3],
                             "reason": why, "cost": boj_priced.get(iid)})
            continue
        vendors = [v for v in q["vendors"] if vend_count.get(v)]
        if not vendors:
            excluded.append({"id": iid, "name": q["name"], "reason": "no Badge-of-Justice vendor in Questie", "cost": boj_priced.get(iid)})
            continue
        vendor = max(vendors, key=lambda v: vend_count[v])
        cost = boj_priced.get(iid)
        if cost is None:
            report["warnings"].append(f"badge item {iid} {q['name']} has no BoJ price in VendorPrice.lua")
        other = {k: v for k, v in PRICES.get(iid, {}).items() if k != BOJ_PRICE_KEY}
        if other:
            report["badge_extra_costs"].append({"id": iid, "extra": other})
        rec = {"id": iid, "cost": cost, "name": q["name"]}
        if iid in table_items:
            rec["phase"], rec["phaseWhy"] = table_items[iid][0], f"AtlasLoot table {table_items[iid][1]}"
            rec["line"], rec["comment"] = table_items[iid][2], table_items[iid][3]
            vendor_phases[vendor][rec["phase"]] += 1
        else:
            rec["phase"], rec["phaseWhy"] = None, "priced BoJ in VendorPrice.lua but not in AtlasLoot's badge tables"
        groups.setdefault(vendor, []).append(rec)
    out = []
    for vendor, items in groups.items():
        for rec in items:
            if rec["phase"] is None:  # vendor's most common table phase
                ph = vendor_phases[vendor].most_common(1)[0][0] if vendor_phases[vendor] else 1
                rec["phase"] = ph
                rec["phaseWhy"] += f"; phase {ph} = most common phase of this vendor's AtlasLoot items"
                report["badge_not_in_tables"].append({"id": rec["id"], "name": rec["name"], "vendor": vendor, "cost": rec["cost"], "phase": ph})
        npc_name = (NPC.get(vendor) or {}).get("name") or "NPC %d" % vendor
        key = re.sub(r"[^A-Za-z0-9]", "", npc_name)
        out.append({"key": key, "name": npc_name, "npcID": vendor, "items": items})
    out.sort(key=lambda g: -vend_count[g["npcID"]])
    report["badges_excluded"] = excluded
    return out, table_items, boj_priced


# --------------------------------------------------------------------------------------
# PvP
# --------------------------------------------------------------------------------------
def parse_price(s):
    """'honorA:22950:pvpEye:10' -> OrderedDict(honorA=22950, pvpEye=10)."""
    parts = (s or "").split(":")
    return OrderedDict((parts[i], int(parts[i + 1])) for i in range(0, len(parts) - 1, 2) if parts[i + 1].isdigit())


def price_text(price):
    """OrderedDict price -> short display string ('22950 honor + 10 EotS marks'); None if nothing displayable."""
    out = []
    for k, v in price.items():
        if k == "money":  # copper -> "12g 34s 56c" (zero parts dropped)
            g_, s_, c_ = v // 10000, (v // 100) % 100, v % 100
            out.append(" ".join(f"{n}{u}" for n, u in ((g_, "g"), (s_, "s"), (c_, "c")) if n) or "0c")
        elif k in PRICE_UNITS:
            out.append(f"{v} {PRICE_UNITS[k]}")
        else:
            out.append(f"{v} {k}")
    return " + ".join(out) or None


def load_item_sets():
    """setID -> ([itemIDs], name) from ItemSet.lua ITEM_SET_DATA_RAW.BCC (name from the trailing comment)."""
    text = read(P_ITEMSET)
    toks, comments = tokenize(text)
    t = version_table(P_ITEMSET, "ITEM_SET_DATA_RAW", "BCC")
    out = {}
    for sid, v in t.hash.items():
        items = [int(x) for x in v.array[0].array] if v.array and isinstance(v.array[0], LuaTable) else []
        out[sid] = (items, comments.get(v.line_start, ""))
    return out


def build_pvp(Q, NPC, PRICES, report):
    toks, comments = tokenize(read(P_PVP))
    consts = scan_local_consts(toks)
    tables = find_data_tables(toks)
    SETS = load_item_sets()
    groups = OrderedDict()
    seen = {}  # itemID -> group key (first group wins)
    excluded = []
    # ---- 1. collect rows: group -> itemID -> {side -> price text or None}
    for al_key, (gkey, gname, gphase) in PVP_TABLES.items():
        tbl = tables.get(al_key)
        if tbl is None:
            report["warnings"].append(f"PvP table {al_key} not found")
            continue
        tname = rtext(tbl.get("name"), consts) or ""
        if gphase is None:
            m = re.search(r"Season (\d)", tname)
            season = int(m.group(1)) if m else None
            gphase = SEASON_PHASE.get(season, 1)
            report["pvp_phase_source"][gkey] = f"AtlasLoot table name '{tname}' -> season {season} -> phase {gphase}"
        else:
            report["pvp_phase_source"].setdefault(gkey, f"fixed phase {gphase} (AtlasLoot table has no season/phase)")
        g = groups.setdefault(gkey, {"key": gkey, "name": gname, "phase": gphase, "items": OrderedDict()})
        top_type = ident(tbl.get("TableType"))
        for sub in tbl.get("items").array:
            if isinstance(sub, tuple) and sub[0] == "ident" and isinstance(consts.get(sub[1]), LuaTable):
                sub = consts[sub[1]]  # shared local tables (PVP_INSIGNIA, PVP_GEMS)
            if not isinstance(sub, LuaTable):
                continue
            sname = rtext(sub.get("name"), consts) or ""
            sub_type = ident(sub.get("TableType")) or top_type
            for diff, r in iter_rows(sub):
                rid = row_id(r)
                if rid is None:
                    continue
                side = DIFF_SIDE.get(diff, "Both")
                pe = next((v for k, v in r.hash.items() if ident(k) == "PRICE_EXTRA_ITTYPE"), None)
                row_price = parse_price(pe[1]) if isinstance(pe, tuple) and pe[0] == "str" else None
                if sub_type == "SET_ITTYPE":
                    if rid not in SETS:
                        report["warnings"].append(f"PvP {al_key}: set {rid} not in ItemSet.lua BCC")
                        continue
                    ids, setname = SETS[rid]
                    members = [(i, f"set {rid} {setname}", None) for i in ids]
                else:
                    c = comments.get(r.array_lines[1] if len(r.array_lines) > 1 else r.line_start, "")
                    members = [(rid, sname, c)]
                for iid, where, cname in members:
                    ok, why = equip_check(iid, Q, section=where)
                    name = (Q.get(iid) or {}).get("name") or (cname or "").strip() or f"item {iid}"
                    if not ok:
                        excluded.append({"group": gkey, "section": where, "id": iid, "name": name, "reason": why})
                        continue
                    if why:
                        report["equippable_by_section"].append({"kind": "PvP", "id": iid, "name": name, "section": where})
                    if iid in seen and seen[iid] != gkey:
                        report["pvp_cross_group_dupes"].append({"id": iid, "name": name, "kept_in": seen[iid], "also_in": gkey})
                        continue
                    seen[iid] = gkey
                    price = row_price if row_price is not None else PRICES.get(iid)
                    rec = g["items"].setdefault(iid, {"id": iid, "name": name, "phase": gphase, "rows": OrderedDict(),
                                                      "section": where, "line": r.line_start})
                    rec["rows"].setdefault(side, price_text(price) if price else None)
    # ---- 2. faction variants from Questie vendors: an item whose vendors are friendly to one side only belongs to
    #         that side; AtlasLoot sometimes lists it for the other side too (Zangarmarsh) or omits the other side's
    #         twin (Honor Hold variants of the reputation PvP pieces).  The twin = same name + class/subclass whose
    #         vendors are friendly to the other side only.
    by_name = defaultdict(list)
    for iid, q in Q.items():
        if q["cls"] in (2, 4):
            by_name[(q["name"], q["cls"], q["sub"])].append(iid)
    letter = {"Alliance": "A", "Horde": "H"}
    full = {"A": "Alliance", "H": "Horde"}

    def twin(iid, want):
        q = Q.get(iid)
        if not q:
            return None
        c = [o for o in by_name[(q["name"], q["cls"], q["sub"])] if o != iid and vendor_sides(o, Q, NPC) == {want}]
        return c[0] if len(c) == 1 else None
    for g in groups.values():
        for iid in list(g["items"].keys()):
            rec = g["items"][iid]
            vs = vendor_sides(iid, Q, NPC)
            if not vs or len(vs) != 1:
                continue
            own = next(iter(vs))
            other = "H" if own == "A" else "A"
            rows = rec["rows"]
            if full[other] not in rows and "Both" not in rows:
                continue  # already listed for its own side only
            t = twin(iid, other)
            if t is None or t in seen:
                # Questie's vendor list may simply be incomplete: keep AtlasLoot's sides unchanged
                report["pvp_faction_fixes"].append({"group": g["key"], "id": iid, "name": rec["name"],
                                                    "fix": f"AtlasLoot lists it for {'/'.join(rows)}; Questie vendors are {full[own]}-only; "
                                                           + ("no twin found - kept as AtlasLoot lists it" if t is None else f"twin {t} already listed")})
                continue
            wrong = rows.pop(full[other], "__none__")
            both = rows.pop("Both", "__none__")
            if both != "__none__":
                rows[full[own]] = both
            if not rows:
                rows[full[own]] = wrong if wrong != "__none__" else None
            if True:
                seen[t] = g["key"]
                g["items"][t] = {"id": t, "name": Q[t]["name"], "phase": rec["phase"], "section": rec["section"],
                                 "line": rec["line"], "rows": OrderedDict([(full[other], wrong if wrong != "__none__" else both)]),
                                 "after": iid}
                report["pvp_faction_fixes"].append({"group": g["key"], "id": iid, "name": rec["name"], "twin": t,
                                                    "fix": f"{iid} is {full[own]}-only (Questie vendors); {full[other]} twin {t} "
                                                           + ("replaces AtlasLoot's wrong-side row" if wrong != "__none__" else "added")})
    # ---- 3. output
    out = []
    for gkey in PVP_GROUP_ORDER:
        if gkey not in groups:
            continue
        g = groups[gkey]
        # place every Questie twin right after the item it was derived from
        ordered, twins = [], defaultdict(list)
        for rec in g["items"].values():
            (twins[rec["after"]] if rec.get("after") else ordered).append(rec)
        seq = []
        for rec in ordered:
            seq.append(rec)
            seq.extend(twins.get(rec["id"], []))
        items = []
        for rec in seq:
            rec.pop("after", None)
            rows = rec.pop("rows")
            sides = set(rows)
            rec["faction"] = next(iter(sides)) if len(sides) == 1 and "Both" not in sides else None
            prices = OrderedDict()
            for side, txt in rows.items():
                if txt:
                    prices.setdefault(txt, side)
            if len(prices) == 1:
                rec["cost"] = next(iter(prices))
            elif prices:  # faction-specific currencies (e.g. Marks of Honor Hold / Marks of Thrallmar)
                rec["cost"] = " / ".join(f"{t} ({sd})" if sd != "Both" else t for t, sd in prices.items())
            else:
                rec["cost"] = None
            rec["phaseWhy"] = report["pvp_phase_source"].get(gkey)
            items.append(rec)
        out.append({"key": g["key"], "name": g["name"], "phase": g["phase"], "items": items})
    report["pvp_excluded"] = excluded
    return out


# --------------------------------------------------------------------------------------
# Lua writer
# --------------------------------------------------------------------------------------
HEADER = """\
-- CDLoot crafted / reputation / Badge of Justice / PvP item database (TBC Anniversary, Interface 20506)
-- AUTO-GENERATED by gen_cdloot_sources.py - do not edit by hand; re-run the generator instead.
-- Sources (all read locally; AtlasLootClassic data is GPL v2):
--   AtlasLootClassic_Crafting/data-tbc.lua     TBC profession tables (rows are craft spell IDs; the Blacksmithing
--                                              Armorsmith/Weaponsmith/Axesmith/Hammersmith/Swordsmith sub-tables)
--   AtlasLootClassic/Data/Profession.lua       spell -> created item, profession, required skill, reagents
--   AtlasLootClassic/Data/Recipe.lua           recipe item -> craft spell (for recipe-based phases)
--   AtlasLootClassic_Factions/data-tbc.lua     TBC faction tables: FactionID, standing sections, ContentPhaseBC
--   AtlasLootClassic_Collections/data-tbc.lua  Badge of Justice vendor tables (P1 / "P4" / "P5")
--   AtlasLootClassic/Data/VendorPrice.lua      badge costs ("BoJ:<n>"), Spirit Shard prices
--   AtlasLootClassic_PvP/data-tbc.lua + AtlasLootClassic/Data/ItemSet.lua  TBC PvP tables and their set members
--   AtlasLootClassic_DungeonsAndRaids/data-tbc.lua  where recipes / raid reagents drop (+ ContentPhaseBC)
--   Questie/Database/TBC (tbcItemDB, tbcNpcDB) item class/subclass (equippability), names, vendors (badge vendor,
--                                              PvP faction twins)
--   Questie ContentPhases/BurningCrusade.lua   phases of Ogri'la / Sha'tari Skyguard (2) and Netherwing (3)
--   LoonBestInSlot/DB/ItemSources.lua and the AtlasLoot TBC phase BiS modules: cross-checks only (nothing copied).
--
-- ns.Data.Crafted    = { { key, name, professionID, items = { { id, skill, spec?, phase, spell, reagentsNote? } } } }
--   id = created item; skill = required skill (Profession.lua); spell = craft spell ID;
--   spec = specialisation: Blacksmithing from AtlasLoot's spec sub-tables; Leatherworking (Dragonscale/Elemental/
--          Tribal), Tailoring (Spellfire/Mooncloth/Shadoweave) and Engineering (Gnomish/Goblin) from a small
--          CURATED name list in the generator (no installed data file marks those);
--   phase = AtlasLoot's rule (max phase of recipe source and raid-dropped reagents; source phase = ContentPhaseBC of
--          the instance / faction that provides it), else 1;
--   reagentsNote = reagents that AtlasLoot lists as dungeon/raid drops (Nether Vortex, Heart of Darkness, Sunmote,
--          epic gems);
--   bop is never set: no installed data file carries bind types.
--   Only skill >= 300 recipes of the TBC (BCC) profession tables whose result is equippable gear; items are grouped
--   by spec (general first), AtlasLoot order inside a group.
-- ns.Data.Reputation = { { key, name, factionID, side?, items = { { id, standing, phase } } } }
--   standing = the AtlasLoot section (Friendly/Honored/Revered/Exalted); side = "Alliance"/"Horde" for faction-only
--   reputations; phase = ContentPhaseBC (Shattered Sun 5), Ogri'la/Skyguard 2, Netherwing 3, Ashtongue 3,
--   Scale of the Sands 3 (Friendly ring 2), else 1.  Equippable gear only (no tabards, recipes, enchants, keys);
--   gear with 0 < requiredLevel < 58 (Tranquillien) is dropped.
-- ns.Data.Badges     = { { key, name, npcID, items = { { id, cost, phase } } } }
--   cost = Badges of Justice (VendorPrice.lua); vendor = the Questie vendor of the item that sells the most
--   badge items (G'eras 18525, Anwehu 27667); phase = AtlasLoot table (P1 table 1, "P4" table 4, "P5" table 5).
--   Gems (Ontuvo), Nether Vortex and other non-gear are excluded.
-- ns.Data.PvP        = { { key, name, phase, items = { { id, cost?, faction?, phase } } } }
--   From AtlasLootClassic_PvP/data-tbc.lua (+ ItemSet.lua to expand the set IDs of its "Sets" rows):
--   S1..S4 = the "Season N" arena tables (Gladiator's / Merciless / Vengeful / Brutal sets, weapons, off-hands,
--   relics, necks, rings, trinkets, cloaks and the General's/Marshal's, Veteran's, Vindicator's, Guardian's
--   off-set pieces listed in each season); Honor = Grand Marshal's / High Warlord's honor sets and weapons,
--   Sergeant's cloaks, the PvP insignia (Medallion of the Alliance/Horde); RepPvP = the reputation PvP sets;
--   WorldPvP = Halaa, Spirit Shard, Hellfire and Zangarmarsh rewards.  An item shared by several AtlasLoot tables is
--   listed once (first of: Honor, RepPvP, S1-S4, WorldPvP).
--   phase: AtlasLoot has the season number but no phase -> S1 = 1, S2 = 2, S3 = 3, S4 = 5; every other group 1.
--   cost: only where AtlasLoot has a price (insignia, world PvP tokens/marks, Spirit Shards); arena point costs and
--   personal-rating requirements are NOT in any installed data file, so `rating` is never set.
--   faction: "Alliance"/"Horde" for items listed on one side only (General's vs Marshal's, Grand Marshal's vs
--   High Warlord's, Medallions); nil when both sides can buy it.  Where Questie's vendors show an item is sold to one
--   side only and a same-name twin is sold to the other side, the twin is used for that side (Zangarmarsh marks
--   rewards, Hellfire rings, Honor Hold versions of the Thrallmar reputation PvP pieces).
--   Equippability: Questie class 2/4 as elsewhere; a few items Questie's TBC DB lacks (Mooncloth/Ringmail/Ornamented
--   off-set pieces, two Brutal weapons) are kept because AtlasLoot lists them in a gear section.
local _, ns = ...
ns.Data = ns.Data or {}
"""


# Item-level phase corrections (CDLoot 0.5 final review, Wowhead TBC "Phase N" tags): the 2.1 engineering goggles
# (the generator's default was P1), the 40000-honor Medallions (P5), and a few single items.
PHASE_OVERRIDES = {32461: 2, 32472: 2, 32473: 2, 32474: 2, 32475: 2, 32476: 2, 32478: 2, 32479: 2, 32480: 2,
                   32494: 2, 32495: 2, 37864: 5, 37865: 5, 32973: 2, 35320: 5, 33204: 3}


def apply_phase_overrides(*groups_lists):
    for groups in groups_lists:
        for g in groups:
            for it in g["items"]:
                if it["id"] in PHASE_OVERRIDES:
                    it["phase"] = PHASE_OVERRIDES[it["id"]]


def write_lua(path, crafted, rep, badges, pvp):
    apply_phase_overrides(crafted, rep, badges, pvp)
    L = [HEADER]
    L.append("ns.Data.Crafted = {")
    for g in crafted:
        L.append(f"  {{ key = {lua_str(g['key'])}, name = {lua_str(g['name'])}, professionID = {g['professionID']}, items = {{")
        cur = "__none__"
        for it in g["items"]:
            if it["spec"] != cur:
                cur = it["spec"]
                L.append(f"    -- {g['name']}" + (f" - {cur}" if cur else " (general)"))
            f = [f"id = {it['id']}", f"skill = {it['skill']}"]
            if it["spec"]:
                f.append(f"spec = {lua_str(it['spec'])}")
            f.append(f"phase = {it['phase']}")
            f.append(f"spell = {it['spell']}")
            if it.get("reagentsNote"):
                f.append(f"reagentsNote = {lua_str(it['reagentsNote'])}")
            L.append("    { " + ", ".join(f) + " }, -- " + cmt(it["name"]))
        L.append("  } },")
    L.append("}")
    L.append("")
    L.append("ns.Data.Reputation = {")
    for g in rep:
        side = f", side = {lua_str(g['side'])}" if g.get("side") else ""
        L.append(f"  {{ key = {lua_str(g['key'])}, name = {lua_str(g['name'])}, factionID = {g['factionID']}{side}, items = {{")
        for it in g["items"]:
            L.append(f"    {{ id = {it['id']}, standing = {lua_str(it['standing'])}, phase = {it['phase']} }}, -- " + cmt(it["name"]))
        L.append("  } },")
    L.append("}")
    L.append("")
    L.append("ns.Data.Badges = {")
    for g in badges:
        L.append(f"  {{ key = {lua_str(g['key'])}, name = {lua_str(g['name'])}, npcID = {g['npcID']}, items = {{")
        for it in g["items"]:
            cost = f"cost = {it['cost']}, " if it["cost"] is not None else ""
            L.append(f"    {{ id = {it['id']}, {cost}phase = {it['phase']} }}, -- " + cmt(it["name"]))
        L.append("  } },")
    L.append("}")
    L.append("")
    L.append("ns.Data.PvP = {")
    for g in pvp:
        L.append(f"  {{ key = {lua_str(g['key'])}, name = {lua_str(g['name'])}, phase = {g['phase']}, items = {{")
        for it in g["items"]:
            f = [f"id = {it['id']}"]
            if it.get("cost"):
                f.append(f"cost = {lua_str(it['cost'])}")
            if it.get("faction"):
                f.append(f"faction = {lua_str(it['faction'])}")
            f.append(f"phase = {it['phase']}")
            L.append("    { " + ", ".join(f) + " }, -- " + cmt(it["name"]))
        L.append("  } },")
    L.append("}")
    L.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L))


# --------------------------------------------------------------------------------------
# Validation + cross-checks
# --------------------------------------------------------------------------------------
def validate_lua(path, report):
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    src = open(path, encoding="utf-8").read()
    res = lua.eval("function(s, n) local f, e = loadstring(s, n); return f, e end")(src, "@Sources.lua")
    f, e = res if isinstance(res, tuple) else (res, None)
    if f is None:
        raise SystemExit(f"Lua 5.1 compile error: {e}")
    ns = lua.table()
    f("CDLoot", ns)
    D = ns.Data
    errs, dups = [], []
    kinds = {"Crafted": ("id", "skill", "phase", "spell"), "Reputation": ("id", "standing", "phase"),
             "Badges": ("id", "cost", "phase"), "PvP": ("id", "phase")}
    counts = {}
    for kind, req in kinds.items():
        t = D[kind]
        if t is None:
            errs.append(f"ns.Data.{kind} missing")
            continue
        n = 0
        across = defaultdict(list)
        for gi in range(1, len(t) + 1):
            g = t[gi]
            if not isinstance(g.key, str) or not isinstance(g.name, str):
                errs.append(f"{kind}[{gi}] key/name")
            seen = set()
            for ii in range(1, len(g["items"]) + 1):
                it = g["items"][ii]
                n += 1
                for fld in req:
                    if it[fld] is None and not (kind == "Badges" and fld == "cost"):
                        errs.append(f"{kind}/{g.key}/{it.id}: missing {fld}")
                if it.id in seen:
                    dups.append(f"{kind}/{g.key}: duplicate {it.id}")
                seen.add(it.id)
                across[int(it.id)].append(g.key)
                if not (isinstance(it.phase, int) and 1 <= it.phase <= 5):
                    errs.append(f"{kind}/{g.key}/{it.id}: bad phase {it.phase}")
                if kind == "Reputation" and it.standing not in STANDING_RANK:
                    errs.append(f"{kind}/{g.key}/{it.id}: bad standing {it.standing}")
                if kind == "PvP" and it.faction not in (None, "Alliance", "Horde"):
                    errs.append(f"{kind}/{g.key}/{it.id}: bad faction {it.faction}")
                if kind == "PvP" and it.cost is not None and not isinstance(it.cost, str):
                    errs.append(f"{kind}/{g.key}/{it.id}: cost not a string")
        counts[kind] = n
        report["validation"][f"{kind}_ids_in_several_groups"] = {str(k): v for k, v in across.items() if len(v) > 1}
    report["validation"]["errors"] = errs
    report["validation"]["duplicates_within_list"] = dups
    report["validation"]["counts"] = counts
    return lua, ns


def load_loon_all():
    """LoonBestInSlot ItemSources (CROSS-CHECK ONLY).  Handles concatenated fields (LBIS.L["A"].."~"..LBIS.L["B"])."""
    rx = re.compile(r'^\s*\[(\d+)\]\s*=\s*\{\s*Name\s*=\s*"((?:\\.|[^"\\])*)"\s*,\s*SourceType\s*=\s*(.*?)\s*,\s*Source\s*=\s*(.*?)'
                    r'\s*,\s*SourceNumber\s*=\s*"([^"]*)"\s*,\s*SourceLocation\s*=\s*(.*?)\s*,\s*SourceFaction\s*=\s*"([^"]*)"', re.M)

    def L(expr):
        return "".join(a or b for a, b in re.findall(r'LBIS\.L\["([^"]*)"\]|"([^"]*)"', expr))
    out = {}
    for m in rx.finditer(read(G.P_LOON_SOURCES)):
        out[int(m.group(1))] = {"name": m.group(2).replace('\\"', '"'), "type": L(m.group(3)), "source": L(m.group(4)),
                                "number": m.group(5), "location": L(m.group(6)), "faction": m.group(7)}
    return out


def loon_crosscheck(loon, crafted, rep, badges, pvp, Q, PROF, report):
    ours = {"Profession": {it["id"]: (g, it) for g in crafted for it in g["items"]},
            "Reputation": {it["id"]: (g, it) for g in rep for it in g["items"]},
            "Badge": {it["id"]: (g, it) for g in badges for it in g["items"]},
            "PvP": {it["id"]: (g, it) for g in pvp for it in g["items"]}}
    created_to_spell = {}
    for sp, pv in PROF.items():
        if pv["item"]:
            created_to_spell.setdefault(pv["item"], []).append(sp)
    excl = {"Profession": {e.get("item"): e["reason"] for e in report["crafted_excluded"] if e.get("item")},
            "Reputation": {e["id"]: e["reason"] for e in report["rep_excluded"]},
            "Badge": {e["id"]: e["reason"] for e in report["badges_excluded"]},
            "PvP": {e["id"]: e["reason"] for e in report["pvp_excluded"]}}
    tbc_factions = {v[1] for v in FACTIONS.values()}

    def classify(kind, iid, e):
        if iid in ours[kind]:
            return "present", None
        other = [k for k in ours if k != kind and iid in ours[k]]
        if other:
            return "present-other-table", f"in our {other[0]} table"
        q = Q.get(iid)
        if kind == "Profession":
            sps = created_to_spell.get(iid, [])
            vers = {PROF[s]["ver"] for s in sps}
            if sps and "BCC" not in vers:
                return "out-of-scope", f"{'/'.join(sorted(vers))} (non-TBC) recipe"
            if iid in excl[kind]:
                return "excluded", excl[kind][iid]
            if not sps:
                return "missing", "no craft spell creates it in AtlasLoot's Profession.lua"
            ok, why = equip_check(iid, Q)
            if not ok:
                return "excluded", why
            sk = min(PROF[s]["skill"] for s in sps if PROF[s]["ver"] == "BCC")
            if sk < MIN_CRAFT_SKILL:
                return "out-of-scope", f"skill {sk} < {MIN_CRAFT_SKILL}"
            if PROF[sps[0]]["prof"] not in PROF_ID_TO_KEY:
                return "out-of-scope", f"profession {PROF[sps[0]]['prof']} not in scope"
            return "missing", "TBC craft spell not listed in AtlasLoot's crafting tables"
        if kind == "Reputation":
            if e["source"].split("~")[0] not in tbc_factions:
                return "out-of-scope", f"non-TBC faction {e['source']}"
            if iid in excl[kind]:
                return "excluded", excl[kind][iid]
            return "missing", "not listed in AtlasLoot's TBC faction tables"
        if kind == "Badge":
            if iid in excl[kind]:
                return "excluded", excl[kind][iid]
            ok, why = equip_check(iid, Q)
            if not ok:
                return "excluded", why
            return "missing", "no BoJ price in AtlasLoot VendorPrice.lua and not in AtlasLoot's badge tables"
        if kind == "PvP":
            if q and q["req"] < 61 and q["ilvl"] < 100:
                return "out-of-scope", "pre-TBC PvP item"
            if iid in excl[kind]:
                return "excluded", excl[kind][iid]
            ok, why = equip_check(iid, Q)
            if not ok:
                return "excluded", why
            return "missing", "not in AtlasLoot's TBC PvP tables"
    detail = defaultdict(list)
    for iid, e in loon.items():
        kinds = []
        if "Profession" in e["type"]:
            kinds.append("Profession")
        if "Reputation" in e["type"]:
            kinds.append("Reputation")
        if "Dungeon Token" in e["type"] and "Badge of Justice" in e["source"]:
            kinds.append("Badge")
        if "PvP" in e["type"]:
            kinds.append("PvP")
        for kind in kinds:
            status, why = classify(kind, iid, e)
            row = {"id": iid, "name": e["name"], "status": status, "reason": why,
                   "loon": f"{e['type']} | {e['source']} | {e['number']} | {e['location']}"}
            if status == "present":
                g, it = ours[kind][iid]
                if kind == "Profession":
                    m = re.search(r"\((\d+)\)", e["source"])
                    if m and int(m.group(1)) != it["skill"]:
                        row["mismatch"] = f"skill Loon {m.group(1)} vs ours {it['skill']}"
                    if e["location"].isdigit() and int(e["location"]) != it["spell"]:
                        row["mismatch"] = (row.get("mismatch", "") + f" spell Loon {e['location']} vs ours {it['spell']}").strip()
                elif kind == "Reputation":
                    if e["location"] != it["standing"]:
                        row["mismatch"] = f"standing Loon {e['location']} vs ours {it['standing']}"
                    if e["source"] != g["name"]:
                        row["mismatch"] = (row.get("mismatch", "") + f" faction Loon {e['source']} vs ours {g['name']}").strip()
                elif kind == "Badge":
                    num = e["number"].split("~")[0]
                    if num.isdigit() and it["cost"] is not None and int(num) != it["cost"]:
                        row["mismatch"] = f"cost Loon {num} vs ours {it['cost']}"
                    loc = e["location"].split("~")[0]
                    if loc and loc != g["name"]:
                        row["vendorDiffers"] = f"Loon {loc} vs ours {g['name']}"
                elif kind == "PvP":
                    lf = {"A": "Alliance", "H": "Horde"}.get(e["faction"])
                    if lf and it.get("faction") and lf != it["faction"]:
                        row["mismatch"] = f"faction Loon {lf} vs ours {it['faction']}"
            detail[kind].append(row)
    res = {}
    for kind, rows in detail.items():
        c = Counter(r["status"] for r in rows)
        in_scope = [r for r in rows if r["status"] != "out-of-scope"]
        pres = c.get("present", 0) + c.get("present-other-table", 0)
        res[kind] = {"loon_total": len(rows), "status_counts": dict(c), "in_scope": len(in_scope), "present": pres,
                     "coverage_in_scope_pct": round(100.0 * pres / max(1, len(in_scope)), 1),
                     "not_present_reasons": dict(Counter(r["reason"] for r in rows if r["status"] in ("missing", "excluded"))),
                     "not_present": [r for r in rows if r["status"] in ("missing", "excluded")],
                     "present_other_table": dict(Counter(r["reason"] for r in rows if r["status"] == "present-other-table")),
                     "out_of_scope_reasons": dict(Counter(r["reason"] for r in rows if r["status"] == "out-of-scope")),
                     "field_mismatches": [r for r in rows if r.get("mismatch")],
                     "vendor_differs": dict(Counter(r["vendorDiffers"] for r in rows if r.get("vendorDiffers")))}
    report["loon"] = res


def spot_check(crafted, rep, badges, pvp, Q, PROF, PRICES, report):
    craft_lines = read(P_CRAFTING).splitlines()
    fac_lines = read(P_FACTIONS).splitlines()
    col_lines = read(P_COLLECTIONS).splitlines()
    pvp_lines = read(P_PVP).splitlines()
    vp = read(P_VENDORPRICE)
    picks = {"Crafted": [28425, 28485, 24266, 29525, 34358, 23829, 35751],  # spot items (if present)
             "Reputation": [29124, 29301, 32654, 32770],
             "Badges": [29383, 34887, 33810],
             "PvP": [28312, 33066, 28235, 27649]}
    by = {"Crafted": {it["id"]: (g, it) for g in crafted for it in g["items"]},
          "Reputation": {it["id"]: (g, it) for g in rep for it in g["items"]},
          "Badges": {it["id"]: (g, it) for g in badges for it in g["items"]},
          "PvP": {it["id"]: (g, it) for g in pvp for it in g["items"]}}
    out = []
    for kind, ids in picks.items():
        for iid in ids:
            if iid not in by[kind]:
                out.append({"kind": kind, "id": iid, "status": "NOT IN OUTPUT"})
                continue
            g, it = by[kind][iid]
            ent = {"kind": kind, "id": iid, "name": it["name"], "group": g["key"], "phase": it["phase"], "phaseWhy": it.get("phaseWhy")}
            if kind == "Crafted":
                ent.update({"skill": it["skill"], "spec": it["spec"], "spell": it["spell"]})
                ln = it.get("line")
                ent["atlasloot_row"] = craft_lines[ln - 1].strip() if ln else "(supplement)"
                pv = PROF[it["spell"]]
                ent["profession_lua"] = f"[{it['spell']}] = {{ {pv['item']}, prof {pv['prof']}, skill {pv['skill']} ... }}"
                ent["ok"] = pv["item"] == iid and pv["skill"] == it["skill"] and (not ln or str(it["spell"]) in craft_lines[ln - 1])
            elif kind == "Reputation":
                ent.update({"standing": it["standing"]})
                ln = it["line"]
                ent["atlasloot_row"] = fac_lines[ln - 1].strip()
                # nearest preceding standing marker
                j = ln - 1
                while j > 0 and "rep" not in fac_lines[j - 1] and "name = ALIL" not in fac_lines[j - 1]:
                    j -= 1
                ent["atlasloot_section"] = fac_lines[j - 1].strip()
                ent["ok"] = str(iid) in fac_lines[ln - 1] and it["standing"] in fac_lines[j - 1] or \
                    STANDING_RANK[it["standing"]] == int((re.search(r"rep(\d)", fac_lines[j - 1]) or [0, 0])[1] or 0)
            elif kind == "PvP":
                ent.update({"cost": it.get("cost"), "faction": it.get("faction"), "section": it.get("section")})
                ln = it.get("line")
                ent["atlasloot_row"] = pvp_lines[ln - 1].strip() if ln else None
                ent["ok"] = bool(ln) and (str(iid) in pvp_lines[ln - 1] or "set " in (it.get("section") or ""))
            else:
                ent.update({"cost": it["cost"], "vendor": g["name"]})
                ln = it.get("line")
                ent["atlasloot_row"] = col_lines[ln - 1].strip() if ln else None
                m = re.search(r"^\s*\[%d\]\s*=\s*\"([^\"]*)\"" % iid, vp, re.M)
                ent["vendorprice_row"] = m.group(0).strip() if m else None
                ent["questie_vendors"] = (Q.get(iid) or {}).get("vendors")
                ent["ok"] = bool(m) and f"BoJ:{it['cost']}" in m.group(1) and g["npcID"] in ent["questie_vendors"]
            out.append(ent)
    report["spot_checks"] = out


# --------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT_LUA_DEFAULT)
    ap.add_argument("--no-curated-specs", action="store_true")
    args = ap.parse_args()
    report = defaultdict(list)
    report["warnings"] = []
    report["validation"] = {}
    report["pvp_phase_source"] = {}

    Q = load_questie_items()
    NPC = load_questie_npcs_full()
    PROF = load_professions()
    REC_BY_SPELL, _ = load_recipes()
    PRICES = load_vendor_prices()
    LOOT = load_loot_sources()
    PHASEMOD = load_phase_module_items()
    markers = load_questie_phase_markers()
    lua_tmp = lua51.LuaRuntime(unpack_returned_tuples=True)
    RAID_IDS, DUNG_IDS = load_cdloot_ids(lua_tmp)
    raid_phases = {}
    if os.path.exists(P_RAID_ITEMS):
        for m in re.finditer(r'^\s*\{ key = "([^"]+)", name = "[^"]*", phase = (\d+)', read(P_RAID_ITEMS), re.M):
            raid_phases[m.group(1)] = int(m.group(2))

    rep, FAC_RECIPE_PHASE = build_reputation(Q, markers, raid_phases, report)
    crafted = build_crafted(Q, PROF, REC_BY_SPELL, LOOT, FAC_RECIPE_PHASE, not args.no_curated_specs, report)
    badges, _, _ = build_badges(Q, NPC, PRICES, report)
    pvp = build_pvp(Q, NPC, PRICES, report)

    write_lua(args.out, crafted, rep, badges, pvp)
    validate_lua(args.out, report)

    # phase-module consistency (our phase must not be later than the earliest BiS list that already uses the item)
    ALL = (("Crafted", crafted), ("Reputation", rep), ("Badges", badges), ("PvP", pvp))
    for kind, groups in ALL:
        for g in groups:
            for it in g["items"]:
                pm = PHASEMOD.get(it["id"])
                if pm is not None:
                    report["phase_module_hits"].append(1)
                    if it["phase"] > pm:
                        report["phase_conflicts"].append({"kind": kind, "group": g["key"], "id": it["id"], "name": it["name"],
                                                          "ours": it["phase"], "earliest_bis_list_phase": pm, "why": it.get("phaseWhy")})
    report["phase_module_hits"] = len(report["phase_module_hits"])
    # overlaps with raid / dungeon data
    for kind, groups in ALL:
        for g in groups:
            for it in g["items"]:
                if it["id"] in RAID_IDS or it["id"] in DUNG_IDS:
                    report["overlap_raid_dungeon"].append({"kind": kind, "group": g["key"], "id": it["id"], "name": it["name"],
                                                           "raid": RAID_IDS.get(it["id"]), "dungeon": DUNG_IDS.get(it["id"])})
    # ids shared between our own four tables
    where = defaultdict(list)
    for kind, groups in ALL:
        for g in groups:
            for it in g["items"]:
                where[it["id"]].append(f"{kind}/{g['key']}")
    report["shared_between_kinds"] = {str(k): v for k, v in where.items() if len({x.split('/')[0] for x in v}) > 1}
    loon_crosscheck(load_loon_all(), crafted, rep, badges, pvp, Q, PROF, report)
    spot_check(crafted, rep, badges, pvp, Q, PROF, PRICES, report)

    # summaries
    summ = {"crafted": {g["key"]: {"items": len(g["items"]), "by_spec": dict(Counter(it["spec"] or "(general)" for it in g["items"])),
                                   "by_phase": dict(sorted(Counter(it["phase"] for it in g["items"]).items()))} for g in crafted},
            "reputation": {g["key"]: {"items": len(g["items"]), "by_phase": dict(sorted(Counter(it["phase"] for it in g["items"]).items())),
                                      "by_standing": dict(Counter(it["standing"] for it in g["items"]))} for g in rep},
            "badges": {g["key"]: {"npcID": g["npcID"], "items": len(g["items"]),
                                  "by_phase": dict(sorted(Counter(it["phase"] for it in g["items"]).items()))} for g in badges},
            "pvp": {g["key"]: {"items": len(g["items"]), "phase": g["phase"], "with_cost": sum(1 for it in g["items"] if it.get("cost")),
                               "by_faction": dict(Counter(it.get("faction") or "both" for it in g["items"]))} for g in pvp},
            "pvp_excluded_reasons": dict(Counter(e["reason"] for e in report["pvp_excluded"])),
            "crafted_phase_provenance": dict(Counter(re.sub(r"\[.*?\]|\d{4,}|\(.*?\)", "", it["phaseWhy"]).split(" from ")[0].strip()
                                                     for g in crafted for it in g["items"])),
            "crafted_excluded_reasons": dict(Counter(re.sub(r"\d+", "N", e["reason"]) for e in report["crafted_excluded"])),
            "rep_excluded_reasons": dict(Counter(e["reason"] for e in report["rep_excluded"])),
            "badges_excluded_reasons": dict(Counter(e["reason"] for e in report["badges_excluded"]))}
    report["summary"] = summ
    report["crafted_phase_detail"] = [{"prof": g["key"], "id": it["id"], "name": it["name"], "phase": it["phase"], "why": it["phaseWhy"]}
                                      for g in crafted for it in g["items"] if it["phase"] != 1]
    with open(OUT_REPORT, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, default=str)
    v = report["validation"]
    print(f"wrote {args.out}")
    print(f"  counts={v['counts']} errors={len(v['errors'])} dups={len(v['duplicates_within_list'])}")
    for k in ("crafted", "reputation", "badges", "pvp"):
        print(f"  {k}: " + ", ".join(f"{g}={d['items']}" for g, d in summ[k].items()))
    print(f"  overlap raid/dungeon: {len(report['overlap_raid_dungeon'])}; phase conflicts: {len(report['phase_conflicts'])}; warnings: {len(report['warnings'])}")
    for kind, r in report["loon"].items():
        print(f"  Loon {kind}: total {r['loon_total']} in-scope {r['in_scope']} present {r['present']} ({r['coverage_in_scope_pct']}%) {r['status_counts']}")
    print(f"  spot-checks ok: {sum(1 for s in report['spot_checks'] if s.get('ok'))}/{len(report['spot_checks'])}")


if __name__ == "__main__":
    main()
