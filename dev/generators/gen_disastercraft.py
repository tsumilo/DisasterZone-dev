"""Disastercraft's game data: classes, spells, items, loot, creatures, vendors, trainers and quest rewards for the
built regions of the real map, written to addon/DisasterZone/Games/Disastercraft/Data.lua.

Sources (offline):
  - cMaNGOS TBC world database (dev/art/tbcdb, see dc_db.py / tbcdb.py): player stats per level, start spells and
    action bars, trainers, creature stats and EventAI, loot, items, vendors, quests, gossip, graveyards.
  - WoW 2.5.6 client tables from wago.tools (dev/art/dc_db2, git-ignored): Spell* (names, effects, costs, cast
    times, ranges, durations, cooldowns, icons), CharStartOutfit (start gear), Item (icons).
  - The generated world (Games/Azeromon/World/<Region>.lua, Quests.lua): which creatures, NPCs and quests exist.

    luaenv/Scripts/python.exe generators/gen_disastercraft.py
"""
import csv
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dc_db  # noqa: E402
import tbcdb  # noqa: E402

DEV = os.path.dirname(HERE)
ADDON = os.path.join(DEV, "..", "addon", "DisasterZone")
WORLD = os.path.join(ADDON, "Games", "Azeromon", "World")
OUT = os.path.join(ADDON, "Games", "Disastercraft", "Data.lua")
D2 = os.path.join(DEV, "art", "dc_db2")
WAGO = "https://wago.tools/db2/%s/csv?build=2.5.6.69795"
REGIONS = ["Northshire"]

RACE = 1                                   # Human (the races of the built zones)
CLASSES = {1: "WARRIOR", 5: "PRIEST", 8: "MAGE"}
MAX_LEVEL = 10
# the trainers' spell lists: the start zone's own (Northshire) and the next town's (to level 10)
TRAINER_TEMPLATES = {1: (10, 11), 5: (50, 51), 8: (70, 71)}
# start spells that do something in the game (the rest are skills / languages / passives of the server)
START_KEEP = {6603, 78, 2457, 133, 168, 585, 2050, 5019, 81, 3127}
EXTRA_ITEMS = {5349, 5350, 2287}           # conjured muffin / water (the spells create them)
TS = 533.3333 / 128


def lua_str(s):
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "").replace("\n", "\\n")
    return '"' + s + '"'


def lua(v, depth=0):
    if v is None:
        return "nil"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, (int,)):
        return str(v)
    if isinstance(v, float):
        if v == int(v):
            return str(int(v))
        return ("%.4f" % v).rstrip("0").rstrip(".")
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(lua(x, depth + 1) for x in v) + " }"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            if x is None:
                continue
            if isinstance(k, int):
                parts.append("[%d] = %s" % (k, lua(x, depth + 1)))
            elif re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
                parts.append("%s = %s" % (k, lua(x, depth + 1)))
            else:
                parts.append("[%s] = %s" % (lua_str(k), lua(x, depth + 1)))
        return "{ " + ", ".join(parts) + " }"
    raise TypeError(type(v))


_ZONES = {}


def zone_names():
    """AreaTable: area ID -> name (a quest's ZoneOrSort: the quest log's header)."""
    if not _ZONES:
        path = os.path.join(HERE, "..", "art", "tbcdb", "db2", "AreaTable.csv")
        for r in csv.DictReader(open(path, encoding="utf-8")):
            _ZONES[int(r["ID"])] = r["AreaName_lang"]
    return _ZONES


def table(name):
    path = os.path.join(D2, name + ".csv")
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        import gen_rooms as R
        R._get(WAGO % name, path)
    return list(csv.DictReader(open(path, encoding="utf-8")))


def num(s, cast=int):
    try:
        return cast(s)
    except (TypeError, ValueError):
        try:
            return cast(float(s))
        except (TypeError, ValueError):
            return 0


# ---------------------------------------------------------------------------------------------------------------
# What exists in the built world
# ---------------------------------------------------------------------------------------------------------------

