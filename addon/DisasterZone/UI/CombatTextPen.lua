if DisasterZoneBoot and DisasterZoneBoot.Run("UI/CombatTextPen.lua", ...) then return end -- DisasterZone UI/CombatTextPen.lua
-- The combat text's pen (ns.CTPen): the mockup's canvas calls (claude.ai/artifact/LeZxS4KRZhKGsQXUbLRCiE, built by
-- dev/art/casc/sct_mockup) on the game's widgets, so the six looks (UI/CombatTextLooks.lua) are drawn by the
-- mockup's own code. Immediate mode over pooled regions: every frame each number draws itself again (texts, rects,
-- gradients, images, lines, arcs, discs, triangles, icons, gilded text) and the pen hands it the next region of each
-- kind from the number's own host frame; whatever a number did not use this frame is hidden. Regions are made once
-- and stay with their host, which goes back to a pool when its number is gone: a fight makes no new frames.
-- Coordinates are the mockup's: px of a 540 px tall screen, y down, from the overlay's top left (UI/CombatText.lua
-- scales the overlay so 540 of its units are the screen's height divided by the size setting). Draw order is the
-- order of the calls (each region takes the next layer slot); a gilded text is a child frame, so it sits above the
-- regions of its number.
local addonName, ns = ...

local Pen = {}
ns.CTPen = Pen

local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt
local cos, sin, ceil = math.cos, math.sin, math.ceil
local pi = math.pi
local TAU = pi * 2
local ipairs, tonumber, type = ipairs, tonumber, type

local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
local WHITE = "Interface\\Buttons\\WHITE8X8"
Pen.WHITE = WHITE
Pen.DISC = MEDIA .. "Strategy\\disc"
Pen.GLOW = MEDIA .. "SoftGlow"
Pen.GILT = MEDIA .. "Gilt\\"
Pen.STAR = "Interface\\Cooldown\\star4"
Pen.QUICK = "Interface\\Buttons\\UI-Quickslot2"
Pen.ALERT = "Interface\\SpellActivationOverlay\\IconAlert"
Pen.LOWHP = "Interface\\FullScreenTextures\\LowHealth"
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-- The mockup's faces. Skurri (the game's damage font) and Morpheus (its title font) have Latin letters only.
local FRIZ = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local LATIN = true
if GetLocale then
    local l = GetLocale()
    LATIN = not (l == "koKR" or l == "zhCN" or l == "zhTW" or l == "ruRU")
end
local FONTS = { Friz = FRIZ, ArialN = "Fonts\\ARIALN.TTF",
                Skurri = LATIN and "Fonts\\SKURRI.TTF" or FRIZ, Morpheus = LATIN and "Fonts\\MORPHEUS.TTF" or FRIZ }
Pen.FONTS = FONTS
local OW = { [0] = "", [1] = "OUTLINE", [2] = "THICKOUTLINE" }

local function clamp(v, a, b)
    a, b = a or 0, b or 1
    if v < a then return a elseif v > b then return b end
    return v
end
Pen.clamp = clamp

-- "#rrggbb" -> { r, g, b } (one table per colour, kept)
local colors = {}
function Pen.C(h)
    local c = colors[h]
    if c then return c end
    c = { (tonumber(h:sub(2, 3), 16) or 255) / 255, (tonumber(h:sub(4, 5), 16) or 255) / 255,
          (tonumber(h:sub(6, 7), 16) or 255) / 255 }
    colors[h] = c
    return c
end
-- a + (b - a) * k into out
function Pen.Mix(a, b, k, out)
    k = clamp(k)
    out = out or {}
    out[1], out[2], out[3] = a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k
    return out
end

---------------------------------------------------------------------------
-- The overlay and the hosts
---------------------------------------------------------------------------

local overlay, measure
local free = {}

function Pen:Overlay()
    if overlay then return overlay end
    overlay = CreateFrame("Frame", "DisasterZoneCombatText", UIParent)
    overlay:SetFrameStrata("LOW")
    overlay:SetFrameLevel(1)
    overlay:SetAllPoints(UIParent)
    if overlay.EnableMouse then overlay:EnableMouse(false) end
    measure = overlay:CreateFontString(nil, "BACKGROUND")
    measure:SetPoint("TOPLEFT", overlay, "TOPLEFT", -4000, 4000)
    measure:SetAlpha(0)
    return overlay
end

