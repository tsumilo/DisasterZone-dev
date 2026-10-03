if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Trainer/UI.lua", ...) then return end -- DisasterZone Games/Trainer/UI.lua
-- ns.TrainerUI: the Raid Trainer's panel. A toolbar (encounter, mode, start), the fight seen from behind your
-- character in a ModelScene (the game's own models, the client's own controls: W / S run, A / D turn, Q / E
-- strafe, right mouse button to look, both buttons to run, wheel to zoom), name plates, an action bar, a minimap
-- and the briefing / result overlay. Without ModelScene actors the minimap fills the view and is the game.
-- The panel takes the keyboard only while a try is running: Esc pauses and gives it back (same as Azeromon),
-- combat pauses too.
local addonName, ns = ...

local UI = ns:NewModule("TrainerUI")
local T = ns.Trainer

local floor, min, max = math.floor, math.min, math.max
local sin, cos, pi = math.sin, math.cos, math.pi

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local TOOLBAR_H, BAR_H, PAD = 30, 64, 6
local MOVE_KEYS = {
    W = "up", UP = "up", S = "down", DOWN = "down",
    A = "left", LEFT = "left", D = "right", RIGHT = "right", Q = "strafeL", E = "strafeR",
}
local MINI_W, MINI_H = 120, 150
local ANIM_STAND, ANIM_DEATH, ANIM_RUN, ANIM_DEAD, ANIM_BACK, ANIM_STUN = 0, 1, 5, 6, 13, 14
local PLATE_HEIGHT = { construct = 3.2, boss = 7 }

local root, view, arena, overlay, focusOverlay
local scene, floorFrame, plateFrame      -- the 3D view (scene == nil: flat fallback)
local cam = { dist = 14, pitch = 0.3, pitchSign = 1, mirror = 1, x = 0, y = 0, z = 0, fx = 1, fy = 0, fz = 0 }
local actors = {}            -- unit id -> actor
local actorPool = {}
local plates = {}
local floorLines, fxLines = {}, {}
local mouse = { look = false, left = false, lastX = 0 }
local R = {}                 -- widgets
local unitFrames = {}        -- pool, by index
local fxFrames = {}
local zoneFrames = {}
local labelFonts = {}
local abilityButtons = {}
local held = {}
local sim, encId, diffId
local focused = false
local px = 4                 -- pixels per yard

local function Data() return ns.Games:GetData(T.GAME_ID) end

local function Encounter() return T:GetEncounter(encId) end

---------------------------------------------------------------------------
-- Focus and keys
---------------------------------------------------------------------------

local function ApplyMove()
    if not sim then return end
    local side = (held.right and 1 or 0) - (held.left and 1 or 0)
    local fwd = (held.up and 1 or 0) - (held.down and 1 or 0)
    if not scene then
        sim:SetMove(side + (held.strafeR and 1 or 0) - (held.strafeL and 1 or 0), fwd)
        return
    end
    if mouse.look and mouse.left then fwd = 1 end                       -- both buttons: run
    local strafe = (held.strafeR and 1 or 0) - (held.strafeL and 1 or 0)
    local turn = 0
    if mouse.look then strafe = strafe + side else turn = -side end     -- looking with the mouse: A / D strafe
    sim:SetControls(fwd, max(-1, min(1, strafe)), turn)
end

local function SetFocus(on)
    focused = on and true or false
    if root then
        pcall(root.EnableKeyboard, root, focused)
        focusOverlay:SetShown(not focused and sim ~= nil and sim.state == "run")
    end
    wipe(held)
    mouse.look, mouse.left = false, false
    ApplyMove()
end

local ShowBriefing, ShowResult
local ResetScene

local function StartTry(seed)
    local enc = Encounter()
    if not enc then return end
    if ns.Games:InCombat() then ns:Print("The Raid Trainer waits until you leave combat.") return end
    sim = T:NewSim(encId, diffId, seed)
    ResetScene()
    overlay:Hide()
    R.start:SetText("Restart")
    SetFocus(true)
end

local function HandleKey(key, down)
    local dir = MOVE_KEYS[key]
    if dir then
        held[dir] = down or nil
        ApplyMove()
        return true
    end
    if not down then return false end
    if key == "TAB" then
        if sim then sim:TabTarget() end
        return true
    end
    if key == "R" or ((key == "SPACE" or key == "ENTER") and not (sim and sim.state == "run")) then
        StartTry()
        return true
    end
    if sim and sim:GetAbility(key) then
        sim:Use(key)
        return true
    end
    return false
end

local function OnKeyDown(self, key)
    if key == "ESCAPE" then
        -- the first Escape pauses and lets the keyboard go; the next one reaches the client and closes the window
        SetFocus(false)
        pcall(self.SetPropagateKeyboardInput, self, false)
        return
    end
    local used = HandleKey(key, true)
    if not InCombatLockdown() and self.SetPropagateKeyboardInput then
        pcall(self.SetPropagateKeyboardInput, self, not used)
    end
end

local function OnKeyUp(self, key)
    HandleKey(key, false)
end

---------------------------------------------------------------------------
-- The 3D view
---------------------------------------------------------------------------

-- Sim (x, y) -> scene (x, y): the scene is right-handed with z up like the world; cam.mirror flips y if the
-- client turns out to draw it the other way round (Calibrate).
local function SY(y) return cam.mirror * y end

