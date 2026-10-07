"""Raids > Teams, the makeover (dev/art/casc/teams_mockup sections 1-7), on the real addon.

Covers: the team chips (only with two or more, my team opens first and has the gold dot), the team card (the roster,
"You: Group n · spec" for members, who changed it, the raids that invite it with my answer / the team's acceptances),
the lineup chips under it,
the tool row (Undo / Save only while something changed, Auto-fill only with members), the unsaved-changes guard
(another team, New team, another Raids view, the window closed: Save / Discard / Cancel), Cancel on a new team,
the ... menu (Copy, Clear groups, Delete with what it changes for a locked raid), Add several (my party, a raid's
accepted players), the spec from a click on the role icon, and the read-only view (my chip lit, no tool row).

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_teams.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import world, K, DAY, now, team, create, signup  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

P = "ns.RaidsUI:GetPanel()"
TV = P + ".teams"
D = TV + ".detail"


def open_teams(w, cl, board=False):
    """Raids > Teams: the board, then (unless board) the team it would open first (mine, else the first)."""
    cl.slash("/dz raids")
    w.tick(0.5)
    cl.eval("ns.RaidsUI:SetView('teams')")
    w.tick(0.5)
    if not board and cl.eval("return ns.RaidPlanUI:IsTeamBoard()"):
        cl.eval("ns.RaidPlanUI:SelectTeam(ns.RaidPlanUI:GetSelectedTeam())")
        w.tick(0.3)


def shown(cl, expr):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr) is True


def text_of(cl, expr):
    return strip_codes(cl.eval("local f = %s; return f and f:GetText()" % expr) or "")


def popup_click(cl, name, index):
    """Click button `index` (1 Save, 2 Discard, 3 Cancel) of the visible StaticPopup `name`."""
    assert cl.eval("local which, i = ...; local _, f = StaticPopup_Visible(which); if not f then return false end;"
                   " StaticPopup_OnClick(f, i); return true", name, index) is True, cl.popups()


def menu_pick(cl, word):
    """Run the entry of the last menu whose text (without its icon) is `word`."""
    entries = [e.get("text") for e in (cl.last_menu() or {}).get("children", []) if e.get("text")]
    hit = [t for t in entries if strip_codes(t).strip() == word]
    assert hit, entries
    cl.menu_select(hit[0])


def board(cl):
    """The board's team banners shown, in order: [(name, mine)]."""
    rows = cl.eval_py("local out = {}; for _, c in ipairs(%s.board.cards) do if c:IsShown() then out[#out + 1] = "
                      "{ c.t1:GetText(), c.dot:IsShown() } end end; return out" % TV) or []
    return [tuple(r) for r in (rows.values() if isinstance(rows, dict) else rows)]


def board_card(cl, name):
    return cl.eval("local n = ...; for _, c in ipairs(%s.board.cards) do if c:IsShown() and c.t1:GetText() == n "
                   "then return c end end" % TV, name)


def lineup_chips(cl):
    """The lineup cards shown: [(name, chosen, mine)]."""
    rows = cl.eval_py("local out = {}; for _, c in ipairs(%s.lcards) do if c:IsShown() then out[#out + 1] = "
                      "{ c.name:GetText(), c.chosen, c.dot:IsShown() } end end; return out" % D) or []
    return [tuple(r) for r in (rows.values() if isinstance(rows, dict) else rows)]


def dirty_buttons(cl):
    # (the banner's line says "changed, not saved" since the raid buffs took the toolbar's room)
    said = "not saved" in strip_codes(cl.eval("return %s.card.changed:GetText()" % TV) or "")
    return shown(cl, D + ".saveBtn"), shown(cl, D + ".revertBtn"), said


