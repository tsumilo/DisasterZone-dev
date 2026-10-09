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
-- Overlay: tree trunks, rocks, fences, props, building blocks (R), walls (#), decks (=) - see OVER. Buildings with
-- rooms are walked in place: their walk grids (W.AddBuilding, WS.Layers) say where a body stands at what height.
local addonName, ns = ...

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local byte, sub, rep, concat = string.byte, string.sub, string.rep, table.concat

local W = { blocks = {}, areas = {}, treeCells = {}, entCells = {}, ents = {} }
ns.AzeroWorldData = W
local WS = {}
ns.AzeroLand = WS
ns.AzeroData = ns.AzeroData or {}  -- (Species.lua fills it: sprites, species, CLASS_SPR)

local WIDTH = 8192                 -- tiles across the map (64 ADTs x 128)
local BLOCK = 32
local CELL = 16                    -- entity / tree index cell (tiles)
local SUB = 4                      -- fine cells a tile (collision, building walk grids)
WS.WIDTH, WS.BLOCK, WS.SUB = WIDTH, BLOCK, SUB
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

-- placements, flat { sprite (0-based), x, y, sort y (map pixels, 16 a tile), size x 100, ... }; bld: the building
-- walked in place these pieces show from outside (hidden while you are in it)
W.scenCells = {}
function W.AddScenery(sp, flat, bld)
    for i = 1, #flat, 5 do
        local s = sp.list[flat[i] + 1]
        local k = flat[i + 4] / 100
        local p = { sp = s, file = sp.file .. s.page, x = flat[i + 1] / 16, y = flat[i + 2] / 16,
                    sort = flat[i + 3] / 16, k = math.abs(k), pxt = sp.pxt, tree = k < 0 or nil, bld = bld }
        local key = floor(p.y / CELL) * 1024 + floor(p.x / CELL)
        local list = W.scenCells[key]
        if not list then list = {} W.scenCells[key] = list end
        list[#list + 1] = p
    end
end

-- a building's depth slices outdoors: flat { sprite, x, y, sort (16 a tile) }; each slice sorts at the ground row
-- under it, so whatever stands behind one wing and in front of another is drawn right (and may fade: wall)
function W.AddSceneryWalls(sp, flat, bld)
    for i = 1, #flat, 4 do
        local s = sp.list[flat[i] + 1]
        local p = { sp = s, file = sp.file .. s.page, x = flat[i + 1] / 16, y = flat[i + 2] / 16,
                    sort = flat[i + 3] / 16, k = 1, pxt = sp.pxt, wall = true, bld = bld }
        local key = floor(p.y / CELL) * 1024 + floor(p.x / CELL)
        local list = W.scenCells[key]
        if not list then list = {} W.scenCells[key] = list end
        list[#list + 1] = p
    end
end

-- A building walked in place (gen: azw_building): its walk grid - SUB x SUB cells a tile from cell (x0, y0), w x h,
-- one string a row (see WS.Layers) - and its storeys { f = floor, top = where the next one begins } in yards over
-- the building's origin, the frame its pictures are drawn in (a body h yards up is drawn 0.6 h yards up the screen)
W.buildings = {}
W.bldCells = {}
function W.AddBuilding(def)
    def.dec = {}
    def.art = {}
    W.buildings[def.id] = def
    for cy = floor(def.y0 / SUB / CELL), floor((def.y0 + def.h) / SUB / CELL) do
        for cx = floor(def.x0 / SUB / CELL), floor((def.x0 + def.w) / SUB / CELL) do
            local key = cy * 1024 + cx
            local list = W.bldCells[key]
            if not list then list = {} W.bldCells[key] = list end
            list[#list + 1] = def
        end
    end
end

-- a storey's cut-away picture: the floor pieces { sprite, x, y } under everyone, the walls { sprite, x, y, sort }
-- in depth slices
function W.AddBuildingArt(id, storey, sp, flat, walls)
    local b = W.buildings[id]
    if not b then return end
    local list = {}
    b.art[storey] = list
    for i = 1, #flat, 3 do
        local s = sp.list[flat[i] + 1]
        list[#list + 1] = { sp = s, file = sp.file .. s.page, x = flat[i + 1] / 16, y = flat[i + 2] / 16,
                            sort = -1e6, k = 1, pxt = sp.pxt, cut = true }
    end
    for i = 1, #walls, 4 do
        local s = sp.list[walls[i] + 1]
        list[#list + 1] = { sp = s, file = sp.file .. s.page, x = walls[i + 1] / 16, y = walls[i + 2] / 16,
                            sort = walls[i + 3] / 16, k = 1, pxt = sp.pxt, wall = true, cut = true }
    end
end

-- e.k = "npc" | "mob" | "obj"; e.g = the spawn's database guid (stable id); in a building e.ht is the height it
-- stands at (yards over the building's origin) and e.xf / e.yf its exact spot
function W.Add(e)
    W.ents[#W.ents + 1] = e
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

---------------------------------------------------------------------------
-- Buildings walked in place: per fine cell the layers a body may stand on
---------------------------------------------------------------------------

-- the building whose walk grid covers the point (x, y) (tiles), and that cell
function WS.BuildingAt(x, y)
    local cx, cy = floor(x * SUB), floor(y * SUB)
    local list = W.bldCells[floor(y / CELL) * 1024 + floor(x / CELL)]
    if not list then return nil end
    for _, b in ipairs(list) do
        if cx >= b.x0 and cy >= b.y0 and cx < b.x0 + b.w and cy < b.y0 + b.h then return b, cx, cy end
    end
    return nil
end

local B64VAL = {}
for i = 1, #RUNS do B64VAL[byte(RUNS, i)] = i - 1 end
local L_NONE, L_OUT = byte("."), byte("o")

-- a row of the grid: per cell (from x0) its list of layers { h, ind, ter, st, [1..4] = link n e s w }; a link is
-- the neighbour's layer index, 0 = outdoors (the world's own ground and collision), nil = no way
local function DecodeRow(b, j)
    local s = b.rows[j + 1]
    local row = {}
    local i, x = 1, 0
    while s and i <= #s do
        local run = B64VAL[byte(s, i)] + 1
        local n = B64VAL[byte(s, i + 1)]
        i = i + 2
        local lay = {}
        for k = 1, n do
            local v = B64VAL[byte(s, i)] * 64 + B64VAL[byte(s, i + 1)]
            local fl = B64VAL[byte(s, i + 2)]
            local l = { h = v / 16 - 128, ind = fl % 2 == 1, ter = floor(fl / 2) % 2 == 1 }
            local st = floor(fl / 4)
            if st > 0 then l.st = st end
            for d = 1, 4 do
                local c = byte(s, i + 2 + d)
                if c == L_OUT then l[d] = 0 elseif c ~= L_NONE then l[d] = B64VAL[c] + 1 end
            end
            lay[k] = l
            i = i + 7
        end
        for _ = 1, run do
            row[x] = lay
            x = x + 1
        end
    end
    b.dec[j] = row
    return row
end

local NOLAYERS = {}
-- the layers of building b's fine cell (cx, cy) (world cell coordinates); empty: plain ground (outdoor rules)
function WS.Layers(b, cx, cy)
    local j, i = cy - b.y0, cx - b.x0
    if i < 0 or j < 0 or i >= b.w or j >= b.h then return NOLAYERS end
    local row = b.dec[j] or DecodeRow(b, j)
    return row[i] or NOLAYERS
end

-- the storey (1-based) a height h is in, in building b
function WS.StoreyOf(b, h)
    local s = b.storeys
    for k = 1, #s do
        if h < s[k].top then return k end
    end
    return #s > 0 and #s or nil
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
    return m
end
