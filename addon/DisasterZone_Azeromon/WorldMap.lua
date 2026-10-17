if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/WorldMap.lua", ...) then return end -- DisasterZone_Azeromon/WorldMap.lua
-- ns.AzeroWorld: the world map (START > MAP). A painted map of every place, laid out the way the maps connect
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
      maps = { "town", "home", "lab", "post", "cottage", "hideout" },
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
    -- Blackrock (MapsBlackrock.lua): Darkshire's north road up through Redridge, then the mountain
    { id = "threecorners", name = "Three Corners", zone = "redridge", kind = "route", x = 5, y = 0, maps = { "threecorners" },
      text = "A valley climbing from Darkshire to the Redridge road. Poachers camp in the hollow." },
    { id = "lakeshire", name = "Lakeshire", zone = "redridge", kind = "town", x = 6.1, y = 0,
      maps = { "lakeshire", "lakeshireinn" }, text = "Magistrate Solomon's town on the lake: the inn, gryphons and the bridge east." },
    { id = "everstill", name = "Lake Everstill", zone = "redridge", kind = "route", x = 7.2, y = 0, maps = { "everstill" },
      text = "The lake, Alther's Mill and Yowler's gnoll camp." },
    { id = "stonewatch", name = "Stonewatch Keep", zone = "redridge", kind = "route", x = 8, y = -0.72,
      maps = { "stonewatch" }, text = "Gath'Ilzogg's keep on its hill. Render's Valley climbs north from here." },
    { id = "steppes", name = "Burning Steppes", zone = "steppes", kind = "route", x = 8.3, y = -1.5, maps = { "steppes" },
      text = "An ash plain, lava lakes and Flame Crest. Morgan's Vigil holds the south-east hill." },
    { id = "brm", name = "Blackrock Mountain", zone = "blackrock", kind = "dungeon", x = 7.1, y = -1.5, maps = { "brm" },
      text = "One great cavern round a lava sea, chain bridges across it, and the Black Forge." },
    { id = "brd", name = "The Imperial Seat", zone = "blackrock", kind = "dungeon", x = 5.9, y = -1.2, maps = { "brd" },
      text = "Emperor Dagran Thaurissan's throne, deep in Blackrock Depths." },
    { id = "moltencore", name = "Molten Core", zone = "blackrock", kind = "dungeon", x = 5.9, y = -1.85, maps = { "moltencore" },
      text = "Ragnaros' lava cavern under the mountain. Something huge prowls its shelf." },
    { id = "gorge", name = "Searing Gorge", zone = "gorge", kind = "route", x = 7.1, y = -2.3, maps = { "gorge" },
      text = "A canyon round the Cauldron's lava. The Thorium Brotherhood holds Thorium Point." },
}

-- The coloured regions behind the places (grid units, like the places).
W.ZONES = {
    { id = "westfall", name = "WESTFALL", color = { 0.93, 0.84, 0.58 }, x0 = -0.45, y0 = 0.42, x1 = 2.45, y1 = 2.5 },
    { id = "elwynn", name = "ELWYNN FOREST", color = { 0.64, 0.83, 0.55 }, x0 = 0.55, y0 = 2.5, x1 = 2.45, y1 = 4.45 },
    { id = "duskwood", name = "DUSKWOOD", color = { 0.50, 0.48, 0.64 }, x0 = 2.55, y0 = 0.42, x1 = 5.45, y1 = 1.6,
      dark = true },
    { id = "stv", name = "STRANGLETHORN", color = { 0.52, 0.74, 0.50 }, x0 = 3.95, y0 = 1.65, x1 = 6.45, y1 = 6.75,
      labelBottom = true },
    { id = "redridge", name = "REDRIDGE MOUNTAINS", color = { 0.88, 0.66, 0.44 }, x0 = 4.5, y0 = -1.05, x1 = 8.85, y1 = 0.42 },
    { id = "blackrock", name = "BLACKROCK MOUNTAIN", color = { 0.42, 0.34, 0.34 }, x0 = 4.5, y0 = -2.6, x1 = 7.65, y1 = -1.0,
      dark = true },
    { id = "steppes", name = "BURNING STEPPES", color = { 0.58, 0.44, 0.38 }, x0 = 7.65, y0 = -2.05, x1 = 8.9, y1 = -1.0,
      dark = true },
    { id = "gorge", name = "SEARING GORGE", color = { 0.90, 0.58, 0.38 }, x0 = 6.2, y0 = -2.6, x1 = 8.0, y1 = -2.05 },
}

-- Gryphon routes (dotted), shown once both ends are known and `flag` is set. `via`: bends on the way.
W.FLIGHTS = {
    { from = "sentinel", to = "arena", via = { { 3.0, 2.5 } } },
    { from = "sentinel", to = "darkshire", flag = "fp_darkshire", via = { { 2, 0.62 }, { 5, 0.62 } } },
    { from = "bootybay", to = "darkshire", flag = "fp_bootybay", via = { { 6.6, 6.2 }, { 6.6, 1 } } },
    { from = "lakeshire", to = "darkshire", flag = "fp_lakeshire", via = { { 5.6, 0.6 } } },
    { from = "steppes", to = "lakeshire", flag = "fp_morgansvigil", via = { { 8.7, -0.7 } } },
    { from = "gorge", to = "steppes", flag = "fp_thoriumpoint", via = { { 8.3, -2.3 } } },
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
    if g:Flag("fp_lakeshire") then v.lakeshire = true end
    if g:Flag("fp_morgansvigil") then v.steppes = true end
    if g:Flag("fp_thoriumpoint") then v.gorge = true end
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
-- The panel (START > MAP): the painted map (WorldArt.lua, baked by dev/generators/gen_azeromon_worldmap.py) at 2
-- units a pixel over the whole screen, the world moving on it (waves, glints, clouds, smoke, Duskwood's mist,
-- birds, gryphons on the routes you know, day and night), mist over places you haven't found (a "?" where a road
-- leads in; the peaks north of Westfall and Duskwood stay misty), and the info card on the right. A place found since the map was last
-- opened is revealed: its mist lifts with sparkles and a banner names it (save.mapSeen: the places already shown).
---------------------------------------------------------------------------

local ART = ns.AzeroWorldArt
local FILES = "Interface\\AddOns\\DisasterZone_Azeromon\\Media\\WorldMap\\"
local GROUND = "Interface\\AddOns\\DisasterZone_Azeromon\\Media\\Ground\\"
local CHARS = "Interface\\AddOns\\DisasterZone_Azeromon\\Media\\chars"
local GLOW = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local PX = 2                                                 -- units per map pixel
local INK = { 0.165, 0.18, 0.21 }
local CREAM = { 0.96, 0.95, 0.89 }
local SLATE = { 0.24, 0.35, 0.53 }
local DARK = { dawn = { 0.97, 0.87, 0.81 }, dusk = { 0.93, 0.74, 0.61 }, night = { 0.39, 0.44, 0.67 } }
local LIGHT = { warm = { 1, 0.75, 0.43 }, lamp = { 1, 0.82, 0.47 }, ember = { 1, 0.47, 0.2 } }
-- zone names on ribbons (panel units). The peaks north of Westfall and Duskwood are not a place: always misty.
W.LABELS = { westfall = { 51, 210 }, elwynn = { 60, 318 }, duskwood = { 172, 196 }, stv = { 198, 270 },
             redridge = { 300, 160 }, steppes = { 320, 50 }, blackrock = { 128, 78 }, gorge = { 160, 42 } }
