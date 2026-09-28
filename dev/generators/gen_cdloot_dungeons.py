#!/usr/bin/env python3
"""
Generator for CDLoot's embedded TBC 5-man dungeon loot database (SPEC_ADDENDUM_B section 21.1).

Companion of gen_cdloot_data.py (raids): it IMPORTS that module and reuses its Lua tokenizer/parser,
text resolver, Questie loaders and DBM helper. The raid generator and its output are not touched.

Reads (read-only) from the installed WoW AddOns folder:
  * AtlasLootClassic_DungeonsAndRaids/data-tbc.lua   -> dungeons (ContentType = DUNGEON_CONTENT), bosses, loot rows
  * Questie/Database/TBC/tbcItemDB.lua               -> item class (gem detection), names, npc/object drop sources
  * Questie/Database/TBC/tbcNpcDB.lua                -> npc names (heroic "(1)" variants), zone check
  * Questie/Database/TBC/tbcObjectDB.lua             -> chest object names / zones
  * DBM-Party-BC/*  (NOT installed here; used automatically if it appears) -> SetCreatureID / SetEncounterID
  * AtlasLootClassic_Data/source-tbc.lua             -> cross-check (boss + difficulty attribution)
  * LoonBestInSlot/DB/ItemSources.lua                -> cross-check (boss + "(H)" attribution)
  * CDLoot/Data/Items.lua                            -> raid item IDs (overlap report only; never written)

Writes:
  * <ADDON>/Data/Dungeons.lua              (the only file written inside the addon)
  * <SCRATCH>/gen_dungeons_report.json     (skips, cross-checks, shared items, spot-checks)

Usage:  python gen_cdloot_dungeons.py [--out PATH]
"""
import argparse
import json
import os
import re
import sys
from collections import OrderedDict, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_cdloot_data as G  # noqa: E402  (raid generator; main() is __name__-guarded)
from gen_cdloot_data import LuaTable, Parser, tokenize, resolve_text, find_assignment, read  # noqa: E402

ADDONS = G.ADDONS
ADDON_DIR = os.path.join(ADDONS, "CDLoot")
OUT_LUA_DEFAULT = os.path.join(ADDON_DIR, "Data", "Dungeons.lua")
OUT_REPORT = os.path.join(HERE, "gen_dungeons_report.json")
P_RAID_ITEMS = os.path.join(ADDON_DIR, "Data", "Items.lua")
P_QUESTIE_NPCS = os.path.join(ADDONS, "Questie", "Database", "TBC", "tbcNpcDB.lua")
P_DBM_PARTY_BC = os.path.join(ADDONS, "DBM-Party-BC")
P_DBM_TEST_INSTANCES = os.path.join(ADDONS, "DBM-Test", "Tools", "Shared", "Data", "Instances.lua")

# --------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------
# AtlasLoot data key -> (CDLoot key, display name, Loon SourceLocation base name)
DUNGEONS = OrderedDict([
    ("HellfireRamparts",      ("HellfireRamparts", "Hellfire Ramparts",       "Hellfire Ramparts")),
    ("TheBloodFurnace",       ("BloodFurnace",     "The Blood Furnace",       "The Blood Furnace")),
    ("TheShatteredHalls",     ("ShatteredHalls",   "The Shattered Halls",     "The Shattered Halls")),
    ("Mana-Tombs",            ("ManaTombs",        "Mana-Tombs",              "Mana Tombs")),
    ("AuchenaiCrypts",        ("AuchenaiCrypts",   "Auchenai Crypts",         "Auchenai Crypts")),
    ("SethekkHalls",          ("SethekkHalls",     "Sethekk Halls",           "Sethekk Halls")),
    ("ShadowLabyrinth",       ("ShadowLabyrinth",  "Shadow Labyrinth",        "Shadow Labyrinth")),
    ("TheSlavePens",          ("SlavePens",        "The Slave Pens",          "The Slave Pens")),
    ("TheUnderbog",           ("Underbog",         "The Underbog",            "The Underbog")),
    ("TheSteamvault",         ("Steamvault",       "The Steamvault",          "The Steamvault")),
    ("OldHillsbradFoothills", ("OldHillsbrad",     "Old Hillsbrad Foothills", "Old Hillsbrad Foothills")),
    ("TheBlackMorass",        ("BlackMorass",      "The Black Morass",        "The Black Morass")),
    ("TheArcatraz",           ("Arcatraz",         "The Arcatraz",            "The Arcatraz")),
    ("TheBotanica",           ("Botanica",         "The Botanica",            "The Botanica")),
    ("TheMechanar",           ("Mechanar",         "The Mechanar",            "The Mechanar")),
    ("MagistersTerrace",      ("MagistersTerrace", "Magisters' Terrace",      "Magisters' Terrace")),
])

