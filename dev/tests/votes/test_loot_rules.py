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
                response = s[3] and "roll" or (s[7] and "pass" or nil), tier = s[4] or 4, att = s[5], dry = s[6],
                longevity = s[8], cantUse = s[9] or nil }
end
ns.Roll:RankRows(rows, { rules = rules })
local out = {}
for i, r in ipairs(rows) do
    out[i] = { key = r.key, suggested = r.suggested, split = r.split, low = r.lowAtt, tie = r.tie }
end
return out
"""
RULES = {"f": 0, "s": "r", "l": "l", "w": "r", "y": "n", "o": 0, "q": "h"}


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
    want = {"f": 60, "s": "p", "l": "r", "w": "d", "y": "a", "o": 0, "q": "h"}
    for x in (bob, tank):
        assert x.eval_py("return ns.Guild:GetLootRules()") == want, x.name
    # junk is refused
    res = gina.eval_py("local ok, e = ns.Guild:SetLootRules({ f = 300, s = 'x' }); return { ok = ok }")
    assert res["ok"] is False
    # longevity: its own criterion beside the dry streak (driest first + longest use counted up to P5); a "count
    # up to" outside P3-P5 is junk
    res = gina.eval_py("local ok = ns.Guild:SetLootRules({ f = 0, s = 'r', l = 'l', w = 'd', y = 'n', o = 5 }); "
                       "return { ok = ok }")
    assert res["ok"] is True, res
    w.tick(5)
    for x in (bob, tank):
        got = x.eval_py("return ns.Guild:GetLootRules()")
        assert got["w"] == "d" and got["o"] == 5, (x.name, got)
    res = gina.eval_py("local ok = ns.Guild:SetLootRules({ f = 0, s = 'r', l = 'l', w = 'r', y = 'n', o = 9 }); "
                       "return { ok = ok }")
    assert res["ok"] is False


@case
def a_class_that_cannot_use_it_is_never_suggested_and_sits_with_the_passes():
    w, c = world()
    # the user's in-game case: Bracers of the Forgotten Conqueror, one vote each for Kaelyn (a shaman: can't use the
    # token, rolled 42) and Caelith (no roll); Brakka can't use it either and rolled 99; Dan passed
    spec = [["Kaelyn", 1, 42, 4, 97, 0, None, None, True], ["Caelith", 1, None, 1, 100, 2],
            ["Brakka", 0, 99, 4, 88, 0, None, None, True], ["Mira", 0, 30, 4, 90, 1], ["Dan", 0, None, 4, 90, 0, True]]
    order, sug, rows = rank(c["Bob"], spec)
    assert sug != "Kaelyn" and not rows["Kaelyn"].get("split"), (order, sug, rows)
    # Kaelyn's vote doesn't count: Caelith has the only vote that does (no roll), so no split
    assert not rows["Caelith"].get("split"), rows
    assert order[-3:] and set(order[-3:]) == {"Kaelyn", "Brakka", "Dan"}, order   # at the bottom with the pass
    assert order.index("Mira") < order.index("Brakka"), order


@case
def longest_use_first_within_a_list():
    w, c = world()
    # name, votes, roll, tier, att, dry, pass, longevity: same list; Ana rolled higher, Bo keeps it longer
    spec = [["Ana", 0, 90, 1, 100, 0, None, 1], ["Bo", 0, 20, 1, 100, 0, None, 3], ["Cy", 0, 95, 4, 100, 0, None, 4]]
    order, sug, _ = rank(c["Bob"], spec)
    assert sug == "Ana", (order, sug)                     # the roll (default)
    order, sug, _ = rank(c["Bob"], spec, o=4)
    assert sug == "Bo" and order[:2] == ["Bo", "Ana"], (order, sug)   # longest use inside the BiS list
    assert order[2] == "Cy"                              # lists first still comes before it
    # with the dry streak on too, longest use goes first, then the driest, then the roll
    spec2 = [["Ana", 0, 90, 1, 100, 6, None, 2], ["Bo", 0, 20, 1, 100, 1, None, 3], ["Di", 0, 50, 1, 100, 3, None, 2]]
    order, sug, _ = rank(c["Bob"], spec2, o=4, w="d")
    assert order == ["Bo", "Ana", "Di"], order
    order, sug, _ = rank(c["Bob"], spec2, w="d")
    assert order == ["Ana", "Di", "Bo"], order                       # longest use off: the driest first
    # rules saved while longest use was a "then" choice (w = "o", h = 4) read as o = 4, w = "r"
    got = c["Bob"].eval_py("return ns.Guild:CleanLootRules({ f = 0, s = 'r', l = 'l', w = 'o', y = 'n', h = 4 })")
    assert got["o"] == 4 and got["w"] == "r", got


# Store:Longevity: phases a pick stays on the list, from the guild's phase up to the last phase counted
LONGEVITY = r"""
local picks = ...
for _, p in ipairs(picks) do ns.BiS:SetSlot(p[1], 11, "main", p[2]) end
ns.BiS:Commit()
local me = ns.Util.PlayerKey()
local out = {}
for i, q in ipairs({ { 2, 4 }, { 2, 5 }, { 3, 5 } }) do
    out[i] = (ns.Store:Longevity(me, 28763, q[1], q[2]))
