"""Azeromon 0.41: the battle effects, step 1 (Games/Azeromon/Fx.lua, FxMoves.lua; the battle's attack event flags).

Covers: every Beast and Fire kit move plays its own effect to its end, both ways (your beast on the foe, the foe on
yours), stays inside the block budget and leaves nothing behind once its sparks and smoke are gone; Beast and Fire
signature moves get a shape by their name (their casts wind up like the type's big cast); a move of a type not drawn
yet keeps the lunge (no effect); a guard move only plays its clip and the "guard" event forms the shell of
its type (all eight), which a guarded hit makes flare without knocking the beast back; each of the eight marks shows
while the snapshot has it and stops when it goes; Savage Maul and Pyroblast wind up while they wait, other casts
don't yet; a combo holds a hit stop; big hits shake the scene unless /dz azeromon shake off; the attack event says
how the hit lands (miss, combo, guarded, released, the move's id); and a real battle plays the effects through the UI.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_fx.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

KIT = ["kclaw", "krend", "kferobite", "kmaul", "kskullbash", "kscorch", "kimmolate", "kincinerate", "kpyroblast",
       "kcounterspell"]
MARKS = ["bleed", "immolate", "corrupt", "chill", "rooted", "exposed", "charged", "regrowth"]
TYPES = ["BEAST", "FIRE", "WATER", "NATURE", "SHADOW", "EARTH", "AIR", "MECH"]

# Lua helpers: a snapshot of the battle on screen, and stepping the effects the way UpdateBattle does
FX = r"""
T_FX = {}
local F, D = ns.AzeroFx, ns.AzeroData
function T_FX.snap(extra)
  local b = ns.Azero.battle
  local s = { ally = { sp = b.ally.mon.sp }, foe = { sp = b.foe.mon.sp } }
  for side, t in pairs(extra or {}) do for k, v in pairs(t) do s[side][k] = v end end
  return s
end
-- steps F.Frame at 60 fps for secs (default: the anim's length and 2.5 s for its smoke to clear); returns the most
-- blocks seen, whether the anim ended, whether a hit stop held it, how far each beast was moved and the last state
function T_FX.run(anim, snap, secs)
  local out = { peak = 0, ended = false, held = false, moved = { foe = 0, ally = 0 }, shook = false }
  secs = secs or ((anim and anim.dur or 0) + 2.5)
  local t = 0
  while t < secs do
    F.Frame(1 / 60, snap)
    if anim and not out.ended then
      if anim.hold and anim.hold() then out.held = true else anim.t = anim.t + 1 / 60 end
      if anim.t >= anim.dur then out.ended = true if anim.done then anim.done() end end
    end
    local st = F.State()
    if st.blocks > out.peak then out.peak = st.blocks end
    for _, side in ipairs({ 'foe', 'ally' }) do
      local d = math.abs(st.offset[side].dx) + math.abs(st.offset[side].dy)
      if d > out.moved[side] then out.moved[side] = d end
    end
    if st.shake[1] ~= 0 or st.shake[2] ~= 0 then out.shook = true end
    t = t + 1 / 60
  end
  out.state = F.State()
  return out
end
function T_FX.attack(id, side, flags)
  local e = { t = 'attack', side = side or 'ally', move = D.moves[id], id = id }
  for k, v in pairs(flags or {}) do e[k] = v end
  return F.Attack(e)
end
"""


def state(c):
    return c.eval_py("return ns.AzeroUI._State()")


def game(lead="murkling"):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(4)")
    c.eval("ns.Azero:NewGame()")
    c.eval("local M = ns.AzeroMon ns.Azero.save.party = { M.New(%r, 30, ns.Azero.rng) }" % lead)
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")                    # title: CONTINUE
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval(FX)
    return w, c


def to_action(w, c):
    for _ in range(80):
        w.tick(0.2)
        if c.eval("return ns.Azero.battle and ns.Azero.battle.need") == "action" and state(c)["stack"] >= 1:
            return
        c.eval("ns.AzeroUI._HandleKey('A')")
    raise AssertionError("no action menu: %r" % state(c))


def wild(w, c, foe="kobling", lvl=20):
    c.eval("ns.Azero:Run(function(g) local M = ns.AzeroMon g:RunBattle({ M.New(%r, %d, g.rng) }, nil) end)" % (foe, lvl))
    to_action(w, c)


@case
def every_beast_and_fire_move_plays_and_clears_up():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local out = {}
      for _, id in ipairs({ %s }) do
        local cast = ns.AzeroData.moves[id].cast or nil
        local row = {}
        for _, side in ipairs({ 'ally', 'foe' }) do
          ns.AzeroFx.Reset()
          local a = T_FX.attack(id, side, { released = cast })
          local res = a and T_FX.run(a, T_FX.snap()) or {}
          row[side] = { anim = a ~= nil, peak = res.peak, ended = res.ended, left = res.state and res.state.blocks,
                        parts = res.state and res.state.parts, playing = res.state and res.state.playing,
                        moved = res.moved and res.moved[side] }
        end
        out[id] = row
      end
      return out""" % ", ".join("'%s'" % k for k in KIT))
    for mid, row in r.items():
        for side, v in row.items():
            assert v["anim"] and v["ended"] and not v["playing"], (mid, side, v)
            assert 10 <= v["peak"] <= 700, (mid, side, v)          # (the pool's budget; the mockup measured up to ~600)
            assert v["left"] == 0 and v["parts"] == 0, (mid, side, v)
    # the moves that close in on the foe really move their beast
    for mid in ("kclaw", "kferobite", "kmaul", "kskullbash"):
        assert r[mid]["ally"]["moved"] >= 6 and r[mid]["foe"]["moved"] >= 6, (mid, r[mid])
    no_errors(w)


