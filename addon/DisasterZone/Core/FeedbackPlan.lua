if DisasterZoneBoot and DisasterZoneBoot.Run("Core/FeedbackPlan.lua", ...) then return end -- DisasterZone: the release plan.
-- The developer's plan for the guild's feedback (Core/Feedback.lua): which release each item goes in and how big it
-- is. The developer edits it (in game on the Feedback page's Plan tab, or from the dev kit: dev/tools/feedback.py plan
-- writes Core/DevPlan.lua, which never ships, and the developer's client takes it in at the next /reload); the
-- officers see it read-only; the guild sees only "Coming next": the releases the developer shows, with the guild's
-- items planned in them (no sizes, no notes, none of the developer's own items).
--
-- Data (SavedVariables db.feedbackPlan[guildKey], account wide):
--   plan   = { rev, rel = { [version] = release }, it = { [key] = entry } }   (the developer's; a copy on staff)
--     release { th = theme, dt = target date (a time), bg = budget (hours), pub = 1 (the guild sees it), done = when
--               it was released, x = 1 (deleted), u = when it last changed }
--     entry   key = a feedback item's id ("Name-Realm#3") or one of the developer's own items ("D-4")
--             { rl = version | "later", sz = "S" | "M" | "L" | "XL", g = group, nt = note, x = 1 (taken off the plan),
--               u; the developer's own items also tt = title, kd = kind, at = created, dn = when it was done }
--   coming = { rev, l = { { v, th, dt, n = { item ids } } } }   what the guild sees (built by the developer's client)
--   sent   = the coming rev the developer's client last told the guild
-- Every release and entry carries u: the newer one wins when the dev kit's file and the saved plan meet, so an edit in
-- game and an edit in the dev kit never undo each other. rev = the newest u: a copy with a higher rev replaces a
-- staff member's copy whole.
--
-- Messages (prefix CDLb, class "fb"; only from staff):
--   FBP  { p = plan }            WHISPER to staff: the developer's plan (after a change, and when one asks)
--   FBC  { c = coming }          GUILD (the developer, after a change) or WHISPER (an answer): Coming next
--   FBPH { pr = rev, cr = rev }  WHISPER to a staff member after login: what I hold (pr only from staff)
local addonName, ns = ...

local Plan = ns:NewModule("FeedbackPlan")
local Util = ns.Util

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat
local strmatch, strsub, strfind = string.match, string.sub, string.find

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local SIZES = { "S", "M", "L", "XL" }
local SIZE_H = { S = 1, M = 3, L = 8, XL = 12 }      -- the hours a size stands for (the budget bars)
local SIZE_INFO = {
    S = { label = "S", hint = "under 1 h" }, M = { label = "M", hint = "2-4 h" },
    L = { label = "L", hint = "about a day" }, XL = { label = "XL", hint = "several days" },
}
local LATER = "later"
local DEV_KINDS = { idea = true, change = true, bug = true, chore = true }
local TITLE_MAX, NOTE_MAX, THEME_MAX, GROUP_MAX, VER_MAX, KEY_MAX = 80, 120, 40, 30, 12, 140
local MAX_ENTRIES = 400
local MAX_RELEASES = 30
local COMING_MAX = 6            -- releases the guild sees
local COMING_ITEMS = 40         -- items per release the guild sees
local MAX_TIME = 2147483647
local HELLO_DELAY = 40          -- seconds after login (after the feedback's own sync)
local ANSWER_LIMIT = 60

Plan.SIZES, Plan.SIZE_H, Plan.SIZE_INFO, Plan.LATER = SIZES, SIZE_H, SIZE_INFO, LATER

local Now, IsInt = Util.Now, Util.IsInt
local function F() return ns.Feedback end
local function DemoOn() return Util.DemoOn() end
local function Comm() return ns.Comm end

---------------------------------------------------------------------------
-- Checks
---------------------------------------------------------------------------

local function ValidVer(v)
    return type(v) == "string" and #v <= VER_MAX and strmatch(v, "^%d+[%.%d]*$") ~= nil
end
Plan.ValidVer = ValidVer

local function Str(v, maxLen)
    return v == nil or (type(v) == "string" and #v <= maxLen)
end

local function IsDevKey(key) return type(key) == "string" and strmatch(key, "^D%-%d+$") ~= nil end
Plan.IsDevKey = IsDevKey

local function ValidKey(key)
    return type(key) == "string" and #key <= KEY_MAX and (IsDevKey(key) or strfind(key, "#%d+$") ~= nil)
end

local function ValidRelease(r)
    return type(r) == "table" and IsInt(r.u, 1, MAX_TIME) and Str(r.th, THEME_MAX)
        and (r.dt == nil or IsInt(r.dt, 1, MAX_TIME)) and (r.bg == nil or IsInt(r.bg, 0, 999))
        and (r.pub == nil or r.pub == 1) and (r.done == nil or IsInt(r.done, 1, MAX_TIME))
        and (r.x == nil or r.x == 1)
end

local function ValidEntry(key, e)
    if type(e) ~= "table" or not IsInt(e.u, 1, MAX_TIME) then return false end
    if not (e.rl == nil or e.rl == LATER or ValidVer(e.rl)) then return false end
    if not (e.sz == nil or SIZE_H[e.sz]) then return false end
    if not (Str(e.g, GROUP_MAX) and Str(e.nt, NOTE_MAX) and (e.x == nil or e.x == 1)) then return false end
    if IsDevKey(key) then
        return Str(e.tt, TITLE_MAX) and (e.kd == nil or DEV_KINDS[e.kd] ~= nil)
            and (e.at == nil or IsInt(e.at, 1, MAX_TIME)) and (e.dn == nil or IsInt(e.dn, 1, MAX_TIME))
    end
    return e.tt == nil and e.kd == nil and e.dn == nil
end

-- Is p a well-formed plan (the wire's or the dev kit file's)?
local function ValidPlan(p)
    if type(p) ~= "table" or not IsInt(p.rev, 0, MAX_TIME) or type(p.rel) ~= "table" or type(p.it) ~= "table" then
        return false
    end
    local n = 0
    for v, r in pairs(p.rel) do
        n = n + 1
        if n > MAX_RELEASES or not ValidVer(v) or not ValidRelease(r) then return false end
    end
    n = 0
    for key, e in pairs(p.it) do
        n = n + 1
        if n > MAX_ENTRIES or not ValidKey(key) or not ValidEntry(key, e) then return false end
    end
    return true
end
Plan.ValidPlan = ValidPlan

local function ValidComing(c)
    if type(c) ~= "table" or not IsInt(c.rev, 0, MAX_TIME) or type(c.l) ~= "table" or #c.l > COMING_MAX then return false end
    for _, r in ipairs(c.l) do
        if type(r) ~= "table" or not ValidVer(r.v) or not Str(r.th, THEME_MAX) or not (r.dt == nil or IsInt(r.dt, 1, MAX_TIME))
            or type(r.n) ~= "table" or #r.n > COMING_ITEMS then return false end
        for _, id in ipairs(r.n) do
            if not (ValidKey(id) and not IsDevKey(id)) then return false end
        end
    end
    return true
end
Plan.ValidComing = ValidComing

---------------------------------------------------------------------------
-- Store
---------------------------------------------------------------------------

local demoStore

local function Bucket(create)
    local gk = IsInGuild() and Util.GuildKey() or nil
    if not gk then return nil end
    return ns.DB:GuildBucket("feedbackPlan", create, gk)
end

local function Store(create, real)
    if not real and DemoOn() then return Plan:DemoStore() end
    return Bucket(create)
end

local function NewPlan() return { rev = 0, rel = {}, it = {} } end

-- The plan I read (create: make it when missing), or nil.
local function GetPlan(create, real)
    local s = Store(create, real)
    if not s then return nil end
    if type(s.plan) ~= "table" then
        if not create then return nil end
        s.plan = NewPlan()
    end
    local p = s.plan
    if type(p.rel) ~= "table" then p.rel = {} end
    if type(p.it) ~= "table" then p.it = {} end
    p.rev = tonumber(p.rev) or 0
    return p
end

local function GetComing(real)
    local s = Store(false, real)
    local c = s and s.coming
    return type(c) == "table" and c or nil
end

local function Copy(t)
    local o = {}
    for k, v in pairs(t) do o[k] = type(v) == "table" and Copy(v) or v end
    return o
end

local function Changed()
    ns:Fire("FEEDBACK_PLAN_UPDATED")
end

-- The newest u in a plan.
local function NewestU(p)
    local r = 0
    for _, part in ipairs({ p.rel, p.it }) do
        for _, e in pairs(part) do if (tonumber(e.u) or 0) > r then r = e.u end end
    end
    return r
end

-- Takes src's releases and entries that are newer than dst's (per release / entry). Returns true when dst changed.
local function MergeInto(dst, src)
    local changed = false
    for _, part in ipairs({ "rel", "it" }) do
        for k, e in pairs(src[part] or {}) do
            local cur = dst[part][k]
            if not cur or (tonumber(e.u) or 0) > (tonumber(cur.u) or 0) then
                dst[part][k] = Copy(e)
                changed = true
            end
        end
    end
    if changed then dst.rev = max(dst.rev or 0, NewestU(dst)) end
    return changed
end
Plan.MergeInto = MergeInto

---------------------------------------------------------------------------
-- Who may do what
---------------------------------------------------------------------------

-- The developer edits the plan (demo mode: anyone, on the demo plan).
function Plan:CanEdit()
    if DemoOn() then return true end
    local Fb = F()
    return Fb and Fb:AmIDev() or false
end

-- Staff see the plan (the Plan tab); the rest of the guild only Coming next.
function Plan:CanSee()
    local Fb = F()
    return Fb and Fb:AmIStaff() or false
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

local function Live(e) return e and e.x ~= 1 end

function Plan:Entry(key)
    local p = GetPlan(false)
    local e = p and p.it[key]
    return Live(e) and e or nil
end

function Plan:Release(v)
    local p = GetPlan(false)
    local r = p and p.rel[v]
    return Live(r) and r or nil
end

local function ByVersion(a, b)
    local c = Util.CompareVersions(a.v, b.v)
    if c ~= 0 then return c < 0 end
    return a.v < b.v
end

-- The releases, oldest first: { { v, th, dt, bg, pub, done } }. withDone: the released ones too.
function Plan:Releases(withDone)
    local p = GetPlan(false)
    local out = {}
    for v, r in pairs(p and p.rel or {}) do
        if Live(r) and (withDone or not r.done) then
            out[#out + 1] = { v = v, th = r.th, dt = r.dt, bg = r.bg, pub = r.pub == 1, done = r.done }
        end
    end
    tsort(out, ByVersion)
    return out
end

-- The first open release after v (nil: the first open one), or nil.
function Plan:NextRelease(after)
    for _, r in ipairs(self:Releases()) do
        if not after or Util.CompareVersions(r.v, after) > 0 then return r end
    end
    return nil
end

-- A card's view of a plan entry or an open item: { key, dev, item, kind, text, no, author, votes, sz, g, nt, rl,
-- done (shipped / a dev item done), closed }.
local function CardOf(key, e)
    local c = { key = key, sz = e and e.sz, g = e and e.g, nt = e and e.nt, rl = e and e.rl }
    if IsDevKey(key) then
        c.dev, c.kind, c.text, c.at = true, e.kd or "idea", e.tt or "?", e.at
        c.done = e.dn ~= nil
        c.dno = tonumber(strmatch(key, "%d+"))     -- (the D number: never a feedback number)
        return c
    end
    local item = F():Get(key)
    if not item or item.state == "removed" then return nil end
    c.item, c.kind, c.text, c.no, c.author, c.votes, c.at = item, item.kind, item.text, item.no, item.author,
        item.voteCount, item.at
    c.done = item.state == "done"
    c.closed = item.closed
    return c
end
Plan.CardOf = CardOf

local function CardOrder(a, b)
    if (a.done and true or false) ~= (b.done and true or false) then return not a.done end
    if (a.g or "") ~= (b.g or "") then
        if not a.g then return false end
        if not b.g then return true end
        return a.g < b.g
    end
    local sa, sb = SIZE_H[a.sz or ""] or 99, SIZE_H[b.sz or ""] or 99
    if (a.votes or 0) ~= (b.votes or 0) then return (a.votes or 0) > (b.votes or 0) end
    if sa ~= sb then return sa < sb end
    return a.key < b.key
end

-- The cards of a column: rl = a version, LATER, or nil ("To sort": open items nobody placed yet).
function Plan:Cards(rl)
    local p = GetPlan(false)
    local out = {}
    if rl == nil then
        for _, item in ipairs(F():List({ open = true }, "asked")) do
            local e = p and p.it[item.id]
            local placed = Live(e) and e.rl ~= nil and (e.rl == LATER or self:Release(e.rl) ~= nil)
            if not placed and item.kind ~= "love" then
                out[#out + 1] = CardOf(item.id, Live(e) and e or nil)
            end
        end
        return out
    end
    for key, e in pairs(p and p.it or {}) do
        if Live(e) and e.rl == rl then
            local c = CardOf(key, e)
            -- (an item closed some other way than shipping leaves the plan's columns)
            if c and not (c.closed and not c.done) then out[#out + 1] = c end
        end
    end
    tsort(out, CardOrder)
    return out
end

-- The hours a column holds (sizes; done and unsized cards count nothing), and how many cards have no size.
function Plan:Load(rl)
    local h, unsized = 0, 0
    for _, c in ipairs(self:Cards(rl)) do
        if not c.done then
            if c.sz then h = h + SIZE_H[c.sz] else unsized = unsized + 1 end
        end
    end
    return h, unsized
end

-- The groups in use (sorted names).
function Plan:Groups()
    local p = GetPlan(false)
    local set, out = {}, {}
    for _, e in pairs(p and p.it or {}) do
        if Live(e) and e.g and not set[e.g] then set[e.g] = true; out[#out + 1] = e.g end
    end
    tsort(out)
    return out
end

-- The planned release of a feedback item for anyone: staff from the plan, everyone else from Coming next.
-- Returns the version and its release view, or nil.
function Plan:PlannedFor(id)
    if self:CanSee() then
        local e = self:Entry(id)
        local r = e and e.rl and e.rl ~= LATER and self:Release(e.rl)
        if r and not r.done then return e.rl, r end
        return nil
    end
    local c = GetComing()
    for _, r in ipairs(c and c.l or {}) do
        for _, n in ipairs(r.n) do
            if n == id then return r.v, r end
        end
    end
    return nil
end

-- Coming next for the Changelog page: { { v, th, dt, items = { item views } } } (open items the guild sees).
function Plan:ComingNext()
    local c
    if self:CanSee() and GetPlan(false) then c = self:BuildComing() else c = GetComing() end
    local out = {}
    for _, r in ipairs(c and c.l or {}) do
        local items = {}
        for _, id in ipairs(r.n) do
            local item = F():Get(id)
            if item and not item.closed then items[#items + 1] = item end
        end
        if #items > 0 then out[#out + 1] = { v = r.v, th = r.th, dt = r.dt, items = items } end
    end
    return out
end

-- The guild's view of the plan, built from it (the developer's client sends it).
function Plan:BuildComing()
    local p = GetPlan(false)
    local c = { rev = p and p.rev or 0, l = {} }
    if not p then return c end
    for _, r in ipairs(self:Releases()) do
        if r.pub and #c.l < COMING_MAX then
            local ids = {}
            for key, e in pairs(p.it) do
                if Live(e) and e.rl == r.v and not IsDevKey(key) then
                    local item = F():Get(key)
                    if item and not item.closed and item.state ~= "removed" then ids[#ids + 1] = key end
                end
            end
            tsort(ids)
            while #ids > COMING_ITEMS do ids[#ids] = nil end
            c.l[#c.l + 1] = { v = r.v, th = r.th, dt = r.dt, n = ids }
        end
    end
    return c
end

---------------------------------------------------------------------------
-- Release check
---------------------------------------------------------------------------

-- A changelog line for a card: the item's first sentence (dev items: the title), cut at 88 characters.
local function DraftText(c)
    local t = Util.Trim((c.text or ""):gsub("\n", " "))
    t = strmatch(t, "^(.-[%.!?])%s") or t
    if #t > 88 then t = strsub(t, 1, 85):gsub("%s+%S*$", "") .. "..." end
    return t
end

-- What a release holds and how far it got: { rows = { { card, shipped = bool } }, done, total, hours, draft = lines }.
-- shipped: a guild item a changelog line names (in this release or an earlier one), or a dev item marked done.
function Plan:Check(v)
    local nums = F().ChangelogNumbers()
    local out = { rows = {}, done = 0, total = 0, hours = 0, draft = {} }
    for _, c in ipairs(self:Cards(v)) do
        local shipped
        if c.dev then shipped = c.done else shipped = c.no ~= nil and nums[c.no] ~= nil end
        out.rows[#out.rows + 1] = { card = c, shipped = shipped and true or false }
        out.total = out.total + 1
        if shipped then out.done = out.done + 1 end
        if c.sz then out.hours = out.hours + SIZE_H[c.sz] end
        if not c.dev and c.no and not nums[c.no] then
            out.draft[#out.draft + 1] = ('{ "%s", fb = { %d } },'):format(DraftText(c):gsub('"', "'"), c.no)
        elseif c.dev and not c.done then
            out.draft[#out.draft + 1] = ('{ "%s" },'):format(DraftText(c):gsub('"', "'"))
        end
    end
    tsort(out.rows, function(a, b)
        if a.shipped ~= b.shipped then return a.shipped end
        return CardOrder(a.card, b.card)
    end)
    return out
end

---------------------------------------------------------------------------
-- Network
---------------------------------------------------------------------------

local function Send(msg, dist, target)
    local C = Comm()
    return (C and C.Send and C:Send(msg, dist, target, "fb")) and true or false
end

-- Online staff running the addon (not me).
local function OnlineStaff()
    local Guild = ns.Guild
    local Sync = ns.Sync
    local out = {}
    if not (Guild and Guild:IsReady()) then return out end
    for _, key in ipairs(Guild:GetOnlineMembers()) do
        if not Util.IsMe(key) and F():IsStaff(key) and (not Sync or not Sync.GetPeer or Sync:GetPeer(key)) then
            out[#out + 1] = key
        end
    end
    tsort(out)
    return out
end

-- The developer's client: tells the officers the plan and the guild Coming next (when it changed).
local function Publish()
    if DemoOn() or not (F() and F():AmIDev()) then return end
    local s = Store(true, true)
    local p = GetPlan(false, true)
    if not (s and p) then return end
    local c = Plan:BuildComing()
    local old = s.coming
    if not (old and Util.Canonical(old.l) == Util.Canonical(c.l)) then
        c.rev = max(p.rev, (old and old.rev or 0) + 1)
        s.coming = c
        Send({ t = "FBC", c = c }, "GUILD")
        s.sent = c.rev
    end
    for _, key in ipairs(OnlineStaff()) do Send({ t = "FBP", p = p }, "WHISPER", key) end
end

local function PublishSoon()
    if DemoOn() then return end
    Util.Debounce("feedback-plan-publish", 3, Publish)
end
Plan.PublishSoon = PublishSoon

local function OnPlan(sender, msg, dist)
    if dist ~= "WHISPER" or not F():IsStaff(sender) or F():AmIDev() then return end
    if not ValidPlan(msg.p) then return end
    local s = Store(true, true)
    local mine = s and GetPlan(false, true)
    if not s or (mine and mine.rev >= msg.p.rev) then return end
    s.plan = msg.p
    Changed()
end

local function OnComing(sender, msg, dist)
    if (dist ~= "GUILD" and dist ~= "WHISPER") or not F():IsStaff(sender) or F():AmIDev() then return end
    if not ValidComing(msg.c) then return end
    local s = Store(true, true)
    local mine = GetComing(true)
    if not s or (mine and (tonumber(mine.rev) or 0) >= msg.c.rev) then return end
    s.coming = msg.c
    Changed()
end

local answered = {}

local function OnHello(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg) ~= "table" then return end
    if not F():AmIStaff() then return end
    local now = GetTime()
    if answered[sender] and now - answered[sender] < ANSWER_LIMIT then return end
    answered[sender] = now
    local c = GetComing(true)
    if c and (tonumber(c.rev) or 0) > (tonumber(msg.cr) or 0) then Send({ t = "FBC", c = c }, "WHISPER", sender) end
    local p = GetPlan(false, true)
    if p and F():IsStaff(sender) and p.rev > (tonumber(msg.pr) or 0) then Send({ t = "FBP", p = p }, "WHISPER", sender) end
end

-- After login: ask a staff member online (the developer first) for what I lack.
local function SayHello()
    if F():AmIDev() then return end
    local staff = OnlineStaff()
    if #staff == 0 then return end
    local pick = staff[1]
    for _, key in ipairs(staff) do if F():IsDev(key) then pick = key end end
    local p = GetPlan(false, true)
    local c = GetComing(true)
    Send({ t = "FBPH", pr = F():AmIStaff() and p and p.rev or nil, cr = c and c.rev or 0 }, "WHISPER", pick)
end

---------------------------------------------------------------------------
-- The dev kit's file (Core/DevPlan.lua: DisasterZoneDevPlan = { gk, p })
---------------------------------------------------------------------------

-- The developer's client takes in what the dev kit wrote (newer releases and entries win). Returns true on a change.
function Plan:TakeFile()
    local file = DisasterZoneDevPlan
    if type(file) ~= "table" or not F():AmIDev() then return false end
    local gk = IsInGuild() and Util.GuildKey() or nil
    if not gk or file.gk ~= gk or not ValidPlan(file.p) then return false end
    local p = GetPlan(true, true)
    if not p then return false end
    local changed = MergeInto(p, file.p)
    if changed then
        Changed()
        self:SyncStatuses()
    end
    return changed
end

---------------------------------------------------------------------------
-- Editing (the developer)
---------------------------------------------------------------------------

-- A changed copy of entry / release `key` in `part` (fields: false clears one), stamped. Returns the new one.
local function Touch(part, key, fields)
    local p = GetPlan(true)
    if not p then return nil end
    local old = p[part][key]
    local e = old and Copy(old) or {}
    for k, v in pairs(fields) do
        if v == false then e[k] = nil else e[k] = v end
    end
    e.u = max(Now(), (old and tonumber(old.u) or 0) + 1)
    p[part][key] = e
    p.rev = max(p.rev, e.u)
    Changed()
    PublishSoon()
    return e
end

local function Need(cond, err)
    if not cond then return false, err end
    return true
end

-- An item put in a release (or Later) is planned: its author sees "Planned".
local function MarkPlanned(key)
    if IsDevKey(key) then return end
    local item = F():Get(key)
    if item and not item.closed and item.state ~= "planned" then F():SetState(key, "planned") end
end

-- Every placed item planned (after the dev kit's file came in).
function Plan:SyncStatuses()
    local p = GetPlan(false)
    for key, e in pairs(p and p.it or {}) do
        if Live(e) and e.rl and (e.rl == LATER or self:Release(e.rl)) then MarkPlanned(key) end
    end
end

-- Creates or changes a release: fields { th, dt, bg, pub (bool), done } (false clears).
function Plan:SetRelease(v, fields)
    if not self:CanEdit() then return false, "only the developer plans releases" end
    if not ValidVer(v) then return false, "a version is numbers and dots: 1.6.0" end
    local f = {}
    if fields.th ~= nil then f.th = fields.th and strsub(Util.Trim(fields.th), 1, THEME_MAX) or false end
    if fields.dt ~= nil then f.dt = fields.dt or false end
    if fields.bg ~= nil then f.bg = fields.bg and max(0, min(999, floor(fields.bg))) or false end
    if fields.pub ~= nil then f.pub = fields.pub and 1 or false end
    if fields.done ~= nil then f.done = fields.done or false end
    f.x = false
    Touch("rel", v, f)
    return true
end

function Plan:DeleteRelease(v)
    if not self:CanEdit() then return false, "only the developer plans releases" end
    if not self:Release(v) then return false, "no such release" end
    Touch("rel", v, { x = 1 })
    return true
end

-- Puts key (and the rest of its group, unless alone) in a column: a version, LATER, or nil (back to To sort).
function Plan:Place(key, rl, alone)
    if not self:CanEdit() then return false, "only the developer plans" end
    if not ValidKey(key) then return false, "unknown item" end
    if rl ~= nil and rl ~= LATER and not self:Release(rl) then return false, "no such release" end
    local e = self:Entry(key)
    local keys = { key }
    if e and e.g and not alone then
        local p = GetPlan(false)
        for k, o in pairs(p.it) do
            if k ~= key and Live(o) and o.g == e.g then keys[#keys + 1] = k end
        end
    end
    for _, k in ipairs(keys) do
        Touch("it", k, { rl = rl or false, x = false })
        if rl then MarkPlanned(k) end
    end
    return true
end

function Plan:SetSize(key, sz)
    if not self:CanEdit() then return false, "only the developer plans" end
    if not ValidKey(key) or not (sz == nil or SIZE_H[sz]) then return false, "pick S, M, L or XL" end
    Touch("it", key, { sz = sz or false, x = false })
    return true
end

function Plan:SetGroup(key, g)
    if not self:CanEdit() then return false, "only the developer plans" end
    g = g and strsub(Util.Trim(g), 1, GROUP_MAX) or nil
    if g == "" then g = nil end
    Touch("it", key, { g = g or false, x = false })
    return true
end

function Plan:SetNote(key, nt)
    if not self:CanEdit() then return false, "only the developer plans" end
    nt = nt and strsub(Util.Trim((nt:gsub("[\r\n|]", " "))), 1, NOTE_MAX) or nil
    if nt == "" then nt = nil end
    Touch("it", key, { nt = nt or false, x = false })
    return true
end

-- Takes an item off the plan (a dev item: deletes it).
function Plan:Remove(key)
    if not self:CanEdit() then return false, "only the developer plans" end
    if not self:Entry(key) then return true end
    Touch("it", key, { x = 1 })
    return true
end

-- One of the developer's own items: returns its key ("D-5"), or nil, err.
function Plan:AddDevItem(title, kind, sz, rl)
    if not self:CanEdit() then return nil, "only the developer adds items" end
    title = Util.Trim(((title or ""):gsub("[\r\n|]", " ")))
    if title == "" then return nil, "give it a title" end
    if not DEV_KINDS[kind or "idea"] then return nil, "unknown kind" end
    if rl ~= nil and rl ~= LATER and not self:Release(rl) then return nil, "no such release" end
    local p = GetPlan(true)
    if not p then return nil, "your guild is not known yet" end
    local n = 0
    for key in pairs(p.it) do
        local d = IsDevKey(key) and tonumber(strmatch(key, "%d+"))
        if d and d > n then n = d end
    end
    local key = "D-" .. (n + 1)
    Touch("it", key, { tt = strsub(title, 1, TITLE_MAX), kd = kind or "idea", sz = SIZE_H[sz or ""] and sz or nil,
        rl = rl, at = Now() })
    return key
end

function Plan:SetDone(key, on)
    if not self:CanEdit() then return false, "only the developer plans" end
    if not (IsDevKey(key) and self:Entry(key)) then return false, "only your own items are marked done here" end
    Touch("it", key, { dn = on and Now() or false })
    return true
end

-- Released: the release is marked done; moveTo (a version or LATER) takes what didn't ship.
function Plan:MarkReleased(v, moveTo)
    if not self:CanEdit() then return false, "only the developer releases" end
    if not self:Release(v) then return false, "no such release" end
    if moveTo then
        for _, row in ipairs(self:Check(v).rows) do
            if not row.shipped then self:Place(row.card.key, moveTo, true) end
        end
    end
    Touch("rel", v, { done = Now() })
    return true
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local loginDone = false

local function AfterLogin()
    if loginDone or not IsInGuild() then return end
    local Guild = ns.Guild
    if not (Guild and Guild:IsReady() and Util.GuildKey()) then return end
    loginDone = true
    if F():AmIDev() then
        Plan:TakeFile()
        Plan:SyncStatuses()
        Publish()
    else
        SayHello()
    end
end

function Plan:OnInit()
    local C = Comm()
    if C and C.Register then
        C:Register("FBP", OnPlan)
        C:Register("FBC", OnComing)
        C:Register("FBPH", OnHello)
    end
    ns:On("DEMO_TOGGLED", function() Changed() end)
    ns:On("FEEDBACK_UPDATED", function()
        if F():AmIDev() and not DemoOn() then PublishSoon() end
    end)
end

function Plan:OnLogin()
    Util.After(HELLO_DELAY + Util.Jitter("fbplan", 10), AfterLogin)
end

---------------------------------------------------------------------------
-- Demo mode: a plan over the demo guild's feedback (in memory, never saved, never sent)
---------------------------------------------------------------------------

-- "1.5.2" -> "1.5.3" (patch) or "1.6.0" (minor).
local function Bump(v, minor)
    local a, b, c = strmatch(tostring(v or "1.0.0"), "^(%d+)%.?(%d*)%.?(%d*)")
    a, b, c = tonumber(a) or 1, tonumber(b) or 0, tonumber(c) or 0
    if minor then return ("%d.%d.0"):format(a, b + 1) end
    return ("%d.%d.%d"):format(a, b, c + 1)
end
Plan.Bump = Bump

function Plan:DemoStore()
    if demoStore then return demoStore end
    local now = Now()
    local realm = Util.GetPlayerRealm()
    local function K(name, n) return name .. "-" .. realm .. "#" .. n end
    local patch, minor = Bump(ns.version), Bump(ns.version, true)
    local p = { rev = now, rel = {}, it = {} }
    p.rel[patch] = { th = "Quality of life", dt = now + 2 * 86400, bg = 8, pub = 1, u = now }
    p.rel[minor] = { th = "Raid nights and boss mods", dt = now + 9 * 86400, bg = 24, pub = 1, u = now }
    local function put(key, t) t.u = now; p.it[key] = t end
    put(K("Grimtusk", 4), { rl = patch, sz = "S", g = "Roll popup" })
    put(K("Orinel", 1), { rl = patch, sz = "M", nt = "The shopping list knows the crafter already" })
    put(K("Isolde", 3), { rl = minor, sz = "L" })
    put("D-1", { tt = "Roll popup waits out a loading screen too", kd = "bug", sz = "S", rl = patch, g = "Roll popup",
        at = now - 3600 })
    put("D-2", { tt = "Boss mods: Karazhan first", kd = "idea", sz = "XL", rl = minor, at = now - 86400 })
    put("D-3", { tt = "Whole-addon patch size cap", kd = "chore", sz = "M", rl = minor, at = now - 2 * 86400 })
    put("D-4", { tt = "My Raid Log", kd = "idea", sz = "L", rl = LATER, at = now - 5 * 86400 })
    demoStore = { plan = p }
    demoStore.coming = nil
    return demoStore
end

-- For the harness and /dump.
function Plan:Debug()
    local p = GetPlan(false, true)
    local c = GetComing(true)
    return { rev = p and p.rev or 0, coming = c and c.rev or 0, file = type(DisasterZoneDevPlan) == "table" }
end
