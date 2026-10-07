#!/usr/bin/env python3
"""
Generator for DisasterZone's Atlas browser data (the in-addon loot browser, like AtlasLoot): everything AtlasLoot has
for TBC beyond raids and 5-man dungeons (those come from Data/Items.lua and Data/Dungeons.lua), plus English names for
every id the Atlas tab can list.

Companion of gen_cdloot_sources.py: it IMPORTS it (and through it gen_cdloot_data.py) and reuses the Lua tokenizer /
table parser, the AtlasLoot table walkers, the text resolver, the Questie item loader, the VendorPrice / ItemSet loaders,
the price parser and the faction name map.  Neither earlier generator nor its output is touched.

Reads (read-only) from the installed WoW AddOns folder:
  * AtlasLootClassic_Crafting/data-tbc.lua         -> every TBC profession table (rows are craft SPELL ids, except the
                                                      Item-type tables: raw gems, herbs, fish)
  * AtlasLootClassic/Data/Profession.lua           -> PROFESSION_DATA.CLASSIC + .BCC (BCC overrides, as AtlasLoot merges
                                                      them on a TBC client): spell -> created item, required skill,
                                                      reagents + counts, number made (the tooltip's Shift materials)
  * AtlasLootClassic/Data/Recipe.lua               -> RECIPE_DATA.CLASSIC + .BCC: recipe item -> craft spell
  * AtlasLootClassic_Factions/data-tbc.lua         -> per-faction tables (FactionID, ContentPhaseBC, standing sub-tables)
  * AtlasLootClassic_PvP/data-tbc.lua              -> honor / reputation / arena season tables, PvP mounts, world PvP
  * AtlasLootClassic_Collections/data-tbc.lua      -> Badge of Justice + Sunmote vendors, world epics, mounts, companions,
                                                      tabards, legendaries, world events
  * AtlasLootClassic_DungeonsAndRaids/data-tbc.lua -> only the local T4_SET / T5_SET / T6_SET tables (item set ids)
  * AtlasLootClassic/Data/ItemSet.lua              -> ITEM_SET_DATA_RAW.BCC (+ CLASSIC fallback): set id -> item ids, name
  * AtlasLootClassic/Data/VendorPrice.lua          -> VENDOR_PRICES_RAW.BCC: badge / honor / mark / money costs
  * ../../WTF/Account/*/SavedVariables/AtlasLootClassic.lua -> AtlasLoot's own vendor scans on this PC
                                                      (AtlasLootClassicDB.global.VendorPrice): what the realm's vendors
                                                      asked when a character opened them; first choice for a cost
                                                      (PvP prices change with the arena seasons, AtlasLoot's tables and
                                                      Wowhead don't follow them)
  * Questie/Database/TBC/tbcItemDB.lua             -> English item names
  * DisasterZone/Data/Items.lua, Dungeons.lua, Sources.lua -> every item id the addon already ships (names; the
                                                      raid / dungeon boss lists also for recipes; Upgrades for the
                                                      Sunmote page)

Writes:
  * <ADDON>/Data/Atlas.lua                         (the only file written inside the addon)
  * dev/generators/gen_atlas_report.json           (counts, unnamed ids, skipped rows by reason, size)

Usage:  luaenv\\Scripts\\python.exe generators\\gen_atlas.py [--out PATH]      (run from the dev folder)
"""
import argparse
import json
import os
import re
import sys
from collections import OrderedDict, Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(DEV, "tools"))  # luabc (imported by gen_cdloot_sources) lives in dev/tools
import gen_cdloot_sources as S  # noqa: E402  (main() is __name__-guarded)
from gen_cdloot_sources import (find_data_tables, rtext, scan_local_consts, version_table, lua_str, cmt, ident,  # noqa: E402
                                parse_price, load_questie_items, load_vendor_prices, load_item_sets, FACTIONS,
                                FACTION_PHASE_RULES)
from gen_cdloot_data import LuaTable, tokenize, read  # noqa: E402
from lupa import lua51  # noqa: E402

ADDON_DIR = os.path.normpath(os.path.join(DEV, "..", "addon", "DisasterZone"))
if not os.path.isdir(ADDON_DIR):
    ADDON_DIR = S.ADDON_DIR
OUT_LUA_DEFAULT = os.path.join(ADDON_DIR, "Data", "Atlas.lua")
OUT_REPORT = os.path.join(HERE, "gen_atlas_report.json")
P_ADDON_DATA = [os.path.join(ADDON_DIR, "Data", f) for f in ("Items.lua", "Dungeons.lua", "Sources.lua")]

FIRST_LINE = ('if DisasterZoneBoot and DisasterZoneBoot.Run("Data/Atlas.lua", ...) then return end '
              '-- DisasterZone Atlas browser data (TBC Anniversary, Interface 20506)')
MAX_X = 16              # max length of a row's extra text (a craft's "Skill 375")
P_WTF_ACCOUNTS = os.path.normpath(os.path.join(S.ADDONS, "..", "..", "WTF", "Account"))
MAX_SET_PAGE_NAME = 19  # Sets page names ("Shaman (Elemental)") stay below 20 characters

# --------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------
CATEGORIES = [("crafting", "Crafting"), ("reputation", "Reputation"), ("pvp", "PvP"), ("vendors", "Badges & Sunmote"),
              ("collections", "Collections"), ("events", "World Events"), ("sets", "Sets")]

# AtlasLoot table key -> (DisasterZone source key, English display name).  The AtlasLoot names resolve to the same
# words where they are plain AL/ALIL strings; these fix the ones that are format strings, colour codes, possessive
# typos or missing (the world PvP tables have only a MapID).
CRAFTING = OrderedDict([
    ("AlchemyBC", ("Alchemy", "Alchemy")), ("BlacksmithingBC", ("Blacksmithing", "Blacksmithing")),
    ("EnchantingBC", ("Enchanting", "Enchanting")), ("EngineeringBC", ("Engineering", "Engineering")),
    ("TailoringBC", ("Tailoring", "Tailoring")), ("LeatherworkingBC", ("Leatherworking", "Leatherworking")),
    ("JewelcraftingBC", ("Jewelcrafting", "Jewelcrafting")), ("MiningBC", ("Mining", "Mining")),
    ("HerbalismBC", ("Herbalism", "Herbalism")), ("CookingBC", ("Cooking", "Cooking")),
    ("FirstAidBC", ("FirstAid", "First Aid")), ("FishingBC", ("Fishing", "Fishing")),
    ("RoguePoisonsBC", ("RoguePoisons", "Rogue Poisons")),
])
PVP = OrderedDict([
    # named apart from the Reputation / Collections categories shown next to them (keys unchanged)
    ("HonorSetBCC", ("Honor", "Honor rewards")), ("ReputationSetBCC", ("Reputation", "PvP reputation rewards")),
    ("PvPMountsBCC", ("Mounts", "PvP mounts")),
    ("ArenaS1PvP", ("ArenaS1", "Arena Season 1")), ("ArenaS2PvP", ("ArenaS2", "Arena Season 2")),
    ("ArenaS3PvP", ("ArenaS3", "Arena Season 3")), ("ArenaS4PvP", ("ArenaS4", "Arena Season 4")),
    ("HellfirePeninsulaPvP", ("Hellfire", "Hellfire Peninsula")), ("NagrandPvP", ("Nagrand", "Nagrand")),
    ("TerokkarPvP", ("Terokkar", "Terokkar Forest")), ("ZangarmarshPvP", ("Zangarmarsh", "Zangarmarsh")),
])
VENDORS = OrderedDict([
    ("BadgeofJustice", ("BadgeofJustice", "Badge of Justice")),
    ("BadgeofJustice4", ("BadgeofJustice4", "Badge of Justice (P4)")),
    ("BadgeofJusticeP5", ("BadgeofJusticeP5", "Badge of Justice (P5)")),
    ("BCCSunmote", ("Sunmote", "Sunmote")),
])
COLLECTIONS = OrderedDict([
    ("WorldEpicsBC", ("WorldEpics", "World Epics")), ("MountsBC", ("Mounts", "Mounts")),
    ("CompanionsBC", ("Companions", "Companions")), ("TabardsBC", ("Tabards", "Tabards")),
    ("LegendarysBC", ("Legendaries", "Legendaries")),
])
EVENTS = OrderedDict([
    ("ChildrensWeekBC", ("ChildrensWeek", "Children's Week")),
    ("MidsummerFestivalBC", ("Midsummer", "Midsummer Fire Festival")),
    ("Brewfest", ("Brewfest", "Brewfest")), ("HalloweenBC", ("HallowsEnd", "Hallow's End")),
])
# Sets category: (source key, name, where the set ids come from)
SETS = [("Tier4", "Tier 4", ("tier", "T4_SET")), ("Tier5", "Tier 5", ("tier", "T5_SET")),
        ("Tier6", "Tier 6", ("tier", "T6_SET")),
        ("ArenaS1", "Arena Season 1", ("pvp", "ArenaS1PvP")), ("ArenaS2", "Arena Season 2", ("pvp", "ArenaS2PvP")),
        ("ArenaS3", "Arena Season 3", ("pvp", "ArenaS3PvP")), ("ArenaS4", "Arena Season 4", ("pvp", "ArenaS4PvP")),
        ("Honor", "Honor sets", ("pvp", "HonorSetBCC")), ("RepPvP", "Reputation PvP sets", ("pvp", "ReputationSetBCC"))]
# AtlasLoot's T4/T5/T6 tables have their ContentPhaseBC commented out; the tiers drop in the phase-1/2/3 raids
# (Karazhan/Gruul/Magtheridon, SSC/TK, Hyjal/BT - the phases of ns.Data.Raids).
TIER_PHASE = {"Tier4": 1, "Tier5": 2, "Tier6": 3}
# Known phases of AtlasLoot tables without ContentPhaseBC (the rules gen_cdloot_sources.py already uses):
#   PvP: S.PVP_TABLES (Honor / Reputation / world PvP = 1) and S.SEASON_PHASE (arena Season N: 1, 2, 3, 5);
#   Badge of Justice: build_badges' rule (a badge table without "P<n>" in its name is phase 1).
BADGE_P1_TABLE = "BadgeofJustice"

