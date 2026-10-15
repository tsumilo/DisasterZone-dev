if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Sound.lua", ...) then return end -- DisasterZone Games/Azeromon/Sound.lua
-- ns.AzeroSound: music and sound effects, all WoW's own (FileDataIDs from the community listfile: the classic
-- files every client has; a file a client lacks simply stays silent).
-- Music plays only while the game is on screen - StopMusic() hands the zone music back - and each map picks its
-- track (def.music; day and night where the zone has both). Battles, the title screen and the arena have their own.
-- The CONTROLS page turns music, sounds and ambience off (DisasterZoneDB.games.azeromon.music / .sfx / .ambience).
-- Ambience (below): the zone's day / night loop, rain, and sources by distance (water, fish, the smithy, the inn).
local addonName, ns = ...

local S = ns:NewModule("AzeroSound")
local G = ns.Azero

S.TRACKS = {
    title = { 53223 },                                                   -- the original World of Warcraft theme
    forest = { day = { 53492, 53493, 53494 }, night = { 53495, 53496, 53497, 53498 } },   -- Elwynn Forest
    plains = { day = { 53680, 53681 }, night = { 53682, 53683 } },                      -- Westfall
    tavern = { 53748, 53749, 53750, 53751 },                             -- a human tavern (the inns, houses)
    mine = { 53240, 53241, 53242 },                                      -- the Deadmines' tunnels
    cove = { 53762, 53763, 53764, 53765 },                               -- Ironclad Cove: a pirate's tune
    battle = { 53684, 53685, 53686, 53687, 53688 },                      -- the classic battleground music
    arena = { day = { 53541, 53542, 53543 }, night = { 53544, 53545, 53546 } },       -- the jungle (Gurubashi)
    duskwood = { day = { 53486, 53487, 53488 }, night = { 53489, 53490, 53491 } },    -- Duskwood (evilforest)
    haunted = { 53234, 53235 },                                          -- a haunted house (Manor Mistmantle)
}

