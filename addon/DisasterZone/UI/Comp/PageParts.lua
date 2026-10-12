if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Comp/PageParts.lua", ...) then return end -- DisasterZone UI/Comp/PageParts.lua
-- page parts: banner, back link, section header (refactor phase 2).
local addonName, ns = ...

-- The parts every page is made of, in the finish of the best pages of 1.3 (the raid page's hero, the guest profile,
-- the Events and Polls banners, the Events / Guest book section titles, the Blessings planner's caps rules):
--   UI:CreatePageBanner(parent, opts)     an art banner (a raid's loading screen under the shade), its back link,
--                                         kicker, title (+ a pill), sub line, tools at the top right and the actions
--                                         at the bottom right (one gold primary)
--   UI:CreateBackLink(parent, text, fn)   the small caps link with a left chevron (grey, gold under the mouse)
--   UI:CreateSectionHeader(parent, title, opts)   "title" (gold, a hairline under it) or "caps" (grey capitals, a
--                                         fading rule after them), with a count, a right text and an action
-- All of them read their values from ns.Style (UI/Style.lua) and draw with the primitives of UI/Widgets.lua.

local UI = ns.UI
local S = ns.Style

local CreateFrame = CreateFrame
local floor, max, min = math.floor, math.max, math.min
local type, tostring, ipairs, pairs = type, tostring, ipairs, pairs

-- (the values a banner over art uses; the rest are ns.Style tokens)
local GOLD, LINE = S.C.GOLD, S.C.HAIRLINE
local P = {
    WHITE = { 1, 1, 1 },                      -- the title over art (the raid page's GameFontHighlightLarge)
    ON_ART = { 0.82, 0.82, 0.82 },            -- the sub line over art (the guest profile's, the Events meta)
    PLAIN = { 0.105, 0.105, 0.125, 1 },       -- a banner without art: the guest profile's dark card ...
    GLOW = S:WithAlpha(GOLD, 0.06),                 -- ... with a little gold light from the left
    GLOW_END = S:WithAlpha(GOLD, 0),
    GLOW_W = 300,
    RING = S:WithAlpha(GOLD, 0.55),                 -- the icon's ring (the Events banner)
    BLACK = { 0, 0, 0, 1 },
    SHADE = { 0.035, 0.035, 0.043 },          -- EUI:AddShade's colour (used when EventWidgets is not there)
    X = 14,                                   -- the banner's inner left / right margin
    BACK_Y = 11,                              -- the back link's row
    TOP = 14, TOP_BACK = 34,                  -- where the text starts: without / under the back link
    TOOL_Y = 9, TOOL = 22, TOOL_GAP = 4,      -- the icon tools at the top right
    EDGE_X = 12,                              -- the tools' and actions' distance from the right edge
    ACT_Y = 12, ACT_GAP = 6, ACT_MIN = 56, ACT_PAD = 28,   -- the actions at the bottom right
    FOOT_H = 26,                              -- banner.foot's height (tabs on the banner's foot)
    FOOT_FADE = 44,                           -- with a reserved foot: the art fades into the page over this
    RULE_HI = S:WithAlpha(LINE, 0.14), RULE_LO = S:WithAlpha(LINE, 0.04),   -- the caps header's fading rule
    BACK = "SUB",                             -- the back link's rest colour (gold under the mouse)
}

-- Each size: the title's style, the icon's size, the gaps of the text stack, whether the stack hangs from the top
-- (a tall banner) or sits on the middle (a strip).
local SIZES = {
    hero  = { h = S.BANNER.hero,  title = "hero",  icon = 44, gapK = 6, gapS = 6, tall = true },
    tool  = { h = S.BANNER.tool,  title = "hero",  icon = 40, gapK = 5, gapS = 5, tall = true, titleColor = "GOLD" },
    strip = { h = S.BANNER.strip, title = "title", icon = 26, gapK = 2, gapS = 2 },
}

local function SizeOf(size)
    if type(size) == "number" then
        local base = size >= 100 and SIZES.hero or (size >= 70 and SIZES.tool or SIZES.strip)
        local m = {}
        for k, v in pairs(base) do m[k] = v end
        m.h = size
        return m
    end
    return SIZES[size] or SIZES.hero
end

local function Upper(s) return (s:gsub("[a-z]+", string.upper)) end

-- text upper-cased outside its escapes (a colour code, a texture, a link's head keep their case). Only a-z change:
-- the bytes of a UTF-8 letter (past 127) stay as they are.
local function Caps(text)
    text = text == nil and "" or tostring(text)
    if not text:find("|", 1, true) then return Upper(text) end
    local out, i, n = {}, 1, #text
    while i <= n do
        local j = text:find("|", i, true)
        if not j then
            out[#out + 1] = Upper(text:sub(i))
            break
        end
        out[#out + 1] = Upper(text:sub(i, j - 1))
        local k = text:sub(j + 1, j + 1)
        local e
        if k == "c" then
            e = j + 9
        elseif k == "T" or k == "A" then
            e = (text:find("|" .. k:lower(), j + 2, true) or n) + 1
        elseif k == "H" then
            e = (text:find("|h", j + 2, true) or n) + 1
        else
            e = j + 1                                           -- |r, |h, ||, |n
        end
        out[#out + 1] = text:sub(j, e)
        i = e + 1
    end
    return table.concat(out)
end
-- (the same for callers: UI:CapsText(text))
function UI:CapsText(text) return Caps(text) end

local function Shown(fs)
    return fs:IsShown() and (fs:GetText() or "") ~= ""
end

local function Paint(target, c)
    local r, g, b = S:Color(c)
    if target:GetObjectType() == "FontString" then target:SetTextColor(r, g, b) else target:SetVertexColor(r, g, b) end
end

-- An atlas icon (a UI.ICON name or index below 1000) on tex; a texture path / file id, or { path, l, r, t, b }.
-- crop: trim a plain texture's border (an item / spell icon in a tile).
local function SetIconTexture(tex, icon, crop)
    if type(icon) == "string" and UI.ICON and UI.ICON[icon] then icon = UI.ICON[icon] end
    if type(icon) == "number" and icon < 1000 then
        local c = UI:IconCoords(icon)
        tex:SetTexture(UI.ICON_ATLAS)
        tex:SetTexCoord(c[1], c[2], c[3], c[4])
    elseif type(icon) == "table" then
        tex:SetTexture(icon[1])
        tex:SetTexCoord(icon[2] or 0, icon[3] or 1, icon[4] or 0, icon[5] or 1)
    else
        tex:SetTexture(icon)
        if crop then tex:SetTexCoord(0.07, 0.93, 0.07, 0.93) else tex:SetTexCoord(0, 1, 0, 1) end
    end
end

-- A tooltip from an action's tip: a string (the title), or { title, text }; nil takes it away.
local function SetTip(f, tip)
    if type(tip) == "table" then
        UI:AttachTooltip(f, tip[1] or tip.title, tip[2] or tip.text)
    elseif tip then
        UI:AttachTooltip(f, tip, nil)
    elseif f.cdlTip then
        UI:AttachTooltip(f, nil, nil)
    end
end

-- A click on an action / tool / header link: its menu (under it) or its onClick(button, mouseButton).
local function ActionClick(self, button)
    local a = self.ppAction
    if not a then return end
    if a.menu then
        UI:ContextMenu(self, a.menu)
    elseif a.onClick then
        a.onClick(self, button)
    end
end

---------------------------------------------------------------------------
-- Back link
---------------------------------------------------------------------------

local function PaintBack(self, on)
    local c = on and "GOLD" or P.BACK
    Paint(self.text, c)
    Paint(self.icon, c)
end

-- The way back to a list or board: a left chevron and a caps word ("ALL RAIDS"), grey, gold under the mouse.
-- b.icon (the chevron), b.text (= b.fs); b:SetText(text) fits the width; b:SetOnClick(fn); fn(b, mouseButton).
-- opts: { forward = true: the way on ("RECENT RUNS  4 >"): the words first, the chevron after them pointing right }.
function UI:CreateBackLink(parent, text, onClick, opts)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(80, 14)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(10, 10)
    b.text = UI:Text(b, "small", P.BACK)
    if opts and opts.forward then
        b.text:SetPoint("LEFT", b, "LEFT", 0, 0)
        b.icon:SetPoint("LEFT", b.text, "RIGHT", 4, 0)
        UI:SetChevron(b.icon, true)
    else
        b.icon:SetPoint("LEFT", 0, 0)
        UI:SetChevron(b.icon, false)
        b.text:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
    end
    b.fs = b.text
    function b:SetText(t)
        self.label = t
        self.text:SetText(Caps(t))
        self:SetWidth(floor(14 + UI:TextWidth(self.text) + 0.5))
    end
    function b:GetText() return self.label end
    function b:SetOnClick(fn) self.onClick = fn end
    b.onClick = onClick
    b:SetScript("OnEnter", function(self) PaintBack(self, true) end)
    b:SetScript("OnLeave", function(self) PaintBack(self, false) end)
    b:SetScript("OnClick", function(self, button) if self.onClick then self.onClick(self, button) end end)
    b:SetText(text or "Back")
    PaintBack(b, false)
    return b
end

---------------------------------------------------------------------------
-- Banner
---------------------------------------------------------------------------

local Banner = {}       -- the banner's methods (copied onto each banner)

-- A pill over dark art (UI:CreatePill on the banner's dark base; Banner:SetPill takes every pill kind).
local function NewPill(parent)
    local p = UI:CreatePill(parent, 16)
    p:SetBase(0.05, 0.05, 0.06)
    return p
end

-- The icon's tile: a black 1 px frame in a ring (the Events / Polls banners' icon).
local function NewIconTile(parent, size, ring)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.ring = UI:Fill(f, ring or P.RING, "BACKGROUND", -1)
    f.ring:ClearAllPoints()
    f.ring:SetPoint("TOPLEFT", -2, 2)
    f.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    f.outer = UI:Fill(f, P.BLACK, "BACKGROUND", 0)
    f.outer:ClearAllPoints()
    f.outer:SetPoint("TOPLEFT", -1, 1)
    f.outer:SetPoint("BOTTOMRIGHT", 1, -1)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    return f
end

-- The shade over the art: EUI:AddShade (the banners' one shade), or the same gradients when it is not loaded.
local function AddShade(b)
    local E = ns.EventUI
    if E and E.AddShade then return E:AddShade(b) end
    local c = P.SHADE
    local t = b:CreateTexture(nil, "BORDER", nil, 1)
    t:SetAllPoints()
    UI:Gradient(t, "HORIZONTAL", { c[1], c[2], c[3], 0.92 }, { c[1], c[2], c[3], 0.12 })
    local d = b:CreateTexture(nil, "BORDER", nil, 2)
    d:SetAllPoints()
    UI:Gradient(d, "VERTICAL", { c[1], c[2], c[3], 0.9 }, { c[1], c[2], c[3], 0 })
    b.shade = { t, d }
    return t, d
end

-- UI:CreatePageBanner(parent, opts) -> banner. opts:
--   size     "hero" (128) | "tool" (84) | "strip" (46) | a height
--   art      a raid key (either form or an instance id: ns.ItemDB:RaidArt, cropped to the banner) | { path, l, r, t, b }
--            | nil (the plain dark card with a gold glow); banner:SetArt(art, desaturate, art2): two pictures side by
--            side (a raid of two instances: banner.art2, banner.artSeam). artFw (0.95: the share of the picture's width a raid's crop
--            takes), artUnder (keep the crop under the logo band), artTint (1: the art's brightness), desaturate
--   icon     a texture / file id / { path, l, r, t, b } / a UI.ICON name: a ringed tile left of the text. iconRing
--   kicker   small gold capitals over the title (kickerColor; kickerCaps = false keeps the case); kickerTip =
--            { title, lines }: a tooltip on it (banner:SetKickerTip)
--   title    the 19 px title (titleColor: white; a tool banner's is gold; a strip's is 13 px), cut with "..." to fit;
--            titleSteps = { "hero", "page", ... }: smaller styles tried first; rightW = px (or function(banner)) kept
--            free at the right of the text for the page's own blocks (banner:SetTitleFit(steps, rightW));
--            titleLines = n: it wraps onto n lines at most instead (cut with "..." on the last)
--   sub      the line under it (subColor)
--   pill     { kind, text } after the title (the EUI pill kinds: live, rank, review, changed, draft, ended, ok ...)
--   back     { text, onClick }: the back link at the top left (a strip: at the left, before the text)
--   actions  { { text, kind = "primary"|nil, onClick, width, menu = function(root), tip, icon, enabled } ... } at the
--            bottom right (a strip: on its middle), the first at the far right; an icon action is a square button
--   tools    { { icon, title, text, onClick, menu, enabled } ... } 22 px icon buttons at the top right (the "···")
--   footH    reserve a foot of that height (tabs on the banner's foot): the actions sit above it, the art fades out
--   width    the width to lay out at while the banner has none (default: S.INNER_W)
-- banner:SetTitle / SetSub / SetKicker / SetArt(art, desaturate) / SetIcon / SetPill(kind, text) / SetActions(list) /
-- SetBack(text, fn) / SetTools(list); banner:Layout() re-lays it out (every setter and a resize do).
-- Fields: banner.art, .plain, .glow, .shade, .fade, .back (the back link), .kicker, .title, .sub, .pill, .icon (the
-- tile; .icon.tex), .actions (the shown action buttons, in list order), .tools, .foot (a frame along the bottom edge).
function UI:CreatePageBanner(parent, opts)
    opts = opts or {}
    local m = SizeOf(opts.size)
    local b = CreateFrame("Frame", nil, parent)
    b:SetHeight(m.h)
    b:SetWidth(opts.width or S.INNER_W)
    b.opts, b.m = opts, m
    b.plain = UI:Fill(b, P.PLAIN, "BACKGROUND", 0)
    b.plain:ClearAllPoints()
    b.plain:SetPoint("TOPLEFT", 1, -1)
    b.plain:SetPoint("BOTTOMRIGHT", -1, 1)
    b.glow = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.glow:SetPoint("TOPLEFT", 1, -1)
    b.glow:SetPoint("BOTTOMLEFT", 1, 1)
    b.glow:SetWidth(P.GLOW_W)
    UI:Gradient(b.glow, "HORIZONTAL", P.GLOW, P.GLOW_END)
    b.art = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    b.art:SetPoint("TOPLEFT", 1, -1)
    b.art:SetPoint("BOTTOMRIGHT", -1, 1)
    b.art:Hide()
    AddShade(b)
    -- (a reserved foot: the art fades into the window's slate under the tabs, the raid page's look)
    b.fade = b:CreateTexture(nil, "BORDER", nil, 3)
    b.fade:SetPoint("BOTTOMLEFT", 0, 0)
    b.fade:SetPoint("BOTTOMRIGHT", 0, 0)
    b.fade:SetHeight(P.FOOT_FADE)
    local sw = S.C.SURFACE_WINDOW
    UI:Gradient(b.fade, "VERTICAL", { sw[1], sw[2], sw[3], 1 }, { sw[1], sw[2], sw[3], 0 })
    b.fade:Hide()
    UI:AddEdges(b, "ARTWORK")
    UI:SetEdgeColor(b, S:Color("EDGE"))

    b.kicker = UI:Text(b, "small", opts.kickerColor or "GOLD")
    b.title = UI:Text(b, m.title, opts.titleColor or m.titleColor or P.WHITE)
    b.sub = UI:Text(b, "body", opts.subColor or P.ON_ART)
    b.pill = NewPill(b)
    b.pill:Hide()
    b.actions, b.tools = {}, {}
    b.btnPool, b.iconPool, b.toolPool = {}, {}, {}

    b.foot = CreateFrame("Frame", nil, b)
    b.foot:SetPoint("BOTTOMLEFT", 0, 0)
    b.foot:SetPoint("BOTTOMRIGHT", 0, 0)
    b.foot:SetHeight(opts.footH or P.FOOT_H)
    b.foot:SetFrameLevel(b:GetFrameLevel() + 3)

    for k, fn in pairs(Banner) do b[k] = fn end
    b.building = true
    b:SetArt(opts.art)
    b:SetIcon(opts.icon)
    b:SetKicker(opts.kicker)
    b:SetTitle(opts.title)
    b:SetSub(opts.sub)
    if opts.pill then b:SetPill(opts.pill[1] or opts.pill.kind, opts.pill[2] or opts.pill.text) end
    if opts.back then b:SetBack(opts.back[1] or opts.back.text, opts.back[2] or opts.back.onClick) end
    if opts.shadeRight then b:SetShadeRight(opts.shadeRight) end
    if opts.kickerTip then b:SetKickerTip(opts.kickerTip[1] or opts.kickerTip.title, opts.kickerTip[2] or opts.kickerTip.lines) end
    b:SetTools(opts.tools)
    b:SetActions(opts.actions)
    b.building = nil
    b:SetScript("OnSizeChanged", function(self) self:Layout() end)
    b:Layout()
    return b
end

function Banner:Relayout()
    if not self.building then self:Layout() end
end

function Banner:SetTitle(text)
    self.titleText = text
    self:Relayout()
end

-- How the title fits (also opts.titleSteps / opts.rightW): steps = the styles it steps down through before it is cut
-- ({ "hero", "page", "title" }; nil: its size only); rightW = px kept free at the right of the text (a number or
-- function(banner): the page's own blocks there).
function Banner:SetTitleFit(steps, rightW)
    self.opts.titleSteps, self.opts.rightW = steps, rightW
    self:Relayout()
end

function Banner:SetSub(text)
    self.sub:SetText(text or "")
    self.sub:SetShown(text ~= nil and text ~= "")
    self:Relayout()
end

function Banner:SetKicker(text)
    local caps = self.opts.kickerCaps ~= false
    self.kicker:SetText(text and (caps and Caps(text) or tostring(text)) or "")
    self.kicker:SetShown(text ~= nil and text ~= "")
    self:Relayout()
end

-- art: a raid key (either form, or an instance id) | { path, l, r, t, b } | nil (the plain card). desaturate: grey it
-- (kept until set again).
function Banner:SetArt(art, desaturate, art2)
    self.artKey, self.art2Key = art, art2
    if desaturate ~= nil then self.desaturate = desaturate and true or false end
    local has = art ~= nil and art ~= false
    self.art:SetShown(has)
    self.plain:SetShown(not has)
    self.glow:SetShown(not has)
    if has then
        local tint = self.opts.artTint or 1
        self.art:SetVertexColor(tint, tint, tint)
        self.art:SetDesaturated((self.desaturate or self.opts.desaturate) and true or false)
    end
    self:Relayout()
    if self.art2 then
        self.art2:SetVertexColor(self.art:GetVertexColor())
        self.art2:SetDesaturated((self.desaturate or self.opts.desaturate) and true or false)
    end
end

-- icon: see SetIconTexture (nil: none, the text starts at the left margin).
-- opts (optional): { glyph = a colour (an atlas glyph: smaller, tinted, on the tile's dark ground; glyphSize px),
-- display = a creature display id (a round portrait of it: a boss), desaturate }.
function Banner:SetIcon(icon, opts)
    if icon ~= nil and icon ~= false then
        if not self.icon then self.icon = NewIconTile(self, self.m.icon, self.opts.iconRing) end
        local tex = self.icon.tex
        if self.iconStyled then                 -- (back to a plain picture after a glyph / portrait)
            tex:ClearAllPoints()
            tex:SetAllPoints()
            tex:SetSize(self.m.icon, self.m.icon)
            tex:SetVertexColor(1, 1, 1, 1)
            if tex.SetDesaturated then tex:SetDesaturated(false) end
            self.iconStyled = nil
        end
        SetIconTexture(tex, icon, true)
        if opts then
            self.iconStyled = true
            if opts.display and SetPortraitTextureFromCreatureDisplayID then
                SetPortraitTextureFromCreatureDisplayID(tex, opts.display)
            end
            if opts.glyph then
                local size = opts.glyphSize or floor(self.m.icon * 0.6)
                tex:ClearAllPoints()
                tex:SetPoint("CENTER")
                tex:SetSize(size, size)
                tex:SetVertexColor(S:Color(opts.glyph == true and "GOLD" or opts.glyph))
            end
            if opts.desaturate and tex.SetDesaturated then tex:SetDesaturated(true) end
        end
        self.icon:Show()
    elseif self.icon then
        self.icon:Hide()
    end
    self:Relayout()
end

-- A shade along the right edge too, w px wide (the page's own content sits there on the art: the raid page's answer
-- side); nil / 0: none. banner.shadeR.
function Banner:SetShadeRight(w)
    w = tonumber(w) or 0
    if w <= 0 then
        if self.shadeR then self.shadeR:Hide() end
        return
    end
    if not self.shadeR then
        self.shadeR = self:CreateTexture(nil, "BORDER", nil, 2)
        self.shadeR:SetPoint("TOPRIGHT", -1, -1)
        self.shadeR:SetPoint("BOTTOMRIGHT", -1, 1)
        UI:Gradient(self.shadeR, "HORIZONTAL", { 0.055, 0.055, 0.067, 0 }, { 0.055, 0.055, 0.067, 0.8 })
    end
    self.shadeR:SetWidth(w)
    self.shadeR:Show()
end

-- A second icon (a pair: the Warglaives) as a smaller tile on the first one's lower right corner: icon (nil hides it),
-- itemID (its tooltip). banner.icon2.
function Banner:SetSecondIcon(icon, itemID)
    if icon == nil or icon == false or not self.icon then
        if self.icon2 then self.icon2:Hide() end
        return
    end
    if not self.icon2 then
        self.icon2 = UI:CreateIconTile(self, 22)
        UI:AttachTooltip(self.icon2, function(f) if f.itemID then UI:SetItemTooltip(f, f.itemID) end end)
    end
    local t = self.icon2
    t:Set(icon)
    t.itemID = itemID
    t:ClearAllPoints()
    t:SetPoint("BOTTOMRIGHT", self.icon, "BOTTOMRIGHT", 6, -6)
    t:SetFrameLevel(self.icon:GetFrameLevel() + 2)
    t:Show()
end

-- A frame of the caller's in the icon's place (several icons side by side: a set's pieces); the text starts after its
-- width. nil gives the place back to the icon tile.
function Banner:SetIconFrame(f)
    if f then
        if not self.iconTile then self.iconTile = self.icon or false end
        if self.iconTile then self.iconTile:Hide() end
        self.icon = f
        f:Show()
    elseif self.iconTile ~= nil then
        if self.icon then self.icon:Hide() end
        self.icon = self.iconTile or nil
        self.iconTile = nil
    end
    self:Relayout()
end

-- kind, text (nil / "" text: no pill). kind: any pill kind (every UI.PILL_LOOK look and the event kinds).
function Banner:SetPill(kind, text)
    if text == nil or text == "" then
        self.pill:Hide()
    else
        self.pill:SetPill(kind, text)
        self.pill:Show()
    end
    self:Relayout()
end

-- text, onClick (nil text: no back link).
function Banner:SetBack(text, onClick)
    if text == nil or text == false then
        if self.back then self.back:Hide() end
    else
        if not self.back then
            self.back = UI:CreateBackLink(self, text, onClick)
        else
            self.back:SetText(text)
            self.back:SetOnClick(onClick)
        end
        self.back:Show()
    end
    self:Relayout()
end

-- (the n-th frame of a pool, made on first use)
local function PoolGet(pool, n, make)
    local f = pool[n]
    if not f then
        f = make()
        pool[n] = f
    end
    return f
end

local function NewIconButton(parent, size)
    local f = UI:CreateIconButton(parent, size, UI.ICON_ATLAS, nil, ActionClick)
    function f:OpenMenu() ActionClick(self) end
    return f
end

local function NewActionButton(parent)
    local f = UI:CreateSleekButton(parent, "", P.ACT_MIN, S.BTN_H, ActionClick)
    function f:OpenMenu() ActionClick(self) end
    return f
end

-- list: { { text, kind, onClick, width, menu, tip, icon, enabled } ... }, the first at the far right.
function Banner:SetActions(list)
    for _, f in ipairs(self.btnPool) do f:Hide() end
    for _, f in ipairs(self.iconPool) do f:Hide() end
    wipe(self.actions)
    local nb, ni = 0, 0
    for _, a in ipairs(list or {}) do
        local f
        if a.icon then
            ni = ni + 1
            f = PoolGet(self.iconPool, ni, function() return NewIconButton(self, S.BTN_H) end)
            SetIconTexture(f.icon, a.icon)
            if a.chevron then UI:SetChevron(f.icon, a.chevron == "right") end
        else
            nb = nb + 1
            f = PoolGet(self.btnPool, nb, function() return NewActionButton(self) end)
            f:SetText(a.text or a[1] or "")
            f:SetKind(a.kind or "secondary")
            local fs = f:GetFontString()
            f:SetWidth(a.width or max(P.ACT_MIN, floor((fs and UI:TextWidth(fs) or 30) + P.ACT_PAD + 0.5)))
        end
        f.ppAction = a
        SetTip(f, a.tip)
        if a.enabled == false then f:Disable() else f:Enable() end
        f:Show()
        self.actions[#self.actions + 1] = f
    end
    self:Relayout()
end

-- A small grey text left of the tools ("3 / 19" beside a pager); nil / "": none. banner.toolsText.
function Banner:SetToolsText(text)
    if not self.toolsText then self.toolsText = UI:Text(self, "small", "SUB", { justify = "RIGHT" }) end
    self.toolsText:SetText(text == nil and "" or tostring(text))
    -- (wanted, kept apart from shown: set before the tools, it shows once they come)
    self.toolsTextOn = text ~= nil and text ~= ""
    self.toolsText:SetShown(self.toolsTextOn)
    self:Relayout()
end

-- list: { { icon, title, text, onClick, menu, enabled, chevron = "left" | "right" } ... }, the first at the far right.
function Banner:SetTools(list)
    for _, f in ipairs(self.toolPool) do f:Hide() end
    wipe(self.tools)
    for i, t in ipairs(list or {}) do
        local f = PoolGet(self.toolPool, i, function() return NewIconButton(self, P.TOOL) end)
        SetIconTexture(f.icon, t.icon or "more")
        if t.chevron then UI:SetChevron(f.icon, t.chevron == "right") end   -- (a pager's < and >)
        f.ppAction = t
        SetTip(f, (t.title or t.text) and { t.title, t.text } or nil)
        if t.enabled == false then f:Disable() else f:Enable() end
        f:Show()
        self.tools[i] = f
    end
    self:Relayout()
end

-- (frames in a row right to left: the first at `point` of parent (x, y), each next one left of the one before;
-- returns the row's width and its leftmost frame)
local function RowFromRight(list, parent, point, x, y, gap, after)
    local w, prev = 0, after
    for i, f in ipairs(list) do
        f:ClearAllPoints()
        if prev then
            f:SetPoint("RIGHT", prev, "LEFT", -gap, 0)
            w = w + gap
        else
            f:SetPoint(point, parent, point, x, y)
        end
        w = w + (f:GetWidth() or 0)
        prev = f
    end
    return w, prev
end

-- Places everything for the banner's current width and content.
function Banner:Layout()
    local m, opts = self.m, self.opts
    local W = self:GetWidth()
    if not W or W <= 1 then W = opts.width or S.INNER_W end
    local H = m.h
    local footH = opts.footH or 0
    local X, EX = P.X, P.EDGE_X

    -- the art, cropped to the banner (two side by side with an art2: UI:SetArtPair)
    local art, art2 = self.artKey, self.art2Key
    if art ~= nil and art ~= false then
        local function crop(a)
            if type(a) ~= "string" and type(a) ~= "number" then return a end
            return function(tex, w, h)
                local path, l, r, t, bt
                if ns.ItemDB and ns.ItemDB.RaidArt then
                    path, l, r, t, bt = ns.ItemDB:RaidArt(a, max(1, w), max(1, h), opts.artFw or 0.95, opts.artUnder)
                end
                tex:SetTexture(path)
                tex:SetTexCoord(l or 0, r or 1, t or 0, bt or 1)
            end
        end
        UI:SetArtPair(self, self.art, crop(art), art2 and crop(art2) or nil, max(1, W - 2), max(1, H - 2), 1)
    elseif self.art2 then
        self.art2:Hide()
        self.artSeam:Hide()
    end
    self.fade:SetShown(footH > 0)

    -- the right side: tools (top) and actions (bottom); a strip has them in one row on its middle
    local toolsW, actsW, rightW, firstTool
    if m.tall then
        toolsW, firstTool = RowFromRight(self.tools, self, "TOPRIGHT", -EX, -P.TOOL_Y, P.TOOL_GAP)
        actsW = RowFromRight(self.actions, self, "BOTTOMRIGHT", -EX, P.ACT_Y + footH, P.ACT_GAP)
    else
        local last
        actsW, last = RowFromRight(self.actions, self, "RIGHT", -EX, footH / 2, P.ACT_GAP)
        toolsW, firstTool = RowFromRight(self.tools, self, "RIGHT", -EX, footH / 2, P.TOOL_GAP, last)
    end
    -- a text beside the tools (Banner:SetToolsText: "3 / 19" left of a pager's chevrons)
    local tt = self.toolsText
    if tt and self.toolsTextOn and firstTool and #self.tools > 0 then
        tt:ClearAllPoints()
        tt:SetPoint("RIGHT", firstTool, "LEFT", -8, 0)
        tt:Show()
        toolsW = toolsW + 8 + UI:TextWidth(tt)
    elseif tt then
        tt:Hide()
    end
    if m.tall then
        rightW = toolsW > 0 and (toolsW + EX + 8) or 16
    else
        rightW = actsW + toolsW + EX + 12
    end

    -- the left side: back link, icon, then the text column
    local back = self.back and self.back:IsShown() and self.back or nil
    local icon = self.icon and self.icon:IsShown() and self.icon or nil
    local textX = X
    local top = m.tall and (back and P.TOP_BACK or P.TOP) or 0
    if back then
        back:ClearAllPoints()
        if m.tall then
            back:SetPoint("TOPLEFT", self, "TOPLEFT", X, -P.BACK_Y)
        else
            back:SetPoint("LEFT", self, "LEFT", X, footH / 2)
            textX = X + back:GetWidth() + 12
        end
    end
    if icon then
        icon:ClearAllPoints()
        if m.tall then
            icon:SetPoint("TOPLEFT", self, "TOPLEFT", textX, -top)
        else
            icon:SetPoint("LEFT", self, "LEFT", textX, footH / 2)
        end
        textX = textX + icon:GetWidth() + 12
    end

    -- the title (cut to the room the tools, the caller's own blocks (opts.rightW) and its pill leave; down the
    -- opts.titleSteps sizes first), the kicker and sub line
    local keep = opts.rightW
    if type(keep) == "function" then keep = keep(self) end
    local pillW = self.pill:IsShown() and (self.pill:GetWidth() + 10) or 0
    local room = max(20, W - textX - max(rightW, tonumber(keep) or 0))
    local titleRoom = max(20, room - pillW)
    local text = self.titleText
    self.title:SetShown(text ~= nil and text ~= "")
    local steps = opts.titleSteps
    if steps and text and text ~= "" then
        local r, g, b = self.title:GetTextColor()
        for _, st in ipairs(steps) do
            UI:SetTextStyle(self.title, st, { r, g, b })
            self.title:SetText(text)
            if UI:TextWidth(self.title) <= titleRoom then break end
        end
    end
    local titleH = S:Size(m.title)
    local wrapTo = tonumber(opts.titleLines) or 1
    if wrapTo > 1 and text and text ~= "" then
        -- (opts.titleLines: the title wraps onto that many lines at most, cut with "..." on the last; a word wrap
        -- leaves some room at each line's end, hence the margin)
        UI:FitText(self.title, text, wrapTo * titleRoom - (wrapTo - 1) * floor(titleRoom * 0.2))
        local n = min(wrapTo, max(1, math.ceil(UI:TextWidth(self.title) / titleRoom)))
        self.title:SetWordWrap(true)
        if self.title.SetMaxLines then self.title:SetMaxLines(wrapTo) end
        self.title:SetJustifyV("TOP")
        self.title:SetWidth(titleRoom)
        local real = self.title:GetStringHeight() or 0
        local per = S:Size(m.title) + 2
        if real > n * per - 1 then n = min(wrapTo, max(n, math.ceil((real - 1) / per))) end
        titleH = n * per
        self.title:SetHeight(titleH)
    else
        UI:FitText(self.title, text or "", titleRoom)
        self.title:SetWidth(floor(min(UI:TextWidth(self.title), titleRoom) + 1))
    end
    self.kicker:SetWidth(room)
    self.sub:SetWidth(max(20, W - textX - (m.tall and 16 or rightW)))

    -- the stack: the shown lines, each { text, height, gap before it }
    local lines = {}
    if Shown(self.kicker) then lines[#lines + 1] = { self.kicker, S:Size("small"), 0 } end
    if self.title:IsShown() then lines[#lines + 1] = { self.title, titleH, #lines > 0 and m.gapK or 0 } end
    if Shown(self.sub) then lines[#lines + 1] = { self.sub, S:Size("body"), #lines > 0 and m.gapS or 0 } end
    local total = 0
    for _, ln in ipairs(lines) do total = total + ln[2] + ln[3] end
    local y
    if m.tall then
        y = -top
        -- (beside an icon a short stack sits on the icon's middle)
        if icon and total < icon:GetHeight() then y = y - floor((icon:GetHeight() - total) / 2) end
    else
        y = -(floor((H - footH) / 2) - floor(total / 2 + 0.5))
    end
    for _, ln in ipairs(lines) do
        y = y - ln[3]
        ln[1]:ClearAllPoints()
        ln[1]:SetPoint("TOPLEFT", self, "TOPLEFT", textX, y)
        y = y - ln[2]
    end
    self.pill:ClearAllPoints()
    self.pill:SetPoint("LEFT", self.title, "RIGHT", 10, 0)
    self.textX = textX
    -- the kicker's tooltip area (Banner:SetKickerTip): over the kicker's words
    local hit = self.kickerHit
    if hit then
        local on = self.kickerTip ~= nil and Shown(self.kicker)
        hit:SetShown(on)
        if on then
            hit:ClearAllPoints()
            hit:SetPoint("TOPLEFT", self.kicker, "TOPLEFT", -2, 2)
            hit:SetSize(floor(UI:TextWidth(self.kicker) + 4.5), S:Size("small") + 4)
        end
    end
end

-- A tooltip on the kicker (what a number in it means): title, lines (as UI:AttachTooltip); nil: none.
function Banner:SetKickerTip(title, lines)
    if title == nil then
        self.kickerTip = nil
    else
        if not self.kickerHit then
            self.kickerHit = CreateFrame("Frame", nil, self)
            self.kickerHit:SetFrameLevel(self:GetFrameLevel() + 4)
            self.kickerHit:EnableMouse(true)
        end
        self.kickerTip = { title, lines }
        UI:AttachTooltip(self.kickerHit, title, lines)
    end
    self:Relayout()
end

---------------------------------------------------------------------------
-- Section header
---------------------------------------------------------------------------

local Header = {}

-- Each style: height, where the line's middle is (px up from the bottom), the texts' styles and colours.
local HEAD = {
    title = { h = 24, mid = 13, titleStyle = "emph", titleColor = "GOLD", count = "small", countColor = "SUB",
              right = "body" },
    caps  = { h = 18, mid = 9, titleStyle = "caps", titleColor = "SUB", count = "small", countColor = "DIM",
              right = "small" },
}

---------------------------------------------------------------------------
-- Text link
---------------------------------------------------------------------------

local Link = {}

function Link:Paint()
    local c = self.hovered and self.hoverColor or self.color
    Paint(self.fs, c)
    if self.chev then Paint(self.chev, self.chevColor or c) end
end

-- The words (a prefix stays in front, in its own colours); the width follows them unless the frame was made fixed.
function Link:SetLabel(text)
    self.label = text
    self.fs:SetText((self.prefix or "") .. (text == nil and "" or tostring(text)))
    if not self.fixed then
        local w = UI:TextWidth(self.fs) + (self.chev and (self.gap + self.chevSize) or 0) + self.pad
        self:SetWidth(floor(w + 0.5))
    end
end
function Link:GetLabel() return self.label end

-- The rest and hover colours (token names or tables).
function Link:SetColors(color, hover)
    self.color, self.hoverColor = color or self.color, hover or self.hoverColor
    self:Paint()
end

local function LinkEnter(self) self.hovered = true; self:Paint() end
local function LinkLeave(self) self.hovered = false; self:Paint() end

-- A quiet text link (a section header's action, "Show me >", "+ Row", "Show rolls (4)", "Clear list"): words in a
-- colour that changes under the mouse, an optional chevron after them. opts: { style ("body"), color ("SUB"), hover
-- ("GOLD"), chevron ("right" | "down" | nil), chevSize (10), chevColor (a fixed chevron colour; default: as the
-- words), gap (3: words to chevron), prefix (text kept in front, e.g. a gold "+ "), align ("LEFT" | "RIGHT" |
-- "CENTER": where the words sit), fixed (true: the caller sizes the frame), pad (0: extra width), height (16) }.
-- link:SetLabel(text), :GetLabel(), :SetColors(color, hover); link.fs, link.chev. onClick(link, mouseButton); a
-- caller may SetScript("OnClick") itself instead.
function UI:CreateTextLink(parent, text, onClick, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(opts.height or 16)
    for k, fn in pairs(Link) do b[k] = fn end
    b.color, b.hoverColor = opts.color or "SUB", opts.hover or "GOLD"
    b.chevColor, b.prefix, b.fixed, b.pad = opts.chevColor, opts.prefix, opts.fixed, opts.pad or 0
    b.gap, b.chevSize = opts.gap or 3, opts.chevSize or 10
    b.fs = UI:Text(b, opts.style or "body", b.color)
    local align = opts.align or "LEFT"
    if opts.chevron then
        b.chev = b:CreateTexture(nil, "ARTWORK")
        b.chev:SetSize(b.chevSize, b.chevSize)
        if opts.chevron == "down" then
            local c = UI:IconCoords(UI.ICON.chevron)
            b.chev:SetTexture(UI.ICON_ATLAS)
            b.chev:SetTexCoord(c[1], c[2], c[3], c[4])
        else
            UI:SetChevron(b.chev, true)
        end
    end
    local tail = b.chev and (b.gap + b.chevSize) or 0
    if align == "RIGHT" then
        b.fs:SetPoint("RIGHT", b, "RIGHT", -tail, 0)
    elseif align == "CENTER" then
        b.fs:SetPoint("CENTER", b, "CENTER", -floor(tail / 2), 0)
    else
        b.fs:SetPoint("LEFT", b, "LEFT", 0, 0)
    end
    if b.chev then b.chev:SetPoint("LEFT", b.fs, "RIGHT", b.gap, opts.chevron == "down" and -1 or 0) end
    b:SetScript("OnEnter", LinkEnter)
    b:SetScript("OnLeave", LinkLeave)
    if onClick then b:SetScript("OnClick", onClick) end
    b:SetLabel(text)
    b:Paint()
    return b
end

-- (the section header's action: a grey link with a chevron, gold under the mouse; ActionClick runs its action)
local function NewHeaderLink(parent)
    local b = UI:CreateTextLink(parent, "", ActionClick, { chevron = "right" })
    return b
end

-- UI:CreateSectionHeader(parent, title, opts) -> header. opts:
--   style   "title" (gold 12 with a hairline under it: EventsTab H.Sect, the guest profile's sections; 24 high) |
--           "caps" (grey small capitals, a count, then a rule fading out to the right: the Blessings planner's; 18 high)
--   count   a number / text after the title; right: a grey text at the right end
--   rule    false: no line
--   action  { text, onClick, tip } (a grey link with a chevron, gold under the mouse) or { icon, onClick, tip } (an
--           18 px icon button) at the right end; menu = function(root) instead of onClick drops a menu
--   width   (default 200; the caller usually anchors both sides)
-- header:SetTitle / SetCount / SetRight / SetAction(action or nil); header:Layout(). Fields: header.title, .count,
-- .right, .rule, .action (the shown action's frame).
function UI:CreateSectionHeader(parent, title, opts)
    opts = opts or {}
    local style = HEAD[opts.style] and opts.style or "title"
    local st = HEAD[style]
    local h = CreateFrame("Frame", nil, parent)
    h:SetSize(opts.width or 200, st.h)
    h.opts, h.st, h.style = opts, st, style
    h.title = UI:Text(h, st.titleStyle, st.titleColor)
    h.count = UI:Text(h, st.count, st.countColor)
    h.right = UI:Text(h, st.right, "SUB", { justify = "RIGHT" })
    if opts.rule ~= false then
        if style == "caps" then
            h.rule = h:CreateTexture(nil, "ARTWORK")
            h.rule:SetHeight(1)
            UI:Gradient(h.rule, "HORIZONTAL", P.RULE_HI, P.RULE_LO)
        else
            h.rule = UI:Rule(h, { bottom = 0 })
        end
    end
    for k, fn in pairs(Header) do h[k] = fn end
    h.building = true
    h:SetTitle(title)
    h:SetCount(opts.count)
    h:SetRight(opts.right)
    h:SetAction(opts.action)
    h.building = nil
    h:Layout()
    return h
end

function Header:Relayout()
    if not self.building then self:Layout() end
end

function Header:SetTitle(text)
    self.titleText = text
    self.title:SetText(self.style == "caps" and Caps(text) or (text == nil and "" or tostring(text)))
    self:Relayout()
end

function Header:SetCount(n)
    local has = n ~= nil and n ~= ""
    self.count:SetText(has and tostring(n) or "")
    self.count:SetShown(has)
    self:Relayout()
end

function Header:SetRight(text)
    local has = text ~= nil and text ~= ""
    self.right:SetText(has and tostring(text) or "")
    self.right:SetShown(has)
    self:Relayout()
end

-- action: { text, onClick | menu, tip } | { icon, onClick | menu, tip } | nil.
function Header:SetAction(a)
    if self.link then self.link:Hide() end
    if self.iconBtn then self.iconBtn:Hide() end
    self.action = nil
    if a then
        local f
        if a.icon then
            if not self.iconBtn then
                self.iconBtn = NewIconButton(self, 18)
                self.iconBtn.icon:ClearAllPoints()
                self.iconBtn.icon:SetPoint("TOPLEFT", 3, -3)
                self.iconBtn.icon:SetPoint("BOTTOMRIGHT", -3, 3)
            end
            f = self.iconBtn
            SetIconTexture(f.icon, a.icon)
        else
            if not self.link then self.link = NewHeaderLink(self) end
            f = self.link
            f:SetLabel(a.text or a[1] or "")
        end
        f.ppAction = a
        SetTip(f, a.tip)
        f:Show()
        self.action = f
    end
    self:Relayout()
end

function Header:Layout()
    local st = self.st
    local caps = self.style == "caps"
    local y = st.mid - st.h / 2                       -- the line's middle, from the header's middle
    self.title:ClearAllPoints()
    self.title:SetPoint("LEFT", self, "LEFT", 2, y)
    self.count:ClearAllPoints()
    self.count:SetPoint("LEFT", self.title, "RIGHT", caps and 8 or 6, 0)
    -- right to left: the action, the right text; the caps rule fills what is left between them and the title
    local edge, edgePoint, edgeX, edgeY = self, "RIGHT", -2, y
    if self.action then
        self.action:ClearAllPoints()
        self.action:SetPoint("RIGHT", self, "RIGHT", -2, y)
        edge, edgePoint, edgeX, edgeY = self.action, "LEFT", -8, 0
    end
    if self.right:IsShown() then
        self.right:ClearAllPoints()
        self.right:SetPoint("RIGHT", edge, edgePoint, edgeX, edgeY)
        edge, edgePoint, edgeX, edgeY = self.right, "LEFT", -10, 0
    end
    if self.rule and caps then
        self.rule:ClearAllPoints()
        self.rule:SetPoint("LEFT", self.count:IsShown() and self.count or self.title, "RIGHT", 10, 0)
        self.rule:SetPoint("RIGHT", edge, edgePoint, edgeX, edgeY)
    end
end