# C_Map.GetAreaInfo(areaID) / MapID -> English zone name (AtlasLoot resolves these at run time)
AREA_NAMES = {796: "Scarlet Monastery", 1584: "Blackrock Depths", 3483: "Hellfire Peninsula", 3518: "Nagrand",
              3519: "Terokkar Forest", 3521: "Zangarmarsh", 3717: "The Slave Pens", 3845: "Tempest Keep"}
TEXT_FIXES = {"Childrens Week": "Children's Week", "Legendarys": "Legendaries"}

SIDE_OF = {"ALLIANCE_DIFF": "Alliance", "HORDE_DIFF": "Horde"}
SIDE_LETTER = {"Alliance": "A", "Horde": "H"}

# Set row comments: "Priest / Heal", "Druid / Owl", "Warlock 2" -> "Priest (Heal)", "Druid (Balance)", "Warlock"
ROLE_NAMES = {"Heal": "Heal", "Shadow": "Shadow", "Owl": "Balance", "Feral": "Feral", "Ele": "Elemental",
              "Enh": "Enh", "Prot": "Prot", "DD": "DPS"}
CLASS_ROLE_NAMES = {("Paladin", "DD"): "Ret"}
RECIPE_PREFIX_RX = re.compile(r"^(Recipe|Pattern|Plans|Formula|Design|Schematic|Manual|Technique|Book): ")

# AtlasLoot price keys -> the addon's cost keys (Core/Currency.lua): "c<currencyID>" a currency (C_CurrencyInfo: Honor
# 1901, Arena Points 1900 on the Classic clients), "g" money in copper, "<itemID>" an item that pays (Badge of Justice,
# marks, tokens). The item ids are AtlasLoot's own (VendorPrice.lua PRICE_INFO_LIST). A price with a key not listed
# here is left out whole (a cost with a part missing would say "you can afford it" wrongly).
COST_KEYS = {
    "money": "g", "honor": "c1901", "honorA": "c1901", "honorH": "c1901", "arena": "c1900",
    "BoJ": "29434", "pvpAlterac": "20560", "pvpWarsong": "20558", "pvpArathi": "20559", "pvpEye": "29024",
    "HalaaRT": "26044", "HalaaBT": "26045", "MarkOfThrallmar": "24581", "MarkOfHonorHold": "24579",
    "SpiritShard": "28558", "holydust": "29735", "arcanerune": "29736", "glowcap": "24245", "ApexisC": "32572",
    "ApexisS": "32569", "Brewfest": "37829", "sunmote": "34664", "burningblossom": "23247", "ancestrycoin": "21100",
    "NecroticRune": "22484",
}
COST_RX = re.compile(r"^(g|c\d+|\d+):\d+(,(g|c\d+|\d+):\d+)*$")


# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------
class Ctx:
    """Shared state: loaded databases, collected names and the report."""

    def __init__(self):
        self.report = OrderedDict()
        self.report["notes"] = []
        self.skipped = defaultdict(list)       # reason -> [where...]
        self.comment_names = {}                # itemID -> name from an AtlasLoot row comment
        self.spell_names = {}                  # spellID -> name from a crafting row comment
        self.x_unpriced = Counter()            # category -> rows without a derivable cost
        self.row_prices = {}                   # itemID -> OrderedDict price of its AtlasLoot row (PRICE_EXTRA)

    def skip(self, reason, where):
        self.skipped[reason].append(where)


def clean_text(s):
    s = re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", s or "")
    s = re.sub(r"\s+", " ", s).strip()
    for a, b in TEXT_FIXES.items():
        s = s.replace(a, b)
    return s


def text(node, consts):
    """rtext() plus C_Map_GetAreaInfo(id) (Collections' world event sub-tables)."""
    if isinstance(node, tuple) and node[0] == "call" and node[1] in ("C_Map_GetAreaInfo", "C_Map.GetAreaInfo") \
            and node[2] and isinstance(node[2][0], int):
        return AREA_NAMES.get(node[2][0], "Area %d" % node[2][0])
    if isinstance(node, tuple) and node[0] == "concat":
        return (text(node[1], consts) or "") + (text(node[2], consts) or "")
    return rtext(node, consts)


def make_key(name, fallback):
    k = "".join(w[:1].upper() + w[1:] for w in re.split(r"[^A-Za-z0-9]+", name or "") if w)
    return k or fallback


def uniq_key(key, used):
    k, n = key, 2
    while k in used:
        k, n = f"{key}{n}", n + 1
    used.add(k)
    return k


def row_comment(comments, r):
    """The `-- comment` on a row's line (first comment of the line where the row's id ends)."""
    ln = r.array_lines[1] if len(r.array_lines) > 1 else r.line_start
    c = comments.get(ln) or comments.get(r.line_end) or ""
    return c.split("--")[0].strip()  # "Balebrew Charm 37128 -- ALL TRINKETS UPDATED ..." -> first part


def strip_skill(c):
    return re.sub(r"\s*\((\d+|undefined)\)\s*$", "", c or "").strip()


