if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LookMinimap.lua", ...) then return end -- DisasterZone UI/LookMinimap.lua
-- The minimap in the addon's looks (UI/Look.lua part "minimap"): reskinned. The map stays the game's (Edit Mode places
-- and sizes it; Edit layout moves it through that); its ring, zone strip, compass and buttons step aside, and the
-- look's own edge, zone and clock are drawn round it. Square looks mask it square (GetMinimapShape tells the minimap
-- button libraries), round ones keep the game's round mask. The mouse wheel zooms (the + and - are gone).
-- Options (ui.minimap.*): shape ("theme" | "round" | "square"), buttons ("edge" | "drawer" | "hover"), clock, zone.
local addonName, ns = ...

local MM = ns:NewModule("LookMinimap")
local UI = ns.UI

local pairs, ipairs, type, floor = pairs, ipairs, type, math.floor

local function Look() return ns.Look end

local HIDE = { "MinimapBorder", "MinimapCompassTexture", "MinimapNorthTag", "MinimapZoneTextButton",
    "MinimapToggleButton", "MinimapZoomIn", "MinimapZoomOut", "GameTimeFrame", "MiniMapWorldMapButton",
    "TimeManagerClockButton", "MiniMapTracking" }
local ROUND_MASK = "Textures\\MinimapMask"
local SQUARE_MASK = "Interface\\Buttons\\WHITE8X8"

local skin
local hidden = {}

local function Shape(look)
    local opt = Look():Opt("minimap", "shape", "theme")
    if opt == "round" or opt == "square" then return opt end
    return (look.key == "halo" or look.key == "gilded") and "round" or "square"
end

local function Hide(name)
    local f = _G[name]
    if not f then return end
    if not hidden[name] then
        hidden[name] = { alpha = f:GetAlpha(), mouse = f.IsMouseEnabled and f:IsMouseEnabled() }
    end
    f:SetAlpha(0)
    if f.EnableMouse and not (f.IsProtected and f:IsProtected()) then pcall(f.EnableMouse, f, false) end
end

local function ZoneColor(fs)
    local kind = GetZonePVPInfo and GetZonePVPInfo()
    if kind == "sanctuary" then fs:SetTextColor(0.41, 0.8, 0.94)
    elseif kind == "arena" or kind == "hostile" then fs:SetTextColor(1, 0.1, 0.1)
    elseif kind == "friendly" then fs:SetTextColor(0.1, 1, 0.1)
    elseif kind == "contested" then fs:SetTextColor(1, 0.7, 0)
    else fs:SetTextColor(1, 0.84, 0.42) end
end

local function Build()
    if skin then return skin end
    local L = Look()
    local map = _G.Minimap
    if not map then return nil end
    skin = CreateFrame("Frame", "DisasterZoneMinimapSkin", map)
    skin:SetAllPoints(map)
    skin:SetFrameLevel(map:GetFrameLevel() + 2)
    -- round: rings behind; square: a panel round it
    skin.ring = L.Tex(map, "BACKGROUND", -7, L.DISC)
    skin.ringIn = L.Tex(map, "BACKGROUND", -6, L.DISC)
    skin.edge = L.Edges(skin, "OVERLAY", 1)
    skin.inner = L.Edges(skin, "OVERLAY", 2)
    skin.head = L.Tex(skin, "BORDER", 1)
    skin.headLine = L.Tex(skin, "BORDER", 2)
    skin.plaque = CreateFrame("Frame", nil, skin)
    skin.plaque.panel = L:Panel(skin.plaque)
    skin.stud = L.Tex(skin, "OVERLAY", 5)
    skin.stud:SetSize(8, 8)
    if skin.stud.SetRotation then skin.stud:SetRotation(math.pi / 4) end
    skin.zone = L:Text(skin, "body", "GOLD")
    skin.sub = L:Text(skin, "small", "SUB")
    skin.clock = L:Text(skin, "small", "TEXT", { justify = "RIGHT" })
    skin.clockBg = L.Tex(skin, "ARTWORK", 1)
    -- the drawer: a small ··· that shows the addon buttons
    skin.knob = CreateFrame("Button", nil, skin)
    skin.knob:SetSize(18, 18)
    skin.knob.bg = L.Tex(skin.knob, "BACKGROUND", 0)
    skin.knob.bg:SetAllPoints()
    skin.knob.fs = L:Text(skin.knob, "small", "TEXT", { justify = "CENTER" })
    skin.knob.fs:SetPoint("CENTER", 0, 1)
    skin.knob.fs:SetText("\194\183\194\183\194\183")
    skin.knob:SetScript("OnClick", function() skin.open = not skin.open; MM:Buttons() end)
    -- the wheel zooms
    map:EnableMouseWheel(true)
    map:SetScript("OnMouseWheel", function(self, d)
        local z = self:GetZoom() or 0
        if d > 0 and z < (self:GetZoomLevels() or 5) - 1 then self:SetZoom(z + 1)
        elseif d < 0 and z > 0 then self:SetZoom(z - 1) end
    end)
    skin:SetScript("OnUpdate", function(self, dt)
        self.t = (self.t or 0) + (dt or 0)
        if self.t < 1 then return end
        self.t = 0
        MM:Clock()
        if Look():Opt("minimap", "buttons", "edge") == "hover" then MM:Buttons() end
    end)
    return skin
