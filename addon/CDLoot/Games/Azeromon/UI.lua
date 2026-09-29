-- CDLoot Games/Azeromon/UI.lua
-- ns.AzeroUI: draws ns.Azero's state and forwards keyboard / mouse input.
-- Screen: 11 x 9 tiles of 48px (16px art at 3x, nearest filtering), camera centred on the player.
-- Keys (while the game has focus): arrows / WASD move, Space / Z / E = A, X / Q / Backspace = B (hold to run),
-- Enter / Tab / M = menu, Escape releases the keyboard.
local addonName, ns = ...

local UI = ns:NewModule("AzeroUI")
local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon
local A = ns.AzeroAtlas

local TILE, VW, VH = 48, 11, 9
local HX, HY = 5, 4                       -- player's screen tile
local SW, SH = TILE * VW, TILE * VH
local MEDIA = "Interface\\AddOns\\CDLoot\\Media\\Azeromon\\"
local ATLAS, CHARS, PLATFORM = MEDIA .. "atlas", MEDIA .. "chars", MEDIA .. "platform"
-- Pixel Operator by Jayvee Enaguas (CC0). Falls back to the game font if the file is missing (needs a restart).
local FONT = MEDIA .. "fonts\\PixelOperator.ttf"
local FONT_BOLD = MEDIA .. "fonts\\PixelOperator-Bold.ttf"
local FONT_FALLBACK = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local TEXT_SPEED = 55                     -- characters per second
local BOX_H = 112
local INK = { 0.25, 0.25, 0.29 }          -- GBA text colour
local INK_SHADOW = { 0.84, 0.84, 0.86 }

local floor, max, min = math.floor, math.max, math.min

local SPRITE_COL = { bald = 0, hero = 3, girl = 6, skel = 9 }
local FACE_ROW = { down = 0, left = 1, right = 2, up = 3 }

local root, screen, world, focusOverlay
local R = {}               -- widgets
local stack = {}           -- open menus (top = last)
local focused = false
local now = 0

---------------------------------------------------------------------------
-- Texture helpers
---------------------------------------------------------------------------

local function Tex(parent, layer, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    return t
end

local function SetPixelTexture(t, file)
    if not pcall(t.SetTexture, t, file, nil, nil, "NEAREST") then t:SetTexture(file) end
    if t.SetSnapToPixelGrid then pcall(t.SetSnapToPixelGrid, t, false) end
    if t.SetTexelSnappingBias then pcall(t.SetTexelSnappingBias, t, 0) end
end

local E = 0.02 / 256       -- tiny inset against bleeding between atlas cells
local function SetTile(t, name)
    name = name or false               -- false = empty; a fresh texture (nil) is always set once
    if t.tileName == name then return end
    t.tileName = name
    local i = name and A[name]
    if not i then t:Hide() return end
    local c, r = i % 16, floor(i / 16)
    t:SetTexCoord(c * 16 / 256 + E, (c + 1) * 16 / 256 - E, r * 16 / 256 + E, (r + 1) * 16 / 256 - E)
    t:Show()
end

local function SetChar(t, sprite, face, frame)
    local key = sprite .. face .. frame
    if t.charKey == key then return end
    t.charKey = key
    local c = (SPRITE_COL[sprite] or 3) + frame
    local r = FACE_ROW[face] or 0
    t:SetTexCoord(c * 16 / 256 + E, (c + 1) * 16 / 256 - E, r * 16 / 128 + E, (r + 1) * 16 / 128 - E)
end

local function Rot(t, r)
    if t.SetRotation then pcall(t.SetRotation, t, r) end
end

-- size is the old design size; the pixel font runs small, so it is scaled up ~1.4x.
local function Font(parent, size, layer, bold)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    local px = floor((size or 16) * 1.4 + 0.5)
    if not fs:SetFont(bold and FONT_BOLD or FONT, px, "") then fs:SetFont(FONT_FALLBACK, size or 16, "") end
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetTextColor(INK[1], INK[2], INK[3])
    fs:SetShadowColor(INK_SHADOW[1], INK_SHADOW[2], INK_SHADOW[3], 1)
    fs:SetShadowOffset(2, -2)
    return fs
end

-- A "rounded" rectangle: two overlapping rects with the corners cut off.
local function Rounded(f, inset, cut, r, g, b, sub, layer)
    local h = Tex(f, layer or "BACKGROUND", sub)
    h:SetPoint("TOPLEFT", inset, -(inset + cut))
    h:SetPoint("BOTTOMRIGHT", -inset, inset + cut)
    h:SetColorTexture(r, g, b, 1)
    local v = Tex(f, layer or "BACKGROUND", sub)
    v:SetPoint("TOPLEFT", inset + cut, -inset)
    v:SetPoint("BOTTOMRIGHT", -(inset + cut), inset)
    v:SetColorTexture(r, g, b, 1)
    return h, v
end

-- The FireRed / Emerald window: dark outline, a pale blue ring, a white inside.
local function Box(parent, w, h, level)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    if level then f:SetFrameLevel(level) end
    Rounded(f, 0, 4, 0.27, 0.29, 0.37, 0)
    Rounded(f, 2, 3, 0.56, 0.74, 0.86, 1)
    Rounded(f, 5, 2, 0.35, 0.50, 0.62, 2)
    Rounded(f, 6, 2, 0.99, 0.99, 0.97, 3)
    f:EnableMouse(true)
    return f
end

-- A small solid triangle built from strips. dir = "right" (menu cursor) or "down" (continue arrow).
local function Triangle(parent, dir, size, r, g, b)
    local f = CreateFrame("Frame", nil, parent)
    local steps = 4
    local s = size or 12
    local strip = s / (steps * 2)
    if dir == "right" then f:SetSize(steps * strip * 2, s) else f:SetSize(s, steps * strip * 2) end
    for i = 0, steps - 1 do
        local t = Tex(f, "OVERLAY", 2)
        t:SetColorTexture(r, g, b, 1)
        local len = s - i * (s / steps)
        if dir == "right" then
            t:SetSize(strip * 2, len)
            t:SetPoint("LEFT", i * strip * 2, 0)
        else
            t:SetSize(len, strip * 2)
            t:SetPoint("TOP", 0, -i * strip * 2)
        end
    end
    return f
end

-- A coloured label pill (types, status).
local function Pill(parent, w, h, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w or 56, h or 16)
    f.bg1, f.bg2 = Rounded(f, 0, 2, 0.5, 0.5, 0.5, 0, "ARTWORK")
    f.fs = f:CreateFontString(nil, "OVERLAY")
    if not f.fs:SetFont(FONT_BOLD, size or 15, "") then f.fs:SetFont(FONT_FALLBACK, 10, "") end
    f.fs:SetPoint("CENTER", 0, 1)
    f.fs:SetTextColor(1, 1, 1)
    f.fs:SetShadowColor(0, 0, 0, 0.45)
    f.fs:SetShadowOffset(1, -1)
    function f:Set(text, c)
        if not text then self:Hide() return end
        self:Show()
        self.fs:SetText(text)
        self.bg1:SetColorTexture(c[1], c[2], c[3], 1)
        self.bg2:SetColorTexture(c[1], c[2], c[3], 1)
    end
    return f
end

local function Bar(parent, w, h)
    local bg = Tex(parent, "ARTWORK", 0)
    bg:SetSize(w, h)
    bg:SetColorTexture(0.22, 0.23, 0.27, 1)
    local track = Tex(parent, "ARTWORK", 1)
    track:SetPoint("TOPLEFT", bg, "TOPLEFT", 1, -1)
    track:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -1, 1)
    track:SetColorTexture(0.40, 0.42, 0.45, 1)
    local fill = Tex(parent, "ARTWORK", 2)
    fill:SetHeight(h - 2)
    fill:SetPoint("LEFT", bg, "LEFT", 1, 0)
    local shine = Tex(parent, "ARTWORK", 3)
    shine:SetPoint("TOPLEFT", fill, "TOPLEFT")
    shine:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
    shine:SetHeight(max(1, floor((h - 2) / 3)))
    local b = { bg = bg, fill = fill, shine = shine, track = track, w = w - 2 }
    function b:Set(pct, r, g, bl)
        pct = max(0, min(1, pct or 0))
        self.fill:SetWidth(max(0.01, self.w * pct))
        self.fill:SetShown(pct > 0)
        self.shine:SetShown(pct > 0)
        if r then
            self.fill:SetColorTexture(r, g, bl, 1)
            self.shine:SetColorTexture(r + (1 - r) * 0.45, g + (1 - g) * 0.45, bl + (1 - bl) * 0.45, 1)
        end
    end
    function b:SetShown(on)
        self.bg:SetShown(on) self.track:SetShown(on)
        if not on then self.fill:Hide() self.shine:Hide() end
    end
    function b:SetHP(pct)
        if pct > 0.5 then self:Set(pct, 0.3, 0.85, 0.35)
        elseif pct > 0.2 then self:Set(pct, 0.95, 0.8, 0.2)
        else self:Set(pct, 0.9, 0.3, 0.25) end
    end
    return b
end

---------------------------------------------------------------------------
-- Models
---------------------------------------------------------------------------

