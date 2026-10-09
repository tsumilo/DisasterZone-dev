"""Disastercraft: what stops you outdoors and what buffs do to your numbers.

Covers: the fine collision layer (azw_collide: ~1 yd cells from the models' own collision meshes) - a tree trunk
or a prop blocks only the cells it stands on, the rest of its old 4-yard tile is open, the foot is WoW-sized, paths
still go round, a unit inside something walks out; buffs - Battle Shout, Power Word: Fortitude, Arcane Intellect -
raise the numbers, keep them after a recalculation (an aura's visual no longer replaces its effects), drop them when
they end, and the character sheet shows them green with the base in the tooltip.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_craft_world.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

import _common  # noqa: E402
from _common import case, run_all, no_errors  # noqa: E402
from test_craft import game, ui_game  # noqa: E402

_common._CASES.clear()              # (test_craft's own cases run in their own suite)

# the tiles round the start whose overlay used to be solid whole, with their collision masks
SOLID_TILES = r"""
  local WS = ns.AzeroLand
  local out = {}
  for ty = 6150, 6300 do
    for tx = 4080, 4240 do
      local _, o = WS.Tile(tx, ty)
      local ch = string.char(o)
      if ch == "T" or ch == "B" or ch == "C" or ch == "a" or ch == "f" then
        out[#out + 1] = { x = tx, y = ty, ch = ch, m = WS.CellMask(tx, ty) }
      end
    end
  end
  return out
"""


@case
def collision_cells_are_smaller_than_tiles():
    w, c = game(1)
    tiles = c.eval_py(SOLID_TILES)
    assert len(tiles) > 50, len(tiles)
    assert all(t["m"] is not None for t in tiles), [t for t in tiles if t["m"] is None][:3]
    full = [t for t in tiles if t["m"] == 0xFFFF]
    # (a tree, a barrel, a fence takes a few of its tile's 16 cells, not all of them)
    assert len(full) < len(tiles) * 0.1, (len(full), len(tiles))
    some = [t for t in tiles if t["m"] not in (0, 0xFFFF)]
    assert len(some) > len(tiles) * 0.3, (len(some), len(tiles))
    no_errors(w)


@case
def you_walk_right_up_to_a_trunk():
    w, c = game(1)
    r = c.eval_py(SOLID_TILES.replace("return out", r"""
      local W, p = ns.Craft.World, ns.Craft.player
      -- a tree tile with a solid cell and open cells: stand on an open one inside the old tile, then walk into
      -- the trunk
      for _, t in ipairs(out) do
        if t.ch == "T" and t.m ~= 0 and t.m ~= 65535 then
          local solid, open
          for k = 0, 15 do
            local cx, cy = t.x + (k % 4 + 0.5) / 4, t.y + (math.floor(k / 4) + 0.5) / 4
            if math.floor(t.m / 2 ^ k) % 2 == 1 then solid = solid or { cx, cy }
            elseif W.Fits("world", cx, cy) then open = open or { cx, cy } end
          end
          if solid and open then
            p.map, p.x, p.y = "world", open[1], open[2]
            local insideOldTile = W.Fits("world", open[1], open[2])
            local dx, dy = solid[1] - open[1], solid[2] - open[2]
            local len = math.sqrt(dx * dx + dy * dy)
            for _ = 1, 40 do W.MoveBy(p, dx / len * 0.02, dy / len * 0.02) end
            return { ok = insideOldTile, reached = ns.AzeroLand.SolidAt(p.x, p.y), x = p.x, y = p.y,
                     sx = solid[1], sy = solid[2], free = W.Free("world", p.x, p.y) }
          end
        end
      end
      return nil
    """))
    assert r, "no tree tile with open cells"
    assert r["ok"] and r["free"] and not r["reached"], r          # stood in the old tile, stopped at the trunk
    no_errors(w)


@case
def a_unit_inside_something_walks_out_and_paths_go_round():
    w, c = game(1)
    r = c.eval_py(SOLID_TILES.replace("return out", r"""
      local W, WS, p = ns.Craft.World, ns.AzeroLand, ns.Craft.player
      local t
      for _, x in ipairs(out) do if x.m == 65535 or (x.ch == "T" and WS.Solid(x.x, x.y)) then t = x break end end
      if not t then return nil end
      p.map, p.x, p.y = "world", t.x + 0.5, t.y + 0.5
      local stuck = not W.Fits("world", p.x, p.y)
      local moved = W.MoveBy(p, 0.05, 0)
      -- a path from one side of the blocked tile to the other goes round it
      local path = W.Path("world", t.x - 2 + 0.5, t.y + 0.5, t.x + 2 + 0.5, t.y + 0.5)
      local through = false
      for _, s in ipairs(path or {}) do
        if math.floor(s[1]) == t.x and math.floor(s[2]) == t.y then through = true end
      end
      return { stuck = stuck, moved = moved, path = path ~= nil, through = through }
    """))
    assert r, "no blocked tile near the start"
    assert r["stuck"] and r["moved"] > 0.04, r
    assert r["path"] and not r["through"], r
    no_errors(w)


@case
def battle_shout_raises_attack_power_until_it_ends():
    w, c = ui_game()
    c.eval("ns.Craft:NewCharacter(1, 0) ns.CraftUI.Glue.selected = 1 ns.CraftUI.Glue.EnterWorld()")
    w.tick(1.0)
    r = c.eval_py(r"""
      local C, Combat, p = ns.Craft, ns.Craft.Combat, ns.Craft.player
      local ap0 = p.ap
      local a = Combat.ApplyAura(p, p, 6673, true)
      local ap1 = p.ap
      local effects = a and a.fx[1] and a.fx[1].a
      Combat.Recalc(p)                         -- (anything else that recalculates - gear, level, another buff)
      local ap2, bonus = p.ap, p.statBonus.ap
      ns.CraftUI.Toggle('character')
      local shown
      for side, prefix in pairs({ left = "PlayerStatFrameLeft", right = "PlayerStatFrameRight" }) do
        for i = 1, 6 do
          local R = ns.CraftUI.characterRefs or {}
          local l = R[prefix .. i .. "Label"]
          if l and l:GetText() == "Power:" then shown = R[prefix .. i .. "StatText"]:GetText() end
        end
      end
      Combat.RemoveAura(p, a, "expired")
      return { ap0 = ap0, ap1 = ap1, ap2 = ap2, ap3 = p.ap, bonus = bonus, effects = effects, shown = shown,
               amount = a and a.fx[1] and a.fx[1].amount }
    """)
    assert r["effects"] == 99, r                      # the aura still holds its effect (not its visual)
    assert r["amount"] and r["amount"] > 0, r
    assert r["ap1"] == r["ap0"] + r["amount"] and r["ap2"] == r["ap1"], r
    assert r["bonus"] == r["amount"] and r["ap3"] == r["ap0"], r
    assert "ff20ff20" in r["shown"] and str(r["ap2"]) in r["shown"], r      # green on the sheet
    no_errors(w)


@case
def fortitude_and_intellect_raise_health_and_mana():
    w, c = game(5)
    r = c.eval_py(r"""
      local Combat, p = ns.Craft.Combat, ns.Craft.player
      local sta0, hp0, int0, mana0 = p.sta, p.hpMax, p.int, p.powerMax
      local a = Combat.ApplyAura(p, p, 1243, true)
      local b = Combat.ApplyAura(p, p, 1459, true)
      Combat.Recalc(p)
      local out = { sta = p.sta - sta0, hp = p.hpMax - hp0, int = p.int - int0, mana = p.powerMax - mana0,
                    bsta = p.statBonus.sta, bint = p.statBonus.int }
      Combat.RemoveAura(p, a) Combat.RemoveAura(p, b)
      out.back = p.sta == sta0 and p.int == int0 and p.hpMax == hp0 and p.powerMax == mana0
      return out
    """)
    assert r["sta"] == 3 and r["bsta"] == 3, r                  # Rank 1: +3 Stamina
    assert r["int"] == 2 and r["bint"] == 2, r                  # Rank 1: +2 Intellect
    assert r["hp"] > 0 and r["mana"] > 0, r
    assert r["back"], r
    no_errors(w)


@case
def an_auras_visual_leaves_its_effects_alone():
    # (UIEffects used to store the visual's handles in a.fx - the aura's own effects - so Food stopped ticking and
    # Icy Veins / stuns ended at the next recalculation)
    w, c = game(1)
    r = c.eval_py(r"""
      local Combat, p = ns.Craft.Combat, ns.Craft.player
      local a = Combat.ApplyAura(p, p, 433, true)
      Combat.Recalc(p)
      return { has = ns.Craft.D.vis[433] ~= nil, a = a.fx[1] and a.fx[1].a, vfx = a.vfx ~= nil }
    """)
    assert r["has"] and r["a"] == 84 and r["vfx"], r
    no_errors(w)


if __name__ == "__main__":
    run_all()
