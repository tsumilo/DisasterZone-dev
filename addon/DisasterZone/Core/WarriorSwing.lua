if DisasterZoneBoot and DisasterZoneBoot.Run("Core/WarriorSwing.lua", ...) then return end -- DisasterZone: warrior swing timer.
-- The swing timer for Arms and Fury warriors: the Retribution / Hunter ring (ns.SwingRing) with the off-hand swing on
-- an inner ring, rage as a globe (or a bar, in the flat themes) and a Heroic Strike lamp on the main-hand landing
-- point. The HUD is UI/WarriorSwingHUD.lua. Mockup: dev/art/casc/warrior_mockup (approved 2026-10-15).
--
-- Swings, as the client tells them: every SWING_DAMAGE / SWING_MISSED of ours in the combat log (its isOffHand says
-- which hand), a Heroic Strike / Cleave landing (they replace the main-hand swing), a Slam finishing (it restarts the
-- swing). Extra attacks (Sword Specialization, Windfury, Hand of Justice) are named by SPELL_EXTRA_ATTACKS just before
-- their hits and do not restart the timer. Speeds are UnitAttackSpeed's (main, off); a speed change mid-swing scales
-- what is left of it, as Core/SwingTimer.lua does.
--
-- What to press: WoWSims' warrior rotations (Data/SimAPL.lua "WARRIOR:Fury" / "WARRIOR:Arms", the TBC APLs), played
-- forward from the live state, see Run. Everything is checked against the character: a spell is only suggested when
-- it is in the spellbook (any rank), a stance-bound one only in its stance, Execute only under 20%, Rampage only when
-- the client says it is usable, and the off-hand ring only shows with an off-hand weapon. Major cooldowns (Death Wish,
-- Recklessness, trinkets) are yours to press.
--
-- Heroic Strike is the warrior's one decision on every swing: queue it (the swing becomes a Heroic Strike: more damage,
-- no rage from the hit) or keep the rage. The lamp says it: "queue" while rage is over the Heroic Strike line (WoWSims:
-- 40 for Fury and dual-wield Arms, 80 for two-handed Arms; a setting can move it) and Execute is not the move,
-- "queued" while it is, "hold" otherwise.
--
-- Settings (ns.DB settings "war"): see Core/DB.lua defaults.
local addonName, ns = ...

local War = ns:NewModule("WarriorSwing")
local CL = ns.CombatLog

local floor, max, min, huge = math.floor, math.max, math.min, math.huge
local pairs, ipairs, tonumber, type = pairs, ipairs, tonumber, type

local GCD = 1.5
local HS_WINDOW = 0.6            -- the last part of the main-hand swing where queueing Heroic Strike is the call
local SLAM_AFTER = 0.3           -- WoWSims "2H Arms": Slam within latency + 0.3 s of the main-hand swing
local REPORTS_MAX = 10
War.GCD, War.HS_WINDOW, War.SLAM_AFTER = GCD, HS_WINDOW, SLAM_AFTER

