if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/Light.lua", ...) then return end -- DisasterZone_Azeromon/Light.lua
-- ns.AzeroLight: light on people in the overworld (Azeromon 0.44, the fidelity mockup's "light on characters").
--
-- Every person throws a shadow in their own shape and catches a rim of light on the side facing it:
--   by day        the sun's shadow, the same way and softness as the baked shadows of the props (down and right)
--   dusk / dawn   a long, faint sun shadow (to the east at dusk, the west at dawn) and a warm rim from the low sun
--   night         one shadow per lit lamp or lantern in reach, longer the further from it, and the lamp's rim
-- Nothing switches on or off between frames: a light's strength falls smoothly to nothing at the edge of its reach,
-- there is no "nearest two" cut, a light beside someone lays the shadow down toward us by a steady amount, and
-- every number eases toward its target over ~0.2 s (per person), so shadows turn and fade instead of jumping.
--
-- Drawing (art from gen_azeromon_art.py, LightArt.lua):
--   shadow   Media/chars_sil.tga: the person's silhouette with a soft edge, slanted into place with SetTexCoord's
--            eight numbers (one texture per light), black, fading toward the tip (a vertical gradient: the slant
--            keeps height on the vertical axis). Under the props (BORDER -1), like their baked shadows.
--   contact  a small soft oval under the feet (the old atlas blob and the blob in chars.tga are gone).
--   rim      the cell's edge pixels (LightArt edges), each lit by how squarely it faces the light: pooled one-pixel
--            squares, ADD, over the night's darkness (OVERLAY 6).
-- UI.lua calls Begin (the frame's lights), AddLight (lanterns), Person (each person), End.
local addonName, ns = ...

local L = {}
ns.AzeroLight = L

local floor, min, max, abs, sqrt, exp = math.floor, math.min, math.max, math.abs, math.sqrt, math.exp
local cos, sin, pi = math.cos, math.sin, math.pi

L.off = false                -- tests / a switch: draw nothing (the old blob comes back)
L.TAU = 0.2                  -- seconds for a person's light to settle on a new target
L.RIM_MAX = 700              -- rim pixels a frame, at most (the effects budget)

local MEDIA = "Interface\\AddOns\\DisasterZone_Azeromon\\Media\\"
L.SIL = MEDIA .. "chars_sil"
L.CLEAN = MEDIA .. "chars_clean"

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64I = {}
for i = 1, #B64 do B64I[B64:sub(i, i)] = i - 1 end
local DIRX, DIRY = {}, {}
for d = 0, 15 do DIRX[d] = cos(d * pi / 8) DIRY[d] = sin(d * pi / 8) end

local function Art() return ns.AzeroLightArt end

-- Lights and shadows are drawn: the art is on disk and the player has not switched them off.
function L.On()
    local art = Art()
    if L.off or not art or not ns:HasAssets(art.asset or 0) then return false end
    local G = ns.Azero
    return not (G and G.Data and G:Data().lights == false)
end

---------------------------------------------------------------------------
-- The light model (pure: tests call it directly)
---------------------------------------------------------------------------

-- The sun on someone outdoors: shadow slant (kx, ky per pixel of height), strength a; rim toward (rx, ry), rw, col.
L.SUN = {
    day = { kx = 0.7, ky = 0.34, a = 0.3, rx = -0.55, ry = -0.85, rw = 0.12, col = { 1, 0.98, 0.9 } },
    dusk = { kx = 1.2, ky = 0.36, a = 0.2, rx = -1, ry = -0.25, rw = 0.38, col = { 1, 0.66, 0.38 } },
    dawn = { kx = -1.2, ky = 0.36, a = 0.18, rx = 1, ry = -0.25, rw = 0.3, col = { 1, 0.75, 0.55 } },
}
local LAMP_COL, WINDOW_COL, LANTERN_COL = { 1, 0.82, 0.59 }, { 1, 0.77, 0.47 }, { 1, 0.81, 0.51 }

-- One light's target on a person whose feet are at (fx, fy) (map pixels): the light stands over (gx, gy), its glow
-- at (hx, hy); reach R; k its strength. nil when out of reach.
function L.Target(fx, fy, gx, gy, hx, hy, R, k, col, rimOnly)
    local vx, vy = fx - gx, fy - gy
    local d = sqrt(vx * vx + vy * vy)
    if d >= R then return nil end
    local w = (1 - d / R) ^ 1.2 * k                              -- smooth to zero at the edge of its reach
    local rx, ry = hx - fx, hy - (fy - 8)
    local rl = sqrt(rx * rx + ry * ry)
    if rl < 0.01 then rl = 1 end
    if rimOnly then
        return { kx = 0, ky = 0.3, a = 0, rx = rx / rl, ry = ry / rl, rw = 0.35 * w, col = col }
    end
    local ux, uy = 0, 1
    if d > 0.5 then ux, uy = vx / d, vy / d end
    local len = min(1.15, max(0.35, d / 14))                     -- longer further from the light
    return { kx = ux * len, ky = uy * len * 0.8 + 0.26 * (1 - abs(uy)), a = 0.56 * w,
             rx = rx / rl, ry = ry / rl, rw = 0.8 * w, col = col }
end

-- Ease a person's lights (state: key -> values) toward this frame's targets over L.TAU; lights gone fade out.
local EASE = { "kx", "ky", "a", "rx", "ry", "rw" }
function L.Ease(state, targets, dt)
    local e = (dt and dt > 0) and (1 - exp(-dt / L.TAU)) or 1
    for k, v in pairs(targets) do
        local c = state[k]
        if not c then
            c = { kx = v.kx, ky = v.ky, rx = v.rx, ry = v.ry, a = (e < 1) and 0 or v.a, rw = (e < 1) and 0 or v.rw }
            state[k] = c
            if e < 1 then c.a, c.rw = v.a * e, v.rw * e end
        else
            for _, p in ipairs(EASE) do c[p] = c[p] + (v[p] - c[p]) * e end
        end
        c.col = v.col
    end
    for k, c in pairs(state) do
        if not targets[k] then
            c.a, c.rw = c.a - c.a * e, c.rw - c.rw * e
            if c.a < 0.004 and c.rw < 0.004 then state[k] = nil end
        end
    end
    return state
end

---------------------------------------------------------------------------
-- A frame
---------------------------------------------------------------------------

local P = { shadow = {}, contact = {}, rim = {} }      -- texture pools
local used = { shadow = 0, contact = 0, rim = 0 }
local parent, S, setPixel
local frame = 0
local people = {}                                       -- key -> { t = now, seen = frame, lights = state }
local F = { lights = {}, live = {} }                    -- this frame's lights

function L.Attach(world, scale, setPixelTexture)
    parent, S, setPixel = world, scale, setPixelTexture
end

-- ctx: { m, g, now, period ("day" | "dusk" | "dawn" | "night"), raining, outdoor, dark (the light map is up),
--        toScreen(mapX, mapY) -> screen x, y (from the world's top-left, y down), viewX, viewY (map px, the view's
--        centre), reach (map px from the centre to the view's corner) }
function L.Begin(ctx)
    frame = frame + 1
    used.shadow, used.contact, used.rim = 0, 0, 0
    F.ctx = ctx
    F.on = L.On() and parent ~= nil
    F.sun = nil
    if ctx.outdoor and not ctx.raining and not (ctx.g and (ctx.g.indoor or ctx.g.cave)) then
        F.sun = L.SUN[ctx.period]
    end
    local lights, n = F.lights, 0
    local g, m = ctx.g, ctx.m
    if ctx.dark and g and g.lights then
        local Routine = ns.AzeroRoutine
        for i, l in ipairs(g.lights) do
            local lx, ly = l[1] - (g.mx or 0) * 16, l[2] - (g.my or 0) * 16
            local window = l[5] == 1
            local reach = window and max(24, (l[3] or 16) * 1.9) or (l[3] or 30) * 2.3
            local dx, dy = lx - (ctx.viewX or lx), ly - (ctx.viewY or ly)
            if dx * dx + dy * dy <= ((ctx.reach or 1e9) + reach) ^ 2 then
                local lamp = Routine and m and m.def and m.def.lamps and
                    Routine.LampAt(m.id, floor(l[1] / 16) - (g.mx or 0), floor(l[2] / 16) - (g.my or 0))
                if not (lamp and not Routine.LampLit(m.id, lamp)) then
                    n = n + 1
                    local e = lights[n] or {}
                    lights[n] = e
                    e.key, e.x, e.y, e.gx, e.gy, e.R = "l" .. i, lx, ly, lx, ly + (window and 6 or 11), reach
                    e.k, e.col, e.rimOnly, e.owner = 1, window and WINDOW_COL or LAMP_COL, window, nil
                end
            end
        end
    end
    F.n = n
    for i = #F.live, 1, -1 do F.live[i] = nil end
end

-- A light someone carries (a lantern): map pixels of its glass; it lights everyone but its owner.
function L.AddLight(owner, x, y)
    if not F.ctx or not F.ctx.dark then return end
    F.live[#F.live + 1] = { key = "v" .. tostring(owner), x = x, y = y, gx = x, gy = y + 6, R = 58, k = 0.9,
                            col = LANTERN_COL, owner = owner }
end

local function Pool(kind)
    used[kind] = used[kind] + 1
    local t = P[kind][used[kind]]
    if not t then
        if kind == "rim" then
            t = parent:CreateTexture(nil, "OVERLAY", nil, 6)
            pcall(t.SetBlendMode, t, "ADD")
        else
            t = parent:CreateTexture(nil, "BORDER", nil, -1)
            setPixel(t, L.SIL)
        end
        P[kind][used[kind]] = t
    end
    return t
end

local function Gradient(t, bottom, top)
    -- black, alpha from `bottom` (lower edge) to `top` (upper edge); a plain alpha when gradients are missing
    local ok = CreateColor and t.SetGradient and pcall(t.SetGradient, t, "VERTICAL",
        CreateColor(0, 0, 0, bottom), CreateColor(0, 0, 0, top))
    if not ok then t:SetVertexColor(0, 0, 0, (bottom + top) / 2) end
end

-- the silhouette of cell `c`, slanted: a point at height h over the feet moves (h * kx, h * ky); (sx, sy) = screen
-- position of the frame's top-left at ground level
local function DrawShadow(c, sx, sy, kx, ky, a)
    local art = Art()
    kx = max(-1.2, min(1.2, kx))
    if abs(ky) < 0.0625 then ky = (ky < 0) and -0.0625 or 0.0625 end
    local vf = 15.5
    local yA, yB = vf + vf * ky, vf - 0.5 * ky                  -- where the top (v = 0) and bottom (v = 16) rows land
    local ytop, ybot = min(yA, yB), max(yA, yB)
    local sA, sB = vf * kx, -0.5 * kx
    local xl, xr = min(sA, sB), 16 + max(sA, sB)
    local per = art.perRow
    local ox = (c % per) * art.cw + art.padx
    local oy = floor(c / per) * art.ch + art.pady
    local W, H = art.w, art.h
    local function tc(x, y)
        local v = vf - (y - vf) / ky
        local u = x - (vf - v) * kx
        return (ox + u) / W, (oy + v) / H
    end
    local ulx, uly = tc(xl, ytop)
    local llx, lly = tc(xl, ybot)
    local urx, ury = tc(xr, ytop)
    local lrx, lry = tc(xr, ybot)
    local t = Pool("shadow")
    t:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
    t:SetSize((xr - xl) * S, (ybot - ytop) * S)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", sx + xl * S, -(sy + ytop * S))
    if ky > 0 then Gradient(t, a * 0.45, a) else Gradient(t, a, a * 0.45) end
    t:Show()
end

local function DrawContact(sx, sy, a)
    local art = Art()
    local c = art.contact
    local t = Pool("contact")
    t:SetTexCoord(c[1] / art.w, (c[1] + c[3]) / art.w, c[2] / art.h, (c[2] + c[4]) / art.h)
    t:SetSize(c[3] * S, c[4] * S)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", sx + (8 - c[3] / 2) * S, -(sy + (15.5 - c[4] / 2) * S))
    t:SetVertexColor(0, 0, 0, a)
    t:Show()
end

local edgeCache = {}
local function Edges(c)
    local e = edgeCache[c]
    if e then return e end
    local s = Art().edges[c] or ""
    e = {}
    for i = 1, #s - 1, 2 do
        local v = B64I[s:sub(i, i)] + B64I[s:sub(i + 1, i + 1)] * 64
        e[#e + 1] = v % 16
        e[#e + 1] = floor(v / 16) % 16
        e[#e + 1] = floor(v / 256)
    end
    edgeCache[c] = e
    return e
end
L._Edges = Edges

local rimL = {}
local function DrawRim(c, sx, sy, lights, nl, legs, cut)
    local e = Edges(c)
    for i = 1, nl do
        local q = lights[i]
        local l = sqrt(q.rx * q.rx + q.ry * q.ry)
        if l < 0.01 then l = 1 end
        q.ux, q.uy = q.rx / l, q.ry / l
    end
    for i = 1, #e, 3 do
        local x, y, d = e[i], e[i + 1], e[i + 2]
        if not (legs and y >= 11) and not (cut and y >= cut) then
            local nx, ny = DIRX[d], DIRY[d]
            local r, g, b = 0, 0, 0
            for j = 1, nl do
                local q = lights[j]
                local f = nx * q.ux + ny * q.uy
                if f > 0.25 then
                    local k = ((f - 0.25) / 0.75) ^ 1.3 * q.rw
                    r, g, b = r + q.col[1] * k, g + q.col[2] * k, b + q.col[3] * k
                end
            end
            if r + g + b > 0.03 and used.rim < L.RIM_MAX then
                local t = Pool("rim")
                t:SetColorTexture(min(1, r), min(1, g), min(1, b), 1)
                t:SetSize(S, S)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", parent, "TOPLEFT", sx + x * S, -(sy + y * S))
                t:Show()
            end
        end
    end
end

-- A person this frame. c = their cell in the people sheet; (mx, my) = map pixels of the sprite's top-left at ground
-- level (fractional while walking); opt.lift = game pixels the sprite is drawn above the ground (a hop, an emote);
-- opt.legs = the legs are hidden (tall grass), so no rim on them; opt.cut = only the top cut rows show (wading);
-- opt.dry = 0..1, how much of the ground under them is dry land (shadows fade as they wade in).
function L.Person(key, c, mx, my, opt)
    if not F.on then return end
    local ctx = F.ctx
    local now = ctx.now or 0
    local p = people[key]
    if not p then p = { t = now, lights = {} } people[key] = p end
    local dt = min(0.25, max(0, now - p.t))
    p.t, p.seen = now, frame
    local fx, fy = mx + 8, my + 15
    local targets = {}
    if F.sun then targets.sun = F.sun end
    for i = 1, F.n do
        local l = F.lights[i]
        local tg = L.Target(fx, fy, l.gx, l.gy, l.x, l.y, l.R, l.k, l.col, l.rimOnly)
        if tg then targets[l.key] = tg end
    end
    for _, l in ipairs(F.live) do
        if l.owner ~= key then
            local tg = L.Target(fx, fy, l.gx, l.gy, l.x, l.y, l.R, l.k, l.col)
            if tg then targets[l.key] = tg end
        end
    end
    L.Ease(p.lights, targets, dt)
    local sx, sy = ctx.toScreen(mx, my)
    local dry = opt and opt.dry or 1
    if dry > 0.01 then DrawContact(sx, sy, ((F.sun == L.SUN.day) and 0.26 or 0.2) * dry) end
    local nl = 0
    for _, s in pairs(p.lights) do
        if s.a * dry > 0.01 then DrawShadow(c, sx, sy, s.kx, s.ky, s.a * dry) end
        if s.rw > 0.02 then nl = nl + 1 rimL[nl] = s end
    end
    if nl > 0 then DrawRim(c, sx, sy - (opt and opt.lift or 0) * S, rimL, nl, opt and opt.legs, opt and opt.cut) end
end

function L.End()
    for kind, pool in pairs(P) do
        for i = used[kind] + 1, #pool do pool[i]:Hide() end
    end
    for key, p in pairs(people) do
        if frame - (p.seen or 0) > 300 then people[key] = nil end
    end
end

-- Hide everything (the light is off, a battle covers the world).
function L.Clear()
    F.on = false
    used.shadow, used.contact, used.rim = 0, 0, 0
    for _, pool in pairs(P) do for _, t in ipairs(pool) do t:Hide() end end
end

-- tests: what is on screen, and a person's eased lights
function L.Stats()
    local shown = function(pool) local n = 0 for _, t in ipairs(pool) do if t:IsShown() then n = n + 1 end end return n end
    return { on = F.on or false, shadows = shown(P.shadow), contacts = shown(P.contact), rims = shown(P.rim),
             lights = F.n or 0, live = #F.live, sun = F.sun and true or false }
end
function L.State(key)
    local p = people[key]
    if not p then return nil end
    local out = {}
    for k, s in pairs(p.lights) do out[k] = { kx = s.kx, ky = s.ky, a = s.a, rw = s.rw } end
    return out
end
function L.Reset() people = {} edgeCache = {} end
