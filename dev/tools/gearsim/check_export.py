"""End-to-end check of Sim mode's WoWSims export: a mock character (dev harness) builds the export the way the game
does (equipped gear, talents, race, buff preset), WoWSims' CLI sims that JSON, and the addon's own sim runs the same
set in the mock. The two should agree (the export is the sim's input, nothing more).

Usage (from dev): luaenv\\Scripts\\python.exe tools\\gearsim\\check_export.py [--iterations N]
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(DEV, "tests", "sync"))

import wowsims_ref  # noqa: E402
from common import Client, new_world, up, settle  # noqa: E402

INV = [1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18]
FURY_P1 = [29021, 29349, 29023, 24259, 29019, 28795, 28824, 28779, 28741, 28608, 28730, 28757, 21670, 28830, 28438,
           28729, 28772]
P1 = {1: 29073, 2: 28745, 3: 29075, 15: 24259, 5: 29071, 9: 28795, 10: 30644, 6: 28779, 7: 30257, 8: 28608,
      11: 28757, 12: 30834, 13: 29383, 14: 28830, 16: 28429, 18: 27484}


def to_request(settings, iterations):
    return {
        "raid": {"parties": [{"players": [settings["player"]], "buffs": settings.get("partyBuffs", {})}],
                 "buffs": settings.get("raidBuffs", {}), "debuffs": settings.get("debuffs", {})},
        "encounter": settings["encounter"],
        "simOptions": {"iterations": iterations, "randomSeed": settings["settings"]["randomSeed"]},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iterations", type=int, default=3000)
    ap.add_argument("--spec", default="ret", choices=["ret", "fury"])
    a = ap.parse_args()
    w = new_world()
    if a.spec == "fury":
        c = Client(w, "Grunt", class_file="WARRIOR", race="Orc", guild_rank=3)
        spec, talents = "Fury", "3400502130201-05050005505012050115"
        gear = {INV[i]: iid for i, iid in enumerate(FURY_P1)}
    else:
        c = Client(w, "Raider", class_file="PALADIN", race="BloodElf", guild_rank=3)
        spec, talents, gear = "Retribution", "5-053201-0523005120033125331051", P1
    up(c)
    settle(w, 5)
    c.eval("ns.BiS:SetSpec(...)", spec)
    c.equip(gear)
    settings_lua = ("{ buffs = 'raid25', duration = 180, mobType = 'Mechanical', seed = 101, talents = '%s' }" % talents)
    text = c.eval("return ns.SimRunner:WoWSimsSettings(ns.SimRunner:EquippedSet(), " + settings_lua + ")")
    settings = json.loads(text)
    out = os.path.join(HERE, "logs", "export_check.json")
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    # WoWSims on the export
    import subprocess
    import tempfile
    req = to_request(settings, a.iterations)
    with tempfile.TemporaryDirectory() as td:
        inp, outp = os.path.join(td, "in.json"), os.path.join(td, "out.json")
        json.dump(req, open(inp, "w"))
        p = subprocess.run([wowsims_ref.CLI, "sim", "--infile", inp, "--outfile", outp], capture_output=True, text=True)
        if p.returncode != 0:
            raise SystemExit(p.stdout + p.stderr)
        res = json.load(open(outp))
    if res.get("error"):
        raise SystemExit(json.dumps(res["error"]))
    ws = res["raidMetrics"]["parties"][0]["players"][0]["dps"]
    # the addon's sim on the same set, in the mock
    lua = c.eval_py("""
      local R = ns.SimRunner
      local S = ns.GearSim
      local n, st = ...
      local sc = R:Scenario(R:EquippedSet(), st)
      local sim, p = S.NewScenario(sc, R:DB(), ns.Data.SimAPL[R:SpecKey()])
      local r = S.RunScenario(sim, p, n)
      return { dps = r.dps, stderr = r.stderr }""", min(a.iterations, 6000),
        c.eval("return " + settings_lua))
    d = lua["dps"] - ws["avg"]
    print("WoWSims (export) %.2f ± %.2f   addon sim %.2f ± %.2f   diff %+.2f (%+.2f%%)" % (
        ws["avg"], ws.get("stdev", 0) / a.iterations ** 0.5, lua["dps"], lua["stderr"], d, d / ws["avg"] * 100))
    print("export written to", out)


if __name__ == "__main__":
    main()
