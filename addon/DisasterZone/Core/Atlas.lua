if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Atlas.lua", ...) then return end -- DisasterZone: Core/Atlas.lua
-- ns.Atlas: the model behind the Atlas tab (a loot browser like AtlasLoot, for everyone). One browse tree over every
-- item source the addon ships: raids and 5-man dungeons (ns.Data.Raids / ns.Data.Dungeons) followed by
-- Data/Atlas.lua (crafting, reputation, PvP, badge / Sunmote vendors, collections, world events, sets). Also: names
-- for search (ns.Data.AtlasNames, English, so search works before the client has seen an item), where an item can be
-- found, and the BiS targets of an item (a tier token resolves to my class's pieces) for "add to my BiS list".
--
-- Tree: categories { key, name, sources = { { key, name, phase?, kind, size?, instanceID? (raids), pages = { { key,
-- name, items, heroicItems?, x? } } } } }. Item entries: positive = itemID, negative = -spellID (a craft that makes no item, e.g. an enchant),
-- string = a section header inside a page (the Sets pages). Sources / pages of the other faction are left out.
local addonName, ns = ...

local Atlas = ns:NewModule("Atlas")

local type, ipairs, pairs, tonumber, tostring = type, ipairs, pairs, tonumber, tostring
local strlower, strfind, strmatch = string.lower, string.find, string.match
local tconcat = table.concat

local MIN_SEARCH = 2
local DOT = "  ·  "

local tree           -- array of categories (built lazily, rebuilt when the faction becomes known)
local treeSide       -- the faction the tree was built for
local byKey = {}     -- [catKey] = category, [catKey .. "\0" .. srcKey] = source
local index          -- array of { id, cat, src, page, heroic } (first location of every id, tree order)
local locations      -- [id] = { location, ... } (every place an id is listed)
local lowerNames = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Data() return ns.Data or {} end

local function MySide()
    local side = UnitFactionGroup and UnitFactionGroup("player")
    if side == "Alliance" or side == "Horde" then return side end
    return nil
end

local function SideOK(side, mine)
    return side == nil or mine == nil or side == mine
end

local function MyClass()
    local data = ns.BiS and ns.BiS.GetData and ns.BiS:GetData()
    if data and type(data.cl) == "string" and data.cl ~= "" then return data.cl end
    local _, classFile = UnitClass("player")
    return classFile
end

local function NonEmpty(list)
    return type(list) == "table" and #list > 0
end

---------------------------------------------------------------------------
-- Tree
---------------------------------------------------------------------------

local function AddCategory(out, cat)
    if #cat.sources == 0 then return end
    out[#out + 1] = cat
    byKey[cat.key] = cat
    for _, src in ipairs(cat.sources) do
        byKey[cat.key .. "\0" .. src.key] = src
    end
end

local function BuildRaids()
    local cat = { key = "raids", name = "Raids", sources = {} }
    for _, raid in ipairs(Data().Raids or {}) do
        local src = { key = raid.key, name = raid.name, phase = tonumber(raid.phase), kind = "raid", size = raid.size,
                      instanceID = tonumber(raid.instanceID), pages = {} }
        for _, boss in ipairs(raid.bosses or {}) do
            if NonEmpty(boss.items) then
                src.pages[#src.pages + 1] = { key = boss.key, name = boss.name, items = boss.items }
            end
        end
        if #src.pages > 0 then cat.sources[#cat.sources + 1] = src end
    end
    return cat
end

local function BuildDungeons()
    local cat = { key = "dungeons", name = "Dungeons", sources = {} }
    for _, d in ipairs(Data().Dungeons or {}) do
        local src = { key = d.key, name = d.name, phase = tonumber(d.phase), kind = "dungeon", pages = {} }
        for _, boss in ipairs(d.bosses or {}) do
            local normal = NonEmpty(boss.items) and boss.items or nil
            local heroic = NonEmpty(boss.heroicItems) and boss.heroicItems or nil
            if normal or heroic then
                src.pages[#src.pages + 1] = { key = boss.key, name = boss.name, items = normal or {},
                                              heroicItems = heroic }
            end
        end
        if #src.pages > 0 then cat.sources[#cat.sources + 1] = src end
    end
    return cat
end

-- Set pages come one per set ("Paladin (Ret)", title "Lightbringer Battlegear"). The middle column lists classes, so
-- they are grouped into one page per class whose list has a header per spec ("Retribution · Lightbringer Battlegear").
local SPEC_NAMES = {
    Paladin = { Heal = "Holy", Prot = "Protection", Ret = "Retribution" },
    Priest  = { Heal = "Holy and Discipline", Shadow = "Shadow" },
    Druid   = { Heal = "Restoration", Balance = "Balance", Feral = "Feral" },
    Shaman  = { Heal = "Restoration", Elemental = "Elemental", Enh = "Enhancement" },
    Warrior = { DPS = "Arms and Fury", Prot = "Protection" },
}

local function GroupSetsByClass(pages)
    local out, byClass = {}, {}
    for _, p in ipairs(pages) do
        local class, role = strmatch(p.name or "", "^(.-) %((.-)%)$")
        class = class or p.name or "?"
        local page = byClass[class]
        if not page then
            page = { key = class, name = class, items = {}, phase = p.phase, side = p.side }
            byClass[class] = page
            out[#out + 1] = page
        end
        local spec = role and ((SPEC_NAMES[class] and SPEC_NAMES[class][role]) or role) or nil
        local title = p.title or p.name or "?"
        page.items[#page.items + 1] = spec and (spec .. DOT .. title) or title
        for _, id in ipairs(p.items) do page.items[#page.items + 1] = id end
    end
    return out
end

-- Data/Atlas.lua categories, without the other faction's sources and pages.
local function BuildExtra(dataCat, side)
    local cat = { key = dataCat.key, name = dataCat.name, sources = {} }
    for _, s in ipairs(dataCat.sources or {}) do
        if SideOK(s.side, side) and type(s.key) == "string" then
            local src = { key = s.key, name = s.name or s.key, phase = tonumber(s.phase), kind = dataCat.key,
                          side = s.side, factionID = s.factionID, pages = {} }
            for _, p in ipairs(s.pages or {}) do
                if SideOK(p.side, side) and NonEmpty(p.items) then
                    src.pages[#src.pages + 1] = { key = p.key, name = p.name or p.key, title = p.title, items = p.items,
                                                  x = p.x, xt = p.xt, phase = tonumber(p.phase), side = p.side }
                end
            end
            if dataCat.key == "sets" then src.pages = GroupSetsByClass(src.pages) end
            if #src.pages > 0 then cat.sources[#cat.sources + 1] = src end
        end
    end
    return cat
end

local function Build()
    local side = MySide()
    if tree and treeSide == side then return tree end
    byKey, index, locations = {}, nil, nil
    local out = {}
    AddCategory(out, BuildRaids())
    AddCategory(out, BuildDungeons())
    for _, dataCat in ipairs(Data().Atlas or {}) do
        if type(dataCat) == "table" and type(dataCat.key) == "string" and not byKey[dataCat.key] then
            AddCategory(out, BuildExtra(dataCat, side))
        end
    end
    tree, treeSide = out, side
    return tree
end

-- Array of categories (do not modify).
function Atlas:GetCategories()
    return Build()
end

function Atlas:GetCategory(catKey)
    Build()
    return byKey[catKey]
end

function Atlas:GetSource(catKey, srcKey)
    Build()
    return byKey[tostring(catKey) .. "\0" .. tostring(srcKey)]
end

function Atlas:GetPage(catKey, srcKey, pageKey)
    local src = self:GetSource(catKey, srcKey)
    if not src then return nil end
    for i, page in ipairs(src.pages) do
        if page.key == pageKey then return page, i end
    end
    return nil
end

-- The entries a page lists: the heroic list on a dungeon page when asked (and there is one).
function Atlas:GetPageEntries(page, heroic)
    if type(page) ~= "table" then return {} end
    if heroic and NonEmpty(page.heroicItems) then return page.heroicItems end
    return page.items or {}
end

function Atlas:HasHeroic(src)
    if type(src) ~= "table" then return false end
    for _, page in ipairs(src.pages or {}) do
        if NonEmpty(page.heroicItems) then return true end
    end
    return false
end

-- The raid of the guild's phase (the Atlas tab opens there): the first raid of that phase, else the first raid.
function Atlas:DefaultSource()
    local cats = Build()
    local raids = byKey.raids
    if not raids then
        local cat = cats[1]
        return cat and cat.key, cat and cat.sources[1] and cat.sources[1].key
    end
    local phase = ns.Guild and ns.Guild.GetGuildPhase and tonumber(ns.Guild:GetGuildPhase())
    if phase then
        for _, src in ipairs(raids.sources) do
            if src.phase == phase then return "raids", src.key end
        end
    end
    return "raids", raids.sources[1] and raids.sources[1].key
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

local function SpellName(spellID)
    local name = GetSpellInfo and GetSpellInfo(spellID)
    if (type(name) ~= "string" or name == "") and C_Spell and C_Spell.GetSpellName then
        name = C_Spell.GetSpellName(spellID)
    end
    return (type(name) == "string" and name ~= "") and name or nil
end

-- The shipped English name of an entry (nil when Data/Atlas.lua does not know it).
function Atlas:GetShippedName(id)
    local names = Data().AtlasNames
    return names and names[tonumber(id) or 0] or nil
end

-- Display name: the client's own name when it has the item cached (or the spell), else the shipped name.
-- Never asks the server for an item (ItemDB:Prefetch does that for a page that is shown).
function Atlas:GetName(id)
    id = tonumber(id)
    if not id then return nil end
    if id < 0 then
        return SpellName(-id) or self:GetShippedName(id)
    end
    local name
    if C_Item and C_Item.GetItemInfo and (not C_Item.IsItemDataCachedByID or C_Item.IsItemDataCachedByID(id)) then
        name = C_Item.GetItemInfo(id)
    end
    return name or self:GetShippedName(id)
end

---------------------------------------------------------------------------
-- Index & search
---------------------------------------------------------------------------

local function BuildIndex()
    if index and tree and treeSide == MySide() then return end
    Build()
    index, locations = {}, {}
    local tokens, upgrades = Data().Tokens or {}, Data().Upgrades or {}
    local function add(id, cat, src, page, heroic, via, viaKind)
        local loc = { id = id, cat = cat, src = src, page = page, heroic = heroic or nil, via = via, viaKind = viaKind }
        local list = locations[id]
        if not list then
            list = {}
            locations[id] = list
            index[#index + 1] = loc
        end
        list[#list + 1] = loc
    end
    -- an entry, then what it gives: every class's token pieces and the Sunmote upgrade (found under the boss)
    local function addEntry(id, cat, src, page, heroic)
        if type(id) ~= "number" then return end
        add(id, cat, src, page, heroic)
        for _, p in ipairs(type(tokens[id]) == "table" and tokens[id] or {}) do
            add(p, cat, src, page, heroic, id, "token")
        end
        if upgrades[id] then add(upgrades[id], cat, src, page, heroic, id, "upgrade") end
    end
    for _, cat in ipairs(tree) do
        for _, src in ipairs(cat.sources) do
            for _, page in ipairs(src.pages) do
                for _, id in ipairs(page.items or {}) do addEntry(id, cat, src, page, false) end
                for _, id in ipairs(page.heroicItems or {}) do addEntry(id, cat, src, page, true) end
            end
        end
    end
end

-- Every place an id is listed: { { id, cat, src, page, heroic }, ... } (tree order), or nil. Do not modify.
function Atlas:GetLocations(id)
    BuildIndex()
    return locations[tonumber(id) or 0]
end

-- "Prince Malchezaar · Karazhan", "Aeonus · The Black Morass (Heroic)", "Exalted · The Sha'tar",
-- "Tier 4" (a source with a single page of its own name).
function Atlas:LocationText(loc)
    if type(loc) ~= "table" or not loc.src then return nil end
    local page, src = loc.page, loc.src
    local text
    if not page or page.name == src.name or (#src.pages == 1 and page.key == "All") then
        text = src.name
    else
        text = (page.name or "?") .. DOT .. (src.name or "?")
    end
    if loc.heroic then text = text .. " (Heroic)" end
    if loc.viaKind == "token" then
        text = text .. " (token)"
    elseif loc.viaKind == "upgrade" then
        text = text .. " (Sunmote upgrade)"
    end
    return text
end

local function LowerName(id, name)
    local cached = lowerNames[id]
    if cached and cached[1] == name then return cached[2] end
    local low = strlower(name)
    lowerNames[id] = { name, low }
    return low
end

local function Words(text)
    local words = {}
    for w in strlower(text):gmatch("%S+") do words[#words + 1] = w end
    return words
end

local function MatchesAll(hay, words)
    for i = 1, #words do
        if not strfind(hay, words[i], 1, true) then return false end
    end
    return true
end

-- The ids whose name contains every word of text (case-insensitive; an item number finds that item), in tree
-- order: { { id, cat, src, page, heroic, via?, viaKind? }, ... } (first location of each id; every match: the
-- caller decides how many to draw). nil for a text shorter than MIN_SEARCH characters.
function Atlas:Search(text)
    text = strmatch(tostring(text or ""), "^%s*(.-)%s*$") or ""
    local number = tonumber(text)
    if not number and #text < MIN_SEARCH then return nil end
    BuildIndex()
    local out = {}
    if number then
        local list = locations[number] or locations[-number]
        if list then out[1] = list[1] end
        return out
    end
    local words = Words(text)
    local localized = GetLocale and GetLocale() ~= "enUS" and GetLocale() ~= "enGB"
    for _, loc in ipairs(index) do
        local id = loc.id
        local shipped = self:GetShippedName(id)
        local hit = shipped and MatchesAll(LowerName(id, shipped), words)
        if not hit and (localized or not shipped) then
            -- the client's own (cached) name: other locales, or an id Data/Atlas.lua has no name for
            local name = self:GetName(id)
            hit = name and name ~= shipped and MatchesAll(strlower(name), words)
        end
        if hit then out[#out + 1] = loc end
    end
    return out
end

Atlas.MIN_SEARCH = MIN_SEARCH

---------------------------------------------------------------------------
-- My BiS list
---------------------------------------------------------------------------

-- What adding itemID to my BiS list can mean: { { itemID = piece, sids = { sid, ... } }, ... }. A tier token (or a
-- quest item such as Magtheridon's Head) gives the pieces my class can use; any other equippable item itself. Empty
-- when nothing fits a slot (recipes, mounts, ...) or the item is a craft spell.
function Atlas:GetBiSTargets(itemID)
    itemID = tonumber(itemID)
    local out = {}
    local DB = ns.ItemDB
    if not itemID or itemID <= 0 or not DB then return out end
    local data = Data()
    local pieces = data.Tokens and data.Tokens[itemID]
    local class = MyClass()
    local function add(id)
        local sids = DB:GetSlotsForItem(id)
        if #sids > 0 then out[#out + 1] = { itemID = id, sids = sids } end
    end
    if type(pieces) == "table" then
        local tierClass = data.TierPieceClass or {}
        for _, p in ipairs(pieces) do
            local pc = tierClass[p]
            if (pc and pc == class) or (not pc and class and DB:IsUsableBy(p, class) ~= false) then add(p) end
        end
        return out
    end
    add(itemID)
    return out
end

-- Can my class use it at all (class restrictions, armor / weapon proficiency)? nil when unknown.
function Atlas:IsUsableByMe(itemID)
    local DB = ns.ItemDB
    local class = MyClass()
    if not (DB and class) or (tonumber(itemID) or 0) <= 0 then return nil end
    return DB:IsUsableBy(itemID, class)
end

---------------------------------------------------------------------------
-- Token rewards: what a tier token (or a quest item such as Magtheridon's Head) gives me, and Sunmote upgrades
---------------------------------------------------------------------------

local upgradeFrom   -- [upgraded itemID] = base itemID (Data.Upgrades reversed)

-- { { id = otherID, via = itemID, kind = }, ... }: what an item turns into, or comes from:
--   "token"   the pieces of my class a token gives (any class can use the rewards of a quest item)
--   "upgrade" the Sunmote upgrade of a Sunwell drop
--   "base"    the Sunwell drop a Sunmote item is made from
--   "makes"   what a recipe / pattern / plan teaches to make (an item, or a negative spell id for an enchant)
-- Empty for other items.
function Atlas:GetRewards(itemID)
    itemID = tonumber(itemID)
    local out = {}
    if not itemID or itemID <= 0 then return out end
    local data = Data()
    if not upgradeFrom then
        upgradeFrom = {}
        for base, up in pairs(data.Upgrades or {}) do upgradeFrom[up] = base end
    end
    local pieces = data.Tokens and data.Tokens[itemID]
    if type(pieces) == "table" then
        local class = MyClass()
        local tierClass = data.TierPieceClass or {}
        local DB = ns.ItemDB
        for _, p in ipairs(pieces) do
            local pc = tierClass[p]
            if (pc and pc == class) or (not pc and class and DB and DB:IsUsableBy(p, class) ~= false) then
                out[#out + 1] = { id = p, via = itemID, kind = "token" }
            end
        end
    end
    local up = data.Upgrades and data.Upgrades[itemID]
    if up then out[#out + 1] = { id = up, via = itemID, kind = "upgrade" } end
    if upgradeFrom[itemID] then out[#out + 1] = { id = upgradeFrom[itemID], via = itemID, kind = "base" } end
    local makes = data.AtlasRecipes and data.AtlasRecipes[itemID]
    if type(makes) == "number" and makes ~= 0 then out[#out + 1] = { id = makes, via = itemID, kind = "makes" } end
    return out
end

---------------------------------------------------------------------------
-- Crafts (the tooltip's Shift materials)
---------------------------------------------------------------------------

local craftOf          -- [createdItemID] = spellID (built on first use from ns.Data.AtlasCrafts)
local crafts = {}      -- [spellID] = parsed craft, or false

local function ParseCraft(spell)
    local c = crafts[spell]
    if c ~= nil then return c or nil end
    local s = Data().AtlasCrafts and Data().AtlasCrafts[spell]
    c = false
    if type(s) == "string" then
        local nums = {}
        for n in s:gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
        if #nums >= 4 then
            c = { spell = spell, item = nums[1], made = nums[2], reagents = {} }
            for i = 3, #nums - 1, 2 do c.reagents[#c.reagents + 1] = { id = nums[i], count = nums[i + 1] } end
        end
    end
    crafts[spell] = c
    return c or nil
end

-- The craft that makes id (an item id, or -spellID of a craft spell; a recipe / pattern gives the craft it teaches):
-- { spell, item (0: makes none), made (per craft), reagents = { { id, count }, ... } }, or nil. Do not modify.
function Atlas:GetCraft(id)
    id = tonumber(id)
    if not id or id == 0 then return nil end
    if id < 0 then return ParseCraft(-id) end
    local data = Data()
    if not craftOf then
        craftOf = {}
        for spell, s in pairs(data.AtlasCrafts or {}) do
            local item = tonumber(strmatch(s, "^(%d+)"))
            if item and item > 0 then craftOf[item] = spell end
        end
        -- items more than one craft makes: the generator's pick
        for item, spell in pairs(data.AtlasCraftFor or {}) do craftOf[item] = spell end
    end
    if craftOf[id] then return ParseCraft(craftOf[id]) end
    local taught = data.AtlasRecipes and data.AtlasRecipes[id]
    if type(taught) == "number" and taught ~= 0 and taught ~= id then return self:GetCraft(taught) end
    return nil
end

-- Does a page list anything my class can use (gear I can equip, or anything that isn't gear)? Instant data only, so
-- the middle column can hide other classes' pages (a set, a class's arena gear) under Show: My class / a spec.
function Atlas:PageUsable(page, heroic)
    for _, id in ipairs(self:GetPageEntries(page, heroic)) do
        if type(id) == "number" and self:EntryUsable(id) then return true end
    end
    return false
end

-- One entry of PageUsable: an enchant, anything that isn't gear, gear my class can equip, a token with a piece for me.
function Atlas:EntryUsable(id)
    id = tonumber(id)
    if not id then return false end
    if id < 0 then return true end
    local DB = ns.ItemDB
    local class = MyClass()
    if not (DB and class) then return true end
    local tokens = Data().Tokens
    if tokens and tokens[id] then
        for _, r in ipairs(self:GetRewards(id)) do
            if r.kind == "token" then return true end
        end
        return false
    end
    return #DB:GetSlotsForItem(id) == 0 or DB:IsUsableBy(id, class) ~= false
end

---------------------------------------------------------------------------
-- The Show filter: all items, my class (what I can equip), or a spec (judged by the item's stats)
---------------------------------------------------------------------------

-- Stat words of an item's tooltip lines (English client wording), first match per line. Spell variants come before
-- the plain ratings ("spell hit rating" before "hit rating").
local STAT_PATTERNS = {
    { "spell critical strike rating", "scrit" },
    { "spell hit rating", "shit" },
    { "spell haste rating", "shaste" },
    { "spell penetration", "spen" },
    { "healing done by up to", "heal" },                 -- "healing done by up to 44 and damage done by up to 15"
    { "damage and healing done by magical spells", "sp" },
    { "damage done by %a+ spells", "school" },           -- "damage done by Shadow spells and effects"
    { "mana per 5 sec", "mp5" },
    { "attack power", "phys" },
    { "critical strike rating", "phys" },
    { "hit rating", "phys" },
    { "haste rating", "phys" },
    { "expertise rating", "phys" },
    { "of your opponent's armor", "phys" },              -- armor penetration
    { "armor penetration", "phys" },
    { "defense rating", "tank" },
    { "dodge rating", "tank" },
    { "parry rating", "tank" },
    { "block rating", "tank" },
    { "block value", "tank" },
    { "^%+%d+ strength", "phys" },
    { "^%+%d+ agility", "phys" },
    { "^%+%d+ intellect", "int" },
    { "^%+%d+ spirit", "spirit" },
}

local flagCache = {}   -- [itemID] = flags (only for items whose tooltip was complete)
local scanTip

-- The item's tooltip lines below its name, or nil while the client doesn't have the item (a load is requested).
-- Tests replace this function.
function Atlas.ScanItemLines(itemID)
    local cached = C_Item and C_Item.IsItemDataCachedByID and C_Item.IsItemDataCachedByID(itemID)
    if cached == nil then cached = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(itemID) ~= nil end
    if not cached then
        if ns.ItemDB and ns.ItemDB.Prefetch then ns.ItemDB:Prefetch({ itemID }) end
        return nil
    end
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "DisasterZoneAtlasScanTooltip", nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:SetItemByID(itemID)
    local out = {}
    for i = 2, scanTip:NumLines() do
        local fs = _G["DisasterZoneAtlasScanTooltipTextLeft" .. i]
        local text = fs and fs:GetText()
        if type(text) == "string" and text ~= "" then out[#out + 1] = text end
    end
    scanTip:Hide()
    return out
end

-- { phys, sp, school, shit, scrit, shaste, spen, heal, mp5, spirit, int, tank = true } from the item's stats, or nil
-- while unknown. Set bonuses and socket bonuses don't count.
function Atlas:GetStatFlags(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 then return nil end
    local flags = flagCache[itemID]
    if flags then return flags end
    local lines = Atlas.ScanItemLines(itemID)
    if type(lines) ~= "table" then return nil end
    flags = {}
    for _, line in ipairs(lines) do
        local low = strlower(line)
        if not (strfind(low, "^%(") or strfind(low, "^socket bonus")) then
            for _, p in ipairs(STAT_PATTERNS) do
                if strfind(low, p[1]) then
                    flags[p[2]] = true
                    break
                end
            end
        end
    end
    flagCache[itemID] = flags
    return flags
end

-- Does an item with these stat flags serve the role? Items with none of the stats (stamina only, resistances,
-- use-effect trinkets, plain weapons) always do: there is nothing to judge them by.
local function RolePasses(f, role)
    if type(f) ~= "table" or next(f) == nil or not role then return true end
    local caster = f.sp or f.school or f.shit or f.spen or f.scrit or f.shaste
    if role == "melee" or role == "ranged" then
        return f.phys == true
    elseif role == "tank" then
        return (f.tank or f.phys) and true or false
    elseif role == "caster" then
        return (caster or (f.int and not f.phys and not f.heal and not f.mp5 and not f.spirit)) and true or false
    elseif role == "healer" then
        if f.heal or f.mp5 or f.sp or f.spirit then return true end
        if f.phys or f.shit or f.spen or f.school then return false end
        return (f.int or f.scrit or f.shaste) and true or false
    end
    return true
end
Atlas.RolePasses = RolePasses

-- My main spec (the BiS list's spec, else the talents) and my off spec: label, role (each may be nil).
function Atlas:GetMySpecs()
    local BiS = ns.BiS
    local class = MyClass()
    local ms = BiS and BiS.GetSpec and BiS:GetSpec() or ""
    if ms == "" and BiS and BiS.DetectSpec then ms = BiS:DetectSpec() or "" end
    local os = ""
    if BiS and BiS.HasOffSpec and BiS:HasOffSpec() and BiS.GetSpec then os = BiS:GetSpec("os") or "" end
    local msRole = ms ~= "" and ns.GetSpecRole and ns.GetSpecRole(class, ms) or nil
    local osRole = os ~= "" and ns.GetSpecRole and ns.GetSpecRole(class, os) or nil
    return (msRole and ms or nil), msRole, (osRole and os or nil), osRole
end

-- The Show choices: { { value = "all" | "class" | "spec" | "os", text = }, ... } (the specs only when known).
function Atlas:GetShowOptions()
    local ms, _, os = self:GetMySpecs()
    local opts = {
        { value = "all", text = "All items", tooltip = "Everything the source has." },
        { value = "class", text = "My class", tooltip = "Hides what your class can't equip." },
    }
    if ms then
        opts[#opts + 1] = { value = "spec", text = ms,
                            tooltip = ("Also hides gear whose stats don't suit %s (for example spell power for a melee spec)."):format(ms) }
    end
    if os and os ~= ms then
        opts[#opts + 1] = { value = "os", text = os .. " (off spec)",
                            tooltip = ("Gear whose stats suit your off spec, %s."):format(os) }
    end
    return opts
end

-- A Show value that exists for me right now ("spec" without a known spec falls back to "class").
function Atlas:ValidShow(mode)
    local ms, _, os = self:GetMySpecs()
    if mode == "spec" and not ms then return "class" end
    if mode == "os" and not os then return ms and "spec" or "class" end
    if mode ~= "class" and mode ~= "spec" and mode ~= "os" then return "all" end
    return mode
end

-- Does an entry pass the Show filter? Anything that isn't gear (recipes, mounts, enchants ...) always does; a token
-- passes when it gives me a piece that does.
function Atlas:PassesShow(id, mode)
    id = tonumber(id)
    if not id or id <= 0 or mode == "all" or mode == nil then return true end
    local data = Data()
    if data.Tokens and data.Tokens[id] then
        for _, r in ipairs(self:GetRewards(id)) do
            if r.kind == "token" and self:PassesShow(r.id, mode) then return true end
        end
        return false
    end
    local DB = ns.ItemDB
    if not DB or #DB:GetSlotsForItem(id) == 0 then return true end
    local class = MyClass()
    if class and DB:IsUsableBy(id, class) == false then return false end
    if mode == "class" then return true end
    local _, msRole, _, osRole = self:GetMySpecs()
    local role = (mode == "os") and osRole or msRole
    return RolePasses(self:GetStatFlags(id), role)
end

-- Puts itemID (an item that fits sid; a token resolves in BiS:SetSlot) into my list as `which` ("main" | "alt") in
-- `phase`; later = true also fills that position in every later phase where it is still empty. Returns the number
-- of phases that now list the item (0 when nothing changed, e.g. the lists are locked).
function Atlas:AddToBiS(itemID, sid, which, phase, list, later)
    local BiS = ns.BiS
    phase = tonumber(phase)
    if not (BiS and phase) then return 0 end
    which = which == "alt" and "alt" or "main"
    local last = later and (ns.MAX_PHASE or 5) or phase
    local done = 0
    for p = phase, last do
        local main, alt = BiS:GetSlot(p, sid, list)
        local cur = which == "main" and main or alt
        if p == phase or cur == nil or cur == itemID then
            if cur == itemID then
                done = done + 1
            elseif BiS:SetSlot(p, sid, which, itemID, list) then
                done = done + 1
            elseif p == phase then
                return 0   -- refused (locked, doesn't fit): BiS printed why
            end
        end
    end
    return done
end

-- itemID -> { main = { [phase] = true }, alt = { ... }, os = { ... } }: where my lists have each item, the Pre-raid
-- list as phase 0. Tokens count when a piece they give is listed.
function Atlas:GetMyListMarks()
    local marks = {}
    local BiS = ns.BiS
    if not (BiS and BiS.GetPhaseItems) then return marks end
    local function mark(id, kind, phase)
        local m = marks[id]
        if not m then
            m = {}
            marks[id] = m
        end
        m[kind] = m[kind] or {}
        m[kind][phase] = true
    end
    local lists = { { nil, false } }
    if BiS.HasOffSpec and BiS:HasOffSpec() then lists[2] = { "os", true } end
    for _, l in ipairs(lists) do
        for _, p in ipairs(ns.LIST_PHASES or { 1, 2, 3, 4, 5 }) do
            for _, pick in ipairs(BiS:GetPhaseItems(p, l[1]) or {}) do
                local kind = l[2] and "os" or pick.which
                mark(pick.itemID, kind, p)
            end
        end
    end
    -- tokens whose piece is listed
    local tokens = Data().Tokens
    if type(tokens) == "table" then
        for tokenID, pieces in pairs(tokens) do
            if type(pieces) == "table" then
                for _, p in ipairs(pieces) do
                    local m = marks[p]
                    if m then
                        for kind, phases in pairs(m) do
                            for phase in pairs(phases) do mark(tokenID, kind, phase) end
                        end
                    end
                end
            end
        end
    end
    return marks
end

-- "P2", "P2-5", "P1, P3", "Pre-raid, P1-3" for a { [phase] = true } set (0 = the Pre-raid list).
function Atlas:PhasesText(set)
    if type(set) ~= "table" then return "" end
    local list = {}
    for p in pairs(set) do
        if p ~= 0 then list[#list + 1] = p end
    end
    table.sort(list)
    local runs, i = {}, 1
    if set[0] then runs[1] = ns.PhaseLabel and ns.PhaseLabel(0) or "Pre-raid" end
    while i <= #list do
        local j = i
        while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
        runs[#runs + 1] = (i == j) and ("P" .. list[i]) or ("P" .. list[i] .. "-" .. list[j])
        i = j + 1
    end
    return tconcat(runs, ", ")
end

-- The faction changed (or became known): rebuild on next use.
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if tree and treeSide ~= MySide() then tree = nil end
end)
