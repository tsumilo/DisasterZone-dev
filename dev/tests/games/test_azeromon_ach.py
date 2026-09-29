"""Azeromon: the event feed and achievements.

Covers: achievements earned from real game flows (taming a wild beast, a real trainer battle reporting which beasts
fought), conditional ones (Hogger without a Fire type / with a single beast), lifetime counters that survive a new
game and never award twice, retroactive awards when a save loads, a failing listener not breaking the game, the
toast (Blizzard's achievement artwork) with the achievement jingle, and the Achievements page in the start menu.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_ach.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def game(seed=7):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    return w, c


def earned(c):
    return sorted(c.eval_py("local t = {} for id in pairs(ns.AzeroAch.Earned()) do t[#t + 1] = id end return t") or [])


def toasts(c):
    return c.eval_py("local f = ns.AzeroAch:ToastFrame() return f and f:IsShown() and f.name:GetText() or nil")


@case
def taming_a_wild_beast_earns_beast_friend_with_toast_and_jingle():
    w, c = game()
    c.eval("ns.Azero:Run(function(g) g:GiveMon('murkling', 5) end)")   # a gift is not a taming
    c.eval("T_AZ.settle()")
    assert "tame1" not in earned(c)
    n0 = c.eval("return #__MOCK.sounds") or 0
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('owlet', 3, ns.Azero.rng), 'caught')")
    assert "tame1" in earned(c)
    assert toasts(c) == "Beast Friend"
    sounds = c.eval_py("return __MOCK.sounds")
    assert 12891 in sounds[n0:], sounds[n0:]
    w.tick(7)                                             # the toast plays out and hides
    assert toasts(c) is None
    no_errors(w)


@case
def a_real_trainer_battle_reports_which_beasts_fought():
    w, c = game()
    c.eval("""local M = ns.AzeroMon
      local lead = M.New('murkling', 30, ns.Azero.rng); lead.moves = M.DefaultMoves('murkling', 30)
      ns.Azero.save.party = { lead, M.New('emberwhelp', 30, ns.Azero.rng) }
      T_SEEN = nil
      ns.Azero:On('battle', function(g, e) T_SEEN = e end)
      ns.Azero:Run(function(g) g:Battle('hogger') end)""")
    c.eval("T_AZ.settle()")
    seen = c.eval_py("return { result = T_SEEN.result, trainer = T_SEEN.trainer, used = T_SEEN.used }")
    assert seen["result"] == "win" and seen["trainer"] == "hogger", seen
    assert seen["used"] == ["murkling"], seen                # the Emberwhelp never came out
    got = earned(c)
    for a in ("hoggernofire", "hoggersolo"):         # (Hogwash comes with the badge, in the Hogger encounter)
        assert a in got, got
    no_errors(w)


@case
def conditions_are_checked_per_battle():
    w, c = game()
    c.eval("ns.Azero:Emit('battle', { result = 'win', trainer = 'hogger', used = { 'emberwhelp', 'murkling' } })")
    got = earned(c)
    assert "hoggernofire" not in got and "hoggersolo" not in got, got     # a Fire type fought, and two beasts
    c.eval("ns.Azero:Emit('battle', { result = 'lose', trainer = 'hogger', used = { 'murkling' } })")
    assert "hoggersolo" not in earned(c)
    c.eval("ns.Azero:Emit('battle', { result = 'win', trainer = 'hogger', used = { 'lashling' } })")
    got = earned(c)
    assert "hoggernofire" in got and "hoggersolo" in got, got
    no_errors(w)


@case
def counters_survive_a_new_game_and_nothing_is_awarded_twice():
    w, c = game()
    for _ in range(9):
        c.eval("ns.Azero:Emit('battle', { result = 'win', trainer = 'hunter1', used = {} })")
    assert "trainers10" not in earned(c)
    c.eval("ns.Azero:NewGame()")                          # lifetime stats are not tied to the save
    c.eval("ns.Azero:Emit('battle', { result = 'win', trainer = 'hunter1', used = {} })")
    assert "trainers10" in earned(c)
    fired = c.eval_py("""T_N = 0 ns.Azero:On('achievement', function() T_N = T_N + 1 end)
      for i = 1, 5 do ns.Azero:Emit('battle', { result = 'win', trainer = 'hunter1', used = {} }) end
      return T_N""")
    assert fired == 0
    assert c.eval("return ns.AzeroAch:Points()") >= 10
    no_errors(w)


@case
def a_loaded_save_earns_what_it_already_deserves():
    w, c = game()
    c.eval("""local s = ns.Azero.save
      for i, id in ipairs(ns.AzeroData.dexOrder) do if i <= 10 then s.caught[id] = true end end
      s.flags.badge_hogger = true""")
    assert "tame10" not in earned(c)
    c.eval("ns.Azero:Load()")
    got = earned(c)
    assert "tame10" in got and "hogger" in got, got
    no_errors(w)


@case
def a_failing_listener_does_not_break_the_game():
    w, c = game()
    c.eval("ns.Azero:On('tame', function() error('boom from a listener') end)")
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('owlet', 3, ns.Azero.rng), 'caught')")
    assert c.eval("return #ns.Azero.save.party") == 1       # the taming itself went through
    assert "tame1" in earned(c)                            # and the other listeners still ran
    no_errors(w, allow=("boom from a listener",))


@case
def the_achievements_page_opens_from_the_start_menu():
    w, c = game()
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('owlet', 3, ns.Azero.rng), 'caught')")
    c.slash("/cdl play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")                    # title: CONTINUE
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("ns.AzeroUI._HandleKey('START')")
    w.tick(0.1)
    for k in ("down", "down", "down", "A"):                 # BESTIARY, PARTY, BAG, ACHIEVEMENTS
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)
    titles = [l["title"] for l in c.eval_py("return ns.AzeroUI._Levels()")]
    assert any(t.startswith("ACHIEVEMENTS") and "1 / " in t and "10 points" in t for t in titles), titles
    no_errors(w)


if __name__ == "__main__":
    run_all()
