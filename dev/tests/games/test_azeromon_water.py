"""Azeromon: water that reflects (Water.lua, 0.46).

Covers: the reflections are up to date with their generator and with the baked grounds they were made from, and
every listed file is there at its size; the shallows are water at a shore, walkable, the deep water still not; a
player wading shows only above the water line (no blob) and gets their legs back on land; near Lakeshire's lake
the reflection's rows show, kept to the water by its mask, and none on a map without one or with the switch off;
someone at the edge of the dock is mirrored below it, someone inland is not; rain brings rings and puddles; you can
still fish from the shallows.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_water.py [-k name]
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

from PIL import Image  # noqa: E402

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

PACK = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone_Azeromon")


def play(map_id, x, y, hour=12, rain=False, face="left"):
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
    return w, c


def water(c):
    return c.eval_py("return ns.AzeroWater.Stats()")


@case
def the_reflections_are_up_to_date():
    import gen_azeromon_water as GW
    src = open(os.path.join(PACK, "WaterArt.lua"), encoding="utf-8").read()
    assert 'src = "%s"' % GW.digest() in src, "WaterArt.lua is stale: run generators\\gen_azeromon_water.py"
    _, c = solo("Alice", tick=2)
    art = c.eval_py("return ns.AzeroWaterArt")
    ground = c.eval_py("local out = {} for k, g in pairs(ns.AzeroGround) do out[k] = g.v end return out")
    assert "lakeshire" in art["maps"] and "town" in art["maps"], sorted(art["maps"])
    for mid, e in art["maps"].items():
        assert e["v"] == ground.get(mid), "%s was re-baked: run generators\\gen_azeromon_water.py" % mid
        r = Image.open(os.path.join(PACK, "Media", "Water", "%s_r.tga" % mid))
        assert r.size == (e["refl"][4], e["refl"][5]), (mid, r.size, e["refl"])
        m = Image.open(os.path.join(PACK, "Media", "Water", "%s_m.tga" % mid))
        assert m.size == (e["mask"][0], e["mask"][1]), (mid, m.size)


@case
def the_shallows_are_water_at_a_shore_and_walkable():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame()")
    bad = c.eval_py("""local bad = {}
      for id, def in pairs(ns.AzeroMaps) do
        if type(def) == 'table' and def.shallows then
          local m = ns.Azero.Compile(id)
          for _, p in ipairs(def.shallows) do
            local k = m.key(p[1], p[2])
            local land = false
            for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
              local kk = m.key(p[1] + d[1], p[2] + d[2])
              if not m.water[kk] and not m.solid[kk] then land = true end
            end
            if not (m.water[k] and m.shallow[k] and not m.solid[k] and land) then bad[#bad + 1] = id .. '@' .. p[1] .. ',' .. p[2] end
          end
        end
      end
      return bad""")
    assert bad == [], bad
    deep = c.eval("local m = ns.Azero.Compile('lakeshire') return m.solid[m.key(25, 16)] == true")
    assert deep, "deep water stays out of reach"
    no_errors(w)


@case
def wading_hides_the_legs_and_land_brings_them_back():
    w, c = play("lakeshire", 21, 16)
    st = c.eval_py("""local L = ns.AzeroUI._Light()
      return { blob = L.playerBlob, h = ns.AzeroUI._PlayerHeight and ns.AzeroUI._PlayerHeight() or false }""")
    assert not st["blob"], st
    assert st["h"] and abs(st["h"] - 48 * 11 / 16) < 0.01, st
    c.eval("ns.Azero:EnterMap('lakeshire', 19, 16, 'left', true)")
    w.tick(0.2)
    assert abs(c.eval("return ns.AzeroUI._PlayerHeight()") - 48) < 0.01
    no_errors(w)


@case
def the_lake_shows_its_reflection_and_a_dry_map_none():
    w, c = play("lakeshire", 25, 12)
    st = water(c)
    assert st["on"] and st["rows"] > 40 and st["mask"], st
    assert st["people"] >= 1, st                             # the player at the edge of the dock
    c.eval("ns.Azero:EnterMap('lakeshire', 12, 9, 'left', true)")
    w.tick(0.2)
    assert water(c)["people"] == 0
    c.eval("ns.Azero:EnterMap('route1', 11, 20, 'left', true)")
    w.tick(0.2)
    st = water(c)
    assert not st["on"] and st["rows"] == 0, st
    c.eval("ns.Azero:EnterMap('lakeshire', 25, 12, 'left', true) ns.Azero:Data().lights = false")
    w.tick(0.2)
    st = water(c)
    assert not st["on"] and st["rows"] == 0 and st["people"] == 0, st
    no_errors(w)


@case
def rain_brings_rings_and_puddles():
    w, c = play("lakeshire", 24, 12, rain=True)
    dry_w, dry = play("lakeshire", 24, 12, rain=False)
    wet_pix = c.eval_py("return ns.AzeroUI._Ambient()")["pix"]
    dry_pix = dry.eval_py("return ns.AzeroUI._Ambient()")["pix"]
    assert wet_pix > dry_pix + 30, (wet_pix, dry_pix)
    no_errors(w)
    no_errors(dry_w)


@case
def you_can_fish_from_the_shallows():
    w, c = play("lakeshire", 21, 16, face="right")
    hint = c.eval("return ns.AzeroUI._Hint()")
    assert hint and "Fish" in hint, hint
    no_errors(w)


if __name__ == "__main__":
    run_all()
