if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Comp/Controls.lua", ...) then return end -- DisasterZone UI/Comp/Controls.lua
-- controls: pill, chip, segments, side menu (refactor phase 2).
local addonName, ns = ...

-- The small controls every page shares, on ns.UI:
--   UI:CreatePill(parent, kind, text)                  THE pill (tags, states): every UI.PILL_LOOK + the event kinds
--   UI:CreateChip(parent, opts)                        a tag as a chip: a dot / class circle / icon and its name
--   UI:CreateSegments(parent, items, onChange, opts)   a row of choices, one picked (and the old route-steps bar)
--   UI:CreateRailNav(parent, items, onSelect, opts)    the side menu of a rail page (Settings, Notifications)

local UI = ns.UI
local S = ns.Style
local C = S.C
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local type, ipairs, pairs, tonumber, tostring = type, ipairs, pairs, tonumber, tostring

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local STAR = "Interface\\COMMON\\ReputationStar"

-- (the helpers in one table: the file stays far from Lua's local limits)
local H = {}

-- A one-line FontString from a template, at size (optional; a size of the type scale) in the template's face.
function H.Label(parent, template, size)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

-- A tooltip (title + one grey line) on a choice / menu item that has item.tip; the frame's .item is read each time.
function H.ItemTip(frame)
    UI:AttachTooltip(frame, function(f, tip)
        local it = f.item
        if not (it and it.tip) then return false end
        tip:AddLine(it.label or "", S:Color("GOLD"))
        tip:AddLine(it.tip, 1, 1, 1, true)
    end)
end

---------------------------------------------------------------------------
-- Pills
---------------------------------------------------------------------------

-- The looks: the text's colour, the tint mixed into the fill (12% over what the pill sits on) and the 1 px edge.
-- UI.TAG_LOOK is the old name of the same table. Read-only: some colours are ns.Style's own tables.
local PILL_LOOK = {
    bis  = { text = C.GOLD,                tint = C.GOLD,               edge = S:WithAlpha("GOLD", 0.5) },
    alt  = { text = { 0.56, 0.78, 1 },     tint = { 0.31, 0.63, 1 },    edge = { 0.43, 0.71, 1, 0.5 } },
    os   = { text = { 0.79, 0.65, 1 },     tint = { 0.63, 0.43, 1 },    edge = { 0.67, 0.51, 1, 0.5 } },
    ok   = { text = { 0.62, 0.94, 0.69 },  tint = { 0.24, 0.71, 0.35 }, edge = { 0.35, 0.86, 0.47, 0.5 } },
    warn = { text = { 1, 0.69, 0.40 },     tint = { 1, 0.55, 0.10 },    edge = { 1, 0.55, 0.10, 0.55 } },
    mute = { text = { 0.72, 0.72, 0.72 },  tint = { 1, 1, 1 },          edge = { 1, 1, 1, 0.2 } },
    -- the events' (Live, Ranked)
    live = { text = { 1, 0.77, 0.72 },     tint = { 0.9, 0.2, 0.15 },   edge = { 1, 0.38, 0.29, 0.8 } },
    rank = { text = { 1, 0.88, 0.54 },     tint = C.GOLD,               edge = S:WithAlpha("GOLD", 0.55) },
    -- a worse number (My Log's "-6.1%"): the BAD red, quieter than live
    bad  = { text = { 1, 0.62, 0.58 },     tint = C.BAD,                edge = S:WithAlpha("BAD", 0.55) },
}
UI.PILL_LOOK = PILL_LOOK
UI.TAG_LOOK = PILL_LOOK

-- The kinds that wear another look (and an icon): { look, icon, icon coords }. Every PILL_LOOK name is a kind too.
UI.PILL_KIND = {
    rank = { "rank", STAR, { 0, 0.5, 0, 0.5 } },
    review = { "warn" }, back = { "warn" }, changed = { "warn" },
    draft = { "mute" }, ended = { "mute" },
}
-- The kinds the event pill's p:SetKind knows; any other reads "mute" there, as it always did.
local EVENT_KINDS = { live = true, rank = true, review = true, back = true, changed = true, draft = true,
    ended = true, mute = true, ok = true, warn = true, alt = true }

-- look name, icon, icon coords of a pill kind ("mute" for an unknown one).
function UI:PillKind(kind)
    local d = kind and UI.PILL_KIND[kind]
    if d then return d[1], d[2], d[3] end
    if kind and PILL_LOOK[kind] then return kind end
    return "mute"
end

local Pill = {}

-- p:SetBase(r, g, b): the colour the pill sits on (the fill is mixed with it, so the edge never shows through it).
function Pill:SetBase(r, g, b) self.base = { r, g, b } end

-- p:Set(text, look, icon): look = a PILL_LOOK name ("mute" for any other); icon (optional) = a texture in front.
function Pill:Set(text, kind, icon)
    local look = PILL_LOOK[kind] or PILL_LOOK.mute
    local a, base, t = 0.12, self.base, look.tint
    self:SetPillColors({ base[1] + (t[1] - base[1]) * a, base[2] + (t[2] - base[2]) * a,
        base[3] + (t[3] - base[3]) * a, 1 }, look.edge)
    self.fs:SetText(text or "")
    self.fs:SetTextColor(look.text[1], look.text[2], look.text[3])
    local x = 7
    if icon then
        self.icon:SetTexture(icon)
        self.icon:Show()
        x = 6 + (self.h - 6) + 3
    else
        self.icon:Hide()
    end
    self.fs:ClearAllPoints()
    self.fs:SetPoint("LEFT", x, 0)
    self:SetWidth(floor(x + (self.fs:GetStringWidth() or 16) + 7 + 0.5))
end

-- p:SetPill(kind, text): any kind (a look, or an event kind: "review", "draft", "rank" with its star ...).
function Pill:SetPill(kind, text)
    local look, icon, coords = UI:PillKind(kind)
    self:Set(text, look, icon)
    if icon and coords then self.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4]) end
