"""Raids > Teams, the target comp's UI (dev/art/casc/teams_mockup sections 8-13), on the real addon.

Covers: the Groups | Comp tabs (organizers always, members once the team has a comp), the empty Comp card and Start
from, the steppers (+ hidden at the team's size), Save / Undo of the comp with the team, a size change that the comp
doesn't fit (offers the preset), the lineup row's meter and Needs (only players in a group count), the read-only Comp
view (my row lit, no +),
the strip's planned state, the open slots in a raid's Sign-ups (Add players with the spec ready) and the LF message.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_comp_ui.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import world, K, DAY, now, create, signup  # noqa: E402
from _common import case, run_all, strip_codes, install_helpers, tt_lines  # noqa: E402

P = "ns.RaidsUI:GetPanel()"
TV = P + ".teams"
D = TV + ".detail"
# name, spec index (ns.SPECS)
SPECS = {"Lee": ("WARRIOR", 3), "Rita": ("PRIEST", 2), "Sam": ("ROGUE", 2), "Bob": ("MAGE", 2)}


def shown(cl, expr):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr) is True


def text_of(cl, expr):
    return strip_codes(cl.eval("local f = %s; return f and f:GetText()" % expr) or "")


def save_team(cl, name, members, size=10, comp=None, groups=None):
    res = cl.eval_py("local n, m, sz, s, cp, g = ...; local ok, r = ns.RaidPlan:SaveTeam(nil, n, m, { size = sz, specs = s, "
                     "groups = g, comp = cp or nil }); return { ok = ok, r = r }",
                     name, [K(n) for n in members], size, {K(n): SPECS[n][1] for n in members}, comp,
                     {K(n): g for n, g in (groups or {}).items()} or None)
    assert res["ok"] is True, res
    return res["r"]


def preset(cl, key):
    return cl.eval_py("return ns.RaidComp:GetPreset(...).cp", key)


def open_teams(w, cl, tid=None, tab="groups"):
    cl.slash("/dz raids")
    w.tick(0.5)
    cl.eval("ns.RaidsUI:SetView('teams')")
    if tid:
        cl.eval("ns.RaidPlanUI:SelectTeam(...)", tid)
    cl.eval("ns.RaidPlanUI:SetTeamTab(...)", tab)
    w.tick(0.3)


def click(cl, expr):
    cl.eval("local b = %s; b:GetScript('OnClick')(b, 'LeftButton')" % expr)


def menu_pick(cl, word):
    entries = [e.get("text") for e in (cl.last_menu() or {}).get("children", []) if e.get("text")]
    hit = [t for t in entries if strip_codes(t).strip() == word]
    assert hit, entries
    cl.menu_select(hit[0])


def col_rows(cl, i):
    """Column i of the Comp view: [(name, open)] of the shown rows."""
    rows = cl.eval_py("local out = {}; for _, r in ipairs(%s.cols[%d].rows) do if r:IsShown() then out[#out + 1] = "
                      "{ r.fs:GetText(), r.slot.member == nil } end end; return out" % (D, i)) or []
    rows = rows.values() if isinstance(rows, dict) else rows
    return [(strip_codes(t), bool(o)) for t, o in rows]


@case
def organizers_draft_the_comp_and_save_it_with_the_team():
    w, c = world()
    bob = c["Bob"]
    tid = save_team(bob, "Kara A", ["Lee", "Rita", "Sam", "Bob"], groups={"Lee": 1, "Rita": 1, "Sam": 2, "Bob": 2})
    w.tick(1)
    open_teams(w, bob, tid, "comp")
    # tabs for organizers; no comp yet: the empty card with its starts, no tool row (nothing to save)
    assert shown(bob, D + ".views") and shown(bob, D + ".compEmpty") and not shown(bob, D + ".tool")
    tiles = [text_of(bob, "%s.compEmpty.tiles[%d].t1" % (D, i)) for i in (1, 2, 3)
             if shown(bob, "%s.compEmpty.tiles[%d]" % (D, i))]
    assert tiles == ["Kara 10", "The team as it is"], tiles
    click(bob, D + ".compEmpty.tiles[2]")
    w.tick(0.3)
    cp = bob.eval_py("return ns.RaidPlanUI:GetDraft().cp")
    assert cp == {"WARRIOR": [0, 0, 1], "PRIEST": [0, 1], "ROGUE": [0, 1], "MAGE": [0, 1]}, cp
    assert shown(bob, D + ".compScroll") and shown(bob, D + ".saveBtn") and shown(bob, D + ".startBtn")
    assert text_of(bob, D + ".tabComp") == "Comp  4/4"
    assert col_rows(bob, 2) == [("Rita", False)], col_rows(bob, 2)
    # + on Healers: the steppers; Restoration Druid 0 -> 1
    click(bob, D + ".cols[2].add")
    steps = "ns.RaidPlanUI:GetCompSteps()"
    assert shown(bob, steps)
    names = [strip_codes(bob.eval("return %s.rows[%d].fs:GetText()" % (steps, i))) for i in range(1, 6)]
    assert names == ["Holy Paladin", "Discipline Priest", "Holy Priest", "Restoration Shaman", "Restoration Druid"], names
    assert not shown(bob, steps + ".rows[5].minus") and shown(bob, steps + ".rows[5].plus")
    click(bob, steps + ".rows[5].plus")
    w.tick(0.3)
    assert bob.eval("return ns.RaidComp:GetCount(ns.RaidPlanUI:GetDraft().cp, 'DRUID', 4)") == 1
    assert text_of(bob, steps + ".foot") == "5 of 10 slots"
    assert col_rows(bob, 2) == [("Rita", False), ("Restoration Druid", True)], col_rows(bob, 2)
    # the lineup row follows the draft: a meter and Needs
    assert shown(bob, D + ".lmeter") and not shown(bob, D + ".lroles")
    assert text_of(bob, D + ".lneeds.btns[1].fs") == "Restoration Druid"
    # Save: the comp goes with the team
    bob.click(bob.eval("return %s.saveBtn" % D))
    w.tick(1)
    t = c["Rita"].eval_py("return ns.RaidPlan:GetTeam(...)", tid)
    assert t["comp"] == {"WARRIOR": [0, 0, 1], "PRIEST": [0, 1], "ROGUE": [0, 1], "MAGE": [0, 1], "DRUID": [0, 0, 0, 1]}, t
    assert not shown(bob, D + ".saveBtn")
    # Undo brings a changed comp back; "No comp" empties it (saved: the team has none)
    click(bob, steps + ".rows[1].plus")
    w.tick(0.3)
    bob.click(bob.eval("return %s.revertBtn" % D))
    w.tick(0.3)
    assert bob.eval("return ns.RaidComp:CompSize(ns.RaidPlanUI:GetDraft().cp)") == 5
    bob.click(bob.eval("return %s.startBtn" % D))
    menu_pick(bob, "No comp")
    w.tick(0.3)
    assert shown(bob, D + ".compEmpty") and shown(bob, D + ".saveBtn")
    bob.click(bob.eval("return %s.saveBtn" % D))
    w.tick(1)
    assert c["Rita"].eval_py("return ns.RaidPlan:GetTeam(...)", tid).get("comp") is None
    w.assert_no_errors()


@case
def a_full_comp_hides_plus_and_a_smaller_size_offers_the_preset():
    w, c = world()
    bob = c["Bob"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"))
    w.tick(1)
    open_teams(w, bob, tid, "comp")
    assert all(not shown(bob, "%s.cols[%d].add" % (D, i)) for i in range(1, 5))
    # a slot clicked opens the steppers too: the footer says why + is gone
    click(bob, D + ".cols[1].rows[1]")
    assert "25 of 25 slots · take one out to add another" == text_of(bob, "ns.RaidPlanUI:GetCompSteps().foot")
    # 10-man: the comp has 25 slots, so the size waits for Kara 10
    bob.eval("ns.RaidPlanUI:SetDraftSize(10)")
    assert bob.popups() == ["DISASTERZONE_TEAM_COMP_SIZE"]
    assert bob.eval("return ns.RaidPlanUI:GetDraft().sz") == 25
    bob.accept_popup("DISASTERZONE_TEAM_COMP_SIZE")
    w.tick(0.3)
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert dr["sz"] == 10 and dr["cp"] == preset(bob, "kara10"), dr
    w.assert_no_errors()


@case
def members_see_the_meter_needs_and_a_read_only_comp():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    plain = save_team(bob, "Alt", ["Rita", "Lee"])
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"),
                    groups={"Rita": 1, "Lee": 1})
    w.tick(2)
    open_teams(w, rita, tid)
    # the lineup row: a square per slot, Needs with the open specs (comp order); the tabs show
    assert shown(rita, D + ".views") and shown(rita, D + ".lmeter") and shown(rita, D + ".lneeds")
    n = rita.eval("local n = 0; for _, s in ipairs(%s.lmeter.sq) do if s.o:IsShown() then n = n + 1 end end; "
                  "return n" % D)
    assert n == 25, n
    needs = [text_of(rita, "%s.lneeds.btns[%d].fs" % (D, i)) for i in (1, 2)]
    assert needs == ["Protection Paladin", "Feral Druid (Bear)"], needs      # (Lee fills Protection Warrior)
    # hover: the slot, open, then who could fill it (nobody here plays Protection Paladin)
    install_helpers(rita)
    btn = rita.eval("return %s.lneeds.btns[1]" % D)
    rita.hover(btn)
    tip = [strip_codes(l).strip() for l, _ in tt_lines(rita)]
    rita.leave(btn)
    assert tip[0] == "Protection Paladin" and tip[1].startswith("Open"), tip
    assert "Nobody in the guild plays it yet." in tip, tip
    # the Comp view: read-only, my row lit, no tool row, no +
    rita.eval("ns.RaidPlanUI:SetTeamTab('comp')")
    w.tick(0.3)
    assert not shown(rita, D + ".tool") and shown(rita, D + ".compBar") and shown(rita, D + ".compScroll")
    assert all(not shown(rita, "%s.cols[%d].add" % (D, i)) for i in range(1, 5))
    lit = rita.eval_py("local out = {}; for _, col in ipairs(%s.cols) do for _, r in ipairs(col.rows) do "
                       "if r:IsShown() and r.me:IsShown() then out[#out + 1] = r.slot.member.key end end end; "
                       "return out" % D)
    assert list(lit.values() if isinstance(lit, dict) else lit) == [K("Rita")], lit
    # a team without a comp: no tabs, the Groups as before
    rita.eval("ns.RaidPlanUI:SelectTeam(...)", plain)
    w.tick(0.3)
    assert not shown(rita, D + ".views") and shown(rita, D + ".scroll") and rita.eval("return ns.RaidPlanUI:GetTeamTab()") == "groups"
    w.assert_no_errors()


@case
def a_comp_saved_elsewhere_shows_at_once():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, groups={"Lee": 1, "Rita": 1, "Sam": 2})
    w.tick(2)
    open_teams(w, rita, tid)
    assert not shown(rita, D + ".views") and not shown(rita, D + ".lmeter")
    # the GM / council saves a comp: the member's view (nothing edited there) takes the new version
    res = bob.eval_py("local ok, r = ns.RaidPlan:SetTeamComp(..., ns.RaidComp:GetPreset('std25').cp); "
                      "return { ok = ok, r = r }", tid)
    assert res["ok"] is True, res
    w.tick(3)
    assert shown(rita, D + ".views") and shown(rita, D + ".lmeter")
    assert text_of(rita, D + ".tabComp") == "Comp  3/25"                # (Bob is unassigned: he doesn't count)
    w.assert_no_errors()


@case
def the_strip_shows_what_the_comp_plans():
    w, c = world()
    bob = c["Bob"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"),
                    groups={"Lee": 1, "Rita": 1})
    w.tick(1)
    open_teams(w, bob, tid, "comp")
    states = bob.eval_py("local out = {}; for _, b in ipairs(%s.compStrip.icons) do if b:IsShown() then "
                         "out[b.entry.key] = { b.entry.state, b.edges[1]:IsShown() } end end; return out" % D)
    assert states["fortitude"] == ["have", False], states          # Rita fills Holy Priest
    assert states["faeriefire"] == ["planned", True], states       # Balance / Feral slots open
    # the Groups strip: who is in the groups lights, the open slots are planned
    bob.eval("ns.RaidPlanUI:SetTeamTab('groups')")
    w.tick(0.3)
    g = bob.eval_py("local out = {}; for _, b in ipairs(ns.RaidPlanUI:GetTeamGrid().strip) do if b:IsShown() then "
                    "out[b.entry.key] = b.entry.state end end; return out")
    assert g["sunder"] == "have" and g["arcaneint"] == "planned", g    # Bob (Fire Mage) sits in no group
    w.assert_no_errors()


@case
def a_raid_lists_the_open_slots_and_the_lf_message():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"),
                    groups={"Lee": 1, "Rita": 1, "Sam": 2, "Bob": 2})
    occ = create(bob, i="ssc", t=now(bob) + 2 * DAY, tm=[tid])
    w.tick(2)
    signup(rita, occ, "A", 2)
    w.tick(2)
    # Sign-ups: the healers column ends with the open slots (gold); the count stays the answers
    bob.slash("/dz raids")
    w.tick(0.3)
    bob.eval("ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); ns.RaidPlanUI:SetDetailTab('signups')", occ)
    w.tick(0.3)
    rows = bob.eval_py("local out = {}; for _, r in ipairs(%s.upcoming.detail.roster.cols[2].rows) do if r:IsShown() then "
                       "out[#out + 1] = { r.fs:GetText(), r.cdlCell.open == true } end end; return out" % P)
    rows = [(strip_codes(t), bool(o)) for t, o in (rows.values() if isinstance(rows, dict) else rows)]
    assert rows[0] == ("Rita", False) and ("Holy Paladin", True) in rows and ("Restoration Druid", True) in rows, rows
    assert text_of(bob, P + ".upcoming.detail.roster.cols[2].count") == "1"
    # who runs the raid: a click opens Add players with that class and spec ready for a guest
    bob.eval("for _, r in ipairs(%s.upcoming.detail.roster.cols[2].rows) do if r:IsShown() and r.cdlCell.open "
             "and r.cdlCell.c == 'DRUID' then r:GetScript('OnClick')(r, 'LeftButton') end end" % P)
    w.tick(0.3)
    win = bob.eval_py("local w = ns.RaidPlanUI:GetInviteWindow(); return { shown = w:IsShown(), c = w.cls, sp = w.sp }")
    assert win == {"shown": True, "c": "DRUID", "sp": 4}, win
    bob.eval("ns.RaidPlanUI:GetInviteWindow():Hide()")
    # the team's ... menu: LF message puts the line in the chat box
    bob.eval("ns.RaidsUI:SetView('teams'); ns.RaidPlanUI:SelectTeam(...)", tid)
    w.tick(0.3)
    bob.click(bob.eval("return %s.moreBtn" % D))
    menu_pick(bob, "LF message")
    line = bob.eval("return __MOCK.opened_chat")
    assert line and "LF Protection Paladin" in line and "SSC" in line and line.endswith("/w me"), line
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
