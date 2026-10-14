if DisasterZoneBoot and DisasterZoneBoot.Run("Core/ReserveLR.lua", ...) then return end -- DisasterZone: Core/ReserveLR.lua
-- LootReserve, both ways (1.4.3), on LootReserve's own protocol (github.com/Anonomit/LootReserve Comm.lua, MIT; the
-- copy the tests run against is in the dev kit, dev/thirdparty/LootReserve).
--   Host: while I hold the raid's reserve list (Core/Reserves.lua), players with LootReserve reserve in its own window:
--   I answer their Hello with the session (SessionInfo), take ReserveItem / CancelReserve (answering ReserveResult /
--   CancelReserveResult), tell the raid each item's reservers (ReserveInfo), ask the reservers to roll (RequestRoll)
--   and name the winner (SendWinner). The guild's hard reserves are hidden items there.
--   Reader: when someone else in the raid hosts a LootReserve session, its reserves become my list (read-only, see
--   Reserves:Mirror) so the drop panel and the rolls follow them. While another LootReserve host runs, I don't answer
--   as one (two hosts would confuse LootReserve's clients).
-- Wire: AceComm prefixes "LootReserve" and "LootReserve1".."LootReserve40" (sent round-robin like LootReserve does);
-- a message is `opcode|arg|arg|...|`; opcodes after Hello (3) carry `length|payload`, the payload LibDeflate-deflated
-- and encoded for the addon channel when longer than 20 bytes (length > 0), raw otherwise (length < 0). Names are
-- short names (Ambiguate "short").
local addonName, ns = ...

local ReserveLR = ns:NewModule("ReserveLR")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, select = type, pairs, ipairs, tonumber, tostring, select
local strformat, strsplit, strjoin, strfind = string.format, strsplit, strjoin, string.find
local tconcat, tsort = table.concat, table.sort
local floor, abs, max = math.floor, math.abs, math.max

local PREFIX, PREFIX_MAX = "LootReserve", 40
local OP = { Version = 1, ReportIncompatibleVersion = 2, Hello = 3, SessionInfo = 4, SessionStop = 5,
             SessionReset = 6, ReserveItem = 7, ReserveResult = 8, ReserveInfo = 9, CancelReserve = 10,
             CancelReserveResult = 11, RequestRoll = 12, PassRoll = 13, DeletedRoll = 14, OptOut = 15, OptIn = 16,
             OptResult = 17, OptInfo = 18, SendWinner = 19, ReservesTotalMissing = 20 }
ReserveLR.OP = OP
local LAST_UNCOMPRESSED, MAX_UNCOMPRESSED = 3, 20
local FOREIGN_KEEP = 15 * 60       -- another LootReserve host counts this long after its last message
local INFO_DELAY = 1               -- SessionInfo goes out this long after the last rules change

-- LootReserve's category of a raid key (Data/Raids.lua lr), and the raid key of a category.
local function CategoryOf(rk)
    local DB = ns.ItemDB
    local meta = rk and DB and DB.GetRaidMeta and DB:GetRaidMeta(rk)
    return type(meta) == "table" and meta.lr or nil
end
ReserveLR.CategoryOf = function(_, rk) return CategoryOf(rk) end

local function RaidOfCategory(cat)
    for rk, meta in pairs(ns.Data and ns.Data.RaidMeta or {}) do
        if type(meta) == "table" and meta.lr == cat then return rk end
    end
    return nil
end

-- Reserves' codes as LootReserve's ReserveResult / CancelReserveResult numbers.
local RESERVE_RESULT = { ok = 0, none = 2, foreign = 2, closed = 3, notmember = 4, notloot = 5, held = 5, dupe = 6,
                         full = 7 }
local CANCEL_RESULT = { ok = 0, none = 2, foreign = 2, closed = 3, notmember = 4, notloot = 5, notres = 6 }

local comm = {}                  -- AceComm embed
local nextPrefix = 1
local foreign = {}               -- [host key] = { at, rk, n, open, byItem = { [itemID] = { key } } }
local warnedForeign = {}
local sentRolls = {}             -- [session id] = "asked" | "won"
local LibDeflate

local function R() return ns.Reserves end

local function Short(key)
    return Util.ShortName(key)
end

local function KeyOf(name)
    return Util.NormalizeName(name)
end

local function Enabled()
    local DB = ns.DB
    return not (DB and DB.GetSetting and DB:GetSetting("reserves.lootReserve") == false)
end

---------------------------------------------------------------------------
-- The wire
---------------------------------------------------------------------------

-- The text of one message (LootReserve's SendCommMessage, without sending).
function ReserveLR:Build(opcode, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "boolean" then v = v and 1 or 0 end
        parts[#parts + 1] = tostring(v == nil and "" or v) .. "|"
    end
    local message = tconcat(parts)
    if opcode > LAST_UNCOMPRESSED then
        local length = #message
        if length > MAX_UNCOMPRESSED and LibDeflate then
            message = LibDeflate:EncodeForWoWAddonChannel(LibDeflate:CompressDeflate(message))
        else
            length = -length
        end
        message = length .. "|" .. message
    end
    return opcode .. "|" .. message
end

-- opcode, { fields } of a received text; nil when it can't be read.
function ReserveLR:Parse(text)
    if type(text) ~= "string" then return nil end
    local opcode, message = strsplit("|", text, 2)
    opcode = tonumber(opcode)
    if not opcode or not message then return nil end
    if opcode > LAST_UNCOMPRESSED then
        local length
        length, message = strsplit("|", message, 2)
        length = tonumber(length)
        if not length or not message then return nil end
        if length > 0 then
            if not LibDeflate then return nil end
            message = LibDeflate:DecodeForWoWAddonChannel(message)
            message = message and LibDeflate:DecompressDeflate(message)
        end
        if not message or #message ~= abs(length) then return nil end
    end
    return opcode, { strsplit("|", message) }
end

local function Send(dist, target, opcode, ...)
    if Util.DemoOn() or not comm.SendCommMessage then return end
    local prefix = PREFIX
    if opcode > LAST_UNCOMPRESSED then
        prefix = PREFIX .. nextPrefix
        nextPrefix = nextPrefix % PREFIX_MAX + 1
    end
    local text = ReserveLR:Build(opcode, ...)
    comm:SendCommMessage(prefix, text, dist, target and (Ambiguate and Ambiguate(target, "none") or target) or nil,
        "ALERT")
end

local function Broadcast(opcode, ...)
    if not IsInRaid() then return end
    Send("RAID", nil, opcode, ...)
end

local function Whisper(key, opcode, ...)
    Send("WHISPER", key, opcode, ...)
end

---------------------------------------------------------------------------
-- Host
---------------------------------------------------------------------------

-- Another LootReserve host speaks in my raid (in the last FOREIGN_KEEP seconds): its key.
local function ForeignHost()
    local now = GetTime()
    for key, f in pairs(foreign) do
        if now - f.at <= FOREIGN_KEEP and Util.IsInMyGroup(key) then return key end
    end
    return nil
end
ReserveLR.ForeignHost = function() return ForeignHost() end

-- I answer as LootReserve's host: my own list, the setting on, no other LootReserve host.
local function Hosting()
    local Res = R()
    if not (Res and Res:Get() and Res:IsHost() and Enabled()) or Util.DemoOn() then return false end
    local fh = ForeignHost()
    return fh == nil or Util.IsMe(fh)
end
ReserveLR.Hosting = function() return Hosting() end

local function Totals()
    local Res = R()
    local missing, _, total = Res:Missing()
    return total, #missing
end

-- SessionInfo's fields for target (nil: the raid).
function ReserveLR:SessionInfoFields(starting)
    local Res = R()
    local L = Res:Get()
    local members, opt = {}, {}
    local keys = Util.GetGroupKeys()
    tsort(keys)
    for _, key in ipairs(keys) do
        members[#members + 1] = strformat("%s=%d,%d", Short(key), Res:Left(key), L.n or 1)
        opt[#opt + 1] = Short(key) .. "=0"
    end
    local items = {}
    for itemID, list in pairs(Res:ByItem()) do
        local names = {}
        for i, key in ipairs(list) do names[i] = Short(key) end
        items[#items + 1] = itemID .. "=" .. tconcat(names, ",")
    end
    tsort(items)
    local cond = {}
    for _, id in ipairs(L.h or {}) do cond[#cond + 1] = id .. "=-" end
    local total, missing = Totals()
    return starting == true, L.at or 0, L.o and true or false, tconcat(members, ";"),
        tostring(CategoryOf(L.rk) or ""), "0.00", 0, tconcat(items, ";"), tconcat(cond, ";"), false, false, 1,
        tconcat(opt, ";"), total, missing
end

local function SendSessionInfo(target, starting)
    if not Hosting() then return end
    if target then
        Whisper(target, OP.SessionInfo, ReserveLR:SessionInfoFields(starting))
    else
        Broadcast(OP.SessionInfo, ReserveLR:SessionInfoFields(starting))
    end
end

local function SendReserveInfo(itemID)
    if not Hosting() then return end
    local names = {}
    for i, key in ipairs(R():Reservers(itemID)) do names[i] = Short(key) end
    local total, missing = Totals()
    Broadcast(OP.ReserveInfo, itemID, tconcat(names, ","), total, missing)
end

local function Remaining(key)
    local Res = R()
    local L = Res:Get()
    if L and not L.o then return "#" end
    return Res:Left(key)
end

local HostHandlers = {}

HostHandlers[OP.Hello] = function(key)
    if Util.IsMe(key) then return end
    SendSessionInfo(key, true)
    -- a roll for this player's reserve is open: ask again
    local Roll = ns.Roll
    local ses = Roll and Roll.GetActive and Roll:GetActive()
    if ses and ses.isLocal and ses.rv == "s" and type(ses.rk) == "table" then
        for _, k in ipairs(ses.rk) do
            if k == key then
                Whisper(key, OP.RequestRoll, ses.i .. ",0", Short(key), false, strformat("%.2f", ses.duration or 0),
                    ses.duration or 0, "", false, false, false)
            end
        end
    end
end

HostHandlers[OP.ReserveItem] = function(key, f)
    local itemID = tonumber(f[1])
    if not itemID then return end
    local ok, code = R():AddFor(key, itemID, "l")
    Whisper(key, OP.ReserveResult, itemID, RESERVE_RESULT[code] or 5, Remaining(key), false)
end

HostHandlers[OP.CancelReserve] = function(key, f)
    local itemID = tonumber(f[1])
    if not itemID then return end
    local ok, code = R():CancelFor(key, itemID)
    Whisper(key, OP.CancelReserveResult, itemID, CANCEL_RESULT[code] or 6, Remaining(key), 1, false)
end

HostHandlers[OP.OptOut] = function(key)
    Whisper(key, OP.OptResult, 0, false)
end
HostHandlers[OP.OptIn] = HostHandlers[OP.OptOut]

HostHandlers[OP.PassRoll] = function(key, f)
    local Roll = ns.Roll
    local itemID = tonumber((strsplit(",", f[1] or "")))
    local ses = Roll and Roll.GetActive and Roll:GetActive()
    if ses and ses.i == itemID and Roll.NoteRemotePass then Roll:NoteRemotePass(ses.id, key) end
end

---------------------------------------------------------------------------
-- Reader: someone else's LootReserve session
---------------------------------------------------------------------------

local function MirrorFrom(host)
    local f = foreign[host]
    if not f then return end
    local byKey = {}
    for itemID, keys in pairs(f.byItem) do
        for _, key in ipairs(keys) do
            local t = byKey[key]
            if not t then
                t = {}
                byKey[key] = t
            end
            t[#t + 1] = itemID
        end
    end
    R():Mirror(host, f.rk, f.n, f.open, {}, byKey)
end

local function NoteForeign(host)
    local f = foreign[host]
    if not f then
        f = { at = GetTime(), byItem = {}, n = 1, open = false }
        foreign[host] = f
    end
    f.at = GetTime()
    local Res = R()
    if Res and Res:Get() and Res:IsHost() and not Res:IsForeign() and not warnedForeign[host] and not Util.IsMe(host) then
        warnedForeign[host] = true
        ns:Print("%s runs a LootReserve session in this raid: players with LootReserve see theirs, not yours.",
            Short(host))
    end
    return f
end

local ReadHandlers = {}

ReadHandlers[OP.SessionInfo] = function(host, f)
    local fi = NoteForeign(host)
    fi.open = tonumber(f[3]) == 1
    local refs = {}
    for entry in (f[4] or ""):gmatch("[^;]+") do
        local name, info = strsplit("=", entry, 2)
        refs[#refs + 1] = name
        local maxRes = tonumber((select(2, strsplit(",", info or ""))))
        if maxRes and maxRes > 0 then fi.n = maxRes end
    end
    local cat = tonumber((strsplit(";", f[5] or "")))
    fi.rk = cat and RaidOfCategory(cat) or fi.rk
    fi.byItem = {}
    for entry in (f[8] or ""):gmatch("[^;]+") do
        local id, list = strsplit("=", entry, 2)
        id = tonumber(id)
        if id and list then
            local keys = {}
            for ref in list:gmatch("[^,]+") do
                local name = tonumber(ref) and refs[tonumber(ref)] or ref
                local key = name and KeyOf(name)
                if key then keys[#keys + 1] = key end
            end
            fi.byItem[id] = keys
        end
    end
    MirrorFrom(host)
end

ReadHandlers[OP.ReserveInfo] = function(host, f)
    local fi = foreign[host]
    if not fi then return end
    fi.at = GetTime()
    local id = tonumber(f[1])
    if not id then return end
    local keys = {}
    for name in (f[2] or ""):gmatch("[^,]+") do
        local key = KeyOf(name)
        if key then keys[#keys + 1] = key end
    end
    fi.byItem[id] = #keys > 0 and keys or nil
    MirrorFrom(host)
end

ReadHandlers[OP.SessionStop] = function(host)
    local fi = foreign[host]
    if not fi then return end
    fi.open = false
    MirrorFrom(host)
end

ReadHandlers[OP.SessionReset] = function(host)
    foreign[host] = nil
    R():Unmirror(host)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function OnComm(prefix, text, dist, sender)
    if Util.DemoOn() or not Enabled() then return end
    local key = KeyOf(sender)
    if not key or not Util.IsInMyGroup(key) then return end
    local opcode, f = ReserveLR:Parse(text)
    if not opcode then return end
    local Res = R()
    local L = Res:Get()
    -- a host's broadcasts: theirs is the session to read. Not the DisasterZone host's own (I have that list from it
    -- already), not my own while I hold a list (that's me answering as a host).
    if ReadHandlers[opcode] then
        local fromListHost = L and not L.foreign and L.by == key
        local mineEcho = Util.IsMe(key) and L and not L.foreign
        if not fromListHost and not mineEcho then ReadHandlers[opcode](key, f) end
        return
    end
    if HostHandlers[opcode] and Hosting() and not Util.IsMe(key) then
        HostHandlers[opcode](key, f)
    end
end

---------------------------------------------------------------------------
-- Following the list and the rolls
---------------------------------------------------------------------------

local infoPending = false
local function QueueInfo(starting)
    if infoPending then return end
    infoPending = true
    Util.After(INFO_DELAY, function()
        infoPending = false
        SendSessionInfo(nil, starting)
    end)
end

local function OnRollStarted(ses)
    if not (Hosting() and type(ses) == "table" and ses.isLocal and not ses.demo) then return end
    if ses.rv == "s" and type(ses.rk) == "table" and #ses.rk > 1 then
        local names = {}
        for i, key in ipairs(ses.rk) do names[i] = Short(key) end
        sentRolls[ses.id] = "asked"
        Broadcast(OP.RequestRoll, ses.i .. ",0", tconcat(names, ","), false, strformat("%.2f", ses.duration or 0),
            ses.duration or 0, "", false, false, false)
    end
end

local function OnRollUpdated(id)
    local Roll = ns.Roll
    local ses = Roll and Roll.Get and Roll:Get(id)
    if not (Hosting() and type(ses) == "table" and ses.isLocal and not ses.demo and ses.rv) then return end
    if ses.state ~= "awarded" or sentRolls[ses.id] == "won" or type(ses.winner) ~= "string" then return end
    sentRolls[ses.id] = "won"
    local losers = {}
    for key in pairs(ses.rolls or {}) do
        if key ~= ses.winner then losers[#losers + 1] = Short(key) end
    end
    tsort(losers)
    local roll = ses.rolls and ses.rolls[ses.winner] and ses.rolls[ses.winner].roll or ""
    Broadcast(OP.SendWinner, ses.i .. ",0", Short(ses.winner), tconcat(losers, ","), roll, ses.rv == "o", "", false)
end

function ReserveLR:OnInit()
    LibDeflate = LibStub and LibStub("LibDeflate", true)
    local AceComm = LibStub and LibStub("AceComm-3.0", true)
    if AceComm then
        AceComm:Embed(comm)
        comm:RegisterComm(PREFIX, OnComm)
        for i = 1, PREFIX_MAX do comm:RegisterComm(PREFIX .. i, OnComm) end
    end
    ns:On("RESERVES_OPENED", function() QueueInfo(true) end)
    ns:On("RESERVES_CLOSED", function() QueueInfo(false) end)
    ns:On("RESERVES_CLEARED", function()
        if not Util.DemoOn() and Enabled() and not ForeignHost() and R():IsHost() then Broadcast(OP.SessionReset) end
    end)
    ns:On("RESERVE_ADDED", function(_, itemID) SendReserveInfo(itemID) end)
    ns:On("RESERVE_REMOVED", function(_, itemID) SendReserveInfo(itemID) end)
    ns:On("RESERVES_RULES", function() QueueInfo(false) end)
    ns:On("ROLL_STARTED", OnRollStarted)
    ns:On("ROLL_UPDATED", OnRollUpdated)
end

-- (tests) forget the other hosts seen
function ReserveLR:_Reset()
    foreign, warnedForeign, sentRolls = {}, {}, {}
end
