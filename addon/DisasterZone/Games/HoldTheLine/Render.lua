if DisasterZoneBoot and DisasterZoneBoot.Run("Games/HoldTheLine/Render.lua", ...) then return end -- DisasterZone Games/HoldTheLine/Render.lua
-- ns.HTLRender: draws a Hold the Line run (ns.HTL) into a view - the mockup's draw() (game.js) in the client's widgets,
-- layer for layer: the ground, stains, ground effects (additive), shadows and runes, the bodies sorted by depth, the
-- smoke and gore, the colour grade (MOD) and the dark round the hero, the additive effects, fog, vignette, numbers,
-- then the HUD. A view is a clipped frame with a scaled carrier (1 unit = 1 world unit); every world texture hangs
-- from one origin frame, so the camera is one SetPoint. Drawing is immediate: textures come from pools each frame and
-- what was not used is hidden (as The Binding of Illidan's UI). Rotations are 8-value texcoords; long, turned pictures
-- (streaks, trails, rays) are textured Lines.
local _, ns = ...

local D, A = ns.HTLData, ns.HTLArt
local E = ns.HTL
local Rd = {}
ns.HTLRender = Rd

local floor, min, max, abs, sqrt, sin, cos, atan2, pi = math.floor, math.min, math.max, math.abs, math.sqrt, math.sin, math.cos, math.atan2 or math.atan, math.pi
local TAU = pi * 2
local MOBS, C = D.MOBS, D.C
local FX = D.MEDIA .. "FX\\"
local UIM = D.MEDIA .. "UI\\"
local SPLAT, VIGNETTE = "Interface\\AddOns\\DisasterZone\\Media\\Illidan\\splat", "Interface\\AddOns\\DisasterZone\\Media\\Illidan\\vignette"
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local FONT, MORPHEUS = "Fonts\\FRIZQT__.TTF", "Fonts\\MORPHEUS.TTF"
local NB = 28                     -- depth bands over the view (each with 16 sublevels)
Rd.FONT, Rd.MORPHEUS = FONT, MORPHEUS

local V                           -- the view being drawn
local CAMX, CAMY = 0, 0

---------------------------------------------------------------------------
-- pools
---------------------------------------------------------------------------
local function NewPool(frame, kind, layer, sub, blend)
    return { frame = frame, kind = kind, layer = layer, sub = sub or 0, blend = blend, items = {}, n = 0 }
end
local function Take(pool)
    pool.n = pool.n + 1
    local t = pool.items[pool.n]
    if not t then
        if pool.kind == "line" then t = pool.frame:CreateLine(nil, pool.layer, nil, pool.sub)
        elseif pool.kind == "font" then t = pool.frame:CreateFontString(nil, pool.layer) t:SetFont(FONT, 12, "OUTLINE") t.size = 12
        else t = pool.frame:CreateTexture(nil, pool.layer, nil, pool.sub) end
        if pool.blend and t.SetBlendMode then t:SetBlendMode(pool.blend) end
        pool.items[pool.n] = t
    end
    t:Show()
    return t
end
local function Begin(v) for _, p in pairs(v.pools) do p.n = 0 end end
local function Finish(v)
    for _, p in pairs(v.pools) do
        for i = p.n + 1, #p.items do local t = p.items[i] if t:IsShown() then t:Hide() end end
    end
end
local function File(t, f) if t.file ~= f then t:SetTexture(f) t.file = f end end
local function Size(t, w, h) w, h = max(0.05, w), max(0.05, h) if t.w ~= w or t.h ~= h then t:SetSize(w, h) t.w, t.h = w, h end end
local function At(t, x, y, w, h) t:SetPoint("CENTER", V.origin, "TOPLEFT", x, -y) Size(t, w, h) end
local function AtTL(t, x, y, w, h) t:SetPoint("TOPLEFT", V.origin, "TOPLEFT", x, -y) Size(t, w, h) end
local function Col(t, c, a) if c then t:SetVertexColor(c[1], c[2], c[3], a or 1) else t:SetVertexColor(1, 1, 1, a or 1) end end
local function Rot(t, rot, u0, v0, u1, v1)       -- the picture turned by rot (clockwise, as the canvas) inside its rect
    u0, v0, u1, v1 = u0 or 0, v0 or 0, u1 or 1, v1 or 1
    if not rot or rot == 0 then t:SetTexCoord(u0, u1, v0, v1) return end
    local cu, cv, hu, hv = (u0 + u1) / 2, (v0 + v1) / 2, (u1 - u0) / 2, (v1 - v0) / 2
    local c, s = cos(rot), sin(rot)
    -- texcoords of the rect's corners: UL, LL, UR, LR (screen y down)
    local function uv(x, y) return cu + (x * c + y * s) * hu, cv + (-x * s + y * c) * hv end
    local ulx, uly = uv(-1, -1)
    local llx, lly = uv(-1, 1)
    local urx, ury = uv(1, -1)
    local lrx, lry = uv(1, 1)
    t:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
end
-- a textured line: a picture w long, h thick, its middle at x, y, turned by ang
local function LineAt(l, x, y, w, h, ang)
    local dx, dy = cos(ang) * w / 2, sin(ang) * w / 2
    l:SetStartPoint("TOPLEFT", V.origin, x - dx, -(y - dy))
    l:SetEndPoint("TOPLEFT", V.origin, x + dx, -(y + dy))
    l:SetThickness(max(0.1, h * (V.lineK or 1)))
end
local function FxFile(k) return FX .. k end
local function FxCrop(k) local c = A.FX_CROP[k] if c then return c[1], c[2] end return 1, 1 end

---------------------------------------------------------------------------
-- the view
---------------------------------------------------------------------------
-- parent: the frame to fill. opts: { preview = true } (a card's little scene: no HUD)
function Rd.NewView(parent, opts)
    local v = { pools = {}, opts = opts or {}, fonts = {} }
    v.root = CreateFrame("Frame", nil, parent)
    v.root:SetAllPoints()
    pcall(v.root.SetClipsChildren, v.root, true)
    local bg = v.root:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.03, 0.05, 1)
    v.scaler = CreateFrame("Frame", nil, v.root)
    v.scaler:SetPoint("TOPLEFT")
    v.scaler:SetSize(D.VW, D.VH)
    v.origin = CreateFrame("Frame", nil, v.scaler)
    v.origin:SetSize(1, 1)
    local lv = v.root:GetFrameLevel()
    local function Layer(n) local f = CreateFrame("Frame", nil, v.scaler) f:SetAllPoints() f:SetFrameLevel(lv + n) return f end
    v.ground = Layer(2)
    v.bands = {}
    for i = 1, NB do v.bands[i] = Layer(3 + i) end
    v.airNorm = Layer(4 + NB)
    v.grade = Layer(5 + NB)
    v.add = Layer(6 + NB)
    v.post = Layer(7 + NB)
    v.text = Layer(8 + NB)
    v.hud = Layer(9 + NB)
    v.top = Layer(14 + NB)
    local P = v.pools
    -- ground
    v.groundTex = v.ground:CreateTexture(nil, "BACKGROUND", nil, -8)
    v.groundTex:SetAllPoints()
    v.groundTex:SetTexture(D.MEDIA .. "ground", "REPEAT", "REPEAT")
    P.chunkDec = NewPool(v.ground, "line", "BACKGROUND", -6)
    P.decal = NewPool(v.ground, "tex", "BACKGROUND", -5)
    P.under = NewPool(v.ground, "tex", "BACKGROUND", -4)
    P.underL = NewPool(v.ground, "line", "BACKGROUND", -4)
    P.tele = NewPool(v.ground, "tex", "BACKGROUND", -3)
    P.glow = NewPool(v.ground, "tex", "BORDER", 0, "ADD")
    P.glowL = NewPool(v.ground, "line", "BORDER", 1, "ADD")
    P.flat = NewPool(v.ground, "tex", "BORDER", 2, "ADD")
    P.flatN = NewPool(v.ground, "tex", "BORDER", 2)
    P.shadow = NewPool(v.ground, "tex", "ARTWORK", 0)
    P.gem = NewPool(v.ground, "tex", "OVERLAY", 0)
    -- the bodies, by depth band (sublevel = finer depth inside a band)
    v.bandPools = {}
    for i = 1, NB do
        local bp = { spr = NewPool(v.bands[i], "tex", "ARTWORK", 0), add = NewPool(v.bands[i], "tex", "ARTWORK", 0, "ADD"), glow = NewPool(v.bands[i], "tex", "BORDER", 0, "ADD") }
        v.bandPools[i] = bp
        P["b" .. i .. "s"], P["b" .. i .. "a"], P["b" .. i .. "g"] = bp.spr, bp.add, bp.glow
    end
    P.airN = NewPool(v.airNorm, "tex", "ARTWORK", 0)
    P.airNL = NewPool(v.airNorm, "line", "ARTWORK", 0)
    -- grade + darkness
    v.tint = v.grade:CreateTexture(nil, "BACKGROUND", nil, 0)
    v.tint:SetAllPoints(v.scaler)
    v.tint:SetColorTexture(D.STAGE.tint[1], D.STAGE.tint[2], D.STAGE.tint[3], 1)
    v.tint:SetBlendMode("MOD")
    v.hole = v.grade:CreateTexture(nil, "ARTWORK", nil, 0)
    v.hole:SetTexture(UIM .. "dark_hole")
    v.darkRect = {}
    for i = 1, 4 do local t = v.grade:CreateTexture(nil, "ARTWORK", nil, 0) t:SetColorTexture(1, 1, 1, 1) v.darkRect[i] = t end
    -- additive effects
    P.add = NewPool(v.add, "tex", "ARTWORK", 0, "ADD")
    P.addL = NewPool(v.add, "line", "ARTWORK", 1, "ADD")
    P.addN = NewPool(v.add, "tex", "ARTWORK", 2)               -- (the shield's face, the grenade: plain pictures among the lights)
    P.addTop = NewPool(v.add, "tex", "OVERLAY", 0, "ADD")
    P.addCore = NewPool(v.add, "tex", "ARTWORK", 1, "ADD")      -- (gradients stay on a texture: their own pool)
    P.trail = NewPool(v.add, "line", "BORDER", 0, "ADD")
    -- post
    v.fog = v.post:CreateTexture(nil, "BACKGROUND", nil, 0)
    v.fog:SetAllPoints(v.scaler)
    v.fog:SetTexture(D.MEDIA .. "fog", "REPEAT", "REPEAT")
    v.fog:SetBlendMode("ADD")
    v.vig = v.post:CreateTexture(nil, "BORDER", nil, 0)
    v.vig:SetTexture(VIGNETTE)
    v.dim = v.post:CreateTexture(nil, "ARTWORK", nil, 0)
    v.dim:SetAllPoints(v.scaler)
    v.flashT = v.post:CreateTexture(nil, "OVERLAY", nil, 0)
    v.flashT:SetAllPoints(v.scaler)
    P.text = NewPool(v.text, "font", "OVERLAY")
    -- HUD
    P.hudBack = NewPool(v.hud, "tex", "BACKGROUND", 0)
    P.hud = NewPool(v.hud, "tex", "ARTWORK", 0)
    P.hudTop = NewPool(v.hud, "tex", "ARTWORK", 2)
    P.hudGlow = NewPool(v.hud, "tex", "OVERLAY", 0, "ADD")
    P.hudFrame = NewPool(v.hud, "tex", "OVERLAY", 1)
    P.hudText = NewPool(v.hud, "font", "OVERLAY")
    P.hudLine = NewPool(v.hud, "line", "ARTWORK", 1)
    v.cdSwipe = {}
    return v
end

-- the view's size: the panel's height shows VH world units, its width as much as it holds
function Rd.Layout(v, w, h)
    if not w or w < 50 then w, h = 786, 518 end
    local k = h / D.VH
    v.K = k
    v.VW, v.VH = w / k, D.VH
    v.scaler:SetScale(k)
    v.scaler:SetSize(v.VW, v.VH)
    return v.VW, v.VH
end
-- (a card's scene: a set world width; the height follows the frame)
function Rd.LayoutWide(v, w, h, vw)
    local k = w / vw
    v.K = k
    v.VW, v.VH = vw, h / k
    v.scaler:SetScale(k)
    v.scaler:SetSize(v.VW, v.VH)
    return v.VW, v.VH
end

---------------------------------------------------------------------------
-- drawing helpers (world units)
---------------------------------------------------------------------------
local function inView(x, y, m) return x > CAMX - m and x < CAMX + V.VW + m and y > CAMY - m and y < CAMY + V.VH + m * 1.6 end
Rd.inView = function(v, x, y, m) V = v return inView(x, y, m) end

-- a picture from the FX set, centred, w x h, turned, in a pool
local function Tex(pool, k, x, y, w, h, a, rot, tint)
    local t = Take(V.pools[pool])
    File(t, FxFile(k))
    local cu, cv = FxCrop(k)
    Rot(t, rot, 0, 0, cu, cv)
    Col(t, tint, a)
    At(t, x, y, w, h)
    return t
end
local function Glow(pool, x, y, r, c, a)
    local t = Take(V.pools[pool])
    File(t, UIM .. "glow")
    t:SetTexCoord(0, 1, 0, 1)
    Col(t, c, a)
    At(t, x, y, r * 2, r * 2)
    return t
end
local function FlatTex(pool, k, x, y, r, a, rot, tint)   -- on the ground: the circle seen at the view's slant
    return Tex(pool, k, x, y, r * 2, r * 2 / 1.3, a, rot, tint)
end
local GLOWC = { gold = { 1, 200 / 255, 110 / 255 }, blue = { 120 / 255, 180 / 255, 1 }, violet = { 200 / 255, 120 / 255, 1 }, fire = { 1, 130 / 255, 50 / 255 },
    green = { 140 / 255, 1, 120 / 255 }, red = { 1, 60 / 255, 50 / 255 }, white = { 1, 1, 1 } }
Rd.GLOWC = GLOWC

-- a unit's frame: page, texcoords, size and offset (Art.lua; world units)
local function Frame(key, dir, col)
    local U = A.UNITS[key]
    local i = (dir * U.cols + col) * 7
    local f = U.f
    local page = f[i + 1]
    if not page then return nil end
    local pg = U.pages[page]
    return pg, f[i + 2], f[i + 3], f[i + 4], f[i + 5], f[i + 6], f[i + 7]
end
Rd.Frame = Frame
local function Sprite(bp, sub, key, dir, col, x, y, alpha, flashA, scale, sx, sy, tint)
    local pg, fx, fy, fw, fh, dx, dy = Frame(key, dir, col)
    if not pg then return end
    local kx, ky = (scale or 1) * (sx or 1), (scale or 1) * (sy or 1)
    local u0, v0, u1, v1 = fx / pg[2], fy / pg[3], (fx + fw) / pg[2], (fy + fh) / pg[3]
    local t = Take(bp.spr)
    t:SetDrawLayer("ARTWORK", sub)
    File(t, pg[1])
    t:SetTexCoord(u0, u1, v0, v1)
    if tint then t:SetVertexColor(tint[1], tint[2], tint[3], alpha or 1) else t:SetVertexColor(1, 1, 1, alpha or 1) end
    AtTL(t, x + dx * kx, y + dy * ky, fw * kx, fh * ky)
    if flashA and flashA > 0 then
        local f2 = Take(bp.add)
        f2:SetDrawLayer("ARTWORK", min(7, sub + 1))
        File(f2, pg[1])
        f2:SetTexCoord(u0, u1, v0, v1)
        f2:SetVertexColor(1, 1, 1, min(1, flashA) * (alpha or 1))
        AtTL(f2, x + dx * kx, y + dy * ky, fw * kx, fh * ky)
    end
end
Rd.Sprite = function(v, bp, ...) V = v Sprite(bp, ...) end

-- the depth band and sublevel of a world y
local function Band(y)
    local f = (y - CAMY + 60) / (V.VH + 180)
    f = min(0.99999, max(0, f))
    local idx = f * NB
    local b = floor(idx)
    return V.bandPools[b + 1], floor((idx - b) * 15.99) - 8
end

---------------------------------------------------------------------------
-- particles (the mockup's drawParts)
---------------------------------------------------------------------------
local function lerp(a, b, k) return a + (b - a) * k end
local function easeOut(k) return 1 - (1 - k) * (1 - k) end
local PL = { flat = { "flat", "flatN" }, under = { "under", "under" }, air = { "add", "airN" } }
local function DrawParts(run, layer, blend)
    local pools = V.pools
    for _, p in ipairs(run.parts) do
        local lay = p.flat and "flat" or p.under and "under" or "air"
        if lay == layer and not (blend == "add" and not p.add) and not (blend == "norm" and p.add) then
            if inView(p.x, p.y - p.z, p.s1 + p.s0 + 20) then
                local k = p.t / p.life
                local a = lerp(p.a0, p.a1, p.ease == "late" and k * k or k)
                if p.fi > 0 and k < p.fi then a = a * k / p.fi end
                if a > 0.003 then
                    local s = lerp(p.s0, p.s1, p.sizeEase == "in" and k * k or easeOut(k))
                    local w, h = s * p.sx, s * p.sy
                    local x, y = p.x, p.y - p.z
                    local file = FxFile(p.img)
                    local cu, cv = FxCrop(p.img)
                    local u0, v0, u1, v1 = 0, 0, cu, cv
                    if p.cell then local g = p.cells or 8 local cw, ch = cu / g, cv / g local i = p.cell u0, v0 = (i % g) * cw, floor(i / g) * ch u1, v1 = u0 + cw, v0 + ch end
                    local poolKey = PL[lay][p.add and 1 or 2]
                    if p.flat then h = h / 1.3 end
                    if p.stretch then
                        local ang = atan2(p.vy - p.vz, p.vx) + (p.rot or 0)
                        local l = w * (1 + p.stretch * sqrt(p.vx * p.vx + (p.vy - p.vz) ^ 2) / 300)
                        local ln = Take(pools[lay == "air" and (p.add and "addL" or "airNL") or (lay == "under" and "underL" or "glowL")])
                        File(ln, file)
                        ln:SetTexCoord(u0, u1, v0, v1)
                        Col(ln, p.tint, min(1, a))
                        LineAt(ln, x, y, l, h, ang)
                    elseif p.rot ~= 0 and abs(w - h) > 0.5 and not p.flat then
                        local ln = Take(pools[lay == "air" and (p.add and "addL" or "airNL") or (lay == "under" and "underL" or "glowL")])
                        File(ln, file)
                        ln:SetTexCoord(u0, u1, v0, v1)
                        Col(ln, p.tint, min(1, a))
                        LineAt(ln, x, y, w, h, p.rot)
                    else
                        local t = Take(pools[poolKey])
                        File(t, file)
                        Rot(t, p.rot, u0, v0, u1, v1)
                        Col(t, p.tint, min(1, a))
                        At(t, x, y, w, h)
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- the world
---------------------------------------------------------------------------
local SCORCH = { 18 / 255, 14 / 255, 12 / 255 }
local GOLDSTAIN = { 90 / 255, 66 / 255, 20 / 255 }
local function DrawDecals(run)
    local P = V.pools
    -- old scorch and bone dust, baked per chunk
    for cx = floor(CAMX / E.CH), floor((CAMX + V.VW) / E.CH) do
        for cy = floor(CAMY / E.CH), floor((CAMY + V.VH) / E.CH) do
            local c = E.Chunk(run, cx, cy)
            for _, d in ipairs(c.dec) do
                local l = Take(P.chunkDec)
                File(l, SPLAT)
                local cell = floor(d.r) % 4
                l:SetTexCoord(cell / 4, (cell + 1) / 4, 0, 1)
                l:SetVertexColor(SCORCH[1], SCORCH[2], SCORCH[3], 0.3)
                LineAt(l, d.x, d.y, d.r * 2, d.r * 1.2, d.a)
            end
        end
    end
    for _, d in ipairs(run.decals) do
        if inView(d.x, d.y, d.r) then
            local a = min(1, d.t * 8) * (d.t > 34 and (40 - d.t) / 6 or 1) * (d.scorch and 0.55 or d.gold and 0.5 or 0.6)
            local k = min(1, d.t * 10)
            local t = Take(P.decal)
            File(t, SPLAT)
            Rot(t, d.a, d.cell / 4, 0, (d.cell + 1) / 4, 1)
            local c = d.scorch and SCORCH or d.gold and GOLDSTAIN or d.c
            t:SetVertexColor(c[1], c[2], c[3], a)
            At(t, d.x, d.y, d.r * 2 * k, d.r * 2 * k * 0.62)
        end
    end
end

local RED50 = { 1, 50 / 255, 30 / 255 }
local function FillLine(pool, x0, y0, x1, y1, w, c, a)
    local l = Take(V.pools[pool])
    File(l, nil) l.file = nil
    l:SetColorTexture(c[1], c[2], c[3], a)
    l:SetVertexColor(1, 1, 1, 1)
    l:SetStartPoint("TOPLEFT", V.origin, x0, -y0)
    l:SetEndPoint("TOPLEFT", V.origin, x1, -y1)
    l:SetThickness(max(0.1, w))
end
local function FillRect(pool, x, y, w, h, c, a)
    local t = Take(V.pools[pool])
    File(t, nil) t.file = nil
    t:SetColorTexture(c[1], c[2], c[3], a)
    t:SetVertexColor(1, 1, 1, 1)
    AtTL(t, x, y, w, h)
    return t
end
local function DrawGroundFx(run)
    for _, t in ipairs(run.tele) do
        local c = t.col or RED50
        if t.t0 and t.enemy and t.shape == "line" then
            local f = 1 - t.t / t.t0
            local pulse = 0.5 + 0.5 * sin(run.t * 14)
            FillLine("glowL", t.x, t.y, t.x2, t.y2, t.w or 40, c, 0.16 + 0.1 * pulse)
            local ex, ey = t.x + (t.x2 - t.x) * f, t.y + (t.y2 - t.y) * f
            FillLine("glowL", t.x, t.y, ex, ey, (t.w or 40) * 0.5, c, 0.35)
            FillLine("glowL", t.x, t.y, t.x2, t.y2, 2, { 1, 0.85, 0.7 }, 0.7)
        elseif t.t0 and t.enemy and t.shape == "band" then
            local f = 1 - t.t / t.t0
            local pulse = 0.5 + 0.5 * sin(run.t * 12)
            FillRect("tele", t.x, t.y, t.w, t.h, c, 0.06 + 0.22 * f + 0.06 * pulse)
            FillRect("tele", t.x, t.y, 2, t.h, c, 0.6)
            FillRect("tele", t.x + t.w - 2, t.y, 2, t.h, c, 0.6)
        elseif t.t0 and t.enemy and t.shape == "cone" then
            local f = 1 - t.t / t.t0
            local l = Take(V.pools.glowL)
            File(l, FxFile("cone")) l:SetTexCoord(1, 0, 0, 1)
            Col(l, c, 0.35 + 0.35 * f)
            LineAt(l, t.x + cos(t.ang) * t.r / 2, t.y + sin(t.ang) * t.r / 2 / 1.3, t.r, t.r * t.spread * 2.2, t.ang)
        elseif t.t0 and t.enemy and t.shape == "ringwarn" then
            local f = 1 - t.t / t.t0
            Tex("tele", "ring_thin", t.x, t.y, t.r * 2 * (0.3 + 0.7 * f), t.r * 2 * (0.3 + 0.7 * f) / 1.3, 0.9, run.t, c)
        elseif t.t0 and t.enemy then
            local f = 1 - t.t / t.t0
            local a = Take(V.pools.tele)
            File(a, CIRCLE) a:SetTexCoord(0, 1, 0, 1)
            a:SetVertexColor(c[1], c[2], c[3], 0.12 + f * 0.18)
            At(a, t.x, t.y, t.r * 2, t.r * 2 / 1.3)
            local b = Take(V.pools.tele)
            File(b, CIRCLE) b:SetTexCoord(0, 1, 0, 1)
            b:SetVertexColor(c[1], c[2], c[3], 0.25 + f * 0.25)
            At(b, t.x, t.y, t.r * 2 * f, t.r * 2 * f / 1.3)
            Tex("tele", "ring_thin", t.x, t.y, t.r * 2.08, t.r * 2.08 / 1.3, 0.9, 0, c)
        end
    end
end

-- a band texture wrapped round a ring in n slices (Holy Shield's runes, Divine Illumination's crown)
local function BandRing(k, x, y, r, h, n, scroll, a, tint)
    local cu = FxCrop(k)
    local sw = 1 / n
    local segW = TAU * r / n + 1
    for i = 0, n - 1 do
        local ang = i / n * TAU
        local px, py = x + cos(ang) * r, y + sin(ang) * r / 1.3
        local u0 = ((i * sw + scroll) % 1)
        if u0 > 1 - sw then u0 = 1 - sw end
        local l = Take(V.pools.glowL)
        File(l, FxFile(k))
        l:SetTexCoord(u0 * cu, (u0 + sw) * cu, 0, 1)
        Col(l, tint, a)
        -- the tangent on the ellipse, the slice as tall as the ring's slant allows
        local tx, ty = -sin(ang), cos(ang) / 1.3
        local tl = sqrt(tx * tx + ty * ty)
        LineAt(l, px, py, segW * tl, h * (1 / 1.3 + 0.23 * abs(cos(ang))), atan2(ty, tx))
    end
end

local function DrawGroundGlow(run)
    local p = run.p
    if run.perks and run.perks.aura and not p.dead then           -- (Revered: the Champion's Aura)
        FlatTex("glow", "sun_ring", p.x, p.y, 44, 0.45, run.t * 0.5, C.GOLD)
        FlatTex("glow", "rune_circle", p.x, p.y, 36, 0.3, -run.t * 0.35, C.HOLY)
    end
    local cs = run.spells.consecration
    if cs and not p.dead and cs.rad then
        local r, L = cs.rad, run.legend.consecration
        local tint = L and C.HOLY or C.GOLD
        local pulse = 0.5 + 0.5 * sin(run.t * 3)
        FlatTex("glow", "white_orb", p.x, p.y, r * 1.15, L and 0.14 or 0.16, 0, C.GOLD)
        FlatTex("glow", "rune_circle", p.x, p.y, r * 1.08, 0.7 + pulse * 0.1, run.t * 0.18, tint)
        FlatTex("glow", "conse_rune", p.x, p.y, r * 0.95, 0.55 + pulse * 0.15, -run.t * 0.12, tint)
        if L then FlatTex("glow", "sun_ring", p.x, p.y, r * 1.12, 0.18, run.t * 0.4, C.GOLD) end
        BandRing("holy_runes", p.x, p.y, r * 1.02, L and 13 or 10, 22, run.t * 0.04, L and 0.6 or 0.62, C.GOLD)
        if L then BandRing("crown", p.x, p.y - 8, r * 1.0, 20, 26, -run.t * 0.03, 0.32, C.GOLD) end
    end
    for _, a in ipairs(run.areas) do
        local f = min(1, a.t / 0.25) * min(1, (a.dur - a.t) / 0.4)
        if a.kind == "blizzard" then
            FlatTex("glow", "frost_disc", a.x, a.y, a.r * 1.1, 0.2 * f, a.t * 0.4, C.ICE)
            FlatTex("glow", "ring_blue", a.x, a.y, a.r * 1.05, 0.55 * f, -a.t * 0.5, C.FROST)
            FlatTex("glow", "frost_cloud", a.x, a.y, a.r * 0.9, 0.16 * f, a.t * 0.8, C.ICE)
        else
            FlatTex("glow", "lava_disc", a.x, a.y, a.r * 1.05, 0.38 * f, a.t * 0.3)
            FlatTex("glow", "fire_ring", a.x, a.y, a.r * 1.1, 0.4 * f, -a.t * 0.3)
            Glow("glow", a.x, a.y, a.r, GLOWC.fire, 0.22 * f)
        end
    end
    for _, h in ipairs(run.haz) do
        local f = min(1, h.t / 0.4) * min(1, (h.dur - h.t) / 1)
        local look = h.look
        if look == "void" then
            FlatTex("flatN", "void_orb", h.x, h.y, h.r * 1.05, 0.95 * f, run.t * 0.4)
            FlatTex("glow", "shadow_ring2", h.x, h.y, h.r * 1.08, 0.7 * f, -run.t * 0.8, { 0.7, 0.4, 1 })
            FlatTex("glow", "dnd", h.x, h.y, h.r, 0.35 * f, run.t * 0.6, { 0.45, 0.2, 0.7 })
        elseif look == "slime" then
            FlatTex("flatN", "slime", h.x, h.y, h.r, 0.75 * f, h.x)
            FlatTex("glow", "white_orb", h.x, h.y, h.r * 0.9, 0.18 * f, 0, { 0.4, 0.9, 0.3 })
        elseif look == "web" then
            FlatTex("flatN", "web", h.x, h.y, h.r * 1.1, 0.7 * f, h.y)
        elseif look == "fissure" then
            FlatTex("glow", "red_star", h.x, h.y, h.r * 1.3, (0.5 + 0.2 * sin(run.t * 20)) * f, run.t * 2, { 1, 0.2, 0.35 })
            FlatTex("glow", "ring_thin", h.x, h.y, h.r * 1.05, 0.9 * f, 0, { 1, 0.25, 0.4 })
            FlatTex("flatN", "smoke_dark", h.x, h.y, h.r, 0.7 * f, run.t)
        elseif look == "fire" then
            FlatTex("glow", "lava_disc", h.x, h.y, h.r * 1.05, 0.5 * f, h.t * 0.3)
            Glow("glow", h.x, h.y, h.r, GLOWC.fire, 0.3 * f)
        elseif look == "frost" then
            FlatTex("glow", "frost_disc", h.x, h.y, h.r * 1.1, 0.35 * f, h.t * 0.4, C.ICE)
            FlatTex("glow", "ring_blue", h.x, h.y, h.r * 1.05, 0.6 * f, -h.t * 0.5, C.FROST)
        elseif look == "shout" then
            FlatTex("glow", "ring_soft", h.x, h.y, h.r, 0.45 * f, 0, { 0.6, 0.8, 1 })
        elseif look ~= "none" then
            FlatTex("glow", "white_orb", h.x, h.y, h.r, 0.3 * f, 0, h.glow or { 90 / 255, 200 / 255, 60 / 255 })
        end
    end
    for cx = floor(CAMX / E.CH), floor((CAMX + V.VW) / E.CH) do
        for cy = floor(CAMY / E.CH), floor((CAMY + V.VH) / E.CH) do
            local ch = run.chunks[cx * 100003 + cy]
            if ch and ch.zones then
                for _, z in ipairs(ch.zones) do
                    if not z.gone and inView(z.x, z.y, z.r) then
                        if z.kind == "web" then
                            FlatTex("flatN", "web", z.x, z.y, z.r * 1.15, 0.62, z.x * 0.01)
                            FlatTex("flatN", "web", z.x + z.r * 0.3, z.y - z.r * 0.2, z.r * 0.7, 0.4, z.y * 0.01)
                        else
                            FlatTex("flatN", "slime", z.x, z.y, z.r, 0.82, z.x * 0.01)
                            FlatTex("glow", "white_orb", z.x, z.y, z.r * 0.95, 0.16 + 0.04 * sin(run.t * 2 + z.x), 0, { 0.35, 0.85, 0.3 })
                        end
                    end
                end
            end
        end
    end
    for _, t in ipairs(run.tele) do
        if t.kind == "flamestrike" then
            local f = 1 - t.t / t.t0
            FlatTex("glow", "ring_soft", t.x, t.y, t.r * (1.2 - f * 0.2), 0.5 + f * 0.4, 0, C.FIRE)
            Glow("glow", t.x, t.y, t.r * f, GLOWC.fire, 0.5 * f)
        end
    end
end

local SHADOW = UIM .. "shadow"
local function Shadow(x, y, w, h, a)
    local t = Take(V.pools.shadow)
    File(t, SHADOW)
    t:SetTexCoord(0, 1, 0, 1)
    t:SetVertexColor(1, 1, 1, a or 1)
    AtTL(t, x, y, w, h)
end

local GEM = { UIM .. "gem_green", UIM .. "gem_blue", UIM .. "gem_violet" }
-- Sapphiron's ice blocks throw a shadow away from her (where the breath cannot reach)
local function DrawBlockShadows(run)
    if not run.blocks or #run.blocks == 0 then return end
    local s
    for _, e in ipairs(run.en) do if e.type == "n_sapphiron" and not e.dead then s = e end end
    if not s then return end
    for _, b in ipairs(run.blocks) do
        local a = atan2(b.y - s.y, b.x - s.x)
        local x1, y1 = b.x + cos(a) * 170, b.y + sin(a) * 170
        FillLine("underL", b.x, b.y, x1, y1, 100, { 0.02, 0.05, 0.12 }, 0.45)
    end
end

local function DrawGems(run)
    local sz = A.UI_SIZE.gem_green
    for _, g in ipairs(run.gems) do
        if inView(g.x, g.y, 30) then
            local big, mid = g.v >= 25, g.v >= 3
            local h = big and 22 or mid and 17 or 13
            local w = h * 0.7
            local bob = sin(g.t * 4) * 2
            local pz = g.pop > 0 and sin((0.35 - g.pop) / 0.35 * pi) * 16 or 0
            Shadow(g.x - w * 0.6, g.y - 2, w * 1.2, 5, 0.6)
            local t = Take(V.pools.gem)
            File(t, GEM[big and 3 or mid and 2 or 1])
            t:SetTexCoord(0, sz[3], 0, sz[4])
            t:SetVertexColor(1, 1, 1, 1)
            AtTL(t, g.x - w / 2, g.y - h - 3 + bob - pz, w, h)
        end
    end
end

local BERSERK, IMMUNE, POS, NEG = { 1, 0.15, 0.05 }, { 1, 0.95, 0.75 }, { 1, 0.3, 0.2 }, { 0.35, 0.6, 1 }
local function DrawEnemy(run, e)
    local M = e.M
    local key = M.sprite or e.type
    local U = A.UNITS[key]
    if not U then return end
    local col = floor(e.anim) % U.walk
    if e.atkT > 0 and U.atk > 0 then col = U.walk + U.death + min(U.atk - 1, floor((1 - e.atkT / 1.2) * U.atk)) end
    local a = (M.ghost and 0.82 or 1) * min(1, e.spawnT * 3)
    local yo = M.fly and (-10 + sin(run.t * 6 + e.wob) * 3) or 0
    local sqk = e.sq / 0.22
    local sq = sqk * sqk * 0.2
    local sx, sy = 1 + sq, 1 - sq * 0.7
    local fl = e.flash > 0 and 0.85 or 0
    local bp, sub = Band(e.y)
    local sc = (M.scale or 1) * (e.sc or 1)
    local tint = e.tint or M.tint
    if e.charge then                                         -- (Thaddius's polarity: a ring of the charge under it)
        local g = Take(bp.glow)
        File(g, FxFile("ring_soft")) g:SetTexCoord(0, 1, 0, 1)
        Col(g, e.charge > 0 and POS or NEG, 0.9)
        At(g, e.x, e.y, M.r * 3, M.r * 3 / 1.3)
    end
    if M.elite or M.boss then
        local g = Take(bp.glow)
        File(g, UIM .. "glow") g:SetTexCoord(0, 1, 0, 1)
        if e.berserk then Col(g, BERSERK, 0.6 + sin(run.t * 9) * 0.2)
        elseif e.immune then Col(g, IMMUNE, 0.45 + sin(run.t * 5) * 0.1)
        else Col(g, M.boss and GLOWC.red or GLOWC.gold, 0.35 + sin(run.t * 4) * 0.08) end
        At(g, e.x, e.y - M.r, M.r * 4.8, M.r * 4.8)
        Sprite(bp, sub, key, e.dir, col, e.x, e.y + yo - (e.z or 0), a * (e.alpha or 1), fl, sc, sx, sy, tint)
    elseif M.reaper then
        local g = Take(bp.glow)
        File(g, UIM .. "glow") g:SetTexCoord(0, 1, 0, 1)
        Col(g, GLOWC.blue, 0.5)
        At(g, e.x, e.y - 40, 140, 140)
        Sprite(bp, sub, key, e.dir, col, e.x, e.y, 0.95, 0, 1.4)
    else
        Sprite(bp, sub, key, e.dir, col, e.x, e.y + yo, a * (e.alpha or 1), fl, sc, sx, sy, tint)
    end
    if e.barrier then        -- (a Deathknight Understudy's Bone Barrier: a bubble to stand in)
        local t = Take(bp.add) t:SetDrawLayer("ARTWORK", min(7, sub + 2))
        File(t, FxFile("ring_soft")) t:SetTexCoord(0, 1, 0, 1) Col(t, { 0.6, 0.8, 1 }, 0.55 + 0.1 * sin(run.t * 3 + e.x))
        At(t, e.x, e.y - 28, 96, 90)
    end
    if e.frz > 0 then        -- encased in ice
        local k, r = min(1, (e.frzMax - e.frz) * 8), M.r
        local pg, fx, fy, fw, fh, dx, dy = Frame(key, e.dir, col)
        if pg then
            local t = Take(bp.add)
            t:SetDrawLayer("ARTWORK", min(7, sub + 1))
            File(t, pg[1])
            t:SetTexCoord(fx / pg[2], (fx + fw) / pg[2], fy / pg[3], (fy + fh) / pg[3])
            t:SetVertexColor(1, 1, 1, 0.32 * k)
            AtTL(t, e.x + dx * sx, e.y + yo + dy * sy, fw * sx, fh * sy)
        end
        local t2 = Take(bp.add)
        t2:SetDrawLayer("ARTWORK", min(7, sub + 2))
        File(t2, FxFile("frost_burst")) t2:SetTexCoord(0, 1, 0, 1)
        Col(t2, C.ICE, 0.55 * k)
        At(t2, e.x, e.y - r * 1.3, r * 3.2 * (0.7 + 0.3 * k), r * 3.6 * (0.7 + 0.3 * k))
        local t3 = Take(bp.add)
        t3:SetDrawLayer("ARTWORK", min(7, sub + 2))
        File(t3, FxFile("blue_star")) t3:SetTexCoord(0, 1, 0, 1)
        Col(t3, C.FROST, 0.6 * k * (0.5 + 0.5 * sin(run.t * 5 + e.wob)))
        At(t3, e.x + r * 0.4, e.y - r * 2.2, 14, 14)
    elseif e.slow > 0 then
        local t = Take(bp.add)
        t:SetDrawLayer("ARTWORK", min(7, sub + 1))
        File(t, FxFile("frost_burst")) t:SetTexCoord(0, 1, 0, 1)
        Col(t, C.ICE, 0.35)
        At(t, e.x, e.y - M.r * 0.2, M.r * 2.4, M.r)
    end
    if e.stun > 0 then
        for i = 0, 2 do
            local a2 = run.t * 6 + i * 2.1
            local t = Take(bp.add)
            t:SetDrawLayer("ARTWORK", 7)
            File(t, FxFile("sparkle")) t:SetTexCoord(0, 1, 0, 1)
            Col(t, C.HOLY, 0.9)
            At(t, e.x + cos(a2) * 11, e.y - M.r * 2.5 + sin(a2) * 3, 12, 12)
        end
    end
    if M.elite and e.hp < e.maxHp then
        local w = 46
        local t = Take(bp.spr) t:SetDrawLayer("ARTWORK", 7) File(t, nil) t.file = nil
        t:SetColorTexture(0, 0, 0, 0.7) t:SetVertexColor(1, 1, 1, 1) AtTL(t, e.x - w / 2, e.y + 8, w, 5)
        local t2 = Take(bp.spr) t2:SetDrawLayer("ARTWORK", 7) t2.file = nil
        t2:SetColorTexture(0.85, 0.65, 0.08, 1) t2:SetVertexColor(1, 1, 1, 1) AtTL(t2, e.x - w / 2 + 1, e.y + 9, (w - 2) * e.hp / e.maxHp, 3)
    end
end

local function DrawPlayer(run)
    local p = run.p
    local Cl = D.CLASSES[run.cls]
    local key = run.ashbringer and "paladin_ash" or (Cl.legendSprite and run.legend[Cl.start] and Cl.legendSprite) or Cl.sprite
    if run.perks and run.perks.tabard and A.UNITS[key .. "_ad"] then key = key .. "_ad" end      -- (Honored: the Dawn's tabard)
    local set = D.T3_SETS and D.T3_SETS[run.cls]
    local plain = key == Cl.sprite or key == Cl.sprite .. "_ad"
    if run.perks and run.perks.t3 and set and plain and A.UNITS[set.sprite] then key = set.sprite end    -- (nine pieces: the set's look)
    local U = A.UNITS[key]
    local col = p.moving and floor(p.anim) % U.walk or 0
    local dir = p.dir
    if (p.atkT or 0) > 0 and U.atk > 0 and not p.dash then          -- a swing: the attack frames, facing the blow
        col = U.walk + U.death + min(U.atk - 1, floor((1 - p.atkT / 0.36) * U.atk))
        dir = p.atkDir or dir
    end
    if p.dead then col, dir = U.walk + min(U.death - 1, floor(p.deadT / 0.1)), p.dir end
    local blink = p.inv > 0 and not p.dead and floor(p.inv * 20) % 2 == 0
    local bp, sub = Band(p.y)
    if p.charge then
        local g = Take(bp.glow)
        File(g, FxFile("ring_soft")) g:SetTexCoord(0, 1, 0, 1)
        Col(g, p.charge > 0 and POS or NEG, 1)
        At(g, p.x, p.y, 54, 54 / 1.3)
    end
    Sprite(bp, sub, key, dir, col, p.x, p.y, blink and 0.55 or 1, p.hurtT > 0.15 and 0.5 or 0)
    if (p.wrapT or 0) > 0 then                               -- (Web Wrap: a cocoon over the hero)
        local w = Take(bp.spr) w:SetDrawLayer("ARTWORK", min(7, sub + 1)) File(w, FxFile("webspin")) Rot(w, sin(run.t * 30) * 0.12)
        w:SetVertexColor(1, 1, 1, 0.95) At(w, p.x, p.y - 28, 44, 58)
        local w2 = Take(bp.spr) w2:SetDrawLayer("ARTWORK", min(7, sub + 2)) File(w2, FxFile("web")) Rot(w2, run.t * 0.3)
        w2:SetVertexColor(1, 1, 1, 0.8) At(w2, p.x, p.y - 26, 62, 62)
    end
    if (p.tombT or 0) > 0 then                               -- (Frost Blast: an ice tomb)
        local t2 = Take(bp.add) t2:SetDrawLayer("ARTWORK", min(7, sub + 2))
        File(t2, FxFile("frost_burst")) t2:SetTexCoord(0, 1, 0, 1) Col(t2, C.ICE, 0.7)
        At(t2, p.x, p.y - 26, 70, 80)
    end
    if not p.dead and not run.preview then
        local w = 38
        local t = Take(bp.spr) t:SetDrawLayer("ARTWORK", 7) t.file = nil
        t:SetColorTexture(0, 0, 0, 0.75) t:SetVertexColor(1, 1, 1, 1) AtTL(t, p.x - w / 2, p.y + 7, w, 5)
        local t2 = Take(bp.spr) t2:SetDrawLayer("ARTWORK", 7) t2.file = nil
        if p.hp / p.maxHp > 0.35 then t2:SetColorTexture(0.13, 0.76, 0.16, 1) else t2:SetColorTexture(0.83, 0.16, 0.1, 1) end
        t2:SetVertexColor(1, 1, 1, 1)
        AtTL(t2, p.x - w / 2 + 1, p.y + 8, max(0.1, (w - 2) * p.hp / p.maxHp), 3)
    end
end

local PICKICON = { gold = "inv_misc_coin_01", healthstone = "inv_stone_04", lootarang = "inv_misc_enggizmos_17", sapper = "inv_misc_bomb_05", chest = "inv_box_02" }
local function DrawPick(run, k)
    local bob = sin(k.t * 3) * 2
    local bp, sub = Band(k.y)
    if k.kind == "eggsac" or k.kind == "spore" or k.kind == "brazier" then
        local t = Take(bp.spr) t:SetDrawLayer("ARTWORK", sub)
        local g = Take(bp.glow) File(g, UIM .. "glow") g:SetTexCoord(0, 1, 0, 1)
        if k.kind == "eggsac" then
            File(t, FxFile("webspin")) Rot(t, sin(k.t * 2) * 0.05) t:SetVertexColor(0.9, 0.95, 0.85, 1) At(t, k.x, k.y - 16, 30 + sin(k.t * 4) * 2, 34)
            Col(g, GLOWC.green, 0.25 + 0.15 * sin(k.t * 3)) At(g, k.x, k.y - 14, 60, 60)
        elseif k.kind == "spore" then
            File(t, FxFile("green_glow")) t:SetTexCoord(0, 1, 0, 1) t:SetVertexColor(0.85, 1, 0.5, 1) At(t, k.x, k.y - 22 + bob, 34, 34)
            Col(g, { 0.8, 1, 0.4 }, 0.45 + 0.15 * sin(k.t * 5)) At(g, k.x, k.y - 20, 80, 80)
        else
            File(t, FxFile("flame")) t:SetTexCoord(0, 1, 0, 1) t:SetVertexColor(1, 0.85, 0.6, 1) At(t, k.x, k.y - 30, 36 + sin(k.t * 9) * 3, 46)
            Col(g, GLOWC.fire, 0.6 + 0.1 * sin(k.t * 7)) At(g, k.x, k.y - 20, 150, 150)
        end
        return
    end
    if k.kind == "cauldron" then
        Shadow(k.x - 34, k.y - 8, 68, 18, 1)
        local pr = A.PROPS.outpost_0
        local pg = A.PROP_PAGES[pr[1]]
        local s = 0.55
        local t = Take(bp.spr)
        t:SetDrawLayer("ARTWORK", sub)
        File(t, pg[1])
        t:SetTexCoord(pr[2] / pg[2], (pr[2] + pr[4]) / pg[2], pr[3] / pg[3], (pr[3] + pr[5]) / pg[3])
        t:SetVertexColor(1, 1, 1, 1)
        AtTL(t, k.x - pr[6] * s, k.y - pr[7] * s, pr[4] * s, pr[5] * s)
        return
    end
    local sz = k.kind == "chest" and 30 or 20
    Shadow(k.x - sz * 0.6, k.y - 4, sz * 1.2, 8, 1)
    local t = Take(bp.spr)
    t:SetDrawLayer("ARTWORK", sub)
    File(t, D.ICON(PICKICON[k.kind]))
    t:SetTexCoord(5 / 64, 59 / 64, 5 / 64, 59 / 64)
    t:SetVertexColor(1, 1, 1, 1)
    AtTL(t, k.x - sz / 2, k.y - sz - 6 + bob, sz, sz)
    local b = Take(bp.spr)
    b:SetDrawLayer("ARTWORK", min(7, sub + 1))
    b.file = nil
    if k.kind == "chest" then b:SetColorTexture(1, 0.82, 0.25, 1) else b:SetColorTexture(0, 0, 0, 0.8) end
    -- (a 1-unit frame: four thin rects would be the canvas stroke; a slightly larger plate behind reads the same)
    b:SetVertexColor(1, 1, 1, 1)
    AtTL(b, k.x - sz / 2 - 1, k.y - sz - 7 + bob, sz + 2, 1)
    local b2 = Take(bp.spr) b2:SetDrawLayer("ARTWORK", min(7, sub + 1)) b2.file = nil
    if k.kind == "chest" then b2:SetColorTexture(1, 0.82, 0.25, 1) else b2:SetColorTexture(0, 0, 0, 0.8) end
    b2:SetVertexColor(1, 1, 1, 1)
    AtTL(b2, k.x - sz / 2 - 1, k.y - 6 + bob, sz + 2, 1)
end

local SPIKE = { UIM .. "ice_spike_0", UIM .. "ice_spike_1", UIM .. "ice_spike_2" }
local function DrawIcicle(run, f)
    if f.t < 0 then return end
    local grow = easeOut(min(1, f.t / 0.14))
    local endT = f.dur - f.t
    local a = min(1, endT * 3)
    local h, w = f.s * 1.5 * grow, f.s
    local bp, sub = Band(f.y)
    local sz = A.UI_SIZE.ice_spike_0
    local t = Take(bp.spr)
    t:SetDrawLayer("ARTWORK", sub)
    File(t, SPIKE[(f.v or 0) + 1])
    t:SetTexCoord(0, sz[3], 0, sz[4] * grow)
    t:SetVertexColor(1, 1, 1, a)
    AtTL(t, f.x - w * 0.42, f.y - h * 1.05, w * 0.84, h * 1.05)
    local t2 = Take(bp.add)
    t2:SetDrawLayer("ARTWORK", min(7, sub + 1))
    File(t2, SPIKE[(f.v or 0) + 1])
    t2:SetTexCoord(0, sz[3], 0, sz[4] * grow)
    t2:SetVertexColor(1, 1, 1, 0.35 * a)
    AtTL(t2, f.x - w * 0.42, f.y - h * 1.05, w * 0.84, h * 1.05)
    if endT < 0.05 and not f.shat then
        f.shat = true
        for _ = 1, 3 do E.emit({ img = "ice_chunks", tint = C.FROST, x = f.x, y = f.y, z = h * 0.5, vx = (math.random() - 0.5) * 140, vy = (math.random() - 0.5) * 80, vz = 50 + math.random() * 90, g = 520, life = 0.5, s0 = 8, s1 = 5, rot = "rnd", vr = 8, bounce = 0.3 }) end
    end
end

local function DrawProp(o)
    local pr = A.PROPS[o.name]
    if not pr then return end
    local pg = A.PROP_PAGES[pr[1]]
    local x, y, w, h = o.x - pr[6], o.y - pr[7], pr[4], pr[5]
    local px, py = V.px, V.py
    local behind = px > x + w * 0.15 and px < x + w * 0.85 and py < o.y and py > y + h * 0.15
    local bp, sub = Band(o.y)
    local t = Take(bp.spr)
    t:SetDrawLayer("ARTWORK", sub)
    File(t, pg[1])
    t:SetTexCoord(pr[2] / pg[2], (pr[2] + pr[4]) / pg[2], pr[3] / pg[3], (pr[3] + pr[5]) / pg[3])
    t:SetVertexColor(1, 1, 1, behind and 0.42 or 1)
    AtTL(t, x, y, w, h)
end

local function DrawCorpse(run, c)
    local M = MOBS[c.type]
    local key = M and M.sprite or c.type
    local U = A.UNITS[key]
    if not U or U.death == 0 then return end
    local col = U.walk + min(U.death - 1, floor(c.t / 0.09))
    local a = c.t < 1.2 and 1 or max(0, 1 - (c.t - 1.2))
    if c.purge then a = max(0, 1 - c.t * 2.2) end
    local bp, sub = Band(c.y - 6)
    Sprite(bp, sub, key, c.dir, col, c.x, c.y + max(0, c.t - 1.2) * 6, a * (M and M.ghost and 0.8 or 1), c.purge and (1 - c.t) or 0, M and M.scale or 1, nil, nil, M and M.tint)
end

---------------------------------------------------------------------------
-- additive effects (the mockup's drawAirFx)
---------------------------------------------------------------------------
local ARC_GOLD, ARC_WHITE, ARC_STORM = { 1, 214 / 255, 120 / 255 }, { 1, 1, 240 / 255 }, { 120 / 255, 200 / 255, 1 }
local TRAIL_GOLD, TRAIL_ARC = { 1, 210 / 255, 120 / 255 }, { 210 / 255, 140 / 255, 1 }
local function ColLine(pool, x0, y0, x1, y1, w, c, a)
    local l = Take(V.pools[pool])
    File(l, nil) l.file = nil
    l:SetColorTexture(c[1], c[2], c[3], a)
    l:SetVertexColor(1, 1, 1, 1)
    l:SetStartPoint("TOPLEFT", V.origin, x0, -y0)
    l:SetEndPoint("TOPLEFT", V.origin, x1, -y1)
    l:SetThickness(max(0.1, w * (V.lineK or 1)))
end
local function DrawAirFx(run)
    local p = run.p
    for _, b in ipairs(run.beams or {}) do
        local k = b.t / b.dur
        local a = (k < 0.15 and k / 0.15 or 1 - (k - 0.15) / 0.85) * (b.a or 1)
        if a > 0 then
            local l = Take(V.pools.addL) File(l, FxFile("beam")) l:SetTexCoord(0, 1, 0, 1)
            Col(l, b.col, a)
            LineAt(l, b.x, b.y - b.h / 2, b.h, b.w, -pi / 2)
            Glow("add", b.x, b.y, b.w * 1.4, b.col, a * 0.6)
        end
    end
    if run.chainT and run.chainT > 0 and run.boss and not run.boss.dead then       -- (Chains of Kel'Thuzad)
        local b = run.boss
        ColLine("trail", b.x, b.y - 60, p.x, p.y - 30, 6, { 0.75, 0.45, 1 }, 0.6)
        ColLine("addL", b.x, b.y - 60, p.x, p.y - 30, 2, { 1, 0.85, 1 }, 0.9)
    end
    for _, a in ipairs(run.arcs) do
        local k = 1 - a.t / a.life
        if a.storm then           -- Thunderfury: a jagged bolt, re-kinked every frame
            local mx, my = (a.x0 + a.x1) / 2 + (math.random() - 0.5) * 22, (a.y0 + a.y1) / 2 + (math.random() - 0.5) * 22
            for _, sg in ipairs({ { a.x0, a.y0, mx, my }, { mx, my, a.x1, a.y1 } }) do
                ColLine("trail", sg[1], sg[2], sg[3], sg[4], 6 * k, ARC_STORM, 0.9 * k)
                ColLine("addL", sg[1], sg[2], sg[3], sg[4], 1.6 * k, ARC_WHITE, k)
            end
        else
            ColLine("trail", a.x0, a.y0, a.x1, a.y1, 5 * k, ARC_GOLD, 0.9 * k)
            ColLine("addL", a.x0, a.y0, a.x1, a.y1, 1.5 * k, ARC_WHITE, k)
        end
    end
    for _, b in ipairs(run.proj) do
        if not (b.delay and b.delay > 0) then
            local tr = b.trail
            if tr and #tr > 4 then
                local col, w0 = b.kind == "shield" and TRAIL_GOLD or TRAIL_ARC, b.kind == "shield" and 9 or 5
                for i = 3, #tr - 1, 2 do
                    local k = i / #tr
                    ColLine("trail", tr[i - 2], tr[i - 1], tr[i], tr[i + 1], w0 * k, col, k * 0.7)
                end
            end
            if b.kind == "shield" then
                Glow("add", b.x, b.y, 34, GLOWC.gold, 0.8)
                Tex("add", "lens", b.x, b.y, 54, 54, 0.8, b.spin * 0.2, C.GOLD)
                Tex("addTop", "sun_ring", b.x, b.y, 30, 30, 0.9, b.spin, C.GOLD)      -- a spinning ring of holy light, no picture
                Glow("addTop", b.x, b.y, 12, GLOWC.white, 0.9)
            elseif b.kind == "frost" then
                local a = atan2(b.vy, b.vx)
                local l = Take(V.pools.addL)
                File(l, FxFile("ice_missile")) l:SetTexCoord(1, 0, 0, 1)
                Col(l, C.ICE, 0.95)
                LineAt(l, b.x - cos(a) * 14, b.y - sin(a) * 14, 60, 26, a)
                Tex("add", "blue_star", b.x, b.y, 30, 30, 0.9, b.spin, C.FROST)
                Tex("add", "frost_burst", b.x, b.y, 16, 16, 0.9, b.spin * 1.4, { 230 / 255, 245 / 255, 1 })
                Glow("add", b.x, b.y, 24, GLOWC.blue, 0.7)
            elseif b.kind == "arcane" then
                Tex("add", "lens", b.x, b.y, 30, 30, 1, run.t * 4, C.ARC)
                Tex("add", "arcane_orbit", b.x, b.y, 18, 18, 0.8, run.t * 9, C.ARC)
                Glow("add", b.x, b.y, 20, GLOWC.violet, 0.7)
            elseif b.kind == "grenade" and b.t >= 0 then
                local sh = Take(V.pools.addN) File(sh, SHADOW) sh:SetTexCoord(0, 1, 0, 1) sh:SetVertexColor(1, 1, 1, 0.5) AtTL(sh, b.gx - 7, b.gy - 3, 14, 6)
                local bomb = Take(V.pools.addN) File(bomb, D.ICON("inv_misc_bomb_08")) Rot(bomb, b.spin, 8 / 64, 8 / 64, 56 / 64, 56 / 64) bomb:SetVertexColor(1, 1, 1, 1) At(bomb, b.x, b.y, 16, 16)
                Tex("add", "sparkle", b.x + 6, b.y - 7, 14, 14, 0.9, run.t * 10, C.EMBER)
            end
        end
    end
    local dr = run.spells.dragonling
    if dr and dr.orbs then for _, o in ipairs(dr.orbs) do Tex("add", "fire_core", o.x, o.y, 40, 40, 0.9, run.t * 3) Glow("add", o.x, o.y, 30, GLOWC.fire, 0.7) end end
    for _, b in ipairs(run.eproj) do local s = b.size or 24 Tex("add", b.img or "shadow_glyph", b.x, b.y, s, s, 0.9, run.t * 4, b.tint) Glow("add", b.x, b.y, s * 0.85, b.glow or GLOWC.violet, 0.6) end
    if run.gateX and not run.gateOpen then                  -- (Gothik's gate: a wall of violet light)
        local a = 0.55 + 0.2 * sin(run.t * 5)
        ColLine("trail", run.gateX, CAMY - 20, run.gateX, CAMY + V.VH + 20, 18, { 0.6, 0.35, 1 }, a * 0.6)
        ColLine("addL", run.gateX, CAMY - 20, run.gateX, CAMY + V.VH + 20, 3, { 0.95, 0.85, 1 }, a)
    end
    for _, f in ipairs(run.fx) do
        local k = f.t / f.dur
        local inv = 1 - k
        if f.kind == "pillar" then
            -- Exorcism: a shaft of light drops out of the sky onto the mark, flares, then thins and fades; a
            -- sigil burns into the ground under it and spreads (soft textures, never a hard edge)
            local H = 420
            local drop = easeOut(min(1, k / 0.09))                     -- (the shaft's foot reaches the ground)
            local after = max(0, (k - 0.09) / 0.91)
            local fade = (1 - after) ^ 1.3
            local w = 30 + 56 * (drop >= 1 and (1 - after) ^ 0.6 or drop)
            local hh = H * drop
            local top = f.y + 12 - H
            Tex("add", "exo_shaft", f.x, top + hh / 2, w * 1.9, hh, 0.55 * fade, 0, C.GOLD)
            Tex("add", "exo_shaft", f.x, top + hh / 2, w, hh, min(1, 1.2 * fade), 0, C.HOLY)
            Tex("add", "exo_shaft", f.x, top + hh / 2, w * 0.4, hh, fade, 0, { 1, 1, 0.94 })
            local sz = 60 + 110 * easeOut(min(1, k * 1.6))
            local sa = (k < 0.08 and k / 0.08 or 1) * (1 - k) ^ 1.1
            Tex("add", "exo_sigil", f.x, f.y, sz, sz * 0.42, sa * 0.95, run.t * 0.6, C.GOLD)
            Tex("add", "exo_sigil", f.x, f.y, sz * 0.72, sz * 0.72 * 0.42, sa * 0.6, -run.t * 0.9, C.HOLY)
            Glow("add", f.x, f.y - 6, 70 * (0.6 + 0.4 * drop), GLOWC.gold, 0.7 * fade)
            if k < 0.22 then Glow("add", f.x, f.y - 20, 120, GLOWC.gold, (1 - k / 0.22) * 0.8 * drop) end
        elseif f.kind == "nova" then
            Glow("add", f.x, f.y, f.r * easeOut(min(1, k * 2.5)), GLOWC.blue, inv * 0.5)
        elseif f.kind == "flame" then
            local r = f.r
            for i = -1, 1 do
                local l = Take(V.pools.addL)
                File(l, FxFile("flame_trail")) l:SetTexCoord(0, 1, 0, 1)
                l:SetVertexColor(1, 1, 1, inv * 0.9)
                LineAt(l, f.x + i * r * 0.35, f.y - r * 0.9, r * 2.2 * (0.6 + k * 0.6), r * 1.1, -pi / 2 + i * 0.15)
            end
            Tex("add", "flame", f.x, f.y - r * 0.4, r * 2.2 * (0.7 + k * 0.5), r * 2.2 * (0.7 + k * 0.5), inv, f.x)
            Glow("add", f.x, f.y, r * 1.4, GLOWC.fire, inv)
        elseif f.kind == "wave" then
            Glow("add", f.x, f.y, f.r * 0.8 * easeOut(min(1, k * 1.1)), GLOWC.gold, inv * 0.3)
        elseif f.kind == "slash" and k >= 0 then       -- a weapon's swing: a crescent sweeping through its arc
            local col = f.legend and C.STORM or f.exec and { 1, 0.28, 0.22 } or { 1, 0.93, 0.8 }
            local sw = f.r * 2.15 * (0.88 + 0.2 * easeOut(k))
            local rot = f.a + (k - 0.5) * (f.exec and 0.3 or 0.7)
            Tex("add", "slash_arc", f.x, f.y, sw, sw, min(1, inv * 1.6), rot, col)
            Tex("add", "slash_arc", f.x, f.y, sw * 0.86, sw * 0.86, min(1, inv * 1.6) * 0.55, rot - 0.22, col)
            if f.legend then Glow("add", f.x + cos(f.a) * f.r * 0.6, f.y + sin(f.a) * f.r * 0.6, f.r * 0.7, GLOWC.blue, inv * 0.5) end
        end
    end
    for _, k in ipairs(run.pick) do
        if k.kind == "chest" and inView(k.x, k.y, 60) then
            Tex("add", "rays", k.x, k.y - 130, 60 + sin(run.t * 3) * 6, 260, 0.55, 0, C.GOLD)
            Tex("add", "sparkle", k.x + sin(run.t * 2) * 10, k.y - 30 - (run.t * 30 % 50), 12, 12, 0.9, 0, C.HOLY)
            Glow("add", k.x, k.y - 16, 60, GLOWC.gold, 0.6)
        end
    end
    for _, g in ipairs(run.gems) do
        if inView(g.x, g.y, 30) then
            local big, mid = g.v >= 25, g.v >= 3
            local h = big and 22 or mid and 17 or 13
            local y = g.y - h * 0.55 - 3 + sin(g.t * 4) * 2
            Glow("add", g.x, y, h * 0.9, big and GLOWC.violet or mid and GLOWC.blue or GLOWC.green, 0.45)
            if (g.t * 1.5 + g.x * 0.01) % 2 < 0.18 then Tex("add", "sparkle", g.x + 2, y - h * 0.3, 12, 12, 0.9) end
        end
    end
    if run.ashbringer and not p.dead then
        local hx, hy = p.x + E.PORTAL[p.dir + 1], p.y - 24
        Glow("add", hx, hy, 22, GLOWC.gold, 0.35 + sin(run.t * 5) * 0.1)
    end
    if run.legend.arcane and not p.dead then
        local ox, oy = p.x - E.PORTAL[p.dir + 1] * 2.6, p.y - 60
        Tex("add", "arcane_circle", ox, oy, 74, 90, 0.9, run.t * 1.2, C.ARC)
        Tex("add", "ring_blue", ox, oy, 60, 74, 0.7, -run.t, C.ARC)
        if math.random() < 0.25 then Tex("add", "lightning", ox + (math.random() - 0.5) * 40, oy, 20, 60, 0.9, (math.random() - 0.5) * 0.8) end
        Glow("add", ox, oy, 50, GLOWC.violet, 0.6)
    end
end

---------------------------------------------------------------------------
-- the dark round the hero (the mockup's lit canvas; the client cannot cut holes, so the hero's own light is a
-- picture of the dark with its hole, and the rest of the view is the plain dark)
---------------------------------------------------------------------------
local function DrawDark(run)
    local ST = run.ST or D.STAGE
    local dark = ST.dark or D.STAGE.dark
    local A_ = ((ST.darkA or D.STAGE.darkA) + run.dark * 0.2) * (run.preview and 0.35 or 1)
    local p = run.p
    local hx, hy, rw, rh = p.x - CAMX, p.y - 16 - CAMY, 420, 420 * 0.8
    local h = V.hole
    h:SetVertexColor(dark[1], dark[2], dark[3], A_)
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", V.scaler, "TOPLEFT", hx - rw, -(hy - rh))
    h:SetSize(rw * 2, rh * 2)
    local l, t, r, b = hx - rw, hy - rh, hx + rw, hy + rh
    local W, H = V.VW, V.VH
    local rects = { { 0, 0, W, max(0, t) }, { 0, b, W, max(0, H - b) }, { 0, max(0, t), max(0, l), max(0, min(b, H) - max(0, t)) }, { r, max(0, t), max(0, W - r), max(0, min(b, H) - max(0, t)) } }
    for i, q in ipairs(rects) do
        local d = V.darkRect[i]
        d:SetVertexColor(dark[1], dark[2], dark[3], A_)
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", V.scaler, "TOPLEFT", q[1], -q[2])
        d:SetSize(max(0.1, q[3]), max(0.1, q[4]))
        d:SetShown(q[3] > 0 and q[4] > 0)
    end
end

---------------------------------------------------------------------------
-- numbers
---------------------------------------------------------------------------
local function Font(fs, size, file)
    size = floor(size + 0.5)
    file = file or FONT
    if fs.size ~= size or fs.ffile ~= file then fs:SetFont(file, size, "OUTLINE") fs.size, fs.ffile = size, file end
end
Rd.Font = Font
local CRIT = { 1, 0.8, 0.13 }
local function DrawTexts(run)
    if run.attract then return end          -- (the title's and the poster's demos: no numbers over the logo)
    for _, t in ipairs(run.texts) do
        local k = t.t / t.life
        local pop = t.t < 0.1 and 1 + (1 - t.t / 0.1) * (t.crit and 0.9 or 0.5) or 1
        local size = (t.crit and 17 or 12) * pop
        local fs = Take(V.pools.text)
        Font(fs, size)
        fs:SetText(t.crit and (t.v .. "!") or tostring(t.v))
        local c = t.crit and CRIT or t.col or C.WHITE
        fs:SetTextColor(c[1], c[2], c[3], k > 0.7 and (1 - k) / 0.3 or 1)
        fs:SetPoint("BOTTOM", V.origin, "TOPLEFT", t.x, -t.y)
    end
end

---------------------------------------------------------------------------
-- draw
---------------------------------------------------------------------------
local LIST, LISTN = {}, 0
local function Push(y, k, o)
    LISTN = LISTN + 1
    local it = LIST[LISTN]
    if not it then it = {} LIST[LISTN] = it end
    it.y, it.k, it.o = y, k, o
end

function Rd.Camera(v, run)
    local p = run.p
    local tr = run.trauma * run.trauma
    local cx, cy = p.x - v.VW / 2 + run.kick.x, p.y - (run.preview and v.VH * (run.pvCamY or 0.56) or v.VH / 2 + 10) + run.kick.y
    if tr > 0 then
        local t = GetTime and GetTime() or 0
        cx = cx + (sin(t * 61) + sin(t * 37.3) * 0.6) * tr * 11
        cy = cy + (sin(t * 53.1 + 2) + sin(t * 29.7) * 0.6) * tr * 11
    end
    return cx, cy
end

function Rd.Draw(v, run)
    V = v
    Begin(v)
    E.SetView(run, v.VW, v.VH)
    CAMX, CAMY = Rd.Camera(v, run)
    v.lineK = 1
    v.origin:ClearAllPoints()
    v.origin:SetPoint("TOPLEFT", v.scaler, "TOPLEFT", -CAMX, CAMY)
    local p = run.p
    V.px, V.py = p.x, p.y
    -- ground (the stage's: the Plaguelands' own texture, or the necropolis's floor straight from the client)
    local ST = run.ST
    local gnd = ST and ST.ground or { D.MEDIA .. "ground", 1024 }
    if v.gFile ~= gnd[1] then
        v.gFile = gnd[1]
        v.groundTex:SetTexture(gnd[1], "REPEAT", "REPEAT")
        local tn = ST and ST.tint or D.STAGE.tint
        v.tint:SetColorTexture(tn[1], tn[2], tn[3], 1)
        local fc = ST and ST.fogC
        if fc then v.fog:SetVertexColor(fc[1], fc[2], fc[3], 1) end
    end
    local gt = gnd[2]
    v.groundTex:SetTexCoord(CAMX / gt, (CAMX + v.VW) / gt, CAMY / (gt * 1.3), (CAMY + v.VH) / (gt * 1.3))
    DrawDecals(run)
    DrawBlockShadows(run)
    DrawParts(run, "under")
    DrawGroundFx(run)
    DrawGroundGlow(run)
    DrawParts(run, "flat")
    -- shadows
    local props = {}
    for cx = floor((CAMX - 260) / E.CH), floor((CAMX + v.VW + 260) / E.CH) do
        for cy = floor((CAMY - 120) / E.CH), floor((CAMY + v.VH + 520) / E.CH) do
            for _, o in ipairs(E.Chunk(run, cx, cy)) do props[#props + 1] = o end
        end
    end
    for _, o in ipairs(props) do local pr = A.PROPS[o.name] if pr then local w = pr[4] Shadow(o.x - w * 0.33, o.y - w * 0.1, w * 0.66, w * 0.2, 0.8) end end
    for _, e in ipairs(run.en) do
        if inView(e.x, e.y, 60) then
            local r = e.M.r * (e.M.reaper and 1.6 or 1)
            Shadow(e.x - r * 1.5, e.y - r * 0.5, r * 3, r, e.M.fly and 0.5 or 1)
        end
    end
    Shadow(p.x - 20, p.y - 6, 40, 13, 1)
    DrawGems(run)
    -- the bodies, by depth
    LISTN = 0
    for _, o in ipairs(props) do Push(o.y, 0, o) end
    for _, c in ipairs(run.corpses) do if inView(c.x, c.y, 80) then Push(c.y - 6, 1, c) end end
    for _, e in ipairs(run.en) do if inView(e.x, e.y, 120) then Push(e.y, 2, e) end end
    for _, k in ipairs(run.pick) do if inView(k.x, k.y, 60) then Push(k.y, 3, k) end end
    for _, f in ipairs(run.fx) do if f.kind == "icicle" then Push(f.y, 5, f) end end
    for _, a in ipairs(run.allies or {}) do if inView(a.x, a.y, 80) then Push(a.y, 6, a) end end
    Push(p.y, 4, p)
    for i = 1, LISTN do
        local it = LIST[i]
        if it.k == 0 then DrawProp(it.o)
        elseif it.k == 1 then DrawCorpse(run, it.o)
        elseif it.k == 2 then DrawEnemy(run, it.o)
        elseif it.k == 3 then DrawPick(run, it.o)
        elseif it.k == 5 then DrawIcicle(run, it.o)
        elseif it.k == 6 then
            local a = it.o
            local M = MOBS[a.type]
            local key = M and M.sprite or a.type
            local U = A.UNITS[key]
            if U then
                local bp, sub = Band(a.y)
                local g = Take(bp.glow) File(g, UIM .. "glow") g:SetTexCoord(0, 1, 0, 1) Col(g, GLOWC.green, 0.4) At(g, a.x, a.y - 16, 60, 60)
                Sprite(bp, sub, key, a.dir, floor(a.anim) % U.walk, a.x, a.y, min(1, (a.life - a.t) * 2) * 0.85, 0.15, M and M.scale or 1, nil, nil, { 0.55, 1, 0.55 })
            end
        else DrawPlayer(run) end
    end
    DrawParts(run, "air", "norm")
    -- grade + dark
    v.tint:SetShown(true)
    DrawDark(run)
    -- light
    DrawAirFx(run)
    DrawParts(run, "air", "add")
    -- fog, vignette, slow motion, flash
    local fx0, fy0 = (CAMX * 0.9 + run.t * 14) / 512, (CAMY * 0.9 + run.t * 5) / 512
    v.fog:SetTexCoord(fx0, fx0 + v.VW / 512, fy0, fy0 + v.VH / 512)
    local fc = ST and ST.fogC or C.WHITE
    v.fog:SetVertexColor(fc[1], fc[2], fc[3], (ST and ST.fog or D.STAGE.fog) + run.dark * 0.1)
    v.vig:ClearAllPoints()
    v.vig:SetPoint("TOPLEFT", v.scaler, "TOPLEFT", -40, 30)
    v.vig:SetSize(v.VW + 80, v.VH + 60)
    v.vig:SetAlpha(0.7)
    if run.ts < 0.9 then v.dim:SetColorTexture(10 / 255, 6 / 255, 18 / 255, (1 - run.ts) * 0.35) v.dim:Show() else v.dim:Hide() end
    if run.flash > 0 then v.flashT:SetColorTexture(run.flashC[1], run.flashC[2], run.flashC[3], run.flash * 0.55) v.flashT:Show() else v.flashT:Hide() end
    DrawTexts(run)
    if not run.preview and Rd.DrawHud then Rd.DrawHud(v, run) end
    Finish(v)
end

-- (the HUD helpers for HUD.lua)
Rd.Take, Rd.File, Rd.Size, Rd.Col, Rd.Rot, Rd.FxFile, Rd.Glow = Take, File, Size, Col, Rot, FxFile, Glow
function Rd.Use(v) V = v end
function Rd.View() return V end
