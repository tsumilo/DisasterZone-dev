"""ADDENDUM J §58: the Raids tab's Upcoming / Teams views and the New / Edit raid window, on the real addon.

Covers: the tab open to every guild member (Raid log only for council), a member answering from the sign-up strip
(spec picked before answering, note), the roster columns and Bench / Absent / No response lines, the organizer's New raid
window (one-off and weekly, "this week only" vs "every week"), cancel / restore from the Cancel menu, the Teams view
(new team through the picker, save, read-only for members), and the login reminder.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_ui.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import world, K, DAY, now, team, create, raids, raid, signup, signups, call  # noqa: E402
from _common import case, run_all, printed_since, strip_codes, install_helpers, tt_lines  # noqa: E402


def open_tab(w, cl, view="upcoming"):
    cl.slash("/cdl raids")
    w.tick(0.5)
    if view != "upcoming":
        cl.eval("ns.RaidsUI:SetView(...)", view)
        w.tick(0.5)
    assert cl.eval("return ns.MainFrame:GetSelectedTab()") == "raids"
    assert cl.eval("return ns.RaidsUI:GetView()") == view


def shown(cl, expr):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr) is True


P = "ns.RaidsUI:GetPanel()"


def has_line(cl, label, count):
    """A roster line "<label> (<n>): names" (the label is colour-coded)."""
    for o in cl.find_text(label, True, True):
        t = strip_codes(cl.eval("local o = ...; return o:GetText()", o) or "")
        if label in t and count in t:
            return True
    return False


# ------------------------------------------------------------------------------------------------------------------
@case
def member_sees_upcoming_and_answers_from_the_strip():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = team(bob, "Kara A", ["Rita", "Lee", "Sam"])
    occ = create(bob, i="kara", t=now(bob) + DAY, tm=[tid], no="Bring pots")
    w.tick(2)
    assert rita.eval("return ns.RaidsUI:IsAvailable()") is True
    open_tab(w, rita)
    assert shown(rita, P + ".upcoming") and not shown(rita, P + ".logBtn")
    assert not shown(rita, P + ".newRaidBtn")
    assert rita.eval("return ns.RaidPlanUI:GetSelectedRaid()") == occ      # the raid to answer is picked
    assert rita.find_text("Karazhan (10)", True, True)
    assert rita.find_text("Bring pots", True, True)
    assert rita.find_text("Pick an answer", True, True)
    # pick Shadow first, then a note, then Accept: all three go out together
    rita.type_text(rita.eval("return ns.RaidsUI:GetPanel().upcoming.noteBox"), "late 10")
    dd = rita.dropdown_menu(rita.eval("return ns.RaidsUI:GetPanel().upcoming.specDD"))
    labels = [e["text"] for e in dd["children"]]
    assert labels == ["Discipline", "Holy", "Shadow"], labels
    _select_spec(rita, 3)
    rita.click(rita.eval("return ns.RaidsUI:GetPanel().upcoming.statusBtns.A"))
    w.tick(2)
    s = signups(bob, occ)[K("Rita")]
    assert s["st"] == "A" and s["sp"] == 3 and s["n"] == "late 10", s
    assert rita.find_text("Saved: Accepted", True, True)
    # others' answers show in the roster of the organizer
    signup(c["Lee"], occ, "A", 3)      # Protection -> Tanks column
    signup(c["Sam"], occ, "X")
    w.tick(2)
    open_tab(w, bob)
    bob.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.3)
    assert bob.find_text("Tanks", True, True) and bob.find_text("Ranged", True, True)
    assert bob.find_text("Lee", True, True) and bob.find_text("Rita", True, True)
    assert has_line(bob, "Absent", "(1)")
    assert bob.find_text("2 accepted", True, True)
    assert shown(bob, P + ".logBtn") and shown(bob, P + ".newRaidBtn")
    w.assert_no_errors()


def _select_spec(cl, index):
    """Selects entry `index` of the sign-up spec dropdown like a click in its menu."""
    entries = cl.dropdown_menu(cl.eval("return ns.RaidsUI:GetPanel().upcoming.specDD"))["children"]
    cl.menu_select(entries[index - 1]["text"])


@case
def no_response_line_lists_invited_members_without_an_answer():
    w, c = world()
    bob = c["Bob"]
    tid = team(bob, "Main", ["Rita", "Lee", "Sam"])
    occ = create(bob, i="gruul", t=now(bob) + DAY, tm=[tid])
    w.tick(2)
    signup(c["Sam"], occ, "B")
    w.tick(2)
    open_tab(w, bob)
    bob.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.3)
    assert has_line(bob, "No response", "(2)")
    assert has_line(bob, "Bench", "(1)")
    assert bob.find_text("2 no response", True, True)
    w.assert_no_errors()


@case
def organizer_creates_and_edits_raids_in_the_window():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = team(bob, "Kara A", ["Rita"])
    w.tick(1)
    open_tab(w, bob)
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().newRaidBtn"))
    w.tick(0.2)
    assert shown(bob, "CDLootRaidEditor")
    ed = "ns.RaidPlanUI:GetEditor()"
    bob.eval("local e = %s; e.f.i = 'ssc'; e.f.sz = 25; e.f.day = 2; e.f.hour = 19; e.f.min = 30; e.f.tm[...] = true;"
             " e.noteBox:SetText('Vashj progress'); e.weeklyCB:SetChecked(true)" % ed, tid)
    bob.click(bob.eval("return %s.saveBtn" % ed))
    w.tick(2)
    assert not shown(bob, "CDLootRaidEditor")
    rs = raids(rita)
    assert len(rs) == 2 and all(r["weekly"] and r["i"] == "ssc" and r["sz"] == 25 for r in rs), rs
    assert rs[0]["tm"] == [tid] and rs[0]["no"] == "Vashj progress", rs[0]
    assert rita.eval("return date('%H:%M', ...)", rs[0]["t"]) == "19:30"
    occ0, occ1 = rs[0]["id"], rs[1]["id"]
    assert bob.eval("return ns.RaidPlanUI:GetSelectedRaid()") == occ0
    # this week only
    bob.eval("ns.RaidPlanUI:OpenEditor(...)", occ0)
    assert shown(bob, "%s.saveAllBtn" % ed)
    bob.eval("%s.noteBox:SetText('Lurker only')" % ed)
    bob.click(bob.eval("return %s.saveBtn" % ed))
    w.tick(2)
    assert raid(rita, occ0)["no"] == "Lurker only" and raid(rita, occ1)["no"] == "Vashj progress"
    # every week: 20:00
    bob.eval("ns.RaidPlanUI:OpenEditor(...); %s.f.hour = 20; %s.f.min = 0" % (ed, ed), occ1)
    bob.click(bob.eval("return %s.saveAllBtn" % ed))
    w.tick(2)
    assert [rita.eval("return date('%H:%M', ...)", r["t"]) for r in raids(rita)] == ["20:00", "20:00"]
    # errors stay in the window: a date in the past
    bob.eval("ns.RaidPlanUI:OpenEditor(); local e = %s; e.f.day = -3" % ed)
    bob.click(bob.eval("return %s.saveBtn" % ed))
    w.tick(0.2)
    assert shown(bob, "CDLootRaidEditor") and "past" in bob.eval("return %s.err:GetText()" % ed)
    # members can't open it
    n0 = len(rita.chat_frame)
    rita.eval("ns.RaidPlanUI:OpenEditor()")
    assert any("guild council" in strip_codes(l) for l in printed_since(rita, n0))
    w.assert_no_errors()


@case
def cancel_menu_cancels_restores_and_deletes_weekly():
    w, c = world()
    bob, sam = c["Bob"], c["Sam"]
    occ = create(bob, i="kara", t=now(bob) + DAY, weekly=True)
    w.tick(2)
    open_tab(w, bob)
    bob.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.3)
    btn = bob.eval("return ns.RaidsUI:GetPanel().upcoming.detail.cancelBtn")
    entries = [e["text"] for e in bob.dropdown_menu(btn)["children"]]
    assert entries == ["Cancel this week's raid", "Stop repeating after this raid", "Delete the whole weekly raid"], entries
    bob.menu_select("Cancel this week's raid")
    w.tick(2)
    assert raid(sam, occ)["cancelled"] is True
    w.tick(0.5)
    assert bob.find_text("CANCELLED", True, True)
    assert "Restore this raid" in [e["text"] for e in bob.dropdown_menu(btn)["children"]]
    bob.menu_select("Restore this raid")
    w.tick(2)
    assert raid(sam, occ)["cancelled"] is False
    bob.dropdown_menu(btn)
    bob.menu_select("Delete the whole weekly raid")
    bob.accept_popup("CDLOOT_PLAN_CONFIRM")
    w.tick(2)
    assert raids(sam) == []
    w.assert_no_errors()


@case
def teams_view_builds_a_team_members_read_only():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    open_tab(w, bob, "teams")
    assert bob.find_text("Make a team with New team", True, True)
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().newTeamBtn"))
    w.tick(0.2)
    tv = "ns.RaidsUI:GetPanel().teams"
    bob.eval("%s.nameBox:SetText('Gruul team')" % tv)
    for n in ("Rita", "Sam", "Lee"):
        bob.eval("ns.RaidPlanUI:ToggleDraftMember(...)", K(n))
    bob.eval("ns.RaidPlanUI:ToggleDraftMember(...)", K("Lee"))       # and removed again
    w.tick(0.3)
    assert bob.find_text("(not saved)", True, True)
    assert bob.eval("return %s.detail.saveBtn:IsEnabled()" % tv) is True
    bob.click(bob.eval("return %s.detail.saveBtn" % tv))
    w.tick(2)
    tms = rita.eval_py("return ns.RaidPlan:GetTeams()")
    assert len(tms) == 1 and tms[0]["name"] == "Gruul team" and tms[0]["members"] == [K("Rita"), K("Sam")], tms
    assert bob.eval("return %s.detail.saveBtn:IsEnabled()" % tv) is False
    open_tab(w, rita, "teams")
    assert rita.find_text("Gruul team", True, True)
    assert not shown(rita, "%s.detail.saveBtn" % tv) and not shown(rita, "%s.picker.frame" % tv)
    assert not shown(rita, "ns.RaidsUI:GetPanel().newTeamBtn")
    w.assert_no_errors()


@case
def login_reminder_lists_raids_to_answer():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = team(bob, "Kara A", ["Rita"])
    create(bob, i="kara", t=now(bob) + DAY, tm=[tid])
    create(bob, i="gruul", t=now(bob) + 2 * DAY)          # open raid: no reminder
    w.tick(2)
    rita.relog()
    n0 = len(rita.chat_frame)
    w.tick(50)
    lines = [strip_codes(l) for l in printed_since(rita, n0) if "to answer" in strip_codes(l)]
    assert len(lines) == 1 and "1 raid to answer" in lines[0] and "Karazhan" in lines[0], lines
    signup(rita, raids(rita)[0]["id"], "A")
    rita.relog()
    n0 = len(rita.chat_frame)
    w.tick(50)
    assert not [l for l in printed_since(rita, n0) if "to answer" in strip_codes(l)]
    w.assert_no_errors()


def hover_tip(cl, finder, key):
    """Hovers the frame `finder` returns for `key` (Lua, ... = key) and returns the tooltip's left lines (plain)."""
    install_helpers(cl)
    frame = cl.eval(finder, key)
    assert frame is not None, "no frame for %s" % key
    cl.hover(frame)
    lines = [strip_codes(l) for l, _ in tt_lines(cl)]
    cl.leave(frame)
    return lines