# (AtlasLoot dungeon key, English boss name) -> (CDLoot boss key, DBM-Party-BC mod file or None)
# DBM-Party-BC is not installed on this machine; file names follow DBM's usual layout and are only
# used if the folder appears later (dbm_ids() returns nothing for missing files).
BOSS_META = {
    ("HellfireRamparts", "Watchkeeper Gargolmar"): ("Gargolmar", "DBM-Party-BC/Hellfire_Ramparts/watchkeeper.lua"),
    ("HellfireRamparts", "Omor the Unscarred"):    ("Omor", "DBM-Party-BC/Hellfire_Ramparts/omor.lua"),
    ("HellfireRamparts", "Nazan & Vazruden"):      ("NazanVazruden", "DBM-Party-BC/Hellfire_Ramparts/vazruden.lua"),
    ("TheBloodFurnace", "The Maker"):              ("Maker", "DBM-Party-BC/Blood_Furnace/Maker.lua"),
    ("TheBloodFurnace", "Broggok"):                ("Broggok", "DBM-Party-BC/Blood_Furnace/Broggok.lua"),
    ("TheBloodFurnace", "Keli'dan the Breaker"):   ("Kelidan", "DBM-Party-BC/Blood_Furnace/Breaker.lua"),
    ("TheShatteredHalls", "Grand Warlock Nethekurse"):     ("Nethekurse", "DBM-Party-BC/Shattered_Halls/Nethekurse.lua"),
    ("TheShatteredHalls", "Blood Guard Porung"):           ("Porung", "DBM-Party-BC/Shattered_Halls/Porung.lua"),
    ("TheShatteredHalls", "Warbringer O'mrogg"):           ("Omrogg", "DBM-Party-BC/Shattered_Halls/Omrogg.lua"),
    ("TheShatteredHalls", "Warchief Kargath Bladefist"):   ("Kargath", "DBM-Party-BC/Shattered_Halls/Kargath.lua"),
    ("TheShatteredHalls", "Shattered Hand Executioner"):   ("Executioner", None),
    ("TheShatteredHalls", "Trash"):                        ("Trash", None),
    ("Mana-Tombs", "Pandemonius"):                  ("Pandemonius", "DBM-Party-BC/Auct_ManaTombs/Pandemonius.lua"),
    ("Mana-Tombs", "Tavarok"):                      ("Tavarok", "DBM-Party-BC/Auct_ManaTombs/Tavarok.lua"),
    ("Mana-Tombs", "Nexus-Prince Shaffar"):         ("Shaffar", "DBM-Party-BC/Auct_ManaTombs/Shaffar.lua"),
    ("Mana-Tombs", "Yor <Void Hound of Shaffar>"):  ("Yor", "DBM-Party-BC/Auct_ManaTombs/Yor.lua"),
    ("Mana-Tombs", "Trash"):                        ("Trash", None),
    ("AuchenaiCrypts", "Shirrak the Dead Watcher"): ("Shirrak", "DBM-Party-BC/Auct_Crypts/Shirrak.lua"),
    ("AuchenaiCrypts", "Exarch Maladaar"):          ("Maladaar", "DBM-Party-BC/Auct_Crypts/Maladaar.lua"),
    ("AuchenaiCrypts", "Avatar of the Martyred"):   ("AvatarOfTheMartyred", None),
    ("AuchenaiCrypts", "Trash"):                    ("Trash", None),
    ("SethekkHalls", "Darkweaver Syth"):            ("Syth", "DBM-Party-BC/Auct_SethekkHalls/Syth.lua"),
    ("SethekkHalls", "Talon King Ikiss"):           ("Ikiss", "DBM-Party-BC/Auct_SethekkHalls/Ikiss.lua"),
    ("SethekkHalls", "Anzu"):                       ("Anzu", "DBM-Party-BC/Auct_SethekkHalls/Anzu.lua"),
    ("SethekkHalls", "The Saga of Terokk"):         ("SagaOfTerokk", None),
    ("SethekkHalls", "Trash"):                      ("Trash", None),
    ("ShadowLabyrinth", "Ambassador Hellmaw"):      ("Hellmaw", "DBM-Party-BC/Auct_ShadowLabyrinth/Hellmaw.lua"),
    ("ShadowLabyrinth", "Blackheart the Inciter"):  ("Blackheart", "DBM-Party-BC/Auct_ShadowLabyrinth/Inciter.lua"),
    ("ShadowLabyrinth", "Grandmaster Vorpil"):      ("Vorpil", "DBM-Party-BC/Auct_ShadowLabyrinth/Vorpil.lua"),
    ("ShadowLabyrinth", "Murmur"):                  ("Murmur", "DBM-Party-BC/Auct_ShadowLabyrinth/Murmur.lua"),
    ("ShadowLabyrinth", "First Fragment Guardian"): ("FirstFragmentGuardian", None),
    ("ShadowLabyrinth", "Trash"):                   ("Trash", None),
    ("TheSlavePens", "Mennu the Betrayer"):         ("Mennu", "DBM-Party-BC/Coil_Slavepens/Mennu.lua"),
    ("TheSlavePens", "Rokmar the Crackler"):        ("Rokmar", "DBM-Party-BC/Coil_Slavepens/Rokmar.lua"),
    ("TheSlavePens", "Quagmirran"):                 ("Quagmirran", "DBM-Party-BC/Coil_Slavepens/Quagmirran.lua"),
    ("TheUnderbog", "Hungarfen"):                   ("Hungarfen", "DBM-Party-BC/Coil_Underbog/Hungarfen.lua"),
    ("TheUnderbog", "Ghaz'an"):                     ("Ghazan", "DBM-Party-BC/Coil_Underbog/Ghazan.lua"),
    ("TheUnderbog", "Swamplord Musel'ek"):          ("Muselek", "DBM-Party-BC/Coil_Underbog/Muselek.lua"),
    ("TheUnderbog", "The Black Stalker"):           ("BlackStalker", "DBM-Party-BC/Coil_Underbog/Stalker.lua"),
    ("TheSteamvault", "Hydromancer Thespia"):       ("Thespia", "DBM-Party-BC/Coil_Steamvault/Thespia.lua"),
    ("TheSteamvault", "Mekgineer Steamrigger"):     ("Steamrigger", "DBM-Party-BC/Coil_Steamvault/Steamrigger.lua"),
    ("TheSteamvault", "Warlord Kalithresh"):        ("Kalithresh", "DBM-Party-BC/Coil_Steamvault/Kalithresh.lua"),
    ("TheSteamvault", "Trash"):                     ("Trash", None),
    ("OldHillsbradFoothills", "Lieutenant Drake"):  ("Drake", "DBM-Party-BC/CoT_OldHillsbrad/Drake.lua"),
    ("OldHillsbradFoothills", "Captain Skarloc"):   ("Skarloc", "DBM-Party-BC/CoT_OldHillsbrad/Skarloc.lua"),
    ("OldHillsbradFoothills", "Epoch Hunter"):      ("EpochHunter", "DBM-Party-BC/CoT_OldHillsbrad/EpochHunter.lua"),
    ("OldHillsbradFoothills", "Don Carlos"):        ("DonCarlos", None),
    ("OldHillsbradFoothills", "Trash"):             ("Trash", None),
    ("TheBlackMorass", "Chrono Lord Deja"):         ("Deja", "DBM-Party-BC/CoT_BlackMorass/Deja.lua"),
    ("TheBlackMorass", "Temporus"):                 ("Temporus", "DBM-Party-BC/CoT_BlackMorass/Temporus.lua"),
    ("TheBlackMorass", "Aeonus"):                   ("Aeonus", "DBM-Party-BC/CoT_BlackMorass/Aeonus.lua"),
    ("TheBlackMorass", "Trash"):                    ("Trash", None),
    ("TheArcatraz", "Zereketh the Unbound"):        ("Zereketh", "DBM-Party-BC/TK_Arcatraz/Zereketh.lua"),
    ("TheArcatraz", "Dalliah the Doomsayer"):       ("Dalliah", "DBM-Party-BC/TK_Arcatraz/Dalliah.lua"),
    ("TheArcatraz", "Wrath-Scryer Soccothrates"):   ("Soccothrates", "DBM-Party-BC/TK_Arcatraz/Soccothrates.lua"),
    ("TheArcatraz", "Harbinger Skyriss"):           ("Skyriss", "DBM-Party-BC/TK_Arcatraz/Skyriss.lua"),
    ("TheArcatraz", "Third Fragment Guardian"):     ("ThirdFragmentGuardian", None),
    ("TheArcatraz", "Trash"):                       ("Trash", None),
    ("TheBotanica", "Commander Sarannis"):          ("Sarannis", "DBM-Party-BC/TK_Botanica/Sarannis.lua"),
    ("TheBotanica", "High Botanist Freywinn"):      ("Freywinn", "DBM-Party-BC/TK_Botanica/Freywinn.lua"),
    ("TheBotanica", "Thorngrin the Tender"):        ("Thorngrin", "DBM-Party-BC/TK_Botanica/Thorngrin.lua"),
    ("TheBotanica", "Laj"):                         ("Laj", "DBM-Party-BC/TK_Botanica/Laj.lua"),
    ("TheBotanica", "Warp Splinter"):               ("WarpSplinter", "DBM-Party-BC/TK_Botanica/WarpSplinter.lua"),
    ("TheBotanica", "Trash"):                       ("Trash", None),
    ("TheMechanar", "Mechano-Lord Capacitus"):      ("Capacitus", "DBM-Party-BC/TK_Mechanar/Capacitus.lua"),
    ("TheMechanar", "Nethermancer Sepethrea"):      ("Sepethrea", "DBM-Party-BC/TK_Mechanar/Sepethrea.lua"),
    ("TheMechanar", "Pathaleon the Calculator"):    ("Pathaleon", "DBM-Party-BC/TK_Mechanar/Pathaleon.lua"),
    ("TheMechanar", "Cache of the Legion"):         ("CacheOfTheLegion", None),
    ("TheMechanar", "Gatewatcher Gyro-Kill"):       ("GyroKill", "DBM-Party-BC/TK_Mechanar/Gyrokill.lua"),
    ("TheMechanar", "Gatewatcher Iron-Hand"):       ("IronHand", "DBM-Party-BC/TK_Mechanar/Ironhand.lua"),
    ("TheMechanar", "Overcharged Manacell"):        ("OverchargedManacell", None),
    ("TheMechanar", "Trash"):                       ("Trash", None),
    ("MagistersTerrace", "Selin Fireheart"):        ("Selin", "DBM-Party-BC/MagistersTerrace/Selin.lua"),
    ("MagistersTerrace", "Vexallus"):               ("Vexallus", "DBM-Party-BC/MagistersTerrace/Vexallus.lua"),
    ("MagistersTerrace", "Priestess Delrissa"):     ("Delrissa", "DBM-Party-BC/MagistersTerrace/Delrissa.lua"),
    ("MagistersTerrace", "Kael'thas Sunstrider"):   ("Kaelthas", "DBM-Party-BC/MagistersTerrace/Kael.lua"),
    ("MagistersTerrace", "Trash"):                  ("Trash", None),
}

