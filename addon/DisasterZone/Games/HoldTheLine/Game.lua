if DisasterZoneBoot and DisasterZoneBoot.Run("Games/HoldTheLine/Game.lua", ...) then return end -- DisasterZone Games/HoldTheLine/Game.lua
-- ns.HTLGame: Hold the Line in the Games hub - its entry, /dz htl, and your record.
-- Saved (Games:GetData("holdtheline"), account wide): runs, wins, best (longest survived, s), kills, rep (Argent Dawn),
-- last ({ t, kills, level, won, cls }), bank (gold carried home from runs) and talents ({ [id] = rank }, bought with it).
local _, ns = ...

local D = ns.HTLData
local G = ns:NewModule("HTLGame")
ns.HTLGame = G

local GAME_ID = D.GAME_ID

local function Data()
    local d = ns.Games:GetData(GAME_ID)
    d.runs, d.wins, d.best, d.kills, d.rep = d.runs or 0, d.wins or 0, d.best or 0, d.kills or 0, d.rep or 0
    if d.bank == nil then d.bank = math.floor(d.kills / 10) end     -- (runs played before talents existed count a little)
    d.talents = type(d.talents) == "table" and d.talents or {}
    return d
end
G.Data = Data

function G:Started(run)
    local d = Data()
    d.runs = d.runs + 1
end

function G:Finished(run, won, rep)
    if run.recorded then return end
    run.recorded = true
    local d = Data()
    d.best = math.max(d.best, math.floor(run.t))
    d.kills = d.kills + run.kills
    d.rep = d.rep + (rep or 0)
    if won then d.wins = d.wins + 1 end
    d.bank = d.bank + (run.gold or 0)
    d.last = { t = math.floor(run.t), kills = run.kills, level = run.level, won = won and true or false, cls = run.cls }
    if ns.HTLSocial then ns.HTLSocial:RunEnded(run, won, run.gold or 0) end
    ns:Fire("GAMES_UPDATED")
end

-- talents: points spent in a tree, whether a rank can be bought (and why not), buying, a full refund
function G:Spent(tree)
    local d, n = Data(), 0
    for id, r in pairs(d.talents) do local t = D.TALENT[id] if t and (not tree or t.tree == tree) then n = n + r end end
    return n
end
function G:Rank(id) return Data().talents[id] or 0 end
function G:Cost(id) local t = D.TALENT[id] return t and D.TIER_COST[t.tier] or 0 end
function G:CanBuy(id)
    local t, d = D.TALENT[id], Data()
    if not t then return false, "unknown" end
    local r = d.talents[id] or 0
    if r >= t.max then return false, "max" end
    local need = (t.tier - 1) * D.TIER_GATE
    if self:Spent(t.tree) < need then return false, "locked", need end
    if d.bank < self:Cost(id) then return false, "gold" end
    return true
end
function G:Buy(id)
    if not self:CanBuy(id) then return false end
    local d = Data()
    d.bank = d.bank - self:Cost(id)
    d.talents[id] = (d.talents[id] or 0) + 1
    if ns.HTLSocial then ns.HTLSocial:CheckProfile() end
    ns:Fire("GAMES_UPDATED")
    return true
end
function G:Reset()
    local d = Data()
    for id, r in pairs(d.talents) do d.bank = d.bank + r * self:Cost(id) end
    wipe(d.talents)
    ns:Fire("GAMES_UPDATED")
end
-- a run's copy (the run reads it, never the saved table)
function G:RunTalents()
    local out = {}
    for id, r in pairs(Data().talents) do if D.TALENT[id] and r > 0 then out[id] = math.min(r, D.TALENT[id].max) end end
    return out
end

local function Clock(s) return string.format("%d:%02d", math.floor(s / 60), s % 60) end

function G:OnInit()
    if not ns:HasAssets(D.ASSETS) then return end      -- its sprites, effects and UI pieces came with art pack 15
    ns.Games:Register(GAME_ID, {
        name = "Hold the Line",
        desc = "Fifteen minutes against the Scourge of the Plaguelands: your class's spells cast themselves, level-ups deal blessings, coffers hold legendaries, and at the end the Pale Rider comes.",
        tagline = "Fifteen minutes. One class. The whole Scourge.",
        icon = "Interface\\Icons\\Spell_Holy_InnerFire",
        order = 40,
        create = function(parent) return ns.HTLUI and ns.HTLUI:CreatePanel(parent) end,
        status = function()
            local d = ns.Games:PeekData(GAME_ID)
            if (d.wins or 0) > 0 then return string.format("|cffa6f04a%d %s|r", d.wins, d.wins == 1 and "win" or "wins") end
            if (d.best or 0) > 0 then return string.format("|cff888888Best: %s|r", Clock(d.best)) end
            return "|cff888888Not played yet|r"
        end,
    })
    ns:RegisterSlash("htl", function() ns.Games:Open(GAME_ID) end, "htl - Hold the Line")
end
