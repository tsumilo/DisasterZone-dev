if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/World/World.lua", ...) then return end -- DisasterZone Games/Azeromon/World/World.lua
-- ns.AzeroLand: the overworld as the real Eastern Kingdoms, one seamless map ("world") built from the client's own
-- terrain by dev/generators/gen_azeromon_world.py (see dev/docs/azeromon_world/PLAN.md).
--
-- Grid: one tile = one cell of an ADT chunk (533.33 / 128 = 4.17 yards); x grows east, y south, from the map's
-- north-west corner (x = (17066.67 - worldY) / 4.17). The data comes in 32x32-tile blocks (ns.AzeroWorldData.blocks,
-- written by the generated World/<Region>.lua files), each three run-length strings - ground class, overlay, hill
-- shade - plus the area of each 8x8 chunk. Blocks are decoded when first looked at; the compiled map's layers
-- (base / over / solid / water / warp / node / object) are tables whose lookups decode on demand, so the engine
-- (Game.lua, UI.lua) reads the world exactly like a hand-made map.
--
-- Ground classes: . grass  , dark grass  * flowers  = road  : dirt  + cobbles  % crops  ^ rocky  # cliff
--                 ~ shallow water  w deep water  s sand  X nothing (outside the data)
-- Overlay: tree trunks, rocks, fences, props, building blocks (R), walls (#), decks (=), doors (D) - see OVER.
local addonName, ns = ...

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local byte, sub, rep, concat = string.byte, string.sub, string.rep, table.concat

local W = { blocks = {}, areas = {}, treeCells = {}, doors = {}, entCells = {}, ents = {}, interiors = {} }
ns.AzeroWorldData = W
local WS = {}
ns.AzeroLand = WS
ns.AzeroData = ns.AzeroData or {}  -- (Species.lua fills it: sprites, species, CLASS_SPR)

local WIDTH = 8192                 -- tiles across the map (64 ADTs x 128)
local BLOCK = 32
local CELL = 16                    -- entity / tree index cell (tiles)
WS.WIDTH, WS.BLOCK = WIDTH, BLOCK
WS.YARDS = 533.3333 / 128

---------------------------------------------------------------------------
-- Registration (the generated files call these while loading)
---------------------------------------------------------------------------

local function CellKey(x, y) return floor(y / CELL) * 1024 + floor(x / CELL) end

-- flat { x, y, radius x 10, ... }: a tree's trunk tile and its crown radius in tiles
function W.AddTrees(flat)
    for i = 1, #flat, 3 do
        local x, y = flat[i], flat[i + 1]
        local key = CellKey(x, y)
        local list = W.treeCells[key]
        if not list then list = {} W.treeCells[key] = list end
        list[#list + 1] = { x = x, y = y, r = flat[i + 2] / 10 }
    end
end

function W.AddDoor(d)
    W.doors[d.y * WIDTH + d.x] = d
end

-- a region's ground pages (Media/Azeromon/Ground/<name>_<n>.blp, 64 x 64 tiles of 16 px each)
function W.AddGround(name, pages, row)
    local r = { file = "Interface\\AddOns\\DisasterZone\\Media\\Azeromon\\Ground\\" .. name .. "_", pages = pages,
                row = row or 64 }
    W.grounds = W.grounds or {}
    W.grounds[name] = r
    return r
end

-- the region's scenery sprites (Media/Azeromon/Scenery/<name>_<n>.blp): flat { page, u, v, w, h, ox, oy, ... }
function W.AddSprites(name, pages, pxPerTile, flat)
    local sp = { file = "Interface\\AddOns\\DisasterZone\\Media\\Azeromon\\Scenery\\" .. name .. "_", list = {},
                 pxt = pxPerTile }
    for i = 1, #flat, 7 do
        sp.list[#sp.list + 1] = { page = flat[i], u = flat[i + 1], v = flat[i + 2], w = flat[i + 3], h = flat[i + 4],
                                  ox = flat[i + 5], oy = flat[i + 6] }
    end
    return sp
end

-- placements, flat { sprite (0-based), x, y, sort y (map pixels, 16 a tile), size x 100, ... }
W.scenCells = {}
function W.AddScenery(sp, flat)
    for i = 1, #flat, 5 do
        local s = sp.list[flat[i] + 1]
        local k = flat[i + 4] / 100
        local p = { sp = s, file = sp.file .. s.page, x = flat[i + 1] / 16, y = flat[i + 2] / 16,
                    sort = flat[i + 3] / 16, k = math.abs(k), pxt = sp.pxt, tree = k < 0 or nil }
        local key = floor(p.y / CELL) * 1024 + floor(p.x / CELL)
        local list = W.scenCells[key]
        if not list then list = {} W.scenCells[key] = list end
        list[#list + 1] = p
    end
end

-- a building's depth slices outdoors: flat { sprite, x, y, sort (16 a tile) }; each slice sorts at the ground row
-- under it, so whatever stands behind one wing and in front of another is drawn right (and may fade: wall)
function W.AddSceneryWalls(sp, flat)
    for i = 1, #flat, 4 do
        local s = sp.list[flat[i] + 1]
        local p = { sp = s, file = sp.file .. s.page, x = flat[i + 1] / 16, y = flat[i + 2] / 16,
                    sort = flat[i + 3] / 16, k = 1, pxt = sp.pxt, wall = true }
        local key = floor(p.y / CELL) * 1024 + floor(p.x / CELL)
        local list = W.scenCells[key]
        if not list then list = {} W.scenCells[key] = list end
        list[#list + 1] = p
    end
end

-- an interior floor's picture, drawn from its building's model: flat { sprite (0-based), x, y (16 a tile) }
W.interiorArt = {}
function W.AddInteriorArt(id, sp, flat)
    local list = W.interiorArt[id] or {}
    W.interiorArt[id] = list
    for i = 1, #flat, 3 do
        local s = sp.list[flat[i] + 1]
        list[#list + 1] = { sp = s, file = sp.file .. s.page, x = flat[i + 1] / 16, y = flat[i + 2] / 16,
                            sort = -1e9, k = 1, pxt = sp.pxt }
    end
end

-- its walls, railings and furniture cut into depth slices: flat { sprite, x, y, sort (16 a tile) }; each slice is
-- drawn in the world's depth order at its own grid row (in front of the people behind it, behind those in front)
function W.AddInteriorWalls(id, sp, flat)
    local list = W.interiorArt[id] or {}
    W.interiorArt[id] = list
    for i = 1, #flat, 4 do
        local s = sp.list[flat[i] + 1]
        list[#list + 1] = { sp = s, file = sp.file .. s.page, x = flat[i + 1] / 16, y = flat[i + 2] / 16,
                            sort = flat[i + 3] / 16, k = 1, pxt = sp.pxt, wall = true }
    end
end

-- a building's floor (generated from its WMO): { name, level, rows, stairs = { { x, y, map, tx, ty } } }
function W.AddInterior(id, def)
    W.interiors[id] = def
end

-- the world door at (x, y) leads into interior `map`, onto its exit mat (ix, iy)
function W.LinkDoor(x, y, map, ix, iy)
    local d = W.doors[y * WIDTH + x]
    if d then d.map, d.ix, d.iy = map, ix, iy end
end

-- e.k = "npc" | "mob" | "obj"; e.g = the spawn's database guid (stable id); e.map = the interior it stands in
-- (then x / y are that interior's)
function W.Add(e)
    W.ents[#W.ents + 1] = e
    if e.map then return end
    local key = CellKey(e.x, e.y)
    local list = W.entCells[key]
    if not list then list = {} W.entCells[key] = list end
    list[#list + 1] = e
end

---------------------------------------------------------------------------
-- Blocks
---------------------------------------------------------------------------

local RUNS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-"
local RUNVAL = {}
for i = 1, #RUNS do RUNVAL[byte(RUNS, i)] = i end

local function Unrle(s)
    local parts = {}
    for i = 1, #s, 2 do parts[#parts + 1] = rep(sub(s, i, i), RUNVAL[byte(s, i + 1)] or 1) end
    return concat(parts)
end
WS.Unrle = Unrle

-- the ground layer: 3-character tile codes, each followed by its run length
local function Unrle3(s)
    local parts = {}
    for i = 1, #s, 4 do parts[#parts + 1] = rep(sub(s, i, i + 2), RUNVAL[byte(s, i + 3)] or 1) end
    return concat(parts)
end

local decoded, decodedCount = {}, 0
local EMPTY = { g = rep("X", BLOCK * BLOCK), o = rep(" ", BLOCK * BLOCK), s = rep("5", BLOCK * BLOCK), area = {} }

local function Block(bx, by)
    local key = by * 256 + bx
    local b = decoded[key]
    if b then return b end
    local raw = W.blocks[key]
    if not raw then return EMPTY end
    if decodedCount >= 160 then           -- (a long walk: forget what is far behind)
        decoded, decodedCount = {}, 0
    end
    b = { g = Unrle(raw[1]), o = Unrle(raw[2]), s = Unrle(raw[3]), area = raw[4] or {}, names = {}, overs = {},
          ground = raw[5] and Unrle3(raw[5]) or nil, region = raw[6], cm = raw[7] and Unrle3(raw[7]) or nil,
          cmv = {} }
    decoded[key] = b
    decodedCount = decodedCount + 1
    return b
end

-- ground class byte, overlay byte, shade (0..9) and the block / index inside it
local B_X = byte("X")
function WS.Tile(x, y)
    if x < 0 or y < 0 or x >= WIDTH or y >= WIDTH then return B_X, 32, 5 end
    local bx, by = floor(x / BLOCK), floor(y / BLOCK)
    local b = Block(bx, by)
    local i = (y - by * BLOCK) * BLOCK + (x - bx * BLOCK) + 1
    return byte(b.g, i), byte(b.o, i), byte(b.s, i) - 48, b, i
end

function WS.Ground(x, y) return (WS.Tile(x, y)) end

-- WoW's own ground at (x, y): the region's page file and the tile's slot on it (nil outside the data)
function WS.GroundTile(x, y)
    if x < 0 or y < 0 or x >= WIDTH or y >= WIDTH then return nil end
    local bx, by = floor(x / BLOCK), floor(y / BLOCK)
    local b = Block(bx, by)
    if not b.ground or not b.region then return nil end
    local i = ((y - by * BLOCK) * BLOCK + (x - bx * BLOCK)) * 3 + 1
    local n = (RUNVAL[byte(b.ground, i)] - 1) * 4096 + (RUNVAL[byte(b.ground, i + 1)] - 1) * 64
              + RUNVAL[byte(b.ground, i + 2)] - 1
    local per = b.region.row * b.region.row
    return b.region.file .. floor(n / per), n % per, b.region.row
end

function WS.AreaAt(x, y)
    if x < 0 or y < 0 then return nil end
    local bx, by = floor(x / BLOCK), floor(y / BLOCK)
    local raw = W.blocks[by * 256 + bx]
    if not raw or not raw[4] then return nil end
    local cx, cy = floor((x - bx * BLOCK) / 8), floor((y - by * BLOCK) / 8)
    return raw[4][cy * 4 + cx + 1]
end

-- "Northshire Valley", "Elwynn Forest" (the zone of the area) for a tile
function WS.AreaName(x, y)
    local id = WS.AreaAt(x, y)
    local a = id and W.areas[id]
    if not a then return nil end
    local z = W.areas[a.zone]
    return a.name, z and z.name or a.name, id
end

---------------------------------------------------------------------------
-- Tiles: what the engine sees
---------------------------------------------------------------------------

local C = {}
for ch in ("., *=:+%^#~wsX"):gmatch(".") do C[ch] = byte(ch) end
local G_DOT, G_DARK, G_FLOW, G_ROAD, G_DIRT, G_COB, G_CROP = C["."], C[","], C["*"], C["="], C[":"], C["+"], C["%"]
local G_ROCK, G_CLIFF, G_SHAL, G_DEEP, G_SAND, G_VOID = C["^"], C["#"], C["~"], C["w"], C["s"], C["X"]

local SOLID_GROUND = { [G_CLIFF] = true, [G_DEEP] = true, [G_VOID] = true }
local WATER = { [G_SHAL] = true, [G_DEEP] = true }
-- autotiled ground classes: atlas prefix (13 pieces each: tl t tr l c r bl b br inw ine isw ise)
local AUTO = { [G_ROAD] = "road_", [G_DIRT] = "path_", [G_COB] = "cobble_", [G_CROP] = "crops_",
               [G_ROCK] = "rocky_", [G_CLIFF] = "cliff_", [G_SAND] = "sand_" }
WS.AUTO = AUTO

-- overlay char -> { tile, solid }
local OVER = {
    T = { "trunk", true }, s = { "stump", true }, l = { "log", true }, o = { "rock", true },
    b = { "bush", false }, u = { "pumpkin", false }, c = { "cabbage", false }, v = { "vines", false },
    -- (small things - a barrel, a sack, a lamp post - do not take a whole 4-yard tile: they stay walkable)
    f = { "fence", true }, g = { "gravestone", false }, L = { "lamppost", false }, i = { "torch1", false },
    n = { "sign", false }, h = { "hay", true }, B = { "barrel", false }, C = { "crate", false }, k = { "sack", false },
    m = { "lumber", false }, a = { "cart", true }, W = { "well", true }, N = { "anvil", true }, d = { "dummy", false },
    r = { "rack", false }, y = { "n_scarecrow", false }, A = { "n_tent", true }, H = { "shed", true },
    U = { "statue", true }, F = { "banner", false }, w = { "awning", false }, p = { "campfire", true },
    t = { "tools", false },
    ["#"] = { "stonewall", true }, R = { "roof_", true }, D = { "door", false }, ["="] = { "bridge", false },
}
local OVERB = {}
for ch, v in pairs(OVER) do OVERB[byte(ch)] = v end
local O_SPACE, O_ROOF, O_DOOR, O_DECK, O_WALL = byte(" "), byte("R"), byte("D"), byte("="), byte("#")
WS.OVER = OVER

local function SameGround(cls, x, y)
    local g = WS.Tile(x, y)
    if WATER[cls] then return WATER[g] or g == G_VOID end
    return g == cls or g == G_VOID
end

local PIECES = { }
-- the 13-piece autotile name for class `cls` at (x, y) (the same rules as Game.lua's Autotile)
local function AutoPiece(prefix, same, x, y)
    local n, s, e, w = same(x, y - 1), same(x, y + 1), same(x + 1, y), same(x - 1, y)
    if n and s and e and w then
        if not same(x - 1, y - 1) then return prefix .. "inw" end
        if not same(x + 1, y - 1) then return prefix .. "ine" end
        if not same(x - 1, y + 1) then return prefix .. "isw" end
        if not same(x + 1, y + 1) then return prefix .. "ise" end
        return prefix .. "c"
    end
    if not n and not w then return prefix .. "tl" end
    if not n and not e then return prefix .. "tr" end
    if not s and not w then return prefix .. "bl" end
    if not s and not e then return prefix .. "br" end
    if not n then return prefix .. "t" end
    if not s then return prefix .. "b" end
    if not w then return prefix .. "l" end
    if not e then return prefix .. "r" end
    return prefix .. "c"
end
WS.AutoPiece = AutoPiece

local function GrassName(cls, x, y)
    -- (WoW's darker forest-floor grass is drawn as grass too: in single tiles it read as dark squares)
    return (x * 7 + y * 13) % 5 == 0 and "grass2" or "grass1"
end

-- the base (ground) tile name of (x, y)
function WS.BaseName(x, y)
    local g, _, _, b, i = WS.Tile(x, y)
    local cached = b.names and b.names[i]
    if cached then return cached end
    local name
    if g == G_VOID then
        name = "void"
    elseif WATER[g] then
        local same = function(xx, yy) return SameGround(g, xx, yy) end
        local piece = AutoPiece("water_", same, x, y)
        if piece == "water_c" and g == G_SHAL then piece = "shallow_c" end
        name = piece
    elseif AUTO[g] then
        local same = function(xx, yy) return SameGround(g, xx, yy) end
        name = AutoPiece(AUTO[g], same, x, y)
    else
        name = GrassName(g, x, y)
    end
    if b.names then b.names[i] = name end
    return name
end

local function IsRoof(x, y)
    local _, o = WS.Tile(x, y)
    return o == O_ROOF or o == O_DOOR
end

-- the overlay tile name of (x, y), or nil
function WS.OverName(x, y)
    local g, o, _, b, i = WS.Tile(x, y)
    local cached = b.overs and b.overs[i]
    if cached ~= nil then return cached or nil end
    local name
    if o == O_ROOF then
        if not IsRoof(x, y + 1) then
            name = "bwall"                          -- the building's front: a wall with windows
            if (x * 3 + y) % 4 == 1 then name = "bwindow" end
        else
            name = AutoPiece("roof_", IsRoof, x, y)
        end
    elseif o == O_DOOR then
        name = IsRoof(x, y + 1) and AutoPiece("roof_", IsRoof, x, y) or "door"
    elseif o == O_WALL then
        -- a bridge's sides: a railing; any other WMO wall: stone
        local function deck(xx, yy) local _, oo = WS.Tile(xx, yy) return oo == O_DECK end
        name = (deck(x - 1, y) or deck(x + 1, y) or deck(x, y - 1) or deck(x, y + 1)) and "railing" or "stonewall"
    elseif o ~= O_SPACE then
        local v = OVERB[o]
        name = v and v[1] or nil
    elseif g == G_FLOW then
        name = "flowers"
    end
    if b.overs then b.overs[i] = name or false end
    return name
end

-- Fine collision (gen_azeromon_world: azw_collide): per tile a 16-bit mask of SUB x SUB cells (~1 yard each,
-- bit sy * SUB + sx) from the client's own collision meshes - a trunk, a barrel, a building's walls take only the
-- cells they stand on. Blocks generated before it have none: their overlay tiles are solid whole, as before.
local SUB = 4
WS.SUB = SUB
local CENTRE = { 5, 6, 9, 10 }            -- the middle four cells (a tile's centre point is their corner)

-- the tile's collision mask, or nil (no fine data in its block)
function WS.CellMask(x, y)
    local _, _, _, b, i = WS.Tile(x, y)
    if not (b and b.cm) then return nil end
    local m = b.cmv[i]
    if m then return m end
    local k = (i - 1) * 3 + 1
    m = (RUNVAL[byte(b.cm, k)] - 1) * 4096 + (RUNVAL[byte(b.cm, k + 1)] - 1) * 64 + RUNVAL[byte(b.cm, k + 2)] - 1
    b.cmv[i] = m
    return m
end

local function Bit(m, n) return floor(m / 2 ^ n) % 2 == 1 end

-- is the point (x, y) (fractional tiles) inside something solid?
function WS.SolidAt(x, y)
    local tx, ty = floor(x), floor(y)
    local g, o, _, b, i = WS.Tile(tx, ty)
    if not (b and b.cm) then return WS.Solid(tx, ty) end
    if o == O_DECK or o == O_DOOR then return false end
    if SOLID_GROUND[g] then return true end
    local m = WS.CellMask(tx, ty)
    if m == 0 then return false end
    return Bit(m, floor((y - ty) * SUB) * SUB + floor((x - tx) * SUB))
end

function WS.Solid(x, y)
    local g, o, _, b = WS.Tile(x, y)
    if o == O_DECK or o == O_DOOR then return false end
    if b and b.cm then
        -- (a tile for paths: blocked when something stands on its middle)
        if SOLID_GROUND[g] then return true end
        local m = WS.CellMask(x, y)
        if m == 0 then return false end
        for _, n in ipairs(CENTRE) do if Bit(m, n) then return true end end
        return false
    end
    if o ~= O_SPACE then
        local v = OVERB[o]
        if v and v[2] then return true end
    end
    return SOLID_GROUND[g] or false
end

function WS.Shade(x, y)
    local _, _, s = WS.Tile(x, y)
    return s
end

---------------------------------------------------------------------------
-- Trees (crowns are drawn above everyone; the trunk tile is solid)
---------------------------------------------------------------------------

-- the trees whose crown may reach the rectangle (x0..x1, y0..y1)
function WS.TreesIn(x0, y0, x1, y1)
    local out = {}
    for cy = floor((y0 - 4) / CELL), floor((y1 + 4) / CELL) do
        for cx = floor((x0 - 4) / CELL), floor((x1 + 4) / CELL) do
            local list = W.treeCells[cy * 1024 + cx]
            if list then
                for _, t in ipairs(list) do
                    if t.x + t.r >= x0 and t.x - t.r <= x1 and t.y + t.r >= y0 and t.y - t.r <= y1 then
                        out[#out + 1] = t
                    end
                end
            end
        end
    end
    return out
end

-- scenery that may show in the rectangle (tiles): its sprites reach up to ~24 tiles from where they stand
function WS.SceneryIn(x0, y0, x1, y1)
    local out = {}
    for cy = floor((y0 - 8) / CELL), floor((y1 + 24) / CELL) do
        for cx = floor((x0 - 24) / CELL), floor((x1 + 24) / CELL) do
            local list = W.scenCells[cy * 1024 + cx]
            if list then
                for _, p in ipairs(list) do
                    local s, k = p.sp, p.k / p.pxt
                    local l, t = p.x - s.ox * k, p.y - s.oy * k
                    if l <= x1 and l + s.w * k >= x0 and t <= y1 and t + s.h * k >= y0 then
                        out[#out + 1] = p
                    end
                end
            end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Entities near a spot
---------------------------------------------------------------------------

function WS.EntitiesNear(x, y, radius)
    local out = {}
    for cy = floor((y - radius) / CELL), floor((y + radius) / CELL) do
        for cx = floor((x - radius) / CELL), floor((x + radius) / CELL) do
            local list = W.entCells[cy * 1024 + cx]
            if list then
                for _, e in ipairs(list) do out[#out + 1] = e end
            end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- The compiled map (what G.Compile returns for a world map)
---------------------------------------------------------------------------

local function XY(k) return k % WIDTH, floor(k / WIDTH) end

local function Lazy(fn)
    return setmetatable({}, { __index = function(_, k)
        if type(k) ~= "number" then return nil end
        local x, y = XY(k)
        return fn(x, y)
    end })
end

local RESOURCE = { ["Peacebloom"] = "peacebloom", ["Silverleaf"] = "silverleaf", ["Earthroot"] = "earthroot",
                   ["Mageroyal"] = "mageroyal", ["Briarthorn"] = "briarthorn", ["Copper Vein"] = "copper",
                   ["Tin Vein"] = "tin" }
WS.RESOURCE = RESOURCE

local nodeAt, objectAt = {}, {}
local indexed = false
local function IndexObjects()
    if indexed then return end
    indexed = true
    for _, e in ipairs(W.ents) do
        if e.k == "obj" then
            local k = e.y * WIDTH + e.x
            local res = RESOURCE[e.n]
            if (e.kind == "herb" or e.kind == "ore") and res then
                nodeAt[k] = { x = e.x, y = e.y, kind = e.kind, list = { res }, ent = e }
            else
                objectAt[k] = e
            end
        end
    end
end
WS.IndexObjects = IndexObjects

function WS.Compile(id, def, G)
    IndexObjects()
    local m = { id = id, def = def, world = true, w = WIDTH, h = WIDTH, theme = G.THEMES.elwynn,
                tall = {}, sign = {}, chest = {}, trigger = {} }
    m.key = function(x, y) return y * WIDTH + x end
    m.base = Lazy(WS.BaseName)
    m.over = Lazy(WS.OverName)
    m.solid = Lazy(WS.Solid)
    m.shade = Lazy(WS.Shade)
    m.water = {}               -- (the world draws its own water pieces; UI.lua swaps m.water tiles for a frame)
    m.isWater = Lazy(function(x, y) return WATER[(WS.Tile(x, y))] or false end)
    m.node = setmetatable({}, { __index = function(_, k) return nodeAt[k] end })
    m.object = setmetatable({}, { __index = function(_, k)
        local e = objectAt[k]
        return e and WS.ObjectDef and WS.ObjectDef(e) or nil
    end })
    m.warp = setmetatable({}, { __index = function(_, k)
        local d = W.doors[k]
        return d and WS.DoorWarp and WS.DoorWarp(d) or nil
    end })
    return m
end
