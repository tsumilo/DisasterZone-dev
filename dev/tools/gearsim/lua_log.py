"""Write a debug log of one Lua iteration: python lua_log.py scenario.json out.log [iteration]"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_lua  # noqa: E402
from specs import SPECS  # noqa: E402

sc = json.load(open(sys.argv[1]))
sp = SPECS[sc.get("spec", "ret")]
L, ns = run_lua.load_engine()
S = ns.GearSim
db = run_lua.build_db(sc['gear'])
apl = json.load(open(os.path.join(run_lua.WOWSIMS, sp["apl"]), encoding="utf-8"))
lsc = dict(sc)
lsc['gear'] = {i + 1: g for i, g in enumerate(sc['gear']) if g and g.get('id')}
lsc['class'] = sp["class"]
if "distanceFromTarget" in sc and "distance" not in sc:
    lsc["distance"] = sc["distanceFromTarget"]
if "professions" not in sc:
    lsc["professions"] = [sc.get("profession1", "Engineering"), sc.get("profession2", "Blacksmithing")]
if "channelClipDelay" in sc and "channelClipDelayMs" not in sc:
    lsc["channelClipDelayMs"] = sc["channelClipDelay"]
if sp.get("luaOptions"):
    lsc.setdefault("classOptions", sp["luaOptions"])
lsc['buffs'] = sp["luaBuffs"]
lsc.pop('consumables', None)
sim, p, t = S.NewScenario(run_lua.to_lua(L, lsc), run_lua.to_lua(L, db), run_lua.to_lua(L, apl))
lines = []
sim.log = L.eval("function(cb) return function(sim, s) cb(sim.now, s) end end")(lambda now, s: lines.append("[%.3f] %s" % (now, s)))
S.RunScenario(sim, p, 1, int(sys.argv[3]) if len(sys.argv) > 3 else 1)
open(sys.argv[2], 'w').write("\n".join(lines))
