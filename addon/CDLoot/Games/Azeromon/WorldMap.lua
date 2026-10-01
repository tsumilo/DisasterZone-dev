if CDLootBoot and CDLootBoot.Run("Games/Azeromon/WorldMap.lua", ...) then return end -- CDLoot Games/Azeromon/WorldMap.lua
-- ns.AzeroWorld: the world map (START > MAP). A schematic of every place, laid out the way the maps connect
-- (Elwynn's north road leads to Westfall, Sentinel Hill's east road to Duskwood), not WoW's real geography.
-- A place groups maps (a town and its houses). Roads come from the maps' edges and warps, gryphon routes from
-- W.FLIGHTS. A place shows as ??? until the player has set foot there (save.visited, kept by G:EnterMap).
-- Its info: what it offers (NPC roles and objects in Maps.lua), wild levels, beasts seen / tamed, trainers
-- beaten, its badge, and guildmates there right now (AzeroNet presence).
-- A new map must join a place in W.PLACES (a test checks every map belongs to exactly one).
local addonName, ns = ...

local W = {}
ns.AzeroWorld = W
local G, D, Maps = ns.Azero, ns.AzeroData, ns.AzeroMaps

-- x, y: grid position (columns west to east, rows north to south). kind: town | route | dungeon | arena
W.PLACES = {
    { id = "deadmines", name = "The Deadmines", zone = "westfall", kind = "dungeon", x = 0, y = 1,
      maps = { "dm1", "dm2", "dm3" }, text = "VanCleef's hideout under Moonbrook: a mine, a foundry and a ship." },
    { id = "moonbrook", name = "Moonbrook", zone = "westfall", kind = "route", x = 1, y = 1, maps = { "moonbrook" },
      text = "A burned town the Defias call their own. The Deadmines open here." },
    { id = "sentinel", name = "Sentinel Hill", zone = "westfall", kind = "town", x = 2, y = 1,
      maps = { "sentinel", "sentinelinn" }, text = "Gryan Stoutmantle's People's Militia holds the hill." },
    { id = "ravenhill", name = "Raven Hill", zone = "duskwood", kind = "route", x = 3, y = 1, maps = { "ravenhill" },
      text = "An empty village above a restless cemetery." },
    { id = "duskwood", name = "Duskwood", zone = "duskwood", kind = "route", x = 4, y = 1,
      maps = { "duskwood", "mistmantle" }, text = "The road through the dark woods, past Manor Mistmantle." },
    { id = "darkshire", name = "Darkshire", zone = "duskwood", kind = "town", x = 5, y = 1,
      maps = { "darkshire", "darkshireinn" }, text = "The Night Watch keeps its lamps lit here all night." },
    { id = "westfall", name = "Westfall", zone = "westfall", kind = "route", x = 2, y = 2,
      maps = { "westfall", "saldean" }, text = "Fields gone wild: harvest golems, coyotes and the Saldeans' farm." },
    { id = "forestedge", name = "Forest's Edge", zone = "elwynn", kind = "route", x = 1, y = 3,
      maps = { "forestedge" }, text = "Hogger's gnolls camp in the woods here." },
    { id = "elwynn", name = "Elwynn Forest", zone = "elwynn", kind = "route", x = 2, y = 3, maps = { "route1" },
      text = "Wolves, kobolds and owls between Goldshire and Westfall." },
    { id = "goldshire", name = "Goldshire", zone = "elwynn", kind = "town", x = 2, y = 4,
      maps = { "town", "home", "lab", "post", "hideout" },
      text = "Home: Huntmaster Aldric's lodge, the Lion's Pride Inn and the Guild Hall beneath it." },
    -- Stranglethorn Vale: the road south from Darkshire, down to Booty Bay
    { id = "rebelcamp", name = "The Rebel Camp", zone = "stv", kind = "route", x = 5, y = 2, maps = { "rebelcamp" },
      text = "Kurzen's deserters camp just over the Duskwood border." },
    { id = "kurzen", name = "Kurzen's Compound", zone = "stv", kind = "dungeon", x = 6, y = 2, maps = { "kurzen" },
      text = "Colonel Kurzen's cave. Troll medicine and bad orders." },
    { id = "stvnorth", name = "Northern Stranglethorn", zone = "stv", kind = "route", x = 5, y = 2.7,
      maps = { "stvnorth" }, text = "Nesingwary's Expedition, Lake Nazferiti and the Bal'lal Ruins." },
    { id = "zulmamwe", name = "Zul'Mamwe", zone = "stv", kind = "route", x = 5, y = 3.4, maps = { "zulmamwe" },
      text = "Skullsplitter ruins and the Venture Company's dig." },
    { id = "moshogg", name = "Mosh'Ogg Mound", zone = "stv", kind = "dungeon", x = 6, y = 3.4, maps = { "moshogg" },
      text = "The ogres' cave. Mai'Zoth has two heads and one club." },
    { id = "arena", name = "Gurubashi Arena", zone = "stv", kind = "arena", x = 5, y = 4.1, maps = { "arena" },
      text = "Short John Mithril's beast fights, on the road through the vale." },
    { id = "stvsouth", name = "Southern Stranglethorn", zone = "stv", kind = "route", x = 5, y = 4.8,
      maps = { "stvsouth" }, text = "Mistvale Valley's gorillas and the road to the coast." },
    { id = "crystalvein", name = "Crystalvein Mine", zone = "stv", kind = "dungeon", x = 6, y = 4.8,
      maps = { "crystalvein" }, text = "The Venture Company's basilisk-crystal mine." },
    { id = "wildshore", name = "The Wild Shore", zone = "stv", kind = "route", x = 5, y = 5.5, maps = { "wildshore" },
      text = "The Ruins of Aboraz, the Bloodsail landing and Firallon's ship." },
    { id = "bootybay", name = "Booty Bay", zone = "stv", kind = "town", x = 5, y = 6.2,
      maps = { "bootybay", "bootybayinn", "bbhall" }, text = "Baron Revilgaz's port: the Salty Sailor Tavern and the docks." },
    { id = "jaguero", name = "Jaguero Isle", zone = "stv", kind = "route", x = 6, y = 6.4, maps = { "jaguero" },
      text = "King Mukla's island, a short boat ride from the bay." },
}

