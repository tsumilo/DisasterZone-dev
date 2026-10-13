if DisasterZoneBoot and DisasterZoneBoot.Run("Core/ShotTimer.lua", ...) then return end -- DisasterZone: hunter shot timer.
-- The Auto Shot -> Steady Shot timer for Hunters: the Retribution swing timer's twin (Core/SwingTimer.lua), with a
-- planner that says what to press next and when. The HUD is UI/ShotTimerHUD.lua (the same ring, ns.SwingRing).
--
-- Auto Shot, as WoWSims models it (sim/core/attack.go, sim/hunter/hunter.go; the gear sim's Sim/Attack.lua):
--   * every shot starts with a 0.5 s windup over ranged haste; the hunter casts nothing during it and the shot leaves
--     at its end. The next windup starts one ranged swing (UnitRangedDamage) after this one started.
--   * Steady Shot (1.5 s) and Multi-Shot (0.5 s) are casts hastened by the same ranged haste (quiver, Quick Shots,
--     Rapid Fire, haste rating, Bloodlust...). A cast still running when the next windup is due pushes that windup
--     to the cast's end: that is clipping. Arcane Shot and Kill Command are instant.
--   * the GCD is 1.5 s and not hastened; Kill Command is off the GCD (usable for 5 s after a crit).
--   * a new attack speed only counts from the next swing on; no Auto Shot while moving (the windup waits).
-- Haste = the ranged weapon's own speed / the speed now: the weapon's speed is read from its tooltip and corrected by
-- every Steady Shot we see cast (its real cast time), so nothing here is a fixed number.
--
-- What to press: WoWSims' Hunter rotation (Data/SimAPL.lua "HUNTER:*", the one the gear sim plays; melee weaving
-- off), see Run below. Latency: as for twisting, a press reaches the server half a round trip later and the shot we
-- see left half a round trip earlier, so every "does it fit" check uses one round trip.
--
-- After each fight a report counts every Auto Shot: on time, clipped (a cast pushed it; the time lost adds up) or
-- held by moving, plus the shots cast.
--
-- Settings (ns.DB settings "shot"): see Core/DB.lua defaults.
local addonName, ns = ...

local ShotTimer = ns:NewModule("ShotTimer")

local floor, max, min, huge = math.floor, math.max, math.min, math.huge
local pairs, ipairs, tonumber, type = pairs, ipairs, tonumber, type

local GCD = 1.5
local WINDUP = 0.5               -- Auto Shot's windup before haste (attack.go RangedSwingWindup)
local CAST = { steady = 1.5, multi = 0.5 }
local SLACK = 0.12               -- a shot this late still counts as on time (server ticks, jitter)
local REPORTS_MAX = 10

ShotTimer.GCD, ShotTimer.WINDUP, ShotTimer.CAST = GCD, WINDUP, CAST

-- Spells by a known id (names come from GetSpellInfo, so any client language works; casting by name uses the
-- highest rank the hunter knows)
local IDS = {
    auto = 75, steady = 34120, multi = 27021, arcane = 27019, kc = 34026, hawk = 27044, viper = 34074,
}
ShotTimer.IDS = IDS
local ICONS = {
    auto = "Interface\\Icons\\Ability_Whirlwind", steady = "Interface\\Icons\\Ability_Hunter_SteadyShot",
    multi = "Interface\\Icons\\Ability_UpgradeMoonGlaive", arcane = "Interface\\Icons\\Ability_ImpalingBolt",
    kc = "Interface\\Icons\\Ability_Hunter_KillCommand", hawk = "Interface\\Icons\\Spell_Nature_RavenForm",
    viper = "Interface\\Icons\\Ability_Hunter_AspectoftheViper", wait = "Interface\\Icons\\INV_Misc_PocketWatch_01",
}

local names = {}                 -- key -> localized spell name
local function NameOf(key)
    if not names[key] and GetSpellInfo and IDS[key] then names[key] = GetSpellInfo(IDS[key]) end
    return names[key]
end
ShotTimer.NameOf = NameOf
ShotTimer.ICONS = setmetatable({}, { __index = function(_, key)
    local tex = IDS[key] and GetSpellTexture and GetSpellTexture(IDS[key])
    return tex or ICONS[key]
end })

