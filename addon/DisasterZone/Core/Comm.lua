if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Comm.lua", ...) then return end -- DisasterZone: addon-message transport. AceComm-3.0 (+ChatThrottleLib) for chunking/throttling,
-- LibSerialize + LibDeflate for the payload. Four prefixes (ctrl, data, alert, game), one priority each; every received
-- message is gated on the server-provided sender before it is decoded and dispatched.
local addonName, ns = ...

local Comm = ns:NewModule("Comm")
local Util = ns.Util

local type, pairs, ipairs, tostring, pcall = type, pairs, ipairs, tostring, pcall
local strsub = string.sub

local AceComm = LibStub and LibStub("AceComm-3.0", true)
local LibSerialize = LibStub and LibStub("LibSerialize", true)
local LibDeflate = LibStub and LibStub("LibDeflate", true)

if AceComm then
    AceComm:Embed(Comm)
end

-- "game" (CDLg) carries only minigame traffic, so its per-prefix server budget never delays council sync.
-- "member" (CDLm) carries the guild's professions and recipes (Core/Professions.lua), for the same reason.
local PREFIX = { ctrl = "CDLc", data = "CDLd", alert = "CDLa", game = "CDLg", member = "CDLm" }
local PRIORITY = { ctrl = "NORMAL", data = "BULK", alert = "ALERT", game = "BULK", member = "BULK" }
local CLASS_BY_PREFIX = { CDLc = "ctrl", CDLd = "data", CDLa = "alert", CDLg = "game", CDLm = "member" }

local MAX_WIRE_LEN = 24000       -- encoded bytes accepted from one message (council: manifests, relays)
local MAX_WIRE_LEN_MEMBER = 4000 -- from anyone else: a full own list is ~1.1 KB, HELLO / rolls / drops far less
local MAX_INFLATED_LEN = 200000  -- decompressed bytes accepted
local MAX_INFLATED_LEN_MEMBER = 16384   -- from a non-council sender (a full 5-phase own list is ~0.7 KB inflated)
-- Deflate can expand a few wire bytes ~400-fold (a 250-byte message -> 99 KB of '{}'), so the wire caps alone do
-- not bound the decode work. Real DisasterZone payloads (item ids, names, revs) inflate at most ~2:1: anything past
-- this ratio is refused before it is deserialized, and the sender is ignored for the rest of the session.
local MAX_INFLATE_RATIO = 16
local INFLATE_SLACK = 2048
local HOLD_MAX = 40              -- messages held while the guild roster is not known yet
local HOLD_SECONDS = 60
local WHISPER_MEMORY = 15        -- seconds a whisper target is remembered for the "No player named" filter

local handlers = {}              -- [msgType] = fn(senderKey, msg, distribution)
local rateLimits = {}            -- [key] = GetTime() of the last allowed call
local held = {}                  -- { {prefix=, text=, dist=, key=, at=} ... }
local holdTimerRunning = false
local recentWhispers = {}        -- [key] = GetTime()
local oversized = {}             -- [key] = true: sent a payload that inflated past the cap (ignored this session)
local notFoundPattern

Comm.stats = { sent = 0, recv = 0, bytesSent = 0, dropped = 0 }

local function ProtoMajor()
    return tostring(ns.PROTO or 1)
end

local function Available()
    return AceComm ~= nil and LibSerialize ~= nil and LibDeflate ~= nil
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

local function Encode(msg)
    local serialized = LibSerialize:Serialize(msg)
    local compressed = LibDeflate:CompressDeflate(serialized)
    return ProtoMajor() .. LibDeflate:EncodeForWoWAddonChannel(compressed)
end

-- member: the sender is not council (smaller inflate cap).
local function Decode(body, member)
    local decoded = LibDeflate:DecodeForWoWAddonChannel(body)
    if not decoded then error("decode failed", 0) end
    local inflated = LibDeflate:DecompressDeflate(decoded)
    if type(inflated) ~= "string" then error("decompress failed", 0) end
    local n = #inflated
    if n > MAX_INFLATED_LEN or n > MAX_INFLATE_RATIO * #decoded + INFLATE_SLACK
        or (member and n > MAX_INFLATED_LEN_MEMBER) then
        error("payload too large", 0)
    end
    local ok, value = LibSerialize:Deserialize(inflated)
    if not ok then error("deserialize failed: " .. tostring(value), 0) end
    return value
