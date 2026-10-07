if DisasterZoneBoot and DisasterZoneBoot.Run("UI/EventWidgets.lua", ...) then return end -- DisasterZone: the events' shared look.
-- Small pieces every events screen uses, so the Events tab, the builder, the live board and the tracker look the same:
-- an event's art (a loading screen cropped below its logo), the banner shade, badges (an icon in a metallic ring),
-- class circles and names ("You" in blue), the stage progress line, the pills (Live, Ranked, In review ...), dates.
local addonName, ns = ...

local EUI = ns:NewModule("EventUI")

local CreateFrame = CreateFrame
local floor, max, min = math.floor, math.max, math.min

EUI.RING = "Interface\\AddOns\\DisasterZone\\Media\\Events\\ring"
EUI.PIECES = "Interface\\AddOns\\DisasterZone\\Media\\Events\\pieces"
EUI.MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
EUI.WHITE = "Interface\\Buttons\\WHITE8X8"
EUI.GOLD = { 1, 0.82, 0 }
EUI.YOU = { 0.4, 0.72, 1 }          -- "You" everywhere (the board, the standings, the tracker)
EUI.GREY = { 0.62, 0.62, 0.62 }
EUI.DIM = { 0.44, 0.44, 0.46 }
EUI.TEXT = { 0.88, 0.88, 0.88 }
EUI.LIVE = { 1, 0.35, 0.27 }
EUI.CARD = { 0.10, 0.10, 0.12, 0.92 }
EUI.EDGE = { 0.34, 0.34, 0.38, 0.55 }
EUI.PAD, EUI.GAP = 10, 8            -- the page grid (UI style: one spacing grid per page)

local function UI() return ns.UI end
local function B() return ns.EventBlocks end
local function Util() return ns.Util end

---------------------------------------------------------------------------
-- Pills
---------------------------------------------------------------------------

do
    local look = ns.UI and ns.UI.TAG_LOOK
    if look then
        look.live = { text = { 1, 0.77, 0.72 }, tint = { 0.9, 0.2, 0.15 }, edge = { 1, 0.38, 0.29, 0.8 } }
        look.rank = { text = { 1, 0.88, 0.54 }, tint = { 1, 0.82, 0 }, edge = { 1, 0.82, 0, 0.55 } }
    end
end

-- kind: live | rank | review | back | changed | draft | ended | mute | ok | warn | alt
local PILL = {
    live = { "live", nil }, rank = { "rank", "Interface\\COMMON\\ReputationStar" }, review = { "warn", nil },
    back = { "warn", nil }, changed = { "warn", nil }, draft = { "mute", nil }, ended = { "mute", nil },
    mute = { "mute", nil }, ok = { "ok", nil }, warn = { "warn", nil }, alt = { "alt", nil },
}

function EUI:CreatePill(parent, h)
    local p = UI():CreateTagPill(parent, h or 16)
    local set = p.Set
    function p:SetKind(text, kind)
        local d = PILL[kind] or PILL.mute
        set(self, text, d[1], d[2])
        if d[2] and self.icon then self.icon:SetTexCoord(0, 0.5, 0, 0.5) end
    end
    return p
end

-- The pill an event's review state shows (nil: none).
function EUI:ReviewPill(state)
    if state == "ranked" then return "Ranked", "rank" end
    if state == "review" then return "In review", "review" end
    if state == "back" then return "Sent back", "back" end
    if state == "changed" then return "Changed", "changed" end
    return nil
end

---------------------------------------------------------------------------
-- Art: a loading screen of the client, cropped below its logo
---------------------------------------------------------------------------

-- Points tex at an event's art (EventBlocks.ART key) cropped for a w x h box: cx, cy = the middle of the crop (0..1
-- of the square texture, which the game shows at 4:3), fw = how much of its width (default 0.9).
-- The art's file and the crop for a w x h picture: path, left, right, top, bottom.
function EUI:ArtCoords(key, w, h, cx, cy, fw)
    local path = B() and B():ArtPath(key) or "Interface\\Glues\\LoadingScreens\\LoadScreenNagrandArenaBattlegrounds"
    w, h = max(1, w or 100), max(1, h or 50)
    cx, cy, fw = cx or 0.5, cy or 0.62, fw or 0.9
    local top = 0.21                       -- the logo's band
    local fh = fw * (4 / 3) * (h / w)
    if fh > 1 - top then
        fh = 1 - top
        fw = fh / ((4 / 3) * (h / w))
    end
    local l = min(max(cx - fw / 2, 0), 1 - fw)
    local t = min(max(cy - fh / 2, top), 1 - fh)
    return path, l, l + fw, t, t + fh
end

function EUI:SetArt(tex, key, w, h, cx, cy, fw)
    local path, l, r, t, b = self:ArtCoords(key, w, h, cx, cy, fw)
    tex:SetTexture(path)
    tex:SetTexCoord(l, r, t, b)
end

local function Gradient(tex, orient, r, g, b, a1, a2)
    if tex.SetGradient and CreateColor then
        tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2))
    else
        tex:SetColorTexture(r, g, b, (a1 + a2) / 2)
    end
end
EUI.Gradient = function(_, ...) return Gradient(...) end

