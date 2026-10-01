"""Azeromon: the stable (Stable Masters Erma in Goldshire and Kirk Maxwell in Sentinel Hill).

Covers: a beast caught with a full party goes to the stable; taking beasts out (not past a full party) and leaving
them (never the last one that can fight); both Stable Masters share one stable; the menus through the UI.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_stable.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def game(seed=7, ui=False):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    if ui:
        c.eval("ns.Azero:AddMon(ns.AzeroMon.New('owlet', 3, ns.Azero.rng), 'caught')")
        c.slash("/dz play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.3)
        c.eval("T_AZ.settle()")
    return w, c


def key(w, c, *keys):
    for k in keys:
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)


def title(c):
    lv = c.eval_py("return ns.AzeroUI._Levels()") or []
    return lv[-1]["title"] if lv else None


def talk(w, c, until_kind="stable"):
    key(w, c, "A")
    for _ in range(20):
        if c.eval("return ns.Azero.pending and ns.Azero.pending.kind") == until_kind:
            return
        key(w, c, "A")
        w.tick(0.2)


@case
def a_full_party_sends_the_catch_to_the_stable_and_it_comes_back_out():
    w, c = game()
    r = c.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      for i = 1, 6 do G:AddMon(M.New('wolfpup', 3 + i, G.rng), 'caught') end
      local where = G:AddMon(M.New('owlet', 4, G.rng), 'caught')
      local full = { G:Withdraw(1) }
      local dep = { G:Deposit(2) }
      local out = { G:Withdraw(1) }
      return { where = where, party = #G.save.party, box = #G.save.box, full = full, dep = dep, out = out,
               last = G.save.party[6].sp }""")
    assert r["where"] == "box" and r["full"][0] is False and "party is full" in r["full"][1], r
    assert r["dep"][0] is True and r["out"] == [True, "Owlet rejoined your party."], r
    assert r["party"] == 6 and r["box"] == 1 and r["last"] == "owlet", r
    no_errors(w)


@case
def the_last_beast_that_can_fight_stays_with_you():
    w, c = game()
    r = c.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      local a, b = M.New('wolfpup', 5, G.rng), M.New('owlet', 5, G.rng)
      b.hp = 0
      G.save.party = { a, b }
      local keepFighter = { G:Deposit(1) }
      local fainted = { G:Deposit(2) }
      local alone = { G:Deposit(1) }
      return { keepFighter = keepFighter[1], fainted = fainted[1], alone = alone[1], n = #G.save.party }""")
    assert r == {"keepFighter": False, "fainted": True, "alone": False, "n": 1}, r
    no_errors(w)


@case
def erma_and_kirk_share_one_stable_through_the_menus():
    w, c = game(ui=True)
    c.eval("""local G, M = ns.Azero, ns.AzeroMon
      G.save.box = { M.New('coyote', 12, G.rng), M.New('tuskling', 9, G.rng) }
      G.save.box[2].shiny = true
      G:EnterMap('post', 7, 5, 'right', true)""")
    w.tick(0.2)
    talk(w, c)
    assert title(c) == "STABLE", title(c)
    assert "In the stable: 2 beasts" in c.eval("return ns.AzeroUI._DescText()")
    key(w, c, "A")                                                   # Take a beast out
    assert title(c) == "IN THE STABLE (2)", title(c)
    assert "Coyote  Lv12  Beast" in c.eval("return ns.AzeroUI._DescText()")
    key(w, c, "A", "A")                                              # Coyote > Take out
    w.tick(0.2)
    for _ in range(5):
        if title(c) == "STABLE":
            break
        key(w, c, "A")
        w.tick(0.2)
    assert title(c) == "STABLE"
    assert [m["sp"] for m in c.eval_py("local o = {} for i, m in ipairs(ns.Azero.save.party) do o[i] = { sp = m.sp } end return o")] == ["owlet", "coyote"]
    key(w, c, "down", "A")                                           # Leave a beast here
    assert title(c) == "LEAVE WHICH BEAST?", title(c)
    key(w, c, "A")                                                   # the owlet
    for _ in range(5):
        if title(c) == "STABLE":
            break
        key(w, c, "A")
        w.tick(0.2)
    key(w, c, "down", "down", "A")                                   # Done
    for _ in range(10):
        if c.eval("return ns.Azero.pending == nil"):
            break
        key(w, c, "A")
        w.tick(0.2)
    assert c.eval("return #ns.Azero.save.box") == 2 and c.eval("return ns.Azero.save.box[2].sp") == "owlet"
    # Kirk Maxwell in Sentinel Hill has the same stable
    c.eval("ns.Azero:EnterMap('sentinelinn', 7, 5, 'right', true)")
    w.tick(0.2)
    talk(w, c)
    assert title(c) == "STABLE" and "In the stable: 2 beasts" in c.eval("return ns.AzeroUI._DescText()")
    no_errors(w)


if __name__ == "__main__":
    run_all()
