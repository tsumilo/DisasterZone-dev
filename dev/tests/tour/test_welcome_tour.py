"""The Welcome tour (UI/Tour.lua, Data/Tours/Welcome.lua, UI/WelcomeTour.lua, Settings > Tutorials): one part per
role (Everyone, Raid leader, Officer, Guild council, Guild Master), a player runs the parts of the roles they hold.
Offered once when the window opens (any answer counts), a new role later offers only its part, the council part runs
on demo data and switches it off again, a look around another role's part records nothing, a part stopped halfway
goes on from there, and the GM gets a set-up checklist (Settings > Tutorials, a Home chip).

Run: luaenv\\Scripts\\python.exe tests\\tour\\test_welcome_tour.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402

ALL = ["all", "leader", "officer", "council", "gm"]
T = "ns.Tour"
W = "ns.WelcomeTour"


def state(c):
    return c.eval_py("return %s:GetState()" % T)


def open_window(c, key="home"):
    c.eval("ns.MainFrame:Open(...)", key)
    c.world.tick(1.5)


def offer_shown(c):
    return c.eval("return %s.offerFrame ~= nil and %s.offerFrame:IsShown()" % (W, W)) is True


def offer_rows(c):
    return c.eval_py("""
      local out = {}
      for _, r in ipairs(%s.offerFrame.box.rows) do if r:IsShown() then out[#out + 1] = r.key end end
      return out""" % W)


def walk(c, limit=80):
    """Next until the tour ends; every step seen as (part, step, anchored, lit)."""
    seen = []
    for _ in range(limit):
        s = state(c)
        if not s:
            return seen
        seen.append((s["chapter"], s["si"], s["anchored"], s["lit"]))
        c.eval("%s:Next()" % T)
        c.world.tick(0.4)
    raise AssertionError("the tour never ended: %r" % seen[-5:])


def progress(c):
    return c.eval_py("local p = %s:Progress('welcome'); return { seen = p.seen, done = p.done, at = p.at, "
                     "known = p.known }" % T)


def demo(c):
    return c.eval("return ns.Demo:IsEnabled()") is True


@case
def a_raider_is_offered_everyone_once():
    w, c = solo("Rai", guild_rank=3)
    assert c.eval_py("return %s:Roles()" % W) == {"all": True}
    open_window(c)
    assert offer_shown(c)
    assert offer_rows(c) == ["all"]
    c.eval("%s:AnswerOffer(false)" % W)
    assert not offer_shown(c)
    assert progress(c)["seen"] is True
    # never again by itself, even after a reload
    c.eval("ns.MainFrame:Close()")
    open_window(c)
    assert not offer_shown(c)
    c.relog()
    w.tick(2)
    open_window(c)
    assert not offer_shown(c)
    assert state(c) is None
    no_errors(w)


@case
def the_gm_gets_every_part_and_each_step_lights_its_control():
    w, c = solo("Gina", guild_rank=0)
    assert c.eval_py("return %s:Roles()" % W) == {k: True for k in ALL}
    open_window(c)
    assert offer_rows(c) == ALL
    c.eval("%s:AnswerOffer(true)" % W)
    w.tick(0.5)
    s = state(c)
    assert s["parts"] == ALL and s["chapter"] == "all" and s["bar"] is True, s
    seen = walk(c)
    parts = []
    for part, si, anchored, lit in seen:
        if part not in parts:
            parts.append(part)
    assert parts == ALL, parts
    dark = [(p, si) for p, si, anchored, lit in seen if anchored and not lit]
    assert dark == [], dark
    assert progress(c)["done"] == {k: True for k in ALL}
    assert not demo(c)          # the council part's demo data is gone again
    no_errors(w)


@case
def unticked_parts_are_left_out():
    w, c = solo("Gina", guild_rank=0)
    open_window(c)
    c.eval("""for _, r in ipairs(%s.offerFrame.box.rows) do
                if r.key == 'officer' or r.key == 'gm' then r.cb:Click() end end""" % W)
    c.eval("%s:AnswerOffer(true)" % W)
    w.tick(0.5)
    assert state(c)["parts"] == ["all", "leader", "council"]
    # Back on the very first step stays there
    c.eval("%s:Back()" % T)
    assert (state(c)["chapter"], state(c)["si"]) == ("all", 1)
    no_errors(w)


@case
def the_council_part_runs_on_demo_data_and_switches_it_off():
    w, c = solo("Gina", guild_rank=0)
    c.eval("%s.Progress().seen = true" % W)
    open_window(c)
    assert c.eval("return %s:StartPart('council')" % W) is True
    w.tick(0.5)
    s = state(c)
    assert (s["chapter"], s["demo"]) == ("council", True), s
    assert demo(c)
    c.eval("%s:Next(); %s:Next()" % (T, T))
    w.tick(0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "council"
    c.eval("%s:Stop()" % T)
    assert not demo(c)
    # demo mode switched on by the player stays on
    c.eval("ns.Demo:SetEnabled(true)")
    c.eval("%s:StartPart('council')" % W)
    w.tick(0.5)
    c.eval("%s:Stop()" % T)
    assert demo(c)
    no_errors(w)


@case
def a_raider_can_look_around_another_part_without_it_counting():
    w, c = solo("Rai", guild_rank=3)
    c.eval("%s.Progress().seen = true" % W)
    open_window(c)
    assert c.eval("return %s:StartPart('council')" % W) is False      # not mine
    assert c.eval("return %s:StartPart('council', true)" % W) is True
    w.tick(0.5)
    s = state(c)
    assert (s["chapter"], s["peek"], s["demo"]) == ("council", True, True), s
    walk(c)
    assert progress(c)["done"] in ({}, [], None), progress(c)
    assert not demo(c)
    no_errors(w)


@case
def a_part_stopped_halfway_goes_on_from_there():
    w, c = solo("Gina", guild_rank=0)
    c.eval("%s.Progress().seen = true" % W)
    open_window(c)
    c.eval("%s:StartPart('leader')" % W)
    w.tick(0.3)
    c.eval("%s:Next(); %s:Next()" % (T, T))
    w.tick(0.3)
    assert state(c)["si"] == 3
    c.eval("%s:Stop()" % T)
    assert progress(c)["at"] == {"leader": 3}
    assert c.eval_py("return { %s:PartState('leader') }" % W) == ["at", 3, 6]
    c.eval("%s:StartPart('leader')" % W)
    w.tick(0.3)
    assert (state(c)["chapter"], state(c)["si"]) == ("leader", 3)
    walk(c)
    assert progress(c)["done"] == {"leader": True}
    assert c.eval_py("return { %s:PartState('leader') }" % W) == ["done", 6, 6]
    no_errors(w)


@case
def a_new_role_offers_only_its_part_once():
    w, c = solo("Rai", guild_rank=3)
    open_window(c)
    c.eval("%s:AnswerOffer(false)" % W)
    w.tick(1)
    kinds = lambda: c.eval_py("""local out = {}
        for _, it in ipairs(ns.Notify:List()) do if it.kind == 'tourRole' then out[#out + 1] = it.key end end
        return out""")
    assert kinds() in ([], {}), kinds()
    # promoted to officer
    c.guild_rank = 1
    w._sync(roster_changed=True)
    w.tick(2)
    c.eval("ns.Notify:Refresh('tourRole')")
    w.tick(0.5)
    assert c.eval_py("return %s:Roles()" % W).get("officer") is True
    assert kinds() == ["officer"], kinds()
    c.eval("for _, it in ipairs(ns.Notify:List()) do if it.kind == 'tourRole' then ns.Notify:Open(it.id) end end")
    w.tick(0.5)
    s = state(c)
    assert (s["chapter"], s["parts"]) == ("officer", ["officer"]), s
    c.eval("%s:Stop()" % T)
    c.eval("ns.Notify:Refresh('tourRole')")
    w.tick(0.5)
    assert kinds() in ([], {}), kinds()
    assert progress(c)["known"].get("officer") is True
    no_errors(w)


@case
def the_gm_checklist_shows_on_home_and_in_settings():
    w, c = solo("Gina", guild_rank=0)
    c.eval("%s.Progress().seen = true" % W)
    open_window(c)
    items = c.eval_py("return %s:Checklist()" % W)
    assert [it["key"] for it in items] == ["council", "leaders", "rules", "attendance", "raid"], items
    n, total = c.eval_py("return { %s:ChecklistCount() }" % W)
    assert total == 5 and n < total
    c.eval("ns.Notify:Refresh('guildSetup')")
    w.tick(0.5)
    chips = c.eval_py("""local out = {}
        for _, it in ipairs(ns.Notify:List({ home = true })) do out[#out + 1] = it.kind end return out""")
    assert "guildSetup" in chips, chips
    c.eval("%s:SetSetupHidden(true)" % W)
    w.tick(0.5)
    chips = c.eval_py("""local out = {}
        for _, it in ipairs(ns.Notify:List({ home = true })) do out[#out + 1] = it.kind end return out""")
    assert "guildSetup" not in (chips or []), chips
    # Settings > Tutorials: every part (the GM has all roles), the checklist, no "other roles"
    c.eval("ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('tutorials'); ns.SettingsUI:Refresh()")
    w.tick(0.5)
    rows = c.eval_py("""local t = ns.SettingsUI.tut local out = {}
        for _, k in ipairs(ns.WelcomeTour.ORDER) do out[k] = t.parts[k]:IsShown() end
        out.peek = t.peek:IsShown(); out.setup = t.setupHead:IsShown(); return out""")
    assert rows == {"all": True, "leader": True, "officer": True, "council": True, "gm": True, "peek": False,
                    "setup": True}, rows
    no_errors(w)


@case
def settings_tutorials_for_a_raider():
    w, c = solo("Rai", guild_rank=3)
    c.eval("%s.Progress().seen = true" % W)
    c.eval("ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('tutorials'); ns.SettingsUI:Refresh()")
    w.tick(0.5)
    rows = c.eval_py("""local t = ns.SettingsUI.tut local out = {}
        for _, k in ipairs(ns.WelcomeTour.ORDER) do out[k] = t.parts[k]:IsShown() end
        out.peek = t.peek:IsShown(); out.setup = t.setupHead:IsShown(); out.strategy = t.strategy:IsShown()
        out.btn = t.parts.all.btn:GetText(); return out""")
    assert rows == {"all": True, "leader": False, "officer": False, "council": False, "gm": False, "peek": True,
                    "setup": False, "strategy": True, "btn": "Start"}, rows
    c.eval("ns.SettingsUI.tut.parts.all.btn:Click()")
    w.tick(0.5)
    assert state(c)["parts"] == ["all"]
    no_errors(w)


@case
def slash_tour_opens_the_offer_then_the_tour():
    w, c = solo("Rai", guild_rank=3)
    c.eval("%s:SlashTour()" % W)
    w.tick(0.5)
    assert offer_shown(c)
    c.eval("%s:AnswerOffer(false)" % W)
    c.eval("%s:SlashTour()" % W)
    w.tick(0.5)
    assert state(c)["chapter"] == "all"
    no_errors(w)


if __name__ == "__main__":
    run_all()
