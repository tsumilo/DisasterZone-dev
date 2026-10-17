if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/Water.lua", ...) then return end -- DisasterZone_Azeromon/Water.lua
-- ns.AzeroWater: water that reflects (Azeromon 0.46, the fidelity mockup's section 3).
--
--   reflection  what stands near a shore, mirrored into the water (baked by gen_azeromon_water.py, WaterArt.lua),
--               drawn as one-pixel rows nudged sideways (the ripple), kept to the water by the map's water mask
--               (a MaskTexture). Fainter and choppier in the rain; still when Calm is on.
--   people      a person whose next tile down is water shows mirrored below the shore; a person wading in the
--               shallows (Maps def.shallows) shows only above the water line, mirrored below it, with rings.
--   life        rain rings on open water and puddles with rings on the roads; at night a glitter of moonlight.
-- UI.lua: Begin (the frame), Person (each person), End, Life (inside Amb.Draw, with its pooled pixels).
local addonName, ns = ...

local W = {}
ns.AzeroWater = W

local floor, min, max, sin, cos, pi = math.floor, math.min, math.max, math.sin, math.cos, math.pi
local function round(v) return floor(v + 0.5) end

W.off = false
local DIR = "Interface\\AddOns\\DisasterZone_Azeromon\\Media\\Water\\"
local CLEAN = "Interface\\AddOns\\DisasterZone_Azeromon\\Media\\chars_clean"
local function Art() return ns.AzeroWaterArt end

function W.On()
    local art = Art()
    if W.off or not art or not ns:HasAssets(art.asset or 0) then return false end
    return ns.AzeroLight and ns.AzeroLight.On() or false
end

local parent, S, setPixel
local rows, people, usedRows, usedPeople = {}, {}, 0, 0
local mask, maskFile
local F = {}

function W.Attach(world, scale, setPixelTexture)
    parent, S, setPixel = world, scale, setPixelTexture
end

local function Mask()
    if mask == nil then
        mask = (parent.CreateMaskTexture and parent:CreateMaskTexture()) or false
    end
    return mask or nil
end

-- ctx: { m, g, now, raining, calm, toScreen(mapX, mapY) -> screen x, y (y down), view = { x0, y0, x1, y1 } map px }
function W.Begin(ctx)
    usedRows, usedPeople = 0, 0
    F.ctx, F.e = ctx, nil
    local art = Art()
    local m, g = ctx.m, ctx.g
    local e = art and m and g and art.maps[m.id]
    if not (e and W.On()) then return false end
    F.e = e
    local ox, oy = (g.mx or 0) * 16, (g.my or 0) * 16
    -- the mask: the water's shape, at 1/maskScale, from the picture's top left
    local mk = Mask()
    if mk then
        local file = DIR .. m.id .. "_m"
        if maskFile ~= file then
            maskFile = file
            pcall(mk.SetTexture, mk, file, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        end
        local sx, sy = ctx.toScreen(-ox, -oy)
        mk:ClearAllPoints()
        mk:SetPoint("TOPLEFT", parent, "TOPLEFT", sx, -sy)
        mk:SetSize(e.mask[1] * art.maskScale * S, e.mask[2] * art.maskScale * S)
    end
    -- the reflection's rows in view
    local r = e.refl
    local v = ctx.view
    local file = DIR .. m.id .. "_r"
    local t = ctx.calm and 0 or (ctx.now or 0)
    local amp = ctx.raining and 1.6 or 1
    local y0 = max(r[2], floor(v.y0 + oy) - 1)
    local y1 = min(r[2] + r[4] - 1, floor(v.y1 + oy) + 1)
    for y = y0, y1 do
        local i = y - r[2]
        usedRows = usedRows + 1
        local tx = rows[usedRows]
        if not tx then
            tx = parent:CreateTexture(nil, "BACKGROUND", nil, 3)
            if mk and tx.AddMaskTexture then pcall(tx.AddMaskTexture, tx, mk) end
            rows[usedRows] = tx
        end
        if tx.file ~= file then tx.file = file setPixel(tx, file) end
        tx:SetTexCoord(0, r[3] / r[5], i / r[6], (i + 1) / r[6])
        tx:SetSize(r[3] * S, S)
        local off = ctx.calm and 0 or round((sin(y * 0.9 + t * 2.3) * 0.7 + sin(y * 0.31 - t * 1.4) * 0.5) * amp)
        local sx, sy = ctx.toScreen(r[1] - ox + off, y - oy)
        tx:ClearAllPoints()
        tx:SetPoint("TOPLEFT", parent, "TOPLEFT", sx, -sy)
        tx:SetAlpha(ctx.raining and 0.55 or 1)
        tx:Show()
    end
    return true
end

-- A person (mx, my = map pixels of the sprite's top-left at ground level; c = their cell in the people sheet).
-- opts.wade: they stand in the shallows (the legs under the water line). Mirrors them into the water when it lies
-- right below them.
function W.Person(key, c, mx, my, opts)
    local ctx, e = F.ctx, F.e
    if not e then return end
    local m = ctx.m
    local wade = opts and opts.wade
    local line                                              -- the water line they are mirrored about (map px)
    if wade then
        line = my + 11
    else
        local tx, ty = floor((mx + 8) / 16), floor((my + 15) / 16)
        if not (m.water[m.key(tx, ty + 1)] and not m.water[m.key(tx, ty)]) then return end
        line = (ty + 1) * 16 + 2
    end
    usedPeople = usedPeople + 1
    local t = people[usedPeople]
    if not t then
        t = parent:CreateTexture(nil, "BACKGROUND", nil, 3)
        setPixel(t, CLEAN)
        local mk = Mask()
        if mk and t.AddMaskTexture then pcall(t.AddMaskTexture, t, mk) end
        people[usedPeople] = t
    end
    local rows_ = wade and 11 or 16
    local cx, cy = c % 16, floor(c / 16)
    -- flipped: the texture's bottom row at the top of the quad
    t:SetTexCoord(cx * 16 / 256, (cx + 1) * 16 / 256, (cy * 16 + rows_) / 128, cy * 16 / 128)
    t:SetSize(16 * S, rows_ * S)
    -- a row at height h over the line shows h under it: the quad starts at the line (the feet / the water line)
    local top = wade and line or (2 * line - (my + 16))
    local sx, sy = ctx.toScreen(mx, top)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", sx, -sy)
    local col = e.col
    t:SetVertexColor(0.45 + col[1] * 0.4, 0.45 + col[2] * 0.4, 0.5 + col[3] * 0.4, (ctx.raining and 0.35 or 0.55))
    t:Show()
end

function W.End()
    for i = usedRows + 1, #rows do rows[i]:Hide() end
    for i = usedPeople + 1, #people do people[i]:Hide() end
end

function W.Clear()
    usedRows, usedPeople = 0, 0
    F.e = nil
    W.End()
end

local function H(x, y, s)
    local h = (x * 374761393 + y * 668265263 + (s + 1) * 1442695041) % 4294967296
    h = (h * 1274126177) % 4294967296
    return (h % 100000) / 100000
end

-- a ring on the water (a one-pixel ellipse) through ctx.pix
local function Ring(pix, cx, cy, r, a)
    local n = max(8, floor(r * 5))
    local seen = {}
    for i = 0, n - 1 do
        local th = i / n * 2 * pi
        local x, y = round(cx + cos(th) * r), round(cy + sin(th) * r * 0.45)
        local k = x * 4096 + y
        if not seen[k] then seen[k] = true pix(x, y, 1, 1, 0.84, 0.9, 0.95, a, "BACKGROUND", 4) end
    end
end
W._Ring = Ring

-- Rain rings and puddles, moonlight on the water, rings round someone wading. ctx: as Begin + period, pix(mx, my,
-- w, h, r, g, b, a, layer, sub) (map pixels), waders = { { mx, my }, ... } (sprite top-lefts)
function W.Life(ctx)
    if not W.On() then return end
    local m, t = ctx.m, ctx.calm and 0 or (ctx.now or 0)
    local v, pix = ctx.view, ctx.pix
    local tx0, ty0, tx1, ty1 = floor(v.x0 / 16), floor(v.y0 / 16), floor(v.x1 / 16), floor(v.y1 / 16)
    for _, wd in ipairs(ctx.waders or {}) do
        local ph = (t * 0.7) % 1
        Ring(pix, wd[1] + 8, wd[2] + 11, 4 + ph * 4, 0.5 * (1 - ph))
        Ring(pix, wd[1] + 8, wd[2] + 11, 4, 0.35)
    end
    if ctx.raining then
        -- rings on open water: a few at a time at hashed spots
        local n = 0
        for i = 0, 40 do
            if n >= 18 then break end
            local cyc = floor(t * 1.4 + i * 0.37)
            local x = tx0 + floor(H(cyc, i, 1) * (tx1 - tx0 + 1))
            local y = ty0 + floor(H(cyc, i, 2) * (ty1 - ty0 + 1))
            local k = m.key(x, y)
            if x >= 0 and y >= 0 and x < m.w and y < m.h and m.water[k] and not (m.shallow and m.shallow[k]) then
                n = n + 1
                local ph = (t * 1.4 + i * 0.37) % 1
                Ring(pix, x * 16 + 2 + floor(H(cyc, i, 3) * 12), y * 16 + 3 + floor(H(cyc, i, 4) * 10), 0.5 + ph * 5, 0.6 * (1 - ph))
            end
        end
        -- puddles on the roads, each with a ring now and then
        for y = max(0, ty0), min(m.h - 1, ty1) do
            local row = m.def.rows[y + 1]
            for x = max(0, tx0), min(m.w - 1, tx1) do
                if row:sub(x + 1, x + 1) == "=" and H(x, y, 4) < 0.45 then
                    local pxl, pyl, wd = x * 16 + 4 + floor(H(x, y, 5) * 8), y * 16 + 4 + floor(H(x, y, 6) * 8), 3 + floor(H(x, y, 7) * 4)
                    pix(pxl - wd, pyl, wd * 2, 2, 0.16, 0.2, 0.28, 0.34, "BACKGROUND", 4)
                    pix(pxl - wd + 1, pyl - 1, wd * 2 - 2, 1, 0.16, 0.2, 0.28, 0.34, "BACKGROUND", 4)
                    pix(pxl - wd + 1, pyl + 2, wd * 2 - 2, 1, 0.16, 0.2, 0.28, 0.34, "BACKGROUND", 4)
                    pix(pxl - wd + 2, pyl - 1, wd * 2 - 5, 1, 0.75, 0.81, 0.89, 0.28, "BACKGROUND", 4)
                    local ph = (t * 0.9 + H(x, y, 8)) % 1
                    Ring(pix, pxl + (H(x, y, 8) - 0.5) * wd, pyl + 0.5, ph * wd * 0.7, 0.55 * (1 - ph))
                end
            end
        end
    elseif ctx.period == "night" and F.e then
        -- the moon's glitter: a band across the water to the right of the middle of the view
        local cxm = (v.x0 + v.x1) / 2 + 40
        for i = 0, 59 do
            local y = floor(v.y0 + H(i, 5, 3) * (v.y1 - v.y0))
            local spread = 6 + (y - v.y0) / max(1, v.y1 - v.y0) * 16
            local x = round(cxm + (H(i, 6, 3) - 0.5) * 2 * spread + sin(y * 0.7 + t * 2) * 1.2)
            local k = m.key(floor(x / 16), floor(y / 16))
            if m.water[k] then
                local ph = (t * 0.8 + H(i, 7, 3)) % 1
                if ph < 0.55 then
                    local wide = ph > 0.15 and ph < 0.4
                    pix(x - (wide and 1 or 0), y, wide and 3 or 1, 1, 0.78, 0.84, 1, 0.55 * sin(ph / 0.55 * pi), "BACKGROUND", 4)
                end
            end
        end
    end
end

-- tests: what is on screen
function W.Stats()
    local n = function(list) local k = 0 for _, t in ipairs(list) do if t:IsShown() then k = k + 1 end end return k end
    return { on = F.e ~= nil, rows = n(rows), people = n(people), mask = mask and true or false }
end
