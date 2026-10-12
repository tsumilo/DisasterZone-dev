if DisasterZoneBoot and DisasterZoneBoot.Run("Core/EventLive.lua", ...) then return end -- DisasterZone: events while they run.
-- A live event: its host's client runs it (Core/EventEngine.lua) and tells the guild where it stands; the entrants'
-- clients see their duels end and tell the host; everyone can watch. The builder's practice run lives here too.
--
-- Wire (class "event", CDLe):
--   EVS { o, h, s = state, c = hosts } GUILD: the run's state (after a change, at most every 2 s and one at a time:
--         a newer one waits until the last one is out). h is the host; a state naming someone else as host hands
--         the run over (that client goes on with it). Only the host I know sends it (or hands it on), or an entrant
--         taking over once that host went quiet; anyone else's is not listened to.
--   EVH { o, h, q = seq } GUILD every 10 s: the host is there (q: the last state sent; anyone behind asks with EVQ).
--   EVQ { o } WHISPER to the host: send me the state (it goes out with the next state on GUILD, for all who asked).
--   EVF { o, k, ... } WHISPER to the host: a fact. k = "duel" { w, l } (only the two duelists report; the loser's word
--         counts at once, the winner's once the loser says the same or after 10 s as "not agreed", which makes the
--         Bracket ask both players), "ready", "answer" { a = ask id, v = player }, "join" / "leave", "watch".
--         What an entrant's game sees (Core/EventSensors.lua, only what the def uses; each with `at`): "h" { what,
--         other, item, name, count, creature, emote }, "place" { pid, in }, "touch" { whom, how, near, emote },
--         "radar" { whom }, "pos" { map, x, y, cont, wx, wy, z, sz, flags, items, gold: what changed }; and the
--         player's own: "ans" { aid, v } (an answer to an ask), "press" { label } (a button); "b" { f = facts } (those
--         of one moment in one message). Sent a frame later, 6 messages at once then 1 a second. The host takes them
--         from entrants only, for what the def uses, 16 at once then 4 a second each; "pos" stays on the host (never
--         in a state that goes out).
--   EVM { o, to, k, text, off, at } from the host: k = "show" (a banner), "tell" (a tracker line), "sound", "plates"
--         (off: hide friendly nameplates / show them again). GUILD with to = "all" (every entrant) or to = keys (4 or
--         more), else WHISPER to each; 8 at once, then 1 a second (the prefix's own pace), and the same line waiting
--         for several players goes as one GUILD message naming them. Taken only from the host I know.
-- A run's "post in guild chat" is the host's: once every 10 s at most and 20 an event, never in demo mode or practice.
-- The host gone (no EVS / EVH for 50 s and offline, or 90 s whatever): the entrants still online take over in name
-- order, each waiting its turn; the first one sends the state with itself as host and goes on from there (everything
-- carries on: timers, matches, stats, open asks, the scripts that were waiting; a secret ask's answers so far are
-- known as given only). The host's own /reload: its runs are kept at logout and go on after it (db.eventHosting,
-- read and cleared at login). Either way the entrants send again their answers the new state doesn't show.
local addonName, ns = ...

local Live = ns:NewModule("EventLive")
local Util = ns.Util

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local tinsert, tremove, tsort, tconcat = table.insert, table.remove, table.sort, table.concat
local floor, max, min = math.floor, math.max, math.min
local strsub = string.sub

local SEND_GAP = 2            -- seconds between two states sent (changes in between go out together)
local HEARTBEAT = 10
local GONE_SILENT = 50        -- the host is gone after this long without a word (and offline)
local GONE_ANYWAY = 90
local TAKEOVER_STEP = 6       -- seconds between one entrant's turn to take over and the next one's
local DUEL_WAIT = 10          -- a winner's report waits this long for the loser's
local GONE_FOR_GOOD = 600     -- a run nobody hosts any more (its host gone, no entrant took over) is forgotten then
local QUIET_SLACK = 10        -- an entrant taking over heard the host last about when I did (give or take this)
local MAX_CHAIN = 8           -- hosts a state names (the first one and the last ones)
local FROM_ME_AHEAD = 5       -- changes an entrant who took my run over can be past my own state
local FACT_SEND_BURST = 6     -- messages of facts I send at once, then FACT_SEND_RATE a second (an addon prefix
local FACT_SEND_RATE = 1      -- carries about that: 10 at once, then 1 a second); what waits goes in one message
local FACT_BATCH = 8          -- facts in one message at most
local FACT_QUEUE = 24         -- facts waiting (past that the oldest position goes, else the oldest)
local FACT_PER_SEC = 4        -- facts the host takes from one entrant a second ...
local FACT_HOST_BURST = 16    -- ... after a burst of this many (a pull of a dozen kills)
local EVM_BURST = 8           -- the host's messages to players at once, then EVM_RATE a second (the event message
local EVM_RATE = 1            -- prefix carries about 10 at once, then 1 a second); the rest wait, and the same line
local EVM_QUEUE = 80          -- waiting for several players goes to them together (one GUILD message naming them)
local EVM_STALE = 20          -- a banner or a sound older than this is dropped (a tell line still goes in the feed)
local FEED_MAX = 20           -- "tell" lines kept for the tracker
local GUILD_GAP = 10          -- a run's guild posts: one every 10 s at most ...
local GUILD_MAX = 20          -- ... and 20 an event
local GUILD_WAIT = 3          -- (posts waiting their turn; past that the oldest waiting one is dropped)
local TEXT_LEN = 250

local hosting = {}            -- [occId] = { run, occ, hosts, sendAt, dirty, pending, recent, watchers, lastBeat }
local seen = {}               -- [occId] = { st, h, c, at (GetTime), def }
local shownAnn, shownCd = {}, {}
local practice                -- { run, def, clock, dummies, off }
local ticker
local inviteQueue = {}        -- keys a run asked to invite and not invited yet
local invitedAt = {}          -- [key] = GetTime() their invite went out
local factQueue = {}          -- { {occId, msg} } my facts over the rate
local factTokens, factAt, factFlushing = FACT_SEND_BURST, 0, false
local pendingEvm = {}         -- [occId] = { {sender, msg, dist, at} } messages that came before the state they need
local evmQueue, evmFlushing = {}, false   -- the host's EVM over the rate
local evmTokens, evmAt = EVM_BURST, 0
local feeds = {}              -- [occId] = { {at, text} } "tell" lines to me, newest first
local myAnswers = {}          -- [occId] = { [aid .. "@" .. at] = value } my answers to asks (a secret one's too)
local answerSent = {}         -- [occId .. "/" .. aid .. "@" .. at] = GetTime() my answer last went out
local myPoint = {}            -- [occId] = pid: the place I asked to be shown the way to (PointMe; never sent)
local ANSWER_AGAIN = 5        -- an answer the host's state doesn't show is sent again after this long (once a state)

local Now = Util.Now
local function Me() return Util.PlayerKey() end
local function Events() return ns.Events end
local function E() return ns.EventEngine end
local function B() return ns.EventBlocks end
local DemoOn = Util.DemoOn

local function WireKey(s)
    if type(s) ~= "string" or s == "" or #s > 48 or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

-- class: "event" (the run, facts), "eventmsg" (EVM: what the host tells players; a budget of its own, see Comm.lua)
local function Send(msg, dist, target, class)
    if DemoOn() then return false end
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, class or "event")) and true or false
end

local function Fire(occId)
    Util.Debounce("event-live-" .. tostring(occId), 0.1, function() ns:Fire("EVENT_LIVE_UPDATED", occId) end)
end

local function Contains(list, v)
    for i = 1, #(list or {}) do if list[i] == v then return i end end
    return nil
end

local function DisplayName(key)
    if type(key) ~= "string" then return "?" end
    if key:find("%-Practice$") then return (key:gsub("%-Practice$", "")):gsub("(%a)(%d)", "%1 %2") end
    return Util.ShortName(key)
end
Live.DisplayName = DisplayName

-- Text a player reads: no escape codes or control characters, at most n bytes, cut between letters.
local function Text(s, n)
    if type(s) ~= "string" then return nil end
    s = s:gsub("%c", " "):gsub("|", "")
    n = n or TEXT_LEN
    if #s > n then
        local cut = n
        while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
        s = strsub(s, 1, cut)
    end
    return s
end

local function IsId(s) return type(s) == "string" and #s > 0 and #s <= 40 and s:find("^[%w%-%/_]+$") ~= nil end
local function Token(s) return type(s) == "string" and #s <= 24 and s:find("^[%u%d_]+$") and s or nil end

local function Int(n, lo, hi)
    n = tonumber(n)
    if not n or n ~= n then return nil end
    return max(lo, min(hi, floor(n)))
end

-- An entrant of the run, or its host.
local function InRun(st, key)
    return type(key) == "string" and (st.host == key or Contains(st.entrants, key) ~= nil)
end

local function Sensors() return ns.EventSensors end