def world_entities():
    ents = {"mob": set(), "npc": set(), "critter": set(), "obj": set()}
    for region in REGIONS:
        text = open(os.path.join(WORLD, region + ".lua"), encoding="utf-8").read()
        for m in re.finditer(r'W\.Add\(\{([^\n]*)\}\)', text):
            body = m.group(1)
            k = re.search(r'k = "(\w+)"', body)
            e = re.search(r'\be = (\d+)', body)
            if k and e and k.group(1) in ents:
                ents[k.group(1)].add(int(e.group(1)))
    quests = set()
    qtext = open(os.path.join(WORLD, "Quests.lua"), encoding="utf-8").read()
    for m in re.finditer(r'^Q\[(\d+)\] = ', qtext, re.M):
        quests.add(int(m.group(1)))
    return ents, quests


# ---------------------------------------------------------------------------------------------------------------
# Spells
# ---------------------------------------------------------------------------------------------------------------

LINE_ICONS = {}                             # class skill line name -> its icon (the spellbook's side tabs)


class Spells:
    def __init__(self):
        self.name = {int(r["ID"]): r["Name_lang"] for r in table("SpellName")}
        self.spell = {int(r["ID"]): r for r in table("Spell")}
        self.misc = {int(r["SpellID"]): r for r in table("SpellMisc") if num(r["DifficultyID"]) == 0}
        self.eff = {}
        for r in table("SpellEffect"):
            if num(r["DifficultyID"]) == 0:
                self.eff.setdefault(int(r["SpellID"]), []).append(r)
        self.power = {}
        for r in table("SpellPower"):
            self.power.setdefault(int(r["SpellID"]), r)
        self.cd = {int(r["SpellID"]): r for r in table("SpellCooldowns")}
        self.cast = {int(r["ID"]): r for r in table("SpellCastTimes")}
        # the class skill line a spell is taught under (the trainer's headers: Fire, Frost, Arms, Holy ...)
        lines = {int(r["ID"]): r for r in table("SkillLine")}
        self.line = {}
        for r in table("SkillLineAbility"):
            sl = lines.get(int(r["SkillLine"]))
            if sl and int(sl["CategoryID"] or 0) == 7:
                self.line.setdefault(int(r["Spell"]), sl["DisplayName_lang"])
                LINE_ICONS[sl["DisplayName_lang"]] = int(sl["SpellIconFileID"] or 0) or None
        self.dur = {int(r["ID"]): r for r in table("SpellDuration")}
        self.rng = {int(r["ID"]): r for r in table("SpellRange")}
        self.rad = {int(r["ID"]): r for r in table("SpellRadius")}
        self.lvl = {int(r["SpellID"]): r for r in table("SpellLevels")}
        self.cat = {int(r["SpellID"]): r for r in table("SpellCategories")}
        self.aura = {int(r["SpellID"]): r for r in table("SpellAuraOptions")}
        self.intr = {int(r["SpellID"]): r for r in table("SpellInterrupts")}
        self.shape = {int(r["SpellID"]): r for r in table("SpellShapeshift")} if os.path.exists(
            os.path.join(D2, "SpellShapeshift.csv")) else {}
        self.classopt = {int(r["SpellID"]): r for r in table("SpellClassOptions")}

    def export(self, sid):
        m = self.misc.get(sid, {})
        s = self.spell.get(sid, {})
        p = self.power.get(sid, {})
        cd = self.cd.get(sid, {})
        lv = self.lvl.get(sid, {})
        cat = self.cat.get(sid, {})
        au = self.aura.get(sid, {})
        it = self.intr.get(sid, {})
        rng = self.rng.get(num(m.get("RangeIndex")), {})
        dur = self.dur.get(num(m.get("DurationIndex")), {})
        attrs = [num(m.get("Attributes_%d" % i)) for i in range(8)]
        effects = []
        for e in sorted(self.eff.get(sid, []), key=lambda e: num(e["EffectIndex"])):
            rad = self.rad.get(num(e["EffectRadiusIndex_0"]), {})
            effects.append({
                "i": num(e["EffectIndex"]), "e": num(e["Effect"]), "a": num(e["EffectAura"]) or None,
                "bp": num(e["EffectBasePoints"]), "die": num(e["EffectDieSides"]) or None,
                "per": num(e["EffectAuraPeriod"]) or None, "trig": num(e["EffectTriggerSpell"]) or None,
                "misc": num(e["EffectMiscValue_0"]) or None, "t1": num(e["ImplicitTarget_0"]) or None,
                "t2": num(e["ImplicitTarget_1"]) or None, "rad": num(rad.get("Radius"), float) or None,
                "coef": round(num(e["EffectBonusCoefficient"], float), 4) or None,
                "rplv": round(num(e["EffectRealPointsPerLevel"], float), 3) or None,
                "chain": num(e["EffectChainTargets"]) or None, "item": num(e["EffectItemType"]) or None,
                "mech": num(e["EffectMechanic"]) or None, "amp": round(num(e["EffectAmplitude"], float), 3) or None,
            })
        castBase = self.cast.get(num(m.get("CastingTimeIndex")), {})
        out = {
            "n": self.name.get(sid, "?"), "r": s.get("NameSubtext_lang") or None, "line": self.line.get(sid),
            "icon": num(m.get("SpellIconFileDataID")) or None, "school": num(m.get("SchoolMask")) or 1,
            "cast": num(castBase.get("Base")) or None, "dur": num(dur.get("Duration")) or None,
            "durLv": num(dur.get("DurationPerLevel")) or None, "durMax": num(dur.get("MaxDuration")) or None,
            "range": num(rng.get("RangeMax_0"), float) or None, "minRange": num(rng.get("RangeMin_0"), float) or None,
            "cost": num(p.get("ManaCost")) or None, "costPct": num(p.get("PowerCostPct"), float) or None,
            "costLv": num(p.get("ManaCostPerLevel")) or None,
            "pt": num(p.get("PowerType")) if p else None,
            "cd": num(cd.get("RecoveryTime")) or None, "catCd": num(cd.get("CategoryRecoveryTime")) or None,
            "gcd": num(cd.get("StartRecoveryTime")) if cd else None,
            "gcdCat": num(cat.get("StartRecoveryCategory")) or None, "cat": num(cat.get("Category")) or None,
            "dispel": num(cat.get("DispelType")) or None, "mech": num(cat.get("Mechanic")) or None,
            "defType": num(cat.get("DefenseType")) or None,
            "lvl": num(lv.get("SpellLevel")) or None, "baseLvl": num(lv.get("BaseLevel")) or None,
            "maxLvl": num(lv.get("MaxLevel")) or None,
            "stack": num(au.get("CumulativeAura")) or None, "procChance": num(au.get("ProcChance")) or None,
            "procCharges": num(au.get("ProcCharges")) or None,
            "intr": num(it.get("InterruptFlags")) or None, "chIntr": num(it.get("ChannelInterruptFlags_0")) or None,
            "auraIntr": num(it.get("AuraInterruptFlags_0")) or None,
            "attr": attrs if any(attrs) else None,
            "speed": num(m.get("Speed"), float) or None,
            "desc": s.get("Description_lang") or None, "auraDesc": s.get("AuraDescription_lang") or None,
            "fx": effects,
        }
        return out

    def triggered(self, sid):
        out = []
        for e in self.eff.get(sid, []):
            t = num(e["EffectTriggerSpell"])
            if t:
                out.append(t)
        return out


