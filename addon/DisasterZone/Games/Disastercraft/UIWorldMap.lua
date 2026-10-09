if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIWorldMap.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIWorldMap.lua
-- CraftUI's world map (M): the classic WorldMapFrame - the 1024 x 768 border (UI-WorldMap-Top/Middle/Bottom 1-4)
-- over a blacked-out screen, the zone's own art in its 1002 x 668 detail frame at (11, -70), the areas you have
-- explored drawn over it (WorldMapOverlay: unexplored areas stay the bare base art, as in WoW), you as the arrow,
-- other heroes as party dots. Right-click zooms out to Eastern Kingdoms, left-click goes back to your zone.
-- All of it is the client's own art by FileDataID (MapData.lua, gen_dc_maps.py).
local addonName, ns = ...

local UI = ns.CraftUI
local K = UI.Kit
local Craft = ns.Craft
local Combat = Craft.Combat
local W = ns.AzeroWorldData

local floor, max, min, atan2 = math.floor, math.max, math.min, math.atan2
local DETAIL_W, DETAIL_H = 1002, 668
local ZONE_MAP = 1429                      -- Elwynn Forest (Northshire is part of its map)

local frame, box, detail, title, zoneText, zoomOut
local art, overlays, dots = {}, {}, {}
local arrow
local shown                                -- the uiMapID on show

-- a hero's place on the world grid (buildings are walked in place: inside one too)
function UI.MapPoint(u)
    if not u then return nil end
    return u.x, u.y
end

-- the way you face, as a map rotation (0 = north, counter-clockwise): the last way you moved
function UI.FacingAngle(u)
    local inp = Craft.World.input
    if u == Craft.player and inp and ((inp.dx or 0) ~= 0 or (inp.dy or 0) ~= 0) then
        UI.lastAngle = atan2(-(inp.dx or 0), -(inp.dy or 0))
        return UI.lastAngle
    end
    if u == Craft.player and UI.lastAngle then return UI.lastAngle end
    local f = u.face
    return (f == "left" and math.pi / 2) or (f == "right" and -math.pi / 2) or (f == "down" and math.pi) or 0
end