local CLOUDS = { { 30, 40, 3.2 }, { 150, 120, 2.6 }, { 250, 70, 3.8 } }       -- start x, y (pixels), drift / s
local KIND = { town = "TOWN", route = "WILDS", dungeon = "DUNGEON", arena = "ARENA" }
local TAG_ICON = { Inn = "bed", Rest = "fire1", Shop = "barrel", Stable = "hay", ["Bounty board"] = "wantedboard",
                   ["Profession trainers"] = "node_peacebloom", ["Pet trainer"] = "crate", ["Forge and anvil"] = "anvil",
                   ["Alchemy table"] = "alchemy", Gryphons = "bannerblue_0_0", ["Beast fights"] = "arenawall" }
local TAG_SHORT = { ["Profession trainers"] = "Professions", ["Forge and anvil"] = "Forge", ["Alchemy table"] = "Alchemy",
                    ["Bounty board"] = "Bounties" }
local CARD_X, CARD_Y, CARD_W, CARD_H = 466, 40, 198, 382    -- (below the key hints along the top)
local PIPS = 28                                              -- beast pips on the card (two rows of 14)

local function Color(t, c, a) t:SetColorTexture(c[1], c[2], c[3], a or 1) return t end

-- a texture at map pixels x, y, w, h (panel units = pixels x 2)
local function Place(t, f, x, y, w, h)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", f, "TOPLEFT", x * PX, -y * PX)
    t:SetSize(w * PX, h * PX)
end

-- a rect in panel units
local function Rect(K, f, layer, sub, x, y, w, h, c, a)
    local t = Color(K.Tex(f, layer, sub), c, a)
    t:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    t:SetSize(w, h)
    return t
end

local function Sheet(t, file, sx, sy, w, h, tw, th)
    t:SetTexCoord(sx / tw, (sx + w) / tw, sy / th, (sy + h) / th)
end

function W.Fogged(p)
    return not W.Visited(p) or (W.reveal and W.reveal.ids[p.id]) and true or false
end

function W.Rumoured(p)
    if W.Visited(p) then return false end
    for _, r in ipairs(W.Roads()) do
        local o = (r[1] == p and r[2]) or (r[2] == p and r[1])
        if o and W.Visited(o) then return true end
    end
    return false
end

