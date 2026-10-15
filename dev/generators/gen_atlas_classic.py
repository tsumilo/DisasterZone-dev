#!/usr/bin/env python3
"""
Generator for the Classic half of DisasterZone's Atlas browser (Data/AtlasClassic.lua): what a level 1-60 character can
still get on the TBC Anniversary realm - the old world's raids and dungeons, the Classic professions, factions,
battlegrounds, tier sets and world events. The Atlas tab's "Classic | TBC" switch shows this tree instead of the TBC
one (Core/Atlas.lua).

Companion of gen_atlas.py: it IMPORTS it and reuses its AtlasLoot table walkers (build_item_tables, build_crafting,
build_reputation, the set rows) with the Classic tables (data.lua) instead of the TBC ones (data-tbc.lua). AtlasLoot
on a TBC client loads both files, so these are the lists AtlasLoot itself shows there.

Reads (read-only) from an AtlasLootClassic install - the anniversary AddOns folder when AtlasLoot is there, else the
classic_era client's (the same AtlasLoot release carries data.lua for every client):
  * AtlasLootClassic_DungeonsAndRaids/data.lua  -> raids + dungeons (bosses, loot rows, LevelRange)
  * AtlasLootClassic_Crafting/data.lua          -> the Classic profession tables (craft spell rows)
  * AtlasLootClassic_Factions/data.lua          -> the Classic factions (Season of Discovery ones left out)
  * AtlasLootClassic_PvP/data.lua               -> battleground rewards, rank armor / weapons, mounts, insignia, sets
  * AtlasLootClassic_Collections/data.lua       -> tier sets (TierSets), world events open on a TBC client
  * AtlasLootClassic/Data/Profession.lua, Recipe.lua, ItemSet.lua  (as gen_atlas.py)
  * Questie/Database/TBC/tbcItemDB.lua          -> English item names
  * DisasterZone/Data/Atlas.lua (the TBC half)  -> names already shipped (only the missing ones are written here)

Left out: Season of Discovery content (Demon Fall Canyon, Karazhan Crypts, the Scarlet Enclave, SoD tables, SoD ids in
the normal lists), tables AtlasLoot gates to the Classic client (gameVersion = CLASSIC: on a TBC
client their TBC versions show, which the TBC half has).

Writes:
  * <ADDON>/Data/AtlasClassic.lua
  * dev/generators/gen_atlas_classic_report.json

Usage:  luaenv\\Scripts\\python.exe generators\\gen_atlas_classic.py [--out PATH]      (run from the dev folder)
"""
import argparse
import json
import os
import re
import sys
from collections import OrderedDict, Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_atlas as A  # noqa: E402
from gen_atlas import S, LuaTable, ident, int_val, cmt, lua_str  # noqa: E402
from lupa import lua51  # noqa: E402

ANNIV = S.ADDONS
ERA = r"C:\World of Warcraft\_classic_era_\Interface\AddOns"
AL = ANNIV if os.path.isdir(os.path.join(ANNIV, "AtlasLootClassic_DungeonsAndRaids")) else ERA
QUESTIE = next((p for p in (os.path.join(ANNIV, "Questie", "Database", "TBC", "tbcItemDB.lua"),
                            os.path.join(ERA, "Questie", "Database", "TBC", "tbcItemDB.lua")) if os.path.exists(p)), None)

P_RAIDS = os.path.join(AL, "AtlasLootClassic_DungeonsAndRaids", "data.lua")
P_CRAFTING = os.path.join(AL, "AtlasLootClassic_Crafting", "data.lua")
P_FACTIONS = os.path.join(AL, "AtlasLootClassic_Factions", "data.lua")
P_PVP = os.path.join(AL, "AtlasLootClassic_PvP", "data.lua")
P_COLLECTIONS = os.path.join(AL, "AtlasLootClassic_Collections", "data.lua")
OUT_LUA_DEFAULT = os.path.join(A.ADDON_DIR, "Data", "AtlasClassic.lua")
P_TBC_ATLAS = os.path.join(A.ADDON_DIR, "Data", "Atlas.lua")
OUT_REPORT = os.path.join(HERE, "gen_atlas_classic_report.json")