end

---------------------------------------------------------------------------
-- Group helper (real group only; demo raid members are not real senders)
---------------------------------------------------------------------------

local function IsRealGroupMember(key)
    if type(key) ~= "string" then return false end
    local group = Util.group
    if type(group) == "table" and group[key] then return true end
    -- The group cache refreshes on a short debounce; ask the client directly as a fallback.
    local unitName = Ambiguate and Ambiguate(key, "none") or key
    if UnitInRaid and UnitInRaid(unitName) then return true end
    if UnitInParty and UnitInParty(unitName) then return true end
    return false
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function SendText(class, text, distribution, target)
    Comm:SendCommMessage(PREFIX[class], text, distribution, target, PRIORITY[class])
    Comm.stats.sent = Comm.stats.sent + 1
    Comm.stats.bytesSent = Comm.stats.bytesSent + #text
end

-- Checks the distribution and resolves the whisper target. Returns ok, target.
local function CheckRoute(distribution, target)
    if distribution == "WHISPER" then
        local key = Util.NormalizeName(target)
        if not key or Util.IsMe(key) then return false end
        local Guild = ns.Guild
        local online = Guild and Guild:IsOnline(key, true)
        if not online and not IsRealGroupMember(key) then return false end
        recentWhispers[key] = GetTime()
        return true, (Ambiguate and Ambiguate(key, "none") or key)
    elseif distribution == "GUILD" then
        return IsInGuild() and true or false
    elseif distribution == "RAID" then
        return IsInRaid() and true or false
    elseif distribution == "PARTY" then
        return IsInGroup() and true or false
    end
    return false
end

-- msg = table with string field t. class = "ctrl" | "data" | "alert" | "game" | "member" (default "ctrl").
function Comm:Send(msg, distribution, target, class)
    if not Available() or not ns.loggedIn then return false end
    if type(msg) ~= "table" or type(msg.t) ~= "string" then return false end
    class = class or "ctrl"
    if not PREFIX[class] then return false end
    local ok, resolved = CheckRoute(distribution, target)
    if not ok then return false end
    local encOk, text = pcall(Encode, msg)
    if not encOk then
        ns:Debug("Comm: could not encode '%s': %s", tostring(msg.t), tostring(text))
        return false
    end
    SendText(class, text, distribution, distribution == "WHISPER" and resolved or nil)
    return true
end

-- Whispers msg to every online council peer (excluding me). Returns the number of sends.
function Comm:SendToCouncil(msg, class)
    if not Available() or not ns.loggedIn then return 0 end
    if type(msg) ~= "table" or type(msg.t) ~= "string" then return 0 end
    local Sync = ns.Sync
    local peers = (Sync and Sync.GetOnlineCouncilPeers) and Sync:GetOnlineCouncilPeers() or {}
    if #peers == 0 then return 0 end
    class = class or "ctrl"
    if not PREFIX[class] then return 0 end
    local encOk, text = pcall(Encode, msg)   -- encode once for all recipients
    if not encOk then
        ns:Debug("Comm: could not encode '%s': %s", tostring(msg.t), tostring(text))
        return 0
    end
    local n = 0
    for _, key in ipairs(peers) do
        local ok, resolved = CheckRoute("WHISPER", key)
        if ok then
            SendText(class, text, "WHISPER", resolved)
            n = n + 1
        end
    end
    return n
end

function Comm:Register(msgType, handler)
    if type(msgType) ~= "string" or type(handler) ~= "function" then
        error("Comm:Register(msgType, handler): bad arguments", 2)
    end
    if handlers[msgType] then
        ns:Debug("Comm: handler for '%s' replaced", msgType)
    end
    handlers[msgType] = handler
end

