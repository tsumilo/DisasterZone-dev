-- CDLoot Games/Azeromon/UI.lua
-- ns.AzeroUI: draws ns.Azero's state and forwards keyboard / mouse input.
-- Screen: 11 x 9 tiles of 48px (16px art at 3x, nearest filtering), camera centred on the player.
-- Keys (while the game has focus): arrows / WASD move, Space / Z / E = A, X / Q / Backspace = B (hold to run),
-- Enter / Tab / M = menu, Escape releases the keyboard.
local addonName, ns = ...

local UI = ns:NewModule("AzeroUI")
UI.screens = {}            -- [pending kind] = fn(pending): screens other UI files add (UI:RegisterScreen)
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
local KH = {}              -- help and reference: key hints, tips, the controls page, the type chart
local Scr = {}             -- the screens' helpers (summary pages, trade, stable, professions, ...)

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
    local AH = ns.AzeroAtlasHeight or 256
    t:SetTexCoord(c * 16 / 256 + E, (c + 1) * 16 / 256 - E, r * 16 / AH + E, (r + 1) * 16 / AH - E)
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
local measureFs                  -- a hidden font string, to measure text (TextWidth)
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

-- How wide `str` is in the game font at `size` (Font sizes).
local function TextWidth(str, size)
    if not measureFs and UIParent then
        measureFs = UIParent:CreateFontString(nil, "OVERLAY")
        measureFs:Hide()
    end
    if measureFs then
        local px = floor((size or 16) * 1.4 + 0.5)
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
-- screen (the player's toward screen-right at +0.8; /cdl azeromon flip fixes it if the engine turns the other
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

-- shiny: the species' other skin (D.shinyDisplay), or its own skin in a golden light when it has none.
local function ShowCreature(m, sp, facing, shiny)
    local s = sp and D.species[sp]
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
    row:SetScript("OnEnter", function(self)
        local menu = self:GetParent().menu
        if menu and stack[#stack] == menu and self.idx then menu.cursor = self.idx UI:RefreshMenu(menu) end
    end)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if UI.Press then UI.Press("B") end
            return
        end
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
            row.fs:SetText(it.text or "")
            row.fs:ClearAllPoints()
            local left = it.icon and (26 + rowH) or 24
            row.fs:SetPoint("LEFT", left, it.bar and 5 or 0)
            -- long names stop short of the right-hand column (cut with "...") instead of running under it
            local rightW = (it.right and it.right ~= "") and (TextWidth(it.right, 13) + 12) or 0
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
            if menu and stack[#stack] == menu then MenuMoveBy(menu, delta > 0 and "up" or "down") end
        end)
    end
    local menu = { frame = f, items = items, cursor = opts.cursor or 1, cols = cols, opts = opts,
                   rowH = rowH, perPage = perLines * cols, first = 1 }
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
    if c >= 1 and c <= n then menu.cursor = c end
    UI:RefreshMenu(menu)
end

MenuMoveBy = function(menu, dir) MenuMove(menu, dir) end

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
-- A message in the text box, answered with Space / X. When a menu covers the text box (the move list sits in its
-- place, a bag or a summary on top), the box comes up over it for the message and goes back down afterwards.
local function Message(str, after)
    local tb = R.textbox
    local base = tb:GetFrameLevel()
    local top = stack[#stack]
    local over = top and top.frame and top.frame:IsShown() and top.frame:GetFrameLevel() + 10
    if over and over > base then
        tb:SetFrameLevel(over)
        R.textArrow:SetFrameLevel(over + 2)
        R.nameTab:SetFrameLevel(over - 1)
    end
    uiMessage = { after = after }
    SetText(str, { onDone = function()
        uiMessage = nil
        ClearText()
        tb:SetFrameLevel(base)
        R.textArrow:SetFrameLevel(base + 2)
        R.nameTab:SetFrameLevel(base - 1)
        if after then after() end
    end })
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
    local entry = { frame = f, items = {}, cursor = 1, cols = 1, summary = sm, isSummary = true, opts = {
        onCancel = function(menu) PopMenu(menu) if onClose then onClose() end end } }
    sm.entry = entry
    stack[#stack + 1] = entry
    Scr.RenderSummary(sm)
end

local function OpenLog()
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
    PushMenu(items, { x = 8, y = -8, w = 320, rowH = 36, title = "BAG", level = 70, desc = true,
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
    "Your Azeromon achievements.",
    "Guild leaderboards and the Guild Bestiary.",
    "Today's bounties and the guild's weekly goal.",
    "Your professions: gather, smelt, brew and forge.",
    "Which types hit which, and how hard.",
    "Every key and button.",
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
        title = string.format("%s  %d / %d", p.name:upper(), C.Skill(prof) or 0, D.SKILL_MAX),
        onCancel = function(m)
            PopMenu(m)
            R.bagDesc:Hide()
            if onClose then onClose() end
        end,
        onMove = function(i, m) desc(i, m) end })
    return menu
end

function Scr.OpenProfessions()
    local C = ns.AzeroCraft
    R.bagDesc:Hide()
    local items = {}
    for _, id in ipairs(D.professionOrder) do
        local p = D.professions[id]
        local skill = C.Skill(id)
        items[#items + 1] = { text = p.name, icon = p.icon, prof = id,
            right = skill and string.format("%d / %d", skill, D.SKILL_MAX) or "not learned",
            bar = skill and skill / D.SKILL_MAX or nil, disabled = not skill,
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

local function OpenStartMenu()
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
                if def.use == "boost" then Message("Drink it in battle: it raises the stat of the beast fighting.") return end
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
        { text = "ACHIEVEMENTS", onSelect = function() Scr.OpenAchievements() end },
        { text = "GUILD", onSelect = function() Scr.OpenGuild() end },
        { text = "BOUNTIES", onSelect = function() Scr.OpenBounties() end },
        { text = "PROFESSIONS", onSelect = function() Scr.OpenProfessions() end },
        { text = "TYPE CHART", onSelect = function() KH.OpenTypeChart() end },
        { text = "CONTROLS", onSelect = function() KH.OpenControls() end },
        { text = "EXIT", onSelect = function(_, menu) PopMenu(menu) end },
    }
    PushMenu(items, { w = 210, rowH = 30, level = 60, desc = true, onMove = StartMenuHelp, onCancel = function(menu) PopMenu(menu) end })
    R.money:Show()
end

---------------------------------------------------------------------------
-- Shop
---------------------------------------------------------------------------

-- Selling: the bag's goods a shop will buy, a quantity (left / right), then the coins.
function Scr.OpenSell()
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

local function OpenShop(keeper)
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
    local e, out = md.effect, {}
    if md.prio and md.prio > 0 then out[#out + 1] = "Always strikes first" end
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
    return table.concat(out, "; ")
end

function Scr.MoveStatsText(md, pp)
    return table.concat({ md.power > 0 and ("Power " .. md.power) or "Status",
        (md.acc or 0) > 0 and ("Acc " .. md.acc .. "%") or "Never misses",
        "PP " .. (pp and (pp .. "/" .. md.pp) or md.pp) }, "   ")
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
            Scr.TextCard(2, "LESSON", D.Money(G.RELEARN_PRICE), "You have " .. D.Money(G.save.money))
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

local BT = { busy = nil }     -- playback state
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
    GameTooltip:SetText(c.title or c.text, 1, 0.82, 0)
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
                BT.lastMove[mon] = idx
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
    local last = BT.lastMove[mon]
    PushMenu(items, { anchor = { "BOTTOMLEFT", screen, "BOTTOMLEFT", 0, 0 }, w = SW - 170, h = BOX_H, rowH = 38, cols = 2,
        level = 70, cursor = (last and mon.moves[last]) and last or 1, onCancel = function(menu)
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
                local foe = G.battle and G.battle.foe.mon
                local txt, col = KH.EffectText(md, foe and D.species[foe.sp].type)
                info.eff:SetText(txt)
                info.eff:SetTextColor(col[1], col[2], col[3])
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
                if def.use == "charm" or def.use == "gear" or def.use == "flask" or def.use == "material" then
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
    PushMenu(items, { anchor = { "BOTTOMRIGHT", screen, "BOTTOMRIGHT", 0, 0 }, w = 230, h = BOX_H, rowH = 38, cols = 2,
        level = 70, cursor = BT.lastAction or 1, onCancel = function() end })
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
    R.battleSkyAlpha = ApplySky(R.battleSky, G.map and G.map.def.outdoor, 0.75, G.map and G.map.def.gloom)
    local foeSp = b.foe and b.foe.mon and D.species[b.foe.mon.sp]
    if b.wild and foeSp and foeSp.rare and PlaySound then pcall(PlaySound, 8959, "Master") end   -- RAID_WARNING
    BT.battle = b
    BT.anim, BT.needShown, BT.ended, BT.snap, BT.lastNeed = nil, nil, nil, nil, nil
    BT.lastAction = nil
    BT.intro = 0.95
    R.battle:Show()
    world:Hide()
    R.foeBox:Hide() R.allyBox:Hide()
    R.foeBox.animHP, R.allyBox.animHP, R.allyBox.animExp = nil, nil, nil
    R.net:Hide()
    -- Load and measure both leads right away, invisibly: the fit samples the idle animation for SAMPLE_TIME,
    -- which then happens during the intro text instead of delaying the send-out.
    ShowCreature(R.foeModel, b.foe.mon.sp, -0.7, b.foe.mon.shiny)
    ShowCreature(R.allyModel, b.ally.mon.sp, 0.8, b.ally.mon.shiny)
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
        -- stat changes, sleep turns and flasks change with plain text events too: keep the boxes on screen current
        if R.foeBox:IsShown() then InfoBox(R.foeBox, "foe") end
        if R.allyBox:IsShown() then InfoBox(R.allyBox, "ally") end
        SetText(e.text, { auto = 1.0, onDone = function() BT.anim = nil ClearText() end })
        BT.anim = { waitText = true }
    elseif e.t == "send" then
        local m = BattleModelFor(e.side)
        ShowCreature(m, e.mon.sp, e.side == "foe" and -0.7 or 0.8, e.mon.shiny)
        local shiny = e.mon.shiny
        m:SetAlpha(0)
        local box = e.side == "foe" and R.foeBox or R.allyBox
        box.animHP, box.animExp = nil, nil
        box.mon = e.mon
        local from = e.side == "foe" and 260 or -260
        -- hold the slide-in until the model has been measured (a creature switched in mid-battle), at most 3 s
        BT.anim = { t = 0, dur = 0.5, hold = function() return m.fit ~= nil and not m.fit.timedOut end, fn = function(f)
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
        BT.anim = { t = 0, dur = 0.35, fn = function(f) m:SetAlpha(1 - f) end, done = function() m:Hide() m.sp = nil end }
    elseif e.t == "attack" then
        local m = BattleModelFor(e.side)
        local other = BattleModelFor(e.side == "ally" and "foe" or "ally")
        local hitSound = e.move and (e.move.power or 0) > 0 and e.move.type
        Anim(m, 16)
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
                    done = function() Anim(m, 0) m:Hide() m.sp = nil m:SetAlpha(1) if e.side == "foe" then R.foeBox:Hide() end end }
    elseif e.t == "status" or e.t == "level" then
        if e.t == "level" then ns.AzeroSound:Play("levelup") end
        R.allyBox.animExp = nil
        RefreshBattleBoxes()
    elseif e.t == "sfx" then
        ns.AzeroSound:Play(e.sound)
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
    R.fade:SetAllPoints()
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
                if m.water[k] then
                    local wf = m.theme.water
                    base = wf and wf[(waterFrame == "water1") and 1 or 2] or waterFrame
                end
                if m.chest[k] then over = G:Flag("chest_" .. m.chest[k].id) and "chest_open" or "chest" end
                local node = m.node and m.node[k]
                if node then
                    local up, res = ns.AzeroCraft:NodeState(m.id, node)
                    over = up and D.resources[res] and D.resources[res].tile or over
                end
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
    DrawHint()
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
        OpenShop(p.keeper)
    elseif p.kind == "relearn" then
        ClearText()
        Scr.OpenRelearn()
    elseif p.kind == "bounties" then
        ClearText()
        Scr.OpenBounties(function() G:Advance() end)
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
    elseif UI.screens[p.kind] then          -- a screen from another UI file (UI:RegisterScreen)
        ClearText()
        UI.screens[p.kind](p)
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
    items[#items + 1] = { text = "WHAT'S NEW", right = KH.ChangelogUnseen() and "new" or nil,
        rightColor = { 0.85, 0.55, 0.05 }, onSelect = function(idx, menu)
            KH.OpenChangelog()
            menu.items[idx].right = nil
            UI:RefreshMenu(menu)
        end }
    items[#items + 1] = { text = "CONTROLS", onSelect = function() KH.OpenControls() end }
    PushMenu(items, { w = 210, anchor = { "TOP", screen, "CENTER", 0, -32 }, rowH = 32, level = 60,
        onCancel = function() end })
end

---------------------------------------------------------------------------
-- Key hints: a strip with the keys that matter right now (under the game when there's room, else over its top
-- edge). It shows when the situation changes, fades after a few seconds, comes back when the player idles, and
-- drops a key for good once it has been used KH.KEY_LEARNED times (G:Data().keys; CONTROLS brings them back).
-- One-time tips (G:Data().tips) teach the rest at the moment they matter.
---------------------------------------------------------------------------

KH.KEY_NAME = { A = "Space", B = "X", START = "Enter", move = "Arrows" }
KH.KEY_LEARNED = 5
KH.KEY_HINTS = {
    world = { { "move", "Walk", "walk" }, { "A", "Talk", "talk" }, { "START", "Menu", "menu" }, { "B", "Run (hold)", "run" } },
    menu = { { "A", "Select", "select" }, { "B", "Back", "back" } },
    text = { { "A", "Next", "next" } },
    netwait = { { "B", "Cancel", "cancel" } },
    evolve = { { "B", "Stop it evolving", "stopevo" } },
}
KH.keyState = { ctx = false, since = 0, input = 0 }

-- What the player is doing, as far as keys go (nil: no strip - e.g. the summary has its own key line).
function KH.KeyContext()
    if R.title:IsShown() then return #stack > 0 and "menu" or nil end
    if not G.started then return nil end
    if uiMessage then return "text" end
    local top = stack[#stack]
    if top then return (not top.isSummary) and "menu" or nil end
    if BT.battle then return "text" end
    local p = G.pending
    if p then
        if p.kind == "text" then return "text" end
        if p.kind == "netwait" then return "netwait" end
        if p.kind == "evolve" then return "evolve" end
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
    local room = ((h or root:GetHeight() or 0) - SH * sc) / 2
    ks:ClearAllPoints()
    ks:SetWidth(SW * sc)
    if room >= 26 then
        ks:SetPoint("TOP", screen, "BOTTOM", 0, -3)
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
    menu = "Tip: press Enter to open your menu: your beasts, your bag, your professions and more.",
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

-- The whole chart: the move's type down the left, the defender's type along the top.
function KH.OpenTypeChart()
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
    stack[#stack + 1] = { frame = f, items = {}, cursor = 1, cols = 1, isPanel = true,
        opts = { onCancel = function(m) PopMenu(m) f:Hide() end } }
end

-- WHAT'S NEW: one release per page (ns.AzeroChangelog, newest first), left / right for older / newer.
function KH.ChangelogUnseen()
    local log = ns.AzeroChangelog
    return log and log[1] and G:Data().changelogSeen ~= log[1].version
end

function KH.OpenChangelog()
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
    stack[#stack + 1] = { frame = f, items = {}, cursor = 1, cols = 1, isPanel = true,
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
    elseif G.started and G.map then key = G.map.def.music end
    ns.AzeroSound:Music(key)
end

function Scr.Dark(sc, a)                -- 0 = normal light, 1 = a black silhouette
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
        { "Open the menu", "Enter, Tab or M" },
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
    items[#items + 1] = { text = "Show the key hints again", onSelect = function(idx, menu)
        G:Data().keys = {}
        R.keyStrip.sig = nil
        KH.keyState.since = now
        menu.items[idx].text = "Key hints will show again"
        UI:RefreshMenu(menu)
    end }
    PushMenu(items, { x = 8, y = -8, w = SW - 16, rowH = 30, level = 70, title = "CONTROLS",
        onCancel = function(menu) PopMenu(menu) end })
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

-- A reference panel on top (type chart, what's new): its own keys first, then Space / X close it.
function KH.PanelKey(top, key)
    if top.onKey and top.onKey(key) then return end
    if key == "A" or key == "B" then top.opts.onCancel(top) end
end

local function HandleKey(key)
    KH.NoteKey((key == "up" or key == "down" or key == "left" or key == "right") and "move" or key)
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
-- Frame update
---------------------------------------------------------------------------

local function OnUpdate(self, elapsed)
    now = now + elapsed
    FitScenes(elapsed)
    KH.UpdateKeyStrip()
    Scr.UpdateMusic()
    if R.title:IsShown() or not G.started then
        ns.AzeroNet:SetActive(false)
        return
    end
    -- visible with a save loaded: guildmates may see us (Net sends at most once a second)
    ns.AzeroNet:SetActive(true)
    ns.AzeroNet:Update(elapsed)
    ns.AzeroPvP:Update()
    ns.AzeroTrade:Update()
    KH.CheckTips()
    ns.AzeroGuild:Update()
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
    Scr.UpdateSpecies(elapsed)
    if R.money:IsShown() then
        local hr = G:Hour() % 24
        local p, cls = G:PerkInfo(), G:ClassFile()
        local cc = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        local className = cls and ((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls])
            or (cls:sub(1, 1) .. cls:sub(2):lower()))
        R.money.perk:SetText(p and string.format("%s: %s", className, p.name) or "")
        if cc then R.money.perk:SetTextColor(cc.r * 0.8, cc.g * 0.8, cc.b * 0.8) end
        R.money.fs:SetText(string.format("Money: %s\nBadges: %d\nRealm time %02d:%02d (%s)", D.Money(G.save.money),
            G:BadgeCount(), math.floor(hr), math.floor((hr % 1) * 60), G:Period()))
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
    -- sky tint for outdoor battles (above the backdrop, below the creatures, which are child frames)
    R.battleSky = Tex(b, "BORDER", 7)
    R.battleSky:SetAllPoints()
    R.battleSky:Hide()

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
        if not hpl:SetFont(FONT_BOLD, 14, "") then hpl:SetFont(FONT_FALLBACK, 9, "") end
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

    R.net = Tex(b, "OVERLAY", 3)
    R.net:SetSize(34, 34)
    R.net:SetTexture("Interface\\Icons\\Ability_Hunter_BeastTaming")
    R.net:Hide()

    R.moveInfo = Box(b, 170, BOX_H, 75)
    R.moveInfo:SetPoint("BOTTOMRIGHT", screen, "BOTTOMRIGHT", 0, 0)
    R.moveInfo.pp = Font(R.moveInfo, 15, nil, true)
    R.moveInfo.pp:SetPoint("TOPLEFT", 18, -14)
    R.moveInfo.type = Pill(R.moveInfo, 80, 20, 16)
    R.moveInfo.type:SetPoint("TOPLEFT", 18, -38)
    R.moveInfo.power = Font(R.moveInfo, 13)
    R.moveInfo.power:SetPoint("TOPLEFT", 18, -62)
    R.moveInfo.eff = Font(R.moveInfo, 12, nil, true)            -- against this foe (KH.EffectText)
    R.moveInfo.eff:SetPoint("TOPLEFT", 18, -84)
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
    R.textbox:SetScript("OnMouseDown", function(_, button)
        if button == "RightButton" then HandleKey("B") return end
        if uiMessage or (G.pending and G.pending.kind == "text") or (BT.battle and text.full) then HandleKey("A") end
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
    glow:SetAllPoints()
    glow:SetFrameLevel(screen:GetFrameLevel() + 44)
    glow.t = Tex(glow, "BACKGROUND")
    glow.t:SetAllPoints()
    glow.t:SetColorTexture(1, 1, 1, 1)
    glow:Hide()
    R.evoGlow = glow
    local flash = CreateFrame("Frame", nil, screen)                 -- and the white flash in front of it
    flash:SetAllPoints()
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
    -- the class perk: one line in the class colour, the whole story on hover
    R.money.perk = Font(R.money, 15)
    R.money.perk:SetPoint("TOPLEFT", R.money.fs, "BOTTOMLEFT", 0, -2)
    R.money:SetScript("OnEnter", function(self)
        local p = G:PerkInfo()
        if not (p and GameTooltip) then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText(p.name, 1, 0.82, 0)
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
        c.name:SetPoint("TOPLEFT", x0, -32)
        c.stats = Font(mc, 13)
        c.stats:SetPoint("TOPLEFT", x0, -58)
        c.effect = Font(mc, 13)
        c.effect:SetPoint("TOPLEFT", x0, -80)
        c.effect:SetWidth(cw)
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
            local top = stack[#stack]
            if top and top.isSummary and top.summary.page == "gear" then
                top.summary.cursor = i
                Scr.RenderSummary(top.summary)
            end
        end)
        cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        cell:SetScript("OnClick", function(_, button)
            if button == "RightButton" then UI.Press("B") return end
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
    -- (the keys: the key strip and CONTROLS explain them)

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
    -- the game keeps its 11 x 9 tiles and scales evenly (never stretched) to the largest size its space allows
    local ks = CreateFrame("Frame", nil, root)
    ks:SetSize(SW, 22)
    ks.bg = Tex(ks, "BACKGROUND")
    ks.bg:SetAllPoints()
    ks.bg:SetColorTexture(0.05, 0.05, 0.07, 0.75)
    ks.parts = {}
    for i = 1, 4 do
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

    local function FitScreen(w, h)
        w, h = w or root:GetWidth(), h or root:GetHeight()
        if w and h and w > 0 and h > 0 then screen:SetScale(max(0.3, min(w / SW, h / SH))) end
        KH.PlaceKeyStrip(h)
    end
    root:SetScript("OnSizeChanged", function(self, w, h) FitScreen(w, h) end)
    UI._Fit = function(w, h) FitScreen(w, h) return screen:GetScale() end
    root:SetScript("OnHide", function() SetFocus(false) ns.AzeroNet:SetActive(false) ns.AzeroSound:Stop() end)

    root.OnGameShown = function()
        FitScreen()
        if not G.started then ShowTitle() end
    end
    root.OnGameHidden = function() SetFocus(false) ns.AzeroNet:SetActive(false) ns.AzeroSound:Stop() end
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
}

-- UI:RegisterScreen(kind, fn): shows G.pending of `kind` (fn(pending)); the screen calls G:Advance() when done.
function UI:RegisterScreen(kind, fn) UI.screens[kind] = fn end

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
UI._Focus = function(on) SetFocus(on) end
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
UI._ShowFoeShiny = function(sp) R.title:Hide() R.battle:Show() ShowCreature(R.foeModel, sp, -0.7, true) end
UI._Camera = function() return { dist = CAM_DIST, fov = CAM_FOV } end
UI._Scene = function(which) return (which == "ally") and R.allyModel or R.foeModel end
UI._TitleScenes = function() return R.titleModels end
UI._SkyAlpha = function() return (R.sky and R.sky:IsShown()) and (R.skyAlpha or 0) or 0 end
