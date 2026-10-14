if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Illidan/Game.lua", ...) then return end -- DisasterZone Games/Illidan/Game.lua
-- ns.BoIGame: The Binding of Illidan in the Games hub: its entry, your saved record and new runs.
-- Saved (Games:GetData("illidan")): runs, wins, best (deepest floor), fastest (s, a win), kills, items (item key ->
-- true, every item you have picked up once), last (the last run's summary, E.Summary).
local _, ns = ...

local D, E = ns.BoIData, ns.BoI
local G = ns:NewModule("BoIGame")
ns.BoIGame = G

local GAME_ID = D.GAME_ID

local function Data()
    local d = ns.Games:GetData(GAME_ID)
    d.runs, d.wins, d.best, d.kills = d.runs or 0, d.wins or 0, d.best or 0, d.kills or 0
    if type(d.items) ~= "table" then d.items = {} end
    return d
end
G.Data = Data

-- daily: today's dungeon (ns.BoIBoard: the same for the whole guild, your first try counts); else a random one
function G:NewRun(class, daily)
    local d = Data()
    d.runs = d.runs + 1
    local run
    if daily and ns.BoIBoard then
        run = ns.BoIBoard:NewDailyRun(class)
    else
        local seed = (time and time() or 0) * 7 + d.runs * 131 + math.random(1, 100000)
        run = E.New({ class = class, seed = seed % 2000000000 })
    end
    run.onEnd = function(r) G:Finished(r) end   -- (the engine calls it once, on the death card or the win)
    return run
end

-- a run ended (died or won): the record
function G:Finished(run)
    local d = Data()
    local s = E.Summary(run)
    run.newBest = d.runs > 1 and s.floor > d.best
    d.best = math.max(d.best, s.floor)
    d.kills = d.kills + s.kills
    if s.won then
        d.wins = d.wins + 1
        if not d.fastest or s.time < d.fastest then d.fastest = s.time end
    end
    for _, k in ipairs(run.items) do d.items[k] = true end
    if run.active then d.items[run.active] = true end
    d.last = s
    if ns.BoIBoard then ns.BoIBoard:Finished(run) end
    ns:Fire("GAMES_UPDATED")
end

local function Clock(s) return string.format("%d:%02d", math.floor(s / 60), s % 60) end
G.Clock = Clock

-- the title screen's line about your record
function G:BestLine()
    local d = ns.Games:PeekData(GAME_ID)
    if not d.runs or d.runs == 0 then return "" end
    if (d.wins or 0) > 0 then
        return string.format("%d %s  \194\183  fastest %s  \194\183  %d runs", d.wins, d.wins == 1 and "win" or "wins", Clock(d.fastest or 0), d.runs)
    end
    return string.format("Deepest: floor %d, %s  \194\183  %d runs", d.best or 1, (D.FLOORS[d.best or 1] or D.FLOORS[1]).name, d.runs)
end

function G:ItemCount()
    local n, all = 0, 0
    for k in pairs(D.ITEMS) do
        all = all + 1
        if ns.Games:PeekData(GAME_ID).items and ns.Games:PeekData(GAME_ID).items[k] then n = n + 1 end
    end
    return n, all
end

function G:OnInit()
    ns.Games:Register(GAME_ID, {
        name = "The Binding of Illidan",
        desc = "A roguelike through the Black Temple: one room at a time, your class's bolts as tears, items that stack, and raid bosses that fight with their raid mechanics. A new dungeon every run.",
        tagline = "Five floors of the Black Temple, raid bosses that fight like the raid. New dungeon every run.",
        icon = "Interface\\Icons\\Spell_Shadow_Metamorphosis",
        order = 30,
        create = function(parent) return ns.BoIUI and ns.BoIUI:CreatePanel(parent) end,
        status = function()
            local d = ns.Games:PeekData(GAME_ID)
            if (d.wins or 0) > 0 then return string.format("|cffa6f04a%d %s|r", d.wins, d.wins == 1 and "win" or "wins") end
            if (d.best or 0) > 0 then return string.format("|cff888888Deepest: floor %d|r", d.best) end
            return "|cff888888Not played yet|r"
        end,
    })
    ns:RegisterSlash("illidan", function() ns.Games:Open(GAME_ID) end, "illidan - The Binding of Illidan")
end
