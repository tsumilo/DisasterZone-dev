"""Azeromon: the battle info boxes.

Covers: the name never runs into the level (the longest species name fits); the chip row shows the type, the status
with sleep turns left, each stat change (+/-) and a flask; too many effects fold into a "+n" chip that lists the rest;
the boxes follow the playback (the snapshot of each event), not the engine ahead of it.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_battlebox.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def battle(foe="rustgolem"):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(4)")
    c.eval("ns.Azero:NewGame()")
    c.eval("local M = ns.AzeroMon ns.Azero.save.party = { M.New('murkling', 30, ns.Azero.rng) }")
    c.slash("/cdl play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("ns.Azero:Run(function(g) g:WildBattle(%r, 10) end)" % foe)
    for _ in range(80):                                  # play the intro until the action menu is up
        w.tick(0.2)
        if c.eval("return ns.Azero.battle and ns.Azero.battle.need") == "action" and c.eval_py("return ns.AzeroUI._State()")["stack"] >= 1:
            break
        c.eval("ns.AzeroUI._HandleKey('A')")
    return w, c


def boxes(c):
    return c.eval_py("return ns.AzeroUI._Boxes()")


def replay(w, c, lua):
    """Change the battle, then let one event carry the new state to the boxes."""
    c.eval("local b = ns.Azero.battle " + lua + " b:Say('...')")
    for _ in range(10):
        w.tick(0.3)


@case
def names_never_reach_the_level_and_the_type_shows():
    w, c = battle()
    b = boxes(c)
    assert b["foe"] and b["foe"]["name"] == "Rusty Harvest Golem" and b["foe"]["lvl"] == "Lv10", b
    assert b["foe"]["chips"] == ["MECH"] and b["ally"]["chips"] == ["WATER"], b
    assert b["foe"]["nameW"] <= b["foe"]["w"] - 32 - 58, b
    no_errors(w)


@case
def effects_show_with_turns_left():
    w, c = battle()
    replay(w, c, "b.foe.stages.atk = -1 b.foe.stages.spe = 2 b.ally.mon.status = 'slp' b.ally.mon.sleep = 2")
    b = boxes(c)
    assert b["foe"]["chips"] == ["MECH", "Atk -1", "Spe +2"], b
    assert b["ally"]["chips"] == ["WATER", "SLP 2"], b
    replay(w, c, "b.ally.mon.status = nil b.ally.mon.sleep = nil b.ally.mon.flask = { id = 'flasktitans', n = 4 }")
    assert boxes(c)["ally"]["chips"] == ["WATER", "FLASK 4"], boxes(c)
    no_errors(w)


@case
def too_many_effects_fold_into_more():
    w, c = battle()
    replay(w, c, "for _, st in ipairs({ 'atk', 'def', 'spa', 'spd', 'spe' }) do b.ally.stages[st] = -2 end "
                 "b.ally.mon.status = 'psn' b.ally.mon.flask = { id = 'flasksupreme', n = 9 }")
    chips = boxes(c)["ally"]["chips"]
    assert chips[0] == "WATER" and chips[1] == "PSN" and chips[-1].startswith("+"), chips
    hidden = int(chips[-1][1:])
    assert len(chips) - 1 + hidden == 8, chips                  # type, status, 5 stats, flask
    no_errors(w)


@case
def a_move_without_pp_says_so_above_the_move_list():
    w, c = battle()
    c.eval("ns.Azero.battle.ally.mon.moves[1].pp = 0")
    c.eval("ns.AzeroUI._HandleKey('A')")                    # FIGHT
    w.tick(0.1)
    before = c.eval_py("return ns.AzeroUI._TextOnTop()")
    c.eval("ns.AzeroUI._HandleKey('A')")                    # the empty move
    w.tick(0.1)
    t = c.eval_py("return ns.AzeroUI._TextOnTop()")
    assert t["shown"] and t["text"] == "There's no PP left for this move!" and t["level"] > t["menu"], t
    for _ in range(4):
        if not c.eval_py("return ns.AzeroUI._State()")["msg"]:
            break
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.1)
    t = c.eval_py("return ns.AzeroUI._TextOnTop()")
    assert not t["shown"] and t["level"] == before["level"], (t, before)      # the move list is back as it was
    assert c.eval_py("return ns.AzeroUI._MenuItems()")[0] == c.eval("return ns.AzeroData.moves[ns.Azero.battle.ally.mon.moves[1].id].name")
    c.eval("ns.AzeroUI._HandleKey('right')")               # another move still works
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.1)
    assert c.eval("return ns.Azero.battle.need") != "action" or c.eval_py("return ns.AzeroUI._State()")["stack"] == 0
    no_errors(w)


@case
def with_no_pp_at_all_it_struggles():
    w, c = battle()
    c.eval("for _, mv in ipairs(ns.Azero.battle.ally.mon.moves) do mv.pp = 0 end")
    c.eval("ns.AzeroUI._HandleKey('A')")                    # FIGHT
    w.tick(0.1)
    assert c.eval_py("return ns.AzeroUI._TextOnTop()")["text"] == "Murkling has no moves left!"
    said = []
    for _ in range(40):
        t = c.eval("return ns.AzeroUI._TextOnTop().text")
        if t and t not in said:
            said.append(t)
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.2)
    assert any("Struggle" in x for x in said), said
    no_errors(w)


@case
def the_move_list_opens_on_the_last_move_used():
    w, c = battle(foe="dustdevil")
    c.eval("ns.Azero.battle.foe.mon.hp = 999")                  # a long fight
    c.eval("ns.AzeroUI._HandleKey('A')")                        # FIGHT
    assert c.eval_py("return ns.AzeroUI._MenuLayout()")["cursor"] == 1
    c.eval("ns.AzeroUI._HandleKey('right')")
    c.eval("ns.AzeroUI._HandleKey('A')")                        # the second move
    for _ in range(80):                                        # play the turn out
        w.tick(0.2)
        if c.eval("return ns.Azero.battle and ns.Azero.battle.need") == "action" and c.eval_py("return ns.AzeroUI._State()")["stack"] >= 1:
            break
        c.eval("ns.AzeroUI._HandleKey('A')")
    assert c.eval_py("return ns.AzeroUI._MenuLayout()")["cursor"] == 1      # the action menu: FIGHT again
    c.eval("ns.AzeroUI._HandleKey('A')")
    assert c.eval_py("return ns.AzeroUI._MenuLayout()")["cursor"] == 2      # the move list: the move it used
    c.eval("ns.AzeroUI._HandleKey('B')")                        # back: the action menu stays on FIGHT
    assert c.eval_py("return ns.AzeroUI._MenuLayout()")["cursor"] == 1
    no_errors(w)


@case
def the_move_panel_says_how_a_move_does_against_this_foe():
    w, c = battle()                                             # Murkling (Water) vs a Rusty Harvest Golem (Mech)
    c.eval("ns.AzeroUI._HandleKey('A')")                        # FIGHT
    moves = c.eval_py("local o = {} for i, m in ipairs(ns.Azero.battle.ally.mon.moves) do o[i] = m.id end return o")
    seen = {}
    for i, mv in enumerate(moves):
        if i:
            c.eval("ns.AzeroUI._HandleKey('%s')" % ("right" if i % 2 else "down"))
            if i == 2:
                c.eval("ns.AzeroUI._HandleKey('left')")
        seen[mv] = c.eval("return ns.AzeroUI._MoveEff()")
    assert seen.get("waterjet") == "Super effective" and seen.get("bite") == "Not very effective", seen
    assert seen.get("leer") == "", seen                          # a status move: no damage to judge
    # the type chip's tooltip lists the matchups
    assert c.eval_py("return ns.AzeroUI._Matchups('MECH')") == ["Weak to: Fire, Water", "Resists: Beast, Nature, Air, Shadow, Mech"]
    assert c.eval_py("return ns.AzeroUI._Matchups('AIR')")[-1] == "Immune to: Earth"
    no_errors(w)


if __name__ == "__main__":
    run_all()
