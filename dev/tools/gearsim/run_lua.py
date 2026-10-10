"""Run the addon's Lua gear sim (AddOns/DisasterZone/Sim/*.lua) on Lua 5.1 (lupa) for a scenario, and compare it
with the WoWSims reference (scenario.ref.json written by wowsims_ref.py --json).

Usage:
  luaenv/Scripts/python.exe tools/gearsim/run_lua.py scenarios/ret_p1_default.json [--iterations N] [--log]

The item data is read from WoWSims' own database (dev/ext/wowsims-tbc/assets/database/db.json) and the trigger
settings of generic item procs from its generated Go file, the same way the addon's generated data will be.
"""
import argparse
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from specs import SPECS  # noqa: E402

from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.normpath(os.path.join(HERE, "..", ".."))
WOWSIMS = os.path.join(DEV, "ext", "wowsims-tbc")
ADDON = os.path.normpath(os.path.join(DEV, "..", "addon", "DisasterZone"))
if not os.path.isdir(ADDON):
    ADDON = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
SIM_FILES = ["Core", "Unit", "Spell", "Attack", "Resources", "Dot", "Pet", "APL", "Character", "Buffs", "Items",
             "Paladin", "Warrior", "Shaman", "Rogue", "Druid", "Data", "Setup"]
DATA_FILES = ["Data/Gems.lua", "Data/SimItems.lua"]

# ---------------------------------------------------------------------------------------------------------------
# Item data
# ---------------------------------------------------------------------------------------------------------------
PM = {"ProcMaskEmpty": 2, "ProcMaskMeleeMHAuto": 4, "ProcMaskMeleeOHAuto": 8, "ProcMaskMeleeMHSpecial": 16,
      "ProcMaskMeleeOHSpecial": 32, "ProcMaskRangedAuto": 64, "ProcMaskRangedSpecial": 128, "ProcMaskSpellDamage": 256,
      "ProcMaskSpellHealing": 512, "ProcMaskSpellDamageProc": 1024, "ProcMaskUnknown": 0}
PM["ProcMaskMeleeMH"] = PM["ProcMaskMeleeMHAuto"] | PM["ProcMaskMeleeMHSpecial"]
PM["ProcMaskMeleeOH"] = PM["ProcMaskMeleeOHAuto"] | PM["ProcMaskMeleeOHSpecial"]
PM["ProcMaskMeleeWhiteHit"] = PM["ProcMaskMeleeMHAuto"] | PM["ProcMaskMeleeOHAuto"]
PM["ProcMaskMeleeSpecial"] = PM["ProcMaskMeleeMHSpecial"] | PM["ProcMaskMeleeOHSpecial"]
PM["ProcMaskMelee"] = PM["ProcMaskMeleeWhiteHit"] | PM["ProcMaskMeleeSpecial"]
PM["ProcMaskRanged"] = PM["ProcMaskRangedAuto"] | PM["ProcMaskRangedSpecial"]
PM["ProcMaskMeleeOrRanged"] = PM["ProcMaskMelee"] | PM["ProcMaskRanged"]
PM["ProcMaskDirect"] = PM["ProcMaskMeleeOrRanged"] | PM["ProcMaskSpellDamage"]
OUTCOME = {"OutcomeEmpty": 0, "OutcomeMiss": 2, "OutcomeHit": 4, "OutcomeDodge": 8, "OutcomeGlance": 16,
           "OutcomeParry": 32, "OutcomeBlock": 64, "OutcomeCrit": 128, "OutcomeLanded": 4 | 128 | 512 | 256 | 16 | 64}
CALLBACK = {"CallbackOnSpellHitDealt": "hit", "CallbackOnSpellHitTaken": "taken", "CallbackOnCastComplete": "cast",
            "CallbackOnPeriodicDamageDealt": "periodic", "CallbackOnApplyEffects": "apply"}


def _mask(expr, table):
    v = 0
    for part in expr.split("|"):
        part = part.strip().replace("core.", "")
        if part in table:
            v |= table[part]
    return v


