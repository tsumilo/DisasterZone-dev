if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Fx.lua", ...) then return end -- DisasterZone Games/Azeromon/Fx.lua
-- ns.AzeroFx: the battle effects (0.41). A move plays its own effect, drawn like the taming moment from plain colour
-- blocks in game pixels (the battle layer is 224 x 144 of them, 3 UI pixels each) plus the addon's Radial glow and
-- the game's star4 sparkle as added light. Every frame is drawn from scratch: each block is a texture taken from a
-- pool on three frames of the battle layer (under the beasts, the shade, over them) and hidden when not used again.
-- Each solid block over the beasts casts a 1-pixel shade down and right, so effects read on bright grass.
-- What stays between events is read from the battle's snapshot: marks on a beast, a guard's shell, a cast winding up.
-- UI.lua calls F.Frame every frame of a battle and plays F.Attack / F.Guard / F.Mark / F.Windup as BT.anim for the
-- events; the moves' recipes are FxMoves.lua. Designed in the dev kit's mockup (dev/art/casc/fx_mockup, fx.js).
local addonName, ns = ...

local F = {}
ns.AzeroFx = F

local floor, max, min, sin, cos, sqrt, abs = math.floor, math.max, math.min, math.sin, math.cos, math.sqrt, math.abs
local atan2, pi, random, tsort = math.atan2, math.pi, math.random, table.sort
local TAU = pi * 2

