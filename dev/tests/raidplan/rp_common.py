"""Shared helpers of the raid planning suites (Addendum J)."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "loot-roll"))

from _common import World, Client, gm_pick  # noqa: E402,F401

REALM = "Thunderstrike"
DAY = 86400


def K(name):
    return "%s-%s" % (name, REALM)


def world(names=(("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"),
                 ("Sam", 3, "ROGUE")), council=("Bob",), planners=("Bob",)):
    """Gina = GM, Bob = guild council + raid leader (the organizers); Lee / Rita / Sam = members."""
    w = World()
    c = {}
    for name, rank, cls in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], list(council))
    set_raid_leaders(w, c["Gina"], planners)
    w.tick(2)
    return w, c


def now(cl):
    return cl.eval("return GetServerTime()")


def team(cl, name, members, tid=None):
    res = cl.eval_py("local id, n, m = ...; local ok, r = ns.RaidPlan:SaveTeam(id, n, m); return { ok = ok, r = r }",
                     tid, name, [K(m) for m in members])
    assert res["ok"] is True, res
    return res["r"]


def create(cl, **f):
    res = cl.eval_py("local f = ...; local ok, r = ns.RaidPlan:CreateRaid(f); return { ok = ok, r = r }", f)
    assert res["ok"] is True, res
    return res["r"]


def raids(cl, *args):
    return cl.eval_py("return ns.RaidPlan:GetRaids(...)", *args)


def raid(cl, occ):
    return cl.eval_py("return ns.RaidPlan:GetRaid(...)", occ)


def signup(cl, occ, st, sp=None, note=None):
    res = cl.eval_py("local o, st, sp, n = ...; local ok, e = ns.RaidPlan:SignUp(o, st, sp, n); return { ok = ok, e = e }",
                     occ, st, sp, note)
    return res


def signups(cl, occ):
    return cl.eval_py("return ns.RaidPlan:GetSignups(...)", occ)


def call(cl, fn, *args):
    return cl.eval_py("local fn = ...; local ok, e = ns.RaidPlan[fn](ns.RaidPlan, select(2, ...)); return { ok = ok, e = e }",
                      fn, *args)


def set_raid_leaders(w, officer, names, tick=2):
    """An officer (rank 0-1) saves the raid leaders list (Addendum J §62): the raid planners besides the GM."""
    res = officer.eval_py("local ok, err = ns.Guild:SetRaidLeaders(...); return { ok = ok, err = err }",
                          [K(n) for n in names])
    assert res.get("ok") is True, res
    if tick:
        w.tick(tick)