local KEY_OF = {}                -- spell id -> key (casts we count)
for k, id in pairs(IDS) do KEY_OF[id] = k end

-- ---------------------------------------------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------------------------------------------
local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting("shot." .. path)
    if v == nil then return default end
    return v
end
ShotTimer.Get = Get

function ShotTimer:IsEnabled() return Get("enabled", true) and true or false end

-- A class tool (Core/ClassKit.lua) for every Hunter: all three specs live on Steady Shot. Its Settings card comes
-- from UI/ShotTimerHUD.lua.
ns.ClassKit:Register({ key = "shot", label = "Shot timer", class = "HUNTER", order = 20, icon = IDS.steady })

function ShotTimer:IsMine() return ns.ClassKit:IsMine("shot") end
function ShotTimer:IsDemo() return ns.ClassKit:IsDemo() end

-- ---------------------------------------------------------------------------------------------------------------
-- Latency (as Core/SwingTimer.lua: the world latency averaged with what we measure, here the time from pressing a
-- cast to the server starting it)
-- ---------------------------------------------------------------------------------------------------------------
local measured                   -- smoothed SENT -> START delay, seconds
local sentAt = {}                -- [spell id] = GetTime() of UNIT_SPELLCAST_SENT

function ShotTimer:Latency()
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

function ShotTimer:LatencyInfo()
    local world
    if GetNetStats then
        local _, _, home, w = GetNetStats()
        world = tonumber(w) or tonumber(home)
    end
    return world, measured and floor(measured * 1000 + 0.5), self:Latency()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Live state: the Auto Shot clock, haste, casts, cooldowns
-- ---------------------------------------------------------------------------------------------------------------
local state = {
    last = nil,                  -- GetTime() of the last Auto Shot we saw leave
    cycle = nil,                 -- the swing that shot started (a new speed counts from the next swing)
    speed = 3,                   -- the ranged swing now (hasted)
    auto = false,                -- Auto Shot is on (repeating)
    startAt = nil,               -- when Auto Shot was turned on
    pushTo = 0,                  -- a cast in progress holds the next windup until here
    castEnd = 0,                 -- our cast bar's end
    moving = false, movedSince = false,
    aspect = nil,                -- "hawk" | "viper" | nil
}
ShotTimer.state = state

