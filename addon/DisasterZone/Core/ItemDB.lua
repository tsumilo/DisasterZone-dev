if DisasterZoneBoot and DisasterZoneBoot.Run("Core/ItemDB.lua", ...) then return end -- DisasterZone: item database access (ns.ItemDB).
-- Indexes over ns.Data (bosses, sources, tokens, upgrades), slot / class filtering,
-- picker candidates, drop expansion and an async item-info cache.
-- 5-man dungeons (ns.Data.Dungeons, Addendum B §21.2) are indexed alongside the raids: their bosses
-- are bossRefs with ref.dungeon = true (ref.raid is the dungeon table) and their sources carry
-- heroic = true when the item is only on the heroic list.
-- Addendum F §37: crafted / reputation / Badge of Justice / PvP items (Data/Sources.lua: ns.Data.Crafted,
-- Reputation, Badges, PvP) are further sources: GetSources entries and picker rows carry
-- kind = "raid" | "dungeon" | "craft" | "rep" | "badge" | "pvp" (indexes built lazily, once).
local addonName, ns = ...

local ItemDB = ns:NewModule("ItemDB")

local type, pairs, ipairs, next, tonumber, tostring, select = type, pairs, ipairs, next, tonumber, tostring, select
local strlower, strfind, strmatch, strgsub = string.lower, string.find, string.match, string.gsub
local tconcat = table.concat
local floor, min, max = math.floor, math.min, math.max

local QUESTION_MARK_ICON = 134400

-- Internal "nothing here" default for iteration; never returned from the public API.
local EMPTY = {}

local function Data()
    return ns.Data or EMPTY
end

---------------------------------------------------------------------------
-- Indexes (built once, lazily, so the API also works before OnInit)
---------------------------------------------------------------------------

local built = false
local raidByKey = {}          -- [raidKey] = raid
local bossByKey = {}          -- [raidKey:bossKey] = bossRef
local bossRefs = {}           -- ordered array of all bossRefs (raid -> boss order)
local directSources = {}      -- [itemID] = { bossRef, ... } (items listed in boss loot tables)
local pieceToTokens = {}      -- [pieceID] = { tokenID, ... } (ns.Data.Tokens)
local arenaToTokens = {}      -- [pieceID] = { tokenID, ... } (ns.Data.TokenArenaExchanges)

