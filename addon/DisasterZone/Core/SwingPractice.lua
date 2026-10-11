if DisasterZoneBoot and DisasterZoneBoot.Run("Core/SwingPractice.lua", ...) then return end -- DisasterZone: twist practice.
-- Practice for the swing timer (Core/SwingTimer.lua): made-up swings on the real ring, the player presses the keys
-- their seals sit on, nothing is cast. The window and the overlay around the ring are UI/SwingPracticeUI.lua.
--
-- Lessons unlock in order (a star in one opens the next), then free play:
--   1 twist     Seal of Blood in the window, slow swings, Command put back for you
--   2 command   Seal of Command back after each swing, at your weapon's speed
--   3 strike    + Crusader Strike
--   4 judge     + Judgement (off the global cooldown)
--   5 haste     the full rotation, Bloodlust (Heroism) in the middle
--   6 free      the full rotation, no end
--
-- The simulation is the twist as the server sees it: a press reaches the server half a round trip after it is made
-- (the player's own latency), the server swings half a round trip before the ring shows it, Seal of Command stays
-- 0.399 s after Seal of Blood replaces it, the global cooldown and the cooldowns are the client's last known ones and
-- a press in the spell queue window before the global cooldown ends goes off when it ends.
--
-- Scoring: a twist 100 (+25 when it sat inside the safe part of the window), Crusader Strike 50, Judgement 30. A
-- ghost player makes every press the planner (SwingTimer.Run) asks for, on the same swings: its score is 100 %.
-- Stars: 60 / 80 / 95 % of the ghost.
--
-- Keys: read from the action bars (Blizzard's, Bartender4, Dominos; macros too) and the bindings, or set by hand in
-- the window (swing.practice.keys, per character). While practice runs a keyboard frame catches those keys (and Esc)
-- and lets every other key through, so the real buttons never fire. Out of combat only: entering combat ends it.
local addonName, ns = ...

local SP = ns:NewModule("SwingPractice")

local floor, max, min, abs, huge = math.floor, math.max, math.min, math.abs, math.huge
local pairs, ipairs, type, tonumber = pairs, ipairs, type, tonumber
local strformat = string.format

local COUNTDOWN = 3
local LATE = 0.25                -- Seal of Blood up to this long after a swing: a late twist
local SAFE = 0.05                -- the safe part of the window: this far inside both edges
local POINTS = { twist = 100, perfect = 25, cs = 50, judge = 30 }
local STARS = { 0.6, 0.8, 0.95 }
local SPELLS = { "soc", "sob", "cs", "judge" }
local SPELL_IDS = { soc = 20375, sob = 31892, cs = 35395, judge = 20271 }
SP.SPELLS, SP.STARS, SP.COUNTDOWN = SPELLS, STARS, COUNTDOWN

local ALL = { soc = true, sob = true, cs = true, judge = true }
local LESSONS = {
    { key = "twist", title = "The twist", spell = "sob", swings = 8, speed = "slow", autoSoc = true,
      keys = { sob = true },
      goal = "Press Seal of Blood while the ring is in the orange.",
      intro = "Slow swings. Seal of Command goes back on for you after every swing." },
    { key = "command", title = "Command back on", spell = "soc", swings = 10, keys = { soc = true, sob = true },
      goal = "After each swing put Seal of Command back on, then twist.",
      intro = "Your weapon's speed now. Command first, Blood in the orange." },
    { key = "strike", title = "Crusader Strike", spell = "cs", swings = 10, keys = { soc = true, sob = true, cs = true },
      goal = "Fit Crusader Strike between the twists.",
      intro = "Strike when it is ready, but never let it cover the orange." },
    { key = "judge", title = "Judgement", spell = "judge", swings = 12, keys = ALL,
      goal = "Judge right after a swing. It is off the global cooldown.",
      intro = "The full rotation: twist, Strike, Judge, Command back on." },
    { key = "haste", title = "Bloodlust", spell = "lust", swings = 12, keys = ALL, haste = { from = 4, to = 9, mult = 1.3 },
      goal = "Keep twisting when the swings speed up.",
      intro = "Bloodlust comes after a few swings: the orange comes 30 % sooner." },
    { key = "free", title = "Free play", spell = "free", keys = ALL,
      goal = "The full rotation, as long as you like.",
      intro = "No end. Esc stops and shows how you did." },
}
SP.LESSONS = LESSONS
local BY_KEY = {}
for i, L in ipairs(LESSONS) do L.n = i; BY_KEY[L.key] = L end

local ST                         -- ns.SwingTimer
local run                        -- the practice running, nil when none
SP.run = nil

local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting("swing.practice." .. path)
    if v == nil then return default end
    return v
end

local function CharKey()
    return (UnitName and UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
end

-- ---------------------------------------------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------------------------------------------
local MODS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, LMETA = true,
    RMETA = true, SHIFT = true, CTRL = true, ALT = true }

-- "SHIFT-ALT-2" and "ALT-SHIFT-2" are the same key: the game's order (ALT-CTRL-SHIFT-key).
local function Normalize(k)
    if type(k) ~= "string" or k == "" then return nil end
    local alt, ctrl, shift = false, false, false
    local rest = k:upper()
    while true do
        local m, tail = rest:match("^(%u+)%-(.+)$")
        if m == "ALT" then alt = true
        elseif m == "CTRL" then ctrl = true
        elseif m == "SHIFT" then shift = true
        else break end
        rest = tail
    end
    return (alt and "ALT-" or "") .. (ctrl and "CTRL-" or "") .. (shift and "SHIFT-" or "") .. rest
end
SP.Normalize = Normalize

-- The key as the keyboard frame got it, with the modifiers held.
local function Pressed(key)
    if not key or MODS[key] then return nil end
    return (IsAltKeyDown and IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown and IsControlKeyDown() and "CTRL-" or "")
        .. (IsShiftKeyDown and IsShiftKeyDown() and "SHIFT-" or "") .. key
end

-- A key for a key cap: "s2" for Shift-2, "cQ", "aE", "N1" for numpad 1.
function SP:Short(k)
    k = Normalize(k)
    if not k then return "" end
    local s = k:gsub("ALT%-", "a"):gsub("CTRL%-", "c"):gsub("SHIFT%-", "s"):gsub("NUMPAD", "N")
        :gsub("MOUSEWHEELUP", "WU"):gsub("MOUSEWHEELDOWN", "WD"):gsub("BUTTON", "M")
        :gsub("SPACE", "Spc"):gsub("BACKSPACE", "Bks"):gsub("CAPSLOCK", "Caps")
    return s
end

local function SpellKeyOf(name)
    if not name then return nil end
    for _, k in ipairs(SPELLS) do
        if ST.NameOf(k) == name then return k end
    end
    -- Seal of Blood's Alliance twin, by its own name too
    if GetSpellInfo and name == GetSpellInfo(348700) then return "sob" end
    return nil
end

-- The spell on an action slot, by key ("soc" ...), or nil.
local function SlotSpell(slot)
    if not GetActionInfo then return nil end
    local kind, id = GetActionInfo(slot)
    if kind == "spell" and id then return SpellKeyOf(GetSpellInfo(id)) end
    if kind == "macro" and id and GetMacroSpell then
        local r = GetMacroSpell(id)
        if type(r) == "number" then r = GetSpellInfo(r) end
        return SpellKeyOf(r)
    end
    return nil
end

local BAR_CMD = {
    { "^ACTIONBUTTON(%d+)$", "page" }, { "^MULTIACTIONBAR1BUTTON(%d+)$", 60 }, { "^MULTIACTIONBAR2BUTTON(%d+)$", 48 },
    { "^MULTIACTIONBAR3BUTTON(%d+)$", 24 }, { "^MULTIACTIONBAR4BUTTON(%d+)$", 36 },
    { "^CLICK BT4Button(%d+):", 0 }, { "^CLICK DominosActionButton(%d+):", 0 }, { "^CLICK ElvUI_Bar1Button(%d+):", 0 },
}

-- What the bindings put on each spell: { soc = "2", ... } (the first key of the first binding found).
function SP:DetectKeys()
    local found = {}
    if not (GetNumBindings and GetBinding) then return found end
    local page = GetActionBarPage and GetActionBarPage() or 1
    for i = 1, GetNumBindings() do
        local cmd, _, k1, k2 = GetBinding(i)
        local key = k1 or k2
        if type(cmd) == "string" and key then
            local spell
            for _, b in ipairs(BAR_CMD) do
                local n = tonumber(cmd:match(b[1]))
                if n then
                    spell = SlotSpell(b[2] == "page" and ((page - 1) * 12 + n) or (b[2] + n))
                    break
                end
            end
            if not spell then
                local sname = cmd:match("^SPELL (.+)$")
                if sname then spell = SpellKeyOf(sname) end
                local mname = cmd:match("^MACRO (.+)$")
                if mname and GetMacroIndexByName and GetMacroSpell then
                    local r = GetMacroSpell(GetMacroIndexByName(mname))
                    if type(r) == "number" then r = GetSpellInfo(r) end
                    spell = SpellKeyOf(r)
                end
            end
            if spell and not found[spell] then found[spell] = Normalize(key) end
        end
    end
    return found
end

-- The keys practice listens to: what the player set here, else what the bars say. { spell = key, ... }
function SP:Keys()
    local set = Get("keys") or {}
    set = type(set[CharKey()]) == "table" and set[CharKey()] or {}
    local auto = self:DetectKeys()
    local out, used = {}, {}
    for _, s in ipairs(SPELLS) do
        local k = set[s]
        if k == false then k = nil elseif k == nil then k = auto[s] end
        k = Normalize(k)
        if k and not used[k] then out[s], used[k] = k, true end
    end
    return out, auto
end

-- Set (key) or clear (false) the key for a spell; nil = back to what the bars say. One key, one spell.
function SP:SetKey(spell, key)
    local all = Get("keys") or {}
    local mine = type(all[CharKey()]) == "table" and all[CharKey()] or {}
    local copy = {}
    for k, v in pairs(mine) do copy[k] = v end
    key = key and Normalize(key) or key
    if key then
        local current = self:Keys()
        for s, k in pairs(current) do if k == key and s ~= spell then copy[s] = false end end
    end
    copy[spell] = key
    local outAll = {}
    for k, v in pairs(all) do outAll[k] = v end
    outAll[CharKey()] = copy
    ns.DB:SetSetting("swing.practice.keys", outAll)
    if run then run.keyOf = self:Keys() end
    ns:Fire("SWING_PRACTICE_KEYS")
end

-- ---------------------------------------------------------------------------------------------------------------
-- Bests and unlocking
-- ---------------------------------------------------------------------------------------------------------------
function SP:Best(key)
    local b = Get("best") or {}
    b = type(b[CharKey()]) == "table" and b[CharKey()] or {}
    return b[key]
end

function SP:IsUnlocked(L)
    L = type(L) == "table" and L or BY_KEY[L]
    if not L then return false end
    if L.n == 1 or L.key == "free" then return true end
    local prev = self:Best(LESSONS[L.n - 1].key)
    return prev ~= nil and (prev.stars or 0) >= 1
end

-- The lesson to suggest: the first one without three stars that is open, else free play.
function SP:NextLesson()
    for _, L in ipairs(LESSONS) do
        if L.key ~= "free" and self:IsUnlocked(L) then
            local b = self:Best(L.key)
            if not b or (b.stars or 0) < 3 then return L end
        end
    end
    return BY_KEY.free
end

local function SaveBest(res)
    local all = Get("best") or {}
    local outAll = {}
    for k, v in pairs(all) do outAll[k] = v end
    local mine = {}
    for k, v in pairs(type(all[CharKey()]) == "table" and all[CharKey()] or {}) do mine[k] = v end
    local b = mine[res.lesson]
    local better = not b or (res.stars or 0) > (b.stars or 0)
        or ((res.stars or 0) == (b.stars or 0) and (res.grade or 0) > (b.grade or 0))
    res.newBest = better
    if better then
        mine[res.lesson] = { stars = res.stars, grade = res.grade, score = res.score, at = time and time() or 0 }
        outAll[CharKey()] = mine
        ns.DB:SetSetting("swing.practice.best", outAll)
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The simulation: one state per player (the player, the ghost)
-- ---------------------------------------------------------------------------------------------------------------
local function NewState(ghost)
    return {
        ghost = ghost,
        sSeal = "soc", sSocUntil = 0,      -- the server's view
        cSeal = "soc", cSealAt = 0,        -- what the client shows (half a round trip after the server)
        gcdEnd = 0, cd = { cs = 0, judge = 0 },
        queued = nil,                      -- { key, at = when the GCD ends }
        arrivals = {},                     -- { at (server), key }
        shows = {},                        -- { at (client), seal }
        gcdHist = {},                      -- { from, to, key } (local)
        replacedAt = nil,                  -- when Blood last replaced Command (server)
        pending = {},                      -- swings waiting for a late Blood: { S, V, prevS, twisted, socAtS, expected }
        score = 0, streak = 0, bestStreak = 0,
        counts = { twist = 0, perfect = 0, early = 0, late = 0, miss = 0, clip = 0, nocmd = 0, cs = 0, judge = 0 },
        expected = 0, graded = 0,
        offsets = {},                      -- Blood vs the swing (server): { d = seconds, kind }, for the ruler
        autoAt = nil,                      -- lesson 1: Command goes back on at this time (server)
    }
end

local function Lesson() return run and run.L end

local function Pop(kind, text, sub, extra)
    if not run then return end
    local p = { at = GetTime(), kind = kind, text = text, sub = sub }
    if extra then for k, v in pairs(extra) do p[k] = v end end
    run.pops[#run.pops + 1] = p
    run.popSeq = run.popSeq + 1
    p.seq = run.popSeq
    if #run.pops > 30 then table.remove(run.pops, 1) end
end

-- The planner's input for a state, as its client sees it.
local function Snap(s, now)
    local L = run.L
    local nxt = run.visQ[1] and run.visQ[1].V or run.vNext
    local ready = {
        cs = max(now, s.cd.cs), judge = L.keys.judge and max(now, s.cd.judge) or huge, exo = huge, cons = huge,
    }
    return {
        now = now, nextSwing = nxt, lastSwing = run.vLast, speed = run.visSpeed, lat = run.lat,
        gcdReady = max(now, s.gcdEnd), seal = s.cSeal,
        use = { cs = L.keys.cs and true or false, exo = false, cons = false },
        ready = ready, gcd = run.gcd, cd = run.cds,
    }
end

-- The planner's steps for a state now.
local function Plan(s, now) return ST.Run(Snap(s, now)) end

-- Does the planner, at a swing, mean to twist the next one?
local function ExpectsTwist(s, now, nextV)
    if run.L.autoSoc then return true end
    for _, st in ipairs(Plan(s, now)) do
        if st.twist and abs(st.twist - nextV) < 0.02 then return true end
        if st.at > nextV then break end
    end
    return false
end

local function Server(s, key, at)
    s.arrivals[#s.arrivals + 1] = { at = at, key = key }
    table.sort(s.arrivals, function(a, b) return a.at < b.at end)
end

local function ShowSeal(s, seal, at)
    s.shows[#s.shows + 1] = { at = at, seal = seal }
end

-- A press goes off on the client at t (the GCD and cooldowns start now, the server hears it half a trip later).
local function Cast(s, key, t)
    if key == "judge" then
        s.cd.judge = t + (run.cds.judge or 10)
    else
        s.gcdEnd = t + run.gcd
        s.gcdHist[#s.gcdHist + 1] = { from = t, to = t + run.gcd, key = key }
        if #s.gcdHist > 12 then table.remove(s.gcdHist, 1) end
        if key == "cs" then s.cd.cs = t + (run.cds.cs or 6) end
    end
    Server(s, key, t + run.h)
    if not s.ghost then
        run.lastCast = { key = key, at = t }
        ns:Fire("SWING_PRACTICE_CAST", key)
    end
end

-- Why a press can't go off now (nil: it can), and whether it can wait in the spell queue.
local function Blocked(s, key, t)
    if key == "judge" then
        if t < s.cd.judge then return strformat("%.1f s", s.cd.judge - t) end
        if not s.cSeal then return "No seal" end
        return nil
    end
    if key == "cs" and t < s.cd.cs then
        local left = s.cd.cs - t
        if left <= run.queue and s.cd.cs >= s.gcdEnd then return nil, "queue", s.cd.cs end
        return strformat("%.1f s", left)
    end
    if t < s.gcdEnd then
        if s.gcdEnd - t <= run.queue then return nil, "queue", s.gcdEnd end
        return "GCD"
    end
    return nil
end

local function Press(s, key, t)
    local why, queue, at = Blocked(s, key, t)
    if why then
        if not s.ghost then Pop("deny", why, nil, { spell = key }) end
        return false
    end
    if queue then
        s.queued = { key = key, at = at }
        if not s.ghost then Pop("queued", "Queued", nil, { spell = key }) end
        return true
    end
    Cast(s, key, t)
    return true
end

-- The server hears a press.
local function Arrive(s, a)
    local key, at = a.key, a.at
    if key == "soc" then
        s.sSeal, s.sSocUntil = "soc", 0
        ShowSeal(s, "soc", at + run.h)
    elseif key == "sob" then
        if s.sSeal == "soc" then
            s.sSocUntil = at + ST.OVERLAP
            s.replacedAt = at
        end
        s.sSeal = "sob"
        ShowSeal(s, "sob", at + run.h)
    elseif key == "judge" then
        if s.sSeal then
            s.score = s.score + POINTS.judge
            s.counts.judge = s.counts.judge + 1
        end
        s.sSeal, s.sSocUntil = nil, 0
        ShowSeal(s, nil, at + run.h)
    elseif key == "cs" then
        s.score = s.score + POINTS.cs
        s.counts.cs = s.counts.cs + 1
    end
end

local function Ms(sec) return strformat("%d ms", floor(abs(sec) * 1000 + 0.5)) end

local SPELL_LABEL = { soc = "Seal of Command", sob = "Seal of Blood", cs = "Crusader Strike", judge = "Judgement" }

-- A swing is over (a late Blood had its chance): what happened to the twist.
local function Classify(s, p)
    local kind, sub
    local rAt = s.replacedAt
    if p.twisted then
        local d = (p.rAt or 0) - p.S
        local perfect = d >= -ST.OVERLAP + SAFE and d <= -SAFE
        kind = perfect and "perfect" or "twist"
        s.offsets[#s.offsets + 1] = { d = d, kind = perfect and "perfect" or "twist" }
        s.score = s.score + POINTS.twist + (perfect and POINTS.perfect or 0)
        s.counts.twist = s.counts.twist + 1
        if perfect then s.counts.perfect = s.counts.perfect + 1 end
        if not perfect then sub = d > -SAFE and "just before the swing" or "at the very start" end
    elseif p.early then
        kind = "early"
        s.offsets[#s.offsets + 1] = { d = p.early - p.S, kind = "early" }
        sub = Ms((p.S - ST.OVERLAP) - p.early) .. " early"
        s.counts.early = s.counts.early + 1
    elseif p.socAtS and rAt and rAt > p.S and rAt <= p.S + LATE then
        kind = "late"
        s.offsets[#s.offsets + 1] = { d = rAt - p.S, kind = "late" }
        sub = Ms(rAt - p.S) .. " late"
        s.counts.late = s.counts.late + 1
    elseif p.expected and p.socAtS then
        -- no Blood at all: was a global cooldown in the way the whole time?
        local z0, z1 = p.V - run.lat - ST.OVERLAP + SAFE, p.V - run.lat - SAFE
        local by
        for _, g in ipairs(s.gcdHist) do
            if g.from <= z0 + 0.01 and g.to >= z1 - 0.01 then by = g.key end
        end
        if by and by ~= "sob" then
            kind = "clip"
            sub = (SPELL_LABEL[by] or "A spell") .. "'s global cooldown"
            s.counts.clip = s.counts.clip + 1
        else
            kind = "miss"
            s.counts.miss = s.counts.miss + 1
        end
    elseif p.expected then
        kind = "nocmd"
        sub = "Seal of Command was not on"
        s.counts.nocmd = s.counts.nocmd + 1
    end
    if p.expected then s.expected = s.expected + 1 end
    if p.expected or kind == "twist" or kind == "perfect" then s.graded = s.graded + 1 end
    if kind == "twist" or kind == "perfect" then
        s.streak = s.streak + 1
        if s.streak > s.bestStreak then s.bestStreak = s.streak end
    elseif kind then
        s.streak = 0
    end
    if not s.ghost and kind then
        local TEXT = { perfect = "Perfect", twist = "Twist", early = "Early", late = "Late", miss = "Missed",
            clip = "Blocked", nocmd = "No Command" }
        Pop(kind, TEXT[kind], sub, { streak = s.streak, swing = p.n })
        run.results[#run.results + 1] = { n = p.n, kind = kind }
        ns:Fire("SWING_PRACTICE_SWING", kind)
    end
end

-- The server swings.
local function ServerSwing(s, S, V, n)
    local twisted = s.sSeal == "sob" and s.sSocUntil >= S
    local socAtS = s.sSeal == "soc"
    local early
    -- (Blood after the last swing's late window: a late twist of that swing is not an early one of this)
    if s.sSeal == "sob" and not twisted and s.replacedAt and s.replacedAt > (s.prevS or -huge) + LATE then
        early = s.replacedAt
    end
    s.pending[#s.pending + 1] = { S = S, V = V, n = n, prevS = s.prevS, twisted = twisted, rAt = s.replacedAt,
        socAtS = socAtS, early = early, expected = s.expectNext }
    s.prevS = S
    if run.L.autoSoc and s.sSeal ~= "soc" then s.autoAt = S + 0.1 end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------------------------------------------
local function SpeedFor(n)
    local L = run.L
    local h = L.haste
    if h and n >= h.from and n < h.to then return run.base / h.mult end
    return run.base
end

local function NextEvent(s)
    local t, what = huge, nil
    if s.arrivals[1] and s.arrivals[1].at < t then t, what = s.arrivals[1].at, "arrive" end
    if s.queued and s.queued.at < t then t, what = s.queued.at, "queued" end
    if s.autoAt and s.autoAt < t then t, what = s.autoAt, "auto" end
    return t, what
end

local function Step(s, what)
    if what == "arrive" then
        Arrive(s, table.remove(s.arrivals, 1))
    elseif what == "queued" then
        local q = s.queued
        s.queued = nil
        local why = Blocked(s, q.key, q.at)
        if not why then Cast(s, q.key, q.at) end
    elseif what == "auto" then
        local at = s.autoAt
        s.autoAt = nil
        Arrive(s, { key = "soc", at = at })
    end
end

local function GhostThink(g, now)
    if now < run.go then return end
    local steps = Plan(g, now)
    local first = steps[1]
    if first and first.key ~= "wait" and first.at <= now + 0.001 then
        if not (first.key ~= "judge" and now < g.gcdEnd) then Press(g, first.key, now) end
    end
end

-- Moves the simulation to now: presses reach the server, the server swings, the client sees it.
local function Advance(now)
    local r = run
    if not r then return end
    local states = { r.me, r.ghost }
    for _ = 1, 400 do
        -- the earliest thing to happen: a state's own event or the next server swing
        local tS = r.vNext - r.h
        local best, bs, bw = tS, nil, "swing"
        for _, s in ipairs(states) do
            local t, w = NextEvent(s)
            if t < best then best, bs, bw = t, s, w end
        end
        if best > now then break end
        if bw == "swing" then
            r.swingN = r.swingN + 1
            local V = r.vNext
            for _, s in ipairs(states) do ServerSwing(s, tS, V, r.swingN) end
            r.visQ[#r.visQ + 1] = { V = V, n = r.swingN, speed = SpeedFor(r.swingN + 1) }
            r.vNext = V + SpeedFor(r.swingN + 1)
        else
            Step(bs, bw)
        end
    end
    -- the client sees its swings
    while r.visQ[1] and r.visQ[1].V <= now do
        local v = table.remove(r.visQ, 1)
        r.vLast = v.V
        r.visSpeed = v.speed
        ST.state.last, ST.state.speed = v.V, v.speed
        ST:MarkDirty()
        local L = r.L
        if L.haste then
            if v.n == L.haste.from - 1 then
                Pop("buff", r.lust.name, "Swings 30 % faster", { icon = r.lust.icon })
            elseif v.n == L.haste.to - 1 then
                Pop("buff", r.lust.name .. " fades", "Back to your speed", { icon = r.lust.icon, fade = true })
            end
        end
        local nextV = r.vNext
        for _, s in ipairs(states) do s.expectNext = ExpectsTwist(s, v.V, nextV) end
    end
    -- what each client shows of its seal
    for _, s in ipairs(states) do
        while s.shows[1] and s.shows[1].at <= now do
            local sh = table.remove(s.shows, 1)
            s.cSeal, s.cSealAt = sh.seal, sh.at
        end
    end
    ST.state.seal = r.me.cSeal
    ST.state.sealExpires = r.me.cSeal and (r.me.cSealAt + 30) or 0
    -- swings whose late window closed
    for _, s in ipairs(states) do
        while s.pending[1] and now >= s.pending[1].S + LATE do
            Classify(s, table.remove(s.pending, 1))
        end
    end
    GhostThink(r.ghost, now)
    -- the end of a lesson
    local L = r.L
    if L.swings and #r.results >= L.swings and not r.me.pending[1] then
        SP:Stop("done")
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The keyboard
-- ---------------------------------------------------------------------------------------------------------------
local catcher
local assignFor, assignDone       -- waiting for a key to give a spell

local function Catcher()
    if catcher then return catcher end
    catcher = CreateFrame("Frame", "DisasterZoneSwingPracticeKeys", UIParent)
    catcher:SetSize(1, 1)
    catcher:SetPoint("TOPLEFT")
    catcher:Hide()
    catcher:SetScript("OnKeyDown", function(self, key)
        if InCombatLockdown and InCombatLockdown() then return end
        local k = Pressed(key)
        if assignFor then
            if not k then self:SetPropagateKeyboardInput(false) return end
            self:SetPropagateKeyboardInput(false)
            local spell, done = assignFor, assignDone
            assignFor, assignDone = nil, nil
            if key ~= "ESCAPE" then SP:SetKey(spell, k) end
            SP:UpdateCatcher()
            if done then done(key ~= "ESCAPE" and k or nil) end
            return
        end
        if not run then self:SetPropagateKeyboardInput(true) return end
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            SP:Stop("esc")
            return
        end
        local nk = k and Normalize(k)
        local spell
        for s, kk in pairs(run.keyOf) do if kk == nk then spell = s end end
        if spell then
            self:SetPropagateKeyboardInput(false)
            SP:Press(spell)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    return catcher
end

function SP:UpdateCatcher()
    local c = Catcher()
    local want = (run ~= nil or assignFor ~= nil) and not (InCombatLockdown and InCombatLockdown())
    c:EnableKeyboard(want)
    c:SetShown(want)
end

-- Waits for the next key and gives it to spell (Esc cancels). done(key or nil) after.
function SP:AssignKey(spell, done)
    if InCombatLockdown and InCombatLockdown() then return false end
    assignFor, assignDone = spell, done
    self:UpdateCatcher()
    return true
end

function SP:CancelAssign()
    if not assignFor then return end
    local done = assignDone
    assignFor, assignDone = nil, nil
    self:UpdateCatcher()
    if done then done(nil) end
end

function SP:Assigning() return assignFor end

-- ---------------------------------------------------------------------------------------------------------------
-- Start, press, stop
-- ---------------------------------------------------------------------------------------------------------------
local driver

local function WeaponSpeed()
    local s = UnitAttackSpeed and UnitAttackSpeed("player")
    s = tonumber(s)
    if s and s >= 3.0 and s <= 4.0 then return s end
    return 3.5
end

local function Lust()
    if UnitFactionGroup and UnitFactionGroup("player") == "Alliance" then
        return { name = "Heroism", icon = "Interface\\Icons\\Ability_Shaman_Heroism" }
    end
    return { name = "Bloodlust", icon = "Interface\\Icons\\Spell_Nature_BloodLust" }
end
SP.Lust = Lust

function SP:CanPractice()
    if not ST or not ST:IsRet() then return false, "Twist practice is for Retribution Paladins (or turn on demo mode)." end
    if InCombatLockdown and InCombatLockdown() then return false, "Not in combat." end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return false, "Not in combat." end
    return true
end

function SP:Start(key)
    local L = BY_KEY[key or ""] or self:NextLesson()
    local ok, why = self:CanPractice()
    if not ok then ns:Print(why) return false end
    if not self:IsUnlocked(L) then return false end
    if run then self:Stop("restart") end
    local now = GetTime()
    local base = L.speed == "slow" and 4.2 or WeaponSpeed()
    local lat = ST:Latency() or 0
    local queue = (tonumber(GetCVar and GetCVar("SpellQueueWindow")) or 400) / 1000
    run = {
        L = L, t0 = now, go = now + COUNTDOWN, base = base, visSpeed = base, lat = lat, h = lat / 2, queue = queue,
        gcd = ST.state.gcd or ST.GCD, cds = { cs = ST.state.cd.cs or 6, judge = ST.state.cd.judge or 10 },
        swingN = 0, visQ = {}, pops = {}, popSeq = 0, results = {}, lust = Lust(),
        keyOf = (self:Keys()),
    }
    run.vNext = run.go + base
    run.vLast = run.go
    run.me, run.ghost = NewState(false), NewState(true)
    run.me.expectNext, run.ghost.expectNext = true, true
    run.me.prevS, run.ghost.prevS = run.go - run.h, run.go - run.h
    SP.run = run
    -- the ring: empty until Go, Seal of Command on (after Refresh: it stops the demo's swings, which clears them)
    ST.practice = SP
    ST:Refresh()
    ST.state.last, ST.state.speed = run.go, base
    ST.state.seal, ST.state.sealExpires = "soc", now + 30
    ST:MarkDirty()
    if not driver then
        driver = CreateFrame("Frame")
        driver:SetScript("OnUpdate", function() if run then Advance(GetTime()) end end)
    end
    driver:Show()
    self:UpdateCatcher()
    ns:Fire("SWING_PRACTICE", "start", L.key)
    return true
end

function SP:Press(spell)
    if not run then return false end
    local now = GetTime()
    if not run.L.keys[spell] then
        Pop("deny", "Not yet", "comes in a later lesson", { spell = spell })
        return false
    end
    Advance(now)
    if not run then return false end
    return Press(run.me, spell, now)
end

-- The swing timer's planner input while practice runs (SwingTimer:Snapshot hands over to this).
function SP:Snapshot(now) return Snap(run.me, now or GetTime()) end

function SP:IsRunning() return run ~= nil end
function SP:Lesson() return Lesson() end

-- The player's numbers so far (also the result at the end).
function SP:Tally(r)
    r = r or run
    if not r then return nil end
    local me, gh = r.me, r.ghost
    local grade = gh.score > 0 and min(1, me.score / gh.score) or (me.score > 0 and 1 or 0)
    local stars = 0
    for i, s in ipairs(STARS) do if grade >= s - 1e-9 then stars = i end end
    -- where Blood lands, on average: the window's middle is 0.2 s before the swing
    local sum, n = 0, 0
    for _, o in ipairs(me.offsets) do sum, n = sum + o.d, n + 1 end
    local lean = n > 0 and (sum / n + ST.OVERLAP / 2) or nil
    return {
        lesson = r.L.key, n = r.L.n, title = r.L.title, score = me.score, ideal = gh.score, grade = grade,
        stars = stars, counts = me.counts, expected = me.expected, twists = me.counts.twist,
        swings = #r.results, bestStreak = me.bestStreak, offsets = me.offsets, lean = lean,
        ghostCs = gh.counts.cs, ghostJudge = gh.counts.judge, free = r.L.key == "free",
    }
end

-- One thing to work on, from what went wrong most.
function SP:Tip(res)
    if not res then return "" end
    local c = res.counts
    local worst, wn = nil, 0
    for _, k in ipairs({ "early", "late", "miss", "clip", "nocmd" }) do
        if (c[k] or 0) > wn then worst, wn = k, c[k] end
    end
    if worst == "early" then return "You pressed Seal of Blood too soon. Wait for the gold to reach the orange." end
    if worst == "late" then return "You pressed Seal of Blood after the swing. Press as the orange starts." end
    if worst == "miss" then return "Some twists were missed. When the ring turns orange, press Seal of Blood." end
    if worst == "clip" then return "A global cooldown covered the orange. Use Crusader Strike right after a swing." end
    if worst == "nocmd" then return "Seal of Command was not on in time. Put it back on right after the swing." end
    if res.ideal > 0 and res.grade < 0.95 then
        if (res.ghostCs or 0) > (c.cs or 0) then return "Use Crusader Strike every time it is ready." end
        if (res.ghostJudge or 0) > (c.judge or 0) then return "Judge right after a swing, with Seal of Blood on." end
    end
    if res.lean and res.lean < -0.12 then return "Every twist landed, but early in the window: a little later is safer." end
    if res.lean and res.lean > 0.12 then return "Every twist landed, but close to the swing: a little sooner is safer." end
    return "Clean. Try the next lesson."
end

function SP:Stop(reason)
    if not run then return end
    local r = run
    local res = self:Tally(r)
    run, SP.run = nil, nil
    if driver then driver:Hide() end
    ST.practice = nil
    ST.state.last = nil
    ST.state.speed = UnitAttackSpeed and tonumber((UnitAttackSpeed("player"))) or ST.state.speed
    ST.ScanSeals()
    ST:Refresh()
    ST:MarkDirty()
    self:UpdateCatcher()
    -- a lesson counts when it ran to its end; free play whenever a few swings were graded
    local counted = reason == "done" or (r.L.key == "free" and reason == "esc" and res.swings >= 3)
    if counted then
        res.done = true
        SaveBest(res)
    end
    if reason == "combat" then ns:Print("Twist practice stopped: you entered combat.") end
    self.last = counted and res or nil
    ns:Fire("SWING_PRACTICE", "stop", reason, counted and res or nil)
end

function SP:OnLogin()
    ST = ns.SwingTimer
    if not ST then return end
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if run then SP:Stop("combat") end
        if assignFor then SP:CancelAssign() end
    end)
    ns:On("CLASSKIT_CHANGED", function() if run and not ST:IsRet() then SP:Stop("spec") end end)
end

-- Test hooks: the state objects and the clock step.
function SP:_Advance(now) Advance(now or GetTime()) end
function SP:_Me() return run and run.me end
function SP:_Ghost() return run and run.ghost end
