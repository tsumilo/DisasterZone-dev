if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LookMinimap.lua", ...) then return end -- DisasterZone UI/LookMinimap.lua
-- The minimap in the addon's looks (UI/Look.lua part "minimap"): reskinned. The map stays the game's (Edit Mode places
-- and sizes it; Edit layout moves it through that); its ring, zone strip, compass and buttons step aside, and the
-- look's own edge, zone and clock are drawn round it. Square looks mask it square (GetMinimapShape tells the minimap
-- button libraries), round ones keep the game's round mask. The mouse wheel zooms (the + and - are gone).
-- Options (ui.minimap.*): shape ("theme" | "round" | "square"), buttons ("edge" | "drawer" | "hover"), clock, zone.
-- Classic: the game's own minimap as it is (its ring, zone bar, clock, zoom and tracking are already the game's art);
-- ours are only the drawer (in the tooltip's edge) and its knob, a round minimap button on the ring.
local addonName, ns = ...

local MM = ns:NewModule("LookMinimap")
local UI = ns.UI

local pairs, ipairs, type, floor, unpack = pairs, ipairs, type, math.floor, unpack

local function Look() return ns.Look end
local BEZEL = "Interface\\AddOns\\" .. addonName .. "\\Media\\Blessings\\bezel"

local HIDE = { "MinimapBorder", "MinimapCompassTexture", "MinimapNorthTag", "MinimapZoneTextButton",
    "MinimapToggleButton", "MinimapZoomIn", "MinimapZoomOut", "GameTimeFrame", "MiniMapWorldMapButton",
    "TimeManagerClockButton", "MiniMapTracking" }
local ROUND_MASK = "Textures\\MinimapMask"
local SQUARE_MASK = "Interface\\Buttons\\WHITE8X8"

local skin
local hidden = {}

local function Shape(look)
    if look.game then return "round" end
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
    -- the texts on their own layer over the plaque (a child frame draws over its parent's font strings)
    skin.texts = CreateFrame("Frame", nil, skin)
    skin.texts:SetAllPoints(skin)
    skin.texts:SetFrameLevel(skin.plaque:GetFrameLevel() + 5)
    skin.zone = L:Text(skin.texts, "body", "GOLD")
    skin.sub = L:Text(skin.texts, "small", "SUB")
    skin.clock = L:Text(skin.texts, "small", "TEXT", { justify = "RIGHT" })
    skin.clockBg = L.Tex(skin, "ARTWORK", 1)
    -- the drawer: a small ··· that shows the addon buttons
    skin.knob = CreateFrame("Button", nil, skin)
    skin.knob:SetSize(18, 18)
    skin.knob.panel = L:Panel(skin.knob)
    skin.knob.fs = L:Text(skin.knob, "small", "TEXT", { justify = "CENTER" })
    skin.knob.fs:SetPoint("CENTER", 0, 1)
    skin.knob.fs:SetText("\194\183\194\183\194\183")
    skin.knob:SetScript("OnClick", function() skin.open = not skin.open; MM:Buttons() end)
    skin.knob:SetScript("OnEnter", function(self) self.fs:SetTextColor(1, 0.82, 0) end)
    skin.knob:SetScript("OnLeave", function(self) self.fs:SetTextColor(0.92, 0.9, 0.84) end)
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
        MM:KeepIconsSquare()
        local mode = Look():Opt("minimap", "buttons", "edge")
        if mode == "hover" or mode == "drawer" then MM:Buttons() end
    end)
    return skin
end

function MM:Clock()
    if not skin then return end
    if skin.look and skin.look.game then skin.clock:SetText("") return end      -- (Classic: the game's own clock)
    if not Look():Opt("minimap", "clock", true) then skin.clock:SetText("") return end
    local local_ = GetCVarBool and GetCVarBool("timeMgrUseLocalTime")
    local h, m
    if local_ or not GetGameTime then h, m = tonumber(date("%H")), tonumber(date("%M"))
    else h, m = GetGameTime() end
    skin.clock:SetText(("%02d:%02d"):format(h or 0, m or 0))
end

function MM:Zone()
    if not skin then return end
    if skin.look and skin.look.game then skin.zone:SetText(""); skin.sub:SetText("") return end
    local on = Look():Opt("minimap", "zone", true)
    skin.zone:SetText(on and (GetMinimapZoneText and GetMinimapZoneText() or "") or "")
    ZoneColor(skin.zone)
    local look = skin.look
    if look and (look.key == "sigil") then skin.zone:SetText(skin.zone:GetText():upper()) end
    local sub = GetSubZoneText and GetSubZoneText() or ""
    skin.sub:SetText((on and look and look.key == "slate" and sub ~= (GetMinimapZoneText and GetMinimapZoneText())) and sub or "")
end

-- The addon buttons on the map: any named button an addon put on it (LibDBIcon10_..., ...MinimapButton, others),
-- not the game's own (zoom, tracking, mail, clock, queue ...) and not our own seal (it has its arc).
local BLIZZ_BUTTON = { "^Minimap", "^MiniMap", "^GameTimeFrame", "^TimeManager", "^QueueStatus", "^HybridMinimap",
    "^ExpansionLandingPage", "^AddonCompartment", "^GarrisonLandingPage", "^MinimapCluster", "^" .. addonName }
local function IsAddonButton(ch)
    local n = ch and ch.GetName and ch:GetName()
    if not n then return false end
    if n:find("^LibDBIcon") then return not n:find(addonName, 1, true) end
    if n:find("MinimapButton") and not n:find("^" .. addonName) then return true end
    for _, pat in ipairs(BLIZZ_BUTTON) do if n:find(pat) then return false end end
    if ch.IsProtected and ch:IsProtected() then return false end
    if not (ch.IsObjectType and ch:IsObjectType("Button")) then return false end
    local w, h = ch:GetWidth() or 0, ch:GetHeight() or 0
    return w >= 14 and w <= 48 and h >= 14 and h <= 48
end

-- The drawer: the addon buttons taken off the map's edge into a panel in the minimap's look, beside the map (on the
-- side with room), sliding out from under the ··· knob.
-- taken[button] = { parent, points, drag, strata, level }: what it had, given back when the drawer goes.
local taken, laying = {}, false
local DRAWER_ROWS, CELL, GAP, PAD = 4, 30, 6, 8

local function Drawer()
    if skin.drawer then return skin.drawer end
    local L = Look()
    local d = CreateFrame("Frame", "DisasterZoneMinimapDrawer", UIParent)
    -- (over the map's own frames; the panel itself takes no clicks, so nothing of it can sit over a button)
    d:SetFrameStrata("HIGH")
    d:SetFrameLevel(30)
    d:SetClampedToScreen(true)
    d:EnableMouse(false)
    d.panel = L:Panel(d)
    d.empty = L:Text(d, "small", "SUB", { justify = "CENTER" })
    d.empty:SetPoint("CENTER")
    d.empty:SetText("No addon buttons")
    d:Hide()
    skin.drawer = d
    return d
end

-- The side the drawer opens to: away from the screen's nearest edge (left of a map on the right half).
local function Side()
    local map = _G.Minimap
    local cx = map and map.GetCenter and map:GetCenter()
    local W = UIParent:GetWidth() or 1920
    return (cx and cx * (map:GetEffectiveScale() / UIParent:GetEffectiveScale()) < W / 2) and 1 or -1
end

-- Lays the taken buttons out in columns of up to four (only the ones their addon shows), over the panel.
function MM:LayDrawer()
    local d = skin and skin.drawer
    if not d then return end
    local list = {}
    for b in pairs(taken) do if b:IsShown() then list[#list + 1] = b end end
    table.sort(list, function(a, b) return (a:GetName() or "") < (b:GetName() or "") end)
    local n = #list
    local rows = math.max(1, math.min(DRAWER_ROWS, n))
    local cols = math.max(1, math.ceil(n / DRAWER_ROWS))
    laying = true
    for i, b in ipairs(list) do
        local row, col = (i - 1) % DRAWER_ROWS, floor((i - 1) / DRAWER_ROWS)
        b:SetFrameStrata(d:GetFrameStrata())
        b:SetFrameLevel(d:GetFrameLevel() + 5)
        b:EnableMouse(true)
        b:ClearAllPoints()
        b:SetPoint("CENTER", d, "TOPLEFT", PAD + col * (CELL + GAP) + CELL / 2, -(PAD + row * (CELL + GAP) + CELL / 2))
        b:SetAlpha(1)
    end
    laying = false
    d:SetSize(n == 0 and 120 or (2 * PAD + cols * CELL + (cols - 1) * GAP),
        n == 0 and 30 or (2 * PAD + rows * CELL + (rows - 1) * GAP))
    d.empty:SetShown(n == 0)
    if skin.look then d.panel:Apply(skin.look) end
end

-- Opens / closes the drawer: a short slide out from the map with a fade.
function MM:ShowDrawer(open, instant)
    local d = skin and skin.drawer
    local map = _G.Minimap
    if not d or not map then return end
    local side = Side()
    local function place(dx)
        d:ClearAllPoints()
        if side < 0 then d:SetPoint("TOPRIGHT", map, "TOPLEFT", -10 + dx, 0)
        else d:SetPoint("TOPLEFT", map, "TOPRIGHT", 10 + dx, 0) end
    end
    if open == d.isOpen and not instant then return end
    d.isOpen = open
    UI:StopTween("dzMinimapDrawer")          -- (a closing slide still running hides it when stopped: before Show)
    if not open and not d:IsShown() then return end
    if open then d:Show() end
    UI:Tween("dzMinimapDrawer", 0.18, function(p)
        local k = open and p or (1 - p)
        d:SetAlpha(k)
        place((1 - k) * 14 * -side)
        if not open and p >= 1 then d:Hide() end
    end, instant)
end
local function Take(b, d)
    if taken[b] then return end
    local pts = {}
    for i = 1, (b:GetNumPoints() or 0) do pts[i] = { b:GetPoint(i) } end
    taken[b] = { parent = b:GetParent(), points = pts, drag = b:GetScript("OnDragStart"),
                 strata = b:GetFrameStrata(), level = b:GetFrameLevel() }
    b:SetParent(d)
    b:SetScript("OnDragStart", nil)            -- (dragging round the edge makes no sense in the drawer)
    if not b.dzDrawerHook then
        b.dzDrawerHook = true
        -- (the button library puts it back on the edge when the map changes: back into the grid)
        hooksecurefunc(b, "SetPoint", function(self)
            if taken[self] and not laying then MM:LayDrawer() end
        end)
    end
end

local function GiveBack()
    local any = false
    for b, was in pairs(taken) do
        any = true
        taken[b] = nil
        b:SetParent(was.parent or _G.Minimap)
        if was.drag then b:SetScript("OnDragStart", was.drag) end
        if was.strata then b:SetFrameStrata(was.strata) end
        if was.level then b:SetFrameLevel(was.level) end
        laying = true
        b:ClearAllPoints()
        for _, p in ipairs(was.points) do pcall(b.SetPoint, b, unpack(p)) end
        laying = false
    end
    return any
end

-- The icons round the map follow its shape. The button libraries ask GetMinimapShape: ours answers while the look is
-- on (over another addon's, e.g. Leatrix Plus's "ROUND") and they are told to place their icons again. The game's own
-- icons (mail, the queue eyes) keep their angle from the centre and move onto the square's edge.
local GAME_ICONS = { "MiniMapMailFrame", "MiniMapBattlefieldFrame", "LFGMinimapFrame", "MiniMapLFGFrame",
    "QueueStatusMinimapButton" }
local moved = {}          -- moved[name] = the points it had before it went onto the square's edge
local prevShape           -- the GetMinimapShape there before ours

local function Shaped()
    if ns.Look and ns.Look:IsOn("minimap") then return (MM.shape == "square") and "SQUARE" or "ROUND" end
    return prevShape and prevShape() or "ROUND"
end

-- True when ours had to (re)take the answer.
local function ClaimShape()
    local f = _G.GetMinimapShape
    if f == Shaped then return false end
    prevShape = f
    _G.GetMinimapShape = Shaped
    return true
end

local function RefreshLibIcons()
    local lib = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (lib and lib.objects and lib.Refresh) then return end
    for name, b in pairs(lib.objects) do
        if not taken[b] then pcall(lib.Refresh, lib, name) end
    end
end

local function SnapGameIcons(square)
    local map = _G.Minimap
    if not map then return end
    for _, name in ipairs(GAME_ICONS) do
        local b = _G[name]
        local locked = b and b.IsProtected and b:IsProtected() and InCombatLockdown and InCombatLockdown()
        if b and b.GetCenter and not locked then
            if square then
                local bx, by = b:GetCenter()
                local mx, my = map:GetCenter()
                if bx and mx then
                    local bs, ms = b:GetEffectiveScale(), map:GetEffectiveScale()
                    local dx, dy = (bx * bs - mx * ms) / ms, (by * bs - my * ms) / ms
                    local hw, hh = (map:GetWidth() or 140) / 2, (map:GetHeight() or 140) / 2
                    local m = math.max(math.abs(dx) / hw, math.abs(dy) / hh)
                    if m > 0.05 and math.abs(m - 1) > 0.01 then
                        if not moved[name] then
                            local pts = {}
                            for i = 1, (b:GetNumPoints() or 0) do pts[i] = { b:GetPoint(i) } end
                            moved[name] = pts
                        end
                        b:ClearAllPoints()
                        b:SetPoint("CENTER", map, "CENTER", dx / m * ms / bs, dy / m * ms / bs)
                    end
                end
            elseif moved[name] then
                b:ClearAllPoints()
                for _, p in ipairs(moved[name]) do pcall(b.SetPoint, b, unpack(p)) end
                moved[name] = nil
            end
        end
    end
end

-- After the shape changed (or the look went off): every icon placed for it.
function MM:PlaceIcons(off)
    if off then
        if _G.GetMinimapShape == Shaped then _G.GetMinimapShape = prevShape end
    else
        ClaimShape()
    end
    RefreshLibIcons()
    SnapGameIcons(not off and MM.shape == "square")
end

-- Each second while square: another addon may take GetMinimapShape after us, and the game re-anchors its icons.
function MM:KeepIconsSquare()
    if MM.shape ~= "square" then return end
    if ClaimShape() then RefreshLibIcons() end
    SnapGameIcons(true)
end

-- The addon buttons: on the edge as they are, in the drawer (a grid under the ··· knob while it's open), or on
-- mouse-over.
function MM:Buttons()
    local map = _G.Minimap
    if not map or not skin then return end
    local mode = Look():Opt("minimap", "buttons", "edge")
    skin.knob:SetShown(mode == "drawer")
    if mode == "drawer" then
        local d = Drawer()
        -- (addons put their buttons on the map, its backdrop or the cluster round it)
        for _, holder in ipairs({ map, _G.MinimapBackdrop, _G.MinimapCluster }) do
            for _, ch in ipairs({ holder:GetChildren() }) do
                if IsAddonButton(ch) then Take(ch, d) end
            end
        end
        self:LayDrawer()
        self:ShowDrawer(skin.open and true or false)
        return
    end
    if GiveBack() then RefreshLibIcons() end     -- (back on the edge for the map's shape)
    skin.open = false
    if skin.drawer then skin.drawer.isOpen = false; skin.drawer:Hide() end
    local show = mode == "edge" or (mode == "hover" and map:IsMouseOver())
    for _, ch in ipairs({ map:GetChildren() }) do
        if IsAddonButton(ch) then ch:SetAlpha(show and 1 or 0) end
    end
end

-- Classic: the game's frames shown again (as Off does), round, and only the knob and drawer of ours.
function MM:ApplyClassic(s, look)
    local L = Look()
    local map = _G.Minimap
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
    if map.SetMaskTexture then pcall(map.SetMaskTexture, map, ROUND_MASK) end
    MM.shape = "round"
    self:PlaceIcons()
    s.ring:Hide(); s.ringIn:Hide(); s.edge:Paint(nil); s.inner:Paint(nil)
    s.head:Hide(); s.headLine:Hide(); s.plaque:Hide(); s.stud:Hide(); s.clockBg:Hide()
    -- the knob: a minimap button (the tracking border's ring round a dark disc, the dots in gold) on the ring's free
    -- lower left, where the game puts none of its own
    local k = s.knob
    k.panel:Apply(nil)
    if not k.cl then
        k.cl = {}
        k.cl.bg = k:CreateTexture(nil, "BACKGROUND")
        k.cl.bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
        k.cl.bg:SetSize(20, 20)
        k.cl.bg:SetPoint("TOPLEFT", 7, -5)
        k.cl.ring = k:CreateTexture(nil, "OVERLAY")
        L:GameTex(k.cl.ring, "tracking")
        k.cl.ring:SetSize(53, 53)
        k.cl.ring:SetPoint("TOPLEFT")
        k.cl.hl = k:CreateTexture(nil, "HIGHLIGHT")
        k.cl.hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        k.cl.hl:SetAllPoints()
        if k.cl.hl.SetBlendMode then k.cl.hl:SetBlendMode("ADD") end
    end
    for _, t in pairs(k.cl) do t:Show() end
    k:SetSize(31, 31)
    k.fs:ClearAllPoints()
    k.fs:SetPoint("CENTER", k, "TOPLEFT", 17, -15)
    k.fs:SetTextColor(1, 0.82, 0)
    local r = (map:GetWidth() or 140) / 2 + 4
    k:ClearAllPoints()
    k:SetPoint("CENTER", map, "CENTER", -r * 0.72 + 1, -r * 0.72 - 2)
    s:Show()
    self:Zone()
    self:Clock()
    self:Buttons()
end

function MM:Apply()
    local L = Look()
    local map = _G.Minimap
    if not map or not L:IsOn("minimap") then return end
    local look = L:For("minimap")
    local s = Build()
    s.look = look
    if look.game then return self:ApplyClassic(s, look) end
    if s.knob.cl then for _, t in pairs(s.knob.cl) do t:Hide() end end
    s.knob:SetSize(18, 18)
    s.knob.fs:ClearAllPoints(); s.knob.fs:SetPoint("CENTER", 0, 1)
    for _, n in ipairs(HIDE) do Hide(n) end
    local cl = _G.MinimapCluster
    if cl and cl.BorderTop then cl.BorderTop:SetAlpha(0) end
    if cl and cl.ZoneTextButton then cl.ZoneTextButton:SetAlpha(0) end
    local shape = Shape(look)
    if map.SetMaskTexture then pcall(map.SetMaskTexture, map, shape == "round" and ROUND_MASK or SQUARE_MASK) end
    MM.shape = shape
    self:PlaceIcons()
    local k = look.key
    local round = shape == "round"
    -- edges / rings
    s.ring:ClearAllPoints(); s.ringIn:ClearAllPoints()
    local rw = (k == "gilded") and 5 or 3
    s.ring:SetPoint("TOPLEFT", map, "TOPLEFT", -rw, rw); s.ring:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", rw, -rw)
    s.ringIn:SetPoint("TOPLEFT", map, "TOPLEFT", -1.5, 1.5); s.ringIn:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", 1.5, -1.5)
    -- (Gilded: the worked gold bezel of the class bars, drawn in colour)
    s.ring:SetTexture(round and (k == "gilded" and BEZEL or L.DISC) or L.WHITE)
    s.ringIn:SetTexture(round and L.DISC or L.WHITE)
    if round then
        L.Color(s.ring, (k == "gilded") and { 1, 1, 1, 1 } or { 1, 0.82, 0, 0.75 })
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
    -- the zone and the clock, per look (a long zone name stops short of the clock, cut with "...")
    s.head:Hide(); s.headLine:Hide(); s.plaque:Hide(); s.stud:Hide(); s.clockBg:Hide()
    s.zone:ClearAllPoints(); s.clock:ClearAllPoints(); s.sub:ClearAllPoints()
    UI:SetTextSize(s.zone, (k == "sigil" or k == "halo") and "caps" or "body")
    s.zone:SetJustifyH((k == "halo" or k == "gilded") and "CENTER" or "LEFT")
    s.sub:SetJustifyH("LEFT")
    local mapW = map:GetWidth() or 140
    if k == "flat" then
        s.head:ClearAllPoints()
        s.head:SetPoint("TOPLEFT", map, "BOTTOMLEFT", -1, -1)
        s.head:SetPoint("TOPRIGHT", map, "BOTTOMRIGHT", 1, -1)
        s.head:SetHeight(20)
        L.Color(s.head, { 0.039, 0.039, 0.051, 0.66 })
        s.clock:SetPoint("RIGHT", s.head, "RIGHT", -6, 0)
        s.zone:SetPoint("LEFT", s.head, "LEFT", 6, 0)
        s.zone:SetPoint("RIGHT", s.clock, "LEFT", -6, 0)
    elseif k == "sigil" then
        s.head:ClearAllPoints()
        s.head:SetPoint("BOTTOMLEFT", map, "TOPLEFT", -1, 2)
        s.head:SetPoint("BOTTOMRIGHT", map, "TOPRIGHT", 1, 2)
        s.head:SetHeight(18)
        L.Gradient(s.head, look.head.bottom, look.head.top)
        s.clock:SetPoint("RIGHT", s.head, "RIGHT", -6, 0)
        s.zone:SetPoint("LEFT", s.head, "LEFT", 6, 0)
        s.zone:SetPoint("RIGHT", s.clock, "LEFT", -6, 0)
    elseif k == "slate" then
        s.clock:SetPoint("TOPRIGHT", map, "TOPRIGHT", -6, -5)
        s.zone:SetPoint("TOPLEFT", map, "TOPLEFT", 6, -5)
        s.zone:SetPoint("RIGHT", s.clock, "LEFT", -6, 0)
        s.sub:SetPoint("TOPLEFT", s.zone, "BOTTOMLEFT", 0, -1)
        s.sub:SetPoint("RIGHT", map, "RIGHT", -6, 0)
    elseif k == "halo" then
        s.zone:SetWidth(mapW + 20)
        s.zone:SetPoint("BOTTOM", map, "TOP", 0, 6)
        s.clock:SetPoint("TOP", map, "BOTTOM", 0, -2)
        s.clockBg:ClearAllPoints()
        s.clockBg:SetPoint("TOPLEFT", s.clock, "TOPLEFT", -8, 2)
        s.clockBg:SetPoint("BOTTOMRIGHT", s.clock, "BOTTOMRIGHT", 8, -2)
        L.Color(s.clockBg, { 0.031, 0.031, 0.043, 0.9 })
    else -- gilded
        s.plaque:ClearAllPoints()
        s.plaque:SetPoint("TOP", map, "BOTTOM", 0, -6)
        s.plaque:SetSize(math.max(100, mapW - 40), 18)
        s.plaque.panel:Apply(look)
        L.Gradient(s.plaque.panel.bg, look.head.bottom, look.head.top)
        s.plaque:Show()
        s.zone:SetWidth(math.max(100, mapW - 40) - 12)
        s.zone:SetPoint("CENTER", s.plaque, "CENTER", 0, 0)
        s.clock:SetPoint("TOP", s.plaque, "BOTTOM", 0, -2)
        s.stud:ClearAllPoints()
        s.stud:SetPoint("CENTER", map, "TOP", 0, 3)
        L.Color(s.stud, look.panel.corners)
    end
    s.knob:ClearAllPoints()
    s.knob:SetPoint("TOPRIGHT", map, "TOPRIGHT", -3, -3)
    s.knob.panel:Apply(look)
    s:Show()
    self:Zone()
    self:Clock()
    self:Buttons()
end

function MM:OnLogin()
    local L = Look()
    L:SetApplied("minimap", L:Key("minimap"))
    self:Apply()
    -- (icons other addons register late, and the button library's own first placing, come after ours)
    if C_Timer and C_Timer.After then
        C_Timer.After(3, function() if Look():IsOn("minimap") and MM.shape == "square" then MM:PlaceIcons() end end)
    end
    for _, e in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
        ns:RegisterEvent(e, function() MM:Zone() end)
    end
    ns:On("UI_LOOK_CHANGED", function(part)
        if part ~= "minimap" then return end
        if Look():IsOn("minimap") then
            MM:Apply()
        else
            MM:Off()
        end
    end)
end

function MM:Knob() return skin and skin.knob end

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
    GiveBack()
    if skin then skin:Hide(); skin.ring:Hide(); skin.ringIn:Hide(); if skin.drawer then skin.drawer:Hide() end end
    MM.shape = "round"
    MM:PlaceIcons(true)
    if map then
        for _, ch in ipairs({ map:GetChildren() }) do
            local n = ch:GetName() or ""
            if n:find("^LibDBIcon") then ch:SetAlpha(1) end
        end
    end
end
