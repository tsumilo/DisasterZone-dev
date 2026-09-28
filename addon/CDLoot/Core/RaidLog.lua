-- CDLoot: Core/RaidLog.lua
-- Raid log (Addendum I §48-§49): records the raid session the raid's authority runs (GroupRules:GetSession, GS
-- rs / rsAt) into db.raids: zone, boss kills with the roster at each kill, and attendance by raid group
-- membership (not location, so ghost runs, AFKs and long trash clears are fine).
--
-- Every client in the raid records locally; there is no single recorder (council clients merge later, §50).
-- The record closes when the authority ends the session (endedBy), or, as a safety net, when I am no longer in
-- the raid (disband, left, raid -> party: autoEnded, stop = the last activity). While no authority rules are known
-- (right after a /reload, or while the authority changes hands) the open record just waits.
local addonName, ns = ...

local RaidLog = ns:NewModule("RaidLog")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local floor = math.floor
local tsort = table.sort

local DAY = 86400
local SCAN_INTERVAL = 60                -- roster / activity scan while a session is open
local ROSTER_DELAY = 1                  -- debounce after GROUP_ROSTER_UPDATE
local RESUME_MAX_IDLE = 2 * 3600        -- an open record idle longer than this is not adopted by a new authority
local ROSTER_KEEP_DAYS = 90             -- per-boss rosters are dropped after this (att totals stay)
local PROMPT_SNOOZE = 1800              -- the "no raid session" reminder is asked at most once per 30 min

local scanPending = false
local zoneEnteredAt                     -- server time I entered the current raid instance (backdating)
local promptedAt = -PROMPT_SNOOZE
local missedPull = false                -- a boss was pulled here while no session ran

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

local function RaidsDB()
    local db = ns.db
    if not db then return nil end
    if type(db.raids) ~= "table" then db.raids = {} end
    return db.raids
end

local function OpenRecord()
    local db = ns.db
    local id = db and db.raidCurrent
    local raids = RaidsDB()
    if type(id) ~= "string" or not raids then return nil end
    local rec = raids[id]
    if type(rec) ~= "table" or rec.stop then
        db.raidCurrent = nil
        return nil
    end
    return rec
end

local function GuildKey()
    local Guild = ns.Guild
    return Guild and Guild.GetGuildKey and Guild:GetGuildKey() or nil
end

local function Changed(rec)
    ns:Fire("RAIDLOG_CHANGED", rec and rec.id)
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

-- { [key] = { class=, online=, zone= } } of the current raid (the real roster, never the demo raid).
local function Roster()
    local out = {}
    if not IsInRaid() then return out end
    for i = 1, (GetNumGroupMembers() or 0) do
        local name, _, _, _, _, fileName, zone, online = GetRaidRosterInfo(i)
        local key = (type(name) == "string" and name ~= UNKNOWNOBJECT) and Util.NormalizeName(name) or nil
        if key then
            out[key] = { class = fileName, online = online and true or false, zone = zone }
        end
    end
    return out
end

-- Zone / instance of the raid, from my own position when I am inside a raid instance.
local function NoteZone(rec)
    if not Util.InRaidInstance() then return false end
    local name, _, _, _, _, _, _, instID = GetInstanceInfo()
    if type(name) == "string" and name ~= "" and rec.zone ~= name then
        rec.zone = name
        rec.instID = tonumber(instID)
    end
    return true
end

-- Updates attendance (joins / leaves) and the activity stamp from the live roster.
local function Scan(rec)
    if not rec then return end
    local now = GetServerTime()
    if not rec.g then rec.g = GuildKey() end
    local inside = NoteZone(rec)
    local roster = Roster()
    rec.att = type(rec.att) == "table" and rec.att or {}
    for key, m in pairs(roster) do
        local a = rec.att[key]
        if type(a) ~= "table" then
            a = { j = now, k = 0 }
            rec.att[key] = a
        end
        if m.class then a.c = m.class end
        a.l = nil   -- present (again)
        if m.online and rec.zone and m.zone == rec.zone then inside = true end
    end
    for key, a in pairs(rec.att) do
        if not roster[key] and not a.l and not a.b then a.l = now end
    end
    if inside then rec.last = now end
end

local function ScheduleScan()
    if scanPending then return end
    scanPending = true
    Util.After(ROSTER_DELAY, function()
        scanPending = false
        local rec = OpenRecord()
        if rec then
            Scan(rec)
            Changed(rec)
        end
    end)
end

