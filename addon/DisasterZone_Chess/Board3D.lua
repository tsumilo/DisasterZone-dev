if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Chess/Board3D.lua", ...) then return end -- DisasterZone_Chess/Board3D.lua
-- ns.ChessBoard3D: Karazhan Chess in the Gamesman's Hall itself. The room is Blizzard's mesh drawn by the shared
-- renderer (Render3D/, the strategy board's "Karazhan:Chess" room, generated to hold the whole board); the pieces
-- are the event's own creatures on the event's own squares, at their own sizes, and the Echo of Medivh watches from
-- where he stands in the event (see-through, as the client draws him).
--
-- The squares: boss_chess_event.cpp SetupBoard puts cell (column c, row r) at world x = -11108.1 + 3.49c + 4.4r,
-- y = -1872.91 - 4.4c + 3.45r (rows 0-1 the Alliance's, column 0 = file a). The room's box (gen_rooms.py BOX) is
-- world x -11114.98 .. , y .. -1841.74, so in room yards (x east = -world y, y north = world x) a square's middle is
-- O + file * COL + rank * ROW below.
--
-- The camera orbits the board's middle: right-drag turns and tilts it, the wheel zooms; it starts behind your
-- pieces. A left click picks the square under the mouse (the 64 squares' corners projected each redraw).
local _, ns = ...

local B3 = {}
ns.ChessBoard3D = B3

local R = ns.ChessRules
local floor, abs, min, max, sqrt = math.floor, math.abs, math.min, math.max, math.sqrt
local pi = math.pi
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local ROOM_REF = "Karazhan:Chess"
local O = { x = 31.170034, y = 6.880391 }     -- a1's middle, room yards
local COL = { x = 4.4, y = 3.49 }             -- one file to the right (white's view)
local ROW = { x = -3.45, y = 4.4 }            -- one rank forward (white's view)
B3.O, B3.COL, B3.ROW = O, COL, ROW
local FWD_W = atan2(ROW.y, ROW.x)             -- the way the Alliance faces (room heading)
local MID = { x = O.x + 3.5 * (COL.x + ROW.x), y = O.y + 3.5 * (COL.y + ROW.y) }
B3.MID = MID

-- Frame levels above the view frame's own (Render3D/View.lua's LV, with room for the pieces' copies)
local LV = { standin = 1, floor = 2, lines = 3, room0 = 4, scene = 330, copy0 = 331, plates = 373, hud = 380 }

-- The event's pieces (Karazhan:Chess research, AzerothCore creature_template / CreatureDisplayInfo build 2.5.6.69795:
-- display, CreatureModelScale; npc for reference): [side][piece] = { display, scale, name, melee }
B3.PIECES = {
    [1] = {
        { display = 16276, scale = 1.5, name = "Human Footman", npc = 17211, melee = true },
        { display = 19783, scale = 1.75, name = "Human Charger", npc = 21664, melee = true },
        { display = 16278, scale = 2, name = "Human Cleric", npc = 21682 },
        { display = 5564, scale = 2, name = "Conjured Water Elemental", npc = 21160, melee = true },
        { display = 16280, scale = 2.5, name = "Human Conjurer", npc = 21683 },
        { display = 16293, scale = 3, name = "King Llane", npc = 21684, melee = true },
    },
    [-1] = {
        { display = 16264, scale = 1.5, name = "Orc Grunt", npc = 17469, melee = true },
        { display = 2352, scale = 2, name = "Orc Wolf", npc = 21748, melee = true },
        { display = 16267, scale = 2, name = "Orc Necrolyte", npc = 21747 },
        { display = 16269, scale = 2, name = "Summoned Daemon", npc = 21726, melee = true },
        { display = 16263, scale = 2.5, name = "Orc Warlock", npc = 21750 },
        { display = 16270, scale = 3, name = "Warchief Blackhand", npc = 21752, melee = true },
    },
}
-- The Echo of Medivh (npc 16816): display 18720, scale 1.3, alpha 130 / 255; his spot (AzerothCore spawn).
B3.MEDIVH = { display = 18720, scale = 1.3, alpha = 130 / 255, x = 11.82, y = 16.18 }

-- Animations (Render3D/View.lua R3.ANIM): stand, death, walk, run, dead, attack (unarmed), cast (spell cast omni)
local A = ns.Render3D and ns.Render3D.ANIM or {}
B3.ANIM = A
local WALK, RUN = 3.2, 7                    -- yd/s: a piece walking one square, running further (and a knight)
local MOVE_MAX = 2.2                        -- s: no move's walk or run takes longer (they speed up)
local FADE = 0.9                            -- s: a fallen piece fading away

-- Square marks: colours and how far over the floor they lie
local LIFT = 0.06
local C_SEL = { 1, 0.82, 0.25 }
local C_MOVE = { 0.55, 0.85, 1 }
local C_CAP = { 1, 0.35, 0.3 }
local C_LAST = { 0.75, 0.6, 1 }
local C_HOVER = { 1, 1, 1 }
local C_CHECK = { 1, 0.15, 0.1 }
local C_FIRE = { 1, 0.5, 0.1 }

local View = {}
View.__index = View

local function R3() return ns.Render3D end

-- The middle of a square (mailbox index) in room yards.
function B3.SquareXY(sq)
    local f, r = R.File(sq), R.Rank(sq)
    return O.x + f * COL.x + r * ROW.x, O.y + f * COL.y + r * ROW.y
end

-- A square's four corners (room x, y), in turn round it.
local function Corners(sq, inset)
    local f, r = R.File(sq), R.Rank(sq)
    local k = 0.5 - (inset or 0)
    local cx, cy = B3.SquareXY(sq)
    local out = {}
    for i, s in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
        out[i] = { cx + (s[1] * COL.x + s[2] * ROW.x) * k, cy + (s[1] * COL.y + s[2] * ROW.y) * k }
    end
    return out
end
B3.Corners = Corners

-- Can the client draw the hall? -> true, or false and why ("restart": the 3D files are not loaded yet)
function B3.Available()
    local r3 = R3()
    if not (r3 and r3.NewView and r3.NewRoom and r3.RoomForBoss and r3.Floor) then return false, "restart" end
    local room = r3.RoomForBoss(ROOM_REF)
    if not room or not r3.HasFloor(room) then return false, "restart" end
    return true
end

-- A 3D board in `parent` (filling it), or nil when the client cannot draw it.
-- opts: onSquare(sq, button) (a click on a square), onHover(sq)
function B3.New(parent, opts)
    if not B3.Available() then return nil end
    local r3 = R3()
    local self = setmetatable({ opts = opts or {}, cam = {}, actors = {}, pool = {}, fx = {}, fxPool = {},
                                labels = {}, marks = {}, occ = {}, proj = {}, anims = {},
                                orb = { heading = FWD_W, pitch = 0.78, dist = 52 } }, View)
    self.drawMarks = function() self:DrawMarks() end
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()
    f:SetClipsChildren(true)
    self.frame = f
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetColorTexture(0.03, 0.03, 0.05, 1)
    self.view = r3.NewView(f, { cam = self.cam, label = "Karazhan Chess", lv = LV, near = 0.5, fov = 1.0, far = 600 })
    if not self.view then
        f:Hide()
        return nil
    end
    self.R = self.view.room
    self.pool[1] = self.view.probe
    -- the camera orbits the board's middle a yard over the floor (decision D6: this hall's own feel, a wheel notch
    -- 0.88 and a linear zoom ease)
    self.orbit = r3.NewOrbitController(self.view, { orb = self.orb, zoom = 0.88, ease = "linear",
        clamp = function(o) self:ClampOrb(o) end, centre = function() return MID.x, MID.y, self.midZ + 1 end })
    self.room = r3.RoomForBoss(ROOM_REF)
    local fl = r3.Floor(self.room)
    if not (fl and fl.mesh and self.R) then
        f:Hide()
        return nil
    end
    self.H = r3.Height(self.room)
    self.R.SetMesh(fl.mesh)
    -- the squares' heights (the floor under each middle), once
    self.z = {}
    for i = 1, 64 do
        local sq = R.SQ[i]
        local x, y = B3.SquareXY(sq)
        self.z[sq] = self:Ground(x, y)
    end
    self.midZ = self:Ground(MID.x, MID.y)
    -- file and rank letters round the board
    for i = 1, 16 do
        local t = self.view.plateFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetTextColor(0.85, 0.78, 0.6, 0.85)
        self.labels[i] = t
    end
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseDown", function(_, button) self:MouseDown(button) end)
    f:SetScript("OnMouseUp", function(_, button) self:MouseUp(button) end)
    f:SetScript("OnMouseWheel", function(_, d) self:Wheel(d) end)
    f:SetScript("OnUpdate", function(_, elapsed) self:OnUpdate(elapsed) end)
    f:SetScript("OnShow", function() self.dirty = true end)
    self:Medivh()
    self.dirty = true
    return self
end

function View:Ground(x, y)
    local g = self.H and self.H(x, y) or 0
    return self.R and self.R.FloorZ and self.R.FloorZ(x, y, g) or g
end

function View:Show() self.frame:Show() self.dirty = true end
function View:Hide() self.frame:Hide() end
function View:IsShown() return self.frame:IsShown() end

---------------------------------------------------------------------------
-- Camera
---------------------------------------------------------------------------

-- Faces the camera from `side`'s end of the board (eased when animate).
function View:FaceSide(side, animate)
    local heading = side == -1 and (FWD_W + pi) or FWD_W
    local to = { heading = heading, pitch = 0.78, dist = 52 }
    if animate then
        self.orbit:MoveTo(to, 0.6)
    else
        self.orb.heading, self.orb.pitch, self.orb.dist = to.heading, to.pitch, to.dist
    end
    self.side = side
    self.dirty = true
end

-- Turns the camera half way round the board (the other side's view).
function View:Flip()
    local o = self.orbit:Goal()
    self.orbit:MoveTo({ heading = o.heading + pi, pitch = o.pitch, dist = o.dist }, 0.7, nil, true)
    self.dirty = true
end

function View:Place()
    self.orbit:Place()
end

local function Clamp(v, lo, hi) return max(lo, min(hi, v)) end

function View:ClampOrb(o)
    o = o or self.orb
    o.pitch = Clamp(o.pitch, 0.25, 1.45)
    o.dist = Clamp(o.dist, 18, 80)
end

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------

local function PieceDef(v)
    local side = v > 0 and 1 or -1
    return B3.PIECES[side][abs(v)], side
end

function View:NewActor()
    local a = table.remove(self.pool) or self.view:NewActor()
    return a
end

function View:FreeActor(a)
    pcall(a.SetShown, a, false)
    pcall(a.SetAlpha, a, 1)
    a.piece, a.anim = nil, nil
    self.pool[#self.pool + 1] = a
end

-- Plays animation id on an actor (once a model is loaded the view's callback plays a.anim again).
local function Anim(a, id)
    a.anim = id
    pcall(a.SetAnimation, a, id)
end

-- An actor showing piece v (display, size; facing its side's forward).
function View:Dress(a, v)
    local def, side = PieceDef(v)
    if a.display ~= def.display then
        a.display, a.loadedOnce, a.bb = def.display, nil, nil
        pcall(a.ClearModel, a)
        pcall(a.SetModelByCreatureDisplayID, a, def.display)
        pcall(a.SetUseCenterForOrigin, a, false, false, false)
    end
    a.scale = def.scale
    pcall(a.SetScale, a, def.scale)
    a.piece, a.side = v, side
    a.face = side == 1 and FWD_W or FWD_W + pi
    Anim(a, A.stand)
    pcall(a.SetAlpha, a, 1)
    pcall(a.SetShown, a, true)
end

-- Puts an actor at room x, y on the floor, facing heading.
function View:Put(a, x, y, heading)
    local s = a.scale or 1
    local z = self:Ground(x, y)
    a.x, a.y, a.z = x, y, z
    pcall(a.SetPosition, a, x / s, self.view:SY(y) / s, z / s)
    pcall(a.SetYaw, a, self.cam.mirror * heading)
end

-- The Echo of Medivh at his spot, facing the board's middle, see-through.
function View:Medivh()
    local m = B3.MEDIVH
    local a = self:NewActor()
    if not a then return end
    self.medivh = a
    a.display = m.display
    pcall(a.SetModelByCreatureDisplayID, a, m.display)
    pcall(a.SetUseCenterForOrigin, a, false, false, false)
    a.scale = m.scale
    pcall(a.SetScale, a, m.scale)
    pcall(a.SetAlpha, a, m.alpha)
    Anim(a, A.stand)
    self:Put(a, m.x, m.y, atan2(MID.y - m.y, MID.x - m.x))
    pcall(a.SetShown, a, true)
end

-- Medivh casts (a cheat): his cast animation for a moment.
function View:MedivhCast()
    local a = self.medivh
    if not a then return end
    Anim(a, A.cast)
    self.medivhUntil = GetTime() + 1.6
end

-- Sets the board to pos at once (no animation): a piece on each occupied square, its actor kept when the same piece
-- stays on its square. Also the fire and the empowered pieces' auras.
function View:SetPosition(pos)
    self.anims = {}
    local keep = {}
    for sq, a in pairs(self.actors) do
        if pos.b[sq] == a.piece and pos.b[sq] ~= 0 then
            keep[sq] = a
        else
            self:FreeActor(a)
        end
    end
    self.actors = keep
    for i = 1, 64 do
        local sq = R.SQ[i]
        local v = pos.b[sq]
        if v ~= 0 and not self.actors[sq] then
            local a = self:NewActor()
            if a then
                self:Dress(a, v)
                self.actors[sq] = a
            end
        end
        local a = self.actors[sq]
        if a then
            local x, y = B3.SquareXY(sq)
            pcall(a.SetAlpha, a, 1)
            Anim(a, A.stand)
            self:Put(a, x, y, a.face)
        end
    end
    self.pos = pos
    self:SetAuras(pos)
    self.dirty = true
end

---------------------------------------------------------------------------
-- Effects (Medivh's cheats: Games/Chess/Cheats.lua C.FX)
---------------------------------------------------------------------------

-- An effect model at a room point (size: the model's scale). key: one effect per key; nil frees it.
function View:Fx(key, fdid, x, y, scale, z)
    local a = self.fx[key]
    if not fdid then
        if a then
            pcall(a.SetShown, a, false)
            self.fx[key] = nil
            self.fxPool[#self.fxPool + 1] = a
        end
        return
    end
    if not a then
        a = table.remove(self.fxPool) or self.view:NewActor()
        if not a then return end
        self.fx[key] = a
    end
    if a.fdid ~= fdid then
        a.fdid = fdid
        pcall(a.ClearModel, a)
        pcall(a.SetModelByFileID, a, fdid)         -- (effect models named by the spell's own visual kits)
        pcall(a.SetUseCenterForOrigin, a, false, false, false)
        a.anim = 0
        pcall(a.SetAnimation, a, 0)
    end
    a.scale = scale or 1
    pcall(a.SetScale, a, a.scale)
    local zz = z or self:Ground(x, y)
    pcall(a.SetPosition, a, x / a.scale, self.view:SY(y) / a.scale, zz / a.scale)
    pcall(a.SetShown, a, true)
end

-- The burning squares and the empowered pieces' auras, as pos has them.
function View:SetAuras(pos)
    local FX = ns.ChessCheats and ns.ChessCheats.FX
    if not FX then return end
    local want = {}
    for sq in pairs(pos.fire or {}) do
        local x, y = B3.SquareXY(sq)
        local key = "fire" .. sq
        want[key] = true
        self:Fx(key, FX.fire.fdid, x, y, 2.6 / FX.fire.size)
    end
    for sq in pairs(pos.hand or {}) do
        local a = self.actors[sq]
        if a then
            local key = "hand" .. sq
            want[key] = true
            self:Fx(key, FX.hand.fdid, a.x or 0, a.y or 0, 0.9 * (a.scale or 1))
        end
    end
    for key in pairs(self.fx) do
        if (key:match("^fire") or key:match("^hand")) and not want[key] then self:Fx(key, nil) end
    end
end

-- A short effect at a square (heal, flare): shown for `dur` seconds.
function View:Flash(fdid, sq, scale, dur)
    local x, y = B3.SquareXY(sq)
    local key = "flash" .. sq .. ":" .. fdid
    self:Fx(key, fdid, x, y, scale)
    self.flashes = self.flashes or {}
    self.flashes[key] = GetTime() + (dur or 1.5)
end

---------------------------------------------------------------------------
-- Animating a move
---------------------------------------------------------------------------

-- Is a move still being shown?
function View:Busy() return next(self.anims) ~= nil end

-- Shows move info mi (Chess.lua MoveInfo) from the position before it to `after` (the position after it).
function View:Animate(mi, after)
    if not mi or not mi.from or not self.actors[mi.from] then
        self:SetPosition(after)
        return
    end
    local now = GetTime()
    local a = self.actors[mi.from]
    local fx, fy = B3.SquareXY(mi.from)
    local tx, ty = B3.SquareXY(mi.to)
    local dist = sqrt((tx - fx) ^ 2 + (ty - fy) ^ 2)
    local run = abs(mi.piece) == 2 or dist > 6.5
    local speed = max(run and RUN or WALK, dist / MOVE_MAX)
    local victim = mi.cap ~= 0 and self.actors[mi.capSq] or nil
    local stop = victim and max(0, dist - 2.2 - 0.25 * (victim.scale or 1)) or dist
    local def = PieceDef(mi.piece)
    local list = {}
    -- the mover: walks (stops short of a victim), strikes, then takes the square
    list[#list + 1] = { a = a, kind = "move", sq0 = mi.from, sq1 = mi.to, x0 = fx, y0 = fy, x1 = tx, y1 = ty,
                        dist = dist, stop = stop,
                        t0 = now, speed = speed, anim = run and A.run or A.walk,
                        strike = victim and (def.melee and A.attack or A.cast) or nil, face = a.face,
                        promo = mi.promo and mi.promo > 0 and mi.promo * mi.mover or nil }
    if victim then
        local hitAt = now + stop / speed + 0.35
        list[#list + 1] = { a = victim, kind = "die", t0 = hitAt, sq = mi.capSq }
    end
    if mi.castle then
        local rf = mi.to > mi.from and mi.from + 3 or mi.from - 4
        local rt = mi.to > mi.from and mi.from + 1 or mi.from - 1
        local ra = self.actors[rf]
        if ra then
            local x0, y0 = B3.SquareXY(rf)
            local x1, y1 = B3.SquareXY(rt)
            local d = sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
            list[#list + 1] = { a = ra, kind = "move", sq0 = rf, sq1 = rt, x0 = x0, y0 = y0, x1 = x1, y1 = y1,
                                dist = d, stop = d,
                                t0 = now, speed = WALK, anim = A.walk, face = ra.face }
        end
    end
    for _, bu in ipairs(mi.burned or {}) do
        local ba = self.actors[bu.sq]
        if ba then list[#list + 1] = { a = ba, kind = "die", t0 = now + 0.2, burn = true, sq = bu.sq } end
    end
    self.after = after
    self.anims = list
    self.dirty = true
end

-- Steps the animations. -> true when something moved
function View:StepAnims()
    local list = self.anims
    if not next(list) then return false end
    local now = GetTime()
    local done = true
    for _, an in ipairs(list) do
        local a = an.a
        if an.kind == "move" and not an.finished then
            done = false
            local t = now - an.t0
            local walked = t * an.speed
            local heading = atan2(an.y1 - an.y0, an.x1 - an.x0)
            if an.strike and not an.struck and walked >= an.stop then
                -- at the victim: the blow, then on
                if not an.strikeAt then
                    an.strikeAt = now
                    Anim(a, an.strike)
                end
                if now - an.strikeAt >= 0.9 then
                    an.struck = true
                    an.t0 = now - an.stop / an.speed
                    Anim(a, an.anim)
                end
                walked = an.stop
            elseif a.anim ~= an.anim and (not an.strike or an.struck or walked < an.stop) then
                Anim(a, an.anim)
            end
            if walked >= an.dist and (not an.strike or an.struck) then
                walked = an.dist
                an.finished = true
                Anim(a, A.stand)
                if an.promo then self:Dress(a, an.promo) end
            end
            local k = an.dist > 0 and walked / an.dist or 1
            local x, y = an.x0 + (an.x1 - an.x0) * k, an.y0 + (an.y1 - an.y0) * k
            -- facing: the way it goes, back to its side's forward at the end
            self:Put(a, x, y, an.finished and an.face or heading)
        elseif an.kind == "die" and not an.finished then
            done = false
            local t = now - an.t0
            if t >= 0 then
                if not an.fell then
                    an.fell = true
                    Anim(a, A.death)
                    if an.burn and ns.ChessCheats then
                        self:Flash(ns.ChessCheats.FX.fireImpact.fdid, an.sq, 0.08, 1.2)
                    end
                end
                if t > 1.0 then
                    local f = min(1, (t - 1.0) / FADE)
                    pcall(a.SetAlpha, a, 1 - f)
                    if f >= 1 then an.finished = true end
                end
            end
        end
    end
    if done then
        -- the actors to their new squares (the fallen first: one may have stood on the square taken), so the
        -- position that follows keeps every model instead of loading it again
        for _, an in ipairs(list) do
            if an.kind == "die" and an.sq and self.actors[an.sq] == an.a then
                self.actors[an.sq] = nil
                self:FreeActor(an.a)
            end
        end
        local moved = {}
        for _, an in ipairs(list) do
            if an.kind == "move" and an.sq0 and self.actors[an.sq0] == an.a then
                self.actors[an.sq0] = nil
                moved[#moved + 1] = an
            end
        end
        for _, an in ipairs(moved) do self.actors[an.sq1] = an.a end
        self.anims = {}
        local after = self.after
        self.after = nil
        if after then self:SetPosition(after) end
        if self.opts.onAnimDone then self.opts.onAnimDone() end
    end
    return true
end

---------------------------------------------------------------------------
-- Marks on the squares
---------------------------------------------------------------------------

-- marks = { sel = sq, moves = { [sq] = "move" | "cap" }, last = { from, to }, check = sq, hover = sq }
function View:SetMarks(marks)
    self.marks = marks or {}
    self.dirty = true
end

function View:Outline(sq, c, inset, a, thick)
    local R_ = self.R
    local pts = Corners(sq, inset)
    local z = (self.z[sq] or 0) + LIFT
    for i = 1, 4 do
        local p, q = pts[i], pts[i % 4 + 1]
        R_.Line(p[1], p[2], z, q[1], q[2], z, c[1], c[2], c[3], a or 1, thick or 2)
    end
end

function View:DrawMarks()
    local m = self.marks
    if m.last then
        if m.last[1] then self:Outline(m.last[1], C_LAST, 0.06, 0.6, 2) end
        if m.last[2] then self:Outline(m.last[2], C_LAST, 0.06, 0.8, 2) end
    end
    for sq in pairs(self.pos and self.pos.fire or {}) do self:Outline(sq, C_FIRE, 0.04, 0.9, 2) end
    if m.check then self:Outline(m.check, C_CHECK, 0.03, 1, 3) end
    for sq, kind in pairs(m.moves or {}) do
        if kind == "cap" then
            self:Outline(sq, C_CAP, 0.08, 0.95, 2)
        else
            self:Outline(sq, C_MOVE, 0.3, 0.9, 2)
        end
    end
    if m.sel then self:Outline(m.sel, C_SEL, 0.02, 1, 3) end
    if m.hover and m.hover ~= m.sel then self:Outline(m.hover, C_HOVER, 0.12, 0.55, 1) end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

-- The pieces as occluders (what the room's copies hide): one box each, the client's own box once the model loaded.
function View:Occluders()
    local occ, n = self.occ, 0
    local function add(a, id)
        if not a or not a.x then return end
        if not a.bb and a.loadedOnce and a.GetActiveBoundingBox then
            local ok, x0, y0, z0, x1, y1, z1 = ns.Render3D.ActorBox(a, "active")
            if ok and type(z1) == "number" and z1 > (z0 or 0) then
                a.bb = { r = max(abs(x0), abs(x1), abs(y0), abs(y1)), z1 = z1 }
            end
        end
        local s = a.scale or 1
        local h = a.bb and a.bb.z1 * s or 2.2 * s
        local rb = a.bb and a.bb.r * s or 0.6 * s
        n = n + 1
        local o = occ[n] or {}
        occ[n] = o
        o.id, o.x, o.y, o.z, o.h, o.group = id, a.x, a.y, a.z or 0, h, nil
        o.w, o.rb, o.top, o.prio, o.layer = max(1, 0.7 * s), rb, h, 1, nil
    end
    for _, a in pairs(self.actors) do add(a, a) end
    for _, an in ipairs(self.anims) do add(an.a, an.a) end
    add(self.medivh, self.medivh)
    for k = n + 1, #occ do occ[k] = nil end
    return occ, n
end

-- The depth mode the hall uses (the strategy board's choice per room: box, stand-ins or stand-ins with gaps;
-- Render3D/View.lua View:SyncDepthMode).
function View:SyncStandins()
    local M3 = ns.StrategyMap3D
    local key = self.room and self.room.key
    local mode = (M3 and M3.DepthMode and key) and M3.DepthMode(key) or "box"
    local use, gaps = self.view:SyncDepthMode(key, mode, M3 and M3.standins, M3 and M3.GapSet)
    self.standins, self.standinGaps = use, gaps
    return use
end

-- The squares' corners on screen (for clicks), and the letters round the board.
function View:ProjectSquares()
    local proj = self.proj
    for i = 1, 64 do
        local sq = R.SQ[i]
        local c = Corners(sq)
        local z = self.z[sq] or 0
        local p = proj[sq] or {}
        proj[sq] = p
        p.ok = true
        for k = 1, 4 do
            local x, y = self.view:Project(c[k][1], c[k][2], z)
            if not x then p.ok = false break end
            p[2 * k - 1], p[2 * k] = x, y
        end
    end
    -- a-h under rank 1, 1-8 left of file a (from white's side; they turn with the board)
    for i = 1, 8 do
        local x, y = B3.SquareXY(R.Square(i - 1, 0))
        x, y = x - ROW.x * 0.8, y - ROW.y * 0.8
        local px, py = self.view:Project(x, y, self.z[R.Square(i - 1, 0)] or 0)
        local t = self.labels[i]
        if px then
            t:ClearAllPoints()
            t:SetPoint("CENTER", self.view.plateFrame, "BOTTOMLEFT", px, py)
            t:SetText(string.char(96 + i))
            t:Show()
        else
            t:Hide()
        end
        local x2, y2 = B3.SquareXY(R.Square(0, i - 1))
        x2, y2 = x2 - COL.x * 0.8, y2 - COL.y * 0.8
        local qx, qy = self.view:Project(x2, y2, self.z[R.Square(0, i - 1)] or 0)
        local t2 = self.labels[8 + i]
        if qx then
            t2:ClearAllPoints()
            t2:SetPoint("CENTER", self.view.plateFrame, "BOTTOMLEFT", qx, qy)
            t2:SetText(tostring(i))
            t2:Show()
        else
            t2:Hide()
        end
    end
end

local function Inside(p, x, y)
    -- a convex quad, corners in turn: the point on the same side of every edge
    local sign = 0
    for k = 1, 4 do
        local x1, y1 = p[2 * k - 1], p[2 * k]
        local j = k % 4 + 1
        local x2, y2 = p[2 * j - 1], p[2 * j]
        local c = (x2 - x1) * (y - y1) - (y2 - y1) * (x - x1)
        if c ~= 0 then
            local s = c > 0 and 1 or -1
            if sign == 0 then sign = s elseif s ~= sign then return false end
        end
    end
    return true
end

-- The square under the mouse, or nil.
function View:SquareAtCursor()
    local x, y = self.view:Cursor()
    for sq, p in pairs(self.proj) do
        if p.ok and Inside(p, x, y) then return sq end
    end
    return nil
end

function View:Draw()
    self.dirty = false
    local si = self:SyncStandins()
    if not self.calibrated then
        self.calibrated = self.view:CalibrateOrbit(function() self:Place() end, MID.x, MID.y, self.midZ + 1,
            self.orb.heading)
        if not self.calibrated then
            self.dirty = true
            return
        end
    end
    self:Place()
    -- (the pieces' positions with the camera's mirror: placed again when it was just found)
    if self.calibrated ~= "placed" then
        self.calibrated = "placed"
        if self.pos and not self:Busy() then self:SetPosition(self.pos) end
        if self.medivh then
            local m = B3.MEDIVH
            self:Put(self.medivh, m.x, m.y, atan2(MID.y - m.y, MID.x - m.x))
        end
    end
    local occ, n = self:Occluders()
    self.view:DrawFrame(occ, n, self.drawMarks, si, self.standinGaps)
    self:ProjectSquares()
end

-- While the panel fades (the hub's way into a game and back out), nothing of the hall is drawn: its opaque pieces
-- (blend DISABLE) and the models do not fade with their parent, and stayed whole over the carousel until the panel
-- was hidden (seen in game 2026-10-08). Back at full alpha it is drawn again.
function View:Faded()
    local a = self.frame.GetEffectiveAlpha and self.frame:GetEffectiveAlpha() or 1
    if a < 0.99 then
        if not self.faded then
            self.faded = true
            if self.R and self.R.Clear then self.R.Clear() end
            self.view.scene:Hide()
            self.view.plateFrame:Hide()
        end
        return true
    end
    if self.faded then
        self.faded = false
        self.view.scene:Show()
        self.view.plateFrame:Show()
        self.dirty = true
    end
    return false
end

function View:OnUpdate(elapsed)
    if self:Faded() then return end
    -- the camera: a turn under way, a right / middle drag
    local moved = self.orbit:Step()
    if self:StepAnims() then moved = true end
    if self.medivhUntil and GetTime() > self.medivhUntil then
        self.medivhUntil = nil
        if self.medivh then Anim(self.medivh, A.stand) end
    end
    if self.flashes then
        local now = GetTime()
        for key, untilT in pairs(self.flashes) do
            if now > untilT then
                self.flashes[key] = nil
                self:Fx(key, nil)
            end
        end
    end
    -- the square under the mouse
    if self.frame:IsMouseOver() and not self.orbit.drag then
        local sq = self:SquareAtCursor()
        if sq ~= self.hover then
            self.hover = sq
            self.marks.hover = sq
            if self.opts.onHover then self.opts.onHover(sq) end
            moved = true
        end
    elseif self.hover then
        self.hover = nil
        self.marks.hover = nil
        moved = true
    end
    -- models still loading: draw again now and then (their boxes, for the copies)
    self.acc = (self.acc or 0) + (elapsed or 0)
    if self.acc > 0.5 then
        self.acc = 0
        for _, a in pairs(self.actors) do if a.loadedOnce and not a.bb then moved = true break end end
    end
    if moved or self.dirty then self:Draw() end
end

function View:MouseDown(button)
    if button == "RightButton" or button == "MiddleButton" then
        self.orbit:BeginDrag(button)
    elseif button == "LeftButton" then
        self.downSq = self:SquareAtCursor()
    end
end

function View:MouseUp(button)
    if button == "LeftButton" then
        local sq = self:SquareAtCursor()
        if sq and sq == self.downSq and self.opts.onSquare then self.opts.onSquare(sq, button) end
        self.downSq = nil
    elseif self.orbit:EndDrag(button) == "click" and button == "RightButton" then
        -- (a right click that turned nothing)
        if self.opts.onSquare then self.opts.onSquare(nil, "RightButton") end
    end
end

function View:Wheel(delta)
    self.orbit:Wheel(delta)
    self.dirty = true
end