-- Scene point -> UI units from the scene's bottom-left corner; nil when it is behind the camera.
local function Project(x, y, z)
    y = SY(y)
    local depth = (x - cam.x) * cam.fx + (y - cam.y) * cam.fy + (z - cam.z) * cam.fz
    if depth < 0.5 then return nil end
    local ok, px, py = pcall(scene.Project3DPointTo2D, scene, x, y, z)
    if not ok or type(px) ~= "number" or type(py) ~= "number" then return nil end
    local es = scene:GetEffectiveScale() or 1
    if es <= 0 then es = 1 end
    return px / es, py / es
end

-- The camera sits behind and above the character and looks where it faces.
local function PlaceCamera()
    local p = sim.player
    local yaw, pitch = cam.mirror * p.facing, cam.pitch
    cam.fx, cam.fy, cam.fz = cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), -sin(pitch)
    local tx, ty, tz = p.x, SY(p.y), 2.2
    cam.x, cam.y, cam.z = tx - cam.fx * cam.dist, ty - cam.fy * cam.dist, tz - cam.fz * cam.dist
    pcall(scene.SetCameraPosition, scene, cam.x, cam.y, cam.z)
    pcall(scene.SetCameraOrientationByYawPitchRoll, scene, yaw, cam.pitchSign * pitch, 0)
end

-- Which way the client counts pitch and which side it draws +y on is not documented: ask the projection once.
-- The point we look at must land mid-height, and a point to the character's left must land left of it.
local function Calibrate()
    local w, h = scene:GetWidth() or 0, scene:GetHeight() or 0
    if w <= 0 or h <= 0 then return end
    cam.calibrated = true
    local p = sim.player
    PlaceCamera()
    local _, cy = Project(p.x, p.y, 2.2)
    if not cy or math.abs(cy - h / 2) > h * 0.25 then
        cam.pitchSign = -cam.pitchSign
        PlaceCamera()
        local _, cy2 = Project(p.x, p.y, 2.2)
        if not cy2 or math.abs(cy2 - h / 2) > h * 0.25 then cam.pitchSign = -cam.pitchSign end   -- no better: keep
    end
    PlaceCamera()
    local cx = Project(p.x, p.y, 2.2)
    local lx = Project(p.x - sin(p.facing) * 2, p.y + cos(p.facing) * 2, 2.2)
    if cx and lx and lx > cx + 1 then cam.mirror = -cam.mirror end
    PlaceCamera()
end

local function NewActor()
    local ok, a = pcall(scene.CreateActor, scene, nil, "ModelSceneActorTemplate")
    if not ok or not a then ok, a = pcall(scene.CreateActor, scene) end
    if not ok or not a then return nil end
    pcall(a.SetUseCenterForOrigin, a, false, false, false)
    if a.SetOnModelLoadedCallback then
        -- an animation does not survive a model change: set it again once the model is there
        pcall(a.SetOnModelLoadedCallback, a, function(self) pcall(self.SetAnimation, self, self.anim or ANIM_STAND) end)
    end
    return a
end

local function ActorFor(u)
    local a = actors[u.id]
    if not a then
        a = table.remove(actorPool) or NewActor()
        if not a then return nil end
        actors[u.id] = a
        a.anim = nil               -- (a pooled actor keeps its model: the same key does not load again)
    end
    local key = u.model or u.display
    if a.key ~= key then
        a.key, a.anim = key, nil
        pcall(a.ClearModel, a)
        if u.model == "player" then
            if not (a.SetModelByUnit and pcall(a.SetModelByUnit, a, "player")) then a.noModel = true end
        elseif u.display then
            pcall(a.SetModelByCreatureDisplayID, a, u.display)
        end
    end
    return a
end

local function AnimFor(u)
    if u.dead then return ANIM_DEATH end
    if u.pose == "dead" then return ANIM_DEAD end
    for _, aura in pairs(u.auras) do
        if aura.stun then return ANIM_STUN end
    end
    if u.moving then return u.backward and ANIM_BACK or ANIM_RUN end
    return ANIM_STAND
end

