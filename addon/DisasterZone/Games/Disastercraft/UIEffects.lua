if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIEffects.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIEffects.lua
-- CraftUI's spell effects: WoW's own. Every spell's visual comes from the client's tables (Data.lua D.vis, written by
-- gen_disastercraft.py from SpellXSpellVisual -> SpellVisualEvent -> SpellVisualKit): the precast glow in the
-- caster's hands while casting, the cast flash, the missile (Fireball's fireball_missile_low.m2 ...), the impact on
-- the target, the state model while an aura lasts (Power Word: Shield's bubble), the channel - each model played by
-- the client in a small ModelScene laid over the map at the unit's attachment point, at the sprites' scale (a
-- 32 px body frame is 2.13 yards), with the spell's own sound kits.
local addonName, ns = ...

local UI = ns.CraftUI
local K = UI.Kit
local Craft = ns.Craft
local D = Craft.D
local Combat = Craft.Combat

local floor, max, min, abs, sqrt, atan2, pi = math.floor, math.max, math.min, math.abs, math.sqrt, math.atan2, math.pi
local Now = Craft.Now
local FX = {}
UI.FX = FX

local DIST = 40                 -- the camera's distance (a telephoto: next to no perspective)
local PITCH = 0.95              -- radians down from level (the map leans its heights up: a high camera)
local SIZE_YD = 6               -- each scene's square, in yards
local POOL_MAX = 28

-- attachment -> height over the feet (fraction of the body sprite) and sideways (fraction, for the right hand)
local ATT = { [-1] = { 0, 0 }, [0] = { 0.45, 0.2 }, [1] = { 0.45, 0.22 }, [2] = { 0.45, -0.22 }, [11] = { 0.9, 0 },
              [15] = { 0.55, 0 }, [16] = { 0.55, 0 }, [18] = { 1.05, 0 }, [19] = { 0, 0 }, [20] = { 0.95, 0 },
              [21] = { 0.45, -0.22 }, [22] = { 0.45, 0.22 }, [34] = { 0.5, 0 }, [35] = { 0.5, 0 } }

local pool, active = {}, {}
local pitchSign = nil           -- the client's pitch convention, found once (Project3DPointTo2D)

local function PxPerYard() return (UI.TILE or 32) / 2.13 end

local function NewScene()
    local ok, sc = pcall(CreateFrame, "ModelScene", nil, UI.top)
    if not ok or not sc or not sc.CreateActor then return nil end
    sc:SetFrameLevel((UI.top:GetFrameLevel() or 1) + 1)
    pcall(sc.SetCameraNearClip, sc, 1)
    pcall(sc.SetCameraFarClip, sc, 200)
    pcall(sc.SetLightVisible, sc, true)
    pcall(sc.SetLightDirection, sc, -0.4, 0.3, -0.8)
    pcall(sc.SetLightAmbientColor, sc, 0.9, 0.9, 0.9)
    pcall(sc.SetLightDiffuseColor, sc, 0.6, 0.6, 0.6)
    local okA, a = pcall(sc.CreateActor, sc, nil, "ModelSceneActorTemplate")
    if not okA or not a then okA, a = pcall(sc.CreateActor, sc) end
    if not okA or not a then return nil end
    sc.actor = a
    if a.SetUseCenterForOrigin then pcall(a.SetUseCenterForOrigin, a, false, false, false) end
    sc:EnableMouse(false)
    sc:Hide()
    return sc
end

-- the camera south of the effect, looking north and down at it; fov so SIZE_YD fill the scene's height
local function Frame(sc, px)
    local cp, sp = math.cos(PITCH), math.sin(PITCH)
    local sign = pitchSign or 1
    pcall(sc.SetCameraPosition, sc, -DIST * cp, 0, DIST * sp)
    pcall(sc.SetCameraOrientationByYawPitchRoll, sc, 0, sign * PITCH, 0)
    local fov = 2 * math.atan((SIZE_YD / 2) / DIST)
    pcall(sc.SetCameraFieldOfView, sc, fov)
    sc:SetSize(px, px)
end

-- the pitch sign: the origin must land in the middle of the scene; try both, keep the one that does
local function Calibrate(sc)
    if pitchSign then return end
    local best, bestErr
    for _, s in ipairs({ 1, -1 }) do
        pitchSign = s
        Frame(sc, sc:GetWidth() > 0 and sc:GetWidth() or 100)
        local ok, x, y = pcall(sc.Project3DPointTo2D, sc, 0, 0, 0)
        local okT, x2, y2 = pcall(sc.Project3DPointTo2D, sc, 0, 0, 1)
        if ok and type(x) == "number" and okT and type(y2) == "number" then
            local es = sc:GetEffectiveScale() or 1
            local w = sc:GetWidth() or 100
            local l, b = sc:GetLeft() or 0, sc:GetBottom() or 0
            local err = abs(x / es - (l + w / 2)) + abs(y / es - (b + w / 2)) + ((y2 > y) and 0 or 1000)
            if not bestErr or err < bestErr then best, bestErr = s, err end
        end
    end
    pitchSign = best or 1
end

local function Get()
    local sc = table.remove(pool)
    if not sc then
        local n = 0
        for _ in pairs(active) do n = n + 1 end
        if n >= POOL_MAX then return nil end
        sc = NewScene()
    end
    return sc
end

local function Release(e)
    local sc = e.sc
    active[e] = nil
    if sc then
        if sc.actor and sc.actor.ClearModel then pcall(sc.actor.ClearModel, sc.actor) end
        sc:Hide()
        pool[#pool + 1] = sc
    end
end

-- the screen point (top-left origin, pixels) of unit u's attachment
local function AttachPoint(u, att)
    local sx, sy = UI.UnitScreen(u)                            -- (up by its height in a building)
    local tile = UI.TILE or 32
    local a = ATT[att or -1] or ATT[34]
    local side = a[2]
    if u.face == "up" then side = -side elseif u.face == "left" or u.face == "right" then side = side * 0.3 end
    return sx + side * tile, sy - a[1] * tile                  -- (the body's feet are on its point)
end

-- plays model fdid; place() -> x, y (screen px), yaw; until = a time, or a function -> true to end
function FX.Play(fdid, scale, place, untilT, opts)
    if not fdid or not UI.top then return nil end
    local sc = Get()
    if not sc then return nil end
    local e = { sc = sc, place = place, untilT = untilT, scale = scale or 1, fdid = fdid, opts = opts or {} }
    local px = SIZE_YD * PxPerYard()
    Frame(sc, px)
    local a = sc.actor
    pcall(a.ClearModel, a)
    pcall(a.SetModelByFileID, a, fdid)
    pcall(a.SetPosition, a, 0, 0, 0)
    pcall(a.SetScale, a, e.scale)
    if a.SetAnimation then pcall(a.SetAnimation, a, 0) end
    if a.SetAlpha then pcall(a.SetAlpha, a, 1) end
    sc:Show()
    if not pitchSign then Calibrate(sc) Frame(sc, px) end
    active[e] = true
    FX.Place(e)
    return e
end

function FX.Place(e)
    local x, y, yaw = e.place()
    if not x then return false end
    local sc = e.sc
    local px = SIZE_YD * PxPerYard()
    if abs((sc:GetWidth() or 0) - px) > 0.5 then Frame(sc, px) end
    sc:ClearAllPoints()
    sc:SetPoint("CENTER", UI.top, "TOPLEFT", x, -y)
    if yaw and sc.actor.SetYaw then pcall(sc.actor.SetYaw, sc.actor, yaw) end
    return true
end

function FX.Stop(e) if e and active[e] then Release(e) end end

function FX.Update()
    local now = Now()
    local p = Craft.player
    for e in pairs(active) do
        local done = false
        if type(e.untilT) == "number" then done = now >= e.untilT
        elseif type(e.untilT) == "function" then done = e.untilT() end
        if not done and e.unit and (e.unit.map ~= (p and p.map) or (e.unit.rec and e.unit.rec.hidden)) then done = true end
        if done or not FX.Place(e) then Release(e) end
    end
end

function FX.Clear()
    for e in pairs(active) do Release(e) end
end

---------------------------------------------------------------------------
-- A spell's moments
---------------------------------------------------------------------------

local function Sound(kit)
    if kit and PlaySound and Craft:Data().sfx ~= false then pcall(PlaySound, kit, "SFX") end
end

-- the models of moment v (a { m = {...}, s = sound }) on unit u, until untilT
local function OnUnit(v, u, untilT)
    if not v or not u then return {} end
    local list = {}
    for _, m in ipairs(v.m or {}) do
        local att = m[2]
        local e = FX.Play(m[1], m[3] or 1, function() return AttachPoint(u, att) end, untilT)
        if e then e.unit = u list[#list + 1] = e end
    end
    Sound(v.s)
    return list
end

local function StopAll(list) for _, e in ipairs(list or {}) do FX.Stop(e) end end

local function Visible(u)
    local p = Craft.player
    return u and p and u.map == p.map and abs(u.x - p.x) < 30 and abs(u.y - p.y) < 22 and (not UI.Shown or UI.Shown(u))
end

-- casts: the precast glow while it lasts, the flash when it goes off, the channel
Craft:On("cast", function(u, id, what, target)
    local v = D.vis[id]
    if not v or not Visible(u) then return end
    if what == "start" then
        StopAll(u.fxPre)
        u.fxPre = OnUnit(v.pre, u, function() return not (u.casting and u.casting.spell == id) end)
    elseif what == "channel" then
        StopAll(u.fxPre)
        local who = (v.chan and v.chan.on == 2 and target) or u
        u.fxPre = OnUnit(v.chan, who, function() return not (u.casting and u.casting.spell == id) end)
        if v.chan and v.chan.on == 2 then OnUnit({ m = (v.pre and v.pre.m) }, u, function() return not u.casting end) end
    elseif what == "done" then
        StopAll(u.fxPre)
        u.fxPre = nil
        OnUnit(v.cast, u, Now() + 1.2)
    elseif what == "interrupted" or what == "failed" then
        StopAll(u.fxPre)
        u.fxPre = nil
    end
end)

-- missiles: the client's missile model from the caster's hand to the target's chest, turned along its flight
Craft:On("missile", function(m)
    local v = D.vis[m.spell]
    if not v or not v.mis or not (Visible(m.src) or Visible(m.dst)) then return end
    local sp = D.spells[m.spell]
    local e
    e = FX.Play(v.mis.m, v.mis.sc or 1, function()
        local dst = m.dst
        if not dst then return nil end
        local fx, fy = AttachPoint({ x = m.from[1], y = m.from[2], face = m.src.face }, 21)
        local tx, ty = AttachPoint(dst, v.mis.to or 34)
        local d = Craft.Dist(m.from[1], m.from[2], dst.x, dst.y)
        local f = min(1, (Now() - m.start) * ((sp and sp.speed) or 20) / max(0.1, d))
        local x, y = fx + (tx - fx) * f, fy + (ty - fy) * f
        -- (north is up the screen; WoW's yaw counts from north toward the west)
        return x, y, atan2(-(tx - fx), -(ty - fy))
    end, function() return m.landed or not m.dst or m.dst.dead and Now() - m.start > 3 end)
    m.fx = e
end)

-- impacts: the spell lands on its target (missiles on arrival, instants at once)
Craft:On("spellhit", function(u, id, target)
    local v = D.vis[id]
    if not v or not v.imp then return end
    local t = (v.imp.on == 1) and u or (target or u)
    if not Visible(t) then return end
    OnUnit(v.imp, t, Now() + 1.6)
end)

Craft:On("impact", function(m)
    m.landed = true
    if m.fx then FX.Stop(m.fx) m.fx = nil end
end)

-- auras with a state model (Power Word: Shield's bubble, Frostbolt's chill on the head) while they last
Craft:On("aura", function(u, a, added)
    local v = D.vis[a.spell]
    if not v or not v.aura then return end
    if added then
        if not Visible(u) then return end
        -- (a.vfx: a.fx is the aura's own effects - what it does to the stats - and must stay)
        a.vfx = OnUnit(v.aura, u, function()
            for _, x in ipairs(u.auras) do if x == a then return u.dead end end
            return true
        end)
    else
        StopAll(a.vfx)
        a.vfx = nil
    end
end)

Craft:On("teleport", function() FX.Clear() end)
Craft:On("logout", function() FX.Clear() end)

-- the level-up: WoW's golden column (spells/levelup/levelup.m2) round your feet, and its sound
function UI.LevelUpEffect(u)
    local e = FX.Play(166464, 1, function() return AttachPoint(u, 19) end, Now() + 3)
    if e then e.unit = u end
    if PlaySoundFile and Craft:Data().sfx ~= false then pcall(PlaySoundFile, 569593, "SFX") end
end
