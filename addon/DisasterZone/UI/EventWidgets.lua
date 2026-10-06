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

function EUI:OnInit() end
