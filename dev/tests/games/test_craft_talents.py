"""Disastercraft talent rows (Games/Disastercraft/Talents.lua): a row of three every second level, one per spec.

Covers: rows open at 2/4/6/8/10; a choice can change for free out of combat (not in combat); a passive choice puts
its aura on the hero and changes its numbers; an ability goes into the spellbook and onto a free action button and
leaves both when the row changes; every one of the 45 choices of the three classes works in the engine: a passive
changes something on the hero, an ability does something when cast at a kobold (or on yourself).

Run: luaenv\\Scripts\\python.exe tests\\games\\test_craft_talents.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

import _common  # noqa: E402
from _common import case, run_all, no_errors  # noqa: E402
from test_craft import game  # noqa: E402

_common._CASES.clear()              # (test_craft's own cases run in their own suite)

SETUP = r"""
  local C, T, Combat = ns.Craft, ns.Craft.Talents, ns.Craft.Combat
  local p = C.player
  C.char.level, p.level = 10, 10
  Combat.Recalc(p)
  T_DC.calm()
"""


@case
def rows_open_every_second_level_and_change_freely():
    w, c = game(8)
    r = c.eval_py(r"""
      local C, T, Combat = ns.Craft, ns.Craft.Talents, ns.Craft.Combat
      local p, out = C.player, {}
      out.at1 = { T.Points() }
      out.early = { T.Choose(1, 1) }
      C.char.level, p.level = 4, 4
      out.at4 = { T.Points() }
      local fb = C.D.spells[133]
      local cast0 = Combat.CastTime(fb, p)
      out.pick = T.Choose(1, 1)                                   -- Improved Fireball: 0.5 s faster
      out.cast1 = Combat.CastTime(fb, p) - cast0
      out.row3 = { T.Choose(3, 1) }                               -- (level 6 row: closed)
      -- swap to Arcane Mind: the Fireball is back to 1.5 s, Intellect goes up
      local int0 = p.int
      out.swap = T.Choose(1, 3)
      out.cast2 = Combat.CastTime(fb, p)
      out.int = p.int - int0
      out.same = { T.Choose(1, 3) }
      -- in combat: no change
      p.inCombat = true
      out.combat = { T.Choose(1, 1) }
      p.inCombat = false
      out.book = false
      for _, tab in ipairs(C.Npc.Spellbook()) do for _, id in ipairs(tab.list) do if id == 12503 then out.book = true end end end
      return out
    """)
    assert r["at1"] == [0, 0, 0] and r["early"] == [False, "level"], r
    assert r["at4"] == [2, 0, 2], r
    assert r["pick"] and abs(r["cast1"] + 0.5) < 1e-6, r
    assert r["row3"] == [False, "level"], r
    assert r["swap"] and abs(r["cast2"] - 1.5) < 1e-6 and r["int"] > 0, r
    assert r["same"] == [False, "same"] and r["combat"] == [False, "combat"], r
    assert r["book"] is False, r                                  # (passive talents stay out of the spellbook)
    no_errors(w)


@case
def an_ability_goes_on_the_bar_and_leaves_with_the_row():
    w, c = game(1)
    r = c.eval_py(SETUP + r"""
      local function onBar(id) for s, a in pairs(C.char.bar) do if a[1] == "spell" and a[2] == id then return s end end end
      T.Choose(5, 1)                                              -- Mortal Strike
      local out = { ms = C.char.spells[12294] == true, bar = onBar(12294) ~= nil }
      T.Choose(5, 2)                                              -- Bloodthirst instead
      out.msGone = not C.char.spells[12294] and onBar(12294) == nil
      out.bt = C.char.spells[23881] == true and onBar(23881) ~= nil
      return out
    """)
    assert r["ms"] and r["bar"] and r["msGone"] and r["bt"], r
    no_errors(w)


# what an ability is cast on: "enemy" (a kobold next to you), "self"
TARGET = {12294: "enemy", 23881: "enemy", 12809: "enemy", 11366: "enemy", 11426: "self", 12042: "self",
          11113: "enemy", 12472: "self", 31589: "enemy", 15237: "enemy", 15407: "enemy", 14752: "self",
          34861: "self", 15473: "self", 10060: "self"}


def check_class(cls):
    w, c = game(cls)
    bad = []
    rows = c.eval_py("local out = {} for ri, row in ipairs(ns.Craft.Talents.Rows(%d)) do out[ri] = row.spells end return out" % cls)
    for ri, spells in enumerate(rows, 1):
        for ci, sid in enumerate(spells, 1):
            r = c.eval_py(SETUP + r"""
              local ri, ci, sid = ...
              -- a fresh hero state: full health and power, no cooldowns, no auras but the talent's
              for i = #p.auras, 1, -1 do Combat.RemoveAura(p, p.auras[i]) end
              p.inCombat, p.combatUntil, p.casting = false, 0, nil
              for _, m in pairs(Combat.units) do if m.threat then m.threat = {} end m.inCombat = false end
              C.char.trow = {}
              local ok, why = T.Choose(ri, ci)
              local sp = C.D.spells[sid]
              local passive = Combat.IsPassive(sp)
              local res = { ok = ok, why = why, passive = passive, name = sp.n }
              if passive then
                res.aura = Combat.FindAura(p, sid) ~= nil
                return res
              end
              p.cd, p.gcdUntil = {}, 0
              if p.cooldowns then p.cooldowns = {} end
              p.hp = math.floor(p.hpMax / 2)
              p.power = p.powerType == C.POWER_RAGE and 1000 or p.powerMax
              local u = T_DC.find(6) or T_DC.find(257)
              u.hostile = true
              T_DC.near(u, 2)
              ns.Craft.World.SetTarget(u)
              T_DC.u, T_DC.hp0, T_DC.php0 = u, u.hp, p.hp
              local ok2, err = Combat.CastSpell(p, sid, select(4, ...) == "self" and p or u)
              res.cast, res.err = ok2, err
              return res
            """, ri, ci, sid, TARGET.get(sid, "enemy"))
            if not r["ok"]:
                bad.append((ri, ci, sid, "choose", r))
                continue
            if r["passive"]:
                if not r["aura"]:
                    bad.append((ri, ci, r["name"], "no aura", r))
                continue
            w.tick(4.0)
            after = c.eval_py(r"""
              local sid = ...
              local p, u, Combat = ns.Craft.player, T_DC.u, ns.Craft.Combat
              local onU = false
              for _, a in ipairs(u.auras) do if a.spell == sid or (ns.CraftData.spells[a.spell] and ns.CraftData.spells[a.spell].n == ns.CraftData.spells[sid].n) then onU = true end end
              local onP = false
              for _, a in ipairs(p.auras) do if a.spell == sid then onP = true end end
              return { hit = u.dead or u.hp < T_DC.hp0, onU = onU, onP = onP, healed = p.hp > T_DC.php0 }
            """, sid)
            if not (after["hit"] or after["onU"] or after["onP"] or after["healed"]):
                bad.append((ri, ci, r["name"], "did nothing", r, after))
            c.eval("T_DC.u.dead = false T_DC.u.hp = T_DC.u.hpMax ns.Craft.player.dead = false")
    no_errors(w)
    assert not bad, bad


@case
def every_warrior_choice_works():
    check_class(1)


@case
def every_mage_choice_works():
    check_class(8)


@case
def every_priest_choice_works():
    check_class(5)


if __name__ == "__main__":
    run_all()
