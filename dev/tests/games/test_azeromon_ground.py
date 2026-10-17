"""Azeromon world art: the baked ground (gen_azeromon_ground.py), the redrawn props and the shadows under people.

Covers: every chunk listed in Ground.lua exists as a power-of-two TGA of the listed size; the pictures are up to date
with the maps (a changed map, atlas or baker without a re-bake fails here: run generators\\gen_azeromon_ground.py);
the game shows the chunks instead of the base tiles on a baked map, darker forest floor outside its edge, and plain
base tiles on a map without one; people stand on a shadow.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_ground.py [-k name]
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

from _common import case, run_all, solo  # noqa: E402
from _azero_bot import BOT  # noqa: E402

ADDON = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone")
GROUND_LUA = os.path.join(ADDON, "..", "DisasterZone_Azeromon", "Ground.lua")


_GROUND = None


def ground():
    """Ground.lua as the game loads it"""
    global _GROUND
    if _GROUND is None:
        _, c = solo("Alice", tick=2)
        _GROUND = c.eval_py("return ns.AzeroGround")
    return _GROUND


def entries():
    return {mid: (g["v"], [tuple(c) for c in g["chunks"]]) for mid, g in ground().items()}


def waters():
    return {mid: [tuple(c) for c in (g.get("water") or [])] for mid, g in ground().items()}


@case
def every_chunk_is_a_power_of_two_tga_of_the_listed_size():
    e = entries()
    assert e, "Ground.lua lists no maps"
    for mid, (v, chunks) in e.items():
        for x, y, w, h, tw, th in chunks:
            f = os.path.join(ADDON, "..", "DisasterZone_Azeromon", "Media", "Ground", "%s_%d_%d.tga" % (mid, x // 256, y // 256))
            assert os.path.exists(f), f
            size = Image.open(f).size
            assert size == (tw, th), (f, size, tw, th)
            assert tw & (tw - 1) == 0 and th & (th - 1) == 0 and tw <= 256 and th <= 256, (f, tw, th)
            assert 0 < w <= tw and 0 < h <= th and x % 256 == 0 and y % 256 == 0, (f, x, y, w, h)


@case
def every_pond_has_a_moving_water_strip_of_twelve_frames():
    w = waters()
    assert w.get("town"), "Goldshire's pond has no moving water"
    for mid, ponds in w.items():
        for i, (x, y, pw, ph, cols, rows, tw, th) in enumerate(ponds):
            f = os.path.join(ADDON, "..", "DisasterZone_Azeromon", "Media", "Ground", "%s_w%d.tga" % (mid, i + 1))
            im = Image.open(f).convert("RGBA")
            assert im.size == (tw, th) and im.getextrema()[3][0] == 0, (f, im.size)     # transparent between glints
            assert cols * rows >= 12 and cols * pw <= tw and rows * ph <= th, (f, cols, rows)
    assert Image.open(os.path.join(ADDON, "..", "DisasterZone_Azeromon", "Media", "Ground", "clouds.tga")).size == (256, 256)
    # every baked picture is a TGA (this client draws our palette BLPs as its green missing-texture square)
    left = [f for f in os.listdir(os.path.join(ADDON, "..", "DisasterZone_Azeromon", "Media", "Ground")) if not f.endswith(".tga")]
    assert not left, left


@case
def the_pictures_are_up_to_date_with_the_maps():
    import gen_azeromon_ground as gg
    maps = gg.load_maps()
    src = gg._src_digest()
    e = entries()
    e.pop("hideout", None)                      # the Guild Hall: gen_azeromon_hall.py (test_azeromon_hideout checks it)
    want = gg.selected(maps)
    assert sorted(e) == sorted(want), ("baked maps differ - run generators\\gen_azeromon_ground.py", sorted(e), want)
    for mid in want:
        m = maps[mid]
        assert e[mid][0] == gg.inputs_hash(m, src), "%s changed since its ground was baked - run generators\\gen_azeromon_ground.py" % mid
        W = max(x + w for x, y, w, h, tw, th in e[mid][1])
        H = max(y + h for x, y, w, h, tw, th in e[mid][1])
        g = ground()[mid]
        assert (W, H) == ((m["w"] + 2 * g["mx"]) * 16, (m["h"] + 2 * g["my"]) * 16), (mid, W, H)


def play(map_id, x, y):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(3)")
    c.eval("ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("ns.Azero:EnterMap(%r, %d, %d, 'down', true)" % (map_id, x, y))
    w.tick(0.2)
    return w, c


@case
def a_baked_map_shows_its_ground_instead_of_base_tiles():
    w, c = play("town", 10, 9)
    shown = c.eval_py("return ns.AzeroUI._Ground()")
    assert shown and all("Ground\\town_" in f for f in shown), shown
    assert len(shown) <= 4, shown
    bases = c.eval_py("return ns.AzeroUI._BaseTiles()")
    assert not any(b for b in bases if b), bases            # the whole view is inside the map: no base tiles
    # at the map's corner the cells outside are forest on the darker floor
    c.eval("ns.Azero:EnterMap('town', 1, 1, 'down', true)")
    w.tick(0.2)
    bases = [b for b in c.eval_py("return ns.AzeroUI._BaseTiles()") if b]
    assert not bases, set(bases)                            # past the edge the baked margin is the ground
    shown = c.eval_py("return ns.AzeroUI._Ground()")
    assert any(f.endswith("town_0_0") for f in shown), shown


@case
def walking_moves_the_ground_with_the_camera():
    w, c = play("route1", 11, 20)
    before = c.eval_py("return ns.AzeroUI._Ground()")
    c.eval("ns.Azero:EnterMap('route1', 11, 2, 'down', true)")
    w.tick(0.2)
    after = c.eval_py("return ns.AzeroUI._Ground()")
    assert before != after and any(f.endswith("route1_0_0") for f in after), (before, after)


@case
def a_map_without_a_baked_ground_keeps_its_tiles():
    w, c = play("town", 10, 9)
    c.eval("ns.AzeroGround.town = nil ns.Azero:EnterMap('town', 10, 9, 'down', true)")
    w.tick(0.2)
    assert c.eval_py("return ns.AzeroUI._Ground()") in ({}, [], None)
    bases = [b for b in c.eval_py("return ns.AzeroUI._BaseTiles()") if b]
    assert any(b.startswith("grass") for b in bases), set(bases)


@case
def people_stand_on_a_shadow():
    w, c = play("town", 10, 9)
    # with light on people (Light.lua, 0.44) a contact shadow at the feet, with it switched off the old blob
    assert c.eval_py("return ns.AzeroUI._Light()")["contacts"] >= 1
    c.eval("ns.Azero:Data().lights = false")
    w.tick(0.2)
    assert c.eval("return ns.AzeroUI._ShadowsShown()") >= 1


@case
def the_pond_moves_and_life_goes_on_around_it():
    w, c = play("town", 27, 13)
    st = lambda: c.eval_py("return ns.AzeroUI._Ambient()")
    a = st()
    assert a["water"] and a["water"][0].endswith("town_w1"), a
    assert a["pix"] > 10, a                                   # butterflies, smoke from the three chimneys
    w.tick(0.6)
    b = st()
    assert a["frame"] != b["frame"], (a, b)
    c.eval("ns.Azero.clockHour = 12")
    w.tick(0.1)
    assert st()["clouds"] > 0.1
    c.eval("ns.Azero.clockHour = 23")
    w.tick(0.1)
    assert st()["clouds"] == 0                               # no cloud shadows at night


@case
def a_map_without_a_baked_ground_has_no_ambient():
    w, c = play("town", 10, 9)
    c.eval("ns.AzeroGround.town = nil ns.Azero:EnterMap('town', 10, 9, 'down', true)")
    w.tick(0.2)
    a = c.eval_py("return ns.AzeroUI._Ambient()")
    assert not a["water"] and a["pix"] == 0 and a["clouds"] == 0, a


@case
def a_road_at_the_edge_carries_on_into_the_forest():
    w, c = play("town", 17, 0)                      # Goldshire's north road (columns 17 and 18) leaves the map
    over = lambda i, j: c.eval("return ns.AzeroUI._OverAt(%d, %d)" % (i, j))
    # view cell i shows column fx - floor(HX) - 1 + i = i + 10 (HX = 6.5): the road (17, 18) is cells 7 and 8; rows 1-4
    # are past the edge
    for j in (1, 2, 3, 4):
        assert not over(7, j) and not over(8, j), (j, over(7, j), over(8, j))
        assert over(6, j) == "tree" and over(9, j) == "tree", (j, over(6, j), over(9, j))


def tall_spot(c, map_id):
    return c.eval_py("""local m = ns.Azero.Compile(%r)
      for y = 1, m.h - 2 do for x = 1, m.w - 2 do
        local k = m.key(x, y)
        if m.tall[k] and m.tall[m.key(x - 1, y)] and m.tall[m.key(x + 1, y)] then return { x, y } end
      end end""" % map_id)


@case
def legs_are_hidden_in_the_grass_walking_or_standing():
    w, c = play("route1", 11, 20)
    x, y = tall_spot(c, "route1")
    c.eval("ns.Azero:EnterMap('route1', %d, %d, 'down', true)" % (x, y))
    w.tick(0.1)
    assert c.eval_py("return ns.AzeroUI._Ambient()")["legs"]
    c.eval("ns.Azero.moving = { t = 0.05, dur = 0.25, fromX = %d, fromY = %d }" % (x - 1, y))
    w.tick(0.02)
    assert c.eval_py("return ns.AzeroUI._Ambient()")["legs"]          # mid-step too
    c.eval("ns.Azero.moving = nil")
    c.eval("ns.Azero:EnterMap('town', 10, 9, 'down', true)")         # no meadow here: nothing over the legs
    w.tick(0.1)
    assert not c.eval_py("return ns.AzeroUI._Ambient()")["legs"]


@case
def gusts_roll_through_the_meadows():
    w, c = play("route1", 11, 20)
    x, y = tall_spot(c, "route1")
    c.eval("ns.Azero:EnterMap('route1', %d, %d, 'down', true)" % (x, y))
    seen = 0
    for _ in range(40):
        w.tick(0.1)
        seen = max(seen, c.eval_py("return ns.AzeroUI._Ambient()")["wind"])
    assert seen >= 2, seen


@case
def night_has_pools_of_light_instead_of_the_flat_tint():
    w, c = play("town", 12, 11)
    st = lambda: c.eval_py("return ns.AzeroUI._Ambient()")
    c.eval("ns.Azero.clockHour = 23")
    w.tick(0.1)
    a = st()
    assert a["dark"] >= 1 and a["glows"] >= 2 and not a["sky"], a
    c.eval("ns.Azero.clockHour = 12")
    w.tick(0.1)
    a = st()
    assert a["dark"] == 0 and a["glows"] == 0 and a["mood"], a


@case
def rooms_have_sunlight_by_day_and_a_fire_that_moves():
    w, c = play("home", 4, 5)
    st = lambda: c.eval_py("return ns.AzeroUI._Ambient()")
    c.eval("ns.Azero.clockHour = 12")
    w.tick(0.1)
    a = st()
    assert a["sun"] and a["anims"] >= 1, a                                    # sunlight, the hearth's flames
    shown = c.eval_py("return ns.AzeroUI._Ground()")
    assert shown and all("home_" in f and "_e_" not in f for f in shown), shown
    c.eval("ns.Azero.clockHour = 21")
    w.tick(0.1)
    a = st()
    assert not a["sun"] and a["anims"] >= 1 and a["dark"] >= 1 and a["glows"] >= 1, a
    shown = c.eval_py("return ns.AzeroUI._Ground()")
    assert shown and all("home_e_" in f for f in shown), shown              # the evening picture: night windows


@case
def every_zone_has_its_mood():
    w, c = play("darkshire", 10, 8)
    st = lambda: c.eval_py("return ns.AzeroUI._Ambient()")
    c.eval("ns.Azero.clockHour = 12")
    w.tick(0.1)
    assert st()["mist"] and st()["mood"], st()                         # Duskwood's mist
    c.eval("ns.Azero:EnterMap('stvnorth', 14, 11, 'down', true)")
    w.tick(0.1)
    assert st()["shafts"], st()                                        # sun shafts in the jungle by day
    c.eval("ns.Azero.clockHour = 23")
    w.tick(0.1)
    a = st()
    assert not a["shafts"] and a["pix"] > 10, a                        # fireflies at night
    c.eval("ns.Azero:EnterMap('crystalvein', 3, 3, 'down', true)")
    c.eval("ns.Azero.clockHour = 12")
    w.tick(0.1)
    assert st()["dark"] >= 1, st()                                     # a cave is dim by day, lit by its torches


@case
def it_rains_now_and_then_and_motion_can_be_turned_off():
    w, c = play("route1", 11, 20)
    st = lambda: c.eval_py("return ns.AzeroUI._Ambient()")
    c.eval("ns.Azero.forceRain = true")
    w.tick(0.1)
    a = st()
    assert a["raining"] and a["pix"] >= 70, a
    c.eval("ns.Azero.forceRain = false ns.Azero:Data().calm = true")
    w.tick(0.1)
    a = st()
    assert not a["raining"] and a["pix"] == 0 and a["wind"] == 0, a


@case
def footsteps_kick_up_dust_on_the_path():
    w, c = play("route1", 11, 20)                                      # on Route 1's road
    c.eval("ns.Azero.forceRain = false")
    x, y = c.eval_py("""local m = ns.Azero.map
      for y = 1, m.h - 2 do for x = 1, m.w - 2 do
        if m.def.rows[y + 1]:sub(x + 1, x + 1) == '=' then return { x, y } end
      end end""")
    c.eval("ns.Azero.moving = { t = 0, dur = 0.25, fromX = %d, fromY = %d }" % (x, y))   # a step off the road
    w.tick(0.02)
    assert c.eval_py("return ns.AzeroUI._Ambient()")["parts"] >= 1
    c.eval("ns.Azero.moving = nil")


@case
def the_sea_glints():
    w, c = play("jaguero", 10, 10)
    g = c.eval_py("return #(ns.AzeroGround.jaguero.glints or {})")
    assert g > 20, g


@case
def the_atlas_has_the_shade_and_shadow_tiles():
    src = open(os.path.join(ADDON, "..", "DisasterZone_Azeromon", "Atlas.lua")).read()
    for name in ("grass1_shade", "wgrass1_shade", "dgrass1_shade", "jgrass1_shade", "shadow",
                 "grass1_forest", "wgrass1_forest", "dgrass1_forest", "jgrass1_forest"):
        assert re.search(r"^\s+%s = \d+,$" % name, src, re.M), name
    assert src.startswith('if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/Atlas.lua", ...) then return end')


if __name__ == "__main__":
    run_all(globals())
