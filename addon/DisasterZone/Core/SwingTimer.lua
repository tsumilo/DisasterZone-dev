if DisasterZoneBoot and DisasterZoneBoot.Run("Core/SwingTimer.lua", ...) then return end -- DisasterZone: seal-twist swing timer.
-- A swing timer for Retribution Paladins that twists Seal of Command into Seal of Blood, with a planner that says
-- what to press next (Crusader Strike and the fillers included) and when. The HUD is UI/SwingTimerHUD.lua.
--
-- Twisting (as the gear sim models it, Sim/Paladin.lua ApplySeal): switching from Seal of Command to another seal
-- keeps Command on for 0.399 s, so Seal of Blood (Seal of the Martyr for the Alliance) landing inside the last 0.399 s before a swing makes that swing
-- hit with both seals.
--
-- Latency: the swing we see arrived half a round trip after the server swung, and a key press reaches the server half
-- a round trip after we press it, so on our own clock the server's window sits one round trip earlier than the bar.
-- The round trip is the world latency (GetNetStats), corrected by what we measure: the time from
-- UNIT_SPELLCAST_SENT to the seal's aura showing up in the combat log (a smoothed average). MARGIN keeps the press
-- target clear of both edges (jitter).
--
-- The planner (Plan): a small search over the next GCDs (Crusader Strike, Seal of Command, Seal of Blood twisted
-- into a swing, Exorcism, Consecration, or holding the GCD until the next swing) up to about two
-- swings ahead, scoring each line by damage. The damage per cast comes from the gear sim run on the gear you wear
-- (Calibrate, out of combat, cached by gear), or estimates from your weapon until it has run. Hammer of Wrath is left
-- out on purpose: its cast time resets the swing, which costs a twisting Ret more than it hits for. Judgement is off the
-- GCD: it is suggested right after a twisted swing, when Seal of Blood is about to be replaced by Command anyway.
--
-- After each fight a report counts every swing: twisted, late (Seal of Blood landed just after the swing), clipped
-- (a GCD was running through the whole window) or plain (no Command up), plus fillers used.
--
-- Settings (ns.DB settings "swing"): see Core/DB.lua defaults.
local addonName, ns = ...

local SwingTimer = ns:NewModule("SwingTimer")

local floor, max, min, huge = math.floor, math.max, math.min, math.huge
local pairs, ipairs, tonumber, type, select = pairs, ipairs, tonumber, type, select
local strformat = string.format

local OVERLAP = 0.399            -- Seal of Command stays on this long after switching away (seals.go)
local MARGIN = 0.05              -- keep the press this far from either edge of the window (jitter)
local GCD = 1.5
local SOC_PPM = 7
local LATE_WINDOW = 0.25         -- Seal of Blood landing this soon after a swing counts as a late twist
local REPORTS_MAX = 10

SwingTimer.OVERLAP, SwingTimer.MARGIN, SwingTimer.GCD = OVERLAP, MARGIN, GCD

-- Spells by a known id (names come from GetSpellInfo, so any client language works)
local IDS = {
    soc = 20375, sob = 31892, cs = 35395, judge = 20271, exo = 879, cons = 26573,
}
SwingTimer.IDS = IDS
-- Icons: the spell's own when the client knows it (Seal of the Martyr gets its own), these otherwise
local ICONS = {
    soc = "Interface\\Icons\\Ability_Warrior_InnerRage", sob = "Interface\\Icons\\Spell_Holy_SealOfBlood",
    cs = "Interface\\Icons\\Spell_Holy_CrusaderStrike", judge = "Interface\\Icons\\Spell_Holy_RighteousFury",
    exo = "Interface\\Icons\\Spell_Holy_Excorcism_02", cons = "Interface\\Icons\\Spell_Holy_InnerFire",
    wait = "Interface\\Icons\\INV_Misc_PocketWatch_01",
}
local COSTS = { soc = 280, sob = 210, cs = 236, exo = 340, cons = 660 }   -- top ranks, fallback only
local CDS = { cs = 6, exo = 15, cons = 8 }

