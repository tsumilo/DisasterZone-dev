"""Azeromon edge cases in the game core (Game.lua, Battle.lua, Mon.lua, the maps), found by the 2026-10-10 review.

Covers: a /reload in the middle of a script keeps none of it (the starter's gift, a trainer's prize before the
trainer counts as beaten, a gate's text before the push back, a battle's damage); an old or broken save is still
offered and repaired (unknown map, bad position, empty party, every beast dropped); a trainer won't fight a party
that can't; escape odds never wrap around past 255; burn / poison still hurt when the other beast fainted; a player
battle's switch index sent as text; a stopped evolution at level 100 and a stopped trade evolution come back;
vanished captains stay gone; a boss shows as soon as his hunters are beaten; the arena's roads stay shut until the
Night Watch; a map edge never lands in a tree; beasts from another player are checked.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_fix_core.py [-k name]
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
    return w, c


def reload(w, c):
    """A real /reload (SavedVariables written and read back), then CONTINUE."""
    c.relog()
    w.tick(2)
    c.eval(BOT)
    c.eval("T_AZ.seed(7)")
    assert c.eval("return ns.Azero:HasSave()") is True
    c.eval("ns.Azero:Load()")


def advance_until(c, needle):
    """Answers the running script's prompts (choices with T_AZ.choice) until a text containing `needle` shows."""
    return c.eval_py(r"""
      local G, needle = ns.Azero, ...
      for _ = 1, 400 do
        local p = G.pending
        if p and p.kind == "text" and p.text:find(needle, 1, true) then return p.text end
        if not p then
          if not (G.co or G.moving) then return nil end
          G:Update(0.05)
        elseif p.kind == "text" then G:Advance()
        elseif p.kind == "choice" then G:Advance(T_AZ.choice)
        elseif p.kind == "battle" then G:Advance(T_AZ.fight(p.battle))
        else G:Update(0.05) end
      end
    """, needle)


# -- a /reload mid-script ------------------------------------------------------------------------------------------

@case
def a_reload_on_the_starter_gift_gives_nothing_and_you_pick_again():
    w, c = game()
    c.eval(r"""
      local G = ns.Azero
      G:NewGame()
      G:EnterMap("lab", 4, 5, "up", true)
      T_AZ.choice = 1
      G:PressA()
    """)
    assert "received" in (advance_until(c, "received") or "")
    assert c.eval("return #ns.Azero.save.party") == 1          # given (in this session)...
    reload(w, c)
    r = c.eval_py("local s = ns.Azero.save return { party = #s.party, starter = s.flags.starter, map = s.map, x = s.x, y = s.y }")
    assert r == {"party": 0, "map": "lab", "x": 4, "y": 5}, r     # ...and gone with the reload, flag and all
    c.eval("ns.Azero.save.face = 'up' T_AZ.choice = 1 ns.Azero:PressA() T_AZ.settle()")
    r = c.eval_py("local s = ns.Azero.save return { party = #s.party, starter = s.flags.starter, done = s.flags.rivalDone, nets = s.bag.net }")
    assert r["party"] == 1 and r["starter"] and r["done"] is True and r["nets"] == 5, r
    no_errors(w)


@case
def a_reload_after_a_trainer_win_keeps_neither_the_prize_nor_the_win():
    w, c = game()
    c.eval(r"""
      local G, M = ns.Azero, ns.AzeroMon
      G:NewGame()
      G.save.flags.starter, G.save.flags.rivalDone = "murkling", true
      G.save.party[1] = M.New("murkling", 40, G.rng)
      G.save.money = 1000
      G:EnterMap("route1", 13, 3, "up", true)
      G:PressA()                                       -- Deputy Rainer
    """)
    # the battle is won and the prize paid; the evolution that follows holds the script before the trainer's flag
    assert "is evolving" in (advance_until(c, "is evolving") or "")
    assert c.eval("return ns.Azero.save.money") > 1000
    assert not c.eval("return ns.Azero.save.flags.beat_captain")
    reload(w, c)
    r = c.eval_py("local s = ns.Azero.save return { money = s.money, beat = s.flags.beat_captain or false }")
    assert r == {"money": 1000, "beat": False}, r
    no_errors(w)


@case
def a_reload_on_a_gate_message_puts_you_back_before_the_gate():
    w, c = game()
    c.eval(r"""
      local G, M = ns.Azero, ns.AzeroMon
      G:NewGame()
      G.save.flags.starter, G.save.flags.rivalDone = "murkling", true
      G.save.party[1] = M.New("murkling", 10, G.rng)
      G.save.flags.beat_captain = true
      G:EnterMap("route1", 10, 2, "up", true)
      G:TryStep("up")
    """)
    assert advance_until(c, "Hold on!") is not None
    assert c.eval_py("return { ns.Azero.save.x, ns.Azero.save.y }") == [10, 1]    # on the gate's tile
    reload(w, c)
    assert c.eval_py("local s = ns.Azero.save return { s.map, s.x, s.y }") == ["route1", 10, 2]
    no_errors(w)


