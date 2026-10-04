if DisasterZoneBoot and DisasterZoneBoot.Run("UI/StrategyMap3D.lua", ...) then return end -- DisasterZone UI/StrategyMap3D.lua
-- The strategy board's 3D view: a mode of the map canvas (UI/StrategyMap.lua) that shows the page in the boss' own
-- room - Blizzard's mesh drawn by the shared renderer (Render3D/), the boss and its adds as their own models - seen
-- through a strategy-game camera.
--
-- One page, two views. The drawings stay what they are (tables in board units on the page); the room's map fit
-- (Render3D/Rooms.lua) makes a board point and a room point the same spot. So the canvas keeps every tool, the
-- selection, the menus, the links to the tables, undo, drafts and live co-editing; in 3D it only asks this view where
-- the mouse is (the floor under it, in board units), what is under it, and to draw.
--
-- A drawing in the room: a zone lies on the floor (outline and hatching, down steps and up platforms), an arrow runs
-- along the floor, a boss portrait is the creature's model at its real size, other icons and texts stand over their
-- spot like name plates, a player marker is a ring in the player's class colour with a post and a plate. Floor marks
-- go into the room's own draw order (a wall or a ledge in front hides them); plates stay on top, as the client's do.
--
-- The camera orbits a point on the floor: right-drag turns and tilts it, the wheel zooms, middle-drag (or the Pan tool,
-- or any left-drag while reading) moves it, a double-click on the floor looks there. All the way in it stands on that
-- point at eye height ("View from here"). It starts as the 2D map seen from straight above and tilts up, and goes back
-- the same way. A small copy of the 2D map in the corner shows where the camera is and what it sees; a click there
-- looks there.
local _, ns = ...

local M3 = ns:NewModule("StrategyMap3D")

local floor, ceil, min, max, abs, sqrt = math.floor, math.ceil, math.min, math.max, math.abs, math.sqrt
local sin, cos, pi = math.sin, math.cos, math.pi
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local tinsert, tsort = table.insert, table.sort

local function R3() return ns.Render3D end
local function MapUI() return ns.StrategyMapUI end
local function UI() return ns.UI end

-- Frame levels above the 3D frame's own (Render3D/View.lua puts the room, the scene and the plate frame there): the
-- room's cluster frames take room0 .. scene - 1 (more than the trainer's: Gorefiend's Vigil needs over 200), the
-- copies over the models copy0 .. copy0 + 31, the plates plates + 1 .. plates + CHIP_LEVELS (the nearest highest);
-- the camera buttons and the small map sit over all of it.
local LV = { floor = 1, lines = 2, room0 = 3, scene = 330, copy0 = 331, plates = 370, hud = 560 }
local CHIP_LEVELS = 180

local EYE = 1.9                       -- yd: the eye over the floor, all the way in
local PITCH_MIN, PITCH_LOOKUP, PITCH_TOP, PITCH_VIEW = 0.12, -0.5, 1.5, 0.9
local DIST_MIN, DIST_NEAR = 0.3, 40   -- yd: all the way in; a drawing looked at
local FOV = 1.1                       -- the scene's field of view (Render3D/View.lua's)
local TILT, MOVE = 0.5, 0.35          -- s: the map tilting into the room (and back); the camera moving to a view
local NORTH = pi / 2                  -- the heading that shows the room as the map does (north up)

-- Floor marks (yd over the floor, so they never sink into it), posts (yd)
local LIFT, LIFT_HATCH, LIFT_SEL = 0.08, 0.06, 0.11
local POST_ICON, POST_SLOT = 2.2, 1.6
local GOLD = { 1, 0.85, 0.1 }

---------------------------------------------------------------------------
-- Which pages can be drawn in a room
---------------------------------------------------------------------------

-- The room a page of a strategy for `bossRef` can be drawn in, or nil and why not: "restart" (the 3D files are not
-- loaded yet: the client was not restarted since the update), "none" (no room for this boss yet), "map" (the page
-- uses another map than the room's; the room comes third).
function M3:RoomFor(bossRef, page)
    local r3 = R3()
    if not (r3 and r3.NewView and r3.NewRoom and r3.RoomForBoss) then return nil, "restart" end
    local room = r3.RoomForBoss(bossRef)
    if not room then return nil, "none" end
    if not r3.HasFloor(room) then return nil, "restart" end
    local m = page and MapUI():ShippedMap(page.m)
    if not (m and m.file == room.map) then return nil, "map", room end
    return room
end

---------------------------------------------------------------------------
-- The view
---------------------------------------------------------------------------

local V = {}
V.__index = V

-- A canvas' 3D view (made the first time the canvas goes 3D), or nil when the client has no ModelScene for it.
function M3:Create(canvas)
    local r3 = R3()
    if not (r3 and r3.NewView) then return nil end
    local self = setmetatable({ canvas = canvas, cam = {}, chips = {}, hits = {}, handles = {}, arrowHits = {},
                                actors = {}, actorPool = {}, geo = setmetatable({}, { __mode = "k" }),
                                orb = { x = 0, y = 0, heading = NORTH, pitch = PITCH_VIEW, dist = 60 } }, V)
    local f = CreateFrame("Frame", nil, canvas.frame)
    f:SetAllPoints(canvas.frame)
    f:SetFrameLevel(canvas.frame:GetFrameLevel() + 1)
    f:SetClipsChildren(true)
    self.frame = f
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetColorTexture(0.03, 0.03, 0.05, 1)
    self.view = r3.NewView(f, { cam = self.cam, label = "Strategy board", lv = LV, near = 0.5, fov = FOV, far = 1500 })
    if not self.view then
        f:Hide()
        return nil
    end
    self.R = self.view.room
    self.actorPool[1] = self.view.probe
    self:CreateHud()
    f:SetScript("OnUpdate", function(_, elapsed) self:OnUpdate(elapsed) end)
    f:Hide()
    return self
end

function V:IsOn() return self.on == true end

function V:Invalidate() self.dirty = true end

-- A room point's floor (the room's own mesh, near the height grid there).
function V:Ground(x, y)
    local H = self.H
    local g = H and H(x, y) or 0
    return self.R and self.R.FloorZ(x, y, g) or g
end

-- How far over the floor the point looked at rides: the eye height all the way in, the floor itself from 5 yd out.
local function Lift(dist)
    return EYE * max(0, min(1, (5 - dist) / (5 - DIST_MIN)))
end

local function Clamp(v, lo, hi) return max(lo, min(hi, v)) end

-- The camera as self.orb says, handed to the scene.
function V:Place()
    local o = self.orb
    self.view:Orbit(o.x, o.y, self:Ground(o.x, o.y) + Lift(o.dist), o.heading, o.pitch, o.dist)
end

-- The farthest the camera may stand, and the box the point looked at stays in (the room and 30 yd round it).
function V:Limits()
    local fl = R3().Floor(self.room)
    local w, h = fl and fl.w or 100, fl and fl.h or 100
    return (self.room.view and self.room.view.dist or max(w, h)) * 2.2, -30, -30, w + 30, h + 30
end

function V:ClampOrb(o)
    local far, x0, y0, x1, y1 = self:Limits()
    o.x, o.y = Clamp(o.x, x0, x1), Clamp(o.y, y0, y1)
    o.dist = Clamp(o.dist, DIST_MIN, far)
    o.pitch = Clamp(o.pitch, o.dist < 3 and PITCH_LOOKUP or PITCH_MIN, PITCH_TOP)
    return o
end

---------------------------------------------------------------------------
-- Views: what the 2D map shows, the room, a drawing, a spot
---------------------------------------------------------------------------

local function Copy(o) return { x = o.x, y = o.y, heading = o.heading, pitch = o.pitch, dist = o.dist } end

-- The page seen from straight above as the 2D map frames it (north up): the board's middle and the distance at which
-- the board's width fills the view.
function V:MapView()
    local cv, r3 = self.canvas, R3()
    local x, y = r3.BoardToRoom(self.room, cv.page, 500, 333)
    local yx = r3.BoardScale(self.room, cv.page)
    local far = self:Limits()
    return self:ClampOrb({ x = x, y = y, heading = NORTH, pitch = PITCH_TOP,
                           dist = Clamp(1000 * yx / (2 * math.tan(FOV / 2)), 10, far) })
end

