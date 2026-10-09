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
def picker_is_my_bis_picker_for_the_working_set():
    w, c = solo()
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    sid = sid_of(c, 13)
    bis_before = c.eval_py("return { ns.BiS:GetSlot(1, ...) }", sid)
    c.eval("ns.SimPanel:OnSlotClick(..., 'main', 'LeftButton')", sid)
    settle(w, 0.2)
    # My BiS's own picker, borrowed by the Working set
    assert c.eval("return ns.Picker:IsOpen() and ns.SimPanel:IsPickerOpen()") is True
    assert "Working set" in c.eval("return DisasterZonePicker.titleText:GetText()")
    ids = c.eval_py("return ns.Picker:VisibleItems()")
    # equipped (both trinkets) and the bag item first, then the sources
    assert ids[:3] == [29383, DRAGONSPINE, HOURGLASS], ids[:5]
    assert len(ids) > 10, ids
    # Best for this slot: ranked against the slot's item, best first
    c.eval("ns.SimPanel._runBest()")
    run_until_done(w, c)
    st = c.eval_py("local s = ns.SimPanel._pstate() return { results = s.results, ranked = s.ranked }")
    assert st["results"] and st["results"].get("ref"), st
    assert len(st["ranked"]) >= 4, st
    vals = [st["results"][i] for i in st["ranked"]]
    assert vals == sorted(vals, reverse=True), vals
    assert c.eval_py("return ns.Picker:VisibleItems()")[:len(st["ranked"])] == st["ranked"]
    # a pick changes the Working set, never the BiS list
    c.eval("ns.Picker:PickItem(...)", HOURGLASS)
    w.tick(0.1)
    assert c.eval("return ns.Picker:IsOpen()") is False
    assert c.eval("return ns.SimPanel:Working()[...].id", sid) == HOURGLASS
    assert c.eval_py("return { ns.BiS:GetSlot(1, ...) }", sid) == bis_before
    assert_no_lua_errors(w)


@r.case
def off_hand_waits_for_a_one_hander():
    w, c = solo()
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    oh = sid_of(c, 17)
    assert c.eval("return ns.SimPanel:OffHandBlocked()") is True      # Lionheart Champion is a two-hander
    c.eval("ns.SimPanel:OnSlotClick(..., 'main', 'LeftButton')", oh)
    assert c.eval("return ns.Picker:IsOpen() and true or false") is False
    assert_no_lua_errors(w)


@r.case
def run_keeps_going_with_the_window_closed():
    w, c = solo()
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 40  ns.SimRunner.FRAME_BUDGET_MS = 0")   # a few fights per frame
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    c.eval("ns.SimPanel:Run()")
    w.tick(0.05, 0.05)
    assert c.eval("return ns.SimRunner:IsRunning()") is True
    c.eval("ns.MainFrame:Close()")
    assert c.eval("return ns.MainFrame:IsShown() and true or false") is False
    run_until_done(w, c)
    c.eval('ns.MainFrame:Open("mybis")')
    settle(w, 0.2)
    res = results(c)
    assert res and res["work"] > 1000 and res["stale"] is False, res
    # the card shows them
    assert c.eval("return ns.SimPanel._card().big:GetText()") == c.eval("return ns.SimPanel.Fmt(...)", res["work"])
    assert_no_lua_errors(w)


@r.case
def best_for_slot_during_a_run_stops_it_cleanly():
    w, c = solo()
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 40  ns.SimRunner.FRAME_BUDGET_MS = 0")
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    c.eval("ns.SimPanel:Run()")
    w.tick(0.05, 0.05)
    assert c.eval("return ns.SimPanel._state().running") is True
    c.eval("ns.SimPanel:OnSlotClick(..., 'main', 'LeftButton')", sid_of(c, 13))
    c.eval("ns.SimPanel._runBest()")
    # the card no longer claims a run
    assert c.eval("return ns.SimPanel._state().running") is False
    assert c.eval("return ns.SimPanel._card().run:GetText()") == "Run sim"
    run_until_done(w, c)
    assert c.eval_py("return ns.SimPanel._pstate().ranked") is not None
    assert_no_lua_errors(w)


