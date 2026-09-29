"""Azeromon: shinies.

Covers: the shiny roll (odds, its own random numbers so encounters don't shift, Illusion Dust hook); a shiny wild
beast fires the "shiny" event and its achievement, taming it records it (Bestiary "shiny", the lifetime stat, the
"Shiny!" achievement) and keeps the shine through evolution and the save; the skin table (real other skins of the
same species, never another species' skin); the battle shows the other skin (or the gold glow), the star and the
sparkle; the guild hears about it (chat news, the "Shinies tamed" board); a player battle carries the shine.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_shiny.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def game(seed=7, ui=False, c_w=None):
    w, c = c_w or solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    c.eval("""local M = ns.AzeroMon
      local m = M.New('murkling', 30, ns.Azero.rng); m.moves = M.DefaultMoves('murkling', 30)
      ns.Azero.save.party = { m }""")
    if ui:
        c.slash("/cdl play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.3)
        c.eval("T_AZ.settle()")
    return w, c


def earned(c):
    return sorted(c.eval_py("local t = {} for id in pairs(ns.AzeroAch.Earned()) do t[#t + 1] = id end return t") or [])


@case
def the_skin_table_is_sound():
    w, c = game()
    bad = c.eval_py("""local D = ns.AzeroData
      local bad, base = {}, {}
      for id, sp in pairs(D.species) do base[sp.display] = id end
      for id, disp in pairs(D.shinyDisplay) do
        local sp = D.species[id]
        if not sp then bad[#bad + 1] = "unknown species " .. id
        elseif sp.boss then bad[#bad + 1] = "boss " .. id
        elseif disp == sp.display then bad[#bad + 1] = "same skin " .. id
        elseif base[disp] then bad[#bad + 1] = id .. " wears " .. base[disp] .. "'s skin" end
      end
      return bad""")
    assert bad == [], bad
    no_errors(w)


@case
def the_roll_uses_its_own_numbers_and_the_odds():
    w, c = game()
    r = c.eval_py("""local G = ns.Azero
      local calls = 0
      local real = G.rng
      G.rng = function(a, b) calls = calls + 1 return real(a, b) end
      local seen = {}
      G.shinyRng = function(a, b) seen[#seen + 1] = b return b end      -- never 1: not shiny
      local no = G:RollShiny()
      G.shinyRng = function(a, b) return 1 end
      local yes = G:RollShiny()
      G.ShinyBoosted = function() return true end
      G.shinyRng = function(a, b) seen[#seen + 1] = b return 1 end
      G:RollShiny()
      G.ShinyBoosted = nil
      G.rng = real
      return { no = no, yes = yes, odds = seen, calls = calls }""")
    assert r == {"no": False, "yes": True, "odds": [400, 200], "calls": 0}, r
    no_errors(w)


@case
def a_shiny_is_announced_tamed_and_keeps_its_shine():
    w, c = game()
    r = c.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      G.shinyOdds = 1
      local seen = {}
      G:On('shiny', function(_, e) seen[#seen + 1] = e.mon.sp end)
      local foe
      G:Run(function(g)
        g:WildBattle('kobling', 15)
      end)
      local b = G.pending and G.pending.battle
      foe = b.foe.mon
      local shiny = foe.shiny
      -- tame it
      local tamed = foe
      G:Advance('caught')
      G:AddMon(tamed, 'caught')
      T_AZ.settle()
      G.shinyOdds = nil
      -- evolve it
      tamed.lvl = 16
      G.save.party = { tamed }
      G:Run(function(g)
        local w = M.New('wolfpup', 2, g.rng); w.hp = 1
        g.shinyOdds = 1e9
        g:RunBattle({ w }, nil)
      end)
      T_AZ.settle()
      return { shiny = shiny, seen = seen, sp = tamed.sp, still = tamed.shiny, caught = G.save.shinyCaught.kobling,
               stat = ns.AzeroAch.Stat('shinies') }""")
    assert r["shiny"] is True and r["seen"] == ["kobling"], r
    assert r["sp"] == "tunneler" and r["still"] is True and r["caught"] is True and r["stat"] == 1, r
    assert "shinyseen" in earned(c) and "shinytame" in earned(c)
    # the save keeps it (and a bad value is dropped)
    ok = c.eval_py("""local M = ns.AzeroMon
      local a = M.Sanitize({ sp = 'owlet', lvl = 5, shiny = true })
      local b = M.Sanitize({ sp = 'owlet', lvl = 5, shiny = 'yes' })
      return { a = a.shiny, b = b.shiny == nil }""")
    assert ok == {"a": True, "b": True}, ok
    no_errors(w)


@case
def the_battle_shows_the_other_skin_the_star_and_the_sparkle():
    w, c = game(ui=True)
    c.eval("""local G = ns.Azero
      G.shinyOdds = 1
      G:Run(function(g) g:WildBattle('webling', 10) end)""")
    # play the intro in the UI until the foe is out
    got = None
    for _ in range(60):
        w.tick(0.1)
        s = c.eval_py("return ns.AzeroUI._Shiny()")
        if s and s["sparkle"]:
            got = s
            break
    assert got, c.eval_py("return ns.AzeroUI._Shiny()")
    assert got["display"] == 4457 and got["glow"] is False and got["star"] is True, got
    no_errors(w)


@case
def a_species_without_a_skin_glows_instead():
    w, c = game(ui=True)
    r = c.eval_py("""local UI = ns.AzeroUI
      UI._ShowFoe('shredder')
      local plain = UI._Shiny()
      return { plain = plain.glow, hasSkin = ns.AzeroData.shinyDisplay.shredder ~= nil }""")
    assert r == {"plain": False, "hasSkin": False}, r
    r = c.eval_py("""local sc = ns.AzeroUI._Scene('foe')
      ns.AzeroUI._ShowFoeShiny('shredder')
      return { glow = sc.glow, display = sc.display }""")
    assert r["glow"] is True and r["display"] == 1269, r
    no_errors(w)


@case
def the_guild_hears_about_a_shiny_and_ranks_shinies():
    w = World()
    cs = {n: Client(w, n, guild_rank=3) for n in ("Alice", "Bob")}
    for c in cs.values():
        c.load_addon()
    w.tick(3)
    a, b = cs["Alice"], cs["Bob"]
    for c in (a, b):
        c.eval(BOT)
        c.eval("T_AZ.seed(3)")
        c.eval("ns.Azero:NewGame()")
    a.eval("""local G = ns.Azero
      local mon = ns.AzeroMon.New('owlet', 5, G.rng)
      mon.shiny = true
      G:Emit('shiny', { mon = mon })
      G:AddMon(mon, 'caught')""")
    w.tick(2)
    news = b.eval("return ns.AzeroGuild.lastNews")
    assert news == "Alice tamed a shiny Owlet!", news
    # Alice's summary carries the count; Bob's board ranks it
    a.eval("ns.AzeroGuild._Reset() ns.AzeroNet:SetActive(true) ns.AzeroGuild:Update()")
    w.tick(3)
    rank = b.eval_py("local r = ns.AzeroGuild:Ranking('shinies') return { name = r[1].entry.name, sh = r[1].value }")
    assert rank == {"name": "Alice", "sh": 1}, rank
    no_errors(w)


@case
def a_player_battle_carries_the_shine():
    w, c = game()
    r = c.eval_py("""local P, M = ns.AzeroPvP, ns.AzeroMon
      local a = M.New('owlet', 10, ns.Azero.rng); a.shiny = true
      local b = M.New('coyote', 10, ns.Azero.rng)
      local team = P.UnpackTeam(P.PackTeam({ a, b }))
      return { a = team[1].shiny == true, b = team[2].shiny == nil }""")
    assert r == {"a": True, "b": True}, r
    no_errors(w)


if __name__ == "__main__":
    run_all()