local function DrawActors()
    local seen = {}
    for _, u in ipairs(sim.units) do
        local show = (u.model or u.display) and (not u.dead or sim.time - (u.diedAt or 0) < 2.5)
        if show then
            local a = ActorFor(u)
            if a then
                seen[u.id] = true
                pcall(a.SetPosition, a, u.x, SY(u.y), 0)
                pcall(a.SetYaw, a, cam.mirror * u.facing)
                pcall(a.SetAlpha, a, u.ghost and 0.8 or 1)
                local anim = AnimFor(u)
                if a.anim ~= anim then
                    a.anim = anim
                    pcall(a.SetAnimation, a, anim)
                end
                pcall(a.SetShown, a, true)
            end
        end
    end
    for id, a in pairs(actors) do
        if not seen[id] then
            pcall(a.SetShown, a, false)
            actors[id] = nil
            actorPool[#actorPool + 1] = a
        end
    end
end

local lineCount = { floor = 0, fx = 0 }

-- One world-space segment, cut at the camera's near plane, drawn as a Line over (or under) the scene.
local function Segment(pool, which, parent, x1, y1, z1, x2, y2, z2, r, g, b, a, thick)
    local function depth(x, y, z) return (x - cam.x) * cam.fx + (SY(y) - cam.y) * cam.fy + (z - cam.z) * cam.fz end
    local d1, d2 = depth(x1, y1, z1), depth(x2, y2, z2)
    local near = 0.6
    if d1 < near and d2 < near then return end
    if d1 < near then
        local k = (near - d1) / (d2 - d1)
        x1, y1, z1 = x1 + (x2 - x1) * k, y1 + (y2 - y1) * k, z1 + (z2 - z1) * k
    elseif d2 < near then
        local k = (near - d2) / (d1 - d2)
        x2, y2, z2 = x2 + (x1 - x2) * k, y2 + (y1 - y2) * k, z2 + (z1 - z2) * k
    end
    local ax, ay = Project(x1, y1, z1)
    local bx, by = Project(x2, y2, z2)
    if not (ax and bx) then return end
    local n = lineCount[which] + 1
    lineCount[which] = n
    local l = pool[n]
    if not l then
        l = parent:CreateLine(nil, "ARTWORK")
        pool[n] = l
    end
    l:SetThickness(thick or 1)
    l:SetColorTexture(r, g, b, a)
    l:SetStartPoint("BOTTOMLEFT", scene, ax, ay)
    l:SetEndPoint("BOTTOMLEFT", scene, bx, by)
    l:Show()
end

local function Circle(x, y, radius, r, g, b, a, thick)
    local n = 20
    for i = 1, n do
        local a1, a2 = (i - 1) / n * 2 * pi, i / n * 2 * pi
        Segment(fxLines, "fx", plateFrame, x + cos(a1) * radius, y + sin(a1) * radius, 0.1,
                x + cos(a2) * radius, y + sin(a2) * radius, 0.1, r, g, b, a, thick)
    end
end

-- The room: its walls and a line every 10 yd, so distance and speed read at a glance.
local function DrawFloor()
    lineCount.floor = 0
    local w, h = sim.enc.arena.w, sim.enc.arena.h
    for x = 0, w, 10 do
        local wall = x == 0 or x >= w
        Segment(floorLines, "floor", floorFrame, x, 0, 0, x, h, 0, 0.55, 0.45, 0.7, wall and 0.9 or 0.28, wall and 3 or 1)
    end
    for y = 0, h, 10 do
        local wall = y == 0 or y >= h
        Segment(floorLines, "floor", floorFrame, 0, y, 0, w, y, 0, 0.55, 0.45, 0.7, wall and 0.9 or 0.28, wall and 3 or 1)
    end
    for _, x in ipairs({ 0, w }) do                                   -- the corners stand up, so walls read as walls
        for _, y in ipairs({ 0, h }) do
            Segment(floorLines, "floor", floorFrame, x, y, 0, x, y, 8, 0.55, 0.45, 0.7, 0.9, 3)
        end
    end
    for i = lineCount.floor + 1, #floorLines do floorLines[i]:Hide() end
end

local function DrawEffects()
    lineCount.fx = 0
    local t = sim.target
    if t and not t.dead then Circle(t.x, t.y, t.radius + 0.4, 1, 0.85, 0.1, 0.9, 2) end
    for _, fx in ipairs(sim.fx) do
        local k = min(1, (sim.time - fx.at) / fx.dur)
        local c = fx.color or { 1, 1, 1 }
        if fx.kind == "ring" then
            Circle(fx.x, fx.y, fx.r * (0.3 + 0.7 * k), c[1], c[2], c[3], 1 - k, 3)
        else
            Segment(fxLines, "fx", plateFrame, fx.x, fx.y, 1.8, fx.x2, fx.y2, 1.8, c[1], c[2], c[3], 1 - k, 4)
        end
    end
    for i = lineCount.fx + 1, #fxLines do fxLines[i]:Hide() end
end

local function Plate(i)
    local f = plates[i]
    if f then return f end
    f = CreateFrame("Button", nil, plateFrame)
    f:SetSize(96, 12)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0, 0, 0, 0.75)
    ns.UI:AddEdges(f, "OVERLAY")
    f.hp = f:CreateTexture(nil, "ARTWORK")
    f.hp:SetPoint("LEFT")
    f.hp:SetHeight(12)
    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.name:SetPoint("BOTTOM", f, "TOP", 0, 2)
    f.state = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.state:SetPoint("TOP", f, "BOTTOM", 0, -1)
    f:SetScript("OnClick", function(self)
        if sim and self.unit then sim:SetTarget(self.unit) end
    end)
    plates[i] = f
    return f
end

local function StateText(u)
    for _, aura in pairs(u.auras) do
        if aura.stun then return "|cff80b0ffStunned|r" end
    end
    local lance = sim:HasAura(u, "lance")
    if lance then return string.format("|cffa0e0ffSlowed %d%%|r", floor(sim:AuraSlow(lance) * 100 + 0.5)) end
    return ""
end

local function DrawPlates()
    local n = 0
    for _, u in ipairs(sim.units) do
        local height = PLATE_HEIGHT[u.kind]
        if height and not u.dead then
            local x, y = Project(u.x, u.y, height)
            if x then
                n = n + 1
                local f = Plate(n)
                f.unit = u
                f:ClearAllPoints()
                f:SetPoint("CENTER", scene, "BOTTOMLEFT", x, y)
                f.name:SetText(u.name)
                local isTarget = sim.target == u
                ns.UI:SetEdgeColor(f, isTarget and 1 or 0, isTarget and 0.85 or 0, isTarget and 0.1 or 0, 1)
                if u.hp then
                    f.hp:SetColorTexture(0.8, 0.15, 0.15, 1)
                    f.hp:SetWidth(max(0.1, 96 * u.hp / u.hpMax))
                    f.hp:Show()
                    f.bg:Show()
                else
                    f.hp:Hide()
                    f.bg:Hide()
                    ns.UI:SetEdgeColor(f, 0, 0, 0, 0)
                end
                f.state:SetText(u.targetable and StateText(u) or "")
                f:EnableMouse(u.targetable and true or false)
                f:Show()
            end
        end
    end
    for i = n + 1, #plates do
        plates[i].unit = nil
        plates[i]:Hide()
    end