local MARTYR = 348700            -- Seal of the Martyr: the Alliance's Seal of Blood in TBC Classic, same twist
local names = {}                 -- key -> localized spell name
local function NameOf(key)
    if not names[key] and GetSpellInfo then
        local id = IDS[key]
        if key == "sob" and IsSpellKnown and IsSpellKnown(MARTYR) then id = MARTYR end
        names[key] = GetSpellInfo(id)
    end
    return names[key]
end
SwingTimer.NameOf = NameOf
SwingTimer.ICONS = setmetatable({}, { __index = function(_, key)
    local n = IDS[key] and NameOf(key)
    local tex = n and GetSpellTexture and GetSpellTexture(n)
    return tex or ICONS[key]
end })

-- ---------------------------------------------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------------------------------------------
local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting("swing." .. path)
    if v == nil then return default end
    return v
end
SwingTimer.Get = Get

function SwingTimer:IsEnabled() return Get("enabled", true) and true or false end

function SwingTimer:IsRet()
    local _, cls = UnitClass("player")
    if cls ~= "PALADIN" then return false end
    -- Retribution = the most points in the third tree; Seal of Command known counts too (low levels, odd builds)
    if GetNumTalentTabs and GetTalentTabInfo then
        local best, bi = -1, nil
        for i = 1, GetNumTalentTabs() do
            local pts = select(3, GetTalentTabInfo(i))
            if type(pts) ~= "number" then pts = select(5, GetTalentTabInfo(i)) end
            pts = tonumber(pts) or 0
            if pts > best then best, bi = pts, i end
        end
        if best > 0 then return bi == 3 end
    end
    return NameOf("soc") ~= nil and (IsSpellKnown and IsSpellKnown(IDS.soc)) or false
end

-- ---------------------------------------------------------------------------------------------------------------
-- Latency
-- ---------------------------------------------------------------------------------------------------------------
local measured                   -- smoothed SENT -> aura applied delay, seconds
local sentAt = {}                -- [spellName] = GetTime() of UNIT_SPELLCAST_SENT

-- The round trip used to move the press zone earlier, seconds.
function SwingTimer:Latency()
    local manual = tonumber(Get("latencyMs", 0)) or 0
    if manual > 0 then return manual / 1000 end
    local world = 0
    if GetNetStats then
        local _, _, home, w = GetNetStats()
        world = (tonumber(w) or tonumber(home) or 0) / 1000
    end
    if measured and world > 0 then return (measured + world) / 2 end
    return measured or world
end

function SwingTimer:LatencyInfo()
    local world
    if GetNetStats then
        local _, _, home, w = GetNetStats()
        world = tonumber(w) or tonumber(home)
    end
    return world, measured and floor(measured * 1000 + 0.5), self:Latency()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Damage per cast: the gear sim on your gear, or weapon-based estimates
-- ---------------------------------------------------------------------------------------------------------------
local values                     -- { soc = per SoC proc, sob = per SoB hit, cs, exo, cons, judge, src }

local function WeaponAvg()
    if UnitDamage then
        local lo, hi = UnitDamage("player")
        lo, hi = tonumber(lo) or 0, tonumber(hi) or 0
        if hi > 0 then return (lo + hi) / 2 end
    end
    return 600
end

function SwingTimer:EstimatedValues()
    local w = WeaponAvg()
    local sp = (GetSpellBonusDamage and tonumber(GetSpellBonusDamage(2))) or 0
    return {
        soc = w * 0.70 * 1.15 + sp * 0.20, sob = w * 0.35 * 1.15, cs = w * 1.10 * 1.15,
        exo = 662 + sp * 0.43, cons = 512 + sp * 0.95, judge = w * 0.75, src = "estimate",
    }
end

function SwingTimer:Values()
    if values then return values end
    local saved = Get("values")
    if type(saved) == "table" and saved.gear == self:GearKey() then
        values = saved
        return values
    end
    return self:EstimatedValues()
end