-- True if allowed now (and records the call); false if called again within `seconds`.
function Comm:RateLimit(key, seconds)
    local now = GetTime()
    local last = rateLimits[key]
    if last and now - last < (seconds or 0) then
        return false
    end
    rateLimits[key] = now
    return true
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- Whispers a member of my group who is not in my guild (another guild's raid leader or pick, a guildless
-- master looter, or me being guildless) may send: only these group-scoped types.
local GROUP_WHISPER_TYPES = { RT = true }

local Hold   -- forward declaration

-- Runs after the sender gate: protocol check, decode, then the registered handler.
-- allow (optional): a set of message types; others are dropped (cross-guild group whispers), or held like any
-- whisper from a sender missing from the roster when holdDenied is true (a brand-new guild member).
local function Dispatch(prefix, text, distribution, senderKey, allow, holdDenied)
    local major = strsub(text, 1, 1)
    if major ~= ProtoMajor() then
        local Sync = ns.Sync
        if Sync and Sync.NotePeerProtocol then Sync:NotePeerProtocol(senderKey, major) end
        return
    end
    -- Inflating is the expensive step: only council members may send large messages, and a sender
    -- whose payload already blew the inflate cap is not decoded again this session.
    local Guild = ns.Guild
    local council = (Guild and (Guild:IsCouncil(senderKey, true)
        or (Guild.IsRaidLogMember and Guild:IsRaidLogMember(senderKey)))) and true or false
    local limit = council and MAX_WIRE_LEN or MAX_WIRE_LEN_MEMBER
    if oversized[senderKey] or #text > limit then
        Comm.stats.dropped = Comm.stats.dropped + 1
        ns:Debug("Comm: oversized message from %s dropped", senderKey)
        return
    end
    local ok, msg = pcall(Decode, strsub(text, 2), not council)
    if not ok then
        Comm.stats.dropped = Comm.stats.dropped + 1
        if msg == "payload too large" then oversized[senderKey] = true end
        ns:Debug("Comm: dropped message from %s (%s)", senderKey, tostring(msg))
        return
    end
    if type(msg) ~= "table" or type(msg.t) ~= "string" then
        Comm.stats.dropped = Comm.stats.dropped + 1
        return
    end
    if allow and not allow[msg.t] then
        if holdDenied then
            Hold(prefix, text, distribution, senderKey)
            return
        end
        Comm.stats.dropped = Comm.stats.dropped + 1
        ns:Debug("Comm: '%s' whisper from %s (not in my guild) dropped", tostring(msg.t), senderKey)
        return
    end
    local handler = handlers[msg.t]
    if not handler then
        ns:Debug("Comm: no handler for '%s' from %s", tostring(msg.t), senderKey)
        return
    end
    if distribution == "GUILD" or distribution == "WHISPER" then
        local Guild = ns.Guild
        if Guild and Guild.MarkOnline then Guild:MarkOnline(senderKey) end
    end
    if ns.SafeCall then
        ns.SafeCall(handler, senderKey, msg, distribution)
    else
        xpcall(function() handler(senderKey, msg, distribution) end, geterrorhandler())
    end
end

local ProcessHeld

local function ScheduleHoldCheck()
    if holdTimerRunning then return end
    holdTimerRunning = true
    Util.After(10, function()
        holdTimerRunning = false
        ProcessHeld(true)
    end)
end