def parse_go_procs():
    """itemID -> trigger settings, from the generated ProcStatBonusEffect blocks (commented-out ones skipped)."""
    path = os.path.join(WOWSIMS, "sim", "common", "tbc", "stat_bonus_procs_auto_gen.go")
    lines = [l for l in open(path, encoding="utf-8") if not l.lstrip().startswith("//")]
    src = "".join(lines)
    out = {}
    for m in re.finditer(r"shared\.New(?:Stacking)?ProcStatBonusEffectWithVariants\(shared\.ProcStatBonusEffect\{(.*?)\},\s*\[\]shared\.ItemVariant\{(.*?)\}\)", src, re.S):
        body, variants = m.group(1), m.group(2)
        cfg = {}
        cb = re.search(r"Callback:\s*([^,\n]+)", body)
        if cb:
            cbs = [CALLBACK.get(c.strip().replace("core.", "")) for c in cb.group(1).split("|")]
            cbs = [c for c in cbs if c]
            cfg["callback"] = cbs[0] if len(cbs) == 1 else cbs
        pm = re.search(r"ProcMask:\s*([^,\n]+)", body)
        if pm:
            cfg["procMask"] = _mask(pm.group(1), PM)
        oc = re.search(r"Outcome:\s*([^,\n]+)", body)
        if oc:
            cfg["outcome"] = _mask(oc.group(1), OUTCOME)
        for k, key in (("RequireDamageDealt", "requireDamage"), ("IsWeaponProc", "weaponProc"),
                       ("CanProcFromProcs", "canProcFromProcs"), ("ClassSpellsOnly", "classSpellsOnly")):
            mm = re.search(k + r":\s*(true|false)", body)
            if mm:
                cfg[key] = mm.group(1) == "true"
        for vid in re.findall(r"ItemID:\s*(\d+)", variants):
            out[int(vid)] = cfg
    return out


def parse_go_onuse():
    ids = set()
    for name in ("stat_bonus_cds_auto_gen.go", "items_trinkets.go"):   # the figurines are in items_trinkets.go
        for line in open(os.path.join(WOWSIMS, "sim", "common", "tbc", name), encoding="utf-8"):
            if line.lstrip().startswith("//"):
                continue
            m = re.search(r"shared\.NewSimpleStatActive\((\d+)\)", line)
            if m:
                ids.add(int(m.group(1)))
    return ids


def dense_to_dict(arr):
    return {i: v for i, v in enumerate(arr or []) if v}


def build_db(gear):
    db = json.load(open(os.path.join(WOWSIMS, "assets", "database", "db.json"), encoding="utf-8"))
    items_by_id = {i["id"]: i for i in db["items"]}
    gems_by_id = {g["id"]: g for g in db["gems"]}
    ench_by_id = {e["effectId"]: e for e in db["enchants"]}
    items, gems, enchants = {}, {}, {}
    for spec in gear:
        if not spec or not spec.get("id"):
            continue
        it = items_by_id[spec["id"]]
        so = it.get("scalingOptions", {}).get("0", {})
        effects = []
        for e in it.get("itemEffects", []):
            eso = (e.get("scalingOptions") or {}).get("0", {})
            ef = {"buffId": e.get("buffId"), "durationMs": e.get("effectDurationMs", 0),
                  "stats": {int(k): v for k, v in (eso.get("stats") or {}).items()}}
            if e.get("proc"):
                ef["proc"] = {"ppm": e["proc"].get("ppm", 0), "icdMs": e["proc"].get("icdMs", 0),
                              "procChance": e["proc"].get("procChance", 0)}
            if e.get("onUse"):
                ef["onUse"] = {"cooldownMs": e["onUse"].get("cooldownMs", 0), "categoryId": e["onUse"].get("categoryId", 0),
                               "categoryCooldownMs": e["onUse"].get("categoryCooldownMs", 0)}
            effects.append(ef)
        items[it["id"]] = {
            "id": it["id"], "type": it.get("type"), "handType": it.get("handType"), "weaponType": it.get("weaponType"),
            "weaponSpeed": it.get("weaponSpeed"), "weaponMin": so.get("weaponDamageMin"), "weaponMax": so.get("weaponDamageMax"),
            "stats": {int(k): v for k, v in (so.get("stats") or {}).items()},
            "sockets": it.get("gemSockets", []), "socketBonus": dense_to_dict(it.get("socketBonus")),
            "setName": it.get("setName"), "effects": effects, "randPropPoints": so.get("randPropPoints", 0),
        }
        for gid in spec.get("gems", []):
            g = gems_by_id.get(gid)
            if g:
                gems[gid] = {"id": gid, "color": g["color"], "stats": dense_to_dict(g.get("stats"))}
        if spec.get("enchant"):
            e = ench_by_id.get(spec["enchant"])
            if e:
                enchants[spec["enchant"]] = {"effectId": e["effectId"], "stats": dense_to_dict(e.get("stats"))}
    effects = {e["id"]: e for e in db.get("spellEffects", [])}

    def gains(c):
        out = []
        for eid in c.get("effectIds") or []:
            e = effects.get(eid)
            if e and e.get("resourceType"):
                out.append({"min": e.get("minEffectSize", 0), "spread": e.get("effectSpread", 0),
                            "resource": e["resourceType"], "periodMs": e.get("auraPeriodMs", 0),
                            "durationMs": e.get("durationMs", 0)})
        return out
    consumables = {c["id"]: {"id": c["id"], "type": c.get("type", 0), "stats": dense_to_dict(c.get("stats")),
                             "buffDuration": c.get("buffDuration", 0), "cooldown": c.get("cooldownDuration", 0),
                             "categoryCooldown": c.get("categoryCooldownDuration", 0),
                             "categoryId": c.get("categoryId", 0), "gains": gains(c)}
                   for c in db.get("consumables", [])}
    suffixes = {r["id"]: {"id": r["id"], "stats": dense_to_dict(r.get("stats"))} for r in db.get("randomSuffixes", [])}
    return {"items": items, "gems": gems, "enchants": enchants, "itemProcs": parse_go_procs(),
            "onUse": {i: True for i in parse_go_onuse()}, "consumables": consumables, "suffixes": suffixes}


