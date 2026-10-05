"""The Raids makeover (2026-10-05): the Upcoming board of raid cards and a raid's page, on the real addon.

Covers: answering from a card without opening the raid (the card then shows the answer), a card opening its page and
"All raids" going back, the note under the answers (opens in place, Escape keeps the old note, Enter saves it), the
banner's answers hidden (not greyed) with the reason when sign-ups are closed, and the Groups tab's drag and drop (the
dragged player leaves the layout while dragged, the spot under the cursor lights up, the drop lands there).

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_page.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import world, K, DAY, now, create, signup, signups  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

P = "ns.RaidsUI:GetPanel()"
D = P + ".upcoming.detail"
GRID = "ns.RaidPlanUI:GetRaidGrid()"

CARD = """
  local occ = ...
  local found
  ns.RaidsUI:GetPanel().upcoming.list.box:ForEachFrame(function(c)
    if c.__cdlData and c.__cdlData.v and c.__cdlData.v.id == occ then found = c end
  end)
  return found"""


def open_tab(w, cl):
    cl.slash("/dz raids")
    w.tick(0.5)


def shown(cl, expr, *args):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr, *args) is True


def chip_of(cl, key):
    return cl.eval("local g = %s; for gi, box in ipairs(g.boxes) do for _, ch in ipairs(box.chips) do "
                   "if box:IsShown() and ch.key == ... then return ch end end end" % GRID, key)


# ------------------------------------------------------------------------------------------------------------------
@case
def a_card_answers_and_opens_the_raid():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    occ = create(bob, i="kara", t=now(bob) + DAY, ti="Kara full clear")
    w.tick(2)
    open_tab(w, rita)
    assert rita.eval("return ns.RaidPlanUI:GetPage()") == "board"
    card = rita.eval(CARD, occ)
    assert card is not None
    assert rita.find_text("Kara full clear", True, True) and rita.find_text("No answers yet", True, True)
    assert shown(rita, "(...).accept", card) and shown(rita, "(...).tentative", card)
    rita.click(rita.eval("return (...).accept", card))
    w.tick(2)
    assert signups(bob, occ)[K("Rita")]["st"] == "A"
    # answered: the card shows the answer instead of the buttons
    assert shown(rita, "(...).pill", card) and not shown(rita, "(...).accept", card)
    assert rita.find_text("Accepted", True, True)
    # a click opens the raid's page; All raids goes back to the board
    rita.click(card)
    w.tick(0.3)
    assert rita.eval("return ns.RaidPlanUI:GetPage()") == "raid"
    assert rita.eval("return %s.statusBtns.A.chosen" % (P + ".upcoming")) is True
    rita.click(rita.eval("return %s.back" % D))
    w.tick(0.3)
    assert rita.eval("return ns.RaidPlanUI:GetPage()") == "board"
    w.assert_no_errors()


@case
def the_note_opens_in_place_escape_keeps_the_old_one():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    assert signup(rita, occ, "A", None, "late 10")["ok"] is True
    w.tick(2)
    open_tab(w, rita)
    rita.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.3)
    link = rita.eval("return %s.noteLink" % D)
    box = rita.eval("return %s.upcoming.noteBox" % P)
    assert strip_codes(rita.eval("return (...).fs:GetText()", link)) == '"late 10"'
    assert not rita.eval("return (...):IsShown()", box)
    # a click turns the link into the field at once (laid out where the link was)
    rita.click(link)
    assert rita.eval("return (...):IsShown()", box) is True and rita.eval("return (...):IsShown()", link) is False
    assert rita.eval("local b = ...; local p = select(2, b:GetPoint(1)); return p == ns.RaidsUI:GetPanel()"
                     ".upcoming.detail.mine", box) is True
    rita.type_text(box, "late 30")
    rita.press_escape(box)
    w.tick(0.3)
    assert not rita.eval("return (...):IsShown()", box)
    assert strip_codes(rita.eval("return (...).fs:GetText()", link)) == '"late 10"'
    assert signups(bob, occ)[K("Rita")]["n"] == "late 10"
    # Enter keeps it (an answer already given: sent at once)
    rita.click(link)
    rita.type_text(box, "late 30", True)
    w.tick(2)
    assert signups(bob, occ)[K("Rita")]["n"] == "late 30"
    assert strip_codes(rita.eval("return (...).fs:GetText()", link)) == '"late 30"'
    w.assert_no_errors()


@case
def closed_sign_ups_hide_the_answers_and_say_why():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    occ = create(bob, i="kara", t=now(bob) + 120)
    w.tick(2)
    assert signup(rita, occ, "T")["ok"] is True
    w.tick(7 * 3600, step=300)                 # the raid started over six hours ago: sign-ups are closed
    open_tab(w, rita)
    rita.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.3)
    assert not shown(rita, P + ".upcoming.statusBtns.A")
    assert rita.find_text("Sign-ups are closed.", True, True)
    assert shown(rita, D + ".pill")                       # the answer I had, as a pill
    w.assert_no_errors()


@case
def dragging_a_player_lifts_them_and_lands_where_the_spot_lights_up():
    w, c = world()
    bob = c["Bob"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    for n, sp in (("Lee", 3), ("Rita", 2), ("Sam", 1)):
        assert signup(c[n], occ, "A", sp)["ok"] is True
    w.tick(2)
    open_tab(w, bob)
    bob.eval("ns.RaidPlanUI:SelectRaid(...); ns.RaidPlanUI:SetDetailTab('groups')", occ)
    w.tick(0.3)
    src = chip_of(bob, K("Lee"))
    assert src is not None
    bob.eval("_G.IsMouseButtonDown = function() return true end")
    bob.eval("%s:BeginDrag(...)" % GRID, src)
    # while dragged, Lee is out of the layout (the seat empties)
    assert chip_of(bob, K("Lee")) is None
    # over group 2's third seat: it lights up
    bob.eval("local g = %s; g.boxes[2].IsMouseOver = function() return true end; "
             "g.boxes[2].chips[3].IsMouseOver = function() return true end" % GRID)
    w.tick(0.2)
    assert bob.eval("local m = %s.marker; return m ~= nil and m:IsShown()" % GRID) is True
    bob.eval("%s:EndDrag()" % GRID)
    bob.eval("_G.IsMouseButtonDown = function() return false end; local g = %s; g.boxes[2].IsMouseOver = nil; "
             "g.boxes[2].chips[3].IsMouseOver = nil" % GRID)
    w.tick(0.3)
    dr = bob.eval_py("return ns.RaidPlanUI:GetRaidDraft()")
    assert dr["grp"][K("Lee")] == 2 and dr["gs"][K("Lee")] == 3, dr
    assert not bob.eval("return %s.marker:IsShown()" % GRID)
    # a drop on nothing puts the player back
    src = chip_of(bob, K("Rita"))
    bob.eval("_G.IsMouseButtonDown = function() return true end")
    bob.eval("%s:BeginDrag(...)" % GRID, src)
    bob.eval("%s:EndDrag()" % GRID)
    bob.eval("_G.IsMouseButtonDown = function() return false end")
    assert chip_of(bob, K("Rita")) is not None
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
