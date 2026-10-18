if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/Steps.lua", ...) then return end -- DisasterZone_Azeromon/Steps.lua
-- ns.AzeroSteps: footsteps (Azeromon 0.47). One step per tile as the foot lands, from the ground it lands on:
-- grass, tall grass, road, sand, dock, shallows outside; inn floor, rug, flagstones, cave floor inside. In the rain
-- the outdoor grounds sound wet (mud, a splash on wood); the first step into the shallows splashes.
-- The sounds are WoW's own footstep files mixed and baked by dev/generators/gen_azeromon_steps.py into
-- Media/Steps (StepsArt.lua lists them): the game can't set a sound's volume or pitch, so the level, the pitch
-- spread and the wet mixes are in the files. Played on Master like the game's other effects; CONTROLS has a
-- Footsteps switch (G:Data().steps), and Sounds off silences them too.
-- Game.lua (G:Update) calls Footfall once per step when the foot lands (G.FOOT_LAND of the step).
local addonName, ns = ...

local S = {}
ns.AzeroSteps = S
local G = ns.Azero

local floor = math.floor
S.DIR = "Interface\\AddOns\\DisasterZone_Azeromon\\Media\\Steps\\"
S.trace = nil               -- tests: a list that gets { set, n, file }

local function Art() return ns.AzeroStepsArt end

function S.On()
    local art = Art()
    if not art or not ns:HasAssets(art.asset or 0) then return false end
    if G:Data().steps == false then return false end
    return ns.AzeroSound == nil or ns.AzeroSound:SfxOn()
end

-- What each theme's own floor (Game.lua THEMES grass1 / grass2) sounds of: one of the StepsArt grounds. Every
-- theme needs an entry (test_azeromon_zones.py checks; dev/docs/AZEROMON_NEW_ZONE.md).
S.THEME_GROUND = {
    elwynn = "grass", westfall = "grass", duskwood = "grass", jungle = "grass", redridge = "grass",
    steppes = "road", gorge = "road",                      -- the Burning Steppes' ash, the Searing Gorge's earth
    mine = "cave", blackrock = "cave", arena = "sand", hall = "hall",
}
-- Tiles of their own, whatever the theme: tile name prefix -> ground
local PREFIX = { { "sand", "sand" }, { "floor", "floor" }, { "rug", "rug" }, { "deck", "dock" } }
local OUTDOOR_WET = { grass = true, tall = true, road = true, sand = true, dock = true }

-- The ground at tile (x, y) of compiled map m: a StepsArt set name without its _wet / _in, or nil (none there).
function S.Ground(m, x, y)
    if not (m and x and y) then return nil end
    local k = m.key(floor(x + 0.5), floor(y + 0.5))
    if m.shallow and m.shallow[k] then return "shallows" end
    if m.water[k] then return nil end
    if m.tall[k] then return "tall" end
    if m.railOver and m.railOver[k] then return "cave" end
    local base = m.base[k]
    if type(base) ~= "string" then return nil end
    local th = m.theme or {}
    if th.path and base:sub(1, #th.path) == th.path then
        return (th.path == "carpet_") and "rug" or "road"
    end
    if m.def.theme and (base == th.grass1 or base == th.grass2) then
        return S.THEME_GROUND[m.def.theme] or (m.def.outdoor and "grass" or "floor")
    end
    for _, p in ipairs(PREFIX) do
        if base:sub(1, #p[1]) == p[1] then return p[2] end
    end
    if base == "void" or base == "wall" then return nil end
    if m.def.outdoor then return "grass" end
    return "floor"
end

-- The set a step plays: its ground, wet in the rain outdoors, "shallows_in" stepping into the shallows.
function S.SetFor(m, x, y, fromX, fromY, raining)
    local ground = S.Ground(m, x, y)
    if not ground then return nil end
    if ground == "shallows" and fromX and S.Ground(m, fromX, fromY) ~= "shallows" then return "shallows_in" end
    if raining and m.def.outdoor and OUTDOOR_WET[ground] then return ground .. "_wet" end
    return ground
end

-- A mix of `set` (1..n), never one of the last two played from it.
local recent, free = {}, {}
function S.Pick(set, n)
    local r = recent[set]
    if not r then r = {} recent[set] = r end
    local c = 0
    for i = 1, n do
        if not ((n > 1 and i == r[1]) or (n > 2 and i == r[2])) then c = c + 1 free[c] = i end
    end
    local i = free[math.random(c)]
    r[2], r[1] = r[1], i
    return i
end

-- The foot lands on tile (x, y), coming from (fromX, fromY).
function S.Footfall(x, y, fromX, fromY)
    if not S.On() or not PlaySoundFile then return end
    local set = S.SetFor(G.map, x, y, fromX, fromY, G.raining)
    local n = set and Art().sets[set]
    if not n or n < 1 then return end
    local i = S.Pick(set, n)
    local file = S.DIR .. set .. "_" .. i .. ".ogg"
    pcall(PlaySoundFile, file, "Master")
    if S.trace then S.trace[#S.trace + 1] = { set, i, file } end
end

S._Reset = function() recent = {} end
