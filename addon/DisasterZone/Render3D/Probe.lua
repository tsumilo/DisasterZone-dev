if DisasterZoneBoot and DisasterZoneBoot.Run("Render3D/Probe.lua", ...) then return end -- DisasterZone Render3D/Probe.lua
-- ns.Render3D.Probe: "/dz 3d probe" (UI/StrategyMap3D.lua hands it on). One in-game session that answers the open
-- questions about how this client draws models, before the 3D board's depth design is chosen (dev/docs/
-- DEPTH_RESEARCH.md, "Final recommendation", panels 0-9). A window of pages of numbered tiles, each a small ModelScene
-- experiment whose caption says what should show - the user screenshots every page - while what can be measured goes
-- to DisasterZoneDB.probe3d.results, with a short summary in the chat.
--
-- Round 3 (2026-10-05): every scene shares one depth buffer, and a scene with SetAllowOverlappedModels(true) seemed to
-- clear it for the other tiles of its page. So the flag and alpha pages start in solo: the bar under the page steps
-- through their tiles and only the chosen tile's scenes are shown (every other scene of the probe hidden). Page 6
-- shows the stock models dev/generators/find_flat_prims.py found as flat or box stand-ins; it is built (its models
-- loaded) only when its tab is opened, so a crash there is pinned on that page and every other page stays usable.
--
-- The crash guard: a malformed loose .m2 may crash the client, and saved variables reach the disk only on a reload or
-- a logout. "/dz 3d probe" saves probe3d.pending = "armed" and reloads; that reload (PLAYER_ENTERING_WORLD says it is
-- one) runs the probe with pending = "running" in memory only - the disk keeps "armed" - and clears the flag when the
-- run is over; one more /reload saves the results. A login that finds the flag any other way (a fresh start after a
-- crash, a reload in the middle of a run) records that the run never finished and loads nothing loose by itself.
-- "/dz 3d probe safe" runs everything but the loose files at once, without the guard.
--
-- Only documented 2.5.6 methods, every model call through pcall. Nothing is made before the probe runs: unused, it
-- costs one look at the saved data on entering the world.
local _, ns = ...

local R3 = ns.Render3D or {}
ns.Render3D = R3
local P = {}
R3.Probe = P

local type, pairs, ipairs, tostring, tonumber, pcall, xpcall, select, unpack = type, pairs, ipairs, tostring, tonumber,
    pcall, xpcall, select, unpack
local format, tconcat, tsort, tinsert, tremove = string.format, table.concat, table.sort, table.insert, table.remove
local cos, sin, sqrt, atan2, rad, floor, abs, max, min = math.cos, math.sin, math.sqrt, math.atan2, math.rad,
    math.floor, math.abs, math.max, math.min
local PI, HUGE = math.pi, math.huge

local DIR = "Interface\\AddOns\\DisasterZone\\Media\\Probe\\"
local CUBE = 167145           -- spells/unitcube.m2: a centred, opaque 1 yd cube (checked in the 2.5.6 files)
local BRUTALLUS = 22711       -- strong particle glows (they lit up every depth slice)
local WHITE = "Interface\\Buttons\\WHITE8X8"
local ARM_TTL = 600           -- seconds an armed probe waits for its reload; later it counts as not finished
-- Every scene of the probe has the same lens and clip range: depth compares between scenes only with equal clips.
local NEAR, FAR, FOV = 0.2, 300, 0.9

