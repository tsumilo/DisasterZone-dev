"""Azeromon 0.37 battles: cooldowns, marks and combos, casts that land a turn later (guarded or interrupted), the
battle HP scale, the rule-list AI and the type kits (Data.lua "0.37 battles", Battle.lua).

The engine is driven directly with a fixed dice roller: every check hits, no crits, top damage rolls.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_combat.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402

from _azero_bot import BOT  # noqa: E402

# a battle between two beasts with chosen moves; `R` = the fixed dice; helpers to read what happened
SETUP = r"""
G, M, B, D = ns.Azero, ns.AzeroMon, ns.AzeroBattle, ns.AzeroData
G:NewGame()
R = function(a, b)
  if a == 85 and b == 100 then return 100 end     -- damage roll: the top
  if b == 16 then return 16 end                   -- never a crit
  if b == 4 then return 4 end                     -- paralysis never stops a turn
  return a                                        -- every hit / chance check succeeds, the first random pick
end
function Mk(sp, lvl, moves)
  local m = M.New(sp, lvl, R)
  m.ivs = { 15, 15, 15, 15, 15, 15 }
  m.hp = M.MaxHP(m)
  m.moves = {}
  for i, id in ipairs(moves) do m.moves[i] = { id = id, pp = D.moves[id].pp } end
  return m
end
function Fight(a, f, opts)
  opts = opts or {}
  local b = B.New({ party = { a }, foes = { f }, wild = opts.wild ~= false, trainer = opts.trainer, rng = R })
  while b:Pop() do end
  return b
