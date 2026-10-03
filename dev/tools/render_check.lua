-- tools/render_check.lua: the capture side of tools/render_check.py, loaded into a harness client (wowmock).
-- It reads what the mock recorded about the Raid Trainer's 3D view - its frames, textures, lines, the
-- ModelScene with its camera and actors - and hands it to Python as text, one record per line:
--   C  the ModelScene camera: position, yaw / pitch / roll (nan = never set), field of view, near clip, the
--      scene's rectangle in the view, its width / height / effective scale, and the trainer's cam.mirror
--   F  a frame:  index, parent index, level, strata, clips children, visible, kind (1 frame, 2 ModelScene),
--      creation order, rectangle (left, bottom, width, height in view units; nan = unresolved)
--   R  a shown texture or line: kind (1 texture, 2 line), creation order, frame index, draw layer, sublevel,
--      texture (file ID; -1 colour texture; -2 another file; -3 none), vertex colour (4), texture coordinates
--      (UL, LL, UR, LR: 8), rectangle (4; for a line its start x, y and end x, y), vertex offsets (UL, LL, UR,
--      LR: 8), line thickness, colour of a colour texture (4), alpha down the parent chain
--   A  a shown ModelScene actor: index, unit id (-1: an effect), position (scene units, scale multiplied in),
--      scale, alpha, body height and width (yards), kind (1 unit, 2 effect)
--   P  the player: x, y, facing (arena coordinates)
-- Only widget state the client itself would have is read (anchors, sizes, offsets, coordinates, layers,
-- levels, shown state, the actors' positions); the renderer's own tables are not looked at. The body sizes come
-- from the sim's units (u.plate / u.tall, else the trainer's PLATE_HEIGHT, else 2.6 yd).
local M = __MOCK
local OBJ = M.OBJ
local fmt, max, min = string.format, math.max, math.min
local RC = {}
__RC = RC

local LAYER = { BACKGROUND = 0, BORDER = 1, ARTWORK = 2, OVERLAY = 3, HIGHLIGHT = 4 }
local STRATA = { WORLD = 0, BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6,
                 FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
local PLATE = { construct = 3.2, boss = 7 }

local function num(v, full)
    if type(v) ~= "number" or v ~= v then return "nan" end
    if v == math.huge then return "inf" end
    if v == -math.huge then return "-inf" end
    return fmt(full and "%.17g" or "%.9g", v)
end
local function exact(v) return num(v, true) end         -- (the camera and the actors: every bit)

local function strata(st)
    while st do
        local s = st.strata
        if s and STRATA[s] then return STRATA[s] end
        st = st.parent and OBJ[st.parent]
    end
    return STRATA.MEDIUM
end

local function chain_alpha(st)
    local a = 1
    while st do
        a = a * (st.alpha or 1)
        st = st.parent and OBJ[st.parent]
    end
    return a
end

local function texcode(t)
    if type(t) == "number" then return t end
    if t == "Color" then return -1 end
    if t == nil then return -3 end
    local n = tonumber(t)
    if n then return n end
    return -2
end

local DEFAULT_TC = { 0, 0, 0, 1, 1, 0, 1, 1 }
local function texcoords(st)
    local c = st.texcoord
    if c and #c >= 8 then return c end
    if c and #c >= 4 then return { c[1], c[3], c[1], c[4], c[2], c[3], c[2], c[4] } end
    return DEFAULT_TC
end

-- The view's frames and the shown textures / lines in it, the ModelScene's camera and actors.
function RC.capture(view, scene, mirror)
    local out, n = {}, 0
    local function add(s) n = n + 1 out[n] = s end
    local memo = {}
    -- the camera
    local sst = OBJ[scene]
    local cp = sst.camPos or { 0, 0, 0 }
    local o = sst.camYPR
    local sl, sb, sw, sh = M.region_rect(scene, view, memo)
    add(fmt("C %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s", exact(cp[1]), exact(cp[2]), exact(cp[3]),
        exact(o and tonumber(o[1])), exact(o and (tonumber(o[2]) or 0)), exact(o and (tonumber(o[3]) or 0)),
        exact(sst.fov or 0.9), exact(sst.near or 0), exact(sl), exact(sb), exact(sw), exact(sh),
        exact(scene:GetWidth()), exact(scene:GetHeight()), exact(scene:GetEffectiveScale()), exact(mirror or 1)))
    -- frames and regions, depth first from the view
    local nf = 0
    local function walk(f, parentIdx, visible)
        local st = OBJ[f]
        visible = visible and st.shown
        nf = nf + 1
        local me = nf
        local l, b, w, h = M.region_rect(f, view, memo)
        add(fmt("F %d %d %d %d %d %d %d %d %s %s %s %s", me, parentIdx, st.level or 0, strata(st),
            st.clips and 1 or 0, visible and 1 or 0, st.kind == "ModelScene" and 2 or 1, st.seq,
            num(l), num(b), num(w), num(h)))
        for _, ch in ipairs(st.children) do
            local cs = OBJ[ch]
            if cs and cs.parent == f then
                if cs.is_frame then
                    walk(ch, me, visible)
                elseif visible and cs.shown and (cs.kind == "Texture" or cs.kind == "Line") then
                    local kind = cs.kind == "Line" and 2 or 1
                    local x1, y1, x2, y2
                    if kind == 2 then
                        x1, y1, x2, y2 = M.line_points(ch, view, memo)
                    else
                        x1, y1, x2, y2 = M.region_rect(ch, view, memo)
                    end
                    local vc = cs.vcolor or { 1, 1, 1, 1 }
                    local tc = texcoords(cs)
                    local vo = cs.voff or {}
                    local function off(i, k) return vo[i] and vo[i][k] or 0 end
                    local col = cs.color or { 1, 1, 1, 1 }
                    add(fmt("R %d %d %d %d %d %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s "
                            .. "%s %s %s %s %s %s %s %s %s %s %s %s %s %s",
                        kind, cs.seq, me, LAYER[cs.layer or "ARTWORK"] or 2, cs.sublayer or 0, num(texcode(cs.texture)),
                        num(vc[1]), num(vc[2]), num(vc[3]), num(vc[4] or 1),
                        num(tc[1]), num(tc[2]), num(tc[3]), num(tc[4]), num(tc[5]), num(tc[6]), num(tc[7]), num(tc[8]),
                        num(x1), num(y1), num(x2), num(y2),
                        num(off(1, 1)), num(off(1, 2)), num(off(2, 1)), num(off(2, 2)),
                        num(off(3, 1)), num(off(3, 2)), num(off(4, 1)), num(off(4, 2)),
                        num(cs.thickness or 1), num(col[1] or 1), num(col[2] or 1), num(col[3] or 1), num(col[4] or 1),
                        num(chain_alpha(cs))))
                end
            end
        end
    end
    walk(view, 0, true)
    -- the actors, with the body size of the unit each one shows
    local sim = ns.TrainerUI._Sim()
    local units = {}
    if sim then
        for _, u in ipairs(sim.units) do
            local a = ns.TrainerUI._Actor(u.id)
            if a then units[a] = u end
        end
        local p = sim.player
        add(fmt("P %s %s %s", exact(p.x), exact(p.y), exact(p.facing)))
    end
    for i, a in ipairs(sst.actors or {}) do
        if a.shown then
            local u = units[a]
            local s = a.scale or 1
            local pos = a.pos or { 0, 0, 0 }
            local height, width, uid, kind = 0, 0, -1, 2
            if u then
                height = u.plate or u.tall or PLATE[u.kind] or 2.6
                width = max(1.2, min(2 * (u.radius or 0.6), 0.6 * height))
                uid, kind = u.id, 1
            end
            add(fmt("A %d %d %s %s %s %s %s %s %s %d", i, uid, exact(pos[1] * s), exact(pos[2] * s), exact(pos[3] * s),
                exact(s), num(a.alpha or 1), num(height), num(width), kind))
        end
    end
    return table.concat(out, "\n")
end

-- The trainer's view as it stands (UI._View: the view frame and its ModelScene; UI._Camera: cam.mirror, the
-- one number that says how the arena maps onto the scene, the same mapping the actors are placed with).
function RC.capture_trainer()
    local view, scene = ns.TrainerUI._View()
    return RC.capture(view, scene, ns.TrainerUI._Camera().mirror)