-- Sound effects: FileDataIDs checked against the community listfile, vanilla/TBC-era files only (the Anniversary
-- client has them). A table keyed by type (hit) takes the move's type as Play's `arg`.
S.SFX = {
    -- menus and text
    cursor = 567407,                                                     -- uchatscrollbutton (a soft tick)
    select = 567437,                                                     -- iuimainmenubuttona
    back = 567481,                                                       -- iuiinterfacebuttona
    text = 567407,
    open = 567490, close = 567464,                                       -- uescapescreenopen / close
    book = 567545, page = 567472,                                        -- pickupbook, iabilitiesturnpagea
    sheet = 567507, tab = 567422,                                        -- ucharactersheetopen / tab
    bag = 567543,                                                        -- pickupbag
    shop = 567483,                                                       -- imoneydialogopen
    stable = 567485,                                                     -- guildvaultopen
    map = 567529,                                                        -- uminimapopen
    quests = 567504,                                                     -- iquestlogopena
    start = 567419,                                                      -- ienterworlda
    error = 567520,                                                      -- ideselecttarget
    -- the world
    bump = 567566,                                                       -- putdownwoodsmall (a thud)
    door = 567461,                                                       -- iequipmentcontaineropena (a creak)
    chest = 567125,                                                      -- doodad chestopen
    item = 567517,                                                       -- uilootpickupitem
    gift = 567400,                                                       -- iquestactivate
    spotted = 567488,                                                    -- pvpwarning: a trainer saw you
    encounter = 567473,                                                  -- unsheathmetal: a wild beast
    heal = 569570,                                                       -- heal_low_base
    drink = 567492,                                                      -- idrinking1
    cure = 569632,                                                       -- nullifypoison
    equip = 567560,                                                      -- pickupmetalsmall
    buy = 567428, sell = 567413,                                         -- lootcoinsmall / lootcoinlarge
    fishcast = 569807, fishbite = 569816, fishreel = 569808,
    bell = 566564,                                                       -- doodad belltollalliance (Darkshire at dusk)             -- tradeskills fishcast / fishbite / fishreelin
    herb = 567552, ore = 567564,                                         -- pickupherb / pickuprocks_ore01
    alchemy = 565598, smith = 567569,                                    -- ak_alchemyset01 / putdownlargemetal
    skillup = 567516, learn = 567400,                                    -- iquestupdate / iquestactivate
    trade = 567406,                                                      -- unwrapgift
    request = 567409,                                                    -- readycheck: a challenge or a trade offer
    bounty = 567439,                                                     -- iquestcomplete
    fanfare = 567434,                                                    -- pvpflagcapturedmono (badges, guild tiers)
    victory = 567408,                                                    -- pvpvictoryalliancemono
    defeat = 567459,                                                     -- igquestfailed
    -- battles
    sendout = 569526,                                                    -- polymorphtarget (a poof)
    recall = 567520,                                                     -- ideselecttarget
    faint = 569776,                                                      -- fizzleshadowa
    miss = 569774,                                                       -- fizzlenaturea
    immune = 569775,                                                     -- fizzlefrosta
    crit = 567837,                                                       -- parrymetalhitmetalcrit
    super = 567850,                                                      -- 1hparrymetalhitmetalcritical
    weak = 567854,                                                       -- 1hparrywoodhitwood
    recoil = 567842,                                                     -- parrywoodhitwood
    drain = 568287,                                                      -- healingaura
    statup = 568424,                                                     -- armorkitbuffsound
    statdown = 569772,                                                   -- fizzleholya
    brn = 569773, psn = 568950, par = 567838, slp = 568774,              -- fizzlefirea, shootwandlaunchpoison,
                                                                         -- parrymetalhitmetal, sleepimpact
    wake = 567436,                                                       -- alarmclockwarning1
    throw = 567565, shake = 567613, breakfree = 567572,                  -- pickupcloth, uselockpick01, putdownlargechain
    run = 567464,                                                        -- uescapescreenclose
    levelup = 567431,                                                    -- sound/interface/levelup
    catch = 567439,                                                      -- iquestcomplete
    evolve = 568667, evolved = 567478,                                   -- resurrection, levelup2
    shiny = 568154,                                                      -- shaysbell (a chime)
    hit = { FIRE = 568461, NATURE = 569708, SHADOW = 569471, EARTH = 569222, WATER = 568318,
            AIR = 568516, BEAST = 568003, MECH = 568227, NONE = 568003 },
}

-- The shortest gap before a sound repeats (default 50 ms): walking into a wall retries every 0.2 s.
S.GAP = { bump = 0.45 }

-- Game events (G:Emit) that make a sound: event -> a S.SFX name, or a function(e) returning one (or nil).
S.ON_EVENT = {
    chest = "chest",
    evolve = "evolved",
    shiny = "shiny",
    badge = "fanfare",
    guildtier = "fanfare",                  -- (the bounty / guild goal toasts stay silent: one sound each)
    bounty = "bounty",
    sell = "sell",
    craft = function(e) return e.prof == "alchemy" and "alchemy" or "smith" end,
    gather = function(e) return e.prof == "herbalism" and "herb" or "ore" end,
    skillup = "skillup",
    learn = "learn",
    relearn = "learn",
    equip = "equip",
    trade = "trade",
    blackout = "defeat",
    tame = function(e) return e.how ~= "caught" and "gift" or nil end,
    battle = function(e) return (e.result == "win" and not e.wild) and "victory" or nil end,
    pvp = function(e) return (e.result == "win" and "victory") or (e.result == "lose" and "defeat") or nil end,
    arena = "victory",
}

local current, currentKey = nil, nil

function S:MusicOn() return G:Data().music ~= false end
function S:SfxOn() return G:Data().sfx ~= false end

