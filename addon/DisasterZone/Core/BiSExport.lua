if DisasterZoneBoot and DisasterZoneBoot.Run("Core/BiSExport.lua", ...) then return end -- DisasterZone: Core/BiSExport.lua
-- ns.BiSExport: my gear or a BiS phase as text other sites read.
--   Exp:WoWSims(specs)    the JSON the WowSimsExporter addon makes (wowsims.com/tbc: Import > Addon): class, race,
--                         level, talents, professions and the 17 slots with enchants and gems
--   Exp:Bulk(phase, list) a phase's main and alt picks as a WoWSims Bulk list ({"items":[...]}, Bulk tab > Import)
--   Exp:WowheadLink(specs) a Wowhead TBC gear planner link (Wowhead wants an enchant's spell: a planned enchant the
--                         Atlas knows the craft of goes in, a worn one (only its enchant number) is left out; gems stay)
-- specs come from Exp:EquippedSpecs() (what I wear, read from the item links) or Exp:PhaseSpecs(phase, list) (the
-- phase's main picks; a slot that is empty or disabled keeps what I wear, like the My BiS model; a pick with gems /
-- an enchant chosen in My BiS has those, else a pick I wear keeps its own).
local addonName, ns = ...

local Exp = ns:NewModule("BiSExport")

local type, tostring, tonumber, ipairs, pairs = type, tostring, tonumber, ipairs, pairs
local strlower, strmatch, strgsub, gmatch = string.lower, string.match, string.gsub, string.gmatch
local tconcat, tsort = table.concat, table.sort
local floor, ceil = math.floor, math.ceil

local NUM_SLOTS = 17
local WOWHEAD_PLANNER = "https://www.wowhead.com/tbc/gear-planner/"

