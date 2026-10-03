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
-- What a unit that stands and fights plays: { animation, seconds } in a loop (each unit starts somewhere else
-- in it). 17 Attack1H, 26 Ready1H, 29 ReadyBow, 51 ReadySpellDirected, 53 SpellCastDirected.
local ACTS = {
    melee = { { 26, 0.9 }, { 17, 1.1 } },
    caster = { { 51, 1.6 }, { 53, 0.9 }, { 0, 0.7 } },
    bow = { { 29, 2.5 }, { 0, 0.6 } },
}

local root, view, arena, overlay, focusOverlay
local scene, floorFrame, plateFrame      -- the 3D view (scene == nil: flat fallback)
local overFrame                          -- above the models: the pieces of the room that stand in front of one
local cam = { dist = 14, pitch = 0.3, pitchSign = 1, mirror = 1, x = 0, y = 0, z = 0, fx = 1, fy = 0, fz = 0 }
local actors = {}            -- unit id -> actor
local actorPool = {}
local plates = {}
local floorLines, fxLines = {}, {}
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

-- The floor's height at a spot (0 on a flat floor).
local function GroundZ(x, y)
    local fn = sim and sim.enc.arena.height
    return fn and fn(x, y) or 0
end

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
    local tx, ty, tz = p.x, SY(p.y), GroundZ(p.x, p.y) + 2.2
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
    local eye = GroundZ(p.x, p.y) + 2.2
    local _, cy = Project(p.x, p.y, eye)
    if not cy or math.abs(cy - h / 2) > h * 0.25 then
        cam.pitchSign = -cam.pitchSign
        PlaceCamera()
        local _, cy2 = Project(p.x, p.y, eye)
        if not cy2 or math.abs(cy2 - h / 2) > h * 0.25 then cam.pitchSign = -cam.pitchSign end   -- no better: keep
    end
    PlaceCamera()
    local cx = Project(p.x, p.y, eye)
    local lx = Project(p.x - sin(p.facing) * 2, p.y + cos(p.facing) * 2, eye)
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
        local show = (u.model or u.display) and (not u.dead or sim.time - (u.diedAt or 0) < 2.5)
        if show then
            local a = ActorFor(u)
            if a then
                seen[u.id] = true
                pcall(a.SetPosition, a, u.x, SY(u.y), GroundZ(u.x, u.y))
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
        local x1, y1, x2, y2 = x + cos(a1) * radius, y + sin(a1) * radius, x + cos(a2) * radius, y + sin(a2) * radius
        Segment(fxLines, "fx", plateFrame, x1, y1, GroundZ(x1, y1) + 0.1, x2, y2, GroundZ(x2, y2) + 0.1, r, g, b, a, thick)
    end
end

-- The room's own mesh (arena.mesh: Blizzard's triangles, textures and baked light). Every triangle is a Texture
-- whose corners are moved to where the camera sees them (two corners share the third point). The scene's camera
-- is measured once a frame (three projected points); the vertices are then projected here, in Lua. Triangles
-- facing away, behind the camera or off screen are hidden; the rest are layered far to near.
local meshState = { tex = {}, shown = {}, sx = {}, sy = {}, sd = {}, over = {}, occ = {}, nOcc = 0,
                    x0 = {}, x1 = {}, y0 = {}, y1 = {}, depth = {}, low = {}, models = {} }
local MESH_LAYERS = { "BACKGROUND", "BORDER", "ARTWORK" }
local MESH_FAR = 110

local function PrepareMesh(mesh)
    if mesh.ready then return end
    mesh.ready = true
    local v, t = mesh.verts, mesh.tris
    mesh.nVerts, mesh.nTris = #v / 6, #t / 4
    mesh.normal, mesh.light = {}, {}
    for i = 1, mesh.nTris do
        local a, b, c = (t[i * 4 - 3] - 1) * 6, (t[i * 4 - 2] - 1) * 6, (t[i * 4 - 1] - 1) * 6
        local ux, uy, uz = v[b + 1] - v[a + 1], v[b + 2] - v[a + 2], v[b + 3] - v[a + 3]
        local wx, wy, wz = v[c + 1] - v[a + 1], v[c + 2] - v[a + 2], v[c + 3] - v[a + 3]
        mesh.normal[i * 3 - 2], mesh.normal[i * 3 - 1], mesh.normal[i * 3] = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
        mesh.light[i] = (v[a + 6] + v[b + 6] + v[c + 6]) / 3
        -- walls, pillars, the faces of steps: what can stand in front of someone (a floor cannot)
        local nx, ny, nz = mesh.normal[i * 3 - 2], mesh.normal[i * 3 - 1], mesh.normal[i * 3]
        mesh.steep = mesh.steep or {}
        mesh.steep[i] = nz < 0.7 * math.sqrt(nx * nx + ny * ny + nz * nz)
    end