-- The banner's shade over its art (left to right, bottom to top), so white text reads on any art. kind "card": only
-- the bottom (a library card's art fading into the card).
function EUI:AddShade(f, kind)
    local t = f:CreateTexture(nil, "BORDER", nil, 1)
    t:SetTexture(EUI.WHITE)
    t:SetAllPoints()
    local d = f:CreateTexture(nil, "BORDER", nil, 2)
    d:SetTexture(EUI.WHITE)
    d:SetAllPoints()
    if kind == "card" then
        Gradient(t, "VERTICAL", 0.10, 0.10, 0.12, 1, 0)
        d:Hide()
    else
        Gradient(t, "HORIZONTAL", 0.035, 0.035, 0.043, 0.92, 0.12)
        Gradient(d, "VERTICAL", 0.035, 0.035, 0.043, 0.9, 0)
    end
    f.shade = { t, d }
    return t, d
end

-- A 1px edge around a frame (the panels' look), coloured.
function EUI:Edge(f, r, g, b, a)
    if not f.edges then UI():AddEdges(f) end
    UI():SetEdgeColor(f, r or EUI.EDGE[1], g or EUI.EDGE[2], b or EUI.EDGE[3], a or EUI.EDGE[4])
end

---------------------------------------------------------------------------
-- Players
---------------------------------------------------------------------------

function EUI:ClassOf(key)
    if type(key) ~= "string" then return nil end
    local L = ns.EventLive
    local dummy = L and L.DummyClass and L:DummyClass(key)
    if dummy then return dummy end
    local G = ns.Guild
    return G and G.GetClass and G:GetClass(key) or nil
end

function EUI:IsMe(key) return Util() and Util().IsMe(key) or false end

-- The player's name for lists: "You" in blue for me (unless real), else in their class colour.
function EUI:Name(key, real)
    if type(key) ~= "string" then return "|cff6f6f74-|r" end
    if not real and self:IsMe(key) then return "|cff66b8ffYou|r" end
    local L = ns.EventLive
    if key:find("%-Practice$") and L then
        local r, g, b = UI():ClassColor(self:ClassOf(key))
        return ("|cff%02x%02x%02x%s|r"):format(r * 255, g * 255, b * 255, L.DisplayName(key))
    end
    return UI():ColoredName(key, self:ClassOf(key))
end

-- The name without colour.
function EUI:Plain(key)
    if type(key) ~= "string" then return "-" end
    local L = ns.EventLive
    if L and L.DisplayName then return L.DisplayName(key) end
    return Util().ShortName(key)
end

-- A class circle texture for a player (a dark disc for someone whose class isn't known).
function EUI:SetClass(tex, key)
    local cls = self:ClassOf(key)
    if cls then
        UI():ClassIcon(tex, cls)
        -- (a reused circle may have drawn an unknown player's dark disc before)
        tex:SetVertexColor(1, 1, 1, 1)
        tex:SetDesaturated(false)
        tex:SetAlpha(1)
    else
        tex:SetTexture(EUI.MASK)
        tex:SetTexCoord(0, 1, 0, 1)
        tex:SetVertexColor(0.2, 0.2, 0.23)
        tex:Show()
    end
end

---------------------------------------------------------------------------
-- Badges: the icon in a disc, a metallic ring tinted by its frame
---------------------------------------------------------------------------

-- size: the icon's diameter (the ring is 1/8 wider on each side). b:SetBadge(badge) with { n, i, f, ti, ev, at };
-- hovering shows what it is.
function EUI:CreateBadge(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    local ring = floor(size * 0.125 + 0.5) + 1
    f:SetSize(size + 2 * ring, size + 2 * ring)
    f.icon = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.icon:SetPoint("CENTER")
    f.icon:SetSize(size, size)
    if f.CreateMaskTexture then
        f.mask = f:CreateMaskTexture()
        f.mask:SetTexture(EUI.MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        f.mask:SetAllPoints(f.icon)
        f.icon:AddMaskTexture(f.mask)
    end
    f.ring = f:CreateTexture(nil, "OVERLAY", nil, 1)
    f.ring:SetTexture(EUI.RING)
    f.ring:SetAllPoints()
    f.shine = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.shine:SetTexture(EUI.MASK)
    f.shine:SetAllPoints(f.icon)
    f.shine:SetVertexColor(0, 0, 0, 0.18)
    function f:SetBadge(bd)
        self.badge = bd
        if not bd then self:Hide() return end
        self.icon:SetTexture(bd.i or "Interface\\Icons\\INV_Misc_QuestionMark")
        self.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        local c = B().FRAME_COLOR[bd.f or "gold"] or B().FRAME_COLOR.gold
        self.ring:SetVertexColor(c[1], c[2], c[3])
        self:Show()
    end
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        local bd = self.badge
        if not bd or self.noTip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(bd.n or "Badge", 1, 0.82, 0)
        if bd.ti and bd.ti ~= "" then GameTooltip:AddLine("Title: " .. bd.ti, 1, 1, 1) end
        if bd.ev then
            GameTooltip:AddLine(bd.ev .. (bd.at and (" · " .. date("%d %b", bd.at)) or ""), 0.62, 0.62, 0.62)
        end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return f
end

---------------------------------------------------------------------------
-- The stage progress line: done (green check), now (gold ring), next (grey ring)
---------------------------------------------------------------------------

-- p:Set(def, st [, sub]): st = a run's state (or nil: nothing started; a done event shows all done); sub = the text
-- after the current stage ("quarterfinals"). p:SetMaxWidth(w): what doesn't fit in w goes, in this order: the sub
-- text, the names of the other stages, the sub text again, the current stage's name (the rings alone).
function EUI:CreateProgress(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(10, 14)
    p.items = {}
    function p:SetMaxWidth(w) self.maxW = w end
    function p:Set(def, st, sub, done)
        local maxW = self.maxW or math.huge
        if self:Lay(def, st, sub, done, "all") <= maxW then return end
        if sub and self:Lay(def, st, nil, done, "all") <= maxW then return end
        if self:Lay(def, st, sub, done, "now") <= maxW then return end
        if sub and self:Lay(def, st, nil, done, "now") <= maxW then return end
        self:Lay(def, st, nil, done, "none")
    end
    -- names: "all" | "now" (the current stage's only) | "none". Returns the width.
    function p:Lay(def, st, sub, done, names)
        local stages = def and def.stages or {}
        local _, cur = B():Stage(def, st and st.stage)
        local over = done or (st and (st.phase == "done" or st.phase == "cancelled"))
        local x = 0
        local prevNamed = true
        for i, s in ipairs(stages) do
            local it = self.items[i]
            if not it then
                it = {}
                it.line = self:CreateTexture(nil, "ARTWORK")
                it.line:SetHeight(1)
                it.dot = self:CreateTexture(nil, "ARTWORK", nil, 1)
                it.dot:SetSize(12, 12)
                it.ring = self:CreateTexture(nil, "ARTWORK", nil, 2)
                it.ring:SetSize(12, 12)
                it.check = self:CreateTexture(nil, "OVERLAY")
                it.check:SetSize(9, 9)
                it.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
                it.fs = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                it.fs:SetWordWrap(false)
                self.items[i] = it
            end
            local state = over and "done" or (cur and (i < cur and "done" or (i == cur and "now" or "next")) or "next")
            local named = names == "all" or (names == "now" and state == "now")
            if i > 1 then
                -- (a shorter line between two rings without names)
                local pad = (prevNamed or named) and 7 or 4
                it.line:ClearAllPoints()
                it.line:SetPoint("LEFT", self, "LEFT", x + pad, 0)
                it.line:SetWidth((prevNamed or named) and 26 or 12)
                local prevDone = over or (cur and i - 1 < cur)
                if prevDone then it.line:SetColorTexture(0.35, 0.86, 0.47, 0.55) else it.line:SetColorTexture(1, 1, 1, 0.18) end
                it.line:Show()
                x = x + ((prevNamed or named) and 40 or 20)
            else
                it.line:Hide()
            end
            -- the ring sits at x; the disc in it is full (done, green), a small gold one (now) or none (next)
            it.ring:ClearAllPoints()
            it.ring:SetPoint("LEFT", self, "LEFT", x, 0)
            it.ring:SetTexture(EUI.RING)
            it.dot:ClearAllPoints()
            it.dot:SetPoint("CENTER", it.ring, "CENTER", 0, 0)
            it.dot:SetTexture(EUI.MASK)
            it.check:ClearAllPoints()
            it.check:SetPoint("CENTER", it.ring, "CENTER", 0, 0)
            if state == "done" then
                it.dot:SetSize(12, 12)
                it.dot:SetVertexColor(0.24, 0.71, 0.35, 0.3)
                it.ring:SetVertexColor(0.35, 0.86, 0.47)
                it.check:Show()
                it.fs:SetTextColor(0.84, 0.84, 0.84)
            elseif state == "now" then
                it.dot:SetSize(5, 5)
                it.dot:SetVertexColor(1, 0.82, 0, 1)
                it.ring:SetVertexColor(1, 0.82, 0)
                it.check:Hide()
                it.fs:SetTextColor(1, 0.95, 0.8)
            else
                it.dot:SetSize(12, 12)
                it.dot:SetVertexColor(0, 0, 0, 0)
                it.ring:SetVertexColor(0.44, 0.44, 0.46)
                it.check:Hide()
                it.fs:SetTextColor(0.66, 0.66, 0.68)
            end
            local text = s.name
            if state == "now" and sub and sub ~= "" then text = text .. " |cffb8a66a· " .. sub .. "|r" end
            it.fs:SetText(text)
            it.fs:ClearAllPoints()
            it.fs:SetPoint("LEFT", self, "LEFT", x + 18, 0)
            for _, t in ipairs({ it.dot, it.ring, it.fs }) do t:Show() end
            if named then
                x = x + 18 + EUI:TextWidth(it.fs)
            else
                it.fs:Hide()
                x = x + 12
            end
            prevNamed = named
        end
        for i = #stages + 1, #self.items do
            local it = self.items[i]
            for _, t in ipairs({ it.line, it.dot, it.ring, it.check, it.fs }) do t:Hide() end
        end
        self:SetWidth(max(10, x))
        return x
    end
    return p
end

-- A text's whole width on one line (GetStringWidth stops at a width the string was given on this client).
function EUI:TextWidth(fs)
    if fs.GetUnboundedStringWidth then return fs:GetUnboundedStringWidth() or 0 end
    return fs:GetStringWidth() or 0
end

-- What a live run's current stage is doing: "quarterfinals", "round 2 of 4", "signing up" (or nil).
function EUI:StageSub(def, st)
    if not (def and st) then return nil end
    local E = ns.EventEngine
    local bk = E and E:BracketOf(def, st)
    if bk and not bk.done and bk.r and bk.r > 0 then
        if bk.fmt == "robin" then return "round " .. bk.r .. " of " .. (bk.last or "?") end
        local left = (bk.last or 1) - bk.r
        if left == 0 then return "the final" end
        if left == 1 then return "semifinals" end
        if left == 2 then return "quarterfinals" end
        return "round " .. bk.r .. " of " .. (bk.last or "?")
    end
    for _, b in pairs(st.blocks or {}) do
        if b.kind == "signup" and b.open then return "signing up" end
    end
    return nil
end

-- The round's name in capitals for headers: "ROUND 1", "QUARTERFINALS", "SEMIFINALS", "FINAL".
function EUI:RoundName(bk, r)
    if not bk then return "" end
    if bk.fmt == "robin" then return "ROUND " .. r end
    local left = (bk.last or 1) - r
    if left == 0 then return "FINAL" end
    if left == 1 then return "SEMIFINALS" end
    if left == 2 then return "QUARTERFINALS" end
    return "ROUND " .. r
end

---------------------------------------------------------------------------
-- Dates
---------------------------------------------------------------------------

function EUI:When(t, withDay)
    if not t then return "" end
    if withDay == false then return date("%H:%M", t) end
    return date("%a %d %b · %H:%M", t)
end

function EUI:Day(t) return date("%a %d %b", t) end

-- "in 3 h", "in 2 days", "in 1 day", "now", "2 h ago". (Rounded up to the next unit: no "60 min", "24 h".)
function EUI:Relative(t)
    local now = (GetServerTime and GetServerTime()) or time()
    local d = t - now
    local a = math.abs(d)
    if a < 90 then return "now" end
    local s
    local m, h = floor(a / 60 + 0.5), floor(a / 3600 + 0.5)
    if m < 60 then s = m .. " min"
    elseif h < 24 then s = h .. " h"
    else
        local n = floor(a / 86400 + 0.5)
        s = n .. (n == 1 and " day" or " days")
    end
    return d > 0 and ("in " .. s) or (s .. " ago")
end

---------------------------------------------------------------------------
-- Icons
---------------------------------------------------------------------------

-- An atlas icon (UI.ICON) on a texture, white unless coloured.
function EUI:Glyph(tex, index, r, g, b, a)
    tex:SetTexture(UI().ICON_ATLAS)
    local c = UI():IconCoords(index)
    tex:SetTexCoord(c[1], c[2], c[3], c[4])
    tex:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
end

-- A category's colours (EventBlocks.CATS): fill, top fill, edge.
function EUI:CatColors(cat)
    local c = B().CAT[cat] or B().CAT.sm
    return c.f, c.f2, c.e
end

---------------------------------------------------------------------------
-- Part 2's shared look: circles of any size, a zone's map with the event's places, chips, segments, the time
-- left, medals. (The live board, the tracker and the builder's map sheet draw with these.)
---------------------------------------------------------------------------

EUI.ARROW = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\arrow"
EUI.TEAL = { 0.337, 0.839, 0.941 }          -- a place (#56d6f0)
EUI.TEAL_LT = { 0.612, 0.937, 1 }           -- its centre, a pointed place's yards (#9cefff)
EUI.TEAL_DONE = { 0.247, 0.714, 0.812 }     -- a list item done (#3fb6cf)
local cos, sin, pi, sqrt, ceil = math.cos, math.sin, math.pi, math.sqrt, math.ceil

-- The numbers' narrow font (Arial Narrow, no outline: the mockups' clocks, scores and ranks).
EUI.NARROW_FONT = "Fonts\\ARIALN.TTF"
function EUI:Narrow(fs, size)
    fs:SetFont(EUI.NARROW_FONT, size or 13, "")
    return fs
end

local function Disc(parent, layer, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    t:SetTexture(EUI.MASK)
    return t
end

-- The part of the segment p1-p2 inside the circle (cx, cy, R): x1, y1, x2, y2, or nil (all of it outside).
local function ClipSegment(x1, y1, x2, y2, cx, cy, R)
    local function inside(x, y) return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= R * R end
    local a, b = inside(x1, y1), inside(x2, y2)
    if a and b then return x1, y1, x2, y2 end
    local dx, dy = x2 - x1, y2 - y1
    local fx, fy = x1 - cx, y1 - cy
    local A = dx * dx + dy * dy
    local Bq = 2 * (fx * dx + fy * dy)
    local Cq = fx * fx + fy * fy - R * R
    local disc = Bq * Bq - 4 * A * Cq
    if A == 0 or disc < 0 then return nil end
    local s = sqrt(disc)
    local t1, t2 = (-Bq - s) / (2 * A), (-Bq + s) / (2 * A)
    local lo, hi = max(0, t1), min(1, t2)
    if hi <= lo then return nil end
    return x1 + dx * lo, y1 + dy * lo, x1 + dx * hi, y1 + dy * hi
end
EUI.ClipSegment = function(_, ...) return ClipSegment(...) end

-- A circle of any size, centred on its frame: c:Set(r, opts) with opts = { stroke = {r, g, b, a}, width (1.6),
-- shadow (a dark line under the stroke), fill = {r, g, b, a}, dot = {r, g, b, a}, dotSize, clip = { x, y, R }: only
-- what lies within that circle (offsets from this circle's centre) is drawn, the minimap's round edge }. The outline
-- is drawn with lines (thin at any size); a small circle uses the ring texture. The caller anchors c by its centre.
function EUI:CreateCircle(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(2, 2)
    c.lines, c.shadows = {}, {}
    c.fill = Disc(c, "ARTWORK", 0)
    c.fill:SetPoint("CENTER")
    c.ring = c:CreateTexture(nil, "ARTWORK", nil, 3)
    c.ring:SetTexture(EUI.RING)
    c.ring:SetPoint("CENTER")
    c.ringShadow = c:CreateTexture(nil, "ARTWORK", nil, 1)
    c.ringShadow:SetTexture(EUI.RING)
    c.ringShadow:SetPoint("CENTER")
    c.dot = Disc(c, "ARTWORK", 5)
    c.dot:SetPoint("CENTER")
    function c:Set(r, o)
        o = o or {}
        r = max(1, tonumber(r) or 1)
        self.r = r
        self:SetSize(max(2, 2 * r), max(2, 2 * r))
        local st, w = o.stroke or EUI.TEAL, o.width or 1.6
        local clip = o.clip
        -- the fill (only when nothing of it would be cut off by the round clip)
        local f = o.fill
        local whole = not clip or (sqrt(clip[1] * clip[1] + clip[2] * clip[2]) + r <= clip[3])
        if f and whole then
            self.fill:SetSize(2 * r, 2 * r)
            self.fill:SetVertexColor(f[1], f[2], f[3], f[4] or 0.2)
            self.fill:Show()
        else
            self.fill:Hide()
        end
        local n = 0
        if r <= 9 and whole then
            -- small: the ring texture (its line is about a tenth of its size)
            self.ring:SetSize(2 * r + 1, 2 * r + 1)
            self.ring:SetVertexColor(st[1], st[2], st[3], st[4] or 1)
            self.ring:Show()
            if o.shadow then
                self.ringShadow:SetSize(2 * r + 4, 2 * r + 4)
                self.ringShadow:SetVertexColor(0, 0, 0, 0.5)
                self.ringShadow:Show()
            else
                self.ringShadow:Hide()
            end
        else
            self.ring:Hide()
            self.ringShadow:Hide()
            local segs = max(16, min(120, ceil(2 * pi * r / 6)))
            for i = 1, segs do
                local a1, a2 = (i - 1) / segs * 2 * pi, i / segs * 2 * pi
                local x1, y1, x2, y2 = r * cos(a1), r * sin(a1), r * cos(a2), r * sin(a2)
                if clip then x1, y1, x2, y2 = ClipSegment(x1, y1, x2, y2, clip[1], clip[2], clip[3]) end
                if x1 then
                    n = n + 1
                    local l = self.lines[n]
                    if not l then
                        l = self:CreateLine(nil, "ARTWORK", nil, 3)
                        self.lines[n] = l
                        self.shadows[n] = self:CreateLine(nil, "ARTWORK", nil, 1)
                    end
                    l:SetStartPoint("CENTER", self, x1, y1)
                    l:SetEndPoint("CENTER", self, x2, y2)
                    l:SetThickness(w)
                    l:SetColorTexture(st[1], st[2], st[3], st[4] or 1)
                    l:Show()
                    local s = self.shadows[n]
                    if o.shadow then
                        s:SetStartPoint("CENTER", self, x1, y1)
                        s:SetEndPoint("CENTER", self, x2, y2)
                        s:SetThickness(w + 2)
                        s:SetColorTexture(0, 0, 0, 0.5)
                        s:Show()
                    else
                        s:Hide()
                    end
                end
            end
        end
        for i = n + 1, #self.lines do
            self.lines[i]:Hide()
            self.shadows[i]:Hide()
        end
        local d = o.dot
        if d and whole then
            local ds = o.dotSize or 4
            self.dot:SetSize(ds, ds)
            self.dot:SetVertexColor(d[1], d[2], d[3], d[4] or 1)
            self.dot:Show()
        else
            self.dot:Hide()
        end
        self:Show()
    end
    return c
end

-- A zone's map from its art layer (C_Map's tiles), cropped to a view that holds the event's places, with their rings
-- and names. m = EUI:CreateZoneMap(parent, w, h); m:SetMap(uiMapID) (false: no art there, a dark grid instead);
-- m:Fit(points [, minSpan]) with points = { { x, y, yd } } (0..1 on the map, a radius in yards); m:P(x, y) -> px from
-- the view's top left; m:Px(yards) -> px; m:Place(i, x, y, yd, name [, look]) shows place i as a ring, m:Done(n)
-- hides the rings after n. look: "place" (teal), "hot" (gold), "dim".
function EUI:CreateZoneMap(parent, w, h)
    local m = CreateFrame("Frame", nil, parent)
    m:SetSize(w, h)
    if m.SetClipsChildren then m:SetClipsChildren(true) end
    m.w, m.h = w, h
    m.bg = m:CreateTexture(nil, "BACKGROUND", nil, -8)
    m.bg:SetAllPoints()
    m.bg:SetColorTexture(0.102, 0.082, 0.047, 1)
    m.canvas = CreateFrame("Frame", nil, m)
    m.canvas:SetAllPoints()
    m.tiles, m.grid, m.rings, m.labels = {}, {}, {}, {}
    -- the frame: a faint light edge inside, a dark vignette along the sides
    m.top = CreateFrame("Frame", nil, m)
    m.top:SetAllPoints()
    m.top:SetFrameLevel(m.canvas:GetFrameLevel() + 6)
    UI():AddEdges(m.top, "OVERLAY", true)
    UI():SetEdgeColor(m.top, 1, 1, 1, 0.1)
    m.vig = {}
    for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = m.top:CreateTexture(nil, "ARTWORK")
        t:SetTexture(EUI.WHITE)
        if side == "TOP" or side == "BOTTOM" then
            t:SetPoint(side .. "LEFT")
            t:SetPoint(side .. "RIGHT")
            t:SetHeight(26)
            Gradient(t, "VERTICAL", 0, 0, 0, side == "TOP" and 0 or 0.32, side == "TOP" and 0.32 or 0)
        else
            t:SetPoint("TOP" .. side)
            t:SetPoint("BOTTOM" .. side)
            t:SetWidth(26)
            Gradient(t, "HORIZONTAL", 0, 0, 0, side == "LEFT" and 0.32 or 0, side == "LEFT" and 0 or 0.32)
        end
        m.vig[i] = t
    end
    function m:SetSize2(nw, nh)
        self.w, self.h = nw, nh
        self:SetSize(nw, nh)
    end
    -- the zone's art and its size in yards (EventSensors' map -> world, as the run measures)
    function m:SetMap(map)
        map = tonumber(map)
        self.map, self.L, self.files = map, nil, nil
        self.ydW, self.ydH = nil, nil
        if map and C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures then
            local ok, layers = pcall(C_Map.GetMapArtLayers, map)
            local L = ok and type(layers) == "table" and layers[1] or nil
            if L and (L.layerWidth or 0) > 0 and (L.tileWidth or 0) > 0 then
                local ok2, files = pcall(C_Map.GetMapArtLayerTextures, map, 1)
                if ok2 and type(files) == "table" and #files > 0 then self.L, self.files = L, files end
            end
        end
        local S = ns.EventSensors
        if map and S and S.World then
            local c0, x0, y0 = S.World(map, 0, 0)
            local c1, x1, y1 = S.World(map, 1, 0)
            local c2, x2, y2 = S.World(map, 0, 1)
            if c0 and c1 and c2 then
                self.ydW = sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
                self.ydH = sqrt((x2 - x0) ^ 2 + (y2 - y0) ^ 2)
                if self.ydW <= 0 or self.ydH <= 0 then self.ydW, self.ydH = nil, nil end
            end
        end
        return self.L ~= nil
    end
    -- the art's size in pixels (the layer's, else the classic 1002 x 668)
    function m:ArtSize()
        local L = self.L
        return (L and L.layerWidth) or 1002, (L and L.layerHeight) or 668
    end
    function m:SetView(x0, y0, spanX)
        local LW, LH = self:ArtSize()
        self.x0, self.y0, self.spanX = x0, y0, spanX
        self.s = self.w / (spanX * LW)
        self.spanY = self.h / self.s / LH
        self:Draw()
    end
    function m:Fit(points, minSpan)
        local LW, LH = self:ArtSize()
        local x1, y1, x2, y2
        for _, p in ipairs(points or {}) do
            local rx = (self.ydW and p[3]) and p[3] / self.ydW or 0.01
            local ry = (self.ydH and p[3]) and p[3] / self.ydH or 0.01
            x1, x2 = min(x1 or 1, p[1] - rx), max(x2 or 0, p[1] + rx)
            y1, y2 = min(y1 or 1, p[2] - ry), max(y2 or 0, p[2] + ry)
        end
        if not x1 then x1, y1, x2, y2 = 0.3, 0.3, 0.7, 0.7 end
        local bw, bh = x2 - x1, y2 - y1
        -- room around them (and under the lowest ring for its name)
        local need = max(minSpan or 0.3, bw * 1.25 + 0.02, (bh * 1.2 + 0.04) * (self.w * LH) / (self.h * LW))
        local span = min(1, need)
        local spanY = self.h * span * LW / (self.w * LH)
        local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2 + spanY * 0.02
        local x0 = min(max(cx - span / 2, 0), max(0, 1 - span))
        local y0 = spanY < 1 and min(max(cy - spanY / 2, 0), 1 - spanY) or (cy - spanY / 2)
        self:SetView(x0, y0, span)
    end
    function m:P(x, y)
        local LW, LH = self:ArtSize()
        return (x - self.x0) * LW * self.s, (y - self.y0) * LH * self.s
    end
    function m:Px(yd)
        if not self.ydW then return nil end
        local LW = self:ArtSize()
        return yd / self.ydW * LW * self.s
    end
    function m:Draw()
        for _, t in ipairs(self.tiles) do t:Hide() end
        for _, t in ipairs(self.grid) do t:Hide() end
        local L, files = self.L, self.files
        if L and files then
            local cols = ceil(L.layerWidth / L.tileWidth)
            local rows = ceil(L.layerHeight / L.tileHeight)
            local tw, th = L.tileWidth * self.s, L.tileHeight * self.s
            local ox, oy = -self.x0 * L.layerWidth * self.s, -self.y0 * L.layerHeight * self.s
            local n = 0
            for r = 1, rows do
                for c = 1, cols do
                    local file = files[(r - 1) * cols + c]
                    local x, y = ox + (c - 1) * tw, oy + (r - 1) * th
                    -- (only the tiles the view shows)
                    if file and x < self.w and y < self.h and x + tw > 0 and y + th > 0 then
                        n = n + 1
                        local t = self.tiles[n]
                        if not t then
                            t = self.canvas:CreateTexture(nil, "BACKGROUND", nil, -7)
                            self.tiles[n] = t
                        end
                        t:SetDrawLayer("BACKGROUND", -7)
                        t:ClearAllPoints()
                        t:SetTexture(file)
                        t:SetTexCoord(0, 1, 0, 1)
                        t:SetSize(tw, th)
                        t:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", x, -y)
                        t:SetVertexColor(0.52, 0.5, 0.47, 1)
                        t:Show()
                    end
                end
            end
            -- the explored parts on top (the player's own discovery, as the world map draws them)
            local E = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures
            local ok, ex = false, nil
            if E then ok, ex = pcall(E, self.map) end
            for _, o in ipairs(ok and type(ex) == "table" and ex or {}) do
                if not o.isShownByMouseOver and o.fileDataIDs then
                    -- (counted from the size, as Blizzard does: the info's own counts aren't reliable here)
                    local nw, nh = ceil(o.textureWidth / 256), ceil(o.textureHeight / 256)
                    for j = 1, nh do
                        for i = 1, nw do
                            local file = o.fileDataIDs[(j - 1) * nw + i]
                            -- 256 px pieces, the last in a row / column holds what's left
                            local pw = (i < nw) and 256 or (o.textureWidth - 256 * (nw - 1))
                            local ph = (j < nh) and 256 or (o.textureHeight - 256 * (nh - 1))
                            local px = ox + (o.offsetX + 256 * (i - 1)) * self.s
                            local py = oy + (o.offsetY + 256 * (j - 1)) * self.s
                            if file and pw > 0 and ph > 0 and px < self.w and py < self.h
                                and px + pw * self.s > 0 and py + ph * self.s > 0 then
                                n = n + 1
                                local t = self.tiles[n]
                                if not t then
                                    t = self.canvas:CreateTexture(nil, "BACKGROUND", nil, -6)
                                    self.tiles[n] = t
                                end
                                t:SetDrawLayer("BACKGROUND", -6)
                                t:ClearAllPoints()
                                t:SetTexture(file)
                                -- an edge piece's file is the next power of two up, not 256 (past 1 the edge smears)
                                local fw, fh = 1, 1
                                while fw < pw do fw = fw * 2 end
                                while fh < ph do fh = fh * 2 end
                                t:SetTexCoord(0, pw / fw, 0, ph / fh)
                                t:SetSize(pw * self.s, ph * self.s)
                                t:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", px, -py)
                                t:SetVertexColor(0.52, 0.5, 0.47, 1)
                                t:Show()
                            end
                        end
                    end
                end
            end
            self.bg:SetColorTexture(0.102, 0.082, 0.047, 1)
        else
            -- no art (an instance, a client without it): a dark grid
            self.bg:SetColorTexture(0.075, 0.075, 0.086, 1)
            local n, step = 0, 40
            for x = step, self.w - 1, step do
                n = n + 1
                local t = self.grid[n] or self.canvas:CreateTexture(nil, "BACKGROUND", nil, -7)
                self.grid[n] = t
                t:ClearAllPoints()
                t:SetColorTexture(1, 1, 1, 0.04)
                t:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", x, 0)
                t:SetSize(1, self.h)
                t:Show()
            end
            for y = step, self.h - 1, step do
                n = n + 1
                local t = self.grid[n] or self.canvas:CreateTexture(nil, "BACKGROUND", nil, -7)
                self.grid[n] = t
                t:ClearAllPoints()
                t:SetColorTexture(1, 1, 1, 0.04)
                t:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, -y)
                t:SetSize(self.w, 1)
                t:Show()
            end
        end
    end
    -- place i: its ring (its size in yards; a fixed small one when the map's yards aren't known) and its name under it
    local LOOK = {
        place = { stroke = EUI.TEAL, fill = { EUI.TEAL[1], EUI.TEAL[2], EUI.TEAL[3], 0.2 }, text = { 1, 1, 1 } },
        hot = { stroke = { 1, 0.82, 0 }, fill = { 1, 0.82, 0, 0.12 }, text = { 1, 0.82, 0 } },
        dim = { stroke = { 0.62, 0.62, 0.66 }, fill = { 1, 1, 1, 0.06 }, text = { 0.72, 0.72, 0.74 } },
    }
    function m:Place(i, x, y, yd, name, look)
        local c = self.rings[i]
        if not c then
            c = EUI:CreateCircle(self.canvas)
            c:SetFrameLevel(self.canvas:GetFrameLevel() + 2)
            local fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetWordWrap(false)
            local path, _, flags = fs:GetFont()
            if path then fs:SetFont(path, 10.5, flags) end
            fs:SetShadowOffset(1, -1)
            fs:SetShadowColor(0, 0, 0, 1)
            c.label = fs
            self.rings[i] = c
        end
        local lk = LOOK[look or "place"] or LOOK.place
        local px, py = self:P(x, y)
        local r = max(6, self:Px(tonumber(yd) or 30) or 6)
        c:ClearAllPoints()
        c:SetPoint("CENTER", self.canvas, "TOPLEFT", px, -py)
        c:Set(r, { stroke = lk.stroke, width = 1.6, shadow = true, fill = lk.fill, dot = EUI.TEAL_LT, dotSize = 4 })
        c.label:SetText(name or "")
        c.label:SetTextColor(lk.text[1], lk.text[2], lk.text[3])
        c.label:ClearAllPoints()
        c.label:SetPoint("CENTER", c, "CENTER", 0, -(r + 10))
        c.label:SetShown(name ~= nil and name ~= "")
        c.px, c.py = px, py
        return c
    end
    function m:Done(n)
        for i = n + 1, #self.rings do
            self.rings[i]:Hide()
            if self.rings[i].hit then self.rings[i].hit:Hide() end
        end
        -- (names that would lie on one another: the first one stays, the others are on their place's card)
        local kept = {}
        for i = 1, n do
            local c = self.rings[i]
            local fs = c and c.label
            if fs and fs:IsShown() and c.px then
                local tw = EUI:TextWidth(fs)
                local x1, y1 = c.px - tw / 2 - 2, c.py + (c.r or 6) + 10 - 7
                local x2, y2 = x1 + tw + 4, y1 + 14
                -- (a name the map's edge would cut: its card on hover says it)
                local clash = x1 < 0 or y1 < 0 or x2 > self.w or y2 > self.h
                for _, k in ipairs(kept) do
                    if x1 < k[3] and k[1] < x2 and y1 < k[4] and k[2] < y2 then clash = true break end
                end
                if clash then fs:Hide() else kept[#kept + 1] = { x1, y1, x2, y2 } end
            end
        end
    end
    -- place i's card on hover (info = { place = the def's place, click = fn }): its zone, coordinates and how far it
    -- is from me; with a click (the board, the event page) "Show the way". nil: no card.
    function m:PlaceInfo(i, info)
        local c = self.rings[i]
        if not c then return end
        local hit = c.hit
        if not info then
            if hit then hit:Hide() end
            return
        end
        if not hit then
            hit = CreateFrame("Button", nil, self.top)
            hit:SetFrameLevel(self.top:GetFrameLevel() + 2)
            hit:RegisterForClicks("LeftButtonUp")
            hit:SetScript("OnEnter", function(b) EUI:PlaceTip(b, b.info.place, b.info.click ~= nil) end)
            hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
            hit:SetScript("OnClick", function(b) if b.info and b.info.click then b.info.click() end end)
            c.hit = hit
        end
        hit.info = info
        -- (the middle of the ring: a big ring would take the whole map)
        local s = max(22, min(2 * (c.r or 6), 44))
        hit:SetSize(s, s)
        hit:ClearAllPoints()
        hit:SetPoint("CENTER", self.canvas, "TOPLEFT", c.px or 0, -(c.py or 0))
        hit:Show()
    end
    -- the zone's name, in a small pill at the top right (on: shown where the game names the map)
    function m:ShowZone(on)
        local z = self.zone
        if not z then
            z = CreateFrame("Frame", nil, self.top)
            z:SetSize(60, 22)
            z:SetFrameLevel(self.top:GetFrameLevel() + 1)
            UI():AddPillShape(z, 22)
            z:SetPillColors({ 0.055, 0.055, 0.066, 0.78 }, { 0.43, 0.43, 0.47, 0.6 })
            z.fs = z:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            local path, _, flags = z.fs:GetFont()
            if path then z.fs:SetFont(path, 11, flags) end
            z.fs:SetTextColor(0.91, 0.91, 0.91)
            z.fs:SetPoint("CENTER", 0, 0)
            self.zone = z
        end
        local name = on and EUI:MapName(self.map)
        if not name then z:Hide() return end
        z.fs:SetText(name)
        z:SetWidth(floor(EUI:TextWidth(z.fs) + 20 + 0.5))
        z:ClearAllPoints()
        z:SetPoint("TOPRIGHT", self, "TOPRIGHT", -10, -9)
        z:Show()
    end
    -- my own arrow (mine only: where I stand, the way I face), while I'm on this map in the open world
    function m:ShowMe(on)
        self.meOn = on and true or nil
        if not self.me then
            local me = CreateFrame("Frame", nil, self.canvas)
            me:SetSize(26, 26)
            me:SetFrameLevel(self.canvas:GetFrameLevel() + 5)
            me.glow = Disc(me, "ARTWORK", 0)
            me.glow:SetSize(24, 24)
            me.glow:SetPoint("CENTER")
            me.glow:SetVertexColor(EUI.YOU[1], EUI.YOU[2], EUI.YOU[3], 0.22)
            me.ring = me:CreateTexture(nil, "ARTWORK", nil, 1)
            me.ring:SetTexture(EUI.RING)
            me.ring:SetSize(25, 25)
            me.ring:SetPoint("CENTER")
            me.ring:SetVertexColor(EUI.YOU[1], EUI.YOU[2], EUI.YOU[3], 0.95)
            me.arrow = me:CreateTexture(nil, "ARTWORK", nil, 2)
            me.arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
            me.arrow:SetSize(20, 20)
            me.arrow:SetPoint("CENTER")
            me.fs = me:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            local path, _, flags = me.fs:GetFont()
            if path then me.fs:SetFont(path, 10.5, flags) end
            me.fs:SetShadowOffset(1, -1)
            me.fs:SetShadowColor(0, 0, 0, 1)
            me.fs:SetTextColor(EUI.YOU[1], EUI.YOU[2], EUI.YOU[3])
            me.fs:SetText("You")
            me.fs:SetPoint("LEFT", me, "CENTER", 15, 1)
            self.me = me
            -- (it follows me a few times a second while the map shows)
            local tick = CreateFrame("Frame", nil, self)
            tick.t = 0
            tick:SetScript("OnUpdate", function(f, dt)
                f.t = f.t + (dt or 0)
                if f.t < 0.25 then return end
                f.t = 0
                if self.meOn then self:PlaceMe() end
            end)
            self.meTick = tick
        end
        self:PlaceMe()
    end
    function m:PlaceMe()
        local me = self.me
        if not me then return end
        local x, y = EUI:MyMapPos(self.map)
        if not (self.meOn and x and self.x0 and self.s) then me:Hide() return end
        local px, py = self:P(x, y)
        if px < -6 or py < -6 or px > self.w + 6 or py > self.h + 6 then me:Hide() return end
        me:ClearAllPoints()
        me:SetPoint("CENTER", self.canvas, "TOPLEFT", px, -py)
        local face = ns.EventSensors and ns.EventSensors.Facing and ns.EventSensors.Facing()
        if me.arrow.SetRotation then me.arrow:SetRotation(face or 0) end
        -- ("You" on the side with room, off the places' names; with room on neither side the arrow says it alone)
        local tw = EUI:TextWidth(me.fs)
        local function clear(x1)
            if x1 < 0 or x1 + tw > self.w then return false end
            for _, c in ipairs(self.rings) do
                local fs = c:IsShown() and c.label
                if fs and fs:IsShown() and c.px then
                    local lw = EUI:TextWidth(fs)
                    local lx, ly = c.px - lw / 2, c.py + (c.r or 6) + 10
                    if x1 < lx + lw and lx < x1 + tw and py - 7 < ly + 7 and ly - 7 < py + 7 then return false end
                end
            end
            return true
        end
        me.fs:ClearAllPoints()
        local rightFirst = px <= self.w - 50
        local a, b2 = px + 15, px - 15 - tw
        if clear(rightFirst and a or b2) then
            if rightFirst then me.fs:SetPoint("LEFT", me, "CENTER", 15, 1) else me.fs:SetPoint("RIGHT", me, "CENTER", -15, 1) end
            me.fs:Show()
        elseif clear(rightFirst and b2 or a) then
            if rightFirst then me.fs:SetPoint("RIGHT", me, "CENTER", -15, 1) else me.fs:SetPoint("LEFT", me, "CENTER", 15, 1) end
            me.fs:Show()
        else
            me.fs:Hide()
        end
        me:Show()
    end
    return m
end

---------------------------------------------------------------------------
-- Where a place is (the event's places): its zone, coordinates, the way from me
---------------------------------------------------------------------------

-- A text's width (unbounded: what it needs on one line).
function EUI:TextWidth(fs)
    return (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth() or 0
end

function EUI:MapName(map)
    map = tonumber(map)
    if not (map and C_Map and C_Map.GetMapInfo) then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, map)
    local n = ok and type(info) == "table" and info.name or nil
    return (n and n ~= "") and n or nil
end

-- A place's zone: the one it was set in (standing there), else its map's name.
function EUI:PlaceZone(p)
    if type(p) ~= "table" then return nil end
    if type(p.z) == "string" and p.z ~= "" then return p.z end
    return self:MapName(p.map)
end

-- Its map coordinates as the game's maps say them: "41.2, 52.8" (digits 1), "41, 52" (digits 0); nil without any.
function EUI:Coords(p, digits)
    local x, y = type(p) == "table" and tonumber(p.x), type(p) == "table" and tonumber(p.y)
    if not (x and y) then return nil end
    if (digits or 1) == 0 then return floor(x * 100) .. ", " .. floor(y * 100) end
    return string.format("%.1f, %.1f", floor(x * 1000) / 10, floor(y * 1000) / 10)
end

-- Where I am on a map (0..1), or nil (not on it, in an instance, the game doesn't say).
function EUI:MyMapPos(map)
    map = tonumber(map)
    if not (map and C_Map and C_Map.GetPlayerMapPosition) then return nil end
    if IsInInstance and IsInInstance() then return nil end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
    if not ok or type(pos) ~= "table" or not pos.GetXY then return nil end
    local x, y = pos:GetXY()
    if not (x and y) or x < 0 or x > 1 or y < 0 or y > 1 or (x == 0 and y == 0) then return nil end
    return x, y
end

-- How far a place is from me: yards, or nil and why ("instance": I'm in one; "far": another continent, unknown).
function EUI:YardsTo(p)
    local S = ns.EventSensors
    if type(p) ~= "table" or not (S and S.MyPos and S.Yards) then return nil, "far" end
    if IsInInstance and IsInInstance() then return nil, "instance" end
    local ok, me = pcall(S.MyPos, S)
    if not (ok and me) then return nil, "far" end
    local yd = S.Yards(me, p)
    if not yd then return nil, "far" end
    return yd, nil, me
end

-- A place's card in the tooltip: its name, zone and coordinates, how far from me, and "Click: show the way".
function EUI:PlaceTip(owner, p, click)
    if type(p) ~= "table" then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(p.n or "A place")
    local zone, xy = self:PlaceZone(p), self:Coords(p, 1)
    local where = (zone and xy) and (zone .. " · " .. xy) or zone or xy
    if where then GameTooltip:AddLine(where, 0.85, 0.85, 0.85) end
    local yd, why = self:YardsTo(p)
    if yd then
        GameTooltip:AddLine(floor(yd + 0.5) .. " yd from you", EUI.TEAL_LT[1], EUI.TEAL_LT[2], EUI.TEAL_LT[3])
    else
        GameTooltip:AddLine(why == "instance" and "You're in an instance: places are in the open world"
            or "Too far from here to measure", 0.62, 0.62, 0.62, true)
    end
    if click then GameTooltip:AddLine("Click: show the way", 0.45, 0.9, 0.55) end
    GameTooltip:Show()
end

-- "Show the way" to one of an event's places: the tracker's arrow and the place's ring on the minimap (my own,
-- never sent; the host's pointing replaces it). Says what happened in the chat frame.
function EUI:ShowTheWay(occ, pid, def)
    local L = ns.EventLive
    local p = type(def) == "table" and type(def.places) == "table" and def.places[pid] or nil
    local ok = occ and L and L.PointMe and L:PointMe(occ, pid)
    if ok then
        ns:Print("%s", "showing the way to " .. ((p and p.n) or "the place") .. ": follow the arrow under your minimap.")
    else
        ns:Print("%s", "there's no way to show here: this board is made up (demo mode) or the place is gone.")
    end
    return ok and true or false
end

-- A tag as a chip: a dot in its colour and its name. chip:Set(text, rgb [, kind]): kind "track" (the tracker's,
-- 18 high), "you" (the board's header: a blue edge, 22 high).
function EUI:CreateChip(parent, kind)
    local h = kind == "you" and 22 or 18
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(40, h)
    UI():AddPillShape(p, h)
    p.kind = kind
    if kind == "you" then
        p:SetPillColors({ 0.055, 0.055, 0.066, 1 }, { 0.4, 0.72, 1, 0.75 })
    else
        p:SetPillColors({ 0.039, 0.039, 0.051, 0.7 }, { 1, 1, 1, 0.25 })
    end
    p.dot = Disc(p, "ARTWORK", 2)
    p.dot:SetSize(8, 8)
    p.dotEdge = Disc(p, "ARTWORK", 1)
    p.dotEdge:SetSize(10, 10)
    p.dotEdge:SetVertexColor(0, 0, 0, 1)
    p.cls = p:CreateTexture(nil, "ARTWORK", nil, 2)
    p.cls:SetSize(14, 14)
    p.fs = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.fs:SetWordWrap(false)
    local path, _, flags = p.fs:GetFont()
    if path then p.fs:SetFont(path, 11, flags) end
    p.fs:SetShadowOffset(1, -1)
    p.fs:SetShadowColor(0, 0, 0, 1)
    -- rgb: the dot's colour; or key: a player's class circle instead of the dot
    function p:Set(text, rgb, key)
        local x = (self.kind == "you") and 7 or 6
        self.dot:ClearAllPoints()
        self.dotEdge:ClearAllPoints()
        self.cls:ClearAllPoints()
        if key then
            self.dot:Hide()
            self.dotEdge:Hide()
            EUI:SetClass(self.cls, key)
            self.cls:SetPoint("LEFT", x, 0)
            self.cls:Show()
            x = x + 14 + 6
        elseif rgb then
            self.cls:Hide()
            self.dot:SetPoint("LEFT", x + 1, 0)
            self.dotEdge:SetPoint("CENTER", self.dot)
            self.dot:SetVertexColor(rgb[1], rgb[2], rgb[3], 1)
            self.dot:Show()
            self.dotEdge:Show()
            x = x + 8 + 6
        else
            self.dot:Hide()
            self.dotEdge:Hide()
            self.cls:Hide()
            x = x + 3
        end
        self.fs:ClearAllPoints()
        self.fs:SetPoint("LEFT", x - 1, 0)
        self.fs:SetText(text or "")
        if self.kind == "you" then self.fs:SetTextColor(0.84, 0.93, 1) else self.fs:SetTextColor(0.94, 0.94, 0.94) end
        self:SetWidth(floor(x + EUI:TextWidth(self.fs) + ((self.kind == "you") and 10 or 8) + 0.5))
    end
    return p
end

-- A list walked in steps (a route): one segment a step, the done ones filled, the next one outlined.
-- s:Set(n, done [, finished]); look "board" (the board's rows) | "track" (the tracker: brighter empties, a dark edge).
function EUI:CreateSegments(parent, w, h, look)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(w, h)
    s.look = look or "board"
    s.segs = {}
    function s:Set(n, done, finished)
        n = max(0, min(40, tonumber(n) or 0))
        done = max(0, min(n, tonumber(done) or 0))
        local gap = n > 16 and 1 or 2
        local W = self:GetWidth()
        local sw = n > 0 and (W - gap * (n - 1)) / n or 0
        for i = 1, n do
            local g = self.segs[i]
            if not g then
                g = { bg = self:CreateTexture(nil, "ARTWORK", nil, 1) }
                g.edge = {}
                for k = 1, 4 do g.edge[k] = self:CreateTexture(nil, "ARTWORK", nil, 2) end
                g.shade = self:CreateTexture(nil, "ARTWORK", nil, 0)
                self.segs[i] = g
            end
            local x = (i - 1) * (sw + gap)
            g.bg:ClearAllPoints()
            g.bg:SetPoint("TOPLEFT", self, "TOPLEFT", x, 0)
            g.bg:SetSize(max(1, sw), self:GetHeight())
            local state = (finished or i <= done) and "d" or (i == done + 1 and "n" or "e")
            local T, D = EUI.TEAL, EUI.TEAL_DONE
            if state == "d" then
                local c = finished and T or D
                g.bg:SetColorTexture(c[1], c[2], c[3], 1)
            elseif state == "n" then
                g.bg:SetColorTexture(T[1], T[2], T[3], self.look == "track" and 0.3 or 0.25)
            else
                g.bg:SetColorTexture(1, 1, 1, self.look == "track" and 0.18 or 0.1)
            end
            g.bg:Show()
            -- the next one: a 1px outline; the tracker's empties: a dark edge to read on the world
            for k, e in ipairs(g.edge) do
                e:ClearAllPoints()
                if state == "n" then
                    e:SetColorTexture(T[1], T[2], T[3], 0.9)
                    if k == 1 then e:SetPoint("TOPLEFT", g.bg); e:SetPoint("TOPRIGHT", g.bg); e:SetHeight(1)
                    elseif k == 2 then e:SetPoint("BOTTOMLEFT", g.bg); e:SetPoint("BOTTOMRIGHT", g.bg); e:SetHeight(1)
                    elseif k == 3 then e:SetPoint("TOPLEFT", g.bg); e:SetPoint("BOTTOMLEFT", g.bg); e:SetWidth(1)
                    else e:SetPoint("TOPRIGHT", g.bg); e:SetPoint("BOTTOMRIGHT", g.bg); e:SetWidth(1) end
                    e:Show()
                else
                    e:Hide()
                end
            end
            if self.look == "track" then
                g.shade:ClearAllPoints()
                g.shade:SetPoint("TOPLEFT", g.bg, "TOPLEFT", -1, 1)
                g.shade:SetPoint("BOTTOMRIGHT", g.bg, "BOTTOMRIGHT", 1, -1)
                g.shade:SetColorTexture(0, 0, 0, 0.5)
                g.shade:Show()
            else
                g.shade:Hide()
            end
        end
        for i = n + 1, #self.segs do
            local g = self.segs[i]
            g.bg:Hide()
            g.shade:Hide()
            for _, e in ipairs(g.edge) do e:Hide() end
        end
    end
    return s
end

-- "Time left": the big clock, "of 20 min", a gold bar, what ends when and what comes then. t:Set(left, total, l, r).
function EUI:CreateTimeLeft(parent, w)
    local t = CreateFrame("Frame", nil, parent)
    t:SetSize(w, 79)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    t.bg:SetColorTexture(0.086, 0.086, 0.106, 0.96)
    UI():AddEdges(t, "BORDER", true)
    UI():SetEdgeColor(t, 0.34, 0.34, 0.38, 0.6)
    local function text(size, r, g, b, font)
        local fs = t:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
        fs:SetWordWrap(false)
        fs:SetJustifyH("LEFT")
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
        fs:SetTextColor(r, g, b)
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 1)
        return fs
    end
    t.big = text(30, 1, 1, 1)
    EUI:Narrow(t.big, 30)
    t.big:SetPoint("TOPLEFT", 10, -9)
    t.of = text(12, 0.62, 0.62, 0.62)
    t.of:SetPoint("BOTTOMLEFT", t.big, "BOTTOMRIGHT", 6, 3)
    t.track = t:CreateTexture(nil, "ARTWORK")
    t.track:SetPoint("TOPLEFT", 10, -48)
    t.track:SetPoint("TOPRIGHT", -10, -48)
    t.track:SetHeight(3)
    t.track:SetColorTexture(1, 1, 1, 0.1)
    t.bar = t:CreateTexture(nil, "ARTWORK", nil, 1)
    t.bar:SetPoint("TOPLEFT", t.track, "TOPLEFT")
    t.bar:SetHeight(3)
    t.bar:SetTexture(EUI.WHITE)
    Gradient(t.bar, "HORIZONTAL", 1, 0.82, 0, 1, 1)
    if t.bar.SetGradient and CreateColor then
        t.bar:SetGradient("HORIZONTAL", CreateColor(0.72, 0.54, 0.06, 1), CreateColor(1, 0.82, 0, 1))
    end
    t.l = text(10.5, 0.62, 0.62, 0.62)
    t.l:SetPoint("TOPLEFT", 10, -57)
    t.r = text(10.5, 0.62, 0.62, 0.62)
    t.r:SetJustifyH("RIGHT")
    t.r:SetPoint("TOPRIGHT", -10, -57)
    function t:Set(left, total, ltext, rtext)
        left, total = max(0, tonumber(left) or 0), max(1, tonumber(total) or 1)
        local sec = floor(left + 0.5)
        if sec >= 3600 then
            self.big:SetText(("%d:%02d:%02d"):format(floor(sec / 3600), floor(sec % 3600 / 60), sec % 60))
        else
            self.big:SetText(("%d:%02d"):format(floor(sec / 60), sec % 60))
        end
        local mins = floor(total / 60 + 0.5)
        self.of:SetText(total >= 60 and ("of " .. (mins >= 120 and (floor(mins / 60 + 0.5) .. " h") or (mins .. " min")))
            or ("of " .. floor(total) .. " s"))
        local W = max(1, self:GetWidth() - 20)
        self.bar:SetWidth(max(1, W * min(1, left / total)))
        self.bar:SetShown(left > 0)
        self.r:SetText(rtext or "")
        local rw = (rtext and rtext ~= "") and (EUI:TextWidth(self.r) + 8) or 0
        self.l:SetText(ltext or "")
        -- (what doesn't fit goes: the right side's words first)
        if EUI:TextWidth(self.l) + rw > W then
            self.r:SetText("")
        end
    end
    return t
end

-- A place medal: 1, 2, 3 on a gold, silver or bronze disc with a light on it. m:Set(n) (nil: hidden).
local MEDAL = {
    { { 0.84, 0.65, 0.08 }, { 1, 0.95, 0.69 }, { 0.16, 0.11, 0 } },
    { { 0.66, 0.69, 0.74 }, { 1, 1, 1 }, { 0.11, 0.13, 0.15 } },
    { { 0.72, 0.41, 0.18 }, { 1, 0.85, 0.72 }, { 0.16, 0.08, 0.02 } },
}
function EUI:CreateMedal(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.base = Disc(f, "ARTWORK", 1)
    f.base:SetAllPoints()
    f.shade = Disc(f, "ARTWORK", 2)
    f.shade:SetSize(size, size)
    f.shade:SetPoint("CENTER", 1.5, -2)
    f.light = Disc(f, "ARTWORK", 3)
    f.light:SetSize(size * 0.55, size * 0.55)
    f.light:SetPoint("CENTER", -size * 0.15, size * 0.18)
    f.fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.fs:SetPoint("CENTER", 0, 0)
    EUI:Narrow(f.fs, 13)
    f.fs:SetShadowOffset(0, 0)
    function f:Set(n)
        local m = MEDAL[n]
        if not m then self:Hide() return end
        self.base:SetVertexColor(m[1][1], m[1][2], m[1][3], 1)
        self.shade:SetVertexColor(m[3][1], m[3][2], m[3][3], 0.45)
        self.light:SetVertexColor(m[2][1], m[2][2], m[2][3], 0.42)
        self.fs:SetText(tostring(n))
        self.fs:SetTextColor(m[3][1], m[3][2], m[3][3])
        self:Show()
    end
    return f
end

-- An item's icon (a file id or path), or nil while the client doesn't have it.
function EUI:ItemIcon(item)
    item = tonumber(item)
    if not item then return nil end
    if C_Item and C_Item.GetItemIconByID then
        local ok, icon = pcall(C_Item.GetItemIconByID, item)
        if ok and icon then return icon end
    end
    if GetItemIcon then
        local ok, icon = pcall(GetItemIcon, item)
        if ok and icon then return icon end
    end
    return nil
end

-- "0:40 ago", "1 min ago", "3 h ago" for a time `sec` ago.
function EUI:Ago(sec)
    sec = max(0, floor(tonumber(sec) or 0))
    if sec < 60 then return ("0:%02d ago"):format(sec) end
    if sec < 3600 then return floor(sec / 60) .. " min ago" end
    return floor(sec / 3600 + 0.5) .. " h ago"
end

function EUI:OnInit() end
