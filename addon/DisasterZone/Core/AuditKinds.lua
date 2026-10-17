if DisasterZoneBoot and DisasterZoneBoot.Run("Core/AuditKinds.lua", ...) then return end -- DisasterZone: the audit log's kinds.
-- What each kind of change is called in the audit log (Core/Audit.lua) and how Put back undoes a removal.
-- A describer gets (old, new, ctx) as the module saw them and returns an entry (or a list, or nil = nothing to say):
--   a (area), v (verb), o (thing key), n (thing name; "#<item id>" = that item's name), k (this kind), x (art:
--   "raid:<instance key>" | "item:<id>" | "class:<FILE>" | "who:<key>" | "g:<UI.ICON name>" | "seal"), c (the line's
--   verb phrase, {o} = the thing, "@<key>" = a player), w (author), t (when), sk (sub key), b (big change), p (Put back).
-- Fields f, each one of:
--   { l, a, b }      a value changed (a / b shown as they are; "@key" = a player, "#id" = an item)
--   { l, ta, tb }    a text changed (the page marks the words)
--   { l, ad, rm }    a list: added / removed
--   { l, v }         a value as it is now        { l, was }   a value that went
--   { l, mv = { { key, from, to } } }            players moved (groups, places)
--   { l, aw = { { itemID, winner, reason } } }   loot handed out
local addonName, ns = ...

local Audit = ns.Audit
local Util = ns.Util

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local floor, min = math.floor, math.min
local tsort, tconcat = table.sort, table.concat

local MAX_LIST = 25

local function Def(kind, def) Audit:Kind(kind, def) end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function P(key) return type(key) == "string" and ("@" .. key) or nil end
local function Short(key) return type(key) == "string" and (Util.ShortName(key) or key) or "?" end

