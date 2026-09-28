#!/usr/bin/env python
"""Generate the mock item database for the WoW mock client.

Outputs:
  tools/wowmock/items.lua            return { [id] = {name, quality, equipLoc, classID, subclassID, icon,
                                                       itemLevel, minLevel, bindType, stackCount}, ... }
                                     for every item referenced by CDLoot/Data/Items.lua (boss loot, tier tokens,
                                     tier pieces, Sunmote upgrades, arena exchanges)
  tools/wowmock/items_fallback.json  {id: [name, quality, equipLoc, classID, subclassID, icon, itemLevel, minLevel]}
                                     for every other TBC item in Questie's DB (lazy fallback for tests that use
                                     arbitrary item IDs)
  tools/wowmock/items_report.json    coverage statistics

Data sources (all read locally from installed addons):
  * names:            `-- Name` comments in CDLoot/Data/Items.lua, else Questie
  * classID/subclassID/itemLevel/requiredLevel:
                      Questie/Database/TBC/tbcItemDB.lua (QuestieDB.itemKeys: 9=itemLevel 10=requiredLevel
                      12=class 13=subClass)
  * equip slot:       LoonBestInSlot/Guides/*.lua  (LBIS:AddItem(spec, "id", LBIS.L["<Slot>"], ...))
                      AtlasLootClassic_TBC_Phase_*/*DB.lua  ({ name = format(AL["<Slot>"], ..), {n, id}, ... })
                      combined with class/subclass (weapon & relic & shield types are exact from subclass);
                      name-keyword heuristics only when no slot label exists.
  * quality:          heuristic (no local source): raid loot = epic(4); see quality_for().
  * icon:             no local source; deterministic fake fileID 130000 + id % 10000.
Run:  luaenv\\Scripts\\python.exe tools\\gen_items.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import luabc  # noqa: E402  (sets up lupa import path)
from lupa import lua51  # noqa: E402

ADDONS = r"C:\World of Warcraft\_anniversary_\Interface\AddOns"
CDLOOT_ITEMS = os.path.join(ADDONS, "CDLoot", "Data", "Items.lua")
QUESTIE_TBC = os.path.join(ADDONS, "Questie", "Database", "TBC", "tbcItemDB.lua")
OUT_DIR = os.path.join(HERE, "wowmock")

WEAPON_2H = {1, 5, 6, 8, 10, 20}
WEAPON_1H = {0, 4, 7, 13, 15, 9}
LABEL_MAP = {
    "Head": "INVTYPE_HEAD", "Neck": "INVTYPE_NECK", "Shoulder": "INVTYPE_SHOULDER", "Shoulders": "INVTYPE_SHOULDER",
    "Back": "INVTYPE_CLOAK", "Chest": "INVTYPE_CHEST", "Wrist": "INVTYPE_WRIST", "Hands": "INVTYPE_HAND",
    "Waist": "INVTYPE_WAIST", "Legs": "INVTYPE_LEGS", "Feet": "INVTYPE_FEET", "Ring": "INVTYPE_FINGER",
    "Rings": "INVTYPE_FINGER", "Trinket": "INVTYPE_TRINKET", "Trinkets": "INVTYPE_TRINKET",
}
NAME_RULES = [  # (regex on name, case-insensitive, equipLoc) - last resort, first match wins
    (r"\brobes?\b", "INVTYPE_ROBE"),
    (r"shoulder|pauldron|mantle|spaulder|epaulet|\bamice\b", "INVTYPE_SHOULDER"),
    (r"helm|crown|cowl|\bhood\b|diadem|faceguard|headdress|headguard|\bmask\b|circlet|\bcap\b|\bcoif\b|antlers|"
     r"headpiece|visor|\bhat\b|cover of|guise|collar of the aldor", "INVTYPE_HEAD"),
    (r"chestguard|chestpiece|breastplate|tunic|\bvest\b|hauberk|harness|raiment|vestments|chestplate|jerkin|"
     r"garments|\barmor\b|chain links|battlegear|cuirass", "INVTYPE_CHEST"),
    (r"bracers|\bbands\b|cuffs|wristguards|vambraces|bindings|wrist|armguards|bracelets", "INVTYPE_WRIST"),
    (r"gloves|gauntlets|handguards|handwraps|\bgrips\b|\bmitts\b|handgrips|\bgrasp\b|\bhands\b", "INVTYPE_HAND"),
    (r"\bbelt\b|girdle|\bcord\b|\bsash\b|waistband|waistguard|cinch", "INVTYPE_WAIST"),
    (r"leggings|legplates|legguards|\bpants\b|trousers|breeches|kilt|pantaloons|britches|legwraps|leg", "INVTYPE_LEGS"),
    (r"boots|sabatons|treads|footwraps|foot-wraps|greaves|stompers|slippers|sandals|footpads|walkers|kickers|"
     r"striders|footguards", "INVTYPE_FEET"),
    (r"cloak|\bcape\b|shawl|\bdrape\b|shroud", "INVTYPE_CLOAK"),
    (r"necklace|choker|pendant|amulet|medallion|locket|\bchain\b|brooch|pendant|\bcollar\b", "INVTYPE_NECK"),
    (r"\bring\b|\bband\b|signet|\bloop\b|\bseal\b", "INVTYPE_FINGER"),
]
MELEE_SPECS = {"DruidBear", "DruidCat", "HunterBeastMastery", "HunterMarksmanship", "HunterSurvival",
               "PaladinRetribution", "RogueDps", "ShamanEnhancement", "WarriorArms", "WarriorFury",
               "WarriorProtection"}


def parse_items_lua():
    """Return (ordered id list, {id: name}) from CDLoot's Items.lua (executed in Lua + comment names)."""
    text = open(CDLOOT_ITEMS, encoding="utf-8").read()
    names = {}
    for m in re.finditer(r"(?m)^\s*(\d+),\s*--\s*(.+?)\s*$", text):
        nm = re.sub(r"^[A-Z]+:\s*", "", m.group(2))
        names.setdefault(int(m.group(1)), nm)
    for m in re.finditer(r"(?m)^\s*\[(\d+)\]\s*=\s*\{\s*(?:patch\s*=\s*\"[^\"]*\",\s*items\s*=\s*\{\s*)?--\s*(.+?)\s*$", text):
        names.setdefault(int(m.group(1)), m.group(2))
    for m in re.finditer(r"(?m)^\s*\[(\d+)\]\s*=\s*(\d+),\s*--\s*(.+?)\s*->\s*(.+?)\s*$", text):
        names.setdefault(int(m.group(1)), m.group(3))
        names.setdefault(int(m.group(2)), m.group(4))
    rt = lua51.LuaRuntime(unpack_returned_tuples=True, register_eval=False, register_builtins=False)
    collect = rt.execute("""
        local src = ...
        local ns = {}
        local f = assert(loadstring(src, "@Data/Items.lua"))
        f("CDLoot", ns)
        local ids, seen = {}, {}
        local function add(id) if type(id) == "number" and not seen[id] then seen[id] = true; ids[#ids+1] = id end end
        local D = ns.Data
        for _, raid in ipairs(D.Raids or {}) do
          for _, boss in ipairs(raid.bosses or {}) do for _, id in ipairs(boss.items or {}) do add(id) end end
        end
        for tok, pieces in pairs(D.Tokens or {}) do add(tok); for _, id in ipairs(pieces) do add(id) end end
        for a, b in pairs(D.Upgrades or {}) do add(a); add(b) end
        for tok, e in pairs(D.TokenArenaExchanges or {}) do add(tok); for _, id in ipairs(e.items or {}) do add(id) end end
        for id in pairs(D.TierPieceClass or {}) do add(id) end
        for id in pairs(D.TokenClasses or {}) do add(id) end
        table.sort(ids)
        return ids
    """, text)
    ids = [int(collect[i]) for i in range(1, len(collect) + 1)]
    return ids, names


