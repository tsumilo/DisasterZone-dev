if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_HoldTheLine/Game.lua", ...) then return end -- DisasterZone_HoldTheLine/Game.lua
-- ns.HTLGame: Hold the Line in the Games hub - its entry, /dz htl, and your record.
-- Saved (Games:GetData("holdtheline"), account wide): runs, wins, best (longest survived, s), kills, rep (Argent Dawn),
-- last ({ t, kills, level, won, cls }), bank (gold carried home from runs) and talents ({ [id] = rank }, bought with it).
-- Naxxramas: naxx = { cleared = { [stage] = true }, best = { [stage] = s }, kills = { [cls] = { [boss] = n } } },
-- t3 = { [cls] = { [slot] = true } } (Desecrated tokens), frozen (Frozen Runes), frostRes (rank 0..5), ktSlain,
-- relicsSeen = { [id] = true }, t3Look = false when the set is hidden.
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
    d.naxx = type(d.naxx) == "table" and d.naxx or {}
    for _, k in ipairs({ "cleared", "best", "kills" }) do if type(d.naxx[k]) ~= "table" then d.naxx[k] = {} end end
    d.t3 = type(d.t3) == "table" and d.t3 or {}
    d.relicsSeen = type(d.relicsSeen) == "table" and d.relicsSeen or {}
    d.frozen, d.frostRes = d.frozen or 0, d.frostRes or 0
    return d
end
G.Data = Data

---------------------------------------------------------------------------
-- Naxxramas: open after a first win in the Plaguelands; the lair after the four masters
---------------------------------------------------------------------------
function G:NaxxReady() return ns:HasAssets(D.NAXX_ASSETS or 99) and D.STAGES ~= nil end
function G:NaxxOpen() local d = Data() return self:NaxxReady() and ((d.wins or 0) > 0 or next(d.naxx.cleared) ~= nil) end
function G:Cleared(stage) return Data().naxx.cleared[stage] and true or false end
function G:LairOpen()
    local d = Data()
    for _, w in ipairs(D.WINGS or {}) do if not d.naxx.cleared[w] then return false end end
    return true
end
function G:StageOpen(stage)
    if stage == "epl" or not stage then return true end
    if not self:NaxxOpen() then return false end
    if stage == "frost" then return self:LairOpen() end
    return true
end
function G:Slain(boss, cls)
    local k = Data().naxx.kills
    if cls then return (k[cls] and k[cls][boss] or 0) > 0 end
    for _, t in pairs(k) do if (t[boss] or 0) > 0 then return true end end
    return false
end
-- Tier 3
function G:T3(cls) local d = Data() d.t3[cls] = type(d.t3[cls]) == "table" and d.t3[cls] or {} return d.t3[cls] end
function G:T3Count(cls) local n = 0 for _ in pairs(self:T3(cls)) do n = n + 1 end return n end
function G:T3Look(cls) return self:T3Count(cls) >= #D.T3_SLOTS and Data().t3Look ~= false end
function G:ToggleT3Look() local d = Data() d.t3Look = d.t3Look == false and true or false ns:Fire("GAMES_UPDATED") end
-- Frost Resistance (Craftsman Wilhelm): the next rank's price, whether you can pay it, buying it
function G:FrostNext() local d = Data() return D.FROST_RES[(d.frostRes or 0) + 1] end
function G:CanBuyFrost()
    local d, nxt = Data(), self:FrostNext()
    if not nxt then return false, "max" end
    if (d.frozen or 0) < nxt.runes then return false, "runes" end
    if (d.bank or 0) < nxt.gold then return false, "gold" end
    return true
end
function G:BuyFrost()
    if not self:CanBuyFrost() then return false end
    local d, nxt = Data(), self:FrostNext()
    d.frozen, d.bank, d.frostRes = d.frozen - nxt.runes, d.bank - nxt.gold, (d.frostRes or 0) + 1
    if ns.HTLSocial then ns.HTLSocial:CheckProfile() end
    ns:Fire("GAMES_UPDATED")
    return true
end
-- what a run starts with from the necropolis (E.New opts)
function G:RunNaxx(cls)
    local d = Data()
    return { frostRes = d.frostRes or 0, t3n = self:T3Count(cls), ktSlain = d.ktSlain and true or false, t3Look = self:T3Look(cls) }
end
-- a run's Desecrated tokens: a master's first fall to a class always drops one, after that one in four; Gluth's is
-- any missing piece. -> { slot ids awarded }
local function AwardTokens(run, d)
    local out = {}
    local mine = G:T3(run.cls)
    d.naxx.kills[run.cls] = d.naxx.kills[run.cls] or {}
    local kills = d.naxx.kills[run.cls]
    for _, tk in ipairs(run.tokens or {}) do
        local first = (kills[tk.boss] or 0) == 0
        kills[tk.boss] = (kills[tk.boss] or 0) + 1
        if first or math.random() < (D.T3_DROP or 0.25) then
            local slot = tk.slot
            if slot == "any" then
                local miss = {}
                for _, s in ipairs(D.T3_SLOTS) do if not mine[s.id] and s.id ~= "ring" and s.id ~= "head" and s.id ~= "chest" then miss[#miss + 1] = s.id end end
                slot = #miss > 0 and miss[math.random(#miss)] or nil
            end
            if slot and not mine[slot] then mine[slot] = true out[#out + 1] = slot end
        end
    end
    return out
end

function G:Started(run)
    local d = Data()
    d.runs = d.runs + 1
end

function G:Finished(run, won, rep)
    if run.recorded then return end
    run.recorded = true
    local d = Data()
    if (run.stage or "epl") == "epl" then d.best = math.max(d.best, math.floor(run.t)) end
    d.kills = d.kills + run.kills
    d.rep = d.rep + (rep or 0)
    if won then d.wins = d.wins + 1 end
    d.bank = d.bank + (run.gold or 0)
    d.last = { t = math.floor(run.t), kills = run.kills, level = run.level, won = won and true or false, cls = run.cls, stage = run.stage }
    if run.stage and run.stage ~= "epl" then
        run.awarded = AwardTokens(run, d)
        d.frozen = (d.frozen or 0) + (run.frozen or 0)
        for id in pairs(run.relicSeen or {}) do d.relicsSeen[id] = true end
        if won then
            d.naxx.cleared[run.stage] = true
            local t = math.floor(run.t)
            if not d.naxx.best[run.stage] or t < d.naxx.best[run.stage] then d.naxx.best[run.stage] = t end
            if run.stage == "frost" then d.ktSlain = true end
        end
    end
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