end

local function Draw3D()
    if not cam.calibrated then Calibrate() end
    PlaceCamera()
    DrawActors()
    DrawFloor()
    DrawEffects()
    DrawPlates()
end

function ResetScene()
    if not scene then return end
    cam.calibrated = false
    for id, a in pairs(actors) do
        pcall(a.SetShown, a, false)
        actors[id] = nil
        actorPool[#actorPool + 1] = a
    end
    for _, l in ipairs(floorLines) do l:Hide() end
    for _, l in ipairs(fxLines) do l:Hide() end
    for _, f in ipairs(plates) do f:Hide() end
end

local function MouseLook()
    if not (mouse.look and sim and sim.state == "run" and focused) then return end
    local x = GetCursorPosition()
    local dx = x - mouse.lastX
    mouse.lastX = x
    if dx ~= 0 then sim:Turn(-dx * 0.006) end
end

local function CreateScene(parent)
    if not parent.CreateLine then return end
    local ok, sc = pcall(CreateFrame, "ModelScene", nil, parent)
    if not ok or not sc or not sc.CreateActor or not sc.Project3DPointTo2D then return end
    scene = sc
    local probe = NewActor()
    if not probe or not probe.SetModelByCreatureDisplayID then
        scene = nil
        sc:Hide()
        return
    end
    actorPool[1] = probe
    floorFrame = CreateFrame("Frame", nil, parent)
    floorFrame:SetAllPoints()
    floorFrame:SetFrameLevel(parent:GetFrameLevel() + 1)
    sc:SetAllPoints()
    sc:SetFrameLevel(parent:GetFrameLevel() + 2)
    plateFrame = CreateFrame("Frame", nil, parent)
    plateFrame:SetAllPoints()
    plateFrame:SetFrameLevel(parent:GetFrameLevel() + 4)
    pcall(sc.SetCameraFieldOfView, sc, 1.1)
    pcall(sc.SetCameraNearClip, sc, 0.5)
    pcall(sc.SetCameraFarClip, sc, 500)
    pcall(sc.SetLightVisible, sc, true)
    pcall(sc.SetLightDirection, sc, -0.4, 0.3, -0.8)
    pcall(sc.SetLightAmbientColor, sc, 0.7, 0.7, 0.75)
    pcall(sc.SetLightDiffuseColor, sc, 0.85, 0.85, 0.85)
    sc:EnableMouse(true)
    sc:EnableMouseWheel(true)
    sc:SetScript("OnMouseDown", function(_, button)
        if button == "RightButton" then
            mouse.look, mouse.lastX = true, (GetCursorPosition())
        elseif button == "LeftButton" then
            mouse.left = true
        end
        ApplyMove()
    end)
    sc:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then mouse.look = false elseif button == "LeftButton" then mouse.left = false end
        ApplyMove()
    end)
    sc:SetScript("OnMouseWheel", function(_, delta)
        cam.dist = max(5, min(35, cam.dist - delta * 2))
    end)
end

---------------------------------------------------------------------------
-- The minimap (and, without a 3D view, the whole game)
---------------------------------------------------------------------------

local function Place(f, x, y)
    f:ClearAllPoints()
    f:SetPoint("CENTER", arena, "BOTTOMLEFT", x * px, y * px)
end

local function UnitFrame(i)
    local f = unitFrames[i]
    if f then return f end
    f = CreateFrame("Button", nil, arena)
    f:SetFrameLevel(arena:GetFrameLevel() + 5)
    f.ring = f:CreateTexture(nil, "BACKGROUND")
    f.ring:SetTexture(DISC)
    f.ring:SetVertexColor(1, 0.85, 0.1, 0.9)
    f.ring:SetPoint("TOPLEFT", -3, 3)
    f.ring:SetPoint("BOTTOMRIGHT", 3, -3)
    f.disc = f:CreateTexture(nil, "ARTWORK")
    f.disc:SetTexture(DISC)
    f.disc:SetAllPoints()
    f.hpBg = f:CreateTexture(nil, "OVERLAY")
    f.hpBg:SetColorTexture(0, 0, 0, 0.8)
    f.hpBg:SetSize(30, 4)
    f.hpBg:SetPoint("BOTTOM", f, "TOP", 0, 3)
    f.hp = f:CreateTexture(nil, "OVERLAY", nil, 1)
    f.hp:SetColorTexture(0.8, 0.15, 0.15, 1)
    f.hp:SetHeight(4)
    f.hp:SetPoint("LEFT", f.hpBg, "LEFT", 0, 0)
    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.label:SetPoint("TOP", f, "BOTTOM", 0, -1)
    f.state = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.state:SetPoint("BOTTOM", f.hpBg, "TOP", 0, 1)
    f:SetScript("OnClick", function(self)
        if sim and self.unit then sim:SetTarget(self.unit) end
    end)
    unitFrames[i] = f
    return f
