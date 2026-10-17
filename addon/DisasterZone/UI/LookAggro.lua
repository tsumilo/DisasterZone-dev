if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LookAggro.lua", ...) then return end -- DisasterZone: UI/LookAggro.lua
-- Aggro warning on the unit, party and raid frames (UI/LookUnits.lua): an outline that turns from yellow to red as a
-- player nears pulling aggro off the tank. Off by default; one switch per part (ui.units.aggro, ui.group.aggro) and
-- where it starts (aggroFrom, % of the pull point).
--   * the number: a player's scaled threat (UnitDetailedThreatSituation: 100 = they pull) on my enemy (Threat:Mob),
--     their own target and the bosses, the highest of them. Tanks (a main tank, the TANK role, Defensive Stance, Bear
--     form, Righteous Fury) never warn: holding aggro is their job. Anyone else holding it is "pulled": deep red.
--   * the look: a crisp 2 px outline on the frame's edge, a soft glow round it and a faint wash inside (Halo's
--     capsules and pill bars: rings round the pill), all one colour sliding yellow > amber > red. From amber on it
--     breathes, faster as it nears the pull, and two lights glide along its edges; pulled, it throbs.
--   * smooth: every frame eases toward the read value (Ease), so colours slide and the light fades in and out.
-- Read five times a second while any part has it on (live players only in a group); drawn every frame only while
-- something glows. Demo mode (and the made-up frames of Edit layout and Settings): the made-up members drift up and
-- down through the range, one of them pulls now and then.
local addonName, ns = ...

local Aggro = ns:NewModule("LookAggro")

local pairs, ipairs, tonumber, type = pairs, ipairs, tonumber, type
local max, min, sin, floor = math.max, math.min, math.sin, math.floor

local SOFT = "Interface\\AddOns\\" .. addonName .. "\\Media\\SoftGlow"
local POLL = 0.2
local EASE = 5            -- how fast the shown value follows the read one (per second)
local PULLED = 1.15       -- the shown value of a pulled player (past red)

local function Look() return ns.Look end
local function Units() return ns.LookUnits end
local function Clock() return GetTime and GetTime() or 0 end   -- (the session clock: the light moves with it)