# Display-name overrides (strip AtlasLoot's "<subtitle>")
NAME_OVERRIDE = {
    ("Mana-Tombs", "Yor <Void Hound of Shaffar>"): "Yor",
}

SKIP_ITEMS = dict(G.SKIP_ITEMS)  # 29434 Badge of Justice
# Questie item class IDs (QuestieDB.itemKeys class = 12): 3 = Gem.  Currency in TBC is a class-15 item
# (Badge of Justice), handled by SKIP_ITEMS; no other currency item appears in the dungeon lists.
QUESTIE_CLASS_GEM = 3
QUESTIE_CLASS_NAMES = {0: "Consumable", 1: "Container", 2: "Weapon", 3: "Gem", 4: "Armor", 5: "Reagent",
                       6: "Projectile", 7: "Trade Goods", 9: "Recipe", 11: "Quiver", 12: "Quest", 13: "Key",
                       15: "Miscellaneous"}

DIFF_FIELD = {"NORMAL_DIFF": "items", "HEROIC_DIFF": "heroicItems"}

# LoonBestInSlot boss spellings -> AtlasLoot boss name (lower-case), cross-check only
LOON_BOSS_ALIASES = {
    "vazruden": "nazan & vazruden",
    "nazan": "nazan & vazruden",
    "vazruden the herald": "nazan & vazruden",
    "yor": "yor <void hound of shaffar>",
    "the gatewatchers": "cache of the legion",   # the Cache spawns when both Gatewatchers are dead
}


# --------------------------------------------------------------------------------------
# Loaders
# --------------------------------------------------------------------------------------
class LazyRows(dict):
    """id -> parsed row, parsed on first access from the single-line `[id] = {...},` rows of a Questie DB."""

    def __init__(self, path, conv):
        super().__init__()
        self.raw = {}
        self.conv = conv
        if os.path.exists(path):
            for m in re.finditer(r"^\[(\d+)\] = (\{.*\}),?[ 	]*$", read(path), re.M):
                self.raw[int(m.group(1))] = m.group(2)

    def __contains__(self, k):
        return k in self.raw

    def get(self, k, default=None):
        if k not in self.raw:
            return default
        if not dict.__contains__(self, k):
            toks, _ = tokenize(self.raw[k])
            try:
                self[k] = self.conv(Parser(toks).parse_table().array)
            except Exception:
                self[k] = default
        return dict.get(self, k, default)

    def __getitem__(self, k):
        return self.get(k)


def _at(arr, i):
    return arr[i] if i < len(arr) else None


def _nums(v):
    return [int(x) for x in v.array] if isinstance(v, LuaTable) else []


def _str(v):
    return v[1] if isinstance(v, tuple) and v[0] == "str" else None


def load_questie_items_full():
    """itemID -> dict(name, npc, obj, cls, sub)  (QuestieDB.itemKeys: 1 name, 2 npcDrops, 3 objectDrops, 12 class, 13 subClass)."""
    return LazyRows(G.P_QUESTIE_ITEMS, lambda a: {
        "name": _str(_at(a, 0)), "npc": _nums(_at(a, 1)), "obj": _nums(_at(a, 2)),
        "cls": _at(a, 11) if isinstance(_at(a, 11), int) else None,
        "sub": _at(a, 12) if isinstance(_at(a, 12), int) else None})


def load_questie_npcs():
    """npcID -> (name, zoneID)  (QuestieDB.npcKeys: 1 name, 9 zoneID)."""
    return LazyRows(P_QUESTIE_NPCS, lambda a: (_str(_at(a, 0)), _at(a, 8) if isinstance(_at(a, 8), int) else None))


def load_questie_objects():
    """objectID -> (name, zoneID)  (QuestieDB.objectKeys: 1 name, 5 zoneID)."""
    return LazyRows(G.P_QUESTIE_OBJECTS, lambda a: (_str(_at(a, 0)), _at(a, 4) if isinstance(_at(a, 4), int) else None))


