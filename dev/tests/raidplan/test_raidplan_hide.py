"""Raid planning (1.3.5): hiding a raid from my own board (another team's raid I won't go to).

Covers: Hide from the card's ... menu and its right-click (also on a locked raid I can only ask to join), the raid
leaving the board, the Home banner and the reminders on this account only, the when filter's "Hidden (n)" view and
"Show on my board again", a weekly raid hidden for one week or every week, and hidden entries of raids that are gone
being dropped.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_hide.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import world, K, DAY, now, team, create, call  # noqa: E402
from _common import case, run_all  # noqa: E402

P = "ns.RaidsUI:GetPanel()"


def open_tab(w, cl):
    cl.slash("/dz raids")
    w.tick(0.5)
    cl.eval("ns.RaidPlanUI:ShowBoard()")
    w.tick(0.3)


def listed(cl):
    """The raids on the Upcoming board, as drawn (ids)."""
    return list(cl.eval_py("""
      local out = {}
      for _, c in ipairs(ns.RaidsUI:GetPanel().upcoming.board.cards) do
        if c:IsShown() and c.__cdlData then out[#out + 1] = c.__cdlData.v.id end
      end
      return out""") or [])


def card(cl, occ):
    return cl.eval("for _, c in ipairs(ns.RaidsUI:GetPanel().upcoming.board.cards) do "
                   "if c:IsShown() and c.__cdlData and c.__cdlData.v.id == ... then return c end end", occ)


def menu_texts(cl):
    return [e.get("text") for e in (cl.last_menu() or {}).get("children", []) if e.get("text")]


def when_options(cl):
    return [e["text"] for e in cl.dropdown_menu(cl.eval("return %s.upcoming.whenDD" % P))["children"]]


def hidden(cl, occ):
    return cl.eval("return ns.RaidPlan:IsRaidHidden(...)", occ)


# ------------------------------------------------------------------------------------------------------------------
@case
def another_teams_raid_hides_from_my_board_only():
    w, c = world()
    bob, rita, lee = c["Bob"], c["Rita"], c["Lee"]
    other = team(bob, "Humble Klan", ["Lee", "Sam"])
    mine = team(bob, "Cat Aggro", ["Rita"])
    theirs = create(bob, i="kara", t=now(bob) + DAY, tm=[other])
    ours = create(bob, i="kara", t=now(bob) + DAY + 3600, tm=[mine])
    w.tick(2)
    open_tab(w, rita)
    assert listed(rita) == [theirs, ours]
    # the card's ... menu: the answers, Hide, Open the raid
    rita.click(rita.eval("return (...).more", card(rita, theirs)))
    texts = menu_texts(rita)
    assert "Accept" in texts and "Hide from my board" in texts and "Open the raid" in texts, texts
    rita.menu_select("Hide from my board")
    w.tick(0.3)
    assert hidden(rita, theirs) == "one"
    assert listed(rita) == [ours]
    # only on this account: nobody else's board changes, nothing is sent
    assert hidden(lee, theirs) is None and hidden(bob, theirs) is None
    open_tab(w, lee)
    assert theirs in listed(lee)
    # the when filter's Hidden view lists it, and shows it again
    assert when_options(rita)[-1] == "Hidden (1)"
    rita.menu_select("Hidden (1)")
    w.tick(0.3)
    assert listed(rita) == [theirs]
    rita.click(card(rita, theirs), "RightButton")
    texts = menu_texts(rita)
    assert "Show on my board again" in texts and "Hide from my board" not in texts, texts
    rita.menu_select("Show on my board again")
    w.tick(0.3)
    assert hidden(rita, theirs) is None
    # nothing hidden any more: back to every raid, no Hidden option
    assert rita.eval("return ns.db.raidplanHidden") is None
    assert listed(rita) == [theirs, ours]
    assert "Hidden (1)" not in when_options(rita)
    w.assert_no_errors()


@case
def a_hidden_invite_stops_reminding():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = team(bob, "Kara A", ["Rita"])
    occ = create(bob, i="kara", t=now(bob) + DAY, tm=[tid])
    w.tick(2)
    assert [v["id"] for v in rita.eval_py("return ns.RaidPlan:GetUnanswered(7)")] == [occ]
    assert rita.eval("return ns.RaidPlan:SetRaidHidden(..., true)", occ) is True
    assert list(rita.eval_py("return ns.RaidPlan:GetUnanswered(7)") or []) == []
    # its page still opens (a link, the calendar)
    open_tab(w, rita)
    rita.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.3)
    assert rita.eval("return ns.RaidPlanUI:GetPage()") == "raid"
    assert rita.eval("return ns.RaidPlanUI:GetSelectedRaid()") == occ
    w.assert_no_errors()


@case
def a_locked_raid_i_can_only_ask_to_join_has_the_menu_too():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = team(bob, "T1 Cat Aggro", ["Lee", "Sam"])
    occ = create(bob, i="kara", t=now(bob) + DAY, tm=[tid], lk=True)
    w.tick(2)
    open_tab(w, rita)
    assert occ in listed(rita)       # (locked raids are listed for everyone: Ask to join)
    cd = card(rita, occ)
    assert rita.eval("local c = ...; return c.more:IsShown()", cd) is True
    rita.click(rita.eval("return (...).more", cd))
    texts = menu_texts(rita)
    assert "Hide from my board" in texts and "Open the raid" in texts, texts
    assert "Accept" not in texts and "Bench" not in texts, texts          # (asking to join is the card's button)
    rita.menu_select("Hide from my board")
    w.tick(0.3)
    assert occ not in listed(rita)
    w.assert_no_errors()


@case
def a_weekly_raid_hides_one_week_or_every_week():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = team(bob, "Kara A", ["Lee"])
    occ0 = create(bob, i="ssc", t=now(bob) + DAY, tm=[tid], weekly=True)
    occ1 = occ0.replace("#0", "#1")
    w.tick(2)
    open_tab(w, rita)
    assert listed(rita)[:2] == [occ0, occ1]
    rita.click(rita.eval("return (...).more", card(rita, occ0)))
    texts = menu_texts(rita)
    assert "Hide this week" in texts and "Hide every week" in texts, texts
    rita.menu_select("Hide this week")
    w.tick(0.3)
    assert hidden(rita, occ0) == "one" and hidden(rita, occ1) is None
    assert occ0 not in listed(rita) and occ1 in listed(rita)
    rita.click(rita.eval("return (...).more", card(rita, occ1)))
    rita.menu_select("Hide every week")
    w.tick(0.3)
    assert hidden(rita, occ1) == "series" and hidden(rita, occ0) == "series"
    assert not [x for x in listed(rita) if x.startswith(occ0.split("#")[0])]
    assert when_options(rita)[-1] == "Hidden (2)"
    # showing one week again shows the series again
    assert rita.eval("return ns.RaidPlan:SetRaidHidden(..., false)", occ1) is True
    assert hidden(rita, occ1) is None and hidden(rita, occ0) == "one"
    # a raid deleted: its entry goes at the next change
    assert call(bob, "DeleteRaid", occ0, "series")["ok"] is True
    w.tick(2)
    other = create(bob, i="kara", t=now(bob) + 2 * DAY)
    w.tick(2)
    assert rita.eval("return ns.RaidPlan:SetRaidHidden(..., true)", other) is True
    keys = sorted((rita.eval_py("return ns.db.raidplanHidden") or {}).keys())
    assert keys == [other], keys
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
