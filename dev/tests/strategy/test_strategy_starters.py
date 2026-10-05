"""ADDENDUM K: the starter strategies (Data/StarterStrategies.lua), on the real addon.

Covers: every encounter with a floor map has a starter; every starter passes the strategy validation once resolved,
sits on a map of its own raid and shows each of its creatures by portrait (every "@Creature" resolves) and its game
objects as "obj:" icons with a model and a definition (Lady Vashj's Shield Generators); New strategy
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
                        if #p.e == 0 or not (p.e[1].i or ''):find('^boss:') then bad(b.ref .. ': no creature') end
                        -- creatures by portrait; the encounter's assets (encounter_assets.py): game objects with a
                        -- model and a definition, creatures with a model or a definition; their zones and arrows
                        local SO = ns.StrategyObjects
                        for _, e in ipairs(p.e) do
                            local kind = SO.Parse(e.i)
                            local ok = e.t == 'z' or e.t == 'a' or (e.t == 'i' and ((e.i or ''):find('^boss:')
                                or (kind == 'obj' and SO.Object(SO.EntryOf(e.i)) and SO.DefOf(e.i))
                                or (kind == 'npc' and (SO.Creature(e.i) or SO.DefOf(e.i)))))
                            if not ok then bad(b.ref .. ': ' .. tostring(e.i or e.t) .. ' ' .. tostring(e.l)) end
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


@case
def every_encounter_asset_has_a_model_or_a_look_and_its_beams_a_target():
    # Data/EncounterSpawns.lua (generated) against Data/EncounterObjects.lua and Data/ModelIndex.lua: every icon key
    # draws something (an object's model file, a creature's display, or a marker's definition), every state's beam
    # aims at an icon key the board can hold, every group lies on its encounter's starter map
    w, c = world()
    bob = c["Bob"]
    res = bob.eval_py("""
        local SO, out = ns.StrategyObjects, { problems = {}, groups = 0, icons = 0 }
        local function bad(msg) out.problems[#out.problems + 1] = msg end
        for ref, sp in pairs(ns.Data.EncounterSpawns) do
            local starter = ns.Data.StarterStrategies[ref]
            if not starter or starter.p[1].map ~= sp.map then bad(ref .. ': not on its starter map') end
            for _, grp in ipairs(sp.groups) do
                out.groups = out.groups + 1
                if #grp.e == 0 then bad(ref .. ' ' .. grp.n .. ': empty') end
                for _, s in ipairs(grp.e) do
                    if s.i then
                        out.icons = out.icons + 1
                        local kind = SO.Parse(s.i)
                        local def = SO.DefOf(s.i)
                        local ok = (kind == 'obj' and SO.Object(SO.EntryOf(s.i)) ~= nil and def ~= nil)
                            or (kind == 'npc' and (SO.Creature(s.i) ~= nil or (def and def.marker)))
                        if not ok then bad(ref .. ' ' .. grp.n .. ': ' .. s.i .. ' draws nothing') end
                        if s.st and not (def and def.states and def.states[s.st]) then bad(s.i .. ': no state ' .. s.st) end
                    end
                    if not (s.mx and s.my and s.mx > -200 and s.mx < 1200 and s.my > -200 and s.my < 1200) then
                        bad(ref .. ' ' .. grp.n .. ': a spot off the map')
                    end
                end
            end
        end
        for name, def in pairs(ns.Data.EncounterObjects.defs) do
            for _, st in ipairs(def.states or {}) do
                local to = st.beam and st.beam.to
                if to then
                    local d = tonumber(to:match('^boss:(%d+)$'))
                    if not ((d and SO.IsDisplay(d)) or SO.Creature(to)) then bad(name .. ': beam to ' .. to) end
                end
            end
        end
        for ref, keys in pairs(ns.Data.EncounterObjects.encounters) do
            for _, key in ipairs(keys) do
                if not SO.DefOf(key) and not SO.Creature(key) then bad(ref .. ': menu ' .. key) end
            end
        end
        return out
    """)
    assert res["problems"] in ([], {}), res["problems"]
    assert res["groups"] >= 60 and res["icons"] >= 100, res
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