-- The coloured regions behind the places (grid units, like the places).
W.ZONES = {
    { id = "westfall", name = "WESTFALL", color = { 0.93, 0.84, 0.58 }, x0 = -0.45, y0 = 0.42, x1 = 2.45, y1 = 2.5 },
    { id = "elwynn", name = "ELWYNN FOREST", color = { 0.64, 0.83, 0.55 }, x0 = 0.55, y0 = 2.5, x1 = 2.45, y1 = 4.45 },
    { id = "duskwood", name = "DUSKWOOD", color = { 0.50, 0.48, 0.64 }, x0 = 2.55, y0 = 0.42, x1 = 5.45, y1 = 1.6,
      dark = true },
    { id = "stv", name = "STRANGLETHORN", color = { 0.52, 0.74, 0.50 }, x0 = 3.95, y0 = 1.65, x1 = 6.45, y1 = 6.75,
      labelBottom = true },
}

-- Gryphon routes (dotted), shown once both ends are known and `flag` is set. `via`: bends on the way.
W.FLIGHTS = {
    { from = "sentinel", to = "arena", via = { { 3.0, 2.5 } } },
    { from = "sentinel", to = "darkshire", flag = "fp_darkshire", via = { { 2, 0.62 }, { 5, 0.62 } } },
    { from = "bootybay", to = "darkshire", flag = "fp_bootybay", via = { { 6.6, 6.2 }, { 6.6, 1 } } },
}

W.TAG_NAMES = { inn = "Inn", rest = "Rest", shop = "Shop", stable = "Stable", profession = "Profession trainers",
                pettrainer = "Pet trainer", gryphon = "Gryphons", arena = "Beast fights", board = "Bounty board",
                craft = "Forge and anvil", alchemy = "Alchemy table" }
W.TAG_ORDER = { "inn", "rest", "shop", "stable", "board", "profession", "pettrainer", "craft", "alchemy", "gryphon", "arena" }
local OBJECT_TAGS = { wantedboard = "board", anvil = "craft", forge = "craft", alchemy = "alchemy" }

W.byId, W.placeOfMap = {}, {}
for _, p in ipairs(W.PLACES) do
    W.byId[p.id] = p
    for _, m in ipairs(p.maps) do W.placeOfMap[m] = p end
end

function W.PlaceOf(mapId) return W.placeOfMap[mapId] end

---------------------------------------------------------------------------
-- Visited places
---------------------------------------------------------------------------

function W.Visited(place)
    local v = G.save and G.save.visited
    if type(v) ~= "table" then return false end
    for _, m in ipairs(place.maps) do if v[m] then return true end end
    return false
end

-- Saves from before the map: count a map as visited when a trainer there was beaten or a chest opened (plus
-- where the player stands and rests, and home).
local function Backfill(g)
    local s = g.save
    if type(s.visited) == "table" then return end
    local v = {}
    s.visited = v
    v[Maps.START.map], v[s.map] = true, true
    if type(s.respawn) == "table" and s.respawn.map then v[s.respawn.map] = true end
    for id, def in pairs(Maps) do
        if type(def) == "table" and def.rows then
            for _, n in ipairs(def.npcs or {}) do
                if n.trainer and g:Flag("beat_" .. n.trainer) then v[id] = true end
            end
            for _, c in ipairs(def.chests or {}) do
                if g:Flag("chest_" .. c.id) then v[id] = true end
            end
        end
    end
    if g:Flag("fp_darkshire") then v.darkshire = true end
