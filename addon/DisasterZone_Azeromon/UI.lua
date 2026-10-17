if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/UI.lua", ...) then return end -- DisasterZone_Azeromon/UI.lua
-- ns.AzeroUI: draws ns.Azero's state and forwards keyboard / mouse input.
-- Screen: 14 x 9 tiles of 48px (16px art at 3x, nearest filtering), camera centred on the player.
-- Keys (while the game has focus): arrows / WASD move, Space / Z / E = A, X / Q / Backspace = B (hold to run),
-- Enter / Tab / M = menu, Escape pauses (releases the keyboard; a second Escape closes the window).
local addonName, ns = ...

local UI = ns:NewModule("AzeroUI")
UI.screens = {}            -- [pending kind] = fn(pending): screens other UI files add (UI:RegisterScreen)
local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon
local A = ns.AzeroAtlas

local TILE, VW, VH = 48, 14, 9            -- 14 x 9 tiles: wide enough to fill the DisasterZone window
local HX, HY = 6.5, 4                     -- player's screen tile (half a tile in: centred on the even width)
local SW, SH = TILE * VW, TILE * VH
local MEDIA = "Interface\\AddOns\\DisasterZone_Azeromon\\Media\\"
local ATLAS, CHARS, PLATFORM = MEDIA .. "atlas", MEDIA .. "chars", MEDIA .. "platform"
-- Pixelify Sans (SIL OFL 1.1, static Medium / SemiBold cuts of the variable font). Falls back to the game font if
-- the file is missing (new files need a client restart). It runs ~25% larger than the old Pixel Operator at the same
-- size, so its sizes run about 0.9 of the old ones (Font: size x 1.25 instead of x 1.4).
local FONT = MEDIA .. "fonts\\PixelifySans-Medium.ttf"
local FONT_BOLD = MEDIA .. "fonts\\PixelifySans-SemiBold.ttf"
local FONT_FALLBACK = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local TEXT_SPEED = 55                     -- characters per second
local BOX_H = 112
local INK = { 0.165, 0.18, 0.21 }         -- text colour (dark slate, no drop shadow)
local INK_SHADOW = { 0.84, 0.84, 0.86 }

local floor, max, min = math.floor, math.max, math.min

local SPRITE_COL = { bald = 0, hero = 3, girl = 6, skel = 9 }
local FACE_ROW = { down = 0, left = 1, right = 2, up = 3 }

local root, screen, world, focusOverlay
local R = {}               -- widgets
local stack = {}           -- open menus (top = last)
local focused = false
local paused = false       -- Esc / combat / hidden window: the game stops, network timers keep going (OnUpdate)
local uiMessage = nil      -- the Message on screen (UI messages below), { after, base }
local BT = { busy = nil }  -- battle playback state (Battle below)
local now = 0
local KH = {}              -- help and reference: key hints, tips, the controls page, the type chart
local Scr = {}             -- the screens' helpers (summary pages, trade, stable, professions, ...)

---------------------------------------------------------------------------
-- Texture helpers
---------------------------------------------------------------------------

local function Tex(parent, layer, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    return t
end

-- Returns false when the client could not load the file (it then draws WoW's green "missing" square: callers that
-- multiply a picture over the world hide it instead). Files added to the addon need a client restart to be found.
local function SetPixelTexture(t, file)
    local ok, loaded = pcall(t.SetTexture, t, file, nil, nil, "NEAREST")
    if not ok then loaded = t:SetTexture(file) end
    if t.SetSnapToPixelGrid then pcall(t.SetSnapToPixelGrid, t, false) end
    if t.SetTexelSnappingBias then pcall(t.SetTexelSnappingBias, t, 0) end
    return loaded ~= false
end

local E = 0.02 / 256       -- tiny inset against bleeding between atlas cells
local function SetTile(t, name)
    name = name or false               -- false = empty; a fresh texture (nil) is always set once
    if t.tileName == name then return end
    t.tileName = name
    local i = name and A[name]
    if not i then t:Hide() return end
    local c, r = i % 16, floor(i / 16)
    local AH = ns.AzeroAtlasHeight or 256
    t:SetTexCoord(c * 16 / 256 + E, (c + 1) * 16 / 256 - E, r * 16 / AH + E, (r + 1) * 16 / AH - E)
    t:Show()
end

-- cut: show only the top `cut` rows (someone wading in the shallows: the legs are under the water, 0.46)
local function SetChar(t, sprite, face, frame, cut)
    local key = sprite .. face .. frame .. (cut or "")
    if t.charKey == key then return end
    t.charKey = key
    local c = (SPRITE_COL[sprite] or 3) + frame
    local r = FACE_ROW[face] or 0
    t:SetTexCoord(c * 16 / 256 + E, (c + 1) * 16 / 256 - E, r * 16 / 128 + E, (r * 16 + (cut or 16)) / 128 - E)
    t:SetHeight(TILE * (cut or 16) / 16)
end

-- size is the old design size; drawn at 1.25x in the pixel font.
local measureFs                  -- a hidden font string, to measure text (TextWidth)
local function Font(parent, size, layer, bold)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    local px = floor((size or 16) * 1.25 + 0.5)
    if not fs:SetFont(bold and FONT_BOLD or FONT, px, "") then fs:SetFont(FONT_FALLBACK, size or 16, "") end
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetTextColor(INK[1], INK[2], INK[3])
    fs:SetShadowColor(INK_SHADOW[1], INK_SHADOW[2], INK_SHADOW[3], 0)
    fs:SetShadowOffset(0, 0)
    return fs
end

-- How wide `str` is in the game font at `size` (Font sizes).
local function TextWidth(str, size)
    if not measureFs and UIParent then
        measureFs = UIParent:CreateFontString(nil, "OVERLAY")
        measureFs:Hide()
    end
    if measureFs then
        local px = floor((size or 16) * 1.25 + 0.5)
        if not measureFs:SetFont(FONT, px, "") then measureFs:SetFont(FONT_FALLBACK, size or 16, "") end
        measureFs:SetText(str)
        local ok, w = pcall(measureFs.GetStringWidth, measureFs)
        if ok and w and w > 0 then return w end
    end
    return #str * (size or 16) * 0.75
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

-- The window: a near-black edge, a slate-blue frame, a pale blue inner ring, a warm cream inside.
local function Box(parent, w, h, level)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    if level then f:SetFrameLevel(level) end
    Rounded(f, 0, 4, 0.04, 0.05, 0.07, 0)
    Rounded(f, 2, 3, 0.24, 0.35, 0.53, 1)
    Rounded(f, 5, 2, 0.66, 0.77, 0.90, 2)
    Rounded(f, 7, 1, 0.97, 0.96, 0.93, 3)
    f:EnableMouse(true)
    f:SetScript("OnMouseDown", function(_, button)          -- a right-click anywhere on a window: back
        if button == "RightButton" and UI.Press then UI.Press("B") end
    end)
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
    if not f.fs:SetFont(FONT_BOLD, floor((size or 15) * 0.82 + 0.5), "") then f.fs:SetFont(FONT_FALLBACK, 10, "") end
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
-- Time of day: the sky tint over outdoor maps (and battles there). Keyframes by realm hour; colour + alpha
-- are interpolated between them: warm dawn, clear day, amber dusk, deep blue night.
---------------------------------------------------------------------------

local SKY = {
    { h = 0,  c = { 0.05, 0.07, 0.24 }, a = 0.46 },
    { h = 4.5, c = { 0.05, 0.07, 0.24 }, a = 0.46 },
    { h = 6,  c = { 0.95, 0.55, 0.45 }, a = 0.18 },
    { h = 7.5, c = { 1, 1, 1 }, a = 0 },
    { h = 17.5, c = { 1, 1, 1 }, a = 0 },
    { h = 19.5, c = { 0.95, 0.45, 0.18 }, a = 0.22 },
    { h = 21, c = { 0.05, 0.07, 0.24 }, a = 0.46 },
    { h = 24, c = { 0.05, 0.07, 0.24 }, a = 0.46 },
}

local function SkyTint(hour)
    for i = 1, #SKY - 1 do
        local k0, k1 = SKY[i], SKY[i + 1]
        if hour >= k0.h and hour <= k1.h then
            local f = (hour - k0.h) / math.max(0.001, k1.h - k0.h)
            local c = {}
            for j = 1, 3 do c[j] = k0.c[j] + (k1.c[j] - k0.c[j]) * f end
            return c[1], c[2], c[3], k0.a + (k1.a - k0.a) * f
        end
    end
    return 1, 1, 1, 0
end

-- gloom: a map that is never brighter than this (Duskwood's endless dusk), in a cold violet
local GLOOM = { 0.10, 0.08, 0.22 }
local function ApplySky(tex, outdoor, strength, gloom)
    if not outdoor then tex:Hide() return 0 end
    local r, g, b, a = SkyTint(G:Hour() % 24)
    if gloom and a < gloom then r, g, b, a = GLOOM[1], GLOOM[2], GLOOM[3], gloom end
    a = a * (strength or 1)
    tex:SetColorTexture(r, g, b, a)
    tex:SetShown(a > 0.005)
    return a
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

-- The scenes' light: plain, or the warm glow of a shiny with no skin of its own.
local function SceneLight(sc, glow)
    if sc.glow == glow then return end
    sc.glow = glow
    if glow then
        local c = D.SHINY_GLOW
        pcall(sc.SetLightAmbientColor, sc, c[1] * 0.85, c[2] * 0.85, c[3] * 0.85)
        pcall(sc.SetLightDiffuseColor, sc, c[1], c[2], c[3])
    else
        pcall(sc.SetLightAmbientColor, sc, 0.72, 0.72, 0.72)
        pcall(sc.SetLightDiffuseColor, sc, 0.85, 0.85, 0.82)
    end
end

local function NewScene(parent, w, h)
    local ok, sc = pcall(CreateFrame, "ModelScene", nil, parent)
    if not ok or not sc or not sc.CreateActor then return nil end
    sc:SetSize(w, h)
    -- Blizzard's actor template gives a reliable "model loaded" callback; a bare actor is the fallback.
    local actorOk, actor = pcall(sc.CreateActor, sc, nil, "ModelSceneActorTemplate")
    if not actorOk or not actor then actorOk, actor = pcall(sc.CreateActor, sc) end
    if not actorOk or not actor or not actor.SetModelByCreatureDisplayID or not actor.GetActiveBoundingBox then
        sc:Hide()
        return nil
    end
    -- the model's own origin (its feet), never the box centre; the rendered bounds, not collision bounds
    pcall(actor.SetUseCenterForOrigin, actor, false, false, false)
    pcall(actor.SetPreferModelCollisionBounds, actor, false)
    sc.loads = 0
    if actor.SetOnModelLoadedCallback then
        sc.hasLoadEvent = pcall(actor.SetOnModelLoadedCallback, actor, function()
            sc.loads = sc.loads + 1
            pcall(actor.SetAnimation, actor, 0)
            if not sc.fit and sc.fitInfo and sc.fitInfo.gaveUp then     -- it loaded after all: fit it now
                pcall(actor.SetAlpha, actor, 0)
                sc.fit = { tweak = sc.tweak or 1, since = GetTime(), age = 0, loads = sc.loads - 1,
                           display = sc.lastDisplay }
            end
        end)
    end
    -- camera on the +x axis looking back at the origin; the actor faces +x (toward us) at yaw 0
    pcall(sc.SetCameraPosition, sc, CAM_DIST, 0, 0)
    pcall(sc.SetCameraOrientationByYawPitchRoll, sc, math.pi, 0, 0)
    pcall(sc.SetCameraFieldOfView, sc, CAM_FOV)
    pcall(sc.SetCameraNearClip, sc, 1)
    pcall(sc.SetCameraFarClip, sc, 400)
    pcall(sc.SetLightVisible, sc, true)
    pcall(sc.SetLightDirection, sc, -0.6, 0.4, -0.7)
    SceneLight(sc, false)
    sc.actor = actor
    sc.isScene = true
    sc.camY, sc.camZ = 0, 0
    sc.SetAnimation = function(self, id) pcall(self.actor.SetAnimation, self.actor, id) end
    scenes[#scenes + 1] = sc
    return sc
end

local function ReadBox(a, method)
    local fn = a[method]
    if not fn then return nil end
    local ok, x0, y0, z0, x1, y1, z1 = pcall(fn, a)
    if ok and type(x0) == "table" and type(y0) == "table" and x0.GetXYZ then   -- documented form: two vectors
        local bx, by, bz = x0:GetXYZ()
        local tx, ty, tz = y0:GetXYZ()
        x0, y0, z0, x1, y1, z1 = bx, by, bz, tx, ty, tz
    end
    if not ok or type(z1) ~= "number" or type(z0) ~= "number" or type(x1) ~= "number" or type(y1) ~= "number"
        or (z1 - z0) <= 0 then
        return nil
    end
    return { x0, y0, z0, x1, y1, z1 }
end

-- The box of the pose on screen right now (GetActiveBoundingBox); the all-animations box as a fallback.
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

-- The 8 box corners in scene space at scale s, turned by yaw (counter-clockwise seen from above, +x toward +y).
local function Corners(box, s, yaw)
    local out = {}
    local sn, cs = math.sin(yaw), math.cos(yaw)
    for _, x in ipairs({ box[1], box[4] }) do
        for _, y in ipairs({ box[2], box[5] }) do
            for _, z in ipairs({ box[3], box[6] }) do
                out[#out + 1] = { (x * cs - y * sn) * s, (x * sn + y * cs) * s, z * s }
            end
        end
    end
    return out
end

-- Where the engine draws a scene-space point, in UI units from the frame's bottom-left (nil if unavailable).
local function Project(sc, x, y, z)
    if not sc.Project3DPointTo2D then return nil end
    local ok, px, py = pcall(sc.Project3DPointTo2D, sc, x, y, z)
    if not ok or type(px) ~= "number" or type(py) ~= "number" then return nil end
    local es = 1
    if sc.GetEffectiveScale then
        local ok2, v = pcall(sc.GetEffectiveScale, sc)
        if ok2 and type(v) == "number" and v > 0 then es = v end
    end
    return px / es, py / es
end

-- The turn the box must be given so it matches what is drawn. Creatures are turned so they face each other on
-- screen (the player's toward screen-right at +0.8; /dz azeromon flip fixes it if the engine turns the other
-- way), so the ON-SCREEN turn is the requested one. Which scene axis runs toward screen-right is read from the
-- engine's projection once per scene.
local function ScreenYaw(sc)
    if not sc.rightSign then
        local cx = Project(sc, 0, sc.camY or 0, sc.camZ or 0)
        local ux = Project(sc, 0, (sc.camY or 0) + 1, sc.camZ or 0)
        if cx and ux and ux ~= cx then sc.rightSign = (ux > cx) and 1 or -1 end
    end
    return (sc.viewYaw or 0) * (sc.rightSign or 1)
end

-- Screen rectangle covered by the fitted box (UI units), or nil when the client cannot project.
local function ProjectedRect(sc, box, s, yaw)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(Corners(box, s, yaw)) do
        local px, py = Project(sc, p[1], p[2], p[3])
        if not px then return nil end
        if px < x0 then x0 = px end
        if px > x1 then x1 = px end
        if py < y0 then y0 = py end
        if py > y1 then y1 = py end
    end
    return x0, y0, x1, y1
end

-- Checks the fit with the engine's own projection and corrects size and camera: the creature fills exactly
-- FILL_H of the height or FILL_W of the width (whichever limits), its ground sits 3% above the bottom edge,
-- and it is centred sideways. This makes the result independent of the field-of-view convention and
-- perspective. Returns the final rectangle, or nil when projection is unavailable.
local function RefineWithProjection(sc, box, s, tweak, yaw)
    local a = sc.actor
    local W, H = sc:GetWidth(), sc:GetHeight()
    for _ = 1, 4 do
        local rx0, ry0, rx1, ry1 = ProjectedRect(sc, box, s, yaw)
        if not rx0 or ry1 - ry0 <= 0 or rx1 - rx0 <= 0 then return nil end
        -- size
        local k = math.min(FILL_H * H / (ry1 - ry0), FILL_W * W / (rx1 - rx0)) / tweak
        if math.abs(k - 1) > 0.005 then
            s = s * k
            pcall(a.SetScale, a, s)
            rx0, ry0, rx1, ry1 = ProjectedRect(sc, box, s, yaw)
            if not rx0 then return nil end
        end
        -- placement: how many UI units one scene unit moves on screen, measured at the creature's plane
        local cx, cy = Project(sc, 0, sc.camY, sc.camZ)
        local ux = Project(sc, 0, sc.camY + 1, sc.camZ)
        local _, uz = Project(sc, 0, sc.camY, sc.camZ + 1)
        if not cx or not ux or not uz or math.abs(ux - cx) < 1e-6 or math.abs(uz - cy) < 1e-6 then return nil end
        local ppuY, ppuZ = ux - cx, uz - cy
        local dy = 0.03 * H - ry0                  -- ground 3% above the bottom edge
        local dx = W / 2 - (rx0 + rx1) / 2         -- centre sideways
        if math.abs(dy) < 0.25 and math.abs(dx) < 0.25 and math.abs(k - 1) <= 0.005 then break end
        sc.camZ = sc.camZ - dy / ppuZ
        sc.camY = sc.camY - dx / ppuY
        pcall(sc.SetCameraPosition, sc, CAM_DIST, sc.camY, sc.camZ)
    end
    sc.fitted = s
    return ProjectedRect(sc, box, s, yaw)
end

-- Shown without a fit (nothing measurable): unscaled, its origin (ground) on the platform line.
local function GiveUp(sc)
    local a = sc.actor
    pcall(a.SetScale, a, 1)
    sc.camY, sc.camZ = 0, VIS_H / 2 - VIS_H * 0.03
    pcall(sc.SetCameraPosition, sc, CAM_DIST, sc.camY, sc.camZ)
    pcall(a.SetAlpha, a, 1)
    sc.fit, sc.fitted, sc.fitBox = nil, nil, nil
    sc.fitInfo = { gaveUp = true }
end

-- Fits a creature (called every frame while a fit is pending and its frame is visible; fit.age counts only
-- that visible time):
--  1. wait until the NEW model has loaded: the template's load event, or else a model file different from the
--     one before (the engine keeps reporting the previous creature's box while the next one loads); after 4 s
--     whatever is loaded is trusted; after 10 s with nothing to measure it is shown unfitted (and refitted if
--     its load event still comes);
--  2. sample the idle pose for SAMPLE_TIME (hovering fliers bob), kept inside the all-animations box, with the
--     model's own ground (origin) always included: every creature stands (or hovers above) the platform line,
--     and a flier's death animation lands on it instead of falling through the bottom edge;
--  3. first fit from the numbers (telephoto camera: nearly flat), with the camera moved, never the actor
--     (actor positions are multiplied by the actor's scale);
--  4. check and correct it with the engine's own projection.
local function FitScene(sc)
    local fit = sc.fit
    if not fit then return end
    local a = sc.actor
    local age = fit.age or 0
    if not fit.ready then
        local loaded, file = true, nil
        if a.IsLoaded then
            local ok, v = pcall(a.IsLoaded, a)
            loaded = not ok or v
        end
        if a.GetModelFileID then
            local ok, v = pcall(a.GetModelFileID, a)
            if ok then file = v end
        end
        -- fresh: the template's load event fired for this model, or (no event, or none within a second) the
        -- model file changed from the previous creature's (the same file after 0.6 s: two species, one model)
        local fresh = sc.hasLoadEvent and sc.loads ~= fit.loads
        if not fresh and (not sc.hasLoadEvent or age > 1.0) then
            fresh = file ~= nil and file ~= 0 and (file ~= fit.prevFile or age > 0.6)
        end
        local box = loaded and MeasureBox(a)
        -- a fresh load (event or a new model file) means the box is this creature's; two species sharing one
        -- model file legitimately share a box. With no signal at all, whatever is loaded is trusted after 4 s.
        local usable = box and (fresh or age > 4)
        if not usable then
            fit.timedOut = age > 4
            if age > 10 then GiveUp(sc) end
            return
        end
        fit.ready = true
    end
    local cur = MeasureBox(a)
    if cur then fit.box = Union(fit.box, cur) end
    fit.sampleStart = fit.sampleStart or age
    if age - fit.sampleStart < SAMPLE_TIME or not fit.box then return end
    local pose = Clamp(fit.box, ReadBox(a, "GetMaxBoundingBox"))
    local b = { pose[1], pose[2], math.min(pose[3], 0), pose[4], pose[5], pose[6] }

    -- first fit from the numbers
    local yaw = ScreenYaw(sc)
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(Corners(b, 1, yaw)) do
        if p[2] < lo then lo = p[2] end
        if p[2] > hi then hi = p[2] end
    end
    local height, width = b[6] - b[3], math.max(hi - lo, 0.01)
    local W, H = sc:GetWidth(), math.max(1, sc:GetHeight())
    local visW = VIS_H * W / H
    local s = math.min(FILL_H * VIS_H / height, FILL_W * visW / width) / fit.tweak
    pcall(a.SetScale, a, s)
    sc.camZ = b[3] * s + VIS_H / 2 - VIS_H * 0.03
    sc.camY = (lo + hi) / 2 * s
    pcall(sc.SetCameraPosition, sc, CAM_DIST, sc.camY, sc.camZ)
    sc.fitted = s

    -- then the engine's word on where it actually lands
    local rx0, ry0, rx1, ry1 = RefineWithProjection(sc, b, s, fit.tweak, yaw)
    if rx0 then
        sc.fitInfo = { h = (ry1 - ry0) / H, w = (rx1 - rx0) / W, feet = ry0 / H, center = (rx0 + rx1) / 2 / W,
                       x0 = b[1], x1 = b[4], z0 = pose[3], z1 = pose[6], ground = b[3], projected = true }
    else
        local sf = sc.fitted
        sc.fitInfo = { h = height * sf / VIS_H, w = width * sf / visW, x0 = b[1], x1 = b[4],
                       feet = (b[3] * sf - (sc.camZ - VIS_H / 2)) / VIS_H, center = 0.5,
                       z0 = pose[3], z1 = pose[6], ground = b[3] }
    end
    pcall(a.SetAlpha, a, 1)
    sc.fit = nil
    sc.fitBox = b
    sc.lastDisplay = fit.display
end

local function FitScenes(elapsed)
    for _, sc in ipairs(scenes) do
        local fit = sc.fit
        if fit and sc:IsVisible() then
            fit.age = (fit.age or 0) + (elapsed or 0)
            FitScene(sc)
        end
    end
end

function Scr.NewModel3D(parent, w, h)
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
-- (/dz azeromon zoom <species> <n>). Bigger = further away = smaller on screen.
local function CamFor(m, s)
    local over = G:Data().zoom
    local tweak = type(over) == "table" and tonumber(over[s.id]) or 1
    return (m.camScale or 1.2) * (s.cam or 1) * tweak
end

-- shiny: the species' other skin (D.shinyDisplay), or its own skin in a golden light when it has none.
function Scr.ShowModel3D(m, sp, facing, shiny)
    local s = sp and ((type(sp) == "table") and sp or D.species[sp])      -- (a table: any creature by display id)
    if not s then m:Hide() m.sp = nil return end
    m:Show()
    m.facing = facing and facing * FacingSign() or 0
    m.viewYaw = facing or 0                        -- the turn as seen on screen (see ScreenYaw)
    shiny = shiny and true or false
    local display = (shiny and D.shinyDisplay[sp]) or s.display
    if m.isScene then
        local over = G:Data().zoom
        local tweak = type(over) == "table" and tonumber(over[s.id]) or 1
        local a = m.actor
        pcall(a.SetYaw, a, m.facing)
        SceneLight(m, shiny and not D.shinyDisplay[sp])
        if m.sp ~= sp or m.tweak ~= tweak or m.display ~= display then
            m.sp, m.tweak, m.display = sp, tweak, display
            local prevFile
            if a.GetModelFileID then
                local ok, v = pcall(a.GetModelFileID, a)
                if ok then prevFile = v end
            end
            pcall(a.SetAlpha, a, 0)                -- hidden until measured, so it never pops in at the wrong size
            pcall(a.ClearModel, a)                 -- drop the previous creature first (its box lingers otherwise)
            pcall(a.SetScale, a, 1)
            pcall(a.SetPosition, a, 0, 0, 0)
            m.camY, m.camZ = 0, 0
            pcall(m.SetCameraPosition, m, CAM_DIST, 0, 0)
            m.fitted, m.fitInfo, m.fitBox = nil, nil, nil
            m.fit = { tweak = tweak, since = GetTime(), age = 0, loads = m.loads, prevFile = prevFile,
                      display = display }
            pcall(a.SetModelByCreatureDisplayID, a, display)
            pcall(a.SetAnimation, a, 0)            -- idle: never inherit the last creature's death / attack pose
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

---------------------------------------------------------------------------
-- Beast frames: a pixel sprite (Sprites.lua, the beast's own model rendered + pixelized in the dev kit) or, for a
-- creature without art (a raid boss trophy, an art set older than the index), the 3D model above. Callers place,
-- fade, show and hide the frame; its feet are its bottom centre.
---------------------------------------------------------------------------

local function NewModel(parent, w, h)
    local m = CreateFrame("Frame", nil, parent)
    m:SetSize(w, h)
    m.w, m.h = w, h
    m.isContainer = true
    m.spr = ns.AzeroSprites.New(m)
    m:SetScript("OnUpdate", function(self, dt) if self.spr.key then self.spr:Update(dt) end end)
    return m
end

-- the 3D model inside a beast frame, made the first time a creature without art is shown in it
function Scr.Scene3D(m)
    if not m.scene then
        m.scene = Scr.NewModel3D(m, m.w, m.h)
        m.scene:SetPoint("BOTTOMLEFT", m, "BOTTOMLEFT", 0, 0)
    end
    m.scene.camScale = m.camScale
    return m.scene
end

-- The beast frame's "is the 3D model still being measured" (a creature switched in waits for it, at most 3 s).
function Scr.Measuring(m)
    local sc = m.isContainer and m.scene or (not m.isContainer and m) or nil
    return sc ~= nil and sc:IsShown() and sc.fit ~= nil and not sc.fit.timedOut
end

local function ShowCreature(m, sp, facing, shiny)
    if not m.isContainer then return Scr.ShowModel3D(m, sp, facing, shiny) end
    local s = sp and ((type(sp) == "table") and sp or D.species[sp])
    if not s then
        m:Hide() m.sp = nil
        m.spr:Hide()
        if m.scene then m.scene:Hide() m.scene.sp = nil end
        return
    end
    m:Show()
    local key, glow
    local Spr = ns.AzeroSprites
    if not G:Data().models3d then key, glow = Spr.Key(sp, shiny) end
    if key then
        if m.scene then m.scene:Hide() end
        m.sp, m.display, m.glow = sp, (shiny and D.shinyDisplay[sp]) or s.display, glow or false
        local view = m.view or "f"
        m.spr:Set(key, view, m.pixelScale or Spr.FitScale(key, view, m.w, m.h), m.spriteLift or floor(m.h * 0.03), glow)
        return
    end
    m.spr:Hide()
    local sc = Scr.Scene3D(m)
    sc:Show()
    Scr.ShowModel3D(sc, sp, facing, shiny)
    m.sp, m.display, m.glow = sp, sc.display, sc.glow or false
end

local function Anim(m, id)
    if not m then return end
    if m.isContainer then
        if m.spr.key then m.spr:Anim(id) return end
        m = m.scene
    end
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

-- Takes a Message off the screen without running its `after` (another text took the box over): the game never
-- waits on a message nobody can see. Puts the box back to its own level (Message lifts it over menus).
local function DropMessage()
    local m = uiMessage
    if not m then return end
    uiMessage = nil
    R.textbox:SetFrameLevel(m.base)
    R.textArrow:SetFrameLevel(m.base + 2)
    R.nameTab:SetFrameLevel(m.base - 1)
end

-- "Name: words" shows Name on a tab above the box (dialogue), like the later games.
local function SetText(str, opts)
    DropMessage()
    -- a battle line waiting to be read loses its onDone here: stop waiting for it
    if BT.anim and BT.anim.waitText then BT.anim = nil end
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
        ns.AzeroSound:Play("text")
        ShowPage(text.page + 1)
        return true
    end
    local cb = text.onDone
    text.onDone = nil
    if cb then ns.AzeroSound:Play("text") cb() return true end
    return false
end

local function ClearText()
    DropMessage()
    if BT.anim and BT.anim.waitText then BT.anim = nil end
    text.full, text.onDone, text.auto, text.pages = nil, nil, nil, nil
    if R.textbox then R.textbox:Hide() R.nameTab:Hide() end
end

---------------------------------------------------------------------------
-- List menus (choices, start menu, party, bag, shop, moves)
-- item = { text, right, bar, disabled, onSelect }
-- opts = { x, y, w, rowH, cols, onCancel, anchor, title, level, noBox, onMove }
---------------------------------------------------------------------------

local MenuMoveBy          -- (defined with the menu keys below)

local menuPool = {}
local DESC_H = 86          -- the description box at the bottom (R.bagDesc, 80 high) plus a small gap

-- A small solid triangle pointing up (the scroll markers; Triangle only does right / down).
local function UpTriangle(parent, size, r, g, b)
    local f = CreateFrame("Frame", nil, parent)
    local steps, s = 4, size
    local strip = s / (steps * 2)
    f:SetSize(s, steps * strip * 2)
    for i = 0, steps - 1 do
        local t = Tex(f, "OVERLAY", 2)
        t:SetColorTexture(r, g, b, 1)
        t:SetSize(s - i * (s / steps), strip * 2)
        t:SetPoint("BOTTOM", 0, i * strip * 2)
    end
    return f
end

local function NewRow(f)
    local row = CreateFrame("Button", nil, f)
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
    row.icon:SetPoint("LEFT", 22, 0)
    -- a Message up (over this menu or beside it) has to be answered first, by mouse as by keys
    row:SetScript("OnEnter", function(self)
        if uiMessage then return end
        local menu = self:GetParent().menu
        if menu and stack[#stack] == menu and self.idx then menu.cursor = self.idx UI:RefreshMenu(menu) end
    end)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if UI.Press then UI.Press("B") end
            return
        end
        if uiMessage then return end
        local menu = self:GetParent().menu
        if menu and stack[#stack] == menu and self.idx then menu.cursor = self.idx UI:MenuSelect(menu) end
    end)
    return row
end

-- Fills the visible rows from menu.first (a scrolling window over the items).
local function DrawRows(menu)
    local f, items, cols, rowH = menu.frame, menu.items, menu.cols, menu.rowH
    local scrolls = menu.perPage < #items
    local gutter = scrolls and 14 or 0                  -- room on the right for the scroll markers
    local colW = (f:GetWidth() - 24 - gutter) / cols
    local top = menu.opts.title and 42 or 12
    for slot = 1, menu.perPage do
        local idx = menu.first + slot - 1
        local it = items[idx]
        local row = f.rows[slot]
        if not row then
            row = NewRow(f)
            f.rows[slot] = row
        end
        if it then
            row.idx = idx
            row:SetSize(colW, rowH)
            row:ClearAllPoints()
            local c, r = (slot - 1) % cols, floor((slot - 1) / cols)
            row:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + c * colW, -top - r * rowH)
            local size = it.size or 16                      -- (the move list steps a long name down a size)
            if row.fsSize ~= size then
                if not row.fs:SetFont(FONT, floor(size * 1.25 + 0.5), "") then row.fs:SetFont(FONT_FALLBACK, size, "") end
                row.fsSize = size
            end
            row.fs:SetText(it.text or "")
            row.fs:ClearAllPoints()
            local left = it.icon and (26 + rowH) or 24
            row.fs:SetPoint("LEFT", left, it.bar and 5 or 0)
            -- long names stop short of the right-hand column (cut with "...") instead of running under it;
            -- rightW: room kept for something drawn there instead of text (a resting move's hourglass and pips)
            local rightW = it.rightW or ((it.right and it.right ~= "") and (TextWidth(it.right, 13) + 12) or 0)
            row.fs:SetWidth(max(24, colW - left - 6 - rightW))
            row.fs:SetWordWrap(false)
            if it.disabled then row.fs:SetTextColor(0.66, 0.66, 0.68) else row.fs:SetTextColor(INK[1], INK[2], INK[3]) end
            local rc = it.rightColor or { 0.36, 0.42, 0.55 }
            row.right:SetTextColor(rc[1], rc[2], rc[3])
            row.right:SetText(it.right or "")
            row.right:ClearAllPoints()
            row.right:SetPoint("RIGHT", -6, it.bar and 5 or 0)
            row.icon:SetSize(rowH - 6, rowH - 6)       -- (pooled rows keep an old size otherwise)
            if it.icon then row.icon:SetTexture(it.icon) row.icon:Show() else row.icon:Hide() end
            row.bar:SetShown(it.bar ~= nil)
            if it.bar then row.bar:SetHP(it.bar) end
            row.cursor:SetShown(idx == menu.cursor)
            row:Show()
        else
            row.idx = nil
            row:Hide()
        end
    end
    for slot = menu.perPage + 1, #f.rows do
        f.rows[slot].idx = nil
        f.rows[slot]:Hide()
    end
    -- the markers sit in the gutter beside the first and last visible line
    local lines = menu.perPage / cols
    f.upMark:ClearAllPoints()
    f.upMark:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -top - (rowH - 10) / 2)
    f.downMark:ClearAllPoints()
    f.downMark:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -top - (lines - 1) * rowH - (rowH - 10) / 2)
    f.upMark:SetShown(scrolls and menu.first > 1)
    f.downMark:SetShown(scrolls and menu.first + menu.perPage - 1 < #items)
end

-- Keeps the cursor inside the visible window (whole lines of `cols` items).
local function ScrollToCursor(menu)
    local cols = menu.cols
    local line = floor((menu.cursor - 1) / cols)
    local firstLine = floor((menu.first - 1) / cols)
    local lines = menu.perPage / cols
    if line < firstLine then firstLine = line end
    if line >= firstLine + lines then firstLine = line - lines + 1 end
    menu.first = firstLine * cols + 1
end

-- opts = { x, y, w, rowH, cols, h, onCancel, anchor, title, level, onMove, cursor,
--          desc = true when the description box (R.bagDesc) shows under this menu, or the height of what does }
-- Menus longer than the space down to the screen bottom (or the description box) scroll with the cursor.
local function PushMenu(items, opts)
    opts = opts or {}
    local cols = opts.cols or 1
    local rowH = opts.rowH or 32
    local w = opts.w or 160
    local titleH = opts.title and 30 or 0
    local rows = math.ceil(#items / cols)
    local perLines = rows
    if not opts.anchor and not opts.h then
        local topY = -(opts.y or -6)                           -- distance from the screen top
        local descH = opts.desc == true and DESC_H or tonumber(opts.desc) or 0
        local room = SH - topY - 8 - descH
        perLines = max(1, min(rows, floor((room - 24 - titleH) / rowH)))
    end
    local h = opts.h or (perLines * rowH + 24 + titleH)
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
    if not f.upMark then
        f.upMark = UpTriangle(f, 10, 0.36, 0.42, 0.55)
        f.downMark = Triangle(f, "down", 10, 0.36, 0.42, 0.55)
        f:EnableMouseWheel(true)
        f:SetScript("OnMouseWheel", function(self, delta)
            local menu = self.menu
            if menu and stack[#stack] == menu and not uiMessage then MenuMoveBy(menu, delta > 0 and "up" or "down") end
        end)
    end
    -- co: the script running when it opened (nil: the player's own menu); see SyncPending
    local menu = { frame = f, items = items, cursor = opts.cursor or 1, cols = cols, opts = opts,
                   rowH = rowH, perPage = perLines * cols, first = 1, co = G.co }
    f.menu = menu
    ScrollToCursor(menu)
    DrawRows(menu)
    -- pooled frames keep their children's old levels: lift the rows (and cursors, markers) with the frame
    for _, row in ipairs(f.rows) do
        row:SetFrameLevel(level + 1)
        row.cursor:SetFrameLevel(level + 2)
    end
    f.upMark:SetFrameLevel(level + 2)
    f.downMark:SetFrameLevel(level + 2)
    f:Show()
    stack[#stack + 1] = menu
    UI:RefreshMenu(menu)
    return menu
end

function UI:RefreshMenu(menu)
    if menu.perPage then
        ScrollToCursor(menu)
        DrawRows(menu)
    end
    if menu.opts.onMove then menu.opts.onMove(menu.cursor, menu) end
end

local function PopMenu(menu)
    menu = menu or stack[#stack]
    for i = #stack, 1, -1 do
        if stack[i] == menu then
            table.remove(stack, i)
            if menu.opts and menu.opts.onPop then menu.opts.onPop(menu) end      -- (what the menu laid over itself)
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
    if it and not it.disabled then ns.AzeroSound:Play("select") end
    if it and not it.disabled and it.onSelect then it.onSelect(menu.cursor, menu) end
end

local function MenuMove(menu, dir)
    local n, cols = #menu.items, menu.cols
    local c = menu.cursor
    if dir == "up" then c = c - cols elseif dir == "down" then c = c + cols
    elseif dir == "left" and cols > 1 then c = c - 1 elseif dir == "right" and cols > 1 then c = c + 1 end
    if c >= 1 and c <= n and c ~= menu.cursor then
        menu.cursor = c
        ns.AzeroSound:Play("cursor")
    end
    UI:RefreshMenu(menu)
end

MenuMoveBy = function(menu, dir) MenuMove(menu, dir) end

local function MenuKey(menu, key)
    if key == "A" then UI:MenuSelect(menu)
    elseif key == "B" then
        if menu.opts.onCancel then
            ns.AzeroSound:Play("back")
            menu.opts.onCancel(menu)
        end
    elseif key == "up" or key == "down" or key == "left" or key == "right" then MenuMove(menu, key) end
end

---------------------------------------------------------------------------
-- UI messages (not from the engine): text + A to continue
---------------------------------------------------------------------------

-- (uiMessage is declared at the top: the text box and the menu rows check it)
-- A message in the text box, answered with Space / X. When a menu covers the text box (the move list sits in its
-- place, a bag or a summary on top), the box comes up over it for the message and goes back down afterwards.
-- While it is up nothing else takes the box: engine prompts wait (SyncPending), menus ignore keys and clicks, and
-- a second message waits for this one. Any other text that still replaces it drops it (DropMessage).
local function Message(str, after)
    if uiMessage then
        local first = uiMessage.after
        uiMessage.after = function()
            if first then first() end
            Message(str, after)
        end
        return
    end
    local tb = R.textbox
    local base = tb:GetFrameLevel()
    local top = stack[#stack]
    local over = top and top.frame and top.frame:IsShown() and top.frame:GetFrameLevel() + 10
    local msg = { after = after, base = base }
    SetText(str, { onDone = function()
        ClearText()                    -- (drops uiMessage and puts the box back down)
        if msg.after then msg.after() end
    end })
    if over and over > base then
        tb:SetFrameLevel(over)
        R.textArrow:SetFrameLevel(over + 2)
        R.nameTab:SetFrameLevel(over - 1)
    end
    uiMessage = msg
end

---------------------------------------------------------------------------
-- Screens: summary, log
---------------------------------------------------------------------------

-- The summary: an INFO page (stats, moves) and a GEAR page (the five gear slots and the flask around the beast).
-- Left / right switch pages; on the gear page up / down pick a slot and Space changes what's in it.
Scr.GEAR_ORDER = { "claws", "shoulders", "chest", "wrists", "waist", "flask" }
Scr.STAT_SHORT = { hp = "HP", atk = "Atk", def = "Def", spa = "SpA", spd = "SpD", spe = "Spe" }

function Scr.SlotName(slot)
    if slot == "flask" then return "Flask" end
    for _, g in ipairs(D.gearSlots or {}) do if g.id == slot then return g.name end end
    return slot
end

function Scr.EmptySlotTexture(slot)
    local inv, fallback = "Trinket0Slot", "Trinket"
    for _, g in ipairs(D.gearSlots or {}) do if g.id == slot then inv, fallback = g.inv, g.fallback end end
    if GetInventorySlotInfo then
        local ok, _, tex = pcall(GetInventorySlotInfo, inv)
        if ok and tex then return tex end
    end
    return "Interface\\PaperDoll\\UI-PaperDoll-Slot-" .. fallback
end

function Scr.BonusText(get)
    local parts = {}
    for _, st in ipairs(M.STATS) do
        local m = get(st)
        if m and m ~= 1 then parts[#parts + 1] = string.format("+%d%% %s", floor((m - 1) * 100 + 0.5), Scr.STAT_SHORT[st]) end
    end
    return table.concat(parts, ", ")
end

function Scr.PartyIndex(mon)
    for i, m in ipairs(G.save.party) do if m == mon then return i end end
end

function Scr.SlotItem(mon, slot)
    if slot == "flask" then return mon.flask and mon.flask.id end
    return type(mon.gear) == "table" and mon.gear[slot] or nil
end

function Scr.SummaryInfoText(mon)
    local s = D.species[mon.sp]
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
    return table.concat(lines, "\n")
end

function Scr.SlotDetail(mon, slot)
    local id = Scr.SlotItem(mon, slot)
    local def = id and D.items[id]
    if slot == "flask" then
        if not def then return "Flask: none. Space: give it a flask (Alchemy)." end
        return string.format("Flask: %s (%s), %d %s left.", def.name, Scr.BonusText(function(st) return def.bonus[st] end),
            mon.flask.n, mon.flask.n == 1 and "battle" or "battles")
    end
    if not def then return Scr.SlotName(slot) .. ": empty. Space: put gear on (Blacksmithing)." end
    return string.format("%s: %s (%s).", Scr.SlotName(slot), def.name, Scr.BonusText(function(st) return def.bonus[st] end))
end

Scr.RenderSummary = function(sm)
    local f, mon = R.summary, sm.mon
    f.title:SetText(string.format("%s   Lv%d", M.Name(mon), mon.lvl))
    local gear = sm.page == "gear"
    f.tabs:SetText(gear and "|cffa8a8b0INFO|r   |cff335c9eGEAR|r" or "|cff335c9eINFO|r   |cffa8a8b0GEAR|r")
    f.body:SetShown(not gear)
    f.gear:SetShown(gear)
    f.model:ClearAllPoints()
    if gear then
        f.model:SetPoint("TOP", f, "TOP", 0, -52)
        f.hint:SetText("Left/Right: info   Space: change   X: close")
        for i, cell in ipairs(f.cells) do
            local id = Scr.SlotItem(mon, Scr.GEAR_ORDER[i])
            local def = id and D.items[id]
            cell.icon:SetShown(def ~= nil)
            if def then cell.icon:SetTexture(def.icon) end
            cell.empty:SetShown(def == nil)
            cell:Select(i == sm.cursor)
        end
        f.detail:SetText(sm.note or Scr.SlotDetail(mon, Scr.GEAR_ORDER[sm.cursor]))
        sm.note = nil
        local total = Scr.BonusText(function(st) return M.Bonus(mon, st) end)
        f.totals:SetText(total ~= "" and ("All together: " .. total) or "No gear or flask yet.")
    else
        f.model:SetPoint("TOPRIGHT", -14, -40)
        f.hint:SetText("Left/Right: gear   Space / X: close")
        f.body:SetText(Scr.SummaryInfoText(mon))
    end
end

-- Space on a gear slot: what the bag has for it, and "Take off".
function Scr.GearSlotAct(sm)
    local slot, mon = Scr.GEAR_ORDER[sm.cursor], sm.mon
    local idx = Scr.PartyIndex(mon)
    if G.battle then sm.note = "You can't change gear during a battle." Scr.RenderSummary(sm) return end
    if not idx then sm.note = "Only beasts in your party can change gear." Scr.RenderSummary(sm) return end
    local bag = G.save.bag
    local items = {}
    local function done(msg)
        sm.note = msg
        Scr.RenderSummary(sm)
    end
    for _, id in ipairs(D.itemOrder) do
        local def = D.items[id]
        local fits = (slot == "flask" and def.use == "flask") or (def.use == "gear" and def.slot == slot)
        if fits and (bag[id] or 0) > 0 then
            items[#items + 1] = { text = def.name, icon = def.icon,
                right = Scr.BonusText(function(st) return def.bonus and def.bonus[st] end),
                onSelect = function(_, m)
                    PopMenu(m)
                    local _, msg
                    if slot == "flask" then _, msg = G:UseFlask(idx, id) else _, msg = G:Equip(idx, id) end
                    done(msg)
                end }
        end
    end
    if slot ~= "flask" and Scr.SlotItem(mon, slot) then
        items[#items + 1] = { text = "Take off", onSelect = function(_, m)
            PopMenu(m)
            local _, msg = G:Unequip(idx, slot)
            done(msg)
        end }
    end
    if #items == 0 then
        done(slot == "flask" and "You have no flasks. Alchemists brew them."
            or ("You have nothing for the " .. Scr.SlotName(slot) .. " slot. Blacksmiths make gear."))
        return
    end
    items[#items + 1] = { text = "Cancel", onSelect = function(_, m) PopMenu(m) end }
    PushMenu(items, { w = 330, x = floor(SW / 2 - 165), y = -110, rowH = 32, title = Scr.SlotName(slot):upper(),
        onCancel = function(m) PopMenu(m) end })
end

function Scr.SummaryKey(top, key)
    local sm = top.summary
    if key == "left" or key == "right" then
        sm.page = (sm.page == "gear") and "info" or "gear"
        ns.AzeroSound:Play("tab")
        Scr.RenderSummary(sm)
        return
    end
    if key == "B" or (key == "A" and sm.page ~= "gear") then
        top.opts.onCancel(top)
        R.summary:Hide()
        return
    end
    if sm.page == "gear" then
        if key == "down" then sm.cursor = sm.cursor % #Scr.GEAR_ORDER + 1 Scr.RenderSummary(sm)
        elseif key == "up" then sm.cursor = (sm.cursor - 2) % #Scr.GEAR_ORDER + 1 Scr.RenderSummary(sm)
        elseif key == "A" then Scr.GearSlotAct(sm) end
    end
end

local function ShowSummary(mon, onClose, page)
    ns.AzeroSound:Play("sheet")
    local f = R.summary
    -- above every open menu (menus stack upward), with its model above the box
    local top = stack[#stack]
    local level = max(100, top and top.frame and top.frame:GetFrameLevel() + 10 or 0)
    f:SetFrameLevel(level)
    f.model:SetFrameLevel(level + 2)
    f.gear:SetFrameLevel(level + 1)
    for _, cell in ipairs(f.cells) do cell:SetFrameLevel(level + 3) end
    f:Show()
    ShowCreature(f.model, mon.sp, 0.5, mon.shiny)
    f.star:SetShown(mon.shiny == true)
    local sm = { mon = mon, page = page or "info", cursor = 1 }
    local entry = { frame = f, items = {}, cursor = 1, cols = 1, summary = sm, isSummary = true, co = G.co, opts = {
        onCancel = function(menu) PopMenu(menu) if onClose then onClose() end end } }
    sm.entry = entry
    stack[#stack + 1] = entry
    Scr.RenderSummary(sm)
end

local function OpenLog()
    ns.AzeroSound:Play("book")
    local s = G.save
    R.bagDesc:Hide()
    local items = {}
    for i, id in ipairs(D.dexOrder) do
        local sp = D.species[id]
        local seen, caught = s.seen[id], s.caught[id]
        items[i] = { text = string.format("%03d  %s", sp.num, seen and sp.name or "-----"),
                     right = (s.shinyCaught and s.shinyCaught[id]) and "shiny" or caught and "tamed" or (seen and "seen" or ""),
                     rightColor = (s.shinyCaught and s.shinyCaught[id]) and { 0.79, 0.54, 0.04 } or nil,
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
        local name = mon.shiny and ("|cffc98a0a" .. M.Name(mon) .. "|r") or M.Name(mon)
        items[i] = { text = string.format("%s  Lv%d%s", name, mon.lvl, st),
                     right = string.format("%d/%d", mon.hp, M.MaxHP(mon)), bar = mon.hp / M.MaxHP(mon),
                     onSelect = function(idx, menu) onPick(idx, menu) end }
    end
    return items
end

-- ctx: nil (start menu) | "battle" | "forced" (a fainted creature must be replaced) | "item" (pick a target)
--      | "teach" (pick a beast for the pet trainer) | "trade" (pick the beast to offer)
--      | "stable" (pick a beast to leave with the Stable Master)
local function OpenParty(ctx, onDone)
    ns.AzeroSound:Play("sheet")
    local b = G.battle
    R.bagDesc:Hide()
    local picking = ctx == "item" or ctx == "teach" or ctx == "trade" or ctx == "stable" or ctx == "equip"
    local partyMenu
    partyMenu = PushMenu(PartyItems(function(idx, menu)
        local mon = ActiveParty()[idx]
        if picking then
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
        opts[#opts + 1] = { text = "Gear", onSelect = function(_, sub)
            PopMenu(sub)
            ShowSummary(mon, nil, "gear")
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
    end), { x = 8, y = -8, w = 380, rowH = 40, level = 70,
        title = ctx == "item" and "USE ON WHICH?" or ctx == "teach" and "TEACH WHICH BEAST?"
            or ctx == "trade" and "OFFER WHICH BEAST? (again: take it back)" or ctx == "stable" and "LEAVE WHICH BEAST?"
            or ctx == "equip" and "EQUIP WHICH BEAST?" or "PARTY",
        onCancel = function(menu)
            if ctx == "forced" then return end
            PopMenu(menu)
            if onDone and not picking then onDone(nil) end
            if picking then onDone(nil, nil) end
        end })
    return partyMenu
end

local function OpenBag(ctx, onUse)
    ns.AzeroSound:Play("bag")
    local items = {}
    local bag = G.save.bag
    for _, id in ipairs(D.itemOrder) do
        if (bag[id] or 0) > 0 then
            local def = D.items[id]
            local right = "x" .. bag[id]
            local odds = ctx == "battle" and def.use == "ball" and G.battle and G.battle.wild and G.battle.TameOdds
            if odds then right = ns.AzeroTaming.Percent(G.battle:TameOdds(id)) .. "   " .. right end   -- (to tame it now)
            items[#items + 1] = { text = def.name, right = right, icon = def.icon, item = id,
                onSelect = function(_, menu) onUse(id, menu) end }
        end
    end
    if #items == 0 then
        Message("The bag is empty.")
        return
    end
    local desc = R.bagDesc
    -- in a battle it covers the whole text box (the prompt behind it would show its top line cut in half)
    desc:SetHeight(ctx == "battle" and BOX_H or 80)
    PushMenu(items, { x = 8, y = -8, w = 380, rowH = 36, title = "BAG", level = 70, desc = true,
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
    "Where you have been, and what's there.",
    "Your Azeromon achievements.",
    "Guild leaderboards and the Guild Bestiary.",
    "Today's bounties and the guild's weekly goal.",
    "Your professions: gather, smelt, brew and forge.",
    "Which types hit which, and how hard.",
    "Every key and button.",
    "Turn off the world's motion: wind, water, fire, critters, weather.",
    "Close this menu.",
}

-- Guild pages: pick a leaderboard (or the Guild Bestiary). Opening them asks guildmates for fresh summaries.
function Scr.FirstCompleteLine()
    local first = ns.AzeroGuild:FirstComplete()
    if not first then return "Nobody in the guild has completed the Bestiary yet." end
    local when = (date and first.done) and date("%d %b %Y", first.done) or ""
    return string.format("First to complete the Bestiary: %s%s (%s).", first.name, first.me and " (you)" or "", when)
end

function Scr.OpenRanking(cat)
    local rows = ns.AzeroGuild:Ranking(cat.id)
    local items = {}
    for _, r in ipairs(rows) do
        items[#items + 1] = { text = string.format("%d.  %s%s", r.rank, r.entry.name, r.entry.me and "  (you)" or ""),
                              right = r.text, onSelect = function() end }
    end
    if #items == 0 then items[1] = { text = "No guildmates known yet.", disabled = true } end
    PushMenu(items, { x = 8, y = -8, w = SW - 16, rowH = 30, level = 70, desc = true, title = cat.name:upper(),
        onCancel = function(menu) PopMenu(menu) R.bagDesc:Hide() end,
        onMove = function()
            R.bagDesc:Show()
            R.bagDesc.fs:SetText(Scr.FirstCompleteLine())
        end })
end

function Scr.OpenGuildBestiary()
    local items = {}
    for _, row in ipairs(ns.AzeroGuild:GuildBestiary()) do
        local sp = D.species[row.id]
        local known = row.count > 0 or (G.save and G.save.seen[row.id])
        items[#items + 1] = { text = string.format("%03d  %s", sp.num, known and sp.name or "-----"),
                              right = row.count > 0 and ("tamed by " .. row.count) or "", names = row.names,
                              disabled = row.count == 0, onSelect = function() end }
    end
    PushMenu(items, { x = 8, y = -8, w = SW - 16, rowH = 28, level = 70, desc = true, title = "GUILD BESTIARY",
        onCancel = function(menu) PopMenu(menu) R.bagDesc:Hide() end,
        onMove = function(i, menu)
            local names = menu.items[i].names
            R.bagDesc:Show()
            R.bagDesc.fs:SetText(#names > 0 and ("Tamed by: " .. table.concat(names, ", ")) or "Nobody in the guild has tamed this one yet.")
        end })
end

function Scr.OpenGuild()
    ns.AzeroSound:Play("book")
    ns.AzeroGuild:Query()
    local items = {}
    for _, cat in ipairs(ns.AzeroGuild.CATEGORIES) do
        items[#items + 1] = { text = cat.name, onSelect = function() Scr.OpenRanking(cat) end }
    end
    items[#items + 1] = { text = "Guild Bestiary", onSelect = function() Scr.OpenGuildBestiary() end }
    R.bagDesc:Hide()
    PushMenu(items, { x = 8, y = -8, w = 330, rowH = 32, level = 70, desc = true, title = "GUILD",
        onCancel = function(menu) PopMenu(menu) R.bagDesc:Hide() end,
        onMove = function()
            R.bagDesc:Show()
            R.bagDesc.fs:SetText(Scr.FirstCompleteLine())
        end })
end

-- The Achievements page: every achievement with its points (earned) or progress (not yet), and the
-- description (plus the date earned) in the box below.
function Scr.OpenAchievements()
    ns.AzeroSound:Play("book")
    local Ach = ns.AzeroAch
    local earned = Ach.Earned()
    local items = {}
    for _, a in ipairs(Ach.list) do
        local done = earned[a.id]
        local right
        if done then
            right = a.points .. " pts"
        elseif a.progress then
            local ok, cur, max = pcall(a.progress, G, Ach)
            right = (ok and cur and max) and string.format("%d/%d", cur, max) or ""
        else
            right = ""
        end
        items[#items + 1] = { text = a.name, right = right, icon = a.icon, disabled = not done, ach = a,
                              onSelect = function() end }
    end
    R.bagDesc:Hide()
    PushMenu(items, { x = 8, y = -8, w = SW - 16, rowH = 30, level = 70, desc = true,
        title = string.format("ACHIEVEMENTS   %d / %d   %d points", Ach:Count(), #Ach.list, Ach:Points()),
        onCancel = function(menu) PopMenu(menu) R.bagDesc:Hide() end,
        onMove = function(i, menu)
            local a = menu.items[i].ach
            local when = earned[a.id]
            R.bagDesc:Show()
            R.bagDesc.fs:SetText(a.desc .. ((type(when) == "number" and when > 0 and date)
                and ("   (earned " .. date("%d %b %Y", when) .. ")") or ""))
        end })
end

-- From the toast: open the page if the game is up and nothing else is on screen.
function UI:OpenAchievements()
    if root and root:IsVisible() and G.started and not G.pending and #stack == 0 and not G.battle then
        Scr.OpenAchievements()
    end
end
---------------------------------------------------------------------------
-- Professions: skills, and each crafting profession's recipes
---------------------------------------------------------------------------

-- the real game's difficulty colours, darkened to read on the white window
Scr.DIFF_COLOR = { orange = { 0.85, 0.42, 0.08 }, yellow = { 0.72, 0.58, 0.0 }, green = { 0.18, 0.58, 0.2 },
                     grey = { 0.55, 0.55, 0.58 } }

function Scr.MatsText(r)
    local bag, parts = G.save.bag, {}
    local names = {}
    for item in pairs(r.mats) do names[#names + 1] = item end
    table.sort(names)
    for _, item in ipairs(names) do
        parts[#parts + 1] = string.format("%s %d/%d", D.items[item].name, bag[item] or 0, r.mats[item])
    end
    return table.concat(parts, ", ")
end

function Scr.RecipeItems(prof)
    local C = ns.AzeroCraft
    local skill = C.Skill(prof) or 0
    local items = {}
    for _, r in ipairs(C.byProf[prof] or {}) do
        local def = D.items[r.makes]
        local n = C.CanMake(r)
        local text = def.name .. ((r.n or 1) > 1 and (" x" .. r.n) or "")
        if skill < r.skill then
            items[#items + 1] = { text = text, right = "Req. " .. r.skill, disabled = true, recipe = r, icon = def.icon }
        else
            items[#items + 1] = { text = text, right = n > 0 and ("can make " .. n) or "no materials",
                                  rightColor = Scr.DIFF_COLOR[C.Difficulty(r.skill, skill)], recipe = r, icon = def.icon,
                                  disabled = n == 0 }
        end
    end
    return items
end

function Scr.OpenRecipes(prof, onClose)
    local C = ns.AzeroCraft
    local p = D.professions[prof]
    local note = nil                          -- the last craft's result, shown until the cursor moves
    local menu
    local function desc(i, m)
        local it = m.items[i]
        R.bagDesc:Show()
        if note then
            R.bagDesc.fs:SetText(note)
            note = nil
            return
        end
        local r = it and it.recipe
        if not r then R.bagDesc.fs:SetText("") return end
        local where = r.station and not C:NearStation(r.station) and ("  Needs " .. D.recipeStations[r.station] .. ".") or ""
        R.bagDesc.fs:SetText(Scr.MatsText(r) .. where .. "\n" .. (D.items[r.makes].desc or ""))
    end
    local items = Scr.RecipeItems(prof)
    for _, it in ipairs(items) do
        it.onSelect = function(idx)
            local ok, msg = C:Craft(it.recipe)
            if ok and PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.LOOT_WINDOW_COIN_SOUND) or 120, "Master") end
            local fresh = Scr.RecipeItems(prof)
            for k, f in ipairs(fresh) do
                menu.items[k].right, menu.items[k].rightColor, menu.items[k].disabled = f.right, f.rightColor, f.disabled
            end
            note = msg
            UI:RefreshMenu(menu)
        end
    end
    menu = PushMenu(items, { x = 8, y = -8, w = SW - 16, rowH = 32, level = 70, desc = true,
        title = string.format("%s  %d / %d", p.name:upper(), C.Skill(prof) or 0, C.Cap(prof)),
        onCancel = function(m)
            PopMenu(m)
            R.bagDesc:Hide()
            if onClose then onClose() end
        end,
        onMove = function(i, m) desc(i, m) end })
    return menu
end

function Scr.OpenProfessions()
    ns.AzeroSound:Play("book")
    local C = ns.AzeroCraft
    R.bagDesc:Hide()
    local items = {}
    for _, id in ipairs(D.professionOrder) do
        local p = D.professions[id]
        local skill = C.Skill(id)
        items[#items + 1] = { text = p.name, icon = p.icon, prof = id,
            right = skill and string.format("%d / %d", skill, C.Cap(id)) or "not learned",
            bar = skill and skill / C.Cap(id) or nil, disabled = not skill,
            onSelect = function()
                if p.gather and id ~= "mining" then
                    Message(p.howto)
                else
                    Scr.OpenRecipes(id)
                end
            end }
    end
    PushMenu(items, { x = 8, y = -8, w = 330, rowH = 40, level = 70, desc = true, title = "PROFESSIONS",
        onCancel = function(menu) PopMenu(menu) R.bagDesc:Hide() end,
        onMove = function(i, menu)
            local it = menu.items[i]
            local p = D.professions[it.prof]
            R.bagDesc:Show()
            R.bagDesc.fs:SetText(C.Skill(it.prof) and p.howto or (p.trainer .. " in Goldshire teaches " .. p.name .. "."))
        end })
end

---------------------------------------------------------------------------
-- The bounty board: today's three bounties and the guild's weekly goal
---------------------------------------------------------------------------

function Scr.Duration(secs)
    secs = math.max(0, math.floor(secs or 0))
    local d, h, m = floor(secs / 86400), floor(secs / 3600) % 24, floor(secs / 60) % 60
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", max(1, m))
end

function Scr.OpenBounties(onClose)
    ns.AzeroSound:Play("quests")
    local BY = ns.AzeroBounty
    local st = BY and BY:State()
    if not st then return end
    R.bagDesc:Hide()
    local function close(menu)
        PopMenu(menu)
        R.bagDesc:Hide()
        if onClose then onClose() end
    end
    local items = {}
    for _, b in ipairs(st.list) do
        items[#items + 1] = { text = BY.Text(b), right = b.done and "Done" or (b.got .. " / " .. b.n),
                              bar = b.done and 1 or b.got / b.n, disabled = b.done, bounty = b,
                              onSelect = function() end }
    end
    local goal = BY.Goal(st.week)
    local mine, total = BY:Weekly()
    local reached, nextNeed = BY:Tier()
    items[#items + 1] = { text = "Guild: " .. goal.name,
                          right = nextNeed and (total .. " / " .. nextNeed) or (total .. "  Gold!"),
                          bar = min(1, total / goal.tiers[#goal.tiers]), guild = true, onSelect = function() end }
    items[#items + 1] = { text = "Close", onSelect = function(_, menu) close(menu) end }
    PushMenu(items, { x = 8, y = -8, w = SW - 16, rowH = 36, level = 70, desc = true, title = "BOUNTY BOARD",
        onCancel = close,
        onMove = function(i, menu)
            local it = menu.items[i]
            R.bagDesc:Show()
            if it.bounty then
                local b = it.bounty
                R.bagDesc.fs:SetText(string.format("%s: %s.\nNew bounties in %s.", b.done and "Paid" or "Reward",
                    BY.RewardText(b.money, b.item, b.count), Scr.Duration(BY.ResetIn())))
            elseif it.guild then
                local tiers = {}
                for t, need in ipairs(goal.tiers) do
                    tiers[t] = string.format("%s %d%s", D.guildTierNames[t], need, t <= reached and " (done)" or "")
                end
                local _, weekLeft = BY.WeekKey()
                R.bagDesc.fs:SetText(string.format("%s. You: %d of %d.\nEach tier pays everyone who helped. %s left.",
                    table.concat(tiers, ", "), mine, total, Scr.Duration(weekLeft)))
            else
                R.bagDesc.fs:SetText("New bounties every day at the daily reset, the same for the whole guild.")
            end
        end })
end

function UI:OpenBountiesPage()
    if root and root:IsVisible() and G.started and not G.pending and #stack == 0 and not G.battle then
        Scr.OpenBounties()
    end
end

local function StartMenuHelp(i)
    R.bagDesc:Show()
    R.bagDesc.fs:SetText(START_HELP[i] or "")
end

local OpenStartMenu
function OpenStartMenu()
    ns.AzeroSound:Play("open")
    local items = {
        { text = "BESTIARY", onSelect = function() OpenLog() end },
        { text = "PARTY", disabled = #G.save.party == 0, onSelect = function() OpenParty(nil) end },
        { text = "BAG", onSelect = function()
            OpenBag(nil, function(id, bagMenu)
                local def = D.items[id]
                if def.use == "ball" then Message("You can't throw that here.") return end
                if def.use == "charm" then
                    Message(G:UseCharm(id), function()
                        PopMenu(bagMenu)
                        R.bagDesc:Hide()
                    end)
                    return
                end
                if def.use == "material" then Message("It's a crafting material. See PROFESSIONS.") return end
                if def.use == "tool" or def.use == "junk" then Message(def.useText) return end
                if def.use == "lure" then
                    Message(ns.AzeroFish:UseLure(id), function()
                        PopMenu(bagMenu)
                        R.bagDesc:Hide()
                    end)
                    return
                end
                if def.use == "boost" then Message("Drink it in battle: it raises the stat of the beast fighting.") return end
                if def.use == "evolve" then                    -- an evolution item: the scene plays as a script
                    OpenParty("item", function(idx, partyMenu)
                        if partyMenu then PopMenu(partyMenu) end
                        if not idx then return end
                        if not M.ItemEvolution(G.save.party[idx], id) then
                            Message("It won't have any effect.")
                            return
                        end
                        CloseAllMenus()
                        R.bagDesc:Hide()
                        G:Run(function(g) g:UseEvolveItem(idx, id) end)
                    end)
                    return
                end
                if def.use == "gear" or def.use == "flask" then
                    OpenParty(def.use == "gear" and "equip" or "item", function(idx, partyMenu)
                        if partyMenu then PopMenu(partyMenu) end
                        if not idx then return end
                        local _, msg
                        if def.use == "gear" then _, msg = G:Equip(idx, id) else _, msg = G:UseFlask(idx, id) end
                        Message(msg, function()
                            PopMenu(bagMenu)
                            R.bagDesc:Hide()
                        end)
                    end)
                    return
                end
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
        { text = "MAP", onSelect = function() ns.AzeroWorld:Open() end },
        { text = "ACHIEVEMENTS", onSelect = function() Scr.OpenAchievements() end },
        { text = "GUILD", onSelect = function() Scr.OpenGuild() end },
        { text = "BOUNTIES", onSelect = function() Scr.OpenBounties() end },
        { text = "PROFESSIONS", onSelect = function() Scr.OpenProfessions() end },
        { text = "TYPE CHART", onSelect = function() KH.OpenTypeChart() end },
        { text = "CONTROLS", onSelect = function() KH.OpenControls() end },
        { text = G:Data().calm and "MOTION: OFF" or "MOTION: ON", onSelect = function(_, menu)
            G:Data().calm = not G:Data().calm or nil
            PopMenu(menu)
            OpenStartMenu()
        end },
        { text = "EXIT", onSelect = function(_, menu) PopMenu(menu) end },
    }
    PushMenu(items, { w = 210, rowH = 25, level = 60, desc = true, onMove = StartMenuHelp, onCancel = function(menu) PopMenu(menu) end })
    R.money:Show()
end

---------------------------------------------------------------------------
-- Shop
---------------------------------------------------------------------------

-- Selling: the bag's goods a shop will buy, a quantity (left / right), then the coins.
function Scr.OpenSell()
    ns.AzeroSound:Play("shop")
    local items = {}
    local bag = G.save.bag
    for _, id in ipairs(D.itemOrder) do
        local def, have, each = D.items[id], bag[id] or 0, G:SellPrice(id)
        if have > 0 and each > 0 then
            items[#items + 1] = { text = def.name, right = string.format("x%d  %s", have, D.Money(each)), icon = def.icon,
                item = id, onSelect = function(_, sellMenu)
                    local qty = have
                    local function qtyItems()
                        return { { text = string.format("x%d   %s", qty, D.Money(qty * each)), onSelect = function(_, qm)
                            PopMenu(qm)
                            local _, msg = G:Sell(id, qty)
                            Message(msg, function()
                                PopMenu(sellMenu)
                                Scr.OpenSell()
                            end)
                        end } }
                    end
                    local qm = PushMenu(qtyItems(), { w = 170, x = SW - 176, y = -250, level = 80, title = "HOW MANY?",
                        onCancel = function(m) PopMenu(m) end })
                    qm.onLeftRight = function(dir)
                        if dir == "up" or dir == "right" then qty = min(have, qty + 1) else qty = max(1, qty - 1) end
                        qm.items = qtyItems()
                        UI:RefreshMenu(qm)
                    end
                end }
        end
    end
    if #items == 0 then
        Message("You have nothing to sell.")
        return
    end
    PushMenu(items, { x = 8, y = -8, w = 400, rowH = 36, title = "SELL", level = 70, desc = true,
        onCancel = function(menu) PopMenu(menu) R.bagDesc:Hide() end,
        onMove = function(i, menu)
            local it = menu.items[i].item
            R.bagDesc:SetShown(it ~= nil)
            if it then
                R.bagDesc.fs:SetText(string.format("%s\nSells for %s each.", D.items[it].desc or "", D.Money(G:SellPrice(it))))
            end
        end })
end

local function OpenShop(keeper, stock)
    ns.AzeroSound:Play("shop")
    local items = {}
    for _, id in ipairs(D.ShopStock(stock)) do
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
                    qm.items = qtyItems()               -- (rows redraw from the items)
                    UI:RefreshMenu(qm)
                end
            end }
    end
    items[#items + 1] = { text = "Sell", onSelect = function() Scr.OpenSell() end }
    items[#items + 1] = { text = "Done", onSelect = function(_, menu)
        PopMenu(menu)
        R.bagDesc:Hide()
        G:Advance()
    end }
    R.money:Show()
    PushMenu(items, { x = 8, y = -8, w = 330, rowH = 36, title = (keeper or "Shop"):upper(), level = 70, desc = true,
        onCancel = function(menu) PopMenu(menu) R.bagDesc:Hide() G:Advance() end,
        onMove = function(i, menu)
            local it = menu.items[i].item
            R.bagDesc:SetShown(it ~= nil or menu.items[i].text == "Sell")
            if it then R.bagDesc.fs:SetText(D.items[it].desc)
            elseif menu.items[i].text == "Sell" then R.bagDesc.fs:SetText("Sell what you carry: crafted goods, herbs, ore...") end
        end })
end

---------------------------------------------------------------------------
-- The stable (a Stable Master at any inn): take beasts out, leave beasts there
---------------------------------------------------------------------------


function Scr.BeastLine(mon)
    local s = D.species[mon.sp]
    local moves = {}
    for i, mv in ipairs(mon.moves) do moves[i] = D.moves[mv.id].name end
    return string.format("%s  Lv%d  %s  HP %d/%d\n%s", M.Name(mon), mon.lvl, D.types[s.type].name, mon.hp, M.MaxHP(mon),
        table.concat(moves, ", "))
end

function Scr.OpenStableBox(onClose)
    ns.AzeroSound:Play("stable")
    local box = G.save.box
    local items = {}
    for i, mon in ipairs(box) do
        local name = mon.shiny and ("|cffc98a0a" .. M.Name(mon) .. "|r") or M.Name(mon)
        items[i] = { text = string.format("%s  Lv%d", name, mon.lvl), right = D.types[D.species[mon.sp].type].name,
            mon = mon, onSelect = function(idx, menu)
                PushMenu({
                    { text = "Take out", onSelect = function(_, sub)
                        PopMenu(sub)
                        local ok, msg = G:Withdraw(idx)
                        Message(msg, function()
                            if ok then PopMenu(menu) onClose() end
                        end)
                    end },
                    { text = "Summary", onSelect = function(_, sub)
                        PopMenu(sub)
                        ShowSummary(box[idx], function() end)
                    end },
                    { text = "Cancel", onSelect = function(_, sub) PopMenu(sub) end },
                }, { w = 150, x = SW - 156, y = -120, level = 80, onCancel = function(sub) PopMenu(sub) end })
            end }
    end
    PushMenu(items, { x = 8, y = -8, w = 330, rowH = 32, level = 70, desc = true,
        title = string.format("IN THE STABLE (%d)", #box),
        onCancel = function(menu) PopMenu(menu) onClose() end,
        onMove = function(i, menu)
            local it = menu.items[i]
            R.bagDesc:Show()
            R.bagDesc.fs:SetText(it and it.mon and Scr.BeastLine(it.mon) or "")
        end })
end

Scr.OpenStable = function(onDone)
    R.bagDesc:Hide()
    local function reopen() Scr.OpenStable(onDone) end
    local items = {
        { text = "Take a beast out", disabled = #G.save.box == 0, onSelect = function(_, menu)
            PopMenu(menu)
            Scr.OpenStableBox(reopen)
        end },
        { text = "Leave a beast here", disabled = #G.save.party <= 1, onSelect = function(_, menu)
            PopMenu(menu)
            OpenParty("stable", function(idx, partyMenu)
                if partyMenu then PopMenu(partyMenu) end
                if not idx then reopen() return end
                local _, msg = G:Deposit(idx)
                Message(msg, reopen)
            end)
        end },
        { text = "Done", onSelect = function(_, menu)
            PopMenu(menu)
            R.bagDesc:Hide()
            if onDone then onDone() end
        end },
    }
    PushMenu(items, { w = 230, rowH = 36, level = 60, desc = true, title = "STABLE",
        onCancel = function(menu)
            PopMenu(menu)
            R.bagDesc:Hide()
            if onDone then onDone() end
        end,
        onMove = function()
            R.bagDesc:Show()
            R.bagDesc.fs:SetText(string.format("In the stable: %d %s. In your party: %d of %d.", #G.save.box,
                #G.save.box == 1 and "beast" or "beasts", #G.save.party, D.MAX_PARTY))
        end })
end

---------------------------------------------------------------------------
-- Trading (Trade.lua runs it): both offers side by side, a status line, Offer / Trade / Cancel
---------------------------------------------------------------------------


function Scr.TradeCard(c, label, mon, items)
    c.label:SetText(label)
    local itemsText = ns.AzeroTrade.ItemsText(items)
    c.items:SetText("")
    if not mon then
        ShowCreature(c.model, nil)
        c.star:Hide()
        c.pill:Hide()
        c.info:SetText("")
        if itemsText ~= "" then
            c.name:SetText("Items")
            c.moves:SetText(itemsText)
        else
            c.name:SetText("Nothing offered yet.")
            c.moves:SetText("")
        end
        return
    end
    ShowCreature(c.model, mon.sp, 0.5, mon.shiny)
    c.name:SetText(M.Name(mon))
    c.star:SetShown(mon.shiny == true)
    local t = D.types[D.species[mon.sp].type]
    c.pill:Set(t.name:upper(), t.color)
    c.info:SetText(string.format("Lv%d   OT %s", mon.lvl, mon.ot or G:PlayerName()))
    local names = {}
    for i, mv in ipairs(mon.moves) do names[i] = D.moves[mv.id].name end
    c.moves:SetText(table.concat(names, ", "))
    if itemsText ~= "" then c.items:SetText("+ " .. itemsText) end
end

function Scr.RefreshTrade(s)
    local f = R.trade
    if not f or not f:IsShown() or not s then return end
    if s.state ~= "open" then
        Scr.tradeMenu = nil
        CloseAllMenus()
        f:Hide()
        return
    end
    Scr.TradeCard(f.cards[1], "YOU OFFER", s.mine, s.myItems)
    Scr.TradeCard(f.cards[2], s.name:upper() .. " OFFERS", s.theirs, s.theirItems)
    local mineAny = s.mine or next(s.myItems or {})
    local theirAny = s.theirs or next(s.theirItems or {})
    local status
    if not mineAny and not theirAny then status = "Offer a beast or items. (Offering nothing is fine: a gift.)"
    elseif s.myOk then status = "Waiting for " .. s.name .. " to accept..."
    elseif s.theirOk then status = s.name .. " accepted this trade!"
    elseif not theirAny then status = "Nothing from " .. s.name .. " yet. Trade as a gift, or wait."
    elseif not mineAny then status = s.name .. " offers something. Accept it as a gift, or add your side."
    else status = "Both offers are on the table. Trade?" end
    f.status:SetText(status)
    local menu = Scr.tradeMenu
    if menu then
        local it = menu.items
        it[1].disabled = s.myOk ~= nil
        it[2].disabled = s.myOk ~= nil
        it[3].disabled = not (mineAny or theirAny) or s.myOk ~= nil
        it[3].text = s.myOk and "Accepted" or "Trade"
        UI:RefreshMenu(menu)
    end
end

-- Offer items: Space puts one more on the table; "Take back all items" clears them.
function Scr.OpenTradeItems()
    local T, s = ns.AzeroTrade, ns.AzeroTrade.session
    if not s then return end
    local bag = G.save.bag
    local items = { { text = "Take back all items", onSelect = function(_, menu)
        T:TakeBackItems()
        for _, it in ipairs(menu.items) do
            if it.item then it.right = string.format("0 / %d", bag[it.item] or 0) end
        end
        UI:RefreshMenu(menu)
    end } }
    for _, id in ipairs(D.itemOrder) do
        local have = bag[id] or 0
        if have > 0 then
            items[#items + 1] = { text = D.items[id].name, icon = D.items[id].icon, item = id,
                right = string.format("%d / %d", s.myItems[id] or 0, have),
                onSelect = function(idx, menu)
                    local n = T:OfferItem(id, 1)
                    menu.items[idx].right = string.format("%d / %d", n or 0, bag[id] or 0)
                    UI:RefreshMenu(menu)
                end }
        end
    end
    if #items == 1 then
        Message("Your bag is empty.")
        return
    end
    PushMenu(items, { x = 8, y = -8, w = 330, rowH = 32, title = "OFFER ITEMS", desc = true,
        onCancel = function(menu) PopMenu(menu) R.bagDesc:Hide() end,
        onMove = function(i, menu)
            R.bagDesc:Show()
            R.bagDesc.fs:SetText(menu.items[i].item and "Space: one more on the table (offered / in your bag). X: done."
                or "Put everything back in your bag.")
        end })
end

function Scr.OpenTrade(s)
    local f = R.trade
    CloseAllMenus()
    R.bagDesc:Hide()
    f.title:SetText("TRADE WITH " .. s.name:upper())
    f:Show()
    local items = {
        { text = "Offer a beast", onSelect = function()
            OpenParty("trade", function(idx, partyMenu)
                if partyMenu then PopMenu(partyMenu) end
                if idx then ns.AzeroTrade:Offer(idx) end
            end)
        end },
        { text = "Offer items", onSelect = function() Scr.OpenTradeItems() end },
        { text = "Trade", disabled = true, onSelect = function()
            local ok, why = ns.AzeroTrade:Confirm()
            if not ok and why == "last" then Message("You can't give away your last beast without getting one back.") end
        end },
        { text = "Cancel", onSelect = function() ns.AzeroTrade:Cancel() end },
    }
    Scr.tradeMenu = PushMenu(items, { anchor = { "BOTTOMRIGHT", screen, "BOTTOMRIGHT", -8, 8 }, w = 190, rowH = 28,
        level = 100, onCancel = function() ns.AzeroTrade:Cancel() end })
    Scr.RefreshTrade(s)
end

---------------------------------------------------------------------------
-- Moves side by side (learning a 5th move, the pet trainer): R.moveCompare holds two cards under the menu
---------------------------------------------------------------------------

Scr.MOVE_DESC_H = BOX_H + 6
Scr.STATUS_TXT = {
    brn = { "Burns the foe", "May burn the foe" },
    psn = { "Poisons the foe", "May poison the foe" },
    par = { "Paralyzes the foe", "May paralyze the foe" },
    slp = { "Puts the foe to sleep", "May put the foe to sleep" },
}
Scr.STAT_TXT = { atk = "Attack", def = "Defense", spa = "Sp. Atk", spd = "Sp. Def", spe = "Speed" }

-- What a move does besides damage, in a few words ("" for a plain attack).
function Scr.MoveEffectText(md)
    local out = Scr.EffectParts(md)
    if md.prio and md.prio > 0 and not md.role then table.insert(out, 1, "Always strikes first") end
    if md.role then         -- (0.37 kits: the move box's line; the cooldown is on the stats line)
        local note = Scr.MoveNote(md)
        if note ~= "" and note ~= "No cooldown" and not (md.effect and md.effect.kind == "stat") then out[#out + 1] = note end
    end
    return table.concat(out, "; ")
end

-- What a move's effect does (a status or stat chance, a drain), as phrases.
function Scr.EffectParts(md)
    local e, out = md.effect, {}
    if e and e.kind == "status" and Scr.STATUS_TXT[e.status] then
        local t = Scr.STATUS_TXT[e.status]
        out[#out + 1] = (e.chance and e.chance < 100) and string.format("%s (%d%%)", t[2], e.chance) or t[1]
    elseif e and e.kind == "stat" then
        local st = e.stages or 0
        local verb = st >= 2 and { "Sharply raises", "May sharply raise" } or st > 0 and { "Raises", "May raise" }
            or st <= -2 and { "Sharply lowers", "May sharply lower" } or { "Lowers", "May lower" }
        local what = (e.who == "self" and "its " or "the foe's ") .. (Scr.STAT_TXT[e.stat] or e.stat)
        out[#out + 1] = (e.chance and e.chance < 100) and string.format("%s %s (%d%%)", verb[2], what, e.chance)
            or (verb[1] .. " " .. what)
    elseif e and e.kind == "drain" then
        out[#out + 1] = e.pct == 50 and "Heals half the damage dealt" or string.format("Heals %d%% of the damage dealt", e.pct)
    end
    return out
end

-- The move list's description line (0.40): what a move does, as one short sentence. `mon`: the beast using it
-- (a setup names the payoff it feeds, when this beast knows one).
function Scr.MoveLine(md, mon)
    local first
    local mk = md.mark and D.MARKS[md.mark.id]
    if md.cast then
        first = md.unstoppable and "Lands next turn and can't be interrupted." or "Lands next turn. Guard or interrupt can stop it."
    elseif md.guard then
        first = string.format("Goes first. Soaks %d%% of hits for %d turns.", floor((1 - md.guard) * 100 + 0.5), md.guardTurns or 1)
    elseif md.interrupt then
        first = "Goes first and breaks the foe's cast."
    elseif md.heal then
        first = string.format("Heals %d%% of its HP%s.", floor(md.heal * 100 + 0.5),
            mk and string.format(", then %s for %d turns", mk.short, md.mark.turns) or "")
    elseif md.payoff and md.payoff.mark and D.MARKS[md.payoff.mark] then
        local pm = D.MARKS[md.payoff.mark]
        first = string.format("x%s %s %s%s.", tostring(md.payoff.mult), md.payoff.self and "once it is" or "while the foe is",
            pm.name, md.payoff.consume and (md.payoff.self and "; uses the charge" or "; uses it up") or "")
    elseif mk then
        local feeds
        for _, m in ipairs(mon and mon.moves or {}) do
            local pd = D.moves[m.id]
            if pd and pd.payoff and pd.payoff.mark == md.mark.id then feeds = pd break end
        end
        first = string.format("%s (%d turns)%s", md.mark.who == "self" and ("Gets " .. mk.short) or ("Leaves " .. mk.short), md.mark.turns,
            feeds and string.format(": %s hits x%s.", feeds.name, tostring(feeds.payoff.mult)) or ".")
    end
    local parts = Scr.EffectParts(md)
    if first and #parts > 0 then                         -- both, shortly: one sentence, its two halves by a ";"
        local rest = (table.concat(parts, "; "):gsub("Heals half the damage dealt", "heals half the damage"))
        if md.cast then return "Lands next turn. " .. (rest:gsub("^%l", string.upper)) .. "." end
        return (first:gsub("%.$", "")) .. "; " .. (rest:gsub("^%u", string.lower)) .. "."
    end
    if first then return first end
    if #parts > 0 then return table.concat(parts, "; ") .. "." end
    if md.power > 0 then
        local reach = md.noImmune and " It even reaches fliers." or ""       -- (Earth's thrown rocks)
        if (md.cd or 0) == 0 then return "No rest: use it any turn." .. reach end
        return "A heavy hit." .. reach
    end
    return ""
end

-- A pixel hourglass (5 x 7 blocks of `px` UI pixels) on `parent`: the rest a move takes after use.
Scr.GLASS = { "#####", "#ooo#", ".#o#.", "..#..", ".#.#.", "#.o.#", "#####" }
function Scr.Hourglass(parent, px)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(5 * px, 7 * px)
    for y, row in ipairs(Scr.GLASS) do
        for x = 1, 5 do
            local ch = row:sub(x, x)
            if ch ~= "." then
                local t = f:CreateTexture(nil, "ARTWORK")
                if ch == "#" then t:SetColorTexture(0.29, 0.33, 0.45, 1) else t:SetColorTexture(0.85, 0.64, 0.23, 1) end
                t:SetSize(px, px)
                t:SetPoint("TOPLEFT", (x - 1) * px, -(y - 1) * px)
            end
        end
    end
    return f
end

-- A resting move's mark (0.40): the hourglass, then one pip per turn of its rest, filled for the turns still left.
function Scr.RestMarkWidth(total, glass) return (glass and 15 or 0) + total * 8 + (total - 1) * 3 end
function Scr.RestMark(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(80, 14)
    f.glass = Scr.Hourglass(f, 2)
    f.pips = {}
    function f:Set(total, left, glass)
        self.total, self.left, self.withGlass = total, left, glass and true or false
        self.glass:SetShown(glass and true or false)
        self.glass:ClearAllPoints()
        self.glass:SetPoint("LEFT", 0, 0)
        local x = glass and 15 or 0
        for i = 1, max(total, #self.pips) do
            local p = self.pips[i]
            if not p and i <= total then
                p = { edge = self:CreateTexture(nil, "ARTWORK", nil, 0), core = self:CreateTexture(nil, "ARTWORK", nil, 1) }
                p.edge:SetSize(8, 8)
                p.core:SetSize(4, 4)
                self.pips[i] = p
            end
            if p then
                local on, show = i <= left, i <= total
                p.edge:SetShown(show) p.core:SetShown(show)
                if show then
                    if on then p.edge:SetColorTexture(0.29, 0.33, 0.45, 1) p.core:SetColorTexture(0.49, 0.54, 0.69, 1)
                    else p.edge:SetColorTexture(0.72, 0.74, 0.80, 1) p.core:SetColorTexture(0.97, 0.96, 0.93, 1) end
                    p.edge:ClearAllPoints() p.edge:SetPoint("LEFT", x + (i - 1) * 11, 0)
                    p.core:ClearAllPoints() p.core:SetPoint("CENTER", p.edge, "CENTER", 0, 0)
                end
            end
        end
        self:SetWidth(Scr.RestMarkWidth(total, glass))
    end
    return f
end

-- A row's gold glint, played once on the turn a resting move is ready again (0.40).
function Scr.Glint(parent)
    local f = CreateFrame("Frame", nil, parent)
    pcall(f.SetClipsChildren, f, true)
    f.band = f:CreateTexture(nil, "OVERLAY")
    f.band:SetColorTexture(1, 0.88, 0.55, 0.6)
    f.band:SetSize(26, 10)
    f:Hide()
    function f:Play(row)
        self:ClearAllPoints()
        self:SetAllPoints(row)
        self.t = 0
        self:Show()
        self:SetScript("OnUpdate", function(g, dt)
            g.t = g.t + dt
            local p = g.t / 0.8
            if p >= 1 then g:SetScript("OnUpdate", nil) g:Hide() return end
            local w, h = g:GetWidth(), g:GetHeight()
            g.band:SetSize(26, h)
            g.band:ClearAllPoints()
            g.band:SetPoint("LEFT", g, "LEFT", -26 + (w + 26) * p, 0)
            g.band:SetAlpha(p < 0.7 and 0.6 or 0.6 * (1 - (p - 0.7) / 0.3))
        end)
    end
    return f
end

-- The fight menu's own layer (0.40), over its pooled menu frame while it is open: the description line under the
-- moves (a hairline, the coach's tag, one sentence) and each resting move's mark and glint. The menu's onPop hides it.
function Scr.FightDeco(menu)
    local d = R.fightDeco
    if not d then
        d = CreateFrame("Frame", nil, screen)
        d.rule = Tex(d, "ARTWORK")
        d.rule:SetColorTexture(0.80, 0.85, 0.92, 1)
        d.rule:SetHeight(2)
        d.coach = Pill(d, 64, 18, 12)
        d.text = Font(d, 12)
        d.text:SetWordWrap(false)
        d.marks, d.glints = {}, {}
        R.fightDeco = d
    end
    if not menu then
        d:Hide()
        d.menu, d.strip = nil, nil
        d:SetParent(screen)
        return d
    end
    if d.menu ~= menu then
        d.menu = menu
        d:SetParent(menu.frame)
        d:ClearAllPoints()
        d:SetAllPoints(menu.frame)
        d.rule:ClearAllPoints()
        d.rule:SetPoint("TOPLEFT", 18, -78)
        d.rule:SetPoint("TOPRIGHT", -18, -78)
    end
    d:SetFrameLevel(menu.frame:GetFrameLevel() + 3)
    d:Show()
    return d
end

-- The description line for move row `it` (the coach's sentence for its pick): one line, a size smaller before cut.
function Scr.MoveStrip(menu, it, mon)
    local d = Scr.FightDeco(menu)
    local room = menu.frame:GetWidth() - 40
    local x, text = 20, ""
    if it.move and it.why then
        d.coach:Set("COACH", { 0.15, 0.26, 0.55 })
        d.coach:SetFrameLevel(d:GetFrameLevel() + 1)
        d.coach:ClearAllPoints()
        d.coach:SetPoint("TOPLEFT", 20, -85)
        x, text = 20 + 64 + 8, it.why
        d.text:SetTextColor(0.15, 0.26, 0.55)
    else
        d.coach:Hide()
        text = it.move and Scr.MoveLine(D.moves[it.move.id], mon) or ""
        d.text:SetTextColor(0.36, 0.38, 0.44)
    end
    local w = room - (x - 20)
    local size = (TextWidth(text, 12) <= w) and 12 or 11
    if not d.text:SetFont(FONT, floor(size * 1.25 + 0.5), "") then d.text:SetFont(FONT_FALLBACK, size, "") end
    d.text:ClearAllPoints()
    d.text:SetPoint("TOPLEFT", x, size == 12 and -86 or -87)
    d.text:SetWidth(w)
    d.text:SetText(text)
    d.strip = (it.why and "Coach: " or "") .. text
end

-- Each row's right-hand mark (a resting move) and glint (ready again this turn).
function Scr.FightMarks(menu, ready)
    local d = Scr.FightDeco(menu)
    for i = 1, 4 do
        local it, row = menu.items[i], menu.frame.rows[i]
        local m = d.marks[i]
        if it and it.mark and row then
            if not m then m = Scr.RestMark(d) d.marks[i] = m end
            m:Set(it.mark.total, it.mark.left, it.mark.glass)
            m:SetFrameLevel(d:GetFrameLevel() + 1)
            m:ClearAllPoints()
            m:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            m:Show()
        elseif m then
            m:Hide()
        end
        local gl = d.glints[i]
        if ready and ready[i] and row then
            if not gl then gl = Scr.Glint(d) d.glints[i] = gl end
            gl:SetFrameLevel(d:GetFrameLevel() + 2)
            gl:Play(row)
        elseif gl then
            gl:Hide()
        end
    end
end

-- A move row's name size and right slot (0.40): the full name at its size beside its right slot when it fits;
-- else a resting move drops the hourglass, then the name steps down to 15 or 14 (cut only past that).
function Scr.FitMoveRow(it, colW)
    local room = colW - 24 - 6
    local slot = 0
    if it.mark then
        local full = Scr.RestMarkWidth(it.mark.total, true) + 10
        it.mark.glass = TextWidth(it.text, 16) <= room - full
        slot = it.mark.glass and full or (Scr.RestMarkWidth(it.mark.total, false) + 10)
        it.rightW = slot
    elseif it.right and it.right ~= "" then
        slot = TextWidth(it.right, 13) + 12
    end
    for _, size in ipairs({ 16, 15, 14 }) do
        it.size = size
        if TextWidth(it.text, size) <= room - slot then break end
    end
end

function Scr.MoveStatsText(md, pp)
    return table.concat({ md.power > 0 and ("Power " .. md.power) or "Status",
        (md.acc or 0) > 0 and ("Acc " .. md.acc .. "%") or "Never misses",
        "PP " .. (pp and (pp .. "/" .. md.pp) or md.pp), (md.cd or 0) > 0 and ("CD " .. md.cd) or nil }, "   ")
end

-- Card i (1 = left, 2 = right): a label, then the move's name, type, numbers and effect.
function Scr.MoveCard(i, label, id, pp)
    local c = R.moveCompare.cards[i]
    c.label:SetText(label or "")
    local md = id and D.moves[id]
    if not md then
        c.name:SetText("")
        c.pill:Hide()
        c.stats:SetText("")
        c.effect:SetText("")
        return c
    end
    local t = D.types[md.type]
    c.name:SetText(md.name)
    c.pill:Set(t.name:upper(), t.color)
    c.stats:SetText(Scr.MoveStatsText(md, pp))
    c.effect:SetText(Scr.MoveEffectText(md))
    return c
end

-- Card i with plain text instead of a move.
function Scr.TextCard(i, label, title, line)
    local c = Scr.MoveCard(i, label, nil)
    c.name:SetText(title or "")
    c.stats:SetText(line or "")
end

-- A menu row for a move: its name, with its type and power on the right in the type's colour.
function Scr.MoveRow(id, onSelect)
    local md = D.moves[id]
    local t = D.types[md.type]
    return { text = md.name, right = t.name .. (md.power > 0 and ("  " .. md.power) or ""), move = id,
             rightColor = { t.color[1] * 0.7, t.color[2] * 0.7, t.color[3] * 0.7 }, onSelect = onSelect }
end

-- "Forget which move?": the beast's moves and "Don't learn", the new move beside the highlighted one.
-- onPick(slot) - slot nil = keep the old moves.
function Scr.PushForgetMenu(mon, newId, onPick, onCancel)
    local function pick(slot, menu)
        PopMenu(menu)
        R.moveCompare:Hide()
        onPick(slot)
    end
    local items = {}
    for i, mv in ipairs(mon.moves) do
        items[i] = Scr.MoveRow(mv.id, function(idx, menu) pick(idx, menu) end)
    end
    items[#items + 1] = { text = "Don't learn " .. D.moves[newId].name, onSelect = function(_, menu) pick(nil, menu) end }
    R.moveCompare:Show()
    Scr.MoveCard(1, "NEW MOVE", newId)
    return PushMenu(items, { w = 300, x = SW - 306, y = -60, rowH = 30, level = 70, title = "FORGET WHICH MOVE?",
        desc = Scr.MOVE_DESC_H, onCancel = onCancel or function() end,
        onMove = function(i)
            local mv = mon.moves[i]
            if mv then Scr.MoveCard(2, "FORGET", mv.id, mv.pp) else Scr.TextCard(2, "KEEP", "All its moves", "Learn nothing new.") end
        end })
end

---------------------------------------------------------------------------
-- The pet trainer: pick a beast, then a move it could know by now (G:Relearn takes the fee)
---------------------------------------------------------------------------


function Scr.RelearnDone(taught, msg)
    CloseAllMenus()
    R.moveCompare:Hide()
    if msg then Message(msg, function() G:Advance(taught) end) else G:Advance(taught) end
end

function Scr.OpenRelearnMoves(idx)
    local mon = G.save.party[idx]
    local list = G:RelearnableMoves(mon)
    if #list == 0 then
        Message(M.Name(mon) .. " has nothing to be reminded of yet.", function() Scr.OpenRelearn() end)
        return
    end
    local items = {}
    for i, id in ipairs(list) do
        items[i] = Scr.MoveRow(id, function(_, menu)
            local function teach(slot)
                local ok, msg = G:Relearn(idx, id, slot)
                Scr.RelearnDone(ok, msg)
            end
            if #mon.moves < 4 then
                teach(nil)
            else
                Scr.PushForgetMenu(mon, id, function(slot)
                    if slot then teach(slot) else UI:RefreshMenu(menu) end      -- back to the list
                end, function(fm)
                    PopMenu(fm)
                    UI:RefreshMenu(menu)
                end)
            end
        end)
    end
    PushMenu(items, { x = 8, y = -8, w = 300, rowH = 30, level = 70, title = "REMEMBER WHICH MOVE?", desc = Scr.MOVE_DESC_H,
        onCancel = function(menu)
            PopMenu(menu)
            R.moveCompare:Hide()
            Scr.OpenRelearn()
        end,
        onMove = function(i)
            R.moveCompare:Show()
            Scr.MoveCard(1, "REMEMBER", list[i])
            Scr.TextCard(2, "LESSON", G.RELEARN_PRICE > 0 and D.Money(G.RELEARN_PRICE) or "Free",
                G.RELEARN_PRICE > 0 and ("You have " .. D.Money(G.save.money)) or "Swap as often as you like")
        end })
end

Scr.OpenRelearn = function()
    OpenParty("teach", function(idx, partyMenu)
        if partyMenu then PopMenu(partyMenu) end
        if not idx then Scr.RelearnDone(false) return end
        Scr.OpenRelearnMoves(idx)
    end)
end

---------------------------------------------------------------------------
-- Battle
---------------------------------------------------------------------------

-- (BT, the playback state, is declared at the top: the text box and messages need it)
BT.lastMove = setmetatable({}, { __mode = "k" })   -- [beast] = the move slot it used last (the move list opens there)

-- A shiny's entrance: stars burst out around the model, with the dig-site chime.
Scr.SPARKLE_TEX = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
function Scr.Sparkle(m)
    if not Scr.sparkle then
        Scr.sparkle = CreateFrame("Frame", nil, R.battle)
        Scr.sparkle.stars = {}
        for i = 1, 7 do
            local t = Scr.sparkle:CreateTexture(nil, "OVERLAY")
            t:SetTexture(Scr.SPARKLE_TEX)
            t:SetBlendMode("ADD")
            t:Hide()
            Scr.sparkle.stars[i] = t
        end
    end
    Scr.sparkle:SetFrameLevel(m:GetFrameLevel() + 5)
    Scr.sparkle:ClearAllPoints()
    Scr.sparkle:SetAllPoints(m)
    Scr.sparkle.t = 0
    Scr.sparkle:Show()
    Scr.sparkle:SetScript("OnUpdate", function(self, dt)
        self.t = self.t + dt
        local w, h = self:GetWidth(), self:GetHeight()
        for i, st in ipairs(self.stars) do
            local f = (self.t - (i - 1) * 0.09) / 0.7
            if f < 0 or f > 1 then
                st:Hide()
            else
                local ang = i * 2.4 + 0.5
                local r = 0.14 + 0.24 * f
                local size = 4 + 24 * math.sin(f * math.pi)
                st:ClearAllPoints()
                st:SetPoint("CENTER", self, "CENTER", math.cos(ang) * r * w, math.sin(ang) * r * h * 0.8)
                st:SetSize(size, size)
                st:SetAlpha(1 - 0.6 * f)
                st:Show()
            end
        end
        if self.t > 1.4 then
            self:SetScript("OnUpdate", nil)
            self:Hide()
        end
    end)
    if PlaySound then
        local kit = (SOUNDKIT and SOUNDKIT.UI_DIG_SITE_COMPLETION_TOAST) or 38326
        pcall(PlaySound, kit, "Master")
    end
end

-- The chips under a battler's name: its type, its status (with the turns left), every stat change and a flask,
-- each with a tooltip. Stat changes last until the beast is switched out, like the games.
local Chips = {
    STATUS_TIP = {
        brn = "Loses 1/8 of its max HP each turn, and its Attack is halved.",
        psn = "Loses 1/8 of its max HP each turn.",
        par = "Its Speed is quartered, and 1 turn in 4 it can't move.",
        slp = "It can't move until it wakes up.",
    },
    ORDER = { "atk", "def", "spa", "spd", "spe" },
}

function Chips.List(s)
    local out = {}
    local sp = s.sp and D.species[s.sp]
    if sp then
        local t = D.types[sp.type]
        out[#out + 1] = { text = t.name:upper(), color = t.color, title = t.name .. " type", lines = KH.Matchups(sp.type) }
    end
    if s.status and D.status[s.status] then
        local st = D.status[s.status]
        local text, lines = st.short, { Chips.STATUS_TIP[s.status] }
        if s.status == "slp" and s.sleep then
            text = text .. " " .. s.sleep
            lines[#lines + 1] = string.format("Wakes up within %d %s.", s.sleep, s.sleep == 1 and "turn" or "turns")
        end
        out[#out + 1] = { text = text, color = st.color, title = st.name:gsub("^%l", string.upper), lines = lines }
    end
    for _, stat in ipairs(Chips.ORDER) do
        local v = s.stages and s.stages[stat]
        if v and v ~= 0 then
            local mult = (v >= 0) and (2 + v) / 2 or 2 / (2 - v)
            out[#out + 1] = { text = string.format("%s %s%d", Scr.STAT_SHORT[stat], v > 0 and "+" or "", v),
                color = v > 0 and { 0.25, 0.62, 0.32 } or { 0.80, 0.30, 0.26 },
                title = string.format("%s %s %d %s", D.statNames[stat], v > 0 and "raised" or "lowered", math.abs(v),
                    math.abs(v) == 1 and "stage" or "stages"),
                lines = { string.format("x%.2f until it is switched out.", mult) } }
        end
    end
    -- 0.37: timed marks (bleed, chill, ...), a guard, a cast being readied
    if s.marks then
        local ids = {}
        for id in pairs(s.marks) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local mk, n = D.MARKS[id], s.marks[id]
            if mk then
                out[#out + 1] = { text = mk.short .. " " .. n, color = mk.color, title = mk.name,
                    lines = { mk.desc, string.format("%d more %s.", n, n == 1 and "turn" or "turns") } }
            end
        end
    end
    if s.guard then
        out[#out + 1] = { text = "GUARD " .. s.guard, color = { 0.42, 0.52, 0.78 }, title = "Guarding",
            lines = { "Takes a quarter of the damage.", string.format("%d more %s.", s.guard, s.guard == 1 and "turn" or "turns") } }
    end
    if s.flask and D.items[s.flask.id] then
        local def = D.items[s.flask.id]
        out[#out + 1] = { text = "FLASK " .. s.flask.n, color = { 0.55, 0.38, 0.78 }, title = def.name,
            lines = { def.desc, string.format("%d %s left, this one included.", s.flask.n, s.flask.n == 1 and "battle" or "battles") } }
    end
    return out
end

function Chips.Tooltip(self)
    local c = self.chip
    if not (c and GameTooltip) then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(c.title or c.text, ns.Style:Color("GOLD"))
    for _, line in ipairs(c.lines or {}) do GameTooltip:AddLine(line, 1, 1, 1, true) end
    GameTooltip:Show()
end

-- Lays the chips out left to right in the box's chip row; what doesn't fit becomes "+n" (its tooltip lists them).
function Chips.Width(text) return floor(TextWidth(text, 13 / 1.4) + 14) end

function Chips.Layout(f, list)
    f.chips = f.chips or {}
    local room, total = f.chipRoom, 0
    for i, c in ipairs(list) do total = total + Chips.Width(c.text) + (i > 1 and 4 or 0) end
    if total > room then
        local x, keep = 0, 0
        for i, c in ipairs(list) do
            local more = Chips.Width("+" .. (#list - i)) + 4
            if x + Chips.Width(c.text) + more > room then break end
            x, keep = x + Chips.Width(c.text) + 4, i
        end
        local more = { text = "+" .. (#list - keep), color = { 0.45, 0.47, 0.52 }, title = "More effects", lines = {} }
        for k = keep + 1, #list do more.lines[#more.lines + 1] = list[k].title or list[k].text end
        local cut = {}
        for k = 1, keep do cut[k] = list[k] end
        cut[#cut + 1] = more
        list = cut
    end
    local x = 0
    for i, c in ipairs(list) do
        local p = f.chips[i]
        if not p then
            p = Pill(f, 40, 16, 13)
            p:EnableMouse(true)
            p:SetScript("OnEnter", Chips.Tooltip)
            p:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
            f.chips[i] = p
        end
        local w = Chips.Width(c.text)
        p:SetWidth(w)
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + x, f.chipY)
        p.chip = c
        p:Set(c.text, c.color)
        x = x + w + 4
    end
    for i = #list + 1, #f.chips do f.chips[i]:Hide() end
    f.chipTexts = {}
    for i, c in ipairs(list) do f.chipTexts[i] = c.text end
end

local function InfoBox(f, side)
    -- the snapshot of the last played event (never the live creature: the engine is ahead of the playback)
    local s = BT.snap and BT.snap[side]
    if not s then f:Hide() return end
    f:Show()
    f.name:SetText(s.name)
    local rare = s.sp and D.species[s.sp] and D.species[s.sp].rare
    if rare then f.name:SetTextColor(0.9, 0.62, 0.05) else f.name:SetTextColor(INK[1], INK[2], INK[3]) end
    f.lvl:SetText("Lv" .. s.lvl)
    f.star:SetShown(s.shiny == true)
    f.name:SetWidth(f:GetWidth() - 32 - 58 - (s.shiny and 18 or 0))    -- never into the level (or the star)
    Chips.Layout(f, Chips.List(s))
    local shownHP = f.animHP or s.hp
    f.hp:SetHP(shownHP / s.max)
    if f.hpText then f.hpText:SetText(string.format("%d / %d", floor(shownHP + 0.5), s.max)) end
    if f.exp then f.exp:Set(f.animExp or s.exp, 0.35, 0.65, 0.95) end
end

-- A cast being readied (0.37): a bar under the foe's box / over yours, gold, or grey when it can't be interrupted.
function Scr.CastBar(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(280, 22)
    f.bg = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.09, 0.09, 0.12, 0.92)
    f.edge = f:CreateTexture(nil, "BACKGROUND", nil, -8)          -- (under the dark bar: only its 2 px rim shows)
    f.edge:SetPoint("TOPLEFT", -2, 2)
    f.edge:SetPoint("BOTTOMRIGHT", 2, -2)
    f.edge:SetColorTexture(0.79, 0.71, 0.54, 1)
    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetPoint("TOPLEFT")
    f.fill:SetPoint("BOTTOMLEFT")
    f.fill:SetWidth(140)
    f.name = Font(f, 13, "OVERLAY", true)
    f.name:SetPoint("LEFT", 8, 0)
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)
    f.name:SetTextColor(1, 1, 1)
    f.note = Font(f, 11, "OVERLAY")
    f.note:SetPoint("RIGHT", -12, 0)
    f.note:SetTextColor(0.92, 0.92, 0.95)
    f:Hide()
    return f
end

function Scr.SetCastBar(f, c)
    if not c then
        f:Hide()
        if f.restore then f.restore() end           -- (cracked by an interrupt: back in place for the next cast)
        return
    end
    f:Show()
    f.name:SetText(c.name)
    if c.unstoppable then
        f.fill:SetColorTexture(0.42, 0.45, 0.53, 1)
        f.edge:SetColorTexture(0.62, 0.65, 0.72, 1)
        f.note:SetText("can't interrupt")
    else
        f.fill:SetColorTexture(0.84, 0.55, 0.14, 1)
        f.edge:SetColorTexture(0.79, 0.71, 0.54, 1)
        f.note:SetText("lands next turn")
    end
    -- the bar grows to fit the name and the note (280 to 340); past that the name ends in "...": they never meet
    f.name:SetWidth(0)
    local noteW = f.note:GetStringWidth()
    f:SetWidth(min(340, max(280, f.name:GetStringWidth() + noteW + 40)))
    f.name:SetWidth(f:GetWidth() - 28 - noteW)
end

local function RefreshBattleBoxes()
    InfoBox(R.foeBox, "foe")
    InfoBox(R.allyBox, "ally")
    if R.foeCast then
        Scr.SetCastBar(R.foeCast, BT.snap and BT.snap.foe and BT.snap.foe.cast)
        Scr.SetCastBar(R.allyCast, BT.snap and BT.snap.ally and BT.snap.ally.cast)
    end
end

-- The coach (0.37): the simple rule list's pick for your beast and why, while it is on (until your first badge,
-- unless set: /dz azeromon coach on | off | auto).
function Scr.CoachOn()
    local d = G:Data()
    if d.coach ~= nil then return d.coach and true or false end
    return G:BadgeCount() == 0
end

function Scr.Coach(b)
    if not (b and b.ally and Scr.CoachOn()) or b.ally.cast then return nil end
    local usable = {}
    for i in ipairs(b.ally.mon.moves) do if b:Usable("ally", i) then usable[#usable + 1] = i end end
    if #usable == 0 then return nil end
    local i = b:Rotation("ally", usable)
    local md = D.moves[b.ally.mon.moves[i].id]
    local op = b.foe
    local why
    if op.cast and (md.interrupt or md.guard) then
        why = md.interrupt and "Break the cast before it lands!" or "Guard now: the cast lands next."
    elseif md.payoff and b:PayoffActive("ally", md) then
        local pm = md.payoff.mark and D.MARKS[md.payoff.mark]
        why = string.format("Combo now! %s is up: x%s.", pm and pm.short or "It", tostring(md.payoff.mult))
    elseif md.role == "setup" then
        local feeds
        for _, m in ipairs(b.ally.mon.moves) do
            local pd = D.moves[m.id]
            if pd and pd.payoff and md.mark and pd.payoff.mark == md.mark.id then feeds = pd break end
        end
        why = feeds and string.format("Set up the combo for %s.", feeds.name) or "Set up the combo."
    elseif md.heal then why = "Heal up while you can."
    elseif md.cast then why = "Cast it now: it lands next turn."
    else why = "Best hit right now." end
    return i, why
end

Scr.ROLE = {
    filler = { "FILLER", { 0.52, 0.55, 0.64 } }, setup = { "SETUP", { 0.27, 0.60, 0.78 } },
    payoff = { "PAYOFF", { 0.80, 0.58, 0.16 } }, nuke = { "CAST", { 0.86, 0.44, 0.18 } },
    guard = { "GUARD", { 0.44, 0.54, 0.80 } }, interrupt = { "INTERRUPT", { 0.80, 0.30, 0.28 } },
    heal = { "HEAL", { 0.30, 0.62, 0.30 } }, buff = { "BUFF", { 0.62, 0.42, 0.78 } },
}

-- One short line on what a move does (the move box's last line when the coach has nothing to say about it).
function Scr.MoveNote(md)
    if md.cast then return md.unstoppable and "Can't be interrupted" or "Lands next turn" end
    if md.guard then return string.format("Soaks %d%% for %d turns", floor((1 - md.guard) * 100 + 0.5), md.guardTurns or 1) end
    if md.interrupt then return "First. Breaks a cast" end
    if md.heal then return string.format("Heals %d%%%s", floor(md.heal * 100 + 0.5), md.mark and " + Regrowth" or "") end
    if md.payoff then
        local mk = md.payoff.mark and D.MARKS[md.payoff.mark]
        return string.format("x%s on %s%s", tostring(md.payoff.mult), mk and mk.short or "status", md.payoff.consume and ", uses it" or "")
    end
    if md.mark and D.MARKS[md.mark.id] then
        return string.format("%s %s for %d turns", md.mark.who == "self" and "Self:" or "Leaves", D.MARKS[md.mark.id].short, md.mark.turns)
    end
    local e = md.effect
    if e and e.kind == "stat" then
        return string.format("%s %s", e.stages > 0 and "Raises" or "Lowers", D.statNames[e.stat] or e.stat)
    end
    if (md.cd or 0) == 0 and md.role then return "No cooldown" end
    return ""
end

local function BattleModelFor(side) return side == "foe" and R.foeModel or R.allyModel end

local function OpenFightMenu()
    local b = G.battle
    local mon = b.ally.mon
    local items = {}
    local coachSlot, coachWhy = Scr.Coach(b)
    local colW = (SW - 200 - 24) / 2
    BT.lastRest = BT.lastRest or setmetatable({}, { __mode = "k" })
    local last = BT.lastRest[mon] or {}
    local ready = {}                                    -- rested last time, ready again now: those rows glint
    for i = 1, 4 do
        local mv = mon.moves[i]
        if mv then
            local md = D.moves[mv.id]
            -- one thing on the right, never two: a resting move's hourglass and pips, or COMBO when its mark is up
            local rest = b.ally.cd and b.ally.cd[i] or 0
            if (last[i] or 0) > 0 and rest == 0 then ready[i] = true end
            last[i] = rest
            local right, rightColor, mark
            if rest > 0 then mark = { total = max(md.cd or 0, rest), left = rest }
            elseif b.PayoffActive and b:PayoffActive("ally", md) then right, rightColor = "COMBO", { 0.80, 0.55, 0.04 } end
            items[i] = { text = md.name, move = mv, right = right, rightColor = rightColor, disabled = rest > 0 or nil,
                rest = rest, mark = mark, why = (i == coachSlot) and coachWhy or nil, onSelect = function(idx, menu)
                if mv.pp <= 0 then
                    Message("There's no PP left for this move!")
                    return
                end
                PopMenu(menu)
                R.moveInfo:Hide()
                BT.lastMove[mon] = idx
                UI:BattleAct({ kind = "move", idx = idx })
            end }
            Scr.FitMoveRow(items[i], colW)
        else
            items[i] = { text = "-", disabled = true }
        end
    end
    BT.lastRest[mon] = last
    local info = R.moveInfo
    -- the move list replaces FIGHT / BAG / PARTY / RUN (which comes back on cancel)
    local actionMenu = stack[#stack]
    if actionMenu then actionMenu.frame:Hide() end
    R.textbox:Hide()
    local last = BT.lastMove[mon]
    -- the cursor starts on the coach's pick, else the last move (if it is not resting), else the first ready one
    local cursor = coachSlot
    if not cursor and last and mon.moves[last] and not items[last].disabled then cursor = last end
    if not cursor then
        for i = 1, 4 do if items[i] and items[i].move and not items[i].disabled then cursor = i break end end
    end
    local fight = PushMenu(items, { anchor = { "BOTTOMLEFT", screen, "BOTTOMLEFT", 0, 0 }, w = SW - 200, h = BOX_H, rowH = 31,
        cols = 2, level = 70, cursor = cursor or 1, onCancel = function(menu)
            PopMenu(menu)
            info:Hide()
            if actionMenu then actionMenu.frame:Show() end
            R.textbox:Show()
        end,
        onPop = function() Scr.FightDeco(nil) end,
        onMove = function(i, menu)
            local it = menu.items[i]
            local mv = it.move
            -- the battle text box stays up (UpdateText shows it every frame) and spans the whole bottom: keep
            -- the info window over it and the move list, whatever level the screen sits at
            local lvl = max(R.textbox:GetFrameLevel(), menu.frame:GetFrameLevel()) + 5
            info:SetFrameLevel(lvl)
            info.type:SetFrameLevel(lvl + 1)
            info.role:SetFrameLevel(lvl + 1)
            info:Show()
            if mv then
                local md = D.moves[mv.id]
                local frac = mv.pp / md.pp
                info.pp:SetText(string.format("PP  %d/%d", mv.pp, md.pp))
                if frac <= 0.25 then info.pp:SetTextColor(0.86, 0.25, 0.2)
                elseif frac <= 0.5 then info.pp:SetTextColor(0.9, 0.55, 0.1)
                else info.pp:SetTextColor(INK[1], INK[2], INK[3]) end
                -- (each item has its own place: PP | its rest on top, type + role pills, power, effect; what it does
                -- is the line under the moves)
                info.glass:SetFrameLevel(lvl + 1)
                if (it.rest or 0) > 0 then
                    info.glass:Hide()
                    info.cd:SetText(string.format("Ready in %d", it.rest))
                    info.cd:SetTextColor(0.86, 0.45, 0.12)
                else
                    info.glass:SetShown((md.cd or 0) > 0)
                    info.cd:SetText((md.cd or 0) > 0 and tostring(md.cd) or "")
                    info.cd:SetTextColor(0.29, 0.33, 0.45)
                end
                info.type:Set(D.types[md.type].name:upper(), D.types[md.type].color)
                local role = md.role and Scr.ROLE[md.role]
                if role then info.role:Set(role[1], role[2]) info.role:Show() else info.role:Hide() end
                local combo = G.battle.PayoffActive and G.battle:PayoffActive("ally", md)
                local pw = md.power
                if combo and pw > 0 then pw = floor(pw * md.payoff.mult) end
                info.power:SetText(md.power > 0 and ("Power " .. pw .. (combo and "  COMBO" or "")) or "Status move")
                local foe = G.battle and G.battle.foe.mon
                local txt, col = KH.EffectText(md, foe and D.species[foe.sp].type)
                info.eff:SetText(txt)
                info.eff:SetTextColor(col[1], col[2], col[3])
            else
                info.pp:SetText("") info.type:Hide() info.role:Hide() info.power:SetText("") info.cd:SetText("")
                info.glass:Hide() info.eff:SetText("")
            end
            Scr.MoveStrip(menu, it, mon)
        end })
    Scr.FightMarks(fight, ready)
end

local function OpenActionMenu()
    local b = G.battle
    -- kept: after a message during the choice it comes back (UpdateBattle)
    BT.prompt = string.format("What will\n%s do?", M.Name(b.ally.mon))
    local odds = ns.AzeroTaming.PromptLine(b, G.save.bag)         -- a wild beast: your best rod's odds this turn
    if odds then BT.prompt = BT.prompt .. "\n" .. odds end
    BT.actionOpen = true
    SetText(BT.prompt, { lines = 3 })
    text.shown = 999
    local items = {
        { text = "FIGHT", onSelect = function()
            local mon = G.battle.ally.mon
            if not G.battle:HasPP(mon) then                 -- nothing left: it struggles, like the games
                Message(M.Name(mon) .. " has no moves left!", function() UI:BattleAct({ kind = "move", idx = 1 }) end)
                return
            end
            OpenFightMenu()
        end },
        { text = "BAG", onSelect = function()
            if b.pvp then Message("Items can't be used in a battle between players.") return end
            OpenBag("battle", function(id, bagMenu)
                local def = D.items[id]
                local function act(target)
                    CloseAllMenus()
                    R.bagDesc:Hide()
                    UI:BattleAct({ kind = "item", item = id, target = target })
                end
                if def.use == "charm" or def.use == "gear" or def.use == "flask" or def.use == "material"
                    or def.use == "evolve" or def.use == "tool" or def.use == "junk" or def.use == "lure" then
                    Message("Now is not the time to use that!")
                elseif def.use == "boost" then
                    local st = b.ally.stages[def.stat] or 0
                    if st >= 6 then Message("It won't have any effect.") else act(nil) end
                elseif def.use == "ball" then
                    act(nil)
                else
                    OpenParty("item", function(idx, partyMenu)
                        if partyMenu then PopMenu(partyMenu) end
                        if not idx then return end
                        local mon = G.save.party[idx]
                        local useless = mon.hp <= 0 or (def.use == "heal" and mon.hp >= M.MaxHP(mon))
                            or (def.use == "cure" and mon.status ~= def.cures)
                            or (def.use == "rejuv" and mon.hp >= M.MaxHP(mon) and not mon.status)
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
    -- the cursor comes back to the last choice of this battle (FIGHT, BAG, ...)
    for i, it in ipairs(items) do
        local pick = it.onSelect
        it.onSelect = function(idx, menu)
            BT.lastAction = i
            return pick(idx, menu)
        end
    end
    BT.actionMenu = PushMenu(items, { anchor = { "BOTTOMRIGHT", screen, "BOTTOMRIGHT", 0, 0 }, w = 230, h = BOX_H,
        rowH = 38, cols = 2, level = 70, cursor = BT.lastAction or 1, onCancel = function() end })
end

-- Closes the FIGHT / BAG / PARTY / RUN menus and whatever was opened from them.
local function CloseActionMenus()
    BT.actionOpen = nil
    CloseAllMenus()
    R.moveInfo:Hide()
    R.bagDesc:Hide()
end

function UI:BattleAct(action)
    local b = G.battle
    if not b then return end
    -- only while the battle waits for this choice (a PvP turn that ran out has already forfeited)
    if b.need ~= "action" then CloseActionMenus() return end
    CloseActionMenus()
    if b.ally.cast and action.kind ~= "forfeit" then action = { kind = "release" } end
    ClearText()
    if not b:Act(action) then
        Message("It won't have any effect.", function() BT.needShown = nil end)
    end
    BT.needShown = nil
end

local function OpenLearnMenu()
    local b = G.battle
    local q = b.learning
    Scr.PushForgetMenu(q.mon, q.move, function(slot)
        b:ResolveLearn(slot)
        BT.needShown = nil
    end)
end

local BATTLE_THEMES = {
    arena = { sky = { 0.93, 0.86, 0.70 }, bands = { { 0.96, 0.90, 0.76 }, { 0.94, 0.88, 0.72 } },
              field = { 0.86, 0.76, 0.55 }, stripe = { 0.78, 0.67, 0.46 }, lines = { 0.82, 0.72, 0.50 },
              platform = PLATFORM .. "_w" },
    elwynn = { sky = { 0.86, 0.94, 0.90 }, bands = { { 0.95, 0.98, 0.93 }, { 0.91, 0.96, 0.92 } },
               field = { 0.80, 0.91, 0.66 }, stripe = { 0.70, 0.85, 0.60 }, lines = { 0.74, 0.87, 0.60 },
               platform = PLATFORM },
    -- Westfall: pale dusty sky over dry golden fields
    westfall = { sky = { 0.97, 0.92, 0.80 }, bands = { { 0.99, 0.97, 0.90 }, { 0.98, 0.94, 0.85 } },
                 field = { 0.91, 0.82, 0.56 }, stripe = { 0.80, 0.68, 0.40 }, lines = { 0.86, 0.75, 0.48 },
                 platform = PLATFORM .. "_w" },
    -- the Deadmines: rock walls above a dusty mine floor
    mine = { sky = { 0.22, 0.19, 0.18 }, bands = { { 0.17, 0.15, 0.14 }, { 0.20, 0.17, 0.16 } },
             field = { 0.36, 0.29, 0.23 }, stripe = { 0.26, 0.21, 0.17 }, lines = { 0.31, 0.25, 0.20 },
             platform = PLATFORM .. "_m" },
    -- Duskwood: a violet dusk over dark moss
    duskwood = { sky = { 0.36, 0.34, 0.48 }, bands = { { 0.30, 0.28, 0.42 }, { 0.33, 0.31, 0.45 } },
                 field = { 0.26, 0.34, 0.30 }, stripe = { 0.20, 0.27, 0.24 }, lines = { 0.23, 0.30, 0.27 },
                 platform = PLATFORM .. "_d" },
    -- Stranglethorn: a hazy tropical sky over the jungle floor
    jungle = { sky = { 0.78, 0.90, 0.92 }, bands = { { 0.88, 0.95, 0.94 }, { 0.83, 0.93, 0.93 } },
               field = { 0.36, 0.60, 0.32 }, stripe = { 0.28, 0.48, 0.26 }, lines = { 0.32, 0.54, 0.29 },
               platform = PLATFORM .. "_j" },
}

-- The painted backdrop for the map's scene (Ground.lua AzeroBattleArt; gen_azeromon_ground.py), or the old
-- colour bands when there is none.
local function BattleScene()
    local art = ns.AzeroBattleArt
    if not art then return nil end
    local def = G.map and G.map.def
    local sc = def and (art.scenes[G.map.id] or art.scenes[def.theme or ""])     -- (a map's own scene: the Molten Core)
    if not sc then sc = (def and not def.outdoor) and art.indoor or art.outdoor end
    return sc
end

local function ApplyBattleTheme(name)
    local t = BATTLE_THEMES[name] or BATTLE_THEMES.elwynn
    local bg = R.bg
    local sc = BattleScene()
    local painted = sc ~= nil and bg.art ~= nil
    for _, x in ipairs({ bg.sky, bg.field, bg.stripe }) do x:SetShown(not painted) end
    for _, x in ipairs(bg.skyBands) do x:SetShown(not painted) end
    for _, x in ipairs(bg.fieldBands) do x:SetShown(not painted) end
    for _, x in ipairs(bg.platforms) do x:SetShown(not painted) end
    if bg.art then
        bg.art:SetShown(painted)
        bg.clouds.on = painted and ns.AzeroBattleArt.clouds[sc] or false
        bg.clouds:SetShown(bg.clouds.on)
        if painted then SetPixelTexture(bg.art, MEDIA .. "Ground\\battle_" .. sc) end
    end
    bg.sky:SetColorTexture(t.sky[1], t.sky[2], t.sky[3], 1)
    bg.field:SetColorTexture(t.field[1], t.field[2], t.field[3], 1)
    bg.stripe:SetColorTexture(t.stripe[1], t.stripe[2], t.stripe[3], 1)
    for i, band in ipairs(bg.skyBands) do band:SetColorTexture(t.bands[i][1], t.bands[i][2], t.bands[i][3], 1) end
    for _, band in ipairs(bg.fieldBands) do band:SetColorTexture(t.lines[1], t.lines[2], t.lines[3], 1) end
    for _, p in ipairs(bg.platforms) do SetPixelTexture(p, t.platform) end
end

local function StartBattleView(b)
    ApplyBattleTheme(G.map and G.map.def.theme)
    R.battleSkyAlpha = ApplySky(R.battleSky, G.map and G.map.def.outdoor, 0.75, G.map and G.map.def.gloom)
    -- 0.45: the scene of the spot you stood on, at this hour and in this weather (BattleScene.lua); the old
    -- picture, its colour bands and the flat tint step aside
    local s = G.save
    local how = ns.AzeroBattleScene.Begin(G.map, s and s.x, s and s.y, G.raining)
    if how == "layers" then
        local bg = R.bg
        for _, x in ipairs({ bg.art, bg.clouds, bg.sky, bg.field, bg.stripe }) do if x then x:Hide() end end
        if bg.clouds then bg.clouds.on = false end
        for _, x in ipairs(bg.skyBands) do x:Hide() end
        for _, x in ipairs(bg.fieldBands) do x:Hide() end
        for _, x in ipairs(bg.platforms) do x:Hide() end
        R.battleSky:Hide()
        R.battleSkyAlpha = 0
    end
    local foeSp = b.foe and b.foe.mon and D.species[b.foe.mon.sp]
    if b.wild and foeSp and (foeSp.rare or foeSp.legendary) and PlaySound then pcall(PlaySound, 8959, "Master") end   -- RAID_WARNING
    ns.AzeroSound:Play("encounter")
    -- the battle takes the keys: overworld menus still open (a guildmate's challenge accepted over the start
    -- menu) close, and so do their boxes
    CloseAllMenus()
    R.money:Hide() R.bagDesc:Hide() R.moveCompare:Hide() R.log:Hide()
    BT.battle = b
    BT.anim, BT.needShown, BT.ended, BT.snap, BT.lastNeed, BT.tamed = nil, nil, nil, nil, nil, nil
    ns.AzeroTaming.Reset()
    ns.AzeroTaming.Card(nil)
    ns.AzeroFx.Reset()
    BT.lastAction, BT.actionOpen, BT.prompt = nil, nil, nil
    BT.lastRest = nil                        -- (the moves resting in the last battle: no glint for them here)
    BT.intro = 0.95
    R.battle:Show()
    world:Hide()
    R.foeBox:Hide() R.allyBox:Hide()
    R.foeBox.animHP, R.allyBox.animHP, R.allyBox.animExp = nil, nil, nil
    R.net:Hide()
    R.net:SetVertexColor(1, 1, 1)            -- (greyed by the last catch)
    -- Load and measure both leads right away, invisibly: the fit samples the idle animation for SAMPLE_TIME,
    -- which then happens during the intro text instead of delaying the send-out.
    ShowCreature(R.foeModel, b.foe.mon.sp, -0.7, b.foe.mon.shiny)
    ShowCreature(R.allyModel, b.ally.mon.sp, 0.8, b.ally.mon.shiny)
    R.foeModel:SetAlpha(0) R.allyModel:SetAlpha(0)
end

local function EndBattleView()
    BT.battle, BT.actionOpen = nil, nil
    ns.AzeroTaming.Reset()
    ns.AzeroBattleScene.End()
    ns.AzeroFx.Reset()
    R.bagDesc:SetHeight(80)                  -- (the battle bag's was as tall as the text box)
    R.battle:Hide()
    R.moveInfo:Hide()                        -- (on the screen, not the battle layer)
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
        -- stat changes, sleep turns and flasks change with plain text events too: keep the boxes on screen current
        if R.foeBox:IsShown() then InfoBox(R.foeBox, "foe") end
        if R.allyBox:IsShown() then InfoBox(R.allyBox, "ally") end
        SetText(e.text, { auto = 1.0, onDone = function() BT.anim = nil ClearText() end })
        BT.anim = { waitText = true }
    elseif e.t == "send" then
        local m = BattleModelFor(e.side)
        ns.AzeroSound:Play("sendout")
        ShowCreature(m, e.mon.sp, e.side == "foe" and -0.7 or 0.8, e.mon.shiny)
        local shiny = e.mon.shiny
        m:SetAlpha(0)
        local box = e.side == "foe" and R.foeBox or R.allyBox
        box.animHP, box.animExp = nil, nil
        box.mon = e.mon
        local from = e.side == "foe" and 260 or -260
        -- hold the slide-in until the model has been measured (a creature switched in mid-battle), at most 3 s
        BT.anim = { t = 0, dur = 0.5, hold = function() return Scr.Measuring(m) end, fn = function(f)
            local ease = 1 - (1 - f) * (1 - f)
            m:SetAlpha(min(1, f * 2))
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", R.battle, "TOPLEFT", m.baseX + from * (1 - ease), m.baseY)
            RefreshBattleBoxes()
        end, done = function()
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", R.battle, "TOPLEFT", m.baseX, m.baseY)
            if shiny then Scr.Sparkle(m) end
        end }
    elseif e.t == "recall" then
        local m = BattleModelFor(e.side)
        ns.AzeroSound:Play("recall")
        BT.anim = { t = 0, dur = 0.35, fn = function(f) m:SetAlpha(1 - f) end, done = function() m:Hide() m.sp = nil end }
    elseif e.t == "attack" then
        -- 0.41: the move's own effect (Fx.lua, FxMoves.lua); a move whose type isn't drawn yet keeps the lunge below
        local fxAnim = ns.AzeroFx.Attack(e)
        if fxAnim then
            BT.anim = fxAnim
            return
        end
        local m = BattleModelFor(e.side)
        local other = BattleModelFor(e.side == "ally" and "foe" or "ally")
        local hitSound = e.move and (e.move.power or 0) > 0 and e.move.type
        local physical = e.move and (e.move.power or 0) > 0 and (e.move.type == "NONE" or (D.types[e.move.type] and D.types[e.move.type].physical))
        Anim(m, physical and 16 or 54)
        local x0 = m.baseX
        local dx = e.side == "ally" and 30 or -30
        BT.anim = { t = 0, dur = 0.55, fn = function(f)
            local lunge = f < 0.3 and (f / 0.3) or max(0, 1 - (f - 0.3) / 0.3)
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", R.battle, "TOPLEFT", x0 + dx * lunge, m.baseY + (e.side == "ally" and 10 or -6) * lunge)
            if f > 0.35 then
                other:SetAlpha(floor(f * 16) % 2 == 0 and 0.25 or 1)
                if hitSound then ns.AzeroSound:Play("hit", hitSound) hitSound = nil end
            end
        end, done = function()
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", R.battle, "TOPLEFT", x0, m.baseY)
            other:SetAlpha(1)
            Anim(m, 0)
        end }
    elseif e.t == "hp" then
        if e.to < e.from and e.to > 0 then Anim(BattleModelFor(e.side), 9) end
        local box = e.side == "foe" and R.foeBox or R.allyBox
        local dur = min(1.0, 0.25 + math.abs(e.to - e.from) / e.max * 0.9)
        BT.anim = { t = 0, dur = dur, fn = function(f)
            box.animHP = e.from + (e.to - e.from) * f
            RefreshBattleBoxes()
        end, done = function() box.animHP = nil RefreshBattleBoxes() end }
    elseif e.t == "faint" then
        local m = BattleModelFor(e.side)
        ns.AzeroSound:Play("faint")
        Anim(m, 1)
        BT.anim = { t = 0, dur = 0.7, fn = function(f) m:SetAlpha(1 - f) end,
                    done = function() Anim(m, 0) m:Hide() m.sp = nil m:SetAlpha(1) if e.side == "foe" then R.foeBox:Hide() end end }
    elseif e.t == "status" or e.t == "level" then
        if e.t == "level" then ns.AzeroSound:Play("levelup") end
        R.allyBox.animExp = nil
        RefreshBattleBoxes()
    elseif e.t == "cast" then                          -- 0.37: a cast is announced (its bar shows from the snapshot)
        Anim(BattleModelFor(e.side), 54)
        RefreshBattleBoxes()
        BT.anim = ns.AzeroFx.Windup(e)                 -- 0.41: a beat for its wind-up to begin (it lasts while it waits)
    elseif e.t == "interrupt" then
        Anim(BattleModelFor(e.side), 9)
        RefreshBattleBoxes()
        BT.anim = ns.AzeroFx.Break(e)                  -- 0.42: what it gathered shatters, its cast bar cracks
    elseif e.t == "castend" or e.t == "mark" or e.t == "guard" or e.t == "unstoppable" or e.t == "combo" then
        RefreshBattleBoxes()
        -- 0.41: a guard's shell forms; a mark landing pops in its colours (both then stay while the snapshot has them)
        -- 0.42: an interrupt bounces off a cast that can't be interrupted (its iron chain flares)
        if e.t == "guard" then BT.anim = ns.AzeroFx.Guard(e)
        elseif e.t == "mark" then BT.anim = ns.AzeroFx.Mark(e)
        elseif e.t == "unstoppable" then BT.anim = ns.AzeroFx.Shrug(e) end
    elseif e.t == "sfx" then
        if not (e.sound == "catch" and ns.AzeroTaming.TakeQuiet()) then ns.AzeroSound:Play(e.sound) end
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
        -- the taming moment (Taming.lua): lure, sigil, orb, one pip per check; then it locks or cracks
        R.net:Hide()
        BT.anim = ns.AzeroTaming.Anim(e, R.battle, R.foeModel, R.allyModel,
            function(name) ns.AzeroSound:Play(name) end, Anim)
    elseif e.t == "tamed" then
        BT.tamed = e                             -- (its card shows once the battle is over)
    elseif e.t == "end" then
        BT.ended = e.result
    end
end

local function UpdateBattle(dt)
    local b = BT.battle
    if not b then return end
    ns.AzeroFx.Frame(dt, BT.snap)            -- 0.41: marks, shells, wind-ups, the effect playing (Fx.lua)
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
    -- the battle stopped waiting for my choice while its menus were open (a PvP turn ran out and forfeited):
    -- they close, so nothing picked from them reaches a battle that has moved on
    if BT.actionOpen and b.need ~= "action" then CloseActionMenus() end
    local a = BT.anim
    if a then
        if a.waitText then UpdateText(dt) return end
        if a.hold and a.hold() and (a.held or 0) < 4 + SAMPLE_TIME + 0.4 then
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
    if e then
        PlayEvent(e)
        if b.need == "watch" then BT.needShown = nil end      -- show "waiting" again once this turn has played
        return
    end
    UpdateText(dt)
    -- a player battle goes action -> wait -> action by itself (the opponent's move arrives): re-prompt
    if b.need ~= BT.lastNeed then
        BT.lastNeed = b.need
        BT.needShown = nil
    end
    -- a message during the choice took "What will X do?" with it: back once FIGHT / BAG / PARTY / RUN is on top
    if BT.actionOpen and b.need == "action" and not text.full and BT.prompt and stack[#stack] == BT.actionMenu then
        SetText(BT.prompt, { lines = 3 })
        text.shown = 999
    end
    if BT.needShown then return end
    if b.need == "wait" then
        BT.needShown = true
        SetText(string.format("Waiting for %s...", b.pvp and b.pvp.name or "the other player"), { lines = 3 })
        text.shown = 999
    elseif b.need == "watch" then
        BT.needShown = true
        RefreshBattleBoxes()
        SetText(string.format("Waiting for %s and %s...", b.pvp.watch.ally, b.pvp.watch.foe), { lines = 3 })
        text.shown = 999
    elseif b.need == "action" then
        BT.needShown = true
        RefreshBattleBoxes()
        if b.ally.cast then
            UI:BattleAct({ kind = "release" })      -- committed: the cast it announced lands now
        else
            OpenActionMenu()
        end
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
        local tamed = BT.tamed
        BT.tamed = nil
        if result == "caught" and tamed then             -- the tamed card, until A
            ns.AzeroTaming.Card(tamed)
            Message(ns.AzeroTaming.CardLine(tamed), function()
                ns.AzeroTaming.Card(nil)
                EndBattleView()
                G:Advance(result)
            end)
            return
        end
        EndBattleView()
        G:Advance(result)
    end
end

---------------------------------------------------------------------------
-- Overworld rendering
---------------------------------------------------------------------------

local grid = {}            -- [i][j] = { base, over }
local sprites = {}         -- pool for NPCs
local torchFrame = "torch1"
local groundTex = {}       -- the baked ground's chunks on screen (Ground.lua; at most four are ever in view)

-- A map with a baked ground (gen_azeromon_ground.py) shows that picture instead of its base tiles: soft paths and
-- shores, grass patches, flowers, the forest wall and the shadows of every static sprite. The picture reaches g.mx,
-- g.my tiles past the map's edges (a road carries on into the forest); it is cut into chunks of 256 px, each one in
-- view gets a texture, placed like a tile. Returns the map's ground entry, if it has one.
-- Screen position (from the world's top-left) of a pixel of the baked picture:
local function PicToScreen(g, x, y, px, py)
    return ((x - g.mx * 16) / 16 - px + HX) * TILE, ((y - g.my * 16) / 16 - py + HY) * TILE
end

local function DrawGround(m, px, py)
    local g = ns.AzeroGround and ns.AzeroGround[m.id]
    local n = 0
    if g then
        local S = TILE / 16
        local eve = (g.indoor and G:Period() ~= "day") and "e_" or ""
        for _, c in ipairs(g.chunks) do
            local x0, y0, w, h, tw, th = c[1], c[2], c[3], c[4], c[5], c[6]
            local sx, sy = PicToScreen(g, x0, y0, px, py)
            if sx < SW and sy < SH and sx + w * S > 0 and sy + h * S > 0 then
                n = n + 1
                local t = groundTex[n]
                if not t then
                    t = Tex(world, "BACKGROUND", 1)
                    groundTex[n] = t
                end
                local file = MEDIA .. "Ground\\" .. m.id .. "_" .. eve .. floor(x0 / 256) .. "_" .. floor(y0 / 256)
                if t.file ~= file then
                    t.file = file
                    SetPixelTexture(t, file)
                    t:SetTexCoord(0, w / tw, 0, h / th)
                    t:SetSize(w * S, h * S)
                end
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", world, "TOPLEFT", sx, -sy)
                t:Show()
            end
        end
    end
    for i = n + 1, #groundTex do groundTex[i]:Hide() end
    return g
end

-- Life on a map with a baked ground: the ponds' moving water (Ground.lua's strips, WATER_FRAMES frames), cloud
-- shadows drifting over everything by day, butterflies, a passing flock with its shadow on the ground, and smoke
-- from the chimneys. Positions are in map pixels (16 per tile) and drawn in game pixels (TILE / 16 screen px each).
local Amb = { WATER_FPS = 4, WATER_FRAMES = 12, waterTex = {}, windTex = {}, lightTex = {}, glowTex = {},
              pix = {}, pixN = 0 }   -- pix: pooled one-colour squares (critters, smoke, pollen)
-- each zone's mood: a warm or cold tint over everything (multiplied), the soft dark frame, motes in the air
Amb.MOODS = {
    elwynn = { tint = { 1, 0.95, 0.86 }, motes = { 1, 0.96, 0.75 }, duskMotes = { 1, 0.81, 0.47 }, rain = true },
    westfall = { tint = { 1, 0.95, 0.84 }, motes = { 0.96, 0.88, 0.62 }, duskMotes = { 1, 0.78, 0.44 }, rain = true },
    duskwood = { tint = { 0.86, 0.9, 1 }, mist = true, leaves = true, rain = true },
    jungle = { tint = { 0.92, 1, 0.94 }, motes = { 0.9, 1, 0.7 }, shafts = true, fireflies = true, rain = true },
    mine = { tint = { 0.94, 0.88, 0.82 }, motes = { 0.8, 0.74, 0.62 }, duskMotes = { 0.8, 0.74, 0.62 } },
    arena = { tint = { 1, 0.94, 0.84 }, motes = { 0.96, 0.86, 0.66 }, duskMotes = { 1, 0.78, 0.44 } },
    -- Blackrock: Redridge's warm autumn with falling leaves (their colours), the Steppes' red-ash grade with ash
    -- falling and embers rising off the lava, the Gorge's warm dust, the mountain's caves with embers
    redridge = { tint = { 1, 0.93, 0.84 }, motes = { 1, 0.86, 0.6 }, duskMotes = { 1, 0.74, 0.42 }, rain = true,
                 leaves = { { 0.86, 0.42, 0.16 }, { 0.74, 0.24, 0.12 }, { 0.94, 0.66, 0.22 } } },
    steppes = { tint = { 1, 0.84, 0.76 }, ash = true, embers = true },
    gorge = { tint = { 1, 0.9, 0.78 }, motes = { 0.96, 0.74, 0.5 }, duskMotes = { 1, 0.66, 0.36 }, embers = true },
    blackrock = { tint = { 1, 0.88, 0.8 }, embers = true, motes = { 0.7, 0.5, 0.4 }, duskMotes = { 0.7, 0.5, 0.4 } },
}
Amb.GLINT = { elwynn = { 0.82, 0.92, 1 }, westfall = { 0.84, 0.94, 1 }, duskwood = { 0.5, 0.6, 0.76 },
              jungle = { 0.7, 0.96, 0.96 }, mine = { 0.36, 0.46, 0.56 }, arena = { 0.84, 0.94, 1 },
              redridge = { 0.84, 0.92, 1 }, steppes = { 1, 0.86, 0.5 }, gorge = { 1, 0.86, 0.5 }, blackrock = { 1, 0.86, 0.5 } }
Amb.parts = {}        -- footstep dust and leaves: { kind, x, y, t0, seed } in map pixels
Amb.GLOW = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
-- stamps with chimneys: where each chimney's top is (px in the stamp); the Lion's Pride has two
Amb.CHIMNEY_KINDS = { house = { { 16, 13 } }, darkhouse = { { 16, 13 } }, farmhouse = { { 16, 13 } },
                      stonehouse = { { 16, 13 } }, rrhouse = { { 16, 13 } }, cottage = { { 16, 13 } },
                      smithy = { { 16, 13 } }, stable = { { 16, 13 } }, inn = { { 16, 27 }, { 80, 27 } } }
Amb.CRITTERS = {                -- butterfly wing colours and the flock's colours, per map theme
    elwynn = { wings = { { 1, 1, 1 }, { 0.96, 0.89, 0.48 }, { 0.62, 0.83, 1 } }, flies = 4,
               bird = { 0.17, 0.16, 0.19 }, bird2 = { 0.17, 0.16, 0.19 } },
    duskwood = { wings = { { 0.79, 0.76, 0.91 } }, flies = 1, bird = { 0.08, 0.07, 0.11 }, bird2 = { 0.08, 0.07, 0.11 },
                 nightFlock = true },
    jungle = { wings = { { 0.95, 0.82, 0.29 }, { 0.35, 0.82, 0.91 } }, flies = 4,
               bird = { 0.85, 0.21, 0.18 }, bird2 = { 0.18, 0.6, 0.28 } },
    westfall = { wings = { { 0.96, 0.89, 0.48 }, { 1, 1, 1 } }, flies = 3, bird = { 0.12, 0.1, 0.12 },
                 bird2 = { 0.12, 0.1, 0.12 } },
    arena = { wings = {}, flies = 0, bird = { 0.3, 0.24, 0.2 }, bird2 = { 0.3, 0.24, 0.2 } },     -- vultures
    redridge = { wings = { { 0.96, 0.62, 0.26 }, { 1, 1, 1 } }, flies = 3, bird = { 0.14, 0.12, 0.12 },
                 bird2 = { 0.14, 0.12, 0.12 } },
    steppes = { wings = {}, flies = 0, bird = { 0.1, 0.08, 0.08 }, bird2 = { 0.1, 0.08, 0.08 } },          -- crows in the ash
    gorge = { wings = {}, flies = 0, bird = { 0.3, 0.22, 0.18 }, bird2 = { 0.3, 0.22, 0.18 } },           -- buzzards
}

function Amb.Water(m, g, px, py)
    local n = 0
    if g and g.water then
        local S = TILE / 16
        local f = G:Data().calm and 0 or floor(now * Amb.WATER_FPS) % Amb.WATER_FRAMES
        for i, wv in ipairs(g.water) do
            local x0, y0, w, h, cols, tw, th = wv[1], wv[2], wv[3], wv[4], wv[5], wv[7], wv[8]
            local sx, sy = PicToScreen(g, x0, y0, px, py)
            if sx < SW and sy < SH and sx + w * S > 0 and sy + h * S > 0 then
                n = n + 1
                local t = Amb.waterTex[n]
                if not t then
                    t = Tex(world, "BACKGROUND", 2)
                    Amb.waterTex[n] = t
                end
                local file = MEDIA .. "Ground\\" .. m.id .. "_w" .. i
                if t.file ~= file then
                    t.file = file
                    SetPixelTexture(t, file)
                    t:SetSize(w * S, h * S)
                end
                local c, r = f % cols, floor(f / cols)
                t:SetTexCoord(c * w / tw, (c + 1) * w / tw, r * h / th, (r + 1) * h / th)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", world, "TOPLEFT", sx, -sy)
                t:Show()
            end
        end
    end
    for i = n + 1, #Amb.waterTex do Amb.waterTex[i]:Hide() end
end

-- Looping animations baked as strips (Ground.lua anims: a hearth's flames), and an interior's sunlight: the light
-- through its windows added over everything by day, so it falls on the furniture and the people too.
Amb.animTex = {}
function Amb.Anims(m, g, px, py)
    local n = 0
    if g and g.anims then
        local S = TILE / 16
        for i, a in ipairs(g.anims) do
            local x0, y0, w, h, cols, tw, th, frames, fps = a[1], a[2], a[3], a[4], a[5], a[7], a[8], a[9], a[10]
            local sx, sy = PicToScreen(g, x0, y0, px, py)
            if sx < SW and sy < SH and sx + w * S > 0 and sy + h * S > 0 then
                n = n + 1
                local t = Amb.animTex[n]
                if not t then
                    t = Tex(world, "BACKGROUND", 2)
                    Amb.animTex[n] = t
                end
                local file = MEDIA .. "Ground\\" .. m.id .. "_f"
                if t.file ~= file then
                    t.file = file
                    SetPixelTexture(t, file)
                    t:SetSize(w * S, h * S)
                end
                local f = G:Data().calm and 0 or floor(now * fps + i * 3) % frames
                local c, r = f % cols, floor(f / cols)
                t:SetTexCoord(c * w / tw, (c + 1) * w / tw, r * h / th, (r + 1) * h / th)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", world, "TOPLEFT", sx, -sy)
                t:Show()
            end
        end
    end
    for i = n + 1, #Amb.animTex do Amb.animTex[i]:Hide() end
end

function Amb.Sun(m, g, px, py, period)
    local t = R.sun
    local s = g and g.indoor and period == "day" and g.sunlight and g.sunlight[1]
    if not s then t:Hide() return end
    local file = MEDIA .. "Ground\\" .. m.id .. "_s"
    if t.file ~= file then
        t.file = file
        SetPixelTexture(t, file)
        pcall(t.SetBlendMode, t, "ADD")
        t:SetTexCoord(0, s[1] / s[3], 0, s[2] / s[4])
        t:SetSize(s[1] * TILE / 16, s[2] * TILE / 16)
    end
    local sx, sy = PicToScreen(g, s[5] or 0, s[6] or 0, px, py)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", world, "TOPLEFT", sx, -sy)
    t:Show()
end

-- a square of w x h game pixels at map pixel (mx, my)
function Amb.Pix(px, py, mx, my, w, h, r, g, b, a, layer, sub)
    Amb.pixN = Amb.pixN + 1
    local t = Amb.pix[Amb.pixN]
    if not t then
        t = world:CreateTexture(nil, "ARTWORK", nil, 4)
        Amb.pix[Amb.pixN] = t
    end
    local S = TILE / 16
    t:SetDrawLayer(layer or "ARTWORK", sub or 4)
    t:SetColorTexture(r, g, b, a or 1)
    t:SetSize(w * S, h * S)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", world, "TOPLEFT", (floor(mx) / 16 - px + HX) * TILE, -(floor(my) / 16 - py + HY) * TILE)
    t:Show()
end

function Amb.Critters(m, px, py, period)
    local c = Amb.CRITTERS[m.def.theme or "elwynn"]
    if not c then return end
    if Amb.raining then period = "night" end           -- (nothing flies in the rain)
    local W, H, t = m.w * 16, m.h * 16, now
    local sin = math.sin
    if period ~= "night" then
        for k = 0, c.flies - 1 do
            local bx = W * (0.5 + 0.38 * sin(t * (0.09 + k * 0.03) + k * 2))
            local by = H * (0.5 + 0.38 * sin(t * (0.11 + k * 0.02) + k * 3.1)) + sin(t * 7 + k) * 2
            local col = c.wings[k % #c.wings + 1]
            Amb.Pix(px, py, bx, by, 1, 1, 0.23, 0.19, 0.14, 1)
            if floor(t * 8 + k) % 2 == 0 then
                for _, d in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 } }) do
                    Amb.Pix(px, py, bx + d[1], by + d[2], 1, 1, col[1], col[2], col[3], 1)
                end
            else
                Amb.Pix(px, py, bx, by - 2, 1, 2, col[1], col[2], col[3], 1)
            end
        end
    end
    -- a flock every 16 s, crossing the map; its shadow far below on the ground (bats at night in Duskwood)
    local p = (t % 16) / 16
    if p < 0.6 and (period ~= "night" or c.nightFlock) then
        local q = p / 0.6
        local x0, y0 = -20 + q * (W + 40), H * 0.15 + q * H * 0.5
        for i, d in ipairs({ { 0, 0 }, { -7, -5 }, { -6, 6 }, { -14, -1 } }) do
            local col = (i % 2 == 0) and c.bird2 or c.bird
            local x, y = x0 + d[1], y0 + d[2]
            Amb.Pix(px, py, x, y, 1, 1, col[1], col[2], col[3], 1, "OVERLAY", 3)
            if floor(t * 6 + d[1]) % 2 == 0 then
                Amb.Pix(px, py, x - 1, y - 1, 1, 1, col[1], col[2], col[3], 1, "OVERLAY", 3)
                Amb.Pix(px, py, x + 1, y - 1, 1, 1, col[1], col[2], col[3], 1, "OVERLAY", 3)
            else
                Amb.Pix(px, py, x - 1, y, 3, 1, col[1], col[2], col[3], 1, "OVERLAY", 3)
            end
            Amb.Pix(px, py, x + 16, y + 38, 3, 1, 0.04, 0.08, 0.08, 0.22, "BORDER", 2)
        end
    end
end

function Amb.Smoke(m, px, py)
    if not m.chimneys then
        m.chimneys = {}
        for _, s in ipairs(m.def.stamps or {}) do
            for _, c in ipairs(Amb.CHIMNEY_KINDS[s.kind] or {}) do
                m.chimneys[#m.chimneys + 1] = { s.x * 16 + c[1], s.y * 16 + c[2], s.inside }
            end
        end
    end
    local sin = math.sin
    local Routine = ns.AzeroRoutine
    for ci, ch in ipairs(m.chimneys) do
        -- a house with a room behind it (the inn, the cottage): thin smoke when empty, thick when full
        local thin = 0
        if ch[3] and Routine then thin = math.max(0, 0.6 - Routine.InsideCount(ch[3]) * 0.1) end
        for k = 0, 6 do
            local age = (now * 0.32 + k / 7) % 1
            -- puffs thin out as they rise (a few skipped, changing six times a second)
            local skip = ((floor(now * 6) * 7 + k * 13 + ci * 31) % 100) / 100 < age * 0.55 + thin
            if not skip then
                local sz = age < 0.3 and 2 or 3
                local gr = (220 - age * 60) / 255
                Amb.Pix(px, py, ch[1] + age * 14 + sin(age * 7 + k) * 2, ch[2] - age * 26, sz, sz, gr, gr, gr + 0.02,
                    0.85 - age * 0.6, "ARTWORK", 5)
            end
        end
    end
end

function Amb.Clouds(m, g, px, py)
    local c = R.clouds
    local a = 0
    if g and m.def.outdoor and not m.def.gloom then a = 0.17 * max(0, 1 - (R.skyAlpha or 0) / 0.3) end
    if Amb.raining then a = a * 1.8 end
    if a <= 0.005 then c:Hide() return end
    if c.ready == nil then
        local ok, loaded = pcall(c.SetTexture, c, MEDIA .. "Ground\\clouds", "REPEAT", "REPEAT", "NEAREST")
        if not ok then loaded = c:SetTexture(MEDIA .. "Ground\\clouds") end
        c.ready = loaded ~= false
    end
    if not c.ready then c:Hide() return end
    local ox, oy = (px - HX) * 16 - now * 7, (py - HY) * 16 - now * 3
    c:SetTexCoord(ox / 256, (ox + VW * 16) / 256, oy / 256, (oy + VH * 16) / 256)
    c:SetAlpha(a)
    c:Show()
end

-- Legs in the grass: whoever stands in a meadow (walking or not) has the meadow's own pixels laid over the lower part
-- of their sprite, cut from the baked meadow (Ground.lua meadows), so only grass covers them, never path or ground.
-- mx, my: the sprite's top-left in map pixels.
function Amb.Legs(sp, m, g, mx, my, px, py)
    local t = sp.legs
    if g and g.meadows then
        local ox, oy = g.mx * 16, g.my * 16
        local x0, y0 = floor(mx + ox + 0.5), floor(my + oy + 0.5) + 9
        local x1, y1 = x0 + 16, y0 + 7
        for i, r in ipairs(g.meadows) do
            local ix0, iy0 = max(x0, r[1]), max(y0, r[2])
            local ix1, iy1 = min(x1, r[1] + r[3]), min(y1, r[2] + r[4])
            if ix1 > ix0 and iy1 > iy0 then
                if not t then
                    t = Tex(world, "ARTWORK", 3)
                    sp.legs = t
                end
                local file = MEDIA .. "Ground\\" .. m.id .. "_m" .. i
                if t.file ~= file then
                    t.file = file
                    SetPixelTexture(t, file)
                end
                local S = TILE / 16
                t:SetTexCoord((ix0 - r[1]) / r[5], (ix1 - r[1]) / r[5], (iy0 - r[2]) / r[6], (iy1 - r[2]) / r[6])
                t:SetSize((ix1 - ix0) * S, (iy1 - iy0) * S)
                local sx, sy = PicToScreen(g, ix0, iy0, px, py)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", world, "TOPLEFT", sx, -sy)
                t:Show()
                return true
            end
        end
    end
    if t then t:Hide() end
    return false
end

-- Wind: a gust rolls across the meadows in the clouds' direction (Amb.Clouds drifts right and a little down: WIND_X,
-- WIND_Y); small cells under the gust are drawn again one pixel over (the blades bend) with a little light added.
-- Only the cells under the gust exist, so this costs a handful of textures.
Amb.WIND_X, Amb.WIND_Y, Amb.WIND_SPEED = 0.92, 0.39, 42
function Amb.Wind(m, g, px, py)
    local n = 0
    if g and g.meadows and not G:Data().calm then
        local S, ox, oy = TILE / 16, g.mx * 16, g.my * 16
        local vx0, vx1 = (px - HX - 1) * 16 + ox, (px - HX + VW + 1) * 16 + ox
        local vy0, vy1 = (py - HY - 1) * 16 + oy, (py - HY + VH + 1) * 16 + oy
        for i, r in ipairs(g.meadows) do
            if r[1] < vx1 and r[1] + r[3] > vx0 and r[2] < vy1 and r[2] + r[4] > vy0 then
                local file = MEDIA .. "Ground\\" .. m.id .. "_m" .. i
                for cy = r[2], r[2] + r[4] - 1, 8 do
                    for cx = r[1], r[1] + r[3] - 1, 4 do
                        local phase = ((cx - ox) * Amb.WIND_X + (cy - oy) * Amb.WIND_Y - now * Amb.WIND_SPEED) % 150
                        if phase < 16 and cx + 4 > vx0 and cx < vx1 and cy + 8 > vy0 and cy < vy1 then
                            local w, h = min(4, r[1] + r[3] - cx), min(8, r[2] + r[4] - cy)
                            local u0, v0 = (cx - r[1] - 1) / r[5], (cy - r[2]) / r[6]
                            for k = 1, 2 do               -- the bent cell, then its light (added)
                                n = n + 1
                                local tx = Amb.windTex[n]
                                if not tx then
                                    tx = Tex(world, "BACKGROUND", 3)
                                    Amb.windTex[n] = tx
                                end
                                if tx.file ~= file then
                                    tx.file = file
                                    SetPixelTexture(tx, file)
                                end
                                tx:SetDrawLayer("BACKGROUND", 2 + k)
                                if k == 2 then
                                    pcall(tx.SetBlendMode, tx, "ADD")
                                    local a = phase < 8 and 0.09 or 0.05
                                    tx:SetVertexColor(a, a, a * 0.6)
                                else
                                    pcall(tx.SetBlendMode, tx, "BLEND")
                                    tx:SetVertexColor(1, 1, 1)
                                end
                                tx:SetTexCoord(u0, u0 + w / r[5], v0, v0 + h / r[6])
                                tx:SetSize(w * S, h * S)
                                local x, y = PicToScreen(g, cx, cy, px, py)
                                tx:ClearAllPoints()
                                tx:SetPoint("TOPLEFT", world, "TOPLEFT", x, -y)
                                tx:Show()
                            end
                        end
                    end
                end
            end
        end
    end
    for i = n + 1, #Amb.windTex do Amb.windTex[i]:Hide() end
end

-- Dusk and night: the baked darkness (pools of warm light round lamps, the forge and windows) multiplied over the
-- world instead of the flat sky tint, glows that flicker on top, and a lantern round the player. Returns true when
-- the darkness is up (the caller then hides the flat tint).
local function Glow(n, sx, sy, size, r, g, b, a)
    local t = Amb.glowTex[n]
    if not t then
        t = Tex(world, "OVERLAY", 7)
        t:SetTexture(Amb.GLOW)
        pcall(t.SetBlendMode, t, "ADD")
        Amb.glowTex[n] = t
    end
    t:SetSize(size, size)
    t:SetVertexColor(r, g, b, a)
    t:ClearAllPoints()
    t:SetPoint("CENTER", world, "TOPLEFT", sx, -sy)
    t:Show()
end

-- An NPC's spot on screen this frame (in map pixels: 16 a tile), walking or not.
function Amb.NpcPixels(n)
    local nx, ny = n.x, n.y
    if n.moving then
        local f = math.min(1, n.moving.t / n.moving.dur)
        nx, ny = n.fromX + (n.x - n.fromX) * f, n.fromY + (n.y - n.fromY) * f
    end
    return nx * 16, ny * 16
end

-- The room behind a window light (a stamp with `inside` on the map: the inn, the cottage), if any.
function Amb.WindowRoom(m, g, l)
    if m.windowRooms == nil then
        m.windowRooms = false
        for _, s in ipairs(m.def.stamps or {}) do
            if s.inside then
                m.windowRooms = m.windowRooms or {}
                m.windowRooms[s.kind] = s.inside
            end
        end
    end
    if not m.windowRooms then return nil end
    local tx, ty = floor(l[1] / 16) - g.mx, floor(l[2] / 16) - g.my
    if tx < 0 or ty < 0 or tx >= m.w or ty >= m.h then return nil end
    local o = m.over[m.key(tx, ty)]
    local kind = type(o) == "string" and o:match("^(.-)_%d+_%d+$")
    return kind and m.windowRooms[kind]
end

-- An unlit lamp post's pool of light, covered (Ground/lampcover_<d|n>.tga multiplied over it: the baker's
-- lamp_cover). Returns true when it drew one.
Amb.coverTex = {}
function Amb.CoverLamp(m, g, l, px, py, key, i)
    local S = TILE / 16
    local sx, sy = PicToScreen(g, l[1] - 32, l[2] - 35, px, py)
    if sx > SW or sy > SH or sx + 64 * S < 0 or sy + 64 * S < 0 then return false end
    local t = Amb.coverTex[i]
    if not t then
        t = Tex(world, "OVERLAY", 5)
        pcall(t.SetBlendMode, t, "MOD")
        Amb.coverTex[i] = t
    end
    local file = MEDIA .. "Ground\\lampcover_" .. key
    if t.file ~= file then
        t.file = file
        t.loaded = SetPixelTexture(t, file)
        t:SetTexCoord(0, 1, 0, 1)
        t:SetSize(64 * S, 64 * S)
    end
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", world, "TOPLEFT", sx, -sy)
    t:SetShown(t.loaded)
    return true
end

function Amb.Night(m, g, px, py)
    local period = G:Period()
    local key = (period == "night" and "n") or ((period == "dusk" or period == "dawn") and "d") or nil
    if g and g.indoor and key then key = "n" end
    if g and g.cave then key = "n" end                  -- a cave or mine is always dim, lit by its torches
    local n, gn = 0, 0
    if g and key and g.lightChunks and Amb.modOK ~= false then
        local S, sc = TILE / 16, g.lightScale or 2
        for _, c in ipairs(g.lightChunks) do
            local x0, y0, w, h, tw, th = c[1], c[2], c[3], c[4], c[5], c[6]
            local sx, sy = PicToScreen(g, x0 * sc, y0 * sc, px, py)
            if sx < SW and sy < SH and sx + w * sc * S > 0 and sy + h * sc * S > 0 then
                n = n + 1
                local t = Amb.lightTex[n]
                if not t then
                    t = Tex(world, "OVERLAY", 5)
                    if not pcall(t.SetBlendMode, t, "MOD") then Amb.modOK = false end
                    Amb.lightTex[n] = t
                end
                local file = MEDIA .. "Ground\\" .. m.id .. "_" .. key .. "_" .. floor(x0 / 256) .. "_" .. floor(y0 / 256)
                if t.file ~= file then
                    t.file = file
                    t.loaded = SetPixelTexture(t, file)
                    t:SetTexCoord(0, w / tw, 0, h / th)
                    t:SetSize(w * sc * S, h * sc * S)
                end
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", world, "TOPLEFT", sx, -sy)
                t:SetShown(t.loaded)
            end
        end
        if n > 0 then
            local k = (key == "n") and 1 or 0.6
            local Routine = ns.AzeroRoutine
            local cn = 0
            for _, l in ipairs(g.lights or {}) do
                local sx, sy = PicToScreen(g, l[1], l[2], px, py)
                local lamp = Routine and m.def.lamps and Routine.LampAt(m.id, floor(l[1] / 16) - g.mx, floor(l[2] / 16) - g.my)
                local off = lamp and not Routine.LampLit(m.id, lamp)
                if off and Amb.CoverLamp(m, g, l, px, py, key, cn + 1) then cn = cn + 1 end
                if not off and sx > -TILE * 2 and sy > -TILE * 2 and sx < SW + TILE * 2 and sy < SH + TILE * 2 then
                    local fl = (l[4] == 1) and (0.75 + 0.25 * math.sin(now * 9 + l[1]) * math.sin(now * 5.3 + l[2])) or 1
                    gn = gn + 1
                    local a, size = (l[5] == 1 and 0.3 or 0.45), 1.5
                    local room = l[5] == 1 and Routine and Amb.WindowRoom(m, g, l)
                    if room then                          -- the inn's windows: brighter the more people are in
                        local full = math.min(1, Routine.InsideCount(room) / 6)
                        a, size = 0.14 + 0.36 * full, 1.2 + 0.6 * full
                    end
                    Glow(gn, sx, sy, l[3] * size * S, 1, 0.66, 0.31, a * fl * k)
                end
            end
            for i = cn + 1, #Amb.coverTex do Amb.coverTex[i]:Hide() end
            -- the night watch's lanterns (Routine.lua: def.lantern)
            for _, nn in ipairs(G.npcs or {}) do
                if not nn.hidden and nn.def.lantern then
                    local x, y = Amb.NpcPixels(nn)
                    gn = gn + 1
                    Glow(gn, (x / 16 - px + HX) * TILE + TILE * 0.8, (y / 16 - py + HY) * TILE + TILE * 0.6, 40 * S, 1, 0.7, 0.35,
                         (0.4 + 0.05 * math.sin(now * 7 + x)) * k)
                end
            end
            -- a bonfire's light (Aftermath.lua props)
            for _, p in ipairs(ns.AzeroAftermath and ns.AzeroAftermath.Props(m) or {}) do
                if p.glow then
                    gn = gn + 1
                    Glow(gn, (p.x + 1 - px + HX) * TILE, (p.y - 0.2 - py + HY) * TILE, 90 * S, 1, 0.6, 0.28,
                         (0.6 + 0.08 * math.sin(now * 9) * math.sin(now * 5.3)) * k)
                end
            end
            -- (the player carries no light: a glow round them with no lantern to be seen read as them glowing)
        end
    end
    for i = n + 1, #Amb.lightTex do Amb.lightTex[i]:Hide() end
    for i = gn + 1, #Amb.glowTex do Amb.glowTex[i]:Hide() end
    if n == 0 then for _, t in ipairs(Amb.coverTex) do t:Hide() end end
    return n > 0
end

-- The zone's mood (Amb.MOODS): its tint and the soft frame, multiplied over the world, and motes in the air by day.
local function Overlay(tex, file, blend, wrap)
    -- a full-screen overlay's file, once; false if the client could not load it (it then stays hidden)
    if tex.ready == nil then
        local ok, loaded
        if wrap then ok, loaded = pcall(tex.SetTexture, tex, file, "REPEAT", "REPEAT") end
        if not ok then loaded = tex:SetTexture(file) end
        tex.ready = loaded ~= false
        if blend then pcall(tex.SetBlendMode, tex, blend) end
    end
    return tex.ready
end

-- Rain: some half hours of the realm's day it rains over a zone that has weather (the same for the whole guild)
function Amb.Raining(m, mood)
    if not (mood and mood.rain and m.def.outdoor) or G:Data().calm then return false end
    if G.forceRain ~= nil then return G.forceRain end
    local t = (GetServerTime and GetServerTime()) or time()
    local slot = floor(t / 1800)
    return ((slot * 2654435761) % 4294967296) / 4294967296 < 0.12
end

function Amb.Mood(m, g, px, py, period)
    local calm = G:Data().calm
    R.mist:Hide()
    R.shafts:Hide()
    Amb.raining = false
    G.raining = false
    if g and g.indoor then
        R.mood:Hide()
        R.vignette:SetShown(Amb.modOK ~= false and Overlay(R.vignette, MEDIA .. "Ground\\vignette", "MOD"))
        if period == "day" and not calm then Amb.Dust(g, px, py) end
        return
    end
    local mood = g and Amb.MOODS[m.def.theme or "elwynn"]
    if not mood or Amb.modOK == false then
        R.mood:Hide()
        R.vignette:Hide()
        return
    end
    Amb.raining = Amb.Raining(m, mood)
    G.raining = Amb.raining                     -- (Sound.lua's rain layer)
    local tr, tg, tb = mood.tint[1], mood.tint[2], mood.tint[3]
    if Amb.raining then tr, tg, tb = tr * 0.84, tg * 0.88, tb * 0.94 end
    R.mood:SetColorTexture(tr, tg, tb, 1)
    if not pcall(R.mood.SetBlendMode, R.mood, "MOD") then Amb.modOK = false end
    R.mood:Show()
    R.vignette:SetShown(Overlay(R.vignette, MEDIA .. "Ground\\vignette", "MOD"))
    local W, H = m.w * 16, m.h * 16
    local ox, oy = (px - HX) * 16, (py - HY) * 16          -- the view's top-left in map pixels
    -- mist rolling low over Duskwood
    if mood.mist and Overlay(R.mist, MEDIA .. "Ground\\mist", "BLEND", true) then
        local mx = ox + (calm and 0 or now * 5)
        R.mist:SetTexCoord(mx / 256, (mx + VW * 16) / 256, oy / 256, (oy + VH * 16) / 256)
        R.mist:SetAlpha(math.min(0.9, 0.45 * (ns.AzeroAftermath and ns.AzeroAftermath.Mist(m.id) or 1)))
        R.mist:Show()
    end
    -- sun shafts through the jungle canopy by day
    if mood.shafts and period == "day" and not Amb.raining and Overlay(R.shafts, MEDIA .. "Ground\\shafts", "ADD", true) then
        R.shafts:SetTexCoord(ox / 256, (ox + VW * 16) / 256, oy / 256, (oy + VH * 16) / 256)
        R.shafts:SetAlpha(calm and 0.5 or (0.45 + 0.12 * math.sin(now * 0.6)))
        R.shafts:Show()
    end
    if calm then return end
    if Amb.raining then Amb.Rain(m, px, py, ox, oy) return end
    -- falling leaves (Duskwood)
    if mood.leaves then
        for k = 0, 15 do
            local life = H + 40
            local y = ((((k * 0.37) % 1) * life + now * (6 + (k % 5))) % life) - 20
            local x = ((k * 0.618) % 1) * W + math.sin(now * 1.4 + k) * 6
            local lc = type(mood.leaves) == "table" and mood.leaves[k % #mood.leaves + 1]
            if lc then
                Amb.Pix(px, py, x, y, 2, 1, lc[1], lc[2], lc[3], 1, "ARTWORK", 6)
            else
                Amb.Pix(px, py, x, y, 2, 1, k % 3 > 0 and 0.71 or 0.54, k % 3 > 0 and 0.42 or 0.29, 0.2, 1, "ARTWORK", 6)
            end
        end
    end
    -- ash drifting down over the Burning Steppes (screen-anchored, like the rain, but slow)
    if mood.ash then
        local VWp, VHp = VW * 16, VH * 16
        for k = 0, 27 do
            local fall = VHp + 8
            local y = (((k * 0.7548) % 1) * fall + now * (5 + (k % 4))) % fall - 4
            local x = (((k * 0.5698) % 1) * (VWp + 20) + math.sin(now * 0.9 + k) * 5 + y * 0.2) % (VWp + 20) - 10
            local gr = (k % 3 == 0) and 0.36 or 0.62
            Amb.Pix(px, py, ox + x, oy + y, 1, 1, gr, gr * 0.94, gr * 0.9, 0.8, "OVERLAY", 2)
        end
    end
    -- embers rising off the lava (m.lava: its lava tiles, gathered once), or anywhere in a cave without lava
    if mood.embers then
        if not m.lava then
            m.lava = {}
            for k in pairs(m.water) do m.lava[#m.lava + 1] = k end
            table.sort(m.lava)
        end
        local n = #m.lava
        for k = 0, 23 do
            local t = now * 0.35 + k * 0.37
            local age, cyc = t % 1, floor(t)
            local tx, ty
            if n > 0 then
                local key = m.lava[(cyc * 7919 + k * 104729) % n + 1]
                tx, ty = key % m.w, floor(key / m.w)
            else
                tx, ty = (cyc * 31 + k * 17) % m.w, (cyc * 13 + k * 29) % m.h
            end
            local x = tx * 16 + 4 + (k * 5) % 9 + math.sin(t * 9 + k) * 2
            local y = ty * 16 + 10 - age * 38
            if x > ox - 16 and x < ox + VW * 16 + 16 and y > oy - 16 and y < oy + VH * 16 + 16 then
                Amb.Pix(px, py, x, y, 1, 1, 1, 0.55 + 0.3 * (1 - age), 0.2, 1 - age * 0.8, "OVERLAY", 6)
            end
        end
    end
    -- fireflies at dusk and night (Stranglethorn)
    if mood.fireflies and period ~= "day" then
        for k = 0, 29 do
            local x = ((k * 0.618) % 1) * W + math.sin(now * 0.5 + k) * 10
            local y = ((k * 0.414) % 1) * H + math.cos(now * 0.4 + k * 1.7) * 8
            local on = 0.5 + 0.5 * math.sin(now * 2.2 + k * 2.4)
            if on > 0.3 then
                Amb.Pix(px, py, x - 1, y - 1, 3, 3, 0.78, 1, 0.47, 0.22 * on, "OVERLAY", 7)
                Amb.Pix(px, py, x, y, 1, 1, 0.9, 1, 0.63, on, "OVERLAY", 7)
            end
        end
    end
    -- motes in the air by day and dusk
    if period == "night" or not mood.motes then return end
    local col = (period == "dusk" or period == "dawn") and (mood.duskMotes or mood.motes) or mood.motes
    for k = 0, 33 do
        local h1, h2, h3 = (k * 0.6180339) % 1, (k * 0.4142135) % 1, (k * 0.7320508) % 1
        if math.sin(now * 1.7 + k * 1.3) > 0.2 then
            local x = (h1 * W + now * (3 + h2 * 4)) % W
            local y = (h3 * H + math.sin(now * 0.8 + k) * 6 - now * 1.5 + H * 10) % H
            Amb.Pix(px, py, x, y, 1, 1, col[1], col[2], col[3], 0.85, "ARTWORK", 6)
        end
    end
end

-- rain over the view: streaks falling at a slant (screen-anchored) and little splashes on the ground
function Amb.Rain(m, px, py, ox, oy)
    local VWp, VHp = VW * 16, VH * 16
    for k = 0, 69 do
        local fall = VHp + 12
        local y = (((k * 0.7548) % 1) * fall + now * 160) % fall - 6
        local x = (((k * 0.5698) % 1) * (VWp + 30) - (y * 0.25)) % (VWp + 30) - 10
        Amb.Pix(px, py, ox + x, oy + y, 1, 3, 0.72, 0.8, 0.95, 0.55, "OVERLAY", 2)
    end
    for k = 0, 14 do
        local cyc = floor(now * 3 + k * 0.37)
        local sx = ((cyc * 0.618 + k * 0.381) % 1) * VWp
        local sy = ((cyc * 0.414 + k * 0.732) % 1) * VHp
        local f = (now * 3 + k * 0.37) % 1
        if f < 0.5 then
            Amb.Pix(px, py, ox + sx - 1, oy + sy, 1, 1, 0.8, 0.88, 1, 0.6, "BORDER", 3)
            Amb.Pix(px, py, ox + sx + 1, oy + sy, 1, 1, 0.8, 0.88, 1, 0.6, "BORDER", 3)
        else
            Amb.Pix(px, py, ox + sx, oy + sy - 1, 1, 1, 0.8, 0.88, 1, 0.45, "BORDER", 3)
        end
    end
end

-- the sea's and big lakes' glints (Ground.lua glints: open-water tiles of the baked picture), a few at a time
function Amb.Glints(m, g, px, py)
    if not (g and g.glints) or G:Data().calm then return end
    local col = Amb.GLINT[m.def.theme or "elwynn"] or Amb.GLINT.elwynn
    local mx0, my0 = g.mx, g.my
    local vx0, vx1 = px - HX - 1 + mx0, px - HX + VW + 1 + mx0
    local vy0, vy1 = py - HY - 1 + my0, py - HY + VH + 1 + my0
    for i, tl in ipairs(g.glints) do
        local tx, ty = tl[1], tl[2]
        if tx >= vx0 and tx <= vx1 and ty >= vy0 and ty <= vy1 then
            local h = ((tx * 73856093 + ty * 19349663) % 1000) / 1000
            local ph = (now * 0.45 + h) % 1
            if ph < 0.3 then
                local x = (tx - mx0) * 16 + 2 + floor(((h * 7.3) % 1) * 11)
                local y = (ty - my0) * 16 + 2 + floor(((h * 13.7) % 1) * 12)
                local wide = ph > 0.08 and ph < 0.22
                Amb.Pix(px, py, x - (wide and 1 or 0), y, wide and 3 or 1, 1, col[1], col[2], col[3], 0.9, "BACKGROUND", 4)
            end
        end
    end
end

-- footsteps: a puff of dust on paths, sand and cave floors, a few leaves kicked up in tall grass (more when running)
function Amb.Steps(m, px, py)
    local mv = G.moving
    if mv and mv ~= Amb.lastMove then
        Amb.lastMove = mv
        if not G:Data().calm then
            local ch = m.def.rows[mv.fromY + 1] and m.def.rows[mv.fromY + 1]:sub(mv.fromX + 1, mv.fromX + 1) or "."
            local kind = (ch == "\"" or ch == ";") and "leaf" or ((ch == "=" or ch == "s" or (m.def.theme == "mine")
                or (m.def.theme == "arena") or (m.def.theme == "gorge") or (m.def.theme == "blackrock")) and "dust") or nil
            local running = mv.dur < (G.STEP_TIME or 0.25) * 0.8
            if kind then
                for k = 1, running and 2 or 1 do
                    Amb.parts[#Amb.parts + 1] = { kind = kind, x = mv.fromX * 16 + 8, y = mv.fromY * 16 + 14,
                                                  t0 = now, seed = #Amb.parts + k }
                end
            end
        end
    end
    local keep = {}
    for _, p in ipairs(Amb.parts) do
        local age = now - p.t0
        if p.kind == "dust" and age < 0.45 then
            keep[#keep + 1] = p
            local f = age / 0.45
            local sz = f < 0.4 and 2 or 3
            Amb.Pix(px, py, p.x - 3 - f * 3, p.y - f * 4, sz, sz, 0.78, 0.7, 0.56, 0.6 * (1 - f), "ARTWORK", 0)
            Amb.Pix(px, py, p.x + 1 + f * 3, p.y - f * 3, sz, sz, 0.78, 0.7, 0.56, 0.5 * (1 - f), "ARTWORK", 0)
        elseif p.kind == "leaf" and age < 0.55 then
            keep[#keep + 1] = p
            local f = age / 0.55
            for k = 0, 2 do
                local dx = (k - 1) * (2 + f * 4)
                local dy = -8 * f + 14 * f * f - k
                Amb.Pix(px, py, p.x + dx, p.y - 4 + dy, 1, 1, 0.32, 0.62 + k * 0.08, 0.26, 1 - f * 0.5, "ARTWORK", 4)
            end
        end
    end
    Amb.parts = keep
end

-- dust motes drifting down through an interior's sun shafts (Ground.lua shafts: x, y, width in picture pixels)
function Amb.Dust(g, px, py)
    local ox, oy = g.mx * 16, g.my * 16
    for si, sh in ipairs(g.shafts or {}) do
        for k = 0, 11 do
            if math.sin(now * 2 + k * 1.7 + si) > 0 then
                local life = (now * 0.07 + k / 12) % 1
                local y = sh[2] + 14 + life * 48 + math.sin(now * 0.9 + k) * 2
                local x = sh[1] + 2 + (y - sh[2] - 13) * 0.3 + (k * 7) % sh[3] + math.sin(now * 0.6 + k * 2) * 1.5
                Amb.Pix(px, py, x - ox, y - oy, 1, 1, 1, 0.97, 0.86, 0.8, "ARTWORK", 6)
            end
        end
    end
end

-- The Guild Hall (Hideout.lua, baked by gen_azeromon_hall.py; HallArt.lua says where everything goes): a shut wing's
-- seal picture over the ground and its dimmed night light, things that stand up drawn behind or in front of the
-- player by their foot, a trophy on every plinth the guild has earned, the chandelier over everything, flames,
-- Serpentshrine's water, coloured glows at night, motes in each open wing, and the wing's name on walking in.
Amb.hall = { props = {}, troph = {}, seals = {}, dims = {}, fires = {}, water = {}, glows = {}, wing = nil }
Amb.HALL_MOTES = { arcane = { 0.78, 0.63, 1 }, fel = { 0.55, 1, 0.35 }, bubbles = { 0.67, 0.92, 1 },
                   stars = { 1, 0.94, 1 }, wisps = { 0.78, 1, 0.86 }, embers = { 1, 0.67, 0.31 },
                   sun = { 1, 0.9, 0.59 }, dust = { 1, 0.94, 0.82 } }

function Amb.HallTex(pool, i, layer, sub, blend)
    local t = pool[i]
    if not t then
        t = Tex(world, layer, sub)
        if blend then pcall(t.SetBlendMode, t, blend) end
        pool[i] = t
    end
    return t
end

-- place pool texture t over map pixels (x, y, w, h), cut from a texture of tw x th at (tx0, ty0); false off screen
function Amb.HallPlace(t, g, x, y, w, h, px, py, file, tx0, ty0, tw, th, dw, dh)
    local S = TILE / 16
    dw, dh = dw or w, dh or h
    local sx, sy = PicToScreen(g, x, y, px, py)
    if sx > SW or sy > SH or sx + dw * S < 0 or sy + dh * S < 0 then t:Hide() return false end
    if t.file ~= file then t.file = file t.loaded = SetPixelTexture(t, file) end
    t:SetTexCoord(tx0 / tw, (tx0 + w) / tw, ty0 / th, (ty0 + h) / th)
    t:SetSize(dw * S, dh * S)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", world, "TOPLEFT", sx, -sy)
    t:SetShown(t.loaded ~= false)
    return true
end

function Amb.HallGlow(g, px, py, x, y, size, r, gg, b, a)
    local P = Amb.hall
    local sx, sy = PicToScreen(g, x, y, px, py)
    if sx < -size or sy < -size or sx > SW + size or sy > SH + size then return end
    P.ng = P.ng + 1
    local t = Amb.HallTex(P.glows, P.ng, "OVERLAY", 7, "ADD")
    if not t.file then t.file = Amb.GLOW t:SetTexture(Amb.GLOW) end
    t:SetSize(size, size)
    t:SetVertexColor(r, gg, b, a)
    t:ClearAllPoints()
    t:SetPoint("CENTER", world, "TOPLEFT", sx, -sy)
    t:Show()
end

function Amb.HallMotes(A_, px, py, shown, night)
    for mi, e in ipairs(A_.motes) do
        local kind, x0, y0, w, h = e[1], e[2], e[3], e[4], e[5]
        local c = Amb.HALL_MOTES[kind]
        if c and shown(e[6]) and not (kind == "dust" and night) then
            for k = 0, 9 do
                local h1, h2, h3 = (k * 0.618 + mi * 0.17) % 1, (k * 0.414 + mi * 0.31) % 1, (k * 0.732) % 1
                local life = (now * (0.12 + h2 * 0.1) + h3) % 1
                local x, y
                if kind == "stars" then
                    x, y = x0 + h1 * w, y0 + h2 * h
                elseif kind == "wisps" then
                    x = x0 + (h1 * w + math.sin(now * 0.7 + k) * 14) % w
                    y = y0 + (h2 * h + math.cos(now * 0.5 + k * 1.7) * 8) % h
                elseif kind == "dust" then
                    x, y = x0 + (h1 * w + now * 2.5) % w, y0 + h2 * h + math.sin(now + k) * 2
                else
                    x = x0 + h1 * w + math.sin(now * 1.3 + k) * 3
                    y = y0 + h - life * h
                end
                local a = math.sin(life * math.pi) * (kind == "stars" and (0.5 + 0.5 * math.sin(now * 6 + k)) or 1)
                if a > 0.08 then
                    Amb.Pix(px, py, x, y, 1, 1, c[1], c[2], c[3], a * (kind == "dust" and 0.45 or 0.9), "OVERLAY", 6)
                    if kind == "wisps" then Amb.Pix(px, py, x - 1, y - 1, 3, 3, c[1], c[2], c[3], a * 0.25, "OVERLAY", 6) end
                end
            end
        end
    end
end

function Amb.Hall(m, g, px, py, period, dark)
    local A_, H_ = ns.AzeroHallArt, ns.AzeroHideout
    local P = Amb.hall
    local on = A_ and H_ and g and g.hall and m.def.hall
    local np, nt, ns_, nd, nf, nw = 0, 0, 0, 0, 0, 0
    P.ng = 0
    if on then
        local GF = MEDIA .. "Ground\\hideout_"
        local open, wingOf = {}, {}
        for i, w in ipairs(A_.wings) do open[i] = H_.WingOpen(w.key) wingOf[w.key] = i end
        local function shown(wi) return wi == 0 or open[wi] end
        local night = period ~= "day"
        local calm = G:Data().calm
        local S = TILE / 16
        -- shut wings: the seal picture, and at night their dimmer light
        for i, w in ipairs(A_.wings) do
            if not open[i] then
                local r = w.rect
                ns_ = ns_ + 1
                Amb.HallPlace(Amb.HallTex(P.seals, ns_, "BACKGROUND", 2), g, r[1], r[2], r[3], r[4], px, py,
                              GF .. "seal" .. i .. (night and "e" or ""), 0, 0, w.tex[1], w.tex[2])
                if dark then
                    nd = nd + 1
                    Amb.HallPlace(Amb.HallTex(P.dims, nd, "OVERLAY", 5, "MOD"), g, r[1], r[2], w.dim[1], w.dim[2], px, py,
                                  GF .. "dim" .. i, 0, 0, w.dim[3], w.dim[4], r[3], r[4])
                end
            end
        end
        -- standing things, then the trophies: in front of the player when their foot is lower on the screen
        local foot = py * 16 + 15
        local sheet, SWd, SHt = GF .. "props", A_.sheet[1], A_.sheet[2]
        for _, p in ipairs(A_.props) do
            if shown(p[8]) then
                np = np + 1
                local t = Amb.HallTex(P.props, np, "ARTWORK", 0)
                t:SetDrawLayer("ARTWORK", p[7] > foot and 3 or 0)
                Amb.HallPlace(t, g, p[5], p[6], p[3], p[4], px, py, sheet, p[1], p[2], SWd, SHt)
            end
        end
        for _, o in ipairs(m.def.objects or {}) do
            if o.boss and o.theme and H_.Trophy(o.boss.enc) and shown(wingOf[o.boss.raid] or 0) then
                if not A_.trophyOf then
                    A_.trophyOf = {}
                    for _, t in ipairs(A_.trophies) do A_.trophyOf[t[1]] = { t[2], t[3], t[4], t[5] } end
                end
                local tr = A_.trophyOf[o.theme]
                nt = nt + 1
                local t = Amb.HallTex(P.troph, nt, "ARTWORK", 0)
                t:SetDrawLayer("ARTWORK", o.y * 16 + 15 > foot and 3 or 0)
                local bob = (o.theme == "sw" or o.theme == "tk") and not calm and floor(math.sin(now * 1.6 + o.x) + 0.5) or 0
                Amb.HallPlace(t, g, o.x * 16, o.y * 16 - 19 + bob, tr[3], tr[4], px, py, sheet, tr[1], tr[2], SWd, SHt)
            end
        end
        local top = A_.top
        if top then
            Amb.HallPlace(Amb.HallTex(P, "topTex", "ARTWORK", 4), g, top[5], top[6], top[3], top[4], px, py, sheet,
                          top[1], top[2], SWd, SHt)
        end
        -- flames (over the darkness: they are the light)
        for i, f in ipairs(A_.fires) do
            local st = A_.strips[f[3]]
            if st and shown(f[4]) then
                nf = nf + 1
                local fr = calm and 0 or floor(now * 10 + i * 3) % st[5]
                Amb.HallPlace(Amb.HallTex(P.fires, nf, "OVERLAY", 6), g, f[1], f[2], st[1], st[2], px, py,
                              GF .. "f_" .. f[3], fr * st[1], 0, st[3], st[4])
            end
        end
        -- Serpentshrine's water wall and basin
        for i, wv in ipairs(A_.water) do
            if shown(wv[10]) then
                nw = nw + 1
                local fr = calm and 0 or floor(now * 6) % wv[9]
                local c, r = fr % wv[5], floor(fr / wv[5])
                Amb.HallPlace(Amb.HallTex(P.water, nw, "BACKGROUND", 3), g, wv[1], wv[2], wv[3], wv[4], px, py,
                              GF .. "w" .. i, c * wv[3], r * wv[4], wv[7], wv[8])
            end
        end
        -- coloured glows at night, and Sunwell's light over the throne once the plateau has fallen
        if dark then
            for i, l in ipairs(A_.glows) do
                if shown(l[8]) then
                    local fl = (l[7] == 1 and not calm) and (0.8 + 0.2 * math.sin(now * 9 + i) * math.sin(now * 5.3 + l[1])) or 1
                    Amb.HallGlow(g, px, py, l[1], l[2], l[3] * 1.1 * S, l[4], l[5], l[6], 0.32 * fl)
                end
            end
        end
        local sw = wingOf.SunwellPlateau
        if sw and open[sw] then
            local n, total = H_.WingCount("SunwellPlateau")
            local k = total > 0 and n / total or 1
            Amb.HallGlow(g, px, py, 288, 92, 190 * S, 1, 0.92, 0.66,
                         (dark and 0.5 or 0.3) * k * (calm and 1 or (0.9 + 0.1 * math.sin(now * 0.8))))
        end
        -- motes in the open wings, Karazhan's floating candles
        if not calm then Amb.HallMotes(A_, px, py, shown, night) end
        for ci, cd in ipairs(A_.candles) do
            if shown(cd[3]) then
                local y = cd[2] + (calm and 0 or floor(math.sin(now * 1.4 + ci) * 2.5 + 0.5))
                Amb.Pix(px, py, cd[1], y, 2, 4, 0.96, 0.94, 0.86, 1, "ARTWORK", 3)
                Amb.Pix(px, py, cd[1] + 1, y + 1, 1, 3, 0.78, 0.75, 0.67, 1, "ARTWORK", 3)
                Amb.Pix(px, py, cd[1], y - 1, 1, 1, 1, 0.82, 0.41, 1, "OVERLAY", 6)
                if dark then Amb.HallGlow(g, px, py, cd[1] + 1, y, 18 * S, 0.82, 0.67, 1, 0.35) end
            end
        end
        -- walking into a wing (or up to its mouth): its name and count over the screen
        local s_ = G.save
        local here
        for _, w in ipairs(A_.wings) do
            local r = w.rect
            local inside = s_.x * 16 >= r[1] and s_.x * 16 < r[1] + r[3] and s_.y * 16 >= r[2] and s_.y * 16 < r[2] + r[4]
            local mouth = w.mouth and math.abs(s_.x - w.mouth) <= 1 and s_.y >= w.y0 + 2 and s_.y <= w.y0 + 4
            if inside or mouth then here = w.key end
        end
        if here ~= P.wing then
            P.wing = here
            if here and not G.banner then G.banner = { text = H_.WingLine(here), t = 2.4, total = 2.4 } end
        end
    else
        P.wing = nil
    end
    for i = np + 1, #P.props do P.props[i]:Hide() end
    for i = nt + 1, #P.troph do P.troph[i]:Hide() end
    for i = ns_ + 1, #P.seals do P.seals[i]:Hide() end
    for i = nd + 1, #P.dims do P.dims[i]:Hide() end
    for i = nf + 1, #P.fires do P.fires[i]:Hide() end
    for i = nw + 1, #P.water do P.water[i]:Hide() end
    for i = P.ng + 1, #P.glows do P.glows[i]:Hide() end
    if P.topTex and not on then P.topTex:Hide() end
end

-- People at work (Routine.lua: the act of their day): the smith's sparks, the alchemist's bubbles, Billy's line.
-- Billy's Murkling, Gurgles, bobbing in the pond by his line (an atlas tile, its chin under the water).
function Amb.Gurgles(px, py, mx, my)
    local t = Amb.gurgles
    if not t then
        t = Tex(world, "ARTWORK", 1)
        t:SetSize(TILE, TILE)
        SetPixelTexture(t, ATLAS)
        SetTile(t, "pet_murkling")
        Amb.gurgles = t
    end
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", world, "TOPLEFT", (mx / 16 - px + HX) * TILE, -((my / 16 - py + HY) * TILE))
    t:Show()
    Amb.gurglesAt = now
end

function Amb.Acts(m, px, py)
    local now = GetTime and GetTime() or 0
    for _, n in ipairs(G.npcs or {}) do
        if not n.hidden and n.act and not n.moving then
            local x, y = Amb.NpcPixels(n)
            local d = ({ up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } })[n.face or "down"]
            if n.act == "smith" then
                local beat = (now * 2.2) % 1                 -- each hammer blow throws sparks off the anvil
                if beat < 0.4 then
                    for k = 0, 6 do
                        local a = ((k * 37 + floor(now * 2.2) * 11) % 100) / 100 * math.pi + math.pi
                        local r = beat * 20 * (0.4 + ((k * 53) % 10) / 10)
                        Amb.Pix(px, py, x + d[1] * 16 + 9 + math.cos(a) * r, y + 6 + math.sin(a) * r * 0.6 + beat * beat * 18,
                                1, 1, 1, k % 2 == 0 and 0.82 or 0.55, k % 2 == 0 and 0.48 or 0.23, 1)
                    end
                end
            elseif n.act == "brew" then
                for k = 0, 4 do
                    local age = (now * 0.6 + k / 5) % 1
                    Amb.Pix(px, py, x + d[1] * 16 + 8 + math.sin(age * 6 + k) * 2, y + d[2] * 16 + 4 - age * 16, 1, 1,
                            0.62, 0.88, 0.54, 1 - age * 0.6)
                end
            elseif n.act == "lute" then                   -- notes rising off the bard's lute
                for k = 0, 2 do
                    local age = (now * 0.5 + k / 3) % 1
                    local nx, ny = x + 10 + math.sin(age * 6 + k) * 3 + k * 2, y + 2 - age * 18
                    local a = 1 - age
                    Amb.Pix(px, py, nx, ny, 2, 2, 0.98, 0.9, 0.55, a)
                    Amb.Pix(px, py, nx + 2, ny - 4, 1, 5, 0.98, 0.9, 0.55, a)
                end
            elseif n.act == "cry" then                    -- the crier's hand bell, swinging
                local sw = math.sin(now * 7) > 0 and 1 or -1
                local bx, by = x + 12 + sw, y + 6
                Amb.Pix(px, py, bx, by, 3, 3, 0.86, 0.68, 0.2, 1)
                Amb.Pix(px, py, bx + 1, by - 1, 1, 1, 0.55, 0.42, 0.12, 1)
                Amb.Pix(px, py, bx, by + 3, 3, 1, 0.6, 0.45, 0.12, 1)
            elseif n.act == "fish" then
                for k = 0, 17 do                              -- the line, sagging out over the water, and the bobber
                    Amb.Pix(px, py, x + 12 + k * d[1] + (d[1] == 0 and 8 or 0), y + 6 - math.sin(k / 18 * math.pi) * 6 + k * 0.3,
                            1, 1, 0.94, 0.94, 0.9, 0.7)
                end
                local bob = math.sin(now * 3) > 0.7 and 1 or 0
                Amb.Pix(px, py, x + 12 + 18 * d[1], y + 11 + bob, 2, 2, 0.91, 0.25, 0.17, 1)
                if n.id == "kid" and ns.AzeroPeople and ns.AzeroPeople.BillyStage() >= 2 then
                    Amb.Gurgles(px, py, x + 20 * d[1] + (d[1] < 0 and -4 or 4), y - 3 + (math.sin(now * 2) > 0 and 1 or 0))
                end
            end
        end
        if not n.hidden and n.def.lantern and G:IsNight() then
            local x, y = Amb.NpcPixels(n)
            Amb.Pix(px, py, x + 11, y + 8, 3, 3, 1, 0.82, 0.48, 1)        -- the lantern in his hand
        end
    end
end

-- Fishing (Fishing.lua): ripples over today's school of fish, and the player's line and bobber while it is out -
-- bobbing, then pulled under with a splash ring and a "!" over it when a fish bites.
function Amb.Fishing(m, g, px, py)
    local F = ns.AzeroFish
    if not (F and m.water) then return end
    local now = GetTime and GetTime() or 0
    local calm = G:Data().calm
    local sc = F.School(m)
    if sc and g and not calm then                      -- (a map without a baked ground has no ambient)
        for k = 0, 1 do                                   -- two rings growing out of the school, one after the other
            local age = (now * 0.55 + k * 0.5) % 1
            local r = 2 + age * 6
            local a = 0.55 * (1 - age)
            local cx, cy = sc.x * 16 + 8, sc.y * 16 + 8
            for i = 0, 11 do
                local ang = i / 12 * math.pi * 2
                Amb.Pix(px, py, cx + math.cos(ang) * r, cy + math.sin(ang) * r * 0.55, 1, 1, 0.86, 0.95, 1, a)
            end
        end
        if floor(now * 1.3) % 3 == 0 then                 -- now and then a fish breaks the surface
            Amb.Pix(px, py, sc.x * 16 + 6 + (floor(now) % 5), sc.y * 16 + 6 - ((now * 1.3) % 1) * 3, 2, 1, 0.76, 0.84, 0.9, 0.8)
        end
    end
    local p = G.pending
    if not (p and p.kind == "fish") then return end
    local s = G.save
    local d = G.DIRS[s.face] or G.DIRS.down
    local hx, hy = s.x * 16 + 8 + d[1] * 5, s.y * 16 + 6 + (d[2] < 0 and -4 or 0)     -- the pole's tip
    local bx, by = p.x * 16 + 7, p.y * 16 + 8
    local under = p.biting
    local bob = under and 2 or ((math.sin(now * 3.2) > 0.6) and 1 or 0)
    for k = 1, 15 do                                      -- the line, sagging toward the water
        local f = k / 16
        Amb.Pix(px, py, hx + (bx - hx) * f, hy + (by - hy) * f + math.sin(f * math.pi) * 4, 1, 1, 0.94, 0.94, 0.9, 0.75)
    end
    if not under then
        Amb.Pix(px, py, bx, by + bob, 3, 2, 0.91, 0.25, 0.17, 1)            -- red top
        Amb.Pix(px, py, bx, by + 2 + bob, 3, 1, 0.96, 0.96, 0.9, 1)         -- white belly
    else
        local age = (p.t - p.bite) / p.window
        local r = 2 + age * 5
        for i = 0, 9 do                                   -- the splash ring where it went under
            local ang = i / 10 * math.pi * 2
            Amb.Pix(px, py, bx + 1 + math.cos(ang) * r, by + 2 + math.sin(ang) * r * 0.55, 1, 1, 1, 1, 1, 0.8 * (1 - age))
        end
        Amb.Pix(px, py, bx + 1, by - 13, 2, 6, 1, 0.84, 0.2, 1, "OVERLAY", 6)   -- the "!"
        Amb.Pix(px, py, bx + 1, by - 5, 2, 2, 1, 0.84, 0.2, 1, "OVERLAY", 6)
        Amb.Pix(px, py, bx, by - 14, 4, 8, 0.1, 0.06, 0.02, 0.9, "OVERLAY", 5)
        Amb.Pix(px, py, bx, by - 6, 4, 4, 0.1, 0.06, 0.02, 0.9, "OVERLAY", 5)
    end
end

-- The guild's marks (Marks.lua): Goldshire's statue for the week's guild goal, drawn behind or in front of the
-- player by its foot, and a rune stone with "Name · 3 h ago" where each guildmate who has gone was last seen.
Amb.guildTex, Amb.markFs = {}, {}
function Amb.GuildTex(i)
    local t = Amb.guildTex[i]
    if not t then
        t = Tex(world, "ARTWORK", 0)
        t:SetSize(TILE, TILE)
        SetPixelTexture(t, ATLAS)
        Amb.guildTex[i] = t
    end
    return t
end

function Amb.Guild(m, g, px, py)
    local Marks = ns.AzeroMarks
    local n, nf = 0, 0
    local function place(t, tx, ty)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", world, "TOPLEFT", (tx - px + HX) * TILE, -((ty - py + HY) * TILE))
        t:Show()
    end
    local st = m.def.statue
    if st and Marks then
        local stage = Marks.StatueStage()
        local front = (st.y + 2) * 16 > py * 16 + 16          -- its foot is lower on screen than the player's
        if g then Amb.Pix(px, py, st.x * 16 + 2, (st.y + 2) * 16 - 3, 28, 3, 0.05, 0.1, 0.05, 0.28, "BORDER", 2) end  -- its shadow
        for dy = 0, 3 do
            for dx = 0, 1 do
                n = n + 1
                local t = Amb.GuildTex(n)
                SetTile(t, string.format("statue%d_%d_%d", stage, dx, dy))
                t:SetDrawLayer("ARTWORK", front and 3 or 0)
                place(t, st.x + dx, st.y - 2 + dy)
            end
        end
    end
    if Marks and ns.AzeroChat then
        for _, e in ipairs(Marks:On(m.id)) do
            n = n + 1
            local t = Amb.GuildTex(n)
            SetTile(t, "marker")
            t:SetDrawLayer("BORDER", 2)
            place(t, e.x, e.y)
            -- the hearthstone's rune glowing softly, a slow pulse (each its own beat)
            local glow = 0.6 + 0.4 * math.sin(now * 2.2 + e.x * 1.7 + e.y)
            local gx, gy = e.x * 16, e.y * 16
            Amb.Pix(px, py, gx + 2, gy + 5, 13, 9, 0.45, 0.8, 1, 0.10 * glow, "BORDER", 3)
            Amb.Pix(px, py, gx + 4, gy + 6, 6, 3, 0.55, 0.88, 1, 0.30 * glow, "BORDER", 3)
            nf = nf + 1
            local fs = Amb.markFs[nf]
            if not fs then
                fs = world:CreateFontString(nil, "OVERLAY")
                if not fs:SetFont(FONT, 11, "OUTLINE") then fs:SetFont(FONT_FALLBACK, 9, "OUTLINE") end
                Amb.markFs[nf] = fs
            end
            local cc = RAID_CLASS_COLORS and e.class and RAID_CLASS_COLORS[e.class]
            fs:SetTextColor(cc and (0.5 + cc.r * 0.5) or 0.9, cc and (0.5 + cc.g * 0.5) or 0.9, cc and (0.5 + cc.b * 0.5) or 0.9)
            fs:SetAlpha(0.8)
            fs:SetText(e.label)
            fs:ClearAllPoints()
            fs:SetPoint("TOP", t, "BOTTOM", 0, 2)
            fs:Show()
        end
    end
    for i = n + 1, #Amb.guildTex do Amb.guildTex[i]:Hide() end
    for i = nf + 1, #Amb.markFs do Amb.markFs[i]:Hide() end
end

-- Things standing because of a win (Aftermath.lua A.Props): the militia's standard (1 x 2) and the harvest bonfire
-- (2 x 2, flames over the logs), drawn behind or in front of the player by their foot.
Amb.propTex = {}
function Amb.Props(m, g, px, py)
    local list = {}
    for _, p in ipairs(ns.AzeroAftermath and ns.AzeroAftermath.Props(m) or {}) do list[#list + 1] = p end
    for _, p in ipairs(ns.AzeroMarks and ns.AzeroMarks.Props(m) or {}) do list[#list + 1] = p end    -- (the chronicle)
    local n = 0
    local foot = py * 16 + 16
    local function tile(name, tx, ty, layer)
        n = n + 1
        local t = Amb.propTex[n]
        if not t then
            t = Tex(world, "ARTWORK", 0)
            t:SetSize(TILE, TILE)
            SetPixelTexture(t, ATLAS)
            Amb.propTex[n] = t
        end
        SetTile(t, name)
        t:SetDrawLayer("ARTWORK", layer)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", world, "TOPLEFT", (tx - px + HX) * TILE, -((ty - py + HY) * TILE))
        t:Show()
    end
    for _, p in ipairs(list) do
        local front = (p.y + 1) * 16 > foot and 3 or 0
        if p.kind == "standard" then
            tile("standard_0_0", p.x, p.y - 1, front)
            tile("standard_0_1", p.x, p.y, front)
        elseif p.kind == "standard_red" then
            tile("standard_red_0_0", p.x, p.y - 1, front)
            tile("standard_red_0_1", p.x, p.y, front)
        elseif p.kind == "pennant" then                      -- hung from the lamp post's arm
            tile("pennant", p.x + 9 / 16, p.y + 1 / 16, front)
        elseif p.kind == "bonfire" then
            for dy = 0, 1 do for dx = 0, 1 do tile(string.format("bonfire_%d_%d", dx, dy), p.x + dx, p.y - 1 + dy, front) end end
            tile("flame_" .. (floor(now * 8) % 4), p.x + 0.5, p.y - 1 + 0.5, front)
        end
    end
    for i = n + 1, #Amb.propTex do Amb.propTex[i]:Hide() end
end

function Amb.Draw(m, g, px, py)
    local period = G:Period()
    Amb.Water(m, g, px, py)
    Amb.Anims(m, g, px, py)
    Amb.Sun(m, g, px, py, period)
    Amb.Wind(m, g, px, py)
    Amb.Clouds(m, g, px, py)
    Amb.pixN = 0
    if g and m.def.outdoor and not G:Data().calm then
        Amb.Critters(m, px, py, period)
        Amb.Smoke(m, px, py)
    end
    Amb.Glints(m, g, px, py)
    Amb.WaterLife(m, g, px, py, period)          -- (0.46: rain rings and puddles, moonlight, rings round a wader)
    Amb.Steps(m, px, py)
    if g then Amb.Acts(m, px, py) end      -- (maps without a baked ground have no ambient at all)
    if Amb.gurgles and Amb.gurglesAt ~= now then Amb.gurgles:Hide() end
    Amb.Guild(m, g, px, py)
    Amb.Props(m, g, px, py)
    Amb.Fishing(m, g, px, py)
    Amb.Mood(m, g, px, py, period)
    local dark = Amb.Night(m, g, px, py)
    Amb.Hall(m, g, px, py, period, dark)
    for i = Amb.pixN + 1, #Amb.pix do Amb.pix[i]:Hide() end
    return dark
end

-- the soft shadow under a person (the atlas' "shadow" tile), on the ground below every sprite
local function Shadow()
    local t = Tex(world, "BORDER", 1)
    t:SetSize(TILE, TILE)
    SetPixelTexture(t, ATLAS)
    SetTile(t, "shadow")
    return t
end

local function BuildWorld()
    world = CreateFrame("Frame", nil, screen)
    world:SetSize(SW, SH)                 -- centred, and scaled a little past the screen to fill the stage (FitScreen)
    world:SetPoint("CENTER")
    pcall(world.SetClipsChildren, world, true)   -- (the tile grid and the ground reach past the view)
    for i = 0, VW + 2 do
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
    R.playerShadow = Shadow()
    R.playerShadow:SetPoint("TOPLEFT", world, "TOPLEFT", HX * TILE, -HY * TILE)
    if ns.AzeroLight then ns.AzeroLight.Attach(world, TILE / 16, SetPixelTexture) end   -- light on people (Light.lua)
    if ns.AzeroWater then ns.AzeroWater.Attach(world, TILE / 16, SetPixelTexture) end   -- water that reflects (Water.lua)
    -- what I say (Chat.lua), over my head
    R.player.say = Box(world, 100, 26, world:GetFrameLevel() + 15)
    R.player.say:EnableMouse(false)
    R.player.say:SetPoint("BOTTOM", R.player, "TOP", 0, 2)
    R.player.say.fs = Font(R.player.say, 11)
    R.player.say.fs:SetPoint("LEFT", 9, 0)
    R.player.say.fs:SetJustifyV("MIDDLE")
    R.player.say:Hide()
    -- cloud shadows (DrawClouds): one repeating texture over the map and the people, under the sky tint
    R.clouds = Tex(world, "OVERLAY", 4)
    R.clouds:SetAllPoints()
    R.clouds:Hide()
    -- the zone's mood (Amb.Mood): a tint and a soft dark frame, both multiplied over the world
    R.mood = Tex(world, "OVERLAY", 4)
    R.mood:SetAllPoints()
    R.mood:Hide()
    R.sun = Tex(world, "ARTWORK", 5)                  -- an interior's sunlight (Amb.Sun), added over everything
    R.sun:Hide()
    R.mist = Tex(world, "OVERLAY", 3)                 -- Duskwood's mist (Amb.Mood), rolling over the ground
    R.mist:SetAllPoints()
    R.mist:Hide()
    R.shafts = Tex(world, "OVERLAY", 4)               -- sun shafts through the jungle canopy (added light)
    R.shafts:SetAllPoints()
    R.shafts:Hide()
    R.vignette = Tex(world, "OVERLAY", 5)
    R.vignette:SetAllPoints()
    R.vignette:Hide()
    R.grassOver = Tex(world, "ARTWORK", 5)
    R.grassOver:SetSize(TILE, TILE * 0.45)
    SetPixelTexture(R.grassOver, ATLAS)
    R.grassOver:SetPoint("BOTTOMLEFT", R.player, "BOTTOMLEFT", 0, 0)
    local i = A.tall_c
    local c, r = i % 16, floor(i / 16)
    local AH = ns.AzeroAtlasHeight or 256
    R.grassOver:SetTexCoord(c * 16 / 256, (c + 1) * 16 / 256, (r * 16 + 16 * 0.55) / AH, (r + 1) * 16 / AH)

    -- the interact hint (DrawHint)
    R.hint = Box(world, 160, 32, world:GetFrameLevel() + 20)
    R.hint.key = Pill(R.hint, 50, 18, 13)
    R.hint.key:SetPoint("LEFT", 10, 0)
    R.hint.key:Set("Space", { 0.30, 0.42, 0.62 })
    R.hint.fs = Font(R.hint, 13)
    R.hint.fs:SetPoint("LEFT", R.hint.key, "RIGHT", 7, 0)
    R.hint.fs:SetJustifyV("MIDDLE")
    R.hint:EnableMouse(false)
    R.hint:Hide()

    R.banner = Box(world, 220, 44, 30)
    R.banner:SetPoint("TOPLEFT", 8, -8)
    R.banner.fs = Font(R.banner, 16, nil, true)
    R.banner.fs:SetPoint("CENTER")
    R.banner.fs:SetJustifyH("CENTER")
    R.banner.fs:SetJustifyV("MIDDLE")

    R.fade = Tex(screen, "OVERLAY", 7)
    R.fade:SetAllPoints(root)
    R.fade:SetColorTexture(0, 0, 0, 1)
    R.fade:Hide()

    -- the sky tint covers the map and the sprites (not the banner or text boxes, which are separate frames)
    R.sky = Tex(world, "OVERLAY", 6)
    R.sky:SetAllPoints()
    R.sky:Hide()
end

local function Sprite(i)
    local s = sprites[i]
    if not s then
        s = Tex(world, "ARTWORK", 1)
        s:SetSize(TILE, TILE)
        SetPixelTexture(s, CHARS)
        s.shadow = Shadow()
        s.shadow:SetPoint("TOPLEFT", s, "TOPLEFT")
        s.bang = Font(world, 26)
        s.bang:SetText("!")
        s.bang:SetTextColor(0.9, 0.2, 0.2)
        -- the name plate: the name over a WoW-style <title>, both over the head
        s.title = world:CreateFontString(nil, "OVERLAY")
        if not s.title:SetFont(FONT_BOLD, 9, "OUTLINE") then s.title:SetFont(FONT_FALLBACK, 8, "OUTLINE") end
        s.title:SetTextColor(0.88, 0.86, 0.66)
        s.title:SetPoint("BOTTOM", s, "TOP", 0, 1)
        s.name = world:CreateFontString(nil, "OVERLAY")
        if not s.name:SetFont(FONT_BOLD, 11, "OUTLINE") then s.name:SetFont(FONT_FALLBACK, 9, "OUTLINE") end
        s.name:SetTextColor(1, 0.98, 0.9)
        -- a speech bubble over the name (a line from the NPC's day: Routine.lua def.says)
        s.say = Box(world, 100, 26, world:GetFrameLevel() + 15)
        s.say:EnableMouse(false)
        s.say.fs = Font(s.say, 11)
        s.say.fs:SetPoint("LEFT", 9, 0)
        s.say.fs:SetJustifyV("MIDDLE")
        s.say:Hide()
        sprites[i] = s
    end
    return s
end

local peerSprites = {}
local PEER_BUSY = { pvp = "battling", battle = "battling", trade = "trading", watch = "watching" }
local function PeerSprite(i)
    local s = peerSprites[i]
    if not s then
        s = Tex(world, "ARTWORK", 0)
        s:SetSize(TILE, TILE)
        SetPixelTexture(s, CHARS)
        s.shadow = Shadow()
        s.shadow:SetPoint("TOPLEFT", s, "TOPLEFT")
        s.label = world:CreateFontString(nil, "OVERLAY")
        if not s.label:SetFont(FONT_BOLD, 11, "OUTLINE") then s.label:SetFont(FONT_FALLBACK, 10, "OUTLINE") end
        s.label:SetPoint("BOTTOM", s, "TOP", 0, -2)
        -- "battling..." over a guildmate who is busy (Net: the peer's status)
        s.bubble = Box(world, 100, 26, world:GetFrameLevel() + 15)
        s.bubble:EnableMouse(false)
        s.bubble:SetPoint("BOTTOM", s.label, "TOP", 0, 1)
        s.bubble.fs = Font(s.bubble, 11)
        s.bubble.fs:SetPoint("LEFT", 9, 0)
        s.bubble.fs:SetJustifyV("MIDDLE")
        s.bubble:Hide()
        peerSprites[i] = s
    end
    return s
end

local function Lerp(a, b, f) return a + (b - a) * f end

-- The "Space: Pick Peacebloom" hint above whatever pressing A would use.
local function DrawHint()
    local h = R.hint
    local text, x, y
    if #stack == 0 and not uiMessage then text, x, y = G:InteractHint() end
    if not text then h:Hide() return end
    if h.text ~= text then
        h.text = text
        h.fs:SetText(text)
        h:SetWidth(floor(TextWidth(text, 13) + h.key:GetWidth() + 34))
    end
    local s = G.save
    local tx, ty = HX + (x - s.x), HY + (y - s.y)
    local left = tx * TILE + TILE / 2 - h:GetWidth() / 2
    left = max(4, min(SW - h:GetWidth() - 4, left))
    h:ClearAllPoints()
    h:SetPoint("BOTTOMLEFT", world, "TOPLEFT", left, -ty * TILE + 2)
    h:Show()
end

-- Light on people (Light.lua, 0.44): which light map is up (as Amb.Night: nil by day outdoors), the people sheet
-- for a sprite (without the grey blob when lit), a sprite's cell in that sheet, and the frame's lights + lanterns.
function Amb.DarkKey(m, g)
    if not (g and g.lightChunks) or Amb.modOK == false then return nil end
    local period = G:Period()
    local key = (period == "night" and "n") or ((period == "dusk" or period == "dawn") and "d") or nil
    if g.indoor and key then key = "n" end
    if g.cave then key = "n" end
    return key
end
function Amb.CharsFile(t, lit)
    local file = lit and ns.AzeroLight.CLEAN or CHARS
    if t.charsFile ~= file then
        t.charsFile = file
        SetPixelTexture(t, file)
        t.charKey = nil                        -- (SetChar sets the frame again)
    end
end
function Amb.CharCell(sprite, face, frame)
    return (FACE_ROW[face] or 0) * 16 + (SPRITE_COL[sprite] or 3) + (frame or 1)
end
function Amb.LightBegin(m, g, px, py)
    local L = ns.AzeroLight
    local lit = L and L.On() or false
    if not lit then
        if Amb.lit then L.Clear() end
        Amb.lit = false
        return false
    end
    Amb.lit = true
    local dark = Amb.DarkKey(m, g)
    L.Begin({ m = m, g = g, now = now, period = G:Period(), raining = Amb.raining, outdoor = m.def.outdoor, dark = dark,
              viewX = px * 16 + 8, viewY = py * 16 + 8, reach = math.sqrt((VW * 8) ^ 2 + (VH * 8) ^ 2) + 16,
              toScreen = function(mx, my) return (mx / 16 - px + HX) * TILE, (my / 16 - py + HY) * TILE end })
    if dark then
        for _, nn in ipairs(G.npcs or {}) do                         -- the night watch's lanterns
            if not nn.hidden and nn.def.lantern then
                local x, y = Amb.NpcPixels(nn)
                L.AddLight(nn.id or nn.def.id or nn.def.name, x + 12, y + 9)
            end
        end
    end
    return true
end
-- Water that reflects (Water.lua, 0.46): the frame's reflection rows; who wades (the shallows: legs under water)
function Amb.WaterBegin(m, g, px, py)
    Amb.waders = Amb.waders or {}
    for i = #Amb.waders, 1, -1 do Amb.waders[i] = nil end
    if not ns.AzeroWater then return false end
    Amb.view = Amb.view or {}
    local v = Amb.view
    v.x0, v.y0 = (px - HX) * 16 - 16, (py - HY) * 16 - 16
    v.x1, v.y1 = (px - HX + VW) * 16 + 16, (py - HY + VH) * 16 + 16
    return ns.AzeroWater.Begin({ m = m, g = g, now = now, raining = Amb.raining, calm = G:Data().calm, view = v,
        toScreen = function(mx, my) return (mx / 16 - px + HX) * TILE, (my / 16 - py + HY) * TILE end })
end
function Amb.Wades(m, x, y)
    local k = m.shallow and m.key(floor(x + 0.5), floor(y + 0.5))
    return k and m.shallow[k] and true or false
end
function Amb.WaterLife(m, g, px, py, period)
    if not (ns.AzeroWater and Amb.view) then return end
    ns.AzeroWater.Life({ m = m, now = now, raining = Amb.raining, calm = G:Data().calm, period = period, view = Amb.view,
        waders = Amb.waders, pix = function(mx, my, w, h, r, gg, b, a, layer, sub) Amb.Pix(px, py, mx, my, w, h, r, gg, b, a, layer, sub) end })
end

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
    torchFrame = "torch" .. (floor(now * 6) % 3 + 1)
    local fx, fy = floor(px), floor(py)
    local ox, oy = (px - fx) * TILE, (py - fy) * TILE
    local outdoor = m.def.outdoor
    local ground = DrawGround(m, px, py)
    for i = 0, VW + 2 do
        for j = 0, VH + 1 do
            local wx, wy = fx - floor(HX) - 1 + i, fy - HY - 1 + j
            local cell = grid[i][j]
            local base, over
            if wx < 0 or wy < 0 or wx >= m.w or wy >= m.h then
                -- outside the map: more forest (the darker floor with trees tucked in, like the baked ground's edge)
                if outdoor and ground then
                    -- the baked margin: the edge carried outward (a road goes on, the rest is forest)
                    local cx, cy = max(0, min(m.w - 1, wx)), max(0, min(m.h - 1, wy))
                    local ch = m.def.rows[cy + 1]:sub(cx + 1, cx + 1)
                    base = false
                    if math.abs(wx - cx) > ground.mx or math.abs(wy - cy) > ground.my then
                        base = A[m.theme.grass1 .. "_forest"] and (m.theme.grass1 .. "_forest") or m.theme.grass1
                    end
                    if ch ~= "=" and ch ~= "w" then over = m.theme.tree end
                elseif outdoor then
                    base, over = m.theme.grass1, m.theme.tree
                else
                    base = "void"
                end
            else
                local k = m.key(wx, wy)
                base, over = m.base[k], m.over[k]
                if over == "torch1" then over = torchFrame end
                if m.def.hall and ground then over = nil end   -- (the hall's pedestals are baked, its trophies props)
                if ground then
                    base = false                       -- the baked picture is the ground here
                elseif m.water[k] then                 -- the calm frame only (swapping frames flickered)
                    base = m.theme.water and m.theme.water[2] or "water2"
                end
                if m.chest[k] then over = G:Flag("chest_" .. m.chest[k].id) and "chest_open" or "chest" end
                local node = m.node and m.node[k]
                if node then
                    local up, res = ns.AzeroCraft:NodeState(m.id, node)
                    over = up and D.resources[res] and D.resources[res].tile or over
                end
                local covers = ns.AzeroAftermath and ns.AzeroAftermath.Covers(m)     -- (a field after a win)
                if covers and covers[k] then over = covers[k] end
            end
            SetTile(cell.base, base)
            SetTile(cell.over, over)
            local x, y = (wx - px + HX) * TILE, -((wy - py + HY) * TILE)
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
    local lit = Amb.LightBegin(m, ground, px, py)
    local Light, Water = ns.AzeroLight, ns.AzeroWater
    local wet = Amb.WaterBegin(m, ground, px, py)
    local wade = Amb.Wades(m, px, py)
    local frame = 1
    if walking or (G.bump and G.input.dir) then
        local f = G.moving and (G.moving.t / G.moving.dur) or (G.bump and (0.2 - G.bump) / 0.2 or 0)
        if f > 0.2 and f < 0.8 then frame = G.stepParity and 0 or 2 end
    end
    local Chat = ns.AzeroChat
    local pface, plift = s.face, 0
    if walking then Chat:Stand("me") else pface, frame, plift = KH.EmoteLook("me", s.face, frame) end
    Amb.CharsFile(R.player, lit)
    R.playerShadow:SetShown(not lit and not wade)
    SetChar(R.player, "hero", pface, frame, wade and 11 or nil)
    R.player:ClearAllPoints()
    R.player:SetPoint("TOPLEFT", world, "TOPLEFT", HX * TILE, -HY * TILE + plift * TILE / 16)
    KH.FitBubble(R.player.say, Chat:Bubble("me"))
    DrawHint()
    -- in tall grass: on a baked map the meadow's own pixels cover the legs, walking or not; elsewhere the old strip
    if ground then
        R.grassOver:Hide()
        Amb.Legs(R.player, m, ground, px * 16, py * 16, px, py)
    else
        local onTall = m.tall[m.key(s.x, s.y)] and not walking
        R.grassOver:SetShown(onTall and true or false)
        if R.player.legs then R.player.legs:Hide() end
    end
    if lit and not wade then
        Light.Person("me", Amb.CharCell("hero", pface, frame), px * 16, py * 16,
            { lift = plift, legs = (R.player.legs and R.player.legs:IsShown()) or R.grassOver:IsShown() })
    end
    if wet then Water.Person("me", Amb.CharCell("hero", pface, frame), px * 16, py * 16, { wade = wade }) end
    if wade then Amb.waders[#Amb.waders + 1] = { px * 16, py * 16 } end
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
            local hop = 0
            if npc.def.dance and not npc.moving and not G:Data().calm then
                hop = math.abs(math.sin(now * 8 + (npc.homeX or 0))) * 2
            end
            local sx, sy = (nx - px + HX) * TILE, -(ny - py + HY) * TILE + ((npc.def.lift or 0) + hop) * TILE / 16
            sp:ClearAllPoints()
            sp:SetPoint("TOPLEFT", world, "TOPLEFT", sx, sy)
            -- now and then a standing NPC glances to the side for a moment (drawn only: the game's facing is unchanged)
            local face = npc.face
            if not npc.moving and not npc.exclaim and G:IsFree() and not G:Data().calm then
                local h = (#(npc.id or "") * 7 + (npc.homeX or 0) * 13 + (npc.homeY or 0) * 29) % 97 / 97
                local cyc = (now + h * 9) % 9
                if cyc < 1.1 then face = (face == "left" or face == "right") and "down" or ((h < 0.5) and "left" or "right") end
            end
            if npc.act == "smith" and not npc.moving then nframe = floor(now * 2.2) % 2 == 0 and 0 or 1 end
            if npc.def.dance and not npc.moving and not G:Data().calm then
                face = ({ "down", "left", "up", "right" })[floor(now * 4 + (npc.homeX or 0)) % 4 + 1]
            end
            Amb.CharsFile(sp, lit)
            SetChar(sp, npc.def.sprite or "bald", face, nframe)
            local t = npc.def.tint
            if t then sp:SetVertexColor(t[1], t[2], t[3]) else sp:SetVertexColor(1, 1, 1) end
            if sp.SetDesaturated and (sp.stone or false) ~= (npc.def.stone or false) then
                sp.stone = npc.def.stone or false            -- a statue: stone grey, up on its pedestal
                pcall(sp.SetDesaturated, sp, sp.stone)
            end
            sp:Show()
            sp.shadow:SetShown(not npc.def.stone and not lit)
            Amb.Legs(sp, m, ground, nx * 16, ny * 16, px, py)
            if lit and not npc.def.stone then
                Light.Person(npc.id or npc.def.id or ("npc" .. n), Amb.CharCell(npc.def.sprite or "bald", face, nframe),
                    nx * 16, ny * 16, { lift = (npc.def.lift or 0) + hop, legs = sp.legs and sp.legs:IsShown() })
            end
            if wet and not npc.def.stone then Water.Person(nil, Amb.CharCell(npc.def.sprite or "bald", face, nframe), nx * 16, ny * 16) end
            local title = G.NpcTitle(npc.def)
            sp.title:SetText(title and ("<" .. title .. ">") or "")
            sp.name:SetText(G.NpcName(npc.def) or "")
            sp.name:ClearAllPoints()
            sp.name:SetPoint("BOTTOM", sp.title, "TOP", 0, -1)
            sp.title:Show()
            sp.name:Show()
            sp.bang:ClearAllPoints()
            sp.bang:SetPoint("BOTTOM", sp.name, "TOP", 0, -2)
            sp.bang:SetShown(npc.exclaim ~= nil)
            local talking = G.pending ~= nil or G.co ~= nil        -- (bubbles wait while someone talks, not while you walk)
            local line = npc.def.says and not talking and ns.AzeroRoutine and ns.AzeroRoutine.Says(npc.def)
            if not line and npc.def.shout and npc.act == "cry" and not npc.moving and not talking then line = npc.def.shout(G) end
            if line then
                if sp.say.text ~= line then
                    sp.say.text = line
                    sp.say.fs:SetText(line)
                    sp.say:SetWidth(floor(TextWidth(line, 11) + 22))
                end
                sp.say:ClearAllPoints()
                sp.say:SetPoint("BOTTOM", sp.name, "TOP", 0, 2)
                sp.say:Show()
            else
                sp.say:Hide()
            end
        end
    end
    for i = n + 1, #sprites do sprites[i]:Hide() sprites[i].shadow:Hide() if sprites[i].legs then sprites[i].legs:Hide() end sprites[i].bang:Hide() sprites[i].name:Hide() sprites[i].title:Hide() sprites[i].say:Hide() end
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
        local pface, lift = p.face or "down", 0
        if p.moving then ns.AzeroChat:Stand(p.key) else pface, pframe, lift = KH.EmoteLook(p.key, pface, pframe) end
        sp:ClearAllPoints()
        sp:SetPoint("TOPLEFT", world, "TOPLEFT", (nx - px + HX) * TILE, -(ny - py + HY) * TILE + lift * TILE / 16)
        sp.shadow:ClearAllPoints()
        sp.shadow:SetPoint("TOPLEFT", world, "TOPLEFT", (nx - px + HX) * TILE, -(ny - py + HY) * TILE)
        Amb.CharsFile(sp, lit)
        local pwade = Amb.Wades(m, nx, ny)
        SetChar(sp, "hero", pface, pframe, pwade and 11 or nil)
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
        sp.shadow:SetShown(not lit and not pwade)
        Amb.Legs(sp, m, ground, nx * 16, ny * 16, px, py)
        if lit and not pwade then
            Light.Person("peer:" .. tostring(p.key), Amb.CharCell("hero", pface, pframe), nx * 16, ny * 16,
                { lift = lift, legs = sp.legs and sp.legs:IsShown() })
        end
        if wet then Water.Person(nil, Amb.CharCell("hero", pface, pframe), nx * 16, ny * 16, { wade = pwade }) end
        if pwade then Amb.waders[#Amb.waders + 1] = { nx * 16, ny * 16 } end
        sp.label:Show()
        local word = PEER_BUSY[p.status]
        local said = ns.AzeroChat:Bubble(p.key)
        if said then
            KH.FitBubble(sp.bubble, said)
        elseif word then
            -- the dots fill up one by one; the width is set for the longest so the box doesn't jump
            KH.FitBubble(sp.bubble, word .. string.rep(".", floor(now * 2.5) % 4), word .. "...")
        else
            sp.bubble:Hide()
        end
    end
    for i = pn + 1, #peerSprites do peerSprites[i]:Hide() peerSprites[i].shadow:Hide() if peerSprites[i].legs then peerSprites[i].legs:Hide() end peerSprites[i].label:Hide() peerSprites[i].bubble:Hide() end
    if lit then Light.End() end
    if Water then Water.End() end
    -- banner / fade
    if G.banner then
        R.banner:Show()
        R.banner.fs:SetText(G.banner.text)
        R.banner:SetWidth(max(200, (R.banner.fs:GetStringWidth() or 0) + 48))
        local total = G.banner.total or 2.2
        local shown = max(0, min(1, (total - G.banner.t) / 0.25, G.banner.t / 0.3))   -- slide down, then up
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
    R.skyAlpha = ApplySky(R.sky, m.def.outdoor, nil, m.def.gloom)
    if Amb.Draw(m, ground, px, py) then R.sky:Hide() end      -- the baked darkness replaces the flat tint
end

---------------------------------------------------------------------------
-- Pending prompts from the engine
---------------------------------------------------------------------------

local shownPending = nil

local function SyncPending()
    local p = G.pending
    if p == shownPending then return end
    -- a Message on screen is answered first: the new prompt (a guildmate's challenge, a trade partner leaving)
    -- shows once it is closed, instead of taking its place and leaving the game waiting on it
    if uiMessage then return end
    shownPending = p
    if not p then
        ClearText()
        return
    end
    -- menus the player opened before this script started (the start menu, the bag) are not part of it: a
    -- guildmate's challenge or trade request closes them, so its prompt gets the keys
    for _, m in ipairs(stack) do
        if m.co ~= G.co then
            CloseAllMenus()
            R.money:Hide()
            break
        end
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
        -- as wide as the longest option needs (the row text starts 36 px in, 24 px of padding after)
        local w = 130
        for _, o in ipairs(p.options) do w = max(w, floor(TextWidth(o, 16) + 60)) end
        w = min(w, SW - 12)
        PushMenu(items, { w = w, x = SW - w - 6, y = -(SH - BOX_H - 4 - (#items * 32 + 24)), level = 60,
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
        OpenShop(p.keeper, p.stock)
    elseif p.kind == "relearn" then
        ClearText()
        Scr.OpenRelearn()
    elseif p.kind == "bounties" then
        ClearText()
        Scr.OpenBounties(function() G:Advance() end)
    elseif p.kind == "trophy" then
        ClearText()
        Scr.OpenTrophy(p.enc)
    elseif p.kind == "trade" then
        ClearText()
        Scr.OpenTrade(p.session)
    elseif p.kind == "stable" then
        ClearText()
        Scr.OpenStable(function() G:Advance() end)
    elseif p.kind == "craft" then
        ClearText()
        if ns.AzeroCraft.Skill(p.prof) then
            Scr.OpenRecipes(p.prof, function() G:Advance() end)
        else
            local prof = D.professions[p.prof]
            Message(string.format("You don't know %s. %s in Goldshire teaches it.", prof.name, prof.trainer),
                function() G:Advance() end)
        end
    elseif p.kind == "netwait" then
        SetText(p.text, { lines = 3 })
        text.shown = 999
    elseif p.kind == "whoswhere" then
        ClearText()
        KH.OpenWhos(p)
    elseif UI.screens[p.kind] then          -- a screen from another UI file (UI:RegisterScreen)
        ClearText()
        UI.screens[p.kind](p)
    end
end

---------------------------------------------------------------------------
-- Title screen
---------------------------------------------------------------------------

-- The logo's art (gen_azeromon_title.py prints these): its used size in game pixels, the texture's size, the ribbon
-- box { x, y, w, h } the tagline sits on. Drawn at `scale` like the world, `top` pixels under the screen's top.
KH.TITLE_ART = { w = 141, h = 51, texW = 256, texH = 64, ribbon = { 14, 31, 112, 16 }, scale = 3, top = 30 }

local function ShowTitle()
    R.title:Show()
    world:Hide()
    CloseAllMenus()
    ClearText()
    if not R.titleFilm and ns.AzeroPoster then
        R.titleFilm = ns.AzeroPoster:New(R.title)
        R.titleFilm:SetFrameLevel(R.title:GetFrameLevel() + 1)
        R.titleFilm:Seek(math.random(#ns.AzeroPoster.SHOTS), 0)
    end
    local items = {}
    if G:HasSave() then
        items[#items + 1] = { text = "CONTINUE", onSelect = function(_, menu)
            PopMenu(menu)
            R.title:Hide()
            world:Show()
            ns.AzeroSound:Play("start")
            G:Load()
        end }
    end
    items[#items + 1] = { text = "NEW GAME", onSelect = function(_, menu)
        local function start()
            PopMenu(menu)
            R.title:Hide()
            world:Show()
            ns.AzeroSound:Play("start")
            G:NewGame()
            G:Run(function(g)
                g:Say("Welcome to Azeroth, the world of AZEROMON!")
                g:Say("From the forests of Elwynn to the jungles of Un'Goro, beasts of every kind roam these lands. Hunters tame them as companions and fight side by side.")
                g:Say("Your journey begins in Goldshire, in the heart of Elwynn Forest. Good luck, {PLAYER}!")
                local perk = g:PerkInfo()
                if perk then g:Say(perk.name .. ": " .. perk.text) end
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
    items[#items + 1] = { text = "WHAT'S NEW", right = KH.ChangelogUnseen() and "•" or nil,      -- (a dot: unread)
        rightColor = { 0.85, 0.55, 0.05 }, onSelect = function(idx, menu)
            KH.OpenChangelog()
            menu.items[idx].right = nil
            UI:RefreshMenu(menu)
        end }
    items[#items + 1] = { text = "CONTROLS", onSelect = function() KH.OpenControls() end }
    PushMenu(items, { w = min(SW - 24, #items * 200), cols = #items, anchor = { "BOTTOM", screen, "BOTTOM", 0, 26 }, rowH = 32,
        level = 60, onCancel = function() end })
end

-- Each frame on the title: the film plays on (held still with MOTION off), the logo breathes.
function KH.TickTitle(elapsed)
    local calm = G:Data().calm
    if R.titleFilm then R.titleFilm:Tick(calm and 0 or elapsed) end
    local t = calm and 0 or now
    R.titleLogo:SetPoint("TOP", 0, -KH.TITLE_ART.top + floor(math.sin(t * 1.6) * 2 + 0.5))
    R.titleGlow:SetAlpha(0.8 + 0.2 * math.sin(t * 1.1))
end

---------------------------------------------------------------------------
-- Key hints: a strip with the keys that matter right now (under the game when there's room, else over its top
-- edge). It shows when the situation changes, fades after a few seconds, comes back when the player idles, and
-- drops a key for good once it has been used KH.KEY_LEARNED times (G:Data().keys; CONTROLS brings them back).
-- One-time tips (G:Data().tips) teach the rest at the moment they matter.
---------------------------------------------------------------------------

KH.KEY_NAME = { A = "Space", B = "X", START = "Tab", CHAT = "Enter", move = "Arrows" }
KH.KEY_LEARNED = 5
KH.KEY_HINTS = {
    world = { { "move", "Walk", "walk" }, { "A", "Talk", "talk" }, { "START", "Menu", "menu" }, { "B", "Run (hold)", "run" },
              { "CHAT", "Chat", "chat" } },
    menu = { { "A", "Select", "select" }, { "B", "Back", "back" } },
    text = { { "A", "Next", "next" } },
    netwait = { { "B", "Cancel", "cancel" } },
    watch = { { "A", "Next", "next" }, { "B", "Stop watching", "stopwatch" } },
    evolve = { { "B", "Stop it evolving", "stopevo" } },
    fish = { { "A", "Hook it (when it dips)", "hook" }, { "B", "Reel in", "reel" } },
    reel = { { "A", "Pull (marker in the gold)", "pull" }, { "B", "Let it go", "letgo" } },
}
KH.keyState = { ctx = false, since = 0, input = 0 }

-- What the player is doing, as far as keys go (nil: no strip - e.g. the summary has its own key line).
function KH.KeyContext()
    if R.title:IsShown() then return #stack > 0 and "menu" or nil end
    if not G.started then return nil end
    if uiMessage then return "text" end
    local top = stack[#stack]
    if top then return (not top.isSummary) and "menu" or nil end
    if BT.battle then return (BT.battle.pvp and BT.battle.pvp.watch) and "watch" or "text" end
    local p = G.pending
    if p then
        if p.kind == "text" then return "text" end
        if p.kind == "netwait" then return "netwait" end
        if p.kind == "evolve" then return "evolve" end
        if p.kind == "fish" then return "fish" end
        if p.kind == "reel" then return "reel" end
        if p.kind == "whoswhere" then return "whos" end
        return nil
    end
    return "world"
end

function KH.KeysUsed()
    local d = G:Data()
    if type(d.keys) ~= "table" then d.keys = {} end
    return d.keys
end

-- A key pressed: it counts toward learning its hint in the current situation.
function KH.NoteKey(key)
    KH.keyState.input = now
    local ctx = KH.KeyContext()
    for _, h in ipairs(ctx and KH.KEY_HINTS[ctx] or {}) do
        if h[1] == key then
            local used = KH.KeysUsed()
            used[h[3]] = (used[h[3]] or 0) + 1
        end
    end
end

function KH.LayoutKeyStrip(list)
    local ks = R.keyStrip
    local x = 0
    for i, part in ipairs(ks.parts) do
        local h = list[i]
        part.pill:SetShown(h ~= nil)
        part.fs:SetShown(h ~= nil)
        if h then
            local key = KH.KEY_NAME[h[1]]
            local pw = floor(TextWidth(key, 12 / 1.4) + 14)
            part.pill:SetWidth(pw)
            part.pill:Set(key, { 0.30, 0.42, 0.62 })
            part.fs:SetText(h[2])
            part.x = x
            x = x + pw + 5 + TextWidth(h[2], 11) + 16
        end
    end
    local left = (ks:GetWidth() - (x - 16)) / 2
    for i, part in ipairs(ks.parts) do
        if list[i] then
            part.pill:ClearAllPoints()
            part.pill:SetPoint("LEFT", ks, "LEFT", left + part.x, 0)
            part.fs:ClearAllPoints()
            part.fs:SetPoint("LEFT", part.pill, "RIGHT", 5, 0)
        end
    end
end

-- Under the game when the space around it allows, else over its top edge.
function KH.PlaceKeyStrip(h)
    local ks = R.keyStrip
    if not ks then return end
    local sc = screen:GetScale() or 1
    local bleed = SH * sc * ((R.bleed or 1) - 1) / 2      -- how far the world reaches past the screen (FitScreen)
    local room = ((h or root:GetHeight() or 0) - SH * sc) / 2 - bleed
    ks:ClearAllPoints()
    ks:SetWidth(SW * sc)
    if room >= 26 then
        ks:SetPoint("TOP", screen, "BOTTOM", 0, -3 - bleed)
        ks.bg:SetAlpha(0)
        ks.outside = true
    else
        ks:SetPoint("TOP", screen, "TOP", 0, -2)
        ks.bg:SetAlpha(1)
        ks.outside = false
    end
    ks:SetFrameLevel(screen:GetFrameLevel() + 300)
end

function KH.UpdateKeyStrip()
    local ks = R.keyStrip
    if not ks then return end
    local ctx = focused and KH.KeyContext() or nil
    if ctx ~= KH.keyState.ctx then KH.keyState.ctx, KH.keyState.since = ctx, now end
    local list, sig = {}, ctx or ""
    local used = KH.KeysUsed()
    for _, h in ipairs(ctx and KH.KEY_HINTS[ctx] or {}) do
        if (used[h[3]] or 0) < KH.KEY_LEARNED then
            list[#list + 1] = h
            sig = sig .. h[3]
        end
    end
    -- shown for 6 s after the situation changes (then a 1 s fade), and again after 12 s without a key
    local t, idle = now - KH.keyState.since, now - KH.keyState.input
    local a = (t < 6) and 1 or max(0, 7 - t)
    if idle > 12 then a = max(a, min(1, idle - 12)) end
    if #list == 0 or a <= 0 then ks:Hide() return end
    if sig ~= ks.sig then
        ks.sig = sig
        KH.LayoutKeyStrip(list)
    end
    ks:SetAlpha(a)
    ks:Show()
end

KH.TIPS = {
    walk = "Tip: walk with the arrow keys or WASD. Space talks to people and picks things up.",
    menu = "Tip: press Tab to open your menu: your beasts, your bag, your professions and more.",
    run = "Tip: hold X while you walk to run.",
    back = "Tip: X (or Q, or a right-click) goes back out of any menu.",
}

function KH.TipSeen(id)
    local d = G:Data()
    if type(d.tips) ~= "table" then d.tips = {} end
    return d.tips[id]
end

function KH.ShowTip(id, after, text)
    G:Data().tips[id] = true
    Message(text or KH.TIPS[id], after)
end

-- Checked every frame in the world; a tip never interrupts a script, a menu or a battle.
function KH.CheckTips()
    if UI.tipsOff or not G:IsFree() or #stack > 0 or uiMessage or BT.battle then return end
    if not KH.TipSeen("walk") then KH.ShowTip("walk") return end
    -- the class perk, once per class (an alt of another class learns its own)
    local cls, perk = G:ClassFile(), G:PerkInfo()
    if cls and perk and not KH.TipSeen("perk_" .. cls) then
        local name = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls]) or (cls:sub(1, 1) .. cls:sub(2):lower())
        KH.ShowTip("perk_" .. cls, nil, string.format("Tip: your class counts here too. %s, %s: %s The menu shows it any time.",
            name, perk.name, perk.text))
        return
    end
    if G:Flag("starter") and not KH.TipSeen("menu") then KH.ShowTip("menu") return end
    if not KH.TipSeen("run") and (tonumber(G.save.steps) or 0) >= 60 then KH.ShowTip("run") return end
end

-- How a move does against a defending type: text and colour for the move panel.
function KH.EffectText(md, defType)
    if not defType or md.power <= 0 then return "", { 0.4, 0.4, 0.45 } end
    local m = D.Effectiveness(md.type, defType)
    if m == 0 then return "No effect", { 0.55, 0.2, 0.2 } end
    if m > 1 then return "Super effective", { 0.2, 0.55, 0.22 } end
    if m < 1 then return "Not very effective", { 0.82, 0.42, 0.1 } end
    return "Normal damage", { 0.4, 0.4, 0.45 }
end

-- Tooltip lines for a type: what hits it hard, what it shrugs off.
function KH.Matchups(defType)
    local weak, resist, immune = {}, {}, {}
    for _, a in ipairs(D.typeOrder) do
        local m = D.Effectiveness(a, defType)
        local name = D.types[a].name
        if m == 0 then immune[#immune + 1] = name
        elseif m > 1 then weak[#weak + 1] = name
        elseif m < 1 then resist[#resist + 1] = name end
    end
    local lines = {}
    if #weak > 0 then lines[#lines + 1] = "Weak to: " .. table.concat(weak, ", ") end
    if #resist > 0 then lines[#lines + 1] = "Resists: " .. table.concat(resist, ", ") end
    if #immune > 0 then lines[#lines + 1] = "Immune to: " .. table.concat(immune, ", ") end
    return lines
end

KH.CELL = { [2] = { "x2", { 0.30, 0.62, 0.32 } }, [0.5] = { "x.5", { 0.84, 0.45, 0.28 } }, [0] = { "x0", { 0.22, 0.22, 0.26 } } }

-- A raid boss's plinth in the Guild Hall (Hideout.lua): the boss on its pedestal and the plaque.
function Scr.OpenTrophy(enc)
    local H = ns.AzeroHideout
    local boss = H and H.Boss(enc)
    ns.AzeroSound:Play("book")
    local f = R.trophy
    if not f then
        f = Box(screen, SW - 20, SH - 20, 100)
        f:SetPoint("CENTER")
        f.noPool = true
        f.title = Font(f, 18, nil, true)
        f.title:SetPoint("TOPLEFT", 22, -18)
        f.title:SetTextColor(0.20, 0.36, 0.62)
        f.sub = Font(f, 12)
        f.sub:SetPoint("TOPLEFT", 22, -44)
        f.sub:SetTextColor(0.36, 0.42, 0.55)
        f.model = NewModel(f, 230, 230)
        f.model:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -36)
        f.lines = {}
        for i = 1, 5 do
            local fs = Font(f, 12)
            fs:SetPoint("TOPLEFT", 22, -80 - (i - 1) * 24)
            fs:SetWidth(SW - 20 - 44 - 240)
            fs:SetWordWrap(i == 5)
            fs:SetTextColor(i == 1 and 0.16 or 0.30, i == 1 and 0.18 or 0.36, i == 1 and 0.24 or 0.50)
            f.lines[i] = fs
        end
        local hint = Font(f, 12)
        hint:SetPoint("BOTTOMRIGHT", -18, 14)
        hint:SetJustifyH("RIGHT")
        hint:SetTextColor(0.36, 0.42, 0.55)
        hint:SetText("Space / X: close")
        f.fake = {}
        R.trophy = f
    end
    f.title:SetText(boss and boss.name:upper() or "TROPHY")
    f.sub:SetText(boss and (boss.raidName .. "  -  the guild's trophy") or "")
    local lines = H and H.Lines(enc) or {}
    for i, fs in ipairs(f.lines) do fs:SetText(lines[i] or "") end
    local fake = f.fake[enc]
    if not fake and boss then
        fake = { id = "trophy" .. enc, name = boss.name, display = H.Display(boss), cam = 1 }
        f.fake[enc] = fake
    end
    if fake and fake.display then ShowCreature(f.model, fake, 0.35) else ShowCreature(f.model, nil) end
    local top = stack[#stack]
    f:SetFrameLevel(max(100, top and top.frame and top.frame:GetFrameLevel() + 10 or 0))
    f:Show()
    stack[#stack + 1] = { frame = f, items = {}, cursor = 1, cols = 1, isPanel = true, co = G.co,
        opts = { onCancel = function(m) PopMenu(m) ShowCreature(f.model, nil) f:Hide() G:Advance() end } }
end
UI._Trophy = function() return R.trophy and R.trophy:IsShown() and { title = R.trophy.title:GetText(), lines = { R.trophy.lines[1]:GetText(), R.trophy.lines[2]:GetText(), R.trophy.lines[3]:GetText() } } or nil end

-- The whole chart: the move's type down the left, the defender's type along the top.
function KH.OpenTypeChart()
    ns.AzeroSound:Play("book")
    local f = R.typeChart
    if not f then
        f = Box(screen, SW - 20, SH - 20, 100)
        f:SetPoint("CENTER")
        f.noPool = true
        local t = Font(f, 18, nil, true)
        t:SetPoint("TOPLEFT", 22, -18)
        t:SetTextColor(0.20, 0.36, 0.62)
        t:SetText("TYPE CHART")
        local sub = Font(f, 12)
        sub:SetPoint("TOPLEFT", 22, -44)
        sub:SetText("Down the left: the move's type.  Along the top: the defender's type.")
        sub:SetTextColor(0.36, 0.42, 0.55)
        local x0, y0, lw, cw, rh = 22, -70, 78, 48, 30
        for j, def in ipairs(D.typeOrder) do                -- column heads
            local p = Pill(f, cw - 4, 16, 11)
            p:SetPoint("TOPLEFT", x0 + lw + (j - 1) * cw, y0 + 2)
            p:Set(D.types[def].name:sub(1, 3):upper(), D.types[def].color)
        end
        for i, atk in ipairs(D.typeOrder) do
            local y = y0 - i * rh
            local p = Pill(f, lw - 8, 18, 12)
            p:SetPoint("TOPLEFT", x0, y + 1)
            p:Set(D.types[atk].name:upper(), D.types[atk].color)
            for j, def in ipairs(D.typeOrder) do
                local m = D.Effectiveness(atk, def)
                local cell = Tex(f, "ARTWORK")
                cell:SetSize(cw - 4, rh - 6)
                cell:SetPoint("TOPLEFT", x0 + lw + (j - 1) * cw, y)
                local look = KH.CELL[m]
                if look then
                    cell:SetColorTexture(look[2][1], look[2][2], look[2][3], 1)
                    local fs = Font(f, 12, "OVERLAY", true)
                    fs:SetPoint("CENTER", cell, "CENTER", 0, 0)
                    fs:SetJustifyH("CENTER")
                    fs:SetText(look[1])
                    fs:SetTextColor(1, 1, 1)
                    fs:SetShadowColor(0, 0, 0, 0.6)
                else
                    cell:SetColorTexture(0.90, 0.91, 0.93, 1)
                end
            end
        end
        local legend = Font(f, 12)
        legend:SetPoint("TOPLEFT", 22, y0 - 9 * rh - 8)
        legend:SetWidth(SW - 64)
        legend:SetText("x2 double damage     x.5 half damage     x0 no effect     blank: normal")
        legend:SetTextColor(0.36, 0.42, 0.55)
        local hint = Font(f, 12)
        hint:SetPoint("BOTTOMRIGHT", -18, 14)
        hint:SetJustifyH("RIGHT")
        hint:SetText("Space / X: close")
        R.typeChart = f
    end
    local top = stack[#stack]
    f:SetFrameLevel(max(100, top and top.frame and top.frame:GetFrameLevel() + 10 or 0))
    f:Show()
    stack[#stack + 1] = { frame = f, items = {}, cursor = 1, cols = 1, isPanel = true, co = G.co,
        opts = { onCancel = function(m) PopMenu(m) f:Hide() end } }
end

-- WHAT'S NEW: one release per page (ns.AzeroChangelog, newest first), left / right for older / newer.
function KH.ChangelogUnseen()
    local log = ns.AzeroChangelog
    return log and log[1] and G:Data().changelogSeen ~= log[1].version
end

function KH.OpenChangelog()
    ns.AzeroSound:Play("book")
    local log = ns.AzeroChangelog or {}
    if #log == 0 then return end
    local f = R.changelog
    if not f then
        f = Box(screen, SW - 20, SH - 20, 100)
        f:SetPoint("CENTER")
        f.noPool = true
        local t = Font(f, 18, nil, true)
        t:SetPoint("TOPLEFT", 22, -18)
        t:SetTextColor(0.20, 0.36, 0.62)
        t:SetText("WHAT'S NEW")
        f.page = Font(f, 13)
        f.page:SetPoint("TOPRIGHT", -22, -24)
        f.page:SetJustifyH("RIGHT")
        f.page:SetTextColor(0.36, 0.42, 0.55)
        f.head = Font(f, 16, nil, true)
        f.head:SetPoint("TOPLEFT", 22, -54)
        f.date = Font(f, 12)
        f.date:SetPoint("TOPLEFT", 22, -80)
        f.date:SetTextColor(0.36, 0.42, 0.55)
        f.body = Font(f, 13)
        f.body:SetPoint("TOPLEFT", 22, -106)
        f.body:SetWidth(SW - 64)
        f.body:SetSpacing(5)
        local hint = Font(f, 12)
        hint:SetPoint("BOTTOMRIGHT", -18, 14)
        hint:SetJustifyH("RIGHT")
        hint:SetText("Left/Right: older / newer   X: close")
        R.changelog = f
    end
    local i = 1
    local function show()
        local r = log[i]
        f.page:SetText(string.format("%d / %d", i, #log))
        f.head:SetText(string.format("v%s  %s", r.version, r.title or ""))
        f.date:SetText(r.date or "")
        local lines = {}
        for k, line in ipairs(r.lines or {}) do lines[k] = "-  " .. line end
        f.body:SetText(table.concat(lines, "\n"))
    end
    show()
    G:Data().changelogSeen = log[1].version
    local top = stack[#stack]
    f:SetFrameLevel(max(100, top and top.frame and top.frame:GetFrameLevel() + 10 or 0))
    f:Show()
    stack[#stack + 1] = { frame = f, items = {}, cursor = 1, cols = 1, isPanel = true, co = G.co,
        onKey = function(key)
            if key == "right" and i < #log then i = i + 1 show() return true end
            if key == "left" and i > 1 then i = i - 1 show() return true end
            return key == "left" or key == "right" or key == "up" or key == "down"
        end,
        opts = { onCancel = function(m) PopMenu(m) f:Hide() end } }
end

---------------------------------------------------------------------------
-- The beast over the world (starter choice, evolution) and the evolution animation: both forms are loaded (the
-- next one while "What? X is evolving!" is read), turned into silhouettes, swapped faster and faster, then a white
-- flash and the new form. A scene that already holds a form keeps it: swapping it into the other scene would
-- reload and re-measure it.
---------------------------------------------------------------------------

-- The track for what's on screen: the title, a battle, or the map's own.
function Scr.UpdateMusic()
    local key
    if R.title:IsShown() then key = "title"
    elseif BT.battle then key = "battle"
    elseif G.started and G.map then key = ns.AzeroSound:InnMusic() or G.map.def.music end    -- (the lute by a busy inn)
    ns.AzeroSound:Music(key)
end

function Scr.Dark(sc, a)                -- 0 = normal light, 1 = a black silhouette
    if sc.isContainer then
        if sc.spr.key then sc.spr:SetDark(a) return end
        sc = sc.scene
        if not sc then return end
    end
    sc.glow = nil                       -- (SceneLight sets the light again afterwards)
    pcall(sc.SetLightAmbientColor, sc, 0.72 * (1 - a), 0.72 * (1 - a), 0.72 * (1 - a))
    pcall(sc.SetLightDiffuseColor, sc, 0.85 * (1 - a), 0.85 * (1 - a), 0.82 * (1 - a))
end

function Scr.UpdateSpecies(dt)
    local sp, nxt = G.showSpecies, G.showNext
    local m1, m2 = R.speciesModel, R.speciesModel2
    local p = G.pending
    local evo = p and p.kind == "evolve" and p or nil
    local ev = Scr.evo
    -- the white flash fades out after the animation, over the "Congratulations!" text
    if R.evoFlash.out then
        R.evoFlash.out = R.evoFlash.out - (dt or 0)
        R.evoFlash:SetAlpha(max(0, R.evoFlash.out / 0.6))
        if R.evoFlash.out <= 0 then R.evoFlash.out = nil R.evoFlash:Hide() end
    end
    if not sp then
        m1:Hide() m2:Hide() R.evoGlow:Hide()
        Scr.evo = nil
        return
    end
    local main, other = m1, m2
    if m2.sp == sp and m1.sp ~= sp then main, other = m2, m1 end
    main:Show()
    ShowCreature(main, sp, 0.3, G.showShiny)
    if nxt and nxt ~= sp then
        other:Show()
        ShowCreature(other, nxt, 0.3, G.showShiny)
    else
        other:Hide()
    end
    if not evo then
        if ev then                                      -- over: lights back, the flash fades
            Scr.evo = nil
            ShowCreature(main, sp, 0.3, G.showShiny)
            R.evoGlow:Hide()
            if ev.flashed then R.evoFlash.out = 0.6 end
        end
        main:SetAlpha(1)
        other:SetAlpha(0)                               -- the next form loads unseen
        return
    end
    -- the animation
    if not ev or ev.p ~= evo then
        ev = { p = evo, acc = 0, which = 1, flashed = false }
        Scr.evo = ev
    end
    local t = G.EVOLVE_TIME - max(0, evo.t or 0)
    local swapFrom, swapTo = 0.5, G.EVOLVE_TIME - 0.8
    R.evoGlow:Show()
    R.evoGlow:SetAlpha(0.18 + 0.12 * math.sin(t * 6))
    local dark = min(1, t / 0.45)
    Scr.Dark(main, dark)
    if nxt then Scr.Dark(other, dark) end
    local showNew = false
    if t >= swapFrom and t < swapTo and nxt then
        local f = (t - swapFrom) / (swapTo - swapFrom)
        local period = 0.5 - 0.43 * f                 -- each form shows for less and less time
        ev.acc = ev.acc + (dt or 0)
        if ev.acc >= period then ev.acc, ev.which = 0, 3 - ev.which end
        showNew = ev.which == 2
    elseif t >= swapTo then
        showNew = true
        local f = min(1, (t - swapTo) / 0.45)
        R.evoFlash:Show()
        R.evoFlash:SetAlpha(f)
        if not ev.flashed then
            ev.flashed = true
            if PlaySound then
                local ok, played = pcall(PlaySound, 12891, "Master")
                if not ok or played == false then pcall(PlaySound, 31578, "Master") end
            end
        end
    end
    main:SetAlpha(showNew and 0 or 1)
    if nxt then other:SetAlpha(showNew and 1 or 0) end
end

function KH.OpenControls()
    local rows = {
        { "Walk", "Arrow keys or WASD" },
        { "Run", "Hold X while walking" },
        { "Talk, pick up, select", "Space, Z or E" },
        { "Back, cancel", "X, Q, Backspace, right-click" },
        { "Open the menu", "Tab or M" },
        { "Chat with guildmates", "Enter (/wave /dance /cheer /sit)" },
        { "Summary pages", "Left and Right" },
        { "Scroll a long list", "Mouse wheel" },
        { "Give the keyboard back", "Esc" },
    }
    local items = {}
    for i, r in ipairs(rows) do items[i] = { text = r[1], right = r[2] } end
    local function onOff(key) return G:Data()[key] ~= false and "On" or "Off" end
    items[#items + 1] = { text = "Music", right = onOff("music"), onSelect = function(idx, menu)
        G:Data().music = G:Data().music == false
        menu.items[idx].right = onOff("music")
        UI:RefreshMenu(menu)
        Scr.UpdateMusic()
    end }
    items[#items + 1] = { text = "Sounds", right = onOff("sfx"), onSelect = function(idx, menu)
        G:Data().sfx = G:Data().sfx == false
        menu.items[idx].right = onOff("sfx")
        UI:RefreshMenu(menu)
    end }
    items[#items + 1] = { text = "Guild chat", right = onOff("chat"), onSelect = function(idx, menu)
        G:Data().chat = G:Data().chat == false
        menu.items[idx].right = onOff("chat")
        UI:RefreshMenu(menu)
    end }
    items[#items + 1] = { text = "Chat bubbles", right = onOff("chatBubbles"), onSelect = function(idx, menu)
        G:Data().chatBubbles = G:Data().chatBubbles == false
        menu.items[idx].right = onOff("chatBubbles")
        UI:RefreshMenu(menu)
    end }
    items[#items + 1] = { text = "Ambience", right = onOff("ambience"), onSelect = function(idx, menu)
        G:Data().ambience = G:Data().ambience == false
        menu.items[idx].right = onOff("ambience")
        UI:RefreshMenu(menu)
    end }
    items[#items + 1] = { text = "Lights and shadows", right = onOff("lights"), onSelect = function(idx, menu)
        G:Data().lights = G:Data().lights == false
        menu.items[idx].right = onOff("lights")
        UI:RefreshMenu(menu)
    end }
    items[#items + 1] = { text = "Show the key hints again", onSelect = function(idx, menu)
        G:Data().keys = {}
        R.keyStrip.sig = nil
        KH.keyState.since = now
        menu.items[idx].text = "Key hints will show again"
        UI:RefreshMenu(menu)
    end }
    PushMenu(items, { x = 8, y = -8, w = SW - 16, rowH = 30, level = 70, title = "CONTROLS", desc = true,
        onCancel = function(menu) PopMenu(menu) end })
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

local KEYMAP = {
    UP = "up", W = "up", DOWN = "down", S = "down", LEFT = "left", A = "left", RIGHT = "right", D = "right",
    SPACE = "A", Z = "A", E = "A",
    X = "B", Q = "B", BACKSPACE = "B",
    ENTER = "CHAT", TAB = "START", M = "START",
}
local heldDirs = {}

local function CurrentDir()
    local best, bestAt
    for d, at in pairs(heldDirs) do
        if not bestAt or at > bestAt then best, bestAt = d, at end
    end
    return best
end

-- pause: true when focus goes because the player paused (Esc), combat started or the window closed - the game stops
-- until the next click. (The panel starts unfocused on the title screen, where nothing runs: not a pause.)
local function SetFocus(on, pause)
    if not on and KH.CloseChat then KH.CloseChat() end
    focused = on and true or false
    paused = not focused and (pause and true or paused)
    if R.pauseNote then R.pauseNote:SetText(paused and KH.PauseNote() or "") end
    if root then
        pcall(root.EnableKeyboard, root, focused)
        focusOverlay:SetShown(not focused)
    end
    wipe(heldDirs)
    G:SetDir(nil)
    G.input.run = false
end

---------------------------------------------------------------------------
-- Guild chat (Chat.lua): the chat line, the log, bubbles and emotes
---------------------------------------------------------------------------

KH.CHAT_W = 300            -- the log's width (stage px)

-- Shows `text` in a bubble box (a peer's, mine): one line up to ~190 px, wrapped past that. nil hides it.
-- `measure`: the text whose width sets the box (so "battling..." doesn't jump as its dots fill).
function KH.FitBubble(box, text, measure)
    if not text then box:Hide() return end
    if box.text ~= text then
        box.text = text
        local w = TextWidth(measure or text, 11)
        box.fs:SetWordWrap(w > 190)
        box.fs:SetWidth(w > 190 and 190 or 0)
        box.fs:SetText(text)
        local h = w > 190 and ((box.fs:GetStringHeight() or 14) + 14) or 26
        box:SetSize(floor(min(w, 190) + 22), max(26, floor(h)))
    end
    box:Show()
end

-- How an emote moves a character this frame: face, frame, lift (game pixels up; negative = down).
function KH.EmoteLook(key, face, frame)
    local e, age = ns.AzeroChat:Emote(key)
    if e == "wave" then return face, floor(age * 5) % 2 == 0 and 0 or 2, 0 end
    if e == "dance" then
        local turn = { "down", "left", "up", "right" }
        return turn[floor(age * 4) % 4 + 1], 1, math.abs(math.sin(age * 8)) * 2
    end
    if e == "cheer" then return face, 0, max(0, math.sin(age * 6)) * 4 end
    if e == "sit" then return "down", 1, -3 end
    return face, frame, 0
end

-- Can Enter open the chat line now (walking about in the world, nothing on screen)?
function KH.CanChat()
    return ns.AzeroChat:On() and not R.title:IsShown() and G:IsFree() and #stack == 0 and not uiMessage
        and not BT.battle and R.chatBox ~= nil
end

function KH.OpenChat()
    wipe(heldDirs)
    G:SetDir(nil)
    G.input.run = false
    pcall(root.EnableKeyboard, root, false)       -- the line has the keys until Enter or Esc
    R.chatBox:Show()
    R.chatBox.eb:SetText("")
    R.chatBox.eb:SetFocus()
end

function KH.CloseChat()
    local box = R.chatBox
    if not (box and box:IsShown()) then return end
    box.eb:ClearFocus()
    box:Hide()
    if focused then pcall(root.EnableKeyboard, root, true) end
end

function KH.BuildChat()
    -- the chat line along the bottom of the stage
    local box = Box(screen, SW - 16, 36, screen:GetFrameLevel() + 120)
    box:SetPoint("BOTTOMLEFT", screen, "BOTTOMLEFT", 8, 12)
    box.label = Font(box, 12, nil, true)
    box.label:SetPoint("LEFT", 12, 0)
    box.label:SetJustifyV("MIDDLE")
    box.label:SetText("Say:")
    local eb = CreateFrame("EditBox", nil, box)
    eb:SetPoint("TOPLEFT", 52, -8)
    eb:SetPoint("BOTTOMRIGHT", -12, 8)
    eb:SetAutoFocus(false)
    if eb.SetMaxLetters then eb:SetMaxLetters(ns.AzeroChat.MAX_LEN) end
    if not eb:SetFont(FONT, 15, "") then eb:SetFont(FONT_FALLBACK, 13, "") end
    eb:SetTextColor(INK[1], INK[2], INK[3])
    eb:SetScript("OnEnterPressed", function(self)
        local text = self:GetText()
        KH.CloseChat()
        if text and text ~= "" then ns.AzeroChat:Say(text) end
    end)
    eb:SetScript("OnEscapePressed", function() KH.CloseChat() end)
    box.eb = eb
    box:Hide()
    R.chatBox = box
    -- the log: the last lines, bottom left over the world, fading out a while after they arrive
    local lg = CreateFrame("Frame", nil, screen)
    lg:SetSize(KH.CHAT_W + 12, 10)
    lg:SetFrameLevel(screen:GetFrameLevel() + 110)
    lg:EnableMouse(false)
    lg.bg = Tex(lg, "BACKGROUND")
    lg.bg:SetAllPoints()
    lg.bg:SetColorTexture(0.04, 0.05, 0.07, 0.55)
    lg.fs = {}
    for i = 1, ns.AzeroChat.LOG_SHOWN do
        local fs = lg:CreateFontString(nil, "OVERLAY")
        if not fs:SetFont(FONT, 13, "OUTLINE") then fs:SetFont(FONT_FALLBACK, 11, "OUTLINE") end
        fs:SetJustifyH("LEFT")
        fs:SetWidth(KH.CHAT_W)
        fs:SetWordWrap(true)
        lg.fs[i] = fs
    end
    lg:Hide()
    R.chatLog = lg
end

-- The reel bar (Fishing.lua, pending kind "reel"): a box over the bottom of the stage with the bar, the gold patch
-- drifting with the fish, the sweeping marker and a pip for each good pull.
function KH.DrawReel()
    local p = G.pending
    local box = R.reel
    if not (p and p.kind == "reel") then
        if box then box:Hide() end
        return
    end
    local W = 300
    if not box then
        box = Box(screen, W + 40, 78, screen:GetFrameLevel() + 120)
        box.title = Font(box, 13, nil, true)
        box.title:SetPoint("TOP", 0, -10)
        box.title:SetJustifyH("CENTER")
        box.track = Tex(box, "ARTWORK", 0)
        box.track:SetSize(W, 14)
        box.track:SetPoint("TOP", 0, -34)
        box.track:SetColorTexture(0.24, 0.35, 0.53, 1)
        box.zone = Tex(box, "ARTWORK", 1)
        box.zone:SetColorTexture(0.95, 0.76, 0.24, 1)
        box.mark = Tex(box, "ARTWORK", 3)
        box.mark:SetSize(4, 22)
        box.mark:SetColorTexture(0.12, 0.13, 0.16, 1)
        box.flash = Tex(box, "ARTWORK", 2)
        box.flash:SetAllPoints(box.track)
        box.pips = {}
        for i = 1, ns.AzeroFish.REEL_NEED do
            local t = Tex(box, "ARTWORK", 1)
            t:SetSize(12, 12)
            t:SetPoint("TOP", box.track, "BOTTOM", (i - (ns.AzeroFish.REEL_NEED + 1) / 2) * 18, -6)
            box.pips[i] = t
        end
        R.reel = box
    end
    box:ClearAllPoints()                          -- (over a text box if one is open: a tip, a message)
    box:SetPoint("BOTTOM", screen, "BOTTOM", 0, uiMessage and (BOX_H + 26) or 24)
    local F = ns.AzeroFish
    local pos, mid = F.ReelAt(p, p.t)
    local zw = W * p.zone
    box.title:SetText(p.beast and "Something big! Reel it in!" or "A big one! Reel it in!")
    box.zone:ClearAllPoints()
    box.zone:SetSize(zw, 14)
    box.zone:SetPoint("LEFT", box.track, "LEFT", max(0, min(W - zw, mid * W - zw / 2)), 0)
    box.mark:ClearAllPoints()
    box.mark:SetPoint("CENTER", box.track, "LEFT", pos * W, 0)
    if p.flash then
        box.flash:SetColorTexture(p.good and 1 or 0.9, p.good and 1 or 0.25, p.good and 0.7 or 0.2, 0.45 * p.flash / 0.25)
        box.flash:Show()
    else
        box.flash:Hide()
    end
    for i, t in ipairs(box.pips) do
        if i <= p.hits then t:SetColorTexture(0.95, 0.76, 0.24, 1) else t:SetColorTexture(0.66, 0.77, 0.9, 1) end
    end
    box:Show()
end

-- Who's where (Routine.lua, pending kind "whoswhere", from an innkeeper's "Anyone seen...?"): everyone in the town,
-- what they're doing, where, and their day as a 24 h bar with the time now on it. Up / down picks, Space asks the
-- innkeeper about them, X goes back.
KH.WHOS_COLORS = { w = { 0.85, 0.66, 0.23 }, o = { 0.47, 0.69, 0.29 }, k = { 0.95, 0.93, 0.89 }, i = { 0.42, 0.5, 0.65 },
                   p = { 0.24, 0.35, 0.53 }, a = { 0.73, 0.7, 0.62 } }
KH.WHOS_LEGEND = { { "w", "Working" }, { "o", "Out and about" }, { "k", "Walking" }, { "i", "Indoors" }, { "p", "Patrol" },
                   { "a", "Away" } }
KH.WHOS_ROW, KH.WHOS_NAME, KH.WHOS_NOW = 29, 172, 190

function KH.BuildWhos()
    local f = Box(screen, SW - 16, SH - 16, screen:GetFrameLevel() + 70)
    f:SetPoint("CENTER")
    f.title = Font(f, 15, nil, true)
    f.title:SetPoint("TOPLEFT", 16, -13)
    f.clock = Font(f, 12)
    f.clock:SetPoint("TOPRIGHT", -16, -15)
    f.clock:SetJustifyH("RIGHT")
    f.rows = {}
    f.barX = 16 + KH.WHOS_NAME + KH.WHOS_NOW + 8
    f.barW = (SW - 16) - f.barX - 18
    f.legend = {}
    for i, l in ipairs(KH.WHOS_LEGEND) do
        local sw = Tex(f, "ARTWORK", 1)
        sw:SetSize(10, 9)
        local c = KH.WHOS_COLORS[l[1]]
        sw:SetColorTexture(c[1], c[2], c[3], 1)
        local fs = Font(f, 10)
        fs:SetText(l[2])
        fs:SetPoint("LEFT", sw, "RIGHT", 4, 0)
        f.legend[i] = { sw = sw, fs = fs }
    end
    f.keys = Font(f, 10)
    f.keys:SetPoint("BOTTOMLEFT", 16, 10)
    f.keys:SetText("Up / Down: pick     Space: ask where they are     X: back")
    f.ticks = {}
    for i = 0, 4 do
        local fs = Font(f, 9)
        fs:SetText(tostring(i * 6))
        f.ticks[i] = fs
    end
    f:Hide()
    R.whos = f
    return f
end

function KH.WhosRow(f, i)
    local r = f.rows[i]
    if r then return r end
    r = {}
    r.hi = Tex(f, "BACKGROUND", 5)
    r.hi:SetColorTexture(0.91, 0.87, 0.77, 1)
    r.hi:SetSize(SW - 16 - 20, KH.WHOS_ROW - 2)
    r.dot = Tex(f, "ARTWORK", 2)
    r.dot:SetSize(10, 10)
    r.name = Font(f, 12, nil, true)
    r.now = Font(f, 10)
    r.now:SetWidth(KH.WHOS_NOW)
    r.now:SetWordWrap(false)
    r.where = Font(f, 9)
    r.where:SetTextColor(0.54, 0.43, 0.12)
    r.track = Tex(f, "ARTWORK", 0)
    r.track:SetColorTexture(0.86, 0.84, 0.78, 1)
    r.track:SetSize(f.barW, 12)
    r.segs = {}
    r.nowl = Tex(f, "ARTWORK", 4)
    r.nowl:SetColorTexture(0.75, 0.22, 0.17, 1)
    r.nowl:SetSize(2, 16)
    f.rows[i] = r
    return r
end

function KH.DrawWhos()
    local f, p = R.whos, G.pending
    if not (f and p and p.kind == "whoswhere") then return end
    local town = ns.AzeroMaps[p.town]
    f.title:SetText(string.format("WHO'S WHERE  -  %s", string.upper(town and town.name or p.town)))
    local mins = floor(p.now or 0)
    f.clock:SetText(string.format("%02d:%02d  %s", floor(mins / 60), mins % 60, G:Period()))
    local top = -40
    for i, e in ipairs(p.list) do
        local r = KH.WhosRow(f, i)
        local y = top - (i - 1) * KH.WHOS_ROW
        r.hi:ClearAllPoints()
        r.hi:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y + 2)
        r.hi:SetShown(i == f.sel)
        local t = e.tint or { 1, 1, 1 }
        r.dot:SetColorTexture(t[1], t[2], t[3], 1)
        r.dot:ClearAllPoints()
        r.dot:SetPoint("TOPLEFT", f, "TOPLEFT", 16, y - 7)
        r.name:SetText(e.name)
        r.name:ClearAllPoints()
        r.name:SetPoint("TOPLEFT", f, "TOPLEFT", 31, y - 4)
        r.now:SetText(e.label)
        r.now:ClearAllPoints()
        r.now:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + KH.WHOS_NAME, y - 1)
        r.where:SetText(e.where)
        r.where:ClearAllPoints()
        r.where:SetPoint("TOPLEFT", r.now, "BOTTOMLEFT", 0, -1)
        r.track:ClearAllPoints()
        r.track:SetPoint("TOPLEFT", f, "TOPLEFT", f.barX, y - 7)
        for k, piece in ipairs(e.bar) do
            local s = r.segs[k]
            if not s then
                s = Tex(f, "ARTWORK", 1)
                r.segs[k] = s
            end
            local c = KH.WHOS_COLORS[piece[3]] or KH.WHOS_COLORS.o
            s:SetColorTexture(c[1], c[2], c[3], 1)
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", r.track, "TOPLEFT", piece[1] / 1440 * f.barW, 0)
            s:SetSize(max(1, (piece[2] - piece[1]) / 1440 * f.barW), 12)
            s:Show()
        end
        for k = #e.bar + 1, #r.segs do r.segs[k]:Hide() end
        r.nowl:ClearAllPoints()
        r.nowl:SetPoint("CENTER", r.track, "LEFT", (p.now or 0) / 1440 * f.barW, 0)
        for _, w in ipairs({ r.dot, r.name, r.now, r.where, r.track, r.nowl }) do w:Show() end
    end
    for i = #p.list + 1, #f.rows do
        local r = f.rows[i]
        for _, w in ipairs({ r.hi, r.dot, r.name, r.now, r.where, r.track, r.nowl }) do w:Hide() end
        for _, s in ipairs(r.segs) do s:Hide() end
    end
    -- the hours under the bars, then the legend
    local by = top - #p.list * KH.WHOS_ROW - 2
    for i = 0, 4 do
        f.ticks[i]:ClearAllPoints()
        f.ticks[i]:SetPoint("TOP", f, "TOPLEFT", f.barX + i / 4 * f.barW, by)
    end
    local x = 16
    for _, l in ipairs(f.legend) do
        l.sw:ClearAllPoints()
        l.sw:SetPoint("TOPLEFT", f, "TOPLEFT", x, by - 18)
        x = x + 10 + 4 + floor(TextWidth(l.fs:GetText(), 10)) + 16
    end
end

function KH.OpenWhos(p)
    local f = R.whos or KH.BuildWhos()
    f.sel = 1
    f:Show()
    ns.AzeroSound:Play("book")
    KH.DrawWhos()
end

-- Keys on the page: up / down pick someone, Space asks, X / back closes.
function KH.WhosKey(key)
    local f, p = R.whos, G.pending
    if not (f and p) then return end
    if key == "up" or key == "down" then
        f.sel = (f.sel - 1 + (key == "down" and 1 or -1)) % #p.list + 1
        ns.AzeroSound:Play("cursor")
        KH.DrawWhos()
    elseif key == "A" then
        f:Hide()
        ns.AzeroSound:Play("select")
        G:Advance(f.sel)
    elseif key == "B" then
        f:Hide()
        ns.AzeroSound:Play("back")
        G:Advance(nil)
    end
end

-- One log line as shown: [Place] Name: text (mine gold, others white-blue, the game's notes grey).
function KH.ChatLine(l)
    if l.system then return "|cffa8a8b0" .. l.text .. "|r" end
    local name = l.me and ("|cffffd34d" .. l.who .. "|r") or ("|cff9fd0ff" .. l.who .. "|r")
    local place = l.place and ("|cffc8b27a[" .. l.place .. "]|r ") or ""
    if l.emote then return place .. name .. " " .. l.text end
    return place .. name .. ": " .. l.text
end

function KH.DrawChat()
    local lg = R.chatLog
    if not lg then return end
    local Chat = ns.AzeroChat
    local typing = R.chatBox:IsShown()
    if not (G.started and not R.title:IsShown() and not BT.battle and Chat:On()) then lg:Hide() return end
    local lines = Chat:Lines(Chat.LOG_SHOWN, typing)
    if #lines == 0 then lg:Hide() return end
    -- above the chat line while typing, above a text box while one is open, else at the bottom
    local y = typing and 54 or ((G.pending or uiMessage) and (BOX_H + 26) or 12)        -- (clear of a text box's title tab)
    lg:ClearAllPoints()
    lg:SetPoint("BOTTOMLEFT", screen, "BOTTOMLEFT", 8, y)
    local n, total, top = #lg.fs, 0, 0
    for i = n, 1, -1 do
        local fs = lg.fs[i]
        local l = lines[#lines - (n - i)]
        fs:ClearAllPoints()
        if l then
            fs:SetText(KH.ChatLine(l.line))
            fs:SetAlpha(l.alpha)
            fs:SetPoint("BOTTOMLEFT", lg, "BOTTOMLEFT", 6, 4 + total)
            total = total + (fs:GetStringHeight() or 14) + 2
            top = max(top, l.alpha)
            fs:Show()
        else
            fs:Hide()
        end
    end
    lg:SetHeight(total + 4)
    lg.bg:SetAlpha(typing and 1 or top)
    lg:Show()
end

-- The pause overlay's second line: what keeps running for the guildmate on the other side ("" when nothing does).
function KH.PauseNote()
    local b, p = BT.battle, G.pending
    if b and b.pvp then return b.pvp.watch and "The match keeps playing." or "Your turn timer keeps running." end
    if p and p.kind == "trade" then return "The trade timer keeps running." end
    if (p and p.kind == "netwait") or (ns.AzeroPvP and ns.AzeroPvP.incoming)
        or (ns.AzeroTrade and ns.AzeroTrade.incoming) then
        return "The request timer keeps running."
    end
    return ""
end

-- A reference panel on top (type chart, what's new): its own keys first, then Space / X close it.
function KH.PanelKey(top, key)
    if top.onKey and top.onKey(key) then return end
    if key == "A" or key == "B" then top.opts.onCancel(top) end
end

local function HandleKey(key)
    KH.NoteKey((key == "up" or key == "down" or key == "left" or key == "right") and "move" or key)
    if key == "CHAT" then
        if KH.CanChat() then KH.OpenChat() return end
        key = "START"
    end
    if R.title:IsShown() then
        local top = stack[#stack]
        if top and top.isPanel then KH.PanelKey(top, key) elseif top then MenuKey(top, key) end
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
            Scr.SummaryKey(top, key)
            return
        end
        if top.isPanel then
            KH.PanelKey(top, key)
            return
        end
        MenuKey(top, key)
        return
    end
    if BT.battle then
        local b = BT.battle
        if key == "B" and b.pvp and b.pvp.watch and b.need ~= "done" then
            PushMenu({
                { text = "Stop watching", onSelect = function()
                    CloseAllMenus()
                    ns.AzeroWatch:Stop()
                end },
                { text = "Keep watching", onSelect = function(_, m) PopMenu(m) end },
            }, { w = 240, x = SW - 246, y = -(SH - BOX_H - 110), title = "Stop watching?",
                 onCancel = function(m) PopMenu(m) end })
            return
        end
        if key == "A" or key == "B" then TextA() end
        return
    end
    local p = G.pending
    if p then
        if p.kind == "text" and (key == "A" or key == "B") then
            if not TextA() and text.done then G:Advance() end
        elseif p.kind == "netwait" and key == "B" then
            G:Advance("cancel")
        elseif p.kind == "evolve" and key == "B" then
            G:Advance("cancel")
        elseif p.kind == "fish" then
            ns.AzeroFish:Key(G, p, key)
        elseif p.kind == "reel" then
            ns.AzeroFish:ReelKey(G, p, key)
        elseif p.kind == "whoswhere" then
            KH.WhosKey(key)
        end
        return
    end
    if key == "A" then
        G:PressA()
    elseif key == "START" and G:IsFree() then
        if not UI.tipsOff and not KH.TipSeen("back") then KH.ShowTip("back", OpenStartMenu) else OpenStartMenu() end
    end
end
UI.Press = function(k) HandleKey(k) end

local function OnKeyDown(self, key)
    if key == "ESCAPE" then
        -- the first Escape pauses: the game lets the keyboard go and the overlay shows. With the keyboard released,
        -- a second Escape reaches the client and closes DisasterZone's window as usual.
        SetFocus(false, true)
        pcall(self.SetPropagateKeyboardInput, self, false)
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
        if busy then HandleKey(k) else KH.NoteKey("move") G:SetDir(CurrentDir()) end
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
-- Sky icon: the realm clock's sun or moon, drawn as an 11x11 grid of coloured squares
---------------------------------------------------------------------------

local SKY_N, SKY_PX = 11, 2
local SKY_INK = {
    Y = { 1.00, 0.84, 0.24 }, W = { 1.00, 0.97, 0.72 }, O = { 0.96, 0.55, 0.14 }, R = { 0.82, 0.28, 0.20 },
    P = { 0.92, 0.45, 0.50 }, H = { 0.36, 0.43, 0.62 }, M = { 0.80, 0.83, 0.92 }, S = { 0.60, 0.64, 0.78 },
    E = { 0.33, 0.37, 0.55 }, K = { 0.88, 0.66, 0.18 },
}
-- one stage per stretch of the day: { from hour, name, rows }; rows read top to bottom, "." is empty. Every shape
-- has a dark rim (O / R round a sun, E round a moon): the panel behind is cream, pale fills alone vanish on it.
local SKY_STAGES = {
    { 0, "Night (full moon)", {
        "K..........", "....EEE....", "..EEMMMEE..", "..EMSMMME..", ".EMMMMMSME.", ".EMMMMMMME.",
        ".EMSSMMMME.", "..EMMMMSE..", "..EEMMMEE..", "....EEE...K", "..........." } },
    { 3, "Night (setting moon)", {
        ".K.........", "....EEE....", "....EMMEE..", "......EMME.", ".......EME.", ".K.....EME.",
        ".......EME.", "......EMME.", "....EMMEE..", "....EEE....", "..........." } },
    { 5, "Dawn", {
        "...........", "...........", ".....P.....", ".P.......P.", "....OOO....", "...OYYYO...",
        "..OYWYYYO..", ".OYYYYYYYO.", "HHHHHHHHHHH", "...OO.OOO..", ".H...HH...." } },
    { 7, "Morning", {
        ".....O.....", "...........", "....OOO....", "...OWYYO...", "..OWYYYYO..", "O.OYYYYYO.O",
        "..OYYYYYO..", "...OYYYO...", "....OOO....", "...........", ".....O....." } },
    { 10, "Midday", {
        ".....O.....", ".O.......O.", "....OOO....", "...OWYYO...", "..OWYYYYO..", "OOOYYYYYOOO",
        "..OYYYYYO..", "...OYYYO...", "....OOO....", ".O.......O.", ".....O....." } },
    { 15, "Afternoon", {
        "...........", ".R.......R.", "....RRR....", "...RYYOR...", "..RYYYOOR..", "..RYYOOOR..",
        "..ROOOOOR..", "...ROOOR...", "....RRR....", ".R.......R.", "..........." } },
    { 18, "Dusk", {
        "...........", "...........", "...........", "...........", "...........", "....RRR....",
        "..RROOORR..", ".ROOOYOOOR.", "HHHHHHHHHHH", "..RR.HH.RR.", "....R..R..." } },
    { 21, "Night (rising moon)", {
        ".........K.", "....EEE....", "..EEMME....", ".EMME......", ".EME.......", ".EME.....K.",
        ".EME.......", ".EMME......", "..EEMME....", "....EEE....", "..........." } },
}

function Scr.BuildSkyIcon(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(SKY_N * SKY_PX, SKY_N * SKY_PX)
    f.px = {}
    for i = 1, SKY_N * SKY_N do
        local t = Tex(f, "OVERLAY")
        t:SetSize(SKY_PX, SKY_PX)
        t:SetPoint("TOPLEFT", ((i - 1) % SKY_N) * SKY_PX, -floor((i - 1) / SKY_N) * SKY_PX)
        t:Hide()
        f.px[i] = t
    end
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        if not (self.stage and GameTooltip) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.stage[2], 1, 1, 1)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    f:SetScript("OnMouseDown", function(_, button)
        if button == "RightButton" and UI.Press then UI.Press("B") end
    end)
    return f
end

function Scr.SetSkyIcon(f, hour)
    local stage = SKY_STAGES[1]
    for _, s in ipairs(SKY_STAGES) do
        if hour >= s[1] then stage = s end
    end
    if f.stage == stage then return end
    f.stage = stage
    for r = 1, SKY_N do
        local row = stage[3][r]
        for c = 1, SKY_N do
            local t, ink = f.px[(r - 1) * SKY_N + c], SKY_INK[row:sub(c, c)]
            if ink then
                t:SetColorTexture(ink[1], ink[2], ink[3], 1)
                t:Show()
            else
                t:Hide()
            end
        end
    end
end

---------------------------------------------------------------------------
-- Frame update
---------------------------------------------------------------------------

local function OnUpdate(self, elapsed)
    now = now + elapsed
    FitScenes(elapsed)
    KH.UpdateKeyStrip()
    KH.DrawChat()
    KH.DrawReel()
    ns.AzeroMarks:Update(elapsed)
    if ns.AzeroAftermath then ns.AzeroAftermath:Update() end
    Scr.UpdateMusic()
    ns.AzeroSound:UpdateAmbience(elapsed, G.started and not R.title:IsShown() and not BT.battle)
    if R.title:IsShown() then KH.TickTitle(elapsed) end
    if R.title:IsShown() or not G.started then
        ns.AzeroNet:SetActive(false)
        return
    end
    -- visible with a save loaded: guildmates may see us (Net sends at most once a second)
    ns.AzeroNet:SetActive(true)
    ns.AzeroNet:Update(elapsed)
    ns.AzeroPvP:Update()
    ns.AzeroWatch:Update()
    ns.AzeroTrade:Update()
    ns.AzeroGuild:Update()
    -- Paused: the network above keeps going (guildmates wait on us), and so does a match between players (its
    -- turn timer runs on); the rest waits for the click - no walking, tips, text or battle playback.
    local live = BT.battle and BT.battle.pvp and true or false
    if paused then
        if not live and text.doneAt then text.doneAt = text.doneAt + elapsed end   -- auto text resumes in place
        R.pauseNote:SetText(KH.PauseNote())
    else
        KH.CheckTips()
    end
    -- directions pressed while a menu was open do not walk once it closes
    local busy = #stack > 0 or uiMessage
    if busy then G:SetDir(nil) elseif focused then G:SetDir(CurrentDir()) end
    if not BT.battle and not paused then G:Update(elapsed) end
    SyncPending()
    if BT.battle then
        if live or not paused then UpdateBattle(elapsed) end
    else
        DrawWorld()
        if not paused then UpdateText(elapsed) end
    end
    Scr.UpdateSpecies(elapsed)
    if R.money:IsShown() then
        local hr = G:Hour() % 24
        local p, cls = G:PerkInfo(), G:ClassFile()
        local cc = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        local className = cls and ((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls])
            or (cls:sub(1, 1) .. cls:sub(2):lower()))
        R.money.perk:SetText(p and string.format("%s: %s", className, p.name) or "")
        if cc then R.money.perk:SetTextColor(cc.r * 0.8, cc.g * 0.8, cc.b * 0.8) end
        R.money.fs:SetText(string.format("Money: %s\nBadges: %d", D.Money(G.save.money), G:BadgeCount()))
        R.money.time:SetText(string.format("Realm time %02d:%02d", math.floor(hr), math.floor((hr % 1) * 60)))
        Scr.SetSkyIcon(R.money.sky, hr)
        if #stack == 0 then R.money:Hide() end
    end
    if R.bagDesc:IsShown() and #stack == 0 then R.bagDesc:Hide() end
    if R.moveCompare:IsShown() and #stack == 0 then R.moveCompare:Hide() end
    if R.log:IsShown() and #stack == 0 then R.log:Hide() end
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function BuildBattle()
    local b = CreateFrame("Frame", nil, screen)
    b:SetSize(SW, SH)                     -- like the world: fills the stage edge to edge (FitScreen)
    b:SetPoint("CENTER")
    pcall(b.SetClipsChildren, b, true)
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

    -- where the beasts stand: the painted platforms' centres (AzeroBattleArt, game pixels x 3), or the old spots
    -- scaled to the screen's width
    local art = ns.AzeroBattleArt
    local S3 = TILE / 16
    local FOE_X, FOE_Y = floor(SW * 0.742), 178
    local ALLY_X, ALLY_Y = floor(SW * 0.258), SH - BOX_H - 22
    if art then FOE_X, FOE_Y, ALLY_X, ALLY_Y = art.foe[1] * S3, art.foe[2] * S3, art.ally[1] * S3, art.ally[2] * S3 end
    if art then
        -- the painted backdrop (sky, far trees, ground, platforms), and clouds drifting across its sky
        bg.art = Tex(b, "BACKGROUND", 2)
        bg.art:SetPoint("TOPLEFT")
        bg.art:SetSize(art.w * S3, art.h * S3)
        SetPixelTexture(bg.art, MEDIA .. "Ground\\battle_" .. art.outdoor)
        bg.art:SetTexCoord(0, art.w / 256, 0, art.h / 256)
        bg.clouds = Tex(b, "BACKGROUND", 3)
        bg.clouds:SetPoint("TOPLEFT")
        bg.clouds:SetSize(art.w * S3, 48 * S3)
        if not pcall(bg.clouds.SetTexture, bg.clouds, MEDIA .. "Ground\\battle_clouds", "REPEAT", "CLAMP", "NEAREST") then
            bg.clouds:SetTexture(MEDIA .. "Ground\\battle_clouds")
        end
        bg.clouds:SetAlpha(0.9)
    end
    b:SetScript("OnUpdate", function(_, elapsed)
        if bg.clouds and bg.clouds:IsShown() then
            local u = (now * 2) / 256
            bg.clouds:SetTexCoord(-u, art.w / 256 - u, 0, 1)
        end
        ns.AzeroBattleScene.Update(elapsed)                          -- (battles where you stand, 0.45)
    end)
    local fp = Tex(b, "BORDER")
    fp:SetSize(240, 60)
    fp:SetPoint("CENTER", b, "TOPLEFT", FOE_X, -FOE_Y)
    local ap = Tex(b, "BORDER")
    ap:SetSize(280, 70)
    ap:SetPoint("CENTER", b, "TOPLEFT", ALLY_X, -ALLY_Y)
    bg.platforms = { fp, ap }
    -- sky tint for outdoor battles (above the backdrop, below the creatures, which are child frames)
    R.battleSky = Tex(b, "BORDER", 7)
    R.battleSky:SetAllPoints()
    R.battleSky:Hide()

    R.foeModel = NewModel(b, 200, 190)
    R.foeModel.baseX, R.foeModel.baseY = FOE_X - 100, -FOE_Y - 22
    R.foeModel.groundY = R.foeModel.baseY
    R.foeModel:SetPoint("BOTTOMLEFT", b, "TOPLEFT", R.foeModel.baseX, R.foeModel.baseY)
    R.foeModel:SetFrameLevel(b:GetFrameLevel() + 2)
    R.foeModel.pixelScale, R.foeModel.spriteLift = 3, 10        -- feet 12 px below the platform's centre
    R.allyModel = NewModel(b, 250, 250)
    R.allyModel.camScale = 1.1
    R.allyModel.view, R.allyModel.pixelScale, R.allyModel.spriteLift = "a", 3, -2
    R.allyModel.baseX, R.allyModel.baseY = ALLY_X - 125, -ALLY_Y - 16
    R.allyModel.groundY = R.allyModel.baseY
    R.allyModel:SetPoint("BOTTOMLEFT", b, "TOPLEFT", R.allyModel.baseX, R.allyModel.baseY)
    R.allyModel:SetFrameLevel(b:GetFrameLevel() + 2)
    -- 0.41: the moves' effects (Fx.lua) draw on frames of this layer; a shake moves the backdrop with them
    ns.AzeroFx.Attach(b, R.foeModel, R.allyModel, {
        play = function(name, arg) ns.AzeroSound:Play(name, arg) end,
        anim = function(m, id) Anim(m, id) end,
        scene = function(dx, dy)
            for _, t in ipairs({ bg.art, bg.clouds }) do
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", b, "TOPLEFT", dx, dy)
            end
            ns.AzeroBattleScene.Shake(dx, dy)                        -- (the layered scene shakes the same)
        end,
        punch = function(side, amp) ns.AzeroBattleScene.Punch(side, amp) end,
        shakeOn = function() return not G:Data().noShake end,
        -- an interrupted cast's bar turns red, shakes and drops away; put back once it hides (Scr.SetCastBar)
        castBar = function(side, p)
            local bar, box = R[side .. "Cast"], R[side .. "Box"]
            if not bar then return end
            local function place(dx, dy)
                bar:ClearAllPoints()
                if side == "foe" then bar:SetPoint("TOPLEFT", box, "BOTTOMLEFT", dx, -6 + dy)
                else bar:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", dx, 6 + dy) end
            end
            bar.restore = function() bar.restore = nil place(0, 0) bar:SetAlpha(1) end
            place(p < 0.4 and (floor(p * 30) % 2 == 0 and -3 or 3) or 0, -8 * p * p)
            bar:SetAlpha(1 - p)
            bar.edge:SetColorTexture(0.88, 0.34, 0.29, 1)
        end,
    })
    -- 0.45: battles where you stand (BattleScene.lua): the layered scene, the beasts' light, the push-in on a hit
    ns.AzeroBattleScene.Build(b, S3, SetPixelTexture, {
        bleed = function() return R.bleed or 1 end,
        models = function() return R.foeModel, R.allyModel end,
        drift = function(dx, dy) ns.AzeroFx.Drift(dx, dy) end,
        shakeOn = function() return not G:Data().noShake end,
    })

    -- HP boxes, laid out like the GBA games: name + type, level, status; an "HP" tag and bar;
    -- the player's box adds HP numbers and the EXP bar.
    -- row 1: name (cut off with "..." before it can reach the level) and level; row 2: the effect chips
    -- (Chips.Layout); row 3: HP (and the numbers on the player's side); the player's EXP along the bottom
    local function info(w, h, withNumbers)
        local f = Box(b, w, h, b:GetFrameLevel() + 5)
        f.lvl = Font(f, 14, nil, true) f.lvl:SetPoint("TOPRIGHT", -16, -12) f.lvl:SetJustifyH("RIGHT")
        f.name = Font(f, 15, nil, true) f.name:SetPoint("TOPLEFT", 16, -12)
        f.name:SetWidth(w - 32 - 58)
        f.name:SetWordWrap(false)
        f.star = Tex(f, "OVERLAY", 3)             -- a shiny
        f.star:SetTexture(Scr.SPARKLE_TEX)
        f.star:SetSize(14, 14)
        f.star:SetPoint("RIGHT", f.lvl, "LEFT", -4, 0)
        f.star:Hide()
        f.chipY, f.chipRoom = -35, w - 32
        local tag = CreateFrame("Frame", nil, f)
        tag:SetSize(30, 14)
        tag:SetPoint("TOPLEFT", 16, -57)
        Rounded(tag, 0, 2, 0.30, 0.30, 0.34, 0, "ARTWORK")
        local hpl = tag:CreateFontString(nil, "OVERLAY")
        if not hpl:SetFont(FONT_BOLD, 11, "") then hpl:SetFont(FONT_FALLBACK, 9, "") end
        hpl:SetPoint("CENTER", 0, 1)
        hpl:SetText("HP")
        hpl:SetTextColor(0.98, 0.72, 0.18)
        f.hp = Bar(f, withNumbers and (w - 64 - 78) or (w - 64), 10)
        f.hp.bg:SetPoint("LEFT", tag, "RIGHT", 2, 0)
        if withNumbers then
            f.hpText = Font(f, 13) f.hpText:SetPoint("RIGHT", f, "TOPRIGHT", -16, -64) f.hpText:SetJustifyH("RIGHT")
            local el = Font(f, 10, nil, true) el:SetPoint("BOTTOMLEFT", 16, 10) el:SetText("EXP")
            el:SetTextColor(0.25, 0.45, 0.75)
            f.exp = Bar(f, w - 70, 6)
            f.exp.bg:SetPoint("BOTTOMRIGHT", -16, 12)
        end
        f:Hide()
        return f
    end
    R.foeBox = info(280, 82)
    R.foeBox:SetPoint("TOPLEFT", b, "TOPLEFT", 14, -14)
    R.allyBox = info(280, 102, true)
    R.allyBox:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -10, BOX_H + 8)
    -- a cast being readied: under the foe's box, over yours
    R.foeCast = Scr.CastBar(b)
    R.foeCast:SetPoint("TOPLEFT", R.foeBox, "BOTTOMLEFT", 0, -6)
    R.foeCast:SetFrameLevel(R.foeBox:GetFrameLevel() + 1)
    R.allyCast = Scr.CastBar(b)
    R.allyCast:SetPoint("BOTTOMRIGHT", R.allyBox, "TOPRIGHT", 0, 6)     -- (grows to the left, away from the edge)
    R.allyCast:SetFrameLevel(R.allyBox:GetFrameLevel() + 1)

    R.net = Tex(b, "OVERLAY", 3)
    R.net:SetSize(34, 34)
    R.net:SetTexture("Interface\\Icons\\Ability_Hunter_BeastTaming")
    R.net:Hide()

    -- on the screen like the menus and text box, not the battle layer (that one is scaled past the stage and clips)
    -- the move box: PP and cooldown, type and role, power, the effect against this foe, one note (coach / what it does)
    R.moveInfo = Box(screen, 200, BOX_H, 75)
    R.moveInfo:SetPoint("BOTTOMRIGHT", screen, "BOTTOMRIGHT", 0, 0)
    R.moveInfo.pp = Font(R.moveInfo, 15, nil, true)
    R.moveInfo.pp:SetPoint("TOPLEFT", 16, -12)
    R.moveInfo.cd = Font(R.moveInfo, 12, nil, true)
    R.moveInfo.cd:SetPoint("TOPRIGHT", -16, -14)
    R.moveInfo.glass = Scr.Hourglass(R.moveInfo, 2)                  -- its rest after use: the hourglass and the turns
    R.moveInfo.glass:SetPoint("RIGHT", R.moveInfo.cd, "LEFT", -4, 1)
    R.moveInfo.glass:Hide()
    R.moveInfo.type = Pill(R.moveInfo, 80, 20, 16)
    R.moveInfo.type:SetPoint("TOPLEFT", 16, -34)
    R.moveInfo.role = Pill(R.moveInfo, 84, 20, 13)
    R.moveInfo.role:SetPoint("TOPLEFT", 100, -34)
    R.moveInfo.power = Font(R.moveInfo, 13)
    R.moveInfo.power:SetPoint("TOPLEFT", 16, -62)
    R.moveInfo.eff = Font(R.moveInfo, 12, nil, true)            -- against this foe (KH.EffectText)
    R.moveInfo.eff:SetPoint("TOPLEFT", 16, -84)
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
    -- the clip is the stage's: the world / battle / title reach a little past the screen to meet its edges
    pcall(root.SetClipsChildren, root, true)
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
    R.textbox:SetScript("OnMouseDown", function(_, button)
        if button == "RightButton" then HandleKey("B") return end
        -- a click on the box only moves the text on: with a menu open (the battle's FIGHT / BAG / PARTY / RUN under
        -- "What will X do?") Space would pick its highlighted entry, so the click does nothing
        if uiMessage then HandleKey("A") return end
        if #stack > 0 then return end
        if (G.pending and G.pending.kind == "text") or (BT.battle and text.full) then HandleKey("A") end
    end)
    R.textbox:Hide()

    -- species portrait (starter choice, evolution)
    R.speciesModel = NewModel(screen, 220, 220)
    R.speciesModel:SetPoint("BOTTOM", screen, "BOTTOM", 0, BOX_H + 10)
    R.speciesModel:SetFrameLevel(screen:GetFrameLevel() + 45)
    R.speciesModel:Hide()
    R.speciesModel2 = NewModel(screen, 220, 220)                   -- the next form (evolution)
    R.speciesModel2:SetPoint("BOTTOM", screen, "BOTTOM", 0, BOX_H + 10)
    R.speciesModel2:SetFrameLevel(screen:GetFrameLevel() + 45)
    R.speciesModel2:Hide()
    local glow = CreateFrame("Frame", nil, screen)                  -- the evolution light behind the beast
    glow:SetAllPoints(root)
    glow:SetFrameLevel(screen:GetFrameLevel() + 44)
    glow.t = Tex(glow, "BACKGROUND")
    glow.t:SetAllPoints()
    glow.t:SetColorTexture(1, 1, 1, 1)
    glow:Hide()
    R.evoGlow = glow
    local flash = CreateFrame("Frame", nil, screen)                 -- and the white flash in front of it
    flash:SetAllPoints(root)
    flash:SetFrameLevel(screen:GetFrameLevel() + 47)
    flash.t = Tex(flash, "OVERLAY")
    flash.t:SetAllPoints()
    flash.t:SetColorTexture(1, 1, 1, 1)
    flash:Hide()
    R.evoFlash = flash

    -- money / descriptions / summary / log
    R.money = Box(screen, 230, 108, screen:GetFrameLevel() + 58)
    R.money:SetPoint("TOPLEFT", 8, -8)
    R.money.fs = Font(R.money, 15)
    R.money.fs:SetPoint("TOPLEFT", 16, -14)
    -- the realm clock, with a pixel sun or moon for the time of day after it (Scr.SetSkyIcon)
    R.money.time = Font(R.money, 15)
    R.money.time:SetPoint("TOPLEFT", R.money.fs, "BOTTOMLEFT", 0, 0)
    R.money.sky = Scr.BuildSkyIcon(R.money)
    R.money.sky:SetPoint("LEFT", R.money.time, "RIGHT", 6, 1)
    -- the class perk: one line in the class colour, the whole story on hover
    R.money.perk = Font(R.money, 15)
    R.money.perk:SetPoint("TOPLEFT", R.money.time, "BOTTOMLEFT", 0, -2)
    R.money:SetScript("OnEnter", function(self)
        local p = G:PerkInfo()
        if not (p and GameTooltip) then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText(p.name, ns.Style:Color("GOLD"))
        GameTooltip:AddLine(p.text, 1, 1, 1, true)
        GameTooltip:AddLine("Your WoW class's perk. It never counts in battles between players.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    R.money:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    R.money:Hide()

    R.bagDesc = Box(screen, SW, 80, screen:GetFrameLevel() + 75)
    R.bagDesc:SetPoint("BOTTOMLEFT")
    R.bagDesc.fs = Font(R.bagDesc, 15)
    R.bagDesc.fs:SetPoint("TOPLEFT", 18, -18)
    R.bagDesc.fs:SetPoint("BOTTOMRIGHT", -18, 12)
    R.bagDesc:Hide()

    -- two move cards side by side (see MoveCard), as tall as the text box
    local mc = Box(screen, SW, BOX_H, screen:GetFrameLevel() + 75)
    mc:SetPoint("BOTTOMLEFT")
    mc.cards = {}
    for i = 1, 2 do
        local x0, cw = (i == 1) and 18 or (SW / 2 + 10), SW / 2 - 28
        local c = {}
        c.label = Font(mc, 13)
        c.label:SetPoint("TOPLEFT", x0, -12)
        c.label:SetTextColor(0.20, 0.36, 0.62)
        c.pill = Pill(mc, 64, 18, 14)
        c.pill:SetPoint("TOPRIGHT", mc, "TOPLEFT", x0 + cw, -12)
        c.name = Font(mc, 15, nil, true)
        c.name:SetPoint("TOPLEFT", x0, -28)
        c.stats = Font(mc, 13)
        c.stats:SetPoint("TOPLEFT", x0, -50)
        c.effect = Font(mc, 13)                                  -- (two lines at most: they end above the rim)
        c.effect:SetPoint("TOPLEFT", x0, -69)
        c.effect:SetWidth(cw)
        c.effect:SetJustifyH("LEFT")
        if c.effect.SetMaxLines then c.effect:SetMaxLines(2) end
        c.effect:SetTextColor(0.36, 0.42, 0.55)
        mc.cards[i] = c
    end
    local divider = Tex(mc, "ARTWORK")
    divider:SetColorTexture(0.56, 0.74, 0.86, 1)
    divider:SetSize(2, BOX_H - 24)
    divider:SetPoint("TOP", mc, "TOP", 0, -12)
    mc:Hide()
    R.moveCompare = mc

    R.summary = Box(screen, SW - 20, SH - 20, screen:GetFrameLevel() + 90)
    R.summary:SetPoint("CENTER")
    R.summary.noPool = true
    R.summary.title = Font(R.summary, 18, nil, true)
    R.summary.title:SetPoint("TOPLEFT", 22, -20)
    R.summary.title:SetTextColor(0.20, 0.36, 0.62)
    R.summary.star = Tex(R.summary, "OVERLAY", 3)
    R.summary.star:SetTexture(Scr.SPARKLE_TEX)
    R.summary.star:SetSize(20, 20)
    R.summary.star:SetPoint("LEFT", R.summary.title, "RIGHT", 6, 0)
    R.summary.star:Hide()
    R.summary.body = Font(R.summary, 13)
    R.summary.body:SetPoint("TOPLEFT", 22, -58)
    R.summary.body:SetWidth(290)
    R.summary.body:SetSpacing(6)
    R.summary.model = NewModel(R.summary, 200, 240)
    R.summary.model:SetPoint("TOPRIGHT", -14, -40)
    local hint = Font(R.summary, 12)
    hint:SetPoint("BOTTOMRIGHT", -18, 14)
    hint:SetJustifyH("RIGHT")
    hint:SetText("Space / X: close")
    R.summary.hint = hint
    R.summary.tabs = Font(R.summary, 13, nil, true)
    R.summary.tabs:SetPoint("TOPRIGHT", -22, -26)
    R.summary.tabs:SetJustifyH("RIGHT")

    -- the gear page: slot cells down both sides (WoW's empty-slot icons), the chosen slot and the totals below
    local sw = SW - 20
    local gp = CreateFrame("Frame", nil, R.summary)
    gp:SetAllPoints()
    R.summary.gear = gp
    R.summary.cells = {}
    for i, slot in ipairs(Scr.GEAR_ORDER) do
        local col, row = (i <= 3) and 0 or 1, (i - 1) % 3
        local cell = CreateFrame("Button", nil, gp)
        cell:SetSize(76, 64)
        cell:SetPoint("TOPLEFT", R.summary, "TOPLEFT", col == 0 and 18 or (sw - 18 - 76), -64 - row * 80)
        local back = Tex(cell, "BACKGROUND")
        back:SetSize(46, 46)
        back:SetPoint("TOP", 0, 0)
        back:SetColorTexture(0.56, 0.74, 0.86, 1)
        cell.back = back
        local inner = Tex(cell, "BORDER")
        inner:SetSize(42, 42)
        inner:SetPoint("CENTER", back, "CENTER")
        inner:SetColorTexture(0.12, 0.13, 0.16, 1)
        cell.empty = Tex(cell, "ARTWORK")
        cell.empty:SetSize(40, 40)
        cell.empty:SetPoint("CENTER", back, "CENTER")
        cell.empty:SetTexture(Scr.EmptySlotTexture(slot))
        cell.icon = Tex(cell, "OVERLAY")
        cell.icon:SetSize(40, 40)
        cell.icon:SetPoint("CENTER", back, "CENTER")
        cell.label = Font(cell, 11)
        cell.label:SetPoint("TOP", back, "BOTTOM", 0, -3)
        cell.label:SetJustifyH("CENTER")
        cell.label:SetText(Scr.SlotName(slot))
        function cell:Select(on)
            if on then
                self.back:SetColorTexture(0.92, 0.66, 0.08, 1)
                self.label:SetTextColor(0.20, 0.36, 0.62)
            else
                self.back:SetColorTexture(0.56, 0.74, 0.86, 1)
                self.label:SetTextColor(INK[1], INK[2], INK[3])
            end
        end
        cell:SetScript("OnEnter", function()
            if uiMessage then return end
            local top = stack[#stack]
            if top and top.isSummary and top.summary.page == "gear" then
                top.summary.cursor = i
                Scr.RenderSummary(top.summary)
            end
        end)
        cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        cell:SetScript("OnClick", function(_, button)
            if button == "RightButton" then UI.Press("B") return end
            if uiMessage then return end
            local top = stack[#stack]
            if top and top.isSummary and top.summary.page == "gear" then
                top.summary.cursor = i
                Scr.GearSlotAct(top.summary)
            end
        end)
        R.summary.cells[i] = cell
    end
    R.summary.detail = Font(gp, 13)
    R.summary.detail:SetPoint("TOPLEFT", R.summary, "TOPLEFT", 22, -300)
    R.summary.detail:SetWidth(sw - 44)
    R.summary.totals = Font(gp, 13)
    R.summary.totals:SetPoint("TOPLEFT", R.summary, "TOPLEFT", 22, -328)      -- up to two lines, above the hint
    R.summary.totals:SetWidth(sw - 44)
    R.summary.totals:SetTextColor(0.36, 0.42, 0.55)
    gp:Hide()
    R.summary:Hide()

    -- the trade screen: two cards (model, name, type, level and original trainer, moves), a status line, a hint
    local tr = Box(screen, SW, SH, screen:GetFrameLevel() + 85)
    tr:SetPoint("CENTER")
    tr.noPool = true
    tr.title = Font(tr, 18, nil, true)
    tr.title:SetPoint("TOPLEFT", 22, -16)
    tr.title:SetTextColor(0.20, 0.36, 0.62)
    tr.cards = {}
    local cw = (SW - 36) / 2
    for i = 1, 2 do
        local card = Box(tr, cw, 244, tr:GetFrameLevel() + 2)
        card:SetPoint("TOPLEFT", tr, "TOPLEFT", 12 + (i - 1) * (cw + 12), -44)
        local c = { frame = card }
        c.label = Font(card, 13)
        c.label:SetPoint("TOPLEFT", 14, -12)
        c.label:SetTextColor(0.20, 0.36, 0.62)
        c.model = NewModel(card, cw - 28, 100)
        c.model:SetPoint("TOP", card, "TOP", 0, -30)
        c.model:SetFrameLevel(card:GetFrameLevel() + 2)
        c.name = Font(card, 15, nil, true)
        c.name:SetPoint("TOPLEFT", 14, -136)
        c.star = Tex(card, "OVERLAY", 3)
        c.star:SetTexture(Scr.SPARKLE_TEX)
        c.star:SetSize(16, 16)
        c.star:SetPoint("LEFT", c.name, "RIGHT", 4, 0)
        c.star:Hide()
        c.pill = Pill(card, 64, 18, 14)
        c.pill:SetPoint("TOPRIGHT", -14, -136)
        c.info = Font(card, 13)
        c.info:SetPoint("TOPLEFT", 14, -160)
        c.moves = Font(card, 13)
        c.moves:SetPoint("TOPLEFT", 14, -182)
        c.moves:SetWidth(cw - 28)
        c.moves:SetTextColor(0.36, 0.42, 0.55)
        c.items = Font(card, 12)                                   -- items offered with the beast
        c.items:SetPoint("TOPLEFT", 14, -222)
        c.items:SetWidth(cw - 28)
        c.items:SetWordWrap(false)
        c.items:SetTextColor(0.55, 0.40, 0.10)
        tr.cards[i] = c
    end
    tr.status = Font(tr, 13)
    tr.status:SetPoint("TOPLEFT", 22, -298)
    tr.status:SetWidth(SW - 44 - 200)
    local hint = Font(tr, 12)
    hint:SetPoint("BOTTOMLEFT", 22, 18)
    hint:SetWidth(SW - 44 - 200)
    hint:SetText("Beasts keep their original trainer (OT). A traded beast earns boosted experience.")
    hint:SetTextColor(0.36, 0.42, 0.55)
    tr:Hide()
    R.trade = tr
    ns.AzeroTrade.onChange = Scr.RefreshTrade

    R.log = Box(screen, SW - 292, SH - 16, screen:GetFrameLevel() + 65)   -- right of the 270-wide list
    R.log:SetPoint("TOPRIGHT", -8, -8)
    R.log.model = NewModel(R.log, 220, 200)
    R.log.model:SetPoint("TOP", 0, -14)
    R.log.body = Font(R.log, 14)
    R.log.body:SetPoint("TOPLEFT", 16, -220)
    R.log.body:SetPoint("BOTTOMRIGHT", -16, 12)
    R.log:Hide()

    -- title: the game's own zones playing behind (the Games poster's film, Poster.lua; made on first show), dark
    -- bands top and bottom, the baked logo (gen_azeromon_title.py) with its ribbon, and the menu as one row along
    -- the bottom
    R.title = CreateFrame("Frame", nil, screen)
    R.title:SetSize(SW, SH)
    R.title:SetPoint("CENTER")
    pcall(R.title.SetClipsChildren, R.title, true)
    R.title:SetFrameLevel(screen:GetFrameLevel() + 30)
    local tbg = Tex(R.title, "BACKGROUND")
    tbg:SetAllPoints()
    tbg:SetColorTexture(0.12, 0.2, 0.35, 1)                          -- (under the film: shows if it can't play)
    local front = CreateFrame("Frame", nil, R.title)
    front:SetAllPoints()
    front:SetFrameLevel(R.title:GetFrameLevel() + 10)
    R.titleFront = front
    local function Band(point, h, a)
        local t = Tex(front, "BACKGROUND")
        t:SetTexture(MEDIA .. "title_shade")
        t:SetVertexColor(0.02, 0.03, 0.07, a)
        t:SetPoint(point .. "LEFT")
        t:SetPoint(point .. "RIGHT")
        t:SetHeight(h)
        if point == "BOTTOM" then t:SetTexCoord(0, 1, 1, 0) end       -- (the ramp fades upward)
        return t
    end
    Band("TOP", 190, 0.7)
    Band("BOTTOM", 150, 0.8)
    local TA = KH.TITLE_ART
    local glow = Tex(front, "BORDER")
    glow:SetTexture(Amb.GLOW)
    pcall(glow.SetBlendMode, glow, "ADD")
    glow:SetVertexColor(1, 0.72, 0.28, 0.28)
    glow:SetSize(TA.w * TA.scale * 1.25, TA.h * TA.scale * 1.1)
    local logo = Tex(front, "ARTWORK")
    SetPixelTexture(logo, MEDIA .. "title_logo")
    logo:SetTexCoord(0, TA.w / TA.texW, 0, TA.h / TA.texH)
    logo:SetSize(TA.w * TA.scale, TA.h * TA.scale)
    logo:SetPoint("TOP", 0, -TA.top)
    glow:SetPoint("CENTER", logo, "CENTER", 0, 8)
    local rb = TA.ribbon
    local sub = front:CreateFontString(nil, "OVERLAY")
    if not sub:SetFont(FONT_BOLD, 13, "") then sub:SetFont(FONT_FALLBACK, 13, "") end
    sub:SetText("TAME THE BEASTS OF AZEROTH")
    sub:SetTextColor(1, 0.93, 0.78)
    sub:SetPoint("CENTER", logo, "TOPLEFT", (rb[1] + rb[3] / 2) * TA.scale, -(rb[2] + (rb[4] - 3) / 2) * TA.scale + 1)
    R.titleLogo, R.titleGlow = logo, glow
    local credit = front:CreateFontString(nil, "OVERLAY")
    credit:SetFont(FONT, 8, "")
    credit:SetTextColor(0.62, 0.66, 0.76, 0.85)
    credit:SetPoint("BOTTOM", 0, 6)
    credit:SetText("Pixel art: Tiny 16 by Lanea Zimmerman (Sharm), CC-BY  |  Tiles: Red_Voxel, CC-BY-SA  |  Font: Pixelify Sans (OFL)")
    local ver = front:CreateFontString(nil, "OVERLAY")
    ver:SetFont(FONT, 10, "")
    ver:SetTextColor(0.78, 0.82, 0.92, 0.8)
    ver:SetPoint("TOPRIGHT", -10, -8)
    local latest = ns.AzeroChangelog and ns.AzeroChangelog[1]
    ver:SetText(latest and ("v" .. latest.version) or "")
    -- (the keys: the key strip and CONTROLS explain them)

    -- focus overlay
    focusOverlay = CreateFrame("Button", nil, root)
    focusOverlay:SetAllPoints(root)                                -- (the whole stage, not the fitted screen)
    focusOverlay:SetFrameLevel(screen:GetFrameLevel() + 120)
    local dim = Tex(focusOverlay, "BACKGROUND")
    dim:SetAllPoints()
    dim:SetColorTexture(0, 0, 0, 0.55)
    local fl = focusOverlay:CreateFontString(nil, "OVERLAY")
    fl:SetFont(FONT, 16, "OUTLINE")
    fl:SetText("PAUSED")
    fl:SetTextColor(1, 0.9, 0.5)
    fl:SetPoint("CENTER")
    local fl2 = focusOverlay:CreateFontString(nil, "OVERLAY")
    fl2:SetFont(FONT, 10, "OUTLINE")
    fl2:SetText("Click to play. The game takes the keyboard while it is active; Esc pauses it, Esc again closes DisasterZone.")
    fl2:SetPoint("TOP", fl, "BOTTOM", 0, -8)
    -- what keeps running while paused (a PvP turn timer, a trade): KH.PauseNote, set every frame while paused
    R.pauseNote = focusOverlay:CreateFontString(nil, "OVERLAY")
    R.pauseNote:SetFont(FONT, 10, "OUTLINE")
    R.pauseNote:SetTextColor(1, 0.72, 0.45)
    R.pauseNote:SetPoint("TOP", fl2, "BOTTOM", 0, -6)
    R.pauseNote:SetText("")
    focusOverlay:SetScript("OnClick", function()
        if InCombatLockdown() then ns:Print("Azeromon waits until you leave combat.") return end
        SetFocus(true)
    end)

    root:SetScript("OnKeyDown", OnKeyDown)
    root:SetScript("OnKeyUp", OnKeyUp)
    root:SetScript("OnUpdate", OnUpdate)
    -- the game keeps its 11 x 9 tiles and scales evenly (never stretched) to the largest size its space allows
    local ks = CreateFrame("Frame", nil, root)
    ks:SetSize(SW, 22)
    ks.bg = Tex(ks, "BACKGROUND")
    ks.bg:SetAllPoints()
    ks.bg:SetColorTexture(0.05, 0.05, 0.07, 0.75)
    ks.parts = {}
    for i = 1, 5 do
        local fs = Font(ks, 11)
        fs:SetTextColor(0.88, 0.88, 0.92)
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
        fs:SetJustifyV("MIDDLE")
        ks.parts[i] = { pill = Pill(ks, 52, 16, 12), fs = fs }
    end
    ks:EnableMouse(false)
    ks:Hide()
    R.keyStrip = ks
    KH.BuildChat()

    -- The text boxes and menus fit inside the stage (the smaller scale); the world, the battle and the title screen
    -- scale on up to the larger one so they meet all four edges (a few game pixels cut off, no dark bars). Past
    -- BLEED_MAX the stage's shape is too far off: they stop there and the bars come back.
    local BLEED_MAX = 1.05
    local function FitScreen(w, h)
        w, h = w or root:GetWidth(), h or root:GetHeight()
        if w and h and w > 0 and h > 0 then
            local fit = max(0.3, min(w / SW, h / SH))
            screen:SetScale(fit)
            local k = min(BLEED_MAX, max(1, max(w / SW, h / SH) / fit))
            R.bleed = k
            world:SetScale(k)
            R.battle:SetScale(k)
            R.title:SetScale(k)
            if ns.AzeroWorld.frame then ns.AzeroWorld:Fit(w / (fit * k), h / (fit * k), k) end
        end
        KH.PlaceKeyStrip(h)
    end
    root:SetScript("OnSizeChanged", function(self, w, h) FitScreen(w, h) end)
    UI._Fit = function(w, h) FitScreen(w, h) return screen:GetScale() end
    root:SetScript("OnHide", function() SetFocus(false, true) ns.AzeroNet:SetActive(false) ns.AzeroSound:Stop()
        ns.AzeroSound:StopAmbience() end)

    root.OnGameShown = function()
        FitScreen()
        if not G.started then ShowTitle() end
    end
    root.OnGameHidden = function() SetFocus(false, true) ns.AzeroNet:SetActive(false) ns.AzeroSound:Stop()
        ns.AzeroSound:StopAmbience() end
    SetFocus(false)
    ShowTitle()
    return root
end

function UI:OnInit()
    ns:On("GAMES_COMBAT", function(inCombat)
        if inCombat then SetFocus(false, true) end
    end)
    ns:RegisterSlash("azeromon", function(rest)
        local cmd, a, b = (rest or ""):match("^%s*(%S*)%s*(%S*)%s*(%S*)")
        cmd = (cmd or ""):lower()
        local d = G:Data()
        if cmd == "flip" then
            d.flipFacing = not d.flipFacing
            ns:Print("Azeromon: battle models turned the other way.")
        elseif cmd == "coach" then
            -- /dz azeromon coach on | off | auto: the move box's coach line (auto = until your first badge)
            local want = (a or ""):lower()
            if want == "on" then d.coach = true elseif want == "off" then d.coach = false else d.coach = nil end
            ns:Print("Azeromon: the coach is %s.", d.coach == nil and "on until your first badge"
                or (d.coach and "on" or "off"))
        elseif cmd == "shake" then
            -- /dz azeromon shake on | off: big hits shake the battle scene (the boxes never move)
            local want = (a or ""):lower()
            d.noShake = (want == "off") or (want ~= "on" and not d.noShake) or nil
            ns:Print("Azeromon: big hits %s the battle scene.", d.noShake and "no longer shake" or "shake")
        elseif cmd == "sky" then
            -- /dz azeromon sky day | dawn | dusk | night | rain | clear | auto: try the light at any hour, until
            -- /reload (the realm clock and the weather slot take over again with "auto")
            local want = (a or ""):lower()
            local HOURS = { day = 12, dawn = 6, dusk = 19, night = 23 }
            if HOURS[want] then G.clockHour = HOURS[want]
            elseif want == "rain" then G.forceRain = true
            elseif want == "clear" then G.forceRain = false
            elseif want == "auto" then G.clockHour, G.forceRain = nil, nil
            else ns:Print("Azeromon: /dz azeromon sky day | dawn | dusk | night | rain | clear | auto") return end
            ns:Print("Azeromon: the sky is %s%s.", G.clockHour and ("at " .. G:Period()) or "on the realm clock",
                G.forceRain == nil and "" or (G.forceRain and ", raining" or ", dry"))
        elseif cmd == "look" then
            -- /dz azeromon look 3d | pixel: the beasts as their 3D models or as pixel art (the default)
            local want = (a or ""):lower()
            d.models3d = (want == "3d") or (want ~= "pixel" and not d.models3d)
            ns:Print("Azeromon: beasts are drawn as %s.", d.models3d and "3D models" or "pixel art")
        elseif cmd == "models" then
            -- what the auto-fit measured for the models on screen (paste this if a creature looks wrong)
            for label, c in pairs({ enemy = R.foeModel, yours = R.allyModel }) do
                local m = c and c.scene
                if c and c.spr and c.spr.key then
                    local st = c.spr:State()
                    ns:Print("Azeromon %s: %s pixel art (%s, x%d)", label, st.key, st.view == "a" and "back" or "front", st.scale or 0)
                    m = nil
                end
                if m and m.isScene and m.sp and m.fit then
                    ns:Print("Azeromon %s: %s still being measured (loaded: %s, %.1f s)", label, m.sp,
                        m.fit.ready and "yes" or "not yet", m.fit.age or 0)
                elseif m and m.isScene and m.sp and m.fitInfo and m.fitInfo.gaveUp then
                    ns:Print("Azeromon %s: %s shown unfitted (the client gave no size for this model)", label, m.sp)
                elseif m and m.isScene and m.sp then
                    local function fmt(b) return b and string.format("%.2f %.2f %.2f / %.2f %.2f %.2f", unpack(b)) or "none" end
                    local fi = m.fitInfo
                    ns:Print("Azeromon %s: %s scale=%.3f yaw=%.2f cam=%.2f", label, m.sp, m.fitted or 0, m.facing or 0, m.camZ or 0)
                    ns:Print("   pose=%s  max=%s", fmt(m.fitBox), fmt(ReadBox(m.actor, "GetMaxBoundingBox")))
                    ns:Print("   fills h=%.2f w=%.2f feet=%.2f centre=%.2f  checked by engine: %s  load event: %s",
                        fi and fi.h or 0, fi and fi.w or 0, fi and fi.feet or 0, fi and fi.center or 0,
                        (fi and fi.projected) and "yes" or "no", m.hasLoadEvent and "yes" or "no")
                elseif m and m.sp then
                    ns:Print("Azeromon %s: %s (old model frame, no ModelScene)", label, m.sp)
                end
            end
        elseif cmd == "zoom" then
            -- /dz azeromon zoom <creature> <factor>: bigger = smaller on screen; "reset" clears
            local id
            for sid, s in pairs(D.species) do
                if sid == (a or ""):lower() or s.name:lower() == (a or ""):lower() then id = sid end
            end
            if not id then
                ns:Print("Azeromon: usage /dz azeromon zoom <creature> <factor>  (e.g. zoom Lashling 1.3; 'reset' clears)")
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

---------------------------------------------------------------------------
-- For the other Azeromon UI files (UI_*.lua, loaded after this one): the building blocks, and screens for their
-- own G.pending kinds. Keeping new screens in their own files keeps this one under Lua's 200-locals limit.
---------------------------------------------------------------------------

UI.Kit = {
    Box = Box, Font = Font, Pill = Pill, Tex = Tex, Bar = Bar, Triangle = Triangle, TextWidth = TextWidth,
    PushMenu = PushMenu, PopMenu = PopMenu, CloseAllMenus = CloseAllMenus, Message = Message,
    SetText = SetText, ClearText = ClearText, ShowCreature = ShowCreature, NewModel = NewModel,
    R = R, stack = stack, SW = SW, SH = SH, BOX_H = BOX_H, TILE = TILE, INK = INK,
    Screen = function() return screen end,
    Now = function() return now end,
    Tile = function(t, name) SetPixelTexture(t, ATLAS) SetTile(t, name) end,     -- an overworld tile on a texture
    -- (the Games hub's poster film, Poster.lua: the same tiles and people on its own textures)
    PixelTexture = SetPixelTexture, SetTile = SetTile, Char = SetChar,
    HasTile = function(name) return (name and A[name]) and true or false end,
}

-- UI:RegisterScreen(kind, fn): shows G.pending of `kind` (fn(pending)); the screen calls G:Advance() when done.
function UI:RegisterScreen(kind, fn) UI.screens[kind] = fn end

-- For tests
UI._HandleKey = function(k) HandleKey(k) end
UI._ChatBox = function() return R.chatBox end
UI._Gurgles = function() return Amb.gurgles ~= nil and Amb.gurgles:IsShown() end
UI._PropTiles = function()
    local out = {}
    for _, t in ipairs(Amb.propTex) do if t:IsShown() then out[#out + 1] = t.tileName end end
    return out
end
UI._Whos = function()
    local f = R.whos
    if not (f and f:IsShown()) then return nil end
    local rows = {}
    for _, r in ipairs(f.rows) do
        if r.name:IsShown() then rows[#rows + 1] = { r.name:GetText(), r.now:GetText(), r.where:GetText() } end
    end
    return { title = f.title:GetText(), sel = f.sel, rows = rows }
end
UI._Reel = function()
    local b = R.reel
    return b and b:IsShown() and { title = b.title:GetText() } or nil
end
UI._DrawChat = function() KH.DrawChat() end
UI._GuildDrawn = function()
    local n, marks = 0, {}
    for _, t in ipairs(Amb.guildTex) do if t:IsShown() and (t.tileName or ""):match("^statue") then n = n + 1 end end
    for _, fs in ipairs(Amb.markFs) do if fs:IsShown() then marks[#marks + 1] = fs:GetText() end end
    return { statue = n, marks = marks }
end
UI._PeerKey = function(name)
    for _, p in ipairs(ns.AzeroNet:PeersOn(G.save.map)) do if p.name == name then return p.key end end
end
UI._ChatLog = function()
    local out = {}
    if not R.chatLog:IsShown() then return out end
    for _, fs in ipairs(R.chatLog.fs) do if fs:IsShown() then out[#out + 1] = fs:GetText() end end
    return out
end
UI._Bubble = function(which)
    local box = which == "me" and R.player.say or nil
    if not box then
        for _, sp in ipairs(peerSprites) do if sp:IsShown() and sp.label:GetText() == which then box = sp.bubble end end
    end
    return box and box:IsShown() and box.fs:GetText() or nil
end
UI._State = function()
    return { stack = #stack, battle = BT.battle ~= nil, msg = uiMessage ~= nil, text = text.full, paused = paused,
             waitText = (BT.anim and BT.anim.waitText) and true or false, actionOpen = BT.actionOpen and true or false }
end
UI._PauseNote = function() return R.pauseNote:GetText() end
UI._NetColor = function() return { R.net:GetVertexColor() } end
UI._Levels = function()
    local out = {}
    for i, m in ipairs(stack) do
        local row = m.frame.rows and m.frame.rows[1]
        out[i] = { level = m.frame:GetFrameLevel(), row = row and row:GetFrameLevel() or 0,
                   title = m.frame.titleFs and m.frame.titleFs:GetText() or "" }
    end
    return out
end
-- Tests: where the top menu sits (anchor offsets, size), which items its visible rows show, the scroll markers,
-- and the description box / Bestiary panel beside it.
UI._MenuLayout = function()
    local m = stack[#stack]
    if not m or not m.perPage then return nil end
    local f = m.frame
    local _, _, _, x, y = f:GetPoint(1)
    local rows = {}
    for _, row in ipairs(f.rows) do
        if row:IsShown() then
            local _, _, _, rx, ry = row:GetPoint(1)
            local _, _, _, fx = row.fs:GetPoint(1)
            rows[#rows + 1] = { idx = row.idx, x = rx, y = ry, w = row:GetWidth(), h = row:GetHeight(),
                                cursor = row.cursor:IsShown(), icon = row.icon:IsShown() and row.icon:GetHeight() or 0,
                                textEnd = (fx or 0) + row.fs:GetWidth(),
                                rightStart = row:GetWidth() - 6 - TextWidth(row.right:GetText() or "", 13) }
        end
    end
    return { x = x, y = y, w = f:GetWidth(), h = f:GetHeight(), rows = rows, n = #m.items, cursor = m.cursor,
             first = m.first, per = m.perPage, up = f.upMark:IsShown(), down = f.downMark:IsShown(),
             SW = SW, SH = SH, desc = max(R.bagDesc:IsShown() and R.bagDesc:GetHeight() or 0,
                                          R.moveCompare:IsShown() and R.moveCompare:GetHeight() or 0),
             log = R.log:IsShown() and R.log:GetWidth() or 0 }
end
UI._MoveCards = function()
    if not R.moveCompare:IsShown() then return nil end
    local out = {}
    for i, c in ipairs(R.moveCompare.cards) do
        out[i] = { label = c.label:GetText() or "", name = c.name:GetText() or "", stats = c.stats:GetText() or "",
                   effect = c.effect:GetText() or "" }
    end
    return out
end
UI._Shiny = function()
    local f = R.foeModel
    return { display = f.display, glow = f.glow or false, star = R.foeBox.star:IsShown(),
             sparkle = Scr.sparkle ~= nil and Scr.sparkle:IsShown() }
end
UI._MenuItems = function()
    local m = stack[#stack]
    local out = {}
    for i, it in ipairs(m and m.items or {}) do out[i] = it.text end
    return out
end
UI._DescText = function() return R.bagDesc:IsShown() and R.bagDesc.fs:GetText() or nil end
UI._Trade = function()
    local f = R.trade
    if not f:IsShown() then return nil end
    local out = { status = f.status:GetText(), cards = {} }
    for i, c in ipairs(f.cards) do
        out.cards[i] = { label = c.label:GetText(), name = c.name:GetText(), info = c.info:GetText() or "",
                         moves = c.moves:GetText() or "", items = c.items:GetText() or "" }
    end
    return out
end
UI._SummaryState = function()
    local top = stack[#stack]
    local sm
    for i = #stack, 1, -1 do if stack[i].isSummary then sm = stack[i].summary break end end
    if not sm then return nil end
    local slots = {}
    for i, slot in ipairs(Scr.GEAR_ORDER) do slots[i] = Scr.SlotItem(sm.mon, slot) or false end
    local f = R.summary
    return { page = sm.page, cursor = sm.cursor, tabs = f.tabs:GetText(), detail = f.detail:GetText(),
             totals = f.totals:GetText(), slots = slots, gearShown = f.gear:IsShown(), top = top and top.isSummary or false,
             labels = (function() local o = {} for i, c in ipairs(f.cells) do o[i] = c.label:GetText() end return o end)() }
end
UI._KeyStrip = function()
    local ks = R.keyStrip
    if not ks:IsShown() then return nil end
    local out = {}
    for _, part in ipairs(ks.parts) do
        if part.fs:IsShown() then out[#out + 1] = part.pill.fs:GetText() .. " " .. part.fs:GetText() end
    end
    return { keys = out, alpha = ks:GetAlpha(), outside = ks.outside }
end
UI._Focus = function(on, pause) SetFocus(on, pause) end
UI._Outside = function() return R.keyStrip.outside end
UI._RightClick = function(what)
    local m = stack[#stack]
    if not m then return end
    if what == "row" then
        local row = m.frame.rows and m.frame.rows[1]
        row:GetScript("OnClick")(row, "RightButton")
    else
        m.frame:GetScript("OnMouseDown")(m.frame, "RightButton")
    end
end
UI._Boxes = function()
    local out = {}
    for _, side in ipairs({ "foe", "ally" }) do
        local f = side == "foe" and R.foeBox or R.allyBox
        out[side] = f:IsShown() and { chips = f.chipTexts or {}, name = f.name:GetText(), lvl = f.lvl:GetText(),
                                      nameW = f.name:GetWidth(), w = f:GetWidth() } or false
    end
    return out
end
UI._TextOnTop = function()
    local top = stack[#stack]
    return { shown = R.textbox:IsShown(), level = R.textbox:GetFrameLevel(),
             menu = top and top.frame:GetFrameLevel() or 0, text = text.full }
end
UI._MoveEff = function() return R.moveInfo:IsShown() and R.moveInfo.eff:GetText() or nil end
UI._MoveNote = function() return (R.fightDeco and R.fightDeco:IsShown()) and R.fightDeco.strip or nil end
UI._MoveRows = function()                    -- the move list's rows: name size, rest marks, glints (0.40)
    local d, out = R.fightDeco, {}
    local menu = d and d:IsShown() and d.menu
    if not menu then return nil end
    for i = 1, 4 do
        local it, m, g = menu.items[i], d.marks[i], d.glints[i]
        out[i] = { size = it and it.size or 16, right = it and it.right,
                   mark = (m and m:IsShown()) and { total = m.total, left = m.left, glass = m.withGlass } or false,
                   glint = (g and g:IsShown()) and true or false }
    end
    return out
end
UI._MoveLine = function(id, kit)             -- a move's description line (kit: the moves its beast knows)
    local moves = {}
    for i, m in ipairs(kit or {}) do moves[i] = { id = m } end
    return Scr.MoveLine(D.moves[id], { moves = moves })
end
UI._MoveRest = function()                    -- the info box's rest corner
    return { glass = R.moveInfo.glass:IsShown(), text = R.moveInfo.cd:GetText() }
end
UI._Matchups = function(t) return KH.Matchups(t) end
UI._TypeChart = function() return R.typeChart ~= nil and R.typeChart:IsShown() end
UI._PerkLine = function() return R.money.perk:GetText() end
UI._ChangelogUnseen = function() return KH.ChangelogUnseen() and true or false end
UI._Changelog = function()
    local f = R.changelog
    if not (f and f:IsShown()) then return nil end
    return { page = f.page:GetText(), head = f.head:GetText(), body = f.body:GetText() }
end
UI._Evolve = function()
    local m1, m2 = R.speciesModel, R.speciesModel2
    return { m1 = m1:IsShown() and m1.sp or false, m2 = m2:IsShown() and m2.sp or false,
             a1 = m1:GetAlpha(), a2 = m2:GetAlpha(), flash = R.evoFlash:IsShown() and R.evoFlash:GetAlpha() or 0,
             glow = R.evoGlow:IsShown() }
end
UI._Root = function() return root end
UI._Hint = function() return R.hint:IsShown() and R.hint.text or nil end
UI._Wheel = function(delta)
    local m = stack[#stack]
    local fn = m and m.frame:GetScript("OnMouseWheel")
    if fn then fn(m.frame, delta) end
end
UI._Summary = function() return R.summary ~= nil and R.summary:IsShown() and true or false end
-- Tests: the bubbles shown over guildmates, { [name] = text }.
UI._PeerBubbles = function()
    local out = {}
    for _, s in ipairs(peerSprites) do
        if s:IsShown() and s.bubble:IsShown() then out[s.label:GetText()] = s.bubble.fs:GetText() end
    end
    return out
end
-- Tests drive the engine themselves: stop the panel from playing battles / prompts.
UI._Detach = function()
    if root then root:SetScript("OnUpdate", nil) end
    ns.AzeroNet:SetActive(true)
end
-- Tests: after showing `sp` in the enemy slot, how much of the frame it fills and where its feet are.
UI._FitInfo = function()
    local sc = R.foeModel and R.foeModel.scene
    if not sc or not sc.isScene or not sc.fitInfo then return nil end
    return sc.fitInfo
end
-- Tests: draw every beast as its 3D model (false) or as pixel art (true, the default when the art is on disk).
UI._UseSprites = function(on) ns.AzeroSprites.off = not on end
-- Tests: what the pixel sprite in a battle slot shows.
UI._Sprite = function(which)
    local m = (which == "ally") and R.allyModel or R.foeModel
    return m and m.spr:State()
end
UI._Model = function(which) return (which == "ally") and R.allyModel or R.foeModel end
UI._Bg = function()                  -- the old battle picture (hidden while a layered scene shows, 0.45)
    local bg = R.bg
    return bg and { art = bg.art and bg.art:IsShown() or false, clouds = bg.clouds and bg.clouds:IsShown() or false } or nil
end
UI._SpriteAnim = function(which, id) Anim((which == "ally") and R.allyModel or R.foeModel, id) end
UI._ShowFoe = function(sp) R.title:Hide() R.battle:Show() ShowCreature(R.foeModel, sp, -0.7) end
UI._ShowFoeShiny = function(sp) R.title:Hide() R.battle:Show() ShowCreature(R.foeModel, sp, -0.7, true) end
UI._Camera = function() return { dist = CAM_DIST, fov = CAM_FOV } end
UI._Scene = function(which)          -- the 3D model in a battle slot (tests of the model fitting)
    local m = (which == "ally") and R.allyModel or R.foeModel
    return m and m.scene
end
UI._TitleFilm = function() return R.titleFilm end
UI._SkyAlpha = function()            -- the flat tint, or the baked darkness that replaces it (Amb.Night)
    local dark = false
    for _, x in ipairs(Amb.lightTex) do if x:IsShown() then dark = true end end
    return ((R.sky and R.sky:IsShown()) or dark) and (R.skyAlpha or 0) or 0
end
-- tests: the baked ground chunks on screen, and the base tile names drawn in the view (false = hidden)
UI._Ground = function()
    local out = {}
    for _, t in ipairs(groundTex) do if t:IsShown() then out[#out + 1] = t.file end end
    return out
end
UI._BaseTiles = function()
    local out = {}
    for i = 0, VW + 2 do for j = 0, VH + 1 do
        local b = grid[i] and grid[i][j] and grid[i][j].base
        if b then out[#out + 1] = b:IsShown() and b.tileName or false end
    end end
    return out
end
-- the Guild Hall's layers on screen (Amb.Hall): shut wings' seals, props, trophies, flames, water, glows, the files
UI._Hall = function()
    local P = Amb.hall
    local function list(pool)
        local out = {}
        for _, t in ipairs(pool) do if t:IsShown() then out[#out + 1] = t.file end end
        return out
    end
    return { seals = list(P.seals), dims = list(P.dims), props = #list(P.props), trophies = #list(P.troph),
             fires = #list(P.fires), water = #list(P.water), glows = #list(P.glows),
             top = P.topTex and P.topTex:IsShown() or false, wing = P.wing,
             front = (function() local n = 0 for _, t in ipairs(P.props) do
                 if t:IsShown() and select(2, t:GetDrawLayer()) == 3 then n = n + 1 end end return n end)() }
end

UI._Ambient = function()
    local water = {}
    for _, t in ipairs(Amb.waterTex) do if t:IsShown() then water[#water + 1] = t.file end end
    local shown = function(list) local k = 0 for _, x in ipairs(list) do if x:IsShown() then k = k + 1 end end return k end
    return { water = water, pix = Amb.pixN, frame = floor(now * Amb.WATER_FPS) % Amb.WATER_FRAMES,
             clouds = (R.clouds and R.clouds:IsShown()) and R.clouds:GetAlpha() or 0,
             wind = shown(Amb.windTex), dark = shown(Amb.lightTex), glows = shown(Amb.glowTex),
             mood = R.mood and R.mood:IsShown() or false, sky = R.sky and R.sky:IsShown() or false,
             legs = R.player.legs and R.player.legs:IsShown() or false,
             anims = shown(Amb.animTex), sun = R.sun and R.sun:IsShown() or false,
             mist = R.mist:IsShown(), shafts = R.shafts:IsShown(), raining = Amb.raining or false,
             parts = #Amb.parts }
end
UI._OverAt = function(i, j)            -- the over tile drawn in view cell i, j (0 .. VW + 1, 0 .. VH + 1)
    local o = grid[i] and grid[i][j] and grid[i][j].over
    return o and o:IsShown() and o.tileName or false
end
UI._ShadowsShown = function()
    local n = 0
    for _, s in ipairs(sprites) do if s:IsShown() and s.shadow:IsShown() then n = n + 1 end end
    return n
end
UI._PlayerHeight = function() return R.player and R.player:GetHeight() or 0 end   -- (wading: the legs cut, 0.46)
UI._Light = function()               -- light on people (Light.lua): textures on screen, the sheet the player uses
    local st = ns.AzeroLight.Stats()
    st.playerFile = R.player and R.player.charsFile or false
    st.playerBlob = R.playerShadow and R.playerShadow:IsShown() or false
    return st
end
