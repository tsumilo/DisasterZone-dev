"""Azeromon: every zone has every piece (the safety net for dev/docs/AZEROMON_NEW_ZONE.md).

A zone is a theme (Game.lua THEMES: its tiles and look) and the maps that use it. Most per-zone tables fall back
quietly when a key is missing (no mood, no rain, no ambience, Elwynn's battle, grass footsteps), so a forgotten
step shows nowhere but in game. These checks name what is missing instead. ALLOWED holds the deliberate gaps,
each with its reason; add to it only on purpose.

Covers, for every theme a map uses: Game.lua knows it; outdoors it has a mood, a water glint, critters and an
ambience bed; it has a footstep ground; the ground baker and the battle painter know it. For every map: it is
baked, its music exists, an outdoor map has a layered battle scene and a world map place, its encounters name real
beasts, every tile you can stand on has a footstep, fishable water has fish, and its roads lead back the way they
came. A made-up zone with none of its pieces is caught by every one of the checks.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_zones.py [-k name]
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

GEN = os.path.join(DEV, "generators")

# Deliberate gaps: check -> { theme, map id or "map.dir": reason }. Each key must name a real theme or map.
ALLOWED = {
    "moods": {}, "glint": {}, "critters": {}, "bed": {}, "music": {}, "battle_scene": {}, "fish": {},
    "edges_back": {},
}

# everything the checks need, read from the game once
DUMP = r"""
local G, D, S = ns.Azero, ns.AzeroData, ns.AzeroSound
local out = { themes = {}, maps = {}, stepsTheme = ns.AzeroSteps.THEME_GROUND, stepsSets = ns.AzeroStepsArt.sets,
              tracks = {}, beds = {}, mapBed = S.MAP_BED, battleArt = ns.AzeroBattleArt.scenes,
              scenes = {}, ui = {}, species = {} }