local function Open(session)
    local raids = RaidsDB()
    if not raids then return nil end
    local rec = raids[session.id]
    if type(rec) ~= "table" then
        rec = { id = session.id, start = session.at, by = session.by, bosses = {}, att = {},
            last = GetServerTime() }
        raids[session.id] = rec
        ns:Print("raid session started%s. The raid log is recording.",
            session.by and not Util.IsMe(session.by) and (" by " .. Util.ShortName(session.by)) or "")
    elseif rec.stop then
        -- A session this client closed (e.g. it left the raid for a moment) is running again: reopen it.
        rec.stop, rec.endedBy, rec.autoEnded = nil, nil, nil
    end
    ns.db.raidCurrent = rec.id
    Scan(rec)
    Changed(rec)
    return rec
end

-- endedBy = the authority that ended it; nil = the safety net (stop = the last activity).
local function Close(rec, endedBy)
    if not rec or rec.stop then return end
    local now = GetServerTime()
    if endedBy then
        Scan(rec)
        rec.stop = now
        rec.endedBy = endedBy
    else
        rec.stop = math.max(tonumber(rec.last) or rec.start or now, rec.start or 0)
        rec.autoEnded = true
    end
    for _, a in pairs(rec.att or {}) do
        if not a.l then a.l = rec.stop end
    end
    if ns.db and ns.db.raidCurrent == rec.id then ns.db.raidCurrent = nil end
    ns:Print("raid session ended%s.", endedBy and not Util.IsMe(endedBy) and (" by " .. Util.ShortName(endedBy)) or "")
    Changed(rec)
end

-- Brings the open record in line with the authority's session.
local function Reconcile()
    if not ns.db then return end
    local rec = OpenRecord()
    if not IsInRaid() then
        if rec then Close(rec, nil) end
        return
    end
    local GR = ns.GroupRules
    if not GR then return end
    local status, from = GR:GetStatus()
    if status == "own" then return end      -- no authority rules known right now: wait
    local s = GR:GetSession()
    if s then
        if rec and rec.id ~= s.id then Close(rec, nil) end
        if not rec or rec.id ~= s.id then Open(s) end
    elseif rec then
        Close(rec, from or Util.PlayerKey())
    end
end