-- What the gear you wear looks like (calibration is redone when it changes).
function SwingTimer:GearKey()
    local parts = {}
    for sid = 1, 18 do
        local id = GetInventoryItemID and GetInventoryItemID("player", sid)
        parts[#parts + 1] = tostring(id or 0)
    end
    return table.concat(parts, ":")
end

local SIM_DUR = 180
-- Runs the gear sim (40 short fights) on the gear you wear and keeps damage per cast. Only out of combat, and never
-- over a sim you started yourself.
function SwingTimer:Calibrate(force)
    local Runner = ns.SimRunner
    if not Runner or not Runner.Start or not self:IsRet() then return false end
    if Runner:IsRunning() or InCombatLockdown() then return false end
    local key = self:GearKey()
    local saved = Get("values")
    if not force and type(saved) == "table" and saved.gear == key then values = saved return true end
    local set = Runner:EquippedSet()
    local mob = Get("mobType", "Demon")
    local ok = Runner:Start({ { key = "now", set = set } }, {
        iterations = 40,
        settings = { duration = SIM_DUR, talents = select(1, Runner:Talents()), mobType = mob },
        onDone = function(res)
            local s = res and res.now
            if not s then return end
            local function per(k)
                local a = s.abilities and s.abilities[k]
                if a and (a.casts or 0) > 0 then return a.dps * SIM_DUR / a.casts end
                if a and (a.hits or 0) > 0 then return a.dps * SIM_DUR / a.hits end
            end
            local est = self:EstimatedValues()
            local v = {
                soc = per("soc_proc") or est.soc, sob = per(31893) or est.sob, cs = per(35395) or est.cs,
                exo = per(27138) or est.exo, cons = est.cons,
                judge = per(31898) or est.judge, src = "sim", gear = key, dps = s.dps,
            }
            values = v
            ns.DB:SetSetting("swing.values", v)
            ns:Fire("SWING_VALUES")
        end,
    })
    return ok
end

-- ---------------------------------------------------------------------------------------------------------------
-- Live state: swing clock, seals, cooldowns
-- ---------------------------------------------------------------------------------------------------------------
local state = {
    last = nil,                  -- GetTime() of the last swing we saw
    speed = 3.5,
    seal = nil,                  -- "soc" | "sob" | nil (what is on now)
    socUntil = 0,                -- Command lingering after a switch (our clock)
    sealExpires = 0,
}
SwingTimer.state = state

local function MainSpeed()
    if UnitAttackSpeed then
        local s = UnitAttackSpeed("player")
        if s and s > 0 then return s end
    end
    return state.speed
end

function SwingTimer:NextSwing(now)
    now = now or GetTime()
    local sp = state.speed
    if not state.last then return now + sp, sp end
    local nxt = state.last + sp
    while nxt < now - 0.2 do nxt = nxt + sp end    -- missed events (out of range): keep the rhythm
    return nxt, sp
end

local function ScanSeals()
    local socName, sobName = NameOf("soc"), NameOf("sob")
    local seal, exp = nil, 0
    if UnitBuff then
        for i = 1, 40 do
            local n, _, _, _, _, expires = UnitBuff("player", i)
            if not n then break end
            if n == socName then seal, exp = "soc", tonumber(expires) or 0
            elseif n == sobName and seal ~= "soc" then seal, exp = "sob", tonumber(expires) or 0 end
        end
    end
    state.seal, state.sealExpires = seal, exp
end
SwingTimer.ScanSeals = ScanSeals

local function CdLeft(key, now)
    local n = NameOf(key)
    if not n or not GetSpellCooldown then return 0 end
    local s, d = GetSpellCooldown(n)
    s, d = tonumber(s) or 0, tonumber(d) or 0
    if s == 0 or d <= GCD + 0.01 then return 0 end   -- a GCD is not the spell's own cooldown
    return max(0, s + d - now)
end

local function GcdLeft(now)
    local n = NameOf("soc") or NameOf("sob")
    if not n or not GetSpellCooldown then return 0 end
    local s, d = GetSpellCooldown(n)
    s, d = tonumber(s) or 0, tonumber(d) or 0
    if s == 0 or d > GCD + 0.01 then return 0 end
    return max(0, s + d - now)
end

local function Known(key)
    local n = NameOf(key)
    return n ~= nil and GetSpellInfo(n) ~= nil
end

local function TargetType()
    local t = UnitCreatureType and UnitCreatureType("target")
    return t
end

local UNDEAD_DEMON = { Demon = true, Undead = true, ["Dämon"] = true, ["Untoter"] = true, ["Démon"] = true,
    ["Mort-vivant"] = true, ["Demonio"] = true, ["No-muerto"] = true }

-- The planner's input, from the live client.
function SwingTimer:Snapshot(now)
    now = now or GetTime()
    state.speed = MainSpeed()
    local ns_, sp = self:NextSwing(now)
    local mana, manaMax = UnitPower("player", 0) or 0, UnitPowerMax("player", 0) or 1
    local hp, hpMax = UnitHealth("target") or 0, UnitHealthMax("target") or 0
    local opt = {}
    for _, k in ipairs({ "cs", "exo", "cons" }) do opt[k] = Get("use." .. k, true) and Known(k) end
    if opt.exo and not UNDEAD_DEMON[TargetType() or ""] then opt.exo = false end
    if opt.cons and manaMax > 0 and mana / manaMax * 100 < (tonumber(Get("consMana", 40)) or 40) then opt.cons = false end
    return {
        now = now, nextSwing = ns_, speed = sp, gcdReady = now + GcdLeft(now), lat = self:Latency(),
        seal = state.seal, socUntil = state.socUntil,
        cd = { cs = now + CdLeft("cs", now), exo = now + CdLeft("exo", now), cons = now + CdLeft("cons", now) },
        judgeReady = now + CdLeft("judge", now), use = opt, values = self:Values(),
        mana = mana, manaPct = manaMax > 0 and mana / manaMax or 1,
    }
end

-- ---------------------------------------------------------------------------------------------------------------
-- The planner (pure: Plan(snapshot) -> { steps, score }); steps = { { key, at (press time), apply, twist } }
-- ---------------------------------------------------------------------------------------------------------------
local function SwingValue(soc, sob, v, speed)
    local chance = min(1, SOC_PPM * speed / 60)
    return (soc and v.soc * chance or 0) + (sob and v.sob or 0)
end

-- Scores a line: every swing up to `horizon` with the seals on at that moment, plus spell damage.
local function Score(snap, steps, horizon)
    local v, lat = snap.values, snap.lat
    local total = 0
    local events = {}
    for _, st in ipairs(steps) do
        if st.key == "soc" or st.key == "sob" then events[#events + 1] = st
        elseif st.key ~= "wait" then total = total + (v[st.key] or 0) end
    end
    local seal, socUntil = snap.seal, snap.socUntil or 0
    local ei = 1
    local ts = snap.nextSwing
    while ts <= horizon do
        while events[ei] and events[ei].apply < ts do
            local e = events[ei]
            if seal == "soc" and e.key == "sob" then socUntil = e.apply + OVERLAP end
            seal = e.key
            ei = ei + 1
        end
        local soc = seal == "soc" or ts < socUntil
        total = total + SwingValue(soc, seal == "sob", v, snap.speed)
        ts = ts + snap.speed
    end
    -- ending in Command means the next swing can be twisted: half its worth
    while events[ei] do seal = events[ei].key; ei = ei + 1 end
    if seal == "soc" then total = total + 0.5 * SwingValue(true, true, v, snap.speed) end
    return total
end
SwingTimer.Score = Score

-- First swing whose window a press at or after t can still reach.
local function TwistSwing(snap, t)
    local ts = snap.nextSwing
    while ts - MARGIN - snap.lat < t do ts = ts + snap.speed end
    return ts
end

function SwingTimer.Plan(snap, depth)
    depth = depth or 5
    local horizon = snap.now + 2 * snap.speed + GCD
    local best, bestScore = {}, -huge
    local steps = {}
    local function rec(t, seal, cd, d)
        if d == 0 or t >= horizon then
            local s = Score(snap, steps, horizon)
            if s > bestScore then
                bestScore = s
                best = {}
                for i = 1, #steps do best[i] = steps[i] end
            end
            return
        end
        local function try(key, press, newCd, newSeal, twist)
            steps[#steps + 1] = { key = key, at = press, apply = press + snap.lat, twist = twist }
            rec(press + GCD, newSeal or seal, newCd or cd, d - 1)
            steps[#steps] = nil
        end
        for _, k in ipairs({ "cs", "exo", "cons" }) do
            if snap.use[k] and cd[k] <= t + 0.01 then
                local c = {}
                for a, b in pairs(cd) do c[a] = b end
                c[k] = t + CDS[k]
                try(k, t, c)
            end
        end
        if seal ~= "soc" then try("soc", t, nil, "soc") end
        if seal == "soc" then
            local ts = TwistSwing(snap, t)
            -- aim at the middle of the window, on our clock (one round trip earlier), never past its late edge
            local press = max(t, min(ts - OVERLAP / 2 - snap.lat, ts - MARGIN - snap.lat))
            if ts <= horizon then try("sob", press, nil, "sob", ts) end
        elseif seal == nil then
            try("sob", t, nil, "sob")
        end
        -- hold the GCD until just after the next swing
        local ns_ = snap.nextSwing
        while ns_ <= t do ns_ = ns_ + snap.speed end
        if ns_ < horizon then
            steps[#steps + 1] = { key = "wait", at = t, apply = t }
            rec(ns_ + 0.01, seal, cd, d - 1)
            steps[#steps] = nil
        end
    end
    rec(max(snap.now, snap.gcdReady), snap.seal, snap.cd, depth)
    return { steps = best, score = bestScore }
end

-- Baseline for "+x dps vs twisting every swing": the same search with fillers off.
function SwingTimer.PlanGain(snap, plan)
    local copy = {}
    for k, v in pairs(snap) do copy[k] = v end
    copy.use = { cs = snap.use.cs }
    local base = SwingTimer.Plan(copy, 4)
    local span = 2 * snap.speed + GCD
    return (plan.score - base.score) / span
end

-- Is auto attack running? No swing seen for 1.6 swings = idle: the HUD rests instead of guessing.
function SwingTimer:IsSwinging(now)
    now = now or GetTime()
    if not state.last then return false end
    return now - state.last < state.speed * 1.6
end

-- What the HUD shows. The plan holds still between events: it is redone when something happened (a swing, a cast, a
-- seal change: MarkDirty), when its first press is overdue, or every half second, and then a fresh plan only replaces
-- the one on screen when it is clearly better (2%), so the queue does not flicker between near-equal lines.
local shown, shownAt, dirty = nil, 0, true
function SwingTimer:MarkDirty() dirty = true end

function SwingTimer:Current()
    local now = GetTime()
    if not self:IsSwinging(now) then shown = nil return nil end
    local first = shown and shown.plan.steps[1]
    local overdue = first and first.at < now - 0.25
    if shown and not dirty and not overdue and now - shownAt < 0.5 then return shown end
    local snap = self:Snapshot(now)
    local plan = SwingTimer.Plan(snap)
    if shown and not dirty and not overdue then
        local keep = {}
        for _, st in ipairs(shown.plan.steps) do if st.at >= now - 0.05 then keep[#keep + 1] = st end end
        if #keep > 0 then
            local old = Score(snap, keep, snap.now + 2 * snap.speed + GCD)
            if plan.score < old * 1.02 then plan = { steps = keep, score = old } end
        end
    end
    dirty = false
    shownAt = now
    local judge
    if snap.judgeReady <= now + 0.05 and snap.seal == "sob" then
        local f = plan.steps[1]
        if f and f.key == "soc" then judge = true end
    end
    shown = { snap = snap, plan = plan, judge = judge }
    return shown
end

-- ---------------------------------------------------------------------------------------------------------------
-- Combat log: swings, seal changes, measured latency, the fight report
-- ---------------------------------------------------------------------------------------------------------------
local myGUID
local fight                      -- { start, swings = { kind, ... }, fillers = { [key] = n }, target }
local recent = {}                -- last swing results for the HUD: { t, kind }

function SwingTimer:Recent() return recent end

-- A moment after a swing at t (so a late Seal of Blood can still show up): what happened to the twist.
local function Classify(t, socUp, gcdThrough)
    local kind
    local a = state.lastSobAt
    if a and a <= t + 0.02 and t - a <= OVERLAP + 0.1 and socUp then kind = "twist"
    elseif socUp and a and a > t + 0.02 and a - t < LATE_WINDOW then kind = "late"
    elseif socUp and gcdThrough then kind = "clip"
    else kind = "plain" end
    recent[#recent + 1] = { t = t, kind = kind }
    if #recent > 24 then table.remove(recent, 1) end
    if fight then fight.swings[#fight.swings + 1] = kind end
end

local function OnSwing(t)
    state.last = t
    SwingTimer:MarkDirty()
    -- Command on at the swing: still the seal, or lingering after Blood replaced it
    local socUp = state.seal == "soc" or state.socUntil > t
    local gcdThrough = state.gcdStart and state.gcdStart <= t - OVERLAP and state.gcdStart + GCD >= t or false
    if C_Timer and C_Timer.After then
        C_Timer.After(LATE_WINDOW + 0.05, function() Classify(t, socUp, gcdThrough) end)
    else
        Classify(t, socUp, gcdThrough)
    end
end

local function OnCombatLog()
    local _, sub, _, src, _, _, _, _, _, _, _, _, spellName = CombatLogGetCurrentEventInfo()
    if src ~= myGUID then return end
    local now = GetTime()
    if sub == "SWING_DAMAGE" or sub == "SWING_MISSED" then
        OnSwing(now)
    elseif sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REFRESH" then
        if spellName == NameOf("sob") or spellName == NameOf("soc") then
            local s = sentAt[spellName]
            if s and now - s < 1.0 then
                local d = now - s
                measured = measured and (measured * 0.8 + d * 0.2) or d
                sentAt[spellName] = nil
            end
            if spellName == NameOf("sob") then state.lastSobAt = now end
        end
    elseif sub == "SPELL_CAST_SUCCESS" and fight then
        for _, k in ipairs({ "cs", "exo", "cons", "judge" }) do
            if spellName == NameOf(k) then fight.fillers[k] = (fight.fillers[k] or 0) + 1 end
        end
    end
end

local function StartFight()
    fight = { start = GetTime(), swings = {}, fillers = {}, target = UnitName("target") }
end

local function EndFight()
    local f = fight
    fight = nil
    if not f or #f.swings < 4 then return end
    local c = { twist = 0, late = 0, clip = 0, plain = 0 }
    for _, k in ipairs(f.swings) do c[k] = (c[k] or 0) + 1 end
    local v = SwingTimer:Values()
    local speed = state.speed
    local dur = GetTime() - f.start
    local per = SwingValue(true, true, v, speed) - SwingValue(false, true, v, speed)
    local rep = {
        at = time and time() or 0, target = f.target, dur = dur, swings = f.swings, counts = c, fillers = f.fillers,
        lostLate = c.late * per / max(1, dur), lostClip = c.clip * per / max(1, dur),
    }
    local list = Get("reports") or {}
    table.insert(list, 1, rep)
    while #list > REPORTS_MAX do table.remove(list) end
    ns.DB:SetSetting("swing.reports", list)
    ns:Fire("SWING_REPORT", rep)
end

function SwingTimer:Reports() return Get("reports") or {} end

-- ---------------------------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------------------------
function SwingTimer:OnLogin()
    myGUID = UnitGUID("player")
    state.speed = MainSpeed()
    ScanSeals()
    ns:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function()
        if SwingTimer.active then OnCombatLog() end
    end)
    ns:RegisterEvent("UNIT_AURA", function(_, unit)
        if unit ~= "player" or not SwingTimer.active then return end
        local before = state.seal
        ScanSeals()
        if before ~= state.seal then SwingTimer:MarkDirty() end
        -- Blood replaced Command: Command lingers for the overlap (the aura is gone already on our side)
        if before == "soc" and state.seal == "sob" then
            state.socUntil = GetTime() + OVERLAP
        end
    end)
    ns:RegisterEvent("UNIT_SPELLCAST_SENT", function(_, unit, _, _, spellArg)
        if unit ~= "player" or not SwingTimer.active then return end
        local name = type(spellArg) == "number" and GetSpellInfo(spellArg) or spellArg
        if name then sentAt[name] = GetTime() end
    end)
    ns:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit)
        if unit ~= "player" or not SwingTimer.active then return end
        local now = GetTime()
        SwingTimer:MarkDirty()
        if GcdLeft(now) > 0 then state.gcdStart = now - (GCD - GcdLeft(now)) end
    end)
    ns:RegisterEvent("UNIT_ATTACK_SPEED", function(_, unit)
        if unit ~= "player" then return end
        -- haste mid-swing scales what is left of the swing
        local old, new = state.speed, MainSpeed()
        if state.last and old > 0 and new ~= old then
            local now = GetTime()
            local left = state.last + old - now
            if left > 0 then state.last = now + left * new / old - new end
        end
        state.speed = new
    end)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if SwingTimer.active then StartFight() end
    end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if fight then EndFight() end
        if SwingTimer.active and Get("useSim", true) then SwingTimer:Calibrate() end
    end)
    ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function()
        values = nil
        if SwingTimer.active and Get("useSim", true) and not InCombatLockdown() then
            if C_Timer then C_Timer.After(2, function() SwingTimer:Calibrate() end) end
        end
    end)
    ns:RegisterEvent("PLAYER_TALENT_UPDATE", function() SwingTimer:Refresh() end)
    ns:RegisterEvent("SPELLS_CHANGED", function() for k in pairs(names) do names[k] = nil end end)
    ns:RegisterEvent("CHARACTER_POINTS_CHANGED", function() SwingTimer:Refresh() end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:find("^swing") then SwingTimer:Refresh() end
    end)
    self:Refresh()
    if self.active and Get("useSim", true) and C_Timer then
        C_Timer.After(8, function() SwingTimer:Calibrate() end)
    end
end

function SwingTimer:Refresh()
    self.active = self:IsEnabled() and self:IsRet()
    ns:Fire("SWING_STATE", self.active)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Slash: /dz swing [on | off | unlock | lock | report | sim]
-- ---------------------------------------------------------------------------------------------------------------
ns:RegisterSlash("swing", function(rest)
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "on" or rest == "off" then
        ns.DB:SetSetting("swing.enabled", rest == "on")
        ns:Print("Swing timer %s.", rest == "on" and "on" or "off")
    elseif rest == "unlock" or rest == "lock" then
        ns.DB:SetSetting("swing.locked", rest == "lock")
        ns:Print(rest == "lock" and "Swing timer locked." or "Swing timer unlocked: drag it where you want it, then /dz swing lock.")
    elseif rest == "sim" then
        if SwingTimer:Calibrate(true) then ns:Print("Simming your gear for the swing timer (out of combat, a few seconds)...")
        else ns:Print("Can't sim right now (in combat, another sim running, or not Retribution).") end
    elseif rest == "report" then
        local r = SwingTimer:Reports()[1]
        if not r then ns:Print("No fight recorded yet.") return end
        local c = r.counts
        local total = c.twist + c.late + c.clip
        ns:Print("%s (%ds): %d/%d twists landed, %d late, %d clipped by a GCD, %d plain swings. Lost about %.0f dps.",
            r.target or "Last fight", floor(r.dur or 0), c.twist, total, c.late, c.clip, c.plain,
            (r.lostLate or 0) + (r.lostClip or 0))
    else
        local world, meas, used = SwingTimer:LatencyInfo()
        local v = SwingTimer:Values()
        ns:Print("Swing timer is %s%s. Latency: world %s ms, measured %s ms, using %d ms. Damage values: %s.",
            SwingTimer:IsEnabled() and "on" or "off", SwingTimer.active and "" or " (not Retribution)",
            tostring(world or "?"), tostring(meas or "-"), floor((used or 0) * 1000 + 0.5),
            v.src == "sim" and "from the gear sim" or "estimates (run /dz swing sim)")
        ns:Print("/dz swing on | off | unlock | lock | report | sim")
    end
end, "Swing timer for twisting Retribution Paladins (on | off | unlock | lock | report | sim)")
