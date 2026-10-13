if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Look.lua", ...) then return end -- DisasterZone UI/Look.lua
-- The game's UI in the addon's looks (Settings > UI): the mockup of 2026-10-13, the user's picks the same day: all five
-- custom looks for every part, party and raid frames in the same set, reskin where the look can be reached and replace
-- (and work every time) where it can't, and no working with other UI addons.
-- Parts and how each gets its look:
--   units    player, target, target of target, focus, pet       replaced (UI/LookUnits.lua: secure unit buttons)
--   group    party and raid frames                                replaced (UI/LookUnits.lua: secure group headers)
--   cast     player, target and focus cast bars                   replaced (UI/LookCast.lua)
--   bars     action bars 1 - 5, stance and pet bars, bags, menu   reskinned (UI/LookBars.lua: Blizzard's own buttons);
--            and the experience / reputation bar                  replaced (the game's status bars retired)
--   minimap  the minimap, zone, clock and its buttons             reskinned (UI/LookMinimap.lua)
-- Looks: blizzard (the default: the game's frames, untouched), flat, halo, sigil, slate, gilded (the names of the
-- meter and class bar themes). Settings: ui.look (everything), ui.<part>.look ("inherit" = ui.look, or a look of its
-- own), ui.<part>.<option> (each part's overrides). A part that was replaced keeps its own frames until a reload: the
-- game doesn't let an addon hand its frames back (Look:NeedsReload).
--
-- This file: the looks' face data and the parts every face is drawn with, so every part draws them the same way:
--   Look:Panel(f)  a frame's ground: fill, edges, inner line, gilded corners      panel:Apply(look)
--   Look:Bar(parent)  a bar: flat | pill | lit | hair | gilt                      bar:Apply(look, kind), :SetValue
--   Look:Icon(parent)  an icon or portrait: square | round | framed | gilt | small icon:Apply(look), :SetTexture ...
-- No new art: the round parts are the game's portrait disc (masks stripe on this client), the gilded bars its
-- status bar texture.
local addonName, ns = ...

local Look = ns:NewModule("Look")
local UI, S = ns.UI, ns.Style

local floor, max, min = math.floor, math.max, math.min
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring

local WHITE = "Interface\\Buttons\\WHITE8X8"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SBAR = "Interface\\TargetingFrame\\UI-StatusBar"
Look.WHITE, Look.DISC, Look.SBAR = WHITE, DISC, SBAR

Look.PARTS = {
    { key = "units", name = "Unit frames", tip = "Player, target, target of target, focus and pet.", replaced = true },
    { key = "group", name = "Party and raid", tip = "Party frames and raid frames.", replaced = true },
    { key = "cast", name = "Cast bars", tip = "Your cast bar and the target's and focus's.", replaced = true },
    { key = "bars", name = "Action bars", tip = "Every action bar, the stance and pet bars, bags, menu and experience.",
      replaced = true },
    { key = "minimap", name = "Minimap", tip = "The map, the zone and the clock, and the buttons around it." },
}
local PART = {}
for _, p in ipairs(Look.PARTS) do PART[p.key] = p end

-- The faces. panel: bg (one colour, or bg + bg2 a top-to-bottom gradient), edge (1 px), outer (1 px outside it), inner
-- (1 px inside), corners (gilded L's); head: a header strip's gradient + line; bar: the bar kind; track: under the
-- fill; fillA: the fill's opacity; icon: square | round | framed | gilt | none; rim: the icon's edge colour; nameC: the
-- name's colour (nameClass: in class colour); upper: capitals; gap: between action buttons; plate: a ground behind
-- an action bar; studs: diamonds at a plate's ends.
Look.LOOKS = {
    { key = "blizzard", name = "Blizzard", tip = "The game's own frames, untouched." },
    { key = "flat", name = "Flat", tip = "Dark 66% panels, 1 px black edges, class-colour bars, square icons.",
      panel = { bg = { 0.039, 0.039, 0.051, 0.66 }, edge = { 0, 0, 0, 1 } },
      bar = "flat", track = { 1, 1, 1, 0.04 }, fillA = 0.74, icon = "square", rim = { 0, 0, 0, 1 },
      nameC = { 1, 1, 1 }, gap = 2, plate = true, buttonSize = 34 },
    { key = "halo", name = "Halo", tip = "Round portraits and buttons in thin rings, pill bars with a soft fade.",
      bar = "pill", track = { 0.031, 0.031, 0.043, 0.62 }, fillA = 0.9, icon = "round", rim = { 0, 0, 0, 1 },
      nameC = { 0.96, 0.86, 0.56 }, gap = 6, plate = false, buttonSize = 32, fade = true },
    { key = "sigil", name = "Sigil", tip = "Framed tiles, bars with a lit top edge, small caps. Crisp and bold.",
      panel = { bg = { 0.035, 0.035, 0.043, 0.86 }, edge = { 0, 0, 0, 1 }, inner = { 1, 1, 1, 0.07 } },
      head = { top = { 0.145, 0.145, 0.17, 1 }, bottom = { 0.078, 0.078, 0.09, 1 }, line = { 0, 0, 0, 1 } },
      bar = "lit", track = { 0.071, 0.071, 0.082, 1 }, fillA = 1, icon = "framed", rim = { 1, 0.82, 0, 0.75 },
      nameC = { 1, 0.82, 0 }, upper = true, gap = 3, plate = true, buttonSize = 34 },
    { key = "slate", name = "Slate", tip = "Text first: names in class colour, hairline bars, no portraits. The least screen.",
      panel = { bg = { 0.051, 0.051, 0.067, 0.72 }, edge = { 1, 1, 1, 0.08 } },
      bar = "hair", track = { 1, 1, 1, 0.08 }, fillA = 1, icon = "none", rim = { 0, 0, 0, 0 },
      nameC = { 1, 1, 1 }, nameClass = true, gap = 1, plate = false, buttonSize = 32 },
    { key = "gilded", name = "Gilded", tip = "Gold trim and corner studs, textured bars. The most 'WoW' of the looks.",
      panel = { bg = { 0.086, 0.063, 0.027, 0.9 }, bg2 = { 0.039, 0.031, 0.02, 0.9 }, edge = { 0.43, 0.33, 0.13, 1 },
                outer = { 0, 0, 0, 1 }, corners = { 0.89, 0.73, 0.33, 1 } },
      head = { top = { 0.231, 0.169, 0.059, 1 }, bottom = { 0.106, 0.078, 0.031, 1 }, line = { 0.54, 0.42, 0.15, 1 } },
      bar = "gilt", track = { 0, 0, 0, 0.45 }, fillA = 1, icon = "gilt", rim = { 0.66, 0.51, 0.17, 1 },
      nameC = { 1, 0.84, 0.42 }, gap = 3, plate = true, studs = true, buttonSize = 34 },
}
local BY_KEY = {}
for _, l in ipairs(Look.LOOKS) do BY_KEY[l.key] = l end
Look.BY_KEY = BY_KEY

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting(path)
    if v == nil then return default end
    return v
end
Look.Get = Get

-- The look chosen for a part ("inherit" follows Look for everything).
function Look:Chosen(part)
    local own = Get("ui." .. part .. ".look", "inherit")
    if own == nil or own == "inherit" or not BY_KEY[own] then
        local all = Get("ui.look", "blizzard")
        return BY_KEY[all] and all or "blizzard"
    end
    return own
end

-- The look a part wears now: a replaced part keeps the look it started with until a reload when it was switched to
-- or from Blizzard (its frames are the game's or ours for the whole session).
local applied = {}
function Look:Key(part)
    local chosen = self:Chosen(part)
    local p = PART[part]
    if p and p.replaced and applied[part] ~= nil then
        local was = applied[part]
        if (was == "blizzard") ~= (chosen == "blizzard") then return was end
    end
    return chosen
end

function Look:For(part) return BY_KEY[self:Key(part)] or BY_KEY.blizzard end
function Look:IsOn(part) return self:Key(part) ~= "blizzard" end

-- A part's option (Settings > UI, the part's card).
function Look:Opt(part, key, default) return Get("ui." .. part .. "." .. key, default) end

-- True when a replaced part was switched to or from Blizzard and waits for a reload.
function Look:NeedsReload(part)
    local p = PART[part]
    if not p or not p.replaced or applied[part] == nil then return false end
    return (applied[part] == "blizzard") ~= (self:Chosen(part) == "blizzard")
end

-- (the parts' files call this once their frames are up)
function Look:SetApplied(part, key) applied[part] = key end

function Look:OnInit()
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) ~= "string" or path:sub(1, 3) ~= "ui." then return end
        local reload = {}
        for _, p in ipairs(Look.PARTS) do
            if path == "ui.look" or path:find("^ui%." .. p.key .. "%.") then
                -- (restyled live: the frames wear the new look now)
                if applied[p.key] ~= nil and not Look:NeedsReload(p.key) then applied[p.key] = Look:Chosen(p.key) end
                ns:Fire("UI_LOOK_CHANGED", p.key, path)
                if Look:NeedsReload(p.key) then reload[#reload + 1] = p.name end
            end
        end
        if #reload > 0 and ns.Popup and ns.Popup.Confirm then
            ns.Popup:Confirm({ key = "uilookreload", title = "Reload to switch",
                text = ("%s switch between the game's frames and DisasterZone's after a reload."):format(
                    table.concat(reload, ", ")), ok = "Reload now", cancel = "Later",
                onAccept = function() if ReloadUI then ReloadUI() end end })
        end
    end)
end

-- The look tiles (Settings > UI): a small player frame in each look; Blizzard's says what it is.
local function PaintTile(tile, t)
    local p = tile.preview
    if not p.host then
        p:SetSize(88, 40)
        p.host = CreateFrame("Frame", nil, p)
        p.host:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
        p.host:SetScale(0.36)
        p.blizz = UI:Text(p, "small", "SUB", { justify = "CENTER" })
        p.blizz:SetPoint("TOP", tile, "TOP", 0, -16)
        p.blizz:SetText("The game's\nown frames")
        p.blizz:SetWordWrap(true)
    end
    p.blizz:SetShown(t.key == "blizzard")
    if t.key == "blizzard" then if p.face then p.host:Hide() end return end
    if not ns.LookUnits then return end
    if not p.face then
        p.face = ns.LookUnits:NewFace(p.host, "big", "units", "left")
    end
    p.host:Show()
    p.face:Apply(t)
    p.face:Set(ns.LookUnits.Fake("player"))
end

function Look:Tiles(SU, sec)
    if not ns.Themes:Kind("uilook") then ns.Themes:Define("uilook", Look.LOOKS, "blizzard", { setting = "ui.look" }) end
    return ns.Themes:SettingsRow(SU, sec, "uilook", "Look for everything",
        "Every part below that follows it. Blizzard leaves the game's frames as they are.",
        { tileW = 88, tileH = 64, gap = 5, clip = true, band = true, nameY = 5, previewAt = { 6, -10 },
          paint = PaintTile })
end

---------------------------------------------------------------------------
-- Colours
---------------------------------------------------------------------------

Look.HOSTILE = { 0.78, 0.21, 0.17 }
Look.NEUTRAL = { 0.9, 0.75, 0.2 }
Look.FRIEND = { 0.3, 0.78, 0.33 }
Look.POWER = {
    [0] = { 0.24, 0.44, 0.85 }, [1] = { 0.77, 0.19, 0.17 }, [2] = { 1, 0.5, 0.25 }, [3] = { 1, 0.86, 0.25 },
    MANA = { 0.24, 0.44, 0.85 }, RAGE = { 0.77, 0.19, 0.17 }, FOCUS = { 1, 0.5, 0.25 }, ENERGY = { 1, 0.86, 0.25 },
}

function Look.ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 0.6, 0.6, 0.6
end

---------------------------------------------------------------------------
-- Panels
---------------------------------------------------------------------------

local function Tex(parent, layer, sub, path)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 0)
    t:SetTexture(path or WHITE)
    return t
end
Look.Tex = Tex

local function Color(t, c, a)
    if not c then t:Hide() return end
    t:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1)
    t:Show()
end
Look.Color = Color

local function Gradient(t, bottom, top)
    if not (t.SetGradient and CreateColor) then Color(t, top) return end
    t:SetVertexColor(1, 1, 1, 1)
    local ok = pcall(t.SetGradient, t, "VERTICAL", CreateColor(bottom[1], bottom[2], bottom[3], bottom[4] or 1),
        CreateColor(top[1], top[2], top[3], top[4] or 1))
    if not ok then Color(t, top) end
    t:Show()
end
Look.Gradient = Gradient

-- Four 1 px lines round a frame, `out` px outside its edge (negative: inside).
local function Edges(parent, layer, sub)
    local e = {}
    for i = 1, 4 do e[i] = Tex(parent, layer or "BORDER", sub) end
    function e:Place(f, out)
        local a, b = out, -out
        e[1]:ClearAllPoints(); e[1]:SetPoint("TOPLEFT", f, "TOPLEFT", -a, a); e[1]:SetPoint("TOPRIGHT", f, "TOPRIGHT", a, a); e[1]:SetHeight(1)
        e[2]:ClearAllPoints(); e[2]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -a, b); e[2]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", a, b); e[2]:SetHeight(1)
        e[3]:ClearAllPoints(); e[3]:SetPoint("TOPLEFT", f, "TOPLEFT", -a, a); e[3]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -a, b); e[3]:SetWidth(1)
        e[4]:ClearAllPoints(); e[4]:SetPoint("TOPRIGHT", f, "TOPRIGHT", a, a); e[4]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", a, b); e[4]:SetWidth(1)
    end
    function e:Paint(c)
        for i = 1, 4 do Color(e[i], c) end
    end
    return e
