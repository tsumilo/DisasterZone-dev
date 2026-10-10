"""Azeromon: the Gurubashi Arena.

Covers: Thor flies you there from Sentinel Hill (for a fee) and Gyll flies you back; challengers grow with the
streak (two beasts, three from the 4th fight; evolved where their level allows); a run: the fee, a prize per win,
an item every 5 wins, fight on or leave, the best streak kept and the Gladiator achievement; a lost fight only ends
the run (no blackout, beasts healed); the streak on the guild's Arena board.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_arena.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

DRIVER = r"""
-- plays the arena: Yes to entering, "Next fight" until `stopAt` wins, the bot fights
function T_AR(stopAt)
  local G = ns.Azero
  T_AR_LOG = {}
  for _ = 1, 20000 do
    local p = G.pending
    if not p then
      if G.co or G.moving then G:Update(0.05) else return end
    elseif p.kind == "text" then T_AR_LOG[#T_AR_LOG + 1] = p.text G:Advance()
    elseif p.kind == "choice" then
      if p.text:find("in a row") then
        G:Advance((ns.Azero:Data().arenaBest or 0) >= stopAt and 2 or 1)
      else G:Advance(1) end
    elseif p.kind == "battle" then G:Advance(T_AZ.fight(p.battle))
    else G:Update(0.5) end
  end
  error("the arena run did not end")
end
"""


def game():
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval(DRIVER)
    c.eval("T_AZ.seed(3)")
    c.eval("ns.Azero:NewGame()")
    c.eval("""local M = ns.AzeroMon
      local m = M.New('tidehunter', 40, ns.Azero.rng) m.moves = M.DefaultMoves('tidehunter', 40)
      ns.Azero.save.party = { m }
      ns.Azero.save.money = 1000""")
    return w, c


def log(c):
    return "\n".join(c.eval_py("return T_AR_LOG") or [])


@case
def thor_flies_you_there_and_gyll_back():
    w, c = game()
    c.eval("ns.Azero:EnterMap('sentinel', 17, 4, 'right', true) ns.Azero:PressA()")
    c.eval("T_AZ.settle()")                                      # Yes
    assert c.eval("return ns.Azero.save.map") == "arena" and c.eval("return ns.Azero.save.money") == 950
    c.eval("ns.Azero:EnterMap('arena', 11, 11, 'right', true) ns.Azero:PressA()")
    c.eval("T_AZ.settle()")
    assert c.eval("return ns.Azero.save.map") == "sentinel"
    no_errors(w)


@case
def challengers_grow_with_the_streak():
    w, c = game()
    r = c.eval_py("""local A, M = ns.AzeroArena, ns.AzeroMon
      local out = {}
      for n = 1, 8 do
        local name, team = A.Challenger(n, ns.Azero.rng)
        local lv, bad = {}, false
        for i, m in ipairs(team) do lv[i] = m.lvl if M.EvolutionTarget(m) then bad = true end end
        out[n] = { size = #team, top = lv[#lv], bad = bad, named = name ~= nil }
      end
      return out""")
    assert [x["size"] for x in r] == [2, 2, 2, 3, 3, 3, 3, 3], r
    assert r[0]["top"] == 38 and r[7]["top"] == 42 and all(not x["bad"] and x["named"] for x in r), r
    no_errors(w)


@case
def a_run_pays_per_win_keeps_the_best_and_gives_items():
    w, c = game()
    # easy challengers so the run is about the rules, not the fights
    c.eval("""local A, M = ns.AzeroArena, ns.AzeroMon
      A.Challenger = function(n) return 'Test Brute ' .. n, { M.New('owlet', 3, ns.Azero.rng) } end""")
    c.eval("ns.Azero:EnterMap('arena', 7, 4, 'up', true)")
    c.eval("ns.Azero:Run(function(g) ns.AzeroArena:Run(g) end)")
    c.eval("T_AR(5)")
    r = c.eval_py("""local G = ns.Azero
      return { best = G:Data().arenaBest, money = G.save.money, potion = G.save.bag.superpotion or 0,
               hp = G.save.party[1].hp == ns.AzeroMon.MaxHP(G.save.party[1]), ach = ns.AzeroAch.Earned().arena5 ~= nil,
               map = G.save.map }""")
    assert r["best"] == 5 and r["potion"] >= 1 and r["hp"] and r["ach"] and r["map"] == "arena", r
    assert r["money"] > 1000 - 100, r                           # the fee, then five prizes
    text = log(c)
    assert "Fight 1! Test Brute 1 steps into the arena!" in text and "A streak of 5!" in text, text
    # the guild board shows it
    rank = c.eval_py("local r = ns.AzeroGuild:Ranking('arena') return { v = r[1].value, t = r[1].text }")
    assert rank == {"v": 5, "t": "5 in a row"}, rank
    no_errors(w)


@case
def losing_only_ends_the_run():
    w, c = game()
    c.eval("""local A, M = ns.AzeroArena, ns.AzeroMon
      A.Challenger = function(n) local m = M.New('bigbadwolf', 100, ns.Azero.rng) return 'The Unbeatable', { m } end""")
    c.eval("ns.Azero:EnterMap('arena', 7, 4, 'up', true)")
    c.eval("ns.Azero:Run(function(g) ns.AzeroArena:Run(g) end)")
    c.eval("T_AR(5)")
    r = c.eval_py("""local G = ns.Azero
      return { map = G.save.map, money = G.save.money, hp = G.save.party[1].hp > 0, best = G:Data().arenaBest or 0 }""")
    assert r == {"map": "arena", "money": 900, "hp": True, "best": 0}, r        # only the fee is gone
    assert "Down in the first round!" in log(c), log(c)
    no_errors(w)


if __name__ == "__main__":
    run_all()