-- Demo mode: a made-up 3.0 bow at 2.2 s (a quiver and Serpent's Swiftness), Hawk up, a bot pressing what the plan says.
local DEMO_SPEED, DEMO_BASE = 2.2, 3.0
local DEMO_REACTION = 0.2        -- the demo bot presses this long after a press is due, as a player would
local demo                       -- { gcd, ready = {}, kcUntil } while demo mode runs

local function RangedSpeed()
    if demo then return DEMO_SPEED end
    if UnitRangedDamage then
        local s = UnitRangedDamage("player")
        if s and s > 0 then return s end
    end
    return state.speed
end

-- The ranged weapon's own speed (no haste): learned from Steady Shot casts per weapon, else its tooltip.
local tip, tipSpeed = nil, {}
local function TooltipSpeed(id)
    if tipSpeed[id] ~= nil then return tipSpeed[id] or nil end
    local ok, speed = pcall(function()
        tip = tip or CreateFrame("GameTooltip", "DisasterZoneShotScanTooltip", nil, "GameTooltipTemplate")
        tip:SetOwner(UIParent, "ANCHOR_NONE")
        tip:ClearLines()
        tip:SetInventoryItem("player", 18)
        for i = 1, (tip:NumLines() or 0) do
            local r = _G["DisasterZoneShotScanTooltipTextRight" .. i]
            local txt = r and r:GetText()
            local n = txt and txt:match("(%d+[%.,]%d%d)")
            if n then return tonumber((n:gsub(",", "."))) end
        end
    end)
    local s = ok and tonumber(speed) or nil
    if s and (s < 1 or s > 5) then s = nil end
    tipSpeed[id] = s or false
    return s
end

local function BaseSpeed()
    if demo then return DEMO_BASE end
    local id = GetInventoryItemID and GetInventoryItemID("player", 18)
    if not id then return nil end
    local learned = Get("base")
    if type(learned) == "table" and tonumber(learned[id]) then return tonumber(learned[id]) end
    return TooltipSpeed(id)
end

-- Ranged haste as a multiplier (1.3 = 30% faster).
function ShotTimer:Haste(speed)
    speed = speed or RangedSpeed()
    local b = BaseSpeed()
    if b and speed and speed > 0 then return max(0.5, b / speed) end
    return 1
end

-- A Steady Shot just started: its real cast time tells the haste, so the weapon's own speed (kept per weapon).
local function Learn(castTime)
    if demo or not castTime or castTime < 0.4 or castTime > 3 then return end
    local id = GetInventoryItemID and GetInventoryItemID("player", 18)
    if not id then return end
    local base = floor(RangedSpeed() * CAST.steady / castTime * 100 + 0.5) / 100
    local learned = Get("base")
    learned = type(learned) == "table" and learned or {}
    local old = tonumber(learned[id])
    if not old or math.abs(old - base) > 0.03 then
        learned[id] = base
        ns.DB:SetSetting("shot.base", learned)
    end
end
ShotTimer.Learn = Learn

function ShotTimer:Windup() return WINDUP / self:Haste() end

local function Moving()
    if demo then return false end
    if state.moving then return true end
    return GetUnitSpeed and (tonumber(GetUnitSpeed("player")) or 0) > 0 or false
end

-- When the next Auto Shot's windup starts (our clock; the shot leaves a windup later).
function ShotTimer:NextStart(now)
    now = now or GetTime()
    local w = self:Windup()
    local nxt
    if state.last then
        local cycle = state.cycle or state.speed
        nxt = state.last - w + cycle
        if state.pushTo > nxt then nxt = state.pushTo end
        if not Moving() then
            while nxt + w < now - 0.2 do nxt = nxt + RangedSpeed() end   -- missed events: keep the rhythm
        end
    else
        nxt = max(state.startAt or now, state.pushTo)
    end
    if Moving() and nxt < now then nxt = now end     -- no Auto Shot while moving: the windup waits
    return nxt
end

local function ScanAspect()
    local hawk, viper = NameOf("hawk"), NameOf("viper")
    local aspect
    if UnitBuff then
        for i = 1, 40 do
            local n = UnitBuff("player", i)
            if not n then break end
            if n == hawk then aspect = "hawk" elseif n == viper then aspect = "viper" end
        end
    end
    state.aspect = aspect
end
ShotTimer.ScanAspect = ScanAspect

-- Durations as the client reports them, kept from the last time each was seen running (talents and sets included).
state.gcd, state.gcdEnd = GCD, 0
state.cd = { multi = 10, arcane = 6, kc = 5 }

local function GcdLeft(now)
    if demo then state.gcdEnd = demo.gcd return max(0, demo.gcd - now) end
    local n = NameOf("steady")
    if not n or not GetSpellCooldown then return 0 end
    local s, d = GetSpellCooldown(n)
    s, d = tonumber(s) or 0, tonumber(d) or 0
    if s == 0 or d > GCD + 0.01 then return 0 end
    state.gcd, state.gcdEnd = d, s + d
    return max(0, s + d - now)
end

local function CdLeft(key, now)
    if demo then return max(0, (demo.ready[key] or 0) - now) end
    local n = NameOf(key)
    if not n or not GetSpellCooldown then return 0 end
    local s, d = GetSpellCooldown(n)
    s, d = tonumber(s) or 0, tonumber(d) or 0
    if s == 0 or d <= state.gcd + 0.01 then return 0 end   -- a GCD is not the spell's own cooldown
    state.cd[key] = d
    return max(0, s + d - now)
end

-- In the spellbook (any rank: by id, else by name, which a client only answers for spells the hunter has).
local function Known(key)
    if demo then return true end
    local id = IDS[key]
    if id and IsPlayerSpell and IsPlayerSpell(id) then return true end
    if id and IsSpellKnown and IsSpellKnown(id) then return true end
    local n = NameOf(key)
    return n ~= nil and GetSpellCooldown ~= nil and GetSpellCooldown(n) ~= nil and IsUsableSpell ~= nil
        and IsUsableSpell(n) ~= nil
end

-- Kill Command: usable (a crit in the last 5 s, the pet in reach) and off cooldown.
local function KillCommandUp(now)
    if demo then return (demo.kcUntil or 0) > now and CdLeft("kc", now) == 0 end
    local n = NameOf("kc")
    if not n or not IsUsableSpell or not Known("kc") then return false end
    return IsUsableSpell(n) and CdLeft("kc", now) == 0 or false
end

-- The rotation's input, from the live client.
function ShotTimer:Snapshot(now)
    now = now or GetTime()
    local sp = RangedSpeed()
    state.speed = sp
    local h = self:Haste(sp)
    local mana, manaMax = UnitPower("player", 0) or 0, UnitPowerMax("player", 0) or 1
    if demo then mana, manaMax = 80, 100 end
    local use = {
        steady = Known("steady"),
        multi = Get("use.multi", true) and Known("multi"),
        arcane = Get("use.arcane", true) and Known("arcane"),
        aspect = Get("aspects", true) and Known("viper") and Known("hawk"),
        viperStart = tonumber(Get("viperStart", 5)) or 5, viperStop = tonumber(Get("viperStop", 25)) or 25,
    }
    return {
        now = now, nextStart = self:NextStart(now), lastShot = state.last, speed = sp,
        cycle = state.cycle or sp, haste = h, windup = WINDUP / h, buffer = min(0.5, 0.25 * sp),
        ct = { steady = CAST.steady / h, multi = CAST.multi / h }, lat = self:Latency(),
        gcdReady = now + GcdLeft(now), busyUntil = max(now, state.castEnd), gcd = state.gcd, cd = state.cd,
        -- since when a press has been possible (the last shot, GCD or cast, whichever ended last): a due press's
        -- window starts there, not at now
        readySince = max(state.last or 0, state.gcdEnd or 0, state.castEnd or 0),
        ready = { multi = now + CdLeft("multi", now), arcane = now + CdLeft("arcane", now) },
        kc = Get("use.kc", true) and KillCommandUp(now), use = use,
        mana = manaMax > 0 and mana / manaMax * 100 or 100, aspect = demo and "hawk" or state.aspect,
    }
end

-- ---------------------------------------------------------------------------------------------------------------
-- The rotation: WoWSims' Hunter priority list (Data/SimAPL.lua "HUNTER:*", melee weaving off), in order:
--   1. Aspect of the Viper below 5% mana, Aspect of the Hawk back from 25% (both on the GCD; Settings can change
--      the numbers or turn the hints off)
--   2. Kill Command whenever it is usable (off the GCD)
--   3. Steady Shot when its cast fits before the next Auto Shot's windup plus a buffer
--   4. Multi-Shot when its cast fits the same way
--   5. Arcane Shot
-- The buffer is min(0.5 s, a quarter of the ranged swing): WoWSims lets a cast push the next Auto Shot by up to that
-- much because a Steady Shot is worth it. Major cooldowns (Rapid Fire, Bestial Wrath, trinkets) are yours to press.
-- "Fits" is on the server's clock: a press reaches it one round trip after the windup time we see.
-- Run(snap) plays the rules forward from now (as if each press is made on time) and returns the presses and the
-- Auto Shots: steps = { { key, at (our clock), cast, latest (the last moment it still fits), off (off the GCD) } },
-- shots = { the times the next Auto Shots leave }; the first step at or before now is the press to make.
-- ---------------------------------------------------------------------------------------------------------------
function ShotTimer.Run(snap, horizon)
    horizon = horizon or (snap.now + 2 * snap.speed + 1)
    local lat, speed, w, buf = snap.lat, snap.speed, snap.windup, snap.buffer
    local t, nxt = snap.now, snap.nextStart
    local gcd, busy = snap.gcdReady, snap.busyUntil
    local rd = {}
    for k, v in pairs(snap.ready) do rd[k] = v end
    local use, G, CD = snap.use, snap.gcd, snap.cd
    local aspect = snap.aspect
    local steps, shots = {}, {}
    if snap.kc then steps[1] = { key = "kc", at = t, off = true } end
    for _ = 1, 60 do
        if t > horizon then break end
        if t >= nxt then
            -- the windup: nothing is cast; the shot leaves at its end and the next windup starts a swing later
            shots[#shots + 1] = nxt + w
            t = max(t, nxt + w)
            nxt = nxt + speed
        elseif t < gcd - 0.001 or t < busy - 0.001 then
            t = min(max(gcd, busy), nxt)
        else
            local left = nxt - (t + lat) + buf      -- room before the next windup, as the server sees the press
            local act, ct
            if use.aspect and aspect ~= "viper" and snap.mana < use.viperStart then act = "viper"
            elseif use.aspect and aspect ~= "hawk" and snap.mana >= use.viperStop then act = "hawk"
            elseif use.steady and snap.ct.steady <= left then act, ct = "steady", snap.ct.steady
            elseif use.multi and t >= rd.multi - 0.001 and snap.ct.multi <= left then act, ct = "multi", snap.ct.multi
            elseif use.arcane and t >= rd.arcane - 0.001 then act = "arcane"
            end
            if act then
                local st = { key = act, at = t, cast = ct }
                steps[#steps + 1] = st
                gcd = t + G
                if act == "viper" or act == "hawk" then aspect = act end
                if CD[act] then rd[act] = t + CD[act] end
                if ct then
                    st.latest = nxt + buf - ct - lat
                    busy = t + ct
                    local e = t + lat + ct                -- the cast ends on the server: a later windup waits
                    if e > nxt then nxt = e end
                end
            else
                -- nothing fits before the shot: wait for it, or for a cooldown
                local nt = nxt
                if use.arcane and rd.arcane > t and rd.arcane < nt then nt = rd.arcane end
                if use.multi and rd.multi > t and rd.multi < nt then nt = rd.multi end
                t = nt
            end
        end
    end
    return steps, shots
end

-- Is Auto Shot running? On, and a shot seen lately (or just turned on): otherwise the HUD rests.
function ShotTimer:IsShooting(now)
    now = now or GetTime()
    if demo then return true end
    if not state.auto then return false end
    if state.last and now - state.last < max(3, (state.cycle or state.speed) * 1.6) then return true end
    return state.startAt ~= nil and now - state.startAt < 3
end

-- What the HUD shows: the rotation played forward from the live state, redone every frame.
local shown, shownAt = nil, 0
function ShotTimer:MarkDirty() shownAt = 0 end

function ShotTimer:Current()
    local now = GetTime()
    if not self:IsShooting(now) then shown = nil return nil end
    if shown and now == shownAt then return shown end
    local snap = self:Snapshot(now)
    local steps, shots = ShotTimer.Run(snap)
    shownAt = now
    shown = { snap = snap, plan = { steps = steps, shots = shots } }
    return shown
end

-- ---------------------------------------------------------------------------------------------------------------
-- Shots, casts and the fight report
-- ---------------------------------------------------------------------------------------------------------------
local fight                      -- { start, shots = { kind, ... }, lost, casts = { [key] = n }, target }

-- An Auto Shot left: how it went against the one before (a cast pushed it, moving held it, or on time).
local function OnShot(now)
    local prev, prevCycle = state.last, state.cycle
    state.last, state.cycle = now, RangedSpeed()
    state.startAt, state.pushTo = nil, 0
    if fight and prev and prevCycle then
        local gap = now - prev
        if gap < prevCycle * 2.5 then
            local late = gap - prevCycle
            local kind = late <= SLACK and "clean" or (state.movedSince and "moved" or "clip")
            fight.shots[#fight.shots + 1] = kind
            if kind == "clip" then fight.lost = fight.lost + late end
        end
    end
    state.movedSince = state.moving
    ShotTimer:MarkDirty()
end
ShotTimer.OnShot = OnShot

local function StartFight()
    fight = { start = GetTime(), shots = {}, lost = 0, casts = {}, target = UnitName("target") }
end

local function EndFight()
    local f = fight
    fight = nil
    if not f or #f.shots < 4 then return end
    local c = { clean = 0, clip = 0, moved = 0 }
    for _, k in ipairs(f.shots) do c[k] = (c[k] or 0) + 1 end
    local rep = {
        at = time and time() or 0, target = f.target, dur = GetTime() - f.start, shots = f.shots, counts = c,
        lost = floor(f.lost * 100 + 0.5) / 100, casts = f.casts,
    }
    local list = Get("reports") or {}
    table.insert(list, 1, rep)
    while #list > REPORTS_MAX do table.remove(list) end
    ns.DB:SetSetting("shot.reports", list)
    ns:Fire("SHOT_REPORT", rep)
end
ShotTimer.StartFight, ShotTimer.EndFight = StartFight, EndFight

function ShotTimer:Reports() return Get("reports") or {} end

local function SpellKey(spellArg)
    local id = tonumber(spellArg)
    if id and KEY_OF[id] then return KEY_OF[id] end
    local name = id and GetSpellInfo and GetSpellInfo(id) or spellArg
    if not name then return nil end
    for k in pairs(IDS) do if NameOf(k) == name then return k end end
end
ShotTimer.SpellKey = SpellKey

-- A cast started (ours): it holds the next windup until it ends; a Steady Shot's real cast time teaches the haste.
local function OnCastStart(key)
    if not UnitCastingInfo then return end
    local _, _, _, s, e = UnitCastingInfo("player")
    s, e = tonumber(s), tonumber(e)
    if not (s and e) then return end
    local now = GetTime()
    state.castEnd = e / 1000
    if state.castEnd > state.pushTo then state.pushTo = state.castEnd end
    if key == "steady" then Learn((e - s) / 1000) end
    local sent = sentAt[key]
    if sent and now - sent < 1.0 then
        local d = now - sent
        measured = measured and (measured * 0.8 + d * 0.2) or d
    end
    sentAt[key] = nil
    ShotTimer:MarkDirty()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------------------------
local function Mine(unit) return unit == "player" and ShotTimer.active end

function ShotTimer:OnLogin()
    state.speed = RangedSpeed()
    ScanAspect()
    if IsAutoRepeatSpell and NameOf("auto") then state.auto = IsAutoRepeatSpell(NameOf("auto")) and true or false end
    ns:RegisterEvent("START_AUTOREPEAT_SPELL", function()
        state.auto, state.startAt = true, GetTime()
        ShotTimer:MarkDirty()
    end)
    ns:RegisterEvent("STOP_AUTOREPEAT_SPELL", function()
        state.auto, state.startAt = false, nil
        ShotTimer:MarkDirty()
    end)
    ns:RegisterEvent("UNIT_SPELLCAST_SENT", function(_, unit, _, _, spellArg)
        if not Mine(unit) then return end
        local key = SpellKey(spellArg)
        if key then sentAt[key] = GetTime() end
    end)
    ns:RegisterEvent("UNIT_SPELLCAST_START", function(_, unit, _, spellArg)
        if not Mine(unit) or demo then return end
        OnCastStart(SpellKey(spellArg))
    end)
    local function stopped(_, unit)
        if not Mine(unit) or demo then return end
        local now = GetTime()
        state.castEnd = min(state.castEnd, now)
        if state.pushTo > now then state.pushTo = now end
        ShotTimer:MarkDirty()
    end
    ns:RegisterEvent("UNIT_SPELLCAST_STOP", stopped)
    ns:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", stopped)
    ns:RegisterEvent("UNIT_SPELLCAST_FAILED", stopped)
    ns:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellArg)
        if not Mine(unit) or demo then return end
        local key = SpellKey(spellArg)
        if key == "auto" then OnShot(GetTime())
        elseif key and fight then fight.casts[key] = (fight.casts[key] or 0) + 1 end
        ShotTimer:MarkDirty()
    end)
    ns:RegisterEvent("UNIT_AURA", function(_, unit)
        if not Mine(unit) then return end
        local before = state.aspect
        ScanAspect()
        if before ~= state.aspect then ShotTimer:MarkDirty() end
    end)
    ns:RegisterEvent("UNIT_RANGEDDAMAGE", function(_, unit)
        if unit == "player" then state.speed = RangedSpeed() end
    end)
    ns:RegisterEvent("PLAYER_STARTED_MOVING", function() state.moving, state.movedSince = true, true end)
    ns:RegisterEvent("PLAYER_STOPPED_MOVING", function() state.moving = false end)
    ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function(_, slot)
        if slot == 18 then state.speed = RangedSpeed() end
    end)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if ShotTimer.active then StartFight() end
    end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if fight then EndFight() end
    end)
    ns:On("CLASSKIT_CHANGED", function() ShotTimer:Refresh() end)
    ns:RegisterEvent("SPELLS_CHANGED", function() for k in pairs(names) do names[k] = nil end end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:find("^shot%.") and path ~= "shot.reports" and path ~= "shot.base" then
            ShotTimer:Refresh()
        end
    end)
    self:Refresh()
