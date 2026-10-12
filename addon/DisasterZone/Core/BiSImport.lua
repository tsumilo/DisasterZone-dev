if DisasterZoneBoot and DisasterZoneBoot.Run("Core/BiSImport.lua", ...) then return end -- DisasterZone: Core/BiSImport.lua
-- ns.BiSImport: turns a list pasted from another site into BiS picks. Imp:Parse(text) recognises
--   That's My BiS   Guild > Exports > "Just Wishlists" CSV (the whole guild: one character is picked)
--   Sixty Upgrades  a set's export (JSON with character.gameClass and items; Seventy Upgrades moved there)
--   WoWSims         the sim's JSON export, its "Addon" format (our own export too) and Bulk lists
--   Wowhead         a gear planner link (wowhead.com/tbc/gear-planner/class/race/hash)
--   anything else   item links, Wowhead item links, item numbers or item names (a copied table's cells), in order
-- Imp:Plan(parsed, opts) fits the items into the 17 slots: in the source's order each item takes the main of its
-- slot, then the alt (rings, trinkets and one-handers fill both slots' mains first); a slot the source names is
-- tried first. Imp:Preview shows what changes; Imp:Apply writes it with BiS:ApplyTemplate, so tokens, disabled
-- slots and the raid lock behave as everywhere else. Gems and enchants (Sixty Upgrades, WoWSims, Wowhead) come along:
-- plan.setups[list][itemID] = { enchant, gems }, written with BiS:SetGemSetups (Replace: over what the item had; Fill:
-- only items without any).
local addonName, ns = ...

local Imp = ns:NewModule("BiSImport")

local type, tostring, tonumber, pairs, ipairs, next = type, tostring, tonumber, pairs, ipairs, next
local strbyte, strsub, strfind, strlower, strupper, strmatch, strgsub, gmatch = string.byte, string.sub,
    string.find, string.lower, string.upper, string.match, string.gsub, string.gmatch
local tconcat, tsort = table.concat, table.sort
local floor = math.floor

local NUM_SLOTS = 17
local MAX_ITEM_ID = 200000
local MAX_PASTE = 4 * 1024 * 1024
local MAX_ITEMS = 400

Imp.FORMAT_LABELS = {
    tmb = "That's My BiS",
    sixty = "Sixty Upgrades",
    wowsims = "WoWSims",
    wowhead = "Wowhead gear planner",
    items = "Item list",
}

local NOTHING = "Nothing to import found. Paste a That's My BiS export, a Sixty Upgrades or WoWSims export, "
    .. "a Wowhead gear planner link, or item links / numbers."

local function Codec() return ns.Codec end
local function ItemDB() return ns.ItemDB end
local function BiS() return ns.BiS end

local function Trim(s)
    if type(s) ~= "string" then return "" end
    return (strgsub(strgsub(s, "^%s+", ""), "%s+$", ""))
end

local function ItemID(v)
    v = tonumber(v)
    if v and v == floor(v) and v >= 1 and v <= MAX_ITEM_ID then return v end
    return nil
end

local CLASS_FILES = { DRUID = true, HUNTER = true, MAGE = true, PALADIN = true, PRIEST = true, ROGUE = true,
                      SHAMAN = true, WARLOCK = true, WARRIOR = true }

-- "Druid", "PRIEST", "ClassPaladin" (WoWSims), "warlock" -> class file, or nil.
local function ClassFile(s)
    if type(s) ~= "string" then return nil end
    s = strgsub(strgsub(strupper(s), "^CLASS", ""), "[^A-Z]", "")
    return CLASS_FILES[s] and s or nil
end

local function MyClass()
    local data = BiS() and BiS():GetData()
    if data and type(data.cl) == "string" and data.cl ~= "" then return data.cl end
    local _, classFile = UnitClass("player")
    return classFile
end

-- An item that goes into a slot (or a token / quest item that turns into one).
local function Wearable(id)
    local db = ItemDB()
    if not db then return false end
    return (db:IsToken(id) or db:GetEquipLoc(id) ~= nil) and true or false
end

---------------------------------------------------------------------------
-- That's My BiS (CSV: type, raid_group_name, member_name, character_name, character_class, ..., sort_order,
-- item_name, item_id, is_offspec, ...; type = wishlist / received / prio)
---------------------------------------------------------------------------

local TYPE_WORDS = { [119] = "wishlist,", [114] = "received,", [112] = "prio," }   -- by first byte: w, r, p

-- WoW can drop the line breaks of a big paste: start a row before each "wishlist," / "received," / "prio," outside
-- quotes that follows the header, a closing quote, a comma or a digit (the end of the row before).
local function RestoreRows(text)
    local out, n = {}, 0
    local len, start, i = #text, 1, 1
    local inQuote, headerDone = false, false
    while i <= len do
        local c = strbyte(text, i)
        if c == 34 then
            inQuote = not inQuote
            i = i + 1
        elseif not inQuote and TYPE_WORDS[c] and strsub(text, i, i + #TYPE_WORDS[c] - 1) == TYPE_WORDS[c] then
            local prev = i > 1 and strbyte(text, i - 1) or nil
            local split
            if headerDone then
                split = prev == 34 or prev == 44 or (prev ~= nil and prev >= 48 and prev <= 57)
            else
                split = i > 1   -- the first one ends the header
            end
            if split then
                n = n + 1
                out[n] = strsub(text, start, i - 1)
                start = i
                headerDone = true
            end
            i = i + #TYPE_WORDS[c]
        else
            i = i + 1
        end
    end
    n = n + 1
    out[n] = strsub(text, start)
    return tconcat(out, "\n")
end

local function ParseTMB(text)
    if not strfind(text, "\n", 1, true) then text = RestoreRows(text) end
    local rows = Codec().ParseCSV(text)
    local header = rows[1]
    if type(header) ~= "table" then return nil end
    local col = {}
    for i, name in ipairs(header) do col[strlower(Trim(name))] = i end
    if not (col.type and col.character_name and col.item_id) then return nil end
    local byChar, names = {}, {}
    for r = 2, #rows do
        local row = rows[r]
        local kind = strlower(Trim(row[col.type]))
        local name = Trim(row[col.character_name])
        local id = ItemID(Trim(row[col.item_id]))
        if name ~= "" and id and (kind == "wishlist" or kind == "received") then
            local c = byChar[name]
            if not c then
                c = { name = name, class = ClassFile(col.character_class and row[col.character_class]),
                      items = {}, received = {}, nReceived = 0 }
                byChar[name] = c
                names[#names + 1] = name
            end
            if kind == "wishlist" then
                local rank = tonumber(col.sort_order and Trim(row[col.sort_order]))
                c.items[#c.items + 1] = {
                    id = id,
                    rank = (rank and rank > 0) and rank or 100000,
                    os = Trim(col.is_offspec and row[col.is_offspec]) == "1",
                    seq = r,
                }
            elseif not c.received[id] then
                c.received[id] = true
                c.nReceived = c.nReceived + 1
            end
        end
    end
    if #names == 0 then
        return nil, "This That's My BiS export has no wishlists. On thatsmybis.com use Guild > Exports > "
            .. "\"Just Wishlists\" > View CSV and copy all of it."
    end
    tsort(names, function(a, b) return strlower(a) < strlower(b) end)
    for _, c in pairs(byChar) do
        tsort(c.items, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.seq < b.seq
        end)
    end
    return { format = "tmb", characters = names, byChar = byChar }
end

---------------------------------------------------------------------------
-- JSON sets: Sixty Upgrades, WoWSims (sim export, "Addon" format, Bulk / EquipmentSpec lists)
---------------------------------------------------------------------------

local SLOT_NAMES = {
    HEAD = 1, NECK = 2, SHOULDER = 3, SHOULDERS = 3, BACK = 4, CLOAK = 4, CHEST = 5, ROBE = 5, WRIST = 6, WRISTS = 6,
    HAND = 7, HANDS = 7, GLOVES = 7, WAIST = 8, BELT = 8, LEGS = 9, FEET = 10, BOOTS = 10,
    FINGER1 = 11, RING1 = 11, FINGER2 = 12, RING2 = 12, TRINKET1 = 13, TRINKET2 = 14,
    MAINHAND = 15, OFFHAND = 16, RANGED = 17, RELIC = 17, WAND = 17, IDOL = 17, LIBRAM = 17, TOTEM = 17,
}

-- "MAIN_HAND", "Finger 1", "ItemSlotTrinket2" (WoWSims) -> sid, or nil.
local function SlotFromName(s)
    if type(s) ~= "string" then return nil end
    s = strgsub(strgsub(strupper(s), "^ITEMSLOT", ""), "[^A-Z0-9]", "")
    return SLOT_NAMES[s]
end

local function V(v) return Codec().Value(v) end

local function EntryID(e)
    e = V(e)
    if type(e) == "number" then return ItemID(e) end
    if type(e) == "table" then return ItemID(V(e.id) or V(e.itemId) or V(e.item_id)) end
    return nil
end

-- An entry's enchant: a number (WoWSims: the enchant id) or a table (Sixty Upgrades: id / spellId / itemId), as the
-- enchant number item links carry; nil when there is none or DisasterZone doesn't know it.
local function EntryEnchant(e)
    local G = ns.Gems
    local v = V(e.enchant)
    if not G or v == nil then return nil end
    if type(v) == "table" then
        return G:EnchantFromAny(V(v.effectId)) or G:EnchantFromAny(V(v.id)) or G:EnchantFromAny(V(v.spellId))
            or G:EnchantFromAny(V(v.itemId))
    end
    return G:EnchantFromAny(v)
end

-- An entry's gems in socket order (numbers or tables with an id; 0 / null = an empty socket), nil when none.
local function EntryGems(e)
    local list = V(e.gems)
    if type(list) ~= "table" then return nil end
    local out, any = {}, false
    for i = 1, 4 do
        local g = V(list[i])
        if type(g) == "table" then g = V(g.id) or V(g.itemId) end
        g = tonumber(g) or 0
        if g > 0 and ns.Gems and ns.Gems:Gem(g) then
            out[i], any = g, true
        else
            out[i] = 0
        end
    end
    return any and out or nil
end

-- positional: index i is slot i (the WoWSims gear layout is the same 17 slots in the same order as ours).
local function ItemsFrom(list, positional)
    local out = {}
    if type(list) ~= "table" then return out end
    for i, e in ipairs(list) do
        local id = EntryID(e)
        if id and #out < MAX_ITEMS then
            local sid = (positional and i <= NUM_SLOTS) and i or nil
            local item = { id = id }
            if type(e) == "table" and e ~= Codec().NULL then
                sid = SlotFromName(V(e.slot)) or sid
                item.enchant, item.gems = EntryEnchant(e), EntryGems(e)
            end
            item.sid = sid
            out[#out + 1] = item
        end
    end
    return out
end

local function Tbl(v)
    v = V(v)
    return type(v) == "table" and v or nil
end

local function EquipmentOf(player)
    local eq = Tbl(player and (player.equipment or player.gear))
    return eq and Tbl(eq.items)
end

local function ParseJSON(text)
    local v, err = Codec().JSONDecode(text)
    if v == nil then
        return nil, "This looks like a JSON export but it couldn't be read (" .. tostring(err or "?") .. "). "
            .. "Copy the whole export and paste it again."
    end
    v = Tbl(v)
    if not v then return nil, NOTHING end
    -- Sixty Upgrades: { character = { name, gameClass, race }, items = [ { id, name, slot?, enchant, gems } ] }
    local ch = Tbl(v.character)
    if ch and Tbl(v.items) then
        return { format = "sixty", class = ClassFile(V(ch.gameClass) or V(ch.class)), name = V(ch.name),
                 items = ItemsFrom(v.items, false) }
    end
    -- WoWSims "Addon" format (the WowSimsExporter addon and our own export): { class, race, gear = { items } }
    local gear = Tbl(v.gear)
    if gear and Tbl(gear.items) then
        return { format = "wowsims", class = ClassFile(V(v.class)), name = V(v.name), items = ItemsFrom(gear.items, true) }
    end
    -- WoWSims JSON export: { player = { class, equipment = { items } } }; a raid export: its first player with gear
    local player = Tbl(v.player)
    local items = EquipmentOf(player)
    if not items then
        local raid = Tbl(v.raid)
        for _, party in ipairs(raid and Tbl(raid.parties) or {}) do
            for _, p in ipairs(Tbl(party) and Tbl(party.players) or {}) do
                p = Tbl(p)
                if not items and EquipmentOf(p) then
                    player, items = p, EquipmentOf(p)
                end
            end
        end
    end
    if items then
        return { format = "wowsims", class = ClassFile(V(player.class)), name = V(player.name),
                 items = ItemsFrom(items, true) }
    end
    -- a Bulk list / bare EquipmentSpec { items = [...] } (not in slot order), or a plain array of items
    if Tbl(v.items) then return { format = "wowsims", items = ItemsFrom(v.items, false) } end
    if v[1] ~= nil then return { format = "items", items = ItemsFrom(v, false) } end
    return nil, NOTHING
end

---------------------------------------------------------------------------
-- Wowhead gear planner link (the hash format WoWSims reads too: version, level, talents, then the items)
---------------------------------------------------------------------------

local WOWHEAD_CLASSES = { druid = "DRUID", hunter = "HUNTER", mage = "MAGE", paladin = "PALADIN", priest = "PRIEST",
                          rogue = "ROGUE", shaman = "SHAMAN", warlock = "WARLOCK", warrior = "WARRIOR" }

local function SidByInvSlot(inv)
    return ns.INVSLOT_TO_SID[inv]
end

local function ParseWowhead(text)
    local cls, _, hash = strmatch(text, "gear%-planner/([%a%-]+)/([%a%-]+)/([%w_%-]+)")
    if not cls then
        if strmatch(text, "gear%-planner/[%a%-]+/[%a%-]+") then
            return nil, "This Wowhead gear planner link has no items yet: add items on Wowhead, then copy the link again."
        end
        return nil, "This Wowhead link has no gear in it: copy the link of a gear planner set "
            .. "(wowhead.com/tbc/gear-planner/...)."
    end
    local bytes = Codec().Base64Decode(hash)
    if not bytes or #bytes < 1 then return nil, "This Wowhead gear planner link couldn't be read." end
    local i, n = 1, #bytes
    local function B()
        local b = bytes[i] or 0
        i = i + 1
        return b
    end
    local version = B()
    if version >= 4 then
        return nil, "This Wowhead link uses a newer format than DisasterZone knows. Paste the items as a list instead."
    end
    if version > 0 then B() end                 -- level
    if version > 1 then i = i + B() end          -- talents (that many bytes)
    local items = {}
    while n - i + 1 >= 3 and #items < MAX_ITEMS do
        local slot = B()
        local gems, id = 0, 0
        if version >= 3 then
            local e = B()
            gems = floor(e / 32) % 8
            id = (e % 32) * 65536
        end
        id = id + B() * 256
        id = id + B()
        local hasEnchant = floor(slot / 128) % 2 == 1
        local hasRandom = floor(slot / 64) % 2 == 1
        slot = slot % 64
        local enchant
        if hasEnchant then
            local spell = B() * 256
            spell = spell + B()
            enchant = ns.Gems and ns.Gems:EnchantFromAny(spell) or nil
        end
        if hasRandom then i = i + 2 end
        local gemList
        for _ = 1, gems do
            local a = B()
            local g = (a % 32) * 65536
            g = g + B() * 256
            g = g + B()
            local idx = floor(a / 32) % 8 + 1
            if idx <= 4 and ns.Gems and ns.Gems:Gem(g) then
                gemList = gemList or { 0, 0, 0, 0 }
                gemList[idx] = g
            end
        end
        if ItemID(id) then items[#items + 1] = { id = id, sid = SidByInvSlot(slot), enchant = enchant, gems = gemList } end
    end
    return { format = "wowhead", class = WOWHEAD_CLASSES[strlower(cls)], items = items }
end

---------------------------------------------------------------------------
-- Item lists: links, Wowhead item links, numbers, names
---------------------------------------------------------------------------

local nameIndex
local function IdByName(name)
    if type(name) ~= "string" or name == "" then return nil end
    if not nameIndex then
        nameIndex = {}
        local names = ns.Data and ns.Data.AtlasNames
        for id, n in pairs(type(names) == "table" and names or {}) do
            if type(id) == "number" and id > 0 and type(n) == "string" then
                local key = strlower(n)
                local old = nameIndex[key]
                if old == nil then
                    nameIndex[key] = id
                elseif type(old) == "number" then
                    nameIndex[key] = { old, id }
                else
                    old[#old + 1] = id
                end
            end
        end
    end
    local e = nameIndex[strlower(name)]
    if type(e) == "number" then return Wearable(e) and e or nil end
    if type(e) == "table" then
        -- the same name more than once (faction / reputation versions): the lowest wearable item number
        local best
        for _, id in ipairs(e) do
            if Wearable(id) and (not best or id < best) then best = id end
        end
        return best
    end
    return nil
end

-- A cell of a copied table or a list line: "1. Wildfury Greatstaff", "- Band of Eternity (Hyjal)".
local function CleanName(s)
    s = Trim(s)
    s = strgsub(s, "^%d+[%.%)]%s*", "")
    s = strgsub(s, "^[%-%*]%s*", "")
    s = strgsub(s, "^\226\128\162%s*", "")   -- bullet
    s = strgsub(s, "%s*%b()$", "")
    return Trim(s)
end

local function ParseItems(text)
    local items = {}
    local function Add(id)
        id = ItemID(id)
        if id and #items < MAX_ITEMS and Wearable(id) then items[#items + 1] = { id = id } end
    end
    for line in gmatch(text .. "\n", "([^\r\n]*)\r?\n") do
        local before = #items
        for id in gmatch(line, "|Hitem:(%d+)") do Add(id) end
        if #items == before then
            for id in gmatch(line, "item[=/](%d+)") do Add(id) end
        end
        if #items == before then
            for name in gmatch(line, "%[([^%]]+)%]") do Add(IdByName(name)) end
        end
        if #items == before then
            -- 5 or 6 digits: TBC items are 20000 and up, and a year such as 2026 is a real (vanilla) item number
            for id in gmatch(line, "%f[%d](%d%d%d%d%d%d?)%f[%D]") do Add(id) end
        end
        if #items == before and strfind(line, "%a") then
            for cell in gmatch(line .. "\t", "([^\t]*)\t") do Add(IdByName(CleanName(cell))) end
        end
    end
    if #items == 0 then return nil, NOTHING end
    return { format = "items", items = items }
end

---------------------------------------------------------------------------
-- Parse
---------------------------------------------------------------------------

-- text -> parsed (see the format readers), or nil, message (nil, nil for an empty text).
-- parsed: { format, class?, name?, items = { { id, sid? }, ... } } or, for That's My BiS,
-- { format = "tmb", characters = { names }, byChar = { [name] = { class, items = { { id, os, rank } }, received } } }.
function Imp:Parse(text)
    if type(text) ~= "string" then return nil, nil end
    if #text > MAX_PASTE then text = strsub(text, 1, MAX_PASTE) end
    text = Trim(text)
    if text == "" then return nil, nil end
    local parsed, err
    if strfind(text, "gear-planner/", 1, true) then
        parsed, err = ParseWowhead(text)
    elseif strfind(text, "^{") or strfind(text, '^%[%s*[%[{"%d%-]') then   -- not "[Item Name]"
        parsed, err = ParseJSON(text)
    elseif strfind(text, "character_name", 1, true) and strfind(text, "item_id", 1, true) then
        parsed, err = ParseTMB(text)
        if not parsed and not err then parsed, err = ParseItems(text) end
    else
        parsed, err = ParseItems(text)
    end
    if not parsed then return nil, err or NOTHING end
    parsed.label = Imp.FORMAT_LABELS[parsed.format] or parsed.format
    if parsed.items and #parsed.items == 0 then return nil, "This " .. parsed.label .. " export has no items in it." end
    return parsed
end

-- That's My BiS: the character to show first (mine, or the only one), or nil.
function Imp:DefaultCharacter(parsed)
    if type(parsed) ~= "table" or parsed.format ~= "tmb" then return nil end
    local me = strlower(UnitName("player") or "")
    for _, n in ipairs(parsed.characters) do
        if strlower(n) == me then return n end
    end
    if #parsed.characters == 1 then return parsed.characters[1] end
    return nil
end

---------------------------------------------------------------------------
-- Plan: fit the items into the slots
---------------------------------------------------------------------------

-- Every item on the bundled BiS lists of a spec (all phases, Pre-raid included): which tier set a token means for
-- that spec.
local specItemsCache = {}
local function SpecItems(class, spec)
    if type(spec) ~= "string" or spec == "" then return nil end
    local key = tostring(class) .. ":" .. spec
    if specItemsCache[key] ~= nil then return specItemsCache[key] or nil end
    local loon, set = ns.Loon, false
    if loon and loon.IsAvailable and loon:IsAvailable() then
        set = {}
        for _, phase in ipairs(ns.LIST_PHASES or { 1, 2, 3, 4, 5 }) do
            for _, e in pairs(loon:GetTemplate(class, spec, phase) or {}) do
                if type(e) == "table" then
                    for _, id in ipairs(e) do set[tonumber(id) or 0] = true end
                end
            end
        end
    end
    specItemsCache[key] = set
    return set or nil
end

-- A token's piece for my class in each slot. Classes with more than one tier set (a paladin's Fallen Champion helm
-- is a holy, a protection or a retribution helm) take the set on their spec's bundled BiS lists.
local function TokenCandidates(id, class, spec)
    local db, data = ItemDB(), ns.Data or {}
    local pieces, tierClass = data.Tokens and data.Tokens[id], data.TierPieceClass or {}
    local out, ambiguous = {}, false
    for sid = 1, NUM_SLOTS do
        local mine = {}
        for _, p in ipairs(type(pieces) == "table" and pieces or {}) do
            if tierClass[p] == class and db:FitsSlot(p, sid) then mine[#mine + 1] = p end
        end
        if #mine == 1 then
            out[#out + 1] = { sid = sid, item = mine[1] }
        elseif #mine > 1 then
            local onList = SpecItems(class, spec) or {}
            local hit, hits = nil, 0
            for _, p in ipairs(mine) do
                if onList[p] then
                    hit = p
                    hits = hits + 1
                end
            end
            if hits == 1 then out[#out + 1] = { sid = sid, item = hit } else ambiguous = true end
        end
    end
    return out, ambiguous and "tokenspec" or "token"
end

-- { { sid, item } } where the item can go, in slot order (a token: my class's piece per slot), or {}, why.
local function Candidates(id, class, spec)
    local db = ItemDB()
    local out = {}
    if db:IsToken(id) then return TokenCandidates(id, class, spec) end
    local sids = db:GetSlotsForItem(id)
    if #sids == 0 then return out, "slot" end
    for _, sid in ipairs(sids) do
        if db:IsUsableBy(id, class, sid) ~= false then out[#out + 1] = { sid = sid, item = id } end
    end
    return out, "class"
end

local function Place(slots, id, wantSid, class, spec)
    local cands, why = Candidates(id, class, spec)
    if #cands == 0 then return false, why end
    if wantSid then
        for k, c in ipairs(cands) do
            if c.sid == wantSid then
                table.remove(cands, k)
                table.insert(cands, 1, c)
                break
            end
        end
    end
    -- never twice in one slot
    local free = {}
    for _, c in ipairs(cands) do
        local t = slots[c.sid]
        if not (t and (t[1] == c.item or t[2] == c.item)) then free[#free + 1] = c end
    end
    if #free == 0 then return false, "twice" end
    for _, c in ipairs(free) do
        local t = slots[c.sid]
        if not t then
            slots[c.sid] = { c.item, 0, from = { id ~= c.item and id or nil } }
            return true
        end
    end
    for _, c in ipairs(free) do
        local t = slots[c.sid]
        if t[2] == 0 then
            t[2] = c.item
            t.from[2] = id ~= c.item and id or nil
            return true
        end
    end
    return false, "full", cands[1].sid
end

Imp.WHY = {
    token = "a token or quest item without a piece for your class: pick the item yourself",
    tokenspec = "a tier token: choose your spec in My BiS (or pick the piece yourself)",
    slot = "not something you wear (or an item number this client doesn't know)",
    class = "your class can't use it",
    twice = "on the list twice",
    full = "the slot already has a main and an alt pick",
}

-- opts: { character = (That's My BiS) the character, list = "ms" | "os" (the other formats) }.
-- plan: { lists = { ms = { [sid] = { main, alt, from = { tokens } } }, os = ... }, count, unplaced = { { id, list,
-- why, sid? } }, received = { ids on the plan that That's My BiS lists as received } }.
function Imp:Plan(parsed, opts)
    opts = opts or {}
    local plan = { lists = {}, unplaced = {}, count = 0, received = {} }
    if type(parsed) ~= "table" then return plan end
    local entries, received = parsed.items, nil
    local tmb = parsed.format == "tmb"
    if tmb then
        local c = parsed.byChar and parsed.byChar[opts.character or ""]
        entries = c and c.items or {}
        received = c and c.received
    end
    local class = MyClass()
    local bis = BiS()
    local specs = { ms = bis and bis:GetSpec() or "", os = bis and bis:HasOffSpec() and bis:GetSpec("os") or "" }
    for _, e in ipairs(entries or {}) do
        local list = tmb and (e.os and "os" or "ms") or (opts.list == "os" and "os" or "ms")
        local slots = plan.lists[list]
        if not slots then
            slots = {}
            plan.lists[list] = slots
        end
        local ok, why, sid = Place(slots, e.id, e.sid, class, specs[list])
        if ok then
            plan.count = plan.count + 1
            -- the gems / enchant go with the item that took the place (a token's piece)
            if e.enchant or e.gems then
                local placed = e.id
                for _, t in pairs(slots) do
                    if t.from and t.from[1] == e.id then placed = t[1] end
                    if t.from and t.from[2] == e.id then placed = t[2] end
                end
                plan.setups = plan.setups or {}
                plan.setups[list] = plan.setups[list] or {}
                plan.setups[list][placed] = { enchant = e.enchant or 0, gems = e.gems or {} }
                plan.gemCount = (plan.gemCount or 0) + 1
            end
        else
            plan.unplaced[#plan.unplaced + 1] = { id = e.id, list = list, why = why, sid = sid }
        end
    end
    for list, slots in pairs(plan.lists) do
        if next(slots) == nil then plan.lists[list] = nil end
    end
    if received then
        local seen = {}
        for _, slots in pairs(plan.lists) do
            for _, t in pairs(slots) do
                for k = 1, 2 do
                    local id = t[k]
                    if id ~= 0 and not seen[id] and (received[id] or (t.from[k] and received[t.from[k]])) then
                        seen[id] = true
                        plan.received[#plan.received + 1] = id
                    end
                end
            end
        end
        tsort(plan.received)
    end
    return plan
end

-- What the import changes in a phase: rows { list, sid, main, alt, nowMain, nowAlt, state } in list / slot order,
-- state "new" (empty now) | "change" | "same" | "disabled" (skipped) | "clear" (not in the import: Replace
-- empties it); and how many slots "Fill empty slots" and "Replace" would change.
function Imp:Preview(plan, phase)
    local rows, fill, replace = {}, 0, 0
    local bis = BiS()
    if type(plan) ~= "table" or not bis then return rows, 0, 0 end
    for _, list in ipairs({ "ms", "os" }) do
        local slots = plan.lists[list]
        if slots then
            local L = list == "os" and "os" or nil
            for sid = 1, NUM_SLOTS do
                local t = slots[sid]
                local nowMain, nowAlt = bis:GetSlot(phase, sid, L)
                nowMain, nowAlt = nowMain or 0, nowAlt or 0
                local disabled = bis:IsSlotDisabled(phase, sid, L)
                local state
                if t then
                    if disabled then
                        state = "disabled"
                    elseif nowMain == t[1] and nowAlt == t[2] then
                        state = "same"
                    elseif nowMain == 0 then
                        state = "new"
                        fill = fill + 1
                        replace = replace + 1
                    else
                        state = "change"
                        replace = replace + 1
                    end
                elseif (nowMain ~= 0 or nowAlt ~= 0) and not disabled then
                    state = "clear"
                    replace = replace + 1
                end
                if state then
                    rows[#rows + 1] = { list = list, sid = sid, main = t and t[1] or 0, alt = t and t[2] or 0,
                                        nowMain = nowMain, nowAlt = nowAlt, state = state }
                end
            end
        end
    end
    return rows, fill, replace
end

-- Writes the plan into a phase. replace: every list the import fills is replaced (disabled slots stay as they are);
-- else only slots without a main pick are filled. markReceived: That's My BiS's received items count as obtained.
-- Returns the number of slots changed, or false (locked; BiS says why).
function Imp:Apply(plan, phase, replace, markReceived)
    local bis = BiS()
    if type(plan) ~= "table" or not bis then return false end
    if plan.lists.os and not bis:HasOffSpec() then
        if not bis:AddOffSpec("") then return false end
    end
    local changed = 0
    for _, list in ipairs({ "ms", "os" }) do
        local slots = plan.lists[list]
        if slots then
            local L = list == "os" and "os" or nil
            local n = bis:ApplyTemplate(phase, slots, replace and true or false, L)
            if n == false then return false end
            changed = changed + (tonumber(n) or 0)
            -- gems and enchants: over the item's own with Replace, else only items that have none
            local setups = plan.setups and plan.setups[list]
            if setups then
                local view = bis:GetListView(L)
                local write = {}
                for id, s in pairs(setups) do
                    local has = type(view.ge) == "table" and view.ge[id] ~= nil
                    if replace or not has then write[id] = s end
                end
                if next(write) then bis:SetGemSetups(write, L) end
            end
        end
    end
    if markReceived then
        for _, id in ipairs(plan.received) do
            if not bis:IsObtained(id) then bis:SetManualObtained(id, true) end
        end
    end
    return changed
end
