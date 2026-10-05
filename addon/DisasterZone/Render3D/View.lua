if DisasterZoneBoot and DisasterZoneBoot.Run("Render3D/View.lua", ...) then return end -- DisasterZone Render3D/View.lua
-- ns.Render3D.NewView(parent, opts): a 3D view inside a frame, shared by the Raid Trainer and the strategy board.
-- One ModelScene (the game's own models), a room renderer under it (Render3D/Room.lua, its cluster frames between the
-- floor frame and the scene), a frame for flat floors under the room and one for labels and plates over everything,
-- the camera, model actors and the cursor. The client does not document which way its pitch counts or which side it
-- draws +y on: Calibrate asks the projection once.
--
-- Coordinates: callers work in room ("arena") coordinates, x east, y north, z up, in yards. The scene is the same
-- with y multiplied by cam.mirror (+1 or -1, found by Calibrate); cam.x, y, z and cam.fx, fy, fz (the view direction)
-- are kept in scene coordinates, as Room.BeginFrame reads them.
local _, ns = ...

local R3 = ns.Render3D or {}
ns.Render3D = R3

local cos, sin, abs = math.cos, math.sin, math.abs

-- Frame levels above the parent's own. The room's cluster frames take room0 .. room0 + 199 (Room.lua), all under the
-- single ModelScene; the copies of the room that hide the models sit just above it (copy0 ..); plates and labels
-- above all that, then whatever the caller lays over the view (arena, hud, focus, overlay: the trainer's).
R3.LV = { floor = 1, lines = 2, room0 = 3, scene = 210, copy0 = 211, plates = 250, arena = 252, hud = 253,
          focus = 268, overlay = 270 }

local View = {}
View.__index = View

-- parent: the view's frame (the caller sets its size and clipping). opts: cam (the camera table to use; fields are
-- added), room (a renderer from R3.NewRoom; nil makes one, false none), label (the renderer's name in messages),
-- lv (frame levels, default R3.LV; with lv.scene2 a second ModelScene there, over the first one's copies: what
-- stands nearest - the strategy board's walking character - with its own copies at lv.copy2), near (the scene's near
-- clip, 0.5), fov (1.1), far (500), anim (the animation a loaded model plays when its actor has none set, 0 = stand).
-- -> the view, or nil when the client has no ModelScene that can show creatures (the caller falls back to something
-- flat).
function R3.NewView(parent, opts)
    opts = opts or {}
    if not parent.CreateLine then return nil end
    local ok, sc = pcall(CreateFrame, "ModelScene", nil, parent)
    if not ok or not sc or not sc.CreateActor or not sc.Project3DPointTo2D then return nil end
    local v = setmetatable({ parent = parent, scene = sc, lv = opts.lv or R3.LV, near = opts.near or 0.5,
                             cam = opts.cam or {}, anim = opts.anim or 0 }, View)
    local cam = v.cam
    cam.mirror, cam.pitchSign = cam.mirror or 1, cam.pitchSign or 1
    cam.x, cam.y, cam.z = cam.x or 0, cam.y or 0, cam.z or 0
    cam.fx, cam.fy, cam.fz = cam.fx or 1, cam.fy or 0, cam.fz or 0
    local probe = v:NewActor()
    if not probe or not probe.SetModelByCreatureDisplayID then
        sc:Hide()
        return nil
    end
    v.probe = probe                                   -- (an actor ready for the caller's pool)
    local base = parent:GetFrameLevel()
    v.floorFrame = CreateFrame("Frame", nil, parent)
    v.floorFrame:SetAllPoints()
    v.floorFrame:SetFrameLevel(base + v.lv.floor)
    sc:SetAllPoints()
    sc:SetFrameLevel(base + v.lv.scene)               -- over the room's frames (Room.lua makes those)
    v.plateFrame = CreateFrame("Frame", nil, parent)
    v.plateFrame:SetAllPoints()
    v.plateFrame:SetFrameLevel(base + v.lv.plates)
    if opts.room ~= false then
        v.room = opts.room or (R3.NewRoom and R3.NewRoom(opts.label)) or nil
        if v.room then v.room.Attach(parent, sc, v.lv, v.near) end
    end
    local scenes = { sc }
    if v.lv.scene2 then
        local ok2, sc2 = pcall(CreateFrame, "ModelScene", nil, parent)
        if ok2 and sc2 and sc2.CreateActor then
            sc2:SetAllPoints()
            sc2:SetFrameLevel(base + v.lv.scene2)
            v.scene2 = sc2
            scenes[2] = sc2
        end
    end
    v.fov, v.far = opts.fov or 1.1, opts.far or 500
    for _, s in ipairs(scenes) do v:SetupScene(s) end
    return v
end

-- A scene's lens and light (every scene of the view the same).
function View:SetupScene(s)
    pcall(s.SetCameraFieldOfView, s, self.fov)
    pcall(s.SetCameraNearClip, s, self.near)
    pcall(s.SetCameraFarClip, s, self.far)
    pcall(s.SetLightVisible, s, true)
    pcall(s.SetLightDirection, s, -0.4, 0.3, -0.8)
    pcall(s.SetLightAmbientColor, s, 0.7, 0.7, 0.75)
    pcall(s.SetLightDiffuseColor, s, 0.85, 0.85, 0.85)
end

-- The backdrop: a third ModelScene under every room piece (at lv.floor), made when first asked for. A model there is
-- hidden by all of the room and seen only where nothing of it is drawn - for a creature far bigger than the room's
-- pieces that stands beyond them (Kil'jaeden over the Sunwell's edge), which no plane through it can sort.
function View:Backdrop()
    if self.scene0 == nil then
        local ok, s = pcall(CreateFrame, "ModelScene", nil, self.parent)
        if ok and s and s.CreateActor then
            s:SetAllPoints()
            s:SetFrameLevel(self.parent:GetFrameLevel() + self.lv.floor)
            self:SetupScene(s)
            self.scene0 = s
            if self.yaw then self:ApplyCamera(self.yaw, self.pitch) end
        else
            self.scene0 = false
        end
    end
    return self.scene0 or nil
end

-- Room y -> scene y.
function View:SY(y) return self.cam.mirror * y end

-- Hands the camera in self.cam (x, y, z and the view direction, scene coordinates) to the scene, looking along
-- scene yaw `yaw` (radians; the room's heading times cam.mirror) and `pitch` (positive looks down).
function View:ApplyCamera(yaw, pitch)
    local sc, cam = self.scene, self.cam
    pcall(sc.SetCameraPosition, sc, cam.x, cam.y, cam.z)
    pcall(sc.SetCameraOrientationByYawPitchRoll, sc, yaw, cam.pitchSign * pitch, 0)
    self.yaw, self.pitch = yaw, pitch
    local sc0 = self.scene0
    if sc0 then
        pcall(sc0.SetCameraPosition, sc0, cam.x, cam.y, cam.z)
        pcall(sc0.SetCameraOrientationByYawPitchRoll, sc0, yaw, cam.pitchSign * pitch, 0)
    end
    local sc2 = self.scene2
    if sc2 then
        pcall(sc2.SetCameraPosition, sc2, cam.x, cam.y, cam.z)
        pcall(sc2.SetCameraOrientationByYawPitchRoll, sc2, yaw, cam.pitchSign * pitch, 0)
    end
    for s in pairs(self.sliceList or {}) do
        pcall(s.SetCameraPosition, s, cam.x, cam.y, cam.z)
        pcall(s.SetCameraOrientationByYawPitchRoll, s, yaw, cam.pitchSign * pitch, 0)
    end
end

-- Puts the camera `dist` yards back from the room point (x, y, z), looking at it along the room heading `heading`
-- (0 = east, pi / 2 = north) and `pitch` (positive looks down).
function View:Orbit(x, y, z, heading, pitch, dist)
    local cam = self.cam
    local yaw = cam.mirror * heading
    cam.fx, cam.fy, cam.fz = cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), -sin(pitch)
    cam.x, cam.y, cam.z = x - cam.fx * dist, self:SY(y) - cam.fy * dist, z - cam.fz * dist
    self:ApplyCamera(yaw, pitch)
end

-- A room point -> UI units from the scene's bottom-left corner; nil when it is behind the camera (nearer than the
-- near clip) or the client gives nothing.
function View:Project(x, y, z)
    local cam, sc = self.cam, self.scene
    y = self:SY(y)
    local depth = (x - cam.x) * cam.fx + (y - cam.y) * cam.fy + (z - cam.z) * cam.fz
    if depth < self.near then return nil end
    local ok, px, py = pcall(sc.Project3DPointTo2D, sc, x, y, z)
    if not ok or type(px) ~= "number" or type(py) ~= "number" then return nil end
    local es = sc:GetEffectiveScale() or 1
    if es <= 0 then es = 1 end
    return px / es, py / es
end

-- Which way the client counts pitch and which side it draws +y on: place() puts the camera (reading cam.pitchSign
-- and cam.mirror) so that it looks at the room point (tx, ty, tz); (lx, ly, lz) is a point to the left of that
-- line of sight. The point looked at must land mid-height, the point to the left left of it. -> false when the view
-- has no size yet (try again later).
function View:Calibrate(place, tx, ty, tz, lx, ly, lz)
    local w, h = self.scene:GetWidth() or 0, self.scene:GetHeight() or 0
    if w <= 0 or h <= 0 then return false end
    local cam = self.cam
    place()
    local _, cy = self:Project(tx, ty, tz)
    if not cy or abs(cy - h / 2) > h * 0.25 then
        cam.pitchSign = -cam.pitchSign
        place()
        local _, cy2 = self:Project(tx, ty, tz)
        if not cy2 or abs(cy2 - h / 2) > h * 0.25 then cam.pitchSign = -cam.pitchSign end   -- no better: keep
    end
    place()
    local cx = self:Project(tx, ty, tz)
    local left = self:Project(lx, ly, lz)
    if cx and left and left > cx + 1 then cam.mirror = -cam.mirror end
    place()
    return true
end

-- A new model actor (nil when the client makes none). Its feet are its origin; an animation does not survive a model
-- change, so a loaded model plays the actor's .anim again (else the view's default).
function View:NewActor(top)
    local sc = (top == "back" and self:Backdrop()) or (top == true and self.scene2) or self.scene
    local ok, a = pcall(sc.CreateActor, sc, nil, "ModelSceneActorTemplate")
    if not ok or not a then ok, a = pcall(sc.CreateActor, sc) end
    if not ok or not a then return nil end
    if top ~= "back" then self:Fan(a) end
    pcall(a.SetUseCenterForOrigin, a, false, false, false)
    if a.SetOnModelLoadedCallback then
        local default = self.anim
        pcall(a.SetOnModelLoadedCallback, a, function(actor)
            -- (the model's own origin at the actor's position, asked again with every model: the client centred
            -- big lopsided ones sideways on it - Kil'jaeden's box centre is 29 yd from his origin)
            pcall(actor.SetUseCenterForOrigin, actor, false, false, false)
            actor.loadedOnce = true                     -- (its own box can be asked now: UI/StrategyMap3D.lua)
            pcall(actor.SetAnimation, actor, actor.anim or default)
        end)
    end
    return a
