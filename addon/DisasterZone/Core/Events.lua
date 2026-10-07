if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Events.lua", ...) then return end -- DisasterZone: the guild's events (the Events tab's data).
-- Everything about events that is stored and synced guild-wide (the live run itself: Core/EventLive.lua):
--   D  the library: events members built (Core/EventBlocks.lua's defs). Only their creator edits one; the creator or
--      the GM / an officer / the guild council removes it. A copy is a new event with its own creator.
--   K  reviews: the GM, an officer or the guild council marks an event ranked (or sends it back) for one revision of
--      it; an edit makes a new revision, which is not ranked until reviewed again. They may also take an event out
--      of the waiting list without deciding (x), or clear a decision from the decided list (hide; it stays in force).
--   O  events on the calendar: an event (a copy of its def as it was) at a time, hosted by who put it there; the
--      host or the GM / an officer / the guild council cancels or removes it.
--   J  sign-ups: one per member and calendar event, written by the member.
--   R  results: what a finished event decided (placings, badges, season points, moments), written by its host;
--      the GM / an officer / the guild council removes one.
--   C  the season (name, first and last day): the GM or an officer.
--   T  titles: the title each member shows (one of the titles their badges gave them).
-- Badges and season points count only from ranked events. Sync works like the strategy library (Core/Strategy.lua):
-- the guild HELLO carries a digest hash (ed); a member whose hash differs gets a digest (EVD) from one other member and
-- asks for what it lacks (EVW -> EVG). An edit goes to the guild at once (EVU).
local addonName, ns = ...

local Events = ns:NewModule("Events")
local Util = ns.Util

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local tinsert, tremove, tsort, tconcat = table.insert, table.remove, table.sort, table.concat
local floor, max, min = math.floor, math.max, math.min
local strformat, strsub = string.format, string.sub

local DAY = 86400
local KINDS = { D = true, K = true, O = true, J = true, R = true, C = true, T = true }
local TOMBSTONE_KEEP = 30 * DAY
local OCC_KEEP = 60 * DAY          -- calendar events are kept this long after their day
local SIGNUP_KEEP = 7 * DAY        -- and their sign-ups this long after the start (the run took them then)
local RESULT_KEEP = 400 * DAY
local MAX_DEFS = 200
local MAX_OWN = 30
local MAX_OCC = 120
local MAX_DIGEST_ITEMS = 1200
local MAX_ID_LEN = 40
local MAX_KEY_LEN = 48
local MAX_ITEM_LEN = MAX_ID_LEN + MAX_KEY_LEN + 3   -- a digest item: "J:" .. occId .. "/" .. key
local MAX_NAME = 40
local MAX_TEXT = 200
local MAX_PIECES = 600               -- in one event (every script, every smart block's own)
local MAX_SCRIPTS = 80
local MAX_STAGES = 8
local MAX_DEPTH = 40
local ROUND_WINDOW = 20
local DELAY_REVIEWER = { 0.5, 2.5 }
local DELAY_MEMBER = { 3, 8 }
local SIZE_HEADROOM = 0.1
local RESULT_SCORES = 8              -- a result keeps the tables of this many scores ...
local RESULT_TAGS = 8                -- ... and this many tags,
local RESULT_KEYS = 40               -- ... of this many players each (a Sign-up takes 40 at most)

local roundSeen, answeredAt = {}, -1000
local idCounter = 0
local demo                          -- demo mode's state (Events:BuildDemo)
local KeepSnapshot                  -- (below: the def a reviewer ranked, for the differences later)

local function Now() return (GetServerTime and GetServerTime()) or time() end
local function Guild() return ns.Guild end
local function B() return ns.EventBlocks end
local function Copy(v) return ns.EventBlocks.Copy(v) end
local function DemoOn() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() or false end

local function GuildKey()
    local G = Guild()
    return G and G.GetGuildKey and G:GetGuildKey() or nil
end

local function WireKey(s)
    if type(s) ~= "string" or s == "" or #s > MAX_KEY_LEN or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

local function IsId(s)
    return type(s) == "string" and #s > 0 and #s <= MAX_ID_LEN and s:find("^[%w%-%/_]+$") ~= nil
end

-- A record's id: an id, or (sign-ups, titles) one holding a member's key, which may hold any letter (accented ones)
-- and be long.
local function IsRecordId(kind, s)
    if kind == "J" then
        local occ = type(s) == "string" and #s <= MAX_ITEM_LEN - 2 and s:match("^(.+)/[^/]+$")
        return occ and IsId(occ) or false
    elseif kind == "T" then
        return WireKey(s) ~= nil
    end
    return IsId(s)
end

local function Me() return Util.PlayerKey() end

local function Send(msg, dist, target, class)
    if DemoOn() then return false end
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, class)) and true or false
end

local function RateLimit(key, seconds)
    local Comm = ns.Comm
    if not (Comm and Comm.RateLimit) then return true end
    return Comm:RateLimit(key, seconds)
end

local function Changed()
    Util.Debounce("events-changed", 0.15, function() ns:Fire("EVENTS_UPDATED") end)
end

local function Root(create)
    local db = ns.db
    local g = GuildKey()
    if not db or not g then return nil end
    if type(db.events) ~= "table" then
        if not create then return nil end
        db.events = {}
    end
    local r = db.events[g]
    if type(r) ~= "table" then
        if not create then return nil end
        r = {}
        db.events[g] = r
    end
    for k in pairs(KINDS) do
        if type(r[k]) ~= "table" then r[k] = {} end
    end
    return r
end

-- What the UI reads: the saved root, or demo mode's own.
local function State()
    if DemoOn() then
        if not demo then Events:BuildDemo() end
        return demo
    end
    return Root(false)
end

local function NextRev(cur)
    local prev = type(cur) == "table" and tonumber(cur.rev) or 0
    return max(Now(), prev + 1)
end

local function NewId(prefix)
    idCounter = idCounter + 1
    local now = Now()
    return (prefix or "") .. strformat("%x", now) .. Util.Hash({ Me() or "", now, idCounter, GetTime() }):sub(1, 4)
end

---------------------------------------------------------------------------
-- Roles
---------------------------------------------------------------------------

-- The GM and the officers: they set the season.
function Events:CanModerate(key)
    local G = Guild()
    if type(key) ~= "string" or not G then return false end
    return (G.IsGM and G:IsGM(key)) or (G.IsOfficer and G:IsOfficer(key, not Util.IsMe(key))) or false
end

-- The GM, the officers and the guild council review events (ranked or sent back).
function Events:CanReview(key)
    local G = Guild()
    if type(key) ~= "string" or not G then return false end
    if DemoOn() and Util.IsMe(key) then return true end
    return (G.IsGM and G:IsGM(key)) or (G.IsOfficer and G:IsOfficer(key, not Util.IsMe(key)))
        or (G.IsGuildCouncil and G:IsGuildCouncil(key)) or false
end

function Events:AmIReviewer() return self:CanReview(Me()) end

-- The same people remove anyone's records: library events, calendar events (cancel or remove), results, and
-- events from the review lists.
function Events:CanRemove(key) return self:CanReview(key) end

---------------------------------------------------------------------------
-- Cleaning what arrives (and what is saved): known shapes, bounded sizes
---------------------------------------------------------------------------

local function Cut(s, maxLen)
    maxLen = maxLen or MAX_TEXT
    if #s > maxLen then
        -- cut between letters, never inside one (in UTF-8 the bytes 0x80-0xBF go on with the letter before)
        local cut = maxLen
        while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
        s = strsub(s, 1, cut)
    end
    return s
end

local function Str(s, maxLen)
    if type(s) ~= "string" then return nil end
    return Cut((s:gsub("[%c|]", "")), maxLen)
end