@case
def chips_card_and_my_team_first():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    a = team(bob, "Alt team", ["Lee", "Sam"])
    m = team(bob, "Main team", ["Rita", "Lee", "Sam", "Bob"])
    bob.eval_py("local id, m = ...; return ns.RaidPlan:SaveTeam(id, 'Main team', m, { size = 25, specs = { [m[1]] = 2 },"
                " groups = { [m[1]] = 5, [m[2]] = 1 } })", m, [K("Rita"), K("Lee"), K("Sam"), K("Bob")])
    occ = create(bob, i="ssc", t=now(bob) + 2 * DAY, tm=[m], lk=True)
    mag = create(bob, i="mag", t=now(bob) + 4 * DAY, tm=[m])
    w.tick(2)
    signup(rita, occ, "A", 2)
    signup(c["Lee"], occ, "A", 3)
    w.tick(2)
    # a member: the board first, their own team on top; a click opens it, read-only
    open_teams(w, rita, board=True)
    assert rita.eval("return ns.RaidPlanUI:IsTeamBoard()") is True and not shown(rita, D)
    assert board(rita) == [("Main team", True), ("Alt team", False)], board(rita)
    assert text_of(rita, TV + ".board.heads[1]") == "YOUR TEAMS" and text_of(rita, TV + ".board.cards[1].kick") == "YOUR TEAM"
    main = board_card(rita, "Main team")
    assert rita.eval("return %s.board.cards[1].th" % TV) == "ssc"                    # (no theme: its next raid's)
    assert text_of(rita, TV + ".board.cards[1].r2").endswith("Serpentshrine Cavern")
    assert text_of(rita, TV + ".board.cards[1].r3") == "2/2", text_of(rita, TV + ".board.cards[1].r3")
    assert text_of(rita, TV + ".board.cards[1].t2") == "4 players   ·   25-man"
    rita.click(main)
    w.tick(0.3)
    assert rita.eval("return ns.RaidPlanUI:GetSelectedTeam()") == m and not rita.eval("return ns.RaidPlanUI:IsTeamBoard()")
    assert text_of(rita, TV + ".card.title") == "Main team" and text_of(rita, TV + ".card.count") == "4 players"
    # its one lineup: a card saying its size, chosen, my gold dot (I'm in its groups); no "+ Lineup" for members
    assert lineup_chips(rita) == [("25-man", True, True)], lineup_chips(rita)
    assert not shown(rita, D + ".lcAdd")
    assert text_of(rita, TV + ".card.you.fs") == "You: Group 5 · Holy"
    assert "changed by Bob" in text_of(rita, TV + ".card.changed")
    assert not shown(rita, D + ".tool") and not shown(rita, TV + ".nameBox") and not shown(rita, D + ".moreBtn")
    # the next raid that invites it, with my answer; "+1 more" for the other
    assert text_of(rita, TV + ".card.next.line").endswith("Serpentshrine Cavern")
    assert text_of(rita, TV + ".card.next.sub") == "Accepted" and shown(rita, TV + ".card.next.lock")
    assert text_of(rita, TV + ".card.next.extra.fs") == "·  +1 more"
    # my chip is lit in the read-only grid
    lit = rita.eval_py("local out = {}; local g = ns.RaidPlanUI:GetTeamGrid(); for _, b in ipairs(g.boxes) do"
                       " for _, ch in ipairs(b.chips) do if ch.me:IsShown() then out[#out + 1] = ch.key end end end;"
                       " return out")
    assert list(lit.values() if isinstance(lit, dict) else lit) == [K("Rita")], lit
    # an organizer: the field, "+ Lineup", the team's acceptances
    open_teams(w, bob)
    bob.eval("ns.RaidPlanUI:SelectTeam(...)", m)
    w.tick(0.3)
    assert shown(bob, TV + ".nameBox") and shown(bob, D + ".lcAdd") and shown(bob, D + ".moreBtn")
    assert text_of(bob, TV + ".card.next.sub") == "2 of 2 accepted"  # (the players in its groups: Rita, Lee)
    assert dirty_buttons(bob) == (False, False, False)              # nothing changed: no Undo / Save
    assert lineup_chips(bob) == [("25-man", True, False)], lineup_chips(bob)
    assert shown(bob, D + ".autoBtn")
    # Theme: a draft change; saved with the team, its banner on the board for everyone
    bob.click(bob.eval("return %s.moreBtn" % D))
    menu_pick(bob, "Theme")
    w.tick(0.1)
    menu_pick(bob, "Black Temple")
    w.tick(0.3)
    assert dirty_buttons(bob) == (True, True, True)
    bob.click(bob.eval("return %s.saveBtn" % D))
    w.tick(2)
    assert rita.eval_py("return ns.RaidPlan:GetTeam(...)", m)["theme"] == "bt"
    rita.eval("ns.RaidPlanUI:ShowTeamBoard()")
    w.tick(0.3)
    assert rita.eval("return %s.board.cards[1].th" % TV) == "bt"
    w.assert_no_errors()