@case
def a_reload_mid_battle_gives_back_the_party_as_it_was():
    w, c = game()
    c.eval(r"""
      local G, M = ns.Azero, ns.AzeroMon
      G:NewGame()
      G.save.flags.starter = "murkling"
      G.save.party[1] = M.New("murkling", 10, G.rng)
      G:Run(function(g) g:WildBattle("wolfpup", 3) end)
      G.save.party[1].hp = 0                           -- as if it fainted in the fight
    """)
    assert c.eval("return ns.Azero.pending.kind") == "battle"
    reload(w, c)
    r = c.eval_py("local M = ns.AzeroMon local m = ns.Azero.save.party[1] return { m.hp, M.MaxHP(m) }")
    assert r[0] == r[1] and r[0] > 0, r
    assert c.eval("return ns.Azero:Data().undo") is None
    no_errors(w)


@case
def a_finished_script_leaves_nothing_to_undo():
    w, c = game()
    c.eval(r"""
      local G = ns.Azero
      G:NewGame()
      G:Run(function(g) g:SetFlag("chest_test") g:Say("Found it.") end)
    """)
    assert c.eval("return ns.Azero:Data().undo ~= nil") is True
    c.eval("T_AZ.settle()")
    assert c.eval("return ns.Azero:Data().undo") is None
    reload(w, c)
    assert c.eval("return ns.Azero.save.flags.chest_test") is True
    no_errors(w)


# -- old and broken saves ------------------------------------------------------------------------------------------

@case
def an_old_save_is_still_offered_and_new_game_asks_first():
    w, c = game()
    c.eval(r"""
      ns.Azero:Data().save = { v = 0, map = "gone_in_an_update", x = 2, y = 2, party = {}, flags = {} }
    """)
    assert c.eval("return ns.Azero:HasSave()") is True
    c.eval("ns.Azero:Load()")
    r = c.eval_py("local s = ns.Azero.save return { s.map, s.v }")
    assert r == ["home", c.eval("return ns.AzeroData.SAVE_VERSION")], r
    no_errors(w)


@case
def a_broken_position_lands_on_open_ground():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      local out = {}
      for _, case in ipairs({ { map = "START", x = 1, y = 1 }, { map = "town", x = "a", y = nil, face = "sideways" },
                              { map = "town", x = 2.5, y = 900 }, { map = "town", x = 0, y = 0 } }) do
        G:Data().save = { v = 1, map = case.map, x = case.x, y = case.y, face = case.face, party = {}, flags = {} }
        G:Load()
        local s, m = G.save, G.map
        out[#out + 1] = { map = s.map, solid = m.solid[m.key(s.x, s.y)] == true, int = s.x == math.floor(s.x)
          and s.y == math.floor(s.y), inside = s.x >= 0 and s.y >= 0 and s.x < m.w and s.y < m.h, face = s.face }
      end
      return out
    """)
    assert r[0]["map"] == "home", r
    for e in r:
        assert e["solid"] is False and e["int"] and e["inside"] and e["face"] in ("up", "down", "left", "right"), r
    no_errors(w)


@case
def a_save_without_beasts_gets_one_back():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      G:Data().save = { v = 1, map = "town", x = 5, y = 8, party = {}, box = { { sp = "wolfpup", lvl = 4 } },
                        flags = { starter = "murkling" } }
      G:Load()
      local fromBox = G.save.party[1] and G.save.party[1].sp
      G:Data().save = { v = 1, map = "town", x = 5, y = 8, party = { { sp = "missingno", lvl = 9 } },
                        flags = { starter = "murkling" } }
      G:Load()
      local again = G.save.party[1] and G.save.party[1].sp
      G:Data().save = { v = 1, map = "town", x = 5, y = 8, party = {}, flags = { starter = "missingno" } }
      G:Load()
      return { fromBox = fromBox, again = again, flag = G.save.flags.starter or false }
    """)
    assert r == {"fromBox": "wolfpup", "again": "murkling", "flag": False}, r
    no_errors(w)


@case
def a_trainer_wont_fight_a_party_that_cannot():
    w, c = game()
    r = c.eval_py(r"""
      local G, M = ns.Azero, ns.AzeroMon
      G:NewGame()
      G.save.flags.starter, G.save.flags.rivalDone = "murkling", true
      G.save.party[1] = M.New("murkling", 10, G.rng)
      G.save.party[1].hp = 0
      G:EnterMap("route1", 13, 3, "up", true)
      G:PressA()
      local said = G.pending and G.pending.kind == "text" and G.pending.text
      T_AZ.settle()
      local result
      G.save.party = {}
      G:Run(function(g) result = g:Battle("captain") end)
      T_AZ.settle()
      return { said = said or "", battles = T_AZ.battles or 0, result = result }
    """)
    assert "can't fight" in r["said"] and r["battles"] == 0 and r["result"] == "none", r
    no_errors(w)


