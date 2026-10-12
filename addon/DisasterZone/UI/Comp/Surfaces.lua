if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Comp/Surfaces.lua", ...) then return end -- DisasterZone UI/Comp/Surfaces.lua
-- surfaces: card, row looks, art row, empty state, notice (refactor phase 2).
local addonName, ns = ...

-- The surfaces every page is built on (REFACTOR_API.md "Surfaces.lua"), all on ns.UI and the values of ns.Style:
--   UI:CreateCard(parent, opts)        a card / an inset well / the quiet fading lift, with an optional title; card.body
--   UI:DecorateRow(row, opts)          the one hover, the one selected look (gold wash + 2 px bar), stripe, hairline
--   UI:CreateArtRow(parent, opts)      the 50 px row with a 64x38 picture and a 20 px icon tile (events, polls, ...)
--   UI:CreateEmptyState(parent, opts)  an illustrated "nothing here" (My Log's): disc + icon, title, text, one action
--   UI:CreateNotice(parent, kind, txt) a slim strip saying why something can't be done here (read-only / locked /
--                                      loading / info); it only SHOWS what the caller decided
-- (scrollList:SetEmptyState is in UI/Widgets.lua, next to SetEmptyText; it builds its state with UI:CreateEmptyState.)

local UI = ns.UI
local S = ns.Style
local floor, max, type = math.floor, math.max, type

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local TRIM = 0.07                       -- an icon's dark border, cut off (the icon tiles' look)

---------------------------------------------------------------------------
-- Card
---------------------------------------------------------------------------

-- The quiet tone's lift (KitView's cards, the paper doll's quiet tiles): a grey-blue that fades from one side.
local QUIET_RGB = { 0.55, 0.55, 0.62 }
local QUIET_A, QUIET_A_HOVER, QUIET_NEAR = 0.11, 0.16, 0.25

local TONES = {
    card  = { fill = "CARD", edge = "EDGE" },
    inset = { fill = "INSET", edge = "EDGE_QUIET" },
    quiet = { quiet = true },
}

local Card = {}

-- The quiet fill: strongest at the `fade` side ("left", the default: strong on the left, fading to the right;
-- "right"; "none": even), a little stronger while hovered.
local function PaintQuiet(card)
    local a = card.hovered and QUIET_A_HOVER or QUIET_A
    local r, g, b = QUIET_RGB[1], QUIET_RGB[2], QUIET_RGB[3]
    local far, near = { r, g, b, a }, { r, g, b, a * QUIET_NEAR }
    if card.fade == "right" then
        UI:Gradient(card.bg, "HORIZONTAL", near, far)
    elseif card.fade == "none" then
        card.bg:SetColorTexture(r, g, b, a * 0.6)
    else
        UI:Gradient(card.bg, "HORIZONTAL", far, near)
    end
end

function Card:SetTone(tone)
    local t = TONES[tone] or TONES.card
    self.tone = TONES[tone] and tone or "card"
    if t.quiet then
        PaintQuiet(self)
        UI:SetEdgeColor(self, 1, 1, 1, 0)
    else
        self.bg:SetColorTexture(S:Color(t.fill))
        UI:SetEdgeColor(self, S:Color(t.edge))
    end
end

-- The quiet tone's hover (a little stronger); the other tones keep their look.
function Card:SetHovered(on)
    self.hovered = on and true or false
    if self.tone == "quiet" then PaintQuiet(self) end
end

-- Lays the body out under the title (or from the top padding without one).
function Card:Layout()
    local pad = self.pad
    self.body:ClearAllPoints()
    if self.title and self.title:IsShown() then
        self.body:SetPoint("TOPLEFT", self.title, "BOTTOMLEFT", 0, -6)
    else
        self.body:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -pad)
    end
    self.body:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -pad, pad)
end

-- The card's title (nil / "": none, the body moves up). style: a S.STYLE name ("title" by default, "caps").
function Card:SetTitle(text, style)
    if text == nil or text == "" then
        if self.title then self.title:Hide() end
        self:Layout()
        return
    end
    if style then self.titleStyle = style end
    if not self.title then
        self.title = UI:Text(self, self.titleStyle or "title")
        self.title:SetPoint("TOPLEFT", self, "TOPLEFT", self.pad, -self.pad)
        self.title:SetPoint("RIGHT", self, "RIGHT", -self.pad, 0)
    elseif style then
        UI:SetTextStyle(self.title, style)
    end
    local st = S.STYLE[self.titleStyle or "title"]
    self.title:SetText((st and st.caps) and tostring(text):upper() or tostring(text))
    self.title:Show()
    self:Layout()
