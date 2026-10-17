if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Taming.lua", ...) then return end -- DisasterZone Games/Azeromon/Taming.lua
-- ns.AzeroTaming: the taming moment (0.39). A Taming Rod's lure arcs over, a paw sigil opens under the wild beast and
-- light pulls it into a golden orb. One pip lights per check of B:Catch that holds. Tamed: the sigil locks with
-- sparkles and a TAMED! stamp, then a card shows the beast idling, where it went and whether it is new in your
-- Bestiary. Broken free: the orb cracks and the beast bursts back out.
-- Everything is drawn from plain colour blocks in game pixels (3 UI pixels each, like the battle's sprites) and the
-- glow textures the addon already has: no art of its own. UI.lua plays T.Anim for the battle's "throw" event and
-- shows T.Card after its "tamed" event.
local addonName, ns = ...

local T = {}
ns.AzeroTaming = T

local floor, max, min, sin, cos, sqrt, abs = math.floor, math.max, math.min, math.sin, math.cos, math.sqrt, math.abs
local pi, rad, tan, random = math.pi, math.rad, math.tan, math.random

local P = 3                                                        -- UI pixels per game pixel
local RADIAL = ns.MEDIA .. "MyBiS\\Radial"
local STAR = "Interface\\Cooldown\\star4"

-- the mockup's colours
local C = {
    gold = { 1, 0.843, 0.369 }, pale = { 1, 0.906, 0.627 }, orb = { 0.91, 0.698, 0.227 },
    shade = { 0.773, 0.541, 0.11 }, edge = { 0.478, 0.29, 0.07 }, shine = { 1, 0.949, 0.722 },
    crack = { 0.227, 0.133, 0.031 }, beam = { 1, 0.953, 0.769 }, stamp = { 0.788, 0.541, 0.102 },
    dark = { 0, 0, 0 }, white = { 1, 1, 1 }, dust = { 0.79, 0.76, 0.69 },
}

-- the timeline, in seconds
T.TIME = { lure = 0.62, open = 0.38, pull = 0.42, settle = 0.5, shake = 0.48, pip = 0.26, lock = 1.1, crack = 0.3,
           burst = 0.4 }
local ORB_UP = 10 * P                    -- the orb's centre above the beast's feet
local PIPS_UP = 22 * P                   -- the pips' centre above the feet: over the orb (below it, the
                                         -- player's HP box would cover them on the foe's platform)
local STAMP_UP = 40 * P                  -- TAMED!, over the pips

local fx                                 -- the pieces, made on first use (Build)

