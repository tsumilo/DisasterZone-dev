if DisasterZoneBoot and DisasterZoneBoot.Run("Render3D/Standins.lua", ...) then return end -- DisasterZone Render3D/Standins.lua
-- ns.Render3D.Standins: the stand-in depth mode of a 3D view (the strategy board's /dz 3d standins). The room is drawn
-- as UI textures, which have no depth; the models stand in ModelScenes, which have. All of the client's model scenes
-- share one depth buffer, and an opaque UI texture drawn between two of them leaves it as it is (seen in game
-- 2026-10-05). So plain models placed just behind the room's surfaces - flat one-sided quads lying in them (a stock
-- menu quad) and cubes (Blizzard's spells/unitcube.m2) - in a scene under the room and covered by an opaque backdrop
-- (Render3D/View.lua View:StandinScene), are never seen but still hide every model pixel that lies behind a surface of
-- the room - exactly, per pixel, particles too - with no occluder boxes and no copies.
--
-- The stand-ins are made offline from the room's surfaces (Render3D/Standins/<RoomKey>.lua, data below). A room has
-- thousands; the client keeps full speed with a few hundred to ~1500 (4000 paused cubes ran at 31-60 fps), so every
-- redraw shows only those that can matter: their surface faces the camera, they are in view, and they lie nearer than
-- some model, over its rectangle on the screen and in front of some of it - the biggest on the screen first, up to a
-- budget. They stand still in the room: an actor is placed when its stand-in joins the selection, not when the camera
-- moves.
--
-- Data (ns.RoomStandins[roomKey], room coordinates as the room files: yd, x east, y north, z over the boss' floor):
--   { version = 2, prims = { [1] = { fid = 167145, kind = "cube", half = 0.5 },
--                            [2] = { fid = 653518, kind = "quad", w = .., h = .., cx = .., cy = .., cz = .. } },
--     room = { size = .. }, n = count, stride = 12, data = { numbers; or strings of numbers and tables of them } }
-- one stand-in = prim index; x, y, z (its anchor: a cube's centre, a quad's middle); yaw, pitch, roll (radians, room
-- coordinates: the turn R = Rz(yaw) Ry(pitch) Rx(roll), the order the client applies SetYaw, SetPitch and SetRoll in -
-- roll turns the model first, Render3D/Probe.lua tiles 35-38); scale (the actor's: a cube is 2 half x scale yd a
-- side, a quad w x h x scale); nx, ny, nz (the unit normal of the surface it stands behind, to the side the surface is
-- seen from; a quad's front, R's first column, faces it); face (the surface's id: a surface's stand-ins kept together
-- make the regions a redraw turns away whole). A prim's model point q stands at anchor + scale R (q - c), c = its
-- middle in model units (cx, cy, cz; 0 for a cube). A quad is the w x h rectangle in its model's y-z plane, drawn from
-- its front only (one-sided). A stand-in lies wholly behind its surface, so it matters only while that surface faces
-- the camera. Version 1 data (cubes turned about z) reads the same.
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
local SAFE_FIDS = {
    [167145] = true,             -- spells/unitcube.m2: an opaque white 1 yd cube centred on its origin
    -- interface/glues/models/ui_mainmenu_cata_lowbandwidth/UI_MainMenu_Cata_LowBandwidth.m2: a 48.93 x 32.99 quad at
    -- model x = -4.04, one-sided (front +x), unlit, opaque; in game it fills its outline and, from a lower scene,
    -- cut a model where it stood (probe tiles 53, 54, 60)
    [653518] = true,
}
local SQRT3 = sqrt(3)
-- Stand-ins in one region at most (a run of one surface in the data, S.Prepare): a long run is cut up so each piece's
-- ball is small enough to leave the screen or a model's rectangle on its own.
local REGION_MAX = 32
local RS = 12                    -- numbers per region in a prepared set's G
-- A stand-in's normal must be a unit vector to this much: the near clip's guard (S.Select) counts along it in yd.
local UNIT_TOL = 0.01
-- A quad's front (its turned model x) must lie along its normal to this much (about 0.1 degree; the generator writes
-- them exactly): leaning, a big quad would reach out in front of its surface.
local QUAD_ALIGN = 0.9999985
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

-- The regions of a prepared set into set.G (RS numbers each) and set.ng: runs of usable stand-ins with one face id
-- (the data keeps a surface's stand-ins together; a run is cut at REGION_MAX). Each: first and last stand-in, the
-- mean normal N (unit, or 0 when they cancel), a ball (centre, radius) holding every stand-in's ball, eps (how far
-- any normal strays from N), and the most and least N . origin + reach of them (their surfaces' farthest and nearest
-- planes along N). S.Select turns a whole region away with these alone: bounds that hold for each stand-in in it.
local function Regions(set)
    local d, stride, R, E, n = set.d, set.stride, set.R, set.E, set.n
    local G, ng = {}, 0
    local i = 1
    while i <= n do
        if not R[i] then
            i = i + 1
        else
            local face = d[(i - 1) * stride + 12]
            local j = i
            while j < n and j - i + 1 < REGION_MAX and d[j * stride + 12] == face do j = j + 1 end
            local sx, sy, sz = 0, 0, 0
            local x0, y0, z0, x1, y1, z1 = huge, huge, huge, -huge, -huge, -huge
            for k = i, j do
                if R[k] then
                    local o = (k - 1) * stride
                    local px, py, pz = d[o + 2], d[o + 3], d[o + 4]
                    sx, sy, sz = sx + d[o + 9], sy + d[o + 10], sz + d[o + 11]
                    x0, y0, z0 = min(x0, px), min(y0, py), min(z0, pz)
                    x1, y1, z1 = max(x1, px), max(y1, py), max(z1, pz)
                end
            end
            local len = sqrt(sx * sx + sy * sy + sz * sz)
            if len > 1e-6 then sx, sy, sz = sx / len, sy / len, sz / len else sx, sy, sz = 0, 0, 0 end
            local cx, cy, cz = (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2
            local rad, eps, hi, lo = 0, 0, -huge, huge
            for k = i, j do
                if R[k] then
                    local o = (k - 1) * stride
                    local px, py, pz = d[o + 2], d[o + 3], d[o + 4]
                    local qx, qy, qz = px - cx, py - cy, pz - cz
                    rad = max(rad, sqrt(qx * qx + qy * qy + qz * qz) + R[k])
                    local ex, ey, ez = d[o + 9] - sx, d[o + 10] - sy, d[o + 11] - sz
                    eps = max(eps, sqrt(ex * ex + ey * ey + ez * ez))
                    local pe = sx * px + sy * py + sz * pz + E[k]
                    hi, lo = max(hi, pe), min(lo, pe)
                end
            end
            local g = ng * RS
            ng = ng + 1
            G[g + 1], G[g + 2], G[g + 3], G[g + 4], G[g + 5] = i, j, sx, sy, sz
            G[g + 6], G[g + 7], G[g + 8], G[g + 9] = cx, cy, cz, rad
            -- (an eps of float noise - the mean of equal normals - counts as none: the bounds then need no distance)
            G[g + 10], G[g + 11], G[g + 12] = (eps > 1e-9) and eps or 0, hi, lo
            i = j + 1
        end
    end
    set.G, set.ng = G, ng
end

-- A stand-in's turn (radians, room coordinates): R = Rz(yaw) Ry(pitch) Rx(roll), the order the client applies SetYaw,
-- SetPitch and SetRoll in (roll turns the model first: probe tile 38, each turn the standard right-handed one about z,
-- y and x: tiles 35-37). -> R's columns, where the model's x, y and z axes point: nine numbers, x's first.
local function Turn(yaw, pitch, roll)
    local cy, sy, cp, sp, cr, sr = cos(yaw), sin(yaw), cos(pitch), sin(pitch), cos(roll), sin(roll)
    return cy * cp, sy * cp, -sp,
        -sy * cr + cy * sp * sr, cy * cr + sy * sp * sr, cp * sr,
        sy * sr + cy * sp * cr, -cy * sr + sy * sp * cr, cp * cr
end
S.Turn = Turn

-- A quad prim's numbers: its size and middle (model units), all finite, the size above 0.
local function QuadPrim(p)
    return Finite(p.w) and Finite(p.h) and p.w > 0 and p.h > 0 and Finite(tonumber(p.cx) or 0)
        and Finite(tonumber(p.cy) or 0) and Finite(tonumber(p.cz) or 0)
end

-- A room's stand-ins ready to select from: the flat numbers and per stand-in its radius round its anchor (R) and its
-- reach along its normal (E: how far its turned box reaches out along the normal from the anchor - 0 for a quad lying
-- in its plane; its surface lies at least that far in front of the anchor, so a camera less far out than that is
-- behind the surface), false for one that is never shown (a model file not known to load, a kind it does not know, no
-- size, a broken number, a normal that is not a unit vector, a quad whose front does not face along its normal), and
-- the regions (Regions above). -> the set, or nil and why ("none", "unreadable": also data of a later version than
-- this file knows, "empty").
function S.Prepare(rec)
    if type(rec) ~= "table" then return nil, "none" end
    local d = Flat(rec.data)
    local stride = tonumber(rec.stride) or 12
    if not d or stride < 12 or (tonumber(rec.version) or 1) > 2 then return nil, "unreadable" end
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
        local r, e
        if ok and s > 0 and abs(len - 1) <= UNIT_TOL then
            -- how far along n each turned axis runs: the reach is the half extents times these
            local xx, xy, xz, yx, yy, yz, zx, zy, zz = Turn(d[o + 5], d[o + 6], d[o + 7])
            local ax, ay, az = nx * xx + ny * xy + nz * xz, nx * yx + ny * yy + nz * yz, nx * zx + ny * zy + nz * zz
            local kind = p.kind or "cube"
            if kind == "cube" then
                local h = (tonumber(p.half) or 0.5) * s
                r, e = h * SQRT3, h * (abs(ax) + abs(ay) + abs(az))
            elseif kind == "quad" and QuadPrim(p) and ax >= QUAD_ALIGN * len then
                local hw, hh = p.w / 2 * s, p.h / 2 * s
                r, e = sqrt(hw * hw + hh * hh), hw * abs(ay) + hh * abs(az)
            end
        end
        if r then
            R[i], E[i] = r, e
            usable = usable + 1
        else
            R[i], E[i] = false, false
        end
    end
    if usable == 0 then return nil, "empty" end
    local set = { d = d, stride = stride, n = n, R = R, E = E, prims = prims, usable = usable, unsafe = unsafe }
    Regions(set)
    return set
end

-- The data of a room, as loaded (nil without).
local function Rec(key) return ns.RoomStandins and key and ns.RoomStandins[key] or nil end

-- The prepared set of a room (ns.RoomStandins[key]), made once per data table while it is in use (Ctl:Off lets it
-- go: ns.RoomStandins keeps every room's data, so a weak key alone would keep a set for every room visited). -> the
-- set and the data, or nil and why.
local CACHE = setmetatable({}, { __mode = "k" })
function S.Load(key)
    local rec = Rec(key)
    if type(rec) ~= "table" then return nil, "none" end
    -- (stand-ins are placed against one build of the room: a room file made again since - another payload size - may
    -- have moved a surface, and a stand-in left in front of it would hide models the room does not; until
    -- gen_standins.py runs again for it, none are shown)
    local floorRec = ns.RoomFloors and ns.RoomFloors[key]
    local made = type(rec.room) == "table" and tonumber(rec.room.size) or nil
    if not (made and floorRec and tonumber(floorRec.size) == made) then return nil, "stale" end
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
-- height, rb / w = its reach round them, sink = how much of it the record leaves out under its feet; room
-- coordinates) as a box, its eight corners projected (x0, y0, x1, y1); far = the depth of its farthest corner; the
-- box itself (bx, by its middle, br its half width, bz0 .. bz1, bh its half diagonal: a stand-in's surface must have
-- some of it behind its plane to hide any of it). A box through the near plane covers the whole view; one wholly
-- behind it is left out.
-- cam: x, y, z, fx, fy, fz (eye and unit view direction, room coordinates), near. proj(x, y, z) -> screen x, y (UI
-- units from the view's bottom-left), or nil. -> the count.
function S.ModelRects(occ, n, cam, proj, out)
    local ex, ey, ez, fx, fy, fz, near = cam.x, cam.y, cam.z, cam.fx, cam.fy, cam.fz, cam.near
    local m = 0
    for i = 1, n or 0 do
        local o = occ[i]
        local r = max(o.rb or 0, (o.w or 0) / 2, 0.25)
        -- (the board starts a part that dips under the floor on it, for its box mode: Magtheridon's feet reach 0.25
        -- yd under; here the floor in front of that is what hides it. A sink left on a reused record only makes
        -- the box bigger: more stand-ins, never fewer)
        local z0 = o.z - max(0, o.sink or 0)
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
            M.bx, M.by, M.br, M.bz0, M.bz1 = o.x, o.y, r, z0, z1
            M.bh = sqrt(2 * r * r + (z1 - z0) * (z1 - z0) / 4)
        end
    end
    return m
end

local SIZE = {}                  -- stand-in -> its radius on the screen this redraw (the budget's order)
local LIVE = {}                  -- the models a region can hide some of (S.Select; refilled per region)
local function Bigger(a, b)
    local sa, sb = SIZE[a], SIZE[b]
    if sa ~= sb then return sa > sb end
    return a < b                 -- (a steady order: the same stand-ins win from redraw to redraw)
end

-- The stand-ins to show, into out[1 .. count]: their surface faces the camera - the camera farther out along the
-- normal than the stand-in reaches, and farther than the near clip too: a nearer surface is clipped away while the
-- stand-in behind it still cuts the models -, some of them lies past the near plane and on the screen, and - unless
-- `all` - it can hide some of a model: over its rectangle, some of it nearer than the model's farthest corner, and
-- some corner of the model's box behind its surface's plane (seen from a camera in front of a surface, a point in
-- front of its plane is never behind it: the floor under a model's feet hides none of it). Over the budget the
-- biggest on the screen win. Whole regions (S.Prepare) go first, by the same tests on bounds that hold for each
-- stand-in in them: a floor under the models or a wall behind the camera is hundreds turned away at once.
-- cam: as S.ModelRects, plus w, h (the view, UI units) and k (px per yd at a depth of 1). st (optional): counts are
-- written into it (regions and stand-ins looked at one by one; of those, facing and in view; relevant: chosen before
-- the budget). -> the count.
function S.Select(set, cam, proj, models, nm, budget, out, all, st)
    local d, stride, R, E, G = set.d, set.stride, set.R, set.E, set.G
    local ex, ey, ez, fx, fy, fz = cam.x, cam.y, cam.z, cam.fx, cam.fy, cam.fz
    local near, w, h, k = cam.near, cam.w, cam.h, cam.k
    -- the farthest corner of any model: nothing past it can hide anything
    local ufar = -huge
    for m = 1, nm do
        local f = models[m].far
        if f > ufar then ufar = f end
    end
    local cnt, regions, examined, facing, inView = 0, 0, 0, 0, 0
    for g = 0, (set.ng - 1) * RS, RS do
        local Nx, Ny, Nz, cx, cy, cz = G[g + 3], G[g + 4], G[g + 5], G[g + 6], G[g + 7], G[g + 8]
        local rad, eps = G[g + 9], G[g + 10]
        local qx, qy, qz = cx - ex, cy - ey, cz - ez
        local dist = sqrt(qx * qx + qy * qy + qz * qz)
        local dep = qx * fx + qy * fy + qz * fz
        local gnear = dep - rad
        local nl, lfar = 0, -huge
        -- facing: none when the camera is the near clip or less out from each of their surfaces (lo: the one
        -- farthest back, less the normals' stray)
        local keep = Nx * ex + Ny * ey + Nz * ez - G[g + 12] + eps * (dist + rad) > near
            and dep + rad > near and (all or gnear < ufar)
        if keep then
            -- their ball on the screen, anywhere when it reaches through the near plane (the bound below holds off
            -- the middle of the view too: k * r * |v| / (dep * (dep - r)) reaches every point of the ball)
            local x0, y0, x1, y1 = -huge, -huge, huge, huge
            if gnear > near then
                local sx, sy = proj(cx, cy, cz)
                if sx then
                    local rp = k * rad * dist / (dep * gnear)
                    x0, y0, x1, y1 = sx - rp, sy - rp, sx + rp, sy + rp
                end
            end
            keep = x1 >= 0 and x0 <= w and y1 >= 0 and y0 <= h
            if keep and not all then
                -- the models some stand-in of theirs could hide: over the rectangle, nearer than the far corner,
                -- some of the box behind the farthest of their planes (less the normals' stray over the distance)
                local hi = G[g + 11]
                local ax, ay = Nx < 0 and -Nx or Nx, Ny < 0 and -Ny or Ny
                for m = 1, nm do
                    local M = models[m]
                    if gnear < M.far and x1 >= M.x0 and x0 <= M.x1 and y1 >= M.y0 and y0 <= M.y1 then
                        local lb = Nx * M.bx + Ny * M.by - M.br * (ax + ay)
                            + (Nz >= 0 and Nz * M.bz0 or Nz * M.bz1) - hi
                        if eps > 0 then
                            local bx, by, bz = M.bx - cx, M.by - cy, (M.bz0 + M.bz1) / 2 - cz
                            lb = lb - eps * (sqrt(bx * bx + by * by + bz * bz) + M.bh + rad)
                        end
                        if lb <= 0 then
                            nl = nl + 1
                            LIVE[nl] = M
                            if M.far > lfar then lfar = M.far end
                        end
                    end
                end
                keep = nl > 0
            end
        end
        if keep then
            regions = regions + 1
            for i = G[g + 1], G[g + 2] do
                local r = R[i]
                if r then
                    examined = examined + 1
                    local o = (i - 1) * stride
                    local px, py, pz = d[o + 2], d[o + 3], d[o + 4]
                    local nx, ny, nz = d[o + 9], d[o + 10], d[o + 11]
                    local vx, vy, vz = ex - px, ey - py, ez - pz
                    if vx * nx + vy * ny + vz * nz > E[i] + near then
                        facing = facing + 1
                        local sdep = -(vx * fx + vy * fy + vz * fz)
                        if sdep + r > near then
                            local through = sdep - r <= near
                            local nearest = through and near or sdep - r
                            -- can it hide some of a model at all (depth and its plane): asked before projecting it
                            local any, pe, ax, ay = all, 0, 0, 0
                            if not all and nearest < lfar then
                                pe = nx * px + ny * py + nz * pz + E[i]
                                ax, ay = nx < 0 and -nx or nx, ny < 0 and -ny or ny
                                for q = 1, nl do
                                    local M = LIVE[q]
                                    if nearest < M.far and nx * M.bx + ny * M.by - M.br * (ax + ay)
                                        + (nz >= 0 and nz * M.bz0 or nz * M.bz1) <= pe then
                                        any = true
                                        break
                                    end
                                end
                            end
                            if any then
                                local x0, y0, x1, y1, size
                                if through then
                                    -- through the near plane: anywhere on the screen
                                    x0, y0, x1, y1, size = -huge, -huge, huge, huge, huge
                                else
                                    local sx, sy = proj(px, py, pz)
                                    if sx then
                                        local rp = k * r * sqrt(vx * vx + vy * vy + vz * vz) / (sdep * nearest)
                                        x0, y0, x1, y1, size = sx - rp, sy - rp, sx + rp, sy + rp, rp
                                    end
                                end
                                if x0 and x1 >= 0 and x0 <= w and y1 >= 0 and y0 <= h then
                                    inView = inView + 1
                                    local hit = all
                                    if not hit then
                                        for q = 1, nl do
                                            local M = LIVE[q]
                                            if nearest < M.far and x1 >= M.x0 and x0 <= M.x1 and y1 >= M.y0
                                                and y0 <= M.y1 and nx * M.bx + ny * M.by - M.br * (ax + ay)
                                                + (nz >= 0 and nz * M.bz0 or nz * M.bz1) <= pe then
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
    if st then
        st.regions, st.examined, st.facing, st.inView, st.relevant = regions, examined, facing, inView, relevant
    end
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
                             stats = { shown = 0, placed = 0, skipped = 0, regions = 0, examined = 0, facing = 0,
                                       inView = 0, relevant = 0 } },
                           Ctl)
    view.standinCtl = c
    return c
end

-- Stand in for room `key` (as the room files are named). -> true when it has stand-ins; else nothing is shown, and
-- why ("none": no data for this room, "stale": made for another build of the room, "unreadable", "empty": none that
-- can be shown).
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
    -- (the room's prepared set goes too: made again, in a few ms, when the mode or the room comes back)
    if self.rec then CACHE[self.rec] = nil end
    self.key, self.set, self.rec, self.sig.n = nil, nil, nil, nil
    self.stats.shown = 0
    self.view:StandinLayer(false)
end

-- cfg: budget (stand-ins at most), all (debug: every one facing the camera and in view, not only those over a
-- model), debug (the cubes drawn over the room, see-through), flag (SetAllowOverlappedModels on the stand-in scene,
-- the caller's default on). The flag clears the whole screen's shared depth buffer just before a flagged scene draws,
-- when it draws anything (solo probe tiles 21, 22, 44-46, 2026-10-05): on the lowest scene of the board it wipes
-- the depth other addons' or Blizzard's model frames left earlier in the frame, and the stand-ins then write the
-- room's. The creature scenes keep it off: they must test against that depth. In debug the scene draws over the
-- creatures, where a clear would wipe their depth too, so the flag is off there.
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
    local flag = (cfg.flag and not debug) and true or false
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
-- y times the mirror m; the client multiplies the position by the scale). The mirror F (y times m) is a reflection,
-- not a turn: the room's stand-in F (anchor + s R (q - c)) is drawn by the actor turned by F R F - R with yaw and roll
-- times m, pitch kept (F turns a turn about z or x the other way and keeps one about y, in any order) - with the
-- prim's middle c reflected too: the model's origin goes to F (anchor - s R (cx, m cy, cz)). A cube, or a quad about
-- its middle, is symmetric under that reflection of its model, so the actor covers exactly the reflected stand-in;
-- and a quad's front (its model x, which the reflection keeps) turns to F n, the reflected normal - the side the
-- reflected camera stands on - so the one-sided quad is drawn to the same cameras in the scene as in the room.
function Ctl:Place(a, i)
    local set = self.set
    local d, o = set.d, (i - 1) * set.stride
    local p = set.prims[d[o + 1]]
    local fid = p.fid
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
    local x, y, z = d[o + 2], d[o + 3], d[o + 4]
    local cx, cy, cz = tonumber(p.cx) or 0, m * (tonumber(p.cy) or 0), tonumber(p.cz) or 0
    if cx ~= 0 or cy ~= 0 or cz ~= 0 then
        local xx, xy, xz, yx, yy, yz, zx, zy, zz = Turn(d[o + 5], d[o + 6], d[o + 7])
        x = x - s * (cx * xx + cy * yx + cz * zx)
        y = y - s * (cx * xy + cy * yy + cz * zy)
        z = z - s * (cx * xz + cy * yz + cz * zz)
    end
    pcall(a.SetPosition, a, x / s, m * y / s, z / s)
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

-- What the stand-ins do: the room's count and how many can be shown, the last selection's counts (S.Select: regions
-- and stand-ins looked at, facing, in view, relevant), actors made, actors placed so far and redraws that needed no
-- selection.
function Ctl:Stats()
    local st, set = self.stats, self.set
    return { key = self.key, total = set and set.n or 0, usable = set and set.usable or 0,
             unsafe = set and set.unsafe or 0, nRegions = set and set.ng or 0, regions = st.regions,
             examined = st.examined, facing = st.facing, inView = st.inView, relevant = st.relevant,
             shown = set and st.shown or 0, actors = #self.pool, placed = st.placed, skipped = st.skipped,
             budget = self.budget, debug = self.debug, all = self.all, flag = self.flag }
end