end

-- A card: a frame with the tone's fill and 1 px edge (none for "quiet"), an optional title at the top and card.body
-- (the frame to put the content in, inset by pad and under the title).
-- opts: { tone = "card" (default) | "inset" | "quiet", title, titleStyle ("title"; "caps" for a small heading),
-- pad (S.IN), fade (quiet only: "left" (default) | "right" | "none"), width, height }.
-- card:SetTone(tone), card:SetTitle(text [, style]), card:SetHovered(on) (quiet: a little stronger); card.bg, .title.
function UI:CreateCard(parent, opts)
    opts = opts or {}
    local card = CreateFrame("Frame", nil, parent)
    if opts.width or opts.height then card:SetSize(opts.width or 100, opts.height or 60) end
    card.pad = opts.pad or S.IN
    card.fade = opts.fade
    card.titleStyle = opts.titleStyle
    card.bg = card:CreateTexture(nil, "BACKGROUND")
    card.bg:SetAllPoints()
    UI:AddEdges(card, "BORDER")
    card.body = CreateFrame("Frame", nil, card)
    for k, fn in pairs(Card) do card[k] = fn end
    card:SetTone(opts.tone)
    card:SetTitle(opts.title)
    return card
end

---------------------------------------------------------------------------
-- Row looks
---------------------------------------------------------------------------

local Row = {}

-- Picked or not: a faint gold wash and a 2 px gold bar on the left.
function Row:SetSelected(on)
    on = on and true or false
    self.dzSelected = on
    if self.dzSelFill then
        self.dzSelFill:SetShown(on)
        self.dzSelBar:SetShown(on)
    end
end

function Row:IsSelected()
    return self.dzSelected and true or false
end

-- The stripe of the i-th row of a list: every second row (2, 4, ...) is a touch lighter (true: on; nil / false: off).
function Row:SetStripe(i)
    if not self.dzStripe then return end
    self.dzStripe:SetShown((type(i) == "number" and i % 2 == 0) or i == true)
end

-- The hover look from code (a child button under the mouse, a row picked with the keyboard ...).
function Row:SetHover(on)
    if self.dzHoverHL then
        if on then self:LockHighlight() else self:UnlockHighlight() end
    elseif self.dzHover then
        self.dzHover:SetShown(on and true or false)
    end
end

local function HoverOn(self) if self.dzHover then self.dzHover:Show() end end
local function HoverOff(self) if self.dzHover then self.dzHover:Hide() end end

-- Gives a row the shared looks. opts: { hover (true; false: none), selectable (the selected look; row:SetSelected),
-- stripe (row:SetStripe(i)), rule (a hairline along the bottom) }. A Button's hover is its HIGHLIGHT layer (it
-- survives a later SetScript); a plain frame's is hooked to OnEnter / OnLeave (hook it after setting those). Calling
-- it again on the same row only adds what it did not have. Returns row.
-- The textures: row.dzHover, row.dzSelFill / row.dzSelBar, row.dzStripe, row.dzRule.
function UI:DecorateRow(row, opts)
    if not row then return row end
    opts = opts or {}
    for k, fn in pairs(Row) do row[k] = fn end
    if opts.stripe and not row.dzStripe then
        row.dzStripe = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.dzStripe:SetAllPoints()
        row.dzStripe:SetColorTexture(S:Color("STRIPE"))
        row.dzStripe:Hide()
    end
    if opts.selectable and not row.dzSelFill then
        row.dzSelFill = row:CreateTexture(nil, "BACKGROUND", nil, 2)
        row.dzSelFill:SetAllPoints()
        row.dzSelFill:SetColorTexture(S:Color("SELECT"))
        row.dzSelBar = row:CreateTexture(nil, "ARTWORK", nil, 7)
        row.dzSelBar:SetWidth(2)
        row.dzSelBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        row.dzSelBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        row.dzSelBar:SetColorTexture(S:Color("SELECT_BAR"))
        row:SetSelected(row.dzSelected)
    end
    if opts.hover ~= false and not row.dzHover then
        local kind = row.GetObjectType and row:GetObjectType()
        if kind == "Button" or kind == "CheckButton" then
            row.dzHover = row:CreateTexture(nil, "HIGHLIGHT")
            row.dzHoverHL = true
        else
            row.dzHover = row:CreateTexture(nil, "BACKGROUND", nil, 3)
            row.dzHover:Hide()
            if row.EnableMouse then row:EnableMouse(true) end
            row:HookScript("OnEnter", HoverOn)
            row:HookScript("OnLeave", HoverOff)
        end
        row.dzHover:SetAllPoints()
        row.dzHover:SetColorTexture(S:Color("HOVER"))
    end
    if opts.rule and not row.dzRule then
        row.dzRule = UI:Rule(row, { bottom = 0 })
    end
    return row
