if DisasterZoneBoot and DisasterZoneBoot.Run("Render3D/Standins.lua", ...) then return end -- DisasterZone Render3D/Standins.lua
-- ns.Render3D.Standins: the stand-in depth mode of a 3D view (the strategy board's /dz 3d standins). The room is drawn
-- as UI textures, which have no depth; the models stand in ModelScenes, which have. All of the client's model scenes
-- share one depth buffer, and an opaque UI texture drawn between two of them leaves it as it is (seen in game
-- 2026-10-05). So plain cubes (Blizzard's spells/unitcube.m2) placed just behind the room's surfaces, in a scene under
-- the room and covered by an opaque backdrop (Render3D/View.lua View:StandinScene), are never seen but still hide
-- every model pixel that lies behind a surface of the room - exactly, per pixel, particles too - with no occluder
-- boxes and no copies.
--
-- The stand-ins are made offline from the room's surfaces (Render3D/Standins/<RoomKey>.lua, data below). A room has
-- thousands; the client keeps full speed with a few hundred to ~1500 (4000 paused cubes ran at 31-60 fps), so every
-- redraw shows only those that can matter: their surface faces the camera, they are in view, and they lie nearer than
-- some model and over its rectangle on the screen - the biggest on the screen first, up to a budget. They stand still
-- in the room: an actor is placed when its stand-in joins the selection, not when the camera moves.
--
-- Data (ns.RoomStandins[roomKey], room coordinates as the room files: yd, x east, y north, z over the boss' floor):
--   { version = 1, prims = { [1] = { fid = 167145, kind = "cube", half = 0.5 }, ... }, n = count, stride = 12,
--     data = { numbers; or strings of numbers and tables of them, read in order } }
-- one stand-in = prim index, x, y, z (the prim's origin), yaw, pitch, roll (radians, the client's SetYaw / SetPitch /
-- SetRoll in room coordinates), scale (uniform: the prim's size times it, in yd), nx, ny, nz (the unit normal of the
-- surface it stands behind, to the side the surface is seen from), face (the surface's id, for debugging). A
-- stand-in lies wholly behind its surface, so it matters only while that surface faces the camera.
local _, ns = ...

local R3 = ns.Render3D or {}
ns.Render3D = R3

local S = {}
R3.Standins = S

local floor, sqrt, abs, max, min, huge = math.floor, math.sqrt, math.abs, math.max, math.min, math.huge
local cos, sin = math.cos, math.sin
local pcall, type, tonumber, pairs = pcall, type, tonumber, pairs
local tremove, tsort = table.remove, table.sort

S.BUDGET = 800                   -- stand-ins shown at most (/dz 3d standins budget)
S.MAX_BUDGET = 4000
-- The only model files a stand-in may load: ones seen loading by file ID in this client. Any other number can crash
-- it, and a loose file from the addon's folder crashed it after a /reload (2026-10-05).
local SAFE_FIDS = { [167145] = true }        -- spells/unitcube.m2: an opaque white 1 yd cube centred on its origin
local SQRT3 = sqrt(3)
-- A stand-in's circle on the screen is taken this much bigger: perspective stretches a ball away from the middle of
-- the view, and a stand-in left out where it was needed lets a model show through a wall.
local PAD = 1.25
local EDGE = 2                   -- px round a model's rectangle
local DEBUG_ALPHA = 0.5          -- the cubes in debug mode, drawn over the room: see-through, to see both

---------------------------------------------------------------------------
-- A room's data, ready to select from
---------------------------------------------------------------------------

local function Finite(v) return type(v) == "number" and v == v and v > -huge and v < huge end

-- The numbers of a room's data, flat: the table itself when it holds only numbers, else its strings and tables read
-- in order. -> nil when anything in it is not a number.
local function Flat(data)
    if type(data) == "string" then data = { data } end
    if type(data) ~= "table" then return nil end
    local plain = true
    for i = 1, #data do
        if type(data[i]) ~= "number" then
            plain = false
            break
        end
    end
    if plain then return data end
    local out, n = {}, 0
    local function add(v)
        local t = type(v)
        if t == "number" then
            n = n + 1
            out[n] = v
        elseif t == "string" then
            for w in v:gmatch("%S+") do
                local x = tonumber(w)
                if not x then return false end
                n = n + 1
                out[n] = x
            end
        elseif t == "table" then
            for i = 1, #v do
                if add(v[i]) == false then return false end
            end
        else
            return false
        end
    end
    if add(data) == false then return nil end
    return out
end

-- A room's stand-ins ready to select from: the flat numbers and per stand-in its radius round its origin (R) and its
-- reach along its normal times the normal's length (E: its surface lies at least that far in front of its origin, so
-- a camera less far out than that is behind the surface), false for one that is never shown (a model file not known
-- to load, no size, a broken number). -> the set, or nil and why ("none", "unreadable", "empty").
function S.Prepare(rec)
    if type(rec) ~= "table" then return nil, "none" end
    local d = Flat(rec.data)
    local stride = tonumber(rec.stride) or 12
    if not d or stride < 12 then return nil, "unreadable" end
    stride = floor(stride)
    local n = floor(#d / stride)
    if tonumber(rec.n) then n = min(n, floor(rec.n)) end
    local prims = type(rec.prims) == "table" and rec.prims or {}
    local R, E = {}, {}
    local usable, unsafe = 0, 0
    for i = 1, n do
        local o = (i - 1) * stride
        local p = prims[d[o + 1]]
        local ok = true
        for k = 2, 11 do
            if not Finite(d[o + k]) then
                ok = false
                break
            end
        end
        local s = d[o + 8]
        if ok and not (type(p) == "table" and SAFE_FIDS[p.fid]) then
            ok = false
            unsafe = unsafe + 1
        end
        local nx, ny, nz = d[o + 9], d[o + 10], d[o + 11]
        local len = ok and sqrt(nx * nx + ny * ny + nz * nz) or 0
        if ok and s > 0 and len > 1e-6 then
            local h = (tonumber(p.half) or 0.5) * s
            local r = h * SQRT3
            local e = r * len
            local yaw, pitch, roll = d[o + 5], d[o + 6], d[o + 7]
            if (p.kind == nil or p.kind == "cube") and pitch == 0 and roll == 0 then
                -- a cube turned about z: its reach along n is the sum over its three axes
                local c, sn = cos(yaw), sin(yaw)
                e = h * (abs(nx * c + ny * sn) + abs(ny * c - nx * sn) + abs(nz))
            end
            R[i], E[i] = r, e
            usable = usable + 1
        else
            R[i], E[i] = false, false
        end
    end
    if usable == 0 then return nil, "empty" end
    return { d = d, stride = stride, n = n, R = R, E = E, prims = prims, usable = usable, unsafe = unsafe }
end

-- The data of a room, as loaded (nil without).
local function Rec(key) return ns.RoomStandins and key and ns.RoomStandins[key] or nil end

-- The prepared set of a room (ns.RoomStandins[key]), made once per data table. -> the set and the data, or nil and
-- why.
local CACHE = setmetatable({}, { __mode = "k" })
function S.Load(key)
    local rec = Rec(key)
    if type(rec) ~= "table" then return nil, "none" end
    if CACHE[rec] == nil then
        local set, why = S.Prepare(rec)
        CACHE[rec] = set or why
    end
    local set = CACHE[rec]
    if type(set) ~= "table" then return nil, set end
    return set, rec
end

---------------------------------------------------------------------------
-- Which stand-ins matter now
---------------------------------------------------------------------------

-- The models' rectangles on the screen into out[1 ..]: each a view occluder record (x, y, z = its feet, h / top = its
-- height, rb / w = its reach round them; room coordinates) as a box, its eight corners projected; far = the depth of
-- its farthest corner. A box through the near plane covers the whole view; one wholly behind it is left out.
-- cam: x, y, z, fx, fy, fz (eye and unit view direction, room coordinates), near. proj(x, y, z) -> screen x, y (UI
-- units from the view's bottom-left), or nil. -> the count.
function S.ModelRects(occ, n, cam, proj, out)
    local ex, ey, ez, fx, fy, fz, near = cam.x, cam.y, cam.z, cam.fx, cam.fy, cam.fz, cam.near
    local m = 0
    for i = 1, n or 0 do
        local o = occ[i]
        local r = max(o.rb or 0, (o.w or 0) / 2, 0.25)
        local z0 = o.z
        local z1 = o.z + max(o.h or 0, o.top or 0, 0.5)
        local x0, y0, x1, y1, far, cut = huge, huge, -huge, -huge, -huge, false
        for c = 0, 7 do
            local x = o.x + ((c % 2 == 0) and -r or r)
            local y = o.y + ((floor(c / 2) % 2 == 0) and -r or r)
            local z = (c < 4) and z0 or z1
            local dep = (x - ex) * fx + (y - ey) * fy + (z - ez) * fz
            if dep > far then far = dep end
            local sx, sy
            if dep >= near then sx, sy = proj(x, y, z) end
            if sx then
                if sx < x0 then x0 = sx end
                if sx > x1 then x1 = sx end
                if sy < y0 then y0 = sy end
                if sy > y1 then y1 = sy end
            else
                cut = true
            end
        end
        if far > near then
            m = m + 1
            local M = out[m] or {}
            out[m] = M
            if cut then
                M.x0, M.y0, M.x1, M.y1 = -huge, -huge, huge, huge
            else
                M.x0, M.y0, M.x1, M.y1 = x0 - EDGE, y0 - EDGE, x1 + EDGE, y1 + EDGE
            end
            M.far = far
        end
    end
    return m
end

local SIZE = {}                  -- stand-in -> its radius on the screen this redraw (the budget's order)
local function Bigger(a, b)
    local sa, sb = SIZE[a], SIZE[b]
    if sa ~= sb then return sa > sb end
    return a < b                 -- (a steady order: the same stand-ins win from redraw to redraw)
end

-- The stand-ins to show, into out[1 .. count]: their surface faces the camera (the camera farther out along the
-- normal than the stand-in reaches), some of them lies past the near plane and on the screen, and - unless `all` -
-- they lie over a model's rectangle and some of them nearer than its farthest corner (models[1 .. nm], S.ModelRects).
-- Over the budget the biggest on the screen win. cam: as S.ModelRects, plus w, h (the view, UI units) and k (px per
-- yd at a depth of 1). st (optional): counts are written into it. -> the count.
function S.Select(set, cam, proj, models, nm, budget, out, all, st)
    local d, stride, R, E = set.d, set.stride, set.R, set.E
    local ex, ey, ez, fx, fy, fz = cam.x, cam.y, cam.z, cam.fx, cam.fy, cam.fz
    local near, w, h, k = cam.near, cam.w, cam.h, cam.k
    -- every model's rectangle together and the farthest of them: most stand-ins are turned away by these alone
    local ux0, uy0, ux1, uy1, ufar = huge, huge, -huge, -huge, -huge
    for m = 1, nm do
        local M = models[m]
        if M.x0 < ux0 then ux0 = M.x0 end
        if M.y0 < uy0 then uy0 = M.y0 end
        if M.x1 > ux1 then ux1 = M.x1 end
        if M.y1 > uy1 then uy1 = M.y1 end
        if M.far > ufar then ufar = M.far end
    end
    local cnt, facing, inView = 0, 0, 0
    for i = 1, set.n do
        local r = R[i]
        if r then
            local o = (i - 1) * stride
            local px, py, pz = d[o + 2], d[o + 3], d[o + 4]
            local vx, vy, vz = ex - px, ey - py, ez - pz
            if vx * d[o + 9] + vy * d[o + 10] + vz * d[o + 11] > E[i] then
                facing = facing + 1
                local dep = -(vx * fx + vy * fy + vz * fz)
                if dep + r > near then
                    local x0, y0, x1, y1, nearest, size
                    if dep - r <= near then
                        -- through the near plane: anywhere on the screen
                        x0, y0, x1, y1, nearest, size = -huge, -huge, huge, huge, near, huge
                    else
                        local sx, sy = proj(px, py, pz)
                        if sx then
                            local rp = PAD * k * r / (dep - r)
                            x0, y0, x1, y1, nearest, size = sx - rp, sy - rp, sx + rp, sy + rp, dep - r, rp
                        end
                    end
                    if x0 and x1 >= 0 and x0 <= w and y1 >= 0 and y0 <= h then
                        inView = inView + 1
                        local hit = all
                        if not hit and nearest < ufar and x1 >= ux0 and x0 <= ux1 and y1 >= uy0 and y0 <= uy1 then
                            for m = 1, nm do
                                local M = models[m]
                                if nearest < M.far and x1 >= M.x0 and x0 <= M.x1 and y1 >= M.y0 and y0 <= M.y1 then
                                    hit = true
                                    break
                                end
                            end
                        end
                        if hit then
                            cnt = cnt + 1
                            out[cnt] = i
                            SIZE[i] = size
                        end
                    end
                end
            end
        end
    end
    local relevant = cnt
    for j = #out, cnt + 1, -1 do out[j] = nil end
    if cnt > budget then
        tsort(out, Bigger)
        for j = cnt, budget + 1, -1 do out[j] = nil end
        cnt = budget
    end
    for j = 1, relevant do
        local i = out[j]
        if i then SIZE[i] = nil end
    end
    if relevant > cnt then
        for i in pairs(SIZE) do SIZE[i] = nil end    -- (the ones cut off by the budget)
    end
    if st then st.facing, st.inView, st.relevant = facing, inView, relevant end
    return cnt
end

---------------------------------------------------------------------------
-- A view's stand-ins
---------------------------------------------------------------------------

-- A stand-in stays still: paused (2.5.6 actors have SetPaused; else the frozen pose Blizzard sets).
local function Freeze(a)
    if a.SetPaused then pcall(a.SetPaused, a, true) else pcall(a.SetAnimation, a, 0, 0, 0, 0) end
end

-- (asked again when a model has loaded: its own origin at the actor's position, and paused)
local function OnLoaded(a)
    pcall(a.SetUseCenterForOrigin, a, false, false, false)
    Freeze(a)
end

-- px per yd at a depth of 1 yd, measured with the projection 10 yd ahead (one yard right and one up: the larger);
-- nil when the projection gives nothing there.
local function PxPerYd(cam, proj)
    local fx, fy, fz = cam.fx, cam.fy, cam.fz
    local ax, ay, az = cam.x + 10 * fx, cam.y + 10 * fy, cam.z + 10 * fz
    local flat = sqrt(fx * fx + fy * fy)
    local rx, ry = 1, 0
    if flat > 1e-4 then rx, ry = fy / flat, -fx / flat end
    local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx            -- (up = right x forward)
    local x0, y0 = proj(ax, ay, az)
    local x1, y1 = proj(ax + rx, ay + ry, az)
    local x2, y2 = proj(ax + ux, ay + uy, az + uz)
    if not (x0 and x1 and x2) then return nil end
    return 10 * max(sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2), sqrt((x2 - x0) ^ 2 + (y2 - y0) ^ 2))
end

local Ctl = {}
Ctl.__index = Ctl

-- The stand-ins of a view (Render3D/View.lua), made once per view with its stand-in scene. -> nil when the client
-- makes no scene for them.
function S.For(view)
    if view.standinCtl ~= nil then return view.standinCtl or nil end
    local sc = view.StandinScene and view:StandinScene()
    if not sc then
        view.standinCtl = false
        return nil
    end
    local c = setmetatable({ view = view, scene = sc, pool = {}, free = {}, at = {}, sel = {}, want = {}, rects = {},
                             sig = {}, cam = {}, budget = S.BUDGET, all = false, debug = false, flag = false,
                             stats = { shown = 0, placed = 0, skipped = 0, facing = 0, inView = 0, relevant = 0 } },
                           Ctl)
    view.standinCtl = c
    return c
end

-- Stand in for room `key` (as the room files are named). -> true when it has stand-ins; else nothing is shown, and
-- why ("none": no data for this room, "unreadable", "empty": none that can be shown).
function Ctl:Use(key)
    if key and key == self.key and self.set and Rec(key) == self.rec then return true end
    self:Off()
    local set, rec = S.Load(key)
    if not set then return false, rec end
    self.key, self.set, self.rec = key, set, rec
    return true
end

-- Nothing shown, the scene and its backdrop hidden (the box mode).
function Ctl:Off()
    local any = false
    for i, a in pairs(self.at) do
        self.at[i] = nil
        self.free[#self.free + 1] = a
        any = true
    end
    if any then self:HideFree() end                -- (only actors with a stand-in are ever shown)
    self.key, self.set, self.rec, self.sig.n = nil, nil, nil, nil
    self.stats.shown = 0
    self.view:StandinLayer(false)
end

-- cfg: budget (stand-ins at most), all (debug: every one facing the camera and in view, not only those over a
-- model), debug (the cubes drawn over the room, see-through), flag (SetAllowOverlappedModels on the stand-in scene:
-- a test of the client's unexplained flag, off unless asked).
function Ctl:Configure(cfg)
    cfg = cfg or {}
    local budget = max(0, min(S.MAX_BUDGET, floor(tonumber(cfg.budget) or S.BUDGET)))
    local all = cfg.all and true or false
    if budget ~= self.budget or all ~= self.all then
        self.budget, self.all, self.sig.n = budget, all, nil        -- (select again)
    end
    local debug = cfg.debug and true or false
    if debug ~= self.debug then
        self.debug = debug
        for _, a in ipairs(self.pool) do self:Alpha(a) end
    end
    local flag = cfg.flag and true or false
    if flag ~= self.flag then
        self.flag = flag
        local sc = self.scene
        if sc.SetAllowOverlappedModels then pcall(sc.SetAllowOverlappedModels, sc, flag) end
    end
    if self.set then self.view:StandinLayer(debug and "debug" or "depth") end
end

function Ctl:Alpha(a)
    local want = self.debug and DEBUG_ALPHA or 1
    if a.salpha ~= want then
        a.salpha = want
        pcall(a.SetAlpha, a, want)
    end
end

function Ctl:NewActor()
    local sc = self.scene
    local ok, a = pcall(sc.CreateActor, sc, nil, "ModelSceneActorTemplate")
    if not ok or not a then ok, a = pcall(sc.CreateActor, sc) end
    if not ok or not a then return nil end
    pcall(a.SetUseCenterForOrigin, a, false, false, false)
    if a.SetOnModelLoadedCallback then pcall(a.SetOnModelLoadedCallback, a, OnLoaded) end
    self.pool[#self.pool + 1] = a
    return a
end

-- An actor as stand-in i: its model, size, place and turn in the scene as the view places creatures (scene y = room
-- y times the mirror; the client multiplies the position by the scale). The y mirror turns a turn about z or x the
-- other way and keeps one about y: yaw and roll change sign, pitch stays, whatever order the client turns in.
function Ctl:Place(a, i)
    local set = self.set
    local d, o = set.d, (i - 1) * set.stride
    local fid = set.prims[d[o + 1]].fid
    if a.sfid ~= fid then
        a.sfid = fid
        pcall(a.ClearModel, a)
        -- (only a file this client was seen loading: SAFE_FIDS, checked when the set was prepared)
        pcall(a.SetModelByFileID, a, fid)
        pcall(a.SetUseCenterForOrigin, a, false, false, false)
        Freeze(a)
    end
    local s = d[o + 8]
    if a.sscale ~= s then
        a.sscale = s
        pcall(a.SetScale, a, s)
    end
    local m = self.mirror or 1
    pcall(a.SetPosition, a, d[o + 2] / s, m * d[o + 3] / s, d[o + 4] / s)
    pcall(a.SetYaw, a, m * d[o + 5])
    local pitch, roll = d[o + 6], m * d[o + 7]
    if pitch ~= (a.spitch or 0) then
        a.spitch = pitch
        if a.SetPitch then pcall(a.SetPitch, a, pitch) end
    end
    if roll ~= (a.sroll or 0) then
        a.sroll = roll
        if a.SetRoll then pcall(a.SetRoll, a, roll) end
    end
    self:Alpha(a)
    if not a.sshown then
        a.sshown = true
        pcall(a.SetShown, a, true)
    end
    a.standin = i
end

function Ctl:HideFree()
    local free = self.free
    for k = 1, #free do
        local a = free[k]
        if a.sshown then
            a.sshown, a.standin = false, nil
            pcall(a.SetShown, a, false)
        end
    end
end

-- Does the selection need doing again? The camera (eye, direction, view size, mirror) and the models' records
-- against the last redraw's. -> true when anything changed.
local function Put(s, j, v, diff)
    if s[j] ~= v then
        s[j] = v
        return true
    end
    return diff
end
function Ctl:Changed(cam, occ, n)
    local s = self.sig
    local diff = s.n ~= n
    s.n = n
    diff = Put(s, 1, cam.x, diff)
    diff = Put(s, 2, cam.y, diff)
    diff = Put(s, 3, cam.z, diff)
    diff = Put(s, 4, cam.fx, diff)
    diff = Put(s, 5, cam.fy, diff)
    diff = Put(s, 6, cam.fz, diff)
    diff = Put(s, 7, cam.w, diff)
    diff = Put(s, 8, cam.h, diff)
    diff = Put(s, 9, self.mirror, diff)
    for i = 1, n do
        local o, j = occ[i], 9 + i * 7 - 7
        diff = Put(s, j + 1, o.x, diff)
        diff = Put(s, j + 2, o.y, diff)
        diff = Put(s, j + 3, o.z, diff)
        diff = Put(s, j + 4, o.h, diff)
        diff = Put(s, j + 5, o.top, diff)
        diff = Put(s, j + 6, o.rb, diff)
        diff = Put(s, j + 7, o.w, diff)
    end
    return diff
end

-- One redraw: picks the stand-ins that matter for the models (occ[1 .. n], the view's occluder records) and shows
-- them; proj(x, y, z) -> screen x, y of a room point with the camera just measured (Room.Project). Actors that keep
-- their stand-in are not touched; nothing at all happens while the camera and the models stand still. -> the count
-- shown.
function Ctl:Update(occ, n, proj)
    local set, view = self.set, self.view
    if not set then return 0 end
    view:StandinLayer(self.debug and "debug" or "depth")
    local vc, cam = view.cam, self.cam
    local m = vc.mirror or 1
    if m ~= self.mirror then
        -- (the calibration turned the scene's y round: every actor stands somewhere else now)
        self.mirror = m
        for i, a in pairs(self.at) do
            self.at[i] = nil
            self.free[#self.free + 1] = a
        end
    end
    cam.x, cam.y, cam.z = vc.x, m * vc.y, vc.z
    cam.fx, cam.fy, cam.fz = vc.fx, m * vc.fy, vc.fz
    cam.near = view.near or 0.5
    cam.w, cam.h = view.scene:GetWidth() or 0, view.scene:GetHeight() or 0
    local st = self.stats
    if not self:Changed(cam, occ, n) then
        st.skipped = st.skipped + 1
        return st.shown
    end
    cam.k = PxPerYd(cam, proj) or 2 * max(cam.w, cam.h)
    local nm = S.ModelRects(occ, n, cam, proj, self.rects)
    local sel = self.sel
    local cnt = S.Select(set, cam, proj, self.rects, nm, self.budget, sel, self.all, st)
    -- actors whose stand-in left the selection are free (hidden at the end unless one takes them again)
    local want, at, free = self.want, self.at, self.free
    for i in pairs(want) do want[i] = nil end
    for j = 1, cnt do want[sel[j]] = true end
    for i, a in pairs(at) do
        if not want[i] then
            at[i] = nil
            free[#free + 1] = a
        end
    end
    local shown = 0
    for j = 1, cnt do
        local i = sel[j]
        if at[i] then
            shown = shown + 1
        else
            local a = tremove(free) or self:NewActor()
            if not a then break end
            at[i] = a
            self:Place(a, i)
            st.placed = st.placed + 1
            shown = shown + 1
        end
    end
    self:HideFree()
    st.shown = shown
    return shown
end

-- What the stand-ins do: the room's count and how many can be shown, the last selection's counts, actors made,
-- actors placed so far and redraws that needed no selection.
function Ctl:Stats()
    local st, set = self.stats, self.set
    return { key = self.key, total = set and set.n or 0, usable = set and set.usable or 0,
             unsafe = set and set.unsafe or 0, facing = st.facing, inView = st.inView, relevant = st.relevant,
             shown = set and st.shown or 0, actors = #self.pool, placed = st.placed, skipped = st.skipped,
             budget = self.budget, debug = self.debug, all = self.all, flag = self.flag }
end
