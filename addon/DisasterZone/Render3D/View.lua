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

local cos, sin, abs, min, max = math.cos, math.sin, math.abs, math.min, math.max
local exp, log = math.exp, math.log

-- The animations the 3D views play (AnimationData IDs): the chess pieces, the trainer's units, your walking character
-- on the strategy board and the hub's chess poster.
R3.ANIM = { stand = 0, death = 1, walk = 4, run = 5, dead = 6, back = 13, stun = 14, attack = 16, attack1H = 17,
            ready1H = 26, readyBow = 29, fall = 40, swimIdle = 41, swim = 42, readyCast = 51, cast = 52,
            castDirected = 53 }

-- An actor's box: kind "active" (GetActiveBoundingBox, its pose now; the default) or "max" (GetMaxBoundingBox, all its
-- animations). The client gives six numbers in practice, two vectors (min, max) by the docs: both are read (a vector by
-- GetXYZ, else its x, y, z). -> true, x0, y0, z0, x1, y1, z1 (model units), or false (no such box, or the client
-- raised an error).
local function BoxVec(v)
    if v.GetXYZ then return v:GetXYZ() end
    return v.x, v.y, v.z
end
function R3.ActorBox(a, kind)
    local fn = a and ((kind == "max") and a.GetMaxBoundingBox or a.GetActiveBoundingBox)
    if not fn then return false end
    local ok, x0, y0, z0, x1, y1, z1 = pcall(fn, a)
    if ok and type(x0) == "table" and type(y0) == "table" then
        local lo, hi = x0, y0
        ok, x0, y0, z0 = pcall(BoxVec, lo)
        if ok then ok, x1, y1, z1 = pcall(BoxVec, hi) end
    end
    return ok, x0, y0, z0, x1, y1, z1
end

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
-- clip, 0.5), fov (1.1), far (500), anim (the animation a loaded model plays when its actor has none set, 0 = stand),
-- bg (r, g, b: the view's background, for the stand-in scene's backdrop; the strategy board's by default).
-- -> the view, or nil when the client has no ModelScene that can show creatures (the caller falls back to something
-- flat).
function R3.NewView(parent, opts)
    opts = opts or {}
    if not parent.CreateLine then return nil end
    local ok, sc = pcall(CreateFrame, "ModelScene", nil, parent)
    if not ok or not sc or not sc.CreateActor or not sc.Project3DPointTo2D then return nil end
    local v = setmetatable({ parent = parent, scene = sc, lv = opts.lv or R3.LV, near = opts.near or 0.5,
                             cam = opts.cam or {}, anim = opts.anim or 0, bg = opts.bg }, View)
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

-- The stand-in scene (Render3D/Standins.lua), made when first asked for: a ModelScene under everything else of the
-- view (lv.standin, default the view's own level; the strategy board gives it one of its own under lv.floor, so it
-- is never level with the floor frame) for cubes standing just behind the room's surfaces, and an opaque
-- backdrop in the view's background colour at the bottom of the floor frame, over the scene and under every room
-- piece. All of the client's ModelScenes share one depth buffer, and an opaque UI texture drawn between two scenes
-- leaves it as it is (seen in game 2026-10-05): the cubes are never seen, yet every model of the scenes above is cut
-- per pixel where a surface of the room stands in front of it. Same lens and camera as the other scenes: the client
-- keeps each scene's depth in its own near / far range, so only identical clips compare. -> the scene, or nil when
-- the client makes none.
function View:StandinScene()
    if self.sceneS == nil then
        local ok, s = pcall(CreateFrame, "ModelScene", nil, self.parent)
        if ok and s and s.CreateActor then
            s:SetAllPoints()
            self:SetupScene(s)
            local bg = self.floorFrame:CreateTexture(nil, "BACKGROUND", nil, -8)
            bg:SetAllPoints()
            local c = self.bg or { 0.03, 0.03, 0.05 }
            bg:SetColorTexture(c[1], c[2], c[3], 1)
            self.sceneS, self.standinBg = s, bg
            self:StandinLayer(false)
            if self.yaw then self:ApplyCamera(self.yaw, self.pitch) end
        else
            self.sceneS = false
        end
    end
    return self.sceneS or nil
end

-- Where the stand-in scene draws: "depth" at the bottom under its backdrop (unseen, its depth kept), "debug" over the
-- room and the models (lv.standinDebug, else just under the plates: to see the cubes), false hidden with its
-- backdrop. Asked again every redraw: a parent that was moved up or down moves the view's frames.
function View:StandinLayer(mode)
    local s = self.sceneS
    if not s then return end
    local lv = self.lv
    local want = self.parent:GetFrameLevel()
        + ((mode == "debug") and (lv.standinDebug or (lv.plates - 1)) or (lv.standin or 0))
    if s:GetFrameLevel() ~= want then s:SetFrameLevel(want) end
    if self.standinMode ~= mode then
        self.standinMode = mode
        s:SetShown(mode and true or false)
        self.standinBg:SetShown(mode and true or false)
    end
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
    local scS = self.sceneS
    if scS then
        pcall(scS.SetCameraPosition, scS, cam.x, cam.y, cam.z)
        pcall(scS.SetCameraOrientationByYawPitchRoll, scS, yaw, cam.pitchSign * pitch, 0)
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

-- Calibrate for a camera that looks at the room point (x, y, z) along the room heading `heading`: the point to its
-- left is 2 yd that way. -> as Calibrate
function View:CalibrateOrbit(place, x, y, z, heading)
    return self:Calibrate(place, x, y, z, x - sin(heading) * 2, y + cos(heading) * 2, z)
end

-- A new model actor (nil when the client makes none). Its feet are its origin; an animation does not survive a model
-- change, so a loaded model plays the actor's .anim again (else the view's default).
function View:NewActor(top)
    local sc = (top == "back" and self:Backdrop()) or (top == true and self.scene2) or self.scene
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
    local okb, x0, y0, _, x1, y1 = R3.ActorBox(a, "active")
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