end
Look.Edges = Edges

local PanelMethods = {}

-- Paints a frame's ground in a look (nil or Blizzard: nothing).
function PanelMethods:Apply(look)
    local p = look and look.panel
    if not p then
        self.bg:Hide(); self.edge:Paint(nil); self.outer:Paint(nil); self.inner:Paint(nil)
        for _, c in ipairs(self.corners) do c:Hide() end
        return
    end
    if p.bg2 then Gradient(self.bg, p.bg2, p.bg) else Color(self.bg, p.bg) end
    self.edge:Paint(p.edge)
    self.outer:Paint(p.outer)
    self.inner:Paint(p.inner)
    for _, c in ipairs(self.corners) do
        if p.corners then Color(c, p.corners) else c:Hide() end
    end
end

function Look:Panel(f)
    local p = { f = f }
    for k, fn in pairs(PanelMethods) do p[k] = fn end
    p.bg = Tex(f, "BACKGROUND", -6)
    p.bg:SetAllPoints(f)
    p.edge = Edges(f, "BORDER", 1); p.edge:Place(f, 0)
    p.outer = Edges(f, "BORDER", 0); p.outer:Place(f, 1)
    p.inner = Edges(f, "BORDER", 2); p.inner:Place(f, -1)
    -- gilded corners: two 2 px arms, 8 long, at the top corners
    p.corners = {}
    for i, pt in ipairs({ "TOPLEFT", "TOPRIGHT" }) do
        local sx = (i == 1) and -2 or 2
        local h = Tex(f, "OVERLAY", 3); h:SetSize(9, 2); h:SetPoint(pt, f, pt, sx, 2)
        local v = Tex(f, "OVERLAY", 3); v:SetSize(2, 9); v:SetPoint(pt, f, pt, sx, 2)
        p.corners[#p.corners + 1] = h
        p.corners[#p.corners + 1] = v
    end
    return p
end

---------------------------------------------------------------------------
-- Bars: a fill over a track, as wide as the bar's set width times the value
---------------------------------------------------------------------------

local BarMethods = {}

function BarMethods:SetWidthNow(w) self.w = w; self.f:SetWidth(w); self:Layout() end

-- kind: flat | pill | lit | hair | gilt (nil: the look's).
function BarMethods:Apply(look, kind, h)
    self.look = look
    self.kind = kind or (look and look.bar) or "flat"
    self.h = h or self.h or 10
    if self.kind == "hair" then self.f:SetHeight(max(1, self.h)) else self.f:SetHeight(self.h) end
    local tr = look and look.track or { 1, 1, 1, 0.05 }
    local pill = self.kind == "pill"
    Color(self.track, tr)
    for _, c in ipairs({ self.tcapL, self.tcapR }) do if pill then Color(c, tr) else c:Hide() end end
    self.fill:SetTexture(self.kind == "gilt" and SBAR or WHITE)
    self.lit:SetShown(self.kind == "lit")
    self.capL:SetShown(pill)
    self.capR:SetShown(pill)
    self:Paint()
    self:Layout()
end

function BarMethods:SetColor(r, g, b)
    self.r, self.g, self.b = r, g, b
    self:Paint()
end

function BarMethods:Paint()
    local r, g, b = self.r or 0.5, self.g or 0.5, self.b or 0.5
    local a = (self.look and self.look.fillA) or 1
    if self.kind == "lit" then
        Gradient(self.fill, { r * 0.62, g * 0.62, b * 0.62, a }, { min(1, r * 1.12 + 0.08), min(1, g * 1.12 + 0.08),
            min(1, b * 1.12 + 0.08), a })
        self.lit:SetVertexColor(1, 1, 1, 0.35)
    elseif self.kind == "pill" and self.look and self.look.fade then
        Gradient(self.fill, { r, g, b, a }, { r, g, b, a })
        if self.fill.SetGradient and CreateColor then
            pcall(self.fill.SetGradient, self.fill, "HORIZONTAL", CreateColor(r, g, b, a * 0.45), CreateColor(r, g, b, a))
        end
        self.capL:SetVertexColor(r, g, b, a * 0.45)
        self.capR:SetVertexColor(r, g, b, a)
    else
        self.fill:SetVertexColor(r, g, b, a)
        self.capL:SetVertexColor(r, g, b, a)
        self.capR:SetVertexColor(r, g, b, a)
    end
end

function BarMethods:SetValue(v)
    v = tonumber(v) or 0
    if v ~= v then v = 0 end
    self.v = max(0, min(1, v))
    self:Layout()
end

function BarMethods:Layout()
    local w = self.w or self.f:GetWidth() or 0
    local h = (self.kind == "hair") and max(1, self.h) or self.h
    local pill = self.kind == "pill"
    local r = pill and floor(h / 2) or 0
    self.track:ClearAllPoints()
    self.track:SetPoint("TOPLEFT", self.f, "TOPLEFT", r, 0)
    self.track:SetPoint("BOTTOMRIGHT", self.f, "BOTTOMRIGHT", -r, 0)
    if pill then
        self.tcapL:ClearAllPoints(); self.tcapL:SetSize(r, h); self.tcapL:SetPoint("LEFT", self.f, "LEFT", 0, 0)
        self.tcapR:ClearAllPoints(); self.tcapR:SetSize(r, h); self.tcapR:SetPoint("RIGHT", self.f, "RIGHT", 0, 0)
    end
    local fw = (w - 2 * r) * (self.v or 0)
    self.fill:ClearAllPoints()
    self.fill:SetPoint("TOPLEFT", self.f, "TOPLEFT", r, 0)
    self.fill:SetPoint("BOTTOMLEFT", self.f, "BOTTOMLEFT", r, 0)
    self.fill:SetWidth(max(0.01, fw))
    self.fill:SetShown(fw > 0.5)
    if self.kind == "gilt" then self.fill:SetTexCoord(0, max(0.01, self.v or 0), 0, 1) else self.fill:SetTexCoord(0, 1, 0, 1) end
    if pill then
        local on = (self.v or 0) > 0
        self.capL:ClearAllPoints(); self.capL:SetSize(r, h); self.capL:SetPoint("RIGHT", self.fill, "LEFT", 0, 0)
        self.capR:ClearAllPoints(); self.capR:SetSize(r, h); self.capR:SetPoint("LEFT", self.fill, "RIGHT", 0, 0)
        self.capL:SetShown(on); self.capR:SetShown(on)
    end
    self.lit:ClearAllPoints()
    self.lit:SetPoint("TOPLEFT", self.fill, "TOPLEFT", 0, 0)
    self.lit:SetPoint("TOPRIGHT", self.fill, "TOPRIGHT", 0, 0)
    self.lit:SetHeight(1)
    -- a part of the track drawn over the fill's end (latency on a cast bar): SetEnd(frac, r, g, b, a)
    if self.endPart and self.endFrac then
        self.endPart:ClearAllPoints()
        self.endPart:SetPoint("TOPRIGHT", self.f, "TOPRIGHT", -r, 0)
        self.endPart:SetPoint("BOTTOMRIGHT", self.f, "BOTTOMRIGHT", -r, 0)
        self.endPart:SetWidth(max(0.01, (w - 2 * r) * self.endFrac))
        -- (a pill's end is round: the wash takes the track's right cap too)
        if self.endCap then
            self.endCap:ClearAllPoints()
            self.endCap:SetSize(r, h)
            self.endCap:SetPoint("RIGHT", self.f, "RIGHT", 0, 0)
            self.endCap:SetShown(pill and self.endPart:IsShown())
        end
    end
end

-- A stretch at the bar's end in its own colour (a cast's latency); frac nil: none.
function BarMethods:SetEnd(frac, r, g, b, a)
    if not self.endPart then
        self.endPart = Tex(self.f, "ARTWORK", 0)
        self.endCap = Tex(self.f, "ARTWORK", 0, DISC)
        self.endCap:SetTexCoord(0.5, 1, 0, 1)
    end
    self.endFrac = frac
    if not frac or frac <= 0 then self.endPart:Hide(); self.endCap:Hide() return end
    self.endPart:SetVertexColor(r or 1, g or 0.25, b or 0.16, a or 0.45)
    self.endCap:SetVertexColor(r or 1, g or 0.25, b or 0.16, a or 0.45)
    self.endPart:Show()
    self:Layout()
end

function Look:Bar(parent)
    local f = CreateFrame("Frame", nil, parent)
    local b = { f = f, v = 0, h = 10 }
    for k, fn in pairs(BarMethods) do b[k] = fn end
    b.track = Tex(f, "BACKGROUND", 1)
    b.tcapL = Tex(f, "BACKGROUND", 1, DISC); b.tcapL:SetTexCoord(0, 0.5, 0, 1)
    b.tcapR = Tex(f, "BACKGROUND", 1, DISC); b.tcapR:SetTexCoord(0.5, 1, 0, 1)
    b.fill = Tex(f, "ARTWORK", 1)
    b.capL = Tex(f, "ARTWORK", 1, DISC); b.capL:SetTexCoord(0, 0.5, 0, 1)
    b.capR = Tex(f, "ARTWORK", 1, DISC); b.capR:SetTexCoord(0.5, 1, 0, 1)
    b.lit = Tex(f, "ARTWORK", 2)
    f:SetScript("OnSizeChanged", function(_, w) if w and w > 0 and not b.fixedW then b.w = w; b:Layout() end end)
    return b
end

---------------------------------------------------------------------------
-- Icons and portraits
---------------------------------------------------------------------------

local IconMethods = {}

-- shape: square | round | framed | gilt | small | none (nil: the look's).
function IconMethods:Apply(look, shape)
    self.look = look
    self.shape = shape or (look and look.icon) or "square"
    local f = self.f
    f:SetShown(self.shape ~= "none")
    local rim = look and look.rim or { 0, 0, 0, 1 }
    local round = self.shape == "round"
    self.ring:SetShown(round)
    self.ringIn:SetShown(round)
    if round then
        Color(self.ring, self.ringColor or rim)
        Color(self.ringIn, { 0, 0, 0, 1 })
        self.edge:Paint(nil); self.edge2:Paint(nil)
    elseif self.shape == "framed" then
        self.edge:Paint({ 0, 0, 0, 1 }); self.edge2:Paint(rim)
    elseif self.shape == "gilt" then
        self.edge:Paint({ 0, 0, 0, 1 }); self.edge2:Paint(rim)
    else
        self.edge:Paint(self.shape == "small" and nil or rim); self.edge2:Paint(nil)
    end
    self:Refresh()
end

-- The ring's colour (Halo: the class or the rarity).
function IconMethods:SetRing(r, g, b)
    self.ringColor = r and { r, g, b, 1 } or nil
    if self.shape == "round" then Color(self.ring, self.ringColor or (self.look and self.look.rim) or { 0, 0, 0, 1 }) end
end

-- A texture (a path or file id), with tex coords for a square crop; round looks get the game's round cut.
function IconMethods:SetTexture(path, l, r, t, b)
    self.kind, self.path, self.unit = "tex", path, nil
    self.coords = l and { l, r, t, b } or nil
    self:Refresh()
end

-- A unit's 2D portrait.
function IconMethods:SetPortrait(unit)
    self.kind, self.unit, self.path = "unit", unit, nil
    self:Refresh()
end

-- The disc mask on the texture (round textures), made the first time.
function IconMethods:Mask(on)
    local t = self.tex
    if on and not self.mask and self.f.CreateMaskTexture then
        self.mask = self.f:CreateMaskTexture()
        self.mask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        self.mask:SetAllPoints(t)
    end
    if not self.mask then return end
    if on and not self.masked then pcall(t.AddMaskTexture, t, self.mask); self.masked = true
    elseif not on and self.masked then pcall(t.RemoveMaskTexture, t, self.mask); self.masked = false end
end

function IconMethods:Refresh()
    local t = self.tex
    if self.kind == "unit" and self.unit then
        self:Mask(false)
        if SetPortraitTexture then pcall(SetPortraitTexture, t, self.unit) end
        if self.shape == "round" then t:SetTexCoord(0, 1, 0, 1) else t:SetTexCoord(0.14, 0.86, 0.14, 0.86) end
    elseif self.path then
        -- (a texture with coords is a cut of a sheet, already shaped: the class circles; else a round look masks it
        -- with the portrait disc: the portrait cut did nothing to file ids in game)
        if self.shape == "round" and not self.coords then
            t:SetTexture(self.path)
            t:SetTexCoord(0.06, 0.94, 0.06, 0.94)
            self:Mask(true)
        else
            self:Mask(false)
            t:SetTexture(self.path)
            local c = self.coords
            if c then t:SetTexCoord(c[1], c[2], c[3], c[4]) else t:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
        end
    end
end

function Look:Icon(parent)
    local f = CreateFrame("Frame", nil, parent)
    local ic = { f = f }
    for k, fn in pairs(IconMethods) do ic[k] = fn end
    ic.ring = Tex(f, "BACKGROUND", 1, DISC)
    ic.ring:SetPoint("TOPLEFT", -3, 3); ic.ring:SetPoint("BOTTOMRIGHT", 3, -3)
    ic.ringIn = Tex(f, "BACKGROUND", 2, DISC)
    ic.ringIn:SetPoint("TOPLEFT", -1.5, 1.5); ic.ringIn:SetPoint("BOTTOMRIGHT", 1.5, -1.5)
    ic.tex = f:CreateTexture(nil, "ARTWORK")
    ic.tex:SetAllPoints(f)
    ic.edge = Edges(f, "OVERLAY", 1); ic.edge:Place(f, -0)
    ic.edge2 = Edges(f, "OVERLAY", 2); ic.edge2:Place(f, -1)
    return ic
end

-- A class's square icon / round circle texture and coords.
function Look.ClassIcon(class, round)
    local co = CLASS_ICON_TCOORDS and class and CLASS_ICON_TCOORDS[class]
    if not co then return nil end
    if round then return "Interface\\TargetingFrame\\UI-Classes-Circles", co[1], co[2], co[3], co[4] end
    local inset = 0.02
    return "Interface\\WorldStateFrame\\Icons-Classes", co[1] + inset, co[2] - inset, co[3] + inset, co[4] - inset
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------

-- A unit frame's text: the type scale's size, the game's outline-ish shadow.
function Look:Text(parent, size, color, opts)
    local fs = UI:Text(parent, size or "body", color or "TEXT", { shadow = true, justify = opts and opts.justify })
    fs:SetWordWrap(false)
    return fs
end

-- A frame no one sees: what a replaced Blizzard frame is parented to.
function Look:Hidden()
    if not self.hidden then
        self.hidden = CreateFrame("Frame", "DisasterZoneLookHidden", UIParent)
        self.hidden:Hide()
    end
    return self.hidden
end

-- Takes a Blizzard frame out of play the way unit frame addons do: no events, hidden, under a hidden parent (so
-- nothing the game does to it can show it again). Out of combat only (protected frames); returns true when done.
function Look:Retire(f, keepParent)
    if type(f) == "string" then f = _G[f] end
    if not f then return true end
    if InCombatLockdown and InCombatLockdown() and f.IsProtected and f:IsProtected() then return false end
    pcall(f.UnregisterAllEvents, f)
    pcall(f.Hide, f)
    if not keepParent then pcall(f.SetParent, f, self:Hidden()) end
    return true
end