# ---------------------------------------------------------------------------------------------------------------
# Items
# ---------------------------------------------------------------------------------------------------------------

def export_item(r, icons):
    stats = []
    for i in range(1, 11):
        t, v = r["stat_type%d" % i], r["stat_value%d" % i]
        if t and v:
            stats.extend([t, v])
    spells = []
    for i in range(1, 6):
        sid = r["spellid_%d" % i]
        if sid:
            spells.append([sid, r["spelltrigger_%d" % i], r["spellcharges_%d" % i], r["spellcooldown_%d" % i],
                           r["spellcategory_%d" % i], r["spellcategorycooldown_%d" % i]])
    out = {
        "n": r["name"], "q": r["Quality"], "c": r["class"], "s": r["subclass"], "inv": r["InventoryType"] or None,
        "icon": icons.get(r["entry"]), "ilvl": r["ItemLevel"] or None, "req": r["RequiredLevel"] or None,
        "buy": r["BuyPrice"] or None, "sell": r["SellPrice"] or None, "bc": (r["BuyCount"] if r["BuyCount"] != 1 else None),
        "stack": r["stackable"] if r["stackable"] and r["stackable"] > 1 else None,
        "cls": r["AllowableClass"] if r["AllowableClass"] not in (-1, 0, 32767, 1535) else None,
        "armor": r["armor"] or None, "block": r["block"] or None,
        "stats": stats or None,
        "dmg": [r["dmg_min1"], r["dmg_max1"], r["dmg_type1"]] if r["dmg_max1"] else None,
        "spd": r["delay"] if r["dmg_max1"] else None,
        "spells": spells or None, "bind": r["bonding"] or None, "unique": r["maxcount"] or None,
        "slots": r["ContainerSlots"] or None, "desc": r["description"] or None, "quest": r["startquest"] or None,
        "dur": r["MaxDurability"] or None, "res": [r["holy_res"], r["fire_res"], r["nature_res"], r["frost_res"],
                                                   r["shadow_res"], r["arcane_res"]]
        if any([r["holy_res"], r["fire_res"], r["nature_res"], r["frost_res"], r["shadow_res"], r["arcane_res"]]) else None,
        "food": r["FoodType"] or None, "flags": r["Flags"] or None,
    }
    return out


