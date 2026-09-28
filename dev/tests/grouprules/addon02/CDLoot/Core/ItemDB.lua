-- CDLoot: item database access (ns.ItemDB).
-- Indexes over ns.Data (bosses, sources, tokens, upgrades), slot / class filtering,
-- picker candidates, drop expansion and an async item-info cache.
-- 5-man dungeons (ns.Data.Dungeons, Addendum B §21.2) are indexed alongside the raids: their bosses
-- are bossRefs with ref.dungeon = true (ref.raid is the dungeon table) and their sources carry
-- heroic = true when the item is only on the heroic list.
local addonName, ns = ...

local ItemDB = ns:NewModule("ItemDB")

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local strlower, strfind, strmatch = string.lower, string.find, string.match
local tconcat = table.concat

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
        if type(info) == "table" and type(info.items) == "table" then
            for _, pieceID in ipairs(info.items) do AppendUnique(arenaToTokens, pieceID, tokenID) end
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

local sourceCache = { all = {}, raids = {}, dungeons = {} }

local function Scope(scope)
    if scope == "raids" or scope == "dungeons" then return scope end
    return "all"
end

-- Array of { ref=, via=nil|"token"|"upgrade"|"arena", viaItem=, heroic=true|nil }: raid sources
-- (direct first, then via token / Sunmote / arena exchange), then 5-man dungeon sources (normal before
-- heroic-only). scope (optional): "raids" | "dungeons" | "all" (default).
-- The returned array is cached and shared: do not modify it.
function ItemDB:GetSources(itemID, scope)
    itemID = tonumber(itemID)
    if not itemID or itemID ~= itemID then return {} end
    scope = Scope(scope)
    local cache = sourceCache[scope]
    local cached = cache[itemID]
    if cached then return cached end
    BuildIndex()

    local out, seenRef = {}, {}
    local function Add(refs, via, viaItem)
        for _, ref in ipairs(refs or EMPTY) do
            if not seenRef[ref] then
                seenRef[ref] = true
                out[#out + 1] = { ref = ref, via = via, viaItem = viaItem }
            end
        end
    end

    if scope ~= "dungeons" then
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
    if scope ~= "raids" then
        for _, src in ipairs(dungeonSources[itemID] or EMPTY) do
            if not seenRef[src.ref] then
                seenRef[src.ref] = true
                out[#out + 1] = { ref = src.ref, heroic = src.heroic or nil }
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

-- "Prince Malchezaar · Karazhan", "Token · Prince Malchezaar · Karazhan", "... +1 more";
-- 5-man: "Aeonus · The Black Morass", "Aeonus · The Black Morass (Heroic)" (heroic list only).
-- short=true drops the raid / dungeon name ("Aeonus (H)"). nil when the item has no known source.
function ItemDB:GetSourceText(itemID, short)
    local sources = self:GetSources(itemID)
    local first = sources[1]
    if not first then return nil end
    local text = BossLabel(first.ref, short, first.heroic)
    local prefix = first.via and VIA_PREFIX[first.via]
    if prefix then
        text = prefix .. " · " .. text
    end
    if #sources > 1 then
        text = text .. " +" .. (#sources - 1) .. " more"
    end
    return text
end

-- Lowest raid phase among all sources (incl. via token / upgrade / arena), or nil.
function ItemDB:GetPhase(itemID)
    local best
    for _, src in ipairs(self:GetSources(itemID)) do
        local p = src.ref.phase
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
    local arena = data.TokenArenaExchanges and data.TokenArenaExchanges[itemID]
    if type(arena) == "table" then
        for _, id in ipairs(arena.items or EMPTY) do Add(id) end
    end
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

local SCOPE_RAIDS, SCOPE_DUNGEONS = { true, false }, { false, true }
local SCOPE_ALL = { true, true }

-- Array of { itemID=, ref=bossRef, via=nil|"token"|"upgrade", viaItem=, heroic=true|nil } in
-- raid -> boss -> item order (dungeons after raids for scope "all").
-- filter = { scope = "raids" (default) | "dungeons" | "all", maxPhase=, phase=, class=, usableOnly=,
--            primaryArmorOnly=, includeTrash=true, includeUpgrades=true }. The phase filters apply to
-- dungeons too (their phase). Deduped by itemID (first source wins). Rows are fresh tables.
function ItemDB:GetCandidates(sid, filter)
    sid = tonumber(sid)
    local out = {}
    if not sid or not ns.SLOTS[sid] then return out end
    filter = type(filter) == "table" and filter or EMPTY
    local raidRows, dungeonRows = BuildSlotRows()
    local scope = (filter.scope == "dungeons" and SCOPE_DUNGEONS) or (filter.scope == "all" and SCOPE_ALL) or SCOPE_RAIDS

    local maxPhase = tonumber(filter.maxPhase)
    local exactPhase = tonumber(filter.phase)
    local class = filter.class
    local includeTrash = filter.includeTrash ~= false
    local includeUpgrades = filter.includeUpgrades ~= false
    local seen = {}

    local function Scan(rows)
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
            if ok and class and filter.usableOnly and self:IsUsableBy(id, class, sid) == false then
                ok = false
            end
            if ok and class and filter.primaryArmorOnly and not self:IsPrimaryArmor(id, class) then
                ok = false
            end
            if ok then
                seen[id] = true
                out[#out + 1] = { itemID = id, ref = ref, via = row.via, viaItem = row.viaItem,
                                  heroic = row.heroic and true or nil }
            end
        end
    end

    if scope[1] then Scan(raidRows[sid]) end
    if scope[2] then Scan(dungeonRows[sid]) end
    return out
end

---------------------------------------------------------------------------
-- Item info (async; the client caches it)
---------------------------------------------------------------------------

local pending = {}    -- [itemID] = true while a load request is outstanding
local failedAt = {}   -- [itemID] = GetTime() of a failed load (not retried for a while)
local RETRY_FAILED_AFTER = 60

local function RequestLoad(itemID)
    if pending[itemID] then return end
    local failed = failedAt[itemID]
    if failed and GetTime and (GetTime() - failed) < RETRY_FAILED_AFTER then return end
    pending[itemID] = true
    if C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end
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

local function FireItemInfoReady()
    ns:Fire("ITEMINFO_READY")
end

ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
    itemID = tonumber(itemID)
    if not itemID or not pending[itemID] then return end
    pending[itemID] = nil
    if success == false then
        -- Unknown / invalid item: don't re-request on every UI refresh (that would loop).
        failedAt[itemID] = GetTime and GetTime() or 0
        return
    end
    -- Throttle rather than restart: fire at most every 0.25s while a burst keeps arriving.
    if not ns.Util.IsDebouncePending("iteminfo") then
        ns.Util.Debounce("iteminfo", 0.25, FireItemInfoReady)
    end
end)

---------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------

local function Matches(haystack, needle)
    return type(haystack) == "string" and strfind(strlower(haystack), needle, 1, true) ~= nil
end

-- Filters a candidates array by item name (if cached), token name, boss / raid name, or exact itemID.
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