@case
def unsaved_changes_ask_before_they_are_lost():
    w, c = world()
    bob = c["Bob"]
    a = team(bob, "Alpha", ["Lee", "Sam"])
    b = team(bob, "Beta", ["Rita"])
    w.tick(2)
    open_teams(w, bob)
    bob.eval("ns.RaidPlanUI:SelectTeam(...)", a)
    w.tick(0.3)
    bob.eval("ns.RaidPlanUI:ToggleDraftMember(...)", K("Rita"))
    w.tick(0.3)
    assert dirty_buttons(bob) == (True, True, True)
    assert text_of(bob, D + ".status") == "Changed, not saved" and text_of(bob, D + ".revertBtn") == "Undo"
    # another team: asks; Cancel stays with the changes
    bob.click(bob.eval("return %s.back" % D))
    assert bob.popups() == ["DISASTERZONE_TEAM_UNSAVED"]
    assert "Alpha" in bob.eval("local _, f = StaticPopup_Visible('DISASTERZONE_TEAM_UNSAVED'); return f.text:GetText()")
    popup_click(bob, "DISASTERZONE_TEAM_UNSAVED", 3)
    assert bob.eval("return ns.RaidPlanUI:GetSelectedTeam()") == a and bob.eval_py("return ns.RaidPlanUI:GetDraft().members")[K("Rita")]
    # Discard: the changes go, Beta opens
    bob.eval("ns.RaidPlanUI:SelectTeam(...)", b)
    popup_click(bob, "DISASTERZONE_TEAM_UNSAVED", 2)
    w.tick(0.3)
    assert bob.eval("return ns.RaidPlanUI:GetSelectedTeam()") == b
    assert sorted(bob.eval_py("return ns.RaidPlan:GetTeam(...)", a)["members"]) == [K("Lee"), K("Sam")]
    # Save: kept, then the other view opens (leaving Teams asks too)
    bob.eval("ns.RaidPlanUI:ToggleDraftMember(...)", K("Sam"))
    bob.eval("ns.RaidsUI:SetView('upcoming')")
    assert bob.eval("return ns.RaidsUI:GetView()") == "teams"            # not yet
    popup_click(bob, "DISASTERZONE_TEAM_UNSAVED", 1)
    w.tick(1)
    assert bob.eval("return ns.RaidsUI:GetView()") == "upcoming"
    assert sorted(bob.eval_py("return ns.RaidPlan:GetTeam(...)", b)["members"]) == [K("Rita"), K("Sam")]
    # the window closed with changes: asks after; Cancel brings Teams back
    bob.eval("ns.RaidsUI:SetView('teams')")
    w.tick(0.3)
    bob.eval("ns.RaidPlanUI:SetDraftSize(10)")
    bob.eval("ns.MainFrame:Close()")
    assert bob.popups() == ["DISASTERZONE_TEAM_UNSAVED"]
    popup_click(bob, "DISASTERZONE_TEAM_UNSAVED", 3)
    w.tick(0.3)
    assert bob.eval("return ns.MainFrame:GetSelectedTab()") == "raids" and bob.eval("return ns.RaidsUI:GetView()") == "teams"
    assert bob.eval("return ns.RaidPlanUI:GetDraft().sz") == 10
    # Undo: back to the saved team, no question asked
    bob.click(bob.eval("return %s.revertBtn" % D))
    w.tick(0.3)
    assert bob.eval("return ns.RaidPlanUI:GetDraft().sz") == 25 and dirty_buttons(bob) == (False, False, False)
    bob.eval("ns.RaidPlanUI:SelectTeam(...)", a)
    assert bob.popups() == []
    w.assert_no_errors()