def load_questie():
    text = open(QUESTIE_TBC, encoding="utf-8", errors="replace").read()
    i = text.index("QuestieDB.itemData = [[") + len("QuestieDB.itemData = [[")
    j = text.index("]]", i)
    rt = lua51.LuaRuntime(unpack_returned_tuples=True, register_eval=False, register_builtins=False)
    conv = rt.execute("""
        local src = ...
        local t = assert(loadstring(src))()
        local out = {}
        for id, r in pairs(t) do
          out[#out+1] = {id, r[1] or "", r[9] or 0, r[10] or 0, r[12] or -1, r[13] or -1}
        end
        return out
    """, text[i:j])
    db = {}
    for k in range(1, len(conv) + 1):
        r = conv[k]
        db[int(r[1])] = {"name": r[2], "ilvl": int(r[3]), "req": int(r[4]), "cls": int(r[5]), "sub": int(r[6])}
    return db


def load_slot_labels():
    labels = {}  # id -> {label: count}

    def add(i, lab):
        d = labels.setdefault(int(i), {})
        d[lab] = d.get(lab, 0) + 1

    gdir = os.path.join(ADDONS, "LoonBestInSlot", "Guides")
    if os.path.isdir(gdir):
        for fn in os.listdir(gdir):
            if fn.endswith(".lua"):
                t = open(os.path.join(gdir, fn), encoding="utf-8", errors="replace").read()
                spec = fn[:-4]
                for m in re.finditer(r'AddItem\(\s*\w+\s*,\s*"(\d+)"\s*,\s*LBIS\.L\["([^"]+)"\]', t):
                    add(m.group(1), "lbis:" + m.group(2))
                    if m.group(2) == "Main Hand":
                        add(m.group(1), "spec:" + spec)
    for d in os.listdir(ADDONS):
        if d.startswith("AtlasLootClassic_TBC_Phase_"):
            for fn in os.listdir(os.path.join(ADDONS, d)):
                if fn.endswith("DB.lua"):
                    t = open(os.path.join(ADDONS, d, fn), encoding="utf-8", errors="replace").read()
                    for line in t.splitlines():
                        m = re.search(r'name\s*=\s*(?:format\()?AL\["([^"]+)"\]', line)
                        if not m:
                            continue
                        for im in re.finditer(r"\{\s*\d+\s*,\s*(\d+)\s*[,}]", line):
                            add(im.group(1), "al:" + m.group(1))
    return labels