-- The professions WoWSims knows (any other name makes its import fail), by skill line.
local SIM_PROFESSIONS = {
    [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering", [182] = "Herbalism",
    [773] = "Inscription", [755] = "Jewelcrafting", [165] = "Leatherworking", [186] = "Mining", [393] = "Skinning",
    [197] = "Tailoring",
}

local WOWHEAD_RACES = { BloodElf = "blood-elf", NightElf = "night-elf", Scourge = "undead", Undead = "undead",
                        Draenei = "draenei", Dwarf = "dwarf", Gnome = "gnome", Human = "human", Orc = "orc",
                        Tauren = "tauren", Troll = "troll" }

-- Rings, trinkets and weapons: the other slot of the pair (a pick I wear in the other ring slot still has its gems).
local PAIR = ns.SLOT_PAIR

local function Codec() return ns.Codec end
local function BiS() return ns.BiS end

---------------------------------------------------------------------------
-- Item specs { id, enchant?, gems? = { item ids, 0 for an empty socket before a filled one }, suffix? }
---------------------------------------------------------------------------

-- "|cff...|Hitem:id:enchant:gem1:gem2:gem3:gem4:suffix:...|h[Name]|h|r" -> spec, or nil.
function Exp:SpecFromLink(link)
    if type(link) ~= "string" then return nil end
    local s = strmatch(link, "item:([%-%d:]+)")
    if not s then return nil end
    local f = {}
    for v in gmatch(s .. ":", "([^:]*):") do f[#f + 1] = v end
    local id = tonumber(f[1])
    if not id or id <= 0 then return nil end
    local spec = { id = id }
    local enchant = tonumber(f[2])
    if enchant and enchant > 0 then spec.enchant = enchant end
    local last = 0
    for g = 1, 4 do
        local gem = tonumber(f[2 + g])
        if gem and gem > 0 then last = g end
    end
    if last > 0 then
        spec.gems = {}
        for g = 1, last do
            local gem = tonumber(f[2 + g])
            spec.gems[g] = (gem and gem > 0) and gem or 0
        end
    end
    local suffix = tonumber(f[7])
    if suffix and suffix ~= 0 then spec.suffix = suffix end
    return spec
end

-- [sid] = spec of what I wear (nil: nothing in that slot).
function Exp:EquippedSpecs()
    local out = {}
    for sid, slot in ipairs(ns.SLOTS or {}) do
        out[sid] = self:SpecFromLink(GetInventoryItemLink("player", slot.invSlot))
    end
    return out
end

-- The spec to export for a BiS pick: its gems / enchant chosen in My BiS; else what I wear when it is the same item
-- (this slot or its pair); else the item.
local function PickSpec(itemID, sid, worn, list)
    local bis = BiS()
    if bis and bis.GetGemSetup then
        local enchant, gems = bis:GetGemSetup(itemID, list)
        if enchant ~= 0 or next(gems) ~= nil then
            local spec = { id = itemID }
            if enchant ~= 0 then
                spec.enchant = enchant
                local e = ns.Gems and ns.Gems:Enchant(enchant)
                spec.enchantSpell = e and e.craft or nil
            end
            local last = 0
            for g = 1, 4 do if (gems[g] or 0) > 0 then last = g end end
            if last > 0 then
                spec.gems = {}
                for g = 1, last do spec.gems[g] = gems[g] or 0 end
            end
            return spec
        end
    end
    local w = worn[sid]
    if w and w.id == itemID then return w end
    local pair = PAIR[sid]
    w = pair and worn[pair]
    if w and w.id == itemID then return w end
    return { id = itemID }
end

local function IsTwoHander(spec)
    local db = ns.ItemDB
    return spec and db and db:GetEquipLoc(spec.id) == "INVTYPE_2HWEAPON" or false
end

-- [sid] = spec for a phase's main picks; second result: how many slots kept what I wear.
function Exp:PhaseSpecs(phase, list)
    local bis = BiS()
    local worn = self:EquippedSpecs()
    local out, kept = {}, 0
    local picked = {}
    for sid = 1, NUM_SLOTS do
        local main = bis:GetSlot(phase, sid, list)
        if main and not bis:IsSlotDisabled(phase, sid, list) then
            out[sid] = PickSpec(main, sid, worn, list)
            picked[sid] = true
        elseif worn[sid] then
            out[sid] = worn[sid]
            kept = kept + 1
        end
    end
    -- a two-handed pick leaves the off hand empty (not the off-hand item I wear now)
    if picked[15] and not picked[16] and out[16] and IsTwoHander(out[15]) then
        out[16] = nil
        kept = kept - 1
    end
    return out, kept
end

---------------------------------------------------------------------------
-- Character
---------------------------------------------------------------------------

-- Talent ranks per tree, talents in tier then column order (as the WowSimsExporter addon writes them):
-- "05032001-0000-500" ("" when the client has no talents to read).
function Exp:TalentString()
    if not (GetNumTalentTabs and GetNumTalents and GetTalentInfo) then return "" end
    local tabs, any = {}, false
    for tab = 1, tonumber(GetNumTalentTabs()) or 0 do
        local list = {}
        for i = 1, tonumber(GetNumTalents(tab)) or 0 do
            local name, _, tier, column, rank, _, _, available = GetTalentInfo(tab, i)
            if name and available and tonumber(tier) and tonumber(column) then
                list[#list + 1] = { pos = (tier - 1) * 4 + column, rank = tonumber(rank) or 0 }
            end
        end
        tsort(list, function(a, b) return a.pos < b.pos end)
        local ranks = {}
        for k, t in ipairs(list) do ranks[k] = tostring(t.rank) end
        if #ranks > 0 then any = true end
        tabs[tab] = tconcat(ranks)
    end
    if not any then return "" end
    return tconcat(tabs, "-")
end

-- { { name = "Mining", level = 375 }, ... }: my professions WoWSims knows (from the Members tab's data).
function Exp:Professions()
    local out = {}
    local P = ns.Professions
    local mine = P and P.GetMember and ns.Util and P:GetMember(ns.Util.PlayerKey())
    for _, e in ipairs(type(mine) == "table" and mine or {}) do
        local name = SIM_PROFESSIONS[e.id]
        if name then out[#out + 1] = { name = name, level = tonumber(e.rank) or 0 } end
    end
    return out
end

local function Me()
    local name, realm
    if UnitFullName then name, realm = UnitFullName("player") end
    name = name or UnitName("player") or ""
    if (realm == nil or realm == "") and GetRealmName then realm = GetRealmName() end
    local _, raceFile = UnitRace("player")
    local _, classFile = UnitClass("player")
    return {
        name = name,
        realm = realm or "",
        raceFile = raceFile or "Human",
        race = (raceFile == "Scourge") and "Undead" or (raceFile or "Human"),
        class = classFile or "WARRIOR",
        level = tonumber(UnitLevel("player")) or 70,
    }
end

---------------------------------------------------------------------------
-- Formats
---------------------------------------------------------------------------

local function SimItem(spec)
    local it = { id = spec.id }
    if spec.enchant then it.enchant = spec.enchant end
    if spec.gems then it.gems = spec.gems end
    if spec.suffix then it.random_suffix = spec.suffix end
    return it
end

-- The WoWSims "Addon" import text (the WowSimsExporter addon's JSON). WoWSims notes that this isn't its exporter
-- addon's version (a warning, the import still works).
function Exp:WoWSims(specs)
    local me = Me()
    local items = {}
    for sid = 1, NUM_SLOTS do
        local spec = specs and specs[sid]
        items[sid] = spec and SimItem(spec) or Codec().NULL
    end
    local spec = BiS() and BiS():GetSpec() or ""
    local doc = {
        version = "DisasterZone " .. tostring(ns.version or "?"),
        unit = "player",
        name = me.name,
        realm = me.realm,
        race = me.race,
        class = strlower(me.class),
        level = me.level,
        talents = self:TalentString(),
        professions = self:Professions(),
        spec = strgsub(strlower(spec or ""), "[^%a]+", "_"),
        gear = { items = items },
    }
    return Codec().JSONEncode(doc)
end

-- A phase's main and alt picks (each item once, worn ones with their gems / enchant) as a WoWSims Bulk list.
-- Returns the text and the number of items.
function Exp:Bulk(phase, list)
    local bis = BiS()
    local worn = self:EquippedSpecs()
    local items, seen = {}, {}
    for sid = 1, NUM_SLOTS do
        if not bis:IsSlotDisabled(phase, sid, list) then
            local main, alt = bis:GetSlot(phase, sid, list)
            for _, id in ipairs({ main or 0, alt or 0 }) do
                if id > 0 and not seen[id] then
                    seen[id] = true
                    items[#items + 1] = SimItem(PickSpec(id, sid, worn, list))
                end
            end
        end
    end
    return Codec().JSONEncode({ items = items }), #items
end

-- Wowhead's planner hash: version 3, level, talents (a digit per talent, 15 after each tree, two per byte), then
-- each item: slot (+64 with a random suffix), gem count and item id (3 bytes), the suffix (2 bytes), the gems.
local function TalentBytes(talents, bytes)
    local trees = {}
    for t in gmatch((talents or "") .. "--", "([^%-]*)%-") do trees[#trees + 1] = t end
    local nib = {}
    for k = 1, 3 do
        for d in gmatch(trees[k] or "", "%d") do nib[#nib + 1] = tonumber(d) end
        nib[#nib + 1] = 15
    end
    bytes[#bytes + 1] = ceil(#nib / 2)
    for e = 1, #nib, 2 do bytes[#bytes + 1] = nib[e] * 16 + (nib[e + 1] or 0) end
end

function Exp:WowheadLink(specs)
    local me = Me()
    local bytes = { 3, me.level }
    TalentBytes(self:TalentString(), bytes)
    local order = {}
    for sid = 1, NUM_SLOTS do
        if specs and specs[sid] then order[#order + 1] = sid end
    end
    tsort(order, function(a, b) return ns.SLOTS[a].invSlot < ns.SLOTS[b].invSlot end)
    for _, sid in ipairs(order) do
        local spec = specs[sid]
        local bits = ns.SLOTS[sid].invSlot
        if spec.suffix then bits = bits + 64 end
        if spec.enchantSpell then bits = bits + 128 end
        bytes[#bytes + 1] = bits
        local gems = {}
        for idx, g in ipairs(spec.gems or {}) do
            if g > 0 then gems[#gems + 1] = { idx - 1, g } end
        end
        local id = spec.id
        bytes[#bytes + 1] = ((#gems % 8) * 32 + floor(id / 65536)) % 256
        bytes[#bytes + 1] = floor(id / 256) % 256
        bytes[#bytes + 1] = id % 256
        if spec.enchantSpell then
            bytes[#bytes + 1] = floor(spec.enchantSpell / 256) % 256
            bytes[#bytes + 1] = spec.enchantSpell % 256
        end
        if spec.suffix then
            local v = spec.suffix % 65536
            bytes[#bytes + 1] = floor(v / 256)
            bytes[#bytes + 1] = v % 256
        end
        for _, g in ipairs(gems) do
            bytes[#bytes + 1] = ((g[1] % 8) * 32 + floor(g[2] / 65536)) % 256
            bytes[#bytes + 1] = floor(g[2] / 256) % 256
            bytes[#bytes + 1] = g[2] % 256
        end
    end
    local race = WOWHEAD_RACES[me.raceFile] or strlower(me.raceFile)
    return WOWHEAD_PLANNER .. strlower(me.class) .. "/" .. race .. "/" .. Codec().Base64Encode(bytes, true)
end
