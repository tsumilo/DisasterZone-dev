if DisasterZoneBoot and DisasterZoneBoot.Run("Core/OfficerNotes.lua", ...) then return end -- DisasterZone: officer notes on guild members.
-- A longer note per character than the guild pane's officer note, kept by DisasterZone and separate from it. Only officers
-- (the Guild Master and the rank below, per the live guild roster) read and write them, and they travel only as
-- whispers between officers: a note is sent to officers, and taken from officers, never over a channel.
--
-- Data (SavedVariables: db.officerNotes[guildKey][charKey]) = { t = text ("" = removed), rev, by }; the newer rev wins.
-- The developer's debug role (/dz role gm | officer) shows the notes UI to a character that is no officer: such a
-- character's notes are kept apart (db.officerNotes["debug " .. guildKey]) and never sent, and it takes none: the
-- network side always goes by the real rank.
-- Messages (WHISPER, class "data"):
--   ON  { k, n = text, v = rev, by }   one note
--   ONI { i = { [key] = rev }, r }     what I have: the receiver sends what is newer and, unless r, its own ONI
local addonName, ns = ...

local Notes = ns:NewModule("OfficerNotes")
local Util = ns.Util

local type, pairs, ipairs, tostring = type, pairs, ipairs, tostring
local floor, max = math.floor, math.max

local MAX_LEN = 600
local MAX_KEY_LEN = 48
local MAX_REV = 2147483647
local FUTURE_SLACK = 60
local MAX_NOTES = 1000          -- entries taken from one ONI
local LOGIN_DELAY = 30
local REPLY_LIMIT = 30

Notes.MAX_LEN = MAX_LEN

local indexSent = false

local Now, IsInt = Util.Now, Util.IsInt

local function Guild() return ns.Guild end

local function WireKey(s)
    if type(s) ~= "string" or s == "" or #s > MAX_KEY_LEN or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

-- Line breaks stay; other control characters and escape codes (colours, links) go.
local function Clean(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("\r", ""):gsub("[%z\1-\9\11-\31]", ""):gsub("|", "")
    return Util.Trim(text)
end

-- An officer by the real guild rank (never the debug role).
local function RealOfficer(key)
    local G = Guild()
    return (G and G:IsReady() and G:IsOfficer(key, true)) and true or false
end

-- I see the notes only through a debug role: what I write stays on this PC, apart from the real notes.
local function Pretending()
    local G = Guild()
    local me = Util.PlayerKey()
    return (G and me and G:IsOfficer(me) and not RealOfficer(me)) and true or false
end

local function Store(create)
    local gk = ns.db and IsInGuild() and Util.GuildKey()
    if type(gk) ~= "string" then return nil end
    if Pretending() then gk = "debug " .. gk end
    return (ns.DB:GuildBucket("officerNotes", create, gk))
end

local function Valid(rec)
    return type(rec) == "table" and type(rec.t) == "string" and #rec.t <= MAX_LEN and IsInt(rec.rev, 1, MAX_REV)
end

-- Officers per the live roster, online, without me.
local function OnlineOfficers()
    local G = Guild()
    local out = {}
    if not (G and G:IsReady()) then return out end
    if not RealOfficer(Util.PlayerKey()) then return out end   -- (a debug role sends nothing)
    for _, key in ipairs(G:GetOnlineMembers()) do
        if not Util.IsMe(key) and G:IsOfficer(key, true) then out[#out + 1] = key end
    end
    return out
end

local function Send(msg, target)
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, "WHISPER", target, "data")) and true or false
end

local function SendNote(key, rec, target)
    return Send({ t = "ON", k = key, n = rec.t, v = rec.rev, by = rec.by }, target)
end

-- Officers read and write the notes (the Guild Master and the rank below).
function Notes:CanUse()
    local G = Guild()
    return (IsInGuild() and G and G:IsReady() and G:IsOfficer(Util.PlayerKey())) and true or false
end

-- True while the notes I see and write are test notes of a debug role: kept on this PC, never shared.
function Notes:IsLocalOnly()
    return Pretending()
end

-- { text, rev, by } of a character's note, or nil (none, or I am no officer).
function Notes:Get(key)
    if not self:CanUse() then return nil end
    local b = Store(false)
    local rec = b and type(key) == "string" and b[key]
    if not Valid(rec) or rec.t == "" then return nil end
    return { text = rec.t, rev = rec.rev, by = rec.by }
