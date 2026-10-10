#!/usr/bin/env python
"""Gear sim in My BiS (Sim/*.lua, Sim/Runner.lua, UI/SimPanel.lua), on the real addon.

Covers: the Sim toggle opens the card and the Working set starts as the equipped gear; Run sims Working vs My gear
in time slices and an unchanged set comes out at exactly 0 (same rolls for both); swapping a trinket marks the slot
as changed, makes the result stale and the next run shows a difference; the picker lists the slot's candidates and
"Best for this slot" sims them; a set simmed before is never simmed again; reset to My gear; the Working set survives a /reload; no Lua errors on the way.

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


def count_fights(c):
    c.eval("""
      local Sim = ns.GearSim.SimMT
      if not Sim._origRunOnce then
        Sim._origRunOnce = Sim.RunOnce
        Sim.RunOnce = function(...) DZ_TEST_FIGHTS = (DZ_TEST_FIGHTS or 0) + 1 return Sim._origRunOnce(...) end
      end
      DZ_TEST_FIGHTS = 0""")


@r.case
def simmed_sets_are_not_simmed_again():
    w, c = solo()
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    n = c.eval("return ns.SimRunner.DEFAULT_ITERATIONS")
    count_fights(c)
    # Working = My gear: one set, simmed once
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    assert c.eval("return DZ_TEST_FIGHTS") == n
    first = results(c)
    # the same run again: nothing to sim, the very same numbers
    count_fights(c)
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    assert c.eval("return DZ_TEST_FIGHTS") == 0
    assert results(c) == first, (results(c), first)
    # one slot changed: only the Working set is simmed; My gear comes from before
    sid = sid_of(c, 14)
    c.eval("local sid, id = ... ns.SimPanel:SetWorkingSlot(sid, ns.SimRunner:FillEntry(id, sid))  ns.MyBiS:Refresh()",
           sid, HOURGLASS)
    count_fights(c)
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    assert c.eval("return DZ_TEST_FIGHTS") == n
    res = results(c)
    assert res["ref"] == first["ref"] and res["diff"] != 0, res
    # the result is the one a fresh sim gives: same seed, same scenario
    c.eval("ns.SimRunner:ClearCache()")
    count_fights(c)
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    assert c.eval("return DZ_TEST_FIGHTS") == 2 * n
    assert results(c) == res, (results(c), res)
    # Best for this slot twice: the second run sims nothing
    c.eval("ns.SimPanel:OnSlotClick(..., 'main', 'LeftButton')", sid)
    settle(w, 0.2)
    c.eval("ns.SimPanel._runBest()")
    run_until_done(w, c)
    ranked = c.eval_py("return ns.SimPanel._pstate().results")
    count_fights(c)
    c.eval("ns.SimPanel._runBest()")
    run_until_done(w, c)
    assert c.eval("return DZ_TEST_FIGHTS") == 0
    assert c.eval_py("return ns.SimPanel._pstate().results") == ranked
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
def gear_sim_page_says_when_the_spec_isnt_covered():
    w, c = solo()
    c.eval("ns.MainFrame:Open('gearsim')")
    settle(w, 0.3)
    assert c.eval("return ns.SimPanel:IsActive()") is True
    run = "return ns.SimPanel._card().run:IsEnabled()"
    assert c.eval(run) is True
    # the Holy off-spec list: the page stays, its card says what the sim covers and Run sim greys out
    assert c.eval("return ns.BiS:SetSpec('Holy', 'os')") is True
    c.eval("ns.MyBiS:SetList('os')  ns.MyBiS:Refresh()")
    assert c.eval("return ns.SimRunner:Spec()") == "Holy"
    assert c.eval("return ns.SimPanel:IsActive()") is True
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "gearsim"
    assert c.eval(run) is False
    assert "covers" in c.eval("return ns.SimPanel._card().note:GetText()")
    # back on the Ret list it runs again
    c.eval("ns.MyBiS:SetList('ms')  ns.MyBiS:Refresh()")
    assert c.eval(run) is True
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


INV = [1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18]   # WoWSims slot order -> inventory slot
FURY_P1 = [29021, 29349, 29023, 24259, 29019, 28795, 28824, 28779, 28741, 28608, 28730, 28757, 21670, 28830, 28438,
           28729, 28772]
ARMS_P1_MH = 28429   # Lionheart Champion (two-hander)


def warrior(spec, gear):
    w = new_world()
    c = Client(w, "Grunt", class_file="WARRIOR", race="Orc", guild_rank=3)
    up(c)
    settle(w, 5)
    assert c.eval("return ns.BiS:SetSpec(...)", spec) is True
    c.equip({INV[i]: iid for i, iid in enumerate(gear) if iid})
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 12")
    c.eval('ns.MainFrame:Open("mybis")')
    settle(w, 1)
    return w, c


@r.case
def fury_and_arms_warriors_sim():
    for spec, gear in (("Fury", FURY_P1), ("Arms", FURY_P1[:14] + [ARMS_P1_MH, 0, 28772])):
        w, c = warrior(spec, gear)
        assert c.eval("return ns.SimRunner:IsSupported()") is True, spec
        c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
        c.eval("ns.SimPanel:Run()")
        run_until_done(w, c)
        res = results(c)
        assert res and 1300 < res["work"] < 2900 and res["diff"] == 0, (spec, res)
        names = c.eval_py("local t = {} for _, a in ipairs(ns.SimRunner:Breakdown(ns.SimPanel._state().results.work)) do "
                          "t[#t + 1] = a.name end return t")
        want = "Bloodthirst" if spec == "Fury" else "Mortal Strike"
        assert want in names and "Melee" in names, (spec, names)
        doc = __import__("json").loads(c.eval("return ns.SimRunner:WoWSimsSettings(ns.SimRunner:EquippedSet(), "
                                              "{ buffs = 'raid25', duration = 180, mobType = 'Mechanical' })"))
        assert doc["player"]["class"] == "ClassWarrior" and "dpsWarrior" in doc["player"], spec
        assert "battleShout" not in doc["partyBuffs"], spec
        assert_no_lua_errors(w)


# WoWSims' P1 Enhancement preset (ui/specs/shaman/enhancement/gear_sets/p1.gear.json), no gems or enchants
ENH_P1 = [29040, 29381, 29043, 24259, 29515, 29517, 29516, 28776, 28741, 28545, 30834, 28757, 28830, 29383, 28308,
          28308, 27815]


# WoWSims' P1 Combat Rogue preset (ui/specs/rogue/dps/gear_sets/p1.gear.json), no gems or enchants
ROGUE_P1 = [29044, 24114, 27797, 28672, 29045, 29246, 27531, 29247, 28741, 28545, 28757, 28649, 28830, 29383, 28295,
            28189, 28772]


@r.case
def combat_rogue_sims():
    w = new_world()
    c = Client(w, "Shanks", class_file="ROGUE", race="Human", guild_rank=3)
    up(c)
    settle(w, 5)
    assert c.eval("return ns.BiS:SetSpec(...)", "Combat") is True
    c.equip({INV[i]: iid for i, iid in enumerate(ROGUE_P1) if iid})
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 8")
    c.eval('ns.MainFrame:Open("mybis")')
    settle(w, 1)
    assert c.eval("return ns.SimRunner:IsSupported()") is True
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    res = results(c)
    assert res and 1200 < res["work"] < 2900 and res["diff"] == 0, res
    names = c.eval_py("local t = {} for _, a in ipairs(ns.SimRunner:Breakdown(ns.SimPanel._state().results.work)) do "
                      "t[#t + 1] = a.name end return t")
    for want in ("Melee", "Off-hand melee", "Sinister Strike", "Deadly Poison", "Sword Specialization"):
        assert want in names, (want, names)
    # poisons stay on whatever the buffs setting
    for key in ("raid10", "solo"):
        cfg = c.eval_py("return ns.SimRunner:BuffConfig(...)", key)
        assert cfg["consumables"].get("ohImbueId") == 27186, (key, cfg["consumables"])
    doc = __import__("json").loads(c.eval("return ns.SimRunner:WoWSimsSettings(ns.SimRunner:EquippedSet(), "
                                          "{ buffs = 'raid25', duration = 180, mobType = 'Mechanical' })"))
    assert doc["player"]["class"] == "ClassRogue" and "rogue" in doc["player"], doc["player"].keys()
    assert doc["player"]["consumables"].get("conjuredId") == 7676, doc["player"]["consumables"]
    assert_no_lua_errors(w)


# WoWSims' P1 Feral preset (ui/specs/druid/feralcat/gear_sets/p1_bis_6p.gear.json), no gems, enchants or suffixes
CAT_P1 = [8345, 29119, 29100, 28672, 29096, 30685, 28506, 30676, 28741, 28545, 28791, 30834, 21670, 29383, 28658, 0, 29390]


@r.case
def feral_cat_sims():
    w = new_world()
    c = Client(w, "Kitty", class_file="DRUID", race="NightElf", guild_rank=3)
    up(c)
    settle(w, 5)
    assert c.eval("return ns.BiS:SetSpec(...)", "Feral (Cat)") is True
    c.equip({INV[i]: iid for i, iid in enumerate(CAT_P1) if iid})
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 6")
    c.eval('ns.MainFrame:Open("mybis")')
    settle(w, 1)
    assert c.eval("return ns.SimRunner:IsSupported()") is True
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    res = results(c)
    assert res and 1200 < res["work"] < 3200 and res["diff"] == 0, res
    names = c.eval_py("local t = {} for _, a in ipairs(ns.SimRunner:Breakdown(ns.SimPanel._state().results.work)) do "
                      "t[#t + 1] = a.name end return t")
    for want in ("Melee", "Shred", "Rip", "Mangle"):
        assert want in names, (want, names)
    sc = c.eval_py("return ns.SimRunner:Scenario(ns.SimRunner:EquippedSet(), { buffs = 'raid25', duration = 180 })")
    assert sc["reactionTimeMs"] == 250 and sc["classOptions"]["form"] == "Cat", (sc["reactionTimeMs"], sc["classOptions"])
    doc = __import__("json").loads(c.eval("return ns.SimRunner:WoWSimsSettings(ns.SimRunner:EquippedSet(), "
                                          "{ buffs = 'raid25', duration = 180, mobType = 'Mechanical' })"))
    assert doc["player"]["class"] == "ClassDruid" and "feralCatDruid" in doc["player"], doc["player"].keys()
    assert_no_lua_errors(w)


# WoWSims' P1 Elemental preset (ui/specs/shaman/elemental/gear_sets/p1.gear.json), no gems or enchants
ELE_P1 = [29035, 28762, 29037, 28797, 29519, 29521, 28780, 29520, 30734, 28517, 30667, 28753, 29370, 28785, 28770, 29268,
          28248]


@r.case
def elemental_shaman_sims():
    w = new_world()
    c = Client(w, "Sparks", class_file="SHAMAN", race="Draenei", guild_rank=3)
    up(c)
    settle(w, 5)
    assert c.eval("return ns.BiS:SetSpec(...)", "Elemental") is True
    c.equip({INV[i]: iid for i, iid in enumerate(ELE_P1) if iid})
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 6")
    c.eval('ns.MainFrame:Open("mybis")')
    settle(w, 1)
    assert c.eval("return ns.SimRunner:IsSupported()") is True
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    res = results(c)
    assert res and 1000 < res["work"] < 2600 and res["diff"] == 0, res
    names = c.eval_py("local t = {} for _, a in ipairs(ns.SimRunner:Breakdown(ns.SimPanel._state().results.work)) do "
                      "t[#t + 1] = a.name end return t")
    for want in ("Lightning Bolt", "Chain Lightning", "Lightning Capacitor"):
        assert want in names, (want, names)
    assert "Melee" not in names, names
    sc = c.eval_py("return ns.SimRunner:Scenario(ns.SimRunner:EquippedSet(), { buffs = 'raid25', duration = 180 })")
    assert sc["distance"] == 20 and sc["classOptions"]["elemental"] is True, (sc["distance"], sc["classOptions"])
    # his own totems: the group's Totem of Wrath / Wrath of Air go
    for key in ("raid25", "raid10"):
        party = c.eval_py("return ns.SimRunner:BuffConfig(...)", key).get("party") or {}
        assert not party.get("totemOfWrath") and not party.get("wrathOfAirTotem"), (key, party)
    doc = __import__("json").loads(c.eval("return ns.SimRunner:WoWSimsSettings(ns.SimRunner:EquippedSet(), "
                                          "{ buffs = 'raid25', duration = 180, mobType = 'Mechanical' })"))
    assert doc["player"]["class"] == "ClassShaman" and "elementalShaman" in doc["player"], doc["player"].keys()
    assert doc["player"]["distanceFromTarget"] == 20
    assert_no_lua_errors(w)


# WoWSims' P1 Shadow Priest preset (ui/specs/priest/dps/gear_sets/p1.gear.json), no gems or enchants
SPRIEST_P1 = [24266, 30666, 21869, 28570, 21871, 24250, 28507, 28799, 24262, 21870, 29352, 28793, 27683, 29370, 28770,
              29272, 29350]


@r.case
def shadow_priest_sims():
    w = new_world()
    c = Client(w, "Flayer", class_file="PRIEST", race="Troll", guild_rank=3)
    up(c)
    settle(w, 5)
    assert c.eval("return ns.BiS:SetSpec(...)", "Shadow") is True
    c.equip({INV[i]: iid for i, iid in enumerate(SPRIEST_P1) if iid})
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 6")
    c.eval('ns.MainFrame:Open("mybis")')
    settle(w, 1)
    assert c.eval("return ns.SimRunner:IsSupported()") is True
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    res = results(c)
    assert res and 900 < res["work"] < 2400 and res["diff"] == 0, res
    names = c.eval_py("local t = {} for _, a in ipairs(ns.SimRunner:Breakdown(ns.SimPanel._state().results.work)) do "
                      "t[#t + 1] = a.name end return t")
    for want in ("Mind Flay", "Mind Blast", "Shadow Word: Pain", "Vampiric Touch", "Shadow Word: Death"):
        assert want in names, (want, names)
    sc = c.eval_py("return ns.SimRunner:Scenario(ns.SimRunner:EquippedSet(), { buffs = 'raid25', duration = 180 })")
    assert sc["distance"] == 20 and sc["channelClipDelayMs"] == 100, (sc["distance"], sc["channelClipDelayMs"])
    # his own Vampiric Touch: no other shadow priest's mana, whatever the setting
    for key in ("raid25", "raid10"):
        ind = c.eval_py("return ns.SimRunner:BuffConfig(...)", key).get("individual") or {}
        assert not ind.get("shadowPriestDps"), (key, ind)
    doc = __import__("json").loads(c.eval("return ns.SimRunner:WoWSimsSettings(ns.SimRunner:EquippedSet(), "
                                          "{ buffs = 'raid25', duration = 180, mobType = 'Mechanical' })"))
    pl = doc["player"]
    assert pl["class"] == "ClassPriest" and pl["dpsPriest"]["options"]["classOptions"]["preShadowform"] is True, pl.keys()
    assert pl["channelClipDelayMs"] == 100 and pl["distanceFromTarget"] == 20
    assert_no_lua_errors(w)


# WoWSims' P1 Balance preset (ui/specs/druid/balance/gear_sets/p1_a.gear.json), no gems or enchants
BALANCE_P1 = [29093, 28762, 29095, 28766, 21848, 24250, 21847, 21846, 24262, 28517, 28753, 29287, 29370, 27683, 28770,
              29271, 27518]


@r.case
def balance_druid_sims():
    w = new_world()
    c = Client(w, "Boomkin", class_file="DRUID", race="NightElf", guild_rank=3)
    up(c)
    settle(w, 5)
    assert c.eval("return ns.BiS:SetSpec(...)", "Balance") is True
    c.equip({INV[i]: iid for i, iid in enumerate(BALANCE_P1) if iid})
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 6")
    c.eval('ns.MainFrame:Open("mybis")')
    settle(w, 1)
    assert c.eval("return ns.SimRunner:IsSupported()") is True
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    res = results(c)
    assert res and 900 < res["work"] < 2400 and res["diff"] == 0, res
    names = c.eval_py("local t = {} for _, a in ipairs(ns.SimRunner:Breakdown(ns.SimPanel._state().results.work)) do "
                      "t[#t + 1] = a.name end return t")
    for want in ("Starfire", "Moonfire", "Treants"):
        assert want in names, (want, names)
    assert "Melee" not in names, names
    sc = c.eval_py("return ns.SimRunner:Scenario(ns.SimRunner:EquippedSet(), { buffs = 'raid25', duration = 180 })")
    assert sc["distance"] == 20 and sc["classOptions"]["form"] == "Moonkin", (sc["distance"], sc["classOptions"])
    doc = __import__("json").loads(c.eval("return ns.SimRunner:WoWSimsSettings(ns.SimRunner:EquippedSet(), "
                                          "{ buffs = 'raid25', duration = 180, mobType = 'Mechanical' })"))
    assert doc["player"]["class"] == "ClassDruid" and "balanceDruid" in doc["player"], doc["player"].keys()
    assert_no_lua_errors(w)


@r.case
def enhancement_shaman_sims():
    w = new_world()
    c = Client(w, "Totemz", class_file="SHAMAN", race="Orc", guild_rank=3)
    up(c)
    settle(w, 5)
    assert c.eval("return ns.BiS:SetSpec(...)", "Enhancement") is True
    c.equip({INV[i]: iid for i, iid in enumerate(ENH_P1) if iid})
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 8")
    c.eval('ns.MainFrame:Open("mybis")')
    settle(w, 1)
    assert c.eval("return ns.SimRunner:IsSupported()") is True
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    res = results(c)
    assert res and 1300 < res["work"] < 2900 and res["diff"] == 0, res
    names = c.eval_py("local t = {} for _, a in ipairs(ns.SimRunner:Breakdown(ns.SimPanel._state().results.work)) do "
                      "t[#t + 1] = a.name end return t")
    for want in ("Melee", "Windfury Weapon", "Stormstrike", "Fire Elemental"):
        assert want in names, (want, names)
    # the shaman's own totems replace the group's
    cfg = c.eval_py("return ns.SimRunner:BuffConfig('raid10')")
    assert "windfuryTotem" not in cfg["party"] and "strengthOfEarthTotem" not in cfg["party"], cfg["party"]
    doc = __import__("json").loads(c.eval("return ns.SimRunner:WoWSimsSettings(ns.SimRunner:EquippedSet(), "
                                          "{ buffs = 'raid25', duration = 180, mobType = 'Mechanical' })"))
    assert doc["player"]["class"] == "ClassShaman" and "enhancementShaman" in doc["player"], doc["player"].keys()
    assert doc["player"]["consumables"].get("drumsId") == "LesserDrumsOfBattle", doc["player"]["consumables"]
    assert_no_lua_errors(w)


@r.case
def swapped_item_keeps_the_meta_gem_on():
    w, c = solo()
    c.eval("ns.SimPanel:Toggle()  ns.MyBiS:Refresh()")
    head, sh, chest = sid_of(c, 1), sid_of(c, 3), sid_of(c, 5)
    # Relentless Earthstorm: 2 red, 2 yellow, 2 blue. Exactly met; Justicar's orange is a needed yellow.
    c.eval("""local h, s, ch = ...
      ns.SimPanel:SetWorkingSlot(h, { id = 29073, enchant = 0, gems = { 32409, 24054 } })
      ns.SimPanel:SetWorkingSlot(s, { id = 29075, enchant = 2986, gems = { 24058, 24027 } })
      ns.SimPanel:SetWorkingSlot(ch, { id = 29071, enchant = 0, gems = { 24058, 24054, 24027 } })""", head, sh, chest)
    assert c.eval("return ns.SimRunner:MetaActive(ns.SimPanel:Working())") is True
    # the Stranger has one red socket: a plain red gem there would switch the meta off
    c.eval("local s = ... ns.SimPanel:OnSlotReceiveItem(s, 30055)", sh)
    assert c.eval("return ns.SimPanel:Working()[...].id", sh) == 30055
    assert c.eval("return ns.SimRunner:MetaActive(ns.SimPanel:Working())") is True,         c.eval_py("return ns.SimPanel:Working()[...].gems", sh)
    # a set whose meta is off says so on the card
    c.eval("local s = ... ns.SimPanel:SetWorkingSlot(s, { id = 30055, enchant = 2986, gems = { 24027 } })", sh)
    assert c.eval("return select(2, ns.SimRunner:MetaOff(ns.SimPanel:Working()))") ==         "at least 2 Red, 2 Yellow and 2 Blue gems"
    c.eval("ns.SimPanel:Run()")
    run_until_done(w, c)
    assert "Meta gem off: needs" in c.eval("return ns.SimPanel._card().sub:GetText()")
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