end

---------------------------------------------------------------------------
-- Art row
---------------------------------------------------------------------------

local ART_W, ART_H, ICON = 64, 38, 20
local ART_X, TEXT_GAP, RIGHT_X = 2, 14, 8

-- A picture onto tex, cropped for a w x h box. art: a raid (either key form: its loading screen under the logo
-- band), an event art key (EventBlocks.ART), a texture path or file id (whole), { path, l, r, t, b }, or a
-- function(tex, w, h) that paints it itself; nil clears it.
function UI:SetArtTexture(tex, art, w, h)
    if not tex then return end
    w, h = w or ART_W, h or ART_H
    if art == nil or art == false then
        tex:SetTexture(nil)
        return
    end
    if type(art) == "function" then
        art(tex, w, h)
        return
    end
    if type(art) == "table" then
        tex:SetTexture(art[1] or art.path)
        tex:SetTexCoord(art[2] or 0, art[3] or 1, art[4] or 0, art[5] or 1)
        return
    end
    if type(art) == "string" and not art:find("[\\/]") then
        local IDB = ns.ItemDB
        if IDB and IDB.GetRaidMeta and IDB:GetRaidMeta(art) then
            local path, l, r, t, b = IDB:RaidArt(art, w, h, 0.6, true)
            tex:SetTexture(path)
            tex:SetTexCoord(l or 0, r or 1, t or 0, b or 1)
            return
        end
        local EUI = ns.EventUI
        if EUI and EUI.ArtCoords then
            local path, l, r, t, b = EUI:ArtCoords(art, w, h, nil, nil, 0.6)
            tex:SetTexture(path)
            tex:SetTexCoord(l, r, t, b)
            return
        end
    end
    tex:SetTexture(art)
    tex:SetTexCoord(0, 1, 0, 1)
end

-- An icon tile: the icon with its border cut off and a 1 px black edge. tile:Set(icon) (a path / file id; nil hides).
local function IconTile(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.outer = f:CreateTexture(nil, "BACKGROUND")
    f.outer:SetPoint("TOPLEFT", -1, 1)
    f.outer:SetPoint("BOTTOMRIGHT", 1, -1)
    f.outer:SetColorTexture(0, 0, 0, 1)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(TRIM, 1 - TRIM, TRIM, 1 - TRIM)
    function f:Set(icon)
        if icon == nil or icon == false then
            self:Hide()
            return
        end
        self.tex:SetTexture(icon)
        self:Show()
    end
    return f
end

-- The icon tile on its own (UI:CreateIconTile(parent, size)): the art row's badge, for rows built by hand.
function UI:CreateIconTile(parent, size)
    return IconTile(parent, size or ICON)
end

local ArtRow = {}

-- Fits the title and the second line into the room the right side and the pill leave.
function ArtRow:FitTitle()
    local w = self:GetWidth() or 0
    if w <= 0 or not self.titleText then return end
    local right = 0
    if self.rightText:IsShown() then right = UI:TextWidth(self.rightText) + RIGHT_X + 8 end
    if self.rightW then right = max(right, self.rightW) end
    local pill = (self.pill and self.pill:IsShown()) and (self.pill:GetWidth() + 7) or 0
    local room = w - self.textX - right - 8
    if room - pill > 20 then
        UI:FitText(self.title, self.titleText, room - pill)
        UI:FitText(self.sub, self.subText or "", room)
    end
    if self.pill and self.pill:IsShown() then
        self.pill:ClearAllPoints()
        self.pill:SetPoint("LEFT", self.title, "LEFT", UI:TextWidth(self.title) + 7, 0)
    end
end

-- The row's content: { art (see UI:SetArtTexture), icon (the tile; nil: none), title, sub (a second line; nil: the
-- title alone, centred), right (a text on the right), pill = { kind, text } (after the title), selected }.
function ArtRow:SetData(d)
    d = d or {}
    UI:SetArtTexture(self.art.tex, d.art, ART_W, ART_H)
    self.icon:Set(d.icon)
    self.titleText = d.title == nil and "" or tostring(d.title)
    self.subText = d.sub ~= nil and tostring(d.sub) or nil
    self.title:SetText(self.titleText)
    self.sub:SetText(self.subText or "")
    self.title:ClearAllPoints()
    self.sub:ClearAllPoints()
    if self.subText and self.subText ~= "" then
        self.title:SetPoint("BOTTOMLEFT", self.art, "RIGHT", TEXT_GAP, 1)
        self.sub:SetPoint("TOPLEFT", self.art, "RIGHT", TEXT_GAP, -3)
        self.sub:Show()
    else
        self.title:SetPoint("LEFT", self.art, "RIGHT", TEXT_GAP, 0)
        self.sub:Hide()
    end
    if d.right ~= nil and d.right ~= "" then
        self.rightText:SetText(tostring(d.right))
        self.rightText:Show()
    else
        self.rightText:SetText("")
        self.rightText:Hide()
    end
    local pill = d.pill
    if type(pill) == "table" and (pill[2] or pill.text) then
        if not self.pill then self.pill = UI:CreatePill(self, 16) end
        self.pill:Set(pill[2] or pill.text, pill[1] or pill.kind)
        self.pill:ClearAllPoints()
        self.pill:SetPoint("LEFT", self.title, "RIGHT", 7, 0)
        self.pill:Show()
    elseif self.pill then
        self.pill:Hide()
    end
    if d.selected ~= nil then self:SetSelected(d.selected) end
    self:FitTitle()
