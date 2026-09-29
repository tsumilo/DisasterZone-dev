-- CDLoot Games/Azeromon/WorldMap.lua
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
      maps = { "town", "home", "lab", "post" }, text = "Home: Huntmaster Aldric's lodge and the Lion's Pride Inn." },
    { id = "arena", name = "Gurubashi Arena", zone = "stv", kind = "arena", x = 5, y = 3.6, maps = { "arena" },
      text = "Short John Mithril's beast fights, deep in Stranglethorn Vale." },
}

-- The coloured regions behind the places (grid units, like the places).
W.ZONES = {
    { id = "westfall", name = "WESTFALL", color = { 0.93, 0.84, 0.58 }, x0 = -0.45, y0 = 0.42, x1 = 2.45, y1 = 2.5 },
    { id = "elwynn", name = "ELWYNN FOREST", color = { 0.64, 0.83, 0.55 }, x0 = 0.55, y0 = 2.5, x1 = 2.45, y1 = 4.45 },
    { id = "duskwood", name = "DUSKWOOD", color = { 0.50, 0.48, 0.64 }, x0 = 2.55, y0 = 0.42, x1 = 5.45, y1 = 1.6,
      dark = true },
    { id = "stv", name = "STRANGLETHORN", color = { 0.52, 0.74, 0.50 }, x0 = 3.95, y0 = 2.85, x1 = 5.45, y1 = 4.3,
      labelBottom = true },
}

-- Gryphon routes (dotted), shown once both ends are known and `flag` is set. `via`: bends on the way.
W.FLIGHTS = {
    { from = "sentinel", to = "arena", via = { { 3.0, 2.5 } } },
    { from = "sentinel", to = "darkshire", flag = "fp_darkshire", via = { { 2, 0.62 }, { 5, 0.62 } } },
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
local GX0, GY0, GW, GH = -0.5, 0.4, 6, 4.2                 -- the grid window it shows
local NODE = { town = 18, route = 12, dungeon = 14, arena = 16 }
local FILL = { town = { 0.86, 0.30, 0.26 }, route = { 0.99, 0.96, 0.86 }, dungeon = { 0.30, 0.27, 0.30 },
               arena = { 0.95, 0.62, 0.22 } }
local UNKNOWN = { 0.68, 0.68, 0.72 }
local ROAD, ROAD_DIM = { 0.82, 0.70, 0.46 }, { 0.62, 0.62, 0.66 }

local function PX(x) return MAP_X + (x - GX0) / GW * MAP_W end
local function PY(y) return MAP_Y - (y - GY0) / GH * MAP_H end

local function Rect(K, f, layer, sub, x0, y0, x1, y1, c, a)
    local t = K.Tex(f, layer, sub)
    t:SetPoint("TOPLEFT", f, "TOPLEFT", math.min(x0, x1), math.max(y0, y1))
    t:SetSize(math.max(1, math.abs(x1 - x0)), math.max(1, math.abs(y1 - y0)))
    t:SetColorTexture(c[1], c[2], c[3], a or 1)
    return t
end

-- A road between two places: straight, or an L (along x first) when they aren't in line.
local function RoadPieces(K, f, a, b)
    local pieces, w = {}, 3
    local ax, ay, bx, by = PX(a.x), PY(a.y), PX(b.x), PY(b.y)
    if ay ~= by then pieces[#pieces + 1] = Rect(K, f, "BORDER", 2, bx - w, ay, bx + w, by, ROAD) end
    if ax ~= bx then pieces[#pieces + 1] = Rect(K, f, "BORDER", 2, ax, ay - w, bx, ay + w, ROAD) end
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
            dots[#dots + 1] = Rect(K, f, "BORDER", 3, x - 1.5, y + 1.5, x + 1.5, y - 1.5, { 0.24, 0.36, 0.62 })
        end
    end
    return dots
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
    Rect(K, f, "BACKGROUND", 1, MAP_X, MAP_Y, MAP_X + MAP_W, MAP_Y - MAP_H, { 0.74, 0.84, 0.91 })     -- the sea
    for _, z in ipairs(W.ZONES) do
        local x0, y0, x1, y1 = PX(z.x0), PY(z.y0), PX(z.x1), PY(z.y1)
        local c = z.color
        Rect(K, f, "BACKGROUND", 2, x0, y0, x1, y1, { c[1] * 0.78, c[2] * 0.78, c[3] * 0.78 })
        Rect(K, f, "BACKGROUND", 3, x0 + 2, y0 - 2, x1 - 2, y1 + 2, c)
        local label = K.Font(f, 10, "ARTWORK", true)
        if z.labelBottom then
            label:SetPoint("BOTTOMLEFT", f, "TOPLEFT", x0 + 6, y1 + 4)
        else
            label:SetPoint("TOPLEFT", f, "TOPLEFT", x0 + 6, y0 - 4)
        end
        label:SetText(z.name)
        if z.dark then label:SetTextColor(0.90, 0.88, 1) else label:SetTextColor(c[1] * 0.45, c[2] * 0.45, c[3] * 0.45) end
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
        local n, s = {}, NODE[p.kind]
        local cx, cy = PX(p.x), PY(p.y)
        n.you = Rect(K, f, "ARTWORK", 1, cx - s / 2 - 4, cy + s / 2 + 4, cx + s / 2 + 4, cy - s / 2 - 4, { 0.20, 0.48, 0.96 })
        n.edge = Rect(K, f, "ARTWORK", 2, cx - s / 2, cy + s / 2, cx + s / 2, cy - s / 2, { 0.16, 0.16, 0.20 })
        n.fill = Rect(K, f, "ARTWORK", 3, cx - s / 2 + 2, cy + s / 2 - 2, cx + s / 2 - 2, cy - s / 2 + 2, FILL[p.kind])
        n.q = K.Font(f, 10, "OVERLAY", true)
        n.q:SetPoint("CENTER", f, "TOPLEFT", cx + 0.5, cy)
        n.q:SetText("?")
        n.dots = {}
        for i = 1, 3 do                                             -- guildmates there now
            n.dots[i] = Rect(K, f, "OVERLAY", 1, cx + s / 2 + 3, cy + s / 2 - (i - 1) * 7, cx + s / 2 + 8, cy + s / 2 - (i - 1) * 7 - 5,
                { 1, 1, 1 })
        end
        n.cx, n.cy, n.size = cx, cy, s
        f.nodes[p.id] = n
    end
    f.cursor = K.Triangle(f, "down", 12, 0.20, 0.36, 0.62)
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
        local n = W.sel and f.nodes[W.sel]
        if n then
            f.cursor:ClearAllPoints()
            f.cursor:SetPoint("BOTTOM", f, "TOPLEFT", n.cx, n.cy + n.size / 2 + 4 + math.floor(math.abs(math.sin(f.clock * 4)) * 3))
        end
        local here = W.PlaceOf(G.save and G.save.map)
        if here then f.nodes[here.id].you:SetAlpha(0.45 + 0.55 * math.abs(math.sin(f.clock * 2.5))) end
    end)
    W.frame = f
    return f
end

function W:Refresh()
    local f = W.frame
    if not f then return end
    for _, p in ipairs(W.PLACES) do
        local n, known = f.nodes[p.id], W.Visited(p)
        local c = known and FILL[p.kind] or UNKNOWN
        n.fill:SetColorTexture(c[1], c[2], c[3], 1)
        n.q:SetShown(not known)
        n.you:SetShown(W.PlaceOf(G.save.map) == p)
        local here = W.Info(p).here
        for i, dot in ipairs(n.dots) do
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