-- Spells by a known id (TBC's top ranks; names come from GetSpellInfo, and a lower rank counts as known by name).
-- st1..st3: the stances (GetShapeshiftForm 1 Battle, 2 Defensive, 3 Berserker); tm: Tactical Mastery.
local IDS = {
    hs = 29707, cleave = 25231, bt = 30335, ms = 30330, ww = 1680, slam = 25242, exe = 25236, rampage = 30033,
    shout = 2048, brage = 2687, ham = 25212, op = 11585, flurry = 12974, sweep = 12328, rend = 25208,
    st1 = 2457, st2 = 71, st3 = 2458, tm = 12295,
}
War.IDS = IDS
local ICONS = {
    hs = "Interface\\Icons\\Ability_Rogue_Ambush", cleave = "Interface\\Icons\\Ability_Warrior_Cleave",
    bt = "Interface\\Icons\\Spell_Nature_BloodLust", ms = "Interface\\Icons\\Ability_Warrior_SavageBlow",
    ww = "Interface\\Icons\\Ability_Whirlwind", slam = "Interface\\Icons\\Ability_Warrior_DecisiveStrike",
    exe = "Interface\\Icons\\INV_Sword_48", rampage = "Interface\\Icons\\Ability_Warrior_Rampage",
    shout = "Interface\\Icons\\Ability_Warrior_BattleShout", brage = "Interface\\Icons\\Ability_Racial_BloodRage",
    ham = "Interface\\Icons\\Ability_ShockWave", op = "Interface\\Icons\\Ability_MeleeDamage",
    sweep = "Interface\\Icons\\Ability_Rogue_SliceDice", rend = "Interface\\Icons\\Ability_Gouge",
    st1 = "Interface\\Icons\\Ability_Warrior_OffensiveStance", st2 = "Interface\\Icons\\Ability_Warrior_DefensiveStance",
    st3 = "Interface\\Icons\\Ability_Racial_Avatar",
    wait = "Interface\\Icons\\INV_Misc_PocketWatch_01",
}
-- Rage costs (TBC, talents ignored: a cost only decides whether a press waits for the next swing's rage)
local COST = { hs = 15, cleave = 20, bt = 30, ms = 30, ww = 25, slam = 15, exe = 15, rampage = 20, shout = 10,
               ham = 10, op = 5, brage = 0, sweep = 30, rend = 10 }
War.COST = COST
-- Stances a press needs (GetShapeshiftForm: 1 Battle, 2 Defensive, 3 Berserker; the TBC tooltips); nil = any
local STANCE = { ww = { [3] = true }, op = { [1] = true }, exe = { [1] = true, [3] = true },
                 ham = { [1] = true, [3] = true }, sweep = { [1] = true, [3] = true }, rend = { [1] = true, [2] = true } }
War.STANCE = STANCE
-- (Sweeping Strikes has no GCD in WoWSims' warrior, sim/warrior/talents_fury.go)
local OFF_GCD = { brage = true, sweep = true }
-- Cooldowns the plan keeps (s): Sweeping Strikes 30, Overpower 5 (the TBC tooltips)
local CD = { bt = 6, ms = 6, ww = 10, sweep = 30, op = 5 }
local OP_WINDOW = 5              -- Overpower is usable this long after the target dodges (WoWSims overpower.go)
local SWAP_KEEP = 10             -- rage a stance swap keeps, + 5 per point of Tactical Mastery (WoWSims stances.go)
War.OP_WINDOW, War.SWAP_KEEP = OP_WINDOW, SWAP_KEEP

local names = {}
local function NameOf(key)
    if not names[key] and GetSpellInfo and IDS[key] then names[key] = GetSpellInfo(IDS[key]) end
    return names[key]
end
War.NameOf = NameOf
War.ICONS = setmetatable({}, { __index = function(_, key)
    local tex = IDS[key] and GetSpellTexture and GetSpellTexture(IDS[key])
    return tex or ICONS[key]
end })

-- ---------------------------------------------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------------------------------------------
local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting("war." .. path)
    if v == nil then return default end
    return v
end
War.Get = Get

function War:IsEnabled() return Get("enabled", false) and true or false end

-- A class tool for Arms and Fury (a warrior with no talent points yet gets it too). Its Settings card comes from
-- UI/WarriorSwingHUD.lua.
ns.ClassKit:Register({ key = "war", label = "Swing timer", class = "WARRIOR", specs = { "Arms", "Fury" }, order = 20,
    icon = IDS.hs, fallback = function() return true end })

function War:IsMine() return ns.ClassKit:IsMine("war") end
function War:IsDemo() return ns.ClassKit:IsDemo("war") end   -- (its part picked on the Demo page)
local function DemoPlaying() return ns.Demo and ns.Demo.IsPlaying and ns.Demo:IsPlaying("war") or false end

-- Situations (Core/Situation.lua): a pack from 2 (Cleave and Sweeping Strikes each hit one more), within 10 yards,
-- counted from the plates and from what Whirlwind, Cleave and Sweeping Strikes' extra hits (12723) hit; a player.
ns.Situation:Register("war", { kinds = { pack = true, player = true }, packFrom = 2, reach = "10", melee = IDS.ham,
    aoe = { IDS.ww, IDS.cleave, 12723 }, active = function() return War.active and true or false end })

-- "fury" | "arms": the talents' spec; demo mode on another class plays Fury (both hands, so every part shows).
function War:Spec()
    local _, cls = UnitClass("player")
    if cls == "WARRIOR" then
        for _, s in ipairs(ns.ClassKit:MySpecs()) do
            if s == "Arms" then return "arms" end
            if s == "Fury" then return "fury" end
        end
    end
    return "fury"
end

-- ---------------------------------------------------------------------------------------------------------------
-- Latency (as the other timers: world latency averaged with the measured press -> server delay)
-- ---------------------------------------------------------------------------------------------------------------
local measured
local sentAt = {}

function War:Latency()
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

function War:LatencyInfo()
    local world
    if GetNetStats then
        local _, _, home, w = GetNetStats()
        world = tonumber(w) or tonumber(home)
    end
    return world, measured and floor(measured * 1000 + 0.5), self:Latency()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Live state
-- ---------------------------------------------------------------------------------------------------------------
local state = {
    mhLast = nil, mhSpeed = 2.6,     -- the main hand's last swing (GetTime()) and speed (hasted)
    ohLast = nil, ohSpeed = nil,     -- the off hand's (nil speed: no off-hand weapon)
    hsAt = nil,                      -- the last Heroic Strike / Cleave that landed
    extraAt = nil,
}
War.state = state

-- Demo mode: a made-up Fury warrior, 2.6 / 2.6 swords, rage from the swings, a bot pressing what the plan says.
local DEMO_SPEED = 2.6
local DEMO_REACTION = 0.2
local demo                           -- { rage, gcd, ready = {}, queued, shout, rampage, n } while demo mode runs

local function Speeds()
    if demo then return DEMO_SPEED, DEMO_SPEED end
    if UnitAttackSpeed then
        local mh, oh = UnitAttackSpeed("player")
        mh, oh = tonumber(mh), tonumber(oh)
        if mh and mh > 0 then return mh, (oh and oh > 0) and oh or nil end
    end
    return state.mhSpeed, state.ohSpeed
end

local function Next(last, speed, now)
    if not last then return now + speed end
    local nxt = last + speed
    while nxt < now - 0.2 do nxt = nxt + speed end     -- missed events (out of range): keep the rhythm
    return nxt
end

function War:NextMH(now) return Next(state.mhLast, state.mhSpeed, now or GetTime()) end
function War:NextOH(now)
    if not state.ohSpeed then return nil end
    return Next(state.ohLast or state.mhLast, state.ohSpeed, now or GetTime())
end

local function Rage()
    if demo then return demo.rage end
    return UnitPower and (tonumber(UnitPower("player", 1)) or 0) or 0
end

local function Stance()
    if demo then return 3 end
    return GetShapeshiftForm and (tonumber(GetShapeshiftForm()) or 0) or 0
end

-- Points in Tactical Mastery (read once per talent change: CLASSKIT_CHANGED forgets it).
local tmRank
local function TacticalMastery()
    if demo then return 0 end
    if tmRank then return tmRank end
    tmRank = 0
    local want = GetSpellInfo and GetSpellInfo(IDS.tm)
    if want and GetNumTalentTabs and GetNumTalents and GetTalentInfo then
        for tab = 1, tonumber(GetNumTalentTabs()) or 0 do
            for i = 1, tonumber(GetNumTalents(tab)) or 0 do
                local n, _, _, _, rank = GetTalentInfo(tab, i)
                if n == want then tmRank = tonumber(rank) or 0 return tmRank end
            end
        end
    end
    return tmRank
end
War.TacticalMastery = TacticalMastery

-- Seconds left on a debuff of this name on the target, anyone's (0 = not on).
local function TargetDebuffLeft(key, now)
    if demo then return max(0, (demo[key] or 0) - now) end
    local n = NameOf(key)
    if not n or not UnitDebuff or not (UnitExists and UnitExists("target")) then return 0 end
    for i = 1, 40 do
        local dn, _, _, _, _, expires = UnitDebuff("target", i)
        if not dn then break end
        if dn == n then
            expires = tonumber(expires) or 0
            return expires > 0 and max(0, expires - now) or huge
        end
    end
    return 0
end
War.TargetDebuffLeft = TargetDebuffLeft

local function ExecutePhase()
    if demo then return false end
    if not (UnitExists and UnitExists("target")) or (UnitIsDead and UnitIsDead("target")) then return false end
    local hp, mx = tonumber(UnitHealth("target")) or 0, tonumber(UnitHealthMax("target")) or 0
    return mx > 0 and hp / mx < 0.2
end

-- In the spellbook (any rank: by id, else by name, which a client only answers for spells the character has).
local function Known(key)
    if demo then return key ~= "slam" and key ~= "ms" and key ~= "op" end
    local id = IDS[key]
    if id and IsPlayerSpell and IsPlayerSpell(id) then return true end
    if id and IsSpellKnown and IsSpellKnown(id) then return true end
    local n = NameOf(key)
    return n ~= nil and GetSpellCooldown ~= nil and GetSpellCooldown(n) ~= nil and IsUsableSpell ~= nil
        and IsUsableSpell(n) ~= nil
end
War.Known = Known

local function GcdLeft(now)
    if demo then return max(0, demo.gcd - now) end
    local n = NameOf("shout") or NameOf("ham")
    if not n or not GetSpellCooldown then return 0 end
    local s, d = GetSpellCooldown(n)
    s, d = tonumber(s) or 0, tonumber(d) or 0
    if s == 0 or d > GCD + 0.01 then return 0 end
    return max(0, s + d - now)
end

local function CdLeft(key, now)
    if demo then return max(0, (demo.ready[key] or 0) - now) end
    local n = NameOf(key)
    if not n or not GetSpellCooldown then return 0 end
    local s, d = GetSpellCooldown(n)
    s, d = tonumber(s) or 0, tonumber(d) or 0
    if s == 0 or d <= GCD + 0.01 then return 0 end     -- a GCD is not the spell's own cooldown
    return max(0, s + d - now)
end

-- Seconds left on a buff of ours by spell key (0 = not on).
local function BuffLeft(key, now)
    if demo then return max(0, (demo[key] or 0) - now) end
    local n = NameOf(key)
    if not n or not UnitBuff then return 0 end
    for i = 1, 40 do
        local bn, _, _, _, _, expires = UnitBuff("player", i)
        if not bn then break end
        if bn == n then
            expires = tonumber(expires) or 0
            return expires > 0 and max(0, expires - now) or huge
        end
    end
    return 0
end

War.BuffLeft = BuffLeft

-- While resting: is there an off hand, the rage, the Heroic Strike line.
function War:RestInfo()
    local mh, oh = Speeds()
    return { oh = oh ~= nil, rage = Rage(), line = self:Line(self:Spec(), oh == nil) }
end

-- Heroic Strike / Cleave queued on the next swing (the client marks the queued spell current).
local function Queued()
    if demo then return demo.queued end
    if not IsCurrentSpell then return nil end
    for _, k in ipairs({ "hs", "cleave" }) do
        local n = NameOf(k)
        if n and IsCurrentSpell(n) then return k end
    end
    return nil
end

local function Usable(key)
    if demo then return true end
    local n = NameOf(key)
    if not n or not IsUsableSpell then return false end
    return IsUsableSpell(n) and true or false
end

-- The Heroic Strike line: the setting, else WoWSims' (two-handed Arms 80, everyone else 40).
function War:Line(spec, twoHand)
    local v = tonumber(Get("hsLine", 0)) or 0
    if v > 0 then return v end
    if spec == "arms" and twoHand then return 80 end
    return 40
end

-- The presses each situation may use (Core/Situation.lua), and their switches: one target war.use.<key> (as before),
-- a pack war.pack.<key> (WoWSims' multi-target list), a player war.player.<key> (Slam and Rend off). Presses not in
-- a situation's list keep the one-target switch (Bloodthirst, Rampage, Battle Shout, Bloodrage).
local PACK_KEYS = { sweep = true, ww = true, slam = true, ms = true, exe = true, cleave = true }
local PLAYER_KEYS = { ham = true, ms = true, op = true, ww = true, exe = true, hs = true, slam = true, rend = true }
local ONLY_IN = { sweep = "pack", cleave = "pack", op = "player", rend = "player" }
local ALL_KEYS = { "bt", "ms", "ww", "slam", "exe", "rampage", "shout", "brage", "ham", "hs", "sweep", "cleave", "op", "rend" }
War.PACK_KEYS, War.PLAYER_KEYS = PACK_KEYS, PLAYER_KEYS

function War.UseFor(kind, k)
    if kind == "pack" and PACK_KEYS[k] then return Get("pack." .. k, true) and true or false end
    if kind == "player" and PLAYER_KEYS[k] then return Get("player." .. k, k ~= "slam" and k ~= "rend") and true or false end
    if ONLY_IN[k] then return false end
    return Get("use." .. k, k ~= "ham") and true or false
end

-- The rotation's input, from the live client.
function War:Snapshot(now)
    now = now or GetTime()
    local mhs, ohs = Speeds()
    state.mhSpeed, state.ohSpeed = mhs, ohs
    local spec = self:Spec()
    local twoHand = ohs == nil
    local rage = Rage()
    local stance = Stance()
    local sit = ns.Situation:Info("war", now)
    local kind = sit.kind
    -- crowd control in reach: nothing that hits more than the target (Whirlwind, Cleave, Sweeping Strikes)
    local held = sit.held ~= nil
    local use = {}
    for _, k in ipairs(ALL_KEYS) do use[k] = War.UseFor(kind, k) and Known(k) or false end
    if held then use.ww, use.sweep, use.cleave = false, false, false end
    local danceMode = Get("dance", "players")
    local ready = {}
    for _, k in ipairs({ "bt", "ms", "ww", "brage", "sweep", "op" }) do ready[k] = now + CdLeft(k, now) end
    local line = self:Line(spec, twoHand)
    if kind == "pack" and not held then line = tonumber(Get("cleaveLine", 40)) or 40
    elseif kind == "player" then
        local pl = tonumber(Get("hsLinePlayer", 0)) or 0
        if pl > 0 then line = pl end
    end
    return {
        now = now, spec = spec, twoHand = twoHand, rage = rage, line = line, stance = stance,
        kind = kind, held = held, sit = sit, lampKey = (kind == "pack" and not held) and "cleave" or "hs",
        dance = danceMode == "always" or (danceMode == "players" and kind == "player"),
        keep = SWAP_KEEP + 5 * TacticalMastery(), danceRage = tonumber(Get("danceRage", 10)) or 10,
        hamLeft = TargetDebuffLeft("ham", now), hamRefresh = tonumber(Get("hamRefresh", 2)) or 2,
        rendLeft = TargetDebuffLeft("rend", now), opUntil = (demo and demo.opUntil) or state.opUntil or 0,
        mhNext = self:NextMH(now), mhLast = state.mhLast, mhSpeed = mhs,
        ohNext = self:NextOH(now), ohLast = state.ohLast, ohSpeed = ohs,
        lat = self:Latency(),
        gcdReady = now + GcdLeft(now), gcd = GCD, ready = ready, use = use, exec = ExecutePhase(),
        queued = Queued(), shoutLeft = BuffLeft("shout", now), rampageLeft = BuffLeft("rampage", now),
        rampageUsable = use.rampage and Usable("rampage"),
        slamCast = (demo and 0.5) or (GetSpellInfo and IDS.slam and (select(4, GetSpellInfo(IDS.slam)) or 1500) / 1000) or 1.5,
        gainMH = tonumber(Get("gainMH", 14)) or 14, gainOH = ohs and (tonumber(Get("gainOH", 7)) or 7) or 0,
    }
end

-- ---------------------------------------------------------------------------------------------------------------
-- The rotation: WoWSims' TBC warrior APLs (Data/SimAPL.lua), the presses a player makes by hand, in order.
--   Fury:  Bloodthirst; Whirlwind when Bloodthirst is 1.5 s or more away (Berserker stance); Execute under 20%;
--          Rampage when it is usable and running out; Battle Shout with 10 s or less left; Hamstring over 60 rage
--          (weaving, off by default: it only pays with Sword Specialization / Windfury).
--   Arms:  Slam right after the main-hand swing (two-hander: within latency + 0.3 s, at least 0.5 s of swing left);
--          Mortal Strike; Whirlwind; Execute under 20%; Battle Shout; Hamstring as above.
--   Bloodrage (off the GCD) under 90 rage. Heroic Strike: the lamp (see the header).
-- A pack (Core/Situation.lua): the APLs' own branch for more than one target ("numberTargets > 1"): Sweeping
--   Strikes on cooldown (off the GCD, when talented), Whirlwind first, then as above without Whirlwind's wait for
--   Bloodthirst; the lamp offers Cleave from war.cleaveLine (WoWSims: 40 rage for every spec) instead of Heroic Strike.
-- A player (ours, from the TBC tooltips; WoWSims has nothing for players): Hamstring kept on the target (50% slower
--   for 15 s: again war.hamRefresh s before it ends), Overpower in the 5 s after the target dodges, Mortal Strike /
--   Bloodthirst, Whirlwind, Execute, Rend when it is off the target (opt-in), Slam (opt-in: a cast, you stand still).
-- Held (crowd control in reach): Whirlwind, Cleave and Sweeping Strikes are left out (Snapshot).
-- Stances: a press only in its stance, unless stance dancing is on for the situation (war.dance): then the press
--   carries the stance to go to (st.stance, 1 Battle / 2 Defensive / 3 Berserker), as long as the swap keeps the rage
--   it costs and throws away no more than war.danceRage (a swap keeps 10 rage, +5 per point of Tactical Mastery).
-- Rage is played forward roughly (each swing before a press brings gainMH / gainOH, each press costs its rage), only
-- to decide whether a press waits for the next swing. Run(snap) returns steps = { { key, at, off, cast, stance } }
-- (the first at or before now is the press to make) and lamp = "queue" | "queued" | "hold" | nil (no Heroic Strike).
-- ---------------------------------------------------------------------------------------------------------------
local function Priority(spec, twoHand, kind)
    if kind == "pack" then
        if spec == "arms" then
            if twoHand then return { "ww", "slam", "ms", "exe", "rampage", "shout" } end
            return { "ww", "ms", "exe", "rampage", "shout" }
        end
        return { "ww", "bt", "exe", "rampage", "shout", "ham" }
    elseif kind == "player" then
        if spec == "arms" then return { "ham", "op", "ms", "ww", "exe", "rend", "slam", "rampage", "shout" } end
        return { "ham", "op", "bt", "ww", "exe", "rend", "rampage", "shout" }
    end
    if spec == "arms" then
        if twoHand then return { "slam", "ms", "ww", "exe", "rampage", "shout", "ham" } end
        return { "ms", "ww", "exe", "rampage", "shout", "ham" }
    end
    return { "bt", "ww", "exe", "rampage", "shout", "ham" }
end
War.Priority = Priority

function War.Lamp(snap)
    if snap.queued then return "queued" end
    local k = snap.lampKey or "hs"
    if not snap.use[k] then return nil end
    if k == "hs" and snap.exec and snap.use.exe then return "hold" end
    return snap.rage >= snap.line and "queue" or "hold"
end

-- The stance a press needs from `stance`: nil (fine as it is), the stance to go to, or false (not now).
local function StanceFor(snap, k, stance, rage)
    local need = STANCE[k]
    if not need or need[stance] then return nil end
    if not snap.dance then return false end
    local keep = snap.keep or SWAP_KEEP
    if rage - keep > (snap.danceRage or 0) or keep < (COST[k] or 0) then return false end
    return need[3] and 3 or (need[1] and 1 or 2)
end
War.StanceFor = StanceFor

function War.Run(snap, count)
    count = count or 3
    local now, lat = snap.now, snap.lat
    local use, rd = snap.use, {}
    for k, v in pairs(snap.ready) do rd[k] = v end
    local rage, gcd = snap.rage, snap.gcdReady
    local mh, oh = snap.mhNext, snap.ohNext
    local shoutLeft = snap.shoutLeft
    local kind = snap.kind or "single"
    local stance = snap.stance or 3
    local hamEnd = now + (snap.hamLeft or 0)
    local rendEnd = now + (snap.rendLeft or 0)
    local opUntil = snap.opUntil or 0
    local steps = {}
    -- the swings landing between two moments bring their rage (a queued Heroic Strike's swing brings none)
    local queued = snap.queued
    local function Swings(t0, t1)
        local got = 0
        while mh <= t1 do
            if mh > t0 then got = got + (queued and 0 or snap.gainMH) end
            queued = nil
            mh = mh + snap.mhSpeed
        end
        while oh and oh <= t1 do
            if oh > t0 then got = got + snap.gainOH end
            oh = oh + snap.ohSpeed
        end
        return got
    end
    -- off the GCD, now: Bloodrage under 90 rage; Sweeping Strikes in a pack
    local offs = 0
    if use.brage and rd.brage <= now + 0.001 and rage < 90 then
        steps[#steps + 1] = { key = "brage", at = now, off = true }
        offs = offs + 1
    end
    if use.sweep and (rd.sweep or now) <= now + 0.001 and rage >= COST.sweep then
        local to = StanceFor(snap, "sweep", stance, rage)
        if to ~= false then
            if to then rage, stance = min(rage, snap.keep or SWAP_KEEP), to end
            steps[#steps + 1] = { key = "sweep", at = now, off = true, stance = to }
            rage = rage - COST.sweep
            offs = offs + 1
        end
    end
    local list = Priority(snap.spec, snap.twoHand, kind)
    local t = max(now, gcd)
    rage = min(100, rage + Swings(now, t))
    for _ = 1, 24 do
        if #steps >= count + offs then break end
        local pick, pickAt, pickTo
        for _, k in ipairs(list) do
            if use[k] then
                local to = StanceFor(snap, k, stance, rage)
                local at
                if to == false then at = nil
                elseif k == "slam" then
                    -- right after a main-hand swing: this one if it just landed, else the next
                    local last = mh - snap.mhSpeed
                    if t <= last + lat + SLAM_AFTER and mh - t >= 0.5 then at = t else at = mh end
                elseif k == "bt" or k == "ms" then at = max(t, rd[k])
                elseif k == "ww" then
                    at = max(t, rd.ww)
                    -- (in a pack Whirlwind comes first; else it waits while Bloodthirst is back within 1.5 s)
                    if kind ~= "pack" and snap.spec == "fury" and use.bt and rd.bt - at < 1.5 then at = nil end
                elseif k == "exe" then at = snap.exec and t or nil
                elseif k == "rampage" then
                    at = (t <= now + 0.001 and snap.rampageUsable and snap.rampageLeft < 5) and t or nil
                elseif k == "shout" then at = (shoutLeft - (t - now) <= 10) and t or nil
                elseif k == "ham" then
                    if kind == "player" then at = max(t, hamEnd - (snap.hamRefresh or 2))
                    else at = (rage > 60) and t or nil end
                elseif k == "op" then
                    at = max(t, rd.op or t)
                    if at > opUntil - 0.05 then at = nil end
                elseif k == "rend" then at = max(t, rendEnd)
                end
                -- the earliest press wins; on a tie the higher in the list
                if at and (not pickAt or at < pickAt - 0.001) then pick, pickAt, pickTo = k, at, to end
                if pickAt and pickAt <= t + 0.001 then break end
            end
        end
        if not pick then break end
        -- not enough rage: it waits for the swings that bring it
        local at = pickAt
        local need = COST[pick] or 0
        local have = min(100, rage + Swings(t, at))
        local guard = 0
        while have < need and guard < 6 do
            local nt = min(mh, oh or huge) + 0.01
            have = min(100, have + Swings(at, nt))
            at, guard = nt, guard + 1
        end
        if pickTo then have, stance = min(have, snap.keep or SWAP_KEEP), pickTo end
        rage = have - need
        local st = { key = pick, at = at, stance = pickTo }
        if pick == "slam" then
            st.cast = snap.slamCast
            -- Slam restarts the swing at its end
            mh = at + lat + snap.slamCast + snap.mhSpeed
        end
        steps[#steps + 1] = st
        gcd = at + GCD
        if CD[pick] then rd[pick] = at + CD[pick] end
        if pick == "shout" then shoutLeft = 120 + (at - now)
        elseif pick == "ham" then hamEnd = at + 15
        elseif pick == "rend" then rendEnd = at + 21
        elseif pick == "op" then opUntil = 0 end
        t = max(gcd, at + (st.cast or 0))
        rage = min(100, rage + Swings(at, t))
    end
    return steps, War.Lamp(snap)
end

-- Is auto attack running? A swing seen within 1.6 swings; otherwise the HUD rests.
function War:IsSwinging(now)
    now = now or GetTime()
    if demo then return true end
    if not state.mhLast then return false end
    return now - max(state.mhLast, state.ohLast or 0) < state.mhSpeed * 1.6
end

local shown, shownAt = nil, 0
function War:MarkDirty() shownAt = 0 end

function War:Current()
    local now = GetTime()
    if not self:IsSwinging(now) then shown = nil return nil end
    if shown and now == shownAt then return shown end
    local snap = self:Snapshot(now)
    local steps, lamp = War.Run(snap)
    shownAt = now
    shown = { snap = snap, plan = { steps = steps }, lamp = lamp, lampKey = snap.lampKey, sit = snap.sit }
    return shown
end

-- ---------------------------------------------------------------------------------------------------------------
-- Combat log: swings, Heroic Strikes, the fight report
-- ---------------------------------------------------------------------------------------------------------------
local myGUID
local fight                      -- { start, mh, hs, capped, target }
local EXTRA_TTL = 0.04
local extraLeft, extraUntil = 0, 0

local function OnMH(now, isHS)
    state.mhLast = now
    if isHS then state.hsAt = now end
    if fight then
        fight.mh = fight.mh + 1
        if isHS then fight.hs = fight.hs + 1 end
        if Rage() >= 100 then fight.capped = fight.capped + 1 end
    end
    War:MarkDirty()
end
War.OnMH = OnMH

local function OnOH(now)
    state.ohLast = now
    War:MarkDirty()
end
War.OnOH = OnOH

-- (a Core/CombatLog.lua subscriber while the timer runs: the event name, then the client's payload)
-- The target dodged one of our attacks: Overpower is usable for OP_WINDOW s (SWING_MISSED: missType first;
-- SPELL_MISSED: after the spell id, name and school).
local function Dodged(dst, now)
    if dst and dst == (UnitGUID and UnitGUID("target")) then
        state.opUntil = now + OP_WINDOW
        War:MarkDirty()
    end
end

local function OnCombatLog(_, ts, sub, _, src, _, _, _, dst, _, _, _, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
    if src ~= myGUID or not War.active or demo then return end
    local now = GetTime()
    if sub == "SWING_MISSED" and a1 == "DODGE" then Dodged(dst, now)
    elseif sub == "SPELL_MISSED" and a4 == "DODGE" then Dodged(dst, now) end
    if sub == "SPELL_EXTRA_ATTACKS" then
        extraLeft, extraUntil = (tonumber(a4) or 1), ts + EXTRA_TTL
    elseif sub == "SWING_DAMAGE" or sub == "SWING_MISSED" then
        local off
        if sub == "SWING_DAMAGE" then off = a10 else off = a2 end
        if off then OnOH(now) return end
        if extraLeft > 0 and ts <= extraUntil then
            extraLeft = extraLeft - 1
            state.extraAt = now
        else
            extraLeft = 0
            OnMH(now)
        end
    elseif sub == "SPELL_DAMAGE" or sub == "SPELL_MISSED" then
        if a2 == NameOf("hs") or a2 == NameOf("cleave") or a1 == IDS.hs or a1 == IDS.cleave then
            -- (Cleave hits two targets: one swing)
            if not state.hsAt or now - state.hsAt > 0.05 then OnMH(now, true) end
        end
    end
end
War.OnCombatLog = OnCombatLog

local function StartFight()
    fight = { start = GetTime(), mh = 0, hs = 0, capped = 0, target = UnitName("target") }
end

local function EndFight()
    local f = fight
    fight = nil
    if not f or f.mh < 4 then return end
    local rep = { at = time and time() or 0, target = f.target, dur = GetTime() - f.start, mh = f.mh, hs = f.hs,
                  capped = f.capped }
    local list = Get("reports") or {}
    table.insert(list, 1, rep)
    while #list > REPORTS_MAX do table.remove(list) end
    ns.DB:SetSetting("war.reports", list)
    ns:Fire("WAR_REPORT", rep)
end
War.StartFight, War.EndFight = StartFight, EndFight

function War:Reports() return Get("reports") or {} end

local function SpellKey(spellArg)
    local id = tonumber(spellArg)
    local name = id and GetSpellInfo and GetSpellInfo(id) or spellArg
    for k, sid in pairs(IDS) do
        if (id and id == sid) or (name and NameOf(k) == name) then return k end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------------------------
local function Mine(unit) return unit == "player" and War.active and not demo end

function War:OnLogin()
    myGUID = UnitGUID("player")
    state.mhSpeed, state.ohSpeed = Speeds()
    ns:RegisterEvent("UNIT_SPELLCAST_SENT", function(_, unit, _, _, spellArg)
        if not Mine(unit) then return end
        local key = SpellKey(spellArg)
        if key then sentAt[key] = GetTime() end
    end)
    ns:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellArg)
        if not Mine(unit) then return end
        local key = SpellKey(spellArg)
        local now = GetTime()
        local sent = key and sentAt[key]
        if sent and now - sent < 1.0 and key ~= "hs" and key ~= "cleave" then
            local d = now - sent
            measured = measured and (measured * 0.8 + d * 0.2) or d
        end
        if key then sentAt[key] = nil end
        if key == "slam" then state.mhLast = now end      -- Slam restarts the swing
        if key == "op" then state.opUntil = 0 end
        War:MarkDirty()
    end)
    ns:RegisterEvent("UNIT_ATTACK_SPEED", function(_, unit)
        if unit ~= "player" or demo then return end
        local now = GetTime()
        local mh, oh = Speeds()
        -- haste mid-swing scales what is left of each swing
        if state.mhLast and state.mhSpeed and mh ~= state.mhSpeed then
            local left = state.mhLast + state.mhSpeed - now
            if left > 0 then state.mhLast = now + left * mh / state.mhSpeed - mh end
        end
        if state.ohLast and state.ohSpeed and oh and oh ~= state.ohSpeed then
            local left = state.ohLast + state.ohSpeed - now
            if left > 0 then state.ohLast = now + left * oh / state.ohSpeed - oh end
        end
        state.mhSpeed, state.ohSpeed = mh, oh
    end)
    ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function(_, slot)
        if slot == 16 or slot == 17 then
            state.mhSpeed, state.ohSpeed = Speeds()
            if not state.ohSpeed then state.ohLast = nil end
            War:MarkDirty()
        end
    end)
    ns:RegisterEvent("UNIT_POWER_FREQUENT", function(_, unit)
        if unit == "player" and War.active then War:MarkDirty() end
    end)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if War.active then StartFight() end
    end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if fight then EndFight() end
    end)
    ns:On("CLASSKIT_CHANGED", function() tmRank = nil; War:Refresh() end)
    ns:On("SITUATION_LOCK", function() War:MarkDirty() end)
    ns:RegisterEvent("SPELLS_CHANGED", function() for k in pairs(names) do names[k] = nil end end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:find("^war%.") and path ~= "war.reports" then War:Refresh() end
    end)
    self:Refresh()
end

-- Demo mode: made-up 2.6 / 2.6 swings (the off hand half a swing behind), rage from each hit, Heroic Strike queued
-- whenever the lamp says so, and a bot pressing what the plan says a reaction time after it is due (nothing is cast),
-- so the whole ring plays for anyone, anywhere.
local demoDriver
local function DemoSwings(on)
    if on and not demo then
        local now = GetTime()
        demo = { rage = 35, gcd = 0, ready = {}, queued = nil, shout = now + 90, rampage = now + 25, n = 0 }
        state.mhSpeed, state.ohSpeed = DEMO_SPEED, DEMO_SPEED
        state.mhLast, state.ohLast = now, now - DEMO_SPEED / 2
        demoDriver = demoDriver or CreateFrame("Frame")
        demoDriver:SetScript("OnUpdate", function()
            local t = GetTime()
            if t >= state.mhLast + state.mhSpeed then
                local hs = demo.queued ~= nil
                if hs then demo.queued = nil
                else demo.rage = min(100, demo.rage + 14) end
                OnMH(state.mhLast + state.mhSpeed, hs)
            end
            if t >= state.ohLast + state.ohSpeed then
                demo.rage = min(100, demo.rage + 7)
                OnOH(state.ohLast + state.ohSpeed)
            end
            local cur = War:Current()
            if not cur then return end
            -- Heroic Strike (Cleave in a pack): queued once the main hand is in its last stretch and the lamp says so
            local lk = cur.lampKey or "hs"
            if cur.lamp == "queue" and state.mhLast + state.mhSpeed - t < HS_WINDOW and demo.rage >= COST[lk] then
                demo.queued = lk
                demo.rage = demo.rage - COST[lk]
                War:MarkDirty()
            end
            local st = cur.plan.steps[1]
            local due = st and st.at <= t + 0.001
            if due and demo.dueKey ~= st.key then demo.dueKey, demo.dueAt = st.key, t end
            if not due then demo.dueKey = nil end
            if due and t - demo.dueAt >= DEMO_REACTION then
                demo.dueKey = nil
                if st.key == "brage" then
                    demo.ready.brage, demo.rage = t + 60, min(100, demo.rage + 10)
                elseif demo.rage >= (COST[st.key] or 0) then
                    demo.rage = demo.rage - (COST[st.key] or 0)
                    if not OFF_GCD[st.key] then demo.gcd = t + GCD end
                    if CD[st.key] then demo.ready[st.key] = t + CD[st.key] end
                    if st.key == "shout" then demo.shout = t + 120
                    elseif st.key == "rampage" then demo.rampage = t + 30
                    elseif st.key == "ham" then demo.ham = t + 15
                    elseif st.key == "rend" then demo.rend = t + 21
                    elseif st.key == "op" then demo.opUntil = 0 end
                end
                War:MarkDirty()
            end
        end)
        demoDriver:Show()
    elseif not on and demo then
        demo = nil
        if demoDriver then demoDriver:Hide() end
        state.mhLast, state.ohLast = nil, nil
        state.mhSpeed, state.ohSpeed = Speeds()
    end
end
War.DemoState = function() return demo end

function War:Refresh()
    -- (off until switched on; its demo shows it while the demo's pull plays)
    local demo = DemoPlaying()
    self.active = self:IsMine() and (self:IsEnabled() or demo)
    DemoSwings(self.active and demo)
    CL:SetSubscribed("war", OnCombatLog, self.active and not demo)
    ns:Fire("WAR_STATE", self.active)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Slash: /dz war [on | off | move | report]
-- ---------------------------------------------------------------------------------------------------------------
ns:RegisterSlash("war", function(rest)
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "on" or rest == "off" then
        ns.DB:SetSetting("war.enabled", rest == "on")
        ns:Print("Warrior swing timer %s.", rest == "on" and "on" or "off")
    elseif rest == "move" or rest == "unlock" then
        if ns.EditMode then ns.EditMode:Open() end
    elseif rest == "report" then
        local r = War:Reports()[1]
        if not r then ns:Print("No fight recorded yet.") return end
        ns:Print("%s (%ds): %d main-hand swings, %d Heroic Strikes, %d swings at full rage.",
            r.target or "Last fight", floor(r.dur or 0), r.mh or 0, r.hs or 0, r.capped or 0)
    else
        local world, meas, used = War:LatencyInfo()
        ns:Print("Warrior swing timer is %s%s. Latency: world %s ms, measured %s ms, using %d ms.",
            War:IsEnabled() and "on" or "off", War.active and "" or " (not an Arms or Fury warrior)",
            tostring(world or "?"), tostring(meas or "-"), floor((used or 0) * 1000 + 0.5))
        ns:Print("/dz war on | off | move | report")
    end
end, "Swing timer for Arms and Fury warriors (on | off | move | report)")