end
return out
"""


@case
def longevity_counts_the_phases_a_pick_stays():
    w, c = world()
    bob = c["Bob"]
    # P2-P4 the Jade Ring, replaced in P5 by another ring
    assert bob.eval_py(LONGEVITY, [[2, 28763], [3, 28763], [4, 28763], [5, 28757]]) in ([3, 3, 2], {1: 3, 2: 3, 3: 2})
    w2, c2 = world()
    # kept in P5: the same up to P4, one more up to P5
    assert c2["Bob"].eval_py(LONGEVITY, [[2, 28763], [3, 28763], [4, 28763], [5, 28763]]) in ([3, 4, 3], {1: 3, 2: 4, 3: 3})
    w3, c3 = world()
    # P3 not filled in yet: skipped (doesn't count, doesn't end it)
    assert c3["Bob"].eval_py(LONGEVITY, [[2, 28763], [4, 28763]]) in ([2, 2, 1], {1: 2, 2: 2, 3: 1})


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



def example(cl):
    res = cl.eval_py("local rows, why = ns.CouncilRulesUI:GetExample(); return { rows = rows, why = why }")
    rows = list(res["rows"].values()) if isinstance(res["rows"], dict) else list(res["rows"])
    sug = [r["name"] for r in rows if r["suggested"]]
    return (sug[0] if sug else None), rows, res["why"]


@case
def council_rules_view_reranks_the_example_and_the_gm_saves():
    w, c = world()
    gina, bob = c["Gina"], c["Bob"]
    gina.eval("ns.MainFrame:Open('council'); ns.CouncilUI:SetView('rules')")
    w.tick(1)
    assert gina.eval("return DisasterZoneCouncilRules ~= nil and DisasterZoneCouncilRules:IsShown()")
    sug, rows, why = example(gina)
    assert sug == "Orinel" and "the only one of them who rolled" in why, (sug, why)
    gina.eval("ns.CouncilRulesUI:SetChoice('s', 'p')")
    sug, rows, why = example(gina)
    assert sug is None and "council picks" in why, (sug, why)
    draft, dirty = gina.eval_py("local d, x = ns.CouncilRulesUI:GetDraft(); return { d = d, x = x }").values()         if False else (None, None)
    res = gina.eval_py("local d, x = ns.CouncilRulesUI:GetDraft(); return { d = d, x = x }")
    assert res["x"] is True and res["d"]["s"] == "p", res
    # nothing is shared until Save & share
    assert bob.eval_py("return ns.Guild:GetLootRules()")["s"] == "r"
    assert gina.eval("return (ns.CouncilRulesUI:Save())") is True
    w.tick(5)
    assert bob.eval_py("return ns.Guild:GetLootRules()")["s"] == "p"
    res = gina.eval_py("local d, x = ns.CouncilRulesUI:GetDraft(); return { d = d, x = x }")
    assert res["x"] is False, res


@case
def council_members_see_the_rules_read_only():
    w, c = world()
    bob = c["Bob"]
    bob.eval("ns.MainFrame:Open('council'); ns.CouncilUI:SetView('rules')")
    w.tick(1)
    bob.eval("ns.CouncilRulesUI:SetChoice('f', 75)")
    res = bob.eval_py("local d, x = ns.CouncilRulesUI:GetDraft(); return { d = d, x = x }")
    assert res["x"] is False and res["d"]["f"] == 0, res


@case
def the_drop_panel_marks_a_split_and_the_floor():
    w, c = world()
    gina = c["Gina"]
    gina.slash("/dz demo on")
    w.tick(2)
    gina.eval("ns.Guild:SetLootRules({ f = 101 })")   # (junk: refused)
    assert gina.eval("return (ns.Guild:SetLootRules({ f = 75, s = 'p', l = 'l', w = 'r', y = 'n' }))") is True
    gina.eval("ns.Loot:SimulateDrop()")
    w.tick(1)
    gina.eval("local b = ns.DropPanel.blocks[1]; ns.DropPanel:StartRoll(b.itemID)")
    w.tick(12, 1)
    gina.eval("ns.DropPanel:Render()")
    out = gina.eval_py("""
        local out = {}
        for _, r in ipairs(ns.DropPanel.blocks[1].rows) do
            if r:IsShown() and r.rollRow and r.data then
                out[#out + 1] = { low = r.data.lowAtt and true or false, tag = r.tag:GetText() or "",
                                  sug = r.data.suggested or false }
            end
        end
        return out""")
    out = list(out.values()) if isinstance(out, dict) else list(out or [])
    lows = [r for r in out if r["low"]]
    for r in lows:
        assert "under 75%" in r["tag"] and not r["sug"], r


if __name__ == "__main__":
    run_all(globals())
