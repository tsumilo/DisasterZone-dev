if DisasterZoneBoot and DisasterZoneBoot.Run("Core/BiS.lua", ...) then return end -- DisasterZone: Core/BiS.lua
-- The player's own BiS list: record model, edits, commit/rev, spec detection,
-- owned-item scanning (equipped / bags / bank / held tokens) and drop matching.
-- Addendum F §36: disabled slots (data.dx = { [phase] = { [sid] = true } }, omitted when empty; the picks
-- of a disabled slot are kept). §38: while the raid's loot authority has locked the BiS lists
-- (GroupRules:IsLocked()), every editing API refuses; obtained / equipped scanning still works.
-- Addendum H: an optional off-spec list next to the main-spec one. It is stored flat so older clients' validators
-- (max nesting depth) accept it: data.os = off-spec label ("" = off spec added, spec not chosen yet), data.op =
-- its phases (same shape as ph), data.ox = its disabled slots (same shape as dx). All three are omitted while the
-- player has no off spec. Every edit / query API takes an optional trailing `list` ("ms" default, or "os").
-- Pre-raid (phase 0, ns.PRE_RAID): every list API also takes phase 0. Its picks are stored flat next to the raid
-- phases, because released validators only accept ph / dx phases 1..5 but let unknown top-level keys through:
-- data.pr = { [sid] = { main, alt } } (like one phase of ph), data.px = { [sid] = true } (like one phase of dx), and
-- data.opr / data.opx for the off spec; omitted when empty. The obtained list (ob) and the council's view stay on
-- the raid phases; drop matching includes Pre-raid only when asked (MatchItem opts.preRaid, my own tooltip).
-- Gems and enchants (DisasterZone 1.3.2): per item of a list, shared by its phases, flat for the same reason:
-- data.ge = { [itemID] = "enchant:gem1:gem2:gem3" } (numbers, 0 = none, trailing zeros dropped; gems in the item's
-- socket order), data.oge for the off spec; omitted when empty. Core/Gems.lua knows sockets, gems and enchants.
local addonName, ns = ...

local BiS = ns:NewModule("BiS")
local Util = ns.Util

local floor, max, min = math.floor, math.max, math.min
local tsort = table.sort

local NUM_SLOTS = 17
local MAX_PHASE = 5
local PRE_RAID = 0
local MAX_ITEM_ID = 200000
local MAX_OB = 200
local MAX_REV = ns.MAX_REV or 2147483647
local MAX_STR = 24
local LIST_VERSION = 1
local BANK_CONTAINER_ID = -1

-- Scan state (session only; the bank snapshot is persisted in record.bank)
local equipped = {}     -- [itemID] = count currently equipped
local bags = {}         -- [itemID] = count in bags
local tokenCovers = {}  -- [pieceID] = tokenID for tokens / quest items the player holds
local bankOpen = false
local scanPending = false
local commitPending = false
local tempRecord        -- throwaway record used only before PLAYER_LOGIN
local checkedRecord     -- the saved record already sanitized this session
local lockNoticeAt      -- GetTime() of the last "lists are locked" print (at most one per 3 s)
local LOCK_NOTICE_INTERVAL = 3

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function IsValidItemID(id)
    return type(id) == "number" and id == floor(id) and id >= 1 and id <= MAX_ITEM_ID
end

-- A raid phase (the keys of ph / dx).
local function IsValidPhase(p)
    return type(p) == "number" and p == floor(p) and p >= 1 and p <= (ns.MAX_PHASE or MAX_PHASE)
end

-- A phase the list APIs take: Pre-raid (0) or a raid phase.
local function IsListPhase(p)
    return p == PRE_RAID or IsValidPhase(p)
end

local function IsValidSid(sid)
    return type(sid) == "number" and sid == floor(sid) and sid >= 1 and sid <= NUM_SLOTS
end

local SlotLabel = ns.SlotLabel

local function ItemLabel(itemID)
    local db = ns.ItemDB
    return db and db:GetLabel(itemID) or ("item " .. tostring(itemID))
end

local function ItemFits(itemID, sid)
    if ns.ItemDB and ns.ItemDB.FitsSlot then
        return ns.ItemDB:FitsSlot(itemID, sid) and true or false
    end
    return true
end

local function ExpandDrop(itemID)
    if ns.ItemDB and ns.ItemDB.ExpandDrop then
        local list = ns.ItemDB:ExpandDrop(itemID)
        if type(list) == "table" then return list end
    end
    return { itemID }
end

local function IsToken(itemID)
    return ns.ItemDB and ns.ItemDB.IsToken and ns.ItemDB:IsToken(itemID) or false
end

local function Contains(list, value)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

-- How a dropped item leads to a wanted item (nil when it is the item itself).
local function ViaOf(dropID, wantedID)
    if dropID == wantedID then return nil end
    local data = ns.Data
    if data then
        if data.Tokens and Contains(data.Tokens[dropID], wantedID) then return "token" end
        if data.Upgrades and data.Upgrades[dropID] == wantedID then return "upgrade" end
        local ex = data.TokenArenaExchanges and data.TokenArenaExchanges[dropID]
        if type(ex) == "table" and Contains(ex.items, wantedID) then return "arena" end
    end
    return "token"
end