for k in pairs(G.THEMES) do out.themes[k] = true end
for k in pairs(S.TRACKS) do out.tracks[k] = true end
for k in pairs(S.BEDS) do out.beds[k] = true end
for k, sc in pairs(ns.AzeroBattleScenes.scenes) do out.scenes[k] = sc.flat and "flat" or "layers" end
for k in pairs(D.species) do out.species[k] = true end
for name, t in pairs(ns.AzeroUI._ZoneTables()) do out.ui[name] = {} for k in pairs(t) do out.ui[name][k] = true end end
for id, def in pairs(ns.AzeroMaps) do
  if type(def) == "table" and def.rows then
    local m = G.Compile(id)
    local e = { theme = def.theme or false, outdoor = def.outdoor or false, music = def.music or false,
                dynamic = def.dynamic or false, ground = ns.AzeroGround[id] ~= nil, edges = {}, enc = {},
                water = 0, silent = {}, place = ns.AzeroWorld.placeOfMap[id] ~= nil,
                fish = ns.AzeroFish.WaterOf(m) ~= nil }
    for dir, ed in pairs(def.edges or {}) do e.edges[dir] = ed.map end
    for _, list in ipairs({ def.encounters or {}, def.coastEncounters or {} }) do
      for _, en in ipairs(list) do e.enc[#e.enc + 1] = en[1] or en.sp end
    end
    for y = 0, m.h - 1 do
      for x = 0, m.w - 1 do
        local k = m.key(x, y)
        local shallow = m.shallow and m.shallow[k]
        if m.water[k] and not shallow then e.water = e.water + 1 end
        if (not m.solid[k] or shallow) and not ns.AzeroSteps.Ground(m, x, y) and #e.silent < 5 then
          e.silent[#e.silent + 1] = x .. "," .. y .. " " .. tostring(m.base[k])
        end
      end
    end
    out.maps[id] = e
  end
end
return out
"""

# a made-up zone with none of its pieces (the checks must name every one)
FAKE = r"""
ns.Azero.THEMES.testzone = { grass1 = "grass1", grass2 = "grass2", tall = "tall_", path = "path_", tree = "tree" }
ns.AzeroMaps.testzone1 = { name = "Test Zone", theme = "testzone", outdoor = true, music = "nosuchtrack",
  rows = { "......", "..ww..", "......" }, encounters = { { "nosuchbeast", 2, 3, 10 } },
  edges = { east = { map = "town", dy = 0 } } }
"""


def dump(fake=False):
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame()")
    if fake:
        c.eval(FAKE)
    return w, c, c.eval_py(DUMP)


def allowed(check, key):
    return key in ALLOWED.get(check, {})


def map_themes(d):
    """theme -> its maps (a map with no theme is Elwynn's)"""
    out = {}
    for mid, e in d["maps"].items():
        out.setdefault(e["theme"] or "elwynn", []).append(mid)
    return out


def outdoor_themes(d):
    return {e["theme"] or "elwynn" for e in d["maps"].values() if e["outdoor"]}


def generator_names(path, name):
    """The strings in a list / tuple assigned to `name` in a generator's source."""
    src = open(os.path.join(GEN, path), encoding="utf-8").read()
    m = re.search(r"\b%s\s*=\s*[\[(]([^\])]*)[\])]" % re.escape(name), src)
    assert m, (path, name)
    return set(re.findall(r'"([a-z_]+)"', m.group(1)))


def ground_themes():
    """gen_azeromon_ground.py's THEMES keys and the lava ones (read as text: importing it boots a client)."""
    src = open(os.path.join(GEN, "gen_azeromon_ground.py"), encoding="utf-8").read()
    block = src[src.index("\nTHEMES = {"):]
    block = block[:block.index("\n}\n")]
    keys = re.findall(r'^    "([a-z_]+)": dict\(', block, re.M)
    lava = set()
    for i, k in enumerate(keys):
        start = block.index('"%s": dict(' % k)
        end = block.index('"%s": dict(' % keys[i + 1]) if i + 1 < len(keys) else len(block)
        if 'water="lava"' in block[start:end]:
            lava.add(k)
    return set(keys), lava


# ------------------------------------------------------------------------------------------------- the checks

def theme_gaps(d):
    used, out = map_themes(d), []
    for theme in sorted(used):
        if theme not in d["themes"]:
            out.append("Game.lua THEMES has no %r (maps %s)" % (theme, sorted(used[theme])))
    for theme in sorted(outdoor_themes(d)):
        for table, what in (("moods", "UI.lua Amb.MOODS (tint, motes, rain = true for weather)"),
                            ("glint", "UI.lua Amb.GLINT"), ("critters", "UI.lua Amb.CRITTERS")):
            if theme not in d["ui"][table] and not allowed(table, theme):
                out.append("%s has no %r" % (what, theme))
        maps = [m for m in used[theme] if d["maps"][m]["outdoor"]]
        if theme not in d["beds"] and not all(m in d["mapBed"] for m in maps) and not allowed("bed", theme):
            out.append("Sound.lua S.BEDS has no %r (an outdoor zone's day / night ambience)" % theme)
    for theme in sorted(used):
        g = d["stepsTheme"].get(theme)
        if g is None:
            out.append("Steps.lua S.THEME_GROUND has no %r (what its floor sounds of)" % theme)
        elif g not in d["stepsSets"]:
            out.append("Steps.lua S.THEME_GROUND[%r] = %r is no StepsArt ground" % (theme, g))
    return out


def baker_gaps(d):
    used, out = map_themes(d), []
    baked = generator_names("gen_azeromon_ground.py", "GROUND_THEMES")
    painted, _ = ground_themes()
    for theme in sorted(t for t in used if t != "hall"):
        if theme not in baked:
            out.append("gen_azeromon_ground.py GROUND_THEMES has no %r: its maps are never baked" % theme)
        if theme not in painted:
            out.append("gen_azeromon_ground.py THEMES has no %r (its palette, water, decor)" % theme)
    import azeromon_battle as AB
    for theme in sorted(used):
        if theme not in AB.SCENE_OF:
            out.append("azeromon_battle.py SCENE_OF has no %r (its battles fall back to Elwynn's)" % theme)
    return out


def map_gaps(d):
    out = []
    for mid, e in sorted(d["maps"].items()):
        if e["dynamic"]:
            continue                                   # (the Guild Hall bakes on its own)
        if not e["ground"]:
            out.append("%s has no baked ground: run generators\\gen_azeromon_ground.py "
                       "(its theme in GROUND_THEMES)" % mid)
        if (not e["music"] or e["music"] not in d["tracks"]) and not allowed("music", mid):
            out.append("%s: def.music %r is not in Sound.lua S.TRACKS" % (mid, e["music"]))
        theme = e["theme"] or "elwynn"
        scene = d["battleArt"].get(mid) or d["battleArt"].get(theme)
        if e["outdoor"] and scene not in d["scenes"] and not allowed("battle_scene", mid):
            out.append("%s: no layered battle scene (Ground.lua AzeroBattleArt.scenes -> %r; azeromon_battle.py "
                       "SCENES / SCENE_OF, then gen_azeromon_battle.py)" % (mid, scene))
        if not e["place"]:
            out.append("%s is in no world map place (WorldMap.lua W.PLACES)" % mid)
    return out


def encounter_gaps(d):
    return ["%s: encounter %r is no species (Data.lua D.species)" % (mid, sp)
            for mid, e in sorted(d["maps"].items()) for sp in e["enc"] if sp not in d["species"]]


def step_gaps(d):
    return ["%s: no footstep ground at %s (Steps.lua S.THEME_GROUND / PREFIX)" % (mid, ", ".join(e["silent"]))
            for mid, e in sorted(d["maps"].items()) if e["silent"]]


def fish_gaps(d):
    _, lava = ground_themes()
    out = []
    for mid, e in sorted(d["maps"].items()):
        theme = e["theme"] or "elwynn"
        if e["outdoor"] and e["water"] > 0 and theme not in lava and not e["fish"] and not allowed("fish", mid):
            out.append("%s: water but no Fishing.lua D.fishWaters[%r]" % (mid, theme))
    return out


def edge_gaps(d):
    opp = {"north": "south", "south": "north", "east": "west", "west": "east"}
    out = []
    for mid, e in sorted(d["maps"].items()):
        for dir_, to in sorted(e["edges"].items()):
            back = d["maps"].get(to, {}).get("edges", {}).get(opp[dir_])
            if back != mid and not allowed("edges_back", "%s.%s" % (mid, dir_)):
                out.append("%s's %s road goes to %s, but %s's %s road goes to %r" % (mid, dir_, to, to, opp[dir_], back))
    return out


# ------------------------------------------------------------------------------------------------- the cases

@case
def every_theme_has_its_look_sound_and_footsteps():
    w, c, d = dump()
    gaps = theme_gaps(d)
    assert not gaps, "\n".join(gaps)
    no_errors(w)


@case
def the_bakers_know_every_theme():
    w, c, d = dump()
    gaps = baker_gaps(d)
    assert not gaps, "\n".join(gaps)
    no_errors(w)


@case
def every_map_is_baked_scored_placed_and_has_a_battle():
    w, c, d = dump()
    gaps = map_gaps(d)
    assert not gaps, "\n".join(gaps)
    no_errors(w)


@case
def encounters_name_real_beasts_and_every_tile_has_a_footstep():
    w, c, d = dump()
    gaps = encounter_gaps(d) + step_gaps(d)
    assert not gaps, "\n".join(gaps)
    no_errors(w)


@case
def fishable_water_has_fish_and_roads_lead_back():
    w, c, d = dump()
    gaps = fish_gaps(d) + edge_gaps(d)
    assert not gaps, "\n".join(gaps)
    no_errors(w)


@case
def a_zone_without_its_pieces_is_caught():
    w, c, d = dump(fake=True)
    found = "\n".join(theme_gaps(d) + baker_gaps(d) + map_gaps(d) + encounter_gaps(d) + fish_gaps(d) + edge_gaps(d))
    for piece in ("for weather) has no 'testzone'", "Amb.GLINT has no 'testzone'", "Amb.CRITTERS has no 'testzone'",
                  "S.BEDS has no 'testzone'", "S.THEME_GROUND has no 'testzone'",
                  "GROUND_THEMES has no 'testzone'", "THEMES has no 'testzone' (its palette",
                  "SCENE_OF has no 'testzone'", "testzone1 has no baked ground", "testzone1: def.music 'nosuchtrack'",
                  "testzone1: no layered battle scene", "testzone1 is in no world map place",
                  "testzone1: encounter 'nosuchbeast'", "testzone1: water but no Fishing.lua",
                  "testzone1's east road goes to town"):
        assert piece in found, (piece, found)
    no_errors(w)


@case
def the_allowed_gaps_name_real_themes_and_maps():
    w, c, d = dump()
    bad = []
    for check, keys in ALLOWED.items():
        for key in keys:
            if key not in d["themes"] and key.split(".")[0] not in d["maps"]:
                bad.append("ALLOWED[%r] has %r: no such theme or map" % (check, key))
    assert not bad, "\n".join(bad)
    no_errors(w)


if __name__ == "__main__":
    run_all()
