if DisasterZoneBoot and DisasterZoneBoot.Run("Render3D/Rooms.lua", ...) then return end -- DisasterZone Render3D/Rooms.lua
-- ns.Render3D rooms: the boss rooms the 3D views can draw (Blizzard's own meshes), which strategy bosses use them, and
-- where each lies on the strategy board's floor map, so a drawing on the 2D map and the same drawing in the room are
-- one spot.
--  * The strategy board's rooms: one per encounter, Render3D/Rooms/<Raid>_<Boss>.lua (data format 3: packed, see
--    R3.Floor) and Render3D/Rooms/Index.lua (ns.Render3D.ROOM_INDEX), made by dev/generators/gen_rooms.py from the
--    area each encounter's starter strategy shows on its floor map.
--  * The Raid Trainer's own rooms: Render3D/Rooms/TeronGorefiendFloor.lua and LadyVashjFloor.lua (format 2: plain
--    tables, read at load time; dev/generators/gen_trainer_heights.py).
--
-- Room coordinates ("arena"): yards, x east, y north, height 0 = the room's main floor (a board room's: the boss').
-- The board: 1000 x 666 units over a shipped 1024 x 683 floor map that the page pans (vx, vy) and zooms (vz) as
-- UI/StrategyMap.lua draws it; a map pixel turns into room yards with the room's fit (x = ax * px + bx,
-- y = ay * py + by: the maps are drawn north up, so no turn).
local _, ns = ...

local R3 = ns.Render3D or {}
ns.Render3D = R3

local floor, min, max = math.floor, math.min, math.max
local tonumber = tonumber

-- A floor's height function from a generated height grid (one letter per cell of grid.cell yards, 1 when not given,
-- rows south to north): smooth between the cell centres, the edge value outside; nil without a grid.
function R3.HeightFn(grid)
    if not (grid and grid.rows and grid.rows[1]) then return nil end
    local index = {}                                    -- character -> its place in the alphabet
    local alphabet = grid.alphabet or "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for k = 1, #alphabet do index[alphabet:byte(k)] = k - 1 end
    local size = grid.cell or 1
    local cols, nrows = #grid.rows[1], #grid.rows
    local function cell(i, j)                           -- nil where there is no floor
        i = max(1, min(cols, i))
        j = max(1, min(nrows, j))
        local n = index[grid.rows[j]:byte(i)]
        return n and (n * grid.step + grid.base)
    end
    return function(x, y)
        local fx, fy = x / size - 0.5, y / size - 0.5
        local i, j = floor(fx), floor(fy)
        local tx, ty = fx - i, fy - j
        local a, b = cell(i + 1, j + 1), cell(i + 2, j + 1)
        local c, d = cell(i + 1, j + 2), cell(i + 2, j + 2)
        local any = a or b or c or d or 0               -- at a hole's edge: the floor next to it
        a, b, c, d = a or any, b or any, c or any, d or any
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    end
end

