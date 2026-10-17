"""Lua-side bot shared by the Azeromon suites (installed with c.eval(BOT))."""
BOT = r"""
local G, D, M = ns.Azero, ns.AzeroData, ns.AzeroMon
if ns.AzeroUI then ns.AzeroUI.tipsOff = true end      -- one-time tips would interrupt the scripted tests
T_AZ = { log = {}, choice = 1 }
function T_AZ.seed(n)
  local s = n
  G.rng = function(a, b)
    s = (s * 1103515245 + 12345) % 2147483648
    local r = s / 2147483648
    if not b then a, b = 1, a end
    return a + math.floor(r * (b - a + 1))
  end
end
function T_AZ.bestMove(b)
  local mon, best, bestScore = b.ally.mon, nil, -1
  for i, mv in ipairs(mon.moves) do
    if mv.pp > 0 and (not b.Usable or b:Usable("ally", i)) then      -- (0.37: never a move that is resting)
      local md = D.moves[mv.id]
      local score = md.power * D.Effectiveness(md.type, D.species[b.foe.mon.sp].type)
      if score > bestScore then best, bestScore = i, score end
    end
  end
  return best or 1
end
-- a player who reads the fight: the rule list the coach uses (set T_AZ.policy = T_AZ.reader for a whole suite)
function T_AZ.reader(b)
  if not b.Rotation then return nil end
  local usable = {}
  for i in ipairs(b.ally.mon.moves) do if b:Usable("ally", i) then usable[#usable + 1] = i end end
  if #usable == 0 then return nil end
  return { kind = "move", idx = b:Rotation("ally", usable) }
end
function T_AZ.fight(b, policy)
  policy = policy or T_AZ.policy
  for _ = 1, 2000 do
    local e = b:Pop()
    while e do
      if e.t == "text" then T_AZ.log[#T_AZ.log + 1] = e.text end
      e = b:Pop()
    end
    if b.need == "done" then return b.result end
    if b.need == "action" then
      local act = policy and policy(b)
      if not act then act = { kind = "move", idx = T_AZ.bestMove(b) } end
      if not b:Act(act) then b:Act({ kind = "move", idx = T_AZ.bestMove(b) }) end
    elseif b.need == "switch" then
      for i, m in ipairs(b.party) do if m.hp > 0 then b:Act({ kind = "switch", idx = i }) break end end
    elseif b.need == "learn" then
      b:ResolveLearn(T_AZ.learnSlot)
    end
  end
  error("battle did not finish")
end
function T_AZ.settle(policy)
  for _ = 1, 5000 do
    local p = G.pending
    if not p then
      if G.co or G.moving then G:Update(0.05) else return end
    elseif p.kind == "text" then T_AZ.log[#T_AZ.log + 1] = p.text G:Advance()
    elseif p.kind == "choice" then G:Advance(T_AZ.choice)
    elseif p.kind == "shop" then G:Advance()
    elseif p.kind == "battle" then
      local r = T_AZ.fight(p.battle, policy)
      T_AZ.battles = (T_AZ.battles or 0) + 1
      G:Advance(r)
    else G:Update(0.05) end
  end
  error("script did not settle")
end
-- One step (TryStep + let it finish). Returns the TryStep result.
function T_AZ.step(dir)
  T_AZ.settle()
  local r = G:TryStep(dir)
  for _ = 1, 40 do
    if not G.moving then break end
    G:Update(0.05)
  end
  return r
end
-- BFS path on the current map to (tx, ty); walks it, settling any script / battle on the way.
-- Returns true when the player stands on (tx, ty) or the map changed because (tx, ty) is a warp.
function T_AZ.walkTo(tx, ty, maxRetries)
  for _ = 1, (maxRetries or 8) do
    T_AZ.settle()
    local m, s = G.map, G.save
    if s.x == tx and s.y == ty then return true end
    local startMap = m.id
    local prev, seen = {}, {}
    local q, head = { { s.x, s.y } }, 1
    seen[m.key(s.x, s.y)] = true
    local found
    while head <= #q do
      local x, y = q[head][1], q[head][2]
      head = head + 1
      if x == tx and y == ty then found = true break end
      for dir, d in pairs(G.DIRS) do
        local nx, ny = x + d[1], y + d[2]
        local k = m.key(nx, ny)
        local ok = nx >= 0 and ny >= 0 and nx < m.w and ny < m.h and not m.solid[k] and not seen[k]
        if ok and (G:NpcAt(nx, ny) or G:SolidNode(nx, ny)) then ok = false end   -- people and ore veins block
        if ok and m.warp[k] and not (nx == tx and ny == ty) then ok = false end
        if ok then seen[k] = true prev[k] = { x, y, dir } q[#q + 1] = { nx, ny } end
      end
    end
    if not found then return false, "no path" end
    local path, x, y = {}, tx, ty
    while not (x == s.x and y == s.y) do
      local p = prev[m.key(x, y)]
      table.insert(path, 1, p[3])
      x, y = p[1], p[2]
    end
    local interrupted = false
    for _, dir in ipairs(path) do
      local r = T_AZ.step(dir)
      if G.map.id ~= startMap then T_AZ.settle() return true end
      if r ~= "moved" or G.pending or G.co then interrupted = true break end
    end
    T_AZ.settle()
    if G.map.id ~= startMap then return true end
    if G.save.x == tx and G.save.y == ty then return true end
  end
  return false, "gave up"
end
function T_AZ.face(dir) G.save.face = dir end
"""
