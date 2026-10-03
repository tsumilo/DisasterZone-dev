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
--   H  the trainer's optional test hooks that exist (UI._Render, _RenderOpts, _Marks, _Order, _Occluders)
--   T  (only with UI._Render) the renderer's screen-error bound tau and the corner dilation in px: the
--      tolerance render_check matches regions with (1 + tau + dilate), never anything the painter uses
--   M  (only with UI._Marks) one 3D mark segment the renderer drew: x1 y1 z1 x2 y2 z2 thickness (arena),
--      for the line truth
-- Only widget state the client itself would have is read (anchors, sizes, offsets, coordinates, layers,
-- levels, shown state, the actors' positions) for the painter; the renderer's own tables are not looked at. The
-- body sizes come from the sim's units (u.plate / u.tall, else the trainer's PLATE_HEIGHT, else 2.6 yd).
local M = __MOCK
local OBJ = M.OBJ
local fmt, max, min = string.format, math.max, math.min
local RC = {}
__RC = RC
RC.opts = {}             -- what render_check has set through UI._RenderOpts (merged)

local HOOKS = { "_Render", "_RenderOpts", "_Marks", "_Order", "_Occluders" }
local function hook(name)
    local UI = ns.TrainerUI
    local f = UI and rawget(UI, name)
    if f == nil and UI then f = UI[name] end
    return type(f) == "function" and f or nil
