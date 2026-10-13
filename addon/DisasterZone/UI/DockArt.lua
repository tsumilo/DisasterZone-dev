if DisasterZoneBoot and DisasterZoneBoot.Run("UI/DockArt.lua", ...) then return end -- DisasterZone UI/DockArt.lua
-- Classic's Dock art (Settings > UI > Action bars > Bar art, while Classic is the bars' look): three sets drawn by
-- dev/generators/gen_classic_media.py (Media/Classic/<set>.tga, where each piece is: Data/ClassicArt.lua), put
-- together on the Dock's grid at any button size. Mockup dev/art/casc/classic_bars_mockup
-- (claude.ai/artifact/JpFwZd5QaaqB1eeXMgu1Fk; the user: all three, to choose from while Classic is set).
--   ironforge  the vanilla bar grown: dark stone, a riveted steel moulding with bolted corners, steel pillars, the
--              main bar's carved wells and its max-level grooves (both the client's own), gryphons
--   stormwind  night marble, a gilt moulding with a sapphire on each corner, gilt pillars, every cluster sunk in a
--              tray with a gilt rim, gilt pearls in the experience slot, lions
--   vault      the guild bank: blued iron round a crimson inlay, brass-rimmed slots with the bank's own wing
--              relief, a stud where four slots meet, a stitched crimson strap, gryphons
-- The plate: the set's ground tiled over it; the moulding round it and round each step the crown stands on (runs
-- stretched along their edge, the outer corners, the rounded joints at a step's foot); a pillar in the middle of each
-- gap between the clusters; trays and wells under the buttons; in the experience slot a band, shown while the bar is
-- not (max level and no reputation watched). The pieces are drawn at 2 px per UI px of a 36 px button: k = S / 36
-- scales them. Needs art pack 9: without it the Dock keeps Classic's plain stone (UI/LookDock.lua).
local addonName, ns = ...

local Art = ns:NewModule("DockArt")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local ipairs = ipairs