-- The overlay's size in its own units (the mockup's px).
function Pen:Size()
    local o = self:Overlay()
    local s = o:GetScale() or 1
    if s <= 0 then s = 1 end
    local w, h = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
    if w <= 0 or h <= 0 then w, h = 1920, 1080 end
    return w / s, h / s
end

local KINDS = { "fs", "tx", "ln", "ic", "gt" }

function Pen:Host(level)
    local h = table.remove(free)
    if not h then
        h = CreateFrame("Frame", nil, self:Overlay())
        h:SetSize(1, 1)
        h:SetPoint("TOPLEFT", overlay, "TOPLEFT", 0, 0)
        h.shown = {}
        for _, k in ipairs(KINDS) do h[k] = {}; h.shown[k] = 0 end
    end
    h:SetFrameLevel(level or 10)
    h:Show()
    return h
end

local function HideUnit(u)
    if not u then return end
    if u.Hide then u:Hide() return end
    for _, r in ipairs(u.parts) do r:Hide() end
end

function Pen:Free(h)
    for _, k in ipairs(KINDS) do
        local list = h[k]
        for i = 1, h.shown[k] do HideUnit(list[i]) end
        h.shown[k] = 0
    end
    h:Hide()
    free[#free + 1] = h
end

-- Every region the pools hold (tests).
function Pen:Count()
    local n = 0
    for _, h in ipairs(free) do for _, k in ipairs(KINDS) do n = n + #h[k] end end
    return n, #free
end

---------------------------------------------------------------------------
-- The pen: state, transform, layer slots
---------------------------------------------------------------------------

local c = { a = 1, sc = 1, ox = 0, oy = 0, add = false, n = 0 }
Pen.c = c
local stack, sp = {}, 0
local LAYERS = { "BACKGROUND", "BORDER", "ARTWORK", "OVERLAY" }

function Pen:Begin(h, x, y)
    c.h = h
    c.ox, c.oy, c.sc, c.a, c.add, c.n = x or 0, y or 0, 1, 1, false, 0
    for _, k in ipairs(KINDS) do c[k] = 0 end
    sp = 0
    return c
end

function Pen:End()
    local h = c.h
    for _, k in ipairs(KINDS) do
        local list, used = h[k], c[k]
        for i = used + 1, h.shown[k] do HideUnit(list[i]) end
        h.shown[k] = used
    end
    c.h = nil
end

function c:Push()
    sp = sp + 1
    local s = stack[sp]
    if not s then s = {}; stack[sp] = s end
    s[1], s[2], s[3], s[4], s[5] = self.ox, self.oy, self.sc, self.a, self.add
end
function c:Pop()
    local s = stack[sp]
    if not s then return end
    sp = sp - 1
    self.ox, self.oy, self.sc, self.a, self.add = s[1], s[2], s[3], s[4], s[5]
end
function c:Translate(x, y) self.ox = self.ox + x * self.sc; self.oy = self.oy + y * self.sc end
function c:Scale(s) self.sc = self.sc * s end

local function Slot(self)
    local n = self.n
    self.n = n + 1
    if n > 63 then n = 63 end
    return LAYERS[floor(n / 16) + 1], (n % 16) - 8
end

-- The next region of a kind on this frame's host (made the first time).
local MAKE = {}
local function Next(self, kind)
    local h = self.h
    local i = self[kind] + 1
    local r = h[kind][i]
    if not r then
        r = MAKE[kind](h)
        h[kind][i] = r
    end
    self[kind] = i
    if i > h.shown[kind] then
        if r.Show then r:Show() else for _, p in ipairs(r.parts) do p:Show() end end
    end
    return r
end

MAKE.fs = function(h)
    local fs = h:CreateFontString(nil, "OVERLAY")
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    fs.k = {}
    return fs
end
MAKE.tx = function(h)
    local t = h:CreateTexture(nil, "ARTWORK")
    t.k = {}
    return t
end
MAKE.ln = function(h)
    local l = h:CreateLine(nil, "ARTWORK")
    l:SetColorTexture(1, 1, 1, 1)
    l.k = {}
    return l
end

local function Blend(r, add)
    local m = add and "ADD" or "BLEND"
    if r.k.b ~= m then r:SetBlendMode(m); r.k.b = m end
end

-- A plain texture region at the next slot: file, coords, colour, alpha, blend; corners unbent. grad: the caller
-- colours it with a gradient (kept while its key holds; a plain colour drops it).
local function Tex(self, file, r, g, b, a, l, rr, t, bb, grad)
    local tx = Next(self, "tx")
    local k = tx.k
    local layer, sub = Slot(self)
    if k.L ~= layer or k.S ~= sub then tx:SetDrawLayer(layer, sub); k.L, k.S = layer, sub end
    if k.f ~= file then tx:SetTexture(file); k.f = file end
    l, rr, t, bb = l or 0, rr or 1, t or 0, bb or 1
    if k.l ~= l or k.r ~= rr or k.t ~= t or k.bb ~= bb then tx:SetTexCoord(l, rr, t, bb); k.l, k.r, k.t, k.bb = l, rr, t, bb end
    if k.bent then
        for v = 1, 4 do tx:SetVertexOffset(v, 0, 0) end
        k.bent = nil
    end
    if k.rot then tx:SetRotation(0); k.rot = nil end
    if not grad then
        tx:SetVertexColor(r, g, b, a)
        k.grad = nil
    end
    tx:SetAlpha(self.a)
    Blend(tx, self.add)
    return tx
end

local function PlaceBox(self, t, x, y, w, h)
    local sc = self.sc
    local px, py = self.ox + x * sc, self.oy + y * sc
    local k = t.k
    w, h = max(0.001, w * sc), max(0.001, h * sc)
    if k.x ~= px or k.y ~= py or k.w ~= w or k.h ~= h then
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", self.h, "TOPLEFT", px, -py)
        t:SetSize(w, h)
        k.x, k.y, k.w, k.h = px, py, w, h
    end
end

---------------------------------------------------------------------------
-- Primitives
---------------------------------------------------------------------------

-- A rectangle (top left x, y), colour col { r, g, b }, alpha a.
function c:Rect(x, y, w, h, col, a)
    local t = Tex(self, WHITE, col[1], col[2], col[3], a or 1)
    PlaceBox(self, t, x, y, w, h)
end

-- A gradient: orient "V" (c1 at the top, c2 at the bottom) or "H" (c1 left, c2 right).
function c:Grad(x, y, w, h, orient, c1, a1, c2, a2)
    local t = Tex(self, WHITE, 1, 1, 1, 1, nil, nil, nil, nil, true)
    local k = t.k
    local key = (orient == "H" and "H" or "V") .. c1[1] .. c1[2] .. c1[3] .. a1 .. c2[1] .. c2[2] .. c2[3] .. a2
    if k.grad ~= key then
        k.grad = key
        local lo, hi, la, ha, o = c2, c1, a2, a1, "VERTICAL"
        if orient == "H" then lo, hi, la, ha, o = c1, c2, a1, a2, "HORIZONTAL" end
        local ok = false
        if t.SetGradient and CreateColor then
            ok = pcall(t.SetGradient, t, o, CreateColor(lo[1], lo[2], lo[3], la), CreateColor(hi[1], hi[2], hi[3], ha))
        end
        if not ok and t.SetGradientAlpha then
            ok = pcall(t.SetGradientAlpha, t, o, lo[1], lo[2], lo[3], la, hi[1], hi[2], hi[3], ha)
        end
        if not ok then t:SetVertexColor(hi[1], hi[2], hi[3], (la + ha) / 2) end
    end
    PlaceBox(self, t, x, y, w, h)
end

-- A picture centred on (cx, cy), w x h, tinted col (nil = white), alpha a, tex coords l r t b, turned by rot.
function c:Img(file, cx, cy, w, h, col, a, l, r, t, b, rot)
    local tx = Tex(self, file, col and col[1] or 1, col and col[2] or 1, col and col[3] or 1, a or 1, l, r, t, b)
    PlaceBox(self, tx, cx - w / 2, cy - h / 2, w, h)
    if rot and rot ~= 0 then tx:SetRotation(rot); tx.k.rot = true end
    return tx
end

function c:Disc(cx, cy, r, col, a) self:Img(Pen.DISC, cx, cy, r * 2, r * 2, col, a) end

-- A soft glow (radial, additive) w x h on (cx, cy).
function c:Glow(cx, cy, w, h, col, a)
    local add = self.add
    self.add = true
    self:Img(Pen.GLOW, cx, cy, w, h, col, a)
    self.add = add
end

-- A line from (x1, y1) to (x2, y2), w px thick.
function c:Line(x1, y1, x2, y2, w, col, a)
    local ln = Next(self, "ln")
    local k = ln.k
    local layer, sub = Slot(self)
    if k.L ~= layer or k.S ~= sub then ln:SetDrawLayer(layer, sub); k.L, k.S = layer, sub end
    local sc = self.sc
    local ax, ay = self.ox + x1 * sc, self.oy + y1 * sc
    local bx, by = self.ox + x2 * sc, self.oy + y2 * sc
    ln:SetStartPoint("TOPLEFT", self.h, ax, -ay)
    ln:SetEndPoint("TOPLEFT", self.h, bx, -by)
    ln:SetThickness(max(0.3, w * sc))
    ln:SetVertexColor(col[1], col[2], col[3], a or 1)
    ln:SetAlpha(self.a)
    Blend(ln, self.add)
end

-- An arc of an ellipse (angles in radians, 0 = right, clockwise as y runs down), w px thick; glow = a soft wider
-- line under it in the same colour (the mockup's shadowBlur).
function c:Arc(cx, cy, rx, ry, a0, a1, w, col, a, glow)
    local span = a1 - a0
    if abs(span) < 0.0001 then return end
    local n = max(3, ceil(abs(span) / (TAU / 40)))
    if glow then
        local add = self.add
        self.add = true
        local px, py = cx + rx * cos(a0), cy + ry * sin(a0)
        for i = 1, n do
            local ang = a0 + span * i / n
            local qx, qy = cx + rx * cos(ang), cy + ry * sin(ang)
            self:Line(px, py, qx, qy, w * 3.2, col, (a or 1) * 0.28)
            px, py = qx, qy
        end
        self.add = add
    end
    local px, py = cx + rx * cos(a0), cy + ry * sin(a0)
    for i = 1, n do
        local ang = a0 + span * i / n
        local qx, qy = cx + rx * cos(ang), cy + ry * sin(ang)
        self:Line(px, py, qx, qy, w, col, a)
        px, py = qx, qy
    end
end
function c:Ring(cx, cy, r, w, col, a, glow) self:Arc(cx, cy, r, r, 0, TAU, w, col, a, glow) end

-- A filled triangle (the corners of one texture bent onto it).
function c:Tri(x1, y1, x2, y2, x3, y3, col, a)
    local t = Tex(self, WHITE, col[1], col[2], col[3], a or 1)
    local k = t.k
    if not k.nosnap then
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
        if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
        k.nosnap = true
    end
    local sc = self.sc
    local ax, ay = self.ox + x1 * sc, -(self.oy + y1 * sc)
    local bx, by = self.ox + x2 * sc, -(self.oy + y2 * sc)
    local cx, cy = self.ox + x3 * sc, -(self.oy + y3 * sc)
    -- a 1 x 1 base on the first corner; corners: upper left = a, lower left = b, upper and lower right = c
    if k.x ~= ax or k.y ~= -ay or k.w ~= 1 or k.h ~= 1 then
        t:ClearAllPoints()
        t:SetPoint("CENTER", self.h, "TOPLEFT", ax, ay)
        t:SetSize(1, 1)
        k.x, k.y, k.w, k.h = ax, -ay, 1, 1
    end
    local ox, oy = ax, ay
    t:SetVertexOffset(UPPER_LEFT_VERTEX or 1, ax - ox + 0.5, ay - oy - 0.5)
    t:SetVertexOffset(LOWER_LEFT_VERTEX or 2, bx - ox + 0.5, by - oy + 0.5)
    t:SetVertexOffset(UPPER_RIGHT_VERTEX or 3, cx - ox - 0.5, cy - oy - 0.5)
    t:SetVertexOffset(LOWER_RIGHT_VERTEX or 4, cx - ox - 0.5, cy - oy + 0.5)
    k.bent = true
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------

-- The width of a text in the mockup's px.
local wcache, wn = {}, 0
function c:W(font, size, s, ow)
    size = floor(size * 2 + 0.5) / 2
    local key = font .. size .. (ow or 0) .. s
    local w = wcache[key]
    if w then return w end
    Pen:Overlay()
    measure:SetFont(FONTS[font] or FRIZ, max(1, size), OW[ow or 0])
    measure:SetText(s)
    w = (measure.GetUnboundedStringWidth and measure:GetUnboundedStringWidth()) or measure:GetStringWidth() or 0
    wn = wn + 1
    if wn > 3000 then wcache, wn = {}, 0 end
    wcache[key] = w
    return w
end
Pen.W = function(_, ...) return c:W(...) end

local ALIGN = { CENTER = "CENTER", LEFT = "LEFT", RIGHT = "RIGHT" }

-- A text at (x, y): its middle on y, and its centre / left edge / right edge on x (align). ow: 0 none (a soft shadow),
-- 1 an outline, 2 a thick outline. glow: a soft light in that colour under it (alpha glowA).
function c:Text(s, x, y, font, size, col, ow, align, glow, glowA)
    align = align or "CENTER"
    if glow then
        local w = self:W(font, size, s, ow)
        local gx = (align == "LEFT" and x + w / 2) or (align == "RIGHT" and x - w / 2) or x
        -- (an additive soft light is brighter than the mockup's blurred shadow: it is drawn at 40%)
        self:Glow(gx, y, w + 26, size * 1.9, glow, (glowA or 0.6) * 0.4)
    end
    local fs = Next(self, "fs")
    local k = fs.k
    local layer, sub = Slot(self)
    if k.L ~= layer or k.S ~= sub then fs:SetDrawLayer(layer, sub); k.L, k.S = layer, sub end
    local sc = self.sc
    local z = floor(size * sc + 0.5)
    if z < 1 then z = 1 end
    local path, flags = FONTS[font] or FRIZ, OW[ow or 0]
    if k.p ~= path or k.z ~= z or k.o ~= flags then
        fs:SetFont(path, z, flags)
        if flags == "" then fs:SetShadowOffset(1, -1); fs:SetShadowColor(0, 0, 0, 0.85)
        else fs:SetShadowOffset(0, 0) end
        k.p, k.z, k.o = path, z, flags
    end
    if k.s ~= s then fs:SetText(s); k.s = s end
    fs:SetTextColor(col[1], col[2], col[3], 1)
    fs:SetAlpha(self.a)
    local px, py = self.ox + x * sc, self.oy + y * sc
    if k.x ~= px or k.y ~= py or k.al ~= align then
        fs:ClearAllPoints()
        fs:SetPoint(ALIGN[align] or "CENTER", self.h, "TOPLEFT", px, -py)
        k.x, k.y, k.al = px, py, align
    end
end

-- Rows: parts laid out side by side, measured first (the mockup's row()). R() starts one, RI / RT add an icon / a
-- text, RW(gap) is its width, RD(x, y, gap, align) draws it and returns the width.
local parts, np = {}, 0
function c:R() np = 0 end
local function Part()
    np = np + 1
    local p = parts[np]
    if not p then p = {}; parts[np] = p end
    return p
end
function c:RI(tex, sz, shape, ring)
    local p = Part()
    p.img, p.sz, p.shape, p.ring, p.t = tex, sz, shape or "sq", ring, nil
end
function c:RT(s, font, size, col, ow, dy, glow, glowA)
    local p = Part()
    p.img, p.t, p.font, p.size, p.col, p.ow, p.dy, p.glow, p.ga = nil, s, font, size, col, ow, dy, glow, glowA
end
function c:RW(gap)
    gap = gap or 5
    local w = 0
    for i = 1, np do
        local p = parts[i]
        p.w = p.img and p.sz or self:W(p.font, p.size, p.t, p.ow)
        w = w + p.w
    end
    return w + gap * max(0, np - 1)
end
function c:RD(x, y, gap, align)
    gap = gap or 5
    local w = self:RW(gap)
    local cx = (align == "LEFT" and x) or (align == "RIGHT" and x - w) or (x - w / 2)
    local n = np
    for i = 1, n do
        local p = parts[i]
        if p.img then self:Icon(p.img, cx + p.sz / 2, y, p.sz, p.shape, p.ring)
        else self:Text(p.t, cx + p.w / 2, y + (p.dy or 0), p.font, p.size, p.col, p.ow, "CENTER", p.glow, p.ga) end
        cx = cx + p.w + gap
    end
    return w
end

---------------------------------------------------------------------------
-- Icons: sq (a black 1 px edge), round (the portrait disc, a black ring and a thin gold one), framed (black, a gold
-- rim and a lit top line), bezel (Gilded's gold square), quick (the game's action button frame)
---------------------------------------------------------------------------

local BLACK = { 0, 0, 0 }
local GOLDRING = { 245 / 255, 220 / 255, 143 / 255 }
local GOLDRIM = { 1, 0.82, 0 }

MAKE.ic = function(h)
    local u = { parts = {} }
    u.tex = h:CreateTexture(nil, "ARTWORK")
    u.parts[1] = u.tex
    if h.CreateMaskTexture then
        u.mask = h:CreateMaskTexture()
        u.mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        u.mask:SetAllPoints(u.tex)
    end
    u.k = {}
    return u
end

local function IconTex(self, u, tex, cx, cy, sz, inset, round, coords)
    local t = u.tex
    local k = u.k
    local layer, sub = Slot(self)
    if k.L ~= layer or k.S ~= sub then t:SetDrawLayer(layer, sub); k.L, k.S = layer, sub end
    if k.f ~= tex then t:SetTexture(tex); k.f = tex end
    local m = coords or (round and 0.06 or 0.08)
    if k.m ~= m then
        if coords then t:SetTexCoord(coords[1], coords[2], coords[3], coords[4]) else t:SetTexCoord(m, 1 - m, m, 1 - m) end
        k.m = m
    end
    if u.mask then
        if round and not k.masked then pcall(t.AddMaskTexture, t, u.mask); k.masked = true
        elseif not round and k.masked then pcall(t.RemoveMaskTexture, t, u.mask); k.masked = false end
    end
    t:SetVertexColor(1, 1, 1, 1)
    t:SetAlpha(self.a)
    local sc = self.sc
    local s = (sz - 2 * inset) * sc
    local px, py = self.ox + cx * sc, self.oy + cy * sc
    if k.x ~= px or k.y ~= py or k.s ~= s then
        t:ClearAllPoints()
        t:SetPoint("CENTER", self.h, "TOPLEFT", px, -py)
        t:SetSize(max(0.001, s), max(0.001, s))
        k.x, k.y, k.s = px, py, s
    end
end

function c:Icon(tex, cx, cy, sz, shape, ring, coords)
    if not tex then return end
    local r = sz / 2
    if shape == "round" then
        self:Disc(cx, cy, r + 2.2, BLACK, 0.9)
        local u = Next(self, "ic")
        IconTex(self, u, tex, cx, cy, sz, 0, true, coords)
        self:Ring(cx, cy, r + 0.4, 1.2, ring or GOLDRING, 0.95)
    elseif shape == "framed" then
        self:Rect(cx - r - 2, cy - r - 2, sz + 4, sz + 4, BLACK, 1)
        local u = Next(self, "ic")
        IconTex(self, u, tex, cx, cy, sz, 0, false)
        local x0, y0, s = cx - r - 1.5, cy - r - 1.5, sz + 3
        self:Rect(x0, y0, s, 1, GOLDRIM, 0.8)
        self:Rect(x0, y0 + s - 1, s, 1, GOLDRIM, 0.8)
        self:Rect(x0, y0, 1, s, GOLDRIM, 0.8)
        self:Rect(x0 + s - 1, y0, 1, s, GOLDRIM, 0.8)
        self:Rect(cx - r, cy - r, sz, 1, { 1, 1, 1 }, 0.4)
    elseif shape == "bezel" then
        local ins = sz * 0.13
        self:Rect(cx - r + 1, cy - r + 1, sz - 2, sz - 2, BLACK, 1)
        local u = Next(self, "ic")
        IconTex(self, u, tex, cx, cy, sz, ins, false)
        self:Img(Pen.GILT .. "bezel", cx, cy, sz, sz)
    elseif shape == "quick" then
        local u = Next(self, "ic")
        IconTex(self, u, tex, cx, cy, sz, 0, false)
        local f = sz * 66 / 36
        self:Img(Pen.QUICK, cx, cy, f, f)
    else
        self:Rect(cx - r - 1, cy - r - 1, sz + 2, sz + 2, BLACK, 1)
        local u = Next(self, "ic")
        IconTex(self, u, tex, cx, cy, sz, 0, false)
    end
end

---------------------------------------------------------------------------
-- Gilded text: the mockup's metal gradient as three bands of the same text (the dark foot under a dark worked edge,
-- the gold body clipped to the top half, a pale crown clipped to the top fifth) and a shine: a narrow clip running
-- across with the text in white.
---------------------------------------------------------------------------

MAKE.gt = function(h)
    local f = CreateFrame("Frame", nil, h)
    f:SetSize(1, 1)
    f:SetPoint("TOPLEFT", h, "TOPLEFT", 0, 0)
    f:SetFrameLevel(h:GetFrameLevel() + 2)
    local u = { f = f, k = {} }
    u.base = f:CreateFontString(nil, "OVERLAY")
    local function Band()
        local b = CreateFrame("Frame", nil, f)
        if b.SetClipsChildren then b:SetClipsChildren(true) end
        local fs = b:CreateFontString(nil, "OVERLAY")
        return b, fs
    end
    u.b1, u.t1 = Band()
    u.b2, u.t2 = Band()
    u.b3, u.t3 = Band()
    u.b4, u.t4 = Band()
    u.b5, u.t5 = Band()
    for _, fs in ipairs({ u.base, u.t1, u.t2, u.t3, u.t4, u.t5 }) do if fs.SetWordWrap then fs:SetWordWrap(false) end end
    function u:Show() self.f:Show() end
    function u:Hide() self.f:Hide() end
    return u
end

-- pal = { top, body, body2, foot } colours (the mockup's four stops); face "Friz" | "Morpheus"; shine (0..1, nil =
-- none): where the shine is across the text.
function c:GText(s, x, y, size, pal, face, align, shine, ow)
    local u = Next(self, "gt")
    local k = u.k
    local f = u.f
    local hl = self.h:GetFrameLevel() + 2
    if k.lvl ~= hl then f:SetFrameLevel(hl); k.lvl = hl end
    f:SetAlpha(self.a)
    local sc = self.sc
    local z = floor(size * sc + 0.5)
    if z < 1 then z = 1 end
    local path = FONTS[face or "Friz"] or FRIZ
    local w = self:W(face or "Friz", size, s, ow or 2) * sc
    local px, py = self.ox + x * sc, self.oy + y * sc
    align = align or "CENTER"
    local left = (align == "LEFT" and px) or (align == "RIGHT" and px - w) or (px - w / 2)
    local fresh = k.s ~= s or k.z ~= z or k.p ~= path
    if fresh then
        u.base:SetFont(path, z, OW[ow or 2])
        u.base:SetShadowOffset(0, -2 * sc)
        u.base:SetShadowColor(0, 0, 0, 0.75)
        for _, fs in ipairs({ u.t1, u.t2, u.t3, u.t4, u.t5 }) do fs:SetFont(path, z, ""); fs:SetShadowOffset(0, 0) end
        for _, fs in ipairs({ u.base, u.t1, u.t2, u.t3, u.t4, u.t5 }) do fs:SetText(s) end
        k.s, k.z, k.p = s, z, path
    end
    local P1, P2, P3, P4 = pal[1], pal[2], pal[3], pal[4]
    u.base:SetTextColor((P3[1] + P4[1]) / 2, (P3[2] + P4[2]) / 2, (P3[3] + P4[3]) / 2, 1)
    u.t1:SetTextColor(P2[1], P2[2], P2[3], 1)
    u.t2:SetTextColor(P1[1], P1[2], P1[3], 1)
    -- (each band's text sits where the base's does; the bands cut it)
    if fresh or k.x ~= left or k.y ~= py or k.al ~= align then
        local hz = z * 0.62
        for _, fs in ipairs({ u.base, u.t1, u.t2, u.t3, u.t4, u.t5 }) do
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", self.h, "TOPLEFT", left, -py)
        end
        u.b1:ClearAllPoints(); u.b1:SetPoint("TOPLEFT", self.h, "TOPLEFT", left - 4, -(py - hz)); u.b1:SetSize(w + 8, hz)
        u.b2:ClearAllPoints(); u.b2:SetPoint("TOPLEFT", self.h, "TOPLEFT", left - 4, -(py - hz)); u.b2:SetSize(w + 8, hz * 0.6)
        k.x, k.y, k.al = left, py, align
    end
    -- (the shine: a bright middle and two softer sides, the mockup's gradient band)
    if shine and shine > -0.3 and shine < 1.3 then
        local p = clamp(shine)
        local bw = max(3, w * 0.06)
        local mid = left + p * w
        for _, band in ipairs({ { u.b4, u.t4, -1.5, 0.35 }, { u.b3, u.t3, -0.5, 0.85 }, { u.b5, u.t5, 0.5, 0.35 } }) do
            local b, fs, off, a = band[1], band[2], band[3], band[4]
            b:Show()
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", self.h, "TOPLEFT", mid + off * bw, -(py - z))
            b:SetSize(bw, z * 2)
            fs:SetTextColor(1, 1, 1, a)
        end
    else
        u.b3:Hide(); u.b4:Hide(); u.b5:Hide()
    end
    return w / sc
end
