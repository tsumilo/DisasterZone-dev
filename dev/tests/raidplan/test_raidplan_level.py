"""Raid planning: a raid's minimum character level (level 70 unless the planner allows lower characters).

Covers: a raid with a minimum level refusing a lower character on its own client and not counting an answer that
arrives anyway, the raid staying listed for that character, raids without the field taking everyone, one week of a
weekly raid differing from its series, malformed levels, and the New / Edit raid window (the box is unticked on a new
raid, ticked on a raid made before the field existed) with the sign-up strip.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_level.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import World, Client, gm_pick, set_raid_leaders, K, DAY, now, team, create, raid, raids, signup, \
    signups, call  # noqa: E402
from _common import case, run_all  # noqa: E402

P = "ns.RaidsUI:GetPanel()"
ED = "ns.RaidPlanUI:GetEditor()"


def world():
    """Gina = GM, Bob = raid leader, Lee = a level 70 member, Tiny = a level 12 alt."""
    w = World()
    c = {}
    for name, rank, cls, level in (("Gina", 0, "PALADIN", 70), ("Bob", 1, "MAGE", 70), ("Lee", 3, "WARRIOR", 70),
                                   ("Tiny", 3, "WARRIOR", 12)):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls, level=level)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ("Bob",))
    w.tick(2)
    return w, c


def block(cl, occ, name=None):
    return cl.eval("return ns.RaidPlan:GetSignupBlock(...)", occ, K(name) if name else None)


def forged_signup(cl, occ):
    """A sign-up sent past the local check (an older client, a tampered one)."""
    cl.eval("local o = ...; local _, c = UnitClass('player'); ns.Comm:Send({ t = 'RPS', l = { { o = o, "
            "s = { st = 'A', rev = GetServerTime(), c = c } } } }, 'GUILD', nil, 'data')", occ)


# ------------------------------------------------------------------------------------------------------------------
@case
def a_level_70_raid_takes_only_level_70_characters():
    w, c = world()
    bob, lee, tiny = c["Bob"], c["Lee"], c["Tiny"]
    anyone = create(bob, i="kara", t=now(bob) + DAY)
    occ = create(bob, i="kara", t=now(bob) + 2 * DAY, ml=70)
    w.tick(2)
    assert raid(tiny, anyone).get("ml") is None and raid(tiny, occ)["ml"] == 70
    assert tiny.eval("return ns.RaidPlan:GetMinLevel(...)", occ) == 70
    assert tiny.eval("return ns.RaidPlan:GetMinLevel(...)", anyone) is None
    # no minimum: everyone signs up
    assert signup(tiny, anyone, "A")["ok"] is True
    # level 70 only: refused on the low character's own client, and every client knows why
    res = signup(tiny, occ, "A")
    assert res["ok"] is False and "level 70" in res["e"], res
    assert signup(lee, occ, "A")["ok"] is True
    assert block(tiny, occ) == "level" and block(lee, occ) is None
    assert block(bob, occ, "Tiny") == "level" and block(bob, occ, "Lee") is None
    assert tiny.eval("return ns.RaidPlan:CanSignUp(...)", occ) is False
    # the raid stays listed for the low character (a lock hides, a level doesn't)
    assert [v["id"] for v in raids(tiny)] == [anyone, occ]
    assert tiny.eval("return ns.RaidPlan:CanSee(...)", occ) is True
    # an answer that arrives anyway is not counted
    forged_signup(tiny, occ)
    w.tick(2)
    for x in (bob, lee, tiny):
        assert sorted(signups(x, occ)) == [K("Lee")], signups(x, occ)
    assert tiny.eval("return ns.RaidPlan:GetMySignup(...)", occ) is None
    # the planner allows lower characters: the answer counts
    assert call(bob, "EditRaid", occ, {"ml": 0})["ok"] is True
    w.tick(2)
    assert raid(lee, occ).get("ml") is None
    assert sorted(signups(lee, occ)) == sorted([K("Lee"), K("Tiny")])
    assert signup(tiny, occ, "T")["ok"] is True
    # and back
    assert call(bob, "EditRaid", occ, {"ml": 70})["ok"] is True
    w.tick(2)
    assert sorted(signups(lee, occ)) == [K("Lee")]
    # members can't change it; malformed levels are refused
    assert call(lee, "EditRaid", occ, {"ml": 0})["ok"] is False
    assert call(bob, "EditRaid", occ, {"ml": 71})["ok"] is False
    assert call(bob, "EditRaid", occ, {"ml": 1.5})["ok"] is False
    bob.eval("ns.Comm:Send({ t = 'RPU', k = 'E', r = { id = 'zz1', rev = GetServerTime(), by = ns.Util.PlayerKey(), "
             "t = GetServerTime() + 86400, i = 'za', sz = 10, ml = 'yes' } }, 'GUILD', nil, 'data')")
    w.tick(2)
    assert raid(lee, "zz1") is None
    w.assert_no_errors()


@case
def a_team_member_below_the_level_is_not_waited_for():
    w, c = world()
    bob, tiny = c["Bob"], c["Tiny"]
    tid = team(bob, "Kara A", ["Lee", "Tiny"])
    occ = create(bob, i="kara", t=now(bob) + DAY, tm=[tid], ml=70)
    w.tick(2)
    assert [v["id"] for v in c["Lee"].eval_py("return ns.RaidPlan:GetUnanswered(7)")] == [occ]
    assert list(tiny.eval_py("return ns.RaidPlan:GetUnanswered(7)")) == []
    w.assert_no_errors()


@case
def one_week_of_a_weekly_raid_differs():
    w, c = world()
    bob, lee, tiny = c["Bob"], c["Lee"], c["Tiny"]
    occ0 = create(bob, i="ssc", t=now(bob) + DAY, ml=70, weekly=True)
    occ1 = occ0.replace("#0", "#1")
    w.tick(2)
    assert raid(tiny, occ0)["ml"] == 70 and raid(tiny, occ1)["ml"] == 70
    # this week only: every level
    assert call(bob, "EditRaid", occ1, {"ml": 0}, "one")["ok"] is True
    w.tick(2)
    assert raid(lee, occ0)["ml"] == 70 and raid(lee, occ1).get("ml") is None
    assert signup(tiny, occ1, "A")["ok"] is True and signup(tiny, occ0, "A")["ok"] is False
    # every week: every level; then level 70 again, the week that was opened stays open
    assert call(bob, "EditRaid", occ0, {"ml": 0}, "series")["ok"] is True
    w.tick(2)
    assert raid(lee, occ0).get("ml") is None and signup(tiny, occ0, "A")["ok"] is True
    assert call(bob, "EditRaid", occ0, {"ml": 70}, "series")["ok"] is True
    w.tick(2)
    assert raid(lee, occ0)["ml"] == 70 and raid(lee, occ1).get("ml") is None
    assert sorted(signups(lee, occ0)) == [] and sorted(signups(lee, occ1)) == [K("Tiny")]
    w.assert_no_errors()


def open_tab(w, cl):
    cl.slash("/dz raids")
    w.tick(0.5)


@case
def the_raid_window_and_the_sign_up_strip():
    w, c = world()
    bob, lee, tiny = c["Bob"], c["Lee"], c["Tiny"]
    old = create(bob, i="za", t=now(bob) + 3 * DAY)        # as made before the field existed
    w.tick(1)
    open_tab(w, bob)
    # a new raid asks for level 70: the box is unticked
    bob.eval("ns.RaidPlanUI:OpenEditor()")
    assert bob.eval("return %s.f.low" % ED) is False and bob.eval("return %s.lowCB:GetChecked()" % ED) is False
    assert bob.find_text("Allow characters below level 70", True, True)
    bob.click(bob.eval("return %s.saveBtn" % ED))
    w.tick(2)
    occ = bob.eval("return ns.RaidPlanUI:GetSelectedRaid()")
    assert raid(tiny, occ)["ml"] == 70, raid(tiny, occ)
    # the low character: the raid is listed, the answers are off and the strip says why
    open_tab(w, tiny)
    tiny.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.5)
    assert tiny.eval("return %s.upcoming.statusBtns.A:IsEnabled()" % P) is False
    assert tiny.find_text("This raid is for level 70 characters.", True, True)
    assert tiny.find_text("level 70 only", True, True)
    open_tab(w, lee)
    lee.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    w.tick(0.5)
    assert lee.eval("return %s.upcoming.statusBtns.A:IsEnabled()" % P) is True
    # editing shows the box; ticking it lets the low character in
    bob.eval("ns.RaidPlanUI:OpenEditor(...)", occ)
    assert bob.eval("return %s.f.low" % ED) is False and bob.eval("return %s.lowCB:GetChecked()" % ED) is False
    bob.click(bob.eval("return %s.lowCB" % ED))
    assert bob.eval("return %s.f.low" % ED) is True
    bob.click(bob.eval("return %s.saveBtn" % ED))
    w.tick(2)
    assert raid(tiny, occ).get("ml") is None
    w.tick(1)
    assert tiny.eval("return %s.upcoming.statusBtns.A:IsEnabled()" % P) is True
    # a raid from before the field: the box is ticked, and saving something else leaves it open to every level
    bob.eval("ns.RaidPlanUI:OpenEditor(...)", old)
    assert bob.eval("return %s.f.low" % ED) is True and bob.eval("return %s.lowCB:GetChecked()" % ED) is True
    bob.eval("%s.noteBox:SetText('bring flasks')" % ED)
    bob.click(bob.eval("return %s.saveBtn" % ED))
    w.tick(2)
    v = raid(tiny, old)
    assert v.get("ml") is None and v["no"] == "bring flasks", v
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