local function Tex(parent, layer, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    return t
end

local function Build()
    frame = CreateFrame("Frame", nil, UI.hudFrame)
    frame:SetAllPoints(UI.hudFrame)
    frame:EnableMouse(true)
    frame:Hide()
    local black = Tex(frame, "BACKGROUND")
    black:SetAllPoints()
    black:SetColorTexture(0, 0, 0, 1)
    box = CreateFrame("Frame", nil, frame)
    box:SetSize(1024, 768)
    box:SetPoint("CENTER")
    local names = { "Top", "Middle", "Bottom" }
    for r = 1, 3 do
        for c = 1, 4 do
            local t = Tex(box, "ARTWORK")
            t:SetTexture("Interface\\WorldMap\\UI-WorldMap-" .. names[r] .. c)
            t:SetSize(256, 256)
            t:SetPoint("TOPLEFT", (c - 1) * 256, -(r - 1) * 256)
        end
    end
    title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("CENTER", box, "CENTER", 0, 372)
    title:SetText(WORLD_MAP or "World Map")
    zoneText = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    zoneText:SetPoint("TOP", box, "TOP", 0, -42)
    -- the zone's map
    detail = CreateFrame("Frame", nil, box)
    detail:SetSize(DETAIL_W, DETAIL_H)
    detail:SetPoint("TOPLEFT", 11, -70)
    pcall(detail.SetClipsChildren, detail, true)
    detail:EnableMouse(true)
    detail:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then UI.ShowMap(1415) else UI.ShowMap(ZONE_MAP) end
    end)
    for i = 1, 12 do
        art[i] = Tex(detail, "BACKGROUND")
        art[i]:SetSize(256, 256)
    end
    arrow = Tex(detail, "OVERLAY", 7)
    arrow:SetTexture("Interface\\WorldMap\\WorldMapArrow")
    arrow:SetSize(28, 28)
    -- buttons: zoom out (the classic one, by the dropdowns) and close
    zoomOut = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    zoomOut:SetSize(110, 22)
    zoomOut:SetPoint("TOPRIGHT", box, "TOPRIGHT", -18, -36)
    zoomOut:SetText(ZOOM_OUT or "Zoom Out")
    zoomOut:SetScript("OnClick", function() UI.ShowMap(1415) end)
    local close = CreateFrame("Button", nil, box, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", box, "TOPRIGHT", 3, 3)
    close:SetScript("OnClick", function() UI.CloseWindow(frame) end)
    frame:SetScript("OnUpdate", function() UI.UpdateWorldMap() end)
end

-- the map's art and the explored areas over it
function UI.ShowMap(id)
    local M = ns.CraftMaps
    local m = M and M.maps[id]
    if not m or not frame then return end
    shown = id
    for i = 1, 12 do
        local fid = m.art[i]
        local t = art[i]
        if fid then
            local r, c = floor((i - 1) / m.cols), (i - 1) % m.cols
            t:SetTexture(fid)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", detail, "TOPLEFT", c * 256, -r * 256)
            t:Show()
        else
            t:Hide()
        end
    end
    for _, t in ipairs(overlays) do t:Hide() end
    local n = 0
    local explored = Craft.char and Craft.char.explored or {}
    for _, o in ipairs(m.overlays or {}) do
        local seen = false
        for _, a in ipairs(o.areas) do if explored[a] then seen = true end end
        if seen then
            for k, fid in ipairs(o.fids) do
                local c, r = (k - 1) % o.cols, floor((k - 1) / o.cols)
                local w, h = min(256, o.w - c * 256), min(256, o.h - r * 256)
                if w > 0 and h > 0 then
                    n = n + 1
                    local t = overlays[n]
                    if not t then t = Tex(detail, "ARTWORK") overlays[n] = t end
                    t:SetTexture(fid)
                    t:SetTexCoord(0, w / 256, 0, h / 256)
                    t:SetSize(w, h)
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", detail, "TOPLEFT", o.x + c * 256, -(o.y + r * 256))
                    t:Show()
                end
            end
        end
    end
    zoneText:SetText(m.name)
    -- (as in WoW: the continent is as far out as it goes; click the map to go back in)
    if id == 1415 then zoomOut:Disable() else zoomOut:Enable() end
    UI.UpdateWorldMap()
end

local function Place(t, u, m)
    local gx, gy = UI.MapPoint(u)
    if not gx then t:Hide() return end
    local x, y = (m.au * gx + m.bu) * DETAIL_W, (m.av * gy + m.bv) * DETAIL_H
    if x < 0 or y < 0 or x > DETAIL_W or y > DETAIL_H then t:Hide() return end
    t:ClearAllPoints()
    t:SetPoint("CENTER", detail, "TOPLEFT", x, -y)
    t:Show()
end

function UI.UpdateWorldMap()
    if not frame or not frame:IsShown() then return end
    local M = ns.CraftMaps
    local m = M and M.maps[shown]
    local p = Craft.player
    if not m or not p then return end
    -- (the frame fits the game panel; it never grows past the client's own size)
    local W, H = UI.PanelSize()
    if W > 0 and H > 0 then box:SetScale(min(1, (W - 8) / 1024, (H - 8) / 768)) end
    Place(arrow, p, m)
    if arrow.SetRotation then arrow:SetRotation(UI.FacingAngle(p)) end
    local n = 0
    for _, u in pairs(Combat.units) do
        if u ~= p and Combat.IsPlayer(u) then
            n = n + 1
            local t = dots[n]
            if not t then
                t = Tex(detail, "OVERLAY", 5)
                t:SetTexture("Interface\\WorldMap\\WorldMapPartyIcon")
                t:SetSize(16, 16)
                dots[n] = t
            end
            Place(t, u, m)
        end
    end
    for i = n + 1, #dots do dots[i]:Hide() end
end

function UI.ToggleWorldMap()
    if not frame then Build() end
    if frame:IsShown() then UI.CloseWindow(frame) return end
    UI.ShowWindow("worldmap", frame, "free")
    frame:ClearAllPoints()
    frame:SetAllPoints(UI.hudFrame)
    UI.ShowMap(ZONE_MAP)
    if PlaySound then pcall(PlaySound, 851) end              -- (IG_QUEST_LOG_OPEN: the map's open sound)
end

-- a newly explored area shows on an open map at once
Craft:On("explored", function() if frame and frame:IsShown() then UI.ShowMap(shown) end end)
