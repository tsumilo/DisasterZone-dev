"""Azeromon: footsteps (Steps.lua, 0.47).

Covers: the baked files are up to date with their generator and every listed mix is on disk (and nothing else);
each ground comes from its tile in every theme (grass, tall grass, roads, sand, docks, shallows; inn floors, rugs,
flagstones, cave floors and rails); walking plays one step per tile on Master as the foot lands, not before;
the rain wets the outdoor grounds and leaves the indoor ones dry; the first step into the shallows splashes and
the next ones don't; a mix never repeats one of the last two; CONTROLS > Footsteps, Sounds off and an older art
set silence them.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_steps.py [-k name]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
DEV = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(DEV, "generators"))

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

PACK = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone_Azeromon")

# records every PlaySoundFile: { file, channel }
SPY = ("__AZ_SND = {} local real = PlaySoundFile PlaySoundFile = function(f, ch)"
       " __AZ_SND[#__AZ_SND + 1] = { tostring(f), ch } if real then return real(f, ch) end return true end")


def play(map_id, x, y, face="right", rain=False, hour=12):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(3)")
    c.eval("ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("ns.Azero.clockHour = %r ns.Azero.forceRain = %s ns.Azero:EnterMap(%r, %d, %d, %r, true)"
           % (hour, "true" if rain else "false", map_id, x, y, face))
    w.tick(0.4)
    c.eval(SPY)
    return w, c


def steps_heard(c):
    return [f for f, ch in (c.eval_py("return __AZ_SND") or []) if "Media\\Steps\\" in f]


def walk(w, c, dirs):
    """Steps along dirs a frame (1/60 s) at a time; per step, the frame its sound came on (of the step's frames)."""
    when = []
    for d in dirs:
        before = len(steps_heard(c))
        assert c.eval("return ns.Azero:TryStep(%r)" % d) == "moved", d
        frames, at = 0, None
        for _ in range(60):
            w.tick(1 / 60)
            frames += 1
            if at is None and len(steps_heard(c)) > before:
                at = frames
            if not c.eval("return ns.Azero.moving ~= nil"):
                break
        when.append((at, frames, len(steps_heard(c)) - before))
    return when


def set_of(f):
    return re.search(r"Steps\\([a-z_]+)_\d+\.ogg$", f).group(1)


@case
def the_steps_are_up_to_date():
    import gen_azeromon_steps as GS
    src = open(os.path.join(PACK, "StepsArt.lua"), encoding="utf-8").read()
    assert 'src = "%s"' % GS.digest() in src, "StepsArt.lua is stale: run generators\\gen_azeromon_steps.py"
    _, c = solo("Alice", tick=2)
    sets = c.eval_py("return ns.AzeroStepsArt.sets")
    want = {"%s_%d.ogg" % (k, i) for k, n in sets.items() for i in range(1, n + 1)}
    have = set(os.listdir(os.path.join(PACK, "Media", "Steps")))
    assert want == have, (sorted(want - have)[:5], sorted(have - want)[:5])
    for g in ("grass", "tall", "road", "sand", "dock", "shallows", "floor", "rug", "hall", "cave"):
        assert sets.get(g, 0) >= 4, g
    for g in ("grass", "tall", "road", "sand", "dock"):
        assert sets.get(g + "_wet", 0) >= 4, g
    assert sets.get("shallows_in", 0) >= 1


@case
def each_ground_comes_from_its_tile():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame()")
    got = c.eval_py("""local S, out = ns.AzeroSteps, {}
      local ids = {}
      for id, def in pairs(ns.AzeroMaps) do if type(def) == 'table' and def.rows then ids[#ids + 1] = id end end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local def = ns.AzeroMaps[id]
        local m = ns.Azero.Compile(id)
        local place = def.outdoor and (def.theme or 'elwynn') or (def.theme or 'indoor')
        for y = 0, m.h - 1 do
          local row = def.rows[y + 1]
          for x = 0, m.w - 1 do
            local ch = row:sub(x + 1, x + 1)
            local k = m.key(x, y)
            local what = (m.shallow and m.shallow[k]) and 'shallow' or ch
            local key = place .. ' ' .. what
            if not out[key] and (not m.solid[k] or what == 'shallow') then out[key] = { id, x, y, S.Ground(m, x, y) or false } end
          end
        end
      end
      return out""")
    want = {
        "elwynn .": "grass", 'elwynn "': "tall", "elwynn =": "road", "elwynn shallow": "shallows",
        "westfall .": "grass", "duskwood .": "grass", "jungle .": "grass", "redridge .": "grass",
        "redridge shallow": "shallows", "steppes .": "road", "arena .": "sand",
        "indoor f": "floor", "indoor r": "rug", "hall .": "hall",
        "mine .": "cave", "mine =": "cave", "blackrock .": "cave",
    }
    for key, ground in want.items():
        assert key in got, (key, sorted(got)[:40])
        assert got[key][3] == ground, (key, got[key], ground)
    docks = [v for k, v in got.items() if k.endswith(" D")]
    assert docks and all(v[3] == "dock" for v in docks), docks
    sands = [v for k, v in got.items() if k.endswith(" s")]
    assert sands and all(v[3] == "sand" for v in sands), sands
    nothing = c.eval("local m = ns.Azero.Compile('lakeshire') return ns.AzeroSteps.Ground(m, 28, 16)")
    assert nothing is None, nothing                       # deep water: no ground
    no_errors(w)


@case
def walking_plays_a_step_per_tile_as_the_foot_lands():
    w, c = play("town", 17, 3, face="down")                 # Goldshire's north road
    c.eval("ns.Azero:Data().steps = nil ns.Azero:Data().sfx = nil")
    when = walk(w, c, ["down", "down", "down"])
    for at, frames, n in when:
        assert n == 1, when                                  # exactly one each step
        assert at is not None and 0.2 * frames <= at <= 0.5 * frames, when   # as the foot lands, not at the start
    heard = c.eval_py("return __AZ_SND")
    steps = [(f, ch) for f, ch in heard if "Media\\Steps\\" in f]
    assert all(ch == "Master" for _, ch in steps), steps
    assert all(f.startswith("Interface\\AddOns\\DisasterZone_Azeromon\\Media\\Steps\\") for f, _ in steps), steps
    assert {set_of(f) for f, _ in steps} <= {"road", "grass", "tall"}, steps
    no_errors(w)


@case
def rain_wets_the_outdoor_grounds_and_not_the_inside():
    w, c = play("town", 17, 3, face="down", rain=True)
    walk(w, c, ["down", "down"])
    sets = {set_of(f) for f in steps_heard(c)}
    assert sets and all(s.endswith("_wet") for s in sets), sets
    r = c.eval_py("""local S = ns.AzeroSteps
      local out = {}
      for id, def in pairs(ns.AzeroMaps) do
        if type(def) == 'table' and def.rows and not def.outdoor and not def.theme then
          local m = ns.Azero.Compile(id)
          out.inside = S.SetFor(m, 2, 2, 2, 1, true) or out.inside
          if out.inside then break end
        end
      end
      local town = ns.Azero.Compile('town')
      out.road = S.SetFor(town, 17, 4, 17, 3, true)
      out.dry = S.SetFor(town, 17, 4, 17, 3, false)
      return out""")
    assert r["road"] == "road_wet" and r["dry"] == "road", r
    assert r.get("inside") in ("floor", "rug"), r              # indoors the rain doesn't reach
    no_errors(w)


@case
def stepping_into_the_shallows_splashes_once():
    w, c = play("lakeshire", 20, 16, face="right")
    walk(w, c, ["right", "down"])                             # into the shallows, then along them
    sets = [set_of(f) for f in steps_heard(c)]
    assert sets == ["shallows_in", "shallows"], sets
    walk(w, c, ["up", "left"])                                # along, then out onto the shore
    sets = [set_of(f) for f in steps_heard(c)]
    assert sets[2] == "shallows" and sets[3] in ("grass", "tall", "road"), sets
    no_errors(w)


@case
def a_mix_never_repeats_one_of_the_last_two():
    _, c = solo("Alice", tick=2)
    picks = c.eval_py("ns.AzeroSteps._Reset() local o = {} for i = 1, 300 do o[i] = ns.AzeroSteps.Pick('grass', 8) end return o")
    for i in range(2, len(picks)):
        assert picks[i] not in (picks[i - 1], picks[i - 2]), (i, picks[i - 2:i + 1])
    assert len(set(picks)) == 8, sorted(set(picks))           # and every mix comes round
    two = c.eval_py("local o = {} for i = 1, 20 do o[i] = ns.AzeroSteps.Pick('x', 2) end return o")
    assert all(a != b for a, b in zip(two, two[1:])), two


@case
def the_switches_silence_them():
    w, c = play("town", 17, 3, face="down")
    c.eval("ns.Azero:Data().steps = false")
    walk(w, c, ["down"])
    assert steps_heard(c) == []
    c.eval("ns.Azero:Data().steps = nil ns.Azero:Data().sfx = false")
    walk(w, c, ["down"])
    assert steps_heard(c) == []
    c.eval("ns.Azero:Data().sfx = nil ns.assetPack = 16")
    walk(w, c, ["down"])
    assert steps_heard(c) == []                               # an older art set: the files aren't there
    c.eval("ns.assetPack = 17")
    walk(w, c, ["up"])
    assert len(steps_heard(c)) == 1
    no_errors(w)


@case
def controls_has_a_footsteps_switch():
    w, c = play("town", 17, 3, face="down")
    src = open(os.path.join(PACK, "UI.lua"), encoding="utf-8").read()
    assert 'text = "Footsteps", right = onOff("steps")' in src
    no_errors(w)


if __name__ == "__main__":
    run_all()
