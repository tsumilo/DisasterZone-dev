#!/usr/bin/env python
"""1.3: the raid-scope council (the raid leader and their raid list picks, not the guild council) gets the raiders' BiS
lists only once the raid runs with the loot council (after Start raid, with it on), and only for that raid session:
afterwards (End raid, leaving the raid) their copies are dropped on their own client. Nothing is sent about it, no
revision changes, the guild council's copies and every player's own list stay as they are, and a later raid session
gets the lists again (without re-requests in between).

Run:  luaenv\\Scripts\\python.exe tests\\sync\\test_raid_council_lists.py   [-k substring]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (Runner, Client, new_world, up, settle, key, edit, own, cached, is_council,  # noqa: E402
                    logical_messages, raid_pick)

r = Runner("raid council lists")
RK, R2K, LK, PK = key("Raider"), key("Raiderb"), key("Raidlead"), key("Pick")
LIST_TYPES = ("L", "R", "W", "M", "S", "H")


def setup():
    """Guildboss = GM, Councila = guild council (seeded list); Raidlead leads the raid and picks Pick for its raid
    council; Raider / Raiderb have BiS lists the guild council already holds."""
    w = new_world()
    w.auto_session = False
    cl = {}
    for name, cls, rank in (("Guildboss", "PALADIN", 0), ("Councila", "PRIEST", 1), ("Raidlead", "WARRIOR", 3),
                            ("Raider", "PALADIN", 3), ("Raiderb", "MAGE", 3), ("Pick", "DRUID", 3)):
        cl[name] = up(Client(w, name, class_file=cls, guild_rank=rank))
    settle(w, 3)
    edit(cl["Raider"], 0, commit=True)
    edit(cl["Raiderb"], 1, commit=True)
    settle(w, 40)
    for gc in ("Guildboss", "Councila"):
        assert cached(cl[gc], RK)["rev"] == own(cl["Raider"])["rev"], gc
        assert cached(cl[gc], R2K)["rev"] == own(cl["Raiderb"])["rev"], gc
    return w, cl


def lists_of(c):
    return c.eval_py("local o = {} for k, v in pairs(ns.db.lists) do o[k] = { v.rev, v.hash } end return o") or {}


def start(c, loot=True):
    res = c.eval_py("local ok, e = ns.GroupRules:SetSession(true, nil, ...); return { ok = ok, e = e }",
                    {"loot": loot, "rolls": True, "lock": False})
    assert res["ok"] is True, res


@r.case
def raid_council_gets_the_lists_only_while_the_loot_council_runs_and_drops_them_after():
    w, cl = setup()
    L, R, R2, P, GM, C1 = (cl[n] for n in ("Raidlead", "Raider", "Raiderb", "Pick", "Guildboss", "Councila"))
    w.make_raid([L, R, R2, P, C1], leader=L)
    settle(w, 20)
    raid_pick(w, L, ["Pick"])
    settle(w, 20)
    assert is_council(L) and is_council(P) and is_council(R, PK), "the raid leader and the pick are the raid's council"
    # no raid session: no lists (the promotion HELLO doesn't bring them either)
    for x in (L, P):
        assert cached(x, RK) is None and cached(x, R2K) is None, x.name
    # a raid without the loot council: still none
    start(L, loot=False)
    settle(w, 30)
    for x in (L, P):
        assert cached(x, RK) is None and cached(x, R2K) is None, x.name
    # the loot council switched on (Options): the raiders push their lists
    res = L.eval_py("return { ns.GroupRules:SetSessionFeatures({ loot = true, rolls = true, lock = false }) }")
    assert res[0] is True, res
    settle(w, 30)
    for x in (L, P):
        assert cached(x, RK)["rev"] == own(R)["rev"] and cached(x, R2K)["rev"] == own(R2)["rev"], x.name
    gc_before = {x.name: lists_of(x) for x in (GM, C1)}
    own_before = {x.name: (own(x)["rev"], own(x)["hash"]) for x in (R, R2)}
    # End raid: the raid council's copies go, on their own clients only
    mark = len(w.addon_log)
    assert L.eval("return ns.RaidLog:End()") is True
    settle(w, 10)
    for x in (L, P):
        assert cached(x, RK) is None and cached(x, R2K) is None, x.name
        assert x.eval("return ns.Store:Get(...)", RK) is None, x.name
        assert lists_of(x) == {}, (x.name, lists_of(x))
    # the guild council's lists and the players' own lists are untouched
    assert {x.name: lists_of(x) for x in (GM, C1)} == gc_before
    assert {x.name: (own(x)["rev"], own(x)["hash"]) for x in (R, R2)} == own_before
    # nothing about it went over the wire, and nobody pushes or asks again afterwards
    settle(w, 60)
    msgs = logical_messages(w, mark)
    assert not [m for m in msgs if m["t"] in LIST_TYPES], [(m["sender"], m["t"]) for m in msgs if m["t"] in LIST_TYPES]
    assert not [m for m in msgs if m["sender"] in (LK, PK) and m["t"] != "GS"], [(m["sender"], m["t"]) for m in msgs]
    assert {x.name: lists_of(x) for x in (GM, C1)} == gc_before
    assert {x.name: (own(x)["rev"], own(x)["hash"]) for x in (R, R2)} == own_before
    # the next raid session (the same evening): the lists come again; leaving the raid drops them again
    start(L, loot=True)
    settle(w, 30)
    for x in (L, P):
        assert cached(x, RK)["rev"] == own(R)["rev"], x.name
    w.disband()
    settle(w, 15)
    for x in (L, P):
        assert lists_of(x) == {}, (x.name, lists_of(x))
    assert {x.name: lists_of(x) for x in (GM, C1)} == gc_before
    w.assert_no_errors()


@r.case
def a_reload_mid_raid_keeps_them_and_the_guild_council_leading_keeps_everything():
    w, cl = setup()
    L, R, R2, GM, C1 = (cl[n] for n in ("Raidlead", "Raider", "Raiderb", "Guildboss", "Councila"))
    w.make_raid([L, R, R2], leader=L)
    settle(w, 10)
    start(L)
    settle(w, 30)
    assert cached(L, RK)["rev"] == own(R)["rev"]
    # the raid leader's /reload: the session goes on, so do the copies
    L.relog()
    settle(w, 30)
    assert cached(L, RK)["rev"] == own(R)["rev"] and cached(L, R2K)["rev"] == own(R2)["rev"]
    assert L.eval("return ns.RaidLog:End()") is True
    settle(w, 10)
    assert lists_of(L) == {}
    # a guild council member leading a raid keeps every list after it (theirs to keep)
    before = lists_of(C1)
    assert RK in before and R2K in before
    w.make_raid([C1, R, R2], leader=C1)
    settle(w, 10)
    start(C1)
    settle(w, 30)
    assert C1.eval("return ns.RaidLog:End()") is True
    settle(w, 10)
    w.disband()
    settle(w, 15)
    assert lists_of(C1) == before
    w.assert_no_errors()


if __name__ == "__main__":
    r.run()
