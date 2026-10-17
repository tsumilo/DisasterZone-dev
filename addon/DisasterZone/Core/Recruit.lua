if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Recruit.lua", ...) then return end -- DisasterZone: Core/Recruit.lua
-- Recruitment (1.6): the people the GM and officers talk to, from the first whisper to settling in. Recruiting is
-- personal: a conversation, fit over gear. Nobody outside the guild needs the addon; everything here stays with the
-- recruiters (dev/docs/recruit/PLAN.md).
--
-- Recruiters: the Guild Master, the officers (real rank) and, when the GM's rules say so, the listed raid leaders.
-- Nobody else ever receives a record; a client that stops being a recruiter forgets them.
--
-- Data (SavedVariables db.recruit[guildKey]): p[key] = a person (Clean below), x[key] = { rev, by } a removal.
-- A person: c, sp (class file, spec index), st ("talk" | "joined" | "notnow" | "gone"), w (who is talking with them;
-- nil = unclaimed), src ("whisper" | "guest" | "intro" | "name" | "trade"), ib / it (introduced by, the line), wa
-- (wants: bits 1 raiding, 2 dungeons, 4 levelling, 8 social), ni (nights they can raid, days 1 = Mon .. 7), nt (a
-- short time text), sd (their words), tg (tags), fu = { at, t } (the follow-up: a day and what), n = { { by, at, t } }
-- (notes, newest first), lv / la (level last seen, when), ja / jl / jb / tm (joined at, level then, invited by, team),
-- ck (check-ins done), ms (milestones reached), nn (Not now since), rev, by (last writer), at (added).
--
-- Messages (WHISPER between recruiters only, class "data"; the OfficerNotes model):
--   RC  { k, r = person, v = rev }   one person, sent to the recruiters online on every change
--   RCI { i = { [key] = rev }, r }   what I have: the receiver sends what is newer and, unless r, its own RCI
--   RCX { k, v, by }                 a removal (kept as a tombstone for 60 days)
-- Newer rev wins; the same rev keeps the record that sorts larger (both sides settle on the same one).
local addonName, ns = ...

local Recruit = ns:NewModule("Recruit")
local Util = ns.Util

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat, tinsert = table.sort, table.concat, table.insert

local Now, IsInt = Util.Now, Util.IsInt

local DAY = 86400
local MAX_KEY = 48
local MAX_REV = 2147483647
local FUTURE_SLACK = 60
local MAX_PEOPLE = 300            -- people kept (tombstones apart)
local MAX_INDEX = 400             -- entries taken from one RCI
local MAX_NOTES, MAX_NOTE, MAX_NOTES_TOTAL = 20, 300, 3000
local MAX_INTRO, MAX_SAID, MAX_TIME, MAX_FOLLOW, MAX_TAG, MAX_TAGS = 160, 200, 24, 80, 16, 4
local TOMB_DAYS = 60
local LOGIN_DELAY = 30
local REPLY_LIMIT = 30

Recruit.STATES = { talk = true, joined = true, notnow = true, gone = true }
Recruit.SOURCES = { whisper = true, guest = true, intro = true, name = true, trade = true }
Recruit.WANTS = { raid = 1, dungeons = 2, level = 4, social = 8 }
Recruit.MAX_NOTE, Recruit.MAX_SAID, Recruit.MAX_INTRO = MAX_NOTE, MAX_SAID, MAX_INTRO

local H = {}                      -- the file's helpers (few main-chunk locals)
local indexSent = false
local demo                        -- demo mode's people (memory only)

local function Guild() return ns.Guild end
local function Me() return Util.PlayerKey() end

-- The last guild invite's outcome (iv.r): sent, declined, ignored (no answer), in a guild, offline.
H.INVITE_RESULTS = { sent = true, declined = true, ignored = true, guild = true, offline = true }

function H.WireKey(s)
    if type(s) ~= "string" or s == "" or #s > MAX_KEY or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

-- One line of text: no control characters or escape codes, trimmed, at most n letters (nil when not text).
function H.Text(s, n, lines)
    if type(s) ~= "string" then return nil end
    s = s:gsub("\r", "")
    s = lines and s:gsub("[%z\1-\9\11-\31]", "") or s:gsub("[%z\1-\31]", " ")
    s = Util.Trim((s:gsub("|", ""))) or ""
    if #s > n then s = s:sub(1, n) end
    return s
end

---------------------------------------------------------------------------
-- Who recruits
---------------------------------------------------------------------------

function Recruit:GetRules()
    local G = Guild()
    return G and G.GetRecruitRules and G:GetRecruitRules() or {}
end

-- A recruiter by the real guild roster (never a debug role): the GM, an officer, a listed raid leader when the rules
-- let raid leaders work on recruits.
function Recruit:IsRecruiter(key)
    local G = Guild()
    if type(key) ~= "string" or not (G and G.IsReady and G:IsReady()) then return false end
    if not G:IsInGuild(key, true) then return false end
    if G:IsGM(key) then return true end
    local wk = self:GetRules().wk or {}
    if wk.o ~= false and G:IsOfficer(key, true) then return true end
    if wk.l and G.IsListedRaidLeader and G:IsListedRaidLeader(key) then return true end
    return false
end

-- Do I see Recruitment? Recruiters (and the debug role / demo mode: the page only, never the network).
function Recruit:CanUse()
    if Util.DemoOn() then return true end
    if not IsInGuild() then return false end
    local G = Guild()
    local me = Me()
    if self:IsRecruiter(me) then return true end
    return (G and G.IsReady and G:IsReady() and G:IsOfficer(me)) and true or false     -- (a debug officer role)
end

function H.AmIRealRecruiter() return Recruit:IsRecruiter(Me()) end