def load_raid_item_ids():
    """itemID -> [raidKey/bossKey] from CDLoot/Data/Items.lua (ns.Data.Raids section only; read-only)."""
    out = defaultdict(list)
    if not os.path.exists(P_RAID_ITEMS):
        return out
    text = read(P_RAID_ITEMS)
    a = text.find("ns.Data.Raids = {")
    b = text.find("\nns.Data.Tokens", a)
    region = text[a:b if b > 0 else len(text)]
    raid = boss = None
    for line in region.splitlines():
        m = re.match(r'^\s*\{ key = "([^"]+)", name = "[^"]*", phase', line)
        if m:
            raid = m.group(1)
            continue
        m = re.match(r'^\s*\{ key = "([^"]+)", name = ', line)
        if m:
            boss = m.group(1)
            continue
        m = re.match(r"^\s*(\d+),", line)
        if m and raid and boss:
            out[int(m.group(1))].append(f"{raid}/{boss}")
    return out


def load_dbm_test_instances():
    """instanceID -> name, from DBM-Test's instance list (instanceID cross-check)."""
    out = {}
    if os.path.exists(P_DBM_TEST_INSTANCES):
        for m in re.finditer(r'\[(\d+)\]\s*=\s*\{name\s*=\s*"([^"]*)"', read(P_DBM_TEST_INSTANCES)):
            out.setdefault(int(m.group(1)), m.group(2))
    return out


def load_loon():
    loon = {}
    loon_re = re.compile(r'^\s*\[(\d+)\]\s*=\s*\{\s*Name\s*=\s*"((?:\\.|[^"\\])*)"\s*,\s*SourceType\s*=\s*LBIS\.L\["([^"]*)"\]\s*,\s*Source\s*=\s*(.*?)\s*,\s*SourceNumber\s*=\s*"([^"]*)"\s*,\s*SourceLocation\s*=\s*(.*?)\s*,\s*SourceFaction\s*=\s*"([^"]*)"', re.M)

    def L(expr):
        return " & ".join(re.findall(r'LBIS\.L\["([^"]*)"\]', expr)) or expr.strip('"')
    for m in loon_re.finditer(read(G.P_LOON_SOURCES)):
        loon[int(m.group(1))] = {"name": m.group(2).replace('\\"', '"'), "type": m.group(3),
                                 "source": L(m.group(4)), "number": m.group(5), "location": L(m.group(6))}
    return loon


