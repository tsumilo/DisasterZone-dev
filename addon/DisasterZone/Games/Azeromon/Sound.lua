if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Sound.lua", ...) then return end -- DisasterZone Games/Azeromon/Sound.lua
-- ns.AzeroSound: music and sound effects, all WoW's own (FileDataIDs from the community listfile: the classic
-- files every client has; a file a client lacks simply stays silent).
-- Music plays only while the game is on screen - StopMusic() hands the zone music back - and each map picks its
-- track (def.music; day and night where the zone has both). Battles, the title screen and the arena have their own.
-- The CONTROLS page turns music and sounds off (DisasterZoneDB.games.azeromon.music / .sfx = false).
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
    guildtier = "fanfare",
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

-- For tests
S._Reset = function() current, currentKey = nil, nil lastAt, warned = {}, false end
