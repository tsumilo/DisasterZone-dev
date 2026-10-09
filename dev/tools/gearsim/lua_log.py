"""Write a debug log of one Lua iteration: python lua_log.py scenario.json out.log [iteration]"""
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_lua
sc = json.load(open(sys.argv[1]))
L, ns = run_lua.load_engine()
S = ns.GearSim
db = run_lua.build_db(sc['gear'])
apl = json.load(open(run_lua.WOWSIMS + '/ui/specs/paladin/retribution/apls/default.apl.json'))
lsc = dict(sc); lsc['gear'] = {i+1: g for i, g in enumerate(sc['gear']) if g and g.get('id')}
lsc['buffs'] = 'wowsims_ret'; lsc.pop('consumables', None)
sim, p, t = S.NewScenario(run_lua.to_lua(L, lsc), run_lua.to_lua(L, db), run_lua.to_lua(L, apl))
lines = []
sim.log = L.eval("function(cb) return function(sim, s) cb(sim.now, s) end end")(lambda now, s: lines.append("[%.3f] %s" % (now, s)))
S.RunScenario(sim, p, 1, int(sys.argv[3]) if len(sys.argv) > 3 else 1)
open(sys.argv[2], 'w').write("\n".join(lines))
