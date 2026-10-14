"""A bot that plays The Binding of Illidan headless (ns.BoI), for the tests and the balance runs.

T_BOI.Input(run) -> the input table for one frame: dodge what is about to land (telegraphs, fire, shots), keep a
fighting distance from the nearest enemy and shoot along the axis it is on; with the room clear take what lies
there, then walk to the next room (unvisited first, the boss last, the vault when it has a key) and down the
trapdoor. It is no expert: good enough to finish a run with god mode and to compare fights with each other.
T_BOI.Play(run, frames) steps the run with it; T_BOI.Fight(run, key, frames) puts the run in front of a boss.
"""

BOT_LUA = r"""
T_BOI = T_BOI or {}
local E, D = ns.BoI, ns.BoIData
local abs, max, min, sqrt, atan2, cos, sin = math.abs, math.max, math.min, math.sqrt, math.atan2, math.cos, math.sin

local function Hyp(x, y) return sqrt(x * x + y * y) end

local function NextDir(run)
  -- BFS over the open rooms; the target: the nearest unvisited room, else the boss's
  local map, from = run.map, run.room
  local prev, q, qi = { [from] = false }, { from }, 1
  while q[qi] do
    local r = q[qi]
    qi = qi + 1
    for _, nb in ipairs(E.Neighbours(map, r)) do
      local o = nb.room
      if prev[o] == nil and (not o.locked or run.keys > 0) and not (o.type == "boss" and o.visited and o.cleared and o ~= from and false) then
        prev[o] = { r, nb.dir }
        q[#q + 1] = o
      end
    end
  end
  local target
  for i = 2, #q do
    local o = q[i]
    if not o.visited and o.type ~= "boss" then target = o break end
  end
  if not target then for i = 2, #q do if q[i].type == "boss" then target = q[i] break end end end
  if not target then return nil end
  local r, dir = target, nil
  while prev[r] and prev[r][1] do
    dir = prev[r][2]
    if prev[r][1] == from then break end
    r = prev[r][1]
  end
  return dir
end
T_BOI.NextDir = NextDir

function T_BOI.Input(run)
  local p, room = run.p, run.room
  local mx, my, shoot = 0, 0, nil
  -- threats: push away from each (weighted by closeness)
  local function Away(x, y, r, w)
    local dx, dy = p.x - x, p.y - y
    local d = max(1, Hyp(dx, dy))
    if d < r then mx, my = mx + dx / d * w * (1 - d / r + 0.3), my + dy / d * w * (1 - d / r + 0.3) end
  end
  for _, h in ipairs(run.hz or {}) do Away(h.x, h.y, h.r + 30, 3) end
  for _, q in ipairs(run.patches or {}) do Away(q.x, q.y, q.r + 22, 2) end
  for _, s in ipairs(run.shots) do
    -- a shot coming at you: step across its path (the closer it would pass, the harder)
    local dx, dy = p.x - s.x, p.y - s.y
    local d = Hyp(dx, dy)
    local sp = max(0.01, Hyp(s.vx, s.vy))
    if d < 150 and (dx * s.vx + dy * s.vy) > 0 then
      local miss = abs(dx * s.vy - dy * s.vx) / sp     -- how far from you its line passes
      if miss < p.r + s.r + 10 then
        local px, py = -s.vy, s.vx
        if px * dx + py * dy < 0 then px, py = -px, -py end
        local l = max(0.01, Hyp(px, py))
        local w = 2.2 * (1 - d / 150) + 0.6
        mx, my = mx + px / l * w, my + py / l * w
      end
    end
  end
  -- anything fast or big coming close: run (kiting), and keep off the walls
  for _, f in ipairs(room.foes) do
    local dx, dy = p.x - f.x, p.y - f.y
    local d = max(1, Hyp(dx, dy))
    local reach = f.r + p.r + ((f.kind == 'boss' or (f.spd or f.d.sp or 0) > 1.5 or f.d.ai == 'dash') and 70 or 30)
    if d < reach and not f.noTouch and not run.spirit then
      mx, my = mx + dx / d * 2.4, my + dy / d * 2.4
      -- along the wall rather than into it: turn the escape round the room's middle
      local cx, cy = E.CX - p.x, E.CY - p.y
      local cl = max(1, Hyp(cx, cy))
      mx, my = mx + cx / cl * 0.8, my + cy / cl * 0.8
    end
  end
  if #room.foes > 0 then   -- (in a fight; a clear room's doors are on the walls)
    local wall = 46
    if p.x < E.X0 + wall then mx = mx + 1 end
    if p.x > E.X1 - wall then mx = mx - 1 end
    if p.y < E.Y0 + wall then my = my + 1 end
    if p.y > E.Y1 - wall then my = my - 1 end
  end
  if run.beam then Away((run.beam.ax + run.beam.bx) / 2, (run.beam.ay + run.beam.by) / 2, 60, 1) end
  local target, td
  for _, f in ipairs(room.foes) do
    local d = Hyp(f.x - p.x, f.y - p.y)
    if not f.immune and (not f.spiritOnly or run.spirit) and (not td or d < td) then target, td = f, d end
  end
  if not target then for _, f in ipairs(room.foes) do target = target or f end end
  if target then
    local dx, dy = target.x - p.x, target.y - p.y
    local d = max(1, Hyp(dx, dy))
    local want = target.kind == "boss" and 170 or 130
    local k = (d - want) / want
    mx, my = mx + dx / d * k * 1.2, my + dy / d * k * 1.2
    -- strafe round it
    local s = (run.frame % 600 < 300) and 1 or -1
    mx, my = mx - dy / d * 0.6 * s, my + dx / d * 0.6 * s
    -- shoot when it is near an axis
    if abs(dx) >= abs(dy) then shoot = dx > 0 and "right" or "left" else shoot = dy > 0 and "down" or "up" end
    -- the cubes: hold one while Blast Nova is cast
    if run.cast and run.cubes then
      local best, bd
      for _, c in ipairs(run.cubes) do
        local dd = Hyp(c.x - p.x, c.y - p.y)
        if c.ex == 0 and (not bd or dd < bd) then best, bd = c, dd end
      end
      if best then mx, my = (best.x - p.x) / max(1, bd) * (bd > 6 and 1 or 0), (best.y - p.y) / max(1, bd) * (bd > 6 and 1 or 0) end
    end
    -- Maiev's trap: stand behind it so Illidan walks over it
    if run.maiev and target.kind == "boss" then
      for _, t in ipairs(run.traps) do
        if t.forBoss and t.arm <= 0 then
          local bx, by = t.x + (t.x - target.x) * 0.8, t.y + (t.y - target.y) * 0.8
          bx, by = E.Clamp(bx, by, 20)
          local l = max(1, Hyp(bx - p.x, by - p.y))
          if l > 8 then mx, my = mx + (bx - p.x) / l * 1.5, my + (by - p.y) / l * 1.5 end
        end
      end
    end
  elseif room.cleared then
    -- take what lies here, then go on
    local goal
    local ped = (room.type == "treasure" or room.type == "secret") and room.item and { x = E.CX, y = E.CY - 30 } or (room.item and room.pedestal)
    if ped then goal = ped end
    if not goal and room.deal and room.deal.item and room.deal.kind == "naaru" then goal = room.deal end
    if not goal then
      for _, k in ipairs(room.pickups) do
        if k.kind ~= "heart" or run.hp < run.maxHp * 2 then goal = k break end
      end
    end
    if not goal and room.trapdoor then goal = room.trapdoor end
    if not goal then
      local dir = NextDir(run)
      if dir then
        local dp = E.DOOR[dir]
        goal = { x = dp[1] + E.DIRS[dir][1] * 30, y = dp[2] + E.DIRS[dir][2] * 30 }
      end
    end
    if goal then
      local dx, dy = goal.x - p.x, goal.y - p.y
      local d = max(1, Hyp(dx, dy))
      mx, my = dx / d, dy / d
    end
  end
  -- against a wall in a fight: slide along it towards the room's middle rather than push into it
  if #room.foes > 0 then
    local edge = 30
    if (p.x < E.X0 + edge and mx < 0) or (p.x > E.X1 - edge and mx > 0) then
      mx = 0
      my = my + (p.y < E.CY and 1.2 or -1.2)
    end
    if (p.y < E.Y0 + edge and my < 0) or (p.y > E.Y1 - edge and my > 0) then
      my = 0
      mx = mx + (p.x < E.CX and 1.2 or -1.2)
    end
  end
  local l = Hyp(mx, my)
  if l > 1 then mx, my = mx / l, my / l end
  return { mx = mx, my = my, shoot = shoot, bomb = false }
end

function T_BOI.Play(run, frames, until_mode)
  for _ = 1, frames do
    if run.mode == "dead" or run.mode == "won" then break end
    E.Step(run, T_BOI.Input(run))
  end
  return run.mode
end

-- put the run in its floor's boss room (the boss's card skipped)
function T_BOI.Fight(run, floorN)
  if floorN and floorN ~= run.floorN then E.EnterFloor(run, floorN) end
  run.mode = "play"
  local boss
  for _, r in ipairs(run.map.list) do if r.type == "boss" then boss = r end end
  local nb = E.Neighbours(run.map, boss, true)[1]
  run.room = nb.room
  run.room.cleared, run.room.visited = true, true
  E.ChangeRoom(run, E.OPP[nb.dir])
  run.mode = "play"
  return run.bossF
end
"""