-- Creatures are drawn in a ModelScene: once a model has loaded we measure its bounding box and scale it so
-- every creature fills the same share of its frame, standing on the frame's bottom edge (the platform).
-- Tiny spiders and huge bloodpetals then look alike, and new species need no hand tuning.
-- Clients without ModelScene actors fall back to a PlayerModel with a fixed camera.
-- A telephoto camera: far away with a narrow field of view, so the picture is nearly flat. With a close camera,
-- the parts of a wide creature that reach toward us (a spider's front legs) project below the frame's bottom
-- edge; at 60 units a model 2 units deep is off by only ~3%. VIS_H = scene units visible top to bottom at the
-- creature's plane.
local CAM_DIST, VIS_H = 60, 3.8
local CAM_FOV = 2 * math.atan(VIS_H / 2 / CAM_DIST)
local FILL_H, FILL_W = 0.78, 0.86     -- share of the frame's height / width a creature may take
local SAMPLE_TIME = 1.6               -- seconds of idle animation measured before fitting (a full hover bob)
local scenes = {}                     -- every scene with a fit pending or done

local function NewScene(parent, w, h)
    local ok, sc = pcall(CreateFrame, "ModelScene", nil, parent)
    if not ok or not sc or not sc.CreateActor then return nil end
    sc:SetSize(w, h)
    local actorOk, actor = pcall(sc.CreateActor, sc)
    if not actorOk or not actor or not actor.SetModelByCreatureDisplayID or not actor.GetActiveBoundingBox then
        sc:Hide()
        return nil
    end
    -- camera on the +x axis looking back at the origin; the actor faces +x (toward us) at yaw 0
    pcall(sc.SetCameraPosition, sc, CAM_DIST, 0, 0)
    pcall(sc.SetCameraOrientationByYawPitchRoll, sc, math.pi, 0, 0)
    pcall(sc.SetCameraFieldOfView, sc, CAM_FOV)
    pcall(sc.SetCameraNearClip, sc, 1)
    pcall(sc.SetCameraFarClip, sc, 400)
    pcall(sc.SetLightVisible, sc, true)
    pcall(sc.SetLightDirection, sc, -0.6, 0.4, -0.7)
    pcall(sc.SetLightAmbientColor, sc, 0.72, 0.72, 0.72)
    pcall(sc.SetLightDiffuseColor, sc, 0.85, 0.85, 0.82)
    sc.actor = actor
    sc.isScene = true
    sc.SetAnimation = function(self, id) pcall(self.actor.SetAnimation, self.actor, id) end
    scenes[#scenes + 1] = sc
    return sc
end

local function ReadBox(a, method)
    local fn = a[method]
    if not fn then return nil end
    local ok, x0, y0, z0, x1, y1, z1 = pcall(fn, a)
    if not ok or not z1 or not z0 or not x1 or not y1 or (z1 - z0) <= 0 then return nil end
    return { x0, y0, z0, x1, y1, z1 }
end

-- The box used for fitting: the envelope of the CURRENT pose (the idle animation we actually show) sampled over
-- SAMPLE_TIME, kept inside the all-animations box. The all-animations box alone is too big for creatures with
-- big rearing / flying animations (a whelp's is 4.2 tall while its idle hover is ~1.9), which made them small
-- and floating.
local function MeasureBox(a)
    return ReadBox(a, "GetActiveBoundingBox") or ReadBox(a, "GetMaxBoundingBox")
end

local function Union(b, c)
    if not b then return { c[1], c[2], c[3], c[4], c[5], c[6] } end
    return { math.min(b[1], c[1]), math.min(b[2], c[2]), math.min(b[3], c[3]),
             math.max(b[4], c[4]), math.max(b[5], c[5]), math.max(b[6], c[6]) }
end

local function Clamp(b, lim)
    if not lim then return b end
    local c = { math.max(b[1], lim[1]), math.max(b[2], lim[2]), math.max(b[3], lim[3]),
                math.min(b[4], lim[4]), math.min(b[5], lim[5]), math.min(b[6], lim[6]) }
    if c[6] - c[3] <= 0 or c[4] - c[1] <= 0 or c[5] - c[2] <= 0 then return b end
    return c
end

-- Fits a loaded actor (called every frame while a fit is pending). The actor stays at the origin at scale 1
-- while its pose is sampled; then it is scaled once and the CAMERA is aimed so the lowest point sits on the
-- frame's bottom edge (moving the camera, not the actor, avoids any question of positions being scaled).
-- The width is taken after the creature's turn (yaw), so a creature seen at an angle still fits.
local function FitScene(sc)
    local fit = sc.fit
    if not fit then return end
    local a = sc.actor
    local loaded = true
    if a.IsLoaded then
        local ok, v = pcall(a.IsLoaded, a)
        loaded = not ok or v
    end
    local cur = loaded and MeasureBox(a)
    if not cur then
        if GetTime() - fit.since > 4 then          -- never measured: show it as it is rather than not at all
            sc.fit = nil
            pcall(a.SetAlpha, a, 1)
        end
        return
    end
    fit.box = Union(fit.box, cur)
    fit.sampleStart = fit.sampleStart or GetTime()
    if GetTime() - fit.sampleStart < SAMPLE_TIME then return end
    local b = Clamp(fit.box, ReadBox(a, "GetMaxBoundingBox"))
    local x0, y0, z0, x1, y1, z1 = b[1], b[2], b[3], b[4], b[5], b[6]

    -- horizontal extent on screen after the turn: rotate the footprint corners about the vertical axis
    local yaw = sc.facing or 0
    local sn, cs = math.sin(yaw), math.cos(yaw)
    local lo, hi = math.huge, -math.huge
    for _, x in ipairs({ x0, x1 }) do
        for _, y in ipairs({ y0, y1 }) do
            local v = x * sn + y * cs
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
    end
    local height, width = z1 - z0, math.max(hi - lo, 0.01)
    local visH = VIS_H
    local visW = visH * (sc:GetWidth() / math.max(1, sc:GetHeight()))
    local s = math.min(FILL_H * visH / height, FILL_W * visW / width) / fit.tweak
    pcall(a.SetScale, a, s)
    local camZ = z0 * s + visH / 2 - visH * 0.03   -- lowest point 3% above the bottom edge
    local camY = (lo + hi) / 2 * s                  -- centred sideways
    pcall(sc.SetCameraPosition, sc, CAM_DIST, camY, camZ)
    pcall(a.SetAlpha, a, 1)
    sc.fit = nil
    sc.fitted = s
    sc.camZ = camZ
    sc.fitBox = b
    sc.fitInfo = { h = height * s / visH, w = width * s / visW, feet = (z0 * s - (camZ - visH / 2)) / visH,
                   z0 = z0, z1 = z1 }
end

local function FitScenes()
    for _, sc in ipairs(scenes) do
        if sc.fit and sc:IsVisible() then FitScene(sc) end
    end
end

local function NewModel(parent, w, h)
    local sc = NewScene(parent, w, h)
    if sc then return sc end
    local m = CreateFrame("PlayerModel", nil, parent)
    m:SetSize(w, h)
    pcall(m.SetScript, m, "OnModelLoaded", function(self)
        pcall(self.SetPortraitZoom, self, 0)
        pcall(self.SetCamDistanceScale, self, self.cam or self.camScale or 1.2)
        pcall(self.SetPosition, self, 0, 0, 0)
        if self.facing then pcall(self.SetFacing, self, self.facing) end
    end)
    return m
end

local function FacingSign()
    return (G:Data().flipFacing and -1 or 1)
end

-- Camera distance for a creature: frame default x species size (Data `cam`) x the player's own tweak
-- (/cdl azeromon zoom <species> <n>). Bigger = further away = smaller on screen.
local function CamFor(m, s)
    local over = G:Data().zoom
    local tweak = type(over) == "table" and tonumber(over[s.id]) or 1
    return (m.camScale or 1.2) * (s.cam or 1) * tweak
end

local function ShowCreature(m, sp, facing)
    local s = sp and D.species[sp]
    if not s then m:Hide() m.sp = nil return end
    m:Show()
    m.facing = facing and facing * FacingSign() or 0
    if m.isScene then
        local over = G:Data().zoom
        local tweak = type(over) == "table" and tonumber(over[s.id]) or 1
        local a = m.actor
        pcall(a.SetYaw, a, m.facing)
        if m.sp ~= sp or m.tweak ~= tweak then
            m.sp, m.tweak = sp, tweak
            pcall(a.SetAlpha, a, 0)                -- hidden until measured, so it never pops in huge
            pcall(a.SetScale, a, 1)
            pcall(a.SetPosition, a, 0, 0, 0)
            pcall(m.SetCameraPosition, m, CAM_DIST, 0, 0)
            pcall(a.SetModelByCreatureDisplayID, a, s.display)
            m.fit = { tweak = tweak, since = GetTime() }
            FitScene(m)
        end
        return
    end
    local cam = CamFor(m, s)
    -- A camera further back shrinks the model toward the middle of its frame, lifting its feet off the
    -- platform. Size on screen goes with 1 / distance, so lower the frame by the height it lost below.
    if m.groundY then
        local f = cam / (m.camScale or 1.2)
        local lift = (1 - 1 / f) * m:GetHeight() / 2
        m.baseY = m.groundY - lift - (s.yoff or 0)
        m:ClearAllPoints()
        m:SetPoint("BOTTOMLEFT", m:GetParent(), "TOPLEFT", m.baseX, m.baseY)
    end
    if m.sp ~= sp or m.cam ~= cam then
        m.sp = sp
        m.cam = cam
        pcall(m.ClearModel, m)
        pcall(m.SetDisplayInfo, m, s.display)
        pcall(m.SetPortraitZoom, m, 0)
        pcall(m.SetCamDistanceScale, m, cam)
        pcall(m.SetPosition, m, 0, 0, 0)
    end
    pcall(m.SetFacing, m, m.facing)
end

local function Anim(m, id)
    if m and m.SetAnimation then pcall(m.SetAnimation, m, id) end
end

---------------------------------------------------------------------------
-- Text box (typewriter)
---------------------------------------------------------------------------

local text = { full = nil, shown = 0, done = true, auto = nil, onDone = nil, pages = nil, page = 1 }
local LINES_PER_PAGE = 2
local TEXT_W = SW - 56

-- Word-wraps with a hidden measuring FontString (falls back to a character estimate), then groups the
-- lines into pages of LINES_PER_PAGE, like the games.
local function Paginate(str, perPage)
    local measure = R.measure
    local function width(s)
        measure:SetText(s)
        local w = measure:GetStringWidth()
        if not w or w <= 0 then w = #s * 11 end
        return w
    end
    local lines = {}
    for para in (str .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in para:gmatch("%S+") do
            local try = line == "" and word or (line .. " " .. word)
            if line ~= "" and width(try) > TEXT_W then
                lines[#lines + 1] = line
                line = word
            else
                line = try
            end
        end
        lines[#lines + 1] = line
    end
    local pages = {}
    perPage = perPage or LINES_PER_PAGE
    for i = 1, #lines, perPage do
        local chunk = {}
        for j = i, min(#lines, i + perPage - 1) do chunk[#chunk + 1] = lines[j] end
        local p = table.concat(chunk, "\n")
        if p:match("%S") then pages[#pages + 1] = p end
    end
    if #pages == 0 then pages[1] = "" end
    return pages
end

local function ShowPage(i)
    text.page = i
    text.full = text.pages[i]
    text.shown = 0
    text.done = false
    text.doneAt = nil
    R.textfs:SetText("")
end

-- "Name: words" shows Name on a tab above the box (dialogue), like the later games.
local function SetText(str, opts)
    str = str or ""
    local speaker, rest = str:match("^([%a][%w%s%.']-): (.+)$")
    if speaker and #speaker <= 28 then str = rest else speaker = nil end
    R.nameTab:SetShown(speaker ~= nil)
    if speaker then
        R.nameTab.fs:SetText(speaker)
        R.nameTab:SetWidth(max(90, R.nameTab.fs:GetStringWidth() + 32))
    end
    text.pages = Paginate(str, opts and opts.lines)
    text.auto = opts and opts.auto
    text.onDone = opts and opts.onDone
    R.textbox:Show()
    ShowPage(1)
end

local function TextFinished() return text.full and text.done end

local function UpdateText(dt)
    if not text.full then R.textbox:Hide() return end
    R.textbox:Show()
    if not text.done then
        text.shown = text.shown + dt * TEXT_SPEED
        local n = floor(text.shown)
        if n >= #text.full then
            n = #text.full
            text.done = true
            text.doneAt = now
        end
        R.textfs:SetText(text.full:sub(1, n))
    end
    local more = text.pages and text.page < #text.pages
    R.textArrow:SetShown(text.done and (more or not text.auto) and true or false)
    R.textArrow:ClearAllPoints()
    R.textArrow:SetPoint("BOTTOMRIGHT", R.textbox, "BOTTOMRIGHT", -20, 16 + (floor(now * 3) % 2) * 3)
    if text.done and text.auto and now - text.doneAt >= text.auto then
        if more then ShowPage(text.page + 1) return end
        local cb = text.onDone
        text.onDone = nil
        if cb then cb() end
    end
end

-- A pressed on the text box: finish the reveal, turn the page, or continue.
local function TextA()
    if not text.full then return false end
    if not text.done then
        text.shown = #text.full
        return true
    end
    if text.pages and text.page < #text.pages then
        ShowPage(text.page + 1)
        return true
    end
    local cb = text.onDone
    text.onDone = nil
    if cb then cb() return true end
    return false
end

local function ClearText()
    text.full, text.onDone, text.auto, text.pages = nil, nil, nil, nil
    if R.textbox then R.textbox:Hide() R.nameTab:Hide() end
end

---------------------------------------------------------------------------
-- List menus (choices, start menu, party, bag, shop, moves)
-- item = { text, right, bar, disabled, onSelect }
-- opts = { x, y, w, rowH, cols, onCancel, anchor, title, level, noBox, onMove }
---------------------------------------------------------------------------

local menuPool = {}

local function PushMenu(items, opts)
    opts = opts or {}
    local cols = opts.cols or 1
    local rowH = opts.rowH or 32
    local w = opts.w or 160
    local rows = math.ceil(#items / cols)
    local h = opts.h or (rows * rowH + 24 + (opts.title and 30 or 0))
    local f = table.remove(menuPool) or Box(screen, w, h)
    f:SetParent(screen)
    f:SetSize(w, h)
    -- always above whatever menu is already open (sub-menus over the bag, party over a sub-menu, ...)
    local level = opts.level or 60
    local top = stack[#stack]
    if top and top.frame and top.frame.GetFrameLevel then level = max(level, top.frame:GetFrameLevel() + 10) end
    f:SetFrameLevel(level)
    f:ClearAllPoints()
    if opts.anchor then
        f:SetPoint(unpack(opts.anchor))
    else
        f:SetPoint("TOPLEFT", screen, "TOPLEFT", opts.x or (SW - w - 6), opts.y or -6)
    end
    f.rows = f.rows or {}
    f.titleFs = f.titleFs or Font(f, 15, nil, true)
    f.titleFs:SetPoint("TOPLEFT", 18, -14)
    f.titleFs:SetTextColor(0.20, 0.36, 0.62)
    f.titleFs:SetText(opts.title or "")
    f.titleFs:SetShown(opts.title ~= nil)
    local top = opts.title and 42 or 12
    local colW = (w - 24) / cols
    for i, it in ipairs(items) do
        local row = f.rows[i]
        if not row then
            row = CreateFrame("Button", nil, f)
            row.cursor = Triangle(row, "right", 14, INK[1], INK[2], INK[3])
            row.cursor:SetPoint("LEFT", 4, 0)
            row.fs = Font(row, 16)
            row.fs:SetPoint("LEFT", 22, 0)
            row.fs:SetJustifyV("MIDDLE")
            row.right = Font(row, 13)
            row.right:SetPoint("RIGHT", -6, 0)
            row.right:SetJustifyH("RIGHT")
            row.right:SetJustifyV("MIDDLE")
            row.bar = Bar(row, 110, 8)
            row.bar.bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 3)
            row.icon = Tex(row, "ARTWORK")
            row.icon:SetSize(rowH - 6, rowH - 6)
            row.icon:SetPoint("LEFT", 22, 0)
            row:SetScript("OnEnter", function(self)
                local menu = self:GetParent().menu
                if menu and stack[#stack] == menu then menu.cursor = self.idx UI:RefreshMenu(menu) end
            end)
            row:SetScript("OnClick", function(self)
                local menu = self:GetParent().menu
                if menu and stack[#stack] == menu then menu.cursor = self.idx UI:MenuSelect(menu) end
            end)
            f.rows[i] = row
        end
        row.idx = i
        row:SetSize(colW, rowH)
        row:ClearAllPoints()
        local c, r = (i - 1) % cols, floor((i - 1) / cols)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + c * colW, -top - r * rowH)
        row.fs:SetText(it.text or "")
        row.fs:ClearAllPoints()
        row.fs:SetPoint("LEFT", it.icon and (26 + rowH) or 24, it.bar and 5 or 0)
        if it.disabled then row.fs:SetTextColor(0.66, 0.66, 0.68) else row.fs:SetTextColor(INK[1], INK[2], INK[3]) end
        local rc = it.rightColor or { 0.36, 0.42, 0.55 }
        row.right:SetTextColor(rc[1], rc[2], rc[3])
        row.right:SetText(it.right or "")
        row.right:ClearAllPoints()
        row.right:SetPoint("RIGHT", -6, it.bar and 5 or 0)
        if it.icon then row.icon:SetTexture(it.icon) row.icon:Show() else row.icon:Hide() end
        row.bar:SetShown(it.bar ~= nil)
        if it.bar then row.bar:SetHP(it.bar) end
        row:Show()
    end
    for i = #items + 1, #f.rows do f.rows[i]:Hide() end
    -- pooled frames keep their children's old levels: lift the rows (and cursors) with the frame
    for _, row in ipairs(f.rows) do
        row:SetFrameLevel(level + 1)
        row.cursor:SetFrameLevel(level + 2)
    end
    local menu = { frame = f, items = items, cursor = opts.cursor or 1, cols = cols, opts = opts }
    f.menu = menu
    f:Show()
    stack[#stack + 1] = menu
    UI:RefreshMenu(menu)
    return menu
end

function UI:RefreshMenu(menu)
    for i, row in ipairs(menu.frame.rows) do
        if row:IsShown() then row.cursor:SetShown(i == menu.cursor) end
    end
    if menu.opts.onMove then menu.opts.onMove(menu.cursor, menu) end
end

local function PopMenu(menu)
    menu = menu or stack[#stack]
    for i = #stack, 1, -1 do
        if stack[i] == menu then
            table.remove(stack, i)
            menu.frame:Hide()
            menu.frame.menu = nil
            -- only real list menus are recycled (never the summary screen, which also sits in the stack)
            if not menu.frame.noPool then menuPool[#menuPool + 1] = menu.frame end
            break
        end
    end
end

local function CloseAllMenus()
    while #stack > 0 do PopMenu(stack[#stack]) end
end

function UI:MenuSelect(menu)
    local it = menu.items[menu.cursor]
    if it and not it.disabled and it.onSelect then it.onSelect(menu.cursor, menu) end
end

local function MenuMove(menu, dir)
    local n, cols = #menu.items, menu.cols
    local c = menu.cursor
    if dir == "up" then c = c - cols elseif dir == "down" then c = c + cols
    elseif dir == "left" and cols > 1 then c = c - 1 elseif dir == "right" and cols > 1 then c = c + 1 end
    if c >= 1 and c <= n then menu.cursor = c end
    UI:RefreshMenu(menu)
end

local function MenuKey(menu, key)
    if key == "A" then UI:MenuSelect(menu)
    elseif key == "B" then
        if menu.opts.onCancel then menu.opts.onCancel(menu) end
    elseif key == "up" or key == "down" or key == "left" or key == "right" then MenuMove(menu, key) end
end

---------------------------------------------------------------------------
-- UI messages (not from the engine): text + A to continue
---------------------------------------------------------------------------

local uiMessage = nil
local function Message(str, after)
    uiMessage = { after = after }
    SetText(str, { onDone = function()
        uiMessage = nil
        ClearText()
        if after then after() end
    end })
end

---------------------------------------------------------------------------
-- Screens: summary, log
---------------------------------------------------------------------------

local function ShowSummary(mon, onClose)
    local f = R.summary
    -- above every open menu (menus stack upward), with its model above the box
    local top = stack[#stack]
    local level = max(100, top and top.frame and top.frame:GetFrameLevel() + 10 or 0)
    f:SetFrameLevel(level)
    f.model:SetFrameLevel(level + 2)
    f:Show()
    local s = D.species[mon.sp]
    f.title:SetText(string.format("%s   Lv%d", M.Name(mon), mon.lvl))
    local lines = {
        string.format("No. %03d  %s", s.num, D.types[s.type].name:upper()),
        string.format("HP  %d/%d%s", mon.hp, M.MaxHP(mon), mon.status and ("  " .. D.status[mon.status].short) or ""),
        string.format("Atk %d   Def %d   Spe %d", M.Stat(mon, "atk"), M.Stat(mon, "def"), M.Stat(mon, "spe")),
        string.format("SpA %d   SpD %d", M.Stat(mon, "spa"), M.Stat(mon, "spd")),
        string.format("Next level: %d exp", mon.lvl >= D.MAX_LEVEL and 0 or (M.ExpForLevel(mon.lvl + 1) - mon.exp)),
        "",
    }
    for _, mv in ipairs(mon.moves) do
        local md = D.moves[mv.id]
        lines[#lines + 1] = string.format("%s  %d/%d", md.name, mv.pp, md.pp)
    end
    f.body:SetText(table.concat(lines, "\n"))
    ShowCreature(f.model, mon.sp, 0.5)
    stack[#stack + 1] = { frame = f, items = {}, cursor = 1, cols = 1, opts = {
        onCancel = function(menu) PopMenu(menu) if onClose then onClose() end end } }
    stack[#stack].isSummary = true
end

local function OpenLog()
    local s = G.save
    R.bagDesc:Hide()
    local items = {}
    for i, id in ipairs(D.dexOrder) do
        local sp = D.species[id]
        local seen, caught = s.seen[id], s.caught[id]
        items[i] = { text = string.format("%03d  %s", sp.num, seen and sp.name or "-----"),
                     right = caught and "tamed" or (seen and "seen" or ""),
                     onSelect = function() end }
    end
    local f = R.log
    f:Show()
    local menu
    menu = PushMenu(items, { x = 8, y = -8, w = 270, rowH = 30, title = "BESTIARY", level = 70,
        onCancel = function(m) PopMenu(m) f:Hide() end,
        onMove = function(i)
            local id = D.dexOrder[i]
            local sp = D.species[id]
            if s.seen[id] then
                ShowCreature(f.model, id, 0.5)
                f.body:SetText(s.caught[id] and (sp.name .. "  (" .. D.types[sp.type].name .. ")\n\n" .. sp.desc)
                    or (sp.name .. "\n\nTame one to learn more."))
            else
                f.model:Hide()
                f.model.sp = nil
                f.body:SetText("Not seen yet.")
            end
        end })
end

---------------------------------------------------------------------------
-- Party / bag (shared by the start menu and battle)
---------------------------------------------------------------------------

-- In a battle the battle's own party (a player battle fights with a healed copy), otherwise the saved one.
local function ActiveParty() return (G.battle and G.battle.party) or G.save.party end

local function PartyItems(onPick)
    local items = {}
    for i, mon in ipairs(ActiveParty()) do
        local st = mon.status and (" " .. D.status[mon.status].short) or ""
        items[i] = { text = string.format("%s  Lv%d%s", M.Name(mon), mon.lvl, st),
                     right = string.format("%d/%d", mon.hp, M.MaxHP(mon)), bar = mon.hp / M.MaxHP(mon),
                     onSelect = function(idx, menu) onPick(idx, menu) end }
    end
    return items
end

-- ctx: nil (start menu) | "battle" | "forced" (a fainted creature must be replaced) | "item" (pick a target)
local function OpenParty(ctx, onDone)
    local b = G.battle
    R.bagDesc:Hide()
    local partyMenu
    partyMenu = PushMenu(PartyItems(function(idx, menu)
        local mon = ActiveParty()[idx]
        if ctx == "item" then
            onDone(idx, menu)
            return
        end
        local opts = {}
        if ctx == "battle" or ctx == "forced" then
            opts[#opts + 1] = { text = "Shift", onSelect = function(_, sub)
                PopMenu(sub)
                if mon.hp <= 0 then Message(M.Name(mon) .. " has no energy left to battle!") return end
                if b and idx == b.allyIdx then Message(M.Name(mon) .. " is already in battle!") return end
                PopMenu(menu)
                onDone(idx)
            end }
        end
        opts[#opts + 1] = { text = "Summary", onSelect = function(_, sub)
            PopMenu(sub)
            ShowSummary(mon)
        end }
        if not ctx then
            opts[#opts + 1] = { text = "Switch", onSelect = function(_, sub)
                PopMenu(sub)
                local first = idx
                Message("Move " .. M.Name(mon) .. " to where?", function()
                    PopMenu(menu)
                    local pick = PushMenu(PartyItems(function(j, m2)
                        G:SwapParty(first, j)
                        PopMenu(m2)
                        OpenParty(ctx, onDone)
                    end), { x = 8, y = -8, w = 380, rowH = 40, title = "PARTY", level = 70,
                        onCancel = function(m2) PopMenu(m2) OpenParty(ctx, onDone) end })
                    pick.cursor = first
                    UI:RefreshMenu(pick)
                end)
            end }
        end
        opts[#opts + 1] = { text = "Cancel", onSelect = function(_, sub) PopMenu(sub) end }
        PushMenu(opts, { w = 150, x = SW - 156, y = -120, level = 80, onCancel = function(sub) PopMenu(sub) end })
    end), { x = 8, y = -8, w = 380, rowH = 40, title = ctx == "item" and "USE ON WHICH?" or "PARTY", level = 70,
        onCancel = function(menu)
            if ctx == "forced" then return end
            PopMenu(menu)
            if onDone and ctx ~= "item" then onDone(nil) end
            if ctx == "item" then onDone(nil, nil) end
        end })
    return partyMenu
end

local function OpenBag(ctx, onUse)
    local items = {}
    local bag = G.save.bag
    for _, id in ipairs(D.itemOrder) do
        if (bag[id] or 0) > 0 then
            local def = D.items[id]
            items[#items + 1] = { text = def.name, right = "x" .. bag[id], icon = def.icon, item = id,
                onSelect = function(_, menu) onUse(id, menu) end }
        end
    end
    if #items == 0 then
        Message("The bag is empty.")
        return
    end
    local desc = R.bagDesc
    PushMenu(items, { x = 8, y = -8, w = 320, rowH = 36, title = "BAG", level = 70,
        onCancel = function(menu) PopMenu(menu) desc:Hide() end,
        onMove = function(i, menu)
            desc:Show()
            desc.fs:SetText(D.items[menu.items[i].item].desc)
        end })
end

---------------------------------------------------------------------------
-- Start menu (overworld)
---------------------------------------------------------------------------

local START_HELP = {
    "Beasts you have seen and tamed.",
    "Check and reorder your beasts.",
    "Use the items you are carrying.",
    "Close this menu.",
}
local function StartMenuHelp(i)
    R.bagDesc:Show()
    R.bagDesc.fs:SetText(START_HELP[i] or "")
end

local function OpenStartMenu()
    local items = {
        { text = "BESTIARY", onSelect = function() OpenLog() end },
        { text = "PARTY", disabled = #G.save.party == 0, onSelect = function() OpenParty(nil) end },
        { text = "BAG", onSelect = function()
            OpenBag(nil, function(id, bagMenu)
                local def = D.items[id]
                if def.use == "ball" then Message("You can't throw that here.") return end
                OpenParty("item", function(idx, partyMenu)
                    if partyMenu then PopMenu(partyMenu) end
                    if not idx then return end
                    local msg = G:UseItemOutside(id, idx)
                    Message(msg, function()
                        PopMenu(bagMenu)
                        R.bagDesc:Hide()
                    end)
                end)
            end)
        end },
        { text = "EXIT", onSelect = function(_, menu) PopMenu(menu) end },
    }
    PushMenu(items, { w = 170, rowH = 36, level = 60, onMove = StartMenuHelp, onCancel = function(menu) PopMenu(menu) end })
    R.money:Show()
end

---------------------------------------------------------------------------
-- Shop
---------------------------------------------------------------------------

local function OpenShop()
    local items = {}
    for _, id in ipairs(D.shopStock) do
        local def = D.items[id]
        items[#items + 1] = { text = def.name, right = D.Money(def.price), icon = def.icon, item = id,
            onSelect = function(_, menu)
                local qty = 1
                local function qtyItems()
                    return { { text = string.format("x%d   %s", qty, D.Money(qty * def.price)), onSelect = function(_, qm)
                        PopMenu(qm)
                        local ok, msg = G:Buy(id, qty)
                        Message(msg)
                    end } }
                end
                local qm = PushMenu(qtyItems(), { w = 170, x = SW - 176, y = -250, level = 80,
                    title = "HOW MANY?",
                    onCancel = function(m) PopMenu(m) end })
                qm.onLeftRight = function(dir)
                    if dir == "up" or dir == "right" then qty = min(99, qty + 1) else qty = max(1, qty - 1) end
                    qm.frame.rows[1].fs:SetText(string.format("x%d   %dg", qty, qty * def.price))
                end
            end }
    end
    items[#items + 1] = { text = "Done", onSelect = function(_, menu)
        PopMenu(menu)
        R.bagDesc:Hide()
        G:Advance()
    end }
    R.money:Show()
    PushMenu(items, { x = 8, y = -8, w = 330, rowH = 36, title = "BROG HAMFIST", level = 70,
        onCancel = function(menu) PopMenu(menu) R.bagDesc:Hide() G:Advance() end,
        onMove = function(i, menu)
            local it = menu.items[i].item
            R.bagDesc:SetShown(it ~= nil)
            if it then R.bagDesc.fs:SetText(D.items[it].desc) end
        end })
end

---------------------------------------------------------------------------
-- Battle
---------------------------------------------------------------------------

local BT = { busy = nil }     -- playback state

local function InfoBox(f, side)
    -- the snapshot of the last played event (never the live creature: the engine is ahead of the playback)
    local s = BT.snap and BT.snap[side]
    if not s then f:Hide() return end
    f:Show()
    f.name:SetText(s.name)
    f.lvl:SetText("Lv" .. s.lvl)
    local sp = s.sp and D.species[s.sp]
    if sp then f.type:Set(D.types[sp.type].name:upper(), D.types[sp.type].color) else f.type:Hide() end
    if s.status then f.status:Set(D.status[s.status].short, D.status[s.status].color) else f.status:Hide() end
    local shownHP = f.animHP or s.hp
    f.hp:SetHP(shownHP / s.max)
    if f.hpText then f.hpText:SetText(string.format("%d / %d", floor(shownHP + 0.5), s.max)) end
    if f.exp then f.exp:Set(f.animExp or s.exp, 0.35, 0.65, 0.95) end
end

local function RefreshBattleBoxes()
    InfoBox(R.foeBox, "foe")
    InfoBox(R.allyBox, "ally")
end

local function BattleModelFor(side) return side == "foe" and R.foeModel or R.allyModel end

local function OpenFightMenu()
    local b = G.battle
    local mon = b.ally.mon
    local items = {}
    for i = 1, 4 do
        local mv = mon.moves[i]
        if mv then
            local md = D.moves[mv.id]
            items[i] = { text = md.name, move = mv, onSelect = function(idx, menu)
                if mv.pp <= 0 then
                    Message("There's no PP left for this move!")
                    return
                end
                PopMenu(menu)
                R.moveInfo:Hide()
                UI:BattleAct({ kind = "move", idx = idx })
            end }
        else
            items[i] = { text = "-", disabled = true }
        end
    end
    local info = R.moveInfo
    -- the move list replaces FIGHT / BAG / PARTY / RUN (which comes back on cancel)
    local actionMenu = stack[#stack]
    if actionMenu then actionMenu.frame:Hide() end
    R.textbox:Hide()
    PushMenu(items, { anchor = { "BOTTOMLEFT", screen, "BOTTOMLEFT", 0, 0 }, w = SW - 170, h = BOX_H, rowH = 38, cols = 2,
        level = 70, onCancel = function(menu)
            PopMenu(menu)
            info:Hide()
            if actionMenu then actionMenu.frame:Show() end
            R.textbox:Show()
        end,
        onMove = function(i, menu)
            local mv = menu.items[i].move
            info:Show()
            if mv then
                local md = D.moves[mv.id]
                local frac = mv.pp / md.pp
                info.pp:SetText(string.format("PP  %d/%d", mv.pp, md.pp))
                if frac <= 0.25 then info.pp:SetTextColor(0.86, 0.25, 0.2)
                elseif frac <= 0.5 then info.pp:SetTextColor(0.9, 0.55, 0.1)
                else info.pp:SetTextColor(INK[1], INK[2], INK[3]) end
                info.type:Set(D.types[md.type].name:upper(), D.types[md.type].color)
                info.power:SetText(md.power > 0 and ("Power " .. md.power) or "Status move")
            else
                info.pp:SetText("") info.type:Hide() info.power:SetText("")
            end
        end })
end

local function OpenActionMenu()
    local b = G.battle
    SetText(string.format("What will\n%s do?", M.Name(b.ally.mon)), { lines = 3 })
    text.shown = 999
    local items = {
        { text = "FIGHT", onSelect = function() OpenFightMenu() end },
        { text = "BAG", onSelect = function()
            if b.pvp then Message("Items can't be used in a battle between players.") return end
            OpenBag("battle", function(id, bagMenu)
                local def = D.items[id]
                local function act(target)
                    CloseAllMenus()
                    R.bagDesc:Hide()
                    UI:BattleAct({ kind = "item", item = id, target = target })
                end
                if def.use == "ball" then
                    act(nil)
                else
                    OpenParty("item", function(idx, partyMenu)
                        if partyMenu then PopMenu(partyMenu) end
                        if not idx then return end
                        local mon = G.save.party[idx]
                        local useless = mon.hp <= 0 or (def.use == "heal" and mon.hp >= M.MaxHP(mon))
                            or (def.use == "cure" and mon.status ~= def.cures)
                        if useless then Message("It won't have any effect.") return end
                        act(idx)
                    end)
                end
            end)
        end },
        { text = "PARTY", onSelect = function()
            OpenParty("battle", function(idx)
                if idx then
                    CloseAllMenus()
                    UI:BattleAct({ kind = "switch", idx = idx })
                end
            end)
        end },
        { text = "RUN", onSelect = function(_, menu)
            if b.pvp then                                 -- running from a player = forfeiting the match
                PushMenu({
                    { text = "Forfeit", onSelect = function()
                        CloseAllMenus()
                        UI:BattleAct({ kind = "forfeit" })
                    end },
                    { text = "Keep fighting", onSelect = function(_, m) PopMenu(m) end },
                }, { w = 220, x = SW - 226, y = -(SH - BOX_H - 110), title = "Forfeit the match?",
                     onCancel = function(m) PopMenu(m) end })
                return
            end
            PopMenu(menu)
            UI:BattleAct({ kind = "run" })
        end },
    }
    PushMenu(items, { anchor = { "BOTTOMRIGHT", screen, "BOTTOMRIGHT", 0, 0 }, w = 230, h = BOX_H, rowH = 38, cols = 2,
        level = 70, onCancel = function() end })
end

function UI:BattleAct(action)
    local b = G.battle
    if not b then return end
    CloseAllMenus()
    ClearText()
    if not b:Act(action) then
        Message("It won't have any effect.", function() BT.needShown = nil end)
    end
    BT.needShown = nil
end

local function OpenLearnMenu()
    local b = G.battle
    local q = b.learning
    local items = {}
    for i, mv in ipairs(q.mon.moves) do
        items[i] = { text = D.moves[mv.id].name, onSelect = function(idx, menu)
            PopMenu(menu)
            b:ResolveLearn(idx)
            BT.needShown = nil
        end }
    end
    items[#items + 1] = { text = "Don't learn " .. D.moves[q.move].name, onSelect = function(_, menu)
        PopMenu(menu)
        b:ResolveLearn(nil)
        BT.needShown = nil
    end }
    PushMenu(items, { w = 280, x = SW - 286, y = -60, rowH = 30, level = 70, title = "FORGET WHICH MOVE?",
        onCancel = function() end })
end

local BATTLE_THEMES = {
    elwynn = { sky = { 0.86, 0.94, 0.90 }, bands = { { 0.95, 0.98, 0.93 }, { 0.91, 0.96, 0.92 } },
               field = { 0.80, 0.91, 0.66 }, stripe = { 0.70, 0.85, 0.60 }, lines = { 0.74, 0.87, 0.60 },
               platform = PLATFORM },
    -- Westfall: pale dusty sky over dry golden fields
    westfall = { sky = { 0.97, 0.92, 0.80 }, bands = { { 0.99, 0.97, 0.90 }, { 0.98, 0.94, 0.85 } },
                 field = { 0.91, 0.82, 0.56 }, stripe = { 0.80, 0.68, 0.40 }, lines = { 0.86, 0.75, 0.48 },
                 platform = PLATFORM .. "_w" },
}

local function ApplyBattleTheme(name)
    local t = BATTLE_THEMES[name] or BATTLE_THEMES.elwynn
    local bg = R.bg
    bg.sky:SetColorTexture(t.sky[1], t.sky[2], t.sky[3], 1)
    bg.field:SetColorTexture(t.field[1], t.field[2], t.field[3], 1)
    bg.stripe:SetColorTexture(t.stripe[1], t.stripe[2], t.stripe[3], 1)
    for i, band in ipairs(bg.skyBands) do band:SetColorTexture(t.bands[i][1], t.bands[i][2], t.bands[i][3], 1) end
    for _, band in ipairs(bg.fieldBands) do band:SetColorTexture(t.lines[1], t.lines[2], t.lines[3], 1) end
    for _, p in ipairs(bg.platforms) do SetPixelTexture(p, t.platform) end
end

local function StartBattleView(b)
    ApplyBattleTheme(G.map and G.map.def.theme)
    BT.battle = b
    BT.anim, BT.needShown, BT.ended, BT.snap, BT.lastNeed = nil, nil, nil, nil, nil
    BT.intro = 0.95
    R.battle:Show()
    world:Hide()
    R.foeBox:Hide() R.allyBox:Hide()
    R.foeBox.animHP, R.allyBox.animHP, R.allyBox.animExp = nil, nil, nil
    R.net:Hide()
    -- Load and measure both leads right away, invisibly: the fit samples the idle animation for SAMPLE_TIME,
    -- which then happens during the intro text instead of delaying the send-out.
    ShowCreature(R.foeModel, b.foe.mon.sp, -0.7)
    ShowCreature(R.allyModel, b.ally.mon.sp, 0.8)
    R.foeModel:SetAlpha(0) R.allyModel:SetAlpha(0)
end

local function EndBattleView()
    BT.battle = nil
    R.battle:Hide()
    world:Show()
    CloseAllMenus()
    ClearText()
end

-- Plays one event. Sets BT.anim = { t, dur, fn(frac), done } for timed animations.
local function PlayEvent(e)
    local prev = BT.snap
    BT.snap = e.snap or BT.snap
    local b = BT.battle
    if e.t == "text" then
        SetText(e.text, { auto = 1.0, onDone = function() BT.anim = nil ClearText() end })
        BT.anim = { waitText = true }
    elseif e.t == "send" then
        local m = BattleModelFor(e.side)
        ShowCreature(m, e.mon.sp, e.side == "foe" and -0.7 or 0.8)
        m:SetAlpha(0)
        local box = e.side == "foe" and R.foeBox or R.allyBox
        box.animHP, box.animExp = nil, nil
        box.mon = e.mon
        local from = e.side == "foe" and 260 or -260
        -- hold the slide-in until the model has been measured (a creature switched in mid-battle), at most 3 s
        BT.anim = { t = 0, dur = 0.5, hold = function() return m.fit ~= nil end, fn = function(f)
            local ease = 1 - (1 - f) * (1 - f)
            m:SetAlpha(min(1, f * 2))
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", R.battle, "TOPLEFT", m.baseX + from * (1 - ease), m.baseY)
            RefreshBattleBoxes()
        end, done = function()
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", R.battle, "TOPLEFT", m.baseX, m.baseY)
        end }
    elseif e.t == "recall" then
        local m = BattleModelFor(e.side)
        BT.anim = { t = 0, dur = 0.35, fn = function(f) m:SetAlpha(1 - f) end, done = function() m:Hide() m.sp = nil end }
    elseif e.t == "attack" then
        local m = BattleModelFor(e.side)
        local other = BattleModelFor(e.side == "ally" and "foe" or "ally")
        Anim(m, 16)
        local x0 = m.baseX
        local dx = e.side == "ally" and 30 or -30
        BT.anim = { t = 0, dur = 0.55, fn = function(f)
            local lunge = f < 0.3 and (f / 0.3) or max(0, 1 - (f - 0.3) / 0.3)
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", R.battle, "TOPLEFT", x0 + dx * lunge, m.baseY + (e.side == "ally" and 10 or -6) * lunge)
            if f > 0.35 then other:SetAlpha(floor(f * 16) % 2 == 0 and 0.25 or 1) end
        end, done = function()
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", R.battle, "TOPLEFT", x0, m.baseY)
            other:SetAlpha(1)
            Anim(m, 0)
        end }
    elseif e.t == "hp" then
        local box = e.side == "foe" and R.foeBox or R.allyBox
        local dur = min(1.0, 0.25 + math.abs(e.to - e.from) / e.max * 0.9)
        BT.anim = { t = 0, dur = dur, fn = function(f)
            box.animHP = e.from + (e.to - e.from) * f
            RefreshBattleBoxes()
        end, done = function() box.animHP = nil RefreshBattleBoxes() end }
    elseif e.t == "faint" then
        local m = BattleModelFor(e.side)
        Anim(m, 1)
        BT.anim = { t = 0, dur = 0.7, fn = function(f) m:SetAlpha(1 - f) end,
                    done = function() m:Hide() m.sp = nil m:SetAlpha(1) if e.side == "foe" then R.foeBox:Hide() end end }
    elseif e.t == "status" or e.t == "level" then
        R.allyBox.animExp = nil
        RefreshBattleBoxes()
    elseif e.t == "exp" then
        if e.mon == b.ally.mon then
            local from = (prev and prev.ally and prev.ally.exp) or 0
            local to = e.snap.ally.exp
            if to < from then from = 0 end
            BT.anim = { t = 0, dur = 0.8, fn = function(f)
                R.allyBox.animExp = from + (to - from) * f
                RefreshBattleBoxes()
            end, done = function() R.allyBox.animExp = nil RefreshBattleBoxes() end }
        end
    elseif e.t == "throw" then
        local net, fm = R.net, R.foeModel
        net:Show()
        local shakes = e.shakes
        local caught = e.caught
        local total = 0.6 + shakes * 0.6 + 0.5
        BT.anim = { t = 0, dur = total, fn = function(f)
            local t = f * total
            if t < 0.6 then
                local p = t / 0.6
                net:ClearAllPoints()
                net:SetPoint("CENTER", R.battle, "TOPLEFT", 90 + (400 - 90) * p, -300 + (300 - 150) * p - math.sin(p * math.pi) * 120)
                Rot(net, p * 6)
            else
                fm:SetAlpha(0)
                local k = t - 0.6
                local wob = (k < shakes * 0.6) and math.sin(k / 0.6 * math.pi * 2) * 0.5 or 0
                Rot(net, wob)
                net:ClearAllPoints()
                net:SetPoint("CENTER", R.battle, "TOPLEFT", 400, -150)
            end
        end, done = function()
            if caught then
                net:SetVertexColor(0.6, 0.6, 0.6)
            else
                net:Hide()
                fm:SetAlpha(1)
            end
        end }
    elseif e.t == "end" then
        BT.ended = e.result
    end
end

local function UpdateBattle(dt)
    local b = BT.battle
    if not b then return end
    if BT.intro then
        BT.intro = BT.intro - dt
        R.flash:Show()
        if BT.intro > 0.45 then          -- three white flashes
            R.flash:SetColorTexture(1, 1, 1, 1)
            R.flash:SetAlpha(floor((BT.intro - 0.45) * 13) % 2 == 0 and 0.9 or 0)
        else                             -- then fade in from black
            R.flash:SetColorTexture(0, 0, 0, 1)
            R.flash:SetAlpha(max(0, BT.intro / 0.45))
        end
        if BT.intro > 0 then return end
        BT.intro = nil
        R.flash:Hide()
    end
    local a = BT.anim
    if a then
        if a.waitText then UpdateText(dt) return end
        if a.hold and a.hold() and (a.held or 0) < 3 then
            a.held = (a.held or 0) + dt
            return
        end
        a.t = a.t + dt
        local f = min(1, a.t / a.dur)
        if a.fn then a.fn(f) end
        if f >= 1 then
            BT.anim = nil
            if a.done then a.done() end
        end
        return
    end
    if uiMessage then UpdateText(dt) return end
    local e = b:Pop()
    if e then PlayEvent(e) return end
    UpdateText(dt)
    -- a player battle goes action -> wait -> action by itself (the opponent's move arrives): re-prompt
    if b.need ~= BT.lastNeed then
        BT.lastNeed = b.need
        BT.needShown = nil
    end
    if BT.needShown then return end
    if b.need == "wait" then
        BT.needShown = true
        SetText(string.format("Waiting for %s...", b.pvp and b.pvp.name or "the other player"), { lines = 3 })
        text.shown = 999
    elseif b.need == "action" then
        BT.needShown = true
        RefreshBattleBoxes()
        OpenActionMenu()
    elseif b.need == "switch" then
        BT.needShown = true
        Message("Choose a beast to send out.", function()
            OpenParty("forced", function(idx)
                if idx then
                    CloseAllMenus()
                    b:Act({ kind = "switch", idx = idx })
                    BT.needShown = nil
                end
            end)
        end)
    elseif b.need == "learn" then
        BT.needShown = true
        OpenLearnMenu()
    elseif b.need == "done" then
        BT.needShown = true
        local result = BT.ended or b.result
        EndBattleView()
        G:Advance(result)
    end
end

---------------------------------------------------------------------------
-- Overworld rendering
---------------------------------------------------------------------------

local grid = {}            -- [i][j] = { base, over }
local sprites = {}         -- pool for NPCs
local waterFrame = "water1"
local torchFrame = "torch1"

local function BuildWorld()
    world = CreateFrame("Frame", nil, screen)
    world:SetAllPoints()
    for i = 0, VW + 1 do
        grid[i] = {}
        for j = 0, VH + 1 do
            local base = Tex(world, "BACKGROUND", 0)
            base:SetSize(TILE, TILE)
            SetPixelTexture(base, ATLAS)
            local over = Tex(world, "BORDER", 0)
            over:SetSize(TILE, TILE)
            SetPixelTexture(over, ATLAS)
            grid[i][j] = { base = base, over = over }
        end
    end
    R.player = Tex(world, "ARTWORK", 2)
    R.player:SetSize(TILE, TILE)
    SetPixelTexture(R.player, CHARS)
    R.player:SetPoint("TOPLEFT", world, "TOPLEFT", HX * TILE, -HY * TILE)
    R.grassOver = Tex(world, "ARTWORK", 5)
    R.grassOver:SetSize(TILE, TILE * 0.45)
    SetPixelTexture(R.grassOver, ATLAS)
    R.grassOver:SetPoint("BOTTOMLEFT", R.player, "BOTTOMLEFT", 0, 0)
    local i = A.tall_c
    local c, r = i % 16, floor(i / 16)
    R.grassOver:SetTexCoord(c * 16 / 256, (c + 1) * 16 / 256, (r * 16 + 16 * 0.55) / 256, (r + 1) * 16 / 256)

    R.banner = Box(world, 220, 44, 30)
    R.banner:SetPoint("TOPLEFT", 8, -8)
    R.banner.fs = Font(R.banner, 16, nil, true)
    R.banner.fs:SetPoint("CENTER")
    R.banner.fs:SetJustifyH("CENTER")
    R.banner.fs:SetJustifyV("MIDDLE")

    R.fade = Tex(screen, "OVERLAY", 7)
    R.fade:SetAllPoints()
    R.fade:SetColorTexture(0, 0, 0, 1)
    R.fade:Hide()
end

local function Sprite(i)
    local s = sprites[i]
    if not s then
        s = Tex(world, "ARTWORK", 1)
        s:SetSize(TILE, TILE)
        SetPixelTexture(s, CHARS)
        s.bang = Font(world, 26)
        s.bang:SetText("!")
        s.bang:SetTextColor(0.9, 0.2, 0.2)
        sprites[i] = s
    end
    return s
end

local peerSprites = {}
local function PeerSprite(i)
    local s = peerSprites[i]
    if not s then
        s = Tex(world, "ARTWORK", 0)
        s:SetSize(TILE, TILE)
        SetPixelTexture(s, CHARS)
        s.label = world:CreateFontString(nil, "OVERLAY")
        if not s.label:SetFont(FONT_BOLD, 14, "OUTLINE") then s.label:SetFont(FONT_FALLBACK, 10, "OUTLINE") end
        s.label:SetPoint("BOTTOM", s, "TOP", 0, -2)
        peerSprites[i] = s
    end
    return s
end

local function Lerp(a, b, f) return a + (b - a) * f end

local function DrawWorld()
    local s = G.save
    local m = G.map
    if not m then return end
    local px, py = s.x, s.y
    local walking = false
    if G.moving then
        local f = min(1, G.moving.t / G.moving.dur)
        px, py = Lerp(G.moving.fromX, s.x, f), Lerp(G.moving.fromY, s.y, f)
        walking = f < 1
    end
    waterFrame = (floor(now * 1.6) % 2 == 0) and "water1" or "water2"
    torchFrame = "torch" .. (floor(now * 6) % 3 + 1)
    local fx, fy = floor(px), floor(py)
    local ox, oy = (px - fx) * TILE, (py - fy) * TILE
    local outdoor = m.def.outdoor
    for i = 0, VW + 1 do
        for j = 0, VH + 1 do
            local wx, wy = fx - HX - 1 + i, fy - HY - 1 + j
            local cell = grid[i][j]
            local base, over
            if wx < 0 or wy < 0 or wx >= m.w or wy >= m.h then
                if outdoor then base, over = m.theme.grass1, m.theme.tree else base = "void" end
            else
                local k = m.key(wx, wy)
                base, over = m.base[k], m.over[k]
                if over == "torch1" then over = torchFrame end
                if m.water[k] then base = waterFrame end
                if m.chest[k] then over = G:Flag("chest_" .. m.chest[k].id) and "chest_open" or "chest" end
            end
            SetTile(cell.base, base)
            SetTile(cell.over, over)
            local x, y = (i - 1) * TILE - ox, -((j - 1) * TILE - oy)
            if cell.x ~= x or cell.y ~= y then
                cell.x, cell.y = x, y
                cell.base:ClearAllPoints()
                cell.base:SetPoint("TOPLEFT", world, "TOPLEFT", x, y)
                cell.over:ClearAllPoints()
                cell.over:SetPoint("TOPLEFT", world, "TOPLEFT", x, y)
            end
        end
    end
    -- player
    local frame = 1
    if walking or (G.bump and G.input.dir) then
        local f = G.moving and (G.moving.t / G.moving.dur) or (G.bump and (0.2 - G.bump) / 0.2 or 0)
        if f > 0.2 and f < 0.8 then frame = G.stepParity and 0 or 2 end
    end
    SetChar(R.player, "hero", s.face, frame)
    local onTall = m.tall[m.key(s.x, s.y)] and not walking
    R.grassOver:SetShown(onTall and true or false)
    -- npcs
    local n = 0
    for _, npc in ipairs(G.npcs) do
        if not npc.hidden then
            n = n + 1
            local sp = Sprite(n)
            local nx, ny = npc.x, npc.y
            local nframe = 1
            if npc.moving then
                local f = min(1, npc.moving.t / npc.moving.dur)
                nx, ny = Lerp(npc.fromX, npc.x, f), Lerp(npc.fromY, npc.y, f)
                if f > 0.2 and f < 0.8 then nframe = (npc.fromX + npc.fromY) % 2 == 0 and 0 or 2 end
            end
            local sx, sy = (nx - px + HX) * TILE, -(ny - py + HY) * TILE
            sp:ClearAllPoints()
            sp:SetPoint("TOPLEFT", world, "TOPLEFT", sx, sy)
            SetChar(sp, npc.def.sprite or "bald", npc.face, nframe)
            local t = npc.def.tint
            if t then sp:SetVertexColor(t[1], t[2], t[3]) else sp:SetVertexColor(1, 1, 1) end
            sp:Show()
            sp.bang:ClearAllPoints()
            sp.bang:SetPoint("BOTTOM", sp, "TOP", 0, -4)
            sp.bang:SetShown(npc.exclaim ~= nil)
        end
    end
    for i = n + 1, #sprites do sprites[i]:Hide() sprites[i].bang:Hide() end
    -- other players (guildmates), drawn with the hero sprite in their class colour and a name tag
    local pn = 0
    for _, p in ipairs(ns.AzeroNet:PeersOn(m.id)) do
        pn = pn + 1
        local sp = PeerSprite(pn)
        local nx, ny, pframe = p.x, p.y, 1
        if p.moving then
            local f = min(1, p.moving.t / p.moving.dur)
            nx, ny = Lerp(p.moving.fromX, p.x, f), Lerp(p.moving.fromY, p.y, f)
            if f > 0.2 and f < 0.8 then pframe = (p.moving.fromX + p.moving.fromY) % 2 == 0 and 0 or 2 end
        end
        sp:ClearAllPoints()
        sp:SetPoint("TOPLEFT", world, "TOPLEFT", (nx - px + HX) * TILE, -(ny - py + HY) * TILE)
        SetChar(sp, "hero", p.face or "down", pframe)
        local cc = RAID_CLASS_COLORS and p.class and RAID_CLASS_COLORS[p.class]
        if cc then
            sp:SetVertexColor(0.55 + cc.r * 0.45, 0.55 + cc.g * 0.45, 0.55 + cc.b * 0.45)
            sp.label:SetTextColor(cc.r, cc.g, cc.b)
        else
            sp:SetVertexColor(1, 1, 1)
            sp.label:SetTextColor(1, 1, 1)
        end
        sp.label:SetText(p.name)
        sp:Show()
        sp.label:Show()
    end
    for i = pn + 1, #peerSprites do peerSprites[i]:Hide() peerSprites[i].label:Hide() end
    -- banner / fade
    if G.banner then
        R.banner:Show()
        R.banner.fs:SetText(G.banner.text)
        R.banner:SetWidth(max(200, (R.banner.fs:GetStringWidth() or 0) + 48))
        local shown = max(0, min(1, (2.2 - G.banner.t) / 0.25, G.banner.t / 0.3))   -- slide down, then up
        R.banner:ClearAllPoints()
        R.banner:SetPoint("TOPLEFT", world, "TOPLEFT", 8, -8 + (1 - shown) * 60)
    else
        R.banner:Hide()
    end
    if G.fade then
        R.fade:Show()
        R.fade:SetAlpha(min(1, G.fade / 0.3))
    else
        R.fade:Hide()
    end
end

---------------------------------------------------------------------------
-- Pending prompts from the engine
---------------------------------------------------------------------------

local shownPending = nil

local function SyncPending()
    local p = G.pending
    if p == shownPending then return end
    shownPending = p
    if not p then
        if not uiMessage then ClearText() end
        return
    end
    if p.kind == "text" then
        SetText(p.text, { onDone = function() G:Advance() end })
    elseif p.kind == "choice" then
        SetText(p.text, { lines = 3 })
        text.shown = 999
        local items = {}
        for i, o in ipairs(p.options) do
            items[i] = { text = o, onSelect = function(idx, menu)
                PopMenu(menu)
                ClearText()
                G:Advance(idx)
            end }
        end
        PushMenu(items, { w = 130, x = SW - 136, y = -(SH - BOX_H - 4 - (#items * 32 + 24)), level = 60,
            onCancel = function(menu)
                PopMenu(menu)
                ClearText()
                G:Advance(p.cancel)
            end })
    elseif p.kind == "battle" then
        ClearText()
        StartBattleView(p.battle)
    elseif p.kind == "shop" then
        ClearText()
        OpenShop()
    elseif p.kind == "netwait" then
        SetText(p.text, { lines = 3 })
        text.shown = 999
    end
end

---------------------------------------------------------------------------
-- Title screen
---------------------------------------------------------------------------

local function ShowTitle()
    R.title:Show()
    world:Hide()
    CloseAllMenus()
    ClearText()
    for i, sp in ipairs(D.starters) do
        R.titleModels[i]:Show()
        R.titleModels[i].sp = nil
        ShowCreature(R.titleModels[i], sp, 0)
    end
    local items = {}
    if G:HasSave() then
        items[#items + 1] = { text = "CONTINUE", onSelect = function(_, menu)
            PopMenu(menu)
            R.title:Hide()
            world:Show()
            G:Load()
        end }
    end
    items[#items + 1] = { text = "NEW GAME", onSelect = function(_, menu)
        local function start()
            PopMenu(menu)
            R.title:Hide()
            world:Show()
            G:NewGame()
            G:Run(function(g)
                g:Say("Welcome to Azeroth, the world of AZEROMON!")
                g:Say("From the forests of Elwynn to the jungles of Un'Goro, beasts of every kind roam these lands. Hunters tame them as companions and fight side by side.")
                g:Say("Your journey begins in Goldshire, in the heart of Elwynn Forest. Good luck, {PLAYER}!")
            end)
        end
        if G:HasSave() then
            PushMenu({
                { text = "Overwrite", onSelect = function(_, m) PopMenu(m) start() end },
                { text = "Cancel", onSelect = function(_, m) PopMenu(m) end },
            }, { w = 150, anchor = { "TOP", screen, "CENTER", 0, -120 }, level = 80, title = "Erase your save?",
                onCancel = function(m) PopMenu(m) end })
        else
            start()
        end
    end }
    PushMenu(items, { w = 170, anchor = { "TOP", screen, "CENTER", 0, -40 }, rowH = 32, level = 60,
        onCancel = function() end })
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

local KEYMAP = {
    UP = "up", W = "up", DOWN = "down", S = "down", LEFT = "left", A = "left", RIGHT = "right", D = "right",
    SPACE = "A", Z = "A", E = "A",
    X = "B", Q = "B", BACKSPACE = "B",
    ENTER = "START", TAB = "START", M = "START",
}
local heldDirs = {}

local function CurrentDir()
    local best, bestAt
    for d, at in pairs(heldDirs) do
        if not bestAt or at > bestAt then best, bestAt = d, at end
    end
    return best
end

local function SetFocus(on)
    focused = on and true or false
    if root then
        pcall(root.EnableKeyboard, root, focused)
        focusOverlay:SetShown(not focused)
    end
    wipe(heldDirs)
    G:SetDir(nil)
    G.input.run = false
end

local function HandleKey(key)
    if R.title:IsShown() then
        if stack[#stack] then MenuKey(stack[#stack], key) end
        return
    end
    -- UI messages and menus first
    if uiMessage then
        if key == "A" or key == "B" then TextA() end
        return
    end
    local top = stack[#stack]
    if top then
        if top.onLeftRight and (key == "left" or key == "right" or key == "up" or key == "down") then
            top.onLeftRight(key)
            return
        end
        if top.isSummary then
            if key == "A" or key == "B" then top.opts.onCancel(top) R.summary:Hide() end
            return
        end
        MenuKey(top, key)
        return
    end
    if BT.battle then
        if key == "A" or key == "B" then TextA() end
        return
    end
    local p = G.pending
    if p then
        if p.kind == "text" and (key == "A" or key == "B") then
            if not TextA() and text.done then G:Advance() end
        elseif p.kind == "netwait" and key == "B" then
            G:Advance("cancel")
        end
        return
    end
    if key == "A" then
        G:PressA()
    elseif key == "START" and G:IsFree() then
        OpenStartMenu()
    end
end

local function OnKeyDown(self, key)
    if key == "ESCAPE" then
        SetFocus(false)
        pcall(self.SetPropagateKeyboardInput, self, true)
        return
    end
    local k = KEYMAP[key]
    if not InCombatLockdown() and self.SetPropagateKeyboardInput then
        pcall(self.SetPropagateKeyboardInput, self, k == nil)
    end
    if not k then return end
    if k == "up" or k == "down" or k == "left" or k == "right" then
        heldDirs[k] = GetTime()
        local busy = #stack > 0 or uiMessage or G.pending or BT.battle or R.title:IsShown()
        if busy then HandleKey(k) else G:SetDir(CurrentDir()) end
        return
    end
    if k == "B" then G.input.run = true end
    HandleKey(k)
end

local function OnKeyUp(self, key)
    local k = KEYMAP[key]
    if k == "up" or k == "down" or k == "left" or k == "right" then
        heldDirs[k] = nil
        G:SetDir(CurrentDir())
    elseif k == "B" then
        G.input.run = false
    end
end

---------------------------------------------------------------------------
-- Frame update
---------------------------------------------------------------------------

local function OnUpdate(self, elapsed)
    now = now + elapsed
    FitScenes()
    if R.title:IsShown() or not G.started then
        ns.AzeroNet:SetActive(false)
        return
    end
    -- visible with a save loaded: guildmates may see us (Net sends at most once a second)
    ns.AzeroNet:SetActive(true)
    ns.AzeroNet:Update(elapsed)
    ns.AzeroPvP:Update()
    -- directions pressed while a menu was open do not walk once it closes
    local busy = #stack > 0 or uiMessage
    if busy then G:SetDir(nil) elseif focused then G:SetDir(CurrentDir()) end
    if not BT.battle then G:Update(elapsed) end
    SyncPending()
    if BT.battle then
        UpdateBattle(elapsed)
    else
        DrawWorld()
        UpdateText(elapsed)
    end
    R.speciesModel:SetShown(G.showSpecies ~= nil)
    if G.showSpecies then ShowCreature(R.speciesModel, G.showSpecies, 0.3) end
    if R.money:IsShown() then
        R.money.fs:SetText("Money: " .. D.Money(G.save.money) .. "\nBadges: " .. G:BadgeCount())
        if #stack == 0 then R.money:Hide() end
    end
    if R.bagDesc:IsShown() and #stack == 0 then R.bagDesc:Hide() end
    if R.log:IsShown() and #stack == 0 then R.log:Hide() end
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function BuildBattle()
    local b = CreateFrame("Frame", nil, screen)
    b:SetAllPoints()
    b:SetFrameLevel(screen:GetFrameLevel() + 20)
    R.battle = b
    -- backdrop: sky, field, a horizon stripe, soft bands; recoloured per map theme (ApplyBattleTheme)
    local bg = {}
    R.bg = bg
    bg.sky = Tex(b, "BACKGROUND", 0)
    bg.sky:SetPoint("TOPLEFT") bg.sky:SetPoint("TOPRIGHT") bg.sky:SetHeight(SH * 0.45)
    bg.field = Tex(b, "BACKGROUND", 0)
    bg.field:SetPoint("TOPLEFT", bg.sky, "BOTTOMLEFT") bg.field:SetPoint("BOTTOMRIGHT")
    bg.stripe = Tex(b, "BACKGROUND", 1)
    bg.stripe:SetPoint("TOPLEFT", bg.sky, "BOTTOMLEFT") bg.stripe:SetPoint("TOPRIGHT", bg.sky, "BOTTOMRIGHT")
    bg.stripe:SetHeight(6)
    bg.skyBands, bg.fieldBands = {}, {}
    for i = 1, 2 do
        local band = Tex(b, "BACKGROUND", 1)
        band:SetPoint("TOPLEFT", 0, -(i - 1) * 40)
        band:SetPoint("TOPRIGHT", 0, -(i - 1) * 40)
        band:SetHeight(40)
        bg.skyBands[i] = band
    end
    for i = 1, 3 do
        local band = Tex(b, "BACKGROUND", 1)
        band:SetPoint("TOPLEFT", bg.field, "TOPLEFT", 0, -20 - i * 34)
        band:SetPoint("TOPRIGHT", bg.field, "TOPRIGHT", 0, -20 - i * 34)
        band:SetHeight(3)
        bg.fieldBands[i] = band
    end

    local fp = Tex(b, "BORDER")
    fp:SetSize(240, 60)
    fp:SetPoint("CENTER", b, "TOPLEFT", 392, -178)
    local ap = Tex(b, "BORDER")
    ap:SetSize(280, 70)
    ap:SetPoint("CENTER", b, "TOPLEFT", 136, -SH + BOX_H + 22)
    bg.platforms = { fp, ap }

    R.foeModel = NewModel(b, 200, 190)
    R.foeModel.baseX, R.foeModel.baseY = 392 - 100, -200
    R.foeModel.groundY = R.foeModel.baseY
    R.foeModel:SetPoint("BOTTOMLEFT", b, "TOPLEFT", R.foeModel.baseX, R.foeModel.baseY)
    R.foeModel:SetFrameLevel(b:GetFrameLevel() + 2)
    R.allyModel = NewModel(b, 250, 250)
    R.allyModel.camScale = 1.1
    R.allyModel.baseX, R.allyModel.baseY = 136 - 125, -SH + BOX_H + 6
    R.allyModel.groundY = R.allyModel.baseY
    R.allyModel:SetPoint("BOTTOMLEFT", b, "TOPLEFT", R.allyModel.baseX, R.allyModel.baseY)
    R.allyModel:SetFrameLevel(b:GetFrameLevel() + 2)

    -- HP boxes, laid out like the GBA games: name + type, level, status; an "HP" tag and bar;
    -- the player's box adds HP numbers and the EXP bar.
    local function info(w, h, withNumbers)
        local f = Box(b, w, h, b:GetFrameLevel() + 5)
        f.name = Font(f, 15, nil, true) f.name:SetPoint("TOPLEFT", 16, -13)
        f.type = Pill(f, 58, 16, 14)
        f.type:SetPoint("LEFT", f.name, "RIGHT", 6, 0)
        f.lvl = Font(f, 14, nil, true) f.lvl:SetPoint("TOPRIGHT", -16, -13) f.lvl:SetJustifyH("RIGHT")
        f.status = Pill(f, 40, 16, 14)
        f.status:SetPoint("RIGHT", f.lvl, "LEFT", -6, 0)
        local tag = CreateFrame("Frame", nil, f)
        tag:SetSize(30, 14)
        tag:SetPoint("TOPLEFT", 16, -38)
        Rounded(tag, 0, 2, 0.30, 0.30, 0.34, 0, "ARTWORK")
        local hpl = tag:CreateFontString(nil, "OVERLAY")
        if not hpl:SetFont(FONT_BOLD, 14, "") then hpl:SetFont(FONT_FALLBACK, 9, "") end
        hpl:SetPoint("CENTER", 0, 1)
        hpl:SetText("HP")
        hpl:SetTextColor(0.98, 0.72, 0.18)
        f.hp = Bar(f, w - 64, 10)
        f.hp.bg:SetPoint("LEFT", tag, "RIGHT", 2, 0)
        if withNumbers then
            f.hpText = Font(f, 14) f.hpText:SetPoint("TOPRIGHT", -16, -55) f.hpText:SetJustifyH("RIGHT")
            local el = Font(f, 10, nil, true) el:SetPoint("BOTTOMLEFT", 16, 10) el:SetText("EXP")
            el:SetTextColor(0.25, 0.45, 0.75)
            f.exp = Bar(f, w - 70, 6)
            f.exp.bg:SetPoint("BOTTOMRIGHT", -16, 12)
        end
        f:Hide()
        return f
    end
    R.foeBox = info(250, 62)
    R.foeBox:SetPoint("TOPLEFT", b, "TOPLEFT", 14, -18)
    R.allyBox = info(256, 96, true)
    R.allyBox:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -10, BOX_H + 8)

    R.net = Tex(b, "OVERLAY", 3)
    R.net:SetSize(34, 34)
    R.net:SetTexture("Interface\\Icons\\Ability_Hunter_BeastTaming")
    R.net:Hide()

    R.moveInfo = Box(b, 170, BOX_H, 75)
    R.moveInfo:SetPoint("BOTTOMRIGHT", screen, "BOTTOMRIGHT", 0, 0)
    R.moveInfo.pp = Font(R.moveInfo, 15, nil, true)
    R.moveInfo.pp:SetPoint("TOPLEFT", 18, -20)
    R.moveInfo.type = Pill(R.moveInfo, 80, 20, 16)
    R.moveInfo.type:SetPoint("TOPLEFT", 18, -48)
    R.moveInfo.power = Font(R.moveInfo, 13)
    R.moveInfo.power:SetPoint("TOPLEFT", 18, -76)
    R.moveInfo:Hide()

    R.flash = Tex(b, "OVERLAY", 7)
    R.flash:SetAllPoints()
    R.flash:SetColorTexture(0, 0, 0, 1)
    b:Hide()
end

function UI:CreatePanel(parent)
    root = CreateFrame("Frame", nil, parent)
    local bg = Tex(root, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 1)

    screen = CreateFrame("Frame", nil, root)
    screen:SetSize(SW, SH)
    screen:SetPoint("CENTER")
    pcall(screen.SetClipsChildren, screen, true)
    R.screen = screen

    BuildWorld()
    BuildBattle()

    -- text box
    R.textbox = Box(screen, SW, BOX_H, screen:GetFrameLevel() + 50)
    R.textbox:SetPoint("BOTTOMLEFT")
    R.textfs = Font(R.textbox, 17)
    R.textfs:SetPoint("TOPLEFT", 22, -20)
    R.textfs:SetPoint("BOTTOMRIGHT", -34, 14)
    R.textfs:SetSpacing(8)
    R.measure = Font(R.textbox, 17)
    R.measure:Hide()
    R.textArrow = Triangle(R.textbox, "down", 14, 0.88, 0.32, 0.26)
    R.textArrow:SetFrameLevel(R.textbox:GetFrameLevel() + 2)
    -- speaker tab
    R.nameTab = Box(screen, 120, 34, screen:GetFrameLevel() + 49)
    R.nameTab:SetPoint("BOTTOMLEFT", R.textbox, "TOPLEFT", 10, -6)
    R.nameTab.fs = Font(R.nameTab, 14, nil, true)
    R.nameTab.fs:SetPoint("LEFT", 16, 1)
    R.nameTab.fs:SetJustifyV("MIDDLE")
    R.nameTab.fs:SetTextColor(0.20, 0.36, 0.62)
    R.nameTab:Hide()
    R.textbox:SetScript("OnMouseDown", function()
        if uiMessage or (G.pending and G.pending.kind == "text") or (BT.battle and text.full) then HandleKey("A") end
    end)
    R.textbox:Hide()

    -- species portrait (starter choice, evolution)
    R.speciesModel = NewModel(screen, 220, 220)
    R.speciesModel:SetPoint("BOTTOM", screen, "BOTTOM", 0, BOX_H + 10)
    R.speciesModel:SetFrameLevel(screen:GetFrameLevel() + 45)
    R.speciesModel:Hide()

    -- money / descriptions / summary / log
    R.money = Box(screen, 170, 64, screen:GetFrameLevel() + 58)
    R.money:SetPoint("TOPLEFT", 8, -8)
    R.money.fs = Font(R.money, 15)
    R.money.fs:SetPoint("LEFT", 16, 0)
    R.money.fs:SetJustifyV("MIDDLE")
    R.money:Hide()

    R.bagDesc = Box(screen, SW, 80, screen:GetFrameLevel() + 75)
    R.bagDesc:SetPoint("BOTTOMLEFT")
    R.bagDesc.fs = Font(R.bagDesc, 15)
    R.bagDesc.fs:SetPoint("TOPLEFT", 18, -18)
    R.bagDesc.fs:SetPoint("BOTTOMRIGHT", -18, 12)
    R.bagDesc:Hide()

    R.summary = Box(screen, SW - 20, SH - 20, screen:GetFrameLevel() + 90)
    R.summary:SetPoint("CENTER")
    R.summary.noPool = true
    R.summary.title = Font(R.summary, 18, nil, true)
    R.summary.title:SetPoint("TOPLEFT", 22, -20)
    R.summary.title:SetTextColor(0.20, 0.36, 0.62)
    R.summary.body = Font(R.summary, 13)
    R.summary.body:SetPoint("TOPLEFT", 22, -58)
    R.summary.body:SetWidth(290)
    R.summary.body:SetSpacing(6)
    R.summary.model = NewModel(R.summary, 200, 240)
    R.summary.model:SetPoint("TOPRIGHT", -14, -40)
    local hint = Font(R.summary, 12)
    hint:SetPoint("BOTTOMRIGHT", -18, 14)
    hint:SetText("Space / X: close")
    R.summary:Hide()

    R.log = Box(screen, SW - 270, SH - 16, screen:GetFrameLevel() + 65)
    R.log:SetPoint("TOPRIGHT", -8, -8)
    R.log.model = NewModel(R.log, 220, 200)
    R.log.model:SetPoint("TOP", 0, -14)
    R.log.body = Font(R.log, 14)
    R.log.body:SetPoint("TOPLEFT", 16, -220)
    R.log.body:SetPoint("BOTTOMRIGHT", -16, 12)
    R.log:Hide()

    -- title
    R.title = CreateFrame("Frame", nil, screen)
    R.title:SetAllPoints()
    R.title:SetFrameLevel(screen:GetFrameLevel() + 30)
    local tbg = Tex(R.title, "BACKGROUND")
    tbg:SetAllPoints()
    tbg:SetColorTexture(0.12, 0.2, 0.35, 1)
    local logo = R.title:CreateFontString(nil, "OVERLAY")
    logo:SetFont(FONT, 46, "THICKOUTLINE")
    logo:SetText("AZEROMON")
    logo:SetTextColor(1, 0.82, 0.2)
    logo:SetPoint("TOP", 0, -34)
    local sub = R.title:CreateFontString(nil, "OVERLAY")
    sub:SetFont(FONT, 15, "OUTLINE")
    sub:SetText("Tame the beasts of Azeroth")
    sub:SetTextColor(0.9, 0.95, 1)
    sub:SetPoint("TOP", logo, "BOTTOM", 0, -6)
    R.titleModels = {}
    for i = 1, 3 do
        local m = NewModel(R.title, 150, 150)
        m:SetPoint("CENTER", R.title, "CENTER", (i - 2) * 160, 50)
        R.titleModels[i] = m
    end
    local credit = R.title:CreateFontString(nil, "OVERLAY")
    credit:SetFont(FONT, 10, "")
    credit:SetTextColor(0.7, 0.75, 0.85)
    credit:SetPoint("BOTTOM", 0, 8)
    credit:SetText("Pixel art: Tiny 16 by Lanea Zimmerman (Sharm), CC-BY  |  Tiles: Red_Voxel, CC-BY-SA  |  Font: Pixel Operator (CC0)")
    local keys = R.title:CreateFontString(nil, "OVERLAY")
    keys:SetFont(FONT, 12, "")
    keys:SetTextColor(0.85, 0.9, 1)
    keys:SetPoint("BOTTOM", credit, "TOP", 0, 8)
    keys:SetText("Arrows/WASD move   Space = A   X = B (hold to run)   Enter = menu   Esc = release keyboard")

    -- focus overlay
    focusOverlay = CreateFrame("Button", nil, root)
    focusOverlay:SetAllPoints(screen)
    focusOverlay:SetFrameLevel(screen:GetFrameLevel() + 120)
    local dim = Tex(focusOverlay, "BACKGROUND")
    dim:SetAllPoints()
    dim:SetColorTexture(0, 0, 0, 0.55)
    local fl = focusOverlay:CreateFontString(nil, "OVERLAY")
    fl:SetFont(FONT, 20, "OUTLINE")
    fl:SetText("Click to play")
    fl:SetTextColor(1, 0.9, 0.5)
    fl:SetPoint("CENTER")
    local fl2 = focusOverlay:CreateFontString(nil, "OVERLAY")
    fl2:SetFont(FONT, 12, "OUTLINE")
    fl2:SetText("The game takes the keyboard while it is active. Esc gives it back.")
    fl2:SetPoint("TOP", fl, "BOTTOM", 0, -8)
    focusOverlay:SetScript("OnClick", function()
        if InCombatLockdown() then ns:Print("Azeromon waits until you leave combat.") return end
        SetFocus(true)
    end)

    root:SetScript("OnKeyDown", OnKeyDown)
    root:SetScript("OnKeyUp", OnKeyUp)
    root:SetScript("OnUpdate", OnUpdate)
    root:SetScript("OnSizeChanged", function(self, w, h)
        if w and h and w > 0 and h > 0 then screen:SetScale(min(1, w / (SW + 8), h / (SH + 8))) end
    end)
    root:SetScript("OnHide", function() SetFocus(false) ns.AzeroNet:SetActive(false) end)

    root.OnGameShown = function()
        if not G.started then ShowTitle() end
    end
    root.OnGameHidden = function() SetFocus(false) ns.AzeroNet:SetActive(false) end
    SetFocus(false)
    ShowTitle()
    return root
end

function UI:OnInit()
    ns:On("GAMES_COMBAT", function(inCombat)
        if inCombat then SetFocus(false) end
    end)
    ns:RegisterSlash("azeromon", function(rest)
        local cmd, a, b = (rest or ""):match("^%s*(%S*)%s*(%S*)%s*(%S*)")
        cmd = (cmd or ""):lower()
        local d = G:Data()
        if cmd == "flip" then
            d.flipFacing = not d.flipFacing
            ns:Print("Azeromon: battle models turned the other way.")
        elseif cmd == "models" then
            -- what the auto-fit measured for the models on screen (paste this if a creature looks wrong)
            for label, m in pairs({ enemy = R.foeModel, yours = R.allyModel }) do
                if m and m.isScene and m.sp then
                    local function fmt(b) return b and string.format("%.2f %.2f %.2f / %.2f %.2f %.2f", unpack(b)) or "none" end
                    local fi = m.fitInfo
                    ns:Print("Azeromon %s: %s scale=%.3f yaw=%.2f cam=%.2f", label, m.sp, m.fitted or 0, m.facing or 0, m.camZ or 0)
                    ns:Print("   pose=%s  max=%s  fills h=%.2f w=%.2f feet=%.2f", fmt(m.fitBox),
                        fmt(ReadBox(m.actor, "GetMaxBoundingBox")), fi and fi.h or 0, fi and fi.w or 0, fi and fi.feet or 0)
                elseif m and m.sp then
                    ns:Print("Azeromon %s: %s (old model frame, no ModelScene)", label, m.sp)
                end
            end
        elseif cmd == "zoom" then
            -- /cdl azeromon zoom <creature> <factor>: bigger = smaller on screen; "reset" clears
            local id
            for sid, s in pairs(D.species) do
                if sid == (a or ""):lower() or s.name:lower() == (a or ""):lower() then id = sid end
            end
            if not id then
                ns:Print("Azeromon: usage /cdl azeromon zoom <creature> <factor>  (e.g. zoom Lashling 1.3; 'reset' clears)")
                return
            end
            if type(d.zoom) ~= "table" then d.zoom = {} end
            local f = tonumber(b)
            if b == "reset" or not f then d.zoom[id] = nil else d.zoom[id] = math.max(0.2, math.min(5, f)) end
            ns:Print("Azeromon: %s size factor %s.", D.species[id].name, tostring(d.zoom[id] or 1))
        else
            ns.Games:Open(G.GAME_ID)
        end
    end, "azeromon [flip | zoom <creature> <factor> | models] - open Azeromon; flip turns battle models, zoom resizes one")
end

-- For tests
UI._HandleKey = function(k) HandleKey(k) end
UI._State = function() return { stack = #stack, battle = BT.battle ~= nil, msg = uiMessage ~= nil, text = text.full } end
UI._Levels = function()
    local out = {}
    for i, m in ipairs(stack) do
        local row = m.frame.rows and m.frame.rows[1]
        out[i] = { level = m.frame:GetFrameLevel(), row = row and row:GetFrameLevel() or 0,
                   title = m.frame.titleFs and m.frame.titleFs:GetText() or "" }
    end
    return out
end
UI._Summary = function() return R.summary ~= nil and R.summary:IsShown() and true or false end
-- Tests drive the engine themselves: stop the panel from playing battles / prompts.
UI._Detach = function()
    if root then root:SetScript("OnUpdate", nil) end
    ns.AzeroNet:SetActive(true)
end
-- Tests: after showing `sp` in the enemy slot, how much of the frame it fills and where its feet are.
UI._FitInfo = function()
    local sc = R.foeModel
    if not sc or not sc.isScene or not sc.fitInfo then return nil end
    return sc.fitInfo
end
UI._ShowFoe = function(sp) R.title:Hide() R.battle:Show() ShowCreature(R.foeModel, sp, -0.7) end
UI._Camera = function() return { dist = CAM_DIST, fov = CAM_FOV } end
