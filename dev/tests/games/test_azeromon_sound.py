"""Azeromon: music and sounds.

Covers: the title theme; each map's track (Elwynn by day and by night, the inn's tavern tune, the Deadmines'
cove); battle music and back to the map afterwards; music switched off and on from CONTROLS; closing the game
hands the zone music back; sound effects in a battle (the move type's hit, a level-up, a catch) and none when off.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_sound.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

FOREST_DAY, FOREST_NIGHT = {53492, 53493, 53494}, {53495, 53496, 53497, 53498}
TAVERN, COVE, BATTLE = {53748, 53749, 53750, 53751}, {53762, 53763, 53764, 53765}, {53684, 53685, 53686, 53687, 53688}


def music(c):
    return c.eval("return __MOCK.music")


def game():
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(5)")
    c.eval("ns.Azero:NewGame() ns.Azero.clockHour = 12")
    c.eval("ns.Azero.save.party = { ns.AzeroMon.New('murkling', 30, ns.Azero.rng) }")
    c.eval("ns.AzeroSound._Reset() ns.Azero:Data().music = nil ns.Azero:Data().sfx = nil")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    return w, c


def enter(w, c):
    c.eval("ns.AzeroUI._HandleKey('A')")                        # CONTINUE
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    w.tick(0.1)


@case
def each_screen_and_map_has_its_music():
    w, c = game()
    assert music(c) == 53223                                    # the title: the World of Warcraft theme
    enter(w, c)
    c.eval("ns.Azero:EnterMap('town', 10, 10, 'down', true)")
    w.tick(0.1)
    assert music(c) in FOREST_DAY, music(c)
    c.eval("ns.Azero.clockHour = 23")
    w.tick(0.1)
    assert music(c) in FOREST_NIGHT, music(c)
    c.eval("ns.Azero:EnterMap('post', 4, 5, 'up', true)")
    w.tick(0.1)
    assert music(c) in TAVERN, music(c)
    c.eval("ns.Azero:EnterMap('dm3', 3, 10, 'right', true)")
    w.tick(0.1)
    assert music(c) in COVE, music(c)
    # a battle has its own, then the map's comes back
    c.eval("ns.Azero:EnterMap('route1', 10, 10, 'down', true)")
    c.eval("ns.Azero:Run(function(g) g:WildBattle('owlet', 2) end)")
    w.tick(0.3)
    assert music(c) in BATTLE, music(c)
    c.eval("ns.AzeroUI._Detach() ns.Azero.battle = nil ns.Azero.pending = nil ns.Azero.co = nil")
    no_errors(w)


@case
def music_can_be_switched_off_and_closing_the_game_gives_the_zone_music_back():
    w, c = game()
    enter(w, c)
    w.tick(0.1)
    assert music(c) is not None
    c.eval("ns.Azero:Data().music = false")
    w.tick(0.1)
    assert music(c) is None
    c.eval("ns.Azero:Data().music = nil")
    w.tick(0.1)
    assert music(c) is not None
    c.eval("ns.AzeroUI._Root():Hide()")
    assert music(c) is None
    no_errors(w)


@case
def battle_sounds_hits_level_ups_and_catches():
    w, c = game()
    enter(w, c)
    s0 = len(c.eval_py("return __MOCK.sounds") or [])
    c.eval("""local G, M = ns.Azero, ns.AzeroMon
      local mon = G.save.party[1]
      mon.exp = M.ExpForLevel(31) - 1
      mon.moves = { { id = 'waterjet', pp = 25 } }             -- one hit that does damage
      G:Run(function(g) local f = M.New('owlet', 2, g.rng) f.hp = 1 g:RunBattle({ f }, nil) end)""")
    for _ in range(80):
        w.tick(0.2)
        if c.eval("return ns.Azero.battle and ns.Azero.battle.need") == "action" and c.eval_py("return ns.AzeroUI._State()")["stack"] >= 1:
            c.eval("ns.AzeroUI._HandleKey('A')")                 # FIGHT
            c.eval("ns.AzeroUI._HandleKey('A')")                 # the first move
        elif c.eval("return ns.Azero.battle == nil"):
            break
        else:
            c.eval("ns.AzeroUI._HandleKey('A')")
    sounds = (c.eval_py("return __MOCK.sounds") or [])[s0:]
    hits = set(c.eval_py("local o = {} for _, id in pairs(ns.AzeroSound.SFX.hit) do o[#o + 1] = id end return o"))
    assert any(s in hits for s in sounds), sounds
    assert 567431 in sounds, sounds                              # the level-up
    # the catch
    s0 = len(c.eval_py("return __MOCK.sounds") or [])
    r = c.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      local f = M.New('owlet', 2, G.rng)
      local b = ns.AzeroBattle.New({ party = G.save.party, foes = { f }, wild = true, rng = function(a, b) return a end,
                                     bag = { net = 1 } })
      b:UseItem('net')
      local e, got = b:Pop(), false
      while e do if e.t == 'sfx' and e.sound == 'catch' then got = true end e = b:Pop() end
      return got""")
    assert r is True
    # nothing at all with sounds off
    c.eval("ns.Azero:Data().sfx = false")
    s0 = len(c.eval_py("return __MOCK.sounds") or [])
    c.eval("ns.AzeroSound:Play('levelup') ns.AzeroSound:Play('hit', 'FIRE')")
    assert len(c.eval_py("return __MOCK.sounds") or []) == s0
    no_errors(w)