end

local function DrawUnits()
    local n = 0
    for _, u in ipairs(sim.units) do
        if not u.dead then
            n = n + 1
            local f = UnitFrame(n)
            f.unit = u
            local size = max(scene and 5 or 10, u.radius * 2 * px)
            f:SetSize(size, size)
            Place(f, u.x, u.y)
            local c = u.color or { 1, 1, 1 }
            local flash = u.hitAt and (sim.time - u.hitAt) < 0.12
            if flash then f.disc:SetVertexColor(1, 1, 1, 1) else f.disc:SetVertexColor(c[1], c[2], c[3], u.ghost and 0.75 or 1) end
            f.ring:SetShown(sim.target == u)
            f:EnableMouse(u.targetable and true or false)
            local showHp = u.hp ~= nil and u.targetable and not scene
            f.hpBg:SetShown(showHp)
            f.hp:SetShown(showHp)
            if showHp then f.hp:SetWidth(max(0.1, 30 * u.hp / u.hpMax)) end
            f.label:SetText((not scene and (u.kind == "boss" or u.kind == "player")) and u.name or "")
            f.state:SetText((not scene and u.targetable) and StateText(u) or "")
            f:Show()
        end
    end
    for i = n + 1, #unitFrames do
        unitFrames[i].unit = nil
        unitFrames[i]:Hide()
    end
end

local function DrawZones()
    for i, z in ipairs(sim.zones) do
        local f = zoneFrames[i]
        if not f then
            f = CreateFrame("Frame", nil, arena)
            f:SetFrameLevel(arena:GetFrameLevel() + 2)
            f.disc = f:CreateTexture(nil, "BACKGROUND")
            f.disc:SetTexture(DISC)
            f.disc:SetAllPoints()
            f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            f.label:SetPoint("BOTTOM", f, "TOP", 0, 1)
            f.dots = {}
            zoneFrames[i] = f
        end
        local c = z.color or { 0.3, 0.6, 1 }
        f:SetSize(z.r * 2 * px, z.r * 2 * px)
        Place(f, z.x, z.y)
        f.disc:SetVertexColor(c[1], c[2], c[3], 0.22)
        f.label:SetText(z.label or "")
        -- the raid: a fixed sunflower of dots, so it reads as a group of players
        for d = 1, (z.dots or 0) do
            local dot = f.dots[d]
            if not dot then
                dot = f:CreateTexture(nil, "ARTWORK")
                dot:SetTexture(DISC)
                f.dots[d] = dot
            end
            local rr = z.r * 0.85 * math.sqrt(d / z.dots) * px
            local ang = d * 2.39996
            dot:SetSize(max(5, 1.6 * px), max(5, 1.6 * px))
            dot:SetVertexColor(c[1] + 0.2, c[2] + 0.2, c[3], 0.95)
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", f, "CENTER", math.cos(ang) * rr, math.sin(ang) * rr)
            dot:Show()
        end
        f:Show()
    end
    for i = #sim.zones + 1, #zoneFrames do zoneFrames[i]:Hide() end
end

local function DrawFx()
    local n = 0
    for _, fx in ipairs(sim.fx) do
        n = n + 1
        local f = fxFrames[n]
        if not f then
            f = CreateFrame("Frame", nil, arena)
            f:SetFrameLevel(arena:GetFrameLevel() + 3)
            f.disc = f:CreateTexture(nil, "ARTWORK")
            f.disc:SetTexture(DISC)
            f.disc:SetAllPoints()
            if f.CreateLine then f.line = f:CreateLine(nil, "OVERLAY") end
            fxFrames[n] = f
        end
        local k = min(1, (sim.time - fx.at) / fx.dur)
        local c = fx.color or { 1, 1, 1 }
        if fx.kind == "ring" then
            local size = fx.r * 2 * px * (0.4 + 0.6 * k)
            f:SetSize(size, size)
            Place(f, fx.x, fx.y)
            f.disc:SetVertexColor(c[1], c[2], c[3], 0.45 * (1 - k))
            f.disc:Show()
            if f.line then f.line:Hide() end
        else
            f:SetSize(1, 1)
            Place(f, fx.x, fx.y)
            f.disc:Hide()
            if f.line then
                f.line:SetThickness(3)
                f.line:SetColorTexture(c[1], c[2], c[3], 1 - k)
                f.line:SetStartPoint("BOTTOMLEFT", arena, fx.x * px, fx.y * px)
                f.line:SetEndPoint("BOTTOMLEFT", arena, fx.x2 * px, fx.y2 * px)
                f.line:Show()
            end
        end
        f:Show()
    end
    for i = n + 1, #fxFrames do fxFrames[i]:Hide() end
end

local function DrawCorpse()
    local c = sim.corpse
    R.corpse:SetShown(c ~= nil)
    if c then
        R.corpse:ClearAllPoints()
        R.corpse:SetPoint("CENTER", arena, "BOTTOMLEFT", c.x * px, c.y * px)
    end
end