end
function Drain(b)
  local out = {}
  while true do local e = b:Pop() if not e then break end out[#out + 1] = e end
  return out
end
function Kinds(evs)
  local out = {}
  for _, e in ipairs(evs) do out[#out + 1] = e.t end
  return table.concat(out, " ")
end
-- the foe always picks slot `i` (a test hook instead of the AI)
function Force(b, i)
  b.FoeAction = function(self)
    local s = self.foe
    if s.cast then return s.cast.mv, s.cast.slot, true end
    local slot = s.mon.moves[i]
    slot.pp = slot.pp - 1
    return D.moves[slot.id], i, false
  end
end
"""


def game():
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval(SETUP)
    return w, c


@case
def a_move_rests_its_cooldown():
    w, c = game()
    r = c.eval_py(r"""
      local b = Fight(Mk("murkling", 5, { "kwaterbolt", "kfrostshock" }), Mk("kobling", 60, { "kstoneskin" }))
      Force(b, 1)                                      -- (the foe only ever guards: nobody faints)
      b:Act({ kind = "move", idx = 2 })                -- Frost Shock: cooldown 3
      Drain(b)
      local resting = { b:Usable("ally", 2), b.ally.cd[2] }
      local refused = b:Act({ kind = "move", idx = 2 })
      for _ = 1, 3 do b:Act({ kind = "move", idx = 1 }) Drain(b) end
      return { resting = resting, refused = refused, ready = b:Usable("ally", 2) }
    """)
    assert r["resting"] == [False, 3] and r["refused"] is False and r["ready"] is True, r
    no_errors(w)


@case
def a_setup_marks_and_its_payoff_hits_harder():
    w, c = game()
    r = c.eval_py(r"""
      local b = Fight(Mk("murkling", 20, { "kfrostshock", "kicelance" }), Mk("kobling", 20, { "krockthrow" }))
      local plain = b:Damage("ally", "foe", D.moves.kicelance, false)
      local spe = b:EffStat("foe", "spe")
      Force(b, 1)
      b:Act({ kind = "move", idx = 1 })
      local evs = Drain(b)
      local chilled = b.foe.marks.chill
      local combo, _, _, paid = b:Damage("ally", "foe", D.moves.kicelance, false)
      return { plain = plain, combo = combo, paid = paid, chilled = chilled, mark = Kinds(evs):find("mark") ~= nil,
               slow = b:EffStat("foe", "spe") / spe }
    """)
    # the chill lasts 2 turns and has counted down once at the end of this turn
    assert r["chilled"] == 1 and r["mark"] and abs(r["slow"] - 0.5) < 1e-9, r
    assert r["paid"] is True and r["combo"] >= r["plain"] * 1.9, r          # x2.3 power (the formula adds a flat +2)
    no_errors(w)


@case
def a_consuming_payoff_uses_its_mark_up_and_bleeds_tick():
    w, c = game()
    r = c.eval_py(r"""
      local f = Mk("kobling", 20, { "krockthrow" })
      local b = Fight(Mk("wolfpup", 20, { "krend", "kferobite", "kclaw" }), f)
      Force(b, 1)
      b:Act({ kind = "move", idx = 1 })                -- Rend: bleed 3
      Drain(b)
      local hp0 = f.hp
      b:Act({ kind = "move", idx = 3 })                -- Claw (the bleed ticks at the end of the turn)
      local evs = Drain(b)
      local tick
      for _, e in ipairs(evs) do if e.t == "hp" and e.side == "foe" then tick = e end end
      local before = b.foe.marks.bleed
      b:Act({ kind = "move", idx = 2 })                -- Ferocious Bite eats the bleed
      Drain(b)
      return { before = before, after = b.foe.marks.bleed, tick = tick and (tick.from - tick.to),
               dot = b:Damage("ally", "foe", { power = D.MARK_DOT_POWER, type = "BEAST", tick = true }, false) }
    """)
    assert r["before"] and r["before"] > 0 and r.get("after") is None, r
    assert r["tick"] == r["dot"] and r["dot"] > 1, r
    no_errors(w)


@case
def a_stronger_casters_marks_hurt_more():
    # a mark's tick is a small hit of the caster's, fixed when it lands: a level gap shows in the damage over time
    w, c = game()
    r = c.eval_py(r"""
      local out = {}
      for _, lvl in ipairs({ 10, 40 }) do
        local f = Mk("kobling", 25, { "kstoneskin" })
        local b = Fight(Mk("wolfpup", lvl, { "krend" }), f)
        Force(b, 1)
        b:Act({ kind = "move", idx = 1 })
        Drain(b)
        out[#out + 1] = b.foe.tick.bleed
      end
      return out
    """)
    assert r[0] >= 1 and r[1] > 2 * r[0], r
    no_errors(w)


@case
def a_cast_lands_next_turn_and_an_interrupt_breaks_it():
    w, c = game()
    r = c.eval_py(r"""
      local out = {}
      local f = Mk("kobling", 20, { "kearthquake", "krockthrow" })
      local b = Fight(Mk("murkling", 20, { "kwaterbolt", "kwindshear" }), f)
      Force(b, 1)
      local hp0 = b.ally.mon.hp
      b:Act({ kind = "move", idx = 1 })                -- the foe begins Earthquake
      local evs = Drain(b)
      out.announced = b.foe.cast ~= nil and Kinds(evs):find("cast") ~= nil
      out.unhurt = b.ally.mon.hp == hp0
      b:Act({ kind = "move", idx = 2 })                -- Wind Shear goes first and breaks it
      evs = Drain(b)
      out.interrupted = Kinds(evs):find("interrupt") ~= nil and b.foe.cast == nil
      out.stillUnhurt = b.ally.mon.hp == hp0
      out.lockout = b.foe.cd[1]
      return out
    """)
    assert r["announced"] and r["unhurt"] and r["interrupted"] and r["stillUnhurt"], r
    assert r["lockout"] == 3, r                      # its cooldown (3), counted down once at the end of the turn
    no_errors(w)


@case
def an_unstoppable_cast_ignores_interrupts_and_a_guard_soaks_it():
    w, c = game()
    r = c.eval_py(r"""
      local out = {}
      -- Hogger's smash can't be interrupted
      local b = Fight(Mk("murkling", 20, { "kwaterbolt", "kwindshear", "kshellshield" }), Mk("hogger", 20, D.species.hogger.kit),
                      { wild = false, trainer = { name = "Hogger", class = "boss" } })
      Force(b, 4)
      b:Act({ kind = "move", idx = 1 })
      Drain(b)
      b:Act({ kind = "move", idx = 2 })                -- Wind Shear: "can't be interrupted"
      local evs = Drain(b)
      out.unstoppable = Kinds(evs):find("unstoppable") ~= nil
      local hit
      for _, e in ipairs(evs) do if e.t == "hp" and e.side == "ally" and e.to < e.from then hit = e.from - e.to end end
      out.hit = hit
      -- the same smash on a guarded beast
      local b2 = Fight(Mk("murkling", 20, { "kwaterbolt", "kwindshear", "kshellshield" }), Mk("hogger", 20, D.species.hogger.kit),
                       { wild = false, trainer = { name = "Hogger", class = "boss" } })
      Force(b2, 4)
      b2:Act({ kind = "move", idx = 1 })
      Drain(b2)
      b2:Act({ kind = "move", idx = 3 })               -- Shell Shield goes first
      evs = Drain(b2)
      local soaked
      for _, e in ipairs(evs) do if e.t == "hp" and e.side == "ally" and e.to < e.from then soaked = e.from - e.to end end
      out.soaked = soaked
      out.guardLeft = b2.ally.guardT
      return out
    """)
    assert r["unstoppable"] and r["hit"], r
    assert r["soaked"] <= r["hit"] * 0.3, r          # 25 % through (rounding)
    assert r["guardLeft"] == 1, r                    # two turns of guard, one counted down
    no_errors(w)


@case
def sleep_breaks_a_cast():
    w, c = game()
    r = c.eval_py(r"""
      local b = Fight(Mk("murkling", 20, { "kwaterbolt" }), Mk("kobling", 20, { "kearthquake" }))
      Force(b, 1)
      b:Act({ kind = "move", idx = 1 })
      Drain(b)
      b.foe.mon.status, b.foe.mon.sleep = "slp", 3
      b:Act({ kind = "move", idx = 1 })
      local evs = Drain(b)
      local broke = false
      for _, e in ipairs(evs) do if e.t == "castend" and e.interrupted then broke = true end end
      return { broke = broke, cast = b.foe.cast ~= nil }
    """)
    assert r == {"broke": True, "cast": False}, r
    no_errors(w)


@case
def the_ai_answers_casts_and_cashes_in_marks():
    w, c = game()
    r = c.eval_py(r"""
      local out = {}
      local trainer = { name = "Vera", class = "rival" }
      -- the player is casting a big move: the foe interrupts
      local b = Fight(Mk("emberwhelp", 25, { "kpyroblast" }), Mk("murkling", 25, { "kwaterbolt", "kfrostshock", "kicelance", "kwindshear" }),
                      { wild = false, trainer = trainer })
      b.ally.cast = { slot = 1, mv = D.moves.kpyroblast }
      out.interrupt = D.moves[b.foe.mon.moves[b:Rotation("foe", { 1, 2, 3, 4 })].id].role
      -- an unstoppable cast: it guards
      local b2 = Fight(Mk("hogger", 25, D.species.hogger.kit), Mk("murkling", 25, { "kwaterbolt", "kfrostshock", "kicelance", "kshellshield" }),
                       { wild = false, trainer = trainer })
      b2.ally.cast = { slot = 4, mv = D.moves.bcast_hogger }
      out.guard = D.moves[b2.foe.mon.moves[b2:Rotation("foe", { 1, 2, 3, 4 })].id].role
      -- the target is chilled: Ice Lance; it is not: Frost Shock first
      local b3 = Fight(Mk("kobling", 25, { "krockthrow" }), Mk("murkling", 25, { "kwaterbolt", "kfrostshock", "kicelance" }),
                       { wild = false, trainer = trainer })
      out.setup = D.moves[b3.foe.mon.moves[b3:Rotation("foe", { 1, 2, 3 })].id].role
      b3.ally.marks.chill = 2
      out.payoff = D.moves[b3.foe.mon.moves[b3:Rotation("foe", { 1, 3 })].id].role
      return out
    """)
    assert r == {"interrupt": "interrupt", "guard": "guard", "setup": "setup", "payoff": "payoff"}, r
    no_errors(w)


@case
def hits_are_scaled_by_battle_hp_and_bosses_have_their_own():
    w, c = game()
    r = c.eval_py(r"""
      local b = Fight(Mk("murkling", 30, { "kwaterbolt" }), Mk("kobling", 30, { "krockthrow" }))
      local scaled = b:Damage("ally", "foe", D.moves.kwaterbolt, false)
      D.BATTLE_HP = 1
      local raw = b:Damage("ally", "foe", D.moves.kwaterbolt, false)
      D.BATTLE_HP = 1.6
      local function Boss(id) return { name = D.trainers[id].name, class = "boss", id = id } end
      local v = Fight(Mk("tidehunter", 40, { "kwaterbolt" }), Mk("stitches", 33, D.species.stitches.kit),
                      { wild = false, trainer = Boss("stitches") })
      local g = Fight(Mk("tidehunter", 55, { "kwaterbolt" }), Mk("blackwyrmkin", 55, { "kclaw" }),
                      { wild = false, trainer = Boss("gath") })
      local own = Fight(Mk("vancleef", 25, D.species.vancleef.kit), Mk("kobling", 30, { "krockthrow" }),
                        { wild = false, trainer = Boss("gath") })
      local wild = Fight(Mk("tidehunter", 30, { "kwaterbolt" }), Mk("stitches", 25, D.species.stitches.kit))
      return { scaled = scaled, raw = raw, boss = v:HpScale("foe"), plain = v:HpScale("ally"), team = g:HpScale("foe"),
               own = own:HpScale("ally"), wild = wild:HpScale("foe") }
    """)
    assert abs(r["scaled"] - r["raw"] / 1.6) <= 1, r
    assert r["boss"] == 0.5 and abs(r["plain"] - 1.6) < 1e-9, r             # D.BOSS_HP: the boss beast's own number
    assert r["team"] == 1.0, r                                              # D.TEAM_HP: Gath'Ilzogg's whole team
    assert r["own"] == 1.6 and r["wild"] == 1.6, r                          # never the player's beasts, nor a wild one
    no_errors(w)


@case
def earth_reaches_fliers_with_thrown_rocks():
    w, c = game()
    r = c.eval_py(r"""
      local b = Fight(Mk("kobling", 20, { "krockthrow", "kwarstomp" }), Mk("owlet", 20, { "kdive" }))
      local rock, eff = b:Damage("ally", "foe", D.moves.krockthrow, false)
      local stomp, eff2 = b:Damage("ally", "foe", D.moves.kwarstomp, false)
      return { rock = rock, eff = eff, stomp = stomp, eff2 = eff2 }
    """)
    assert r["rock"] > 0 and r["eff"] == 0.5 and r["stomp"] == 0 and r["eff2"] == 0, r
    no_errors(w)


@case
def every_beast_learns_its_type_kit_and_bosses_bring_five():
    w, c = game()
    bad = c.eval_py(r"""
      local out = {}
      for id, s in pairs(D.species) do
        if s.kit then
          if #s.kit ~= 5 then out[#out + 1] = id .. " kit" end
          local cast, second = D.moves[s.kit[4]], D.moves[s.kit[5]]
          if not (cast.cast and cast.unstoppable) then out[#out + 1] = id .. " cast" end
          if not (second.cast and not second.unstoppable and (second.heal or second.role == "buff")) then out[#out + 1] = id .. " second" end
          if #M.DefaultMoves(id, 30) ~= 5 then out[#out + 1] = id .. " moves" end
        else
          local kit = D.TYPE_KIT[s.type]
          if not kit then out[#out + 1] = id .. " no kit" else
            for _, mv in ipairs(kit) do
              local found = false
              for _, e in ipairs(s.learn) do if e[2] == mv and e[1] <= 25 then found = true end end
              if not found then out[#out + 1] = id .. " misses " .. mv end
            end
            local m = M.DefaultMoves(id, 30)
            local roles = {}
            for i, x in ipairs(m) do roles[i] = D.moves[x.id].role end
            if #m ~= 4 or roles[1] ~= "filler" or roles[2] ~= "setup" or roles[3] ~= "payoff" then
              out[#out + 1] = id .. " default " .. table.concat(roles, ",")
            end
          end
        end
      end
      return out
    """)
    assert bad == [], bad[:20]
    no_errors(w)


if __name__ == "__main__":
    run_all(globals())
