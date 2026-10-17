if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_HoldTheLine/Social.lua", ...) then return end -- DisasterZone_HoldTheLine/Social.lua
-- ns.HTLSocial: Hold the Line's guild side. Achievements (D.ACHIEVEMENTS: earned for good, the guild hears who was
-- first), the guild's boards (each member's best per class, this week and all time, and the week's challenge) and
-- the Argent Dawn's standings (what each one brings to a run).
--
-- Saved (Games:GetData("holdtheline"), account wide), beside Game.lua's: ach[id] = time earned; firsts[id] =
-- { who, t } (the guild's first); weeks[week][key] = entry; all[key] = entry (all time); clsBest[cls] = longest run;
-- stones, chWins, goldTotal (lifetime); chPaid[week] (a challenge week settled); look = { tabard, aura } (worn).
-- entry = { b = { [cls] = { t, k, l, lg, w } }, g = gold home, r = rep, p = points, ti = title, ch = { t, k, c },
--   kt = the fastest Kel'Thuzad (the run's clock at his fall), d = Desecrated pieces owned (all classes) }
--   (b: per class the longest run t and its legendary lg, the most slain k, the highest level l, wins w).
-- Wire (the games' class): HLR { w = week, e, a } my entry for the week and all time (a run ended); HLQ { w, n }
-- "I know n entries of week w" (the boards opened, at most once a minute); HLA { w, l, a } an answer (after a random
-- wait, unless someone answered first); HLF { id, t } a guild first.
local _, ns = ...

local D = ns.HTLData
local S = ns:NewModule("HTLSocial")
ns.HTLSocial = S

local GAME_ID = D.GAME_ID
local CHUNK = 8
local ASK_EVERY = 60
local KEEP_WEEKS = 6
local floor, max, min = math.floor, math.max, math.min
local CLS = { PALADIN = true, MAGE = true, WARRIOR = true }

local function Util() return ns.Util end
local function Me() return Util().PlayerKey() end
local function Now() return Util().Now and Util().Now() or time() end

local function Data()
    local d = ns.HTLGame.Data()
    for _, k in ipairs({ "ach", "firsts", "weeks", "all", "clsBest", "chPaid", "look" }) do if type(d[k]) ~= "table" then d[k] = {} end end
    d.stones, d.chWins, d.goldTotal = d.stones or 0, d.chWins or 0, d.goldTotal or 0
    return d
end
S.Data = Data

---------------------------------------------------------------------------
-- the week (it turns on the realm's weekly reset day: Wednesday in Europe, Tuesday elsewhere)
---------------------------------------------------------------------------
local function RealmNow() return Now() - ((ns.RaidNights and ns.RaidNights.Offset and ns.RaidNights:Offset() or 0) * 60) end
local function ResetDay() return (GetCurrentRegion and GetCurrentRegion() == 3) and 3 or 2 end
function S:Week(t)
    t = t or RealmNow()
    local back = (tonumber(date("%w", t)) - ResetDay()) % 7
    return date("%Y-%m-%d", t - back * 86400)
end
-- seconds left of this week
function S:WeekLeft()
    local t = RealmNow()
    local back = (tonumber(date("%w", t)) - ResetDay()) % 7
    local d = date("*t", t)
    local since = back * 86400 + d.hour * 3600 + d.min * 60 + d.sec
    return max(0, 7 * 86400 - since)
end
local function WeekIndex(week)
    local y, m, d = week:match("^(%d+)%-(%d+)%-(%d+)$")
    if not y then return 0 end
    return floor(time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) / 604800)
end
local function Hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    return h
end
function S:Challenge(week)
    week = week or self:Week()
    local c = D.CHALLENGES[WeekIndex(week) % #D.CHALLENGES + 1]
    return c, Hash("HTL:" .. week) % 1999999999 + 1
end

---------------------------------------------------------------------------
-- the Argent Dawn
---------------------------------------------------------------------------
function S:Standing(rep)
    rep = rep or Data().rep or 0
    local cur, i = D.STANDINGS[1], 1
    for k, s in ipairs(D.STANDINGS) do if rep >= s.at then cur, i = s, k end end
    return cur, i, D.STANDINGS[i + 1]
end
-- what a run starts with, from your standing: { reroll = n, seal = true, tabard = true, aura = true }
function S:RunPerks()
    local d = Data()
    local _, i = self:Standing(d.rep)
    local out = {}
    for k = 2, i do
        for _, r in ipairs(D.STANDINGS[k].rewards or {}) do
            if r.id == "manual" then out.reroll = (out.reroll or 0) + 1 end
            if r.id == "seal" then out.seal = true end
            if r.id == "tabard" and d.look.tabard ~= false then out.tabard = true end
            if r.id == "aura" and d.look.aura ~= false then out.aura = true end
        end
    end
    return out
end
function S:Title()
    local d = Data()
    if d.titleWeek == self:Week() then return D.CHALLENGE_TITLE end
    if (d.rep or 0) >= D.STANDINGS[#D.STANDINGS].at then return "Champion of the Dawn" end
end

---------------------------------------------------------------------------
-- achievements
---------------------------------------------------------------------------
S.toasts = {}         -- earned this session, waiting for the UI to show them

function S:TreesFull()
    local d, n = Data(), 0
    for _, tr in ipairs(D.TALENT_TREES) do
        local full = true
        for _, t in ipairs(D.TALENTS) do if t.tree == tr.id and (d.talents[t.id] or 0) < t.max then full = false end end
        if full then n = n + 1 end
    end
    return n
end
function S:Has(id) return Data().ach[id] ~= nil end
-- Tier 3: sets complete (nine pieces) and pieces owned, over the three classes
function S:T3Sets() local n = 0 for c in pairs(CLS) do if ns.HTLGame:T3Count(c) >= #(D.T3_SLOTS or {}) then n = n + 1 end end return n end
function S:T3Pieces() local n = 0 for c in pairs(CLS) do n = n + ns.HTLGame:T3Count(c) end return n end
function S:Points()
    local d, have, all = Data(), 0, 0
    for _, a in ipairs(D.ACHIEVEMENTS) do
        all = all + a.pts
        if d.ach[a.id] then have = have + a.pts end
    end
    return have, all
end
function S:Count()
    local d, n = Data(), 0
    for _, a in ipairs(D.ACHIEVEMENTS) do if d.ach[a.id] then n = n + 1 end end
    return n, #D.ACHIEVEMENTS
end
-- a listing for the UI: { a, earned = time or nil, have, need, first = { who, t } }
function S:List(cat)
    local d, out = Data(), {}
    for _, a in ipairs(D.ACHIEVEMENTS) do
        if not cat or a.cat == cat then
            local row = { a = a, earned = d.ach[a.id], first = d.firsts[a.id] }
            if a.prof and not row.earned then local _, have, need = a.prof(d, S) row.have, row.need = have, need end
            out[#out + 1] = row
        end
    end
    table.sort(out, function(x, y)
        if (x.earned and 1 or 0) ~= (y.earned and 1 or 0) then return x.earned ~= nil end
        if x.earned and y.earned and x.earned ~= y.earned then return x.earned > y.earned end
        return false
    end)
    return out
end

local function Award(id)
    local d = Data()
    if d.ach[id] or not D.ACH[id] then return false end
    local now = Now()
    d.ach[id] = now
    S.toasts[#S.toasts + 1] = id
    local f = d.firsts[id]
    if not f then
        d.firsts[id] = { who = Me(), t = now }
        ns.Games:Send(GAME_ID, { t = "HLF", id = id, ts = now }, "GUILD")
    end
    ns:Fire("GAMES_UPDATED")
    return true
end
S._Award = Award

-- a real run (not the lab, not god mode): its achievements so far; final = it just ended (won or not)
function S:CheckRun(run, final)
    if not run or run.lab or run.god or run.dev or run.attract or run.preview then return end
    local naxx = run.stage and run.stage ~= "epl"
    for _, a in ipairs(D.ACHIEVEMENTS) do
        -- (the Plaguelands' survival and class wins belong to the Plaguelands; the necropolis's to the necropolis)
        local fits = naxx and (a.cat == "naxx" or a.cat == "slaughter" or a.cat == "legend") or (not naxx and a.cat ~= "naxx")
        if fits and a.run and not Data().ach[a.id] and a.run(run, final) then Award(a.id) end
    end
    if final and run.over == "victory" and not naxx then
        local f = Data().firsts.palefirst
        if not f or Util().IsMe(f.who) then Award("palefirst") end
    end
    if final and run.slain and run.slain.n_kelthuzad then            -- (the guild's first Kel'Thuzad; a Warrior's)
        local f = Data().firsts.nx_bane
        if not f or Util().IsMe(f.who) then Award("nx_bane") end
        if run.cls == "WARRIOR" then local h = Data().firsts.nx_hardest if not h or Util().IsMe(h.who) then Award("nx_hardest") end end
    end
end
function S:CheckProfile()
    local d = Data()
    for _, a in ipairs(D.ACHIEVEMENTS) do
        if a.prof and not d.ach[a.id] and a.prof(d, S) then Award(a.id) end
    end
end

---------------------------------------------------------------------------
-- the boards
---------------------------------------------------------------------------
local function num(v, hi) return max(0, min(hi, floor(tonumber(v) or 0))) end
local function CleanBest(b)
    if type(b) ~= "table" then return nil end
    local out = { t = num(b.t, 1200), k = num(b.k, 999999), l = num(b.l, 9999), w = num(b.w, 99999) }
    if type(b.lg) == "string" and D.LEGEND[b.lg] then out.lg = b.lg end
    return out
end
local function Clean(e)
    if type(e) ~= "table" then return nil end
    local out = { b = {}, g = num(e.g, 99999999), r = num(e.r, 99999999), p = num(e.p, 99999) }
    if type(e.b) == "table" then for c, b in pairs(e.b) do if CLS[c] then out.b[c] = CleanBest(b) end end end
    if type(e.ti) == "string" then out.ti = e.ti:sub(1, 40) end
    if type(e.ch) == "table" and CLS[e.ch.c] then out.ch = { t = num(e.ch.t, 1800), k = num(e.ch.k, 999999), c = e.ch.c } end
    if tonumber(e.kt) then out.kt = num(e.kt, 3600) end
    if tonumber(e.d) then out.d = num(e.d, 27) end
    return out
end
S.Clean = Clean

local function Prune(d)
    local weeks = {}
    for w in pairs(d.weeks) do weeks[#weeks + 1] = w end
    table.sort(weeks)
    for i = 1, #weeks - KEEP_WEEKS do d.weeks[weeks[i]] = nil end
end
-- someone's entry arrives (or mine changes): kept when it says more than what we had
local function Better(old, new)
    if not old then return true end
    if (new.p or 0) ~= (old.p or 0) or (new.r or 0) ~= (old.r or 0) or (new.g or 0) ~= (old.g or 0) then return true end
    for c, b in pairs(new.b) do
        local o = old.b[c]
        if not o or b.t ~= o.t or b.k ~= o.k or b.l ~= o.l or b.w ~= o.w then return true end
    end
    if new.ch and (not old.ch or new.ch.t ~= old.ch.t or new.ch.k ~= old.ch.k) then return true end
    if (new.kt or 0) ~= (old.kt or 0) or (new.d or 0) ~= (old.d or 0) then return true end
    return false
end
local function Store(week, key, e, all)
    if type(key) ~= "string" then return false end
    local d, changed = Data(), false
    e = e and Clean(e)
    if e and type(week) == "string" and week:match("^%d%d%d%d%-%d%d%-%d%d$") then
        d.weeks[week] = d.weeks[week] or {}
        if Better(d.weeks[week][key], e) then d.weeks[week][key] = e changed = true end
        Prune(d)
    end
    all = all and Clean(all)
    if all and Better(d.all[key], all) then d.all[key] = all changed = true end
    if changed then ns:Fire("GAMES_UPDATED") end
    return changed
end
S._Store = Store

-- my entry for the week (and all time) after a run: best per class, gold home, rep, points, title, challenge
local function Fold(e, run, home)
    e = e or { b = {} }
    e.b = e.b or {}
    if run.stage and run.stage ~= "epl" then                   -- (a necropolis run: its own boards, not the Plaguelands')
        if run.stage == "frost" and run.over == "victory" then local t = floor(run.t) if not e.kt or t < e.kt then e.kt = t end end
        e.g = (e.g or 0) + (home or 0)
        return e
    end
    local b = e.b[run.cls] or { t = 0, k = 0, l = 0, w = 0 }
    local t = floor(run.t)
    if t > (b.t or 0) or (t == b.t and run.kills > (b.k or 0)) then
        b.t = t
        b.lg = nil
        for id in pairs(run.legend) do b.lg = id end
    end
    b.k, b.l = max(b.k or 0, run.kills), max(b.l or 0, run.level)
    if run.over == "victory" then b.w = (b.w or 0) + 1 end
    e.b[run.cls] = b
    e.g = (e.g or 0) + (home or 0)
    return e
end
local function Stamp(e)
    local d = Data()
    e.r, e.p, e.ti = d.rep or 0, (S:Points()), S:Title()
    e.d = S:T3Pieces()
    return e
end

function S:RunEnded(run, won, home)
    if not run or run.lab or run.god or run.dev or run.attract or run.preview then return end
    local d, me, week = Data(), Me(), self:Week()
    if (run.stage or "epl") == "epl" then d.clsBest[run.cls] = max(d.clsBest[run.cls] or 0, floor(run.t)) end
    d.goldTotal = d.goldTotal + (home or 0)
    d.stones = d.stones + (run.stones or 0)
    self:CheckRun(run, true)
    self:CheckProfile()
    d.weeks[week] = d.weeks[week] or {}
    local mine = Fold(d.weeks[week][me], run, home)
    if run.challenge == week then
        local ch = mine.ch
        if not ch or floor(run.t) > ch.t or (floor(run.t) == ch.t and run.kills > ch.k) then mine.ch = { t = floor(run.t), k = run.kills, c = run.cls } end
    end
    d.weeks[week][me] = Stamp(mine)
    d.all[me] = Stamp(Fold(d.all[me], run, home))
    ns:Fire("GAMES_UPDATED")
    ns.Games:Send(GAME_ID, { t = "HLR", w = week, e = d.weeks[week][me], a = d.all[me] }, "GUILD")
end

-- A board, best first: kind "time" | "kills" | "level" | "gold" | "rep" | "points" | "challenge"; period "week" |
-- "all"; cls nil (each member's best class) or a class. -> { { key, name, cls, v, e, b, me }, ... }
function S:Board(kind, period, cls, week)
    local d = Data()
    week = week or self:Week()
    local src = period == "all" and d.all or (d.weeks[week] or {})
    local list = {}
    for key, e in pairs(src) do
        local best, bc, bv = nil, nil, -1
        if kind == "gold" then bv = e.g or 0
        elseif kind == "rep" then bv = e.r or 0
        elseif kind == "points" then bv = e.p or 0
        elseif kind == "challenge" then if e.ch then bv, bc = e.ch.t * 1000000 + min(999999, e.ch.k), e.ch.c end
        elseif kind == "kt" then if e.kt then bv = 100000 - e.kt end
        elseif kind == "desecrated" then bv = e.d or 0
        else
            for c, b in pairs(e.b or {}) do
                if not cls or c == cls then
                    local v = kind == "kills" and b.k or kind == "level" and b.l or ((b.t or 0) * 1000000 + min(999999, b.k or 0))
                    if v > bv then bv, best, bc = v, b, c end
                end
            end
        end
        if not bc and kind ~= "challenge" and kind ~= "kt" and kind ~= "desecrated" then
            for c, b in pairs(e.b or {}) do if not best or (b.t or 0) > (best.t or 0) then best, bc = b, c end end
        end
        if bv > 0 and (kind ~= "challenge" or bc) and (not cls or bc == cls or kind == "gold" or kind == "rep" or kind == "points" or kind == "kt" or kind == "desecrated") then
            list[#list + 1] = { key = key, name = Util().ShortName(key) or key, cls = bc, v = bv, e = e, b = best, me = Util().IsMe(key) }
        end
    end
    table.sort(list, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.key < b.key end)
    return list
end

-- a challenge week that has turned: its leader is the champion (once; only you can settle your own reward)
function S:Settle()
    local d, now = Data(), self:Week()
    for week in pairs(d.weeks) do
        if week < now and not d.chPaid[week] then
            d.chPaid[week] = true
            local top = self:Board("challenge", "week", nil, week)[1]
            if top and top.me then
                d.chWins = d.chWins + 1
                d.rep = (d.rep or 0) + D.CHALLENGE_REP
                d.titleWeek = now
                self:CheckProfile()
            end
        end
    end
end

---------------------------------------------------------------------------
-- the wire
---------------------------------------------------------------------------
local lastAsk, answering = 0, {}
local function Count(week) local n = 0 for _ in pairs(Data().weeks[week] or {}) do n = n + 1 end return n end
function S:Ask()
    if InCombatLockdown and InCombatLockdown() then return end
    local now = Now()
    if now - lastAsk < ASK_EVERY then return end
    lastAsk = now
    local week = self:Week()
    ns.Games:Send(GAME_ID, { t = "HLQ", w = week, n = Count(week) }, "GUILD")
end
local function Answer(week)
    answering[week] = nil
    local d, l, a, n = Data(), {}, {}, 0
    for key, e in pairs(d.weeks[week] or {}) do
        l[key], a[key] = e, d.all[key]
        n = n + 1
        if n >= CHUNK then ns.Games:Send(GAME_ID, { t = "HLA", w = week, l = l, a = a }, "GUILD") l, a, n = {}, {}, 0 end
    end
    if n > 0 then ns.Games:Send(GAME_ID, { t = "HLA", w = week, l = l, a = a }, "GUILD") end
end
local handlers = {}
handlers.HLR = function(sender, msg)
    if type(msg) ~= "table" or Util().IsMe(sender) then return end
    Store(msg.w, sender, msg.e, msg.a)
end
handlers.HLQ = function(sender, msg)
    if type(msg) ~= "table" or Util().IsMe(sender) or type(msg.w) ~= "string" then return end
    if Count(msg.w) <= (tonumber(msg.n) or 0) or answering[msg.w] then return end
    answering[msg.w] = true
    local wait = 0.5 + math.random() * 2.5
    if Util().After then Util().After(wait, function() if answering[msg.w] then Answer(msg.w) end end) else Answer(msg.w) end
end
handlers.HLA = function(sender, msg)
    if type(msg) ~= "table" or type(msg.l) ~= "table" or Util().IsMe(sender) then return end
    answering[msg.w] = nil
    local n = 0
    for key, e in pairs(msg.l) do
        n = n + 1
        if n > CHUNK then break end
        Store(msg.w, key, e, type(msg.a) == "table" and msg.a[key] or nil)
    end
end
handlers.HLF = function(sender, msg)
    if type(msg) ~= "table" or Util().IsMe(sender) or not D.ACH[msg.id] then return end
    local d, ts = Data(), tonumber(msg.ts) or Now()
    local f = d.firsts[msg.id]
    if not f or ts < (f.t or 0) then d.firsts[msg.id] = { who = sender, t = ts } ns:Fire("GAMES_UPDATED") end
end
S._handlers = handlers

function S:OnInit()
    if not ns:HasAssets(D.ASSETS) then return end
    for t, fn in pairs(handlers) do ns.Comm:Register(t, fn) end
end
