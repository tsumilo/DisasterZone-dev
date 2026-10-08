"""Live raid session edge cases found in the 2026-10-08 review, each fixed, on the real addon.

Covers: the lead passed to a raid member without DisasterZone (the session carries on with whoever ran it, instead of
ending for everyone), the lead passed to a member who has it (they adopt the session; Invite & sort keeps running
through the hand-over), and a raider who was away when the raid ended closing it hours later (their copy ends at its
last activity, not "now", and nobody who joined afterwards counts as an attendee).

Run: luaenv\\Scripts\\python.exe tests\\raidlog\\test_raid_session_edges.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "loot-roll"))

from test_raidlog import world, raid, start, rec, current, K  # noqa: E402
import _common  # noqa: E402
from _common import case, run_all  # noqa: E402
from harness import ExtraMember  # noqa: E402

del _common._CASES[:]       # (importing test_raidlog registered its own cases)

RAIDERS = ("Lee", "Bob", "Rita", "Sam")


def plan(cl, groups):
    cl.eval("ns.__plan = {}")
    for k, g in groups.items():
        cl.eval("ns.__plan[select(1, ...)] = select(2, ...)", k, g)


@case
def lead_passed_to_a_member_without_the_addon_keeps_the_session():
    w, c = world()
    lee = c["Lee"]
    members = [c[n] for n in RAIDERS]
    w.make_raid(members, leader=lee)
    w.tick(8)
    rid = start(w, c)
    w.make_raid(members, leader="Noaddon", extra_members=[ExtraMember("Noaddon", "WARRIOR")])
    w.tick(15)
    for n in RAIDERS:
        x = c[n]
        assert x.eval("return ns.GroupRules:GetAuthority()") == K("Lee"), n
        assert x.eval("return ns.GroupRules:GetSession() ~= nil") is True, n
        assert x.eval("return ns.GroupRules:IsFeatureOn('loot')") is True, n
        assert current(x) == rid, n
    # Lee leaves the raid: nobody runs it any more (as before)
    w.make_raid([c[n] for n in RAIDERS[1:]], leader="Noaddon", extra_members=[ExtraMember("Noaddon", "WARRIOR")])
    w.tick(15)
    assert c["Rita"].eval("return ns.GroupRules:GetSession() == nil") is True
    w.assert_no_errors()


@case
def lead_passed_to_a_member_with_the_addon_hands_the_session_over():
    w, c = world()
    lee, rita = c["Lee"], c["Rita"]
    members = [c[n] for n in RAIDERS]
    w.make_raid(members, leader=lee)
    w.tick(8)
    rid = start(w, c)
    plan(lee, {K("Lee"): 1, K("Bob"): 1, K("Rita"): 2, K("Sam"): 2, K("Gina"): 2})
    assert lee.eval("return ns.RaidInvite:Start('occ1', ns.__plan, 'Kara')") is True
    w.tick(5)
    w.make_raid(members, leader=rita, assistants=[lee])
    w.tick(15)
    assert rita.eval("return ns.GroupRules:IsAuthority()") is True
    for n in RAIDERS:
        assert c[n].eval("return ns.GroupRules:GetSession() ~= nil") is True, n
        assert current(c[n]) == rid, n
    assert lee.eval("return ns.RaidInvite:IsActive()") is True     # not stopped by the hand-over
    # the session ends: the run stops, and says so
    rita.slash("/dz raid end")
    w.tick(25)
    assert lee.eval("return ns.RaidInvite:IsActive()") is False
    assert any("Invite & sort stopped" in line for line in lee.chat_frame), lee.chat_frame[-5:]
    w.assert_no_errors()


@case
def a_raider_who_missed_the_end_closes_the_raid_at_its_last_activity():
    w, c = world()
    lee, sam = c["Lee"], c["Sam"]
    raid(w, c, members=RAIDERS)
    w.enter_instance()
    rid = start(w, c)
    w.tick(600, step=5)
    sam.logout()                       # Sam logs out and stays in the raid group (offline)
    w.tick(5)
    lee.slash("/dz raid end")
    w.tick(5)
    real_stop = rec(lee, rid)["stop"]
    w.leave_instance()
    w.tick(3600, step=10)              # an hour later Gina joins the group, then Sam logs back in
    raid(w, c, members=RAIDERS + ("Gina",), tick=5)
    sam.login()
    w.tick(20)
    r = rec(sam, rid)
    assert r.get("stop") and r["stop"] <= real_stop, (r.get("stop"), real_stop)
    assert not r.get("endedBy") and r.get("autoEnded"), r
    assert K("Gina") not in r["att"], r["att"]
    assert (r["att"][K("Lee")].get("l") or 0) <= real_stop, r["att"][K("Lee")]
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
