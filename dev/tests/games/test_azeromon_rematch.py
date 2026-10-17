"""Azeromon: trainer rematches.

Covers: a beaten trainer's team grows to about the player's strongest beast and evolves where the level allows; the
rematch is offered once a day (WoW's daily reset) and a win marks it; bosses who left and the rival's first battle
never rematch; "Win a trainer battle" bounties count rematches.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_rematch.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

NOW = 1790000000


def game():
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(9)")
    c.eval("ns.Azero:NewGame()")
    c.eval("ns.AzeroBounty.clock = %d ns.AzeroBounty.resetIn = 3600" % NOW)
    c.eval("""local M = ns.AzeroMon
      local m = M.New('murkling', 30, ns.Azero.rng) m.moves = M.DefaultMoves('murkling', 30)
      ns.Azero.save.party = { m }
      ns.Azero:SetFlag('beat_druid1')""")
    return w, c


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


@case
def a_rematch_team_grows_and_evolves():
    w, c = game()
    team = c.eval_py("""local o = {}
      for i, m in ipairs(ns.Azero:RematchTeam('druid1')) do o[i] = { sp = m.sp, lvl = m.lvl } end
      return o""")
    assert team == [{"sp": "screecher", "lvl": 28}, {"sp": "goretusk", "lvl": 29}], team   # both grew up
    # a weak party: never below their first team
    c.eval("ns.Azero.save.party[1].lvl = 2")
    low = c.eval_py("local t = ns.Azero:RematchTeam('druid1') return { t[1].lvl, t[2].lvl, t[2].sp }")
    assert low == [4, 5, "tuskling"], low
    no_errors(w)


@case
def once_a_day_and_a_win_counts_for_bounties():
    w, c = game()
    c.eval("T_AZ.policy = T_AZ.reader")                # (an even fight since 0.36: play the rule list, not the strongest move)
    c.eval("""local M = ns.AzeroMon                    -- (a Tidehunter: the grown-up team hits harder now)
      local m = M.New('tidehunter', 32, ns.Azero.rng) m.moves = M.DefaultMoves('tidehunter', 32)
      local m2 = M.New('tidehunter', 32, ns.Azero.rng) m2.moves = M.DefaultMoves('tidehunter', 32)
      ns.Azero.save.party = { m, m2 }""")
    c.eval("local st = ns.AzeroBounty:State() st.list = { { id = 'trainer', n = 1, got = 0, money = 260, item = 'potion', count = 2 } }")
    c.eval("T_AZ.log = {} ns.Azero:EnterMap('route1', 15, 19, 'right', true) ns.Azero:PressA()")
    c.eval("T_AZ.settle()")                                   # Yes (T_AZ.choice = 1), then the bot fights
    assert "Druid Initiate Ellisara would like to battle!" in log(c) and "Foe Goretusk" in log(c), log(c)
    r = c.eval_py("""local st = ns.AzeroBounty:State()
      return { day = ns.Azero.save.rematch and ns.Azero.save.rematch.druid1, key = ns.AzeroBounty.DayKey(),
               bounty = st.list[1].done == true, ach = ns.AzeroAch.Earned().rematch1 ~= nil }""")
    assert r["day"] == r["key"] and r["bounty"] and r["ach"], r
    c.eval("T_AZ.log = {} ns.Azero:PressA()")
    c.eval("T_AZ.settle()")
    assert "That's enough for today." in log(c) and "would like to battle" not in log(c), log(c)
    c.eval("ns.AzeroBounty.clock = %d" % (NOW + 86400))          # the next day
    assert c.eval("return ns.Azero:RematchReady('druid1')") is True
    no_errors(w)


@case
def bosses_who_left_and_the_rival_never_rematch():
    w, c = game()
    assert c.eval("return ns.Azero:RematchReady('rhahkzor')") is False
    assert c.eval("return ns.Azero:RematchReady('vancleef')") is False
    assert c.eval("return ns.Azero:RematchReady('rival1')") is False
    assert c.eval("return ns.Azero:RematchReady('hogger')") is True        # gym leaders do
    no_errors(w)


if __name__ == "__main__":
    run_all()