-- World yards of a map point, for the run (EventSensors' map cache): continent, x, y.
local function WorldPos(map, x, y)
    local S = Sensors()
    if S and S.World then return S.World(map, x, y) end
    return nil
end

-- What the def's entrants sense (EventBlocks:Senses, as EventSensors reads it), or nil.
local function SensesOf(def)
    local S = Sensors()
    return type(def) == "table" and S and S.SensesOf and S.SensesOf(def) or nil
end

-- A run's state as it goes out (EVS, a handover, my /reload): all of it but where the players are.
local function Outgoing(run)
    local s = run:Snapshot()
    s.pos = nil
    return s
end

---------------------------------------------------------------------------
-- What the world sees of a run (invites, marks; the players' messages and guild posts below)
---------------------------------------------------------------------------

local function GroupUnitOf(key)
    local short = Util.ShortName(key)
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    local raid = IsInRaid and IsInRaid()
    for i = 1, n do
        local unit = raid and ("raid" .. i) or (i == n and "player" or ("party" .. i))
        local name = UnitName and UnitName(unit)
        if name and (name == short or (UnitFullName and Util.NormalizeName(name) == key)) then return unit end
    end
    if Util.IsMe(key) then return "player" end
    return nil
end

local zoneCache, zoneAt = {}, -100
local function ZoneOf(key)
    if GetTime() - zoneAt > 10 and GetNumGuildMembers and GetGuildRosterInfo then
        zoneAt = GetTime()
        zoneCache = {}
        for i = 1, GetNumGuildMembers() do
            local name, _, _, _, _, zone = GetGuildRosterInfo(i)
            if name then zoneCache[Util.NormalizeName(name)] = zone end
        end
    end
    if Util.IsMe(key) and GetRealZoneText then return GetRealZoneText() end
    return zoneCache[key]
end

local function IsOnline(key)
    if Util.IsMe(key) then return true end
    local G = ns.Guild
    return G and G.IsOnline and G:IsOnline(key, true) or false
end

-- The invites a run asked for: not who is in my group already or offline, only while I lead my group (or assist in
-- a raid) or have none; a party about to go past five turns into a raid first, and the rest go out once it is one.
local function FlushInvites()
    if not inviteQueue[1] or DemoOn() then return end
    local grouped, raid = IsInGroup and IsInGroup(), IsInRaid and IsInRaid()
    local leader = UnitIsGroupLeader and UnitIsGroupLeader("player")
    if grouped and not (leader or (raid and UnitIsGroupAssistant and UnitIsGroupAssistant("player"))) then
        inviteQueue = {}
        return
    end
    -- (an invite that went out holds a place until they're in, or for a minute)
    local pending = 0
    for k, t in pairs(invitedAt) do
        if GroupUnitOf(k) or GetTime() - t > 60 then invitedAt[k] = nil else pending = pending + 1 end
    end
    local keys = {}
    for _, k in ipairs(inviteQueue) do
        if not Util.IsMe(k) and not GroupUnitOf(k) and not invitedAt[k] and IsOnline(k) then keys[#keys + 1] = k end
    end
    local size = max(1, grouped and GetNumGroupMembers and GetNumGroupMembers() or 1) + pending
    if not raid and grouped and size + #keys > 5 and leader then
        local convert = ConvertToRaid
        if convert then pcall(convert) end
        inviteQueue = keys
        return
    end
    local room = (raid and 40 or 5) - size
    local fn = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    inviteQueue = {}
    for i, k in ipairs(keys) do
        if i <= room then
            invitedAt[k] = GetTime()
            if fn then pcall(fn, Util.ShortName(k)) end
        else
            inviteQueue[#inviteQueue + 1] = k
        end
    end
end

local function HostOut(occId)
    return {
        -- (demo mode: nothing reaches the world; part 1's chat lines and whispers are the addon's own messages now)
        invite = function(keys)
            for _, k in ipairs(keys or {}) do
                if type(k) == "string" and not Contains(inviteQueue, k) and #inviteQueue < 40 then
                    inviteQueue[#inviteQueue + 1] = k
                end
            end
            FlushInvites()
        end,
        mark = function(key, n)
            if DemoOn() then return end
            local unit = GroupUnitOf(key)
            if unit and SetRaidTarget then pcall(SetRaidTarget, unit, n) end
        end,
        -- the addon tells the players itself (EVM): a banner, a tracker line, a sound, their friendly nameplates
        show = function(keys, text) Live:Deliver(occId, "show", keys, Text(tostring(text or ""))) end,
        tell = function(keys, text) Live:Deliver(occId, "tell", keys, Text(tostring(text or ""))) end,
        sound = function(keys, sound) Live:Deliver(occId, "sound", keys, Text(tostring(sound or ""), 32)) end,
        plates = function(keys, off) Live:Deliver(occId, "plates", keys, nil, off and true or false) end,
        guild = function(text) Live:GuildPost(occId, text) end,
        isOnline = IsOnline,
        zoneOf = ZoneOf,
        changed = function() Live:Dirty(occId) end,
        ended = function(run) Live:Ended(occId, run) end,
    }
end

---------------------------------------------------------------------------
-- The addon tells the players (EVM): banners, tracker lines, sounds, nameplates; the run's guild posts
---------------------------------------------------------------------------

local EVM_KINDS = { show = true, tell = true, sound = true, plates = true }

-- A sound by its EventBlocks.SOUNDS key: { key, words, SOUNDKIT name, its id where the client lacks the name }.
local function PlaySoundKey(key)
    local Bk = B()
    local s = Bk and type(Bk.SOUND_BY) == "table" and Bk.SOUND_BY[key]
    if type(s) ~= "table" then return false end
    local kit = (type(SOUNDKIT) == "table" and type(s[3]) == "string" and SOUNDKIT[s[3]]) or tonumber(s[4])
    if kit and PlaySound then pcall(PlaySound, kit, "Master") end
    return true
end

-- A message for me (from the host, or my own run's for me).
local function Receive(occId, k, text, off)
    if k == "show" then
        if text and text ~= "" then ns:Fire("EVENT_SHOW", occId, text) end
    elseif k == "tell" then
        if not text or text == "" then return end
        local feed = feeds[occId] or {}
        feeds[occId] = feed
        tinsert(feed, 1, { at = Now(), text = text })
        while #feed > FEED_MAX do tremove(feed) end
        ns:Fire("EVENT_TELL", occId, text)
    elseif k == "sound" then
        if text and text ~= "" then
            PlaySoundKey(text)
            ns:Fire("EVENT_SOUND", occId, text)
        end
    elseif k == "plates" then
        local S = Sensors()
        if S and S.SetPlates then S:SetPlates(occId, off) end
    end
end

local function EvmToken()
    local now = GetTime()
    evmTokens = min(EVM_BURST, evmTokens + (now - evmAt) * EVM_RATE)
    evmAt = now
    if evmTokens < 1 then return false end
    evmTokens = evmTokens - 1
    return true
end

local function FlushEvm()
    while evmQueue[1] and EvmToken() do
        local e = tremove(evmQueue, 1)
        if e.dist == "WHISPER" then
            -- (the same line waiting for other players: one message names them all; "Right!" to a quiz's fast ones)
            local to, m = { e.target }, e.msg
            local i = 1
            while evmQueue[i] and #to < 40 do
                local x = evmQueue[i]
                local xm = x.msg
                if x.dist == "WHISPER" and xm.o == m.o and xm.k == m.k and xm.text == m.text and xm.off == m.off then
                    to[#to + 1] = x.target
                    tremove(evmQueue, i)
                else
                    i = i + 1
                end
            end
            if #to > 1 then
                e = { msg = { t = "EVM", o = m.o, to = to, k = m.k, text = m.text, off = m.off, at = m.at }, dist = "GUILD" }
            end
        end
        if not DemoOn() then Send(e.msg, e.dist, e.target, "eventmsg") end
    end
    if evmQueue[1] and not evmFlushing then
        evmFlushing = true
        Util.After(0.25, function()
            evmFlushing = false
            FlushEvm()
        end)
    end
end

local function QueueEvm(msg, dist, target)
    if #evmQueue >= EVM_QUEUE then tremove(evmQueue, 1) end
    evmQueue[#evmQueue + 1] = { msg = msg, dist = dist, target = target }
    FlushEvm()
end

-- The host's run tells players something (keys: a list, a key, or "all" = every entrant). One GUILD message for
-- every entrant online or for 4+ players, else a whisper each; mine straight to me.
function Live:Deliver(occId, k, keys, text, off)
    local h = hosting[occId]
    if not h or DemoOn() or not EVM_KINDS[k] then return false end
    local st = h.run.st
    if keys == "all" then keys = st.entrants end
    if type(keys) == "string" then keys = { keys } end
    local me, list, named = Me(), {}, {}
    for _, key in ipairs(type(keys) == "table" and keys or {}) do
        key = WireKey(key)
        if key and not named[key] then
            named[key] = true
            list[#list + 1] = key
        end
    end
    local others, all = {}, true
    for _, key in ipairs(list) do
        if key == me then
            Receive(occId, k, text, off)
        elseif IsOnline(key) then
            others[#others + 1] = key
            if not Contains(st.entrants, key) then all = false end
        end
    end
    if #others == 0 then return true end
    for _, key in ipairs(st.entrants) do
        if key ~= me and not named[key] and IsOnline(key) then all = false; break end
    end
    local function msg(to) return { t = "EVM", o = occId, to = to, k = k, text = text, off = off, at = Now() } end
    if all and #others >= 2 then
        QueueEvm(msg("all"), "GUILD")
    elseif #others >= 4 then
        QueueEvm(msg(others), "GUILD")
    else
        for _, key in ipairs(others) do QueueEvm(msg(nil), "WHISPER", key) end
    end
    return true
end

-- EVM from the host I know (its state, or the handover); for me when it names me or every entrant (I am one).
local function OnMessage(sender, msg, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    local occId = type(msg.o) == "string" and #msg.o <= 40 and msg.o ~= "practice" and msg.o
    if not occId or sender == Me() or not EVM_KINDS[msg.k] then return end
    local s = seen[occId]
    if not s or s.h ~= sender then
        -- before the state that says who hosts it (the run's first messages, a takeover's): it may wait a moment
        local list = pendingEvm[occId] or {}
        pendingEvm[occId] = list
        while #list >= 12 or (list[1] and GetTime() - list[1][4] > 10) do tremove(list, 1) end
        list[#list + 1] = { sender, msg, dist, GetTime() }
        return
    end
    if not s.st or s.st.phase ~= "live" then return end
    local me = Me()
    if dist == "GUILD" then
        if msg.to == "all" then
            if not Contains(s.st.entrants, me) then return end
        elseif type(msg.to) == "table" then
            local mine = false
            for i = 1, min(#msg.to, 40) do
                if WireKey(msg.to[i]) == me then mine = true; break end
            end
            if not mine then return end
        else
            return
        end
    end
    local at = tonumber(msg.at) or Now()
    if (msg.k == "show" or msg.k == "sound") and Now() - at > EVM_STALE then return end
    Receive(occId, msg.k, Text(msg.text, msg.k == "sound" and 32 or TEXT_LEN), msg.off == true)
end

-- The messages that came before the state naming their sender as host: heard again once it came (the rest stay
-- out: their sender isn't the host).
local function ReplayEvm(occId)
    local list = pendingEvm[occId]
    if not list then return end
    pendingEvm[occId] = nil
    for _, e in ipairs(list) do
        if GetTime() - e[4] <= 10 and seen[occId] and seen[occId].h == e[1] then OnMessage(e[1], e[2], e[3]) end
    end
end

-- The run's "post in guild chat": the host's client only, one every GUILD_GAP s and GUILD_MAX an event (counted in
-- the run's state, so a host who takes over goes on counting); never in demo mode (practice has its own out).
local function FlushGuild(h)
    local q = h.guildQ
    if not q or not q[1] or DemoOn() then return end
    local g = h.run.st.gpost
    if type(g) ~= "table" then
        g = { n = 0, at = 0 }
        h.run.st.gpost = g
    end
    if (tonumber(g.n) or 0) >= GUILD_MAX then
        h.guildQ = nil
        return
    end
    if Now() - (tonumber(g.at) or 0) < GUILD_GAP then return end
    local text = tremove(q, 1)
    g.n, g.at = (tonumber(g.n) or 0) + 1, Now()
    if IsInGuild and IsInGuild() and SendChatMessage then pcall(SendChatMessage, text, "GUILD") end
    h.run:Changed()   -- (the count goes out with the next state)
end

function Live:GuildPost(occId, text)
    local h = hosting[occId]
    text = Text(type(text) == "string" and text or tostring(text or ""))
    if not h or DemoOn() or not text or text == "" then return false end
    local g = type(h.run.st.gpost) == "table" and h.run.st.gpost or { n = 0 }
    h.guildQ = h.guildQ or {}
    if (tonumber(g.n) or 0) + #h.guildQ >= GUILD_MAX then return false end
    if #h.guildQ >= GUILD_WAIT then tremove(h.guildQ, 1) end
    h.guildQ[#h.guildQ + 1] = text
    FlushGuild(h)
    return true
end

---------------------------------------------------------------------------
-- Hosting
---------------------------------------------------------------------------

local function EnsureTicker()
    if ticker or not C_Timer then return end
    ticker = C_Timer.NewTicker(1, function() Live:Tick() end)
end

function Live:IsHosting(occId) return hosting[occId] ~= nil and hosting[occId].run.st.phase == "live" end

function Live:CanStart(occId)
    if DemoOn() then return false, "Demo mode is on: nothing runs for real." end
    local o = Events():GetOcc(occId)
    if not o or Events():HostOf(o) ~= Me() then return false, "Only the host starts their event." end
    local state = Events():OccState(o)
    if state == "live" then return false, "It's running already." end
    if state == "done" then return false, "This event is over." end
    if state == "cancelled" then return false, "This event was cancelled." end
    local probs = B():Problems(o.def)
    if #probs > 0 then return false, "The event has pieces that need fixing: open it in the builder." end
    return true
end

local function NewHost(occId, o, run, hosts)
    hosting[occId] = { run = run, occ = o, hosts = hosts, sendAt = 0, dirty = true, pending = {}, recent = {}, watchers = {},
        lastBeat = 0 }
    EnsureTicker()
end

-- A player may be in this run: level 70 when its Sign-up asks for it (a level the roster doesn't know counts as fine).
local function LevelOK(def, key)
    if Util.IsMe(key) or not Events():Needs70(def) then return true end
    local G = ns.Guild
    local m = G and G.GetMember and G:GetMember(key, true)
    return not (m and tonumber(m.level) and tonumber(m.level) < 70)
end

function Live:Start(occId)
    local ok, why = self:CanStart(occId)
    if not ok then return false, why end
    local o = Events():GetOcc(occId)
    local signups = {}
    for _, k in ipairs(Events():GetSignups(occId)) do
        if LevelOK(o.def, k) then signups[#signups + 1] = k end
    end
    -- an event with no Sign-up: who pressed Join, and whoever is in my group as I start it (guild members online
    -- with the addon)
    local entrants
    if #B():BlocksOf(o.def, "signup") == 0 then
        entrants = {}
        for _, k in ipairs(signups) do entrants[#entrants + 1] = k end
        if not Contains(entrants, Me()) then tinsert(entrants, 1, Me()) end
        local G, Sync, group = ns.Guild, ns.Sync, {}
        local n = GetNumGroupMembers and GetNumGroupMembers() or 0
        local raid = IsInRaid and IsInRaid()
        for i = 1, n do
            local name, realm = UnitName(raid and ("raid" .. i) or ("party" .. i))
            local key = name and Util.NormalizeName((realm and realm ~= "") and (name .. "-" .. realm) or name)
            if key and not Contains(entrants, key) and G and G:IsInGuild(key, true) and IsOnline(key)
                and Sync and Sync.GetPeer and Sync:GetPeer(key) and LevelOK(o.def, key) then
                group[#group + 1] = key
            end
        end
        tsort(group)
        for _, k in ipairs(group) do entrants[#entrants + 1] = k end
    end
    local run = E():New(o.def, { id = occId, host = Me(), signups = signups, entrants = entrants, out = HostOut(occId),
        rankOf = function(k) return Events():RankOf(k) end, nameOf = DisplayName, worldPos = WorldPos })
    NewHost(occId, o, run, { Me() })
    run:Start()
    self:SendState(occId, true)
    Fire(occId)
    return true
end

-- My client goes on with a run from its state (I took over, or it was handed to me).
local function Resume(occId, st, chain)
    -- (demo mode: I couldn't tell anyone, so I don't)
    local o = not DemoOn() and Events():GetOcc(occId, true)
    if not o then return false end
    local run = E():Restore(o.def, st, { out = HostOut(occId), rankOf = function(k) return Events():RankOf(k) end,
        nameOf = DisplayName, worldPos = WorldPos })
    run.st.host = Me()
    -- (a new start of the run: the entrants' games tell it again where they are, as they do a new host)
    run.st.boot = (tonumber(run.st.boot) or 0) + 1
    local hosts = {}
    for _, h in ipairs(chain or {}) do hosts[#hosts + 1] = h end
    if hosts[#hosts] ~= Me() then hosts[#hosts + 1] = Me() end
    while #hosts > MAX_CHAIN do tremove(hosts, 2) end
    NewHost(occId, o, run, hosts)
    seen[occId] = nil
    run:Changed()
    Live:SendState(occId, true)
    ns:Print("you're hosting %s now.", o.def.name or "the event")
    -- (my own answers that went to the host who was gone)
    Live:AnswerAgain(occId, run.st)
    Fire(occId)
    return true
end

function Live:Dirty(occId)
    local h = hosting[occId]
    if h then
        h.dirty = true
        self:NoteAnnouncements(occId, h.run.st)
    end
    Fire(occId)
end

function Live:SendState(occId, now)
    local h = hosting[occId]
    if not h then return end
    if not now and GetTime() - h.sendAt < SEND_GAP then return end
    -- the last state is still on its way out (the server lets about one 250-byte part a second through): this one
    -- waits and goes out with whatever changes meanwhile, so the queue never holds more than one (a safety valve
    -- after 20 s, in case the count of what's queued is off)
    local Comm = ns.Comm
    if not now and Comm and Comm.Backlog and Comm:Backlog("event") > 0 and GetTime() - h.sendAt < 20 then return end
    h.sendAt = GetTime()
    h.lastBeat = GetTime()
    h.sentSeq = h.run.st.seq
    -- (not sent, e.g. the guild not there yet right after a /reload: again soon)
    h.dirty = not Send({ t = "EVS", o = occId, h = h.run.st.host, s = Outgoing(h.run), c = h.hosts }, "GUILD")
end

function Live:Ended(occId, run)
    local h = hosting[occId]
    if not h then return end
    self:SendState(occId, true)
    -- (an event taken off the calendar while it ran keeps no result)
    if Events().SaveResult and not h.gone then Events():SaveResult(occId, run, h.hosts) end
    Fire(occId)
end

-- Hands the run to another member who is online (they go on with it; I become a watcher).
function Live:HandOver(occId, key)
    local h = hosting[occId]
    key = WireKey(key)
    if not h or not key or key == Me() then return false end
    if not IsOnline(key) then return false, "They're offline." end
    h.run.st.host = key
    local chain = {}
    for _, x in ipairs(h.hosts) do chain[#chain + 1] = x end
    chain[#chain + 1] = key
    while #chain > MAX_CHAIN do tremove(chain, 2) end
    Send({ t = "EVS", o = occId, h = key, s = Outgoing(h.run), c = chain }, "GUILD")
    seen[occId] = { st = Outgoing(h.run), h = key, c = chain, at = GetTime() }
    hosting[occId] = nil
    Fire(occId)
    return true
end

-- The host's controls ----------------------------------------------------

local function HostRun(occId)
    local h = hosting[occId]
    return h and h.run.st.phase == "live" and h.run or nil
end

function Live:SetPaused(occId, paused)
    local run = HostRun(occId)
    if not run then return false end
    if paused and not run.st.paused then
        run.st.paused = Now()
    elseif not paused and run.st.paused then
        -- the time stood still: timers, waiting scripts and "every" pieces end that much later
        local shift = Now() - run.st.paused
        if run.Shift then
            run:Shift(shift)   -- (asks, "seconds since" and the stage's clock too)
        else
            for _, t in ipairs(run.st.timers) do t.at = t.at + shift end
            for th in pairs(run.threads) do
                if th.wait and th.wait.at then th.wait.at = th.wait.at + shift end
            end
            for id, at in pairs(run.st.everyAt or {}) do run.st.everyAt[id] = at + shift end
        end
        run.st.paused = nil
    end
    run:Changed()
    return true
end

function Live:IsPaused(occId)
    local st = self:GetState(occId)
    return st and st.paused and true or false
end

-- The host decides a match (a dispute, or a no-show): finishes it with that winner.
function Live:DecideMatch(occId, mid, winner)
    local run = HostRun(occId)
    if not run then return false end
    for _, bid in ipairs(B():BlocksOf(run.def, "bracket")) do
        local bk = run:Bracket(bid)
        local m = bk and bk.m[mid]
        if m and (m.a == winner or m.b == winner) and m.st ~= "done" then
            if m.st == "wait" then run:BracketPlay(bid, m) end
            run:BracketFinish(bid, m, winner, false)
            run:Pump()
            return true
        end
    end
    return false
end

-- The host answers an ask put to them (who won a disputed game).
function Live:HostAnswer(occId, askId, winner)
    local run = HostRun(occId)
    if not run then return false end
    run:Answer(askId, run.st.host, winner)
    return true
end

-- Returns ok, and why not (words for the host): a player joins only while a Sign-up is open.
function Live:AddPlayer(occId, key)
    local run = HostRun(occId)
    key = WireKey(key)
    if not run or not key then return false end
    if Contains(run.st.entrants, key) then return false, "They're in it already." end
    if not LevelOK(run.def, key) then return false, "This one is for level 70 characters." end
    if run:Join(key) then return true end
    for _, bid in ipairs(B():BlocksOf(run.def, "signup")) do
        if run:SignupState(bid).open then return false, "The sign-up is full." end
    end
    return false, "Sign-ups are closed: the bracket is set."
end

function Live:RemovePlayer(occId, key)
    local run = HostRun(occId)
    if not run then return false end
    run:BracketOut(key)
    run:Leave(key)
    run:Pump()
    return true
end

function Live:GoStage(occId, stageId)
    local run = HostRun(occId)
    if not run then return false end
    run:GoStage(stageId)
    run:Pump()
    return true
end

function Live:CloseSignup(occId)
    local run = HostRun(occId)
    if not run then return false end
    for _, bid in ipairs(B():BlocksOf(run.def, "signup")) do
        run:Queue(function() run:CloseSignup(bid) end)
    end
    run:Pump()
    return true
end

function Live:EndEvent(occId)
    local run = HostRun(occId)
    if not run then return false end
    run:End()
    return true
end

---------------------------------------------------------------------------
-- Facts on the host
---------------------------------------------------------------------------

local function PairKey(a, b) if a < b then return a .. "|" .. b end return b .. "|" .. a end

local SAME_DUEL = 3   -- two reports whose server times are this close are of one duel (no duel is that short)

local function ApplyDuel(h, key, p, agree)
    h.pending[key] = nil
    h.recent[key] = { at = p.at, t = p.t }
    h.run:Duel(p.w, p.l, agree)
end

-- Two reports of one duel: the same second on the reporters' clocks, or here a moment apart (two clients' server
-- times can be a few seconds apart; two duels of one pair never end within SAME_DUEL s of each other).
local function OneDuel(x, at)
    return x ~= nil and (math.abs(at - x.at) <= SAME_DUEL or GetTime() - x.t <= SAME_DUEL)
end

-- at: the server time the reporter saw the duel end (the same second on both clients, give or take their clocks).
local function OnDuelReport(h, sender, w, l, at)
    if sender ~= w and sender ~= l then return end
    local run = h.run
    if not (Contains(run.st.entrants, w) and Contains(run.st.entrants, l)) then return end
    local key = PairKey(w, l)
    at = tonumber(at) or Now()
    -- the other duelist's report of a duel already counted
    local rec = h.recent[key]
    if type(rec) == "table" and OneDuel(rec, at) then return end
    local p = h.pending[key]
    if p and not OneDuel(p, at) then
        -- a newer duel while the last one waited for its second report: that one stays "not agreed"
        ApplyDuel(h, key, p, false)
        p = nil
    end
    if not p then
        p = { w = w, l = l, from = { [sender] = true }, t = GetTime(), at = at }
        h.pending[key] = p
        if sender == l then ApplyDuel(h, key, p, true) end   -- the loser says so: that counts
        return
    end
    if p.from[sender] then return end
    p.from[sender] = true
    ApplyDuel(h, key, p, p.w == w)
end

-- What an entrant's game says it saw (EventSensors) and what the player did (an answer, a button): taken from
-- entrants only, for what the def uses, at most FACT_PER_SEC a second each (a burst of FACT_HOST_BURST).
local SENSED = { kill = true, loot = true, fish = true, die = true, mount = true, dismount = true, move = true, stop = true,
    emote = true }
local TOUCH_HOW = { click = true, point = true, emote = true }
local NEW_FACTS = { h = true, place = true, touch = true, radar = true, pos = true, ans = true, press = true }

local function FactAllowed(h, sender)
    h.rates = h.rates or {}
    local r, now = h.rates[sender], GetTime()
    if not r then
        r = { n = FACT_HOST_BURST, at = now }
        h.rates[sender] = r
    end
    r.n = min(FACT_HOST_BURST, r.n + (now - r.at) * FACT_PER_SEC)
    r.at = now
    if r.n < 1 then return false end
    r.n = r.n - 1
    return true
end

-- An answer as it may reach the run: a key / text (120 bytes), a number, yes / no, or up to three keys (votes).
local function AnswerValue(v, inner)
    local t = type(v)
    if t == "boolean" then return v end
    if t == "number" then
        if v ~= v then return nil end
        return max(-1e9, min(1e9, v))
    end
    if t == "string" then return Text(v, 120) end
    if t == "table" and not inner then
        local out = {}
        for i = 1, min(#v, 3) do
            local x = AnswerValue(v[i], true)
            if type(x) == "string" and x ~= "" then out[#out + 1] = x end
        end
        return #out > 0 and out or nil
    end
    return nil
end

local POS_FLAGS = { "fl", "sw", "cb", "mt", "mv", "dd" }   -- flying, swimming, in combat, mounted, moving, dead

local function Finite(v, lim)
    v = tonumber(v)
    return v and v == v and v > -lim and v < lim and v or nil
end

-- A "pos" fact as the run takes it (EventEngine Run:Pos): only the parts the def uses (s = its senses; nil: all, the
-- practice panel's): a position (map, x, y; cont, wx, wy), zone / subzone, flags, item counts, gold gained.
local function CleanPos(msg, s)
    local pos, any = {}, false
    -- (in an instance: no position; the one from before it is forgotten)
    if (not s or s.pos) and msg.inst == true then
        pos.inst = true
        any = true
    elseif not s or s.pos then
        local map, x, y = tonumber(msg.map), Finite(msg.x, 2), Finite(msg.y, 2)
        if map and x and y and map == floor(map) and map > 0 and map < 1e6 and x >= -1 and y >= -1 then
            pos.map, pos.x, pos.y = map, x, y
            local wx, wy, cont = Finite(msg.wx, 1e6), Finite(msg.wy, 1e6), tonumber(msg.cont)
            if wx and wy and cont and cont == floor(cont) then pos.wx, pos.wy, pos.cont = wx, wy, cont end
            any = true
        end
    end
    if not s or s.pos or s.zone then
        if msg.z ~= nil then pos.z = Text(msg.z, 48) or ""; any = true end
        if msg.sz ~= nil then pos.sz = Text(msg.sz, 48) or ""; any = true end
    end
    -- (flags: all of them for a def asking "is ..."; mounted / moving / dead also for one whose happenings keep them)
    local h = s and s.happen or {}
    local flagOK = { mt = h.mount or h.dismount, mv = h.move or h.stop, dd = h.die }
    for _, f in ipairs(POS_FLAGS) do
        if msg[f] ~= nil and (not s or s.flags or flagOK[f]) then pos[f] = msg[f] == true; any = true end
    end
    if type(msg.items) == "table" and (not s or next(s.items)) then
        local items, n = {}, 0
        for item in pairs(s and s.items or msg.items) do
            local c = Int(msg.items[tostring(item)], 0, 1e6)
            if c and n < 24 then items[tostring(item)] = c; n = n + 1 end
        end
        if n > 0 then pos.items = items; any = true end
    end
    if (not s or s.gold) and msg.gold ~= nil then
        local g = Int(msg.gold, -1e10, 1e10)
        if g then pos.gold = g; any = true end
    end
    return any and pos or nil
end

local function OnNewFact(h, sender, msg)
    local run, k = h.run, msg.k
    -- (from entrants; the host's own answers and buttons too: an ask or a button may be put to a host who isn't one)
    if not Contains(run.st.entrants, sender) and not ((k == "ans" or k == "press") and sender == run.st.host) then return end
    local s = SensesOf(run.def)
    if not s or not FactAllowed(h, sender) then return end
    if k == "h" then
        local what = msg.what
        if not (type(what) == "string" and SENSED[what] and s.happen[what]) then return end
        local item = tonumber(msg.item)
        local data = { other = WireKey(msg.other), item = item and Int(item, 1, 1e7) or Text(msg.item, 64),
            name = Text(msg.name, 64), count = Int(msg.count, 1, 10000), creature = Text(msg.creature, 64),
            emote = Token(msg.emote) }
        if data.other == sender then data.other = nil end
        if run.Happen then run:Happen(sender, what, data) end
    elseif k == "place" then
        local pid = IsId(msg.pid) and msg.pid
        if not (pid and s.places[pid]) then return end
        if run.Place then run:Place(sender, pid, msg["in"] and true or false) end
    elseif k == "touch" then
        local how, whom = msg.how, WireKey(msg.whom)
        if not (TOUCH_HOW[how] and s.touch[how]) or not whom or whom == sender or not InRun(run.st, whom) then return end
        -- (only up close counts: "clicks / points at / ... up close")
        if msg.near ~= true then return end
        if run.Touch then run:Touch(sender, whom, how, how == "emote" and Token(msg.emote) or nil) end
    elseif k == "radar" then
        local whom = WireKey(msg.whom)
        if not s.radar or not whom or whom == sender or not InRun(run.st, whom) then return end
        if run.Radar then run:Radar(sender, whom) end
    elseif k == "pos" then
        local pos = CleanPos(msg, s)
        if pos and run.Pos then run:Pos(sender, pos) end
    elseif k == "ans" then
        local aid, v = IsId(msg.aid) and msg.aid, AnswerValue(msg.v)
        if s.asks and aid and v ~= nil and run.AskAnswer then run:AskAnswer(aid, sender, v) end
    elseif k == "press" then
        local label = Text(msg.label, 32)
        if s.buttons and label and label ~= "" and run.Press then run:Press(sender, label) end
    end
end

local function OnFact(sender, msg, dist)
    if dist ~= "WHISPER" and sender ~= Me() then return end
    local occId = type(msg.o) == "string" and msg.o
    local h = occId and hosting[occId]
    if not h or h.run.st.phase ~= "live" then return end
    local run = h.run
    local k = msg.k
    if NEW_FACTS[k] then
        OnNewFact(h, sender, msg)
    elseif k == "b" then
        -- facts of one moment together (each one counted)
        for i = 1, min(type(msg.f) == "table" and #msg.f or 0, FACT_BATCH) do
            local f = msg.f[i]
            if type(f) == "table" and NEW_FACTS[f.k] then OnNewFact(h, sender, f) end
            if h.run.st.phase ~= "live" then break end
        end
    elseif k == "duel" then
        local w, l = WireKey(msg.w), WireKey(msg.l)
        if w and l and w ~= l then OnDuelReport(h, sender, w, l, msg.at) end
    elseif k == "ready" then
        if Contains(run.st.entrants, sender) then run:SetReady(sender) end
    elseif k == "answer" then
        local a = tonumber(msg.a)
        if a then run:Answer(a, sender, WireKey(msg.v)) end
    elseif k == "join" then
        if LevelOK(run.def, sender) then run:Join(sender) end
    elseif k == "leave" then
        run:Leave(sender)
    elseif k == "watch" then
        h.watchers[sender] = GetTime()
    end
end

-- A fact of mine: to the host (or straight in when I host it).
local function Tell(occId, msg)
    msg.t = "EVF"
    msg.o = occId
    if hosting[occId] then
        OnFact(Me(), msg, "WHISPER")
        return true
    end
    local s = seen[occId]
    if not s or not s.h then return false end
    return Send(msg, "WHISPER", s.h)
end

function Live:Ready(occId) return Tell(occId, { k = "ready" }) end
function Live:AnswerAsk(occId, askId, v) return Tell(occId, { k = "answer", a = askId, v = v }) end

-- My facts go out a moment after they happen (those of one moment in one message), as the rate allows.
local function FactToken()
    local now = GetTime()
    factTokens = min(FACT_SEND_BURST, factTokens + (now - factAt) * FACT_SEND_RATE)
    factAt = now
    if factTokens < 1 then return false end
    factTokens = factTokens - 1
    return true
end

local FlushFacts
local function LaterFacts(sec)
    if factFlushing then return end
    factFlushing = true
    Util.After(sec, function()
        factFlushing = false
        FlushFacts()
    end)
end

FlushFacts = function()
    while factQueue[1] and FactToken() do
        local occId = factQueue[1][1]
        -- what waits for that event goes together (FACT_BATCH at most)
        local batch, i = {}, 1
        while factQueue[i] and #batch < FACT_BATCH do
            if factQueue[i][1] == occId then batch[#batch + 1] = tremove(factQueue, i)[2] else i = i + 1 end
        end
        if not DemoOn() then
            if #batch == 1 then Tell(occId, batch[1]) else Tell(occId, { k = "b", f = batch }) end
        end
    end
    if factQueue[1] then LaterFacts(0.3) end
end

-- A fact of mine for the host of a live event I'm in (EventSensors, my answers, my buttons): fact = { k, ... }.
function Live:SendFact(occId, fact)
    if DemoOn() or type(fact) ~= "table" or not NEW_FACTS[fact.k] or occId == "practice" then return false end
    local st = (hosting[occId] and hosting[occId].run.st) or (seen[occId] and seen[occId].st)
    if not st or st.phase ~= "live" then return false end
    -- (an entrant's; the host's own answers and buttons too, an entrant or not)
    local mine = Contains(st.entrants, Me()) or ((fact.k == "ans" or fact.k == "press") and st.host == Me())
    if not mine then return false end
    local msg = {}
    for k, v in pairs(fact) do msg[k] = v end
    msg.at = Now()
    if msg.k == "pos" then
        -- a newer position joins the one waiting (its parts win; the waiting one's other parts stay)
        for _, f in ipairs(factQueue) do
            if f[1] == occId and f[2].k == "pos" then
                -- (in an instance and out again: the newer of the two stands)
                if msg.inst then
                    for _, k in ipairs({ "map", "x", "y", "cont", "wx", "wy" }) do f[2][k] = nil end
                elseif msg.map then
                    f[2].inst = nil
                end
                for k, v in pairs(msg) do f[2][k] = v end
                return true
            end
        end
    end
    if #factQueue >= FACT_QUEUE then
        local drop = 1
        for i, f in ipairs(factQueue) do
            if f[2].k == "pos" then drop = i; break end
        end
        tremove(factQueue, drop)
    end
    factQueue[#factQueue + 1] = { occId, msg }
    LaterFacts(0)
    return true
end

-- Events:SignUp calls this: joining (or leaving) while the event runs tells the host. On the host, Events calls it
-- for a member's sign-up heard from the guild (they may not know yet who hosts it).
function Live:OnSignUp(occId, key, on)
    local h = hosting[occId]
    if h and not Util.IsMe(key) then
        if h.run.st.phase ~= "live" then return end
        if not on then
            h.run:Leave(key)
        elseif LevelOK(h.run.def, key) then
            h.run:Join(key)
        end
        return
    end
    if not self:IsLive(occId) or not Util.IsMe(key) then return end
    Tell(occId, { k = on and "join" or "leave" })
end

---------------------------------------------------------------------------
-- What everyone hears
---------------------------------------------------------------------------

local function StateNewer(a, ah, b, bh)
    if not b then return true end
    if (a.seq or 0) ~= (b.seq or 0) then return (a.seq or 0) > (b.seq or 0) end
    return (ah or "") < (bh or "")
end

local function CleanState(s)
    -- the state is only read (the engine runs only on the host): a table of the right shape is enough
    if type(s) ~= "table" or type(s.entrants) ~= "table" or type(s.blocks) ~= "table" then return nil end
    if type(s.seq) ~= "number" then return nil end
    return s
end

-- The chain of hosts a state names: keys, the first one and the last ones.
local function Chain(c)
    local out = {}
    if type(c) ~= "table" then return out end
    for i = 1, min(#c, 40) do
        local k = WireKey(c[i])
        if k then out[#out + 1] = k end
    end
    while #out > MAX_CHAIN do tremove(out, 2) end
    return out
end

-- May this state come from its sender, and how: "host" (the host I know: its state, or it hands the run on),
-- "takeover" (an entrant goes on with it once that host went quiet, or the first I hear of the run), "race" (two
-- entrants took over from the same host at once: the newer state wins), "fromme" (someone went on with the run I
-- host: my states didn't reach them), or nil: anyone else (a stale or made-up state) is not listened to.
local function HowSent(occId, o, sender, host, chain)
    local mine, cur = hosting[occId], seen[occId]
    local known = (mine and Me()) or (cur and cur.h) or nil
    local first = Events():HostOf(o)
    local last, before = chain[#chain], chain[#chain - 1]
    if known and sender == known then
        if host == sender or (last == host and before == sender) then return "host" end
        return nil
    end
    if host ~= sender or last ~= sender then
        -- the first I hear of it is a handover: from the one handing it on, in a chain from the event's host
        if not known and last == host and before == sender and chain[1] == first then return "host" end
        return nil
    end
    if not known then return (sender == first or chain[1] == first) and "takeover" or nil end
    local st = mine and mine.run.st or cur.st
    if not (Contains(st.entrants, sender) or sender == first) then return nil end
    local knownChain = mine and mine.hosts or cur.c or {}
    if before and before == knownChain[#knownChain - 1] then return "race" end
    if mine then return before == Me() and "fromme" or nil end
    if GetTime() - cur.at >= GONE_SILENT - QUIET_SLACK or not IsOnline(known) then return "takeover" end
    return nil
end

local function OnState(sender, msg, dist)
    local occId = type(msg.o) == "string" and #msg.o <= 40 and msg.o ~= "practice" and msg.o
    if not occId then return end
    local st = CleanState(msg.s)
    if not st then return end
    local host = WireKey(msg.h)
    -- (a calendar event I know: the real one, also in demo mode; one taken off the calendar is over for me)
    local o = Events():GetOcc(occId, true)
    if not o and seen[occId] and Events():OccRemoved(occId) then
        seen[occId] = nil
        Fire(occId)
    end
    if not host or not o then return end
    local chain = Chain(msg.c)
    local how = HowSent(occId, o, sender, host, chain)
    if not how then return end
    local mine = hosting[occId]
    if mine then
        if host == Me() then return end
        -- someone else hosts it now (they took over while I was gone, or a race of two takeovers). One who went on
        -- from my last state they heard is at most a few changes past mine: a state far ahead of mine is made up.
        if (how == "race" and not StateNewer(st, host, mine.run.st, Me()))
            or (how == "fromme" and st.seq > mine.run.st.seq + FROM_ME_AHEAD) then
            -- mine goes out again (soon, not once per state of theirs)
            mine.dirty = true
            Live:SendState(occId)
            return
        end
        hosting[occId] = nil
        ns:Print("%s hosts %s now.", DisplayName(host), o.def.name or "the event")
    end
    local cur = seen[occId]
    if cur and cur.st and (host == cur.h or how == "race") and not StateNewer(st, host, cur.st, cur.h) then
        if host == cur.h then cur.at = GetTime() end
        return
    end
    seen[occId] = { st = st, h = host, c = chain, at = GetTime() }
    if host == Me() and st.phase == "live" then
        Resume(occId, st, chain)
        return
    end
    Live:NoteAnnouncements(occId, st)
    EnsureTicker()
    Fire(occId)
    ReplayEvm(occId)
    Live:AnswerAgain(occId, st)
end

local function OnBeat(sender, msg, dist)
    if dist ~= "GUILD" then return end
    local occId = type(msg.o) == "string" and msg.o
    if not occId then return end
    local host = WireKey(msg.h)
    if host ~= sender then return end
    local cur = seen[occId]
    if cur and cur.h == host then
        cur.at = GetTime()
        -- behind: ask (at most every 10 s)
        if (tonumber(msg.q) or 0) > (cur.st and cur.st.seq or 0) and ns.Comm:RateLimit("EVQ:" .. occId, 10) then
            Send({ t = "EVQ", o = occId }, "WHISPER", host)
        end
    elseif not hosting[occId] and ns.Comm:RateLimit("EVQ:" .. occId, 10) then
        Send({ t = "EVQ", o = occId }, "WHISPER", host)
    end
end

-- Answered with the next state on GUILD: one state for all who asked, however many open the board at once (a
-- whisper each would queue a whole state per member behind the next one).
local function OnQuery(sender, msg, dist)
    if dist ~= "WHISPER" then return end
    local occId = type(msg.o) == "string" and msg.o
    local h = occId and hosting[occId]
    if not h then return end
    h.watchers[sender] = GetTime()
    h.dirty = true
end

-- Big text on my screen when the run says so (raid warning pieces, countdowns), once each.
function Live:NoteAnnouncements(occId, st)
    local me = Me()
    local mine = Contains(st.entrants, me) or Contains(st.signups, me) or st.host == me
    local ann = st.ann
    if ann and (shownAnn[occId] or 0) < ann.s then
        shownAnn[occId] = ann.s
        if mine and Now() - (ann.at or 0) < 30 then ns:Fire("EVENT_ANNOUNCE", occId, ann.text) end
    end
    local cd = st.cd
    if cd and (shownCd[occId] or 0) < cd.s then
        shownCd[occId] = cd.s
        if (Contains(cd.to, me) or st.host == me) and Now() - (cd.at or 0) < cd.n then
            ns:Fire("EVENT_COUNTDOWN", occId, cd.n - (Now() - cd.at))
        end
    end
end

---------------------------------------------------------------------------
-- Duels I see end (CHAT_MSG_SYSTEM): mine are told to the host of a live event I'm in
---------------------------------------------------------------------------

local duelPatterns

local function Esc(s) return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")) end

-- "%1$s has defeated %2$s in a duel" -> a Lua pattern and which argument each capture is (%s counts up).
local function Pattern(fmt)
    local pat, order, pos, n = "^", {}, 1, 0
    while true do
        local s, e, d = fmt:find("%%(%d)%$s", pos)
        local s2, e2 = fmt:find("%%s", pos)
        if s2 and (not s or s2 < s) then s, e, d = s2, e2, nil end
        if not s then break end
        pat = pat .. Esc(fmt:sub(pos, s - 1)) .. "(.+)"
        n = n + 1
        order[#order + 1] = d and tonumber(d) or n
        pos = e + 1
    end
    return pat .. Esc(fmt:sub(pos)) .. "$", order
end
Live._Pattern = Pattern

local function BuildPatterns()
    duelPatterns = {}
    local locale = GetLocale and GetLocale() or "enUS"
    if locale == "enUS" or locale == "enGB" or not DUEL_WINNER_KNOCKOUT then
        -- English: the winner first when they defeated, the loser first when they fled
        duelPatterns[1] = { pat = "^(.+) has defeated (.+) in a duel%.?$", order = { 1, 2 } }
        duelPatterns[2] = { pat = "^(.+) has fled from (.+) in a duel%.?$", order = { 2, 1 } }
        return
    end
    -- other languages: the client's strings take (winner, loser)
    for _, fmt in ipairs({ DUEL_WINNER_KNOCKOUT, DUEL_WINNER_RETREAT }) do
        if type(fmt) == "string" then
            local pat, order = Pattern(fmt)
            duelPatterns[#duelPatterns + 1] = { pat = pat, order = order }
        end
    end
end

-- winner, loser keys from a system message, or nil.
function Live:ParseDuel(text)
    if type(text) ~= "string" then return nil end
    if not duelPatterns then BuildPatterns() end
    for _, p in ipairs(duelPatterns) do
        local a, b = text:match(p.pat)
        if a and b then
            local args = {}
            args[p.order[1]] = a
            args[p.order[2]] = b
            local w, l = Util.NormalizeName(args[1]), Util.NormalizeName(args[2])
            if w and l then return w, l end
        end
    end
    return nil
end

-- The runs going on that I know of: { [occId] = state } (the ones I host and the ones I hear of).
local function LiveStates()
    local out = {}
    for occId, s in pairs(seen) do
        if s.st and s.st.phase == "live" and not hosting[occId] then out[occId] = s.st end
    end
    for occId, h in pairs(hosting) do
        if h.run.st.phase == "live" then out[occId] = h.run.st end
    end
    return out
end

-- The live events I'm an entrant of: { [occId] = state } (not practice, nothing in demo mode). EventSensors watches
-- for these.
function Live:MyLiveEvents()
    local out = {}
    if DemoOn() then return out end
    local me = Me()
    for occId, st in pairs(LiveStates()) do
        if Contains(st.entrants, me) then out[occId] = st end
    end
    return out
end

local function OnSystem(_, text)
    local w, l = Live:ParseDuel(text)
    if not w then return end
    local me = Me()
    if w ~= me and l ~= me then return end
    local at = Now()
    -- the live events I'm in; in two at once, a duel that is my match in one of them is that one's only
    local other = w == me and l or w
    local mineIn, matched = {}, {}
    for occId, st in pairs(LiveStates()) do
        if Contains(st.entrants, me) then
            mineIn[#mineIn + 1] = occId
            local m = Live:MyMatch(occId)
            if m and (m.a == other or m.b == other) then matched[#matched + 1] = occId end
        end
    end
    for _, occId in ipairs(#matched > 0 and matched or mineIn) do
        if hosting[occId] then
            OnFact(me, { t = "EVF", o = occId, k = "duel", w = w, l = l, at = at }, "WHISPER")
        else
            Tell(occId, { k = "duel", w = w, l = l, at = at })
        end
    end
    if practice then Live:PracticeDuel(w, l) end
end

---------------------------------------------------------------------------
-- The ticker: hosts run their events, everyone watches for a host gone quiet
---------------------------------------------------------------------------

function Live:Tick()
    local any = false
    for occId, h in pairs(hosting) do
        any = true
        local run = h.run
        if run.st.phase == "live" then
            if not run.st.paused then run:Tick() end
            for key, p in pairs(h.pending) do
                if GetTime() - p.t >= DUEL_WAIT then ApplyDuel(h, key, p, false) end
            end
            local n = 0
            for k, t in pairs(h.watchers) do
                if GetTime() - t > 70 then h.watchers[k] = nil else n = n + 1 end
            end
            if n ~= (run.st.watch or 0) then
                run.st.watch = n
                run.st.watchMax = max(run.st.watchMax or 0, n)
                h.dirty = true
            end
            -- entrants going offline and coming back (the run's "when an entrant goes offline" pieces)
            local moved = false
            for _, k in ipairs(run.st.entrants) do
                local on = IsOnline(k)
                if on == (run.st.off[k] and true or false) then
                    run:SetOnline(k, on)
                    moved = true
                end
            end
            if moved then run:Changed() end
        end
        if h.dirty then self:SendState(occId) end
        FlushGuild(h)
        -- (the beat names the last state sent: who has it isn't behind, even while a newer one waits to go out)
        if GetTime() - h.lastBeat >= HEARTBEAT and run.st.phase == "live" then
            h.lastBeat = GetTime()
            Send({ t = "EVH", o = occId, h = run.st.host, q = h.sentSeq or run.st.seq }, "GUILD")
        end
        -- a run that ended is forgotten after 10 minutes, like the ones I watched (its result stays)
        if run.st.phase ~= "live" then
            h.endedAt = h.endedAt or GetTime()
            if GetTime() - h.endedAt > 600 then hosting[occId] = nil end
        end
    end
    for occId, s in pairs(seen) do
        any = true
        if s.st.phase == "live" and not hosting[occId] then
            self:CheckTakeover(occId, s)
            if self.watching == occId and GetTime() - (s.watchSent or 0) > 30 then
                s.watchSent = GetTime()
                Tell(occId, { k = "watch" })
            end
            -- nobody hosts it any more (its host gone, no entrant took over), or it was taken off the calendar: it
            -- isn't live for me
            if seen[occId] and (GetTime() - s.at > GONE_FOR_GOOD or Events():OccRemoved(occId)) then
                seen[occId] = nil
                Fire(occId)
            end
        elseif s.st.phase ~= "live" and GetTime() - s.at > 600 then
            seen[occId] = nil
        end
    end
    if inviteQueue[1] and GetTime() - (self.invitedAt or 0) > 5 then
        self.invitedAt = GetTime()
        FlushInvites()
    end
    if practice then
        any = true
        self:PracticeTick()
    end
    if not any and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

function Live:CheckTakeover(occId, s)
    -- (demo mode: I couldn't tell anyone I took over)
    if DemoOn() then return end
    local silent = GetTime() - s.at
    if silent < GONE_SILENT then return end
    -- quiet but online: they wait longer; either way one after the other, not all at once
    local wait = IsOnline(s.h) and GONE_ANYWAY or GONE_SILENT
    if silent < wait then return end
    local me = Me()
    if not Contains(s.st.entrants, me) then return end
    -- my turn: the online entrants (but the old host) in name order, one step each
    local list = {}
    for _, k in ipairs(s.st.entrants) do
        if k ~= s.h and IsOnline(k) then list[#list + 1] = k end
    end
    tsort(list)
    local turn = Contains(list, me) or 1
    if silent < wait + (turn - 1) * TAKEOVER_STEP then return end
    Resume(occId, s.st, s.c)
end

---------------------------------------------------------------------------
-- Reading (the board, the tracker, the tab)
---------------------------------------------------------------------------

-- Demo mode's live cup (odemo1): the Friday duel cup 40 minutes in, round 1 played, two quarterfinals on, me next.
local demoLive
local function DemoLive()
    if demoLive then return demoLive end
    local Ev = Events()
    local o = Ev and Ev:GetOcc("odemo1")
    local D = ns.Demo
    if not (o and D and D.GetMembers) then return nil end
    local names = {}
    for _, k in ipairs(D:GetMembers()) do
        if #names >= 15 then break end
        names[#names + 1] = k
    end
    local me = Me() or "Me-Realm"
    tinsert(names, 3, me)
    local clock = Now() - 40 * 60
    local def = B().Copy(o.def)
    def.blocks.b2.set.seed = "order"
    local run = E():New(def, { id = "odemo1", host = Ev:HostOf(o), signups = names, now = function() return clock end,
        nameOf = DisplayName })
    run:Start()
    local function playRound(r, upsets)
        for guard = 1, 40 do
            local bk = run:MainBracket()
            if not bk or bk.r ~= r then return end
            local m
            for _, mid in ipairs(bk.rounds[r]) do
                if bk.m[mid].st == "play" then m = bk.m[mid]; break end
            end
            if not m then return end
            local w, l = m.a, m.b
            if upsets[m.i] then w, l = l, w end
            run:Duel(w, l, true)
            clock = clock + 50
            run:Duel(w, l, true)
            clock = clock + 70
            run:Tick()
        end
    end
    playRound(1, { [6] = true })
    -- the quarterfinals: the first done (2-1), the second one game in
    local bk = run:MainBracket()
    if bk and bk.r == 2 then
        local q1, q2 = bk.m[bk.rounds[2][1]], bk.m[bk.rounds[2][2]]
        run:Duel(q1.a, q1.b, true); clock = clock + 60
        run:Duel(q1.b, q1.a, true); clock = clock + 60
        run:Duel(q1.a, q1.b, true); clock = clock + 40
        run:Tick()
        if q2.st == "play" then run:Duel(q2.b, q2.a, true) end
        q2 = bk.m[bk.rounds[2][2]]
        q2.t = Now() - 102
    end
    run.st.moments = {
        { at = Now() - 9 * 60, text = "Upset: seed 11 " .. DisplayName(names[11]) .. " knocked out seed 6 " .. DisplayName(names[6]),
          i = "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
        { at = Now() - 22 * 60, text = "You won in 0:48, the fastest duel tonight", i = "Interface\\Icons\\Ability_Rogue_Sprint" },
        { at = Now() - 4 * 60, text = DisplayName(names[9]) .. " took a game off " .. DisplayName(names[1]),
          i = "Interface\\Icons\\Ability_Warrior_Challange" },
    }
    run.st.watch = 23
    run.st.seq = 120
    demoLive = run.st
    return demoLive
end

function Live:GetState(occId)
    local h = hosting[occId]
    if h then return h.run.st end
    if practice and occId == "practice" then return practice.run.st end
    if DemoOn() and occId == "odemo1" then return DemoLive() end
    local s = seen[occId]
    return s and s.st or nil
end

function Live:GetHost(occId)
    local st = self:GetState(occId)
    return st and st.host or nil
end

function Live:GetDef(occId)
    if occId == "practice" and practice then return practice.run.def end
    local h = hosting[occId]
    if h then return h.run.def end
    local o = Events():GetOcc(occId)
    return o and o.def or nil
end

function Live:IsLive(occId)
    if DemoOn() then return occId == "odemo1" end
    local st = self:GetState(occId)
    return st and st.phase == "live" or false
end

-- Live events I know of: occIds, newest first.
function Live:GetLiveList()
    local out = {}
    if DemoOn() then return { "odemo1" } end
    for occId, h in pairs(hosting) do
        if h.run.st.phase == "live" then out[#out + 1] = occId end
    end
    for occId, s in pairs(seen) do
        if s.st.phase == "live" and not hosting[occId] then out[#out + 1] = occId end
    end
    return out
end

-- My open question (who won), or nil: ask, state.
function Live:MyAsk(occId)
    local st = self:GetState(occId)
    local me = Me()
    for _, a in pairs(st and st.asks or {}) do
        if Contains(a.to, me) and a.ans[me] == nil then return a, st end
    end
    return nil, st
end

-- My current match: match, bracket, state.
function Live:MyMatch(occId, key)
    local st = self:GetState(occId)
    local def = self:GetDef(occId)
    if not st or not def then return nil end
    local m, bk = E():MatchFor(def, st, key or Me())
    return m, bk, st
end

-- The board is open on that event: the host counts me as watching.
function Live:Watch(occId)
    self.watching = occId
    local s = seen[occId]
    if s and s.h and ns.Comm:RateLimit("EVQw:" .. occId, 10) then Send({ t = "EVQ", o = occId }, "WHISPER", s.h) end
end

function Live:Unwatch() self.watching = nil end

function Live:IsHostOf(occId) return hosting[occId] ~= nil end

---------------------------------------------------------------------------
-- Me: what the tracker and the prompts show of a run (asks, buttons, tags, scores, the arrow, the feed)
---------------------------------------------------------------------------

-- An ask's / a button's players: a set { [key] = true } (or a list).
local function Has(set, key)
    if type(set) ~= "table" then return false end
    return set[key] == true or Contains(set, key) ~= nil
end

local function SetKeys(set)
    local out = {}
    if type(set) ~= "table" then return out end
    for k, v in pairs(set) do
        if type(k) == "string" and v then out[#out + 1] = k
        elseif type(k) == "number" and type(v) == "string" then out[#out + 1] = v end
    end
    tsort(out)
    return out
end

-- A def's definitions of one kind (tags, scores, places, lists, asks) in the builder's order: { {id, d} }.
local function DefsOf(def, kind)
    local out, seenId = {}, {}
    local all = type(def) == "table" and type(def[kind]) == "table" and def[kind] or {}
    local Bk = B()
    if Bk and Bk.Defs then
        local ok, list = pcall(Bk.Defs, Bk, def, kind)
        for _, e in ipairs(ok and type(list) == "table" and list or {}) do
            local id = type(e) == "table" and (e.id or e[1]) or e
            if id ~= nil and type(all[id]) == "table" and not seenId[id] then
                seenId[id] = true
                out[#out + 1] = { id = id, d = all[id] }
            end
        end
    end
    local rest = {}
    for id, d in pairs(all) do
        if type(d) == "table" and not seenId[id] then rest[#rest + 1] = { id = id, d = d } end
    end
    tsort(rest, function(a, b) return tostring(a.id) < tostring(b.id) end)
    for _, e in ipairs(rest) do out[#out + 1] = e end
    return out
end
Live._DefsOf = DefsOf

-- Who may be picked in a "player" ask: the entrants, or the entrants with its tag (from); me only when it says so.
local function AskPlayers(st, a, me)
    local from = type(a) == "table" and a.from
    local out = {}
    local set = type(from) == "string" and from ~= "" and from ~= "entrants" and type(st.tags) == "table" and st.tags[from]
    for _, k in ipairs(st.entrants or {}) do
        if (not set or Has(set, k)) and (k ~= me or (a and a.self)) then out[#out + 1] = k end
    end
    return out
end

local function AnswerKey(aid, q) return tostring(aid) .. "@" .. tostring(type(q) == "table" and q.at or 0) end

-- The asks open for me, oldest first: { {id, n, q, kind, choices, players, votes, self, secret, ends, at, answered,
-- mine} }.
function Live:MyAsks(occId)
    local st, def = self:GetState(occId), self:GetDef(occId)
    local out = {}
    if type(st) ~= "table" or type(def) ~= "table" or type(st.qa) ~= "table" then return out end
    local me = Me()
    local mine = myAnswers[occId] or {}
    for aid, q in pairs(st.qa) do
        if type(q) == "table" and q.open and Has(q.who, me) then
            local a = type(def.asks) == "table" and type(def.asks[aid]) == "table" and def.asks[aid] or {}
            local kind = a.kind or q.kind or "choice"
            local ans = type(q.ans) == "table" and q.ans[me] or nil
            local sent = mine[AnswerKey(aid, q)]
            out[#out + 1] = { id = aid, n = a.n, q = q.q or a.q, kind = kind, choices = q.choices or a.choices,
                players = kind == "player" and AskPlayers(st, a, me) or nil, votes = max(1, min(3, tonumber(a.votes) or 1)),
                self = a.self and true or false, secret = a.secret and true or false, ends = q.ends, at = q.at,
                seq = q.id, answered = ans ~= nil or sent ~= nil, mine = sent ~= nil and sent or ans }
        end
    end
    tsort(out, function(x, y)
        if (x.seq or 0) ~= (y.seq or 0) then return (x.seq or 0) < (y.seq or 0) end
        return tostring(x.id) < tostring(y.id)
    end)
    return out
end

-- The buttons the run gave me: labels, sorted.
function Live:MyButtons(occId)
    local st = self:GetState(occId)
    local out, me = {}, Me()
    for label, who in pairs(type(st) == "table" and type(st.buttons) == "table" and st.buttons or {}) do
        if type(label) == "string" and Has(who, me) then out[#out + 1] = label end
    end
    tsort(out)
    return out
end

-- The tags I have that are shown to me: { {id, n, c, shown} } (a tag shown to the host only: just the host's).
function Live:MyTags(occId)
    local st, def = self:GetState(occId), self:GetDef(occId)
    local out, me = {}, Me()
    if type(st) ~= "table" or type(st.tags) ~= "table" then return out end
    for _, e in ipairs(DefsOf(def, "tags")) do
        local shown = e.d.shown or "all"
        if Has(st.tags[e.id], me) and (shown ~= "host" or st.host == me) then
            out[#out + 1] = { id = e.id, n = e.d.n, c = e.d.c, shown = shown }
        end
    end
    return out
end

-- A player's place by a score among the players who have it (ties alike: 1, 2, 2, 4), nil without one (the run's
-- rule; this one for a client without the engine's reader).
local function PlaceBy(st, rows, key, high)
    local v = tonumber(rows[key])
    if v == nil then return nil end
    local place = 1
    for k, x in pairs(rows) do
        x = tonumber(x)
        if k ~= key and x and ((high and x > v) or (not high and x < v)) then place = place + 1 end
    end
    return place
end
Live._PlaceBy = PlaceBy

-- My scores: { {sid, n, place, name, fmt, high, board} } in the builder's order.
function Live:MyScores(occId)
    local st, def = self:GetState(occId), self:GetDef(occId)
    local out, me = {}, Me()
    if type(st) ~= "table" or type(def) ~= "table" then return out end
    local Eng = E()
    local reader = Eng and Eng.Reader and Eng:Reader(def, st)
    for _, e in ipairs(DefsOf(def, "scores")) do
        local rows = type(st.scores) == "table" and type(st.scores[e.id]) == "table" and st.scores[e.id] or {}
        local high = e.d.high ~= false
        local n = tonumber(rows[me])
        -- (placed as the run places them: among the players who have that score)
        local place
        if reader then
            place = reader:PlaceBy(e.id, me)
            if not place or place <= 0 then place = nil end
        elseif n ~= nil then
            place = PlaceBy(st, rows, me, high)
        end
        out[#out + 1] = { sid = e.id, n = n or (high and 0 or nil), place = place, name = e.d.n,
            fmt = e.d.fmt or "num", high = high, board = e.d.board and true or false }
    end
    return out
end

-- The way from me to one of a def's places: yards, bearing (radians from where I face, counterclockwise: 0 ahead,
-- pi/2 to my left), the place; yards / bearing nil where it isn't known (an instance, another continent).
local function WayTo(def, pid)
    local place = type(def) == "table" and type(def.places) == "table" and def.places[pid]
    if type(place) ~= "table" then return nil, nil, nil end
    local S = Sensors()
    local me = S and S:MyPos()
    if not me then return nil, nil, place end
    local yards = S.Yards(me, place)
    local to, facing = S.Bearing(me, place), S.Facing()
    return yards, (yards and to and facing) and ((to - facing) % (2 * math.pi)) or nil, place
end

-- The place the run points me to: pid, yards, bearing; yards / bearing nil where positions are unknown (instances).
-- When the host points me nowhere: the place I asked to be shown the way to (PointMe), until I'm there; the host's
-- point replaces it.
function Live:MyPoint(occId)
    local st, def = self:GetState(occId), self:GetDef(occId)
    local pid = type(st) == "table" and type(st.point) == "table" and st.point[Me()] or nil
    if pid ~= nil then
        myPoint[occId] = nil
        local yards, bearing = WayTo(def, pid)
        return pid, yards, bearing
    end
    pid = myPoint[occId]
    if pid == nil then return nil end
    local yards, bearing, place = WayTo(def, pid)
    if not place or (yards and yards <= (tonumber(place.r) or 30)) then
        myPoint[occId] = nil   -- (a place the event doesn't have, or I'm there)
        return nil
    end
    return pid, yards, bearing
end

-- Shows me the way to one of the event's places (pid; nil: stop): my own point, kept on my client and never sent,
-- for a planned event too (MyPoint). False for a place the event doesn't have.
function Live:PointMe(occId, pid)
    if type(occId) ~= "string" then return false end
    if pid == nil then
        myPoint[occId] = nil
        Fire(occId)
        return true
    end
    local def = self:GetDef(occId)
    if not (type(pid) == "string" and type(def) == "table" and type(def.places) == "table" and type(def.places[pid]) == "table") then
        return false
    end
    myPoint[occId] = pid
    Fire(occId)
    return true
end

-- Where the event's entrants meet (a planned event too): pid, yards, bearing (as MyPoint), or nil (nowhere set).
function Live:MyMeet(occId)
    local def, pid
    if occId == "practice" then
        def = practice and practice.run and practice.run.def
        pid = def and def.meet
    else
        local o = Events():GetOcc(occId)
        def = o and o.def
        pid = o and Events():MeetOf(o)
    end
    if not (type(pid) == "string" and type(def) == "table" and type(def.places) == "table" and type(def.places[pid]) == "table") then
        return nil
    end
    local yards, bearing = WayTo(def, pid)
    return pid, yards, bearing
end

-- The run's "tell" lines to me, newest first: { {at, text} }.
function Live:MyFeed(occId)
    local out = {}
    for i, e in ipairs(feeds[occId] or {}) do out[i] = { at = e.at, text = e.text } end
    return out
end

-- I press a button the run gave me.
function Live:Press(occId, label)
    if type(label) ~= "string" or not Contains(self:MyButtons(occId), label) then return false end
    return self:SendFact(occId, { k = "press", label = label })
end

-- My answer to an ask (one each): a key (or up to `votes` keys), a choice's text, text, true / false or a number.
function Live:AnswerAsk2(occId, aid, value)
    -- (more picks than any ask takes: refused, not cut down to the first three)
    if type(value) == "table" and #value > 3 then return false end
    local v = AnswerValue(value)
    local st, def = self:GetState(occId), self:GetDef(occId)
    local q = type(st) == "table" and type(st.qa) == "table" and st.qa[aid]
    if v == nil or type(q) ~= "table" or not q.open or not Has(q.who, Me()) then return false end
    -- an answer the run takes (a player it may pick, one of the choices, 1-10 ...): else it would be lost
    local ad = type(def) == "table" and type(def.asks) == "table" and def.asks[aid]
    if type(ad) ~= "table" then return false end
    local Eng = E()
    if Eng and Eng.Reader then
        local reader = Eng:Reader(def, st)
        if reader.CheckAnswer and reader:CheckAnswer(ad, Me(), v) == nil then return false end
    end
    local mine = myAnswers[occId] or {}
    myAnswers[occId] = mine
    local key = AnswerKey(aid, q)
    if mine[key] ~= nil or (type(q.ans) == "table" and q.ans[Me()] ~= nil) then return false end
    local ok = self:SendFact(occId, { k = "ans", aid = aid, v = v })
    if ok then
        mine[key] = v
        answerSent[occId .. "/" .. key] = GetTime()
        Fire(occId)
    end
    return ok
end

-- My answers the host's state doesn't show while the ask is still open (they went out while the host reloaded, or
-- to a host who was gone before someone took over): sent again, at most every ANSWER_AGAIN s (the run takes one
-- answer each, so a copy that crosses the first one does nothing).
function Live:AnswerAgain(occId, st)
    local mine = myAnswers[occId]
    if not mine or type(st) ~= "table" or type(st.qa) ~= "table" or st.phase ~= "live" then return end
    local me = Me()
    for aid, q in pairs(st.qa) do
        if type(q) == "table" and q.open and Has(q.who, me) and not (type(q.ans) == "table" and q.ans[me] ~= nil) then
            local key = AnswerKey(aid, q)
            local v = mine[key]
            local sent = occId .. "/" .. key
            if v ~= nil and GetTime() - (answerSent[sent] or 0) >= ANSWER_AGAIN then
                answerSent[sent] = GetTime()
                self:SendFact(occId, { k = "ans", aid = aid, v = v })
            end
        end
    end
end

---------------------------------------------------------------------------
-- Practice runs (the builder): the real engine, dummies for players, nothing sent
---------------------------------------------------------------------------

local DUMMY_CLASSES = { "MAGE", "WARRIOR", "ROGUE", "SHAMAN", "PRIEST", "WARLOCK", "DRUID", "HUNTER", "PALADIN" }

function Live:DummyClass(key)
    local n = tonumber(type(key) == "string" and key:match("^Dummy(%d+)%-Practice$"))
    if not n then return nil end
    return DUMMY_CLASSES[((n - 1) % #DUMMY_CLASSES) + 1]
end

local function PracticeNow()
    local p = practice
    if not p then return Now() end
    if p.paused then return p.virt end
    return p.virt + (GetTime() - p.base) * p.speed
end

local function Rebase()
    local p = practice
    if not p then return end
    p.virt = PracticeNow()
    p.base = GetTime()
end

-- A practice run's message: the run logs every one itself (the practice log); one for me also shows on my screen.
-- (Practice changes nothing in my game: no nameplates.)
local function PracticeSays(kind, keys, text, off)
    if not practice or kind == "plates" then return end
    if keys == "all" then keys = practice.run and practice.run.st.entrants or {} end
    if type(keys) == "string" then keys = { keys } end
    if Contains(type(keys) == "table" and keys or {}, Me()) then Receive("practice", kind, text, off) end
end

function Live:StartPractice(def, count)
    self:StopPractice()
    feeds.practice = nil
    count = max(2, min(32, tonumber(count) or 16))
    local dummies = {}
    for i = 1, count do dummies[i] = "Dummy" .. i .. "-Practice" end
    practice = { def = def, dummies = dummies, off = {}, virt = Now(), base = GetTime(), speed = 1, paused = false, log = {},
        dummyAsked = {}, dummyAnswers = {} }
    local out = {
        log = function(kind, text) ns:Fire("EVENT_PRACTICE_LOG", kind, text) end,
        ran = function(sid, block) ns:Fire("EVENT_PRACTICE_RAN", sid, block) end,
        changed = function() ns:Fire("EVENT_PRACTICE_UPDATED") end,
        ended = function() ns:Fire("EVENT_PRACTICE_UPDATED") end,
        isOnline = function(k) return not practice or not practice.off[k] end,
        -- the addon's messages: in the log, and mine on my screen (nothing reaches the world)
        show = function(keys, text) PracticeSays("show", keys, Text(tostring(text or ""))) end,
        tell = function(keys, text) PracticeSays("tell", keys, Text(tostring(text or ""))) end,
        sound = function(keys, sound) PracticeSays("sound", keys, Text(tostring(sound or ""), 32)) end,
        plates = function(keys, off) PracticeSays("plates", keys, nil, off and true or false) end,
        guild = function() end,   -- (the run doesn't post in practice; it logs the line)
        -- dummies answer at once with what really happened; the host (me) answers on the board
        ask = function(a)
            if not practice then return end
            local truth = practice.lastWin
            for _, k in ipairs(a.to) do
                if k:find("%-Practice$") then
                    practice.answers = practice.answers or {}
                    tinsert(practice.answers, { id = a.id, k = k, v = truth or a.opts[1], at = GetTime() + 2 })
                end
            end
        end,
    }
    practice.run = E():New(def, { id = "practice", host = Me(), signups = dummies, out = out, practice = true,
        now = PracticeNow, nameOf = DisplayName, worldPos = WorldPos })
    practice.run:Start()
    EnsureTicker()
    ns:Fire("EVENT_PRACTICE_UPDATED")
    return practice.run
end

function Live:StopPractice()
    if not practice then return end
    practice = nil
    ns:Fire("EVENT_PRACTICE_UPDATED")
end

function Live:GetPractice() return practice and practice.run or nil, practice end

function Live:PracticeTick()
    local p = practice
    if not p or not p.run then return end
    if p.answers then
        for i = #p.answers, 1, -1 do
            local a = p.answers[i]
            if GetTime() >= a.at then
                tremove(p.answers, i)
                p.run:Answer(a.id, a.k, a.v)
            end
        end
    end
    if not p.paused then
        self:PracticeDummiesAnswer()
        p.run:Tick()
    end
end

-- A dummy's answer to an ask: someone it may pick, a choice, yes or no, 1-10, or for a quiz question its first right
-- answer more often than not.
local function DummyAnswer(run, aid, q, key)
    local a = type(run.def.asks) == "table" and type(run.def.asks[aid]) == "table" and run.def.asks[aid] or {}
    local kind = a.kind or q.kind or "choice"
    if kind == "player" then
        local pool = AskPlayers(run.st, a, key)
        if #pool == 0 then return nil end
        local votes = max(1, min(3, tonumber(a.votes) or 1))
        if votes == 1 then return pool[math.random(#pool)] end
        local picks = {}
        for _ = 1, min(votes, #pool) do picks[#picks + 1] = tremove(pool, math.random(#pool)) end
        return picks
    elseif kind == "yesno" then
        return math.random(2) == 1
    elseif kind == "number" then
        return math.random(1, 10)
    elseif kind == "text" then
        -- (a quiz question's answers: its list item's)
        local item = type(q.item) == "table" and q.item
        local l = item and type(run.def.lists) == "table" and run.def.lists[item.ql]
        local it = type(l) == "table" and type(l.items) == "table" and l.items[item.qi]
        local right = type(it) == "table" and type(it.a) == "table" and it.a[1]
        if type(right) == "string" and math.random(10) <= 6 then return right end
        return "No idea"
    end
    local choices = type(q.choices) == "table" and q.choices or a.choices
    if type(choices) == "table" and #choices > 0 then return choices[math.random(#choices)] end
    return nil
end

-- Dummies answer the asks put to them, a few seconds later (faster at a higher practice speed).
function Live:PracticeDummiesAnswer()
    local p = practice
    local run = p and p.run
    if not run or not run.AskAnswer or type(run.st.qa) ~= "table" then return end
    for aid, q in pairs(run.st.qa) do
        if type(q) == "table" and q.open then
            for _, k in ipairs(SetKeys(q.who)) do
                local tag = AnswerKey(aid, q) .. "@" .. k
                if k:find("%-Practice$") and not (type(q.ans) == "table" and q.ans[k] ~= nil) and not p.dummyAsked[tag] then
                    p.dummyAsked[tag] = true
                    tinsert(p.dummyAnswers, { aid = aid, k = k, v = DummyAnswer(run, aid, q, k),
                        at = GetTime() + (2 + math.random() * 4) / max(0.25, p.speed or 1) })
                end
            end
        end
    end
    for i = #p.dummyAnswers, 1, -1 do
        local d = p.dummyAnswers[i]
        if GetTime() >= d.at then
            tremove(p.dummyAnswers, i)
            if d.v ~= nil then run:AskAnswer(d.aid, d.k, d.v) end
        end
    end
end

-- The practice inputs (the dummies panel): something happens to a dummy, it goes in or out of a place, touches or
-- targets someone, stands somewhere, answers, presses a button.
local function PracticeRun(fn)
    local run = practice and practice.run
    return run and type(run[fn]) == "function" and run or nil
end

function Live:PracticeHappen(key, what, data)
    local run = PracticeRun("Happen")
    if run then run:Happen(key, what, type(data) == "table" and data or {}) end
end

function Live:PracticePlace(key, pid, inside)
    local run = PracticeRun("Place")
    if run then run:Place(key, pid, inside and true or false) end
end

function Live:PracticeTouch(who, whom, how, emote)
    local run = PracticeRun("Touch")
    if run then run:Touch(who, whom, how or "click", emote) end
end

function Live:PracticeRadar(who, whom)
    local run = PracticeRun("Radar")
    if run then run:Radar(who, whom) end
end

function Live:PracticePos(key, pos)
    local run = PracticeRun("Pos")
    if run and type(pos) == "table" then
        local clean = CleanPos(pos)
        if clean then run:Pos(key, clean) end
    end
end

function Live:PracticeAnswer(key, aid, value)
    local run = PracticeRun("AskAnswer")
    local v = AnswerValue(value)
    if run and v ~= nil then run:AskAnswer(aid, key, v) end
end

function Live:PracticePress(key, label)
    local run = PracticeRun("Press")
    if run and type(label) == "string" then run:Press(key, label) end
end

-- A dummy duel: agree = both games saw it (the default); false makes the Bracket ask the players.
function Live:PracticeDuel(w, l, agree)
    local p = practice
    if not p then return end
    p.lastWin = w
    p.run:Duel(w, l, agree ~= false)
end

function Live:PracticeOffline(key, off)
    local p = practice
    if not p then return end
    p.off[key] = off and true or nil
    p.run:SetOnline(key, not off)
end

function Live:PracticeReady(key)
    if practice then practice.run:SetReady(key) end
end

function Live:SetPracticeSpeed(speed)
    if not practice then return end
    Rebase()
    practice.speed = tonumber(speed) or 1
    ns:Fire("EVENT_PRACTICE_UPDATED")
end

function Live:SetPracticePaused(paused)
    if not practice then return end
    Rebase()
    practice.paused = paused and true or false
    ns:Fire("EVENT_PRACTICE_UPDATED")
end

-- Jumps the practice clock to the next timer or wait (a 5 minute no-show takes a click).
function Live:PracticeSkip()
    local p = practice
    if not p or not p.run then return end
    local now = PracticeNow()
    local soonest
    for _, t in ipairs(p.run.st.timers) do
        if not soonest or t.at < soonest then soonest = t.at end
    end
    for th in pairs(p.run.threads) do
        local w = th.wait
        if w and w.at and (not soonest or w.at < soonest) then soonest = w.at end
    end
    if not soonest or soonest <= now then return end
    Rebase()
    p.virt = soonest
    p.run:Tick()
    ns:Fire("EVENT_PRACTICE_UPDATED")
end

function Live:PracticeNow() return PracticeNow() end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- My event cancelled, or taken off the calendar, while I run it: the run stops (one taken off keeps no result).
local function CheckHostedOccs()
    for occId, h in pairs(hosting) do
        if h.run.st.phase == "live" then
            local o = Events():GetOcc(occId, true)
            if not o and Events():OccRemoved(occId) then
                h.gone = true
                h.run:Cancel("Taken off the calendar")
            elseif o and o.cancel then
                h.run:Cancel(o.cancel)
            end
        end
    end
end

-- The host's /reload (or a quick relog): the runs I host are kept at logout and go on after it, when that was soon
-- enough that no entrant took over yet (they wait GONE_SILENT at least; this leaves them a margin).
local RESTORE_WITHIN = GONE_SILENT - QUIET_SLACK

local function SaveHosted()
    local db = ns.db
    if not db then return end
    local keep
    for occId, h in pairs(hosting) do
        if h.run.st.phase == "live" then
            keep = keep or {}
            keep[occId] = { me = Me(), st = h.run:Snapshot(true), c = h.hosts, at = Now() }   -- (all of it: my own disk)
        end
    end
    db.eventHosting = keep
end

local function RestoreHosted()
    local db = ns.db
    local list = db and db.eventHosting
    if type(list) ~= "table" then return end
    db.eventHosting = nil
    for occId, e in pairs(list) do
        if type(e) == "table" and e.me == Me() and type(e.st) == "table" and e.st.phase == "live"
            and (tonumber(e.at) or 0) > Now() - RESTORE_WITHIN and not hosting[occId] and not seen[occId] then
            Resume(occId, e.st, type(e.c) == "table" and e.c or nil)
        end
    end
end

function Live:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("EVS", OnState)
        Comm:Register("EVH", OnBeat)
        Comm:Register("EVQ", OnQuery)
        Comm:Register("EVF", OnFact)
        Comm:Register("EVM", OnMessage)
        if Comm.AllowLarge then Comm:AllowLarge("EVS", "event") end
    end
    ns:RegisterEvent("CHAT_MSG_SYSTEM", OnSystem)
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function() FlushInvites() end)
    ns:RegisterEvent("PLAYER_LOGOUT", SaveHosted)
    ns:On("EVENTS_UPDATED", CheckHostedOccs)
    ns:On("DEMO_TOGGLED", function()
        demoLive = nil
        Fire("demo")
    end)
end

function Live:OnLogin()
    -- (a moment for the guild to be there: the state goes to it at once)
    Util.After(3, RestoreHosted)
end

-- (harness / debugging)
function Live:_State() return hosting, seen, practice end