FIRST_LINE = ('if DisasterZoneBoot and DisasterZoneBoot.Run("Data/AtlasClassic.lua", ...) then return end '
              '-- DisasterZone Atlas browser data, the Classic half (TBC Anniversary, Interface 20506)')

# --------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------
# (category key, display name, kind): kind is what Core/Atlas.lua / UI/Atlas.lua look at (raid / dungeon art and
# sizes, sets grouped by class); the key differs from the TBC half's so both trees share one index.
CATEGORIES = [("c_raids", "Raids", "raid"), ("c_dungeons", "Dungeons", "dungeon"), ("c_crafting", "Crafting", "crafting"),
              ("c_reputation", "Reputation", "reputation"), ("c_pvp", "PvP", "pvp"),
              ("c_events", "World Events", "events"), ("c_sets", "Sets", "sets")]

# Loading screens (the client's FileDataIDs; Interface\Glues\LoadingScreens\LoadScreen*.blp, 4:3). Read from the
# installed build with casc_local.py (names hashed where the listfile name is known, the rest identified by eye).
ART = {"MoltenCore": 131851, "BlackwingLair": 131827, "ZulGurub": 131886, "RuinsAQ": 131818, "TempleAQ": 131819,
       "BlackrockDepths": 131824, "BlackrockSpire": 131825, "DireMaul": 131835, "Scholomance": 131868,
       "Stratholme": 131871, "Deadmines": 131833, "Gnomeregan": 131841, "ScarletMonastery": 131866,
       "Uldaman": 131876, "ZulFarrak": 131885, "Maraudon": 131850, "SunkenTemple": 131872, "WailingCaverns": 131882,
       "ShadowfangKeep": 131869, "Stockade": 131870, "RazorfenKraul": 131865, "RazorfenDowns": 131864,
       "BlackfathomDeeps": 131823, "RagefireChasm": 131862, "Kalimdor": 131848, "EasternKingdoms": 131839,
       "WarsongGulch": 131883, "ArathiBasin": 131820, "AlteracValley": 131861, "Naxxramas": 131854}