local function Same(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return Util.Hash(a) == Util.Hash(b)
end

-- An array or a set ({ [k] = true / rev }) -> a set.
local function SetOf(x)
    local out = {}
    if type(x) ~= "table" then return out end
    for k, v in pairs(x) do
        if type(k) == "number" then out[v] = true elseif v then out[k] = true end
    end
    return out
end

-- Sets a, b -> added, removed (sorted arrays, fmt applied).
local function Diff(a, b, fmt)
    a, b = SetOf(a), SetOf(b)
    local ad, rm = {}, {}
    for k in pairs(b) do if not a[k] then ad[#ad + 1] = k end end
    for k in pairs(a) do if not b[k] then rm[#rm + 1] = k end end
    local function sorted(t)
        tsort(t, function(x, y) return tostring(x) < tostring(y) end)
        local out = {}
        for i = 1, min(#t, MAX_LIST) do out[i] = fmt and fmt(t[i]) or tostring(t[i]) end
        return out
    end
    return sorted(ad), sorted(rm)
end

local function Show(v)
    if v == nil or v == false or v == "" then return "None" end
    if v == true then return "Yes" end
    return tostring(v)
end

local function Scalar(f, l, a, b, fmt)
    if Same(a, b) then return end
    fmt = fmt or Show
    local sa, sb = fmt(a), fmt(b)
    if sa == sb then return end
    f[#f + 1] = { l = l, a = sa, b = sb }
end

local function TextField(f, l, a, b)
    a, b = a or "", b or ""
    if a == b then return end
    f[#f + 1] = { l = l, ta = a, tb = b }
end

local function List(f, l, a, b, fmt)
    local ad, rm = Diff(a, b, fmt)
    if #ad == 0 and #rm == 0 then return end
    f[#f + 1] = { l = l, ad = ad[1] and ad or nil, rm = rm[1] and rm or nil }
end

-- { [key] = n } maps (groups) -> moves { key, from, to } ("Not placed" for none).
local function Moves(f, l, a, b, what)
    a, b = type(a) == "table" and a or {}, type(b) == "table" and b or {}
    local keys, seen = {}, {}
    for k in pairs(a) do keys[#keys + 1] = k; seen[k] = true end
    for k in pairs(b) do if not seen[k] then keys[#keys + 1] = k end end
    tsort(keys)
    local mv = {}
    for _, k in ipairs(keys) do
        if a[k] ~= b[k] and #mv < MAX_LIST then
            mv[#mv + 1] = { k, a[k] and (what .. " " .. a[k]) or "Not placed", b[k] and (what .. " " .. b[k]) or "Not placed" }
        end
    end
    if #mv > 0 then f[#f + 1] = { l = l, mv = mv } end
end

local function Day(t)
    if type(t) ~= "number" then return nil end
    return date("%a ", t) .. tonumber(date("%d", t))
end

local function Start(t)
    if type(t) ~= "number" then return nil end
    return date("%a ", t) .. tonumber(date("%d", t)) .. date(" %b, %H:%M", t)
end

local function ClassName(c)
    if type(c) ~= "string" then return nil end
    local names = LOCALIZED_CLASS_NAMES_MALE
    return names and names[c] or (c:sub(1, 1) .. c:sub(2):lower())
end

---------------------------------------------------------------------------
-- Raids (Core/RaidPlan.lua): series S, raids / weeks E, sign-ups U, teams T, waitlists W, the blacklist BL
---------------------------------------------------------------------------

local function RP() return ns.RaidPlan end

local function PlanRoot()
    return ns.DB and ns.DB:GuildBucket("raidplan", false) or nil
end

local function SeriesRec(sid)
    local root = PlanRoot()
    return root and type(root.S) == "table" and root.S[sid] or nil
end

local function InstList(rec)
    local R = RP()
    if not (R and type(rec) == "table") then return {} end
    return R:GetRaidInstances(rec)
end

local function InstNames(rec)
    local R, out = RP(), {}
    for _, k in ipairs(InstList(rec)) do
        local inst = R:GetInstance(k)
        out[#out + 1] = inst and inst.name or k
    end
    return out[1] and tconcat(out, " + ") or nil
end

-- A raid's name for the log: "Serpentshrine Cavern · Sun 18".
local function RaidName(v)
    local R = RP()
    local name = (R and type(v) == "table") and R:GetRaidName(v) or nil
    if not name or name == "?" then name = "a raid" end
    if type(v) == "table" and v.t then name = name .. " · " .. Day(v.t) end
    return name
end

local function RaidArt(v)
    local list = InstList(v)
    return list[1] and ("raid:" .. list[1]) or "g:calendar"
end

-- The raid an occurrence id is now (its view), else what the record says (with its series' fields under it).
local function RaidView(occId, rec)
    local R = RP()
    local v = R and occId and R:GetRaid(occId)
    if v then return v end
    if type(rec) ~= "table" then return nil end
    local base = rec.sid and SeriesRec(rec.sid)
    if not base then return rec end
    local out = {}
    for k, x in pairs(base) do out[k] = x end
    for k, x in pairs(rec) do out[k] = x end
    return out
end

local function TeamName(id)
    local R = RP()
    local t = R and R:GetTeam(id)
    return t and t.n or "a team"
end

local function KeysOf(m)
    local out = {}
    for k in pairs(type(m) == "table" and m or {}) do out[#out + 1] = k end
    return out
end

local function RaidFields(old, new, base)
    local f = {}
    local function get(r, k)
        if r and r[k] ~= nil then return r[k] end
        return base and base[k]
    end
    Scalar(f, "Start", get(old, "t"), get(new, "t"), Start)
    local ia = InstNames({ i = get(old, "i"), ix = get(old, "ix") })
    local ib = InstNames({ i = get(new, "i"), ix = get(new, "ix") })
    if ia ~= ib then f[#f + 1] = { l = "Raid", a = ia or "None", b = ib or "None" } end
    Scalar(f, "Size", get(old, "sz"), get(new, "sz"))
    List(f, "Teams", get(old, "tm"), get(new, "tm"), TeamName)
    Scalar(f, "Who can join", get(old, "lk") and true or false, get(new, "lk") and true or false,
        function(v) return v and "Its teams and invites" or "Everyone in the guild" end)
    Scalar(f, "Hidden from others", get(old, "pv") and true or false, get(new, "pv") and true or false,
        function(v) return v and "Yes" or "No" end)
    Scalar(f, "Fill open places", get(old, "fo") and true or false, get(new, "fo") and true or false,
        function(v) return v and "On" or "Off" end)
    List(f, "Invites", get(old, "inv"), get(new, "inv"), P)
    Scalar(f, "Lowest level", tonumber(get(old, "ml")) or 0, tonumber(get(new, "ml")) or 0,
        function(v) return v > 0 and tostring(v) or "Any" end)
    TextField(f, "Title", get(old, "ti"), get(new, "ti"))
    TextField(f, "Note", get(old, "no"), get(new, "no"))
    Scalar(f, "Leader", get(old, "rl") or nil, get(new, "rl") or nil, function(v) return v and P(v) or "None" end)
    Moves(f, "Groups", get(old, "grp"), get(new, "grp"), "Group")
    List(f, "Guests", KeysOf(get(old, "gu")), KeysOf(get(new, "gu")), P)
    List(f, "Declined", KeysOf(get(old, "rj")), KeysOf(get(new, "rj")), P)
    List(f, "Taken off the sign-ups", KeysOf(get(old, "rm")), KeysOf(get(new, "rm")), P)
    List(f, "Guests taken out", KeysOf(get(old, "gx")), KeysOf(get(new, "gx")), P)
    if not Same(get(old, "tl"), get(new, "tl")) then f[#f + 1] = { l = "Lineups", v = "Changed" } end
    return f
end

local function MadeFields(r)
    local f = {}
    local function add(l, v) if v ~= nil and v ~= "" then f[#f + 1] = { l = l, v = v } end end
    add("Raid", InstNames(r))
    add("Start", Start(r.t))
    add("Size", r.sz)
    if type(r.tm) == "table" and r.tm[1] then
        local names = {}
        for _, id in ipairs(r.tm) do names[#names + 1] = TeamName(id) end
        add("Teams", tconcat(names, ", "))
    end
    add("Leader", r.rl and P(r.rl) or nil)
    add("Note", r.no)
    return f
end

-- (what CreateRaid takes back from a removed one-off raid)
local RAID_KEEP = { "t", "i", "ix", "sz", "tm", "tl", "lk", "pv", "fo", "inv", "ml", "ti", "no" }
local function RaidSnap(r)
    local out = {}
    for _, k in ipairs(RAID_KEEP) do if r[k] ~= nil then out[k] = r[k] end end
    return out
end

local function DescribeRaid(kind, old, new)
    if type(new) ~= "table" then return nil end
    if old and old.del and new.del then return nil end
    local isE = kind == "E"
    local o = isE and ("rp:O:" .. new.id) or ("rp:S:" .. new.id)
    local base = isE and new.sid and SeriesRec(new.sid) or nil
    local view
    if isE then
        view = (new.del or new.x) and RaidView(nil, old or new) or RaidView(new.id, new)
    else
        view = new.del and old or new
    end
    local e = { a = "raids", o = o, k = "rp." .. kind, w = new.by, t = new.rev, x = RaidArt(view) }
    e.n = isE and RaidName(view) or ((RP() and view and RP():GetRaidName(view) or "a raid") .. " · weekly")
    if new.del then
        if not old then return nil end
        e.v, e.b = "rem", "rem"
        if isE and not new.sid then e.p = RaidSnap(old) end
        e.f = MadeFields(RaidView(nil, old))
        return e
    end
    if new.x and not (old and old.x) then
        e.v, e.b = "rem", "rem"
        e.c = isE and "cancelled {o}" or "stopped the weekly raid {o}"
        if isE then e.p = { x = 1 } end
        return e
    end
    if old and old.x and not new.x then
        e.v, e.c = "chg", "put {o} back on"
        return e
    end
    if not old and not (isE and new.sid) then
        e.v, e.c, e.f = "add", "planned {o}", MadeFields(view or new)
        return e
    end
    local f = RaidFields(old, new, base)
    if kind == "S" and old and old.u ~= new.u then
        Scalar(f, "Repeats", old.u, new.u, function(v) return v and ("until week " .. (v + 1)) or "every week" end)
    end
    if #f == 0 then return nil end
    e.v, e.f = "chg", f
    return e
end

local function RaidPutBack(e)
    local R = RP()
    if not (R and type(e.p) == "table") then return false, "This can't be put back." end
    local occId = e.o:match("^rp:O:(.+)$")
    if e.p.x then return R:EditRaid(occId, { x = false }) end
    local f = {}
    for k, v in pairs(e.p) do f[k] = v end
    if type(f.t) == "number" and f.t < Util.Now() then
        return false, "That raid's date has passed: plan it again with a new date."
    end
    return Audit:PuttingBack(e, function() return R:CreateRaid(f) end)
end

Def("rp.E", { describe = function(old, new) return DescribeRaid("E", old, new) end, putBack = RaidPutBack,
    canPutBack = function(e) return type(e.p) == "table" and RP() ~= nil end })
Def("rp.S", { describe = function(old, new) return DescribeRaid("S", old, new) end })

local STATUS = { A = "Coming", T = "Tentative", B = "Bench", X = "Absent" }

Def("rp.U", { describe = function(old, new, ctx)
    if type(new) ~= "table" or not ctx.occ or not ctx.key then return nil end
    local view = RaidView(ctx.occ)
    local e = { a = "raids", o = "rp:O:" .. ctx.occ, n = RaidName(view), k = "rp.U", x = RaidArt(view),
                w = ctx.key, sk = ctx.key, t = new.rev }
    if not old then
        e.v, e.c = "add", "signed up for {o}"
        e.f = { { l = "Answer", v = STATUS[new.st] or new.st } }
        if new.n then e.f[2] = { l = "Note", v = new.n } end
        if new.dc then e.s = "In Discord" end
        return e
    end
    local f = {}
    Scalar(f, "Answer", STATUS[old.st] or old.st, STATUS[new.st] or new.st)
    TextField(f, "Note", old.n, new.n)
    if #f == 0 then return nil end
    e.v, e.c, e.f = "chg", "changed their answer for {o}", f
    return e
end })

Def("rp.W", { describe = function(old, new, ctx)
    if type(new) ~= "table" or not ctx.tid then return nil end
    if old and (old.x and true or false) == (new.x and true or false) then return nil end   -- (a new place only)
    if not old and new.x then return nil end
    local e = { a = "raids", o = "rp:T:" .. ctx.tid, n = TeamName(ctx.tid), k = "rp.W", x = "g:team",
                w = new.by, sk = "w:" .. (ctx.key or ""), t = new.rev }
    if new.x then
        e.v = "chg"
        e.c = (new.by == ctx.key) and "left the waitlist of {o}" or ("took " .. P(ctx.key) .. " off the waitlist of {o}")
    else
        e.v = "add"
        e.c = (new.by == ctx.key) and "joined the waitlist of {o}" or ("put " .. P(ctx.key) .. " on the waitlist of {o}")
    end
    return e
end })

-- Teams: a removed one is kept whole for Put back.
local TEAM_KEEP = { "n", "m", "sz", "s", "grp", "gs", "cp", "L", "th", "nt", "nn" }

local function NightsText(nt)
    local RN = ns.RaidNights
    if type(nt) ~= "table" or not nt[1] or not RN then return "None" end
    local days = RN:DaysText(nt)
    local times = RN:TimesText(nt)
    return days .. (times and times ~= "" and (", " .. times) or "")
end

Def("rp.T", {
    describe = function(old, new)
        if type(new) ~= "table" then return nil end
        if new.del and (not old or old.del) then return nil end
        local th = new.th or (old and old.th)
        local e = { a = "raids", o = "rp:T:" .. new.id, n = (new.del and old and old.n) or new.n or "a team", k = "rp.T",
                    x = th and ("raid:" .. th) or "g:team", w = new.by, t = new.rev }
        if new.del then
            e.v, e.b, e.c = "rem", "rem", "removed the team {o}"
            local p = {}
            for _, k in ipairs(TEAM_KEEP) do p[k] = old[k] end
            e.p = p
            e.f = { { l = "Players", v = #(old.m or {}) } }
            return e
        end
        if not old or old.del then
            e.v, e.c = "add", "made the team {o}"
            e.f = { { l = "Players", v = #(new.m or {}) }, { l = "Size", v = new.sz } }
            return e
        end
        local f = {}
        TextField(f, "Name", old.n, new.n)
        List(f, "Players", old.m, new.m, P)
        Scalar(f, "Size", old.sz, new.sz)
        local la, lb = {}, {}
        for _, l in ipairs(type(old.L) == "table" and old.L or {}) do la[l.id] = l end
        for _, l in ipairs(type(new.L) == "table" and new.L or {}) do lb[l.id] = l end
        local added, gone = {}, {}
        for id, l in pairs(lb) do
            if not la[id] then added[#added + 1] = l.n or "Lineup" end
        end
        for id, l in pairs(la) do
            if not lb[id] then gone[#gone + 1] = l.n or "Lineup" end
        end
        if #added > 0 or #gone > 0 then f[#f + 1] = { l = "Lineups", ad = added[1] and added, rm = gone[1] and gone } end
        for _, l in ipairs(type(new.L) == "table" and new.L or {}) do
            local before = la[l.id]
            if before then Moves(f, "Groups in " .. (l.n or "the lineup"), before.grp, l.grp, "Group") end
        end
        if not new.L then Moves(f, "Groups", old.grp, new.grp, "Group") end
        Scalar(f, "Banner", old.th, new.th, function(v)
            local inst = v and RP() and RP():GetInstance(v)
            return inst and inst.name or "None"
        end)
        Scalar(f, "Raid nights", NightsText(old.nt), NightsText(new.nt))
        TextField(f, "Nights note", old.nn, new.nn)
        if not Same(old.cp, new.cp) then f[#f + 1] = { l = "Target comp", v = "Changed" } end
        if #f == 0 then return nil end
        e.v, e.f = "chg", f
        return e
    end,
    canPutBack = function(e) return type(e.p) == "table" and type(e.p.m) == "table" end,
    putBack = function(e)
        local R, p = RP(), e.p
        if not R then return false end
        local opts = { theme = p.th, nights = p.nt, note = p.nn }
        if type(p.L) == "table" and p.L[1] then
            opts.lineups = {}
            for _, l in ipairs(p.L) do
                opts.lineups[#opts.lineups + 1] = { name = l.n, size = l.sz, specs = l.s, groups = l.grp, seats = l.gs, comp = l.cp }
            end
        else
            opts.size, opts.specs, opts.groups, opts.seats, opts.comp = p.sz, p.s, p.grp, p.gs, p.cp
        end
        return Audit:PuttingBack(e, function() return R:SaveTeam(nil, p.n, p.m, opts) end)
    end,
})

Def("rp.BL", {
    describe = function(old, new, ctx)
        local key = ctx.key
        if not key then return nil end
        local e = { a = "guests", o = "bl:" .. key, n = Short(key), k = "rp.BL", x = "who:" .. key, sk = "bl" }
        if new and not old then
            e.v, e.b, e.c, e.w, e.t = "add", "black", "put {o} on the blacklist", new.by, new.v
            if new.r then e.f, e.s = { { l = "Reason", v = new.r } }, "“" .. new.r .. "”" end
        elseif old and not new then
            e.v, e.b, e.c, e.t = "rem", "black", "took {o} off the blacklist", ctx.at
            e.f = { { l = "Blacklisted for", was = old.r or "No reason given" } }
            e.p = { r = old.r or false }
        elseif old and new then
            if (old.r or "") == (new.r or "") then return nil end
            e.v, e.c, e.w, e.t = "chg", "changed why {o} is on the blacklist", new.by, new.v
            e.f = {}
            TextField(e.f, "Reason", old.r, new.r)
        else
            return nil
        end
        return e
    end,
    canPutBack = function(e) return type(e.p) == "table" end,
    putBack = function(e)
        local key = e.o:match("^bl:(.+)$")
        return RP():SetBlacklisted(key, e.p.r or nil)
    end,
})

---------------------------------------------------------------------------
-- Guest book (Core/GuestBook.lua)
---------------------------------------------------------------------------

Def("gb.N", {
    describe = function(old, new, ctx)
        local key = ctx.key
        if not key then return nil end
        local live = function(r) return type(r) == "table" and not r.x end
        local e = { a = "guests", o = "gb:" .. key, n = Short(key), k = "gb.N", x = "who:" .. key, t = ctx.at,
                    w = ctx.who }
        if live(old) and not live(new) then
            e.v, e.c = "rem", new and "took {o} out of the guest book" or "cleared {o} in the guest book"
            e.p = { n = old.n or false, rc = old.rc or false, c = old.c or false, sp = old.sp }
            if old.n then e.f = { { l = "Note", was = old.n } } end
            return e
        end
        if not live(new) then return nil end
        if not live(old) then
            e.v, e.c = "add", "added {o} to the guest book"
            e.f = {}
            if new.c then e.f[#e.f + 1] = { l = "Class", v = ClassName(new.c) } end
            if new.rc then e.f[#e.f + 1] = { l = "Recruit mark", v = "Yes" } end
            if new.n then e.f[#e.f + 1] = { l = "Note", v = new.n } end
            return e
        end
        local f = {}
        TextField(f, "Note", old.n, new.n)
        Scalar(f, "Recruit mark", old.rc and true or false, new.rc and true or false, function(v) return v and "Yes" or "No" end)
        Scalar(f, "Class", ClassName(old.c), ClassName(new.c))
        if #f == 0 then return nil end
        e.v, e.f = "chg", f
        e.c = "changed {o} in the guest book"
        return e
    end,
    canPutBack = function(e) return type(e.p) == "table" and ns.GuestBook ~= nil end,
    putBack = function(e)
        local key, p = e.o:match("^gb:(.+)$"), e.p
        return ns.GuestBook:SetNote(key, p.n or false, p.rc and true or false, p.c or false, p.sp)
    end,
})

---------------------------------------------------------------------------
-- Strategies (Core/Strategy.lua): boards B, the strategy a raid uses per boss F
---------------------------------------------------------------------------

local function BossName(ref)
    local S = ns.Strategy
    return (S and S.GetBossName and type(ref) == "string" and S:GetBossName(ref)) or "a boss"
end

local function BossArt(ref)
    local inst = type(ref) == "string" and ref:match("^(%w+):")
    return inst and ("raid:" .. inst) or "g:pin"
end

local function PageNames(p)
    local out = {}
    for _, page in ipairs(type(p) == "table" and p or {}) do out[#out + 1] = page.n or "Page" end
    return tconcat(out, " · ")
end

local STRAT_DROP = { id = true, rev = true, by = true, ow = true, co = true, cr = true, del = true }

Def("sb.B", {
    describe = function(old, new)
        if type(new) ~= "table" then return nil end
        if new.del and (not old or old.del) then return nil end
        local ref = new.b or (old and old.b)
        local e = { a = "strat", o = "sb:" .. new.id, n = (new.del and old and old.n) or new.n or "a strategy",
                    k = "sb.B", x = BossArt(ref), w = new.by, t = new.rev }
        if new.del then
            e.v, e.b, e.c = "rem", "rem", "removed the strategy {o}"
            local p = {}
            for k, v in pairs(old) do if not STRAT_DROP[k] then p[k] = v end end
            e.p = p
            e.f = { { l = "Boss", v = BossName(old.b) }, { l = "Pages", v = PageNames(old.p) } }
            return e
        end
        if not old or old.del then
            e.v, e.c = "add", "made the strategy {o}"
            e.f = { { l = "Boss", v = BossName(new.b) }, { l = "Pages", v = PageNames(new.p) } }
            return e
        end
        local f = {}
        TextField(f, "Name", old.n, new.n)
        Scalar(f, "Boss", BossName(old.b), BossName(new.b))
        List(f, "Can edit", old.co, new.co, P)
        local pa, pb, changed = {}, {}, {}
        for _, page in ipairs(old.p or {}) do pa[page.id] = page end
        for _, page in ipairs(new.p or {}) do
            pb[page.id] = page
            if pa[page.id] and not Same(pa[page.id], page) then changed[#changed + 1] = page.n or "Page" end
        end
        local added, gone = {}, {}
        for id, page in pairs(pb) do if not pa[id] then added[#added + 1] = page.n or "Page" end end
        for id, page in pairs(pa) do if not pb[id] then gone[#gone + 1] = page.n or "Page" end end
        if #added > 0 or #gone > 0 then f[#f + 1] = { l = "Pages", ad = added[1] and added, rm = gone[1] and gone } end
        if #changed > 0 then f[#f + 1] = { l = "Pages changed", v = tconcat(changed, " · ") } end
        Scalar(f, "Auto marks", old.am ~= false, new.am ~= false, function(v) return v and "On" or "Off" end)
        if #f == 0 then return nil end
        e.v, e.f = "chg", f
        return e
    end,
    canPutBack = function(e) return type(e.p) == "table" and type(e.p.p) == "table" and ns.Strategy ~= nil end,
    putBack = function(e)
        local draft = Util.CopyTable(e.p)
        return Audit:PuttingBack(e, function() return ns.Strategy:SaveStrategy(draft) end)
    end,
})

Def("sb.F", { describe = function(old, new)
    if type(new) ~= "table" or type(new.o) ~= "string" then return nil end
    local S = ns.Strategy
    local function name(r)
        if not r then return nil end
        if r.x then return "None" end
        local s = r.s and S and S.GetStrategy and S:GetStrategy(r.s)
        return s and s.n or (r.s and "a strategy" or nil)
    end
    local view = RaidView(new.o)
    local boss = BossName(new.b)
    local f = {}
    Scalar(f, boss, name(old), name(new))
    local moved = 0
    local a, b = type(old and old.a) == "table" and old.a or {}, type(new.a) == "table" and new.a or {}
    for k, v in pairs(b) do if a[k] ~= v then moved = moved + 1 end end
    for k in pairs(a) do if b[k] == nil then moved = moved + 1 end end
    if moved > 0 then f[#f + 1] = { l = boss .. " jobs", v = moved .. (moved == 1 and " changed" or " changed") } end
    if #f == 0 then return nil end
    return { a = "raids", o = "rp:O:" .. new.o, n = RaidName(view), k = "sb.F", x = RaidArt(view), w = new.by, t = new.rev,
             sk = "f:" .. tostring(new.b), v = old and "chg" or "add",
             c = old and "changed the strategies for {o}" or "picked the strategies for {o}", f = f }
end })

---------------------------------------------------------------------------
-- Polls and events (Core/Polls.lua, Core/Events.lua; their sync engine passes them on)
---------------------------------------------------------------------------

local function Strings(list)
    local out = {}
    for _, v in ipairs(type(list) == "table" and list or {}) do
        out[#out + 1] = type(v) == "table" and tostring(v.t or v.n or v[1] or "") or tostring(v)
    end
    return out
end

Def("pl.P", { describe = function(old, new)
    if type(new) ~= "table" then return nil end
    if new.del and (not old or old.del) then return nil end
    local e = { a = "events", o = "pl:" .. new.id, n = (new.del and old and old.q) or new.q or "a poll", k = "pl.P",
                x = "g:ballot", w = new.by, t = new.rev }
    if new.del then
        e.v, e.c = "rem", "removed the poll {o}"
        return e
    end
    local closed = function(r) return r and type(r.cl) == "number" and r.cl <= (r.rev or 0) + 5 end
    if not old or old.del then
        e.v, e.c = "add", "started the poll {o}"
        e.f = { { l = "Answers", v = tconcat(Strings(new.o), " · ") } }
        if type(new.cl) == "number" then e.f[2] = { l = "Closes", v = Start(new.cl) } end
        return e
    end
    if closed(new) and not closed(old) then
        e.v, e.c = "chg", "closed the poll {o}"
        return e
    end
    local f = {}
    TextField(f, "Question", old.q, new.q)
    List(f, "Answers", Strings(old.o), Strings(new.o))
    Scalar(f, "Closes", old.cl, new.cl, Start)
    if #f == 0 then return nil end
    e.v, e.f = "chg", f
    return e
end })

local function DefName(d) return type(d) == "table" and (d.name or d.n) or nil end

local function EventName(id)
    local E = ns.Events
    local d = E and E.GetDef and E:GetDef(id)
    return DefName(d) or "an event"
end

Def("ev.D", { describe = function(old, new)
    if type(new) ~= "table" then return nil end
    if new.del and (not old or old.del) then return nil end
    local e = { a = "events", o = "ev:D:" .. new.id, n = DefName(new) or DefName(old) or "an event", k = "ev.D",
                x = "g:trophy", w = new.by, t = new.rev }
    if new.del then e.v, e.c = "rem", "removed the event {o}"; return e end
    if not old or old.del then e.v, e.c = "add", "made the event {o}"; return e end
    local f = {}
    TextField(f, "Name", DefName(old), DefName(new))
    if #f == 0 and not Same(old, new) then f[1] = { l = "Event", v = "Changed" } end
    if #f == 0 then return nil end
    e.v, e.f = "chg", f
    return e
end })

Def("ev.O", { describe = function(old, new)
    if type(new) ~= "table" then return nil end
    if new.del and (not old or old.del) then return nil end
    local src = (new.del and old) or new
    local name = DefName(src.def) or "an event"
    if type(src.at) == "number" and src.at > 0 then name = name .. " · " .. Day(src.at) end
    local e = { a = "events", o = "ev:O:" .. new.id, n = name, k = "ev.O", x = "g:trophy", w = new.by, t = new.rev }
    if new.del then e.v, e.b, e.c = "rem", "rem", "removed {o}"; return e end
    if new.cancel and not (old and old.cancel) then
        e.v, e.c = "rem", "cancelled {o}"
        e.f = { { l = "Why", v = new.cancel } }
        return e
    end
    if not old or old.del then
        e.v, e.c = "add", "scheduled {o}"
        e.f = { { l = "When", v = Start(new.at) }, { l = "Where", v = new.where }, { l = "Host", v = P(new.h) } }
        return e
    end
    local f = {}
    Scalar(f, "When", old.at, new.at, Start)
    TextField(f, "Where", old.where, new.where)
    TextField(f, "Note", old.note, new.note)
    Scalar(f, "Host", old.h, new.h, function(v) return v and P(v) or "None" end)
    if #f == 0 then return nil end
    e.v, e.f = "chg", f
    return e
end })

Def("ev.K", { describe = function(old, new)
    if type(new) ~= "table" or (old and old.dr == new.dr and old.ok == new.ok and (old.note or "") == (new.note or "")) then
        return nil
    end
    if new.x or new.hide then return nil end
    local e = { a = "events", o = "ev:D:" .. new.id, n = EventName(new.id), k = "ev.K", x = "g:trophy", w = new.by,
                t = new.rev, sk = "k", v = "chg" }
    e.c = new.ok and "approved {o}" or "sent {o} back"
    if new.note then e.f = { { l = "Note", v = new.note } } end
    return e
end })

Def("ev.R", { describe = function(old, new)
    if type(new) ~= "table" then return nil end
    if new.del and (not old or old.del) then return nil end
    local e = { a = "events", o = "ev:R:" .. new.id, n = (new.del and old and old.name) or new.name or "an event",
                k = "ev.R", x = "g:trophy", w = new.by, t = new.rev }
    if new.del then e.v, e.c = "rem", "removed the results of {o}"; return e end
    if old and not old.del and Same(old, new) then return nil end
    e.v, e.c = old and not old.del and "chg" or "add", old and not old.del and "changed the results of {o}" or "posted the results of {o}"
    if new.champ then e.f = { { l = "Winner", v = P(new.champ) } } end
    return e
end })

Def("ev.C", { describe = function(old, new)
    if type(new) ~= "table" or Same(old, new) then return nil end
    local f = {}
    TextField(f, "Season", old and old.n, new.n)
    Scalar(f, "From", old and old.from, new.from, Start)
    Scalar(f, "To", old and old.to, new.to, Start)
    if #f == 0 then return nil end
    return { a = "events", o = "ev:season", n = "the events season", k = "ev.C", x = "g:trophy", w = new.by, t = new.rev,
             v = old and "chg" or "add", f = f }
end })

---------------------------------------------------------------------------
-- Loot (Core/Ledger.lua awards, Core/Prized.lua prized items, Core/Store.lua BiS lists the council holds)
---------------------------------------------------------------------------

local REASON = {}
for _, r in ipairs(ns.AWARD_REASONS or {}) do REASON[r.key] = r.label end
local function ReasonText(r) return r and (REASON[r] or r) or "None" end

local function AwardKey(e)
    if e.s == "a" then
        return "lg:a:" .. tostring(e.w) .. ":" .. tostring(e.i) .. ":" .. floor((e.ts or 0) / 600)
    end
    return "lg:" .. e.id
end

Def("lg.A", {
    describe = function(old, new, ctx)
        if type(new) ~= "table" or not new.i then return nil end
        local e = { a = "loot", o = AwardKey(new), n = "#" .. new.i, k = "lg.A", x = "item:" .. new.i }
        local award = { { l = "Award", aw = { { new.i, new.w, new.r } } } }
        if not old then
            if new.s == "a" or new.vd then return nil end            -- (loot lines are recorded, nobody's change)
            e.v, e.c, e.w, e.t, e.sk = "add", "gave {o} to " .. P(new.w), new.by, new.ts, "a"
            e.f = award
            return e
        end
        if (old.vd and true or false) ~= (new.vd and true or false) then
            e.t, e.sk, e.f = new.vts, "v", award
            if new.vd then
                e.v, e.b, e.c = "rem", "void", "took back {o} from " .. P(new.w)
                e.p = { id = new.id }
                if ctx.lost then e.s = "Lost to another award" end
            else
                e.v, e.c = "chg", "gave {o} back to " .. P(new.w)
            end
            return e
        end
        if old.r ~= new.r then
            e.v, e.c, e.t, e.sk = "chg", "changed why " .. P(new.w) .. " got {o}", new.rts, "r"
            e.f = { { l = "Reason", a = ReasonText(old.r), b = ReasonText(new.r) } }
            return e
        end
        return nil
    end,
    canPutBack = function(e) return type(e.p) == "table" and type(e.p.id) == "string" and ns.Ledger ~= nil end,
    putBack = function(e)
        local ok = ns.Ledger:Void(e.p.id, false)
        if not ok then return false, "Only loot council members can change awards, and it may be counted again already." end
        return true
    end,
})

Def("pz.I", {
    describe = function(old, new)
        if type(new) ~= "table" then return nil end
        if new.del and (not old or old.del) then return nil end
        local src = (new.del and old) or new
        local id = type(src.ids) == "table" and src.ids[1] or tonumber(new.id)
        local e = { a = "loot", o = "pz:" .. new.id, n = id and ("#" .. id) or "an item", k = "pz.I",
                    x = id and ("item:" .. id) or "g:prized", w = new.by, t = new.rev, b = "rules" }
        local Pz = ns.Prized
        local function rules(a, b) return Pz and Pz.DescribeChange and Pz:DescribeChange(a, b) or nil end
        if new.del then
            e.v, e.c = "rem", "made {o} an ordinary item again"
            e.p = { ids = old.ids, r = old.r }
            return e
        end
        if not old or old.del then
            e.v, e.c = "add", "made {o} a prized item"
            local r = rules(nil, new.r)
            if r then e.f = { { l = "Rules", v = r } } end
            return e
        end
        local r = rules(old.r, new.r)
        if not r then return nil end
        e.v, e.c, e.f = "chg", "changed the rules of {o}", { { l = "Rules", v = r } }
        return e
    end,
    canPutBack = function(e) return type(e.p) == "table" and type(e.p.ids) == "table" and ns.Prized ~= nil end,
    putBack = function(e)
        local rec = ns.Prized:Add(e.p.ids, e.p.r)
        if not rec then return false, "Only the Guild Master and the guild council change prized items." end
        return true
    end,
})

local SLOT_LABEL = {}
for _, s in ipairs(ns.SLOTS or {}) do SLOT_LABEL[s.id] = s.label end

local function Mains(data, field)
    local out = {}
    for phase, list in pairs(type(data) == "table" and type(data[field]) == "table" and data[field] or {}) do
        if type(list) == "table" then
            for sid, pick in pairs(list) do
                local main = type(pick) == "table" and tonumber(pick[1]) or tonumber(pick)
                out[phase .. ":" .. sid] = main or 0
            end
        end
    end
    return out
end

Def("bis.L", { describe = function(old, new, ctx)
    if type(old) ~= "table" or type(new) ~= "table" or not ctx.key or old.hash == new.hash then return nil end
    local f = {}
    local function walk(field, phaseName)
        local a, b = Mains(old.data, field), Mains(new.data, field)
        local keys, seen = {}, {}
        for k in pairs(a) do keys[#keys + 1] = k; seen[k] = true end
        for k in pairs(b) do if not seen[k] then keys[#keys + 1] = k end end
        tsort(keys)
        for _, k in ipairs(keys) do
            if (a[k] or 0) ~= (b[k] or 0) and #f < 8 then
                local phase, sid = k:match("^(%d+):(%d+)$")
                f[#f + 1] = { l = (SLOT_LABEL[tonumber(sid)] or "Slot") .. " · " .. phaseName(tonumber(phase)),
                              a = (a[k] or 0) > 0 and ("#" .. a[k]) or "None", b = (b[k] or 0) > 0 and ("#" .. b[k]) or "None" }
            end
        end
    end
    walk("ph", function(p) return "Phase " .. tostring(p) end)
    walk("op", function(p) return "Off spec, phase " .. tostring(p) end)
    if #f == 0 then return nil end
    return { a = "loot", o = "bis:" .. ctx.key, n = "their BiS list", k = "bis.L", x = "who:" .. ctx.key, w = ctx.key,
             t = (tonumber(new.ts) or 0) > 0 and new.ts or Util.Now(), v = "chg", f = f,
             b = ctx.locked and "lock" or nil }
end })

---------------------------------------------------------------------------
-- Roles (Core/Guild.lua): the guild council CG, the raid leaders record RL (with the GM's rules), alts AC
---------------------------------------------------------------------------

Def("gd.CG", { describe = function(old, new)
    if type(new) ~= "table" then return nil end
    if type(old) == "table" and old.g ~= new.g then old = nil end
    local e = { a = "roles", o = "gd:council", n = "the guild council", k = "gd.CG", x = "g:crown", w = new.by,
                t = new.rev, b = "rights" }
    if not old then
        e.v, e.c = "add", "set up {o}"
        local members = Diff({}, new.members, P)
        e.f = { { l = "Members", ad = members[1] and members or nil } }
        return e
    end
    local f = {}
    List(f, "Members", old.members, new.members, P)
    Scalar(f, "Phase", old.phase, new.phase)
    Scalar(f, "Disenchanter", old.de, new.de, function(v) return v and P(v) or "None" end)
    Scalar(f, "Guild bank", old.bank, new.bank, function(v) return v and P(v) or "None" end)
    if #f == 0 then return nil end
    e.v, e.f = "chg", f
    return e
end })

local LOOT_RULES = {
    { "f", "Attendance floor", { [0] = "Off" }, "%" },
    { "s", "When votes split", { r = "Highest roll", p = "Council picks" } },
    { "l", "Before anyone votes", { l = "Lists first", r = "Roll only" } },
    { "w", "Then, among them", { r = "Highest roll", d = "Driest first" } },
    { "o", "Longest use", { [0] = "Off" }, "P" },
    { "y", "Since loot counts", { n = "Nights there", a = "Any night" } },
    { "q", "Prized: not qualified", { h = "A notice", s = "Roll window" } },
}

local function RuleText(spec, v)
    if v == nil then return "None" end
    if spec[3][v] then return spec[3][v] end
    if spec[4] == "%" then return tostring(v) .. "%" end
    if spec[4] == "P" then return "P" .. tostring(v) end
    return tostring(v)
end

Def("gd.RL", { describe = function(old, new)
    if type(old) ~= "table" or type(new) ~= "table" then return nil end
    local out = {}
    local function part(sk, o, n, who, b, f)
        if #f > 0 then
            out[#out + 1] = { a = "roles", o = o, n = n, k = "gd.RL", x = "g:crown", w = who, t = new.rev, sk = sk,
                              v = "chg", b = b, f = f }
        end
    end
    local f = {}
    List(f, "Raid leaders", old.m, new.m, P)
    part("m", "gd:leaders", "the raid leaders", new.by, "rights", f)
    f = {}
    if not Same(old.lr, new.lr) then
        local a, b = type(old.lr) == "table" and old.lr or {}, type(new.lr) == "table" and new.lr or {}
        for _, spec in ipairs(LOOT_RULES) do Scalar(f, spec[2], RuleText(spec, a[spec[1]]), RuleText(spec, b[spec[1]])) end
    end
    part("lr", "gd:lootrules", "the loot rules", new.lrBy, "rules", f)
    f = {}
    if not Same(old.ar, new.ar) then
        local a, b = type(old.ar) == "table" and old.ar or {}, type(new.ar) == "table" and new.ar or {}
        Scalar(f, "On time within", a.o, b.o, function(v) return v and (v .. " min") or "None" end)
        Scalar(f, "Disconnects forgiven", a.d, b.d, function(v) return v and (v .. " min") or "None" end)
    end
    part("ar", "gd:attrules", "the attendance rules", new.arBy, nil, f)
    f = {}
    if not Same(old.dc, new.dc) then f[1] = { l = "Discord", v = "Changed" } end
    part("dc", "gd:discord", "the Discord set-up", new.dcBy, "rights", f)
    f = {}
    if not Same(old.rc, new.rc) then f[1] = { l = "Recruitment rules", v = "Changed" } end
    part("rc", "gd:recruitrules", "who may recruit", new.rcBy, "rights", f)
    return out
end })

Def("gd.AC", { describe = function(old, new, ctx)
    if type(new) ~= "table" or not ctx.key then return nil end
    local ad, rm = Diff(old and old.m, new.m, P)
    if #ad == 0 and #rm == 0 then return nil end
    return { a = "members", o = "ac:" .. ctx.key, n = "their characters", k = "gd.AC", x = "who:" .. ctx.key,
             w = ctx.key, t = new.rev, v = old and "chg" or "add",
             c = #rm > 0 and #ad == 0 and "unlinked characters" or "linked characters",
             f = { { l = "Same player", ad = ad[1] and ad, rm = rm[1] and rm } } }
end })

---------------------------------------------------------------------------
-- Members (officer notes, attendance, the raid log) and recruitment
---------------------------------------------------------------------------

Def("on.N", {
    describe = function(old, new, ctx)
        if type(new) ~= "table" or not ctx.key then return nil end
        local a, b = old and old.t or "", new.t or ""
        if a == b then return nil end
        local e = { a = "members", o = "on:" .. ctx.key, n = Short(ctx.key), k = "on.N", x = "who:" .. ctx.key,
                    w = new.by, t = new.rev }
        if b == "" then
            e.v, e.c, e.p = "rem", "cleared the officer note on {o}", { t = a }
            e.f = { { l = "Officer note", was = a } }
        elseif a == "" then
            e.v, e.c, e.f = "add", "wrote an officer note on {o}", { { l = "Officer note", v = b } }
        else
            e.v, e.c, e.f = "chg", "changed the officer note on {o}", { { l = "Officer note", ta = a, tb = b } }
        end
        return e
    end,
    canPutBack = function(e) return type(e.p) == "table" and ns.OfficerNotes and ns.OfficerNotes:CanUse() end,
    putBack = function(e) return ns.OfficerNotes:Set(e.o:match("^on:(.+)$"), e.p.t) end,
    audience = function(key) return ns.Guild:IsOfficer(key, true) end,    -- (the notes' own audience)
})

local STAGE = { talk = "Talking", joined = "Joined", notnow = "Not now", gone = "Gone" }

Def("rc.P", { audience = function(key) return ns.Recruit:IsRecruiter(key) end, describe = function(old, new, ctx)
    local key = ctx.key
    if not key then return nil end
    local cls = (new and new.c) or (old and old.c)
    local e = { a = "recruit", o = "rc:" .. key, n = Short(key), k = "rc.P",
                x = cls and ("class:" .. cls) or ("who:" .. key) }
    if not new then
        if not old then return nil end
        e.v, e.c, e.w, e.t = "rem", "took {o} out of Recruitment", ctx.who, ctx.at
        return e
    end
    e.w, e.t = new.by, new.rev
    if not old then
        e.v, e.c = "add", "added {o} to Recruitment"
        e.f = { { l = "Stage", v = STAGE[new.st] or new.st } }
        return e
    end
    local f = {}
    Scalar(f, "Stage", STAGE[old.st] or old.st, STAGE[new.st] or new.st)
    Scalar(f, "Talking to them", old.w, new.w, function(v) return v and P(v) or "Nobody" end)
    local na, nb = type(old.n) == "table" and #old.n or 0, type(new.n) == "table" and #new.n or 0
    if nb > na then
        local last = new.n[nb]
        f[#f + 1] = { l = "Note", v = type(last) == "table" and last.t or "" }
    end
    if #f == 0 then return nil end
    e.v, e.f = "chg", f
    return e
end })

local function LogName(rec)
    if type(rec) ~= "table" then return "a raid" end
    if rec.pl and RP() then
        local v = RP():GetRaid(rec.pl)
        if v then return RaidName(v) end
    end
    local name = type(rec.zone) == "string" and rec.zone or "a raid"
    if rec.start then name = name .. " · " .. Day(rec.start) end
    return name
end

local function LogArt(rec)
    if type(rec) == "table" and rec.pl and RP() then
        local v = RP():GetRaid(rec.pl)
        if v then return RaidArt(v) end
    end
    return "g:calendar"
end

Def("rl.R", { describe = function(_, new, ctx)
    if type(new) ~= "table" then return nil end
    local rec = { pl = ctx.session and ctx.session.rp, start = new.start }
    return { a = "raids", o = "rl:" .. new.id, n = LogName(rec), k = "rl.R", x = LogArt(rec), w = new.by,
             t = new.start, sk = "start", v = "add", c = "started {o}" }
end })

Def("rl.E", { describe = function(_, rec)
    if type(rec) ~= "table" or not rec.endedBy or not rec.stop then return nil end
    local n = 0
    for _ in pairs(rec.att or {}) do n = n + 1 end
    return { a = "raids", o = "rl:" .. rec.id, n = LogName(rec), k = "rl.E", x = LogArt(rec), w = rec.endedBy,
             t = floor(rec.stop / 60) * 60, sk = "end", v = "chg", c = "ended {o}",
             f = { { l = "Attended", v = n }, { l = "Bosses", v = #(rec.bosses or {}) } } }
end })

Def("rl.D", { describe = function(old, new)
    if type(new) ~= "table" or not new.del or (old and old.del) then return nil end
    return { a = "raids", o = "rl:" .. new.id, n = LogName(old or new), k = "rl.D", x = LogArt(old), w = new.delBy,
             t = new.delAt, sk = "del", v = "rem", b = "rem", c = "removed the logged raid {o}" }
end })

local DECISION = { x = "Excused", c = "Counts", u = "Not decided" }

Def("at.D", { describe = function(old, new, ctx)
    if type(new) ~= "table" or not ctx.key or not ctx.rec then return nil end
    if old and old.d == new.d and (old.n or "") == (new.n or "") then return nil end
    local f = { { l = "Attendance", a = DECISION[old and old.d or "u"] or "Not decided", b = DECISION[new.d] or new.d } }
    if new.n then f[2] = { l = "Note", v = new.n } end
    return { a = "members", o = "rl:" .. ctx.rec.id, n = LogName(ctx.rec), k = "at.D", x = "who:" .. ctx.key,
             w = new.by, t = new.at, sk = "dc:" .. ctx.key, v = "chg",
             c = "decided the attendance of " .. P(ctx.key) .. " for {o}", f = f }
end })

---------------------------------------------------------------------------
-- The addon (Core/Patch.lua): an update I published
---------------------------------------------------------------------------

Def("pt.U", { describe = function(_, new)
    if type(new) ~= "table" or not new.seq then return nil end
    return { a = "addon", o = "pt:" .. new.seq, n = tostring(new.version or "?") .. " update " .. new.seq, k = "pt.U",
             x = "seal", v = "add", c = "sent {o} to the guild", b = "update", t = Util.Now(),
             f = { { l = "Files", v = new.n } } }
end })