local function DrawHud()
    R.objective:SetText(sim.objective or "")
    local bar = sim.bars[1]
    R.timer:SetShown(bar ~= nil)
    if bar then
        local c = bar.color or { 1, 1, 1 }
        R.timer.fill:SetColorTexture(c[1], c[2], c[3], 0.9)
        R.timer.fill:SetWidth(max(0.1, R.timer:GetWidth() * bar.remain / bar.total))
        R.timer.text:SetText(string.format("%s  %.0f", bar.label, bar.remain))
    end
    local b = sim.banner
    if b and sim.time - b.at < b.dur then
        R.banner:SetText(b.text)
        R.banner:SetTextColor(b.color[1], b.color[2], b.color[3])
        R.banner:SetAlpha(min(1, (b.dur - (sim.time - b.at)) / 0.6))
        R.banner:Show()
    else
        R.banner:Hide()
    end
    local e = sim.error
    if e and sim.time - e.at < 1.5 then
        R.error:SetText(e.text)
        R.error:Show()
    else
        R.error:Hide()
    end
    for _, btn in ipairs(abilityButtons) do
        if btn.ab then
            local remain = sim:Cooldown(btn.ab)
            local usable = not btn.ab.usable or btn.ab.usable(sim)
            btn.icon:SetDesaturated(not usable)
            btn.shade:SetShown(remain > 0 or not usable)
            btn.cd:SetText(remain >= 1.05 and string.format("%d", remain + 0.5) or "")
        end
    end
end

local function Draw()
    if not sim then return end
    if scene then Draw3D() end
    DrawZones()
    DrawUnits()
    if not scene then DrawFx() end
    DrawCorpse()
    DrawHud()
end

local function LayoutArena()
    local enc = Encounter()
    if not (enc and root) then return end
    local w, h = root:GetWidth() or 0, root:GetHeight() or 0
    local availW, availH = w - PAD * 2, h - TOOLBAR_H - BAR_H - PAD * 3
    if availW <= 0 or availH <= 0 then return end
    view:SetSize(availW, availH)
    if scene then
        px = min(MINI_W / enc.arena.w, MINI_H / enc.arena.h)
    else
        px = max(1, min(availW / enc.arena.w, availH / enc.arena.h))
    end
    arena:SetSize(enc.arena.w * px, enc.arena.h * px)
    local labels = scene and {} or enc.arena.labels or {}
    for i, l in ipairs(labels) do
        local fs = labelFonts[i]
        if not fs then
            fs = arena:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
            labelFonts[i] = fs
        end
        fs:SetText(l.text)
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", arena, "BOTTOMLEFT", l.x * px, l.y * px)
        fs:Show()
    end
    for i = #labels + 1, #labelFonts do labelFonts[i]:Hide() end
    Draw()
end

