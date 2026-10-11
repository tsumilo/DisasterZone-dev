"""Demo scenarios (1.3.5, Core/DemoScenarios.lua): each one stages a roll on the demo raid and shows what its chat hint
says - with the default loot rules and with the Council > Rules choice the hint names.

Run: luaenv\\Scripts\\python.exe tests\\votes\\test_demo_scenarios.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all, solo  # noqa: E402

DEFAULT = {"f": 0, "s": "r", "l": "l", "w": "r", "y": "n", "o": 0, "q": "h"}


def world():
    w, c = solo("Gina", guild_rank=0, tick=4)
    c.slash("/dz demo on")
    w.tick(2)
    return w, c


def run(world_, c, key, **rules):
    if rules:
        r = dict(DEFAULT, **rules)
        assert c.eval_py("return (ns.Guild:SetLootRules(...))", r) is True
    ok = c.eval_py("local ok, e = ns.Demo:RunScenario(...); return { ok = ok, e = e }", key)
    assert ok["ok"] is True, ok
    world_.tick(10, 0.5)
    res = c.eval_py("""local a = ns.Roll:GetActive()
        local out = { rows = {} }
        for i, r in ipairs(ns.Roll:GetResults(a.id)) do
            out.rows[i] = { name = r.name, suggested = r.suggested or false, split = r.split or false,
                            low = r.lowAtt and true or false, cantUse = r.cantUse or false, votes = r.votes,
                            roll = r.roll }
        end
        out.plain = a.plain and true or false
        return out""")
    rows = list(res["rows"].values()) if isinstance(res["rows"], dict) else list(res["rows"])
    sug = [r["name"] for r in rows if r["suggested"]]
    return (sug[0] if sug else None), rows, res


def names(rows):
    return {r["name"] for r in rows}


@case
def split_vote():
    w, c = world()
    sug, rows, _ = run(w, c, "split")
    assert sug == "Orinel" and names(rows) <= {"Orinel", "Brakka", "Quillon", "Kaelyn", "Caelith", "Mirabel", "Gina"}, rows
    assert sum(1 for r in rows if r["split"]) == 3, rows
    sug, _, _ = run(w, c, "split", s="p")
    assert sug is None


@case
def popular_but_absent():
    w, c = world()
    sug, rows, _ = run(w, c, "absent")
    assert sug == "Quillon", (sug, rows)
    sug, rows, _ = run(w, c, "absent", f=50)
    assert sug == "Caelith" and any(r["low"] for r in rows if r["name"] == "Quillon"), (sug, rows)


@case
def dry_streak_vs_fresh_loot():
    w, c = world()
    assert run(w, c, "dry")[0] == "Kaelyn"
    assert run(w, c, "dry", w="d")[0] == "Grimtusk"


@case
def longest_use():
    w, c = world()
    assert run(w, c, "longest")[0] == "Brakka"
    assert run(w, c, "longest", o=4)[0] == "Aldrin"


@case
def wrong_class():
    w, c = world()
    sug, rows, _ = run(w, c, "class")
    k = [r for r in rows if r["name"] == "Kaelyn"][0]
    assert k["cantUse"] and sug == "Aldrin", (sug, rows)


@case
def prized_you_qualify_gets_the_window_and_prizedno_the_notice():
    w, c = world()
    run(w, c, "prized")
    assert c.eval("return ns.RollFrame.frame ~= nil and ns.RollFrame.frame:IsShown() or false")
    c.eval("ns.RollFrame:Hide()")
    run(w, c, "prizedno")
    assert not c.eval("return ns.RollFrame.frame ~= nil and ns.RollFrame.frame:IsShown() or false")
    assert c.eval("return #ns.Notify:List({ kind = 'lootNotEligible' })") >= 1


@case
def plain_roll_highest_wins():
    w, c = world()
    sug, rows, res = run(w, c, "plain")
    assert res["plain"] and sug == "Kaelyn", (sug, rows)


@case
def slash_and_demo_off_clear_it():
    w, c = world()
    c.slash("/dz demo split")
    w.tick(1)
    assert c.eval("return ns.Demo:GetActiveScenario() ~= nil")
    c.slash("/dz demo off")
    w.tick(1)
    assert c.eval("return ns.Demo:GetActiveScenario() == nil")


if __name__ == "__main__":
    run_all(globals())
