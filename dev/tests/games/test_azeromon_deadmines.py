"""Azeromon step 4: Moonbrook and the Deadmines.

Covers: a bot playing the whole run from Sentinel Hill (west road, Moonbrook, the mine door, Rhahk'Zor, the
foundry with Sneed and Gilnid, Ironclad Cove with Mr. Smite on the bridge, VanCleef refusing until his crew is
beaten, Greenskin, Cookie, VanCleef's badge, Gryan's ending); bosses leave the passage and stay gone; "X joins the
fight!" for a boss's own creature; wild beasts on any cave floor; Kobling evolving into the Kobold Tunneler; bosses
not counting toward the Bestiary; the mine tiles (rock, rails, water) and the Deadmines achievements.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_deadmines.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def game(seed=11):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    c.eval("""local M = ns.AzeroMon
      local m = M.New('murkling', 45, ns.Azero.rng); m.moves = M.DefaultMoves('murkling', 45)
      local e = M.New('emberwhelp', 45, ns.Azero.rng); e.moves = M.DefaultMoves('emberwhelp', 45)
      ns.Azero.save.party = { m, e }""")
    return w, c


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


@case
def the_whole_deadmines_run():
    w, c = game()
    r = c.eval_py(r"""
      local G, M = ns.Azero, ns.AzeroMon
      local trace = {}
      local function heal() for _, mon in ipairs(G.save.party) do M.Heal(mon) end end
      local function go(x, y, label)
        local ok, why = T_AZ.walkTo(x, y)
        trace[#trace + 1] = label .. "=" .. tostring(ok) .. "@" .. G.save.map .. " " .. G.save.x .. "," .. G.save.y
        return ok
      end
      local function talk(face) T_AZ.face(face) G:PressA() T_AZ.settle() heal() end
      G:EnterMap('sentinel', 2, 9, 'left', true)
      go(0, 9, "sentinel west")
      T_AZ.step("left")                          -- -> Moonbrook
      local mb = G.save.map
      go(2, 7, "mine door")
      T_AZ.step("up")                            -- the mine door -> the Deadmines
      local dm1 = G.save.map
      heal()
      go(3, 12, "rhahkzor") talk("down")
      go(3, 14, "down to the foundry")
      local dm2 = G.save.map
      heal()
      go(12, 7, "sneed") talk("down")
      go(17, 12, "gilnid") talk("right")
      go(21, 14, "down to the cove")
      local dm3 = G.save.map
      heal()
      go(9, 10, "smite") talk("right")
      go(22, 9, "vancleef too early") talk("right")
      local early = G:Flag("beat_vancleef")
      go(18, 8, "greenskin") talk("up")
      go(13, 13, "cookie") talk("down")
      go(22, 9, "vancleef") talk("right")
      local ach = {}
      for id in pairs(ns.AzeroAch.Earned()) do ach[#ach + 1] = id end
      G:EnterMap('sentinel', 11, 7, 'up', true)
      G:PressA() T_AZ.settle()
      return { mb = mb, dm1 = dm1, dm2 = dm2, dm3 = dm3, early = early or false, trace = trace, ach = ach,
               badge = G:Flag("badge_vancleef") or false, badges = G:BadgeCount() }
    """)
    assert (r["mb"], r["dm1"], r["dm2"], r["dm3"]) == ("moonbrook", "dm1", "dm2", "dm3"), r
    assert r["early"] is False, r
    assert r["badge"] is True and r["badges"] >= 1, r
    for a in ("vancleef", "dmbosses"):
        assert a in r["ach"], r
    text = log(c)
    for needle in ("Rhahk'Zor joins the fight!", "Sneed sent out Sneed's Shredder!", "You'll have to get past my crew first",
                   "retreats deeper into the mine", "VanCleef's Bandana", "The Brotherhood is broken"):
        assert needle in text, (needle, r["trace"])
    no_errors(w)


@case
def beaten_bosses_stay_gone():
    w, c = game()
    c.eval("ns.Azero:SetFlag('beat_rhahkzor') ns.Azero:EnterMap('dm1', 3, 12, 'down', true)")
    hidden = c.eval("for _, n in ipairs(ns.Azero.npcs) do if n.id == 'rhahkzor' then return n.hidden end end")
    assert hidden is True
    # and the doorway is free: the ladder beyond can be reached
    assert c.eval("return ns.Azero:Blocked(3, 13)") is False
    no_errors(w)


@case
def wild_beasts_on_any_cave_floor():
    w, c = game()
    r = c.eval_py("""local G = ns.Azero
      G:EnterMap('dm1', 21, 12, 'up', true)
      local real = G.rng
      G.rng = function(a, b) if a == 1 and b == 100 then return 1 end return real(a, b) end   -- always an encounter
      local res = G:TryStep('up')
      for i = 1, 20 do if G.moving then G:Update(0.05) end end
      G.rng = real
      local b = G.pending and G.pending.battle
      return { res = res, battle = b ~= nil, wild = b and b.wild, sp = b and b.foe.mon.sp }""")
    assert r["res"] == "moved" and r["battle"] and r["wild"], r
    assert r["sp"] in ("tunneler", "minespider", "kobling", "webling"), r
    no_errors(w)


@case
def data_kobling_evolves_and_bosses_are_not_in_the_bestiary():
    w, c = game()
    r = c.eval_py("""local D = ns.AzeroData
      local ids = ns.AzeroGuild.CompletableIds()
      local has = {}
      for _, id in ipairs(ids) do has[id] = true end
      return { evo = D.species.kobling.evolve.into, hogger = has.hogger or false, vancleef = has.vancleef or false,
               tunneler = has.tunneler or false, shredder = has.shredder or false }""")
    assert r == {"evo": "tunneler", "hogger": False, "vancleef": False, "tunneler": True, "shredder": True}, r
    # the mine tiles: rock is solid, rails walkable with a rail on top, cove water uses the dark water frames
    t = c.eval_py("""local m = ns.Azero.Compile('dm1')
      local k = m.key
      local m3 = ns.Azero.Compile('dm3')
      return { rockSolid = m.solid[k(0, 0)] == true, rock = m.base[k(0, 0)], railOver = m.over[k(10, 4)],
               railSolid = m.solid[k(10, 4)] or false, vRail = m.over[k(22, 8)], cross = m.over[k(22, 4)],
               water = m3.water[m3.key(5, 5)] == true, deck = m3.base[m3.key(15, 10)], floor = m.base[k(10, 3)] }""")
    assert t["rockSolid"] and t["rock"] == "mwall" and t["railOver"] == "rail_h" and t["railSolid"] is False, t
    assert t["vRail"] == "rail_v" and t["cross"] == "rail_x" and t["water"] and t["deck"] == "deck", t
    assert t["floor"] in ("mfloor1", "mfloor2"), t
    no_errors(w)


if __name__ == "__main__":
    run_all()
