"""ADDENDUM K, 1.3: picking a raid's strategy per boss, and a raid's own leader assigning it (user request 2026-10-04).

Covers: Strategy:PickStrategy (saved at once, names in the slots both strategies share stay), who may pick (a raid
without a leader: the GM, the raid leaders on the list and the guild council; a led raid: its own leader, the GM and the
raid leaders on the list, not the council), the leader's fills being trusted by everyone, the default for a boss not picked yet (the strategy the guild used
last time, else the first by name; "only" for a single strategy), and the Assignments tab: the dropdown for who
arranges the raid, the strategy's name for everyone else, "not picked yet", and a pick made from the dropdown's menu.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_picks.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import K, DAY, now, create, save_council, get_fill, fill  # noqa: E402
from rp_common import world as rp_world, call  # noqa: E402
from _common import case, run_all, strip_codes, menu_texts  # noqa: E402

BOSS = "BlackTemple:Council"
ROWS = "ns.RaidsUI:GetPanel().upcoming.detail.assign.list"


def world():
    """Gina = GM, Bob = guild council, Lee / Rita = on the raid leaders list, Sam = a member who leads one raid."""
    return rp_world(names=(("Gina", 0, "PALADIN"), ("Bob", 2, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"),
                           ("Sam", 3, "HUNTER"), ("Hana", 3, "HUNTER")),
                    council=("Bob",), planners=("Lee", "Rita"))


def pick(cl, occ, sid, boss=BOSS):
    return cl.eval_py("local o, b, s = ...; local ok, e = ns.Strategy:PickStrategy(o, b, s); return { ok = ok, e = e }",
                      occ, boss, sid)


def used(cl, occ, boss=BOSS):
    return cl.eval_py("local s, f, how = ns.Strategy:GetRaidStrategy(...); return { id = s and s.id, how = how }",
                      occ, boss)


# ------------------------------------------------------------------------------------------------------------------
@case
def the_raid_leader_picks_and_the_council_does_not_on_a_led_raid():
    w, c = world()
    bob, lee, rita, sam = c["Bob"], c["Lee"], c["Rita"], c["Sam"]
    a = save_council(lee, "A plan")
    b = save_council(rita, "B plan")
    occ = create(lee, i="bt", t=now(lee) + DAY)
    w.tick(2)
    # no leader: the raid leaders on the list and the council pick; members don't
    assert used(sam, occ) == {"id": a, "how": "first"}
    assert pick(rita, occ, b)["ok"] is True
    assert pick(sam, occ, a)["ok"] is False
    w.tick(2)
    assert used(sam, occ) == {"id": b, "how": "picked"}
    # names in the slots both share stay when the pick changes (both are copies of the same plan)
    assert fill(rita, occ, BOSS, b, {"tk.1.1": K("Lee"), "md.1.2": K("Hana")})["ok"] is True
    w.tick(2)
    assert pick(bob, occ, a)["ok"] is True
    w.tick(2)
    f = get_fill(sam, occ, BOSS)
    assert f["s"] == a and f["a"] == {"tk.1.1": K("Lee"), "md.1.2": K("Hana")}, f
    # Sam leads it now (named by a raid leader on the list): Sam and the list pick and assign, the council doesn't
    assert call(lee, "EditRaid", occ, {"rl": K("Sam")})["ok"] is True
    w.tick(2)
    assert sam.eval("return ns.Strategy:CanAssign(...)", occ) is True
    assert rita.eval("return ns.Strategy:CanAssign(...)", occ) is True
    assert bob.eval("return ns.Strategy:CanAssign(...)", occ) is False
    assert bob.eval("return ns.Strategy:CanAssign()") is True        # (other raids)
    res = pick(bob, occ, b)
    assert res["ok"] is False and "this raid's leader" in res["e"], res
    assert pick(sam, occ, b)["ok"] is True
    assert fill(sam, occ, BOSS, b, {"tk.2.1": K("Sam")})["ok"] is True
    w.tick(2)
    for x in c.values():
        f = get_fill(x, occ, BOSS)
        assert f and f["s"] == b and f["a"] == {"tk.2.1": K("Sam")}, (x.name, f)
    # an unknown strategy, or one of another boss
    assert pick(sam, occ, "nope")["ok"] is False
    assert pick(sam, occ, a, "BlackTemple:Illidan")["ok"] is False
    w.assert_no_errors()


@case
def a_boss_not_picked_uses_the_one_used_last_time():
    w, c = world()
    lee, rita = c["Lee"], c["Rita"]
    a = save_council(lee, "A plan")
    b = save_council(rita, "B plan")
    first = create(lee, i="bt", t=now(lee) + DAY)
    later = create(lee, i="bt", t=now(lee) + 8 * DAY)
    w.tick(2)
    assert used(rita, later) == {"id": a, "how": "first"}
    assert pick(lee, first, b)["ok"] is True
    w.tick(2)
    assert used(rita, later) == {"id": b, "how": "last"}
    assert rita.eval("return ns.Strategy:GetLastPick(...)", BOSS, later) == b
    # the latest raid before it wins over one after it
    third = create(lee, i="bt", t=now(lee) + 15 * DAY)
    w.tick(2)
    assert pick(lee, third, a)["ok"] is True
    w.tick(2)
    assert used(rita, later) == {"id": b, "how": "last"}
    # a boss with one strategy
    only = rita.eval_py("local d = (loadstring(...))(); d.b = 'BlackTemple:Illidan'; d.n = 'Solo';"
                        " local ok, r = ns.Strategy:SaveStrategy(d); return { ok = ok, r = r }",
                        open(os.path.join(HERE, "st_common.py"), encoding="utf-8").read().split('COUNCIL = """')[1]
                        .split('"""')[0])
    assert only["ok"] is True, only
    w.tick(2)
    assert used(lee, later, "BlackTemple:Illidan") == {"id": only["r"], "how": "only"}
    w.assert_no_errors()


