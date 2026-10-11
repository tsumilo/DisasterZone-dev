if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Comp/MapArt.lua", ...) then return end -- DisasterZone UI/Comp/MapArt.lua
-- map art tiles, shared by the strategy map, event zone map and guild map (refactor phase 2).
local addonName, ns = ...

-- ns.MapArt: a zone's art from the game (C_Map's art layer and its tiles) and its size in yards. One copy of what the
-- strategy board, the events' zone map and map sheet and the guild map each had.
--   MapArt.Layer(mapID)  the map's first art layer { layerWidth, layerHeight, tileWidth, tileHeight, ... } or nil
--   MapArt.Files(mapID)  that layer's tile files (a non-empty list) or nil
--   MapArt.Tiles(pool, parent, layer, files, ox, oy, scale, opts) -> n   lays the tiles out (below)
--   MapArt.Yards(mapID)  the map's width and height in yards (from where its corners are in the world), or nil
local MapArt = {}
ns.MapArt = MapArt

local ceil, sqrt = math.ceil, math.sqrt

function MapArt.Layer(mapID)
    mapID = tonumber(mapID)
    if not mapID or mapID <= 0 or not (C_Map and C_Map.GetMapArtLayers) then return nil end
    local ok, layers = pcall(C_Map.GetMapArtLayers, mapID)
    local L = ok and type(layers) == "table" and layers[1] or nil
    if L and (L.layerWidth or 0) > 0 and (L.tileWidth or 0) > 0 and (L.tileHeight or 0) > 0 then return L end
    return nil
end

function MapArt.Files(mapID)
    mapID = tonumber(mapID)
    if not mapID or not (C_Map and C_Map.GetMapArtLayerTextures) then return nil end
    local ok, files = pcall(C_Map.GetMapArtLayerTextures, mapID, 1)
    if ok and type(files) == "table" and #files > 0 then return files end
    return nil
end

-- Lays a layer's tiles out on parent, row by row: tile (c, r) at (ox + c * tileWidth * scale, oy + r * tileHeight *
-- scale) from parent's top left (oy down). pool = a list of the textures made so far (reused, grown as needed); the
-- caller hides what it doesn't use. Returns how many of pool are in use.
--   opts { n = pool entries already used (the next tile goes after them), layer = { "BACKGROUND", sublevel }
--          (made textures; with setLayer every tile is put back on it), color = { r, g, b[, a] } (a tint),
--          view = { w, h } (only the tiles that show in it), lastRowFile = the last row's file height in px when it
--          holds only what is left of the layer (shown cut to it) }
function MapArt.Tiles(pool, parent, layer, files, ox, oy, scale, opts)
    opts = opts or {}
    local n = opts.n or 0
    local L = layer
    local cols = ceil(L.layerWidth / L.tileWidth)
    local rows = ceil(L.layerHeight / L.tileHeight)
    local tw, th = L.tileWidth * scale, L.tileHeight * scale
    local dl = opts.layer or { "BACKGROUND" }
    local col, view = opts.color, opts.view
    for r = 1, rows do
        for c = 1, cols do
            local file = files[(r - 1) * cols + c]
            local x, y = ox + (c - 1) * tw, oy + (r - 1) * th
            if file and (not view or (x < view[1] and y < view[2] and x + tw > 0 and y + th > 0)) then
                n = n + 1
                local t = pool[n]
                if not t then
                    t = parent:CreateTexture(nil, dl[1], nil, dl[2])
                    pool[n] = t
                end
                if opts.setLayer then t:SetDrawLayer(dl[1], dl[2] or 0) end
                t:ClearAllPoints()
                t:SetTexture(file)
                if opts.lastRowFile and r == rows and rows > 1 then
                    local left = L.layerHeight - L.tileHeight * (rows - 1)
                    t:SetTexCoord(0, 1, 0, left / opts.lastRowFile)
                    t:SetSize(tw, left * scale)
                else
                    t:SetTexCoord(0, 1, 0, 1)
                    t:SetSize(tw, th)
                end
                t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
                if col then t:SetVertexColor(col[1], col[2], col[3], col[4] or 1) end
                t:Show()
            end
        end
    end
    return n
end

-- The map's width and height in yards (height nil where only the width is known); nil where the game doesn't say.
local yardCache = {}
function MapArt.Yards(mapID)
    local map = tonumber(mapID)
    if not map then return nil end
    local hit = yardCache[map]
    if hit then return hit[1], hit[2] end
    local function world(x, y)
        local Sn = ns.EventSensors
        if Sn and Sn.World then return Sn.World(map, x, y) end
        if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
        local ok, cont, v = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
        if not ok or not cont or type(v) ~= "table" or not v.GetXY then return nil end
        local wx, wy = v:GetXY()
        return cont, wx, wy
    end
    local c0, x0, y0 = world(0, 0)
    local c1, x1, y1 = world(1, 0)
    if not (c0 and c1) or c0 ~= c1 then return nil end
    local w = sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))
    if w <= 1 then return nil end
    local h
    local c2, x2, y2 = world(0, 1)
    if c2 and c2 == c0 then
        h = sqrt((x2 - x0) * (x2 - x0) + (y2 - y0) * (y2 - y0))
        if h <= 1 then h = nil end
    end
    if h then yardCache[map] = { w, h } end          -- (a half answer is asked again next time)
    return w, h
end
