if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/World.lua", ...) then return end -- DisasterZone Games/Disastercraft/World.lua
-- Craft.World: the map you walk (the real Northshire from Games/Azeromon/World: ns.AzeroLand + its entities), free
-- movement with collision, the buildings' insides, and everything that lives there: NPCs where they stand in WoW,
-- critters, and creatures with WoW's behaviour - they wander their spawn radius, notice you inside their aggro
-- range (20 yards at an even level, a yard less for each level you are above them), call nearby friends, chase
-- you, swing, cast what their script casts, flee when their script says so, give up when dragged too far from home
-- (evade: back home, full health), die, leave a corpse to loot, and come back after their real respawn time.
--
-- Idle wandering is a pure function of the spawn and the realm clock, so every guildmate sees the same kobold at
-- the same spot without a word on the network; only creatures in a fight are simulated (by the party leader).
local addonName, ns = ...

local Craft = ns.Craft
local D = Craft.D
local Combat = Craft.Combat
local World = {}
Craft.World = World

local WS = ns.AzeroLand
local W = ns.AzeroWorldData

local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt
local Now = Craft.Now
local YARDS = Craft.YARDS

World.recs = {}                 -- guid -> { e = spawn, unit = combat unit (creatures), kind, ... }
World.objects = {}              -- objects (quest crates, herbs, ore, chests)
World.authority = true          -- this client simulates creatures in fights (alone: yes; in a party: the leader)
World.input = { dx = 0, dy = 0 }
local ACTIVE = 40               -- tiles around a player in which creatures think

---------------------------------------------------------------------------
-- The clock all clients share (realm time, smooth)
---------------------------------------------------------------------------

local clockBase, clockAt
function World.Clock()
    local now = Now()
    if not clockBase then clockBase, clockAt = Craft.Time(), now end
    return clockBase + (now - clockAt)
end

