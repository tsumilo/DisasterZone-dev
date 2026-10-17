if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/BattleScene.lua", ...) then return end -- DisasterZone_Azeromon/BattleScene.lua
-- ns.AzeroBattleScene: battles where you stand (Azeromon 0.45, the fidelity mockup's section 1).
--
-- The scene comes from the spot you were standing on (SpotFor: next to water a pond or lake, on a road the road
-- with its lamp, in town the town's edge, else the zone's field) and keeps the time of day and the weather: each
-- outdoor scene is five layers (BattleScenes.lua, gen_azeromon_battle.py), one set per period (day, dusk, night,
-- rain), that drift at their own speed (sky 0.1, far 0.25, near 0.5, ground and beasts 1, grass in front 1.3).
-- Water mirrors the sky and far shore in rippling rows (kept to the water by a mask). The beasts take the light:
-- a shade for the period with the lamp's pool let through, a shadow on their platform from the sun, the lamp or the
-- moon (one-row strips of their own frame), a contact shadow, and a rim on the edge that faces the light (idle
-- frames, BeastRim.lua). A big hit pushes the camera in on the beast that took it. Underground and indoors the old
-- picture stays (BattleScenes `flat`), the beasts still lit by its lanterns or lava.
-- UI.lua: Build (with the battle layer), Begin / End (a battle shows / goes), Update (every frame), Punch (a hit).
local addonName, ns = ...

local BS = {}
ns.AzeroBattleScene = BS

local floor, min, max, abs, sqrt, sin, cos, pi = math.floor, math.min, math.max, math.abs, math.sqrt, math.sin, math.cos, math.pi
local function round(v) return floor(v + 0.5) end

BS.off = false
local function Art() return ns.AzeroBattleScenes end
local G

function BS.On()
    local art = Art()
    if BS.off or not art or not ns:HasAssets(art.asset or 0) then return false end
    G = G or ns.Azero
    return not (G and G.Data and G:Data().lights == false)
end

---------------------------------------------------------------------------
-- Where you stand
---------------------------------------------------------------------------

local function Ch(m, x, y)
    local r = m.def.rows[y + 1]
    return r and r:sub(x + 1, x + 1) or ""
end

-- The scene for a battle that starts at x, y on map m: a spot of its zone's scene, the zone's own field, a flat
-- scene (underground / indoors), or nil (no layered art for it: the old picture).
function BS.SpotFor(m, x, y)
    local art, old = Art(), ns.AzeroBattleArt
    if not (art and old and m and m.def) then return nil end
    local def = m.def
    local base = old.scenes[m.id] or old.scenes[def.theme or ""]
    if not base then base = def.outdoor and old.outdoor or old.indoor end
    local spots = art.spots[base]
    x, y = x or 0, y or 0
    if spots then
        local water, road = false, false
        for dy = -2, 2 do
            for dx = -2, 2 do
                local c = Ch(m, x + dx, y + dy)
                if c == "w" then water = true end
                if c == "=" and abs(dx) <= 1 and abs(dy) <= 1 then road = true end
            end
        end
        if water and (spots.pond or spots.lake) then return spots.pond or spots.lake end
        if road and spots.road then return spots.road end
        if spots.town then
            for _, s in ipairs(def.stamps or {}) do
                if abs((s.x or 0) - x) <= 6 and abs((s.y or 0) - y) <= 6 then return spots.town end
            end
        end
    end
    if art.scenes[base] then return base end
    return nil
end

-- The battle's light: "day", "dusk", "night" or "rain", from the realm clock and the weather where you stood.
function BS.PeriodNow(raining)
    G = G or ns.Azero
    local p = G:Period()
    if p == "night" then return "night" end
    if raining then return "rain" end
    if p == "dusk" or p == "dawn" then return "dusk" end
    return "day"
end

---------------------------------------------------------------------------
-- The layers
---------------------------------------------------------------------------

local b, S3, setPixel, opts
local L = { rows = {} }
BS._L = L                      -- (tests: the layer textures)
local pools = {}
local cur                      -- the battle on screen: { key, sc, period, rain, dawn, flat }
local GLOW = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local CLOUDS = "Interface\\AddOns\\DisasterZone_Azeromon\\Media\\Ground\\battle_clouds"
local SIL = "Interface\\AddOns\\DisasterZone_Azeromon\\Media\\chars_sil"

local function Pool(name, parent, layer, sub, blend, file)
    local p = pools[name]
    if not p then
        p = { used = 0, list = {}, parent = parent, layer = layer, sub = sub, blend = blend, file = file }
        pools[name] = p
    end
    return p
end
local function Get(p)
    p.used = p.used + 1
    local t = p.list[p.used]
    if not t then
        t = p.parent:CreateTexture(nil, p.layer, nil, p.sub)
        if p.blend then pcall(t.SetBlendMode, t, p.blend) end
        if p.file then setPixel(t, p.file) end
        p.list[p.used] = t
    end
    return t
end
local function Flush(p) for i = p.used + 1, #p.list do p.list[i]:Hide() end p.used = 0 end

-- (attached by UI.lua's BuildBattle) battle = the battle layer, scale = UI pixels per game pixel; o.bleed() = the
-- battle layer's own scale (FitScreen), o.models() = foe, ally model frames, o.drift(dx, dy) moves the beasts and
-- the effects with the ground (Fx.lua), o.shakeOn() = shaking allowed
function BS.Build(battle, scale, setPixelTexture, o)
    b, S3, setPixel, opts = battle, scale, setPixelTexture, o or {}
    local function T(layer, sub) local t = b:CreateTexture(nil, layer, nil, sub) t:Hide() return t end
    L.sky, L.clouds, L.far, L.near, L.ground = T("BACKGROUND", 0), T("BACKGROUND", 1), T("BACKGROUND", 2),
        T("BACKGROUND", 3), T("BACKGROUND", 5)
    if not pcall(L.clouds.SetTexture, L.clouds, CLOUDS, "REPEAT", "CLAMP", "NEAREST") then L.clouds:SetTexture(CLOUDS) end
    if b.CreateMaskTexture then
        L.mask = b:CreateMaskTexture()
    end
    BS.front = CreateFrame("Frame", nil, b)                         -- over the beasts: grass in front, rims
    BS.front:SetAllPoints(b)
    BS.front:SetFrameLevel(b:GetFrameLevel() + 3)
    BS.top = CreateFrame("Frame", nil, b)                           -- rain, fireflies
    BS.top:SetAllPoints(b)
    BS.top:SetFrameLevel(b:GetFrameLevel() + 4)
    L.fg = BS.front:CreateTexture(nil, "ARTWORK", nil, 0)
    L.fg:Hide()
    Pool("smoke", b, "BACKGROUND", 4)
    Pool("refl", b, "BACKGROUND", 6)
    Pool("shadow", b, "BORDER", 0)
    Pool("contact", b, "BORDER", 0, nil, SIL)
    Pool("glit", b, "BORDER", 3, "ADD")
    Pool("glow", b, "BORDER", 2, "ADD", GLOW)
    Pool("rim", BS.front, "OVERLAY", 2, "ADD")
    Pool("pix", BS.top, "OVERLAY", 0)
    Pool("fly", BS.top, "OVERLAY", 1, "ADD")
end

-- layer pixels (x from the layer's left, y down) -> the battle layer; ux, uy: a further offset in UI pixels (the
-- drift, already snapped to the screen's pixels)
local function Place(t, x, y, w, h, ux, uy)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", b, "TOPLEFT", x * S3 + (ux or 0), -(y * S3 + (uy or 0)))
    t:SetSize(max(1, w * S3), max(1, h * S3))
end

-- One pixel of the screen, in the battle layer's units: the drift moves the layers by whole screen pixels, so a
-- layer glides instead of jumping a whole game pixel (3 UI pixels) at a time, and never lands between two pixels.
local function PixelUnit()
    local f = PixelUtil and PixelUtil.GetPixelToUIUnitFactor and PixelUtil.GetPixelToUIUnitFactor()
    local es = b.GetEffectiveScale and b:GetEffectiveScale()
    if f and es and es > 0 then return f / es end
    return 1
end
local function Snap(v, pu) return floor(v / pu + 0.5) * pu end
BS._Snap = Snap

local function File(name) return Art().dir .. name end

-- A battle starts: pick and show its scene. Returns "layers" (the old picture hides), "flat" (the old picture stays,
-- the beasts are lit by its lights) or nil (nothing to do).
function BS.Begin(m, x, y, raining)
    BS.End()
    if not (b and BS.On()) then return nil end
    local art = Art()
    local key = BS.SpotFor(m, x, y)
    local sc = key and art.scenes[key]
    if not sc then return nil end
    G = G or ns.Azero
    cur = { key = key, sc = sc, period = BS.PeriodNow(raining), rain = raining and true or false,
            dawn = G:Period() == "dawn", flat = sc.flat and true or false, t = 0, punch = nil }
    if cur.flat then return "flat" end
    local p = cur.period
    local function Layer(t, name, w, h, tw, th)
        setPixel(t, File(key .. "_" .. name .. "_" .. p))
        t:SetTexCoord(0, w / tw, 0, h / th)
        t:Show()
    end
    Layer(L.sky, "sky", 240, 64, 256, 64)
    Layer(L.far, "far", 240, 64, 256, 64)
    Layer(L.near, "near", 240, 64, 256, 64)
    Layer(L.ground, "ground", 240, 128, 256, 128)
    L.clouds:SetShown(sc.clouds and (p == "day" or p == "dusk") or false)
    if p == "dusk" then L.clouds:SetVertexColor(1, 0.78, 0.72, 0.55) else L.clouds:SetVertexColor(1, 1, 1, 0.9) end
    if sc.blades then
        setPixel(L.fg, File("blades_" .. sc.blades))
        local d = ({ day = { 1, 1, 1 }, dusk = { 0.93, 0.75, 0.66 }, night = { 0.31, 0.36, 0.59 }, rain = { 0.73, 0.76, 0.82 } })[p]
        L.fg:SetVertexColor(d[1], d[2], d[3])
        L.fg:Show()
    else
        L.fg:Hide()
    end
    cur.water = sc.water
    if sc.water and L.mask then
        local y0, y1 = sc.water[1], sc.water[2]
        local th = (y1 - y0 < 32) and 32 or 64
        pcall(L.mask.SetTexture, L.mask, File(key .. "_wmask"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        cur.maskTH = th
    end
    return "layers"
end

function BS.End()
    if cur and cur.punch and b then BS.Zoom(1) end
    cur = nil
    for _, t in ipairs({ L.sky, L.clouds, L.far, L.near, L.ground, L.fg }) do if t then t:Hide() end end
    for _, t in ipairs(L.rows) do t:Hide() end
    for _, p in pairs(pools) do Flush(p) end
    if opts and opts.drift then opts.drift(0, 0) end
    for _, m in ipairs(opts and opts.models and { opts.models() } or {}) do
        if m and m.spr and m.spr.SetLight then m.spr:SetLight(nil) end
    end
end

function BS.Current() return cur and { key = cur.key, period = cur.period, rain = cur.rain, flat = cur.flat } or nil end

---------------------------------------------------------------------------
-- Every frame
---------------------------------------------------------------------------

local function Drift(t)
    return sin(t * 0.21) * 3.2 + sin(t * 0.53) * 0.8, sin(t * 0.17) * 0.8
end

local SX, SY = 0, 0                -- the shake (UI pixels), from Fx.lua's scene callback
function BS.Shake(dx, dy) SX, SY = dx or 0, dy or 0 end

local DARKS = { day = { 1, 1, 1 }, dusk = { 0.93, 0.75, 0.66 }, night = { 0.31, 0.36, 0.59 }, rain = { 0.73, 0.76, 0.82 } }

-- the light on a beast whose feet are at fx, fy (layer pixels): its shade, its shadow (kx, ky, a) and rims
local function BeastLight(fx, fy, top)
    local sc, p = cur.sc, cur.period
    local tint = { 1, 1, 1 }
    local shadow, rims = nil, {}
    if not cur.flat then tint = { DARKS[p][1], DARKS[p][2], DARKS[p][3] } end
    local lamp, ld
    for _, l in ipairs(sc.lights or {}) do
        local d = sqrt((fx - l[1]) ^ 2 + (fy - (l[2] + 14)) ^ 2)
        if not lamp or d < ld then lamp, ld = l, d end
        if p == "dusk" or p == "night" or cur.flat then
            local r = l[5] * ((p == "dusk" and not cur.flat) and 0.75 or 1)
            local u = d / r
            local k = (u < 0.35 and 1 - u / 0.35 * 0.25) or (u < 0.7 and 0.75 - (u - 0.35) / 0.35 * 0.5) or (u < 1 and 0.25 * (1 - (u - 0.7) / 0.3)) or 0
            for i = 1, 3 do tint[i] = max(tint[i], l[5 + i] * k) end
        end
    end
    local lit = lamp and (p == "night" or p == "dusk" or cur.flat)
    if cur.rain and not lit then return tint, nil, rims end
    if p == "day" and not cur.flat then
        shadow = { kx = 0.55, ky = -0.16, a = 0.34 }
        rims[1] = { -0.7, -1, 1, 0.98, 0.91, 0.22 }
    elseif p == "dusk" and not cur.flat and not lit then
        local s = cur.dawn and -1 or 1
        shadow = { kx = 1.25 * s, ky = -0.07, a = 0.22 }
        rims[1] = { -s, -0.15, 1, 0.63, 0.35, 0.6 }
    end
    if lit then
        local vx, vy = fx - lamp[3], fy - lamp[4]
        local d = sqrt(vx * vx + vy * vy)
        if d < 0.5 then d = 0.5 end
        local w = max(0, min(1, 1 - d / 150))
        local len = max(0.35, min(1.3, d / 70))
        shadow = { kx = vx / d * len, ky = vy / d * len * 0.35, a = 0.42 * w + 0.05 }
        local hx, hy = lamp[1] - fx, lamp[2] - top
        local hd = sqrt(hx * hx + hy * hy)
        rims[#rims + 1] = { hx, hy, lamp[6], lamp[7], lamp[8], max(0.15, min(0.95, 1.15 - hd / 130)) }
    elseif p == "night" then
        shadow = { kx = -0.5, ky = -0.08, a = 0.14 }
    end
    if p == "night" and not cur.flat then rims[#rims + 1] = { 1, -1, 0.59, 0.67, 1, 0.22 } end
    return tint, shadow, rims
end

-- rims: the frame's outline from BeastRim.lua (idle frames), lit by how squarely it faces each light
local B64I = {}
do local s = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" for i = 1, #s do B64I[s:sub(i, i)] = i - 1 end end
local function Runs(s)
    local out, last, i = {}, nil, 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "." then out[#out + 1] = -1 last = nil i = i + 1
        elseif c == "!" then
            last = B64I[s:sub(i + 1, i + 1)] + B64I[s:sub(i + 2, i + 2)] * 64
            out[#out + 1] = last
            i = i + 3
        else
            last = (last or 0) + B64I[c] - 32
            out[#out + 1] = last
            i = i + 1
        end
    end
    return out
end
local rimCache = {}
local function Outline(key, view, idx, w, h)
    local ck = key .. view .. idx
    local e = rimCache[ck]
    if e ~= nil then return e end
    local data = ns.AzeroBeastRim and ns.AzeroBeastRim.beasts[key]
    local s = data and data[view]
    e = false
    if s then
        local n = 0
        for frame in (s .. "|"):gmatch("([^|]*)|") do
            n = n + 1
            if n == idx then
                local l, r, t = frame:match("^([^,]*),([^,]*),([^,]*)$")
                if l then
                    local left, right, top = Runs(l), Runs(r), Runs(t)
                    e = {}
                    local seen = {}
                    local function add(x, y, nx, ny)
                        local k = y * 256 + x
                        local q = seen[k]
                        if q then q[3], q[4] = q[3] + nx, q[4] + ny return end
                        q = { x, y, nx, ny }
                        seen[k] = q
                        e[#e + 1] = q
                    end
                    for y = 1, #left do
                        local a, a0, a1 = left[y], left[y - 1], left[y + 1]
                        if a >= 0 then add(a, y - 1, -2, ((a1 and a1 >= 0) and a1 or a) - ((a0 and a0 >= 0) and a0 or a)) end
                        local c, c0, c1 = right[y], right[y - 1], right[y + 1]
                        if c >= 0 then add(c, y - 1, 2, -(((c1 and c1 >= 0) and c1 or c) - ((c0 and c0 >= 0) and c0 or c))) end
                    end
                    for x = 1, #top do
                        local a, a0, a1 = top[x], top[x - 1], top[x + 1]
                        if a >= 0 then add(x - 1, a, ((a1 and a1 >= 0) and a1 or a) - ((a0 and a0 >= 0) and a0 or a), -2) end
                    end
                    for _, q in ipairs(e) do
                        local ln = sqrt(q[3] * q[3] + q[4] * q[4])
                        if ln < 0.01 then ln = 1 end
                        q[3], q[4] = q[3] / ln, q[4] / ln
                    end
                end
                break
            end
        end
    end
    rimCache[ck] = e
    return e
end
BS._Outline = Outline

local function DrawBeast(m, side, gdx, gdy)
    local spr = m and m.spr
    if not (spr and spr.key and spr.tex and spr.tex:IsShown() and spr.cur and spr.seq) then
        if spr and spr.SetLight then spr:SetLight(nil) end
        return
    end
    local f = spr.cur.frames[spr.seq[spr.pos]]
    if not f then return end
    local art = Art()
    local home = art[side]                                 -- layer pixels of the feet (platform centre)
    local fx, fy = home[1], home[2]
    local k = spr.scale
    local fw, fh = f[3], f[4]
    local tint, shadow, rims = BeastLight(fx, fy, fy - (f[6] + fh) * k / S3 * 0.6)
    if spr.SetLight then spr:SetLight(tint[1], tint[2], tint[3]) end
    if (spr.shrink or 1) < 0.99 or (spr.flash or 0) > 0.6 then return end           -- (the taming moment)
    -- the shadow, contact and rim are drawn on the battle layer, not on the beast's own frame: they follow how much
    -- of the beast shows (it fades in when sent out, out when it faints or is called back, then hides)
    local seen = 0
    if m:IsVisible() then
        seen = (m.GetEffectiveAlpha and m:GetEffectiveAlpha()) or m:GetAlpha() or 1
        if spr.tex.GetAlpha then seen = seen * (spr.tex:GetAlpha() or 1) end
    end
    if seen < 0.05 then return end
    -- where the frame is: the model's bottom centre + the sprite's lift (UI pixels from the battle layer's top left)
    local _, _, _, mx, my = m:GetPoint(1)
    local feetX, feetY = (mx or 0) + (m.w or m:GetWidth() or 0) / 2, (my or 0) + (spr.lift or 0)
    -- contact shadow under the feet
    local info = ns.AzeroBeastArt and ns.AzeroBeastArt.beasts[spr.key]
    local cw = max(12, (info and info.iw or fw) * 0.72) * (k / S3)
    local c = Get(pools.contact)
    local la = ns.AzeroLightArt
    if la then
        local ct = la.contact
        c:SetTexCoord(ct[1] / la.w, (ct[1] + ct[3]) / la.w, ct[2] / la.h, (ct[2] + ct[4]) / la.h)
    end
    c:SetSize(cw * S3, 3.2 * S3)
    c:ClearAllPoints()
    c:SetPoint("CENTER", b, "TOPLEFT", feetX, feetY)
    c:SetVertexColor(0, 0, 0, (cur.rain and 0.3 or 0.34) * seen)
    c:Show()
    -- the cast shadow: one-row strips of the frame, each moved by its height over the feet
    if shadow and shadow.a > 0.01 then
        local used = {}
        local hg = max(1, math.ceil(abs(shadow.ky)))
        for r = fh - 1, 0, -1 do
            local hgt = max(0, f[6] + (fh - 1 - r))
            local tr = round(hgt * shadow.ky)
            if not used[tr] then
                used[tr] = true
                local t = Get(pools.shadow)
                if t.path ~= spr.path then
                    t.path = spr.path
                    setPixel(t, spr.path)
                end
                t:SetTexCoord(f[1] / spr.tw, (f[1] + fw) / spr.tw, (f[2] + r) / spr.th, (f[2] + r + 1) / spr.th)
                t:SetSize(fw * k, hg * k)
                t:ClearAllPoints()
                t:SetPoint("BOTTOMLEFT", b, "TOPLEFT", feetX + (f[5] + round(hgt * shadow.kx)) * k, feetY - tr * k - (shadow.ky >= 0 and (hg - 1) * k or 0))
                local fade = 1 - 0.55 * min(1, hgt / max(1, fh))
                t:SetVertexColor(0, 0, 0, shadow.a * fade * seen)
                t:Show()
            end
        end
    end
    -- rims on the edge facing a light (idle frames)
    if #rims > 0 and spr.clip == "idle" then
        local e = Outline(spr.key, spr.view, spr.seq[spr.pos], fw, fh)
        if e then
            for _, q in ipairs(rims) do
                local l = sqrt(q[1] * q[1] + q[2] * q[2])
                q.ux, q.uy = q[1] / l, q[2] / l
            end
            for _, px in ipairs(e) do
                local r_, g_, b_ = 0, 0, 0
                for _, q in ipairs(rims) do
                    local d = px[3] * q.ux + px[4] * q.uy
                    if d > 0.25 then
                        local s = ((d - 0.25) / 0.75) ^ 1.3 * q[6] * seen
                        r_, g_, b_ = r_ + q[3] * s, g_ + q[4] * s, b_ + q[5] * s
                    end
                end
                if r_ + g_ + b_ > 0.04 then
                    local t = Get(pools.rim)
                    t:SetColorTexture(min(1, r_), min(1, g_), min(1, b_), 1)
                    t:SetSize(k, k)
                    t:ClearAllPoints()
                    t:SetPoint("BOTTOMLEFT", b, "TOPLEFT", feetX + (f[5] + px[1]) * k, feetY + (f[6] + fh - 1 - px[2]) * k)
                    t:Show()
                end
            end
        end
    end
end

local function Pix(pool, x, y, w, h, r, g, bl, a, ux, uy)
    local t = Get(pool)
    t:SetColorTexture(r, g, bl, a)
    Place(t, x, y, w, h, ux, uy)
    t:Show()
end

local function Ring(pool, cx, cy, rad, a)
    local n = max(8, floor(rad * 5))
    local seen = {}
    for i = 0, n - 1 do
        local th = i / n * 2 * pi
        local x, y = round(cx + cos(th) * rad), round(cy + sin(th) * rad * 0.45)
        local key = x * 1000 + y
        if not seen[key] then seen[key] = true Pix(pool, x, y, 1, 1, 0.84, 0.89, 0.94, a) end
    end
end

local function H(x, y, s)
    local h = (x * 374761393 + y * 668265263 + (s + 1) * 1442695041) % 4294967296
    h = (h * 1274126177) % 4294967296
    return (h % 100000) / 100000
end

-- The push-in: zoom the battle layer toward a point (layer pixels) by z, keeping that point where it is.
function BS.Zoom(z, px, py)
    if not b then return end
    local bleed = opts.bleed and opts.bleed() or 1
    local W, Hh = b:GetWidth(), b:GetHeight()
    local cx, cy = 0, 0
    if px then cx, cy = (px - Art().off) * S3 - W / 2, -(py * S3 - Hh / 2) end
    b:ClearAllPoints()
    b:SetScale(bleed * z)
    local pu = PixelUnit()                                  -- (the shift in whole screen pixels, at the new scale)
    b:SetPoint("CENTER", b:GetParent(), "CENTER", Snap(cx / z - cx, pu), Snap(cy / z - cy, pu))
end

function BS.Punch(side, amp)
    if not cur or cur.flat or (opts.shakeOn and not opts.shakeOn()) then return end
    local home = Art()[side == "ally" and "ally" or "foe"]
    cur.punch = { t = 0, z = 1 + 0.02 * min(3, max(1, amp or 1)), x = home[1], y = home[2] - 20 }
end

function BS.Update(dt)
    if not cur then return end
    dt = dt or 0
    cur.t = cur.t + dt
    local t = (G and G.Data and G:Data().calm) and 0 or cur.t
    local art, sc, p = Art(), cur.sc, cur.period
    for _, pool in pairs(pools) do pool.used = 0 end
    local cx, cy = 0, 0
    if not cur.flat then cx, cy = Drift(t) end
    -- each layer's drift in UI pixels, snapped to the screen's: sky 0.1, clouds 0.15, far 0.25, near 0.5, the
    -- ground with the beasts and their effects 1, the grass in front 1.3
    local pu = PixelUnit()
    local function Off(kx, ky) return Snap(cx * kx * S3, pu), Snap(cy * ky * S3, pu) end
    local skx = Snap(cx * 0.1 * S3, pu)
    local fx_, fy_ = Off(0.25, 0.3)
    local nx_, ny_ = Off(0.5, 0.5)
    local gx_, gy_ = Off(1, 1)
    local bx_, by_ = Off(1.3, 1.2)
    if opts.drift then opts.drift(gx_, gy_) end
    local sx, sy = SX / S3, -SY / S3                            -- (the shake, back to layer pixels)
    local OFF = art.off
    if not cur.flat then
        Place(L.sky, -OFF + sx, sy, 240, 64, skx, 0)
        if L.clouds:IsShown() then
            -- the strip shown twice side by side and slid along by its position (a scrolled texture steps a whole
            -- texel at a time); one strip's width on, it is back where it started
            L.clouds:SetTexCoord(0, 2, 0, 1)
            Place(L.clouds, -OFF + sx, 2 + sy, 512, 48, Snap((cx * 0.15 - (t * 2) % 256) * S3, pu), 0)
        end
        Place(L.far, -OFF + sx, sy, 240, 64, fx_, fy_)
        Place(L.near, -OFF + sx, sy, 240, 64, nx_, ny_)
        Place(L.ground, -OFF + sx, art.groundTop + sy, 240, 128, gx_, gy_)
        -- chimney smoke, drifting up from the near layer
        for _, s in ipairs(sc.smoke or {}) do
            for i = 0, 8 do
                local ph = (t * 0.22 + i / 9) % 1
                local x = s[1] - OFF + round(sin(ph * 5 + i) * 1.5 + ph * 7)
                local y = s[2] - round(ph * 22)
                local sz = ph > 0.4 and 2 or 1
                Pix(pools.smoke, x + sx, y + sy, sz, sz, 0.84, 0.84, 0.86, 0.5 * (1 - ph) * (p == "night" and 0.4 or 1), nx_, ny_)
            end
        end
        -- the water: mirrored sky and shore in rippling rows, kept to the water
        local nrows = 0
        if sc.water then
            nrows = sc.water[2] - sc.water[1] + 1
            local y0, y1 = sc.water[1], sc.water[2]
            local th = (y1 - y0 < 32) and 32 or 64
            local amp = cur.rain and 1.6 or 1
            if L.mask then
                L.mask:ClearAllPoints()
                L.mask:SetPoint("TOPLEFT", b, "TOPLEFT", (-OFF + sx) * S3 + gx_, -((y0 + sy) * S3 + gy_))
                L.mask:SetSize(256 * S3, th * S3)
            end
            for y = y0, y1 do
                local i = y - y0 + 1
                local r = L.rows[i]
                if not r then
                    r = b:CreateTexture(nil, "BACKGROUND", nil, 6)
                    L.rows[i] = r
                    if L.mask and r.AddMaskTexture then pcall(r.AddMaskTexture, r, L.mask) end
                end
                local file = File(cur.key .. "_refl_" .. p)
                if r.file ~= file then r.file = file setPixel(r, file) end
                r:SetTexCoord(0, 240 / 256, (i - 1) / th, i / th)
                local off = round((sin(y * 0.9 + t * 2.3) * 0.7 + sin(y * 0.31 - t * 1.4) * 0.5) * amp * (1 + (y - y0) / 30))
                Place(r, -OFF + off + sx, y + sy, 240, 1, gx_, gy_)
                r:SetAlpha(cur.rain and 0.6 or 1)
                r:Show()
            end
            -- the moon's glitter at night
            if p == "night" and not cur.rain then
                for i = 0, 49 do
                    local y = y0 + 1 + floor(H(i, 5, 3) * (y1 - y0))
                    local x = round(art.moon[1] + (H(i, 6, 3) - 0.5) * (8 + (y - y0) * 0.6))
                    local ph = (t * 0.8 + H(i, 7, 3)) % 1
                    if ph < 0.55 then
                        local wide = ph > 0.15 and ph < 0.4
                        Pix(pools.glit, x - OFF - (wide and 1 or 0) + sx, y + sy, wide and 3 or 1, 1, 0.81, 0.85, 1,
                            0.6 * sin(ph / 0.55 * pi), gx_, gy_)
                    end
                end
            end
        end
        for i = nrows + 1, #L.rows do L.rows[i]:Hide() end
        -- glows at the lamp's glass and the windows (dusk and night)
        if p == "dusk" or p == "night" then
            for _, l in ipairs(sc.lights or {}) do
                local g = Get(pools.glow)
                local fl = 0.85 + 0.15 * sin(t * 9 + l[1]) * sin(t * 5.3)
                g:SetVertexColor(l[6], l[7] * 0.8, l[8] * 0.55, 0.45 * fl * (p == "dusk" and 0.6 or 1))
                g:ClearAllPoints()
                g:SetPoint("CENTER", b, "TOPLEFT", (l[1] - OFF + sx) * S3 + gx_, -((l[2] + sy) * S3 + gy_))
                g:SetSize(52 * S3, 52 * S3)
                g:Show()
            end
            for _, w in ipairs(sc.windows or {}) do
                local g = Get(pools.glow)
                g:SetVertexColor(1, 0.75, 0.43, 0.4)
                g:ClearAllPoints()
                g:SetPoint("CENTER", b, "TOPLEFT", (w[1] - OFF + sx) * S3 + nx_, -((w[2] + sy) * S3 + ny_))
                g:SetSize(16 * S3, 16 * S3)
                g:Show()
            end
        end
        -- grass in front of your beast
        if L.fg:IsShown() then
            local nfr, th = art.bladesFrames or 4, art.bladesTexH or 256
            local fr = floor(t * 4) % nfr
            L.fg:SetTexCoord(0, 240 / 256, fr * art.bladesH / th, (fr + 1) * art.bladesH / th)
            Place(L.fg, -OFF + sx, art.bladesY + sy, 240, art.bladesH, bx_, by_)
        end
    end
    -- the beasts: their shade, shadow and rims
    if opts.models then
        local foe, ally = opts.models()
        DrawBeast(foe, "foe")
        DrawBeast(ally, "ally")
    end
    -- rain, fireflies
    if cur.rain then
        for k = 0, 89 do
            local fall = 156
            local y = ((k * 0.7548) % 1 * fall + t * 170) % fall - 6
            local x = ((k * 0.5698) % 1 * 254 - y * 0.25) % 254 - 10
            Pix(pools.pix, round(x), round(y), 1, 3, 0.77, 0.83, 0.93, 0.5)
        end
        for k = 0, 39 do
            local cyc = floor(t * 2 + k * 0.37)
            local x = round(((cyc * 0.618 + k * 0.381) % 1) * 224)
            local y = round(art.horizon + 4 + ((cyc * 0.414 + k * 0.732) % 1) * 84)
            local ph = (t * 2 + k * 0.37) % 1
            local w = sc.water
            if w and y >= w[1] + 2 and y <= w[2] then
                Ring(pools.pix, x, y, 0.5 + ph * 5 * (0.5 + (y - art.horizon) / 80), 0.55 * (1 - ph))
            elseif ph < 0.4 and not cur.flat then
                Pix(pools.pix, x - 1, y, 1, 1, 0.84, 0.89, 0.96, 0.6)
                Pix(pools.pix, x + 1, y, 1, 1, 0.84, 0.89, 0.96, 0.6)
                Pix(pools.pix, x, y - 1, 1, 1, 0.84, 0.89, 0.96, 0.6)
            end
        end
    elseif p == "night" and sc.flies then
        for i = 0, 11 do
            local x = round((H(i, 1, 2) * 240 + sin(t * 0.4 + i) * 14 + cx) % 240) - OFF
            local y = round(64 + H(i, 2, 2) * 60 + sin(t * 0.7 + i * 2) * 6)
            local a = 0.5 + 0.5 * sin(t * 2.2 + i * 1.7)
            Pix(pools.fly, x, y, 1, 1, 0.84, 1, 0.55, 0.8 * a)
        end
    end
    -- the push-in after a big hit
    local push = cur.punch
    if push then
        push.t = push.t + dt
        local h = push.t
        -- eased in and out (smoothstep), so it settles instead of snapping at the ends
        local function ease(u) u = max(0, min(1, u)) return u * u * (3 - 2 * u) end
        local k = (h < 0.14 and ease(h / 0.14)) or (h < 0.45 and 1) or (h < 0.95 and 1 - ease((h - 0.45) / 0.5)) or 0
        BS.Zoom(1 + (push.z - 1) * k, push.x, push.y)
        if h >= 0.95 then cur.punch = nil BS.Zoom(1) end
    end
    for _, pool in pairs(pools) do Flush(pool) end
end

-- tests: what is on screen
function BS.Stats()
    local shown = function(p) local n = 0 for _, t in ipairs(p and p.list or {}) do if t:IsShown() then n = n + 1 end end return n end
    local rows = 0
    for _, t in ipairs(L.rows) do if t:IsShown() then rows = rows + 1 end end
    return { scene = cur and cur.key or false, period = cur and cur.period or false, flat = cur and cur.flat or false,
             sky = L.sky and L.sky:IsShown() or false, ground = L.ground and L.ground:IsShown() or false,
             groundFile = L.ground and L.ground:IsShown() and L.ground:GetTexture() or false,
             fg = L.fg and L.fg:IsShown() or false, rows = rows, shadows = shown(pools.shadow), rims = shown(pools.rim),
             contacts = shown(pools.contact), glows = shown(pools.glow), pix = shown(pools.pix), smoke = shown(pools.smoke),
             punch = cur and cur.punch and true or false, scale = b and b:GetScale() or 1 }
end
