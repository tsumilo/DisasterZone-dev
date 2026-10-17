"""Azeromon 0.41 - 0.43: the battle effects (Games/Azeromon/Fx.lua, FxMoves.lua; the battle's attack event flags).

Covers: every kit move of all eight types plays its own effect to its end, both ways (your beast on the foe, the foe
on yours), stays inside the block budget and leaves nothing behind once its sparks and smoke are gone; every
signature move (all types) gets a shape by its name and plays it, and its cast winds up like its type's big cast;
every boss's cast that can't be interrupted plays its family's blow (a leap and smash, a stomp, a flurry, a quake, a
broadside) or the shape its name picks, its heal or rally plays, and each winds up while it waits; a guard move only
plays its clip and the "guard" event forms the shell of its type (all eight), which a guarded hit makes flare without
knocking the beast back; a move without a recipe (Struggle) keeps the lunge; each of the eight marks shows while the
snapshot has it and stops when it goes; every kit cast winds up while it waits; an interrupt shatters the wind-up and
cracks the cast bar, which is back in place for the next cast; a cast that can't be interrupted turns an iron chain
round its caster, and an interrupt only makes it flare; a combo holds a hit stop; big hits shake the scene unless
/dz azeromon shake off; the attack event says how the hit lands (miss, combo, guarded, released, the move's id); and
a real battle plays the effects through the UI, a boss's wind-up, chain and smash too.

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
       "kcounterspell", "kwaterbolt", "kfrostshock", "kicelance", "ktidalwave", "kwindshear", "kthorns", "kroots",
       "kthornvolley", "kovergrowth", "kregrowth", "kshadowbite", "kcorruption", "kdeathcoil", "kshadowbolt",
       "kspelllock", "krockthrow", "kcrusharmor", "kboulder", "kearthquake", "kwarstomp", "kdive", "khuntersmark",
       "ktalonrake", "ktempest", "kscreech", "kgears", "kchargeup", "krocketpunch", "ksawstorm", "kshock"]
CASTS = {"kmaul": "maul", "kpyroblast": "pyro", "ktidalwave": "tidal", "kovergrowth": "overgrowth",
         "kshadowbolt": "shadowbolt", "kearthquake": "quake", "ktempest": "tempest", "ksawstorm": "sawstorm"}
MARKS = ["bleed", "immolate", "corrupt", "chill", "rooted", "exposed", "charged", "regrowth"]
TYPES = ["BEAST", "FIRE", "WATER", "NATURE", "SHADOW", "EARTH", "AIR", "MECH"]
WINDUP = {"BEAST": "maul", "FIRE": "pyro", "WATER": "tidal", "NATURE": "overgrowth", "SHADOW": "shadowbolt",
          "EARTH": "quake", "AIR": "tempest", "MECH": "sawstorm"}
SHAPES = {"jaws", "flurry", "cleave", "lob", "rakes", "volley", "charge", "breath", "storm", "smash", "vortex", "wave",
          "spit", "dread", "saw", "bolt"}
BOSS_FAMILY = {"hogger": "smash", "vancleef": "flurry", "stitches": "smash", "mukla": "quake", "smite": "stomp",
               "firallon": "broadside", "bangalash": "flurry", "rhahkzor": "smash"}

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
def every_kit_move_plays_and_clears_up():
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
    for mid in ("kclaw", "kferobite", "kmaul", "kskullbash", "kshadowbite", "kdive", "ktalonrake", "kgears"):
        assert r[mid]["ally"]["moved"] >= 6 and r[mid]["foe"]["moved"] >= 6, (mid, r[mid])
    no_errors(w)


@case
def every_signature_gets_a_shape_and_its_cast_winds_up():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local F, D = ns.AzeroFx, ns.AzeroData
      local out = { shapes = {}, played = {}, casts = {}, missing = {} }
      for id, mv in pairs(D.moves) do
        if id:match('^s[fc]x?_') then
          if not F.Sig(id, mv) then out.missing[#out.missing + 1] = id end
          local shape = F.ShapeOf(mv.name)
          out.shapes[mv.name] = shape
          local key = shape .. ' ' .. mv.type                  -- (each shape in each type's colours and bits)
          if not out.played[key] then
            out.played[key] = {}
            for _, side in ipairs({ 'ally', 'foe' }) do
              F.Reset()
              local res = T_FX.run(T_FX.attack(id, side, { released = mv.cast or nil }), T_FX.snap())
              out.played[key][side] = { ended = res.ended, peak = res.peak, left = res.state.blocks, parts = res.state.parts }
            end
          end
          if id:match('^scx?_') then out.casts[id] = { F.CastFor(id) or false, mv.type, mv.name } end
        end
      end
      return out""")
    assert r["missing"] == [], r["missing"]
    sh = r["shapes"]
    for name, shape in {"Flame Breath": "breath", "Ravage": "rakes", "Riptide": "wave", "Tsunami": "wave",
                        "Whirlwind": "vortex", "Maelstrom": "vortex", "Nightmare": "dread", "Corrosive Poison": "spit",
                        "Buzzsaw": "saw", "Razor Petal": "volley", "Crystal Spines": "volley", "Ogre Slam": "smash",
                        "Headhunter's Strike": "lob", "Slag Toss": "lob", "Steam Jet": "breath"}.items():
        assert sh.get(name) == shape, (name, sh.get(name))
    assert set(sh.values()) == SHAPES, set(sh.values()) ^ SHAPES
    for key, row in r["played"].items():
        for side, v in row.items():
            assert v["ended"] and 10 <= v["peak"] <= 700 and v["left"] == 0 and v["parts"] == 0, (key, side, v)
    assert r["casts"], r
    for mid, (key, typ, name) in r["casts"].items():
        assert key == ("broadside" if "Cannon" in name else WINDUP[typ]), (mid, key, typ, name)
    no_errors(w)