# AtlasLoot key -> (source key, name, size, art)
RAIDS = OrderedDict([
    ("MoltenCore2", ("MoltenCore", "Molten Core", 40, "MoltenCore")),
    ("Onyxia2", ("Onyxia", "Onyxia's Lair", 40, "Kalimdor")),
    ("BlackwingLair", ("BlackwingLair", "Blackwing Lair", 40, "BlackwingLair")),
    ("Zul'Gurub", ("ZulGurub", "Zul'Gurub", 20, "ZulGurub")),
    ("TheRuinsofAhnQiraj", ("AQ20", "Ruins of Ahn'Qiraj", 20, "RuinsAQ")),
    ("TheTempleofAhnQiraj", ("AQ40", "Temple of Ahn'Qiraj", 40, "TempleAQ")),
    ("Naxxramas", ("Naxxramas", "Naxxramas", 40, "Naxxramas")),
    ("WorldBosses2", ("WorldBosses", "World Bosses", 40, "EasternKingdoms")),
])
DUNGEONS = OrderedDict([
    ("Ragefire", ("Ragefire", "Ragefire Chasm", "RagefireChasm")),
    ("WailingCaverns", ("WailingCaverns", "Wailing Caverns", "WailingCaverns")),
    ("TheDeadmines", ("Deadmines", "The Deadmines", "Deadmines")),
    ("ShadowfangKeep", ("ShadowfangKeep", "Shadowfang Keep", "ShadowfangKeep")),
    ("TheStockade", ("Stockade", "The Stockade", "Stockade")),
    ("BlackfathomDeeps2", ("BlackfathomDeeps", "Blackfathom Deeps", "BlackfathomDeeps")),
    ("Gnomeregan2", ("Gnomeregan", "Gnomeregan", "Gnomeregan")),
    ("RazorfenKraul", ("RazorfenKraul", "Razorfen Kraul", "RazorfenKraul")),
    ("ScarletMonasteryGraveyard", ("SMGraveyard", "SM: Graveyard", "ScarletMonastery")),
    ("ScarletMonasteryLibrary", ("SMLibrary", "SM: Library", "ScarletMonastery")),
    ("ScarletMonasteryArmory", ("SMArmory", "SM: Armory", "ScarletMonastery")),
    ("ScarletMonasteryCathedral", ("SMCathedral", "SM: Cathedral", "ScarletMonastery")),
    ("RazorfenDowns", ("RazorfenDowns", "Razorfen Downs", "RazorfenDowns")),
    ("Uldaman", ("Uldaman", "Uldaman", "Uldaman")),
    ("Zul'Farrak", ("ZulFarrak", "Zul'Farrak", "ZulFarrak")),
    ("Maraudon", ("Maraudon", "Maraudon", "Maraudon")),
    ("TheTempleOfAtal'Hakkar2", ("SunkenTemple", "Sunken Temple", "SunkenTemple")),
    ("BlackrockDepths", ("BlackrockDepths", "Blackrock Depths", "BlackrockDepths")),
    ("LowerBlackrockSpire", ("LBRS", "Lower Blackrock Spire", "BlackrockSpire")),
    ("UpperBlackrockSpire", ("UBRS", "Upper Blackrock Spire", "BlackrockSpire")),
    ("DireMaulEast", ("DireMaulEast", "Dire Maul East", "DireMaul")),
    ("DireMaulWest", ("DireMaulWest", "Dire Maul West", "DireMaul")),
    ("DireMaulNorth", ("DireMaulNorth", "Dire Maul North", "DireMaul")),
    ("Scholomance", ("Scholomance", "Scholomance", "Scholomance")),
    ("Stratholme", ("Stratholme", "Stratholme", "Stratholme")),
])
CRAFTING = OrderedDict((k, (k, n)) for k, n in [
    ("Alchemy", "Alchemy"), ("Blacksmithing", "Blacksmithing"), ("Enchanting", "Enchanting"),
    ("Engineering", "Engineering"), ("Tailoring", "Tailoring"), ("Leatherworking", "Leatherworking"),
    ("Mining", "Mining"), ("Herbalism", "Herbalism"), ("Cooking", "Cooking"), ("FirstAid", "First Aid"),
    ("Fishing", "Fishing"), ("RoguePoisons", "Rogue Poisons")])
