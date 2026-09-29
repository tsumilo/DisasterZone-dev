-- CDLoot Games/Azeromon/Sound.lua
-- ns.AzeroSound: music and sound effects, all WoW's own (FileDataIDs from the community listfile: the classic
-- files every client has; a file a client lacks simply stays silent).
-- Music plays only while the game is on screen - StopMusic() hands the zone music back - and each map picks its
-- track (def.music; day and night where the zone has both). Battles, the title screen and the arena have their own.
-- The CONTROLS page turns music and sounds off (CDLootDB.games.azeromon.music / .sfx = false).
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

S.SFX = {
    levelup = 567431,                                                    -- sound/interface/levelup
    catch = 567439,                                                      -- iquestcomplete
    heal = 569570,                                                       -- heal_low_base
    select = 567407,                                                     -- uchatscrollbutton (a soft tick)
    hit = { FIRE = 568461, NATURE = 569708, SHADOW = 569471, EARTH = 569222, WATER = 568318,
            AIR = 568516, BEAST = 568003, MECH = 568227, NONE = 568003 },
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

-- A sound effect: name in S.SFX (hit takes the move's type as `arg`).
function S:Play(name, arg)
    if not self:SfxOn() then return end
    local id = S.SFX[name]
    if type(id) == "table" then id = id[arg] or id.NONE end
    if id and PlaySoundFile then pcall(PlaySoundFile, id, "SFX") end
end

-- For tests
S._Reset = function() current, currentKey = nil, nil end
