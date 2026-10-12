if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Trainer/UI.lua", ...) then return end -- DisasterZone Games/Trainer/UI.lua
-- ns.TrainerUI: the Raid Trainer's panel. A toolbar (encounter, mode, start), the fight seen from behind your
-- character in a ModelScene (the game's own models, the client's own controls: W / S run, A / D turn, Q / E
-- strafe, right mouse button to look, both buttons to run, wheel to zoom), name plates, an action bar, a minimap
-- and the briefing / result overlay. Without ModelScene actors the minimap fills the view and is the game.
-- The panel takes the keyboard only while a try is running: Esc pauses and gives it back (same as Azeromon),
-- combat pauses too. The 3D view itself (scene, camera, room renderer) is the shared one in Render3D/.
local addonName, ns = ...

local UI = ns:NewModule("TrainerUI")
local T = ns.Trainer
-- the shared 3D view (Render3D/View.lua) and the trainer's own room renderer (Render3D/Room.lua); both nil until the
-- client is restarted once after an update that added them (a /reload does not read new files; spec 7.4)
local R3 = ns.Render3D
local Room = R3 and R3.NewRoom and R3.NewRoom("Raid Trainer")
ns.TrainerRoom = Room

local floor, min, max = math.floor, math.min, math.max
local sin, cos, pi = math.sin, math.cos, math.pi

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local TOOLBAR_H, BAR_H, PAD = 30, 64, 6
local MOVE_KEYS = {
    W = "up", UP = "up", S = "down", DOWN = "down",
    A = "left", LEFT = "left", D = "right", RIGHT = "right", Q = "strafeL", E = "strafeR",
}
local MINI_W, MINI_H = 170, 170
-- The animations (Render3D/View.lua R3.ANIM; none without the Render3D files, when there is no 3D view to play them)
local A = R3 and R3.ANIM or {}
local ANIM_STAND, ANIM_DEATH, ANIM_RUN, ANIM_DEAD, ANIM_BACK, ANIM_STUN, ANIM_FALL = A.stand, A.death, A.run, A.dead,
    A.back, A.stun, A.fall
local PLATE_HEIGHT = { construct = 3.2, boss = 7 }
-- What a unit that stands and fights plays: { animation, seconds } in a loop (each unit starts somewhere else
-- in it): Ready1H and Attack1H; ReadySpellDirected, SpellCastDirected and a stand; ReadyBow and a stand.
local ACTS = {
    melee = { { A.ready1H, 0.9 }, { A.attack1H, 1.1 } },
    caster = { { A.readyCast, 1.6 }, { A.castDirected, 0.9 }, { A.stand, 0.7 } },
    bow = { { A.readyBow, 2.5 }, { A.stand, 0.6 } },
}

-- Frame levels above the view's own. The room's cluster frames take room0 .. room0 + 199 (Room.lua), all under
-- the single ModelScene; the copies of the room that hide the models sit just above it; the HUD above all that.
local LV = { floor = 1, lines = 2, room0 = 3, scene = 210, copy0 = 211, plates = 250, arena = 252, hud = 253,
             focus = 268, overlay = 270 }
local NEAR_CLIP = 0.5            -- the scene's near clip; the room is cut at the same distance

local root, view, arena, overlay, focusOverlay
local v3                                 -- the shared 3D view (Render3D/View.lua) in `view`
local scene, floorFrame, plateFrame      -- its ModelScene and frames (scene == nil: the minimap is the game)
local roomOn = false                     -- drawing the room with Room.lua this frame (marks go in its order)
local cam = { dist = 14, pitch = 0.3, pitchSign = 1, mirror = 1, x = 0, y = 0, z = 0, fx = 1, fy = 0, fz = 0 }
local follow                             -- R3.NewFollowCam(cam): the pivot's spring and the pull-in, on cam's fields
local actors = {}            -- unit id -> actor
local actorPool = {}
local plates = {}
local floorLines, fxLines = {}, {}
local markLabels = {}        -- the text on the encounter's marks, and the compass letters
local floorTiles = {}
local TILES = 20             -- the floor map is drawn as TILES x TILES quads, each bent into perspective
local fxActors = {}          -- effect -> actor
local fxPool = {}            -- model file -> spare actors that already hold it
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
local ResetScene, ResetUnitFrames

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
    if sim and sim.enc.interactKey == key then
        sim:Interact()
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

-- The floor's height at a spot (0 on a flat floor): the ground units walk on there (arena.ground, near the height
-- grid's value), else the grid's.
local function GroundZ(x, y)
    local arena = sim and sim.enc.arena
    local fn = arena and arena.height
    local z = fn and fn(x, y) or 0
    local ground = arena and arena.ground
    return ground and ground(x, y, z) or z
end

-- Where a unit's feet are: on the room's ground as the sim keeps it (up ramps, through a fall), or its own height.
local function FeetZ(u)
    return sim:FeetZ(u)
end

-- A unit's size: its own scale, else its display's (the encounter's def.displays: CreatureDisplayInfo's
-- CreatureModelScale). The client draws a ModelScene actor at scale 1 whatever its display says, so it is set here.
local function DisplayOf(u)
    local t = u.display and sim.enc.displays
    return t and t[u.display]
end
local function UnitScale(u)
    if u.scale then return u.scale end
    local d = DisplayOf(u)
    return d and d.scale or 1
end

-- How high over a unit's feet a spell effect on it sits (yards): at the model's attachment point fx.attach
-- ("chest", "head", "hand" - the left, where spells are held - or "base"), from def.displays, else a humanoid's
-- (a Blood Elf's, model 2208: 1.50, 2.19, 1.03); or fx.z (yards on a model of scale 1). Both grow with the unit.
local ATTACH = { base = 0, chest = 1.5, head = 2.19, hand = 1.03 }
local CHEST = { attach = "chest" }
local function AttachZ(u, fx)
    if fx.attach then
        local d = DisplayOf(u)
        return ((d and d[fx.attach]) or ATTACH[fx.attach] or 0) * UnitScale(u)
    end
    return (fx.z or 0) * UnitScale(u)
end

-- Sim point -> UI units from the scene's bottom-left corner; nil when it is behind the camera.
local function Project(x, y, z)
    return v3:Project(x, y, z)
end

-- The camera sits behind and above the character and looks where it faces (spec 5.2): R3.NewFollowCam, the strategy
-- board's walking camera too. The point it turns round (the pivot, cam.hz) rides 2.2 yd over your feet as the
-- client's does, up and down ramps and through a fall frame for frame; only a jump of the feet no walking makes (a
-- ledge stepped up) goes into cam.hoff, which a spring takes back to 0, so it eases over a few frames instead of
-- jolting the view. With the room (room = true) the camera is pulled in where the room is in the way
-- (Room.CameraDistance) and eases back out at 6 yd a second. cam.dist is the distance wanted (the wheel), cam.cur the
-- one used. dt: seconds since the last frame (Room.opts.camDt replaces it: render_check's walks); nil, a jump of the
-- player, a new distance or pitch, or a height far off snap everything to where it belongs.
local function PlaceCamera(dt, room)
    local p = sim.player
    local o = Room and Room.opts
    if dt and o and type(o.camDt) == "number" then dt = o.camDt end
    local yaw, pitch = cam.mirror * p.facing, cam.pitch
    cam.fx, cam.fy, cam.fz = cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), -sin(pitch)
    local turned = cam.lastDist ~= nil
        and (math.abs(cam.dist - cam.lastDist) > 0.15 or math.abs(pitch - cam.lastPitch) > 0.15)
    local snap
    cam.hz, snap = follow:Pivot(FeetZ(p) + 2.2, p.x, p.y, p.vz, p.falling, dt, turned)
    cam.lastDist, cam.lastPitch = cam.dist, pitch
    local allowed, hit = cam.dist, false
    if room and o.collision ~= false then allowed, hit = Room.CameraDistance(p.x, p.y, cam.hz, cam, cam.dist) end
    cam.collided = hit
    local d = follow:Reach(allowed, dt, snap)
    local tx, ty, tz = p.x, SY(p.y), cam.hz
    cam.x, cam.y, cam.z = tx - cam.fx * d, ty - cam.fy * d, tz - cam.fz * d
    v3:ApplyCamera(yaw, pitch)