end

-- Demo mode: made-up Auto Shots from a 3.0 bow at 2.2 s, and a bot that presses what the plan says a reaction time
-- after it is due (nothing is cast), so the ring plays the whole rotation for anyone, anywhere. Every fourth shot "crits", which
-- lights Kill Command for a moment.
local demoDriver
local function DemoShots(on)
    if on and not demo then
        demo = { gcd = 0, ready = {}, kcUntil = 0, n = 0 }
        state.last, state.cycle, state.pushTo, state.castEnd = nil, nil, 0, 0
        state.startAt = GetTime()
        demoDriver = demoDriver or CreateFrame("Frame")
        demoDriver:SetScript("OnUpdate", function()
            local now = GetTime()
            local nxt = ShotTimer:NextStart(now)
            if now >= nxt + ShotTimer:Windup() then
                OnShot(nxt + ShotTimer:Windup())
                demo.n = demo.n + 1
                if demo.n % 4 == 0 then demo.kcUntil = now + 2.5 end
            end
            local cur = ShotTimer:Current()
            local st = cur and cur.plan.steps[1]
            -- (a due press is planned at "now" every frame: the reaction counts from when it first became due)
            local due = st and st.at <= now + 0.001
            if due and demo.dueKey ~= st.key then demo.dueKey, demo.dueAt = st.key, now end
            if not due then demo.dueKey = nil end
            if due and now - demo.dueAt >= DEMO_REACTION then
                demo.dueKey = nil
                demo.presses = (demo.presses or 0) + 1
                if st.key == "kc" then
                    demo.ready.kc, demo.kcUntil = now + state.cd.kc, 0
                else
                    demo.gcd = now + GCD
                    if state.cd[st.key] then demo.ready[st.key] = now + state.cd[st.key] end
                    if st.cast then
                        state.castEnd = now + st.cast
                        local e = now + cur.snap.lat + st.cast
                        if e > state.pushTo then state.pushTo = e end
                    end
                end
                ShotTimer:MarkDirty()
            end
        end)
        demoDriver:Show()
    elseif not on and demo then
        demo = nil
        if demoDriver then demoDriver:Hide() end
        state.last, state.cycle, state.startAt, state.pushTo, state.castEnd = nil, nil, nil, 0, 0
        state.speed = RangedSpeed()
    end
