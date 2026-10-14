if DisasterZoneBoot and DisasterZoneBoot.Run("Core/ReserveIO.lua", ...) then return end -- DisasterZone: Core/ReserveIO.lua
-- Loot reserves in and out (1.4.3) for Core/Reserves.lua's list.
--   Import (pasted text, recognised by its shape):
--     softres.it CSV (Item, ItemId, From, Name, Class, Spec, Note, Date ...), LootReserve's CSV (Player, Class, Plus,
--     ExtraReserves, RollBonus, Item, Count), any CSV with a name and an item (id) column, Gargul's own CSV
--     (itemID,player1,player2 per row, no header), and the softres.it "Gargul" export (Base64 of zlib-packed JSON:
--     softreserves[] { name, class, items[] { id } }, hardreserves[] { id }). Hard reserves join the guild's.
--   Export: CSV (softres.it columns), LootReserve's CSV, the Gargul string, and raid chat lines.
--   The wrap-up: each roll reserves decided, who reserved the item, who got it and how (Reserves:WrapUp).
local addonName, ns = ...

local ReserveIO = ns:NewModule("ReserveIO")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, select = type, pairs, ipairs, tonumber, tostring, select
local strlower, strmatch, strformat, strgsub, strfind, strsub, strchar, strbyte = string.lower, string.match,
    string.format, string.gsub, string.find, string.sub, string.char, string.byte
local tsort, tconcat = table.sort, table.concat
local min = math.min

local MAX_ROWS = 400
local MAX_TEXT = 200000

local function R() return ns.Reserves end
local function Codec() return ns.Codec end

local function Clean(s)
    return Util.Trim(strgsub(tostring(s or ""), "^\239\187\191", ""))   -- (a UTF-8 BOM)
end

local function KeyOf(name)
    name = Clean(name)
    if name == "" or strfind(name, "[%c|,;]") then return nil end
    name = strgsub(name, "^%l", string.upper)
    return Util.NormalizeName(name)
end

local function ClassOf(key)
    local unit = Util.GetPartyUnit and Util.GetPartyUnit(key)
    if unit then
        local _, file = UnitClass(unit)
        if file then return file end
    end
    return ""
end

local function ItemFromCell(cell, rk)
    cell = Clean(cell)
    local id = tonumber(cell)
    if id then return id end
    local Chat = ns.ReserveChat
    return Chat and Chat.FindItem and (Chat:FindItem(cell, rk)) or nil
end

---------------------------------------------------------------------------
-- Import
---------------------------------------------------------------------------

local NAME_COLS = { name = true, player = true, character = true, ["player name"] = true }
local ID_COLS = { itemid = true, ["item id"] = true, ["item_id"] = true, id = true }
local ITEM_COLS = { item = true, ["item name"] = true, itemname = true }