# -- battle rules --------------------------------------------------------------------------------------------------

@case
def running_away_gets_surer_with_every_try():
    w, c = game()
    r = c.eval_py(r"""
      local B, M = ns.AzeroBattle, ns.AzeroMon
      local party = { M.New("murkling", 60) }
      local b = B.New({ party = party, foes = { M.New("wolfpup", 2) }, wild = true,
                        rng = function(a, b) return b end })        -- the worst roll every time
      b.EffStat = function(self, side, stat) if stat == "spe" then return side == "ally" and 90 or 100 end return 50 end
      for _ = 1, 6 do
        if b.need ~= "action" then break end
        b:Act({ kind = "run" })
      end
      return { result = b.result, runs = b.runs }
    """)
    # 128 * 90 / 100 + 30 * tries: 145, 175, 205, 235, 265 -> past 255 on the 5th it always works
    assert r == {"result": "run", "runs": 5}, r
    no_errors(w)


@case
def poison_still_hurts_the_foe_when_your_beast_faints():
    w, c = game()
    r = c.eval_py(r"""
      local B, M = ns.AzeroBattle, ns.AzeroMon
      local party = { M.New("wolfpup", 2), M.New("murkling", 20) }
      local foe = M.New("murkling", 50)
      for id, mv in pairs(ns.AzeroData.moves) do                    -- one plain hit, so the foe surely attacks
        if mv.power >= 40 and mv.acc == 100 and not mv.effect and not mv.prio then foe.moves = { { id = id, pp = 10 } } break end
      end
      local b = B.New({ party = party, foes = { foe }, wild = true, rng = function(a, b) return a end })
      party[1].hp = 1
      foe.status = "psn"
      local before = foe.hp
      b:Act({ kind = "move", idx = 1 })
      return { need = b.need, lost = before - foe.hp, eighth = math.floor(M.MaxHP(foe) / 8), ally = party[1].hp }
    """)
    assert r["ally"] == 0 and r["need"] == "switch", r
    assert r["lost"] >= r["eighth"] > 0, r
    no_errors(w)


@case
def a_player_battle_switch_sent_as_text_is_a_number():
    w, c = game()
    r = c.eval_py(r"""
      local B, M = ns.AzeroBattle, ns.AzeroMon
      local b = B.New({ party = { M.New("murkling", 10), M.New("emberwhelp", 10) },
                        foes = { M.New("wolfpup", 10), M.New("emberwhelp", 10) }, rng = function(a) return a end,
                        pvp = { host = true, name = "Bob" } })
      local two = b:ValidPvP("foe", { kind = "switch", idx = "2" })
      local active = b:ValidPvP("foe", { kind = "switch", idx = "1" })
      local half = b:ValidPvP("foe", { kind = "switch", idx = 1.5 })
      b.mine = b:ValidPvP("ally", { kind = "move", idx = 1 })
      b.theirs = two
      local ok = pcall(b.ResolvePvP, b)
      return { two = { two.kind, two.idx }, active = active.kind, half = half.kind, ok = ok, foeIdx = b.foeIdx }
    """)
    assert r == {"two": ["switch", 2], "active": "move", "half": "move", "ok": True, "foeIdx": 2}, r
    no_errors(w)


@case
def a_stopped_evolution_at_level_100_asks_again_after_the_next_battle():
    w, c = game()
    r = c.eval_py(r"""
      local G, M = ns.Azero, ns.AzeroMon
      G:NewGame()
      local mon = M.New("emberwhelp", 100, G.rng)
      G.save.party[1] = mon
      G:Run(function(g) g:Evolutions() end)
      local first = G.pending and G.pending.kind
      while G.pending and G.pending.kind ~= "evolve" do G:Advance() end
      G:Advance("cancel")
      T_AZ.settle()
      local stopped = mon.sp
      G:Run(function(g) g:Evolutions() end)
      while G.pending and G.pending.kind ~= "evolve" do G:Advance() end
      local asked = G.pending and G.pending.kind
      T_AZ.settle()
      return { stopped = stopped, asked = asked or false, now = mon.sp }
    """)
    assert r == {"stopped": "emberwhelp", "asked": "evolve", "now": "emberancient"}, r
    no_errors(w)


