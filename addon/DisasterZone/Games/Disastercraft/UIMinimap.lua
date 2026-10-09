if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIMinimap.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIMinimap.lua
-- CraftUI's minimap: the classic MinimapCluster laid out as Blizzard's Minimap.xml lays it (192 x 192 at the top
-- right: the border's top bar with the zone text and the minimize button, the 140 px round map under it, the round
-- border, the compass's N, the zoom buttons), showing WoW's own minimap tiles (world/minimaps/azeroth/mapX_Y, one
-- 256 px picture per ADT = 128 grid tiles) through the client's round minimap mask; inside a building, that
-- building's own floor picture. On it: you (the arrow), other heroes, quest givers (! and ?), your corpse.
local addonName, ns = ...

local UI = ns.CraftUI
local K = UI.Kit
local Craft = ns.Craft
local Combat = Craft.Combat
local WS = ns.AzeroLand

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt
local TS = 533.33333 / 128                      -- yards a grid tile
local SIZE = 140                                -- the round map, px
local ACROSS_OUT = { 466.67, 400, 333.33, 266.67, 200, 133.33 } -- yards across, outdoors (WoW's zoom levels)
local ADT = 128                                 -- grid tiles an ADT

local cluster, map, mask, tiles, inner, blips, arrow, zoneText, zoomIn, zoomOut, toggle
local zoom = 1

local function MaskedTex(layer, sub)
    local t = map:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    if mask and t.AddMaskTexture then t:AddMaskTexture(mask) end
    return t
end

local function ZoomTo(z)
    zoom = max(1, min(#ACROSS_OUT, z))
    if zoomIn then if zoom >= #ACROSS_OUT then zoomIn:Disable() else zoomIn:Enable() end end
    if zoomOut then if zoom <= 1 then zoomOut:Disable() else zoomOut:Enable() end end
    local d = Craft:Data()
    if d then d.minimapZoom = zoom end
end

local function ZoomButton(name, x, y, step)
    local b = CreateFrame("Button", nil, cluster.backdrop)
    b:SetSize(32, 32)
    b:SetPoint("CENTER", cluster.backdrop, "CENTER", x, y)
    b:SetNormalTexture("Interface\\Minimap\\UI-Minimap-Zoom" .. name .. "Button-Up")
    b:SetPushedTexture("Interface\\Minimap\\UI-Minimap-Zoom" .. name .. "Button-Down")
    b:SetDisabledTexture("Interface\\Minimap\\UI-Minimap-Zoom" .. name .. "Button-Disabled")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    b:SetScript("OnClick", function()
        ZoomTo(zoom + step)
        if PlaySound then pcall(PlaySound, step > 0 and 862 or 863) end      -- IG_MINIMAP_ZOOM_IN / _OUT
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(step > 0 and "Zoom In" or "Zoom Out", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", K.HideTooltip)
    return b
end

function UI.BuildMinimap(hud)
    cluster = CreateFrame("Frame", nil, hud)
    cluster:SetSize(192, 192)
    cluster:SetPoint("TOPRIGHT", hud, "TOPRIGHT", 0, 0)
    cluster:SetFrameLevel(hud:GetFrameLevel() + 6)
    -- the top bar: the zone's name, the minimize button
    local top = cluster:CreateTexture(nil, "ARTWORK")
    top:SetTexture("Interface\\Minimap\\UI-Minimap-Border")
    top:SetSize(176, 28)
    top:SetPoint("TOP")
    top:SetTexCoord(0.3125, 1.0, 0.0, 0.109375)
    cluster.top = top
    local zb = CreateFrame("Button", nil, cluster)
    zb:SetSize(140, 12)
    zb:SetPoint("LEFT", top, "LEFT", 10, 0)
    zoneText = zb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zoneText:SetSize(140, 12)
    zoneText:SetPoint("CENTER", 0, 1)
    zb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local W = Craft.World
        GameTooltip:SetText(W.areaName or "", 0.1, 1, 0.1)
        if W.zoneName and W.zoneName ~= W.areaName then GameTooltip:AddLine(W.zoneName, 1, 1, 1) end
        GameTooltip:AddLine("Friendly Territory", 0.1, 1, 0.1)
        GameTooltip:Show()
    end)
    zb:SetScript("OnLeave", K.HideTooltip)
    toggle = CreateFrame("Button", nil, cluster)
    toggle:SetSize(32, 32)
    toggle:SetPoint("RIGHT", top, "RIGHT", 1, 1)
    toggle:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    toggle:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    toggle:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
    toggle:SetScript("OnClick", function()
        local d = Craft:Data()
        local hidden = not map:IsShown()
        map:SetShown(hidden)
        cluster.backdrop:SetShown(hidden)
        if d then d.minimapHidden = not hidden end
    end)
    -- the round map
    map = CreateFrame("Frame", nil, cluster)
    map:SetSize(SIZE, SIZE)
    map:SetPoint("TOP", top, "BOTTOM", 0, 6)
    map:EnableMouse(true)
    map:EnableMouseWheel(true)
    map:SetScript("OnMouseWheel", function(_, d) ZoomTo(zoom + (d > 0 and 1 or -1)) end)
    if map.CreateMaskTexture then
        local ok, m = pcall(map.CreateMaskTexture, map)
        if ok and m then
            m:SetTexture("Textures\\MinimapMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            m:SetAllPoints(map)
            mask = m
        end
    end
    local bg = MaskedTex("BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetAllPoints(map)
    tiles, inner, blips = {}, {}, {}
    for i = 1, 4 do tiles[i] = MaskedTex("BACKGROUND", 1) end
    -- the border, the N, the zoom buttons (MinimapBackdrop: 192 x 192 round the map)
    local back = CreateFrame("Frame", nil, cluster)
    back:SetSize(192, 192)
    back:SetPoint("CENTER", map, "CENTER")
    back:SetFrameLevel(map:GetFrameLevel() + 3)
    cluster.backdrop = back
    local border = back:CreateTexture(nil, "ARTWORK")
    border:SetTexture("Interface\\Minimap\\UI-Minimap-Border")
    border:SetTexCoord(0.25, 1.0, 0.125, 0.875)
    border:SetPoint("TOPLEFT", back, "TOPLEFT", -8, -24)
    border:SetPoint("BOTTOMRIGHT", back, "BOTTOMRIGHT", -8, -24)
    local north = back:CreateTexture(nil, "OVERLAY")
    north:SetTexture("Interface\\Minimap\\CompassNorthTag")
    north:SetSize(16, 16)
    north:SetPoint("CENTER", map, "CENTER", 0, 67)
    zoomIn = ZoomButton("In", 69, -37, 1)
    zoomOut = ZoomButton("Out", 43, -65, -1)
    -- you, on top of everything on the map
    local over = CreateFrame("Frame", nil, map)
    over:SetAllPoints()
    over:SetFrameLevel(map:GetFrameLevel() + 2)
    map.over = over
    arrow = over:CreateTexture(nil, "OVERLAY", nil, 7)
    arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
    arrow:SetSize(32, 32)
    arrow:SetPoint("CENTER", map, "CENTER")
    local d = Craft:Data()
    ZoomTo(d and d.minimapZoom or 1)
    if d and d.minimapHidden then map:Hide() back:Hide() end
    cluster:SetScript("OnUpdate", function() UI.UpdateMinimap() end)
    UI.Minimap = cluster
    return cluster
end

-- a blip on the map: a small button (its tooltip names it)
local function Blip(i)
    local b = blips[i]
    if b then return b end
    b = CreateFrame("Button", nil, map.over)
    b:SetSize(16, 16)
    b.icon = b:CreateTexture(nil, "OVERLAY")
    b.icon:SetAllPoints()
    b:SetScript("OnEnter", function(self)
        if not self.label then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(self.label, 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", K.HideTooltip)
    blips[i] = b
    return b
end

local function DrawTiles(p, d)
    local gpx = SIZE * TS / d                      -- px a grid tile
    local R = d / 2 / TS + 1
    local n = 0
    local M = ns.CraftMaps
    for ax = floor((p.x - R) / ADT), floor((p.x + R) / ADT) do
        for ay = floor((p.y - R) / ADT), floor((p.y + R) / ADT) do
            local fid = M and M.minimap[ax .. "_" .. ay]
            if fid and n < #tiles then
                n = n + 1
                local t = tiles[n]
                t:SetTexture(fid)
                t:SetSize(ADT * gpx, ADT * gpx)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", map, "CENTER", (ax * ADT - p.x) * gpx, -(ay * ADT - p.y) * gpx)
                t:Show()
            end
        end
    end
    for i = n + 1, #tiles do tiles[i]:Hide() end
    for _, t in ipairs(inner) do t:Hide() end
    return gpx
end

function UI.UpdateMinimap()
    local p = Craft.player
    if not p or not cluster or not map:IsShown() then
        if cluster and zoneText then zoneText:SetText(Craft.World.areaName or "") end
        return
    end
    local W = Craft.World
    zoneText:SetText(W.areaName or W.MapName(p.map, p.x, p.y))
    zoneText:SetTextColor(0.1, 1, 0.1)                 -- (friendly territory: Alliance land)
    local px = DrawTiles(p, ACROSS_OUT[zoom])
    if arrow.SetRotation then arrow:SetRotation(UI.FacingAngle and UI.FacingAngle(p) or 0) end
    -- blips: quest givers, other heroes, your corpse (within the round map)
    local n = 0
    local half = SIZE / 2 - 6
    local function Put(x, y, tex, label, size, coords, clampEdge)
        local dx, dy = (x - p.x) * px, (y - p.y) * px
        local r = sqrt(dx * dx + dy * dy)
        if r > half then
            if not clampEdge then return end
            dx, dy = dx * half / r, dy * half / r
        end
        n = n + 1
        local b = Blip(n)
        b.icon:SetTexture(tex)
        if coords then b.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4]) else b.icon:SetTexCoord(0, 1, 0, 1) end
        b:SetSize(size, size)
        b:ClearAllPoints()
        b:SetPoint("CENTER", map, "CENTER", dx, -dy)
        b.label = label
        b:Show()
    end
    for _, u in pairs(Combat.units) do
        if u ~= p and u.map == p.map and not (u.rec and u.rec.hidden) and not u.dead then
            if u.kind == "npc" and u.entry then
                local mark, grey = Craft.Quests.Marker(u.entry)
                if mark and not grey then
                    Put(u.x, u.y, mark == "!" and "Interface\\GossipFrame\\AvailableQuestIcon"
                        or "Interface\\GossipFrame\\ActiveQuestIcon", u.name, 14)
                end
            elseif Combat.IsPlayer(u) then
                Put(u.x, u.y, "Interface\\WorldMap\\WorldMapPartyIcon", u.name, 12, nil, true)
            end
        end
    end
    local c = Craft.char
    if p.ghost and c and c.corpse and c.corpse.map == p.map then
        Put(c.corpse.x, c.corpse.y, "Interface\\Minimap\\POIIcons", "Your corpse", 20, { 0, 0.125, 0, 0.125 }, true)
    end
    for i = n + 1, #blips do blips[i]:Hide() end
end

-- (built with the HUD, in the top-right corner the HUD leaves free for it)
local BuildHud = UI.BuildHud
function UI.BuildHud(...)
    local hud = BuildHud(...)
    if hud then UI.BuildMinimap(hud) end
    return hud
end