end

-- Which way the client counts pitch and which side it draws +y on is not documented: the shared view asks the
-- projection once (Render3D/View.lua). The point we look at is the character's head, a point to its left must land
-- left of it.
local function Calibrate()
    local p = sim.player
    cam.calibrated = v3:CalibrateOrbit(PlaceCamera, p.x, p.y, FeetZ(p) + 2.2, p.facing)
end

local function NewActor()
    return v3:NewActor()
end

local function ActorFor(u)
    local a = actors[u.id]
    if not a then
        a = table.remove(actorPool) or NewActor()
        if not a then return nil end
        actors[u.id] = a
        a.anim = nil               -- (a pooled actor keeps its model: the same key does not load again)
    end
    local key = u.model or u.display or (u.fdid and ("file" .. u.fdid))
    if a.key ~= key then
        a.key, a.anim = key, nil
        pcall(a.ClearModel, a)
        if u.model == "player" then
            if not (a.SetModelByUnit and pcall(a.SetModelByUnit, a, "player")) then a.noModel = true end
        elseif u.fdid then
            if not (a.SetModelByFileID and pcall(a.SetModelByFileID, a, u.fdid)) then a.noModel = true end
        elseif u.display then
            pcall(a.SetModelByCreatureDisplayID, a, u.display)
        end
    end
    return a
end

local function AnimFor(u)
    if u.dead then return ANIM_DEATH end
    if u.pose == "dead" then return ANIM_DEAD end
    if u.falling then return ANIM_FALL end
    for _, aura in pairs(u.auras) do
        if aura.stun then return ANIM_STUN end
    end
    if u.moving then return u.backward and ANIM_BACK or ANIM_RUN end
    local act = ACTS[u.act]
    if act then
        local total = 0
        for _, step in ipairs(act) do total = total + step[2] end
        local t = (sim.time + u.id * 0.83) % total
        for _, step in ipairs(act) do
            if t < step[2] then return step[1] end
            t = t - step[2]
        end
    end
    return ANIM_STAND
end

