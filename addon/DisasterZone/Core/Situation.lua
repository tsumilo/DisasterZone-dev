if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Situation.lua", ...) then return end -- DisasterZone: rotation situations.
-- What a class tool's rotation is facing (feedback #30, Slay: "Auto swap to AoE / PvP scenarios with the class tools";
-- mockup claude.ai/artifact/F7uzKaTkq9oHbjqk2CQNj3, v3 approved 2026-10-17). A timer with a rotation (Core/WarriorSwing.lua,
-- Core/SwingTimer.lua, Core/ShotTimer.lua) asks Situation:Info(prefix) every frame and plays the presses for it:
--   single   one target: the rotation as before (the default)
--   pack     enough enemies fighting within reach. Counted (union by GUID) from enemy nameplates that are in combat
--            and within reach, and from the enemies the tool's own multi-target attacks hit in the last HIT_TTL
--            seconds (Whirlwind, Cleave, Sweeping Strikes' extra hits; Multi-Shot, Volley). In after the count held
--            for inDelay s, back after it stayed under for outDelay s, so it never flickers.
--   player   the target is an enemy player: duels, battlegrounds, arenas and the open world alike. At once.
-- On top of any of them, held: a crowd-controlled enemy whose tooltip says any damage breaks it is within reach, so
-- the presses that hit more than the target wait (the tool decides which: info.held).
-- Reach is what the client can measure in a fight: melee (IsSpellInRange of the tool's melee spell), 10 yd
-- (CheckInteractDistance 3, duel range) or 28 yd (4, follow range).
-- The switch key (binding DISASTERZONE_SITUATION) goes Automatic -> One target -> Pack -> Player -> Automatic (only the
-- kinds the tool has); the pick holds until the fight ends (setting sit.hold "fight") or until the key goes back to
-- Automatic ("key"). On bosses (IsEncounterInProgress, a boss unit, a world boss target) the count can be left to the
-- key: <prefix>.sit.bosses "key".
-- Settings per tool, <prefix>.sit.*: mode (auto | key | off), show (the chip), sound, packFrom, reach (melee | 10 | 28),
-- count (both | plates | hits), inDelay, outDelay, bosses (count | key), cc.<key>. One for all: sit.hold.
-- Demo: Situation:SetDemo({ kind, n, cls, held }) plays a situation on whatever timer runs (the Demo page's moments).
local addonName, ns = ...

local Sit = ns:NewModule("Situation")

local pairs, ipairs, type, tonumber, pcall = pairs, ipairs, type, tonumber, pcall
local max = math.max

local THROTTLE = 0.2             -- s between two looks at the plates and the log
local HIT_TTL = 3                -- s an enemy counts after one of our multi-target attacks hit it
Sit.THROTTLE, Sit.HIT_TTL = THROTTLE, HIT_TTL

-- Crowd control whose tooltip says any damage breaks it (Wowhead TBC, checked 2026-10-17), by one id of each: the
-- client names them (every rank shares the name).
local CC = {
    { key = "poly", id = 118 }, { key = "sap", id = 6770 }, { key = "shackle", id = 9484 },
    { key = "trap", id = 3355 }, { key = "hibernate", id = 2637 }, { key = "repent", id = 20066 },
    { key = "seduce", id = 6358 }, { key = "blind", id = 2094 }, { key = "scatter", id = 19503 },
    { key = "wyvern", id = 19386 },
}
Sit.CC = CC

local LABEL = { single = "One target", pack = "Pack", player = "Player" }
Sit.LABEL = LABEL

local tools = {}                 -- [prefix] = { kinds = { pack, player }, packFrom, reach, melee, aoe = { ids }, active() }
local order = {}                 -- prefixes in register order
local state = {}                 -- [prefix] = { info, at, pack, inSince, outSince, key }
local hits = {}                  -- [guid] = GetTime() of our last multi-target hit on it
local aoeNames = {}              -- [spell name] = true: the registered tools' multi-target attacks
local ccNames = {}               -- [spell name] = CC entry
local lock, lockFought           -- the switch key's pick ("single" | "pack" | "player") and whether a fight ran since
local demo                       -- { kind, n, cls, held } while a demo moment plays

local function Setting(path, default)
    local v = ns.DB and ns.DB:GetSetting(path)
    if v == nil then return default end
    return v
end

function Sit:Get(prefix, path, default)
    local d = tools[prefix]
    if default == nil and d then
        if path == "packFrom" then default = d.packFrom
        elseif path == "reach" then default = d.reach end
    end
    return Setting(prefix .. ".sit." .. path, default)
end

-- A tool with a rotation: def = { kinds = { pack = true, player = true }, packFrom, reach ("melee" | "10" | "28"),
-- melee (a melee spell id for the melee reach), aoe = { spell ids whose hits count }, active() }.
function Sit:Register(prefix, def)
    def.kinds = def.kinds or {}
    def.packFrom = def.packFrom or 2
    def.reach = def.reach or "10"
    tools[prefix] = def
    order[#order + 1] = prefix
    state[prefix] = { info = { kind = "single", n = 0 } }
    for _, id in ipairs(def.aoe or {}) do
        local n = GetSpellInfo and GetSpellInfo(id)
        if n then aoeNames[n] = true end
    end
    return def
end

function Sit:Tool(prefix) return tools[prefix] end

-- The kinds a tool can be in, in the key's order.
function Sit:Kinds(prefix)
    local d = tools[prefix]
    local out = { "single" }
    if d and d.kinds.pack then out[#out + 1] = "pack" end
    if d and d.kinds.player then out[#out + 1] = "player" end
    return out
end

local function CcNames()
    if next(ccNames) then return ccNames end
    for _, c in ipairs(CC) do
        local n = GetSpellInfo and GetSpellInfo(c.id)
        if n then ccNames[n] = c end
    end
    return ccNames
end

-- ---------------------------------------------------------------------------------------------------------------
-- What the client can tell
-- ---------------------------------------------------------------------------------------------------------------
local plates = {}
local function Plates()
    for i = #plates, 1, -1 do plates[i] = nil end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return plates end
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if u then plates[#plates + 1] = u end
    end
    return plates
end
Sit.Plates = Plates

local function InReach(unit, reach, melee)
    if reach == "melee" then
        local n = melee and GetSpellInfo and GetSpellInfo(melee)
        if n and IsSpellInRange then
            local r = IsSpellInRange(n, unit)
            if r ~= nil then return r == 1 end
        end
        reach = "10"
    end
    if not CheckInteractDistance then return false end
    local ok, r = pcall(CheckInteractDistance, unit, reach == "28" and 4 or 3)
    return ok and r and true or false
end
Sit.InReach = InReach

local function Hostile(unit)
    return UnitExists and UnitExists(unit) and UnitCanAttack and UnitCanAttack("player", unit)
        and not (UnitIsDead and UnitIsDead(unit)) or false
end

-- The first crowd control (one the tool's settings guard) on this unit: its entry, name and icon.
local function CcOn(prefix, unit)
    if not UnitDebuff then return nil end
    local names = CcNames()
    for i = 1, 40 do
        local n, icon = UnitDebuff(unit, i)
        if not n then break end
        local c = names[n]
        if c and Sit:Get(prefix, "cc." .. c.key, true) then return c, n, icon end
    end
    return nil
end

-- Enemies fighting within reach (nameplates and/or our hits), and a crowd-controlled one in reach.
local seen = {}
function Sit:Count(prefix, now)
    local d = tools[prefix]
    local reach = self:Get(prefix, "reach")
    local mode = self:Get(prefix, "count", "both")
    for g in pairs(seen) do seen[g] = nil end
    local n, held = 0, nil
    for _, u in ipairs(Plates()) do
        if Hostile(u) and InReach(u, reach, d and d.melee) then
            local c, cn, ci = CcOn(prefix, u)
            if c then
                held = held or { key = c.key, name = cn, icon = ci }
            elseif mode ~= "hits" and UnitAffectingCombat and UnitAffectingCombat(u) then
                local g = UnitGUID(u)
                if g and not seen[g] then seen[g] = true; n = n + 1 end
            end
        end
    end
    if mode ~= "plates" then
        for g, t in pairs(hits) do
            if now - t > HIT_TTL or t > now + 1 then hits[g] = nil
            elseif not seen[g] then seen[g] = true; n = n + 1 end
        end
    end
    return n, held
end

function Sit:TargetPlayer()
    if not (UnitIsPlayer and UnitIsPlayer("target")) or not Hostile("target") then return nil end
    local name, cls = UnitClass("target")
    return cls or "WARRIOR", name
end

function Sit:InBossFight()
    if IsEncounterInProgress and IsEncounterInProgress() then return true end
    if UnitExists and UnitExists("boss1") then return true end
    return UnitClassification and UnitClassification("target") == "worldboss" or false
end

-- ---------------------------------------------------------------------------------------------------------------
-- The situation
-- ---------------------------------------------------------------------------------------------------------------
local function Allowed(d, kind)
    return kind == "single" or (d and d.kinds[kind]) and true or false
end

local function Sound()
    if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856, "Master") end
end

-- { kind = "single" | "pack" | "player", n (enemies counted), held = { key, name, icon } or nil, cls / who (the
-- player's class file and class name), locked (the key's pick), boss, auto (picked by the tool, not the key) }.
-- The table is the tool's own and is reused: read it, don't keep it.
function Sit:Info(prefix, now)
    now = now or GetTime()
    local d, s = tools[prefix], state[prefix]
    if not s then return { kind = "single", n = 0 } end
    if s.at and now >= s.at and now - s.at < THROTTLE then return s.info end
    s.at = now
    local info = s.info
    info.held, info.cls, info.who, info.boss, info.locked = nil, nil, nil, nil, nil
    info.n = 0
    local mode = self:Get(prefix, "mode", "auto")
    local kind = "single"
    if demo then
        kind = Allowed(d, demo.kind) and demo.kind or "single"
        info.n, info.cls, info.who = demo.n or 0, demo.cls, demo.who
        info.held = demo.held
        info.locked = demo.locked
    elseif mode ~= "off" then
        -- (only tools with presses that hit more than the target look at the plates: the others have nothing to hold)
        local n, held = 0, nil
        if d.kinds.pack then n, held = self:Count(prefix, now) end
        info.n, info.held = n, held
        local boss = self:InBossFight()
        info.boss = boss
        local cls, who = nil, nil
        if d.kinds.player then cls, who = self:TargetPlayer() end
        -- the count's own state (in after inDelay, out after outDelay), kept while a player or the key decides
        local want = d.kinds.pack and n >= (tonumber(self:Get(prefix, "packFrom")) or 2)
            and not (boss and self:Get(prefix, "bosses", "count") == "key") or false
        if s.pack then
            if want then s.outSince = nil
            else
                s.outSince = s.outSince or now
                if now - s.outSince >= (tonumber(self:Get(prefix, "outDelay", 3)) or 3) then s.pack, s.outSince = false, nil end
            end
        else
            if want then
                s.inSince = s.inSince or now
                if now - s.inSince >= (tonumber(self:Get(prefix, "inDelay", 1)) or 1) then s.pack, s.inSince = true, nil end
            else s.inSince = nil end
        end
        if lock and Allowed(d, lock) then
            kind, info.locked = lock, true
        elseif mode == "key" then
            kind = "single"
        elseif cls then
            kind = "player"
        elseif s.pack then
            kind = "pack"
        end
        if kind == "player" then info.cls, info.who = cls or "WARRIOR", who end
    end
    info.kind = kind
    info.auto = not info.locked
    -- a new situation (or crowd control coming / going): the HUD flashes; the tool's own switch clicks if asked
    local key = kind .. ":" .. (info.held and info.held.key or "") .. ":" .. (info.locked and "k" or "")
    if s.key and key ~= s.key then
        s.changedAt = now
        if info.auto and not demo and self:Get(prefix, "sound", false) then Sound() end
    end
    s.key = key
    return info
end

-- When the situation (or its hold) last changed: the HUD flashes the next press once.
function Sit:ChangedAt(prefix) return state[prefix] and state[prefix].changedAt end

-- Forget the throttle (settings changed, a test steps the clock).
function Sit:Dirty(prefix)
    for p, s in pairs(state) do
        if not prefix or p == prefix then s.at = nil end
    end
end

-- Back to nothing seen (a new fight, the tool switched off).
function Sit:Reset(prefix)
    for p, s in pairs(state) do
        if not prefix or p == prefix then
            s.at, s.pack, s.inSince, s.outSince, s.key, s.changedAt = nil, nil, nil, nil, nil, nil
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The switch key
-- ---------------------------------------------------------------------------------------------------------------
function Sit:Lock() return lock end

local function InFight() return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) or false end

function Sit:SetLock(kind)
    if kind == "auto" then kind = nil end
    lock = kind
    lockFought = kind ~= nil and InFight() or false
    self:Dirty()
    ns:Fire("SITUATION_LOCK", lock)
end

-- The tool running now (the key works on it), or nil.
function Sit:ActiveTool()
    for _, p in ipairs(order) do
        local d = tools[p]
        if d.active and d.active() then return p end
    end
    return nil
end

-- Automatic -> One target -> Pack -> Player -> Automatic, over the kinds the running tool has.
function Sit:Cycle()
    local p = self:ActiveTool()
    local kinds = p and self:Kinds(p) or { "single" }
    local cur = lock
    local nxt = nil
    if not cur then nxt = kinds[1]
    else
        for i, k in ipairs(kinds) do
            if k == cur then nxt = kinds[i + 1] break end
        end
    end
    self:SetLock(nxt)
    return nxt
end

function DisasterZone_SituationNext() Sit:Cycle() end
BINDING_HEADER_DISASTERZONE = BINDING_HEADER_DISASTERZONE or "DisasterZone"
BINDING_NAME_DISASTERZONE_SITUATION = "Rotation: next situation (Automatic, One target, Pack, Player)"

-- The key it is bound to, as the client writes it ("SHIFT-F"), or nil.
function Sit:KeyText()
    local k = GetBindingKey and GetBindingKey("DISASTERZONE_SITUATION")
    return k and (GetBindingText and GetBindingText(k) or k) or nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- Demo moments (UI/DemoList.lua): a situation played on whatever timer runs
-- ---------------------------------------------------------------------------------------------------------------
function Sit:SetDemo(d)
    demo = d
    self:Dirty()
    ns:Fire("SITUATION_LOCK", lock)
end
function Sit:Demo() return demo end

-- ---------------------------------------------------------------------------------------------------------------
-- Our multi-target hits (a Core/CombatLog.lua subscriber while a tool with a pack runs)
-- ---------------------------------------------------------------------------------------------------------------
local myGUID
local function OnCombatLog(_, _, sub, _, src, _, _, _, dst, _, _, _, _, spellName)
    if sub == "UNIT_DIED" then hits[dst] = nil return end
    if src ~= myGUID then return end
    if (sub == "SPELL_DAMAGE" or sub == "SPELL_MISSED") and spellName and aoeNames[spellName] and dst then
        hits[dst] = GetTime()
    end
end
Sit.OnCombatLog = OnCombatLog
function Sit:Hits() return hits end

function Sit:Refresh()
    local want = false
    for _, p in ipairs(order) do
        local d = tools[p]
        if d.kinds.pack and d.active and d.active() and self:Get(p, "mode", "auto") ~= "off" then want = true end
    end
    if ns.CombatLog and ns.CombatLog.SetSubscribed then ns.CombatLog:SetSubscribed("situation", OnCombatLog, want) end
end

function Sit:OnLogin()
    myGUID = UnitGUID("player")
    -- (names come from the client: read them once the spellbook is there)
    for _, p in ipairs(order) do
        for _, id in ipairs(tools[p].aoe or {}) do
            local n = GetSpellInfo and GetSpellInfo(id)
            if n then aoeNames[n] = true end
        end
    end
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if lock then lockFought = true end
    end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        for g in pairs(hits) do hits[g] = nil end
        self:Reset()
        if lock and lockFought and Setting("sit.hold", "fight") == "fight" then self:SetLock(nil) end
    end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:find("%.sit%.") then self:Dirty(); self:Refresh() end
    end)
    for _, e in ipairs({ "WAR_STATE", "SWING_STATE", "SHOT_STATE", "CLASSKIT_CHANGED" }) do
        ns:On(e, function() self:Refresh() end)
    end
    self:Refresh()
end