@case
def beast_and_fire_signatures_get_a_shape_others_wait():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local F, D = ns.AzeroFx, ns.AzeroData
      local out = { shapes = {}, played = {}, casts = {} }
      for id, mv in pairs(D.moves) do
        if id:match('^s[fc]x?_') then
          local drawn = F.Sig(id, mv) ~= nil
          if (mv.type == 'BEAST' or mv.type == 'FIRE') ~= drawn then out.wrong = id end
          if drawn then
            out.shapes[mv.name] = F.ShapeOf(mv.name)
            if not out.played[F.ShapeOf(mv.name)] then
              F.Reset()
              local res = T_FX.run(T_FX.attack(id, 'ally', { released = mv.cast or nil }), T_FX.snap())
              out.played[F.ShapeOf(mv.name)] = { ended = res.ended, peak = res.peak, left = res.state.blocks }
            end
            if id:match('^scx?_') then out.casts[id] = F.CastFor(id) or false end
          end
        end
      end
      return out""")
    assert "wrong" not in r, r.get("wrong")
    assert r["shapes"].get("Flame Breath") == "breath" and r["shapes"].get("Ravage") == "rakes", r["shapes"]
    for shape, v in r["played"].items():
        assert v["ended"] and v["peak"] >= 10 and v["left"] == 0, (shape, v)
    assert r["casts"] and all(v in ("maul", "pyro") for v in r["casts"].values()), r["casts"]
    no_errors(w)


@case
def other_types_keep_the_lunge_and_guards_only_play_a_clip():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local out = {}
      for _, id in ipairs({ 'kwaterbolt', 'kthorns', 'kshadowbite', 'krockthrow', 'kdive', 'kgears', 'ktidalwave' }) do
        out[id] = T_FX.attack(id, 'ally') ~= nil
      end
      ns.AzeroFx.Reset()
      local g = T_FX.attack('khide', 'ally')
      out.guardDur = g and g.dur
      return out""")
    assert not any(v for k, v in r.items() if k != "guardDur"), r
    assert r["guardDur"] and r["guardDur"] <= 0.3, r
    no_errors(w)