FACTIONS = OrderedDict([
    ("ArgentDawn", ("ArgentDawn", "Argent Dawn")), ("Timbermaw", ("Timbermaw", "Timbermaw Hold")),
    ("ThoriumBrotherhood", ("ThoriumBrotherhood", "Thorium Brotherhood")),
    ("CenarionCircle", ("CenarionCircle", "Cenarion Circle")), ("ZandalarTribe", ("ZandalarTribe", "Zandalar Tribe")),
    ("BroodOfNozdormu", ("BroodOfNozdormu", "Brood of Nozdormu")),
    ("HydraxianWaterlords", ("HydraxianWaterlords", "Hydraxian Waterlords")),
    ("BloodsailBuccaneers", ("BloodsailBuccaneers", "Bloodsail Buccaneers")),
    ("WintersaberTrainers", ("WintersaberTrainers", "Wintersaber Trainers")),
])
PVP = OrderedDict([
    ("AlteracValley", ("AlteracValley", "Alterac Valley")), ("WarsongGulch", ("WarsongGulch", "Warsong Gulch")),
    ("ArathiBasin", ("ArathiBasin", "Arathi Basin")), ("Armor", ("Armor", "Rank armor")),
    ("Weapons", ("Weapons", "Rank weapons")), ("PvPMounts", ("Mounts", "PvP mounts")),
    ("Insignia", ("Insignia", "Insignia")),
])
PVP_ART = {"AlteracValley": "AlteracValley", "WarsongGulch": "WarsongGulch", "ArathiBasin": "ArathiBasin"}
EVENTS = OrderedDict([
    ("Darkmoon", ("Darkmoon", "Darkmoon Faire")), ("FishingExtravaganza", ("Fishing", "Fishing Extravaganza")),
    ("LunarFestival", ("LunarFestival", "Lunar Festival")), ("Noblegarden", ("Noblegarden", "Noblegarden")),
    ("HarvestFestival", ("HarvestFestival", "Harvest Festival")), ("WinterVeil", ("WinterVeil", "Feast of Winter Veil")),
])
# TierSets / ClassSets sub-table name (AtlasLoot's text; ZG / AQ read as "C_Map_GetAreaInfo(<area>)") -> (source key,
# display name), None = left out. Sources are listed in SET_ORDER.
SET_NAMES = [(r"^Dungeon Set 1", ("Tier0", "Tier 0")), (r"^Dungeon Set 2", ("Tier05", "Tier 0.5")),
             (r"^Tier 1 ", ("Tier1", "Tier 1")), (r"^Tier 2 ", ("Tier2", "Tier 2")),
             (r"^Tier 2\.5", ("Tier25", "Tier 2.5")), (r"^Tier 3", ("Tier3", "Tier 3")), (r"1977", ("ZulGurub", "Zul'Gurub")),
             (r"3428\D+20", ("AQ20", "Ruins of Ahn'Qiraj")), (r"3428\D+40", ("AQ40", "Temple of Ahn'Qiraj")),
             (r"^(Misc|Cloth|Leather|Mail|Plate)", ("World", "World & crafted"))]
SET_ORDER = ["Tier0", "Tier05", "Tier1", "Tier2", "Tier25", "Tier3", "ZulGurub", "AQ20", "AQ40", "World", "PvP"]
# Recommended levels where AtlasLoot gives Season of Discovery's (no GetForVersion): the original instances'
LV_FIX = {"BlackfathomDeeps": "24-32", "Gnomeregan": "29-38", "SunkenTemple": "45-55"}

# Craft spells from here on are Season of Discovery's (Classic / TBC crafts are far below)
SOD_SPELLS = 100000
# Pages of Season of Discovery bosses that also carry a normal list
SKIP_PAGES = {("WorldBosses", "PrinceThunderaan")}


# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------
def level_range(tbl):
    """AtlasLoot LevelRange (or GetForVersion(classic, bc): the TBC client's numbers) -> "13-18" (the recommended
    levels), None for level 60 content."""
    v = tbl.get("LevelRange")
    if isinstance(v, tuple) and v[0] == "call":
        args = [a for a in v[2] if isinstance(a, LuaTable)]
        v = args[1] if len(args) > 1 else (args[0] if args else None)
    if not isinstance(v, LuaTable) or len(v.array) < 3:
        return None
    lo, hi = int_val(v.array[1]), int_val(v.array[2])
    if not lo or not hi or lo >= 60:
        return None
    return f"{lo}-{hi}"


def instances(ctx, config, kind, PRICES):
    """Raids / dungeons through gen_atlas.build_item_tables (a source per instance, a page per boss) + size, levels
    and the loading screen."""
    plain = OrderedDict((k, v[:2]) for k, v in config.items())
    sources, _ = A.build_item_tables(ctx, P_RAIDS, plain, kind, PRICES, priced=False)
    tables, _, _ = A.parse_file(P_RAIDS)
    by_key = {v[0]: (k, v) for k, v in config.items()}
    out = []
    for src in sources:
        al_key, v = by_key[src["key"]]
        for pg in [pg for pg in src["pages"] if (src["key"], pg["key"]) in SKIP_PAGES]:
            ctx.skip("Season of Discovery page left out", f"{kind}/{src['key']}/{pg['key']}")
            src["pages"].remove(pg)
        src.pop("phase", None)
        tbl = tables[al_key]
        if kind == "raid":
            src["size"] = v[2]
            src["art"] = ART[v[3]]
        else:
            src["art"] = ART[v[2]]
            lv = LV_FIX.get(src["key"]) or level_range(tbl)
            if lv:
                src["lv"] = lv
        out.append(src)
    if kind == "dungeon":   # in level order: the list reads like a levelling road
        out.sort(key=lambda src: int(src.get("lv", "99-99").split("-")[0]))
    return out