end

local function HideMesh()
    for i in pairs(meshState.shown) do
        meshState.tex[i]:Hide()
        meshState.shown[i] = nil
    end
    meshState.key = nil
end

-- The room is drawn under the models, so by itself a pillar between the camera and a character would be painted
-- over by that character. Each frame: find the triangles that are nearer than a model they overlap on screen and
-- can hide it (anything steep; a floor only when it lies above that model's feet, like a walkway seen from below
-- or beside); those, and every triangle nearer still that touches no model, move to a frame above the models.
-- A triangle that has a model in front of it, or that a model stands on, stays below.
local function UpdateOcclusion()
    local st, b = meshState, meshState.basis
    if not (b and overFrame) then return end
    local models, nm = st.models, 0
    for _, u in ipairs(sim.units) do
        if actors[u.id] and not u.dead then
            local tall = PLATE_HEIGHT[u.kind] or 2.6
            local dx, dy, dz = u.x - b.camX, b.m * u.y - b.camY, GroundZ(u.x, u.y) - b.camZ
            local depth = dx * b.fx + dy * b.fy + dz * b.fz
            local top = depth + tall * b.fz
            if depth > 0.4 and top > 0.4 then
                local r, up = (dx * b.rx + dy * b.ry) / depth, (dx * b.ux + dy * b.uy + dz * b.uz) / depth
                local fx2, fy2 = b.cx + r * b.exx + up * b.eyx, b.cy + r * b.exy + up * b.eyy
                r, up = (dx * b.rx + dy * b.ry) / top, (dx * b.ux + dy * b.uy + (dz + tall) * b.uz) / top
                local hx, hy = b.cx + r * b.exx + up * b.eyx, b.cy + r * b.exy + up * b.eyy
                local half = max(8, math.abs(hy - fy2) * 0.3)
                nm = nm + 1
                local mo = models[nm] or {}
                models[nm] = mo
                mo.x0, mo.x1 = min(fx2, hx) - half, max(fx2, hx) + half
                mo.y0, mo.y1 = min(fy2, hy), max(fy2, hy)
                mo.depth = depth
                mo.z = dz + b.camZ
            end
        end
    end
    -- how deep the covering goes: the farthest model that has something in front of it
    local reach = 0
    local x0, x1, y0, y1, depth, occ = st.x0, st.x1, st.y0, st.y1, st.depth, st.occ
    local steep, low = st.mesh.steep, st.low
    for n = 1, st.nOcc do
        local i = occ[n]
        local d = depth[i]
        local blocked = false
        for j = 1, nm do
            local mo = models[j]
            if x1[i] >= mo.x0 and x0[i] <= mo.x1 and y1[i] >= mo.y0 and y0[i] <= mo.y1 then
                if d < mo.depth - 0.5 and (steep[i] or low[i] > mo.z + 0.4) then
                    if mo.depth > reach then reach = mo.depth end
                else
                    blocked = true
                end
            end
        end
        st.blocked = st.blocked or {}
        st.blocked[i] = blocked
    end
    for n = 1, st.nOcc do
        local i = occ[n]
        local over = depth[i] < reach - 0.5 and not st.blocked[i]
        if over ~= (st.over[i] or false) then
            st.over[i] = over or nil
            local tx = st.tex[i]
            tx:SetParent(over and overFrame or floorFrame)
            tx:SetDrawLayer(MESH_LAYERS[floor(tx.bucket / 16) + 1], tx.bucket % 16 - 8)
        end
    end
end

