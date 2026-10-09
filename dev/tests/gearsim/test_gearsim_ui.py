#!/usr/bin/env python
"""Gear sim in My BiS (Sim/*.lua, Sim/Runner.lua, UI/SimPanel.lua), on the real addon.

Covers: the Sim toggle opens the card and the Working set starts as the equipped gear; Run sims Working vs My gear
in time slices and an unchanged set comes out at exactly 0 (same rolls for both); swapping a trinket marks the slot
as changed, makes the result stale and the next run shows a difference; the picker lists the slot's candidates and
"Best for this slot" sims them; reset to My gear; the Working set survives a /reload; no Lua errors on the way.

Run: luaenv\\Scripts\\python.exe tests\\gearsim\\test_gearsim_ui.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "sync"))

from common import Runner, Client, new_world, up, settle, assert_no_lua_errors  # noqa: E402

r = Runner("gear sim (My BiS)")

# WoWSims' P1 Retribution preset, by inventory slot (no gems / enchants on the mock's links)
P1 = {1: 29073, 2: 28745, 3: 29075, 15: 24259, 5: 29071, 9: 28795, 10: 30644, 6: 28779, 7: 30257, 8: 28608,
      11: 28757, 12: 30834, 13: 29383, 14: 28830, 16: 28429, 18: 27484}
TRINKET1_SID = None
HOURGLASS = 28034   # Hourglass of the Unraveller
DRAGONSPINE = 28830


def solo():
    w = new_world()
    c = Client(w, "Raider", class_file="PALADIN", race="BloodElf", guild_rank=3)
    up(c)
    settle(w, 5)
    assert c.eval("return ns.BiS:SetSpec(...)", "Retribution") is True
    c.equip(P1)
    c.set_bags({(0, 1): HOURGLASS})
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 12  ns.SimPanel.PICK_ITERATIONS = 6  ns.SimPanel.MAX_PICK_RUN = 4")
    c.eval('ns.MainFrame:Open("mybis")')
    settle(w, 1)
    return w, c


def sid_of(c, inv):
    return c.eval("for sid, s in ipairs(ns.SLOTS) do if s.invSlot == ... then return sid end end", inv)


def run_until_done(w, c, what="ns.SimRunner:IsRunning()", limit=600):
    for _ in range(limit):
        if not c.eval("return " + what):
            return
        w.tick(0.05, 0.05)
    raise AssertionError("sim never finished")


def results(c):
    return c.eval_py("""
      local s = ns.SimPanel and ns.SimPanel._state and ns.SimPanel._state()
      local res = s and s.results
      if not res then return nil end
      return { work = res.work.dps, ref = res.ref.dps, diff = res.diff, se = res.se, stale = s.stale }""")


@r.case
def toggle_shows_card_and_working_is_equipped():
    w, c = solo()
    assert c.eval("return ns.SimPanel:IsActive()") is False
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    settle(w, 0.5)
    assert c.eval("return ns.SimPanel:IsActive()") is True
    for inv, iid in P1.items():
        got = c.eval("local e = ns.SimPanel:Working()[...] return e and e.id", sid_of(c, inv))
        assert got == iid, (inv, iid, got)
    assert c.eval("return ns.SimPanel:Changed() == nil or next(ns.SimPanel:Changed()) == nil") is True
    assert_no_lua_errors(w)


@r.case
def unchanged_set_runs_to_zero_difference():
    w, c = solo()
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    res = results(c)
    assert res, "no results"
    assert 1200 < res["work"] < 2600, res
    assert res["work"] == res["ref"] and res["diff"] == 0, res
    assert_no_lua_errors(w)


@r.case
def trinket_swap_marks_changed_and_shows_difference():
    w, c = solo()
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    sid = sid_of(c, 14)
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    c.eval("local sid, id = ... ns.SimPanel:SetWorkingSlot(sid, ns.SimRunner:FillEntry(id, sid))  ns.MyBiS:Refresh()",
           sid, HOURGLASS)
    assert c.eval("return ns.SimPanel:Changed()[...] and true or false", sid) is True
    assert results(c)["stale"] is True
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    res = results(c)
    assert res["stale"] is False and res["diff"] != 0, res
    assert abs(res["work"] - res["ref"] - res["diff"]) < 1e-6, res
    assert_no_lua_errors(w)


@r.case
def picker_lists_and_sims_best_for_slot():
    w, c = solo()
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    sid = sid_of(c, 13)
    c.eval("ns.SimPanel:OnSlotClick(..., 'main', 'LeftButton', nil, UIParent)", sid)
    settle(w, 0.2)
    assert c.eval("return ns.SimPanel:IsPickerOpen()") is True
    ids = c.eval_py("local t = {} for _, r in ipairs(ns.SimPanel:PickerRows()) do t[#t + 1] = r.entry.id end return t")
    assert HOURGLASS in ids and 29383 in ids and DRAGONSPINE in ids, ids
    c.eval("ns.SimPanel._runBest()")
    run_until_done(w, c)
    got = c.eval_py("local s = ns.SimPanel._pstate() return s.results")
    assert got and got.get("ref"), got
    assert sum(1 for k in got if k != "ref") >= 3, got
    assert_no_lua_errors(w)


@r.case
def reset_and_reload_keep_working_set():
    w, c = solo()
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    sid = sid_of(c, 14)
    c.eval("local sid, id = ... ns.SimPanel:SetWorkingSlot(sid, ns.SimRunner:FillEntry(id, sid))", sid, HOURGLASS)
    c.relog()
    settle(w, 3)
    c.eval('ns.MainFrame:Open("mybis")')
    assert c.eval("return ns.SimPanel:Working()[...].id", sid) == HOURGLASS
    c.equip(P1)   # the mock doesn't keep gear over a relog
    c.eval("ns.SimPanel:ResetTo(ns.SimRunner:EquippedSet())")
    assert c.eval("return ns.SimPanel:Working()[...].id", sid) == DRAGONSPINE
    assert_no_lua_errors(w)


if __name__ == "__main__":
    r.run()
