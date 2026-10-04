"""Raid planning 1.3: a raid's own leader, named by the GM or a raid leader on the list (user decisions 2026-10-04).

Covers: naming a leader (the GM and the raid leaders list only, on any raid; not the guild council), the leader running
that raid (edit, cancel, groups, guests, delete) together with the GM and the raid leaders on the list, the guild
council not running a led raid, taking the leader off, weekly raids (a series leader, one week's own leader, a week with
none, series-wide edits for the series' leader), forged leaders (not named by the GM / a raid leader) being ignored, an
older client's copy without the leader not replacing the newer one, a council member's groups keeping a one-off raid
listed, and the Raid leader window and the raid's header (the crown icon, "led by", which icons each member gets).

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_raid_leader.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import world as rp_world, K, DAY, now, create, raid, raids, call  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

D = "ns.RaidsUI:GetPanel().upcoming.detail"
LW = "ns.RaidPlanUI:GetLeaderWindow()"


def world():
    """Gina = GM, Bob = guild council (rank 2: not an officer), Lee / Rita = on the raid leaders list, Sam / Vic =
    members."""
    return rp_world(names=(("Gina", 0, "PALADIN"), ("Bob", 2, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"),
                           ("Sam", 3, "ROGUE"), ("Vic", 3, "HUNTER")),
                    council=("Bob",), planners=("Lee", "Rita"))


def can(cl, fn, occ):
    return cl.eval("local fn, o = ...; return ns.RaidPlan[fn](ns.RaidPlan, o)", fn, occ)


def lead(cl, occ, name, scope=None):
    return call(cl, "EditRaid", occ, {"rl": K(name) if name else False}, scope)


# ------------------------------------------------------------------------------------------------------------------
@case
def the_raid_leaders_name_a_leader_who_runs_the_raid():
    w, c = world()
    gina, bob, lee, rita, sam, vic = (c[n] for n in ("Gina", "Bob", "Lee", "Rita", "Sam", "Vic"))
    occ = create(lee, i="kara", t=now(lee) + DAY)
    w.tick(2)
    # no leader yet: the raid leaders on the list run it; the council lays out groups
    assert raid(sam, occ).get("rl") is None
    assert can(rita, "CanManageRaid", occ) and not can(bob, "CanManageRaid", occ) and not can(sam, "CanManageRaid", occ)
    assert can(bob, "CanEditGroups", occ)
    # strategies and names: the raid leaders on the list and the GM only (the council reads them)
    assert can(rita, "CanAssignStrategies", occ) and can(gina, "CanAssignStrategies", occ)
    assert not can(bob, "CanAssignStrategies", occ) and not can(sam, "CanAssignStrategies", occ)
    assert lee.eval("return ns.RaidPlan:CanAssignLeader()") and gina.eval("return ns.RaidPlan:CanAssignLeader()")
    assert not bob.eval("return ns.RaidPlan:CanAssignLeader()")
    # only the GM and the raid leaders on the list name one (not the council, not a member)
    for x in (bob, sam):
        res = lead(x, occ, "Sam")
        assert res["ok"] is False and "choose a raid's leader" in res["e"], res
    assert lead(lee, occ, "Sam")["ok"] is True
    w.tick(2)
    for x in c.values():
        v = raid(x, occ)
        assert v["rl"] == K("Sam") and v["rlb"] == K("Lee"), v
        assert x.eval("return ns.RaidPlan:IsLeaderOf(...)", occ) is (x is sam)
    # the leader runs it: details, groups, guests, declines; everyone sees the changes
    assert call(sam, "EditRaid", occ, {"no": "Bring flasks", "lk": True, "inv": [K("Vic")]})["ok"] is True
    assert call(sam, "SetGroups", occ, {K("Lee"): 1, K("Vic"): 2})["ok"] is True
    assert call(sam, "AddGuest", occ, "Pugzor", "WARLOCK", 1)["ok"] is True
    w.tick(2)
    for x in c.values():
        v = raid(x, occ)
        assert v and v["no"] == "Bring flasks" and v["grp"][K("Vic")] == 2 and K("Pugzor") in v["gu"], (x.name, v)
    # the guild council doesn't run a led raid (not even its groups)
    for fn, args in (("EditRaid", ({"no": "x"},)), ("SetGroups", ({},)), ("AddGuest", ("Pug", "MAGE")),
                     ("CancelRaid", ()), ("DeleteRaid", ())):
        res = call(bob, fn, occ, *args)
        assert res["ok"] is False and "this raid's leader" in res["e"], (fn, res)
    assert not can(bob, "CanManageRaid", occ) and not can(bob, "CanEditGroups", occ)
    # ... a leader who is not on the list doesn't name another one
    assert lead(sam, occ, "Vic")["ok"] is False
    # the other raid leaders on the list and the GM run it with the leader
    assert can(rita, "CanManageRaid", occ) and can(rita, "CanEditGroups", occ)
    assert call(rita, "EditRaid", occ, {"no": "Rita's note"})["ok"] is True
    # ... but its strategies and names are the leader's and the GM's alone
    assert can(sam, "CanAssignStrategies", occ) and can(gina, "CanAssignStrategies", occ)
    for x in (rita, lee, bob, vic):
        assert not can(x, "CanAssignStrategies", occ), x.name
    assert call(gina, "SetGroups", occ, {K("Lee"): 1})["ok"] is True
    # a locked raid is listed for its leader even when they are not in it
    w.tick(2)
    assert occ in [v["id"] for v in raids(sam)]
    # the leader cancels, restores and deletes it
    assert call(sam, "CancelRaid", occ)["ok"] is True
    w.tick(2)
    assert raid(rita, occ)["cancelled"] is True
    assert call(sam, "EditRaid", occ, {"x": False})["ok"] is True
    w.tick(2)
    assert raid(rita, occ)["cancelled"] is False
    assert call(sam, "DeleteRaid", occ)["ok"] is True
    w.tick(2)
    assert all(raid(x, occ) is None for x in c.values())
    w.assert_no_errors()


@case
def taking_the_leader_off_leaves_the_raid_to_the_list():
    w, c = world()
    bob, lee, rita, sam = c["Bob"], c["Lee"], c["Rita"], c["Sam"]
    occ = create(lee, i="gruul", t=now(lee) + DAY)
    w.tick(2)
    assert lead(rita, occ, "Sam")["ok"] is True
    w.tick(2)
    assert call(sam, "EditRaid", occ, {"no": "Sam's note"})["ok"] is True
    w.tick(2)
    assert lead(lee, occ, None)["ok"] is True                              # any raid leader on the list takes it off
    w.tick(2)
    assert raid(lee, occ).get("rl") is None
    assert call(lee, "EditRaid", occ, {"no": "Lee again"})["ok"] is True
    assert call(sam, "EditRaid", occ, {"no": "x"})["ok"] is False
    assert call(bob, "SetGroups", occ, {K("Lee"): 1})["ok"] is True       # the council lays out an unled raid
    w.tick(2)
    assert raid(sam, occ)["no"] == "Lee again"
    w.assert_no_errors()


@case
def a_weekly_raid_has_a_leader_and_a_week_can_differ():
    w, c = world()
    bob, lee, rita, sam, vic = (c[n] for n in ("Bob", "Lee", "Rita", "Sam", "Vic"))
    occ0 = create(lee, i="ssc", t=now(lee) + DAY, weekly=True)
    sid = occ0.split("#")[0]
    occ1 = sid + "#1"
    w.tick(2)
    # every week: Sam
    assert lead(lee, occ0, "Sam", "series")["ok"] is True
    w.tick(2)
    assert raid(rita, occ0)["rl"] == K("Sam") and raid(rita, occ1)["rl"] == K("Sam")
    # week 1 only: Vic
    assert lead(lee, occ1, "Vic", "one")["ok"] is True
    w.tick(2)
    assert raid(rita, occ0)["rl"] == K("Sam") and raid(rita, occ1)["rl"] == K("Vic")
    # each runs their week; one week's edit by its leader (an override) reaches everyone
    assert call(sam, "EditRaid", occ0, {"no": "Sam's week"}, "one")["ok"] is True
    assert call(vic, "SetGroups", occ1, {K("Vic"): 1})["ok"] is True
    assert call(vic, "EditRaid", occ0, {"no": "x"}, "one")["ok"] is False
    assert call(sam, "EditRaid", occ1, {"no": "x"}, "one")["ok"] is False
    w.tick(2)
    assert raid(lee, occ0)["no"] == "Sam's week" and raid(lee, occ1)["grp"][K("Vic")] == 1
    # the whole series: its own leader (Sam), not a week's (Vic)
    assert call(vic, "EditRaid", occ1, {"no": "every week"}, "series")["ok"] is False
    assert call(vic, "StopRepeating", occ1)["ok"] is False
    assert call(sam, "EditRaid", occ0, {"sz": 10}, "series")["ok"] is True
    w.tick(2)
    assert raid(lee, occ1)["sz"] == 10
    # a week without a leader: only the list runs that week; the raid leaders on the list run the led weeks too
    assert lead(rita, occ1, None, "one")["ok"] is True
    w.tick(2)
    assert raid(rita, occ1).get("rl") is None and raid(rita, occ0)["rl"] == K("Sam")
    assert call(vic, "EditRaid", occ1, {"no": "x"}, "one")["ok"] is False
    assert call(lee, "EditRaid", occ1, {"no": "Lee's week"}, "one")["ok"] is True
    assert call(lee, "EditRaid", occ0, {"no": "Lee on Sam's week"}, "one")["ok"] is True
    w.tick(2)
    assert raid(sam, occ1)["no"] == "Lee's week"
    w.assert_no_errors()


@case
def a_leader_not_named_by_the_gm_or_a_raid_leader_is_ignored():
    w, c = world()
    bob, lee, sam, rita = c["Bob"], c["Lee"], c["Sam"], c["Rita"]
    occ = create(lee, i="kara", t=now(lee) + DAY)
    w.tick(2)

    def forge(cl, rid, extra):
        cl.eval("local o, rl, rlb = ...; local v = ns.RaidPlan:GetRaid(o) or { t = GetServerTime() + 86400, i = 'kara', "
                "sz = 10 }; ns.Comm:Send({ t = 'RPU', k = 'E', r = { id = o, rev = GetServerTime() + 1, "
                "by = ns.Util.PlayerKey(), t = v.t, i = v.i, sz = v.sz, rl = rl, rlb = rlb } }, 'GUILD', nil, 'data')",
                rid, *extra)
        w.tick(2)

    # the guild council (whose records are trusted: it lays out groups) names a leader on its own: no leader shows
    forge(bob, occ, (K("Sam"), K("Bob")))
    v = raid(rita, occ)
    assert v is not None and v.get("rl") is None, v
    assert not can(sam, "CanManageRaid", occ)
    # a member makes up a raid and leads it, "named by" themselves: it does not show
    forge(sam, "fake1", (K("Sam"), K("Sam")))
    assert raid(rita, "fake1") is None
    # a leader without who named them is refused outright
    forge(sam, "fake2", (K("Sam"),))
    assert raid(rita, "fake2") is None
    assert rita.eval("return ns.db.raidplan[next(ns.db.raidplan)].E.fake2") is None
    w.assert_no_errors()


@case
def an_older_copy_without_the_leader_does_not_win():
    w, c = world()
    bob, lee, rita = c["Bob"], c["Lee"], c["Rita"]
    occ = create(lee, i="kara", t=now(lee) + DAY)
    w.tick(2)
    assert lead(lee, occ, "Sam")["ok"] is True
    w.tick(2)
    # the same version passed on by a 1.2 client, which drops the fields it doesn't know; made so that it would win
    # the same-rev tie (the larger hash) if the leader didn't count
    res = rita.eval_py("local o = ...; local root = ns.db.raidplan[next(ns.db.raidplan)]; local e = root.E[o]; "
                       "local h = ns.Util.Hash(e); for i = 1, 200 do local copy = {}; "
                       "for k, v in pairs(e) do copy[k] = v end; copy.rl, copy.rlb = nil, nil; "
                       "copy.no = string.rep('~', 60 + i % 60) .. i; if ns.Util.Hash(copy) > h then return copy end end", occ)
    assert res is not None
    lee.eval("local r, o, to = ...; ns.Comm:Send({ t = 'RPG', o = o, e = r }, 'WHISPER', to, 'data')", res, occ, K("Rita"))
    w.tick(2)
    v = raid(rita, occ)
    assert v.get("rl") == K("Sam") and v.get("no") is None, v
    w.assert_no_errors()


@case
def council_groups_keep_a_one_off_raid_listed():
    w, c = world()
    bob, lee, sam = c["Bob"], c["Lee"], c["Sam"]
    occ = create(lee, i="kara", t=now(lee) + DAY)
    w.tick(2)
    assert call(bob, "SetGroups", occ, {K("Lee"): 1})["ok"] is True
    w.tick(2)
    for x in (bob, lee, sam):
        v = raid(x, occ)
        assert v is not None and v["grp"][K("Lee")] == 1, (x.name, v)
    w.assert_no_errors()


@case
def the_raid_leader_window_and_header():
    w, c = world()
    bob, lee, sam, rita = c["Bob"], c["Lee"], c["Sam"], c["Rita"]
    occ = create(lee, i="kara", t=now(lee) + DAY)
    w.tick(2)

    def header(cl):
        cl.slash("/dz raids")
        w.tick(0.3)
        cl.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
        w.tick(0.3)
        shown = cl.eval_py("local d = %s; return { edit = d.editBtn:IsShown(), cancel = d.cancelBtn:IsShown(), "
                           "invite = d.inviteBtn:IsShown(), leader = d.leaderBtn:IsShown(), sub = d.sub:GetText() }" % D)
        shown["sub"] = strip_codes(shown["sub"])
        return shown

    # the guild council gets no crown and runs nothing; a raid leader on the list gets everything
    h = header(bob)
    assert not h["leader"] and not h["edit"] and not h["cancel"], h
    assert "by Lee" in h["sub"] and "led by" not in h["sub"], h
    h = header(lee)
    assert h["edit"] and h["cancel"] and h["invite"] and h["leader"], h
    # Lee opens the window from the crown, picks Sam, saves
    lee.click(lee.eval("return %s.leaderBtn" % D))
    w.tick(0.2)
    assert lee.eval("return %s:IsShown()" % LW)
    assert "No raid leader" in strip_codes(lee.eval("return %s.pickText:GetText()" % LW))
    assert not lee.eval("return %s.saveAllBtn:IsShown()" % LW)
    # the member search lists the raid leaders first
    items = lee.eval_py("local w = %s; w.picker:Open(); return w.picker:GetShown()" % LW) or []
    texts = [i.get("header") or i.get("text") for i in items]
    assert texts[0] == "Raid leaders" and texts[1:3] == ["Lee", "Rita"], texts
    lee.eval("%s.picker:ToggleEntry(...)" % LW, [i for i in items if i.get("text") == "Sam"][0])
    assert "Sam leads this raid" in strip_codes(lee.eval("return %s.pickText:GetText()" % LW))
    lee.click(lee.eval("return %s.saveBtn" % LW))
    w.tick(2)
    assert not lee.eval("return %s:IsShown()" % LW)
    assert raid(rita, occ)["rl"] == K("Sam")
    # the other raid leaders on the list still run it; the leader runs it without the crown
    h = header(rita)
    assert "led by Sam" in h["sub"] and h["edit"] and h["leader"], h
    h = header(sam)
    assert h["edit"] and h["cancel"] and h["invite"] and not h["leader"], h
    h = header(bob)
    assert not h["edit"] and not h["cancel"] and not h["leader"], h
    # the title ends where the shown icons start
    right = sam.eval("local d = %s; for i = 1, d.title:GetNumPoints() do local p, _, _, x = d.title:GetPoint(i); "
                     "if p == 'RIGHT' then return x end end" % D)
    assert right == -(4 * 27 + 6), right   # share, cancel, edit, invite
    # Sam opens the editor; the council is told why not
    sam.eval("ns.RaidPlanUI:OpenEditor(...)", occ)
    assert sam.eval("return ns.RaidPlanUI:GetEditor():IsShown()")
    bob.eval("ns.RaidPlanUI:OpenEditor(...)", occ)
    assert not bob.eval("local e = ns.RaidPlanUI:GetEditor(); return e ~= nil and e:IsShown()")
    # No leader in the window takes it off
    rita.eval("ns.RaidPlanUI:OpenLeader(...)", occ)
    rita.click(rita.eval("return %s.noneBtn" % LW))
    rita.eval("ns.RaidPlanUI:SaveLeader('one')")
    w.tick(2)
    assert raid(sam, occ).get("rl") is None
    # members and the council don't get the window
    assert sam.eval("return ns.RaidPlanUI:OpenLeader(...)", occ) is False
    assert bob.eval("return ns.RaidPlanUI:OpenLeader(...)", occ) is False
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
