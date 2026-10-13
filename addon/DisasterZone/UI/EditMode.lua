if DisasterZoneBoot and DisasterZoneBoot.Run("UI/EditMode.lua", ...) then return end -- DisasterZone UI/EditMode.lua
-- Edit layout (/dz edit): one overlay that moves every frame the layout knows (Core/Layout.lua): the addon's HUD
-- frames, the class tools, the meters and the game's own frames. The approved prototype of 2026-10-13:
--   every frame gets a box (gold edge, its name on hover); drag it, Shift-click or drag a box round several;
--   snapping: the screen's centre lines (gold, they win a near tie), other frames' edges and centres (teal), equal
--   gaps between two neighbours (pink, both gaps numbered); Alt held: no snapping; with the grid on, a free drop lands
--   on it, counted from the centre (so the grid is symmetric too); the gaps to the nearest neighbours while dragging;
--   a readout of the place from the screen's centre (equal numbers either side = symmetric);
--   mirrored pairs: move one and its partner follows on the other side of the centre (same height, same size);
--   a toolbar on the selection (centre, line up, equal gaps, mirror, reset, hide); arrow keys 1 px (Shift: a grid
--   step); Ctrl+Z / Ctrl+Y; Esc (deselect, then done).
--   resizing: 8 handles round the selection (one frame or several as a group). A corner scales evenly from the
--   opposite corner; a side stretches a frame that lays itself out at any width / height (def.stretch: cast bars, the
--   XP bar), else scales evenly too; Shift: from the centre; the moving edge snaps like a drag (Alt: free); the mouse
--   wheel on a picked frame: 5% a notch; a double-click on a handle: back to 100% / its natural size. Several picked:
--   they scale as one, the gaps between them too. The game's frames scale through their Edit Mode size (its steps).
-- The panel: profile (this character's; new, copy, rename, delete, share), grid, what snaps, my character's frames or
-- everything, the list with an eye per frame, undo / redo / reset / done.
-- The meters keep their own docking: while editing they are unlocked and raised over the overlay, and a stack dragged
-- by its header snaps like the rest (MeterPanels calls EditMode:SnapBox). The game's frames move when dropped (the
-- game applies its Edit Mode layout). A fight closes the overlay (the game forbids moving its frames then).
local addonName, ns = ...

local EM = ns:NewModule("EditMode")
local UI, S = ns.UI, ns.Style

local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local tinsert, tremove, tsort = table.insert, table.remove, table.sort

local T = 6                                   -- how near (UIParent units) an edge snaps
local TEAL = { 0.31, 0.83, 0.88 }
local ROSE = { 1, 0.42, 0.6 }
local GOLD = { 1, 0.82, 0 }
local PANEL_W, ROW_H, LIST_H = 252, 18, 168

local active, overlay, guides, panel, toolbar, banner
local movers, outlines = {}, {}
local sel, primary, pickFor = {}, nil, nil
local undo, redo = {}, {}
local drag, previews = nil, {}
local reopenAfterCombat = false

local function Layout() return ns.Layout end
local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting(path)
    if v == nil then return default end
    return v
end
local function Set(path, v) if ns.DB then ns.DB:SetSetting(path, v) end end
local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end

function EM:IsActive() return active and true or false end

local function Cursor()
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale() or 1
    return (x or 0) / s, (y or 0) / s
end

local function IndexOf(t, v) for i, x in ipairs(t) do if x == v then return i end end end
local function IsSel(id) return IndexOf(sel, id) ~= nil end

---------------------------------------------------------------------------
-- Which items show, and their boxes
---------------------------------------------------------------------------

local function ShowAll() return Get("editlayout.all", false) and true or false end

local function Listed(def)
    return ShowAll() or Layout():IsMine(def.id)
end

-- The boxes of everything on the screen now: { id = box }; meters as "meters:<i>".
local boxes = {}
local function Box(l, b, w, h) return { l = l, b = b, w = w, h = h, r = l + w, t = b + h, cx = l + w / 2, cy = b + h / 2 } end