function H.OnlineRecruiters()
    local G = Guild()
    local out = {}
    if not (G and G.IsReady and G:IsReady()) or not H.AmIRealRecruiter() then return out end
    for _, key in ipairs(G:GetOnlineMembers()) do
        if not Util.IsMe(key) and Recruit:IsRecruiter(key) then out[#out + 1] = key end
    end
    return out
end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

function H.Store(create)
    if not IsInGuild() then return nil end
    local gk = Util.GuildKey()
    if type(gk) ~= "string" then return nil end
    local G = Guild()
    local me = Me()
    -- (a debug officer role: its own people, kept apart and never sent)
    if not H.AmIRealRecruiter() and G and G.IsReady and G:IsReady() and G:IsOfficer(me) then gk = "debug " .. gk end
    local b = ns.DB:GuildBucket("recruit", create, gk)
    if not b then return nil end
    if create then
        if type(b.p) ~= "table" then b.p = {} end
        if type(b.x) ~= "table" then b.x = {} end
    end
    return b
end

function H.Pretending()
    local b = H.Store(false)
    return not H.AmIRealRecruiter() and not Util.DemoOn() and Recruit:CanUse()
end

---------------------------------------------------------------------------
-- A person, cleaned (from the wire or from saved data): a copy with only valid fields, or nil.
---------------------------------------------------------------------------

function H.Days(list)
    if type(list) ~= "table" then return nil end
    local set, out = {}, {}
    for i = 1, min(#list, 7) do
        local d = list[i]
        if IsInt(d, 1, 7) and not set[d] then set[d] = true; out[#out + 1] = d end
    end
    tsort(out)
    return #out > 0 and out or nil
end

function H.Notes(list)
    if type(list) ~= "table" then return nil end
    local out, total = {}, 0
    for i = 1, min(#list, MAX_NOTES) do
        local e = list[i]
        if type(e) == "table" then
            local by, at, t = H.WireKey(e.by), tonumber(e.at), H.Text(e.t, MAX_NOTE, true)
            if by and IsInt(at, 1, MAX_REV) and t and t ~= "" and total + #t <= MAX_NOTES_TOTAL then
                out[#out + 1] = { by = by, at = at, t = t }
                total = total + #t
            end
        end
    end
    tsort(out, function(a, b) if a.at ~= b.at then return a.at > b.at end return a.t < b.t end)
    return #out > 0 and out or nil
end

function H.Tags(list)
    if type(list) ~= "table" then return nil end
    local out, set = {}, {}
    for i = 1, min(#list, MAX_TAGS) do
        local t = H.Text(list[i], MAX_TAG)
        if t and t ~= "" and not set[t] then set[t] = true; out[#out + 1] = t end
    end
    return #out > 0 and out or nil
end

function H.Spec(c, sp)
    if type(c) ~= "string" or not (ns.SPECS and ns.SPECS[c]) then return nil, nil end
    if IsInt(sp, 1, #ns.SPECS[c]) then return c, sp end
    return c, nil
end

function Recruit:Clean(r)
    if type(r) ~= "table" or not IsInt(r.rev, 1, MAX_REV) then return nil end
    local st = Recruit.STATES[r.st] and r.st or nil
    if not st then return nil end
    local o = { st = st, rev = r.rev, by = H.WireKey(r.by), at = IsInt(r.at, 1, MAX_REV) and r.at or nil }
    o.c, o.sp = H.Spec(r.c, r.sp)
    o.w = r.w ~= nil and H.WireKey(r.w) or nil
    o.src = Recruit.SOURCES[r.src] and r.src or nil
    o.ib = r.ib ~= nil and H.WireKey(r.ib) or nil
    o.it = H.Text(r.it, MAX_INTRO)
    o.wa = IsInt(r.wa, 0, 15) and r.wa or nil
    o.ni = H.Days(r.ni)
    o.nt = H.Text(r.nt, MAX_TIME)
    o.sd = H.Text(r.sd, MAX_SAID)
    o.tg = H.Tags(r.tg)
    if type(r.fu) == "table" and IsInt(r.fu.at, 1, MAX_REV) then
        o.fu = { at = r.fu.at, t = H.Text(r.fu.t, MAX_FOLLOW) or "" }
    end
    o.n = H.Notes(r.n)
    o.lv = IsInt(r.lv, 1, 80) and r.lv or nil
    o.la = IsInt(r.la, 1, MAX_REV) and r.la or nil
    o.ja = IsInt(r.ja, 1, MAX_REV) and r.ja or nil
    o.jl = IsInt(r.jl, 1, 80) and r.jl or nil
    o.jb = r.jb ~= nil and H.WireKey(r.jb) or nil
    o.tm = type(r.tm) == "string" and #r.tm <= 32 and r.tm or nil
    if type(r.ck) == "table" then o.ck = { w = r.ck.w == true or nil, m = r.ck.m == true or nil } end
    if type(r.ms) == "table" then
        local ms = {}
        for _, k in ipairs({ 58, 70, "d", "r" }) do
            if IsInt(r.ms[k], 1, MAX_REV) then ms[k] = r.ms[k] end
        end
        if next(ms) then o.ms = ms end
    end
    o.nn = IsInt(r.nn, 1, MAX_REV) and r.nn or nil
    if type(r.iv) == "table" and IsInt(r.iv.at, 1, MAX_REV) and H.INVITE_RESULTS[r.iv.r] then
        o.iv = { at = r.iv.at, r = r.iv.r, by = H.WireKey(r.iv.by) }
    end
    if o.it == "" then o.it = nil end
    if o.sd == "" then o.sd = nil end
    if o.nt == "" then o.nt = nil end
    return o
end

-- A stable text of a record, to settle a same-rev tie the same way on both sides.
function H.Digest(r)
    local parts = {}
    for _, k in ipairs({ "st", "w", "c", "sp", "src", "ib", "it", "wa", "nt", "sd", "lv", "ja", "jl", "jb", "tm", "nn", "by" }) do
        parts[#parts + 1] = tostring(r[k])
    end
    for _, d in ipairs(r.ni or {}) do parts[#parts + 1] = d end
    for _, t in ipairs(r.tg or {}) do parts[#parts + 1] = t end
    for _, e in ipairs(r.n or {}) do parts[#parts + 1] = e.by .. e.at .. e.t end
    if r.fu then parts[#parts + 1] = r.fu.at .. r.fu.t end
    if r.iv then parts[#parts + 1] = r.iv.at .. r.iv.r end
    return tconcat(parts, "\31")
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

function H.People()
    if Util.DemoOn() then
        demo = demo or Recruit:BuildDemo()
        return demo
    end
    local b = H.Store(false)
    return b and b.p or {}
end

-- A person (a copy, with .key), or nil.
function Recruit:Get(key)
    if not self:CanUse() or type(key) ~= "string" then return nil end
    key = Util.NormalizeName(key)
    local r = H.People()[key]
    local o = self:Clean(r)
    if not o then return nil end
    o.key = key
    return o
end

function Recruit:Has(key) return self:Get(key) ~= nil end

-- Every person (copies), optionally of one state; sorted by the latest change first.
function Recruit:GetPeople(st)
    local out = {}
    if not self:CanUse() then return out end
    for key, r in pairs(H.People()) do
        local o = self:Clean(r)
        if o and (st == nil or o.st == st) then
            o.key = key
            out[#out + 1] = o
        end
    end
    tsort(out, function(a, b) if a.rev ~= b.rev then return a.rev > b.rev end return a.key < b.key end)
    return out
end

function Recruit:Wants(r, what) return r and r.wa and floor(r.wa / Recruit.WANTS[what]) % 2 == 1 or false end

-- The end of today (my clock), for "due" follow-ups.
function H.EndOfToday()
    local t = date("*t", Now())
    t.hour, t.min, t.sec = 23, 59, 59
    return time(t)
end

-- A check-in that is due: "w" (a week) / "m" (a month), or nil.
function Recruit:CheckInDue(r)
    if not (r and r.st == "joined" and r.ja) then return nil end
    local ck = self:GetRules().ck or 1
    local done, now = r.ck or {}, Now()
    if ck == 1 and not done.w and now >= r.ja + 7 * DAY and now < r.ja + 30 * DAY then return "w" end
    if (ck == 1 or ck == 2) and not done.m and now >= r.ja + 30 * DAY and now < r.ja + 60 * DAY then return "m" end
    return nil
end

-- The latest milestone reached in the last week: the key (58, 70, "d", "r") and when, or nil.
function Recruit:RecentMilestone(r)
    local best, at
    for k, t in pairs(r and r.ms or {}) do
        if t >= Now() - 7 * DAY and (not at or t > at) then best, at = k, t end
    end
    return best, at
end

-- Offline long enough to count as quiet (a joined person, by the guild roster's last online), or nil: the days.
function Recruit:QuietDays(r)
    local q = self:GetRules().q or 14
    if q == 0 or not (r and r.st == "joined" and r.la) then return nil end
    local days = floor((Now() - r.la) / DAY)
    return days >= q and days or nil
end

-- Where a person goes in the list: talking = "unclaimed" | "need" (a follow-up due) | "talk"; joined = "check" |
-- "mile" | "quiet" | "settle"; "notnow"; "gone".
function Recruit:Section(r)
    if not r then return nil end
    if r.st == "talk" then
        if not r.w then return "unclaimed" end
        if r.fu and r.fu.at <= H.EndOfToday() then return "need" end
        return "talk"
    elseif r.st == "joined" then
        if self:CheckInDue(r) then return "check" end
        if self:RecentMilestone(r) then return "mile" end
        if self:QuietDays(r) then return "quiet" end
        return "settle"
    end
    return r.st
end

---------------------------------------------------------------------------
-- Writing (recruiters; demo mode on its own copy, never sent)
---------------------------------------------------------------------------

function H.Send(msg, target)
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, "WHISPER", target, "data")) and true or false
end

function H.SendPerson(key, r, target) return H.Send({ t = "RC", k = key, r = r, v = r.rev }, target) end

-- Saves a person (a full record), stamps it and sends it to the recruiters online.
function H.Save(key, r)
    local now = Now()
    if Util.DemoOn() then
        demo = demo or Recruit:BuildDemo()
        r.rev = max(now, (demo[key] and demo[key].rev or 0) + 1)
        r.by = Me()
        demo[key] = r
        ns:Fire("RECRUIT_UPDATED", key)
        return true
    end
    local b = H.Store(true)
    if not b then return false, "your guild is not known yet" end
    local old = b.p[key]
    r.rev = max(now, (old and old.rev or 0) + 1, (b.x[key] and b.x[key].rev or 0) + 1)
    r.by = Me()
    local clean = Recruit:Clean(r)
    if not clean then return false, "not a valid person" end
    b.p[key] = clean
    b.x[key] = nil
    if not H.Pretending() then
        for _, who in ipairs(H.OnlineRecruiters()) do H.SendPerson(key, clean, who) end
    end
    ns:Fire("RECRUIT_UPDATED", key)
    return true
end

function H.Editable(key)
    if not Recruit:CanUse() then return nil, "only the Guild Master and officers work on recruits" end
    if type(key) ~= "string" then return nil, "no name" end
    key = Util.NormalizeName(key)
    local r = H.People()[key]
    if not r then return nil, "not in Recruitment" end
    return key, Util.CopyTable(r)
end

-- Adds someone (opts: c, sp, src, lv, note, ib, it, claim = false to leave them unclaimed). Returns ok, err / key.
function Recruit:Add(name, opts)
    if not self:CanUse() then return false, "only the Guild Master and officers work on recruits" end
    opts = opts or {}
    local key = H.WireKey(name)
    if not key then return false, "not a character name" end
    local G = Guild()
    if G and G.IsInGuild and G:IsInGuild(key, true) and not opts.member then return false, "already in the guild" end
    local people = H.People()
    if people[key] and people[key].st ~= "gone" then return false, "already in Recruitment" end
    local n = 0
    for _ in pairs(people) do n = n + 1 end
    if n >= MAX_PEOPLE then return false, "Recruitment is full: remove someone first" end
    local now = Now()
    local r = { st = "talk", at = now, src = Recruit.SOURCES[opts.src] and opts.src or "name" }
    r.c, r.sp = H.Spec(opts.c, opts.sp)
    if opts.claim ~= false then r.w = Me() end
    r.lv = IsInt(opts.lv, 1, 80) and opts.lv or nil
    r.la = r.lv and now or nil
    if opts.ib then r.ib, r.it = H.WireKey(opts.ib), H.Text(opts.it, MAX_INTRO) end
    if opts.note and H.Text(opts.note, MAX_NOTE, true) ~= "" then
        r.n = { { by = opts.noteBy and H.WireKey(opts.noteBy) or Me(), at = now, t = H.Text(opts.note, MAX_NOTE, true) } }
    end
    local ok, err = H.Save(key, r)
    if not ok then return false, err end
    return true, key
end

-- Changes what we know (fields: c, sp, wants = { raid = true, ... }, nights = { 4, 7 }, time, said, tags,
-- follow = { at, t } | false, lv). Returns ok, err.
function Recruit:Update(key, f)
    local k, r = H.Editable(key)
    if not k then return false, r end
    f = f or {}
    if f.c ~= nil then r.c, r.sp = H.Spec(f.c, f.sp) elseif f.sp ~= nil then r.c, r.sp = H.Spec(r.c, f.sp) end
    if f.wants ~= nil then
        local bits = 0
        for what, bit in pairs(Recruit.WANTS) do if f.wants[what] then bits = bits + bit end end
        r.wa = bits
    end
    if f.nights ~= nil then r.ni = H.Days(f.nights) end
    if f.time ~= nil then r.nt = H.Text(f.time, MAX_TIME) end
    if f.said ~= nil then r.sd = H.Text(f.said, MAX_SAID) end
    if f.tags ~= nil then r.tg = H.Tags(f.tags) end
    if f.follow == false then r.fu = nil
    elseif type(f.follow) == "table" and IsInt(f.follow.at, 1, MAX_REV) then
        r.fu = { at = f.follow.at, t = H.Text(f.follow.t, MAX_FOLLOW) or "" }
    end
    if IsInt(f.lv, 1, 80) then r.lv, r.la = f.lv, Now() end
    return H.Save(k, r)
end

-- A note from me (newest first; the oldest go past MAX_NOTES). Returns ok, err.
function Recruit:AddNote(key, text, by)
    local k, r = H.Editable(key)
    if not k then return false, r end
    text = H.Text(text, MAX_NOTE, true)
    if not text or text == "" then return false, "the note is empty" end
    local list = r.n or {}
    tinsert(list, 1, { by = by and H.WireKey(by) or Me(), at = Now(), t = text })
    r.n = list
    return H.Save(k, r)
end

-- I talk to them (claim), or pass them to another recruiter.
function Recruit:Claim(key) return self:PassTo(key, Me()) end

function Recruit:PassTo(key, to)
    local k, r = H.Editable(key)
    if not k then return false, r end
    to = H.WireKey(to)
    if not to or (not Util.DemoOn() and not self:IsRecruiter(to)) then return false, "they don't work on recruits" end
    r.w = to
    if r.st == "notnow" then r.st, r.nn = "talk", nil end
    return H.Save(k, r)
end

function Recruit:NotNow(key)
    local k, r = H.Editable(key)
    if not k then return false, r end
    r.st, r.nn, r.fu = "notnow", Now(), nil
    return H.Save(k, r)
end

function Recruit:Reopen(key)
    local k, r = H.Editable(key)
    if not k then return false, r end
    r.st, r.nn = "talk", nil
    return H.Save(k, r)
end

-- Joined the guild (the invite flow calls this): level then, who invited, the team they went to.
function Recruit:MarkJoined(key, info)
    local k, r = H.Editable(key)
    if not k then return false, r end
    info = info or {}
    r.st, r.fu, r.nn = "joined", nil, nil
    r.ja = Now()
    r.jl = IsInt(info.lv, 1, 80) and info.lv or r.lv
    r.jb = H.WireKey(info.by) or Me()
    r.tm = type(info.team) == "string" and info.team or r.tm
    return H.Save(k, r)
end

-- Fields the settling-in checks keep (ck, ms, lv, la, st = "gone"): no claim needed.
function Recruit:Note(key, fields)
    local k, r = H.Editable(key)
    if not k then return false, r end
    for f, v in pairs(fields or {}) do r[f] = v end
    return H.Save(k, r)
end

-- Raids > Guests' Recruit mark is the way in for the raid leaders who aren't officers: a guest marked there comes into
-- Recruitment (unclaimed, with the guest book's class and note), once. Someone removed from Recruitment isn't brought
-- back (the tombstone); the mark goes when they're removed.
function H.PullGuestMarks()
    local GB = ns.GuestBook
    if not (GB and GB.GetEntries and Recruit:CanUse()) or Util.DemoOn() or H.Pretending() then return end
    local b = H.Store(true)
    if not b then return end
    local people = H.People()
    local G = Guild()
    for _, e in ipairs(GB:GetEntries()) do
        local key = H.WireKey(e.key)
        if e.recruit and key and not people[key] and not b.x[key] and not (G and G.IsInGuild and G:IsInGuild(key, true)) then
            Recruit:Add(key, { src = "guest", c = e.c, sp = e.sp, note = e.note, noteBy = e.noteBy, claim = false })
        end
    end
end

-- Removes someone (a tombstone travels so nobody brings them back).
function Recruit:Remove(key)
    local k, r = H.Editable(key)
    if not k then return false, r end
    if Util.DemoOn() then
        demo[k] = nil
        ns:Fire("RECRUIT_UPDATED", k)
        return true
    end
    local b = H.Store(true)
    local rev = max(Now(), (r.rev or 0) + 1)
    b.p[k] = nil
    b.x[k] = { rev = rev, by = Me() }
    local GB = ns.GuestBook
    local e = GB and GB.GetNote and GB:GetNote(k)
    if e and e.recruit then GB:SetNote(k, nil, false) end
    if not H.Pretending() then
        for _, who in ipairs(H.OnlineRecruiters()) do H.Send({ t = "RCX", k = k, v = rev, by = Me() }, who) end
    end
    ns:Fire("RECRUIT_UPDATED", k)
    return true
end

---------------------------------------------------------------------------
-- Fit with the teams: their raid nights (core: every one must be among theirs) and an open place for their spec in
-- the team's comp (Core/RaidComp.lua).
---------------------------------------------------------------------------

-- The days (1 = Mon) of a team's nights: core, optional.
function Recruit:TeamDays(team)
    local core, opt = {}, {}
    for _, n in ipairs(team and team.nights or {}) do
        local d = floor((tonumber(n.w) or 0) / 1440) + 1
        if d >= 1 and d <= 7 then
            if n.o then opt[#opt + 1] = d else core[#core + 1] = d end
        end
    end
    tsort(core)
    tsort(opt)
    return core, opt
end

-- { team, ok, nightsOk, part, place, nights = bool (the team has nights) } for one team; nil when the person has no
-- nights.
function Recruit:FitTeam(r, team)
    if not (r and r.ni and team) then return nil end
    local have = {}
    for _, d in ipairs(r.ni) do have[d] = true end
    local core = self:TeamDays(team)
    local hit = 0
    for _, d in ipairs(core) do if have[d] then hit = hit + 1 end end
    local nightsOk = #core > 0 and hit == #core
    local place = false
    local RP = ns.RaidPlan
    if team.demoOpen then
        for _, o in ipairs(team.demoOpen) do
            if o.c == r.c and (r.sp == nil or o.sp == r.sp) then place = true end
        end
    elseif r.c and RP and RP.GetTeamOpenSlots then
        for _, o in ipairs((RP:GetTeamOpenSlots(team))) do
            if o.c == r.c and (r.sp == nil or o.sp == r.sp) then place = true break end
        end
    end
    return { team = team, ok = nightsOk and place, nightsOk = nightsOk, part = hit > 0 and not nightsOk, place = place,
             nights = #core > 0 }
end

-- Every team's fit (teams in name order), and the first that fits fully (or nil).
-- Demo mode, when no team has raid nights yet: two made-up teams, so the fit can be tried.
function H.DemoTeams()
    local function night(d, h, m, o) return { w = (d - 1) * 1440 + h * 60 + m, m = 210, o = o } end
    return {
        { id = "demo-main", name = "Main team", nights = { night(4, 19, 30), night(7, 19, 30, true) },
          demoOpen = { { c = "PALADIN", sp = 1 }, { c = "DRUID", sp = 4 }, { c = "HUNTER", sp = 3 } } },
        { id = "demo-owls", name = "Night Owls", nights = { night(1, 21, 0), night(3, 21, 0) },
          demoOpen = { { c = "PALADIN", sp = 1 }, { c = "WARRIOR", sp = 3 } } },
    }
end

function Recruit:GetTeams()
    local RP = ns.RaidPlan
    local teams = RP and RP.GetTeams and RP:GetTeams() or {}
    if Util.DemoOn() then
        local any = false
        for _, t in ipairs(teams) do if t.nights and #t.nights > 0 then any = true end end
        if not any then return H.DemoTeams() end
    end
    return teams
end

function Recruit:GetTeam(id)
    for _, t in ipairs(self:GetTeams()) do if t.id == id then return t end end
end

function Recruit:Fits(r)
    local out, best = {}, nil
    for _, team in ipairs(self:GetTeams()) do
        local f = self:FitTeam(r, team)
        if f then
            out[#out + 1] = f
            if f.ok and not best then best = f end
        end
    end
    return out, best
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

function H.Index()
    local i = {}
    local b = H.Store(false)
    if not b then return i end
    for key, r in pairs(b.p) do if IsInt(r.rev, 1, MAX_REV) then i[key] = r.rev end end
    for key, x in pairs(b.x) do if IsInt(x.rev, 1, MAX_REV) then i[key] = -x.rev end end
    return i
end

function H.SendIndex(target, isReply) return H.Send({ t = "RCI", i = H.Index(), r = isReply and 1 or nil }, target) end

function H.Trusted(sender, dist)
    return dist == "WHISPER" and H.AmIRealRecruiter() and Recruit:IsRecruiter(sender)
end

function H.OnPerson(sender, msg, dist)
    if not H.Trusted(sender, dist) then return end
    local key = H.WireKey(msg.k)
    if not key or not IsInt(msg.v, 1, Now() + FUTURE_SLACK) or type(msg.r) ~= "table" then return end
    local r = Recruit:Clean(msg.r)
    if not r or r.rev ~= msg.v then return end
    local b = H.Store(true)
    if not b then return end
    local x = b.x[key]
    if x and x.rev >= r.rev then return end
    local old = b.p[key]
    if old then
        if old.rev > r.rev then return end
        if old.rev == r.rev and H.Digest(old) >= H.Digest(r) then return end
    end
    b.p[key] = r
    b.x[key] = nil
    ns:Fire("RECRUIT_UPDATED", key)
end

function H.OnRemove(sender, msg, dist)
    if not H.Trusted(sender, dist) then return end
    local key = H.WireKey(msg.k)
    if not key or not IsInt(msg.v, 1, Now() + FUTURE_SLACK) then return end
    local b = H.Store(true)
    if not b then return end
    local old, x = b.p[key], b.x[key]
    if (old and old.rev >= msg.v) or (x and x.rev >= msg.v) then return end
    b.p[key] = nil
    b.x[key] = { rev = msg.v, by = H.WireKey(msg.by) or sender }
    ns:Fire("RECRUIT_UPDATED", key)
end

function H.OnIndex(sender, msg, dist)
    if not H.Trusted(sender, dist) or type(msg.i) ~= "table" then return end
    local Comm = ns.Comm
    if Comm and Comm.RateLimit and not Comm:RateLimit("rci:" .. sender, REPLY_LIMIT) then return end
    local b = H.Store(true)
    if not b then return end
    local theirs, n, theyHaveNewer = {}, 0, false
    for key, rev in pairs(msg.i) do
        n = n + 1
        if n > MAX_INDEX then break end
        if type(key) == "string" and IsInt(rev, -MAX_REV, MAX_REV) and rev ~= 0 then
            theirs[key] = rev
            local mine = b.p[key] and b.p[key].rev or (b.x[key] and b.x[key].rev) or 0
            if math.abs(rev) > mine then theyHaveNewer = true end
        end
    end
    for key, r in pairs(b.p) do
        if math.abs(theirs[key] or 0) < r.rev then H.SendPerson(key, r, sender) end
    end
    for key, x in pairs(b.x) do
        if math.abs(theirs[key] or 0) < x.rev then H.Send({ t = "RCX", k = key, v = x.rev, by = x.by }, sender) end
    end
    if theyHaveNewer and msg.r ~= 1 then H.SendIndex(sender, true) end
end

-- Once a session, when the roster shows me as a recruiter: compare with the recruiters online. A recruiter coming
-- online does the same towards me.
function H.Share()
    if indexSent or not H.AmIRealRecruiter() then return end
    indexSent = true
    for _, who in ipairs(H.OnlineRecruiters()) do H.SendIndex(who) end
end

-- No longer a recruiter (rank lost, the GM's rules changed): the people go from this client (never sent anywhere).
function H.Purge()
    local G = Guild()
    if not (G and G.IsReady and G:IsReady()) or not IsInGuild() or Util.DemoOn() then return end
    if H.AmIRealRecruiter() then return end
    local gk = Util.GuildKey()
    local root = ns.db and ns.db.recruit
    if type(gk) == "string" and type(root) == "table" and root[gk] then
        root[gk] = nil
        indexSent = false
        ns:Fire("RECRUIT_UPDATED")
    end
end

-- Tombstones older than TOMB_DAYS go.
function H.Tidy()
    local b = H.Store(false)
    if not b or type(b.x) ~= "table" then return end
    local cut = Now() - TOMB_DAYS * DAY
    for key, x in pairs(b.x) do
        if type(x) ~= "table" or not IsInt(x.rev, 1, MAX_REV) or x.rev < cut then b.x[key] = nil end
    end
end

---------------------------------------------------------------------------
-- The friends list: the only way the game tells me when someone outside the guild comes online, their level and
-- zone. The people I talk with go on my friends list (note "DZ recruit"); only those the addon added come off it,
-- when they join, go to Not now, are passed on or removed. Per character; Settings: "Add people to my friends list".
---------------------------------------------------------------------------

H.live = {}                       -- [key] = { online, lv, zone } from my friends list
local FRIEND_NOTE = "DZ recruit"
local FRIENDS_MAX = 100

function H.Mine()
    local db = ns.db
    if type(db) ~= "table" then return {} end
    -- (demo mode saves nothing: a list in memory for it)
    if ns.Util.DemoOn() then
        H.demoMine = H.demoMine or { added = {}, queue = {} }
        return H.demoMine
    end
    if type(db.recruitMine) ~= "table" then db.recruitMine = {} end
    local m = db.recruitMine
    if type(m.added) ~= "table" then m.added = {} end
    if type(m.queue) ~= "table" then m.queue = {} end
    return m
end

function H.GameName(key)
    return (Ambiguate and Ambiguate(key, "none")) or Util.ShortName(key) or key
end

-- My list to read: the saved one, or an empty one that is never written (H.Mine creates the saved one when something is
-- stored, so looking never leaves an empty table in saved data).
local NONE = { added = {}, queue = {} }
function H.Peek()
    if Util.DemoOn() then return H.demoMine or NONE end
    local m = type(ns.db) == "table" and ns.db.recruitMine
    if type(m) == "table" and type(m.added) == "table" and type(m.queue) == "table" then return m end
    return NONE
end

function H.FriendsOn() return H.Peek().friends ~= false end

-- Settings: "Add people to my friends list" (this character only).
function Recruit:FriendsOn() return H.FriendsOn() end
function Recruit:SetFriendsOn(on)
    H.Mine().friends = on and true or false
    H.Reconcile()
    ns:Fire("RECRUIT_UPDATED")
end

-- What the friends list says about someone: { online, lv, zone } or nil. Demo mode: made-up states.
function Recruit:Live(key)
    if type(key) ~= "string" then return nil end
    if Util.DemoOn() then
        local n = key:match("^([^%-]+)")
        local on = { Kaelthorn = true, Aurelith = true, Nortok = true, Bramble = true }
        local zones = { Kaelthorn = "Shattrath City", Aurelith = "Hellfire Peninsula", Nortok = "Shattrath City",
                        Bramble = "Terokkar Forest" }
        if on[n] then return { online = true, zone = zones[n] } end
        return { online = false }
    end
    return H.live[Util.NormalizeName(key)]
end

function H.ScanFriends()
    local FL = C_FriendList
    if not (FL and FL.GetNumFriends and FL.GetFriendInfoByIndex) then return end
    local seen, changed, cameOnline = {}, false, {}
    for i = 1, FL.GetNumFriends() or 0 do
        local info = FL.GetFriendInfoByIndex(i)
        -- (a friend whose name hasn't loaded yet comes back as "": skip it until it has one)
        local key = type(info) == "table" and Util.NormalizeName(info.name)
        if key then
            local on = info.connected and true or false
            local old = H.live[key]
            local lv = tonumber(info.level)
            if lv == 0 then lv = nil end
            if not old or old.online ~= on or old.lv ~= lv or old.zone ~= info.area then changed = true end
            if on and old and not old.online then cameOnline[#cameOnline + 1] = key end
            H.live[key] = { online = on, lv = lv, zone = on and info.area or nil }
            seen[key] = true
        end
    end
    for key in pairs(H.live) do
        if not seen[key] then H.live[key], changed = nil, true end
    end
    -- what I learn about the people I talk with: their level, when I last saw them online
    local me = Me()
    for key, l in pairs(H.live) do
        local r = H.People()[key]
        if r and l.online and r.w == me and r.st == "talk" and (r.lv ~= l.lv or (r.la or 0) < Now() - DAY / 2) then
            Recruit:Note(key, { lv = l.lv or r.lv, la = Now() })
        end
    end
    for _, key in ipairs(cameOnline) do
        ns:Fire("RECRUIT_ONLINE", key)
        if H.Peek().queue[key] then ns:Fire("RECRUIT_INVITE_READY", key) end
    end
    if changed then ns:Fire("RECRUIT_LIVE") end
end

function H.IsFriend(key)
    local FL = C_FriendList
    return FL and FL.GetFriendInfo and FL.GetFriendInfo(H.GameName(key)) ~= nil or false
end

-- The people I talk with on my friends list; the ones the addon added and I no longer talk with off it.
function H.Reconcile()
    local FL = C_FriendList
    if Util.DemoOn() or not H.AmIRealRecruiter() or not (FL and FL.AddFriend) then return end
    local me = Me()
    local want = {}
    if H.FriendsOn() then
        for key, r in pairs(H.People()) do
            if r.st == "talk" and r.w == me then want[key] = true end
        end
    end
    if next(want) == nil and next(H.Peek().added) == nil then return end
    local mine = H.Mine()
    for key in pairs(mine.added) do
        if not want[key] then
            if H.IsFriend(key) then FL.RemoveFriend(H.GameName(key)) end
            mine.added[key] = nil
        end
    end
    local n = FL.GetNumFriends and FL.GetNumFriends() or 0
    for key in pairs(want) do
        if not mine.added[key] and not H.IsFriend(key) then
            if n >= FRIENDS_MAX then
                mine.full = true
                break
            end
            FL.AddFriend(H.GameName(key), FRIEND_NOTE)
            mine.added[key], n = true, n + 1
        end
    end
end

function Recruit:IsFriendsListFull() return H.Peek().full == true end

---------------------------------------------------------------------------
-- The guild invite. Invite (from a click: the game wants a hardware event) sends GuildInvite and keeps what to do
-- when they join; the game's answers come as system messages. Offline: kept until they come online (a reminder
-- with Invite then). When they join: Joined on their card, the welcome line in guild chat, the officer note, the
-- team's bench, a word to that team's raid leaders, and they come off my friends list.
---------------------------------------------------------------------------

H.pending = {}                    -- [key] = { at, opts }
local INVITE_WAIT = 120

-- A Lua pattern from a GlobalStrings format with one %s (the name).
function H.Pattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)")
    return "^" .. p .. "$"
end

function H.Fill(tmpl, key, by)
    local G = Guild()
    local s = tostring(tmpl or "")
    s = s:gsub("{name}", Util.ShortName(key) or key):gsub("{date}", date("%d %b", Now())):gsub("{by}", Util.ShortName(by or Me()) or "")
    s = s:gsub("{guild}", (GetGuildInfo and GetGuildInfo("player")) or "the guild")
    return s
end

-- The welcome line and the officer note the rules suggest for someone (a copy the invite dialog may change).
function Recruit:InviteDefaults(key)
    local rules = self:GetRules()
    local r = self:Get(key) or {}
    local _, best = self:Fits(r)
    return { welcome = H.Fill(rules.wl, key), note = H.Fill(rules.on, key, r.w or Me()), team = best and best.team.id or nil,
             teamName = best and best.team.name or nil }
end

-- Sends the guild invite (opts: welcome text or "", note, team id). Returns ok, err | "queued".
function Recruit:Invite(key, opts)
    if not self:CanUse() then return false, "only the Guild Master and officers work on recruits" end
    local r = self:Get(key)
    if not r then return false, "not in Recruitment" end
    opts = opts or self:InviteDefaults(r.key)
    if Util.DemoOn() then
        ns:Print("Demo: would invite %s to the guild.", H.GameName(r.key))
        return true
    end
    if CanGuildInvite and not CanGuildInvite() then return false, "your guild rank can't invite" end
    local live = self:Live(r.key)
    if live and live.online == false then
        H.Mine().queue[r.key] = opts
        self:Note(r.key, { iv = { at = Now(), r = "offline", by = Me() } })
        return true, "queued"
    end
    H.pending[r.key] = { at = Now(), opts = opts }
    H.Mine().queue[r.key] = nil
    if GuildInvite then GuildInvite(H.GameName(r.key)) end
    Util.After(INVITE_WAIT, function()
        local p = H.pending[r.key]
        if p and p.at <= Now() - INVITE_WAIT + 1 then
            H.pending[r.key] = nil
            Recruit:Note(r.key, { iv = { at = Now(), r = "ignored", by = Me() } })
        end
    end)
    return true
end

function Recruit:InviteQueued(key) return H.Peek().queue[key] ~= nil end
function Recruit:CancelQueued(key) H.Mine().queue[key] = nil end
function Recruit:QueuedOpts(key) return H.Peek().queue[key] end

function H.KeyOf(name)
    if type(name) ~= "string" or name == "" then return nil end
    name = name:gsub("|H[^|]*|h", ""):gsub("|h", ""):gsub("[%[%]\"]", "")
    return Util.NormalizeName(name)
end

-- After they joined: the officer note on the roster (the game's, when my rank may write it; else DisasterZone's own).
function H.WriteNote(key, note, tries)
    note = tostring(note or "")
    if note == "" then return end
    local found
    for i = 1, (GetNumGuildMembers and GetNumGuildMembers()) or 0 do
        local name = GetGuildRosterInfo(i)
        if name and Util.NormalizeName(name) == key then found = i break end
    end
    if not found then
        if (tries or 0) < 5 then Util.After(3, function() H.WriteNote(key, note, (tries or 0) + 1) end) end
        return
    end
    if CanEditOfficerNote and CanEditOfficerNote() and GuildRosterSetOfficerNote then
        local short = note
        if #short > 31 then                                    -- (the game keeps 31 bytes)
            short = short:sub(1, 31)
            -- (cut inside a letter like the "ä" of Släy: drop its first half too)
            local nb = note:byte(32)
            if nb >= 128 and nb < 192 then short = short:gsub("[\192-\255][\128-\191]*$", "") end
        end
        GuildRosterSetOfficerNote(found, short)
    elseif ns.OfficerNotes and ns.OfficerNotes.Set then
        ns.OfficerNotes:Set(key, note)
    end
end

function H.OnJoined(key)
    local p = H.pending[key]
    H.pending[key] = nil
    local r = H.People()[key]
    if not (p and r) then return end
    local opts = p.opts or {}
    local live = Recruit:Live(key) or {}
    Recruit:MarkJoined(key, { lv = live.lv or r.lv, by = Me(), team = opts.team })
    if type(opts.welcome) == "string" and opts.welcome ~= "" and SendChatMessage then
        SendChatMessage(opts.welcome:sub(1, 255), "GUILD")
    end
    Util.After(2, function() H.WriteNote(key, opts.note) end)
    if opts.team then H.ToBench(key, opts.team) end
    ns:Fire("RECRUIT_JOINED", key)
end

-- Onto a team's bench (a team member outside its lineups' groups) and a word to the raid leaders.
function H.ToBench(key, teamId)
    local RP = ns.RaidPlan
    local team = RP and RP.GetTeam and RP:GetTeam(teamId)
    if not team then return end
    if RP.CanManageTeams and RP:CanManageTeams() then
        local members = {}
        for _, m in ipairs(team.members or {}) do members[#members + 1] = m end
        local there = false
        for _, m in ipairs(members) do if m == key then there = true end end
        if not there then
            members[#members + 1] = key
            RP:SaveTeam(team.id, team.name, members, {})
        end
    end
    H.TellRaidLeaders(key, team)
end

-- The guild's raid leaders and the GM (online, not me): "<name> joined, on <team>'s bench".
function H.TellRaidLeaders(key, team)
    local G = Guild()
    if not (G and G.GetRaidLeaders) then return end
    local to = {}
    for _, k in ipairs(G:GetRaidLeaders() or {}) do to[k] = true end
    local gm = G.GetGM and G:GetGM()
    if gm then to[gm] = true end
    local online = {}
    for _, k in ipairs(G:GetOnlineMembers() or {}) do online[k] = true end
    local r = H.People()[key] or {}
    for k in pairs(to) do
        if online[k] and not Util.IsMe(k) then
            H.Send({ t = "RCR", k = key, tm = team.id, c = r.c, sp = r.sp, why = "joined" }, k)
        end
    end
end

-- A word for a raid leader (from a recruiter only): kept for the notification center (UI/NotifySources.lua).
function H.OnTeamNews(sender, msg, dist)
    if dist ~= "WHISPER" or not Recruit:IsRecruiter(sender) then return end
    local key = H.WireKey(msg.k)
    if not key or type(msg.tm) ~= "string" or #msg.tm > 32 then return end
    local news = ns.db and ns.DB:GuildBucket("recruitNews", true)
    if not news then return end
    local why = (msg.why == "joined" or msg.why == "70") and msg.why or "joined"
    news[key .. ":" .. why] = { k = key, tm = msg.tm, c = H.Spec(msg.c, msg.sp), sp = select(2, H.Spec(msg.c, msg.sp)),
                                why = why, by = sender, at = Now() }
    ns:Fire("RECRUIT_TEAM_NEWS", key)
end

function Recruit:GetTeamNews()
    local out = {}
    local news = ns.db and ns.DB:GuildBucket("recruitNews", false)
    for id, n in pairs(news or {}) do
        if type(n) == "table" and (n.at or 0) > Now() - 14 * DAY then
            out[#out + 1] = { id = id, key = n.k, team = n.tm, c = n.c, sp = n.sp, why = n.why, by = n.by, at = n.at }
        end
    end
    tsort(out, function(a, b) return a.at > b.at end)
    return out
end

function Recruit:DismissTeamNews(id)
    local news = ns.db and ns.DB:GuildBucket("recruitNews", false)
    if news then news[id] = nil end
    ns:Fire("RECRUIT_TEAM_NEWS")
end

function H.OnSystem(text)
    if type(text) ~= "string" then return end
    local function match(fmt)
        local p = H.Pattern(fmt)
        return p and text:match(p)
    end
    local name = match(_G.ERR_GUILD_JOIN_S)
    if name then
        local key = H.KeyOf(name)
        if key and H.pending[key] then H.OnJoined(key) end
        if key then ns:Fire("RECRUIT_GUILD_JOIN", key) end
        return
    end
    for _, x in ipairs({ { _G.ERR_GUILD_DECLINE_S, "declined" }, { _G.ERR_ALREADY_IN_GUILD_S, "guild" },
                         { _G.ERR_ALREADY_INVITED_TO_GUILD_S, "guild" }, { _G.ERR_GUILD_PLAYER_NOT_FOUND_S, "offline" } }) do
        name = match(x[1])
        if name then
            local key = H.KeyOf(name)
            local p = key and H.pending[key]
            if p then
                H.pending[key] = nil
                if x[2] == "offline" then H.Mine().queue[key] = p.opts end
                Recruit:Note(key, { iv = { at = Now(), r = x[2], by = Me() } })
            end
            return
        end
    end
end

---------------------------------------------------------------------------
-- Settling in: what the guild roster says about the people who joined. One client keeps each person up to date:
-- whoever invited them (else the Guild Master, when the inviter isn't in the guild any more). Their level (58 and 70
-- are milestones; a raider at 70 is a word for the raid leaders), when they were last online (gone quiet), their
-- first raid with the guild (attendance), and leaving the guild ("gone").
---------------------------------------------------------------------------

-- Last online from the roster: seconds ago (0 while online), or nil when they're not in it.
function H.RosterSeen(key)
    local G = Guild()
    local m = G and G.GetMember and G:GetMember(key, true)
    if not m then return nil end
    if m.online then return 0, m.level end
    for i = 1, (GetNumGuildMembers and GetNumGuildMembers()) or 0 do
        local name = GetGuildRosterInfo(i)
        if name and Util.NormalizeName(name) == key and GetGuildRosterLastOnline then
            local y, mo, d, h = GetGuildRosterLastOnline(i)
            local s = (((tonumber(y) or 0) * 365 + (tonumber(mo) or 0) * 30 + (tonumber(d) or 0)) * 24 + (tonumber(h) or 0)) * 3600
            return s, m.level
        end
    end
    return nil, m.level
end

function H.KeeperOf(r)
    local G = Guild()
    if r.jb and G and G:IsInGuild(r.jb, true) then return r.jb end
    return G and G.GetGM and G:GetGM() or nil
end

function H.CheckSettling()
    local G = Guild()
    if Util.DemoOn() or not H.AmIRealRecruiter() or not (G and G.IsReady and G:IsReady()) then return end
    local me, now = Me(), Now()
    local rules = Recruit:GetRules()
    local ms = rules.ms or {}
    for key, rec in pairs(H.People()) do
        if rec.st == "joined" and H.KeeperOf(rec) == me then
            local r = Recruit:Clean(rec)
            local fields, any = {}, false
            local function set(f, v) fields[f], any = v, true end
            if not G:IsInGuild(key, true) then
                set("st", "gone")
            else
                local ago, lv = H.RosterSeen(key)
                local la = ago and (now - ago) or nil
                if la and math.abs((r.la or 0) - la) > DAY / 2 then set("la", floor(la)) end
                if lv and lv ~= r.lv then set("lv", lv) end
                local reached = Util.CopyTable(r.ms or {})
                local changed = false
                for _, at in ipairs({ 58, 70 }) do
                    if ms[at] ~= false and lv and lv >= at and not reached[at] and (r.jl or 0) < at then
                        reached[at], changed = now, true
                        if at == 70 and rules.rl ~= false and Recruit:Wants(r, "raid") then H.TellAt70(key, r) end
                    end
                end
                local Att = ns.Attendance
                if ms.r ~= false and not reached.r and Att and Att.GetHistory then
                    local ok, hist = pcall(Att.GetHistory, Att, key)
                    -- (a night they were expected at but never came, or only clashed with, is no first raid)
                    local came = false
                    for _, h in ipairs(ok and type(hist) == "table" and hist or {}) do
                        local x = type(h) == "table" and h.r
                        if type(x) == "table" and ((x.kind and not x.noShow) or (tonumber(x.help) or 0) > 0) then
                            came = true
                            break
                        end
                    end
                    if came then reached.r, changed = now, true end
                end
                if changed then set("ms", reached) end
            end
            if any then Recruit:Note(key, fields) end
        end
    end
end

-- A raider hit 70: a word for the raid leaders, with the team that has a place for them (if any).
function H.TellAt70(key, r)
    local _, best = Recruit:Fits(r)
    local team = best and best.team or { id = r.tm or "" }
    local G = Guild()
    if not G then return end
    local to = {}
    for _, k in ipairs(G:GetRaidLeaders() or {}) do to[k] = true end
    local gm = G.GetGM and G:GetGM()
    if gm then to[gm] = true end
    for _, k in ipairs(G:GetOnlineMembers() or {}) do
        if to[k] and not Util.IsMe(k) then
            H.Send({ t = "RCR", k = key, tm = team.id, c = r.c, sp = r.sp, why = "70" }, k)
        end
    end
end

---------------------------------------------------------------------------
-- Demo mode: made-up people, in memory only, never sent
---------------------------------------------------------------------------

function Recruit:BuildDemo()
    local now = Now()
    local G = Guild()
    local members = {}
    for _, k in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        if not Util.IsMe(k) then members[#members + 1] = k end
    end
    local me = Me() or "You-Realm"
    local function m(i) return members[i] or me end
    local realm = (me:match("%-(.+)$")) or "Realm"
    local function key(n) return n .. "-" .. realm end
    local d = function(days) return now - days * DAY end
    local function note(by, days, t) return { by = by, at = floor(d(days)), t = t } end
    local team1 = (Recruit:GetTeams()[1] or {}).id
    local p = {}
    p[key("Kaelthorn")] = { st = "talk", c = "PALADIN", sp = 1, w = m(2), src = "trade", wa = 9, ni = { 4, 7 },
        nt = "from 19:00", sd = "SSC 4/6 and TK 1/4 before my guild broke up. Want a steady group that doesn't take itself too seriously.",
        tg = { "Chill" }, fu = { at = floor(now + 0.5 * DAY), t = "bring him to SSC as a guest" }, lv = 70, la = now, at = floor(d(2)),
        n = { note(m(2), 1, "Lovely chat. Calm, explains his healing well, wants a relaxed SSC group. Thursdays and Sundays both fine.") } }
    p[key("Aurelith")] = { st = "talk", c = "PALADIN", sp = 1, w = me, src = "whisper", wa = 14,
        sd = "Not thinking about raids yet. Would love to see Karazhan one day.", tg = { "New to WoW", "Chill" },
        fu = { at = floor(now + 2 * DAY), t = "she wants to try a dungeon with us first" }, lv = 13, la = now, at = floor(d(4)),
        n = { note(m(1), 1, "Took her through Ramparts with three guildies. Asked lots of good questions."),
              note(me, 3, "Started a month ago with her partner. Loves questing, a bit nervous about dungeons.") } }
    p[key("Darkstalkerr")] = { st = "talk", c = "HUNTER", sp = 3, w = m(1), src = "guest", wa = 9, ni = { 4, 5, 6 },
        nt = "late, from 21:00", sd = "Works some Sundays. Thursdays always free.", tg = { "Chill" },
        fu = { at = floor(now), t = "after Thursday's raid" }, lv = 70, la = d(2), at = floor(d(21)),
        n = { note(m(1), 5, "Great guy in voice, plays late, wants a home guild after his old one stopped.") } }
    p[key("Thalric")] = { st = "talk", c = "WARRIOR", sp = 3, src = "intro", ib = m(3), wa = 12, lv = 34, la = d(2), at = floor(d(2)),
        it = "My cousin, played vanilla, coming back after 15 years. Very chill, wants to level with us.",
        tg = { "Returning", "Has friends here" } }
    p[key("Nortok")] = { st = "joined", c = "SHAMAN", sp = 3, src = "whisper", wa = 1, ni = { 4, 7 }, lv = 70, la = now,
        ja = floor(d(15)), jl = 52, jb = m(2), tm = team1, tg = { "Returning" }, at = floor(d(24)), ms = { [58] = floor(d(12)), [70] = floor(d(1)), r = floor(d(4)) },
        ck = { w = true }, n = { note(m(2), 22, "Met him in a Ramparts pug, healed it like a champ at 52. Came back after 10 years away.") } }
    p[key("Bramble")] = { st = "joined", c = "DRUID", sp = 4, src = "whisper", wa = 10, lv = 48, la = now,
        ja = floor(d(7)), jl = 41, jb = me, tg = { "Returning", "Social" }, at = floor(d(10)),
        n = { note(me, 9, "Came back after Wrath. Loves healing, wants to learn TBC dungeons.") } }
    p[key("Fennick")] = { st = "joined", c = "ROGUE", sp = 2, src = "name", wa = 4, lv = 61, la = d(16), ja = floor(d(25)),
        jl = 55, jb = m(1), ck = { w = true }, at = floor(d(28)) }
    p[key("Stabbystab")] = { st = "notnow", c = "ROGUE", sp = 2, src = "trade", wa = 1, lv = 70, la = d(13), nn = floor(d(13)),
        n = { note(m(1), 13, "Only wants loot, not the group. Maybe later.") } }
    for _, r in pairs(p) do
        r.rev, r.by, r.at = floor(now), me, r.at or floor(d(20))
    end
    return p
end

function Recruit:ResetDemo() demo = nil end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Recruit:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("RC", H.OnPerson)
        Comm:Register("RCI", H.OnIndex)
        Comm:Register("RCX", H.OnRemove)
        Comm:Register("RCR", H.OnTeamNews)
    end
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("FRIENDLIST_UPDATE")
    ev:RegisterEvent("CHAT_MSG_SYSTEM")
    ev:SetScript("OnEvent", function(_, event, text)
        if event == "CHAT_MSG_SYSTEM" then H.OnSystem(text)
        else Util.Debounce("recruit-friends", 0.5, H.ScanFriends) end
    end)
    ns:On("RECRUIT_UPDATED", function() Util.Debounce("recruit-reconcile", 3, H.Reconcile) end)
    ns:On("DEMO_TOGGLED", function()
        demo = nil
        ns:Fire("RECRUIT_UPDATED")
    end)
    ns:On("CONFIG_UPDATED", function() ns:Fire("RECRUIT_UPDATED") end)
    ns:On("RECRUIT_RULES_CHANGED", function() Util.Debounce("recruit-purge", 2, H.Purge) end)
end

function Recruit:OnLogin()
    Util.After(LOGIN_DELAY, function()
        H.Tidy()
        H.Purge()
        H.Share()
        H.ScanFriends()
        H.Reconcile()
        H.PullGuestMarks()
    end)
    ns:On("GUESTBOOK_CHANGED", function() Util.Debounce("recruit-guests", 2, H.PullGuestMarks) end)
    ns:On("ROSTER_UPDATED", function()
        Util.Debounce("recruit-roster", 5, function()
            H.Purge()
            if not indexSent then H.Share() end
            H.CheckSettling()
        end)
    end)
end

-- (tests)
Recruit._H = H
function Recruit:ShareNow() indexSent = false; H.Share() end