-- Tier token -> arena season set exchanges open on Anniversary realms: T4 -> S1 ("2.2") and T5 -> S2 ("2.3"). T6 -> S3
-- ("2.5") is not available there yet (LootReserve's Anniversary data stops at 2.3), so T6 tokens do not count as a
-- way to a Season 3 piece. Raise this when the realms open the next step.
local ARENA_EXCHANGE_PATCH = 2.3

-- The arena pieces a token exchanges for right now (a table from ns.Data.TokenArenaExchanges), or nil.
local function ActiveArenaItems(info)
    if type(info) ~= "table" or type(info.items) ~= "table" then return nil end
    local patch = tonumber(info.patch)
    if patch and patch > ARENA_EXCHANGE_PATCH + 1e-9 then return nil end
    return info.items
end
local upgradeToBase = {}      -- [upgradedID] = baseID (ns.Data.Upgrades)
local bossByNpc = {}          -- [npcID] = bossRef
local bossByObject = {}       -- [objectID] = bossRef
local bossByEncounter = {}    -- [encounterID] = bossRef
local dungeonByKey = {}       -- [dungeonKey] = dungeon (ns.Data.Dungeons)
local dungeonRefs = {}        -- ordered array of the dungeon bossRefs (dungeon -> boss order)
local dungeonSources = {}     -- [itemID] = { {ref=, heroic=bool}, ... } (5-man loot tables)

local function AppendUnique(map, key, value)
    local list = map[key]
    if not list then
        list = {}
        map[key] = list
    end
    for i = 1, #list do
        if list[i] == value then return end
    end
    list[#list + 1] = value
end

local function FirstWins(map, key, value)
    key = tonumber(key)
    if key and map[key] == nil then map[key] = value end
end

-- One source per (item, boss); an item on both the normal and the heroic list of a boss is not heroic-only.
local function AddDungeonSource(itemID, ref, heroic)
    local list = dungeonSources[itemID]
    if not list then
        list = {}
        dungeonSources[itemID] = list
    end
    for i = 1, #list do
        if list[i].ref == ref then
            if not heroic then list[i].heroic = false end
            return
        end
    end
    list[#list + 1] = { ref = ref, heroic = heroic and true or false }
end

local function IndexDungeons(data)
    for _, dungeon in ipairs(data.Dungeons or EMPTY) do
        if type(dungeon) == "table" and type(dungeon.key) == "string" and type(dungeon.bosses) == "table"
            and not raidByKey[dungeon.key] and not dungeonByKey[dungeon.key] then
            dungeonByKey[dungeon.key] = dungeon
            for _, boss in ipairs(dungeon.bosses) do
                local ref = type(boss) == "table" and boss.key and {
                    raid = dungeon,
                    boss = boss,
                    key = dungeon.key .. ":" .. boss.key,
                    phase = tonumber(dungeon.phase) or 1,
                    dungeon = true,
                }
                if ref and not bossByKey[ref.key] then
                    bossByKey[ref.key] = ref
                    dungeonRefs[#dungeonRefs + 1] = ref
                    for _, itemID in ipairs(type(boss.items) == "table" and boss.items or EMPTY) do
                        if type(itemID) == "number" then AddDungeonSource(itemID, ref, false) end
                    end
                    for _, itemID in ipairs(type(boss.heroicItems) == "table" and boss.heroicItems or EMPTY) do
                        if type(itemID) == "number" then AddDungeonSource(itemID, ref, true) end
                    end
                    -- Raids first: a creature / object listed by both keeps its raid boss.
                    for _, npcID in ipairs(type(boss.npcIDs) == "table" and boss.npcIDs or EMPTY) do FirstWins(bossByNpc, npcID, ref) end
                    for _, objID in ipairs(type(boss.objectIDs) == "table" and boss.objectIDs or EMPTY) do FirstWins(bossByObject, objID, ref) end
                    if boss.encounterID then FirstWins(bossByEncounter, boss.encounterID, ref) end
                end
            end
        end
    end
    -- Normal sources before heroic-only ones (stable): the first dungeon source is heroic only when
    -- every dungeon source of the item is.
    for _, list in pairs(dungeonSources) do
        local normal, heroic = {}, {}
        for i = 1, #list do
            local src = list[i]
            if src.heroic then heroic[#heroic + 1] = src else normal[#normal + 1] = src end
        end
        for i = 1, #heroic do normal[#normal + 1] = heroic[i] end
        for i = 1, #normal do list[i] = normal[i] end
    end
end

local function BuildIndex()
    if built then return end
    built = true
    local data = Data()

    for _, raid in ipairs(data.Raids or EMPTY) do
        if type(raid) == "table" and raid.key and type(raid.bosses) == "table" then
            raidByKey[raid.key] = raid
            for _, boss in ipairs(raid.bosses) do
                if type(boss) == "table" and boss.key then
                    local ref = {
                        raid = raid,
                        boss = boss,
                        key = raid.key .. ":" .. boss.key,
                        phase = tonumber(raid.phase) or 1,
                    }
                    if not bossByKey[ref.key] then
                        bossByKey[ref.key] = ref
                        bossRefs[#bossRefs + 1] = ref
                    end
                    for _, itemID in ipairs(boss.items or EMPTY) do
                        if type(itemID) == "number" then
                            AppendUnique(directSources, itemID, ref)
                        end
                    end
                    for _, npcID in ipairs(boss.npcIDs or EMPTY) do FirstWins(bossByNpc, npcID, ref) end
                    for _, objID in ipairs(boss.objectIDs or EMPTY) do FirstWins(bossByObject, objID, ref) end
                    if boss.encounterID then FirstWins(bossByEncounter, boss.encounterID, ref) end
                end
            end
        end
    end

    for tokenID, pieces in pairs(data.Tokens or EMPTY) do
        if type(pieces) == "table" then
            for _, pieceID in ipairs(pieces) do AppendUnique(pieceToTokens, pieceID, tokenID) end
        end
    end
    for tokenID, info in pairs(data.TokenArenaExchanges or EMPTY) do
        local items = ActiveArenaItems(info)
        if items then
            for _, pieceID in ipairs(items) do AppendUnique(arenaToTokens, pieceID, tokenID) end
        end
    end
    for baseID, upgradedID in pairs(data.Upgrades or EMPTY) do
        if type(upgradedID) == "number" and upgradeToBase[upgradedID] == nil then
            upgradeToBase[upgradedID] = baseID
        end
    end
    -- Keep token lists deterministic (pairs order is not).
    for _, list in pairs(pieceToTokens) do table.sort(list) end
    for _, list in pairs(arenaToTokens) do table.sort(list) end

    IndexDungeons(data)
end

function ItemDB:OnInit()
    BuildIndex()
end

---------------------------------------------------------------------------
-- Raids, bosses, sources
---------------------------------------------------------------------------

function ItemDB:GetRaids()
    return Data().Raids or {}
end

-- ns.Data.Dungeons (5-man dungeons, same shape as the raids plus heroicItems per boss).
function ItemDB:GetDungeons()
    return Data().Dungeons or {}
end

function ItemDB:GetRaid(raidKey)
    BuildIndex()
    return raidKey and raidByKey[raidKey] or nil
end

function ItemDB:GetDungeon(dungeonKey)
    BuildIndex()
    return dungeonKey and dungeonByKey[dungeonKey] or nil
end

---------------------------------------------------------------------------
-- Raid information (Data/Raids.lua ns.Data.RaidMeta, refactor 1D). Every lookup takes either key form: the item data's
-- ("HyjalSummit") or the raid planner's ("hyjal"); RaidArt and ItemKeyOf also take an instance id. Both forms stay
-- valid forever (saved records use both).
---------------------------------------------------------------------------

local metaIndex   -- { plan = { [planKey] = itemKey }, inst = { [instanceID] = itemKey } }, built on first use

local function MetaIndex()
    if metaIndex then return metaIndex end
    metaIndex = { plan = {}, inst = {} }
    for itemKey, m in pairs(Data().RaidMeta or EMPTY) do
        if type(m) == "table" then
            if m.planKey then metaIndex.plan[m.planKey] = itemKey end
            if m.instanceID then metaIndex.inst[m.instanceID] = itemKey end
        end
    end
    return metaIndex
end

-- The item data's raid key of `key` (an item key, a plan key or an instance id), or nil.
function ItemDB:ItemKeyOf(key)
    if type(key) == "string" then
        if (Data().RaidMeta or EMPTY)[key] then return key end
        return MetaIndex().plan[key]
    elseif type(key) == "number" then
        return MetaIndex().inst[key]
    end
    return nil
end

-- The raid's meta (ns.Data.RaidMeta entry) and item key, from either key form; nil for anything else.
function ItemDB:GetRaidMeta(key)
    local itemKey = self:ItemKeyOf(key)
    if not itemKey then return nil end
    return Data().RaidMeta[itemKey], itemKey
end

-- The raid planner's key of `key` (either form), or nil.
function ItemDB:PlanKeyOf(key)
    local m = self:GetRaidMeta(key)
    return m and m.planKey or nil
end

-- itemKey, raid (the ns.Data.Raids entry) of an instance map id; nil if it is not a known raid.
function ItemDB:GetRaidByInstance(instanceID)
    local itemKey = type(instanceID) == "number" and MetaIndex().inst[instanceID] or nil
    if not itemKey then return nil end
    return itemKey, self:GetRaid(itemKey)
end

-- itemKey, raid of a raid planner key ("kara"); nil for "other" and unknown keys.
function ItemDB:GetRaidByPlanKey(planKey)
    local itemKey = type(planKey) == "string" and MetaIndex().plan[planKey] or nil
    if not itemKey then return nil end
    return itemKey, self:GetRaid(itemKey)
end

-- The raid's short name ("Kara", ..., "SWP"), either key form; nil for anything else (callers fall back).
function ItemDB:RaidShort(key)
    local m = self:GetRaidMeta(key)
    return m and m.short or nil
end

-- A raid's LFG icon (a file id; either key form), or nil.
function ItemDB:RaidIcon(key)
    local m = self:GetRaidMeta(key)
    return m and m.icon or nil
end

-- A raid's loading screen: file, l, r, t, b. Without w: the whole picture under the logo band. With w x h: the crop a
-- box of that shape shows (fw = the share of the picture's width, 0.5 by default), centred on the raid's focus.
-- under: keep the crop under the logo band (true), or only when h < under (a number). Unknown keys get a generic
-- loading screen (the raid planner's "other").
function ItemDB:RaidArt(key, w, h, fw, under)
    local itemKey = self:ItemKeyOf(key)
    local m = itemKey and Data().RaidMeta[itemKey] or EMPTY
    if not m.art then m = Data().RaidMetaOther or EMPTY end
    local a = m.art
    if not a then return nil end
    if w == nil then return a[1], a[2], a[3], a[4], a[5] end
    fw = fw or 0.5
    local fh = fw * (4 / 3) * (h / w)
    local l = min(max(a.cx - fw / 2, 0), 1 - fw)
    local t = min(max(a.cy - fh / 2, 0.02), 0.98 - fh)
    local b = t + fh
    local top = m.artTop or 0
    if under and (under == true or (type(under) == "number" and h < under)) and t < top then
        t, b = top, b + top - t
    end
    return a[1], l, l + fw, t, b
end

-- Raid and dungeon boss keys ("Karazhan:Prince", "BlackMorass:Aeonus").
function ItemDB:GetBossRef(rbKey)
    BuildIndex()
    if type(rbKey) ~= "string" or rbKey == "" then return nil end
    return bossByKey[rbKey]
end

local allRefs   -- raids then dungeons (built on first use)

-- Ordered array of bossRefs (raid order, then boss order). Do not modify.
-- scope: nil / "raids" = raid bosses (as before), "dungeons" = 5-man bosses, "all" = raids then dungeons.
function ItemDB:GetBossRefs(scope)
    BuildIndex()
    if scope == "dungeons" then return dungeonRefs end
    if scope == "all" then
        if not allRefs then
            allRefs = {}
            for i = 1, #bossRefs do allRefs[#allRefs + 1] = bossRefs[i] end
            for i = 1, #dungeonRefs do allRefs[#allRefs + 1] = dungeonRefs[i] end
        end
        return allRefs
    end
    return bossRefs
end

---------------------------------------------------------------------------
-- Crafted / reputation / badge / PvP sources (Addendum F §37, Data/Sources.lua)
---------------------------------------------------------------------------

-- kind, ns.Data table, filter.sources flag (+ accepted aliases), GetSources scope names.
local EXTRA_KINDS = {
    { kind = "craft", data = "Crafted",    flags = { "crafted", "craft" } },
    { kind = "rep",   data = "Reputation", flags = { "rep", "reputation" } },
    { kind = "badge", data = "Badges",     flags = { "badges", "badge" } },
    { kind = "pvp",   data = "PvP",        flags = { "pvp" } },
}
local SEASON_BY_KEY = { S1 = 1, S2 = 2, S3 = 3, S4 = 4 }
local MAX_ITEM_ID = 200000
local MAX_TEXT = 96

local extraBuilt = false
local extraSources = {}       -- [itemID] = { entry, ... } (craft, rep, badge, pvp order; data order inside)
local extraByKind = {}        -- [kind] = { entry, ... } in data order
local extraSlotRows           -- [kind][sid] = { entry, ... } (built on first picker use)

local function ValidItemID(id)
    return type(id) == "number" and id == floor(id) and id >= 1 and id <= MAX_ITEM_ID
end

local function Str(v)
    if type(v) ~= "string" or v == "" then return nil end
    if #v > MAX_TEXT then v = v:sub(1, MAX_TEXT) end
    return v
end

local function Phase(...)
    local maxPhase = ns.MAX_PHASE or 5
    for i = 1, select("#", ...) do
        local p = tonumber((select(i, ...)))
        if p and p == floor(p) and p >= 1 then
            return (p > maxPhase) and maxPhase or p
        end
    end
    return 1   -- items without a phase count as phase 1 (§35)
end

local function Side(v)
    if v == "Alliance" or v == "Horde" then return v end
    return nil
end

-- One entry per (group, item). Entries are shared (GetSources returns them): never modified after the build.
local function MakeExtraEntry(kind, group, gkey, gname, item)
    local e = {
        kind = kind, itemID = item.id, groupKey = gkey, groupName = gname,
        phase = Phase(item.phase, group.phase),
    }
    if kind == "craft" then
        e.craft = group
        e.skill = tonumber(item.skill)
        e.spec = Str(item.spec)
        e.subgroup = e.spec
        e.bop = (item.bop == true) or nil
        e.reagentsNote = Str(item.reagentsNote)
        e.spell = tonumber(item.spell)
        e.professionID = tonumber(group.professionID)
    elseif kind == "rep" then
        e.rep = group
        e.standing = Str(item.standing)
        e.factionID = tonumber(group.factionID)
        e.faction = Side(group.side)
    elseif kind == "badge" then
        e.badge = group
        e.cost = tonumber(item.cost)
        e.npcID = tonumber(group.npcID)
    else
        e.pvp = group
        e.cost = Str(item.cost) or tonumber(item.cost)
        e.rating = tonumber(item.rating)
        e.faction = Side(item.faction)
        e.season = SEASON_BY_KEY[gkey]
    end
    return e
end

local function BuildExtra()
    if extraBuilt then return end
    extraBuilt = true
    local data = Data()
    for _, def in ipairs(EXTRA_KINDS) do
        local list = {}
        extraByKind[def.kind] = list
        local groups = data[def.data]
        for _, group in ipairs(type(groups) == "table" and groups or EMPTY) do
            if type(group) == "table" and type(group.items) == "table" then
                local gkey = Str(group.key) or Str(group.name) or "?"
                local gname = Str(group.name) or gkey
                local seen = {}
                for _, item in ipairs(group.items) do
                    local id = type(item) == "table" and item.id
                    if ValidItemID(id) and not seen[id] then
                        seen[id] = true
                        local e = MakeExtraEntry(def.kind, group, gkey, gname, item)
                        list[#list + 1] = e
                        local perItem = extraSources[id]
                        if not perItem then
                            perItem = {}
                            extraSources[id] = perItem
                        end
                        perItem[#perItem + 1] = e
                    end
                end
            end
        end
    end
end

-- The source groups of one kind ("craft" | "rep" | "badge" | "pvp") in data order: the ns.Data tables
-- (DisasterZone extension, e.g. for section order). Do not modify.
function ItemDB:GetSourceGroups(kind)
    for _, def in ipairs(EXTRA_KINDS) do
        if def.kind == kind then
            local groups = Data()[def.data]
            return type(groups) == "table" and groups or {}
        end
    end
    return {}
end

---------------------------------------------------------------------------
-- GetSources
---------------------------------------------------------------------------

-- scope -> { raids, dungeons, craft, rep, badge, pvp }
local SCOPES = {
    all      = { true, true, true, true, true, true },
    raids    = { true, false, false, false, false, false },
    dungeons = { false, true, false, false, false, false },
    drops    = { true, true, false, false, false, false },
    craft    = { false, false, true, false, false, false },
    rep      = { false, false, false, true, false, false },
    badge    = { false, false, false, false, true, false },
    pvp      = { false, false, false, false, false, true },
}
local SCOPE_ALIAS = { crafted = "craft", reputation = "rep", badges = "badge" }
local sourceCache = {}
for name in pairs(SCOPES) do sourceCache[name] = {} end

local function Scope(scope)
    scope = SCOPE_ALIAS[scope] or scope
    if type(scope) == "string" and SCOPES[scope] then return scope end
    return "all"
end

-- Array of source entries, each with kind and phase:
--   raid:    { kind="raid", ref=, via=nil|"token"|"upgrade"|"arena", viaItem=, phase=, groupKey=, groupName= }
--            (direct first, then via token / Sunmote / arena exchange)
--   dungeon: { kind="dungeon", ref=, heroic=true|nil, phase=, groupKey=, groupName= } (normal before heroic-only)
--   craft:   { kind="craft", craft=profession, groupKey=, groupName=, skill=, spec=, subgroup=, bop=, reagentsNote=,
--              spell=, professionID=, phase= }
--   rep:     { kind="rep", rep=faction, groupKey=, groupName=, standing=, factionID=, faction=side|nil, phase= }
--   badge:   { kind="badge", badge=vendor, groupKey=, groupName=, cost=badges, npcID=, phase= }
--   pvp:     { kind="pvp", pvp=group, groupKey=, groupName=, season=1..4|nil, cost=text|nil, rating=, faction=, phase= }
-- in that kind order. scope (optional): "all" (default: every kind), "drops" (raids + 5-man dungeons, the
-- pre-0.4 default), "raids", "dungeons", "craft", "rep", "badge", "pvp".
-- The returned array is cached and shared: do not modify it.
function ItemDB:GetSources(itemID, scope)
    itemID = tonumber(itemID)
    if not itemID or itemID ~= itemID then return {} end
    scope = Scope(scope)
    local cache = sourceCache[scope]
    local cached = cache[itemID]
    if cached then return cached end
    BuildIndex()
    local want = SCOPES[scope]

    local out, seenRef = {}, {}
    local function Add(refs, via, viaItem)
        for _, ref in ipairs(refs or EMPTY) do
            if not seenRef[ref] then
                seenRef[ref] = true
                out[#out + 1] = { kind = "raid", ref = ref, via = via, viaItem = viaItem, phase = ref.phase,
                                  groupKey = ref.raid.key, groupName = ref.raid.name }
            end
        end
    end

    if want[1] then
        Add(directSources[itemID], nil, nil)
        for _, tokenID in ipairs(pieceToTokens[itemID] or EMPTY) do
            Add(directSources[tokenID], "token", tokenID)
        end
        local baseID = upgradeToBase[itemID]
        if baseID then
            Add(directSources[baseID], "upgrade", baseID)
        end
        for _, tokenID in ipairs(arenaToTokens[itemID] or EMPTY) do
            Add(directSources[tokenID], "arena", tokenID)
        end
    end
    if want[2] then
        for _, src in ipairs(dungeonSources[itemID] or EMPTY) do
            if not seenRef[src.ref] then
                seenRef[src.ref] = true
                local ref = src.ref
                out[#out + 1] = { kind = "dungeon", ref = ref, heroic = src.heroic or nil, phase = ref.phase,
                                  groupKey = ref.raid.key, groupName = ref.raid.name }
            end
        end
    end
    if want[3] or want[4] or want[5] or want[6] then
        BuildExtra()
        local extra = extraSources[itemID]
        if extra then
            for k = 3, 6 do
                if want[k] then
                    local kind = EXTRA_KINDS[k - 2].kind
                    for i = 1, #extra do
                        if extra[i].kind == kind then out[#out + 1] = extra[i] end
                    end
                end
            end
        end
    end

    cache[itemID] = out
    return out
end

-- true when the item drops in a 5-man dungeon (any difficulty).
function ItemDB:IsDungeonItem(itemID)
    BuildIndex()
    itemID = tonumber(itemID)
    return (itemID and dungeonSources[itemID] ~= nil) and true or false
end

local VIA_PREFIX = { token = "Token", arena = "Token", upgrade = "Sunmote" }

local function BossLabel(ref, short, heroic)
    local boss, raid = ref.boss, ref.raid
    local bossName = boss.name or boss.key or "?"
    local raidName = raid.name or raid.key or "?"
    if short then
        local text = boss.isTrash and (raidName .. " trash") or bossName
        if heroic then text = text .. " (H)" end
        return text
    end
    local text = bossName .. " · " .. raidName
    if heroic then text = text .. " (Heroic)" end
    return text
end

local DASH = " \226\128\148 "   -- " — " (the default fonts have the em dash)

-- "Arena Season 2 (Merciless Gladiator)" -> "Arena Season 2"; "World PvP (Hellfire, ...)" -> "World PvP".
local function ShortGroupName(name)
    local s = strgsub(name or "?", "%s*%b()%s*$", "")
    return (s ~= "") and s or (name or "?")
end

local function NumberText(n)
    if type(n) ~= "number" then return tostring(n) end
    if n == floor(n) then return string.format("%d", n) end
    return tostring(n)
end

-- Text of one source entry (a GetSources entry or a GetCandidates row).
local function SourceLabel(src, short)
    local kind = src.kind
    if src.ref and (kind == nil or kind == "raid" or kind == "dungeon") then
        local text = BossLabel(src.ref, short, src.heroic)
        local prefix = src.via and VIA_PREFIX[src.via]
        if prefix then text = prefix .. " · " .. text end
        return text
    end
    local name = src.groupName or src.groupKey or "?"
    if kind == "craft" then
        -- "Blacksmithing (375)", long: "Blacksmithing (375) · Armorsmith · BoP"
        local text = src.skill and (name .. " (" .. NumberText(src.skill) .. ")") or name
        if not short then
            if src.spec then text = text .. " · " .. src.spec end
            if src.bop then text = text .. " · BoP" end
        end
        return text
    elseif kind == "rep" then
        -- "The Sha'tar — Exalted"
        return src.standing and (name .. DASH .. src.standing) or name
    elseif kind == "badge" then
        -- "G'eras — 60 badges"
        if src.cost then return name .. DASH .. NumberText(src.cost) .. " badges" end
        return name .. " (Badge of Justice)"
    elseif kind == "pvp" then
        -- long: "Arena Season 2 (Merciless Gladiator)", "Honor vendors — 8000 honor (Alliance)";
        -- short: "Arena Season 2", "Honor vendors (Alliance)"
        local text = (short or not src.season) and ShortGroupName(name) or name
        if not short and src.cost then text = text .. DASH .. NumberText(src.cost) end
        if not short and src.rating then text = text .. " (" .. NumberText(src.rating) .. " rating)" end
        if src.faction then text = text .. " (" .. src.faction .. ")" end
        return text
    end
    return name
end

-- The entry GetSourceText / GetSourceKind describe: the first source, except that an arena piece reached
-- only through a tier token's arena exchange (LootReserve data) is described by its own source (PvP).
local function PrimarySource(sources)
    local first = sources[1]
    if first and first.via == "arena" then
        for i = 2, #sources do
            if sources[i].via ~= "arena" then return sources[i] end
        end
    end
    return first
end

-- "Prince Malchezaar · Karazhan", "Token · Prince Malchezaar · Karazhan", "... +1 more";
-- 5-man: "Aeonus · The Black Morass", "Aeonus · The Black Morass (Heroic)" (heroic list only).
-- short=true drops the raid / dungeon name ("Aeonus (H)"). Addendum F: "Blacksmithing (375)" (+ " · Armorsmith"
-- when long), "The Sha'tar — Exalted", "G'eras — 60 badges", "Arena Season 2 (...)" / short "Arena Season 2",
-- "Honor vendors — 8000 honor (Alliance)". nil when the item has no known source.
function ItemDB:GetSourceText(itemID, short)
    local sources = self:GetSources(itemID)
    local primary = PrimarySource(sources)
    if not primary then return nil end
    local text = SourceLabel(primary, short)
    if #sources > 1 then
        text = text .. " +" .. (#sources - 1) .. " more"
    end
    return text
end

-- Text of one source entry or picker row (GetSources / GetCandidates), without the "+n more" suffix.
function ItemDB:FormatSource(src, short)
    if type(src) ~= "table" then return nil end
    return SourceLabel(src, short)
end

-- The primary kind of an item's sources: "raid" | "dungeon" | "craft" | "rep" | "badge" | "pvp", or nil.
function ItemDB:GetSourceKind(itemID)
    local primary = PrimarySource(self:GetSources(itemID))
    return primary and primary.kind or nil
end

-- Lowest phase among all sources (raid via token / upgrade / arena, dungeons, crafted, rep, badges, PvP), or nil.
function ItemDB:GetPhase(itemID)
    local best
    for _, src in ipairs(self:GetSources(itemID)) do
        local p = src.phase or (src.ref and src.ref.phase)
        if p and (not best or p < best) then best = p end
    end
    return best
end

function ItemDB:IsToken(itemID)
    itemID = tonumber(itemID)
    local tokens = Data().Tokens
    return (itemID and tokens and tokens[itemID] ~= nil) and true or false
end

-- Classes that can use a tier token (ns.Data.TokenClasses), or nil.
function ItemDB:GetTokenClasses(itemID)
    local tc = Data().TokenClasses
    return tc and tc[tonumber(itemID) or 0] or nil
end

local expandCache = {}

-- { itemID } + token pieces + arena exchange items + Sunmote upgrade (deduped, cached; do not modify).
function ItemDB:ExpandDrop(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID ~= itemID then return {} end
    local cached = expandCache[itemID]
    if cached then return cached end
    local data = Data()
    local out, seen = {}, {}
    local function Add(id)
        if type(id) == "number" and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    Add(itemID)
    for _, id in ipairs((data.Tokens and data.Tokens[itemID]) or EMPTY) do Add(id) end
    local arena = ActiveArenaItems(data.TokenArenaExchanges and data.TokenArenaExchanges[itemID])
    for _, id in ipairs(arena or EMPTY) do Add(id) end
    Add(data.Upgrades and data.Upgrades[itemID])
    expandCache[itemID] = out
    return out
end

-- GUID "Creature-0-srv-inst-zone-npcID-spawn" / "GameObject-..." -> bossRef.
function ItemDB:GetBossBySourceGUID(guid)
    if type(guid) ~= "string" or guid == "" then return nil end
    BuildIndex()
    local fields = {}
    for part in (guid .. "-"):gmatch("([^%-]*)%-") do
        fields[#fields + 1] = part
    end
    local unitType, id = fields[1], tonumber(fields[6])
    if not id then return nil end
    if unitType == "Creature" or unitType == "Vehicle" then
        return bossByNpc[id]
    elseif unitType == "GameObject" then
        return bossByObject[id]
    end
    return nil
end

-- DisasterZone 0.5: the trash pseudo-boss ref ("Karazhan:Trash") of the raid / dungeon with this instance ID when one of
-- `items` is on its loot list, else nil (loot of a trash corpse is not filed under the last boss killed).
function ItemDB:GetTrashRefForInstance(instanceID, items)
    instanceID = tonumber(instanceID)
    if not instanceID or type(items) ~= "table" then return nil end
    local data = Data()
    local function Scan(list)
        for _, group in ipairs(list or EMPTY) do
            if type(group) == "table" and group.instanceID == instanceID then
                for _, boss in ipairs(group.bosses or EMPTY) do
                    if type(boss) == "table" and boss.isTrash then
                        local have = {}
                        for _, id in ipairs(boss.items or EMPTY) do have[id] = true end
                        for _, id in ipairs(boss.heroicItems or EMPTY) do have[id] = true end
                        for _, id in ipairs(items) do
                            if have[tonumber(id)] then
                                return self:GetBossRef(tostring(group.key) .. ":" .. tostring(boss.key))
                            end
                        end
                    end
                end
            end
        end
        return nil
    end
    return Scan(data.Raids) or Scan(data.Dungeons)
end

function ItemDB:GetBossByEncounter(encounterID)
    encounterID = tonumber(encounterID)
    if not encounterID then return nil end
    BuildIndex()
    return bossByEncounter[encounterID]
end

---------------------------------------------------------------------------
-- Equip location, slots, usability
---------------------------------------------------------------------------

local function InstantInfo(itemID)
    local api = C_Item and C_Item.GetItemInfoInstant
    if not api then return nil end
    -- itemID, type, subType, equipLoc, icon, classID, subclassID
    return api(itemID)
end

local equipLocCache = {}   -- [itemID] = equipLoc | false (not equippable / unknown)
local unknownItems = {}    -- ids GetItemInfoInstant did not know (debug-logged once)

local NON_EQUIP = { [""] = true, INVTYPE_NON_EQUIP = true, INVTYPE_NON_EQUIP_IGNORE = true }

-- DisasterZone 0.5: the item's classID (C_Item.GetItemInfoInstant; 7 trade goods, 3 gem, ...), or nil when unknown.
function ItemDB:GetItemClassID(itemID)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    local id, _, _, _, _, classID = InstantInfo(itemID)
    if id == nil then return nil end
    return tonumber(classID)
end

local function RawEquipLoc(itemID)
    local id, _, _, loc = InstantInfo(itemID)
    if id == nil then
        if not unknownItems[itemID] then
            unknownItems[itemID] = true
            ns:Debug("ItemDB: client has no instant info for item %s; skipped.", tostring(itemID))
        end
        return false
    end
    if type(loc) ~= "string" or NON_EQUIP[loc] then return false end
    return loc
end

-- invType string (tokens resolve to their first piece), or nil if not equippable.
function ItemDB:GetEquipLoc(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID ~= itemID then return nil end
    local cached = equipLocCache[itemID]
    if cached == nil then
        local tokens = Data().Tokens
        local pieces = tokens and tokens[itemID]
        if type(pieces) == "table" and pieces[1] then
            cached = RawEquipLoc(pieces[1])
        else
            cached = RawEquipLoc(itemID)
        end
        equipLocCache[itemID] = cached
    end
    return cached or nil
end

local GEAR_CLASSES = { [2] = true, [4] = true }   -- weapon, armor
local NOT_GEAR_LOC = { INVTYPE_BODY = true, INVTYPE_TABARD = true, INVTYPE_BAG = true, INVTYPE_QUIVER = true,
                       INVTYPE_AMMO = true }

-- 1.3.5: gear = a weapon or armor worn in a real slot (not a shirt / tabard), or a tier token / quest item that turns
-- into gear (Data.Tokens: Magtheridon's Head, Verdant Sphere, ...). Bags, recipes, mounts, materials: false.
-- nil when the client does not know the item.
function ItemDB:IsGear(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID ~= itemID then return nil end
    if self:IsToken(itemID) then return true end
    local id, _, _, loc, _, classID = InstantInfo(itemID)
    if id == nil then return nil end
    return (GEAR_CLASSES[tonumber(classID)] and type(loc) == "string" and not NON_EQUIP[loc] and not NOT_GEAR_LOC[loc])
        and true or false
end

-- Array of sids the item can go into (a new array each call).
function ItemDB:GetSlotsForItem(itemID)
    local out = {}
    local loc = self:GetEquipLoc(itemID)
    local sids = loc and ns.INVTYPE_TO_SIDS[loc]
    if sids then
        for i = 1, #sids do out[i] = sids[i] end
    end
    return out
end

function ItemDB:FitsSlot(itemID, sid)
    local slot = ns.SLOTS[tonumber(sid) or 0]
    if not slot then return false end
    local loc = self:GetEquipLoc(itemID)
    return (loc and slot.invTypes[loc]) and true or false
end

local function ListHas(list, value)
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

-- DisasterZone 0.5: the arena pieces tokenID exchanges for right now (see ARENA_EXCHANGE_PATCH), or nil. Do not modify.
function ItemDB:GetArenaExchangeItems(tokenID)
    local data = Data()
    return ActiveArenaItems(data.TokenArenaExchanges and data.TokenArenaExchanges[tonumber(tokenID) or 0])
end

-- DisasterZone 0.5: false when only other classes can use itemID (a tier piece, a token, or a class-restricted item of
-- ns.Data.ItemClasses: "Classes: ..." on the tooltip), true otherwise, nil for bad arguments. Class restrictions
-- only (no armor / weapon proficiency): the loot-decision guard for wanters.
function ItemDB:CanClassUse(itemID, classFile)
    itemID = tonumber(itemID)
    if not itemID or type(classFile) ~= "string" or classFile == "" then return nil end
    local data = Data()
    local tierClass = data.TierPieceClass and data.TierPieceClass[itemID]
    if tierClass then return tierClass == classFile end
    local tokenClasses = data.TokenClasses and data.TokenClasses[itemID]
    if type(tokenClasses) == "table" then return ListHas(tokenClasses, classFile) end
    local itemClasses = data.ItemClasses and data.ItemClasses[itemID]
    if type(itemClasses) == "table" then return ListHas(itemClasses, classFile) end
    return true
end

-- The classes that may use a class-restricted item (ns.Data.ItemClasses), or nil. Do not modify.
function ItemDB:GetItemClasses(itemID)
    local data = Data()
    local list = data.ItemClasses and data.ItemClasses[tonumber(itemID) or 0]
    return type(list) == "table" and list or nil
end

-- true / false, or nil when unknown (unknown class, or the client does not know the item).
-- Optional sid: one-handers in the off hand (sid 16) require dual wield.
function ItemDB:IsUsableBy(itemID, classFile, sid)
    itemID = tonumber(itemID)
    if not itemID or type(classFile) ~= "string" then return nil end
    local data = Data()

    local tierClass = data.TierPieceClass and data.TierPieceClass[itemID]
    if tierClass then return tierClass == classFile end

    local tokenClasses = data.TokenClasses and data.TokenClasses[itemID]
    if type(tokenClasses) == "table" then return ListHas(tokenClasses, classFile) end

    local pieces = data.Tokens and data.Tokens[itemID]
    if type(pieces) == "table" then
        -- Class-less quest items (e.g. Magtheridon's Head): usable if any reward is.
        for _, pieceID in ipairs(pieces) do
            if self:IsUsableBy(pieceID, classFile, sid) ~= false then return true end
        end
        return false
    end

    -- Class-restricted items ("Classes: Rogue": T5 class trinkets, Warglaives, PvP set pieces, Ashtongue
    -- talismans, ...), then the usual armor / weapon checks (a restricted weapon still needs dual wield).
    local itemClasses = data.ItemClasses and data.ItemClasses[itemID]
    if type(itemClasses) == "table" and not ListHas(itemClasses, classFile) then return false end

    local id, _, _, loc, _, classID, subclassID = InstantInfo(itemID)
    if id == nil then return nil end

    if classID == ns.ITEM_CLASS_ARMOR then
        local allowed = ns.ARMOR_ALLOWED[classFile]
        if not allowed then return nil end
        if subclassID ~= nil and not allowed[subclassID] then return false end
    elseif classID == ns.ITEM_CLASS_WEAPON then
        local allowed = ns.WEAPON_ALLOWED[classFile]
        if not allowed then return nil end
        if subclassID ~= nil and ns.WEAPON_RESTRICTED[subclassID] and not allowed[subclassID] then
            return false
        end
        if not ns.DUAL_WIELD[classFile] then
            if loc == "INVTYPE_WEAPONOFFHAND" then return false end
            if loc == "INVTYPE_WEAPON" and tonumber(sid) == 16 then return false end
        end
    end
    return true
end

local ALWAYS_PRIMARY_LOC = {
    INVTYPE_CLOAK = true, INVTYPE_FINGER = true, INVTYPE_NECK = true, INVTYPE_TRINKET = true,
    INVTYPE_SHIELD = true, INVTYPE_RELIC = true, INVTYPE_HOLDABLE = true,
}
local BODY_ARMOR_SUB = { [1] = true, [2] = true, [3] = true, [4] = true }

-- true unless the item is body armor (cloth/leather/mail/plate) of a lighter type than the class's.
function ItemDB:IsPrimaryArmor(itemID, classFile)
    itemID = tonumber(itemID)
    if not itemID then return true end
    local data = Data()
    if (data.TierPieceClass and data.TierPieceClass[itemID]) or (data.Tokens and data.Tokens[itemID]) then
        return true
    end
    local id, _, _, loc, _, classID, subclassID = InstantInfo(itemID)
    if id == nil or classID ~= ns.ITEM_CLASS_ARMOR then return true end
    if not BODY_ARMOR_SUB[subclassID] or ALWAYS_PRIMARY_LOC[loc] then return true end
    local primary = classFile and ns.ARMOR_PRIMARY[classFile]
    if not primary then return true end
    return subclassID == primary
end

---------------------------------------------------------------------------
-- Picker candidates
---------------------------------------------------------------------------

-- slotRows[sid] = ordered rows { itemID, ref, via, viaItem, tokenClass } for every
-- raid item (or token piece / Sunmote upgrade) that fits the slot; dungeonSlotRows[sid] the same for
-- 5-man loot (plus heroic = true for heroic-list-only rows). Built on first use.
local slotRows, dungeonSlotRows

local function BuildSlotRows()
    if slotRows then return slotRows, dungeonSlotRows end
    BuildIndex()
    local data = Data()
    local tokens = data.Tokens or EMPTY
    local upgrades = data.Upgrades or EMPTY
    local tierClass = data.TierPieceClass or EMPTY
    local rowsBySid, dungeonBySid = {}, {}
    for sid = 1, ns.NUM_SLOTS do
        rowsBySid[sid] = {}
        dungeonBySid[sid] = {}
    end

    local function Emit(target, itemID, ref, via, viaItem, heroic)
        local loc = ItemDB:GetEquipLoc(itemID)
        local sids = loc and ns.INVTYPE_TO_SIDS[loc]
        if not sids then return end
        for _, sid in ipairs(sids) do
            local rows = target[sid]
            if rows then
                rows[#rows + 1] = { itemID = itemID, ref = ref, via = via, viaItem = viaItem,
                                    tokenClass = tierClass[itemID], heroic = heroic }
            end
        end
    end

    local function EmitItem(target, itemID, ref, heroic)
        local pieces = tokens[itemID]
        if type(pieces) == "table" then
            -- Tokens are never candidates themselves; their pieces are.
            for _, pieceID in ipairs(pieces) do
                if type(pieceID) == "number" then Emit(target, pieceID, ref, "token", itemID, heroic) end
            end
        else
            Emit(target, itemID, ref, nil, nil, heroic)
            local upgraded = upgrades[itemID]
            if type(upgraded) == "number" then Emit(target, upgraded, ref, "upgrade", itemID, heroic) end
        end
    end

    for _, ref in ipairs(bossRefs) do
        for _, itemID in ipairs(ref.boss.items or EMPTY) do
            if type(itemID) == "number" then EmitItem(rowsBySid, itemID, ref, nil) end
        end
    end

    -- 5-man: the normal list, then heroic-list items the normal list does not have.
    for _, ref in ipairs(dungeonRefs) do
        local boss = ref.boss
        local normal = {}
        for _, itemID in ipairs(type(boss.items) == "table" and boss.items or EMPTY) do
            if type(itemID) == "number" and not normal[itemID] then
                normal[itemID] = true
                EmitItem(dungeonBySid, itemID, ref, nil)
            end
        end
        local heroicSeen = {}
        for _, itemID in ipairs(type(boss.heroicItems) == "table" and boss.heroicItems or EMPTY) do
            if type(itemID) == "number" and not normal[itemID] and not heroicSeen[itemID] then
                heroicSeen[itemID] = true
                EmitItem(dungeonBySid, itemID, ref, true)
            end
        end
    end
    slotRows, dungeonSlotRows = rowsBySid, dungeonBySid
    return slotRows, dungeonSlotRows
end

-- extraSlotRows[kind][sid] = the source entries of that kind whose item fits the slot (data order).
local function BuildExtraSlotRows()
    if extraSlotRows then return extraSlotRows end
    BuildExtra()
    local byKind = {}
    for _, def in ipairs(EXTRA_KINDS) do
        local bySid = {}
        for sid = 1, ns.NUM_SLOTS do bySid[sid] = {} end
        for _, e in ipairs(extraByKind[def.kind] or EMPTY) do
            local loc = ItemDB:GetEquipLoc(e.itemID)
            local sids = loc and ns.INVTYPE_TO_SIDS[loc]
            if sids then
                for _, sid in ipairs(sids) do
                    local rows = bySid[sid]
                    if rows then rows[#rows + 1] = e end
                end
            end
        end
        byKind[def.kind] = bySid
    end
    extraSlotRows = byKind
    return extraSlotRows
end

local SCOPE_RAIDS, SCOPE_DUNGEONS = { true, false }, { false, true }
local SCOPE_ALL = { true, true }

-- filter.sources (Addendum F §35) -> raids, dungeons, { [kind] = true } for the extra kinds.
local function WantedSources(filter)
    local s = filter.sources
    if type(s) == "table" then
        local extra = {}
        for _, def in ipairs(EXTRA_KINDS) do
            for _, flag in ipairs(def.flags) do
                if s[flag] then extra[def.kind] = true end
            end
        end
        return s.raids and true or false, s.dungeons and true or false, extra
    end
    local scope = (filter.scope == "dungeons" and SCOPE_DUNGEONS) or (filter.scope == "all" and SCOPE_ALL) or SCOPE_RAIDS
    return scope[1], scope[2], EMPTY
end

-- "Alliance" / "Horde" whose faction-tagged rows are shown, or nil (show both sides).
local function WantedFaction(filter)
    local f = filter.faction
    if f == "Alliance" or f == "Horde" then return f end
    if f ~= nil then return nil end   -- "any" / false: both sides
    if UnitFactionGroup then
        local mine = UnitFactionGroup("player")
        if mine == "Alliance" or mine == "Horde" then return mine end
    end
    return nil
end

-- Fields copied from a source entry into an extra-kind picker row.
local ROW_FIELDS = { "kind", "groupKey", "groupName", "subgroup", "phase", "skill", "spec", "bop", "reagentsNote",
    "spell", "professionID", "standing", "factionID", "faction", "cost", "rating", "season", "npcID" }

-- Array of rows in section order: raids (raid -> boss -> item), 5-man dungeons, then crafted (profession
-- order; general before specialisations), reputation, badge vendors and PvP (data order).
--   raid / dungeon rows: { itemID=, kind="raid"|"dungeon", ref=bossRef, via=nil|"token"|"upgrade", viaItem=,
--                          heroic=true|nil, phase=, groupKey=raid key, groupName=raid name }
--   other rows:          { itemID=, kind="craft"|"rep"|"badge"|"pvp", groupKey=, groupName= (profession, faction,
--                          vendor or PvP group), subgroup= (specialisation), phase=, + the GetSources fields }
-- filter = { sources = { raids=, dungeons=, crafted=, rep=, badges=, pvp= } (supersedes scope),
--            scope = "raids" (default) | "dungeons" | "all" (raids + dungeons), maxPhase=, phase=, class=,
--            usableOnly=, primaryArmorOnly=, includeTrash=true, includeUpgrades=true,
--            faction = nil (my faction) | "Alliance" | "Horde" | "any" }.
-- The phase filters apply to every source (items without a phase count as phase 1). Faction-tagged rows
-- (PvP items and side-only reputations) are only listed for the wanted faction. Deduped by itemID (first
-- source wins). Rows are fresh tables.
function ItemDB:GetCandidates(sid, filter)
    sid = tonumber(sid)
    local out = {}
    if not sid or not ns.SLOTS[sid] then return out end
    filter = type(filter) == "table" and filter or EMPTY
    local raidRows, dungeonRows = BuildSlotRows()
    local wantRaids, wantDungeons, wantExtra = WantedSources(filter)

    local maxPhase = tonumber(filter.maxPhase)
    local exactPhase = tonumber(filter.phase)
    local class = filter.class
    local usableOnly = class and filter.usableOnly
    local primaryOnly = class and filter.primaryArmorOnly
    local includeTrash = filter.includeTrash ~= false
    local includeUpgrades = filter.includeUpgrades ~= false
    local seen = {}

    local function Scan(rows, kind)
        for i = 1, #(rows or EMPTY) do
            local row = rows[i]
            local id, ref = row.itemID, row.ref
            local ok = not seen[id]
                and (includeTrash or not ref.boss.isTrash)
                and (not maxPhase or ref.phase <= maxPhase)
                and (not exactPhase or ref.phase == exactPhase)
                and (includeUpgrades or row.via ~= "upgrade")
            if ok and class and row.tokenClass and row.tokenClass ~= class then
                ok = false
            end
            if ok and usableOnly and self:IsUsableBy(id, class, sid) == false then
                ok = false
            end
            if ok and primaryOnly and not self:IsPrimaryArmor(id, class) then
                ok = false
            end
            if ok then
                seen[id] = true
                local raid = ref.raid
                out[#out + 1] = { itemID = id, kind = kind, ref = ref, via = row.via, viaItem = row.viaItem,
                                  heroic = row.heroic and true or nil, phase = ref.phase,
                                  groupKey = raid.key, groupName = raid.name }
            end
        end
    end

    if wantRaids then Scan(raidRows[sid], "raid") end
    if wantDungeons then Scan(dungeonRows[sid], "dungeon") end

    if next(wantExtra) then
        local byKind = BuildExtraSlotRows()
        local faction = WantedFaction(filter)
        for _, def in ipairs(EXTRA_KINDS) do
            if wantExtra[def.kind] then
                local rows = byKind[def.kind][sid] or EMPTY
                for i = 1, #rows do
                    local e = rows[i]
                    local id, p = e.itemID, e.phase
                    local ok = not seen[id]
                        and (not maxPhase or p <= maxPhase)
                        and (not exactPhase or p == exactPhase)
                        and (not faction or not e.faction or e.faction == faction)
                    if ok and usableOnly and self:IsUsableBy(id, class, sid) == false then
                        ok = false
                    end
                    if ok and primaryOnly and not self:IsPrimaryArmor(id, class) then
                        ok = false
                    end
                    if ok then
                        seen[id] = true
                        local row = { itemID = id }
                        for f = 1, #ROW_FIELDS do
                            local k = ROW_FIELDS[f]
                            row[k] = e[k]
                        end
                        out[#out + 1] = row
                    end
                end
            end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Item info (async; the client caches it)
---------------------------------------------------------------------------

local pending = {}    -- [itemID] = true while a load request is outstanding
local requestedAt = {} -- [itemID] = GetTime() of the outstanding request (watchdog)
local failedAt = {}   -- [itemID] = GetTime() of a failed load (not retried for a while)
local RETRY_FAILED_AFTER = 60
local WATCHDOG_EVERY = 1     -- seconds between sweeps while anything is pending
local REREQUEST_AFTER = 3    -- a request with no answer by then is sent again

local function FireItemInfoReady()
    ns:Fire("ITEMINFO_READY")
end

local function QueueReady()
    if not ns.Util.IsDebouncePending("iteminfo") then
        ns.Util.Debounce("iteminfo", 0.25, FireItemInfoReady)
    end
end

-- GET_ITEM_INFO_RECEIVED is not reliable: it can be skipped when the item was already in flight
-- (requested by a tooltip or another addon), or arrive before GetItemInfo can read it. Either way the
-- item stayed "pending" forever and the UI showed "Loading..." until some other refresh. The watchdog
-- polls pending items: cached ones fire ITEMINFO_READY, silent ones are requested again.
local watchdogRunning = false
local Watchdog
Watchdog = function()
    local api = C_Item and C_Item.GetItemInfo
    local now = GetTime and GetTime() or 0
    local any, ready = false, false
    for id in pairs(pending) do
        if api and api(id) then
            pending[id], requestedAt[id] = nil, nil
            ready = true
        else
            any = true
            if now - (requestedAt[id] or 0) >= REREQUEST_AFTER then
                requestedAt[id] = now
                if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
            end
        end
    end
    if ready then QueueReady() end
    if any and C_Timer and C_Timer.After then
        C_Timer.After(WATCHDOG_EVERY, Watchdog)
    else
        watchdogRunning = false
    end
end

local function StartWatchdog()
    if watchdogRunning or not (C_Timer and C_Timer.After) then return end
    watchdogRunning = true
    C_Timer.After(WATCHDOG_EVERY, Watchdog)
end

local function RequestLoad(itemID)
    if pending[itemID] then return end
    local failed = failedAt[itemID]
    if failed and GetTime and (GetTime() - failed) < RETRY_FAILED_AFTER then return end
    pending[itemID] = true
    requestedAt[itemID] = GetTime and GetTime() or 0
    if C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end
    StartWatchdog()
end

-- name, link, quality, icon when cached; otherwise nil (and a load is requested).
function ItemDB:GetInfo(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID ~= itemID or itemID <= 0 then return nil end
    local api = C_Item and C_Item.GetItemInfo
    if api then
        local name, link, quality, _, _, _, _, _, _, icon = api(itemID)
        if name then
            return name, link, quality, icon
        end
    end
    RequestLoad(itemID)
    return nil
end

function ItemDB:GetName(itemID)
    local name = self:GetInfo(itemID)
    return name
end

function ItemDB:GetLink(itemID)
    local _, link = self:GetInfo(itemID)
    return link
end

function ItemDB:GetQuality(itemID)
    local name, _, quality = self:GetInfo(itemID)
    if name then return quality end
    if C_Item and C_Item.GetItemQualityByID and tonumber(itemID) then
        return C_Item.GetItemQualityByID(tonumber(itemID))
    end
    return nil
end

-- What chat and messages name an item by: its link, else its name, else "item <id>" (still loading). The Core
-- modules' one copy (the UI's is UI:ItemLabel, which gives nil while loading).
function ItemDB:GetLabel(itemID)
    return self:GetLink(itemID) or self:GetName(itemID) or ("item " .. tostring(itemID))
end

function ItemDB:GetIcon(itemID)
    itemID = tonumber(itemID)
    local icon = itemID and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
    return icon or QUESTION_MARK_ICON
end

function ItemDB:IsPending(itemID)
    return pending[tonumber(itemID) or 0] == true
end

function ItemDB:Prefetch(ids)
    if type(ids) ~= "table" then return end
    local api = C_Item and C_Item.GetItemInfo
    for _, id in ipairs(ids) do
        id = tonumber(id)
        if id and id > 0 and not (api and api(id)) then
            RequestLoad(id)
        end
    end
end

ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
    itemID = tonumber(itemID)
    if not itemID or not pending[itemID] then return end
    if success == false then
        -- Unknown / invalid item: don't re-request on every UI refresh (that would loop).
        pending[itemID], requestedAt[itemID] = nil, nil
        failedAt[itemID] = GetTime and GetTime() or 0
        return
    end
    -- Only clear once the info is actually readable; otherwise the watchdog keeps it alive.
    local api = C_Item and C_Item.GetItemInfo
    if api and not api(itemID) then return end
    pending[itemID], requestedAt[itemID] = nil, nil
    -- Throttle rather than restart: fire at most every 0.25s while a burst keeps arriving.
    QueueReady()
end)

---------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------

local function Matches(haystack, needle)
    return type(haystack) == "string" and strfind(strlower(haystack), needle, 1, true) ~= nil
end

-- Filters a candidates array by item name (if cached), token name, boss / raid name, or exact itemID;
-- Addendum F rows also by their group (profession, faction, vendor, PvP season), specialisation,
-- standing and faction tag.
function ItemDB:Search(text, candidates)
    local out = {}
    if type(candidates) ~= "table" then return out end
    local needle = strlower(strmatch(tostring(text or ""), "^%s*(.-)%s*$") or "")
    if needle == "" then
        for i = 1, #candidates do out[i] = candidates[i] end
        return out
    end
    local number = tonumber(needle)
    for i = 1, #candidates do
        local row = candidates[i]
        local ref = type(row) == "table" and row.ref
        local hit = false
        if type(row) == "table" then
            if number and row.itemID == number then
                hit = true
            elseif Matches(self:GetName(row.itemID), needle) then
                hit = true
            elseif row.viaItem and Matches(self:GetName(row.viaItem), needle) then
                hit = true
            elseif ref and ref.boss and (Matches(ref.boss.name, needle) or Matches(ref.raid and ref.raid.name, needle)) then
                hit = true
            elseif not ref and (Matches(row.groupName, needle) or Matches(row.subgroup, needle)
                or Matches(row.standing, needle) or Matches(row.faction, needle)) then
                hit = true
            end
        end
        if hit then out[#out + 1] = row end
    end
    return out
end

-- Debug helper: short description of an item's slot / sources.
function ItemDB:Describe(itemID)
    local parts = { tostring(itemID) }
    parts[#parts + 1] = self:GetEquipLoc(itemID) or "not equippable"
    parts[#parts + 1] = self:GetSourceText(itemID) or "no raid source"
    return tconcat(parts, " | ")
end
