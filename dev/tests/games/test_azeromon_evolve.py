"""Azeromon: the evolution scene.

Covers: the next form loads while "What? X is evolving!" is read; the animation (both forms, silhouettes, swapping,
the white flash) ends in the new form without reloading it; X stops it ("Huh? ... stopped evolving!"), and a stopped
beast waits until it gains a level before trying again; bots without a UI get through it on their own.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_evolve.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def game(ui=True):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(5)")
    c.eval("ns.Azero:NewGame()")
    c.eval("ns.Azero.save.party = { ns.AzeroMon.New('emberwhelp', 16, ns.Azero.rng) }")
    if ui:
        c.slash("/dz play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.3)
        c.eval("T_AZ.settle()")
    return w, c


def pending(c):
    return c.eval_py("local p = ns.Azero.pending return p and { kind = p.kind, text = p.text }")


@case
def the_animation_swaps_the_forms_and_ends_in_the_new_one():
    w, c = game()
    c.eval("ns.Azero:Run(function(g) g:EvolveNow(g.save.party[1], 'flamescale') end)")
    w.tick(0.1)
    assert "is evolving" in (pending(c) or {}).get("text", ""), pending(c)
    ev = c.eval_py("return ns.AzeroUI._Evolve()")
    assert ev["m1"] == "emberwhelp" and ev["m2"] == "flamescale" and ev["a2"] == 0, ev   # loading, hidden
    w.tick(2)                                                    # (both measured meanwhile)
    for _ in range(4):
        if pending(c)["kind"] == "evolve":
            break
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.1)
    assert pending(c)["kind"] == "evolve"
    seen = set()
    flash = 0
    for _ in range(60):
        w.tick(0.1)
        e = c.eval_py("return ns.AzeroUI._Evolve()")
        if not pending(c) or pending(c)["kind"] != "evolve":
            break
        assert e["glow"], e
        seen.add((e["a1"], e["a2"]))
        flash = max(flash, e["flash"])
    assert (1, 0) in seen and (0, 1) in seen and flash > 0.5, (seen, flash)       # swapped both ways, flashed
    assert c.eval("return ns.Azero.save.party[1].sp") == "flamescale"
    e = c.eval_py("return ns.AzeroUI._Evolve()")
    assert e["m2"] == "flamescale" and e["a2"] == 1 and e["m1"] is False, e      # the new form stays where it loaded
    no_errors(w)


@case
def x_stops_it_and_it_waits_for_the_next_level():
    w, c = game()
    c.eval("ns.Azero:Run(function(g) g:EvolveNow(g.save.party[1], 'flamescale') end)")
    for _ in range(6):
        if pending(c) and pending(c)["kind"] == "evolve":
            break
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.1)
    w.tick(1)
    c.eval("ns.AzeroUI._HandleKey('B')")
    w.tick(0.2)
    assert "stopped evolving" in (pending(c) or {}).get("text", ""), pending(c)
    r = c.eval_py("local m = ns.Azero.save.party[1] return { sp = m.sp, stop = m.evoStop }")
    assert r == {"sp": "emberwhelp", "stop": 16}, r
    no_errors(w)
    # the next battle at the same level: no second try; after a level: it evolves
    w2, c2 = game(ui=False)
    r = c2.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      local mon = G.save.party[1]
      mon.evoStop = 16
      local function fight()
        G:Run(function(g) local f = M.New('wolfpup', 2, g.rng) f.hp = 1 g:RunBattle({ f }, nil) end)
        T_AZ.settle()
      end
      fight()
      local after1 = mon.sp
      mon.lvl = 17
      fight()
      return { after1 = after1, after2 = mon.sp, stop = mon.evoStop or false }""")
    assert r == {"after1": "emberwhelp", "after2": "flamescale", "stop": False}, r
    no_errors(w2)


if __name__ == "__main__":
    run_all()