local P = 3                                                       -- UI pixels per game pixel
local RADIAL = "Interface\\AddOns\\" .. addonName .. "\\Media\\MyBiS\\Radial"
local STAR = "Interface\\Cooldown\\star4"
local SIDES = { "foe", "ally" }

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function lerp(a, b, t) return a + (b - a) * t end
local function eOut(t) return 1 - (1 - t) * (1 - t) end
local function eIn(t) return t * t end
local function rr(a, b) return a + random() * (b - a) end
local function bump(p) return sin(clamp(p, 0, 1) * pi) end
local function unit(x, y) local l = sqrt(x * x + y * y) if l == 0 then l = 1 end return x / l, y / l end
local function pick(list, q) return list[clamp(floor(q * #list) + 1, 1, #list)] end
F.clamp, F.lerp, F.eOut, F.eIn, F.rr, F.bump, F.unit, F.pick = clamp, lerp, eOut, eIn, rr, bump, unit, pick

---------------------------------------------------------------------------
-- Colours: "#rrggbb" -> { r, g, b }, one table per colour (a block tells an unchanged colour by the same table)
---------------------------------------------------------------------------

local hexes = {}
local function C(hex)
    local c = hexes[hex]
    if not c then
        c = { tonumber(hex:sub(2, 3), 16) / 255, tonumber(hex:sub(4, 5), 16) / 255, tonumber(hex:sub(6, 7), 16) / 255 }
        hexes[hex] = c
    end
    return c
end
F.C = C
local function Pal(t) local o = {} for k, v in pairs(t) do o[k] = C(v) end return o end
F.Pal = Pal
local function Ramp(t) local o = {} for i, v in ipairs(t) do o[i] = C(v) end return o end
F.Ramp = Ramp

-- o outline, d dark, m mid, l light, h highlight, w white-hot; lit from the top left like the world
local PAL = {
    BEAST  = Pal({ o = "#2b2117", d = "#5e4a33", m = "#94795a", l = "#c9b48c", h = "#ece0c2", w = "#fffaf0", glow = "#f2d29a" }),
    FIRE   = Pal({ o = "#3d0f06", d = "#8f2410", m = "#d9531a", l = "#f6902a", h = "#ffcf55", w = "#fff3c4", glow = "#ff7a26" }),
    WATER  = Pal({ o = "#0a1f45", d = "#17468f", m = "#3479cc", l = "#74b5ee", h = "#c4e8ff", w = "#ffffff", glow = "#4aa8ff" }),
    NATURE = Pal({ o = "#16300d", d = "#2d5e1a", m = "#4e9a2b", l = "#86cc45", h = "#c8ee85", w = "#f2ffd6", glow = "#7ee05a" }),
    SHADOW = Pal({ o = "#110720", d = "#2c1547", m = "#56308a", l = "#8b62c4", h = "#c6a6ee", w = "#efe4ff", glow = "#9a5cff" }),
    EARTH  = Pal({ o = "#26180b", d = "#4e341b", m = "#7d5a32", l = "#ad8750", h = "#d9bf88", w = "#f6e6bf", glow = "#e0b060" }),
    AIR    = Pal({ o = "#1b2750", d = "#3c5294", m = "#7290d2", l = "#b2c6f2", h = "#dde8ff", w = "#ffffff", glow = "#a8c4ff" }),
    MECH   = Pal({ o = "#1b1d23", d = "#41454f", m = "#737885", l = "#a9aeba", h = "#d9dce4", w = "#ffffff", glow = "#3fe0d0" }),
}
F.PAL = PAL
F.GOLD = Pal({ o = "#4a2f06", d = "#8c600e", m = "#d9a43c", l = "#f2c869", h = "#ffe7a3", w = "#fffaea" })
F.HEAL = Pal({ o = "#123a10", d = "#2c7a24", m = "#4fb53a", l = "#8fe066", h = "#d0ffb0", w = "#f4ffe8" })
F.VOLT = Pal({ o = "#0c4f4b", d = "#159088", m = "#43d9cc", l = "#9af2e8", h = "#c9fff8", w = "#ffffff" })
F.BONE = Pal({ o = "#3c3628", d = "#7c7460", m = "#b4ab90", h = "#e4dcc4", w = "#f8f2e0" })
F.BARK = Pal({ o = "#24160a", d = "#4a2f16", m = "#7a5028", l = "#a87a44", h = "#cfa266" })
F.STONE = Pal({ o = "#1e1e24", d = "#3e3e48", m = "#666671", l = "#9696a1", h = "#c8c8d0", w = "#e6e6ec" })
F.FLAME = Pal({ d = "#8f2410", m = "#d9531a", l = "#f6902a", h = "#ffcf55", w = "#fff3c4" })
F.FIRE_R = Ramp({ "#fff3c4", "#ffcf55", "#f6902a", "#d9531a", "#8f2410" })
F.SPARK = Ramp({ "#fff2b8", "#ffc24a", "#ec7a1a", "#9a3a0a" })
F.BLOOD = Ramp({ "#ef6a58", "#c93a2f", "#8e1f19", "#4a0e0b" })
F.SMOKE = Ramp({ "#857a74", "#5e5450", "#3e3634", "#24201f" })
F.DUST = Ramp({ "#e8dcbc", "#c8b48a", "#9c8660", "#6e5a3c" })
F.WHITE = C("#ffffff")
F.IRON = Pal({ o = "#15161a", d = "#2a2c34", m = "#4c505c", l = "#7d828f", h = "#c4c8d2", w = "#eef0f4" })
F.BLOOM = Pal({ d = "#2d5e1a", p = "#d9628f", P = "#ffb0cf", y = "#ffe08a", o = "#7a2448" })
local GOLD, HEAL, VOLT, BONE, BARK, STONE, FLAME = F.GOLD, F.HEAL, F.VOLT, F.BONE, F.BARK, F.STONE, F.FLAME
local IRON = F.IRON
local FIRE_R, BLOOD = F.FIRE_R, F.BLOOD
local SHADE = C("#0c1006")
-- a mark's colour (its pop, the blink as it lands)
F.MARKCOL = { bleed = C("#c9473e"), immolate = C("#e7762e"), corrupt = C("#8f5fc4"), chill = C("#5fb2e8"),
              rooted = C("#5c9c33"), exposed = C("#c99a2c"), charged = C("#2fb3aa"), regrowth = C("#4f9e3a") }

---------------------------------------------------------------------------
-- The frame's draw lists. Each draw call raises z, so later calls sit higher (the flush turns z into draw layers).
---------------------------------------------------------------------------

local LISTS = { under = { n = 0 }, over = { n = 0 } }
local GLOWS = { under = { n = 0 }, over = { n = 0 } }
local STARS = { n = 0 }
local Z = 0

local function push(list)
    local n = list.n + 1
    list.n = n
    local e = list[n]
    if not e then e = {} list[n] = e end
    return e
end
-- a block (x, y its top-left, game pixels from the battle layer's top-left); used by the shapes, which raise z once
local function Put(x, y, w, h, c, a, lay)
    if not c then return end
    a = a or 1
    if a <= 0.02 then return end
    local e = push(LISTS[lay or "over"])
    e.x, e.y = floor(x + 0.5), floor(y + 0.5)
    e.w, e.h = max(1, floor(w + 0.5)), max(1, floor(h + 0.5))
    e.c, e.a, e.z = c, min(1, a), Z
end
local function Rect(x, y, w, h, c, a, lay) Z = Z + 1 Put(x, y, w, h, c, a, lay) end
F.Rect = Rect
-- a soft light (look B): Radial, added; r in game pixels
local function Glow(x, y, r, c, a, lay)
    if not a or a <= 0.01 then return end
    local e = push(GLOWS[lay or "over"])
    e.x, e.y, e.r, e.c, e.a = x, y, r, c, a
end
F.Glow = Glow
-- a star4 sparkle, s UI pixels across
local function Star(x, y, s, c, a)
    if not a or a <= 0.01 or s <= 1 then return end
    local e = push(STARS)
    e.x, e.y, e.s, e.c, e.a = x, y, s, c or F.WHITE, a
end
F.Star = Star

-- A set of single pixels, merged into runs of one colour (one block each) when flushed. Reused: Flush empties it.
local PS = {}
PS.__index = PS
local psPool, psFree = {}, 0
local function NewPS()
    if psFree > 0 then local s = psPool[psFree] psPool[psFree] = nil psFree = psFree - 1 return s end
    return setmetatable({ rows = {}, ys = {} }, PS)
end
-- (rows[y] = { at = { [x] = colour }, xs = { x, ... }, n }; ys lists the rows in use)
function PS:Add(x, y, c)
    x, y = floor(x + 0.5), floor(y + 0.5)
    local row = self.rows[y]
    if not row then row = { at = {}, xs = {}, n = 0 } self.rows[y] = row end
    if row.n == 0 then self.ys[#self.ys + 1] = y end
    if row.at[x] == nil then row.n = row.n + 1 row.xs[row.n] = x end
    row.at[x] = c
end
local xs = {}
function PS:Flush(lay, a)
    Z = Z + 1
    for yi = 1, #self.ys do
        local y = self.ys[yi]
        local row = self.rows[y]
        local n, at = row.n, row.at
        for i = 1, n do xs[i] = row.xs[i] end
        for i = #xs, n + 1, -1 do xs[i] = nil end
        tsort(xs)
        local i = 1
        while i <= n do
            local x0 = xs[i]
            local c = at[x0]
            local j = i + 1
            while j <= n and xs[j] == xs[j - 1] + 1 and at[xs[j]] == c do j = j + 1 end
            Put(x0, y, xs[j - 1] - x0 + 1, 1, c, a, lay)
            i = j
        end
        for k = 1, n do at[row.xs[k]] = nil row.xs[k] = nil end
        row.n = 0
        self.ys[yi] = nil
    end
    psFree = psFree + 1
    psPool[psFree] = self
end
F.NewPS = NewPS

local function Line(ps, x0, y0, x1, y1, c)
    x0, y0, x1, y1 = floor(x0 + 0.5), floor(y0 + 0.5), floor(x1 + 0.5), floor(y1 + 0.5)
    local dx, dy = abs(x1 - x0), -abs(y1 - y0)
    local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
    local e = dx + dy
    for _ = 1, 500 do
        ps:Add(x0, y0, c)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * e
        if e2 >= dy then e = e + dy x0 = x0 + sx end
        if e2 <= dx then e = e + dx y0 = y0 + sy end
    end
end
F.Line = Line
local function Arc(ps, cx, cy, rx, ry, a0, a1, c)
    local n = max(4, floor(abs(a1 - a0) * max(rx, ry) * 1.3 + 0.99))
    for i = 0, n do
        local a = a0 + (a1 - a0) * i / n
        ps:Add(cx + cos(a) * rx, cy + sin(a) * ry, c)
    end
end
F.Arc = Arc

-- ellipses as rows of blocks (Taming.lua's Rows / Disc / Ring)
local rowsCache = {}
local function Rows(rx, ry)
    local key = rx * 1000 + ry
    local out = rowsCache[key]
    if out then return out end
    out = {}
    for y = -ry, ry - 1 do
        local yc = (y + 0.5) / ry
        out[#out + 1] = { y, floor(rx * sqrt(max(0, 1 - yc * yc)) + 0.5) }
    end
    rowsCache[key] = out
    return out
end
local function Disc(cx, cy, rx, ry, c, a, lay)
    Z = Z + 1
    cx, cy, rx, ry = floor(cx + 0.5), floor(cy + 0.5), floor(rx + 0.5), floor(ry + 0.5)
    if rx < 1 or ry < 1 then Put(cx, cy, 1, 1, c, a, lay) return end
    for _, r in ipairs(Rows(rx, ry)) do
        if r[2] > 0 then Put(cx - r[2], cy + r[1], 2 * r[2], 1, c, a, lay) end
    end
end
F.Disc = Disc
-- an ellipse's outline, th thick; half = "back" (the far, upper half) or "front"
local function Ring(cx, cy, rx, ry, th, c, a, lay, half)
    Z = Z + 1
    cx, cy, rx, ry = floor(cx + 0.5), floor(cy + 0.5), floor(rx + 0.5), floor(ry + 0.5)
    if rx < 1 or ry < 1 then return end
    local inner = (rx - th >= 1 and ry - th >= 1) and Rows(rx - th, ry - th) or nil
    local ir = {}
    if inner then for _, r in ipairs(inner) do ir[r[1]] = r[2] end end
    for _, r in ipairs(Rows(rx, ry)) do
        local y, xo = r[1], r[2]
        local xi = ir[y] or 0
        if xo > 0 and not (half == "back" and y >= 0) and not (half == "front" and y < 0) then
            if xi <= 0 then Put(cx - xo, cy + y, 2 * xo, 1, c, a, lay)
            else
                Put(cx - xo, cy + y, xo - xi, 1, c, a, lay)
                Put(cx + xi, cy + y, xo - xi, 1, c, a, lay)
            end
        end
    end
end
F.Ring = Ring

---------------------------------------------------------------------------
-- Glyphs: rows of palette letters ('.' is clear), one block per run of a letter. Generated ones carry colours.
---------------------------------------------------------------------------

local function Glyph(rows)
    local runs, w = {}, 0
    for y, r in ipairs(rows) do
        w = max(w, #r)
        local x = 1
        while x <= #r do
            local ch = r:sub(x, x)
            if ch == "." then x = x + 1
            else
                local x1 = x + 1
                while x1 <= #r and r:sub(x1, x1) == ch do x1 = x1 + 1 end
                runs[#runs + 1] = { x - 1, y - 1, x1 - x, ch }
                x = x1
            end
        end
    end
    return { runs = runs, w = w, h = #rows }
end
F.Glyph = Glyph
-- draws glyph g with its top-left at (x, y); pal maps its letters to colours (nil: the runs carry colours).
-- o: flip, vflip, a, lay, shadow (a colour drawn 1 pixel down-right first), solid (one colour for every run)
local function Stamp(g, x, y, pal, o)
    Z = Z + 1
    x, y = floor(x + 0.5), floor(y + 0.5)
    local flip, vflip, a, lay, solid = o and o.flip, o and o.vflip, o and o.a, o and o.lay, o and o.solid
    if o and o.shadow then
        for _, r in ipairs(g.runs) do
            Put(x + 1 + (flip and g.w - r[1] - r[3] or r[1]), y + 1 + (vflip and g.h - 1 - r[2] or r[2]), r[3], 1, o.shadow, (a or 1) * 0.6, lay)
        end
        Z = Z + 1
    end
    for _, r in ipairs(g.runs) do
        local c = solid or (pal and pal[r[4]] or r[4])
        if type(c) == "table" then
            Put(x + (flip and g.w - r[1] - r[3] or r[1]), y + (vflip and g.h - 1 - r[2] or r[2]), r[3], 1, c, a, lay)
        end
    end
end
F.Stamp = Stamp
local function StampC(g, cx, cy, pal, o) Stamp(g, floor(cx + 0.5) - floor(g.w / 2), floor(cy + 0.5) - floor(g.h / 2), pal, o) end
local function StampB(g, cx, by, pal, o) Stamp(g, floor(cx + 0.5) - floor(g.w / 2), floor(by + 0.5) - g.h + 1, pal, o) end
F.StampC, F.StampB = StampC, StampB

local GL = {}
F.GL = GL
GL.flame = { Glyph({ "..l..", "..ll.", ".lhl.", ".mhl.", "mlhwl", "mlwhm", "dmhmd", ".ddd." }),
             Glyph({ ".l...", ".ll..", ".lhl.", "mlhl.", "mlhhl", "mhwhm", "dmhmd", ".ddd." }),
             Glyph({ "...l.", "..ll.", ".lhl.", ".lhlm", "lhwlm", "mhwlm", "dmhmd", ".ddd." }) }
GL.flameS = { Glyph({ ".l.", ".l.", "lhl", "lhm", "dmd" }), Glyph({ "l..", ".l.", "lhl", "mhl", "dmd" }),
              Glyph({ "..l", ".l.", "lhl", "lhm", "dmd" }) }
GL.flameT = { Glyph({ "..l..", "..l..", ".lhl.", ".lhl.", ".mhl.", "mlhlm", "mlwhm", "mhwhm", "mhwlm", "dmhmd", "dmhmd", ".ddd." }),
              Glyph({ ".l...", ".ll..", ".lhl.", ".lhl.", "mlhl.", "mlhlm", "mhwlm", "mlwhm", "mhwhm", "dmhmd", "dmhmd", ".ddd." }),
              Glyph({ "...l.", "..ll.", ".lhl.", ".lhl.", ".lhlm", "mlhlm", "mlwhm", "mhwlm", "mhwhm", "dmhmd", "dmhmd", ".ddd." }) }
GL.fang = Glyph({ "mhw", "mhw", ".hw", ".h.", ".m." })
GL.boneH = Glyph({ "hh....hh", ".hhhhhh.", "mm....mm" })
GL.boneV = Glyph({ "h.m", "hhm", ".h.", ".h.", ".h.", ".h.", "hhm", "h.m" })
GL.runes = { Glyph({ "h.h", ".h.", "h.h" }), Glyph({ "hhh", "h..", "hhh" }), Glyph({ ".h.", "hhh", ".h." }), Glyph({ "hh.", ".h.", ".hh" }) }
GL.plus = Glyph({ ".w.", "www", ".w." })
GL.feather = Glyph({ ".hhhw", "mml.." })
GL.crystal = Glyph({ "..h..", ".hlm.", "hllmd", ".lmd.", "..d.." })
GL.crystalS = Glyph({ ".h.", "hld", ".d." })
GL.daze = Glyph({ ".y.", "yYy", ".y." })
GL.leaf = { Glyph({ ".lh", "lmd", "do." }), Glyph({ "hl.", "dml", ".od" }) }
GL.sprout = Glyph({ "l.l", ".m.", ".m.", ".d." })
GL.bud = Glyph({ ".p.", "pPp", ".d.", ".d." })
GL.bloom = Glyph({ "..pPp..", ".pPPPp.", "pPPyPPp", ".pPPPp.", "..pdp..", "...d..." })
GL.lock = Glyph({ ".ooo.", "o...o", "ooooo", "lhhll", "lhoml", "mmmmm" })
GL.up = Glyph({ "..h..", ".hlh.", "hl.lh" })
GL.down = Glyph({ "hl.lh", ".hlh.", "..h.." })
GL.fist = Glyph({ ".oooooo.", "odllllho", "odmmllhh", "odmmmlho", "odmmmmlo", ".oooooo." })
F.DAZE = Pal({ y = "#ffd84a", Y = "#fffbe0" })

-- generated sprites: a ball lit from the top left ("lit"), glowing from its core ("core"); a comet heading right;
-- a lumpy rock (k turns it: its outline shifts)
local gen = {}
local function key(...) return table.concat({ ... }, "|") end
local function runsFrom(pts, w, h)
    tsort(pts, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
    local runs = {}
    local i = 1
    while i <= #pts do
        local p = pts[i]
        local j = i + 1
        while j <= #pts and pts[j][2] == p[2] and pts[j][1] == pts[j - 1][1] + 1 and pts[j][3] == p[3] do j = j + 1 end
        runs[#runs + 1] = { p[1], p[2], j - i, p[3] }
        i = j
    end
    return { runs = runs, w = w, h = h }
end
local function Ball(r, ramp, mode)
    local k = key("b", r, tostring(ramp), mode)
    if gen[k] then return gen[k] end
    local D = 2 * r + 1
    local function inside(i, j) local dx, dy = i - r, j - r return dx * dx + dy * dy <= r * r + r * 0.6 end
    local pts = {}
    for j = 0, D - 1 do
        for i = 0, D - 1 do
            if inside(i, j) then
                local edge = not inside(i - 1, j) or not inside(i + 1, j) or not inside(i, j - 1) or not inside(i, j + 1)
                local nx, ny = (i - r) / (r + 0.5), (j - r) / (r + 0.5)
                local d = sqrt(nx * nx + ny * ny)
                local c
                if mode == "lit" then
                    local nz = sqrt(max(0, 1 - d * d))
                    local I = -0.55 * nx - 0.6 * ny + 0.58 * nz
                    c = edge and ramp[1] or I > 0.8 and ramp[5] or I > 0.45 and ramp[4] or I > 0.05 and ramp[3] or ramp[2]
                elseif mode == "void" then                 -- dark at its heart, a lit rim ({ o, d, m, h })
                    c = edge and ramp[4] or d > 0.72 and ramp[3] or d > 0.42 and ramp[2] or ramp[1]
                else
                    c = edge and ramp[1] or d < 0.35 and ramp[5] or d < 0.62 and ramp[4] or d < 0.85 and ramp[3] or ramp[2]
                end
                local s = r - floor(r * 0.45 + 0.5)
                if mode == "lit" and r >= 2 and ramp[6] and i == s and j == s then c = ramp[6] end
                pts[#pts + 1] = { i, j, c }
            end
        end
    end
    gen[k] = runsFrom(pts, D, D)
    return gen[k]
end
F.Ball = Ball
-- ramp = { dark, mid, light, high, white }; seed 0..2 picks one of its flicker frames
local function Comet(r, len, ramp, seed)
    local k = key("c", r, len, tostring(ramp), seed)
    if gen[k] then return gen[k] end
    local W, H, hx = len + 2 * r + 1, 2 * r + 1, len + r
    local function hash(x) local v = sin(x * 12.9898 + seed * 78.233) * 43758.5453 return v - floor(v) end
    local function inside(i, j)
        local dx, dy = i - hx, j - r
        if dx * dx + dy * dy <= r * r + r * 0.6 then return true end
        if i < hx and i >= 0 then
            local t = i / max(1, hx)
            local hh = r * (0.2 + 0.8 * t ^ 0.8) + hash(i) * 1.1 - 0.4
            return abs(dy) <= hh
        end
        return false
    end
    local pts = {}
    for j = 0, H - 1 do
        for i = 0, W - 1 do
            if inside(i, j) then
                local edge = not inside(i, j - 1) or not inside(i, j + 1) or not inside(i + 1, j)
                local dx, dy = i - hx, j - r
                local d = sqrt(dx * dx + dy * dy) / (r + 0.5)
                local c
                if i >= hx - r then c = edge and ramp[2] or d < 0.45 and ramp[5] or d < 0.75 and ramp[4] or ramp[3]
                else
                    local t = i / hx
                    c = edge and (t > 0.5 and ramp[2] or ramp[1]) or t > 0.65 and ramp[3] or t > 0.35 and ramp[2] or ramp[1]
                end
                pts[#pts + 1] = { i, j, c }
            end
        end
    end
    gen[k] = runsFrom(pts, W, H)
    return gen[k]
end
F.Comet = Comet
-- ramp = { o, d, m, l, h }
local function Rock(r, ramp, kk)
    local k = key("r", r, tostring(ramp), kk)
    if gen[k] then return gen[k] end
    local D, c0, s = 2 * r + 3, r + 1, kk * 1.7 + 0.4
    local function rad(a) return r * (1 + 0.16 * sin(3 * a + s) + 0.1 * sin(5 * a + 2 * s)) + 0.35 end
    local function inside(i, j) local dx, dy = i - c0, j - c0 return sqrt(dx * dx + dy * dy) <= rad(atan2(dy, dx)) end
    local pts = {}
    for j = 0, D - 1 do
        for i = 0, D - 1 do
            if inside(i, j) then
                local edge = not inside(i - 1, j) or not inside(i + 1, j) or not inside(i, j - 1) or not inside(i, j + 1)
                local nx, ny = (i - c0) / (r + 0.5), (j - c0) / (r + 0.5)
                local nz = sqrt(max(0, 1 - nx * nx - ny * ny))
                local I = -0.6 * nx - 0.62 * ny + 0.5 * nz
                pts[#pts + 1] = { i, j, edge and ramp[1] or I > 0.62 and ramp[4] or I > 0.2 and ramp[3] or ramp[2] }
            end
        end
    end
    gen[k] = runsFrom(pts, D, D)
    return gen[k]
end
F.Rock = Rock
-- a cog with `teeth` teeth (kk 0..2 turns it a third of a tooth); ramp = { o, d, m, l, h }
local function Gear(r, ramp, kk, teeth)
    local k = key("g", r, tostring(ramp), kk, teeth)
    if gen[k] then return gen[k] end
    local D, c0, ph = 2 * r + 3, r + 1, kk * TAU / teeth / 3
    local function inside(i, j)
        local dx, dy = i - c0, j - c0
        local d = sqrt(dx * dx + dy * dy)
        if d < max(1.1, r * 0.32) then return false end
        return d <= r - 0.6 or (d <= r + 1.2 and cos(teeth * (atan2(dy, dx) + ph)) > 0.25)
    end
    local pts = {}
    for j = 0, D - 1 do
        for i = 0, D - 1 do
            if inside(i, j) then
                local edge = not inside(i - 1, j) or not inside(i + 1, j) or not inside(i, j - 1) or not inside(i, j + 1)
                local I = (-0.7 * (i - c0) - 0.7 * (j - c0)) / (r + 1)
                pts[#pts + 1] = { i, j, edge and ramp[1] or I > 0.35 and ramp[4] or I > -0.2 and ramp[3] or ramp[2] }
            end
        end
    end
    gen[k] = runsFrom(pts, D, D)
    return gen[k]
end
F.Gear = Gear
-- a sawblade (kk 0..2 turns it); ramp = { o, d, m, l, h }: steel teeth, a darker ring, a dark hub
local function Saw(r, ramp, kk)
    local k = key("s", r, tostring(ramp), kk)
    if gen[k] then return gen[k] end
    local D, c0, ph = 2 * r + 3, r + 1, kk * TAU / 10 / 3
    local function inside(i, j)
        local dx, dy = i - c0, j - c0
        local f = ((atan2(dy, dx) + ph) * 10 / TAU) % 1
        return sqrt(dx * dx + dy * dy) <= r - 0.8 + 1.8 * (1 - f)
    end
    local pts = {}
    for j = 0, D - 1 do
        for i = 0, D - 1 do
            if inside(i, j) then
                local edge = not inside(i - 1, j) or not inside(i + 1, j) or not inside(i, j - 1) or not inside(i, j + 1)
                local dx, dy = i - c0, j - c0
                local d = sqrt(dx * dx + dy * dy)
                local I = (-0.7 * dx - 0.7 * dy) / (r + 1)
                local c = d < 1.2 and ramp[1] or edge and (I > 0 and ramp[5] or ramp[2]) or abs(d - r * 0.55) < 0.5 and ramp[2]
                          or I > 0.3 and ramp[4] or ramp[3]
                pts[#pts + 1] = { i, j, c }
            end
        end
    end
    gen[k] = runsFrom(pts, D, D)
    return gen[k]
end
F.Saw = Saw
local function DrawGen(g, cx, cy, o) Stamp(g, floor(cx + 0.5) - floor(g.w / 2), floor(cy + 0.5) - floor(g.h / 2), nil, o) end
F.DrawGen = DrawGen

---------------------------------------------------------------------------
-- The pools: textures on frames of the battle layer, placed from the draw lists at the end of a frame
---------------------------------------------------------------------------

local fx                                     -- { b, models, under, shade, over, pools, play, anim, scene, shakeOn }
local LAYERS = { "BACKGROUND", "BORDER", "ARTWORK", "OVERLAY" }

local function NewPool(frame, kind) return { f = frame, kind = kind, list = {}, used = 0, shown = 0 } end
local function Take(pool)
    local i = pool.used + 1
    pool.used = i
    local t = pool.list[i]
    if not t then
        t = pool.f:CreateTexture(nil, "ARTWORK")
        if pool.kind == "glow" or pool.kind == "star" then
            t:SetTexture(pool.kind == "glow" and RADIAL or STAR)
            t:SetBlendMode("ADD")
            t:SetDrawLayer("OVERLAY", pool.kind == "glow" and 6 or 7)
        end
        pool.list[i] = t
    end
    return t
end
local function EndPool(pool)
    for i = pool.used + 1, pool.shown do
        local t = pool.list[i]
        if t.on then t:Hide() t.on = false end
    end
    pool.shown = pool.used
    pool.used = 0
end
local function PlaceBlock(t, f, x, y, w, h, c, a, layer, sub)
    if t.x ~= x or t.y ~= y then t:ClearAllPoints() t:SetPoint("TOPLEFT", f, "TOPLEFT", x * P, -y * P) t.x, t.y = x, y end
    if t.w ~= w or t.h ~= h then t:SetSize(w * P, h * P) t.w, t.h = w, h end
    if t.c ~= c or t.a ~= a then t:SetColorTexture(c[1], c[2], c[3], a) t.c, t.a = c, a end
    if t.lay ~= layer or t.sub ~= sub then t:SetDrawLayer(layer, sub) t.lay, t.sub = layer, sub end
    if not t.on then t:Show() t.on = true end
end
local function FlushBlocks(list, pool, shade)
    local n = list.n
    local ranks, last = 0, nil
    for i = 1, n do local z = list[i].z if z ~= last then ranks = ranks + 1 last = z end end
    local r = 0
    last = nil
    for i = 1, n do
        local e = list[i]
        if e.z ~= last then r = r + 1 last = e.z end
        local slot = ranks <= 60 and (r - 1) or floor((r - 1) * 60 / ranks)
        PlaceBlock(Take(pool), pool.f, e.x, e.y, e.w, e.h, e.c, e.a, LAYERS[floor(slot / 16) + 1], slot % 16 - 8)
        if shade and e.a >= 0.9 then
            PlaceBlock(Take(shade), shade.f, e.x + 1, e.y + 1, e.w, e.h, SHADE, 0.42, "ARTWORK", 0)
        end
    end
    list.n = 0
end
local function FlushGlows(list, pool)
    for i = 1, list.n do
        local e = list[i]
        local t = Take(pool)
        local size = floor(e.r * 2 * P + 0.5)
        if t.w ~= size then t:SetSize(size, size) t.w = size end
        if t.x ~= e.x or t.y ~= e.y then t:ClearAllPoints() t:SetPoint("CENTER", pool.f, "TOPLEFT", e.x * P, -e.y * P) t.x, t.y = e.x, e.y end
        if t.c ~= e.c then t:SetVertexColor(e.c[1], e.c[2], e.c[3]) t.c = e.c end
        local a = e.a * 0.7                                -- added light washes out on bright grass: keep it soft
        if t.a ~= a then t:SetAlpha(a) t.a = a end
        if not t.on then t:Show() t.on = true end
    end
    list.n = 0
end
local function FlushStars(pool)
    for i = 1, STARS.n do
        local e = STARS[i]
        local t = Take(pool)
        local size = floor(e.s + 0.5)
        if t.w ~= size then t:SetSize(size, size) t.w = size end
        t:ClearAllPoints()
        t:SetPoint("CENTER", pool.f, "TOPLEFT", e.x * P + 1.5, -e.y * P - 1.5)
        if t.c ~= e.c then t:SetVertexColor(e.c[1], e.c[2], e.c[3]) t.c = e.c end
        if t.a ~= e.a then t:SetAlpha(e.a) t.a = e.a end
        if not t.on then t:Show() t.on = true end
    end
    STARS.n = 0
end

---------------------------------------------------------------------------
-- The beasts: where they stand (game pixels) and what the effects do to them this frame
---------------------------------------------------------------------------

local boxes = {}
-- the beast's idle frames' box around its feet (game pixels: l, r across, b, t up), or a rough one for a 3D model
local function BoxOf(m)
    local spr = m and m.spr
    if spr and spr.key and spr.clips and spr.clips.idle then
        local k = spr.key .. (spr.view or "f")
        local bx = boxes[k]
        if not bx then
            local l, r, b, t = 999, -999, 999, -999
            for _, f in ipairs(spr.clips.idle.frames) do
                l, r, b, t = min(l, f[5]), max(r, f[5] + f[3]), min(b, f[6]), max(t, f[6] + f[4])
            end
            if r < l then l, r, b, t = -20, 20, 0, 44 end
            bx = { l = l, r = r, b = b, t = t }
            boxes[k] = bx
        end
        return bx
    end
    return { l = -20, r = 20, b = 0, t = 44 }
end
local PT = {}
-- side's points: feet, c (the middle of its box), head, l, r, top, bot, w, h (game pixels, y down)
local function Pts(side)
    local p = PT[side]
    if p then return p end
    local m = fx.models[side]
    local fx0 = (m.baseX + m.w / 2) / P
    local fy0 = -(m.baseY + (m.spriteLift or 0)) / P
    local bx = BoxOf(m)
    local l, r, top, bot = fx0 + bx.l, fx0 + bx.r, fy0 - bx.t, fy0 - bx.b
    p = { side = side, feet = { fx0, fy0 }, c = { (l + r) / 2, (top + bot) / 2 }, head = { (l + r) / 2, top },
          l = l, r = r, top = top, bot = bot, w = r - l, h = bot - top }
    PT[side] = p
    return p
end
F.Pts = Pts

-- what the effects do to a beast this frame (set while drawing, applied after): offset, a coloured light over it,
-- a shade it is drawn in, up to two after-images
local BM = { foe = { ghosts = {} }, ally = { ghosts = {} } }
local function Beast(side) return BM[side] end
F.Beast = Beast
function F.Offset(side, dx, dy) local s = BM[side] s.dx = s.dx + floor(dx + 0.5) s.dy = s.dy + floor(dy + 0.5) end
function F.Light(side, c, a) local s = BM[side] if not s.la or a >= s.la then s.lc, s.la = c, a end end
function F.Shade(side, r, g, b) local s = BM[side] s.sr, s.sg, s.sb = r, g, b end
function F.Ghost(side, dx, dy, a, c)
    local s = BM[side]
    if #s.ghosts >= 2 then return end
    s.ghosts[#s.ghosts + 1] = { dx, dy, a, c }
end

local SX, SY = 0, 0                          -- the shake's offset this frame (game pixels)
local function ApplyBeasts()
    for _, side in ipairs(SIDES) do
        local m, s = fx.models[side], BM[side]
        local ox, oy = s.dx + SX, s.dy + SY
        if ox ~= (s.ax or 0) or oy ~= (s.ay or 0) then
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", fx.b, "TOPLEFT", m.baseX + ox * P, m.baseY - oy * P)
            s.ax, s.ay = ox, oy
        end
        local spr = m.spr
        if spr and spr.key then
            local la = s.la or 0
            if la ~= (s.appA or 0) or (la > 0 and s.lc ~= s.appC) then
                spr:SetFx(spr.shrink or 1, la, s.lc and s.lc[1], s.lc and s.lc[2], s.lc and s.lc[3])
                s.appA, s.appC = la, s.lc
            end
            if s.sr ~= s.appSr or s.sg ~= s.appSg or s.sb ~= s.appSb then
                spr:SetShade(s.sr, s.sg, s.sb)
                s.appSr, s.appSg, s.appSb = s.sr, s.sg, s.sb
            end
            for i = 1, 2 do
                local g = s.ghosts[i]
                if g then
                    local c = g[4] or F.WHITE
                    spr:SetGhost(i, (g[1] - ox) * P, -(g[2] - oy) * P, g[3], c[1], c[2], c[3])
                    s.appG = i
                elseif (s.appG or 0) >= i then
                    spr:SetGhost(i, 0, 0, 0)
                end
            end
            s.appG = #s.ghosts
        end
    end
end
local function ResetBeasts()
    for _, side in ipairs(SIDES) do
        local s = BM[side]
        s.dx, s.dy, s.lc, s.la, s.sr, s.sg, s.sb = 0, 0, nil, nil, nil, nil, nil
        for i = #s.ghosts, 1, -1 do s.ghosts[i] = nil end
    end
end

-- a WoW animation on a beast (16 attack, 54 special, 9 hit, 0 idle), through UI.lua's Anim
function F.Clip(side, id) if fx and fx.anim then fx.anim(fx.models[side], id) end end
function F.Sound(name, arg) if fx and fx.play then fx.play(name, arg) end end

---------------------------------------------------------------------------
-- Shake (the scene, never the boxes) and hit stop
---------------------------------------------------------------------------

local SHK = { amp = 0, t = 0, dur = 1, acc = 0, ox = 0, oy = 0 }
local freeze = 0
function F.Shake(amp, dur)
    local left = SHK.amp * max(0, 1 - SHK.t / SHK.dur)
    if amp >= left then SHK.amp, SHK.t, SHK.dur = amp, 0, dur or 0.2 end
end
function F.Hitstop(d) freeze = max(freeze, d) end
-- true while a hit stop holds the moment (UpdateBattle's BT.anim waits)
function F.Holding() return freeze > 0 end
local function StepShake(dt)
    SHK.t = SHK.t + dt
    local k = SHK.amp * max(0, 1 - SHK.t / SHK.dur)
    SHK.acc = SHK.acc + dt
    if SHK.acc > 1 / 30 then
        SHK.acc = 0
        if k > 0.3 and (not fx.shakeOn or fx.shakeOn()) then SHK.ox, SHK.oy = floor(rr(-k, k) + 0.5), floor(rr(-k * 0.6, k * 0.6) + 0.5)
        else SHK.ox, SHK.oy = 0, 0 end
    end
    if SHK.ox ~= SX or SHK.oy ~= SY then
        SX, SY = SHK.ox, SHK.oy
        for _, f in ipairs({ fx.under, fx.shade, fx.over }) do
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", fx.b, "TOPLEFT", SX * P, -SY * P)
            f:SetPoint("BOTTOMRIGHT", fx.b, "BOTTOMRIGHT", SX * P, -SY * P)
        end
        if fx.scene then fx.scene(SX * P, -SY * P) end
    end
end

---------------------------------------------------------------------------
-- Particles: they outlive the move that made them (smoke drifts on while the HP bar drains)
---------------------------------------------------------------------------

local PARTS, spare = {}, {}
local function Emit(o)
    o.age, o.vx, o.vy, o.seed = 0, o.vx or 0, o.vy or 0, random() * 10
    PARTS[#PARTS + 1] = o
    return o
end
F.Emit = Emit
-- n particles from (x, y): o = kind, cols, s = { min, max } speed, ang (centre), spread, ay, drag, life = { a, b },
-- ground, bounce, lay, pal, onLand, a, r0, r1, sway, jx, jy
local function Spray(x, y, n, o)
    for i = 1, n do
        local a = (o.ang or -pi / 2) + (o.spread or TAU) * ((i - 1 + random()) / n - 0.5)
        local sp = rr(o.s[1], o.s[2])
        Emit({ kind = o.kind, x = x + (o.jx and rr(-o.jx, o.jx) or 0), y = y + (o.jy and rr(-o.jy, o.jy) or 0),
               vx = cos(a) * sp, vy = sin(a) * sp, ay = o.ay or 0, drag = o.drag or 0, life = rr(o.life[1], o.life[2]),
               cols = o.cols, ground = o.ground, bounce = o.bounce, lay = o.lay, pal = o.pal, onLand = o.onLand, a = o.a,
               r0 = o.r0, r1 = o.r1, sway = o.sway })
    end
end
F.Spray = Spray
local function Splat(p) p.kind, p.age, p.life, p.lay = "splat", 0, 0.45, "under" end
F.Splat = Splat
-- a mote flying along a curve to (tx, ty) (life seconds; bend lifts the curve's middle)
local function Seek(x0, y0, tx, ty, life, cols, bend, lay, big)
    Emit({ kind = "seek", x = x0, y = y0, x0 = x0, y0 = y0, tx = tx, ty = ty, cx = (x0 + tx) / 2 + rr(-6, 6),
           cy = (y0 + ty) / 2 + (bend or -14), life = life, cols = cols, lay = lay, big = big })
end
F.Seek = Seek
local function StepParts(dt)
    local i = 1
    while i <= #PARTS do
        local p = PARTS[i]
        p.age = p.age + dt
        if p.age >= p.life then
            PARTS[i] = PARTS[#PARTS]
            PARTS[#PARTS] = nil
        else
            if p.kind ~= "seek" then
                if p.drag and p.drag > 0 then local k = max(0, 1 - p.drag * dt) p.vx, p.vy = p.vx * k, p.vy * k end
                p.vy = p.vy + (p.ay or 0) * dt
                p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
                if p.ground and p.y >= p.ground and p.vy > 0 then
                    p.y = p.ground
                    if p.bounce and p.vy > 30 then p.vy, p.vx = -p.vy * p.bounce, p.vx * 0.7
                    else
                        p.vy, p.vx, p.ay = 0, p.vx * 0.2, 0
                        if p.onLand then local f = p.onLand p.onLand = nil f(p) end
                    end
                end
            end
            i = i + 1
        end
    end
end
local function DrawPart(p)
    local q = p.age / p.life
    local lay, x, y, a = p.lay or "over", p.x, p.y, p.a or 1
    local k = p.kind
    Z = Z + 1
    if k == "px" then Put(x, y, p.size or 1, p.size or 1, pick(p.cols, q), a, lay)
    elseif k == "ember" then Put(x + (p.sway and sin(p.age * 9 + p.seed) * p.sway or 0), y, 1, 1, pick(p.cols, q), a, lay)
    elseif k == "spark" then
        Put(x, y, 1, 1, pick(p.cols, q), a, lay)
        local sp = sqrt(p.vx * p.vx + p.vy * p.vy)
        if sp > 40 and q < 0.7 then Put(x - p.vx / sp * 1.4, y - p.vy / sp * 1.4, 1, 1, pick(p.cols, q + 0.25), a, lay) end
    elseif k == "drop" then
        local fast = p.vy > 60
        Put(x, y, 1, fast and 2 or 1, p.cols[fast and 2 or 1], a, lay)
    elseif k == "splat" then
        Put(x - 1, y, 3, 1, p.cols[3], 1 - q, "under")
        Put(x, y, 1, 1, p.cols[4], 1 - q, "under")
    elseif k == "puff" then
        local r = lerp(p.r0 or 1, p.r1 or 3, eOut(q))
        local aa = a * (1 - q * q)
        Disc(x, y, r, r * 0.85, p.cols[3], aa, lay)
        Disc(x - 1, y - 1, max(1, r - 1), max(1, (r - 1) * 0.85), p.cols[2], aa, lay)
        if r > 2.5 then Disc(x - 1.5, y - 1.5, max(1, r - 2.5), max(1, (r - 2.5) * 0.85), p.cols[1], aa, lay) end
    elseif k == "shard" then
        if q < 0.8 then
            Put(x, y - 1, 1, 3, p.cols[2], a, lay) Put(x - 1, y, 3, 1, p.cols[2], a, lay) Put(x, y, 1, 1, p.cols[1], a, lay)
        else Put(x, y, 1, 1, p.cols[2], a, lay) end
    elseif k == "chunk" then
        Put(x, y, 3, 2, p.cols[2], a, lay) Put(x, y - 1, 2, 1, p.cols[3], a, lay) Put(x + 1, y + 1, 2, 1, p.cols[1], a, lay)
    elseif k == "leaf" or k == "petal" then
        local fl = sin(p.age * 11 + p.seed) > 0
        local xs = x + sin(p.age * 5 + p.seed) * (p.sway or 1.5)
        Put(xs, y, fl and 2 or 1, fl and 1 or 2, p.cols[1], a, lay)
        Put(xs + (fl and 1 or 0), y + (fl and 0 or 1), 1, 1, p.cols[2], a, lay)
    elseif k == "pebble" then
        Put(x, y, 2, 2, p.cols[2], a, lay) Put(x, y, 1, 1, p.cols[3], a, lay) Put(x + 1, y + 1, 1, 1, p.cols[1], a, lay)
    elseif k == "glint" then
        if q < 0.45 then
            Put(x, y - 1, 1, 3, p.cols[1], a, lay) Put(x - 1, y, 3, 1, p.cols[1], a, lay) Put(x, y, 1, 1, p.cols[2], a, lay)
        else Put(x, y, 1, 1, p.cols[2], a, lay) end
    elseif k == "flame" then
        if q < 0.7 then StampB(GL.flameS[floor(p.age * 14 + p.seed) % 3 + 1], x, y, p.pal, { lay = lay, a = a })
        else Put(x, y - 1, 1, 1, p.pal.l, a, lay) end
    elseif k == "mote" then
        Put(x, y, 1, 1, pick(p.cols, q), a, lay)
        if q < 0.6 then Put(x, y + 1, 1, 1, p.cols[#p.cols], a * 0.6, lay) end
    elseif k == "wisp" then
        Put(x + sin(p.age * 6 + p.seed) * 1.5, y, q < 0.4 and 2 or 1, 1, pick(p.cols, q), a, lay)
    elseif k == "feather" then
        Stamp(GL.feather, x + sin(p.age * 4 + p.seed) * 3, y, p.pal, { flip = sin(p.age * 6 + p.seed) > 0, a = a * (q > 0.75 and (1 - q) * 4 or 1), lay = lay })
    elseif k == "decal" then
        Disc(x, y, p.r0, max(1, p.r0 * 0.3), p.cols[1], (p.a or 0.5) * (1 - q), "under")
    elseif k == "ring" then
        local r = lerp(p.r0, p.r1, eOut(q))
        Ring(x, y, r, max(1, r * (p.flat or 1)), 1, pick(p.cols, q), a * (1 - q), lay)
    elseif k == "seek" then
        local e = eIn(q)
        local bx = lerp(lerp(p.x0, p.cx, e), lerp(p.cx, p.tx, e), e)
        local by = lerp(lerp(p.y0, p.cy, e), lerp(p.cy, p.ty, e), e)
        if p.big then
            Put(bx - 1, by, 3, 1, p.cols[1], a, lay) Put(bx, by - 1, 1, 3, p.cols[1], a, lay) Put(bx, by, 1, 1, p.cols[#p.cols], a, lay)
        else Put(bx, by, 1, 1, pick(p.cols, q), a, lay) end
    end
end

---------------------------------------------------------------------------
-- A run: one effect's timeline (At: once at t, Span: every frame in [t0, t1) with its progress and age)
---------------------------------------------------------------------------

local Run = {}
Run.__index = Run
local function NewRun(dur) return setmetatable({ t = 0, dur = dur or 0.6, ev = {} }, Run) end
F.NewRun = NewRun
function Run:At(t, fn) self.ev[#self.ev + 1] = { t0 = t, once = fn } end
function Run:Span(t0, t1, fn) self.ev[#self.ev + 1] = { t0 = t0, t1 = t1, fn = fn } end
function Run:Step(dt)
    self.t = self.t + dt
    local t = self.t
    for _, e in ipairs(self.ev) do
        if e.once then
            if not e.done and t >= e.t0 then e.done = true e.once() end
        elseif t >= e.t0 and t < e.t1 then
            e.fn((t - e.t0) / (e.t1 - e.t0), t - e.t0)
        end
    end
end

---------------------------------------------------------------------------
-- Shared pieces of the moves (FxMoves.lua)
---------------------------------------------------------------------------

-- the attacker steps toward the target and back (dist game pixels)
function F.Lunge(run, X, t0, dur, dist, side)
    side = side or X.a
    local ux, uy = unit(X.B.c[1] - X.A.c[1], X.B.c[2] - X.A.c[2])
    run:Span(t0, t0 + dur, function(p)
        local k = p < 0.35 and eOut(p / 0.35) or 1 - eIn((p - 0.35) / 0.65)
        F.Offset(side, ux * dist * k, uy * dist * k)
    end)
end
-- the target takes the hit: its hit clip, a soft blink, a knock back, the hit sound; a guard's shell flares instead
-- and a miss sidesteps. o: knock, flash (a colour), shake, shakeDur, stop (hit stop)
function F.React(run, X, t, o)
    o = o or {}
    if X.miss then
        run:Span(t - 0.12, t + 0.24, function(p) local k = bump(p) F.Offset(X.b, X.dir * 5 * k, -2 * k) end)
        return
    end
    run:At(t, function()
        if X.type and X.power > 0 then F.Sound("hit", X.type) end
        if X.guarded then F.GuardHit(X.b, X.hit, X) if o.shake then F.Shake(max(1, o.shake - 1), 0.12) end return end
        F.Clip(X.b, 9)
        if o.shake then F.Shake(o.shake, o.shakeDur or 0.2) end
        if o.stop and o.stop > 0 then F.Hitstop(o.stop) end
    end)
    if X.guarded then return end
    local kn = o.knock or 2
    run:Span(t, t + 0.16, function(p)
        F.Offset(X.b, X.dir * kn * (1 - p), 0)
        if p > 0.12 and p < 0.45 then F.Light(X.b, o.flash or F.WHITE, 0.3) end    -- (added light: softer than it reads)
    end)
end
-- a payoff with its mark up: a short hit stop, a gold ring and sparkles
function F.ComboFx(run, X, t)
    if not X.combo or X.miss then return end
    local pt = X.hit
    run:At(t, function()
        F.Hitstop(0.08)
        F.Shake(2, 0.24)
        Spray(pt[1], pt[2], 10, { kind = "glint", cols = { GOLD.l, GOLD.w }, s = { 45, 85 }, life = { 0.3, 0.55 }, drag = 5 })
    end)
    run:Span(t, t + 0.32, function(p)
        local r = 3 + 15 * eOut(p)
        Ring(pt[1], pt[2], r, r * 0.8, 1, p < 0.45 and GOLD.h or GOLD.m, 1 - p * 0.8)
        if p < 0.6 then
            Star(pt[1], pt[2], 46 * (1 - p), GOLD.h, 1 - p / 0.6)
            Glow(pt[1], pt[2], 26, C("#ffcc55"), 0.7 * (1 - p))
        end
    end)
end
-- a blast: a disc that swells through the ramp (dark rim, hot core), holds a beat, then breaks into smoke and sparks
function F.Explode(run, t, pt, r, ramp, o)
    o = o or {}
    run:Span(t, t + 0.3, function(p)
        local k = p < 0.35 and eOut(p / 0.35) or 1
        local r0 = max(1, r * k * (p > 0.6 and 1 - (p - 0.6) * 1.6 or 1))
        Disc(pt[1], pt[2], r0, r0 * 0.86, ramp[5])
        Disc(pt[1] - 1, pt[2] - 1, r0 - 1, (r0 - 1) * 0.86, ramp[4])
        if r0 > 3 then Disc(pt[1] - 1, pt[2] - 1, r0 - 2.5, (r0 - 2.5) * 0.86, ramp[3]) end
        if r0 > 4 and p < 0.8 then Disc(pt[1] - 1.5, pt[2] - 1.5, r0 - 4, (r0 - 4) * 0.86, ramp[2]) end
        if r0 > 5.5 and p < 0.6 then Disc(pt[1] - 1.5, pt[2] - 1.5, r0 - 5.5, (r0 - 5.5) * 0.86, ramp[1]) end
        Glow(pt[1], pt[2], r * 2.2, o.glow or ramp[3], 0.5 * (1 - p))
    end)
    run:At(t + 0.2, function()
        if o.smoke ~= false then
            Spray(pt[1], pt[2], o.puffs or max(2, floor(r / 2)), { kind = "puff", cols = o.smokeCols or F.SMOKE, s = { 8, 22 }, ang = -pi / 2,
                  spread = pi * 1.6, ay = -10, drag = 2, life = { 0.5, 0.9 }, r0 = 1.5, r1 = max(2, r * 0.45), a = 0.85 })
        end
        Spray(pt[1], pt[2], o.sparks or floor(r * 1.4), { kind = "ember", cols = o.sparkCols or { ramp[1], ramp[2], ramp[3], ramp[4] },
              s = { 30, 80 }, ay = 60, drag = 2.5, life = { 0.3, 0.6 } })
    end)
end
-- something in flight from `from` to `to`; arc lifts its middle; shadow (a radius) puts its shadow on the ground.
-- o.draw(x, y, q, vx, vy), o.trail(x, y, q, vx, vy), o.hit(to)
function F.Fly(run, X, o)
    local from, to, arcH = o.from or X.muzzle, o.to or X.hit, o.arc or 0
    run:Span(o.t0, o.t0 + o.dur, function(p)
        local q = o.ease and o.ease(p) or p
        local x = lerp(from[1], to[1], q)
        local y = lerp(from[2], to[2], q) - arcH * 4 * q * (1 - q)
        local vx, vy = to[1] - from[1], (to[2] - from[2]) - arcH * 4 * (1 - 2 * q)
        if o.shadow then
            local gx, gy = lerp(X.A.feet[1], X.ground[1], q), lerp(X.A.feet[2], X.ground[2], q)
            local s = clamp(1 - (gy - y) / 70, 0.4, 1)
            Disc(gx, gy, max(1, o.shadow * s), max(1, o.shadow * s * 0.32), C("#0b0d06"), 0.32, "under")
        end
        o.draw(x, y, q, vx, vy)
        if o.trail then o.trail(x, y, q, vx, vy) end
    end)
    if o.hit then run:At(o.t0 + o.dur, function() o.hit(to) end) end
end
-- n strokes across pt that wipe in, hold and wipe out from their tails; cols = { edge, rim, core }
function F.Slashes(run, X, o)
    local pt, n, len, gap, th, cols = o.at or X.hit, o.n or 3, o.len or 14, o.gap or 4, o.th or 2, o.cols
    local ang = o.ang or (X.dir > 0 and 1.9 or pi - 1.9)
    local dx, dy = cos(ang), sin(ang)
    local nx, ny = -dy, dx
    local shx, shy
    if nx + ny > 0 then shx, shy = (nx > 0 and 1 or nx < 0 and -1 or 0), (ny > 0 and 1 or ny < 0 and -1 or 0)
    else shx, shy = (nx > 0 and -1 or nx < 0 and 1 or 0), (ny > 0 and -1 or ny < 0 and 1 or 0) end
    local stagger, wipe, hold, out = o.stagger or 0.035, o.wipe or 0.07, o.hold or 0.06, o.out or 0.1
    local bend = o.bend or 2.5
    for i = 1, n do
        local off = (i - 1 - (n - 1) / 2) * gap
        local ti = o.t0 + (i - 1) * stagger
        local L = len * (1 - abs(i - 1 - (n - 1) / 2) * (o.taper or 0.12))
        local cx, cy = pt[1] + nx * off, pt[2] + ny * off
        run:Span(ti, ti + wipe + hold + out, function(_, lt)
            local head, tail = clamp(lt / wipe, 0, 1), clamp((lt - wipe - hold) / out, 0, 1)
            local ps = NewPS()
            local N = floor(L * 1.8 + 0.99)
            for pass = 1, 3 do
                for k = 0, N do
                    local s = k / N
                    if s <= head and s >= tail then
                        local u = s - 0.5
                        local bow = bend * (1 - 4 * u * u)
                        local x, y = cx + dx * u * L + nx * bow, cy + dy * u * L + ny * bow
                        local w = th * sin(s * pi)
                        if pass == 1 and w > 1.6 then ps:Add(x + 2 * shx, y + 2 * shy, cols[1]) end
                        if pass == 2 and w > 0.7 then ps:Add(x + shx, y + shy, w > 1.6 and cols[2] or cols[1]) end
                        if pass == 3 then ps:Add(x, y, cols[3]) end
                    end
                end
            end
            ps:Flush("over")
        end)
    end
end
-- jaws that snap shut on pt: a row of fangs above, one below, a gum line behind each. o.pal = { m, h, w }
function F.Jaws(run, X, o)
    local pt = o.at or X.hit
    local W, n = o.w or clamp(floor(X.B.w * 0.55 + 0.5), 10, 20), o.n or 4
    local tc, th, tout, pal = o.close or 0.12, o.hold or 0.14, o.out or 0.1, o.pal
    local snapPal = { m = pal.h, h = pal.w, w = pal.w }
    run:Span(o.t0, o.t0 + tc + th + tout, function(_, lt)
        local gap = floor(lerp(12, 0, eIn(clamp(lt / tc, 0, 1))) + 0.5)
        local fade = clamp((lt - tc - th) / tout, 0, 1)
        if fade > 0 then gap = floor(lerp(0, 4, fade) + 0.5) end
        local a, x0, y, sp = 1 - fade, floor(pt[1] - W / 2 + 0.5), floor(pt[2] + 0.5), W / n
        local fp = (lt >= tc and lt < tc + 0.05) and snapPal or pal
        Rect(x0 + 1, y - gap - 7, W - 2, 1, o.gumD, a) Rect(x0, y - gap - 6, W, 1, o.gum, a)
        Rect(x0, y + gap + 5, W, 1, o.gum, a) Rect(x0 + 1, y + gap + 6, W - 2, 1, o.gumD, a)
        for i = 0, n - 1 do Stamp(GL.fang, x0 + floor(i * sp + (sp - 3) / 2 + 0.5), y - gap - 5, fp, { a = a }) end
        for j = 0, n - 2 do Stamp(GL.fang, x0 + floor((j + 0.5) * sp + (sp - 3) / 2 + 0.5), y + gap, fp, { a = a, vflip = true }) end
    end)
end
-- a burst of pixel rays (a bonk); cols = { short rays, long rays }
function F.Bonk(run, t, pt, cols, size)
    run:Span(t, t + 0.16, function(p)
        local ps = NewPS()
        local r0 = 2 + 3 * p
        local r1 = r0 + (size or 5) * (1 - p)
        for i = 0, 7 do
            local a = i * pi / 4
            local L = (i % 2 == 1) and r1 * 0.6 or r1
            Line(ps, pt[1] + cos(a) * r0, pt[2] + sin(a) * r0, pt[1] + cos(a) * L, pt[2] + sin(a) * L, i % 2 == 1 and cols[1] or cols[2])
        end
        ps:Flush("over")
        Star(pt[1], pt[2], 34 * (1 - p), cols[2], 1 - p)
    end)
end
-- three small stars circling a dazed head
function F.Daze(run, side, t0, dur)
    run:Span(t0, t0 + dur, function(p, lt)
        local hp = Pts(side).head
        for i = 0, 2 do
            local a = lt * 7 + i * TAU / 3
            StampC(GL.daze, hp[1] + cos(a) * 8, hp[2] - 2 + sin(a) * 2, F.DAZE,
                   { shadow = C("#3a2a08"), lay = sin(a) < 0 and "under" or "over", a = p > 0.8 and (1 - p) * 5 or 1 })
        end
    end)
end
-- four gold corners around a beast (a hunter's lock), e pixels out from its box
local function Brackets(P_, e, pal, a)
    local l, r, t, b = floor(P_.l - e + 0.5), floor(P_.r + e + 0.5), floor(P_.top - e + 0.5), floor(P_.bot + e - 2 + 0.5)
    local k = 4
    for _, cn in ipairs({ { l, t, 1, 1 }, { r, t, -1, 1 }, { l, b, 1, -1 }, { r, b, -1, -1 } }) do
        for pass = 1, 2 do
            local o = pass == 2 and 0 or 1
            local col = pass == 2 and pal.h or pal.o
            Rect(cn[3] > 0 and cn[1] + o or cn[1] - k + 1 + o, cn[2] + o, k, 1, col, pass == 2 and a or a * 0.8)
            Rect(cn[1] + o, cn[4] > 0 and cn[2] + o or cn[2] - k + 1 + o, 1, k, col, pass == 2 and a or a * 0.8)
        end
        Rect(cn[1], cn[2], 1, 1, pal.w, a)
    end
end
F.Brackets = Brackets
-- a zigzag bolt from (x0, y0) to (x1, y1); cols = { outer, core }
local function Zigzag(ps, x0, y0, x1, y1, segs, amp, cols)
    local dx, dy = x1 - x0, y1 - y0
    local L = sqrt(dx * dx + dy * dy)
    if L == 0 then L = 1 end
    local nx, ny = -dy / L, dx / L
    local path = { { x0, y0 } }
    for i = 1, segs do
        local f = i / segs
        local j = (i == segs) and 0 or rr(-amp, amp)
        path[#path + 1] = { x0 + dx * f + nx * j, y0 + dy * f + ny * j }
    end
    for k = 2, #path do
        Line(ps, path[k - 1][1] + 1, path[k - 1][2], path[k][1] + 1, path[k][2], cols[1])
        Line(ps, path[k - 1][1], path[k - 1][2] + 1, path[k][1], path[k][2] + 1, cols[1])
    end
    for k = 2, #path do Line(ps, path[k - 1][1], path[k - 1][2], path[k][1], path[k][2], cols[2]) end
end
F.Zigzag = Zigzag
-- a jagged line on the ground (cracks, a fissure): points from (x0, y0) to (x1, y1) every `step`, jittered sideways
function F.CrackPath(x0, y0, x1, y1, step, jit)
    local out = {}
    local dx, dy = x1 - x0, y1 - y0
    local L = sqrt(dx * dx + dy * dy)
    if L == 0 then L = 1 end
    local n = max(2, floor(L / step + 0.5))
    local nx, ny = -dy / L, dx / L
    for i = 0, n do
        local f = i / n
        local j = (i == 0 or i == n) and 0 or rr(-jit, jit)
        out[#out + 1] = { x0 + dx * f + nx * j, y0 + dy * f + ny * j }
    end
    return out
end
-- draws a path as far as `upto` (0..1) of its length, shifted ox, oy
function F.DrawPath(ps, path, upto, c, ox, oy)
    ox, oy = ox or 0, oy or 0
    local n = (#path - 1) * clamp(upto, 0, 1)
    local k = floor(n)
    for i = 1, k do Line(ps, path[i][1] + ox, path[i][2] + oy, path[i + 1][1] + ox, path[i + 1][2] + oy, c) end
    if k < #path - 1 and n > k then
        local f, a, b = n - k, path[k + 1], path[k + 2]
        Line(ps, a[1] + ox, a[2] + oy, lerp(a[1], b[1], f) + ox, lerp(a[2], b[2], f) + oy, c)
    end
end
-- a stone spike pushing out of the ground: base (x, y), W wide and H tall in full, shown up to `rise` (0..1)
function F.Spike(x, y, W, H, rise, pal)
    Z = Z + 1
    local vis = floor(H * clamp(rise, 0, 1) + 0.5)
    for r = 0, vis - 1 do
        local hw = max(0, floor((r + (H - vis) + 1) * W / (2 * H) + 0.5))
        local yy = y - vis + r
        if hw <= 0 then Put(x, yy, 1, 1, pal.h)
        else
            Put(x - hw, yy, hw, 1, pal.l) Put(x, yy, hw, 1, pal.d)
            Put(x - hw - 1, yy, 1, 1, pal.o) Put(x + hw, yy, 1, 1, pal.o)
            if r == 0 then Put(x - 1, yy, 1, 1, pal.h) end
        end
    end
end
-- a vine growing up from (x0, y0) to length len, curling; cols = { shade, stem, tip, leaf, leaf shade }
function F.Vine(ps, x0, y0, len, phase, curl, cols)
    local s = 0
    while s <= len do
        local x, y = x0 + sin(s * 0.42 + phase) * curl, y0 - s
        ps:Add(x + 1, y, cols[1])
        ps:Add(x, y, s > len - 1.5 and cols[3] or cols[2])
        s = s + 0.5
    end
    local k = 4
    while k < len - 1 do
        local xs = x0 + sin(k * 0.42 + phase) * curl
        local sd = (floor(k / 5) % 2 == 1) and 1 or -1
        ps:Add(xs + sd, y0 - k, cols[4]) ps:Add(xs + 2 * sd, y0 - k - 1, cols[4]) ps:Add(xs + 2 * sd, y0 - k, cols[5])
        k = k + 5
    end
end
-- the sound of a screech or a shout: a ")" arc facing right (facing > 0) or "(" facing left
function F.SoundArc(ps, x, y, r, facing, c)
    if facing > 0 then Arc(ps, x, y, r * 0.55, r, -0.95, 0.95, c)
    else Arc(ps, x, y, r * 0.55, r, pi - 0.95, pi + 0.95, c) end
end

---------------------------------------------------------------------------
-- Guards: each type's shell round the beast (k: how far it has formed, 0..1; fl: it flares when hit; tw: its age)
---------------------------------------------------------------------------

local function ShellGeo(side)
    local p = Pts(side)
    return p.c[1], p.c[2] + 1, floor(p.w * 0.5 + 5.5), floor(p.h * 0.5 + 4.5)
end
local function ShellEdge(side, from)
    local cx, cy, rx, ry = ShellGeo(side)
    local ux, uy = unit(from[1] - cx, from[2] - cy)
    local s = 1 / sqrt(ux * ux / (rx * rx) + uy * uy / (ry * ry))
    return { cx + ux * s, cy + uy * s }
end
F.ShellEdge = ShellEdge

local SHELLS = {}
F.SHELLS = SHELLS
SHELLS.BEAST = { sparks = { PAL.BEAST.w, PAL.BEAST.l, PAL.BEAST.m }, draw = function(cx, cy, rx, ry, k, fl, tw)
    -- Thick Hide: stitched leather plates in a ring
    local n = 10
    local pf, pb = NewPS(), NewPS()
    for i = 0, n - 1 do
        if i / n <= k * 1.05 then
            local a0 = i * TAU / n + 0.08
            local a1 = a0 + TAU / n - 0.16
            local back = sin((a0 + a1) / 2) < -0.05
            local set = back and pb or pf
            local lit = (floor(tw * 6) % n) == i or fl > 0.3
            Arc(set, cx, cy, rx, ry, a0, a1, lit and PAL.BEAST.h or PAL.BEAST.m)
            Arc(set, cx, cy, rx - 1, ry - 1, a0, a1, PAL.BEAST.d)
            local am = (a0 + a1) / 2
            set:Add(cx + cos(am) * (rx - 0.5), cy + sin(am) * (ry - 0.5), PAL.BEAST.w)
        end
    end
    pb:Flush("under", 0.9) pf:Flush("over", 0.95)
end }
SHELLS.FIRE = { sparks = { F.SPARK[1], F.SPARK[2], F.SPARK[3] }, draw = function(cx, cy, rx, ry, k, fl, tw)
    -- Fire Ward: a ring of flame, small flames licking along its top
    local sc = 0.7 + 0.3 * k
    local ps = NewPS()
    Arc(ps, cx, cy, rx * sc, ry * sc, pi, TAU, fl > 0.3 and PAL.FIRE.w or PAL.FIRE.l)
    Arc(ps, cx, cy, rx * sc, ry * sc, 0, pi, PAL.FIRE.m)
    ps:Flush("over", 0.85 * k)
    Disc(cx, cy, rx * sc - 1, ry * sc - 1, PAL.FIRE.h, 0.08 + 0.15 * fl)
    for i = 0, 6 do
        if i <= k * 8 then
            local a = pi + 0.15 + i * (pi - 0.3) / 6
            StampB(GL.flameS[(floor(tw * 12) + i) % 3 + 1], cx + cos(a) * rx * sc, cy + sin(a) * ry * sc + 2, FLAME)
        end
    end
    Glow(cx, cy - ry * 0.5, rx * 1.6, C("#ff8a2a"), 0.18 + 0.3 * fl)
end }
SHELLS.WATER = { sparks = { PAL.WATER.w, PAL.WATER.h, PAL.WATER.l }, draw = function(cx, cy, rx0, ry0, k, fl, tw)
    -- Shell Shield: a dome with scale arcs and a sheen that sweeps across
    local sc = 0.6 + 0.4 * k
    local rx, ry = rx0 * sc, ry0 * sc
    local ps = NewPS()
    Disc(cx, cy, rx - 1, ry - 1, PAL.WATER.l, 0.12 + 0.2 * fl)
    Arc(ps, cx, cy, rx, ry, 0, TAU, fl > 0.3 and PAL.WATER.w or PAL.WATER.h)
    Arc(ps, cx, cy, rx - 1, ry - 1, 0.3, pi - 0.3, PAL.WATER.m)
    for row = 0, 1 do
        for i = 0, 4 do
            if not (row == 1 and i == 4) then
                Arc(ps, cx + (i - 2) * rx * 0.36 + (row == 1 and rx * 0.18 or 0), cy - ry * 0.55 + row * ry * 0.3, 2.5, 1.5, 0.2, pi - 0.2, PAL.WATER.l)
            end
        end
    end
    local sw = (tw * 0.9) % 1.4 - 0.2
    Arc(ps, cx, cy, rx - 2, ry - 2, pi + 0.4 + sw, pi + 0.9 + sw, PAL.WATER.w)
    ps:Flush("over", 0.75 * k + 0.25 * fl)
    Glow(cx, cy, rx0 * 1.5, C("#58b4ff"), 0.12 + 0.3 * fl, "under")
end }
SHELLS.NATURE = { sparks = { PAL.NATURE.h, PAL.NATURE.l, BARK.l }, draw = function(cx, cy, rx, ry, k, fl, tw)
    -- Barkskin: bark plates with grain, a few leaves on top
    local n = 9
    local pf, pb = NewPS(), NewPS()
    for i = 0, n - 1 do
        if (i + 0.5) / n <= k * 1.05 then
            local a0 = pi * 0.5 + i * TAU / n + 0.06
            local a1 = a0 + TAU / n - 0.12
            local set = sin((a0 + a1) / 2) < -0.1 and pb or pf
            Arc(set, cx, cy, rx, ry, a0, a1, fl > 0.3 and BARK.h or BARK.l)
            Arc(set, cx, cy, rx - 1, ry - 1, a0, a1, BARK.d)
        end
    end
    pb:Flush("under", 0.9) pf:Flush("over", 0.95)
    if k > 0.8 then
        for j = 0, 2 do
            local x, y = cx + (j - 1) * 5, cy - ry - 1 + (j == 1 and -1 or 0)
            Rect(x, y, 2, 1, PAL.NATURE.l) Rect(x + (j == 2 and 1 or 0), y - 1, 1, 1, PAL.NATURE.h)
        end
    end
end }
SHELLS.SHADOW = { sparks = { BONE.w, BONE.h, PAL.SHADOW.l }, draw = function(cx, cy, rx, ry, k, fl, tw)
    -- Bone Armor: bones circling the beast, a dark ring at its feet
    Ring(cx, cy + ry - 2, rx * 0.8, 3, 1, PAL.SHADOW.m, 0.6 * k, "under")
    for i = 0, 5 do
        local a = tw * 1.7 + i * TAU / 6
        local R = lerp(2, 1, k)
        local x, y = cx + cos(a) * rx * R * 0.9, cy + sin(a) * ry * 0.22 + (i % 2 == 1 and -4 or 3)
        local front = sin(a) > 0
        StampC(abs(cos(a)) > 0.55 and GL.boneV or GL.boneH, x + (fl > 0.2 and rr(-1, 1) or 0), y,
               front and BONE or { h = BONE.m, m = BONE.d }, { lay = front and "over" or "under", a = k, shadow = BONE.o })
    end
end }
SHELLS.EARTH = { sparks = { STONE.w, STONE.h, STONE.l }, draw = function(cx, cy, rx, ry, k, fl, tw)
    -- Stoneskin: stone plates hug the lower body, a thin ring above
    local ps = NewPS()
    Arc(ps, cx, cy, rx, ry, pi + 0.25, TAU - 0.25, STONE.l)
    ps:Flush("over", 0.6 * k + 0.4 * fl)
    local ramp = { STONE.o, STONE.d, STONE.m, STONE.l, STONE.h }
    for i = 0, 7 do
        local a = pi * 0.08 + i * pi * 0.12
        local rise = clamp(k * 1.6 - i * 0.08, 0, 1)
        if rise > 0 then DrawGen(Rock(2, ramp, i % 4), cx + cos(a) * rx * 0.95, cy + sin(a) * ry * 0.85 + (1 - rise) * 8, { a = rise }) end
    end
    if k > 0.9 then
        for j = 0, 1 do
            local a2 = pi + 0.5 + j * 1.6
            DrawGen(Rock(2, ramp, j + 1), cx + cos(a2) * rx * 0.9, cy + sin(a2) * ry * 0.9, { lay = "under" })
        end
    end
    if floor(tw * 2) % 3 == 0 then Rect(cx + rx * 0.5, cy + ry * 0.3, 1, 1, STONE.w) end
end }
SHELLS.AIR = { sparks = { PAL.AIR.w, PAL.AIR.h, PAL.AIR.l }, draw = function(cx, cy, rx0, ry0, k, fl, tw)
    -- Wind Wall: three bands of wind circling the beast
    local pf, pb = NewPS(), NewPS()
    for b = 0, 2 do
        local y0 = cy + (b - 1) * ry0 * 0.55
        local rx, ry = rx0 * (0.85 + (b == 1 and 0.1 or 0)) * (0.6 + 0.4 * k), 3 + b
        for d = 0, 1 do
            local a0 = tw * (3.4 + b * 0.6) + d * pi + b * 1.3
            local a1 = a0 + 1.6
            local s = a0
            while s < a1 do
                local set = sin(s) > 0 and pf or pb
                set:Add(cx + cos(s) * rx, y0 + sin(s) * ry + 1, PAL.AIR.d)
                set:Add(cx + cos(s) * rx, y0 + sin(s) * ry, s > a1 - 0.5 and PAL.AIR.w or (fl > 0.3 and PAL.AIR.h or PAL.AIR.l))
                s = s + 0.06
            end
        end
    end
    pb:Flush("under", 0.75 * k) pf:Flush("over", 0.9 * k)
end }
SHELLS.MECH = { sparks = { VOLT.w, VOLT.l, VOLT.m }, draw = function(cx, cy, rx0, ry0, k, fl, tw)
    -- Deflector Shield: a teal shell, a few hexes across its top lit by a passing scan line
    local sc = 0.6 + 0.4 * k
    local rx, ry = rx0 * sc, ry0 * sc
    local ring, hex = NewPS(), NewPS()
    Disc(cx, cy, rx - 1, ry - 1, VOLT.m, 0.07 + 0.2 * fl)
    Arc(ring, cx, cy, rx, ry, 0, TAU, fl > 0.3 and VOLT.w or VOLT.l)
    ring:Flush("over", 0.7 * k + 0.3 * fl)
    local scan = cy - ry + ((tw * 22) % (2 * ry + 10))
    for gy = -2, 0 do
        for gx = -2, 2 do
            local hx, hy = cx + gx * 6 + (gy % 2 ~= 0 and 3 or 0), cy + gy * 5
            if ((hx - cx) * (hx - cx)) / (rx * rx) + ((hy - cy) * (hy - cy)) / (ry * ry) <= 0.62 then
                local c = (abs(hy - scan) < 3 or fl > 0.4) and VOLT.h or VOLT.m
                for s = 0, 5 do
                    local a0 = s * pi / 3 + pi / 6
                    local a1 = a0 + pi / 3
                    Line(hex, hx + cos(a0) * 3, hy + sin(a0) * 2.4, hx + cos(a1) * 3, hy + sin(a1) * 2.4, c)
                end
            end
        end
    end
    hex:Flush("over", 0.3 * k + 0.5 * fl)
    Glow(cx, cy, rx0 * 1.5, C("#3fe0d0"), 0.14 + 0.3 * fl, "under")
end }

local GS = {}                                -- [side] = { type, tw, k, flare }: the shell on screen
local function DrawShell(side, g, dt)
    g.tw = g.tw + dt
    g.flare = max(0, (g.flare or 0) - dt * 3.2)
    local cx, cy, rx, ry = ShellGeo(side)
    local sh = SHELLS[g.type] or SHELLS.BEAST
    sh.draw(cx, cy, rx, ry, g.k or 1, g.flare, g.tw)
end
-- a hit stops on the shell: it flares, sparks fly back toward the attacker
function F.GuardHit(side, pt, X)
    local g = GS[side]
    if not g then return end
    g.flare = 1
    local sh = SHELLS[g.type] or SHELLS.BEAST
    Spray(pt[1], pt[2], 7, { kind = "spark", cols = sh.sparks, s = { 40, 80 }, ang = atan2(X.A.c[2] - pt[2], X.A.c[1] - pt[1]),
          spread = pi * 0.9, ay = 90, drag = 3, life = { 0.2, 0.4 } })
    Emit({ kind = "ring", x = pt[1], y = pt[2], r0 = 1, r1 = 6, cols = { sh.sparks[1], sh.sparks[2] }, life = 0.25 })
end

---------------------------------------------------------------------------
-- Marks, while they last (read from the snapshot), and the pop as one lands
---------------------------------------------------------------------------

local function every(st, k, iv, dt, fn)
    st[k] = (st[k] or 0) + dt
    local n = 0
    while st[k] >= iv and n < 4 do st[k] = st[k] - iv n = n + 1 fn() end
end
local MARKS = {}
F.MARKS = MARKS
local BLOOD4 = { BLOOD[2], BLOOD[1], BLOOD[3], BLOOD[4] }
MARKS.bleed = function(side, p, M, dt)
    -- a red scar on it that drips now and then
    local sx = floor(p.c[1] + (side == "foe" and -1 or 1) * p.w * 0.12 + 0.5)
    local sy = floor(p.c[2] - p.h * 0.05 + 0.5)
    local ps = NewPS()
    for k = 0, 1 do
        Line(ps, sx - 1 + k * 3, sy - 2, sx + 2 + k * 3, sy + 2, BLOOD[4])
        Line(ps, sx - 2 + k * 3, sy - 2, sx + 1 + k * 3, sy + 2, k == 1 and BLOOD[2] or BLOOD[1])
    end
    ps:Flush("over")
    every(M, "a", 0.5, dt, function()
        Emit({ kind = "drop", x = sx + rr(-1, 4), y = sy + 2, vy = 0, ay = 120, ground = p.feet[2] + rr(-1, 2), life = 1.8,
               cols = BLOOD4, onLand = Splat })
    end)
end
MARKS.immolate = function(side, p, M, dt)
    -- small flames lick at it, embers rise
    local f1 = floor(M.tw * 11)
    StampB(GL.flameS[f1 % 3 + 1], p.l + p.w * 0.22, p.feet[2] - 1, FLAME)
    StampB(GL.flameS[(f1 + 1) % 3 + 1], p.r - p.w * 0.2, p.feet[2] - 2, FLAME)
    StampB(GL.flameS[(f1 + 2) % 3 + 1], p.c[1] + p.w * 0.05, p.c[2] + p.h * 0.1, FLAME)
    every(M, "a", 0.16, dt, function()
        Emit({ kind = "ember", x = p.c[1] + rr(-p.w * 0.35, p.w * 0.35), y = p.c[2] + rr(0, p.h * 0.3), vy = -22, ay = -10,
               life = 0.7, cols = FIRE_R, sway = 1 })
    end)
    Glow(p.feet[1], p.feet[2] - 4, p.w * 0.9, C("#ff7a26"), 0.22 + 0.06 * sin(M.tw * 9), "under")
end
local WISP = { PAL.SHADOW.h, PAL.SHADOW.l, PAL.SHADOW.m, PAL.SHADOW.d }
MARKS.corrupt = function(side, p, M, dt)
    -- dark wisps rise off it; it darkens in pulses
    every(M, "a", 0.13, dt, function()
        Emit({ kind = "wisp", x = p.c[1] + rr(-p.w * 0.35, p.w * 0.35), y = p.c[2] + rr(-p.h * 0.2, p.h * 0.3), vy = -15,
               life = 0.9, cols = WISP })
    end)
    local v = 0.5 + 0.5 * sin(M.tw * 4)
    F.Shade(side, 1 - 0.18 * v, 1 - 0.26 * v, 1 - 0.08 * v)
end
MARKS.chill = function(side, p, M, dt)
    -- frost on the ground at its feet, a cold light on it, glints
    F.Light(side, C("#9fd4ff"), 0.22)
    StampB(GL.crystalS, p.feet[1] - 0.32 * p.w, p.feet[2], PAL.WATER)
    StampB(GL.crystal, p.feet[1] + 0.3 * p.w, p.feet[2] + 1, PAL.WATER)
    StampB(GL.crystalS, p.feet[1] + 0.05 * p.w, p.feet[2] - 1, PAL.WATER, { lay = "under" })
    every(M, "a", 0.45, dt, function()
        Emit({ kind = "glint", x = p.c[1] + rr(-p.w * 0.4, p.w * 0.4), y = p.c[2] + rr(-p.h * 0.4, p.h * 0.3), life = 0.35,
               cols = { PAL.WATER.h, PAL.WATER.w } })
    end)
end
MARKS.rooted = function(side, p, M, dt)
    -- roots coiled round its feet
    local pf, pb = NewPS(), NewPS()
    local rx = p.w * 0.42 + 2
    for lvl = 0, 2 do
        local cy = p.feet[2] - lvl * 3 - 1 + (lvl == 1 and sin(M.tw * 3) * 0.5 or 0)
        local s = 0
        while s < TAU do
            if (s % 1.6) <= 1.25 then
                local a = s + lvl * 1.7
                local x, y = p.feet[1] + cos(a) * (rx - lvl), cy + sin(a) * 2.6
                local set = sin(a) > 0 and pf or pb
                set:Add(x, y + 1, BARK.d)
                set:Add(x, y, sin(a) > 0.4 and BARK.l or BARK.m)
            end
            s = s + 0.04
        end
    end
    for i, l in ipairs({ { -0.4, 3 }, { 0.35, 6 }, { 0.05, 8 } }) do
        local x, y = p.feet[1] + l[1] * p.w * 1.1, p.feet[2] - l[2]
        pf:Add(x, y, PAL.NATURE.l)
        pf:Add(x + (sin(M.tw * 4 + i) > 0 and 1 or -1), y - 1, PAL.NATURE.h)
    end
    pb:Flush("under") pf:Flush("over")
end
MARKS.exposed = function(side, p, M, dt)
    -- a hunter's lock on it
    Brackets(p, 3 + (sin(M.tw * 5) > 0.3 and 1 or 0), GOLD, 1)
end
MARKS.charged = function(side, p, M, dt)
    -- little arcs crackle over it, three sparks circle it
    every(M, "a", 0.22, dt, function()
        local x0, y0 = p.c[1] + rr(-p.w * 0.35, p.w * 0.35), p.c[2] + rr(-p.h * 0.35, p.h * 0.2)
        M.arc = { t = 0.12, x0 = x0, y0 = y0, x1 = x0 + rr(-7, 7), y1 = y0 + rr(-6, 6) }
    end)
    if M.arc then
        M.arc.t = M.arc.t - dt
        if M.arc.t > 0 then
            local zp = NewPS()
            Zigzag(zp, M.arc.x0, M.arc.y0, M.arc.x1, M.arc.y1, 3, 2, { VOLT.m, VOLT.w })
            zp:Flush("over")
            Glow(M.arc.x0, M.arc.y0, 10, C("#3fe0d0"), 0.5)
        end
    end
    for i = 0, 2 do
        local a = M.tw * 5 + i * TAU / 3
        local x, y = p.c[1] + cos(a) * (p.w * 0.5 + 2), p.c[2] + sin(a) * 3 + (i - 1) * 4
        local lay = sin(a) > 0 and "over" or "under"
        Rect(x, y - 1, 1, 3, VOLT.m, 1, lay) Rect(x - 1, y, 3, 1, VOLT.m, 1, lay) Rect(x, y, 1, 1, VOLT.w, 1, lay)
    end
    Glow(p.c[1], p.c[2], p.w * 0.8, C("#3fe0d0"), 0.12, "under")
end
local MOTE = { HEAL.w, HEAL.h, HEAL.l, HEAL.m }
MARKS.regrowth = function(side, p, M, dt)
    -- green motes drift up from a soft ring at its feet
    Ring(p.feet[1], p.feet[2], p.w * 0.4 + 1, 2, 1, HEAL.l, 0.45 + 0.25 * sin(M.tw * 3), "under")
    every(M, "a", 0.2, dt, function()
        Emit({ kind = "mote", x = p.feet[1] + rr(-p.w * 0.4, p.w * 0.4), y = p.feet[2] - rr(0, 3), vy = -17, life = 1.0, cols = MOTE })
    end)
    Glow(p.feet[1], p.feet[2] - 4, p.w * 0.8, C("#7ee05a"), 0.14, "under")
end
local POPS = {
    bleed = function(p) Spray(p.c[1], p.c[2], 8, { kind = "drop", cols = BLOOD4, s = { 30, 60 }, ang = -pi / 2, spread = pi * 1.2, ay = 220, ground = p.feet[2] + 1, life = { 0.8, 1.2 }, onLand = Splat }) end,
    immolate = function(p) Spray(p.c[1], p.c[2] + 4, 10, { kind = "ember", cols = FIRE_R, s = { 20, 50 }, ang = -pi / 2, spread = pi * 0.9, ay = -20, life = { 0.4, 0.7 } }) end,
    corrupt = function(p) Spray(p.c[1], p.c[2], 10, { kind = "wisp", cols = WISP, s = { 12, 30 }, ang = -pi / 2, spread = pi * 1.4, life = { 0.6, 1.0 } }) end,
    chill = function(p) Spray(p.c[1], p.c[2], 8, { kind = "glint", cols = { PAL.WATER.h, PAL.WATER.w }, s = { 20, 45 }, drag = 4, life = { 0.3, 0.5 } }) end,
    rooted = function(p) Spray(p.feet[1], p.feet[2], 8, { kind = "pebble", cols = { BARK.d, BARK.m, BARK.l }, s = { 25, 50 }, ang = -pi / 2, spread = pi * 0.9, ay = 260, ground = p.feet[2] + 2, life = { 0.5, 0.7 } }) end,
    exposed = function(p) Spray(p.c[1], p.c[2], 6, { kind = "glint", cols = { GOLD.l, GOLD.w }, s = { 30, 55 }, drag = 5, life = { 0.3, 0.45 } }) end,
    charged = function(p) Spray(p.c[1], p.c[2], 10, { kind = "spark", cols = { VOLT.w, VOLT.l, VOLT.m }, s = { 30, 70 }, ay = 60, drag = 3, life = { 0.25, 0.45 } }) end,
    regrowth = function(p) Spray(p.feet[1], p.feet[2] - 2, 10, { kind = "mote", cols = { HEAL.w, HEAL.h, HEAL.l }, s = { 15, 35 }, ang = -pi / 2, spread = pi * 0.8, life = { 0.6, 0.9 } }) end,
}

---------------------------------------------------------------------------
-- Casts winding up: FxMoves.lua registers F.CASTS[key] = { windup(side, st, dt), focus(side), cols } and which move
-- ids use them (F.CAST_OF[id] = key). A cast without one keeps only its cast bar.
---------------------------------------------------------------------------

F.CASTS, F.CAST_OF = {}, {}
local CS = {}                                -- [side] = { key, id, tw, ... }: the wind-up on screen
local CH = {}                                -- [side] = { tw, flare }: the iron chain of a cast that can't be interrupted
local BROKEN = {}                            -- [side] = true: an interrupt broke the cast (until the snapshot drops it)
local function CastKey(id)
    if not id then return nil end
    local key = F.CAST_OF[id] or (F.CastFor and F.CastFor(id))
    return key and F.CASTS[key] and key or nil
end
-- can't be interrupted: an iron chain turns slowly round its feet (flare: an interrupt bounced off it)
local function ChainRing(side, tw, flare)
    local p = Pts(side)
    local rx, ry, cx, cy = floor(p.w * 0.6 + 4.5), 4, p.feet[1], p.feet[2] - 1
    local pf, pb = NewPS(), NewPS()
    local s = 0
    while s < TAU do
        local a = s + tw * 0.8
        local x, y = cx + cos(a) * rx, cy + sin(a) * ry
        local set = sin(a) > 0 and pf or pb
        local link = floor(s * rx / 2.2) % 2 == 1
        set:Add(x, y, flare > 0.2 and IRON.w or link and IRON.h or IRON.m)
        set:Add(x, y + 1, IRON.o)
        s = s + 0.03
    end
    pb:Flush("under", 0.95) pf:Flush("over", 0.95)
    if flare > 0 then Glow(cx, cy - 2, rx * 1.2, C("#e8ecf5"), 0.35 * flare, "under") end
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

local run                                    -- the effect playing now (one at a time, like BT.anim)
local MS = { foe = {}, ally = {} }           -- [side][mark id] = its state ({ tw, ... })
local peak = 0
local function Visible(side)
    local m = fx.models[side]
    return m and m:IsShown() and m:GetAlpha() > 0.5 and m.sp ~= nil
end
local function Ambient(side, s, dt)
    local p = Pts(side)
    -- marks
    local ms = MS[side]
    for id in pairs(ms) do if not (s.marks and s.marks[id]) then ms[id] = nil end end
    if s.marks then
        for id in pairs(s.marks) do
            local st = ms[id]
            if not st then st = { tw = 0 } ms[id] = st end
            st.tw = st.tw + dt
            if MARKS[id] then MARKS[id](side, p, st, dt) end
        end
    end
    -- a guard's shell
    if s.guard then
        local g = GS[side]
        if not g then
            local sp = ns.AzeroData and ns.AzeroData.species[s.sp]
            g = { type = s.guardType or (sp and sp.type) or "BEAST", tw = 0, k = 1, flare = 0 }
            GS[side] = g
        end
        DrawShell(side, g, dt)
    else
        GS[side] = nil
    end
    -- a cast winding up (not once an interrupt has broken it), and the chain of one that can't be interrupted
    local cast = s.cast
    if not cast then BROKEN[side] = nil end
    local key = cast and not BROKEN[side] and CastKey(cast.id)
    if key then
        local c = CS[side]
        if not c or c.key ~= key then c = { key = key, tw = 0 } CS[side] = c end
        c.tw = c.tw + dt
        F.CASTS[key].windup(side, c, dt)
    else
        CS[side] = nil
    end
    if cast and cast.unstoppable then
        local ch = CH[side]
        if not ch then ch = { tw = 0, flare = 0 } CH[side] = ch end
        ch.tw = ch.tw + dt
        ch.flare = max(0, ch.flare - dt * 2.5)
        ChainRing(side, ch.tw, ch.flare)
    else
        CH[side] = nil
    end
end

-- Every frame of a battle (UpdateBattle, before the event playback): marks, shells and wind-ups from the snapshot,
-- the effect playing, the particles; then the blocks go on screen.
function F.Frame(dt, snap)
    if not fx then return end
    if freeze > 0 then freeze = freeze - dt return end           -- a hit stop: everything holds still
    PT.foe, PT.ally = nil, nil
    Z = 0
    ResetBeasts()
    for _, side in ipairs(SIDES) do
        local s = snap and snap[side]
        if s and Visible(side) then Ambient(side, s, dt)
        else MS[side] = {} GS[side] = nil CS[side] = nil CH[side] = nil end
    end
    if run then run:Step(dt) end
    StepParts(dt)
    for i = 1, #PARTS do DrawPart(PARTS[i]) end
    StepShake(dt)
    local pools = fx.pools
    peak = max(peak, LISTS.under.n + LISTS.over.n)
    FlushBlocks(LISTS.under, pools.under)
    FlushBlocks(LISTS.over, pools.over, pools.shade)
    FlushGlows(GLOWS.under, pools.glowU)
    FlushGlows(GLOWS.over, pools.glowO)
    FlushStars(pools.star)
    for _, k in ipairs({ "under", "over", "shade", "glowU", "glowO", "star" }) do EndPool(pools[k]) end
    ApplyBeasts()
end

-- The battle layer and its two beast frames (UI.lua's BuildBattle). opts: play(name, arg) a sound, anim(m, id) a
-- clip, scene(dx, dy) moves the backdrop with a shake, shakeOn() false when the player turned shaking off,
-- castBar(side, p) cracks a broken cast's bar (p 0..1 through it).
function F.Attach(b, foeModel, allyModel, opts)
    opts = opts or {}
    local function layer(lvl)
        local f = CreateFrame("Frame", nil, b)
        f:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
        f:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
        f:SetFrameLevel(b:GetFrameLevel() + lvl)
        return f
    end
    fx = { b = b, models = { foe = foeModel, ally = allyModel }, play = opts.play, anim = opts.anim, scene = opts.scene,
           shakeOn = opts.shakeOn, castBar = opts.castBar }
    -- (the beasts are 2 levels up, the HP boxes 5: effects pass under the boxes)
    fx.under, fx.shade, fx.over = layer(1), layer(3), layer(4)
    fx.pools = { under = NewPool(fx.under, "block"), shade = NewPool(fx.shade, "block"), over = NewPool(fx.over, "block"),
                 glowU = NewPool(fx.under, "glow"), glowO = NewPool(fx.over, "glow"), star = NewPool(fx.over, "star") }
end

-- A new battle, the end of one: nothing left on screen.
function F.Reset()
    run, freeze, peak = nil, 0, 0
    for i = #PARTS, 1, -1 do PARTS[i] = nil end
    MS.foe, MS.ally, GS.foe, GS.ally, CS.foe, CS.ally = {}, {}, nil, nil, nil, nil
    CH.foe, CH.ally, BROKEN.foe, BROKEN.ally = nil, nil, nil, nil
    SHK.amp, SHK.ox, SHK.oy = 0, 0, 0
    if not fx then return end
    LISTS.under.n, LISTS.over.n, GLOWS.under.n, GLOWS.over.n, STARS.n = 0, 0, 0, 0, 0
    for _, pool in pairs(fx.pools) do pool.used = 0 EndPool(pool) end
    if SX ~= 0 or SY ~= 0 then
        SX, SY = 0, 0
        for _, f in ipairs({ fx.under, fx.shade, fx.over }) do
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", fx.b, "TOPLEFT", 0, 0)
            f:SetPoint("BOTTOMRIGHT", fx.b, "BOTTOMRIGHT", 0, 0)
        end
        if fx.scene then fx.scene(0, 0) end
    end
    ResetBeasts()
    for _, side in ipairs(SIDES) do
        local m, s = fx.models[side], BM[side]
        if (s.ax or 0) ~= 0 or (s.ay or 0) ~= 0 then
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", fx.b, "TOPLEFT", m.baseX, m.baseY)
        end
        s.ax, s.ay = 0, 0
        local spr = m.spr
        if spr and spr.key then
            if (s.appA or 0) > 0 then spr:SetFx(spr.shrink or 1, 0) end
            if s.appSr then spr:SetShade(nil) end
            for i = 1, 2 do spr:SetGhost(i, 0, 0, 0) end
        end
        s.appA, s.appC, s.appSr, s.appSg, s.appSb, s.appG = 0, nil, nil, nil, nil, 0
    end
end

-- BT.anim for a run: it waits while a hit stop holds, and ends the run when done
local function Anim(r)
    run = r
    return { t = 0, dur = r.dur, hold = F.Holding, done = function() if run == r then run = nil end end }
end

-- the move's context: who acts (a) on whom (b), their points, the facing, where it hits and how it lands
function F.Context(e)
    local a = e.side
    local b = a == "ally" and "foe" or "ally"
    local A, B = Pts(a), Pts(b)
    local mv = e.move or {}
    local X = { a = a, b = b, A = A, B = B, dir = a == "ally" and 1 or -1, mv = mv, type = mv.type, power = mv.power or 0,
                pal = PAL[mv.type] or PAL.BEAST, combo = e.combo and true or false, miss = e.miss and true or false,
                guarded = (e.guarded and GS[b]) and true or false, released = e.released and true or false }
    X.muzzle = a == "ally" and { A.c[1] + A.w * 0.18, A.c[2] - A.h * 0.14 } or { A.c[1] - A.w * 0.22, A.c[2] - A.h * 0.02 }
    X.hit = { B.c[1] - X.dir * B.w * 0.06, B.c[2] - B.h * 0.05 }
    X.ground = { B.feet[1], B.feet[2] }
    if X.miss then
        X.hit = { B.c[1] + X.dir * (B.w * 0.5 + 12), B.c[2] - 10 }
        X.ground = { B.feet[1] + X.dir * 22, B.feet[2] + 2 }
    elseif X.guarded then
        X.hit = ShellEdge(b, X.muzzle)
    end
    return X
end

F.MOVES = {}                                 -- [move id] = { play(run, X), desc } (FxMoves.lua)

-- The battle's "attack" event: BT.anim for the move's effect, or nil when it has none yet (UI.lua keeps the lunge).
function F.Attack(e)
    if not fx or not e.move or not (Visible(e.side)) then return nil end
    local mv = e.move
    if mv.guard then                                                -- (the shell forms on the "guard" event)
        local r = NewRun(0.25)
        r:At(0, function() F.Clip(e.side, 54) end)
        return Anim(r)
    end
    local rec = e.id and (F.MOVES[e.id] or (F.Sig and F.Sig(e.id, mv)))
    if not rec then return nil end
    local X = F.Context(e)
    local r = NewRun(0.6)
    rec.play(r, X)
    return Anim(r)
end

-- The "guard" event: the beast's shell forms round it (it stays while the snapshot says it guards)
function F.Guard(e)
    if not fx or not Visible(e.side) then return nil end
    local s = e.snap and e.snap[e.side]
    local sp = s and ns.AzeroData and ns.AzeroData.species[s.sp]
    local g = { type = (s and s.guardType) or (sp and sp.type) or "BEAST", tw = 0, k = 0, flare = 0 }
    GS[e.side] = g
    local r = NewRun(0.5)
    r:Span(0, 0.42, function(p) g.k = eOut(p) if p > 0.85 then g.flare = 1 end end)
    r:At(0.42, function() g.k = 1 end)
    return Anim(r)
end

-- The "mark" event: a mark landing pops in its colours (one going away just stops showing)
function F.Mark(e)
    if not fx or not e.mark or (e.turns or 0) <= 0 or not Visible(e.side) then return nil end
    local side, id = e.side, e.mark
    local r = NewRun(0.38)
    r:At(0, function() if POPS[id] then POPS[id](Pts(side)) end end)
    r:Span(0, 0.18, function(p) F.Light(side, F.MARKCOL[id] or F.WHITE, 0.5 * (1 - p)) end)
    return Anim(r)
end

-- The "cast" event: a beat for the wind-up to begin before the battle's line (nil: this cast has none)
function F.Windup(e)
    if not fx or not Visible(e.side) then return nil end
    local s = e.snap and e.snap[e.side]
    if not (s and s.cast and CastKey(s.cast.id)) then return nil end
    return Anim(NewRun(0.5))
end

-- The "interrupt" event (side: the caster): the power it gathered shatters into shards and smoke, it flinches, and
-- its cast bar cracks, shakes and drops away (UI.lua's castBar hook)
function F.Break(e)
    if not fx or not Visible(e.side) then return nil end
    local side = e.side
    local s = e.snap and e.snap[side]
    local cast = s and s.cast
    local key = cast and CastKey(cast.id)
    local cs = key and F.CASTS[key]
    local p = Pts(side)
    local f = (cs and cs.focus) and cs.focus(side) or { p.c[1], p.c[2] - p.h * 0.1 }
    local pal = PAL[cast and cast.type or ""] or PAL.BEAST
    local cols = (cs and cs.cols) or { pal.w, pal.l }
    BROKEN[side] = true
    local r = NewRun(0.5)
    r:At(0, function()
        F.Clip(side, 9)
        Spray(f[1], f[2], 14, { kind = "shard", cols = cols, s = { 40, 90 }, ay = 180, drag = 1.5, life = { 0.35, 0.6 } })
        Spray(f[1], f[2], 4, { kind = "puff", cols = F.SMOKE, s = { 6, 16 }, ang = -pi / 2, spread = pi * 1.5, ay = -8,
              life = { 0.5, 0.8 }, r0 = 1, r1 = 3, a = 0.8 })
    end)
    r:Span(0, 0.14, function(q)
        Glow(f[1], f[2], 16 * (1 - q), F.WHITE, 0.45 * (1 - q))
        Star(f[1], f[2], 34 * (1 - q), F.WHITE, 1 - q)
        F.Light(side, F.WHITE, 0.2)
    end)
    r:Span(0, 0.45, function(q) if fx.castBar then fx.castBar(side, q) end end)
    return Anim(r)
end

-- The "unstoppable" event (side: the caster): the interrupt bounces off; its chain flares, sparks fly back
function F.Shrug(e)
    if not fx or not Visible(e.side) then return nil end
    local side = e.side
    local by = side == "ally" and "foe" or "ally"
    local r = NewRun(0.6)
    r:At(0, function()
        local ch = CH[side]
        if ch then ch.flare = 1 end
        local p, q = Pts(side), Pts(by)
        Spray(p.c[1], p.c[2], 8, { kind = "spark", cols = { IRON.w, IRON.h, IRON.l }, s = { 50, 90 },
              ang = atan2(q.c[2] - p.c[2], q.c[1] - p.c[1]), spread = pi * 0.7, ay = 120, life = { 0.25, 0.45 } })
    end)
    r:Span(0, 0.3, function(q)
        local p = Pts(side)
        if q < 0.4 then F.Light(side, C("#c4c8d2"), 0.2) end
        Glow(p.feet[1], p.feet[2] - 4, p.w, C("#e8ecf5"), 0.3 * (1 - q), "under")
    end)
    return Anim(r)
end

-- what is on screen (tests): blocks this frame and the most since Reset, shades, glows, sparkles, particles, the
-- effect playing, marks / shells / wind-ups per side
function F.State()
    if not fx then return {} end
    local p = fx.pools
    local out = { blocks = p.under.shown + p.over.shown, shades = p.shade.shown, glows = p.glowU.shown + p.glowO.shown,
                  stars = p.star.shown, parts = #PARTS, playing = run ~= nil, peak = peak, marks = {}, shell = {}, windup = {} }
    for _, side in ipairs(SIDES) do
        local ids = {}
        for id in pairs(MS[side]) do ids[#ids + 1] = id end
        tsort(ids)
        out.marks[side] = ids
        out.shell[side] = GS[side] and GS[side].type or nil
        out.windup[side] = CS[side] and CS[side].key or nil
        out.chain = out.chain or {}
        out.chain[side] = CH[side] and true or nil
        out.broken = out.broken or {}
        out.broken[side] = BROKEN[side] or nil
    end
    local bm = {}
    for _, side in ipairs(SIDES) do bm[side] = { dx = BM[side].ax or 0, dy = BM[side].ay or 0 } end
    out.offset = bm
    out.shake = { SX, SY }
    return out
end
