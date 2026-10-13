if DisasterZoneBoot and DisasterZoneBoot.Run("Core/CombatText.lua", ...) then return end -- DisasterZone Core/CombatText.lua
-- Combat text (ns.CombatText): reads the combat log (Core/CombatLog.lua) while combat text is turned on (Settings >
-- UI > Combat text, ui.sct.on: off by default, and only that switch turns it on), and turns what happens to me and
-- my pet into the stage's events (UI/CombatText.lua):
--   out    my hits and my pet's (and my heals on others), with crit, school, icon, overkill; hits of one
--          spell within MERGE s on one mob (or at the target spot) join as a "multi" group (Windfury's extra swing is
--          named: "Melee + Windfury"); ticks (periodic damage and the ground spells of GROUND) join as a "tick" group
--   miss   my misses on a mob (Dodge, Parry ...), and a hit on me that missed (mine = true)
--   taken  hits on me (partial resists say how much); heal: heals on me with the healer (effective healing only)
--   proc   a buff I gain in combat that lasts a minute or less (my own long buffs, seals, are left out)
--   alert  a reactive spell I know becomes usable in combat (Hammer of Wrath, Execute, Overpower, Revenge ...)
--   lowhp  my health under 35% (mana under 25%) in combat, again only after it went back over 50%
-- ev.peak: my biggest hit of the fight so far (Slate's hairlines are measured against it).
-- Options (ui.sct.*): on, place plate | columns, size, hideGame (the game's own damage and healing numbers off while
-- ours are on; put back as they were), taken, heals, procs, alerts, lowHealth, merge theme | on | off (theme: every
-- look but Classic), autoAttacks, minHit, minHeal.
local addonName, ns = ...

local CTE = ns:NewModule("CombatText")

local floor, max, min, band = math.floor, math.max, math.min, bit and bit.band
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring

local MERGE = 0.12          -- s a hit waits for others of its spell to join it
local STAGGER = 0.06        -- s between the hits of a group as they are handed on (they count up as in the mockup)
CTE.MERGE = MERGE

local function UIx() return ns.CombatTextUI end
local function Opt(key, default) return ns.Look and ns.Look:Opt("sct", key, default) end
local function Now() return GetTime() end
local function InCombat()
    return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
end

-- Spell schools (combat log bit masks) -> the looks' colour keys.
local SCHOOL = { [1] = "phys", [2] = "holy", [4] = "fire", [8] = "nature", [16] = "frost", [32] = "shadow", [64] = "arcane" }
local function School(mask)
    mask = tonumber(mask) or 1
    if SCHOOL[mask] then return SCHOOL[mask] end
    for _, b in ipairs({ 2, 4, 8, 16, 32, 64 }) do
        if band and band(mask, b) ~= 0 then return SCHOOL[b] end
    end
    return "phys"
end
CTE.School = School

-- Ground spells whose hits come one a second without a cast: they count up in place like ticks.
local GROUND = { 26573, 1949, 5740, 10, 16914, 1510, 1543, 13812, 2120, 32736 }
-- Reactive spells: alert when they light up.
local REACTIVE = { 24275, 24274, 24239, 27180, 5308, 20658, 20660, 20661, 20662, 25234, 25236, 7384, 7887, 11584, 11585,
                   6572, 6574, 7379, 11600, 11601, 25288, 25269, 30357, 34428, 14251, 19306, 20909, 20910, 27067, 34026,
                   1495, 14269, 14270, 14271, 36916 }
local MELEE_ICON = "Interface\\Icons\\INV_Sword_04"
local MISS = { DODGE = "Dodge", PARRY = "Parry", MISS = "Miss", BLOCK = "Block", RESIST = "Resist", ABSORB = "Absorb",
               IMMUNE = "Immune", EVADE = "Evade", DEFLECT = "Deflect", REFLECT = "Reflect" }
CTE.MISS = MISS

local me, pet
local ground = {}           -- [spell name] = true
local reactive = {}         -- [spell name] = icon (known ones)
local wasUsable = {}
local pending = {}          -- [merge key] = { hits, timer }
local extra = nil           -- { name, untilT }: an extra attack (Windfury) is coming
local fight = nil
local low = { hp = false, mana = false }
local lastProc = {}

---------------------------------------------------------------------------
-- Settings and the switch
---------------------------------------------------------------------------

function CTE:IsOn()
    local ui = UIx()
    return ui and ui:IsOn() or false
end

function CTE:Merging()
    local m = Opt("merge", "theme")
    if m == "on" then return true elseif m == "off" then return false end
    local ui = UIx()
    return not (ui and ui:LookKey() == "classic")
end

---------------------------------------------------------------------------
-- Handing events on
---------------------------------------------------------------------------

local function Emit(ev)
    local ui = UIx()
    if ui then ui:Emit(ev) end
end

local function Later(delay, ev)
    local ui = UIx()
    if not ui then return end
    if delay <= 0 then ui:Emit(ev) else ui.st:Queue(delay, ev) end
end

local function Flush(key)
    local p = pending[key]
    pending[key] = nil
    if not p then return end
    local hits = p.hits
    if #hits == 1 then
        Emit(hits[1])
        return
    end
    local gkey = "m:" .. key .. ":" .. tostring(p.t0)
    local named = hits[1].spell
    for i, ev in ipairs(hits) do
        ev.group, ev.gkey = "multi", gkey
        if i > 1 and ev.extra then named = (hits[1].spell or "") .. " + " .. ev.extra
        elseif i > 1 and ev.spell ~= hits[1].spell then named = (hits[1].spell or "") .. " + " .. (ev.spell or "") end
        ev.gname = named
        Later((i - 1) * STAGGER, ev)
    end
end

local function Buffer(key, ev)
    local p = pending[key]
    if p then
        p.hits[#p.hits + 1] = ev
        return
    end
    p = { hits = { ev }, t0 = Now() }
    pending[key] = p
    if C_Timer and C_Timer.After then C_Timer.After(MERGE, function() Flush(key) end) else Flush(key) end
end
CTE._Flush = Flush

local function Icon(spellId, spellName)
    local tex
    if spellId and spellId ~= 0 and GetSpellTexture then tex = GetSpellTexture(spellId) end
    if not tex and spellName and GetSpellTexture then tex = GetSpellTexture(spellName) end
    return tex
end

local function ShortName(name)
    if type(name) ~= "string" then return nil end
    return (name:match("^([^%-]+)")) or name
end

local function ClassOf(guid)
    if not (guid and GetPlayerInfoByGUID) then return nil end
    local ok, _, cls = pcall(GetPlayerInfoByGUID, guid)
    if ok then return cls end
    return nil
end

---------------------------------------------------------------------------
-- The combat log
---------------------------------------------------------------------------

local DAMAGE = { SWING_DAMAGE = 1, RANGE_DAMAGE = 2, SPELL_DAMAGE = 2, SPELL_PERIODIC_DAMAGE = 2, DAMAGE_SHIELD = 2,
                 DAMAGE_SPLIT = 2, SPELL_BUILDING_DAMAGE = 2, ENVIRONMENTAL_DAMAGE = 3 }
local MISSED = { SWING_MISSED = 1, RANGE_MISSED = 2, SPELL_MISSED = 2, SPELL_PERIODIC_MISSED = 2, DAMAGE_SHIELD_MISSED = 2 }
local HEALS = { SPELL_HEAL = true, SPELL_PERIODIC_HEAL = true }

-- The fight's biggest hit so far (a new fight starts when combat does).
local function Fight()
    if not fight and InCombat() then fight = { peak = 0 } end
    return fight
end

local function OutHit(sub, src, dst, spellId, spellName, school, amt, overkill, resisted, crit)
    local isPet = src ~= me
    local swing = sub == "SWING_DAMAGE"
    if swing then
        if not Opt("autoAttacks", true) then return end
        spellName = isPet and "Pet" or "Melee"
    end
    local f = Fight()
    if f and amt > f.peak then f.peak = amt end
    local minHit = tonumber(Opt("minHit", 0)) or 0
    if amt < minHit and not crit then return end
    local ev = { k = "out", amt = amt, spell = spellName, school = swing and "phys" or School(school),
                 icon = (not swing) and Icon(spellId, spellName) or nil, crit = crit and true or nil, dst = dst,
                 pet = isPet or nil, peak = f and f.peak or amt }
    if overkill and overkill > 0 then ev.overkill = overkill end
    local merging = CTE:Merging()
    local periodic = sub == "SPELL_PERIODIC_DAMAGE"
    local ui = UIx()
    if merging and (periodic or ground[spellName]) then
        ev.k, ev.group = "tick", "tick"
        ev.hold = periodic and 3.4 or 1.4
        local on = ui and ui:Mode() == "plate" and ui.plates[dst] and dst or "spot"
        ev.gkey = "t:" .. tostring(spellName) .. ":" .. tostring(on)
        Emit(ev)
        return
    end
    if not merging then Emit(ev) return end
    if swing and extra and Now() <= extra.untilT then ev.extra = extra.name; extra = nil end
    local on = ui and ui:Mode() == "plate" and ui.plates[dst] and dst or "spot"
    Buffer((swing and (isPet and "pet" or "melee") or tostring(spellName)) .. ":" .. tostring(on), ev)
end

local function OnCLEU(_, _, sub, _, src, srcName, _, _, dst, _, _, _, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22)
    if not me then me = UnitGUID and UnitGUID("player") end
    local mine = src == me or (pet and src == pet)
    local onMe = dst == me
    if not mine and not onMe then return end
    local d = DAMAGE[sub]
    if d then
        local spellId, spellName, school, amt, overkill, resisted, crit
        if d == 1 then
            amt, overkill, school, resisted, crit = a12, a13, a14, a15, a18
        elseif d == 2 then
            spellId, spellName, school, amt, overkill, resisted, crit = a12, a13, a14, a15, a16, a18, a21
        else
            spellName, amt, overkill, school, resisted, crit = a12, a13, a14, a15, a16, a19
            spellName = type(spellName) == "string" and (spellName:sub(1, 1) .. spellName:sub(2):lower()) or "Falling"
        end
        amt = tonumber(amt) or 0
        if amt <= 0 then return end
        overkill = tonumber(overkill)
        if mine and not onMe then
            OutHit(sub, src, dst, spellId, spellName, school, amt, overkill, tonumber(resisted), crit)
        elseif onMe and Opt("taken", true) then
            local swing = d == 1
            local r = tonumber(resisted)
            Emit({ k = "taken", amt = amt, spell = swing and "Melee" or spellName, school = swing and "phys" or School(school),
                   icon = swing and MELEE_ICON or (Icon(spellId, spellName) or MELEE_ICON),
                   resist = (r and r > 0) and r or nil, crit = crit and true or nil,
                   maxHP = UnitHealthMax and UnitHealthMax("player") or nil })
        end
        return
    end
    local m = MISSED[sub]
    if m then
        local spellName, missType
        if m == 1 then missType = a12 else spellName, missType = a13, a15 end
        local what = MISS[missType or ""] or missType
        if not what then return end
        if mine and not onMe then
            if m == 1 and not Opt("autoAttacks", true) then return end
            Emit({ k = "miss", what = what, spell = spellName, dst = dst })
        elseif onMe and Opt("taken", true) then
            Emit({ k = "miss", what = what, spell = spellName or "Melee", mine = true })
        end
        return
    end
    if HEALS[sub] then
        local spellId, spellName, amt, over, crit = a12, a13, tonumber(a15) or 0, tonumber(a16) or 0, a18
        local eff = amt - over
        if eff <= 0 then return end
        if onMe then
            if not Opt("heals", true) then return end
            if eff < (tonumber(Opt("minHeal", 0)) or 0) then return end
            local self = src == me
            local cls = (not self) and ClassOf(src) or nil
            local coords = cls and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls]
            Emit({ k = "heal", amt = eff, spell = spellName, icon = Icon(spellId, spellName),
                   who = self and spellName or ShortName(srcName), whoClass = cls,
                   whoIcon = coords and "Interface\\TargetingFrame\\UI-Classes-Circles" or nil, whoCoords = coords,
                   crit = crit and true or nil, maxHP = UnitHealthMax and UnitHealthMax("player") or nil })
        elseif mine and src == me then
            if eff < (tonumber(Opt("minHeal", 0)) or 0) then return end
            Emit({ k = "out", amt = eff, spell = spellName, icon = Icon(spellId, spellName), school = "heal",
                   crit = crit and true or nil, dst = dst })
        end
        return
    end
    if sub == "SPELL_EXTRA_ATTACKS" and src == me then
        local name = a13
        if type(name) == "string" then name = name:gsub(" Attack$", "") end
        extra = { name = name, untilT = Now() + 0.6 }
        return
    end
    if sub == "SPELL_AURA_APPLIED" and onMe and a15 == "BUFF" then
        CTE:Proc(a12, a13, src)
    end
end
CTE.OnCLEU = OnCLEU

-- A buff gained in combat: shown when it lasts a minute or less (my own 30 s+ buffs, seals, are left out).
function CTE:Proc(spellId, spellName, src)
    if not Opt("procs", true) or not InCombat() then return end
    local dur
    if UnitBuff then
        for i = 1, 40 do
            local name, _, _, _, d, _, _, _, _, id = UnitBuff("player", i)
            if not name then break end
            if (spellId and id == spellId) or name == spellName then dur = tonumber(d) break end
        end
    end
    if not dur or dur <= 0 or dur > 60 then return end
    if src == me and dur >= 30 then return end
    local t = Now()
    if lastProc[spellName or ""] and t - lastProc[spellName or ""] < 1 then return end
    lastProc[spellName or ""] = t
    Emit({ k = "proc", spell = spellName, icon = Icon(spellId, spellName), dur = dur })
end

---------------------------------------------------------------------------
-- Alerts, low health
---------------------------------------------------------------------------

function CTE:LearnSpells()
    for k in pairs(reactive) do reactive[k] = nil end
    for k in pairs(ground) do ground[k] = nil end
    for _, id in ipairs(GROUND) do
        local name = GetSpellInfo and GetSpellInfo(id)
        if name then ground[name] = true end
    end
    for _, id in ipairs(REACTIVE) do
        local name, icon
        if GetSpellInfo then name, _, icon = GetSpellInfo(id) end
        local known = IsSpellKnown and IsSpellKnown(id)
        if name and known then reactive[name] = icon or (GetSpellTexture and GetSpellTexture(id)) or true end
    end
end

function CTE:CheckAlerts()
    if not (Opt("alerts", true) and self:IsOn()) then return end
    if not next(reactive) then return end
    local fighting = InCombat() and UnitExists and UnitExists("target") and UnitCanAttack and UnitCanAttack("player", "target")
    for name, icon in pairs(reactive) do
        local usable = IsUsableSpell and IsUsableSpell(name)
        local ready = usable and true or false
        if ready and GetSpellCooldown then
            local start, dur = GetSpellCooldown(name)
            if start and start > 0 and dur and start + dur - Now() > 1.6 then ready = false end
        end
        if ready and not wasUsable[name] and fighting then
            Emit({ k = "alert", spell = name, icon = icon ~= true and icon or nil })
        end
        wasUsable[name] = ready
    end
end

function CTE:CheckLow(unit, power)
    if unit ~= "player" or not (Opt("lowHealth", true) and self:IsOn()) then return end
    if not power then
        local h, m = UnitHealth("player") or 0, UnitHealthMax("player") or 0
        if m <= 0 then return end
        local pct = h / m * 100
        if pct < 35 and not low.hp and InCombat() and h > 0 then
            low.hp = true
            Emit({ k = "lowhp", pct = floor(pct + 0.5) })
        elseif pct > 50 then
            low.hp = false
        end
    else
        if UnitPowerType and UnitPowerType("player") ~= 0 then return end
        local p, m = UnitPower("player", 0) or 0, UnitPowerMax("player", 0) or 0
        if m <= 0 then return end
        local pct = p / m * 100
        if pct < 25 and not low.mana and InCombat() then
            low.mana = true
            Emit({ k = "lowhp", pct = floor(pct + 0.5), mana = true })
        elseif pct > 50 then
            low.mana = false
        end
    end
end

---------------------------------------------------------------------------
-- The game's own numbers
---------------------------------------------------------------------------

-- The game's numbers: the CVars this client's own options write (Blizzard_SettingsDefinitions_Frame, Classic
-- CombatOverrides.lua): the _v2 damage, periodic, pet and healing numbers over the mobs (the names without _v2 do
-- nothing on this client), and enableFloatingCombatText, the game's scrolling text over your head (hits taken,
-- heals, procs). Each is saved the first time it is turned off and put back as it was when ours go off.
local GAME_CVARS = { "floatingCombatTextCombatDamage_v2", "floatingCombatTextCombatLogPeriodicSpells_v2",
                     "floatingCombatTextPetMeleeDamage_v2", "floatingCombatTextPetSpellDamage_v2",
                     "floatingCombatTextCombatHealing_v2", "enableFloatingCombatText" }