local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\Classic\\"
local DWARF = "Interface\\MainMenuBar\\UI-MainMenuBar-Dwarf"           -- (the vanilla well: 42, 148 .. 84, 190 of 256)
local MAXLEVEL = "Interface\\MainMenuBar\\UI-MainMenuBar-MaxLevel"      -- (256 x 32: the grooves in rows 2 .. 29)
local BANK = "Interface\\GuildBankFrame\\UI-GuildBankFrame-Slots"        -- (128 x 512: a slot's relief 8, 6 .. 44, 41)

Art.SETS = {
    { key = "ironforge", name = "Ironforge", tip = "Stone and steel: the vanilla bar grown to the Dock." },
    { key = "stormwind", name = "Stormwind", tip = "Night marble and gold." },
    { key = "vault", name = "Guild Vault", tip = "Iron and crimson: the guild bank." },
}

local function Data() return ns.Data and ns.Data.ClassicArt end
local function Look() return ns.Look end

-- The art is on disk (art pack 9) and its piece list loaded.
function Art:Ready()
    return ns:HasAssets(9) and Data() ~= nil
end

-- The chosen set (ui.bars.art; Ironforge by default).
function Art:Set()
    local k = Look() and Look():Opt("bars", "art", "ironforge") or "ironforge"
    local d = Data()
    if not (d and d[k]) then k = "ironforge" end
    return k
end

-- The end caps to stand at the Dock's ends: the option (ui.bars.caps), or with "match" (the default) the set's own
-- (lions with Stormwind, gryphons with the others; gryphons without the art).
function Art:Caps()
    local c = Look() and Look():Opt("bars", "caps", "match") or "match"
    if c ~= "match" then return c end
    local d = Data()
    local s = d and self:Ready() and d[self:Set()]
    return s and s.caps or "gryphon"
end

---------------------------------------------------------------------------
-- Textures: a pool per frame (the art is drawn again on every layout)
---------------------------------------------------------------------------

local function New(pool, f, layer, sub)
    pool.n = pool.n + 1
    local t = pool.t[pool.n]
    if not t then
        t = f:CreateTexture(nil, layer, nil, sub)
        pool.t[pool.n] = t
    else
        t:SetDrawLayer(layer, sub)
    end
    t:SetVertexColor(1, 1, 1, 1)
    t:Show()
    return t
end

local function Begin(f, field)
    local pool = f[field]
    if not pool then pool = { t = {}, n = 0 }; f[field] = pool end
    pool.n = 0
    return pool
end

local function Finish(pool)
    for i = pool.n + 1, #pool.t do pool.t[i]:Hide() end
end

-- A rect of `file` (tex coords u0 .. u1, v0 .. v1) at x, y of f (dock units, y down), w x h.
local function Quad(pool, f, file, u0, u1, v0, v1, x, y, w, h, layer, sub)
    if w <= 0.01 or h <= 0.01 then return nil end
    local t = New(pool, f, layer, sub)
    t:SetTexture(file)
    t:SetTexCoord(u0, u1, v0, v1)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    t:SetSize(w, h)
    return t
end

-- A piece of the set's atlas at x, y: its own size (scaled) unless w / h are given; part = { x, y, w, h } px inside
-- it; axis "x" / "y": stretched along that axis from its middle texel (a moulding is the same all along an edge).
local function Put(ctx, name, x, y, w, h, layer, sub, part, axis)
    local P = ctx.s.p[name]
    if not P then return nil end
    local px, py, pw, ph = P[1], P[2], P[3], P[4]
    if part then px, py, pw, ph = px + part[1], py + part[2], part[3], part[4] end
    local W, H = ctx.s.w, ctx.s.h
    local u0, u1, v0, v1 = px / W, (px + pw) / W, py / H, (py + ph) / H
    if axis == "x" then local m = px + pw / 2; u0, u1 = (m - 0.5) / W, (m + 0.5) / W end
    if axis == "y" then local m = py + ph / 2; v0, v1 = (m - 0.5) / H, (m + 0.5) / H end
    return Quad(ctx.pool, ctx.f, ctx.file, u0, u1, v0, v1, x, y, w or pw * ctx.u, h or ph * ctx.u, layer, sub)
end

-- A file's rect (rx, ry, rw, rh of a tw x th file) repeated over x, y, w, h, each copy cw x ch (the last ones cut).
local function Tile(pool, f, file, tw, th, rect, x, y, w, h, cw, ch, layer, sub)
    if w <= 0.01 or h <= 0.01 or cw < 1 or ch < 1 then return end
    local cols, rows = ceil(w / cw - 0.001), ceil(h / ch - 0.001)
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local qw, qh = min(cw, w - c * cw), min(ch, h - r * ch)
            Quad(pool, f, file, rect[1] / tw, (rect[1] + rect[3] * qw / cw) / tw, rect[2] / th,
                (rect[2] + rect[4] * qh / ch) / th, x + c * cw, y + r * ch, qw, qh, layer, sub)
        end
    end
end

-- A whole file repeated over x, y, w, h, each copy cw x ch, the pattern anchored at the frame's top-left (two
-- rects tiled this way meet without a seam).
local function Ground(pool, f, file, x, y, w, h, cw, ch, layer, sub)
    if w <= 0.01 or h <= 0.01 or cw < 1 or ch < 1 then return end
    -- (whole tile indices, never a running sum: a float step can round to nothing at a size like 42 and never end)
    for r = floor(y / ch), ceil((y + h) / ch) - 1 do
        local y0, y1 = max(y, r * ch), min(y + h, (r + 1) * ch)
        if y1 - y0 > 0.01 then
            for c = floor(x / cw), ceil((x + w) / cw) - 1 do
                local x0, x1 = max(x, c * cw), min(x + w, (c + 1) * cw)
                if x1 - x0 > 0.01 then
                    Quad(pool, f, file, (x0 - c * cw) / cw, (x1 - c * cw) / cw, (y0 - r * ch) / ch, (y1 - r * ch) / ch,
                        x0, y0, x1 - x0, y1 - y0, layer, sub)
                end
            end
        end
    end
end

