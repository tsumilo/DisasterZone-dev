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
    for _, s in ipairs(scenes) do
        pcall(s.SetCameraFieldOfView, s, opts.fov or 1.1)
        pcall(s.SetCameraNearClip, s, v.near)
        pcall(s.SetCameraFarClip, s, opts.far or 500)
        pcall(s.SetLightVisible, s, true)
        pcall(s.SetLightDirection, s, -0.4, 0.3, -0.8)
        pcall(s.SetLightAmbientColor, s, 0.7, 0.7, 0.75)
        pcall(s.SetLightDiffuseColor, s, 0.85, 0.85, 0.85)
    end
    return v
end

-- Room y -> scene y.
function View:SY(y) return self.cam.mirror * y end

-- Hands the camera in self.cam (x, y, z and the view direction, scene coordinates) to the scene, looking along
-- scene yaw `yaw` (radians; the room's heading times cam.mirror) and `pitch` (positive looks down).
function View:ApplyCamera(yaw, pitch)
    local sc, cam = self.scene, self.cam
    pcall(sc.SetCameraPosition, sc, cam.x, cam.y, cam.z)
    pcall(sc.SetCameraOrientationByYawPitchRoll, sc, yaw, cam.pitchSign * pitch, 0)
    local sc2 = self.scene2
    if sc2 then
        pcall(sc2.SetCameraPosition, sc2, cam.x, cam.y, cam.z)
        pcall(sc2.SetCameraOrientationByYawPitchRoll, sc2, yaw, cam.pitchSign * pitch, 0)
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
    local sc = (top and self.scene2) or self.scene
    local ok, a = pcall(sc.CreateActor, sc, nil, "ModelSceneActorTemplate")
    if not ok or not a then ok, a = pcall(sc.CreateActor, sc) end
    if not ok or not a then return nil end
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