end

-- Room the caller's own controls take on the right (px from the row's right edge), kept clear of the title.
function ArtRow:SetRightWidth(w)
    self.rightW = w
    self:FitTitle()
end

-- The 50 px row of the boards' lists (events, polls, the raid log, strategies, guests): a 64x38 picture with a 20 px
-- icon tile on its lower left corner, a title (with an optional pill) over a second line, a text on the right.
-- opts: { onClick(row, button), selectable, stripe, rule (true), hover (true), width }. row.right is an empty frame
-- along the right edge for the caller's buttons (row:SetRightWidth(px) keeps the title clear of them).
-- row:SetData{ art, icon, title, sub, right, pill = { kind, text }, selected }; row.art (.tex), row.icon (.tex),
-- row.title, row.sub, row.rightText, row.pill (made on first use); the looks of UI:DecorateRow.
function UI:CreateArtRow(parent, opts)
    opts = opts or {}
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(S.ROW.art)
    if opts.width then r:SetWidth(opts.width) end
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    UI:DecorateRow(r, { hover = opts.hover, selectable = opts.selectable, stripe = opts.stripe,
        rule = opts.rule ~= false })
    r.textX = ART_X + ART_W + TEXT_GAP

    r.art = CreateFrame("Frame", nil, r)
    r.art:SetSize(ART_W, ART_H)
    r.art:SetPoint("LEFT", r, "LEFT", ART_X, 0)
    r.art.outer = r.art:CreateTexture(nil, "BACKGROUND")
    r.art.outer:SetPoint("TOPLEFT", -1, 1)
    r.art.outer:SetPoint("BOTTOMRIGHT", 1, -1)
    r.art.outer:SetColorTexture(0, 0, 0, 1)
    r.art.tex = r.art:CreateTexture(nil, "ARTWORK")
    r.art.tex:SetAllPoints()
    UI:AddEdges(r.art, "OVERLAY")
    UI:SetEdgeColor(r.art, S:Color("HAIRLINE"))

    r.icon = IconTile(r, ICON)
    r.icon:SetPoint("BOTTOMLEFT", r.art, "BOTTOMLEFT", -5, -5)
    r.icon:SetFrameLevel(r.art:GetFrameLevel() + 3)
    r.icon:Hide()

    r.title = UI:Text(r, "emph")
    r.sub = UI:Text(r, "sub")
    r.rightText = UI:Text(r, "sub", nil, { justify = "RIGHT" })
    r.rightText:SetPoint("RIGHT", r, "RIGHT", -RIGHT_X, 0)
    r.rightText:Hide()
    r.right = CreateFrame("Frame", nil, r)
    r.right:SetPoint("TOPRIGHT", r, "TOPRIGHT", -RIGHT_X, 0)
    r.right:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -RIGHT_X, 0)
    r.right:SetWidth(1)

    for k, fn in pairs(ArtRow) do r[k] = fn end
    if opts.onClick then
        local onClick = opts.onClick
        r:SetScript("OnClick", function(self, button) onClick(self, button) end)
    end
    r:HookScript("OnSizeChanged", function(self) self:FitTitle() end)
    r:SetData(nil)
    return r
