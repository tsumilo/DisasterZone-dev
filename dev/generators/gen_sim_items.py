"""Generate Data/SimItems.lua for the gear sim (Sim/*.lua) from WoWSims TBC's item database.

Sources (all from the WoWSims checkout in dev/ext/wowsims-tbc, MIT):
  assets/database/db.json                       items: base stats, weapon damage / speed, set, item effects
  sim/common/tbc/stat_bonus_procs_auto_gen.go   trigger settings of generic stat procs (callback, mask, outcome)
  sim/common/tbc/stat_bonus_cds_auto_gen.go     which on-use effects are plain stat actives (+ items_trinkets.go)
Sockets, socket bonuses, gems and enchants are already in Data/Gems.lua (gen_gems.py) and are not repeated.

Format (one string per item, parsed lazily by Sim/Data.lua):
  [itemID] = "type,hand,weaponType,speed,min,max|stats|set|effects"
    stats   "statID:value,..." (WoWSims proto Stat numbers)
    effects "buffId,durationMs,stats(statID:value;...),ppm,icdMs,procChance,useCdMs,categoryId,categoryCdMs[,maxStacks]"
    joined by "/"
  ns.Data.SimProcs[itemID] = "callback,procMask,outcome,flags" (flags: d require damage, w weapon proc,
    p can proc from procs, c class spells only)
  ns.Data.SimOnUse[itemID] = true
Usage: python gen_sim_items.py [--min-ilvl 80]
"""
import argparse
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.normpath(os.path.join(HERE, ".."))
WOWSIMS = os.path.join(DEV, "ext", "wowsims-tbc")
ADDON = os.path.normpath(os.path.join(DEV, "..", "addon", "DisasterZone"))
OUT = os.path.join(ADDON, "Data", "SimItems.lua")

PM = {"ProcMaskEmpty": 2, "ProcMaskMeleeMHAuto": 4, "ProcMaskMeleeOHAuto": 8, "ProcMaskMeleeMHSpecial": 16,
      "ProcMaskMeleeOHSpecial": 32, "ProcMaskRangedAuto": 64, "ProcMaskRangedSpecial": 128, "ProcMaskSpellDamage": 256,
      "ProcMaskSpellHealing": 512, "ProcMaskSpellDamageProc": 1024, "ProcMaskUnknown": 0}
OUTCOME = {"OutcomeEmpty": 0, "OutcomeMiss": 2, "OutcomeHit": 4, "OutcomeDodge": 8, "OutcomeGlance": 16,
           "OutcomeParry": 32, "OutcomeBlock": 64, "OutcomeCrit": 128, "OutcomeLanded": 4 | 128 | 512 | 256 | 16 | 64}
CALLBACK = {"CallbackOnSpellHitDealt": "hit", "CallbackOnSpellHitTaken": "taken", "CallbackOnCastComplete": "cast",
            "CallbackOnPeriodicDamageDealt": "periodic", "CallbackOnApplyEffects": "apply"}


def mask(expr, table):
    v = 0
    for part in expr.split("|"):
        part = part.strip().replace("core.", "")
        v |= table.get(part, 0)
    return v


def go_procs():
    path = os.path.join(WOWSIMS, "sim", "common", "tbc", "stat_bonus_procs_auto_gen.go")
    src = "".join(l for l in open(path, encoding="utf-8") if not l.lstrip().startswith("//"))
    out = {}
    pat = r"shared\.New(?:Stacking)?(?:Proc)?StatBonusEffectWithVariants\(shared\.ProcStatBonusEffect\{(.*?)\},\s*\[\]shared\.ItemVariant\{(.*?)\}\)"
    for m in re.finditer(pat, src, re.S):
        body, variants = m.group(1), m.group(2)
        cb = re.search(r"Callback:\s*([^,\n]+)", body)
        cbs = [CALLBACK.get(c.strip().replace("core.", ""), "") for c in cb.group(1).split("|")] if cb else ["hit"]
        pm = re.search(r"ProcMask:\s*([^,\n]+)", body)
        oc = re.search(r"Outcome:\s*([^,\n]+)", body)
        flags = ""
        for k, f in (("RequireDamageDealt", "d"), ("IsWeaponProc", "w"), ("CanProcFromProcs", "p"), ("ClassSpellsOnly", "c")):
            if re.search(k + r":\s*true", body):
                flags += f
        rec = "%s,%d,%d,%s" % ("+".join(c for c in cbs if c) or "hit", mask(pm.group(1), PM) if pm else 0,
                               mask(oc.group(1), OUTCOME) if oc else 0, flags)
        for vid in re.findall(r"ItemID:\s*(\d+)", variants):
            out[int(vid)] = rec
    return out


def go_onuse():
    ids = set()
    for name in ("stat_bonus_cds_auto_gen.go", "items_trinkets.go"):   # the figurines are in items_trinkets.go
        for line in open(os.path.join(WOWSIMS, "sim", "common", "tbc", name), encoding="utf-8"):
            if line.lstrip().startswith("//"):
                continue
            m = re.search(r"shared\.NewSimpleStatActive\((\d+)\)", line)
            if m:
                ids.add(int(m.group(1)))
    return ids


def fmt_num(v):
    if float(v).is_integer():
        return str(int(v))
    return ("%.4f" % v).rstrip("0").rstrip(".")