local function FromCSV(rows, rk)
    local entries = {}
    local head = rows[1] or {}
    local cols = {}
    for i, c in ipairs(head) do cols[strlower(Clean(c))] = i end
    local nameCol, idCol, itemCol
    for k, i in pairs(cols) do
        if NAME_COLS[k] then nameCol = nameCol or i end
        if ID_COLS[k] then idCol = idCol or i end
        if ITEM_COLS[k] then itemCol = itemCol or i end
    end
    local skipped = 0
    if nameCol and (idCol or itemCol) then
        for r = 2, #rows do
            local row = rows[r]
            local key = KeyOf(row[nameCol])
            local id = (idCol and tonumber(Clean(row[idCol]))) or (itemCol and ItemFromCell(row[itemCol], rk))
            if key and id then entries[#entries + 1] = { key, id } elseif #row > 1 then skipped = skipped + 1 end
        end
        return entries, skipped, "csv"
    end
    -- Gargul's CSV: itemID,player1,player2,... (no header)
    for _, row in ipairs(rows) do
        local id = tonumber(Clean(row[1]))
        if id then
            for c = 2, #row do
                local key = KeyOf(row[c])
                if key then entries[#entries + 1] = { key, id } end
            end
        elseif #row > 1 then
            skipped = skipped + 1
        end
    end
    return entries, skipped, "gargulcsv"
end

local function BytesToString(bytes)
    local parts = {}
    for i = 1, #bytes, 4000 do
        parts[#parts + 1] = strchar(unpack(bytes, i, min(#bytes, i + 3999)))
    end
    return tconcat(parts)
end

local function StringToBytes(s)
    local out = {}
    for i = 1, #s do out[i] = strbyte(s, i) end
    return out
end

local function FromGargul(text)
    local C = Codec()
    local LD = LibStub and LibStub("LibDeflate", true)
    if not (C and LD) then return nil end
    local bytes = C.Base64Decode(Clean(text))
    if not bytes or #bytes < 4 then return nil end
    local raw = LD:DecompressZlib(BytesToString(bytes))
    if not raw then return nil end
    local data = C.JSONDecode(raw)
    if type(data) ~= "table" then return nil end
    local entries, held = {}, {}
    for _, sr in ipairs(type(data.softreserves) == "table" and data.softreserves or {}) do
        local key = type(sr) == "table" and KeyOf(sr.name)
        for _, it in ipairs(key and type(sr.items) == "table" and sr.items or {}) do
            local id = tonumber(type(it) == "table" and it.id or it)
            if id then entries[#entries + 1] = { key, id } end
        end
    end
    for _, hr in ipairs(type(data.hardreserves) == "table" and data.hardreserves or {}) do
        local id = tonumber(type(hr) == "table" and hr.id or hr)
        if id then held[#held + 1] = id end
    end
    return entries, held
end

-- Reads pasted text: entries { { key, itemID } }, held { itemID }, info { format = "csv" | "gargul" | "gargulcsv",
-- skipped = n }; nil, message when nothing in it can be read.
function ReserveIO:Read(text, rk)
    if type(text) ~= "string" then return nil, "Nothing pasted." end
    if #text > MAX_TEXT then return nil, "That is too long to be a reserve list." end
    local t = Clean(text)
    if t == "" then return nil, "Nothing pasted." end
    if not strfind(t, "[,;\t\n]") then
        local entries, held = FromGargul(t)
        if entries then return entries, held, { format = "gargul", skipped = 0 } end
        return nil, "That isn't a softres.it, Gargul or LootReserve export."
    end
    local C = Codec()
    local sep = strfind(t, "\t") and not strfind(t, ",") and "\t" or nil
    if sep then t = strgsub(t, "\t", ",") end
    local rows = C and C.ParseCSV and C.ParseCSV(t, MAX_ROWS) or {}
    if #rows == 0 then return nil, "That isn't a softres.it, Gargul or LootReserve export." end
    local entries, skipped, format = FromCSV(rows, rk)
    if #entries == 0 then return nil, "No reserves found (it needs a name and an item column)." end
    return entries, {}, { format = format, skipped = skipped }
end

-- Imports pasted text into the list (the host): ok, summary text.
function ReserveIO:Import(text)
    local Res = R()
    local L = Res and Res:Get()
    if not (L and Res:IsHost()) then return false, "Open reserves first." end
    local entries, held, info = self:Read(text, L.rk)
    if not entries then return false, held end
    local added, refused = Res:Import(entries, held)
    local parts = { strformat("%d reserve%s imported", added, added == 1 and "" or "s") }
    if #held > 0 then parts[#parts + 1] = strformat("%d hard reserve%s held for the guild", #held,
        #held == 1 and "" or "s") end
    if #refused > 0 then parts[#parts + 1] = strformat("%d skipped (full, held or not this raid's loot)", #refused) end
    if (info.skipped or 0) > 0 then parts[#parts + 1] = strformat("%d row%s unreadable", info.skipped,
        info.skipped == 1 and "" or "s") end
    return true, tconcat(parts, " · "), refused
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------

local function Quote(s)
    s = tostring(s or "")
    if strfind(s, "[,\"\n]") then return "\"" .. strgsub(s, "\"", "\"\"") .. "\"" end
    return s
end

local function NameOf(itemID)
    local DB = ns.ItemDB
    local n = DB and DB.GetName and DB:GetName(itemID)
    if n then return n end
    local names = ns.Data and ns.Data.AtlasNames
    return names and names[itemID] or tostring(itemID)
end

-- Every reserve as { key, itemID }, sorted by item then name.
local function Rows()
    local out = {}
    for itemID, keys in pairs(R():ByItem()) do
        for _, key in ipairs(keys) do out[#out + 1] = { key, itemID } end
    end
    tsort(out, function(a, b)
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[1] < b[1]
    end)
    return out
end

-- format: "csv" (softres.it columns) | "lootreserve" | "gargul"
function ReserveIO:Export(format)
    local L = R():Get()
    if not L then return "" end
    local loot = R():RaidLoot(L.rk)
    local DB = ns.ItemDB
    local lines = {}
    if format == "lootreserve" then
        lines[1] = "Player,Class,Plus,ExtraReserves,RollBonus,Item,Count"
        for _, row in ipairs(Rows()) do
            lines[#lines + 1] = tconcat({ Quote(Util.ShortName(row[1])), ClassOf(row[1]), "0", "0", "0", row[2], "1" }, ",")
        end
        return tconcat(lines, "\n")
    elseif format == "gargul" then
        local C = Codec()
        local LD = LibStub and LibStub("LibDeflate", true)
        if not (C and LD) then return "" end
        local by = {}
        for _, row in ipairs(Rows()) do
            local t = by[row[1]]
            if not t then
                t = { name = Util.ShortName(row[1]), class = strlower(ClassOf(row[1])), note = "", plusOnes = 0, items = {} }
                by[row[1]] = t
            end
            t.items[#t.items + 1] = { id = row[2] }
        end
        local soft, keys = {}, {}
        for key in pairs(by) do keys[#keys + 1] = key end
        tsort(keys)
        for _, key in ipairs(keys) do soft[#soft + 1] = by[key] end
        local hard = {}
        for _, id in ipairs(L.h or {}) do hard[#hard + 1] = { id = id, ["for"] = "guild", note = "" } end
        local json = C.JSONEncode({ metadata = { id = L.id, createdAt = L.at or 0 }, softreserves = soft,
                                    hardreserves = hard })
        return C.Base64Encode(StringToBytes(LD:CompressZlib(json)))
    end
    lines[1] = "Item,ItemId,From,Name,Class"
    for _, row in ipairs(Rows()) do
        local boss = loot[row[2]]
        local ref = boss and DB and DB.GetBossRef and DB:GetBossRef(L.rk .. ":" .. boss)
        local from = (type(ref) == "table" and ref.boss and ref.boss.name) or boss or ""
        lines[#lines + 1] = tconcat({ Quote(NameOf(row[2])), row[2], Quote(from), Quote(Util.ShortName(row[1])),
                                      ClassOf(row[1]) }, ",")
    end
    return tconcat(lines, "\n")
end

-- The list for raid chat: lines of "[item] A, B · [item] C".
function ReserveIO:ChatLines()
    local Chat = ns.ReserveChat
    local parts = {}
    local by = R():ByItem()
    local ids = {}
    for id in pairs(by) do ids[#ids + 1] = id end
    tsort(ids)
    for _, id in ipairs(ids) do
        local names = {}
        for i, key in ipairs(by[id]) do names[i] = Util.ShortName(key) end
        parts[#parts + 1] = Chat:Link(id) .. " " .. tconcat(names, ", ")
    end
    if #parts == 0 then return { "No reserves yet." } end
    return Chat:Pack("Reserves: ", parts, " · ")
end

---------------------------------------------------------------------------
-- Wrap-up
---------------------------------------------------------------------------

-- The night's rolls decided by reserves: { { itemID, kind = "s" | "g" | "o", reservers = { key }, winner = key or nil,
-- roll = n or nil, how = text } } in roll order.
function ReserveIO:WrapUp()
    local Roll = ns.Roll
    local out = {}
    for _, ses in ipairs(Roll and Roll.ReserveSessions and Roll:ReserveSessions() or {}) do
        local row = { itemID = ses.i, kind = ses.rv, reservers = ses.rk or {}, winner = ses.winner, state = ses.state }
        local r = ses.winner and ses.rolls and ses.rolls[ses.winner]
        row.roll = r and not r.invalid and r.roll or nil
        if ses.rv == "s" then
            row.how = #row.reservers == 1 and "only reserve" or "reserve roll"
        elseif ses.rv == "g" then
            row.how = "loot council"
        else
            row.how = "up for grabs"
        end
        out[#out + 1] = row
    end
    return out
end

-- The wrap-up for raid chat: "[item] -> Winner (how)".
function ReserveIO:WrapUpLines()
    local Chat = ns.ReserveChat
    local parts = {}
    for _, row in ipairs(self:WrapUp()) do
        if row.winner then
            parts[#parts + 1] = strformat("%s %s (%s%s)", Chat:Link(row.itemID), Util.ShortName(row.winner), row.how,
                row.roll and (" " .. row.roll) or "")
        end
    end
    if #parts == 0 then return { "No reserved loot handed out yet." } end
    return Chat:Pack("Loot tonight: ", parts, " · ")
end