CTE.GAME_CVARS = GAME_CVARS

local function CVar(cv)
    if C_CVar and C_CVar.GetCVar then return C_CVar.GetCVar(cv) end
    return GetCVar and GetCVar(cv)
end
local function SetCV(cv, v)
    if C_CVar and C_CVar.SetCVar then return pcall(C_CVar.SetCVar, cv, v) end
    if SetCVar then return pcall(SetCVar, cv, v) end
end

function CTE:ApplyGameNumbers()
    local s = ns.db
    if not s then return end
    local hide = self:IsOn() and Opt("hideGame", true)
    if type(s.sctSaved) ~= "table" then s.sctSaved = nil end
    if hide then
        local saved = s.sctSaved or {}
        for _, cv in ipairs(GAME_CVARS) do
            local v = CVar(cv)
            if v ~= nil then
                if saved[cv] == nil then saved[cv] = v end
                if v ~= "0" then SetCV(cv, "0") end
            end
        end
        s.sctSaved = saved
    elseif s.sctSaved then
        for cv, v in pairs(s.sctSaved) do
            if CVar(cv) ~= nil then SetCV(cv, v) end
        end
        s.sctSaved = nil
    end
end

---------------------------------------------------------------------------
-- On / off
---------------------------------------------------------------------------

local listening = false
function CTE:Refresh()
    local on = self:IsOn()
    if ns.CombatLog then ns.CombatLog:SetSubscribed("combattext", OnCLEU, on) end
    listening = on
    self:ApplyGameNumbers()