-- A 9-slice of the pieces <prefix>tl .. <prefix>br on x, y, w, h (in a small box the corners shrink to its half,
-- keeping their outer part).
local function Nine(ctx, prefix, x, y, w, h, layer, sub)
    local P = ctx.s.p[prefix .. "tl"]
    if not P or w <= 0 or h <= 0 then return end
    local cp = P[3]
    local cw, ch = min(cp * ctx.u, w / 2), min(cp * ctx.u, h / 2)
    local kx, ky = cw / ctx.u, ch / ctx.u
    Put(ctx, prefix .. "tl", x, y, cw, ch, layer, sub, { 0, 0, kx, ky })
    Put(ctx, prefix .. "tr", x + w - cw, y, cw, ch, layer, sub, { cp - kx, 0, kx, ky })
    Put(ctx, prefix .. "bl", x, y + h - ch, cw, ch, layer, sub, { 0, cp - ky, kx, ky })
    Put(ctx, prefix .. "br", x + w - cw, y + h - ch, cw, ch, layer, sub, { cp - kx, cp - ky, kx, ky })
    local mw, mh = w - 2 * cw, h - 2 * ch
    if mw > 0.01 then
        local T = ctx.s.p[prefix .. "t"]
        Put(ctx, prefix .. "t", x + cw, y, mw, ch, layer, sub, { 0, 0, T[3], ky }, "x")
        Put(ctx, prefix .. "b", x + cw, y + h - ch, mw, ch, layer, sub, { 0, cp - ky, T[3], ky }, "x")
    end
    if mh > 0.01 then
        local L = ctx.s.p[prefix .. "l"]
        Put(ctx, prefix .. "l", x, y + ch, cw, mh, layer, sub, { 0, 0, kx, L[4] }, "y")
        Put(ctx, prefix .. "r", x + w - cw, y + ch, cw, mh, layer, sub, { cp - kx, 0, kx, L[4] }, "y")
    end
    if mw > 0.01 and mh > 0.01 then
        Put(ctx, prefix .. "c", x + cw, y + ch, mw, mh, layer, sub, nil, "x")
    end
end

---------------------------------------------------------------------------
-- The plate
---------------------------------------------------------------------------

-- Rivets along an edge from (x0, y0) to (x1, y1), `off` in from it along (nx, ny), about every 46 UI px.
local function Rivets(ctx, x0, y0, x1, y1, nx, ny)
    local at = ctx.s.rivetAt
    if not at then return end
    local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
    local n = floor(len / (46 * ctx.k))
    if n < 1 then return end
    local off, half = at[1] * ctx.u, 8 * ctx.u
    for i = 1, n do
        local t = (i - 0.5) / n
        local cx, cy = x0 + (x1 - x0) * t + nx * off, y0 + (y1 - y0) * t + ny * off
        Put(ctx, "rivet", cx - half, cy - half, nil, nil, "BORDER", 2)
    end
end

