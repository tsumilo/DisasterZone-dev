"""Reference runs for the gear sim: feed a scenario to the real WoWSims TBC CLI and read back its numbers.

A scenario is the same JSON the Lua sim takes (dev/tools/gearsim/scenarios/*.json):
  { "spec": "ret", "race": "BloodElf", "talents": "5-053201-...", "gear": [ {id, enchant, gems}, ... 17 slots ],
    "buffs": "wowsims_default" | {raid, party, individual, debuffs}, "consumables": {...} | "wowsims_default",
    "duration": 180, "durationVariation": 0, "mobType": "Mechanical", "iterations": 10000, "seed": 101 }

Usage:
  python wowsims_ref.py scenario.json [--iterations N] [--log] [--json out.json]

Needs the WoWSims checkout + CLI built in dev/ext (see dev/ext/README.txt).
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
EXT = os.path.normpath(os.path.join(HERE, "..", "..", "ext"))
WOWSIMS = os.path.join(EXT, "wowsims-tbc")
CLI = os.path.join(WOWSIMS, "wowsimcli.exe")

from specs import SPECS, RET_BUFFS  # noqa: E402
RET_DEFAULTS = RET_BUFFS

DEFAULT_TARGET = {
    "level": 73, "mobType": "MobTypeMechanical", "swingSpeed": 2, "minBaseDamage": 15113,
    "parryHaste": True, "canCrush": True, "damageSpread": 0.5,
}

def target_stats(armor=7685, ap=320):
    arr = [0.0] * 60  # protojson takes a dense array; indices from proto/common.proto Stat enum
    arr[STAT_INDEX["StatArmor"]] = armor
    arr[STAT_INDEX["StatAttackPower"]] = ap
    return arr


def _stat_index():
    idx, inside = {}, False
    with open(os.path.join(WOWSIMS, "proto", "common.proto"), encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s.startswith("enum Stat {"):
                inside = True
                continue
            if inside:
                if s.startswith("}"):
                    break
                if "=" in s and s.startswith("Stat"):
                    name, num = s.split("=")
                    idx[name.strip()] = int(num.strip().rstrip(";").split()[0])
    return idx


STAT_INDEX = _stat_index()


def build_request(sc, iterations=None, debug=False):
    spec = sc.get("spec", "ret")
    sp = SPECS[spec]
    field, spec_val, cls = sp["field"], sp["options"], sp["wsClass"]
    buffs = sc.get("buffs", "wowsims_default")
    if buffs == "wowsims_default":
        buffs = sp["buffs"]
    cons = sc.get("consumables", "wowsims_default")
    if cons == "wowsims_default":
        cons = sp["buffs"]["consumables"]
    cons = dict(cons)
    # The sim only registers potions / conjured items that are in these lists (consumes.go:163, 369); the
    # WoWSims UI fills them. Only potId / conjuredId are auto-used, so listing the chosen ones is enough.
    if cons.get("potId") and "potions" not in cons:
        cons["potions"] = [cons["potId"]]
    if cons.get("conjuredId") and "conjuredItems" not in cons:
        cons["conjuredItems"] = [cons["conjuredId"]]
    with open(os.path.join(WOWSIMS, sp["apl"]), encoding="utf-8") as f:
        apl = json.load(f)
    if sc.get("aplVariables"):
        for v in apl["valueVariables"]:
            if v["name"] in sc["aplVariables"]:
                v["value"] = {"const": {"val": str(sc["aplVariables"][v["name"]])}}
    player = {
        "name": "Player",
        "race": "Race" + sc.get("race", "BloodElf"),
        "class": cls,
        "equipment": {"items": sc["gear"]},
        "consumables": cons,
        "buffs": buffs.get("individual", {}),
        field: spec_val,
        "talentsString": sc["talents"],
        "profession1": sc.get("profession1", "Engineering"),
        "profession2": sc.get("profession2", "Blacksmithing"),
        "rotation": apl,
        "reactionTimeMs": sc.get("reactionTimeMs", 0),
        "distanceFromTarget": sc.get("distanceFromTarget", 5),
        "inFrontOfTarget": sc.get("inFrontOfTarget", False),
    }
    target = dict(DEFAULT_TARGET)
    target["mobType"] = "MobType" + sc.get("mobType", "Mechanical")
    target["stats"] = target_stats(sc.get("targetArmor", 7685))
    req = {
        "raid": {
            "parties": [{"players": [player], "buffs": buffs.get("party", {})}],
            "buffs": buffs.get("raid", {}),
            "debuffs": buffs.get("debuffs", {}),
        },
        "encounter": {
            "duration": sc.get("duration", 180),
            "durationVariation": sc.get("durationVariation", 0),
            "executeProportion20": sc.get("execute20", 0.2),
            "executeProportion25": 0.25, "executeProportion35": 0.35,
            "executeProportion45": 0.45, "executeProportion90": 0.9,
            "targets": [target],
        },
        "simOptions": {"iterations": iterations or sc.get("iterations", 10000),
                       "randomSeed": sc.get("seed", 101), "debug": debug},
    }
    return req


def action_name(aid):
    if "spellId" in aid:
        return "spell:%d" % aid["spellId"] + (":%d" % aid["tag"] if aid.get("tag") else "")
    if "itemId" in aid:
        return "item:%d" % aid["itemId"] + (":%d" % aid["tag"] if aid.get("tag") else "")
    if "otherId" in aid:
        return aid["otherId"] + (":%d" % aid["tag"] if aid.get("tag") else "")
    return json.dumps(aid)


def run(sc, iterations=None, debug=False):
    req = build_request(sc, iterations, debug)
    with tempfile.TemporaryDirectory() as td:
        inp, out = os.path.join(td, "in.json"), os.path.join(td, "out.json")
        with open(inp, "w", encoding="utf-8") as f:
            json.dump(req, f)
        p = subprocess.run([CLI, "sim", "--infile", inp, "--outfile", out], capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(p.stdout + p.stderr)
        with open(out, encoding="utf-8") as f:
            res = json.load(f)
    if res.get("error"):
        raise RuntimeError(json.dumps(res["error"]))
    pl = res["raidMetrics"]["parties"][0]["players"][0]
    dur = res.get("avgIterationDuration") or sc.get("duration", 180)
    iters = res.get("iterationsDone") or (iterations or sc.get("iterations", 10000))
    actions = {}
    for a in pl.get("actions", []):
        dmg = sum(t.get("damage", 0) for t in a.get("targets", []))
        casts = sum(t.get("casts", 0) for t in a.get("targets", []))
        hits = sum(t.get("hits", 0) + t.get("crits", 0) + t.get("ticks", 0) + t.get("critTicks", 0) for t in a.get("targets", []))
        crits = sum(t.get("crits", 0) + t.get("critTicks", 0) for t in a.get("targets", []))
        tg = [t for t in a.get("targets", []) if t.get("unitIndex", 0) == 0] or a.get("targets", [])
        def tot(k):
            return sum(t.get(k, 0) for t in tg) / iters
        actions[action_name(a["id"])] = {
            "dps": dmg / iters / dur, "casts": casts / iters, "hits": hits / iters, "crits": crits / iters,
            "enemy": {"damage": tot("damage") / dur, "hits": tot("hits"), "crits": tot("crits"), "misses": tot("misses"),
                      "dodges": tot("dodges"), "glances": tot("glances"), "resistedHits": tot("resistedHits"),
                      "resistedCrits": tot("resistedCrits")},
        }
    return {
        "dps": pl["dps"]["avg"], "dpsStdev": pl["dps"].get("stdev", 0), "iterations": iters,
        "actions": actions, "logs": res.get("logs", ""),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--iterations", type=int)
    ap.add_argument("--log", action="store_true", help="debug log of one iteration to stdout")
    ap.add_argument("--json", help="write the result here")
    a = ap.parse_args()
    with open(a.scenario, encoding="utf-8") as f:
        sc = json.load(f)
    r = run(sc, 1 if a.log else a.iterations, debug=a.log)
    if a.log:
        print(r["logs"])
        return
    print("DPS %.2f  (stdev %.1f, %d iterations, stderr %.2f)" % (r["dps"], r["dpsStdev"], r["iterations"],
                                                                   r["dpsStdev"] / max(1, r["iterations"]) ** 0.5))
    for name, m in sorted(r["actions"].items(), key=lambda kv: -kv[1]["dps"]):
        if m["dps"] > 0 or m["casts"] > 0:
            print("  %-22s %8.2f dps  casts %7.2f  hits %7.2f  crits %6.2f" % (name, m["dps"], m["casts"], m["hits"], m["crits"]))
    if a.json:
        r.pop("logs", None)
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(r, f, indent=1)


if __name__ == "__main__":
    sys.exit(main())