@case
def each_guard_forms_its_shell_and_a_guarded_hit_flares_it():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local out = {}
      for _, T in ipairs({ %s }) do
        ns.AzeroFx.Reset()
        local snap = T_FX.snap({ foe = { guard = 2, guardType = T } })
        local a = ns.AzeroFx.Guard({ t = 'guard', side = 'foe', snap = snap })
        local res = T_FX.run(a, snap, 1.0)
        out[T] = { shell = res.state.shell.foe, peak = res.peak, ended = res.ended }
      end
      -- a claw into Stoneskin: sparks fly back, the foe isn't knocked about
      ns.AzeroFx.Reset()
      local snap = T_FX.snap({ foe = { guard = 2, guardType = 'EARTH' } })
      T_FX.run(nil, snap, 0.1)
      local a = T_FX.attack('kclaw', 'ally', { guarded = true })
      local res = T_FX.run(a, snap)
      out.guarded = { moved = res.moved.foe, ended = res.ended }
      -- gone from the snapshot: the shell goes
      local res2 = T_FX.run(nil, T_FX.snap(), 0.1)
      out.after = res2.state.shell.foe or false
      return out""" % ", ".join("'%s'" % t for t in TYPES))
    for t in TYPES:
        v = r[t]
        assert v["shell"] == t and v["peak"] >= 8 and v["ended"], (t, v)
    assert r["guarded"]["ended"] and r["guarded"]["moved"] == 0, r["guarded"]
    assert r["after"] is False, r
    no_errors(w)


@case
def each_mark_shows_while_the_snapshot_has_it():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local out = {}
      for _, id in ipairs({ %s }) do
        ns.AzeroFx.Reset()
        local res = T_FX.run(nil, T_FX.snap({ foe = { marks = { [id] = 3 } } }), 1.5)
        local pop = ns.AzeroFx.Mark({ t = 'mark', side = 'foe', mark = id, turns = 3 })
        local res2 = T_FX.run(pop, T_FX.snap({ foe = { marks = { [id] = 3 } } }), 0.5)
        local gone = T_FX.run(nil, T_FX.snap(), 2.5)
        out[id] = { marks = res.state.marks.foe, peak = res.peak, pop = pop ~= nil and res2.ended,
                    after = gone.state.marks.foe, left = gone.state.blocks }
      end
      out.off = ns.AzeroFx.Mark({ t = 'mark', side = 'foe', mark = 'bleed', turns = 0 }) == nil
      return out""" % ", ".join("'%s'" % m for m in MARKS))
    for m in MARKS:
        v = r[m]
        assert v["marks"] == [m] and v["peak"] >= 1 and v["pop"], (m, v)
        assert v["after"] == [] and v["left"] == 0, (m, v)
    assert r["off"], r
    no_errors(w)


@case
def maul_and_pyroblast_wind_up_while_they_wait():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local out = {}
      for _, id in ipairs({ 'kmaul', 'kpyroblast', 'ktidalwave' }) do
        ns.AzeroFx.Reset()
        local snap = T_FX.snap({ ally = { cast = { id = id, name = 'x', power = 100 } } })
        local a = ns.AzeroFx.Windup({ t = 'cast', side = 'ally', snap = snap })
        local res = T_FX.run(a, snap, 1.2)
        out[id] = { anim = a ~= nil, windup = res.state.windup.ally or false, peak = res.peak }
      end
      return out""")
    assert r["kmaul"]["anim"] and r["kmaul"]["windup"] == "maul" and r["kmaul"]["peak"] > 0, r
    assert r["kpyroblast"]["anim"] and r["kpyroblast"]["windup"] == "pyro" and r["kpyroblast"]["peak"] >= 10, r
    assert not r["ktidalwave"]["anim"] and r["ktidalwave"]["windup"] is False, r
    no_errors(w)


@case
def a_combo_holds_a_hit_stop_and_big_hits_shake_unless_turned_off():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local out = {}
      ns.AzeroFx.Reset()
      out.combo = T_FX.run(T_FX.attack('kferobite', 'ally', { combo = true }), T_FX.snap())
      ns.AzeroFx.Reset()
      out.plain = T_FX.run(T_FX.attack('kclaw', 'ally'), T_FX.snap())
      ns.AzeroFx.Reset()
      out.maul = T_FX.run(T_FX.attack('kmaul', 'ally', { released = true }), T_FX.snap())
      ns.Azero:Data().noShake = true
      ns.AzeroFx.Reset()
      out.calm = T_FX.run(T_FX.attack('kmaul', 'ally', { released = true }), T_FX.snap())
      ns.Azero:Data().noShake = nil
      for k, v in pairs(out) do out[k] = { held = v.held, shook = v.shook, ended = v.ended } end
      return out""")
    assert r["combo"]["held"] and r["combo"]["ended"] and not r["plain"]["held"], r
    assert r["maul"]["shook"] and not r["calm"]["shook"] and r["calm"]["ended"], r
    no_errors(w)