-- Yellow > amber > red, then the pulled red.
local STOPS = { { 0, 1, 0.9, 0.16 }, { 0.5, 1, 0.52, 0.06 }, { 1, 1, 0.13, 0.1 }, { PULLED, 0.95, 0.02, 0.06 } }
local function ColorAt(s)
    if s <= STOPS[1][1] then return STOPS[1][2], STOPS[1][3], STOPS[1][4] end
    for i = 2, #STOPS do
        local b = STOPS[i]
        if s <= b[1] then
            local a = STOPS[i - 1]
            local f = (s - a[1]) / (b[1] - a[1])
            return a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f, a[4] + (b[4] - a[4]) * f
        end
    end
    local z = STOPS[#STOPS]
    return z[2], z[3], z[4]
end
Aggro.ColorAt = ColorAt

---------------------------------------------------------------------------
-- Who is near pulling
---------------------------------------------------------------------------

local TANK_AURAS = { [71] = true, [5487] = true, [9634] = true, [25780] = true }   -- Defensive Stance, Bear, Dire Bear, Righteous Fury
local tankCache = {}      -- guid -> { until, isTank }

local function HasTankAura(u)
    for i = 1, 40 do
        local id
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local a = C_UnitAuras.GetAuraDataByIndex(u, i, "HELPFUL")
            if not a then return false end
            id = a.spellId
        elseif UnitAura then
            local name, _, _, _, _, _, _, _, _, sid = UnitAura(u, i, "HELPFUL")
            if not name then return false end
            id = sid
        else
            return false
        end
        if id and TANK_AURAS[id] then return true end
    end
    return false
end

function Aggro.IsTank(u)
    if not (UnitExists and UnitExists(u)) then return false end
    if ns.Tanks and ns.Tanks.NumberOfUnit and ns.Tanks:NumberOfUnit(u) then return true end
    if UnitGroupRolesAssigned and UnitGroupRolesAssigned(u) == "TANK" then return true end
    local guid = UnitGUID and UnitGUID(u) or u
    local c, now = tankCache[guid], Clock()
    if c and c[1] > now then return c[2] end
    local is = HasTankAura(u)
    tankCache[guid] = { now + 1, is }
    return is
end

local function Attackable(m)
    return UnitExists(m) and UnitCanAttack and UnitCanAttack("player", m) and not (UnitIsDead and UnitIsDead(m))
end

local function InGroup() return (IsInGroup and IsInGroup()) or (GetNumGroupMembers and GetNumGroupMembers() > 0) or false end

local MOBS = { "", "boss1", "boss2", "boss3", "boss4" }
-- Unit u's pull: its highest scaled threat as a share (1 = it pulls) and whether it holds aggro now. 0 for a tank,
-- out of combat, or alone.
function Aggro.Read(u)
    if not (u and UnitExists and UnitExists(u) and UnitDetailedThreatSituation) then return 0, false end
    if not (UnitIsPlayer and UnitIsPlayer(u)) and not (u == "pet" or u:find("pet")) then return 0, false end
    if not (UnitAffectingCombat and UnitAffectingCombat(u)) then return 0, false end
    if Aggro.IsTank(u) then return 0, false end
    local best, pulled = 0, false
    local function Try(m)
        if not (m and Attackable(m)) then return end
        local tanking, _, scaled = UnitDetailedThreatSituation(u, m)
        if tanking then pulled = true end
        scaled = tonumber(scaled) or 0
        if scaled > best then best = scaled end
    end
    Try(ns.Threat and ns.Threat.Mob and ns.Threat:Mob() or "target")
    Try(u .. "target")
    for i = 2, #MOBS do Try(MOBS[i]) end
    return best / 100, pulled
end

---------------------------------------------------------------------------
-- The light on one face
---------------------------------------------------------------------------

local function SoftTex(f, layer, sub, l, r, t, b, add)
    local x = f:CreateTexture(nil, layer, nil, sub)
    x:SetTexture(SOFT)
    x:SetTexCoord(l, r, t, b)
    if add and x.SetBlendMode then x:SetBlendMode("ADD") end
    x:Hide()
    return x
end

local function Solid(f, layer, sub)
    local x = f:CreateTexture(nil, layer, nil, sub)
    x:SetTexture(Look().WHITE)
    x:Hide()
    return x
end

-- (a pill: a ring `out` px past a w x h pill round frame p, drawn under it; tinted every frame without tables)
local function Pill(host, sub)
    local p = { l = host:CreateTexture(nil, "BACKGROUND", nil, sub), r = host:CreateTexture(nil, "BACKGROUND", nil, sub),
                mid = host:CreateTexture(nil, "BACKGROUND", nil, sub) }
    p.l:SetTexture(Look().DISC); p.l:SetTexCoord(0, 0.5, 0, 1)
    p.r:SetTexture(Look().DISC); p.r:SetTexCoord(0.5, 1, 0, 1)
    p.mid:SetTexture(Look().WHITE)
    function p:Place(f, w, h, out)
        local H = h + 2 * out
        local R = H / 2
        self.l:ClearAllPoints(); self.l:SetSize(R, H); self.l:SetPoint("TOPLEFT", f, "TOPLEFT", -out, out)
        self.r:ClearAllPoints(); self.r:SetSize(R, H); self.r:SetPoint("TOPRIGHT", f, "TOPRIGHT", out, out)
        self.mid:ClearAllPoints()
        self.mid:SetPoint("TOPLEFT", f, "TOPLEFT", R - out, out)
        self.mid:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", out - R, -out)
        self.wide = w > h
    end
    function p:Tint(r, g, b, a)
        local show = a > 0.004
        self.l:SetShown(show); self.r:SetShown(show); self.mid:SetShown(show and self.wide)
        if show then
            self.l:SetVertexColor(r, g, b, a); self.r:SetVertexColor(r, g, b, a); self.mid:SetVertexColor(r, g, b, a)
        end
    end
    return p
end

local PILL_GLOW = { { 4, 0.3 }, { 7, 0.16 }, { 11, 0.08 } }   -- the glow's rings: px past the pill, alpha

-- The parts, made the first time a face lights.
local function Parts(face)
    if face.aggro then return face.aggro end
    local host, over = face.host, face.over
    local g = { face = face, s = 0, goal = 0, pulled = false, seen = 0 }
    -- square looks: the soft glow outside (sides and corners of SoftGlow), the 2 px outline and the wash on `over`
    -- (above the bars, under the texts), the gliding lights added on top
    g.out = {
        SoftTex(host, "BACKGROUND", -8, 0.47, 0.53, 0, 0.5),       -- top (opaque at the frame's edge)
        SoftTex(host, "BACKGROUND", -8, 0.47, 0.53, 0.5, 1),       -- bottom
        SoftTex(host, "BACKGROUND", -8, 0, 0.5, 0.47, 0.53),       -- left
        SoftTex(host, "BACKGROUND", -8, 0.5, 1, 0.47, 0.53),       -- right
        SoftTex(host, "BACKGROUND", -8, 0, 0.5, 0, 0.5),           -- corners: TL TR BL BR
        SoftTex(host, "BACKGROUND", -8, 0.5, 1, 0, 0.5),
        SoftTex(host, "BACKGROUND", -8, 0, 0.5, 0.5, 1),
        SoftTex(host, "BACKGROUND", -8, 0.5, 1, 0.5, 1),
    }
    g.wash = {
        SoftTex(over, "BORDER", 0, 0.47, 0.53, 0.5, 1),            -- inside the top edge, fading down
        SoftTex(over, "BORDER", 0, 0.47, 0.53, 0, 0.5),            -- bottom
        SoftTex(over, "BORDER", 0, 0.5, 1, 0.47, 0.53),            -- left
        SoftTex(over, "BORDER", 0, 0, 0.5, 0.47, 0.53),            -- right
    }
    g.line = {}
    for i = 1, 4 do g.line[i] = Solid(over, "OVERLAY", 3) end
    g.sheen = { SoftTex(over, "OVERLAY", 6, 0, 1, 0, 1, true), SoftTex(over, "OVERLAY", 6, 0, 1, 0, 1, true),
                SoftTex(over, "OVERLAY", 7, 0, 1, 0, 1, true), SoftTex(over, "OVERLAY", 7, 0, 1, 0, 1, true) }
    -- pills (Halo's capsule, Halo's health pill): a 2 px ring and three wider, fainter ones under the pill
    g.ring = Pill(host, -7)
    g.halo = {}
    for i = 1, #PILL_GLOW do g.halo[i] = Pill(host, -8) end
    face.aggro = g
    return g
end

local function HideAll(g)
    for _, t in ipairs(g.out) do t:Hide() end
    for _, t in ipairs(g.wash) do t:Hide() end
    for _, t in ipairs(g.line) do t:Hide() end
    for _, t in ipairs(g.sheen) do t:Hide() end
    g.ring:Tint(0, 0, 0, 0)
    for _, p in ipairs(g.halo) do p:Tint(0, 0, 0, 0) end
end

-- Lays the light out for the face's look and kind (again after every Face:Apply).
function Aggro:Place(face)
    local g = face.aggro
    if not g then return end
    local host = face.host
    local pill = face.hp and face.hp.kind == "pill" and (face.ringOn or face.kind == "big")
    g.pill = pill
    g.span = nil
    if pill then
        local f = face.hp.f
        local w, h = face.hp.w or 0, face.ringOn and (face.h or 0) or (face.hp.h or 0)
        g.ring:Place(f, w, h, face.ringOn and 3 or 2)
        for i, p in ipairs(g.halo) do p:Place(f, w, h, PILL_GLOW[i][1] + (face.ringOn and 1 or 0)) end
        g.edgeTo, g.ex, g.ey, g.w, g.h = f, 0, 0, w, h
    else
        -- the box the light goes round: the frame; Classic's big frames: the rails (not the ring's whole box), its
        -- corners anchored to the bars themselves
        local C = {}
        local classicBig = face.look and face.look.game and face.kind == "big" and face.hp and face.hp.f
        if classicBig then
            local low = (face.pp and face.pp.f and face.pp.f:IsShown()) and face.pp.f or face.hp.f
            C.TOPLEFT, C.TOPRIGHT = { face.hp.f, -3, 3 }, { face.hp.f, 3, 3 }
            C.BOTTOMLEFT, C.BOTTOMRIGHT = { low, -3, -3 }, { low, 3, -3 }
        else
            for _, k in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do C[k] = { host, 0, 0 } end
        end
        local function At(t, point, corner, dx, dy)
            local c = C[corner]
            t:SetPoint(point, c[1], corner, c[2] + (dx or 0), c[3] + (dy or 0))
        end
        local function Strip(t, p1, c1, p2, c2, w, h, dx1, dy1, dx2, dy2)
            t:ClearAllPoints(); At(t, p1, c1, dx1, dy1); At(t, p2, c2, dx2, dy2)
            if w then t:SetWidth(w) else t:SetHeight(h) end
        end
        local G = (face.kind == "cell") and 6 or 9
        local o = g.out
        Strip(o[1], "BOTTOMLEFT", "TOPLEFT", "BOTTOMRIGHT", "TOPRIGHT", nil, G)
        Strip(o[2], "TOPLEFT", "BOTTOMLEFT", "TOPRIGHT", "BOTTOMRIGHT", nil, G)
        Strip(o[3], "TOPRIGHT", "TOPLEFT", "BOTTOMRIGHT", "BOTTOMLEFT", G)
        Strip(o[4], "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT", G)
        for k = 5, 8 do o[k]:ClearAllPoints(); o[k]:SetSize(G, G) end
        At(o[5], "BOTTOMRIGHT", "TOPLEFT"); At(o[6], "BOTTOMLEFT", "TOPRIGHT")
        At(o[7], "TOPRIGHT", "BOTTOMLEFT"); At(o[8], "TOPLEFT", "BOTTOMRIGHT")
        local I = (face.kind == "cell") and 7 or 10
        local wsh = g.wash
        Strip(wsh[1], "TOPLEFT", "TOPLEFT", "TOPRIGHT", "TOPRIGHT", nil, I)
        Strip(wsh[2], "BOTTOMLEFT", "BOTTOMLEFT", "BOTTOMRIGHT", "BOTTOMRIGHT", nil, I)
        Strip(wsh[3], "TOPLEFT", "TOPLEFT", "BOTTOMLEFT", "BOTTOMLEFT", I)
        Strip(wsh[4], "TOPRIGHT", "TOPRIGHT", "BOTTOMRIGHT", "BOTTOMRIGHT", I)
        -- the outline: the frame's own outer 2 px (the dispel light and the target mark stay outside it)
        local l = g.line
        Strip(l[1], "TOPLEFT", "TOPLEFT", "TOPRIGHT", "TOPRIGHT", nil, 2)
        Strip(l[2], "BOTTOMLEFT", "BOTTOMLEFT", "BOTTOMRIGHT", "BOTTOMRIGHT", nil, 2)
        Strip(l[3], "TOPLEFT", "TOPLEFT", "BOTTOMLEFT", "BOTTOMLEFT", 2, nil, 0, -2, 0, 2)
        Strip(l[4], "TOPRIGHT", "TOPRIGHT", "BOTTOMRIGHT", "BOTTOMRIGHT", 2, nil, 0, -2, 0, 2)
        g.edgeTo, g.ex, g.ey = C.TOPLEFT[1], C.TOPLEFT[2], C.TOPLEFT[3]
        if classicBig then
            g.w = (face.hp.w or 140) + 6
            g.h = (face.hp.h or 12) + ((face.pp and face.pp.f:IsShown() and face.pp.h) or 0) + 6
        else
            g.w = host.GetWidth and host:GetWidth() or 0
            g.h = face.h or (host.GetHeight and host:GetHeight()) or 0
            if (g.w or 0) <= 0 then g.w = (face.kind == "cell") and 72 or 214 end
        end
    end
    for i, t in ipairs(g.sheen) do
        local core = i > 2
        local L = max(16, (g.w or 72) * (core and 0.16 or 0.4))
        t:SetSize(L, core and 4 or 10)
    end
    g.placed = face.look
end

-- Paints the light at shown value s (0 off .. 1 red .. PULLED) at time now.
local function Paint(g, now)
    local s = g.s
    if s < 0.004 then HideAll(g) return end
    local r, gr, b = ColorAt(s)
    local on = min(1, s * 6)                                   -- fades in right past zero
    local heat = min(1, s)
    -- breathing from amber on: deeper and quicker toward the pull; pulled, a hard throb
    local amp, hz = 0, 0
    if s > 0.45 then amp, hz = 0.12 + 0.3 * (heat - 0.45) / 0.55, 1.4 + 2.6 * (heat - 0.45) / 0.55 end
    if s > 1.001 then amp, hz = 0.5, 5.5 end
    local beat = 1 - amp + amp * (0.5 + 0.5 * sin(now * hz * 6.2832))
    local A = on * (0.55 + 0.45 * heat)
    if g.pill then
        g.ring:Tint(r, gr, b, A)
        for i, p in ipairs(g.halo) do p:Tint(r, gr, b, A * PILL_GLOW[i][2] * 1.6 * beat) end
    else
        local ga = A * 0.85 * beat
        for _, t in ipairs(g.out) do t:SetVertexColor(r, gr, b, ga); t:Show() end
        local wa = A * (0.18 + 0.22 * heat) * beat
        for _, t in ipairs(g.wash) do t:SetVertexColor(r, gr, b, wa); t:Show() end
        for _, t in ipairs(g.line) do t:SetVertexColor(r, gr, b, A); t:Show() end
    end
    -- the gliding lights: from amber on, faster as it heats (the top one left to right, the bottom one back)
    local sheenA = (s > 0.5) and on * min(1, (s - 0.5) * 4) or 0
    if sheenA <= 0.01 or not g.edgeTo then
        for _, t in ipairs(g.sheen) do t:Hide() end
        return
    end
    local period = (s > 1.001) and 0.9 or (2.6 - 1.2 * heat)
    g.phase = ((g.phase or 0) + (now - (g.last or now)) / period) % 1
    g.last = now
    local f = g.phase
    local fade = sin(f * 3.14159)
    local w, h = g.w or 72, g.h or 32
    local m = min(w * 0.25, 22)
    local x1, x2 = m + f * (w - 2 * m), w - m - f * (w - 2 * m)
    local y1, y2 = 0, -h
    if g.pill then local o = g.face.ringOn and 3 or 2; y1, y2 = o, -h - o end
    local sh = g.sheen
    for i, t in ipairs(sh) do
        local top = (i % 2) == 1
        t:ClearAllPoints()
        t:SetPoint("CENTER", g.edgeTo, "TOPLEFT", (top and x1 or x2) + (g.ex or 0), (top and y1 or y2) + (g.ey or 0))
        local core = i > 2
        local cr, cg, cb = core and 1 or r, core and min(1, gr + 0.5) or gr, core and min(1, b + 0.45) or b
        t:SetVertexColor(cr, cg, cb, sheenA * fade * (core and 0.9 or 0.75) * (top and 1 or 0.8))
        t:Show()
    end
end

-- The goal for a face: v = its pull share (1 = pulls), pulled = it holds aggro; from = where the light starts.
local function Goal(v, pulled, from)
    if pulled then return PULLED end
    if not v or v < from then return 0 end
    return 0.08 + 0.92 * min(1, (v - from) / max(0.01, 1 - from))
end
Aggro.Goal = Goal

-- Sets face's goal (Ease slides to it). snap: jump there now (tests, still renders).
function Aggro:Set(face, v, pulled, snap)
    local from = (tonumber(Look():Opt(face.part, "aggroFrom", 70)) or 70) / 100
    local goal = Goal(v, pulled, from)
    local g = face.aggro
    if goal <= 0 and not g then return end
    g = Parts(face)
    if g.placed ~= face.look then self:Place(face) end
    g.goal = goal
    if snap then
        g.s = goal
        Paint(g, Clock())
    end
    if goal > 0 or g.s > 0 then self.lit[face] = true end
    self:Wake()
end

function Aggro:Clear(face)
    local g = face.aggro
    if not g then return end
    g.goal, g.s = 0, 0
    HideAll(g)
    self.lit[face] = nil
end

---------------------------------------------------------------------------
-- Driving: reads five times a second, eases every frame while something glows
---------------------------------------------------------------------------

Aggro.lit = setmetatable({}, { __mode = "k" })   -- faces with a light on or fading
local drawer, reader
local seed = 0

local function PartOn(part) return Look():IsOn(part) and Look():Opt(part, "aggro", false) and true or false end
function Aggro:IsOn() return PartOn("units") or PartOn("group") end

-- A made-up member's pull at time now: they drift through the range at their own pace; some pull now and then.
function Aggro.DemoValue(face, now)
    if not face.aggroSeed then seed = seed + 1; face.aggroSeed = seed end
    local k = face.aggroSeed
    local v = 0.72 + 0.36 * sin(now * (0.35 + 0.07 * (k % 5)) + k * 2.1)
    if k % 3 == 0 then v = v - 0.25 end                 -- a third stay calm
    return v, v >= 1.02
end

local function Faces() local U = Units(); return U and U.allFaces or {} end

local function Visible(face)
    local h = face.host
    return h and h.IsVisible and h:IsVisible() and face.look and face.d and face.d.exists
end

local function ReadAll()
    local U = Units()
    if not U then return end
    local on = { units = PartOn("units"), group = PartOn("group") }
    local live = InGroup()
    local now = Clock()
    for face in pairs(Faces()) do
        local wants = on[face.part] and face.kind ~= "small" and Visible(face)
        if wants then
            local d = face.d
            if d.unit then
                if live then Aggro:Set(face, Aggro.Read(d.unit))
                else Aggro:Set(face, 0, false) end
            elseif d.isPlayer then
                -- (made-up members: Edit layout, Settings samples, demo mode's party)
                Aggro:Set(face, Aggro.DemoValue(face, now))
            end
        elseif face.aggro and face.aggro.goal > 0 then
            Aggro:Set(face, 0, false)
        end
    end
end
Aggro.ReadAll = ReadAll

local function Draw(_, dt)
    dt = min(0.1, dt or 0)
    local now = Clock()
    local any = false
    local k = 1 - math.exp(-EASE * dt)
    for face in pairs(Aggro.lit) do
        local g = face.aggro
        if g then
            g.s = g.s + (g.goal - g.s) * k
            if g.goal <= 0 and g.s < 0.004 then g.s = 0 end
            if face.host:IsVisible() then Paint(g, now) else HideAll(g) end
            if g.s > 0 or g.goal > 0 then any = true else Aggro.lit[face] = nil end
        end
    end
    if not any and drawer then drawer:Hide() end
end

function Aggro:Wake()
    if not drawer then
        drawer = CreateFrame("Frame")
        drawer:SetScript("OnUpdate", Draw)
    end
    drawer:Show()
end

local function Tick() if Aggro:IsOn() then ReadAll() end end

function Aggro:Refresh()
    local on = self:IsOn()
    if on and not reader then
        if C_Timer and C_Timer.NewTicker then reader = C_Timer.NewTicker(POLL, Tick) end
        ReadAll()
    elseif not on and reader then
        reader:Cancel(); reader = nil
    end
    if not on then
        for face in pairs(Faces()) do self:Clear(face) end
    else
        -- (a part turned off while the other stays on)
        for face in pairs(Faces()) do if not PartOn(face.part) then self:Clear(face) end end
    end
end

function Aggro:OnLogin()
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and (path:find("^ui%.units%.aggro") or path:find("^ui%.group%.aggro")) then
            Aggro:Refresh()
        end
    end)
    ns:On("UI_LOOK_CHANGED", function() Aggro:Refresh() end)
    -- (the Demo page's party: its made-up members' threat drifts)
    ns:On("DEMO_PARTS_CHANGED", function(key)
        if key == "party" or key == "stop" then Aggro:Refresh(); if Aggro:IsOn() then ReadAll() end end
    end)
    self:Refresh()
end