OVERRIDES = {  # hand-verified exceptions to the heuristics
    32837: "INVTYPE_WEAPONMAINHAND",  # Warglaive of Azzinoth (main hand)
    32838: "INVTYPE_WEAPONOFFHAND",   # Warglaive of Azzinoth (off hand)
}


def equip_loc_for(item_id, name, cls, sub, labs):
    """Return (equipLoc, source) where source in exact|label|heuristic|none."""
    if item_id in OVERRIDES:
        return OVERRIDES[item_id], "exact"
    labset = {l.split(":", 1)[1] for l in (labs or {}) if not l.startswith("spec:")}
    if cls in (0, 1, 3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16):
        return "INVTYPE_NON_EQUIP_IGNORE", "exact"
    if cls == 2:
        if sub in WEAPON_2H:
            return "INVTYPE_2HWEAPON", "exact"
        if sub == 2:
            return "INVTYPE_RANGED", "exact"
        if sub in (3, 18, 19):
            return "INVTYPE_RANGEDRIGHT", "exact"
        if sub == 16:
            return "INVTYPE_THROWN", "exact"
        if sub in WEAPON_1H:
            # One-hand vs main-hand-only cannot be read from any local source. Heuristic: listed as an
            # off-hand anywhere or as "Onehand" -> INVTYPE_WEAPON; main-hand only and only by caster/healer
            # specs -> INVTYPE_WEAPONMAINHAND; main-hand by any melee spec -> INVTYPE_WEAPON.
            mh = bool(labset & {"Main Hand"})
            oh = bool(labset & {"Off Hand", "Offhand"})
            one = "Onehand" in labset
            specs = {l.split(":", 1)[1] for l in (labs or {}) if l.startswith("spec:")}
            if one or oh:
                return "INVTYPE_WEAPON", "heuristic"
            if mh and specs and not (specs & MELEE_SPECS):
                return "INVTYPE_WEAPONMAINHAND", "heuristic"
            return "INVTYPE_WEAPON", "heuristic"
        return "INVTYPE_WEAPON", "heuristic"
    if cls == 4:
        if sub == 6:
            return "INVTYPE_SHIELD", "exact"
        if sub in (7, 8, 9, 10, 11):
            return "INVTYPE_RELIC", "exact"
        mapped = [LABEL_MAP[l] for l in labset if l in LABEL_MAP]
        if sub == 0 and not mapped and labset & {"Off Hand", "Offhand"}:
            return "INVTYPE_HOLDABLE", "label"
        if mapped:
            # most frequent mapped label
            cnt = {}
            for l, c in (labs or {}).items():
                lab = l.split(":", 1)[1]
                if lab in LABEL_MAP:
                    cnt[LABEL_MAP[lab]] = cnt.get(LABEL_MAP[lab], 0) + c
            loc = max(cnt.items(), key=lambda kv: kv[1])[0]
            if loc == "INVTYPE_CHEST" and re.search(r"\bRobes?\b", name, re.I):
                loc = "INVTYPE_ROBE"
            return loc, "label"
        for rx, loc in NAME_RULES:
            if re.search(rx, name, re.I):
                if sub == 0 and loc not in ("INVTYPE_NECK", "INVTYPE_FINGER", "INVTYPE_TRINKET", "INVTYPE_HOLDABLE"):
                    continue
                if sub in (1, 2, 3, 4) and loc in ("INVTYPE_NECK", "INVTYPE_FINGER"):
                    continue
                return loc, "heuristic"
        if sub == 0:
            return "INVTYPE_TRINKET", "heuristic"
        return "INVTYPE_CHEST", "heuristic"
    return "INVTYPE_NON_EQUIP_IGNORE", "none"