-- The test models (Media/Probe/manifest.txt says what each one is). box = where its geometry should be, in model
-- units (= yards): min x, y, z, max x, y, z. key = its name for "/dz 3d probe only <key>".
local LOOSE = {
    { key = "copy", file = "probe_copy.m2", box = { -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 } },
    { key = "md21", file = "probe_box_md21.m2", box = { 0, 0, 0, 3, 1, 2 } },
    { key = "noskin", file = "probe_box_noskin.m2", skin = "probe_box_noskin00.skin", box = { 0, 0, 0, 3, 1, 2 } },
    { key = "md20", file = "probe_box_md20.m2", skin = "probe_box_md2000.skin", box = { 0, 0, 0, 3, 1, 2 } },
    { key = "checker", file = "probe_checker.m2", box = { 0, 0, 0, 4, 4, 0 } },
    { key = "depth", file = "probe_depth.m2", box = { 0, 0, 0, 4, 4, 0 } },
}
-- "only frames": the two frame types panel 0 asks CreateFrame for, which the addon never makes otherwise. Made only in
-- a guarded run with every loose file or alone, so a crash there is never blamed on a loose file by the bisect.
local FRAMES = "frames"
local LOOSE_BY, KEYS = {}, {}
for _, L in ipairs(LOOSE) do
    LOOSE_BY[L.key] = L
    KEYS[#KEYS + 1] = L.key
end
KEYS[#KEYS + 1] = FRAMES
KEYS = tconcat(KEYS, "/")               -- (not "|": the chat reads that as an escape)
local KEY_ORDER = { "control", "copy", "md21", "noskin", "md20", "checker", "depth" }

-- A key "/dz 3d probe only" takes, or nil.
local function OnlyKey(key)
    if key == FRAMES or LOOSE_BY[key or ""] then return key end
    return nil
end

local function OnlyName(key)
    if key == FRAMES then return "the OffScreenFrame and UiCamera frames" end
    return LOOSE_BY[key] and LOOSE_BY[key].file or tostring(key)
end
local CUBE_BOX = { -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 }
local ORIGIN = { 0, 0, 0 }

-- Stand-in candidates (page 6): stock models that passed dev/generators/find_flat_prims.py on build 2.5.6.69795 -
-- opaque (one alpha-keyed for comparison), depth test and write on, no billboard or moving bone, header box on the
-- mesh, 4 vertices (flat) or one box. Each ID was read from the installed client and starts with 'MD21': an ID that is
-- not a model can crash the client in SetModelByFileID (WoWUIBugs #67), so only IDs from that report go here (the
-- probe's test checks them against the client's files). Two are kept as controls although the scan refuses them:
-- 198110 (its header box) and 200893 (a projected-texture batch, refused since it was picked). box = the drawn mesh
-- in model units (min x, y, z, max x, y, z; a flat one has no thickness on one axis).
local ROOF = { fid = 198111, box = { -44.8464, -54.5491, 17.0593, 44.8431, 54.5731, 17.0593 } }   -- two-sided
local ROOF_HDR = { fid = 198110, box = ROOF.box }          -- the same quad, its header box reaching down to z 0
local CATA = { fid = 653518, box = { -4.0358, -23.5964, 1.7645, -4.0358, 25.3344, 34.7498 } }  -- one-sided, faces +x
local LEGION = { fid = 1396283, box = { -7.0473, -29.9331, -1.789, -7.0473, 33.8957, 31.1963 } }   -- faces +x
local BLANKET = { fid = 200893, box = { -0.5851, -0.8307, 0.048, 0.6258, 0.852, 0.048 } }    -- alpha key, faces +z
local SCALE100 = { fid = 219357, box = { -1.3889, -1.3889, 0, 1.3889, 1.3889, 2.7778 } }      -- one-sided box
local ELEVATOR = { fid = 203154, box = { -1.9699, -1.9699, -0.3058, 1.9699, 1.9699, 0.3058 } }   -- a slab
local PRIM_SPAN = 2.4                                       -- yd: a candidate's longest side in its tile

local YELLOW, RED, GREEN, BLUE = { 1, 0.85, 0.1 }, { 1, 0.25, 0.25 }, { 0.25, 1, 0.3 }, { 0.35, 0.55, 1 }
local CYAN, PINK, TEAL = { 0.2, 0.95, 0.95 }, { 1, 0.4, 0.95 }, { 0.16, 0.34, 0.38 }

-- Tile grid: 4 columns, 3 rows a page; a tile is its scene area, a caption under it and a grey line of values. Under
-- the page: the solo bar (one tile at a time, with the chosen tile's full explanation) and the status line.
local TW, GAP, SCENE_H, CAP_H, DATA_H = 222, 10, 108, 40, 12
local ROW_H = SCENE_H + CAP_H + DATA_H + 8
local BAR_H = 66                  -- (three lines of explanation under the buttons)
local WIN_W, WIN_H = 4 * TW + 3 * GAP + 40, 3 * ROW_H + 80 + BAR_H

P.pitchSign = 1               -- Blizzard's orbit camera: a positive pitch looks down (checked again by Calibrate)
P.signs = 1                   -- tile 38's sign set (Signs; 1 = all +, what tiles 35-37 showed in game)
P.order = 0                   -- tile 38's rotation order shown (0 = all of ORDERS)
P.solo = {}                   -- page -> the tile shown alone (its index on the page), or false: every tile
local PAGE_OF = {}            -- page key -> its index (filled with PAGES)

---------------------------------------------------------------------------
-- Saved state (DisasterZoneDB.probe3d)
---------------------------------------------------------------------------

local function State()
    local db = ns.db
    return db and type(db.probe3d) == "table" and db.probe3d or nil
end

local function NewState()
    local db = ns.db
    if not db then return nil end
    if type(db.probe3d) ~= "table" then db.probe3d = {} end
    return db.probe3d
end

-- The last ten runs, finished or not.
local function History(st, entry)
    if type(st.history) ~= "table" then st.history = {} end
    tinsert(st.history, entry)
    while #st.history > 10 do tremove(st.history, 1) end
end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

-- A NaN or an infinity must never reach the saved variables: the client may write one as -nan(ind) or 1.#INF,
-- which the next login cannot read, and then the whole DisasterZoneDB file is lost. The probe's misread test models
-- are exactly where the client might answer with one.
local function Finite(v)
    return v == v and v ~= HUGE and v ~= -HUGE
end

-- (a number that is not finite comes back as its text)
local function Round(v, n)
    if type(v) ~= "number" then return v end
    if not Finite(v) then return tostring(v) end
    local k = 10 ^ (n or 3)
    return floor(v * k + 0.5) / k
end

local function Short(v)
    return tostring(v):sub(1, 120)
end

-- A value for the saved results: nil is written as "nil" (an absent key would read as "not asked").
local function Val(v)
    if v == nil then return "nil" end
    if type(v) == "number" then return Round(v, 4) end
    if type(v) == "boolean" or type(v) == "string" then return v end
    return Short(v)
end

local function Pack(...) return { n = select("#", ...), ... } end

-- What a pcall answered, for the saved results (not "ok and v or ...": a false answer would read as an error).
local function Answer(ok, v)
    if ok then return Val(v) end
    return "error: " .. Short(v)
end

-- An actor's box (GetActiveBoundingBox / GetMaxBoundingBox: six numbers in practice, two vectors by the docs) as
-- { min x, y, z, max x, y, z }, or nil. A box with a number that is not finite is nil too, its numbers as text the
-- second answer (kept apart: the box readers format every corner as a number).
local function BoxOf(a, name)
    local f = a and a[name]
    if type(f) ~= "function" then return nil end
    local r = Pack(pcall(f, a))
    if not r[1] then return nil end
    local out = {}
    for i = 2, r.n do
        local v = r[i]
        if type(v) == "number" then
            out[#out + 1] = v
        elseif type(v) == "table" then
            local ok, x, y, z = pcall(function() if v.GetXYZ then return v:GetXYZ() end return v.x, v.y, v.z end)
            if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
                out[#out + 1], out[#out + 2], out[#out + 3] = x, y, z
            end
        end
    end
    if #out == 0 then return nil end
    local bad = false
    for _, v in ipairs(out) do
        if not Finite(v) then bad = true end
    end
    if bad then
        local txt = {}
        for i, v in ipairs(out) do txt[i] = tostring(v) end
        return nil, tconcat(txt, " ")
    end
    for i, v in ipairs(out) do out[i] = Round(v, 3) end
    return out
end

-- A value as text, "-" for nothing (a false answer stays "false").
local function Txt(v)
    if v == nil then return "-" end
    return tostring(v)
end

local function BoxText(b)
    if not b or #b < 6 then return "-" end
    return format("x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f", b[1], b[4], b[2], b[5], b[3], b[6])
end

-- A step of the run: an error is kept in the results and reported (BugSack), and the run goes on - only a crash is
-- what the guard is for. (Reported from inside xpcall's handler, while the stack still shows where it happened.)
local function Report(e)
    local h = geterrorhandler and geterrorhandler()
    if h then pcall(h, e) end
    return e
end

local function Step(name, fn, ...)
    local args, n = { ... }, select("#", ...)
    local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, Report)
    if not ok then
        local res = P.res
        if res then res.errors[#res.errors + 1] = name .. ": " .. Short(err) end
    end
    return ok
end

---------------------------------------------------------------------------
-- Scenes, cameras, actors
---------------------------------------------------------------------------

-- A ModelScene over tile t's scene area at its level + lvl (under parent, default the area).
local function Scene(t, lvl, parent)
    local ok, sc = pcall(CreateFrame, "ModelScene", nil, parent or t.area)
    if not ok or not sc then return nil end
    sc:SetAllPoints(t.area)
    sc:SetFrameLevel(t.level + (lvl or 1))
    pcall(sc.SetCameraFieldOfView, sc, FOV)
    pcall(sc.SetCameraNearClip, sc, NEAR)
    pcall(sc.SetCameraFarClip, sc, FAR)
    pcall(sc.SetLightVisible, sc, true)
    pcall(sc.SetLightDirection, sc, -0.4, 0.3, -0.8)
    pcall(sc.SetLightAmbientColor, sc, 0.7, 0.7, 0.75)
    pcall(sc.SetLightDiffuseColor, sc, 0.85, 0.85, 0.85)
    P.scenes[#P.scenes + 1] = sc
    -- (whose scene it is: solo shows one tile's scenes and hides every other scene of the probe)
    sc.probeTile = t
    t.scenes = t.scenes or {}
    t.scenes[#t.scenes + 1] = sc
    return sc
end

-- The camera at (cx, cy, cz) looking at (tx, ty, tz); kept on the scene so a changed pitch sign can place it again.
local function LookAt(sc, cx, cy, cz, tx, ty, tz)
    if not sc then return end
    sc.probeCam = { cx, cy, cz, tx, ty, tz }
    local dx, dy, dz = tx - cx, ty - cy, tz - cz
    pcall(sc.SetCameraPosition, sc, cx, cy, cz)
    local pitch = atan2(-dz, sqrt(dx * dx + dy * dy))   -- (positive looks down)
    pcall(sc.SetCameraOrientationByYawPitchRoll, sc, atan2(dy, dx), P.pitchSign * pitch, 0)
end

-- The camera `dist` yards from (tx, ty, tz), looking at it along `yaw` and down `pitch` (degrees).
local function Orbit(sc, tx, ty, tz, yaw, pitch, dist)
    local y, p = rad(yaw), rad(pitch)
    local fx, fy, fz = cos(p) * cos(y), cos(p) * sin(y), -sin(p)
    LookAt(sc, tx - fx * dist, ty - fy * dist, tz - fz * dist, tx, ty, tz)
end

-- A screen point (UI units from the scene's bottom-left corner) of a scene point, or nil.
local function Proj(sc, x, y, z)
    if not sc then return nil end
    local ok, px, py = pcall(sc.Project3DPointTo2D, sc, x, y, z)
    if not ok or type(px) ~= "number" or type(py) ~= "number" then return nil end
    local es = sc:GetEffectiveScale() or 1
    if es <= 0 then es = 1 end
    return px / es, py / es
end

-- A new actor (nil when the scene makes none). Its model's own origin stands at its position; probeOnLoad (if set)
-- runs once its model has loaded.
local function Actor(sc)
    if not sc then return nil end
    local ok, a = pcall(sc.CreateActor, sc, nil, "ModelSceneActorTemplate")
    if not ok or not a then ok, a = pcall(sc.CreateActor, sc) end
    if not ok or not a then return nil end
    pcall(a.SetUseCenterForOrigin, a, false, false, false)
    if a.SetOnModelLoadedCallback then
        pcall(a.SetOnModelLoadedCallback, a, function(actor)
            -- (asked again with every model, as View.lua does: the client may reset it)
            pcall(actor.SetUseCenterForOrigin, actor, false, false, false)
            actor.probeLoadedAt = GetTime()
            if actor.probeOnLoad then pcall(actor.probeOnLoad, actor) end
        end)
    end
    return a
end

-- Puts actor a's origin at (x, y, z) at scale s (a position is multiplied by the actor's scale).
local function Place(a, x, y, z, s)
    if not a then return end
    s = s or 1
    pcall(a.SetScale, a, s)
    pcall(a.SetPosition, a, x / s, y / s, z / s)
end

local function Cube(sc, x, y, z, size)
    local a = Actor(sc)
    if not a then return nil end
    pcall(a.SetModelByFileID, a, CUBE)
    Place(a, x, y, z, size)
    return a
end

-- Your own character, its feet at (x, y, z), facing `yaw`. Right after a reload the client may not have your model
-- yet (the first full run showed no "you" in any tile): SetModelByUnit is asked again every 0.5 s until it says yes
-- and the model has loaded, for up to 10 s; results.me keeps what happened.
local function Me(sc, x, y, z, yaw)
    local a = Actor(sc)
    if not a then return nil end
    Place(a, x, y, z, 1)
    pcall(a.SetYaw, a, yaw or 0)
    local res = P.res
    local me = res and res.me
    if res and not me then
        me = { tiles = 0, set = {}, loaded = 0 }
        res.me = me
    end
    if me then me.tiles = me.tiles + 1 end
    local tries, done = 0, false
    local function Try()
        if done then return end
        tries = tries + 1
        local ok, set = pcall(a.SetModelByUnit, a, "player")
        set = ok and set and true or false
        local okl, loaded = pcall(a.IsLoaded, a)
        loaded = okl and loaded and true or false
        if set and loaded then
            done = true
            if me then
                me.loaded = me.loaded + 1
                me.set[#me.set + 1] = tries
            end
            pcall(a.SetYaw, a, yaw or 0)
            if a.probeOnLoad and not a.probeLoadedAt then
                a.probeLoadedAt = GetTime()
                pcall(a.probeOnLoad, a)
            end
        elseif tries < 20 then
            C_Timer.After(0.5, Try)
        elseif me then
            me.failed = (me.failed or 0) + 1
            me.lastSet, me.lastLoaded = set, loaded
        end
    end
    Try()
    return a
end

local function Creature(sc, display, x, y, z, yaw, s)
    local a = Actor(sc)
    if not a then return nil end
    pcall(a.SetModelByCreatureDisplayID, a, display)
    Place(a, x, y, z, s or 1)
    pcall(a.SetYaw, a, yaw or 0)
    return a
end

local function SetFlag(sc)
    local ok, err = pcall(sc.SetAllowOverlappedModels, sc, true)
    local res = P.res
    if res and res.overlapSet == nil then
        -- (the getter right after setting it: whether the flag sticks)
        if ok then
            res.overlapSet = Answer(pcall(sc.GetAllowOverlappedModels, sc))
        else
            res.overlapSet = Answer(ok, err)
        end
    end
end

---------------------------------------------------------------------------
-- Tiles and overlays
---------------------------------------------------------------------------

-- Tile n of page pg at grid cell (col, row), spanning cs x rs cells: a dark scene area with a 1 px edge, the caption
-- under it ("n. what should show") and a grey line of measured values (t.data).
local function Tile(pg, n, col, row, caption, cs, rs)
    local UI = ns.UI
    cs, rs = cs or 1, rs or 1
    local f = CreateFrame("Frame", nil, pg)
    local h = ROW_H * rs - 8
    f:SetSize(TW * cs + GAP * (cs - 1), h)
    f:SetPoint("TOPLEFT", (col - 1) * (TW + GAP), -(row - 1) * ROW_H)
    local area = CreateFrame("Frame", nil, f)
    area:SetPoint("TOPLEFT")
    area:SetPoint("TOPRIGHT")
    area:SetHeight(h - CAP_H - DATA_H)
    local bg = area:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.11, 0.12, 0.15, 1)
    if UI and UI.AddEdges then
        UI:AddEdges(area)
        UI:SetEdgeColor(area, 0.32, 0.32, 0.36, 1)
    end
    local cap = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cap:SetPoint("TOPLEFT", area, "BOTTOMLEFT", 1, -3)
    cap:SetPoint("TOPRIGHT", area, "BOTTOMRIGHT", -1, -3)
    cap:SetHeight(CAP_H - 2)
    cap:SetJustifyH("LEFT")
    cap:SetJustifyV("TOP")
    cap:SetText(n .. ". " .. caption)
    local data = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    data:SetPoint("BOTTOMLEFT", 1, 0)
    data:SetPoint("BOTTOMRIGHT", -1, 0)
    data:SetHeight(DATA_H)
    data:SetJustifyH("LEFT")
    data:SetWordWrap(false)
    -- (the colours set here, not left to the fonts: solo greys the other tiles' captions and gives these back)
    cap:SetTextColor(1, 1, 1)
    data:SetTextColor(0.5, 0.5, 0.5)
    local t = { f = f, area = area, bg = bg, cap = cap, data = data, n = n, level = area:GetFrameLevel(),
                caption = caption }
    pg.tiles[#pg.tiles + 1] = t
    return t
end

local function Overlay(t)
    if not t.ov then
        local ov = CreateFrame("Frame", nil, t.area)
        ov:SetAllPoints(t.area)
        ov:SetFrameLevel(t.level + 9)                   -- (over every scene of the tile)
        t.ov, t.lines, t.dots = ov, {}, {}
    end
    return t.ov
end

-- Line i of tile t from scene point p to q (projected by sc), in colour c; hidden while an end does not project.
local function Seg(t, i, sc, p, q, c)
    local ov = Overlay(t)
    local l = t.lines[i]
    if not l then
        l = ov:CreateLine(nil, "OVERLAY")
        l:SetThickness(1.5)
        t.lines[i] = l
    end
    local x1, y1 = Proj(sc, p[1], p[2], p[3])
    local x2, y2 = Proj(sc, q[1], q[2], q[3])
    if not (x1 and x2) then
        l:Hide()
        return
    end
    l:SetColorTexture(c[1], c[2], c[3], 0.9)
    l:SetStartPoint("BOTTOMLEFT", sc, x1, y1)
    l:SetEndPoint("BOTTOMLEFT", sc, x2, y2)
    l:Show()
end

local function HideDot(t, i)
    local d = t.dots and t.dots[i]
    if d then d:Hide() end
end

-- Dot i of tile t on scene point p.
local function Dot(t, i, sc, p, c, size)
    local ov = Overlay(t)
    local d = t.dots[i]
    if not d then
        d = ov:CreateTexture(nil, "OVERLAY")
        t.dots[i] = d
    end
    local x, y = Proj(sc, p[1], p[2], p[3])
    if not x then
        d:Hide()
        return
    end
    d:SetSize(size or 5, size or 5)
    d:SetColorTexture(c[1], c[2], c[3], 1)
    d:ClearAllPoints()
    d:SetPoint("CENTER", sc, "BOTTOMLEFT", x, y)
    d:Show()
end

-- The 8 corners of box b (bit 1 of the index: max x, bit 2: max y, bit 4: max z) and its 12 edges.
local function Corners(b)
    local out = {}
    for i = 0, 7 do
        out[i + 1] = { (i % 2 == 0) and b[1] or b[4], (floor(i / 2) % 2 == 0) and b[2] or b[5],
                       (floor(i / 4) == 0) and b[3] or b[6] }
    end
    return out
end
local EDGES = { { 1, 2 }, { 3, 4 }, { 1, 3 }, { 2, 4 }, { 5, 6 }, { 7, 8 }, { 5, 7 }, { 6, 8 }, { 1, 5 }, { 2, 6 },
                { 3, 7 }, { 4, 8 } }

local function Wire(t, sc, b, c)
    local k = Corners(b)
    for i, e in ipairs(EDGES) do Seg(t, i, sc, k[e[1]], k[e[2]], c) end
end

-- A camera that shows box b whole, from the front left and above.
local function FrameBox(sc, b, pitch)
    local cx, cy, cz = (b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2
    local dx, dy, dz = b[4] - b[1], b[5] - b[2], b[6] - b[3]
    local r = max(0.8, sqrt(dx * dx + dy * dy + dz * dz) / 2)
    Orbit(sc, cx, cy, cz, 35, pitch or 30, 4 * r)
end

-- The camera on (tx, ty, tz) from azimuth az and elevation el (degrees: where it stands, seen from the point), backed
-- off until every point of pts lies within `fill` of the scene's half width and half height, measured with the
-- client's own projection (whether its field of view is horizontal or vertical: tile 38 of round 2 assumed one and
-- showed only part of its dots). Before the scene is laid out it keeps a first guess; t.draw calls it again.
local function Fit(sc, pts, tx, ty, tz, az, el, fill)
    if not sc then return end
    local r = 0.3
    for _, p in ipairs(pts) do
        r = max(r, sqrt((p[1] - tx) ^ 2 + (p[2] - ty) ^ 2 + (p[3] - tz) ^ 2))
    end
    local dist = sc.probeDist or 3.5 * r
    local w, h = sc:GetWidth() or 0, sc:GetHeight() or 0
    for _ = 1, 6 do
        Orbit(sc, tx, ty, tz, az + 180, el, dist)
        if w <= 0 or h <= 0 then break end
        local worst = 0
        for _, p in ipairs(pts) do
            local x, y = Proj(sc, p[1], p[2], p[3])
            if not x then
                worst = nil                             -- (not measurable now: keep the camera where it is)
                break
            end
            worst = max(worst, abs(x - w / 2) / (w / 2), abs(y - h / 2) / (h / 2))
        end
        local k = worst and worst / (fill or 0.8) or 0
        if k <= 0 or abs(k - 1) < 0.02 then break end
        dist = max(dist * k, r + 2 * NEAR)
    end
    sc.probeDist = dist
end

---------------------------------------------------------------------------
-- Rotations (tiles 35-38): candidate meanings of the actor's yaw, pitch and roll, right-handed, z up
---------------------------------------------------------------------------

local function Mul(a, b)
    return { a[1] * b[1] + a[2] * b[4] + a[3] * b[7], a[1] * b[2] + a[2] * b[5] + a[3] * b[8],
             a[1] * b[3] + a[2] * b[6] + a[3] * b[9],
             a[4] * b[1] + a[5] * b[4] + a[6] * b[7], a[4] * b[2] + a[5] * b[5] + a[6] * b[8],
             a[4] * b[3] + a[5] * b[6] + a[6] * b[9],
             a[7] * b[1] + a[8] * b[4] + a[9] * b[7], a[7] * b[2] + a[8] * b[5] + a[9] * b[8],
             a[7] * b[3] + a[8] * b[6] + a[9] * b[9] }
end

local function Apply(m, v)
    return { m[1] * v[1] + m[2] * v[2] + m[3] * v[3], m[4] * v[1] + m[5] * v[2] + m[6] * v[3],
             m[7] * v[1] + m[8] * v[2] + m[9] * v[3] }
end

local AXIS = {
    y = function(a) local c, s = cos(a), sin(a) return { c, -s, 0, s, c, 0, 0, 0, 1 } end,   -- yaw: about +z
    p = function(a) local c, s = cos(a), sin(a) return { c, 0, s, 0, 1, 0, -s, 0, c } end,   -- pitch: about +y
    r = function(a) local c, s = cos(a), sin(a) return { 1, 0, 0, 0, c, -s, 0, s, c } end,   -- roll: about +x
}
local SETTER = { y = "SetYaw", p = "SetPitch", r = "SetRoll" }

-- One turn about one axis (deg degrees), as SetYaw / SetPitch / SetRoll alone do: tiles 35-37 showed each is the
-- standard right-handed turn about z, y and x. Page 6 turns its models about one axis only, so the still unknown
-- order of a combined turn cannot misplace them.
local function Turn(axis, deg)
    if not axis then return nil end
    return AXIS[axis](rad(deg))
end

-- p (model units) as the client should draw it: turned by m (nil: not turned), scaled by s, moved to pos.
local function Xf(m, s, pos, p)
    local v = { p[1] * s, p[2] * s, p[3] * s }
    if m then v = Apply(m, v) end
    return { v[1] + pos[1], v[2] + pos[2], v[3] + pos[3] }
end

-- The lines of tile t along box b's edges placed by (m, s, pos); a flat box gives its outline only (each edge once).
local function WireXf(t, sc, b, m, s, pos, c)
    local k = Corners(b)
    local seen, i = {}, 0
    for _, e in ipairs(EDGES) do
        local p, q = k[e[1]], k[e[2]]
        local key = format("%.4f %.4f %.4f %.4f %.4f %.4f", p[1], p[2], p[3], q[1], q[2], q[3])
        if abs(p[1] - q[1]) + abs(p[2] - q[2]) + abs(p[3] - q[3]) > 1e-6 and not seen[key] then
            seen[key] = true
            i = i + 1
            Seg(t, i, sc, Xf(m, s, pos, p), Xf(m, s, pos, q), c)
        end
    end
    t.wired = i
end
-- "ypr" = yaw(pitch(roll(v))): roll turns the model first.
local ORDERS = { { "ypr", RED, "Y.P.R" }, { "yrp", GREEN, "Y.R.P" }, { "pyr", BLUE, "P.Y.R" },
                 { "pry", YELLOW, "P.R.Y" }, { "ryp", CYAN, "R.Y.P" }, { "rpy", PINK, "R.P.Y" } }
-- Tile 38's turn, in degrees. Picked offline (all signs +, as tiles 35-37 showed) in the tile's own perspective view
-- (the camera Fit places: 4.7 yd away if the client's field of view of 0.9 is vertical, 7.4 yd if horizontal; 2 yd
-- cube, 454 x 276 area): whichever order is the true one, for any wrong order there is a visible corner of the true
-- cube with none of that order's dots within 0.65 yd (about 41 px) of it on screen. The first pick, 50 / 40 / 35, kept
-- its 0.62 yd only seen from far away (no perspective): in the tile's view Y.P.R and Y.R.P came within 0.41 yd
-- (25 px). Round 2's 30 / 20 / 35: 0.28 yd.
local TURN = { y = 30, p = 60, r = 65 }

local function Rot(order, ang)
    local m = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    for i = 1, 3 do
        local k = order:sub(i, i)
        m = Mul(m, AXIS[k](ang[k]))
    end
    return m
end

-- Sign set i (1..8): the signs of yaw, pitch and roll.
local function Signs(i)
    local k = i - 1
    return (k % 2 == 0) and 1 or -1, (floor(k / 2) % 2 == 0) and 1 or -1, (floor(k / 4) % 2 == 0) and 1 or -1
end

local function SignsText(i)
    local y, p, r = Signs(i)
    return format("Signs: yaw %s  pitch %s  roll %s", y > 0 and "+" or "-", p > 0 and "+" or "-", r > 0 and "+" or "-")
end

-- (the button's short form: it must stay clear of the cube's dots)
local function SignsButtonText(i)
    local y, p, r = Signs(i)
    return format("Signs y%s p%s r%s", y > 0 and "+" or "-", p > 0 and "+" or "-", r > 0 and "+" or "-")
end

local function OrderButtonText(i)
    return i == 0 and "Orders: all" or ("Order " .. ORDERS[i][3])
end

local CORNERS2 = Corners({ -1, -1, -1, 1, 1, 1 })   -- (the 2 yd cube of the rotation tiles)

---------------------------------------------------------------------------
-- Loose files
---------------------------------------------------------------------------

-- What the client says of a file path before loading it (C_UIFileAsset, when this client has it).
local function AssetInfo(rec, path)
    local fa = _G.C_UIFileAsset
    if type(fa) ~= "table" then
        rec.fileAsset = "no C_UIFileAsset"
        return
    end
    for _, name in ipairs({ "IsLooseFile", "GetFileID", "IsKnownFile" }) do
        local f = fa[name]
        if type(f) == "function" then
            rec[name] = Answer(pcall(f, path))
        else
            rec[name] = "missing"
        end
    end
end

-- Why a loose file (or, with key FRAMES, the two frame types) is not made this run, or nil.
-- (noskin and md20 use layouts no file of the client has - an MD21 without SFID, a plain MD20 - so a full run leaves
-- them out: each loads on its own, /dz 3d probe only noskin / only md20, after a full run was saved)
local RISKY = { noskin = true, md20 = true }
local function SkipReason(key)
    if P.mode == "safe" then return "safe mode" end
    if P.only and P.only ~= key then return "only " .. P.only .. " this run" end
    if not P.only and RISKY[key] then return "riskier layout: /dz 3d probe only " .. key end
    return nil
end

-- The tile's one line: loaded or not and the size of what loaded (the file id and the box's corners are in the
-- table under the tiles; they would not fit here).
local function LooseLine(rec)
    if rec.skipped then return "skipped: " .. rec.skipped end
    local loaded = rec.loaded6s
    if loaded == nil then loaded = rec.loaded2s end
    local s = "set " .. tostring(rec.set) .. ", loaded " .. (loaded == nil and "..." or tostring(loaded))
    local b = rec.active
    if b and #b >= 6 then
        s = s .. format(", %.1f x %.1f x %.1f yd", b[4] - b[1], b[5] - b[2], b[6] - b[3])
    elseif rec.activeBad then
        s = s .. ", box not finite"
    end
    return s
end

-- Loads a test model into actor a of tile t (the control cube by file ID when L is nil) and keeps what the client
-- says in results.loose[key].
local function LoadModel(t, a, key, L)
    local res = P.res
    local rec = { file = L and L.file or ("file id " .. CUBE) }
    res.loose[key] = rec
    if L then
        local path = DIR .. L.file
        rec.path = path
        AssetInfo(rec, path)
        if L.skin then
            local sk = { file = L.skin }
            AssetInfo(sk, DIR .. L.skin)
            rec.skinFile = sk
        end
        local why = SkipReason(key)
        if why then
            rec.skipped = why
            t.data:SetText(LooseLine(rec))
            return
        end
    end
    if not a then
        rec.set = "no actor"
        t.data:SetText(LooseLine(rec))
        return
    end
    -- (a loose file only ever by path: a client without SetModelByPath says so instead of trying another way)
    local method, asset = "SetModelByFileID", CUBE
    if L then method, asset = "SetModelByPath", DIR .. L.file end
    if type(a[method]) ~= "function" then
        rec.set = "no " .. method
    else
        rec.set = Answer(pcall(a[method], a, asset))
    end
    P.loaded[key] = { a = a, t = t, t0 = GetTime() }
    t.data:SetText(LooseLine(rec))
end

-- The depth tiles (7, 8): the camera looks along the square's thin axis, the big cube stands behind the square (its
-- near face a yard behind it, twice the square's size) moved sideways by half its width, so its edge runs down the
-- square's middle. Half the square then lies over the cube (a hole there = it writes depth), the other half over the
-- tile's mid-tone backdrop (no darker or tinted patch there = its Mod blend leaves the colours under it alone).
local function DepthLayout(scenes, cube, b)
    local sx, sy, sz = abs(b[4] - b[1]), abs(b[5] - b[2]), abs(b[6] - b[3])
    local cx, cy, cz = (b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2
    local fx, fy, fz
    if sz <= sx and sz <= sy then
        fx, fy, fz = cos(rad(80)), 0, -sin(rad(80))            -- flat on the ground: from above
    elseif sx <= sy then
        fx, fy, fz = cos(rad(10)), 0, -sin(rad(10))            -- upright across x
    else
        fx, fy, fz = 0, cos(rad(10)), -sin(rad(10))            -- upright across y
    end
    -- (sideways: in the square's plane, across the view)
    local ux, uy = 0, 1
    if fy ~= 0 then ux, uy = 1, 0 end
    local side = max(sx, sy, sz, 1)
    local d, k = 2 * side, side + 1
    P.depthBox = b
    for _, sc in ipairs(scenes) do LookAt(sc, cx - fx * d, cy - fy * d, cz - fz * d, cx, cy, cz) end
    Place(cube, cx + fx * k + ux * side, cy + fy * k + uy * side, cz + fz * k, 2 * side)
end

-- Every loaded test model: loaded yet, which file, its boxes (tag "2s" / "6s": seconds after loading).
function P.CheckLoose(tag)
    local res = P.res
    for key, h in pairs(P.loaded) do
        local rec, a = res.loose[key], h.a
        local ok, v = pcall(a.IsLoaded, a)
        if ok then rec["loaded" .. tag] = v and true or false else rec["loaded" .. tag] = Answer(ok, v) end
        rec.modelFileID = Answer(pcall(a.GetModelFileID, a))
        rec.modelPath = Answer(pcall(a.GetModelPath, a))
        rec.active, rec.activeBad = BoxOf(a, "GetActiveBoundingBox")
        rec.max, rec.maxBad = BoxOf(a, "GetMaxBoundingBox")
        if a.probeLoadedAt then rec.loadSeconds = Round(a.probeLoadedAt - h.t0, 2) end
        h.t.data:SetText(LooseLine(rec))
    end
    -- the square may lie otherwise than the manifest says: the depth tiles follow the client's own box
    local b = res.loose.depth and res.loose.depth.active
    if b and #b == 6 and P.depthTiles then
        local span = abs(b[4] - b[1]) + abs(b[5] - b[2]) + abs(b[6] - b[3])
        if span > 0.5 and span < 100 then
            for _, d in ipairs(P.depthTiles) do DepthLayout(d.scenes, d.cube, b) end
            if P.page == PAGE_OF.loose then P.Redraw() end
        end
    end
    P.RefreshLooseTable()
end

-- Page 6's stand-in candidates: loaded or not, and the client's own box for each (does it match the mesh, or the
-- header box? 198110's header box reaches 17 units below its quad). Asked 2 and 6 s after the page was built: it is
-- built only when its tab is opened, often long after the run's own checks.
function P.CheckPrims()
    local res = P.res
    if not res then return end
    res.prims = res.prims or {}
    for _, h in ipairs(P.prims or {}) do
        local a, rec = h.a, { fid = h.fid }
        if a then
            local ok, v = pcall(a.IsLoaded, a)
            if ok then rec.loaded = v and true or false else rec.loaded = Answer(ok, v) end
            rec.modelFileID = Answer(pcall(a.GetModelFileID, a))
            rec.active, rec.activeBad = BoxOf(a, "GetActiveBoundingBox")
        else
            rec.loaded = "no actor"
        end
        res.prims[h.key] = rec
        h.t.data:SetText(format("%d: loaded %s; client box %s", h.fid, Txt(rec.loaded),
            rec.activeBad and ("not finite: " .. rec.activeBad) or BoxText(rec.active)))
    end
    if P.dataText then P.dataText:SetText(tconcat(P.SummaryLines(res), "\n")) end
end

-- Whether the client's model path is the one asked for (it may answer in another case or with /).
local function SamePath(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    return (a:lower():gsub("/", "\\")) == (b:lower():gsub("/", "\\"))
end

-- What the client said of each model in keys (default all of them), one entry a line.
function P.LooseTableText(keys)
    local res = P.res
    local out = {}
    for _, key in ipairs(keys or KEY_ORDER) do
        local r = res and res.loose[key]
        if r then
            local asked = format("loose %s, id %s, known %s", Txt(r.IsLooseFile), Txt(r.GetFileID),
                Txt(r.IsKnownFile))
            local s
            if r.skipped then
                s = format("%s: skipped (%s); %s", key, r.skipped, asked)
            else
                -- (the model's path only when it is not the one asked for; the max box only when it differs)
                local path = ""
                if r.modelPath ~= nil and r.modelPath ~= "nil" and not SamePath(r.modelPath, r.path) then
                    path = ", path " .. tostring(r.modelPath)
                end
                local act, maxb = BoxText(r.active), BoxText(r.max)
                if r.activeBad then act = "box " .. r.activeBad end
                if r.maxBad then maxb = "box " .. r.maxBad end
                local took = r.loadSeconds and format(" (%.2f s)", r.loadSeconds) or ""
                s = format("%s: %s; set %s; loaded 2 s %s, 6 s %s%s; fid %s%s; %s%s", key, asked, Txt(r.set),
                    Txt(r.loaded2s), Txt(r.loaded6s), took, Txt(r.modelFileID), path, act,
                    maxb ~= act and ("; max " .. maxb) or "")
            end
            if r.skinFile then
                s = s .. format("; .skin loose %s, known %s", Txt(r.skinFile.IsLooseFile), Txt(r.skinFile.IsKnownFile))
            end
            out[#out + 1] = s
        end
    end
    return tconcat(out, "\n")
end

function P.RefreshLooseTable()
    for _, col in ipairs(P.looseCols or {}) do col.fs:SetText(P.LooseTableText(col.keys)) end
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

-- 1: the loose model files, with Blizzard's own cube as the control.
local function BuildLoose(pg)
    local t = Tile(pg, 1, 1, 1, "Control: Blizzard's unit cube (file 167145) inside the yellow frame = model scenes "
        .. "work.")
    local sc = Scene(t, 1)
    FrameBox(sc, CUBE_BOX)
    LoadModel(t, Actor(sc), "control", nil)
    t.draw = function() Wire(t, sc, CUBE_BOX, YELLOW) Dot(t, 1, sc, ORIGIN, RED) end
    local CAPS = {
        copy = "probe_copy.m2, a byte copy of 1 from Media\\Probe: the same cube = loose .m2 files load at all.",
        md21 = "probe_box_md21.m2: a box filling the yellow 3x1x2 yd frame (red dot = origin). Mirrored = handedness.",
        noskin = "probe_box_noskin.m2 + its own .skin: fills the frame = the client finds a loose .skin by name.",
        md20 = "probe_box_md20.m2 + .skin, old MD20 layout: fills the frame = MD20 files load too.",
        checker = "probe_checker.m2, our vertices on a Blizzard skin: a 4x4 yd checkerboard in the frame = reuse "
            .. "works.",
    }
    local CELLS = { copy = { 2, 1 }, md21 = { 3, 1 }, noskin = { 4, 1 }, md20 = { 1, 2 }, checker = { 2, 2 } }
    for i, key in ipairs({ "copy", "md21", "noskin", "md20", "checker" }) do
        local L = LOOSE_BY[key]
        local tt = Tile(pg, i + 1, CELLS[key][1], CELLS[key][2], CAPS[key])
        local s = Scene(tt, 1)
        FrameBox(s, L.box, key == "checker" and 45 or 30)
        LoadModel(tt, Actor(s), key, L)
        tt.draw = function() Wire(tt, s, L.box, YELLOW) Dot(tt, 1, s, ORIGIN, RED) end
    end
    -- 7: the invisible square in a lower scene, a big cube in the upper one; 8: the cube alone. Both over a mid-tone
    -- backdrop like the board's textured room: on near-black a darkening or tint from the Mod pass would not show.
    local L = LOOSE_BY.depth
    local t7 = Tile(pg, 7, 3, 2, "probe_depth.m2 (invisible) in the outline: a HOLE in the cube = writes depth; "
        .. "brown unchanged = colour-neutral.")
    local t8 = Tile(pg, 8, 4, 2, "Control for 7, no square: the cube unbroken, the brown beside it plain.")
    for _, t in ipairs({ t7, t8 }) do t.bg:SetColorTexture(0.55, 0.42, 0.25, 1) end
    local low, up = Scene(t7, 1), Scene(t7, 3)
    local cube7 = Actor(up)
    if cube7 then pcall(cube7.SetModelByFileID, cube7, CUBE) end
    local up8 = Scene(t8, 3)
    local cube8 = Actor(up8)
    if cube8 then pcall(cube8.SetModelByFileID, cube8, CUBE) end
    P.depthTiles = { { scenes = { low, up }, cube = cube7 }, { scenes = { up8 }, cube = cube8 } }
    for _, d in ipairs(P.depthTiles) do DepthLayout(d.scenes, d.cube, L.box) end
    LoadModel(t7, Actor(low), "depth", L)
    t8.data:SetText("the same camera and cube as 7")
    -- (the yellow outline: where the square is, so where the hole must be)
    t7.draw = function() Wire(t7, up, P.depthBox or L.box, YELLOW) end
    t8.draw = function() Wire(t8, up8, P.depthBox or L.box, YELLOW) end
    -- row 3: everything the client said of each file, for the screenshot, in two columns: with the client's real
    -- answers an entry runs past one full-width line, and seven of them would not fit the row in one column
    P.looseCols = {}
    local colW = 2 * TW + GAP
    for i, keys in ipairs({ { "control", "copy", "md21", "noskin" }, { "md20", "checker", "depth" } }) do
        local fs = pg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", (i - 1) * (colW + GAP), -2 * ROW_H)
        fs:SetSize(colW, ROW_H - 8)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        P.looseCols[i] = { fs = fs, keys = keys }
    end
    P.RefreshLooseTable()
end

-- You 5 yd ahead facing the camera, a small cube in front of your chest a little to one side (pages 2 and 3). Once
-- your model has loaded, the cube moves onto the line from the camera to the middle of your body and is sized to your
-- height: a fixed cube would cover a gnome's head only, and a missed body reads like "no depth".
local ME_CAM = { -5, 0, 1.3, 0, 0, 1.0 }
local ME_CUBE_X = -1.6
local function MeCube(A, B, alpha)
    LookAt(A, unpack(ME_CAM))
    LookAt(B, unpack(ME_CAM))
    local cube = Cube(A, ME_CUBE_X, 0.2, 1.1, 0.5)
    if cube and alpha then pcall(cube.SetAlpha, cube, alpha) end
    local me = Me(B, 0, 0, 0, PI)
    if me and cube then
        me.probeOnLoad = function(m)
            local b = BoxOf(m, "GetActiveBoundingBox")
            if not (b and #b == 6) then return end
            local h = b[6] - b[3]
            if h < 0.3 or h > 8 then return end
            local u = (ME_CUBE_X - ME_CAM[1]) / -ME_CAM[1]     -- (the cube's share of the way from the camera)
            local tz = b[3] + 0.55 * h
            Place(cube, ME_CUBE_X, u * 0.1 * h, ME_CAM[3] + u * (tz - ME_CAM[3]), 0.25 * h)
        end
        if me.probeLoadedAt then pcall(me.probeOnLoad, me) end
    end
    return cube
end

-- 13-19, 42: the cube's scene, something drawn over the same pixels, then your scene. kind: plain (a colour texture),
-- clip / clipout (both scenes in a clipping frame like the board's, the teal over the LEFT half only so the right
-- half shows whether the scenes draw in there at all: clip keeps the teal in a frame of its own inside the clipping
-- frame, at a level between the scenes; clipout puts that frame outside it, a sibling at the same level),
-- DISABLE / ALPHAKEY / BLEND (a file texture in that blend mode), strata (the cube's scene in MEDIUM strata under the
-- window), none (control). long: the solo bar's full explanation.
local function Sandwich(pg, n, col, row, kind, caption, long)
    local t = Tile(pg, n, col, row, caption)
    t.long = long
    local holder = t.area
    local clip = kind == "clip" or kind == "clipout"
    if clip then
        holder = CreateFrame("Frame", nil, t.area)
        holder:SetAllPoints(t.area)
        holder:SetFrameLevel(t.level + 1)
        holder:SetClipsChildren(true)
    end
    local A
    if kind == "strata" then
        A = Scene(t, 1, UIParent)
        if A then
            A:SetFrameStrata("MEDIUM")
            -- (not a child of the window: shown with the page when solo allows it, hidden with it)
            A.probeOuter = pg
            pg:HookScript("OnShow", function() P.ApplySolo() end)
            pg:HookScript("OnHide", function() A:Hide() end)
        end
    else
        A = Scene(t, 2, holder)
    end
    if kind ~= "none" and kind ~= "strata" then
        local cover = CreateFrame("Frame", nil, kind == "clipout" and t.area or holder)
        cover:SetFrameLevel(t.level + 3)
        if clip then
            cover:SetPoint("TOPLEFT", t.area, "TOPLEFT")
            cover:SetPoint("BOTTOMRIGHT", t.area, "BOTTOM")
        else
            cover:SetAllPoints(t.area)
        end
        local tex = cover:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        if kind == "plain" or clip then
            tex:SetColorTexture(TEAL[1], TEAL[2], TEAL[3], 1)
        else
            tex:SetTexture(WHITE)
            tex:SetVertexColor(TEAL[1], TEAL[2], TEAL[3], 1)
            pcall(tex.SetBlendMode, tex, kind)
        end
        t.cover = cover
    end
    t.holder = holder
    MeCube(A, Scene(t, 5, holder))
end

-- 2: depth inside one scene, and through textures between scenes.
local function BuildDepth(pg)
    local t = Tile(pg, 9, 1, 1, "Two cubes through each other, one scene: straight cut lines where they meet = "
        .. "per-pixel depth.")
    local sc = Scene(t, 1)
    Orbit(sc, 0.35, 0.25, 0.2, 35, 30, 7)
    Cube(sc, 0, 0, 0, 2)
    local b = Cube(sc, 0.7, 0.5, 0.4, 2)
    if b then pcall(b.SetYaw, b, rad(45)) end
    t = Tile(pg, 10, 2, 1, "Brutallus standing in a big cube, one scene: cut off flat where he enters it = per-pixel "
        .. "depth.")
    sc = Scene(t, 1)
    LookAt(sc, -11, -6, 6, 1.5, 0, 2)
    Creature(sc, BRUTALLUS, 0, 0, 0, PI, 1)
    Cube(sc, 3, 0, -2.5, 8)
    for i, meFirst in ipairs({ true, false }) do
        t = Tile(pg, 10 + i, 2 + i, 1, meFirst and "You 15 yd away, Brutallus x6 30 yd behind you, one scene, you made "
            .. "first: you must be in front." or "As 11, Brutallus made first: you must be in front.")
        sc = Scene(t, 1)
        LookAt(sc, -15, 0, 1.5, 15, 0, 5)
        if meFirst then Me(sc, 0, 0, 0, PI) end
        Creature(sc, BRUTALLUS, 30, 0, 0, PI, 6)
        if not meFirst then Me(sc, 0, 0, 0, PI) end
    end
    Sandwich(pg, 13, 1, 2, "plain", "Cube scene, an opaque texture, then your scene: a cube-shaped HOLE in you = depth "
        .. "survives textures.")
    Sandwich(pg, 14, 2, 2, "clip", "As 13 in a clipping frame (like the board's), teal on the LEFT half only: a hole "
        .. "there = clipping keeps depth.", "Both scenes and the teal's own frame (between them) inside a "
        .. "SetClipsChildren frame. Left half: a cube-shaped teal hole in you = depth survives in a clipping frame. "
        .. "Right half (no teal): the cube in front of you = the scenes draw there; nothing at all on both halves = "
        .. "model scenes do not draw like this inside a clipping frame (round 2's blank tile).")
    Sandwich(pg, 15, 3, 2, "DISABLE", "As 13 with a file texture, blend DISABLE: a hole = depth survives it.")
    Sandwich(pg, 16, 4, 2, "ALPHAKEY", "As 13 with a file texture, blend ALPHAKEY: a hole = depth survives it.")
    Sandwich(pg, 17, 1, 3, "BLEND", "As 13 with a file texture, blend BLEND: a hole = depth survives it.")
    Sandwich(pg, 18, 2, 3, "strata", "Cube scene in MEDIUM strata under this window: a hole = depth crosses strata "
        .. "(UI models elsewhere cut holes).")
    Sandwich(pg, 19, 3, 3, "none", "Control for 13-18, no texture: the cube in front of you.")
    Sandwich(pg, 42, 4, 3, "clipout", "As 14 with the teal frame outside the clipping frame (level between the "
        .. "scenes): a hole on the left = levels interleave.", "The two scenes inside the clipping frame, the "
        .. "teal (left half) in a sibling frame outside it at a level between them. A hole in you on the left = frame "
        .. "levels interleave across the clipping frame as anywhere else. Teal over all of you on the left = the "
        .. "clipping frame and its children draw as one block at its own level.")
end

-- 24, 25: Brutallus in two scenes cut at his middle by their clips, the far half under the near half.
local function SliceTile(pg, n, col, row, flag, caption, long)
    local t = Tile(pg, n, col, row, caption)
    t.long = long
    local F, N = Scene(t, 1), Scene(t, 3)
    local c = { -12, -3, 4, 2.5, 0, 2.3 }
    local d = sqrt((c[4] - c[1]) ^ 2 + (c[5] - c[2]) ^ 2 + (c[6] - c[3]) ^ 2)
    for _, s in ipairs({ F, N }) do
        LookAt(s, unpack(c))
        if flag and s then SetFlag(s) end
    end
    if F then pcall(F.SetCameraNearClip, F, d) end
    if N then pcall(N.SetCameraFarClip, N, d) end
    Creature(N, BRUTALLUS, 0, 0, 0, PI, 1)
    local far = Creature(F, BRUTALLUS, 0, 0, 0, PI, 1)
    -- (glows ignore clips: one copy of them is enough)
    if far then pcall(far.SetParticleOverrideScale, far, 0) end
    t.data:SetText(format("cut %.1f yd from the camera", d))
end

-- 43-46: three scenes with the same camera and clips - the cube's, a middle one, yours. mid: "empty" (no actor), "side"
-- (a small cube to your right, clear of you and of the big cube), "corner" (the middle scene only a small square in
-- the tile's corner, a small cube in it so it surely draws); flag: the middle scene flagged.
local function ThreeTile(pg, n, col, row, mid, flag, caption, long)
    local t = Tile(pg, n, col, row, caption)
    t.long = long
    local A, M, B = Scene(t, 1), Scene(t, 3), Scene(t, 5)
    if M then
        if mid == "corner" then
            M:ClearAllPoints()
            M:SetPoint("BOTTOMRIGHT", t.area, "BOTTOMRIGHT", -3, 3)
            M:SetSize(30, 30)
        end
        LookAt(M, unpack(ME_CAM))
        if mid == "side" then
            Cube(M, -1, -1.25, 0.35, 0.35)
        elseif mid == "corner" then
            Cube(M, -1, 0, 1.1, 0.9)
        end
        if flag then SetFlag(M) end
    end
    MeCube(A, B)
    t.data:SetText(format("middle scene: %s, flag %s", mid == "empty" and "empty" or (mid == "side"
        and "a small cube aside" or "a corner square"), flag and "on" or "off"))
end

-- 3 (solo): SetAllowOverlappedModels, the flag. Round 2 drew these tiles in one frame and a flagged scene seemed to
-- clear the depth the tiles drawn after it needed, so this page starts in solo: one tile's scenes at a time. Every
-- tile but the slices: a cube in a lower scene in front of you in an upper one, same camera and clips. Read 21 and 22
-- together: 21 you over the cube + 22 the cube in front = the flag clears the shared depth before its scene draws;
-- both you over the cube = a flagged scene keeps a depth buffer of its own; both the cube in front = no effect.
local function BuildFlags(pg)
    local FLAGS = {
        { 20, nil, nil, "Flag off on both (control): the cube in front of you, a cube-shaped hole in you = scenes "
            .. "share depth.", "Flag off on both scenes: the lower scene's cube writes depth and your scene is tested "
            .. "against it - the cube in front of you, a cube-shaped hole in you. Every flag tile compares with this." },
        { 21, nil, true, "Flag on YOUR (upper) scene only. You over the cube = clears before drawing (or own buffer); "
            .. "cube in front = no effect.", "SetAllowOverlappedModels(true) on the scene drawn last. You drawn whole "
            .. "over the cube = the flagged scene ignores the depth drawn before it: it clears the shared depth "
            .. "before drawing, or draws with a depth buffer of its own (22 tells which). The cube in front = the "
            .. "flag has no effect here." },
        { 22, true, nil, "Flag on the CUBE's (lower) scene only. Cube in front = clears before drawing (or no "
            .. "effect); you over it = own buffer.", "The flag on the scene drawn first. The cube still in front of "
            .. "you = its depth reaches the scenes after it: with 21 showing you over the cube, the flag clears "
            .. "depth BEFORE its own scene draws. You over the cube = a flagged scene's depth never reaches later "
            .. "scenes: it has its own buffer (or clears after drawing)." },
        { 23, true, true, "Flag on both scenes. You over the cube = clears or own buffer (21 and 22 tell which); cube "
            .. "in front = no effect.", "Both scenes flagged. You over the cube should agree with 21 (the upper "
            .. "flagged scene ignores what was drawn before it). The cube in front = no effect: then 21 and 22 show "
            .. "the cube in front too." },
    }
    for i, f in ipairs(FLAGS) do
        local t = Tile(pg, f[1], i, 1, f[4])
        t.long = f[5]
        local A, B = Scene(t, 1), Scene(t, 3)
        if f[2] and A then SetFlag(A) end
        if f[3] and B then SetFlag(B) end
        MeCube(A, B)
        t.data:SetText(format("flag: cube scene %s, your scene %s", f[2] and "on" or "off", f[3] and "on" or "off"))
    end
    ThreeTile(pg, 43, 1, 2, "empty", false, "Three scenes: cube, an EMPTY middle scene (flag off), you: the cube in "
        .. "front of you (control for 44-46).", "Control for 44-46: three scenes with the same camera and clips - "
        .. "the cube's (lowest), an empty one, yours (top). The cube in front of you, a cube-shaped hole in you.")
    ThreeTile(pg, 44, 2, 2, "empty", true, "As 43, the empty middle scene flagged: you over the cube = a flagged "
        .. "scene clears depth even empty; cube in front = no.", "The middle scene holds nothing and has "
        .. "SetAllowOverlappedModels(true). You drawn over the cube = a flagged scene clears the shared depth when it "
        .. "draws, even with nothing in it (one empty flagged scene could reset depth between two groups of scenes). "
        .. "The cube in front = an empty flagged scene does nothing (45 has one with a model in it).")
    ThreeTile(pg, 45, 3, 2, "side", true, "As 44 with a small cube far to the side in the flagged scene: you over "
        .. "the big cube = it clears its whole rectangle.", "The flagged middle scene holds a small cube to your "
        .. "right, clear of you and of the big cube. You over the big cube = the flagged scene clears depth over its "
        .. "whole rectangle, not only where it draws. The big cube in front = it clears its own pixels only, or "
        .. "nothing (compare 21).")
    ThreeTile(pg, 46, 4, 2, "corner", true, "As 45, the flagged scene only a small square in the corner: you over the "
        .. "big cube = its clear covers the screen.", "The flagged middle scene is only a small square in this "
        .. "tile's bottom right corner (the small cube in it shows that it draws). You over the big cube = its clear "
        .. "covers the whole screen, not just its rectangle: a flagged scene anywhere then wipes the depth every "
        .. "scene drawn before it left for the scenes drawn after it (what round 2's page 3 looked like).")
    SliceTile(pg, 24, 1, 3, false, "Brutallus cut in two scenes at his middle by their clips, flag off: broken = "
        .. "slicing fails (known).", "The far half in the lower scene (its near clip at the cut), the near half in "
        .. "the upper one (its far clip at the cut). Each scene stores depth in its own clip range, so the two halves' "
        .. "depths do not compare: a broken Brutallus (known since the slice test).")
    SliceTile(pg, 25, 2, 3, true, "As 24 with the flag on both scenes: one whole Brutallus, no seam = slicing by clips "
        .. "works with the flag.", "As 24, both scenes flagged. If a flagged scene clears depth before it draws, the "
        .. "near half draws over the far half whatever their stored depths: one whole Brutallus, no seam. Broken as "
        .. "24 = the flag does not clear between these two scenes.")
    -- 30, 31: the other untried way to isolate a scene's depth - a frame drawn to its own frame buffer first, then
    -- composited (SetIsFrameBuffer; it needs flattened render layers). As tile 20 otherwise.
    local BUFFER = {
        { 30, 3, false, "Cube scene inside a frame-buffer frame (SetIsFrameBuffer): you drawn over the cube = a frame "
            .. "buffer isolates depth." },
        { 31, 4, true, "As 30, each scene inside its own frame-buffer frame: you drawn over the cube = it isolates "
            .. "depth." },
    }
    for _, f in ipairs(BUFFER) do
        local t = Tile(pg, f[1], f[2], 3, f[4])
        local said = {}
        -- (scene lvl inside such a frame one level under it, or straight on the tile)
        local function Holder(lvl, buffered)
            if not buffered then return Scene(t, lvl) end
            local h = CreateFrame("Frame", nil, t.area)
            h:SetAllPoints(t.area)
            h:SetFrameLevel(t.level + lvl - 1)
            for _, m in ipairs({ "SetFlattensRenderLayers", "SetIsFrameBuffer" }) do
                if type(h[m]) ~= "function" then
                    said[m] = "missing"
                else
                    local ok, err = pcall(h[m], h, true)
                    said[m] = ok and "ok" or ("error: " .. Short(err))
                end
            end
            return Scene(t, lvl, h)
        end
        MeCube(Holder(2, true), Holder(4, f[3]))
        t.data:SetText(format("SetIsFrameBuffer %s, flatten %s", Txt(said.SetIsFrameBuffer),
            Txt(said.SetFlattensRenderLayers)))
        if P.res and P.res.frameBuffer == nil then
            P.res.frameBuffer = { SetIsFrameBuffer = said.SetIsFrameBuffer,
                                  SetFlattensRenderLayers = said.SetFlattensRenderLayers }
        end
    end
end

-- 4 (solo): actor alpha and depth. Row 1: the cube in a lower scene, so it surely draws before you - a hole in you =
-- it writes depth. Row 2: the cube and you in one scene, the cube made first; a client that draws see-through actors
-- after the opaque ones shows you whole there whatever it writes, so row 1 decides and row 2 tells the order.
local function BuildAlpha(pg)
    local ALPHA = {
        { 26, 1, 1, 1, false, "Cube alpha 1 in a lower scene before you: the cube in front, a hole in you (control)." },
        { 27, 2, 1, 0.5, false, "Cube alpha 0.5, lower scene: a faint cube and a cube-shaped hole in you = a "
            .. "see-through actor writes depth." },
        { 28, 3, 1, 0.01, false, "Cube alpha 0.01 (invisible), lower scene: a cube-shaped HOLE in you = an invisible "
            .. "actor writes depth." },
        { 29, 4, 1, 0, false, "Cube alpha 0, lower scene: a hole = alpha 0 still writes depth; you whole = it is not "
            .. "drawn at all." },
        { 47, 1, 2, 1, true, "Cube alpha 1 and you in ONE scene, the cube made first: the cube in front (control)." },
        { 48, 2, 2, 0.5, true, "As 47, cube alpha 0.5: a hole in you behind the faint cube = it writes depth before "
            .. "you draw." },
        { 49, 3, 2, 0.01, true, "As 47, cube alpha 0.01: a hole = it writes depth; you whole = drawn after you or no "
            .. "depth (see 28)." },
        { 50, 4, 2, 0, true, "As 47, cube alpha 0: a hole = it still writes depth; you whole = it is not drawn at all." },
    }
    for _, f in ipairs(ALPHA) do
        local t = Tile(pg, f[1], f[2], f[3], f[6])
        if f[5] then
            local sc = Scene(t, 1)
            MeCube(sc, sc, f[4])
            t.long = format("The cube (alpha %s) and you in one scene, the cube's actor made first. A cube-shaped "
                .. "hole in you = it wrote depth before you were drawn. You whole behind it = the client draws "
                .. "see-through actors after the opaque ones (or it writes no depth): tile %d, the same cube in a "
                .. "lower scene, says which.", tostring(f[4]), f[1] - 21)
        else
            MeCube(Scene(t, 1), Scene(t, 3), f[4])
            t.long = format("The cube (actor alpha %s) in a lower scene, you in the upper one, same camera and clips: "
                .. "the cube's scene draws first. A cube-shaped hole in you = an actor at this alpha writes depth "
                .. "(an invisible one would make a stand-in that needs no texture over it).", tostring(f[4]))
        end
        t.data:SetText(format("actor alpha %s, %s", tostring(f[4]), f[5] and "one scene" or "lower scene"))
    end
end

-- 35-37: one turn each; green dots = the corners turned by +30 degrees about that axis, red = by -30.
local function RotTile(pg, n, col, row, axis, setter, caption)
    local t = Tile(pg, n, col, row, caption)
    local sc = Scene(t, 1)
    Orbit(sc, 0, 0, 0, 35, 30, 7.5)
    local a = Cube(sc, 0, 0, 0, 2)
    if a then pcall(a[setter], a, rad(30)) end
    t.draw = function()
        local i = 0
        for _, sg in ipairs({ { 1, GREEN }, { -1, RED } }) do
            local m = AXIS[axis](sg[1] * rad(30))
            for _, c in ipairs(CORNERS2) do
                i = i + 1
                Dot(t, i, sc, Apply(m, c), sg[2])
            end
        end
    end
    t.data:SetText("green: +30 deg about the axis, red: -30")
end

-- 5: particles against depth, the rotation order, frozen poses.
local function BuildParticles(pg)
    local BC = { -13, 0, 3, 0.5, 0, 2.5 }
    local t = Tile(pg, 32, 1, 1, "Big cube before Brutallus, one scene: his glows hidden behind it = particles are "
        .. "depth-tested.")
    local sc = Scene(t, 1)
    LookAt(sc, unpack(BC))
    Creature(sc, BRUTALLUS, 0, 0, 0, PI, 1)
    Cube(sc, -4.5, 0.3, 2.6, 3)
    t = Tile(pg, 33, 2, 1, "As 32, the cube in a lower scene: glows hidden behind it = particles test depth across "
        .. "scenes.")
    local A, B = Scene(t, 1), Scene(t, 3)
    LookAt(A, unpack(BC))
    LookAt(B, unpack(BC))
    Cube(A, -4.5, 0.3, 2.6, 3)
    Creature(B, BRUTALLUS, 0, 0, 0, PI, 1)
    t = Tile(pg, 34, 3, 1, "Brutallus alone: where his glows are (the control for 32 and 33).")
    sc = Scene(t, 1)
    LookAt(sc, unpack(BC))
    Creature(sc, BRUTALLUS, 0, 0, 0, PI, 1)
    RotTile(pg, 35, 4, 1, "y", "SetYaw", "Cube SetYaw(30 deg): do the green or the red dots sit on its corners?")
    RotTile(pg, 36, 1, 2, "p", "SetPitch", "Cube SetPitch(30 deg): green or red dots on its corners?")
    RotTile(pg, 37, 2, 2, "r", "SetRoll", "Cube SetRoll(30 deg): green or red dots on its corners?")
    -- 38: all three; one colour per order (or one order at a time, with its outline), with the signs the user sets
    -- (all + by default: tiles 35-37 showed each turn is +). Round 2 framed it too close for the client's lens and
    -- turned it too little: the camera is now fitted to every candidate corner (Fit), the turn picked so the orders
    -- differ by 0.65 yd or more at some visible corner in this view (see TURN).
    t = Tile(pg, 38, 3, 2, format("Yaw %d, pitch %d, roll %d deg (signs + as in 35-37). Which colour's dots sit on "
        .. "ALL the cube's corners? ", TURN.y, TURN.p, TURN.r)
        .. "|cffff4040red|r Y.P.R, |cff40ff4dgreen|r Y.R.P, |cff598cffblue|r P.Y.R, |cffffd91ayellow|r P.R.Y, "
        .. "|cff33f2f2cyan|r R.Y.P, |cffff66f2pink|r R.P.Y (outer to inner).", 2, 2)
    local big = t
    big.long = "The cube turned by SetYaw, SetPitch and SetRoll together. Each colour is one order of applying them "
        .. "(Y.P.R = yaw of pitch of roll: roll turns the model first). Name the colour whose dots sit on every "
        .. "visible corner; the Orders button shows one order at a time with its outline, the Signs button the other "
        .. "sign sets (all + is what tiles 35-37 showed)."
    -- (its own local: BuildParticles reuses `sc` for tiles 39 and 40 below, and draw runs later - with the
    -- shared one it fitted tile 40's camera and pinned these dots to tile 40's scene)
    local bsc = Scene(big, 1)
    local a = Cube(bsc, 0, 0, 0, 2)
    if a then
        pcall(a.SetYaw, a, rad(TURN.y))
        pcall(a.SetPitch, a, rad(TURN.p))
        pcall(a.SetRoll, a, rad(TURN.r))
    end
    -- (the camera frames every corner of every order and sign set: it stays put while the buttons change the dots)
    local every = {}
    for si = 1, 8 do
        local sy, sp, sr = Signs(si)
        local ang = { y = sy * rad(TURN.y), p = sp * rad(TURN.p), r = sr * rad(TURN.r) }
        for _, o in ipairs(ORDERS) do
            local m = Rot(o[1], ang)
            for _, c in ipairs(CORNERS2) do every[#every + 1] = Apply(m, c) end
        end
    end
    Fit(bsc, every, 0, 0, 0, 215, 30, 0.82)
    big.draw = function()
        Fit(bsc, every, 0, 0, 0, 215, 30, 0.82)
        local sy, sp, sr = Signs(P.signs)
        local ang = { y = sy * rad(TURN.y), p = sp * rad(TURN.p), r = sr * rad(TURN.r) }
        local i = 0
        for k, o in ipairs(ORDERS) do
            local m = Rot(o[1], ang)
            local k8 = {}
            for j, c in ipairs(CORNERS2) do
                i = i + 1
                k8[j] = Apply(m, c)
                if P.order == 0 or P.order == k then
                    Dot(big, i, bsc, k8[j], o[2], P.order == k and 6 or 4)
                else
                    HideDot(big, i)
                end
            end
            -- the chosen order's outline: whether its edges run along the cube's is easier to see than 8 dots
            if P.order == k then
                for e, ed in ipairs(EDGES) do Seg(big, e, bsc, k8[ed[1]], k8[ed[2]], o[2]) end
            end
        end
        if P.order == 0 then
            for _, l in ipairs(big.lines or {}) do l:Hide() end
        end
        big.data:SetText(SignsText(P.signs) .. " (green / red in 35-37 = + / -); " .. OrderButtonText(P.order))
    end
    -- (two narrow buttons in the top right corner, clear of the dots)
    local UI = ns.UI
    if UI and UI.CreateSleekButton then
        local sbtn, obtn
        sbtn = UI:CreateSleekButton(big.f, SignsButtonText(P.signs), 100, 20, function()
            P.signs = P.signs % 8 + 1
            sbtn:SetText(SignsButtonText(P.signs))
            Step("signs", big.draw)
        end)
        sbtn:SetPoint("TOPRIGHT", big.area, "TOPRIGHT", -4, -4)
        sbtn:SetFrameLevel(big.level + 12)
        big.signs = sbtn
        obtn = UI:CreateSleekButton(big.f, OrderButtonText(P.order), 100, 20, function()
            P.order = (P.order + 1) % (#ORDERS + 1)
            obtn:SetText(OrderButtonText(P.order))
            Step("order", big.draw)
        end)
        obtn:SetPoint("TOPRIGHT", sbtn, "BOTTOMRIGHT", 0, -4)
        obtn:SetFrameLevel(big.level + 12)
        big.order = obtn
    end
    -- 39, 40: frozen poses (again once the model has loaded: an animation set before is not kept)
    local FREEZE = {
        { 39, "You with SetAnimation(0, 0, 0, 0): frozen, no breathing.",
          function(x) pcall(x.SetAnimation, x, 0, 0, 0, 0) end },
        { 40, "You with the actor's SetPaused(true): frozen, no breathing.",
          function(x) pcall(x.SetPaused, x, true) end },
    }
    for i, f in ipairs(FREEZE) do
        t = Tile(pg, f[1], i, 3, f[2])
        sc = Scene(t, 1)
        LookAt(sc, -5.5, 0, 1.1, 0, 0, 1)
        local me = Me(sc, 0, 0, 0, PI)
        if me then
            f[3](me)
            me.probeOnLoad = f[3]
        end
    end
end

---------------------------------------------------------------------------
-- 6: stand-in candidates (flat models and boxes from find_flat_prims.py)
---------------------------------------------------------------------------

-- The actor scale that makes a candidate's longest side PRIM_SPAN yd.
local function SpanScale(prim)
    local b = prim.box
    return PRIM_SPAN / max(b[4] - b[1], b[5] - b[2], b[6] - b[3])
end

-- 51-58: one candidate alone, turned about one axis only (axis, deg), scaled so its longest side is PRIM_SPAN yd, its
-- origin (the red dot) on the scene's origin, the yellow outline where its mesh must be drawn; the camera at azimuth
-- az and elevation el (degrees, where it stands seen from the model; below 0 = from below). CheckPrims puts the
-- client's own box for it in the data line.
local function PrimTile(pg, n, col, row, prim, axis, deg, az, el, caption, long)
    local t = Tile(pg, n, col, row, caption)
    t.long = long
    local sc = Scene(t, 1)
    local b = prim.box
    local s = SpanScale(prim)
    local m = Turn(axis, deg)
    local a = Actor(sc)
    if a then
        pcall(a.SetModelByFileID, a, prim.fid)
        Place(a, 0, 0, 0, s)
        if axis then pcall(a[SETTER[axis]], a, rad(deg)) end
    end
    local pts = { ORIGIN }
    for _, c in ipairs(Corners(b)) do pts[#pts + 1] = Xf(m, s, ORIGIN, c) end
    local mid = Xf(m, s, ORIGIN, { (b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2 })
    Fit(sc, pts, mid[1], mid[2], mid[3], az, el, 0.75)
    t.draw = function()
        Fit(sc, pts, mid[1], mid[2], mid[3], az, el, 0.75)
        WireXf(t, sc, b, m, s, ORIGIN, YELLOW)
        Dot(t, 1, sc, ORIGIN, RED)
    end
    P.prims = P.prims or {}
    P.prims[#P.prims + 1] = { key = tostring(n), fid = prim.fid, a = a, t = t }
    t.data:SetText(format("file %d at scale %.4f, %s", prim.fid, s, axis and (SETTER[axis] .. " " .. deg .. " deg")
        or "not turned"))
    return t
end

-- 59-61: a candidate as a stand-in: in a lower scene on the line from the camera to your middle, turned (one axis)
-- to face the camera, covering the left half of you; an opaque teal texture over it; your scene on top (as tile 13
-- with the cube). Sized to your height once your model has loaded, as MeCube does, or at the actor scale `fixed`
-- (61: the scale tile 51 draws the quad with, far above the tiny one the sizing gives these big quads).
local function StandInTile(pg, n, col, row, prim, axis, deg, caption, long, fixed)
    local t = Tile(pg, n, col, row, caption)
    t.long = long
    local A = Scene(t, 2)
    local cover = CreateFrame("Frame", nil, t.area)
    cover:SetAllPoints(t.area)
    cover:SetFrameLevel(t.level + 3)
    local tex = cover:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetColorTexture(TEAL[1], TEAL[2], TEAL[3], 1)
    local B = Scene(t, 5)
    LookAt(A, unpack(ME_CAM))
    LookAt(B, unpack(ME_CAM))
    local m, b = Turn(axis, deg), prim.box
    local lo, hi = { HUGE, HUGE, HUGE }, { -HUGE, -HUGE, -HUGE }     -- (the turned mesh's box, model units)
    for _, c in ipairs(Corners(b)) do
        local v = Xf(m, 1, ORIGIN, c)
        for k = 1, 3 do lo[k], hi[k] = min(lo[k], v[k]), max(hi[k], v[k]) end
    end
    local a = Actor(A)
    if a then
        pcall(a.SetModelByFileID, a, prim.fid)
        pcall(a[SETTER[axis]], a, rad(deg))
    end
    -- its middle on the camera's line to your middle, 0.45 of your height tall (at a fixed scale: as tall as that
    -- makes it), its right edge on your middle line (+y is the screen's left, looking along +x)
    local function Lay(h, foot)
        local u = (ME_CUBE_X - ME_CAM[1]) / -ME_CAM[1]
        local s = fixed or 0.45 * h * u / max(hi[3] - lo[3], 1e-3)
        local zc = ME_CAM[3] + u * (foot + 0.55 * h - ME_CAM[3])
        t.s, t.pos = s, { ME_CUBE_X - s * (lo[1] + hi[1]) / 2, -s * lo[2], zc - s * (lo[3] + hi[3]) / 2 }
        if a then Place(a, t.pos[1], t.pos[2], t.pos[3], s) end
        -- (the scale shown: these big quads shrink to under 0.01, should the client clamp an actor's scale)
        t.data:SetText(format("%d: %s %d, scale %.4f", prim.fid, SETTER[axis], deg, s))
    end
    Lay(1.8, 0)
    local me = Me(B, 0, 0, 0, PI)
    if me then
        me.probeOnLoad = function(mm)
            local bb = BoxOf(mm, "GetActiveBoundingBox")
            if not (bb and #bb == 6) then return end
            local h = bb[6] - bb[3]
            if h < 0.3 or h > 8 then return end
            Lay(h, bb[3])
            if t.draw and P.page == PAGE_OF.flat then pcall(t.draw) end
        end
        if me.probeLoadedAt then pcall(me.probeOnLoad, me) end
    end
    t.draw = function() WireXf(t, B, b, m, t.s, t.pos, YELLOW) end
end

local function BuildFlat(pg)
    PrimTile(pg, 51, 1, 1, ROOF, "y", 30, 240, 40, "198111 DNRDeadMinesCaveRoof: a 4-vertex quad, two-sided, yaw 30. "
        .. "Fills the yellow frame = usable as a flat stand-in.", "198111: 4 vertices, 2 triangles in the plane z = "
        .. "17.06 (model units), 89.7 x 109.1 units, opaque, material flag 0x4 (two-sided), header box = the mesh, "
        .. "no billboard or moving bone. Shrunk to 2.4 yd, SetYaw(30 deg); its faces wind downwards, so seeing it "
        .. "from above also shows the two-sided flag works (52 sees the same quad from below). Filling the outline "
        .. "(the red dot, its origin, under its middle) = it loads and draws exactly where the maths puts it.")
    -- (from below: the side its faces wind towards, so the header-box answer does not hang on the two-sided flag)
    PrimTile(pg, 52, 2, 1, ROOF_HDR, "y", 30, 240, -40, "198110: 51's quad seen from below (its front), header box "
        .. "to z 0. In the frame = box ignored; shifted = placed by it.", "198110 has 198111's mesh but its header "
        .. "(Geo) box runs from z 0 to the quad. Seen from below, the side its faces wind towards, so it draws even "
        .. "if the client ignores the two-sided flag 51 relies on. With SetUseCenterForOrigin(false, false, false) "
        .. "the quad should sit in the frame. Shifted = the client still places file models by their header box: "
        .. "then only candidates whose header box equals the mesh are safe. Empty = not loaded (data line).")
    PrimTile(pg, 53, 3, 1, CATA, "y", 30, 65, 15, "653518, a Cata menu quad: one-sided, front view. Fills the "
        .. "frame = usable as a flat stand-in.", "653518 (interface/glues/models/ui_mainmenu_cata_lowbandwidth/"
        .. "UI_MainMenu_Cata_LowBandwidth.m2): 4 vertices in the plane x = -4.04, 48.9 x "
        .. "33.0 units, front faces +x, opaque, unlit (flag 0x1), one-sided; header box = the mesh. SetYaw(30 deg), "
        .. "seen from in front. Filling the outline = usable as a one-sided flat stand-in (54 checks its back).")
    PrimTile(pg, 54, 4, 1, CATA, "y", 30, 245, 15, "653518 from behind: an empty frame = one-sided (back faces "
        .. "culled); drawn = both of its sides draw.", "The same quad as 53 seen from behind. Nothing in the outline "
        .. "= its back faces are culled, as a one-sided stand-in needs (it then hides nothing seen from behind a "
        .. "wall). Drawn = the client draws both sides of it.")
    PrimTile(pg, 55, 1, 2, LEGION, "y", 30, 65, 15, "1396283, a Legion menu quad: one-sided, wider. Fills the "
        .. "frame = usable as a flat stand-in.", "1396283 (interface/glues/models/ui_mainmenu_legion/"
        .. "UI_MainMenu_Legion_LowBandwidth.m2): 4 vertices in the plane x = -7.05, 63.8 x "
        .. "33.0 units (a wider shape than 653518), front faces +x, opaque, unlit, one-sided, header box = the mesh. "
        .. "SetYaw(30 deg), seen from in front.")
    PrimTile(pg, 56, 2, 2, BLANKET, "y", 30, 240, 45, "200893 G_Blanket (control): alpha key + projected flag. "
        .. "Fills the frame = a plain quad; holes = see-through texels.", "200893 world/goober/G_Blanket.m2: 4 "
        .. "vertices in the plane z = 0.048, 1.21 x 1.68 units, front faces +z, one-sided, alpha key: its see-through "
        .. "texels draw nothing and write no depth. Unlike the other candidates its batch also has flag 0x4 "
        .. "('projected texture' on wowdev, as on spell ground effects; find_flat_prims.py now refuses it) and the "
        .. "alpha-key shader 0x10: an odd result (shifted, smeared, no depth) may come from that flag, not the key.")
    PrimTile(pg, 57, 3, 2, SCALE100, "y", 30, 215, 30, "219357 world/scale/100x100.m2: a 2.78 yd box on its "
        .. "origin. Fills the frame = usable as a box stand-in.", "219357 world/scale/100x100.m2 (one of the scale "
        .. "boxes 50x50 .. 1000x1000): 12 triangles, opaque, one-sided, its base on the origin (z 0 .. 2.78), x and y "
        .. "centred. Another clean box besides the unit cube 167145.")
    PrimTile(pg, 58, 4, 2, ELEVATOR, "y", 30, 215, 35, "203154 IronforgeHouseElevator: a 3.94 x 3.94 x 0.61 yd slab. "
        .. "Fills the frame = usable as a floor stand-in.", "203154 world/khazmodan/ironforge/passivedoodads/"
        .. "elevators/IronforgeHouseElevator.m2: a box of 12 triangles, 3.94 x 3.94 x 0.61 units centred on its "
        .. "origin, opaque, one-sided. A thick square plate: a floor or a wall stand-in with some depth.")
    StandInTile(pg, 59, 1, 3, ROOF, "p", 90, "198111 as a stand-in: lower scene, before you, teal texture between. "
        .. "A rectangular hole in you = it hides you.", "The two-sided quad 198111 stood up by SetPitch(90 deg) to "
        .. "face the camera, in a scene under an opaque teal texture; you in a scene over it. A hole in you the "
        .. "shape of the yellow outline (teal showing through) = a flat stand-in writes depth and hides a model "
        .. "behind a room surface per pixel: one actor per wall instead of many cubes. No hole while 61 has one = "
        .. "the client clamps or drops the tiny actor scale (the data line, about 0.006), not a quad failure.")
    StandInTile(pg, 60, 2, 3, CATA, "y", 180, "As 59 with 653518 (one-sided, turned to face the camera): a "
        .. "rectangular hole in you = it hides you per pixel.", "As 59 with the one-sided quad 653518, SetYaw(180 "
        .. "deg) so its front faces the camera. A hole in you the shape of the outline = it writes depth. No hole "
        .. "while 59 has one = its unlit material or its facing stops it.")
    StandInTile(pg, 61, 3, 3, ROOF, "p", 90, "Control for 59: that quad at 51's scale, over your whole left half. "
        .. "Hole here but not in 59 = 59's tiny scale fails.", "198111 as in 59 but at the actor scale "
        .. "tile 51 draws it with (about 0.022: its longest side 2.4 yd), so it is about 2 yd tall and covers your "
        .. "whole left half. Teal over your left half here while 59 has no hole = the client clamps or drops the "
        .. "very small scale 59 needs (about 0.006, its data line), not a flat stand-in failure; no hole in either "
        .. "= the quad writes no depth from a lower scene.", SpanScale(ROOF))
    -- (what the client says of 51-58, 2 and 6 s after the page was built: see CheckPrims)
    C_Timer.After(2, function() Step("prims 2 s", P.CheckPrims) end)
    C_Timer.After(6, function() Step("prims 6 s", P.CheckPrims) end)
end

---------------------------------------------------------------------------
-- 8: the stand-in quad turned flat and drawn big (stand-ins v2 drew floor quads floating over the floor in game)
---------------------------------------------------------------------------

-- 71-78: one model turned by yaw, pitch and roll (degrees, all three set as the stand-ins set them: Y.P.R, tile 38)
-- at actor scale s (nil: its longest side PRIM_SPAN yd), origin on the scene's origin; the yellow outline where the
-- maths puts its mesh, the camera at azimuth az / elevation el. Outline and model apart = the client does not turn or
-- scale it as the stand-ins assume at that setting.
local function PoseTile(pg, n, col, row, prim, yaw, pitch, roll, s, az, el, caption, long, pivot)
    local t = Tile(pg, n, col, row, caption)
    t.long = long
    local sc = Scene(t, 1)
    local b = prim.box
    s = s or SpanScale(prim)
    local m = Rot("ypr", { y = rad(yaw), p = rad(pitch), r = rad(roll) })
    local a = Actor(sc)
    -- pivot: 71-78 showed the client turns a model about the middle of its box, not its origin; placed for that
    -- (position = minus the box's middle: the middle at the origin, unmoved by the turn), the outline (the mesh turned
    -- about that middle) must be filled
    local c = { (b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2 }
    local pos = ORIGIN
    if pivot then
        local rc = Xf(m, s, ORIGIN, c)
        pos = { -rc[1], -rc[2], -rc[3] }
    end
    if a then
        pcall(a.SetModelByFileID, a, prim.fid)
        if pivot then
            pcall(a.SetScale, a, s)
            pcall(a.SetPosition, a, -c[1], -c[2], -c[3])
        else
            Place(a, 0, 0, 0, s)
        end
        pcall(a.SetYaw, a, rad(yaw))
        pcall(a.SetPitch, a, rad(pitch))
        pcall(a.SetRoll, a, rad(roll))
    end
    local pts = { ORIGIN }
    for _, k in ipairs(Corners(b)) do pts[#pts + 1] = Xf(m, s, pos, k) end
    local mid = Xf(m, s, pos, c)
    Fit(sc, pts, mid[1], mid[2], mid[3], az, el, 0.75)
    t.draw = function()
        Fit(sc, pts, mid[1], mid[2], mid[3], az, el, 0.75)
        WireXf(t, sc, b, m, s, pos, YELLOW)
        Dot(t, 1, sc, ORIGIN, RED)
    end
    t.data:SetText(format("%d: yaw %d, pitch %d, roll %d, scale %.3f%s", prim.fid, yaw, pitch, roll, s,
        pivot and ", by its middle" or ""))
    return t
end

local function BuildTilted(pg)
    local F = "Fills the yellow outline = drawn where the stand-ins assume. Tilted, shifted or another size = not."
    PoseTile(pg, 71, 1, 1, CATA, 0, -90, 0, nil, 200, 45, "71. 653518 laid flat as a floor quad (pitch -90), "
        .. "small. " .. F, "The stand-ins lay this one-sided quad flat on floors with SetPitch(-90 deg): its front "
        .. "(+x) then faces up. Seen from above. In the outline = pitch -90 works at a small scale.")
    PoseTile(pg, 72, 2, 1, CATA, 0, -90, 0, 0.3, 200, 45, "72. As 71 at scale 0.3 (15 x 10 yd), like a big floor "
        .. "stand-in. " .. F, "Floor stand-ins reach scale 0.64. Tilted or lifted here but not in 71 = the client "
        .. "turns or scales big actors differently (the floating floor quads).")
    PoseTile(pg, 73, 3, 1, CATA, 0, -85, 0, 0.3, 200, 45, "73. As 72 at pitch -85: tilted 5 deg, one long edge "
        .. "higher. Compare with 72.", "Should look visibly tilted: one long edge about 0.9 yd above the other. If 72 "
        .. "looks like this, the client stops pitch short of 90 degrees.")
    PoseTile(pg, 74, 4, 1, CATA, 0, -60, 0, 0.3, 200, 30, "74. Pitch -60 at scale 0.3 (a slope stand-in). " .. F,
        "A sloped quad as on ramps: big pitch but not 90.")
    PoseTile(pg, 75, 1, 2, CATA, 30, -90, 0, 0.3, 200, 45, "75. Floor quad with yaw 30 (pitch -90), scale 0.3, as "
        .. "most floor stand-ins are turned. " .. F, "Yaw and pitch -90 together: at pitch 90 yaw and roll turn about "
        .. "the same axis, a case the client might handle differently.")
    PoseTile(pg, 76, 2, 2, CATA, 30, -90, 40, 0.3, 200, 45, "76. As 75 with roll 40 too. " .. F, "Yaw 30, pitch -90, "
        .. "roll 40: at pitch 90 the roll adds to the yaw (gimbal lock); the outline assumes Y.P.R exactly.")
    PoseTile(pg, 77, 3, 2, CATA, 0, 0, 0, 0.5, 70, 10, "77. Not turned, scale 0.5 (24 x 16 yd): a big wall stand-in. "
        .. F, "Only the scale is big here. Wrong here = the scale itself is the problem, not the turn.")
    PoseTile(pg, 78, 4, 2, CATA, 0, 90, 0, 0.3, 200, -45, "78. Pitch +90: a ceiling quad facing down, seen from "
        .. "below. " .. F, "The front then faces down; seen from below it must fill the outline.")
    -- 79-82: placed for a turn about the box's middle (what 71-78 showed): these must all fill their outlines
    local G = "Placed by its middle (the client turns models about their box middle). Must fill the outline."
    PoseTile(pg, 79, 1, 3, CATA, 0, -90, 0, 0.3, 200, 45, "79. As 72, placed by its middle. " .. G, "72's floor "
        .. "quad placed for a turn about its box's middle: the red dot is its middle now.", true)
    PoseTile(pg, 80, 2, 3, CATA, 30, -90, 40, 0.3, 200, 45, "80. As 76 (yaw 30, pitch -90, roll 40), placed by "
        .. "its middle. " .. G, "76's turn placed for a turn about the box's middle.", true)
    PoseTile(pg, 81, 3, 3, CATA, 30, 0, 0, 0.3, 65, 15, "81. Yaw 30 only, scale 0.3 (a wall), placed by its "
        .. "middle. " .. G, "Wall stand-ins turn by yaw only; their middle is 4 units off the origin sideways.", true)
    PoseTile(pg, 82, 4, 3, CATA, 0, -60, 0, 0.3, 200, 30, "82. As 74 (pitch -60, a slope), placed by its middle. "
        .. G, "74's slope quad placed for a turn about the box's middle.", true)
end

---------------------------------------------------------------------------
-- 7: cost, and every automatic result
---------------------------------------------------------------------------

local COST_W, COST_H = 560, 300

local function CostLine(c)
    return format("%d paused cubes: setup %.0f ms (%.3f ms each, %d new actors), fps %.0f -> %.0f (lowest %.0f)",
        c.n, c.setupMs or 0, c.perActorMs or 0, c.made or 0, c.fpsBefore or 0, c.fpsAfter or 0, c.fpsMin or 0)
end

-- n paused unit cubes on a grid in the cost scene (actors are kept and reused; the rest are hidden), made 250 a frame
-- (debugprofilestop round each batch); then the frame rate for 3 s. Plain actors, as a proxy route would make them:
-- ModelSceneActorTemplate gives every actor a Lua OnUpdate, which would be measured as well.
function P.Spawn(pg, n)
    if pg.job or not pg.costScene then return end
    local sc, pool = pg.costScene, pg.pool
    local side = math.ceil(sqrt(max(n, 1)))
    local sp = 1.6
    local w = side * sp
    Orbit(sc, w / 2, w / 2, 0, 45, 50, w * 1.6 + 6)    -- (all of them in view: culled ones would cost less)
    for i = n + 1, #pool do pcall(pool[i].Hide, pool[i]) end
    local job = { n = n, i = 0, ms = 0, made = 0, fps0 = GetFramerate() or 0, el = 0, next = 0, samples = {} }
    pg.job = job
    pg.costInfo:SetText(format("Making %d cubes...", n))
    pg.costArea:SetScript("OnUpdate", function(_, el)
        if job.i < n then
            local t0 = debugprofilestop()
            local stop = min(n, job.i + 250)
            for i = job.i + 1, stop do
                local a = pool[i]
                if not a then
                    local okA, na = pcall(sc.CreateActor, sc)
                    if okA and na then
                        a = na
                        pool[i] = a
                        pcall(a.SetUseCenterForOrigin, a, false, false, false)
                        pcall(a.SetModelByFileID, a, CUBE)
                        job.made = job.made + 1
                    end
                end
                if a then
                    pcall(a.SetPosition, a, ((i - 1) % side) * sp, floor((i - 1) / side) * sp, 0.5)
                    if a.SetPaused then pcall(a.SetPaused, a, true) else pcall(a.SetAnimation, a, 0, 0, 0, 0) end
                    pcall(a.Show, a)
                end
            end
            job.i = stop
            job.ms = job.ms + (debugprofilestop() - t0)
            return
        end
        job.el = job.el + el
        if job.el >= job.next then
            job.samples[#job.samples + 1] = GetFramerate() or 0
            job.next = job.next + 0.25
        end
        if job.el < 3 then return end
        pg.costArea:SetScript("OnUpdate", nil)
        pg.job = nil
        local sum, low = 0, nil
        for _, v in ipairs(job.samples) do
            sum = sum + v
            low = low and min(low, v) or v
        end
        local c = { n = n, made = job.made, setupMs = Round(job.ms, 1), perActorMs = Round(job.ms / max(n, 1), 4),
                    fpsBefore = Round(job.fps0, 1), fpsAfter = Round(sum / max(#job.samples, 1), 1),
                    fpsMin = Round(low or 0, 1) }
        if P.res then P.res.cost[tostring(n)] = c end
        ns:Print("3D probe cost: %s.", CostLine(c))
        P.RefreshCost(pg)
    end)
end

function P.RefreshCost(pg)
    local lines = {}
    local cost = P.res and P.res.cost or {}
    for _, n in ipairs({ 250, 1000, 4000 }) do
        local c = cost[tostring(n)]
        if c then lines[#lines + 1] = CostLine(c) end
    end
    pg.costInfo:SetText(#lines > 0 and tconcat(lines, "\n") or "No count pressed yet.")
end

local function BuildCost(pg)
    local UI = ns.UI
    local area = CreateFrame("Frame", nil, pg)
    area:SetPoint("TOPLEFT")
    area:SetSize(COST_W, COST_H)
    local bg = area:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.11, 0.12, 0.15, 1)
    pg.costArea, pg.pool = area, {}
    pg.costScene = Scene({ area = area, level = area:GetFrameLevel() }, 1)
    local cap = pg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cap:SetPoint("TOPLEFT", COST_W + 140, 0)
    cap:SetPoint("TOPRIGHT", 0, 0)
    cap:SetJustifyH("LEFT")
    cap:SetJustifyV("TOP")
    cap:SetHeight(80)
    cap:SetText("41. Cost: paused unit cubes in one scene (plain actors, no template). Press a count; the setup time "
        .. "and the frame rate before and after go to the chat and the saved results. Clear hides them.")
    for i, n in ipairs({ 250, 1000, 4000, 0 }) do
        local b = UI:CreateSleekButton(pg, n > 0 and (n .. " cubes") or "Clear", 120, 22, function()
            if n > 0 then
                P.Spawn(pg, n)
            elseif not pg.job then
                for _, a in ipairs(pg.pool) do pcall(a.Hide, a) end
            end
        end)
        b:SetPoint("TOPLEFT", COST_W + 10, -(i - 1) * 28)
    end
    local info = pg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("TOPLEFT", COST_W + 140, -86)
    info:SetPoint("TOPRIGHT", 0, -86)
    info:SetHeight(COST_H - 86)
    info:SetJustifyH("LEFT")
    info:SetJustifyV("TOP")
    pg.costInfo = info
    P.RefreshCost(pg)
    local data = pg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    data:SetPoint("TOPLEFT", 0, -(COST_H + 10))
    data:SetPoint("TOPRIGHT", 0, -(COST_H + 10))
    data:SetHeight(3 * ROW_H - COST_H - 18)
    data:SetJustifyH("LEFT")
    data:SetJustifyV("TOP")
    P.dataText = data
    data:SetText(tconcat(P.SummaryLines(P.res), "\n"))
end

-- key, tab text, builder; solo: the page opens showing one tile at a time; lazy: built only when its tab is opened,
-- never by the run itself (page 6's stock models: should one of them crash the client, the crash is then pinned on
-- opening that page, and every later run still shows the other pages).
local PAGES = {
    { key = "loose", name = "1 Loose files", build = BuildLoose },
    { key = "depth", name = "2 Depth", build = BuildDepth },
    { key = "flag", name = "3 Flag (solo)", build = BuildFlags, solo = true },
    { key = "alpha", name = "4 Alpha (solo)", build = BuildAlpha, solo = true },
    { key = "turns", name = "5 Particles & turns", build = BuildParticles },
    { key = "flat", name = "6 Flat models", build = BuildFlat, lazy = true },
    { key = "cost", name = "7 Cost & data", build = BuildCost },
    { key = "tilted", name = "8 Tilted & big", build = BuildTilted, lazy = true },
}
for i, def in ipairs(PAGES) do PAGE_OF[def.key] = i end

---------------------------------------------------------------------------
-- Automatic measurements
---------------------------------------------------------------------------

-- The names of an object's methods: its metatable's __index table and its own function fields.
local function Names(obj)
    local seen, out = {}, {}
    local function add(t)
        if type(t) ~= "table" then return end
        for k, v in pairs(t) do
            if type(k) == "string" and type(v) == "function" and not seen[k] then
                seen[k] = true
                out[#out + 1] = k
            end
        end
    end
    local mt = getmetatable(obj)
    if type(mt) == "table" then add(rawget(mt, "__index")) end
    add(obj)
    tsort(out)
    return out
end

-- Panel 0: every method of ModelScene, its actor, PlayerModel and Frame (and OffScreenFrame / UiCamera when the client
-- makes them: only in a guarded run, see FRAMES), SetAllowOverlappedModels on a fresh scene.
function P.DumpMethods(res)
    res.methods, res.counts, res.create = {}, {}, {}
    local function keep(name, obj)
        local list = Names(obj)
        res.methods[name] = tconcat(list, " ")
        res.counts[name] = #list
    end
    local holder = CreateFrame("Frame", nil, UIParent)
    holder:Hide()                                       -- (everything made here stays hidden)
    keep("Frame", holder)
    local ok, sc = pcall(CreateFrame, "ModelScene", nil, holder)
    if ok and sc then
        keep("ModelScene", sc)
        local oka, a = pcall(sc.CreateActor, sc)
        if oka and a then keep("ModelSceneActor", a) end
        res.overlapDefault = Answer(pcall(sc.GetAllowOverlappedModels, sc))
    end
    local okp, pm = pcall(CreateFrame, "PlayerModel", nil, holder)
    if okp and pm then keep("PlayerModel", pm) end
    local why = SkipReason(FRAMES)
    for _, kind in ipairs({ "OffScreenFrame", "UiCamera" }) do
        if why then
            res.create[kind] = "not asked (" .. why .. ")"
        else
            local okc, f = pcall(CreateFrame, kind, nil, holder)
            if okc and f then
                res.create[kind] = "yes"
                keep(kind, f)
                pcall(f.Hide, f)
            else
                res.create[kind] = "no: " .. Short(f)
            end
        end
    end
end

-- Which way the client counts pitch (the point looked at must land mid-height) and on which side it draws +y, with
-- the small empty measuring scene. -> whether the pitch sign changed.
function P.Calibrate()
    local sc = P.measure
    if not sc then return false end
    local h = sc:GetHeight() or 0
    if h <= 0 then return false end
    local before = P.pitchSign
    local function centred()
        LookAt(sc, -10, 0, 5, 0, 0, 0)
        local _, y = Proj(sc, 0, 0, 0)
        return y and abs(y - h / 2) < h / 4
    end
    if not centred() then
        P.pitchSign = -P.pitchSign
        if not centred() then P.pitchSign = before end
    end
    return P.pitchSign ~= before
end

local CLIPS = { { 0.5, 500 }, { 0.5, 50 }, { 2, 500 }, { 0.2, 300 }, { 1, 20 } }
local DISTS = { 1, 5, 10, 30, 100 }

-- Panel 7: what Project3DPointTo2D's depth is - points straight ahead at known distances under several clip ranges
-- (is it scaled per scene's own near / far?).
function P.Measure(res)
    if P.Calibrate() then P.Recam() end
    local sc = P.measure
    res.pitchSign = P.pitchSign
    if not sc then return end
    LookAt(sc, 0, 0, 0, 1, 0, 0)
    local cx = Proj(sc, 10, 0, 0)
    local px = Proj(sc, 10, 3, 0)
    res.yDrawn = (cx and px) and (px > cx and "right" or "left") or "?"
    res.depth = {}
    for _, c in ipairs(CLIPS) do
        pcall(sc.SetCameraNearClip, sc, c[1])
        pcall(sc.SetCameraFarClip, sc, c[2])
        for _, d in ipairs(DISTS) do
            local r = Pack(pcall(sc.Project3DPointTo2D, sc, d, 0, 0))
            local depth
            if not r[1] then
                depth = "error: " .. Short(r[2])
            elseif type(r[4]) == "number" then
                depth = Round(r[4], 6)
            else
                depth = Val(r[4])                       -- (nothing: the point is outside the clips)
            end
            res.depth[#res.depth + 1] = { near = c[1], far = c[2], dist = d, depth = depth }
        end
    end
    pcall(sc.SetCameraNearClip, sc, NEAR)
    pcall(sc.SetCameraFarClip, sc, FAR)
end

---------------------------------------------------------------------------
-- Results text
---------------------------------------------------------------------------

local function LooseShort(r)
    if r.skipped then return "skipped" end
    local l = r.loaded6s
    if l == nil then l = r.loaded2s end
    if l == true then return "LOADED" end
    if l == nil then return "set " .. tostring(r.set) end
    return "not loaded (set " .. tostring(r.set) .. ")"
end

-- The results as text lines (the chat summary is the first ones; page 5 shows them all).
function P.SummaryLines(res)
    if not res then return { "No results yet." } end
    local L = {}
    L[#L + 1] = format("Build %s. Run: %s%s, %s%s. Errors: %d%s.", tostring(res.build or "?"), tostring(res.mode),
        res.only and (" (only " .. res.only .. ")") or "", res.finished and "finished" or "running",
        res.seconds and format(" in %.1f s", res.seconds) or "", #(res.errors or {}),
        (res.errors and res.errors[1]) and (" (first: " .. res.errors[1] .. ")") or "")
    local me = res.me
    if me then
        L[#L + 1] = format("Your character: loaded in %d of %d tiles (tries %s)%s.", me.loaded, me.tiles,
            #me.set > 0 and tconcat(me.set, " ") or "-", me.failed and format(", %d never loaded (set %s, loaded %s)",
            me.failed, tostring(me.lastSet), tostring(me.lastLoaded)) or "")
    end
    local parts = {}
    for _, key in ipairs(KEY_ORDER) do
        local r = res.loose and res.loose[key]
        if r then parts[#parts + 1] = key .. " " .. LooseShort(r) end
    end
    L[#L + 1] = "Models: " .. (#parts > 0 and tconcat(parts, ", ") or "-") .. "."
    local counts = {}
    for _, name in ipairs({ "ModelScene", "ModelSceneActor", "PlayerModel", "Frame", "OffScreenFrame", "UiCamera" }) do
        if res.counts and res.counts[name] then counts[#counts + 1] = name .. " " .. res.counts[name] end
    end
    L[#L + 1] = format("Methods: %s. CreateFrame OffScreenFrame: %s; UiCamera: %s.", tconcat(counts, ", "),
        Short(res.create and res.create.OffScreenFrame or "-"), Short(res.create and res.create.UiCamera or "-"))
    L[#L + 1] = format("SetAllowOverlappedModels on a fresh scene: %s (after setting it: %s). Pitch sign %s (+ = a "
        .. "positive pitch looks down). +y drawn on the %s looking along +x.", tostring(res.overlapDefault),
        res.overlapSet == nil and "not set yet" or tostring(res.overlapSet), Txt(res.pitchSign), Txt(res.yDrawn))
    if res.depth and #res.depth > 0 then
        local rows, cur, key = {}, nil, nil
        for _, d in ipairs(res.depth) do
            local k = d.near .. "-" .. d.far
            if k ~= key then
                key = k
                cur = {}
                rows[#rows + 1] = { k, cur }
            end
            cur[#cur + 1] = tostring(d.depth)
        end
        local txt = {}
        for _, r in ipairs(rows) do txt[#txt + 1] = "clip " .. r[1] .. ": " .. tconcat(r[2], " ") end
        L[#L + 1] = "Project3DPointTo2D depth of points 1, 5, 10, 30, 100 yd ahead: " .. tconcat(txt, "; ") .. "."
    end
    local cost = {}
    for _, n in ipairs({ 250, 1000, 4000 }) do
        local c = res.cost and res.cost[tostring(n)]
        if c then cost[#cost + 1] = CostLine(c) end
    end
    if #cost > 0 then L[#L + 1] = "Cost: " .. tconcat(cost, "; ") .. "." end
    -- page 6: each candidate loaded or not (its tile number first; the client's boxes are in the saved results)
    local keys = {}
    for k in pairs(res.prims or {}) do keys[#keys + 1] = k end
    tsort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
    local prims = {}
    for _, k in ipairs(keys) do
        local r = res.prims[k]
        prims[#prims + 1] = format("%s (%s) %s", k, tostring(r.fid), r.loaded == true and "loaded"
            or ("not loaded: " .. tostring(r.loaded)))
    end
    if #prims > 0 then L[#L + 1] = "Stand-in candidates (page 6 tiles): " .. tconcat(prims, ", ") .. "." end
    return L
end

function P.PrintSummary(res)
    ns:Print("3D probe results:")
    for _, line in ipairs(P.SummaryLines(res)) do ns:Print("  %s", line) end
end

function P.PrintCrash()
    local st = State()
    if not (st and st.crashed) then return end
    local c = type(st.crash) == "table" and st.crash or {}
    local when = (type(date) == "function" and tonumber(c.armedAt)) and date("%H:%M", c.armedAt) or "?"
    ns:Print("the 3D probe armed at %s never finished: the game most likely crashed or closed while it loaded a "
        .. "loose model file or made a test frame%s (or, if page 6 was opened, one of its stock models). Nothing "
        .. "loose is loaded again by itself.", when,
        c.only and (" (only " .. c.only .. ")") or "")
    ns:Print("  /dz 3d probe - every test but the loose files; /dz 3d probe only <%s> confirm - one file (or the "
        .. "frames) per run, finds the one that crashes; /dz 3d probe reset - clear this notice, keep the results.",
        KEYS)
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

-- The open page's overlays (in solo the shown tile's only: the others' lines and dots hidden with their scenes).
function P.Redraw()
    local pg = P.pages and P.pages[P.page]
    if not pg then return end
    local only = P.SoloTile()
    for _, t in ipairs(pg.tiles) do
        local on = not only or t == only
        if t.draw and on then Step("draw " .. t.n, t.draw) end
        if t.ov then t.ov:SetShown(on) end
    end
end

---------------------------------------------------------------------------
-- Solo: one tile's scenes at a time
---------------------------------------------------------------------------

-- The tile shown alone on the open page, or nil (every tile shown).
function P.SoloTile()
    local pg = P.pages and P.pages[P.page]
    local k = pg and P.solo[P.page]
    return k and pg.tiles[k] or nil
end

-- With a solo tile, only its scenes are shown: every other scene of the probe is hidden, on every page and outside
-- the window (tile 18's), as is the empty measuring scene - nothing else draws into the shared depth buffer that
-- frame. The other tiles' captions are greyed, the solo tile's edge gold. Without one, every scene is shown again (one
-- outside the window only while its page is visible).
function P.ApplySolo()
    local only = P.SoloTile()
    for _, sc in ipairs(P.scenes or {}) do
        local show = not only or sc.probeTile == only
        if sc.probeOuter then show = show and sc.probeOuter:IsVisible() end
        sc:SetShown(show and true or false)
    end
    local UI = ns.UI
    local pg = P.pages and P.pages[P.page]
    for _, t in ipairs(pg and pg.tiles or {}) do
        local on = not only or t == only
        local c = on and 1 or 0.4
        t.cap:SetTextColor(c, c, c)
        c = on and 0.5 or 0.3
        t.data:SetTextColor(c, c, c)
        if t.signs then t.signs:SetShown(on) end            -- (tile 38's buttons)
        if t.order then t.order:SetShown(on) end
        if UI and UI.SetEdgeColor and t.area.edges then
            if only and on then
                UI:SetEdgeColor(t.area, 1, 0.82, 0, 1)
            else
                UI:SetEdgeColor(t.area, 0.32, 0.32, 0.36, 1)
            end
        end
    end
    P.RefreshBar()
    P.Redraw()
end

-- Prev / Next: the solo tile d tiles on (turning solo on at the first or last tile).
function P.SoloStep(d)
    local pg = P.pages and P.pages[P.page]
    if not (pg and #pg.tiles > 0) then return end
    local k = P.solo[P.page]
    if k then
        k = (k - 1 + d) % #pg.tiles + 1
    else
        k = d > 0 and 1 or #pg.tiles
    end
    P.solo[P.page] = k
    P.ApplySolo()
end

-- Solo on (at the tile it was on) or off (every tile).
function P.SoloToggle()
    local pg = P.pages and P.pages[P.page]
    if not (pg and #pg.tiles > 0) then return end
    P.soloLast = P.soloLast or {}
    if P.solo[P.page] then
        P.soloLast[P.page] = P.solo[P.page]
        P.solo[P.page] = false
    else
        P.solo[P.page] = P.soloLast[P.page] or 1
    end
    P.ApplySolo()
end

function P.RefreshBar()
    local b = P.bar
    if not b then return end
    local pg = P.pages and P.pages[P.page]
    local n = pg and #pg.tiles or 0
    for _, w in ipairs({ b.prev, b.next, b.mode, b.label, b.text }) do w:SetShown(n > 0) end
    if n == 0 then return end
    local k = P.solo[P.page]
    local t = k and pg.tiles[k]
    b.mode:SetText(t and "All tiles" or "Solo")
    if t then
        b.label:SetText(format("Solo: tile %d (%d of %d)", t.n, k, n))
        b.text:SetText(t.n .. ". " .. (t.long or t.caption or ""))
    else
        b.label:SetText(format("All %d tiles shown", n))
        b.text:SetText("Every tile of this page draws at once. Solo (or Prev / Next) shows one tile's scenes alone: "
            .. "every model scene shares one depth buffer, so only then can no other tile draw into it.")
    end
end

-- Every scene's camera again (after the pitch sign changed), then the overlays.
function P.Recam()
    for _, sc in ipairs(P.scenes or {}) do
        local c = sc.probeCam
        if c and sc ~= P.measure then LookAt(sc, c[1], c[2], c[3], c[4], c[5], c[6]) end
    end
    P.Redraw()
end

function P.SetStatus()
    if not P.status then return end
    local res = P.res
    local what = ""
    if res then
        what = (res.mode == "safe" and "Safe run, no loose files")
            or (res.only and ("Only " .. OnlyName(res.only))) or "Full run"
    end
    local state = (res and res.finished) and "done - screenshot each page, then /reload" or "measuring..."
    P.status:SetText(format("%s, %s: %s", what, tostring(res and res.build or "?"), state))
end

function P.SetPage(i)
    P.page = i
    for j, pg in ipairs(P.pages) do
        if j == i and not pg.built then
            pg.built = true
            if P.solo[j] == nil then P.solo[j] = PAGES[j].solo and 1 or false end
            Step("page " .. j, PAGES[j].build, pg)
        end
        pg:SetShown(j == i)
        P.tabs[j]:SetActive(j == i)
    end
    if i == PAGE_OF.cost and P.dataText then
        P.dataText:SetText(tconcat(P.SummaryLines(P.res), "\n"))
    end
    Step("solo", P.ApplySolo)
    -- (the overlays once the page is laid out, and again later: a scene sized by its anchors only knows its size
    -- after the client has laid it out)
    C_Timer.After(0.05, function() if P.page == i then P.Redraw() end end)
    C_Timer.After(0.5, function() if P.page == i then P.Redraw() end end)
end

-- Under the page: the solo bar - Prev / Next / Solo-or-all, which tile, the status on the right; then the solo
-- tile's full explanation (the captions are short). Its own step: the window works without it.
local function BuildBar(content)
    local UI = ns.UI
    local bar = CreateFrame("Frame", nil, content)
    bar:SetPoint("TOPLEFT", 6, -(34 + 3 * ROW_H + 2))
    bar:SetPoint("TOPRIGHT", -6, -(34 + 3 * ROW_H + 2))
    bar:SetHeight(BAR_H - 4)
    local prev = UI:CreateSleekButton(bar, "< Prev", 64, 20, function() P.SoloStep(-1) end)
    prev:SetPoint("TOPLEFT", 0, 0)
    local nxt = UI:CreateSleekButton(bar, "Next >", 64, 20, function() P.SoloStep(1) end)
    nxt:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    local mode = UI:CreateSleekButton(bar, "All tiles", 80, 20, function() P.SoloToggle() end)
    mode:SetPoint("LEFT", nxt, "RIGHT", 4, 0)
    local label = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", mode, "RIGHT", 10, 0)
    label:SetSize(170, 20)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    local status = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("LEFT", label, "RIGHT", 6, 0)
    status:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    status:SetHeight(20)
    status:SetJustifyH("RIGHT")
    status:SetWordWrap(false)
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4)
    text:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    text:SetHeight(BAR_H - 30)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    P.bar = { frame = bar, prev = prev, next = nxt, mode = mode, label = label, text = text }
    P.status = status
end

function P.Show(page)
    local UI = ns.UI
    if not P.win then
        if not (UI and UI.CreateWindow) then
            ns:Print("the 3D probe needs the addon's window code, which did not load.")
            return
        end
        P.scenes, P.loaded = P.scenes or {}, P.loaded or {}
        local f = UI:CreateWindow("DisasterZoneProbe3D", "DisasterZone 3D probe", WIN_W, WIN_H,
            { noSavePosition = true })
        P.win = f
        local content = f.content
        P.tabs, P.pages = {}, {}
        local x = 2
        for i, def in ipairs(PAGES) do
            local tab = UI:CreateUnderlineTab(content, def.name, function() P.SetPage(i) end, "page")
            tab:SetPoint("TOPLEFT", x, -2)
            x = x + tab:GetWidth() + 4
            P.tabs[i] = tab
            local pg = CreateFrame("Frame", nil, content)
            pg:SetPoint("TOPLEFT", 6, -34)
            pg:SetSize(4 * TW + 3 * GAP, 3 * ROW_H)
            pg:Hide()
            pg.tiles = {}
            P.pages[i] = pg
        end
        Step("bar", BuildBar, content)
        -- a small empty scene for the projection measurements (it draws nothing)
        local ok, m = pcall(CreateFrame, "ModelScene", nil, content)
        if ok and m then
            m:SetSize(64, 64)
            m:SetPoint("BOTTOMRIGHT", -2, 2)
            pcall(m.SetCameraFieldOfView, m, FOV)
            pcall(m.SetCameraNearClip, m, NEAR)
            pcall(m.SetCameraFarClip, m, FAR)
            P.measure = m
            P.scenes[#P.scenes + 1] = m
            P.Calibrate()
        end
    end
    P.win:Show()
    P.SetStatus()
    P.SetPage(page or P.page or 1)
end

---------------------------------------------------------------------------
-- The run
---------------------------------------------------------------------------

-- Other 3D views of the addon open under the probe would write depth into the same pixels first (every scene shares
-- one depth buffer: what tile 18 tests) and spoil tiles, so they are closed for the run. (After the guarded reload
-- none is open; a safe run may find one.)
local function CloseOtherScenes()
    local closed = {}
    local board = ns.StrategyBoard
    if board and board.IsShown and board:IsShown() then
        pcall(board.Close, board)
        closed[#closed + 1] = "the strategy board"
    end
    local main = ns.MainFrame
    if main and main.IsShown and main:IsShown() then
        pcall(main.Close, main)
        closed[#closed + 1] = "the DisasterZone window (its games draw 3D)"
    end
    if #closed > 0 then
        ns:Print("3D probe: closed %s - model scenes share one depth buffer and could spoil the tiles.",
            tconcat(closed, " and "))
    end
end

-- mode "full" (the loose files too: only after the guarded reload) or "safe"; only = one key of "only" (OnlyKey).
function P.Start(mode, only)
    if P.res then
        P.Show()
        ns:Print("the 3D probe already ran in this session (its window is open again); /reload first to run it afresh.")
        return
    end
    local st = NewState()
    if not st then
        ns:Print("saved data is not loaded yet.")
        return
    end
    if mode == "full" then st.pending = "running" end      -- (memory only: the disk keeps "armed" until a reload)
    local res = { at = time(), mode = mode, only = only, finished = false, errors = {}, loose = {}, cost = {} }
    st.results = res
    P.res, P.mode, P.only, P.t0 = res, mode, only, GetTime()
    P.scenes, P.loaded = P.scenes or {}, P.loaded or {}
    local v, b, d, toc = GetBuildInfo()
    res.build = format("%s.%s", tostring(v), tostring(b))
    res.buildDate, res.toc = Val(d), Val(toc)
    Step("other scenes", CloseOtherScenes)
    Step("methods", P.DumpMethods, res)
    Step("window", P.Show, 1)
    -- every page now, inside the guarded run (page 3's frame-buffer tiles are the least known), then back to page 1;
    -- not the lazy page 6: its models load only when its tab is opened, so a crash right then points at them
    Step("pages", function()
        for i = #PAGES, 1, -1 do
            if not PAGES[i].lazy then P.SetPage(i) end
        end
    end)
    ns:Print("3D probe running (%s): its window has seven pages (3 and 4 show one tile at a time: Prev / Next under "
        .. "the page; 6 loads its stock models only when opened); the measured results follow in a few seconds.",
        mode == "safe" and "safe: no loose files" or (only and ("only " .. OnlyName(only)) or "all loose files"))
    C_Timer.After(0.3, function() Step("measure", P.Measure, res) end)
    C_Timer.After(2, function() Step("loose 2 s", P.CheckLoose, "2s") end)
    C_Timer.After(6, function()
        Step("loose 6 s", P.CheckLoose, "6s")
        P.Finish()
    end)
end

function P.Finish()
    local res, st = P.res, State()
    res.finished = true
    res.seconds = Round(GetTime() - P.t0, 1)
    if st then
        if st.pending == "running" then
            st.pending, st.armedAt, st.only = nil, nil, nil
        end
        -- (each model's verdict in short and the frame answers: the next run replaces results, the history keeps them)
        local loose = {}
        for key, r in pairs(res.loose) do loose[key] = LooseShort(r) end
        local create = res.create and { OffScreenFrame = res.create.OffScreenFrame, UiCamera = res.create.UiCamera }
        History(st, { at = res.at, mode = res.mode, only = res.only, finished = true, errors = #res.errors,
                      loose = loose, create = create })
    end
    P.SetStatus()
    if P.dataText then P.dataText:SetText(tconcat(P.SummaryLines(res), "\n")) end
    P.PrintSummary(res)
    -- a file the client never indexed loads only after a full restart: a /reload does not look for new files
    local unknown = {}
    for _, key in ipairs(KEY_ORDER) do
        local r = res.loose[key]
        if r and r.IsKnownFile == false and r.loaded6s ~= true then unknown[#unknown + 1] = key end
    end
    if #unknown > 0 then
        ns:Print("3D probe: the client does not know %s (C_UIFileAsset.IsKnownFile false). Files put in Media\\Probe "
            .. "after the game started need a full restart of the game, not a /reload, before they can load.",
            tconcat(unknown, ", "))
    end
    ns:Print("Screenshot each page of the probe window now (its tabs at the top) and look in World of Warcraft\\"
        .. "_anniversary_\\Logs for model errors (the newest files); then /reload once: that saves the results "
        .. "(SavedVariables, DisasterZoneDB.probe3d).")
end

function P.Arm(only)
    if P.res then
        P.Show()
        ns:Print("the 3D probe already ran in this session (its window is open again); /reload first to run it afresh.")
        return
    end
    local st = NewState()
    if not st then
        ns:Print("saved data is not loaded yet.")
        return
    end
    if st.crashed and not only then
        P.PrintCrash()
        return
    end
    st.pending, st.armedAt, st.only = "armed", time(), only
    ns:Print("3D probe: reloading the interface to run it%s. Files added to Media\\Probe since the game started need a "
        .. "full game restart first.", only and (" with " .. OnlyName(only) .. " only") or "")
    ReloadUI()
end

local USAGE = "/dz 3d probe - run the 3D render probe now, without the loose model files; loose confirm - reload "
    .. "and load the loose files too (CRASHED the game on 2026-10-05: a loose model loaded again after a reload); "
    .. "only <%s> confirm - one loose file (or the two test frame types) per run; results - the last results; "
    .. "reset - clear a crash notice or an armed run (results and history stay); clear - forget everything it saved."

-- Loose model files: the first run drew Blizzard's placeholder cube for every one (even a byte copy of the game's own
-- cube), and the second, after a reload, crashed the game in SetModelByPath (2026-10-05). They load only when asked
-- for with "confirm".
local LOOSE_WARNING = "3D probe: loose model files do not load in this client (a placeholder cube) and loading one "
    .. "again after a reload crashed the game on 2026-10-05. Add 'confirm' to load them anyway: /dz 3d probe %s confirm"

function P.Slash(arg)
    local cmd, rest = strsplit(" ", strtrim(arg or ""), 2)
    cmd = strlower(cmd or "")
    rest = rest and strlower(strtrim(rest)) or nil
    local confirm = false
    if rest and rest:find("confirm", 1, true) then
        confirm = true
        rest = strtrim((rest:gsub("confirm", "")))
        if rest == "" then rest = nil end
    end
    if cmd == "" or cmd == "run" or cmd == "safe" then
        P.Start("safe")
    elseif cmd == "loose" then
        if confirm then P.Arm(nil) else ns:Print(LOOSE_WARNING, "loose") end
    elseif cmd == "only" then
        if OnlyKey(rest) then
            if confirm then P.Arm(rest) else ns:Print(LOOSE_WARNING, "only " .. rest) end
        else
            ns:Print("/dz 3d probe only <%s>: one loose model file per run (frames: the OffScreenFrame and UiCamera "
                .. "frame types alone).", KEYS)
        end
    elseif cmd == "results" then
        local st = State()
        if st and st.results then P.PrintSummary(st.results) else ns:Print("the 3D probe has no results yet.") end
        if st and st.crashed then P.PrintCrash() end
    elseif cmd == "reset" then
        -- (the crash notice and an armed run only: after a crash the bisect's results and the history of runs are
        -- what is left to read)
        local st = State()
        if st then st.pending, st.armedAt, st.only, st.crashed, st.crash = nil, nil, nil, nil, nil end
        if P.win then P.win:Hide() end
        ns:Print("3D probe: crash notice and armed run cleared, results and history kept%s.",
            P.res and "; /reload before running it again" or "")
    elseif cmd == "clear" then
        if ns.db then ns.db.probe3d = nil end
        if P.win then P.win:Hide() end
        ns:Print("3D probe: everything it saved is forgotten%s.", P.res and "; /reload before running it again" or "")
    else
        ns:Print(USAGE, KEYS)
    end
end

-- The first PLAYER_ENTERING_WORLD of a session: the reload an armed probe asked for runs it; any other login that
-- finds the flag means the last run never finished.
local function OnEnterWorld(_, _, isReload)
    ns:UnregisterEvent("PLAYER_ENTERING_WORLD", OnEnterWorld)
    local st = State()
    if not (st and st.pending) then return end
    if st.pending == "armed" and isReload and time() - (tonumber(st.armedAt) or 0) < ARM_TTL then
        st.pending = "running"                          -- (memory only: the disk keeps "armed" until a reload)
        local only = OnlyKey(st.only)
        C_Timer.After(1, function() P.Start("full", only) end)
        return
    end
    st.crashed = true
    st.crash = { armedAt = st.armedAt, noticedAt = time(), only = st.only, state = st.pending }
    History(st, { at = st.armedAt, mode = "full", only = st.only, finished = false })
    st.pending, st.armedAt, st.only = nil, nil, nil
    C_Timer.After(5, P.PrintCrash)
end
ns:RegisterEvent("PLAYER_ENTERING_WORLD", OnEnterWorld)