local function DrawMesh()
    local mesh = sim.enc.arena.mesh
    if not mesh then return false end
    if meshState.mesh ~= mesh then
        HideMesh()
        for _, tex in pairs(meshState.tex) do tex:Hide() end
        meshState.tex, meshState.mesh = {}, mesh
    end
    PrepareMesh(mesh)
    local w, h = scene:GetWidth() or 0, scene:GetHeight() or 0
    -- nothing moved: nothing to do
    local key = string.format("%.3f %.3f %.3f %.4f %.4f %.4f %d %d", cam.x, cam.y, cam.z, cam.fx, cam.fy, cam.fz, w, h)
    if meshState.key == key then
        UpdateOcclusion()                                              -- the view stands still, the others move
        return true
    end

    -- the camera, measured: the screen point straight ahead, and what one yard to the right and one yard up
    -- are worth there (10 yd ahead). All in scene space (y already mirrored).
    local m = cam.mirror
    local fx, fy, fz = cam.fx, cam.fy, cam.fz
    local flat = math.sqrt(fx * fx + fy * fy)
    if flat < 1e-4 then return true end
    local rx, ry = fy / flat, -fx / flat                               -- right = forward x up
    local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx            -- up = right x forward
    local function probe(dx, dy, dz)
        local ok, px, py = pcall(scene.Project3DPointTo2D, scene, cam.x + fx * 10 + dx, cam.y + fy * 10 + dy, cam.z + fz * 10 + dz)
        if ok and type(px) == "number" and type(py) == "number" then return px, py end
    end
    local cx, cy = probe(0, 0, 0)
    local px1, py1 = probe(rx, ry, 0)
    local px2, py2 = probe(ux, uy, uz)
    if not (cx and px1 and px2) then return true end
    local es = scene:GetEffectiveScale() or 1
    if es <= 0 then es = 1 end
    cx, cy = cx / es, cy / es
    local exx, exy = (px1 / es - cx) * 10, (py1 / es - cy) * 10       -- per yard to the right, at 1 yd ahead
    local eyx, eyy = (px2 / es - cx) * 10, (py2 / es - cy) * 10
    meshState.key = key

    local v, t, normal = mesh.verts, mesh.tris, mesh.normal
    local sx, sy, sd = meshState.sx, meshState.sy, meshState.sd
    local camX, camY, camZ = cam.x, cam.y, cam.z
    meshState.basis = { camX = camX, camY = camY, camZ = camZ, m = m, fx = fx, fy = fy, fz = fz, rx = rx, ry = ry,
                        ux = ux, uy = uy, uz = uz, cx = cx, cy = cy, exx = exx, exy = exy, eyx = eyx, eyy = eyy }
    local nOcc = 0
    for i = 1, mesh.nVerts do
        local o = i * 6 - 6
        local dx, dy, dz = v[o + 1] - camX, m * v[o + 2] - camY, v[o + 3] - camZ
        local depth = dx * fx + dy * fy + dz * fz
        if depth > 0.4 then
            local r = (dx * rx + dy * ry) / depth
            local u = (dx * ux + dy * uy + dz * uz) / depth
            sx[i], sy[i], sd[i] = cx + r * exx + u * eyx, cy + r * exy + u * eyy, depth
        else
            sd[i] = false
        end
    end

    local tex, shown = meshState.tex, meshState.shown
    local eyeX, eyeY = camX, m * camY                                  -- the camera in the mesh's own coordinates
    local buckets = #MESH_LAYERS * 16
    for i = 1, mesh.nTris do
        local a, b, c = t[i * 4 - 3], t[i * 4 - 2], t[i * 4 - 1]
        local da, db, dc = sd[a], sd[b], sd[c]
        local visible = false
        if da and db and dc then
            local o = (a - 1) * 6
            -- facing the camera?
            local facing = normal[i * 3 - 2] * (eyeX - v[o + 1]) + normal[i * 3 - 1] * (eyeY - v[o + 2]) + normal[i * 3] * (camZ - v[o + 3])
            if facing > 0 then
                local ax, ay, bx, by, qx, qy = sx[a], sy[a], sx[b], sy[b], sx[c], sy[c]
                if not ((ax < 0 and bx < 0 and qx < 0) or (ax > w and bx > w and qx > w)
                        or (ay < 0 and by < 0 and qy < 0) or (ay > h and by > h and qy > h)) then
                    visible = true
                    local tx = tex[i]
                    if not tx then
                        tx = floorFrame:CreateTexture(nil, "BACKGROUND")
                        tx:SetSize(1, 1)
                        tx:SetPoint("BOTTOMLEFT", scene, "BOTTOMLEFT", 0, 0)
                        tx:SetTexture(mesh.textures[t[i * 4]], "REPEAT", "REPEAT")
                        local oa, ob, oc = (a - 1) * 6, (b - 1) * 6, (c - 1) * 6
                        -- upper left = a, lower left = b, upper right and lower right = c
                        tx:SetTexCoord(v[oa + 4], v[oa + 5], v[ob + 4], v[ob + 5], v[oc + 4], v[oc + 5], v[oc + 4], v[oc + 5])
                        local l = mesh.light[i]
                        tx:SetVertexColor(l, l, l)
                        tex[i] = tx
                    end
                    tx:SetVertexOffset(1, ax, ay - 1)
                    tx:SetVertexOffset(2, bx, by)
                    tx:SetVertexOffset(3, qx - 1, qy - 1)
                    tx:SetVertexOffset(4, qx - 1, qy)
                    -- far ones first: three layers of sixteen sublevels
                    local depth = (da + db + dc) / 3
                    local bucket = buckets - 1 - max(0, min(buckets - 1, floor(depth / MESH_FAR * buckets)))
                    if tx.bucket ~= bucket then
                        tx.bucket = bucket
                        tx:SetDrawLayer(MESH_LAYERS[floor(bucket / 16) + 1], bucket % 16 - 8)
                    end
                    if not shown[i] then
                        shown[i] = true
                        tx:Show()
                    end
                    nOcc = nOcc + 1
                    meshState.occ[nOcc] = i
                    meshState.x0[i], meshState.x1[i] = min(ax, bx, qx), max(ax, bx, qx)
                    meshState.y0[i], meshState.y1[i] = min(ay, by, qy), max(ay, by, qy)
                    meshState.depth[i] = depth
                    if not meshState.low[i] then
                        meshState.low[i] = min(v[(a - 1) * 6 + 3], v[(b - 1) * 6 + 3], v[(c - 1) * 6 + 3])
                    end
                end
            end
        end
        if not visible and shown[i] then
            shown[i] = nil
            tex[i]:Hide()
            if meshState.over[i] then                                  -- out of sight: back under the models
                meshState.over[i] = nil
                tex[i]:SetParent(floorFrame)
                tex[i]:SetDrawLayer(MESH_LAYERS[floor(tex[i].bucket / 16) + 1], tex[i].bucket % 16 - 8)
            end
        end
    end
    meshState.nOcc = nOcc
    UpdateOcclusion()
    return true
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
                t = floorFrame:CreateTexture(nil, "BACKGROUND")
                if not t.SetVertexOffset then
                    t:Hide()
                    return false
                end
                t:SetSize(1, 1)
                t:SetPoint("BOTTOMLEFT", scene, "BOTTOMLEFT", 0, 0)
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
                t:SetVertexOffset(1, nwx, nwy - 1)
                t:SetVertexOffset(2, swx, swy)
                t:SetVertexOffset(3, nex - 1, ney - 1)
                t:SetVertexOffset(4, sex - 1, sey)
                t:Show()
            else
                t:Hide()                                              -- a corner is behind the camera
            end
        end
    end
    return true