@case
def a_stopped_trade_evolution_comes_back():
    w, c = game()
    r = c.eval_py(r"""
      local G, M = ns.Azero, ns.AzeroMon
      G:NewGame()
      local mon = M.New("tunneler", 20, G.rng)
      G.save.party[1] = mon
      G:Run(function(g) g:EvolveNow(mon, "geomancer") end)
      while G.pending and G.pending.kind ~= "evolve" do G:Advance() end
      G:Advance("cancel")
      T_AZ.settle()
      local kept = mon.tradeEvo
      M.Sanitize(mon)                                  -- (survives a save round trip)
      mon.lvl = 21
      G:Run(function(g) g:Evolutions() end)
      T_AZ.settle()
      return { kept = kept or false, now = mon.sp, left = mon.tradeEvo or false }
    """)
    assert r == {"kept": "geomancer", "now": "geomancer", "left": False}, r
    no_errors(w)


@case
def beasts_from_another_player_are_checked():
    w, c = game()
    r = c.eval_py(r"""
      local M = ns.AzeroMon
      local boss = M.Sanitize({ sp = "hogger", lvl = 10, moves = {} }, true)
      local mon = M.Sanitize({ sp = "murkling", lvl = 5, moves = { { id = "sawstorm", pp = 5 }, { id = "tackle", pp = 5 },
                                                                    { id = "tackle", pp = 5 } } }, true)
      local own = M.Sanitize({ sp = "murkling", lvl = 5, status = "slp", sleep = "lots", moves = {} })
      local ids = {}
      for _, m in ipairs(mon.moves) do ids[#ids + 1] = m.id end
      return { boss = boss == nil, ids = ids, sleep = own.sleep }
    """)
    assert r["boss"] is True and "sawstorm" not in r["ids"], r
    assert len(r["ids"]) == len(set(r["ids"])) and r["sleep"] in (1, 2, 3), r
    no_errors(w)


# -- the world -----------------------------------------------------------------------------------------------------

@case
def captains_who_rowed_away_stay_gone():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      G:NewGame()
      G.save.flags.beat_stillwater, G.save.flags.beat_keelhaul = true, true
      G:EnterMap("wildshore", 2, 2, "down", true)
      local out = {}
      for _, n in ipairs(G.npcs) do if n.id == "stillwater" or n.id == "keelhaul" then out[n.id] = n.hidden end end
      return out
    """)
    assert r == {"stillwater": True, "keelhaul": True}, r
    no_errors(w)


@case
def the_king_comes_out_as_soon_as_his_hunters_are_beaten():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      G:NewGame()
      G.save.flags.beat_ajeck, G.save.flags.beat_erlgadin = true, true
      G:EnterMap("stvnorth", 5, 5, "down", true)
      local function king() for _, n in ipairs(G.npcs) do if n.id == "bangalash" then return n.hidden end end end
      local before = king()
      G:Run(function(g) g:SetFlag("beat_barnil") g:Say("Barnil: Well hunted.") end)
      T_AZ.settle()
      return { before = before, after = king() }
    """)
    assert r == {"before": True, "after": False}, r
    no_errors(w)


@case
def the_arena_roads_stay_shut_until_the_night_watch():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      G:NewGame()
      G:EnterMap("arena", 7, 0, "up", true)
      local shut = T_AZ.step("up")
      local said = G.pending and G.pending.text or ""
      T_AZ.settle()
      local where = G.save.map
      G.save.flags.badge_nightwatch = true
      local open = T_AZ.step("up")
      return { shut = shut, said = said, where = where, open = open, now = G.save.map }
    """)
    assert r["shut"] == "blocked" and "closed" in r["said"] and r["where"] == "arena", r
    assert r["open"] == "edge" and r["now"] == "zulmamwe", r
    no_errors(w)


@case
def a_map_edge_never_lands_in_a_tree():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      G:NewGame()
      local bad = {}
      for id, def in pairs(ns.AzeroMaps) do
        local m = G.Compile(id)
        if m and def.edges then
          for side, edge in pairs(def.edges) do
            local dir = ({ north = "up", south = "down", west = "left", east = "right" })[side]
            local span = (dir == "up" or dir == "down") and m.w or m.h
            for i = 0, span - 1 do
              local x, y
              if dir == "up" then x, y = i, 0 elseif dir == "down" then x, y = i, m.h - 1
              elseif dir == "left" then x, y = 0, i else x, y = m.w - 1, i end
              if not m.solid[m.key(x, y)] then
                G.save.flags.badge_nightwatch = true
                G:EnterMap(id, x, y, dir, true)
                if G:TryStep(dir) == "edge" then
                  local t, s = G.map, G.save
                  if t.solid[t.key(s.x, s.y)] then bad[#bad + 1] = id .. " " .. side .. " " .. i .. " -> " .. t.id end
                end
              end
            end
          end
        end
      end
      return bad
    """)
    assert r in ([], None, {}), r
    no_errors(w)


if __name__ == "__main__":
    run_all(globals())