@case
def every_sound_effect_is_a_file_id_and_game_events_make_sounds():
    w, c = game()
    enter(w, c)
    bad = c.eval_py("""local o = {}
      for name, id in pairs(ns.AzeroSound.SFX) do
        if type(id) == 'table' then for _, v in pairs(id) do if type(v) ~= 'number' then o[#o + 1] = name end end
        elseif type(id) ~= 'number' then o[#o + 1] = name end
      end
      for ev, r in pairs(ns.AzeroSound.ON_EVENT) do
        if type(r) == 'string' and not ns.AzeroSound.SFX[r] then o[#o + 1] = ev end
      end
      return o""") or []
    assert bad == [], bad
    SFX = c.eval_py("local o = {} for k, v in pairs(ns.AzeroSound.SFX) do if type(v) == 'number' then o[k] = v end end return o")
    def played(fn):
        c.eval("ns.AzeroSound._Reset()")
        s0 = len(c.eval_py("return __MOCK.sounds") or [])
        c.eval(fn)
        return (c.eval_py("return __MOCK.sounds") or [])[s0:]
    assert SFX["fanfare"] in played("ns.Azero:Emit('badge', { id = 'x' })")
    assert SFX["gift"] in played("ns.Azero:Emit('tame', { how = 'gift', mon = ns.Azero.save.party[1] })")
    assert played("ns.Azero:Emit('tame', { how = 'caught', mon = ns.Azero.save.party[1] })") == []        # the battle's catch sound covers it
    assert SFX["herb"] in played("ns.Azero:Emit('gather', { prof = 'herbalism' })")
    assert SFX["heal"] in played("ns.Azero:HealParty()")
    assert SFX["error"] in played("ns.Azero.save.money = 0 ns.Azero:Buy('potion', 1)")
    # the same sound twice at once plays once; the wall thud waits longer
    assert len(played("ns.AzeroSound:Play('cursor') ns.AzeroSound:Play('cursor')")) == 1
    # battle events: a miss and a status
    got = c.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      local f = M.New('owlet', 2, G.rng)
      local b = ns.AzeroBattle.New({ party = G.save.party, foes = { f }, wild = true, rng = function(a, b) return a end })
      b:ApplyStatus('foe', 'psn')
      local o, e = {}, b:Pop()
      while e do if e.t == 'sfx' then o[#o + 1] = e.sound end e = b:Pop() end
      return o""")
    assert "psn" in got, got
    no_errors(w)


def ambience(c):
    return c.eval_py("return ns.AzeroSound:Playing()") or {}


def at(w, c, where, hour=12):
    c.eval("ns.Azero.clockHour = %r ns.Azero:EnterMap(%s, true)" % (hour, where))
    w.tick(0.6)


@case
def the_zone_bed_follows_day_night_and_rain():
    w, c = game()
    enter(w, c)
    at(w, c, "'town', 10, 10, 'down'")
    assert ambience(c).get("bed") == 539131, ambience(c)            # Elwynn by day: birds
    c.eval("ns.Azero.clockHour = 23")
    w.tick(0.6)
    assert ambience(c).get("bed") == 539108, ambience(c)            # by night: crickets
    c.eval("ns.Azero.raining = true ns.AzeroSound:UpdateAmbience(1, true)")
    assert ambience(c).get("rain") == 538981, ambience(c)
    at(w, c, "'bootybay', 12, 12, 'down'")
    assert ambience(c).get("bed") == 539048, ambience(c)            # the beach
    at(w, c, "'post', 4, 5, 'up'", hour=12)
    assert ambience(c).get("bed") == 537422, ambience(c)            # a quiet inn at noon
    at(w, c, "'post', 4, 5, 'up'", hour=20)
    assert ambience(c).get("bed") == 537423, ambience(c)            # crowded at supper
    no_errors(w)


@case
def sources_start_near_and_fade_away():
    w, c = game()
    enter(w, c)
    c.eval("ns.AzeroSound.trace = {}")
    at(w, c, "'town', 28, 14, 'right'")
    assert ambience(c).get("water") == 538973, ambience(c)
    at(w, c, "'town', 20, 22, 'right'")                              # three tiles from Argus at the anvil
    a = ambience(c)
    assert a.get("smithy") == 537332 and "water" not in a, a
    trace = c.eval_py("return ns.AzeroSound.trace")
    assert ["stop", "water", 538973] in trace, trace
    for _ in range(12):
        w.tick(0.5)
    shots = [t for t in c.eval_py("return ns.AzeroSound.trace") if t[0] == "shot" and t[1] == "anvil"]
    assert len(shots) >= 2, shots                                    # the anvil rings every ~3 s this close
    at(w, c, "'town', 20, 22, 'right'", hour=23)                     # Argus is at the inn: the smithy is quiet
    assert "smithy" not in ambience(c), ambience(c)
    # the school of fish: stand next to it
    spot = c.eval_py("""local m, s = ns.Azero.map, ns.AzeroFish.School(ns.Azero.map)
      for dir, d in pairs(ns.Azero.DIRS) do
        local x, y = s.x - d[1], s.y - d[2]
        if not m.water[m.key(x, y)] and not m.solid[m.key(x, y)] then return { x, y } end
      end""")
    at(w, c, "'town', %d, %d, 'down'" % tuple(spot))
    assert ambience(c).get("school") == 566808, ambience(c)
    no_errors(w)


@case
def loops_restart_as_they_end_and_ambience_switches_off():
    w, c = game()
    enter(w, c)
    c.eval("ns.AzeroSound.trace = {}")
    at(w, c, "'town', 10, 10, 'down'")
    for _ in range(62):
        w.tick(1)
    plays = [t for t in c.eval_py("return ns.AzeroSound.trace") if t[0] == "play" and t[1] == "bed"]
    assert len(plays) == 2, plays                                    # 60 s of Elwynn: once more after a minute
    c.eval("ns.Azero:Data().ambience = false")
    w.tick(0.6)
    assert ambience(c) == {}, ambience(c)
    c.eval("ns.Azero:Data().ambience = nil")
    w.tick(0.6)
    assert ambience(c).get("bed"), ambience(c)
    c.eval("ns.AzeroUI._Root():Hide()")
    assert ambience(c) == {}, ambience(c)
    no_errors(w)


@case
def every_ambience_file_has_a_length():
    w, c = game()
    missing = c.eval_py("""local S, o = ns.AzeroSound, {}
      local function need(id) if not S.LEN[id] then o[#o + 1] = id end end
      for _, b in pairs(S.BEDS) do need(b.day) need(b.night) end
      for _, s in pairs(S.SOURCES) do need(s.id) end
      need(S.TAVERN) need(S.TAVERN_CROWDED) need(S.RAIN)
      return o""") or []
    assert missing == [], missing
    no_errors(w)


if __name__ == "__main__":
    run_all()