# ---------------------------------------------------------------------------------------------------------------
# Spell visuals: the client's own effect models and sounds per spell (SpellXSpellVisual -> SpellVisual ->
# SpellVisualEvent -> SpellVisualKit -> its effects: model attachments (SpellVisualKitModelAttach ->
# SpellVisualEffectName.ModelFileDataID) and sound kits; the missile from SpellVisualMissile)
# ---------------------------------------------------------------------------------------------------------------

# SpellVisualEvent StartEvent -> our moment: 1 precast (until 2), 3 cast, 6 impact, 7 aura (until 8), 11 channel
VIS_EVENTS = {1: "pre", 3: "cast", 6: "imp", 7: "aura", 11: "chan"}


def spell_visuals(spell_ids):
    xv = {}
    for r in table("SpellXSpellVisual"):
        if num(r["DifficultyID"]) == 0:
            xv.setdefault(num(r["SpellID"]), []).append(r)
    sv = {num(r["ID"]): r for r in table("SpellVisual")}
    ev = {}
    for r in table("SpellVisualEvent"):
        ev.setdefault(num(r["SpellVisualID"]), []).append(r)
    kfx = {}
    for r in table("SpellVisualKitEffect"):
        kfx.setdefault(num(r["ParentSpellVisualKitID"]), []).append(r)
    att = {num(r["ID"]): r for r in table("SpellVisualKitModelAttach")}
    en = {num(r["ID"]): r for r in table("SpellVisualEffectName")}
    mis = {}
    for r in table("SpellVisualMissile"):
        mis.setdefault(num(r["SpellVisualMissileSetID"]), []).append(r)
    out = {}
    for sid in spell_ids:
        rows = sorted(xv.get(sid, []), key=lambda r: -num(r["Priority"]))
        if not rows:
            continue
        vid = num(rows[0]["SpellVisualID"])
        v = sv.get(vid, {})
        d = {}
        for e in ev.get(vid, []):
            what = VIS_EVENTS.get(num(e["StartEvent"]))
            if not what:
                continue
            target = num(e["TargetType"])           # 1 the caster, 2 the target
            if what == "imp" and target == 1 and any(num(x["StartEvent"]) == 6 and num(x["TargetType"]) == 2
                                                       for x in ev.get(vid, [])):
                continue                             # (the impact on the target is the one we play)
            models, sound = [], None
            for k in kfx.get(num(e["SpellVisualKitID"]), []):
                et = num(k["EffectType"])
                if et == 2:
                    a = att.get(num(k["Effect"]))
                    n = a and en.get(num(a["SpellVisualEffectNameID"]))
                    if n and num(n["ModelFileDataID"]):
                        models.append([num(n["ModelFileDataID"]), num(a["AttachmentID"]),
                                       round(num(a["Scale"], float) * (num(n["Scale"], float) or 1), 3),
                                       round(num(a["Offset_2"], float), 3)])
                elif et == 5 and not sound:
                    sound = num(k["Effect"])
            if models or sound:
                d[what] = {"m": models or None, "s": sound, "on": target}
        ms = num(v.get("SpellVisualMissileSetID")) if v else 0
        for m in mis.get(ms, [])[:1]:
            n = en.get(num(m["SpellVisualEffectNameID"]))
            if n and num(n["ModelFileDataID"]):
                d["mis"] = {"m": num(n["ModelFileDataID"]), "sc": num(n["Scale"], float) or 1,
                            "from": num(m["Attachment"]), "to": num(m["DestinationAttachment"])}
        if d:
            out[sid] = d
    return out


# ---------------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------------

