"""1.3: the planned-raid link of a raid session and of a logged raid (Addendum J §61), on the real addon.

Covers: the leader's /reload keeping the session's link (and an unlink on purpose, which also rides on GS now);
a relink of a logged raid replacing its sign-ups and the bench marks made from them, an unlink clearing them, and a
council peer's copy following (the winning link's sign-ups, never a union across two links), reliability counting
linked raids only; a raid log member (not the session's authority) relinking the running raid for the whole raid
(the authority takes the request into the session), a raider's forged request ignored.

Run: luaenv\\Scripts\\python.exe tests\\raidlog\\test_raid_link.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "raidplan"))

from rp_common import World, Client, gm_pick, K, now, create, signup, set_raid_leaders  # noqa: E402
from _common import case, run_all, printed_since, strip_codes  # noqa: E402

A = [("Tank", "WARRIOR", 3), ("Rog", "ROGUE", 2), ("Moon", "DRUID", 1), ("Pip", "PRIEST", 2), ("Lock", "WARLOCK", 3)]
B = [("Ena", "SHAMAN", 2), ("War", "WARRIOR", 2), ("Holly", "PALADIN", 1)]


def world():
    """Gina = GM, Bob = guild council + the raid leaders list; the others plain members."""
    w = World()
    w.auto_session = False
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


def sign(w, c, occ, members, status=None):
    for n, _, sp in members:
        assert signup(c[n], occ, (status or {}).get(n, "A"), sp)["ok"], n
    w.tick(2)


def session(cl):
    return cl.eval_py("return ns.GroupRules:GetSession()")


def rec(cl, rid):
    return cl.eval_py("return ns.RaidLog:GetRaid(...)", rid)


def said(cl, n0, needle):
    return [strip_codes(l) for l in printed_since(cl, n0) if needle in strip_codes(l)]


def sync(w, *cls):
    """Raid planners exchange their raid log (the HELLO digest, then the weeks that differ)."""
    for x in cls:
        x.eval("ns.Sync:SendHello(true)")
        w.tick(1)
    w.tick(40)


# ------------------------------------------------------------------------------------------------------------------
@case
def the_leaders_reload_keeps_the_link_and_an_unlink():
    w, c = world()
    bob, tank = c["Bob"], c["Tank"]
    occ = create(bob, i="kara", t=now(bob) + 600)
    w.tick(2)
    sign(w, c, occ, A)
    w.make_raid([bob, tank], leader=bob, extra_members=["Pugone", "Pugtwo"])
    w.tick(4)
    assert bob.eval("return ns.GroupRules:SetSession(true, GetServerTime() - 9000, { loot = true, rolls = true })")
    w.tick(3)
    assert bob.eval("return ns.RaidLink:SetLink(...)", occ)
    w.tick(6)
    rid = session(bob)["id"]
    assert session(tank)["rp"] == occ and rec(bob, rid)["pl"] == occ
    # the leader reloads: the session it resumes from its raid log keeps the link, for everyone
    bob.relog(reload=True)
    w.tick(15)
    for x in (bob, tank):
        s = session(x)
        assert s and s["id"] == rid and s["rp"] == occ, (x.name, s)
    assert tank.eval("local s = ns.GroupRules:GetSession(); return s and s.rp") == occ    # (strategy reminders)
    # unlinked on purpose: the unlink reaches the raid too, and survives the next /reload (no automatic relink)
    assert bob.eval("return ns.RaidLink:SetLink(nil)")
    w.tick(6)
    for x in (bob, tank):
        s = session(x)
        assert s.get("rp") is None and s.get("rpAt"), (x.name, s)
        assert rec(x, rid).get("pl") is None, x.name
    bob.relog(reload=True)
    w.tick(20)
    for x in (bob, tank):
        s = session(x)
        assert s and s["id"] == rid and s.get("rp") is None and s.get("rpAt"), (x.name, s)
    w.assert_no_errors()


@case
def a_relink_replaces_the_signups_and_an_unlink_clears_them_for_good():
    w, c = world()
    bob, gina = c["Bob"], c["Gina"]
    occ = create(bob, i="kara", t=now(bob) + 600)
    other = create(bob, i="kara", t=now(bob) + 3600)          # the same night, later: the other team's raid
    w.tick(2)
    sign(w, c, occ, A, status={"Pip": "B"})                  # Pip is on the bench for this one
    sign(w, c, other, B, status={"Holly": "B"})
    w.make_raid([bob, gina] + [c[n] for n, _, _ in A if n != "Pip"], leader=bob)
    w.tick(4)
    bob.slash("/dz raid start")
    w.tick(6)
    rid = session(bob)["id"]
    assert session(bob)["rp"] == occ
    bob.slash("/dz raid end")
    w.tick(10)
    w.disband()
    w.tick(30)
    for x in (bob, gina):                                    # both recorded it: the same link, sign-ups, bench mark
        r = rec(x, rid)
        assert r["pl"] == occ and r["su"][K("Tank")] == "A" and r["att"][K("Pip")]["b"] is True, (x.name, r)
        assert r["att"][K("Pip")].get("j") is None, r["att"][K("Pip")]        # never joined
    assert bob.eval_py("return ns.RaidLog:GetReliability(...)", K("Tank"))["came"] == 1
    # the raid was really the other team's: relinking replaces the sign-ups and the bench marks made from them
    assert bob.eval("return ns.RaidLog:SetPlanned(...)", rid, other) is True
    w.tick(1)
    r = rec(bob, rid)
    assert r["pl"] == other and sorted(r["su"]) == sorted(K(n) for n, _, _ in B), r["su"]
    assert K("Pip") not in r["att"] and r["att"][K("Holly")]["b"] is True, r["att"]
    assert bob.eval_py("return ns.RaidLog:GetReliability(...)", K("Tank"))["accepted"] == 0
    # Gina's copy (still the old link) takes the newer link with its sign-ups: no union of the two raids
    sync(w, bob, gina)
    for x in (bob, gina):
        r = rec(x, rid)
        assert r["pl"] == other and sorted(r["su"]) == sorted(K(n) for n, _, _ in B), (x.name, r["su"])
        assert K("Pip") not in r["att"] and r["att"][K("Holly")]["b"] is True, (x.name, r["att"])
    assert bob.eval_py("return ns.RaidLog:GetDigest()") == gina.eval_py("return ns.RaidLog:GetDigest()")
    # unlinked: the sign-ups go, everywhere, and don't come back from a peer
    assert gina.eval("return ns.RaidLog:SetPlanned(...)", rid, None) is True
    w.tick(1)
    sync(w, gina, bob)
    for x in (bob, gina):
        r = rec(x, rid)
        assert r.get("pl") is None and r.get("su") is None and K("Holly") not in r["att"], (x.name, r)
        assert x.eval_py("return ns.RaidLog:GetReliability(...)", K("Ena")) is None, x.name
    assert bob.eval_py("return ns.RaidLog:GetDigest()") == gina.eval_py("return ns.RaidLog:GetDigest()")
    # an old copy that still has sign-ups without a link (1.2) loses them too
    assert bob.eval_py("local r = ns.RaidLog:MergeRecord(..., 'x'); return r", dict(
        {k: v for k, v in rec(bob, rid).items() if k not in ("g", "last")},
        su={K("Tank"): "A"})) is False
    assert rec(bob, rid).get("su") is None
    w.assert_no_errors()


@case
def a_raid_log_member_relinks_the_running_raid_for_everyone():
    w, c = world()
    bob, gina, tank = c["Bob"], c["Gina"], c["Tank"]
    occ = create(bob, i="kara", t=now(bob) + 600)
    other = create(bob, i="kara", t=now(bob) + 3600)
    w.tick(2)
    sign(w, c, occ, A)
    sign(w, c, other, B)
    w.make_raid([bob, gina] + [c[n] for n, _, _ in A], leader=bob)
    w.tick(4)
    n0 = len(bob.chat_frame)
    bob.slash("/dz raid start")
    w.tick(6)
    rid = session(bob)["id"]
    assert session(bob)["rp"] == occ
    assert said(bob, n0, "Raid leaders and the guild council can change that in the Raid log, for the whole raid")
    # Gina (the GM, not the raid leader) relinks it in the Raid log: the session takes it, for the whole raid
    n0 = len(bob.chat_frame)
    assert gina.eval("return ns.RaidLog:SetPlanned(...)", rid, other) is True
    w.tick(4)
    for x in [bob, gina] + [c[n] for n, _, _ in A]:
        assert session(x)["rp"] == other, (x.name, session(x))
        assert rec(x, rid)["pl"] == other, x.name
    assert said(bob, n0, "Gina linked this raid to the planned raid"), printed_since(bob, n0)
    # a raider without the raid log can't: a forged request is ignored, and the API refuses
    tank.eval("ns.Comm:Send({ t = 'GSP', rs = ..., rp = ... }, 'WHISPER', select(3, ...), 'alert')", rid, occ, K("Bob"))
    w.tick(4)
    assert session(bob)["rp"] == other and session(tank)["rp"] == other
    assert tank.eval("return ns.RaidLog:SetPlanned(...)", rid, occ) is False
    # the raid ends: every record has the link the raid had, with its sign-ups
    bob.slash("/dz raid end")
    w.tick(10)
    for x in (bob, gina):
        r = rec(x, rid)
        assert r["pl"] == other and sorted(r["su"]) == sorted(K(n) for n, _, _ in B), (x.name, r)
    # Gina unlinks the next raid while it runs: nobody's raid stays linked
    w.tick(5)
    bob.slash("/dz raid start")
    w.tick(6)
    rid2 = session(bob)["id"]
    assert rid2 != rid and session(tank).get("rp")
    assert gina.eval("return ns.RaidLog:SetPlanned(...)", rid2, None) is True
    w.tick(4)
    for x in (bob, gina, tank):
        s = session(x)
        assert s.get("rp") is None and s.get("rpAt"), (x.name, s)
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