local function DrawActors()
    local seen = {}
    for _, u in ipairs(sim.units) do
        local show = (u.model or u.display or u.fdid) and (not u.dead or sim.time - (u.diedAt or 0) < 2.5)
        if show then
            local a = ActorFor(u)
            if a then
                seen[u.id] = true
                -- (an actor's position is multiplied by its scale: divide it out)
                local scale = UnitScale(u)
                if a.scale ~= scale then
                    a.scale = scale
                    pcall(a.SetScale, a, scale)
                end
                -- (the copies' occluders stand where the model does: a.feetZ)
                local z = FeetZ(u)
                a.feetZ = z
                pcall(a.SetPosition, a, u.x / scale, SY(u.y) / scale, z / scale)
                -- a strafing body swings round over a moment, not in one frame
                local want = u.bodyTurn or 0
                local have = a.bodyTurn or 0
                if have ~= want then
                    local step = 9 * (sim.time - (a.turnAt or sim.time))
                    have = (want > have) and min(want, have + step) or max(want, have - step)
                    a.bodyTurn = have
                end
                a.turnAt = sim.time
                pcall(a.SetYaw, a, cam.mirror * (u.facing + have))
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

-- One world-space segment, cut at the camera's near plane, drawn as a Line over the scene (the flat floor map's
-- path; with the room, Room.Line puts mark segments into the room's own order).
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

-- A ring on the floor: 20 segments. With the room they lie 0.08 yd over the room's own floor (Room.FloorZ) and go
-- into its draw order, so whatever is nearer paints over them; without it they lie on the height grid, on top.
-- The floor does not move: each ring of the frame (by its place in DrawEffects' order) keeps its points while its
-- centre, radius and floor stay the same, so a ring that stands still costs no floor search.
local rings, nRings = {}, 0
local function Circle(x, y, radius, r, g, b, a, thick)
    local n = 20
    nRings = nRings + 1
    local ring = rings[nRings]
    if not ring then
        ring = { X = {}, Y = {}, Z = {} }
        rings[nRings] = ring
    end
    local floorKey = roomOn and sim.enc.arena.mesh or sim.enc.arena
    local ringX, ringY, ringZ = ring.X, ring.Y, ring.Z
    if ring.x ~= x or ring.y ~= y or ring.r ~= radius or ring.floor ~= floorKey then
        ring.x, ring.y, ring.r, ring.floor = x, y, radius, floorKey
        for i = 0, n do
            local ang = i / n * 2 * pi
            local px_, py_ = x + cos(ang) * radius, y + sin(ang) * radius
            ringX[i], ringY[i] = px_, py_
            ringZ[i] = roomOn and (Room.FloorZ(px_, py_, GroundZ(px_, py_)) + 0.08) or (GroundZ(px_, py_) + 0.1)
        end
    end
    for i = 1, n do
        if roomOn then
            Room.Line(ringX[i - 1], ringY[i - 1], ringZ[i - 1], ringX[i], ringY[i], ringZ[i], r, g, b, a, thick)
        else
            Segment(fxLines, "fx", plateFrame, ringX[i - 1], ringY[i - 1], ringZ[i - 1], ringX[i], ringY[i], ringZ[i],
                    r, g, b, a, thick)
        end
    end
end

-- The floor map: the arena's piece of Blizzard's map, cut into tiles; every tile's four corners are moved to
-- where the scene projects them (Texture:SetVertexOffset), which bends the flat picture into the room's floor.
local function DrawFloorMap()
    local map = sim.enc.arena.map
    if not map then return false end
    local w, h = sim.enc.arena.w, sim.enc.arena.h
    local n = 0
    for i = 0, TILES - 1 do
        for j = 0, TILES - 1 do
            n = n + 1
            local t = floorTiles[n]
            if not t then
                -- (a 1 x 1 base at the scene's corner, bent onto the floor: Render3D/Room.lua R3.Bend)
                t = R3.NewBentTexture(floorFrame, "BACKGROUND", nil, scene, "BOTTOMLEFT", 0.5, 0.5)
                if not t.SetVertexOffset then
                    t:Hide()
                    return false
                end
                t:SetVertexColor(0.85, 0.85, 0.85)
                floorTiles[n] = t
            end
            if t.file ~= map.file then
                t.file = map.file
                t:SetTexture(map.file)
            end
            local x0, x1 = w * i / TILES, w * (i + 1) / TILES
            local y0, y1 = h * j / TILES, h * (j + 1) / TILES
            local nwx, nwy = Project(x0, y1, GroundZ(x0, y1))
            local swx, swy = Project(x0, y0, GroundZ(x0, y0))
            local nex, ney = Project(x1, y1, GroundZ(x1, y1))
            local sex, sey = Project(x1, y0, GroundZ(x1, y0))
            local inside = not sim.enc.arena.walkable or sim.enc.arena.walkable((x0 + x1) / 2, (y0 + y1) / 2)
            if inside and nwx and swx and nex and sex then
                local ua, ub = map.u0 + (map.u1 - map.u0) * x0 / w, map.u0 + (map.u1 - map.u0) * x1 / w
                local vs, vn = map.v1 - (map.v1 - map.v0) * y0 / h, map.v1 - (map.v1 - map.v0) * y1 / h
                t:SetTexCoord(ua, vn, ua, vs, ub, vn, ub, vs)            -- upper left, lower left, upper right, lower right
                R3.Bend(t, 0.5, 0.5, nwx, nwy, swx, swy, nex, ney, sex, sey)
                t:Show()
            else
                t:Hide()                                              -- a corner is behind the camera
            end
        end
    end
    return true
end

-- A room without its own mesh (or without Room.lua): its floor map, its walls and a line every 10 yd, so distance
-- and speed read at a glance.
local function DrawFloor()
    lineCount.floor = 0
    local w, h = sim.enc.arena.w, sim.enc.arena.h
    local mapped = DrawFloorMap()
    if not mapped then
        for _, t in ipairs(floorTiles) do t:Hide() end
    end
    local flat = not sim.enc.arena.height
    for x = 0, flat and w or -1, 10 do
        local wall = x == 0 or x >= w
        if x > 0 then Segment(floorLines, "floor", floorFrame, x, 0, 0, x, h, 0, 0.55, 0.45, 0.7, mapped and 0.18 or 0.28, 1) end
    end
    for y = 0, flat and h or -1, 10 do
        if y > 0 then Segment(floorLines, "floor", floorFrame, 0, y, 0, w, y, 0, 0.55, 0.45, 0.7, mapped and 0.18 or 0.28, 1) end
    end
    local outline = sim.enc.arena.outline or { { 0, 0 }, { w, 0 }, { w, h }, { 0, h } }
    for i, a in ipairs(outline) do                                    -- the walls: floor edge, top edge, corners
        local b = outline[i % #outline + 1]
        Segment(floorLines, "floor", floorFrame, a[1], a[2], 0, b[1], b[2], 0, 0.55, 0.45, 0.7, 0.9, 3)
        Segment(floorLines, "floor", floorFrame, a[1], a[2], 8, b[1], b[2], 8, 0.55, 0.45, 0.7, 0.5, 2)
        Segment(floorLines, "floor", floorFrame, a[1], a[2], 0, a[1], a[2], 8, 0.55, 0.45, 0.7, 0.9, 3)
    end
    for i = lineCount.floor + 1, #floorLines do floorLines[i]:Hide() end
end

-- A mark's label (text over it, on top of everything). The labels are reused by index; their setters run only when
-- the text, font, colour or place changed (a still view re-anchors nothing). dzShown mirrors Show / Hide.
local nLabels = 0
local function Label(text, x, y, z, r, g, b, big)
    local sxp, syp = Project(x, y, GroundZ(x, y) + z)
    if not sxp then return end
    nLabels = nLabels + 1
    local fs = markLabels[nLabels]
    if not fs then
        fs = plateFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs.dzShown = true
        markLabels[nLabels] = fs
    end
    local font = big and "GameFontNormalHuge" or "GameFontNormal"
    if fs.dzFont ~= font then
        fs:SetFontObject(font)
        fs.dzFont = font
    end
    if fs.dzText ~= text then
        fs:SetText(text)
        fs.dzText = text
    end
    if fs.dzR ~= r or fs.dzG ~= g or fs.dzB ~= b then
        fs:SetTextColor(r, g, b)
        fs.dzR, fs.dzG, fs.dzB = r, g, b
    end
    if not fs.dzX or math.abs(fs.dzX - sxp) > 0.01 or math.abs(fs.dzY - syp) > 0.01 then
        fs:ClearAllPoints()
        fs:SetPoint("BOTTOM", scene, "BOTTOMLEFT", sxp, syp)
        fs.dzX, fs.dzY = sxp, syp
    end
    if not fs.dzShown then
        fs:Show()
        fs.dzShown = true
    end
end

-- The heights a mark's column stands on, by the mark's place in sim.marks (the floor does not move).
local columns = {}

-- The target circle, the encounter's marks (ring, column, label) and beams. With the room (roomOn) every segment
-- goes through Room.Line into the room's draw order; otherwise they are Lines on top of the scene.
local function DrawEffects()
    lineCount.fx = 0
    nRings, nLabels = 0, 0
    local t = sim.target
    if t and not t.dead then
        if t.friendly then
            Circle(t.x, t.y, t.radius + 0.4, 0.1, 1, 0.1, 0.9, 3)
        else
            Circle(t.x, t.y, t.radius + 0.4, 1, 0.1, 0.1, 0.9, 3)                           -- hostile: red
        end
    end
    -- the encounter's marks: a ring on the floor, a column standing on it, a label on top
    local floorKey = roomOn and sim.enc.arena.mesh or sim.enc.arena
    for i, mk in ipairs(sim.marks or {}) do
        local c = mk.color or { 1, 1, 1 }
        Circle(mk.x, mk.y, mk.r or 3, c[1], c[2], c[3], 0.9, 2)
        if (mk.column or 0) > 0 then
            local col = columns[i]
            if not col then
                col = {}
                columns[i] = col
            end
            if col.x ~= mk.x or col.y ~= mk.y or col.floor ~= floorKey then
                col.x, col.y, col.floor = mk.x, mk.y, floorKey
                col.z = roomOn and Room.FloorZ(mk.x, mk.y, GroundZ(mk.x, mk.y)) or GroundZ(mk.x, mk.y)
            end
            local g = col.z
            if roomOn then
                Room.Line(mk.x, mk.y, g, mk.x, mk.y, g + mk.column, c[1], c[2], c[3], 0.8, 3)
            else
                Segment(fxLines, "fx", plateFrame, mk.x, mk.y, g, mk.x, mk.y, g + mk.column, c[1], c[2], c[3], 0.8, 3)
            end
        end
        if mk.label then Label(mk.label, mk.x, mk.y, (mk.column or 0) + 0.5, c[1], c[2], c[3]) end
    end
    for i = nLabels + 1, #markLabels do
        local fs = markLabels[i]
        if fs.dzShown then
            fs:Hide()
            fs.dzShown = false
        end
    end
    for _, b in ipairs(sim.beams or {}) do                           -- { x, y, z, x2, y2, z2, r, g, b }
        local z1, z2 = GroundZ(b[1], b[2]) + b[3], GroundZ(b[4], b[5]) + b[6]
        if roomOn then
            Room.Line(b[1], b[2], z1, b[4], b[5], z2, b[7], b[8], b[9], 0.75, 3)
        else
            Segment(fxLines, "fx", plateFrame, b[1], b[2], z1, b[4], b[5], z2, b[7], b[8], b[9], 0.75, 3)
        end
    end
    if not roomOn then
        for i = lineCount.fx + 1, #fxLines do fxLines[i]:Hide() end
    end
end

local function ReleaseFxActor(fx)
    local a = fxActors[fx]
    fxActors[fx] = nil
    if not a then return end
    pcall(a.SetShown, a, false)
    fxPool[a.fdid] = fxPool[a.fdid] or {}
    table.insert(fxPool[a.fdid], a)
end

-- The spells' own effect models: an actor per running effect, on its unit or flying to it. One on a unit sits at its
-- attachment point and is as much bigger as the unit (attached models take their unit's scale in the client).
local function DrawFxActors()
    local seen = {}
    for _, fx in ipairs(sim.fx) do
        if fx.fdid then
            local a = fxActors[fx]
            if a == nil then
                a = fxPool[fx.fdid] and table.remove(fxPool[fx.fdid])
                if not a then
                    a = NewActor()
                    if a then
                        a.fdid = fx.fdid
                        a.bad = not (a.SetModelByFileID and pcall(a.SetModelByFileID, a, fx.fdid))
                    end
                end
                if a then pcall(a.SetAnimation, a, ANIM_STAND) end
                fxActors[fx] = a or false
            end
            if a then
                seen[fx] = true
                local u = fx.unit
                local x, y, z, yaw, s = fx.x, fx.y, fx.z or 0, 0, 1
                if fx.kind == "missile" then
                    -- (from chest high where it was cast to its target's chest, wherever that stands)
                    local k = min(1, (sim.time - fx.at) / fx.dur)
                    yaw = math.atan2(u.y - fx.y, u.x - fx.x)
                    x, y = fx.x + (u.x - fx.x) * k, fx.y + (u.y - fx.y) * k
                    local z0 = GroundZ(fx.x, fx.y) + ATTACH.chest
                    z = z0 + (FeetZ(u) + AttachZ(u, CHEST) - z0) * k
                elseif u then
                    x, y, z, s = u.x, u.y, FeetZ(u) + AttachZ(u, fx), UnitScale(u)
                else
                    z = GroundZ(x, y) + z
                end
                if a.scale ~= s then
                    a.scale = s
                    pcall(a.SetScale, a, s)
                end
                pcall(a.SetPosition, a, x / s, SY(y) / s, z / s)          -- (multiplied by the actor's scale)
                pcall(a.SetYaw, a, cam.mirror * yaw)
                pcall(a.SetShown, a, not a.bad and not (u and u.dead and fx.kind ~= "missile"))
            end
        end
    end
    for fx in pairs(fxActors) do
        if not seen[fx] then ReleaseFxActor(fx) end
    end
end

-- The models on screen, for the room's copies (spec 5.13.1): one record per shown unit actor (the dead ones too while
-- shown) at its feet, with the body size render_check and the plates use, its model's own box (radius, height and
-- how far it reaches below its origin, the largest seen for that model so it never shrinks or bobs) and you first;
-- an effect on a unit raises its top, a flying missile is a record of its own. Records are reused.
-- A model whose origin is not at its feet (a Shield Generator's is mid-height, its pedestal ends 2.8 yd lower) is
-- recorded from where its box ends, no lower than the floor under it: the copies keep only what lies higher than an
-- occluder's feet, so feet recorded too high would let every step in front of it draw under it. Besides what the
-- client reports (GetActiveBoundingBox), a unit may carry its model's own box (u.box: min x, y, z, max x, y, z in
-- model units, from the model file) for a model the client may report no box for.
local occList, occBox = {}, {}
local function Occ(n)
    local o = occList[n]
    if not o then
        o = {}
        occList[n] = o
    end
    return o
end
local function BuildOccluders()
    local n = 0
    for _, u in ipairs(sim.units) do
        local a = actors[u.id]
        if a then
            n = n + 1
            local o = Occ(n)
            local h = u.plate or u.tall or PLATE_HEIGHT[u.kind] or 2.6
            o.id, o.x, o.y, o.z = u.id, u.x, u.y, a.feetZ or FeetZ(u)
            o.h, o.w = h, max(1.2, min(2 * (u.radius or 0.6), 0.6 * h))
            o.prio = (u == sim.player) and 2 or 1
            local bb = a.key and occBox[a.key]
            local ub = a.key and u.box
            if ub then
                local s = UnitScale(u)
                if not bb then
                    bb = { 0, 0, 0 }
                    occBox[a.key] = bb
                end
                bb[1] = max(bb[1], math.abs(ub[1]) * s, math.abs(ub[2]) * s, math.abs(ub[4]) * s, math.abs(ub[5]) * s)
                bb[2] = max(bb[2], ub[6] * s)
                bb[3] = min(bb[3], ub[3] * s)
            end
            if a.key and a.GetActiveBoundingBox then
                local ok, x0, y0, z0, x1, y1, z1 = R3.ActorBox(a, "active")      -- (six numbers or two vectors)
                if ok and type(z1) == "number" and type(x0) == "number" and type(y0) == "number"
                    and type(x1) == "number" and type(y1) == "number" then
                    local s = UnitScale(u)
                    local rb = max(math.abs(x0), math.abs(x1), math.abs(y0), math.abs(y1)) * s
                    if not bb then
                        bb = { 0, 0, 0 }
                        occBox[a.key] = bb
                    end
                    if rb > bb[1] then bb[1] = rb end
                    if z1 * s > bb[2] then bb[2] = z1 * s end
                    if type(z0) == "number" and z0 * s < bb[3] then bb[3] = z0 * s end
                end
            end
            o.rb, o.top, o.feet = bb and bb[1] or 0, bb and bb[2] or 0, o.z
            if bb and bb[3] < 0 then
                local ground = sim.enc.arena.ground
                local under = ground and ground(u.x, u.y, o.z) or GroundZ(u.x, u.y)
                local drop = o.z - max(under, o.z + bb[3])
                if drop > 0 then
                    o.z, o.h, o.top = o.z - drop, o.h + drop, o.top + drop
                end
            end
            o.unit = u
        end
    end
    for fx, a in pairs(fxActors) do
        if a and not a.bad then
            local u = fx.unit
            if fx.kind == "missile" and u then
                local k = min(1, (sim.time - fx.at) / fx.dur)
                local x, y = fx.x + (u.x - fx.x) * k, fx.y + (u.y - fx.y) * k
                local z0 = GroundZ(fx.x, fx.y) + ATTACH.chest
                local z = z0 + (FeetZ(u) + AttachZ(u, CHEST) - z0) * k     -- (as DrawFxActors)
                n = n + 1
                local o = Occ(n)
                o.id, o.x, o.y, o.z, o.h, o.w = fx, x, y, z - 0.6, 1.2, 1.0
                o.rb, o.top, o.prio, o.unit = 0, 0, 1, nil
            elseif u and not u.dead then
                for i = 1, n do
                    local o = occList[i]
                    if o.unit == u then
                        o.top = max(o.top, o.feet - o.z + AttachZ(u, fx) + 1.5 * UnitScale(u))
                        break
                    end
                end
            end
        end
    end
    return occList, n
end

-- The marks in the room's own draw order (View:DrawFrame's lines).
local function DrawRoomLines()
    roomOn = true
    DrawEffects()
    roomOn = false
end

-- An enemy name plate as this client draws it in its Classic style (Blizzard_NamePlates: NamePlateConstants and
-- NamePlateUnitFrameMixin's classic branch): a 128 x 10 bar area, the 128 x 16 Nameplate-Border art centred on it,
-- the health fill (UI-TargetingFrame-BarFill) from 3.5 to 20.75 short of the right edge and half a pixel up, the
-- level centred 11 left of the art's right edge, the name centred 4 above, your debuffs above the name.
-- The client's plate art, Interface\Tooltips\Nameplate-Border (file 137053), is 128 x 32 with the frame in its lower
-- half (rows 15-31): the bar shows through its opening (columns 5-105, rows 20-26; the bar runs one pixel under the
-- rim on each side, columns 4-106 and rows 19-27, so no gap shows) and the level sits in the box at columns 107-125.
-- The border is drawn at its own size over the bar, its opening centred on the plate frame (PLATE_W x PLATE_H).
local PLATE_W, PLATE_H, PLATE_FILL, PLATE_BAR_H = 128, 10, 103, 9
local PLATE_STEP = 46        -- how far plates of enemies standing together climb above each other

local function PlateFont(name, fallback)
    return _G[name] and name or fallback
end

local function Plate(i)
    local f = plates[i]
    if f then return f end
    f = CreateFrame("Button", nil, plateFrame)
    f:SetSize(PLATE_W, PLATE_H)
    f.hp = f:CreateTexture(nil, "ARTWORK")
    f.hp:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-BarFill")
    f.hp:SetPoint("LEFT", f, "LEFT", 4, 0)
    f.hp:SetHeight(PLATE_BAR_H)
    f.glow = f:CreateTexture(nil, "ARTWORK", nil, 1)            -- the target's bar is brightened
    f.glow:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-BarFill")
    f.glow:SetBlendMode("ADD")
    f.glow:SetAlpha(0.25)
    f.glow:SetAllPoints(f.hp)
    f.border = f:CreateTexture(nil, "OVERLAY")                   -- over the bar: its rim frames it
    f.border:SetTexture("Interface\\Tooltips\\Nameplate-Border")
    f.border:SetSize(128, 32)
    f.border:SetPoint("LEFT", f, "LEFT", 0, 7.5)                 -- (the opening's middle, row 23.5, 7.5 under its own)
    f.level = f:CreateFontString(nil, "OVERLAY", PlateFont("SystemFont_NamePlateLevel", "GameFontNormalSmall"))
    f.level:SetDrawLayer("OVERLAY", 1)
    f.level:SetPoint("CENTER", f, "RIGHT", -11.5, 0)
    f.skull = f:CreateTexture(nil, "OVERLAY", nil, 1)
    f.skull:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    f.skull:SetSize(15, 15)
    f.skull:SetPoint("CENTER", f, "RIGHT", -11.5, 0)
    f.name = f:CreateFontString(nil, "OVERLAY", PlateFont("SystemFont_NamePlate", "GameFontHighlightSmall"))
    f.name:SetPoint("BOTTOM", f, "TOP", 0, 6)                    -- (the border's top edge is 3.5 over the frame's)
    f.debuffs = {}
    f:SetScript("OnClick", function(self)
        if not (sim and self.unit) then return end
        if self.unit.interact then sim:Interact(self.unit) else sim:SetTarget(self.unit) end
    end)
    plates[i] = f
    return f
end

local function PlateDebuff(f, i)
    local b = f.debuffs[i]
    if b then return b end
    b = CreateFrame("Frame", nil, f)
    b:SetSize(20, 20)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.count:SetPoint("BOTTOMRIGHT", 3, -2)
    f.debuffs[i] = b
    return b
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
        local height = u.plate or PLATE_HEIGHT[u.kind]
        if height and not u.dead then
            local x, y = Project(u.x, u.y, FeetZ(u) + height)
            if x then
                n = n + 1
                local f = Plate(n)
                f.unit = u
                -- an enemy has the bar; an ally or a thing you can use only its name, as the client shows them
                local nameOnly = u.friendly or u.label
                f.border:SetShown(not nameOnly)
                f.hp:SetShown(not nameOnly)
                if nameOnly then
                    f.name:SetTextColor(u.label and 1 or 0.4, u.label and 0.82 or 0.75, u.label and 0 or 1)
                else
                    f.name:SetTextColor(1, 1, 1)
                end
                -- plates of enemies standing together climb above each other instead of covering each other
                local moved, passes = true, 0
                while moved and passes < 8 do
                    moved, passes = false, passes + 1
                    for k = 1, n - 1 do
                        local o = plates[k]
                        -- (a little under the step: o.py + step - o.py can come out a hair short and would
                        -- collide forever)
                        if math.abs(o.px - x) < PLATE_W and math.abs(o.py - y) < PLATE_STEP - 1 then
                            y = o.py + PLATE_STEP
                            moved = true
                        end
                    end
                end
                f.px, f.py = x, y
                f:ClearAllPoints()
                f:SetPoint("CENTER", scene, "BOTTOMLEFT", x, y)
                f.name:SetText(u.name)
                local isTarget = sim.target == u
                f:SetAlpha((isTarget or nameOnly or not sim.target) and 1 or 0.6)   -- the others dim, as the client's do
                f.glow:SetShown(isTarget and not nameOnly)
                f.hp:SetVertexColor(1, 0, 0)                                -- hostile
                f.hp:SetWidth(max(0.1, PLATE_FILL * (u.hp and u.hp / u.hpMax or 1)))
                local level = u.level or 70
                f.skull:SetShown(level < 0 and not nameOnly)
                f.level:SetText((level < 0 or nameOnly) and "" or level)
                f.level:SetTextColor(1, 1, 0)                               -- your own level: yellow
                -- your debuffs on it, in a row centred above the name
                local shownAuras = 0
                for _, aura in pairs(u.auras) do
                    if aura.icon then
                        shownAuras = shownAuras + 1
                        local b = PlateDebuff(f, shownAuras)
                        b.icon:SetTexture(aura.icon)
                        b.count:SetText(aura.stacks > 1 and aura.stacks or "")
                        b:Show()
                    end
                end
                for k = 1, #f.debuffs do
                    local b = f.debuffs[k]
                    if k <= shownAuras then
                        b:ClearAllPoints()
                        b:SetPoint("BOTTOM", f.name, "TOP", (k - (shownAuras + 1) / 2) * 22, 2)
                    else
                        b:Hide()
                    end
                end
                f:EnableMouse((u.targetable or u.selectable or u.interact) and true or false)
                f:Show()
            end
        end
    end
    for i = n + 1, #plates do
        plates[i].unit = nil
        plates[i]:Hide()
    end
end

-- A click in the view: the enemy whose body is under the cursor (the nearest one if several are), else the one
-- whose body is closest to it within 40 pixels.
local function PickAt(x, y)
    local best, bestScore
    for _, u in ipairs(sim.units) do
        if not u.dead and (u.targetable or u.selectable or u.interact) then
            local ground = FeetZ(u)
            local fx, fy = Project(u.x, u.y, ground)
            local hx, hy = Project(u.x, u.y, ground + (u.plate or u.tall or PLATE_HEIGHT[u.kind] or 3))
            if fx and hx then
                local half = max(10, math.abs(hy - fy) * 0.35)
                local cx, cy = (fx + hx) / 2, (fy + hy) / 2
                local inside = math.abs(x - cx) <= half and y >= min(fy, hy) - 4 and y <= max(fy, hy) + 16
                local dx, dy = x - cx, y - cy
                local miss = math.sqrt(dx * dx + dy * dy)
                -- a hit beats any miss; among hits the one closest to the camera, among misses the nearest
                local depth = (u.x - cam.x) * cam.fx + (SY(u.y) - cam.y) * cam.fy
                local score = inside and depth or (miss <= half + 40 and 100000 + miss or nil)
                if score and (not bestScore or score < bestScore) then best, bestScore = u, score end
            end
        end
    end
    if best then
        if best.interact then sim:Interact(best) else sim:SetTarget(best) end
    end
    return best
end

local function CursorInScene()
    return v3:Cursor()
end

-- One frame of the 3D view (spec 5.1). elapsed: seconds since the last frame (nil: a jump, e.g. the result).
local function Draw3D(elapsed)
    local mesh = sim.enc.arena.mesh
    local room = Room and mesh and Room.SetMesh(mesh)          -- (nothing when unchanged; false: the flat floor map)
    if not cam.calibrated then Calibrate() end
    PlaceCamera(elapsed, room)
    DrawActors()
    DrawFxActors()
    if room then
        -- (when the room draws: the models' planes and boxes for the copies, the room - at once when the camera did
        -- not move -, the marks in its order, the room in front of the models over them)
        v3:DrawFrame(BuildOccluders, nil, DrawRoomLines)
    else
        DrawFloor()
        DrawEffects()
    end
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
    for fx in pairs(fxActors) do ReleaseFxActor(fx) end
    ResetUnitFrames()
    if Room then Room.Clear() end
    for _, l in ipairs(floorLines) do l:Hide() end
    for _, l in ipairs(fxLines) do l:Hide() end
    for _, fs in ipairs(markLabels) do
        fs:Hide()
        fs.dzShown = false
    end
    for _, t in ipairs(floorTiles) do t:Hide() end
    for _, f in ipairs(plates) do f:Hide() end
end

-- The sounds the sim asked for since the last frame (sound kits, as the spells' visuals name them).
local function PlaySounds()
    for i, kit in ipairs(sim.sounds) do
        if PlaySound then pcall(PlaySound, kit, "SFX") end
        sim.sounds[i] = nil
    end
end

local function MouseLook()
    if not (mouse.look and sim and sim.state == "run" and focused) then return end
    local x, y = GetCursorPosition()
    local dx, dy = x - mouse.lastX, y - (mouse.lastY or y)
    mouse.lastX, mouse.lastY = x, y
    if dx ~= 0 then sim:Turn(-dx * 0.006) end
    if dy ~= 0 then cam.pitch = max(0.05, min(1.3, cam.pitch - dy * 0.004)) end      -- drag up: look up
end

-- The 3D view (Render3D/View.lua: the scene, its floor and plate frames, the room renderer under the scene). Without
-- it (the client not restarted after the update that brought it, or no ModelScene) the minimap is the game.
local function CreateScene(parent)
    v3 = R3 and R3.NewView and R3.NewView(parent, { cam = cam, room = Room or false, lv = LV, near = NEAR_CLIP,
                                                   fov = 1.1, far = 500, anim = ANIM_STAND })
    if not v3 then return end
    scene, floorFrame, plateFrame = v3.scene, v3.floorFrame, v3.plateFrame
    follow = R3.NewFollowCam(cam)
    actorPool[1] = v3.probe
    local sc = scene
    sc:EnableMouse(true)
    sc:EnableMouseWheel(true)
    sc:SetScript("OnMouseDown", function(_, button)
        if button == "RightButton" then
            mouse.look = true
            mouse.lastX, mouse.lastY = GetCursorPosition()
        elseif button == "LeftButton" then
            mouse.left = true
            mouse.downX, mouse.downY = CursorInScene()
        end
        ApplyMove()
    end)
    sc:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            mouse.look = false
        elseif button == "LeftButton" then
            mouse.left = false
            -- a click (not a drag, not running with both buttons) targets what is under the cursor
            local x, y = CursorInScene()
            if sim and sim.state == "run" and not mouse.look and mouse.downX
                and math.abs(x - mouse.downX) < 6 and math.abs(y - mouse.downY) < 6 then
                PickAt(x, y)
            end
        end
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
        f.label:SetText(scene and "" or (z.label or ""))        -- (the 3D view has the labels)
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
    local flat = {}
    for _, fx in ipairs(sim.fx) do
        if fx.kind == "ring" or fx.kind == "beam" then flat[#flat + 1] = fx end
    end
    for _, fx in ipairs(flat) do
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

---------------------------------------------------------------------------
-- The client's own look: player and target frame (Blizzard's unit frame art), debuffs with their sweep and
-- stack count, your own auras with the time left, and damage numbers floating off what you hit.
---------------------------------------------------------------------------

local UF_TEX = "Interface\\TargetingFrame\\UI-TargetingFrame"
local UF_ELITE = "Interface\\TargetingFrame\\UI-TargetingFrame-Elite"
local BAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"
local hud = { texts = {}, textPool = {}, debuffs = {}, auras = {} }

-- One unit frame in the stock layout (232 x 100; the target's art is the player's, mirrored).
local function NewUnitFrame(parent, isPlayer)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(232, 100)
    f.portrait = f:CreateTexture(nil, "BACKGROUND")
    f.portrait:SetSize(64, 64)
    f.nameBg = f:CreateTexture(nil, "BACKGROUND")
    f.nameBg:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-LevelBackground")
    f.nameBg:SetSize(119, 19)
    f.barBg = f:CreateTexture(nil, "BACKGROUND")
    f.barBg:SetColorTexture(0, 0, 0, 0.5)
    f.barBg:SetSize(119, 23)
    f.hp = f:CreateTexture(nil, "BORDER")
    f.hp:SetTexture(BAR_TEX)
    f.hp:SetVertexColor(0, 1, 0)
    f.hp:SetHeight(12)
    f.mp = f:CreateTexture(nil, "BORDER")
    f.mp:SetTexture(BAR_TEX)
    f.mp:SetVertexColor(0, 0, 1)
    f.mp:SetSize(119, 11)
    f.art = f:CreateTexture(nil, "ARTWORK")
    f.art:SetTexture(UF_TEX)
    f.art:SetAllPoints()
    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.name:SetWidth(100)
    f.level = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.hpText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hpText:SetPoint("CENTER", f.hp, "LEFT", 59.5, 0)
    if isPlayer then
        f.art:SetTexCoord(1, 0.09375, 0, 0.78125)
        f.portrait:SetPoint("TOPLEFT", 42, -12)
        f.nameBg:SetPoint("TOPLEFT", 106, -22)
        f.barBg:SetPoint("TOPLEFT", 106, -41)
        f.hp:SetPoint("TOPLEFT", 106, -41)
        f.mp:SetPoint("TOPLEFT", 106, -52)
        f.name:SetPoint("CENTER", 50, 19)
        f.level:SetPoint("CENTER", -63, -16)
    else
        f.art:SetTexCoord(0.09375, 1, 0, 0.78125)
        f.portrait:SetPoint("TOPRIGHT", -42, -12)
        f.nameBg:SetPoint("TOPLEFT", 7, -22)
        f.barBg:SetPoint("TOPLEFT", 7, -41)
        f.hp:SetPoint("TOPLEFT", 7, -41)
        f.mp:SetPoint("TOPLEFT", 7, -52)
        f.name:SetPoint("CENTER", -50, 19)
        f.level:SetPoint("CENTER", 63, -16)
    end
    return f
end

local function SetPortrait(f, u)
    local key = u.model or u.display
    if f.portraitKey == key then return end
    f.portraitKey = key
    if u.model == "player" and SetPortraitTexture then
        pcall(SetPortraitTexture, f.portrait, "player")
    elseif u.display and SetPortraitTextureFromCreatureDisplayID then
        pcall(SetPortraitTextureFromCreatureDisplayID, f.portrait, u.display)
    else
        f.portrait:SetTexture("Interface\\CharacterFrame\\TempPortrait")
    end
end

local function FillUnitFrame(f, u, name)
    SetPortrait(f, u)
    f.name:SetText(name or u.name)
    local level = u.level or 70
    f.level:SetText(level < 0 and "??" or level)
    f.art:SetTexture((u.elite and not f.isPlayer) and UF_ELITE or UF_TEX)
    local frac = (u.hp and u.hpMax) and (u.hp / u.hpMax) or 1
    f.hp:SetWidth(max(0.1, 119 * frac))
    if u.hp and u.hpPercent then
        f.hpText:SetText(string.format("%d%%", frac * 100 + 0.5))
    else
        f.hpText:SetText(u.hp and string.format("%d / %d", u.hp, u.hpMax) or "")
    end
    if not f.isPlayer then
        if u.friendly then f.nameBg:SetVertexColor(0, 0.7, 0) else f.nameBg:SetVertexColor(1, 0, 0) end
    end
    f.mp:SetShown(u.mana ~= false)
end

-- A debuff on the target frame: icon, the coloured debuff border, the stack count, the client's cooldown sweep.
local function DebuffButton(i)
    local b = hud.debuffs[i]
    if b then return b end
    b = CreateFrame("Frame", nil, hud.target)
    b:SetSize(21, 21)
    b:SetPoint("TOPLEFT", hud.target, "BOTTOMLEFT", 5 + (i - 1) * 24, 32)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
    b.border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
    b.border:SetPoint("TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", 1, -1)
    local ok, cd = pcall(CreateFrame, "Cooldown", nil, b, "CooldownFrameTemplate")
    if ok and cd then
        cd:SetAllPoints()
        if cd.SetReverse then cd:SetReverse(true) end
        b.cd = cd
    end
    local top = CreateFrame("Frame", nil, b)
    top:SetAllPoints()
    top:SetFrameLevel(b:GetFrameLevel() + 3)
    b.count = top:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.count:SetPoint("BOTTOMRIGHT", 2, -1)
    hud.debuffs[i] = b
    return b
end

-- One of your own auras, top right like the buff bar: icon and the time left under it.
local function AuraButton(i)
    local b = hud.auras[i]
    if b then return b end
    b = CreateFrame("Frame", nil, hud.frame)
    b:SetSize(30, 30)
    b:SetPoint("TOPRIGHT", view, "TOPRIGHT", -(MINI_W + 18) - (i - 1) * 36, -8)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
    b.border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
    b.border:SetPoint("TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", 1, -1)
    b.time = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.time:SetPoint("TOP", b, "BOTTOM", 0, -1)
    hud.auras[i] = b
    return b
end

local function CreateUnitFrames()
    hud.frame = CreateFrame("Frame", nil, view)
    hud.frame:SetAllPoints()
    hud.frame:SetFrameLevel(view:GetFrameLevel() + LV.arena)
    hud.player = NewUnitFrame(hud.frame, true)
    hud.player.isPlayer = true
    hud.player:SetScale(0.72)
    hud.player:SetPoint("TOPLEFT", view, "TOPLEFT", -14, -2)
    hud.target = NewUnitFrame(hud.frame, false)
    hud.target:SetScale(0.72)
    hud.target:SetPoint("TOPLEFT", view, "TOPLEFT", 212, -2)
    hud.target.nameBg:SetVertexColor(1, 0, 0)                    -- hostile
    hud.player.nameBg:SetVertexColor(0, 0, 1)
    hud.frame:Hide()
end

-- A number floating up from where the hit landed, in the client's damage font, spell yellow.
local function FloatText(hit)
    local fs = table.remove(hud.textPool)
    if not fs then
        fs = plateFrame:CreateFontString(nil, "OVERLAY")
        fs:SetFont(DAMAGE_TEXT_FONT or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
        fs:SetTextColor(1, 1, 0)
    end
    fs:SetText(hit.amount)
    hud.texts[#hud.texts + 1] = { fs = fs, at = sim.time, x = hit.x, y = hit.y, tall = PLATE_HEIGHT[hit.kind] or 2.6,
                                  drift = ((#hud.texts % 3) - 1) * 14 }
end

local function DrawCombatText()
    for i, hit in ipairs(sim.hits) do
        FloatText(hit)
        sim.hits[i] = nil
    end
    for i = #hud.texts, 1, -1 do
        local t = hud.texts[i]
        local k = (sim.time - t.at) / 1.3
        local x, y = Project(t.x, t.y, GroundZ(t.x, t.y) + t.tall)
        if k >= 1 or k < 0 or not x then
            t.fs:Hide()
            hud.textPool[#hud.textPool + 1] = t.fs
            table.remove(hud.texts, i)
        else
            t.fs:ClearAllPoints()
            t.fs:SetPoint("CENTER", scene, "BOTTOMLEFT", x + t.drift, y + 24 + 70 * k)
            t.fs:SetAlpha(k < 0.6 and 1 or (1 - k) / 0.4)
            t.fs:Show()
        end
    end
end

local function DrawUnitFrames()
    hud.frame:Show()
    local p = sim.player
    FillUnitFrame(hud.player, p, p.ghost and p.name or (UnitName and UnitName("player")) or p.name)
    local t = sim.target
    hud.target:SetShown(t ~= nil and not t.dead)
    local n = 0
    if t and not t.dead then
        FillUnitFrame(hud.target, t)
        for id, aura in pairs(t.auras) do
            if aura.icon then
                n = n + 1
                local b = DebuffButton(n)
                b.icon:SetTexture(aura.icon)
                b.border:SetVertexColor(0.2, 0.6, 1)                 -- magic
                b.count:SetText(aura.stacks > 1 and aura.stacks or "")
                -- the sweep runs on the client's clock: start it where the aura stands now
                if b.cd and (b.auraRef ~= aura or b.auraAt ~= aura.at) then
                    b.auraRef, b.auraAt = aura, aura.at
                    pcall(b.cd.SetCooldown, b.cd, GetTime() - (sim.time - aura.at), aura.total)
                end
                b:Show()
            end
        end
    end
    for i = n + 1, #hud.debuffs do
        hud.debuffs[i].auraRef = nil
        hud.debuffs[i]:Hide()
    end
    -- your own auras: the encounter's timers (Shadow of Death, the spirit's minute)
    local m = 0
    for _, bar in ipairs(sim.bars) do
        if bar.icon then
            m = m + 1
            local b = AuraButton(m)
            b.icon:SetTexture(bar.icon)
            b.border:SetShown(bar.harmful and true or false)
            b.border:SetVertexColor(0.8, 0, 0)
            local left = bar.remain
            b.time:SetText(not left and "" or (left >= 60 and string.format("%d m", left / 60 + 0.5) or string.format("%d s", left + 0.5)))
            b:Show()
        end
    end
    for i = m + 1, #hud.auras do hud.auras[i]:Hide() end
    DrawCombatText()
end

function ResetUnitFrames()
    if not hud.frame then return end
    hud.frame:Hide()
    for i = #hud.texts, 1, -1 do
        hud.texts[i].fs:Hide()
        hud.textPool[#hud.textPool + 1] = hud.texts[i].fs
        hud.texts[i] = nil
    end
end

local HEADINGS = { "east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east" }

local function DrawHud()
    R.objective:SetText(sim.objective or "")
    R.status:SetText(sim.status and table.concat(sim.status, "\n") or "")
    for _, fs in ipairs(R.compass) do fs:SetShown(sim.enc.compass and true or false) end
    -- which way you look, on the minimap
    if R.facing then
        local p = sim.player
        R.facing:SetStartPoint("BOTTOMLEFT", arena, p.x * px, p.y * px)
        R.facing:SetEndPoint("BOTTOMLEFT", arena, p.x * px + cos(p.facing) * 12, p.y * px + sin(p.facing) * 12)
        R.facing:Show()
    end
    local bar = sim.bars[1]
    if scene then
        DrawUnitFrames()
        bar = nil                                   -- the timers are aura icons here
    elseif bar and not bar.remain then
        bar = nil
    end
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
    if scene and UIErrorsFrame and UIErrorsFrame.AddMessage then
        -- the client's own red error line ("Out of range.")
        if e and hud.lastError ~= e then
            hud.lastError = e
            pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, e.text, 1, 0.1, 0.1, 1)
        end
        R.error:Hide()
    elseif e and sim.time - e.at < 1.5 then
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

local function Draw(elapsed)
    if not sim then return end
    if scene then Draw3D(elapsed) end
    DrawZones()
    DrawUnits()
    if not scene then DrawFx() end
    DrawCorpse()
    DrawHud()
end

local function LayoutArena()
    local enc = Encounter()
    if not (enc and root) then return end
    local map = enc.arena.map
    if map then
        R.miniMap:SetTexture(map.file)
        R.miniMap:SetTexCoord(map.u0, map.u1, map.v0, map.v1)
    end
    local tiles = enc.arena.minimap
    R.miniMap:SetShown(map ~= nil and not tiles)
    R.miniMap.on = map ~= nil
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
    -- the client's own minimap tiles, each on its piece of the arena
    for i, tile in ipairs(tiles or {}) do
        local t = R.miniTiles[i]
        if not t then
            t = arena:CreateTexture(nil, "BACKGROUND", nil, 2)
            R.miniTiles[i] = t
        end
        t:SetTexture(tile.file)
        t:SetTexCoord(unpack(tile.uv))
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", arena, "BOTTOMLEFT", tile.x0 * px, tile.y0 * px)
        t:SetSize((tile.x1 - tile.x0) * px, (tile.y1 - tile.y0) * px)
        t:Show()
    end
    for i = #(tiles or {}) + 1, #R.miniTiles do R.miniTiles[i]:Hide() end
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
            b.border = b:CreateTexture(nil, "OVERLAY")
            b.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
            b.border:SetPoint("TOPLEFT", -14, 14)
            b.border:SetPoint("BOTTOMRIGHT", 14, -14)
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
        lines[#lines + 1] = "W / S run, A / D turn, Q / E strafe. Hold the right mouse button to turn and look, wheel to zoom."
        lines[#lines + 1] = "Tab targets what is in front of you; or click a construct or its name plate. Esc pauses."
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
        PlaySounds()
        if sim.state ~= "run" then
            local score, best = T:Finish(sim)
            wipe(held)
            Draw()
            ShowResult(score, best)
            return
        end
    end
    Draw(elapsed)
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
    R.status:SetText("")
    for _, fs in ipairs(R.compass) do fs:Hide() end
    if R.facing then R.facing:Hide() end
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
    if Room and type(Data().render) == "table" then Room.SetOpts(Data().render) end   -- (/dz trainer render)
    if not (R3 and R3.NewView and Room) then
        -- a new file in the TOC is only read when the client starts: until then the fight is played on the minimap
        ns:Print("Raid Trainer: restart the game client once to load the 3D view (a /reload is not enough). Until then the fight is shown on the map only.")
    end
    if view:GetFrameLevel() + LV.overlay > 9990 then
        ns:Print("Raid Trainer: the window sits too high in the frame stack; the 3D view may draw in the wrong order.")
    end

    arena = CreateFrame("Frame", nil, view)
    arena:SetFrameLevel(view:GetFrameLevel() + LV.arena)
    if scene then arena:SetPoint("TOPRIGHT", view, "TOPRIGHT", -6, -6) else arena:SetPoint("CENTER") end
    arena:SetSize(MINI_W, MINI_H)
    local floorTex = arena:CreateTexture(nil, "BACKGROUND")
    floorTex:SetAllPoints()
    floorTex:SetColorTexture(0.09, 0.08, 0.11, scene and 0.8 or 1)
    R.miniTiles = {}
    R.miniMap = arena:CreateTexture(nil, "BACKGROUND", nil, 1)
    R.miniMap:SetAllPoints()
    R.miniMap:SetVertexColor(0.8, 0.8, 0.8)
    R.miniMap:Hide()
    ns.UI:AddEdges(arena)
    ns.UI:SetEdgeColor(arena, 0.4, 0.3, 0.5, 1)
    arena:SetClipsChildren(true)

    if scene then CreateUnitFrames() end

    R.corpse = arena:CreateTexture(nil, "ARTWORK")
    R.corpse:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    R.corpse:SetSize(18, 18)
    R.corpse:Hide()

    R.timer = CreateFrame("Frame", nil, view)
    R.timer:SetFrameLevel(view:GetFrameLevel() + LV.hud)
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
    hud:SetFrameLevel(view:GetFrameLevel() + LV.hud)
    R.banner = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if scene then
        -- below the unit frames and aura icons, where the client puts its raid warnings
        R.banner:SetPoint("TOP", view, "TOP", 0, -104)
    else
        R.banner:SetPoint("TOP", R.timer, "BOTTOM", 0, -8)
    end
    R.banner:SetWidth(420)
    R.banner:Hide()
    -- the job card under the unit frames; the heading and "N" on the minimap
    R.status = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    R.status:SetPoint("TOPLEFT", view, "TOPLEFT", 10, -84)
    R.status:SetJustifyH("LEFT")
    R.status:SetSpacing(3)
    R.status:SetShadowColor(0, 0, 0, 1)
    R.status:SetShadowOffset(1, -1)
    R.compass = {}
    for i, c in ipairs({ { "N", "TOP", 0, -2 }, { "S", "BOTTOM", 0, 2 }, { "W", "LEFT", 3, 0 }, { "E", "RIGHT", -3, 0 } }) do
        local fs = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint(c[2], arena, c[2], c[3], c[4])
        fs:SetText(c[1])
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
        fs:Hide()
        R.compass[i] = fs
    end
    if hud.CreateLine then
        R.facing = hud:CreateLine(nil, "OVERLAY")
        R.facing:SetThickness(2)
        R.facing:SetColorTexture(1, 1, 1, 0.9)
        R.facing:Hide()
    end
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
    overlay:SetFrameLevel(view:GetFrameLevel() + LV.overlay)
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
    focusOverlay:SetFrameLevel(view:GetFrameLevel() + LV.focus)
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

-- The room renderer's switches, kept per character (Data().render) and set in game with /dz trainer render (spec 7.3,
-- 13: the fallbacks for what could not be checked outside the client). Applied when the panel is made.
local RENDER_SWITCHES = { copies = "the room drawn again over the models it hides", collision = "the camera kept out of "
    .. "the walls", morph = "texture morph between finer and coarser pieces", quads = "two triangles drawn as one "
    .. "texture where they can", opaque = "opaque textures (blending off)" }
local function RenderSettings()
    local d = Data()
    if type(d.render) ~= "table" then d.render = {} end
    return d.render
end
local function SlashTrainer(rest)
    local cmd, what, value = (rest or ""):lower():match("^(%S*)%s*(%S*)%s*(%S*)")
    if cmd ~= "render" then
        ns:Print("Raid Trainer: /dz trainer render [copies|collision|morph|quads|opaque on|off | target <n>|auto | reset]")
        return
    end
    local set = RenderSettings()
    if what == "reset" then
        local back = {}
        for k in pairs(set) do
            local v = Room and Room.Defaults and Room.Defaults[k]
            if v == nil then v = false end                      -- (target: back to the time controller's)
            back[k] = v
        end
        wipe(set)
        if Room then Room.SetOpts(back) end
        ns:Print("Raid Trainer: render settings back to their defaults.")
        return
    end
    if what == "target" then
        local n = tonumber(value)
        if value == "auto" then
            set.target = nil
            if Room then Room.SetOpts({ target = false }) end
        elseif n then
            n = max(300, min(4000, floor(n)))
            set.target = n
            if Room then Room.SetOpts({ target = n }) end
        end
    elseif RENDER_SWITCHES[what] and (value == "on" or value == "off") then
        set[what] = value == "on"
        if Room then Room.SetOpts({ [what] = value == "on" }) end
    elseif what ~= "" then
        ns:Print("Raid Trainer: unknown render setting '%s'.", what)
        return
    end
    if not Room then
        ns:Print("Raid Trainer: restart the game client once to load the new room renderer (a /reload is not enough).")
        return
    end
    local o, parts = Room.opts, {}
    for _, k in ipairs({ "copies", "collision", "morph", "quads", "opaque" }) do
        parts[#parts + 1] = k .. " " .. ((o[k] ~= false) and "on" or "off")
    end
    parts[#parts + 1] = "target " .. (tonumber(o.target) and tostring(o.target) or "auto")
    ns:Print("Raid Trainer render: %s.", table.concat(parts, ", "))
end
ns:RegisterSlash("trainer", SlashTrainer, "render <copies|collision|morph|quads|opaque> on|off, render target <n>|auto, "
    .. "render reset - the Raid Trainer's 3D room (fallbacks if it looks wrong)")

-- Tests
UI._Key = function(key, down) return HandleKey(key, down ~= false) end
UI._Sim = function() return sim end
UI._Mouse = function(look, left) mouse.look, mouse.left = look and true or false, left and true or false ApplyMove() end
UI._Camera = function() return cam end
UI._Fx = function()
    local out = {}
    for fx, a in pairs(fxActors) do
        if a then out[#out + 1] = { fdid = a.fileID or a.fdid, kind = fx.kind, shown = a.shown } end
    end
    return out
end
-- Tests: the floor map's tiles, and what the room shows (Room.lua): its pieces, copies and mark lines.
UI._Floor = function()
    local n = 0
    for _, t in ipairs(floorTiles) do if t:IsShown() then n = n + 1 end end
    local st = Room and Room.Stats()
    return { tiles = #floorTiles, shown = n, mini = R.miniMap.on or false,
             mesh = Room and Room.ShownTextures() or 0, copies = st and st.copies or 0,
             lines = Room and Room.ShownLines() or 0 }
end
UI._Hud = function()
    if not hud.frame then return nil end
    local debuffs, auras, texts = {}, {}, {}
    for _, b in ipairs(hud.debuffs) do
        if b:IsShown() then debuffs[#debuffs + 1] = { icon = b.icon:GetTexture(), count = b.count:GetText() or "" } end
    end
    for _, b in ipairs(hud.auras) do
        if b:IsShown() then auras[#auras + 1] = b.time:GetText() end
    end
    for _, t in ipairs(hud.texts) do texts[#texts + 1] = t.fs:GetText() end
    return { player = hud.player.name:GetText(), playerHp = hud.player.hpText:GetText(),
             target = hud.target:IsShown() and hud.target.name:GetText() or false,
             targetHp = hud.target.hpText:GetText(), targetLevel = hud.target.level:GetText(),
             targetWidth = hud.target.hp:GetWidth(), debuffs = debuffs, auras = auras, texts = texts }
end
UI._Guide = function()
    local labels = {}
    for _, fs in ipairs(markLabels) do if fs:IsShown() then labels[#labels + 1] = fs:GetText() end end
    local compass = {}
    for _, fs in ipairs(R.compass) do if fs:IsShown() then compass[#compass + 1] = fs:GetText() end end
    local tiles = 0
    for _, t in ipairs(R.miniTiles) do if t:IsShown() then tiles = tiles + 1 end end
    return { status = R.status:GetText(), compass = compass, labels = labels, tiles = tiles }
end
UI._Plates = function()
    local out = {}
    for _, f in ipairs(plates) do if f:IsShown() then out[#out + 1] = { f.px, f.py } end end
    return out
end
UI._Plate = function(i) return plates[i] end
UI._Project = function(x, y, z) return Project(x, y, GroundZ(x, y) + z) end
UI._ActorPos = function(unitId) local a = actors[unitId] if a then return { a:GetPosition() } end end
UI._Click = function(x, y) return PickAt(x, y) end
UI._Anim = function(unitId) return actors[unitId] and actors[unitId].anim end
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
-- Tests (tools/render_check.py, spec section 8; read only but _RenderOpts): the 3D view's frames; the renderer's
-- numbers; render options; the room's draw order and where the mark lines went; the mark segments drawn.
UI._View = function()
    return view, scene, Room and Room.Frames() or {}, Room and Room.CopyFrames() or {}, plateFrame, floorFrame
end
UI._Render = function()
    if not Room then return nil end
    local st = Room.Stats()
    st.camCur, st.camWant, st.collided = cam.cur or cam.dist, cam.dist, cam.collided or false
    return st
end
UI._RenderOpts = function(t) if Room then Room.SetOpts(t) end end
UI._Order = function() return Room and Room.Order() or nil end
UI._Marks = function() return Room and Room.Marks() or nil end
UI._Occluders = function() return Room and Room.Occluders() or nil end
