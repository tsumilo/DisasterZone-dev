if DisasterZoneBoot and DisasterZoneBoot.Run("Render3D/Rooms.lua", ...) then return end -- DisasterZone Render3D/Rooms.lua
-- ns.Render3D rooms: the boss rooms the 3D views can draw (Blizzard's own meshes, Render3D/Rooms/<Name>Floor.lua, made
-- by dev/generators/gen_trainer_heights.py), which strategy bosses use them, and where each lies on the strategy
-- board's floor map, so a drawing on the 2D map and the same drawing in the room are one spot.
--
-- Room coordinates ("arena"): yards, x east, y north, height 0 = the room's main floor, as the floor files have them.
-- The board: 1000 x 666 units over a shipped 1024 x 683 floor map that the page pans (vx, vy) and zooms (vz) as
-- UI/StrategyMap.lua draws it; a map pixel turns into room yards with the room's fit (x = ax * px + bx,
-- y = ay * py + by: the maps are drawn north up, so no turn).
local _, ns = ...

local R3 = ns.Render3D or {}
ns.Render3D = R3

local floor, min, max = math.floor, math.min, math.max

-- A floor's height function from a generated height grid (one letter per square yard, rows south to north): smooth
-- between the yard centres, the edge value outside; nil without a grid.
function R3.HeightFn(grid)
    if not grid then return nil end
    local index = {}                                    -- character -> its place in the alphabet
    local alphabet = grid.alphabet or "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for k = 1, #alphabet do index[alphabet:byte(k)] = k - 1 end
    local function cell(i, j)                           -- nil where there is no floor
        i = max(1, min(grid.w, i))
        j = max(1, min(grid.h, j))
        local n = index[grid.rows[j]:byte(i)]
        return n and (n * grid.step + grid.base)
    end
    return function(x, y)
        local fx, fy = x - 0.5, y - 0.5
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
-- view asks the model's own box.
R3.DISPLAYS = {
    [21254] = { scale = 2.5, name = 2.45 },        -- Teron Gorefiend (model 51)
    [21300] = { scale = 1.5, name = 3.39 },        -- Vengeful Spirit (model 9)
    [21305] = { scale = 1.75, name = 2.29 },       -- Shadowy Construct (model 1771)
    [20748] = { scale = 3.5, name = 2.77 },        -- Lady Vashj (model 2535)
    [11172] = { scale = 2, name = 3.19 },          -- Tainted Elemental (model 110)
    [20076] = { scale = 2, name = 3.19 },          -- Enchanted Elemental (model 110)
    [20772] = { scale = 3 },                       -- Coilfang Elite (model 2353)
    [18194] = { scale = 3 },                       -- Coilfang Strider (model 2385)
}

-- The rooms. floor: the key in ns.RoomFloors; bosses: the strategy bosses (Core/Strategy.lua refs) drawn in it; map:
-- the shipped floor map (Data/RaidMaps.lua file) a page must use for its drawings to land in the room; fit: map
-- pixel -> room yards; view: where the camera first looks (room point, distance).
local ROOMS = {}
R3.ROOMS = ROOMS

do
    -- Gorefiend's Vigil on Black Temple's floor 4 (BT04): the hall and, down the steps at its north end, the alcove
    -- Teron stands in (Render3D/Rooms/TeronVigilFloor.lua; the Raid Trainer's "teron" is the hall alone, in the same
    -- coordinates). The fit: room point -> the temple's local coordinates (x = -615 - room x, y = -759 - room y) ->
    -- world through the temple's placement (ADT blacktemple_31_30 MODF, unique id 1075600: turned 269.65 degrees)
    -- -> the map's world rectangle (retail UiMapAssignment, uiMap 343: world x 343.333 .. 636.667, y 135 .. 575),
    -- fitted over the room (off by 0.37 yd at most: the placement's 0.35 degree turn). It puts Teron's spawn
    -- (AzerothCore: world 606.641, 402.173) at room (29.9, 85.2), on the alcove floor the mesh has there.
    ROOMS.teron = {
        key = "teron", name = "Gorefiend's Vigil", floor = "teronVigil", bosses = { "BlackTemple:Teron" },
        map = "BT04",
        fit = { ax = 0.429637, bx = -142.9243, ay = -0.429482, by = 115.2135 },
        view = { x = 30, y = 50, dist = 78 },
    }
    -- Lady Vashj's room on the Serpentshrine Cavern map: the map's world rectangle (retail UiMapAssignment, uiMap 332:
    -- world x -400 .. 650.002, y -1362.500 .. 212.502; the map's left edge is the largest y, its top the largest x)
    -- and the room's own coordinates (Games/Trainer/Encounters/LadyVashj.lua: x = -world y - 923.27 + 105,
    -- y = world x - 29.83 + 105). Her starter's portrait lands within a map pixel of her spot.
    local xMin, xMax, yMin, yMax = -400, 650.00201, -1362.50049, 212.50249
    ROOMS.vashj = {
        key = "vashj", name = "Lady Vashj's room", floor = "vashj", bosses = { "SerpentshrineCavern:Vashj" },
        map = "Serpentshrine",
        fit = { ax = (yMax - yMin) / 1024, bx = -yMax - 923.27 + 105,
                ay = -(xMax - xMin) / 683, by = xMax - 29.83 + 105 },
        view = { x = 105, y = 100, dist = 115 },
    }
end

local byBoss = {}
for _, room in pairs(ROOMS) do
    for _, b in ipairs(room.bosses) do byBoss[b] = room end
end

-- The room of a strategy boss ("BlackTemple:Teron"), or nil.
function R3.RoomForBoss(bossRef)
    return type(bossRef) == "string" and byBoss[bossRef] or nil
end

-- A room's floor file (ns.RoomFloors.<key>: w, h, rows, mesh, walk), or nil when it is not loaded.
function R3.Floor(room)
    local floors = ns.RoomFloors
    return room and floors and floors[room.floor] or nil
end

-- A room's height grid as a function (cached), or nil.
function R3.Height(room)
    if not room then return nil end
    if room.heightFn == nil then room.heightFn = R3.HeightFn(R3.Floor(room)) or false end
    return room.heightFn or nil
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