ROSTER_CELL = """
  local key = ...
  local found
  ns.RaidsUI:GetPanel().upcoming.detail.roster.box:ForEachFrame(function(row)
    for _, cell in ipairs(row.cells or {}) do
      if cell:IsShown() and cell.cdlCell and cell.cdlCell.key == key then found = cell end
    end
  end)
  return found"""

GROUP_CHIP = """
  local key = ...
  local grid = ns.RaidPlanUI:GetRaidGrid()
  for _, box in ipairs(grid.boxes) do
    for _, chip in ipairs(box.chips) do if chip.key == key then return chip end end
  end
  local found
  grid.pool.list.box:ForEachFrame(function(row)
    for _, chip in ipairs(row.chips or {}) do if chip:IsShown() and chip.key == key then found = chip end end
  end)
  return found"""


@case
def signup_order_is_kept_and_shown_on_hover():
    w, c = world()
    bob = c["Bob"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    signup(c["Sam"], occ, "T", 2)
    w.tick(120)
    signup(c["Rita"], occ, "A", 3)
    w.tick(120)
    signup(c["Lee"], occ, "B", 3)
    w.tick(300)
    signup(c["Sam"], occ, "A")                   # changing the answer keeps Sam first
    w.tick(2)
    for n, x in c.items():
        order = x.eval_py("return (ns.RaidPlan:GetSignupOrder(...))", occ)
        assert order == {K("Sam"): 1, K("Rita"): 2, K("Lee"): 3}, (n, order)
    open_tab(w, bob)
    bob.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.3)
    lines = hover_tip(bob, ROSTER_CELL, K("Sam"))
    assert any(l.startswith("Sign-up #1 of 3") for l in lines), lines
    assert any(l.startswith("Changed to Accepted") for l in lines), lines
    lines = hover_tip(bob, ROSTER_CELL, K("Lee"))              # Bench: its own cells, hoverable too
    assert any(l.startswith("Sign-up #3 of 3") for l in lines), lines
    assert not any(l.startswith("Changed") for l in lines), lines
    assert has_line(bob, "Bench", "(1)")
    # the Groups tab chips
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().upcoming.detail.tabGroups"))
    w.tick(0.3)
    lines = hover_tip(bob, GROUP_CHIP, K("Rita"))
    assert any(l.startswith("Sign-up #2 of 3") for l in lines), lines
    lines = hover_tip(bob, GROUP_CHIP, K("Lee"))
    assert any(l.startswith("Sign-up #3 of 3") for l in lines) and "Signed up as Bench" in lines, lines
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