@case
def the_assignments_tab_picks_from_the_row():
    w, c = world()
    bob, lee, rita, sam = c["Bob"], c["Lee"], c["Rita"], c["Sam"]
    a = save_council(lee, "A plan")
    b = save_council(rita, "B plan")
    occ = create(lee, i="bt", t=now(lee) + DAY)
    w.tick(2)
    assert call(lee, "EditRaid", occ, {"rl": K("Sam")})["ok"] is True
    w.tick(2)

    def council_row(cl):
        cl.slash("/dz raids")
        w.tick(0.3)
        cl.eval("ns.RaidPlanUI:SelectRaid(...); ns.RaidPlanUI:SetDetailTab('assign')", occ)
        w.tick(0.3)
        return cl.eval_py("local ref, found = ...; %s.box:ForEachFrame(function(row) local d = row.__cdlData; "
                          "if d and d.ref == ref then found = { l1 = row.l1:GetText(), l2 = row.l2:GetText(), stat = row.stat:GetText(), "
                          "pick = row.pick:IsShown(), pickText = row.pick:GetText(), assign = row.assign:IsShown(), "
                          "pickW = row.pick:GetWidth() } "
                          "end end); return found" % ROWS, BOSS)

    # the leader: a dropdown with the strategy in use, "not picked yet" while it is the default
    r = council_row(sam)
    assert r["pick"] and r["assign"] and r["pickText"] == "A plan", r
    assert strip_codes(r["l2"]) == "not picked yet" and strip_codes(r["stat"]) == "0/10 filled", r
    assert 110 <= r["pickW"] <= 230, r
    # a raid leader on the list runs it too: the dropdown
    r = council_row(lee)
    assert r["pick"] and r["assign"], r
    # the guild council (not on a led raid): the name as text, no dropdown
    r = council_row(bob)
    assert not r["pick"] and not r["assign"] and strip_codes(r["l2"]) == "A plan", r
    assert strip_codes(r["stat"]) == "0/10 filled" and r["l1"] == "The Illidari Council", r
    # the leader opens the dropdown: both strategies, who made them, how big
    sam.eval("local ref = ...; %s.box:ForEachFrame(function(row) local d = row.__cdlData; if d and d.ref == ref then "
             "row.pick:OpenMenu() end end)" % ROWS, BOSS)
    entries = [(k, t) for _, k, t, _ in menu_texts(sam.last_menu())]
    texts = [strip_codes(t) for k, t in entries if k == "radio"]
    assert texts[0].startswith("A plan  Lee · 10 slots") and texts[1].startswith("B plan  Rita · 10 slots"), texts
    raw_b = [t for k, t in entries if k == "radio" and strip_codes(t).startswith("B plan")][0]
    sam.menu_select(raw_b)
    w.tick(2)
    assert get_fill(lee, occ, BOSS)["s"] == b
    r = council_row(sam)
    assert r["pickText"] == "B plan" and strip_codes(r["l2"]) == "", r
    # the council's row follows
    r = council_row(bob)
    assert strip_codes(r["l2"]) == "B plan", r
    # B is now what the guild used last time: the menu says so on another raid
    occ2 = create(lee, i="bt", t=now(lee) + 8 * DAY)
    w.tick(2)
    lee.eval("ns.RaidPlanUI:SelectRaid(...)", occ2)
    w.tick(0.3)
    lee.eval("local ref = ...; %s.box:ForEachFrame(function(row) local d = row.__cdlData; if d and d.ref == ref then "
             "row.pick:OpenMenu() end end)" % ROWS, BOSS)
    texts = [strip_codes(t) for _, k, t, _ in menu_texts(lee.last_menu()) if k == "radio"]
    assert any(t.startswith("B plan") and "used last time" in t for t in texts), texts
    assert not any(t.startswith("A plan") and "used last time" in t for t in texts), texts
    assert a != b
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
