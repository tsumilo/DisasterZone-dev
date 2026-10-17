if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Resource.lua", ...) then return end -- DisasterZone: resource bar.
-- The resource bar's model (feedback #26, with #27's combo points on it): what the character spends right now (rage,
-- energy or mana; druids by form), how much of it, and what makes the number useful in a fight:
--   * the next energy / mana tick. Both come in steps every 2 s: a jump in the power updates is a tick and the next
--     one is due 2 s after it (the way energy tick add-ons keep time). Adrenaline Rush doubles the energy steps.
--   * the five-second rule: after mana is spent, spirit regen waits 5 s; the ring runs it before the ticks.
--   * marks: a line at what each press the player picked costs (none until they pick; Settings lists the presses
--     they know). Costs come from the client (GetSpellPowerCost) so talents count; the data file's base cost is the
--     fallback for rage and energy.
--   * warriors: the swing timer's Heroic Strike line, the rage a queued Heroic Strike / Cleave will take, and (opt-in)
--     what the next main-hand hit should give.
--   * capping: rage full, or the next tick would push energy past the top.
--   * combo points on the target (Rogues, Cat form) and druid mana under Bear and Cat (a mark per shapeshift).
-- UI/ResourceBar.lua shows it (UI/ResourceFace.lua the six looks in three shapes). A class tool for every class
-- (ClassKit "ANY"), off until switched on.
--
-- Settings (ns.DB settings "power"): see Core/DB.lua defaults.
local addonName, ns = ...

local Res = ns:NewModule("Resource")

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local pairs, ipairs, tonumber, type = pairs, ipairs, tonumber, type

local DATA = ns.ClassData.RESOURCE
local TICK, RULE = 2.0, 5.0
local MANA, RAGE, ENERGY = 0, 1, 3
local KIND = { [MANA] = "mana", [RAGE] = "rage", [ENERGY] = "energy" }
local TYPE = { mana = MANA, rage = RAGE, energy = ENERGY }
local TOKEN = { MANA = "mana", RAGE = "rage", ENERGY = "energy" }
Res.TICK, Res.RULE, Res.KIND = TICK, RULE, KIND

-- ---------------------------------------------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------------------------------------------
local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting("power." .. path)
    if v == nil then return default end
    return v
end
Res.Get = Get

local function Set(path, v)            -- (fires SETTINGS_CHANGED "power.<path>")
    if ns.DB and ns.DB.SetSetting then ns.DB:SetSetting("power." .. path, v) end
end
Res.Set = Set

-- A class tool for every class; its Settings card comes from UI/ResourceBar.lua.
ns.ClassKit:Register({ key = "power", label = "Resource bar", class = ns.ClassKit.ANY, order = 5,
                       icon = "Interface\\Icons\\Ability_Warrior_EndlessRage" })

function Res:IsMine() return ns.ClassKit:IsMine("power") end
function Res:IsLive() return ns.ClassKit:IsLive("power") end
function Res:IsDemo() return ns.ClassKit:IsDemo("power") end
local function DemoPlaying() return ns.Demo and ns.Demo.IsPlaying and ns.Demo:IsPlaying("power") or false end
Res.DemoPlaying = DemoPlaying

local function MyClass() return ns.ClassKit:MyClass() end

-- ---------------------------------------------------------------------------------------------------------------
-- Presses and their costs
-- ---------------------------------------------------------------------------------------------------------------
local names = {}                 -- spell id -> localized name
local function NameOf(id)
    if names[id] == nil and GetSpellInfo then names[id] = GetSpellInfo(id) or false end
    return names[id] or nil
end

-- Known: the id itself, or (a lower rank) the name in the spellbook (as Core/WarriorSwing.lua: by name the client
-- answers cooldown and usability only for spells the character has).
local function Known(id)
    if IsPlayerSpell and IsPlayerSpell(id) then return true end
    if IsSpellKnown and IsSpellKnown(id) then return true end
    local n = NameOf(id)
    return n ~= nil and GetSpellCooldown ~= nil and GetSpellCooldown(n) ~= nil and IsUsableSpell ~= nil
        and IsUsableSpell(n) ~= nil
end
Res.Known = Known