end
RC.hook = hook

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
    -- the optional hooks: which exist, the match tolerance's tau, the 3D mark segments
    local have = {}
    for _, h in ipairs(HOOKS) do if hook(h) then have[#have + 1] = h end end
    add("H " .. table.concat(have, " "))
    local st = hook("_Render") and hook("_Render")()
    if type(st) == "table" and type(st.tau) == "number" then
        local dil = tonumber(st.dilate) or tonumber(RC.opts.dilate) or 0
        add(fmt("T %s %s", exact(st.tau), exact(dil)))
    end
    local marks = hook("_Marks") and hook("_Marks")()
    if type(marks) == "table" then
        for _, sg in ipairs(marks) do
            add(fmt("M %s %s %s %s %s %s %s", exact(sg[1]), exact(sg[2]), exact(sg[3]), exact(sg[4]), exact(sg[5]),
                exact(sg[6]), num(sg[7] or 1)))
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

-- An encounter's room mesh as text: "verts|tris|textures|nodeOf|pair" (x y z u v light per vertex; a b c texture
-- per triangle, 1-based; texture file IDs; the BSP node each triangle belongs to, 1-based, 0 = none; each
-- triangle's quad mate from the data format v2 pair list, 1-based, 0 = none: the renderer draws the two as one
-- texture).
function RC.mesh(encId)
    local m = ns.Trainer:GetEncounter(encId).arena.mesh
    local v, t, x, no, pr = {}, {}, {}, {}, {}
    for i = 1, #m.verts do v[i] = fmt("%.10g", m.verts[i]) end
    for i = 1, #m.tris do t[i] = tostring(m.tris[i]) end
    for i = 1, #m.textures do x[i] = tostring(m.textures[i]) end
    local nt = math.floor(#m.tris / 4)
    for i = 1, nt do no[i] = 0 end
    local nodes = m.nodes or {}
    for k = 1, math.floor(#nodes / 8) do
        local first, count = nodes[k * 8 - 1], nodes[k * 8]
        for i = first, first + count - 1 do if i >= 1 and i <= nt then no[i] = k end end
    end
    local pair = (m.version == 2 and type(m.pair) == "table") and m.pair or {}
    for i = 1, nt do
        no[i] = tostring(no[i])
        pr[i] = tostring(tonumber(pair[i]) or 0)
    end
    return table.concat(v, " ") .. "|" .. table.concat(t, " ") .. "|" .. table.concat(x, " ") .. "|"
        .. table.concat(no, " ") .. "|" .. table.concat(pr, " ")
end

-- Which optional test hooks the trainer has: "name name ...".
function RC.hooks()
    local have = {}
    for _, h in ipairs(HOOKS) do if hook(h) then have[#have + 1] = h end end
    return table.concat(have, " ")
end

-- Render options through UI._RenderOpts (merged into Room.opts by the renderer). -> false without the hook.
function RC.set_opts(t)
    local f = hook("_RenderOpts")
    if not f then return false end
    for k, v in pairs(t) do RC.opts[k] = v end
    f(t)
    return true
end

-- The renderer's own reports (nil without the hook).
function RC.render_stats() local f = hook("_Render") return f and f() or nil end
function RC.order() local f = hook("_Order") return f and f() or nil end
function RC.occluders() local f = hook("_Occluders") return f and f() or nil end
function RC.marks() local f = hook("_Marks") return f and f() or nil end

-- The order invariants (spec 9.2.13), only when UI._Order has the v2 fields (frames, levels, lines as
-- { frame, pos }): "nodes distinct wrong badLines lines pieces" - badLines = shown mark lines neither on an odd
-- position nor in the bottom line frame (reported as frame 0). nil for the v1 renderer.
function RC.order_summary()
    local o = RC.order()
    if type(o) ~= "table" or o.frames == nil or o.levels == nil then return nil end
    local bad, n = 0, 0
    for _, l in ipairs(o.lines or {}) do
        n = n + 1
        local fr, pos = l.frame or l[1], l.pos or l[2]
        local bottom = fr == 0 or fr == "bottom" or l.bottom == true
        if not bottom and not (type(pos) == "number" and pos % 2 == 1) then bad = bad + 1 end
    end
    return fmt("%d %d %d %d %d %d", tonumber(o.nodes) or -1, tonumber(o.distinct) or -1, tonumber(o.wrong) or -1,
        bad, n, tonumber(o.pieces) or -1)
end

-- Put the index-th living unit of a kind ("raider", "boss", ...) at x, y and let it stand there. -> its unit id.
function RC.place_unit(kind, index, x, y)
    local s = ns.TrainerUI._Sim()
    local u = s and s:Alive(kind)[index]
    if not u then return nil end
    u.x, u.y, u.goal = x, y, nil
    return u.id
end

-- Remember where every unit stands (and where it was going), to put them back after a pose moved some.
function RC.save_units()
    local s, t = ns.TrainerUI._Sim(), {}
    for _, u in ipairs(s.units) do t[u] = { u.x, u.y, u.goal, u.facing } end
    RC.saved = t
end
function RC.restore_units()
    for u, v in pairs(RC.saved or {}) do u.x, u.y, u.goal, u.facing = v[1], v[2], v[3], v[4] end
    RC.saved = nil
end

-- A floor mark of render_check's own (a ring of radius r at x, y with a column of that height), kept in sim.marks
-- even when the encounter rewrites the list every step.
RC.extraMarks = {}
local function keep_marks(sim)
    if #RC.extraMarks == 0 then return end
    local marks = sim.marks
    if type(marks) ~= "table" then marks = {} sim.marks = marks end
    for _, mk in ipairs(RC.extraMarks) do
        local found = false
        for _, o in ipairs(marks) do if o == mk then found = true break end end
        if not found then marks[#marks + 1] = mk end
    end
end
function RC.add_mark(x, y, r, column)
    local s = ns.TrainerUI._Sim()
    local mk = { x = x, y = y, r = r, column = column, color = { 1, 0.85, 0.1 } }
    RC.extraMarks[#RC.extraMarks + 1] = mk
    if not rawget(s, "__rcUpdate") then
        local base = s.Update
        s.__rcUpdate = true
        s.Update = function(self, dt)
            local a, b = base(self, dt)
            keep_marks(self)
            return a, b
        end
    end
    keep_marks(s)
    return #RC.extraMarks
end
function RC.clear_marks()
    local s = ns.TrainerUI._Sim()
    local gone = {}
    for _, mk in ipairs(RC.extraMarks) do gone[mk] = true end
    if s and type(s.marks) == "table" then
        for i = #s.marks, 1, -1 do if gone[s.marks[i]] then table.remove(s.marks, i) end end
    end
    RC.extraMarks = {}
end

-- The camera as the trainer placed it: scene position, forward, mirror and the distance actually used.
function RC.camera()
    local c = ns.TrainerUI._Camera()
    return { c.x, c.y, c.z, c.fx, c.fy, c.fz, c.mirror or 1, c.cur or c.dist, c.dist, c.pitch }
end

-- One panel tick without counting (the bench); the mock's setters may be no-ops then (M.null_setters).
function RC.null_setters(on) return M.null_setters(on) end

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