_PARSE = A.parse_file


def tables_without(path, drop_rx=None, keep=None):
    """gen_atlas.parse_file, without Season of Discovery tables (by name) and CLASSIC-gated ones."""
    tables, comments, consts = _PARSE(path)
    out = OrderedDict()
    for k, t in tables.items():
        if keep is not None and k not in keep:
            continue
        gv = t.get("gameVersion")
        if gv is not None and "CLASSIC_VERSION_NUM" in repr(gv):
            continue
        if drop_rx and drop_rx.search(k):
            continue
        out[k] = t
    return out, comments, consts


def set_sources(ctx, SETS_DB):
    """Tier / raid sets from Collections' TierSets and the PvP rank sets: a source per sub-table, a page per set (as
    gen_atlas.build_sets: name = "<Class> (<Role>)", title = the set's name)."""
    out = []
    for path, al_key, fixed in ((P_COLLECTIONS, "TierSets", None), (P_PVP, "ClassSets", ("PvP", "PvP rank sets"))):
        tables, comments, consts = A.parse_file(path)
        tbl = tables.get(al_key)
        if tbl is None:
            ctx.report["notes"].append(f"sets: AtlasLoot table {al_key} not found")
            continue
        merged = OrderedDict()   # source key -> (name, [pages])
        for si, sub in enumerate(tbl.get("items").array):
            sub = A.resolve_sub(sub, consts)
            if not isinstance(sub, LuaTable):
                continue
            sname = A.clean_text(A.text(sub.get("name"), consts)) if sub.get("name") is not None else ""
            if fixed:
                key, name = fixed
            else:
                hit = next((v for rx, v in SET_NAMES if re.search(rx, sname)), "?")
                if hit is None:
                    ctx.skip("set sub-table left out (closed on a TBC realm)", f"sets/{al_key}/{sname}")
                    continue
                if hit == "?":
                    ctx.skip("set sub-table not in SET_NAMES", f"sets/{al_key}/{sname}")
                    continue
                key, name = hit
            entry = merged.setdefault(key, (name, [], set()))
            where = f"sets/{al_key}/{sname}"
            for dname, rows in A.ordered_diffs(A.diff_lists(sub, where, ctx)):
                side = A.SIDE_OF.get(dname)
                for pos, r in rows:
                    sid = int_val(r.array[1]) if len(r.array) > 1 else None
                    if sid is None or sid not in SETS_DB or not SETS_DB[sid][0]:
                        ctx.skip("set row without a known set id", f"{where} pos {pos}")
                        continue
                    ids, setname = SETS_DB[sid]
                    cl, role = A.set_class_label(A.row_comment(comments, r))
                    pname = f"{cl} ({role})" if role else (cl or f"Set {sid}")
                    page = OrderedDict(key=A.uniq_key(f"{sid}" + (A.SIDE_LETTER[side] if side else ""), entry[2]),
                                       name=pname, title=cmt(setname) or f"Set {sid}")
                    if side:
                        page["side"] = side
                    page["items"] = list(OrderedDict.fromkeys(ids))
                    entry[1].append(((cl or "~", role or "", {"Alliance": 1, "Horde": 2}.get(side, 0), len(entry[1])),
                                     page))
        for key, (name, found, _) in merged.items():
            pages = [pg for _, pg in sorted(found, key=lambda t: t[0])]
            if pages:
                out.append(A.finish_source(key, name, pages))
    out.sort(key=lambda src: SET_ORDER.index(src["key"]) if src["key"] in SET_ORDER else 99)
    return out


