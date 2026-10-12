if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Polls.lua", ...) then return end -- DisasterZone: the guild's polls (Guild > Polls).
-- The GM, the officers and the guild council ask; the people they pick answer. Stored and synced guild-wide:
--   P  polls: { id, by, rev, q = question, k = kind, o = answers, mx, cl = closes at, rv = results shown, ch = answers
--      can change, a = who it asks (as picked), m = the people asked (taken when it was posted, one character per
--      player), del }. Only its asker edits it (the question, the answers' words, the closing time, more people);
--      the asker or the GM removes it. Its kind and its number of answers never change once posted.
--   V  answers: one per poll and person asked, id = poll id .. "/" .. the asked character, written by that character
--      or another character of the same player (Guild:SameAccount): one answer per player.
-- Kinds: "one" (one answer), "many" (several, mx = at most that many, 0 = any), "yn" (yes or no) and "days" (pick
-- days: o = "YYYY-MM-DD" or "YYYY-MM-DD HH:MM"; an answer says for each day 1 = can, 2 = if needed, 0 = can't).
-- rv: "live" (results always), "vote" (after you answered), "close" (once it closes). Names are always shown.
-- A poll is shown only to the people it asks and its asker; everyone's client still keeps and relays it, so a member
-- who was offline gets it from whoever is online.
-- Sync works like the events library (Core/Events.lua): the guild HELLO carries a digest hash (od); a member whose hash
-- differs gets a digest (PLD) from one other member and asks for what it lacks (PLW -> PLG). A change goes to the guild
-- at once (PLU). PLN: the asker nudges the people who haven't answered (a pop-up on their screen, no chat).
local addonName, ns = ...

local Polls = ns:NewModule("Polls")
local Util = ns.Util

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local tsort, tconcat = table.sort, table.concat
local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

local DAY = 86400
local KINDS = { P = true, V = true }
local POLL_KINDS = { one = true, many = true, yn = true, days = true }
local SHOW = { live = true, vote = true, close = true }
local TOMBSTONE_KEEP = 30 * DAY    -- a deletion is in the digest this long; then kept as a grave (DigestSync.lua)
local GRAVE_KEEP = 365 * DAY
local MAX_GRAVES = 200
local CLOSED_KEEP = 60 * DAY         -- a closed poll (and its answers) is kept this long after it closed
local MAX_OPEN = 60                  -- polls stored at once (not removed)
local MAX_OWN = 20                   -- of one asker
local MAX_ANSWERS = 12
local MAX_DAYS = 14
local MAX_ASKED = 600                -- people one poll asks
local MAX_TARGETS = 24
local MAX_Q = 140
local MAX_A = 60
local MAX_LONG = 60 * DAY            -- a poll closes at most this long after it was posted
local CLOSE_SLACK = 300              -- an answer relayed from someone's store may be this much younger than the close
local MAX_DIGEST_ITEMS = 2000
local MAX_ID_LEN = 40
local MAX_KEY_LEN = 48
local MAX_ITEM_LEN = MAX_ID_LEN + MAX_KEY_LEN + 3
local DELAY_ASKER = { 0.5, 2.5 }
local DELAY_MEMBER = { 3, 8 }
local NUDGE_EVERY = 10 * 60          -- an asker nudges one poll at most this often

Polls.MAX_ANSWERS, Polls.MAX_DAYS, Polls.MAX_Q, Polls.MAX_A = MAX_ANSWERS, MAX_DAYS, MAX_Q, MAX_A

local demo

local Now = Util.Now          -- (the server clock: ns.Util.Now)
local function Guild() return ns.Guild end
local function Me() return Util.PlayerKey() end
local DemoOn = Util.DemoOn

local function WireKey(s)
    if type(s) ~= "string" or s == "" or #s > MAX_KEY_LEN or s:find("[%c|,]") then return nil end
    return Util.NormalizeName(s)
end

local function IsId(s)
    return type(s) == "string" and #s > 0 and #s <= MAX_ID_LEN and s:find("^[%w%-_]+$") ~= nil
end

local function Send(msg, dist, target, class)
    if DemoOn() then return false end
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, class)) and true or false
end

local RateLimit = Util.RateLimit

local function Changed()
    Util.Debounce("polls-changed", 0.15, function() ns:Fire("POLLS_UPDATED") end)
end