end

---------------------------------------------------------------------------
-- Empty state
---------------------------------------------------------------------------

local EMPTY_W, EMPTY_W_COMPACT = 430, 360
local Empty = {}

-- (Re)fills the state: { icon (a path / file id; or glyph = a UI.ICON index, drawn gold), title, text, action =
-- { text, onClick, width, kind ("primary") } }. Fields left out are cleared. The frame's height follows its content.
function Empty:SetContent(o)
    o = o or {}
    self.content = o
    local disc, iconSize = self.compact and 40 or 54, self.compact and 22 or 30
    self.port:SetSize(disc, disc)
    self.icon:SetSize(iconSize, iconSize)
    if o.glyph and UI.IconCoords then
        local c = UI:IconCoords(o.glyph)
        self.icon:SetTexture(UI.ICON_ATLAS)
        self.icon:SetTexCoord(c[1], c[2], c[3], c[4])
        self.icon:SetVertexColor(S:Color("GOLD"))
    else
        self.icon:SetTexture(o.icon or 134939)   -- (a scroll, My Log's)
        self.icon:SetTexCoord(0, 1, 0, 1)
        self.icon:SetVertexColor(1, 1, 1, 1)
    end
    local h, below, gap = disc, self.port, 12
    if o.title and o.title ~= "" then
        self.title:SetText(o.title)
        self.title:Show()
        h = h + gap + max(14, self.title:GetStringHeight() or 14)
        below, gap = self.title, 10
    else
        self.title:Hide()
    end
    if o.text and o.text ~= "" then
        self.text:ClearAllPoints()
        self.text:SetPoint("TOP", below, "BOTTOM", 0, -gap)
        self.text:SetText(o.text)
        self.text:Show()
        h = h + gap + max(12, self.text:GetStringHeight() or 12)
        below = self.text
    else
        self.text:Hide()
    end
    local a = o.action
    if a and a.text then
        if not self.btn then
            self.btn = UI:CreateSleekButton(self, a.text, a.width, S.BTN_H, function(b, ...)
                if self.onAction then self.onAction(b, ...) end
            end, a.kind or "primary")
        else
            self.btn:SetText(a.text)
            if self.btn.SetKind then self.btn:SetKind(a.kind or "primary") end
        end
        self.btn:SetWidth(a.width or max(120, floor(UI:TextWidth(a.text) + 32 + 0.5)))
        self.onAction = a.onClick
        self.btn:ClearAllPoints()
        self.btn:SetPoint("TOP", below, "BOTTOM", 0, -16)
        self.btn:Show()
        h = h + 16 + S.BTN_H
    elseif self.btn then
        self.btn:Hide()
        self.onAction = nil
    end
    self:SetHeight(floor(h + 0.5))
end

-- A new width for the state (its title and text wrap to it); the content is laid out again.
function Empty:SetBoxWidth(w)
    w = floor(max(120, tonumber(w) or EMPTY_W) + 0.5)
    self:SetWidth(w)
    self.title:SetWidth(w)
    self.text:SetWidth(w)
    self:SetContent(self.content)
end

-- An illustrated "nothing here" (My Log's): a faint gold disc with an icon, a gold title, a centred text and an
-- optional main action. opts: { icon / glyph, title, text, action = { text, onClick, width, kind }, width (430),
-- compact (a smaller disc and width: inside a list) }. The caller places it (it sizes its own height);
-- state:SetContent(opts) refills it, state:SetBoxWidth(w) re-wraps it. state.port, .icon, .title, .text, .btn (made
-- with the first action).
function UI:CreateEmptyState(parent, opts)
    opts = opts or {}
    local e = CreateFrame("Frame", nil, parent)
    e.compact = opts.compact and true or false
    local w = opts.width or (e.compact and EMPTY_W_COMPACT or EMPTY_W)
    e:SetSize(w, 120)
    e.port = e:CreateTexture(nil, "ARTWORK")
    e.port:SetTexture(DISC)
    e.port:SetVertexColor(S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 0.12)
    e.port:SetPoint("TOP", e, "TOP", 0, 0)
    e.icon = e:CreateTexture(nil, "OVERLAY")
    e.icon:SetPoint("CENTER", e.port, "CENTER")
    e.title = UI:Text(e, "title", nil, { justify = "CENTER", wrap = true, width = w })
    e.title:SetPoint("TOP", e.port, "BOTTOM", 0, -12)
    e.text = UI:Text(e, "body", "SUB", { justify = "CENTER", wrap = true, width = w })
    e.text:SetSpacing(3)
    for k, fn in pairs(Empty) do e[k] = fn end
    e:SetContent(opts)
    return e
end

---------------------------------------------------------------------------
-- Notice
---------------------------------------------------------------------------

-- kind -> the strip's colour token and icon (glyph: an atlas index of UI.ICON, tinted; tex: a texture).
local NOTICE = {
    readonly = { color = "YOU",  glyph = "eye" },
    locked   = { color = "WARN", tex = function() return UI.ICON_LOCK end },
    loading  = { color = "SUB",  tex = function() return "Interface\\Icons\\INV_Misc_PocketWatch_01" end, trim = true },
    info     = { color = "GOLD", glyph = "notes" },
}
UI.NOTICE_LOOK = NOTICE

local Notice = {}
local NOTICE_H, NOTICE_ICON, NOTICE_TX = 26, 12, 28

-- Fits the strip's height to its text (it wraps to the strip's width).
function Notice:Fit()
    local w = self:GetWidth() or 0
    if w > NOTICE_TX + 20 then self.text:SetWidth(w - NOTICE_TX - 10) end
    local th = self.text:GetStringHeight() or 12
    self:SetHeight(max(NOTICE_H, floor(th + 14 + 0.5)))
end

-- kind: "readonly" | "locked" | "loading" | "info" (anything else: info); text: what to say.
function Notice:SetNotice(kind, text)
    local look = NOTICE[kind] or NOTICE.info
    self.kind = NOTICE[kind] and kind or "info"
    local r, g, b = S:Color(look.color)
    self.bg:SetColorTexture(r, g, b, 0.08)
    self.bar:SetColorTexture(r, g, b, 0.8)
    local glyph = look.glyph and UI.ICON and UI.ICON[look.glyph]
    if glyph and UI.IconCoords then
        local c = UI:IconCoords(glyph)
        self.icon:SetTexture(UI.ICON_ATLAS)
        self.icon:SetTexCoord(c[1], c[2], c[3], c[4])
        self.icon:SetVertexColor(r, g, b, 1)
    else
        self.icon:SetTexture(look.tex and look.tex() or nil)
        if look.trim then
            self.icon:SetTexCoord(TRIM, 1 - TRIM, TRIM, 1 - TRIM)
        else
            self.icon:SetTexCoord(0, 1, 0, 1)
        end
        self.icon:SetVertexColor(1, 1, 1, 1)
    end
    self.text:SetText(text or "")
    self:Fit()
    self:Show()
end

-- A slim strip saying why something can't be done here, or that it is on its way: kind "readonly" | "locked" |
-- "loading" | "info", in the kind's colour (a faint wash, a 2 px bar on the left, an icon) with the text in the
-- body style. It only shows what the caller decided. The caller places it and sets its width (the height follows
-- the text). notice:SetNotice(kind, text); notice.kind, .bg, .bar, .icon, .text.
function UI:CreateNotice(parent, kind, text)
    local n = CreateFrame("Frame", nil, parent)
    n:SetSize(300, NOTICE_H)
    n.bg = n:CreateTexture(nil, "BACKGROUND")
    n.bg:SetAllPoints()
    n.bar = n:CreateTexture(nil, "BORDER")
    n.bar:SetWidth(2)
    n.bar:SetPoint("TOPLEFT", n, "TOPLEFT", 0, 0)
    n.bar:SetPoint("BOTTOMLEFT", n, "BOTTOMLEFT", 0, 0)
    n.icon = n:CreateTexture(nil, "ARTWORK")
    n.icon:SetSize(NOTICE_ICON, NOTICE_ICON)
    n.icon:SetPoint("LEFT", n, "LEFT", 10, 0)
    n.text = UI:Text(n, "body", "TEXT", { wrap = true })
    n.text:SetPoint("LEFT", n, "LEFT", NOTICE_TX, 0)
    for k, fn in pairs(Notice) do n[k] = fn end
    n:HookScript("OnSizeChanged", function(self, w)
        if self.fitW ~= w then
            self.fitW = w
            self:Fit()
        end
    end)
    n:SetNotice(kind, text)
    return n
end