-- What a press costs in power `ptype`: the client's cost (talents count), else the data file's base cost (rage and
-- energy only). nil when it costs nothing of that power.
function Res:Cost(press, ptype)
    local want = ptype or (press.form and TYPE[press.form])
    if GetSpellPowerCost then
        local ok, costs = pcall(GetSpellPowerCost, NameOf(press.id) or press.id)
        if ok and type(costs) == "table" then
            for _, c in ipairs(costs) do
                if type(c) == "table" and (want == nil or c.type == want) and tonumber(c.cost) and c.cost > 0 then
                    return tonumber(c.cost)
                end
            end
        end
    end
    if press.cost and (want == nil or want == RAGE or want == ENERGY) then return press.cost end
    return nil
end

-- The presses of a class (default: mine) a mark can be picked for, with their power: { press, kind } in data order.
function Res:Presses(cls)
    cls = cls or MyClass()
    local out = {}
    local list = DATA.PRESSES[cls]
    if not list then return out end
    local default = cls == "WARRIOR" and "rage" or cls == "ROGUE" and "energy" or "mana"
    for _, p in ipairs(list) do
        out[#out + 1] = { press = p, kind = p.form or default }
    end
    return out
end

-- Picked marks are kept per class: power.marks.<CLASS> = { [press key] = true }.
function Res:Picked(cls)
    local t = Get("marks." .. (cls or MyClass() or "?"))
    return type(t) == "table" and t or {}
end

function Res:SetPicked(key, on, cls)
    cls = cls or MyClass()
    local t = {}
    for k, v in pairs(self:Picked(cls)) do t[k] = v end
    t[key] = on and true or nil
    Set("marks." .. cls, t)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Live state
-- ---------------------------------------------------------------------------------------------------------------
local st = {
    ptype = nil,                 -- the power the bar shows (MANA / RAGE / ENERGY)
    last = {},                   -- [ptype] = last value seen (to tell ticks and spends apart)
    tickAt = {},                 -- [ptype] = GetTime() of the last regen tick seen
    tickGain = {},               -- [ptype] = what that tick brought
    ruleAt = nil,                -- GetTime() mana was last spent (the five-second rule)
    fight = false,
}
Res.state = st

local function Clock() return GetTime and GetTime() or 0 end

local function PowerType()
    local pt = UnitPowerType and UnitPowerType("player")
    pt = tonumber(pt) or MANA
    if not KIND[pt] then pt = MANA end
    return pt
end

local function Power(pt)
    return tonumber(UnitPower and UnitPower("player", pt)) or 0, max(1, tonumber(UnitPowerMax and UnitPowerMax("player", pt)) or 0)
end

local function HasBuff(id)
    if not UnitBuff then return false end
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, sid = UnitBuff("player", i)
        if not name then return false end
        if sid == id then return true end
    end
    return false
end

-- A power update: tell a regen tick (energy / mana going up in a step) from a spend (going down).
function Res:Seen(pt, now)
    local v, mx = Power(pt)
    local prev = st.last[pt]
    st.last[pt] = v
    if not prev then return end
    local d = v - prev
    if pt == ENERGY then
        -- a tick is +20 (+40 under Adrenaline Rush); less when it hit the top; Thistle Tea / Relentless Strikes give
        -- more than one tick at once (those are not ticks)
        if d > 0 and d <= 45 then st.tickAt[pt], st.tickGain[pt] = now, d end
    elseif pt == MANA then
        if d < 0 then
            st.ruleAt = now
        elseif d > 0 and d <= mx * 0.06 then
            st.tickAt[pt] = now
            if not (st.ruleAt and now - st.ruleAt < RULE) then st.tickGain[pt] = d end
        end
    end
end

-- How far into the 2 s between ticks we are (0..1), nil before the first tick was seen.
local function TickPhase(pt, now)
    local at = st.tickAt[pt]
    if not at then return nil end
    return ((now - at) % TICK) / TICK
end

-- The next tick's gain for the bar's ghost.
local function TickGain(pt, mx)
    if pt == ENERGY then return HasBuff(DATA.ADRENALINE_RUSH) and 40 or 20 end
    if pt == MANA then return st.tickGain[pt] end
    return nil
end

-- Druid mana under Bear and Cat, with what a shapeshift costs.
local function FormMana()
    local v, mx = Power(MANA)
    if mx <= 1 then return nil end
    local shift
    for _, id in ipairs(DATA.SHIFTS) do
        if Known(id) then
            shift = Res:Cost({ id = id }, MANA)
            if shift then break end
        end
    end
    return { pct = 100 * v / mx, shift = shift and 100 * shift / mx or nil }
end

local function SwingGain()
    local W = ns.WarriorSwing
    if W and W.MainHandGain then return W:MainHandGain() end
    return 14
end

local function HeldRage()
    local held = 0
    for _, key in ipairs({ "hs", "cleave" }) do
        for _, p in ipairs(DATA.PRESSES.WARRIOR) do
            if p.key == key then
                local n = NameOf(p.id)
                if n and IsCurrentSpell and IsCurrentSpell(n) then held = max(held, Res:Cost(p, RAGE) or p.cost) end
            end
        end
    end
    return held
end

local function HSLine()
    local W = ns.WarriorSwing
    if not (W and W.RestInfo and ns.ClassKit:IsMine("war")) then return nil end
    local ok, info = pcall(W.RestInfo, W)
    return ok and info and tonumber(info.line) or nil
end

-- At rest: nothing to show for the power (rage empty, energy and mana full).
local function AtRest(pt, v, mx)
    if pt == RAGE then return v <= 0 end
    return v >= mx
end

-- The bar's snapshot: everything the faces draw. Values are in the power's own units (mana: real mana); the face
-- turns them into fractions of mx.
function Res:Snapshot(now)
    now = now or Clock()
    if DemoPlaying() then return self:DemoSnapshot(now) end
    local pt = st.ptype or PowerType()
    local v, mx = Power(pt)
    local kind = KIND[pt]
    local s = { kind = kind, v = v, mx = mx, fight = st.fight, marks = {} }
    s.rest = not st.fight and AtRest(pt, v, mx)
    if pt == ENERGY or pt == MANA then
        s.tick = TickPhase(pt, now)
        if Get("tick", "ring") ~= "off" then s.ghost = TickGain(pt, mx) end
        if pt == MANA and Get("rule", true) and st.ruleAt and now - st.ruleAt < RULE then
            s.rule = (now - st.ruleAt) / RULE
            s.ghost = nil
        end
    end
    if pt == RAGE and MyClass() == "WARRIOR" then
        if Get("hsLine", true) then s.line = HSLine() end
        if Get("queued", true) then
            local held = HeldRage()
            if held > 0 then s.held = min(held, v) end
        end
        if Get("swing", false) then s.swing = SwingGain() end
    end
    -- capping: rage full, or energy whose next tick (due within 0.6 s) would spill over
    if Get("cap", true) and st.fight then
        if pt == RAGE then
            s.cap = v >= mx - 2
        elseif pt == ENERGY and s.tick then
            s.cap = v >= mx or (v + (s.ghost or 20) > mx and (1 - s.tick) * TICK <= 0.6)
        end
    end
    -- marks: the picked presses that spend this power and are known
    local picked = self:Picked()
    for _, e in ipairs(self:Presses()) do
        if picked[e.press.key] and e.kind == kind and Known(e.press.id) then
            local c = self:Cost(e.press, pt)
            if c then
                s.marks[#s.marks + 1] = { key = e.press.key, cost = c, name = NameOf(e.press.id),
                                          icon = GetSpellTexture and GetSpellTexture(e.press.id) }
            end
        end
    end
    if Get("combo", true) and (MyClass() == "ROGUE" or (MyClass() == "DRUID" and pt == ENERGY)) then
        s.cp = tonumber(GetComboPoints and GetComboPoints("player", "target")) or 0
    end
    if MyClass() == "DRUID" and pt ~= MANA and Get("formMana", true) then s.mana = FormMana() end
    return s
end

-- Should the bar be on screen: switched on (or its demo playing), and the show setting.
function Res:Wanted(s)
    if DemoPlaying() then return true end
    if not self:IsLive() then return false end
    local show = Get("show", "active")
    if show == "always" then return true end
    if show == "combat" then return st.fight end
    s = s or self:Snapshot()
    return st.fight or not s.rest
end

-- How much of it shows: out of combat the restAlpha setting.
function Res:Alpha()
    if st.fight or DemoPlaying() then return 1 end
    return tonumber(Get("restAlpha", 0.4)) or 0.4
end

-- ---------------------------------------------------------------------------------------------------------------
-- Demo: a made-up fight for the character's resource (the class picked on the Demo page cycles in), played while the
-- "power" part runs a pull (Core/DemoParts.lua). Nothing is read from the game.
-- ---------------------------------------------------------------------------------------------------------------
local DEMO = {
    -- each: { kind, script(t) -> fields }
    rage = function(t)
        -- swings every 2.6 s (+14), Bloodthirst every 6 s (-30), Whirlwind at 3 s (-25), HS queued from 9 s
        local rage = 8 + floor(t / 2.6) * 14 - floor((t + 3) / 6) * 30 - floor((t + 3) / 10) * 25
        rage = max(0, min(100, rage + 30))
        local held = (t % 9 > 6) and min(12, rage) or nil
        return { kind = "rage", v = rage, mx = 100, line = 40, held = held, cap = rage >= 98,
                 marks = { { key = "ww", cost = 25 }, { key = "bt", cost = 30 } } }
    end,
    energy = function(t)
        local phase = (t % TICK) / TICK
        local ticks = floor(t / TICK)
        local e = 40 + ticks * 20
        local spent = floor(t / 2.2)
        e = e - spent * 40
        while e < 0 do e = e + 40 end
        local late = t % 30 > 22                  -- the last part of the pull lets it cap
        if late then e = min(100, 70 + (t % 30 - 22) * 6) end
        local cp = (spent % 6)
        return { kind = "energy", v = min(100, e), mx = 100, tick = phase, ghost = 20, cp = min(5, cp),
                 cap = late and e + 20 > 100 and phase > 0.7,
                 marks = { { key = "snd", cost = 25 }, { key = "evis", cost = 35 }, { key = "ss", cost = 40 } } }
    end,
    mana = function(t)
        local casting = (t % 30) < 16
        local m = 9000 - floor(min(t % 30, 16) / 2.5) * 420
        local rule
        if casting then rule = ((t % 30) % 2.5) / RULE + 0.1 end
        if not casting then m = m + floor(((t % 30) - 16) / TICK) * 140 end
        return { kind = "mana", v = m, mx = 10000, rule = rule, tick = not casting and ((t % TICK) / TICK) or nil,
                 ghost = not casting and 140 or nil, marks = {} }
    end,
}

function Res:DemoKind()
    local cls = MyClass()
    if cls == "WARRIOR" then return "rage" end
    if cls == "ROGUE" or cls == "DRUID" then return "energy" end
    return "mana"
end

function Res:DemoSnapshot(now)
    local D = ns.Demo
    local pull = (D and D.PULL) or 30
    local left = D and D.PullLeft and D:PullLeft()
    local t = left and (pull - left) or (now % pull)          -- (looping: no end, the clock goes round)
    local s = DEMO[self:DemoKind()](t)
    s.fight, s.rest, s.demo = true, false, true
    if s.kind == "energy" and MyClass() == "DRUID" then s.mana = { pct = 61, shift = 22 } end
    if not Get("combo", true) then s.cp = nil end
    return s
end

-- ---------------------------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------------------------
local function Changed() ns:Fire("RESOURCE_CHANGED") end

function Res:OnLogin()
    st.ptype = PowerType()
    for _, pt in ipairs({ MANA, RAGE, ENERGY }) do st.last[pt] = Power(pt) end
    st.fight = UnitAffectingCombat and UnitAffectingCombat("player") and true or false
    ns:RegisterEvent("UNIT_POWER_FREQUENT", function(_, unit, token)
        if unit ~= "player" then return end
        local kind = TOKEN[token]
        if kind then self:Seen(TYPE[kind], Clock()) end
        Changed()
    end)
    ns:RegisterEvent("UNIT_MAXPOWER", function(_, unit) if unit == "player" then Changed() end end)
    ns:RegisterEvent("UNIT_DISPLAYPOWER", function(_, unit)
        if unit ~= "player" then return end
        st.ptype = PowerType()
        Changed()
    end)
    ns:RegisterEvent("UPDATE_SHAPESHIFT_FORM", function() st.ptype = PowerType(); Changed() end)
    ns:RegisterEvent("PLAYER_TARGET_CHANGED", Changed)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() st.fight = true; Changed() end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() st.fight = false; Changed() end)
    ns:RegisterEvent("SPELLS_CHANGED", function() for k in pairs(names) do names[k] = nil end; Changed() end)
    ns:On("CLASSKIT_CHANGED", Changed)
end