end

-- p:SetKind(text, kind): the event pill's call (live | rank | review | back | changed | draft | ended | mute | ok |
-- warn | alt; anything else reads "mute").
function Pill:SetKind(text, kind)
    self:SetPill(EVENT_KINDS[kind] and kind or "mute", text)
end

-- UI:CreatePill(parent, kind, text [, h]): a small rounded tag ("BiS", "Alt P2", "Live", "In review") that sizes
-- itself to its text: a tinted fill, a 1 px edge, the text in its kind's colour. kind / text are optional (set them
-- later with p:SetPill(kind, text), p:Set(text, look, icon) or p:SetKind(text, kind)). h: 16 by default (or opts
-- { h = n }). The call shape UI:CreatePill(parent, h) makes an empty one.
-- p.fs = its text, p.icon = the icon in front, p.h = its height.
function UI:CreatePill(parent, kind, text, h)
    if type(kind) == "number" then
        h, kind = kind, nil
    end
    if type(h) == "table" then h = h.h end
    h = tonumber(h) or 16
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(30, h)
    p.h = h
    UI:AddPillShape(p, h)
    p.base = { C.CARD[1], C.CARD[2], C.CARD[3] }
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(h - 6, h - 6)
    p.icon:SetPoint("LEFT", 6, 0)
    p.icon:Hide()
    p.fs = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.fs:SetWordWrap(false)
    for k, fn in pairs(Pill) do p[k] = fn end
    if kind then p:SetPill(kind, text) end
    return p
end

---------------------------------------------------------------------------
-- Chips
---------------------------------------------------------------------------