@case
def new_team_cancel_copy_and_clear_groups():
    w, c = world()
    bob = c["Bob"]
    a = team(bob, "Kara A", ["Lee", "Rita", "Sam"])
    bob.eval_py("local id, m = ...; return ns.RaidPlan:SaveTeam(id, 'Kara A', m, { size = 10, specs = { [m[1]] = 3 },"
                " groups = { [m[1]] = 1, [m[2]] = 2 } })", a, [K("Lee"), K("Rita"), K("Sam")])
    w.tick(2)
    open_teams(w, bob)
    # New team: a chip joins, the name is ready to type, Cancel drops it (an untouched draft doesn't ask)
    bob.click(bob.eval("return %s.newTeamBtn" % P))
    w.tick(0.3)
    assert shown(bob, TV + ".nameBox") and not bob.eval("return ns.RaidPlanUI:IsTeamBoard()")
    assert text_of(bob, D + ".status") == "New team, not saved" and text_of(bob, D + ".revertBtn") == "Cancel"
    assert not shown(bob, D + ".autoBtn")
    bob.eval("ns.RaidPlanUI:SetTeamTab('groups')")
    w.tick(0.3)
    assert bob.find_text("Add members with the search above", True, True)
    bob.eval("ns.RaidPlanUI:SelectTeam(...)", a)
    assert bob.popups() == []
    bob.click(bob.eval("return %s.newTeamBtn" % P))
    bob.eval("ns.RaidPlanUI:ToggleDraftMember(...)", K("Lee"))
    w.tick(0.3)
    bob.click(bob.eval("return %s.revertBtn" % D))
    w.tick(0.3)
    assert bob.eval("return ns.RaidPlanUI:GetSelectedTeam()") == a
    # ... > Copy: a new draft with the members, specs and groups, saved as "Kara A 2"
    bob.click(bob.eval("return %s.moreBtn" % D))
    menu = [strip_codes(e.get("text") or "").strip() for e in bob.last_menu()["children"] if e.get("text")]
    assert menu == ["Theme", "Copy", "Clear groups", "Delete"], menu
    menu_pick(bob, "Copy")
    w.tick(0.3)
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert dr.get("id") is None and dr["sz"] == 10 and dr["grp"] == {K("Lee"): 1, K("Rita"): 2}, dr
    assert bob.eval("return %s.nameBox:GetText()" % TV) == "Kara A 2"
    bob.click(bob.eval("return %s.saveBtn" % D))
    w.tick(1)
    names = sorted(t["name"] for t in bob.eval_py("return ns.RaidPlan:GetTeams()"))
    assert names == ["Kara A", "Kara A 2"], names
    # ... > Clear groups: everyone out of the groups, unsaved until Save
    bob.click(bob.eval("return %s.moreBtn" % D))
    menu_pick(bob, "Clear groups")
    w.tick(0.3)
    assert bob.eval_py("return ns.RaidPlanUI:GetDraft().grp") in ({}, [], None)
    assert dirty_buttons(bob) == (True, True, True)
    w.assert_no_errors()


@case
def delete_says_what_a_locked_raid_loses():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    a = team(bob, "Main", ["Rita", "Lee", "Sam"])
    occ = create(bob, i="ssc", t=now(bob) + 2 * DAY, tm=[a], lk=True)
    create(bob, i="mag", t=now(bob) + 3 * DAY, tm=[a])
    w.tick(2)
    signup(rita, occ, "A", 2)
    signup(c["Lee"], occ, "T")
    w.tick(2)
    open_teams(w, bob)
    text = strip_codes(bob.eval("return ns.RaidPlanUI:GetTeamDeleteText()"))
    assert "Delete the team Main?" in text, text
    assert "Serpentshrine Cavern and" in text and "Magtheridon's Lair invite it: its 3 players are no longer invited" in text, text
    assert "is locked to its teams: 2 answers from this team stop counting." in text, text
    bob.click(bob.eval("return %s.moreBtn" % D))
    menu_pick(bob, "Delete")
    assert bob.popups() == ["DISASTERZONE_TEAM_DELETE"]
    bob.accept_popup("DISASTERZONE_TEAM_DELETE")
    w.tick(2)
    assert rita.eval_py("return ns.RaidPlan:GetTeams()") == []
    # no teams: the empty card, its New team the only one
    assert shown(bob, TV + ".empty") and shown(bob, TV + ".empty.newBtn") and not shown(bob, P + ".newTeamBtn")
    w.assert_no_errors()