end
W.Backfill = Backfill
G:On("load", function(g) Backfill(g) end)

---------------------------------------------------------------------------
-- Roads, flights, neighbours
---------------------------------------------------------------------------

-- Pairs of places joined by an edge or a warp between their maps: { { a, b }, ... } (each pair once).
function W.Roads()
    local out, seen = {}, {}
    local function add(a, b)
        if not a or not b or a == b then return end
        local k = a.id < b.id and (a.id .. "|" .. b.id) or (b.id .. "|" .. a.id)
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = { a, b }
        end
    end
    for _, p in ipairs(W.PLACES) do
        for _, m in ipairs(p.maps) do
            local def = Maps[m]
            for _, e in pairs(def and def.edges or {}) do add(p, W.placeOfMap[e.map]) end
            for _, wp in ipairs(def and def.warps or {}) do add(p, W.placeOfMap[wp.map]) end
        end
    end
    return out
end

function W.FlightShown(fl)
    return W.Visited(W.byId[fl.from]) and W.Visited(W.byId[fl.to]) and (not fl.flag or G:Flag(fl.flag)) and true or false
end

-- The nearest place from `id` in direction dir (up / down / left / right), favouring places in line.
local STEP = { left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 } }
function W.Neighbour(id, dir)
    local from, d = W.byId[id], STEP[dir]
    if not from or not d then return id end
    local best, bestScore
    for _, p in ipairs(W.PLACES) do
        local vx, vy = p.x - from.x, p.y - from.y
        local along = vx * d[1] + vy * d[2]
        if p ~= from and along > 0.01 then
            local score = along + 2 * (math.abs(vx * d[2]) + math.abs(vy * d[1]))
            if not bestScore or score < bestScore then best, bestScore = p, score end
        end
    end
    return best and best.id or id
end

---------------------------------------------------------------------------
-- What a place offers and how far the player has got there
---------------------------------------------------------------------------

