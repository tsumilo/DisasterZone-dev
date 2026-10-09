if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Loot.lua", ...) then return end -- DisasterZone Games/Disastercraft/Loot.lua
-- Craft.Loot: what a kill gives - the experience (WoW's formula, shared in a party), the quest credit, the money and
-- the items from the creature's real loot table (cMaNGOS rules: independent rows roll their chance; a group gives at
-- most one of its items - the explicit chances first, else one of the "equal chance" rows; a reference is a nested
-- table rolled `maxcount` times; a negative chance is a quest drop, only for someone who still needs it).
-- The corpse sparkles while there is loot on it; the loot window takes the items (and the money) into your bags.
local addonName, ns = ...

local Craft = ns.Craft
local D = Craft.D
local Combat = Craft.Combat
local Items = Craft.Items
local Loot = {}
Craft.Loot = Loot

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local Chance, Roll = Craft.Chance, Craft.Roll

---------------------------------------------------------------------------
-- Rolling a loot table
---------------------------------------------------------------------------

-- needsQuest(item) -> true when someone may get this quest drop
local function RollTable(rows, out, needsQuest, depth)
    if not rows or depth > 4 then return end
    local groups = {}
    for _, r in ipairs(rows) do
        local item, chance, group, mn, mx = r[1], r[2], r[3], r[4], r[5]
        if group and group > 0 then
            local g = groups[group]
            if not g then g = { explicit = {}, equal = {} } groups[group] = g end
            if chance ~= 0 then g.explicit[#g.explicit + 1] = r else g.equal[#g.equal + 1] = r end
        else
            local quest = chance < 0
            local pct = abs(chance)
            if item == 0 then
                -- a reference: roll it, then roll its table maxcount times
                if Chance(pct) then
                    for _ = 1, max(1, mx or 1) do RollTable(D.lootRefs[mn], out, needsQuest, depth + 1) end
                end
            elseif (not quest or (needsQuest and needsQuest(item))) and Chance(pct) then
                out[#out + 1] = { id = item, n = Roll(max(1, mn or 1), max(mn or 1, mx or 1)), quest = quest or nil }
            end
        end
    end
    for _, g in pairs(groups) do
        local got = false
        local r = Craft.rng() * 100
        for _, row in ipairs(g.explicit) do
            local pct = abs(row[2])
            local quest = row[2] < 0
            if r < pct then
                if row[1] == 0 then
                    for _ = 1, max(1, row[5] or 1) do RollTable(D.lootRefs[row[4]], out, needsQuest, depth + 1) end
                    got = true
                elseif not quest or (needsQuest and needsQuest(row[1])) then
                    out[#out + 1] = { id = row[1], n = Roll(max(1, row[4] or 1), max(row[4] or 1, row[5] or 1)) }
                    got = true
                end
                break
            end
            r = r - pct
        end
        if not got and #g.equal > 0 then
            -- the "equal chance" rows share what is left of the group's hundred
            local total = 0
            for _, row in ipairs(g.explicit) do total = total + abs(row[2]) end
            if Craft.rng() * 100 < (100 - total) or total == 0 then
                local row = g.equal[Roll(1, #g.equal)]
                if row[1] == 0 then
                    RollTable(D.lootRefs[row[4]], out, needsQuest, depth + 1)
                elseif D.items[row[1]] then
                    out[#out + 1] = { id = row[1], n = Roll(max(1, row[4] or 1), max(row[4] or 1, row[5] or 1)) }
                end
            end
        end
    end
end
Loot.RollTable = RollTable

-- the loot of a dead creature: { money = c, items = { { id, n, quest } } }
function Loot.Generate(u, needsQuest)
    local cr = u.cr or {}
    local loot = { money = 0, items = {} }
    if cr.gold and cr.gold[2] and cr.gold[2] > 0 then loot.money = Roll(cr.gold[1] or 0, cr.gold[2]) end
    local rows = D.loot[u.entry]
    if rows then RollTable(rows, loot.items, needsQuest, 0) end
    -- (stacks of the same item merge, like the loot window shows them)
    local merged, byId = {}, {}
    for _, it in ipairs(loot.items) do
        if D.items[it.id] then
            local m = byId[it.id]
            if m and (D.items[it.id].stack or 1) >= m.n + it.n then m.n = m.n + it.n
            else m = { id = it.id, n = it.n, quest = it.quest } byId[it.id] = m merged[#merged + 1] = m end
        end
    end
    loot.items = merged
    return loot
end

---------------------------------------------------------------------------
-- Kills: who tagged it, the experience, the quest credit, the loot
---------------------------------------------------------------------------

-- the first player to hurt a creature owns its kill (and their party)
Craft:On("damage", function(src, dst, amount, info)
    if dst and Combat.IsCreature(dst) and src and Combat.IsPlayer(src) and not dst.tapper then
        dst.tapper = src.guid
        dst.tapParty = Craft.Party and Craft.Party.IdOf and Craft.Party.IdOf(src) or nil
    end
end)

function Loot.Mine(u)
    local p = Craft.player
    if not p or not u.tapper then return false end
    if u.tapper == p.guid then return true end
    if Craft.Party and Craft.Party.InMyParty and Craft.Party.InMyParty(u.tapper) then return true end
    return false
end

-- the experience share for each party member near the kill (WoW: by level, with the group bonus)
function Loot.KillXP(u, members)
    local p = Craft.player
    local sum, maxLvl = 0, 0
    for _, m in ipairs(members) do sum = sum + m.level maxLvl = max(maxLvl, m.level) end
    local n = #members
    local base = Craft.KillXP(maxLvl, u.level, u.elite, u.cr and u.cr.xpm)
    if base <= 0 then return 0 end
    local rate = Craft.GROUP_RATE[min(5, n)] or 1
    if n <= 1 then return Craft.KillXP(p.level, u.level, u.elite, u.cr and u.cr.xpm) * Craft.XP_RATE end
    return floor(base * rate * p.level / sum * Craft.XP_RATE)
end

Craft:On("death", function(u, killer)
    if not Combat.IsCreature(u) or not u.rec then return end
    if not Loot.Mine(u) then return end
    local p = Craft.player
    if not p then return end
    -- party members near the kill share it
    local members = Craft.Party and Craft.Party.MembersNear and Craft.Party.MembersNear(u, 74) or { p }
    local mine = false
    for _, m in ipairs(members) do if m == p then mine = true end end
    if not mine and #members > 0 and not (p.ghost or p.dead) then members[#members + 1] = p mine = true end
    if mine and not p.dead then
        local xp = Loot.KillXP(u, members)
        if xp > 0 then
            Craft:GiveXP(xp, string.format("%s dies, you gain %d experience.", u.name, xp))
        end
        if Craft.Quests then Craft.Quests.OnKill(u) end
    end
    -- the loot: rolled by whoever owns the creature (alone: you); a party's leader shares it out (Party.lua)
    if Combat.Owns(u) and (not Craft.Party or not Craft.Party.HandlesLoot or not Craft.Party.HandlesLoot(u)) then
        u.rec.loot = Loot.Generate(u, function(item) return Craft.Quests and Craft.Quests.NeedsItem(item) end)
        if #u.rec.loot.items == 0 and u.rec.loot.money == 0 then u.rec.loot = nil end
        if u.rec.loot then u.rec.corpseUntil = Craft.Now() + 300 end
    end
end)

function Loot.CanLoot(u)
    local l = u.rec and u.rec.loot
    if not l then return false end
    if not Loot.Mine(u) then return false end
    if l.money > 0 then return true end
    for _, it in ipairs(l.items) do
        if not it.taken and (not it.owner or it.owner == (Craft.player and Craft.player.guid)) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- The loot window
---------------------------------------------------------------------------

Loot.open = nil                       -- the corpse whose loot window is up

function Loot.Open(u, auto)
    if not Loot.CanLoot(u) then
        Craft:Error(u.rec and u.rec.loot and "You don't have permission to loot that corpse." or "There is nothing to loot.")
        return false
    end
    Loot.open = u
    if auto then
        Loot.TakeAll()
        return true
    end
    Craft:Emit("loot", u)
    return true
end

function Loot.Items()
    local u = Loot.open
    return u and u.rec and u.rec.loot
end

function Loot.Close()
    local u = Loot.open
    Loot.open = nil
    if u then
        Craft:Emit("lootclose", u)
        local l = u.rec and u.rec.loot
        if l and not Loot.CanLoot(u) then
            u.rec.loot = nil
            u.rec.corpseUntil = math.min(u.rec.corpseUntil or 0, Craft.Now() + 30)
        end
    end
end

function Loot.TakeMoney()
    local l = Loot.Items()
    if not l or l.money <= 0 then return end
    local m = l.money
    l.money = 0
    if Craft.Party and Craft.Party.SplitMoney and Craft.Party.SplitMoney(Loot.open, m) then
        -- (shared out among the party)
    else
        Craft:AddMoney(m, "loot")
    end
    Craft:Emit("lootupdate")
end

function Loot.Take(i)
    local l = Loot.Items()
    local it = l and l.items[i]
    if not it or it.taken then return false end
    if it.owner and it.owner ~= Craft.player.guid then Craft:Error("You can't loot that item.") return false end
    if it.rolling then Craft:Error("That item is being rolled for.") return false end
    if Craft.Party and Craft.Party.TakeLoot and Craft.Party.TakeLoot(Loot.open, i, it) then
        Craft:Emit("lootupdate")
        return true
    end
    local left = Items.Add(it.id, it.n, "loot")
    if left >= it.n then return false end
    if left > 0 then it.n = left return false end
    it.taken = true
    Craft:Emit("lootupdate")
    if not Loot.CanLoot(Loot.open) then Loot.Close() end
    return true
end

function Loot.TakeAll()
    local l = Loot.Items()
    if not l then return end
    Loot.TakeMoney()
    for i = 1, #l.items do
        if Loot.open then Loot.Take(i) end
    end
    if Loot.open and not Loot.CanLoot(Loot.open) then Loot.Close() end
end

function Loot.OpenObject(o)
    Craft:Error("It's locked.")
end

-- walking away closes the loot window
Craft:On("teleport", function() if Loot.open then Loot.Close() end end)