-- The view a room opens with: the selected drawing (close), else the room.
function V:DefaultView()
    local v = self.room.view or {}
    local o = { x = v.x or 50, y = v.y or 50, heading = NORTH, pitch = PITCH_VIEW, dist = v.dist or 60 }
    local e = self.canvas.selected
    if e and self.canvas.sel[e] then
        local g = self:Geo(e)
        o.x, o.y, o.dist = g.x, g.y, min(o.dist, DIST_NEAR)
    end
    return self:ClampOrb(o)
end

-- Moves the camera to view `to` over `dur` seconds (eased; the heading the short way round); after() when there.
function V:MoveTo(to, dur, after)
    self:ClampOrb(to)
    local from = Copy(self.orb)
    local dh = (to.heading - from.heading + pi) % (2 * pi) - pi
    to.heading = from.heading + dh
    self.anim = { from = from, to = to, t0 = GetTime(), dur = dur or MOVE, after = after }
    self:Invalidate()
end

-- Looks at a room point (keeps the angle; comes in to DIST_NEAR when farther).
function V:LookAt(x, y, close)
    local o = Copy(self.orb)
    o.x, o.y = x, y
    if close and o.dist > DIST_NEAR then o.dist = DIST_NEAR end
    if o.dist < 3 then o.dist, o.pitch = 12, max(o.pitch, 0.6) end
    self:MoveTo(o)
end

-- The first boss / add model on the page (its geometry), or nil.
function V:FirstModel()
    for _, e in ipairs(self.canvas.page and self.canvas.page.e or {}) do
        if e.t == "i" and type(e.i) == "string" and e.i:match("^boss:%d+$") then return self:Geo(e), e end
    end
end

