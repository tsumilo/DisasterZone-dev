"""The guild's loot rules (1.3.5, Council > Rules): Guild:Get/SetLootRules (the GM's, synced with the raid leaders list
on RLL), Roll:RankRows (attendance floor, split votes, lists first / roll only, highest roll / driest first) and what
a dry streak counts (nights really there / any night).

Run: luaenv\\Scripts\\python.exe tests\\votes\\test_loot_rules.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "attendance"))
sys.path.insert(0, os.path.join(TESTS, "raidplan"))

from test_dry_streak import world, nights, award, dry, K  # noqa: E402
from _common import case, run_all  # noqa: E402

# rows for RankRows: name, votes, roll, tier, att, dry, extra
RANK = r"""
local spec, rules = ...
local rows = {}
for i, s in ipairs(spec) do
    rows[i] = { key = s[1], name = s[1], votes = s[2] or 0, roll = s[3], invalid = false, inRaid = true,
                response = s[3] and "roll" or (s[7] and "pass" or nil), tier = s[4] or 4, att = s[5], dry = s[6] }
end
ns.Roll:RankRows(rows, { rules = rules })
local out = {}
for i, r in ipairs(rows) do
    out[i] = { key = r.key, suggested = r.suggested, split = r.split, low = r.lowAtt, tie = r.tie }
end
return out
"""
RULES = {"f": 0, "s": "r", "l": "l", "w": "r", "y": "n"}


def rank(cl, spec, **over):
    rules = dict(RULES, **over)
    res = cl.eval_py(RANK, spec, rules)
    res = list(res.values()) if isinstance(res, dict) else list(res)
    sug = [r["key"] for r in res if r.get("suggested")]
    return [r["key"] for r in res], (sug[0] if sug else None), {r["key"]: r for r in res}


# the user's in-game case: one vote each; Quillon (OS, 14%) and Brakka did not roll, Orinel rolled 93
CASE = [["Quillon", 1, None, 3, 14, 5], ["Orinel", 1, 93, 4, 60, 5], ["Brakka", 1, None, 4, 88, 1],
        ["Kaelyn", 0, 98, 4, 78, 0], ["Caelith", 0, 27, 3, 100, 1]]


@case
def split_vote_goes_to_the_highest_roll_among_them():
    w, c = world()
    order, sug, rows = rank(c["Bob"], CASE)
    assert sug == "Orinel", (order, sug)
    assert order[:1] == ["Orinel"] and all(rows[n]["split"] for n in ("Quillon", "Orinel", "Brakka")), rows
    assert not rows["Kaelyn"].get("split")


@case
def split_vote_council_picks_means_no_suggestion():
    w, c = world()
    order, sug, rows = rank(c["Bob"], CASE, s="p")
    assert sug is None, (order, sug)
    assert rows["Orinel"]["split"]


@case
def nobody_of_the_split_rolled_means_no_suggestion():
    w, c = world()
    spec = [["Quillon", 1, None, 3, 14, 5], ["Brakka", 1, None, 4, 88, 1], ["Kaelyn", 0, 98, 4, 78, 0]]
    order, sug, rows = rank(c["Bob"], spec)
    assert sug is None, (order, sug)


@case
def attendance_floor_drops_votes_and_suggestions_below_it():
    w, c = world()
    # one clear vote for Quillon (14%): with a 50% floor it doesn't count, the roll order decides
    spec = [["Quillon", 2, 99, 3, 14, 5], ["Orinel", 0, 93, 4, 60, 5], ["Caelith", 0, 27, 3, 100, 1]]
    order, sug, rows = rank(c["Bob"], spec)
    assert sug == "Quillon", (order, sug)
    order, sug, rows = rank(c["Bob"], spec, f=50)
    assert sug == "Caelith" and rows["Quillon"]["low"], (order, sug, rows)   # (lists first: OS before no list)
    assert order.index("Quillon") > order.index("Orinel"), order


@case
def before_votes_lists_first_or_the_roll_only():
    w, c = world()
    spec = [["Kaelyn", 0, 98, 4, 78, 0], ["Caelith", 0, 27, 3, 100, 1], ["Orinel", 0, 93, 4, 60, 5]]
    assert rank(c["Bob"], spec)[1] == "Caelith"           # the OS list before everyone not on a list
    assert rank(c["Bob"], spec, l="r")[1] == "Kaelyn"     # the roll only


@case
def driest_first_within_a_list():
    w, c = world()
    spec = [["Kaelyn", 0, 98, 4, 78, 0], ["Orinel", 0, 93, 4, 60, 5], ["Mirabel", 0, 8, 4, 75, 5]]
    assert rank(c["Bob"], spec)[1] == "Kaelyn"
    order, sug, _ = rank(c["Bob"], spec, w="d")
    assert sug == "Orinel" and order[:3] == ["Orinel", "Mirabel", "Kaelyn"], order   # (equal streaks: the roll)


@case
def only_the_gm_sets_the_rules_and_they_reach_the_guild():
    w, c = world()
    gina, bob, tank = c["Gina"], c["Bob"], c["Tank"]
    assert bob.eval_py("return ns.Guild:GetLootRules()") == RULES
    res = bob.eval_py("local ok, e = ns.Guild:SetLootRules({ f = 50, s = 'p', l = 'l', w = 'r', y = 'n' }); "
                      "return { ok = ok, e = e }")
    assert res["ok"] is False and "Guild Master" in res["e"], res
    res = gina.eval_py("local ok, e = ns.Guild:SetLootRules({ f = 60, s = 'p', l = 'r', w = 'd', y = 'a' }); "
                       "return { ok = ok, e = e }")
    assert res["ok"] is True, res
    w.tick(5)
    want = {"f": 60, "s": "p", "l": "r", "w": "d", "y": "a"}
    for x in (bob, tank):
        assert x.eval_py("return ns.Guild:GetLootRules()") == want, x.name
    # junk is refused
    res = gina.eval_py("local ok, e = ns.Guild:SetLootRules({ f = 300, s = 'x' }); return { ok = ok }")
    assert res["ok"] is False


@case
def dry_streak_counts_only_nights_they_were_really_there():
    w, c = world()
    bob = c["Bob"]
    # Heal came to n7 for 20 minutes without a kill: not a night of theirs (default), counted with "any night"
    specs = [{"id": "n14", "ago": 14, "att": {"Heal": 4}}, {"id": "n7", "ago": 7, "att": {"Heal": 0}},
             {"id": "n1", "ago": 1, "att": {"Heal": 3}}]
    nights(bob, specs)
    bob.eval("""local id, key = ...
        local rec = ns.db.raids[id]
        local a = rec.att[key]
        a.s = { rec.start, rec.start + 20 * 60 }
        a.l = rec.start + 20 * 60
        ns:Fire('RAIDLOG_CHANGED')""", "n7", K("Heal"))
    d = dry(bob, "Heal")
    assert d["nights"] == 2 and d["came"] == 3, d
    bob.eval("ns.Guild.GetLootRules = function() return { f = 0, s = 'r', l = 'l', w = 'r', y = 'a' } end")
    d = dry(bob, "Heal")
    assert d["nights"] == 3, d


if __name__ == "__main__":
    run_all(globals())
