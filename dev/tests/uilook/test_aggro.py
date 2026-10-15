#!/usr/bin/env python
"""Aggro warning on the unit, party and raid frames (UI/LookAggro.lua, 2026-10-15): off by default; a player's
scaled threat on the mobs around lights an outline that slides from yellow to red at the pull; tanks never light;
a non-tank holding aggro is "pulled"; it eases (no jumps) and clears when turned off; made-up members light too.

Run: luaenv\\Scripts\\python.exe tests\\uilook\\test_aggro.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from _common import case, run_all, solo  # noqa: E402


# Threat by unit token: __THR[unit] = { scaled, tanking }; every unit is in combat, "target" a mob I can attack.
THREAT_STUB = """
    _G.__THR = {}
    local R = { UnitExists = UnitExists, UnitCanAttack = UnitCanAttack, UnitIsDead = UnitIsDead }
    UnitAffectingCombat = function(u) return true end
    UnitExists = function(u) if u == 'target' then return true end return R.UnitExists(u) end
    UnitCanAttack = function(a, u) if u == 'target' then return true end return R.UnitCanAttack and R.UnitCanAttack(a, u) end
    UnitIsDead = function(u) if u == 'target' then return false end return R.UnitIsDead and R.UnitIsDead(u) end
    UnitDetailedThreatSituation = function(u, m)
        if m ~= 'target' then return nil end
        local t = __THR[u]
        if not t then return false, 0, 0, 0, 0 end
        return t[2] and true or false, t[2] and 3 or 1, t[1], t[1], 1000
    end