def main():
    db = dc_db.load()
    wdb = tbcdb.load()
    SP = Spells()
    ents, quest_ids = world_entities()
    ct = db.index("creature_template", "Entry")
    it = db.index("item_template", "entry")
    icons = {num(r["ID"]): num(r["IconFileDataID"]) for r in table("Item")}

    spells = set()
    items = set(EXTRA_ITEMS)

    # ---- classes
    lvlstats = {}
    for r in db.rows("player_levelstats"):
        if r["race"] == RACE:
            lvlstats[(r["class"], r["level"])] = r
    classlvl = {(r["class"], r["level"]): r for r in db.rows("player_classlevelstats")}
    xp = {r["lvl"]: r["xp_for_next_level"] for r in db.rows("player_xp_for_level")}
    create = {(r["race"], r["class"]): r for r in db.rows("playercreateinfo")}
    outfit = {}
    for r in table("CharStartOutfit"):
        if num(r["RaceID"]) == RACE:
            outfit[(num(r["ClassID"]), num(r["SexID"]))] = [num(r["ItemID_%d" % i]) for i in range(24)
                                                             if num(r.get("ItemID_%d" % i)) > 0]
    classes = {}
    trainers = {}
    for cls, token in CLASSES.items():
        levels = []
        for L in range(1, MAX_LEVEL + 1):
            a, b = lvlstats[(cls, L)], classlvl[(cls, L)]
            levels.append([b["basehp"], b["basemana"], a["str"], a["agi"], a["sta"], a["inte"], a["spi"]])
        start = [r["Spell"] for r in db.rows("playercreateinfo_spell")
                 if r["race"] == RACE and r["class"] == cls and r["Spell"] in START_KEEP]
        spells.update(start)
        bar = {}
        for r in db.rows("playercreateinfo_action"):
            if r["race"] == RACE and r["class"] == cls:
                b = r["button"] % 12 + 1 if r["button"] >= 72 else r["button"] + 1
                bar[b] = [r["type"], r["action"]]          # type 0 = spell, 128 = item
                if r["type"] == 128:
                    items.add(r["action"])
        gear = outfit.get((cls, 0), [])
        items.update(gear)
        c = create[(RACE, cls)]
        gx = (17066.67 - c["position_y"]) / TS
        gy = (17066.67 - c["position_x"]) / TS
        classes[cls] = {"token": token, "levels": levels, "start": start, "bar": bar, "gear": gear,
                        "pos": [round(gx, 2), round(gy, 2)]}
        # every spell this class can train to MAX_LEVEL (both templates) - trainers below
        for tmpl in TRAINER_TEMPLATES[cls]:
            rows = []
            for r in db.multi("npc_trainer_template", "entry").get(tmpl, []):
                if r["reqlevel"] <= MAX_LEVEL and r["spell"] not in (13908, 10797, 2652, 32548, 9035):  # (other races)
                    rows.append([r["spell"], r["spellcost"], max(1, r["reqlevel"]), r["ReqAbility1"] or None])
                    spells.add(r["spell"])
            rows.sort(key=lambda x: (x[2], x[0]))
            trainers[tmpl] = rows
        # Desperate Prayer is the Human priest's racial (level 10)
        if cls == 5:
            trainers[51].append([13908, 100, 10, None])
            spells.add(13908)

    # ---- creatures (mobs, critters, NPCs)
    creatures = {}
    loot = {}
    refs = {}
    vendors = {}
    eventai = {}
    texts = {}
    bt = wdb.index("broadcast_text", "Id")
    npctext = wdb.index("npc_text", "ID")
    gossip = wdb.multi("gossip_menu", "entry")
    ai = db.multi("creature_ai_scripts", "creature_id")
    # hostility to an Alliance player (WoW's rule as Wowhead shows it: the template's enemy group holds players,
    # or the creature is of the "monster" group without being their friend)
    ftemp = {int(r["ID"]): r for r in csv.DictReader(open(os.path.join(DEV, "art", "tbcdb", "db2", "FactionTemplate.csv"),
                                                            encoding="utf-8"))}

    def hostile(fac):
        t = ftemp.get(fac)
        if not t:
            return False
        eg, fg, fr = int(t["EnemyGroup"]), int(t["FactionGroup"]), int(t["FriendGroup"])
        if eg & 3:
            return True
        return bool(fg & 8) and not (fr & 3)

    def add_loot(lid, tname="creature_loot_template", into=None):
        rows = db.multi(tname, "entry").get(lid, [])
        out = []
        for r in rows:
            if r["mincountOrRef"] < 0:
                ref = -r["mincountOrRef"]
                out.append([0, r["ChanceOrQuestChance"], r["groupid"], ref, r["maxcount"]])
                if ref not in refs:
                    refs[ref] = None
                    refs[ref] = add_loot(ref, "reference_loot_template")
            else:
                if r["item"] not in it:
                    continue
                out.append([r["item"], r["ChanceOrQuestChance"], r["groupid"], r["mincountOrRef"] or 1, r["maxcount"] or 1])
                items.add(r["item"])
        return out

    for kind in ("mob", "critter", "npc"):
        for e in sorted(ents[kind]):
            c = ct.get(e)
            if not c:
                continue
            flags = c["NpcFlags"]
            d = {"n": c["Name"], "sub": c["SubName"] or None, "lv": [c["MinLevel"], c["MaxLevel"]],
                 "disp": c["DisplayId1"] or None, "det": c["Detection"] or None,
                 "cfh": c["CallForHelp"] or None, "pursuit": c["Pursuit"] or None,
                 "hp": [c["MinLevelHealth"], c["MaxLevelHealth"]], "mana": [c["MinLevelMana"], c["MaxLevelMana"]]
                 if c["MaxLevelMana"] else None,
                 "dmg": [max(1, int(c["MinMeleeDmg"])), max(1, int(round(c["MaxMeleeDmg"])))],
                 "ap": c["MeleeAttackPower"] or None, "armor": c["Armor"] or None,
                 "spd": c["MeleeBaseAttackTime"], "rank": c["Rank"] or None, "type": c["CreatureType"] or None,
                 "fam": c["Family"] or None, "fac": c["Faction"], "flags": flags or None,
                 "hostile": hostile(c["Faction"]) or None,
                 "school": c["DamageSchool"] or None, "run": round(c["SpeedRun"], 3), "walk": round(c["SpeedWalk"], 3),
                 "xpm": c["ExperienceMultiplier"] if c["ExperienceMultiplier"] != 1 else None,
                 "gold": [c["MinLootGold"], c["MaxLootGold"]] if c["MaxLootGold"] else None,
                 "cls": c["UnitClass"] if c["UnitClass"] != 1 else None,
                 "credit": c["KillCredit1"] or None,
                 "resist": [c["ResistanceHoly"], c["ResistanceFire"], c["ResistanceNature"], c["ResistanceFrost"],
                            c["ResistanceShadow"], c["ResistanceArcane"]]
                 if any([c["ResistanceHoly"], c["ResistanceFire"], c["ResistanceNature"], c["ResistanceFrost"],
                         c["ResistanceShadow"], c["ResistanceArcane"]]) else None}
            if kind == "npc":
                roles = []
                for bit, role in ((2, "quest"), (16, "trainer"), (128, "vendor"), (4096, "repair"),
                                  (8192, "flight"), (16384, "spirit"), (65536, "inn"), (131072, "bank")):
                    if flags & bit:
                        roles.append(role)
                d["roles"] = roles or None
                if flags & 16 and c["TrainerType"] == 0 and c["TrainerClass"] in CLASSES:
                    d["trainer"] = TRAINER_TEMPLATES[c["TrainerClass"]][0]
                    d["tcls"] = c["TrainerClass"]
                # vendor stock
                if flags & 128:
                    stock = []
                    for r in db.multi("npc_vendor", "entry").get(e, []) + \
                            db.multi("npc_vendor_template", "entry").get(c["VendorTemplateId"], []):
                        if r["item"] in it and not r["ExtendedCost"]:
                            stock.append([r["item"], r["maxcount"] or None, r["incrtime"] or None])
                            items.add(r["item"])
                    if stock:
                        vendors[e] = stock
                # gossip greeting
                for g in gossip.get(c["GossipMenuId"], []):
                    nt = npctext.get(g["text_id"])
                    if nt:
                        t = nt["text0_0"] or nt["text0_1"]
                        if t:
                            d["say"] = t
                            break
            if kind == "mob" and c["LootId"]:
                loot[e] = add_loot(c["LootId"])
            # EventAI: the bits the game plays (timers, hp %, aggro, range, spawn, missing buff; say / cast / flee)
            rules = []
            for r in ai.get(e, []):
                ev = r["event_type"]
                if ev not in (0, 2, 4, 9, 11, 27, 33):
                    continue
                acts = []
                for k in (1, 2, 3):
                    at = r["action%d_type" % k]
                    p1, p2, p3 = r["action%d_param1" % k], r["action%d_param2" % k], r["action%d_param3" % k]
                    if at == 1:
                        lines = [bt[x]["Text"] or bt[x]["Text1"] for x in (p1, p2, p3) if x and x in bt]
                        if lines:
                            acts.append(["say", lines])
                    elif at == 11 and p1:
                        acts.append(["cast", p1, p2])          # target: 0 self, 1 victim
                        spells.add(p1)
                    elif at == 25:
                        acts.append(["flee"])
                    elif at == 57:
                        acts.append(["ranged", p2 or 30])
                if acts:
                    rules.append([ev, r["event_chance"], r["event_param1"], r["event_param2"], r["event_param3"],
                                  r["event_param4"], acts])
            if rules:
                eventai[e] = rules
            creatures[e] = d

    # ---- quests: rewards and xp
    qt = db.index("quest_template", "entry")
    quests = {}
    for q in sorted(quest_ids):
        r = qt.get(q)
        if not r:
            continue
        choice = [[r["RewChoiceItemId%d" % i], r["RewChoiceItemCount%d" % i]] for i in range(1, 7) if r["RewChoiceItemId%d" % i]]
        rew = [[r["RewItemId%d" % i], r["RewItemCount%d" % i]] for i in range(1, 5) if r["RewItemId%d" % i]]
        for x in choice + rew:
            items.add(x[0])
        if r["SrcItemId"]:
            items.add(r["SrcItemId"])
        for i in range(1, 5):
            if r["ReqItemId%d" % i]:
                items.add(r["ReqItemId%d" % i])
        quests[q] = {"lvl": r["QuestLevel"], "xpm": r["RewMoneyMaxLevel"] or None,
                     "money": r["RewOrReqMoney"] if r["RewOrReqMoney"] > 0 else None,
                     "choice": choice or None, "rew": rew or None, "spell": r["RewSpellCast"] or r["RewSpell"] or None,
                     "src": [r["SrcItemId"], r["SrcItemCount"] or 1] if r["SrcItemId"] else None,
                     "offer": r["OfferRewardText"] or None, "req": r["RequestItemsText"] or None,
                     "flags": r["QuestFlags"] or None, "next": r["NextQuestInChain"] or None,
                     "zone": zone_names().get(r["ZoneOrSort"]) if r["ZoneOrSort"] > 0 else None}
        if r["RewSpellCast"] or r["RewSpell"]:
            spells.add(r["RewSpellCast"] or r["RewSpell"])

    # ---- items: everything referenced (and their spells)
    item_out = {}
    for i in sorted(items):
        r = it.get(i)
        if not r:
            continue
        item_out[i] = export_item(r, icons)
        for s in item_out[i]["spells"] or []:
            spells.add(s[0])

    # ---- spells (and what they trigger)
    todo = list(spells)
    seen = set()
    spell_out = {}
    chain = db.index("spell_chain", "spell_id")
    while todo:
        s = todo.pop()
        if s in seen or s not in SP.misc and s not in SP.eff:
            continue
        seen.add(s)
        spell_out[s] = SP.export(s)
        ch = chain.get(s)
        if ch:
            spell_out[s]["prev"] = ch["prev_spell"] or None
            spell_out[s]["first"] = ch["first_spell"] or None
            spell_out[s]["rank"] = ch["rank"] or None
        for t in SP.triggered(s):
            todo.append(t)
        for e in spell_out[s]["fx"]:
            if e["e"] == 24 and e["item"]:              # CREATE_ITEM
                if e["item"] not in item_out and e["item"] in it:
                    item_out[e["item"]] = export_item(it[e["item"]], icons)
    threat = {r["entry"]: [r["Threat"], r["multiplier"], r["ap_bonus"]] for r in db.rows("spell_threat")}
    for s, d in spell_out.items():
        if s in threat:
            d["threat"] = threat[s]

    # ---- the graveyard (spirit healer) of the start zone
    gy = []
    for r in db.rows("world_safe_locs"):
        if r["id"] == 105:
            gy.append({"x": round((17066.67 - r["y"]) / TS, 2), "y": round((17066.67 - r["x"]) / TS, 2),
                       "n": r["name"]})

    vis = spell_visuals(sorted(spell_out))
    write(classes, xp, trainers, spell_out, item_out, creatures, loot, refs, vendors, eventai, quests, gy, vis)


