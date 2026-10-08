if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIWorld.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIWorld.lua
-- CraftUI's world view: WoW's own ground and scenery (the generated Northshire pages), every unit as its model's
-- sprite (Media/Azeromon/mobs.blp: you in your class's start outfit, NPCs and creatures from their models), all
-- drawn back to front by where they stand; the target's selection circle, name plates, quest markers, floating
-- combat text, missiles and impacts, chat bubbles, the corpse's sparkle. Mouse: left-click targets, right-click
-- talks / attacks / loots, the wheel zooms, hovering shows the unit's tooltip and WoW's cursors.
local addonName, ns = ...

local UI = ns.CraftUI
local K = UI.Kit
local Craft = ns.Craft
local D = Craft.D
local Combat = Craft.Combat
local WS = ns.AzeroLand
local W = ns.AzeroWorldData

local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt
local Now = Craft.Now

local MOBS = K.MEDIA .. "mobs.blp"
local MOBS_ACT = K.MEDIA .. "mobs_act.blp"      -- the same bodies' action frames (see SpriteCoords)
local FACE_ROW = { down = 0, left = 1, right = 2, up = 3 }
UI.TILE = 32
local TILE = 32
local view, canvas, top                 -- the clip frame, the map's frame, the frame over it (names, numbers)
local VW, VH = 800, 600                 -- the view's size in pixels
local grid = {}                         -- ground cells
local scen, scenUsed = {}, 0
local camX, camY = 0, 0

---------------------------------------------------------------------------
-- Sprites from the model sheet
---------------------------------------------------------------------------

local function SheetH() return (ns.AzeroData and ns.AzeroData.MOB_SHEET_H) or 2048 end

-- the sheet slot of a unit's body
function UI.SpriteOf(u)
    if u.kind == "player" or u.kind == "remote" then
        local spr = ns.AzeroData and ns.AzeroData.CLASS_SPR
        local tok = Craft.CLASS_TOKENS[u.class] or "WARRIOR"
        local sex = (u.char and u.char.sex) or u.sex or 0
        return spr and spr[tok .. sex] or 35
    end
    if u.sprite then return u.sprite end
    local S = ns.AzeroData and ns.AzeroData.worldSpecies
    local key = S and S._byEntry and S._byEntry[u.entry]
    local sp = key and S[key]
    u.sprite = sp and sp.spr or 0
    return u.sprite
end

-- a body's cell: mobs.blp holds 3 walk frames (stride, stand, stride) x 4 facings, 5 bodies a row (512 wide);
-- mobs_act.blp the same bodies in the same rows with 5 action frames each (1024 wide): 0 the swing's wind-up,
-- 1 the strike, 2 a spell readied, 3 the spell let go, 4 the corpse - all posed from the model's own animations
local ACT = { windup = 0, strike = 1, ready = 2, release = 3, dead = 4 }
local function SpriteCoords(r, spr, face, frame, act)
    local H = SheetH()
    local row = floor(spr / 5) * 4 + (FACE_ROW[face] or 0)
    local tp, b = row * 32 / H, (row + 1) * 32 / H
    if act then
        local c = (spr % 5) * 5 + act
        r.file, r.l, r.r = MOBS_ACT, c * 32 / 1024, (c + 1) * 32 / 1024
    else
        local c = (spr % 5) * 3 + frame
        r.file, r.l, r.r = MOBS, c * 32 / 512, (c + 1) * 32 / 512
    end
    r.t, r.b = tp, b
end

---------------------------------------------------------------------------
-- Depth: everything standing on the ground (bodies, scenery, an interior's walls, objects) is drawn back to front
-- by the ground row it stands on. One frame's draw layers give 32 ordered slots (BORDER / ARTWORK sublevels), too
-- few for a busy screen - a body and the wall just in front of it could share one and draw either way round - so
-- DEPTH_FRAMES frames are stacked over the map, 32 slots each, and only distinct rows need distinct slots.
-- Each frame the drawing code asks for pictures (Draw), and FlushDepth hands them textures from the right frame.
---------------------------------------------------------------------------

local DEPTH_FRAMES = 8
local depthFrames, depthPools = {}, {}
local reqs, nreq = {}, 0
local order = {}
UI.depthOrder = order               -- (the last frame's pictures back to front: for the test suites)

-- a picture to draw this frame at depth `sort`: fill in file, l / r / t / b (or c8 = 8 coords), w, h, pt, x, y
-- (pixels from the map's top-left), and optionally alpha, cr / cg / cb, blend
local function Draw(sort)
    nreq = nreq + 1
    local r = reqs[nreq]
    if not r then r = {} reqs[nreq] = r end
    r.sort, r.idx = sort, nreq
    r.c8, r.alpha, r.cr, r.cg, r.cb, r.blend, r.pt = nil, 1, 1, 1, 1, "BLEND", "TOPLEFT"
    return r
end
UI.DepthDraw = Draw

local function FlushDepth()
    for i = #order, 1, -1 do order[i] = nil end
    for i = 1, nreq do order[i] = reqs[i] end
    table.sort(order, function(a, b)
        if a.sort ~= b.sort then return a.sort < b.sort end
        return a.idx < b.idx
    end)
    local uniq, last = 0, nil
    for _, r in ipairs(order) do
        if r.sort ~= last then uniq = uniq + 1 last = r.sort end
        r.rank = uniq
    end
    local total = DEPTH_FRAMES * 32
    local used = {}
    for _, r in ipairs(order) do
        local slot = uniq <= total and (r.rank - 1) or floor((r.rank - 1) * total / uniq)
        local f = floor(slot / 32) + 1
        local s = slot % 32
        local n = (used[f] or 0) + 1
        used[f] = n
        local pool = depthPools[f]
        local t = pool[n]
        if not t then
            t = depthFrames[f]:CreateTexture(nil, "ARTWORK")
            pool[n] = t
        end
        if t.file ~= r.file then t:SetTexture(r.file) t.file = r.file end
        local c = r.c8
        if c then t:SetTexCoord(c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8])
        else t:SetTexCoord(r.l, r.r, r.t, r.b) end
        t:SetSize(r.w, r.h)
        t:ClearAllPoints()
        t:SetPoint(r.pt, depthFrames[f], "TOPLEFT", r.x, -r.y)
        t:SetVertexColor(r.cr, r.cg, r.cb)
        t:SetAlpha(r.alpha)
        if t.blend ~= r.blend then t:SetBlendMode(r.blend) t.blend = r.blend end
        if s < 16 then t:SetDrawLayer("BORDER", s - 8) else t:SetDrawLayer("ARTWORK", s - 24) end
        t:Show()
    end
    for f = 1, DEPTH_FRAMES do
        local pool = depthPools[f]
        for i = (used[f] or 0) + 1, #pool do pool[i]:Hide() end
    end
    nreq = 0
end

---------------------------------------------------------------------------
-- Building the view
---------------------------------------------------------------------------

local overlay = {}              -- name plates and friends, pooled per unit guid
local fct = {}                  -- floating combat text
local fctPool = {}
local effects = {}              -- glows: missiles, impacts, rings

function UI.BuildWorld(parent)
    view = CreateFrame("Frame", nil, parent)
    view:SetAllPoints()
    pcall(view.SetClipsChildren, view, true)
    view:EnableMouse(true)
    view:EnableMouseWheel(true)
    view.bg = K.Tex(view, "BACKGROUND")
    view.bg:SetAllPoints()
    view.bg:SetColorTexture(0, 0, 0, 1)
    canvas = CreateFrame("Frame", nil, view)
    canvas:SetAllPoints()
    -- the depth frames (bodies, scenery, walls: see FlushDepth), then the glows, then names and numbers
    for f = 1, DEPTH_FRAMES do
        local d = CreateFrame("Frame", nil, view)
        d:SetAllPoints()
        d:SetFrameLevel(canvas:GetFrameLevel() + f)
        depthFrames[f], depthPools[f] = d, {}
    end
    local fx = CreateFrame("Frame", nil, view)
    fx:SetAllPoints()
    fx:SetFrameLevel(canvas:GetFrameLevel() + DEPTH_FRAMES + 1)
    top = CreateFrame("Frame", nil, view)
    top:SetAllPoints()
    top:SetFrameLevel(canvas:GetFrameLevel() + DEPTH_FRAMES + 3)
    UI.view, UI.canvas, UI.top, UI.fxLayer = view, canvas, top, fx
    -- the target's circle (under every body)
    UI.circle = K.Tex(canvas, "BACKGROUND", "Interface\\SelectionCircle\\Selection_SelectionA", 6)
    UI.circle:SetBlendMode("ADD")
    UI.circle:Hide()
    UI.hoverCircle = K.Tex(canvas, "BACKGROUND", "Interface\\SelectionCircle\\Selection_SelectionA", 5)
    UI.hoverCircle:SetBlendMode("ADD")
    UI.hoverCircle:Hide()
    -- the ghost world: grey and cold
    UI.ghostTint = K.Tex(top, "BACKGROUND")
    UI.ghostTint:SetAllPoints()
    UI.ghostTint:SetColorTexture(0.55, 0.62, 0.7, 0.42)
    UI.ghostTint:Hide()
    UI.corpseMark = K.Tex(top, "OVERLAY", "Interface\\Minimap\\POIIcons")
    UI.corpseMark:SetSize(24, 24)
    UI.corpseMark:Hide()
    UI.corpseMark.text = K.Font(top, 11, "OUTLINE")
    UI.corpseMark.text:SetPoint("TOP", UI.corpseMark, "BOTTOM", 0, -2)
    UI.corpseMark.text:SetText("Your corpse")
    UI.corpseMark.text:Hide()
    view:SetScript("OnMouseWheel", function(_, d)
        UI.zoom = Craft.Clamp((UI.zoom or 1) + d * 0.1, 0.6, 1.8)
        Craft:Data().zoomf = UI.zoom
    end)
    view:SetScript("OnMouseDown", function(_, button) UI.WorldClick(button) end)
    view:SetScript("OnLeave", function() UI.hover = nil K.HideTooltip() if ResetCursor then ResetCursor() end end)
    UI.zoom = Craft:Data().zoomf or 1
end

-- world point -> view pixel (top-left origin)
local function ToScreen(x, y)
    return (x - camX) * TILE + VW / 2, (y - camY) * TILE + VH / 2
end
UI.ToScreen = ToScreen

-- the cursor's world point
function UI.CursorWorld()
    local cx, cy = GetCursorPosition()
    local s = view:GetEffectiveScale()
    local l, t = view:GetLeft(), view:GetTop()
    if not l then return nil end
    local px, py = cx / s - l, t - cy / s
    return camX + (px - VW / 2) / TILE, camY + (py - VH / 2) / TILE, px, py
end

---------------------------------------------------------------------------
-- The ground
---------------------------------------------------------------------------

local function Cell(i, j)
    local col = grid[i]
    if not col then col = {} grid[i] = col end
    local c = col[j]
    if not c then
        c = K.Tex(canvas, "BACKGROUND", nil, 0)
        col[j] = c
    end
    return c
end

local function DrawGround(map, cols, rows)
    local fx, fy = floor(camX - cols / 2), floor(camY - rows / 2)
    for i = 0, cols + 1 do
        for j = 0, rows + 1 do
            local c = Cell(i, j)
            local wx, wy = fx + i - 1, fy + j - 1
            local file, slot, row
            if map == "world" then file, slot, row = WS.GroundTile(wx, wy) end
            if file then
                if c.file ~= file then c:SetTexture(file) c.file = file c.slot = nil end
                if c.slot ~= slot then
                    c.slot = slot
                    local cc, rr, h = slot % row, floor(slot / row), 0.5 / 1024
                    c:SetTexCoord(cc / row + h, (cc + 1) / row - h, rr / row + h, (rr + 1) / row - h)
                end
                local sx, sy = ToScreen(wx, wy)
                c:ClearAllPoints()
                c:SetPoint("TOPLEFT", canvas, "TOPLEFT", floor(sx + 0.5), -floor(sy + 0.5))
                c:SetSize(TILE + 1, TILE + 1)
                c:Show()
            else
                c:Hide()
            end
        end
    end
    -- cells beyond the view (it shrank / zoomed in)
    for i, col in pairs(grid) do
        for j, c in pairs(col) do
            if i > cols + 1 or j > rows + 1 then c:Hide() end
        end
    end
end

---------------------------------------------------------------------------
-- Name plates, markers, bars: one bundle per unit
---------------------------------------------------------------------------

local function Plate(guid)
    local o = overlay[guid]
    if o then return o end
    o = {}
    o.name = K.Font(top, 11, "OUTLINE")
    o.title = K.Font(top, 9, "OUTLINE")
    o.quest = K.Tex(top, "OVERLAY")
    o.quest:SetSize(22, 22)
    o.bar = K.Bar(top, 56, 6, 1, 0.1, 0.1)
    o.bar.text:Hide()
    o.bar.border = K.Tex(o.bar, "OVERLAY", "Interface\\Tooltips\\Nameplate-Border")
    o.bar.border:SetPoint("TOPLEFT", -4, 4)
    o.bar.border:SetPoint("BOTTOMRIGHT", 22, -6)
    o.bar.border:Hide()
    o.sparkle = K.Tex(top, "OVERLAY", "Interface\\Cooldown\\star4")
    o.sparkle:SetBlendMode("ADD")
    o.sparkle:SetSize(26, 26)
    o.stun = K.Tex(top, "OVERLAY", "Interface\\Cooldown\\star4")
    o.stun:SetBlendMode("ADD")
    o.stun:SetVertexColor(1, 1, 0.3)
    o.shield = K.Tex(UI.fxLayer, "OVERLAY", "Spells\\GENERICGLOW64", 3)
    o.shield:SetBlendMode("ADD")
    o.shield:SetVertexColor(1, 0.95, 0.6, 0.6)
    overlay[guid] = o
    return o
end

local function HidePlate(o)
    o.name:Hide() o.title:Hide() o.quest:Hide() o.bar:Hide() o.sparkle:Hide() o.stun:Hide() o.shield:Hide()
    o.used = false
end

local REACT = { hostile = { 1, 0.1, 0.1 }, neutral = { 1, 1, 0 }, friendly = { 0.1, 1, 0.1 } }

---------------------------------------------------------------------------
-- Floating combat text and spell effects
---------------------------------------------------------------------------

function UI.FCT(u, text, r, g, b, crit, big)
    if not top then return end
    local fs = table.remove(fctPool)
    if not fs then fs = K.Font(top, 16, "OUTLINE") end
    fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", crit and 22 or (big and 18 or 15), "OUTLINE")
    fs:SetText(text)
    fs:SetTextColor(r or 1, g or 1, b or 1)
    fs:Show()
    fct[#fct + 1] = { fs = fs, u = u, x = u.x, y = u.y, map = u.map, t0 = Now(), crit = crit,
                      dx = (math.random() - 0.5) * 18 }
end

local glowPool = {}
local function Glow(layer)
    local t = table.remove(glowPool)
    if not t then
        t = K.Tex(UI.fxLayer, "OVERLAY", "Spells\\GENERICGLOW64", layer or 4)
        t:SetBlendMode("ADD")
    end
    t:Show()
    return t
end

-- an effect at a unit or flying between two: kind = "missile" | "impact" | "ring" | "pillar"
function UI.Effect(e)
    if not canvas then return end
    e.t0 = Now()
    e.tex = Glow()
    if e.kind == "ring" then e.tex:SetTexture("Interface\\Minimap\\Ping\\ping5") e.tex:SetBlendMode("ADD") end
    effects[#effects + 1] = e
end

local function DrawEffects()
    local now = Now()
    for i = #effects, 1, -1 do
        local e = effects[i]
        local done = false
        local t = e.tex
        local col = e.color or { 1, 1, 1 }
        if e.kind == "missile" then
            local m = e.m
            local dst = m.dst
            local sp = D.spells[m.spell]
            if not dst or dst.dead and now - (m.start or 0) > 3 then done = true else
                local d = Craft.Dist(m.from[1], m.from[2], dst.x, dst.y)
                local f = min(1, (now - m.start) * (sp.speed or 20) / max(0.1, d))
                local x = m.from[1] + (dst.x - m.from[1]) * f
                local y = (m.from[2] - 0.9) + ((dst.y - 0.9) - (m.from[2] - 0.9)) * f      -- (chest high)
                local sx, sy = ToScreen(x, y)
                t:ClearAllPoints()
                t:SetPoint("CENTER", canvas, "TOPLEFT", sx, -sy)
                t:SetSize(TILE * 0.9, TILE * 0.9)
                t:SetVertexColor(col[1], col[2], col[3], 1)
                if f >= 1 or e.landed then done = true end
            end
        else
            local age = now - e.t0
            local dur = e.dur or 0.35
            if age >= dur or not e.u then done = true else
                local f = age / dur
                -- (a ring lies round the feet; a flash is chest high; a pillar rises from the feet)
                local sx, sy = ToScreen(e.u.x, e.u.y - (e.kind == "pillar" and 1.1 or (e.kind == "ring" and 0 or 0.8)))
                t:ClearAllPoints()
                t:SetPoint("CENTER", canvas, "TOPLEFT", sx, -sy)
                local size = e.kind == "ring" and (TILE * (0.5 + (e.radius or 2) * 2 * f)) or
                             (e.kind == "pillar" and TILE * 1.6 or TILE * (1 + f))
                if e.kind == "pillar" then t:SetSize(TILE * 1.2, TILE * 3) else t:SetSize(size, size * (e.kind == "ring" and 0.55 or 1)) end
                t:SetVertexColor(col[1], col[2], col[3], 1 - f)
            end
        end
        if done then
            t:Hide()
            glowPool[#glowPool + 1] = t
            table.remove(effects, i)
        end
    end
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

local function UnitFrame(u, now)
    if u.moving then return floor(now * 7) % 4 == 0 and 0 or (floor(now * 7) % 4 == 2 and 2 or 1) end
    return 1
end

-- the action pose a body shows now (ACT column), or nil for its walk frames: the swing for a moment after each
-- melee blow (wind-up, then the strike), the spell readied while casting, let go for a moment after, the corpse
local SWING_WINDUP, SWING_TIME, RELEASE_TIME = 0.08, 0.34, 0.3
local function UnitPose(u, now)
    if u.dead and not u.ghost then return ACT.dead end
    local s = u.swungAt and now - u.swungAt
    if s and s < SWING_TIME then return s < SWING_WINDUP and ACT.windup or ACT.strike end
    local c = u.casting
    if c then return c.channel and ACT.release or ACT.ready end
    if u.castDoneAt and now - u.castDoneAt < RELEASE_TIME then return ACT.release end
    return nil
end
UI.UnitPose = UnitPose

-- a scenery / interior sprite's picture: half a texel in from each edge (filtering there read the page around the
-- piece: a dark seam), the drawn box shrunk to match
local function ScenPicture(r, sc, px16)
    local s = sc.sp
    r.file = sc.file
    r.l, r.r, r.t, r.b = (s.u + 0.5) / 1024, (s.u + s.w - 0.5) / 1024, (s.v + 0.5) / 1024, (s.v + s.h - 0.5) / 1024
    r.w, r.h = (s.w - 1) * px16, (s.h - 1) * px16
    local sx, sy = ToScreen(sc.x, sc.y)
    r.pt, r.x, r.y = "TOPLEFT", sx - (s.ox - 0.5) * px16, sy - (s.oy - 0.5) * px16
end

function UI.DrawWorld(dt)
    local p = Craft.player
    if not p or not view then return end
    VW, VH = UI.PanelSize()
    -- about 17 tiles across the panel at the normal zoom (the wheel zooms 0.6x - 1.8x)
    TILE = floor(Craft.Clamp(VW / 17, 30, 80) * (UI.zoom or 1) + 0.5)
    UI.TILE = TILE
    camX, camY = p.x, p.y - 0.8
    local cols, rows = math.ceil(VW / TILE) + 1, math.ceil(VH / TILE) + 1
    local map = p.map
    local now = Now()
    -- ground (outdoors); an interior is its own picture on black
    if map == "world" then DrawGround(map, cols, rows)
    else for _, col in pairs(grid) do for _, c in pairs(col) do c:Hide() end end end
    -- scenery (trees, houses, fences); in an interior its floor under everyone and its walls in depth slices
    scenUsed = 0
    local x0, y0 = camX - cols / 2 - 1, camY - rows / 2 - 1
    local x1, y1 = x0 + cols + 2, y0 + rows + 2
    local list
    if map == "world" then list = WS.SceneryIn(x0, y0, x1, y1)
    else local m = Craft.World.interiors[map] list = m and m.art or {} end
    local feetX, feetY = p.x, p.y
    -- your body's box on the screen (the walls in front of it fade)
    local psx, psy = ToScreen(p.x, p.y)
    local pl, pr, pt, pb = psx - TILE * 0.35, psx + TILE * 0.35, psy - TILE * 0.95, psy
    for _, sc in ipairs(list) do
        local s, k = sc.sp, sc.k
        local kk = k / sc.pxt
        local l, tt = sc.x - s.ox * kk, sc.y - s.oy * kk
        if l < x1 and l + s.w * kk > x0 and tt < y1 and tt + s.h * kk > y0 then
            local px16 = TILE / sc.pxt * k
            if map ~= "world" and not sc.wall then
                -- an interior's floor: under every body
                scenUsed = scenUsed + 1
                local t = scen[scenUsed]
                if not t then t = K.Tex(canvas, "BACKGROUND", nil, 1) scen[scenUsed] = t end
                if t.file ~= sc.file then t:SetTexture(sc.file) t.file = sc.file end
                local q = {}
                ScenPicture(q, sc, px16)
                t:SetTexCoord(q.l, q.r, q.t, q.b)
                t:SetSize(q.w, q.h)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", canvas, "TOPLEFT", q.x, -q.y)
                t:SetAlpha(1)
                t:Show()
            else
                local r = Draw(sc.sort)
                ScenPicture(r, sc, px16)
                -- a wall in front of you that hides you turns see-through where it covers you (only the slices on
                -- you, so the room keeps its walls); a tree crown fades the same way
                if sc.wall and sc.sort > feetY and r.x < pr and r.x + r.w > pl and r.y < pb and r.y + r.h > pt then
                    r.alpha = 0.4
                elseif sc.tree and sc.sort > feetY then
                    local R = 2.5
                    if feetX + R >= l and feetX - R <= l + s.w * kk and feetY - 0.5 + R >= tt and feetY - 0.5 - R <= tt + s.h * kk then
                        r.alpha = 0.3
                    end
                end
            end
        end
    end
    for i = scenUsed + 1, #scen do scen[i]:Hide() end
    -- units
    local seen = {}
    local halfW, halfH = cols / 2 + 2, rows / 2 + 2
    for _, u in pairs(Combat.units) do
        if u.map == map and abs(u.x - camX) < halfW and abs(u.y - camY) < halfH and
           not (u.rec and u.rec.hidden) and not (u.ghost and u ~= p) then
            local spr = UI.SpriteOf(u)
            local r = Draw(u.y)
            local face, frame, pose = u.face or "down", UnitFrame(u, now), UnitPose(u, now)
            SpriteCoords(r, spr, face, frame, pose)
            local size = TILE
            if u.cc then size = TILE * 0.8 end
            r.w, r.h = size, size
            -- the body stands on its feet: the sprite's bottom row on the unit's point
            local sx, sy = ToScreen(u.x, u.y)
            r.pt, r.x, r.y = "BOTTOM", sx, sy + 0.06 * TILE
            -- a player in their gear (Outfit.lua): the bare body instead of the class sprite, each worn piece over
            -- it, cut from the same 32 px cell
            local layers = (u.kind == "player" or u.kind == "remote") and UI.OutfitLayers and
                           UI.OutfitLayers(u, pose and "act" or "walk", pose or frame, FACE_ROW[face] or 0)
            local worn
            if layers and layers[1] then
                worn = {}
                local k = size / 32
                local left, topY = sx - size / 2, r.y - size
                for i, L in ipairs(layers) do
                    local q = i == 1 and r or Draw(u.y)
                    q.file, q.l, q.r, q.t, q.b = L[1], L[2], L[3], L[4], L[5]
                    q.pt, q.x, q.y, q.w, q.h = "TOPLEFT", left + L[6] * k, topY + L[7] * k, L[8] * k, L[9] * k
                    if i > 1 then worn[#worn + 1] = q end
                end
            end
            -- tints: dead grey, a ghost pale, hit flashes red, a sheep white, slowed blue
            if u.dead and not u.ghost then r.cr, r.cg, r.cb = 0.62, 0.62, 0.62
            elseif u.ghost then r.cr, r.cg, r.cb, r.alpha = 0.7, 0.85, 1, 0.6
            elseif u.flashUntil and now < u.flashUntil then r.cr, r.cg, r.cb = 1, 0.45, 0.45
            elseif u.cc then r.cr, r.cg, r.cb = 1, 0.85, 1
            elseif (u.speedMult or 1) < 1 then r.cr, r.cg, r.cb = 0.7, 0.85, 1 end
            for _, q in ipairs(worn or {}) do q.cr, q.cg, q.cb, q.alpha = r.cr, r.cg, r.cb, r.alpha end
            seen[u.guid] = true
            -- the plate over the head
            local o = Plate(u.guid)
            o.used = true
            local headY = sy - ((u.dead and not u.ghost) and 0.55 or 1.05) * TILE
            local react = Combat.Reaction(p, u)
            local isPlayer = Combat.IsPlayer(u)
            local showName = (u.kind == "npc") or isPlayer or u == p.target or u == UI.hover or
                             (u.inCombat and u.target == p)
            if u == p then showName = false end
            local y = headY
            if showName then
                local c = REACT[react] or REACT.neutral
                if isPlayer then
                    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[Craft.CLASS_TOKENS[u.class] or ""]
                    c = cc and { cc.r, cc.g, cc.b } or { 0.4, 0.6, 1 }
                end
                if u.dead then c = { 0.6, 0.6, 0.6 } end
                if u.title and u.kind == "npc" then
                    o.title:SetText("<" .. u.title .. ">")
                    o.title:SetTextColor(0.9, 0.9, 0.9)
                    o.title:ClearAllPoints()
                    o.title:SetPoint("BOTTOM", top, "TOPLEFT", sx, -y)
                    o.title:Show()
                    y = y + 11
                else
                    o.title:Hide()
                end
                o.name:SetText(u.name or "")
                o.name:SetTextColor(c[1], c[2], c[3])
                o.name:ClearAllPoints()
                o.name:SetPoint("BOTTOM", top, "TOPLEFT", sx, -y)
                o.name:Show()
                y = y + 13
            else
                o.name:Hide() o.title:Hide()
            end
            -- a health plate on creatures in a fight with you or targeted
            if u.kind == "mob" and not u.dead and (u.inCombat or u == p.target) then
                o.bar:ClearAllPoints()
                o.bar:SetPoint("BOTTOM", top, "TOPLEFT", sx, -(showName and (headY - 2) or headY) + 0)
                o.bar:SetWidth(max(36, TILE * 1.4))
                o.bar:SetValue(u.hp / max(1, u.hpMax))
                local c = REACT[react] or REACT.neutral
                o.bar:SetStatusBarColor(c[1], c[2] * 0.9, c[3])
                o.bar:Show()
                if showName then
                    o.name:ClearAllPoints()
                    o.name:SetPoint("BOTTOM", o.bar, "TOP", 0, 2)
                end
            else
                o.bar:Hide()
            end
            -- quest markers
            local mark, grey
            if u.kind == "npc" and u.entry then mark, grey = Craft.Quests.Marker(u.entry) end
            if mark then
                o.quest:SetTexture(mark == "!" and "Interface\\GossipFrame\\AvailableQuestIcon"
                                   or "Interface\\GossipFrame\\ActiveQuestIcon")
                if o.quest.SetDesaturated then o.quest:SetDesaturated(grey and true or false) end
                o.quest:ClearAllPoints()
                o.quest:SetPoint("BOTTOM", top, "TOPLEFT", sx, -(y + 1))
                o.quest:Show()
            else
                o.quest:Hide()
            end
            -- a lootable corpse sparkles
            if u.dead and u.rec and Craft.Loot.CanLoot(u) then
                o.sparkle:ClearAllPoints()
                o.sparkle:SetPoint("CENTER", top, "TOPLEFT", sx, -(sy - 0.3 * TILE))
                o.sparkle:SetAlpha(0.55 + 0.45 * math.sin(now * 5))
                o.sparkle:Show()
            else
                o.sparkle:Hide()
            end
            -- stunned: stars over the head
            if u.stunned and not u.dead then
                o.stun:ClearAllPoints()
                o.stun:SetPoint("CENTER", top, "TOPLEFT", sx + math.sin(now * 6) * 6, -(headY + 4))
                o.stun:SetSize(18, 18)
                o.stun:Show()
            else
                o.stun:Hide()
            end
            -- Power Word: Shield: a golden bubble
            if Combat.HasAura(u, 69) and not u.dead then
                o.shield:ClearAllPoints()
                o.shield:SetPoint("CENTER", canvas, "TOPLEFT", sx, -(sy - 0.6 * TILE))
                o.shield:SetSize(TILE * 1.5, TILE * 1.5)
                o.shield:Show()
            else
                o.shield:Hide()
            end
        end
    end
    for guid, o in pairs(overlay) do if not seen[guid] and o.used ~= false then HidePlate(o) end end
    -- objects (crates you can pick up, herbs, ore): their item's picture, sparkling when a quest wants them
    UI.DrawObjects(map, halfW, halfH, now)
    -- the target's circle
    local tgt = p.target
    if tgt and tgt.map == map and not (tgt.rec and tgt.rec.hidden) then
        local c = REACT[Combat.Reaction(p, tgt)] or REACT.neutral
        if tgt.dead then c = { 0.6, 0.6, 0.6 } end
        local sx, sy = ToScreen(tgt.x, tgt.y)
        UI.circle:ClearAllPoints()
        UI.circle:SetPoint("CENTER", canvas, "TOPLEFT", sx, -(sy - 0.1 * TILE))
        UI.circle:SetSize(TILE * 1.25, TILE * 0.62)
        UI.circle:SetVertexColor(c[1], c[2], c[3], 0.9)
        UI.circle:Show()
    else
        UI.circle:Hide()
    end
    local hv = UI.hover
    if hv and hv ~= tgt and hv.map == map then
        local sx, sy = ToScreen(hv.x, hv.y)
        UI.hoverCircle:ClearAllPoints()
        UI.hoverCircle:SetPoint("CENTER", canvas, "TOPLEFT", sx, -(sy - 0.1 * TILE))
        UI.hoverCircle:SetSize(TILE * 1.2, TILE * 0.6)
        UI.hoverCircle:SetVertexColor(1, 1, 1, 0.35)
        UI.hoverCircle:Show()
    else
        UI.hoverCircle:Hide()
    end
    FlushDepth()
    -- the ghost run: a grey world and the way to your corpse
    UI.ghostTint:SetShown(p.ghost and true or false)
    local c = Craft.char
    if p.ghost and c and c.corpse and c.corpse.map == map then
        local sx, sy = ToScreen(c.corpse.x, c.corpse.y)
        sx, sy = Craft.Clamp(sx, 20, VW - 20), Craft.Clamp(sy, 20, VH - 40)
        UI.corpseMark:ClearAllPoints()
        UI.corpseMark:SetPoint("CENTER", top, "TOPLEFT", sx, -sy)
        UI.corpseMark:SetTexture("Interface\\Minimap\\POIIcons")
        UI.corpseMark:SetTexCoord(0, 0.125, 0, 0.125)
        UI.corpseMark:Show()
        UI.corpseMark.text:Show()
    else
        UI.corpseMark:Hide()
        UI.corpseMark.text:Hide()
    end
    DrawEffects()
    -- floating numbers rise and fade over 1.4 s
    for i = #fct, 1, -1 do
        local f = fct[i]
        local age = now - f.t0
        local dur = f.crit and 1.8 or 1.4
        if age >= dur or f.map ~= map then
            f.fs:Hide()
            fctPool[#fctPool + 1] = f.fs
            table.remove(fct, i)
        else
            local u = f.u
            local x, y = u and u.map == map and u.x or f.x, u and u.map == map and u.y or f.y
            local sx, sy = ToScreen(x, y)
            local rise = age / dur
            local pop = f.crit and (1 + 0.6 * max(0, 1 - age * 6)) or 1
            f.fs:SetScale(pop)
            f.fs:ClearAllPoints()
            f.fs:SetPoint("CENTER", top, "TOPLEFT", (sx + f.dx) / pop, -(sy - TILE * 1.4 - rise * 46) / pop)
            f.fs:SetAlpha(rise < 0.6 and 1 or (1 - (rise - 0.6) / 0.4))
        end
    end
    UI.DrawBubbles(now)
    UI.UpdateHover()
end

---------------------------------------------------------------------------
-- Objects
---------------------------------------------------------------------------

local objTex = {}
function UI.DrawObjects(map, halfW, halfH, now)
    local n = 0
    for _, o in ipairs(Craft.World.objects) do
        if o.map == map and abs(o.x - camX) < halfW and abs(o.y - camY) < halfH then
            local wanted = Craft.Quests.ObjectWanted(o)
            local used = o.usedUntil and Craft.World.Clock() < o.usedUntil
            if not used and (wanted or o.e.kind == "herb" or o.e.kind == "ore" or o.e.kind == "chest") then
                n = n + 1
                local t = objTex[n]
                if not t then
                    t = { glow = K.Tex(top, "OVERLAY", "Interface\\Cooldown\\star4") }
                    t.glow:SetBlendMode("ADD")
                    objTex[n] = t
                end
                local icon
                if wanted then icon = Craft.Items.Icon(wanted.id)
                elseif o.e.kind == "herb" then icon = "Interface\\Icons\\INV_Misc_Flower_02"
                elseif o.e.kind == "ore" then icon = "Interface\\Icons\\INV_Ore_Copper_01"
                else icon = "Interface\\Icons\\INV_Box_01" end
                local sx, sy = ToScreen(o.x, o.y)
                local r = Draw(o.y)
                r.file, r.l, r.r, r.t, r.b = icon, 0.07, 0.93, 0.07, 0.93
                r.w, r.h, r.pt, r.x, r.y = TILE * 0.62, TILE * 0.62, "BOTTOM", sx, sy
                t.shown = true
                if wanted then
                    t.glow:SetSize(TILE * 0.9, TILE * 0.9)
                    t.glow:ClearAllPoints()
                    t.glow:SetPoint("CENTER", top, "TOPLEFT", sx, -(sy - TILE * 0.31))
                    t.glow:SetAlpha(0.45 + 0.4 * math.sin(now * 4 + o.x))
                    t.glow:Show()
                else
                    t.glow:Hide()
                end
                t.obj = o
            end
        end
    end
    for i = n + 1, #objTex do objTex[i].shown = false objTex[i].glow:Hide() objTex[i].obj = nil end
end

---------------------------------------------------------------------------
-- Chat bubbles
---------------------------------------------------------------------------

local bubbles = {}
function UI.Bubble(u, text)
    if not text or not top then return end
    local b
    for _, x in ipairs(bubbles) do if x.u == u then b = x end end
    if not b then
        for _, x in ipairs(bubbles) do if not x.u then b = x break end end
    end
    if not b then
        b = { f = K.Frame(top, 160, 30, K.TOOLTIP_BACKDROP) }
        b.f:SetBackdropColor(1, 1, 1, 0.9)
        b.f:SetBackdropBorderColor(0.8, 0.8, 0.8, 1)
        b.fs = K.Font(b.f, 11)
        b.fs:SetTextColor(0, 0, 0)
        b.fs:SetPoint("TOPLEFT", 8, -7)
        b.fs:SetWidth(180)
        b.fs:SetJustifyH("LEFT")
        bubbles[#bubbles + 1] = b
    end
    b.u, b.t0 = u, Now()
    b.fs:SetWidth(180)
    b.fs:SetText(text)
    local w = min(196, (b.fs:GetStringWidth() or 100) + 16)
    b.fs:SetWidth(w - 16)
    b.f:SetSize(w, (b.fs:GetStringHeight() or 12) + 14)
    b.f:Show()
end

function UI.DrawBubbles(now)
    for _, b in ipairs(bubbles) do
        local u = b.u
        if u and (now - b.t0 > 6 or u.dead or u.map ~= Craft.player.map) then b.u = nil end
        if b.u then
            local sx, sy = ToScreen(u.x, u.y)
            b.f:ClearAllPoints()
            b.f:SetPoint("BOTTOM", top, "TOPLEFT", sx, -(sy - TILE * 1.55 - 14))
            b.f:Show()
        else
            b.f:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- The mouse over the world
---------------------------------------------------------------------------

-- WoW's cursors by their files (Interface\Cursor: there is no plain "Loot" one - a lootable corpse shows LootAll),
-- and the greyed "Unable" twin the client shows while the thing is out of reach
local CURSOR_FILE = { attack = "Attack", talk = "Speak", loot = "LootAll", use = "Interact", trainer = "Trainer",
                      vendor = "Buy", quest = "Quest", herb = "Gatherherbs", ore = "Mine", pickup = "Pickup" }
local UNABLE_FILE = { attack = "UnableAttack", talk = "UnableSpeak", loot = "UnableLootAll", use = "UnableInteract",
                      trainer = "UnableTrainer", vendor = "UnableBuy", quest = "UnableQuest", pickup = "UnablePickup",
                      herb = "UnableGatherherbs", ore = "UnableMine" }
local CURSORS = {}
for k, f in pairs(CURSOR_FILE) do CURSORS[k] = "Interface\\Cursor\\" .. f end
for k, f in pairs(UNABLE_FILE) do CURSORS[k .. "-far"] = "Interface\\Cursor\\" .. f end

local function PickAt(x, y)
    local p = Craft.player
    -- bodies: the sprite stands on its feet, so the clickable box is the tile above the feet point
    local best, bd = nil, 0.62
    for _, u in pairs(Combat.units) do
        if u ~= p and u.map == p.map and not (u.rec and u.rec.hidden) and not (u.ghost) then
            local d = sqrt((u.x - x) ^ 2 + ((u.y - ((u.dead and not u.ghost) and 0.25 or 0.55)) - y) ^ 2)
            if d < bd then best, bd = u, d end
        end
    end
    if best then return best end
    for _, t in ipairs(objTex) do
        local o = t.obj
        if o and t.shown and sqrt((o.x - x) ^ 2 + ((o.y - 0.3) - y) ^ 2) < 0.5 then return o end
    end
    return nil
end
UI.PickAt = PickAt

local function CursorKind(x)
    local p = Craft.player
    if x.e and x.guid and x.guid:find("^O:") then
        if Craft.Quests.ObjectWanted(x) then return "pickup" end
        if x.e.kind == "herb" then return "herb", true end          -- (no Herbalism / Mining yet: greyed)
        if x.e.kind == "ore" then return "ore", true end
        return "use"
    end
    if x.dead then return (x.rec and Craft.Loot.CanLoot(x)) and "loot" or nil end
    if x.kind == "npc" then
        if Craft.Quests.Marker(x.entry or 0) then return "quest" end
        if x.cr and x.cr.trainer then return "trainer" end
        if Craft.Npc.HasRole(x, "vendor") then return "vendor" end
        return "talk"
    end
    if Combat.CanAttack(p, x) and x.kind ~= "critter" then return "attack" end
    return nil
end

-- the cursor over x: its kind, greyed ("-far") while it is out of reach (attack: never - you can always walk up)
local function CursorFor(x)
    if not x then return nil end
    local kind, unable = CursorKind(x)
    if not kind then return nil end
    if kind ~= "attack" and not unable then
        local p = Craft.player
        local d = x.guid and not x.guid:find("^O:") and Craft.UnitDist(p, x) or Craft.Dist(p.x, p.y, x.x, x.y)
        unable = d > Craft.INTERACT_RANGE
    end
    return unable and (kind .. "-far") or kind
end

local lastCursor
function UI.UpdateHover()
    if not view:IsMouseOver() or (UI.MouseOverWindow and UI.MouseOverWindow()) then
        if UI.hover then UI.hover = nil K.HideTooltip() end
        if lastCursor then lastCursor = nil if ResetCursor then ResetCursor() end end
        return
    end
    local x, y = UI.CursorWorld()
    if not x then return end
    local h = PickAt(x, y)
    if h ~= UI.hover then
        UI.hover = h
        if h and h.guid and not h.guid:find("^O:") then K.UnitTooltip(view, h)
        elseif h and h.e then
            GameTooltip:SetOwner(view, "ANCHOR_CURSOR")
            GameTooltip:SetText(h.e.n or "?", 1, 1, 1)
            local it = Craft.Quests.ObjectWanted(h)
            if it then GameTooltip:AddLine(it.name, 1, 0.82, 0) end
            if h.e.kind == "herb" then GameTooltip:AddLine("Requires Herbalism", 1, 0.1, 0.1) end
            if h.e.kind == "ore" then GameTooltip:AddLine("Requires Mining", 1, 0.1, 0.1) end
            GameTooltip:Show()
        else K.HideTooltip() end
    end
    local cur = CursorFor(h)
    if cur ~= lastCursor then
        lastCursor = cur
        if cur and SetCursor then pcall(SetCursor, CURSORS[cur]) elseif ResetCursor then ResetCursor() end
    end
end

function UI.WorldClick(button)
    if UI.SetFocus then UI.SetFocus(true) end
    local p = Craft.player
    if not p then return end
    -- a spell waiting for its target (a held item / action on the cursor drops back)
    if UI.cursorItem and UI.ClearCursorItem then UI.ClearCursorItem() return end
    local x, y = UI.CursorWorld()
    if not x then return end
    local h = PickAt(x, y)
    if button == "LeftButton" then
        if h and h.guid and not h.guid:find("^O:") then Craft.World.SetTarget(h)
        elseif not h then Craft.World.SetTarget(nil) end
    elseif button == "RightButton" then
        if h then
            if IsShiftKeyDown and IsShiftKeyDown() and h.dead and h.rec then
                Craft.World.SetTarget(h)
                Craft.Loot.Open(h, true)
            else
                Craft.World.Interact(h)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Action poses: a melee blow (a swing or a melee ability, hit or not) plays the swing; a spell that went off plays
-- the release (see UnitPose)
---------------------------------------------------------------------------

Craft:On("damage", function(src, dst, amount, info)
    if src and info and info.kind == "melee" then src.swungAt = Now() end
end)

Craft:On("cast", function(u, id, what)
    if u and what == "done" then
        local sp = D.spells[id]
        if not (sp and sp.defType == 2) then u.castDoneAt = Now() end      -- (melee abilities swing instead)
    end
end)