end

function MM:Clock()
    if not skin then return end
    if not Look():Opt("minimap", "clock", true) then skin.clock:SetText("") return end
    local local_ = GetCVarBool and GetCVarBool("timeMgrUseLocalTime")
    local h, m
    if local_ or not GetGameTime then h, m = tonumber(date("%H")), tonumber(date("%M"))
    else h, m = GetGameTime() end
    skin.clock:SetText(("%02d:%02d"):format(h or 0, m or 0))
end

function MM:Zone()
    if not skin then return end
    local on = Look():Opt("minimap", "zone", true)
    skin.zone:SetText(on and (GetMinimapZoneText and GetMinimapZoneText() or "") or "")
    ZoneColor(skin.zone)
    local look = skin.look
    if look and (look.key == "sigil") then skin.zone:SetText(skin.zone:GetText():upper()) end
    local sub = GetSubZoneText and GetSubZoneText() or ""
    skin.sub:SetText((on and look and look.key == "slate" and sub ~= (GetMinimapZoneText and GetMinimapZoneText())) and sub or "")
end

-- The minimap button libraries' buttons (children of the map named LibDBIcon...): on the edge as they are, in the
-- drawer (shown while it's open), or on mouse-over.
function MM:Buttons()
    local map = _G.Minimap
    if not map or not skin then return end
    local mode = Look():Opt("minimap", "buttons", "edge")
    local show = mode == "edge" or (mode == "drawer" and skin.open) or (mode == "hover" and map:IsMouseOver())
    skin.knob:SetShown(mode == "drawer")
    for _, ch in ipairs({ map:GetChildren() }) do
        local n = ch:GetName() or ""
        if n:find("^LibDBIcon") or n:find("MinimapButton") then ch:SetAlpha(show and 1 or 0) end
    end
end

function MM:Apply()
    local L = Look()
    local map = _G.Minimap
    if not map or not L:IsOn("minimap") then return end
    local look = L:For("minimap")
    local s = Build()
    s.look = look
    for _, n in ipairs(HIDE) do Hide(n) end
    local cl = _G.MinimapCluster
    if cl and cl.BorderTop then cl.BorderTop:SetAlpha(0) end
    if cl and cl.ZoneTextButton then cl.ZoneTextButton:SetAlpha(0) end
    local shape = Shape(look)
    if map.SetMaskTexture then pcall(map.SetMaskTexture, map, shape == "round" and ROUND_MASK or SQUARE_MASK) end
    MM.shape = shape
    local k = look.key
    local round = shape == "round"
    -- edges / rings
    s.ring:ClearAllPoints(); s.ringIn:ClearAllPoints()
    local rw = (k == "gilded") and 5 or 3
    s.ring:SetPoint("TOPLEFT", map, "TOPLEFT", -rw, rw); s.ring:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", rw, -rw)
    s.ringIn:SetPoint("TOPLEFT", map, "TOPLEFT", -1.5, 1.5); s.ringIn:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", 1.5, -1.5)
    s.ring:SetTexture(round and L.DISC or L.WHITE)
    s.ringIn:SetTexture(round and L.DISC or L.WHITE)
    if round then
        L.Color(s.ring, (k == "gilded") and look.rim or { 1, 0.82, 0, 0.75 })
        L.Color(s.ringIn, { 0, 0, 0, 1 })
        s.edge:Paint(nil); s.inner:Paint(nil)
    else
        s.ring:Hide(); s.ringIn:Hide()
        s.edge:Place(map, 1)
        s.inner:Place(map, 0)
        if k == "slate" then s.edge:Paint(nil); s.inner:Paint(nil)
        elseif k == "sigil" then s.edge:Paint({ 0, 0, 0, 1 }); s.inner:Paint({ 1, 0.82, 0, 0.6 })
        elseif k == "gilded" then s.edge:Paint({ 0, 0, 0, 1 }); s.inner:Paint(look.rim)
        else s.edge:Paint({ 0, 0, 0, 1 }); s.inner:Paint({ 1, 1, 1, 0.08 }) end
    end
    -- the zone and the clock, per look
    s.head:Hide(); s.headLine:Hide(); s.plaque:Hide(); s.stud:Hide(); s.clockBg:Hide()
    s.zone:ClearAllPoints(); s.clock:ClearAllPoints(); s.sub:ClearAllPoints()
    UI:SetTextSize(s.zone, (k == "sigil" or k == "halo") and "caps" or "body")
    if k == "flat" then
        s.head:ClearAllPoints()
        s.head:SetPoint("TOPLEFT", map, "BOTTOMLEFT", -1, -1)
        s.head:SetPoint("TOPRIGHT", map, "BOTTOMRIGHT", 1, -1)
        s.head:SetHeight(20)
        L.Color(s.head, { 0.039, 0.039, 0.051, 0.66 })
        s.zone:SetPoint("LEFT", s.head, "LEFT", 6, 0)
        s.clock:SetPoint("RIGHT", s.head, "RIGHT", -6, 0)
    elseif k == "sigil" then
        s.head:ClearAllPoints()
        s.head:SetPoint("BOTTOMLEFT", map, "TOPLEFT", -1, 2)
        s.head:SetPoint("BOTTOMRIGHT", map, "TOPRIGHT", 1, 2)
        s.head:SetHeight(18)
        L.Gradient(s.head, look.head.bottom, look.head.top)
        s.zone:SetPoint("LEFT", s.head, "LEFT", 6, 0)
        s.clock:SetPoint("RIGHT", s.head, "RIGHT", -6, 0)
    elseif k == "slate" then
        s.zone:SetPoint("TOPLEFT", map, "TOPLEFT", 6, -5)
        s.sub:SetPoint("TOPLEFT", s.zone, "BOTTOMLEFT", 0, -1)
        s.clock:SetPoint("TOPRIGHT", map, "TOPRIGHT", -6, -5)
    elseif k == "halo" then
        s.zone:SetPoint("BOTTOM", map, "TOP", 0, 6)
        s.clock:SetPoint("TOP", map, "BOTTOM", 0, -2)
        s.clockBg:ClearAllPoints()
        s.clockBg:SetPoint("TOPLEFT", s.clock, "TOPLEFT", -8, 2)
        s.clockBg:SetPoint("BOTTOMRIGHT", s.clock, "BOTTOMRIGHT", 8, -2)
        L.Color(s.clockBg, { 0.031, 0.031, 0.043, 0.9 })
    else -- gilded
        s.plaque:ClearAllPoints()
        s.plaque:SetPoint("TOP", map, "BOTTOM", 0, -6)
        s.plaque:SetSize(math.max(100, (map:GetWidth() or 140) - 40), 18)
        s.plaque.panel:Apply(look)
        L.Gradient(s.plaque.panel.bg, look.head.bottom, look.head.top)
        s.plaque:Show()
        s.zone:SetPoint("CENTER", s.plaque, "CENTER", 0, 0)
        s.clock:SetPoint("TOP", s.plaque, "BOTTOM", 0, -2)
        s.stud:ClearAllPoints()
        s.stud:SetPoint("CENTER", map, "TOP", 0, 3)
        L.Color(s.stud, look.panel.corners)
    end
    s.knob:ClearAllPoints()
    s.knob:SetPoint("TOPRIGHT", map, "TOPRIGHT", -3, -3)
    L.Color(s.knob.bg, { 0.039, 0.039, 0.051, 0.85 })
    s:Show()
    self:Zone()
    self:Clock()
    self:Buttons()
end

-- What the minimap button libraries ask: square looks are square.
local function Shaped()
    if ns.Look and ns.Look:IsOn("minimap") then return (MM.shape == "square") and "SQUARE" or "ROUND" end
    return "ROUND"
end

function MM:OnLogin()
    local L = Look()
    L:SetApplied("minimap", L:Key("minimap"))
    if L:IsOn("minimap") and not _G.GetMinimapShape then _G.GetMinimapShape = Shaped end
    self:Apply()
    for _, e in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
        ns:RegisterEvent(e, function() MM:Zone() end)
    end
    ns:On("UI_LOOK_CHANGED", function(part)
        if part ~= "minimap" then return end
        if Look():IsOn("minimap") then
            if not _G.GetMinimapShape then _G.GetMinimapShape = Shaped end
            MM:Apply()
        else
            MM:Off()
        end
    end)
end

-- Back to the game's look without a reload.
function MM:Off()
    local map = _G.Minimap
    if map and map.SetMaskTexture then pcall(map.SetMaskTexture, map, ROUND_MASK) end
    for name, was in pairs(hidden) do
        local f = _G[name]
        if f then
            f:SetAlpha(was.alpha or 1)
            if was.mouse and f.EnableMouse and not (f.IsProtected and f:IsProtected()) then pcall(f.EnableMouse, f, true) end
        end
    end
    local cl = _G.MinimapCluster
    if cl and cl.BorderTop then cl.BorderTop:SetAlpha(1) end
    if cl and cl.ZoneTextButton then cl.ZoneTextButton:SetAlpha(1) end
    if skin then skin:Hide(); skin.ring:Hide(); skin.ringIn:Hide() end
    MM.shape = "round"
    if map then
        for _, ch in ipairs({ map:GetChildren() }) do
            local n = ch:GetName() or ""
            if n:find("^LibDBIcon") then ch:SetAlpha(1) end
        end
    end
end