end

-- Saves (text "" removes) a character's note and sends it to the officers online. Returns ok, err.
function Notes:Set(key, text)
    if not self:CanUse() then return false, "only officers and the Guild Master keep officer notes" end
    local G = Guild()
    if type(key) ~= "string" or not G:IsInGuild(key, true) then return false, "not a guild member" end
    text = Clean(text)
    if not text then return false, "invalid text" end
    if #text > MAX_LEN then return false, ("the note is too long (%d of %d letters)"):format(#text, MAX_LEN) end
    local b = Store(true)
    if not b then return false, "your guild is not known yet" end
    local old = Valid(b[key]) and b[key] or nil
    if (old and old.t or "") == text then return true end
    local rec = { t = text, rev = max(Now(), (old and old.rev or 0) + 1), by = Util.PlayerKey() }
    b[key] = rec
    ns.AuditSaw("on.N", old, rec, { key = key, mine = true })
    for _, officer in ipairs(OnlineOfficers()) do SendNote(key, rec, officer) end
    ns:Fire("OFFICER_NOTES_UPDATED", key)
    return true
end

local function Index()
    local i = {}
    for key, rec in pairs(Store(false) or {}) do
        if Valid(rec) then i[key] = rec.rev end
    end
    return i
end

local function SendIndex(target, isReply)
    return Send({ t = "ONI", i = Index(), r = isReply and 1 or nil }, target)
end

-- Both ends must be officers by the roster I see: a note is never taken from, or given to, anyone else.
local function Trusted(sender, dist)
    local G = Guild()
    if dist ~= "WHISPER" or not (G and G:IsReady()) then return false end
    return G:IsOfficer(sender, true) and G:IsOfficer(Util.PlayerKey(), true) and true or false
end

local function OnNote(sender, msg, dist)
    if not Trusted(sender, dist) then return end
    local key = WireKey(msg.k)
    local text = Clean(msg.n)
    if not key or not text or #text > MAX_LEN or not IsInt(msg.v, 1, Now() + FUTURE_SLACK) then return end
    local by = msg.by ~= nil and WireKey(msg.by) or sender
    local b = Store(true)
    if not b then return end
    local old = Valid(b[key]) and b[key] or nil
    if old and (old.rev > msg.v or (old.rev == msg.v and old.t >= text)) then return end
    b[key] = { t = text, rev = msg.v, by = by }
    ns.AuditSaw("on.N", old, b[key], { key = key, via = sender })
    ns:Fire("OFFICER_NOTES_UPDATED", key)
end

local function OnIndex(sender, msg, dist)
    if not Trusted(sender, dist) or type(msg.i) ~= "table" then return end
    local Comm = ns.Comm
    if Comm and Comm.RateLimit and not Comm:RateLimit("oni:" .. sender, REPLY_LIMIT) then return end
    local theirs, n, theyHaveNewer = {}, 0, false
    local mine = Store(false) or {}
    for key, rev in pairs(msg.i) do
        n = n + 1
        if n > MAX_NOTES then break end
        if type(key) == "string" and IsInt(rev, 1, MAX_REV) then
            theirs[key] = rev
            local rec = Valid(mine[key]) and mine[key] or nil
            if not rec or rec.rev < rev then theyHaveNewer = true end
        end
    end
    for key, rec in pairs(mine) do
        if Valid(rec) and (theirs[key] or 0) < rec.rev then SendNote(key, rec, sender) end
    end
    if theyHaveNewer and msg.r ~= 1 then SendIndex(sender, true) end
end

-- Once per session, when the roster shows me as an officer: compare notes with the officers online.
local function Share()
    if indexSent or not RealOfficer(Util.PlayerKey()) then return end
    indexSent = true
    for _, officer in ipairs(OnlineOfficers()) do SendIndex(officer) end
end

function Notes:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("ON", OnNote)
        Comm:Register("ONI", OnIndex)
    end
    ns:On("CONFIG_UPDATED", function() ns:Fire("OFFICER_NOTES_UPDATED") end)   -- (my rank / debug role changed)
end

function Notes:OnLogin()
    Util.After(LOGIN_DELAY, Share)
    ns:On("ROSTER_UPDATED", function()
        if not indexSent then Util.Debounce("officer-notes-share", LOGIN_DELAY, Share) end
    end)
end
