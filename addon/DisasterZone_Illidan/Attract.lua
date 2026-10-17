if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Illidan/Attract.lua", ...) then return end -- DisasterZone_Illidan/Attract.lua
-- ns.BoIAttract: The Binding of Illidan playing itself, for the hub's poster (the game's own engine and renderer,
-- like Azeromon's walk through Elwynn). Scenes cycle: a fight in a room of a random floor, then a boss with its raid
-- mechanics; your class, a few items for the colour, god mode (the demo never dies). Input(run) is a small fighter:
-- it dodges what is about to land, keeps its distance (runs from what is fast or big), slides along walls and shoots
-- along the axis the nearest enemy is on.
local _, ns = ...

local D, E = ns.BoIData, ns.BoI
local A = {}
ns.BoIAttract = A

local abs, max, min, sqrt, floor = math.abs, math.max, math.min, math.sqrt, math.floor

local function Hyp(x, y) return sqrt(x * x + y * y) end

function A.Input(run)
    local p, room = run.p, run.room
    local mx, my, shoot = 0, 0, nil
    local function Away(x, y, r, w)
        local dx, dy = p.x - x, p.y - y
        local d = max(1, Hyp(dx, dy))
        if d < r then mx, my = mx + dx / d * w * (1 - d / r + 0.3), my + dy / d * w * (1 - d / r + 0.3) end
    end
    for _, h in ipairs(run.hz or {}) do Away(h.x, h.y, h.r + 30, 3) end
    for _, q in ipairs(run.patches or {}) do Away(q.x, q.y, q.r + 22, 2) end
    for _, s in ipairs(run.shots) do
        local dx, dy = p.x - s.x, p.y - s.y
        local d = Hyp(dx, dy)
        local sp = max(0.01, Hyp(s.vx, s.vy))
        if d < 150 and (dx * s.vx + dy * s.vy) > 0 and abs(dx * s.vy - dy * s.vx) / sp < p.r + s.r + 10 then
            local px, py = -s.vy, s.vx
            if px * dx + py * dy < 0 then px, py = -px, -py end
            local l = max(0.01, Hyp(px, py))
            local w = 2.2 * (1 - d / 150) + 0.6
            mx, my = mx + px / l * w, my + py / l * w
        end
    end
    local target, td
    for _, f in ipairs(room.foes) do
        local d = Hyp(f.x - p.x, f.y - p.y)
        if not f.immune and (not f.spiritOnly or run.spirit) and (not td or d < td) then target, td = f, d end
        local reach = f.r + p.r + ((f.kind == "boss" or (f.spd or f.d.sp or 0) > 1.5 or f.d.ai == "dash") and 70 or 30)
        if d < reach and not f.noTouch then
            local dx, dy = p.x - f.x, p.y - f.y
            local dd = max(1, d)
            mx, my = mx + dx / dd * 2.4, my + dy / dd * 2.4
            local cx, cy = E.CX - p.x, E.CY - p.y
            local cl = max(1, Hyp(cx, cy))
            mx, my = mx + cx / cl * 0.8, my + cy / cl * 0.8
        end
    end
    if target then
        local dx, dy = target.x - p.x, target.y - p.y
        local d = max(1, Hyp(dx, dy))
        local want = target.kind == "boss" and 170 or 130
        local k = (d - want) / want
        mx, my = mx + dx / d * k * 1.2, my + dy / d * k * 1.2
        local s = (run.frame % 600 < 300) and 1 or -1
        mx, my = mx - dy / d * 0.6 * s, my + dx / d * 0.6 * s
        if abs(dx) >= abs(dy) then shoot = dx > 0 and "right" or "left" else shoot = dy > 0 and "down" or "up" end
        if run.cast and run.cubes then   -- Blast Nova: hold a cube
            local best, bd
            for _, c in ipairs(run.cubes) do
                local dd = Hyp(c.x - p.x, c.y - p.y)
                if c.ex == 0 and (not bd or dd < bd) then best, bd = c, dd end
            end
            if best then mx, my = (best.x - p.x) / max(1, bd), (best.y - p.y) / max(1, bd) end
        end
    end
    if #room.foes > 0 then
        local wall, edge = 46, 30
        if p.x < E.X0 + wall then mx = mx + 1 end
        if p.x > E.X1 - wall then mx = mx - 1 end
        if p.y < E.Y0 + wall then my = my + 1 end
        if p.y > E.Y1 - wall then my = my - 1 end
        if (p.x < E.X0 + edge and mx < 0) or (p.x > E.X1 - edge and mx > 0) then mx, my = 0, my + (p.y < E.CY and 1.2 or -1.2) end
        if (p.y < E.Y0 + edge and my < 0) or (p.y > E.Y1 - edge and my > 0) then my, mx = 0, mx + (p.x < E.CX and 1.2 or -1.2) end
    end
    local l = Hyp(mx, my)
    if l > 1 then mx, my = mx / l, my / l end
    return { mx = mx, my = my, shoot = shoot }
end

-- the scenes, in turn: three rooms, then a boss (of the floor after the last one shown)
local LOOKS = { { "eye", "chain" }, { "orb", "fiend" }, { "sulfuras", "mongoose" }, { "glaive" }, { "poly", "elemental" } }
local nextFloor, count = 1, 0

-- a new scene: { run, until (seconds it lasts), kind }
function A.NewScene(class)
    count = count + 1
    local boss = count % 4 == 0
    local fl = boss and nextFloor or ((count * 3) % #D.FLOORS) + 1
    if boss then nextFloor = nextFloor % #D.FLOORS + 1 end
    local run = E.New({ class = class, seed = floor((time and time() or 0) % 100000) * 7 + count * 131 })
    run.god = true
    if fl > 1 then E.EnterFloor(run, fl) end
    for _, k in ipairs(LOOKS[(count % #LOOKS) + 1]) do E.GiveItem(run, k, true) end
    run.mode = "play"
    local room
    for _, r in ipairs(run.map.list) do
        if (boss and r.type == "boss") or (not boss and not room and r.type == "normal" and r ~= run.map.start) then room = r end
    end
    local nb = room and E.Neighbours(run.map, room, true)[1]
    if nb then
        run.room = nb.room
        run.room.cleared, run.room.visited = true, true
        E.ChangeRoom(run, E.OPP[nb.dir])
    end
    run.mode, run.fade = "play", 0
    if boss and run.bossF then run.bossF.hp = run.bossF.max * (0.35 + 0.6 * ((count * 0.37) % 1)) end   -- (a later phase now and then)
    return { run = run, left = boss and 16 or 13, boss = boss }
end
