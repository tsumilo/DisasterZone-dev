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
-- What to press comes from WoWSims' Retribution rotation (the one the gear sim plays, see Run below), not from a
-- planner of our own. Hammer of Wrath is not in it: its cast time resets the swing.
--
-- After each fight a report counts every swing: twisted, late (Seal of Blood landed just after the swing), clipped
-- (a GCD was running through the whole window) or plain (no Command up), plus fillers used.
--
-- Settings (ns.DB settings "swing"): see Core/DB.lua defaults.
local addonName, ns = ...

local SwingTimer = ns:NewModule("SwingTimer")
local CL = ns.CombatLog

local floor, max, min, huge = math.floor, math.max, math.min, math.huge
local pairs, ipairs, tonumber, type, select = pairs, ipairs, tonumber, type, select
local strformat = string.format

local OVERLAP = 0.399            -- Seal of Command stays on this long after switching away (seals.go)
local MARGIN = 0.05              -- keep the press this far from either edge of the window (jitter)
local GCD = 1.5
local LATE_WINDOW = 0.25         -- Seal of Blood landing this soon after a swing counts as a late twist
local REPORTS_MAX = 10

SwingTimer.OVERLAP, SwingTimer.MARGIN, SwingTimer.GCD = OVERLAP, MARGIN, GCD

-- Spells by a known id (names come from GetSpellInfo, so any client language works)
local IDS = {
    soc = 20375, sob = 31892, cs = 35395, judge = 20271, exo = 879, cons = 26573, hoj = 853,
}
SwingTimer.IDS = IDS
-- Icons: the spell's own when the client knows it (Seal of the Martyr gets its own), these otherwise
local ICONS = {
    soc = "Interface\\Icons\\Ability_Warrior_InnerRage", sob = "Interface\\Icons\\Spell_Holy_SealOfBlood",
    cs = "Interface\\Icons\\Spell_Holy_CrusaderStrike", judge = "Interface\\Icons\\Spell_Holy_RighteousFury",
    exo = "Interface\\Icons\\Spell_Holy_Excorcism_02", cons = "Interface\\Icons\\Spell_Holy_InnerFire",
    hoj = "Interface\\Icons\\Spell_Holy_SealOfMight", wait = "Interface\\Icons\\INV_Misc_PocketWatch_01",
}
-- Stuns and incapacitates on the target (one id of each; the client names every rank alike): Seal of Command's
-- Judgement does double damage then ("456 to 504 if the target is stunned or incapacitated", the TBC tooltip).
local STUNS = { 853, 408, 1833, 20253, 7922, 12809, 20549, 5211, 9005, 22570, 24394, 12355, 15269, 20170, 30283, 5530,
                12798, 16922, 1776, 6770, 20066 }
local HOJ_CD = 60