end

function ShotTimer:Refresh()
    self.active = self:IsMine() and self:IsEnabled()
    DemoShots(self.active and self:IsDemo())
    ns:Fire("SHOT_STATE", self.active)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Slash: /dz shot [on | off | unlock | lock | report]
-- ---------------------------------------------------------------------------------------------------------------
ns:RegisterSlash("shot", function(rest)
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "on" or rest == "off" then
        ns.DB:SetSetting("shot.enabled", rest == "on")
        ns:Print("Shot timer %s.", rest == "on" and "on" or "off")
    elseif rest == "unlock" or rest == "lock" then
        ns.DB:SetSetting("shot.locked", rest == "lock")
        ns:Print(rest == "lock" and "Shot timer locked." or "Shot timer unlocked: drag it where you want it, then /dz shot lock.")
    elseif rest == "report" then
        local r = ShotTimer:Reports()[1]
        if not r then ns:Print("No fight recorded yet.") return end
        local c = r.counts
        local total = c.clean + c.clip + c.moved
        local casts = r.casts or {}
        ns:Print("%s (%ds): %d/%d Auto Shots on time, %d clipped (%.1f s lost), %d held by moving; %d Steady Shots.",
            r.target or "Last fight", floor(r.dur or 0), c.clean, total, c.clip, r.lost or 0, c.moved, casts.steady or 0)
    else
        local world, meas, used = ShotTimer:LatencyInfo()
        local h = ShotTimer:Haste()
        ns:Print("Shot timer is %s%s. Ranged haste %d%%, Steady Shot %.2f s. Latency: world %s ms, measured %s ms, using %d ms.",
            ShotTimer:IsEnabled() and "on" or "off", ShotTimer.active and "" or " (not a Hunter)",
            floor((h - 1) * 100 + 0.5), CAST.steady / h, tostring(world or "?"), tostring(meas or "-"),
            floor((used or 0) * 1000 + 0.5))
        ns:Print("/dz shot on | off | unlock | lock | report")
    end
end, "Auto Shot / Steady Shot timer for Hunters (on | off | unlock | lock | report)")