def tbc_names():
    """ids the TBC half (Data/Atlas.lua) already names, and its recipe keys."""
    names, recipes = set(), set()
    if not os.path.exists(P_TBC_ATLAS):
        return names, recipes
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    ns = lua.table()
    f = lua.eval("function(s) return loadstring(s) end")(open(P_TBC_ATLAS, encoding="utf-8").read())
    f("DisasterZone", ns)
    for k in ns.Data.AtlasNames.keys():
        names.add(int(k))
    for k in ns.Data.AtlasRecipes.keys():
        recipes.add(int(k))
    return names, recipes


# --------------------------------------------------------------------------------------
# Writer
# --------------------------------------------------------------------------------------
HEADER = """\
-- AUTO-GENERATED by gen_atlas_classic.py - do not edit by hand; re-run the generator instead.
-- Sources (all read locally; AtlasLootClassic data is GPL v2): the Classic tables AtlasLoot also shows on a TBC client
-- (AtlasLootClassic_DungeonsAndRaids / _Crafting / _Factions / _PvP / _Collections data.lua), AtlasLootClassic/Data
-- Profession.lua + Recipe.lua + ItemSet.lua, Questie's TBC item DB (names).
--
-- ns.Data.AtlasClassic: the Atlas tab's tree while its switch says Classic, shaped like ns.Data.Atlas, plus
--   category kind ("raid" / "dungeon" / "sets" / ...; the key is "c_" + the TBC half's so both share one index) and
--   source size (raid), lv ("13-18": a dungeon's recommended levels), art (its loading screen's FileDataID).
--   No Season of Discovery content.
-- ns.Data.AtlasClassicNames: English names the TBC half (ns.Data.AtlasNames) doesn't have.
-- Recipes the TBC half doesn't list are added to ns.Data.AtlasRecipes.
"""


def write_lua(path, tree, names, recipes):
    L = [FIRST_LINE, HEADER.rstrip("\n"), "local _, ns = ...", "ns.Data = ns.Data or {}", "", "ns.Data.AtlasClassic = {"]
    for cat in tree:
        L.append(f"  {{ key = {lua_str(cat['key'])}, name = {lua_str(cat['name'])}, kind = {lua_str(cat['kind'])}, "
                 "sources = {")
        for src in cat["sources"]:
            f = [f"key = {lua_str(src['key'])}", f"name = {lua_str(src['name'])}"]
            for k in ("size", "art"):
                if src.get(k):
                    f.append(f"{k} = {src[k]}")
            for k in ("lv", "side"):
                if src.get(k):
                    f.append(f"{k} = {lua_str(src[k])}")
            if src.get("factionID"):
                f.append(f"factionID = {src['factionID']}")
            L.append("    { " + ", ".join(f) + ", pages = {")
            for pg in src["pages"]:
                f = [f"key = {lua_str(pg['key'])}", f"name = {lua_str(pg['name'])}"]
                if pg.get("title"):
                    f.append(f"title = {lua_str(pg['title'])}")
                if pg.get("side"):
                    f.append(f"side = {lua_str(pg['side'])}")
                L.append("      { " + ", ".join(f) + ", items = {")
                for e in pg["items"]:
                    L.append(A.lua_item_line(e, names, "          "))
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
    L.append("ns.Data.AtlasClassicNames = {")
    for i in sorted(names):
        L.append(f"  [{i}] = {lua_str(names[i])},")
    L.append("}")
    L.append("")
    L.append("local recipes = ns.Data.AtlasRecipes or {}")
    L.append("ns.Data.AtlasRecipes = recipes")
    L.append("for r, v in pairs({")
    for r in sorted(recipes):
        L.append(f"  [{r}] = {recipes[r]},")
    L.append("}) do if recipes[r] == nil then recipes[r] = v end end")
    L.append("")
    data = "\n".join(L)
    with open(path, "wb") as fh:
        fh.write(data.encode("utf-8"))
    return len(data.encode("utf-8"))