-- The chip looks: height, fill, edge, text colour, the inset before the dot and the room after the text.
UI.CHIP_LOOK = {
    track = { h = 18, fill = { 0.039, 0.039, 0.051, 0.7 }, edge = { 1, 1, 1, 0.25 }, text = { 0.94, 0.94, 0.94 },
              x = 6, pad = 8 },
    you   = { h = 22, fill = { 0.055, 0.055, 0.066, 1 }, edge = { 0.4, 0.72, 1, 0.75 }, text = { 0.84, 0.93, 1 },
              x = 7, pad = 10 },
}
UI.CHIP_LOOK.default = UI.CHIP_LOOK.track
-- the "you" chip's shape in other colours: "live" (my match is on: a red edge, warm text) and the action chips' kinds
-- (Home's toolbar): "plain", "warn", "info" (blue), "bad"
do
    local you = UI.CHIP_LOOK.you
    local function look(fill, edge, a, text)
        local r, g, b = S:Color(edge)
        return { h = you.h, fill = fill or you.fill, edge = { r, g, b, a }, text = text, x = you.x, pad = you.pad }
    end
    UI.CHIP_LOOK.live = look({ 0.075, 0.045, 0.045, 1 }, "LIVE", 0.8, { 1, 0.85, 0.8 })
    UI.CHIP_LOOK.plain = look(nil, "EDGE_STRONG", 0.7, C.TEXT)
    UI.CHIP_LOOK.warn = look(nil, "WARN", 0.7, { 1, 0.82, 0.65 })
    UI.CHIP_LOOK.info = look(nil, "YOU", 0.55, { 0.81, 0.91, 1 })
    UI.CHIP_LOOK.bad = look(nil, "BAD", 0.85, { 1, 0.82, 0.78 })
end
local CHIP_SELECTED_EDGE = S:WithAlpha("GOLD", 0.75)

local Chip = {}

function Chip:Paint()
    local look = self.look
    local edge = look.edge
    if self.selected then
        edge = CHIP_SELECTED_EDGE
    elseif self.hovered then
        edge = { edge[1], edge[2], edge[3], min(1, (edge[4] or 1) + 0.25) }
    end
    self:SetPillColors(look.fill, edge)
    local tc = self.selected and C.GOLD or look.text
    self.fs:SetTextColor(tc[1], tc[2], tc[3])
end

-- chip:Set(text, rgb, key): rgb = the dot's colour; or key = a player's class circle instead of the dot; neither = the
-- icon from opts.icon / chip:SetIcon, or the text alone.
function Chip:Set(text, rgb, key)
    local look = self.look
    local x = look.x
    self.dot:ClearAllPoints()
    self.dotEdge:ClearAllPoints()
    self.cls:ClearAllPoints()
    self.icon:ClearAllPoints()
    self.icon:Hide()
    if key then
        self.dot:Hide()
        self.dotEdge:Hide()
        local E = ns.EventUI
        if E and E.SetClass then E:SetClass(self.cls, key) end
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
    elseif self.iconPath then
        self.dot:Hide()
        self.dotEdge:Hide()
        self.cls:Hide()
        self.icon:SetTexture(self.iconPath)
        local co = self.iconCoords
        if co then self.icon:SetTexCoord(co[1], co[2], co[3], co[4]) else self.icon:SetTexCoord(0, 1, 0, 1) end
        local r, g, b, a = S:Color(self.iconColor or { 1, 1, 1, 1 })
        self.icon:SetVertexColor(r, g, b, a)
        self.icon:SetDesaturated(self.iconDesat and true or false)
        self.icon:SetPoint("LEFT", x, 0)
        self.icon:Show()
        x = x + 14 + 6
    else
        self.dot:Hide()
        self.dotEdge:Hide()
        self.cls:Hide()
        x = x + 3
    end
    self.fs:ClearAllPoints()
    self.fs:SetPoint("LEFT", x - 1, 0)
    self.fs:SetText(text or "")
    self:Paint()
    self:SetWidth(floor(x + UI:TextWidth(self.fs) + look.pad + 0.5))
end

-- chip:SetIcon(path [, coords, color, desaturate]): a texture in front of the text when no dot / class circle is given
-- (nil: none); coords { l, r, t, b } (an atlas glyph: UI.ICON_ATLAS and UI:IconCoords(i)) and color (a token name or
-- a table: a tint) are kept over every chip:Set. Takes effect on the next chip:Set.
function Chip:SetIcon(path, coords, color, desaturate)
    self.iconPath, self.iconCoords, self.iconColor, self.iconDesat = path, coords, color, desaturate
end

-- chip:SetLook(kind): another look of UI.CHIP_LOOK (the shape keeps its height), repainted now.
function Chip:SetLook(kind)
    self.look = UI.CHIP_LOOK[kind] or UI.CHIP_LOOK.default
    self:Paint()
end

function Chip:SetSelected(on)
    self.selected = on and true or false
    self:Paint()
end

function Chip:IsSelected() return self.selected end

-- UI:CreateChip(parent, opts): a tag as a chip, a rounded capsule with a dot in the tag's colour (or a class circle, or
-- an icon) and its name. opts { text, rgb, key (class circle), icon, kind = "track" (18 high, the default) | "you" (the
-- board's header: a blue edge, 22 high) | "live" | "plain" | "warn" | "info" | "bad" (the "you" shape), selected (a gold edge, gold text), onClick (a Button then, with a hover:
-- onClick(chip, mouseButton)) }. chip:Set(text, rgb, key), chip:SetSelected(on), chip:SetIcon(path); chip.fs.
-- The call shape UI:CreateChip(parent, kind) makes an empty one of that kind.
function UI:CreateChip(parent, opts)
    if type(opts) ~= "table" then opts = { kind = opts } end
    local look = UI.CHIP_LOOK[opts.kind or "default"] or UI.CHIP_LOOK.default
    local h = look.h
    local p = CreateFrame(opts.onClick and "Button" or "Frame", nil, parent)
    p:SetSize(40, h)
    UI:AddPillShape(p, h)
    p.kind = opts.kind
    p.look = look
    p.dot = p:CreateTexture(nil, "ARTWORK", nil, 2)
    p.dot:SetTexture(DISC)
    p.dot:SetSize(8, 8)
    p.dotEdge = p:CreateTexture(nil, "ARTWORK", nil, 1)
    p.dotEdge:SetTexture(DISC)
    p.dotEdge:SetSize(10, 10)
    p.dotEdge:SetVertexColor(0, 0, 0, 1)
    p.cls = p:CreateTexture(nil, "ARTWORK", nil, 2)
    p.cls:SetSize(14, 14)
    p.icon = p:CreateTexture(nil, "ARTWORK", nil, 2)
    p.icon:SetSize(14, 14)
    p.icon:Hide()
    p.fs = H.Label(p, "GameFontHighlightSmall", S.FONT.body)
    p.fs:SetShadowOffset(1, -1)
    p.fs:SetShadowColor(0, 0, 0, 1)
    for k, fn in pairs(Chip) do p[k] = fn end
    p.selected = opts.selected and true or false
    p.iconPath = opts.icon
    if opts.onClick then
        p:RegisterForClicks("LeftButtonUp")
        p:SetScript("OnEnter", function(self) self.hovered = true; self:Paint() end)
        p:SetScript("OnLeave", function(self) self.hovered = false; self:Paint() end)
        p:SetScript("OnClick", function(self, button) opts.onClick(self, button) end)
    end
    p:Paint()
    if opts.text or opts.rgb or opts.key or opts.icon then p:Set(opts.text, opts.rgb, opts.key) end
    return p