local function MeterRects()
    local MP = ns.MeterPanels
    local out = {}
    if not MP or not MP.StackFrames then return out end
    for i, f in ipairs(MP:StackFrames()) do
        if f:IsShown() and f:GetLeft() then
            local r = Layout().Ratio(f)
            out[#out + 1] = Box(f:GetLeft() * r, f:GetBottom() * r, f:GetWidth() * r, f:GetHeight() * r)
        end
    end
    return out
end

local function ReadBoxes()
    for k in pairs(boxes) do boxes[k] = nil end
    for _, def in ipairs(Layout():Items()) do
        if def.kind ~= "meters" and Listed(def) and not (drag and drag.ghost and drag.ghost[def.id]) then
            local l, b, w, h = Layout():Rect(def.id)
            if l and w > 0 and h > 0 then boxes[def.id] = Box(l, b, w, h) end
        elseif drag and drag.ghost and drag.ghost[def.id] then
            boxes[def.id] = drag.ghost[def.id]
        end
    end
    for i, bx in ipairs(MeterRects()) do boxes["meters:" .. i] = bx end
end

---------------------------------------------------------------------------
-- Guides: lines and number pills, drawn fresh on each move
---------------------------------------------------------------------------

local linePool, pillPool, lineUsed, pillUsed = {}, {}, 0, 0

local function Line(l, b, w, h, c, a)
    lineUsed = lineUsed + 1
    local t = linePool[lineUsed]
    if not t then
        t = guides:CreateTexture(nil, "OVERLAY")
        linePool[lineUsed] = t
    end
    t:ClearAllPoints()
    t:SetPoint("BOTTOMLEFT", guides, "BOTTOMLEFT", l, b)
    t:SetSize(max(1, w), max(1, h))
    t:SetColorTexture(c[1], c[2], c[3], a or 0.95)
    t:Show()
    return t
end
local function VLine(x, y1, y2, c, a) return Line(floor(x + 0.5) - 0.5, min(y1, y2), 1, abs(y2 - y1), c, a) end
local function HLine(y, x1, x2, c, a) return Line(min(x1, x2), floor(y + 0.5) - 0.5, abs(x2 - x1), 1, c, a) end

-- A pill centred on (x, y) (or with its left / bottom there: corner = true).
local function Pill(x, y, text, c, dark, corner)
    pillUsed = pillUsed + 1
    local p = pillPool[pillUsed]
    if not p then
        p = CreateFrame("Frame", nil, guides)
        p.bg = p:CreateTexture(nil, "BACKGROUND")
        p.bg:SetAllPoints()
        p.fs = UI:Text(p, "small", "TEXT", { shadow = false })
        p.fs:SetPoint("CENTER", 0, 0)
        pillPool[pillUsed] = p
    end
    p.fs:SetText(text)
    local tw = p.fs:GetStringWidth() or 20
    if tw <= 0 then tw = #tostring(text) * 6 end
    p:SetSize(floor(tw + 10), 14)
    p.bg:SetColorTexture(c[1], c[2], c[3], 0.95)
    if dark then p.fs:SetTextColor(0.05, 0.05, 0.06) else p.fs:SetTextColor(0.92, 0.9, 0.84) end
    p:ClearAllPoints()
    if corner then p:SetPoint("BOTTOMLEFT", guides, "BOTTOMLEFT", x, y)
    else p:SetPoint("CENTER", guides, "BOTTOMLEFT", x, y) end
    p:Show()
    return p
end

function EM:ClearGuides()
    for i = 1, #linePool do linePool[i]:Hide() end
    for i = 1, #pillPool do pillPool[i]:Hide() end
    lineUsed, pillUsed = 0, 0
end

---------------------------------------------------------------------------
-- Snapping (plain numbers: tested without frames)
---------------------------------------------------------------------------

-- The lines a box can catch on one axis: { v, k = "c" (screen centre) | "e" (screen edge) | "f" (a frame), b = box }.
local function Lines(axis, skip)
    local out = {}
    local W, H = Layout().Screen()
    local L = axis == "x" and W or H
    if Get("editlayout.snapScreen", true) then
        out[#out + 1] = { v = 0, k = "e" }
        out[#out + 1] = { v = L, k = "e" }
        out[#out + 1] = { v = L / 2, k = "c" }
    end
    if Get("editlayout.snapFrames", true) then
        for id, bx in pairs(boxes) do
            if not skip[id] then
                if axis == "x" then
                    out[#out + 1] = { v = bx.l, k = "f", b = bx }; out[#out + 1] = { v = bx.cx, k = "f", b = bx }
                    out[#out + 1] = { v = bx.r, k = "f", b = bx }
                else
                    out[#out + 1] = { v = bx.b, k = "f", b = bx }; out[#out + 1] = { v = bx.cy, k = "f", b = bx }
                    out[#out + 1] = { v = bx.t, k = "f", b = bx }
                end
            end
        end
    end
    return out
end

local function Best(edges, lines)
    local r
    for _, e in ipairs(edges) do
        for _, l in ipairs(lines) do
            local d = l.v - e
            local sc = abs(d) - (l.k == "c" and 3 or 0)       -- (the screen's centre wins a near tie)
            if abs(d) <= T and (not r or sc < r.sc) then r = { d = d, sc = sc } end
        end
    end
    return r
end

-- Equal gaps: the box exactly between two neighbours on its row (x) or column (y).
local function Gaps(axis, bx, skip)
    if not Get("editlayout.snapGaps", true) then return nil end
    local near = {}
    for id, o in pairs(boxes) do
        if not skip[id] then
            local overlap = axis == "x" and (o.b < bx.t and o.t > bx.b) or (o.l < bx.r and o.r > bx.l)
            if overlap then near[#near + 1] = o end
        end
    end
    local r
    for _, A in ipairs(near) do
        for _, B in ipairs(near) do
            if axis == "x" and A.r <= bx.cx and B.l >= bx.cx then
                local ideal = (A.r + B.l - bx.w) / 2
                local d = ideal - bx.l
                if ideal >= A.r and abs(d) <= T and (not r or abs(d) < abs(r.d)) then r = { d = d, A = A, B = B } end
            elseif axis == "y" and A.t <= bx.cy and B.b >= bx.cy then
                local ideal = (A.t + B.b - bx.h) / 2
                local d = ideal - bx.b
                if ideal >= A.t and abs(d) <= T and (not r or abs(d) < abs(r.d)) then r = { d = d, A = A, B = B } end
            end
        end
    end
    return r
end

local function GridSnap(v, centre)
    local g = tonumber(Get("editlayout.grid", 0)) or 0
    if g <= 0 then return v end
    return centre + floor((v - centre) / g + 0.5) * g
end

-- Where a w x h box dragged to (l, b) lands: snapped l, b and what it caught ({ gx, gy } equal gaps).
-- skip: { [box id] = true } (what moves with it).
function EM:Snap(l, b, w, h, skip, free)
    local W, H = Layout().Screen()
    if free then return l, b end
    local bx = Box(l, b, w, h)
    local sx = Best({ bx.l, bx.cx, bx.r }, Lines("x", skip))
    local ex = Gaps("x", bx, skip)
    local gx, gy
    if ex and (not sx or abs(ex.d) - 2 <= sx.sc) then l = l + ex.d; gx = ex
    elseif sx then l = l + sx.d
    else l = GridSnap(l + w / 2, W / 2) - w / 2 end
    local sy = Best({ bx.b, bx.cy, bx.t }, Lines("y", skip))
    local ey = Gaps("y", bx, skip)
    if ey and (not sy or abs(ey.d) - 2 <= sy.sc) then b = b + ey.d; gy = ey
    elseif sy then b = b + sy.d
    else b = GridSnap(b + h / 2, H / 2) - h / 2 end
    l = max(0, min(W - w, l))
    b = max(0, min(H - h, b))
    return floor(l + 0.5), floor(b + 0.5), gx, gy
end

-- Draws what a box at bx lines up with, its gaps and its place.
local function DrawGuides(id, bx, skip, gx, gy, scale)
    EM:ClearGuides()
    local W, H = Layout().Screen()
    -- (two passes: the screen's centre lines last, so gold shows where a frame's line runs along it too)
    for pass = 1, 2 do
        for _, axis in ipairs({ "x", "y" }) do
            local edges = axis == "x" and { bx.l, bx.cx, bx.r } or { bx.b, bx.cy, bx.t }
            for _, l in ipairs(Lines(axis, skip)) do
                for _, e in ipairs(edges) do
                    if abs(l.v - e) <= 0.5 then
                        if l.k == "c" and pass == 2 then
                            if axis == "x" then VLine(l.v, 0, H, GOLD) else HLine(l.v, 0, W, GOLD) end
                        elseif l.k == "f" and pass == 1 then
                            if axis == "x" then VLine(l.v, min(bx.b, l.b.b) - 4, max(bx.t, l.b.t) + 4, TEAL)
                            else HLine(l.v, min(bx.l, l.b.l) - 4, max(bx.r, l.b.r) + 4, TEAL) end
                        end
                    end
                end
            end
        end
    end
    if gx then
        local g1, g2 = bx.l - gx.A.r, gx.B.l - bx.r
        HLine(bx.cy, gx.A.r, bx.l, ROSE); HLine(bx.cy, bx.r, gx.B.l, ROSE)
        Pill((gx.A.r + bx.l) / 2, bx.cy, floor(g1 + 0.5), ROSE, true)
        Pill((bx.r + gx.B.l) / 2, bx.cy, floor(g2 + 0.5), ROSE, true)
    end
    if gy then
        local g1, g2 = bx.b - gy.A.t, gy.B.b - bx.t
        VLine(bx.cx, gy.A.t, bx.b, ROSE); VLine(bx.cx, bx.t, gy.B.b, ROSE)
        Pill(bx.cx, (gy.A.t + bx.b) / 2, floor(g1 + 0.5), ROSE, true)
        Pill(bx.cx, (bx.t + gy.B.b) / 2, floor(g2 + 0.5), ROSE, true)
    end
    if not gx and not gy then
        -- the gaps to the nearest neighbour each way (or the screen's edge)
        local function nearest(dir)
            local d = dir == "l" and bx.l or dir == "r" and (W - bx.r) or dir == "d" and bx.b or (H - bx.t)
            for oid, o in pairs(boxes) do
                if not skip[oid] then
                    local ov = (dir == "l" or dir == "r") and (o.b < bx.t and o.t > bx.b) or (o.l < bx.r and o.r > bx.l)
                    if ov then
                        local g = dir == "l" and (bx.l - o.r) or dir == "r" and (o.l - bx.r) or dir == "d" and (bx.b - o.t)
                            or (o.b - bx.t)
                        if g >= 0 and g < d then d = g end
                    end
                end
            end
            return d
        end
        local L, R, D, U = nearest("l"), nearest("r"), nearest("d"), nearest("u")
        if L > 0 and L < 300 then HLine(bx.cy, bx.l - L, bx.l, TEAL, 0.6); Pill(bx.l - L / 2, bx.cy, floor(L + 0.5), TEAL, true) end
        if R > 0 and R < 300 then HLine(bx.cy, bx.r, bx.r + R, TEAL, 0.6); Pill(bx.r + R / 2, bx.cy, floor(R + 0.5), TEAL, true) end
        if D > 0 and D < 240 then VLine(bx.cx, bx.b - D, bx.b, TEAL, 0.6); Pill(bx.cx, bx.b - D / 2, floor(D + 0.5), TEAL, true) end
        if U > 0 and U < 240 then VLine(bx.cx, bx.t, bx.t + U, TEAL, 0.6); Pill(bx.cx, bx.t + U / 2, floor(U + 0.5), TEAL, true) end
    end
    -- a mirrored partner: a dashed tie through the centre line
    local partner = id and Layout():Partner(id)
    local pb = partner and boxes[partner]
    if pb then
        local x1, x2 = min(bx.cx, pb.cx), max(bx.cx, pb.cx)
        local x = x1
        while x < x2 do Line(x, bx.cy, min(5, x2 - x), 1, GOLD, 0.7); x = x + 9 end
        Pill(W / 2, bx.cy, "mirrored", GOLD, true)
    end
    -- where it is, from the screen's centre
    local dx, dy = floor(bx.cx - W / 2 + 0.5), floor(bx.cy - H / 2 + 0.5)
    local p = Layout().AnchorOf(bx.l, bx.b, bx.w, bx.h)
    local text = ("centre %s%d, %s%d"):format(dx > 0 and "+" or "", dx, dy > 0 and "+" or "", dy)
    if scale and abs(scale - 1) > 0.001 then text = text .. ("  \194\183  %d%%"):format(floor(scale * 100 + 0.5)) end
    text = text .. "  \194\183  " .. p:lower()
    local rx = bx.r + 8
    if rx > W - 170 then rx = bx.l - 170 end
    Pill(max(2, rx), min(H - 16, max(2, bx.t - 14)), text, { 0.03, 0.03, 0.04 }, false, true)
end

---------------------------------------------------------------------------
-- Movers
---------------------------------------------------------------------------

local function SetEdges(m, r, g, b, a)
    for _, e in ipairs(m.edges) do e:SetColorTexture(r, g, b, a) end
end

local function PaintMover(m)
    local id = m.id
    local on = IsSel(id)
    local partner = false
    for _, s in ipairs(sel) do if Layout():Partner(s) == id then partner = true end end
    if on then
        SetEdges(m, GOLD[1], GOLD[2], GOLD[3], 1)
        m.wash:SetColorTexture(1, 0.82, 0, 0.12)
    elseif partner then
        SetEdges(m, 0.89, 0.73, 0.33, 0.85)
        m.wash:SetColorTexture(1, 0.82, 0, 0.07)
    elseif m:IsMouseOver() then
        SetEdges(m, 1, 0.82, 0, 0.8)
        m.wash:SetColorTexture(1, 0.82, 0, 0.07)
    else
        SetEdges(m, 1, 0.82, 0, 0.4)
        m.wash:SetColorTexture(1, 0.82, 0, 0.04)
    end
    local def = Layout():Item(id)
    m.tag:SetShown(on or m:IsMouseOver())
    m:SetAlpha((def and not Layout():IsMine(id)) and 0.6 or 1)
end

local function NewMover()
    local m = CreateFrame("Button", nil, overlay)
    m:SetFrameLevel(overlay:GetFrameLevel() + 20)
    m:RegisterForClicks("AnyUp")
    m.wash = m:CreateTexture(nil, "BACKGROUND")
    m.wash:SetPoint("TOPLEFT", -3, 3)
    m.wash:SetPoint("BOTTOMRIGHT", 3, -3)
    -- a 1 px edge 3 px outside the frame (top, bottom, left, right)
    m.edges = {}
    for i = 1, 4 do m.edges[i] = m:CreateTexture(nil, "BORDER") end
    local e = m.edges
    e[1]:SetPoint("TOPLEFT", -3, 3); e[1]:SetPoint("TOPRIGHT", 3, 3); e[1]:SetHeight(1)
    e[2]:SetPoint("BOTTOMLEFT", -3, -3); e[2]:SetPoint("BOTTOMRIGHT", 3, -3); e[2]:SetHeight(1)
    e[3]:SetPoint("TOPLEFT", -3, 3); e[3]:SetPoint("BOTTOMLEFT", -3, -3); e[3]:SetWidth(1)
    e[4]:SetPoint("TOPRIGHT", 3, 3); e[4]:SetPoint("BOTTOMRIGHT", 3, -3); e[4]:SetWidth(1)
    m.tag = CreateFrame("Frame", nil, m)
    m.tag:SetFrameLevel(m:GetFrameLevel() + 5)
    m.tag.bg = m.tag:CreateTexture(nil, "BACKGROUND")
    m.tag.bg:SetAllPoints()
    m.tag.bg:SetColorTexture(1, 0.82, 0, 0.9)
    m.tag.fs = UI:Text(m.tag, "small", "TEXT", { shadow = false })
    m.tag.fs:SetTextColor(0.08, 0.08, 0.08)
    m.tag.fs:SetPoint("LEFT", 4, 0)
    m:EnableMouseWheel(true)
    m:SetScript("OnMouseWheel", function(self, delta) EM:Wheel(self.id, delta) end)
    m:SetScript("OnMouseDown", function(self, button) EM:OnMoverDown(self.id, button) end)
    m:SetScript("OnMouseUp", function() EM:EndDrag() end)
    m:SetScript("OnEnter", function(self) PaintMover(self) end)
    m:SetScript("OnLeave", function(self) PaintMover(self) end)
    return m
end

local function PlaceMover(m, bx)
    m:ClearAllPoints()
    m:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", bx.l, bx.b)
    m:SetSize(max(4, bx.w), max(4, bx.h))
    local W, H = Layout().Screen()
    m.tag:ClearAllPoints()
    if bx.t > H - 20 then m.tag:SetPoint("TOPLEFT", m, "BOTTOMLEFT", -3, -5)
    else m.tag:SetPoint("BOTTOMLEFT", m, "TOPLEFT", -3, 5) end
end

local function TagText(def)
    local t = def.name or def.id
    if def.when then t = t .. "  |cff4b3d00" .. def.when .. "|r" end
    return t
end

-- An outline (no mouse) round each meter stack, where it is now.
local function PlaceOutlines()
    local i = 0
    for k, bx in pairs(boxes) do
        if k:find("^meters:") then
            i = i + 1
            local o = outlines[i]
            if not o then
                o = CreateFrame("Frame", nil, overlay)
                o:SetFrameLevel(overlay:GetFrameLevel() + 2)
                o.edges = {}
                for j = 1, 4 do o.edges[j] = o:CreateTexture(nil, "BORDER") end
                o.edges[1]:SetPoint("TOPLEFT", -3, 3); o.edges[1]:SetPoint("TOPRIGHT", 3, 3); o.edges[1]:SetHeight(1)
                o.edges[2]:SetPoint("BOTTOMLEFT", -3, -3); o.edges[2]:SetPoint("BOTTOMRIGHT", 3, -3); o.edges[2]:SetHeight(1)
                o.edges[3]:SetPoint("TOPLEFT", -3, 3); o.edges[3]:SetPoint("BOTTOMLEFT", -3, -3); o.edges[3]:SetWidth(1)
                o.edges[4]:SetPoint("TOPRIGHT", 3, 3); o.edges[4]:SetPoint("BOTTOMRIGHT", 3, -3); o.edges[4]:SetWidth(1)
                for _, e in ipairs(o.edges) do e:SetColorTexture(1, 0.82, 0, 0.4) end
                o.fs = UI:Text(o, "small", "GOLD")
                o.fs:SetPoint("BOTTOMLEFT", o, "TOPLEFT", -2, 5)
                o.fs:SetText("Meters  |cff9a958adrag by a header|r")
                outlines[i] = o
            end
            o:ClearAllPoints()
            o:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", bx.l, bx.b)
            o:SetSize(bx.w, bx.h)
            o:Show()
        end
    end
    for j = i + 1, #outlines do outlines[j]:Hide() end
end

-- Puts a mover on every listed frame that is on the screen, and an outline (no mouse) on each meter stack.
function EM:Refresh()
    if not active then return end
    ReadBoxes()
    local used = {}
    for _, def in ipairs(Layout():Items()) do
        local bx = boxes[def.id]
        if bx and def.kind ~= "meters" then
            local m = movers[def.id]
            if not m then m = NewMover(); movers[def.id] = m end
            m.id = def.id
            m.tag.fs:SetText(TagText(def))
            m.tag:SetSize(floor((m.tag.fs:GetStringWidth() or 60) + 9), 13)
            PlaceMover(m, bx)
            m:Show()
            PaintMover(m)
            used[def.id] = true
        end
    end
    for id, m in pairs(movers) do if not used[id] then m:Hide() end end
    PlaceOutlines()
    self:PlaceHandles()
    self:UpdateToolbar()
    self:UpdateList()
end

---------------------------------------------------------------------------
-- Dragging, scaling, the marquee
---------------------------------------------------------------------------

local function SelBox(ids)
    local l, b, r, t
    for _, id in ipairs(ids) do
        local bx = boxes[id]
        if bx then
            l, b = min(l or bx.l, bx.l), min(b or bx.b, bx.b)
            r, t = max(r or bx.r, bx.r), max(t or bx.t, bx.t)
        end
    end
    if not l then return nil end
    return Box(l, b, r - l, t - b)
end

local function PushUndo()
    undo[#undo + 1] = Layout():Snapshot()
    if #undo > 60 then tremove(undo, 1) end
    for k in pairs(redo) do redo[k] = nil end
end

-- What moves with the selection: the selection and the mirrored partners of it.
local function MovingSet()
    local set, ids = {}, {}
    for _, id in ipairs(sel) do set[id] = true; ids[#ids + 1] = id end
    for _, id in ipairs(sel) do
        local p = Layout():Partner(id)
        if p and not set[p] then set[p] = true end
    end
    return set, ids
end

function EM:OnMoverDown(id, button)
    if pickFor then
        if id ~= pickFor then
            PushUndo()
            Layout():SetMirror(pickFor, id)
            sel, primary = { pickFor, id }, pickFor
            self:CommitBlizz()
        end
        pickFor = nil
        self:Hint(nil)
        self:Refresh()
        return
    end
    if IsShiftKeyDown() or IsControlKeyDown() then
        local i = IndexOf(sel, id)
        if i then tremove(sel, i) else sel[#sel + 1] = id end
        primary = id
        self:Refresh()
        return
    end
    if not IsSel(id) then sel = { id } end
    primary = id
    if button ~= "LeftButton" then self:Refresh() return end
    local cx, cy = Cursor()
    local set, ids = MovingSet()
    local start = {}
    ReadBoxes()
    for k in pairs(set) do if boxes[k] then start[k] = boxes[k] end end
    drag = { kind = "move", id = id, x0 = cx, y0 = cy, set = set, ids = ids, start = start, moved = false, ghost = {} }
    self:Refresh()
end

---------------------------------------------------------------------------
-- Resizing: handles round the selection
---------------------------------------------------------------------------

-- The handles: { key, hx, hy } (-1 left / bottom, 0 middle, 1 right / top).
local HANDLES = {
    { "BOTTOMLEFT", -1, -1 }, { "BOTTOM", 0, -1 }, { "BOTTOMRIGHT", 1, -1 }, { "RIGHT", 1, 0 },
    { "TOPRIGHT", 1, 1 }, { "TOP", 0, 1 }, { "TOPLEFT", -1, 1 }, { "LEFT", -1, 0 },
}
local handles = {}

-- What resizes with the selection: the picked ids that scale or stretch.
local function Sizable()
    local out = {}
    for _, id in ipairs(sel) do
        local cx, cy = Layout():CanStretch(id)
        if boxes[id] and (Layout():ScaleRange(id) or cx or cy) then out[#out + 1] = id end
    end
    return out
end

-- A side handle stretches when one frame is picked and it lays itself out along that axis.
local function Stretches(ids, hx, hy)
    if #ids ~= 1 or (hx ~= 0 and hy ~= 0) then return false end
    local cx, cy = Layout():CanStretch(ids[1])
    if hx ~= 0 then return cx end
    return cy
end

local function NewHandle(h)
    local b = CreateFrame("Button", nil, overlay)
    b:SetSize(14, 14)
    b:SetFrameLevel(overlay:GetFrameLevel() + 40)
    b.edge = b:CreateTexture(nil, "ARTWORK")
    b.edge:SetPoint("CENTER")
    b.edge:SetSize(9, 9)
    b.edge:SetColorTexture(0.05, 0.05, 0.06, 1)
    b.t = b:CreateTexture(nil, "OVERLAY")
    b.t:SetPoint("CENTER")
    b.t:SetSize(7, 7)
    b.t:SetColorTexture(1, 0.82, 0, 1)
    b.h = h
    b:SetScript("OnEnter", function(self)
        self.t:SetSize(9, 9); self.edge:SetSize(11, 11)
        if SetCursor then pcall(SetCursor, "UI_RESIZE_CURSOR") end
        local ids = Sizable()
        local str = Stretches(ids, self.h[2], self.h[3])
        EM:Hint(str and "Drag to stretch  \194\183  Shift: from the centre  \194\183  double-click: natural size"
            or "Drag to resize  \194\183  Shift: from the centre  \194\183  Alt: no snapping  \194\183  double-click: 100%")
    end)
    b:SetScript("OnLeave", function(self)
        self.t:SetSize(7, 7); self.edge:SetSize(9, 9)
        if ResetCursor then pcall(ResetCursor) end
        if not pickFor then EM:Hint(nil) end
    end)
    b:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local now = GetTime and GetTime() or 0
        if self.last and now - self.last < 0.35 then
            self.last = nil
            EM:ResetSize(self.h[2], self.h[3])
            return
        end
        self.last = now
        EM:StartResize(self.h[2], self.h[3])
    end)
    b:SetScript("OnMouseUp", function() EM:EndDrag() end)
    return b
end

function EM:PlaceHandles()
    if not overlay then return end
    local ids = (active and not (drag and drag.kind ~= "resize")) and Sizable() or {}
    local sb = drag and drag.kind == "resize" and drag.now or SelBox(ids)
    for i, h in ipairs(HANDLES) do
        local b = handles[i]
        if not b then b = NewHandle(h); handles[i] = b end
        local side = h[2] == 0 or h[3] == 0
        -- (a side handle on a frame too small to hold it: only the corners)
        local room = sb and ((h[2] == 0 and sb.w >= 40) or (h[3] == 0 and sb.h >= 28) or not side)
        if sb and #ids > 0 and room then
            b:ClearAllPoints()
            local x = h[2] < 0 and sb.l - 3 or (h[2] > 0 and sb.r + 3 or sb.cx)
            local y = h[3] < 0 and sb.b - 3 or (h[3] > 0 and sb.t + 3 or sb.cy)
            b:SetPoint("CENTER", overlay, "BOTTOMLEFT", x, y)
            -- (a side that stretches is drawn long: a bar, not a dot)
            local str = Stretches(ids, h[2], h[3])
            if str then
                b.t:SetSize(h[2] ~= 0 and 3 or 14, h[3] ~= 0 and 3 or 14)
                b.edge:SetSize(h[2] ~= 0 and 5 or 16, h[3] ~= 0 and 5 or 16)
            elseif not b:IsMouseOver() then
                b.t:SetSize(7, 7); b.edge:SetSize(9, 9)
            end
            b:Show()
        else
            b:Hide()
        end
    end
end

-- Before a size changes: its size now goes into the profile (so an undo brings it back).
local function SeedSizes(ids)
    for _, id in ipairs(ids) do
        local e = Layout():Active().frames[Layout():Key(id)] or {}
        if e.s == nil and Layout():ScaleRange(id) then
            e.s = Layout():Scale(id)
            Layout():Active().frames[Layout():Key(id)] = e
        end
    end
end

function EM:StartResize(hx, hy)
    ReadBoxes()
    local ids = Sizable()
    if #ids == 0 or InCombat() then return end
    local cx, cy = Cursor()
    local start, s0, size0 = {}, {}, {}
    for _, id in ipairs(ids) do
        start[id] = boxes[id]
        s0[id] = Layout():Scale(id)
        local w, h = Layout():Size(id)
        local f = Layout():Frame(id)
        size0[id] = { w or (f and f:GetWidth()) or 0, h or (f and f:GetHeight()) or 0 }
    end
    SeedSizes(ids)
    PushUndo()
    drag = { kind = "resize", hx = hx, hy = hy, x0 = cx, y0 = cy, ids = ids, start = start, s0 = s0, size0 = size0,
             g = SelBox(ids), stretch = Stretches(ids, hx, hy), ghost = {}, bsize = {}, id = primary or ids[1] }
    if toolbar then toolbar:Hide() end
end
-- (the old corner grip's name)
function EM:StartScale(id)
    if id and not IsSel(id) then sel, primary = { id }, id end
    self:StartResize(1, -1)
end

-- The factor range every frame in ids can take, from its own scale range.
local function FactorRange(ids, s0)
    local lo, hi = 0, math.huge
    for _, id in ipairs(ids) do
        local a, b = Layout():ScaleRange(id)
        if a and s0[id] and s0[id] > 0 then lo = max(lo, a / s0[id]); hi = min(hi, b / s0[id]) end
    end
    if hi == math.huge then hi = 1 end
    return lo, hi
end

-- Scales the frames in ids by k about (ax, ay): their sizes and the gaps between them (Blizzard frames: ghosts).
local function ApplyFactor(d, k, ax, ay)
    local nl, nb, nr, nt
    for _, id in ipairs(d.ids) do
        local st = d.start[id]
        local def = Layout():Item(id)
        local s = d.s0[id] * k
        local ncx, ncy = ax + (st.cx - ax) * k, ay + (st.cy - ay) * k
        local bx
        if def.kind == "blizzard" then
            local lo, hi, step = Layout():ScaleRange(id)
            s = max(lo, min(hi, floor(s / step + 0.5) * step))
            local r = s / d.s0[id]
            bx = Box(ncx - st.w * r / 2, ncy - st.h * r / 2, st.w * r, st.h * r)
            d.ghost[id], d.bsize[id] = bx, s
            if movers[id] then PlaceMover(movers[id], bx) end
        else
            Layout():SetScale(id, s, true)
            local _, _, w, h = Layout():Rect(id)
            w, h = w or st.w * k, h or st.h * k
            Layout():MoveTo(id, ncx - w / 2, ncy - h / 2, true)
            bx = Box(ncx - w / 2, ncy - h / 2, w, h)
        end
        nl, nb = min(nl or bx.l, bx.l), min(nb or bx.b, bx.b)
        nr, nt = max(nr or bx.r, bx.r), max(nt or bx.t, bx.t)
    end
    return Box(nl, nb, nr - nl, nt - nb)
end

-- The moving edge's snap: the line it catches (UIParent units) or nil.
local function SnapEdge(axis, v, skip)
    if IsAltKeyDown() then return nil end
    local r = Best({ v }, Lines(axis, skip))
    return r and (v + r.d) or nil
end

local function UpdateResize(d, cx, cy)
    local G = d.g
    local shift = IsShiftKeyDown()
    local skip = {}
    for _, id in ipairs(d.ids) do skip[id] = true; local p = Layout():Partner(id); if p then skip[p] = true end end
    -- the anchor: the opposite side / corner (the centre with Shift); a side's other axis keeps its middle
    local ax = (shift or d.hx == 0) and G.cx or (d.hx > 0 and G.l or G.r)
    local ay = (shift or d.hy == 0) and G.cy or (d.hy > 0 and G.b or G.t)
    -- where the moving edges would go, snapped
    local ex = d.hx ~= 0 and ((d.hx > 0 and G.r or G.l) + (cx - d.x0)) or nil
    local ey = d.hy ~= 0 and ((d.hy > 0 and G.t or G.b) + (cy - d.y0)) or nil
    if ex then ex = SnapEdge("x", ex, skip) or ex end
    if ey then ey = SnapEdge("y", ey, skip) or ey end
    local nw = ex and max(4, (ex - ax) * d.hx) or G.w
    local nh = ey and max(4, (ey - ay) * d.hy) or G.h
    if shift then
        if ex then nw = max(4, abs(ex - G.cx) * 2) end
        if ey then nh = max(4, abs(ey - G.cy) * 2) end
    end
    local id = d.ids[1]
    if d.stretch then
        local f = Layout():Frame(id)
        local r = Layout().Ratio(f)
        local st, sz = d.start[id], d.size0[id]
        if d.hx ~= 0 then Layout():SetSize(id, sz[1] + (nw - st.w) / r, nil)
        else Layout():SetSize(id, nil, sz[2] + (nh - st.h) / r) end
        local _, _, w, h = Layout():Rect(id)
        w, h = w or st.w, h or st.h
        local l = d.hx == 0 and st.l or (shift and G.cx - w / 2 or (d.hx > 0 and G.l or G.r - w))
        local b = d.hy == 0 and st.b or (shift and G.cy - h / 2 or (d.hy > 0 and G.b or G.t - h))
        Layout():MoveTo(id, l, b, true)
        d.now = Box(l, b, w, h)
        local fw, fh = Layout():Size(id)
        d.label = ("%d \195\151 %d"):format(floor((fw or sz[1]) + 0.5), floor((fh or sz[2]) + 0.5))
    else
        -- even scale: the factor from the axis being pulled (a corner: whichever grew or shrank more)
        local kx, ky = nw / G.w, nh / G.h
        local k
        if d.hx == 0 then k = ky elseif d.hy == 0 then k = kx
        elseif abs(kx - 1) >= abs(ky - 1) then k = kx else k = ky end
        local lo, hi = FactorRange(d.ids, d.s0)
        -- (the primary frame lands on whole percents)
        local pid = IsSel(d.id) and d.s0[d.id] and d.id or d.ids[1]
        local ps = d.s0[pid]
        k = max(lo, min(hi, k))
        if ps and ps > 0 then k = floor(ps * k * 100 + 0.5) / 100 / ps end
        d.now = ApplyFactor(d, k, ax, ay)
        d.label = ("%d%%"):format(floor(ps * k * 100 + 0.5))
        if #d.ids > 1 then d.label = d.label .. ("  \194\183  %d frames"):format(#d.ids) end
    end
    -- mirrored partners follow (same size, the other side)
    for _, i2 in ipairs(d.ids) do
        local p = Layout():Partner(i2)
        if p and not IsSel(p) and Layout():Item(i2).kind == "dz" then Layout():FollowMirror(i2, true) end
    end
    ReadBoxes()
    for i2, m in pairs(movers) do if m:IsShown() and boxes[i2] then PlaceMover(m, boxes[i2]) end end
    DrawGuides(d.id, d.now, skip, nil, nil, nil)
    Pill(cx + 14, cy - 22, d.label, GOLD, true, true)
    EM:PlaceHandles()
end

-- The mouse wheel on a picked frame: 5% a notch, the selection about its middle.
function EM:Wheel(id, delta)
    if not IsSel(id) or drag or InCombat() then return end
    ReadBoxes()
    local ids = Sizable()
    if #ids == 0 then return end
    local s0, start = {}, {}
    for _, i2 in ipairs(ids) do s0[i2] = Layout():Scale(i2); start[i2] = boxes[i2] end
    local ps = s0[IsSel(primary) and s0[primary] and primary or ids[1]]
    local ns2 = floor(ps * 20 + (delta > 0 and 1.5 or -0.5)) / 20       -- (the next 5% step either way)
    local lo, hi = FactorRange(ids, s0)
    local k = max(lo, min(hi, ns2 / ps))
    if abs(k - 1) < 0.001 then return end
    SeedSizes(ids)
    PushUndo()
    local G = SelBox(ids)
    local d = { ids = ids, start = start, s0 = s0, ghost = {}, bsize = {} }
    ApplyFactor(d, k, G.cx, G.cy)
    self:FinishResize(d)
end

-- A double-click on a handle: back to 100% (a stretching side: its natural width / height).
function EM:ResetSize(hx, hy)
    if drag then drag = nil end
    ReadBoxes()
    local ids = Sizable()
    if #ids == 0 or InCombat() then return end
    SeedSizes(ids)
    PushUndo()
    if Stretches(ids, hx, hy) then
        local id = ids[1]
        local st = boxes[id]
        local nw, nh = nil, nil
        if hx ~= 0 then nw = false else nh = false end
        Layout():SetSize(id, nw, nh)
        local _, _, w, h = Layout():Rect(id)
        if w then Layout():MoveTo(id, st.cx - w / 2, st.cy - h / 2, true) end
        self:FinishResize({ ids = ids, ghost = {}, bsize = {} })
        return
    end
    local d = { ids = ids, start = {}, s0 = {}, ghost = {}, bsize = {} }
    for _, id in ipairs(ids) do d.start[id] = boxes[id]; d.s0[id] = Layout():Scale(id) end
    for _, id in ipairs(ids) do
        local st = boxes[id]
        if Layout():Item(id).kind == "blizzard" then
            local r = 1 / d.s0[id]
            d.ghost[id] = Box(st.cx - st.w * r / 2, st.cy - st.h * r / 2, st.w * r, st.h * r)
            d.bsize[id] = 1
        else
            Layout():SetScale(id, 1, true)
            local _, _, w, h = Layout():Rect(id)
            if w then Layout():MoveTo(id, st.cx - w / 2, st.cy - h / 2, true) end
        end
    end
    self:FinishResize(d)
end

-- After a resize: the game's frames get their size and place, partners follow, the screen catches up.
function EM:FinishResize(d)
    local any = false
    for id, g in pairs(d.ghost or {}) do
        Layout():SetScale(id, d.bsize[id], true, true)
        Layout():MoveTo(id, g.l, g.b, true, g.w, g.h)
        any = true
    end
    for _, id in ipairs(d.ids or {}) do
        local p = Layout():Partner(id)
        if p and not IsSel(p) then Layout():FollowMirror(id, true) end
    end
    if any then self:CommitBlizz() end
    self:ClearGuides()
    self:Refresh()
    self:Flash()
end

local function MoveItem(id, l, b)
    local def = Layout():Item(id)
    if not def then return end
    if def.kind == "blizzard" then
        local s = boxes[id] or drag.start[id]
        drag.ghost[id] = Box(l, b, s.w, s.h)
        local m = movers[id]
        if m then PlaceMover(m, drag.ghost[id]) end
    else
        Layout():MoveTo(id, l, b)
    end
end

local function UpdateDrag()
    local d = drag
    local cx, cy = Cursor()
    local dx, dy = cx - d.x0, cy - d.y0
    if d.kind == "move" then
        if not d.moved then
            if abs(dx) + abs(dy) < 2 then return end
            d.moved = true
            PushUndo()
            toolbar:Hide()
        end
        local s0 = d.start[d.id]
        if not s0 then return end
        local W = Layout().Screen()
        local skip = {}
        for k in pairs(d.set) do skip[k] = true end
        local nl, nb, gx, gy = EM:Snap(s0.l + dx, s0.b + dy, s0.w, s0.h, skip, IsAltKeyDown())
        local ddx, ddy = nl - s0.l, nb - s0.b
        local placed = {}
        for _, id in ipairs(d.ids) do
            local st = d.start[id]
            if st then MoveItem(id, st.l + ddx, st.b + ddy); placed[id] = Box(st.l + ddx, st.b + ddy, st.w, st.h) end
        end
        for _, id in ipairs(d.ids) do
            local p = Layout():Partner(id)
            local me, ps = placed[id], p and d.start[p]
            if p and me and ps and not placed[p] then
                MoveItem(p, W - me.l - ps.w, me.t - ps.h)
                placed[p] = true
            end
        end
        ReadBoxes()
        for id, m in pairs(movers) do if m:IsShown() and boxes[id] then PlaceMover(m, boxes[id]) end end
        DrawGuides(d.id, Box(nl, nb, s0.w, s0.h), skip, gx, gy, Layout():Scale(d.id))
    elseif d.kind == "resize" then
        UpdateResize(d, cx, cy)
    elseif d.kind == "marquee" then
        local x1, x2, y1, y2 = min(d.x0, cx), max(d.x0, cx), min(d.y0, cy), max(d.y0, cy)
        EM:ClearGuides()
        Line(x1, y1, x2 - x1, 1, GOLD); Line(x1, y2, x2 - x1, 1, GOLD)
        Line(x1, y1, 1, y2 - y1, GOLD); Line(x2, y1, 1, y2 - y1, GOLD)
        sel = {}
        for _, id in ipairs(d.base) do sel[#sel + 1] = id end
        for id, bx in pairs(boxes) do
            if movers[id] and movers[id]:IsShown() and bx.l < x2 and bx.r > x1 and bx.b < y2 and bx.t > y1 and not IsSel(id) then
                sel[#sel + 1] = id
            end
        end
        primary = sel[#sel]
        for _, m in pairs(movers) do if m:IsShown() then PaintMover(m) end end
    end
end

function EM:EndDrag()
    local d = drag
    if not d then return end
    drag = nil
    if d.kind == "resize" then
        self:FinishResize(d)
        return
    end
    if d.kind == "move" and d.moved then
        local any = false
        for id, g in pairs(d.ghost) do Layout():MoveTo(id, g.l, g.b, true, g.w, g.h); any = true end
        if any then self:CommitBlizz() end
    elseif d.kind == "move" and not d.moved and #undo > 0 then
        -- (a click: nothing moved)
    end
    self:ClearGuides()
    self:Refresh()
    if d.kind ~= "marquee" and sel[1] then self:Flash() end
end

function EM:CommitBlizz()
    Layout().Blizz:Commit()
    -- (the game moves its frames when it applies the layout: read their boxes again a moment later)
    if C_Timer and C_Timer.After then C_Timer.After(0.1, function() EM:Refresh() end) end
end

-- After a toolbar action or a nudge: the guides of the first picked frame for a second.
function EM:Flash()
    if drag or not sel[1] then return end
    ReadBoxes()
    local bx = boxes[sel[1]]
    if not bx then return end
    local skip = MovingSet()
    DrawGuides(sel[1], bx, skip, nil, nil, Layout():Scale(sel[1]))
    self.flashUntil = (GetTime and GetTime() or 0) + 1.2
end

---------------------------------------------------------------------------
-- The toolbar on the selection
---------------------------------------------------------------------------

-- Glyphs drawn from small bars (x, y from the top-left of a 14 x 14 box, w, h).
local GLYPHS = {
    al = { { 1, 1, 1.5, 12 }, { 4, 3, 9, 3 }, { 4, 8, 6, 3 } },
    ac = { { 6.25, 1, 1.5, 12 }, { 2.5, 3, 9, 3 }, { 4, 8, 6, 3 } },
    ar = { { 11.5, 1, 1.5, 12 }, { 2, 3, 9, 3 }, { 5, 8, 6, 3 } },
    at = { { 1, 1, 12, 1.5 }, { 3, 4, 3, 9 }, { 8, 4, 3, 6 } },
    am = { { 1, 6.25, 12, 1.5 }, { 3, 2.5, 3, 9 }, { 8, 4, 3, 6 } },
    ab = { { 1, 11.5, 12, 1.5 }, { 3, 2, 3, 9 }, { 8, 5, 3, 6 } },
    dh = { { 1, 4, 3, 6 }, { 5.5, 4, 3, 6 }, { 10, 4, 3, 6 } },
    dv = { { 4, 1, 6, 3 }, { 4, 5.5, 6, 3 }, { 4, 10, 6, 3 } },
    ch = { { 6.5, 0, 1, 3 }, { 6.5, 11, 1, 3 }, { 2, 4.5, 10, 5 } },
    cv = { { 0, 6.5, 3, 1 }, { 11, 6.5, 3, 1 }, { 4.5, 2, 5, 10 } },
    mir = { { 6.5, 0, 1, 3 }, { 6.5, 5.5, 1, 3 }, { 6.5, 11, 1, 3 }, { 1, 3, 4, 8 }, { 9, 3, 4, 8 } },
}

local function GlyphButton(parent, key, title, text, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(24, 24)
    b.hover = b:CreateTexture(nil, "BACKGROUND")
    b.hover:SetAllPoints()
    b.hover:SetColorTexture(1, 1, 1, 0.06)
    b.hover:Hide()
    b.bars = {}
    for _, r in ipairs(GLYPHS[key]) do
        local t = b:CreateTexture(nil, "ARTWORK")
        t:SetPoint("TOPLEFT", b, "TOPLEFT", 5 + r[1], -5 - r[2])
        t:SetSize(r[3], r[4])
        t:SetColorTexture(0.85, 0.82, 0.75, 1)
        b.bars[#b.bars + 1] = t
    end
    b:SetScript("OnEnter", function(self)
        self.hover:Show()
        for _, t in ipairs(self.bars) do t:SetColorTexture(1, 0.82, 0, 1) end
        GameTooltip:SetOwner(self, ns.UI:TowardMiddle(self, "y"))
        GameTooltip:AddLine(title)
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        self.hover:Hide()
        for _, t in ipairs(self.bars) do t:SetColorTexture(0.85, 0.82, 0.75, self:IsEnabled() and 1 or 0.3) end
        GameTooltip:Hide()
    end)
    b:SetScript("OnClick", onClick)
    b.key = key
    return b
end

local function SetGlyphEnabled(b, on)
    b:SetEnabled(on)
    for _, t in ipairs(b.bars) do t:SetColorTexture(0.85, 0.82, 0.75, on and 1 or 0.3) end
end

local function TextButton(parent, text, onClick)
    local b = UI:CreateSleekButton(parent, text, 10, 20, onClick)
    UI:SetTextStyle(b:GetFontString(), "small")
    b:SetWidth(floor((b:GetFontString():GetStringWidth() or 40) + 16))
    return b
end

-- Toolbar actions (also the panel's list and the tests).
function EM:Act(a)
    local ids = {}
    for _, id in ipairs(sel) do ids[#ids + 1] = id end
    if #ids == 0 then return end
    ReadBoxes()
    local sb = SelBox(ids)
    if not sb then return end
    local W, H = Layout().Screen()
    PushUndo()
    local function each(fn)
        for _, id in ipairs(ids) do
            local bx = boxes[id]
            if bx then local l, b = fn(id, bx); Layout():MoveTo(id, l, b, true) end
        end
        for _, id in ipairs(ids) do
            local p = Layout():Partner(id)
            if p and not IsSel(p) then Layout():FollowMirror(id, true) end
        end
    end
    if a == "ch" then each(function(_, bx) return bx.l + W / 2 - sb.cx, bx.b end)
    elseif a == "cv" then each(function(_, bx) return bx.l, bx.b + H / 2 - sb.cy end)
    elseif a == "al" then each(function(_, bx) return sb.l, bx.b end)
    elseif a == "ar" then each(function(_, bx) return sb.r - bx.w, bx.b end)
    elseif a == "ac" then each(function(_, bx) return sb.cx - bx.w / 2, bx.b end)
    elseif a == "at" then each(function(_, bx) return bx.l, sb.t - bx.h end)
    elseif a == "ab" then each(function(_, bx) return bx.l, sb.b end)
    elseif a == "am" then each(function(_, bx) return bx.l, sb.cy - bx.h / 2 end)
    elseif a == "dh" or a == "dv" then
        local hz = a == "dh"
        local order = {}
        for _, id in ipairs(ids) do if boxes[id] then order[#order + 1] = id end end
        tsort(order, function(p, q) if hz then return boxes[p].l < boxes[q].l end return boxes[p].b < boxes[q].b end)
        local total = 0
        for _, id in ipairs(order) do total = total + (hz and boxes[id].w or boxes[id].h) end
        local gap = ((hz and sb.w or sb.h) - total) / max(1, #order - 1)
        local at = hz and sb.l or sb.b
        local pos = {}
        for _, id in ipairs(order) do pos[id] = at; at = at + (hz and boxes[id].w or boxes[id].h) + gap end
        each(function(id, bx) if hz then return pos[id] or bx.l, bx.b end return bx.l, pos[id] or bx.b end)
    elseif a == "mir" and #ids == 2 then
        Layout():SetMirror(ids[1], ids[2])
    elseif a == "unmirror" then
        Layout():ClearMirror(ids[1])
    elseif a == "reset" then
        for _, id in ipairs(ids) do Layout():Reset(id) end
    elseif a == "hide" then
        for _, id in ipairs(ids) do
            if Layout():SetHidden(id, true) then
                local f = Layout():Frame(id)
                if f then f:Hide() end
            end
        end
        sel = {}
    end
    self:CommitBlizz()
    self:Refresh()
    self:Flash()
end

function EM:UpdateToolbar()
    if not toolbar then return end
    for _, c in ipairs(toolbar.parts or {}) do c:Hide() end
    toolbar.parts = {}
    if not active or drag or #sel == 0 then toolbar:Hide() return end
    ReadBoxes()
    local sb = SelBox(sel)
    if not sb then toolbar:Hide() return end
    local x = 6
    local function add(c, gap)
        c:SetParent(toolbar)
        c:ClearAllPoints()
        c:SetPoint("LEFT", toolbar, "LEFT", x, 0)
        c:Show()
        x = x + c:GetWidth() + (gap or 2)
        toolbar.parts[#toolbar.parts + 1] = c
    end
    local function sep()
        local s = toolbar.seps[#toolbar.parts + 1]
        if not s then
            s = CreateFrame("Frame", nil, toolbar)
            s:SetSize(9, 16)
            local t = s:CreateTexture(nil, "ARTWORK")
            t:SetPoint("CENTER")
            t:SetSize(1, 14)
            t:SetColorTexture(1, 1, 1, 0.12)
            toolbar.seps[#toolbar.parts + 1] = s
        end
        add(s, 0)
    end
    toolbar.name:SetText(#sel == 1 and (Layout():Item(sel[1]) and Layout():Item(sel[1]).name or sel[1])
        or (#sel .. " frames"))
    toolbar.name:ClearAllPoints()
    toolbar.name:SetPoint("LEFT", toolbar, "LEFT", 8, 0)
    x = 14 + (toolbar.name:GetStringWidth() or 60)
    toolbar.name:Show()
    local B = toolbar.b
    sep()
    if #sel == 1 then
        local id = sel[1]
        local partner = Layout():Partner(id)
        SetGlyphEnabled(B.ch, not partner)
        B.ch.tipNote = partner
        add(B.ch); add(B.cv)
        sep()
        if partner then add(B.unmirror) else add(B.mirror1) end
        sep()
        add(B.reset)
        local def = Layout():Item(id)
        if def and def.kind == "dz" and not def.noHide then add(B.hide) end
    else
        SetGlyphEnabled(B.ch, true)
        add(B.al); add(B.ac); add(B.ar); sep()
        add(B.at); add(B.am); add(B.ab); sep()
        SetGlyphEnabled(B.dh, #sel >= 3); SetGlyphEnabled(B.dv, #sel >= 3)
        add(B.dh); add(B.dv); sep()
        add(B.ch); add(B.cv)
        if #sel == 2 then
            sep()
            if Layout():Partner(sel[1]) == sel[2] then add(B.unmirror) else add(B.mirror2) end
        end
    end
    toolbar:SetWidth(x + 4)
    local W, H = Layout().Screen()
    local tx = max(4, min(W - x - 8, sb.cx - (x + 4) / 2))
    -- (above the picked frame's name tag, else under the frame)
    local ty = sb.t + 54 <= H - 4 and (sb.t + 22) or max(4, sb.b - 40)
    toolbar:ClearAllPoints()
    toolbar:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", tx, ty)
    toolbar:Show()
end

local function BuildToolbar()
    toolbar = CreateFrame("Frame", "DisasterZoneEditToolbar", overlay)
    toolbar:SetFrameLevel(overlay:GetFrameLevel() + 110)
    toolbar:SetHeight(28)
    toolbar:EnableMouse(true)
    toolbar.bg = UI:Fill(toolbar, "DROP_BG", "BACKGROUND")
    UI:AddEdges(toolbar, "BORDER")
    UI:SetEdgeColor(toolbar, S:Color("DROP_EDGE"))
    toolbar.name = UI:Text(toolbar, "small", "GOLD")
    toolbar.seps = {}
    local function act(a) return function() EM:Act(a) end end
    local B = {}
    B.al = GlyphButton(toolbar, "al", "Line up left edges", nil, act("al"))
    B.ac = GlyphButton(toolbar, "ac", "Line up centres", "Left to right: their middles in one column.", act("ac"))
    B.ar = GlyphButton(toolbar, "ar", "Line up right edges", nil, act("ar"))
    B.at = GlyphButton(toolbar, "at", "Line up top edges", nil, act("at"))
    B.am = GlyphButton(toolbar, "am", "Line up middles", "Top to bottom: their middles in one row.", act("am"))
    B.ab = GlyphButton(toolbar, "ab", "Line up bottom edges", nil, act("ab"))
    B.dh = GlyphButton(toolbar, "dh", "Equal gaps across", "Three or more: the same gap between each, left to right.", act("dh"))
    B.dv = GlyphButton(toolbar, "dv", "Equal gaps down", "Three or more: the same gap between each, top to bottom.", act("dv"))
    B.ch = GlyphButton(toolbar, "ch", "Centre left to right", "On the screen's middle line.", act("ch"))
    B.cv = GlyphButton(toolbar, "cv", "Centre top to bottom", "On the screen's middle line.", act("cv"))
    B.mirror1 = TextButton(toolbar, "Mirror\226\128\166", function()
        pickFor = sel[1]
        EM:Hint(("Click the frame that sits mirrored on the other side of %s  \194\183  Esc cancels")
            :format(Layout():Item(sel[1]).name or sel[1]))
    end)
    B.mirror2 = TextButton(toolbar, "Mirror", act("mir"))
    UI:AttachTooltip(B.mirror2, "Mirror", { "The second one moves to the other side of the centre, level with the first, "
        .. "and follows it from now on." })
    B.unmirror = TextButton(toolbar, "Unmirror", act("unmirror"))
    B.reset = TextButton(toolbar, "Reset", act("reset"))
    UI:AttachTooltip(B.reset, "Reset", { "Back to its own default place and size." })
    B.hide = TextButton(toolbar, "Hide", act("hide"))
    UI:AttachTooltip(B.hide, "Hide", { "Hidden in this profile. The eye in the list brings it back." })
    for _, b in pairs(B) do b:Hide() end
    toolbar.b = B
    toolbar:Hide()
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

function EM:Hint(text)
    if not banner then return end
    banner.fs:SetText(text or "Edit layout  \194\183  drag anything  \194\183  pull a handle or roll the wheel to resize"
        .. "  \194\183  Esc when done")
    banner:SetWidth(floor((banner.fs:GetStringWidth() or 300) + 24))
    if text then banner.bg:SetColorTexture(1, 0.82, 0, 1) else banner.bg:SetColorTexture(1, 0.82, 0, 0.88) end
end

-- Asks a name for a new profile (a copy of where everything is now) and switches this character to it.
function EM:PromptNew(onDone)
    local L = Layout()
    local me = ns.Util.PlayerKey()
    ns.Popup:Prompt({ title = "New profile", text = "A copy of where everything is now, for this character.",
        default = L.UniqueName(me and ns.Util.ShortName(me) or "Layout"), maxLetters = 32, trim = true,
        validate = function(v)
            if v == "" then return false end
            if L:NameTaken(v) then return "A profile has that name already." end
        end,
        onAccept = function(v)
            local id = L:NewProfile(v)
            if id then L:Use(id) end
            if active then EM:Reset() end
            if onDone then onDone(id) end
        end })
end

local function ProfileMenu(root)
    local L = Layout()
    local pid = L:ActiveId()
    local isDefault = pid == "default"
    root:CreateButton("New profile\226\128\166", function() EM:PromptNew() end)
    root:CreateButton("Copy", function()
        local p = L:Active()
        local id = L:NewProfile((p.name or "Layout") .. " copy")
        if id then L:Use(id); EM:Reset() end
    end)
    local rn = root:CreateButton("Rename\226\128\166", function()
        ns.Popup:Prompt({ title = "Rename profile", default = L:Active().name, maxLetters = 32, trim = true,
            validate = function(v)
                if v == "" then return false end
                if L:NameTaken(v, pid) then return "A profile has that name already." end
            end,
            onAccept = function(v) L:Rename(pid, v); EM:UpdatePanel() end })
    end)
    if isDefault and rn.SetEnabled then rn:SetEnabled(false) end
    local del = root:CreateButton("Delete", function()
        ns.Popup:Confirm({ title = "Delete profile", text = ("Delete \"%s\"? Characters using it go back to Default.")
            :format(L:Active().name or ""), ok = "Delete", danger = true,
            onAccept = function() L:Delete(pid); EM:Reset() end })
    end)
    if isDefault and del.SetEnabled then del:SetEnabled(false) end
    root:CreateDivider()
    root:CreateButton("Share\226\128\166", function() EM:Share() end)
end

function EM:Share(anchor)
    local ref = Layout():ShareRef()
    if not ref then return end
    Layout():Capture(true)
    if ns.ShareWindow and ns.ShareWindow.Open then ns.ShareWindow:Open(ref, anchor or (panel and panel.more)) end
end

local function ListRow(parent, i)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(i - 1) * ROW_H)
    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.05)
    r.hl:Hide()
    r.sel = r:CreateTexture(nil, "BACKGROUND", nil, 1)
    r.sel:SetAllPoints()
    r.sel:SetColorTexture(1, 0.82, 0, 0.1)
    r.sel:Hide()
    r.fs = UI:Text(r, "small", "TEXT")
    r.fs:SetPoint("LEFT", 8, 0)
    r.fs:SetPoint("RIGHT", -24, 0)
    r.eye = UI:CreateTipIconButton(r, 16, UI.ICON.eye, "Hide", "Hidden in this profile; click again to show it.")
    r.eye:SetPoint("RIGHT", -4, 0)
    r:SetScript("OnEnter", function(self) self.hl:Show() end)
    r:SetScript("OnLeave", function(self) self.hl:Hide() end)
    r:SetScript("OnClick", function(self)
        if self.isHead or not self.id then return end
        if boxes[self.id] then sel, primary = { self.id }, self.id; EM:Refresh(); EM:Flash() end
    end)
    r.eye:SetScript("OnClick", function()
        local id = r.id
        if not id then return end
        PushUndo()
        local on = not Layout():IsHidden(id)
        Layout():SetHidden(id, on)
        local f = Layout():Frame(id)
        if f and on then f:Hide() end
        if not on then local def = Layout():Item(id); if def and def.preview then pcall(def.preview, true); previews[id] = true end end
        EM:Refresh()
    end)
    return r
end

function EM:UpdateList()
    if not panel then return end
    local rows = {}
    local g
    for _, def in ipairs(Layout():Items()) do
        if Listed(def) and def.kind ~= "meters" then
            if def.group ~= g then g = def.group; rows[#rows + 1] = { head = g } end
            rows[#rows + 1] = { def = def }
        end
    end
    local child = panel.listChild
    child:SetHeight(max(1, #rows * ROW_H))
    for i, info in ipairs(rows) do
        local r = panel.rows[i] or ListRow(child, i)
        panel.rows[i] = r
        r:Show()
        if info.head then
            r.isHead, r.id = true, nil
            r.fs:SetText(S:Wrap("DIM", info.head:upper()))
            r.fs:SetPoint("LEFT", 4, 0)
            r.eye:Hide(); r.sel:Hide()
        else
            local def = info.def
            r.isHead, r.id = false, def.id
            r.fs:SetPoint("LEFT", 12, 0)
            local hidden = Layout():IsHidden(def.id)
            local onScreen = boxes[def.id] ~= nil
            local name = def.name or def.id
            if hidden then name = S:Wrap("DIM", name .. " (hidden)")
            elseif not onScreen then name = S:Wrap("SUB", name) .. S:Wrap("DIM", "  not shown") end
            r.fs:SetText(name)
            r.sel:SetShown(IsSel(def.id))
            r.eye:SetShown(def.kind == "dz" and not def.noHide)
            r.eye.icon:SetAlpha(hidden and 0.35 or 1)
            r.eye.tipTitle = hidden and "Show" or "Hide"
        end
    end
    for i = #rows + 1, #panel.rows do panel.rows[i]:Hide() end
end

function EM:UpdatePanel()
    if not panel then return end
    panel.profile:Refresh()
    panel.grid:Select(tostring(tonumber(Get("editlayout.grid", 0)) or 0))
    panel.show:Select(ShowAll() and "all" or "mine")
    panel.undo:SetEnabled(#undo > 0)
    panel.redo:SetEnabled(#redo > 0)
    self:UpdateList()
end

local function BuildPanel()
    panel = CreateFrame("Frame", "DisasterZoneEditPanel", overlay)
    panel:SetFrameLevel(overlay:GetFrameLevel() + 100)
    panel:SetSize(PANEL_W, 200)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    if UI.SoftShadow then UI:SoftShadow(panel, 18, 0.5, -6, 2) end
    panel.bg = UI:Fill(panel, "DROP_BG", "BACKGROUND")
    UI:AddEdges(panel, "BORDER")
    UI:SetEdgeColor(panel, 1, 0.82, 0, 0.45)
    local head = CreateFrame("Frame", nil, panel)
    head:SetPoint("TOPLEFT"); head:SetPoint("TOPRIGHT"); head:SetHeight(28)
    head:EnableMouse(true)
    head:RegisterForDrag("LeftButton")
    head:SetScript("OnDragStart", function() panel:StartMoving() end)
    head:SetScript("OnDragStop", function()
        panel:StopMovingOrSizing()
        local l, t = panel:GetLeft(), panel:GetTop()
        if l and t then Set("editlayout.panel", { floor(l + 0.5), floor(t + 0.5) }) end
    end)
    local hb = head:CreateTexture(nil, "BACKGROUND", nil, 1)
    hb:SetAllPoints()
    hb:SetColorTexture(1, 1, 1, 0.03)
    local title = UI:Text(head, "emph", "GOLD")
    title:SetPoint("LEFT", 10, 0)
    title:SetText("Edit layout")
    local drag = UI:Text(head, "small", "DIM")
    drag:SetPoint("RIGHT", -10, 0)
    drag:SetText("drag here")

    local y = -36
    local function label(text)
        local fs = UI:Text(panel, "small", "TEXT")
        fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, y - 4)
        fs:SetText(text)
        return fs
    end
    label("Profile")
    panel.profile = UI:CreateSleekDropdown(panel, 122, function()
        local out = {}
        for _, p in ipairs(Layout():Profiles()) do out[#out + 1] = { value = p.id, text = p.name } end
        return out
    end, function() return Layout():ActiveId() end, function(v)
        if v ~= Layout():ActiveId() then Layout():Use(v); EM:Reset() end
    end)
    panel.profile:SetPoint("TOPLEFT", panel, "TOPLEFT", 70, y)
    panel.more = UI:CreateSleekMenuButton(panel, "\194\183\194\183\194\183", 40, ProfileMenu)
    panel.more:SetPoint("LEFT", panel.profile, "RIGHT", 4, 0)
    y = y - 30
    label("Grid")
    panel.grid = UI:CreateSegments(panel, { { key = "0", label = "Off" }, { key = "8", label = "8" },
        { key = "16", label = "16" }, { key = "32", label = "32" } }, function(key)
        Set("editlayout.grid", tonumber(key) or 0)
        EM:DrawGrid()
    end, { width = 166, h = 20, textSize = "small" })
    panel.grid:SetPoint("TOPLEFT", panel, "TOPLEFT", 70, y)
    y = y - 28
    label("Snap to")
    local snaps = { { "editlayout.snapScreen", "Screen centre and edges", GOLD },
                    { "editlayout.snapFrames", "Other frames", TEAL }, { "editlayout.snapGaps", "Equal gaps", ROSE } }
    for i, s in ipairs(snaps) do
        local cb = UI:CreateCheckbox(panel, s[2], function() return Get(s[1], true) and true or false end,
            function(on) Set(s[1], on and true or false) end)
        cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 66, y + 2 - (i - 1) * 18)
        local sw = panel:CreateTexture(nil, "ARTWORK")
        sw:SetSize(10, 2)
        sw:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_W - 22, y - 9 - (i - 1) * 18)
        sw:SetColorTexture(s[3][1], s[3][2], s[3][3], 1)
    end
    y = y - 58
    label("Frames")
    panel.show = UI:CreateSegments(panel, { { key = "mine", label = "My character" }, { key = "all", label = "Everything" } },
        function(key) Set("editlayout.all", key == "all"); EM:SetPreviews(); EM:Refresh() end,
        { width = 166, h = 20, textSize = "small" })
    panel.show:SetPoint("TOPLEFT", panel, "TOPLEFT", 70, y)
    y = y - 28
    local sf = UI:CreateScrollFrame(panel)
    sf:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, y)
    sf:SetSize(PANEL_W - 28, LIST_H)
    local well = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    well:SetPoint("TOPLEFT", sf, "TOPLEFT", -1, 1)
    well:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", 14, -1)
    well:SetColorTexture(S:Color("INSET"))
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(PANEL_W - 28, 10)
    sf:SetScrollChild(child)
    panel.listChild, panel.rows = child, {}
    y = y - LIST_H - 10
    panel.undo = UI:CreateSleekButton(panel, "Undo", 50, 22, function() EM:Undo() end)
    panel.undo:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, y)
    UI:AttachTooltip(panel.undo, "Undo", { "Ctrl+Z" })
    panel.redo = UI:CreateSleekButton(panel, "Redo", 50, 22, function() EM:Redo() end)
    panel.redo:SetPoint("LEFT", panel.undo, "RIGHT", 4, 0)
    UI:AttachTooltip(panel.redo, "Redo", { "Ctrl+Y" })
    local reset = UI:CreateSleekButton(panel, "Reset", 54, 22, function()
        ns.Popup:Confirm({ title = "Reset layout", text = "Put every frame of this profile back at its own default place?",
            ok = "Reset", danger = true, onAccept = function()
                PushUndo()
                for _, def in ipairs(Layout():Items()) do if def.kind ~= "meters" then Layout():Reset(def.id) end end
                local m = Layout():Active().mirror
                for k in pairs(m) do m[k] = nil end
                EM:Refresh()
            end })
    end)
    reset:SetPoint("LEFT", panel.redo, "RIGHT", 4, 0)
    local done = UI:CreateSleekButton(panel, "Done", 70, 22, function() EM:Close() end, "primary")
    done:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, y)
    panel:SetHeight(-y + 30)
end

---------------------------------------------------------------------------
-- The overlay: grid, keys, open / close
---------------------------------------------------------------------------

local gridLines = {}
function EM:DrawGrid()
    for _, t in ipairs(gridLines) do t:Hide() end
    if not overlay then return end
    local g = tonumber(Get("editlayout.grid", 0)) or 0
    local W, H = Layout().Screen()
    local n = 0
    local function line(l, b, w, h, a)
        n = n + 1
        local t = gridLines[n]
        if not t then t = overlay.gridLayer:CreateTexture(nil, "BACKGROUND", nil, 2); gridLines[n] = t end
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", l, b)
        t:SetSize(w, h)
        t:SetColorTexture(1, 1, 1, a)
        t:Show()
    end
    if g > 0 then
        local x = W / 2 % g
        while x < W do line(floor(x), 0, 1, H, 0.06); x = x + g end
        local y = H / 2 % g
        while y < H do line(0, floor(y), W, 1, 0.06); y = y + g end
    end
end

local function Nudge(dx, dy)
    if #sel == 0 then return end
    PushUndo()
    ReadBoxes()
    local W = Layout().Screen()
    for _, id in ipairs(sel) do
        local bx = boxes[id]
        if bx then Layout():MoveTo(id, bx.l + dx, bx.b + dy, true) end
    end
    for _, id in ipairs(sel) do
        local p = Layout():Partner(id)
        if p and not IsSel(p) then Layout():FollowMirror(id, true) end
    end
    local _ = W
    EM:CommitBlizz()
    EM:Refresh()
    EM:Flash()
end

function EM:OnKey(key)
    if key == "ESCAPE" then
        if pickFor then pickFor = nil; self:Hint(nil)
        elseif #sel > 0 then sel = {}; self:Refresh()
        else self:Close() end
        return true
    end
    local step = IsShiftKeyDown() and max(1, tonumber(Get("editlayout.grid", 0)) or 0) or 1
    if IsShiftKeyDown() and step < 2 then step = 10 end
    if key == "LEFT" then Nudge(-step, 0) return true end
    if key == "RIGHT" then Nudge(step, 0) return true end
    if key == "UP" then Nudge(0, step) return true end
    if key == "DOWN" then Nudge(0, -step) return true end
    if IsControlKeyDown() and key == "Z" then if IsShiftKeyDown() then self:Redo() else self:Undo() end return true end
    if IsControlKeyDown() and key == "Y" then self:Redo() return true end
    return false
end

function EM:Undo()
    if #undo == 0 then return end
    redo[#redo + 1] = Layout():Snapshot()
    Layout():Restore(tremove(undo))
    self:CommitBlizz()
    self:Refresh()
    self:UpdatePanel()
end

function EM:Redo()
    if #redo == 0 then return end
    undo[#undo + 1] = Layout():Snapshot()
    Layout():Restore(tremove(redo))
    self:CommitBlizz()
    self:Refresh()
    self:UpdatePanel()
end

local function BuildOverlay()
    overlay = CreateFrame("Frame", "DisasterZoneEditMode", UIParent)
    overlay:SetAllPoints(UIParent)
    -- (over the HUD and the pop-ups, under the menus and dialogs it opens: those are FULLSCREEN_DIALOG)
    overlay:SetFrameStrata("FULLSCREEN")
    overlay:SetFrameLevel(1)
    overlay:EnableMouse(true)
    overlay:EnableKeyboard(true)
    overlay.dim = overlay:CreateTexture(nil, "BACKGROUND")
    overlay.dim:SetAllPoints()
    overlay.dim:SetColorTexture(0, 0, 0, 0.22)
    overlay.gridLayer = CreateFrame("Frame", nil, overlay)
    overlay.gridLayer:SetAllPoints()
    overlay.axisV = overlay:CreateTexture(nil, "BACKGROUND", nil, 3)
    overlay.axisH = overlay:CreateTexture(nil, "BACKGROUND", nil, 3)
    overlay.axisV:SetColorTexture(1, 0.82, 0, 0.3)
    overlay.axisH:SetColorTexture(1, 0.82, 0, 0.3)
    overlay.axisV:SetWidth(1)
    overlay.axisV:SetPoint("TOP", overlay, "TOP", 0, 0)
    overlay.axisV:SetPoint("BOTTOM", overlay, "BOTTOM", 0, 0)
    overlay.axisH:SetHeight(1)
    overlay.axisH:SetPoint("LEFT", overlay, "LEFT", 0, 0)
    overlay.axisH:SetPoint("RIGHT", overlay, "RIGHT", 0, 0)
    guides = CreateFrame("Frame", nil, overlay)
    guides:SetAllPoints()
    guides:SetFrameLevel(overlay:GetFrameLevel() + 60)
    banner = CreateFrame("Frame", nil, overlay)
    banner:SetFrameLevel(overlay:GetFrameLevel() + 70)
    banner:SetHeight(18)
    banner:SetPoint("TOP", overlay, "TOP", 0, 0)
    banner.bg = banner:CreateTexture(nil, "BACKGROUND")
    banner.bg:SetAllPoints()
    banner.fs = UI:Text(banner, "small", "TEXT", { shadow = false })
    banner.fs:SetTextColor(0.08, 0.08, 0.08)
    banner.fs:SetPoint("CENTER", 0, 0)
    -- empty space: a click drops the selection, a drag picks with a box
    overlay:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        if pickFor then pickFor = nil; EM:Hint(nil) return end
        local cx, cy = Cursor()
        local base = {}
        if IsShiftKeyDown() then for _, id in ipairs(sel) do base[#base + 1] = id end end
        sel = base
        ReadBoxes()
        drag = { kind = "marquee", x0 = cx, y0 = cy, base = base }
        EM:Refresh()
    end)
    overlay:SetScript("OnMouseUp", function() EM:EndDrag() end)
    overlay:SetScript("OnKeyDown", function(self, key)
        local handled = EM:OnKey(key)
        if not InCombat() then self:SetPropagateKeyboardInput(not handled) end
    end)
    local since = 0
    overlay:SetScript("OnUpdate", function(_, elapsed)
        if drag then
            UpdateDrag()
            return
        end
        since = since + (elapsed or 0)
        if EM.flashUntil and (GetTime and GetTime() or 0) > EM.flashUntil then EM.flashUntil = nil; EM:ClearGuides() end
        if since > 0.3 then since = 0; EM:RefreshQuiet() end
    end)
    BuildToolbar()
    BuildPanel()
    EM:Hint(nil)
    overlay:Hide()
end

-- (the frames move and grow on their own too: the boxes follow every 0.3 s, without touching the list's scroll)
function EM:RefreshQuiet()
    if not active or drag then return end
    ReadBoxes()
    for id, m in pairs(movers) do
        if m:IsShown() and boxes[id] then PlaceMover(m, boxes[id]) end
    end
    PlaceOutlines()
    self:PlaceHandles()
end

-- Frames that only show sometimes come up with made-up content while editing (and go when it closes).
function EM:SetPreviews()
    for _, def in ipairs(Layout():Items()) do
        local want = active and Listed(def) and def.preview and not Layout():IsHidden(def.id)
        if want and not previews[def.id] then
            -- (nothing of it on the screen: a frame not shown, or a holder whose units aren't there)
            if not Layout():Rect(def.id) then
                if pcall(def.preview, true) then previews[def.id] = true end
            end
        elseif not want and previews[def.id] then
            pcall(def.preview, false)
            previews[def.id] = nil
        end
    end
end

-- After a profile switch: no selection, no history.
function EM:Reset()
    sel, primary, pickFor = {}, nil, nil
    for k in pairs(undo) do undo[k] = nil end
    for k in pairs(redo) do redo[k] = nil end
    self:SetPreviews()
    self:Refresh()
    self:UpdatePanel()
end

function EM:Open()
    if active then return true end
    if InCombat() then
        ns:Print("Edit layout opens after the fight (the game doesn't let frames move in combat).")
        return false
    end
    if not overlay then BuildOverlay() end
    active = true
    reopenAfterCombat = false
    sel, primary, pickFor = {}, nil, nil
    for k in pairs(undo) do undo[k] = nil end
    for k in pairs(redo) do redo[k] = nil end
    Layout():RegisterBlizzard()
    if ns.UI.CloseMenus then ns.UI:CloseMenus() end
    -- the DisasterZone window steps aside while editing (the user, 2026-10-13) and comes back on its page after
    local mf = ns.MainFrame
    self.windowPage = nil
    if mf and mf.IsShown and mf:IsShown() then
        self.windowPage = mf:GetSelectedTab() or "home"
        mf:Close()
    end
    if GameTooltip then GameTooltip:Hide() end
    local pos = Get("editlayout.panel")
    panel:ClearAllPoints()
    if type(pos) == "table" and pos[1] then panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos[1], pos[2])
    else panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 260, -160) end
    overlay:Show()
    -- the hidden frames show while editing (to be moved, or brought back with the eye)
    for _, def in ipairs(Layout():Items()) do
        if def.kind == "dz" and Layout():IsHidden(def.id) then
            local f = Layout():Frame(def.id)
            if f and def.preview then pcall(def.preview, true); previews[def.id] = true end
        end
    end
    self:SetPreviews()
    self:DrawGrid()
    self:Hint(nil)
    ns:Fire("EDIT_LAYOUT", true)
    self:Refresh()
    self:UpdatePanel()
    return true
end

function EM:Close()
    if not active then return end
    if drag then self:EndDrag() end
    active = false
    pickFor = nil
    sel = {}
    self:ClearGuides()
    for id in pairs(previews) do
        local def = Layout():Item(id)
        if def and def.preview then pcall(def.preview, false) end
        previews[id] = nil
    end
    for _, def in ipairs(Layout():Items()) do
        if def.kind == "dz" and Layout():IsHidden(def.id) then
            local f = Layout():Frame(def.id)
            if f and f:IsShown() and not (def.protected and InCombat()) then f:Hide() end
        end
    end
    Layout():Capture()
    if Layout().Blizz.dirty then Layout().Blizz:Commit() end
    if overlay then overlay:Hide() end
    if GameTooltip then GameTooltip:Hide() end
    ns:Fire("EDIT_LAYOUT", false)
    -- (back to the window's page, unless a fight closed it: then the window stays out of the way)
    local page = self.windowPage
    self.windowPage = nil
    if page and not InCombat() and ns.MainFrame and not ns.MainFrame:IsShown() then ns.MainFrame:Open(page) end
end

function EM:Toggle()
    if active then self:Close() else self:Open() end
end

-- For tests: pick frames as a click would.
function EM:Select(ids)
    sel = {}
    for _, id in ipairs(ids or {}) do sel[#sel + 1] = id end
    primary = sel[1]
    self:Refresh()
end
function EM:Selection() return sel end
function EM:StepDrag() if drag then UpdateDrag() end end
function EM:Mover(id) return movers[id] end
function EM:SelectionBox() ReadBoxes() return SelBox(sel) end
function EM:HandlesShown()
    local n = 0
    for _, b in ipairs(handles) do if b:IsShown() then n = n + 1 end end
    return n
end
function EM:GetPanel() return panel end
function EM:GetToolbar() return toolbar end
function EM:Boxes() ReadBoxes() return boxes end

-- The meters: a stack dragged by its header snaps like the rest (MeterPanels' drag, holder units: TOPLEFT x, y).
-- (the other stacks are the meters' own business: docking to them is theirs, so they are left out here)
function EM:SnapBox(frame, x, y, w, h)
    if not active then return x, y end
    local r = Layout().Ratio(frame)
    ReadBoxes()
    local skip = {}
    for k in pairs(boxes) do if k:find("^meters:") then skip[k] = true end end
    local nl, nb, gx, gy = self:Snap(x * r, (y - h) * r, w * r, h * r, skip, IsAltKeyDown())
    DrawGuides(nil, Box(nl, nb, w * r, h * r), skip, gx, gy, nil)
    PlaceOutlines()
    return nl / r, nb / r + h
end

function EM:OnLogin()
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if active then
            reopenAfterCombat = true
            EM.windowPage = nil              -- (the window stays out of the fight)
            EM:Close()
            ns:Print("Edit layout closed for the fight. It comes back when the fight is over.")
        end
    end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if reopenAfterCombat then
            reopenAfterCombat = false
            if UI.Toast then
                UI:Toast({ key = "editlayout", kicker = "Edit layout", title = "Back to editing?",
                    text = "It closed when the fight started.", duration = 20,
                    buttons = { { text = "Reopen", kind = "primary", onClick = function() EM:Open() end } } })
            end
        end
    end)
    ns:On("LAYOUT_RECEIVED", function(owner, pid, data) EM:OnReceived(owner, pid, data) end)
end

-- A shared layout arrived (Share.lua asked for it): keep it as a profile?
function EM:OnReceived(owner, pid, data)
    local who = ns.Util.ShortName(owner) or tostring(owner)
    if not data then
        ns:Print("%s's layout isn't there any more.", who)
        return
    end
    local n = 0
    for _ in pairs(type(data.f) == "table" and data.f or {}) do n = n + 1 end
    ns.Popup:Confirm({ key = "layoutshare", title = "Shared layout",
        text = ("%s shared the layout \"%s\" (%d frames).\nKeep it as a profile?"):format(who, tostring(data.n or "?"), n),
        ok = "Keep and use", alt = "Keep", cancel = "No thanks",
        onAccept = function() local id = Layout():Import(data, owner); if id then Layout():Use(id) end end,
        onAlt = function() Layout():Import(data, owner) end })
end
