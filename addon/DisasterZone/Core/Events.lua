if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Events.lua", ...) then return end -- DisasterZone: the guild's events (the Events tab's data).
-- Everything about events that is stored and synced guild-wide (the live run itself: Core/EventLive.lua):
--   D  the library: events members built (Core/EventBlocks.lua's defs). Only their creator edits one; the creator or
--      the GM / an officer deletes it. A copy is a new event with its own creator.
--   K  reviews: the GM, an officer or the guild council marks an event ranked (or sends it back) for one revision of
--      it; an edit makes a new revision, which is not ranked until reviewed again.
--   O  events on the calendar: an event (a copy of its def as it was) at a time, hosted by who put it there.
--   J  sign-ups: one per member and calendar event, written by the member.
--   R  results: what a finished event decided (placings, badges, season points, moments), written by its host.
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
local OCC_KEEP = 60 * DAY          -- calendar events (and their sign-ups) are kept this long after their day
local RESULT_KEEP = 400 * DAY
local MAX_DEFS = 200
local MAX_OWN = 30
local MAX_OCC = 120
local MAX_DIGEST_ITEMS = 1200
local MAX_ID_LEN = 40
local MAX_KEY_LEN = 48
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

-- The GM and the officers: they delete anyone's event, cancel anyone's calendar event, set the season.
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

---------------------------------------------------------------------------
-- Cleaning what arrives (and what is saved): known shapes, bounded sizes
---------------------------------------------------------------------------

local function Str(s, maxLen)
    if type(s) ~= "string" then return nil end
    s = s:gsub("[%c|]", "")
    if #s > (maxLen or MAX_TEXT) then s = strsub(s, 1, maxLen or MAX_TEXT) end
    return s
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
        if type(n) == "table" and Str(n.text) then
            out.notes[#out.notes + 1] = { st = Str(n.st, 12) or "*", x = Int(n.x, -4000, 4000) or 0, y = Int(n.y, -4000, 4000) or 0,
                text = Str(n.text) }
        end
    end
    if type(d.review) == "table" and Int(d.review.rev, 0) then
        out.review = { rev = Int(d.review.rev, 0), at = Int(d.review.at, 0) or 0, note = Str(d.review.note) }
    end
    return out
end

local function CleanRecord(kind, r)
    if type(r) ~= "table" or not IsId(r.id) then return nil end
    local by = WireKey(r.by)
    if not by then return nil end
    local rev = Int(r.rev, 0)
    if not rev or rev > Now() + 600 then return nil end
    if kind == "D" then
        local d = Events:CleanDef(r)
        if d then d.rev = rev end
        return d
    elseif kind == "K" then
        return { id = r.id, by = by, rev = rev, dr = Int(r.dr, 0) or 0, ok = r.ok and true or false, note = Str(r.note) }
    elseif kind == "O" then
        if r.del then return { id = r.id, by = by, rev = rev, del = true, h = WireKey(r.h) } end
        local d = type(r.def) == "table" and Events:CleanDef(r.def)
        if not d then return nil end
        return { id = r.id, by = by, h = WireKey(r.h) or by, rev = rev, def = d, dk = IsId(r.dk) and r.dk or nil, dr = Int(r.dr, 0),
            at = Int(r.at, 0) or 0, where = Str(r.where, 48), note = Str(r.note), ranked = r.ranked and true or nil,
            cancel = r.cancel and (Str(r.cancel, 80) or "Cancelled") or nil }
    elseif kind == "J" then
        local occ, who = r.id:match("^(.+)/(.+)$")
        if not occ or WireKey(who) ~= by then return nil end
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
        return out
    elseif kind == "C" then
        if r.id ~= "season" then return nil end
        return { id = "season", by = by, rev = rev, n = Str(r.n, 32) or "Season", from = Int(r.from, 0) or 0,
            to = Int(r.to, 0) or 0 }
    elseif kind == "T" then
        if WireKey(r.id) ~= by then return nil end
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

local function Merge(root, kind, rec)
    local t = root[kind]
    local cur = t[rec.id]
    if kind == "D" then
        if cur and not cur.del and cur.by ~= rec.by and not (rec.del and Events:CanModerate(rec.by)) then
            return false   -- only its creator edits it; a moderator may delete it
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
        -- h is its host (who put it on the calendar), by its last writer: the host, or a moderator cancelling it
        if cur and not cur.del then
            local host = cur.h or cur.by
            if rec.h and rec.h ~= host then return false end
            if rec.by ~= host and not ((rec.del or rec.cancel) and Events:CanModerate(rec.by)) then return false end
        elseif not cur and not rec.del and rec.h ~= rec.by then
            return false
        end
        if cur and cur.del and not rec.del then return false end
        if not cur and not rec.del and CountLive(t) >= MAX_OCC then return false end
        if cur and not Newer(rec, cur) and not (rec.del and not cur.del) then return false end
    elseif kind == "R" then
        if rec.del then
            if not (Events:CanModerate(rec.by) or (cur and cur.by == rec.by)) then return false end
        else
            local occ = root.O[rec.id]
            local host = occ and (occ.h or occ.by)
            -- the event's host writes its result; a host who took over names the chain from the first host
            if occ and not occ.del and rec.by ~= host then
                if not (rec.hosts[1] == host and rec.hosts[#rec.hosts] == rec.by) then return false end
            end
        end
        if cur and cur.del and not rec.del then return false end
        if cur and not Newer(rec, cur) and not (rec.del and not cur.del) then return false end
    elseif kind == "C" then
        if not Events:CanModerate(rec.by) then return false end
        if cur and not Newer(rec, cur) then return false end
    else   -- J, T: written by the member themself (CleanRecord checked the id)
        if cur and not Newer(rec, cur) then return false end
    end
    t[rec.id] = rec
    return true
end

local function StoreRecord(kind, r)
    if not KINDS[kind] then return false end
    local root = Root(true)
    if not root then return false end
    local rec = CleanRecord(kind, r)
    if not rec then return false end
    return Merge(root, kind, rec)
end

-- My own change: stored (merged like anyone's), then sent to the guild.
local function Commit(kind, rec)
    if DemoOn() then
        local st = State()
        st[kind][rec.id] = rec
        Changed()
        return true
    end
    rec.by = rec.by or Me()
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
    if not Merge(Root(true), kind, clean) then return false end
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
    if not d or not (d.by == Me() or self:CanModerate(Me())) then return false end
    return Commit("D", { id = id, by = Me(), name = d.name, del = true })
end

-- A review of an event: the newest one for it, or nil.
function Events:GetReview(defId)
    local st = State()
    return st and st.K[defId] or nil
end

-- "ranked" (this revision was marked ranked), "review" (sent in, waiting), "back" (sent back for this revision),
-- "changed" (ranked before, edited since), "draft".
function Events:ReviewState(d)
    if not d then return "draft" end
    local k = self:GetReview(d.id)
    if k and k.dr == d.rev then return k.ok and "ranked" or "back" end
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

-- Events sent in and not decided for their current revision (the Review view), oldest first.
function Events:GetReviewQueue()
    local out = {}
    for _, d in ipairs(self:GetDefs()) do
        if self:ReviewState(d) == "review" then out[#out + 1] = d end
    end
    tsort(out, function(a, b) return (a.review.at or 0) < (b.review.at or 0) end)
    return out
end

-- Recent decisions (the Review view's second list), newest first.
function Events:GetDecided(limit)
    local st = State()
    local out = {}
    for id, k in pairs(st and st.K or {}) do
        local d = self:GetDef(id)
        if d then out[#out + 1] = { d = d, k = k } end
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

-- Puts one of the library's events on the calendar (I host it): a copy of the event as it is now.
function Events:Schedule(defId, at, opts)
    local d = self:GetDef(defId)
    if not d then return nil end
    local id = NewId("o")
    local ok = Commit("O", { id = id, by = Me(), h = Me(), def = Copy(d), dk = d.id, dr = d.rev, at = floor(tonumber(at) or Now()),
        where = opts and opts.where, note = opts and opts.note, ranked = self:IsRanked(d) or nil })
    if ok then
        -- the host is in it unless they say otherwise
        if not (opts and opts.noJoin) then self:SignUp(id, true) end
        return id
    end
    return nil
end

function Events:GetOcc(id)
    local st = State()
    local o = st and st.O[id]
    if o and not o.del then return o end
    return nil
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
    return o ~= nil and (self:HostOf(o) == Me() or self:CanModerate(Me()))
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

-- The host moves their event (a new time / place / note).
function Events:EditOcc(id, at, where, note)
    local o = self:GetOcc(id)
    if not o or self:HostOf(o) ~= Me() then return false end
    local rec = Copy(o)
    rec.by = Me()
    rec.at = floor(tonumber(at) or o.at)
    rec.where = where
    rec.note = note
    return Commit("O", rec)
end

function Events:SignUp(occId, on)
    local o = self:GetOcc(occId)
    if not o then return false end
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
    local rec = { id = occId, by = Me(), name = d.name, icon = d.icon, art = d.art, at = st.t0 or Now(), t1 = st.t1 or Now(),
        ranked = (o and o.ranked) or nil, dk = o and o.dk, n = #st.entrants, champ = res.champ, second = res.second,
        third = res.third, points = {}, badges = {}, moments = {}, last4 = {}, hosts = hosts or { Me() }, nums = {},
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
    return Commit("R", rec)
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

function Events:DeleteResult(id)
    if not self:CanModerate(Me()) then return false end
    return Commit("R", { id = id, by = Me(), del = true })
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
        r.rank = i
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
    local items = {}
    for kind in pairs(KINDS) do
        for id in pairs(root[kind]) do items[#items + 1] = kind .. ":" .. id end
    end
    tsort(items)
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
    if StoreRecord(msg.k, msg.r) then
        if msg.k == "K" then
            local d = Events:GetDef(msg.r.id)
            if d and msg.r.ok and Events:AmIReviewer() then KeepSnapshot(d) end
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
        if type(item) == "string" and #item <= MAX_ID_LEN + 2 then SendItem(root, item, sender) end
    end
end

local function CleanDigest(d)
    if type(d) ~= "table" then return nil end
    local out, n = {}, 0
    for item, h in pairs(d) do
        n = n + 1
        if n > MAX_DIGEST_ITEMS then return nil end
        if type(item) ~= "string" or #item > MAX_ID_LEN + 2 or not item:find("^%u:") then return nil end
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
            if r.del and r.rev < now - TOMBSTONE_KEEP then drop = true end
            if kind == "O" and not r.del and (r.at or 0) < now - OCC_KEEP then drop = true end
            if kind == "R" and (r.at or 0) < now - RESULT_KEEP then drop = true end
            if drop then root[kind][id] = nil; changed = true end
        end
    end
    for id, j in pairs(root.J) do
        if not root.O[j.o] then root.J[id] = nil; changed = true end
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
    local mine = lib("edemo3", "Hide and seek in Shattrath", "Interface\\Icons\\Ability_Stealth", "eots", me, { "signup" },
        now - 1 * DAY)
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

function Events:OnLogin()
    local function Daily()
        Events:Prune()
        Util.After(DAY / 4, Daily)
    end
    Util.RandomDelay(20, 40, Daily)
end