local MARTYR = 348700            -- Seal of the Martyr: the Alliance's Seal of Blood in TBC Classic, same twist
local names = {}                 -- key -> localized spell name
local function NameOf(key)
    if not names[key] and GetSpellInfo then
        local id = IDS[key]
        -- (the Alliance's is Seal of the Martyr: by faction, so it is named right before it is trained too)
        if key == "sob" and ((IsSpellKnown and IsSpellKnown(MARTYR))
            or (UnitFactionGroup and UnitFactionGroup("player") == "Alliance")) and GetSpellInfo(MARTYR) then
            id = MARTYR
        end
        names[key] = GetSpellInfo(id)
    end
    return names[key]
end
SwingTimer.NameOf = NameOf
SwingTimer.ICONS = setmetatable({}, { __index = function(_, key)
    local n = IDS[key] and NameOf(key)
    local tex = n and GetSpellTexture and GetSpellTexture(n)
    if not tex and key == "sob" and n and n == GetSpellInfo(MARTYR) and GetSpellTexture then tex = GetSpellTexture(MARTYR) end
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

function SwingTimer:IsEnabled() return Get("enabled", false) and true or false end

-- A class tool (Core/ClassKit.lua) for Retribution: the most points in the third tree, or (no points yet) Seal of
-- Command known. Its Settings section comes from UI/SwingTimerHUD.lua.
ns.ClassKit:Register({
    key = "swing", label = "Swing timer", class = "PALADIN", specs = { "Retribution" }, order = 20, icon = IDS.sob,
    fallback = function() return NameOf("soc") ~= nil and (IsSpellKnown and IsSpellKnown(IDS.soc)) or false end,
})

function SwingTimer:IsRet()
    return ns.ClassKit:IsMine("swing")
end

-- Situations (Core/Situation.lua): no pack for Ret (the twist is the same on one target or many, and Consecration
-- doesn't pay its mana), only a player.
ns.Situation:Register("swing", { kinds = { player = true }, active = function() return SwingTimer.active and true or false end })

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

-- Durations as the client reports them (haste, talents and set bonuses included), kept from the last time each was
-- seen running: the GCD from a seal's cooldown, a spell's own cooldown when it is longer than the GCD.
state.gcd = GCD
state.cd = { cs = 6, judge = 10, exo = 15, cons = 8 }

local function GcdLeft(now)
    local n = NameOf("soc") or NameOf("sob")
    if not n or not GetSpellCooldown then return 0 end
    local s, d = GetSpellCooldown(n)
    s, d = tonumber(s) or 0, tonumber(d) or 0
    if s == 0 or d > GCD + 0.01 then return 0 end
    state.gcd = d
    return max(0, s + d - now)
end

local function CdLeft(key, now)
    local n = NameOf(key)
    if not n or not GetSpellCooldown then return 0 end
    local s, d = GetSpellCooldown(n)
    s, d = tonumber(s) or 0, tonumber(d) or 0
    if s == 0 or d <= state.gcd + 0.01 then return 0 end   -- a GCD is not the spell's own cooldown
    state.cd[key] = d
    return max(0, s + d - now)
end

-- In the spellbook, by id (a talent spell such as Crusader Strike is missing from a Reckoning build). The name
-- lookup is only the fallback for a client without IsPlayerSpell / IsSpellKnown.
local function Known(key)
    local id = IDS[key]
    if id and IsPlayerSpell then return IsPlayerSpell(id) and true or false end
    if id and IsSpellKnown then return IsSpellKnown(id) and true or false end
    local n = NameOf(key)
    return n ~= nil and GetSpellInfo(n) ~= nil
end

local function TargetType()
    local t = UnitCreatureType and UnitCreatureType("target")
    return t
end

-- Until when the target is stunned or incapacitated (0: it isn't).
local stunNames
local function StunnedUntil(now)
    if state.demoStun then return state.demoStun end
    if not stunNames then
        stunNames = {}
        for _, id in ipairs(STUNS) do
            local n = GetSpellInfo and GetSpellInfo(id)
            if n then stunNames[n] = true end
        end
    end
    if not UnitDebuff or not (UnitExists and UnitExists("target")) then return 0 end
    local untilT = 0
    for i = 1, 40 do
        local n, _, _, _, _, expires = UnitDebuff("target", i)
        if not n then break end
        if stunNames[n] then
            expires = tonumber(expires) or 0
            untilT = max(untilT, expires > 0 and expires or now + 1)
        end
    end
    return untilT
end
SwingTimer.StunnedUntil = StunnedUntil

local UNDEAD_DEMON = { Demon = true, Undead = true, ["Dämon"] = true, ["Untoter"] = true, ["Démon"] = true,
    ["Mort-vivant"] = true, ["Demonio"] = true, ["No-muerto"] = true }

-- The rotation's input, from the live client.
function SwingTimer:Snapshot(now)
    now = now or GetTime()
    if self.practice and self.practice.run then return self.practice:Snapshot(now) end
    state.speed = MainSpeed()
    local nxt, sp = self:NextSwing(now)
    local mana, manaMax = UnitPower("player", 0) or 0, UnitPowerMax("player", 0) or 1
    local use = { cs = Known("cs"), exo = Get("use.exo", false) and Known("exo"),
                  cons = Get("use.cons", false) and Known("cons") }
    if use.exo and not UNDEAD_DEMON[TargetType() or ""] then use.exo = false end
    if use.cons and manaMax > 0 and mana / manaMax * 100 < (tonumber(Get("consMana", 40)) or 40) then use.cons = false end
    -- against a player: Seal of Command's Judgement on a stunned target; Hammer of Justice to set it up (opt-in)
    local sit = ns.Situation:Info("swing", now)
    local player = sit.kind == "player"
    use.stunJudge = player and Get("stunJudge", true) and true or false
    use.hoj = player and Get("hoj", false) and Known("hoj") or false
    return {
        sit = sit, stunUntil = (use.stunJudge or use.hoj) and StunnedUntil(now) or 0,
        now = now, nextSwing = nxt, lastSwing = state.last or (nxt - sp), speed = sp, lat = self:Latency(),
        gcdReady = now + GcdLeft(now), seal = state.seal, use = use,
        ready = { cs = now + CdLeft("cs", now), judge = now + CdLeft("judge", now), exo = now + CdLeft("exo", now),
                  cons = now + CdLeft("cons", now), hoj = now + CdLeft("hoj", now) },
        gcd = state.gcd, cd = state.cd,
    }
end

-- ---------------------------------------------------------------------------------------------------------------
-- The rotation: WoWSims' Retribution priority list (Data/SimAPL.lua, the one the gear sim plays), in order:
--   1. Seal of Command up and the swing within 0.4 s       -> Seal of Blood (the twist)
--   2. Seal of Blood up                                     -> Crusader Strike when ready
--   3. Seal of Blood up, GCD ready, <= 0.8 s after a swing   -> Judgement (off the GCD)
--   4. Seal of Blood up                                     -> Exorcism / Consecration (off unless turned on;
--                                                              WoWSims leaves both off)
--   5. no Command, Judgement on cooldown, its GCD ends before the next window closes, >= 0.5 s after a swing
--                                                           -> Seal of Command
-- plus: no seal at all -> Seal of Command.
-- Against a player (Core/Situation.lua), before all of them: Seal of Command up and the target stunned or
-- incapacitated -> Judgement (Command's does double then); Hammer of Justice (opt-in) to stun it when Command is up and
-- Judgement is ready or nearly. The 0.4 s of rule 1 is on the server's clock; on ours the window is one
-- round trip earlier and MARGIN inside both edges (the press zone). Haste: the swing length is the client's
-- UnitAttackSpeed read on every pass (a running swing is rescaled the moment it changes, UNIT_ATTACK_SPEED), and the
-- GCD and cooldowns are the durations the client last reported, so nothing here is a fixed number.
-- Run(snap) plays the rules forward from now (as if each press is made on time) and returns the presses:
-- { { key, at (our clock), twist (the swing it twists into) } }; the first one at or before now is the press to make.
-- ---------------------------------------------------------------------------------------------------------------
function SwingTimer.Run(snap, horizon)
    horizon = horizon or (snap.now + 2 * snap.speed + 0.5)
    local lat = snap.lat
    local t = snap.now
    local nxt, last, speed = snap.nextSwing, snap.lastSwing, snap.speed
    local seal, gcd = snap.seal, snap.gcdReady
    local rd = {}
    for k, v in pairs(snap.ready) do rd[k] = v end
    local use, G, CD = snap.use, snap.gcd, snap.cd
    local stunUntil, stunFrom = snap.stunUntil or 0, t
    rd.hoj = rd.hoj or t
    local steps = {}
    for _ = 1, 40 do
        if t > horizon then break end
        while t >= nxt do last, nxt = nxt, nxt + speed end
        local zone0, zone1 = nxt - OVERLAP + MARGIN - lat, nxt - MARGIN - lat
        local gcdOk = t >= gcd - 0.001
        local act, twist
        if use.stunJudge and seal == "soc" and t >= rd.judge and t >= stunFrom and t + lat < stunUntil then act = "judge"
        elseif use.hoj and seal == "soc" and gcdOk and t >= rd.hoj and rd.judge - t <= 0.5 and stunUntil <= t + lat then
            act = "hoj"
        elseif seal == "soc" and gcdOk and t >= zone0 and t <= zone1 then act, twist = "sob", nxt
        elseif seal == "sob" and gcdOk and use.cs and t >= rd.cs then act = "cs"
        elseif seal == "sob" and gcdOk and t >= rd.judge and t - last <= 0.8 then act = "judge"
        elseif seal == "sob" and gcdOk and use.exo and t >= rd.exo then act = "exo"
        elseif seal == "sob" and gcdOk and use.cons and t >= rd.cons then act = "cons"
        elseif seal ~= "soc" and gcdOk and (seal == nil or t < rd.judge) and G <= (nxt - t) + OVERLAP
            and t - last >= 0.5 then act = "soc"
        elseif seal == nil and gcdOk then act = "soc"
        end
        if act then
            steps[#steps + 1] = { key = act, at = t, twist = twist }
            if act == "judge" then rd.judge = t + CD.judge; seal = nil
            elseif act == "hoj" then
                -- (the stun lands one round trip later: Judgement after that)
                gcd, rd.hoj, stunFrom, stunUntil = t + G, t + HOJ_CD, t + lat, t + lat + 6
            else
                gcd = t + G
                if act == "sob" or act == "soc" then seal = act end
                if CD[act] then rd[act] = t + CD[act] end
            end
        else
            -- jump to the next moment a rule could fire
            local cand = { gcd, zone0, nxt + 0.001, last + 0.5, rd.cs, rd.judge }
            if use.hoj then cand[#cand + 1] = rd.hoj end
            if stunFrom > t then cand[#cand + 1] = stunFrom end
            if use.exo then cand[#cand + 1] = rd.exo end
            if use.cons then cand[#cand + 1] = rd.cons end
            local nt = huge
            for _, c in ipairs(cand) do if c and c > t + 0.001 and c < nt then nt = c end end
            if nt == huge then break end
            t = nt
        end
    end
    return steps
end

-- Is auto attack running? No swing seen for 1.6 swings = idle: the HUD rests instead of guessing.
function SwingTimer:IsSwinging(now)
    now = now or GetTime()
    if self.practice then return true end      -- twist practice (Core/SwingPractice.lua) runs the swings
    if not state.last then return false end
    return now - state.last < state.speed * 1.6
end

-- What the HUD shows: the rotation played forward from the live state, redone every frame (it is a few dozen steps
-- of arithmetic), so a press you hold back slides along smoothly instead of jumping at a refresh rate.
local shown, shownAt = nil, 0
function SwingTimer:MarkDirty() shownAt = 0 end

function SwingTimer:Current()
    local now = GetTime()
    if not self:IsSwinging(now) then shown = nil return nil end
    if shown and now == shownAt then return shown end
    local snap = self:Snapshot(now)
    local steps = SwingTimer.Run(snap)
    shownAt = now
    shown = { snap = snap, plan = { steps = steps } }
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

-- Extra attacks (Reckoning, Windfury, Hand of Justice, Sword Specialization): the log names them with
-- SPELL_EXTRA_ATTACKS just before the hits they cause. Those hits are not the weapon's swing, so they must not
-- restart the timer; they only flash the ring (state.extraAt). Unused grants expire after a moment.
local EXTRA_TTL = 0.04          -- the hits share the grant's log timestamp (WeakAuras uses the same window)
local extraLeft, extraUntil = 0, 0
local FILLERS = { "cs", "exo", "cons", "judge" }

-- One combat-log event (a Core/CombatLog.lua subscriber while the timer runs and practice does not: the event name,
-- then the client's payload; while twist practice runs, practice owns the state).
local function OnCombatLog(_, ts, sub, _, src, _, _, _, _, _, _, _, _, spellName, _, amount)
    if src ~= myGUID or not SwingTimer.active or SwingTimer.practice then return end
    local now = GetTime()
    if sub == "SPELL_EXTRA_ATTACKS" then
        extraLeft, extraUntil = (tonumber(amount) or 1), ts + EXTRA_TTL
    elseif sub == "SWING_DAMAGE" or sub == "SWING_MISSED" then
        if extraLeft > 0 and ts <= extraUntil then
            extraLeft = extraLeft - 1
            state.extraAt = now
        else
            extraLeft = 0
            OnSwing(now)
        end
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
        for _, k in ipairs(FILLERS) do
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
    local rep = {
        at = time and time() or 0, target = f.target, dur = GetTime() - f.start, swings = f.swings, counts = c,
        fillers = f.fillers,
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
    -- (while twist practice runs, the real swings, seals and casts are ignored: practice owns the state; the combat
    -- log is read only while the timer runs, see Refresh)
    ns:RegisterEvent("UNIT_AURA", function(_, unit)
        if unit ~= "player" or not SwingTimer.active or SwingTimer.practice then return end
        local before = state.seal
        ScanSeals()
        if before ~= state.seal then SwingTimer:MarkDirty() end
        -- Blood replaced Command: Command lingers for the overlap (the aura is gone already on our side)
        if before == "soc" and state.seal == "sob" then
            state.socUntil = GetTime() + OVERLAP
        end
    end)
    ns:RegisterEvent("UNIT_SPELLCAST_SENT", function(_, unit, _, _, spellArg)
        if unit ~= "player" or not SwingTimer.active or SwingTimer.practice then return end
        local name = type(spellArg) == "number" and GetSpellInfo(spellArg) or spellArg
        if name then sentAt[name] = GetTime() end
    end)
    ns:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit)
        if unit ~= "player" or not SwingTimer.active or SwingTimer.practice then return end
        local now = GetTime()
        SwingTimer:MarkDirty()
        if GcdLeft(now) > 0 then state.gcdStart = now - (GCD - GcdLeft(now)) end
    end)
    ns:RegisterEvent("UNIT_ATTACK_SPEED", function(_, unit)
        if unit ~= "player" or SwingTimer.practice then return end
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
    end)
    ns:On("CLASSKIT_CHANGED", function() SwingTimer:Refresh() end)
    ns:RegisterEvent("SPELLS_CHANGED", function() for k in pairs(names) do names[k] = nil end end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:find("^swing") and not path:find("^swing%.practice") then
            SwingTimer:Refresh()
        end
    end)
    self:Refresh()
end

-- Demo mode: made-up swings every 3.5 s with Seal of Command up, so the HUD and its planner can be tried by anyone,
-- anywhere (nothing is cast).
local demoDriver
local function DemoSwings(on)
    if on and not demoDriver then
        demoDriver = CreateFrame("Frame")
        local acc = 0
        demoDriver:SetScript("OnUpdate", function(_, elapsed)
            acc = acc + (elapsed or 0)
            if acc < 0.1 then return end
            acc = 0
            local now = GetTime()
            state.speed = 3.5
            -- (a duel on the Demo page: the target is stunned for 6 s out of every 14)
            local d = ns.Situation:Demo()
            if d and d.kind == "player" then state.demoStun = (now % 14 < 6) and (now - now % 14 + 6) or 0
            else state.demoStun = nil end
            state.seal = "soc"
            state.sealExpires = now + 25
            if not state.last or now - state.last >= state.speed then
                state.last = now
                SwingTimer:MarkDirty()
            end
        end)
    elseif demoDriver then
        demoDriver:SetShown(on and true or false)
        if not on then state.last = nil end
    end
end

-- (its part picked on the Demo page; the made-up swings play while the demo's pull does)
function SwingTimer:IsDemo() return ns.ClassKit:IsDemo("swing") end
local function DemoPlaying() return ns.Demo and ns.Demo.IsPlaying and ns.Demo:IsPlaying("swing") or false end

-- (twist practice keeps it on while it runs, even when the swing timer itself is off)
function SwingTimer:Refresh()
    -- (off until switched on; its demo shows it anyway)
    local demo = DemoPlaying()
    self.active = self:IsRet() and (self:IsEnabled() or self.practice ~= nil or demo)
    DemoSwings(self.active and demo and not self.practice)
    CL:SetSubscribed("swing", OnCombatLog, self.active and not self.practice)
    ns:Fire("SWING_STATE", self.active)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Slash: /dz swing [on | off | move | report | practice] (move: Edit layout; unlock still opens it)
-- ---------------------------------------------------------------------------------------------------------------
ns:RegisterSlash("swing", function(rest)
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "on" or rest == "off" then
        ns.DB:SetSetting("swing.enabled", rest == "on")
        ns:Print("Swing timer %s.", rest == "on" and "on" or "off")
    elseif rest == "move" or rest == "unlock" then
        if ns.EditMode then ns.EditMode:Open() end
    elseif rest == "practice" then
        if ns.SwingPracticeUI then ns.SwingPracticeUI:Open() end
    elseif rest == "report" then
        local r = SwingTimer:Reports()[1]
        if not r then ns:Print("No fight recorded yet.") return end
        local c = r.counts
        local total = c.twist + c.late + c.clip
        ns:Print("%s (%ds): %d/%d twists landed, %d late, %d clipped by a GCD, %d plain swings.",
            r.target or "Last fight", floor(r.dur or 0), c.twist, total, c.late, c.clip, c.plain)
    else
        local world, meas, used = SwingTimer:LatencyInfo()
        ns:Print("Swing timer is %s%s. Latency: world %s ms, measured %s ms, using %d ms.",
            SwingTimer:IsEnabled() and "on" or "off", SwingTimer.active and "" or " (not Retribution)",
            tostring(world or "?"), tostring(meas or "-"), floor((used or 0) * 1000 + 0.5))
        ns:Print("/dz swing on | off | move | report | practice")
    end
end, "Swing timer for twisting Retribution Paladins (on | off | move | report | practice)")