local function LayoutAbilities()
    local enc = Encounter()
    local list = enc and enc.abilities or {}
    for i, ab in ipairs(list) do
        local b = abilityButtons[i]
        if not b then
            b = CreateFrame("Button", nil, R.bar)
            b:SetSize(40, 40)
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetAllPoints()
            b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            ns.UI:AddEdges(b, "OVERLAY")
            ns.UI:SetEdgeColor(b, 0, 0, 0, 1)
            b.shade = b:CreateTexture(nil, "OVERLAY")
            b.shade:SetAllPoints()
            b.shade:SetColorTexture(0, 0, 0, 0.6)
            b.cd = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            b.cd:SetPoint("CENTER")
            b.key = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
            b.key:SetPoint("TOPRIGHT", -2, -2)
            b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.name:SetPoint("TOP", b, "BOTTOM", 0, -2)
            b:SetScript("OnClick", function(self)
                if sim and self.ab then sim:Use(self.ab.id) end
            end)
            b:SetScript("OnEnter", function(self)
                if self.ab then ns.UI:SetTextTooltip(self, { self.ab.name .. "  (" .. self.ab.key .. ")", self.ab.tip }) end
            end)
            b:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
            abilityButtons[i] = b
        end
        b.ab = ab
        b.icon:SetTexture(ab.icon)
        b.key:SetText(ab.key)
        b.name:SetText(ab.name)
        b.shade:Hide()
        b.cd:SetText("")
        b:ClearAllPoints()
        b:SetPoint("TOP", R.bar, "TOP", (i - (#list + 1) / 2) * 88, -2)
        b:Show()
    end
    for i = #list + 1, #abilityButtons do
        abilityButtons[i].ab = nil
        abilityButtons[i]:Hide()
    end
end

---------------------------------------------------------------------------
-- Briefing / result overlay
---------------------------------------------------------------------------

local function BestLine()
    local enc = Encounter()
    local rec = Data().enc and Data().enc[encId] and Data().enc[encId][diffId]
    if not (rec and rec.bestScore) then return "|cff888888No clear yet on this difficulty.|r" end
    return string.format("Best: |cffffd100%d|r points, fastest clear %.1f sec (%d of %d tries).",
        rec.bestScore, rec.bestTime or 0, rec.clears or 0, rec.tries or 0)
end

function ShowBriefing()
    local enc = Encounter()
    if not enc then return end
    overlay.title:SetText(enc.name)
    overlay.title:SetTextColor(1, 0.82, 0.2)
    local lines = {}
    for i, l in ipairs(enc.howTo or { enc.desc }) do lines[#lines + 1] = i .. ". " .. l end
    lines[#lines + 1] = ""
    if scene then
        lines[#lines + 1] = "W / S run, A / D turn, Q / E strafe. Hold the right mouse button to look, wheel to zoom."
        lines[#lines + 1] = "Tab or a click on a name plate targets. Esc pauses."
    else
        lines[#lines + 1] = "Move: WASD or the arrow keys. Target: Tab or click. Esc pauses."
    end
    lines[#lines + 1] = BestLine()
    overlay.body:SetText(table.concat(lines, "\n"))
    overlay.go:SetText("Start  (Space)")
    overlay:Show()
    focusOverlay:Hide()
end

function ShowResult(score, best)
    local enc = Encounter()
    local won = sim.state == "won"
    overlay.title:SetText(won and "Constructs down!" or "Wipe")
    if enc.resultTitle then overlay.title:SetText(enc.resultTitle(sim)) end
    if won then overlay.title:SetTextColor(0.4, 0.9, 0.4) else overlay.title:SetTextColor(0.95, 0.3, 0.3) end
    local lines = {}
    if not won and sim.reason then lines[#lines + 1] = sim.reason end
    for _, l in ipairs(enc.summary and enc.summary(sim) or {}) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Score: |cffffd100%d|r%s", score, best and "  |cff5fd35fNew best!|r" or "")
    lines[#lines + 1] = BestLine()
    overlay.body:SetText(table.concat(lines, "\n"))
    overlay.go:SetText("Try again  (Space)")
    overlay:Show()
    focusOverlay:Hide()
end

local function OnUpdate(self, elapsed)
    if not sim then return end
    if sim.state == "run" and focused then
        MouseLook()
        sim:Update(elapsed)
        if sim.state ~= "run" then
            local score, best = T:Finish(sim)
            wipe(held)
            Draw()
            ShowResult(score, best)
            return
        end
    end
    Draw()
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function PickDifficulty(enc)
    diffId = T:GetDifficulty(enc, Data().diff and Data().diff[enc.id]).id
end

local function SelectEncounter(id)
    local enc = T:GetEncounter(id)
    if not enc then return end
    encId = id
    Data().last = id
    PickDifficulty(enc)
    sim = nil
    SetFocus(false)
    ResetScene()
    for _, f in ipairs(unitFrames) do f:Hide() end
    for _, f in ipairs(fxFrames) do f:Hide() end
    for _, f in ipairs(zoneFrames) do f:Hide() end
    R.corpse:Hide()
    R.timer:Hide()
    R.banner:Hide()
    R.error:Hide()
    R.objective:SetText("")
    R.start:SetText("Start")
    R.encounter:Refresh()
    R.difficulty:Refresh()
    LayoutAbilities()
    LayoutArena()
    ShowBriefing()
end

local function SelectDifficulty(id)
    local enc = Encounter()
    if not enc then return end
    diffId = T:GetDifficulty(enc, id).id
    local d = Data()
    if type(d.diff) ~= "table" then d.diff = {} end
    d.diff[enc.id] = diffId
    SelectEncounter(enc.id)
end

function UI:CreatePanel(parent)
    root = CreateFrame("Frame", nil, parent)

    R.encounter = ns.UI:CreateSleekDropdown(root, 170, function()
        local out = {}
        for _, e in ipairs(T:GetEncounters()) do out[#out + 1] = { text = e.name, value = e.id } end
        return out
    end, function() return encId end, SelectEncounter)
    R.encounter:SetPoint("TOPLEFT", PAD, -PAD)

    R.difficulty = ns.UI:CreateSleekDropdown(root, 150, function()
        local out, enc = {}, Encounter()
        for _, d in ipairs(enc and enc.difficulties or {}) do out[#out + 1] = { text = d.name, value = d.id } end
        return out
    end, function() return diffId end, SelectDifficulty)
    R.difficulty:SetPoint("LEFT", R.encounter, "RIGHT", 6, 0)

    R.start = ns.UI:CreateSleekButton(root, "Start", 80, 22, function() StartTry() end, "primary")
    R.start:SetPoint("LEFT", R.difficulty, "RIGHT", 6, 0)

    R.objective = ns.UI:CreateLabel(root, "", "GameFontHighlightSmall")
    R.objective:SetPoint("LEFT", R.start, "RIGHT", 10, 0)
    R.objective:SetPoint("RIGHT", root, "RIGHT", -PAD, 0)
    R.objective:SetJustifyH("LEFT")

    view = CreateFrame("Frame", nil, root)
    view:SetPoint("TOP", root, "TOP", 0, -(TOOLBAR_H + PAD))
    view:SetSize(280, 360)
    local viewBg = view:CreateTexture(nil, "BACKGROUND")
    viewBg:SetAllPoints()
    viewBg:SetColorTexture(0.05, 0.04, 0.07, 1)
    ns.UI:AddEdges(view)
    ns.UI:SetEdgeColor(view, 0.4, 0.3, 0.5, 1)
    view:SetClipsChildren(true)
    CreateScene(view)

    arena = CreateFrame("Frame", nil, view)
    arena:SetFrameLevel(view:GetFrameLevel() + 6)
    if scene then arena:SetPoint("TOPRIGHT", view, "TOPRIGHT", -6, -6) else arena:SetPoint("CENTER") end
    arena:SetSize(MINI_W, MINI_H)
    local floorTex = arena:CreateTexture(nil, "BACKGROUND")
    floorTex:SetAllPoints()
    floorTex:SetColorTexture(0.09, 0.08, 0.11, scene and 0.8 or 1)
    ns.UI:AddEdges(arena)
    ns.UI:SetEdgeColor(arena, 0.4, 0.3, 0.5, 1)
    arena:SetClipsChildren(true)

    R.corpse = arena:CreateTexture(nil, "ARTWORK")
    R.corpse:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    R.corpse:SetSize(18, 18)
    R.corpse:Hide()

    R.timer = CreateFrame("Frame", nil, view)
    R.timer:SetFrameLevel(view:GetFrameLevel() + 8)
    R.timer:SetSize(200, 14)
    R.timer:SetPoint("TOP", view, "TOP", 0, -6)
    local tbg = R.timer:CreateTexture(nil, "BACKGROUND")
    tbg:SetAllPoints()
    tbg:SetColorTexture(0, 0, 0, 0.7)
    R.timer.fill = R.timer:CreateTexture(nil, "ARTWORK")
    R.timer.fill:SetPoint("LEFT")
    R.timer.fill:SetHeight(14)
    R.timer.text = R.timer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    R.timer.text:SetPoint("CENTER")
    R.timer:Hide()

    local hud = CreateFrame("Frame", nil, view)
    hud:SetAllPoints()
    hud:SetFrameLevel(view:GetFrameLevel() + 8)
    R.banner = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    R.banner:SetPoint("TOP", R.timer, "BOTTOM", 0, -8)
    R.banner:SetWidth(420)
    R.banner:Hide()
    R.error = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    R.error:SetTextColor(1, 0.2, 0.2)
    R.error:SetPoint("BOTTOM", view, "BOTTOM", 0, 26)
    R.error:Hide()

    R.bar = CreateFrame("Frame", nil, root)
    R.bar:SetPoint("TOP", view, "BOTTOM", 0, -PAD)
    R.bar:SetSize(460, BAR_H)

    -- briefing / result
    overlay = CreateFrame("Frame", nil, root)
    overlay:SetAllPoints(view)
    overlay:SetFrameLevel(view:GetFrameLevel() + 30)
    overlay:EnableMouse(true)
    local dim = overlay:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints()
    dim:SetColorTexture(0, 0, 0, 0.82)
    overlay.title = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    overlay.title:SetPoint("TOP", 0, -24)
    overlay.body = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    overlay.body:SetPoint("TOPLEFT", 16, -64)
    overlay.body:SetPoint("TOPRIGHT", -16, -64)
    overlay.body:SetJustifyH("LEFT")
    overlay.body:SetSpacing(4)
    overlay.go = ns.UI:CreateSleekButton(overlay, "Start  (Space)", 150, 26, function() StartTry() end, "primary")
    overlay.go:SetPoint("BOTTOM", 0, 20)

    -- paused
    focusOverlay = CreateFrame("Button", nil, root)
    focusOverlay:SetAllPoints(view)
    focusOverlay:SetFrameLevel(view:GetFrameLevel() + 28)
    local fdim = focusOverlay:CreateTexture(nil, "BACKGROUND")
    fdim:SetAllPoints()
    fdim:SetColorTexture(0, 0, 0, 0.55)
    local fl = focusOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fl:SetText("PAUSED")
    fl:SetPoint("CENTER")
    local fl2 = focusOverlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fl2:SetText("Click to go on. Esc pauses; Esc again closes DisasterZone.")
    fl2:SetPoint("TOP", fl, "BOTTOM", 0, -6)
    fl2:SetWidth(360)
    focusOverlay:SetScript("OnClick", function()
        if InCombatLockdown() then ns:Print("The Raid Trainer waits until you leave combat.") return end
        SetFocus(true)
    end)
    focusOverlay:Hide()

    root:SetScript("OnKeyDown", OnKeyDown)
    root:SetScript("OnKeyUp", OnKeyUp)
    root:SetScript("OnUpdate", OnUpdate)
    root:SetScript("OnSizeChanged", LayoutArena)
    root:SetScript("OnHide", function() SetFocus(false) end)
    root.OnGameShown = function() LayoutArena() end
    root.OnGameHidden = function() SetFocus(false) end

    local encs = T:GetEncounters()
    local first = T:GetEncounter(Data().last) or encs[1]
    if first then SelectEncounter(first.id) end
    return root
end

function UI:OnInit()
    ns:On("GAMES_COMBAT", function(inCombat)
        if inCombat then SetFocus(false) end
    end)
end

-- Tests
UI._Key = function(key, down) return HandleKey(key, down ~= false) end
UI._Sim = function() return sim end
UI._Mouse = function(look, left) mouse.look, mouse.left = look and true or false, left and true or false ApplyMove() end
UI._Camera = function() return cam end
UI._Actor = function(unitId) return actors[unitId] end
UI._Start = function(seed) StartTry(seed) end
UI._Select = function(enc, diff)
    SelectEncounter(enc)
    if diff then SelectDifficulty(diff) end
end
UI._Tick = function(elapsed) if root then OnUpdate(root, elapsed) end end
UI._State = function()
    return {
        focused = focused, enc = encId, diff = diffId,
        overlay = overlay and overlay:IsShown() and overlay.title:GetText() or false,
        body = overlay and overlay:IsShown() and overlay.body:GetText() or false,
        paused = focusOverlay and focusOverlay:IsShown() or false,
        is3D = scene ~= nil, actors = (function() local n = 0 for _ in pairs(actors) do n = n + 1 end return n end)(),
        plates = (function() local n = 0 for _, f in ipairs(plates) do if f:IsShown() then n = n + 1 end end return n end)(),
        state = sim and sim.state or false, phase = sim and sim.phase or false,
    }
end