-- Stored in db.polls[guild key] and synced by Core/DigestSync.lua (PLU / PLD / PLK / PLW / PLG, the HELLO's od);
-- the record checks (clean, merge) are set below, where they are.
local SYNC = {
    module = Polls, bucket = "polls", kinds = { "P", "V" }, prefix = "PL",
    maxItems = MAX_DIGEST_ITEMS, maxItemLen = MAX_ITEM_LEN + 2, itemPattern = "^[PV]:", wireKey = WireKey,
    helloField = "od", helloOrder = 60, large = true, changed = Changed,
    tombKeep = { P = TOMBSTONE_KEEP }, graveKeep = GRAVE_KEEP, maxGraves = MAX_GRAVES,
    tooBig = "this poll is too big to share with the guild: ask fewer people or give fewer answers.",
    delay = function() return Polls:AmIAsker() and DELAY_ASKER or DELAY_MEMBER end,
}
local sync = ns.DigestSync.New(SYNC)
local Newer = sync.Newer

local function Root(create) return sync:Root(create) end

-- What the UI reads: the saved root, or demo mode's own.
local function State()
    if DemoOn() then
        if not demo then Polls:BuildDemo() end
        return demo
    end
    return Root(false)
end

local function NewId() return sync:NewId("p") end

---------------------------------------------------------------------------
-- Roles
---------------------------------------------------------------------------

-- The GM, the officers and the guild council ask polls.
function Polls:CanAsk(key)
    local G = Guild()
    if type(key) ~= "string" or not G then return false end
    if DemoOn() and Util.IsMe(key) then return true end
    return (G.IsGM and G:IsGM(key)) or (G.IsOfficer and G:IsOfficer(key, not Util.IsMe(key)))
        or (G.IsGuildCouncil and G:IsGuildCouncil(key)) or false
end

function Polls:AmIAsker() return self:CanAsk(Me()) end

-- The poll's asker, or the GM: close, extend, remove.
function Polls:CanManage(p, key)
    key = key or Me()
    if type(p) ~= "table" or type(key) ~= "string" then return false end
    if p.by == key then return true end
    local G = Guild()
    if DemoOn() and Util.IsMe(key) then return true end
    return (G and G.IsGM and G:IsGM(key)) and true or false
end

---------------------------------------------------------------------------
-- Cleaning what arrives (and what is saved)
---------------------------------------------------------------------------

local function Str(s, maxLen)
    if type(s) ~= "string" then return nil end
    s = s:gsub("[%c|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    if #s > maxLen then
        s = s:sub(1, maxLen)
        -- (never half a UTF-8 letter)
        while #s > 0 and s:byte(#s) >= 128 and s:byte(#s) < 192 do s = s:sub(1, #s - 1) end
        if #s > 0 and s:byte(#s) >= 192 then s = s:sub(1, #s - 1) end
    end
    return s
end

local function Int(n, lo, hi)
    n = tonumber(n)
    if not n or n ~= floor(n) or n < lo or n > hi then return nil end
    return n
end

-- "2026-10-13" or "2026-10-13 20:00": y, m, d, hh|nil, mm|nil.
local function DayParts(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, rest = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    if not y or mo < 1 or mo > 12 or d < 1 or d > 31 then return nil end
    if rest == "" then return y, mo, d end
    local hh, mm = rest:match("^ (%d%d):(%d%d)$")
    hh, mm = tonumber(hh), tonumber(mm)
    if not hh or hh > 23 or mm > 59 then return nil end
    return y, mo, d, hh, mm
end
Polls.DayParts = DayParts

local function CleanTarget(t)
    if type(t) ~= "table" then return nil end
    local k = t[1]
    if k == "g" then return { "g" } end
    if k == "t" then
        if not IsId(t[2]) then return nil end
        local ln = t[3]
        if ln ~= nil and ln ~= false and not IsId(ln) then return nil end
        return { "t", t[2], ln or false, Str(t[4], 40) or "Team" }
    end
    if k == "r" then
        if t[2] ~= "officer" and t[2] ~= "council" and t[2] ~= "leader" then return nil end
        return { "r", t[2] }
    end
    if k == "k" then
        local i = Int(t[2], 0, 20)
        if not i then return nil end
        return { "k", i, Str(t[3], 40) or ("Rank " .. i) }
    end
    if k == "p" then
        local key = WireKey(t[2])
        return key and { "p", key } or nil
    end
    return nil
end

local function CleanPoll(r)
    if not IsId(r.id) then return nil end
    local by = WireKey(r.by)
    local rev = Int(r.rev, 1, 2 ^ 31)
    if not by or not rev then return nil end
    if r.del then return { id = r.id, by = by, rev = rev, del = true } end
    local k = POLL_KINDS[r.k] and r.k or nil
    local q = Str(r.q, MAX_Q)
    if not k or not q or type(r.o) ~= "table" then return nil end
    local o = {}
    for i = 1, (k == "days" and MAX_DAYS or MAX_ANSWERS) do
        local v = r.o[i]
        if v == nil then break end
        if k == "days" then
            if not DayParts(v) then return nil end
            o[i] = v
        else
            o[i] = Str(v, MAX_A)
            if not o[i] then return nil end
        end
    end
    if #o < (k == "days" and 1 or 2) or (k == "yn" and #o ~= 2) then return nil end
    local at = Int(r.at, 1, 2 ^ 31)
    local cl = Int(r.cl, 1, 2 ^ 31)
    if not at or not cl or cl < at or cl > at + MAX_LONG then return nil end
    local a = {}
    for i = 1, MAX_TARGETS do
        if r.a == nil or r.a[i] == nil then break end
        local t = CleanTarget(r.a[i])
        if not t then return nil end
        a[#a + 1] = t
    end
    if type(r.m) ~= "table" then return nil end
    local m, seen = {}, {}
    for i = 1, MAX_ASKED do
        local v = r.m[i]
        if v == nil then break end
        local key = WireKey(v)
        if not key or seen[key] then return nil end
        seen[key] = true
        m[#m + 1] = key
    end
    if r.m[MAX_ASKED + 1] ~= nil or #m == 0 then return nil end
    local out = { id = r.id, by = by, rev = rev, at = at, q = q, k = k, o = o, cl = cl, a = a, m = m,
                  rv = SHOW[r.rv] and r.rv or "vote", ch = r.ch and true or nil }
    if k == "many" then out.mx = Int(r.mx, 0, #o) or 0 end
    return out
end

-- An answer for a poll of `kind` with `n` answers (mx: "many"'s cap): the cleaned list, or nil.
local function CleanChoice(kind, c, n, mx)
    if type(c) ~= "table" then return nil end
    local out = {}
    if kind == "days" then
        for i = 1, n do
            local v = Int(c[i], 0, 2)
            if not v then return nil end
            out[i] = v
        end
        if c[n + 1] ~= nil then return nil end
        return out
    end
    local seen = {}
    for i = 1, n do
        local v = c[i]
        if v == nil then break end
        v = Int(v, 1, n)
        if not v or seen[v] then return nil end
        seen[v] = true
        out[#out + 1] = v
    end
    if c[#out + 1] ~= nil or #out == 0 then return nil end
    if (kind == "one" or kind == "yn") and #out ~= 1 then return nil end
    if kind == "many" and mx and mx > 0 and #out > mx then return nil end
    tsort(out)
    return out
end

local function CleanVote(r)
    if type(r.id) ~= "string" or #r.id > MAX_ITEM_LEN then return nil end
    local pid, slot = r.id:match("^([^/]+)/(.+)$")
    if not IsId(pid) or not WireKey(slot) or WireKey(slot) ~= slot then return nil end
    local by = WireKey(r.by)
    local rev = Int(r.rev, 1, 2 ^ 31)
    if not by or not rev or type(r.c) ~= "table" then return nil end
    local c = {}
    for i = 1, MAX_DAYS do
        local v = Int(r.c[i], 0, MAX_ANSWERS)
        if r.c[i] == nil then break end
        if not v then return nil end
        c[i] = v
    end
    if #c == 0 or r.c[#c + 1] ~= nil then return nil end
    return { id = r.id, p = pid, s = slot, by = by, rev = rev, c = c }
end

local function CleanRecord(kind, r)
    if type(r) ~= "table" then return nil end
    local ok, out = pcall(kind == "P" and CleanPoll or CleanVote, r)
    if ok then return out end
    return nil
end
Polls.CleanRecord = CleanRecord

---------------------------------------------------------------------------
-- Who a poll asks
---------------------------------------------------------------------------

local function InSet(list)
    local set = {}
    for _, k in ipairs(list or {}) do set[k] = true end
    return set
end

-- The slot a character answers in: itself when the poll asks it, else the asked character of the same player.
local function SlotOf(p, key, set)
    if type(p) ~= "table" or p.del or type(key) ~= "string" then return nil end
    set = set or InSet(p.m)
    if set[key] then return key end
    local G = Guild()
    if not (G and G.GetLinkedCharacters) then return nil end
    for _, alt in ipairs(G:GetLinkedCharacters(key)) do
        if set[alt] then return alt end
    end
    return nil
end

function Polls:SlotOf(p, key) return SlotOf(p, key or Me()) end

-- The poll asks me (or another character of mine).
function Polls:AsksMe(p) return SlotOf(p, Me()) ~= nil end

-- Shown to me: it asks me, or I asked it.
function Polls:IsVisible(p)
    if type(p) ~= "table" or p.del then return false end
    return p.by == Me() or Util.IsMe(p.by) or SlotOf(p, Me()) ~= nil
end

-- Members the target covers right now (keys of guild members).
local function TargetKeys(t)
    local G, R = Guild(), ns.RaidPlan
    local out = {}
    local members = G and G.GetMembers and G:GetMembers() or {}
    if t[1] == "g" then
        for _, k in ipairs(members) do out[#out + 1] = k end
    elseif t[1] == "t" then
        local team = R and R.GetTeam and R:GetTeam(t[2])
        if team then
            local l = t[3] and R.FindLineup and R:FindLineup(team, t[3]) or nil
            if l then
                for _, k in ipairs(team.members) do
                    local g = l.groups[k]
                    if type(g) == "number" and g >= 1 then out[#out + 1] = k end
                end
                if #out == 0 then for _, k in ipairs(team.members) do out[#out + 1] = k end end
            else
                for _, k in ipairs(team.members) do out[#out + 1] = k end
            end
        end
    elseif t[1] == "r" then
        if t[2] == "officer" then
            for _, k in ipairs(members) do
                if G:IsGM(k) or G:IsOfficer(k, true) then out[#out + 1] = k end
            end
        elseif t[2] == "council" then
            local gc = G.GetGuildCouncil and G:GetGuildCouncil()
            for k in pairs(gc and gc.members or {}) do out[#out + 1] = k end
            local gm = G.GetGM and G:GetGM()
            if gm then out[#out + 1] = gm end
        elseif t[2] == "leader" then
            for _, k in ipairs(G.GetRaidLeaders and G:GetRaidLeaders() or {}) do out[#out + 1] = k end
        end
    elseif t[1] == "k" then
        for _, k in ipairs(members) do
            local m = G:GetMember(k)
            if m and tonumber(m.rankIndex) == t[2] then out[#out + 1] = k end
        end
    elseif t[1] == "p" then
        out[1] = t[2]
    end
    return out
end
Polls.TargetKeys = TargetKeys

-- The people a list of targets asks: one character per player (the first met, in the targets' order), sorted.
function Polls:Resolve(targets)
    local G = Guild()
    local set, out = {}, {}
    local function add(k)
        if set[k] or #out >= MAX_ASKED then return end
        if G and G.GetLinkedCharacters then
            for _, alt in ipairs(G:GetLinkedCharacters(k)) do
                if set[alt] then return end
            end
        end
        set[k] = true
        out[#out + 1] = k
    end
    for _, t in ipairs(targets or {}) do
        for _, k in ipairs(TargetKeys(t)) do add(k) end
    end
    tsort(out)
    return out
end

-- A target's words for chips and lines: "Main team", "Officers", "Raider", a short name.
function Polls:TargetName(t)
    if type(t) ~= "table" then return "" end
    if t[1] == "g" then return "Everyone" end
    if t[1] == "t" then
        local R = ns.RaidPlan
        local team = R and R.GetTeam and R:GetTeam(t[2])
        local name = team and team.name or t[4] or "Team"
        if t[3] and team then
            local l = R:FindLineup(team, t[3])
            if l then return name .. " · " .. R:LineupName(team, l) end
        end
        return name
    end
    if t[1] == "r" then
        return ({ officer = "Officers", council = "Guild Council", leader = "Raid leaders" })[t[2]] or ""
    end
    if t[1] == "k" then
        local G = Guild()
        for _, k in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
            local m = G:GetMember(k)
            if m and tonumber(m.rankIndex) == t[2] and m.rankName then return m.rankName end
        end
        return t[3] or "Rank"
    end
    if t[1] == "p" then return Util.ShortName(t[2]) or t[2] end
    return ""
end

-- What the "Who votes" field offers: { { kind = "g"|"team"|"lineup"|"role"|"rank"|"player", target, name, n, class } }.
function Polls:AudienceOptions()
    local G, R = Guild(), ns.RaidPlan
    local out = {}
    local function opt(kind, t, name, extra)
        local e = { kind = kind, target = t, name = name, n = #self:Resolve({ t }) }
        for k, v in pairs(extra or {}) do e[k] = v end
        out[#out + 1] = e
    end
    opt("g", { "g" }, "Everyone in the guild")
    for _, team in ipairs(R and R.GetTeams and R:GetTeams() or {}) do
        opt("team", { "t", team.id, false, team.name }, team.name)
        if #team.lineups > 1 then
            for _, l in ipairs(team.lineups) do
                opt("lineup", { "t", team.id, l.id, team.name }, R:LineupName(team, l), { team = team.name })
            end
        end
    end
    opt("role", { "r", "officer" }, "Officers")
    opt("role", { "r", "council" }, "Guild Council")
    opt("role", { "r", "leader" }, "Raid leaders")
    local ranks, seen = {}, {}
    for _, k in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        local m = G:GetMember(k)
        local i = m and tonumber(m.rankIndex)
        if i and not seen[i] then
            seen[i] = true
            ranks[#ranks + 1] = { i = i, name = m.rankName or ("Rank " .. i) }
        end
    end
    tsort(ranks, function(a, b) return a.i < b.i end)
    for _, rk in ipairs(ranks) do opt("rank", { "k", rk.i, rk.name }, rk.name) end
    for _, k in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        out[#out + 1] = { kind = "player", target = { "p", k }, name = Util.ShortName(k) or k, n = 1,
                          class = G.GetClass and G:GetClass(k) or nil, key = k }
    end
    return out
end

---------------------------------------------------------------------------
-- Merging (the same on every client, whatever order things arrive in)
---------------------------------------------------------------------------

local function CountLive(t, owner)
    local n = 0
    for _, r in pairs(t) do
        if not r.del and (not owner or r.by == owner) then n = n + 1 end
    end
    return n
end

local function Superset(new, old)
    local set = InSet(new)
    for _, k in ipairs(old or {}) do
        if not set[k] then return false end
    end
    return true
end

-- live: a live edit (PLU, or my own), checked against what is true now; else a record relayed from someone's store.
local function Merge(root, kind, rec, live)
    local t = root[kind]
    local cur = t[rec.id]
    if kind == "P" then
        if cur and cur.del and not rec.del then return false end         -- a removal wins
        -- (1.4.1) one Prune drops (CLOSED_KEEP after it closed) is not taken back from someone's store
        if not live and not rec.del and (rec.cl or 0) < Now() - CLOSED_KEEP then return false end
        if rec.del then
            if cur and not cur.del and rec.by ~= cur.by and not Polls:CanManage(cur, rec.by) then return false end
        elseif cur then
            if rec.by ~= cur.by then return false end                      -- only its asker edits it
            if rec.k ~= cur.k or #rec.o ~= #cur.o or rec.at ~= cur.at or (rec.mx or 0) ~= (cur.mx or 0) then
                return false
            end
            if not Superset(rec.m, cur.m) then return false end            -- people are only ever added
        else
            if not Polls:CanAsk(rec.by) then return false end
            if CountLive(t) >= MAX_OPEN or CountLive(t, rec.by) >= MAX_OWN then return false end
            if live and rec.at > Now() + 600 then return false end
        end
        if cur and not Newer(rec, cur) and not (rec.del and not cur.del) then return false end
    else
        local p = root.P[rec.p]
        if not p or p.del then return false end
        local set = InSet(p.m)
        if not set[rec.s] then return false end
        if rec.by ~= rec.s then
            local G = Guild()
            if not (G and G.SameAccount and G:SameAccount(rec.by, rec.s)) then return false end
        end
        local n = #p.o
        local c = CleanChoice(p.k, rec.c, n, p.mx)
        if not c or #c ~= #rec.c then return false end
        for i, v in ipairs(c) do
            if rec.c[i] ~= v then return false end
        end
        if live then
            if Now() >= p.cl then return false end
        elseif rec.rev > p.cl + CLOSE_SLACK then
            return false
        end
        if cur and not p.ch and live then return false end                -- answers can't change
        if cur and not Newer(rec, cur) then return false end
    end
    t[rec.id] = rec
    return true
end

SYNC.clean, SYNC.merge, SYNC.state = CleanRecord, Merge, State
-- demo mode: an answer must still fit its poll
SYNC.demoCheck = function(st, kind, clean)
    if kind ~= "V" then return true end
    local p = st.P[clean.p]
    return (p and CleanChoice(p.k, clean.c, #p.o, p.mx)) and true or false
end


-- My own change: stored (merged like anyone's), then sent to the guild. Returns ok, the clean record.
local function Commit(kind, rec) return sync:Commit(kind, rec) end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

function Polls:GetPoll(id)
    local st = State()
    local p = st and type(id) == "string" and st.P[id]
    if not p or p.del then return nil end
    return p
end

function Polls:IsOpen(p)
    return type(p) == "table" and not p.del and Now() < (p.cl or 0)
end

-- The answers of a poll: { [slot] = vote }.
function Polls:GetVotes(p)
    local out = {}
    local st = State()
    if not st or type(p) ~= "table" then return out end
    local prefix = p.id .. "/"
    for id, v in pairs(st.V) do
        if id:sub(1, #prefix) == prefix and v.p == p.id then out[v.s] = v end
    end
    return out
end

-- My answer (any of my characters'), or nil.
function Polls:MyVote(p)
    local slot = SlotOf(p, Me())
    if not slot then return nil end
    local st = State()
    return st and st.V[p.id .. "/" .. slot] or nil
end

-- May I see the results now?
function Polls:ResultsShown(p)
    if type(p) ~= "table" then return false end
    if p.rv == "live" or not self:IsOpen(p) then return true end
    if p.by == Me() then return true end                     -- (the asker; the GM sees them when they show)
    if p.rv == "vote" then return self:MyVote(p) ~= nil end
    return false
end

-- Polls I can see, sorted: open ones closing first, then closed ones (latest closed first).
function Polls:GetPolls()
    local out = {}
    local st = State()
    for _, p in pairs(st and st.P or {}) do
        if not p.del and self:IsVisible(p) then out[#out + 1] = p end
    end
    local now = Now()
    tsort(out, function(a, b)
        local ao, bo = a.cl > now, b.cl > now
        if ao ~= bo then return ao end
        if ao then
            if a.cl ~= b.cl then return a.cl < b.cl end
        elseif a.cl ~= b.cl then
            return a.cl > b.cl
        end
        return a.id < b.id
    end)
    return out
end

-- Open polls that ask me and that I haven't answered.
function Polls:GetWaiting()
    local out = {}
    for _, p in ipairs(self:GetPolls()) do
        if self:IsOpen(p) and self:AsksMe(p) and not self:MyVote(p) then out[#out + 1] = p end
    end
    return out
end

function Polls:WaitingCount() return #self:GetWaiting() end

-- The results: { total = people asked, answered = n, counts = { [i] = n }, maybe = { [i] = n } (days), no = { [i] = n }
-- (days), voters = { [i] = { key, ... } } (days: "can"), maybes = { [i] = { key } }, waiting = { key, ... } (sorted),
-- votes = { [slot] = vote }, best = i|nil (days: most "can", then "if needed", then fewest "can't") }.
-- A voter's key is who answered (the character that clicked).
function Polls:Results(p)
    local res = { total = #(p and p.m or {}), answered = 0, counts = {}, maybe = {}, no = {}, voters = {}, maybes = {},
                  waiting = {} }
    if type(p) ~= "table" then return res end
    for i = 1, #p.o do
        res.counts[i], res.maybe[i], res.no[i], res.voters[i], res.maybes[i] = 0, 0, 0, {}, {}
    end
    local votes = self:GetVotes(p)
    res.votes = votes
    for _, slot in ipairs(p.m) do
        local v = votes[slot]
        if v then
            res.answered = res.answered + 1
            if p.k == "days" then
                for i = 1, #p.o do
                    local s = v.c[i]
                    if s == 1 then
                        res.counts[i] = res.counts[i] + 1
                        res.voters[i][#res.voters[i] + 1] = v.by
                    elseif s == 2 then
                        res.maybe[i] = res.maybe[i] + 1
                        res.maybes[i][#res.maybes[i] + 1] = v.by
                    else
                        res.no[i] = res.no[i] + 1
                    end
                end
            else
                for _, i in ipairs(v.c) do
                    if res.counts[i] then
                        res.counts[i] = res.counts[i] + 1
                        res.voters[i][#res.voters[i] + 1] = v.by
                    end
                end
            end
        else
            res.waiting[#res.waiting + 1] = slot
        end
    end
    for i = 1, #p.o do
        tsort(res.voters[i])
        tsort(res.maybes[i])
    end
    if p.k == "days" and res.answered > 0 then
        local best
        for i = 1, #p.o do
            if not best then
                best = i
            else
                local a, b = res, i
                if a.counts[b] > a.counts[best] or (a.counts[b] == a.counts[best] and (a.maybe[b] > a.maybe[best]
                    or (a.maybe[b] == a.maybe[best] and a.no[b] < a.no[best]))) then
                    best = b
                end
            end
        end
        res.best = best
    end
    return res
end

-- A day of a "days" poll in words: "Mon 13", its time ("20:00") or nil, and the day's start (server time).
function Polls:DayLabel(s)
    local y, mo, d, hh, mm = DayParts(s)
    if not y then return tostring(s), nil, nil end
    local t = time({ year = y, month = mo, day = d, hour = 12 })
    return date("%a %d", t), hh and strformat("%02d:%02d", hh, mm) or nil, t
end

---------------------------------------------------------------------------
-- Writing
---------------------------------------------------------------------------

-- def = { q, k, o = { answers } (days: day strings), mx, cl = closes at, rv, ch, a = targets }. Returns the new id or
-- nil, why.
function Polls:Create(def)
    if not self:AmIAsker() then return nil, "Only the Guild Master, the officers and the guild council ask polls." end
    if type(def) ~= "table" then return nil, "nothing to post" end
    local a = {}
    for _, t in ipairs(def.a or {}) do
        local ct = CleanTarget(t)
        if ct then a[#a + 1] = ct end
    end
    local m = DemoOn() and self:DemoResolve(a) or self:Resolve(a)
    if #m == 0 then return nil, "Pick who votes first." end
    local o = def.k == "yn" and { "Yes", "No" } or def.o
    local id = NewId()
    local rec = { id = id, q = def.q, k = def.k, o = o, mx = def.mx, at = Now(), cl = def.cl, rv = def.rv,
                  ch = def.ch, a = a, m = m }
    if not CleanPoll({ id = id, by = Me(), rev = 1, q = rec.q, k = rec.k, o = o, mx = rec.mx, at = rec.at, cl = rec.cl,
                       rv = rec.rv, ch = rec.ch, a = a, m = m }) then
        return nil, "Something in this poll isn't right: check the question, the answers and the closing time."
    end
    local ok = Commit("P", rec)
    if not ok then return nil, "Couldn't post the poll." end
    return id
end

-- My poll with some fields changed: q, o (words only), cl, rv, ch, add = targets to add.
function Polls:Edit(id, changes)
    local p = self:GetPoll(id)
    if not p or not Util.IsMe(p.by) then return false end
    local rec = Util.CopyTable(p)
    rec.rev = nil
    for _, k in ipairs({ "q", "cl", "rv" }) do
        if changes[k] ~= nil then rec[k] = changes[k] end
    end
    if changes.ch ~= nil then rec.ch = changes.ch and true or nil end
    if type(changes.o) == "table" and #changes.o == #p.o then rec.o = changes.o end
    if type(changes.add) == "table" and #changes.add > 0 then
        local a = rec.a
        for _, t in ipairs(changes.add) do
            local ct = CleanTarget(t)
            if ct and #a < MAX_TARGETS then a[#a + 1] = ct end
        end
        local m, set = rec.m, InSet(rec.m)
        for _, k in ipairs(DemoOn() and self:DemoResolve(changes.add) or self:Resolve(changes.add)) do
            if not set[k] and not SlotOf({ m = m }, k, set) and #m < MAX_ASKED then
                set[k] = true
                m[#m + 1] = k
            end
        end
    end
    return (Commit("P", rec))
end

-- Closing now (the asker; the GM may remove someone else's poll, not edit it).
function Polls:Close(id)
    local p = self:GetPoll(id)
    if not p then return false end
    local now = Now()
    return self:Edit(id, { cl = max(p.at, now - 1) })
end

function Polls:Extend(id, seconds)
    local p = self:GetPoll(id)
    if not p then return false end
    local base = max(p.cl, Now())
    return self:Edit(id, { cl = min(base + (seconds or DAY), p.at + MAX_LONG) })
end

function Polls:Delete(id)
    local p = self:GetPoll(id)
    if not p or not self:CanManage(p) then return false end
    return (Commit("P", { id = id, del = true }))
end

-- My answer: choice = { indices } (one / yn: one index; many: several) or, for days, { 0|1|2 per day }.
function Polls:Vote(id, choice)
    local p = self:GetPoll(id)
    if not p or not self:IsOpen(p) then return false, "This poll is closed." end
    local slot = SlotOf(p, Me())
    if not slot then return false, "This poll doesn't ask you." end
    local c = CleanChoice(p.k, choice, #p.o, p.mx)
    if not c then return false, "Pick an answer first." end
    local mine = self:MyVote(p)
    if mine and not p.ch then return false, "Answers to this poll can't be changed." end
    local ok = Commit("V", { id = p.id .. "/" .. slot, p = p.id, s = slot, c = c })
    if ok then ns:Fire("POLL_ANSWERED", p.id) end
    return ok and true or false
end

-- Reminds the people who haven't answered (a pop-up on their screen). Returns the number waiting, or nil, why.
function Polls:Nudge(id)
    local p = self:GetPoll(id)
    if not p or not self:CanManage(p) then return nil end
    if not self:IsOpen(p) then return nil, "closed" end
    local waiting = self:Results(p).waiting
    if #waiting == 0 then return 0 end
    if not RateLimit("PLN:" .. id, NUDGE_EVERY) then return nil, "soon" end
    Send({ t = "PLN", p = id }, "GUILD", nil, "ctrl")
    return #waiting
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

-- PLU { k, r }: a change; its writer is the sender.
local function OnUpdate(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.r) ~= "table" or WireKey(msg.r.by) ~= sender then return end
    if not KINDS[msg.k] then return end
    local root = Root(false)
    local had = root and root.P[msg.r.id] ~= nil
    local ok, rec = sync:StoreFrom(sender, msg.k, msg.r, true)
    if not ok then return end
    Changed()
    if msg.k == "P" and not had and not rec.del and not Util.IsMe(rec.by) and Polls:AsksMe(rec) and Polls:IsOpen(rec) then
        ns:Fire("POLL_ARRIVED", rec.id)
    end
end

-- PLG { k, r }: one record, relayed by anyone in the guild.
local function OnGive(sender, msg, dist)
    if dist ~= "WHISPER" or not KINDS[msg.k] or type(msg.r) ~= "table" then return end
    if sync:StoreFrom(sender, msg.k, msg.r) then Changed() end
end

-- PLN { p }: the asker reminds the people who haven't answered.
local function OnNudge(sender, msg, dist)
    if dist ~= "GUILD" or not IsId(msg.p) then return end
    local p = Polls:GetPoll(msg.p)
    if not p or not Polls:CanManage(p, sender) or not Polls:IsOpen(p) then return end
    if not Polls:AsksMe(p) or Polls:MyVote(p) then return end
    if not RateLimit("PLNr:" .. msg.p, 120) then return end
    ns:Fire("POLL_NUDGED", p.id, sender)
end

---------------------------------------------------------------------------
-- Retention
---------------------------------------------------------------------------

function Polls:Prune(now)
    local root = Root(false)
    if not root then return end
    now = now or Now()
    -- deleted polls: graves after TOMBSTONE_KEEP, dropped after GRAVE_KEEP (DigestSync.lua)
    local changed = sync:PruneGraves(root, now)
    for id, p in pairs(root.P) do
        if not p.del and (p.cl or 0) < now - CLOSED_KEEP then
            root.P[id] = nil
            changed = true
        end
    end
    for id, v in pairs(root.V) do
        local p = root.P[v.p]
        if not p or p.del then root.V[id] = nil; changed = true end
    end
    local seen = ns.DB:GuildBucket("pollSeen")
    for id in pairs(seen or {}) do
        if not root.P[id] then seen[id] = nil end
    end
    if changed then Changed() end
end

-- The pop-up's memory: a poll pops up once (per character), unless its asker nudges.
function Polls:WasShown(id)
    local seen = ns.DB:GuildBucket("pollSeen")
    return seen and seen[id] and true or false
end

function Polls:MarkShown(id)
    if DemoOn() then return end
    local seen = ns.DB:GuildBucket("pollSeen", true)
    if seen then seen[id] = true end
end

---------------------------------------------------------------------------
-- Demo mode: a few polls of the demo guild (nothing is stored or sent)
---------------------------------------------------------------------------

function Polls:DemoResolve(targets)
    local G = Guild()
    local keys = {}
    for _, k in ipairs(G and G.GetMembers and G:GetMembers() or {}) do keys[#keys + 1] = k end
    local me = Me()
    local out, set = {}, {}
    for _, t in ipairs(targets or {}) do
        local list = t[1] == "p" and { t[2] } or keys
        for _, k in ipairs(list) do
            if not set[k] then set[k] = true; out[#out + 1] = k end
        end
    end
    if me and not set[me] then out[#out + 1] = me end
    tsort(out)
    return out
end

function Polls:BuildDemo()
    local now = Now()
    local G = Guild()
    local me = Me() or "You-Realm"
    local keys = {}
    for _, k in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        if k ~= me then keys[#keys + 1] = k end
    end
    local asker = (G and G.GetGM and G:GetGM()) or keys[1] or me
    if asker == me then asker = keys[1] or me end
    local m = { me }
    for i = 1, min(#keys, 20) do m[#m + 1] = keys[i] end
    tsort(m)
    local function day(off, tm)
        return date("%Y-%m-%d", now + off * DAY) .. (tm and (" " .. tm) or "")
    end
    demo = { P = {}, V = {} }
    local function poll(id, def)
        def.id, def.by, def.rev, def.at, def.m = id, def.by or asker, now - 3600, now - 3600, def.m or m
        def.a = def.a or { { "g" } }
        demo.P[id] = CleanPoll(def)
    end
    poll("pdemo1", { q = "Which nights can you raid SSC next week?", k = "days", cl = now + 3 * DAY, rv = "live", ch = true,
                     o = { day(3, "20:00"), day(5, "20:00"), day(6, "20:00"), day(8, "19:30"), day(9, "19:30") } })
    poll("pdemo2", { q = "Should we start Thursdays 30 minutes earlier?", k = "yn", o = { "Yes", "No" },
                     cl = now + DAY, rv = "vote", ch = true })
    poll("pdemo3", { q = "Which raid should we do next Wednesday?", k = "one", cl = now + 2 * DAY, rv = "vote", ch = true,
                     o = { "Gruul's Lair", "Magtheridon's Lair", "Karazhan", "A night off" } })
    poll("pdemo4", { q = "Loot: allow off-spec rolls on tier tokens?", k = "one", by = me, cl = now + 4 * DAY,
                     rv = "vote", ch = true, o = { "Yes, after main spec", "No, main spec only", "Council decides" } })
    -- answers from the others (spread by their names, the same every time)
    for id, p in pairs(demo.P) do
        for i, k in ipairs(p.m) do
            local h = Util.Adler32(k .. id)
            if k ~= me and h % 5 ~= 0 and not (id == "pdemo1" and i > 14) then
                local c
                if p.k == "days" then
                    c = {}
                    for d = 1, #p.o do c[d] = (h + d * 7) % 5 == 0 and 0 or ((h + d) % 4 == 0 and 2 or 1) end
                else
                    c = { 1 + (h % #p.o) }
                end
                local vid = id .. "/" .. k
                demo.V[vid] = { id = vid, p = id, s = k, by = k, rev = now - 1800, c = c }
            end
        end
    end
    local mine = "pdemo3/" .. me
    demo.V[mine] = { id = mine, p = "pdemo3", s = me, by = me, rev = now - 600, c = { 1 } }
    return demo
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Polls:OnInit()
    sync:Register(OnUpdate, OnGive)
    local Comm = ns.Comm
    if Comm and Comm.Register then Comm:Register("PLN", OnNudge) end
    ns:On("DEMO_TOGGLED", function(on)
        if not on then demo = nil end
        Changed()
    end)
    for _, e in ipairs({ "CONFIG_UPDATED", "ROSTER_UPDATED", "ACCOUNTS_UPDATED" }) do
        ns:On(e, function() Changed() end)
    end
end

function Polls:OnLogin()
    local function Daily()
        Polls:Prune()
        Util.After(DAY / 4, Daily)
    end
    -- (not drawn from math.random: see Events:OnLogin)
    local n = Util.Adler32((Util.PlayerKey() or "?") .. "polls-prune" .. tostring(Now()))
    Util.After(25 + (n % 1000) / 50, Daily)
    -- a poll's closing time passing changes the pages (results shown, no more answers)
    local function Tick()
        local now = Now()
        local st = State()
        for _, p in pairs(st and st.P or {}) do
            if not p.del and p.cl <= now and p.cl > now - 61 then Changed() break end
        end
        Util.After(60, Tick)
    end
    Util.After(60, Tick)
end
