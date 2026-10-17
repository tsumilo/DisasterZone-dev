"""Azeromon balance check: every boss fight, played many times by the real battle engine.

A party of three beasts (random types, each in the form it would have at that level, the type kit it would know)
(as many as the boss brings, at least three) meets each boss trainer's team two levels above its ace, with no items. One side presses the strongest move (the
masher); the other plays the rule list (B:Rotation, what the coach suggests). The boss's own HP number
(D.BOSS_HP[ace], or D.TEAM_HP[trainer] when an ordinary beast leads) is swept so each boss can be set where reading the fight matters and mashing loses more often.

Run: luaenv\\Scripts\\python.exe tests\\games\\azero_balance.py [-n fights] [-k boss] [--over levels]
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import solo  # noqa: E402

SIM = r"""
local G, M, B, D = ns.Azero, ns.AzeroMon, ns.AzeroBattle, ns.AzeroData
G:NewGame()
local seed = 7
local function rng(a, b)
  seed = (seed * 1103515245 + 12345) % 2147483648
  local r = seed / 2147483648
  if not b then a, b = 1, a end
  return a + math.floor(r * (b - a + 1))
end
-- the forms a player can have at `lvl`: no boss, no legendary, not yet evolved past
local into = {}
for id, s in pairs(D.species) do if s.evolve and s.evolve.into then into[s.evolve.into] = s.evolve.level or 0 end end
function SIM_POOL(lvl)
  local pool = {}
  for id, s in pairs(D.species) do
    if not s.boss and not s.legendary and (not D.TYPE_KIT or D.TYPE_KIT[s.type])
       and (not s.evolve or not s.evolve.level or s.evolve.level > lvl) and (into[id] or 0) <= lvl then
      pool[#pool + 1] = id
    end
  end
  table.sort(pool)
  return pool
end
local function Party(lvl, pool, size)
  local party, types = {}, {}
  for _ = 1, 200 do
    local sp = pool[rng(1, #pool)]
    local t = D.species[sp].type
    if not types[t] then
      types[t] = true
      local m = M.New(sp, lvl, rng)
      m.moves = M.DefaultMoves(sp, lvl)
      party[#party + 1] = m
      if #party == size then break end
    end
  end
  return party
end
local function Masher(b)
  local mon, best, bestScore = b.ally.mon, nil, -1
  for i, mv in ipairs(mon.moves) do
    if mv.pp > 0 and (not b.Usable or b:Usable("ally", i)) then
      local md = D.moves[mv.id]
      local score = md.power * D.Effectiveness(md.type, D.species[b.foe.mon.sp].type)
      if score > bestScore then best, bestScore = i, score end
    end
  end
  return best or 1
end
local function Reader(b)
  if not b.Rotation then return Masher(b) end      -- (an engine from before 0.36)
  local usable = {}
  for i in ipairs(b.ally.mon.moves) do if b:Usable("ally", i) then usable[#usable + 1] = i end end
  if #usable == 0 then return 1 end
  return b:Rotation("ally", usable)
end
local function Fight(id, lvl, pool, policy)
  local def = D.trainers[id]
  local foes = {}
  for i, e in ipairs(def.team) do foes[i] = M.New(e[1], e[2], rng) end
  local b = B.New({ party = Party(lvl, pool, math.max(SIM_SIZE or 3, #def.team)), foes = foes, wild = false, trainer = G:TrainerDef(id), rng = rng })
  for _ = 1, 3000 do
    while b:Pop() do end
    if b.need == "done" then return b.result, b.turn end
    if b.need == "action" then
      if b.ally.cast or not b:Act({ kind = "move", idx = policy(b) }) then b:Act({ kind = "move", idx = Masher(b) }) end
    elseif b.need == "switch" then
      for i, m in ipairs(b.party) do if m.hp > 0 then b:Act({ kind = "switch", idx = i }) break end end
    elseif b.need == "learn" then
      b:ResolveLearn(nil)
    else
      return "stuck", b.turn
    end
  end
  return "stuck", 0
end
function SIM_BOSS(id, over, n, scales)
  local def = D.trainers[id]
  local ace = def.team[#def.team]
  local lvl = ace[2] + over
  local pool = SIM_POOL(lvl)
  local out = { id = id, ace = ace[1], lvl = lvl, boss = D.species[ace[1]].boss and true or false, rows = {} }
  -- a boss beast's own number, or (an ordinary beast leads) the whole team's (D.TEAM_HP; engines from 0.36)
  local tab = out.boss and "BOSS_HP" or "TEAM_HP"
  local key = out.boss and ace[1] or id
  D[tab] = D[tab] or {}
  local keep = D[tab][key]
  for _, sc in ipairs((D.BATTLE_HP and scales) or { 1 }) do
    D[tab][key] = sc
    local row = { scale = sc }
    for _, p in ipairs({ { "mash", Masher }, { "read", Reader } }) do
      local wins, turns = 0, 0
      for k = 1, n do
        seed = k * 7919 + #id
        local r, t = Fight(id, lvl, pool, p[2])
        if r == "win" then wins = wins + 1 end
        turns = turns + (t or 0)
      end
      row[p[1]] = math.floor(wins * 100 / n + 0.5)
      row[p[1] .. "T"] = math.floor(turns * 10 / n + 0.5) / 10
    end
    out.rows[#out.rows + 1] = row
  end
  D[tab][key] = keep
  return out
end
function SIM_BOSSES()
  local ids = {}
  for id, t in pairs(D.trainers) do
    if t.class == "boss" and type(t.team) == "table" then ids[#ids + 1] = id end
  end
  table.sort(ids, function(a, b)
    local x, y = D.trainers[a].team, D.trainers[b].team
    return x[#x][2] < y[#y][2]
  end)
  return ids
end
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=120)
    ap.add_argument("-k", default="")
    ap.add_argument("--over", type=int, default=2)
    ap.add_argument("--party", type=int, default=3, help="party size (at least the boss's team size)")
    ap.add_argument("--scales", default="1.6,1.3,1.0,0.8")
    a = ap.parse_args()
    w, c = solo("Alice", tick=2)
    if c.eval("return ns.AzeroUI ~= nil"):
        c.eval("ns.AzeroUI.tipsOff = true")
    c.eval(SIM)
    c.eval("SIM_SIZE = %d" % a.party)
    ids = c.eval_py("return SIM_BOSSES()")
    scales = "{ %s }" % a.scales
    print("%-14s %-14s %4s  %s" % ("boss", "ace", "you", "scale: mash%/turns  read%/turns"))
    for id in ids:
        if a.k and a.k not in id:
            continue
        r = c.eval_py("return SIM_BOSS(%r, %d, %d, %s)" % (id, a.over, a.n, scales))
        cells = "  ".join("x%.1f: %3d/%4.1f %3d/%4.1f" % (x["scale"], x["mash"], x["mashT"], x["read"], x["readT"])
                          for x in r["rows"])
        print("%-14s %-14s %4d  %s%s" % (id, r["ace"], r["lvl"], cells, "" if r["boss"] else "  (whole team)"),
              flush=True)


if __name__ == "__main__":
    main()
