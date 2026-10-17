"""Azeromon: the bigger Goldshire (0.27).

Covers: the new stamps (inn, smithy, cottage, stable, well) have their sizes in the atlas and on the map; nothing on
the map stands inside a building, and only small props (barrels, crates, hay, the anvil and forge) lean against one;
every sign, board and new building keeps a tile of open ground in front of it; every door warps into its room and
the room's door warps back onto open ground next to it; the inn's double door, the Guild Hall stairs and the revive
spot; the north road meets Elwynn Forest's road; NPCs stand on open ground; old saves in Goldshire or the inn are
moved to the new spots, newer saves are left alone.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_goldshire.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402

NEW = {"inn": (9, 8), "smithy": (5, 6), "cottage": (5, 6), "stable": (5, 6), "well": (2, 3)}
LEAN = ("barrel", "crate", "hay", "anvil", "forge")

_MAP = None


def town():
    """the compiled Goldshire: size, rows, over tiles, solid tiles, stamps, warps, NPC spots"""
    global _MAP
    if _MAP is None:
        _, c = solo("Alice", tick=2)
        _MAP = c.eval_py("""
          local G = ns.Azero
          local function dump(id)
            local m = G.Compile(id)
            local over, solid = {}, {}
            for y = 0, m.h - 1 do for x = 0, m.w - 1 do
              local k = m.key(x, y)
              over[#over + 1] = type(m.over[k]) == "string" and m.over[k] or ""
              solid[#solid + 1] = m.solid[k] and 1 or 0
            end end
            local stamps, warps, npcs, edges = {}, {}, {}, {}
            for _, s in ipairs(m.def.stamps or {}) do stamps[#stamps + 1] = { kind = s.kind, x = s.x, y = s.y } end
            for _, w in ipairs(m.def.warps or {}) do warps[#warps + 1] = { x = w.x, y = w.y, map = w.map, tx = w.tx, ty = w.ty } end
            for _, n in ipairs(m.def.npcs or {}) do if type(n.x) == "number" then npcs[#npcs + 1] = { id = n.id, x = n.x, y = n.y } end end
            for side, e in pairs(m.def.edges or {}) do edges[side] = { map = e.map, dx = e.dx or 0, dy = e.dy or 0 } end
            local rows = {}
            for i, r in ipairs(m.def.rows) do rows[i] = r end
            return { w = m.w, h = m.h, over = over, solid = solid, stamps = stamps, warps = warps, npcs = npcs,
                     edges = edges, rows = rows }
          end
          local out = {}
          for _, id in ipairs({ "town", "post", "home", "lab", "cottage", "route1", "hideout" }) do out[id] = dump(id) end
          out.atlas = {}
          for kind in pairs({ inn = 1, smithy = 1, cottage = 1, stable = 1, well = 1 }) do
            out.atlas[kind] = ns.AzeroAtlas[kind .. "_0_0"] ~= nil
          end
          out.respawn = ns.AzeroMaps.RESPAWN
          return out
        """)
    return _MAP


def at(m, x, y, key):
    return m[key][y * m["w"] + x]


def walkable(m, x, y):
    return 0 <= x < m["w"] and 0 <= y < m["h"] and at(m, x, y, "solid") == 0


@case
def the_new_stamps_are_in_the_atlas_and_on_the_map():
    t = town()
    assert all(t["atlas"].values()), t["atlas"]
    kinds = {s["kind"] for s in t["town"]["stamps"]}
    assert set(NEW) <= kinds, kinds
    m = t["town"]
    for s in m["stamps"]:
        if s["kind"] in NEW:
            w, h = NEW[s["kind"]]
            assert at(m, s["x"] + w - 1, s["y"] + h - 1, "over") == "%s_%d_%d" % (s["kind"], w - 1, h - 1), s


@case
def nothing_stands_inside_a_building_and_only_small_props_lean_on_one():
    m = town()["town"]
    for s in m["stamps"]:
        if s["kind"] not in NEW or s["kind"] == "well":
            continue
        w, h = NEW[s["kind"]]
        for y in range(s["y"] - 1, s["y"] + h + 1):
            for x in range(s["x"] - 1, s["x"] + w + 1):
                if not (0 <= x < m["w"] and 0 <= y < m["h"]):
                    continue
                o = at(m, x, y, "over")
                inside = s["x"] <= x < s["x"] + w and s["y"] <= y < s["y"] + h
                if inside:
                    assert o.startswith(s["kind"] + "_"), (s, x, y, o)
                elif o and m["rows"][y][x] != "T" and not any(o.startswith(k + "_") for k in NEW):
                    # (buildings may stand side by side: the inn and its stable)
                    assert o in LEAN, ("%s against the %s at (%d,%d)" % (o, s["kind"], x, y))


@case
def signs_boards_and_doors_have_open_ground_in_front():
    m = town()["town"]
    for y in range(m["h"] - 1):
        for x in range(m["w"]):
            o = at(m, x, y, "over")
            if o in ("sign", "wantedboard", "alchemy", "anvil", "forge"):
                around = [(x, y + 1), (x - 1, y), (x + 1, y), (x, y - 1)]
                assert any(walkable(m, a, b) for a, b in around), (o, x, y)


@case
def every_door_leads_in_and_back_out_next_to_it():
    t = town()
    m = t["town"]
    for w in m["warps"]:
        assert walkable(m, w["x"], w["y"]), ("door tile is solid", w)
        room = t[w["map"]]
        assert walkable(room, w["tx"], w["ty"]), ("lands on a solid tile inside", w)
        back = [b for b in room["warps"] if b["map"] == "town"]
        assert back, ("no way back out of", w["map"])
        for b in back:
            assert walkable(m, b["tx"], b["ty"]), ("lands on a solid tile outside", b)
            assert abs(b["tx"] - w["x"]) <= 1 and abs(b["ty"] - w["y"]) <= 1, ("lands away from its door", w, b)
    inn = [w for w in m["warps"] if w["map"] == "post"]
    assert sorted((w["x"], w["y"]) for w in inn) == [(7, 22), (8, 22)], inn     # the double door


@case
def the_guild_hall_stairs_and_the_revive_spot_are_in_the_new_inn():
    t = town()
    post, hall = t["post"], t["hideout"]
    down = [w for w in post["warps"] if w["map"] == "hideout"]
    assert down and at(post, down[0]["x"], down[0]["y"], "over") == "stairs", down
    up = [w for w in hall["warps"] if w["map"] == "post"]
    assert up and all(walkable(post, w["tx"], w["ty"]) and abs(w["tx"] - down[0]["x"]) <= 1 for w in up), up
    r = t["respawn"]
    assert r["map"] == "post" and walkable(post, r["x"], r["y"]), r


@case
def the_north_road_meets_elwynn_forests_road():
    t = town()
    m, r1 = t["town"], t["route1"]
    dx = m["edges"]["north"]["dx"]
    assert m["edges"]["north"]["map"] == "route1" and r1["edges"]["south"] == {"map": "town", "dx": -dx, "dy": 0}
    road = [x for x in range(m["w"]) if m["rows"][0][x] == "="]
    assert road, "no road leaves Goldshire to the north"
    for x in road:
        assert r1["rows"][-1][x + dx] == "=", ("Goldshire's road at x %d meets Elwynn's x %d, not a road" % (x, x + dx))


@case
def people_stand_on_open_ground():
    t = town()
    for mid in ("town", "post"):
        m = t[mid]
        for n in m["npcs"]:
            o = at(m, n["x"], n["y"], "over")
            assert at(m, n["x"], n["y"], "solid") == 0 and o in ("", "sign") or o == "", (mid, n, o)


@case
def old_saves_move_to_the_new_goldshire():
    _, c = solo("Alice", tick=2)
    r = c.eval_py("""
      local G = ns.Azero
      local out = {}
      for _, case in ipairs({
          { v = 1, map = "town", x = 5, y = 16, respawn = { map = "post", x = 4, y = 5, face = "up" } },
          { v = 1, map = "post", x = 4, y = 5 },
          { v = 1, map = "route1", x = 10, y = 3, respawn = { map = "home", x = 4, y = 4, face = "up" } },
          { v = 2, map = "town", x = 17, y = 12 },
        }) do
        G:Data().save = { v = case.v, map = case.map, x = case.x, y = case.y, face = "down", party = {},
                          flags = { starter = "murkling" }, respawn = case.respawn }
        G:Load()
        local s, m = G.save, G.map
        out[#out + 1] = { map = s.map, x = s.x, y = s.y, v = s.v, solid = m.solid[m.key(s.x, s.y)] == true,
                          rx = s.respawn and s.respawn.x, ry = s.respawn and s.respawn.y }
      end
      return out
    """)
    assert r[0]["map"] == "town" and (r[0]["x"], r[0]["y"]) == (7, 23) and (r[0]["rx"], r[0]["ry"]) == (5, 4), r
    assert r[1]["map"] == "post" and (r[1]["x"], r[1]["y"]) == (7, 8), r
    assert r[2]["map"] == "route1" and (r[2]["x"], r[2]["y"]) == (10, 3) and (r[2]["rx"], r[2]["ry"]) == (4, 4), r
    assert r[3]["map"] == "town" and (r[3]["x"], r[3]["y"]) == (17, 12), r
    now = c.eval("return ns.AzeroData.SAVE_VERSION")             # (every old save ends on today's version)
    assert all(e["v"] == now and not e["solid"] for e in r), r


if __name__ == "__main__":
    run_all(globals())