# ---------------------------------------------------------------------------------------------------------------
# Lua
# ---------------------------------------------------------------------------------------------------------------
def to_lua(L, obj):
    """Python -> Lua table, lists 1-based."""
    if isinstance(obj, dict):
        t = L.table()
        for k, v in obj.items():
            t[k] = to_lua(L, v)
        return t
    if isinstance(obj, (list, tuple)):
        t = L.table()
        for i, v in enumerate(obj):
            t[i + 1] = to_lua(L, v)
        return t
    return obj


def to_py(obj):
    if lua51.lua_type(obj) == "table":
        keys = list(obj.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [to_py(obj[k]) for k in sorted(keys)]
        return {k: to_py(obj[k]) for k in keys}
    return obj


def load_engine(log=None, gamedb=False):
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    ns = L.table()
    if gamedb:
        for rel in DATA_FILES:
            with open(os.path.join(ADDON, rel), encoding="utf-8") as f:
                src = f.read()
            L.eval("function(src, name) local f, err = loadstring(src, name); if not f then error(err) end; return f end")(src, "@" + rel)("DisasterZone", ns)
    for name in SIM_FILES:
        path = os.path.join(ADDON, "Sim", name + ".lua")
        with open(path, encoding="utf-8") as f:
            src = f.read()
        fn = L.eval("function(src, name) local f, err = loadstring(src, name); if not f then error(err) end; return f end")(src, "@Sim/" + name + ".lua")
        fn("DisasterZone", ns)
    return L, ns


def run(sc, iterations=None, log=False, start=1, gamedb=False):
    L, ns = load_engine(gamedb=gamedb)
    S = ns.GearSim
    db = build_db(sc["gear"])
    sp = SPECS[sc.get("spec", "ret")]
    with open(os.path.join(WOWSIMS, sp["apl"]), encoding="utf-8") as f:
        apl = json.load(f)
    if sc.get("aplVariables"):
        for v in apl["valueVariables"]:
            if v["name"] in sc["aplVariables"]:
                v["value"] = {"const": {"val": str(sc["aplVariables"][v["name"]])}}
    lsc = dict(sc)
    lsc["gear"] = {i + 1: g for i, g in enumerate(sc["gear"]) if g and g.get("id")}
    lsc["class"] = sp["class"]
    if sp.get("luaOptions") and "classOptions" not in lsc:
        lsc["classOptions"] = sp["luaOptions"]
    if lsc.get("buffs", "wowsims_default") == "wowsims_default":
        lsc["buffs"] = sp["luaBuffs"]
    if lsc.get("consumables") == "wowsims_default":
        lsc.pop("consumables")
    sim, p, target = S.NewScenario(to_lua(L, lsc), S.GameDB() if gamedb else to_lua(L, db), to_lua(L, apl))
    if log:
        lines = []
        sim.log = L.eval("function(cb) return function(sim, s) cb(sim.now, s) end end")(lambda t, s: lines.append("[%.3f] %s" % (t, s)))
    n = iterations or sc.get("iterations", 1000)
    t0 = time.time()
    res = S.RunScenario(sim, p, n, start)
    el = time.time() - t0
    out = to_py(res)
    out["seconds"] = el
    out["stats"] = {to_py(S.STAT_NAMES)[i]: p.stats[i + 1] for i in range(len(to_py(S.STAT_NAMES)))}
    return out


KEYMAP = {  # our metrics keys -> WoWSims action names
    "melee": "OtherActionAttack:1", "melee_oh": "OtherActionAttack:2", "melee_12281": "OtherActionAttack:12281",
    "bloodlust": "spell:2825:-1", "drums": "spell:35476:-1", "flame_cap": "item:22788", 31893: "spell:31893", 35395: "spell:35395", "soc_proc": "spell:20424",
    "windfury": "OtherActionAttack:25584", 31898: "spell:31898", "item:23827": "item:23827", "item:10646": "item:10646",
    "item:23737": "item:23737", "judge_soc": "spell:20467",
    "pet_fire_elemental_melee": "pet:OtherActionAttack:1", "pet_fire_elemental_13339": "pet:spell:13339",
    "pet_fire_elemental_12470": "pet:spell:12470", "pet_fire_elemental_13376": "pet:spell:13376",
    "windfury_totem": "OtherActionAttack:25584", "drums_own": "spell:35476",
}



def map_key(k):
    if k in KEYMAP:
        return KEYMAP[k]
    if isinstance(k, int):
        return "spell:%d" % k
    if isinstance(k, str) and re.match(r"^\d+:-?\d+$", k):
        return "spell:" + k
    return k


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--iterations", type=int)
    ap.add_argument("--log", action="store_true")
    ap.add_argument("--gamedb", action="store_true", help="use the addon's generated data (Data/SimItems.lua, Data/Gems.lua)")
    a = ap.parse_args()
    with open(a.scenario, encoding="utf-8") as f:
        sc = json.load(f)
    r = run(sc, a.iterations, a.log, gamedb=a.gamedb)
    ref = None
    refp = a.scenario.replace(".json", ".ref.json")
    if os.path.exists(refp):
        with open(refp, encoding="utf-8") as f:
            ref = json.load(f)
    print("Lua  DPS %.2f  (stdev %.1f, %d it, stderr %.2f, %.1fs = %.2f ms/it)" % (
        r["dps"], r["stdev"], r["iterations"], r["stderr"], r["seconds"], r["seconds"] / r["iterations"] * 1000))
    if ref:
        d = r["dps"] - ref["dps"]
        print("Ref  DPS %.2f  -> diff %+.2f (%+.2f%%)" % (ref["dps"], d, d / ref["dps"] * 100))
    for k, m in sorted(r["abilities"].items(), key=lambda kv: -kv[1]["dps"]):
        if m["dps"] <= 0 and m["casts"] <= 0:
            continue
        line = "  %-22s %8.2f dps  casts %7.2f  hits %7.2f  crits %6.2f" % (k, m["dps"], m["casts"], m["hits"], m["crits"])
        rk = map_key(k)
        if ref and rk in ref["actions"]:
            rm = ref["actions"][rk]
            line += "   | ref %8.2f dps casts %7.2f" % (rm["dps"], rm["casts"])
        print(line)
    if ref:
        print()
        print("  outcomes per fight (lua | ref):  hits  crits  glances  misses  dodges  partials")
        for k, m in sorted(r["abilities"].items(), key=lambda kv: -kv[1]["dps"]):
            rk = map_key(k)
            e = ref["actions"].get(rk, {}).get("enemy")
            if not e or m["dps"] <= 0:
                continue
            print("  %-12s %6.2f|%6.2f %6.2f|%6.2f %6.2f|%6.2f %5.2f|%5.2f %5.2f|%5.2f %5.2f|%5.2f  dmg/landed %7.1f|%7.1f" % (
                k, m["hits"], e["hits"], m["crits"], e["crits"], m["glances"], e["glances"], m["misses"], e["misses"],
                m["dodges"], e["dodges"], m["partials"], e["resistedHits"] + e["resistedCrits"],
                m["dps"] * 180 / max(1e-9, m["hits"] + m["crits"] + m["glances"]),
                e["damage"] * 180 / max(1e-9, e["hits"] + e["crits"] + e["glances"])))
    print("mana gains:", {k: round(v) for k, v in r["mana"].items()})
    st = r["stats"]
    print("stats: Str %.0f Agi %.0f AP %.1f crit %.2f%% hit %.2f%% exp %.1f haste %.0f mana %.0f int %.0f mp5 %.0f" % (
        st["Strength"], st["Agility"], st["AttackPower"], st["PhysicalCritPercent"], st["PhysicalHitPercent"],
        st["ExpertiseRating"], st["MeleeHasteRating"], st["Mana"], st["Intellect"], st["MP5"]))


if __name__ == "__main__":
    sys.exit(main())
