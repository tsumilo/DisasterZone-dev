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
-- The host gone (no EVS / EVH for 50 s and offline, or 90 s whatever): the entrants still online take over in name
-- order, each waiting its turn; the first one sends the state with itself as host and goes on from there (scripts that
-- were waiting are lost, everything else carries on: timers, matches, stats). The host's own /reload: its runs are
-- kept at logout and go on after it (db.eventHosting, read and cleared at login).
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
local CHAT_PER_MIN = 8        -- lines an event says in chat a minute (the rest are dropped)
local WHISPER_PER_MIN = 30    -- (the rest wait their turn)
local WHISPER_QUEUE = 120
local GONE_FOR_GOOD = 600     -- a run nobody hosts any more (its host gone, no entrant took over) is forgotten then
local QUIET_SLACK = 10        -- an entrant taking over heard the host last about when I did (give or take this)
local MAX_CHAIN = 8           -- hosts a state names (the first one and the last ones)
local FROM_ME_AHEAD = 5       -- changes an entrant who took my run over can be past my own state

local hosting = {}            -- [occId] = { run, occ, hosts, sendAt, dirty, pending, recent, watchers, lastBeat }
local seen = {}               -- [occId] = { st, h, c, at (GetTime), def }
local shownAnn, shownCd = {}, {}
local practice                -- { run, def, clock, dummies, off }
local ticker
local chatLog = {}            -- GetTime() of the event's recent chat lines
local whisperLog = {}
local whisperQueue = {}       -- { {key, text} } over the whisper rate, sent as it allows
local inviteQueue = {}        -- keys a run asked to invite and not invited yet
local invitedAt = {}          -- [key] = GetTime() their invite went out

local function Now() return (GetServerTime and GetServerTime()) or time() end
local function Me() return Util.PlayerKey() end
local function Events() return ns.Events end
local function E() return ns.EventEngine end
local function B() return ns.EventBlocks end
local function DemoOn() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() or false end

local function WireKey(s)
    if type(s) ~= "string" or s == "" or #s > 48 or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

local function Send(msg, dist, target)
    if DemoOn() then return false end
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, "event")) and true or false
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

---------------------------------------------------------------------------
-- What the world sees of a run (chat, whispers, invites, marks)
---------------------------------------------------------------------------

local function Allowed(log, perMin)
    local now = GetTime()
    while log[1] and now - log[1] > 60 do tremove(log, 1) end
    if #log >= perMin then return false end
    log[#log + 1] = now
    return true
end

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

local function Whisper(key, text)
    if SendChatMessage then pcall(SendChatMessage, text, "WHISPER", nil, Util.ShortName(key)) end
end

-- Whispers that waited for the rate (every tick).
local function FlushWhispers()
    while whisperQueue[1] and not DemoOn() and Allowed(whisperLog, WHISPER_PER_MIN) do
        local w = tremove(whisperQueue, 1)
        Whisper(w[1], w[2])
    end
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
        -- (demo mode: nothing reaches the world)
        say = function(ch, text)
            text = strsub(tostring(text or ""), 1, 250)
            if DemoOn() or not Allowed(chatLog, CHAT_PER_MIN) then return end
            if (ch == "RAID" and not (IsInRaid and IsInRaid())) or (ch == "PARTY" and not (IsInGroup and IsInGroup())) then
                return
            end
            if ch == "GUILD" and not (IsInGuild and IsInGuild()) then return end
            if SendChatMessage then pcall(SendChatMessage, text, ch) end
        end,
        whisper = function(key, text)
            text = strsub(tostring(text or ""), 1, 250)
            if Util.IsMe(key) then
                ns:Print("%s", text)
                return
            end
            if DemoOn() then return end
            if whisperQueue[1] or not Allowed(whisperLog, WHISPER_PER_MIN) then
                if #whisperQueue < WHISPER_QUEUE then whisperQueue[#whisperQueue + 1] = { key, text } end
                return
            end
            Whisper(key, text)
        end,
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
        isOnline = IsOnline,
        zoneOf = ZoneOf,
        changed = function() Live:Dirty(occId) end,
        ended = function(run) Live:Ended(occId, run) end,
    }
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
        rankOf = function(k) return Events():RankOf(k) end, nameOf = DisplayName })
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
        nameOf = DisplayName })
    run.st.host = Me()
    local hosts = {}
    for _, h in ipairs(chain or {}) do hosts[#hosts + 1] = h end
    if hosts[#hosts] ~= Me() then hosts[#hosts + 1] = Me() end
    while #hosts > MAX_CHAIN do tremove(hosts, 2) end
    NewHost(occId, o, run, hosts)
    seen[occId] = nil
    run:Changed()
    Live:SendState(occId, true)
    ns:Print("you're hosting %s now.", o.def.name or "the event")
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
    h.dirty = not Send({ t = "EVS", o = occId, h = h.run.st.host, s = h.run:Snapshot(), c = h.hosts }, "GUILD")
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
    Send({ t = "EVS", o = occId, h = key, s = h.run:Snapshot(), c = chain }, "GUILD")
    seen[occId] = { st = h.run:Snapshot(), h = key, c = chain, at = GetTime() }
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
        for _, t in ipairs(run.st.timers) do t.at = t.at + shift end
        for th in pairs(run.threads) do
            if th.wait and th.wait.at then th.wait.at = th.wait.at + shift end
        end
        for id, at in pairs(run.st.everyAt or {}) do run.st.everyAt[id] = at + shift end
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
    h.recent[key] = p.at
    h.run:Duel(p.w, p.l, agree)
end

-- at: the server time the reporter saw the duel end (the same second on both clients).
local function OnDuelReport(h, sender, w, l, at)
    if sender ~= w and sender ~= l then return end
    local run = h.run
    if not (Contains(run.st.entrants, w) and Contains(run.st.entrants, l)) then return end
    local key = PairKey(w, l)
    at = tonumber(at) or Now()
    -- the other duelist's report of a duel already counted
    if h.recent[key] and math.abs(at - h.recent[key]) <= SAME_DUEL then return end
    local p = h.pending[key]
    if p and math.abs(at - p.at) > SAME_DUEL then
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

local function OnFact(sender, msg, dist)
    if dist ~= "WHISPER" and sender ~= Me() then return end
    local occId = type(msg.o) == "string" and msg.o
    local h = occId and hosting[occId]
    if not h or h.run.st.phase ~= "live" then return end
    local run = h.run
    local k = msg.k
    if k == "duel" then
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
    FlushWhispers()
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

function Live:StartPractice(def, count)
    self:StopPractice()
    count = max(2, min(32, tonumber(count) or 16))
    local dummies = {}
    for i = 1, count do dummies[i] = "Dummy" .. i .. "-Practice" end
    practice = { def = def, dummies = dummies, off = {}, virt = Now(), base = GetTime(), speed = 1, paused = false, log = {} }
    local out = {
        log = function(kind, text) ns:Fire("EVENT_PRACTICE_LOG", kind, text) end,
        ran = function(sid, block) ns:Fire("EVENT_PRACTICE_RAN", sid, block) end,
        changed = function() ns:Fire("EVENT_PRACTICE_UPDATED") end,
        ended = function() ns:Fire("EVENT_PRACTICE_UPDATED") end,
        isOnline = function(k) return not practice or not practice.off[k] end,
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
        now = PracticeNow, nameOf = DisplayName })
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
    if not p.paused then p.run:Tick() end
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
            keep[occId] = { me = Me(), st = h.run:Snapshot(), c = h.hosts, at = Now() }
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