@case
def every_boss_cast_heal_and_rally_plays_its_own_effect():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local F, D = ns.AzeroFx, ns.AzeroData
      local out = { moves = {} }
      for id, mv in pairs(D.moves) do
        if id:match('^bcast_') or id:match('^bsecond_') then
          for _, side in ipairs({ 'foe', 'ally' }) do
            F.Reset()
            local a = T_FX.attack(id, side, { released = true })
            local res = a and T_FX.run(a, T_FX.snap()) or {}
            out.moves[id .. ' ' .. side] = { anim = a ~= nil, ended = res.ended, peak = res.peak, left = res.state and res.state.blocks,
                                            parts = res.state and res.state.parts, moved = res.moved and res.moved[side] }
          end
        end
      end
      -- Hogger Smash into a guard: the shell flares, the beast isn't thrown about; a miss lands beside it
      -- (no shake: the scene shakes the beasts with it)
      F.Reset()
      ns.Azero:Data().noShake = true
      local snap = T_FX.snap({ ally = { guard = 2, guardType = 'WATER' } })
      T_FX.run(nil, snap, 0.1)
      local g = T_FX.run(T_FX.attack('bcast_hogger', 'foe', { released = true, guarded = true }), snap)
      ns.Azero:Data().noShake = nil
      out.guarded = { ended = g.ended, moved = g.moved.ally }
      F.Reset()
      local m = T_FX.run(T_FX.attack('bcast_hogger', 'foe', { released = true, miss = true }), T_FX.snap())
      out.miss = { ended = m.ended, left = m.state.blocks }
      return out""")
    assert len(r["moves"]) >= 32, len(r["moves"])
    for key, v in r["moves"].items():
        assert v["anim"] and v["ended"] and 10 <= v["peak"] <= 700, (key, v)
        assert v["left"] == 0 and v["parts"] == 0, (key, v)
    for boss in ("hogger", "stitches", "rhahkzor"):                     # (they leap onto the target)
        assert r["moves"]["bcast_%s foe" % boss]["moved"] >= 10, (boss, r["moves"]["bcast_%s foe" % boss])
    assert r["guarded"]["ended"] and r["guarded"]["moved"] == 0, r["guarded"]
    assert r["miss"]["ended"] and r["miss"]["left"] == 0, r["miss"]
    no_errors(w)


@case
def guards_only_play_a_clip_and_struggle_keeps_the_lunge():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local out = {}
      out.struggle = ns.AzeroFx.Attack({ t = 'attack', side = 'ally', move = ns.AzeroData.moves.kclaw }) ~= nil   -- (no id)
      ns.AzeroFx.Reset()
      local g = T_FX.attack('khide', 'ally')
      out.guardDur = g and g.dur
      return out""")
    assert r["struggle"] is False, r
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
def every_cast_winds_up_while_it_waits():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local D = ns.AzeroData
      local ids = { %s }
      for id in pairs(D.moves) do if id:match('^bcast_') or id:match('^bsecond_') then ids[#ids + 1] = id end end
      local out = {}
      for _, id in ipairs(ids) do
        for _, side in ipairs({ 'ally', 'foe' }) do
          ns.AzeroFx.Reset()
          local snap = T_FX.snap({ [side] = { cast = { id = id, name = 'x', power = 100 } } })
          local a = ns.AzeroFx.Windup({ t = 'cast', side = side, snap = snap })
          local res = T_FX.run(a, snap, 1.2)
          out[id .. '_' .. side] = { anim = a ~= nil, windup = res.state.windup[side] or false, peak = res.peak,
                                     type = D.moves[id].type, heal = D.moves[id].heal ~= nil }
        end
      end
      return out""" % ", ".join("'%s'" % k for k in CASTS))
    for mid, key in CASTS.items():
        for side in ("ally", "foe"):
            v = r["%s_%s" % (mid, side)]
            assert v["anim"] and v["windup"] == key and v["peak"] > 0, (mid, side, v)
    bosses = [k for k in r if k.startswith("bcast_") or k.startswith("bsecond_")]
    assert len(bosses) >= 32, bosses
    for k in bosses:
        v = r[k]
        mid = k.rsplit("_", 1)[0]
        boss = mid.split("_", 1)[1]
        if mid.startswith("bcast_"):
            want = BOSS_FAMILY.get(boss) or WINDUP[v["type"]]
        else:
            want = "heal" if v["heal"] else "rally"
        assert v["anim"] and v["windup"] == want and v["peak"] > 0, (k, want, v)
    no_errors(w)


@case
def an_interrupt_shatters_the_wind_up_and_a_chain_shrugs_it_off():
    w, c = game()
    wild(w, c)
    r = c.eval_py(r"""
      local F = ns.AzeroFx
      local out = {}
      -- the foe winds up Tidal Wave; an interrupt lands
      F.Reset()
      local snap = T_FX.snap({ foe = { cast = { id = 'ktidalwave', name = 'Tidal Wave', power = 100, type = 'WATER' } } })
      out.before = T_FX.run(nil, snap, 0.8).state.windup.foe
      local res = T_FX.run(F.Break({ t = 'interrupt', side = 'foe', snap = snap }), snap, 0.6)
      out.broken = { ended = res.ended, windup = res.state.windup.foe or false, broken = res.state.broken.foe or false,
                     peak = res.peak }
      local bar = ns.AzeroUI.Kit.R.foeCast
      out.bar = { alpha = bar:GetAlpha(), restore = bar.restore ~= nil }
      if bar.restore then bar.restore() end
      out.restored = { alpha = bar:GetAlpha(), restore = bar.restore ~= nil }
      out.after = T_FX.run(nil, T_FX.snap(), 0.1).state.broken.foe or false
      -- a boss's cast that can't be interrupted: the chain turns; an interrupt bounces off it
      F.Reset()
      local boss = T_FX.snap({ foe = { cast = { id = 'bcast_hogger', name = 'Hogger Smash', power = 130, unstoppable = true } } })
      local idle = T_FX.run(nil, boss, 0.5)
      out.chain = { chain = idle.state.chain.foe or false, peak = idle.peak, windup = idle.state.windup.foe or false,
                    moved = idle.moved.foe }
      local sh = T_FX.run(F.Shrug({ t = 'unstoppable', side = 'foe', snap = boss }), boss, 0.7)
      out.shrug = { ended = sh.ended, chain = sh.state.chain.foe or false, moved = sh.moved.foe }
      out.gone = T_FX.run(nil, T_FX.snap(), 0.1).state.chain.foe or false
      return out""")
    assert r["before"] == "tidal", r
    assert r["broken"]["ended"] and r["broken"]["windup"] is False and r["broken"]["broken"] and r["broken"]["peak"] > 0, r
    assert r["bar"]["alpha"] < 0.6 and r["bar"]["restore"], r
    assert r["restored"]["alpha"] == 1 and not r["restored"]["restore"], r
    assert r["after"] is False, r
    assert r["chain"]["chain"] and r["chain"]["peak"] >= 10 and r["chain"]["windup"] == "smash", r
    # (it isn't knocked about: it only rocks in its crouch as before)
    assert r["shrug"]["ended"] and r["shrug"]["chain"] and r["shrug"]["moved"] <= r["chain"]["moved"], r
    assert r["gone"] is False, r
    no_errors(w)


@case
def an_interrupt_in_a_real_battle_cracks_the_bar_and_puts_it_back():
    w, c = game("wolfpup")
    wild(w, c, foe="kobling", lvl=20)
    c.eval("ns.Azero.battle.foe.mon.moves = { { id = 'kearthquake', pp = 10 } }")

    def slot(mid):
        return c.eval("for i, m in ipairs(ns.Azero.battle.ally.mon.moves) do if m.id == %r then return i end end" % mid)

    def play_turn(mid):
        seen = {"broken": False, "windup": None}
        c.eval("ns.Azero.battle:Act({ kind = 'move', idx = %d })" % slot(mid))
        for i in range(240):
            w.tick(0.05)
            st = c.eval_py("return ns.AzeroFx.State()")
            seen["broken"] = seen["broken"] or bool((st.get("broken") or {}).get("foe"))
            seen["windup"] = seen["windup"] or (st.get("windup") or {}).get("foe")
            s = state(c)
            if s["msg"] or (s.get("text") and not s["waitText"]):
                c.eval("ns.AzeroUI._HandleKey('A')")
            if i > 20 and c.eval("local b = ns.Azero.battle return b and #b.events == 0") and not st["playing"]:
                break
        return seen

    first = play_turn("krend")                              # the foe begins Earthquake: it winds up
    assert first["windup"] == "quake", first
    second = play_turn("kskullbash")                        # Skull Bash goes first and breaks it
    assert second["broken"], second
    bar = c.eval_py("local f = ns.AzeroUI.Kit.R.foeCast return { shown = f:IsShown(), alpha = f:GetAlpha(), "
                    "restore = f.restore ~= nil }")
    assert not bar["shown"] and bar["alpha"] == 1 and not bar["restore"], bar
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


@case
def a_boss_winds_up_and_smashes_through_the_ui():
    w, c = game("murkling")
    c.eval("ns.Azero:Run(function(g) local M = ns.AzeroMon g:RunBattle({ M.New('hogger', 12, g.rng) }, nil) end)")
    to_action(w, c)
    c.eval("ns.Azero.battle.foe.mon.moves = { { id = 'bcast_hogger', pp = 10 } }")
    idx = c.eval("for i, m in ipairs(ns.Azero.battle.ally.mon.moves) do "
                 "if ns.AzeroData.moves[m.id].role == 'filler' then return i end end")
    assert idx, "no filler"

    def play_turn():
        seen = {"windup": None, "chain": False, "peak": 0, "leap": 0}
        c.eval("ns.Azero.battle:Act({ kind = 'move', idx = %d })" % idx)
        for i in range(260):
            w.tick(0.05)
            st = c.eval_py("return ns.AzeroFx.State()")
            seen["windup"] = seen["windup"] or (st.get("windup") or {}).get("foe")
            seen["chain"] = seen["chain"] or bool((st.get("chain") or {}).get("foe"))
            seen["peak"] = max(seen["peak"], st["blocks"])
            off = st["offset"]["foe"]
            seen["leap"] = max(seen["leap"], abs(off["dx"]) + abs(off["dy"]))
            s = state(c)
            if s["msg"] or (s.get("text") and not s["waitText"]):
                c.eval("ns.AzeroUI._HandleKey('A')")
            if i > 20 and c.eval("local b = ns.Azero.battle return b and #b.events == 0") and not st["playing"]:
                break
        return seen

    first = play_turn()                                     # Hogger winds up Hogger Smash: it can't be interrupted
    assert first["windup"] == "smash" and first["chain"], first
    second = play_turn()                                    # it lands: the leap and the smash
    assert second["leap"] >= 10 and second["peak"] >= 100, second
    no_errors(w)


if __name__ == "__main__":
    run_all()
