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


if __name__ == "__main__":
    run_all()