Hold = function(prefix, text, distribution, senderKey)
    if #held >= HOLD_MAX then
        table.remove(held, 1)
    end
    held[#held + 1] = { prefix = prefix, text = text, dist = distribution, key = senderKey, at = GetTime() }
    local Guild = ns.Guild
    if Guild and Guild.RequestRoster then Guild:RequestRoster() end
    ScheduleHoldCheck()
end

-- Re-checks held messages: dispatch those whose sender is now a known guild member, drop
-- those that are too old (or, once the roster is known, whose sender still isn't in it
-- after a timer-driven check).
ProcessHeld = function(fromTimer)
    if #held == 0 then return end
    local Guild = ns.Guild
    local ready = Guild and Guild:IsReady()
    local now = GetTime()
    local keep = {}
    local release = {}
    for _, h in ipairs(held) do
        if ready and Guild:IsInGuild(h.key, true) then
            release[#release + 1] = h
        elseif now - h.at < HOLD_SECONDS and not (ready and fromTimer and now - h.at >= 20) then
            keep[#keep + 1] = h
        end
    end
    held = keep
    for _, h in ipairs(release) do
        Dispatch(h.prefix, h.text, h.dist, h.key)
    end
    if #held > 0 then ScheduleHoldCheck() end
end

function Comm:OnCommReceived(prefix, text, distribution, sender)
    if not CLASS_BY_PREFIX[prefix] or not ns.loggedIn or not Available() then return end
    if type(text) ~= "string" or type(sender) ~= "string" then return end
    local senderKey = Util.NormalizeName(sender)
    if not senderKey or Util.IsMe(senderKey) then return end
    Comm.stats.recv = Comm.stats.recv + 1
    if #text < 2 or #text > MAX_WIRE_LEN then
        Comm.stats.dropped = Comm.stats.dropped + 1
        ns:Debug("Comm: empty or oversized message from %s dropped", senderKey)
        return
    end

    -- Sender gate before decoding: only guild members (GUILD/WHISPER) or group members (RAID/PARTY).
    if distribution == "GUILD" or distribution == "WHISPER" then
        local Guild = ns.Guild
        if not Guild then return end
        if not Guild:IsInGuild(senderKey, true) then
            if distribution == "WHISPER" and IsRealGroupMember(senderKey) then
                -- A raid / party member of another guild (or I have none): group-scoped whispers (RT) now; any
                -- other type waits like before, in case the roster is still loading or misses a new member.
                Dispatch(prefix, text, distribution, senderKey, GROUP_WHISPER_TYPES, IsInGuild())
            elseif IsInGuild() then
                Hold(prefix, text, distribution, senderKey)   -- roster may not be loaded yet
            end
            return
        end
    elseif distribution == "RAID" or distribution == "PARTY" then
        if not IsRealGroupMember(senderKey) then return end
    else
        return
    end
    Dispatch(prefix, text, distribution, senderKey)
end

---------------------------------------------------------------------------
-- "No player named 'X' is currently playing." suppression for our own addon whispers
---------------------------------------------------------------------------

local function FormatToPattern(fmt)
    local p = fmt:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
    p = p:gsub("%%s", "(.+)")
    p = p:gsub("%%d", "(%%d+)")
    return "^" .. p .. "$"
end

local function SystemMessageFilter(_, _, message, ...)
    if not notFoundPattern or type(message) ~= "string" then return false end
    local name = message:match(notFoundPattern)
    if not name then return false end
    local key = Util.NormalizeName(name)
    local t = key and recentWhispers[key]
    if t and GetTime() - t < WHISPER_MEMORY then
        local Guild = ns.Guild
        if Guild and Guild.MarkOffline then Guild:MarkOffline(key) end
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Comm:OnInit()
    if not Available() then
        ns:Print("embedded communication libraries are missing; syncing is disabled.")
        return
    end
    for _, prefix in pairs(PREFIX) do
        Comm:RegisterComm(prefix, "OnCommReceived")
    end
    ns:On("ROSTER_UPDATED", function() ProcessHeld(false) end)
end

function Comm:OnLogin()
    if type(ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" and ERR_CHAT_PLAYER_NOT_FOUND_S ~= "" then
        notFoundPattern = FormatToPattern(ERR_CHAT_PLAYER_NOT_FOUND_S)
        local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
        if addFilter then
            addFilter("CHAT_MSG_SYSTEM", SystemMessageFilter)
        end
    end
    -- Forget old whisper targets now and then.
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(120, function()
            local now = GetTime()
            for key, t in pairs(recentWhispers) do
                if now - t > WHISPER_MEMORY then recentWhispers[key] = nil end
            end
            for key, t in pairs(rateLimits) do
                if now - t > 600 then rateLimits[key] = nil end
            end
        end)
    end
end

-- Debug helper for the harness / "/dump": pending held messages.
function Comm:GetHeldCount()
    return #held
end