---------------------------------------------------------------------------
-- Walking: the world's ground, and buildings walked in place
---------------------------------------------------------------------------
-- Outdoors a body stands on the ground (u.e = nil) and the world's ~1 yd collision cells stop it (WS.SolidAt). A
-- building with rooms has its own walk grid over its footprint (WS.Layers: per fine cell every height a body may
-- stand at, and which layer of each neighbour it leads to), so inside one a body has a height u.e (yards over the
-- building's origin) and its building u.bld: it walks up a stair because the stair's cells rise a little each,
-- a wall stops it because no link crosses it, and it walks out of the door because the doorway's cells link to
-- the ground outside. Plain ground inside a grid (no layers) follows the outdoor rules.

local SUB = WS.SUB
local DXS, DYS = { 0, 1, 0, -1 }, { -1, 0, 1, 0 }        -- the link directions n e s w
local OPP = { 3, 4, 1, 2 }

-- the index of the layer at height e in a cell's layers (the nearest within reach), or nil
local function LayerAt(lay, e, reach)
    local best, bd
    for k = 1, #lay do
        local d = abs(lay[k].h - e)
        if not bd or d < bd then best, bd = k, d end
    end
    if best and bd <= (reach or 0.75) then return best end
    return nil
end

-- where a body at (x, y) stands: its building and layer index (nil, nil outdoors). e: its height (nil: on the
-- ground - the grid's terrain layer there, else its lowest)
local function Settle(x, y, e, b)
    local bb, cx, cy = WS.BuildingAt(x, y)
    if not bb then return nil, nil end
    local lay = WS.Layers(bb, cx, cy)
    if #lay == 0 then return nil, nil end
    if e ~= nil and (b == nil or b == bb) then
        local k = LayerAt(lay, e, 1e9)
        return bb, k
    end
    for k = 1, #lay do if lay[k].ter then return bb, k end end
    return bb, 1
end

-- the unit's height and building at its spot (spawns, teleports, saved spots)
function World.Settle(u, e)
    if type(e) ~= "number" then e = nil end
    local b, k = Settle(u.x, u.y, e, u.bld)
    if b then
        local cx, cy = floor(u.x * SUB), floor(u.y * SUB)
        u.bld, u.e = b, WS.Layers(b, cx, cy)[k].h
    else
        u.bld, u.e = nil, nil
    end
end

-- one cell over (direction d) from cell (cx, cy) for a body on layer li of building b (b nil: on the ground):
-- ok, and the building / layer it stands on there
local function CellStep(b, li, cx, cy, d)
    local nx, ny = cx + DXS[d], cy + DYS[d]
    if b and li then
        local l = WS.Layers(b, cx, cy)[li]
        local link = l and l[d]
        if link == nil then return false end
        if link == 0 then return true, nil, nil end          -- (out onto the ground)
        return true, b, link
    end
    local b2 = WS.BuildingAt((nx + 0.5) / SUB, (ny + 0.5) / SUB)
    if not b2 then return true, nil, nil end
    local lay = WS.Layers(b2, nx, ny)
    if #lay == 0 then return true, nil, nil end
    for k = 1, #lay do
        if lay[k][OPP[d]] == 0 then return true, b2, k end   -- (a layer the ground leads onto)
    end
    return false
end

-- the foot outdoors where the fine collision cells are: a body's half width in WoW (~0.5 yd), sampled round it
local FOOT = 0.12
local RING = {}
for k = 0, 7 do RING[#RING + 1] = { math.cos(k * math.pi / 4), math.sin(k * math.pi / 4) } end

-- is the point (x, y) clear of the world's collision (outdoors: the cells round the foot)?
local function GroundFits(x, y, r)
    if WS.CellMask(floor(x), floor(y)) then
        r = r or FOOT
        if WS.SolidAt(x, y) then return false end
        for _, o in ipairs(RING) do
            if WS.SolidAt(x + o[1] * r, y + o[2] * r) then return false end
        end
        return true
    end
    return not WS.Solid(floor(x), floor(y))
end

-- a body standing at (x, y) on layer li of building b (b nil: the ground) goes straight to (nx, ny): ok, and the
-- building / layer it ends on. Every cell crossed must be linked to the next (a corner: either way round).
local function Probe(x, y, b, li, nx, ny)
    local cx, cy = floor(x * SUB), floor(y * SUB)
    local tx, ty = floor(nx * SUB), floor(ny * SUB)
    if cx ~= tx or cy ~= ty then
        local dx, dy = nx - x, ny - y
        local n = max(1, floor(max(abs(dx), abs(dy)) * SUB * 2 + 0.999))
        for i = 1, n do
            local f = i / n
            local qx, qy = floor((x + dx * f) * SUB), floor((y + dy * f) * SUB)
            if qx ~= cx or qy ~= cy then
                local ddx, ddy = qx - cx, qy - cy
                if abs(ddx) > 1 or abs(ddy) > 1 then return false end
                local dh = ddx > 0 and 2 or 4
                local dv = ddy > 0 and 3 or 1
                local ok, b2, l2
                if ddx ~= 0 and ddy ~= 0 then
                    local ok1, b1, l1 = CellStep(b, li, cx, cy, dh)
                    if ok1 then ok, b2, l2 = CellStep(b1, l1, cx + ddx, cy, dv) end
                    if not ok then
                        ok1, b1, l1 = CellStep(b, li, cx, cy, dv)
                        if ok1 then ok, b2, l2 = CellStep(b1, l1, cx, cy + ddy, dh) end
                    end
                else
                    ok, b2, l2 = CellStep(b, li, cx, cy, ddx ~= 0 and dh or dv)
                end
                if not ok then return false end
                b, li, cx, cy = b2, l2, qx, qy
            end
        end
    end
    -- the spot itself: on the ground the world's collision, on a building's ground its props too (barrels...)
    if not b then
        if not GroundFits(nx, ny) then return false end
    else
        local l = WS.Layers(b, cx, cy)[li]
        if l and l.ter and WS.SolidAt(nx, ny) then return false end
    end
    return true, b, li
end

-- a unit's layer index where it stands (re-settling it when its height fits no layer of its cell)
local function UnitLayer(u)
    local b = u.bld
    if not b or u.e == nil then
        if WS.BuildingAt(u.x, u.y) then
            World.Settle(u)
            b = u.bld
            if not b then return nil, nil end
        else
            return nil, nil
        end
    end
    local cx, cy = floor(u.x * SUB), floor(u.y * SUB)
    local lay = WS.Layers(b, cx, cy)
    if #lay == 0 then u.bld, u.e = nil, nil return nil, nil end
    local k = LayerAt(lay, u.e)
    if not k then
        World.Settle(u, u.e)
        if not u.bld then return nil, nil end
        k = LayerAt(WS.Layers(u.bld, cx, cy), u.e)
    end
    return u.bld, k
end
World.UnitLayer = UnitLayer

local function Place(u, x, y, b, li)
    u.x, u.y = x, y
    if b and li then
        local l = WS.Layers(b, floor(x * SUB), floor(y * SUB))[li]
        u.bld, u.e = b, l and l.h or u.e
    else
        u.bld, u.e = nil, nil
    end
end

-- can a body stand at (x, y) - at height e in building b, or on the ground? (spawn wander spots, the goal of a path)
function World.Fits(map, x, y, r, e, b)
    local bb, cx, cy = WS.BuildingAt(x, y)
    if bb then
        local lay = WS.Layers(bb, cx, cy)
        if #lay > 0 then
            local k = LayerAt(lay, e or 0, e and 0.75 or 1e9)
            if not k then return false end
            return not (lay[k].ter and WS.SolidAt(x, y))
        end
    end
    return GroundFits(x, y, r)
end
local Fits = World.Fits

-- (outdoors: the point free to stand on)
function World.Free(map, x, y)
    return not WS.SolidAt(x, y)
end

-- can a foot stand on tile (tx, ty)? (outdoor paths)
function World.Walkable(map, tx, ty)
    return not WS.Solid(tx, ty)
end
local Walkable = World.Walkable

-- moves u by (dx, dy) tiles, sliding along walls; returns the distance actually moved
function World.MoveBy(u, dx, dy)
    local x, y = u.x, u.y
    local nx, ny = x + dx, y + dy
    local b, li = UnitLayer(u)
    if not b and not GroundFits(x, y) then
        -- (standing inside something - a spawn point or a saved spot on a cell that is solid now: walk out freely)
        u.x, u.y = nx, ny
        World.Settle(u)
        local mx, my = u.x - x, u.y - y
        return sqrt(mx * mx + my * my)
    end
    local ok, b2, l2 = Probe(x, y, b, li, nx, ny)
    if ok then Place(u, nx, ny, b2, l2)
    else
        ok, b2, l2 = Probe(x, y, b, li, nx, y)
        if ok then Place(u, nx, y, b2, l2)
        else
            ok, b2, l2 = Probe(x, y, b, li, x, ny)
            if ok then Place(u, x, ny, b2, l2) end
        end
    end
    local mx, my = u.x - x, u.y - y
    return sqrt(mx * mx + my * my)
end

-- nothing in the way on the straight line between two points, for a body standing at the first (height e0 in
-- building b0, or on the ground); returns ok and the height / building it would end at
function World.LineClear(map, x0, y0, x1, y1, e0, b0)
    local b, li
    if b0 and e0 then
        local cx, cy = floor(x0 * SUB), floor(y0 * SUB)
        li = LayerAt(WS.Layers(b0, cx, cy), e0)
        b = li and b0 or nil
    elseif WS.BuildingAt(x0, y0) then
        b, li = Settle(x0, y0, nil, nil)
    end
    if not b then
        -- (on the ground the whole way: the fine cells along the line)
        local dx, dy = x1 - x0, y1 - y0
        local n = max(1, floor(max(abs(dx), abs(dy)) * 8))
        local inside = false
        for i = 0, n do
            local f = i / n
            local px, py = x0 + dx * f, y0 + dy * f
            if WS.BuildingAt(px, py) then inside = true break end
            if WS.SolidAt(px, py) then return false end
        end
        if not inside then return true end
    end
    local ok, b2, l2 = Probe(x0, y0, b, li, x1, y1)
    if not ok then return false end
    local e1 = b2 and l2 and WS.Layers(b2, floor(x1 * SUB), floor(y1 * SUB))[l2].h or nil
    return true, e1, b2
end

-- the same spot, height and all: a and b see each other (no floor between, no wall)
function World.CanSee(a, b)
    if a.map ~= b.map then return false end
    local ok, e1, b1 = World.LineClear(a.map, a.x, a.y, b.x, b.y, a.e, a.bld)
    if not ok then return false end
    if b1 ~= b.bld then return b1 == nil and b.bld == nil end
    return b1 == nil or abs((e1 or 0) - (b.e or 0)) < 1.5
end

-- A* over tiles outdoors (8 ways, no corner cutting); returns { {x, y}, ... } tile centres or nil. In or into a
-- building it searches its fine cells layer by layer instead (World.PathFine).
function World.Path(map, sx, sy, tx, ty, limit, e0, b0, e1, b1)
    if b0 or b1 or WS.BuildingAt(sx, sy) or WS.BuildingAt(tx, ty) then
        return World.PathFine(sx, sy, tx, ty, limit, e0, b0, e1, b1)
    end
    sx, sy, tx, ty = floor(sx), floor(sy), floor(tx), floor(ty)
    if not Walkable(map, tx, ty) then
        -- the nearest walkable tile next to the goal
        local best
        for oy = -1, 1 do for ox = -1, 1 do
            if Walkable(map, tx + ox, ty + oy) and not best then best = { tx + ox, ty + oy } end
        end end
        if not best then return nil end
        tx, ty = best[1], best[2]
    end
    limit = limit or 900
    local function K(x, y) return y * 16384 + x end
    local open, came, g = { { sx, sy, 0 } }, {}, { [K(sx, sy)] = 0 }
    local closed = {}
    local n = 0
    while #open > 0 and n < limit do
        -- (small sets: a linear pick of the best f is fast enough)
        local bi, bf = 1, 1e9
        for i, o in ipairs(open) do
            local f = o[3] + max(abs(o[1] - tx), abs(o[2] - ty))
            if f < bf then bi, bf = i, f end
        end
        local cur = table.remove(open, bi)
        local cx, cy = cur[1], cur[2]
        local ck = K(cx, cy)
        if cx == tx and cy == ty then
            local path = {}
            local k = ck
            while k and k ~= K(sx, sy) do
                local x, y = k % 16384, floor(k / 16384)
                table.insert(path, 1, { x + 0.5, y + 0.5 })
                k = came[k]
            end
            return path
        end
        if not closed[ck] then
            closed[ck] = true
            n = n + 1
            for oy = -1, 1 do
                for ox = -1, 1 do
                    if ox ~= 0 or oy ~= 0 then
                        local nx, ny = cx + ox, cy + oy
                        local ok = Walkable(map, nx, ny)
                        if ok and ox ~= 0 and oy ~= 0 then
                            ok = Walkable(map, cx + ox, cy) and Walkable(map, cx, cy + oy)
                        end
                        if ok then
                            local nk = K(nx, ny)
                            local ng = cur[3] + ((ox ~= 0 and oy ~= 0) and 1.414 or 1)
                            if not closed[nk] and (not g[nk] or ng < g[nk]) then
                                g[nk] = ng
                                came[nk] = ck
                                open[#open + 1] = { nx, ny, ng }
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- a binary heap of { f, ... } nodes (the fine search opens thousands)
local function HeapPush(h, node)
    local i = #h + 1
    h[i] = node
    while i > 1 do
        local p = floor(i / 2)
        if h[p][1] <= h[i][1] then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end

local function HeapPop(h)
    local top = h[1]
    local last = h[#h]
    h[#h] = nil
    if #h > 0 then
        h[1] = last
        local i, n = 1, #h
        while true do
            local l, r, m = i * 2, i * 2 + 1, i
            if l <= n and h[l][1] < h[m][1] then m = l end
            if r <= n and h[r][1] < h[m][1] then m = r end
            if m == i then break end
            h[m], h[i] = h[i], h[m]
            i = m
        end
    end
    return top
end

-- A* over fine cells (4 ways), each node a cell and the layer stood on (0: the ground), through the same links a
-- body walks (CellStep); the goal is the cell at (tx, ty) on the layer nearest height e1 (any, on the ground).
-- Returns { {x, y}, ... } cell centres or nil.
function World.PathFine(sx, sy, tx, ty, limit, e0, b0, e1, b1)
    local scx, scy = floor(sx * SUB), floor(sy * SUB)
    local gcx, gcy = floor(tx * SUB), floor(ty * SUB)
    local b, li
    if b0 and e0 then
        li = LayerAt(WS.Layers(b0, scx, scy), e0, 1e9)
        b = li and b0 or nil
    else
        b, li = Settle(sx, sy, nil, nil)
    end
    local function K(cx, cy, l) return (cy * 65536 + cx) * 16 + (l or 0) end
    limit = limit or 2500
    local sk = K(scx, scy, li)
    local blds, g, came, closed = { [sk] = b }, { [sk] = 0 }, {}, {}
    local open = {}
    HeapPush(open, { max(abs(scx - gcx), abs(scy - gcy)), scx, scy, li, 0 })
    local n = 0
    while #open > 0 and n < limit do
        local cur = HeapPop(open)
        local cx, cy, cl = cur[2], cur[3], cur[4]
        local ck = K(cx, cy, cl)
        if not closed[ck] then
            closed[ck] = true
            n = n + 1
            local cb = blds[ck]
            if cx == gcx and cy == gcy and (e1 == nil or not cl or abs(WS.Layers(cb, cx, cy)[cl].h - e1) < 1.5) then
                local path = {}
                local k = ck
                while k and k ~= sk do
                    local cell = floor(k / 16)
                    table.insert(path, 1, { (cell % 65536 + 0.5) / SUB, (floor(cell / 65536) + 0.5) / SUB })
                    k = came[k]
                end
                return path
            end
            for d = 1, 4 do
                local ok, nb, nl = CellStep(cb, cl, cx, cy, d)
                local nx, ny = cx + DXS[d], cy + DYS[d]
                if ok then
                    local px, py = (nx + 0.5) / SUB, (ny + 0.5) / SUB
                    if nb then
                        if WS.Layers(nb, nx, ny)[nl].ter and WS.SolidAt(px, py) then ok = false end
                    elseif WS.SolidAt(px, py) then
                        ok = false
                    end
                end
                if ok then
                    local nk = K(nx, ny, nl)
                    local ng = cur[5] + 1
                    if not closed[nk] and (not g[nk] or ng < g[nk]) then
                        g[nk] = ng
                        came[nk] = ck
                        blds[nk] = nb
                        HeapPush(open, { ng + max(abs(nx - gcx), abs(ny - gcy)), nx, ny, nl, ng })
                    end
                end
            end
        end
    end
    return nil
end

function World.MapName(map, x, y)
    return (WS.AreaName(floor(x or 0), floor(y or 0))) or "Northshire Valley"
end

---------------------------------------------------------------------------
-- Spawns: creatures, NPCs, critters, objects
---------------------------------------------------------------------------

local function Hash(a, b)
    local h = (a * 73856093 + b * 19349663) % 2147483647
    h = (h * 1103515245 + 12345) % 2147483648
    return h / 2147483648
end

local function Spawn(rec)
    local e = rec.e
    local kind = e.k == "mob" and "mob" or (e.k == "critter" and "critter" or "npc")
    local u = Combat.NewCreature("C:" .. e.g, kind, e.e, e)
    u.rec = rec
    u.map = "world"
    u.x, u.y = e.xf or (e.x + 0.5), e.yf or (e.y + 0.5)
    World.Settle(u, e.ht)                   -- (in a building: the floor it stands on)
    u.face = e.f or "down"
    u.homeX, u.homeY, u.homeE, u.homeB = u.x, u.y, u.e, u.bld
    if kind == "npc" then u.name = e.n or u.name u.title = e.t or (u.cr and u.cr.sub) end
    u.sprite = e.spr
    rec.unit = u
    rec.state = "idle"
    rec.respawnAt = nil
    rec.corpseUntil = nil
    rec.loot = nil
    return u
end

local function BuildSpawns()
    for _, e in ipairs(W.ents or {}) do
        if e.k == "mob" or e.k == "critter" or e.k == "npc" then
            local rec = { e = e, guid = "C:" .. e.g }
            World.recs[rec.guid] = rec
            Spawn(rec)
        elseif e.k == "obj" then
            local o = { e = e, guid = "O:" .. e.g, map = "world", x = e.xf or (e.x + 0.5), y = e.yf or (e.y + 0.5) }
            -- (where it stands, height and all, as a unit would: o.e is its spawn)
            o.pos = { map = "world", x = o.x, y = o.y }
            World.Settle(o.pos, e.ht)
            World.objects[#World.objects + 1] = o
        end
    end
end

-- where an idle creature stands at realm time t (wander: a new spot in its radius every few seconds), and the
-- height it stands at near there (in a building)
local SEG = 8
function World.IdlePos(rec, t)
    local e, u = rec.e, rec.unit
    local hx, hy = u.homeX, u.homeY
    local r = e.w or 0
    if r <= 0 then return hx, hy, false, u.face, u.homeE end
    local g = e.g
    rec.spots = rec.spots or {}
    local function point(k)
        local c = rec.spots[k]
        if c then return c[1], c[2], c[3], c[4] end
        local a = Hash(g, k) * math.pi * 2
        local d = sqrt(Hash(g + 7, k)) * r
        local px, py = hx + math.cos(a) * d, hy + math.sin(a) * d
        local ok, pe, pb = World.LineClear(u.map, hx, hy, px, py, u.homeE, u.homeB)
        if not ok or not Fits(u.map, px, py, nil, pe, pb) then px, py, pe, pb = hx, hy, u.homeE, u.homeB end
        rec.spots[k] = { px, py, pe, pb }
        rec.spots[k - 3] = nil
        return px, py, pe, pb
    end
    local k = floor(t / SEG)
    local f = (t - k * SEG)
    local ax, ay, ae, ab = point(k - 1)
    local bx, by, be = point(k)
    local dist = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) * YARDS
    local speed = Craft.WALK_SPEED * ((u.cr and u.cr.walk) or 1)
    local walkT = dist / speed
    -- (a blocked straight line between two spots: via home)
    if dist > 0.01 and not World.LineClear(u.map, ax, ay, bx, by, ae, ab) then
        local d1 = sqrt((hx - ax) ^ 2 + (hy - ay) ^ 2) * YARDS
        local d2 = sqrt((bx - hx) ^ 2 + (by - hy) ^ 2) * YARDS
        local t1, t2 = d1 / speed, d2 / speed
        if f < t1 then
            local p = f / t1
            return ax + (hx - ax) * p, ay + (hy - ay) * p, true, World.FaceOf(hx - ax, hy - ay), ae
        elseif f < t1 + t2 then
            local p = (f - t1) / t2
            return hx + (bx - hx) * p, hy + (by - hy) * p, true, World.FaceOf(bx - hx, by - hy), u.homeE
        end
        return bx, by, false, World.FaceOf(bx - hx, by - hy), be
    end
    if f < walkT then
        local p = f / walkT
        return ax + (bx - ax) * p, ay + (by - ay) * p, true, World.FaceOf(bx - ax, by - ay), p < 0.5 and ae or be
    end
    return bx, by, false, (dist > 0.01) and World.FaceOf(bx - ax, by - ay) or u.face, be
end

function World.FaceOf(dx, dy)
    if abs(dx) > abs(dy) then return dx > 0 and "right" or "left" end
    return dy > 0 and "down" or "up"
end

---------------------------------------------------------------------------
-- The player
---------------------------------------------------------------------------

function World.Enter(c)
    if not World.built then
        World.built = true
        BuildSpawns()
    end
    local p = Combat.NewPlayer(c)
    Craft.player = p
    p.map = "world"
    p.x, p.y = c.x, c.y
    -- (saved inside one of the old inside maps, before buildings were walked in place: back at the hearth)
    if c.map and c.map ~= "world" then
        local b = c.bind or {}
        if b.map and b.map ~= "world" then
            local gy = D.graveyards and D.graveyards[1]
            b = gy and { x = gy.x, y = gy.y } or b
        end
        p.x, p.y, c.e = b.x or p.x, b.y or p.y, nil
    end
    c.map = "world"
    World.Settle(p, c.e)
    World.area = nil
    World.CheckArea(true)
    return p
end

function World.Leave()
    local p = Craft.player
    if p then
        local c = Craft.char
        if c then
            c.map, c.x, c.y, c.e, c.face = p.map, p.x, p.y, p.e, p.face
            c.hp, c.power = p.hp, p.power
        end
        Combat.Remove(p)
    end
    Craft.player = nil
end

-- e: the height to stand at there (in a building; nil: its ground)
function World.Teleport(u, map, x, y, e)
    u.map, u.x, u.y = "world", x, y
    World.Settle(u, e)
    u.path = nil
    if u == Craft.player then
        Combat.Interrupt(u, "teleport")
        World.CheckArea()
        Craft:Emit("teleport", map, x, y)
    end
end

-- the area banner: Northshire Valley, Northshire Abbey, Echo Ridge Mine...
function World.CheckArea(quiet)
    local p = Craft.player
    if not p then return end
    local name, zone, id = WS.AreaName(floor(p.x), floor(p.y))
    if id and id ~= World.area then
        World.area = id
        World.areaName = name
        World.zoneName = zone or World.zoneName
        Craft:Emit("area", name, zone, quiet)
        if type(id) == "number" then World.Explore(id, name, quiet) end
    end
end

-- Exploring: the first time you stand in an area it goes on your map, and (like the TBC server) you gain its
-- exploration experience - the base XP of the area's level, less when you are far above it, a level-5-higher amount
-- when far below; areas without a level give none. Logging in somewhere new explores it quietly.
function World.Explore(id, name, quiet)
    local c = Craft.char
    local M = ns.CraftMaps
    if not c or not M or M.areaLevel[id] == nil then return end
    c.explored = c.explored or {}
    if c.explored[id] then return end
    c.explored[id] = true
    local lvl = M.areaLevel[id]
    if not quiet and lvl > 0 and c.level < D.MAX_LEVEL then
        local diff = c.level - lvl
        local xp
        if diff < -5 then xp = M.exploreXP[c.level + 5] or 0
        elseif diff > 5 then xp = floor((M.exploreXP[lvl] or 0) * max(0, min(100, 100 - (diff - 5) * 5)) / 100)
        else xp = M.exploreXP[lvl] or 0 end
        xp = xp * Craft.XP_RATE
        if xp > 0 then
            Craft:GiveXP(xp, string.format("Discovered %s: %d experience gained", name or "?", xp))
        end
    end
    Craft:Emit("explored", id)
end

local function StandUp(p)
    if p.sitting then
        p.sitting = false
        Combat.RemoveAurasByInterrupt(p, 0x40000)
        for i = #p.auras, 1, -1 do                     -- (eating / drinking need you seated)
            local a = p.auras[i]
            local sp = D.spells[a.spell]
            if sp and (sp.n == "Food" or sp.n == "Drink" or sp.n == "Food & Drink") then Combat.RemoveAura(p, a, "stood") end
        end
        Craft:Emit("sit", false)
    end
end
World.StandUp = StandUp

function World.ToggleSit()
    local p = Craft.player
    if not p or p.dead then return end
    if p.sitting then StandUp(p) else
        if p.casting then Combat.Interrupt(p) end
        p.sitting = true
        Craft:Emit("sit", true)
    end
end

local lastSave = 0
local function MovePlayer(p, dt)
    local inp = World.input
    if p.dead and not p.ghost then p.moving = false return end
    if p.charge then return end
    local dx, dy = inp.dx or 0, inp.dy or 0
    if dx == 0 and dy == 0 or p.stunned or p.rooted or p.cc then
        p.moving = false
        return
    end
    local len = sqrt(dx * dx + dy * dy)
    dx, dy = dx / len, dy / len
    local speed = Craft.RUN_SPEED * (p.speedMult or 1) * (p.ghost and 1.25 or 1)
    if inp.walk then speed = Craft.WALK_SPEED end
    local step = speed * dt / YARDS
    StandUp(p)
    if p.casting then
        local sp = D.spells[p.casting.spell]
        Combat.Interrupt(p, "moving")
    end
    local moved = World.MoveBy(p, dx * step, dy * step)
    p.moving = moved > 0
    p.face = World.FaceOf(dx, dy)
    if p.autoShot then p.autoShot = false end
    World.CheckArea()
end

-- the warrior's Charge: a rush at 25 yards a second to the target's side
function World.Charge(u, t)
    u.charge = { target = t, speed = 25 }
end

local function MoveCharge(u, dt)
    local c = u.charge
    local t = c.target
    if not t or t.dead or t.map ~= u.map then u.charge = nil return end
    local d = Craft.UnitDist(u, t)
    if d <= Craft.MELEE_RANGE - 1 then u.charge = nil return end
    local step = min(c.speed * dt, d - (Craft.MELEE_RANGE - 1.5)) / YARDS
    local dx, dy = t.x - u.x, t.y - u.y
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.001 then u.charge = nil return end
    local moved = World.MoveBy(u, dx / len * step, dy / len * step)
    u.face = World.FaceOf(dx, dy)
    u.moving = true
    if moved < step * 0.2 then u.charge = nil end
    c.time = (c.time or 0) + dt
    if c.time > 2 then u.charge = nil end
end

function World.Hearth()
    local p, c = Craft.player, Craft.char
    if not p or not c then return end
    local b = c.bind
    World.Teleport(p, "world", b.x, b.y, b.e)
end

-- dying, the ghost run, coming back
function World.ReleaseSpirit()
    local p, c = Craft.player, Craft.char
    if not p or not p.dead or p.ghost then return end
    -- the graveyard nearest where you fell, like WoW
    local cx, cy = p.x, p.y
    local gy, best
    for _, g in ipairs(D.graveyards) do
        local dd = Craft.Dist(cx, cy, g.x, g.y)
        if not best or dd < best then gy, best = g, dd end
    end
    p.ghost = true
    c.ghost = true
    p.hp = 1
    World.Teleport(p, "world", gy.x, gy.y)
    Craft:Emit("ghost", true)
end

function World.CorpseDistance()
    local p, c = Craft.player, Craft.char
    if not p or not c or not c.corpse then return 1e9 end
    if c.corpse.map ~= p.map then return 1e9 end
    return Craft.Dist(p.x, p.y, c.corpse.x, c.corpse.y)
end

function World.Revive(atCorpse)
    local p, c = Craft.player, Craft.char
    if not p or not p.dead then return end
    p.dead, p.ghost = false, false
    c.dead, c.ghost = nil, nil
    if atCorpse and c.corpse then
        World.Teleport(p, "world", c.corpse.x, c.corpse.y, c.corpse.e)
    end
    c.corpse = nil
    Combat.Recalc(p)
    p.hp = max(1, floor(p.hpMax * 0.5))
    if p.powerType == Craft.POWER_MANA then p.power = floor(p.powerMax * 0.5) else p.power = 0 end
    if p.class == 1 and c.spells[2457] then Combat.ApplyAura(p, p, 2457, true) end
    Craft:Emit("ghost", false)
    Craft:Emit("revive")
end

---------------------------------------------------------------------------
-- Creatures: the brain (only the client with authority runs it; the rest follow its word)
---------------------------------------------------------------------------

-- WoW's aggro radius: the creature's detection range (10 yards for Northshire's critters of trouble, 18 for the
-- rest; 20 when unknown), a yard less for each level you are above it, a yard more for each below; 5 at least
local function AggroRange(mob, pl)
    local base = (mob.cr and mob.cr.det) or 20
    local yd = base + ((mob.level or 1) - (pl.level or 1))
    return Craft.Clamp(yd, 5, 45)
end

local function Players()
    local out = {}
    for _, u in pairs(Combat.units) do
        if (u.kind == "player" or u.kind == "remote") and not u.dead and not u.ghost then out[#out + 1] = u end
    end
    return out
end
World.Players = Players

local function Say(u, text)
    text = text:gsub("%$[Nn]", (Craft.char and Craft.char.name) or "you")
    Craft:Msg(u.name .. " says: " .. text, "monster")
    Craft:Emit("bubble", u, text)
end
World.Say = Say

-- EventAI: a rule's next time
local function RuleNext(r, first)
    local lo, hi
    if r[1] == 0 or r[1] == 33 then
        if first then lo, hi = r[3], r[4] else lo, hi = r[5], r[6] end
    elseif r[1] == 2 or r[1] == 9 or r[1] == 27 then
        lo, hi = r[5], r[6]
    else
        return nil
    end
    if not lo or (lo == 0 and hi == 0) then return first and 0 or nil end
    return Now() + Craft.Roll(lo, max(lo, hi)) / 1000
end

local function RunActions(mob, acts, target)
    for _, a in ipairs(acts) do
        if a[1] == "say" then
            Say(mob, a[2][Craft.Roll(1, #a[2])])
        elseif a[1] == "cast" then
            local tgt = (a[3] == 0) and mob or target
            if tgt then Combat.CastSpell(mob, a[2], tgt, { ai = true }) end
        elseif a[1] == "flee" then
            mob.rec.state = "flee"
            mob.rec.fleeUntil = Now() + 7
            Craft:Msg(mob.name .. " attempts to run away in fear!", "monster")
            Craft:Emit("bubble", mob, nil, "flee")
        elseif a[1] == "ranged" then
            mob.rec.ranged = a[2]
        end
    end
end

local function EventAI(mob, event, target)
    local rules = D.eventai[mob.entry]
    if not rules then return end
    local rec = mob.rec
    rec.ai = rec.ai or {}
    for i, r in ipairs(rules) do
        if r[1] == event and Craft.Chance(r[2] or 100) then RunActions(mob, r[7], target) end
    end
end

local function EventAITimers(mob, target)
    local rules = D.eventai[mob.entry]
    if not rules then return end
    local rec = mob.rec
    rec.ai = rec.ai or {}
    local now = Now()
    for i, r in ipairs(rules) do
        local ev = r[1]
        local st = rec.ai[i]
        if not st then st = { next = RuleNext(r, true) } rec.ai[i] = st end
        if ev == 0 or ev == 33 then
            if st.next and now >= st.next and not mob.casting then
                if Craft.Chance(r[2] or 100) then RunActions(mob, r[7], target) end
                st.next = RuleNext(r, false)
            end
        elseif ev == 2 then
            local pct = mob.hp / mob.hpMax * 100
            if pct <= (r[3] or 100) and pct >= (r[4] or 0) and (not st.fired or (st.next and now >= st.next)) then
                st.fired = true
                if Craft.Chance(r[2] or 100) then RunActions(mob, r[7], target) end
                st.next = RuleNext(r, false)
                if not st.next then st.next = 1e12 end
            end
        elseif ev == 9 and target then
            local d = Craft.UnitDist(mob, target)
            if d >= (r[3] or 0) and d <= (r[4] or 40) and (not st.next or now >= st.next) and not mob.casting then
                if Craft.Chance(r[2] or 100) then RunActions(mob, r[7], target) end
                st.next = RuleNext(r, false) or (now + 3)
            end
        elseif ev == 27 then
            local acts = r[7]
            local spell = r[3]
            if not Combat.FindAura(mob, spell) and (not st.next or now >= st.next) and not mob.casting then
                RunActions(mob, acts, target)
                st.next = RuleNext(r, false) or (now + 10)
            end
        end
    end
end

-- creatures of the same faction within the pulled one's call-for-help radius (5 yards in Northshire) join in
local function CallForHelp(mob, foe)
    local radius = mob.cr and mob.cr.cfh
    if not radius or radius <= 0 then return end
    for _, rec in pairs(World.recs) do
        local o = rec.unit
        if o and o ~= mob and not o.dead and o.kind == "mob" and rec.state == "idle" and o.hostile and
           o.cr and mob.cr and o.cr.fac == mob.cr.fac and o.map == mob.map and Craft.UnitDist(o, mob) <= radius then
            World.Engage(o, foe)
        end
    end
end

function World.Engage(mob, foe)
    local rec = mob.rec
    if not rec or mob.dead or rec.state == "evade" then return end
    if rec.state == "idle" or rec.state == "return" then
        rec.state = "combat"
        rec.engageX, rec.engageY = mob.x, mob.y
        rec.ai = nil
        mob.swingAt = Now() + 0.4
        if mob.kind == "mob" then
            EventAI(mob, 4, foe)
            CallForHelp(mob, foe)
        end
        Craft:Emit("engage", mob, foe)
    end
    Combat.EnterCombat(mob, foe)
    if foe and Combat.IsPlayer(foe) then Combat.AddThreat(mob, foe, 0) end
end

local function Evade(mob)
    local rec = mob.rec
    rec.state = "evade"
    mob.threat = {}
    mob.target = nil
    mob.attacking = false
    mob.casting = nil
    rec.path = nil
    rec.ranged = nil
    for i = #mob.auras, 1, -1 do
        if not mob.auras[i].helpful then table.remove(mob.auras, i) end
    end
    Combat.Recalc(mob)
    Craft:Emit("evade", mob)
end
World.Evade = Evade

-- steps a creature toward (tx, ty) at speed (yards / s); uses a path around walls when the straight line is blocked
local function Steer(mob, tx, ty, speed, dt, stopYd, te, tb)
    local rec = mob.rec
    local d = Craft.Dist(mob.x, mob.y, tx, ty)
    if d <= (stopYd or 0.3) then mob.moving = false return true end
    local gx, gy = tx, ty
    local clear, le, lb = World.LineClear(mob.map, mob.x, mob.y, tx, ty, mob.e, mob.bld)
    if clear and (te ~= nil or tb ~= nil) and (lb ~= tb or abs((le or 0) - (te or 0)) > 1.5) then clear = false end
    if not clear then
        local now = Now()
        if not rec.path or (rec.pathAt or 0) < now or rec.pathGoal ~= floor(tx) * 16384 + floor(ty) then
            rec.path = World.Path(mob.map, mob.x, mob.y, tx, ty, 700, mob.e, mob.bld, te, tb)
            rec.pathAt = now + 0.6
            rec.pathGoal = floor(tx) * 16384 + floor(ty)
        end
        local p = rec.path and rec.path[1]
        local near = (mob.bld or tb) and 0.35 or 0.6         -- (a building's path runs cell by cell)
        while p and Craft.Dist(mob.x, mob.y, p[1], p[2]) < near do
            table.remove(rec.path, 1)
            p = rec.path[1]
        end
        if p then gx, gy = p[1], p[2] else rec.stuck = (rec.stuck or 0) + dt end
    else
        rec.path = nil
    end
    local dx, dy = gx - mob.x, gy - mob.y
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.001 then return false end
    local step = min(speed * dt / YARDS, len, (d - (stopYd or 0)) / YARDS + 0.05)
    if step <= 0 then return true end
    local moved = World.MoveBy(mob, dx / len * step, dy / len * step)
    mob.face = World.FaceOf(dx, dy)
    mob.moving = moved > 0.0001
    if moved < step * 0.1 then rec.stuck = (rec.stuck or 0) + dt else rec.stuck = 0 end
    return false
end

local function RunSpeed(mob) return Craft.RUN_SPEED * ((mob.cr and mob.cr.run) or 1) * (mob.speedMult or 1) end

local function ThinkCombat(mob, dt)
    local rec = mob.rec
    local now = Now()
    local target = Combat.PickTarget(mob)
    if not target then Evade(mob) return end
    if mob.target ~= target then mob.target = target Craft:Emit("mobtarget", mob, target) end
    -- dragged too far from where the fight started (or home): give up
    local home = Craft.Dist(mob.x, mob.y, rec.engageX or mob.homeX, rec.engageY or mob.homeY)
    if home > 60 or (rec.stuck or 0) > 5 or target.map ~= mob.map then Evade(mob) return end
    if mob.stunned or mob.cc then
        mob.moving = false
        if mob.cc then                                    -- (a sheep wanders a little)
            rec.sheepAt = rec.sheepAt or now
        end
        return
    end
    EventAITimers(mob, target)
    if mob.dead or rec.state ~= "combat" then return end
    if mob.casting then mob.moving = false return end
    local d = Craft.UnitDist(mob, target)
    local reach = Craft.MELEE_RANGE
    if rec.ranged and (mob.power or 0) > 0 then reach = rec.ranged - 2 end
    if d > reach - 0.5 and not mob.rooted then
        Steer(mob, target.x, target.y, RunSpeed(mob), dt, reach - 1, target.e, target.bld)
    else
        mob.moving = false
        Combat.Face(mob, target)
    end
    if d <= Craft.MELEE_RANGE + 0.5 and now >= (mob.swingAt or 0) then
        Combat.Swing(mob, target)
        mob.swingAt = now + (mob.mh and mob.mh[4] or 2) / (mob.hasteMult or 1)
    end
end

local function ThinkFlee(mob, dt)
    local rec = mob.rec
    local t = mob.target
    if Now() >= (rec.fleeUntil or 0) or not t or t.dead then rec.state = "combat" return end
    if mob.stunned or mob.rooted or mob.cc then mob.moving = false return end
    local dx, dy = mob.x - t.x, mob.y - t.y
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.01 then dx, dy, len = 1, 0, 1 end
    Steer(mob, mob.x + dx / len * 3, mob.y + dy / len * 3, RunSpeed(mob) * 0.6, dt, 0)
end

local function ThinkEvade(mob, dt)
    local rec = mob.rec
    local done = Steer(mob, mob.homeX, mob.homeY, RunSpeed(mob) * 1.4, dt, 0.5, mob.homeE, mob.homeB)
    if done or (rec.stuck or 0) > 3 then
        mob.x, mob.y, mob.e, mob.bld = mob.homeX, mob.homeY, mob.homeE, mob.homeB
        mob.hp = mob.hpMax
        mob.power = mob.powerMax or 0
        mob.inCombat = false
        rec.state = "return"
        rec.stuck = 0
        Craft:Emit("evaded", mob)
    end
end

local function IdleAggro(mob, players)
    if not mob.hostile or mob.kind ~= "mob" then return end
    for _, pl in ipairs(players) do
        if pl.map == mob.map and not pl.dead and not pl.ghost then
            local d = Craft.UnitDist(mob, pl)
            if d <= AggroRange(mob, pl) and World.CanSee(mob, pl) then
                World.Engage(mob, pl)
                return true
            end
        end
    end
end

local thinkAcc = 0
local function UpdateCreatures(dt)
    local now = Now()
    local clock = World.Clock()
    local players = Players()
    thinkAcc = thinkAcc + dt
    local scan = thinkAcc >= 0.2
    if scan then thinkAcc = 0 end
    local me = Craft.player
    for guid, rec in pairs(World.recs) do
        local u = rec.unit
        if u then
            -- near anyone? (far ones only keep their idle walk, worked out when seen)
            local near = false
            for _, pl in ipairs(players) do
                if pl.map == u.map and abs(pl.x - u.x) < ACTIVE and abs(pl.y - u.y) < ACTIVE then near = true break end
            end
            if not near and me and me.ghost and me.map == u.map and abs(me.x - u.x) < ACTIVE and abs(me.y - u.y) < ACTIVE then
                near = true
            end
            if u.dead then
                -- the corpse lies, then is gone; the creature comes back after its respawn time
                if rec.corpseUntil and now >= rec.corpseUntil then rec.corpseUntil = nil rec.hidden = true end
                if rec.respawnAt and clock >= rec.respawnAt then
                    Combat.Remove(u)
                    Spawn(rec)
                    rec.hidden = nil
                    Craft:Emit("respawn", rec.unit)
                end
            elseif rec.state == "idle" or rec.state == "return" then
                if near or rec.state == "return" then
                    local ix, iy, moving, face, ie = World.IdlePos(rec, clock)
                    if rec.state == "return" then
                        if Steer(u, ix, iy, Craft.WALK_SPEED * 1.5, dt, 0.3, ie, u.homeB) then rec.state = "idle" end
                    elseif not u.stunned and not u.rooted then
                        local ox, oy = u.x, u.y
                        u.x, u.y, u.moving, u.face = ix, iy, moving, face
                        if (ox ~= ix or oy ~= iy or u.e == nil) and (u.homeB or u.bld) then World.Settle(u, ie) end
                    end
                    if scan and World.authority and rec.state == "idle" then IdleAggro(u, players) end
                    -- spawn buffs (Frost Armor on the Geomancer)
                    if scan and World.authority and D.eventai[u.entry] and rec.state == "idle" then
                        local rules = D.eventai[u.entry]
                        for i, r in ipairs(rules) do
                            if r[1] == 27 and not Combat.FindAura(u, r[3]) then RunActions(u, r[7], nil) end
                        end
                    end
                end
            elseif World.authority then
                if rec.state == "combat" then ThinkCombat(u, dt)
                elseif rec.state == "flee" then ThinkFlee(u, dt)
                elseif rec.state == "evade" then ThinkEvade(u, dt) end
            end
            -- a creature attacked while idle (a spell from range) fights back
            if not u.dead and rec.state == "idle" and u.inCombat and next(u.threat) and World.authority then
                local t = Combat.PickTarget(u)
                if t then World.Engage(u, t) end
            end
            if u.charge then MoveCharge(u, dt) end
        end
    end
end

-- a creature died: the corpse, the respawn timer (the loot and the experience come from Loot.lua)
Craft:On("death", function(u, killer)
    if Combat.IsCreature(u) and u.rec then
        local rec = u.rec
        rec.state = "dead"
        u.moving = false
        rec.respawnAt = World.Clock() + max(20, floor((rec.e.r or 300) * Craft.RESPAWN_RATE))
        rec.corpseUntil = Now() + 60
    end
end)

---------------------------------------------------------------------------
-- Talking, looting, using: what's in front of you
---------------------------------------------------------------------------

-- the unit or object at map point (x, y) (a click), friendly or not
function World.UnitAt(map, x, y, radius)
    local best, bestD = nil, (radius or 0.7)
    for _, u in pairs(Combat.units) do
        if u.map == map and u ~= Craft.player and not (u.rec and u.rec.hidden) then
            -- (the sprite stands on its feet, on the unit's point: the clickable box reaches a tile up)
            local d = sqrt((u.x - x) ^ 2 + ((u.y - 0.55) - y) ^ 2)
            if d < bestD then best, bestD = u, d end
        end
    end
    return best
end

function World.ObjectAt(map, x, y, radius)
    local best, bestD = nil, (radius or 0.7)
    for _, o in ipairs(World.objects) do
        if o.map == map then
            local d = sqrt((o.x - x) ^ 2 + (o.y - y) ^ 2)
            if d < bestD then best, bestD = o, d end
        end
    end
    return best
end

-- Tab: the nearest attackable creature in front first, then the next on each press
function World.TabTarget()
    local p = Craft.player
    if not p then return end
    local list = {}
    for _, u in pairs(Combat.units) do
        if u.kind == "mob" and not u.dead and u.map == p.map and not (u.rec and u.rec.hidden) then
            local d = Craft.UnitDist(p, u)
            if d <= 40 then list[#list + 1] = { u = u, d = d } end
        end
    end
    table.sort(list, function(a, b)
        local ha, hb = a.u.hostile and 0 or 1, b.u.hostile and 0 or 1
        if ha ~= hb then return ha < hb end
        return a.d < b.d
    end)
    if #list == 0 then return end
    local cur = p.target
    local idx = 0
    for i, x in ipairs(list) do if x.u == cur then idx = i end end
    local nxt = list[(idx % #list) + 1].u
    World.SetTarget(nxt)
end

function World.SetTarget(u)
    local p = Craft.player
    if not p then return end
    if p.target ~= u then
        p.target = u
        if p.attacking and (not u or not Combat.CanAttack(p, u)) then Combat.StopAttack(p) end
        Craft:Emit("target", u)
    end
end

-- right-click / the interact key on a unit or object
function World.Interact(x)
    local p = Craft.player
    if not p or not x then return end
    if p.dead and not p.ghost then return end
    if x.e and x.guid and x.guid:find("^O:") then
        return World.UseObject(x)
    end
    local u = x
    if p.ghost then
        if u.entry == 6491 then World.Revive(false) end     -- (a spirit healer)
        return
    end
    World.SetTarget(u)
    if u.dead and u.rec then
        if Craft.UnitDist(p, u) > Craft.INTERACT_RANGE then Craft:Error("You are too far away!") return end
        if Craft.Loot then Craft.Loot.Open(u) end
        return
    end
    if Combat.CanAttack(p, u) and u.kind ~= "critter" then
        Combat.StartAttack(p, u)
        return
    end
    if u.kind == "npc" then
        if Craft.UnitDist(p, u) > Craft.INTERACT_RANGE then Craft:Error("You are too far away!") return end
        if p.inCombat and false then return end
        Combat.Face(p, u)
        Craft:Emit("gossip", u)
    end
end

function World.UseObject(o)
    local p = Craft.player
    if Craft.Dist(p.x, p.y, o.x, o.y) > Craft.INTERACT_RANGE then Craft:Error("You are too far away!") return end
    if o.usedUntil and World.Clock() < o.usedUntil then Craft:Error("It's empty.") return end
    if Craft.Quests and Craft.Quests.UseObject(o) then return end
    local e = o.e
    if e.kind == "herb" then Craft:Error("Requires Herbalism") return end
    if e.kind == "ore" then Craft:Error("Requires Mining") return end
    if e.kind == "chest" and Craft.Loot then Craft.Loot.OpenObject(o) return end
    Craft:Error("You can't use that right now.")
end

-- the nearest thing to talk to / loot / use within reach (the interact key)
function World.Nearest()
    local p = Craft.player
    if not p then return nil end
    local best, bestD = nil, Craft.INTERACT_RANGE
    for _, u in pairs(Combat.units) do
        if u ~= p and u.map == p.map and not (u.rec and u.rec.hidden) and
           (u.kind == "npc" or (u.dead and u.rec and u.rec.loot and Craft.Loot and Craft.Loot.CanLoot(u))) then
            local d = Craft.UnitDist(p, u)
            if d < bestD then best, bestD = u, d end
        end
    end
    for _, o in ipairs(World.objects) do
        if o.map == p.map and Craft.Quests and Craft.Quests.ObjectWanted(o) then
            local d = Craft.Dist(p.x, p.y, o.x, o.y)
            if d < bestD then best, bestD = o, d end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- The clock
---------------------------------------------------------------------------

function World.Update(dt)
    local p = Craft.player
    if not p then return end
    if p.charge then MoveCharge(p, dt) else MovePlayer(p, dt) end
    UpdateCreatures(dt)
    local now = Now()
    if now - lastSave > 2 then
        lastSave = now
        local c = Craft.char
        c.map, c.x, c.y, c.e, c.face = p.map, p.x, p.y, p.e, p.face
        c.hp, c.power = p.hp, p.power
    end
end

-- for the test suites: the spawn table, rebuilt
function World.Reset()
    for guid, rec in pairs(World.recs) do if rec.unit then Combat.Remove(rec.unit) end end
    World.recs, World.objects, World.built = {}, {}, false
end

-- eating and drinking sit you down, like the client does when the Food / Drink aura lands
Craft:On("aura", function(u, a, added)
    if not added or not u or u.dead or u.kind ~= "player" then return end
    local sp = D.spells[a.spell]
    if sp and (sp.n == "Food" or sp.n == "Drink" or sp.n == "Food & Drink") and not u.sitting then
        if u.casting then Combat.Interrupt(u) end
        u.sitting = true
        if u == Craft.player then Craft:Emit("sit", true) end
    end
end)