end

-- An encounter's room mesh as text: "verts|tris|textures" (x y z u v light per vertex; a b c texture per
-- triangle, 1-based; texture file IDs).
function RC.mesh(encId)
    local m = ns.Trainer:GetEncounter(encId).arena.mesh
    local v, t, x = {}, {}, {}
    for i = 1, #m.verts do v[i] = fmt("%.10g", m.verts[i]) end
    for i = 1, #m.tris do t[i] = tostring(m.tris[i]) end
    for i = 1, #m.textures do x[i] = tostring(m.textures[i]) end
    return table.concat(v, " ") .. "|" .. table.concat(t, " ") .. "|" .. table.concat(x, " ")
end

-- Put the player (and the camera behind him) somewhere: arena x, y, facing (radians, 0 = east), the camera's
-- pitch and distance - what mouse look and the wheel would set.
function RC.pose(x, y, facing, pitch, dist)
    local s, cam = ns.TrainerUI._Sim(), ns.TrainerUI._Camera()
    s.player.x, s.player.y, s.player.facing = x, y, facing
    cam.pitch, cam.dist = pitch, dist
end

-- API calls of one panel frame: counting on, the tick, counting off -> "Name=count ..." (methods looked up on
-- widgets; the actors are plain tables and are not counted).
function RC.counted_tick(dt)
    local counts = {}
    M.set_api_count(counts)
    local ok, err = pcall(ns.TrainerUI._Tick, dt)
    M.set_api_count(nil)
    if not ok then error(err, 0) end
    local parts = {}
    for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return table.concat(parts, " ")
end

-- Several points through the mock's own Project3DPointTo2D (to check the Python projection against it):
-- pts = "x y z x y z ..." in scene units -> "sx sy d ..." (nan when behind the camera).
function RC.project(scene, pts)
    local res = {}
    local v = {}
    for w in pts:gmatch("%S+") do v[#v + 1] = tonumber(w) end
    for i = 1, #v, 3 do
        local sx, sy, d = scene:Project3DPointTo2D(v[i], v[i + 1], v[i + 2])
        res[#res + 1] = exact(sx) .. " " .. exact(sy) .. " " .. exact(d)
    end
    return table.concat(res, " ")
end
