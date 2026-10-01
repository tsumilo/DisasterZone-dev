"""ADDENDUM K: the starter strategies (Data/StarterStrategies.lua), on the real addon.

Covers: every encounter with a floor map has a starter; every starter passes the strategy validation once resolved,
sits on a map of its own raid and shows each of its creatures by portrait (every "@Creature" resolves); New strategy
opens the boss' starter as an unsaved draft under the name typed, and Save shares it with the guild; a boss without a
starter (a world boss) gets a blank page.

Run: luaenv\Scripts\python.exe tests\strategy\test_strategy_starters.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, strategies  # noqa: E402
from _common import case, run_all  # noqa: E402

P = "ns.RaidsUI:GetPanel()"
W = "_G.DisasterZoneStrategyBoard"


@case
def every_encounter_has_a_valid_starter():
    w, c = world()
    bob = c["Bob"]
    res = bob.eval_py("""
        local out = { missing = {}, problems = {}, n = 0 }
        local function bad(msg) out.problems[#out.problems + 1] = msg end
        local raidOf = {}
        for _, m in ipairs(ns.Data.RaidMaps) do raidOf[m.id] = m.raid end
        for _, raid in ipairs(ns.Strategy:GetRaidTree()) do
            for _, b in ipairs(raid.bosses) do
                local src = ns.Data.StarterStrategies[b.ref]
                if not src then
                    if raid.key ~= 'WorldBosses' then out.missing[#out.missing + 1] = b.ref end
                else
                    out.n = out.n + 1
                    local d = ns.StrategyBoard:StarterDraft(b.ref)
                    d.n = 'x'
                    local clean, err = ns.Strategy:Validate(d)
                    if not clean then bad(b.ref .. ': ' .. tostring(err)) else
                        local p = clean.p[1]
                        if #clean.p ~= 1 or #p.k ~= 0 then bad(b.ref .. ': more than one page / blocks') end
                        if raidOf[p.m] ~= raid.key then bad(b.ref .. ': map ' .. tostring(p.m)) end
                        if not (p.vz and p.vz > 100) then bad(b.ref .. ': not framed on the room') end
                        if #p.e == 0 then bad(b.ref .. ': no creature') end
                        for _, e in ipairs(p.e) do
                            if e.t ~= 'i' or not (e.i or ''):find('^boss:') then bad(b.ref .. ': ' .. tostring(e.l)) end
                        end
                    end
                end
            end
        end
        return out
    """)
    assert res["missing"] in ([], {}), res["missing"]
    assert res["problems"] in ([], {}), res["problems"]
    assert res["n"] == 55, res["n"]
    w.assert_no_errors()


def new_strategy(cl, boss, name):
    cl.slash("/dz raids")
    cl.eval("ns.RaidsUI:SetView('strategies'); ns.StrategiesUI:SelectBoss(...)", boss)
    cl.click(cl.eval("return %s.strategies.detail.newBtn" % P))
    cl.type_text(cl.eval("return _G.DisasterZoneStrategyPrompt.edit"), name, enter=True)


@case
def new_strategy_starts_from_the_starter():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    w.tick(0.5)
    new_strategy(bob, "GruulsLair:Maulgar", "25 farm")
    w.tick(0.2)
    st = bob.eval_py("local s = ns.StrategyBoard:GetState(); local p = s.strat.p[1]; return { mode = s.mode, "
                     "dirty = s.dirty, n = s.strat.n, m = p.m, vz = p.vz, e = #p.e, k = #p.k, i = p.e[1].i }")
    assert st["mode"] == "edit" and st["dirty"] and st["n"] == "25 farm" and st["e"] == 5 and st["k"] == 0, st
    assert st["vz"] == 300 and st["i"] == "boss:18649", st
    assert bob.eval("return ns.StrategyMapUI:MapName(...)", st["m"]) == "Gruul's Lair"
    # the board shows the five ogres' portraits
    n = bob.eval("local n = 0; for _, o in ipairs(%s.canvas.pools.icon) do if o.holder:IsShown() then n = n + 1 end end; "
                 "return n" % W)
    assert n == 5, n
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(2)
    ss = strategies(rita, "GruulsLair:Maulgar")
    assert len(ss) == 1 and ss[0]["n"] == "25 farm" and len(ss[0]["p"][0]["e"]) == 5, ss
    w.assert_no_errors()


@case
def a_boss_without_a_starter_gets_a_blank_page():
    w, c = world()
    bob = c["Bob"]
    w.tick(0.5)
    bob.eval("ns.StrategyBoard:NewStrategy('WorldBosses:Kazzak', 'x')")
    st = bob.eval_py("local p = ns.StrategyBoard:GetState().strat.p[1]; return { e = #p.e, vz = p.vz or 0 }")
    assert st == {"e": 0, "vz": 0}, st
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
