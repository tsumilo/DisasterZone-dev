"""Generates DisasterZone Data/ItemClasses.lua: ns.Data.ItemClasses = { [itemID] = { "ROGUE", ... } } for every item in
DisasterZone's data (raid / 5-man drops, token pieces, arena exchanges, Sunmote upgrades, crafted / reputation / badge /
PvP items) that only some classes can use ("Classes: ..." on the tooltip). Tier pieces (TierPieceClass) and tokens
(TokenClasses) are left out: DisasterZone already knows their classes.

Source: AtlasLootClassic/Data/Requirements.lua (GPL v2), CLASSIC + BCC tables (class bit masks), cross-checked
against the Wowhead TBC tooltips cached in review/data (tt_cache*.json, wowhead_cache.json).
Run: python fixer/gen_itemclasses.py [--write]"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(SCRATCH, "review", "data"))
from common import load_data, lua_list  # noqa: E402

ADDON = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
REQ = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\AtlasLootClassic\Data\Requirements.lua"
DATA = os.path.join(SCRATCH, "review", "data")

BITS = [("WARRIOR", 1), ("PALADIN", 2), ("HUNTER", 4), ("ROGUE", 8), ("PRIEST", 16), ("SHAMAN", 64),
        ("MAGE", 128), ("WARLOCK", 256), ("DRUID", 1024)]
TBC = sum(b for _, b in BITS)
NAME = {"Warrior": "WARRIOR", "Paladin": "PALADIN", "Hunter": "HUNTER", "Rogue": "ROGUE", "Priest": "PRIEST",
        "Shaman": "SHAMAN", "Mage": "MAGE", "Warlock": "WARLOCK", "Druid": "DRUID"}

# --- DisasterZone item ids --------------------------------------------------------------------------------------------
L, ns = load_data()
D = ns.Data
ids = {}


def tag(i, t):
    ids.setdefault(int(i), set()).add(t)


for raid in lua_list(D["Raids"]):
    for boss in lua_list(raid["bosses"]):
        for i in lua_list(boss["items"]):
            tag(i, "raid")
for dg in lua_list(D.Dungeons):
    for boss in lua_list(dg["bosses"]):
        for i in lua_list(boss["items"]) + lua_list(boss["heroicItems"]):
            tag(i, "dungeon")
for tok, pieces in D.Tokens.items():
    for p in lua_list(pieces):
        tag(p, "piece")
for tok, info in D.TokenArenaExchanges.items():
    for p in lua_list(info["items"]):
        tag(p, "arena")
for b, u in D.Upgrades.items():
    tag(u, "upgrade")
for kind in ("Crafted", "Reputation", "Badges", "PvP"):
    for g in lua_list(D[kind]):
        for it in lua_list(g["items"]):
            tag(it.id, kind.lower())
skip = {int(k) for k in D.TierPieceClass.keys()} | {int(k) for k in D.Tokens.keys()} \
    | {int(k) for k in D.TokenClasses.keys()}

# --- AtlasLoot requirement masks (CLASSIC, then BCC overrides) -----------------------------------------------------
with open(REQ, encoding="utf-8") as f:
    src = f.read()
masks = {}
start = src.index("ReqData_RAW.CLASSIC = {")
bcc = src.index("ReqData_RAW.BCC = {")
wrath = src.index("ReqData_RAW.WRATH = {")
ENTRY = re.compile(r"\[(\d+)\]\s*=\s*\{\s*(\d+)")
for m in ENTRY.finditer(src, start, bcc):
    masks[int(m.group(1))] = int(m.group(2))
for m in ENTRY.finditer(src, bcc, wrath):
    masks[int(m.group(1))] = int(m.group(2))

# --- Wowhead tooltip cache (cross-check / gap filler) --------------------------------------------------------------
tt = {}
for fn in ("wowhead_cache.json", "tt_cache.json", "tt_cache2.json", "tt_cache3.json", "tt_cache4.json", "tt_extra.json"):
    p = os.path.join(DATA, fn)
    if os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            for k, v in json.load(f).items():
                if isinstance(v, dict):
                    tt.setdefault(int(k), {}).update({kk: vv for kk, vv in v.items() if vv is not None})


def tt_classes(i):
    d = tt.get(i)
    if not d:
        return None
    if d.get("classes"):
        return sorted(NAME[c] for c in d["classes"] if c in NAME)
    rc = (d.get("json") or {}).get("reqclass")
    if rc and (rc & TBC) != TBC:
        return sorted(c for c, b in BITS if rc & b)
    return []   # known, unrestricted


def al_classes(i):
    m = masks.get(i)
    if m is None:
        return None
    m &= TBC
    if m == 0 or m == TBC:
        return []
    return sorted(c for c, b in BITS if m & b)


out, disagree = {}, []
for i in sorted(ids):
    if i in skip:
        continue
    a, t = al_classes(i), tt_classes(i)
    if a and t is not None and t != a and t:
        disagree.append((i, "atlas", a, "wowhead", t))
    if a is None and not t:
        continue
    if a and t == [] and "classes" in (tt.get(i) or {}):
        disagree.append((i, "atlas", a, "wowhead", "none"))
    cls = t if t else a     # the tooltip wins where both know the item
    if cls:
        out[i] = cls

print("items:", len(ids), "restricted:", len(out), "disagreements:", len(disagree))
for d in disagree[:40]:
    print("   ", d)
from collections import Counter
print(Counter(sorted(ids[i])[0] for i in out))

lines = [
    "-- DisasterZone class-restricted items (TBC Anniversary, Interface 20506): the classes that may equip them.",
    "-- AUTO-GENERATED by gen_itemclasses.py - do not edit by hand; re-run the generator instead.",
    "-- Source: AtlasLootClassic/Data/Requirements.lua (GPL v2, class bit masks of the CLASSIC and BCC tables),",
    "-- cross-checked with Wowhead TBC tooltips (\"Classes: ...\"). Tier pieces (TierPieceClass) and tokens",
    "-- (TokenClasses) are not listed: Data/Items.lua already carries their classes.",
    "local addonName, ns = ...",
    "ns.Data = ns.Data or {}",
    "",
    "ns.Data.ItemClasses = {",
]
for i in sorted(out):
    lines.append('  [%d] = { %s },' % (i, ", ".join('"%s"' % c for c in out[i])))
lines.append("}")
text = "\n".join(lines) + "\n"
if "--write" in sys.argv:
    with open(os.path.join(ADDON, "Data", "ItemClasses.lua"), "w", encoding="ascii", newline="\n") as f:
        f.write(text)
    print("wrote Data/ItemClasses.lua (%d bytes)" % len(text))