end
function CTE:IsListening() return listening end

function CTE:OnLogin()
    me = UnitGUID and UnitGUID("player")
    pet = UnitGUID and UnitGUID("pet")
    self:LearnSpells()
    self:Refresh()
    ns:RegisterEvent("UNIT_PET", function(_, unit) if unit == "player" then pet = UnitGUID("pet") end end)
    ns:RegisterEvent("SPELLS_CHANGED", function() CTE:LearnSpells() end)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() fight = { peak = 0 } end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        fight = nil
        CTE:ApplyGameNumbers()
    end)
    ns:RegisterEvent("UNIT_HEALTH", function(_, unit)
        if unit == "player" then CTE:CheckLow("player") elseif unit == "target" then CTE:CheckAlerts() end
    end)
    ns:RegisterEvent("UNIT_POWER_UPDATE", function(_, unit, kind) if kind == "MANA" then CTE:CheckLow(unit, true) end end)
    for _, e in ipairs({ "SPELL_UPDATE_USABLE", "ACTIONBAR_UPDATE_USABLE", "PLAYER_TARGET_CHANGED", "SPELL_UPDATE_COOLDOWN" }) do
        ns:RegisterEvent(e, function() CTE:CheckAlerts() end)
    end
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and (path == "ui.look" or path:find("^ui%.sct%.")) then
            CTE:Refresh()
            local ui = UIx()
            if ui then ui:SetZones(); ui:Rescale() end
        end
    end)
end
