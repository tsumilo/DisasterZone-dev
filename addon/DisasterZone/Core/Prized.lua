if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Prized.lua", ...) then return end -- DisasterZone: prized items (Raids > Loot rules).
-- A short list of very important drops (Dragonspine Trophy, the Warglaives, Thori'dal...) that the GM and the guild
-- council give stricter loot rules; every member sees the rules and how they stand against each (user request
-- 2026-10-11, mockup dev/art/casc/prized_mockup). Stored and synced guild-wide like the polls (Core/Polls.lua):
--   I  an item: { id = the first item ID as text, ids = { 1-2 item IDs sharing the rules (the two glaives) },
--      r = the rules, by, rev, del }. Written by the GM or the guild council; a removal (del) wins.
--   G  a hand-out of a prized item: { id, i = the item's record id, it = the item ID, to = the winner, at, by,
--      ov = { rule keys it broke }, why = the reason given for that, ag = council votes for the winner,
--      of = council members in the raid then, del }. Written by the council member who awarded it; never edited
--      (del = voided). Every member keeps them: the loot log is council-only, but the cooldown, the queue and the
--      pair rules, and the item's public history, need them.
--   H  a rule change: { id, i, by, at, t = what changed in words }. Written with the change (GM / guild council).
-- Rules (r[key] = { m = "r" required | "p" priority, ... }):
--   att   { p = %, w = weeks }   attended at least p% of the raids (time-based, Core/Attendance.lua) in the last w weeks
--   rank  { i = rank index }     guild rank i or higher (0 = Guild Master)
--   main  {}                     main characters only (Members' main / alt link, both ways)
--   guild {}                     guild members only (no guests)
--   cd    { w = weeks }          no other prized item in the last w weeks
--   order { g = { { tokens }... } }  specs that go first: "ROGUE" (the class) or "ROGUE:Combat"; required = only these
--   queue { n = { keys } }       named players in order; the next one in the raid who meets the other rules
--   pair  {}                     the item's two IDs go to the same player (the second follows the first)
--   bis   {}                     only players with it on their main-spec BiS list
--   vote  { s = "all" | "3q" | "2t" | "half" }   the council decides (no rolls): that share of the council members
--                                in the raid must vote for the winner; an award against a rule needs the same count
--                                (all of them when the item has no vote rule), with a reason everyone sees.
-- Sync: the guild HELLO carries a digest hash (zd); a member whose hash differs gets a digest (PZD) from one other
-- member and asks for what it lacks (PZW -> PZG). A change goes to the guild at once (PZU).
local addonName, ns = ...

local Prized = ns:NewModule("Prized")
local Util = ns.Util

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local tsort, tconcat, tinsert = table.sort, table.concat, table.insert
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local strformat = string.format

local DAY = 86400
local WEEK = 7 * DAY
local KINDS = { I = true, G = true, H = true }
local MAX_ITEMS = 40                  -- prized item records (not removed)
local MAX_GIVEN = 600                 -- hand-outs kept
local MAX_HIST = 400                  -- rule changes kept
local GIVEN_KEEP = 400 * DAY
local HIST_KEEP = 365 * DAY
local TOMBSTONE_KEEP = 60 * DAY
local MAX_WHY = 140
local MAX_TEXT = 200
local MAX_QUEUE = 12
local MAX_GROUPS = 3
local MAX_TOKENS = 12
local MAX_DIGEST_ITEMS = 1500
local MAX_ID_LEN = 40
local MAX_KEY_LEN = 48
local MAX_ITEM_LEN = MAX_ID_LEN + 3
local ROUND_WINDOW = 20
local DELAY_WRITER = { 0.5, 2.5 }
local DELAY_MEMBER = { 3, 8 }
local SIZE_HEADROOM = 0.1
local ATT_NIGHTS = 80                 -- nights looked at for "the last w weeks" (more than any team raids in 12 weeks)

Prized.MAX_ITEMS, Prized.MAX_WHY, Prized.MAX_QUEUE, Prized.MAX_GROUPS = MAX_ITEMS, MAX_WHY, MAX_QUEUE, MAX_GROUPS

local roundSeen, answeredAt = {}, -1000
local idCounter = 0
local demo
local attCache = {}                   -- [weeks] = { at = GetTime(), by = { [player] = pct } }
local itemIndex                       -- [itemID] = record id (live records), rebuilt on change

local function Now() return (GetServerTime and GetServerTime()) or time() end
local function Guild() return ns.Guild end
local function Me() return Util.PlayerKey() end
local function DemoOn() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() or false end

local function GuildKey()
    local G = Guild()
    return G and G.GetGuildKey and G:GetGuildKey() or nil
end

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

local function RateLimit(key, seconds)
    local Comm = ns.Comm
    if not (Comm and Comm.RateLimit) then return true end
    return Comm:RateLimit(key, seconds)
end

local function Changed()
    itemIndex = nil
    Util.Debounce("prized-changed", 0.15, function() ns:Fire("PRIZED_UPDATED") end)
end

local function Root(create)
    local db = ns.db
    local g = GuildKey()
    if not db or not g then return nil end
    if type(db.prized) ~= "table" then
        if not create then return nil end
        db.prized = {}
    end
    local r = db.prized[g]
    if type(r) ~= "table" then
        if not create then return nil end
        r = {}
        db.prized[g] = r
    end
    for k in pairs(KINDS) do
        if type(r[k]) ~= "table" then r[k] = {} end
    end
    return r
end

-- What the UI and the rule checks read: the saved root, or demo mode's own.
local function State()
    if DemoOn() then
        if not demo then Prized:BuildDemo() end
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
    return prefix .. strformat("%x", now) .. Util.Hash({ Me() or "", now, idCounter, GetTime() }):sub(1, 4)
end

local function SameAccount(a, b)
    if a == b then return true end
    local G = Guild()
    return (G and G.SameAccount and G:SameAccount(a, b)) and true or false
end

---------------------------------------------------------------------------
-- Rights
---------------------------------------------------------------------------

-- The GM and the guild council set the rules.
function Prized:CanEdit(key)
    key = key or Me()
    local G = Guild()
    if type(key) ~= "string" or not G then return false end
    if DemoOn() and Util.IsMe(key) then return true end
    return (G.IsGM and G:IsGM(key)) or (G.IsGuildCouncil and G:IsGuildCouncil(key)) or false
end

-- Who may record a hand-out: whoever this client sees as council (the GM, the guild council, the raid's council
-- while I am in that raid), or a raid planner / raid log member (raid leaders who run the loot).
function Prized:CanRecordGiven(key)
    local G = Guild()
    if type(key) ~= "string" or not G then return false end
    if DemoOn() and Util.IsMe(key) then return true end
    return (G.IsGM and G:IsGM(key)) or (G.IsGuildCouncil and G:IsGuildCouncil(key))
        or (G.IsCouncil and G:IsCouncil(key, true)) or (G.IsRaidLogMember and G:IsRaidLogMember(key)) or false
end

---------------------------------------------------------------------------
-- The rules: their order, words and defaults
---------------------------------------------------------------------------

-- In the order they are listed on the page and in the Add rule menu.
Prized.RULES = {
    { key = "att", label = "Attendance", desc = "share of raid time over some weeks", icon = "calendar" },
    { key = "rank", label = "Rank", desc = "lowest guild rank that can get it", icon = "rank" },
    { key = "main", label = "Mains only", desc = "linked alts can't get it", icon = "person" },
    { key = "guild", label = "Guild only", desc = "no guests or pugs", icon = "shield" },
    { key = "cd", label = "Cooldown", desc = "no other prized item for a while", icon = "hourglass" },
    { key = "order", label = "Spec order", desc = "which specs go first", icon = "order" },
    { key = "queue", label = "Queue", desc = "named players, in order", icon = "queue" },
    { key = "pair", label = "Pair", desc = "two items go to the same player", icon = "pair" },
    { key = "bis", label = "On BiS list", desc = "only players who listed it", icon = "bis" },
    { key = "vote", label = "Council vote", desc = "how many must agree; no rolls", icon = "vote" },
}
Prized.RULE = {}
for i, d in ipairs(Prized.RULES) do
    d.order = i
    Prized.RULE[d.key] = d
end

Prized.ATT_PCT = { 50, 60, 70, 75, 80, 85, 90 }
Prized.ATT_WEEKS = { 2, 4, 6, 8, 12 }
Prized.CD_WEEKS = { 1, 2, 3, 4, 6, 8, 12 }
Prized.VOTE_SHARES = {
    { key = "all", label = "Everyone", long = "all council members in the raid" },
    { key = "3q", label = "3 in 4", long = "3 in 4 council members in the raid" },
    { key = "2t", label = "2 in 3", long = "2 in 3 council members in the raid" },
    { key = "half", label = "Most", long = "more than half the council members in the raid" },
}
local VOTE_SHARE = {}
for _, v in ipairs(Prized.VOTE_SHARES) do VOTE_SHARE[v.key] = v end

local function Weeks(w) return w == 1 and "1 week" or (tostring(w) .. " weeks") end

-- Guild ranks as this client sees them: { { i = index, name = }, ... } by index (0 = Guild Master).
function Prized:GetRanks()
    local G = Guild()
    local byIndex = {}
    for _, key in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        local m = G:GetMember(key)
        local i = m and tonumber(m.rankIndex)
        if i and m.rankName and not byIndex[i] then byIndex[i] = m.rankName end
    end
    local out = {}
    for i = 0, 9 do
        if byIndex[i] then out[#out + 1] = { i = i, name = byIndex[i] } end
    end
    return out
end

function Prized:RankName(i)
    for _, r in ipairs(self:GetRanks()) do
        if r.i == i then return r.name end
    end
    return "rank " .. tostring(i)
end

-- A spec token's words: "Rogues" / "Combat rogues" / "Feral druids".
local CLASS_PLURAL = { WARRIOR = "warriors", PALADIN = "paladins", HUNTER = "hunters", ROGUE = "rogues",
                       PRIEST = "priests", SHAMAN = "shamans", MAGE = "mages", WARLOCK = "warlocks", DRUID = "druids" }
function Prized:TokenText(tok, capital)
    local cls, spec = tostring(tok):match("^(%u+):?(.*)$")
    local plural = CLASS_PLURAL[cls or ""] or tostring(tok)
    local s = (spec and spec ~= "") and (spec .. " " .. plural) or plural
    if capital then s = s:sub(1, 1):upper() .. s:sub(2) end
    return s
end

function Prized:GroupText(g, capital)
    local parts = {}
    for i, tok in ipairs(g or {}) do parts[#parts + 1] = self:TokenText(tok, capital and i == 1) end
    if #parts == 0 then return capital and "Nobody yet" or "nobody yet" end
    if #parts <= 2 then return tconcat(parts, " and ") end
    return tconcat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end

-- One rule as a sentence and a short line under it (sub): (text, sub).
function Prized:RuleText(key, v, rec)
    v = v or {}
    if key == "att" then
        return strformat("At least %d%% attendance in the last %s", v.p or 75, Weeks(v.w or 6)),
            "time in the raid, from the raid log"
    elseif key == "rank" then
        return strformat("Rank %s or higher", self:RankName(v.i or 0)), "lower ranks and guests can't get it"
    elseif key == "main" then
        return "Main characters only", "linked alts don't count"
    elseif key == "guild" then
        return "Guild members only", "no guests or pugs"
    elseif key == "cd" then
        return strformat("No other prized item in the last %s", Weeks(v.w or 4)), nil
    elseif key == "order" then
        local g = v.g or {}
        local rest = {}
        for i = 2, #g do rest[#rest + 1] = self:GroupText(g[i]) end
        if v.m == "r" then
            -- required: only the listed specs, the first group before the others
            return strformat("Only %s", self:GroupText(g[1])),
                #rest > 0 and ("then " .. tconcat(rest, ", then ")) or "nobody else can get it"
        end
        rest[#rest + 1] = "everyone"
        return strformat("%s first", self:GroupText(g[1], true)), "then " .. tconcat(rest, ", then ")
    elseif key == "queue" then
        return "Goes to the next player in the queue", "set by the council; someone who doesn't meet the other rules is skipped"
    elseif key == "pair" then
        return "Both go to the same player", "the second one follows the first"
    elseif key == "bis" then
        return "Only players with it on their BiS list", "their main spec list"
    elseif key == "vote" then
        local s = VOTE_SHARE[v.s or "all"] or VOTE_SHARE.all
        return "The Loot Council decides, no rolls", strformat("%s vote for the winner", s.long)
    end
    return tostring(key), nil
end

-- A short form of a rule's value for the history ("75% / 6 wk").
local function ShortValue(key, v)
    v = v or {}
    if key == "att" then return strformat("%d%% over %s", v.p or 0, Weeks(v.w or 0))
    elseif key == "rank" then return Prized:RankName(v.i or 0)
    elseif key == "cd" then return Weeks(v.w or 0)
    elseif key == "order" then
        local parts = {}
        for _, g in ipairs(v.g or {}) do parts[#parts + 1] = Prized:GroupText(g) end
        return tconcat(parts, " > ")
    elseif key == "queue" then
        local parts = {}
        for _, k in ipairs(v.n or {}) do parts[#parts + 1] = Util.ShortName(k) end
        return #parts > 0 and tconcat(parts, ", ") or "empty"
    elseif key == "vote" then return (VOTE_SHARE[v.s or "all"] or VOTE_SHARE.all).label:lower()
    end
    return nil
end

-- Default values of a rule just added.
function Prized:DefaultRule(key)
    if key == "att" then return { m = "r", p = 75, w = 6 }
    elseif key == "rank" then
        local ranks = self:GetRanks()
        local i = #ranks >= 3 and ranks[#ranks - 1].i or (ranks[#ranks] and ranks[#ranks].i or 1)
        return { m = "r", i = i }
    elseif key == "cd" then return { m = "r", w = 4 }
    elseif key == "order" then return { m = "p", g = { {} } }
    elseif key == "queue" then return { m = "r", n = {} }
    elseif key == "vote" then return { m = "r", s = "all" }
    end
    return { m = "r" }
end

-- Starting points for a new item: { key, label, desc, rules(ids) }.
Prized.TEMPLATES = {
    { key = "legendary", label = "Legendary", icon = "prized",
      desc = "80% / 8 wk · Mains · Guild · Queue · Pair · Council",
      rules = function(n)
          local r = { att = { m = "r", p = 80, w = 8 }, main = { m = "r" }, guild = { m = "r" },
                      queue = { m = "r", n = {} }, vote = { m = "r", s = "all" } }
          if n > 1 then r.pair = { m = "r" } end
          return r
      end },
    { key = "trinket", label = "Top trinket", icon = "poll",
      desc = "75% / 6 wk · Rank · Mains · Cooldown · Spec order",
      rules = function()
          return { att = { m = "r", p = 75, w = 6 }, rank = Prized:DefaultRule("rank"), main = { m = "r" },
                   guild = { m = "r" }, cd = { m = "r", w = 4 }, order = { m = "p", g = { {} } },
                   vote = { m = "r", s = "all" } }
      end },
    { key = "copy", label = "Copy from…", icon = "notes", desc = "the rules of another prized item" },
    { key = "blank", label = "Nothing yet", icon = "plus", desc = "start empty, add rules one by one",
      rules = function() return {} end },
}

---------------------------------------------------------------------------
-- Cleaning what arrives (and what is saved)
---------------------------------------------------------------------------

local function Str(s, maxLen)
    if type(s) ~= "string" then return nil end
    s = s:gsub("[%c|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    if #s > maxLen then
        s = s:sub(1, maxLen)
        -- (never cut inside a UTF-8 character)
        while #s > 0 and s:byte(#s) >= 128 and s:byte(#s) < 192 do s = s:sub(1, #s - 1) end
        if #s > 0 and s:byte(#s) >= 192 then s = s:sub(1, #s - 1) end
    end
    return s
end

local function Int(n, lo, hi)
    n = tonumber(n)
    if not n or n ~= n then return nil end
    n = floor(n)
    if n < lo or n > hi then return nil end
    return n
end

local function Mode(m, allowPriority)
    if m == "p" and allowPriority then return "p" end
    return "r"
end

local VALID_CLASS = {}
for c in pairs(CLASS_PLURAL) do VALID_CLASS[c] = true end

local function CleanToken(t)
    if type(t) ~= "string" or #t > 40 then return nil end
    local cls, spec = t:match("^(%u+):?(.*)$")
    if not cls or not VALID_CLASS[cls] then return nil end
    if spec ~= "" then
        local ok = false
        for _, s in ipairs(ns.SPECS and ns.SPECS[cls] or {}) do
            if s.label == spec then ok = true break end
        end
        if not ok then return nil end
        return cls .. ":" .. spec
    end
    return cls
end

-- One rule's value, or nil (dropped).
local function CleanRule(key, v)
    if type(v) ~= "table" then return nil end
    if key == "att" then
        local p, w = Int(v.p, 1, 100), Int(v.w, 1, 26)
        if not p or not w then return nil end
        return { m = Mode(v.m, true), p = p, w = w }
    elseif key == "rank" then
        local i = Int(v.i, 0, 9)
        if not i then return nil end
        return { m = Mode(v.m, true), i = i }
    elseif key == "main" or key == "guild" or key == "bis" then
        return { m = Mode(v.m, true) }
    elseif key == "pair" then
        return { m = Mode(v.m, true) }
    elseif key == "cd" then
        local w = Int(v.w, 1, 26)
        if not w then return nil end
        return { m = Mode(v.m, true), w = w }
    elseif key == "order" then
        local g = {}
        for gi = 1, MAX_GROUPS do
            local src = type(v.g) == "table" and v.g[gi]
            if type(src) ~= "table" then break end
            local out, seen = {}, {}
            for ti = 1, MAX_TOKENS do
                local tok = CleanToken(src[ti])
                if src[ti] == nil then break end
                if tok and not seen[tok] then seen[tok] = true; out[#out + 1] = tok end
            end
            g[#g + 1] = out
        end
        if #g == 0 then g[1] = {} end
        return { m = Mode(v.m, true), g = g }
    elseif key == "queue" then
        local n, seen = {}, {}
        for i = 1, MAX_QUEUE do
            local k = v.n and v.n[i]
            if k == nil then break end
            k = WireKey(k)
            if k and not seen[k] then seen[k] = true; n[#n + 1] = k end
        end
        return { m = Mode(v.m, true), n = n }
    elseif key == "vote" then
        local s = VOTE_SHARE[v.s] and v.s or "all"
        return { m = "r", s = s }
    end
    return nil
end

local function CleanRules(r, nIds)
    local out = {}
    if type(r) ~= "table" then return out end
    for key in pairs(Prized.RULE) do
        local c = r[key] ~= nil and CleanRule(key, r[key]) or nil
        if c and not (key == "pair" and nIds < 2) then out[key] = c end
    end
    return out
end

local function CleanItem(r)
    if type(r) ~= "table" or not IsId(r.id) then return nil end
    local by, rev = WireKey(r.by), Int(r.rev, 1, 4102444800)
    if not by or not rev then return nil end
    if r.del then return { id = r.id, by = by, rev = rev, del = true } end
    local ids, seen = {}, {}
    for i = 1, 2 do
        local n = r.ids and Int(r.ids[i], 1, 999999)
        if n and not seen[n] then seen[n] = true; ids[#ids + 1] = n end
    end
    if #ids == 0 or tostring(ids[1]) ~= r.id then return nil end
    return { id = r.id, ids = ids, r = CleanRules(r.r, #ids), by = by, rev = rev }
end

local function CleanGiven(r)
    if type(r) ~= "table" or not IsId(r.id) or not IsId(r.i) then return nil end
    local by, to, rev, at = WireKey(r.by), WireKey(r.to), Int(r.rev, 1, 4102444800), Int(r.at, 1, 4102444800)
    local it = Int(r.it, 1, 999999)
    if not by or not to or not rev or not at or not it then return nil end
    local out = { id = r.id, i = r.i, it = it, to = to, by = by, at = at, rev = rev }
    if type(r.ov) == "table" then
        local ov = {}
        for i = 1, 10 do
            local k = r.ov[i]
            if k == nil then break end
            if Prized.RULE[k] then ov[#ov + 1] = k end
        end
        if #ov > 0 then out.ov = ov end
    end
    out.why = Str(r.why, MAX_WHY)
    out.ag = Int(r.ag, 0, 40)
    out.of = Int(r.of, 0, 40)
    if r.del then out.del = true end
    return out
end

local function CleanHist(r)
    if type(r) ~= "table" or not IsId(r.id) or not IsId(r.i) then return nil end
    local by, rev, at = WireKey(r.by), Int(r.rev, 1, 4102444800), Int(r.at, 1, 4102444800)
    local t = Str(r.t, MAX_TEXT)
    if not by or not rev or not at or not t then return nil end
    return { id = r.id, i = r.i, by = by, at = at, rev = rev, t = t }
end

local CLEAN = { I = CleanItem, G = CleanGiven, H = CleanHist }

---------------------------------------------------------------------------
-- Merging (the same on every client, whatever order things arrive in)
---------------------------------------------------------------------------

local function Newer(a, b)
    if not b then return true end
    if a.rev ~= b.rev then return a.rev > b.rev end
    return Util.Hash(a) > Util.Hash(b)
end

local function CountLive(t)
    local n = 0
    for _, r in pairs(t) do
        if not r.del then n = n + 1 end
    end
    return n
end

local function Merge(root, kind, rec, live)
    local t = root[kind]
    local cur = t[rec.id]
    if live and rec.rev > Now() + 600 then return false end
    if kind == "I" then
        if not Prized:CanEdit(rec.by) then return false end
        if cur and cur.del and not rec.del then return false end           -- a removal wins
        if not cur and not rec.del and CountLive(t) >= MAX_ITEMS then return false end
        if cur and not Newer(rec, cur) and not (rec.del and not cur.del) then return false end
    elseif kind == "G" then
        if cur then
            if cur.del then return false end
            -- only a void (by its writer or anyone who sets the rules) changes a hand-out
            if not rec.del or not (rec.by == cur.by or Prized:CanEdit(rec.by)) then return false end
            if rec.to ~= cur.to or rec.it ~= cur.it then return false end
        else
            if not Prized:CanRecordGiven(rec.by) then return false end
            if CountLive(t) >= MAX_GIVEN then return false end
        end
    else
        if cur then return false end                                       -- never edited
        if not Prized:CanEdit(rec.by) then return false end
        if CountLive(t) >= MAX_HIST then return false end
    end
    t[rec.id] = rec
    return true
end

local function StoreRecord(kind, r, live)
    if not KINDS[kind] then return false end
    local root = Root(true)
    if not root then return false end
    local rec = CLEAN[kind](r)
    if not rec then return false end
    return Merge(root, kind, rec, live), rec
end

-- My own change: stored (merged like anyone's), then sent to the guild.
local function Commit(kind, rec)
    rec.by = rec.by or Me()
    if DemoOn() then
        local st = State()
        rec.rev = NextRev(st[kind][rec.id])
        local clean = CLEAN[kind](rec)
        if not clean then return false end
        st[kind][rec.id] = clean
        Changed()
        return true, clean
    end
    local root = Root(true)
    if not root then return false end
    rec.rev = NextRev(root[kind][rec.id])
    local clean = CLEAN[kind](rec)
    if not clean then return false end
    local Comm = ns.Comm
    if Comm and Comm.Fits and not Comm:Fits({ t = "PZU", k = kind, r = clean }, SIZE_HEADROOM) then
        ns:Print("this change is too big to share with the guild.")
        return false
    end
    if not Merge(root, kind, clean, true) then return false end
    Send({ t = "PZU", k = kind, r = clean }, "GUILD", nil, "data")
    Changed()
    return true, clean
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

local function Index()
    if itemIndex then return itemIndex end
    -- (State first: building the demo resets the index)
    local st = State()
    local idx = {}
    for id, rec in pairs(st and st.I or {}) do
        if not rec.del then
            for _, n in ipairs(rec.ids) do idx[n] = id end
        end
    end
    itemIndex = idx
    return idx
end

-- The prized record an item ID belongs to (either of a pair), or nil.
function Prized:ForItem(itemID)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    local id = Index()[itemID]
    local st = State()
    return id and st and st.I[id] or nil
end

function Prized:IsPrized(itemID) return self:ForItem(itemID) ~= nil end

function Prized:Get(id)
    local st = State()
    local rec = st and st.I[id]
    return (rec and not rec.del) and rec or nil
end

-- Where an item drops: { raidKey, raidName, raidOrder, bossName, bossOrder } (from the item database).
local placeCache = {}
function Prized:Place(itemID)
    local c = placeCache[itemID]
    if c then return c end
    local ItemDB = ns.ItemDB
    local src = ItemDB and ItemDB.GetSources and ItemDB:GetSources(itemID, "raids")[1]
    local ref = src and src.ref
    c = { raidKey = ref and ref.raid and ref.raid.key or "other", raidName = ref and ref.raid and ref.raid.name or "Other",
          bossName = ref and ref.boss and ref.boss.name or nil, phase = ref and ref.phase or 9 }
    local order, bossOrder = 99, 99
    for i, raid in ipairs(ns.Data and ns.Data.Raids or {}) do
        if raid.key == c.raidKey then
            order = i
            for j, b in ipairs(raid.bosses or {}) do
                if ref and ref.boss and b.key == ref.boss.key then bossOrder = j break end
            end
            break
        end
    end
    c.raidOrder, c.bossOrder = order, bossOrder
    placeCache[itemID] = c
    return c
end

-- The live records sorted by raid (as the item database lists them), then boss, then name.
function Prized:GetItems()
    local out = {}
    local st = State()
    for _, rec in pairs(st and st.I or {}) do
        if not rec.del then out[#out + 1] = rec end
    end
    tsort(out, function(a, b)
        local pa, pb = self:Place(a.ids[1]), self:Place(b.ids[1])
        if pa.raidOrder ~= pb.raidOrder then return pa.raidOrder < pb.raidOrder end
        if pa.bossOrder ~= pb.bossOrder then return pa.bossOrder < pb.bossOrder end
        return a.id < b.id
    end)
    return out
end

-- A record's name: the item's name, or the pair's shared name ("Warglaive of Azzinoth").
function Prized:Name(rec)
    local ItemDB = ns.ItemDB
    local name = ItemDB and ItemDB.GetName and ItemDB:GetName(rec.ids[1]) or ("item " .. rec.ids[1])
    if #rec.ids > 1 then
        local other = ItemDB and ItemDB.GetName and ItemDB:GetName(rec.ids[2])
        if other and other == name then return name .. " (pair)" end
        if other then return name .. " + " .. other end
    end
    return name
end

-- Hand-outs (not voided), newest first; filter: { i = record id, to = player (with their linked characters),
-- since = time, item = item ID }.
function Prized:GetGiven(filter)
    filter = filter or {}
    local out = {}
    local st = State()
    for _, g in pairs(st and st.G or {}) do
        if not g.del and (not filter.i or g.i == filter.i) and (not filter.item or g.it == filter.item)
            and (not filter.since or g.at >= filter.since) and (not filter.to or SameAccount(g.to, filter.to)) then
            out[#out + 1] = g
        end
    end
    tsort(out, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.id > b.id
    end)
    return out
end

-- An item's history, newest first: hand-outs and rule changes, { kind = "G" | "H", rec }.
function Prized:GetHistory(id)
    local out = {}
    local st = State()
    for _, g in pairs(st and st.G or {}) do
        if g.i == id and not g.del then out[#out + 1] = { kind = "G", rec = g, at = g.at } end
    end
    for _, h in pairs(st and st.H or {}) do
        if h.i == id then out[#out + 1] = { kind = "H", rec = h, at = h.at } end
    end
    tsort(out, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.rec.id > b.rec.id
    end)
    return out
end

-- The last rule change of an item (its H record), or nil.
function Prized:LastChange(id)
    for _, e in ipairs(self:GetHistory(id)) do
        if e.kind == "H" then return e.rec end
    end
    return nil
end

---------------------------------------------------------------------------
-- How a player stands against the rules
---------------------------------------------------------------------------

-- A player's attendance % over the last `weeks` weeks (time-based), or nil when this client can't know it (another
-- player's figure needs the raid log; mine comes from a raid log reader) or no raid in that time expected them.
-- Second result: true when it is unknown (not "no raids").
function Prized:Attendance(key, weeks)
    local Att = ns.Attendance
    if not Att or type(key) ~= "string" then return nil, true end
    local cutoff = Now() - weeks * WEEK
    if Att.CanSeeAll and Att:CanSeeAll() then
        local c = attCache[weeks]
        if not c or GetTime() - c.at > 30 then
            c = { at = GetTime(), by = {} }
            local nights = {}
            for _, n in ipairs(Att:ClosedNights(ATT_NIGHTS) or {}) do
                if (n.start or 0) >= cutoff then nights[#nights + 1] = n end
            end
            local sums = {}
            for _, item in ipairs(Att:Results(nights, Att:Rules()) or {}) do
                local seen = {}
                for k, r in pairs(item.results or {}) do
                    if r.kind and r.counts then
                        local pk = Att:PlayerOf(k)
                        if not seen[pk] then
                            seen[pk] = true
                            local s = sums[pk] or { sum = 0, n = 0 }
                            s.sum, s.n = s.sum + (r.credit or 0), s.n + 1
                            sums[pk] = s
                        end
                    end
                end
            end
            for pk, s in pairs(sums) do c.by[pk] = floor(s.sum * 100 / s.n + 0.5) end
            attCache[weeks] = c
        end
        local p = c.by[Att:PlayerOf(key)] or c.by[key]
        if not p then
            for other, v in pairs(c.by) do
                if SameAccount(other, key) then p = v break end
            end
        end
        return p, false
    end
    if not Util.IsMe(key) then return nil, true end
    local mine = Att.GetMine and Att:GetMine()
    if not mine then
        if Att.RequestMine then Att:RequestMine() end
        return nil, true
    end
    local sum, n = 0, 0
    for _, e in ipairs(mine.h or {}) do
        if (e.d or 0) >= cutoff and e.c and e.k and e.k ~= "h" then
            sum, n = sum + e.c, n + 1
        end
    end
    if n == 0 then return nil, false end
    return floor(sum / n + 0.5), false
end

-- A player's class and main spec label (from their BiS list), else the roster's class.
function Prized:ClassSpec(key, hint)
    local Store, G = ns.Store, Guild()
    local rec = Store and Store.Get and Store:Get(key)
    local d = rec and rec.data
    local cls = (d and d.cl) or (hint and hint.classFile) or (G and G.GetClass and G:GetClass(key))
    local spec = (d and d.sp) or (hint and hint.spec)
    return cls, spec
end

-- Which group of the spec order a player is in (1..n), #groups + 1 when none, nil when unknown.
local function OrderGroup(v, cls, spec)
    if not cls then return nil end
    local needSpec = false
    for gi, g in ipairs(v.g or {}) do
        for _, tok in ipairs(g) do
            local c, s = tok:match("^(%u+):?(.*)$")
            if c == cls then
                if s == "" then return gi end
                if spec == nil then needSpec = true
                elseif spec == s or (s == "Feral" and spec:find("^Feral")) then return gi end
            end
        end
    end
    if needSpec then return nil end
    return #(v.g or {}) + 1
end

local function MainOf(key)
    local Att = ns.Attendance
    if Att and Att.PlayerOf then return Att:PlayerOf(key) end
    return key
end

local function OnBiSList(rec, key)
    local Store = ns.Store
    if not Store then return nil end
    local list = Store.Get and Store:Get(key)
    if not list then return nil end
    for _, id in ipairs(rec.ids) do
        for _, w in ipairs(Store:GetWanters(id, { list = "ms", includeObtained = true }) or {}) do
            if w.key == key then return true end
        end
    end
    return false
end

-- Has `key` (or a linked character) received this record's item ids? (count of ids received)
local function ReceivedCount(rec, key)
    local n, got = 0, {}
    for _, g in ipairs(Prized:GetGiven({ i = rec.id, to = key })) do
        if not got[g.it] then got[g.it] = true; n = n + 1 end
    end
    return n
end

-- The pair's holder: the player who got one of its items and not yet the other, or nil.
function Prized:PairHolder(rec)
    if #rec.ids < 2 then return nil end
    local given = self:GetGiven({ i = rec.id })
    local last = given[1]
    if not last then return nil end
    if ReceivedCount(rec, last.to) >= #rec.ids then return nil end
    return last.to, last
end

local function OneRule(self, rec, rkey, v, key, ctx)
    local res = { key = rkey, m = v.m or "r" }
    if rkey == "att" then
        local p, unknown = self:Attendance(key, v.w)
        if p then
            res.ok = p >= v.p
            res.value = strformat("%d%%", p)
            res.num = p
        elseif unknown then
            res.ok = nil
            res.value = "?"
        else
            res.ok = false
            res.value = "no raids"
            res.num = 0
        end
        res.why = res.ok == false and (p and strformat("%d%% attendance", p) or "no raids in that time") or nil
    elseif rkey == "rank" then
        local G = Guild()
        local m = G and G.GetMember and G:GetMember(key)
        if m and tonumber(m.rankIndex) then
            res.ok = m.rankIndex <= v.i
            res.value = m.rankName
            res.why = not res.ok and (tostring(m.rankName) .. " rank") or nil
        elseif G and G.GetMember then
            res.ok, res.value, res.why = false, "guest", "not in the guild"
        end
    elseif rkey == "main" then
        local main = MainOf(key)
        res.ok = main == key
        res.value = res.ok and "Main" or "Alt"
        res.why = not res.ok and ("alt of " .. Util.ShortName(main)) or nil
    elseif rkey == "guild" then
        local G = Guild()
        res.ok = (G and G.IsInGuild and G:IsInGuild(key)) and true or false
        res.value = res.ok and "Member" or "Guest"
        res.why = not res.ok and "guest" or nil
    elseif rkey == "cd" then
        local since = Now() - v.w * WEEK
        local last
        for _, g in ipairs(self:GetGiven({ to = key, since = since })) do
            if g.i ~= rec.id then last = g break end
        end
        res.ok = last == nil
        if last then
            local other = self:ForItem(last.it)
            local name = ns.ItemDB and ns.ItemDB.GetName and ns.ItemDB:GetName(last.it) or "a prized item"
            res.value = name
            res.free = last.at + v.w * WEEK
            res.why = strformat("had %s %s", name, Util.FormatAgo and Util.FormatAgo(last.at) or "")
            res.lastItem = other and other.id or nil
        else
            res.value = "none"
        end
    elseif rkey == "order" then
        local cls, spec = self:ClassSpec(key, ctx and ctx.hint)
        local gi = OrderGroup(v, cls, spec)
        local n = #(v.g or {})
        res.group = gi
        if gi == nil then
            res.ok = nil
            res.value = "?"
        elseif v.m == "r" then
            res.ok = gi <= n
            res.value = res.ok and (gi == 1 and "First group" or ("Group " .. gi)) or "Not listed"
            res.why = not res.ok and strformat("%s not listed", spec and (spec .. " " .. (CLASS_PLURAL[cls] or "")) or
                (CLASS_PLURAL[cls] or "class")) or nil
        else
            res.ok = true
            res.value = gi == 1 and "First group" or (gi <= n and ("Group " .. gi) or "After them")
        end
        res.prio = gi or (n + 1)
    elseif rkey == "queue" then
        local pos = self:QueuePlace(rec, key, ctx)
        res.pos = pos
        local q = v.n or {}
        if #q == 0 then
            res.ok, res.value = true, "empty"
            res.prio = 1
        elseif pos then
            res.ok = v.m ~= "r" or pos == 1
            res.value = "#" .. pos
            res.prio = pos
            res.why = not res.ok and strformat("#%d in the queue", pos) or nil
        else
            res.ok = v.m ~= "r" and true or false
            res.value = "not queued"
            res.prio = MAX_QUEUE + 1
            res.why = v.m == "r" and "not in the queue" or nil
        end
    elseif rkey == "pair" then
        local holder = self:PairHolder(rec)
        if holder then
            local mine = SameAccount(holder, key)
            res.ok = v.m ~= "r" or mine
            res.value = mine and "Has the other one" or ("Goes to " .. Util.ShortName(holder))
            res.prio = mine and 0 or 1
            res.why = not mine and (Util.ShortName(holder) .. " has the other one") or nil
        else
            res.ok, res.value, res.prio = true, "None given yet", 1
        end
    elseif rkey == "bis" then
        local on = OnBiSList(rec, key)
        if on == nil then
            res.ok, res.value = nil, "?"
        else
            res.ok = on
            res.value = on and "On your list" or "Not listed"
            if not Util.IsMe(key) then res.value = on and "On their list" or "Not listed" end
            res.why = not on and "not on their BiS list" or nil
        end
        res.prio = on and 0 or 1
    elseif rkey == "vote" then
        res.ok = true
        res.info = true
    end
    -- A priority rule never keeps anyone out (it sorts).
    if res.m == "p" and res.ok == false then
        res.soft = true
    end
    return res
end

-- How `key` stands against the record's rules: { ok = true | false | nil (unknown), rules = { per rule, in order },
-- fail = the first failed required rule, failKey, prio = { sort numbers }, required = n, met = n }.
-- ctx (optional): { present = { [key] = true } players who could take it now (the raid), hint = { classFile, spec },
-- skip = { [ruleKey] = true } }.
function Prized:Check(rec, key, ctx)
    local out = { rules = {}, ok = true, required = 0, met = 0, prio = {} }
    if type(rec) ~= "table" or type(key) ~= "string" then
        out.ok = nil
        return out
    end
    local unknown = false
    for _, d in ipairs(self.RULES) do
        local v = rec.r[d.key]
        if v and not (ctx and ctx.skip and ctx.skip[d.key]) then
            local res = OneRule(self, rec, d.key, v, key, ctx)
            res.label = d.label
            out.rules[#out.rules + 1] = res
            if not res.info and res.m == "r" then
                out.required = out.required + 1
                if res.ok == true then
                    out.met = out.met + 1
                elseif res.ok == false then
                    if out.ok ~= false then
                        out.fail, out.failKey = res.why or d.label, d.key
                    end
                    out.ok = false
                else
                    unknown = true
                end
            end
        end
    end
    if out.ok == true and unknown then out.ok = nil end
    -- (1.3.5, the user: in demo mode I count as meeting every rule, to see what rolling for a prized item is like;
    -- res.demo marks the rules the demo waved through)
    if DemoOn() and Util.IsMe(key) and out.ok ~= true then
        for _, res in ipairs(out.rules) do
            if not res.info and res.m == "r" and res.ok ~= true then
                res.ok, res.demo = true, true
            end
        end
        out.ok, out.fail, out.failKey, out.met = true, nil, nil, out.required
    end
    -- the sort: the pair's holder, the queue, the spec order, then on the BiS list, then attendance (higher first)
    local by = {}
    for _, res in ipairs(out.rules) do by[res.key] = res end
    out.prio = { by.pair and by.pair.prio or 1, by.queue and by.queue.prio or 1, by.order and by.order.prio or 1,
                 (by.bis and by.bis.m == "p") and by.bis.prio or 0,
                 (by.att and by.att.m == "p") and -(by.att.num or 0) or 0 }
    out.by = by
    return out
end

-- Compare two Check results for the sort (qualifying first, then the priority rules): true when a goes first.
function Prized:Before(a, b)
    local oa, ob = a and a.ok ~= false, b and b.ok ~= false
    if oa ~= ob then return oa end
    local pa, pb = a and a.prio or {}, b and b.prio or {}
    for i = 1, max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y end
    end
    return nil
end

-- Place of `key` among the queued players still waiting for this item: 1 = next. Players who got it are skipped,
-- and (with ctx.present) players not in the raid or not meeting the other required rules. nil = not queued.
function Prized:QueuePlace(rec, key, ctx)
    local v = rec.r.queue
    if not v then return nil end
    local pos = 0
    for _, k in ipairs(v.n or {}) do
        local waiting = ReceivedCount(rec, k) < #rec.ids
        local here = true
        if waiting and ctx and ctx.present then
            here = false
            for p in pairs(ctx.present) do
                if SameAccount(p, k) then here = true break end
            end
            if here and not SameAccount(k, key) then
                local c = self:Check(rec, k, { skip = { queue = true, pair = true }, present = ctx.present })
                here = c.ok ~= false
            end
        end
        if waiting and here then
            pos = pos + 1
            if SameAccount(k, key) then return pos end
        elseif SameAccount(k, key) then
            return nil
        end
    end
    return nil
end

-- Council members in my raid (demo-aware): a sorted array.
function Prized:PresentCouncil()
    local G = Guild()
    local out = {}
    for _, k in ipairs(G and G.GetCouncilMembers and G:GetCouncilMembers() or {}) do
        if Util.IsMe(k) or (Util.IsInMyGroup and Util.IsInMyGroup(k)) then out[#out + 1] = k end
    end
    return out
end

-- Votes needed to award the item (n = council members in the raid). override: an award against a rule (the
-- item's vote rule, else every council member in the raid). 0 = no votes needed.
function Prized:NeededVotes(rec, n, override)
    n = max(1, tonumber(n) or 1)
    local v = rec and rec.r and rec.r.vote
    if not v then
        if override then return n end
        return 0
    end
    local s = v.s or "all"
    if s == "3q" then return ceil(n * 3 / 4) end
    if s == "2t" then return ceil(n * 2 / 3) end
    if s == "half" then return floor(n / 2) + 1 end
    return n
end

-- The council decides (no rolls)?
function Prized:CouncilDecides(rec)
    return rec and rec.r and rec.r.vote ~= nil or false
end

-- The rule keys a player breaks (required ones that failed), for an override's record.
function Prized:Broken(check)
    local out = {}
    for _, res in ipairs(check and check.rules or {}) do
        if res.m == "r" and res.ok == false then out[#out + 1] = res.key end
    end
    return out
end

---------------------------------------------------------------------------
-- Writing
---------------------------------------------------------------------------

local function CopyRules(r)
    local out = {}
    for k, v in pairs(r or {}) do
        local c = {}
        for f, x in pairs(v) do
            if type(x) == "table" then
                local t = {}
                for i, y in ipairs(x) do
                    if type(y) == "table" then
                        local u = {}
                        for j, z in ipairs(y) do u[j] = z end
                        t[i] = u
                    else
                        t[i] = y
                    end
                end
                c[f] = t
            else
                c[f] = x
            end
        end
        out[k] = c
    end
    return out
end
Prized.CopyRules = function(_, r) return CopyRules(r) end

-- What changed between two rule sets, in words (for the history and the guild's notification), or nil.
function Prized:DescribeChange(old, new)
    local parts = {}
    for _, d in ipairs(self.RULES) do
        local a, b = old and old[d.key], new and new[d.key]
        if a and not b then
            parts[#parts + 1] = "removed " .. d.label:lower()
        elseif b and not a then
            local sv = ShortValue(d.key, b)
            parts[#parts + 1] = "added " .. d.label:lower() .. (sv and (" (" .. sv .. ")") or "")
        elseif a and b then
            local sa, sb = ShortValue(d.key, a), ShortValue(d.key, b)
            if sa ~= sb then
                parts[#parts + 1] = strformat("%s from %s to %s", d.label:lower(), sa or "", sb or "")
            end
            if (a.m or "r") ~= (b.m or "r") then
                parts[#parts + 1] = strformat("%s now %s", d.label:lower(), b.m == "p" and "priority" or "required")
            end
        end
    end
    if #parts == 0 then return nil end
    local s = tconcat(parts, ", ")
    return s:sub(1, 1):upper() .. s:sub(2)
end

local function AddHistory(recId, text)
    if not text then return end
    Commit("H", { id = NewId("h"), i = recId, at = Now(), t = text })
end

-- Makes items prized (one record; two IDs share the rules) with the given rules. Returns the record or nil.
function Prized:Add(ids, rules, how)
    if not self:CanEdit() then return nil end
    local clean = {}
    for _, n in ipairs(ids or {}) do
        n = tonumber(n)
        if n and #clean < 2 and not self:ForItem(n) then clean[#clean + 1] = n end
    end
    if #clean == 0 then return nil end
    local id = tostring(clean[1])
    local cur = State() and State().I[id]
    local ok, rec = Commit("I", { id = id, ids = clean, r = rules or {}, rev = cur and cur.rev or nil })
    if not ok then return nil end
    AddHistory(id, "Made a prized item" .. (how and (", from the " .. how .. " start") or ""))
    return rec
end

-- Saves new rules for a record (history + notification). Returns true when saved.
function Prized:Save(id, rules)
    if not self:CanEdit() then return false end
    local cur = self:Get(id)
    if not cur then return false end
    local text = self:DescribeChange(cur.r, CleanRules(rules, #cur.ids))
    if not text then return true end
    local ok = Commit("I", { id = id, ids = cur.ids, r = rules })
    if not ok then return false end
    AddHistory(id, text)
    return true
end

function Prized:Remove(id)
    if not self:CanEdit() then return false end
    local cur = self:Get(id)
    if not cur then return false end
    local ok = Commit("I", { id = id, del = true })
    return ok and true or false
end

-- A hand-out of a prized item (the awarding council member's client). info: { why, ov, ag, of }.
function Prized:RecordGiven(itemID, winner, info)
    local rec = self:ForItem(itemID)
    winner = WireKey(winner)
    if not rec or not winner then return false end
    info = info or {}
    local at = Now()
    local ok = Commit("G", { id = NewId("g"), i = rec.id, it = tonumber(itemID), to = winner, at = at,
                             ov = info.ov, why = info.why, ag = info.ag, of = info.of })
    return ok and true or false
end

-- Voids the hand-out that matches a voided loot log award (same item and winner, within a day of it).
function Prized:VoidGiven(itemID, winner, ts)
    local best
    for _, g in ipairs(self:GetGiven({ item = tonumber(itemID), to = winner })) do
        if not ts or math.abs(g.at - ts) < DAY then best = g break end
    end
    if not best then return false end
    local copy = {}
    for k, v in pairs(best) do copy[k] = v end
    copy.del, copy.by = true, Me()
    local ok = Commit("G", copy)
    return ok and true or false
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

function Prized:GetDigest()
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

function Prized:GetDigestHash()
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
        Send({ t = "PZG", k = kind, r = root[kind][id] }, "WHISPER", target, "data")
    end
end

-- PZU { k, r }: a change; its writer is the sender.
local function OnUpdate(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.r) ~= "table" or WireKey(msg.r.by) ~= sender then return end
    if not KINDS[msg.k] then return end
    local ok, rec = StoreRecord(msg.k, msg.r, true)
    if not ok then return end
    Changed()
    if msg.k == "H" and not Util.IsMe(rec.by) then ns:Fire("PRIZED_RULES_CHANGED", rec.i, rec.t, rec.by) end
end

-- PZG { k, r }: one record, relayed by anyone in the guild.
local function OnGive(sender, msg, dist)
    if dist ~= "WHISPER" or not KINDS[msg.k] or type(msg.r) ~= "table" then return end
    if StoreRecord(msg.k, msg.r) then Changed() end
end

local function OnWant(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.w) ~= "table" or not RateLimit("PZW:" .. sender, 5) then return end
    local root = Root(false)
    if not root then return end
    for i = 1, MAX_DIGEST_ITEMS do
        local item = msg.w[i]
        if item == nil then break end
        if type(item) == "string" and #item <= MAX_ITEM_LEN + 2 then SendItem(root, item, sender) end
    end
end

local function CleanDigest(d)
    if type(d) ~= "table" then return nil end
    local out, n = {}, 0
    for item, h in pairs(d) do
        n = n + 1
        if n > MAX_DIGEST_ITEMS then return nil end
        if type(item) ~= "string" or #item > MAX_ITEM_LEN + 2 or not item:find("^[IGH]:") then return nil end
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
    local mine = Prized:GetDigest()
    local want, give = {}, {}
    for item, h in pairs(theirs) do
        if mine[item] ~= h then want[#want + 1] = item end
    end
    for item, h in pairs(mine) do
        if theirs[item] ~= h then give[#give + 1] = item end
    end
    tsort(want)
    tsort(give)
    if #want > 0 then Send({ t = "PZW", w = want }, "WHISPER", sender, "ctrl") end
    for _, item in ipairs(give) do SendItem(root, item, sender) end
end

local function OnClaim(sender, msg, dist)
    if dist ~= "GUILD" then return end
    local to = WireKey(msg.to)
    if to and not Util.IsMe(to) then roundSeen[to] = { at = GetTime() } end
end

-- Sync calls this for every HELLO on GUILD (zd = the sender's hash; nil from older clients).
function Prized:OnHelloDigest(sender, zd)
    if type(zd) ~= "string" or #zd > 8 or type(sender) ~= "string" then return end
    local mine = self:GetDigestHash()
    if mine == "0" or zd == mine then return end
    if not RateLimit("PZDh:" .. sender, ROUND_WINDOW) then return end
    local delay = self:CanEdit() and DELAY_WRITER or DELAY_MEMBER
    local Comm = ns.Comm
    local queued = Comm and Comm.Backlog and Comm:Backlog("data") or 0
    local busy = queued > 0 and min(12, 6 + queued / 240) or 0
    busy = max(busy, ROUND_WINDOW - (GetTime() - answeredAt))
    Util.RandomDelay(delay[1] + busy, delay[2] + busy, function()
        local h = Prized:GetDigestHash()
        local seen = roundSeen[sender]
        if h == "0" or (seen and GetTime() - seen.at < ROUND_WINDOW) then return end
        roundSeen[sender] = { at = GetTime() }
        Send({ t = "PZK", to = sender }, "GUILD", nil, "live")
        Send({ t = "PZD", to = sender, h = h, d = Prized:GetDigest() }, "GUILD", nil, "data")
    end)
end

---------------------------------------------------------------------------
-- Retention
---------------------------------------------------------------------------

function Prized:Prune(now)
    local root = Root(false)
    if not root then return end
    now = now or Now()
    local changed = false
    for id, r in pairs(root.I) do
        if r.del and r.rev < now - TOMBSTONE_KEEP then root.I[id] = nil; changed = true end
    end
    for id, g in pairs(root.G) do
        if (g.at or 0) < now - GIVEN_KEEP then root.G[id] = nil; changed = true end
    end
    for id, h in pairs(root.H) do
        if (h.at or 0) < now - HIST_KEEP then root.H[id] = nil; changed = true end
    end
    if changed then Changed() end
end

---------------------------------------------------------------------------
-- Demo mode: the mockup's items, hand-outs and changes (nothing is stored or sent)
---------------------------------------------------------------------------

function Prized:BuildDemo()
    local now = Now()
    local G = Guild()
    local me = Me() or "You-Realm"
    local keys = {}
    for _, k in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        if k ~= me then keys[#keys + 1] = k end
    end
    local function K(i) return keys[i] or me end
    local gm = (G and G.GetGM and G:GetGM()) or K(1)
    if gm == me then gm = K(1) end
    demo = { I = {}, G = {}, H = {} }
    local function item(ids, r)
        local id = tostring(ids[1])
        demo.I[id] = CleanItem({ id = id, ids = ids, r = r, by = gm, rev = now - 8 * WEEK })
    end
    local melee = { "ROGUE", "HUNTER", "SHAMAN:Enhancement", "DRUID:Feral (Cat)" }
    local function trinket(order, mode)
        return { att = { m = "r", p = 75, w = 6 }, rank = { m = "r", i = 3 }, main = { m = "r" },
                 cd = { m = "r", w = 4 }, order = { m = mode or "p", g = order }, vote = { s = "all" } }
    end
    item({ 28830 }, trinket({ melee, { "WARRIOR:Fury", "PALADIN:Retribution" } }))
    item({ 30627 }, trinket({ melee, { "WARRIOR:Fury", "PALADIN:Retribution" } }))
    item({ 32837, 32838 }, { att = { m = "r", p = 80, w = 8 }, main = { m = "r" }, guild = { m = "r" },
                             queue = { m = "r", n = { me, K(3), K(5) } }, pair = { m = "r" }, vote = { s = "3q" } })
    item({ 32483 }, trinket({ { "MAGE", "WARLOCK", "PRIEST:Shadow", "SHAMAN:Elemental", "DRUID:Balance" } }, "r"))
    item({ 32505 }, trinket({ melee }))
    item({ 34334 }, { att = { m = "r", p = 80, w = 8 }, main = { m = "r" }, order = { m = "r", g = { { "HUNTER" } } },
                      queue = { m = "r", n = { K(6), K(8) } }, vote = { s = "3q" } })
    item({ 34427 }, { att = { m = "p", p = 60, w = 4 }, rank = { m = "r", i = 3 }, cd = { m = "r", w = 4 },
                      order = { m = "p", g = { { "WARRIOR:Protection", "PALADIN:Protection", "DRUID:Feral (Bear)" } } },
                      vote = { s = "2t" } })
    local n = 0
    local function given(rid, it, to, ago, extra)
        n = n + 1
        local g = { id = "gdemo" .. n, i = rid, it = it, to = to, by = gm, at = now - ago, rev = now - ago, ag = 4, of = 5 }
        for k, v in pairs(extra or {}) do g[k] = v end
        demo.G[g.id] = CleanGiven(g)
    end
    given("30627", 30627, me, 18 * DAY)
    given("28830", 28830, K(2), 3 * WEEK, { ag = 5 })
    given("28830", 28830, K(3), 5 * WEEK, { ag = 3 })
    given("32505", 32505, K(4), 2 * WEEK)
    given("28830", 28830, K(7), 9 * WEEK, { ov = { "cd" }, why = "Nobody else in the first group was there.", ag = 5 })
    local h = 0
    local function hist(rid, text, ago, by)
        h = h + 1
        demo.H["hdemo" .. h] = CleanHist({ id = "hdemo" .. h, i = rid, by = by or gm, at = now - ago, rev = now - ago,
                                          t = text })
    end
    for id in pairs(demo.I) do hist(id, "Made a prized item", 10 * WEEK) end
    hist("28830", "Attendance from 70% over 6 weeks to 75% over 6 weeks", 2 * DAY)
    hist("28830", "Added spec order (rogues, hunters, Enhancement shamans and Feral (Cat) druids)", 6 * WEEK, K(1))
    hist("32837", "Queue from " .. Util.ShortName(K(3)) .. ", " .. Util.ShortName(K(5)) .. " to " .. Util.ShortName(me) ..
        ", " .. Util.ShortName(K(3)) .. ", " .. Util.ShortName(K(5)), 4 * DAY)
    itemIndex = nil
    return demo
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Prized:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("PZU", OnUpdate)
        Comm:Register("PZD", OnDigest)
        Comm:Register("PZK", OnClaim)
        Comm:Register("PZW", OnWant)
        Comm:Register("PZG", OnGive)
        if Comm.AllowLarge then
            for _, t in ipairs({ "PZU", "PZG", "PZD" }) do Comm:AllowLarge(t, "data") end
        end
    end
    ns:On("DEMO_TOGGLED", function(on)
        if not on then demo = nil end
        attCache = {}
        Changed()
    end)
    for _, e in ipairs({ "CONFIG_UPDATED", "ROSTER_UPDATED", "ACCOUNTS_UPDATED", "RAIDLOG_CHANGED",
                         "ATTENDANCE_MINE", "LIST_UPDATED", "MYLIST_COMMITTED", "GUILD_KEY_READY" }) do
        ns:On(e, function()
            attCache = {}
            Changed()
        end)
    end
end

function Prized:OnLogin()
    local function Daily()
        Prized:Prune()
        Util.After(DAY / 4, Daily)
    end
    -- (not drawn from math.random: see Events:OnLogin)
    local n = Util.Adler32((Util.PlayerKey() or "?") .. "prized-prune" .. tostring(Now()))
    Util.After(30 + (n % 1000) / 50, Daily)
end