@case
def add_several_and_the_spec_from_the_role_icon():
    w, c = world()
    bob, rita, lee = c["Bob"], c["Rita"], c["Lee"]
    a = team(bob, "Main", ["Bob"])
    occ = create(bob, i="mag", t=now(bob) + 2 * DAY, tm=[a])
    w.tick(2)
    signup(rita, occ, "A", 2)
    signup(lee, occ, "A", 3)
    w.tick(2)
    w.make_party([bob, c["Sam"]])
    w.tick(1)
    open_teams(w, bob)
    bob.eval("ns.RaidPlanUI:SetTeamTab('groups')")
    w.tick(0.3)
    sd = TV + ".picker"
    bob.eval("%s:Open()" % sd)
    # its list hangs on UIParent (drawn over the page) but keeps a strata above the window (HIGH): a new parent hands
    # a frame its MEDIUM, and the list opened behind the window in game
    assert bob.eval("return %s.panel:GetFrameStrata()" % sd) == "FULLSCREEN_DIALOG"
    assert bob.eval("return %s.panel:IsShown()" % sd) is True
    items = bob.eval_py("local out = {}; for _, e in ipairs(%s:GetShown()) do out[#out + 1] = e.header or e.text end;"
                        " return out" % sd)
    items = list(items.values() if isinstance(items, dict) else items)
    assert items[:4] == ["ADD SEVERAL", "Everyone in my party", "Accepted for " + bob.eval(
        "local v = ns.RaidPlan:GetRaid(...); return date('%a', v.t) .. ' ' .. tonumber(date('%d', v.t))", occ)
        + " Magtheridon's Lair", "GUILD MEMBERS"], items
    assert strip_codes(bob.eval("return %s.footer.count:GetText()" % sd)) == "1 of 40 in the team"
    # a click on Accepted for ... adds both; the shortcut is gone then
    bob.eval("local sd = %s; for _, e in ipairs(sd:GetShown()) do if e.key == '@accepted' then sd:ToggleEntry(e) end end" % sd)
    w.tick(0.3)
    members = bob.eval_py("return ns.RaidPlanUI:GetDraft().members")
    assert members.get(K("Rita")) and members.get(K("Lee")), members
    keys = [e.get("key") for e in (lambda r: r.values() if isinstance(r, dict) else r)(
        bob.eval_py("return %s:GetShown()" % sd)) if isinstance(e, dict)]
    assert "@accepted" not in keys and "@group" in keys, keys
    assert strip_codes(bob.eval("return %s.footer.count:GetText()" % sd)) == "3 of 40 in the team"
    bob.eval("%s:Close()" % sd)
    # the role icon: a click opens the spec menu (Automatic says what it picked and from where)
    bob.eval("ns.RaidPlanUI:GetTeamGrid():Drop(..., 1)", K("Rita"))
    w.tick(0.3)
    rb = bob.eval("for _, ch in ipairs(ns.RaidPlanUI:GetTeamGrid().boxes[1].chips) do if ch.key == ... then"
                  " return ch.roleBtn end end", K("Rita"))
    assert bob.eval("local b = ...; return b:IsShown()", rb) is True
    bob.click(rb)
    menu = bob.last_menu()
    texts = [strip_codes(e.get("text") or "") for e in menu["children"]]
    assert texts[0] == "Rita" and texts[1] == "Automatic · Holy, from the last sign-up", texts
    assert texts[2:] == ["Discipline", "Holy", "Shadow"], texts
    bob.menu_select("Shadow")
    w.tick(0.3)
    assert bob.eval_py("return ns.RaidPlanUI:GetDraft().s")[K("Rita")] == 3
    # members get no role buttons
    open_teams(w, rita)
    assert rita.eval("local n = 0; for _, b in ipairs(ns.RaidPlanUI:GetTeamGrid().boxes) do for _, ch in ipairs(b.chips)"
                     " do if ch.roleBtn:IsShown() then n = n + 1 end end end; return n") == 0
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
