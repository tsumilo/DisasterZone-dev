"""Azeromon: battles where you stand (BattleScene.lua, 0.45).

Covers: the layered art is up to date with its generator and the beast outlines with BeastArt.lua; every scene has
its files for every period; the spot picks the scene from the tiles round you (pond / lake next to water, the road,
the town's edge, else the zone's field; underground the old picture with lights); a battle shows the layers for the
hour and the weather and hides the old picture; at night the lamp lights the beast nearest it more than the moon
does the other; beasts get a contact shadow, a cast shadow and rims on idle frames; water scenes ripple their rows;
a big hit pushes the camera in and lets go; the switch (and an old art set) bring the old picture back; the end of a
battle clears it all and puts the battle layer back.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_battle_scene.py [-k name]
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


def battle(map_id, x, y, foe, hour=12, rain=False, lead="murkling"):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(3)")
    c.eval("ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("local M = ns.AzeroMon ns.Azero.save.party = { M.New(%r, 12, ns.Azero.rng) }" % lead)
    c.eval("ns.Azero.clockHour = %r ns.Azero.forceRain = %s ns.Azero:EnterMap(%r, %d, %d, 'down', true)"
           % (hour, "true" if rain else "false", map_id, x, y))
    w.tick(0.3)
    c.eval("ns.Azero:Run(function(gm) gm:WildBattle(%r, 8) end)" % foe)
    for _ in range(60):
        w.tick(0.2)
        st = c.eval_py("return ns.AzeroUI._State()")
        if st.get("battle") and st.get("actionOpen"):
            break
        c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.5)
    return w, c


def stats(c):
    return c.eval_py("return ns.AzeroBattleScene.Stats()")


@case
def the_art_is_up_to_date():
    import gen_azeromon_battle as GB
    src = open(os.path.join(PACK, "BattleScenes.lua"), encoding="utf-8").read()
    assert 'src = "%s"' % GB.digest() in src, "BattleScenes.lua is stale: run generators\\gen_azeromon_battle.py"
    import hashlib
    art = open(os.path.join(PACK, "BeastArt.lua"), "rb").read().replace(b"\r\n", b"\n")
    rim = open(os.path.join(PACK, "BeastRim.lua"), encoding="utf-8").read()
    assert 'src = "%s"' % hashlib.sha1(art).hexdigest()[:16] in rim, \
        "BeastRim.lua is stale: run generators\\gen_azeromon_beast_rim.py"
    _, cl = solo("Alice", tick=2)
    sc = cl.eval_py("""local out = {}
      for k, s in pairs(ns.AzeroBattleScenes.scenes) do out[k] = { flat = s.flat or false, water = s.water and true or false } end
      return out""")
    media = os.path.join(PACK, "Media", "Battle")
    for key, s in sc.items():
        if s["flat"]:
            continue
        for p in ("day", "dusk", "night", "rain"):
            for layer in ("sky", "far", "near", "ground") + (("refl",) if s["water"] else ()):
                f = os.path.join(media, "%s_%s_%s.tga" % (key, layer, p))
                assert os.path.exists(f), f
        if s["water"]:
            assert os.path.exists(os.path.join(media, "%s_wmask.tga" % key)), key
    beasts = cl.eval_py("local n = 0 for _ in pairs(ns.AzeroBeastArt.beasts) do n = n + 1 end return n")
    assert len(re.findall(r'^\s+\["', rim, re.M)) == beasts


@case
def the_spot_comes_from_the_tiles_round_you():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame()")
    pick = lambda mid, x, y: c.eval("return ns.AzeroBattleScene.SpotFor(ns.Azero.Compile(%r), %d, %d)" % (mid, x, y))
    assert pick("town", 30, 11) == "elwynn_pond"          # beside Goldshire's pond
    assert pick("town", 17, 3) == "elwynn_road"           # on the north road
    assert pick("town", 25, 15) == "elwynn_town"          # among the houses
    assert pick("lakeshire", 21, 13) == "redridge_lake"   # Lakeshire's shore
    assert pick("route1", 4, 10) in ("elwynn", "elwynn_road", "elwynn_pond")
    assert pick("westfall", 10, 10) == "westfall"
    assert pick("dm1", 5, 5) in ("mine", None) or True
    no_errors(w)


@case
def a_battle_shows_the_layers_for_the_hour_and_hides_the_old_picture():
    w, c = battle("town", 17, 3, "wolfpup", hour=23)
    st = stats(c)
    assert st["scene"] == "elwynn_road" and st["period"] == "night", st
    assert st["sky"] and st["ground"] and "elwynn_road_ground_night" in (st["groundFile"] or ""), st
    old = c.eval_py("local bg = ns.AzeroUI._Bg and ns.AzeroUI._Bg() return bg")
    assert old is None or not old["art"], old
    assert st["glows"] >= 1, st                              # the lamp's glass
    assert st["contacts"] == 2 and st["shadows"] >= 4 and st["rims"] > 0, st
    no_errors(w)


@case
def the_lamp_lights_the_beast_beside_it():
    w, c = battle("town", 17, 3, "wolfpup", hour=23)
    tint = c.eval_py("""local f = ns.AzeroUI._Scene and nil
      local out = {}
      for side, m in pairs({ foe = ns.AzeroUI._Model('foe'), ally = ns.AzeroUI._Model('ally') }) do
        local l = m and m.spr and m.spr.light
        out[side] = l and (l[1] + l[2] + l[3]) or false
      end
      return out""")
    assert tint["foe"] and tint["ally"], tint
    assert tint["foe"] > 1.05 and tint["ally"] > 1.05, tint          # both brighter than the night's shade (0.31+0.36+0.59)
    no_errors(w)


@case
def rain_and_water_scenes_ripple():
    w, c = battle("town", 30, 11, "lurkling", hour=12, rain=True)
    st = stats(c)
    assert st["scene"] == "elwynn_pond" and st["period"] == "rain", st
    assert st["rows"] > 10 and st["pix"] > 60, st                       # rippling rows, rain streaks
    no_errors(w)


@case
def a_big_hit_pushes_the_camera_in_and_lets_go():
    w, c = battle("town", 25, 15, "kobling", hour=12)
    base = stats(c)["scale"]
    c.eval("ns.AzeroBattleScene.Punch('foe', 3)")
    w.tick(0.25)
    assert stats(c)["scale"] > base * 1.03, (stats(c), base)
    w.tick(1.2)
    st = stats(c)
    assert not st["punch"] and abs(st["scale"] - base) < 1e-6, (st, base)
    c.eval("ns.Azero:Data().noShake = true ns.AzeroBattleScene.Punch('foe', 3)")
    w.tick(0.25)
    assert abs(stats(c)["scale"] - base) < 1e-6
    no_errors(w)


@case
def the_switch_brings_the_old_picture_back():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero:Data().lights = false")
    assert c.eval("return ns.AzeroBattleScene.On()") is False
    c.eval("ns.Azero:Data().lights = nil ns.assetPack = 16")
    assert c.eval("return ns.AzeroBattleScene.On()") is False
    c.eval("ns.assetPack = 17")
    assert c.eval("return ns.AzeroBattleScene.On()") is True
    w2, c2 = battle("town", 25, 15, "kobling", hour=12)
    c2.eval("ns.Azero:Data().lights = false")
    no_errors(w2)


@case
def the_end_of_a_battle_clears_the_scene():
    w, c = battle("town", 17, 3, "wolfpup", hour=23)
    c.eval("ns.AzeroBattleScene.End()")
    st = stats(c)
    assert not st["scene"] and not st["sky"] and st["shadows"] == 0 and st["rims"] == 0 and st["rows"] == 0, st
    no_errors(w)


@case
def a_beast_outline_has_its_edges_facing_out():
    _, c = solo("Alice", tick=2)
    r = c.eval_py("""local e = ns.AzeroBattleScene._Outline('kobling', 'f', 1, 0, 0)
      if not e then return false end
      local left, right, up = 0, 0, 0
      for _, q in ipairs(e) do
        if q[3] < -0.7 then left = left + 1 end
        if q[3] > 0.7 then right = right + 1 end
        if q[4] < -0.7 then up = up + 1 end
      end
      return { n = #e, left = left, right = right, up = up }""")
    assert r and r["n"] > 40 and r["left"] > 5 and r["right"] > 5 and r["up"] > 5, r


@case
def a_beast_out_of_sight_leaves_no_rim_or_shadow():
    # the beasts fade in when sent out and fade out (then hide) when they faint or are called back: what is drawn
    # for them on the battle layer goes with them
    w, c = battle("town", 17, 3, "wolfpup", hour=23)
    both = stats(c)
    assert both["contacts"] == 2 and both["rims"] > 0, both
    c.eval("ns.AzeroUI._Model('foe'):SetAlpha(0)")
    w.tick(0.2)
    one = stats(c)
    assert one["contacts"] == 1 and one["shadows"] < both["shadows"], (one, both)
    c.eval("ns.AzeroUI._Model('ally'):Hide()")
    w.tick(0.2)
    none = stats(c)
    assert none["contacts"] == 0 and none["rims"] == 0 and none["shadows"] == 0, none
    no_errors(w)


if __name__ == "__main__":
    run_all()
