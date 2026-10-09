"""Sampling profile of the Lua gear sim: python profile_lua.py scenario.json [iterations]"""
import json, sys, os, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_lua
sc = json.load(open(sys.argv[1]))
n = int(sys.argv[2]) if len(sys.argv) > 2 else 100
L, ns = run_lua.load_engine(); S = ns.GearSim
db = run_lua.build_db(sc['gear'])
apl = json.load(open(run_lua.WOWSIMS + '/ui/specs/paladin/retribution/apls/default.apl.json'))
lsc = dict(sc); lsc['gear'] = {i+1: g for i, g in enumerate(sc['gear']) if g and g.get('id')}
lsc['buffs'] = 'wowsims_ret'; lsc.pop('consumables', None)
sim, p, t = S.NewScenario(run_lua.to_lua(L, lsc), run_lua.to_lua(L, db), run_lua.to_lua(L, apl))
prof = L.eval("""function(S, sim, p, n)
  local samples, fsamples = {}, {}
  debug.sethook(function()
    local info = debug.getinfo(2, "Sn")
    if info then
      local k = info.short_src .. ":" .. (info.linedefined or 0) .. " " .. tostring(info.name)
      samples[k] = (samples[k] or 0) + 1
    end
    -- inclusive: walk the stack
    local seen = {}
    for lvl = 2, 30 do
      local fi = debug.getinfo(lvl, "Sn")
      if not fi then break end
      local fk = fi.short_src .. ":" .. (fi.linedefined or 0) .. " " .. tostring(fi.name)
      if not seen[fk] then seen[fk] = true; fsamples[fk] = (fsamples[fk] or 0) + 1 end
    end
  end, "", 1000)
  S.RunScenario(sim, p, n, 1)
  debug.sethook()
  return samples, fsamples
end""")
samples, fsamples = prof(S, sim, p, n)
s = sorted(((v, k) for k, v in samples.items()), reverse=True)
tot = sum(v for v, k in s)
print("self (line):")
for v, k in s[:25]:
    print("  %5.1f%%  %s" % (v * 100 / tot, k))
f = sorted(((v, k) for k, v in fsamples.items()), reverse=True)
print("inclusive (function):")
for v, k in f[:30]:
    print("  %5.1f%%  %s" % (v * 100 / tot, k))