-- Stands at a drawing at eye height: an arrow from its start along it, anything else facing the first model on the
-- page (a model faces the nearest player marker, else the room's middle).
function V:ViewFrom(e)
    local g = self:Geo(e)
    local x, y, tx, ty = g.x, g.y, nil, nil
    if e.t == "a" then
        tx, ty = g.x2, g.y2
    else
        local m, me = self:FirstModel()
        if m and me ~= e then
            tx, ty = m.x, m.y
        else
            local v = self.room.view or {}
            tx, ty = self:NearestSlot(x, y)
            if not tx then tx, ty = v.x or 50, v.y or 50 end
        end
    end
    local heading = self.orb.heading
    if tx and (abs(tx - x) + abs(ty - y)) > 0.01 then heading = atan2(ty - y, tx - x) end
    self:MoveTo({ x = x, y = y, heading = heading, pitch = 0.08, dist = DIST_MIN })
end

-- The player marker nearest a room point: its x, y, or nil.
function V:NearestSlot(x, y)
    local bx, by, best
    for _, e in ipairs(self.canvas.page and self.canvas.page.e or {}) do
        if e.t == "s" then
            local g = self:Geo(e)
            local d = (g.x - x) ^ 2 + (g.y - y) ^ 2
            if d > 1 and (not best or d < best) then bx, by, best = g.x, g.y, d end
        end
    end
    return bx, by
end

-- The drawings on this page that are mine (my player markers, drawings linked to my slots), page order.
function V:MySpots()
    local mine = self.canvas.opts.mySlots and self.canvas.opts.mySlots() or {}
    local out = {}
    for _, e in ipairs(self.canvas.page and self.canvas.page.e or {}) do
        if (e.t == "s" and mine[e.r]) or (e.ln and mine[e.ln]) then out[#out + 1] = e end
    end
    return out
end

function V:ViewMySpot()
    local spots = self:MySpots()
    if #spots == 0 then return false end
    self.spotI = (self.spotI or 0) % #spots + 1
    self:ViewFrom(spots[self.spotI])
    return true
end

function V:Rotate(steps)
    local o = Copy(self.anim and self.anim.to or self.orb)
    o.heading = o.heading + steps * pi / 4
    self:MoveTo(o)
end

-- Straight down (north up, as the map) and back to the usual tilt.
function V:ToggleTop()
    local o = Copy(self.anim and self.anim.to or self.orb)
    if o.pitch < PITCH_TOP - 0.05 then
        o.pitch, o.heading = PITCH_TOP, NORTH
        if o.dist < 12 then o.dist = 30 end
    else
        o.pitch = PITCH_VIEW
    end
    self:MoveTo(o)
end

function V:Reset()
    local v = self.room.view or {}
    self:MoveTo({ x = v.x or 50, y = v.y or 50, heading = NORTH, pitch = PITCH_VIEW, dist = v.dist or 60 })
end

-- Opens the view on the canvas' page (animate: the 2D map tilts up into the room). -> false without a room.
function V:Open(animate)
    local cv = self.canvas
    local room = M3:RoomFor(cv.opts.bossRef and cv.opts.bossRef(), cv.page)
    if not room then return false end
    local fl = R3().Floor(room)                       -- (a packed room is unpacked here, the first time)
    if not (fl and fl.mesh) then
        ns:Print("The 3D room of this boss could not be read.")
        return false
    end
    if room ~= self.room then
        self.room, self.calibrated = room, false
        self.hiZ, self.loZ = nil, nil
    end
    self.H = R3().Height(room)
    self.on, self.anim, self.drag3 = true, nil, nil
    self.frame:Show()
    self.R.SetMesh(fl.mesh)
    local goal = self:DefaultView()
    if animate then
        self.orb = self:MapView()
        self:MoveTo(goal, TILT)
    else
        self.orb = goal
    end
    self.spotI = nil
    self:Invalidate()
    return true
end

-- Leaves (animate: back down to the map seen from above first; done() then).
function V:Close(animate, done)
    local function finish()
        self.on, self.anim, self.drag3 = false, nil, nil
        self.frame:Hide()
        if self.R then self.R.Clear() end
        for e, a in pairs(self.actors) do
            pcall(a.SetShown, a, false)
            self.actors[e] = nil
            self.actorPool[#self.actorPool + 1] = a
        end
        if done then done() end
    end
    if animate and self.on and self.room then
        self:MoveTo(self:MapView(), TILT, finish)
    else
        finish()
    end
end

---------------------------------------------------------------------------
-- The floor under a screen point
---------------------------------------------------------------------------

-- The highest and lowest floor of the room's height grid (where a ray from above can meet it).
function V:HeightRange()
    if self.hiZ then return self.hiZ, self.loZ end
    local fl = R3().Floor(self.room)
    local hi, lo = 0, 0
    if fl and fl.rows then
        local index = {}
        local alphabet = fl.alphabet or "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        for k = 1, #alphabet do index[alphabet:byte(k)] = k - 1 end
        local first = true
        for _, row in ipairs(fl.rows) do
            for i = 1, #row do
                local n = index[row:byte(i)]
                if n then
                    local z = n * fl.step + fl.base
                    if first then hi, lo, first = z, z, false end
                    if z > hi then hi = z end
                    if z < lo then lo = z end
                end
            end
        end
    end
    self.hiZ, self.loZ = hi + 0.5, lo - 0.5
    return self.hiZ, self.loZ
end

-- The room point on the floor under a screen point (UI units from the scene's bottom-left), or nil (the view looks
-- over the horizon there). planeZ: meet that height instead of the floor (a drag that moves the camera); maxZ: floors
-- higher than that are looked through.
function V:FloorAt(sx, sy, planeZ, maxZ)
    local R = self.R
    local ex, ey, ez, dx, dy, dz = R.ScreenRay(sx, sy)
    if not ex then return nil end
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    dx, dy, dz = dx / len, dy / len, dz / len
    if planeZ then
        if dz > -1e-3 then return nil end
        local t = (planeZ - ez) / dz
        return ex + dx * t, ey + dy * t, planeZ
    end
    local hi, lo = self:HeightRange()
    if dz > -1e-3 and ez > hi then return nil end
    local t0 = (dz < -1e-3 and ez > hi) and (ez - hi) / -dz or 0
    local t1 = (dz < -1e-3) and (ez - lo) / -dz + 1 or (t0 + 300)
    local H = self.H or function() return 0 end
    local step = 0.4
    local prev = t0
    local t = t0
    while t <= t1 do
        local x, y, z = ex + dx * t, ey + dy * t, ez + dz * t
        local h = H(x, y)
        if z <= h and not (maxZ and h > maxZ) then
            local a, b = prev, t                          -- the crossing lies between: halve it down
            for _ = 1, 10 do
                local m = (a + b) / 2
                local mx, my = ex + dx * m, ey + dy * m
                if ez + dz * m <= H(mx, my) then b = m else a = m end
            end
            local hx, hy = ex + dx * b, ey + dy * b
            return hx, hy, self:Ground(hx, hy)
        end
        prev = t
        t = t + step
    end
    return nil
end

-- The cursor's floor point in the page's board units (unrounded), or nil. fromZ (a drawing being moved from a floor
-- that high): floors more than 3 yd over it are looked through, and where none is met, the mouse on that level.
function V:CursorBoard(fromZ)
    local sx, sy = self.view:Cursor()
    local x, y = self:FloorAt(sx, sy, nil, fromZ and fromZ + 3)
    if not x and fromZ then x, y = self:FloorAt(sx, sy, fromZ) end
    if not x then return nil end
    return R3().RoomToBoard(self.room, self.canvas.page, x, y)
end

-- The floor height (room yards) under a board point of the page.
function V:GroundAtBoard(bx, by)
    local x, y = R3().BoardToRoom(self.room, self.canvas.page, bx, by)
    return self:Ground(x, y)
end

---------------------------------------------------------------------------
-- Geometry of a drawing in the room (cached: the floor is searched only when the drawing or the map view changes)
---------------------------------------------------------------------------

-- Appends the segments of a floor path from (x1, y1) to (x2, y2), `lift` yd over the floor, in pieces of at most
-- `step` yd, to the flat list L (x1, y1, z1, x2, y2, z2, ...).
function V:Path(L, x1, y1, x2, y2, lift, step)
    local len = sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
    local n = max(1, min(48, ceil(len / (step or 1.5))))
    local px, py = x1, y1
    local pz = self:Ground(px, py) + lift
    for k = 1, n do
        local t = k / n
        local qx, qy = x1 + (x2 - x1) * t, y1 + (y2 - y1) * t
        local qz = self:Ground(qx, qy) + lift
        local o = #L
        L[o + 1], L[o + 2], L[o + 3], L[o + 4], L[o + 5], L[o + 6] = px, py, pz, qx, qy, qz
        px, py, pz = qx, qy, qz
    end
end

-- Appends an ellipse on the floor (centre, half axes) in n pieces.
function V:Ring(L, cx, cy, rx, ry, lift, n)
    n = n or max(12, min(40, ceil(2 * pi * max(rx, ry) / 1.2)))
    local px, py = cx + rx, cy
    local pz = self:Ground(px, py) + lift
    for k = 1, n do
        local a = k / n * 2 * pi
        local qx, qy = cx + cos(a) * rx, cy + sin(a) * ry
        local qz = self:Ground(qx, qy) + lift
        local o = #L
        L[o + 1], L[o + 2], L[o + 3], L[o + 4], L[o + 5], L[o + 6] = px, py, pz, qx, qy, qz
        px, py, pz = qx, qy, qz
    end
end

-- Appends a rectangle on the floor (centre, half sizes).
function V:Rect(L, cx, cy, hx, hy, lift)
    self:Path(L, cx - hx, cy - hy, cx + hx, cy - hy, lift)
    self:Path(L, cx + hx, cy - hy, cx + hx, cy + hy, lift)
    self:Path(L, cx + hx, cy + hy, cx - hx, cy + hy, lift)
    self:Path(L, cx - hx, cy + hy, cx - hx, cy - hy, lift)
end

-- The hatching of a zone: lines at 45 degrees about 2 yd apart (at most 12), clipped to the ellipse or rectangle.
function V:Hatch(L, g, round)
    local cx, cy, rx, ry = g.x, g.y, g.rx, g.ry
    local k = Clamp(floor(2 * max(rx, ry) / 2), 2, 12)
    local r2 = 1 / sqrt(2)
    for j = 1, k do
        local o = -1 + (2 * j - 1) / k                    -- the line's place across, -1 .. 1
        if round then
            -- in the unit circle: the chord at offset o along (1, 1), scaled back to the ellipse
            local half = sqrt(max(0, 1 - o * o))
            local ux, uy = -o * r2, o * r2
            self:Path(L, cx + (ux - half * r2) * rx, cy + (uy - half * r2) * ry,
                      cx + (ux + half * r2) * rx, cy + (uy + half * r2) * ry, LIFT_HATCH, 2.5)
        else
            -- y - y0 = x - x0 - c across the box (c from -(rx + ry) to rx + ry)
            local c = o * (rx + ry)
            local lo, hi = max(-rx, -ry + c), min(rx, ry + c)
            if hi - lo > 0.2 then
                self:Path(L, cx + lo, cy + lo - c, cx + hi, cy + hi - c, LIFT_HATCH, 2.5)
            end
        end
    end
end

local function Sig(e, view)
    return table.concat({ view, e.t, e.x, e.y, e.w or "", e.h == true and "h" or (e.h or ""), e.s or "", e.x2 or "",
                          e.y2 or "", e.i or "" }, ",")
end

-- A drawing's geometry in the room: x, y, z (its spot on the floor); a zone's half axes rx, ry and its outline,
-- hatching and selection outline (flat segment lists); an arrow's x2, y2, its path, head, selection lines and points
-- along it; a marker's ring and post; a model's display and scale.
function V:Geo(e)
    local cv, r3 = self.canvas, R3()
    local page = cv.page
    local view = self.room.key .. ":" .. tostring(page and page.vx) .. ":" .. tostring(page and page.vy) .. ":"
        .. tostring(page and page.vz)
    local sig = Sig(e, view)
    local g = self.geo[e]
    if g and g.sig == sig then return g end
    g = { sig = sig }
    self.geo[e] = g
    local room = self.room
    g.x, g.y = r3.BoardToRoom(room, page, e.x, e.y)
    g.z = self:Ground(g.x, g.y)
    if e.t == "z" then
        local sx, sy = r3.BoardScale(room, page)
        g.rx, g.ry = max(0.3, (e.w or 4) / 2 * sx), max(0.3, (e.h or 4) / 2 * sy)
        g.out, g.hatch, g.selOut = {}, {}, {}
        if e.s == "c" then
            self:Ring(g.out, g.x, g.y, g.rx, g.ry, LIFT)
            self:Ring(g.selOut, g.x, g.y, g.rx + 0.4, g.ry + 0.4, LIFT_SEL)
        else
            self:Rect(g.out, g.x, g.y, g.rx, g.ry, LIFT)
            self:Rect(g.selOut, g.x, g.y, g.rx + 0.4, g.ry + 0.4, LIFT_SEL)
        end
        self:Hatch(g.hatch, g, e.s == "c")
        local hx, hy = r3.BoardToRoom(room, page, e.x + e.w / 2, e.y + e.h / 2)
        g.handle = { hx, hy, self:Ground(hx, hy) + LIFT }
    elseif e.t == "a" then
        g.x2, g.y2 = r3.BoardToRoom(room, page, e.x2, e.y2)
        g.z2 = self:Ground(g.x2, g.y2)
        g.path, g.head, g.selOut = {}, {}, {}
        self:Path(g.path, g.x, g.y, g.x2, g.y2, LIFT + 0.02, 1.5)
        local dx, dy = g.x2 - g.x, g.y2 - g.y
        local len = sqrt(dx * dx + dy * dy)
        if len > 0.05 then
            local ux, uy = dx / len, dy / len
            if e.h then
                local L = min(2.2, 0.35 * len)
                for s = -1, 1, 2 do
                    local a = 0.45 * s
                    local bx = g.x2 - L * (ux * cos(a) - uy * sin(a))
                    local by = g.y2 - L * (uy * cos(a) + ux * sin(a))
                    self:Path(g.head, g.x2, g.y2, bx, by, LIFT + 0.02, 1)
                end
            end
            for s = -1, 1, 2 do                           -- the selection: a gold line along each side
                local ox, oy = -uy * 0.4 * s, ux * 0.4 * s
                self:Path(g.selOut, g.x + ox, g.y + oy, g.x2 + ox, g.y2 + oy, LIFT_SEL, 1.5)
            end
        end
        g.handle = { g.x, g.y, g.z + LIFT }
        g.handle2 = { g.x2, g.y2, g.z2 + LIFT }
    else
        g.ring, g.post = {}, nil
        local disp = e.t == "i" and type(e.i) == "string" and tonumber(e.i:match("^boss:(%d+)$"))
        if disp then
            local d = r3.DISPLAYS and r3.DISPLAYS[disp]
            g.display, g.scale, g.nameZ = disp, d and d.scale or 1, d and d.name
            self:Ring(g.ring, g.x, g.y, 0.6 * g.scale, 0.6 * g.scale, LIFT)
        elseif e.t == "s" then
            self:Ring(g.ring, g.x, g.y, 0.6, 0.6, LIFT, 14)
            g.post = POST_SLOT
        elseif e.t == "i" then
            self:Ring(g.ring, g.x, g.y, 0.45, 0.45, LIFT, 12)
            g.post = POST_ICON
        end
    end
    return g
end

---------------------------------------------------------------------------
-- Models (boss portraits as the creatures)
---------------------------------------------------------------------------

function V:Actor(e)
    local a = self.actors[e]
    if a then return a end
    a = table.remove(self.actorPool) or self.view:NewActor()
    if not a then return nil end
    self.actors[e] = a
    return a
end

-- Places the page's models: each where its portrait is, at its real size, facing the nearest player marker (else the
-- room's middle); the ones no longer on the page go back to the pool. -> the occluder records (Room.SetOccluders).
function V:DrawModels()
    local seen, n = {}, 0
    local occ = self.occ or {}
    self.occ = occ
    local cam = self.cam
    for _, e in ipairs(self.canvas.page and self.canvas.page.e or {}) do
        local g = e.t == "i" and self:Geo(e)
        if g and g.display then
            local a = self:Actor(e)
            if a then
                seen[e] = true
                if a.display ~= g.display then
                    a.display, a.anim, a.box, a.bb = g.display, 0, nil, nil
                    pcall(a.ClearModel, a)
                    pcall(a.SetModelByCreatureDisplayID, a, g.display)
                    a.loadAt = GetTime()
                end
                local s = g.scale
                if a.scale ~= s then
                    a.scale = s
                    pcall(a.SetScale, a, s)
                end
                local tx, ty = self:NearestSlot(g.x, g.y)
                if not tx then
                    local v = self.room.view or {}
                    tx, ty = v.x or g.x, v.y or g.y - 1
                end
                local face = ((abs(tx - g.x) + abs(ty - g.y)) > 0.5) and atan2(ty - g.y, tx - g.x) or -pi / 2
                pcall(a.SetPosition, a, g.x / s, self.view:SY(g.y) / s, g.z / s)
                pcall(a.SetYaw, a, cam.mirror * face)
                pcall(a.SetShown, a, true)
                -- its own box once loaded (model units): how far it reaches round its feet and under them (the
                -- Lurker: 15 yd across, half under the water), for what the room draws over it
                if not a.bb and a.GetActiveBoundingBox then
                    local ok, x0, y0, z0, x1, y1, z1 = pcall(a.GetActiveBoundingBox, a)
                    if ok and type(z1) == "number" and type(z0) == "number" and z1 > z0 then
                        a.bb = { r = max(abs(x0), abs(x1), abs(y0), abs(y1)), z0 = min(0, z0), z1 = z1 }
                    end
                end
                local bb = a.bb
                -- its height (the label goes over it): the model's name point, else its box
                local h = g.nameZ and (g.nameZ * s) or (bb and bb.z1 > 0 and bb.z1 * s) or nil
                g.h = (h or 2.5 * s) + 0.4
                local under = bb and -bb.z0 * s or 0
                n = n + 1
                local o = occ[n] or {}
                occ[n] = o
                o.id, o.x, o.y, o.z, o.h = e, g.x, g.y, g.z - under, g.h - 0.4 + under
                o.w, o.rb, o.top, o.prio = max(1.2, 0.8 * s), max(0.5 * s, bb and bb.r * s or 0), g.h + under, 1
            end
        end
    end
    for e, a in pairs(self.actors) do
        if not seen[e] then
            pcall(a.SetShown, a, false)
            self.actors[e] = nil
            self.actorPool[#self.actorPool + 1] = a
        end
    end
    self.nOcc = n
    return occ, n
end

---------------------------------------------------------------------------
-- Floor marks
---------------------------------------------------------------------------

local function Emit(R, L, r, g, b, a, thick)
    for o = 0, #L - 6, 6 do
        R.Line(L[o + 1], L[o + 2], L[o + 3], L[o + 4], L[o + 5], L[o + 6], r, g, b, a, thick)
    end
end

local function ClassColor(cls)
    local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
    if c then return c.r, c.g, c.b end
    return 0.85, 0.7, 0.3
end

-- What other members on the same live board have selected: element -> { r, g, b }.
function V:RemoteMarks()
    local out
    local cv = self.canvas
    for _, other in ipairs(cv.opts.remoteSel and cv.opts.remoteSel() or {}) do
        for _, e in ipairs(cv.page and cv.page.e or {}) do
            if e._u and other.sel[e._u] then
                out = out or {}
                out[e] = { other.r, other.g, other.b }
            end
        end
    end
    return out
end

function V:DrawLines(remote)
    local R, cv = self.R, self.canvas
    local lit, sel = cv.lit, cv.sel
    local list = cv.page and cv.page.e or {}
    -- zones under everything else, as on the map
    for _, e in ipairs(list) do
        if e.t == "z" then
            local g = self:Geo(e)
            local r, gg, b = MapUI():Color(e.c or 1)
            local hot = lit and lit[e]
            Emit(R, g.hatch, r, gg, b, hot and 0.6 or 0.35, hot and 2.5 or 1.5)
            Emit(R, g.out, r, gg, b, 0.95, hot and 5 or 3)
            local rc = remote and remote[e]
            if sel[e] then Emit(R, g.selOut, GOLD[1], GOLD[2], GOLD[3], 1, 2)
            elseif rc then Emit(R, g.selOut, rc[1], rc[2], rc[3], 0.95, 2) end
        end
    end
    for _, e in ipairs(list) do
        if e.t ~= "z" then
            local g = self:Geo(e)
            if e.t == "a" then
                local r, gg, b = MapUI():Color(e.c or 9)
                if lit and lit[e] then r, gg, b = GOLD[1], GOLD[2], GOLD[3] end
                Emit(R, g.path, r, gg, b, 0.95, 4)
                Emit(R, g.head, r, gg, b, 0.95, 4)
                local rc = remote and remote[e]
                if sel[e] then Emit(R, g.selOut, GOLD[1], GOLD[2], GOLD[3], 0.9, 2)
                elseif rc then Emit(R, g.selOut, rc[1], rc[2], rc[3], 0.9, 2) end
            elseif e.t == "s" then
                local cls = cv.opts.slotClass and cv.opts.slotClass(e.r)
                local r, gg, b = ClassColor(cls)
                Emit(R, g.ring, r, gg, b, 0.95, 3)
                R.Line(g.x, g.y, g.z + LIFT, g.x, g.y, g.z + g.post, r, gg, b, 0.9, 2)
            elseif g.display then
                local r, gg, b = MapUI():Color(e.c or 9)
                Emit(R, g.ring, r, gg, b, sel[e] and 1 or 0.55, sel[e] and 3 or 2)
            elseif e.t == "i" then
                Emit(R, g.ring, 1, 1, 1, 0.7, 2)
                R.Line(g.x, g.y, g.z + LIFT, g.x, g.y, g.z + g.post, 0.85, 0.85, 0.85, 0.8, 1.5)
            end
        end
    end
    -- the selection box being dragged lies on the floor
    local d = cv.drag
    if d and d.mode == "marquee" and d.ex then
        local r3 = R3()
        local x1, y1 = r3.BoardToRoom(self.room, cv.page, d.sx, d.sy)
        local x2, y2 = r3.BoardToRoom(self.room, cv.page, d.ex, d.ey)
        local L = {}
        self:Rect(L, (x1 + x2) / 2, (y1 + y2) / 2, abs(x2 - x1) / 2, abs(y2 - y1) / 2, LIFT_SEL)
        Emit(R, L, GOLD[1], GOLD[2], GOLD[3], 0.9, 2)
    end
end

---------------------------------------------------------------------------
-- Plates: icons, texts, player markers, labels (over everything, nearest on top)
---------------------------------------------------------------------------

local function fontPath() return MapUI().FontPath() end

function V:Chip(n)
    local c = self.chips[n]
    if c then return c end
    c = CreateFrame("Frame", nil, self.view.plateFrame)
    c:SetSize(1, 1)
    c.edge = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.bg = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.glow = c:CreateTexture(nil, "ARTWORK", nil, 1)
    c.glow:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.6)
    c.icon = c:CreateTexture(nil, "ARTWORK", nil, 2)
    c.fs = c:CreateFontString(nil, "OVERLAY")
    c.fs:SetFont(fontPath(), 12, "OUTLINE")
    c.sub = c:CreateFontString(nil, "OVERLAY")
    c.sub:SetFont(fontPath(), 11, "OUTLINE")
    c.badge = c:CreateTexture(nil, "OVERLAY", nil, 3)
    c.sel = {}
    for i = 1, 4 do c.sel[i] = c:CreateTexture(nil, "OVERLAY", nil, 4) end
    c.lvl = -1
    self.chips[n] = c
    return c
end

local function Reset(c)
    c.edge:Hide()
    c.bg:Hide()
    c.glow:Hide()
    c.icon:Hide()
    c.fs:Hide()
    c.sub:Hide()
    c.badge:Hide()
    for i = 1, 4 do c.sel[i]:Hide() end
end

-- A box round a region (selection: gold, or another member's colour).
local function Box(c, region, color, pad)
    pad = pad or 3
    local S = c.sel
    for i = 1, 4 do
        S[i]:ClearAllPoints()
        S[i]:SetColorTexture(color[1], color[2], color[3], 1)
        S[i]:Show()
    end
    S[1]:SetPoint("BOTTOMLEFT", region, "TOPLEFT", -pad, pad - 1)
    S[1]:SetPoint("BOTTOMRIGHT", region, "TOPRIGHT", pad, pad - 1)
    S[1]:SetHeight(1)
    S[2]:SetPoint("TOPLEFT", region, "BOTTOMLEFT", -pad, -pad + 1)
    S[2]:SetPoint("TOPRIGHT", region, "BOTTOMRIGHT", pad, -pad + 1)
    S[2]:SetHeight(1)
    S[3]:SetPoint("TOPRIGHT", region, "TOPLEFT", -pad + 1, pad)
    S[3]:SetPoint("BOTTOMRIGHT", region, "BOTTOMLEFT", -pad + 1, -pad)
    S[3]:SetWidth(1)
    S[4]:SetPoint("TOPLEFT", region, "TOPRIGHT", pad - 1, pad)
    S[4]:SetPoint("BOTTOMLEFT", region, "BOTTOMRIGHT", pad - 1, -pad)
    S[4]:SetWidth(1)
end

-- A screen point of a room point with the camera just measured (the renderer's own basis), else the scene's.
function V:Proj(x, y, z)
    if self.measured then
        local sx, sy, d = self.R.Project(x, y, z)
        return sx, sy, d
    end
    local sx, sy = self.view:Project(x, y, z)
    if not sx then return nil end
    local cam = self.cam
    return sx, sy, (x - cam.x) * cam.fx + (self.view:SY(y) - cam.y) * cam.fy + (z - cam.z) * cam.fz
end

-- How big a plate is at a depth: a little bigger near, smaller far, never tiny.
local function Size(d) return Clamp(30 / max(1, d), 0.65, 1.25) end

-- The plates of this frame: one request per plate { e, kind, sx, sy, d }, drawn far to near; hit boxes on the way.
function V:DrawPlates(remote)
    local cv = self.canvas
    local page = cv.page
    local reqs, n = self.reqs or {}, 0
    self.reqs = reqs
    local hits, nh = self.hits, 0
    local handles = self.handles
    for i = #handles, 1, -1 do handles[i] = nil end
    local arrows = self.arrowHits
    for i = #arrows, 1, -1 do arrows[i] = nil end
    local function add(e, kind, x, y, z, extra)
        local sx, sy, d = self:Proj(x, y, z)
        if not sx then return end
        n = n + 1
        local r = reqs[n] or {}
        reqs[n] = r
        r.e, r.kind, r.sx, r.sy, r.d, r.extra = e, kind, sx, sy, d, extra
    end
    for _, e in ipairs(page and page.e or {}) do
        local g = self:Geo(e)
        if e.t == "z" then
            if e.l or e.rm or (e.ln and cv.opts.linkText) then add(e, "zone", g.x, g.y, g.z + 0.3) end
        elseif e.t == "a" then
            if e.ln and cv.opts.linkText and not e.g then
                add(e, "arrow", (g.x + g.x2) / 2, (g.y + g.y2) / 2, (g.z + g.z2) / 2 + 0.3)
            end
            -- the screen path, for the mouse
            local L, pts = g.path, {}
            for o = 0, #L - 6, 6 do
                local sx, sy = self:Proj(L[o + 1], L[o + 2], L[o + 3])
                if sx then pts[#pts + 1] = sx pts[#pts + 1] = sy end
                if o == #L - 6 then
                    local qx, qy = self:Proj(L[o + 4], L[o + 5], L[o + 6])
                    if qx then pts[#pts + 1] = qx pts[#pts + 1] = qy end
                end
            end
            local _, _, d = self:Proj(g.x, g.y, g.z)
            arrows[#arrows + 1] = { e = e, pts = pts, d = d or 1e9 }
        elseif e.t == "x" then
            add(e, "text", g.x, g.y, g.z + 0.6)
        elseif e.t == "s" then
            add(e, "slot", g.x, g.y, g.z + g.post)
        elseif g.display then
            add(e, "model", g.x, g.y, g.z + (g.h or 3))
        elseif e.t == "i" then
            add(e, "icon", g.x, g.y, g.z + g.post)
        end
    end
    -- far to near: the nearest plate on top
    for i = n + 1, #reqs do reqs[i] = nil end
    tsort(reqs, function(a, b) return a.d > b.d end)
    local base = self.view.plateFrame:GetFrameLevel()
    local scene = self.view.scene
    local editable = cv:Editable()
    for k = 1, n do
        local r = reqs[k]
        local c = self:Chip(k)
        Reset(c)
        local e = r.e
        local f = Size(r.d)
        local selected = editable and cv.sel[e]
        local rc = remote and remote[e]
        local boxColor = selected and GOLD or rc
        local hot = cv.lit and cv.lit[e]
        c:ClearAllPoints()
        local w, h, ax, ay = 0, 0, 0, 0                   -- the hit box: size and its bottom-left from the anchor
        if r.kind == "icon" then
            local sz = floor(max(12, (e.z or 32) * 0.7 * f))
            c:SetSize(sz, sz)
            c:SetPoint("BOTTOM", scene, "BOTTOMLEFT", r.sx, r.sy)
            c.icon:ClearAllPoints()
            c.icon:SetAllPoints(c)
            MapUI():SetIcon(c.icon, e.i)
            c.icon:Show()
            if hot then
                c.glow:ClearAllPoints()
                c.glow:SetPoint("TOPLEFT", c, "TOPLEFT", -3, 3)
                c.glow:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 3, -3)
                c.glow:Show()
            end
            w, h, ax, ay = sz, sz, -sz / 2, 0
            if e.l then
                local cr, cg, cb = MapUI():Color(e.c or 9)
                c.fs:SetFont(fontPath(), floor(max(8, 11 * f)), "OUTLINE")
                c.fs:ClearAllPoints()
                c.fs:SetPoint("TOP", c, "BOTTOM", 0, -1)
                c.fs:SetWidth(0)
                c.fs:SetText(e.l)
                c.fs:SetTextColor(cr, cg, cb)
                c.fs:Show()
                local lh = c.fs:GetStringHeight() or 12
                h, ay = h + lh + 1, -(lh + 1)
            end
            if boxColor then Box(c, c, boxColor) end
            self:Badge(c, e, c, sz * 0.45)
        elseif r.kind == "text" then
            local cr, cg, cb = MapUI():Color(e.c or 9)
            if hot then cr, cg, cb = GOLD[1], GOLD[2], GOLD[3] end
            local size = floor(max(8, MapUI().TextSize(e) * f))
            c.fs:SetFont(fontPath(), size, "OUTLINE")
            c.fs:ClearAllPoints()
            c.fs:SetPoint("CENTER", scene, "BOTTOMLEFT", r.sx, r.sy)
            c.fs:SetWidth(0)
            c.fs:SetJustifyH(e.j == "l" and "LEFT" or (e.j == "r" and "RIGHT" or "CENTER"))
            c.fs:SetText(e.l or "")
            c.fs:SetTextColor(cr, cg, cb)
            c.fs:Show()
            local sw = c.fs:GetStringWidth() or 40
            local wrap = MapUI().TextBox(e) * 0.7 * f
            if sw > wrap then
                c.fs:SetWidth(wrap)
                sw = wrap
            end
            w, h = sw, c.fs:GetStringHeight() or size
            ax, ay = -w / 2, -h / 2
            c:SetSize(1, 1)
            c:SetPoint("CENTER", scene, "BOTTOMLEFT", r.sx, r.sy)
            if boxColor then Box(c, c.fs, boxColor) end
        elseif r.kind == "slot" then
            local text = cv.opts.slotText and cv.opts.slotText(e.r) or e.r
            c.fs:SetFont(fontPath(), floor(max(8, 11 * f)), "OUTLINE")
            c.fs:ClearAllPoints()
            c.fs:SetWidth(0)
            c.fs:SetText(text)
            c.fs:SetTextColor(1, 1, 1)
            local sw, sh = (c.fs:GetStringWidth() or 40) + 10, floor(max(8, 11 * f)) + 6
            c:SetSize(sw, sh)
            c:SetPoint("BOTTOM", scene, "BOTTOMLEFT", r.sx, r.sy)
            c.fs:SetPoint("CENTER", c, "CENTER", 0, 0)
            c.fs:Show()
            c.bg:ClearAllPoints()
            c.bg:SetAllPoints(c)
            c.bg:SetColorTexture(0, 0, 0, 0.72)
            c.bg:Show()
            c.edge:ClearAllPoints()
            c.edge:SetPoint("TOPLEFT", c, "TOPLEFT", -1, 1)
            c.edge:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 1, -1)
            c.edge:SetColorTexture(hot and 1 or 0.85, hot and 0.85 or 0.7, hot and 0.1 or 0.3, hot and 1 or 0.8)
            c.edge:Show()
            w, h, ax, ay = sw, sh, -sw / 2, 0
            if boxColor then Box(c, c, boxColor, 4) end
        else
            -- a zone's label, a model's name (over its head), an arrow's names: text with a badge and the names of
            -- the players linked to it under it
            local label = e.l
            if r.kind == "model" and not label then label = MapUI():IconName(e.i, cv.opts.bossRef and cv.opts.bossRef()) end
            if r.kind == "arrow" then label = nil end
            c:SetSize(1, 1)
            c:SetPoint("BOTTOM", scene, "BOTTOMLEFT", r.sx, r.sy)
            local top = c
            if label and label ~= "" then
                c.fs:SetFont(fontPath(), floor(max(8, (r.kind == "model" and 12 or 13) * f)), "OUTLINE")
                c.fs:ClearAllPoints()
                c.fs:SetPoint("BOTTOM", c, "BOTTOM", 0, 0)
                c.fs:SetWidth(0)
                c.fs:SetText(label)
                if r.kind == "model" then c.fs:SetTextColor(1, 0.82, 0) else c.fs:SetTextColor(1, 1, 1) end
                c.fs:Show()
                top = c.fs
                w, h = c.fs:GetStringWidth() or 40, c.fs:GetStringHeight() or 12
                ax, ay = -w / 2, 0
            end
            if boxColor and r.kind == "model" and top ~= c then Box(c, top, boxColor) end
            self:Badge(c, e, top, top == c and 0 or (h / 2 + 2), top == c)
        end
        -- the names of the players a linked drawing stands for (under it)
        local link = cv.opts.linkText and e.ln and e.t ~= "s" and cv.opts.linkText(e.ln)
        if link and link ~= "" then
            c.sub:SetFont(fontPath(), floor(max(8, 11 * f)), "OUTLINE")
            c.sub:ClearAllPoints()
            c.sub:SetPoint("TOP", c, "BOTTOM", 0, (r.kind == "icon" and e.l) and -((c.fs:GetStringHeight() or 12) + 2) or -1)
            c.sub:SetWidth(0)
            c.sub:SetText(link)
            c.sub:Show()
        end
        local lvl = base + min(CHIP_LEVELS, k)
        if c.lvl ~= lvl then
            c:SetFrameLevel(lvl)
            c.lvl = lvl
        end
        c:Show()
        if w > 0 then
            nh = nh + 1
            local hb = hits[nh] or {}
            hits[nh] = hb
            hb.e, hb.l, hb.b, hb.r, hb.t, hb.d = e, r.sx + ax, r.sy + ay, r.sx + ax + w, r.sy + ay + h, r.d
        end
    end
    for k = n + 1, #self.chips do self.chips[k]:Hide() end
    -- a model's body is under the mouse too (feet to its name)
    for _, e in ipairs(page and page.e or {}) do
        local g = e.t == "i" and self.geo[e]
        if g and g.display and self.actors[e] then
            local fx, fy, d = self:Proj(g.x, g.y, g.z)
            local hx, hy = self:Proj(g.x, g.y, g.z + (g.h or 3))
            if fx and hx then
                local half = max(10, abs(hy - fy) * 0.3)
                nh = nh + 1
                local hb = hits[nh] or {}
                hits[nh] = hb
                hb.e, hb.l, hb.b, hb.r, hb.t, hb.d = e, min(fx, hx) - half, min(fy, hy), max(fx, hx) + half, max(fy, hy), d
            end
        end
    end
    for i = nh + 1, #hits do hits[i] = nil end
    self.nHits = nh
    -- the corner handles of the one selected drawing (a zone's size, an arrow's ends)
    local e = editable and cv.selected
    if e and cv:SelectionCount() == 1 and (e.t == "z" or e.t == "a") then
        local g = self:Geo(e)
        local function handle(name, p)
            local sx, sy = self:Proj(p[1], p[2], p[3])
            if sx then handles[#handles + 1] = { name = name, x = sx, y = sy } end
        end
        if e.t == "z" then handle("size", g.handle)
        else
            handle("end1", g.handle)
            handle("end2", g.handle2)
        end
    end
    self:DrawHandles()
end

-- A raid mark badge on a plate (e.rm): at the top right of `region`, or over it (above = true).
function V:Badge(c, e, region, dx, above)
    if not e.rm then return end
    c.badge:ClearAllPoints()
    c.badge:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. e.rm)
    c.badge:SetSize(16, 16)
    if above then
        c.badge:SetPoint("BOTTOM", region, "TOP", 0, 2)
    else
        c.badge:SetPoint("LEFT", region, "TOPRIGHT", 1, 0)
    end
    c.badge:Show()
end

function V:DrawHandles()
    self.handleTex = self.handleTex or {}
    local T = self.handleTex
    for i, hd in ipairs(self.handles) do
        local t = T[i]
        if not t then
            t = self.hud:CreateTexture(nil, "OVERLAY", nil, 7)
            t:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
            t:SetSize(8, 8)
            T[i] = t
        end
        t:ClearAllPoints()
        t:SetPoint("CENTER", self.view.scene, "BOTTOMLEFT", hd.x, hd.y)
        t:Show()
    end
    for i = #self.handles + 1, #T do T[i]:Hide() end
end

---------------------------------------------------------------------------
-- What is under the mouse
---------------------------------------------------------------------------

local function SegDist(px, py, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / len2)) or 0
    return sqrt((px - x1 - t * dx) ^ 2 + (py - y1 - t * dy) ^ 2)
end

-- The drawing under the mouse: the nearest plate or model under it, else an arrow within 6 px, else the topmost zone
-- whose floor is under it. Drawn things only (what the last frame showed).
function V:HitTest()
    if not (self.on and self.canvas.page) then return nil end
    local cx, cy = self.view:Cursor()
    local best, bestD
    for i = 1, self.nHits or 0 do
        local hb = self.hits[i]
        if cx >= hb.l - 3 and cx <= hb.r + 3 and cy >= hb.b - 3 and cy <= hb.t + 3 and (not bestD or hb.d < bestD) then
            best, bestD = hb.e, hb.d
        end
    end
    if best then return best end
    for _, a in ipairs(self.arrowHits) do
        local p = a.pts
        for o = 1, #p - 3, 2 do
            if SegDist(cx, cy, p[o], p[o + 1], p[o + 2], p[o + 3]) <= 6 and (not bestD or a.d < bestD) then
                best, bestD = a.e, a.d
            end
        end
    end
    if best then return best end
    local bx, by = self:CursorBoard()
    if not bx then return nil end
    local list = self.canvas.page.e
    for i = #list, 1, -1 do
        local e = list[i]
        if e.t == "z" and MapUI().Hits(e, bx, by, 0) then return e end
    end
    return nil
end

-- The handle of the selected drawing under the mouse, or nil.
function V:HandleAt()
    local cx, cy = self.view:Cursor()
    for _, hd in ipairs(self.handles) do
        if abs(cx - hd.x) <= 9 and abs(cy - hd.y) <= 9 then return hd.name end
    end
    return nil
end

---------------------------------------------------------------------------
-- The camera buttons, the compass, the small map, the hint
---------------------------------------------------------------------------

-- The editor icons (UI.ICON_ATLAS): 27 turn left, 28 turn right, 29 from above, 30 the whole room, 31 the small map,
-- 15 the eye.
local HUD_ICONS = { rotL = 27, rotR = 28, top = 29, home = 30, map = 31, eye = 15 }
local INSET_W = 200
local EYE_HINT = "Standing here at eye height: right-drag looks around, the wheel steps back out."

function V:CreateHud()
    local hud = CreateFrame("Frame", nil, self.frame)
    hud:SetAllPoints()
    hud:SetFrameLevel(self.frame:GetFrameLevel() + LV.hud)
    self.hud = hud
    local btns = {}
    local function button(key, title, text, onClick)
        local b = UI():CreateTipIconButton(hud, 22, HUD_ICONS[key], title, text, onClick)
        btns[#btns + 1] = b
        b.key = key
        return b
    end
    self.mapBtn = button("map", "Small map", "Shows or hides the 2D map in the corner: where the camera is and what it "
        .. "sees. Click it to look there.", function() self:ToggleInset() end)
    self.eyeBtn = button("eye", "My spot", "Stand where you are on this page, at eye height, looking at the boss. "
        .. "Click again for your next spot; wheel out to step back.", function() self:ViewMySpot() end)
    button("home", "Whole room", "Back to the view of the whole room (Home).", function() self:Reset() end)
    self.topBtn = button("top", "From above", "Look straight down, north up, like the 2D map; click again to tilt back.",
        function() self:ToggleTop() end)
    button("rotR", "Turn right", "Turn the view 45 degrees (E).", function() self:Rotate(-1) end)
    button("rotL", "Turn left", "Turn the view 45 degrees (Q).", function() self:Rotate(1) end)
    local prev
    for _, b in ipairs(btns) do
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -2, 0) else b:SetPoint("TOPRIGHT", -6, -6) end
        prev = b
    end
    self.hudBtns = btns
    -- the compass: an arrow pointing north as the camera sees it
    local comp = CreateFrame("Frame", nil, hud)
    comp:SetSize(30, 30)
    comp:SetPoint("TOPLEFT", 8, -8)
    comp.bg = comp:CreateTexture(nil, "BACKGROUND")
    comp.bg:SetAllPoints()
    comp.bg:SetTexture(MapUI().TEX.disc)
    comp.bg:SetVertexColor(0, 0, 0, 0.55)
    comp.arrow = comp:CreateTexture(nil, "ARTWORK")
    comp.arrow:SetSize(16, 16)
    comp.arrow:SetPoint("CENTER")
    comp.arrow:SetTexture(MapUI().TEX.arrow)
    comp.arrow:SetVertexColor(1, 0.3, 0.25, 1)
    comp.n = comp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    comp.n:SetText("N")
    self.compass = comp
    -- the hint (what the mouse does), on a dark strip
    self.hintBg = hud:CreateTexture(nil, "BACKGROUND")
    self.hintBg:SetColorTexture(0, 0, 0, 0.5)
    self.hint = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.hint:SetPoint("BOTTOMLEFT", 6, 5)
    self.hint:SetPoint("RIGHT", hud, "RIGHT", -84, 0)          -- (the board's 2D / 3D switch is in that corner)
    self.hint:SetJustifyH("LEFT")
    self.hintBg:SetPoint("TOPLEFT", self.hint, "TOPLEFT", -4, 3)
    self.hintBg:SetPoint("BOTTOMRIGHT", self.hint, "BOTTOMRIGHT", 4, -3)
    -- the small map: a read-only copy of the 2D canvas (the same page), with the camera on it
    local inset = MapUI():CreateCanvas(hud, INSET_W, {
        editable = function() return false end,
        slotText = function(ref) return self.canvas.opts.slotText and self.canvas.opts.slotText(ref) or ref end,
        linkText = function(ref) return self.canvas.opts.linkText and self.canvas.opts.linkText(ref) or nil end,
        slotTip = self.canvas.opts.slotTip,
        bossRef = self.canvas.opts.bossRef,
    })
    inset.frame:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -6, -34)
    inset.hint:Hide()
    UI():AddEdges(inset.frame)
    UI():SetEdgeColor(inset.frame, 0.5, 0.5, 0.55, 0.9)
    inset.frame:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            self.insetDrag = true
            self:LookAtInset(true)
        end
    end)
    inset.frame:SetScript("OnMouseUp", function() self.insetDrag = false end)
    inset.frame:SetScript("OnMouseWheel", function(_, delta) self:Wheel(delta) end)
    self.inset = inset
    local mark = CreateFrame("Frame", nil, inset.frame)
    mark:SetAllPoints()
    mark:SetFrameLevel(inset.top:GetFrameLevel() + 5)
    mark.arrow = mark:CreateTexture(nil, "OVERLAY", nil, 2)
    mark.arrow:SetTexture(MapUI().TEX.arrow)
    mark.arrow:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
    mark.arrow:SetSize(14, 14)
    mark.lines = {}
    for i = 1, 4 do
        local l = mark:CreateLine(nil, "OVERLAY", nil, 1)
        l:SetColorTexture(1, 1, 1, 0.8)
        l:SetThickness(1)
        mark.lines[i] = l
    end
    self.mark = mark
    self.insetOn = true
end

-- The hint the canvas gives for its tool (DrawHud shows another one while the camera stands on a spot).
function V:SetHint(text)
    self.baseHint = text
    self:ShowHint(self.orb.dist < 3 and EYE_HINT or text)
end

function V:ShowHint(text)
    if self.hintShown == text then return end
    self.hintShown = text
    self.hint:SetText(text or "")
    self.hintBg:SetShown(text ~= nil and text ~= "")
end

function V:ToggleInset()
    self.insetOn = not self.insetOn
    self.inset.frame:SetShown(self.insetOn)
    self.mapBtn:SetActive(self.insetOn)
    self:Invalidate()
end

-- A click on the small map: look at that spot (drag: follow the mouse without easing).
function V:LookAtInset(ease)
    local bx, by = self.inset:Cursor()
    local x, y = R3().BoardToRoom(self.room, self.canvas.page, bx, by)
    if ease then
        self:LookAt(x, y)
    else
        self.anim = nil
        self.orb.x, self.orb.y = x, y
        self:ClampOrb(self.orb)
        self:Invalidate()
    end
end

-- The camera on the small map: an arrow where it looks (pointing the way it faces) and what it sees of the floor.
function V:DrawInset()
    if not self.insetOn then return end
    local inset, cv, r3 = self.inset, self.canvas, R3()
    if inset.page ~= cv.page or self.insetStale then
        self.insetStale = false
        inset:SetPage(cv.page)
    end
    local o = self.orb
    local function at(x, y)
        local bx, by = r3.RoomToBoard(self.room, cv.page, x, y)
        return bx * inset.s, -by * inset.s
    end
    local mx, my = at(o.x, o.y)
    local mark = self.mark
    mark.arrow:ClearAllPoints()
    mark.arrow:SetPoint("CENTER", inset.layer, "TOPLEFT", mx, my)
    mark.arrow:SetRotation(o.heading - pi / 2)
    -- the floor the view sees: the screen's corners on the floor's height under the point looked at
    local w, h = self.view.scene:GetWidth() or 0, self.view.scene:GetHeight() or 0
    local z = self:Ground(o.x, o.y)
    local P = {}
    local far = self:Limits()
    for i, c in ipairs({ { 0, 0 }, { w, 0 }, { w, h }, { 0, h } }) do
        local x, y = self:FloorAt(c[1], c[2], z)
        if not x then
            -- over the horizon: as far as the camera may stand, straight ahead of that corner
            local ex, ey, _, dx, dy = self.R.ScreenRay(c[1], c[2])
            if ex then
                local l = sqrt(dx * dx + dy * dy)
                if l > 1e-6 then x, y = ex + dx / l * far, ey + dy / l * far end
            end
        end
        if x then P[i] = { at(x, y) } end
    end
    for i = 1, 4 do
        local a, b = P[i], P[i % 4 + 1]
        local l = mark.lines[i]
        if a and b then
            l:SetStartPoint("TOPLEFT", inset.layer, a[1], a[2])
            l:SetEndPoint("TOPLEFT", inset.layer, b[1], b[2])
            l:Show()
        else
            l:Hide()
        end
    end
end

-- The compass and the buttons that depend on the page.
function V:DrawHud()
    local o = self.orb
    local z = self:Ground(o.x, o.y)
    local ax, ay = self:Proj(o.x, o.y, z)
    local bx, by = self:Proj(o.x, o.y + 5, z)
    local comp = self.compass
    if ax and bx and (abs(bx - ax) + abs(by - ay)) > 0.5 then
        local a = atan2(by - ay, bx - ax)
        comp.arrow:SetRotation(a - pi / 2)
        comp.n:ClearAllPoints()
        comp.n:SetPoint("CENTER", comp, "CENTER", cos(a) * 21, sin(a) * 21)
        comp:Show()
    else
        comp:Hide()
    end
    self:ShowHint(o.dist < 3 and EYE_HINT or self.baseHint)
    self.eyeBtn:SetShown(#self:MySpots() > 0)
    self.topBtn:SetActive(o.pitch >= PITCH_TOP - 0.05)
    self.mapBtn:SetActive(self.insetOn)
    -- the buttons close up when one is hidden
    local prev
    for _, b in ipairs(self.hudBtns) do
        if b:IsShown() then
            b:ClearAllPoints()
            if prev then b:SetPoint("RIGHT", prev, "LEFT", -2, 0) else b:SetPoint("TOPRIGHT", -6, -6) end
            prev = b
        end
    end
    self:DrawInset()
end

---------------------------------------------------------------------------
-- A frame
---------------------------------------------------------------------------

function V:Draw()
    self.dirty = false
    local cv, R = self.canvas, self.R
    if not (cv.page and self.room) then return end
    local fl = R3().Floor(self.room)
    local ok = fl and R.SetMesh(fl.mesh)
    if not self.calibrated then
        local o = self.orb
        local z = self:Ground(o.x, o.y) + Lift(o.dist)
        self.calibrated = self.view:Calibrate(function() self:Place() end, o.x, o.y, z,
            o.x - sin(o.heading) * 2, o.y + cos(o.heading) * 2, z)
    end
    self:Place()
    local occ, n = self:DrawModels()
    local remote = self:RemoteMarks()
    self.measured = ok and R.BeginFrame(self.cam) or false
    if self.measured then
        R.SetOccluders(occ, n)
        R.DrawRoom()
        R.BeginLines()
        self:DrawLines(remote)
        R.EndLines()
        R.DrawCopies()
    end
    self:DrawPlates(remote)
    self:DrawHud()
end

local function Smooth(t) return t * t * (3 - 2 * t) end

function V:OnUpdate(elapsed)
    if not self.on then return end
    local moved = false
    local a = self.anim
    if a then
        local t = (GetTime() - a.t0) / max(0.01, a.dur)
        local o, f, to = self.orb, a.from, a.to
        if t >= 1 then
            o.x, o.y, o.heading, o.pitch, o.dist = to.x, to.y, to.heading, to.pitch, to.dist
            self.anim = nil
        else
            local k = Smooth(t)
            o.x, o.y = f.x + (to.x - f.x) * k, f.y + (to.y - f.y) * k
            o.heading = f.heading + (to.heading - f.heading) * k
            o.pitch = f.pitch + (to.pitch - f.pitch) * k
            -- the distance eases in its logarithm, so a long zoom does not rush its near end
            o.dist = math.exp(math.log(f.dist) + (math.log(to.dist) - math.log(f.dist)) * k)
        end
        moved = true
        if not self.anim and a.after then a.after() end
        if not self.on then return end
    end
    local d = self.drag3
    if d then
        if not IsMouseButtonDown(d.button) then
            self.drag3 = nil
        else
            local cx, cy = GetCursorPosition()
            local dx, dy = cx - d.cx, cy - d.cy
            if abs(dx) + abs(dy) > 4 then d.moved = true end
            if d.kind == "orbit" and d.moved then
                local o = self.orb
                o.heading = d.heading - dx * 0.008
                o.pitch = d.pitch - dy * 0.006
                self.anim = nil
                self:ClampOrb(o)
                moved = true
            elseif d.kind == "pan" and d.moved then
                -- the floor point under the mouse at the start stays under it
                local sx, sy = self.view:Cursor()
                local x, y = self:FloorAt(sx, sy, d.z)
                if x then
                    local o = self.orb
                    o.x, o.y = o.x + (d.x - x), o.y + (d.y - y)
                    self.anim = nil
                    self:ClampOrb(o)
                    moved = true
                end
            end
        end
    end
    if self.insetDrag then
        if IsMouseButtonDown("LeftButton") then self:LookAtInset(false) else self.insetDrag = false end
    end
    -- models still loading: look again now and then (their height, for the labels and the copies)
    local loading = false
    for _, act in pairs(self.actors) do
        if act.loadAt and GetTime() - act.loadAt < 3 then loading = true end
    end
    self.acc = (self.acc or 0) + (elapsed or 0)
    if loading and self.acc > 0.4 then
        self.acc = 0
        self.dirty = true
    end
    if moved or self.dirty then self:Draw() end
end

---------------------------------------------------------------------------
-- Mouse (the canvas hands its events here first)
---------------------------------------------------------------------------

-- A button pressed on the canvas. -> true when the camera took it: the right button (turn / tilt; a click without a
-- drag opens the canvas' menu on release), the middle button (move), the left button with the Pan tool or while the
-- page is only read (move; a double-click on the floor looks there), and a double-click on empty floor while editing.
function V:MouseDown(button, editable, tool)
    local cx, cy = GetCursorPosition()
    local o = self.orb
    if button == "RightButton" then
        self.drag3 = { kind = "orbit", button = button, cx = cx, cy = cy, heading = o.heading, pitch = o.pitch }
        return true
    end
    local now = GetTime()
    local double = self.lastDown and now - self.lastDown.at < 0.35 and abs(cx - self.lastDown.x) + abs(cy - self.lastDown.y) < 8
    self.lastDown = { at = now, x = cx, y = cy }
    if button == "LeftButton" and double and (not editable or tool == "pan" or (tool == "select" and not self:HitTest())) then
        local sx, sy = self.view:Cursor()
        local x, y = self:FloorAt(sx, sy)
        if x then self:LookAt(x, y, true) end
        self.lastDown = nil
        return true
    end
    if button == "MiddleButton" or (button == "LeftButton" and (tool == "pan" or not editable)) then
        local sx, sy = self.view:Cursor()
        local z = self:Ground(o.x, o.y)
        local x, y = self:FloorAt(sx, sy, z)
        self.drag3 = { kind = "pan", button = button, cx = cx, cy = cy, x = x or o.x, y = y or o.y, z = z }
        if not x then self.drag3 = nil end
        return true
    end
    return false
end

-- A button released. -> "click" for a right click without a drag (the canvas opens its menu), true when the camera
-- had the button, else nil.
function V:MouseUp(button)
    local d = self.drag3
    if d and d.button == button then
        self.drag3 = nil
        if d.kind == "orbit" and not d.moved then return "click" end
        return true
    end
    return nil
end

function V:Wheel(delta)
    local o = Copy(self.anim and self.anim.to or self.orb)
    o.dist = o.dist * (delta > 0 and 0.82 or 1 / 0.82)
    if o.dist < DIST_MIN * 1.5 then o.dist = DIST_MIN end
    self.anim = nil
    self.orb.dist = o.dist
    self:ClampOrb(self.orb)
    self:Invalidate()
end

-- Keys while editing in 3D: Q / E turn, Home shows the whole room. -> true when used.
function V:OnKey(key)
    if key == "Q" then self:Rotate(1) return true end
    if key == "E" then self:Rotate(-1) return true end
    if key == "HOME" then self:Reset() return true end
    return false
end

-- Tests: the view's state.
function V:_State()
    local R = self.R
    local nModels = 0
    for _ in pairs(self.actors) do nModels = nModels + 1 end
    local shown = 0
    for _, c in ipairs(self.chips) do if c:IsShown() then shown = shown + 1 end end
    return { on = self.on or false, room = self.room and self.room.key or false, orb = Copy(self.orb),
             animating = self.anim ~= nil, plates = shown, models = nModels, hits = self.nHits or 0,
             handles = #self.handles, textures = R and R.ShownTextures() or 0, lines = R and R.ShownLines() or 0,
             measured = self.measured or false, inset = self.insetOn or false, hint = self.hint:GetText() or "",
             mySpots = #self:MySpots(), compass = self.compass:IsShown() }
end
