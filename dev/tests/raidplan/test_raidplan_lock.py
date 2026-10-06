"""Raid planning 1.0: a raid locked to its teams, with extra invites for players outside them.

Covers: an open raid with teams taking everyone's sign-up, a locked raid taking only its teams' members and its extra
invites (private: refused on the member's own client, not counted when it arrives anyway, and not listed for anyone
else but the GM, the guild council and the raid leaders), inviting a player later, unlocking, requests to join a locked
raid that is not private (listed for everyone, approved or denied by who runs it),
an invite-only raid without a team, one week of a weekly raid differing from its series, and the New / Edit raid window
and the sign-up strip.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_lock.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import world, K, DAY, now, team, create, raid, raids, signup, signups, call  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

P = "ns.RaidsUI:GetPanel()"
ED = "ns.RaidPlanUI:GetEditor()"


def can(cl, occ, name=None):
    return cl.eval("return ns.RaidPlan:CanSignUp(...)", occ, K(name) if name else None)


def forged_signup(cl, occ):
    """A sign-up sent past the local check (an older client, a tampered one)."""
    cl.eval("local o = ...; local _, c = UnitClass('player'); ns.Comm:Send({ t = 'RPS', l = { { o = o, "
            "s = { st = 'A', rev = GetServerTime(), c = c } } } }, 'GUILD', nil, 'data')", occ)


# ------------------------------------------------------------------------------------------------------------------
@case
def a_locked_raid_takes_only_its_teams_and_invites():
    w, c = world()
    bob, lee, rita, sam = c["Bob"], c["Lee"], c["Rita"], c["Sam"]
    tid = team(bob, "Kara A", ["Lee", "Gina"])
    # open: the team says who is expected, everyone signs up
    open_occ = create(bob, i="kara", t=now(bob) + DAY, tm=[tid])
    occ = create(bob, i="kara", t=now(bob) + 2 * DAY, tm=[tid], lk=True, pv=True, inv=[K("Sam")])
    w.tick(2)
    v = raid(rita, open_occ)
    assert v["lk"] is False and list(v["inv"] or []) == [], v
    assert rita.eval("return ns.RaidPlan:IsLocked(...)", open_occ) is False
    assert signup(rita, open_occ, "A")["ok"] is True
    v = raid(rita, occ)
    assert v["lk"] is True and list(v["inv"]) == [K("Sam")], v
    assert rita.eval("return ns.RaidPlan:IsLocked(...)", occ) is True
    assert sorted(rita.eval_py("local out = {}; for k in pairs(ns.RaidPlan:GetInvited(...)) do out[#out + 1] = k end; "
                               "return out", occ)) == sorted([K("Lee"), K("Gina"), K("Sam")])
    assert can(lee, occ) and can(sam, occ) and not can(rita, occ) and not can(bob, occ)
    assert can(bob, occ, "Sam") and not can(bob, occ, "Rita")
    assert signup(lee, occ, "A")["ok"] is True          # in the team
    assert signup(sam, occ, "T")["ok"] is True          # invited on top
    res = signup(rita, occ, "A")
    assert res["ok"] is False and "private" in res["e"], res
    # listed for the team, the invited player and those who plan raids (Bob, Gina); not for Rita
    for n, x in c.items():
        ids = [v["id"] for v in raids(x)]
        assert ids == ([open_occ] if n == "Rita" else [open_occ, occ]), (n, ids)
        assert x.eval("return ns.RaidPlan:CanSee(...)", occ) is (n != "Rita"), n
    assert [v["id"] for v in raids(rita, None, None, True)] == [open_occ, occ]
    # the invited player without an answer is waited for
    assert [x["id"] for x in c["Gina"].eval_py("return ns.RaidPlan:GetUnanswered(7)")] == [open_occ, occ]
    # a sign-up that arrives anyway is not counted
    forged_signup(rita, occ)
    w.tick(2)
    for x in (bob, lee, rita):
        assert sorted(signups(x, occ)) == sorted([K("Lee"), K("Sam")]), signups(x, occ)
    assert rita.eval("return ns.RaidPlan:GetMySignup(...)", occ) is None
    assert all(m["key"] != K("Rita") for m in bob.eval_py("return ns.RaidPlan:GetLayoutMembers(...)", occ))
    # invited later: the answer counts
    assert call(bob, "EditRaid", occ, {"inv": [K("Sam"), K("Rita")]})["ok"] is True
    w.tick(2)
    assert sorted(signups(lee, occ)) == sorted([K("Lee"), K("Sam"), K("Rita")])
    assert [v["id"] for v in raids(rita)] == [open_occ, occ]
    assert signup(rita, occ, "B")["ok"] is True
    # taken off again, then the lock goes: everyone signs up
    assert call(bob, "EditRaid", occ, {"inv": []})["ok"] is True
    w.tick(2)
    assert list(raid(lee, occ)["inv"] or []) == [] and K("Sam") not in signups(lee, occ)
    assert call(bob, "EditRaid", occ, {"lk": False})["ok"] is True
    w.tick(2)
    assert raid(lee, occ)["lk"] is False
    assert sorted(signups(lee, occ)) == sorted([K("Lee"), K("Sam"), K("Rita")])
    assert signup(c["Bob"], occ, "A")["ok"] is True
    # members can't lock or invite
    assert call(rita, "EditRaid", occ, {"lk": True})["ok"] is False
    w.assert_no_errors()


@case
def invite_only_and_a_lock_without_anyone():
    w, c = world()
    bob, rita, sam = c["Bob"], c["Rita"], c["Sam"]
    # no team, two invites, locked: invite-only
    occ = create(bob, i="za", t=now(bob) + DAY, lk=True, pv=True, inv=[K("Sam"), K("Rita"), K("Sam")])
    # locked without a team or an invite: nobody to lock it to, so it stays open
    odd = create(bob, i="za", t=now(bob) + 2 * DAY, lk=True)
    w.tick(2)
    assert list(raid(sam, occ)["inv"]) == [K("Rita"), K("Sam")]
    assert signup(sam, occ, "A")["ok"] is True and signup(c["Lee"], occ, "A")["ok"] is False
    assert sam.eval("return ns.RaidPlan:IsLocked(...)", odd) is False
    assert signup(c["Lee"], odd, "A")["ok"] is True
    # bad invite lists are refused
    assert call(bob, "EditRaid", occ, {"inv": ["a|b"]})["ok"] is False
    assert call(bob, "EditRaid", occ, {"inv": ["P%d-X" % i for i in range(41)]})["ok"] is False
    bob.eval("ns.Comm:Send({ t = 'RPU', k = 'E', r = { id = 'zz1', rev = GetServerTime(), by = ns.Util.PlayerKey(), "
             "t = GetServerTime() + 86400, i = 'za', sz = 10, lk = 'yes' } }, 'GUILD', nil, 'data')")
    w.tick(2)
    assert raid(sam, "zz1") is None
    w.assert_no_errors()


@case
def one_week_of_a_weekly_raid_differs():
    w, c = world()
    bob, rita, lee = c["Bob"], c["Rita"], c["Lee"]
    tid = team(bob, "Main", ["Lee"])
    occ0 = create(bob, i="ssc", t=now(bob) + DAY, tm=[tid], lk=True, pv=True, weekly=True)
    occ1 = occ0.replace("#0", "#1")
    w.tick(2)
    assert raid(rita, occ0)["lk"] is True and raid(rita, occ1)["lk"] is True
    assert signup(rita, occ1, "A")["ok"] is False
    # this week only: open
    assert call(bob, "EditRaid", occ1, {"lk": False}, "one")["ok"] is True
    w.tick(2)
    assert raid(rita, occ0)["lk"] is True and raid(rita, occ1)["lk"] is False
    assert signup(rita, occ1, "A")["ok"] is True and signup(rita, occ0, "A")["ok"] is False
    # every week: an invite; the week that was opened stays open
    assert call(bob, "EditRaid", occ0, {"inv": [K("Rita")]}, "series")["ok"] is True
    w.tick(2)
    assert list(raid(lee, occ0)["inv"]) == [K("Rita")] and list(raid(lee, occ1)["inv"]) == [K("Rita")]
    assert signup(rita, occ0, "A")["ok"] is True
    assert raid(lee, occ1)["lk"] is False
    # one week without the invite
    assert call(bob, "EditRaid", occ0, {"inv": []}, "one")["ok"] is True
    w.tick(2)
    assert list(raid(lee, occ0)["inv"] or []) == [] and list(raid(lee, occ1)["inv"]) == [K("Rita")]
    assert K("Rita") not in signups(lee, occ0)
    w.assert_no_errors()


def lst_keys(cl):
    """The invited players shown as chips in the raid sheet."""
    v = cl.eval_py("local out = {}; for _, p in ipairs(ns.RaidPlanUI:GetEditor().chips) do if p:IsShown() and "
                   "p.kind == 'player' then out[#out + 1] = p.key end end; return out")
    return list(v.values()) if isinstance(v, dict) else list(v or [])


def open_tab(w, cl):
    cl.slash("/dz raids")
    w.tick(0.5)


@case
def the_raid_window_and_the_sign_up_strip():
    w, c = world()
    bob, rita, sam = c["Bob"], c["Rita"], c["Sam"]
    tid = team(bob, "Kara A", ["Lee"])
    w.tick(1)
    open_tab(w, bob)
    # a new raid: locked needs a team or an invite
    bob.eval("ns.RaidPlanUI:OpenEditor()")
    # (Sign-ups: Everyone | Teams + invited | Private)
    assert bob.eval("return %s.f.lk" % ED) is False and bob.eval("return %s.access[1].kind" % ED) == "chosen"
    bob.click(bob.eval("return %s.access[2]" % ED))
    assert bob.eval("return %s.f.lk" % ED) is True and bob.eval("return %s.access[2].kind" % ED) == "chosen"
    bob.click(bob.eval("return %s.saveBtn" % ED))
    assert "needs a team" in bob.eval("return %s.err:GetText()" % ED)
    # the invite picker: team members are in already, others are ticked
    bob.eval("%s.f.tm[...] = true" % ED, tid)
    items = {e["key"]: e for e in bob.eval_py("local sd = %s.invPicker; sd:Open(); return sd:GetShown()" % ED) if "key" in e}
    assert items[K("Lee")].get("fixed") == "Kara A" and not items[K("Sam")].get("fixed"), items
    bob.eval("local key = ...; local sd = %s.invPicker; for _, e in ipairs(sd:GetShown()) do "
             "if e.key == key then sd:ToggleEntry(e) end end" % ED, K("Sam"))
    assert lst_keys(bob) == [K("Sam")]                              # (an invited player: a pill)
    bob.click(bob.eval("return %s.saveBtn" % ED))
    w.tick(2)
    occ = bob.eval("return ns.RaidPlanUI:GetSelectedRaid()")
    v = raid(rita, occ)
    assert v["lk"] is True and list(v["inv"]) == [K("Sam")] and list(v["tm"]) == [tid], v
    assert bob.find_text("Kara A +1 invited", True, True) and bob.find_text("Locked", True, True)
    # the raid leader is not in it: the answers are off and the strip says why
    assert bob.eval("return %s.upcoming.statusBtns.A:IsEnabled()" % P) is False
    assert bob.find_text("you are not in this raid (Invite adds you)", True, True)
    bob.eval("ns.RaidPlanUI:ShowBoard()")
    w.tick(0.3)
    assert bob.find_text("Not invited", True, True)                  # the card says it too
    bob.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.3)
    # a member who is not invited sees the raid and answers to ask to join
    open_tab(w, rita)
    rita.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.5)
    assert rita.eval("return %s.upcoming.statusBtns.A:IsEnabled()" % P) is True
    assert rita.find_text("pick an answer to ask to join", True, True)
    open_tab(w, sam)
    sam.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.5)
    assert sam.eval("return %s.upcoming.statusBtns.A:IsEnabled()" % P) is True
    sam.click(sam.eval("return %s.upcoming.statusBtns.A" % P))
    w.tick(2)
    assert list(signups(bob, occ)) == [K("Sam")]
    # editing shows the lock and the invites; unticking the lock opens the raid
    bob.eval("ns.RaidPlanUI:OpenEditor(...)", occ)
    assert bob.eval("return %s.f.lk" % ED) is True and bob.eval("return %s.f.access" % ED) == "locked"
    assert bob.eval("return %s.f.inv[...]" % ED, K("Sam")) is True
    bob.click(bob.eval("return %s.access[1]" % ED))
    bob.click(bob.eval("return %s.saveBtn" % ED))
    w.tick(2)
    assert raid(rita, occ)["lk"] is False and list(raid(rita, occ)["inv"]) == [K("Sam")]
    w.tick(1)
    assert rita.find_text("Karazhan", True, True) and rita.find_text("10-player", True, True)
    assert rita.eval("return ns.RaidPlanUI:GetSelectedRaid()") == occ
    assert rita.eval("return %s.upcoming.statusBtns.A:IsEnabled()" % P) is True
    w.assert_no_errors()


@case
def the_invite_button_and_window():
    w, c = world()
    bob, rita, lee = c["Bob"], c["Rita"], c["Lee"]
    tid = team(bob, "Kara A", ["Lee"])
    occ = create(bob, i="kara", t=now(bob) + DAY, tm=[tid], lk=True, pv=True)
    w.tick(2)
    win = "ns.RaidPlanUI:GetInviteWindow()"
    # a raid planner outside the raid: the banner points at Invite
    open_tab(w, bob)
    bob.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.3)
    assert bob.eval("return %s.upcoming.detail.inviteBtn:IsShown()" % P) is True
    assert bob.find_text("you are not in this raid (Invite adds you)", True, True)
    bob.click(bob.eval("return %s.upcoming.detail.inviteBtn" % P))
    assert bob.eval("return %s:IsShown()" % win) is True
    assert bob.find_text("Nobody added yet.", True, True)
    items = {e["key"]: e for e in bob.eval_py("local sd = %s.picker; sd:Open(); return sd:GetShown()" % win)}
    assert items[K("Lee")].get("fixed") == "Kara A" and not items[K("Rita")].get("fixed")
    # inviting is shared at once: the raid shows up for Rita, and Bob can answer after adding himself
    assert rita.eval("return ns.RaidPlan:CanSee(...)", occ) is False
    assert bob.eval("return ns.RaidPlanUI:ToggleInvite(...)", K("Rita")) is True
    assert bob.eval("return ns.RaidPlanUI:ToggleInvite(...)", K("Bob")) is True
    w.tick(2)
    assert list(raid(lee, occ)["inv"]) == [K("Bob"), K("Rita")]
    assert signup(rita, occ, "A")["ok"] is True
    assert [r["key"] for r in bob.eval_py("return %s.list:GetData()" % win)] == [K("Bob"), K("Rita")]
    assert bob.find_text("2 invited", True, True)
    assert bob.eval("return %s.upcoming.statusBtns.A:IsEnabled()" % P) is True
    # the X of a row takes the invite back
    bob.eval("local key = ...; local w = %s; w.list.box:ForEachFrame(function(row) if row.__cdlData.key == key then "
             "row.remove:GetScript('OnClick')(row.remove) end end)" % win, K("Rita"))
    w.tick(2)
    assert list(raid(lee, occ)["inv"]) == [K("Bob")] and rita.eval("return ns.RaidPlan:CanSee(...)", occ) is False
    # members have no Invite button and can't open the window
    open_tab(w, lee)
    lee.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.3)
    assert lee.eval("return %s.upcoming.detail.inviteBtn:IsShown()" % P) is False
    assert lee.eval("return ns.RaidPlanUI:OpenInvites(...)", occ) is False
    # the raid is deleted: the window closes
    assert call(bob, "DeleteRaid", occ)["ok"] is True
    w.tick(1)
    assert bob.eval("return %s:IsShown()" % win) is False
    w.assert_no_errors()


@case
def requests_to_join_a_locked_raid():
    w, c = world()
    bob, lee, rita, sam = c["Bob"], c["Lee"], c["Rita"], c["Sam"]
    tid = team(bob, "Kara A", ["Lee"])
    occ = create(bob, i="kara", t=now(bob) + DAY, tm=[tid], lk=True)
    w.tick(2)
    # listed for everyone; members outside ask, who runs it invites themselves
    assert [v["id"] for v in raids(rita)] == [occ]
    assert rita.eval("return ns.RaidPlan:CanRequest(...)", occ) is True
    assert lee.eval("return ns.RaidPlan:CanRequest(...)", occ) is False
    assert bob.eval("return ns.RaidPlan:CanRequest(...)", occ) is False
    assert signup(bob, occ, "A")["ok"] is False
    # the answer is a request: not counted, listed for the roster
    assert signup(rita, occ, "A", None, "can heal")["ok"] is True
    assert signup(sam, occ, "T")["ok"] is True
    w.tick(2)
    assert signups(bob, occ) == {} or K("Rita") not in signups(bob, occ)
    reqs = bob.eval_py("return ns.RaidPlan:GetRequests(...)", occ)
    assert [r["key"] for r in reqs] == [K("Rita"), K("Sam")], reqs
    assert reqs[0]["n"] == "can heal"
    assert rita.eval_py("return ns.RaidPlan:GetMyRequest(...)", occ)["key"] == K("Rita")
    assert bob.eval("return (ns.RaidPlan:GetPendingRequests())") == 2
    # members can't answer requests
    assert call(lee, "ApproveRequest", occ, K("Rita"))["ok"] is False
    # approve: invited to this raid, the answer counts; deny: declined
    assert call(bob, "ApproveRequest", occ, K("Rita"))["ok"] is True
    assert call(bob, "DeclineSignup", occ, K("Sam"))["ok"] is True
    w.tick(2)
    assert list(raid(lee, occ)["inv"]) == [K("Rita")]
    assert K("Rita") in signups(lee, occ) and K("Sam") not in signups(lee, occ)
    assert lee.eval_py("return ns.RaidPlan:GetRequests(...)", occ) in ([], {}, None)
    assert sam.eval("return ns.RaidPlan:GetSignupBlock(...)", occ) == "declined"
    assert signup(sam, occ, "A")["ok"] is False
    # withdrawing: Absent takes the request back
    occ2 = create(bob, i="kara", t=now(bob) + 2 * DAY, tm=[tid], lk=True)
    w.tick(2)
    assert signup(sam, occ2, "A")["ok"] is True
    assert signup(sam, occ2, "X")["ok"] is True
    w.tick(2)
    assert bob.eval_py("return ns.RaidPlan:GetRequests(...)", occ2) in ([], {}, None)
    # private: hidden again, no requests
    assert call(bob, "EditRaid", occ2, {"pv": True})["ok"] is True
    w.tick(2)
    assert raid(sam, occ2)["pv"] is True and [v["id"] for v in raids(sam)] == [occ]
    assert sam.eval("return ns.RaidPlan:CanRequest(...)", occ2) is False
    assert "private" in signup(sam, occ2, "A")["e"]
    # the roster shows the request; who runs it opens approve / deny with a click
    occ3 = create(bob, i="kara", t=now(bob) + 3 * DAY, tm=[tid], lk=True)
    w.tick(2)
    assert signup(rita, occ3, "A")["ok"] is True
    w.tick(2)
    open_tab(w, bob)
    bob.eval("ns.RaidPlanUI:SelectRaid(...)", occ3)
    w.tick(0.5)
    assert any("Requests to join (1)" in strip_codes(bob.eval("local o = ...; return o:GetText()", o) or "")
               for o in bob.find_text("Requests to join", True, True))
    bob.eval("ns.RaidPlanUI:ShowBoard()")
    w.tick(0.3)
    assert bob.find_text("1 request", True, True)                     # on the raid's card
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