def write(classes, xp, trainers, spells, items, creatures, loot, refs, vendors, eventai, quests, gy, vis):
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    L = []
    w = L.append
    w('if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Data.lua", ...) then return end '
      '-- DisasterZone Games/Disastercraft/Data.lua  (GENERATED by dev/generators/gen_disastercraft.py - do not edit)')
    w("-- Disastercraft's data from the TBC world database (cMaNGOS) and the 2.5.6 client tables: classes, spells,")
    w("-- items, loot, creatures, vendors, trainers, quest rewards. Times in ms, ranges in yards, money in copper.")
    w("local addonName, ns = ...")
    w("local D = {}")
    w("ns.CraftData = D")
    w("D.MAX_LEVEL = %d" % MAX_LEVEL)
    w("-- xp to the next level")
    w("D.xp = %s" % lua([xp[i] for i in range(1, MAX_LEVEL + 1)]))
    w("-- class: levels = { { base hp, base mana, str, agi, sta, int, spi } per level }, start spells, bar = { [slot] =")
    w("-- { type (0 spell, 128 item), id } }, gear = start outfit, pos = the first step (world tiles)")
    w("-- the class skill lines (spellbook tabs, trainer headers): name -> icon")
    w("D.skillLines = %s" % lua({k: v for k, v in sorted(LINE_ICONS.items()) if v}))
    w("D.classes = {}")
    for c in sorted(classes):
        w("D.classes[%d] = %s" % (c, lua(classes[c])))
    w("-- trainer template -> { { spell, cost (copper), level, required spell } }")
    w("D.trainers = {}")
    for t in sorted(trainers):
        w("D.trainers[%d] = %s" % (t, lua(trainers[t])))
    w("-- spells: fx = effects { i, e (SPELL_EFFECT_*), a (SPELL_AURA_*), bp, die, per, trig, misc, t1/t2 (targets),")
    w("-- rad, coef, rplv }")
    w("local S = {}")
    w("D.spells = S")
    for s in sorted(spells):
        w("S[%d] = %s" % (s, lua(spells[s])))
    w("-- items: q quality, c / s class / subclass, inv InventoryType, stats { type, value, ... }, dmg { min, max,")
    w("-- school }, spd ms, spells { { id, trigger, charges, cd, cat, catCd } }")
    w("local I = {}")
    w("D.items = I")
    for i in sorted(items):
        w("I[%d] = %s" % (i, lua(items[i])))
    w("-- creatures by entry")
    w("local C = {}")
    w("D.creatures = C")
    for e in sorted(creatures):
        w("C[%d] = %s" % (e, lua(creatures[e])))
    w("-- loot by creature entry / reference id: { item (0 = reference), chance (<0 quest), group, min (ref id), max }")
    w("D.loot = {}")
    for e in sorted(loot):
        w("D.loot[%d] = %s" % (e, lua(loot[e])))
    w("D.lootRefs = {}")
    for e in sorted(refs):
        w("D.lootRefs[%d] = %s" % (e, lua(refs[e] or [])))
    w("-- vendor stock by NPC entry: { item, max count, restock seconds }")
    w("D.vendors = {}")
    for e in sorted(vendors):
        w("D.vendors[%d] = %s" % (e, lua(vendors[e])))
    w("-- EventAI by creature entry: { event, chance, p1, p2, p3, p4, actions }")
    w("D.eventai = {}")
    for e in sorted(eventai):
        w("D.eventai[%d] = %s" % (e, lua(eventai[e])))
    w("-- quest rewards / xp (World/Quests.lua has the texts and objectives)")
    w("D.quests = {}")
    for q in sorted(quests):
        w("D.quests[%d] = %s" % (q, lua(quests[q])))
    w("D.graveyards = %s" % lua(gy))
    w("-- spell visuals: pre (while casting) / cast / imp (impact) / aura (while it lasts) / chan: { m = { { model")
    w("-- FileDataID, attachment, scale, z offset } }, s = sound kit, on = 1 caster | 2 target }; mis = the missile")
    w("D.vis = {}")
    for sid in sorted(vis):
        w("D.vis[%d] = %s" % (sid, lua(vis[sid])))
    open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(L) + "\n")
    print("wrote", OUT, "spells", len(spells), "items", len(items), "creatures", len(creatures),
          "refs", len(refs), "bytes", os.path.getsize(OUT))


if __name__ == "__main__":
    main()
