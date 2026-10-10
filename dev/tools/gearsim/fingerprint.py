"""Exact-output check for gear sim speed work: runs every scenario for a fixed number of fights and records each
fight's DPS and every ability/mana total to the last bit, plus the time per fight. A speed change must leave the
fingerprint identical.

Usage (from dev/tools/gearsim, with the dev kit's luaenv python):
  python fingerprint.py --save            write logs/fingerprint.json (the reference)
  python fingerprint.py                   compare against it, print ms/fight before -> now
  python fingerprint.py --noskip          run with S.NO_SKIP (the rotation polls every 10 ms, WoWSims' way)
  python fingerprint.py enh_p1 fury_p1    only these scenarios
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_lua  # noqa: E402
from specs import SPECS  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "logs", "fingerprint.json")
# scenario -> fights (enough to cross every proc, cooldown and execute path several times)
SCENARIOS = {
    "ret_p1_default": 200, "ret_p1_human": 100, "ret_p1_hourglass": 100, "ret_p2_default": 100,
    "ret_p3_default": 100, "ret_preraid_default": 100, "fury_p1": 100, "arms_p1": 100, "enh_p1": 60,
    "rogue_p1": 100, "rogue_mutilate": 60, "cat_p1": 60, "ele_p1": 60, "spriest_p1": 60, "balance_p1": 60,
    "arcane_p1": 60, "fire_p1": 60, "frost_p1": 30, "aff_t4": 30, "demo_t4": 30, "destro_t4": 30,
    "hunter_bm_p1": 30, "hunter_sv_p1": 30,
}

DUMP = """function(S, sim, p, n, noskip)
  S.NO_SKIP = noskip or nil
  local t0 = os.clock()
  S.RunScenario(sim, p, n, 1)
  local el = os.clock() - t0
  S.NO_SKIP = nil
  local m = p.metrics
  local out = {}
  local function f(x) return string.format("%.17g", x) end
  for i = 1, m.iterations do out[#out + 1] = "it" .. i .. "=" .. f(m.iterDps[i]) end
  local keys = {}
  for k in pairs(m.byKey) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  for _, ks in ipairs(keys) do
    local a = m.byKey[ks] or m.byKey[tonumber(ks)]
    local fields = {}
    for fk in pairs(a) do if type(a[fk]) == "number" then fields[#fields + 1] = fk end end
    table.sort(fields)
    for _, fk in ipairs(fields) do out[#out + 1] = ks .. "." .. fk .. "=" .. f(a[fk]) end
  end
  local mk = {}
  for k in pairs(m.mana) do mk[#mk + 1] = k end
  table.sort(mk)
  for _, k in ipairs(mk) do out[#out + 1] = "mana." .. k .. "=" .. f(m.mana[k]) end
  return table.concat(out, "\\n"), el
end"""


def setup(name, gamedb=False):
    with open(os.path.join(HERE, "scenarios", name + ".json"), encoding="utf-8") as fh:
        sc = json.load(fh)
    L, ns = run_lua.load_engine(gamedb=gamedb)
    S = ns.GearSim
    sp = SPECS[sc.get("spec", "ret")]
    with open(os.path.join(run_lua.WOWSIMS, sp["apl"]), encoding="utf-8") as fh:
        apl = json.load(fh)
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
    db = S.GameDB() if gamedb else run_lua.to_lua(L, run_lua.build_db(sc["gear"]))
    sim, p, _ = S.NewScenario(run_lua.to_lua(L, lsc), db, run_lua.to_lua(L, apl))
    return L, S, sim, p


def run(name, n, noskip=False):
    L, S, sim, p = setup(name)
    text, el = L.eval(DUMP)(S, sim, p, n, noskip)
    return text, el * 1000 / n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("only", nargs="*")
    ap.add_argument("--save", action="store_true")
    ap.add_argument("--noskip", action="store_true")
    args = ap.parse_args()
    names = args.only or list(SCENARIOS)
    ref = {}
    if os.path.exists(REF):
        with open(REF, encoding="utf-8") as fh:
            ref = json.load(fh)
    bad = 0
    tot_before = tot_now = 0
    for name in names:
        n = SCENARIOS.get(name, 100)
        text, ms = run(name, n, args.noskip)
        r = ref.get(name)
        if args.save:
            ref[name] = {"n": n, "text": text, "ms": ms}
            print("%-22s %4d fights  %7.2f ms/fight  saved" % (name, n, ms))
            continue
        if not r:
            print("%-22s no reference (run --save)" % name)
            continue
        same = r["text"] == text
        tot_before += r["ms"]
        tot_now += ms
        line = "%-22s %7.2f -> %7.2f ms/fight  (x%.2f)  %s" % (name, r["ms"], ms, r["ms"] / ms, "same" if same else "DIFFERENT")
        print(line)
        if not same:
            bad += 1
            a, b = r["text"].split("\n"), text.split("\n")
            shown = 0
            for x, y in zip(a, b):
                if x != y:
                    print("    ref %s\n    now %s" % (x, y))
                    shown += 1
                    if shown >= 4:
                        break
            if len(a) != len(b):
                print("    lines: ref %d, now %d" % (len(a), len(b)))
    if args.save:
        os.makedirs(os.path.dirname(REF), exist_ok=True)
        with open(REF, "w", encoding="utf-8") as fh:
            json.dump(ref, fh, indent=1)
    elif tot_now:
        print("total %.1f -> %.1f ms (x%.2f)%s" % (tot_before, tot_now, tot_before / tot_now,
                                                   "" if not bad else "  %d DIFFERENT" % bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
