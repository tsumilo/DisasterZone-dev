if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/Arena.lua", ...) then return end -- DisasterZone_Azeromon/Arena.lua
-- ns.AzeroArena: the Gurubashi Arena (Thor at Sentinel Hill flies you there). Short John Mithril runs a gauntlet:
-- challengers one after another, stronger each time; no healing between fights (items are fine). After each win,
-- fight on or leave with the prize so far; every REWARD_EVERY wins adds an item. The best streak is kept
-- (DisasterZoneDB.games.azeromon.arenaBest) and shared with the guild (GuildBoard: AZS ar, the "Arena streak" board).
-- A lost fight only ends the run: the arena's healers patch your beasts up, no blackout.
local addonName, ns = ...

local A = ns:NewModule("AzeroArena")
local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon

A.FEE = 100                    -- copper to enter a run
A.PRIZE = 6                    -- copper per level of the challenger's last beast, times the streak so far
A.REWARD_EVERY = 5
A.REWARDS = { "superpotion", "greatnet", "rejuv", "flasktitans", "illusiondust" }     -- 5, 10, 15, 20, 25+ wins

-- Stranglethorn's regulars, in no particular order.
A.CHALLENGERS = {
    "Bloodsail Buccaneer", "Venture Co. Enforcer", "Kurzen Mercenary", "Skullsplitter Hunter", "Booty Bay Bruiser",
    "Mosh'Ogg Brute", "Stranglethorn Tigress Tamer", "Nesingwary's Tracker", "Gurubashi Berserker", "Steamwheedle Duelist",
}

-- Beasts that fight in the arena: everything but bosses and rares.
local pool
local function Pool()
    if pool then return pool end
    pool = {}
    for _, id in ipairs(D.dexOrder) do
        local sp = D.species[id]
        if not sp.boss and not sp.rare and not sp.legendary then pool[#pool + 1] = id end
    end
    return pool
end

-- Challenger `n` of a run: two beasts at first, three from the 4th; levels climb with the streak from just under
-- the player's strongest, and a beast takes its evolved form where the level allows.
function A.Challenger(n, rng)
    rng = rng or G.rng
    local best = 1
    for _, m in ipairs(G.save.party) do best = math.max(best, m.lvl) end
    local size = n >= 4 and 3 or 2
    local lvl = math.max(5, math.min(D.MAX_LEVEL, best - 3 + math.floor(n / 2)))
    local team = {}
    local list = Pool()
    for i = 1, size do
        local sp = list[rng(1, #list)]
        local l = math.min(D.MAX_LEVEL, lvl + (i == size and 1 or 0))
        for _ = 1, 3 do
            local evo = D.species[sp].evolve
            if evo and evo.level and l >= evo.level then sp = evo.into else break end
        end
        team[i] = M.New(sp, l, rng)
    end
    return A.CHALLENGERS[rng(1, #A.CHALLENGERS)], team
end

function A.Best() return tonumber(G:Data().arenaBest) or 0 end

-- Short John Mithril's script.
function A:Run(g)
    local who = "Short John Mithril: "
    g:Say(who .. "Welcome to the Gurubashi Arena! Beast against beast, and Stranglethorn's toughest watching.")
    if A.Best() > 0 then g:Say(string.format("%sYour best streak here is %d. Think you can beat it?", who, A.Best())) end
    if not M.FirstUsable(g.save.party) then
        g:Say(who .. "Your beasts can't stand up! Rest them first.")
        return
    end
    if not g:YesNo(string.format("%sA run costs %s. No healing between fights. Step in?", who, D.Money(A.FEE))) then
        g:Say(who .. "The crowd will be here when you're ready.")
        return
    end
    if g.save.money < A.FEE then
        g:Say(who .. "Come back with " .. D.Money(A.FEE) .. ", friend.")
        return
    end
    g.save.money = g.save.money - A.FEE
    local streak = 0
    while true do
        local name, team = A.Challenger(streak + 1)
        D.trainers.arena = { name = name, class = "arena", prize = A.PRIZE * (streak + 1),
                             intro = "", lose = "The crowd roars for you!" }
        g:Say(string.format("%sFight %d! %s steps into the arena!", who, streak + 1, name))
        local result = g:RunBattle(team, "arena", { noBlackout = true })
        if result ~= "win" then break end
        streak = streak + 1
        if streak % A.REWARD_EVERY == 0 then
            local item = A.REWARDS[math.min(#A.REWARDS, streak / A.REWARD_EVERY)]
            g:Give(item, 1)
        end
        if streak > A.Best() then G:Data().arenaBest = streak end
        G:Emit("arena", { streak = streak })
        if not M.FirstUsable(g.save.party) then break end
        local pick = g:Choose(string.format("%s%d in a row! Fight on, or leave while you're ahead?", who, streak),
            { "Next fight", "Leave" })
        if pick ~= 1 then break end
    end
    g:HealParty()
    if streak == 0 then
        g:Say(who .. "Down in the first round! The healers have patched your beasts up. Try again!")
    else
        g:Say(string.format("%sA streak of %d! %s", who, streak,
            streak >= A.Best() and "The best you've done here!" or ("Your best is " .. A.Best() .. ".")))
        g:Say(who .. "The healers have patched your beasts up.")
    end
    if ns.AzeroGuild and ns.AzeroGuild.MarkDirty then ns.AzeroGuild:MarkDirty() end
end