end

---------------------------------------------------------------------------
-- Segments: a row of choices, one picked
---------------------------------------------------------------------------

local SEG_TEXT = { 0.66, 0.66, 0.70 }       -- a choice not picked
local SEG_GLIDE = 0.18                       -- seconds: the thumb's glide to a new pick
-- the wells of the two looks: "frame" (joined cells in a framed well, the default) and "pill" (rounded)
local SEG_WELL = {
    frame = { fill = { 0.075, 0.075, 0.085, 0.95 }, edge = { 0.30, 0.30, 0.34, 1 } },
    pill  = { fill = { 0.06, 0.06, 0.07, 1 },        edge = C.HAIRLINE },
}

-- One item: { key, label } / { key = , label = } / { value = , text = } / a plain label (its key is its index).
-- Optional fields: tip (a tooltip), color (the label's colour, e.g. a quality's), disabled.
function H.SegItem(it, i)
    if type(it) ~= "table" then return { key = i, label = tostring(it) } end
    local key = it.key
    if key == nil then key = it.value end
    if key == nil then key = it[1] end
    if key == nil then key = i end
    local label = it.label or it.text or it[2]
    return { key = key, label = label ~= nil and tostring(label) or tostring(key), tip = it.tip, color = it.color,
             disabled = it.disabled, src = it }
end

local Seg = {}

-- The index of a key; a number that is no item's key is taken as an index.
function Seg:IndexOf(which)
    if which == nil then return nil end
    for i, it in ipairs(self.items) do
        if it.key == which then return i end
    end
    if type(which) == "number" and self.items[which] then return which end
    return nil
end

-- The thumb to x, w: eased from where it was while the control is on screen, else at once.
function Seg:MoveThumb(x, w, instant)
    local th = self.thumb
    local fromX, fromW = self.thumbX, self.thumbW
    self.thumbX, self.thumbW = x, w
    local function place(e)
        th:ClearAllPoints()
        th:SetPoint("LEFT", self, "LEFT", fromX + (x - fromX) * e, 0)
        th:SetWidth(max(1, fromW + (w - fromW) * e))
    end
    if instant or fromX == nil or (fromX == x and fromW == w) or not self:IsVisible() then
        self:SetScript("OnUpdate", nil)
        fromX, fromW = x, w
        place(1)
        return
    end
    local t = 0
    place(0)
    self:SetScript("OnUpdate", function(f, dt)
        t = t + (dt or 0)
        local pr = min(1, t / SEG_GLIDE)
        place(1 - (1 - pr) ^ 3)
        if pr >= 1 then f:SetScript("OnUpdate", nil) end
    end)
end

function Seg:Paint(instant)
    local sel = self.selected
    for i, b in ipairs(self.buttons) do
        local it = self.items[i]
        if it and b:IsShown() then
            local on, off = i == sel, it.disabled
            local r, g, bl
            if on then
                r, g, bl = S:Color(it.color or self.onText)
            elseif off then
                r, g, bl = S:Color("DIM")
            elseif it.color then
                local k = b.hovered and 1 or 0.8
                r, g, bl = S:Color(it.color)
                r, g, bl = r * k, g * k, bl * k
            else
                r, g, bl = S:Color(b.hovered and "TEXT" or SEG_TEXT)
            end
            b.label:SetTextColor(r, g, bl)
            b:EnableMouse((self.enabled and not off) and true or false)
            b.wash:SetShown((b.hovered and self.enabled and not on and not off) and true or false)
        end
    end
    local th = self.thumb
    th:SetShown(sel ~= nil)
    local r, g, bl = S:Color(self.accent)
    if self.look == "pill" then          -- (not th.SetPillColors: the harness answers any Set* method)
        th:SetPillColors({ 0.04 + r * 0.13, 0.04 + g * 0.13, 0.05 + bl * 0.13, 1 }, { r, g, bl, 0.4 })
    else
        UI:Gradient(th.fill, "VERTICAL", { r * 0.27, g * 0.25, bl * 0.25 + 0.03, 0.95 },
            { r * 0.42, g * 0.39, bl * 0.39 + 0.06, 0.95 })
        UI:SetEdgeColor(th, r, g, bl, 0.95)
        th.shine:SetColorTexture(min(1, r * 0.4 + 0.6), min(1, g * 0.4 + 0.6), min(1, bl * 0.4 + 0.6), 0.35)
    end
    if sel then
        local b = self.buttons[sel]
        self:MoveThumb(b.x, b:GetWidth(), instant)
    end