-- Plays `key`'s track (a S.TRACKS entry), or stops the game's music when key is nil or music is off.
-- The same key keeps its track playing; day and night count as different tracks.
function S:Music(key)
    if not self:MusicOn() then key = nil end
    local list = key and S.TRACKS[key]
    local want = key
    if type(list) == "table" and list.day then
        local night = G.IsNight and G:IsNight()
        list = night and list.night or list.day
        want = key .. (night and ":night" or ":day")
    end
    if want == currentKey then return end
    currentKey = want
    if not list then
        if current then
            current = nil
            if StopMusic then pcall(StopMusic) end
        end
        return
    end
    current = list[math.random(#list)]
    if PlayMusic then pcall(PlayMusic, current) end
end

function S:Stop() self:Music(nil) end
function S:Current() return current, currentKey end

-- A sound effect: name in S.SFX (hit takes the move's type as `arg`). Played on the Master channel like the
-- achievement toast: on "SFX" the game was silent for anyone whose Sound Effects channel is off or low while their
-- music is up. The same sound is not repeated within 50 ms (a menu redrawn twice, events in one frame).
local lastAt, warned = {}, false
function S:Play(name, arg)
    if not self:SfxOn() then return end
    local id = S.SFX[name]
    if type(id) == "table" then id = id[arg] or id.NONE end
    if not id or not PlaySoundFile then return end
    local now = GetTime and GetTime() or 0
    if lastAt[id] and now - lastAt[id] < (S.GAP[name] or 0.05) then return end
    lastAt[id] = now
    local ok, willPlay = pcall(PlaySoundFile, id, "Master")
    if (not ok or willPlay == false) and not warned then
        warned = true               -- once a session: sound switched off in the game, or a file this client lacks
        ns:Print("%s", string.format("Azeromon: the '%s' sound (%s) didn't play. Is Enable Sound on in the game's Sound options?",
            tostring(name), tostring(id)))
    end
end

function S:OnInit()
    for event, r in pairs(S.ON_EVENT) do
        G:On(event, function(_, e)
            local name = r
            if type(r) == "function" then name = r(e) end
            if name then S:Play(name) end
        end)
    end
end

---------------------------------------------------------------------------
-- Ambience: the world's own sound, in layers (the CONTROLS page's "Ambience", G:Data().ambience = false: off)
--   bed      the zone's day or night loop (birds by day, crickets and owls by night), or the room's (the inn's
--            murmur, crowded once a few people are in)
--   rain     over the bed while it rains (Amb.Raining in UI.lua sets G.raining)
--   sources  loops that start within a radius and fade out past it: still water by the shore, a school of fish,
--            the smithy while Argus works it, the inn's crowd at the door when it's full
--   one-shots that come more often the nearer you are: the anvil's ring, an owl at night
-- Played on the game's Ambience channel (its volume slider applies) - but some clients refuse every sound on it
-- (PlaySoundFile returns nothing; seen 2026-10-15 with the slider at 60%), and then on Master for the rest of the
-- session, like the effects. Each loop is restarted as it ends: LEN holds
-- every file's length, measured from the installed client's files (Ogg granule / rate).
---------------------------------------------------------------------------

-- id -> seconds
S.LEN = {
    [539131] = 60, [539108] = 60,                    -- zoneambience forestnormalday / night (Elwynn)
    [539006] = 60, [539121] = 30,                    -- westfallday / night
    [539098] = 59.44, [538996] = 59.54,              -- forestscaryday / night (Duskwood)
    [539097] = 60, [539092] = 60,                    -- jungleday / night (Stranglethorn)
    [539048] = 56.84, [539125] = 56.94,              -- beachday / night (Booty Bay)
    [539047] = 60, [538994] = 60,                    -- foresthighday / night (Redridge)
    [539024] = 56.47, [539061] = 56.47,              -- canyondesertday / night (the Searing Gorge)
    [539073] = 56.94, [539077] = 56.94,              -- volcanicday / night (the Burning Steppes, the mountain)
    [539071] = 56.94,                                -- deadmines
    [537422] = 60, [537423] = 55.9,                  -- wmoambience tavern / taverncrowded
    [538983] = 20, [538981] = 30,                    -- weather rainlightloop / rainmediumloop
    [538973] = 10.12,                                -- water river_lakestilla
    [566808] = 5.19,                                 -- doodad tradeskill_fishschool_01standvar2
    [537332] = 59.54,                                -- wmoambience blacksmith
    [538985] = 29.95,                                -- weather snowlight: a soft wind (no forest wind loop in 2.5)
}
-- the bed for each map theme (UI.lua Amb.MOODS keys), day and night
S.BEDS = {
    elwynn = { day = 539131, night = 539108 },
    westfall = { day = 539006, night = 539121 },
    duskwood = { day = 539098, night = 538996 },
    jungle = { day = 539097, night = 539092 },
    arena = { day = 539097, night = 539092 },
    beach = { day = 539048, night = 539125 },
    redridge = { day = 539047, night = 538994 },
    gorge = { day = 539024, night = 539061 },
    steppes = { day = 539073, night = 539077 },
    blackrock = { day = 539073, night = 539077 },
    mine = { day = 539071, night = 539071 },
}
S.MAP_BED = { bootybay = "beach" }          -- maps whose bed isn't their theme's
S.TAVERN, S.TAVERN_CROWDED = 537422, 537423
S.CROWD = 3                                 -- people inside before the inn sounds crowded
S.RAIN = 538981
S.SOURCES = {
    water = { id = 538973, radius = 3 },    -- still water, from the nearest shore tile
    school = { id = 566808, radius = 3 },   -- a school of fish (Fishing.lua)
    smithy = { id = 537332, radius = 5 },   -- a forge or anvil, while someone is smithing at it
    inn = { id = 537423, radius = 4 },      -- the door of a room with S.CROWD or more people in it
    wind = { id = 538985, radius = 2 },     -- wind in the trees, near the forest's edge
}
S.WIND_THEMES = { elwynn = true, westfall = true, duskwood = true, redridge = true, jungle = true }
-- one-shots: id(s), and the gap in seconds near (distance 0) and far (at radius)
S.SHOTS = {
    anvil = { ids = { 569814, 569822, 569799 }, radius = 7, near = 1.8, far = 6 },     -- blacksmithcrafting a/b/c
    owl = { ids = { 557971 }, near = 25, far = 60 },                                    -- owlpreaggro, night woods
    frog = { ids = { 549327 }, radius = 6, near = 5, far = 14 },                        -- creature/frog/float, by a pond
}
S.FROG_THEMES = { elwynn = true, westfall = true, duskwood = true, redridge = true }
S.OWL_THEMES = { elwynn = true, duskwood = true, redridge = true }
S.FADE = 1500                               -- ms a loop takes to fade when it stops
S.TICK = 0.25                               -- seconds between ambience updates

function S:AmbienceOn() return G:Data().ambience ~= false end

-- The inn's lute: by the door of a room with S.CROWD or more people in it, the zone's music gives way to the
-- tavern's tune spilling out (the inn's own music: Maps def.music of the room). Starts within LUTE_IN tiles of the
-- door, stops past LUTE_OUT, so standing at the edge doesn't flip it back and forth.
S.LUTE_IN, S.LUTE_OUT = 4, 6
local luteOn = false
function S:InnMusic()
    local m, s, Routine, Maps = G.map, G.save, ns.AzeroRoutine, ns.AzeroMaps
    if not (G.started and m and s and Routine and m.def.outdoor) then luteOn = false return nil end
    local best, music
    for _, st in ipairs(m.def.stamps or {}) do
        local id = st.inside or st.inn                 -- (inn: an inn whose house stamp other buildings share)
        local room = id and Maps[id]
        if room and room.music and Routine.InsideCount(id) >= S.CROWD then
            for _, wp in pairs(m.warp) do
                if wp.map == id then
                    local d = math.max(math.abs(wp.x - s.x), math.abs(wp.y - s.y))
                    if not best or d < best then best, music = d, room.music end
                end
            end
        end
    end
    luteOn = best ~= nil and best <= (luteOn and S.LUTE_OUT or S.LUTE_IN)
    return luteOn and music or nil
end

local playing = {}          -- key -> { id, handle, at }
local shotAt = {}
local tickAcc = 0
S.trace = nil               -- tests: a list that gets { "play" | "stop", key, id }

local function Clock() return GetTime and GetTime() or 0 end

-- Plays an ambience file; returns its handle. The Ambience channel until it refuses a file that Master plays.
S.ambChannel = "Ambience"
function S.PlayAmbient(id)
    if not PlaySoundFile then return nil end
    local ok, willPlay, handle = pcall(PlaySoundFile, id, S.ambChannel)
    if (not ok or not willPlay) and S.ambChannel ~= "Master" then
        local ok2, will2, handle2 = pcall(PlaySoundFile, id, "Master")
        if ok2 and will2 then
            S.ambChannel = "Master"
            return handle2
        end
    end
    return ok and willPlay and handle or nil
end

local function Start(key, id)
    if not PlaySoundFile then return end
    playing[key] = { id = id, handle = S.PlayAmbient(id), at = Clock() }
    if S.trace then S.trace[#S.trace + 1] = { "play", key, id } end
end

local function Halt(key, fade)
    local p = playing[key]
    if not p then return end
    if p.handle and StopSound then pcall(StopSound, p.handle, fade or S.FADE) end
    playing[key] = nil
    if S.trace then S.trace[#S.trace + 1] = { "stop", key, p.id } end
end

-- The tile distance (Chebyshev) from the player to the nearest of `tiles` ({ x, y } lists), or nil.
local function Nearest(s, tiles)
    local best
    for _, t in ipairs(tiles) do
        local d = math.max(math.abs(t.x - s.x), math.abs(t.y - s.y))
        if not best or d < best then best = d end
    end
    return best
end

-- The forest's edge trees: "T" tiles of the map's rows next to open ground (cached on the compiled map).
function S.TreeEdge(m)
    if m.treeEdge then return m.treeEdge end
    local list, rows = {}, m.def.rows or {}
    local function tree(x, y)
        local r = rows[y + 1]
        return not r or x < 0 or x >= #r or r:sub(x + 1, x + 1) == "T"
    end
    for y = 0, #rows - 1 do
        for x = 0, #rows[y + 1] - 1 do
            if tree(x, y) and (not tree(x + 1, y) or not tree(x - 1, y) or not tree(x, y + 1) or not tree(x, y - 1)) then
                list[#list + 1] = { x = x, y = y }
            end
        end
    end
    m.treeEdge = list
    return list
end

-- What should be heard right now: key -> id loops, and the one-shots with their distance.
function S:AmbienceWants()
    local wants, shots = {}, {}
    local m, s = G.map, G.save
    if not (G.started and m and s) then return wants, shots end
    local night = G.IsNight and G:IsNight()
    local Routine, Fish = ns.AzeroRoutine, ns.AzeroFish
    -- the bed
    if m.def.outdoor then
        local bed = S.BEDS[S.MAP_BED[m.id] or m.def.theme or "elwynn"]
        if bed then wants.bed = night and bed.night or bed.day end
        if G.raining then wants.rain = S.RAIN end
    elseif m.def.music == "tavern" then
        local n = Routine and Routine.InsideCount(m.id) or 0
        wants.bed = n >= S.CROWD and S.TAVERN_CROWDED or S.TAVERN
    elseif m.def.music == "mine" or m.def.cave then
        wants.bed = S.BEDS.mine.day
    end
    if not m.def.outdoor then return wants, shots end
    -- water and fish
    if Fish and Fish.WaterOf(m) then
        local d = Nearest(s, Fish.Shore(m))
        if d and d <= S.SOURCES.water.radius then wants.water = S.SOURCES.water.id end
        local sc = Fish.School(m)
        if sc and Nearest(s, { sc }) <= S.SOURCES.school.radius then wants.school = S.SOURCES.school.id end
    end
    -- the smithy: someone at work by a forge or anvil
    for _, n in ipairs(G.npcs or {}) do
        if n.act == "smith" and not n.hidden then
            local d = Nearest(s, { n })
            if d <= S.SOURCES.smithy.radius then wants.smithy = S.SOURCES.smithy.id end
            if d <= S.SHOTS.anvil.radius then shots.anvil = d end
        end
    end
    -- a full room's door
    if Routine then
        for _, st in ipairs(m.def.stamps or {}) do
            local room = st.inside or st.inn
            if room and Routine.InsideCount(room) >= S.CROWD then
                local doors = {}
                for _, wp in pairs(m.warp) do
                    if wp.map == room then doors[#doors + 1] = { x = wp.x, y = wp.y } end
                end
                local d = Nearest(s, doors)
                if d and d <= S.SOURCES.inn.radius then wants.inn = S.SOURCES.inn.id end
            end
        end
    end
    if night and S.OWL_THEMES[m.def.theme or "elwynn"] and not G.raining then shots.owl = 0 end
    local theme = m.def.theme or "elwynn"
    -- wind in the trees at the forest's edge
    if S.WIND_THEMES[theme] then
        local d = Nearest(s, S.TreeEdge(m))
        if d and d <= S.SOURCES.wind.radius then wants.wind = S.SOURCES.wind.id end
    end
    -- frogs by a pond (not the sea)
    if S.FROG_THEMES[theme] and Fish and Fish.WaterOf(m) and not m.def.coastEncounters then
        local d = Nearest(s, Fish.Shore(m))
        if d and d <= S.SHOTS.frog.radius then shots.frog = d end
    end
    return wants, shots
end

-- Called every frame by the UI (any time: with the game hidden or in a battle it stops everything).
function S:UpdateAmbience(dt, active)
    tickAcc = tickAcc + (dt or 0)
    if tickAcc < S.TICK then return end
    tickAcc = 0
    local wants, shots = {}, {}
    if active and self:AmbienceOn() then wants, shots = self:AmbienceWants() end
    local now = Clock()
    for key, p in pairs(playing) do
        if wants[key] ~= p.id then Halt(key, key == "bed" and 3000 or S.FADE) end
    end
    for key, id in pairs(wants) do
        local p = playing[key]
        if not p then
            Start(key, id)
        elseif now - p.at >= (S.LEN[id] or 30) - 0.1 then
            Start(key, id)                  -- the file is ending: the next pass starts as it stops
        end
    end
    for key, d in pairs(shots) do
        local def = S.SHOTS[key]
        local gap = def.near + (def.far - def.near) * math.min(1, d / (def.radius or 1))
        if not shotAt[key] then
            shotAt[key] = now - gap * 0.5   -- (the first comes a little after arriving)
        elseif now - shotAt[key] >= gap then
            shotAt[key] = now
            local id = def.ids[math.random(#def.ids)]
            S.PlayAmbient(id)
            if S.trace then S.trace[#S.trace + 1] = { "shot", key, id } end
        end
    end
    for key in pairs(shotAt) do if not shots[key] then shotAt[key] = nil end end
end

function S:StopAmbience()
    for key in pairs(playing) do Halt(key) end
    shotAt = {}
end

function S:Playing()
    local out = {}
    for k, p in pairs(playing) do out[k] = p.id end
    return out
end

-- For tests
S._Reset = function()
    luteOn = false
    current, currentKey = nil, nil
    lastAt, warned = {}, false
    playing, shotAt, tickAcc = {}, {}, 0
    S.ambChannel = "Ambience"
end