-- The depth mode of a room drawn in this view (the strategy board's choice per room, which the chess hall follows):
-- "box" (occluder boxes and the room's copies hide the models), "standins" (cubes behind the room's surfaces do it per
-- pixel, Render3D/Standins.lua) or "gaps" (stand-ins, and the copies only for the triangles no stand-in covers).
-- key: the room's key (nil: none, as "box"); cfg: the stand-ins' settings (Standins:Configure); gapSet(key): that
-- room's gap triangles. Turns the stand-ins on or off and sets the room's copies to match.
-- -> the stand-ins in use (nil: box mode), the gap set in use, and why a room has none (Standins:Use's answer)
function View:SyncDepthMode(key, mode, cfg, gapSet)
    local S = R3.Standins
    if mode == "box" or not S then key = nil end
    local ctl = self.standinCtl or (key and S.For and S.For(self)) or nil
    local use, why
    if key and ctl then
        local ok
        ok, why = ctl:Use(key)
        if ok then use = ctl end
    elseif ctl and ctl.key then
        ctl:Off()
    end
    if use and cfg then use:Configure(cfg) end
    local gaps = use and mode == "gaps" and gapSet and gapSet(key) or nil
    local R = self.room
    if R and R.opts then
        local copies = use == nil or gaps ~= nil
        if (R.opts.copies ~= false) ~= copies then R.SetOpts({ copies = copies }) end
        if R.opts.copyOnly ~= gaps then R.SetOpts({ copyOnly = gaps or false }) end
    end
    return use, gaps, why
end

-- One frame of the room renderer, when the camera lets it draw (Room.BeginFrame): the occluders (occ, n; occ may be a
-- function that returns them, asked only then), the room, lines() (the caller's floor marks, in the room's own order),
-- the room's copies over the models and the stand-ins (si: in use, gaps: its gap set; with stand-ins and no gaps the
-- room gets no occluders). -> true when the room was drawn
function View:DrawFrame(occ, n, lines, si, gaps)
    local R = self.room
    if not (R and R.BeginFrame(self.cam)) then return false end
    if type(occ) == "function" then occ, n = occ() end
    if not si or gaps then R.SetOccluders(occ, n) end
    R.DrawRoom()
    R.BeginLines()
    if lines then lines() end
    R.EndLines()
    R.DrawCopies()
    if si then si:Update(occ, n, R.Project) end
    return true
end

---------------------------------------------------------------------------
-- Cameras: the orbit (chess hall, strategy board) and the follow camera (Raid Trainer, walking on the board)
---------------------------------------------------------------------------

-- A critically damped spring, stepped implicitly (stable for any dt): position x, speed v towards target, w its
-- stiffness. -> the new x, v
function R3.Spring(x, v, target, w, dt)
    local f, hw2 = 1 + 2 * dt * w, dt * w * w
    local det = 1 / (f + dt * hw2)
    return (f * x + dt * v + dt * hw2 * target) * det, (v + hw2 * (target - x)) * det
end
local Spring = R3.Spring

-- The camera behind someone walking. Its fields live on `state` (the Raid Trainer's camera table keeps them where
-- its tests read them): hoff, hv (the pivot's spring), lastTarget, px, py (the last frame's pivot target and feet),
-- cur (the distance in use).
local Follow = {}
Follow.__index = Follow

function R3.NewFollowCam(state)
    return setmetatable({ s = state or {} }, Follow)
end

-- The height the camera turns round: target (the eye height over the feet at x, y), plus an offset a spring takes
-- back to 0. The pivot rides the feet up and down ramps and through a fall frame for frame; only a jump of the feet
-- that walking (up to the steepest ground, R3.WALK.maxSlope) and falling (vz, gravity) cannot make in dt - a ledge
-- stepped up - goes into the offset, so the view eases over a few frames instead of jolting. It snaps (offset 0) when
-- asked to, without dt or a last frame, after a move of over 3 yd or a jump of over 2 yd while not falling.
-- -> the pivot's height, and whether it snapped
function Follow:Pivot(target, x, y, vz, falling, dt, snap)
    local s, W = self.s, R3.WALK
    local moved2 = s.px and (x - s.px) ^ 2 + (y - s.py) ^ 2 or 0
    local jump = s.lastTarget and target - s.lastTarget or 0
    snap = snap or not dt or not s.lastTarget or moved2 > 9 or (abs(jump) > 2 and not falling)
    if snap then
        s.hoff, s.hv = 0, 0
    else
        local walk = math.sqrt(moved2) * W.maxSlope + abs(vz or 0) * dt + W.gravity * dt * dt + 0.02
        if abs(jump) > walk then s.hoff = (s.hoff or 0) - jump end
        s.hoff, s.hv = Spring(s.hoff or 0, s.hv or 0, 0, 12, dt)
    end
    s.lastTarget, s.px, s.py = target, x, y
    return target + s.hoff, snap and true or false
end

-- The distance the camera stands at: pulled in at once to `allowed` (where the room is in the way:
-- Room.CameraDistance), eased back out at 6 yd a second; snap: straight to it. -> the distance
function Follow:Reach(allowed, dt, snap)
    local s = self.s
    if snap or not s.cur or allowed < s.cur then
        s.cur = allowed
    else
        s.cur = min(allowed, s.cur + 6 * dt)
    end
    return s.cur
end

-- The orbit camera: it circles a point (opts.centre(orb) -> x, y, z; default orb.x, orb.y, 0) at orb.heading (room
-- radians, 0 = east), orb.pitch (positive looks down) and orb.dist (yd). A right / middle drag turns and tilts it
-- (R3.ORBIT_DRAG: radians per pixel), the wheel zooms by opts.zoom a notch (0.88), MoveTo eases it to a view
-- (smoothstep; the distance linearly, or in its logarithm with opts.ease = "log" so a long zoom does not rush its
-- near end). opts: orb (the table to keep: it stays the same table, Set copies into it), clamp(o) (keeps a view in
-- bounds), wheelGoal (the wheel zooms from where a move is going), snapDist(dist) -> dist (the wheel's last notch in).
-- Each view keeps its own feel (decision D6): the chess hall 0.88 linear, the strategy board 0.82 log.
R3.ORBIT_DRAG = { x = 0.008, y = 0.006 }

local Orbit = {}
Orbit.__index = Orbit

function R3.NewOrbitController(view, opts)
    opts = opts or {}
    return setmetatable({ view = view, orb = opts.orb or { heading = 0, pitch = 0.5, dist = 20 },
                          zoom = opts.zoom or 0.88, ease = opts.ease or "linear", clamp = opts.clamp,
                          centre = opts.centre, wheelGoal = opts.wheelGoal, snapDist = opts.snapDist }, Orbit)
end

-- A copy of a view (default the orbit now): x, y, heading, pitch, dist.
function Orbit:Copy(o)
    o = o or self.orb
    return { x = o.x, y = o.y, heading = o.heading, pitch = o.pitch, dist = o.dist }
end

-- Where the camera is going: the end of the move under way, else where it is.
function Orbit:Goal()
    return self.anim and self.anim.to or self.orb
end

-- Puts the orbit at view `o` at once (its fields copied: orb stays the same table). -> orb
function Orbit:Set(o)
    local orb = self.orb
    orb.x, orb.y, orb.heading, orb.pitch, orb.dist = o.x, o.y, o.heading, o.pitch, o.dist
    return orb
end

-- Keeps a view (default the orbit) in bounds. -> it
function Orbit:Clamp(o)
    o = o or self.orb
    if self.clamp then self.clamp(o) end
    return o
end

-- The camera where the orbit says, handed to the view.
function Orbit:Place()
    local o = self.orb
    local x, y, z
    if self.centre then x, y, z = self.centre(o) else x, y, z = o.x or 0, o.y or 0, 0 end
    self.view:Orbit(x, y, z, o.heading, o.pitch, o.dist)
end

-- Stops a move and a drag under way.
function Orbit:Stop()
    self.anim, self.drag = nil, nil
end

-- Eases the camera to view `to` (kept in bounds) over `dur` seconds (0.35); after() once there. The heading goes the
-- short way round unless raw (a half turn that must go one way).
function Orbit:MoveTo(to, dur, after, raw)
    self:Clamp(to)
    local from = self:Copy()
    if not raw then
        local dh = (to.heading - from.heading + math.pi) % (2 * math.pi) - math.pi
        to.heading = from.heading + dh
    end
    self.anim = { from = from, to = to, t0 = GetTime(), dur = dur or 0.35, after = after }
end

-- The wheel: one notch in (delta > 0) or out. Ends a move.
function Orbit:Wheel(delta)
    local base = (self.wheelGoal and self.anim) and self.anim.to.dist or self.orb.dist
    local d = base * (delta > 0 and self.zoom or 1 / self.zoom)
    if self.snapDist then d = self.snapDist(d) end
    self.anim = nil
    self.orb.dist = d
    self:Clamp()
end

-- A drag that turns and tilts the camera, from the cursor now (button: the one held).
function Orbit:BeginDrag(button)
    local cx, cy = GetCursorPosition()
    local o = self.orb
    self.drag = { button = button, cx = cx, cy = cy, heading = o.heading, pitch = o.pitch }
end

-- A button let go: -> "click" when it held a drag that never moved (4 px), true when it held a moved one, else nil.
function Orbit:EndDrag(button)
    local d = self.drag
    if not (d and d.button == button) then return nil end
    self.drag = nil
    return d.moved and true or "click"
end

local function Smooth(t) return t * t * (3 - 2 * t) end

-- One frame: the move under way (its after() when it ends), then the drag. -> true when the camera moved
function Orbit:Step()
    local moved = false
    local a = self.anim
    if a then
        local t = (GetTime() - a.t0) / max(0.01, a.dur)
        local o, f, to = self.orb, a.from, a.to
        if t >= 1 then
            self:Set(to)
            self.anim = nil
        else
            local k = Smooth(t)
            if f.x and to.x then o.x, o.y = f.x + (to.x - f.x) * k, f.y + (to.y - f.y) * k end
            o.heading = f.heading + (to.heading - f.heading) * k
            o.pitch = f.pitch + (to.pitch - f.pitch) * k
            if self.ease == "log" then
                o.dist = exp(log(f.dist) + (log(to.dist) - log(f.dist)) * k)
            else
                o.dist = f.dist + (to.dist - f.dist) * k
            end
        end
        moved = true
        if not self.anim and a.after then a.after() end
    end
    local d = self.drag
    if d then
        if not IsMouseButtonDown(d.button) then
            self.drag = nil
        else
            local cx, cy = GetCursorPosition()
            local dx, dy = cx - d.cx, cy - d.cy
            if abs(dx) + abs(dy) > 4 then d.moved = true end
            if d.moved then
                local o = self.orb
                o.heading = d.heading - dx * R3.ORBIT_DRAG.x
                o.pitch = d.pitch - dy * R3.ORBIT_DRAG.y
                self.anim = nil
                self:Clamp(o)
                moved = true
            end
        end
    end
    return moved
end
