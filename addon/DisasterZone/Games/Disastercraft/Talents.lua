if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Talents.lua", ...) then return end -- DisasterZone Games/Disastercraft/Talents.lua
-- Craft.Talents: WoW's talent trees (Talent.dbc / TalentTab.dbc, in Data.lua) as in TBC: a point every level from
-- 10, five points spent in a tree open its next tier, a talent's prerequisite first; each rank is a spell - a
-- passive one puts its aura on the hero (Combat's spell modifiers and stat auras do the rest), an active one goes
-- into the spellbook. A class trainer unlearns them all for a fee (1 g, then 5 g more each time, 50 g at most).
local addonName, ns = ...

local Craft = ns.Craft
local D = Craft.D
local Combat = Craft.Combat

local Talents = {}
Craft.Talents = Talents

local max, min = math.max, math.min
local FIRST_LEVEL, PER_TIER = 10, 5

-- talent id -> { tree index, row }, spell id -> talent id (built once)
local byTalent, bySpell

local function Index()
    if byTalent then return end
    byTalent, bySpell = {}, {}
    for _, trees in pairs(D.talents or {}) do
        for ti, tree in ipairs(trees) do
            for _, t in ipairs(tree.talents) do
                byTalent[t.id] = { tree = ti, row = t }
                for _, sp in ipairs(t.ranks) do bySpell[sp] = t.id end
            end
        end
    end
end

local function C() return Craft.char end

function Talents.Trees(cls) return (D.talents and D.talents[cls]) or {} end
function Talents.Get(id) Index() return byTalent[id] and byTalent[id].row, byTalent[id] and byTalent[id].tree end
function Talents.OfSpell(spellId) Index() return bySpell[spellId] end
function Talents.Rank(c, id) c = c or C() return (c and c.talents and c.talents[id]) or 0 end

-- points spent in tree ti (all trees when nil)
function Talents.Spent(c, ti)
    c = c or C()
    Index()
    local n = 0
    for id, r in pairs(c and c.talents or {}) do
        local x = byTalent[id]
        if x and (ti == nil or x.tree == ti) then n = n + r end
    end
    return n
end

-- -> unspent, spent, earned
function Talents.Points(c)
    c = c or C()
    local earned = max(0, (c and c.level or 1) - FIRST_LEVEL + 1)
    local spent = Talents.Spent(c)
    return max(0, earned - spent), spent, earned
end

-- can c put a point into talent id? -> ok, why ("points" | "max" | "tier" | "prereq")
function Talents.CanLearn(c, id)
    c = c or C()
    local t, ti = Talents.Get(id)
    if not t then return false, "unknown" end
    local rank = Talents.Rank(c, id)
    if rank >= #t.ranks then return false, "max" end
    if Talents.Points(c) <= 0 then return false, "points" end
    if Talents.Spent(c, ti) < t.tier * PER_TIER then return false, "tier" end
    for _, p in ipairs(t.pre or {}) do
        if Talents.Rank(c, p[1]) < p[2] then return false, "prereq" end
    end
    return true
end

local function ApplyRank(u, spellId, prevId)
    if not u then return end
    if prevId then
        local a = Combat.FindAura(u, prevId)
        if a then Combat.RemoveAura(u, a, "talent") end
    end
    local sp = D.spells[spellId]
    if sp and Combat.IsPassive(sp) then Combat.ApplyAura(u, u, spellId, true) end
    Combat.Recalc(u)
end

-- a point into talent id (the hero's)
function Talents.Learn(id)
    local c = C()
    local ok, why = Talents.CanLearn(c, id)
    if not ok then return false, why end
    local t = Talents.Get(id)
    c.talents = c.talents or {}
    local rank = (c.talents[id] or 0) + 1
    local prev = rank > 1 and t.ranks[rank - 1] or nil
    local spellId = t.ranks[rank]
    c.talents[id] = rank
    if prev then c.spells[prev] = nil end
    c.spells[spellId] = true
    ApplyRank(Craft.player, spellId, prev)
    Craft:Emit("talent", id, rank)
    return true
end

-- the hero's talents on its unit (logging in, coming back to life)
function Talents.ApplyAll(u)
    local c = u and u.char
    if not (c and c.talents) then return end
    for id, r in pairs(c.talents) do
        local t = Talents.Get(id)
        local spellId = t and t.ranks[r]
        local sp = spellId and D.spells[spellId]
        if sp and Combat.IsPassive(sp) and not Combat.FindAura(u, spellId) then Combat.ApplyAura(u, u, spellId, true) end
    end
    Combat.Recalc(u)
end

-- a passive talent rank (kept out of the spellbook, like WoW)
function Talents.IsPassiveTalent(spellId)
    local sp = D.spells[spellId]
    return Talents.OfSpell(spellId) ~= nil and sp ~= nil and Combat.IsPassive(sp)
end

-- unlearning at a class trainer: 1 g the first time, 5 g more each time after, 50 g at most
function Talents.ResetCost(c)
    c = c or C()
    local n = c and c.talentResets or 0
    return min(500000, n == 0 and 10000 or n * 50000)
end

function Talents.Reset()
    local c = C()
    if Talents.Spent(c) == 0 then return false end
    local cost = Talents.ResetCost(c)
    if Craft:Money() < cost then Craft:Error("You don't have enough money.") return false end
    Craft:AddMoney(-cost, "silent")
    local u = Craft.player
    for id, r in pairs(c.talents or {}) do
        local t = Talents.Get(id)
        local spellId = t and t.ranks[r]
        if spellId then
            c.spells[spellId] = nil
            local a = u and Combat.FindAura(u, spellId)
            if a then Combat.RemoveAura(u, a, "talent") end
        end
    end
    c.talents = {}
    c.talentResets = (c.talentResets or 0) + 1
    if u then Combat.Recalc(u) end
    Craft:Msg("Your talents have been reset.", "system")
    Craft:Emit("talent")
    return true
end

-- a new level may bring a point
Craft:On("level", function() Craft:Emit("talent") end)