@case
def the_attack_event_says_how_the_hit_lands():
    w, c = game()
    r = c.eval_py(r"""
      local B, M, D = ns.AzeroBattle, ns.AzeroMon, ns.AzeroData
      local function battle(sp, foe)
        local b = B.New({ party = { M.New(sp, 25, ns.Azero.rng) }, foes = { M.New(foe or 'kobling', 25, ns.Azero.rng) },
                          wild = true, rng = math.random })
        while b:Pop() do end
        return b
      end
      local function slotOf(b, id)
        for i, m in ipairs(b.ally.mon.moves) do if m.id == id then return i end end
      end
      local function mine(b)
        local out = {}
        while true do
          local e = b:Pop()
          if not e then break end
          if e.side == 'ally' and (e.t == 'attack' or e.t == 'cast') then out[#out + 1] = e end
        end
        return out
      end
      local out = {}
      -- a miss: every roll of 1-100 comes up 100 (Entangling Roots hits 95 in 100)
      local b = battle('lashling')
      b.ally.mon.moves[1].id = 'kroots'
      b.rng = function(a, z) if a == 1 and z == 100 then return 100 end return math.random(a, z) end
      b:Act({ kind = 'move', idx = 1 })
      local e = mine(b)[1]
      out.miss = { miss = e.miss, id = e.id }
      -- a combo: Ferocious Bite on a bleeding foe
      b = battle('wolfpup')
      b.foe.marks.bleed = 3
      b:Act({ kind = 'move', idx = slotOf(b, 'kferobite') })
      e = mine(b)[1]
      out.combo = { combo = e.combo, id = e.id, miss = e.miss or false, eff = e.eff }
      -- into a guard
      b = battle('wolfpup')
      b.foe.guard, b.foe.guardT = 0.25, 3
      b:Act({ kind = 'move', idx = slotOf(b, 'krend') })
      e = mine(b)[1]
      out.guarded = { guarded = e.guarded, combo = e.combo or false }
      -- a cast: announced (its snapshot names it), then released next turn
      b = battle('emberwhelp')
      local s = slotOf(b, 'kpyroblast')
      if not s then b.ally.mon.moves[4] = { id = 'kpyroblast', pp = 10 } s = 4 end
      b:Act({ kind = 'move', idx = s })
      local first = mine(b)
      out.cast = { t = first[#first] and first[#first].t, snapId = first[#first] and first[#first].snap.ally.cast and first[#first].snap.ally.cast.id }
      b:Act({ kind = 'release' })
      local second = mine(b)
      local rel
      for _, x in ipairs(second) do if x.t == 'attack' then rel = x end end
      out.release = rel and { released = rel.released, id = rel.id } or false
      -- a guard move: the snapshot says which shell
      b = battle('emberwhelp')
      b.ally.mon.moves[1] = { id = 'kfireward', pp = 15 }
      b:Act({ kind = 'move', idx = 1 })
      local gt
      while true do local x = b:Pop() if not x then break end if x.t == 'guard' and x.side == 'ally' then gt = x.snap.ally.guardType end end
      out.guardType = gt or false
      return out""")
    assert r["miss"] == {"miss": True, "id": "kroots"}, r
    assert r["combo"]["combo"] is True and r["combo"]["id"] == "kferobite" and not r["combo"]["miss"], r
    assert r["guarded"]["guarded"] is True and not r["guarded"]["combo"], r
    assert r["cast"] == {"t": "cast", "snapId": "kpyroblast"}, r
    assert r["release"] == {"released": True, "id": "kpyroblast"}, r
    assert r["guardType"] == "FIRE", r
    no_errors(w)


@case
def a_battle_plays_the_effects_through_the_ui():
    w, c = game("emberwhelp")
    wild(w, c, foe="kobling", lvl=12)
    idx = c.eval("for i, m in ipairs(ns.Azero.battle.ally.mon.moves) do if m.id == 'kincinerate' then return i end end")
    assert idx, "no Incinerate"
    c.eval("ns.Azero.battle:Act({ kind = 'move', idx = %d })" % idx)        # (the turn resolves at once; it plays back)
    seen, peak = False, 0
    for i in range(200):
        w.tick(0.05)
        st = c.eval_py("return ns.AzeroFx.State()")
        seen = seen or st["playing"]
        peak = max(peak, st["blocks"])
        s = state(c)
        if s["msg"] or (s.get("text") and not s["waitText"]):
            c.eval("ns.AzeroUI._HandleKey('A')")
        if i > 20 and c.eval("local b = ns.Azero.battle return b and #b.events == 0") and not st["playing"]:
            break
    assert seen and peak >= 10, (seen, peak)
    no_errors(w)


if __name__ == "__main__":
    run_all()