"""


def halo_raid():
    w, c = solo("Alice", class_file="PRIEST", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.look', 'halo')")
    c.relog()
    w.tick(2)
    w.auto_session = False
    w.make_raid([c], extra_members=["Bob", "Carol", "Dave"])
    w.tick(1)
    c.eval(THREAT_STUB)
    # (the mock's group headers make no children: four cells by hand, as the game's InitChild styles them)
    c.eval("""
        __CELLS = {}
        local hd = ns.LookUnits:Header('raid')
        for i = 1, 4 do
            local b = CreateFrame('Button', 'TestAggroCell' .. i, hd, 'SecureUnitButtonTemplate')
            hd:SetAttribute('child' .. i, b)
            hd:InitChild('TestAggroCell' .. i); b:SetAttribute('unit', 'raid' .. i); b:Show()
            ns.LookUnits.Refresh(b)
            if b.face.d and b.face.d.name then __CELLS[b.face.d.name] = b.face end
        end""")
    return w, c


def cell_of(c, name):
    """The raid cell face showing name (as a Lua expression's prelude: defines local F)."""
    return "local F = __CELLS['%s'] " % name


@case
def off_by_default():
    w, c = halo_raid()
    assert c.eval_py("return ns.Look:Opt('group', 'aggro', false)") is False
    assert c.eval_py("return ns.Look:Opt('units', 'aggro', false)") is False
    c.eval(cell_of(c, "Bob") + "__THR[F.d.unit] = { 99 }")
    c.eval("ns.LookAggro.ReadAll()")
    w.tick(0.5)
    lit = c.eval_py("local n = 0 for f in pairs(ns.LookUnits.allFaces) do if f.aggro and f.aggro.goal > 0 then n = n + 1 end end return n")
    assert lit == 0, lit


@case
def ramp_and_colours():
    w, c = solo("Alice")
    g = c.eval_py("local A = ns.LookAggro; return { A.Goal(0.5, false, 0.7), A.Goal(0.7, false, 0.7), "
                  "A.Goal(1, false, 0.7), A.Goal(0.2, true, 0.7) }")
    assert g[0] == 0 and 0 < g[1] < 0.1 and abs(g[2] - 1) < 1e-6 and g[3] > 1, g
    y = c.eval_py("return { ns.LookAggro.ColorAt(0.05) }")
    r = c.eval_py("return { ns.LookAggro.ColorAt(1) }")
    assert y[1] > 0.8 and y[0] > 0.9, y          # yellow: red and green high
    assert r[1] < 0.2 and r[0] > 0.9, r          # red: green gone


@case
def read_threat_tanks_and_pulls():
    w, c = halo_raid()
    units = c.eval_py("local o = {} for i = 1, 4 do local u = 'raid' .. i if UnitExists(u) then o[UnitName(u)] = u end end return o")
    bob, carol, dave = units["Bob"], units["Carol"], units["Dave"]
    c.eval("__THR[...] = { 90 }", bob)
    v = c.eval_py("return { ns.LookAggro.Read(...) }", bob)
    assert abs(v[0] - 0.9) < 1e-6 and v[1] is False, v
    # a main tank never warns, even holding aggro
    c.eval("local t = ...; __THR[t] = { 100, true }; ns.Tanks.NumberOfUnit = function(_, u) if u == t then return 1 end end", carol)
    v = c.eval_py("return { ns.LookAggro.Read(...) }", carol)
    assert v[0] == 0 and v[1] is False, v
    # anyone else holding it has pulled
    c.eval("__THR[...] = { 100, true }", dave)
    v = c.eval_py("return { ns.LookAggro.Read(...) }", dave)
    assert v[1] is True, v
    # out of combat: nothing
    c.eval("UnitAffectingCombat = function() return false end")
    v = c.eval_py("return { ns.LookAggro.Read(...) }", bob)
    assert v[0] == 0, v


@case
def lights_eases_and_clears():
    w, c = halo_raid()
    c.eval("ns.DB:SetSetting('ui.group.aggro', true)")
    c.eval(cell_of(c, "Bob") + "__THR[F.d.unit] = { 95 }")
    c.eval("ns.LookAggro.ReadAll()")
    goal = c.eval_py(cell_of(c, "Bob") + "return F.aggro and F.aggro.goal or 0")
    assert goal > 0.8, goal
    s0 = c.eval_py(cell_of(c, "Bob") + "return F.aggro.s")
    w.tick(0.05)
    s1 = c.eval_py(cell_of(c, "Bob") + "return F.aggro.s")
    assert s0 < s1 < goal, (s0, s1, goal)             # slides, no jump
    w.tick(3)
    s2 = c.eval_py(cell_of(c, "Bob") + "return F.aggro.s")
    assert abs(s2 - goal) < 0.05, (s2, goal)
    # the Halo capsule: its ring shows in the warning's colour
    shown = c.eval_py(cell_of(c, "Bob") + "return F.aggro.ring.l:IsShown()")
    assert shown, "ring hidden"
    # a calm member stays dark
    calm = c.eval_py(cell_of(c, "Carol") + "return F.aggro and F.aggro.goal or 0")
    assert calm == 0, calm
    c.eval("ns.DB:SetSetting('ui.group.aggro', false)")
    off = c.eval_py(cell_of(c, "Bob") + "return { F.aggro.s, F.aggro.ring.l:IsShown() }")
    assert off[0] == 0 and not off[1], off


@case
def square_looks_paint_outline():
    w, c = solo("Alice")
    for look in ("flat", "classic", "gilded"):
        c.eval("ns.DB:SetSetting('ui.group.aggro', true)")
        res = c.eval_py("""
            local f = CreateFrame('Frame', nil, UIParent)
            local F = ns.LookUnits:NewFace(f, 'cell', 'group', 'left')
            F:Apply(ns.Look.BY_KEY[...]); F:Set(ns.LookUnits.Fake('member', 2))
            ns.LookAggro:Set(F, 1.0, false, true)
            local r, g, b, a = F.aggro.line[1]:GetVertexColor()
            return { F.aggro.line[1]:IsShown(), F.aggro.out[1]:IsShown(), r, g, a, F.aggro.pill and true or false }
        """, look)
        assert res[0] and res[1], (look, res)
        assert res[2] > 0.9 and res[3] < 0.2 and res[4] > 0.9, (look, res)
        assert res[5] is False, (look, res)


@case
def made_up_members_light():
    w, c = solo("Alice")
    c.eval("ns.DB:SetSetting('ui.look', 'flat')")
    c.relog()
    w.tick(2)
    c.eval("ns.DB:SetSetting('ui.group.aggro', true); ns.LookUnits:ShowPreview('party', true)")
    c.eval("ns.LookAggro.ReadAll()")
    n = c.eval_py("local n = 0 for f in pairs(ns.LookUnits.allFaces) do if f.aggro and f.aggro.goal > 0 then n = n + 1 end end return n")
    assert n >= 1, n


if __name__ == "__main__":
    run_all(globals())