function W.Info(place)
    local info = { name = place.name, visited = W.Visited(place), here = {}, tags = {} }
    info.you = G.save and W.placeOfMap[G.save.map] == place or false
    local tagSet, beasts, lo, hi = {}, {}, nil, nil
    local trainers, beaten = 0, 0
    for _, m in ipairs(place.maps) do
        local def = Maps[m] or {}
        for _, n in ipairs(def.npcs or {}) do
            if n.role then tagSet[n.role] = true end
            if n.trainer then
                trainers = trainers + 1
                if G:Flag("beat_" .. n.trainer) then beaten = beaten + 1 end
                local t = D.trainers[n.trainer]
                if t and t.badge and D.badges[t.badge] then
                    info.badge = { name = D.badges[t.badge].name, earned = G:Flag("badge_" .. t.badge) and true or false }
                end
            end
        end
        for _, o in ipairs(def.objects or {}) do
            if OBJECT_TAGS[o.tile] then tagSet[OBJECT_TAGS[o.tile]] = true end
        end
        for _, list in ipairs({ def.encounters or {}, def.coastEncounters or {} }) do
            for _, e in ipairs(list) do
                if not e.rare then
                    beasts[e.sp] = true
                    lo, hi = math.min(lo or e.min, e.min), math.max(hi or e.max, e.max)
                end
            end
        end
        local net = ns.AzeroNet
        for _, p in ipairs(net and net.PeersOn and net:PeersOn(m) or {}) do info.here[#info.here + 1] = p end
    end
    for _, t in ipairs(W.TAG_ORDER) do if tagSet[t] then info.tags[#info.tags + 1] = W.TAG_NAMES[t] end end
    if lo then info.wild = { lo, hi } end
    local total, seen, caught = 0, 0, 0
    for sp in pairs(beasts) do
        total = total + 1
        if G.save.seen[sp] then seen = seen + 1 end
        if G.save.caught[sp] then caught = caught + 1 end
    end
    if total > 0 then info.beasts = { seen = seen, caught = caught, total = total } end
    if trainers > 0 then info.trainers = { beaten = beaten, total = trainers } end
    table.sort(info.here, function(a, b) return (a.name or "") < (b.name or "") end)
    return info
end

-- The info box's lines for a place: name, zone, then up to three lines of text.
function W.Lines(place)
    local info = W.Info(place)
    local zone
    for _, z in ipairs(W.ZONES) do if z.id == place.zone then zone = z.name end end
    local names = {}
    for i, p in ipairs(info.here) do names[i] = p.name end
    local here = #names > 0 and ("Guildmates here: " .. table.concat(names, ", ")) or ""
    if not info.visited then
        return { name = "???", zone = zone or "", text = "You haven't been here yet.", line3 = "", line4 = here, you = info.you }
    end
    local l3 = {}
    if info.wild then l3[#l3 + 1] = string.format("Wild beasts Lv %d-%d", info.wild[1], info.wild[2]) end
    if #info.tags > 0 then l3[#l3 + 1] = table.concat(info.tags, ", ") end
    local l4 = {}
    if info.you then l4[#l4 + 1] = "You are here." end
    if info.beasts then
        l4[#l4 + 1] = string.format("Beasts %d/%d seen, %d tamed", info.beasts.seen, info.beasts.total, info.beasts.caught)
    end
    if info.trainers then l4[#l4 + 1] = string.format("Trainers %d/%d", info.trainers.beaten, info.trainers.total) end
    if info.badge then l4[#l4 + 1] = info.badge.name .. (info.badge.earned and ": earned" or ": not yet") end
    if here ~= "" then l4[#l4 + 1] = here end
    return { name = place.name, zone = zone or "", text = place.text or "", line3 = table.concat(l3, "     "),
             line4 = table.concat(l4, "     "), you = info.you }
end

---------------------------------------------------------------------------
-- The panel (START > MAP)
---------------------------------------------------------------------------

local MAP_X, MAP_Y, MAP_W, MAP_H = 22, -48, 464, 242       -- the drawing area inside the panel
local GX0, GY0, GW, GH = -0.5, 0.4, 7.3, 6.7               -- the grid window it shows
local NODE = { town = 14, route = 9, dungeon = 12, arena = 14 }
local SEA, SEA_EDGE = { 0.55, 0.72, 0.84 }, { 0.42, 0.58, 0.72 }
local INK = { 0.18, 0.17, 0.22 }
local FILL = { town = { 0.99, 0.94, 0.82 }, route = { 0.99, 0.96, 0.86 }, dungeon = { 0.40, 0.36, 0.42 },
               arena = { 0.97, 0.66, 0.24 } }
local ROOF = { 0.80, 0.26, 0.22 }
local UNKNOWN = { 0.70, 0.72, 0.76 }
local ROAD, ROAD_DIM, ROAD_EDGE = { 0.90, 0.78, 0.52 }, { 0.72, 0.72, 0.74 }, { 0.46, 0.36, 0.22 }
-- Props scattered over each zone (grid units), drawn with the zone's own overworld tiles: trees, flowers, hay,
-- gravestones and palms, placed clear of the places and roads.
local PROPS = {
    elwynn = { { "tree", 0.8, 2.75 }, { "tree", 1.45, 2.72 }, { "tree", 1.2, 3.5 }, { "tree", 0.85, 4.1 },
               { "tree", 1.5, 4.22 }, { "tree", 2.3, 3.6 }, { "flowers", 1.7, 3.85 }, { "flowers", 0.78, 3.35 } },
    westfall = { { "wtree", 0.15, 0.62 }, { "wtree", 1.0, 0.58 }, { "wtree", 1.5, 1.6 }, { "wtree", 0.4, 1.7 },
                 { "wtree", 1.2, 2.25 }, { "wtree", -0.05, 2.2 }, { "hay", 0.7, 1.5 }, { "pumpkin", 1.75, 2.2 },
                 { "hay", 2.25, 0.6 } },
    duskwood = { { "dtree", 2.8, 1.38 }, { "dtree", 3.5, 0.62 }, { "dtree", 4.5, 1.4 }, { "dtree", 5.2, 0.65 },
                 { "dtree", 3.6, 1.4 }, { "dtree", 4.3, 0.62 }, { "gravestone", 4.85, 1.4 }, { "deadtree", 3.05, 0.75 } },
    stv = { { "jtree", 4.3, 1.95 }, { "jtree", 4.55, 2.6 }, { "jtree", 4.2, 3.3 }, { "jtree", 4.6, 4.0 },
            { "jtree", 4.3, 4.7 }, { "jtree", 4.6, 5.4 }, { "jtree", 4.2, 6.0 }, { "jtree", 5.6, 2.6 },
            { "jtree", 6.2, 2.8 }, { "jtree", 5.6, 4.15 }, { "jtree", 6.2, 4.2 }, { "jtree", 5.6, 5.5 },
            { "jtree", 6.25, 5.6 }, { "totem_0_0", 4.5, 3.65 }, { "jtree", 6.3, 1.9 } },
}
-- a few waves on the open sea
local WAVES = { { 3.0, 2.2 }, { 3.45, 3.0 }, { 3.0, 3.9 }, { 3.5, 4.6 }, { 2.9, 5.5 }, { 1.5, 5.2 }, { 0.5, 5.0 },
                { 2.2, 6.0 }, { 0.15, 3.3 }, { 6.1, 1.0 }, { 6.65, 3.0 }, { 6.65, 5.2 }, { 3.6, 5.9 }, { -0.2, 4.2 } }

local function PX(x) return MAP_X + (x - GX0) / GW * MAP_W end
local function PY(y) return MAP_Y - (y - GY0) / GH * MAP_H end

local function Rect(K, f, layer, sub, x0, y0, x1, y1, c, a)
    local t = K.Tex(f, layer, sub)
    t:SetPoint("TOPLEFT", f, "TOPLEFT", math.min(x0, x1), math.max(y0, y1))
    t:SetSize(math.max(1, math.abs(x1 - x0)), math.max(1, math.abs(y1 - y0)))
    t:SetColorTexture(c[1], c[2], c[3], a or 1)
    return t
end

-- A hollow frame (four thin rects) around a box.
local function Ring(K, f, layer, sub, x0, y0, x1, y1, w, c)
    local r = {}
    r[1] = Rect(K, f, layer, sub, x0, y0, x1, y0 - w, c)
    r[2] = Rect(K, f, layer, sub, x0, y1 + w, x1, y1, c)
    r[3] = Rect(K, f, layer, sub, x0, y0, x0 + w, y1, c)
    r[4] = Rect(K, f, layer, sub, x1 - w, y0, x1, y1, c)
    return r
end

-- A triangle of stacked strips pointing `dir` (up / down / left / right), its base `size` wide, tip at (tx, ty).
local function Tri(K, f, layer, sub, dir, size, tx, ty, c)
    local steps = math.max(2, math.floor(size / 2))
    local out = {}
    for i = 0, steps - 1 do
        local len = size * (i + 1) / steps
        local d = i * (size / 2 / steps)
        if dir == "up" then out[#out + 1] = Rect(K, f, layer, sub, tx - len / 2, ty - d, tx + len / 2, ty - d - size / 2 / steps, c)
        elseif dir == "down" then out[#out + 1] = Rect(K, f, layer, sub, tx - len / 2, ty + d, tx + len / 2, ty + d + size / 2 / steps, c)
        elseif dir == "left" then out[#out + 1] = Rect(K, f, layer, sub, tx + d, ty + len / 2, tx + d + size / 2 / steps, ty - len / 2, c)
        else out[#out + 1] = Rect(K, f, layer, sub, tx - d, ty + len / 2, tx - d - size / 2 / steps, ty - len / 2, c) end
    end
    return out
end

-- An overworld tile from the atlas, `size` pixels square, centred on (cx, cy).
local function Prop(K, f, layer, sub, name, cx, cy, size, alpha)
    local t = K.Tex(f, layer, sub)
    K.Tile(t, name)
    t:SetSize(size, size)
    t:SetPoint("CENTER", f, "TOPLEFT", cx, cy)
    if alpha then t:SetAlpha(alpha) end
    return t
end

-- A road between two places: straight, or an L (along x first) when they aren't in line. A dark edge under a
-- lighter centre.
local function RoadPieces(K, f, a, b)
    local pieces, w = {}, 2
    local ax, ay, bx, by = PX(a.x), PY(a.y), PX(b.x), PY(b.y)
    if ay ~= by then
        Rect(K, f, "BORDER", 1, bx - w - 1, ay + 1, bx + w + 1, by - 1, ROAD_EDGE)
        pieces[#pieces + 1] = Rect(K, f, "BORDER", 2, bx - w, ay, bx + w, by, ROAD)
    end
    if ax ~= bx then
        Rect(K, f, "BORDER", 1, ax - 1, ay - w - 1, bx + 1, ay + w + 1, ROAD_EDGE)
        pieces[#pieces + 1] = Rect(K, f, "BORDER", 2, ax, ay - w, bx, ay + w, ROAD)
    end
    return pieces
end

-- Dots every few pixels along a polyline (gryphon routes).
local function DottedLine(K, f, pts)
    local dots = {}
    for i = 1, #pts - 1 do
        local x0, y0, x1, y1 = pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2]
        local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
        for s = 0, len, 8 do
            local t = len > 0 and s / len or 0
            local x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            dots[#dots + 1] = Rect(K, f, "BORDER", 3, x - 1.5, y + 1.5, x + 1.5, y - 1.5, { 0.30, 0.42, 0.66 })
        end
    end
    return dots
end

-- The marker of a place: a house for a town, a cave mouth for a dungeon, a ring for the arena, a small stone
-- for a route. `art` is hidden while the place is unknown (a grey stone shows instead).
local function NodeArt(K, f, p, cx, cy)
    local s = NODE[p.kind]
    local art = {}
    if p.kind == "town" then
        art[#art + 1] = Rect(K, f, "ARTWORK", 2, cx - 6, cy + 1, cx + 6, cy - 7, INK)             -- the walls
        art[#art + 1] = Rect(K, f, "ARTWORK", 3, cx - 5, cy, cx + 5, cy - 6, FILL.town)
        art[#art + 1] = Rect(K, f, "ARTWORK", 4, cx - 1, cy - 2, cx + 1, cy - 6, INK)             -- the door
        for _, t in ipairs(Tri(K, f, "ARTWORK", 3, "up", 18, cx, cy + 9, INK)) do art[#art + 1] = t end   -- the roof
        for _, t in ipairs(Tri(K, f, "ARTWORK", 4, "up", 14, cx, cy + 7, ROOF)) do art[#art + 1] = t end
    elseif p.kind == "dungeon" then
        art[#art + 1] = Rect(K, f, "ARTWORK", 2, cx - s / 2, cy + s / 2, cx + s / 2, cy - s / 2, INK)
        art[#art + 1] = Rect(K, f, "ARTWORK", 3, cx - s / 2 + 1, cy + s / 2 - 1, cx + s / 2 - 1, cy - s / 2 + 1, FILL.dungeon)
        art[#art + 1] = Rect(K, f, "ARTWORK", 4, cx - 3, cy + 1, cx + 3, cy - s / 2 + 1, { 0.06, 0.05, 0.08 })  -- the mouth
    elseif p.kind == "arena" then
        art[#art + 1] = Rect(K, f, "ARTWORK", 2, cx - s / 2, cy + s / 2, cx + s / 2, cy - s / 2, INK)
        art[#art + 1] = Rect(K, f, "ARTWORK", 3, cx - s / 2 + 1, cy + s / 2 - 1, cx + s / 2 - 1, cy - s / 2 + 1, FILL.arena)
        art[#art + 1] = Rect(K, f, "ARTWORK", 4, cx - 3, cy + 3, cx + 3, cy - 3, { 0.99, 0.94, 0.82 })          -- the ring
        art[#art + 1] = Rect(K, f, "ARTWORK", 5, cx - 2, cy + 2, cx + 2, cy - 2, FILL.arena)
    else
        art[#art + 1] = Rect(K, f, "ARTWORK", 2, cx - s / 2, cy + s / 2, cx + s / 2, cy - s / 2, INK)
        art[#art + 1] = Rect(K, f, "ARTWORK", 3, cx - s / 2 + 1, cy + s / 2 - 1, cx + s / 2 - 1, cy - s / 2 + 1, FILL.route)
    end
    return art
end

function W:Build(K)
    local SW, SH = K.SW, K.SH
    local f = K.Box(K.Screen(), SW - 20, SH - 20, 100)
    f:SetPoint("CENTER")
    f.noPool = true
    local t = K.Font(f, 18, nil, true)
    t:SetPoint("TOPLEFT", 22, -18)
    t:SetTextColor(0.20, 0.36, 0.62)
    t:SetText("WORLD MAP")
    -- the sea, framed
    Rect(K, f, "BACKGROUND", 0, MAP_X - 2, MAP_Y + 2, MAP_X + MAP_W + 2, MAP_Y - MAP_H - 2, INK)
    Rect(K, f, "BACKGROUND", 1, MAP_X, MAP_Y, MAP_X + MAP_W, MAP_Y - MAP_H, SEA)
    Ring(K, f, "BACKGROUND", 2, MAP_X, MAP_Y, MAP_X + MAP_W, MAP_Y - MAP_H, 1, SEA_EDGE)
    for _, wv in ipairs(WAVES) do Prop(K, f, "BACKGROUND", 3, "water1", PX(wv[1]), PY(wv[2]), 10, 0.55) end
    -- the zones: an ink edge, a lighter shore, the land, corners nipped so they read as coast
    for _, z in ipairs(W.ZONES) do
        local x0, y0, x1, y1 = PX(z.x0), PY(z.y0), PX(z.x1), PY(z.y1)
        local c = z.color
        local shore = { c[1] * 0.5 + SEA[1] * 0.5, c[2] * 0.5 + SEA[2] * 0.5, c[3] * 0.5 + SEA[3] * 0.5 }
        Rect(K, f, "BACKGROUND", 4, x0 - 2, y0 + 2, x1 + 2, y1 - 2, shore)
        Rect(K, f, "BACKGROUND", 5, x0, y0, x1, y1, { c[1] * 0.72, c[2] * 0.72, c[3] * 0.72 })
        Rect(K, f, "BACKGROUND", 6, x0 + 2, y0 - 2, x1 - 2, y1 + 2, c)
        for _, corner in ipairs({ { x0 - 2, y0 + 2, x0 + 2, y0 - 2 }, { x1 - 2, y0 + 2, x1 + 2, y0 - 2 },
                                  { x0 - 2, y1 + 2, x0 + 2, y1 - 2 }, { x1 - 2, y1 + 2, x1 + 2, y1 - 2 } }) do
            Rect(K, f, "BACKGROUND", 7, corner[1], corner[2], corner[3], corner[4], SEA)
        end
        local label = K.Font(f, 9, "ARTWORK", true)
        if z.labelBottom then
            label:SetPoint("BOTTOMLEFT", f, "TOPLEFT", x0 + 7, y1 + 5)
        else
            label:SetPoint("TOPLEFT", f, "TOPLEFT", x0 + 7, y0 - 5)
        end
        label:SetText(z.name)
        if z.dark then label:SetTextColor(0.90, 0.88, 1) else label:SetTextColor(c[1] * 0.42, c[2] * 0.42, c[3] * 0.42) end
        for _, pr in ipairs(PROPS[z.id] or {}) do
            Prop(K, f, "BORDER", 0, pr[1], PX(pr[2]), PY(pr[3]), 14, z.dark and 0.9 or 1)
        end
    end
    -- a compass rose in the open sea, bottom left: four points, north in red, the letters round it
    do
        local cx, cy = MAP_X + 34, MAP_Y - MAP_H + 44
        local cream, red = { 0.99, 0.96, 0.86 }, { 0.80, 0.26, 0.22 }
        Rect(K, f, "BORDER", 3, cx - 13, cy + 1, cx + 13, cy - 1, INK)                               -- the cross
        Rect(K, f, "BORDER", 3, cx - 1, cy + 13, cx + 1, cy - 13, INK)
        Tri(K, f, "BORDER", 4, "up", 10, cx, cy + 16, INK)
        Tri(K, f, "BORDER", 5, "up", 6, cx, cy + 14, red)
        Tri(K, f, "BORDER", 4, "down", 10, cx, cy - 16, INK)
        Tri(K, f, "BORDER", 5, "down", 6, cx, cy - 14, cream)
        Tri(K, f, "BORDER", 4, "left", 10, cx - 16, cy, INK)
        Tri(K, f, "BORDER", 5, "left", 6, cx - 14, cy, cream)
        Tri(K, f, "BORDER", 4, "right", 10, cx + 16, cy, INK)
        Tri(K, f, "BORDER", 5, "right", 6, cx + 14, cy, cream)
        Rect(K, f, "BORDER", 6, cx - 3, cy + 3, cx + 3, cy - 3, INK)                                 -- the hub
        Rect(K, f, "BORDER", 7, cx - 2, cy + 2, cx + 2, cy - 2, cream)
        for _, l in ipairs({ { "N", 0, 24, red }, { "S", 0, -24, INK }, { "W", -24, 0, INK }, { "E", 24, 0, INK } }) do
            local fs = K.Font(f, 9, "ARTWORK", true)
            fs:SetPoint("CENTER", f, "TOPLEFT", cx + l[2], cy + l[3])
            fs:SetTextColor(l[4][1], l[4][2], l[4][3])
            fs:SetText(l[1])
        end
    end
    f.roads = {}
    for _, r in ipairs(W.Roads()) do f.roads[#f.roads + 1] = { a = r[1], b = r[2], pieces = RoadPieces(K, f, r[1], r[2]) } end
    f.flights = {}
    for _, fl in ipairs(W.FLIGHTS) do
        local a, b = W.byId[fl.from], W.byId[fl.to]
        local pts = { { PX(a.x), PY(a.y) } }
        for _, v in ipairs(fl.via or {}) do pts[#pts + 1] = { PX(v[1]), PY(v[2]) } end
        pts[#pts + 1] = { PX(b.x), PY(b.y) }
        f.flights[#f.flights + 1] = { def = fl, dots = DottedLine(K, f, pts) }
    end
    f.nodes = {}
    for _, p in ipairs(W.PLACES) do
        local node, s = {}, NODE[p.kind]
        local cx, cy = PX(p.x), PY(p.y)
        node.you = Ring(K, f, "ARTWORK", 1, cx - s / 2 - 4, cy + s / 2 + 4, cx + s / 2 + 4, cy - s / 2 - 4, 2, { 0.20, 0.48, 0.96 })
        node.art = NodeArt(K, f, p, cx, cy)
        node.ghost = Rect(K, f, "ARTWORK", 2, cx - 4, cy + 4, cx + 4, cy - 4, INK)        -- an unknown place
        node.ghostFill = Rect(K, f, "ARTWORK", 3, cx - 3, cy + 3, cx + 3, cy - 3, UNKNOWN)
        node.dots = {}
        for i = 1, 3 do                                             -- guildmates there now
            node.dots[i] = Rect(K, f, "OVERLAY", 1, cx + s / 2 + 3, cy + s / 2 - (i - 1) * 7, cx + s / 2 + 8,
                cy + s / 2 - (i - 1) * 7 - 5, { 1, 1, 1 })
        end
        node.cx, node.cy, node.size = cx, cy, s
        f.nodes[p.id] = node
    end
    f.cursor = K.Triangle(f, "down", 12, 0.20, 0.36, 0.62)
    f.cursor:SetFrameLevel(f:GetFrameLevel() + 4)
    -- the info box
    Rect(K, f, "ARTWORK", 0, 22, -296, 486, -297, { 0.80, 0.82, 0.86 })
    f.name = K.Font(f, 16, nil, true)
    f.name:SetPoint("TOPLEFT", 22, -302)
    f.zone = K.Font(f, 11, nil, true)
    f.zone:SetPoint("TOPRIGHT", -22, -305)
    f.zone:SetJustifyH("RIGHT")
    f.zone:SetTextColor(0.36, 0.42, 0.55)
    f.lines = {}
    for i, y in ipairs({ -324, -341, -358 }) do
        local fs = K.Font(f, 12)
        fs:SetPoint("TOPLEFT", 22, y)
        fs:SetWidth(MAP_W)
        fs:SetWordWrap(false)
        fs:SetTextColor(i == 1 and 0.16 or 0.30, i == 1 and 0.18 or 0.36, i == 1 and 0.24 or 0.50)
        f.lines[i] = fs
    end
    local hint = K.Font(f, 12)
    hint:SetPoint("BOTTOMRIGHT", -18, 12)
    hint:SetJustifyH("RIGHT")
    hint:SetTextColor(0.36, 0.42, 0.55)
    hint:SetText("Arrows: look around     Space / X: close")
    f.clock = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        f.clock = f.clock + (elapsed or 0)
        local node = W.sel and f.nodes[W.sel]
        if node then
            f.cursor:ClearAllPoints()
            f.cursor:SetPoint("BOTTOM", f, "TOPLEFT", node.cx, node.cy + node.size / 2 + 5 + math.floor(math.abs(math.sin(f.clock * 4)) * 3))
        end
        local here = W.PlaceOf(G.save and G.save.map)
        if here then
            local a = 0.45 + 0.55 * math.abs(math.sin(f.clock * 2.5))
            for _, r in ipairs(f.nodes[here.id].you) do r:SetAlpha(a) end
        end
    end)
    W.frame = f
    return f
end

function W:Refresh()
    local f = W.frame
    if not f then return end
    local herePlace = W.PlaceOf(G.save.map)
    for _, p in ipairs(W.PLACES) do
        local node, known = f.nodes[p.id], W.Visited(p)
        for _, a in ipairs(node.art) do a:SetShown(known) end
        node.ghost:SetShown(not known)
        node.ghostFill:SetShown(not known)
        for _, r in ipairs(node.you) do r:SetShown(herePlace == p) end
        local here = W.Info(p).here
        for i, dot in ipairs(node.dots) do
            local peer = here[i]
            local cc = peer and peer.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[peer.class]
            if cc then dot:SetColorTexture(cc.r, cc.g, cc.b, 1) else dot:SetColorTexture(1, 1, 1, 1) end
            dot:SetShown(peer ~= nil)
        end
    end
    for _, r in ipairs(f.roads) do
        local c = (W.Visited(r.a) and W.Visited(r.b)) and ROAD or ROAD_DIM
        for _, piece in ipairs(r.pieces) do piece:SetColorTexture(c[1], c[2], c[3], 1) end
    end
    for _, fl in ipairs(f.flights) do
        local shown = W.FlightShown(fl.def)
        for _, d in ipairs(fl.dots) do d:SetShown(shown) end
    end
    local place = W.byId[W.sel] or W.PLACES[1]
    local l = W.Lines(place)
    f.name:SetText(l.name)
    f.zone:SetText(l.zone)
    f.lines[1]:SetText(l.text)
    f.lines[2]:SetText(l.line3)
    f.lines[3]:SetText(l.line4)
end

function W:Key(key)
    if STEP[key] then
        W.sel = W.Neighbour(W.sel, key)
        W:Refresh()
        return true
    end
    return false
end

function W:Open()
    ns.AzeroSound:Play("map")
    local K = ns.AzeroUI.Kit
    local f = W.frame or W:Build(K)
    local here = W.PlaceOf(G.save.map)
    W.sel = here and here.id or "goldshire"
    W:Refresh()
    local stack = K.stack
    local top = stack[#stack]
    f:SetFrameLevel(math.max(100, top and top.frame and top.frame:GetFrameLevel() + 10 or 0))
    f:Show()
    stack[#stack + 1] = { frame = f, items = {}, cursor = 1, cols = 1, isPanel = true,
        onKey = function(key) return W:Key(key) end,
        opts = { onCancel = function(m) K.PopMenu(m) f:Hide() end } }
end

-- Tests: what the panel shows.
function W._State()
    local f = W.frame
    if not f or not f:IsShown() then return nil end
    return { sel = W.sel, name = f.name:GetText(), zone = f.zone:GetText(), text = f.lines[1]:GetText() or "",
             line3 = f.lines[2]:GetText() or "", line4 = f.lines[3]:GetText() or "" }
end