-- The moulding: round the plate (0, top .. w, h) and each step (x0 .. x1, from y0 down to the plate's top).
local function Moulding(ctx, spec)
    local d = Data()
    local u = ctx.u
    local b, c = d.TR * u, d.C * u
    local W, H, top = spec.w, spec.h, spec.top
    local function Run(name, x, y, w, h)
        if w > 0.01 and h > 0.01 then Put(ctx, name, x, y, w, h, "BORDER", 0, nil, (name == "top" or name == "bottom") and "x" or "y") end
    end
    Put(ctx, "tl", 0, top, nil, nil, "BORDER", 1)
    Put(ctx, "tr", W - c, top, nil, nil, "BORDER", 1)
    Put(ctx, "bl", 0, H - c, nil, nil, "BORDER", 1)
    Put(ctx, "br", W - c, H - c, nil, nil, "BORDER", 1)
    Run("left", 0, top + c, b, H - top - 2 * c)
    Run("right", W - b, top + c, b, H - top - 2 * c)
    Run("bottom", c, H - b, W - 2 * c, b)
    Rivets(ctx, 0, top + c, 0, H - c, 1, 0)
    Rivets(ctx, W, top + c, W, H - c, -1, 0)
    Rivets(ctx, c, H, W - c, H, 0, -1)
    local x = c
    for _, s in ipairs(spec.steps) do
        Run("top", x, top, s.x0 - x, b)
        Rivets(ctx, x, top, s.x0, top, 0, 1)
        Put(ctx, "jl", s.x0, top, nil, nil, "BORDER", 1)
        Put(ctx, "jr", s.x1 - b, top, nil, nil, "BORDER", 1)
        Put(ctx, "tl", s.x0, s.y0, nil, nil, "BORDER", 1)
        Put(ctx, "tr", s.x1 - c, s.y0, nil, nil, "BORDER", 1)
        Run("top", s.x0 + c, s.y0, s.x1 - s.x0 - 2 * c, b)
        Run("left", s.x0, s.y0 + c, b, top - s.y0 - c)
        Run("right", s.x1 - b, s.y0 + c, b, top - s.y0 - c)
        Rivets(ctx, s.x0 + c, s.y0, s.x1 - c, s.y0, 0, 1)
        x = s.x1
    end
    Run("top", x, top, W - c - x, b)
    Rivets(ctx, x, top, W - c, top, 0, 1)
end

-- A pillar from the top moulding to the bottom one at x, its stone at y (the pieces' own offsets: the generator cut
-- them 14, 10, 14 and 16 px left of the pillar's middle, the stone's middle 18 px down its piece).
local function Pillar(ctx, x, top, H, studY)
    local u = ctx.u
    local P = ctx.s.p
    if not P.post_top then return end
    Put(ctx, "post_top", x - 14 * u, top, nil, nil, "BORDER", 4)
    Put(ctx, "post_bot", x - 14 * u, H - P.post_bot[4] * u, nil, nil, "BORDER", 4)
    local y0, y1 = top + P.post_top[4] * u, H - P.post_bot[4] * u
    Put(ctx, "post_mid", x - 10 * u, y0, nil, y1 - y0, "BORDER", 3, nil, "y")
    if studY then Put(ctx, "stud", x - 16 * u, studY - 18 * u, nil, nil, "BORDER", 5) end
end

-- A well under one button's cell (x, y, s: the cell is the button and half a gap round it).
local function Well(ctx, cell)
    local kind = ctx.s.cells
    if kind == "client" then
        Quad(ctx.pool, ctx.f, DWARF, 42 / 256, 84 / 256, 148 / 256, 190 / 256, cell.x, cell.y, cell.s, cell.s, "BACKGROUND", -4)
    elseif kind == "slot" then
        local ins = 4 * ctx.u
        Quad(ctx.pool, ctx.f, BANK, 8 / 128, 44 / 128, 6 / 512, 41 / 512, cell.x + ins, cell.y + ins,
            cell.s - 2 * ins, cell.s - 2 * ins, "BACKGROUND", -4)
        Nine(ctx, "well_", cell.x, cell.y, cell.s, cell.s, "BACKGROUND", -3)
    else
        Nine(ctx, "well_", cell.x, cell.y, cell.s, cell.s, "BACKGROUND", -3)
    end
end

-- The experience slot: a tray round it (the bar sits in it while shown), the band in it (max level).
local function Band(ctx, spec, bandPool)
    local bx = spec.band
    if not bx then return end
    local k, u = ctx.k, ctx.u
    local out = 4 * u
    local tx, ty, tw, th = bx.x - 2 * k, bx.y - 1.5 * k, bx.w + 4 * k, bx.h + 3 * k
    Nine(ctx, "tray_", tx - out, ty - out, tw + 2 * out, th + 2 * out, "BACKGROUND", -5)
    local f = ctx.f
    if ctx.s.band == "client" then
        local h = bx.h
        Tile(bandPool, f, MAXLEVEL, 256, 32, { 0, 2, 256, 27 }, bx.x, bx.y, bx.w, h, 256 * h / 27, h, "BACKGROUND", -1)
    else
        local P = ctx.s.p.fill
        if P then
            Tile(bandPool, f, ctx.file, ctx.s.w, ctx.s.h, P, bx.x, bx.y, bx.w, bx.h, P[3] * bx.h / P[4], bx.h,
                "BACKGROUND", -1)
        end
    end
end

-- What the Dock's grid holds for the art (dock units): the plate's top, the crown's steps, the cells under the
-- buttons, the clusters' boxes, the pillars' places, the experience slot.
function Art:Spec(T, g, rows)
    local S, G, P, s = T.S, T.G, T.P, T.s
    local d = Data()
    local k = S / 36
    local spec = { k = k, w = g.w, h = g.h, top = g.plateTop, steps = {}, cells = {}, boxes = {}, posts = {},
                   junctions = {} }
    -- the crown's steps: its buttons' box grown by P to the sides and up (the moulding, a gap, half a cell), from the
    -- plate's top; the stance and pet steps one when they would nearly touch
    local function Step(list)
        if #list == 0 then return nil end
        local x0, x1 = list[1][1], list[#list][1] + s
        return { x0 = x0 - P, x1 = x1 + P, y0 = max(0, list[1][2] - P) }
    end
    local a, b = Step(g.stance), Step(g.pet)
    local gap = 2 * d.C * k / d.d
    if a and b and b.x0 - a.x1 < gap then
        a = { x0 = min(a.x0, b.x0), x1 = max(a.x1, b.x1), y0 = min(a.y0, b.y0) }
        b = nil
    end
    if a then spec.steps[#spec.steps + 1] = a end
    if b then spec.steps[#spec.steps + 1] = b end
    table.sort(spec.steps, function(p, q) return p.x0 < q.x0 end)
    -- the cells: the block's, the bags', the crown's
    local cell = S + G
    for r = 1, rows do
        for c = 1, 12 do
            spec.cells[#spec.cells + 1] = { x = g.block.x - G / 2 + (c - 1) * cell, y = g.rows[r] - G / 2, s = cell }
        end
    end
    spec.junctions[1] = { x = g.block.x - G / 2, y = g.block.y - G / 2, cols = 12, rows = rows, cell = cell }
    for _, p in ipairs(g.bags) do spec.cells[#spec.cells + 1] = { x = p[1] - G / 2, y = p[2] - G / 2, s = cell } end
    for _, list in ipairs({ g.stance, g.pet }) do
        for _, p in ipairs(list) do spec.cells[#spec.cells + 1] = { x = p[1] - G / 2, y = p[2] - G / 2, s = s + G } end
    end
    -- the clusters (trays sink round them: the cells' outer edge)
    local B = spec.boxes
    if #g.bags > 0 then
        local x0, x1 = math.huge, -math.huge
        for _, p in ipairs(g.bags) do x0, x1 = min(x0, p[1]), max(x1, p[1] + S) end
        B.bags = { x = x0 - G / 2, y = g.block.y - G / 2, w = x1 - x0 + G, h = g.block.h + G }
    end
    B.block = { x = g.block.x - G / 2, y = g.block.y - G / 2, w = g.block.w + G, h = g.block.h + G }
    if g.pager then
        B.pager = { x = g.pager.x - 2 * k, y = g.pager.y - 2 * k, w = g.pager.w + 4 * k, h = g.pager.h + 4 * k }
        B.block = { x = g.pager.x - G / 2, y = B.block.y, w = B.block.x + B.block.w - (g.pager.x - G / 2), h = B.block.h }
    end
    if g.menuW and g.menuW > 0 then
        B.menu = { x = g.menuX - G / 2, y = g.block.y - G / 2, w = g.menuW + G, h = g.block.h + G }
    end
    B.crown = {}
    for _, list in ipairs({ g.stance, g.pet }) do
        if #list > 0 then
            B.crown[#B.crown + 1] = { x = list[1][1] - G / 2, y = list[1][2] - G / 2,
                                      w = list[#list][1] + s - list[1][1] + G, h = s + G }
        end
    end
    for i, x in ipairs(g.seams or {}) do spec.posts[i] = x end
    spec.studY = g.block.y + g.block.h / 2
    -- the experience slot (and the reputation bar under it)
    local xp = g.xp
    spec.band = { x = xp.x, y = xp.y, w = xp.w, h = xp.h + (g.rep and (g.rep.y + g.rep.h - xp.y - xp.h) or 0) }
    return spec
end

-- The rail (action bars 4 and 5): a plate round `cols` columns of 12 cells.
function Art:RailSpec(T, cols)
    local S, G, P = T.S, T.G, T.P
    local cell = S + G
    local w, h = cols * S + (cols - 1) * G + 2 * P, 12 * S + 11 * G + 2 * P
    local spec = { k = S / 36, w = w, h = h, top = 0, steps = {}, cells = {}, boxes = { crown = {} }, posts = {},
                   junctions = { { x = P - G / 2, y = P - G / 2, cols = cols, rows = 12, cell = cell } } }
    for c = 1, cols do
        for r = 1, 12 do
            spec.cells[#spec.cells + 1] = { x = P - G / 2 + (c - 1) * cell, y = P - G / 2 + (r - 1) * cell, s = cell }
        end
    end
    spec.boxes.block = { x = P - G / 2, y = P - G / 2, w = cols * cell, h = 12 * cell }
    return spec
end

-- Draws the chosen set on the dock frame f (or the rail) from a spec (Art:Spec / Art:RailSpec).
function Art:Draw(f, spec)
    local d = Data()
    local key = self:Set()
    local s = d[key]
    local pool = Begin(f, "dzArt")
    local bandPool = Begin(f, "dzBand")
    local ctx = { f = f, pool = pool, s = s, file = MEDIA .. key, u = spec.k / d.d, k = spec.k }
    local W, H, top = spec.w, spec.h, spec.top
    -- the ground: the set's tile over the plate and each step (a pixel in from the edge: the moulding's rim is its own)
    local gt = 128 * spec.k
    local gfile = MEDIA .. key .. "_ground"
    Ground(pool, f, gfile, 1, top + 1, W - 2, H - top - 2, gt, gt, "BACKGROUND", -7)
    for _, st in ipairs(spec.steps) do
        Ground(pool, f, gfile, st.x0 + 1, st.y0 + 1, st.x1 - st.x0 - 2, top - st.y0, gt, gt, "BACKGROUND", -7)
    end
    -- trays: Stormwind sinks every cluster (a gilt rim); the others the menu's and the pager's
    local out = 4 * ctx.u
    local B = spec.boxes
    local trays = {}
    if s.cells == "soft" then
        for _, name in ipairs({ "bags", "block", "menu" }) do if B[name] then trays[#trays + 1] = B[name] end end
        for _, c in ipairs(B.crown or {}) do trays[#trays + 1] = c end
    else
        if B.menu then trays[#trays + 1] = B.menu end
        if B.pager then trays[#trays + 1] = B.pager end
    end
    for _, t in ipairs(trays) do Nine(ctx, "tray_", t.x - out, t.y - out, t.w + 2 * out, t.h + 2 * out, "BACKGROUND", -5) end
    if s.cells == "soft" and B.pager then
        Nine(ctx, "well_", B.pager.x, B.pager.y, B.pager.w, B.pager.h, "BACKGROUND", -3)
    end
    for _, cell in ipairs(spec.cells) do Well(ctx, cell) end
    -- (the vault: a brass stud where four slots meet)
    if s.cells == "slot" and s.p.junction then
        local half = 8 * ctx.u
        for _, j in ipairs(spec.junctions) do
            for r = 0, j.rows do
                for c = 0, j.cols do
                    Put(ctx, "junction", j.x + c * j.cell - half, j.y + r * j.cell - half, nil, nil, "BACKGROUND", -2)
                end
            end
        end
    end
    Band(ctx, spec, bandPool)
    Moulding(ctx, spec)
    for _, x in ipairs(spec.posts) do Pillar(ctx, x, top, H, spec.studY) end
    Finish(pool)
    Finish(bandPool)
    f.dzArtOn = true
    self:ShowBand(f)
    -- a soft shadow under the plate on the world
    if f.floor then
        f.floor:ClearAllPoints()
        f.floor:SetPoint("CENTER", f, "TOPLEFT", W / 2, -(top + H) / 2 - 3)
        f.floor:SetSize(W + 70, H - top + 50)
        f.floor:SetVertexColor(0, 0, 0, 0.55)
        f.floor:Show()
    end
end

-- Off this frame (another look, the art pack missing, the Dock off).
function Art:Clear(f)
    if not f then return end
    for _, field in ipairs({ "dzArt", "dzBand" }) do
        local pool = f[field]
        if pool then for _, t in ipairs(pool.t) do t:Hide() end; pool.n = 0 end
    end
    f.dzArtOn = false
end

-- True while the art is drawn on f.
function Art:Drawn(f) return f and f.dzArtOn and true or false end

-- The experience bar is shown (LookBars:XPUpdate): the band in its slot only while it is not.
function Art:XPShown(on)
    self.xpShown = on and true or false
    if ns.LookDock and ns.LookDock.f then self:ShowBand(ns.LookDock.f) end
end

function Art:ShowBand(f)
    local pool = f and f.dzBand
    if not pool then return end
    local show = f.dzArtOn and not self.xpShown
    for i = 1, pool.n do pool.t[i]:SetShown(show) end
end