end

-- seg:SetItems(items): new choices; the pick stays on the same key while it is still there. Returns the width.
function Seg:SetItems(items)
    local o = self.opts
    local oldKey = self.selected and self.items[self.selected] and self.items[self.selected].key
    self.items = {}
    for i, it in ipairs(items or {}) do self.items[i] = H.SegItem(it, i) end
    local n = #self.items
    local h = self:GetHeight()
    local inset = self.look == "pill" and 2 or 0
    -- the widths: equal parts of opts.width, opts.itemW each, or each fitted to its label
    local total = 0
    local eq = (o.width and n > 0) and floor((o.width - 2 * inset) / n) or o.itemW
    for i = 1, n do
        local b = self.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, self)
            b.wash = b:CreateTexture(nil, "BACKGROUND", nil, 3)
            b.wash:SetPoint("TOPLEFT", 1, -1)
            b.wash:SetPoint("BOTTOMRIGHT", -1, 1)
            b.wash:SetColorTexture(S:Color("HOVER"))
            b.wash:Hide()
            b.label = H.Label(b, "GameFontHighlightSmall", S:Size(o.textSize or "body"))
            b.label:SetPoint("CENTER", 0, 0)
            b.index = i
            b:RegisterForClicks("LeftButtonUp")
            b:SetScript("OnClick", function(btn) self:Click(btn.index) end)
            b:SetScript("OnEnter", function(btn) btn.hovered = true; self:Paint(true) end)
            b:SetScript("OnLeave", function(btn) btn.hovered = false; self:Paint(true) end)
            H.ItemTip(b)
            self.buttons[i] = b
        end
        local it = self.items[i]
        b.item, b.key, b.value = it, it.key, it.key
        b.label:SetText(it.label)
        local w = eq
        if not w then w = max(o.minW or 0, ceil(UI:TextWidth(b.label) + 2 * (o.pad or 14))) end
        if o.width and i == n then w = o.width - 2 * inset - total end      -- (the last takes the rounding)
        b:SetSize(w, h - 2 * inset)
        b:ClearAllPoints()
        b.x = inset + total
        b:SetPoint("LEFT", self, "LEFT", b.x, 0)
        b:SetFrameLevel(self.thumb:GetFrameLevel() + 1)
        b:Show()
        total = total + w
    end
    for i = n + 1, #self.buttons do self.buttons[i]:Hide() end
    self:SetWidth(max(1, total + 2 * inset))
    -- the frame look's hairlines between the cells
    for i = 2, n do
        local t = self.dividers[i]
        if not t then
            t = self:CreateTexture(nil, "BORDER")
            t:SetColorTexture(0.30, 0.30, 0.34, 0.8)
            t:SetSize(1, max(1, h - 8))
            self.dividers[i] = t
        end
        t:ClearAllPoints()
        t:SetPoint("LEFT", self, "LEFT", self.buttons[i].x, 0)
        t:SetShown(self.look ~= "pill")
    end
    for i = n + 1, #self.dividers do
        if self.dividers[i] then self.dividers[i]:Hide() end
    end
    self.selected = self:IndexOf(oldKey)
    self:Paint(true)
    return self:GetWidth()
end

-- A click on choice i: picks it and calls onChange(key, i, item); a handler that returns false keeps the old pick.
function Seg:Click(i)
    local it = self.items[i]
    if not it or it.disabled or not self.enabled then return end
    local old = self.selected
    self.selected = i
    self:Paint()
    if self.onChange and self.onChange(it.key, i, it.src) == false and self.selected == i then
        self.selected = old
        self:Paint()
    end
end

-- seg:Select(key or index [, fire]): picks it (nil: none); fire = true also calls onChange (as a click would).
function Seg:Select(which, fire)
    local i = self:IndexOf(which)
    if fire and i then return self:Click(i) end
    self.selected = i
    self:Paint()
end

-- key, index of the pick (nil: none).
function Seg:GetSelected()
    local i = self.selected
    if not i then return nil end
    return self.items[i].key, i
end

-- seg:SetEnabled(false): read-only (the same look and pick, no clicks).
function Seg:SetEnabled(on)
    self.enabled = on and true or false
    self:Paint(true)
end

function Seg:SetItemEnabled(which, on)
    local i = self:IndexOf(which)
    if not i then return end
    self.items[i].disabled = not on
    self:Paint(true)
end

