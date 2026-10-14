"""Azeromon: the world map (START > MAP).

Covers: every map belongs to exactly one place; places count as visited once you set foot there, and saves from
before the map are filled in from beaten trainers and opened chests; roads follow the maps' edges and warps, and
gryphon routes show once both ends are known (and the flight learned); what a place offers (NPC roles, boards,
crafting stations), wild levels, beasts seen / tamed, trainers beaten, its badge; guildmates there now; the panel
through the UI (opens on your place, arrows move between places, ??? for unvisited ones, X closes); the painted map
(gen_azeromon_worldmap.py: files there, WorldArt.lua up to date with the places and roads), mist over unknown places
with a "?" where a road leads in, a place found since the last look revealed with a banner, lamps after dark.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_worldmap.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

DEV = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(DEV, "generators"))


def game(ui=False):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(3)")
    c.eval("ns.Azero:NewGame()")
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('murkling', 12, ns.Azero.rng), 'caught')")
    if ui:
        c.slash("/dz play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.3)
        c.eval("T_AZ.settle()")
    return w, c


def visited(c):
    return c.eval_py("""local out = {}
      for _, p in ipairs(ns.AzeroWorld.PLACES) do if ns.AzeroWorld.Visited(p) then out[#out + 1] = p.id end end
      table.sort(out) return out""")


def lines(c, place):
    return c.eval_py("return ns.AzeroWorld.Lines(ns.AzeroWorld.byId[%r])" % place)


@case
def every_map_belongs_to_exactly_one_place():
    w, c = game()
    bad = c.eval_py("""local W, Maps = ns.AzeroWorld, ns.AzeroMaps
      local bad, count = {}, {}
      for _, p in ipairs(W.PLACES) do
        for _, m in ipairs(p.maps) do
          if not Maps[m] then bad[#bad + 1] = 'no map ' .. m end
          count[m] = (count[m] or 0) + 1
        end
      end
      for id, def in pairs(Maps) do
        if type(def) == 'table' and def.rows and count[id] ~= 1 then bad[#bad + 1] = id .. ' in ' .. (count[id] or 0) end
      end
      return bad""")
    assert bad == [], bad
    no_errors(w)


@case
def places_are_visited_by_setting_foot_there():
    w, c = game()
    assert visited(c) == ["goldshire"], visited(c)
    c.eval("ns.Azero:EnterMap('saldean', 4, 5, 'up', true)")
    assert visited(c) == ["goldshire", "westfall"], visited(c)
    # a save from before the map: filled in from beaten trainers and opened chests
    c.eval("""local s = ns.Azero.save
      s.visited = nil
      s.flags.beat_captain = true s.flags.chest_wfnet = true s.flags.fp_darkshire = true
      ns.Azero:Load()""")
    assert visited(c) == ["darkshire", "elwynn", "goldshire", "westfall"], visited(c)
    no_errors(w)


@case
def roads_follow_the_maps_and_flights_need_both_ends():
    w, c = game()
    roads = c.eval_py("""local out = {}
      for _, r in ipairs(ns.AzeroWorld.Roads()) do
        local a, b = r[1].id, r[2].id
        if a > b then a, b = b, a end
        out[#out + 1] = a .. '-' .. b
      end
      table.sort(out) return out""")
    assert roads == ["arena-stvsouth", "arena-zulmamwe", "bootybay-wildshore", "crystalvein-stvsouth",
                     "darkshire-duskwood", "darkshire-rebelcamp", "deadmines-moonbrook", "duskwood-ravenhill",
                     "elwynn-forestedge", "elwynn-goldshire", "elwynn-westfall", "kurzen-rebelcamp",
                     "moonbrook-sentinel", "moshogg-zulmamwe", "ravenhill-sentinel", "rebelcamp-stvnorth",
                     "sentinel-westfall", "stvnorth-zulmamwe", "stvsouth-wildshore"], roads
    shown = "local W = ns.AzeroWorld return { W.FlightShown(W.FLIGHTS[1]), W.FlightShown(W.FLIGHTS[2]) }"
    assert c.eval_py(shown) == [False, False]
    c.eval("ns.Azero:EnterMap('sentinel', 5, 9, 'down', true) ns.Azero:EnterMap('arena', 7, 11, 'up', true)")
    c.eval("ns.Azero:EnterMap('darkshire', 1, 10, 'right', true)")
    assert c.eval_py(shown) == [True, False]                    # Darkshire's route is learned from Felicia
    c.eval("ns.Azero:SetFlag('fp_darkshire')")
    assert c.eval_py(shown) == [True, True]
    # moving around the map: in line first
    moves = c.eval_py("""local N = ns.AzeroWorld.Neighbour
      return { N('goldshire', 'up'), N('elwynn', 'left'), N('sentinel', 'right'), N('darkshire', 'down'),
               N('arena', 'up'), N('goldshire', 'down'), N('deadmines', 'left') }""")
    assert moves == ["elwynn", "forestedge", "ravenhill", "rebelcamp", "zulmamwe", "arena", "deadmines"], moves
    no_errors(w)


@case
def a_place_tells_what_it_offers_and_your_progress():
    w, c = game()
    assert lines(c, "westfall")["name"] == "???" and lines(c, "westfall")["text"] == "You haven't been here yet."
    c.eval("ns.Azero:EnterMap('sentinel', 5, 9, 'down', true)")
    l = lines(c, "sentinel")
    assert l["name"] == "Sentinel Hill" and l["zone"] == "WESTFALL", l
    assert l["line3"] == "Inn, Shop, Stable, Bounty board, Forge and anvil, Gryphons", l
    assert l["line4"] == "You are here.", l                              # (no trainers, no wild beasts)
    l = lines(c, "goldshire")
    assert l["line3"] == ("Inn, Shop, Stable, Bounty board, Profession trainers, Pet trainer, Forge and anvil, "
                          "Alchemy table"), l
    # a route: its wild levels, beasts seen / tamed, trainers
    c.eval("ns.Azero:EnterMap('westfall', 5, 5, 'down', true)")
    expect = c.eval_py("""local lo, hi, n = 99, 0, {}
      for _, list in ipairs({ ns.AzeroMaps.westfall.encounters, ns.AzeroMaps.westfall.coastEncounters }) do
        for _, e in ipairs(list) do if not e.rare then lo = math.min(lo, e.min) hi = math.max(hi, e.max) n[e.sp] = true end end
      end
      local total = 0 for _ in pairs(n) do total = total + 1 end
      return { lo = lo, hi = hi, total = total }""")
    c.eval("ns.Azero.save.seen.coyote = true ns.Azero.save.caught.coyote = true ns.Azero.save.seen.crawler = true")
    l = lines(c, "westfall")
    assert l["line3"].startswith("Wild beasts Lv %d-%d" % (expect["lo"], expect["hi"])), (l, expect)
    assert l["line3"].endswith("Rest"), l                                  # the Saldeans' farm
    assert "Beasts 2/%d seen, 1 tamed" % expect["total"] in l["line4"] and "Trainers 0/" in l["line4"], l
    # a badge place
    c.eval("ns.Azero:EnterMap('forestedge', 5, 5, 'down', true)")
    assert "Hogger's Claw: not yet" in lines(c, "forestedge")["line4"]
    c.eval("ns.Azero:SetFlag('beat_hogger') ns.Azero:SetFlag('badge_hogger')")
    assert "Hogger's Claw: earned" in lines(c, "forestedge")["line4"]
    no_errors(w)


@case
def guildmates_show_where_they_are():
    w, c = game()
    c.eval("""ns.AzeroNet.PeersOn = function(self, m)
      if m == 'sentinelinn' then return { { name = 'Bob', class = 'MAGE' } } end
      if m == 'sentinel' then return { { name = 'Ann', class = 'DRUID' } } end
      return {} end""")
    assert lines(c, "sentinel")["line4"] == "Guildmates here: Ann, Bob"          # (not visited yet: only that)
    no_errors(w)


@case
def the_map_through_the_ui():
    w, c = game(ui=True)
    c.eval("ns.Azero:EnterMap('route1', 11, 20, 'up', true)")
    c.eval("ns.AzeroUI._HandleKey('START')")
    w.tick(0.1)
    items = c.eval_py("return ns.AzeroUI._MenuItems()")
    assert "MAP" in items, items
    for _ in range(items.index("MAP")):
        c.eval("ns.AzeroUI._HandleKey('down')")
    assert c.eval("return ns.AzeroUI._DescText()") == "Where you have been, and what's there."
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.1)
    s = c.eval_py("return ns.AzeroWorld._State()")
    assert s["sel"] == "elwynn" and s["name"] == "Elwynn Forest" and s["zone"] == "ELWYNN FOREST", s
    assert s["line4"].startswith("You are here."), s
    c.eval("ns.AzeroUI._HandleKey('up')")                               # Westfall: not been there
    s = c.eval_py("return ns.AzeroWorld._State()")
    assert s["sel"] == "westfall" and s["name"] == "???", s
    c.eval("ns.AzeroUI._HandleKey('down')")
    c.eval("ns.AzeroUI._HandleKey('down')")
    s = c.eval_py("return ns.AzeroWorld._State()")
    assert s["sel"] == "goldshire" and s["name"] == "Goldshire", s
    w.tick(0.5)                                                          # (the marker and cursor animate)
    c.eval("ns.AzeroUI._HandleKey('B')")
    w.tick(0.1)
    assert c.eval("return ns.AzeroWorld._State()") is None
    assert c.eval_py("return ns.AzeroUI._MenuItems()") == items             # back on the START menu
    no_errors(w)


@case
def the_painted_map_is_baked_and_up_to_date():
    from PIL import Image
    import gen_azeromon_worldmap as GW
    w, c = game()
    art = c.eval_py("return ns.AzeroWorldArt")
    assert art["v"] == GW.inputs_hash(GW.world_data(c)), "WorldArt.lua is stale: run generators/gen_azeromon_worldmap.py"
    for name, size in (("worldmap", (art["tw"], art["th"])), ("worldmap_fog1", (512, art["fogH"])),
                       ("worldmap_fog2", (512, art["fogH"])), ("worldmap_lap", (art["lap"]["tw"], art["lap"]["th"])),
                       ("worldmap_dusk", (art["tw"], art["th"])), ("worldmap_sprites", (128, 64))):
        f = os.path.join(GW.OUT_DIR, name + ".tga")
        assert os.path.exists(f), f
        assert Image.open(f).size == size, (f, Image.open(f).size, size)
    places = c.eval_py("local out = {} for _, p in ipairs(ns.AzeroWorld.PLACES) do out[#out + 1] = p.id end return out")
    assert sorted(art["places"]) == sorted(places), art["places"]
    assert sorted(art["fog"]) == sorted(places + ["redridge"]), sorted(art["fog"])
    no_errors(w)


def open_map(c, w):
    c.eval("ns.AzeroUI._HandleKey('START')")
    w.tick(0.1)
    items = c.eval_py("return ns.AzeroUI._MenuItems()")
    for _ in range(items.index("MAP")):
        c.eval("ns.AzeroUI._HandleKey('down')")
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.1)
    return c.eval_py("return ns.AzeroWorld._State()")


def close_map(c, w):
    c.eval("ns.AzeroUI._HandleKey('B')")
    w.tick(0.1)
    c.eval("ns.AzeroUI._HandleKey('B')")
    w.tick(0.1)


@case
def mist_hides_unknown_places_and_lifts_when_you_find_them():
    w, c = game(ui=True)
    s = open_map(c, w)
    assert s["artOK"], s
    assert "goldshire" not in s["fog"] and "westfall" in s["fog"] and "redridge" in s["fog"], s["fog"]
    assert s["pins"] == ["elwynn"], s["pins"]                         # a road leads from Goldshire into the mist
    assert s["reveal"] == [] and s.get("banner") is None, s              # (the first look shows what you know, quietly)
    close_map(c, w)
    c.eval("ns.Azero:EnterMap('route1', 11, 20, 'up', true)")
    s = open_map(c, w)
    assert s["reveal"] == ["elwynn"] and s["sel"] == "elwynn", s
    assert "elwynn" in s["fog"] and s["name"] == "Elwynn Forest", s   # the mist is still lifting; the card knows it
    w.tick(0.6)
    assert c.eval_py("return ns.AzeroWorld._State()")["banner"] == "Elwynn Forest"
    w.tick(2.5)
    s = c.eval_py("return ns.AzeroWorld._State()")
    assert s["reveal"] == [] and "elwynn" not in s["fog"], s
    assert s["pins"] == ["forestedge", "westfall"], s["pins"]
    close_map(c, w)
    s = open_map(c, w)
    assert s["reveal"] == [], s                                      # shown once
    no_errors(w)


@case
def lamps_light_up_after_dark():
    w, c = game(ui=True)
    lit = """local f = ns.AzeroWorld.frame local n = 0
      for _, g in ipairs(f.glows) do if g.tex:IsShown() then n = n + 1 end end
      for _, x in ipairs(f.windows) do if x.tex:IsShown() then n = n + 1 end end
      return { n = n, dark = f.dark:IsShown() }"""
    c.eval("ns.Azero.clockHour = 12")
    s = open_map(c, w)
    assert s["period"] == "day" and c.eval_py(lit) == {"n": 0, "dark": False}
    close_map(c, w)
    c.eval("ns.Azero.clockHour = 23")
    s = open_map(c, w)
    r = c.eval_py(lit)
    assert s["period"] == "night" and r["dark"] and r["n"] > 0, r
    # lamps under the mist stay dark: only Goldshire's are known in a new game
    gold = c.eval_py("""local f, A = ns.AzeroWorld.frame, ns.AzeroWorldArt local far = 0
      local gx, gy = A.places.goldshire[1], A.places.goldshire[2]
      for _, g in ipairs(f.glows) do
        if g.tex:IsShown() and (math.abs(g.x - gx) > 14 or math.abs(g.y - gy) > 14) then far = far + 1 end
      end
      return far""")
    assert gold == 0, gold
    no_errors(w)


if __name__ == "__main__":
    run_all()