end

---------------------------------------------------------------------------
-- Depth slices (Room.SetSlices): K more ModelScenes, each clipped to one band of depth and stacked between the room's
-- bands; every actor of the scene and scene2 has a copy (a mirror) in each, and what is done to the actor is done to
-- its mirrors (Fan). The actors' own scenes are then not shown (alpha 0: they still measure the camera).
---------------------------------------------------------------------------

local FAN = { "SetModelByCreatureDisplayID", "SetModelByUnit", "SetModelByFileID", "ClearModel",
              "SetUseCenterForOrigin", "SetScale", "SetPosition", "SetYaw", "SetPitch", "SetRoll", "SetAlpha",
              "SetShown", "Show", "Hide", "SetAnimation" }
local MODEL_SET = { SetModelByCreatureDisplayID = true, SetModelByUnit = true, SetModelByFileID = true,
                    ClearModel = true }

-- The actor's calls go on to its mirrors too; the last of each is kept for a mirror made later.
function View:Fan(a)
    self.fanned = self.fanned or {}
    self.fanned[#self.fanned + 1] = a
    a.mirrors, a.last = {}, {}
    for _, name in ipairs(FAN) do
        local orig = a[name]
        if orig then
            a[name] = function(actor, ...)
                if MODEL_SET[name] then
                    actor.modelCall = { name, ... }
                else
                    actor.last[name] = { ... }
                end
                if name == "SetAnimation" then actor.anim = ... end
                for _, m in pairs(actor.mirrors) do
                    local f = m[name]
                    if f then pcall(f, m, ...) end
                end
                return orig(actor, ...)
            end
        end
    end
end

local REPLAY = { "SetUseCenterForOrigin", "SetScale", "SetPosition", "SetYaw", "SetPitch", "SetRoll", "SetAlpha",
                 "SetShown", "SetAnimation" }

-- A ModelScene for the slices (from the view's pool: made once, reused).
function View:SliceScene()
    self.scenePool = self.scenePool or {}
    local s = table.remove(self.scenePool)
    if not s then
        local ok, sc = pcall(CreateFrame, "ModelScene", nil, self.parent)
        if not (ok and sc and sc.CreateActor) then return nil end
        sc:SetAllPoints()
        self:SetupScene(sc)
        s = sc
    end
    self.sliceList = self.sliceList or {}
    self.sliceList[s] = true
    if self.yaw then
        local cam = self.cam
        pcall(s.SetCameraPosition, s, cam.x, cam.y, cam.z)
        pcall(s.SetCameraOrientationByYawPitchRoll, s, self.yaw, cam.pitchSign * self.pitch, 0)
    end
    return s
end

-- Actor a's mirror for band i, in a scene of its own (a.sliceScenes[i]): a model scene does not sort a small model in
-- front of a big scaled one behind it (Brutallus, 30 yd further, was drawn over you), so every model has its own
-- scenes and the view layers them by distance (SetSliceClips). Made with what was done to a so far.
function View:Mirror(a, i)
    local m = a.mirrors[i]
    if m then return m end
    a.sliceScenes = a.sliceScenes or {}
    local sc = a.sliceScenes[i] or self:SliceScene()
    if not sc then return nil end
    a.sliceScenes[i] = sc
    local ok, mm = pcall(sc.CreateActor, sc, nil, "ModelSceneActorTemplate")
    if not ok or not mm then ok, mm = pcall(sc.CreateActor, sc) end
    if not ok or not mm then return nil end
    m = mm
    a.mirrors[i] = m
    local default = self.anim
    if m.SetOnModelLoadedCallback then
        pcall(m.SetOnModelLoadedCallback, m, function(actor)
            pcall(actor.SetUseCenterForOrigin, actor, false, false, false)
            -- (all copies start the animation again together, so the slices stay in step)
            if a.SetAnimation then pcall(a.SetAnimation, a, a.anim or default) end
        end)
    end
    local mc = a.modelCall
    if mc and m[mc[1]] then pcall(m[mc[1]], m, unpack(mc, 2)) end
    for _, name in ipairs(REPLAY) do
        local args = a.last[name]
        if args and m[name] then pcall(m[name], m, unpack(args)) end
    end
    if not a.last.SetShown and m.SetShown then pcall(m.SetShown, m, true) end
    return m
end

-- Is the actor shown (as its own calls last said)?
local function Shown(a)
    local sh = a.last and a.last.SetShown
    if sh then return sh[1] and true or false end
    if a.last and a.last.Hide and not a.last.Show then return false end
    return a.modelCall ~= nil
end

-- K bands (K < 2: none): the shown actors mirrored into scenes of their own for each band; the actors' own scenes draw
-- nothing while they are on. -> K, and the number of shown actors (model scenes per band).
function View:SetSlices(K)
    K = (K and K > 1) and K or 0
    local n = 0
    for _, a in ipairs(self.fanned or {}) do
        local on = K > 1 and Shown(a)
        if on then n = n + 1 end
        for i = 1, K do
            if on then
                local m = self:Mirror(a, i)
                if m then pcall(m.SetShown, m, true) end
            end
            local sc = a.sliceScenes and a.sliceScenes[i]
            if sc then sc:SetShown(on and true or false) end
        end
        for i, sc in pairs(a.sliceScenes or {}) do
            if i > K then sc:Hide() end
        end
    end
    local on = K > 1
    if on ~= self.slicing then
        self.slicing = on
        -- (the actors' own scenes draw nothing while slicing: alpha 0, and - in case the client draws a model scene
        -- whatever its alpha - clipped to an empty depth range; they still measure the camera)
        for _, sc in ipairs({ self.scene, self.scene2 }) do
            pcall(sc.SetAlpha, sc, on and 0 or 1)
            if on then
                pcall(sc.SetCameraNearClip, sc, 0.01)
                pcall(sc.SetCameraFarClip, sc, 0.011)
            else
                pcall(sc.SetCameraNearClip, sc, self.near)
                pcall(sc.SetCameraFarClip, sc, self.far)
            end
        end
    end
    return K, n
end

-- Particles (glows, flames) are not cut by a scene's clips: shown in every slice they add up K times (Brutallus went
-- white). Each actor keeps them in the one slice that holds its middle (depth d, yd along the view axis), none in the
-- others - when the client has SetParticleOverrideScale. -> whether it has.
function View:SliceParticles(a, d, cuts)
    local band = 1
    while cuts[band] and d >= cuts[band] do band = band + 1 end
    local any = false
    for i, m in pairs(a.mirrors or {}) do
        if m.SetParticleOverrideScale then
            any = true
            local want = (i == band) and 1 or 0
            if m.particles ~= want then
                m.particles = want
                pcall(m.SetParticleOverrideScale, m, want)
            end
        end
    end
    return any
end

-- An actor's depth (yd along the view axis) from where its own calls put it (position times scale: scene units).
function View:ActorDepth(a)
    local p, sc = a.last and a.last.SetPosition, a.last and a.last.SetScale
    if not p then return nil end
    local s = sc and sc[1] or 1
    local cam = self.cam
    return (p[1] * s - cam.x) * cam.fx + (p[2] * s - cam.y) * cam.fy + (p[3] * s - cam.z) * cam.fz
end

-- The slices' clips (band i from cuts[i - 1] to cuts[i]; the nearest from the view's near clip, the farthest to its far
-- clip) and levels: in band i the shown actors' scenes from levels[i] up, the farthest actor lowest.
function View:SetSliceClips(cuts, levels)
    local order = {}
    for _, a in ipairs(self.fanned or {}) do
        if a.sliceScenes and Shown(a) then
            order[#order + 1] = a
            a.sliceDepth = self:ActorDepth(a) or 0
        end
    end
    table.sort(order, function(x, y) return x.sliceDepth > y.sliceDepth end)
    for j, a in ipairs(order) do
        for i, sc in pairs(a.sliceScenes) do
            if sc:IsShown() and levels[i] then
                pcall(sc.SetCameraNearClip, sc, (i == 1) and self.near or cuts[i - 1])
                pcall(sc.SetCameraFarClip, sc, cuts[i] or self.far)
                local lvl = levels[i] + j - 1
                if sc:GetFrameLevel() ~= lvl then sc:SetFrameLevel(lvl) end
            end
        end
    end
end

-- Where the client draws an actor's model sideways from its position, as room x, y to add to the position so the
-- model's own origin stands there: 0, 0 unless the client says it centres the model's box (IsUsingCenterForOrigin),
-- then the box's centre (GetActiveBoundingBox, model units) turned by its facing (room radians) and scaled.
function View:CentreShift(a, scale, facing)
    if not (a and a.IsUsingCenterForOrigin) then return 0, 0 end
    local ok, ux, uy = pcall(a.IsUsingCenterForOrigin, a)
    if not ok or not (ux or uy) then return 0, 0 end
    local okb, x0, y0, _, x1, y1 = pcall(a.GetActiveBoundingBox, a)
    if not okb or type(x1) ~= "number" or type(y1) ~= "number" then return 0, 0 end
    local cx, cy = ux and (x0 + x1) / 2 * scale or 0, uy and (y0 + y1) / 2 * scale or 0
    local c, s = cos(facing), sin(facing)                -- (the model keeps its handedness: a plain turn)
    return c * cx - s * cy, s * cx + c * cy
end

-- The cursor in UI units from the scene's bottom-left corner.
function View:Cursor()
    local sc = self.scene
    local x, y = GetCursorPosition()
    local es = sc:GetEffectiveScale() or 1
    if es <= 0 then es = 1 end
    return x / es - (sc:GetLeft() or 0), y / es - (sc:GetBottom() or 0)
end