local function SameKeys(a, b)
    for k in pairs(a) do
        if b[k] == nil then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function SameArray(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function SameMap(a, b)
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k, v in pairs(b) do
        if a[k] ~= v then return false end
    end
    return true
end

local function PlayerClass()
    local _, classFile = UnitClass("player")
    return classFile
end

-- The tier pieces of my class a token (or quest item such as Magtheridon's Head) can be exchanged for.
local function MyTokenPieces(tokenID)
    local data = ns.Data
    local pieces = data and data.Tokens and data.Tokens[tokenID]
    local tierClass = data and data.TierPieceClass
    local class = PlayerClass()
    local out = {}
    if type(pieces) == "table" and tierClass and class then
        for _, p in ipairs(pieces) do
            if tierClass[p] == class then out[#out + 1] = p end
        end
    end
    return out
end

-- Addendum H: the table an edit of `list` works on. The main spec edits data itself (ph / dx / pr / px); the off
-- spec a stand-in { ph = data.op, dx = data.ox, pr = data.opr, px = data.opx } that StoreList writes back (empty
-- tables are dropped again).
local function NonEmpty(t)
    return (type(t) == "table" and next(t) ~= nil) and t or nil
end

local function ListTable(data, list)
    if list ~= "os" then return data end
    return {
        ph = type(data.op) == "table" and data.op or {}, dx = type(data.ox) == "table" and data.ox or nil,
        pr = type(data.opr) == "table" and data.opr or nil, px = type(data.opx) == "table" and data.opx or nil,
        ge = type(data.oge) == "table" and data.oge or nil,
    }
end

local function StoreList(data, list, L)
    if list ~= "os" then
        data.ge = NonEmpty(data.ge)
        return
    end
    data.op, data.ox = NonEmpty(L.ph), NonEmpty(L.dx)
    data.opr, data.opx = NonEmpty(L.pr), NonEmpty(L.px)
    data.oge = NonEmpty(L.ge)
    -- picks imply the off spec exists
    if data.os == nil and (data.op or data.ox or data.opr or data.opx) then data.os = "" end
end

-- The one accessor per kind for a list table L (data, or ListTable's stand-in): the picks { [sid] = { main, alt } }
-- and the disabled slots { [sid] = true } of a phase, Pre-raid (L.pr / L.px) or a raid phase (L.ph[p] / L.dx[p]).
-- The setters drop empty tables, so an empty phase is never stored (same hash as before).
local function PhaseSlots(L, phase)
    local t
    if phase == PRE_RAID then t = L.pr else t = L.ph[phase] end
    return type(t) == "table" and t or nil
end

local function SetPhaseSlots(L, phase, slots)
    slots = NonEmpty(slots)
    if phase == PRE_RAID then L.pr = slots else L.ph[phase] = slots end
end

local function PhaseDisabled(L, phase)
    local t
    if phase == PRE_RAID then
        t = L.px
    else
        local dx = L.dx
        t = type(dx) == "table" and dx[phase] or nil
    end
    return type(t) == "table" and t or nil
end

local function SetPhaseDisabled(L, phase, slots)
    slots = NonEmpty(slots)
    if phase == PRE_RAID then
        L.px = slots
        return
    end
    if slots then
        if type(L.dx) ~= "table" then L.dx = {} end
        L.dx[phase] = slots
    elseif type(L.dx) == "table" then
        L.dx[phase] = nil
        if next(L.dx) == nil then L.dx = nil end   -- omitted when empty (same hash as before 0.4)
    end
end

-- Disabled slot (Addendum F §36): data.dx[phase][sid] == true (Pre-raid: data.px[sid]).
local function IsDisabled(data, phase, sid)
    local p = PhaseDisabled(data, phase)
    return (p and p[sid] == true) and true or false
end

-- Group-rule lock (Addendum F §38): locked, lockInfo {by, at} (nil when unlocked).
local function LockState()
    local GR = ns.GroupRules
    if not (GR and GR.IsLocked and GR:IsLocked()) then return false, nil end
    local info = GR.GetLockInfo and GR:GetLockInfo() or nil
    return true, info
end

-- true (and prints, at most once per 3 s) when the lists are locked: the caller refuses the edit.
local function RefuseLocked()
    local locked, info = LockState()
    if not locked then return false end
    local now = GetTime()
    if not lockNoticeAt or now - lockNoticeAt >= LOCK_NOTICE_INTERVAL then
        lockNoticeAt = now
        local by = type(info) == "table" and info.by or nil
        if by and Util.IsMe(by) then
            ns:Print("BiS lists are locked by you during the raid (/dz unlock to edit).")
        else
            ns:Print("BiS lists are locked by %s during the raid.", by and Util.ShortName(by) or "the raid leader")
        end
    end
    return true
end

-- A token is never a pick itself (it is never "obtained" once exchanged): resolve it to the one
-- piece of my class that fits the slot, or nil when there is none or more than one.
local function ResolveToken(itemID, sid)
    local found
    for _, p in ipairs(MyTokenPieces(itemID)) do
        if ItemFits(p, sid) then
            if found then return nil end
            found = p
        end
    end
    return found
end

---------------------------------------------------------------------------
-- Record model
---------------------------------------------------------------------------

local function NewData()
    return { v = LIST_VERSION, cl = PlayerClass() or "", sp = "", ph = {}, ob = {}, eq = {} }
end

local function NewRecord()
    local data = NewData()
    data.sp = BiS:DetectSpec()
    return { rev = 0, highestSeenRev = 0, ts = 0, hash = "", data = data, manual = {}, bank = {}, bankTs = 0 }
end

-- One phase's picks { [sid] = { main, alt } }: repaired in place. Returns the table, or nil when it is empty / not a
-- table (omitted).
local function SanitizeSlots(slots)
    if type(slots) ~= "table" then return nil end
    for sid, s in pairs(slots) do
        local main = type(s) == "table" and tonumber(s[1]) or 0
        local alt = type(s) == "table" and tonumber(s[2]) or 0
        if not IsValidItemID(main) then main = 0 end
        if not IsValidItemID(alt) or alt == main then alt = 0 end
        if not IsValidSid(sid) or (main == 0 and alt == 0) then
            slots[sid] = nil
        elseif s[1] ~= main or s[2] ~= alt then
            slots[sid] = { main, alt }
        end
    end
    return NonEmpty(slots)
end

-- Phases table { [phase] = { [sid] = { main, alt } } } (raid phases 1..5): repaired in place.
local function SanitizePhases(ph)
    for phase, slots in pairs(ph) do
        if not IsValidPhase(phase) then
            ph[phase] = nil
        else
            ph[phase] = SanitizeSlots(slots)
        end
    end
end

-- One phase's disabled slots { [sid] = true }: sids 1..17, true values only. Returns the table, or nil when it is
-- empty / not a table (omitted).
local function SanitizeDisabledSlots(slots)
    if type(slots) ~= "table" then return nil end
    for sid, v in pairs(slots) do
        if not IsValidSid(sid) or v ~= true then slots[sid] = nil end
    end
    return NonEmpty(slots)
end

-- Disabled slots { [phase] = { [sid] = true } }: phases 1..5, sids 1..17, true values only. Returns the table, or
-- nil when it is empty / not a table (omitted).
local function SanitizeDisabled(dx)
    if type(dx) ~= "table" then return nil end
    for phase, slots in pairs(dx) do
        if not IsValidPhase(phase) then
            dx[phase] = nil
        else
            dx[phase] = SanitizeDisabledSlots(slots)
        end
    end
    return NonEmpty(dx)
end

-- One gem / enchant setup "enchant:gem1:gem2:gem3" (numbers, 0 = none): the canonical string (trailing zeros dropped),
-- or nil when it is empty or malformed.
local MAX_GEMS = 4
local function CanonGems(s)
    if type(s) ~= "string" or #s > 40 or not s:match("^%d+[%d:]*$") then return nil end
    local parts = {}
    for n in (s .. ":"):gmatch("([^:]*):") do
        local v = tonumber(n)
        if not v or v ~= floor(v) or v < 0 or v > MAX_ITEM_ID then return nil end
        parts[#parts + 1] = v
    end
    if #parts > MAX_GEMS + 1 then return nil end
    while #parts > 0 and parts[#parts] == 0 do parts[#parts] = nil end
    if #parts == 0 then return nil end
    return table.concat(parts, ":")
end

-- Gem / enchant setups { [itemID] = "enchant:gem..." }: repaired in place; nil when empty.
local function SanitizeGems(t)
    if type(t) ~= "table" then return nil end
    for id, s in pairs(t) do
        local c = IsValidItemID(id) and CanonGems(s) or nil
        if c ~= s then t[id] = c end
    end
    return NonEmpty(t)
end

-- Repair anything malformed in a saved record (SavedVariables are user-editable).
local function SanitizeData(d)
    if type(d.v) ~= "number" then d.v = LIST_VERSION end
    if type(d.cl) ~= "string" then d.cl = PlayerClass() or "" end
    if type(d.sp) ~= "string" then d.sp = "" end
    if #d.sp > MAX_STR then d.sp = d.sp:sub(1, MAX_STR) end
    if type(d.ph) ~= "table" then d.ph = {} end
    if type(d.ob) ~= "table" then d.ob = {} end
    if type(d.eq) ~= "table" then d.eq = {} end
    SanitizePhases(d.ph)
    if d.dx ~= nil then d.dx = SanitizeDisabled(d.dx) end
    -- Off spec (Addendum H): os label, op phases, ox disabled slots; all omitted without an off spec.
    if d.os ~= nil and type(d.os) ~= "string" then d.os = "" end
    if type(d.os) == "string" and #d.os > MAX_STR then d.os = d.os:sub(1, MAX_STR) end
    if d.op ~= nil then
        if type(d.op) ~= "table" then
            d.op = nil
        else
            SanitizePhases(d.op)
            if next(d.op) == nil then d.op = nil end
        end
    end
    if d.ox ~= nil then d.ox = SanitizeDisabled(d.ox) end
    -- Pre-raid: flat picks / disabled slots of both specs; omitted when empty.
    d.pr, d.px = SanitizeSlots(d.pr), SanitizeDisabledSlots(d.px)
    d.opr, d.opx = SanitizeSlots(d.opr), SanitizeDisabledSlots(d.opx)
    d.ge, d.oge = SanitizeGems(d.ge), SanitizeGems(d.oge)
    if d.os == nil and (d.op ~= nil or d.ox ~= nil or d.opr ~= nil or d.opx ~= nil) then d.os = "" end
end

local function SanitizeRecord(rec)
    if type(rec.rev) ~= "number" then rec.rev = 0 end
    if type(rec.highestSeenRev) ~= "number" then rec.highestSeenRev = rec.rev end
    if type(rec.ts) ~= "number" then rec.ts = 0 end
    if type(rec.hash) ~= "string" then rec.hash = "" end
    if type(rec.data) ~= "table" then rec.data = NewData() end
    if type(rec.manual) ~= "table" then rec.manual = {} end
    if type(rec.bank) ~= "table" then rec.bank = {} end
    if type(rec.bankTs) ~= "number" then rec.bankTs = 0 end
    SanitizeData(rec.data)
end

local function ReadSlot(data, phase, sid)
    local p = PhaseSlots(data, phase)
    local s = p and p[sid]
    if type(s) ~= "table" then return 0, 0 end
    return tonumber(s[1]) or 0, tonumber(s[2]) or 0
end

-- Always stores {main, alt} (0 = empty) so the canonical hash is stable; drops empty slots/phases.
local function WriteSlot(data, phase, sid, main, alt)
    main, alt = main or 0, alt or 0
    if main ~= 0 and main == alt then alt = 0 end
    local p = PhaseSlots(data, phase)
    if main == 0 and alt == 0 then
        if p then
            p[sid] = nil
            SetPhaseSlots(data, phase, p)   -- (dropped when that was its last pick)
        end
        return
    end
    p = p or {}
    p[sid] = { main, alt }
    SetPhaseSlots(data, phase, p)
end

local function SlotsHavePicks(slots)
    if type(slots) ~= "table" then return false end
    for _, s in pairs(slots) do
        if type(s) == "table" and ((s[1] or 0) ~= 0 or (s[2] or 0) ~= 0) then return true end
    end
    return false
end

-- Any pick in any phase of either list, Pre-raid included (a Pre-raid-only list is worth sharing too: it must
-- commit, so an automatic restore never takes it for an empty fresh install).
local function HasPicks(data)
    for _, ph in ipairs({ data.ph, data.op }) do
        if type(ph) == "table" then
            for _, slots in pairs(ph) do
                if SlotsHavePicks(slots) then return true end
            end
        end
    end
    return SlotsHavePicks(data.pr) or SlotsHavePicks(data.opr)
end

function BiS:GetRecord()
    local key = ns.loggedIn and Util.PlayerKey()
    if not (key and ns.db and type(ns.db.chars) == "table") then
        if not tempRecord then tempRecord = NewRecord() end
        return tempRecord
    end
    local rec = ns.db.chars[key]
    if type(rec) ~= "table" then
        rec = NewRecord()
        ns.db.chars[key] = rec
    end
    if checkedRecord ~= rec then
        SanitizeRecord(rec)
        checkedRecord = rec
    end
    return rec
end

function BiS:GetData()
    return self:GetRecord().data
end

-- list (Addendum H): "ms" (default) or "os".
function BiS:GetSlot(phase, sid, list)
    local main, alt = ReadSlot(ListTable(self:GetData(), list), phase, sid)
    return (main ~= 0 and main or nil), (alt ~= 0 and alt or nil)
end

---------------------------------------------------------------------------
-- Edits
---------------------------------------------------------------------------

-- list (Addendum H): which list changed ("os"; nil = the main spec or both); third MYLIST_CHANGED argument.
-- Drops the gem / enchant setups of items no longer picked anywhere on their list (keeps the synced list small).
local function PruneGems(data)
    for _, k in ipairs({ { "ge", "ph", "pr" }, { "oge", "op", "opr" } }) do
        local ge = data[k[1]]
        if type(ge) == "table" then
            local picked = {}
            local function add(slots)
                for _, s in pairs(type(slots) == "table" and slots or {}) do
                    if type(s) == "table" then
                        if (s[1] or 0) ~= 0 then picked[s[1]] = true end
                        if (s[2] or 0) ~= 0 then picked[s[2]] = true end
                    end
                end
            end
            for _, slots in pairs(type(data[k[2]]) == "table" and data[k[2]] or {}) do add(slots) end
            add(data[k[3]])
            for id in pairs(ge) do
                if not picked[id] then ge[id] = nil end
            end
            data[k[1]] = NonEmpty(ge)
        end
    end
end

local function AfterEdit(phase, sid, list)
    PruneGems(BiS:GetData())
    BiS:RebuildDerived()
    ns:Fire("MYLIST_CHANGED", phase, sid, list)
    BiS:MarkDirty()
end

-- Addendum F §38: locked, lockInfo {by=key, at=serverTime} (nil when unlocked). While locked every editing
-- API below refuses (returns false; prints at most once per 3 s).
function BiS:IsLocked()
    return LockState()
end

---------------------------------------------------------------------------
-- Off spec (Addendum H)
---------------------------------------------------------------------------

function BiS:HasOffSpec()
    return ns.HasOffSpec(self:GetData()) and true or false
end

-- A read-only view of one list shaped like ListData ({ cl, sp, ph, dx, ob, eq }): for "os" the off-spec picks
-- with the shared obtained / equipped state. Callers (PaperDoll, summaries) must not write into it.
function BiS:GetListView(list)
    return ns.ListView(self:GetData(), list)
end

-- Adds an empty off-spec list (spec label optional). false while locked.
function BiS:AddOffSpec(label)
    if RefuseLocked() then return false end
    local data = self:GetData()
    if data.os ~= nil then return true end
    data.os = ""
    if type(label) == "string" and label ~= "" then self:SetSpec(label, "os") end
    AfterEdit(nil, nil, "os")
    return true
end

-- Removes the off-spec list and all its picks. false while locked.
function BiS:RemoveOffSpec()
    if RefuseLocked() then return false end
    local data = self:GetData()
    if not ns.HasOffSpec(data) then return true end
    data.os, data.op, data.ox, data.opr, data.opx, data.oge = nil, nil, nil, nil, nil, nil
    AfterEdit(nil, nil, "os")
    return true
end

-- Makes the off spec the main spec and the main spec the off spec: spec labels, picks and disabled slots of every
-- phase trade places (obtained / equipped stay shared). false while locked or without an off spec.
function BiS:SwapLists()
    if RefuseLocked() then return false end
    local data = self:GetData()
    if not ns.HasOffSpec(data) then return false end
    data.sp, data.os = data.os or "", data.sp or ""
    data.ph, data.op = type(data.op) == "table" and data.op or {}, NonEmpty(data.ph)
    data.dx, data.ox = data.ox, NonEmpty(data.dx)
    data.pr, data.opr = data.opr, NonEmpty(data.pr)
    data.px, data.opx = data.opx, NonEmpty(data.px)
    data.ge, data.oge = NonEmpty(data.oge), NonEmpty(data.ge)
    AfterEdit(nil, nil, "ms")
    ns:Fire("MYLIST_CHANGED", nil, nil, "os")
    return true
end

---------------------------------------------------------------------------
-- Pick edits (list: "ms" default, "os" = the off-spec list)
---------------------------------------------------------------------------

function BiS:SetSlot(phase, sid, which, itemID, list)
    if not IsListPhase(phase) or not IsValidSid(sid) then return false end
    if which ~= "main" and which ~= "alt" then return false end
    if RefuseLocked() then return false end
    itemID = tonumber(itemID) or 0
    if itemID ~= 0 then
        if not IsValidItemID(itemID) then return false end
        if IsToken(itemID) then
            local piece = ResolveToken(itemID, sid)
            if not piece then
                ns:Print("%s is a token / quest item: pick the item you exchange it for instead (the picker lists those under the boss).",
                    ItemLabel(itemID))
                return false
            end
            itemID = piece
        end
        if not ItemFits(itemID, sid) then
            ns:Print("%s doesn't fit the %s slot.", ItemLabel(itemID), SlotLabel(sid))
            return false
        end
    end
    local data = self:GetData()
    local L = ListTable(data, list)
    local oldMain, oldAlt = ReadSlot(L, phase, sid)
    local main, alt = oldMain, oldAlt
    if which == "main" then
        if itemID ~= 0 and itemID == alt then alt = main end   -- promoting the alt: swap
        main = itemID
    else
        if itemID ~= 0 and itemID == main then main = alt end  -- demoting the main: swap
        alt = itemID
    end
    if main ~= 0 and main == alt then alt = 0 end
    if main == oldMain and alt == oldAlt then return true end
    WriteSlot(L, phase, sid, main, alt)
    StoreList(data, list, L)
    AfterEdit(phase, sid, list)
    return true
end

-- 1.4.2 (Discord BiS edits, Core/Bridge.lua): may itemID go in slot sid? Returns the item to store (a token becomes
-- its piece for that slot), or nil and why.
function BiS:CheckPick(itemID, sid)
    itemID = tonumber(itemID) or 0
    if not IsValidSid(sid) then return nil, "unknown slot" end
    if not IsValidItemID(itemID) then return nil, "unknown item" end
    if IsToken(itemID) then
        local piece = ResolveToken(itemID, sid)
        if not piece then return nil, ItemLabel(itemID) .. " is a token: pick the item it turns into." end
        itemID = piece
    end
    if not ItemFits(itemID, sid) then return nil, ItemLabel(itemID) .. " doesn't fit the " .. SlotLabel(sid) .. " slot." end
    return itemID
end

function BiS:ClearSlot(phase, sid, list)
    if not IsListPhase(phase) or not IsValidSid(sid) then return false end
    if RefuseLocked() then return false end
    local data = self:GetData()
    local L = ListTable(data, list)
    local main, alt = ReadSlot(L, phase, sid)
    if main == 0 and alt == 0 then return true end
    WriteSlot(L, phase, sid, 0, 0)
    StoreList(data, list, L)
    AfterEdit(phase, sid, list)
    return true
end

function BiS:SwapMainAlt(phase, sid, list)
    if not IsListPhase(phase) or not IsValidSid(sid) then return false end
    if RefuseLocked() then return false end
    local data = self:GetData()
    local L = ListTable(data, list)
    local main, alt = ReadSlot(L, phase, sid)
    if main == 0 and alt == 0 then return false end
    WriteSlot(L, phase, sid, alt, main)
    StoreList(data, list, L)
    AfterEdit(phase, sid, list)
    return true
end

function BiS:ClearPhase(phase, list)
    if not IsListPhase(phase) then return false end
    if RefuseLocked() then return false end
    local data = self:GetData()
    local L = ListTable(data, list)
    if PhaseSlots(L, phase) == nil then return true end
    SetPhaseSlots(L, phase, nil)
    StoreList(data, list, L)
    AfterEdit(phase, nil, list)
    return true
end

-- overwrite=true: drops every pick of `phase` except those in disabled slots (Addendum F §36: a disabled
-- slot keeps its picks and is never filled by a copy / template).
local function ResetPhaseKeepingDisabled(data, phase)
    local old = PhaseSlots(data, phase)
    local keep
    if old then
        for sid, s in pairs(old) do
            if IsDisabled(data, phase, sid) then
                keep = keep or {}
                keep[sid] = s
            end
        end
    end
    SetPhaseSlots(data, phase, keep)
end

-- overwrite=true: the target phase becomes an exact copy of the source phase.
-- overwrite=false: only slots without a main pick in the target are filled.
-- Disabled slots of the target phase are left untouched either way.
-- list: the target list; fromList (default: list) the source list, so "copy my main spec's P2 into my off spec"
-- is CopyPhase(2, 2, false, "os", "ms"). Either phase may be Pre-raid (0): CopyPhase(0, 1, false) fills P1's empty
-- slots from the Pre-raid list.
function BiS:CopyPhase(fromPhase, toPhase, overwrite, list, fromList)
    fromList = fromList or list
    local sameList = (fromList == "os") == (list == "os")
    if not IsListPhase(fromPhase) or not IsListPhase(toPhase) or (sameList and fromPhase == toPhase) then return false end
    if RefuseLocked() then return false end
    local data = self:GetData()
    local L = ListTable(data, list)
    local S = sameList and L or ListTable(data, fromList)
    local src = Util.CopyTable(PhaseSlots(S, fromPhase) or {})
    local S2 = { ph = { [1] = src } }
    if overwrite then ResetPhaseKeepingDisabled(L, toPhase) end
    local changed = overwrite and true or false
    for sid = 1, NUM_SLOTS do
        local sMain, sAlt = ReadSlot(S2, 1, sid)
        if (sMain ~= 0 or sAlt ~= 0) and not IsDisabled(L, toPhase, sid) then
            local tMain, tAlt = ReadSlot(L, toPhase, sid)
            if overwrite then
                WriteSlot(L, toPhase, sid, sMain, sAlt)
            elseif tMain == 0 and sMain ~= 0 then
                local alt = tAlt ~= 0 and tAlt or sAlt
                WriteSlot(L, toPhase, sid, sMain, alt)
                changed = true
            end
        end
    end
    StoreList(data, list, L)
    if changed then AfterEdit(toPhase, nil, list) end
    return changed
end

-- slots[sid] = {main, alt}. overwrite=true replaces the whole phase with the template;
-- overwrite=false fills only slots without a main pick. Items that don't fit are skipped, and disabled
-- slots are never filled (nor cleared). Returns the number of slots changed (false while locked).
function BiS:ApplyTemplate(phase, slots, overwrite, list)
    if not IsListPhase(phase) or type(slots) ~= "table" then return 0 end
    if RefuseLocked() then return false end
    local rdata = self:GetData()
    local data = ListTable(rdata, list)
    local before = Util.CopyTable(PhaseSlots(data, phase) or {})
    if overwrite then ResetPhaseKeepingDisabled(data, phase) end
    for sid = 1, NUM_SLOTS do
        local t = slots[sid]
        if type(t) == "table" and not IsDisabled(data, phase, sid) then
            local m, a = tonumber(t[1]) or 0, tonumber(t[2]) or 0
            if m ~= 0 and IsToken(m) then m = ResolveToken(m, sid) or 0 end
            if a ~= 0 and IsToken(a) then a = ResolveToken(a, sid) or 0 end
            if m ~= 0 and not (IsValidItemID(m) and ItemFits(m, sid)) then m = 0 end
            if a ~= 0 and not (IsValidItemID(a) and ItemFits(a, sid)) then a = 0 end
            if m == 0 and a ~= 0 then m, a = a, 0 end
            if m ~= 0 then
                local tMain, tAlt = ReadSlot(data, phase, sid)
                if overwrite then
                    WriteSlot(data, phase, sid, m, a)
                elseif tMain == 0 then
                    WriteSlot(data, phase, sid, m, tAlt ~= 0 and tAlt ~= m and tAlt or a)
                end
            end
        end
    end
    local after = PhaseSlots(data, phase) or {}
    local changed = 0
    for sid = 1, NUM_SLOTS do
        local b, a = before[sid], after[sid]
        local bm, ba = b and b[1] or 0, b and b[2] or 0
        local am, aa = a and a[1] or 0, a and a[2] or 0
        if bm ~= am or ba ~= aa then changed = changed + 1 end
    end
    StoreList(rdata, list, data)
    if changed > 0 then AfterEdit(phase, nil, list) end
    return changed
end

---------------------------------------------------------------------------
-- Gems and enchants (per item of a list; Core/Gems.lua is the logic)
---------------------------------------------------------------------------

-- enchant (number, 0 = none), gems { [socket] = gemID or 0 } of an item on `list`.
function BiS:GetGemSetup(itemID, list)
    local L = ListTable(self:GetData(), list)
    local s = type(L.ge) == "table" and L.ge[itemID] or nil
    local gems, enchant = {}, 0
    if type(s) == "string" then
        local i = 0
        for n in (s .. ":"):gmatch("([^:]*):") do
            if i == 0 then enchant = tonumber(n) or 0 else gems[i] = tonumber(n) or 0 end
            i = i + 1
        end
    end
    return enchant, gems
end

-- The stored string of a setup (nil = none): enchant number, gems { [socket] = id }.
local function EncodeGems(enchant, gems)
    local parts = { tostring(tonumber(enchant) or 0) }
    local n = 0
    for k in pairs(type(gems) == "table" and gems or {}) do
        if type(k) == "number" and k > n then n = k end
    end
    for i = 1, math.min(n, MAX_GEMS) do parts[#parts + 1] = tostring(tonumber(gems[i]) or 0) end
    return CanonGems(table.concat(parts, ":"))
end

-- Several setups at once: setups = { [itemID] = { enchant = n, gems = { ... } } or false (= clear) }. One change
-- event. false while locked; else the number of items changed.
function BiS:SetGemSetups(setups, list)
    if type(setups) ~= "table" then return 0 end
    if RefuseLocked() then return false end
    local data = self:GetData()
    local L = ListTable(data, list)
    local ge = type(L.ge) == "table" and L.ge or {}
    local changed = 0
    for itemID, s in pairs(setups) do
        if IsValidItemID(itemID) then
            local v = s and EncodeGems(s.enchant, s.gems) or nil
            if ge[itemID] ~= v then
                ge[itemID] = v
                changed = changed + 1
            end
        end
    end
    if changed == 0 then return 0 end
    L.ge = NonEmpty(ge)
    if list ~= "os" then data.ge = L.ge end
    StoreList(data, list, L)
    AfterEdit(nil, nil, list)
    return changed
end

-- One item's setup (enchant number or 0, gems { [socket] = id }); enchant and gems nil clear it. true when stored.
function BiS:SetGemSetup(itemID, enchant, gems, list)
    local n = self:SetGemSetups({ [itemID] = (enchant or gems) and { enchant = enchant, gems = gems } or false }, list)
    return n ~= false
end

---------------------------------------------------------------------------
-- Disabled slots (Addendum F §36)
---------------------------------------------------------------------------

function BiS:IsSlotDisabled(phase, sid, list)
    if not IsListPhase(phase) or not IsValidSid(sid) then return false end
    return IsDisabled(ListTable(self:GetData(), list), phase, sid)
end

-- { [sid] = true } of the disabled slots of a phase (a new table).
function BiS:GetDisabledSlots(phase, list)
    local out = {}
    if not IsListPhase(phase) then return out end
    local p = PhaseDisabled(ListTable(self:GetData(), list), phase)
    if p then
        for sid, v in pairs(p) do
            if v == true and IsValidSid(sid) then out[sid] = true end
        end
    end
    return out
end

-- Writes one flag; true when it changed. Empty tables are dropped (omitted when empty: same hash as before 0.4).
local function WriteDisabled(data, phase, sid, disabled)
    if IsDisabled(data, phase, sid) == disabled then return false end
    local p = PhaseDisabled(data, phase) or {}
    p[sid] = disabled and true or nil
    SetPhaseDisabled(data, phase, p)
    return true
end

-- Disables (true) / enables (false) a slot in one phase; the picks are kept. false when refused.
function BiS:SetSlotDisabled(phase, sid, disabled, list)
    if not IsListPhase(phase) or not IsValidSid(sid) then return false end
    if RefuseLocked() then return false end
    local data = self:GetData()
    local L = ListTable(data, list)
    if WriteDisabled(L, phase, sid, disabled and true or false) then
        StoreList(data, list, L)
        AfterEdit(phase, sid, list)
    end
    return true
end

-- Disables / enables a slot in every phase, Pre-raid included. false when refused.
function BiS:SetSlotDisabledAllPhases(sid, disabled, list)
    if not IsValidSid(sid) then return false end
    if RefuseLocked() then return false end
    local data = self:GetData()
    local L = ListTable(data, list)
    local changed = false
    for phase = PRE_RAID, (ns.MAX_PHASE or MAX_PHASE) do
        if WriteDisabled(L, phase, sid, disabled and true or false) then changed = true end
    end
    StoreList(data, list, L)
    if changed then AfterEdit(nil, sid, list) end
    return true
end

---------------------------------------------------------------------------
-- Spec
---------------------------------------------------------------------------

-- list "os": the off-spec label ("" while not chosen or without an off spec).
function BiS:GetSpec(list)
    local data = self:GetData()
    if list == "os" then return data.os or "" end
    return data.sp or ""
end

function BiS:SetSpec(label, list)
    if label ~= nil and type(label) ~= "string" then return false end
    label = label or ""
    if RefuseLocked() then return false end
    local data = self:GetData()
    if list == "os" then
        if label ~= "" then
            local specs = ns.SPECS and ns.SPECS[data.cl]
            local known = type(specs) ~= "table"
            for _, spec in ipairs(type(specs) == "table" and specs or {}) do
                if spec.label == label then known = true break end
            end
            if not known then return false end
            if #label > MAX_STR then label = label:sub(1, MAX_STR) end
        end
        if data.os == label then return true end
        data.os = label   -- (setting a label also adds the off spec)
        ns:Fire("MYLIST_CHANGED", nil, nil, "os")
        self:MarkDirty()
        return true
    end
    if label ~= "" then
        local specs = ns.SPECS and ns.SPECS[data.cl]
        if type(specs) == "table" then
            local known = false
            for _, spec in ipairs(specs) do
                if spec.label == label then known = true break end
            end
            if not known then return false end
        end
        if #label > MAX_STR then label = label:sub(1, MAX_STR) end
    end
    if data.sp == label then return true end
    data.sp = label
    ns:Fire("MYLIST_CHANGED")
    self:MarkDirty()
    return true
end

-- Talent points spent in a tab. 2.5.6: C_SpecializationInfo.GetSpecializationInfo (pointsSpent is
-- the 7th return); GetTalentTabInfo is only a deprecation fallback there, kept for older clients.
local function TabPoints(tab)
    local C = C_SpecializationInfo
    if C and C.GetSpecializationInfo then
        local ok, _, _, _, _, _, _, points = pcall(C.GetSpecializationInfo, tab, false, false, nil, nil, nil)
        if ok then return tonumber(points) end
    end
    if GetTalentTabInfo then
        local r1, _, r3, _, r5 = GetTalentTabInfo(tab)
        -- alias order: id, name, desc, icon, pointsSpent; the old 2.4 order had points 3rd
        return (type(r1) == "string") and tonumber(r3) or tonumber(r5)
    end
    return nil
end

function BiS:DetectSpec()
    local classFile = PlayerClass()
    local specs = ns.SPECS and classFile and ns.SPECS[classFile]
    local C = C_SpecializationInfo
    if type(specs) ~= "table" or not ((C and C.GetSpecializationInfo) or GetTalentTabInfo) then return "" end
    local numTabs = (GetNumTalentTabs and GetNumTalentTabs()) or 3
    local bestTab, bestPoints = nil, 0
    for tab = 1, numTabs do
        local points = TabPoints(tab)
        if points and points > bestPoints then
            bestTab, bestPoints = tab, points
        end
    end
    if not bestTab then return "" end
    for _, spec in ipairs(specs) do
        if spec.tab == bestTab then return spec.label or "" end
    end
    return ""
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------

-- { sid=, which=, itemID=, disabled=true|nil } per pick (disabled: the slot is disabled, the pick is kept).
function BiS:GetPhaseItems(phase, list)
    local out = {}
    if not IsListPhase(phase) then return out end
    local data = ListTable(self:GetData(), list)
    for sid = 1, NUM_SLOTS do
        local main, alt = ReadSlot(data, phase, sid)
        local disabled = IsDisabled(data, phase, sid) or nil
        if main ~= 0 then out[#out + 1] = { sid = sid, which = "main", itemID = main, disabled = disabled } end
        if alt ~= 0 then out[#out + 1] = { sid = sid, which = "alt", itemID = alt, disabled = disabled } end
    end
    return out
end

-- Every item on my lists' raid phases (both specs: the obtained list data.ob covers the off spec too). Pre-raid picks
-- are left out: ob is what the council sees (capped at 200 ids), and the council never sees the Pre-raid list.
function BiS:AllListItems()
    local set = {}
    local data = self:GetData()
    for _, ph in ipairs({ data.ph, data.op }) do
        for _, slots in pairs(type(ph) == "table" and ph or {}) do
            if type(slots) == "table" then
                for _, s in pairs(slots) do
                    if type(s) == "table" then
                        if (s[1] or 0) ~= 0 then set[s[1]] = true end
                        if (s[2] or 0) ~= 0 then set[s[2]] = true end
                    end
                end
            end
        end
    end
    return set
end

---------------------------------------------------------------------------
-- Obtained scanning
---------------------------------------------------------------------------

-- Returns itemID, count for a container slot (nil when empty).
local function ReadContainerSlot(bag, slot)
    local C = C_Container
    if not C then return nil end
    if C.GetContainerItemInfo then
        local info = C.GetContainerItemInfo(bag, slot)
        if type(info) == "table" and info.itemID then
            return info.itemID, info.stackCount or 1
        end
        return nil
    end
    if C.GetContainerItemLink then
        local link = C.GetContainerItemLink(bag, slot)
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then return id, 1 end
    end
    return nil
end

local function ScanContainer(bag, into)
    local C = C_Container
    if not (C and C.GetContainerNumSlots) then return end
    local n = C.GetContainerNumSlots(bag) or 0
    for slot = 1, n do
        local id, count = ReadContainerSlot(bag, slot)
        if id then into[id] = (into[id] or 0) + (count or 1) end
    end
end

local function NumBagSlots()
    return tonumber(NUM_BAG_SLOTS) or 4
end

local function NumBankBagSlots()
    return tonumber(NUM_BANKBAGSLOTS) or 7
end

local function RebuildTokenCovers(rec)
    local covers = {}
    local function add(set)
        for id in pairs(set) do
            if IsToken(id) then
                for _, piece in ipairs(ExpandDrop(id)) do
                    if piece ~= id then covers[piece] = id end
                end
            end
        end
    end
    add(equipped)
    add(bags)
    add(rec.bank)
    tokenCovers = covers
end

-- Rebuilds data.ob and data.eq from the current scan state. Returns true if either changed.
function BiS:RebuildDerived()
    local rec = self:GetRecord()
    local data = rec.data
    local ob = {}
    for id in pairs(self:AllListItems()) do
        if self:GetObtainedState(id) then ob[#ob + 1] = id end
    end
    tsort(ob)
    for i = #ob, MAX_OB + 1, -1 do ob[i] = nil end

    local eq = data.eq
    if ns.loggedIn and ns.SLOTS then
        eq = {}
        for sid = 1, NUM_SLOTS do
            local slot = ns.SLOTS[sid]
            local id = slot and slot.invSlot and GetInventoryItemID("player", slot.invSlot)
            if IsValidItemID(id) then eq[sid] = id end
        end
    end

    local changed = false
    if not SameArray(ob, data.ob) then
        data.ob = ob
        changed = true
    end
    if not SameMap(eq, data.eq) then
        data.eq = eq
        changed = true
    end
    return changed
end

function BiS:ScanOwned()
    scanPending = false
    if not ns.loggedIn then return end
    local rec = self:GetRecord()

    local newEquipped, newBags = {}, {}
    for invSlot = 1, 19 do
        local id = GetInventoryItemID("player", invSlot)
        if id then newEquipped[id] = (newEquipped[id] or 0) + 1 end
    end
    for bag = 0, NumBagSlots() do
        ScanContainer(bag, newBags)
    end

    local changed = not SameKeys(equipped, newEquipped) or not SameKeys(bags, newBags)
    equipped, bags = newEquipped, newBags

    if bankOpen then
        local bank = {}
        ScanContainer(BANK_CONTAINER or BANK_CONTAINER_ID, bank)
        local first = NumBagSlots() + 1
        for bag = first, first + NumBankBagSlots() - 1 do
            ScanContainer(bag, bank)
        end
        if not SameKeys(rec.bank, bank) then changed = true end
        rec.bank = bank
        rec.bankTs = GetServerTime()
    end

    RebuildTokenCovers(rec)
    local dataChanged = self:RebuildDerived()
    if changed or dataChanged then ns:Fire("OWNED_UPDATED") end
    if dataChanged then self:MarkDirty() end
end

function BiS:ScheduleScan()
    scanPending = true
    Util.Debounce("bis-scan", 1.5, function() BiS:ScanOwned() end)
end

function BiS:GetObtainedState(itemID)
    if not itemID then return nil end
    if equipped[itemID] then return "equipped" end
    if bags[itemID] then return "bags" end
    local rec = self:GetRecord()
    if rec.bank[itemID] then return "bank" end
    if tokenCovers[itemID] then return "token" end
    if rec.manual[itemID] then return "manual" end
    if IsToken(itemID) then
        -- A token pick saved by an older version: obtained once I own one of my class's pieces.
        for _, p in ipairs(MyTokenPieces(itemID)) do
            if equipped[p] then return "equipped" end
            if bags[p] then return "bags" end
            if rec.bank[p] then return "bank" end
        end
    end
    return nil
end

function BiS:IsObtained(itemID)
    return self:GetObtainedState(itemID) ~= nil
end

function BiS:SetManualObtained(itemID, obtained)
    itemID = tonumber(itemID)
    if not IsValidItemID(itemID) then return false end
    local rec = self:GetRecord()
    local value = obtained and true or nil
    if rec.manual[itemID] == value then return true end
    rec.manual[itemID] = value
    self:RebuildDerived()
    ns:Fire("OWNED_UPDATED")
    self:MarkDirty()
    return true
end

---------------------------------------------------------------------------
-- Commit / revisions
---------------------------------------------------------------------------

function BiS:MarkDirty()
    commitPending = true
    Util.Debounce("bis-commit", 8, function() BiS:Commit() end)
    ns:Fire("SYNC_STATUS")
end

-- A never-committed list with no picks is not worth sharing; it also keeps rev at 0 so a
-- fresh install can be restored automatically from the council (see Sync.OnCouncilHasNewer).
local function NothingToShare(rec)
    return rec.rev == 0 and not HasPicks(rec.data)
end

function BiS:Commit()
    local wasPending = commitPending
    commitPending = false
    Util.CancelDebounce("bis-commit")
    local rec = self:GetRecord()
    if not ns.loggedIn or rec == tempRecord or NothingToShare(rec) then
        if wasPending then ns:Fire("SYNC_STATUS") end
        return false
    end
    local newHash = Util.Hash(rec.data)
    if newHash == rec.hash then
        if wasPending then ns:Fire("SYNC_STATUS") end
        return false
    end
    rec.rev = min(max(rec.rev, rec.highestSeenRev) + 1, MAX_REV)
    rec.highestSeenRev = rec.rev
    rec.ts = GetServerTime()
    rec.hash = newHash
    ns:Fire("MYLIST_COMMITTED", rec)
    ns:Fire("SYNC_STATUS")
    return true
end

-- New rev even when the data is unchanged (used by Sync to supersede a council copy).
function BiS:ForceBump()
    local wasPending = commitPending
    commitPending = false
    Util.CancelDebounce("bis-commit")
    local rec = self:GetRecord()
    if not ns.loggedIn or rec == tempRecord then
        if wasPending then ns:Fire("SYNC_STATUS") end
        return false
    end
    rec.rev = min(max(rec.rev, rec.highestSeenRev) + 1, MAX_REV)
    rec.highestSeenRev = rec.rev
    rec.ts = GetServerTime()
    rec.hash = Util.Hash(rec.data)
    ns:Fire("MYLIST_COMMITTED", rec)
    ns:Fire("SYNC_STATUS")
    return true
end

function BiS:IsDirty()
    if commitPending then return true end
    local rec = self:GetRecord()
    if NothingToShare(rec) then return false end
    return Util.Hash(rec.data) ~= rec.hash
end

function BiS:NoteSeenRev(rev)
    rev = tonumber(rev)
    if not rev or rev ~= floor(rev) or rev < 0 or rev > MAX_REV then return end
    local rec = self:GetRecord()
    if rev > (rec.highestSeenRev or 0) then rec.highestSeenRev = rev end
end

-- entry = {r=rev, ts=, h=, d=data} from a council member's copy of my list.
function BiS:AdoptRestored(entry)
    if type(entry) ~= "table" or type(entry.d) ~= "table" then return false end
    local rev = tonumber(entry.r)
    if not rev or rev ~= floor(rev) or rev < 0 then return false end
    if ns.Store and ns.Store.ValidateData then
        local ok, err = ns.Store:ValidateData(entry.d)
        if not ok then
            ns:Debug("Restore rejected: %s", tostring(err))
            return false
        end
    end
    local rec = self:GetRecord()
    if rec == tempRecord then return false end
    local data = Util.CopyTable(entry.d)
    SanitizeData(data)
    data.cl = PlayerClass() or data.cl
    rec.data = data
    rec.rev = rev
    rec.highestSeenRev = max(rec.highestSeenRev or 0, rev)
    local ts = tonumber(entry.ts)
    rec.ts = (ts and ts > 0) and ts or GetServerTime()
    rec.hash = Util.Hash(rec.data)
    -- Re-derive ob/eq from what this character actually holds (may queue a newer commit).
    self:ScanOwned()
    ns:Fire("MYLIST_CHANGED")
    ns:Print("Restored your BiS list from the council (rev %d).", rev)
    return true
end

---------------------------------------------------------------------------
-- Drop matching
---------------------------------------------------------------------------

-- Adds the picks of one phase's slots that are `wanted` to out (MatchItem). An earlier phase's pick (Pre-raid
-- included) of a slot disabled in the current phase `view` is superseded ("not needed", §36).
local function MatchSlots(out, data, phase, slots, view, m)
    if type(slots) ~= "table" then return end
    for sid, s in pairs(slots) do
        if type(s) == "table" and not IsDisabled(data, phase, sid)
            and not (phase < view and IsDisabled(data, view, sid)) then
            for idx = 1, 2 do
                if s[idx] == m.wanted then
                    if m.obtained == nil then m.obtained = BiS:IsObtained(m.wanted) end
                    out[#out + 1] = {
                        phase = phase, sid = sid, which = (idx == 1) and "main" or "alt",
                        wanted = m.wanted, via = m.via, obtained = m.obtained, os = m.os,
                    }
                end
            end
        end
    end
end

-- Picks matching a dropped item (disabled slots are skipped, Addendum F §36). Off-spec picks (Addendum H) carry
-- os = true and come after every main-spec match. opts.preRaid: my Pre-raid picks match too (phase = 0), after
-- every raid-phase match of the same list; only my own tooltip asks (loot alerts, the roll popup and the drop
-- panel stay on the raid phases).
function BiS:MatchItem(itemID, opts)
    local out = {}
    itemID = tonumber(itemID)
    if not itemID then return out end
    local preRaid = type(opts) == "table" and opts.preRaid and true or false
    local rdata = self:GetData()
    local lists = { { L = rdata } }
    if rdata.op or (preRaid and rdata.opr) then lists[2] = { L = ListTable(rdata, "os"), os = true } end
    -- A pick my class cannot use (class-restricted item, another class's token) never alerts (DisasterZone 0.5).
    local view = ns.Guild and ns.Guild.GetViewPhase and ns.Guild:GetViewPhase() or 1
    local _, myClass = UnitClass("player")
    local ItemDB = ns.ItemDB
    local dropUsable = not (ItemDB and ItemDB.CanClassUse and ItemDB:CanClassUse(itemID, myClass) == false)
    for _, wanted in ipairs(ExpandDrop(itemID)) do
        local m = { wanted = wanted, via = ViaOf(itemID, wanted) }
        local usable = (wanted == itemID or dropUsable)
            and not (ItemDB and ItemDB.CanClassUse and ItemDB:CanClassUse(wanted, myClass) == false)
        if usable then
            for _, lst in ipairs(lists) do
                local data = lst.L
                m.os = lst.os
                for phase, slots in pairs(data.ph) do
                    MatchSlots(out, data, phase, slots, view, m)
                end
                if preRaid then MatchSlots(out, data, PRE_RAID, PhaseSlots(data, PRE_RAID), view, m) end
            end
        end
    end
    if #out > 1 then
        local view = ns.Guild and ns.Guild.GetViewPhase and ns.Guild:GetViewPhase()
        tsort(out, function(a, b)
            if (a.os and true or false) ~= (b.os and true or false) then return not a.os end
            local ap, bp = (a.phase == PRE_RAID), (b.phase == PRE_RAID)
            if ap ~= bp then return bp end   -- Pre-raid after the raid phases
            local av, bv = (a.phase == view), (b.phase == view)
            if av ~= bv then return av end
            if a.phase ~= b.phase then return a.phase < b.phase end
            if a.which ~= b.which then return a.which == "main" end
            if a.sid ~= b.sid then return a.sid < b.sid end
            return a.wanted < b.wanted
        end)
    end
    return out
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local SPEC_WAIT, SPEC_WAIT_TRIES = 5, 3

-- Fills an empty spec from the talents after login. Not while the lists are locked (the spec is part of the
-- picks the council watches), and after a /reload inside a raid not before the raid's rules (and so a
-- possible lock) are known: the answer to the rules query takes a few seconds, and a spec set meanwhile
-- would be flagged "changed during lock" (Addendum F §38).
local function AutoDetectSpec(tries)
    local data = BiS:GetData()
    if data.sp ~= "" or LockState() then return end
    local GR = ns.GroupRules
    if tries < SPEC_WAIT_TRIES and IsInRaid() and GR and GR.GetActive and not GR:GetActive()
        and not (GR.IsAuthority and GR:IsAuthority()) then
        Util.After(SPEC_WAIT, function() AutoDetectSpec(tries + 1) end)
        return
    end
    local spec = BiS:DetectSpec()
    if spec ~= "" then
        data.sp = spec
        ns:Fire("MYLIST_CHANGED")
        BiS:MarkDirty()
    end
end

function BiS:OnLogin()
    local rec = self:GetRecord()
    local classFile = PlayerClass()
    if classFile and rec.data.cl ~= classFile then rec.data.cl = classFile end

    ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function() BiS:ScheduleScan() end)
    ns:RegisterEvent("BAG_UPDATE_DELAYED", function() BiS:ScheduleScan() end)
    ns:RegisterEvent("BANKFRAME_OPENED", function()
        bankOpen = true
        BiS:ScanOwned()
    end)
    ns:RegisterEvent("PLAYERBANKSLOTS_CHANGED", function()
        if bankOpen then BiS:ScheduleScan() end
    end)
    ns:RegisterEvent("BANKFRAME_CLOSED", function()
        -- flush a queued scan while the bank contents are still readable
        if bankOpen and scanPending then
            Util.CancelDebounce("bis-scan")
            BiS:ScanOwned()
        end
        bankOpen = false
    end)
    ns:RegisterEvent("PLAYER_LOGOUT", function() BiS:Commit() end)
    -- Addendum F §38: an edit made just before the lock is committed now (not after the 8 s debounce), so
    -- the council sees it as made before the lock.
    ns:On("BIS_LOCK_CHANGED", function(locked)
        if locked and BiS:IsDirty() then BiS:Commit() end
    end)

    Util.After(3, function()
        AutoDetectSpec(0)
        BiS:ScanOwned()
    end)
end