end

-- The room: its floor map, its walls and a line every 10 yd, so distance and speed read at a glance.
local function DrawFloor()
    lineCount.floor = 0
    local w, h = sim.enc.arena.w, sim.enc.arena.h
    if DrawMesh() then                                                -- the real room: nothing else to draw
        for _, t in ipairs(floorTiles) do t:Hide() end
        for _, l in ipairs(floorLines) do l:Hide() end
        return
    end
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

local function DrawEffects()
    lineCount.fx = 0
    local t = sim.target
    if t and not t.dead then Circle(t.x, t.y, t.radius + 0.4, 1, 0.85, 0.1, 0.9, 2) end
    for i = lineCount.fx + 1, #fxLines do fxLines[i]:Hide() end
end

local function ReleaseFxActor(fx)
    local a = fxActors[fx]
    fxActors[fx] = nil
    if not a then return end
    pcall(a.SetShown, a, false)
    fxPool[a.fdid] = fxPool[a.fdid] or {}
    table.insert(fxPool[a.fdid], a)
end

-- The spells' own effect models: an actor per running effect, on its unit or flying to it.
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
                local x, y, z, yaw = fx.x, fx.y, fx.z or 0, 0
                if fx.kind == "missile" then
                    local k = min(1, (sim.time - fx.at) / fx.dur)
                    yaw = math.atan2(u.y - fx.y, u.x - fx.x)
                    x, y, z = fx.x + (u.x - fx.x) * k, fx.y + (u.y - fx.y) * k, 1.5
                elseif u then
                    x, y = u.x, u.y
                end
                pcall(a.SetPosition, a, x, SY(y), GroundZ(x, y) + z)
                pcall(a.SetYaw, a, cam.mirror * yaw)
                pcall(a.SetShown, a, not a.bad and not (u and u.dead and fx.kind ~= "missile"))
            end
        end
    end
    for fx in pairs(fxActors) do
        if not seen[fx] then ReleaseFxActor(fx) end
    end
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
            local x, y = Project(u.x, u.y, GroundZ(u.x, u.y) + height)
            if x then
                n = n + 1
                local f = Plate(n)
                f.unit = u
                -- plates of enemies standing together climb above each other instead of covering each other
                local moved, passes = true, 0
                while moved and passes < 8 do
                    moved, passes = false, passes + 1
                    for k = 1, n - 1 do
                        local o = plates[k]
                        -- (37, not 38: o.py + 38 - o.py can come out a hair under 38 and would collide forever)
                        if math.abs(o.px - x) < 100 and math.abs(o.py - y) < 37 then
                            y = o.py + 38
                            moved = true
                        end
                    end
                end
                f.px, f.py = x, y
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