def stats_str(d, sep=","):
    return sep.join("%d:%s" % (int(k), fmt_num(v)) for k, v in sorted(((int(k), v) for k, v in d.items())) if v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-ilvl", type=int, default=80)
    a = ap.parse_args()
    db = json.load(open(os.path.join(WOWSIMS, "assets", "database", "db.json"), encoding="utf-8"))
    procs, onuse = go_procs(), go_onuse()
    # items with a hand-written effect in Sim/Items.lua are always in, whatever their item level
    with open(os.path.join(ADDON, "Sim", "Items.lua"), encoding="utf-8") as f:
        handwritten = set(int(x) for x in re.findall(r"IE\[(\d+)\]", f.read()))
    rows = []
    for it in db["items"]:
        so = it.get("scalingOptions", {}).get("0", {})
        if it.get("quality", 0) < 2 or (so.get("ilvl", 0) < a.min_ilvl and it["id"] not in handwritten):
            continue
        if it.get("type", 0) == 0:
            continue
        head = ",".join(fmt_num(x) for x in (it.get("type", 0), it.get("handType", 0), it.get("weaponType", 0),
                                             it.get("weaponSpeed", 0), so.get("weaponDamageMin", 0),
                                             so.get("weaponDamageMax", 0), so.get("randPropPoints", 0)))
        effs = []
        for e in it.get("itemEffects", []):
            eso = (e.get("scalingOptions") or {}).get("0", {})
            proc, use = e.get("proc") or {}, e.get("onUse") or {}
            if not proc and not use:
                continue
            fields = [
                str(e.get("buffId", 0)), fmt_num(e.get("effectDurationMs", 0)), stats_str(eso.get("stats") or {}, ";"),
                fmt_num(proc.get("ppm", 0)), fmt_num(proc.get("icdMs", 0)), fmt_num(proc.get("procChance", 0)),
                fmt_num(use.get("cooldownMs", 0)), fmt_num(use.get("categoryId", 0)), fmt_num(use.get("categoryCooldownMs", 0)),
            ]
            if e.get("maxCumulativeStacks"):
                fields.append(str(e["maxCumulativeStacks"]))
            effs.append(",".join(fields))
        rows.append((it["id"], "%s|%s|%s|%s" % (head, stats_str(so.get("stats") or {}), (it.get("setName") or "").replace("|", "/"),
                                                 "/".join(effs))))
    rows.sort()
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("Data/SimItems.lua", ...) then return end -- DisasterZone gear sim item data.',
        "-- AUTO-GENERATED by gen_sim_items.py - do not edit by hand; re-run the generator instead.",
        "-- Source: WoWSims TBC (github.com/wowsims/tbc-new, MIT): assets/database/db.json and the generated proc / on-use",
        "-- tables in sim/common/tbc. Format: see dev/generators/gen_sim_items.py.",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "ns.Data.SimItems = {",
    ]
    for iid, s in rows:
        lines.append('  [%d] = "%s",' % (iid, s.replace("\\", "\\\\").replace('"', '\\"')))
    lines.append("}")
    lines.append("ns.Data.SimProcs = {")
    for iid in sorted(procs):
        lines.append('  [%d] = "%s",' % (iid, procs[iid]))
    lines.append("}")
    lines.append("ns.Data.SimOnUse = {")
    lines.append("  " + ", ".join("[%d] = true" % i for i in sorted(onuse)))
    lines.append("}")
    # random suffixes ("of the Bandit"): their stat allocation, scaled by an item's randPropPoints / 10000
    lines.append("ns.Data.SimSuffixes = {")
    for r in sorted(db.get("randomSuffixes", []), key=lambda r: r["id"]):
        st = {i: v for i, v in enumerate(r.get("stats") or []) if v}
        if st:
            lines.append('  [%d] = "%s",' % (r["id"], stats_str(st)))
    lines.append("}")
    # consumables (flasks, elixirs, food, potions, runes): "type|stats|buffDuration|cooldown|categoryCooldown|categoryId|
    # effects" (WS stat numbers; durations in seconds; effects "min:spread:resourceType:periodMs:durationMs;...")
    effects = {e["id"]: e for e in db.get("spellEffects", [])}
    lines.append("ns.Data.SimConsumables = {")
    for c in sorted(db.get("consumables", []), key=lambda c: c["id"]):
        st = {i: v for i, v in enumerate(c.get("stats") or []) if v}
        effs = []
        for eid in c.get("effectIds") or []:
            e = effects.get(eid)
            if e and e.get("resourceType"):
                effs.append("%s:%s:%d:%d:%d" % (fmt_num(e.get("minEffectSize", 0)), fmt_num(e.get("effectSpread", 0)),
                                                e["resourceType"], e.get("auraPeriodMs", 0), e.get("durationMs", 0)))
        if st or effs:
            lines.append('  [%d] = "%d|%s|%s|%s|%s|%s|%s",' % (
                c["id"], c.get("type", 0), stats_str(st), fmt_num(c.get("buffDuration", 0)),
                fmt_num(c.get("cooldownDuration", 0)), fmt_num(c.get("categoryCooldownDuration", 0)),
                c.get("categoryId", 0), ";".join(effs)))
    lines.append("}")
    with open(OUT, "wb") as f:
        f.write(("\n".join(lines) + "\n").encode("utf-8"))
    print("%d items, %d procs, %d on-use -> %s (%d KB)" % (len(rows), len(procs), len(onuse), OUT, os.path.getsize(OUT) // 1024))


if __name__ == "__main__":
    main()