-- A block of game pixels, its bottom-left (x, y) game pixels from the centre of `f`.
local function Block(f, x, y, w, h, c, a, sub, list)
    local t = f:CreateTexture(nil, "ARTWORK", nil, sub or 0)
    t:SetColorTexture(c[1], c[2], c[3], a or 1)
    t:SetSize(w * P, h * P)
    t:SetPoint("BOTTOMLEFT", f, "CENTER", x * P, y * P)
    t.gx, t.gy = x, y
    if list then list[#list + 1] = t end
    return t
end

-- an ellipse's rows of game pixels (half sizes rx, ry): { y, half width }, bottom row first
local function Rows(rx, ry)
    local out = {}
    for y = -ry, ry - 1 do
        local yc = (y + 0.5) / ry
        out[#out + 1] = { y, floor(rx * sqrt(max(0, 1 - yc * yc)) + 0.5) }
    end
    return out
end

-- a filled ellipse centred (cx, cy) game pixels from f's centre
local function Disc(f, rx, ry, c, a, sub, list, cx, cy)
    for _, r in ipairs(Rows(rx, ry)) do
        if r[2] > 0 then Block(f, (cx or 0) - r[2], (cy or 0) + r[1], 2 * r[2], 1, c, a, sub, list) end
    end
end

-- an ellipse's outline, `th` game pixels thick
local function Ring(f, rx, ry, th, c, a, sub, list)
    local inner = {}
    for _, r in ipairs(Rows(rx - th, ry - th)) do inner[r[1]] = r[2] end
    for _, r in ipairs(Rows(rx, ry)) do
        local y, xo = r[1], r[2]
        local xi = inner[y] or 0
        if xo > 0 then
            if xi <= 0 then
                Block(f, -xo, y, 2 * xo, 1, c, a, sub, list)
            else
                Block(f, -xo, y, xo - xi, 1, c, a, sub, list)
                Block(f, xi, y, xo - xi, 1, c, a, sub, list)
            end
        end
    end
end

local function Glow(f, w, h, c, a)
    local g = f:CreateTexture(nil, "BACKGROUND")
    g:SetTexture(RADIAL)
    g:SetBlendMode("ADD")
    g:SetVertexColor(c[1], c[2], c[3])
    g:SetAlpha(a)
    g:SetSize(w, h)
    g:SetPoint("CENTER")
    return g
end

-- A piece: a frame on the battle layer at frame level `lvl` above it, moved, scaled and faded as a whole.
local function Piece(b, lvl, w, h)
    local f = CreateFrame("Frame", nil, b)
    f:SetSize(w, h)
    f:SetFrameLevel(b:GetFrameLevel() + lvl)
    f:Hide()
    return f
end

-- Puts piece f's centre at (x, y) UI pixels from the battle layer's top-left, at scale s (offsets are in the
-- piece's own, scaled units).
local function Place(f, x, y, s)
    s = max(0.01, s or 1)
    f:SetScale(s)
    f:ClearAllPoints()
    f:SetPoint("CENTER", fx.b, "TOPLEFT", x / s, y / s)
end

local function Build(b)
    if fx and fx.b == b then return end
    fx = { b = b, sparks = {} }
    -- the sigil lies on the ground, under the beast (models are 2 levels up): two rings and a paw
    local s = Piece(b, 1, 180, 60)
    -- (inside the platform's top, clear of its rim; gold with a shade below and right, lit from the top left like
    -- the world, so it reads on light grass)
    s.glow = Glow(s, 180, 50, C.gold, 0.3)
    Ring(s, 25, 7, 1, C.beam, 1, 1)
    Ring(s, 24, 6, 1, C.gold, 1, 1)
    Ring(s, 18, 5, 1, C.gold, 0.8, 1)
    Disc(s, 5, 2, C.shade, 1, 2, nil, 1, -3)
    Disc(s, 5, 2, C.gold, 1, 3, nil, 0, -2)
    for _, toe in ipairs({ { -9, 1 }, { -4, 2 }, { 2, 2 }, { 7, 1 } }) do
        Block(s, toe[1], toe[2] - 1, 3, 3, C.shade, 1, 2)
        Block(s, toe[1], toe[2], 2, 2, C.gold, 1, 3)
    end
    fx.sigil = s
    -- light rising from it: four columns, fading toward the top
    local beams = Piece(b, 3, 180, 200)
    beams.segs = {}
    for _, x in ipairs({ -27, -10, 7, 24 }) do
        for i = 1, 10 do
            local seg = Block(beams, x, -30 + (i - 1) * 6, 3, 6, C.beam, 0.38 - 0.032 * i, 0)
            seg.row = i
            beams.segs[#beams.segs + 1] = seg
        end
    end
    fx.beams = beams
    -- the rod's lure
    local lure = Piece(b, 4, 40, 40)
    Glow(lure, 54, 54, C.gold, 0.7)
    Block(lure, -4, -4, 8, 8, C.shade, 1, 0)
    Block(lure, -3, -3, 6, 6, C.gold, 1, 1)
    Block(lure, -2, 1, 2, 1, C.shine, 1, 2)
    fx.lure = lure
    -- the orb: outline, shade, gold, a shine; cracks for a beast that breaks free. Its blocks rock on its bottom.
    local orb = Piece(b, 4, 60, 60)
    orb.glow = Glow(orb, 90, 90, C.gold, 0.55)
    orb.blocks, orb.cracks = {}, {}
    Disc(orb, 6, 6, C.edge, 1, 0, orb.blocks)
    Disc(orb, 5, 5, C.shade, 1, 1, orb.blocks)
    Disc(orb, 4, 4, C.orb, 1, 2, orb.blocks, -1, 1)
    Block(orb, -3, 2, 2, 1, C.shine, 1, 3, orb.blocks)
    Block(orb, -4, 1, 1, 1, C.shine, 1, 3, orb.blocks)
    for _, c in ipairs({ { -2, 3 }, { -1, 2 }, { -1, 1 }, { 0, 0 }, { 1, -1 }, { 0, -2 }, { 1, 1 }, { 2, 2 }, { 3, 2 } }) do
        local cr = Block(orb, c[1], c[2], 1, 1, C.crack, 1, 4, orb.blocks)
        cr:Hide()
        orb.cracks[#orb.cracks + 1] = cr
    end
    fx.orb = orb
    -- one pip per check
    local pips = Piece(b, 4, 80, 20)
    pips.list = {}
    for i = 1, 3 do
        local x = -10 + (i - 1) * 7
        local pip = { edge = Block(pips, x, -2, 5, 5, C.white, 0.55, 0), core = Block(pips, x + 1, -1, 3, 3, C.dark, 0.45, 1) }
        pips.list[i] = pip
    end
    fx.pips = pips
    -- TAMED!
    local stamp = Piece(b, 5, 120, 40)
    Block(stamp, -19, -6, 38, 13, C.edge, 1, 0)
    Block(stamp, -18, -5, 36, 11, C.stamp, 1, 1)
    local K = ns.AzeroUI and ns.AzeroUI.Kit
    if K and K.Font then
        stamp.text = K.Font(stamp, 15, "OVERLAY", true)
        stamp.text:SetPoint("CENTER", 0, 0)
        stamp.text:SetJustifyH("CENTER")
        stamp.text:SetJustifyV("MIDDLE")
        stamp.text:SetTextColor(1, 1, 1)
        stamp.text:SetText("TAMED!")
    end
    fx.stamp = stamp
    -- sparkles: small blocks, or stars for a shiny
    local sl = CreateFrame("Frame", nil, b)
    sl:SetAllPoints(b)
    sl:SetFrameLevel(b:GetFrameLevel() + 4)
    fx.sparkLayer = sl
end

local function Spark(i)
    local sp = fx.sparks[i]
    if not sp then
        sp = { block = fx.sparkLayer:CreateTexture(nil, "OVERLAY"), star = fx.sparkLayer:CreateTexture(nil, "OVERLAY") }
        sp.star:SetTexture(STAR)
        sp.star:SetBlendMode("ADD")
        fx.sparks[i] = sp
    end
    return sp
end

-- Hides every piece (a new battle, the end of one).
function T.Reset()
    if not fx then return end
    for _, k in ipairs({ "sigil", "beams", "lure", "orb", "pips", "stamp" }) do fx[k]:Hide() end
    for _, cr in ipairs(fx.orb.cracks) do cr:Hide() end
    for _, sp in ipairs(fx.sparks) do sp.block:Hide() sp.star:Hide() end
    fx.burst = nil
end

-- the beast frame's feet: its bottom centre, lifted like its sprite, in UI pixels from the battle layer's top-left
local function Feet(m)
    return (m.baseX or 0) + (m.w or 0) / 2, (m.baseY or 0) + (m.spriteLift or 0)
end

-- A burst of n sparkles from (x, y), starting at time t0 of the timeline.
local function Burst(list, t0, x, y, n, c, stars)
    for i = 1, n do
        local ang = (i / n) * pi * 2 + random() * 0.4
        local r = (stars and 45 or 60) + random() * 70
        list[#list + 1] = { t0 = t0, dur = 0.7 + random() * 0.3, x = x, y = y, dx = cos(ang) * r, dy = sin(ang) * r,
                            c = c or ((i % 3 == 0) and C.white or C.pale), star = stars }
    end
end

local function DrawSparks(list, t)
    local n = 0
    for _, s in ipairs(list) do
        local p = (t - s.t0) / s.dur
        if p >= 0 and p < 1 then
            n = n + 1
            local sp = Spark(n)
            local e = 1 - (1 - p) ^ 3
            local tex, other = s.star and sp.star or sp.block, s.star and sp.block or sp.star
            other:Hide()
            local size = s.star and (22 * (1 - 0.6 * p)) or (6 * (1 - 0.6 * p))
            if s.star then tex:SetVertexColor(s.c[1], s.c[2], s.c[3]) else tex:SetColorTexture(s.c[1], s.c[2], s.c[3], 1) end
            tex:SetSize(size, size)
            tex:SetAlpha(1 - p)
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", fx.sparkLayer, "TOPLEFT", s.x + s.dx * e, s.y + s.dy * e)
            tex:Show()
        end
    end
    for i = n + 1, #fx.sparks do fx.sparks[i].block:Hide() fx.sparks[i].star:Hide() end
end

-- the orb's rocking: its blocks lean by `deg` degrees, pivoting on its bottom row
local function Lean(orb, deg)
    local k = tan(rad(deg))
    for _, t in ipairs(orb.blocks) do
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", orb, "CENTER", (t.gx + floor((t.gy + 6) * k + 0.5)) * P, t.gy * P)
    end
end

-- a shake's lean through its course q (0..1): 0 -> -22 -> 16 -> 0 degrees
local function ShakeLean(q)
    if q < 1 / 3 then return -22 * q * 3 end
    if q < 2 / 3 then return -22 + 38 * (q - 1 / 3) * 3 end
    return 16 * (1 - (q - 2 / 3) * 3)
end

-- The animation for the battle's "throw" event { shakes, caught, shiny }, as UI.lua's BT.anim { t, dur, fn, done }.
-- b: the battle layer; fm / am: the foe's / your beast frame (UI.lua's NewModel: .spr, .baseX, .baseY, .w, ...).
-- play(name): a sound effect; anim(m, id): a WoW animation id on a beast frame (54 = its special clip).
function T.Anim(e, b, fm, am, play, anim)
    Build(b)
    T.Reset()
    local TT = T.TIME
    local shakes, caught, shiny = min(3, e.shakes or 0), e.caught and true or false, e.shiny and true or false
    local spr = fm.spr and fm.spr.key and fm.spr or nil
    local fx0, fy0 = Feet(fm)
    local ax, ay = Feet(am)
    local _, sh = 0, 0
    if spr then _, sh = spr:Size() end
    local top = fy0 + min(sh > 0 and sh or 120, 150) * 0.55
    local tOpen = TT.lure
    local tPull = tOpen + TT.open
    local tPop = tPull + TT.pull
    local tShake = tPop + TT.settle
    local tEnd = tShake + shakes * (TT.shake + TT.pip)
    local total = tEnd + (caught and TT.lock or (TT.crack + TT.burst))
    local x0, y0 = ax + 40, ay + 120                       -- the lure leaves from above your beast
    local cx, cy = (x0 + fx0) / 2, (y0 + top) / 2 + 220    -- (the curve's pull: its top is 110 above the line)
    local sparks, fired = {}, {}
    local function Once(key, fn) if not fired[key] then fired[key] = true fn() end end
    T.quiet = nil
    play = play or function() end
    local orb, sig, beams, pips, stamp, lure = fx.orb, fx.sigil, fx.beams, fx.pips, fx.stamp, fx.lure
    local function fn(f)
        local t = f * total
        Once("throw", function() play("throw") end)
        -- 1. the lure arcs over
        if t < tOpen then
            local p = t / TT.lure
            local u = 1 - p
            Place(lure, u * u * x0 + 2 * u * p * cx + p * p * fx0, u * u * y0 + 2 * u * p * cy + p * p * top, 1)
            lure:Show()
        else
            lure:Hide()
        end
        -- 2. the sigil opens, light rises and the beast whitens; 3. it is drawn into the orb
        if t >= tOpen then
            Once("open", function()
                play("drain")
                Burst(sparks, tOpen, fx0, top, 8)
            end)
        end
        local sigEnd = caught and (tEnd + 0.6) or tEnd + TT.crack
        if t >= tOpen and t < sigEnd then
            local q = min(1, (t - tOpen) / 0.35)
            local s, a, glow = 0.3 + 0.7 * q, q, 0.35
            if caught and t >= tEnd then                   -- it locks: flares, then spreads out and fades
                local k = (t - tEnd) / 0.6
                if k < 0.4 then s, a, glow = 1 + 0.15 * k / 0.4, 1, 0.35 + 0.65 * k / 0.4
                else s, a, glow = 1.15 + 0.25 * (k - 0.4) / 0.6, 1 - (k - 0.4) / 0.6, 1 end
            elseif t >= tShake and t < tEnd then           -- it dims with each shake
                local k = ((t - tShake) % (TT.shake + TT.pip)) / TT.shake
                if k < 1 then a = 1 - 0.5 * sin(k * pi) end
            end
            sig.glow:SetAlpha(glow)
            sig:SetAlpha(a)
            Place(sig, fx0, fy0, s)
            sig:Show()
        else
            sig:Hide()
        end
        if t >= tOpen and t < tPop + 0.4 then
            local q = min(1, (t - tOpen) / 0.8)
            local rows = floor(10 * (0.3 + 0.7 * q) + 0.5)
            for _, seg in ipairs(beams.segs) do seg:SetShown(seg.row <= rows) end
            beams:SetAlpha(q * ((t > tPop) and max(0, 1 - (t - tPop) / 0.4) or 1))
            Place(beams, fx0, fy0 + 30 * P, 1)                -- (its columns start at the feet)
            beams:Show()
        else
            beams:Hide()
        end
        local burstAt = tEnd + TT.crack
        if t < tPop then
            fm:SetAlpha(1)
            if spr then
                if t < tOpen then spr:SetFx(1, 0)
                elseif t < tPull then spr:SetFx(1, 0.9 * (t - tOpen) / TT.open)
                else local q = (t - tPull) / TT.pull spr:SetFx(1 - 0.95 * q * q, 0.9) end
            elseif t >= tPull then
                fm:SetAlpha(max(0, 1 - (t - tPull) / TT.pull))
            end
        elseif caught or t < burstAt then
            fm:SetAlpha(0)
        else                                               -- 4b. it bursts back out
            Once("burst", function()
                fm:SetAlpha(1)
                Burst(sparks, burstAt, fx0, fy0 + ORB_UP, 12, C.dust)
                if anim then anim(fm, 54) end
            end)
            local q = (t - burstAt) / 0.36
            local s = (q < 0.6) and (0.2 + 0.92 * q / 0.6) or (1.12 - 0.12 * min(1, (q - 0.6) / 0.4))
            if spr then spr:SetFx(s, 0) end
        end
        -- the orb: it pops in, rocks once per check, then locks or cracks
        local orbEnd = caught and (tEnd + 0.6) or burstAt
        if t >= tPop and t < orbEnd then
            local q = min(1, (t - tPop) / 0.22)
            local s, a, dx, lean = 1.8 - 0.8 * q, 1, 0, 0
            if t >= tShake and t < tEnd then
                local k = ((t - tShake) % (TT.shake + TT.pip)) / TT.shake
                if k < 1 then lean = ShakeLean(k) end
            end
            local cracked = not caught and t >= tEnd
            for _, cr in ipairs(orb.cracks) do cr:SetShown(cracked) end
            if cracked then
                local k = (t - tEnd) / TT.crack
                dx = (k < 0.25) and (-4 * k / 0.25) or (k < 0.75) and (-4 + 8 * (k - 0.25) / 0.5) or (4 * (1 - (k - 0.75) / 0.25))
            end
            orb.glow:SetAlpha(0.55)
            orb.glow:SetSize(90, 90)
            if caught and t >= tEnd then
                local k = (t - tEnd) / 0.6
                if k < 0.3 then
                    orb.glow:SetAlpha(0.55 + 0.45 * k / 0.3)
                    orb.glow:SetSize(90 + 60 * k / 0.3, 90 + 60 * k / 0.3)
                else
                    s, a = 1 - 0.4 * (k - 0.3) / 0.7, 1 - (k - 0.3) / 0.7
                    orb.glow:SetAlpha(1)
                    orb.glow:SetSize(150, 150)
                end
            end
            Lean(orb, lean)
            orb:SetAlpha(a)
            Place(orb, fx0 + dx, fy0 + ORB_UP, s)
            orb:Show()
        else
            orb:Hide()
        end
        -- the pips: one per check that held
        local pipsEnd = caught and (tEnd + TT.lock) or burstAt
        if t >= tPop and t < pipsEnd then
            local lit = 0
            for k = 1, shakes do
                local sk = tShake + (k - 1) * (TT.shake + TT.pip)
                if t >= sk then Once("shake" .. k, function() play("shake") end) end
                if t >= sk + TT.shake then lit = k end
            end
            for i, pip in ipairs(pips.list) do
                local on = i <= lit
                local ec, cc = on and C.edge or C.white, on and C.gold or C.dark
                pip.edge:SetColorTexture(ec[1], ec[2], ec[3], on and 1 or 0.55)
                pip.core:SetColorTexture(cc[1], cc[2], cc[3], on and 1 or 0.45)
            end
            pips.lit = lit
            Place(pips, fx0, fy0 + PIPS_UP, 1)
            pips:Show()
        else
            pips:Hide()
        end
        -- 4a. it holds: sparkles, the stamp, the jingle
        if caught and t >= tEnd then
            Once("lock", function()
                Burst(sparks, tEnd, fx0, fy0 + ORB_UP, 22)
                if shiny then Burst(sparks, tEnd + 0.1, fx0, fy0 + ORB_UP, 12, C.gold, true) end
                T.quiet = true                             -- (the battle's own "catch" sound follows: this was it)
                play("catch")
                if shiny then play("shiny") end
            end)
            local q = min(1, (t - tEnd) / 0.2)
            Place(stamp, fx0, fy0 + STAMP_UP, 1.6 - 0.6 * q)
            stamp:Show()
        else
            stamp:Hide()
        end
        if not caught and t >= tEnd then Once("crack", function() play("breakfree") end) end
        DrawSparks(sparks, t)
    end
    return { t = 0, dur = total, fn = fn, done = function()
        T.Reset()
        if spr then spr:SetFx(1, 0) end
        fm:SetAlpha(caught and 0 or 1)
    end }
end

-- true once, right after a tame played its own jingle: the battle's "catch" sound that follows stays quiet
function T.TakeQuiet()
    local q = T.quiet
    T.quiet = nil
    return q and true or false
end

-- what is on screen (tests, the look renders)
function T.State()
    if not fx then return {} end
    local cracked = false
    for _, cr in ipairs(fx.orb.cracks) do if fx.orb:IsShown() and cr:IsShown() then cracked = true end end
    local sparks = 0
    for _, sp in ipairs(fx.sparks) do if sp.block:IsShown() or sp.star:IsShown() then sparks = sparks + 1 end end
    return { lure = fx.lure:IsShown(), sigil = fx.sigil:IsShown(), beams = fx.beams:IsShown(), orb = fx.orb:IsShown(),
             pips = fx.pips:IsShown() and (fx.pips.lit or 0) or nil, stamp = fx.stamp:IsShown(), cracked = cracked,
             sparks = sparks }
end

---------------------------------------------------------------------------
-- The odds
---------------------------------------------------------------------------

-- 0..1 as the odds read: 34%, <1%, 100%
function T.Percent(p)
    if p >= 0.995 then return "100%" end
    if p <= 0 then return "0%" end
    if p < 0.01 then return "<1%" end
    return floor(p * 100 + 0.5) .. "%"
end

-- The battle prompt's last line in a wild battle: the best rod in the bag and its odds this turn ("Taming Rod: 34%
-- to tame"), or nil (a trainer's beast, no rod).
function T.PromptLine(b, bag)
    if not (b and b.wild and b.TameOdds and bag) then return nil end
    local D = ns.AzeroData
    local best, bestP
    for _, id in ipairs(D.itemOrder) do
        local def = D.items[id]
        if def and def.use == "ball" and (bag[id] or 0) > 0 then
            local p = b:TameOdds(id)
            if not bestP or p > bestP then best, bestP = id, p end
        end
    end
    if not best then return nil end
    return string.format("%s: %s to tame", D.items[best].name, T.Percent(bestP))
end

---------------------------------------------------------------------------
-- The tamed card
---------------------------------------------------------------------------

-- The line under the card: what the catch means for your Bestiary.
function T.CardLine(info)
    local name = ns.AzeroData.species[info.sp].name
    if info.fresh then return string.format("%s was added to your Bestiary!", name) end
    return string.format("Take good care of %s!", name)
end

-- Shows the card for the battle's "tamed" event { sp, lvl, shiny, fresh, where }: the beast idling (its front),
-- its name and level, its type, NEW IN BESTIARY when it is, and where it went. nil hides it.
function T.Card(info)
    local K = ns.AzeroUI and ns.AzeroUI.Kit
    if not K then return end
    local c = T.card
    if not info then
        if c then
            c:Hide()
            K.ShowCreature(c.m, nil)
        end
        return
    end
    local D = ns.AzeroData
    if not c then
        local screen = K.Screen()
        c = K.Box(screen, 400, 156, screen:GetFrameLevel() + 40)          -- (over the battle, under the text box)
        c:SetPoint("BOTTOM", screen, "BOTTOM", 0, K.BOX_H + 82)
        -- a soft shadow under its feet (the beast frame below: 150 x 128 at 14, 14; the card's centre is 200, 78)
        Disc(c, 22, 3, C.dark, 0.14, 1, nil, -37, -21)
        c.m = K.NewModel(c, 150, 128)
        c.m:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 14, 14)
        c.m:SetFrameLevel(c:GetFrameLevel() + 2)
        c.head = K.Font(c, 13, nil, true)
        c.head:SetPoint("TOPLEFT", 180, -16)
        c.head:SetTextColor(0.64, 0.42, 0.05)
        c.head:SetText("TAMED!")
        c.star = c:CreateTexture(nil, "OVERLAY")              -- a shiny: the star its HP box wears
        c.star:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
        c.star:SetSize(22, 22)
        c.star:SetPoint("CENTER", c, "TOPRIGHT", -26, -24)
        c.name = K.Font(c, 16, nil, true)
        c.name:SetPoint("TOPLEFT", 180, -38)
        c.name:SetWidth(200)
        c.name:SetWordWrap(false)
        c.lvl = K.Font(c, 13)
        c.lvl:SetPoint("TOPLEFT", 180, -70)
        c.type = K.Pill(c, 76, 20, 14)
        c.type:SetPoint("TOPLEFT", 240, -67)
        c.new = K.Pill(c, 160, 20, 14)
        c.new:SetPoint("TOPLEFT", 180, -97)
        c.where = K.Font(c, 12)
        c.where:SetPoint("TOPLEFT", 180, -127)
        c.where:SetTextColor(0.36, 0.42, 0.55)
        T.card = c
    end
    local s = D.species[info.sp]
    c.name:SetText(s.name)
    c.lvl:SetText("Lv" .. (info.lvl or 1))
    c.type:Set(D.types[s.type].name:upper(), D.types[s.type].color)
    c.new:Set(info.fresh and "NEW IN BESTIARY" or nil, C.stamp)
    c.where:SetText(info.where == "box" and "Sent to the Stable Master" or "Joined your party")
    c.star:SetShown(info.shiny and true or false)
    c.info = info
    c:Show()
    K.ShowCreature(c.m, info.sp, -0.7, info.shiny)
    -- the battle is over: its HP boxes and cast bars make way for the card
    for _, k in ipairs({ "foeBox", "allyBox", "foeCast", "allyCast" }) do
        if K.R[k] then K.R[k]:Hide() end
    end
end

function T.CardState()
    local c = T.card
    if not (c and c:IsShown()) then return nil end
    return { name = c.name:GetText(), lvl = c.lvl:GetText(), type = c.type:IsShown() and c.type.fs:GetText() or nil,
             new = c.new:IsShown() and c.new.fs:GetText() or nil, where = c.where:GetText(), star = c.star:IsShown(),
             sprite = c.m.spr and c.m.spr:State() or nil }
end