-- Text of several lines (the builder's notes): its line breaks stay.
local function Lines(s, maxLen)
    if type(s) ~= "string" then return nil end
    s = s:gsub("\r\n?", "\n"):gsub("[%z\1-\9\11-\31\127|]", "")
    return Cut(s, maxLen)
end

local function Int(n, lo, hi)
    n = tonumber(n)
    if not n or n ~= n then return nil end
    n = floor(n)
    if lo and n < lo then n = lo end
    if hi and n > hi then n = hi end
    return n
end

local CleanPiece

local function CleanArg(a, budget, depth)
    local t = type(a)
    if t == "number" then return (a == a and a > -1e9 and a < 1e9) and a or nil end
    if t == "string" then return Str(a) end
    if t ~= "table" then return nil end
    if a.k then return CleanPiece(a, budget, depth + 1) end
    if type(a.j) == "table" then
        local out = {}
        for i = 1, min(#a.j, 24) do
            local x = a.j[i]
            if type(x) == "string" then out[#out + 1] = Str(x)
            elseif type(x) == "table" and x.k then out[#out + 1] = CleanPiece(x, budget, depth + 1) end
        end
        return { j = out }
    end
    return nil
end

CleanPiece = function(p, budget, depth)
    if type(p) ~= "table" or type(p.k) ~= "string" or #p.k > 16 or not p.k:find("^[%w%.]+$") then return nil end
    if depth > MAX_DEPTH then return nil end
    budget.n = budget.n + 1
    if budget.n > MAX_PIECES then return nil end
    local out = { k = p.k, a = {} }
    if type(p.a) == "table" then
        for i = 1, 8 do
            if p.a[i] ~= nil then out.a[i] = CleanArg(p.a[i], budget, depth) end
        end
    end
    -- the next piece is a chain, not a nesting: walk it here so a long stack does not count as deep
    if p.c1 then out.c1 = CleanPiece(p.c1, budget, depth + 1) end
    if p.c2 then out.c2 = CleanPiece(p.c2, budget, depth + 1) end
    local cur, src = out, p.n
    while type(src) == "table" do
        local nx = CleanPiece({ k = src.k, a = src.a, c1 = src.c1, c2 = src.c2 }, budget, depth)
        if not nx then break end
        cur.n = nx
        cur, src = nx, src.n
    end
    return out
end

local function Num(n, lo, hi)
    n = tonumber(n)
    if not n or n ~= n then return nil end
    if lo and n < lo then n = lo end
    if hi and n > hi then n = hi end
    return n
end

local function OneOf(v, choices, default)
    for _, c in ipairs(choices) do
        if (type(c) == "table" and c[1] or c) == v then return v end
    end
    return default
end

-- An event's definitions (tags, scores, places, lists, asks: EVENTS_KINDS.md), each kind at most LIMITS.defs (places
-- LIMITS.places), the lowest ids first; names 24, a question 120, answers / choices 6 of 40, items 40 a list.
local DEF_TEXT = 120
local ALL_ITEMS = 80   -- list items in all an event's lists (B.LIMITS.allItems when EventBlocks says)
Events.ALL_ITEMS = ALL_ITEMS
local function CleanDefinitions(d, out)
    local Bk = B()
    local L = Bk.LIMITS or {}
    local NAME, PER = L.name or 24, L.defs or 24
    local function kind(name, limit, clean)
        local t = type(d[name]) == "table" and d[name] or nil
        if not t then return end
        local ids = {}
        for id, x in pairs(t) do
            if IsId(id) and type(x) == "table" then ids[#ids + 1] = id end
        end
        tsort(ids)
        local res, n = {}, 0
        for i = 1, min(#ids, limit) do
            local x = clean(t[ids[i]], ids[i])
            if x then
                res[ids[i]] = x
                n = n + 1
            end
        end
        if n > 0 then out[name] = res end
    end
    local function texts(list, count, len)
        local res = {}
        for i = 1, min(type(list) == "table" and #list or 0, count) do
            local s = Str(list[i], len)
            if s and s ~= "" then res[#res + 1] = s end
        end
        return res
    end
    kind("tags", PER, function(x, id)
        return { n = Str(x.n, NAME) or id, c = (Bk.TAG_COLOR and Bk.TAG_COLOR[x.c]) and x.c or "blue",
            shown = OneOf(x.shown, Bk.TAG_SHOWN or { "all", "self", "host" }, "all") }
    end)
    kind("scores", PER, function(x, id)
        return { n = Str(x.n, NAME) or id, high = x.high ~= false, fmt = OneOf(x.fmt, Bk.SCORE_FMT or { "num" }, "num"),
            board = x.board and true or false, cap = Num(x.cap, -1e9, 1e9) }
    end)
    kind("places", L.places or 24, function(x, id)
        local p = { n = Str(x.n, NAME) or id, map = Int(x.map, 1, 1e6), x = Num(x.x, 0, 1), y = Num(x.y, 0, 1),
            r = Num(x.r, 1, 5000) or 30, z = Str(x.z, 48), sz = Str(x.sz, 48) }
        if not (p.map and p.x and p.y) then p.map, p.x, p.y = nil, nil, nil end
        return p
    end)
    -- (list items: 40 a list and LIMITS.allItems in all the event's lists, so that a def with every definition filled
    -- in still goes to the guild in one message)
    local itemsLeft = L.allItems or ALL_ITEMS
    kind("lists", PER, function(x, id)
        local l = { n = Str(x.n, NAME) or id, kind = OneOf(x.kind, Bk.LIST_KINDS or { "text" }, "text"), items = {} }
        local count = min(type(x.items) == "table" and #x.items or 0, L.items or 40, itemsLeft)
        itemsLeft = itemsLeft - count
        for i = 1, count do
            local it = x.items[i]
            if l.kind == "question" then
                if type(it) == "table" and Str(it.q, L.question or DEF_TEXT) then
                    l.items[#l.items + 1] = { q = Str(it.q, L.question or DEF_TEXT),
                        a = texts(it.a, L.answers or 6, L.answer or 40), pts = Num(it.pts, -1000, 1000) }
                end
            elseif l.kind == "place" then
                if IsId(it) then l.items[#l.items + 1] = it end
            else
                local s = Str(it, DEF_TEXT)
                if s and s ~= "" then l.items[#l.items + 1] = s end
            end
        end
        return l
    end)
    kind("asks", PER, function(x, id)
        local from = x.from
        if from ~= "entrants" and not IsId(from) then from = "entrants" end
        return { n = Str(x.n, NAME) or id, q = Str(x.q, L.question or DEF_TEXT),
            kind = OneOf(x.kind, Bk.ASK_KINDS or { "player" }, "player"),
            choices = texts(x.choices, L.choices or 6, L.choice or 40), from = from, votes = Int(x.votes, 1, 3) or 1,
            self = x.self and true or false, time = Int(x.time, 5, 3600) or 60, secret = x.secret and true or false }
    end)
end

local function CleanScripts(list, budget)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, min(#list, MAX_SCRIPTS) do
        local s = list[i]
        if type(s) == "table" and IsId(s.id) and s.top then
            local top = CleanPiece(s.top, budget, 0)
            if top then
                out[#out + 1] = { id = s.id, st = Str(s.st, 12) or "*", x = Int(s.x, -4000, 4000) or 0,
                    y = Int(s.y, -4000, 4000) or 0, top = top }
            end
        end
    end
    return out
end

-- A def as it may be stored (nil: refused).
function Events:CleanDef(d)
    if type(d) ~= "table" or not IsId(d.id) then return nil end
    local by = WireKey(d.by)
    if not by then return nil end
    local out = { id = d.id, by = by, rev = Int(d.rev, 0), at = Int(d.at, 0), name = Str(d.name, MAX_NAME) or "Event" }
    if d.del then
        out.del = true
        return out
    end
    out.icon = Str(d.icon, 96)
    out.art = Str(d.art, 16)
    out.from = IsId(d.from) and d.from or nil
    local budget = { n = 0 }
    out.stages = {}
    for i = 1, min(type(d.stages) == "table" and #d.stages or 0, MAX_STAGES) do
        local s = d.stages[i]
        if type(s) == "table" and IsId(s.id) then
            out.stages[#out.stages + 1] = { id = s.id, name = Str(s.name, 24) or ("Stage " .. i), desc = Str(s.desc, MAX_TEXT) }
        end
    end
    out.scripts = CleanScripts(d.scripts, budget)
    out.blocks = {}
    local nb = 0
    for bid, b in pairs(type(d.blocks) == "table" and d.blocks or {}) do
        nb = nb + 1
        if nb > 8 then break end
        if IsId(bid) and type(b) == "table" and B().SMART[b.kind] then
            local set = {}
            for _, o in ipairs(B().SMART[b.kind].settings) do
                local v = type(b.set) == "table" and b.set[o.key]
                if type(v) == "number" or type(v) == "boolean" or (type(v) == "string" and #v <= 16) then set[o.key] = v end
            end
            out.blocks[bid] = { kind = b.kind, stage = Str(b.stage, 12) or "s1", x = Int(b.x, -4000, 4000) or 0,
                y = Int(b.y, -4000, 4000) or 0, set = set, inner = b.inner and CleanScripts(b.inner, budget) or nil }
        end
    end
    out.vars = {}
    for i = 1, min(type(d.vars) == "table" and #d.vars or 0, 24) do
        local v = d.vars[i]
        if type(v) == "table" and Str(v.n, 24) then
            out.vars[#out.vars + 1] = { n = Str(v.n, 24), t = (v.t == "num" or v.t == "text") and v.t or "player" }
        end
    end
    out.badges = {}
    local nbd = 0
    for id, bd in pairs(type(d.badges) == "table" and d.badges or {}) do
        nbd = nbd + 1
        if nbd > 12 then break end
        if IsId(id) and type(bd) == "table" then
            out.badges[id] = { n = Str(bd.n, 32) or "Badge", i = Str(bd.i, 96), f = Str(bd.f, 10) or "gold", ti = Str(bd.ti, 24) }
        end
    end
    out.notes = {}
    for i = 1, min(type(d.notes) == "table" and #d.notes or 0, 20) do
        local n = d.notes[i]
        if type(n) == "table" and Lines(n.text) then
            out.notes[#out.notes + 1] = { st = Str(n.st, 12) or "*", x = Int(n.x, -4000, 4000) or 0, y = Int(n.y, -4000, 4000) or 0,
                text = Lines(n.text) }
        end
    end
    CleanDefinitions(d, out)
    -- where the entrants meet: one of its places (only when set: older records hash as they did)
    if IsId(d.meet) and out.places and out.places[d.meet] then out.meet = d.meet end
    if type(d.review) == "table" and Int(d.review.rev, 0) then
        out.review = { rev = Int(d.review.rev, 0), at = Int(d.review.at, 0) or 0, note = Str(d.review.note) }
    end
    -- part 1's pieces as part 2's (an event made before, another member's older copy): in place, once
    local Bk = B()
    if Bk.Migrate then pcall(Bk.Migrate, Bk, out) end
    return out
end

local function CleanRecord(kind, r)
    if type(r) ~= "table" or not IsRecordId(kind, r.id) then return nil end
    local by = WireKey(r.by)
    if not by then return nil end
    local rev = Int(r.rev, 0)
    if not rev or rev > Now() + 600 then return nil end
    if kind == "D" then
        local d = Events:CleanDef(r)
        if d then d.rev = rev end
        return d
    elseif kind == "K" then
        -- x: a revision taken out of the waiting list (undecided); hide: cleared from the decided list
        return { id = r.id, by = by, rev = rev, dr = Int(r.dr, 0) or 0, ok = r.ok and true or false, note = Str(r.note),
            x = Int(r.x, 0), hide = r.hide and true or nil }
    elseif kind == "O" then
        if r.del then return { id = r.id, by = by, rev = rev, del = true, h = WireKey(r.h) } end
        local d = type(r.def) == "table" and Events:CleanDef(r.def)
        if not d then return nil end
        return { id = r.id, by = by, h = WireKey(r.h) or by, rev = rev, def = d, dk = IsId(r.dk) and r.dk or nil, dr = Int(r.dr, 0),
            at = Int(r.at, 0) or 0, where = Str(r.where, 48), note = Str(r.note), ranked = r.ranked and true or nil,
            cancel = r.cancel and (Str(r.cancel, 80) or "Cancelled") or nil,
            meet = (IsId(r.meet) and d.places and d.places[r.meet]) and r.meet or nil }
    elseif kind == "J" then
        local occ, who = r.id:match("^(.+)/([^/]+)$")
        if not occ or who ~= by then return nil end
        return { id = r.id, by = by, rev = rev, o = occ, on = r.on and true or false, at = Int(r.at, 0) or rev }
    elseif kind == "R" then
        if r.del then return { id = r.id, by = by, rev = rev, del = true } end
        local out = { id = r.id, by = by, rev = rev, name = Str(r.name, MAX_NAME) or "Event", icon = Str(r.icon, 96),
            art = Str(r.art, 16), at = Int(r.at, 0) or 0, t1 = Int(r.t1, 0) or 0, ranked = r.ranked and true or nil,
            cancel = Str(r.cancel, 80), dk = IsId(r.dk) and r.dk or nil, n = Int(r.n, 0, 200) or 0,
            champ = WireKey(r.champ), second = WireKey(r.second), third = WireKey(r.third), points = {}, badges = {},
            moments = {}, last4 = {}, hosts = {}, nums = {} }
        for k, v in pairs(type(r.points) == "table" and r.points or {}) do
            local key = WireKey(k)
            if key and tonumber(v) then out.points[key] = Int(v, -1000, 1000) end
        end
        for i = 1, min(type(r.badges) == "table" and #r.badges or 0, 40) do
            local a = r.badges[i]
            if type(a) == "table" and WireKey(a.p) then
                out.badges[#out.badges + 1] = { p = WireKey(a.p), n = Str(a.n, 32) or "Badge", i = Str(a.i, 96),
                    f = Str(a.f, 10) or "gold", ti = Str(a.ti, 24) }
            end
        end
        for i = 1, min(type(r.moments) == "table" and #r.moments or 0, 12) do
            local m = r.moments[i]
            if type(m) == "table" and Str(m.text) then
                out.moments[#out.moments + 1] = { at = Int(m.at, 0) or 0, text = Str(m.text), i = Str(m.i, 96) }
            end
        end
        for i = 1, min(type(r.last4) == "table" and #r.last4 or 0, 4) do
            local m = r.last4[i]
            if type(m) == "table" then
                out.last4[#out.last4 + 1] = { a = WireKey(m.a), b = WireKey(m.b), wa = Int(m.wa, 0, 9) or 0,
                    wb = Int(m.wb, 0, 9) or 0, win = WireKey(m.win), r = Int(m.r, 0, 9) or 0, sa = Int(m.sa, 0, 99),
                    sb = Int(m.sb, 0, 99), bronze = m.bronze and true or nil, final = m.final and true or nil }
            end
        end
        for i = 1, min(type(r.hosts) == "table" and #r.hosts or 0, 6) do
            local h = WireKey(r.hosts[i])
            if h then out.hosts[#out.hosts + 1] = h end
        end
        for _, k in ipairs({ "matches", "duels", "longest", "watch" }) do
            if type(r.nums) == "table" and tonumber(r.nums[k]) then out.nums[k] = Int(r.nums[k], 0) end
        end
        out.mw = {}
        for k, v in pairs(type(r.mw) == "table" and r.mw or {}) do
            local key = WireKey(k)
            if key and tonumber(v) then out.mw[key] = Int(v, 0, 99) end
        end
        -- the scores' tables and who had each tag at the end (only when the event had them)
        local function keysOf(t)
            local list = {}
            for k in pairs(type(t) == "table" and t or {}) do
                if type(k) == "string" and WireKey(k) then list[#list + 1] = k end
            end
            tsort(list)
            return list
        end
        if type(r.scores) == "table" and #r.scores > 0 then
            out.scores = {}
            for i = 1, min(#r.scores, RESULT_SCORES) do
                local s = r.scores[i]
                if type(s) == "table" and IsId(s.id) then
                    local v = {}
                    for j, k in ipairs(keysOf(s.v)) do
                        if j > RESULT_KEYS then break end
                        local n = Num(s.v[k], -1e9, 1e9)
                        if n then v[WireKey(k)] = n end
                    end
                    out.scores[#out.scores + 1] = { id = s.id, n = Str(s.n, 24) or s.id, high = s.high ~= false,
                        fmt = (s.fmt == "time" or s.fmt == "gold") and s.fmt or "num", v = v }
                end
            end
        end
        if type(r.tags) == "table" and #r.tags > 0 then
            out.tags = {}
            for i = 1, min(#r.tags, RESULT_TAGS) do
                local t = r.tags[i]
                if type(t) == "table" and IsId(t.id) then
                    local keys = {}
                    for j = 1, min(type(t.k) == "table" and #t.k or 0, RESULT_KEYS) do
                        local key = WireKey(t.k[j])
                        if key then keys[#keys + 1] = key end
                    end
                    out.tags[#out.tags + 1] = { id = t.id, n = Str(t.n, 24) or t.id, c = Str(t.c, 12),
                        shown = (t.shown == "self" or t.shown == "host") and t.shown or "all", k = keys }
                end
            end
        end
        return out
    elseif kind == "C" then
        if r.id ~= "season" then return nil end
        return { id = "season", by = by, rev = rev, n = Str(r.n, 32) or "Season", from = Int(r.from, 0) or 0,
            to = Int(r.to, 0) or 0 }
    elseif kind == "T" then
        if r.id ~= by then return nil end
        return { id = r.id, by = by, rev = rev, ti = Str(r.ti, 24) }
    end
    return nil
end
Events.CleanRecord = CleanRecord

---------------------------------------------------------------------------
-- Merging (the same on every client, whatever order things arrive in)
---------------------------------------------------------------------------

local function Newer(a, b)
    if not b then return true end
    if a.rev ~= b.rev then return a.rev > b.rev end
    return Util.Hash(a) > Util.Hash(b)
end

local function CountLive(t, owner)
    local n = 0
    for _, r in pairs(t) do
        if not r.del and (not owner or r.by == owner) then n = n + 1 end
    end
    return n
end

-- A calendar event made ranked right now (a live edit): it must be a copy of a library event whose current revision a
-- reviewer ranked, as it is. (A relayed one is taken at its word: the review may have moved on since.)
local function RankedNow(root, rec)
    local k, d = rec.dk and root.K[rec.dk], rec.dk and root.D[rec.dk]
    if not (k and k.ok and k.dr == rec.dr and d and not d.del and d.rev == rec.dr) then return false end
    local def = Events:CleanDef(d)
    return def ~= nil and Util.Hash(def) == Util.Hash(rec.def)
end

-- live: a live edit (EVU, or my own), checked against what is true now; else a record relayed from someone's store.
local function Merge(root, kind, rec, live)
    local t = root[kind]
    local cur = t[rec.id]
    if kind == "D" then
        if cur and not cur.del and cur.by ~= rec.by and not (rec.del and Events:CanRemove(rec.by)) then
            return false   -- only its creator edits it; the GM, an officer or the guild council may remove it
        end
        if cur and cur.del and not rec.del then return false end   -- a deletion wins
        if not cur and not rec.del then
            if CountLive(t) >= MAX_DEFS or CountLive(t, rec.by) >= MAX_OWN then return false end
        end
        if cur and not Newer(rec, cur) and not (rec.del and not cur.del) then return false end
    elseif kind == "K" then
        if not Events:CanReview(rec.by) then return false end
        if cur and not Newer(rec, cur) then return false end
    elseif kind == "O" then
        -- h is its host (who put it on the calendar), by its last writer: the host, or the GM / an officer / the guild
        -- council cancelling or removing it
        if cur and not cur.del then
            local host = cur.h or cur.by
            if rec.h and rec.h ~= host then return false end
            if rec.by ~= host and not ((rec.del or rec.cancel) and Events:CanRemove(rec.by)) then return false end
        elseif not cur and not rec.del and rec.h ~= rec.by then
            return false
        end
        if cur and cur.del and not rec.del then return false end
        if not cur and not rec.del and CountLive(t) >= MAX_OCC then return false end
        if cur and not Newer(rec, cur) and not (rec.del and not cur.del) then return false end
        -- ranked only by a review (an edit of one that was ranked keeps it, for the same revision)
        if live and rec.ranked and not rec.del and not (cur and not cur.del and cur.ranked and cur.dr == rec.dr)
            and not RankedNow(root, rec) then
            return false
        end
    elseif kind == "R" then
        local occ = root.O[rec.id]
        local host = occ and (occ.h or occ.by)
        if rec.del then
            if not (Events:CanRemove(rec.by) or (cur and cur.by == rec.by)) then return false end
        else
            -- a result is of a calendar event this client knows (unless it is older than the calendar keeps them)
            if not occ and (rec.at or 0) > Now() - OCC_KEEP + DAY then return false end
            -- the event's host writes its result; a host who took over names the chain from the first host, and
            -- never writes over the host's own
            if host and rec.by ~= host then
                if not (rec.hosts[1] == host and rec.hosts[#rec.hosts] == rec.by) then return false end
                if cur and not cur.del and cur.by == host then return false end
            end
            -- ranked only when its calendar event was
            if rec.ranked and occ and not occ.del and not occ.ranked then return false end
        end
        if cur and cur.del and not rec.del then return false end
        -- (the host's own result replaces a taker's, whatever their revisions)
        local hostOwn = host and not rec.del and rec.by == host and cur and not cur.del and cur.by ~= host
        if cur and not hostOwn and not Newer(rec, cur) and not (rec.del and not cur.del) then return false end
    elseif kind == "C" then
        if not Events:CanModerate(rec.by) then return false end
        if cur and not Newer(rec, cur) then return false end
    else   -- J, T: written by the member themself (CleanRecord checked the id)
        if cur and not Newer(rec, cur) then return false end
    end
    t[rec.id] = rec
    return true
end

local function StoreRecord(kind, r, live)
    if not KINDS[kind] then return false end
    local root = Root(true)
    if not root then return false end
    local rec = CleanRecord(kind, r)
    if not rec then return false end
    return Merge(root, kind, rec, live), rec
end

-- My own change: stored (merged like anyone's), then sent to the guild.
local function Commit(kind, rec)
    rec.by = rec.by or Me()
    if DemoOn() then
        -- demo mode: its own data changes (with a revision, like a real one), nothing is stored or sent
        local st = State()
        rec.rev = NextRev(st[kind][rec.id])
        if kind == "D" and type(rec.review) == "table" and rec.review.rev == true then rec.review.rev = rec.rev end
        local clean = CleanRecord(kind, rec)
        if not clean then return false end
        st[kind][rec.id] = clean
        Changed()
        return true
    end
    rec.rev = NextRev(Root(true) and Root(true)[kind][rec.id])
    -- a review asked for "this revision": the one this commit makes
    if kind == "D" and type(rec.review) == "table" and rec.review.rev == true then rec.review.rev = rec.rev end
    local clean = CleanRecord(kind, rec)
    if not clean then return false end
    local Comm = ns.Comm
    if Comm and Comm.Fits and not Comm:Fits({ t = "EVU", k = kind, r = clean }, SIZE_HEADROOM) then
        ns:Print("this event is too big to share with the guild: take some pieces out.")
        return false
    end
    if not Merge(Root(true), kind, clean, true) then return false end
    Send({ t = "EVU", k = kind, r = clean }, "GUILD", nil, "data")
    Changed()
    return true
end

---------------------------------------------------------------------------
-- The library (D) and reviews (K)
---------------------------------------------------------------------------

function Events:GetDefs()
    local st = State()
    local out = {}
    for _, d in pairs(st and st.D or {}) do
        if not d.del then out[#out + 1] = d end
    end
    tsort(out, function(a, b)
        if a.name ~= b.name then return (a.name or "") < (b.name or "") end
        return a.id < b.id
    end)
    return out
end

function Events:GetDef(id)
    local st = State()
    local d = st and st.D[id]
    if d and not d.del then return d end
    return nil
end

function Events:IsMine(d) return d and d.by == Me() or false end

-- A new event, not saved yet: the starter (Friday duel cup) or an empty one.
function Events:NewDef(starter)
    local d = starter and B():Starter() or B():Blank()
    d.id = NewId("e")
    d.by = Me()
    return d
end

function Events:CopyDef(src)
    if type(src) == "string" then src = self:GetDef(src) end
    if not src then return nil end
    local d = Copy(src)
    d.id = NewId("e")
    d.by = Me()
    d.from = src.id
    d.review = nil
    d.rev = nil
    if not self:IsMine(src) then d.name = src.name end
    return d
end

-- Saves my event (new or edited): a new revision, to the guild. Refused for someone else's (copy it).
function Events:SaveDef(d)
    if type(d) ~= "table" then return false end
    d.id = d.id or NewId("e")
    local cur = self:GetDef(d.id)
    if cur and cur.by ~= Me() then return false end
    d.by = Me()
    d.at = Now()
    -- a pending review is for the revision it was sent with: an edit makes a new one, not reviewed
    d.review = nil
    local rec = Copy(d)
    local ok = Commit("D", rec)
    if ok then
        local saved = self:GetDef(d.id)
        if saved then d.rev = saved.rev end
    end
    return ok
end

function Events:DeleteDef(id)
    local d = self:GetDef(id)
    if not d or not (d.by == Me() or self:CanRemove(Me())) then return false end
    return Commit("D", { id = id, by = Me(), name = d.name, del = true })
end

-- A review of an event: the newest one for it, or nil.
function Events:GetReview(defId)
    local st = State()
    return st and st.K[defId] or nil
end

-- "ranked" (this revision was marked ranked), "review" (sent in, waiting), "back" (sent back for this revision),
-- "changed" (ranked before, edited since), "draft" (also: a reviewer took this revision out of the waiting list).
function Events:ReviewState(d)
    if not d then return "draft" end
    local k = self:GetReview(d.id)
    if k and k.dr == d.rev then return k.ok and "ranked" or "back" end
    if k and k.x == d.rev then return "draft" end
    if d.review and d.review.rev == d.rev then return "review" end
    if k and k.ok then return "changed" end
    return "draft"
end

function Events:IsRanked(d) return self:ReviewState(d) == "ranked" end

-- Sends my event in for review (with a note for the reviewers).
function Events:SubmitForReview(id, note)
    local d = self:GetDef(id)
    if not d or d.by ~= Me() then return false end
    local rec = Copy(d)
    rec.review = { rev = true, at = Now(), note = Str(note) }   -- (Commit stamps the revision it makes)
    return Commit("D", rec)
end

-- A reviewer's decision on the event's current revision: ok = ranked, else sent back with a note.
function Events:Review(id, ok, note)
    local d = self:GetDef(id)
    if not d or not self:CanReview(Me()) then return false end
    if ok then KeepSnapshot(d) end
    return Commit("K", { id = id, by = Me(), dr = d.rev, ok = ok and true or false, note = Str(note) })
end

-- A reviewer takes an event out of the waiting list without deciding (its creator may send it in again: that makes a
-- new revision). The review it had stays as it was (an older ranked one too).
function Events:DismissReview(defId)
    local d = self:GetDef(defId)
    if not d or not self:CanRemove(Me()) or self:ReviewState(d) ~= "review" then return false end
    local rec = Copy(self:GetReview(defId) or {})
    rec.id, rec.by, rec.x, rec.rev = defId, Me(), d.rev, nil
    rec.dr, rec.ok = rec.dr or 0, rec.ok or false
    return Commit("K", rec)
end

-- A reviewer clears a decision from the decided list; it stays in force (a ranked event stays ranked).
function Events:HideDecision(defId)
    local k = self:GetReview(defId)
    if not k or not self:CanRemove(Me()) or k.hide then return false end
    local rec = Copy(k)
    rec.by, rec.hide, rec.rev = Me(), true, nil
    return Commit("K", rec)
end

-- Events sent in and not decided for their current revision (the Review view), oldest first.
function Events:GetReviewQueue()
    local out = {}
    for _, d in ipairs(self:GetDefs()) do
        if self:ReviewState(d) == "review" then out[#out + 1] = d end
    end
    tsort(out, function(a, b) return (a.review.at or 0) < (b.review.at or 0) end)
    return out
end

-- Recent decisions (the Review view's second list), newest first: not the ones cleared from it, nor an event only
-- taken out of the waiting list.
function Events:GetDecided(limit)
    local st = State()
    local out = {}
    for id, k in pairs(st and st.K or {}) do
        local d = self:GetDef(id)
        if d and not k.hide and (k.dr or 0) > 0 then out[#out + 1] = { d = d, k = k } end
    end
    tsort(out, function(a, b) return a.k.rev > b.k.rev end)
    while #out > (limit or 6) do tremove(out) end
    return out
end

-- What changed between the ranked revision's pieces and now: kept by the reviewer's client as the def it last saw
-- ranked (snap), so a changed event can show only its differences.
function Events:RankedSnapshot(defId)
    local db = ns.db
    local g = GuildKey()
    local snaps = db and db.eventSnaps and g and db.eventSnaps[g]
    return snaps and snaps[defId] or nil
end

function KeepSnapshot(d)
    local db = ns.db
    local g = GuildKey()
    if not (db and g and d) or DemoOn() then return end
    db.eventSnaps = db.eventSnaps or {}
    db.eventSnaps[g] = db.eventSnaps[g] or {}
    db.eventSnaps[g][d.id] = Copy(d)
end

---------------------------------------------------------------------------
-- The calendar (O) and sign-ups (J)
---------------------------------------------------------------------------

-- A place of the event's to meet at (pid) or nil: one of its places.
local function MeetPlace(def, pid)
    return (IsId(pid) and type(def) == "table" and type(def.places) == "table" and type(def.places[pid]) == "table") and pid
        or nil
end

-- Where the entrants of a calendar event meet: its own choice (o.meet), else its event's (def.meet); nil: nowhere
-- (an event without places). A pid of o.def.places.
function Events:MeetOf(o)
    if type(o) ~= "table" then return nil end
    return MeetPlace(o.def, o.meet) or MeetPlace(o.def, type(o.def) == "table" and o.def.meet)
end

-- Puts one of the library's events on the calendar (I host it): a copy of the event as it is now. opts: where, note,
-- meet (one of its places to meet at, instead of the event's own), noJoin (the host isn't in it).
function Events:Schedule(defId, at, opts)
    local d = self:GetDef(defId)
    if not d then return nil end
    local id = NewId("o")
    local ok = Commit("O", { id = id, by = Me(), h = Me(), def = Copy(d), dk = d.id, dr = d.rev, at = floor(tonumber(at) or Now()),
        where = opts and opts.where, note = opts and opts.note, ranked = self:IsRanked(d) or nil,
        meet = opts and MeetPlace(d, opts.meet) or nil })
    if ok then
        -- the host is in it unless they say otherwise
        if not (opts and opts.noJoin) then self:SignUp(id, true) end
        return id
    end
    return nil
end

-- real: the saved one, even in demo mode (live events go on underneath it).
function Events:GetOcc(id, real)
    local st = real and Root(false) or State()
    local o = st and st.O[id]
    if o and not o.del then return o end
    return nil
end

-- The calendar event was taken off the calendar (its removal is known here).
function Events:OccRemoved(id)
    local root = Root(false)
    local o = root and root.O[id]
    return o and o.del or false
end

-- Calendar events from..to (start times), soonest first; cancelled ones too (they say so).
function Events:GetOccurrences(from, to)
    local st = State()
    local out = {}
    for _, o in pairs(st and st.O or {}) do
        if not o.del and (not from or o.at >= from) and (not to or o.at <= to) then out[#out + 1] = o end
    end
    tsort(out, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.id < b.id
    end)
    return out
end

function Events:HostOf(o) return o and (o.h or o.by) or nil end

function Events:CanManageOcc(o)
    return o ~= nil and (self:HostOf(o) == Me() or self:CanRemove(Me()))
end

function Events:CancelOcc(id, reason)
    local o = self:GetOcc(id)
    if not self:CanManageOcc(o) then return false end
    local rec = Copy(o)
    rec.by = Me()
    rec.h = self:HostOf(o)
    rec.cancel = Str(reason, 80) or "Cancelled"
    return Commit("O", rec)
end

function Events:DeleteOcc(id)
    local o = self:GetOcc(id)
    if not self:CanManageOcc(o) then return false end
    return Commit("O", { id = id, by = Me(), h = self:HostOf(o), del = true })
end

-- The host moves their event (a new time / place / note); not while it runs, nor once it ran. meet: a place of its
-- to meet at (nil: as it was; false: the event's own).
function Events:EditOcc(id, at, where, note, meet)
    local o = self:GetOcc(id)
    if not o or self:HostOf(o) ~= Me() then return false end
    local state = self:OccState(o)
    if state == "live" or state == "done" then return false end
    local rec = Copy(o)
    rec.by = Me()
    rec.at = floor(tonumber(at) or o.at)
    rec.where = where
    rec.note = note
    if meet == false then rec.meet = nil elseif meet ~= nil then rec.meet = MeetPlace(o.def, meet) end
    return Commit("O", rec)
end

-- A Sign-up block of the event takes level 70 characters only.
function Events:Needs70(def)
    for _, bid in ipairs(B():BlocksOf(def, "signup")) do
        if B():SmartSetting(def.blocks[bid], "lvl70") then return true end
    end
    return false
end

-- Returns ok, and why not (words for the player).
function Events:SignUp(occId, on)
    local o = self:GetOcc(occId)
    if not o then return false, "That event is gone from the calendar." end
    if on then
        local state = self:OccState(o)
        if state == "cancelled" then return false, "That event was cancelled." end
        if state == "done" then return false, "That event is over." end
        if self:Needs70(o.def) and UnitLevel and (UnitLevel("player") or 0) < 70 then
            return false, "This one is for level 70 characters."
        end
        -- a sign-up that closes before the start (15 minutes early) stays closed from then on, and a full one is full
        -- (while the event runs, its host's run decides)
        if state ~= "live" and not self:IsSignedUp(occId) then
            local closes = self:ClosesAt(o)
            if closes and closes < o.at and Now() >= closes then return false, "Sign-up is closed." end
            local first = B():BlocksOf(o.def, "signup")[1]
            local spots = first and B():SmartSetting(o.def.blocks[first], "spots")
            if spots and #self:GetSignups(occId) >= spots then return false, "It's full." end
        end
        -- while it runs: as its run says (a Sign-up that's open and has room), else joining would do nothing
        local L = ns.EventLive
        local run = state == "live" and L and L.GetState and L:GetState(occId)
        local inIt = false
        for _, k in ipairs(type(run) == "table" and type(run.entrants) == "table" and run.entrants or {}) do
            if k == Me() then inIt = true end
        end
        if type(run) == "table" and not inIt then
            local open, room = false, false
            for _, bid in ipairs(B():BlocksOf(o.def, "signup")) do
                local b = type(run.blocks) == "table" and run.blocks[bid]
                if type(b) == "table" and b.open then
                    open = true
                    local spots = B():SmartSetting(o.def.blocks[bid], "spots") or 40
                    if type(b.list) ~= "table" or #b.list < spots then room = true end
                end
            end
            if not open then return false, "Sign-up is closed." end
            if not room then return false, "It's full." end
        end
    end
    local me = Me()
    local id = occId .. "/" .. me
    local st = State()
    local cur = st and st.J[id]
    local at = (cur and cur.on and on) and cur.at or Now()
    local ok = Commit("J", { id = id, by = me, o = occId, on = on and true or false, at = at })
    -- while the event runs, the host hears it at once
    if ok and ns.EventLive and ns.EventLive.OnSignUp then ns.EventLive:OnSignUp(occId, me, on) end
    return ok
end

function Events:IsSignedUp(occId, key)
    local st = State()
    local j = st and st.J[occId .. "/" .. (key or Me())]
    return j and j.on or false
end

-- Who signed up, first come first: keys.
function Events:GetSignups(occId)
    local st = State()
    local list = {}
    for _, j in pairs(st and st.J or {}) do
        if j.o == occId and j.on then list[#list + 1] = j end
    end
    tsort(list, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.by < b.by
    end)
    local out = {}
    for i, j in ipairs(list) do out[i] = j.by end
    return out
end

-- The sign-up of an occurrence's Sign-up block closes at: (time) or nil.
function Events:ClosesAt(o)
    if not o then return nil end
    for _, bid in ipairs(B():BlocksOf(o.def, "signup")) do
        local closes = B():SmartSetting(o.def.blocks[bid], "closes")
        if closes == "early" then return o.at - 900 end
        if closes == "start" then return o.at end
    end
    return nil
end

-- planned | live | done | cancelled | missed (its time passed long ago, nobody ran it)
function Events:OccState(o)
    if not o then return nil end
    if o.cancel then return "cancelled" end
    local r = self:GetResult(o.id)
    if r then return r.cancel and "cancelled" or "done" end
    local L = ns.EventLive
    if L and L.IsLive and L:IsLive(o.id) then return "live" end
    if Now() > o.at + 6 * 3600 then return "missed" end
    return "planned"
end

---------------------------------------------------------------------------
-- Results (R)
---------------------------------------------------------------------------

function Events:GetResult(id)
    local st = State()
    local r = st and st.R[id]
    if r and not r.del then return r end
    return nil
end

function Events:GetResults(from, to)
    local st = State()
    local out = {}
    for _, r in pairs(st and st.R or {}) do
        if not r.del and (not from or r.at >= from) and (not to or r.at <= to) then out[#out + 1] = r end
    end
    tsort(out, function(a, b) return a.at > b.at end)
    return out
end

-- The host saves what the run decided (Core/EventLive.lua at the end of a run). hosts: the chain of hosts.
function Events:SaveResult(occId, run, hosts)
    local o = self:GetOcc(occId)
    local st = run.st
    local res = run:Result()
    local d = run.def
    -- the chain of hosts as a result keeps it (6): the first one and the last ones
    local chain = {}
    hosts = hosts or { Me() }
    for i, k in ipairs(hosts) do
        if i == 1 or i > #hosts - 5 then chain[#chain + 1] = k end
    end
    local rec = { id = occId, by = Me(), name = d.name, icon = d.icon, art = d.art, at = st.t0 or Now(), t1 = st.t1 or Now(),
        ranked = (o and o.ranked) or nil, dk = o and o.dk, n = #st.entrants, champ = res.champ, second = res.second,
        third = res.third, points = {}, badges = {}, moments = {}, last4 = {}, hosts = chain, nums = {},
        cancel = st.phase == "cancelled" and (st.reason or "Cancelled") or nil }
    if rec.ranked then
        for k, n in pairs(res.points) do rec.points[k] = n end
        for _, a in ipairs(res.badges) do
            local bd = d.badges and d.badges[a.b]
            if bd then rec.badges[#rec.badges + 1] = { p = a.p, n = bd.n, i = bd.i, f = bd.f, ti = bd.ti } end
        end
    end
    local moms = st.moments or {}
    for i = max(1, #moms - 7), #moms do rec.moments[#rec.moments + 1] = Copy(moms[i]) end
    local bk = run:MainBracket()
    rec.mw = {}
    if bk then
        local matches, games, longest = 0, 0, 0
        for _, m in pairs(bk.m) do
            if m.st == "done" and not m.wo then
                matches = matches + 1
                games = games + (m.g or 0)
                if m.t and m.te and m.te - m.t > longest then longest = m.te - m.t end
            end
            if m.st == "done" and m.win and rec.ranked then rec.mw[m.win] = (rec.mw[m.win] or 0) + 1 end
        end
        rec.nums = { matches = matches, duels = games, longest = longest, watch = st.watchMax }
        if bk.fmt ~= "robin" then
            local last, semis = bk.rounds[bk.last] or {}, bk.rounds[bk.last - 1] or {}
            local seedOf = {}
            for i, k in ipairs(bk.seeds) do seedOf[k] = i end
            local function add(m)
                rec.last4[#rec.last4 + 1] = { a = m.a or nil, b = m.b or nil, wa = m.wa, wb = m.wb, win = m.win, r = m.r,
                    sa = m.a and seedOf[m.a], sb = m.b and seedOf[m.b], bronze = m.bronze, final = m.final }
            end
            for _, mid in ipairs(semis) do add(bk.m[mid]) end
            for _, mid in ipairs(last) do add(bk.m[mid]) end
        end
    end
    self:ResultTables(rec, d, st)
    return Commit("R", rec)
end

-- A result's score tables (the scores on the board first) and tags: who had what at the end. Trimmed (tags first,
-- then the last scores) until the result fits a message to the guild.
function Events:ResultTables(rec, d, st)
    local Bk = B()
    local defs = Bk.Defs and Bk:Defs(d, "scores", true) or {}
    local board, rest = {}, {}
    for _, e in ipairs(defs) do tinsert(e.board and board or rest, e) end
    for _, e in ipairs(rest) do board[#board + 1] = e end
    local scores = {}
    for _, e in ipairs(board) do
        if #scores >= RESULT_SCORES then break end
        local rows, v = type(st.scores) == "table" and st.scores[e.id], {}
        for k, n in pairs(type(rows) == "table" and rows or {}) do
            if type(k) == "string" and tonumber(n) then v[k] = tonumber(n) end
        end
        scores[#scores + 1] = { id = e.id, n = e.n, high = e.high ~= false, fmt = e.fmt, v = v }
    end
    local tags = {}
    for _, e in ipairs(Bk.Defs and Bk:Defs(d, "tags", true) or {}) do
        if #tags >= RESULT_TAGS then break end
        local set, keys = type(st.tags) == "table" and st.tags[e.id], {}
        for k, on in pairs(type(set) == "table" and set or {}) do
            if type(k) == "string" and on then keys[#keys + 1] = k end
        end
        tsort(keys)
        tags[#tags + 1] = { id = e.id, n = e.n, c = e.c, shown = e.shown, k = keys }
    end
    rec.scores = #scores > 0 and scores or nil
    rec.tags = #tags > 0 and tags or nil
    local Comm = ns.Comm
    if not (Comm and Comm.Fits) then return rec end
    local function fits()
        local probe = CleanRecord("R", (function()
            local r = Copy(rec)
            r.rev = Now()
            return r
        end)())
        return probe == nil or Comm:Fits({ t = "EVU", k = "R", r = probe }, SIZE_HEADROOM)
    end
    while not fits() do
        if rec.tags then
            tremove(rec.tags)
            if #rec.tags == 0 then rec.tags = nil end
        elseif rec.scores then
            tremove(rec.scores)
            if #rec.scores == 0 then rec.scores = nil end
        else
            break
        end
    end
    return rec
end

-- How often a library event ran (results of calendar events made from it), and when last.
function Events:RunCount(defId)
    local n, last = 0, nil
    for _, r in ipairs(self:GetResults()) do
        if r.dk == defId and not r.cancel then
            n = n + 1
            if not last or r.at > last then last = r.at end
        end
    end
    return n, last
end

-- Removes a result, and its calendar event with it (or it would read "planned" again).
function Events:DeleteResult(id)
    if not self:CanRemove(Me()) then return false end
    if not Commit("R", { id = id, by = Me(), del = true }) then return false end
    if self:GetOcc(id) then self:DeleteOcc(id) end
    return true
end

---------------------------------------------------------------------------
-- The season (C), standings, badges and titles (T)
---------------------------------------------------------------------------

-- Seasons by default follow the calendar's quarters; the first one (Oct - Dec 2026) is "Season 1".
local FIRST_SEASON = { year = 2026, q = 4 }

local function QuarterOf(t)
    local d = date("*t", t)
    return d.year, floor((d.month - 1) / 3) + 1
end

local function QuarterBounds(year, q)
    local from = time({ year = year, month = (q - 1) * 3 + 1, day = 1, hour = 0 })
    local ny, nq = year, q + 1
    if nq > 4 then ny, nq = year + 1, 1 end
    local to = time({ year = ny, month = (nq - 1) * 3 + 1, day = 1, hour = 0 }) - 1
    return from, to
end

-- The current season: { n, from, to, set (by an officer) }.
function Events:GetSeason()
    local st = State()
    local c = st and st.C.season
    local now = Now()
    if c and c.from <= now and now <= c.to then return { n = c.n, from = c.from, to = c.to, set = true } end
    local y, q = QuarterOf(now)
    local from, to = QuarterBounds(y, q)
    local num = (y - FIRST_SEASON.year) * 4 + (q - FIRST_SEASON.q) + 1
    return { n = "Season " .. max(1, num), from = from, to = to }
end

function Events:SetSeason(name, from, to)
    if not self:CanModerate(Me()) then return false end
    return Commit("C", { id = "season", by = Me(), n = name, from = from, to = to })
end

-- Standings of the season: { { key, pts, events, wins, badges = { badge ... newest first }, rank } ... }.
function Events:Standings(season)
    season = season or self:GetSeason()
    local rows, byKey = {}, {}
    local function row(k)
        local r = byKey[k]
        if not r then
            r = { key = k, pts = 0, events = 0, wins = 0, badges = {} }
            byKey[k] = r
            rows[#rows + 1] = r
        end
        return r
    end
    for _, r in ipairs(self:GetResults(season.from, season.to)) do
        if r.ranked and not r.cancel then
            local seen = {}
            for k, n in pairs(r.points) do
                local x = row(k)
                x.pts = x.pts + n
                if not seen[k] then seen[k] = true; x.events = x.events + 1 end
            end
            for _, a in ipairs(r.badges) do
                local x = row(a.p)
                tinsert(x.badges, { n = a.n, i = a.i, f = a.f, ti = a.ti, ev = r.name, at = r.at })
            end
            for k, n in pairs(r.mw or {}) do row(k).wins = row(k).wins + n end
        end
    end
    tsort(rows, function(a, b)
        if a.pts ~= b.pts then return a.pts > b.pts end
        if a.wins ~= b.wins then return a.wins > b.wins end
        return a.key < b.key
    end)
    for i, r in ipairs(rows) do
        -- the same points and match wins: the same rank (1, 2, 2, 4)
        local prev = rows[i - 1]
        r.rank = (prev and prev.pts == r.pts and prev.wins == r.wins) and prev.rank or i
        tsort(r.badges, function(a, b) return a.at > b.at end)
    end
    return rows
end

-- A member's rank this season (seeding), or nil.
function Events:RankOf(key)
    local cache = self.rankCache
    local now = GetTime()
    if not cache or now - cache.at > 5 then
        cache = { at = now, by = {} }
        for _, r in ipairs(self:Standings()) do cache.by[r.key] = r.rank end
        self.rankCache = cache
    end
    return cache.by[key]
end

-- Every badge a member earned in ranked events, newest first.
function Events:BadgesOf(key)
    local out = {}
    for _, r in ipairs(self:GetResults()) do
        if r.ranked and not r.cancel then
            for _, a in ipairs(r.badges) do
                if a.p == key then out[#out + 1] = { n = a.n, i = a.i, f = a.f, ti = a.ti, ev = r.name, at = r.at, occ = r.id } end
            end
        end
    end
    tsort(out, function(a, b) return a.at > b.at end)
    return out
end

function Events:TitlesOf(key)
    local out, seen = {}, {}
    for _, b in ipairs(self:BadgesOf(key)) do
        if b.ti and b.ti ~= "" and not seen[b.ti] then seen[b.ti] = true; out[#out + 1] = b.ti end
    end
    return out
end

-- The title a member shows: the one they picked (if they still have it), else their newest; "" for none picked to
-- show nothing.
function Events:GetTitle(key)
    local st = State()
    local t = st and st.T[key]
    local titles = self:TitlesOf(key)
    if t then
        if t.ti == "" then return nil end
        for _, x in ipairs(titles) do
            if x == t.ti then return x end
        end
    end
    return titles[1]
end

function Events:SetTitle(ti)
    return Commit("T", { id = Me(), by = Me(), ti = ti or "" })
end

---------------------------------------------------------------------------
-- Digest / sync
---------------------------------------------------------------------------

function Events:GetDigest()
    local out = {}
    local root = Root(false)
    if not root then return out end
    local items, signups = {}, {}
    for kind in pairs(KINDS) do
        local list = kind == "J" and signups or items
        for id in pairs(root[kind]) do list[#list + 1] = kind .. ":" .. id end
    end
    -- past the cap, sign-ups (the most, and the least lasting) are left out first
    tsort(items)
    tsort(signups)
    for _, item in ipairs(signups) do items[#items + 1] = item end
    for i = 1, min(#items, MAX_DIGEST_ITEMS) do
        local kind, id = items[i]:match("^(%u):(.+)$")
        out[items[i]] = Util.Hash(root[kind][id]):sub(1, 6)
    end
    return out
end

function Events:GetDigestHash()
    local d = self:GetDigest()
    local list = {}
    for item, h in pairs(d) do list[#list + 1] = item .. "=" .. h end
    if #list == 0 then return "0" end
    tsort(list)
    return Util.Hash(list)
end

local function SendItem(root, item, target)
    local kind, id = item:match("^(%u):(.+)$")
    if kind and KINDS[kind] and root[kind][id] then
        Send({ t = "EVG", k = kind, r = root[kind][id] }, "WHISPER", target, "data")
    end
end

-- EVU { k, r }: a change; its writer is the sender.
local function OnUpdate(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.r) ~= "table" or WireKey(msg.r.by) ~= sender then return end
    if not KINDS[msg.k] then return end
    local ok, rec = StoreRecord(msg.k, msg.r, true)
    if ok then
        if msg.k == "K" then
            local d = Events:GetDef(msg.r.id)
            -- (a decision for the revision it is now; a dismissal or a cleared decision keeps the old copy)
            if d and rec.ok and rec.dr == d.rev and Events:AmIReviewer() then KeepSnapshot(d) end
        elseif msg.k == "J" and ns.EventLive and ns.EventLive.OnSignUp then
            -- a sign-up while I run that event: the run hears it (its member may not know I host it yet)
            ns.EventLive:OnSignUp(rec.o, rec.by, rec.on)
        end
        Events.rankCache = nil
        Changed()
    end
end

-- EVG { k, r }: one record, relayed by anyone in the guild.
local function OnGive(sender, msg, dist)
    if dist ~= "WHISPER" or not KINDS[msg.k] or type(msg.r) ~= "table" then return end
    if StoreRecord(msg.k, msg.r) then
        Events.rankCache = nil
        Changed()
    end
end

local function OnWant(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.w) ~= "table" or not RateLimit("EVW:" .. sender, 5) then return end
    local root = Root(false)
    if not root then return end
    for i = 1, MAX_DIGEST_ITEMS do
        local item = msg.w[i]
        if item == nil then break end
        if type(item) == "string" and #item <= MAX_ITEM_LEN then SendItem(root, item, sender) end
    end
end

local function CleanDigest(d)
    if type(d) ~= "table" then return nil end
    local out, n = {}, 0
    for item, h in pairs(d) do
        n = n + 1
        if n > MAX_DIGEST_ITEMS then return nil end
        if type(item) ~= "string" or #item > MAX_ITEM_LEN or not item:find("^%u:") then return nil end
        if type(h) ~= "string" or #h > 8 then return nil end
        out[item] = h
    end
    return out
end

local function OnDigest(sender, msg, dist)
    if dist ~= "GUILD" then return end
    local to = WireKey(msg.to)
    if not to then return end
    if not Util.IsMe(to) then
        roundSeen[to] = { at = GetTime() }
        return
    end
    if GetTime() - answeredAt < ROUND_WINDOW then return end
    local theirs = CleanDigest(msg.d)
    if not theirs then return end
    answeredAt = GetTime()
    local root = Root(true)
    if not root then return end
    local mine = Events:GetDigest()
    local want, give = {}, {}
    for item, h in pairs(theirs) do
        if mine[item] ~= h then want[#want + 1] = item end
    end
    for item, h in pairs(mine) do
        if theirs[item] ~= h then give[#give + 1] = item end
    end
    tsort(want)
    tsort(give)
    if #want > 0 then Send({ t = "EVW", w = want }, "WHISPER", sender, "ctrl") end
    for _, item in ipairs(give) do SendItem(root, item, sender) end
end

local function OnClaim(sender, msg, dist)
    if dist ~= "GUILD" then return end
    local to = WireKey(msg.to)
    if to and not Util.IsMe(to) then roundSeen[to] = { at = GetTime() } end
end

-- Sync calls this for every HELLO on GUILD (ed = the sender's events hash; nil from older clients).
function Events:OnHelloDigest(sender, ed)
    if type(ed) ~= "string" or #ed > 8 or type(sender) ~= "string" then return end
    local mine = self:GetDigestHash()
    if mine == "0" or ed == mine then return end
    if not RateLimit("EVDh:" .. sender, ROUND_WINDOW) then return end
    local delay = self:AmIReviewer() and DELAY_REVIEWER or DELAY_MEMBER
    local Comm = ns.Comm
    local queued = Comm and Comm.Backlog and Comm:Backlog("data") or 0
    local busy = queued > 0 and min(12, 6 + queued / 240) or 0
    busy = max(busy, ROUND_WINDOW - (GetTime() - answeredAt))
    Util.RandomDelay(delay[1] + busy, delay[2] + busy, function()
        local h = Events:GetDigestHash()
        local seen = roundSeen[sender]
        if h == "0" or (seen and GetTime() - seen.at < ROUND_WINDOW) then return end
        roundSeen[sender] = { at = GetTime() }
        Send({ t = "EVK", to = sender }, "GUILD", nil, "live")
        Send({ t = "EVD", to = sender, h = h, d = Events:GetDigest() }, "GUILD", nil, "data")
    end)
end

---------------------------------------------------------------------------
-- Retention
---------------------------------------------------------------------------

function Events:Prune(now)
    local root = Root(false)
    if not root then return end
    now = now or Now()
    local changed = false
    for kind in pairs(KINDS) do
        for id, r in pairs(root[kind]) do
            local drop = false
            -- (a deleted result is remembered as long as results are kept: a member back from a long break must not
            -- bring it back)
            if r.del and r.rev < now - (kind == "R" and RESULT_KEEP or TOMBSTONE_KEEP) then drop = true end
            if kind == "O" and not r.del and (r.at or 0) < now - OCC_KEEP then drop = true end
            if kind == "R" and not r.del and (r.at or 0) < now - RESULT_KEEP then drop = true end
            if drop then root[kind][id] = nil; changed = true end
        end
    end
    for id, j in pairs(root.J) do
        local o = root.O[j.o]
        if not o or (not o.del and (o.at or 0) < now - SIGNUP_KEEP) then root.J[id] = nil; changed = true end
    end
    -- reviews of events gone from the library (and the ranked copies a reviewer kept of them)
    for id in pairs(root.K) do
        if not root.D[id] then root.K[id] = nil; changed = true end
    end
    local db, g = ns.db, GuildKey()
    local snaps = db and db.eventSnaps and g and db.eventSnaps[g]
    for id in pairs(snaps or {}) do
        local d = root.D[id]
        if not d or d.del then snaps[id] = nil end
    end
    if changed then Changed() end
end

---------------------------------------------------------------------------
-- Demo mode: a guild with a library, a live cup, the week's events, results and a season
---------------------------------------------------------------------------

function Events:BuildDemo()
    local D = ns.Demo
    local names = D and D.GetMembers and D:GetMembers() or {}
    local me = Me() or "Me-Realm"
    demo = {}
    for k in pairs(KINDS) do demo[k] = {} end
    local now = Now()
    local function pick(i) return names[((i - 1) % math.max(1, #names)) + 1] or me end
    local starter = B():Starter()
    starter.id, starter.by, starter.rev, starter.at = "edemo1", pick(1), now - 3 * DAY, now - 3 * DAY
    demo.D[starter.id] = starter
    demo.K[starter.id] = { id = starter.id, by = pick(2), rev = now - 2 * DAY, dr = starter.rev, ok = true }
    local function lib(id, name, icon, art, by, kinds, rev)
        local d = B():Blank(name)
        d.id, d.by, d.rev, d.at, d.icon, d.art = id, by, rev, rev, icon, art
        for i, k in ipairs(kinds) do
            d.blocks["b" .. i] = { kind = k, stage = "s1", x = 20, y = 20 + 260 * (i - 1), set = B():SmartDefaults(k) }
        end
        demo.D[id] = d
        return d
    end
    lib("edemo2", "2v2 arena cup", "Interface\\Icons\\Achievement_Arena_2v2_7", "blades", pick(1), { "signup", "bracket" },
        now - 6 * DAY)
    demo.K.edemo2 = { id = "edemo2", by = pick(2), rev = now - 5 * DAY, dr = now - 6 * DAY, ok = true }
    -- mine, in review: the hide and seek example (tags, a touch, a play area, a Hint button), played in Shattrath
    local mine = B():Example("hide")
    if mine then
        mine.name = "Hide and seek in Shattrath"
        if type(mine.places) == "table" and mine.places.pc1 then
            mine.places.pc1 = { n = "Play area", map = 1955, x = 0.52, y = 0.46, r = 250, z = "Shattrath City",
                sz = "Terrace of Light" }
        end
        mine.id, mine.by, mine.rev, mine.at = "edemo3", me, now - 1 * DAY, now - 1 * DAY
        demo.D.edemo3 = mine
    else
        mine = lib("edemo3", "Hide and seek in Shattrath", "Interface\\Icons\\Ability_Stealth", "eots", me, { "signup" },
            now - 1 * DAY)
    end
    mine.review = { rev = mine.rev, at = now - 1 * DAY, note = "Seekers get 5 minutes per round." }
    lib("edemo4", "Ring of Blood night", "Interface\\Icons\\Ability_Warrior_Challange", "ruins", pick(3),
        { "signup", "bracket" }, now - 9 * DAY)
    -- the live cup and the week
    local function occ(id, def, at, by, ranked)
        demo.O[id] = { id = id, by = by, h = by, rev = now - DAY, def = Copy(def), dk = def.id, dr = def.rev, at = at,
            where = "Ring of Trials, Nagrand", ranked = ranked }
    end
    occ("odemo1", starter, now - 40 * 60, pick(1), true)
    occ("odemo2", demo.D.edemo2, now + 3 * DAY, pick(1), true)
    occ("odemo3", demo.D.edemo4, now + 5 * DAY + 3600, pick(3), nil)
    for i = 1, math.min(12, #names) do
        local k = names[i]
        demo.J["odemo2/" .. k] = { id = "odemo2/" .. k, by = k, rev = now, o = "odemo2", on = i <= 7, at = now - i * 600 }
    end
    -- last week's cup: a result
    local function res(id, at, champ, second, third, pts)
        demo.R[id] = { id = id, by = pick(1), rev = at + 7200, name = "Friday duel cup", icon = starter.icon, art = "nagrand",
            at = at, t1 = at + 7900, ranked = true, n = 14, champ = champ, second = second, third = third, points = pts,
            badges = { { p = champ, n = "Duel champion", i = "Interface\\Icons\\Ability_Warrior_Challange", f = "gold",
                ti = "the Duelist" }, { p = second, n = "Runner-up", i = "Interface\\Icons\\Ability_Parry", f = "silver" },
                { p = third, n = "Third place", i = "Interface\\Icons\\INV_Jewelry_Talisman_07", f = "bronze" } },
            moments = {}, last4 = {}, hosts = { pick(1) }, nums = { matches = 13, duels = 31, longest = 372 } }
    end
    local pts1, pts2 = {}, {}
    for i = 1, math.min(10, #names) do
        pts1[names[i]] = 60 - i * 5
        pts2[names[i]] = 45 - i * 3
    end
    pts1[me] = 40
    res("rdemo1", now - 7 * DAY, pick(2), me, pick(4), pts1)
    res("rdemo2", now - 14 * DAY, pick(3), pick(2), me, pts2)
    demo.O.rdemo1 = { id = "rdemo1", by = pick(1), h = pick(1), rev = now - 8 * DAY, def = Copy(starter), dk = starter.id,
        at = now - 7 * DAY, ranked = true }
    -- the new kinds on the calendar: a fishing derby in two days (with sign-ups) and a trivia night later in the week,
    -- copies of the examples (not in the library); and the derby of ten days ago, its Fish table in the result
    local fish, quiz = B():Example("fish"), B():Example("quiz")
    if fish then
        fish.id, fish.by, fish.rev = "edemo5", pick(4), now - 12 * DAY
        occ("odemo4", fish, now + 2 * DAY + 1800, pick(4), nil)
        demo.O.odemo4.dk, demo.O.odemo4.where = nil, "Booty Bay docks"
        for i = 1, math.min(9, #names) do
            local k = names[#names - i + 1]
            demo.J["odemo4/" .. k] = { id = "odemo4/" .. k, by = k, rev = now, o = "odemo4", on = true, at = now - i * 900 }
        end
        local rows, ptsF = {}, {}
        for i = 1, math.min(9, #names) do
            rows[names[i + 1] or me] = 31 - i * 3
            ptsF[names[i + 1] or me] = (i <= 3 and ({ 30, 20, 10 })[i] or 0) + 5
        end
        rows[me], ptsF[me] = 12, 5
        local at = now - 10 * DAY
        demo.R.rdemo3 = { id = "rdemo3", by = pick(4), rev = at + 2400, name = "Fishing derby", icon = fish.icon, art = fish.art,
            at = at, t1 = at + 2200, ranked = true, n = 10, points = ptsF,
            badges = { { p = pick(2), n = "Angler of the night", i = "Interface\\Icons\\Trade_Fishing", f = "gold", ti = "the Angler" },
                { p = pick(3), n = "Runner-up", i = "Interface\\Icons\\INV_Fishingpole_02", f = "silver" },
                { p = pick(4), n = "Third place", i = "Interface\\Icons\\INV_Misc_Fish_37", f = "bronze" } },
            moments = { { at = at + 900, text = Util.ShortName(pick(6)) .. " fished up Mr. Pinchy" },
                { at = at + 1500, text = Util.ShortName(pick(2)) .. " leads with 21 fish" } },
            last4 = {}, hosts = { pick(4) }, nums = {}, mw = {},
            scores = { { id = "sc1", n = "Fish", high = true, fmt = "num", v = rows } } }
        demo.O.rdemo3 = { id = "rdemo3", by = pick(4), h = pick(4), rev = at - DAY, def = Copy(fish), at = at, ranked = true }
    end
    if quiz then
        quiz.id, quiz.by, quiz.rev = "edemo6", pick(5), now - 2 * DAY
        occ("odemo5", quiz, now + 4 * DAY + 7200, pick(5), nil)
        demo.O.odemo5.dk, demo.O.odemo5.where = nil, "Scryer's Tier, Shattrath"
    end
    -- (the examples are part 2's already; a def made another way is brought up to them)
    local Bk = B()
    if Bk.Migrate then
        for _, d in pairs(demo.D) do pcall(Bk.Migrate, Bk, d) end
        for _, o in pairs(demo.O) do pcall(Bk.Migrate, Bk, o.def) end
    end
    return demo
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Events:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("EVU", OnUpdate)
        Comm:Register("EVD", OnDigest)
        Comm:Register("EVK", OnClaim)
        Comm:Register("EVW", OnWant)
        Comm:Register("EVG", OnGive)
        if Comm.AllowLarge then
            for _, t in ipairs({ "EVU", "EVG", "EVD" }) do Comm:AllowLarge(t, "data") end
        end
    end
    ns:On("DEMO_TOGGLED", function(on)
        if not on then demo = nil end
        Changed()
    end)
    ns:On("CONFIG_UPDATED", function() Events.rankCache = nil; Changed() end)
end

-- Every stored event (the library's, the calendar's copies, a reviewer's ranked copies) in part 2's pieces, once.
function Events:MigrateStored()
    local db, Bk = ns.db, B()
    if not (db and Bk and Bk.Migrate) then return end
    local function migrate(d)
        if type(d) == "table" and not d.del then pcall(Bk.Migrate, Bk, d) end
    end
    for _, root in pairs(type(db.events) == "table" and db.events or {}) do
        for _, d in pairs(type(root) == "table" and type(root.D) == "table" and root.D or {}) do migrate(d) end
        for _, o in pairs(type(root) == "table" and type(root.O) == "table" and root.O or {}) do
            if type(o) == "table" then migrate(o.def) end
        end
    end
    for _, snaps in pairs(type(db.eventSnaps) == "table" and db.eventSnaps or {}) do
        for _, d in pairs(type(snaps) == "table" and snaps or {}) do migrate(d) end
    end
end

function Events:OnLogin()
    self:MigrateStored()
    local function Daily()
        Events:Prune()
        Util.After(DAY / 4, Daily)
    end
    -- First prune 20-40 s after the login, spread per character. Not drawn from math.random: every module shares
    -- that sequence (the test harness seeds it per client), and a draw at every login, events or not, would shift the
    -- delay each other module picks (Patch.lua and Guild.lua's OwnJitter keep their own jitter for the same reason).
    local n = Util.Adler32((Util.PlayerKey() or "?") .. "events-prune" .. tostring(Now()))
    Util.After(20 + (n % 1000) / 50, Daily)
end