local function OnEncounterEnd(_, encounterID, encounterName, _, _, success)
    if success ~= 1 and success ~= true then return end
    local rec = OpenRecord()
    if not rec then return end
    local enc = tonumber(encounterID)
    rec.bosses = type(rec.bosses) == "table" and rec.bosses or {}
    for _, b in ipairs(rec.bosses) do
        if b.enc == enc then return end   -- already recorded (the same kill seen twice)
    end
    Scan(rec)
    local now = GetServerTime()
    local roster = Roster()
    local keys, off = {}, nil
    for key, m in pairs(roster) do
        keys[#keys + 1] = key
        local a = rec.att[key]
        if a then a.k = (tonumber(a.k) or 0) + 1 end
        if not m.online then
            off = off or {}
            off[key] = true
        end
    end
    tsort(keys)
    rec.bosses[#rec.bosses + 1] = { enc = enc, name = type(encounterName) == "string" and encounterName or nil,
        ts = now, roster = keys, off = off }
    rec.last = now
    Changed(rec)
end

---------------------------------------------------------------------------
-- "No raid session" reminder (§48: forgot to start)
---------------------------------------------------------------------------

-- A boss pull in a raid instance without a session: the authority gets a chat reminder (a popup would get in the
-- way of the pull and the loot windows). A session started after a missed pull is backdated to when I entered
-- the instance.
local function OnEncounterStart()
    if not (IsInRaid() and Util.InRaidInstance()) then return end
    local GR = ns.GroupRules
    if not (GR and GR:IsAuthority()) or GR:GetSession() then return end
    missedPull = true
    if GetTime() - promptedAt < PROMPT_SNOOZE then return end
    promptedAt = GetTime()
    ns:Print("no raid session is running, so this raid is not being logged. Type /cdl raid start to start one.")
end

local function OnEnteringWorld()
    if IsInRaid() and Util.InRaidInstance() then
        if not zoneEnteredAt then zoneEnteredAt = GetServerTime() end
    else
        zoneEnteredAt = nil
        missedPull = false
    end
    ScheduleScan()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- The id of the raid session being recorded now, or nil.
function RaidLog:GetCurrentID()
    if not IsInRaid() then return nil end
    local rec = OpenRecord()
    return rec and rec.id or nil
end

-- The open record when a new authority may resume it (I am in a raid and it was active recently), or nil.
function RaidLog:GetResumable()
    if not IsInRaid() then return nil end
    local rec = OpenRecord()
    if not rec then return nil end
    local last = tonumber(rec.last) or tonumber(rec.start) or 0
    if GetServerTime() - last > RESUME_MAX_IDLE then return nil end
    return { id = rec.id, start = rec.start }
end

function RaidLog:GetRaid(id)
    local raids = RaidsDB()
    return raids and type(id) == "string" and raids[id] or nil
end

-- The raids of my current guild (and untagged ones), newest first. Stored tables: treat as read-only.
function RaidLog:GetRaids()
    local raids = RaidsDB()
    local out = {}
    if not raids then return out end
    local g = GuildKey()
    for _, rec in pairs(raids) do
        if type(rec) == "table" and (rec.g == nil or rec.g == g) then out[#out + 1] = rec end
    end
    tsort(out, function(a, b) return (a.start or 0) > (b.start or 0) end)
    return out
end

-- startAt (optional): an earlier start time; default = now, or my instance entry after a missed boss pull.
function RaidLog:Start(startAt)
    local GR = ns.GroupRules
    if not GR then return false end
    if not startAt and missedPull then startAt = zoneEnteredAt end
    local ok, err = GR:SetSession(true, startAt)
    if not ok then ns:Print("%s", tostring(err)) end
    return ok
end

function RaidLog:End()
    local GR = ns.GroupRules
    if not GR then return false end
    local ok, err = GR:SetSession(false)
    if not ok then ns:Print("%s", tostring(err)) end
    return ok
end

---------------------------------------------------------------------------
-- Retention
---------------------------------------------------------------------------

function RaidLog:Prune(now)
    local raids = RaidsDB()
    if not raids then return end
    now = now or GetServerTime()
    local keepDays = tonumber(ns.DB and ns.DB.GetSetting and ns.DB:GetSetting("raidlog.keepDays")) or 365
    for id, rec in pairs(raids) do
        if type(rec) ~= "table" or type(rec.start) ~= "number" then
            raids[id] = nil
        elseif rec.stop and now - rec.start > keepDays * DAY then
            raids[id] = nil
        elseif now - rec.start > ROSTER_KEEP_DAYS * DAY then
            for _, b in ipairs(rec.bosses or {}) do
                b.roster, b.off = nil, nil
            end
        end
    end
end

---------------------------------------------------------------------------
-- Slash: /cdl raid start | end | status
---------------------------------------------------------------------------

local function FormatDuration(sec)
    sec = floor(math.max(0, sec or 0))
    return ("%d:%02d:%02d"):format(floor(sec / 3600), floor(sec % 3600 / 60), sec % 60)
end

local function SlashRaid(rest)
    local cmd = (rest or ""):match("^(%S*)"):lower()
    if cmd == "start" then
        if ns.GroupRules and ns.GroupRules:GetSession() then
            ns:Print("a raid session is already running.")
            return
        end
        RaidLog:Start()
    elseif cmd == "end" or cmd == "stop" then
        if not (ns.GroupRules and ns.GroupRules:GetSession()) then
            ns:Print("no raid session is running.")
            return
        end
        RaidLog:End()
    else
        local rec = OpenRecord()
        if rec then
            ns:Print("raid session: %s, %s, %d boss(es), %d raider(s).", rec.zone or "zone not seen yet",
                FormatDuration(GetServerTime() - (rec.start or GetServerTime())), #(rec.bosses or {}), Util.Count(rec.att or {}))
        else
            ns:Print("no raid session is running. /cdl raid start (raid leader) starts one.")
        end
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function RaidLog:OnInit()
    ns:On("GROUP_RULES_CHANGED", Reconcile)
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        if not IsInRaid() then Reconcile() end
        ScheduleScan()
    end)
    ns:RegisterEvent("ENCOUNTER_START", OnEncounterStart)
    ns:RegisterEvent("ENCOUNTER_END", OnEncounterEnd)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)
    ns:RegisterSlash("raid", SlashRaid, "start | end | status - the raid session and raid log (raid leader starts / ends)")
end

function RaidLog:OnLogin()
    self:Prune()
    local function Tick()
        local rec = OpenRecord()
        if rec and IsInRaid() then
            Scan(rec)
            Changed(rec)
        end
        Util.After(SCAN_INTERVAL, Tick)
    end
    Util.After(SCAN_INTERVAL, Tick)
end