-- seg:SetItemColor(key, color): a label in its own colour (a gem quality's); nil = the usual grey / white.
function Seg:SetItemColor(which, color)
    local i = self:IndexOf(which)
    if not i then return end
    self.items[i].color = color
    self:Paint(true)
end

function Seg:SetLabel(which, text)
    local i = self:IndexOf(which)
    if not i then return end
    local list = {}
    for k, it in ipairs(self.items) do
        list[k] = { key = it.key, label = (k == i) and tostring(text or "") or it.label, tip = it.tip,
                    color = it.color, disabled = it.disabled }
    end
    self:SetItems(list)
end

-- (the names the hand-built copies used: My Log's seg:SetSelected(key), the event builder's seg:Set(value))
Seg.SetSelected = Seg.Select
function Seg:Set(value) self:Select(value) end

-- The route-steps bar (UI:CreateSegments(parent, w, h, look)): one segment a step, the done ones filled, the
-- next one outlined. s:Set(n, done [, finished]); look "board" | "track" (brighter empties and a dark edge).
local STEP_NEXT = { 0.337, 0.839, 0.941 }    -- (EUI.TEAL)
local STEP_DONE = { 0.247, 0.714, 0.812 }    -- (EUI.TEAL_DONE)
local Steps = {}

function Steps:Set(n, done, finished)
    n = max(0, min(40, tonumber(n) or 0))
    done = max(0, min(n, tonumber(done) or 0))
    local gap = n > 16 and 1 or 2
    local W = self:GetWidth()
    local sw = n > 0 and (W - gap * (n - 1)) / n or 0
    local E = ns.EventUI
    local T, D = (E and E.TEAL) or STEP_NEXT, (E and E.TEAL_DONE) or STEP_DONE
    local track = self.look == "track"
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
        if state == "d" then
            local c = finished and T or D
            g.bg:SetColorTexture(c[1], c[2], c[3], 1)
        elseif state == "n" then
            g.bg:SetColorTexture(T[1], T[2], T[3], track and 0.3 or 0.25)
        else
            local empty = track and 0.18 or 0.1
            g.bg:SetColorTexture(1, 1, 1, empty)
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
        if track then
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

function H.CreateSteps(parent, w, h, look)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(w, h)
    s.look = look or "board"
    s.segs = {}
    for k, fn in pairs(Steps) do s[k] = fn end
    return s
end

-- UI:CreateSegments(parent, items, onChange, opts) -> seg: a row of choices in one control, the picked one under a
-- thumb in the accent colour that glides to a new pick, the others grey with a soft wash under the mouse.
--   items: { { key, label } ... } (or { key =, label =, tip =, color =, disabled = }, or plain labels: key = index)
--   onChange(key, index, item) on a click (the click picks it first); returning false puts the old pick back.
--   opts { look = "frame" (joined cells, the default) | "pill" (rounded), h (22), width (the whole control, in equal
--          parts) | itemW (each) | else each fitted to its label (pad 14 a side, minW), accent (a token name or colour:
--          "GOLD" by default, "OK" for a green answer bar), onText (the picked label's colour: white), textSize (a size
--          of the type scale, "body"), selected (key), readOnly (no clicks: the read-only look of a page) }
--   seg:Select(key|index [, fire]), seg:GetSelected() -> key, index, seg:SetItems(items), seg:SetEnabled(on),
--   seg:SetItemEnabled(key, on), seg:SetItemColor(key, color), seg:SetLabel(key, text); seg.buttons[i] (.label).
-- The call shape UI:CreateSegments(parent, w, h, look) is the route-steps bar.
function UI:CreateSegments(parent, items, onChange, opts)
    if type(items) == "number" then return H.CreateSteps(parent, items, onChange, opts) end
    opts = type(opts) == "table" and opts or {}
    local look = opts.look == "pill" and "pill" or "frame"
    local h = opts.h or 22
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(10, h)
    s.opts, s.look, s.onChange = opts, look, onChange
    s.accent = opts.accent or "GOLD"
    s.onText = opts.onText or { 1, 1, 1 }
    s.enabled = not opts.readOnly
    s.buttons, s.items, s.dividers = {}, {}, {}
    local well = SEG_WELL[look]
    local th = CreateFrame("Frame", nil, s)
    if look == "pill" then
        UI:AddPillShape(s, h)
        s:SetPillColors(well.fill, well.edge)
        th:SetSize(10, h - 4)
        UI:AddPillShape(th, h - 4)
    else
        s.bg = UI:Fill(s, well.fill)
        UI:AddEdges(s, "BORDER")
        UI:SetEdgeColor(s, well.edge[1], well.edge[2], well.edge[3], well.edge[4])
        th:SetSize(10, h)
        th.fill = th:CreateTexture(nil, "ARTWORK")
        th.fill:SetAllPoints()
        UI:AddEdges(th, "OVERLAY")
        th.shine = th:CreateTexture(nil, "OVERLAY")
        th.shine:SetHeight(1)
        th.shine:SetPoint("TOPLEFT", 1, -1)
        th.shine:SetPoint("TOPRIGHT", -1, -1)
    end
    th:Hide()
    s.thumb = th
    for k, fn in pairs(Seg) do s[k] = fn end
    s:SetItems(items)
    if opts.selected ~= nil then s:Select(opts.selected) end
    return s
end

---------------------------------------------------------------------------
-- Rail nav: the side menu of a rail page
---------------------------------------------------------------------------

local RAIL_TEXT = { 0.78, 0.78, 0.78 }      -- an item that is not open
local RAIL_COUNT_HOT = { 1, 0.86, 0.62 }    -- a count that wants you (Needs you)
local RAIL_OPEN = S:WithAlpha("GOLD", 0.08)     -- the open item's fill

-- An item's icon on tex: a UI.ICON name or atlas index, a texture path / file id (>= 1000), { path, l, r, t, b }, or
-- function(tex, item, open) that draws it. Tinted item.iconColor, else gold while open (item.gold) or grey.
function H.RailIcon(tex, item, open)
    local icon = item.icon
    if type(icon) == "function" then
        icon(tex, item, open)
        return
    end
    if type(icon) == "string" and UI.ICON and UI.ICON[icon] then icon = UI.ICON[icon] end
    if type(icon) == "number" and icon < 1000 then
        tex:SetTexture(UI.ICON_ATLAS)
        local c = UI:IconCoords(icon)
        tex:SetTexCoord(c[1], c[2], c[3], c[4])
    elseif type(icon) == "table" then
        tex:SetTexture(icon[1])
        tex:SetTexCoord(icon[2] or 0, icon[3] or 1, icon[4] or 0, icon[5] or 1)
    else
        tex:SetTexture(icon)
        tex:SetTexCoord(0, 1, 0, 1)
    end
    local c = item.iconColor
    if c == nil then c = (open and item.gold) and "GOLD" or "SUB" end
    tex:SetVertexColor(S:Color(c))
end

local Rail = {}

function Rail:PaintItem(b)
    local it = b.item
    local on = b.key ~= nil and b.key == self.selected
    if on then
        b.fill:SetColorTexture(RAIL_OPEN[1], RAIL_OPEN[2], RAIL_OPEN[3], RAIL_OPEN[4])
    elseif b.hovered then
        b.fill:SetColorTexture(S:Color("HOVER"))
    else
        b.fill:SetColorTexture(0, 0, 0, 0)
    end
    b.bar:SetShown(on)
    local tc
    if on then
        tc = self.opts.selectedColor or "GOLD"
    elseif b.hovered then
        tc = { 1, 1, 1 }
    else
        tc = it.dim and "SUB" or RAIL_TEXT
    end
    b.text:SetTextColor(S:Color(tc))
    if it.icon ~= nil then
        H.RailIcon(b.icon, it, on)
        b.icon:Show()
    else
        b.icon:Hide()
    end
    local n = tonumber(it.count) or 0
    b.count:SetText(n > 0 and tostring(n) or "")
    local nc = (it.hot or (it.gold and n > 0)) and RAIL_COUNT_HOT or C.DIM
    b.count:SetTextColor(nc[1], nc[2], nc[3])
end

function Rail:Paint()
    for _, b in ipairs(self.buttons) do
        if b:IsShown() then self:PaintItem(b) end
    end
end

-- A new menu row (reused across SetItems).
function H.RailButton(rail)
    local b = CreateFrame("Button", nil, rail)
    b.fill = b:CreateTexture(nil, "BACKGROUND")
    b.fill:SetAllPoints()
    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetPoint("TOPLEFT")
    b.bar:SetPoint("BOTTOMLEFT")
    b.bar:SetWidth(2)
    b.bar:SetColorTexture(S:Color("SELECT_BAR"))
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(13, 13)
    b.icon:SetPoint("LEFT", 10, 0)
    b.text = H.Label(b, "GameFontHighlight")
    b.text:SetJustifyH("LEFT")
    b.count = H.Label(b, "GameFontHighlightSmall")
    b.count:SetJustifyH("RIGHT")
    b.count:SetPoint("RIGHT", -10, 0)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnEnter", function(btn) btn.hovered = true; rail:PaintItem(btn) end)
    b:SetScript("OnLeave", function(btn) btn.hovered = false; rail:PaintItem(btn) end)
    b:SetScript("OnClick", function(btn) rail:Click(btn.key) end)
    H.ItemTip(b)
    return b
end

-- rail:SetItems(items): (re)builds the menu. items: { key, label, icon, count, gold (its icon gold while open, its
-- count gold while it has some), hot (a gold count), dim (grey label), tip } or { sep = true } (a hairline between
-- groups) or { header = "Text" } (a small caps title). Returns the height the rows take.
function Rail:SetItems(items)
    local rowH, y, bi, si = self.opts.rowH or S.ROW.list, self.opts.top or 0, 0, 0
    local anyIcon = false
    for _, it in ipairs(items or {}) do
        if type(it) == "table" and it.icon ~= nil then anyIcon = true end
    end
    self.items, self.byKey = items or {}, {}
    for _, it in ipairs(self.items) do
        if it.sep or it.header then
            si = si + 1
            local sp = self.seps[si]
            if not sp then
                sp = { line = UI:Rule(self, { layer = "BORDER" }), text = UI:Text(self, "caps", "DIM") }
                self.seps[si] = sp
            end
            sp.line:ClearAllPoints()
            sp.text:ClearAllPoints()
            if it.header then
                sp.line:Hide()
                sp.text:SetText(tostring(it.header):upper())
                sp.text:SetPoint("TOPLEFT", self, "TOPLEFT", 12, -y - 8)
                sp.text:Show()
                y = y + 22
            else
                sp.text:Hide()
                sp.line:SetPoint("TOPLEFT", self, "TOPLEFT", 10, -y - 6)
                sp.line:SetPoint("TOPRIGHT", self, "TOPRIGHT", -10, -y - 6)
                sp.line:Show()
                y = y + 13
            end
        else
            bi = bi + 1
            local b = self.buttons[bi]
            if not b then
                b = H.RailButton(self)
                self.buttons[bi] = b
            end
            b.item, b.key = it, it.key
            b:SetHeight(rowH)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -y)
            b:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -y)
            b.text:ClearAllPoints()
            if anyIcon then
                b.text:SetPoint("LEFT", b.icon, "RIGHT", 8, 0)
            else
                b.text:SetPoint("LEFT", b, "LEFT", 12, 0)
            end
            b.text:SetPoint("RIGHT", b, "RIGHT", -30, 0)
            b.text:SetText(it.label or "")
            if it.key ~= nil then self.byKey[it.key] = b end
            b:Show()
            self:PaintItem(b)
            y = y + rowH
        end
    end
    for i = bi + 1, #self.buttons do self.buttons[i]:Hide() end
    for i = si + 1, #self.seps do
        self.seps[i].line:Hide()
        self.seps[i].text:Hide()
    end
    self.contentH = y
    return y