-- The creatures the strategy boards show as models: CreatureDisplayInfo.CreatureModelScale (wago.tools, build
-- 2.5.6.69795; the client draws a ModelScene actor at scale 1 whatever its display says) and, where known, the
-- model's PlayerName attachment height in model units (the M2 file; the label goes 0.4 yd over it) and its Chest
-- attachment's (where a beam or a spell effect meets it). Without one the view asks the model's own box.
-- Render3D/Rooms/Index.lua gives the scale of every portrait (DISPLAY_SCALE).
R3.DISPLAYS = {
    [21254] = { scale = 2.5, name = 2.45 },        -- Teron Gorefiend (model 51)
    [21300] = { scale = 1.5, name = 3.39 },        -- Vengeful Spirit (model 9)
    [21305] = { scale = 1.75, name = 2.29 },       -- Shadowy Construct (model 1771)
    [20748] = { scale = 3.5, name = 2.77, chest = 1.74 },  -- Lady Vashj (model 2535; chest: the Raid Trainer's)
    [11172] = { scale = 2, name = 3.19 },          -- Tainted Elemental (model 110)
    [20076] = { scale = 2, name = 3.19 },          -- Enchanted Elemental (model 110)
}
for id, s in pairs(R3.DISPLAY_SCALE or {}) do
    if not R3.DISPLAYS[id] then R3.DISPLAYS[id] = { scale = s } end
end

-- The rooms, from the generated index: per encounter (keyed by its floor key) { key, name, floor, bosses, map (the
-- shipped floor map a page must use for its drawings to land in the room), fit (map pixel -> room yards), view (where
-- the camera first looks: room point, distance), spot (where the boss stands) }.
local ROOMS = {}
R3.ROOMS = ROOMS
local byBoss = {}
for ref, e in pairs(R3.ROOM_INDEX or {}) do
    local room = { key = e.floor, name = e.name, floor = e.floor, bosses = { ref }, map = e.map, fit = e.fit,
                   view = e.view, spot = e.spot }
    ROOMS[e.floor] = room
    byBoss[ref] = room
end

-- The room of a strategy boss ("BlackTemple:Teron"), or nil.
function R3.RoomForBoss(bossRef)
    return type(bossRef) == "string" and byBoss[bossRef] or nil
end

-- Is a room's floor file there (without unpacking it)?
function R3.HasFloor(room)
    local floors = ns.RoomFloors
    return room ~= nil and floors ~= nil and floors[room.floor] ~= nil
end

-- A packed floor (format 3) -> the format 2 tables: rows, mesh = { version = 2, textures, blend, verts, tris, nodes,
-- pair }, walk = { verts, tris, slide, swim }. The packed text keeps its sections apart with "|": the rows (one per
-- line), the texture file IDs, the blend codes (D, A, B), then verts, tris, nodes and pair as numbers, then (rooms
-- made since walking) the ground's verts (x, y, z) and its walk, slide and swim faces (vertex a, b, c, 1-based).
-- -> false when it cannot be read.
local BLEND = { D = "DISABLE", A = "ALPHAKEY", B = "BLEND" }
local function Numbers(s)
    local out, n = {}, 0
    for w in s:gmatch("%S+") do
        n = n + 1
        out[n] = tonumber(w)
    end
    return out
end
local function Unpack(f)
    local LD = LibStub and LibStub("LibDeflate", true)
    if not LD or type(f.data) ~= "table" then return false end
    local raw = LD:DecodeForPrint(table.concat(f.data))
    local text = raw and LD:DecompressDeflate(raw)
    if type(text) ~= "string" or #text ~= f.size then return false end
    local parts = {}
    for part in (text .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = part end
    if #parts ~= 7 and #parts ~= 11 then return false end
    local rows = {}
    for line in (parts[1] .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = line end
    local blend = {}
    for code in parts[3]:gmatch("%S+") do blend[#blend + 1] = BLEND[code] or "BLEND" end
    f.rows = rows
    f.mesh = { version = 2, textures = Numbers(parts[2]), blend = blend, verts = Numbers(parts[4]),
               tris = Numbers(parts[5]), nodes = Numbers(parts[6]), pair = Numbers(parts[7]) }
    if parts[8] then
        f.walk = { verts = Numbers(parts[8]), tris = Numbers(parts[9]), slide = Numbers(parts[10]),
                   swim = Numbers(parts[11]) }
    end
    return true
end

-- A room's floor (ns.RoomFloors.<key>: w, h, rows, mesh; the trainer's also walk), unpacked when packed: the last
-- KEEP rooms used stay unpacked, older ones keep only their packed text. nil when it is not loaded or cannot be read.
local unpacked = {}                      -- floors unpacked, the most recent last
local KEEP = 2
function R3.Floor(room)
    local floors = ns.RoomFloors
    local f = room and floors and floors[room.floor]
    if not f then return nil end
    if f.version ~= 3 then return f end
    for i = #unpacked, 1, -1 do
        if unpacked[i] == f then table.remove(unpacked, i) end
    end
    if not f.mesh then
        if f.bad or not Unpack(f) then
            f.bad = true
            return nil
        end
    end
    unpacked[#unpacked + 1] = f
    while #unpacked > KEEP do
        local old = table.remove(unpacked, 1)
        old.rows, old.mesh, old.walk = nil, nil, nil
        for _, r in pairs(ROOMS) do
            if floors[r.floor] == old then r.heightFn, r.groundFn = nil, nil end
        end
    end
    return f
end

-- A room's height grid as a function (cached while its floor stays unpacked), or nil.
function R3.Height(room)
    if not room then return nil end
    if not room.heightFn then room.heightFn = R3.HeightFn(R3.Floor(room)) end
    return room.heightFn
end

---------------------------------------------------------------------------
-- Walking on a room: the ground (the Raid Trainer's units and the strategy board's walk mode)
---------------------------------------------------------------------------

-- The client's numbers: running, walking backwards and swimming (yd/s), keyboard turning (rad/s), gravity and the
-- fastest fall (yd/s^2, yd/s: TrinityCore), a jump's upward speed (yd/s), the highest step walked up (yd), the steepest
-- slope walked (tan 50 degrees). (Games/Trainer/Engine.lua keeps its own copies of them.)
R3.WALK = { run = 7, back = 4.5, swim = 4.722222, turn = math.pi, gravity = 19.291103, terminal = 60.148003,
            jump = 7.95577, stepUp = 1.0, maxSlope = math.tan(math.rad(50)) }

-- The ground walking units stand on, from a floor's walk table: Blizzard's collision faces no steeper than 50 degrees
-- (tris; on a staircase that is the invisible ramp over the steps, so feet glide up it as in the game), the steeper
-- ones you slide down but cannot walk up (slide) and the water's surface (swim). ground(x, y, z, air) = the highest
-- face at (x, y) a unit with its feet at z can be on: ground up to stepUp above z (in the air: none above z), a slope
-- no higher than z; nil where there is none (a pillar, a wall, outside the room). z nil: the highest of all. On a
-- slope it also returns the slope's rise per yard east and north (the way down is against them); on water a 4th
-- value, true. Faces are kept by 4 yd squares. stepUp: yd (R3.WALK.stepUp when not given).
function R3.GroundFn(walk, stepUp)
    if not walk or not walk.tris then return nil end
    stepUp = stepUp or R3.WALK.stepUp
    local V = walk.verts
    local cells, n = {}, 0
    -- per face: barycentric weights w1 = K1 dx + K2 dy, w2 = K3 dx + K4 dy from its third corner (CX, CY), its
    -- plane z = PA x + PB y + PC, and KIND: 1 ground, 2 a slope, 3 water
    local K1, K2, K3, K4, CX, CY, PA, PB, PC, KIND = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
    local function add(list, kind)
        for t = 1, floor(#list / 3) do
            local a, b, c = list[t * 3 - 2] * 3, list[t * 3 - 1] * 3, list[t * 3] * 3
            local ax, ay, az = V[a - 2], V[a - 1], V[a]
            local bx, by, bz = V[b - 2], V[b - 1], V[b]
            local cx, cy, cz = V[c - 2], V[c - 1], V[c]
            local det = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            local ux, uy, uz = bx - ax, by - ay, bz - az
            local vx, vy, vz = cx - ax, cy - ay, cz - az
            local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            if det ~= 0 and nz ~= 0 then                -- (never upright: the generators keep 80 degrees at most)
                n = n + 1
                K1[n], K2[n] = (by - cy) / det, (cx - bx) / det
                K3[n], K4[n] = (cy - ay) / det, (ax - cx) / det
                CX[n], CY[n], KIND[n] = cx, cy, kind
                PA[n], PB[n] = -nx / nz, -ny / nz
                PC[n] = az - PA[n] * ax - PB[n] * ay
                for gx = floor(min(ax, bx, cx) / 4), floor(max(ax, bx, cx) / 4) do
                    for gy = floor(min(ay, by, cy) / 4), floor(max(ay, by, cy) / 4) do
                        local key = (gx + 500) * 1000 + gy + 500
                        local cell = cells[key]
                        if not cell then
                            cell = {}
                            cells[key] = cell
                        end
                        cell[#cell + 1] = n
                    end
                end
            end
        end
    end
    add(walk.tris, 1)
    add(walk.slide or {}, 2)
    add(walk.swim or {}, 3)
    if n == 0 then return nil end
    local EPS = -1e-4                                   -- (a point on a shared edge belongs to both sides)
    return function(x, y, z, air)
        local cell = cells[(floor(x / 4) + 500) * 1000 + floor(y / 4) + 500]
        if not cell then return nil end
        local limit = z and (z + (air and 0 or stepUp) + 1e-6) or math.huge
        local slopeLimit = z and (z + 0.05) or math.huge
        local best, bi
        for k = 1, #cell do
            local i = cell[k]
            local dx, dy = x - CX[i], y - CY[i]
            local w1 = K1[i] * dx + K2[i] * dy
            if w1 >= EPS then
                local w2 = K3[i] * dx + K4[i] * dy
                if w2 >= EPS and 1 - w1 - w2 >= EPS then
                    local h = PA[i] * x + PB[i] * y + PC[i]
                    if h <= (KIND[i] == 2 and slopeLimit or limit) and (not best or h > best) then best, bi = h, i end
                end
            end
        end
        if bi and KIND[bi] == 2 then return best, PA[bi], PB[bi] end
        if bi and KIND[bi] == 3 then return best, nil, nil, true end
        return best
    end
end

-- A room's ground as a function (R3.GroundFn; cached while its floor stays unpacked), or nil (a room made before
-- walking, or one without ground).
function R3.Ground(room)
    if not room then return nil end
    if room.groundFn == nil then
        local f = R3.Floor(room)
        room.groundFn = f and f.walk and R3.GroundFn(f.walk) or false
    end
    return room.groundFn or nil
end

-- Someone walking on a room's ground (ground: a GroundFn; w, h: the room's size, which it stays 0.5 yd inside),
-- feet at (x, y, z), facing (radians, 0 = east). W:Step(dt, fwd, strafe, turn, jump) moves it as the client moves a
-- character: running, backing off, strafing (the body turns into it: bodyTurn), turning by keyboard, steps up to
-- R3.WALK.stepUp; walls, pillars and ledges stop it (it slides along them on the free axis); off an edge it falls,
-- a steep slope slides it down, a jump arcs; on water it swims at the surface. What it is doing: moving, backward,
-- falling, swimming.
local Walker = {}
Walker.__index = Walker

function R3.NewWalker(ground, w, h, x, y, z, facing)
    local k = setmetatable({ ground = ground, w = w, h = h, x = x, y = y, facing = facing or 0, vz = 0,
                             bodyTurn = 0 }, Walker)
    local g, _, _, swim = ground(x, y, z)
    if not g then g, _, _, swim = ground(x, y, nil) end
    k.z, k.swimming, k.gx, k.gy = g or z or 0, swim and true or false, x, y
    return k
end

function Walker:Step(dt, fwd, strafe, turn, jump)
    local C, ground = R3.WALK, self.ground
    local sqrt = math.sqrt
    local x0, y0 = self.x, self.y
    if turn ~= 0 then self.facing = self.facing + turn * C.turn * dt end
    local mx, my = 0, 0
    self.backward, self.bodyTurn = false, 0
    if fwd ~= 0 or strafe ~= 0 then
        local cf, sf = math.cos(self.facing), math.sin(self.facing)
        mx, my = cf * fwd + sf * strafe, sf * fwd - cf * strafe
        if fwd < 0 then
            self.backward, self.bodyTurn = true, strafe * math.pi / 4      -- backing off to the right: swings left
        elseif fwd > 0 then
            self.bodyTurn = -strafe * math.pi / 4                         -- running forward and right: leans in
        else
            self.bodyTurn = -strafe * math.pi / 2                         -- a pure strafe: runs sideways
        end
    end
    local speed = self.swimming and C.swim or (self.backward and C.back or C.run)
    local vx, vy = 0, 0
    self.moving = false
    if self.falling then
        vx, vy = self.fvx or 0, self.fvy or 0                             -- (in the air the keys steer nothing)
    elseif mx ~= 0 or my ~= 0 then
        local len = sqrt(mx * mx + my * my)
        vx, vy = mx / len * speed, my / len * speed
        self.moving = true
    end
    if jump and not self.falling and not self.swimming then
        self.falling, self.vz, self.fvx, self.fvy = true, C.jump, vx, vy
    end
    local z0, air = self.z, self.falling
    if vx ~= 0 or vy ~= 0 then
        local nx = min(self.w - 0.5, max(0.5, self.x + vx * dt))
        local ny = min(self.h - 0.5, max(0.5, self.y + vy * dt))
        if ground(nx, ny, z0, air) then
            self.x, self.y = nx, ny
        elseif ground(nx, self.y, z0, air) then
            self.x = nx
        elseif ground(self.x, ny, z0, air) then
            self.y = ny
        elseif self.falling then
            self.fvx, self.fvy = 0, 0
        end
    end
    -- onto the ground where it now is, or on with its fall (the Raid Trainer's Sim:Settle)
    local moved2 = (self.x - self.gx) ^ 2 + (self.y - self.gy) ^ 2
    local g, sx, sy, swim = ground(self.x, self.y, z0, self.falling)
    if not self.falling and g and (sx or g < z0 - sqrt(moved2) * C.maxSlope - 0.02) then
        local v = dt > 0 and sqrt(moved2) / dt or 0
        local kk = dt > 0 and min(1, max(speed, C.run) / max(v, 1e-9)) / dt or 0
        self.falling, self.vz, self.fvx, self.fvy = true, 0, (self.x - self.gx) * kk, (self.y - self.gy) * kk
    end
    if self.falling then
        local vz = max(-C.terminal, self.vz - C.gravity * dt)
        local nz = z0 + vz * dt
        if g and nz > g then
            self.z, self.vz = nz, vz
        elseif sx then
            -- on the slope: held on it, and pushed off downhill as gravity pulls along it
            local push = C.gravity / (1 + sx * sx + sy * sy) * dt
            self.z, self.vz = g, vz
            self.fvx, self.fvy = (self.fvx or 0) - sx * push, (self.fvy or 0) - sy * push
        else                                                              -- landed
            self.z, self.vz, self.falling, self.fvx, self.fvy = g or z0, 0, nil, nil, nil
        end
    elseif g then
        self.z = g
    end
    self.swimming = (swim and not self.falling) and true or false
    self.gx, self.gy = self.x, self.y
    self.vx, self.vy = dt > 0 and (self.x - x0) / dt or 0, dt > 0 and (self.y - y0) / dt or 0      -- (how it went)
end

---------------------------------------------------------------------------
-- Board units <-> room yards
---------------------------------------------------------------------------

local LW, LH = 1024, 683                 -- a shipped map's size (UI/StrategyMap.lua: SHIPPED_LAYER)
local BW, BH = 1000, 666                 -- the board (Core/Strategy.lua: BOARD_W, BOARD_H)

-- The page's map view as UI/StrategyMap.lua draws it: the map pixel at the board's centre and map pixels per
-- board unit.
local function MapView(page)
    local vx, vy, vz = page and page.vx or 500, page and page.vy or 500, page and page.vz or 100
    return vx / 1000 * LW, vy / 1000 * LH, min(BW / LW, BH / LH) * vz / 100
end

-- A board point of a page -> room x, y (yards).
function R3.BoardToRoom(room, page, bx, by)
    local cx, cy, k = MapView(page)
    local f = room.fit
    return f.ax * (cx + (bx - BW / 2) / k) + f.bx, f.ay * (cy + (by - BH / 2) / k) + f.by
end

-- A room point -> the page's board x, y (unrounded, may lie off the board).
function R3.RoomToBoard(room, page, x, y)
    local cx, cy, k = MapView(page)
    local f = room.fit
    return ((x - f.bx) / f.ax - cx) * k + BW / 2, ((y - f.by) / f.ay - cy) * k + BH / 2
end

-- Yards per board unit across and down (the same within a few percent).
function R3.BoardScale(room, page)
    local _, _, k = MapView(page)
    local f = room.fit
    return math.abs(f.ax) / k, math.abs(f.ay) / k
end