@r.case
def sim_button_only_for_specs_the_sim_covers():
    w, c = solo()
    btn = "ns.MainFrame:GetPanel('mybis').simBtn"
    assert c.eval("return " + btn + ":IsEnabled()") is True
    # Holy off-spec list: the button greys out
    assert c.eval("return ns.BiS:SetSpec('Holy', 'os')") is True
    c.eval("ns.MyBiS:SetList('os')  ns.MyBiS:Refresh()")
    assert c.eval("return ns.SimRunner:Spec()") == "Holy"
    assert c.eval("return " + btn + ":IsEnabled()") is False
    # back on the Ret list it works; switching to the Holy list while in Sim mode leaves Sim mode
    c.eval("ns.MyBiS:SetList('ms')  ns.MyBiS:Refresh()")
    assert c.eval("return " + btn + ":IsEnabled()") is True
    c.eval("ns.SimPanel:Toggle()")
    assert c.eval("return ns.SimPanel:IsActive()") is True
    c.eval("ns.MyBiS:SetList('os')  ns.MyBiS:Refresh()")
    assert c.eval("return ns.SimPanel:IsActive()") is False
    assert_no_lua_errors(w)


@r.case
def talents_are_yours_only_when_specced_into_it():
    w, c = solo()
    # the mock client is specced Holy (41/20/0): a Ret sim takes the standard Ret build
    assert c.eval("return ns.BiS:DetectSpec()") == "Holy"
    t, own = c.eval_py("return { ns.SimRunner:Talents() }")
    assert own is False and t == c.eval("return ns.SimRunner.DEFAULT_TALENTS['PALADIN:Retribution']"), (t, own)
    # specced Ret: the talents are read from the game (the mock lists no talent ranks, so still the standard build)
    c.set_talents((0, 11, 50))
    assert c.eval("return ns.BiS:DetectSpec()") == "Retribution"
    c.eval("ns.SimRunner.TalentString = function() return '5-05-0523005120033125331051' end")
    t, own = c.eval_py("return { ns.SimRunner:Talents() }")
    assert own is True and t == "5-05-0523005120033125331051", (t, own)
    assert_no_lua_errors(w)


@r.case
def owned_spare_is_compared_set_up():
    w, c = solo()
    stranger = 30055   # Shoulderpads of the Stranger: one red socket
    c.set_bags({(0, 1): stranger})
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    sid = sid_of(c, 3)
    c.eval("local sid = ...  ns.SimPanel:SetWorkingSlot(sid, { id = 29075, enchant = 2986, gems = {} })", sid)
    c.eval("ns.SimPanel:OnSlotClick(..., 'main', 'LeftButton')", sid)
    c.eval("ns.Picker:PickItem(...)", stranger)
    e = c.eval_py("local e = ns.SimPanel:Working()[...] return { id = e.id, enchant = e.enchant, gems = e.gems }", sid)
    assert e["id"] == stranger, e
    assert e["enchant"] == 2986, e            # the slot's shoulder enchant carries over
    assert e["gems"] and e["gems"][0], e      # the empty socket got the guide's gem
    assert_no_lua_errors(w)


@r.case
def wowsims_export_is_valid_settings_json():
    import json
    w, c = solo()
    text = c.eval("return ns.SimRunner:WoWSimsSettings(ns.SimRunner:EquippedSet(), "
                  "{ buffs = 'raid25', duration = 180, mobType = 'Mechanical', talents = '5-053201-0523005120033125331051' })")
    doc = json.loads(text)
    assert doc["apiVersion"] == 15
    pl = doc["player"]
    assert pl["class"] == "ClassPaladin" and pl["race"] == "RaceBloodElf", pl["race"]
    assert len(pl["equipment"]["items"]) == 17 and pl["equipment"]["items"][2]["id"] == 29075
    assert pl["rotation"]["type"] == "TypeAPL" and pl["retributionPaladin"] == {"options": {"classOptions": {}}}
    assert doc["partyBuffs"]["windfuryTotem"] == "TristateEffectImproved"
    assert doc["encounter"]["targets"][0]["mobType"] == "MobTypeMechanical"
    assert '"currentTime":{}' in text          # empty messages stay objects
    c.eval("ns.SimPanel:ShowExport('Working set', ...)", text)
    assert c.eval("return DisasterZoneSimExport:IsShown()") is True
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
