if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Materials.lua", ...) then return end -- DisasterZone: Core/Materials.lua
-- Crafting materials that drop (Nether Vortex from Serpentshrine and Tempest Keep trash, Heart of Darkness, ...): the
-- gear crafts that use one, who in the raid has such a craft on a BiS / off-spec list, who in the guild crafts it,
-- and how many of the material each of them already holds. The drop panel, the roll popup and the roll's suggestion
-- read this; nothing here records loot.
--
-- Holdings: my own count is live (GetItemCount, bank included). Everyone else's comes from their own client: when a
-- material drops that a craft on their lists uses, it sends MH { i = material, h = how many it holds, f = the craft
-- it is for } to the group, again when they pick another craft in the roll popup, and their roll's RR carries h / f
-- too (Roll). Without a report the count is estimated from the loot log: the material awarded to them, minus what
-- the crafts they have already made took. Reports live in memory only.
--
-- Ranking (the council's call, 2026-10-10): in the raid first, then whoever this drop completes a craft for, then
-- whoever is closest to one, then main-spec BiS before alt picks before off-spec lists.
local addonName, ns = ...

local Materials = ns:NewModule("Materials")

local Util = ns.Util
local floor, max, min = math.floor, math.max, math.min
local ipairs, pairs, type, tonumber, tostring = ipairs, pairs, type, tonumber, tostring
local tsort = table.sort

local MAX_HELD = 999
local REPORT_GAP = 5          -- seconds between two MH of the same material (a pick change sends at once)
local EMPTY = {}

local uses           -- [materialID] = { use, ... } (built on first use)
local reports = {}   -- [materialID] = { [key] = { n =, f =, at = } }
local picks = {}     -- [materialID] = the craft item I want it for (popup choice)
local lastSent = {}  -- [materialID] = GetTime() of my last MH

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

local function DemoOn()
    local Demo = ns.Demo
    return (Demo and Demo.IsEnabled and Demo:IsEnabled()) and true or false
end

local function IsMe(key)
    return Util.IsMe and Util.IsMe(key) or false
end

local function ValidCount(n)
    n = tonumber(n)
    if not n or n ~= floor(n) or n < 0 then return nil end
    return min(n, MAX_HELD)
end

-- The profession of a craft group of ns.Data.Crafted ("Blacksmithing"), as ns.Professions knows it ({ id, name,
-- icon }), or nil.
local function ProfessionOf(name)
    local Prof = ns.Professions
    for _, def in ipairs(Prof and Prof.GetProfessions and Prof:GetProfessions() or EMPTY) do
        if def.name == name then return def end
    end
    return nil
end

local function BuildUses()
    uses = {}
    local Atlas = ns.Atlas
    local crafted = ns.Data and ns.Data.Crafted
    if not (Atlas and Atlas.GetCraft and type(crafted) == "table") then return end
    for _, group in ipairs(crafted) do
        local prof = type(group) == "table" and ProfessionOf(group.name or group.key) or nil
        for _, e in ipairs(type(group) == "table" and group.items or EMPTY) do
            local spell, item = tonumber(e.spell), tonumber(e.id)
            local craft = spell and item and Atlas:GetCraft(-spell)
            if craft then
                for _, r in ipairs(craft.reagents or EMPTY) do
                    local id, count = tonumber(r.id), tonumber(r.count)
                    if id and count and count > 0 and id ~= item then
                        local list = uses[id]
                        if not list then
                            list = {}
                            uses[id] = list
                        end
                        list[#list + 1] = { item = item, spell = spell, count = count, prof = prof,
                                            profName = group.name or group.key, spec = e.spec, phase = e.phase }
                    end
                end
            end
        end
    end
    for _, list in pairs(uses) do
        tsort(list, function(a, b)
            if a.count ~= b.count then return a.count < b.count end
            return a.item < b.item
        end)
    end
end

local function UsesOf(id)
    if not uses then BuildUses() end
    return uses[tonumber(id) or 0]
end

local function UseFor(id, craftItem)
    craftItem = tonumber(craftItem)
    if not craftItem then return nil end
    for _, u in ipairs(UsesOf(id) or EMPTY) do
        if u.item == craftItem then return u end
    end
    return nil
end

---------------------------------------------------------------------------
-- Public API: what a material is for
---------------------------------------------------------------------------

-- Is itemID a crafting material of gear (and not gear or a tier token itself)?
function Materials:IsMaterial(itemID)
    itemID = tonumber(itemID)
    if not itemID or not UsesOf(itemID) then return false end
    local db = ns.ItemDB
    if db and db.IsToken and db:IsToken(itemID) then return false end
    local sids = db and db.GetSlotsForItem and db:GetSlotsForItem(itemID)
    if type(sids) == "table" and sids[1] then return false end
    return true
end

-- The gear crafts that use the material: { { item, spell, count, prof = { id, name, icon } | nil, profName, spec,
-- phase }, ... } (fewest needed first). Shared tables: don't change them.
function Materials:GetUses(itemID)
    return UsesOf(itemID) or EMPTY
end

function Materials:GetUse(itemID, craftItem)
    return UseFor(itemID, craftItem)
end

-- Who in the guild knows the craft: keys (sorted), from the Members profession sync.
function Materials:GetCrafters(use)
    local Prof = ns.Professions
    local r = type(use) == "table" and Prof and Prof.GetRecipe and Prof:GetRecipe(use.spell)
    local out = {}
    for _, key in ipairs(type(r) == "table" and r.crafters or EMPTY) do out[#out + 1] = key end
    tsort(out)
    return out
end

-- The crafter to show for a craft: forKey when they make it themselves, else someone in the raid, online, any.
-- Returns key, state ("self" / "raid" / "online" / "offline"), or nil when nobody in the guild is known to make it.
function Materials:PickCrafter(use, forKey)
    local list = self:GetCrafters(use)
    if #list == 0 then return nil end
    local Guild = ns.Guild
    local best, bestRank
    for _, key in ipairs(list) do
        local state, rank
        if key == forKey then
            state, rank = "self", 0
        elseif Util.IsInMyGroup(key) then
            state, rank = "raid", 1
        elseif IsMe(key) or (Guild and Guild.IsOnline and Guild:IsOnline(key)) then
            state, rank = "online", 2
        else
            state, rank = "offline", 3
        end
        if not bestRank or rank < bestRank then best, bestRank = { key, state }, rank end
    end
    return best[1], best[2]
end

---------------------------------------------------------------------------
-- Holdings
---------------------------------------------------------------------------

-- The material key holds: n, source ("live" mine, "report" from their client, "log" estimated from the loot log),
-- and the time of a report.
function Materials:GetHeld(key, itemID)
    itemID = tonumber(itemID)
    if type(key) ~= "string" or not itemID then return 0, "log" end
    if IsMe(key) and not DemoOn() then
        local n = GetItemCount and tonumber((GetItemCount(itemID, true))) or 0
        return n, "live"
    end
    local r = reports[itemID] and reports[itemID][key]
    if r then return r.n, "report", r.at end
    -- The loot log: awarded to them (not as disenchant / guild bank), minus what the crafts they made took.
    local n = 0
    local Ledger = ns.Ledger
    for _, e in ipairs(Ledger and Ledger.GetEntries and Ledger:GetEntries({ player = key }) or EMPTY) do
        if e.i == itemID and e.r ~= "de" and e.r ~= "bank" then n = n + 1 end
    end
    if n > 0 then
        local Store = ns.Store
        for _, u in ipairs(UsesOf(itemID) or EMPTY) do
            if Store and Store.IsObtainedBy and Store:IsObtainedBy(key, u.item) then n = n - u.count end
        end
    end
    return max(0, n), "log"
end

-- The craft key told us they want the material for (MH / RR f), or nil.
function Materials:GetReportedCraft(key, itemID)
    local r = reports[tonumber(itemID) or 0]
    r = r and r[key]
    return r and r.f or nil
end

-- A report from key's client (MH, or the h / f of their roll). Returns true when it was taken.
function Materials:OnReport(key, itemID, held, craftItem)
    key = Util.NormalizeName(key)
    itemID = tonumber(itemID)
    local n = ValidCount(held)
    if not key or not itemID or not n or not UsesOf(itemID) then return false end
    local f = UseFor(itemID, craftItem) and tonumber(craftItem) or nil
    local list = reports[itemID]
    if not list then
        list = {}
        reports[itemID] = list
    end
    local cur = list[key]
    if cur and cur.n == n and cur.f == f then
        cur.at = Now()
        return true
    end
    list[key] = { n = n, f = f, at = Now() }
    ns:Fire("MATERIALS_UPDATED", itemID, key)
    return true
end

---------------------------------------------------------------------------
-- Who wants it
---------------------------------------------------------------------------

local WHICH_RANK = { main = 1, alt = 2 }

-- Sort rank of a want (lower first): in the raid, completes a craft, fewest still missing, BiS before alt before OS.
local function Better(a, b)
    if (a.inRaid and true or false) ~= (b.inRaid and true or false) then return a.inRaid and true or false end
    if (a.completes and true or false) ~= (b.completes and true or false) then return a.completes and true or false end
    if a.left ~= b.left then return a.left < b.left end
    local ao, bo = a.os and 1 or 0, b.os and 1 or 0
    if ao ~= bo then return ao < bo end
    local aw, bw = WHICH_RANK[a.which] or 3, WHICH_RANK[b.which] or 3
    if aw ~= bw then return aw < bw end
    local an, bn = tonumber(a.wonTonight) or 0, tonumber(b.wonTonight) or 0
    if an ~= bn then return an < bn end
    return tostring(a.key) < tostring(b.key)
end
Materials.Better = Better

-- Everyone with a craft that uses itemID on a list (not made yet):
--   { groups = { { use, wanters = { want, ... } }, ... }  -- crafts somebody wants, best group first
--     others = { use, ... },                               -- crafts nobody wants
--     wants = { want, ... },                               -- one per player: the craft they want it for, best first
--     byKey = { [key] = want } }
-- A want is the Store:GetWanters entry of the craft plus: craft (item), need (per craft), held, heldSrc, left (still
-- missing after this one), completes (this one finishes it). A player who told us the craft they want it for (MH /
-- the popup) is only listed under that craft. opts: viewPhase.
function Materials:GetWants(itemID, opts)
    itemID = tonumber(itemID)
    local out = { groups = {}, others = {}, wants = {}, byKey = {} }
    local list = UsesOf(itemID)
    local Store = ns.Store
    if not list or not (Store and Store.GetWanters) then return out end
    opts = type(opts) == "table" and opts or EMPTY
    local held = {}
    local function HeldOf(key)
        local h = held[key]
        if not h then
            local n, src, at = self:GetHeld(key, itemID)
            h = { n = n, src = src, at = at }
            held[key] = h
        end
        return h
    end
    for _, use in ipairs(list) do
        local g = { use = use, wanters = {} }
        local seen = {}
        for _, w in ipairs(Store:GetWanters(use.item, { includeObtained = false, list = "both", viewPhase = opts.viewPhase })) do
            local key = type(w) == "table" and w.key
            local f = key and self:GetReportedCraft(key, itemID)
            if key and not seen[key] and (not f or f == use.item) then
                seen[key] = true
                local h = HeldOf(key)
                local want = {}
                for k, v in pairs(w) do want[k] = v end
                want.craft, want.need = use.item, use.count
                want.via = "craft"
                want.held, want.heldSrc, want.heldAt = h.n, h.src, h.at
                want.left = max(0, use.count - h.n - 1)
                want.completes = h.n + 1 >= use.count
                g.wanters[#g.wanters + 1] = want
                local cur = out.byKey[key]
                if not cur or Better(want, cur) then out.byKey[key] = want end
            end
        end
        if #g.wanters > 0 then
            tsort(g.wanters, Better)
            out.groups[#out.groups + 1] = g
        else
            out.others[#out.others + 1] = use
        end
    end
    tsort(out.groups, function(a, b)
        local x, y = a.wanters[1], b.wanters[1]
        if x.key ~= y.key or x.craft ~= y.craft then return Better(x, y) end
        return a.use.item < b.use.item
    end)
    for _, want in pairs(out.byKey) do out.wants[#out.wants + 1] = want end
    tsort(out.wants, Better)
    return out
end

---------------------------------------------------------------------------
-- My own crafts (the roll popup, the toast, MH)
---------------------------------------------------------------------------

-- The crafts using itemID that are on my lists and not made yet, best first: { { use, match (BiS:MatchItem entry),
-- held, left, completes }, ... }. includeOS: off-spec lists too (default true).
function Materials:GetOwnWants(itemID, includeOS)
    itemID = tonumber(itemID)
    local out = {}
    local BiS = ns.BiS
    if not itemID or not (BiS and BiS.MatchItem) then return out end
    local n = 0
    if GetItemCount then n = tonumber((GetItemCount(itemID, true))) or 0 end
    for _, use in ipairs(UsesOf(itemID) or EMPTY) do
        for _, m in ipairs(BiS:MatchItem(use.item) or EMPTY) do
            if type(m) == "table" and not m.obtained and (includeOS ~= false or not m.os) then
                out[#out + 1] = { use = use, match = m, held = n, left = max(0, use.count - n - 1),
                                  completes = n + 1 >= use.count, os = m.os, which = m.which, inRaid = true,
                                  key = use.item }
                break
            end
        end
    end
    tsort(out, Better)
    return out
end

-- The craft I want itemID for: my pick in the popup while it is still on my lists, else the best one; nil if none.
function Materials:GetOwnPick(itemID, includeOS)
    local list = self:GetOwnWants(itemID, includeOS)
    local p = picks[tonumber(itemID) or 0]
    for _, w in ipairs(list) do
        if w.use.item == p then return w, list end
    end
    return list[1], list
end

-- The popup's choice: the craft I want itemID for (tells the group right away).
function Materials:SetOwnPick(itemID, craftItem)
    itemID, craftItem = tonumber(itemID), tonumber(craftItem)
    if not itemID or not UseFor(itemID, craftItem) then return false end
    if picks[itemID] == craftItem then return true end
    picks[itemID] = craftItem
    self:SendReport(itemID, true)
    ns:Fire("MATERIALS_UPDATED", itemID, Util.PlayerKey())
    return true
end

-- h / f for my RR or MH: how many I hold and the craft I want it for; nil when no craft on my lists uses it.
function Materials:OwnReport(itemID)
    local w = self:GetOwnPick(itemID)
    if not w then return nil end
    return w.held, w.use.item
end

local function GroupChannel()
    if Util.GetGroupChannel then return Util.GetGroupChannel() end
    return IsInRaid and IsInRaid() and "RAID" or nil
end

-- Tells the group what I hold of itemID (MH), when a craft on my lists uses it. force: also within REPORT_GAP.
function Materials:SendReport(itemID, force)
    itemID = tonumber(itemID)
    if not itemID or DemoOn() then return false end
    local h, f = self:OwnReport(itemID)
    if not h then return false end
    local channel = GroupChannel()
    local Comm = ns.Comm
    if not channel or not (Comm and Comm.Send) then return false end
    local t = GetTime and GetTime() or 0
    if not force and lastSent[itemID] and t - lastSent[itemID] < REPORT_GAP then return false end
    lastSent[itemID] = t
    return Comm:Send({ t = "MH", i = itemID, h = h, f = f }, channel, nil, "alert") and true or false
end

---------------------------------------------------------------------------
-- Network + lifecycle
---------------------------------------------------------------------------

local function GroupDist(dist)
    if dist == "RAID" then return true end
    return dist == "PARTY" and Util.IsDungeonModeActive and Util.IsDungeonModeActive() or false
end

local function OnHoldings(sender, msg, dist)
    if DemoOn() or type(msg) ~= "table" or not GroupDist(dist) then return end
    if not Util.IsInMyGroup(sender) then return end
    Materials:OnReport(sender, msg.i, msg.h, msg.f)
end

local function OnDrop(drop)
    if type(drop) ~= "table" or drop.test or type(drop.i) ~= "table" then return end
    local seen = {}
    for _, id in ipairs(drop.i) do
        id = tonumber(id)
        if id and not seen[id] and UsesOf(id) then
            seen[id] = true
            Materials:SendReport(id)
        end
    end
end

function Materials:OnInit()
    ns:On("DROP", OnDrop)
    if ns.Comm and ns.Comm.Register then ns.Comm:Register("MH", OnHoldings) end
end

-- Tests / demo: forget every report and pick.
function Materials:Reset()
    reports, picks, lastSent = {}, {}, {}
    uses = nil
end