def int_val(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def diff_lists(sub, where, ctx):
    """OrderedDict diffName -> [rows sorted by position] for one AtlasLoot sub-table.
    Handles GetItemsFromDiff (the Horde tabard list re-uses the Alliance list) and AtlasLoot's typo `[NORMAL_ITTYPE] = {`
    (World Epics / Legendaries; works in game because that index equals NORMAL_DIFF's) - read as NORMAL_DIFF."""
    raw = OrderedDict()
    for dk, rows in sub.hash.items():
        name = ident(dk)
        if not name:
            continue
        if name.endswith("_ITTYPE"):
            if isinstance(rows, LuaTable) and any(isinstance(r, LuaTable) for r in rows.array):
                ctx.report["notes"].append(f"{where}: rows keyed [{name}] read as NORMAL_DIFF (AtlasLoot typo)")
                name = "NORMAL_DIFF"
            else:
                continue
        if not name.endswith("_DIFF"):
            continue
        if not isinstance(rows, LuaTable):
            ctx.skip("difficulty alias / link (not a row list)", f"{where} [{name}]")
            continue
        raw[name] = rows
    out = OrderedDict()
    for name, rows in raw.items():
        lst = []
        for k, r in enumerate(rows.array):
            if isinstance(r, LuaTable):
                pos = int_val(r.array[0]) if r.array else None
                if pos is None:
                    ctx.skip("row without integer position", f"{where} [{name}] #{k + 1}")
                    continue
                lst.append((pos, r))
            elif isinstance(r, tuple) and r[0] == "call":
                ctx.skip("version-gated row (AtlasLoot:GameVersion_* call, Wrath-only)", f"{where} [{name}] #{k + 1}")
            elif r is not None:
                ctx.skip("non-table row", f"{where} [{name}] #{k + 1}")
        src = ident(rows.get("GetItemsFromDiff"))
        if src and src in raw:
            # AtlasLoot ItemDB getItemsFromDiff: the other list's rows fill every position this list does not set
            taken = {p for p, _ in lst}
            extra = []
            for x in raw[src].array:
                p = int_val(x.array[0]) if isinstance(x, LuaTable) and x.array else None
                if p is not None and p not in taken:
                    extra.append((p, x))
            lst += extra
            ctx.report["notes"].append(f"{where}: [{name}] GetItemsFromDiff = {src} (+{len(extra)} rows at positions "
                                       f"{[p for p, _ in extra]})")
        elif src:
            ctx.report["notes"].append(f"{where}: [{name}] GetItemsFromDiff = {src} not found")
        lst.sort(key=lambda pr: pr[0])
        out[name] = lst
    return out


def ordered_diffs(dl):
    """Non-side difficulties first (source order), then Alliance, then Horde."""
    names = [n for n in dl if n not in SIDE_OF] + [n for n in ("ALLIANCE_DIFF", "HORDE_DIFF") if n in dl]
    return [(n, dl[n]) for n in names]


def diff_label(dname):
    return dname[:-5].replace("_", " ").title()  # MAIL_DIFF -> "Mail", HEROIC_DIFF -> "Heroic"


def build_pages(sub_name, base_key, dl, row_fn, used, ctx, where, phase=None):
    """Pages for one sub-table: one per difficulty list; side lists -> side pages (key suffix A/H); non-normal
    difficulties (Leather/Mail/Plate/Heroic) -> name suffix " (Mail)" and key suffix."""
    pages = []
    for dname, rows in ordered_diffs(dl):
        side = SIDE_OF.get(dname)
        name, key = sub_name, base_key
        if dname != "NORMAL_DIFF" and not side:
            name, key = f"{sub_name} ({diff_label(dname)})", base_key + diff_label(dname).replace(" ", "")
        if side:
            key += SIDE_LETTER[side]
        items, x, seen = [], OrderedDict(), set()
        for pos, r in rows:
            for ent in row_fn(r, f"{where} [{dname}] pos {pos}"):
                eid, xt, alt = (ent + (None,))[:3]
                if eid in seen and alt and alt not in seen:
                    # a second craft making the same item on this page (Primal Earth from two transmutes): list
                    # that craft as its spell instead of dropping it
                    ctx.skip("same created item twice on a page - second craft listed as its spell",
                             f"{where} [{dname}] {eid} -> {alt}")
                    eid = alt
                elif eid in seen:
                    ctx.skip("duplicate within page", f"{where} [{dname}] {eid}")
                    continue
                seen.add(eid)
                items.append(eid)
                # a text ("Skill 375") stays on the page; a price goes to the item's cost (AtlasCosts)
                if isinstance(xt, str):
                    x[len(items)] = xt
                elif xt and isinstance(eid, int) and eid > 0:
                    ctx.row_prices.setdefault(eid, xt)
        if not items:
            ctx.skip("empty page dropped", f"{where} [{dname}]")
            continue
        page = OrderedDict(key=uniq_key(key, used), name=name)
        if phase:
            page["phase"] = phase
        if side:
            page["side"] = side
        page["items"] = items
        if x:
            page["x"] = x
        pages.append(page)
    return pages


def finish_source(key, name, pages, phase=None, side=None, factionID=None):
    src = OrderedDict(key=key, name=name)
    if phase:
        src["phase"] = phase
    sides = {p.get("side") for p in pages}
    if side is None and len(sides) == 1 and None not in sides:
        side = sides.pop()
    if side:
        src["side"] = side
    if factionID:
        src["factionID"] = factionID
    src["pages"] = pages
    return src


# --------------------------------------------------------------------------------------
# Prices
# --------------------------------------------------------------------------------------
def cost_string(price):
    """OrderedDict / dict price with AtlasLoot keys -> the addon's cost string ("c1901:22950,29024:10"), or None when a
    part has a key COST_KEYS doesn't know (or the price is empty / not positive)."""
    parts = []
    for k, v in price.items():
        key = COST_KEYS.get(k)
        if key is None or not isinstance(v, int) or v <= 0:
            return None
        parts.append(f"{key}:{v}")
    return ",".join(parts) or None


def load_learned_prices(ctx):
    """AtlasLoot's vendor scans on this PC: {itemID: OrderedDict price}. Every account's AtlasLootClassic.lua saved
    variables, the newest file last (it wins). Missing files are fine (a PC without AtlasLoot: none)."""
    import glob
    files = sorted(glob.glob(os.path.join(P_WTF_ACCOUNTS, "*", "SavedVariables", "AtlasLootClassic.lua")),
                   key=os.path.getmtime)
    out, per_file = {}, OrderedDict()
    for path in files:
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        try:
            lua.execute(read(path))
        except Exception as e:  # a broken saved-variables file: skip it, say so
            ctx.report["notes"].append(f"learned prices: {path} not readable ({e})")
            continue
        db = lua.globals().AtlasLootClassicDB
        vp = db and db["global"] and db["global"]["VendorPrice"]
        n = 0
        if vp:
            for k, v in vp.items():
                if isinstance(k, int) and isinstance(v, str):
                    price = parse_price(v)
                    if price:
                        out[k] = price
                        n += 1
        per_file[os.path.relpath(path, P_WTF_ACCOUNTS)] = n
    ctx.report["learned_price_files"] = per_file
    return out


# --------------------------------------------------------------------------------------
# Loaders
# --------------------------------------------------------------------------------------
def profession_created_fixes():
    """spellID -> created item from AtlasLoot's `-- fix` lines after the BCC table (`PROFESSION[36686][1] = 24272`):
    the cooldown cloths (Shadowcloth, Spellcloth, Primal Mooncloth) are `{ nil, ... }` in the table itself, and
    AtlasLoot fills in what they make right after it on a TBC client. Only field 1 (the created item) is fixed there;
    a fix of any other field stops the generator (it would not know what that field means here)."""
    src = read(S.P_PROFESSION)
    start = src.index("PROFESSION_DATA.BCC")
    end = src.find("PROFESSION_DATA.WRATH", start)
    fixes = {}
    for sp, field, v in re.findall(r"PROFESSION\[(\d+)\]\[(\d+)\]\s*=\s*(\d+)", src[start:end if end > 0 else None]):
        if field != "1":
            raise SystemExit(f"Profession.lua fix line for field {field} of {sp}: not handled")
        fixes[int(sp)] = int(v)
    return fixes


def load_professions_tbc():
    """spellID -> (createdItem or None, skill, version) as AtlasLoot sees it on a TBC client (CLASSIC, then BCC
    overriding, then the BCC fix lines); the set of spells that exist only in the WRATH table; spellID -> the row's
    `-- comment` (the created item's / spell's name, present on some rows; fallback names only)."""
    out, cmts = {}, {}
    _, comments = tokenize(read(S.P_PROFESSION))
    fixes = profession_created_fixes()
    for ver in ("CLASSIC", "BCC"):
        t = version_table(S.P_PROFESSION, "PROFESSION_DATA", ver)
        for sp, v in t.hash.items():
            a = v.array
            item = fixes[sp] if ver == "BCC" and sp in fixes else (int_val(a[0]) if a else None)
            out[sp] = (item, int_val(a[2]) if len(a) > 2 else None, ver)
            c = (comments.get(v.line_start) or "").strip()
            if c:
                cmts[sp] = c
    wr = version_table(S.P_PROFESSION, "PROFESSION_DATA", "WRATH")
    wrath_only = {sp for sp in wr.hash if sp not in out}
    return out, wrath_only, cmts


def load_crafts_tbc(ctx):
    """spellID -> (createdItem or 0, numberMade, [(reagent, count), ...], skill, version, profession) for every craft AtlasLoot
    knows on a TBC client (CLASSIC, then BCC overriding, then the BCC fix lines; rows are { created, prof, skill, low,
    high, {reagents}, {counts}, made? }). Rows without a reagent list or with lists of different lengths are skipped
    (reported)."""
    out = {}
    fixes = profession_created_fixes()
    for ver in ("CLASSIC", "BCC"):
        t = version_table(S.P_PROFESSION, "PROFESSION_DATA", ver)
        for sp, v in t.hash.items():
            a = v.array
            if ver == "BCC" and sp in fixes:
                a = [fixes[sp]] + list(a[1:])
            if len(a) < 7 or not isinstance(a[5], LuaTable) or not isinstance(a[6], LuaTable):
                ctx.skip("craft without a reagent list (Profession.lua)", f"{ver} {sp}")
                continue
            ids = [int_val(x) for x in a[5].array]
            ns_ = [int_val(x) for x in a[6].array]
            if len(ids) != len(ns_) or not ids or any(not i or i <= 0 for i in ids) or any(not n or n <= 0 for n in ns_):
                ctx.skip("craft with a bad reagent list (Profession.lua)", f"{ver} {sp} {ids} {ns_}")
                continue
            made = int_val(a[7]) if len(a) > 7 else None
            out[sp] = (int_val(a[0]) or 0, made if made and made > 0 else 1, list(zip(ids, ns_)),
                       int_val(a[2]) or 0, ver, int_val(a[1]) or 0)
    return out


# Disenchanted materials whose only crafts are Classic leftovers (Arcane Dust from an Arcane Crystal, Small Prismatic
# Shard from a Nexus Crystal): a breakdown would point players at the wrong source, so it stops at them.
NO_BREAKDOWN_ITEMS = {22445: "Arcane Dust", 22448: "Small Prismatic Shard"}


def conversions(crafts):
    """The crafts a materials breakdown never goes through: crafts that only turn one material into another on a loop
    (one kind of reagent, no more of it than the craft makes, and the reagent can itself be crafted from the result:
    transmutes Primal Air -> Primal Fire -> Primal Earth -> ..., the Large -> Small Prismatic Shard shatter), and every
    craft of NO_BREAKDOWN_ITEMS. Gem cuts, cooking and smelting are one-to-one too but no loop: they stay."""
    makes = defaultdict(list)
    for sp, c in crafts.items():
        if c[0]:
            makes[c[0]].append(sp)

    def reaches(start, target):
        seen, stack = set(), [start]
        while stack:
            i = stack.pop()
            if i == target:
                return True
            if i not in seen:
                seen.add(i)
                for sp in makes.get(i, ()):
                    stack.extend(r for r, _ in crafts[sp][2])
        return False
    return {sp for sp, (item, made, reagents, _, _, _) in crafts.items()
            if item in NO_BREAKDOWN_ITEMS or (item and len(reagents) == 1 and reagents[0][1] <= made
                                              and reaches(reagents[0][0], item))}


def craft_for_items(crafts, conv):
    """createdItem -> spell for the items more than one craft makes (Large Prismatic Shard, Primal Fire, ...): a real
    craft before a conversion, a TBC craft first, then the lowest required skill, then the lowest spell id. Items one
    craft makes need no entry."""
    by_item = defaultdict(list)
    for sp, (item, _, _, skill, ver, _) in crafts.items():
        if item:
            by_item[item].append((sp in conv, 0 if ver == "BCC" else 1, skill, sp))
    return OrderedDict((item, sorted(c)[0][3]) for item, c in sorted(by_item.items()) if len(c) > 1)


def load_item_sets_tbc():
    """setID -> ([itemIDs], name): ItemSet.lua BCC (S.load_item_sets) with the CLASSIC table as fallback."""
    sets = dict(load_item_sets())
    toks, comments = tokenize(read(S.P_ITEMSET))
    t = version_table(S.P_ITEMSET, "ITEM_SET_DATA_RAW", "CLASSIC")
    for sid, v in t.hash.items():
        if sid in sets or not v.array or not isinstance(v.array[0], LuaTable):
            continue
        sets[sid] = ([int(x) for x in v.array[0].array], comments.get(v.line_start, ""))
    return sets


def load_addon_ids():
    """Every item id in DisasterZone's Data/Items.lua, Dungeons.lua, Sources.lua (run in Lua 5.1), plus names from
    the `-- comment` of those files (fallback names only)."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    loader = lua.eval("function(s, n) local f, e = loadstring(s, n); return f, e end")
    ns = lua.table()
    for p in P_ADDON_DATA:
        src = open(p, encoding="utf-8").read()
        f, e = loader(src, "@" + os.path.basename(p))
        if f is None:
            raise SystemExit(f"cannot load {p}: {e}")
        f("DisasterZone", ns)
    D = ns.Data
    ids = OrderedDict()  # id -> first origin

    def add(v, origin):
        if isinstance(v, (int, float)) and int(v) == v and v > 0:
            ids.setdefault(int(v), origin)

    def arr(t):
        return [t[i] for i in range(1, len(t) + 1)] if t is not None else []
    for r in arr(D.Raids):
        for b in arr(r.bosses):
            for v in arr(b["items"]):
                add(v, f"Raids/{r.key}/{b.key}")
    for tok, pieces in (D.Tokens or {}).items():
        add(tok, "Tokens")
        for v in arr(pieces):
            add(v, f"Tokens/{tok}")
    for a, b in (D.Upgrades or {}).items():
        add(a, "Upgrades")
        add(b, "Upgrades")
    for tok, e in (D.TokenArenaExchanges or {}).items():
        add(tok, "TokenArenaExchanges")
        for v in arr(e["items"] if e is not None else None):
            add(v, f"TokenArenaExchanges/{tok}")
    for d in arr(D.Dungeons):
        for b in arr(d.bosses):
            for fld in ("items", "heroicItems"):
                for v in arr(b[fld]):
                    add(v, f"Dungeons/{d.key}/{b.key}")
    for kind in ("Crafted", "Reputation", "Badges", "PvP"):
        for g in arr(D[kind]):
            for it in arr(g["items"]):
                add(it.id, f"Sources/{kind}/{g.key}")
    # TierPieceClass keys are the tier pieces (already Tokens pieces); checked only
    tpc_extra = [int(k) for k in (D.TierPieceClass or {}).keys() if int(k) not in ids]
    boss_ids = OrderedDict((i, o) for i, o in ids.items() if o.startswith(("Raids/", "Dungeons/")))
    upgrades = {int(a): int(b) for a, b in (D.Upgrades or {}).items()}
    names = {}
    rxs = [re.compile(r"^\s*(\d+), -- (.+)$"), re.compile(r"^\s*\{ id = (\d+),.*\}, -- (.+)$"),
           re.compile(r"^\s*\[(\d+)\] = \{ -- (.+)$"), re.compile(r"^\s*\[(\d+)\] = \{ patch = .*-- (.+)$")]
    up = re.compile(r"^\s*\[(\d+)\] = (\d+), -- (.+?) -> (.+)$")
    for p in P_ADDON_DATA:
        for line in open(p, encoding="utf-8"):
            m = up.match(line)
            if m:
                names.setdefault(int(m.group(1)), m.group(3).strip())
                names.setdefault(int(m.group(2)), m.group(4).strip())
                continue
            for rx in rxs:
                m = rx.match(line)
                if m:
                    names.setdefault(int(m.group(1)), re.sub(r"\s*\[.*$", "", m.group(2)).strip())
                    break
    return ids, names, tpc_extra, boss_ids, upgrades


# --------------------------------------------------------------------------------------
# Builders
# --------------------------------------------------------------------------------------
def parse_file(path):
    toks, comments = tokenize(read(path))
    return find_data_tables(toks), comments, scan_local_consts(toks)


def item_row_fn(comments, ctx, prices=None, unpriced_cat=None, boj_only=False):
    """Row -> [(itemID, price)] for Item-type tables; price (OrderedDict) from the row's PRICE_EXTRA, else
    VendorPrice; formatted per page by format_costs."""
    def fn(r, where):
        a = r.array
        iid = int_val(a[1]) if len(a) > 1 else None
        if iid is None:
            v = a[1] if len(a) > 1 else None
            if isinstance(v, tuple) and v[0] == "str":
                ctx.skip("icon / header / marker string row", f"{where} {v[1]}")
            else:
                ctx.skip("row without an id", where)
            return []
        if len(a) > 2 and int_val(a[2]):
            ctx.skip("secondary id in row ignored (kept the main id)", f"{where} {iid} (+{a[2]})")
        c = re.sub(r"\s+\d{4,6}$", "", row_comment(comments, r))  # "Balebrew Charm 37128" (old id) -> name
        if c:
            ctx.comment_names.setdefault(iid, c)
        price = None
        if prices is not None:
            pe = next((v for k, v in r.hash.items() if ident(k) == "PRICE_EXTRA_ITTYPE"), None)
            price = parse_price(pe[1]) if isinstance(pe, tuple) and pe[0] == "str" else None
            if not price:
                price = OrderedDict(prices.get(iid) or {})
                if boj_only:
                    price = OrderedDict((k, v) for k, v in price.items() if k == "BoJ")
            if not price:
                price = None
                if unpriced_cat:
                    ctx.x_unpriced[unpriced_cat] += 1
        return [(iid, price)]
    return fn


def build_crafting(ctx, PROF, WRATH_ONLY):
    tables, comments, consts = parse_file(S.P_CRAFTING)
    sources = []
    for al_key, tbl in tables.items():
        if al_key not in CRAFTING:
            ctx.report["notes"].append(f"crafting table {al_key} not in the configured list - added with a derived name")
        key, disp = CRAFTING.get(al_key, (make_key(al_key[:-2] if al_key.endswith("BC") else al_key, al_key),
                                          clean_text(text(tbl.get("name"), consts)) or al_key))
        top_type = ident(tbl.get("TableType"))
        pages, used = [], set()
        for si, sub in enumerate(tbl.get("items").array):
            if not isinstance(sub, LuaTable):
                ctx.skip("non-table sub-table (version-gated)", f"crafting/{al_key}#{si + 1}")
                continue
            sname = clean_text(text(sub.get("name"), consts)) or disp
            sub_type = ident(sub.get("TableType")) or top_type
            where = f"crafting/{al_key}/{sname}"
            if sub_type == "PROF_ITTYPE":
                def fn(r, w, al_key=al_key):
                    a = r.array
                    v = a[1] if len(a) > 1 else None
                    sp = int_val(v)
                    if sp is None and isinstance(v, tuple) and v[0] == "str" and re.match(r"^[se]\d+$", v[1]):
                        sp = int(v[1][1:])
                    if sp is None:
                        ctx.skip("icon / header / marker string row", f"{w} {v[1] if isinstance(v, tuple) else v}")
                        return []
                    c = strip_skill(row_comment(comments, r))
                    if sp in WRATH_ONLY:
                        ctx.skip("Wrath-only craft spell (PROFESSION_DATA.WRATH only)", f"{w} {sp} {c}")
                        return []
                    pv = PROF.get(sp)
                    if pv is None:
                        ctx.skip("craft spell not in Profession.lua - listed as a spell", f"{w} {sp} {c}")
                        m = re.search(r"\((\d+)\)\s*$", row_comment(comments, r))
                        ctx.spell_names.setdefault(sp, c)
                        return [(-sp, f"Skill {m.group(1)}" if m else None)]
                    item, skill, _ = pv
                    xt = f"Skill {skill}" if skill else None
                    if c:
                        ctx.spell_names.setdefault(sp, c)
                    if item:
                        if c:  # name fallback for created items Questie lacks (the comment is the item's name)
                            ctx.comment_names.setdefault(item, c)
                        return [(item, xt, -sp)]
                    return [(-sp, xt)]
            else:
                fn = item_row_fn(comments, ctx)
            dl = diff_lists(sub, where, ctx)
            pages += build_pages(sname, make_key(sname, f"Page{si + 1}"), dl, fn, used, ctx, where,
                                 phase=int_val(sub.get("ContentPhaseBC")))
        if pages:
            sources.append(finish_source(key, disp, pages, phase=int_val(tbl.get("ContentPhaseBC"))))
        else:
            ctx.skip("source without pages dropped", f"crafting/{al_key}")
    return sources


def build_reputation(ctx):
    tables, comments, consts = parse_file(S.P_FACTIONS)
    sources = []
    for al_key, tbl in tables.items():
        if al_key == "DUMMY":
            continue
        if al_key in FACTIONS:
            key, disp = FACTIONS[al_key]
        else:
            key = make_key(al_key, al_key)
            disp = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", al_key)
            ctx.report["notes"].append(f"faction table {al_key} not in FACTIONS - name derived from the key: {disp}")
        fid = int_val(tbl.get("FactionID"))
        phase = int_val(tbl.get("ContentPhaseBC"))
        rule = FACTION_PHASE_RULES.get(key, {})
        if not phase and rule.get("phase"):
            phase = rule["phase"]
            ctx.report["notes"].append(f"reputation/{key}: phase {phase} from gen_cdloot_sources FACTION_PHASE_RULES "
                                       "(AtlasLoot has no ContentPhaseBC)")
        pages, used = [], set()
        for si, sub in enumerate(tbl.get("items").array):
            if not isinstance(sub, LuaTable):
                ctx.skip("non-table sub-table (version-gated)", f"reputation/{al_key}#{si + 1}")
                continue
            sname = clean_text(text(sub.get("name"), consts)) or f"Standing {si + 1}"
            pphase = rule.get("standing_phase", {}).get(sname)
            where = f"reputation/{al_key}/{sname}"
            pages += build_pages(sname, make_key(sname, f"Page{si + 1}"), diff_lists(sub, where, ctx),
                                 item_row_fn(comments, ctx), used, ctx, where,
                                 phase=pphase if pphase and pphase != phase else None)
        if pages:
            sources.append(finish_source(key, disp, pages, phase=phase, factionID=fid))
        else:
            ctx.skip("source without pages dropped", f"reputation/{al_key}")
    return sources


def resolve_sub(sub, consts):
    if isinstance(sub, tuple) and sub[0] == "ident" and isinstance(consts.get(sub[1]), LuaTable):
        return consts[sub[1]]  # shared local tables (PVP_INSIGNIA, PVP_GEMS)
    return sub


def known_phase(cat, al_key, tbl, ctx):
    """AtlasLoot ContentPhaseBC, else the phase gen_cdloot_sources.py already knows for that table (None if neither)."""
    ph = int_val(tbl.get("ContentPhaseBC"))
    if ph:
        return ph
    why = None
    if cat == "pvp":
        m = re.match(r"^ArenaS(\d)PvP$", al_key)
        if m and S.SEASON_PHASE.get(int(m.group(1))):
            ph, why = S.SEASON_PHASE[int(m.group(1))], f"S.SEASON_PHASE (season {m.group(1)})"
        elif S.PVP_TABLES.get(al_key) and S.PVP_TABLES[al_key][2]:
            ph, why = S.PVP_TABLES[al_key][2], "S.PVP_TABLES fixed phase"
    elif cat == "vendors" and al_key == BADGE_P1_TABLE:
        ph, why = 1, "gen_cdloot_sources build_badges rule (no P<n> in the table name = phase 1)"
    if ph:
        ctx.report.setdefault("phase_not_from_atlasloot", {})[f"{cat}/{al_key}"] = f"{ph} ({why})"
    return ph


def build_item_tables(ctx, path, config, cat, PRICES, priced=True, boj_only=False, set_subs=None, set_phase=None):
    """Generic builder for Item-type AtlasLoot tables (PvP, vendors, collections, events).  set_subs: dict that
    receives the SET_ITTYPE sub-tables (PvP) instead of emitting them."""
    tables, comments, consts = parse_file(path)
    sources = []
    for al_key, (key, disp) in config.items():
        tbl = tables.get(al_key)
        if tbl is None:
            ctx.report["notes"].append(f"{cat}: AtlasLoot table {al_key} not found")
            continue
        gv = tbl.get("gameVersion")
        if gv is not None and "WRATH" in repr(gv):
            ctx.skip("non-TBC table (gameVersion)", f"{cat}/{al_key}")
            continue
        ctx.report.setdefault("atlasloot_names", {})[f"{cat}/{al_key}"] = clean_text(text(tbl.get("name"), consts)) \
            if tbl.get("name") is not None else None
        top_type = ident(tbl.get("TableType"))
        pages, used = [], set()
        for si, sub in enumerate(tbl.get("items").array):
            sub = resolve_sub(sub, consts)
            if not isinstance(sub, LuaTable):
                ctx.skip("version-gated sub-table (AtlasLoot:GameVersion_* call, Wrath-only)", f"{cat}/{al_key}#{si + 1}")
                continue
            sname = clean_text(text(sub.get("name"), consts)) if sub.get("name") is not None else None
            if not sname:
                mid = int_val(sub.get("MapID"))
                sname = AREA_NAMES.get(mid) if mid else None
                sname = sname or disp
            sub_type = ident(sub.get("TableType")) or top_type
            where = f"{cat}/{al_key}/{sname}"
            if sub_type == "SET_ITTYPE":
                if set_subs is not None:
                    set_subs.setdefault(al_key, []).append(sub)
                    ctx.skip("set sub-table moved to the Sets category", where)
                else:
                    ctx.skip("set sub-table (not handled here)", where)
                continue
            fn = item_row_fn(comments, ctx, prices=PRICES if priced else None, unpriced_cat=cat, boj_only=boj_only)
            pages += build_pages(sname, make_key(sname, f"Page{si + 1}"), diff_lists(sub, where, ctx), fn, used, ctx,
                                 where, phase=int_val(sub.get("ContentPhaseBC")))
        phase = known_phase(cat, al_key, tbl, ctx)
        if set_phase is not None:
            set_phase[al_key] = phase
        if pages:
            sources.append(finish_source(key, disp, pages, phase=phase))
        else:
            ctx.skip("source without pages dropped", f"{cat}/{al_key}")
    return sources, comments


def set_class_label(c):
    """Set row comment -> (class, role label or None): "Priest / Heal" -> ("Priest", "Heal"), "Warlock 2" ->
    ("Warlock", None), "Paladin / DD" -> ("Paladin", "Ret"), "Shaman / Enh" -> ("Shaman", "Enh")."""
    c = re.sub(r"\s+\d+$", "", (c or "").strip())
    m = re.match(r"^(\w+)\s*/\s*(\w+)$", c)
    if m:
        cl, raw = m.group(1), m.group(2)
        return cl, CLASS_ROLE_NAMES.get((cl, raw), ROLE_NAMES.get(raw, raw))
    return c, None


def build_sets(ctx, SETS_DB, pvp_set_subs, set_phase):
    """Sets category: one page per item set - key = set ID (+A/H for a faction's list), name = "<Class> (<Role>)",
    title = the full set name, items = the set's pieces. Pages sorted by class, role, faction, AtlasLoot order."""
    toks, comments_dr = tokenize(read(S.P_DUNGEONSRAIDS))
    consts_dr = scan_local_consts(toks)
    _, comments_pvp, _ = parse_file(S.P_PVP)
    sources = []
    for key, name, (kind, ref) in SETS:
        if kind == "tier":
            sub = consts_dr.get(ref)
            subs, comments = ([sub] if isinstance(sub, LuaTable) else []), comments_dr
            phase = TIER_PHASE.get(key)
        else:
            subs, comments = pvp_set_subs.get(ref, []), comments_pvp
            phase = set_phase.get(ref)
        if not subs:
            ctx.report["notes"].append(f"sets/{key}: no set table found ({ref})")
            continue
        found, used = [], set()  # (sort key, page)
        for sub in subs:
            where = f"sets/{key}"
            for dname, rows in ordered_diffs(diff_lists(sub, where, ctx)):
                side = SIDE_OF.get(dname)
                for pos, r in rows:
                    w = f"{where} [{dname}] pos {pos}"
                    sid = int_val(r.array[1]) if len(r.array) > 1 else None
                    if sid is None:
                        ctx.skip("set row without a set id", w)
                        continue
                    if sid not in SETS_DB or not SETS_DB[sid][0]:
                        ctx.skip("set id not in ItemSet.lua (BCC/CLASSIC)", f"{w} {sid}")
                        continue
                    ids, sname = SETS_DB[sid]
                    cl, role = set_class_label(row_comment(comments, r))
                    pname = f"{cl} ({role})" if role else (cl or f"Set {sid}")
                    if len(pname) > MAX_SET_PAGE_NAME:
                        ctx.report.setdefault("set_page_names_long", []).append({"where": w, "name": pname})
                    page = OrderedDict(key=uniq_key(f"{sid}" + (SIDE_LETTER[side] if side else ""), used),
                                       name=pname, title=cmt(sname) or f"Set {sid}")
                    if side:
                        page["side"] = side
                    page["items"] = list(OrderedDict.fromkeys(ids))
                    order = (cl or "~", role or "", {"Alliance": 1, "Horde": 2}.get(side, 0), len(found))
                    found.append((order, page))
        pages = [pg for _, pg in sorted(found, key=lambda t: t[0])]
        if pages:
            if not phase:
                ctx.report["notes"].append(f"sets/{key}: no known phase")
            sources.append(finish_source(key, name, pages, phase=phase))
    return sources


# --------------------------------------------------------------------------------------
# Recipes
# --------------------------------------------------------------------------------------
def build_recipes(scope_ids, REC_BY_ITEM, PROF, WRATH_ONLY, Q, ctx):
    """recipeItemID -> createdItemID (or -spellID when the craft makes no item) for every recipe item in scope
    (Recipe.lua: recipe -> spell; Profession.lua: spell -> created item)."""
    out = OrderedDict()
    unmapped = []
    for iid in sorted(scope_ids):
        r = REC_BY_ITEM.get(iid)
        q = Q.get(iid) or {}
        if r is None:
            nm = q.get("name") or ctx.comment_names.get(iid) or ""
            if q.get("cls") == 9 or RECIPE_PREFIX_RX.match(nm):
                unmapped.append({"id": iid, "name": nm, "reason": "not in Recipe.lua (CLASSIC/BCC)"})
            continue
        sp = r[2]
        pv = PROF.get(sp)
        if pv is None:
            unmapped.append({"id": iid, "name": q.get("name") or ctx.comment_names.get(iid), "spell": sp,
                             "reason": "Wrath-only craft spell" if sp in WRATH_ONLY else
                             "Recipe.lua spell is not a craft in Profession.lua (fishing lure / book, ...)"})
            continue
        out[iid] = pv[0] if pv[0] else -sp
    ctx.report["recipes_unmapped"] = unmapped
    return out


# --------------------------------------------------------------------------------------
# Lua writer
# --------------------------------------------------------------------------------------
HEADER = """\
-- AUTO-GENERATED by gen_atlas.py - do not edit by hand; re-run the generator instead.
-- Sources (all read locally; AtlasLootClassic data is GPL v2):
--   AtlasLootClassic_Crafting/data-tbc.lua     every TBC profession table and sub-table (rows are craft spell IDs,
--                                              except the Item tables: raw gems, herbs, fish)
--   AtlasLootClassic/Data/Profession.lua       spell -> created item + required skill (CLASSIC, BCC overriding)
--   AtlasLootClassic/Data/Recipe.lua           recipe item -> craft spell (CLASSIC + BCC)
--   AtlasLootClassic_Factions/data-tbc.lua     TBC faction tables: FactionID, ContentPhaseBC, standing sub-tables
--   AtlasLootClassic_PvP/data-tbc.lua          honor / reputation / arena season tables, PvP mounts, world PvP
--   AtlasLootClassic_Collections/data-tbc.lua  Badge of Justice + Sunmote vendors, world epics, mounts, companions,
--                                              tabards, legendaries, Children's Week, Midsummer, Brewfest, Hallow's End
--   AtlasLootClassic_DungeonsAndRaids/data-tbc.lua  T4_SET / T5_SET / T6_SET (item set ids per class)
--   AtlasLootClassic/Data/ItemSet.lua          set id -> item ids + set name (BCC, CLASSIC fallback)
--   AtlasLootClassic/Data/VendorPrice.lua      badge / honor / mark / token / money costs
--   WTF/Account/*/SavedVariables/AtlasLootClassic.lua  AtlasLoot's vendor scans on the author's PC: the prices the
--                                              realm's vendors asked (first choice for AtlasCosts)
--   Questie/Database/TBC/tbcItemDB.lua         English item names (fallback: the AtlasLoot row comment)
--   DisasterZone Data/Items.lua, Dungeons.lua, Sources.lua  item ids the Atlas tab also lists (names; the raid /
--                                              dungeon boss lists for recipes; Upgrades for the Sunmote page)
--
-- ns.Data.Atlas = { { key, name, sources = { { key, name, phase?, side?, factionID?, pages = {
--                     { key, name, title?, phase?, side?, items = { ... }, x? } } } } } }
--   Raids and 5-man dungeons are NOT here (ns.Data.Raids / ns.Data.Dungeons).
--   categories: crafting, reputation, pvp, vendors (Badges & Sunmote), collections, events (World Events), sets.
--   items: positive = item ID; negative = -spellID of a craft that creates no item (enchants ...). No strings.
--   Sets: one page per item set: key = set ID (+ "A"/"H" for a faction's list), name = "<Class>" or
--         "<Class> (<Role>)" (below 20 characters: "Priest (Heal)", "Shaman (Enh)", "Paladin (Ret)"),
--         title = the full set name ("Merciless Gladiator's Dreadgear"), items = the set's pieces (ItemSet.lua).
--         Pages sorted by class, then role.
--   Rows keep AtlasLoot's reading order (ascending position: left column, right column, then page 2+).
--   Crafting rows are the CREATED item (or -spell); a sub-table with Leather/Mail/Plate lists becomes one page per
--   armor type (" (Mail)"); Heroic lists likewise (" (Heroic)").
--   side = "Alliance"/"Horde": a sub-table with both faction lists becomes two pages (keys suffixed A/H); a source
--          whose pages are all one faction's carries the side too.
--   phase = set whenever known, 1 included: AtlasLoot ContentPhaseBC (source or page), else the rules
--          gen_cdloot_sources.py uses: faction rules (Sha'tari Skyguard 2, Netherwing 3), PvP tables (Honor /
--          Reputation / world PvP 1; arena Season 1/2/3/4 = 1/2/3/5), the P1 Badge of Justice table 1;
--          Tier 4/5/6 = 1/2/3; every Sets source has one. No phase = not known (crafting, most factions, ...).
--   x = { [itemIndex] = "short text" } shown at the row's right (at most 16 characters): "Skill 375" (crafting,
--       Profession.lua required skill). Prices are not here: ns.Data.AtlasCosts, per item.
--   PvP: the arena / honor / reputation SET sub-tables live under Sets; every other PvP sub-table stays under PvP.
-- ns.Data.AtlasCosts = { [itemID] = "key:amount,key:amount" } what an item costs at its vendor (Core/Currency.lua):
--   key "c<currencyID>" = a currency (c1901 Honor, c1900 Arena Points), "g" = money in copper, a number = an item
--   that pays (29434 Badge of Justice, 20560 Alterac Valley Mark, 34664 Sunmote ...). First choice: the realm's own
--   prices from AtlasLoot's vendor scans (PvP prices change with the arena seasons), then the AtlasLoot row's price,
--   then VendorPrice.lua; a Sunmote upgrade costs one Sunmote (plus its base drop, the row under it).
-- ns.Data.AtlasNames = { [id] = "English name" } for every id the Atlas tab can list: the ids above (items positive,
--   craft spells negative) plus every item id of Data/Items.lua (raid loot, tokens + pieces, upgrades, arena token
--   exchanges), Data/Dungeons.lua and Data/Sources.lua, plus every AtlasRecipes value.
-- ns.Data.AtlasRecipes = { [recipeItemID] = createdItemID or -spellID } for every recipe / pattern / plans / formula
--   / design / schematic / manual the Atlas tab lists (ns.Data.Atlas and the raid / dungeon boss lists):
--   Recipe.lua recipe -> spell, Profession.lua spell -> created item (-spellID when it creates none).
-- ns.Data.AtlasCrafts = { [spellID] = "created,made,reagent,count,reagent,count,..." } for every craft on a TBC
--   client (Profession.lua CLASSIC + BCC): the created item (0: none, an enchant), how many one craft makes, then
--   each reagent and how many one craft needs. A string per craft (parsed when shown): far less memory than tables.
-- ns.Data.AtlasCraftFor = { [createdItemID] = spellID } only for items more than one craft makes (a real craft before
--   a conversion, a TBC craft first, then the lowest skill). AtlasNames also names every reagent.
-- ns.Data.AtlasConversions = { [spellID] = true } crafts that breaking materials down (Shift + click in a tooltip)
--   never goes through: one-material conversions on a loop (transmutes, the Prismatic Shard shatter) and the Classic
--   crafts of disenchanted materials (Arcane Dust, Small Prismatic Shard).
"""


def lua_item_line(e, names, indent):
    if isinstance(e, str):
        return f"{indent}{lua_str(e)},"
    nm = names.get(e)
    return f"{indent}{e}," + (f" -- {cmt(nm)}" if nm else "")


def write_lua(path, tree, names, recipes, crafts, craft_for, conv, costs):
    L = [FIRST_LINE, HEADER.rstrip("\n"), "local _, ns = ...", "ns.Data = ns.Data or {}", "",
         "-- Browse tree beyond raids / dungeons. categories -> sources -> pages -> items.", "ns.Data.Atlas = {"]
    for cat in tree:
        L.append(f"  {{ key = {lua_str(cat['key'])}, name = {lua_str(cat['name'])}, sources = {{")
        for src in cat["sources"]:
            f = [f"key = {lua_str(src['key'])}", f"name = {lua_str(src['name'])}"]
            if src.get("phase"):
                f.append(f"phase = {src['phase']}")
            if src.get("side"):
                f.append(f"side = {lua_str(src['side'])}")
            if src.get("factionID"):
                f.append(f"factionID = {src['factionID']}")
            L.append("    { " + ", ".join(f) + ", pages = {")
            for pg in src["pages"]:
                f = [f"key = {lua_str(pg['key'])}", f"name = {lua_str(pg['name'])}"]
                if pg.get("title"):
                    f.append(f"title = {lua_str(pg['title'])}")
                if pg.get("phase"):
                    f.append(f"phase = {pg['phase']}")
                if pg.get("side"):
                    f.append(f"side = {lua_str(pg['side'])}")
                L.append("      { " + ", ".join(f) + ", items = {")
                for e in pg["items"]:
                    L.append(lua_item_line(e, names, "          "))
                if pg.get("x"):
                    xs = [f"[{i}] = {lua_str(t)}" for i, t in pg["x"].items()]
                    L.append("      }, x = {")
                    for k in range(0, len(xs), 6):
                        L.append("          " + ", ".join(xs[k:k + 6]) + ",")
                L.append("      } },")
            L.append("    }},")
        L.append("  }},")
    L.append("}")
    L.append("")
    L.append("-- What a recipe / pattern / plans / formula / design / schematic / manual teaches: the created item")
    L.append("-- (positive) or -spellID when the craft makes no item (enchants).")
    L.append("ns.Data.AtlasRecipes = {")
    for r in sorted(recipes):
        v = recipes[r]
        L.append(f"  [{r}] = {v}, -- {cmt(names.get(r, '?'))} -> {cmt(names.get(v, '?'))}")
    L.append("}")
    L.append("")
    L.append("-- Every craft's materials: [spellID] = \"created,made,reagent,count,...\" (created 0: makes no item).")
    L.append("ns.Data.AtlasCrafts = {")
    for sp in sorted(crafts):
        item, made, reagents = crafts[sp][:3]
        parts = [item, made] + [x for pair in reagents for x in pair]
        L.append(f"  [{sp}] = \"{','.join(str(p) for p in parts)}\",")
    L.append("}")
    L.append("")
    L.append("-- The craft shown for an item more than one craft makes.")
    L.append("ns.Data.AtlasCraftFor = {")
    for item, sp in craft_for.items():
        L.append(f"  [{item}] = {sp}, -- {cmt(names.get(item, '?'))}")
    L.append("}")
    L.append("")
    L.append("-- Crafts a materials breakdown never goes through (transmutes, shatters, disenchanted materials).")
    L.append("ns.Data.AtlasConversions = {")
    for sp in sorted(conv):
        L.append(f"  [{sp}] = true, -- {cmt(names.get(crafts[sp][0], '?'))} from {cmt(names.get(crafts[sp][2][0][0], '?'))}")
    L.append("}")
    L.append("")
    L.append("-- What an item costs at its vendor: \"key:amount,...\" (c<currencyID>, g = copper, <itemID>).")
    L.append("ns.Data.AtlasCosts = {")
    for i in sorted(costs):
        L.append(f"  [{i}] = \"{costs[i]}\", -- {cmt(names.get(i, '?'))}")
    L.append("}")
    L.append("")
    L.append("-- English names for every id the browser can list: items (positive) and craft spells (negative).")
    L.append("ns.Data.AtlasNames = {")
    for i in sorted(names):
        L.append(f"  [{i}] = {lua_str(names[i])},")
    L.append("}")
    L.append("")
    data = "\n".join(L).encode("utf-8")
    with open(path, "wb") as f:
        f.write(data)
    return len(data)


# --------------------------------------------------------------------------------------
# Validation (Lua 5.1)
# --------------------------------------------------------------------------------------
def validate_lua(path, expect_cats):  # noqa: C901
    raw = open(path, "rb").read()
    errs = []
    if raw.startswith(b"\xef\xbb\xbf"):
        errs.append("file has a BOM")
    if b"\r" in raw:
        errs.append("file has CR characters")
    src = raw.decode("utf-8")
    if src.split("\n", 1)[0] != FIRST_LINE:
        errs.append("first line differs from the required boot line")
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    res = lua.eval("function(s, n) local f, e = loadstring(s, n); return f, e end")(src, "@Atlas.lua")
    f, e = res if isinstance(res, tuple) else (res, None)
    if f is None:
        raise SystemExit(f"Lua 5.1 compile error: {e}")
    ns = lua.table()
    f("DisasterZone", ns)
    A, N = ns.Data.Atlas, ns.Data.AtlasNames
    if A is None or N is None:
        raise SystemExit("ns.Data.Atlas / ns.Data.AtlasNames missing")

    def arr(t):
        return [t[i] for i in range(1, len(t) + 1)] if t is not None else []
    counts = Counter()
    cat_keys = []
    tree_ids = set()
    for ci, cat in enumerate(arr(A), 1):
        w0 = f"cat#{ci}"
        if not isinstance(cat.key, str) or not isinstance(cat.name, str):
            errs.append(f"{w0}: key/name")
        cat_keys.append(cat.key)
        srcs = arr(cat.sources)
        if not srcs:
            errs.append(f"{cat.key}: no sources")
        skeys = set()
        for src in srcs:
            w1 = f"{cat.key}/{src.key}"
            if not isinstance(src.key, str) or not isinstance(src.name, str) or not re.match(r"^[A-Za-z0-9_]+$", src.key or ""):
                errs.append(f"{w1}: key/name")
            if src.key in skeys:
                errs.append(f"{w1}: duplicate source key")
            skeys.add(src.key)
            if src.side not in (None, "Alliance", "Horde"):
                errs.append(f"{w1}: bad side {src.side}")
            if src.phase is not None and not (isinstance(src.phase, int) and 1 <= src.phase <= 5):
                errs.append(f"{w1}: bad phase {src.phase}")
            if cat.key == "sets" and src.phase is None:
                errs.append(f"{w1}: Sets source without phase")
            pages = arr(src.pages)
            if not pages:
                errs.append(f"{w1}: no pages")
            pkeys = set()
            for pg in pages:
                w2 = f"{w1}/{pg.key}"
                counts["pages"] += 1
                if not isinstance(pg.key, str) or not isinstance(pg.name, str) or not re.match(r"^[A-Za-z0-9_]+$", pg.key or ""):
                    errs.append(f"{w2}: key/name")
                if pg.key in pkeys:
                    errs.append(f"{w2}: duplicate page key")
                pkeys.add(pg.key)
                if pg.side not in (None, "Alliance", "Horde"):
                    errs.append(f"{w2}: bad side {pg.side}")
                if cat.key == "sets":
                    counts["set_pages"] += 1
                    if not isinstance(pg.title, str) or not pg.title:
                        errs.append(f"{w2}: Sets page without title")
                    if len(pg.name or "") > MAX_SET_PAGE_NAME:
                        errs.append(f"{w2}: Sets page name too long ({pg.name!r})")
                items = arr(pg["items"])
                if not items:
                    errs.append(f"{w2}: empty items")
                prev_str = False
                for k, e in enumerate(items, 1):
                    if isinstance(e, str):
                        counts["headers"] += 1
                        errs.append(f"{w2}#{k}: header string (no page has headers any more)")
                        if prev_str:
                            errs.append(f"{w2}#{k}: two headers in a row (empty section)")
                        prev_str = True
                    elif isinstance(e, int) and e != 0:
                        counts["entries"] += 1
                        counts["spells" if e < 0 else "items"] += 1
                        tree_ids.add(e)
                        prev_str = False
                    else:
                        errs.append(f"{w2}#{k}: bad entry {e!r}")
                if items and isinstance(items[-1], str):
                    errs.append(f"{w2}: header is the last entry")
                if pg.x is not None:
                    for k, t in pg.x.items():
                        if not (isinstance(k, int) and 1 <= k <= len(items)) or not isinstance(t, str) or len(t) > MAX_X:
                            errs.append(f"{w2}: bad x [{k}] = {t!r}")
                        elif isinstance(items[k - 1], str):
                            errs.append(f"{w2}: x on a header [{k}]")
                if pg.xt is not None:
                    errs.append(f"{w2}: xt (prices are AtlasCosts now)")
    if cat_keys != expect_cats:
        errs.append(f"category keys {cat_keys} != {expect_cats}")
    missing = sorted(i for i in tree_ids if N[i] is None)
    if missing:
        errs.append(f"{len(missing)} tree ids without AtlasNames entry: {missing[:20]}")
    n_names = sum(1 for _ in N.keys())
    for k, v in N.items():
        if not isinstance(k, int) or not isinstance(v, str) or not v:
            errs.append(f"AtlasNames bad entry {k!r} = {v!r}")
            break
    counts["names"] = n_names
    counts["tree_unique_ids"] = len(tree_ids)
    CO = ns.Data.AtlasCosts
    if CO is None:
        errs.append("ns.Data.AtlasCosts missing")
    else:
        for k, v in CO.items():
            counts["costs"] += 1
            if not (isinstance(k, int) and k > 0) or N[k] is None:
                errs.append(f"AtlasCosts key {k!r} is not a named item id")
            if not (isinstance(v, str) and COST_RX.match(v)):
                errs.append(f"AtlasCosts[{k!r}] = {v!r}: not key:amount,...")
    R = ns.Data.AtlasRecipes
    if R is None:
        errs.append("ns.Data.AtlasRecipes missing")
    else:
        for k, v in R.items():
            counts["recipes"] += 1
            if not (isinstance(k, int) and k > 0):
                errs.append(f"AtlasRecipes key {k!r} is not an item id")
            elif N[k] is None:
                errs.append(f"AtlasRecipes key {k} has no AtlasNames entry")
            if not (isinstance(v, int) and v != 0):
                errs.append(f"AtlasRecipes[{k}] = {v!r} (not a non-zero id)")
            elif N[v] is None:
                errs.append(f"AtlasRecipes[{k}] = {v} has no AtlasNames entry")
    C, CF = ns.Data.AtlasCrafts, ns.Data.AtlasCraftFor
    if C is None or CF is None:
        errs.append("ns.Data.AtlasCrafts / AtlasCraftFor missing")
    else:
        unnamed = set()
        for k, v in C.items():
            counts["crafts"] += 1
            nums = [int(x) for x in v.split(",")] if isinstance(v, str) and re.match(r"^\d+(,\d+)+$", v) else None
            if not (isinstance(k, int) and k > 0) or not nums or len(nums) < 4 or len(nums) % 2 or nums[1] < 1 \
                    or any(n <= 0 for n in nums[2:]):
                errs.append(f"AtlasCrafts[{k!r}] = {v!r}: not created,made,reagent,count,...")
                continue
            unnamed.update(r for r in nums[2::2] if N[r] is None)
        if unnamed:
            errs.append(f"{len(unnamed)} reagents without AtlasNames entry: {sorted(unnamed)[:20]}")
        for k, v in CF.items():
            created = C[v] and int(C[v].split(",")[0])
            if created != k:
                errs.append(f"AtlasCraftFor[{k}] = {v}: that craft makes {created}")
        CV = ns.Data.AtlasConversions
        if CV is None:
            errs.append("ns.Data.AtlasConversions missing")
        else:
            for k, v in CV.items():
                counts["conversions"] += 1
                if v is not True or C[k] is None:
                    errs.append(f"AtlasConversions[{k!r}] = {v!r}: not a craft")
    return errs, counts, lua, ns


# --------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--out", default=OUT_LUA_DEFAULT)
    args = ap.parse_args()
    ctx = Ctx()
    rep = ctx.report

    Q = load_questie_items()
    PROF, WRATH_ONLY, PROF_CMT = load_professions_tbc()
    _, REC_BY_ITEM = S.load_recipes()
    PRICES = load_vendor_prices()
    SETS_DB = load_item_sets_tbc()
    addon_ids, addon_names, tpc_extra, boss_ids, UPGRADES = load_addon_ids()

    pvp_set_subs, set_phase = OrderedDict(), {}
    crafting = build_crafting(ctx, PROF, WRATH_ONLY)
    reputation = build_reputation(ctx)
    pvp, _ = build_item_tables(ctx, S.P_PVP, PVP, "pvp", PRICES, set_subs=pvp_set_subs, set_phase=set_phase)
    vendors, _ = build_item_tables(ctx, S.P_COLLECTIONS, VENDORS, "vendors", PRICES)
    collections, _ = build_item_tables(ctx, S.P_COLLECTIONS, COLLECTIONS, "collections", PRICES)
    events, _ = build_item_tables(ctx, S.P_COLLECTIONS, EVENTS, "events", PRICES)
    sets = build_sets(ctx, SETS_DB, pvp_set_subs, set_phase)
    # Sunmote page: every upgraded item costs its base Sunwell drop + one Sunmote (ns.Data.Upgrades base -> upgraded);
    # the Sunmote is its cost (AtlasCosts), the base drop shows as the indented row under it
    upgraded = set(UPGRADES.values())
    sunmote_costs = {}
    for src in vendors:
        if src["key"] != VENDORS["BCCSunmote"][0]:
            continue
        for pg in src["pages"]:
            for e in pg["items"]:
                if e in upgraded:
                    sunmote_costs[e] = OrderedDict(sunmote=1)
                else:
                    rep.setdefault("sunmote_not_an_upgrade", []).append({"page": pg["key"], "id": e})
    by_cat = {"crafting": crafting, "reputation": reputation, "pvp": pvp, "vendors": vendors,
              "collections": collections, "events": events, "sets": sets}
    tree = [OrderedDict(key=k, name=n, sources=by_cat[k]) for k, n in CATEGORIES if by_cat[k]]

    # ---- names
    tree_ids = OrderedDict()
    for cat in tree:
        for src in cat["sources"]:
            for pg in src["pages"]:
                for e in pg["items"]:
                    if isinstance(e, int):
                        tree_ids.setdefault(e, f"{cat['key']}/{src['key']}/{pg['key']}")
    rep["tier_piece_class_ids_not_elsewhere"] = tpc_extra
    all_ids = OrderedDict(tree_ids)
    for i, o in addon_ids.items():
        all_ids.setdefault(i, o)
    names, unnamed, name_src = {}, [], Counter()
    for i, origin in all_ids.items():
        if i < 0:
            nm = ctx.spell_names.get(-i)
            if nm:
                names[i] = nm
                name_src["spell: crafting row comment"] += 1
            else:
                unnamed.append({"id": i, "where": origin})
            continue
        q = Q.get(i)
        if q and q.get("name"):
            names[i] = q["name"]
            name_src["Questie TBC item DB"] += 1
        elif ctx.comment_names.get(i):
            names[i] = ctx.comment_names[i]
            name_src["AtlasLoot row comment"] += 1
            rep.setdefault("names_from_atlasloot_comment", {})[str(i)] = names[i]
        elif addon_names.get(i):
            names[i] = addon_names[i]
            name_src["DisasterZone data file comment"] += 1
            rep.setdefault("names_from_addon_comment", {})[str(i)] = names[i]
        else:
            unnamed.append({"id": i, "where": origin})
    # ---- recipes (scope: the tree + the raid / dungeon boss lists) and names for what they teach
    scope = set(i for i in tree_ids if i > 0) | set(boss_ids)
    recipes = build_recipes(scope, REC_BY_ITEM, PROF, WRATH_ONLY, Q, ctx)
    rec_name_src = Counter()
    for r, v in list(recipes.items()):
        if v in names:
            continue
        rname = names.get(r) or (Q.get(r) or {}).get("name") or ""
        stripped = RECIPE_PREFIX_RX.sub("", rname)
        sp = -v if v < 0 else None
        if v > 0 and (Q.get(v) or {}).get("name"):
            nm, how = Q[v]["name"], "Questie TBC item DB"
        elif v > 0 and ctx.comment_names.get(v):
            nm, how = ctx.comment_names[v], "AtlasLoot row comment"
        elif sp and ctx.spell_names.get(sp):
            nm, how = ctx.spell_names[sp], "spell: crafting row comment"
        else:
            spell = sp or next((s_ for s_, pv in PROF.items() if pv[0] == v and REC_BY_ITEM.get(r, (0, 0, 0))[2] == s_), None)
            if spell and PROF_CMT.get(spell):
                nm, how = strip_skill(PROF_CMT[spell]), "Profession.lua row comment"
            elif stripped and stripped != rname:
                nm, how = stripped, "recipe name without its prefix"
            else:
                nm, how = None, None
        if nm:
            names[v] = nm
            rec_name_src[how] += 1
            if how not in ("Questie TBC item DB",):
                rep.setdefault("recipe_value_names_fallback", {})[str(v)] = f"{nm} ({how})"
        else:
            del recipes[r]
            unnamed.append({"id": v, "where": f"AtlasRecipes[{r}] (entry dropped)"})
    rep["recipe_value_name_sources"] = dict(rec_name_src)
    rep["recipes"] = len(recipes)
    rep["name_sources"] = dict(name_src)
    rep["ids_without_names"] = unnamed
    # unnamed ids that are in the tree would break the tree; drop them (reported)
    bad = {u["id"] for u in unnamed if u["id"] in tree_ids}
    if bad:
        for cat in tree:
            for src in cat["sources"]:
                for pg in src["pages"]:
                    old = pg["items"]
                    keep = [e for e in old if not (isinstance(e, int) and e in bad)]
                    if len(keep) != len(old):
                        # remap x
                        if pg.get("x"):
                            nx, j = OrderedDict(), 0
                            for k, e in enumerate(old, 1):
                                if isinstance(e, int) and e in bad:
                                    continue
                                j += 1
                                if k in pg["x"]:
                                    nx[j] = pg["x"][k]
                            pg["x"] = nx
                        pg["items"] = keep
                        for e in old:
                            if isinstance(e, int) and e in bad:
                                ctx.skip("id without any name dropped from the tree", f"{cat['key']}/{src['key']}/{pg['key']} {e}")

    # ---- materials: every craft's reagents, named (a craft with a reagent nobody can name is not on this client:
    # Season of Discovery rows in the CLASSIC table)
    crafts = load_crafts_tbc(ctx)
    reagent_src = Counter()
    for sp in sorted(crafts):
        for r, _ in crafts[sp][2]:
            if r in names:
                continue
            if (Q.get(r) or {}).get("name"):
                names[r] = Q[r]["name"]
                reagent_src["Questie TBC item DB"] += 1
            elif ctx.comment_names.get(r):
                names[r] = ctx.comment_names[r]
                reagent_src["AtlasLoot row comment"] += 1
        missing = [r for r, _ in crafts[sp][2] if r not in names]
        if missing:
            ctx.skip("craft with a reagent without any name (not on a TBC client)", f"{sp} {missing}")
            del crafts[sp]
    conv = conversions(crafts)
    craft_for = craft_for_items(crafts, conv)
    rep["crafts"] = len(crafts)
    rep["reagent_name_sources"] = dict(reagent_src)
    rep["craft_for"] = {str(k): v for k, v in craft_for.items()}

    rep["conversions"] = len(conv)

    # ---- costs: what each item the Atlas can list costs at its vendor. The realm's own prices first (AtlasLoot's
    # vendor scans on this PC), then the AtlasLoot row's price, then VendorPrice.lua, then the Sunmote rule.
    learned = load_learned_prices(ctx)
    costs, cost_src, cost_keys, dropped = OrderedDict(), Counter(), Counter(), []
    for i in sorted(k for k in names if k > 0):
        for how, table in (("AtlasLoot vendor scan (realm)", learned), ("AtlasLoot table row", ctx.row_prices),
                           ("AtlasLoot VendorPrice.lua", PRICES), ("Sunmote upgrade", sunmote_costs)):
            if i in table and table[i]:
                cs = cost_string(table[i])
                if cs:
                    costs[i] = cs
                    cost_src[how] += 1
                    for part in cs.split(","):
                        cost_keys[part.split(":")[0]] += 1
                else:
                    dropped.append({"id": i, "from": how, "price": dict(table[i])})
                break
    rep["costs"] = len(costs)
    rep["cost_sources"] = dict(cost_src)
    rep["cost_keys"] = dict(cost_keys.most_common())
    rep["costs_dropped_unknown_key"] = dropped
    size = write_lua(args.out, tree, names, recipes, crafts, craft_for, conv, costs)
    errs, counts, lua, ns = validate_lua(args.out, [c["key"] for c in tree])

    # ---- report
    rep["output"] = args.out
    rep["bytes"] = size
    rep["validation_errors"] = errs
    rep["validation_counts"] = dict(counts)
    rep["addon_data_ids"] = len(addon_ids)
    rep["atlas_names"] = len(names)
    summary = OrderedDict()
    for cat in tree:
        cs = OrderedDict()
        for src in cat["sources"]:
            cs[src["key"]] = OrderedDict(
                (pg["key"], sum(1 for e in pg["items"] if isinstance(e, int))) for pg in src["pages"])
        summary[cat["key"]] = cs
    rep["counts"] = summary
    rep["skipped_counts"] = {k: len(v) for k, v in sorted(ctx.skipped.items())}
    rep["skipped"] = {k: v[:60] for k, v in sorted(ctx.skipped.items())}
    rep["rows_without_table_price_by_category"] = dict(ctx.x_unpriced)
    unpriced = Counter()
    for c_ in tree:
        for s_ in c_["sources"]:
            for p_ in s_["pages"]:
                for e in p_["items"]:
                    if isinstance(e, int) and e > 0 and e not in costs and c_["key"] in ("pvp", "vendors", "sets"):
                        unpriced[f"{c_['key']}/{s_['key']}"] += 1
    rep["rows_without_cost_pvp_vendors_sets"] = dict(unpriced)
    rep["costs_sample"] = {str(i): costs[i] for i in list(costs)[::max(1, len(costs) // 30)][:30]}

    def page_of(cat_key, src_key, pg_idx=0, pg_key=None):
        for c in tree:
            if c["key"] != cat_key:
                continue
            for s in c["sources"]:
                if s["key"] == src_key:
                    if pg_key:
                        return next((p for p in s["pages"] if p["key"] == pg_key), None)
                    return s["pages"][pg_idx]
        return None

    def show(e):
        return {"id": e, "name": names.get(e)} if isinstance(e, int) else {"header": e}
    spot = OrderedDict()
    pg = page_of("crafting", "Enchanting")
    spot["enchanting_first_page"] = {"page": pg["name"], "first3": [show(e) for e in pg["items"][:3]],
                                     "x": [pg.get("x", {}).get(k) for k in (1, 2, 3)]}
    pg = page_of("reputation", "Shatar", pg_key="Exalted")
    spot["shatar_exalted"] = [show(e) for e in pg["items"]] if pg else None
    t6 = next(s_ for s_ in sets if s_["key"] == "Tier6")
    spot["tier6_pages"] = [{"key": p_["key"], "name": p_["name"], "title": p_["title"], "items": len(p_["items"])}
                           for p_ in t6["pages"]]
    spot["sets_phases"] = {s_["key"]: s_.get("phase") for s_ in sets}
    spot["recipes_sample"] = [{"recipe": r, "recipe_name": names.get(r), "teaches": v, "teaches_name": names.get(v)}
                              for r, v in list(recipes.items())[::max(1, len(recipes) // 5)][:5]]
    spot["recipes_sample_spell"] = next(({"recipe": r, "recipe_name": names.get(r), "teaches": v,
                                          "teaches_name": names.get(v)} for r, v in recipes.items() if v < 0), None)
    mounts = next(s for s in collections if s["key"] == "Mounts")
    spot["mounts_pages"] = [{"key": p["key"], "name": p["name"], "side": p.get("side"),
                             "items": sum(1 for e in p["items"] if isinstance(e, int))} for p in mounts["pages"]]
    spot["file"] = {"bytes": size, "atlas_names": len(names)}
    rep["spot_checks"] = spot
    with open(OUT_REPORT, "w", encoding="utf-8", newline="\n") as f:
        json.dump(rep, f, indent=1, ensure_ascii=False, default=str)

    # ---- console summary
    print(f"wrote {args.out} ({size} bytes, {size / 1024:.0f} KB)")
    for cat in tree:
        n_items = sum(sum(1 for e in p["items"] if isinstance(e, int)) for s in cat["sources"] for p in s["pages"])
        print(f"  {cat['key']:<12} sources={len(cat['sources']):>3} pages={sum(len(s['pages']) for s in cat['sources']):>4} "
              f"entries={n_items}")
    print(f"  validation: {counts.get('pages')} pages, {counts.get('items')} item rows, {counts.get('spells')} spell rows, "
          f"{counts.get('set_pages')} set pages, {counts.get('headers', 0)} headers, {counts.get('tree_unique_ids')} unique ids; "
          f"AtlasNames={counts.get('names')} (addon data ids {len(addon_ids)}); AtlasRecipes={counts.get('recipes')} "
          f"(unmapped recipe items {len(rep['recipes_unmapped'])}); AtlasCrafts={counts.get('crafts')} "
          f"(AtlasCraftFor {len(craft_for)}); errors={len(errs)}")
    for e in errs[:30]:
        print("   ERROR", e)
    print(f"  names: {dict(name_src)}; unnamed: {len(unnamed)}")
    print("  skipped: " + "; ".join(f"{k}={len(v)}" for k, v in sorted(ctx.skipped.items())))
    print(f"  report: {OUT_REPORT}")
    if errs:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