def validate(path):
    src = open(path, "rb").read().decode("utf-8")
    assert src.split("\n", 1)[0] == FIRST_LINE
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    res = lua.eval("function(s) return loadstring(s, '@AtlasClassic.lua') end")(src)
    f, e = res if isinstance(res, tuple) else (res, None)
    if f is None:
        raise SystemExit(f"Lua 5.1 compile error: {e}")
    ns = lua.table()
    f("DisasterZone", ns)
    counts = Counter()
    errs = []
    C = ns.Data.AtlasClassic
    for ci in range(1, len(C) + 1):
        cat = C[ci]
        keys = set()
        for si in range(1, len(cat.sources) + 1):
            src = cat.sources[si]
            if not re.match(r"^[A-Za-z0-9_]+$", src.key) or src.key in keys:
                errs.append(f"{cat.key}/{src.key}: bad or duplicate key")
            keys.add(src.key)
            counts[cat.key + " sources"] += 1
            for pi in range(1, len(src.pages) + 1):
                pg = src.pages[pi]
                counts[cat.key + " items"] += len(pg["items"])
    return errs, counts


# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--out", default=OUT_LUA_DEFAULT)
    args = ap.parse_args()
    # the shared loaders read these module paths
    for name, path in (("P_PROFESSION", os.path.join(AL, "AtlasLootClassic", "Data", "Profession.lua")),
                       ("P_RECIPE", os.path.join(AL, "AtlasLootClassic", "Data", "Recipe.lua")),
                       ("P_ITEMSET", os.path.join(AL, "AtlasLootClassic", "Data", "ItemSet.lua")),
                       ("P_VENDORPRICE", os.path.join(AL, "AtlasLootClassic", "Data", "VendorPrice.lua")),
                       ("P_CRAFTING", P_CRAFTING), ("P_FACTIONS", P_FACTIONS)):
        setattr(S, name, path)
    if QUESTIE:
        S.P_QUESTIE_ITEMS = QUESTIE
    ctx = A.Ctx()
    rep = ctx.report
    rep["atlasloot"] = AL
    Q = S.load_questie_items() if QUESTIE else {}
    PROF, WRATH_ONLY, PROF_CMT = A.load_professions_tbc()
    _, REC_BY_ITEM = S.load_recipes()
    SETS_DB = A.load_item_sets_tbc()

    # crafting / reputation: gen_atlas's builders read S.P_CRAFTING / S.P_FACTIONS through A.parse_file; their tables
    # are narrowed to the configured (Classic, non-SoD) ones here
    real_parse = A.parse_file

    def narrowed(path):
        if path == P_CRAFTING:
            return tables_without(path, keep=CRAFTING)
        if path == P_FACTIONS:
            return tables_without(path, keep=FACTIONS)
        return real_parse(path)
    A.parse_file = narrowed
    real_diffs = A.diff_lists

    def no_sod(sub, where, ctx_):
        out = real_diffs(sub, where, ctx_)
        for name in [n for n in out if "SOD" in n]:
            ctx_.skip("Season of Discovery list left out", f"{where} [{name}]")
            del out[name]
        return out
    A.diff_lists = no_sod
    A.CRAFTING, A.FACTIONS = CRAFTING, FACTIONS
    S.FACTION_PHASE_RULES.clear()
    try:
        raids = instances(ctx, RAIDS, "raid", {})
        dungeons = instances(ctx, DUNGEONS, "dungeon", {})
        crafting = A.build_crafting(ctx, PROF, WRATH_ONLY)
        reputation = A.build_reputation(ctx)
        pvp, _ = A.build_item_tables(ctx, P_PVP, PVP, "pvp", {}, priced=False)
        events, _ = A.build_item_tables(ctx, P_COLLECTIONS, EVENTS, "events", {}, priced=False)
        sets = set_sources(ctx, SETS_DB)
    finally:
        A.parse_file = real_parse
        A.diff_lists = real_diffs
    for src in pvp:
        src.pop("phase", None)
        if src["key"] in PVP_ART:
            src["art"] = ART[PVP_ART[src["key"]]]
    for lst in (crafting, reputation, events):
        for src in lst:
            src.pop("phase", None)
            for pg in src["pages"]:
                pg.pop("phase", None)
    by_kind = {"raid": raids, "dungeon": dungeons, "crafting": crafting, "reputation": reputation, "pvp": pvp,
               "events": events, "sets": sets}
    tree = [OrderedDict(key=k, name=n, kind=kind, sources=by_kind[kind]) for k, n, kind in CATEGORIES if by_kind[kind]]

    # ---- names: only what the TBC half doesn't have
    have, have_recipes = tbc_names()
    ids = OrderedDict()
    for cat in tree:
        for src in cat["sources"]:
            for pg in src["pages"]:
                for e in pg["items"]:
                    if isinstance(e, int):
                        ids.setdefault(e, f"{cat['key']}/{src['key']}/{pg['key']}")
    names, unnamed, name_src = {}, [], Counter()
    for i, where in ids.items():
        # only what a TBC client has: an item in Questie's TBC item DB (AtlasLoot's Classic tables carry Season of
        # Discovery ids among the normal rows, named by their row comments), a craft spell from before SoD's ids
        if i < 0:
            nm = ctx.spell_names.get(-i) if -i < SOD_SPELLS else None
            how = "crafting row comment"
        else:
            nm = (Q.get(i) or {}).get("name")
            how = "Questie TBC item DB"
        if nm:
            names[i] = nm
            if i not in have:
                name_src[how] += 1
        else:
            unnamed.append({"id": i, "where": where})
    # an id the TBC client doesn't have (Season of Discovery rows): out of the tree
    bad = {u["id"] for u in unnamed}
    for cat in tree:
        for src in cat["sources"]:
            for pg in src["pages"]:
                if any(isinstance(e, int) and e in bad for e in pg["items"]):
                    old = pg["items"]
                    pg["items"] = [e for e in old if not (isinstance(e, int) and e in bad)]
                    if pg.get("x"):
                        nx, j = OrderedDict(), 0
                        for k, e in enumerate(old, 1):
                            if isinstance(e, int) and e in bad:
                                continue
                            j += 1
                            if k in pg["x"]:
                                nx[j] = pg["x"][k]
                        pg["x"] = nx
            src["pages"] = [pg for pg in src["pages"] if pg["items"]]
        cat["sources"] = [s for s in cat["sources"] if s["pages"]]
    tree = [c for c in tree if c["sources"]]
    # recipes in the Classic tree
    scope = set(i for i in names if i > 0)
    recipes = A.build_recipes(scope, REC_BY_ITEM, PROF, WRATH_ONLY, Q, ctx)
    recipes = OrderedDict((r, v) for r, v in recipes.items() if r not in have_recipes)
    for r, v in recipes.items():
        if v not in names and v > 0 and (Q.get(v) or {}).get("name"):
            names[v] = Q[v]["name"]
    write_names = {i: n for i, n in names.items() if i not in have}
    size = write_lua(args.out, tree, write_names, recipes)
    errs, counts = validate(args.out)

    rep["output"] = args.out
    rep["bytes"] = size
    rep["validation_errors"] = errs
    rep["counts"] = dict(counts)
    rep["names_written"] = len(write_names)
    rep["name_sources"] = dict(name_src)
    rep["ids_without_names_dropped"] = unnamed
    rep["recipes_added"] = len(recipes)
    rep["skipped_counts"] = {k: len(v) for k, v in sorted(ctx.skipped.items())}
    rep["skipped"] = {k: v[:40] for k, v in sorted(ctx.skipped.items())}
    with open(OUT_REPORT, "w", encoding="utf-8") as fh:
        json.dump(rep, fh, indent=1)
    print(f"wrote {args.out} ({size} bytes); {dict(counts)}")
    print(f"names written {len(write_names)}, dropped unnamed {len(unnamed)}, recipes added {len(recipes)}")
    if errs:
        print("VALIDATION ERRORS:", errs[:20])
        sys.exit(1)


if __name__ == "__main__":
    main()
