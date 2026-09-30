"""ADDENDUM K: the starter strategies (Data/StarterStrategies.lua), on the real addon.

Covers: every starter passes the strategy validation once resolved, every "@Creature" portrait and map name resolves,
every link / token / target cell points at an existing cell, and an author loads one from Raids > Strategies
(Starter button, authors only) as an unsaved draft that Save shares with the guild.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_starters.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, strategies  # noqa: E402
from _common import case, run_all  # noqa: E402

P = "ns.RaidsUI:GetPanel()"
W = "_G.CDLootStrategyBoard"


@case
def every_starter_is_valid_and_resolved():
    w, c = world()
    bob = c["Bob"]
    refs = bob.eval_py("local out = {}; for ref in pairs(ns.Data.StarterStrategies) do out[#out + 1] = ref end; "
                       "table.sort(out); return out")
    assert refs == ["BlackTemple:Council", "GruulsLair:Gruul", "GruulsLair:Maulgar"], refs
    for ref in refs:
        res = bob.eval_py("""
            local ref = ...
            local d = ns.StrategyBoard:StarterDraft(ref)
            d.n = d.n or 'x'
            local clean, err = ns.Strategy:Validate(d)
            local out = { ok = clean ~= nil, err = err, problems = {} }
            if not clean then return out end
            local function bad(msg) out.problems[#out.problems + 1] = msg end
            -- every icon a portrait / key that resolved (the loader falls back to rt8 for unknown names)
            local src = ns.Data.StarterStrategies[ref]
            local function check(srcKey, key, where)
                if type(srcKey) == 'string' and srcKey:find('^@') and not (key or ''):find('^boss:') then
                    bad(where .. ': ' .. srcKey .. ' unresolved')
                end
            end
            local slots = {}
            for _, s in ipairs(ns.Strategy:GetSlots(clean)) do slots[s.ref] = true end
            local blocks = {}
            for _, p in ipairs(clean.p) do for _, k in ipairs(p.k) do blocks[k.id] = k end end
            local function refOk(r)
                local b, row, col = ns.StrategyMapUI.ParseRef(r)
                local k = b and blocks[b]
                if not k then return false end
                if row and row > k.r then return false end
                if col and not k.c[col] then return false end
                if row and col then return slots[r] == true end
                return true
            end
            for pi, p in ipairs(clean.p) do
                if p.m == 0 then bad('page ' .. pi .. ' has no map') end
                for ei, e in ipairs(p.e) do
                    check(src.p[pi].e[ei].i, e.i, 'element ' .. ei)
                    if e.ln and not refOk(e.ln) then bad('element ' .. ei .. ' links to ' .. e.ln) end
                    if e.r and not slots[e.r] then bad('token ' .. ei .. ' shows ' .. e.r) end
                end
                for ki, k in ipairs(p.k) do
                    for row, cells in pairs(k.d or {}) do
                        for col, v in pairs(cells) do
                            if type(v) == 'table' then
                                check(src.p[pi].k[ki].d[row][col].i, v.i, k.id .. ' cell')
                                if v.s and not slots[v.s] then bad(k.id .. ' target shows ' .. v.s) end
                            end
                        end
                    end
                end
            end
            out.slots = #ns.Strategy:GetSlots(clean)
            return out
        """, ref)
        assert res["ok"] is True, (ref, res)
        assert res.get("problems") in (None, [], {}), (ref, res["problems"])
        assert res["slots"] >= 10, (ref, res)
    w.assert_no_errors()


@case
def author_loads_a_starter_and_saves_it():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    for x, author in ((rita, False), (bob, True)):
        x.slash("/cdl raids")
        w.tick(0.5)
        x.eval("ns.RaidsUI:SetView('strategies'); ns.StrategiesUI:SelectBoss('GruulsLair:Maulgar')")
        shown = x.eval("local b = %s.strategies.detail.starterBtn; return b:IsShown() and b:IsVisible()" % P)
        assert shown is author, (x, shown)
    # a boss without a starter: no button
    bob.eval("ns.StrategiesUI:SelectBoss('BlackTemple:Illidan')")
    assert bob.eval("return %s.strategies.detail.starterBtn:IsShown()" % P) is False
    bob.eval("ns.StrategiesUI:SelectBoss('GruulsLair:Maulgar')")
    bob.click(bob.eval("return %s.strategies.detail.starterBtn" % P))
    w.tick(0.2)
    st = bob.eval_py("local s = ns.StrategyBoard:GetState(); return { mode = s.mode, dirty = s.dirty, n = s.strat.n, "
                     "m = s.strat.p[1].m, e = #s.strat.p[1].e, k = #s.strat.p[1].k }")
    assert st["mode"] == "edit" and st["dirty"] and st["n"] == "25 standard" and st["k"] == 8, st
    assert bob.eval("return ns.StrategyMapUI:MapName(...)", st["m"]) == "Gruul's Lair"
    # the board shows the ogres' portraits with their raid marks
    marks = bob.eval_py("local out = {}; for _, o in ipairs(%s.canvas.pools.icon) do if o.badge and o.badge:IsShown() "
                        "then out[#out + 1] = o.badge:GetTexture():sub(-1) end end; table.sort(out); return out" % W)
    assert marks == ["4", "5", "6", "7", "8"], marks
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(2)
    ss = strategies(rita, "GruulsLair:Maulgar")
    assert len(ss) == 1 and ss[0]["n"] == "25 standard" and len(ss[0]["p"][0]["k"]) == 8, ss
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
