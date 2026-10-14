if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Plates.lua", ...) then return end -- DisasterZone UI/Plates.lua
-- Nameplates in the UI looks (ns.Plates): Settings > Interface > Looks > Nameplates (ui.plates.look, following
-- ui.look; Blizzard = the game's own plates). The mockup of 2026-10-13 (claude.ai/artifact/TxPbRME3GQ9ACQ88e74evf),
-- built 2026-10-14 with my picks (the user: "get this done"): threat as bar colours for tanks and a glow for the
-- others, your own debuffs (the raid's armor and curse debuffs as an option), friendly players by name until hurt,
-- other plates at 60% while you have a target, plates stacking.
-- How: every plate the game shows (NAME_PLATE_UNIT_ADDED) gets a frame of ours on it, drawn by the look's code
-- (UI/PlateLooks.lua) with the combat text's pen (UI/CombatTextPen.lua); the game's own plate under it is made
-- see-through (its UnitFrame's alpha 0), so clicks, tab targeting and mouse-over stay the game's. Friendly plates in
-- dungeons and raids are the game's alone (forbidden to addons): those stay as they are.
-- Reading: on events (health, auras, casts, threat, marks, target) a plate is read again; drawing: at once when read,
-- every frame while it casts or pulses, four times a second while it shows debuff times. One OnUpdate, only while a
-- plate of ours is up. Stacking: the game's own CVar (nameplateMotion), set out of combat and put back when ours go.
local addonName, ns = ...

local P = ns:NewModule("Plates")
local Pen = ns.CTPen

local floor, max, min, abs, sin = math.floor, math.max, math.min, math.abs, math.sin
local pairs, ipairs, pcall, type, tostring = pairs, ipairs, pcall, type, tostring
local wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end

local recs = {}            -- [token] = { token, plate, root, host, p, dirty, at }
P.recs = recs
local driver
local reported = false

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local function Opt(key, default)
    if not ns.Look then return default end
    local v = ns.Look:Opt("plates", key, default)
    if v == nil then return default end
    return v
end
P.Opt = Opt

function P:LookKey()
    local L = ns.Look
    return L and L:Key("plates") or "blizzard"
end
function P:IsOn() return self:LookKey() ~= "blizzard" end
function P:Face(key)
    local looks = ns.PlateLooks
    return looks and (looks[key or self:LookKey()] or looks.flat)
end

local function Report(err)
    if reported then return end
    reported = true
    local h = geterrorhandler and geterrorhandler()
    if h then h(err) end
end

---------------------------------------------------------------------------
-- What a plate shows
---------------------------------------------------------------------------

local function C(r, g, b) return { r / 255, g / 255, b / 255 } end
-- (threat: tanks' bar colours; everyone else's glows)
local TH = { mine = C(72, 189, 84), slip = C(255, 150, 36), lost = C(232, 40, 36), tank = C(66, 156, 242) }
local GLOW = { near = C(255, 150, 30), aggro = C(255, 34, 24) }
P.TH, P.GLOW = TH, GLOW
local GAME = { hostile = { 1, 0, 0 }, neutral = { 1, 1, 0 }, friend = { 0, 1, 0 } }
local NAMES = { hostile = C(255, 104, 86), neutral = C(255, 220, 90), friend = C(110, 220, 120) }

-- Finishers that open at a health line: the tick, and the icon beside the plate once a mob is past it.
local EXEC = { PALADIN = { 0.2, "Interface\\Icons\\Ability_ThunderClap" },
               WARRIOR = { 0.2, "Interface\\Icons\\INV_Sword_48" } }
P.EXEC = EXEC

-- The raid's armor and curse debuffs (spell ids, every rank): shown with yours when the option is on.
local RAID_DEBUFFS = {}
for _, id in ipairs({ 7386, 7405, 8380, 11596, 11597, 25225,                  -- Sunder Armor
                      770, 778, 9749, 9907, 26993, 16857, 17390, 17391, 17392, 27011, -- Faerie Fire (and Feral)
                      1490, 11721, 11722, 27228,                               -- Curse of the Elements
                      704, 7658, 7659, 11717, 27226,                           -- Curse of Recklessness
                      8647, 8649, 8650, 11197, 11198, 26866,                   -- Expose Armor
                      17800, 22959, 12579 }) do                               -- Shadow Vulnerability, Fire Vuln., Winter's Chill
    RAID_DEBUFFS[id] = true
end
P.RAID_DEBUFFS = RAID_DEBUFFS
local MAX_AURAS = 5

local myClass
local function MyClass()
    if not myClass and UnitClass then myClass = select(2, UnitClass("player")) end
    return myClass
end

local function MyRole()
    local BM = ns.BossMod
    local ok, r = pcall(function() return BM and BM.MyRole and BM:MyRole() end)
    return ok and r or "dps"
end

local function InGroup() return (IsInGroup and IsInGroup()) or (GetNumGroupMembers and GetNumGroupMembers() > 0) or false end

local function IsTankUnit(u)
    if not (UnitExists and UnitExists(u)) then return false end
    if ns.Tanks and ns.Tanks.NumberOfUnit and ns.Tanks:NumberOfUnit(u) then return true end
    if GetPartyAssignment and pcall(GetPartyAssignment, "MAINTANK", u) and GetPartyAssignment("MAINTANK", u) then return true end
    return UnitGroupRolesAssigned and UnitGroupRolesAssigned(u) == "TANK" or false
end

-- The threat state of mob unit u for me: tanks mine | slip | lost | tank (another tank holds it); the others
-- near | aggro | calm. nil out of combat.
function P:Threat(u, role)
    if not (UnitAffectingCombat and UnitAffectingCombat(u)) then return nil end
    local isTanking, status, pct = nil, nil, nil
    if UnitDetailedThreatSituation then isTanking, status, pct = UnitDetailedThreatSituation("player", u) end
    if role == "tank" then
        if isTanking then return status == 3 and "mine" or "slip" end
        if IsTankUnit(u .. "target") then return "tank" end
        if UnitExists and UnitExists(u .. "target") then return "lost" end
        return nil
    end
    if not InGroup() then return nil end
    if isTanking or (status and status >= 2) then return "aggro" end
    if status == 1 or (pct and pct >= 80) then return "near" end
    return "calm"
end

local function Now() return GetTime and GetTime() or 0 end

-- Reads unit token u into plate table p (made once per plate).
function P:Read(u, p, lookKey)
    p.name = (UnitName and UnitName(u)) or ""
    local lvl = UnitLevel and UnitLevel(u) or 0
    p.lvl = (lvl and lvl > 0) and lvl or "??"
    local cls = UnitClassification and UnitClassification(u) or "normal"
    p.boss = cls == "worldboss" or cls == "elite" or cls == "rareelite" or p.lvl == "??"
    p.mark = GetRaidTargetIndex and GetRaidTargetIndex(u) or nil
    local hm = UnitHealthMax and UnitHealthMax(u) or 0
    p.hp = hm > 0 and max(0, min(1, (UnitHealth(u) or 0) / hm)) or 0
    local isPlayer = UnitIsPlayer and UnitIsPlayer(u)
    local class
    if isPlayer and UnitClass then class = select(2, UnitClass(u)) end
    local reaction = UnitReaction and UnitReaction(u, "player") or 4
    local friend = reaction >= 5
    p.friend = friend
    p.target = UnitIsUnit and UnitIsUnit(u, "target") or false
    p.dim = Opt("dim", true) and (UnitExists and UnitExists("target")) and not p.target or false
    p.combat = (UnitAffectingCombat and UnitAffectingCombat(u)) or false
    local kind = friend and "friend" or (reaction <= 3 and "hostile" or "neutral")
    local classic = lookKey == "classic"
    local col
    if class and ns.Look then col = { ns.Look.ClassColor(class) }
    elseif classic then col = GAME[kind]
    else col = ns.Look and ns.Look[kind == "friend" and "FRIEND" or kind == "hostile" and "HOSTILE" or "NEUTRAL"] or GAME[kind] end
    p.nameCol = class and col or NAMES[kind]
    p.nameOnly = friend and (not isPlayer or (Opt("friendly", "name") == "name" and p.hp >= 0.999)) or false
    -- threat
    p.glow, p.threat = nil, nil
    local mode = Opt("threat", "role")
    if not friend and mode ~= "off" then
        local role = MyRole()
        local th = self:Threat(u, role)
        p.threat = th
        if th then
            if role == "tank" then col = TH[th] or col
            elseif mode == "bar" then col = (th == "aggro" and TH.lost) or (th == "near" and TH.slip) or col
            else p.glow = GLOW[th] end
        end
    end
    p.col = col
    -- the cast
    local cast = p.castInfo
    p.castInfo = nil
    if not friend and (Opt("casts", "all") == "all" or p.target) then
        local name, _, tex, st, en, _, _, notInt = nil, nil, nil, nil, nil, nil, nil, nil
        local channel = false
        if UnitCastingInfo then name, _, tex, st, en, _, _, notInt = UnitCastingInfo(u) end
        if not name and UnitChannelInfo then
            name, _, tex, st, en, _, notInt = UnitChannelInfo(u)
            channel = name ~= nil
        end
        if name and st and en and en > st then
            cast = cast or {}
            cast.spell, cast.icon, cast.st, cast.en, cast.kick, cast.channel = name, tex, st / 1000, en / 1000, not notInt, channel
            p.castInfo = cast
        end
    end
    -- debuffs: mine, and the raid's when asked
    p.auras = p.auras or {}
    local list = p.auras
    for i = #list, 1, -1 do list[i] = nil end
    if not friend and UnitAura then
        local raid = Opt("raidDebuffs", false)
        local mine, others = 0, 0
        for i = 1, 40 do
            local name, icon, count, _, dur, exp, src, _, _, sid = UnitAura(u, i, "HARMFUL")
            if not name then break end
            local isMine = src == "player" or src == "pet"
            if isMine or (raid and sid and RAID_DEBUFFS[sid]) then
                list[#list + 1] = { icon = icon, dur = dur or 0, exp = exp or 0, stacks = count, mine = isMine }
                if isMine then mine = mine + 1 else others = others + 1 end
            end
            if #list >= 12 then break end
        end
        table.sort(list, function(a, b)
            if a.mine ~= b.mine then return a.mine end
            return (a.exp or 0) < (b.exp or 0)
        end)
        for i = #list, MAX_AURAS + 1, -1 do list[i] = nil end
    end
    -- the finisher's line
    local ex = Opt("execute", true) and not friend and EXEC[MyClass() or ""]
    p.exec = (ex and p.combat) and ex[1] or nil        -- (the tick only in a fight)
    p.execIcon = ex and ex[2] or nil
    return p
end

-- The parts that move with the clock: cast progress, debuff times, the pulse.
function P:Tick(p, now)
    local cast = p.castInfo
    if cast then
        local k = (now - cast.st) / (cast.en - cast.st)
        if k > 1.05 or k < -0.05 then
            p.cast = nil
        else
            p.cast = p.cast or {}
            local c = p.cast
            c.spell, c.icon, c.kick = cast.spell, cast.icon, cast.kick
            k = max(0, min(1, k))
            c.prog = cast.channel and 1 - k or k
            c.left = max(0, cast.en - now)
        end
    else
        p.cast = nil
    end
    for _, a in ipairs(p.auras or {}) do
        a.left = (a.exp and a.exp > 0) and max(0, a.exp - now) or 0
        a.start = (a.exp and a.exp > 0 and a.dur and a.dur > 0) and (a.exp - a.dur) or nil
    end
    p.execReady = p.exec and p.combat and p.hp > 0 and p.hp <= p.exec or false
    p.pulse = 0.55 + 0.45 * abs(sin(now * 3.6))
    p.auras = p.auras or {}
    return p
end

-- Does p change with the clock this frame (a cast, a pulse)?
local function Live(p) return p.castInfo ~= nil or p.glow ~= nil or p.execReady or (p.target and p.cast ~= nil) end

---------------------------------------------------------------------------
-- The plates
---------------------------------------------------------------------------

local function PlateOf(token)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, token, issecure and issecure() or false)
    if not ok or type(plate) ~= "table" or not plate.CreateTexture then return nil end
    if plate.IsForbidden and plate:IsForbidden() then return nil end
    return plate
end

-- The game's own plate see-through (alpha 0, kept so while ours is on it) or back.
local function GameSeen(plate, seen)
    local uf = plate and plate.UnitFrame
    if type(uf) ~= "table" or not uf.SetAlpha or (uf.IsForbidden and uf:IsForbidden()) then return end
    if not seen then
        if not uf.dzHooked and hooksecurefunc then
            uf.dzHooked = true
            hooksecurefunc(uf, "SetAlpha", function(f, a)
                if f.dzHidden and a and a > 0 and not f.dzBusy then
                    f.dzBusy = true
                    f:SetAlpha(0)
                    f.dzBusy = nil
                end
            end)
        end
        uf.dzHidden = true
        uf:SetAlpha(0)
    elseif uf.dzHidden then
        uf.dzHidden = nil
        uf:SetAlpha(1)
    end
end
P.GameSeen = GameSeen

local function Root(plate)
    local r = plate.dzPlate
    if not r then
        r = CreateFrame("Frame", nil, plate)
        r:SetSize(1, 1)
        r:SetPoint("CENTER", plate, "CENTER", 0, 0)
        if r.SetIgnoreParentAlpha then r:SetIgnoreParentAlpha(true) end
        if r.EnableMouse then r:EnableMouse(false) end
        plate.dzPlate = r
    end
    r:SetScale(max(0.5, min(2, tonumber(Opt("size", 1)) or 1)))
    r:Show()
    return r
end

function P:Draw(rec, now)
    local face = self:Face()
    if not face then return end
    local p = self:Tick(rec.p, now or Now())
    local c = Pen:Begin(rec.host, 0, 0)
    c.a = p.dim and 0.6 or 1
    local ok, err = pcall(face.Draw, c, p)
    Pen:End()
    if not ok then Report(err) end
end

function P:Add(token)
    if recs[token] then self:Remove(token) end
    if not self:IsOn() then return end
    local plate = PlateOf(token)
    if not plate then return end
    local root = Root(plate)
    local rec = { token = token, plate = plate, root = root, host = Pen:Host(10, root), p = {}, dirty = true }
    recs[token] = rec
    GameSeen(plate, false)
    self:Wake()
end

function P:Remove(token)
    local rec = recs[token]
    if not rec then return end
    recs[token] = nil
    if rec.host then Pen:Free(rec.host) end
    if rec.root then rec.root:Hide() end
end

function P:MarkAll() for _, rec in pairs(recs) do rec.dirty = true end end

-- Every plate again (the look, its options, on / off).
function P:Restyle()
    local tokens = {}
    for token, rec in pairs(recs) do tokens[#tokens + 1] = token; GameSeen(rec.plate, true) end
    for _, t in ipairs(tokens) do self:Remove(t) end
    if self:IsOn() and C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates(issecure and issecure() or false) or {}) do
            local token = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if token then self:Add(token) end
        end
    end
    self:ApplyStacking()
end

local slow, full = 0, 0
local function OnUpdate(_, elapsed)
    slow, full = slow + (elapsed or 0), full + (elapsed or 0)
    local quarter, second = slow >= 0.25, full >= 1
    if quarter then slow = 0 end
    if second then full = 0 end
    local now = Now()
    local key = P:LookKey()
    local any = false
    for _, rec in pairs(recs) do
        any = true
        if rec.dirty or (second and rec.p.combat) then
            local ok, err = pcall(P.Read, P, rec.token, rec.p, key)
            if not ok then Report(err) end
            rec.dirty = false
            rec.drawn = false
        end
        if not rec.drawn or Live(rec.p) or (quarter and #(rec.p.auras or {}) > 0) then
            P:Draw(rec, now)
            rec.drawn = true
        end
    end
    if not any then P:Sleep() end
end

function P:Wake()
    if not driver then driver = CreateFrame("Frame") end
    driver:SetScript("OnUpdate", OnUpdate)
end
function P:Sleep() if driver then driver:SetScript("OnUpdate", nil) end end
function P:IsAwake() return driver ~= nil and driver:GetScript("OnUpdate") ~= nil end

-- One step by hand (tests).
function P:Step(dt) OnUpdate(nil, dt or 0.05) end

---------------------------------------------------------------------------
-- Stacking: the game's CVar while ours are on (set out of combat), put back as it was
---------------------------------------------------------------------------

local function CVar(cv)
    if C_CVar and C_CVar.GetCVar then return C_CVar.GetCVar(cv) end
    return GetCVar and GetCVar(cv)
end
local function SetCV(cv, v)
    if C_CVar and C_CVar.SetCVar then return pcall(C_CVar.SetCVar, cv, v) end
    if SetCVar then return pcall(SetCVar, cv, v) end
end

function P:ApplyStacking()
    local s = ns.db
    if not s then return end
    if InCombatLockdown and InCombatLockdown() then self.stackLater = true return end
    self.stackLater = nil
    local want = self:IsOn() and Opt("stack", true)
    local cur = CVar("nameplateMotion")
    if cur == nil then return end
    if want then
        if s.platesMotion == nil then s.platesMotion = cur end
        if cur ~= "1" then SetCV("nameplateMotion", "1") end
    elseif s.platesMotion ~= nil then
        SetCV("nameplateMotion", s.platesMotion)
        s.platesMotion = nil
    end
end

---------------------------------------------------------------------------
-- The demo (Try it, demo mode): the mockup's Maulgar council over the middle of the screen, three moments
---------------------------------------------------------------------------

local I = "Interface\\Icons\\"
local DEMO_MOBS = {
    { key = "maulgar", name = "High King Maulgar", mark = 4, x = 8, y = -150 },
    { key = "kiggler", name = "Kiggler the Crazed", mark = 5, x = -250, y = -70 },
    { key = "blindeye", name = "Blindeye the Seer", mark = 8, x = 236, y = -80 },
    { key = "olm", name = "Olm the Summoner", mark = 7, x = -130, y = 10 },
    { key = "krosh", name = "Krosh Firehand", mark = 6, x = 352, y = 0 },
}
local DEMO_CASTS = {
    poh = { "Prayer of Healing", I .. "Spell_Holy_PrayerOfHealing02", 4, true },
    gfb = { "Greater Fireball", I .. "Spell_Fire_FlameBolt", 3, true },
    ww = { "Whirlwind", I .. "Ability_Whirlwind", 15, false, true },
    fel = { "Summon Wild Felhunter", I .. "Spell_Shadow_SummonFelHunter", 3, false },
    poly = { "Greater Polymorph", I .. "Spell_Nature_Polymorph", 2, true },
}
local DEMO_AURAS = {
    jotc = { I .. "Spell_Holy_HolySmite", 20, 16, nil, true },
    sunder = { I .. "Ability_Warrior_Sunder", 30, 24, 5 },
    ff = { I .. "Spell_Nature_FaerieFire", 40, 33 },
    coe = { I .. "Spell_Shadow_ChillTouch", 300, 214 },
}
-- moments: per mob hp, cast, debuffs, threat (tank / damage)
local DEMO_MOMENTS = {
    { maulgar = { 0.81, "ww", { "sunder", "coe" }, "mine" }, kiggler = { 0.77, nil, nil, "tank" },
      blindeye = { 0.62, "poh", { "jotc", "sunder", "ff" }, "tank" }, olm = { 0.84, "fel", nil, "tank" },
      krosh = { 0.79, "gfb", nil, "tank" } },
    { maulgar = { 0.66, nil, { "sunder", "coe" }, "slip" }, kiggler = { 0.58, "poly", nil, "lost", "aggro" },
      blindeye = { 0.44, nil, { "jotc", "sunder", "ff" }, "tank", "near" }, olm = { 0.71, nil, nil, "tank" },
      krosh = { 0.63, nil, nil, "tank" } },
    { maulgar = { 0.52, nil, { "sunder", "coe" }, "mine" }, kiggler = { 0.38, nil, nil, "tank" },
      blindeye = { 0.17, nil, { "jotc", "sunder", "ff" }, "tank" }, olm = { 0.46, nil, nil, "tank" },
      krosh = { 0.41, nil, nil, "tank" } },
}
P.DEMO_SECONDS = 15

-- A made-up plate: mob m in moment `mom` (1-3) at clock t (s), for my role.
function P:DemoPlate(m, mom, t, role, lookKey)
    local d = DEMO_MOMENTS[mom][m.key]
    local p = { name = m.name, lvl = "??", boss = true, mark = m.mark, hp = d[1], combat = true, auras = {},
                target = m.key == "blindeye", friend = false }
    p.dim = not p.target
    local th = role == "tank" and d[4] or d[5]
    p.col = lookKey == "classic" and GAME.hostile or (ns.Look and ns.Look.HOSTILE) or GAME.hostile
    p.nameCol = NAMES.hostile
    if role == "tank" and TH[th] then p.col = TH[th] elseif GLOW[th or ""] then p.glow = GLOW[th] end
    if d[2] then
        local c = DEMO_CASTS[d[2]]
        local k = (t % c[3]) / c[3]
        p.castInfo = { spell = c[1], icon = c[2], kick = c[4], channel = c[5], st = Now() - k * c[3], en = Now() + (1 - k) * c[3] }
    end
    for _, key in ipairs(d[3] or {}) do
        local a = DEMO_AURAS[key]
        local left = (a[3] - t) % a[2]
        p.auras[#p.auras + 1] = { icon = a[1], dur = a[2], exp = Now() + left, stacks = a[4], mine = a[5] or false }
    end
    p.exec, p.execIcon = 0.2, EXEC.PALADIN[2]
    return p
end

local demo = { hosts = {} }
P.demo = demo

local function DemoFrame()
    if demo.f then return demo.f end
    local f = CreateFrame("Frame", "DisasterZonePlatesDemo", UIParent)
    f:SetFrameStrata("LOW")
    f:SetSize(1, 1)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    if f.EnableMouse then f:EnableMouse(false) end
    demo.f = f
    return f
end

local function DemoUpdate(_, elapsed)
    demo.t = (demo.t or 0) + (elapsed or 0)
    if demo.t >= (demo.length or P.DEMO_SECONDS) and not demo.loop then P:StopDemo() return end
    P:DrawDemo(demo.t)
end

function P:DrawDemo(t)
    local f = DemoFrame()
    local key = self:LookKey()
    if key == "blizzard" then key = demo.look or "halo" end
    local face = self:Face(key)
    local role = MyRole() == "tank" and "tank" or "dps"
    local mom = min(3, floor((t % self.DEMO_SECONDS) / 5) + 1)
    local now = Now()
    local plates = {}
    for i, m in ipairs(DEMO_MOBS) do
        local p = self:Tick(self:DemoPlate(m, mom, t, role, key), now)
        p.g = face.Geom(p)
        p.x, p.y, p.order = m.x, m.y, i
        plates[i] = p
    end
    -- (stacked: nearer ones (further down the screen) stay, the others go up off them)
    table.sort(plates, function(a, b) return a.y > b.y end)
    local placed = {}
    for _, p in ipairs(plates) do
        for _ = 1, 12 do
            local hit
            for _, q in ipairs(placed) do
                if p.x + p.g.l < q.x + q.g.r and p.x + p.g.r > q.x + q.g.l
                    and p.y + p.g.top < q.y + q.g.bot + 2 and p.y + p.g.bot > q.y + q.g.top - 2 then hit = q break end
            end
            if not hit then break end
            p.y = hit.y + hit.g.top - 3 - p.g.bot
        end
        placed[#placed + 1] = p
    end
    for _, p in ipairs(plates) do
        local h = demo.hosts[p.order]
        if not h then h = Pen:Host(p.target and 12 or 10, f); demo.hosts[p.order] = h end
        local c = Pen:Begin(h, p.x, p.y)
        c.a = p.dim and 0.6 or 1
        local ok, err = pcall(face.Draw, c, p)
        Pen:End()
        if not ok then Report(err) end
    end
end

-- Try it (Settings; also while the plates are on Blizzard: the look you point at, else Halo).
function P:TryIt(lookKey, loop)
    local f = DemoFrame()
    local s = (UIParent:GetHeight() or 768) / 768
    f:SetScale(max(0.5, s) * max(0.5, min(2, tonumber(Opt("size", 1)) or 1)))
    demo.t, demo.look, demo.loop = 0, lookKey, loop
    f:Show()
    f:SetScript("OnUpdate", DemoUpdate)
    self:DrawDemo(0)
    return true
end

function P:StopDemo()
    for i, h in pairs(demo.hosts) do Pen:Free(h); demo.hosts[i] = nil end
    if demo.f then demo.f:SetScript("OnUpdate", nil); demo.f:Hide() end
    demo.t, demo.loop = nil, nil
end
function P:DemoRunning() return demo.t ~= nil end

-- Settings' sample: Blindeye casting, your target, in look `key` on frame f (w x h); drawn again by f.restyle.
function P:Sample(f, key)
    local face = self:Face(key)
    if not face then return nil end
    local host = Pen:Host(10, f)
    local function paint()
        local p = self:Tick(self:DemoPlate(DEMO_MOBS[3], 1, 1.3, "dps", key), Now())
        p.dim = false
        local g = face.Geom(p)
        local c = Pen:Begin(host, -g.l + 6, -g.top + 6)
        pcall(face.Draw, c, p)
        Pen:End()
        return g
    end
    local g = paint()
    f.restyle = function() paint() end
    return host, g.r - g.l + 12, g.bot - g.top + 12
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function Dirty(_, unit)
    local rec = unit and recs[unit]
    if rec then rec.dirty = true end
end

function P:OnLogin()
    MyClass()
    ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, token) P:Add(token) end)
    ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, token) P:Remove(token) end)
    for _, e in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_AURA", "UNIT_NAME_UPDATE", "UNIT_TARGET",
                         "UNIT_FACTION", "UNIT_THREAT_LIST_UPDATE", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP",
                         "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED",
                         "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_CHANNEL_STOP",
                         "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" }) do
        ns:RegisterEvent(e, Dirty)
    end
    for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "RAID_TARGET_UPDATE", "UNIT_THREAT_SITUATION_UPDATE",
                         "PLAYER_REGEN_DISABLED", "GROUP_ROSTER_UPDATE" }) do
        ns:RegisterEvent(e, function() P:MarkAll() end)
    end
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        P:MarkAll()
        if P.stackLater then P:ApplyStacking() end
    end)
    ns:On("UI_LOOK_CHANGED", function(part) if part == "plates" then P:Restyle() end end)
    ns:On("DEMO_TOGGLED", function(on)
        if on then P:TryIt() elseif P:DemoRunning() then P:StopDemo() end
    end)
    self:Restyle()
end