-- A click in the view: the enemy whose body is under the cursor (the nearest one if several are), else the one
-- whose body is closest to it within 40 pixels.
local function PickAt(x, y)
    local best, bestScore
    for _, u in ipairs(sim.units) do
        if not u.dead and u.targetable then
            local ground = GroundZ(u.x, u.y)
            local fx, fy = Project(u.x, u.y, ground)
            local hx, hy = Project(u.x, u.y, ground + (PLATE_HEIGHT[u.kind] or 3))
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
    if best then sim:SetTarget(best) end
    return best
end

local function CursorInScene()
    local x, y = GetCursorPosition()
    local es = scene:GetEffectiveScale() or 1
    if es <= 0 then es = 1 end
    return x / es - (scene:GetLeft() or 0), y / es - (scene:GetBottom() or 0)
end

local function Draw3D()
    if not cam.calibrated then Calibrate() end
    PlaceCamera()
    DrawActors()
    DrawFloor()
    DrawEffects()
    DrawFxActors()
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
    HideMesh()
    for _, l in ipairs(floorLines) do l:Hide() end
    for _, l in ipairs(fxLines) do l:Hide() end
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
    overFrame = CreateFrame("Frame", nil, parent)
    overFrame:SetAllPoints()
    overFrame:SetFrameLevel(parent:GetFrameLevel() + 3)
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
    local map = enc.arena.map
    if map then
        R.miniMap:SetTexture(map.file)
        R.miniMap:SetTexCoord(map.u0, map.u1, map.v0, map.v1)
    end
    R.miniMap:SetShown(map ~= nil)
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
    R.miniMap = arena:CreateTexture(nil, "BACKGROUND", nil, 1)
    R.miniMap:SetAllPoints()
    R.miniMap:SetVertexColor(0.8, 0.8, 0.8)
    R.miniMap:Hide()
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
UI._Fx = function()
    local out = {}
    for fx, a in pairs(fxActors) do
        if a then out[#out + 1] = { fdid = a.fileID or a.fdid, kind = fx.kind, shown = a.shown } end
    end
    return out
end
UI._Floor = function()
    local n, m = 0, 0
    for _, t in ipairs(floorTiles) do if t:IsShown() then n = n + 1 end end
    for _ in pairs(meshState.shown) do m = m + 1 end
    local o = 0
    for _ in pairs(meshState.over) do o = o + 1 end
    return { tiles = #floorTiles, shown = n, mini = R.miniMap.on or false, mesh = m, over = o }
end
UI._OverDebug = function()
    local out, mesh = {}, meshState.mesh
    for i in pairs(meshState.over) do
        local a = (mesh.tris[i * 4 - 3] - 1) * 6
        out[#out + 1] = string.format('%.0f,%.0f,%.1f d=%.1f steep=%s', mesh.verts[a + 1], mesh.verts[a + 2], mesh.verts[a + 3], meshState.depth[i], tostring(mesh.steep[i]))
        if #out >= 12 then break end
    end
    local mo = {}
    for j, m in ipairs(meshState.models) do mo[#mo + 1] = string.format('%.1f z=%.1f', m.depth, m.z) end
    return { out, mo }
end
UI._Plates = function()
    local out = {}
    for _, f in ipairs(plates) do if f:IsShown() then out[#out + 1] = { f.px, f.py } end end
    return out
end
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