def quality_for(cls, ilvl, raid_item):
    if raid_item:
        if cls in (2, 4) and ilvl and ilvl < 100:
            return 3
        return 4
    if cls in (2, 4):
        if ilvl >= 120:
            return 4
        if ilvl >= 90:
            return 3
        return 2
    return 1


def stack_for(cls):
    return 20 if cls in (3, 5, 7) else 1


def lua_str(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"' or ch == "\\":
            out.append("\\" + ch)
        elif o < 32:
            out.append("\\%d" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def main():
    ids, names = parse_items_lua()
    questie = load_questie()
    labels = load_slot_labels()
    stats = {"items": len(ids), "name_from_cdloot": 0, "name_from_questie": 0, "name_missing": 0,
             "class_from_questie": 0, "class_guessed": 0, "equip": {"exact": 0, "label": 0, "heuristic": 0, "none": 0},
             "heuristic_items": []}
    lines = ["-- AUTO-GENERATED by tools/gen_items.py - do not edit. See that file for data sources.",
             "-- [id] = {name, quality, equipLoc, classID, subclassID, icon, itemLevel, minLevel, bindType, stackCount}",
             "return {"]
    for i in ids:
        q = questie.get(i)
        nm = names.get(i)
        if nm:
            stats["name_from_cdloot"] += 1
        elif q and q["name"]:
            nm = q["name"]
            stats["name_from_questie"] += 1
        else:
            nm = "Item %d" % i
            stats["name_missing"] += 1
        if q and q["cls"] >= 0:
            cls, sub, ilvl, req = q["cls"], q["sub"], q["ilvl"], q["req"]
            stats["class_from_questie"] += 1
        else:
            stats["class_guessed"] += 1
            if re.search(r"of the (Fallen|Forgotten|Vanquished)", nm):
                cls, sub = 15, 0
            else:
                cls, sub = 4, 0
            ilvl, req = 0, 70
        loc, src = equip_loc_for(i, nm, cls, sub, labels.get(i))
        stats["equip"][src] += 1
        if src == "heuristic":
            stats["heuristic_items"].append("%d %s -> %s" % (i, nm, loc))
        quality = quality_for(cls, ilvl, True)
        icon = 130000 + i % 10000
        lines.append("  [%d] = {%s, %d, %s, %d, %d, %d, %d, %d, %d, %d}," % (
            i, lua_str(nm), quality, lua_str(loc), cls, sub, icon, ilvl, req, 1, stack_for(cls)))
    lines.append("}")
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "items.lua"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

    idset = set(ids)
    fb = {}
    for i, q in questie.items():
        if i in idset:
            continue
        loc, _ = equip_loc_for(i, q["name"], q["cls"], q["sub"], labels.get(i))
        fb[str(i)] = [q["name"], quality_for(q["cls"], q["ilvl"], False), loc, q["cls"], q["sub"],
                      130000 + i % 10000, q["ilvl"], q["req"]]
    with open(os.path.join(OUT_DIR, "items_fallback.json"), "w", encoding="utf-8") as fh:
        json.dump(fb, fh, separators=(",", ":"))

    eq = stats["equip"]
    total = len(ids)
    stats["coverage_pct"] = {
        "name_real": round(100.0 * (stats["name_from_cdloot"] + stats["name_from_questie"]) / total, 1),
        "class_subclass_real": round(100.0 * stats["class_from_questie"] / total, 1),
        "equipLoc_exact_or_label": round(100.0 * (eq["exact"] + eq["label"]) / total, 1),
        "equipLoc_heuristic": round(100.0 * eq["heuristic"] / total, 1),
    }
    stats["fallback_items"] = len(fb)
    with open(os.path.join(OUT_DIR, "items_report.json"), "w", encoding="utf-8") as fh:
        json.dump(stats, fh, indent=1)
    print("items.lua: %d items; names real %.1f%%, class/subclass real %.1f%%, equipLoc exact/label %.1f%%, "
          "heuristic %.1f%% (%d); fallback db %d items" % (
              total, stats["coverage_pct"]["name_real"], stats["coverage_pct"]["class_subclass_real"],
              stats["coverage_pct"]["equipLoc_exact_or_label"], stats["coverage_pct"]["equipLoc_heuristic"],
              eq["heuristic"], len(fb)))


if __name__ == "__main__":
    main()
