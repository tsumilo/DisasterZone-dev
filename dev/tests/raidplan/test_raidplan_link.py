"""ADDENDUM J §61: raid sessions linked to planned raids, on the real addon.

Covers: the leader's client links the session automatically when enough players in the raid signed up (every raider
records the same link through GS rp / rpAt), Invite & sort making the link without that evidence, two raids at the same
time told apart by who is in the raid (a mixed roster stays unlinked), a raid of another instance never linked, a
manual unlink sticking, the End raid snapshot (sign-ups kept on the record, Bench sign-ups marked bench, no-shows and
reliability), the Raid log lines, and a council relink reaching another council member through the raid log sync.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_link.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import World, Client, gm_pick, K, now, create, signup, set_raid_leaders  # noqa: E402
from _common import case, run_all, printed_since, strip_codes  # noqa: E402

A = [("Tank", "WARRIOR", 3), ("Rog", "ROGUE", 2), ("Moon", "DRUID", 1), ("Pip", "PRIEST", 2), ("Lock", "WARLOCK", 3)]
B = [("Ena", "SHAMAN", 2), ("War", "WARRIOR", 2), ("Holly", "PALADIN", 1), ("Hunt", "HUNTER", 2), ("Cat", "DRUID", 2)]


def world():
    w = World()
    c = {}
    for n, cls, rank in (("Gina", "PALADIN", 0), ("Bob", "MAGE", 1)):
        c[n] = Client(w, n, guild_rank=rank, class_file=cls)
    for n, cls, _ in A + B:
        c[n] = Client(w, n, guild_rank=3, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ["Bob"])
    w.tick(2)
    return w, c


def team(bob, name, members):
    res = bob.eval_py("local n, m = ...; local ok, id = ns.RaidPlan:SaveTeam(nil, n, m); return { ok = ok, id = id }",
                      name, [K(x) for x, _, _ in members])
    assert res["ok"], res
    return res["id"]


def sign(w, c, occ, members, status=None):
    for n, _, sp in members:
        assert signup(c[n], occ, (status or {}).get(n, "A"), sp)["ok"], n
    w.tick(2)


def session(cl):
    return cl.eval_py("return ns.GroupRules:GetSession()")


def rec(cl, rid):
    return cl.eval_py("return ns.RaidLog:GetRaid(...)", rid)


def start(w, c, members, leader="Bob"):
    w.make_raid([c[leader]] + [c[n] for n in members], leader=c[leader])
    w.tick(4)
    c[leader].slash("/dz raid start")
    w.tick(6)
    return session(c[leader])


# ------------------------------------------------------------------------------------------------------------------
@case
def the_session_links_itself_when_the_signed_up_players_are_in_the_raid():
    w, c = world()
    bob = c["Bob"]
    tid = team(bob, "Kara A", A)
    occ = create(bob, i="kara", t=now(bob) + 1800, tm=[tid])       # started half an hour early
    w.tick(2)
    sign(w, c, occ, A)
    n0 = len(bob.chat_frame)
    s = start(w, c, [n for n, _, _ in A])
    assert s["rp"] == occ and isinstance(s["rpAt"], int), s
    assert any("linked to the planned raid Karazhan" in strip_codes(l) for l in printed_since(bob, n0))
    for n in ["Bob"] + [x for x, _, _ in A]:
        r = rec(c[n], s["id"])
        assert r["pl"] == occ and r["plAt"] == s["rpAt"], (n, r.get("pl"))
    w.assert_no_errors()


@case
def invite_and_sort_links_without_other_evidence():
    w, c = world()
    bob = c["Bob"]
    occ = create(bob, i="kara", t=now(bob) + 600)
    w.tick(2)
    # nobody signed up; the leader places two players and runs Invite & sort
    bob.eval("local o, a, b = ...; ns.RaidPlan:SetGroups(o, { [a] = 1, [b] = 1 })", occ, K("Tank"), K("Rog"))
    w.tick(1)
    bob.eval("local o = ...; ns.RaidInvite:Start(o, ns.RaidPlan:GetRaid(o).grp, 'Karazhan')", occ)
    w.tick(10)
    assert w.group and w.group["kind"] == "raid"
    bob.slash("/dz raid start")
    w.tick(6)
    assert session(bob)["rp"] == occ
    w.assert_no_errors()


@case
def two_raids_at_once_are_told_apart_by_who_is_there():
    w, c = world()
    bob = c["Bob"]
    ta, tb = team(bob, "Kara A", A), team(bob, "Kara B", B)
    t = now(bob) + 900
    occ_a = create(bob, i="kara", t=t, tm=[ta])
    occ_b = create(bob, i="kara", t=t, tm=[tb])
    w.tick(2)
    sign(w, c, occ_a, A)
    sign(w, c, occ_b, B)
    s = start(w, c, [n for n, _, _ in B])
    assert s["rp"] == occ_b, s
    bob.slash("/dz raid end")
    w.tick(3)
    w.disband()
    w.tick(2)
    # a mixed roster (3 of A, 2 of B): not clear enough, no link
    s = start(w, c, ["Tank", "Rog", "Moon", "Ena", "War"])
    assert s.get("rp") is None, s
    # ... until more of A arrive
    w.group["members"] += [c["Pip"], c["Lock"]]
    w.group["subgroups"].update({id(c["Pip"]): 2, id(c["Lock"]): 2})
    w._roster_changed_group()
    w.tick(6)
    assert session(bob)["rp"] == occ_a
    w.assert_no_errors()


@case
def another_instance_is_never_linked_and_a_manual_unlink_sticks():
    w, c = world()
    bob = c["Bob"]
    occ = create(bob, i="gruul", t=now(bob) + 600)
    w.tick(2)
    sign(w, c, occ, A)
    w.enter_instance("Karazhan", 532)
    w.tick(2)
    s = start(w, c, [n for n, _, _ in A])
    assert s.get("rp") is None, s                         # we are in Karazhan, the plan says Gruul
    w.leave_instance()
    w.tick(6)
    assert session(bob)["rp"] == occ                     # outside, the sign-ups decide
    bob.eval("ns.RaidLink:SetLink(nil)")
    w.tick(6)
    s = session(bob)
    assert s.get("rp") is None and s.get("rpAt"), s       # unlinked on purpose: no automatic relink
    w.assert_no_errors()


@case
def end_raid_keeps_signups_marks_bench_and_counts_no_shows():
    w, c = world()
    bob, gina = c["Bob"], c["Gina"]
    tid = team(bob, "Kara A", A)
    occ = create(bob, i="kara", t=now(bob) + 600, tm=[tid])
    w.tick(2)
    sign(w, c, occ, A + [("Ena", "SHAMAN", 2)], status={"Pip": "B", "Ena": "X"})
    s = start(w, c, ["Tank", "Rog", "Moon", "Gina"])     # Lock accepted but doesn't come; Pip is on the bench
    assert s["rp"] == occ
    bob.slash("/dz raid end")
    w.tick(3)
    r = rec(bob, s["id"])
    assert r["su"] == {K("Tank"): "A", K("Rog"): "A", K("Moon"): "A", K("Pip"): "B", K("Lock"): "A", K("Ena"): "X"}, r["su"]
    assert r["att"][K("Pip")]["b"] is True and K("Lock") not in r["att"], r["att"]
    rel = bob.eval_py("return ns.RaidLog:GetReliability(...)", K("Lock"))
    assert rel["accepted"] == 1 and rel["came"] == 0, rel
    assert bob.eval("return ns.RaidLog:GetReliabilityText(...)", K("Tank")) == "came to 1 of 1 accepted raids"
    # the Raid log shows the link and the no-show
    bob.slash("/dz raids")
    w.tick(0.3)
    bob.eval("ns.RaidsUI:Select(...)", s["id"])
    w.tick(0.3)
    # (the link is a picker under the raid's banner; how the sign-ups turned out sits beside it)
    link = strip_codes(bob.eval("return ns.RaidsUI:GetPanel().linkBtn:GetText()"))
    assert link == "Linked to  Karazhan", link
    check = strip_codes(bob.eval("local l = ns.RaidsUI:GetPanel().signupLine; return l:IsShown() and l.fs:GetText()"))
    assert "came" in check and "no-show Lock" in check, check
    # the council member's recording agrees (same link time, same bench mark)
    rg = rec(gina, s["id"])
    assert rg["pl"] == occ and rg["att"][K("Pip")]["b"] is True, rg
    w.assert_no_errors()


@case
def council_relinks_a_logged_raid_and_the_other_council_member_gets_it():
    w, c = world()
    bob, gina = c["Bob"], c["Gina"]
    occ = create(bob, i="kara", t=now(bob) + 600)
    other = create(bob, i="kara", t=now(bob) + 7200)
    w.tick(2)
    sign(w, c, occ, A)
    s = start(w, c, [n for n, _, _ in A])
    assert s["rp"] == occ
    bob.slash("/dz raid end")
    w.tick(5)
    w.disband()
    w.tick(2)
    gina.logout()
    w.tick(1)
    bob.slash("/dz raids")
    w.tick(0.3)
    bob.eval("ns.RaidsUI:Select(...)", s["id"])
    w.tick(0.3)
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().linkBtn"))
    items = [e["text"] for e in bob.last_menu()["children"] if e.get("text")]
    assert "Not linked" in items and len(items) >= 4, items
    label = next(x for x in items if x.endswith("Karazhan") and x != items[1] and "Planned" not in x and x != items[0])
    bob.menu_select(label)
    w.tick(1)
    assert rec(bob, s["id"])["pl"] == other, rec(bob, s["id"])["pl"]
    gina.login()
    w.tick(60)
    assert rec(gina, s["id"])["pl"] == other, rec(gina, s["id"])
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