# --------------------------------------------------------------------------------------
# Parse AtlasLoot dungeons
# --------------------------------------------------------------------------------------
def parse_atlas_dungeons():
    text = read(G.P_ATLAS_RAIDS)
    toks, comments = tokenize(text)
    commented_rows = {}
    for ln, c in comments.items():
        m = re.match(r"^\{\s*\d+\s*,\s*(\d+)\s*\}\s*,?\s*(?:--\s*(.*))?$", c)
        if m:
            commented_rows[ln] = (int(m.group(1)), (m.group(2) or "").strip())
    found = OrderedDict()
    for i in range(len(toks) - 5):
        if toks[i].kind == "name" and toks[i].val == "data" and toks[i + 1].val == "[" and toks[i + 2].kind == "str" \
                and toks[i + 3].val == "]" and toks[i + 4].val == "=":
            p = Parser(toks)
            p.i = i + 5
            tbl = p.parse_table()
            ct = tbl.get("ContentType")
            found[toks[i + 2].val] = (tbl, ct[1] if isinstance(ct, tuple) and ct[0] == "ident" else None)
    return found, comments, commented_rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT_LUA_DEFAULT)
    args = ap.parse_args()

    report = OrderedDict()
    report["skipped"] = []
    report["warnings"] = []

    atlas_all, comments, commented_rows = parse_atlas_dungeons()
    dungeon_keys = [k for k, (_, ct) in atlas_all.items() if ct == "DUNGEON_CONTENT"]
    report["atlas_dungeon_content_keys"] = dungeon_keys
    for k in dungeon_keys:
        if k not in DUNGEONS:
            report["warnings"].append(f"AtlasLoot dungeon {k} has no DUNGEONS entry; key/name derived automatically")
    for k in DUNGEONS:
        if k not in dungeon_keys:
            report["warnings"].append(f"configured dungeon {k} not found as DUNGEON_CONTENT in data-tbc.lua")

    questie = load_questie_items_full()
    qnpc = load_questie_npcs()
    qobj = load_questie_objects()
    qobj_by_name = defaultdict(list)
    for o, raw in qobj.raw.items():
        m = re.match(r'^\{"((?:\\.|[^"\\])*)"', raw)
        if m:
            qobj_by_name[m.group(1).replace('\\"', '"')].append(o)
    badge = questie.get(29434) or {"npc": [], "obj": []}
    badge_npcs, badge_objs = set(badge["npc"]), set(badge["obj"])
    loon = load_loon()
    raid_items = load_raid_item_ids()
    dbm_test_inst = load_dbm_test_instances()
    dbm_party_installed = os.path.isdir(P_DBM_PARTY_BC)
    report["dbm_party_bc_installed"] = dbm_party_installed

    out = []
    all_sources = defaultdict(list)   # itemID -> ["Dungeon/Boss(N|H)"]
    for al_key in dungeon_keys:
        dt = atlas_all[al_key][0]
        key, disp, loon_loc = DUNGEONS.get(al_key, (re.sub(r"[^A-Za-z0-9]", "", al_key), al_key, al_key))
        phase_v = dt.get("ContentPhaseBC")
        phase = int(phase_v) if isinstance(phase_v, (int, float)) else 1
        instance_id = dt.get("InstanceID")
        map_id = dt.get("MapID")
        if instance_id and dbm_test_inst and instance_id not in dbm_test_inst:
            report["warnings"].append(f"{key}: instanceID {instance_id} not in DBM-Test instance list")
        bosses = []
        for pos, entry in enumerate(dt.get("items").array, start=1):
            if entry is None:
                continue
            if isinstance(entry, tuple):
                if entry[0] == "ident":
                    report["skipped"].append({"dungeon": key, "entry": entry[1], "reason": "shared extra table (KEYS: dungeon keys list, ExtraList/IgnoreAsSource) - not boss loot"})
                elif entry[0] == "call":
                    inner = next((a for a in entry[2] if isinstance(a, LuaTable)), None)
                    nm = resolve_text(inner.get("name")) if inner else "?"
                    report["skipped"].append({"dungeon": key, "entry": nm, "reason": f"wrapped in {entry[1]}(WRATH_VERSION_NUM, ...) - Wrath-only, nil on the TBC client"})
                continue
            name_en = resolve_text(entry.get("name"))
            st = resolve_text(entry.get("specialType")) if entry.get("specialType") is not None else None
            if st == "vendor":
                rows = [r.array[1] for dk in entry.hash if isinstance(dk, tuple) and dk[0] == "ident"
                        for r in entry.hash[dk].array if isinstance(r, LuaTable) and len(r.array) > 1]
                report["skipped"].append({"dungeon": key, "entry": name_en, "items": rows, "reason": "specialType = \"vendor\": sold by an NPC for gold, not a drop"})
                continue
            meta = BOSS_META.get((al_key, name_en))
            if not meta:
                report["warnings"].append(f"No BOSS_META for {al_key}/{name_en}; key derived automatically")
                meta = (re.sub(r"[^A-Za-z0-9]", "", re.sub(r"<.*?>", "", name_en).title()), None)
            bkey, dbm_rel = meta
            npc = entry.get("npcID")
            npcs = [int(npc)] if isinstance(npc, (int, float)) else ([int(x) for x in npc.array] if isinstance(npc, LuaTable) else [])
            atlas_npcs = list(npcs)
            cids, eids = G.dbm_ids(dbm_rel) if dbm_party_installed else ([], [])
            for c in cids:
                if c not in npcs:
                    npcs.append(c)
            obj = entry.get("ObjectID")
            objs = [int(obj)] if isinstance(obj, (int, float)) else ([int(x) for x in obj.array] if isinstance(obj, LuaTable) else [])
            atlas_objs = list(objs)
            is_trash = name_en == "Trash"
            is_chest = bool(atlas_objs)

            lists = OrderedDict((f, []) for f in DIFF_FIELD.values())
            headers_seen = []
            diff_keys = [k for k in entry.hash if isinstance(k, tuple) and k[0] == "ident" and k[1].endswith("_DIFF")]
            for dk in diff_keys:
                field = DIFF_FIELD.get(dk[1])
                if field is None:
                    report["warnings"].append(f"{key}/{name_en}: unexpected difficulty {dk[1]} (ignored)")
                    continue
                heroic = field == "heroicItems"
                rows = entry.hash[dk]
                seen = set()
                items = lists[field]
                for r_i, row in enumerate(rows.array):
                    if not isinstance(row, LuaTable) or len(row.array) < 2:
                        report["skipped"].append({"dungeon": key, "boss": name_en, "row": repr(row), "reason": "malformed row"})
                        continue
                    val = row.array[1]
                    cmt = comments.get(rows.array_lines[r_i]) or comments.get(row.line_end) or ""
                    if isinstance(val, tuple) and val[0] == "str":
                        s = val[1]
                        if s.startswith(G.DUMMY_PREFIXES):
                            header = resolve_text(row.array[3]) if len(row.array) > 3 else s
                            items.append(("header", header))
                            headers_seen.append(header)
                            report["skipped"].append({"dungeon": key, "boss": name_en, "list": field, "row": s, "text": header, "reason": "icon/header row (Dummy type) - not an item; its text is appended as \"(from: ...)\" to the next item comment"})
                        else:
                            mm = re.match(r"^([a-z]+)", s)
                            report["skipped"].append({"dungeon": key, "boss": name_en, "list": field, "row": s, "reason": f"string row type '{G.STRING_TYPE_PREFIXES.get(mm.group(1) if mm else '', 'unknown')}' - not a plain item"})
                        continue
                    if not isinstance(val, (int, float)):
                        report["skipped"].append({"dungeon": key, "boss": name_en, "list": field, "row": repr(val), "reason": "non-numeric item value"})
                        continue
                    ids = [int(val)]
                    for hk, hv in row.hash.items():
                        if isinstance(hk, tuple) and hk[0] == "ident" and hk[1].startswith("ATLASLOOT_IT_") and isinstance(hv, (int, float)):
                            ids.append(int(hv))
                    for x in ids:
                        if x in SKIP_ITEMS:
                            report["skipped"].append({"dungeon": key, "boss": name_en, "list": field, "item": x, "name": cmt, "reason": SKIP_ITEMS[x]})
                            continue
                        q = questie.get(x)
                        if heroic and q and q["cls"] == QUESTIE_CLASS_GEM:
                            report["skipped"].append({"dungeon": key, "boss": name_en, "list": field, "item": x, "name": cmt, "reason": "heroic gem drop (Questie item class 3 = Gem): not equippable gear"})
                            continue
                        if x in seen:
                            report["skipped"].append({"dungeon": key, "boss": name_en, "list": field, "item": x, "name": cmt, "reason": "duplicate within the same list (deduped)"})
                            continue
                        seen.add(x)
                        items.append(("item", x, cmt))
            # commented-out rows inside this boss table
            for ln in range(entry.line_start, entry.line_end + 1):
                if ln in commented_rows:
                    iid, nm = commented_rows[ln]
                    report["skipped"].append({"dungeon": key, "boss": name_en, "item": iid, "name": nm, "reason": "commented out in AtlasLoot (--{ idx, id })"})

            # objectIDs: AtlasLoot ObjectID + Questie objects that drop this boss's items AND share a name with the
            # AtlasLoot object (heroic chest variant) or with a header row in the list ("The Talon King's Coffer").
            ref_names = {qobj[o][0] for o in atlas_objs if o in qobj} | set(headers_seen)
            # (a) same-named Questie objects in the same zone as the AtlasLoot object (normal/heroic chest variants)
            for ao in atlas_objs:
                an, az = qobj.get(ao) or (None, None)
                for o in qobj_by_name.get(an, []):
                    oz = (qobj.get(o) or (None, None))[1]
                    if o not in objs and oz == az:
                        objs.append(o)
                        report.setdefault("questie_objectIDs", []).append({"dungeon": key, "boss": bkey, "object": o, "name": an, "zone": oz, "via": f"same name + zone as AtlasLoot ObjectID {ao}", "badge_holder": o in badge_objs})
            # (b) objects Questie lists as the drop source of this boss's items, named like (a) or a header row
            for fld, items in lists.items():
                for x in items:
                    if x[0] != "item":
                        continue
                    for o in (questie.get(x[1]) or {}).get("obj", []):
                        if o in objs or o not in qobj:
                            continue
                        oname, ozone = qobj[o]
                        if oname in ref_names and (ozone in (None, 0, map_id)):
                            objs.append(o)
                            report.setdefault("questie_objectIDs", []).append({"dungeon": key, "boss": bkey, "object": o, "name": oname, "zone": ozone, "via": f"Questie objectDrops of item {x[1]} ({fld})", "badge_holder": o in badge_objs})

            n_n = sum(1 for x in lists["items"] if x[0] == "item")
            n_h = sum(1 for x in lists["heroicItems"] if x[0] == "item")
            if n_n == 0 and n_h == 0:
                report["warnings"].append(f"{key}/{bkey}: no items left after skipping")
            for fld, tag in (("items", "N"), ("heroicItems", "H")):
                for x in lists[fld]:
                    if x[0] == "item":
                        all_sources[x[1]].append(f"{key}/{bkey}({tag})")
            bosses.append(OrderedDict(
                key=bkey, name=NAME_OVERRIDE.get((al_key, name_en), re.sub(r"\s*<.*?>", "", name_en)),
                atlasName=name_en, atlasIndex=pos, npcIDs=npcs, atlasNpcIDs=atlas_npcs, objectIDs=objs,
                encounterIDs=eids, isTrash=is_trash, isChest=is_chest, items=lists["items"], heroicItems=lists["heroicItems"],
                nItems=n_n, nHeroic=n_h, extraList=bool(entry.get("ExtraList")),
            ))
        keys = [b["key"] for b in bosses]
        dup = sorted({k for k in keys if keys.count(k) > 1})
        if dup:
            raise SystemExit(f"duplicate boss keys in {key}: {dup}")
        out.append(OrderedDict(key=key, alKey=al_key, name=disp, loonLoc=loon_loc, phase=phase,
                               instanceID=instance_id, mapID=map_id, bosses=bosses))

    # ---------------------------------------------------------------- checks / cross-checks
    # (1) npcIDs vs Questie npc DB: names, heroic "(1)" variants, zone
    npc_check = []
    for d in out:
        for b in d["bosses"]:
            rows = []
            for n in b["npcIDs"]:
                nm, zone = qnpc.get(n, (None, None))
                rows.append({"npc": n, "questie_name": nm, "zone": zone})
            npc_check.append({"dungeon": d["key"], "boss": b["key"], "npcs": rows})
    report["npc_questie_names"] = npc_check

    # (2) Questie npcDrops for the boss's items that are NOT in npcIDs (possible missing variants)
    missing_npc = []
    for d in out:
        for b in d["bosses"]:
            if b["isTrash"]:
                continue
            cand = defaultdict(int)
            n_items = 0
            for fld in ("items", "heroicItems"):
                for x in b[fld]:
                    if x[0] != "item":
                        continue
                    n_items += 1
                    for n in (questie.get(x[1]) or {}).get("npc", []):
                        cand[n] += 1
            for n, c in sorted(cand.items(), key=lambda kv: -kv[1]):
                if n in b["npcIDs"]:
                    continue
                nm, zone = qnpc.get(n, (None, None))
                base = re.sub(r" \(1\)$", "", nm or "")
                if c >= 2 and base and base.lower() in {(qnpc.get(k, ("",))[0] or "").lower() for k in b["npcIDs"]} | {b["atlasName"].lower()}:
                    missing_npc.append({"dungeon": d["key"], "boss": b["key"], "npc": n, "name": nm, "items_dropped": c, "of": n_items})
    report["questie_npc_variants_not_in_atlas"] = missing_npc

    # (3) Questie loot-holder check: does any npc/object of each boss actually carry one of its items?
    holder = {}
    holder_none = []
    for d in out:
        for b in d["bosses"]:
            if b["isTrash"]:
                continue
            ids = [x[1] for f in ("items", "heroicItems") for x in b[f] if x[0] == "item"]
            n_hit = [n for n in b["npcIDs"] if any(n in (questie.get(i) or {}).get("npc", []) for i in ids)]
            o_hit = [o for o in b["objectIDs"] if any(o in (questie.get(i) or {}).get("obj", []) for i in ids)]
            n_badge = [n for n in b["npcIDs"] if n in badge_npcs]
            o_badge = [o for o in b["objectIDs"] if o in badge_objs]
            holder[f"{d['key']}/{b['key']}"] = {"item_drop_npcs": n_hit, "item_drop_objects": o_hit, "badge_npcs": n_badge, "badge_objects": o_badge}
            if not (n_hit or o_hit or n_badge or o_badge):
                holder_none.append(f"{d['key']}/{b['key']}")
    report["loot_holders_questie"] = holder
    report["loot_holders_questie_none"] = holder_none

    # (4) Item names: AtlasLoot comment vs Questie name
    name_mismatch = []
    for d in out:
        for b in d["bosses"]:
            for f in ("items", "heroicItems"):
                for x in b[f]:
                    if x[0] != "item":
                        continue
                    qn = (questie.get(x[1]) or {}).get("name")
                    if qn is None:
                        name_mismatch.append((d["key"], b["key"], x[1], x[2], "not in Questie"))
                    elif qn.replace("\\'", "'").strip().lower() != (x[2] or "").strip().lower():
                        name_mismatch.append((d["key"], b["key"], x[1], x[2], qn))
    report["item_name_vs_questie"] = {"mismatch": name_mismatch}

    # (5) AtlasLoot source-tbc: boss + difficulty attribution
    src_toks, _ = tokenize(read(G.P_ATLAS_SOURCE))
    sp = Parser(src_toks)
    sp.i = find_assignment(src_toks, [("name", "local"), ("name", "SOURCE_DATA"), ("op", "=")])
    source_data = sp.parse_table()
    atlas_ids = [resolve_text(x) for x in source_data.get("AtlasLootIDs").array]
    item_src = source_data.get("ItemData").hash
    alidx = {name: i + 1 for i, name in enumerate(atlas_ids)}

    def src_entries(v):
        """-> list of (ini, boss, diffset) with diffset in {'N'}, {'H'}, {'N','H'}"""
        res = []
        if not isinstance(v, LuaTable):
            return res
        es = v.array if (v.array and isinstance(v.array[0], LuaTable)) else [v]
        for e in es:
            if not isinstance(e, LuaTable):
                continue
            ini = e.array[0] if len(e.array) > 0 else e.get(1)
            boss = e.array[1] if len(e.array) > 1 else e.get(2)
            d5 = e.get(5)
            if d5 is None:
                ds = {"N"}
            elif d5 == 0:
                ds = {"H"}
            elif isinstance(d5, LuaTable):
                ds = {"N"} | {"H" for z in d5.array if z == 2}
            else:
                ds = {"?"}
            res.append((ini, boss, frozenset(ds)))
        return res
    xs = {"match_boss": 0, "match_boss_and_difficulty": 0, "boss_mismatch": [], "difficulty_mismatch": [], "missing": [],
          "atlas_source_entries_not_in_ours": []}
    ours_by_pos = {}
    for d in out:
        ri = alidx.get(d["alKey"])
        for b in d["bosses"]:
            per_item = defaultdict(set)
            for f, tag in (("items", "N"), ("heroicItems", "H")):
                for x in b[f]:
                    if x[0] == "item":
                        per_item[x[1]].add(tag)
            ours_by_pos[(ri, b["atlasIndex"])] = (d["key"], b["key"], per_item)
            for iid, tags in per_item.items():
                v = item_src.get(iid)
                if v is None:
                    xs["missing"].append((d["key"], b["key"], iid))
                    continue
                ent = [e for e in src_entries(v) if (e[0], e[1]) == (ri, b["atlasIndex"])]
                if not ent:
                    xs["boss_mismatch"].append((d["key"], b["key"], iid, [(atlas_ids[e[0] - 1] if isinstance(e[0], int) and 0 < e[0] <= len(atlas_ids) else e[0], e[1]) for e in src_entries(v)]))
                    continue
                xs["match_boss"] += 1
                # our tags may be a subset of source-tbc's (e.g. a heroic gem we skipped doesn't matter here)
                if set(ent[0][2]) == tags:
                    xs["match_boss_and_difficulty"] += 1
                else:
                    xs["difficulty_mismatch"].append((d["key"], b["key"], iid, sorted(tags), sorted(ent[0][2])))
    # reverse: every source-tbc loot entry pointing at a dungeon boss we ship should be in our lists
    for iid, v in item_src.items():
        if not isinstance(iid, int):
            continue
        for ini, boss, ds in src_entries(v):
            k = (ini, boss)
            if k in ours_by_pos:
                dk, bk, per_item = ours_by_pos[k]
                if iid not in per_item:
                    xs["atlas_source_entries_not_in_ours"].append((dk, bk, iid, sorted(ds), (questie.get(iid) or {}).get("name")))
    rm = xs["atlas_source_entries_not_in_ours"]
    xs["reverse_missing_by_reason"] = {
        "heroic_gems_skipped": sum(1 for r_ in rm if (questie.get(r_[2]) or {}).get("cls") == QUESTIE_CLASS_GEM),
        "badge_skipped": sum(1 for r_ in rm if r_[2] in SKIP_ITEMS),
        "other": [r_ for r_ in rm if (questie.get(r_[2]) or {}).get("cls") != QUESTIE_CLASS_GEM and r_[2] not in SKIP_ITEMS],
    }
    report["crosscheck_atlas_source_tbc"] = xs

    # (6) LoonBestInSlot: boss + "(H)" location
    loc_to_dungeon = {}
    for d in out:
        for base in {d["loonLoc"], d["name"]}:
            loc_to_dungeon[base] = (d["key"], "N")
            loc_to_dungeon[base + " (H)"] = (d["key"], "H")
            loc_to_dungeon[base + " (Heroic)"] = (d["key"], "H")
    bossname = {(d["key"], b["key"]): b["atlasName"].lower() for d in out for b in d["bosses"]}
    our_src = defaultdict(set)  # iid -> {(dungeon, boss, tag)}
    for d in out:
        for b in d["bosses"]:
            for f, tag in (("items", "N"), ("heroicItems", "H")):
                for x in b[f]:
                    if x[0] == "item":
                        our_src[x[1]].add((d["key"], b["key"], tag))
    lx = {"agree": 0, "agree_boss_only": [], "boss_differs": [], "loon_dungeon_item_not_in_db": [], "loon_locations_unmapped": set()}
    for iid, e in loon.items():
        if e["type"] not in ("Drop",):
            continue
        locs = e["location"].split(" & ")
        hits = [loc_to_dungeon[l] for l in locs if l in loc_to_dungeon]
        if not hits:
            continue
        ours = our_src.get(iid)
        if not ours:
            lx["loon_dungeon_item_not_in_db"].append((iid, e["name"], e["source"], e["location"], (questie.get(iid) or {}).get("cls")))
            continue
        loon_names = {LOON_BOSS_ALIASES.get(s.strip().lower(), s.strip().lower()) for s in e["source"].split(" & ")}
        our_names = {bossname[(dk, bk)] for dk, bk, _ in ours}
        our_tags = {t for _, _, t in ours}
        loon_tags = {t for _, t in hits}
        boss_ok = bool(our_names & loon_names) or "trash" in our_names
        if not boss_ok:
            lx["boss_differs"].append((iid, e["name"], sorted(our_names), sorted(loon_names)))
        elif loon_tags <= our_tags or (loon_tags == {"N"} and our_tags == {"H"} and False):
            lx["agree"] += 1
        else:
            lx["agree_boss_only"].append((iid, e["name"], sorted(our_tags), e["location"]))
    lx["loon_locations_unmapped"] = sorted({e["location"] for e in loon.values() if e["type"] == "Drop" and
                                            any(w in e["location"] for w in ("Ramparts", "Furnace", "Shattered", "Tombs", "Crypts", "Sethekk", "Labyrinth", "Slave", "Underbog", "Steamvault", "Hillsbrad", "Morass", "Arcatraz", "Botanica", "Mechanar", "Magisters")) and
                                            not all(l in loc_to_dungeon for l in e["location"].split(" & "))})
    report["crosscheck_loon"] = lx

    # (7) overlaps: raid items, and items shared by several dungeon bosses
    report["raid_items_parsed"] = len(raid_items)
    report["raid_overlap"] = {str(i): {"dungeon": all_sources[i], "raid": raid_items[i], "name": (questie.get(i) or {}).get("name")}
                              for i in sorted(all_sources) if i in raid_items}
    shared = {}
    for i, srcs in sorted(all_sources.items()):
        bossset = sorted({s.rsplit("(", 1)[0] for s in srcs})
        if len(bossset) > 1:
            shared[str(i)] = {"name": (questie.get(i) or {}).get("name"), "sources": srcs}
    report["shared_across_bosses"] = shared
    # gems appearing in NORMAL lists (kept, per the heroic-only gem rule) and class histogram
    hist = defaultdict(lambda: defaultdict(int))
    normal_gems = []
    for d in out:
        for b in d["bosses"]:
            for f in ("items", "heroicItems"):
                for x in b[f]:
                    if x[0] == "item":
                        c = (questie.get(x[1]) or {}).get("cls")
                        hist[f][QUESTIE_CLASS_NAMES.get(c, str(c))] += 1
                        if f == "items" and c == QUESTIE_CLASS_GEM:
                            normal_gems.append((d["key"], b["key"], x[1], x[2]))
    report["item_class_histogram"] = {k: dict(v) for k, v in hist.items()}
    report["normal_list_gems_kept"] = normal_gems

    # ---------------------------------------------------------------- emit Lua
    def lstr(s):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

    def lnums(xs_):
        return "{ " + ", ".join(str(x) for x in xs_) + " }" if xs_ else "{}"

    def cmt_clean(c):
        return (c or "").replace("\n", " ").strip()

    L = []
    w = L.append
    w("-- CDLoot embedded 5-man dungeon loot database (TBC Anniversary, Interface 20506)")
    w("-- AUTO-GENERATED by gen_cdloot_dungeons.py - do not edit by hand; re-run the generator instead.")
    w("-- Sources (all read locally, GPL-licensed AtlasLootClassic data unless noted):")
    w("--   AtlasLootClassic_DungeonsAndRaids/data-tbc.lua  (dungeons with ContentType = DUNGEON_CONTENT, bosses,")
    w("--                                                   drops per difficulty, npcID/ObjectID, ContentPhaseBC,")
    w("--                                                   item-name comments)")
    w("--   Questie/Database/TBC (tbcItemDB/tbcObjectDB)    (item class for gem detection; heroic chest object IDs)")
    w("--   DBM-Party-BC                                    (creature/encounter IDs - " + ("installed, merged" if dbm_party_installed else "NOT installed when generated: no encounterIDs") + ")")
    w("--   AtlasLootClassic_Data/source-tbc.lua, LoonBestInSlot/DB/ItemSources.lua  (cross-checks only)")
    w("-- items = NORMAL_DIFF list, heroicItems = HEROIC_DIFF list (both deduped, AtlasLoot order).")
    w("-- Excluded: Badge of Justice (29434); gems in heroic lists (the random heroic gem drops, Questie item")
    w("-- class 3); header rows (their text is kept as \"(from: ...)\" on the next item's comment); the shared KEYS")
    w("-- table; Wrath-only entries (Ahune); vendor NPCs (Old Hillsbrad recipe vendors).")
    w("-- Kept: patterns/recipes, quest items, keys, mounts, pets, seasonal hats; filter non-equippables at runtime.")
    w("-- Chest objectIDs beyond AtlasLoot's ObjectID come from Questie (same-name heroic chest in the same zone,")
    w("-- or the object Questie lists as the drop source of a boss item, e.g. the Talon King's Coffer).")
    w("--")
    w("-- Dungeon fields: key, name, phase (AtlasLoot ContentPhaseBC, else 1), instanceID, bosses.")
    w("-- Boss fields: key (unique per dungeon), name, npcIDs (normal + heroic creature IDs), objectIDs (loot")
    w("--   chest/object GameObject IDs), encounterID (only when DBM-Party-BC provides one), isTrash / isChest")
    w("--   (pseudo-bosses), items, heroicItems (itemIDs; either may be empty).")
    w("local _, ns = ...")
    w("ns.Data = ns.Data or {}")
    w("")
    w("ns.Data.Dungeons = {")
    for d in out:
        inst = f", instanceID = {d['instanceID']}" if d["instanceID"] else ""
        w(f"  {{ key = {lstr(d['key'])}, name = {lstr(d['name'])}, phase = {d['phase']}{inst}, bosses = {{")
        for b in d["bosses"]:
            fields = [f"key = {lstr(b['key'])}", f"name = {lstr(b['name'])}", f"npcIDs = {lnums(b['npcIDs'])}"]
            if b["objectIDs"]:
                fields.append(f"objectIDs = {lnums(b['objectIDs'])}")
            if b["encounterIDs"]:
                fields.append(f"encounterID = {b['encounterIDs'][0]}")
            if b["isTrash"]:
                fields.append("isTrash = true")
            if b["isChest"]:
                fields.append("isChest = true")
            w("    { " + ", ".join(fields) + ",")
            for fld in ("items", "heroicItems"):
                lst = b[fld]
                if not any(x[0] == "item" for x in lst):
                    w(f"      {fld} = {{}},")
                    continue
                w(f"      {fld} = {{")
                pending = None  # AtlasLoot header row: labels the item that follows it (e.g. the Talon King's Coffer key)
                for x in lst:
                    if x[0] == "header":
                        pending = cmt_clean(x[1])
                    else:
                        c = cmt_clean(x[2])
                        if pending:
                            c = f"{c} (from: {pending})"
                            pending = None
                        w(f"        {x[1]},{(' -- ' + c) if c else ''}")
                w("      },")
            w("    },")
        w("  }},")
    w("}")
    w("")
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L))

    counts = []
    for d in out:
        counts.append({"dungeon": d["key"], "phase": d["phase"], "instanceID": d["instanceID"], "bosses": len(d["bosses"]),
                       "items": sum(b["nItems"] for b in d["bosses"]), "heroicItems": sum(b["nHeroic"] for b in d["bosses"]),
                       "unique": len({x[1] for b in d["bosses"] for f in ("items", "heroicItems") for x in b[f] if x[0] == "item"}),
                       "per_boss": {b["key"]: [b["nItems"], b["nHeroic"]] for b in d["bosses"]}})
    report["counts"] = counts
    report["bosses_dump"] = [{"dungeon": d["key"], "boss": b["key"], "atlasIndex": b["atlasIndex"], "npcIDs": b["npcIDs"],
                              "objectIDs": b["objectIDs"], "isChest": b["isChest"], "isTrash": b["isTrash"], "extraList": b["extraList"]}
                             for d in out for b in d["bosses"]]
    with open(OUT_REPORT, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, default=lambda o: sorted(o) if isinstance(o, (set, frozenset)) else str(o))

    print(f"Wrote {args.out}")
    tn = th = 0
    for c in counts:
        tn += c["items"]
        th += c["heroicItems"]
        print(f"  {c['dungeon']:18s} phase={c['phase']} inst={c['instanceID']} bosses={c['bosses']:2d} normal={c['items']:3d} heroic={c['heroicItems']:3d} unique={c['unique']:3d}")
    print(f"  TOTAL normal={tn} heroic={th} unique items={len(all_sources)}")
    print(f"  reverse-missing split: {dict((k, v if isinstance(v, int) else len(v)) for k, v in xs['reverse_missing_by_reason'].items())}  raid items parsed={len(raid_items)}  no-holder={holder_none}")
    print(f"  source-tbc: boss match={xs['match_boss']} boss+diff match={xs['match_boss_and_difficulty']} boss mismatch={len(xs['boss_mismatch'])} diff mismatch={len(xs['difficulty_mismatch'])} missing={len(xs['missing'])} reverse-missing={len(xs['atlas_source_entries_not_in_ours'])}")
    print(f"  loon: agree={lx['agree']} boss-only={len(lx['agree_boss_only'])} differs={len(lx['boss_differs'])} loon-only={len(lx['loon_dungeon_item_not_in_db'])} unmappedLocs={lx['loon_locations_unmapped']}")
    print(f"  raid overlap={len(report['raid_overlap'])} shared across bosses={len(shared)} name mismatches={len(name_mismatch)} questie-objects={len(report.get('questie_objectIDs', []))} npc-variants-missing={len(missing_npc)}")
    print(f"  warnings={report['warnings']}")


if __name__ == "__main__":
    main()