end

-- A click on item key: opens it and calls onSelect(key, item); a handler that returns false keeps the old one open.
function Rail:Click(key)
    local b = key ~= nil and self.byKey[key]
    if not b then return end
    local old = self.selected
    self.selected = key
    self:Paint()
    if self.onSelect and self.onSelect(key, b.item) == false and self.selected == key then
        self.selected = old
        self:Paint()
    end
end

-- rail:Select(key [, fire]): shows key as the open one (nil: none); fire = true also calls onSelect.
function Rail:Select(key, fire)
    if fire then return self:Click(key) end
    self.selected = key
    self:Paint()
end

function Rail:GetSelected() return self.selected end

-- rail:SetCount(key, n [, hot]): the number at the item's right (0 / nil: none); hot = in gold.
function Rail:SetCount(key, n, hot)
    local b = key ~= nil and self.byKey[key]
    if not b then return end
    b.item.count = n
    if hot ~= nil then b.item.hot = hot end
    self:PaintItem(b)
end

function Rail:SetLabel(key, text)
    local b = key ~= nil and self.byKey[key]
    if not b then return end
    b.item.label = text
    b.text:SetText(text or "")
end

function Rail:GetContentHeight() return self.contentH or 0 end

-- UI:CreateRailNav(parent, items, onSelect, opts) -> rail: the side menu of a rail page (Settings, Notifications):
-- rows rowH high (26) in a light grey; the open one with a soft gold fill, a 2 px gold bar on its left and gold text;
-- a soft wash under the mouse. Items may have an icon (13 px, before the label) and a count (at the right). The caller
-- anchors and sizes the rail (the rows take its width). opts { width (150 until anchored), rowH, top (the first row's
-- y), selected (key), selectedColor (the open item's text: "GOLD") }.
-- rail:Select(key [, fire]), rail:GetSelected(), rail:SetCount(key, n [, hot]), rail:SetLabel(key, text),
-- rail:SetItems(items), rail:GetContentHeight(); rail.byKey[key] = its row (.text, .icon, .count, .bar, .fill).
function UI:CreateRailNav(parent, items, onSelect, opts)
    opts = type(opts) == "table" and opts or {}
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(opts.width or 150, 10)
    r.opts, r.onSelect = opts, onSelect
    r.buttons, r.seps, r.byKey = {}, {}, {}
    r.selected = opts.selected
    for k, fn in pairs(Rail) do r[k] = fn end
    r:SetItems(items)
    return r
end
