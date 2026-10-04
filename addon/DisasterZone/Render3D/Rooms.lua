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
-- model's PlayerName attachment height in model units (the M2 file; the label goes 0.4 yd over it). Without one the
-- view asks the model's own box. Render3D/Rooms/Index.lua gives the scale of every portrait (DISPLAY_SCALE).
R3.DISPLAYS = {
    [21254] = { scale = 2.5, name = 2.45 },        -- Teron Gorefiend (model 51)
    [21300] = { scale = 1.5, name = 3.39 },        -- Vengeful Spirit (model 9)
    [21305] = { scale = 1.75, name = 2.29 },       -- Shadowy Construct (model 1771)
    [20748] = { scale = 3.5, name = 2.77 },        -- Lady Vashj (model 2535)
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
-- pair }. The packed text keeps its sections apart with "|": the rows (one per line), the texture file IDs, the blend
-- codes (D, A, B), then verts, tris, nodes and pair as numbers. -> false when it cannot be read.
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
    if #parts ~= 7 then return false end
    local rows = {}
    for line in (parts[1] .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = line end
    local blend = {}
    for code in parts[3]:gmatch("%S+") do blend[#blend + 1] = BLEND[code] or "BLEND" end
    f.rows = rows
    f.mesh = { version = 2, textures = Numbers(parts[2]), blend = blend, verts = Numbers(parts[4]),
               tris = Numbers(parts[5]), nodes = Numbers(parts[6]), pair = Numbers(parts[7]) }
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
        old.rows, old.mesh = nil, nil
        for _, r in pairs(ROOMS) do
            if floors[r.floor] == old then r.heightFn = nil end
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