-- A ribbon with the zone's name: ink edge, coloured band, tails.
local function Ribbon(K, f)
    local r = { parts = {} }
    local function part(sub) local t = K.Tex(f, "ARTWORK", sub) r.parts[#r.parts + 1] = t return t end
    r.shadow, r.edge, r.tailL, r.tailR, r.tailLe, r.tailRe = part(0), part(1), part(2), part(2), part(1), part(1)
    r.fill, r.shine = part(3), part(4)
    r.fs = K.Font(f, 7, "OVERLAY", true)
    function r.Set(cx, cy, text, c, light)
        local w, h = math.ceil(K.TextWidth(text, 7)) + 16, 13
        local x, y = math.floor(cx - w / 2), math.floor(cy - h / 2)
        local function put(t, px, py, pw, ph, col, a)
            t:ClearAllPoints() t:SetPoint("TOPLEFT", f, "TOPLEFT", px, -py) t:SetSize(pw, ph) Color(t, col, a) t:Show()
        end
        put(r.shadow, x + 1, y + 2, w, h, { 0.04, 0.05, 0.06 }, 0.55)
        put(r.edge, x - 1, y - 1, w + 2, h + 2, INK)
        put(r.tailLe, x - 7, y + 2, 7, h, INK) put(r.tailRe, x + w, y + 2, 7, h, INK)
        put(r.tailL, x - 6, y + 3, 6, h - 2, { c[1] * 0.78, c[2] * 0.78, c[3] * 0.78 })
        put(r.tailR, x + w, y + 3, 6, h - 2, { c[1] * 0.78, c[2] * 0.78, c[3] * 0.78 })
        put(r.fill, x, y, w, h, c) put(r.shine, x, y, w, 1, { 1, 1, 1 }, 0.35)
        r.fs:ClearAllPoints()
        r.fs:SetPoint("CENTER", f, "TOPLEFT", cx, -cy - 1)
        r.fs:SetText(text)
        if light then r.fs:SetTextColor(0.93, 0.91, 1) else r.fs:SetTextColor(c[1] * 0.36, c[2] * 0.36, c[3] * 0.36) end
        r.fs:Show()
    end
    return r
end

local function BuildMap(K, f)
    local A = ART
    f.base = K.Tex(f, "BACKGROUND", -7)
    f.artOK = K.PixelTexture(f.base, FILES .. "worldmap")
    Sheet(f.base, nil, 0, 0, A.w, A.h, A.tw, A.th)
    Place(f.base, f, 0, 0, A.w, A.h)
    -- the waves on the shore: frames of the whole picture
    f.lap = K.Tex(f, "BACKGROUND", -6)
    K.PixelTexture(f.lap, FILES .. "worldmap_lap")
    Place(f.lap, f, 0, 0, A.w, A.h)
    f.glints = {}
    for i, g in ipairs(A.glints) do
        if i % 4 == 1 then                                   -- a quarter of the sites is plenty at a time
            local t = Color(K.Tex(f, "BACKGROUND", -5), { 1, 1, 1 })
            Place(t, f, g[1], g[2], 1, 1)
            t.phase = i * 1.7
            f.glints[#f.glints + 1] = t
        end
    end
    -- cloud shadows (the overworld's), drifting
    f.cloudShade = K.Tex(f, "BACKGROUND", -4)
    if not pcall(f.cloudShade.SetTexture, f.cloudShade, GROUND .. "clouds", "REPEAT", "REPEAT", "NEAREST") then
        f.cloudShade:SetTexture(GROUND .. "clouds")
    end
    f.cloudShade:SetAllPoints(f)
    f.clouds = {}
    for i = 1, 3 do
        local s, c = K.Tex(f, "BACKGROUND", -3), K.Tex(f, "ARTWORK", 3)
        K.PixelTexture(s, FILES .. "worldmap_sprites") K.PixelTexture(c, FILES .. "worldmap_sprites")
        local sp, ss = A.sprites["cloud" .. i], A.sprites["cshadow" .. i]
        Sheet(c, nil, sp[1], sp[2], sp[3], sp[4], 128, 64) Sheet(s, nil, ss[1], ss[2], ss[3], ss[4], 128, 64)
        f.clouds[i] = { cloud = c, shadow = s, w = sp[3], h = sp[4] }
    end
    -- Duskwood's mist, through its shape
    f.mist = K.Tex(f, "BORDER", 0)
    if not pcall(f.mist.SetTexture, f.mist, GROUND .. "mist", "REPEAT", "REPEAT", "NEAREST") then f.mist:SetTexture(GROUND .. "mist") end
    f.mist:SetAllPoints(f)
    local ok, mask = pcall(f.CreateMaskTexture, f)
    if ok and mask and pcall(mask.SetTexture, mask, FILES .. "worldmap_dusk", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") then
        mask:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        mask:SetSize(A.tw * PX, A.th * PX)
        f.mistOK = pcall(f.mist.AddMaskTexture, f.mist, mask)
    end
    f.mist:SetShown(f.mistOK and true or false)
    -- smoke and birds: small squares
    f.smoke = {}
    for i = 1, 40 do f.smoke[i] = { tex = Color(K.Tex(f, "BORDER", 2), { 0.9, 0.9, 0.92 }), on = false } f.smoke[i].tex:Hide() end
    f.birds = {}
    for i = 1, 9 do f.birds[i] = Color(K.Tex(f, "BORDER", 3), { 0.16, 0.16, 0.19 }, 0.9) end
    -- the mist over places, two noise variants crossfaded
    f.fog = {}
    for id, r in pairs(A.fog) do
        local a, b = K.Tex(f, "ARTWORK", 0), K.Tex(f, "ARTWORK", 1)
        K.PixelTexture(a, FILES .. "worldmap_fog1") K.PixelTexture(b, FILES .. "worldmap_fog2")
        for _, t in ipairs({ a, b }) do
            Sheet(t, nil, r[5], r[6], r[3], r[4], 512, A.fogH)
            Place(t, f, r[1], r[2], r[3], r[4])
        end
        f.fog[id] = { a = a, b = b, box = r, phase = #id }
    end
    f.sparks = {}
    for i = 1, 30 do f.sparks[i] = Color(K.Tex(f, "ARTWORK", 2), { 1, 0.91, 0.59 }) f.sparks[i]:Hide() end
    -- gryphons
    f.gryphons = {}
    for i, fl in ipairs(A.flights) do
        local g, s = K.Tex(f, "ARTWORK", 4), K.Tex(f, "ARTWORK", 4)
        K.PixelTexture(g, FILES .. "worldmap_sprites") K.PixelTexture(s, FILES .. "worldmap_sprites")
        local ss = A.sprites.gryS
        Sheet(s, nil, ss[1], ss[2], ss[3], ss[4], 128, 64)
        s:SetSize(ss[3] * PX, ss[4] * PX)
        g:SetSize(7 * PX, 5 * PX)
        local len, segs = 0, {}
        for k = 2, #fl.pts do
            local l = math.sqrt((fl.pts[k][1] - fl.pts[k - 1][1]) ^ 2 + (fl.pts[k][2] - fl.pts[k - 1][2]) ^ 2)
            segs[#segs + 1] = l
            len = len + l
        end
        f.gryphons[i] = { tex = g, shadow = s, def = W.FLIGHTS[i], pts = fl.pts, segs = segs, len = len }
    end
    -- dusk and night: the world multiplied, then lamps and lit windows
    f.dark = K.Tex(f, "ARTWORK", 5)
    f.dark:SetAllPoints(f)
    f.dark:SetColorTexture(1, 1, 1, 1)
    pcall(f.dark.SetBlendMode, f.dark, "MOD")
    f.glows, f.windows = {}, {}
    for i, l in ipairs(A.lights) do
        local t = K.Tex(f, "ARTWORK", 6)
        t:SetTexture(GLOW)
        pcall(t.SetBlendMode, t, "ADD")
        local c = LIGHT[l[3]] or LIGHT.warm
        t:SetVertexColor(c[1], c[2], c[3], 1)
        t:SetPoint("CENTER", f, "TOPLEFT", (l[1] + 0.5) * PX, -(l[2] + 0.5) * PX)
        f.glows[i] = { tex = t, r = l[4] * PX * 2.2, x = l[1], y = l[2], kind = l[3] }
    end
    for i, wd in ipairs(A.windows) do
        local t = Color(K.Tex(f, "ARTWORK", 7), { 1, 0.84, 0.47 })
        Place(t, f, wd[1], wd[2], 1, 1)
        f.windows[i] = { tex = t, x = wd[1], y = wd[2] }
    end
end

-- which place's mist covers map pixel x, y (for lights and smoke: hidden under mist)
local function UnderMist(x, y)
    for id, r in pairs(ART.fog) do
        if x >= r[1] + 3 and y >= r[2] + 3 and x < r[1] + r[3] - 3 and y < r[2] + r[4] - 3 then
            local p = W.byId[id]
            local nearest, best = nil, 1e9
            for pid, xy in pairs(ART.places) do
                local d = (xy[1] - x) ^ 2 + (xy[2] - y) ^ 2
                if d < best then nearest, best = pid, d end
            end
            if nearest == id and (not p or W.Fogged(p)) then return true end
        end
    end
    return false
end

local function BuildMarks(K, f)
    local m = CreateFrame("Frame", nil, f)
    m:SetAllPoints(f)
    m:SetFrameLevel(f:GetFrameLevel() + 2)
    f.marks = m
    f.ribbons = {}
    for _, z in ipairs(W.ZONES) do f.ribbons[z.id] = Ribbon(K, m) end
    local title = K.Font(m, 12, "OVERLAY", true)
    title:SetPoint("BOTTOMLEFT", m, "BOTTOMLEFT", 52, 14)
    title:SetTextColor(CREAM[1], CREAM[2], CREAM[3])
    title:SetShadowColor(0.03, 0.08, 0.16, 0.6)
    title:SetShadowOffset(1, -1)
    title:SetText("WORLD MAP")
    -- per place: a "?" pin (rumours) and guildmate pins
    f.pins, f.mates = {}, {}
    for _, p in ipairs(W.PLACES) do
        local xy = ART.places[p.id]
        local cx, cy = xy[1] * PX, xy[2] * PX
        local pin = { Rect(K, m, "ARTWORK", 0, cx - 6, cy - 7, 12, 13, INK), Rect(K, m, "ARTWORK", 1, cx - 5, cy - 6, 10, 11, CREAM) }
        pin.fs = K.Font(m, 8, "OVERLAY", true)
        pin.fs:SetPoint("CENTER", m, "TOPLEFT", cx, -cy - 1)
        pin.fs:SetTextColor(SLATE[1], SLATE[2], SLATE[3])
        pin.fs:SetText("?")
        pin.cy = cy
        f.pins[p.id] = pin
        local mates = {}
        for i = 1, 3 do
            mates[i] = { Rect(K, m, "ARTWORK", 2, cx + 12, cy - 15 + (i - 1) * 8, 8, 8, INK),
                         Rect(K, m, "ARTWORK", 3, cx + 13, cy - 14 + (i - 1) * 8, 6, 6, { 1, 1, 1 }) }
        end
        f.mates[p.id] = mates
    end
    -- you: a pulsing ring and the hero's head
    f.you = {}
    for i = 1, 4 do f.you[i] = Color(K.Tex(m, "OVERLAY", 0), { 0.31, 0.59, 1 }) end
    f.head = K.Tex(m, "OVERLAY", 2)
    K.PixelTexture(f.head, CHARS)
    f.head:SetTexCoord(64 / 256, 80 / 256, 0, 10 / 128)
    f.head:SetSize(16, 10)
    f.headStick = Color(K.Tex(m, "OVERLAY", 1), INK)
    f.headStick:SetSize(2, 6)
    -- the selection: corner brackets and the pointer
    f.brackets = {}
    for i = 1, 8 do f.brackets[i] = Color(K.Tex(m, "OVERLAY", i <= 4 and 3 or 4), i <= 4 and INK or { 0.98, 0.96, 0.9 }) end
    f.brackets2 = {}
    for i = 1, 8 do f.brackets2[i] = Color(K.Tex(m, "OVERLAY", i <= 4 and 3 or 4), i <= 4 and INK or { 0.98, 0.96, 0.9 }) end
    f.cursor = K.Triangle(m, "down", 12, SLATE[1], SLATE[2], SLATE[3])
    f.cursor:SetFrameLevel(m:GetFrameLevel() + 1)
end

-- The card: zone band, name, text, then rows (wild levels, beasts with pips, trainers, badge), what's here as icon
-- chips, guildmates; laid out top to bottom on Refresh.
local function BuildCard(K, f)
    local c = K.Box(f, CARD_W, CARD_H, f:GetFrameLevel() + 4)
    c:SetPoint("TOPLEFT", f, "TOPLEFT", CARD_X, -CARD_Y)
    f.card = c
    c.bandEdge = Rect(K, c, "ARTWORK", 0, 7, 10, CARD_W - 14, 24, INK)
    c.band = Rect(K, c, "ARTWORK", 1, 7, 10, CARD_W - 14, 23, { 1, 1, 1 })
    c.bandShine = Rect(K, c, "ARTWORK", 2, 7, 10, CARD_W - 14, 1, { 1, 1, 1 }, 0.3)
    c.zone = K.Font(c, 7, "OVERLAY", true)
    c.zone:SetPoint("TOPLEFT", 14, -17)
    c.kindBg = Rect(K, c, "ARTWORK", 2, 0, 15, 10, 13, { 0.08, 0.09, 0.13 }, 0.75)
    c.kind = K.Font(c, 7, "OVERLAY", true)
    c.kind:SetTextColor(CREAM[1], CREAM[2], CREAM[3])
    c.name = K.Font(c, 14, "OVERLAY", true)
    c.name:SetPoint("TOPLEFT", 14, -42)
    c.youBg = Rect(K, c, "ARTWORK", 1, 14, 66, 10, 14, { 0.24, 0.47, 0.86 })
    c.you = K.Font(c, 7, "OVERLAY", true)
    c.you:SetPoint("TOPLEFT", c, "TOPLEFT", 20, -68)
    c.you:SetTextColor(1, 1, 1)
    c.you:SetText("YOU ARE HERE")
    c.text = K.Font(c, 9)
    c.text:SetWidth(CARD_W - 28)
    c.text:SetWordWrap(true)
    c.text:SetTextColor(0.30, 0.35, 0.44)
    c.rule = Rect(K, c, "ARTWORK", 1, 14, 0, CARD_W - 28, 1, { 0.84, 0.85, 0.89 })
    c.rows = {}
    for i = 1, 4 do
        local r = { icon = K.Tex(c, "ARTWORK", 2), icon2 = {} }
        r.icon:SetSize(16, 16)
        for k = 1, 4 do r.icon2[k] = K.Tex(c, "ARTWORK", 2) r.icon2[k]:SetSize(8, 8) end
        r.label = K.Font(c, 9)
        r.label:SetTextColor(0.43, 0.46, 0.53)
        r.value = K.Font(c, 9, "OVERLAY", true)
        r.value:SetJustifyH("RIGHT")
        c.rows[i] = r
    end
    c.pips = {}
    for i = 1, PIPS do c.pips[i] = { Color(K.Tex(c, "ARTWORK", 3), INK), Color(K.Tex(c, "ARTWORK", 4), { 1, 1, 1 }) } end
    c.tamed = K.Font(c, 7)
    c.tamed:SetTextColor(0.55, 0.57, 0.63)
    c.hereHead = K.Font(c, 7, "OVERLAY", true)
    c.hereHead:SetTextColor(0.55, 0.57, 0.63)
    c.hereHead:SetText("HERE")
    c.chips = {}
    for i = 1, 12 do
        local ch = { bg = Color(K.Tex(c, "ARTWORK", 1), { 0.92, 0.93, 0.94 }), icon = K.Tex(c, "ARTWORK", 2), fs = K.Font(c, 8) }
        ch.bg:SetSize((CARD_W - 28) / 2 - 4, 18)
        ch.icon:SetSize(16, 16)
        c.chips[i] = ch
    end
    c.matesHead = K.Font(c, 7, "OVERLAY", true)
    c.matesHead:SetTextColor(0.55, 0.57, 0.63)
    c.matesHead:SetText("GUILDMATES HERE")
    c.mates = {}
    for i = 1, 4 do
        c.mates[i] = { edge = Color(K.Tex(c, "ARTWORK", 2), INK), dot = Color(K.Tex(c, "ARTWORK", 3), { 1, 1, 1 }), fs = K.Font(c, 9, "OVERLAY", true) }
        c.mates[i].edge:SetSize(8, 8) c.mates[i].dot:SetSize(6, 6)
    end
    local hint = K.Font(c, 7)
    hint:SetPoint("BOTTOMLEFT", 14, 12)
    hint:SetTextColor(0.47, 0.51, 0.59)
    hint:SetText("Arrows: look around   Space / X: close")
end

local function BuildBanner(K, f)
    local b = K.Box(f, 240, 46, f:GetFrameLevel() + 8)
    b.top = K.Font(b, 7, "OVERLAY", true)
    b.top:SetPoint("TOP", 0, -12)
    b.top:SetTextColor(0.75, 0.55, 0.16)
    b.top:SetText("NEW PLACE DISCOVERED")
    b.name = K.Font(b, 12, "OVERLAY", true)
    b.name:SetPoint("TOP", 0, -24)
    b:Hide()
    f.banner = b
end

function W:Build(K)
    local f = CreateFrame("Frame", nil, K.Screen())
    f:SetSize(K.SW, K.SH)
    f:SetPoint("CENTER")                  -- like the world: scaled a little past the screen to fill the stage (W:Fit)
    f:SetFrameLevel(100)
    f.noPool = true
    f:EnableMouse(true)
    f:SetScript("OnMouseDown", function(_, button)
        if button == "RightButton" and ns.AzeroUI.Press then ns.AzeroUI.Press("B") end
    end)
    Rect(K, f, "BACKGROUND", -8, 0, 0, K.SW, K.SH, { 0.26, 0.47, 0.77 })       -- (the sea, if the picture is missing)
    BuildMap(K, f)
    BuildMarks(K, f)
    BuildCard(K, f)
    BuildBanner(K, f)
    f.clock, f.smokeHidden, f.h = 0, {}, K.SH
    f:SetScript("OnUpdate", function(_, elapsed) W:Animate(elapsed or 0) end)
    W.frame = f
    local UI = ns.AzeroUI
    if UI._Fit then UI._Fit() end
    return f
end

-- The stage's visible size in map units and the bleed scale (UI FitScreen): the picture meets all four edges like
-- the world does, and the card moves in by what the bleed cuts off so it stays whole.
function W:Fit(visW, visH, k)
    local f = W.frame
    f:SetScale(k)
    local w, h = f:GetWidth(), f:GetHeight()
    local cutX, cutY = math.max(0, (w - visW) / 2), math.max(0, (h - visH) / 2)
    local y = math.min(CARD_Y + cutY, h - cutY - CARD_H - 4)             -- (a short stage: the bottom wins)
    f.card:ClearAllPoints()
    f.card:SetPoint("TOPLEFT", f, "TOPLEFT", CARD_X - cutX, -y)
end

---------------------------------------------------------------------------
-- Every frame: the moving parts
---------------------------------------------------------------------------

local function Bracket(list, x, y, s, l)
    local i = 0
    for _, sx in ipairs({ -1, 1 }) do
        for _, sy in ipairs({ -1, 1 }) do
            local cx, cy = x + sx * s, y + sy * s
            local hx = sx > 0 and cx - l or cx
            local vy = sy > 0 and cy - l or cy
            i = i + 1
            local e1, e2, c1, c2 = list[i], list[i + 4], nil, nil
            -- (ink outline + cream bar per arm; two arms per corner come from the two lists)
            e1:ClearAllPoints() e1:SetPoint("TOPLEFT", W.frame.marks, "TOPLEFT", hx - 1, -(cy - 2)) e1:SetSize(l + 2, 4)
            e2:ClearAllPoints() e2:SetPoint("TOPLEFT", W.frame.marks, "TOPLEFT", hx, -(cy - 1)) e2:SetSize(l, 2)
            c1, c2 = W.frame.brackets2[i], W.frame.brackets2[i + 4]
            c1:ClearAllPoints() c1:SetPoint("TOPLEFT", W.frame.marks, "TOPLEFT", cx - 2, -(vy - 1)) c1:SetSize(4, l + 2)
            c2:ClearAllPoints() c2:SetPoint("TOPLEFT", W.frame.marks, "TOPLEFT", cx - 1, -vy) c2:SetSize(2, l)
        end
    end
end

function W:Animate(elapsed)
    local f = W.frame
    if not f or not f:IsShown() then return end
    f.clock = f.clock + elapsed
    local t, A = f.clock, ART
    -- waves on the shore
    local fr = math.floor(t * 6) % A.lap.frames
    Sheet(f.lap, nil, (fr % A.lap.cols) * A.w, math.floor(fr / A.lap.cols) * A.h, A.w, A.h, A.lap.tw, A.lap.th)
    for _, g in ipairs(f.glints) do
        local s = math.sin(t * 2.3 + g.phase)
        g:SetAlpha(s > 0.9 and (s - 0.9) * 10 or 0)
    end
    -- clouds: by day and dusk
    local period = f.period or "day"
    local cloudy = period ~= "night"
    f.cloudShade:SetShown(cloudy)
    if cloudy then
        f.cloudShade:SetAlpha(period == "day" and 0.16 or 0.08)
        local ox, oy = -(t * 3) / 256, -(t * 1.2) / 256
        f.cloudShade:SetTexCoord(ox, ox + A.w / 256, oy, oy + A.h / 256)
    end
    for i, c in ipairs(f.clouds) do
        local d = CLOUDS[i]
        local x = ((d[1] + t * d[3]) % (A.w + 80)) - 40
        c.cloud:SetShown(cloudy) c.shadow:SetShown(cloudy)
        Place(c.cloud, f, math.floor(x), d[2], c.w, c.h)
        Place(c.shadow, f, math.floor(x) + 10, d[2] + 14, c.w, c.h)
        c.cloud:SetAlpha(period == "day" and 0.95 or 0.8)
    end
    if f.mistOK then
        local mx = -(t * 4) / 256
        f.mist:SetTexCoord(mx, mx + A.w / 256, 0, A.h / 256)
        f.mist:SetAlpha(period == "day" and 0.55 or 0.8)
    end
    -- smoke: a puff now and then from each chimney (not under mist)
    f.puffAt = f.puffAt or 0
    if t >= f.puffAt then
        f.puffAt = t + 0.25
        for _, s in ipairs(A.smoke) do
            if not f.smokeHidden[s[1] .. "," .. s[2]] and math.random() < 0.35 then
                for _, p in ipairs(f.smoke) do
                    if not p.on then
                        p.on, p.x, p.y, p.t0 = true, s[1] + math.random(), s[2], t
                        p.dark = W.byId.moonbrook and math.abs(s[1] - A.places.moonbrook[1]) < 9 and math.abs(s[2] - A.places.moonbrook[2]) < 9
                        break
                    end
                end
            end
        end
    end
    for _, p in ipairs(f.smoke) do
        if p.on then
            local age = t - p.t0
            if age > 3.2 then
                p.on = false
                p.tex:Hide()
            else
                local sz = age > 1.6 and 2 or 1
                if p.dark then p.tex:SetColorTexture(0.27, 0.24, 0.24, 1) else p.tex:SetColorTexture(0.89, 0.89, 0.9, 1) end
                p.tex:SetAlpha((1 - age / 3.2) * 0.75)
                Place(p.tex, f, math.floor(p.x + age * 2.2 + math.sin(age * 3 + p.t0) * 0.6), math.floor(p.y - age * 5.5), sz, sz)
                p.tex:Show()
            end
        end
    end
    -- birds over Elwynn, every 26 seconds
    do
        local ph = (t % 26) / 26
        local bx, by = -10 + ph * A.w * 0.5, 110 - ph * 60
        for k, o in ipairs({ { 0, 0 }, { 5, 3 }, { -4, 4 } }) do
            local up = math.sin(t * 9 + k) > 0
            local x, y = math.floor(bx + o[1]), math.floor(by + o[2])
            Place(f.birds[k * 3 - 2], f, x - 1, y + (up and -1 or 0), 1, 1)
            Place(f.birds[k * 3 - 1], f, x, y, 1, 1)
            Place(f.birds[k * 3], f, x + 1, y + (up and -1 or 0), 1, 1)
        end
    end
    -- the mist: drifts between its two variants; a place being revealed lifts with sparkles
    local rv = W.reveal
    local prog = rv and math.min(1, (t - rv.t0) / 1.6) or 0
    for id, fg in pairs(f.fog) do
        local p = W.byId[id]
        local on = id == "peaks" or (p and W.Fogged(p))
        local a = 1
        if rv and rv.ids[id] then a = 1 - prog end
        fg.a:SetShown(on and a > 0) fg.b:SetShown(on and a > 0)
        if on then
            fg.a:SetAlpha(a)
            fg.b:SetAlpha(a * (0.5 + 0.5 * math.sin(t * 0.5 + fg.phase)))
        end
    end
    if rv then
        local n = 0
        for id in pairs(rv.ids) do
            local r = A.fog[id]
            for _ = 1, 10 do
                n = n + 1
                local s = f.sparks[n]
                if s and prog < 1 then
                    local seed = (n * 7919 + math.floor(t * 12)) % 997
                    Place(s, f, r[1] + 4 + seed % math.max(1, r[3] - 8), r[2] + 4 + (seed * 31) % math.max(1, r[4] - 8), 1, 1)
                    s:SetAlpha(math.random() < 0.6 and 1 or 0)
                    s:Show()
                end
            end
        end
        for i = n + 1, #f.sparks do f.sparks[i]:Hide() end
        if prog >= 1 then
            W.reveal = nil
            for _, s in ipairs(f.sparks) do s:Hide() end
            W:Refresh()
        end
    end
    -- gryphons on the routes you know
    for k, g in ipairs(f.gryphons) do
        local shown = W.FlightShown(g.def)
        g.tex:SetShown(shown) g.shadow:SetShown(shown)
        if shown and g.len > 0 then
            local s = (t * 16 + k * 70) % (g.len * 2)
            if s > g.len then s = 2 * g.len - s end
            local i = 1
            while i < #g.segs and s > g.segs[i] do s = s - g.segs[i] i = i + 1 end
            local u = s / g.segs[i]
            local a, b = g.pts[i], g.pts[i + 1]
            local x, y = a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u - 4
            local sp = A.sprites[math.sin(t * 10 + k) > 0 and "gryA" or "gryB"]
            Sheet(g.tex, nil, sp[1], sp[2], sp[3], sp[4], 128, 64)
            Place(g.tex, f, math.floor(x - 3), math.floor(y - 2), 7, 5)
            Place(g.shadow, f, math.floor(x - 2), math.floor(y + 9), 5, 1)
        end
    end
    -- lamps flicker after dark
    if period ~= "day" then
        local k = period == "night" and 1 or 0.55
        local flick = 1 + math.sin(t * 7) * 0.04
        for _, gl in ipairs(f.glows) do
            if gl.tex:IsShown() then gl.tex:SetSize(gl.r * flick, gl.r * flick) gl.tex:SetAlpha(0.42 * k) end
        end
    end
    -- you, the selection, rumours
    local here = W.PlaceOf(G.save and G.save.map)
    if here then
        local xy = A.places[here.id]
        local x, y = xy[1] * PX, xy[2] * PX
        local a = 0.45 + 0.55 * math.abs(math.sin(t * 2.5))
        local ring = { { x - 13, y - 11, 26, 2 }, { x - 13, y + 11, 26, 2 }, { x - 13, y - 11, 2, 24 }, { x + 11, y - 11, 2, 24 } }
        for i, r in ipairs(ring) do
            local tx = f.you[i]
            tx:ClearAllPoints() tx:SetPoint("TOPLEFT", f.marks, "TOPLEFT", r[1], -r[2]) tx:SetSize(r[3], r[4]) tx:SetAlpha(a)
        end
        local bob = math.floor(math.abs(math.sin(t * 3)) * 2)
        f.head:ClearAllPoints()
        f.head:SetPoint("TOPLEFT", f.marks, "TOPLEFT", x - 8, -(y - 32) - bob)
        f.headStick:ClearAllPoints() f.headStick:SetPoint("TOPLEFT", f.marks, "TOPLEFT", x - 1, -(y - 22) - bob)
    end
    local sel = W.sel and A.places[W.sel]
    if sel then
        local x, y = sel[1] * PX, sel[2] * PX
        local pulse = math.floor(math.sin(t * 5) * 1.5 + 0.5)
        Bracket(f.brackets, x, y, 16 + pulse, 6)
        f.cursor:ClearAllPoints()
        f.cursor:SetPoint("BOTTOM", f.marks, "TOPLEFT", x, -(y - 16 - 6) + math.floor(math.abs(math.sin(t * 4)) * 3))
        f.cursor:SetShown(not here or W.sel ~= here.id)
    end
    for id, pin in pairs(f.pins) do
        if pin[1]:IsShown() then
            local bob = math.floor(math.sin(t * 2 + #id) + 0.5)
            pin[1]:SetPoint("TOPLEFT", f.marks, "TOPLEFT", ART.places[id][1] * PX - 6, -(pin.cy - 7 + bob))
            pin[2]:SetPoint("TOPLEFT", f.marks, "TOPLEFT", ART.places[id][1] * PX - 5, -(pin.cy - 6 + bob))
            pin.fs:SetPoint("CENTER", f.marks, "TOPLEFT", ART.places[id][1] * PX, -(pin.cy + 1 + bob))
        end
    end
    -- the banner slides in, waits, slides out
    local bn = W.banner
    if bn then
        local age = t - bn.t0
        local slide = age < 0.35 and age / 0.35 or (age > 2.8 and math.max(0, 1 - (age - 2.8) / 0.4) or 1)
        f.banner:ClearAllPoints()
        f.banner:SetPoint("BOTTOM", f, "TOPLEFT", 300, -(f.h + 46 - slide * 62))     -- (rises from the bottom, over the sea)
        f.banner:Show()
        if age > 3.2 then W.banner = nil f.banner:Hide() end
    end
end

---------------------------------------------------------------------------
-- What the panel shows (on open, on a move, after a reveal)
---------------------------------------------------------------------------

-- how many lines `text` wraps to at `width` in the game font at `size`
local function WrapCount(K, text, size, width)
    local n, line = 1, ""
    for word in text:gmatch("%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if line ~= "" and K.TextWidth(try, size) > width then n, line = n + 1, word else line = try end
    end
    return n
end

local function Card(K, f, place)
    local c, info = f.card, W.Info(place)
    local zone
    for _, z in ipairs(W.ZONES) do if z.id == place.zone then zone = z end end
    local known = W.Visited(place)                     -- (a place being revealed: its card already shows it)
    local zc = zone and zone.color or { 0.7, 0.72, 0.78 }
    c.band:SetColorTexture(zc[1], zc[2], zc[3], 1)
    c.zone:SetText(zone and zone.name or "")
    if zone and zone.dark then c.zone:SetTextColor(0.94, 0.92, 1) else c.zone:SetTextColor(zc[1] * 0.34, zc[2] * 0.34, zc[3] * 0.34) end
    local kt = KIND[place.kind] or ""
    local kw = math.ceil(K.TextWidth(kt, 7)) + 10
    c.kind:SetText(kt)
    c.kindBg:ClearAllPoints() c.kindBg:SetPoint("TOPRIGHT", c, "TOPRIGHT", -14, -15) c.kindBg:SetSize(kw, 13)
    c.kind:ClearAllPoints() c.kind:SetPoint("TOPRIGHT", c, "TOPRIGHT", -19, -17)
    c.name:SetText(known and place.name or "???")
    local y = 62
    c.you:SetShown(info.you) c.youBg:SetShown(info.you)
    if info.you then
        c.youBg:SetSize(math.ceil(K.TextWidth("YOU ARE HERE", 7)) + 12, 14)
        y = y + 20
    end
    local text = known and (place.text or "") or (W.Rumoured(place)
        and "A road leads into the mist here. Follow it to find out what's there." or "You haven't been here yet.")
    c.text:SetText(text)
    c.text:ClearAllPoints() c.text:SetPoint("TOPLEFT", c, "TOPLEFT", 14, -(y + 4))
    y = y + 4 + WrapCount(K, text, 9, CARD_W - 28) * 14 + 6
    c.rule:ClearAllPoints() c.rule:SetPoint("TOPLEFT", c, "TOPLEFT", 14, -y)
    y = y + 10
    -- the rows
    local rows = {}
    if known then
        if info.wild then rows[#rows + 1] = { tile = "tall_c", label = "Wild beasts", value = string.format("Lv %d - %d", info.wild[1], info.wild[2]) } end
        if info.beasts then
            rows[#rows + 1] = { char = { 0, 64 }, label = "Beasts", value = string.format("%d/%d seen", info.beasts.seen, info.beasts.total),
                                pips = info.beasts }
        end
        if info.trainers then
            rows[#rows + 1] = { char = { 48, 0 }, label = "Trainers", value = string.format("%d/%d beaten", info.trainers.beaten, info.trainers.total) }
        end
        if info.badge then
            rows[#rows + 1] = { crest = info.badge.earned, label = info.badge.name, value = info.badge.earned and "Earned" or "Not yet" }
        end
    end
    c.shown = { rows = {}, tags = {} }
    local pipN = 0
    for i, r in ipairs(c.rows) do
        local d = rows[i]
        r.icon:SetShown(d ~= nil and not d.crest) r.label:SetShown(d ~= nil) r.value:SetShown(d ~= nil)
        for _, t in ipairs(r.icon2) do t:SetShown(d ~= nil and d.crest ~= nil) end
        if d then
            c.shown.rows[i] = d.label .. ": " .. d.value
            r.icon:ClearAllPoints() r.icon:SetPoint("TOPLEFT", c, "TOPLEFT", 14, -y)
            if d.tile then K.Tile(r.icon, d.tile) r.icon:SetVertexColor(1, 1, 1) r.icon:SetAlpha(1)
            elseif d.char then
                K.PixelTexture(r.icon, CHARS)
                r.icon:SetTexCoord(d.char[1] / 256, (d.char[1] + 16) / 256, d.char[2] / 128, (d.char[2] + 16) / 128)
                r.icon.tileName = nil
            end
            for k, nm in ipairs({ "crest_0_0", "crest_1_0", "crest_0_1", "crest_1_1" }) do
                local t = r.icon2[k]
                if d.crest ~= nil then
                    K.Tile(t, nm)
                    t:ClearAllPoints() t:SetPoint("TOPLEFT", c, "TOPLEFT", 14 + ((k - 1) % 2) * 8, -(y + math.floor((k - 1) / 2) * 8))
                    t:SetAlpha(d.crest and 1 or 0.35)
                end
            end
            r.label:SetText(d.label)
            r.label:ClearAllPoints() r.label:SetPoint("TOPLEFT", c, "TOPLEFT", 36, -(y + 2))
            r.value:SetText(d.value)
            r.value:ClearAllPoints() r.value:SetPoint("TOPRIGHT", c, "TOPRIGHT", -14, -(y + 2))
            y = y + 20
            if d.pips then
                local total = math.min(d.pips.total, PIPS)
                for k = 1, total do
                    local px, py = 36 + ((k - 1) % 14) * 9, y + math.floor((k - 1) / 14) * 9
                    local pe, pf = c.pips[k][1], c.pips[k][2]
                    pe:ClearAllPoints() pe:SetPoint("TOPLEFT", c, "TOPLEFT", px, -py) pe:SetSize(7, 7)
                    pf:ClearAllPoints() pf:SetPoint("TOPLEFT", c, "TOPLEFT", px + 1, -(py + 1)) pf:SetSize(5, 5)
                    if k <= d.pips.caught then pf:SetColorTexture(0.89, 0.71, 0.25, 1)
                    elseif k <= d.pips.seen then pf:SetColorTexture(0.47, 0.63, 0.84, 1)
                    else pf:SetColorTexture(0.84, 0.85, 0.89, 1) end
                    pe:Show() pf:Show()
                end
                pipN = total
                y = y + 9 * math.ceil(total / 14) + 2
                c.tamed:SetText(string.format("%d tamed", d.pips.caught))
                c.tamed:ClearAllPoints() c.tamed:SetPoint("TOPLEFT", c, "TOPLEFT", 36, -y)
                y = y + 14
            end
        end
    end
    c.tamed:SetShown(pipN > 0)
    for k = pipN + 1, PIPS do c.pips[k][1]:Hide() c.pips[k][2]:Hide() end
    -- what's here
    local tags = known and info.tags or {}
    c.hereHead:SetShown(#tags > 0)
    if #tags > 0 then
        c.hereHead:ClearAllPoints() c.hereHead:SetPoint("TOPLEFT", c, "TOPLEFT", 14, -(y + 2))
        y = y + 14
    end
    local half = (CARD_W - 28) / 2
    for i, ch in ipairs(c.chips) do
        local tg = tags[i]
        ch.bg:SetShown(tg ~= nil) ch.icon:SetShown(tg ~= nil) ch.fs:SetShown(tg ~= nil)
        if tg then
            c.shown.tags[i] = tg
            local cx, cy = 14 + ((i - 1) % 2) * half, y + math.floor((i - 1) / 2) * 20
            ch.bg:ClearAllPoints() ch.bg:SetPoint("TOPLEFT", c, "TOPLEFT", cx, -cy)
            K.Tile(ch.icon, TAG_ICON[tg] or "sign")
            ch.icon:ClearAllPoints() ch.icon:SetPoint("TOPLEFT", c, "TOPLEFT", cx + 1, -(cy + 1))
            ch.fs:SetText(TAG_SHORT[tg] or tg)
            ch.fs:ClearAllPoints() ch.fs:SetPoint("TOPLEFT", c, "TOPLEFT", cx + 20, -(cy + 4))
        end
    end
    y = y + math.ceil(#tags / 2) * 20 + (#tags > 0 and 6 or 0)
    -- guildmates there now
    local here = info.here
    c.matesHead:SetShown(#here > 0)
    if #here > 0 then
        c.matesHead:ClearAllPoints() c.matesHead:SetPoint("TOPLEFT", c, "TOPLEFT", 14, -(y + 2))
        y = y + 14
    end
    for i, m in ipairs(c.mates) do
        local peer = here[i]
        m.edge:SetShown(peer ~= nil) m.dot:SetShown(peer ~= nil) m.fs:SetShown(peer ~= nil)
        if peer then
            local cc = peer.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[peer.class]
            local r, g, b = cc and cc.r or 1, cc and cc.g or 1, cc and cc.b or 1
            m.edge:ClearAllPoints() m.edge:SetPoint("TOPLEFT", c, "TOPLEFT", 14, -(y + 1))
            m.dot:ClearAllPoints() m.dot:SetPoint("TOPLEFT", c, "TOPLEFT", 15, -(y + 2))
            m.dot:SetColorTexture(r, g, b, 1)
            m.fs:SetText(peer.name or "")
            m.fs:SetTextColor(r * 0.7, g * 0.7, b * 0.7)
            m.fs:ClearAllPoints() m.fs:SetPoint("TOPLEFT", c, "TOPLEFT", 28, -y)
            y = y + 14
        end
    end
end

function W:Refresh()
    local f = W.frame
    if not f then return end
    local K = ns.AzeroUI.Kit
    local herePlace = W.PlaceOf(G.save.map)
    -- the time of day
    local period = G:Period()
    f.period = period
    local dark = DARK[period]
    f.dark:SetShown(dark ~= nil)
    if dark then
        f.dark:SetColorTexture(dark[1], dark[2], dark[3], 1)
        pcall(f.dark.SetBlendMode, f.dark, "MOD")
    end
    f.smokeHidden = {}
    for _, s in ipairs(ART.smoke) do if UnderMist(s[1], s[2]) then f.smokeHidden[s[1] .. "," .. s[2]] = true end end
    for _, gl in ipairs(f.glows) do gl.tex:SetShown(dark ~= nil and not UnderMist(gl.x, gl.y)) end
    for _, wd in ipairs(f.windows) do wd.tex:SetShown(dark ~= nil and not UnderMist(wd.x, wd.y)) end
    -- zone ribbons: a zone's name once you know a place in it
    for _, z in ipairs(W.ZONES) do
        local any = false
        for _, p in ipairs(W.PLACES) do if p.zone == z.id and not W.Fogged(p) then any = true end end
        local pos = W.LABELS[z.id]
        if pos then
            f.ribbons[z.id].Set(pos[1], pos[2], any and z.name or "???", any and z.color or { 0.72, 0.74, 0.8 }, any and z.dark)
        end
    end
    -- pins: "?" where a road leads into the mist; guildmates where they are
    for _, p in ipairs(W.PLACES) do
        local pin = f.pins[p.id]
        local show = W.Rumoured(p)
        pin[1]:SetShown(show) pin[2]:SetShown(show) pin.fs:SetShown(show)
        local here = W.Fogged(p) and {} or W.Info(p).here
        for i, dot in ipairs(f.mates[p.id]) do
            local peer = here[i]
            local cc = peer and peer.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[peer.class]
            if cc then dot[2]:SetColorTexture(cc.r, cc.g, cc.b, 1) else dot[2]:SetColorTexture(1, 1, 1, 1) end
            dot[1]:SetShown(peer ~= nil) dot[2]:SetShown(peer ~= nil)
        end
    end
    for _, t in ipairs(f.you) do t:SetShown(herePlace ~= nil) end
    f.head:SetShown(herePlace ~= nil) f.headStick:SetShown(herePlace ~= nil)
    local place = W.byId[W.sel] or W.PLACES[1]
    Card(K, f, place)
    W:Animate(0)
end

function W:Key(key)
    if STEP[key] then
        W.sel = W.Neighbour(W.sel, key)
        W:Refresh()
        return true
    end
    return false
end

-- Places found since the map was last opened: revealed now (a save from before the reveal: all shown, quietly).
local function Discoveries()
    local s = G.save
    local seen = s.mapSeen
    local new, first = {}, nil
    if type(seen) ~= "table" then
        seen = {}
        s.mapSeen = seen
        for _, p in ipairs(W.PLACES) do if W.Visited(p) then seen[p.id] = true end end
        return nil
    end
    local n = 0
    for _, p in ipairs(W.PLACES) do
        if W.Visited(p) and not seen[p.id] then
            seen[p.id] = true
            new[p.id] = true
            n = n + 1
            first = first or p
        end
    end
    if n == 0 then return nil end
    return new, first, n
end

function W:Open()
    ns.AzeroSound:Play("map")
    local K = ns.AzeroUI.Kit
    local f = W.frame or W:Build(K)
    local here = W.PlaceOf(G.save.map)
    W.sel = here and here.id or "goldshire"
    W.reveal, W.banner = nil, nil
    local new, first, n = Discoveries()
    if new then
        W.reveal = { ids = new, t0 = f.clock + 0.4 }
        W.banner = { t0 = f.clock + 0.2 }
        f.banner.name:SetText(n > 1 and string.format("%s and %d more", first.name, n - 1) or first.name)
        W.sel = first.id
    else
        f.banner:Hide()
    end
    W:Refresh()
    local stack = K.stack
    local top = stack[#stack]
    f:SetFrameLevel(math.max(100, top and top.frame and top.frame:GetFrameLevel() + 10 or 0))
    f.marks:SetFrameLevel(f:GetFrameLevel() + 2)
    f.card:SetFrameLevel(f:GetFrameLevel() + 4)
    f.banner:SetFrameLevel(f:GetFrameLevel() + 8)
    f:Show()
    stack[#stack + 1] = { frame = f, items = {}, cursor = 1, cols = 1, isPanel = true,
        onKey = function(key) return W:Key(key) end,
        opts = { onCancel = function(m) K.PopMenu(m) f:Hide() end } }
end

-- Tests: what the panel shows.
function W._State()
    local f = W.frame
    if not f or not f:IsShown() then return nil end
    local place = W.byId[W.sel]
    local l = W.Lines(place)
    local fog, pins, reveal = {}, {}, {}
    for id, fg in pairs(f.fog) do if fg.a:IsShown() then fog[#fog + 1] = id end end
    for id, pin in pairs(f.pins) do if pin[1]:IsShown() then pins[#pins + 1] = id end end
    for id in pairs(W.reveal and W.reveal.ids or {}) do reveal[#reveal + 1] = id end
    table.sort(fog) table.sort(pins) table.sort(reveal)
    local c = f.card
    return { sel = W.sel, name = c.name:GetText(), zone = c.zone:GetText(), text = c.text:GetText() or "",
             line3 = l.line3, line4 = l.line4, rows = c.shown.rows, tags = c.shown.tags, fog = fog, pins = pins,
             reveal = reveal, banner = f.banner:IsShown() and f.banner.name:GetText() or nil, period = f.period,
             artOK = f.artOK }
end
