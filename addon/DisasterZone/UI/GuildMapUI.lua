if DisasterZoneBoot and DisasterZoneBoot.Run("UI/GuildMapUI.lua", ...) then return end -- DisasterZone: Guild > Map.
-- Guildmates who share (Core/GuildMap.lua) on the game's own map art: continent tabs with how many are on each, the
-- art filling the room left of the list (never under it) with the people on it, and on the right the same people by
-- zone. Like the game's map, hovering a region lights it and names it, a click opens it, a right-click goes back. Pins:
-- a class-colour dot; me as the game's arrow in a gold halo; a ring on the zone's middle for zone only; a crowd as a
-- ring of class dots with the count (click: into that zone); a dungeon or raid at its entrance with a skull, a gold
-- count and its name; away members faded. In a zone the names stand by the dots and the list goes by subzone.
-- Not sharing: a card asks first (only sharers see each other). The eye picks how I share, ··· the world map dots.
-- The game's world map (M) gets the same dots (GuildMapUI.WorldMap below; settings.map.blizzard).
local addonName, ns = ...

local GuildMapUI = ns:NewModule("GuildMapUI")

local floor, min, max, sqrt, cos, sin, pi, abs = math.floor, math.min, math.max, math.sqrt, math.cos, math.sin, math.pi,
    math.abs
local type, pairs, ipairs, tostring = type, pairs, ipairs, tostring

local TOP = 34                 -- the continent tabs' row
local SIDE_W = 200             -- the list on the right (the art stops at its edge)
local GLIDE = 2.0               -- s a guildmate's dot takes to glide to where they were last heard (about the stream's
                               -- rate, so a walker moves steadily instead of hopping)
local CLUSTER_PX = 16          -- dots closer than this on a continent are one crowd
local CROWD_PX = 28            -- a crowd and anything closer than this are one crowd
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local ARROW = "Interface\\Minimap\\MinimapArrow"
local SKULL = "Interface\\WorldMap\\Skull_64"
local GOLD = { 1, 0.82, 0 }

local panel
local state = { cont = 1945, zone = nil, hot = nil }
local GM = function() return ns.GuildMap end

local function UI() return ns.UI end

local function Text(parent, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", "GameFontHighlightSmall")
    if size then
        local path, _, flags = fs:GetFont()
        fs:SetFont(path or STANDARD_TEXT_FONT, size, flags or "")
    end
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    return fs
end

local function Disc(parent, layer, size, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(DISC)
    t:SetSize(size, size)
    t:SetVertexColor(r, g, b, a or 1)
    return t
end

local function Gradient(tex, orient, r, g, b, a1, a2)
    if tex.SetGradient and CreateColor then
        tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2))
    else
        tex:SetColorTexture(r, g, b, (a1 + a2) / 2)
    end
end

local function ClassOf(key)
    local G = ns.Guild
    local c = G and G:GetClass(key)
    if not c and ns.Util.IsMe(key) and UnitClass then c = select(2, UnitClass("player")) end
    if not c and ns.GuildMap then c = ns.GuildMap:GetDemoClass(key) end
    return c
end

local function ColoredName(key) return UI():ColoredName(key, ClassOf(key)) end

-- "Fire Mage · 70" (the spec from their My BiS / talents when shared, else the class).
local function WhoLine(key)
    local cls = ClassOf(key)
    local className = cls and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls] or (cls and cls:sub(1, 1) .. cls:sub(2):lower()) or ""
    local spec
    local P = ns.Professions
    local s = P and P.GetSpecs and P:GetSpecs(key)
    local main = s and s[1]
    local list = cls and ns.SPECS and ns.SPECS[cls]
    if main and list then
        local sp = main.sp and list[main.sp]
        if not sp then
            for _, x in ipairs(list) do if x.tab == main.tab then sp = x break end end
        end
        spec = sp and sp.label
    end
    local m = ns.Guild and ns.Guild:GetMember(key)
    local level = m and tonumber(m.level)
    if not level and ns.Util.IsMe(key) and UnitLevel then level = UnitLevel("player") end
    local who = spec and (spec .. " " .. className) or className
    return level and (who .. " · " .. level) or who
end

local function Ago(at)
    local s = max(0, floor(GetTime() - (at or GetTime())))
    if s < 60 then return s .. " s ago" end
    return floor(s / 60) .. " min ago"
end

-- An entry's place in words: "Halaa, Nagrand" / "In Shadow Labyrinth" / "Somewhere in Nagrand".
local function PlaceText(e)
    if e.i then return "In " .. (e.n or "an instance") end
    local zone = GM():GetMapName(e.m) or "?"
    if e.z then return "Somewhere in " .. zone end
    if e.s then return e.s .. ", " .. zone end
    return zone
end

local function ZoneKey(e)
    if e.i then return "i" .. e.i end
    return "m" .. tostring(e.m)
end

---------------------------------------------------------------------------
-- The art
---------------------------------------------------------------------------

-- Fills view `v` (a frame) with map `map`'s art; v.place(x, y) -> pixels from its top left. Returns true if drawn.
local function DrawArt(v, map, W, H)
    v.tiles = v.tiles or {}
    for _, t in ipairs(v.tiles) do t:Hide() end
    local L, files
    if C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures then
        local ok, layers = pcall(C_Map.GetMapArtLayers, map)
        L = ok and type(layers) == "table" and layers[1] or nil
        if L then
            local ok2, f = pcall(C_Map.GetMapArtLayerTextures, map, 1)
            files = ok2 and type(f) == "table" and f or nil
        end
    end
    local LW, LH = (L and L.layerWidth) or 1002, (L and L.layerHeight) or 668
    local TW, TH = (L and L.tileWidth) or 256, (L and L.tileHeight) or 256
    -- the whole map fits (nothing at its edges cut off); the room above / below it shows the same art larger and
    -- dimmed behind it, so there are no empty bars
    local s = min(W / LW, H / LH)
    local x0, y0 = (W - LW * s) / 2, (H - LH * s) / 2
    local bs = max(W / LW, H / LH) * 1.08
    local bx0, by0 = (W - LW * bs) / 2, (H - LH * bs) / 2
    v.place = function(x, y) return x0 + x * LW * s, y0 + y * LH * s end
    v.toMap = function(px, py) return (px - x0) / (LW * s), (py - y0) / (LH * s) end
    v.artW, v.artH, v.x0, v.y0 = LW * s, LH * s, x0, y0
    if not files or #files == 0 then return false end
    local cols = math.ceil(LW / TW)
    v.back = v.back or {}
    for _, t in ipairs(v.back) do t:Hide() end
    for i, file in ipairs(files) do
        local c, r = (i - 1) % cols, floor((i - 1) / cols)
        local b = v.back[i]
        if not b then
            b = v:CreateTexture(nil, "BACKGROUND", nil, -2)
            v.back[i] = b
        end
        b:SetTexture(file)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", v, "TOPLEFT", bx0 + c * TW * bs, -(by0 + r * TH * bs))
        b:SetSize(TW * bs, TH * bs)
        b:SetVertexColor(0.24, 0.23, 0.22)
        b:Show()
    end
    -- (the fitted art's top and bottom edges fade into the dimmed copy)
    v.edgeT = v.edgeT or v:CreateTexture(nil, "BACKGROUND", nil, 3)
    v.edgeB = v.edgeB or v:CreateTexture(nil, "BACKGROUND", nil, 3)
    for i, e in ipairs({ v.edgeT, v.edgeB }) do
        e:SetTexture("Interface\\Buttons\\WHITE8X8")
        e:ClearAllPoints()
        e:SetHeight(14)
        e:SetWidth(LW * s)
        if i == 1 then
            e:SetPoint("TOPLEFT", v, "TOPLEFT", x0, -y0)
            Gradient(e, "VERTICAL", 0, 0, 0, 0, 0.55)
        else
            e:SetPoint("BOTTOMLEFT", v, "TOPLEFT", x0, -(y0 + LH * s))
            Gradient(e, "VERTICAL", 0, 0, 0, 0.55, 0)
        end
        e:SetShown(y0 > 1)
    end
    for i, file in ipairs(files) do
        local t = v.tiles[i]
        if not t then
            t = v:CreateTexture(nil, "BACKGROUND")
            v.tiles[i] = t
        end
        local c, r = (i - 1) % cols, floor((i - 1) / cols)
        t:SetTexture(file)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", v, "TOPLEFT", x0 + c * TW * s, -(y0 + r * TH * s))
        t:SetSize(TW * s, TH * s)
        t:SetVertexColor(0.9, 0.88, 0.84)
        t:Show()
    end
    -- every explored area on top, as if I had been everywhere (the base art alone is the unexplored map), laid out
    -- like Blizzard's MapExplorationDataProvider: 256px tiles row by row, the last row / column cut to the area
    v.over = v.over or {}
    for _, t in ipairs(v.over) do t:Hide() end
    local n = 0
    local list = ns.Data and ns.Data.MapOverlays and ns.Data.MapOverlays[map]
    for _, spec in ipairs(list or {}) do
        local w, h, ox, oy, ids = spec:match("^(%d+):(%d+):(%d+):(%d+):(.+)$")
        w, h, ox, oy = tonumber(w), tonumber(h), tonumber(ox), tonumber(oy)
        if w and ids then
            local files = {}
            for id in ids:gmatch("%d+") do files[#files + 1] = tonumber(id) end
            local wide, tall = math.ceil(w / TW), math.ceil(h / TH)
            for j = 1, tall do
                local ph, fh = TH, TH
                if j == tall then
                    ph = h % TH
                    if ph == 0 then ph = TH end
                    fh = 16
                    while fh < ph do fh = fh * 2 end
                end
                for k = 1, wide do
                    local file = files[(j - 1) * wide + k]
                    if file then
                        local pw, fw = TW, TW
                        if k == wide then
                            pw = w % TW
                            if pw == 0 then pw = TW end
                            fw = 16
                            while fw < pw do fw = fw * 2 end
                        end
                        n = n + 1
                        local t = v.over[n]
                        if not t then
                            t = v:CreateTexture(nil, "BACKGROUND", nil, 1)
                            v.over[n] = t
                        end
                        t:SetTexture(file)
                        t:SetTexCoord(0, pw / fw, 0, ph / fh)
                        t:ClearAllPoints()
                        t:SetPoint("TOPLEFT", v, "TOPLEFT", x0 + (ox + TW * (k - 1)) * s, -(y0 + (oy + TH * (j - 1)) * s))
                        t:SetSize(pw * s, ph * s)
                        t:SetVertexColor(0.9, 0.88, 0.84)
                        t:Show()
                    end
                end
            end
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Pins
---------------------------------------------------------------------------

local function PinTooltip(pin)
    local d = pin.data
    if not d then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    if d.kind == "crowd" or d.kind == "dungeon" then
        GameTooltip:AddLine(d.title or "")
        for _, key in ipairs(d.keys) do GameTooltip:AddLine(ColoredName(key)) end
        if d.kind == "crowd" and d.zoom then GameTooltip:AddLine("Click to zoom in", 0.6, 0.6, 0.62) end
    else
        local e = d.e
        GameTooltip:AddLine(ns.Util.IsMe(d.key) and "|cffffd100You|r" or ColoredName(d.key))
        GameTooltip:AddLine(WhoLine(d.key), 0.62, 0.62, 0.64)
        GameTooltip:AddLine(PlaceText(e), 1, 1, 1)
        if e.a then GameTooltip:AddLine("Away", 1, 0.8, 0.1) end
        if not e.me then
            GameTooltip:AddLine("Updated " .. Ago(e.at), 0.62, 0.62, 0.64)
            GameTooltip:AddLine("Click for their profile", 0.62, 0.62, 0.64)
            GameTooltip:AddLine("Right-click to whisper or invite", 0.62, 0.62, 0.64)
        end
    end
    GameTooltip:Show()
end

local function OpenProfile(key)
    if ns.MainFrame then ns.MainFrame:Open("members") end
    if ns.MembersUI and ns.MembersUI.ShowMember then ns.MembersUI:ShowMember(key) end
end

local function PersonMenu(pin, key)
    UI():ContextMenu(pin, function(root)
        root:CreateTitle(ns.Util.ShortName(key))
        root:CreateButton(UI():AtlasIconText(UI().ICON.whisper, 13) .. " Whisper", function()
            if ChatFrame_SendTell then ChatFrame_SendTell(Ambiguate and Ambiguate(key, "none") or key) end
        end)
        root:CreateButton(UI():AtlasIconText(19, 13) .. " Invite", function()
            local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
            if invite then invite(Ambiguate and Ambiguate(key, "none") or key) end
        end)
        root:CreateButton(UI():AtlasIconText(UI().ICON.team, 13) .. " Profile", function() OpenProfile(key) end)
    end)
end

-- A ring drawn as small discs packed along a circle (no rotated textures: the same in every client): n discs of
-- `size` px at radius r around the pin's centre. Overlapping, they read as one smooth band; spaced, as a dotted ring.
local function Ring(b, key, n, size, r, layer, sub)
    b.rings = b.rings or {}
    local ring = b.rings[key]
    if ring then return ring end
    ring = {}
    for i = 1, n do
        local t = Disc(b, layer, size, 1, 1, 1, 1, sub)
        local a = (i - 0.5) / n * 2 * pi - pi / 2
        t:SetPoint("CENTER", b, "CENTER", cos(a) * r, -sin(a) * r)
        t:Hide()
        ring[i] = t
    end
    b.rings[key] = ring
    return ring
end

local function ShowRing(ring, on)
    for _, t in ipairs(ring) do t:SetShown(on) end
end

-- Colours a ring by the class mix of `keys` (sorted by class, a share each; one dark disc between two classes).
local function PaintClassRing(ring, keys)
    local list = {}
    for _, key in ipairs(keys) do list[#list + 1] = ClassOf(key) or "" end
    table.sort(list)
    local n = #ring
    local prev
    for i, t in ipairs(ring) do
        local cls = list[min(#list, floor((i - 1) / n * #list) + 1)]
        if prev and cls ~= prev and #list > 1 then
            t:SetVertexColor(0.04, 0.04, 0.05, 0.95)
        else
            t:SetVertexColor(UI():ClassColor(cls ~= "" and cls or nil))
        end
        prev = cls
        t:Show()
    end
end

local function NewPin(v)
    local b = CreateFrame("Button", nil, v)
    b:SetSize(16, 16)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- every pin: a soft shadow under it
    b.shadow = Disc(b, "BACKGROUND", 18, 0, 0, 0, 0.5)
    b.shadow:SetPoint("CENTER", 0, -1)
    b.glow = Disc(b, "BACKGROUND", 28, 1, 1, 1, 0.4, 1)
    b.glow:SetPoint("CENTER")
    -- a dot: dark edge, class fill, a shine up left
    b.edge = Disc(b, "ARTWORK", 14, 0.03, 0.03, 0.04, 0.95, 1)
    b.edge:SetPoint("CENTER")
    b.fill = Disc(b, "ARTWORK", 11, 1, 1, 1, 1, 2)
    b.fill:SetPoint("CENTER")
    b.sheen = Disc(b, "ARTWORK", 6, 1, 1, 1, 0.28, 3)
    b.sheen:SetPoint("CENTER", -1.5, 1.5)
    b.shine = Disc(b, "ARTWORK", 3, 1, 1, 1, 0.7, 4)
    b.shine:SetPoint("CENTER", -1.8, 1.8)
    -- a crowd / dungeon: dark edge, a band in the class mix, a dark middle with the count or a skull, a gold badge
    b.outer = Disc(b, "ARTWORK", 32, 0.02, 0.02, 0.03, 0.9, 0)
    b.outer:SetPoint("CENTER")
    b.mid = Disc(b, "ARTWORK", 21, 0.05, 0.05, 0.06, 0.96, 5)
    b.mid:SetPoint("CENTER")
    b.count = Text(b, 12.5)
    b.count:SetPoint("CENTER", 0.5, 0)
    b.skull = b:CreateTexture(nil, "OVERLAY")
    b.skull:SetTexture(SKULL)
    b.skull:SetTexCoord(0, 0.5, 0, 0.5)
    b.skull:SetSize(16, 16)
    b.skull:SetPoint("CENTER")
    -- (the badge on a frame of its own, so its number sits over the band and the skull)
    b.badgeFrame = CreateFrame("Frame", nil, b)
    b.badgeFrame:SetSize(18, 18)
    b.badgeFrame:SetPoint("CENTER", b, "TOPRIGHT", -0.5, -1.5)
    b.badgeEdge = Disc(b.badgeFrame, "ARTWORK", 18, 0.04, 0.04, 0.05, 0.95)
    b.badgeEdge:SetPoint("CENTER")
    b.badge = Disc(b.badgeFrame, "ARTWORK", 15, GOLD[1], GOLD[2], GOLD[3], 1, 1)
    b.badge:SetPoint("CENTER")
    b.badgeText = Text(b.badgeFrame, 10)
    b.badgeText:SetTextColor(0.08, 0.08, 0.08)
    b.badgeText:SetShadowColor(0, 0, 0, 0)
    b.badgeText:SetPoint("CENTER", 0.5, 0)
    b.under = Text(b, 10.5)
    b.under:SetTextColor(0.94, 0.9, 0.78)
    b.under:SetPoint("TOP", b, "BOTTOM", 0, -2)
    -- me: the game's arrow in a thin gold ring, a fainter one around it
    b.halo = Disc(b, "BACKGROUND", 30, GOLD[1], GOLD[2], GOLD[3], 0.1, 2)
    b.halo:SetPoint("CENTER")
    b.arrow = b:CreateTexture(nil, "OVERLAY")
    b.arrow:SetTexture(ARROW)
    b.arrow:SetSize(24, 24)
    b.arrow:SetPoint("CENTER")
    -- a name by the dot (in a zone)
    b.label = Text(b, 11.5)
    b:SetScript("OnEnter", function(self)
        PinTooltip(self)
        local d = self.data
        if d and d.zoneKey ~= state.hot then
            state.hot = d.zoneKey
            GuildMapUI:PaintList()
        end
        if d and d.kind == "dot" and not self.big then
            self.big = true
            self:Paint()
        end
    end)
    b:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if state.hot then
            state.hot = nil
            GuildMapUI:PaintList()
        end
        if self.big then
            self.big = false
            self:Paint()
        end
    end)
    b:SetScript("OnClick", function(self, button)
        local d = self.data
        if not d then return end
        if d.kind == "crowd" or d.kind == "dungeon" then
            if d.zoom then GuildMapUI:ShowZone(d.zoom) end
        elseif not ns.Util.IsMe(d.key) then
            if button == "RightButton" then PersonMenu(self, d.key) else OpenProfile(d.key) end
        end
    end)
    function b:Paint()
        local d = self.data
        local kind = d.kind
        local isMe = kind == "me"
        local dot = kind == "dot" and not d.e.z
        local zoneRing = kind == "dot" and d.e.z
        local crowd = kind == "crowd" or kind == "dungeon"
        local r, g, bl = 1, 1, 1
        if d.key then r, g, bl = UI():ClassColor(ClassOf(d.key)) end
        -- a dot
        self.edge:SetShown(dot)
        self.fill:SetShown(dot)
        self.sheen:SetShown(dot)
        self.shine:SetShown(dot)
        self.glow:SetShown(dot and self.big or false)
        if dot then
            local big = self.big
            self.edge:SetSize(big and 19 or 14, big and 19 or 14)
            self.edge:SetVertexColor(big and 1 or 0.03, big and 1 or 0.03, big and 1 or 0.04, 0.95)
            self.fill:SetSize(big and 15 or 11, big and 15 or 11)
            self.fill:SetVertexColor(r, g, bl, 1)
            self.glow:SetVertexColor(r, g, bl, 0.45)
        end
        -- zone only: a dotted ring in the class colour around a see-through dark middle
        local dots = Ring(self, "dotted", 11, 2.6, 6.3, "ARTWORK", 3)
        ShowRing(dots, zoneRing)
        if zoneRing then
            for _, t in ipairs(dots) do t:SetVertexColor(r, g, bl, 1) end
            self.edge:Show()
            self.edge:SetSize(17, 17)
            self.edge:SetVertexColor(0.03, 0.03, 0.04, 0.45)
        end
        -- a crowd / a dungeon
        local band = Ring(self, "band", 46, 5, 12.6, "ARTWORK", 2)
        ShowRing(band, false)
        self.outer:SetShown(crowd)
        self.mid:SetShown(crowd)
        self.count:SetShown(kind == "crowd")
        if crowd then
            PaintClassRing(band, d.keys)
            self.count:SetText(#d.keys)
        end
        self.skull:SetShown(kind == "dungeon")
        self.badgeFrame:SetShown(kind == "dungeon")
        self.under:SetShown(kind == "dungeon" and d.showName ~= false)
        if kind == "dungeon" then
            self.badgeText:SetText(#d.keys)
            self.under:SetText(d.title or "")
        end
        -- me
        local stroke = Ring(self, "me", 56, 2, 14.5, "ARTWORK", 1)
        local faint = Ring(self, "me2", 72, 1.6, 23, "BACKGROUND", 3)
        ShowRing(stroke, isMe)
        ShowRing(faint, isMe)
        if isMe then
            for _, t in ipairs(stroke) do t:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.9) end
            for _, t in ipairs(faint) do t:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.3) end
        end
        self.halo:SetShown(isMe)
        self.arrow:SetShown(isMe)
        if isMe and self.arrow.SetRotation then
            self.arrow:SetRotation(GetPlayerFacing and GetPlayerFacing() or 0)
        end
        self.shadow:SetShown(not isMe)
        self.shadow:SetSize(crowd and 36 or (zoneRing and 19 or 18), crowd and 36 or (zoneRing and 19 or 18))
        self:SetSize(crowd and 32 or (isMe and 30 or 18), crowd and 32 or (isMe and 30 or 18))
        self:SetAlpha((d.e and d.e.a) and 0.5 or 1)
        self:SetFrameLevel(self:GetParent():GetFrameLevel() + (isMe and 8 or (crowd and 6 or (self.big and 7 or 4))))
        -- the name by the dot (zone view), left of it when the dot is in the view's right part
        self.label:SetShown(d.label ~= nil)
        if d.label then
            self.label:SetText(d.label)
            self.label:SetTextColor(r, g, bl)
            self.label:ClearAllPoints()
            if d.labelLeft then self.label:SetPoint("RIGHT", self, "LEFT", 0, 0)
            else self.label:SetPoint("LEFT", self, "RIGHT", 0, 0) end
        end
    end
    return b
end

---------------------------------------------------------------------------
-- The list on the right
---------------------------------------------------------------------------

local function ListRow(p, i)
    local r = p.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, p.listChild)
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    r.bar:SetWidth(2)
    r.bar:SetPoint("TOPLEFT", 0, -7)
    r.bar:SetPoint("BOTTOMLEFT", 0, 8)
    r.line = r:CreateTexture(nil, "ARTWORK")
    r.line:SetColorTexture(1, 1, 1, 0.06)
    r.line:SetHeight(1)
    r.line:SetPoint("TOPLEFT", 10, 0)
    r.line:SetPoint("TOPRIGHT", 0, 0)
    r.icon = r:CreateTexture(nil, "OVERLAY")
    r.icon:SetTexture(SKULL)
    r.icon:SetTexCoord(0, 0.5, 0, 0.5)
    r.icon:SetSize(13, 13)
    r.icon:SetPoint("TOPLEFT", 10, -7)
    r.name = Text(r, 12)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.count = Text(r, 11)
    r.count:SetTextColor(0.54, 0.54, 0.56)
    r.count:SetPoint("TOPRIGHT", 0, -7)
    r.sub = Text(r, 10)
    r.sub:SetTextColor(0.49, 0.49, 0.51)
    r.sub:SetJustifyH("LEFT")
    r.people = Text(r, 11)
    r.people:SetJustifyH("LEFT")
    r.people:SetJustifyV("TOP")
    r.people:SetWordWrap(true)
    r.people:SetSpacing(2)
    r:SetScript("OnClick", function(self)
        if self.zoom then GuildMapUI:ShowZone(self.zoom) end
    end)
    p.rows[i] = r
    return r
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

-- The art's room: the view less the list.
local function ViewSize(p)
    local W, H = p.view:GetWidth() or 0, p.view:GetHeight() or 0
    if W < 100 then W = 790 end
    if H < 100 then H = 516 end   -- (the page is about 790 x 550 under the nav strip)
    return W - SIDE_W, H
end

local function OptionRow(card, mode, title, desc, y)
    local r = CreateFrame("Button", nil, card)
    r:SetHeight(44)
    r:SetPoint("TOPLEFT", 22, -y)
    r:SetPoint("TOPRIGHT", -22, -y)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    UI():AddEdges(r, "BORDER")
    r.dot = Disc(r, "ARTWORK", 13, 0.47, 0.47, 0.5, 1)
    r.dot:SetPoint("LEFT", 12, 0)
    r.dotIn = Disc(r, "ARTWORK", 10, 0.1, 0.1, 0.11, 1, 1)
    r.dotIn:SetPoint("CENTER", r.dot)
    r.pick = Disc(r, "ARTWORK", 6, GOLD[1], GOLD[2], GOLD[3], 1, 2)
    r.pick:SetPoint("CENTER", r.dot)
    r.title = Text(r, 12.5)
    r.title:SetPoint("TOPLEFT", 36, -8)
    r.title:SetText(title)
    r.desc = Text(r, 10.5)
    r.desc:SetTextColor(0.57, 0.57, 0.59)
    r.desc:SetPoint("TOPLEFT", 36, -25)
    r.desc:SetText(desc)
    r.mode = mode
    r:SetScript("OnClick", function()
        card.choice = mode
        GuildMapUI:PaintCard()
    end)
    return r
end

local function CreateCard(p)
    local veil = CreateFrame("Frame", nil, p.view)
    veil:SetAllPoints()
    veil:SetFrameLevel(p.view:GetFrameLevel() + 30)
    veil:EnableMouse(true)
    veil.bg = veil:CreateTexture(nil, "BACKGROUND")
    veil.bg:SetAllPoints()
    veil.bg:SetColorTexture(0.04, 0.04, 0.05, 0.72)
    local card = CreateFrame("Frame", nil, veil)
    card:SetSize(400, 262)
    card:SetPoint("CENTER")
    card.bg = card:CreateTexture(nil, "BACKGROUND")
    card.bg:SetAllPoints()
    card.bg:SetColorTexture(0.063, 0.063, 0.075, 0.98)
    UI():AddEdges(card, "BORDER")
    UI():SetEdgeColor(card, 0.34, 0.34, 0.38, 0.9)
    card.kick = Text(card, 9.5)
    card.kick:SetTextColor(0.75, 0.65, 0.29)
    card.kick:SetPoint("TOPLEFT", 22, -20)
    card.kick:SetText("GUILD MAP")
    card.title = Text(card, 16)
    card.title:SetPoint("TOPLEFT", 22, -36)
    card.title:SetText("Show your guild where you are?")
    card.text = Text(card, 11)
    card.text:SetTextColor(0.66, 0.66, 0.68)
    card.text:SetPoint("TOPLEFT", 22, -60)
    card.text:SetPoint("RIGHT", -22, 0)
    card.text:SetJustifyH("LEFT")
    card.text:SetWordWrap(true)
    card.text:SetText("Only guildmates who share see each other. Pick how much of you they see; the eye at the top "
        .. "right changes it any time.")
    card.opts = {
        OptionRow(card, "zone", "Zone only", "\"In Nagrand\". No dot, no exact spot.", 98),
        OptionRow(card, "exact", "Exact spot", "A dot that moves with you, every few seconds.", 148),
    }
    card.note = Text(card, 10.5)
    card.note:SetTextColor(0.49, 0.49, 0.51)
    card.note:SetPoint("BOTTOMLEFT", 22, 24)
    card.note:SetText("Always hidden in battlegrounds and arenas.")
    card.share = UI():CreateSleekButton(card, "Share", 84, 24, function()
        GM():SetShare(card.choice or "exact")
    end, "primary")
    card.share:SetPoint("BOTTOMRIGHT", -22, 18)
    card.choice = "exact"
    p.veil, p.card = veil, card
end

function GuildMapUI:PaintCard()
    local card = panel and panel.card
    if not card then return end
    for _, r in ipairs(card.opts) do
        local on = r.mode == card.choice
        r.bg:SetColorTexture(on and 1 or 1, on and 0.82 or 1, on and 0 or 1, on and 0.06 or 0.03)
        UI():SetEdgeColor(r, on and GOLD[1] or 1, on and GOLD[2] or 1, on and GOLD[3] or 1, on and 0.45 or 0.06)
        r.dot:SetVertexColor(on and GOLD[1] or 0.47, on and GOLD[2] or 0.47, on and GOLD[3] or 0.5, 1)
        r.pick:SetShown(on)
    end
end

local function ShareMenu(owner)
    local G = GM()
    UI():ContextMenu(owner, function(root)
        root:CreateTitle("Share where I am")
        for _, o in ipairs({ { "off", "Off" }, { "zone", "Zone only" }, { "exact", "Exact spot" } }) do
            local item = root:CreateRadio(o[2], function() return G:GetShare() == o[1] end, function() G:SetShare(o[1]) end)
            if o[1] == "off" then item:SetTitleAndTextTooltip("Off", "You stop seeing the others too.") end
        end
    end)
end

local function MoreMenu(owner)
    local G = GM()
    UI():ContextMenu(owner, function(root)
        root:CreateCheckbox("Dots on the world map (M)", function() return G:GetShowOnWorldMap() end,
            function() G:SetShowOnWorldMap(not G:GetShowOnWorldMap()) end)
    end)
end

function GuildMapUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", "DisasterZoneGuildMapPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    p.tabs = {}
    local prev
    for _, c in ipairs(GM().CONTINENTS) do
        local t = UI():CreateUnderlineTab(p, c.name, function() GuildMapUI:ShowContinent(c.id) end)
        if prev then t:SetPoint("LEFT", prev, "RIGHT", 4, 0) else t:SetPoint("TOPLEFT", 6, -6) end
        t.cont = c
        p.tabs[#p.tabs + 1] = t
        prev = t
    end
    p.more = UI():CreateTipIconButton(p, 22, UI().ICON.more, "More", nil, function(self) MoreMenu(self) end)
    p.more:SetPoint("TOPRIGHT", -8, -6)
    p.eye = UI():CreateTipIconButton(p, 22, UI().ICON.eye, "Sharing", nil, function(self) ShareMenu(self) end)
    p.eye:SetPoint("RIGHT", p.more, "LEFT", -6, 0)

    -- the map: the art (left of the list, clipped to it), its region highlight, the pins; the list on the right
    local view = CreateFrame("Frame", nil, p)
    view:SetPoint("TOPLEFT", 0, -TOP)
    view:SetPoint("BOTTOMRIGHT", 0, 0)
    p.view = view
    local art = CreateFrame("Frame", nil, view)
    art:SetPoint("TOPLEFT")
    art:SetPoint("BOTTOMRIGHT", -SIDE_W, 0)
    if art.SetClipsChildren then art:SetClipsChildren(true) end
    art:EnableMouse(true)
    p.art = art
    p.solid = view:CreateTexture(nil, "BACKGROUND")
    p.solid:SetColorTexture(0.055, 0.055, 0.067, 1)
    p.solid:SetPoint("TOPLEFT", art, "TOPRIGHT")
    p.solid:SetPoint("BOTTOMRIGHT")
    p.sideEdge = view:CreateTexture(nil, "BORDER")
    p.sideEdge:SetColorTexture(1, 1, 1, 0.07)
    p.sideEdge:SetWidth(1)
    p.sideEdge:SetPoint("TOPLEFT", p.solid, "TOPLEFT")
    p.sideEdge:SetPoint("BOTTOMLEFT", p.solid, "BOTTOMLEFT")
    -- the region under the cursor: the game's own highlight art, and its name
    p.hl = art:CreateTexture(nil, "BORDER")
    p.hl:SetBlendMode("ADD")
    p.hl:SetAlpha(0.45)
    p.hl:Hide()
    p.vig = {}
    for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = art:CreateTexture(nil, "ARTWORK")
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        if side == "LEFT" or side == "RIGHT" then
            t:SetPoint("TOP" .. side)
            t:SetPoint("BOTTOM" .. side)
            t:SetWidth(side == "LEFT" and 30 or 22)
            Gradient(t, "HORIZONTAL", 0, 0, 0, side == "LEFT" and 0.45 or 0, side == "LEFT" and 0 or 0.4)
        else
            t:SetPoint(side .. "LEFT")
            t:SetPoint(side .. "RIGHT")
            t:SetHeight(30)
            Gradient(t, "VERTICAL", 0, 0, 0, side == "TOP" and 0 or 0.45, side == "TOP" and 0.45 or 0)
        end
        p.vig[i] = t
    end
    p.pins = {}
    p.pinLayer = CreateFrame("Frame", nil, art)
    p.pinLayer:SetAllPoints()
    p.pinLayer:SetFrameLevel(art:GetFrameLevel() + 2)
    p.tag = CreateFrame("Frame", nil, art)
    p.tag:SetHeight(22)
    p.tag:SetPoint("TOP", 0, -10)
    p.tag:SetFrameLevel(art:GetFrameLevel() + 20)
    p.tag.bg = p.tag:CreateTexture(nil, "BACKGROUND")
    p.tag.bg:SetAllPoints()
    p.tag.bg:SetColorTexture(0.055, 0.055, 0.067, 0.86)
    UI():AddEdges(p.tag, "BORDER")
    UI():SetEdgeColor(p.tag, 1, 1, 1, 0.09)
    p.tag.text = Text(p.tag, 12)
    p.tag.text:SetPoint("CENTER", 0, 0)
    p.tag:Hide()
    art:SetScript("OnUpdate", function(self, elapsed)
        self.look = (self.look or 0) + (elapsed or 0)
        if self.look < 0.05 then return end
        self.look = 0
        GuildMapUI:HoverRegion(self:IsMouseOver() and not GuildMapUI:OverPin())
    end)
    art:SetScript("OnLeave", function() GuildMapUI:HoverRegion(false) end)
    art:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            if state.zone then GuildMapUI:ZoomOut() end
        elseif state.region then
            GuildMapUI:ShowZone(state.region)
        end
    end)
    p.crumb = CreateFrame("Button", nil, art)
    p.crumb:SetHeight(24)
    p.crumb:SetPoint("TOPLEFT", 12, -10)
    p.crumb:SetFrameLevel(art:GetFrameLevel() + 20)
    p.crumb.bg = p.crumb:CreateTexture(nil, "BACKGROUND")
    p.crumb.bg:SetAllPoints()
    p.crumb.bg:SetColorTexture(0.055, 0.055, 0.067, 0.88)
    UI():AddEdges(p.crumb, "BORDER")
    UI():SetEdgeColor(p.crumb, 1, 1, 1, 0.09)
    p.crumb.chev = p.crumb:CreateTexture(nil, "ARTWORK")
    p.crumb.chev:SetSize(10, 10)
    p.crumb.chev:SetPoint("LEFT", 8, 0)
    UI():SetChevron(p.crumb.chev, false)
    p.crumb.chev:SetVertexColor(0.7, 0.7, 0.72)
    p.crumb.text = Text(p.crumb, 12)
    p.crumb.text:SetPoint("LEFT", 22, 0)
    p.crumb:SetScript("OnClick", function() GuildMapUI:ZoomOut() end)

    -- the list: a scroll frame over the solid strip (its bar inside the strip's right margin)
    p.list = UI():CreateScrollFrame(view)
    p.list:SetPoint("TOPRIGHT", -14, -10)
    p.list:SetPoint("BOTTOMRIGHT", -14, 30)
    p.list:SetWidth(SIDE_W - 14)
    p.list:SetFrameLevel(view:GetFrameLevel() + 10)
    p.listChild = CreateFrame("Frame", nil, p.list)
    p.listChild:SetSize(SIDE_W - 14, 10)
    p.list:SetScrollChild(p.listChild)
    p.rows = {}
    p.foot = Text(view, 10.5)
    p.foot:SetTextColor(0.43, 0.43, 0.45)
    p.foot:SetPoint("BOTTOMRIGHT", -14, 12)
    p.foot:SetWidth(SIDE_W - 28)
    p.foot:SetJustifyH("LEFT")
    p.empty = Text(view, 11)
    p.empty:SetTextColor(0.6, 0.6, 0.62)
    p.empty:SetPoint("TOPLEFT", p.list, "TOPLEFT", 10, -6)
    p.empty:SetWidth(SIDE_W - 30)
    p.empty:SetJustifyH("LEFT")
    p.empty:SetWordWrap(true)

    CreateCard(p)
    self:PaintCard()

    p:SetScript("OnShow", function()
        GM():SetViewing(true)
        GuildMapUI:Refresh()
    end)
    p:SetScript("OnHide", function() GM():SetViewing(false) end)
    -- my arrow turns and walks with me; the rest follows GUILDMAP_UPDATED (and a slow look for the "ago"s)
    -- every frame: my arrow walks and turns with me, the others glide; news redraws the map at most every 0.25 s,
    -- and it is looked at again every 2 s anyway (the "ago"s, demo walkers)
    p.lastDraw = 0
    p:SetScript("OnUpdate", function(self)
        local now = GetTime()
        if (self.dirty and now - self.lastDraw >= 0.25) or now - self.lastDraw >= GLIDE then
            GuildMapUI:Refresh()
        end
        GuildMapUI:Glide(now)
        GuildMapUI:MoveMe()
    end)
    GM():SetViewing(p:IsVisible())
    C_Timer.After(0, function() GuildMapUI:Refresh() end)
    return p
end

-- The continent a map lies on (or itself), else Outland.
local function ContinentFor(map)
    return (map and GM():ContinentOf(map)) or 1945
end

function GuildMapUI:ShowContinent(id)
    state.cont, state.zone = id, nil
    self:Refresh()
end

-- Zooms into a zone (uiMapID), or back out to its continent (nil).
function GuildMapUI:ShowZone(map)
    if map then state.cont = ContinentFor(map) end
    state.zone = map
    self:Refresh()
end

-- Opens the map in a member's zone (their instance's entrance zone inside one).
function GuildMapUI:ShowPerson(key)
    local e = GM():GetEntries()[key]
    local zone = e and ((e.i and (GM():GetEntrance(e.i))) or e.m)
    if ns.MainFrame then ns.MainFrame:Open("map") end
    self:ShowZone(zone)
end

local function Info(id)
    if not (id and C_Map and C_Map.GetMapInfo) then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, id)
    return ok and type(info) == "table" and info or nil
end

-- Back out one step: a city to its zone (Shattrath to Terokkar), a zone to its continent.
function GuildMapUI:ZoomOut()
    local info = Info(state.zone)
    local parent = info and Info(info.parentMapID)
    if parent and parent.mapType == 3 then self:ShowZone(parent.mapID) else self:ShowZone(nil) end
end

-- The region (a zone, or a city in the open zone) at x, y (0..1) of map `map`, or nil.
local function RegionAt(map, x, y)
    if not (C_Map and C_Map.GetMapInfoAtPosition) or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    local ok, info = pcall(C_Map.GetMapInfoAtPosition, map, x, y)
    if not ok or type(info) ~= "table" or info.mapID == map or info.mapType ~= 3 then return nil end
    return info.mapID, info.name
end

function GuildMapUI:RegionAt(map, x, y) return RegionAt(map, x, y) end

-- Is the mouse on a pin or the crumb (they take the click, not the region under them)?
function GuildMapUI:OverPin()
    local p = panel
    if not p then return false end
    if p.crumb:IsShown() and p.crumb:IsMouseOver() then return true end
    for _, b in ipairs(p.pins) do
        if b:IsShown() and b:IsMouseOver() then return true end
    end
    return false
end

-- Lights the region under the cursor (on = the mouse is over the art), as the game's map does: its highlight art
-- and its name with how many guildmates are in it; a click opens it (state.region).
function GuildMapUI:HoverRegion(on)
    local p = panel
    if not p or not p.art.toMap then return end
    local map = state.zone or state.cont
    local region, name
    local x, y
    if on and GetCursorPosition and p.art:GetLeft() then
        local cx, cy = GetCursorPosition()
        local sc = p.art:GetEffectiveScale() or 1
        x, y = p.art.toMap(cx / sc - p.art:GetLeft(), p.art:GetTop() - cy / sc)
        region, name = RegionAt(map, x, y)
    end
    if region == state.region then return end
    state.region = region
    p.hl:Hide()
    p.tag:Hide()
    if not region then return end
    -- the game's own highlight of that region (C_Map.GetMapHighlightInfoAtPosition: as Blizzard's map draws it)
    if C_Map.GetMapHighlightInfoAtPosition then
        local ok, file, atlas, tpx, tpy, tw, th, sx, sy = pcall(C_Map.GetMapHighlightInfoAtPosition, map, x, y)
        if ok and ((file and file > 0) or atlas) and (tw or 0) > 0 and (th or 0) > 0 then
            if atlas and p.hl.SetAtlas then p.hl:SetAtlas(atlas) else p.hl:SetTexture(file) end
            p.hl:SetTexCoord(0, tpx or 1, 0, tpy or 1)
            p.hl:ClearAllPoints()
            p.hl:SetPoint("TOPLEFT", p.art, "TOPLEFT", p.art.x0 + sx * p.art.artW, -(p.art.y0 + sy * p.art.artH))
            p.hl:SetSize(tw * p.art.artW, th * p.art.artH)
            p.hl:Show()
        end
    end
    local n = 0
    for _, e in pairs(GM():GetEntries()) do
        local m = e.i and (GM():GetEntrance(e.i)) or e.m
        local info = Info(m)
        if m == region or (info and info.parentMapID == region) then n = n + 1 end
    end
    p.tag.text:SetText((name or "") .. (n > 0 and ("  |cff8a8a8e·|r  |cffffd100" .. n .. "|r") or ""))
    p.tag:SetWidth(floor((p.tag.text:GetStringWidth() or 100) + 24))
    p.tag:Show()
end

function GuildMapUI:GetState() return state end
function GuildMapUI:GetPanel() return panel end

-- Builds what the view shows: { pins = { data }, zones = { list rows } }.
local function Build(entries, map, zoneView, W, H, place)
    local G = GM()
    local items = {}
    local byZone, zoneList = {}, {}
    for key, e in pairs(entries) do
        local onCont = G:ContinentOf(e.i and (G:GetEntrance(e.i)) or e.m)
        local here
        if zoneView then
            here = (e.m == map) or (e.i and (G:GetEntrance(e.i)) == map)
            -- (a city inside the zone: Shattrath in Terokkar shows in Terokkar too)
            if not here and e.m and not e.i then
                local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(e.m)
                here = info and info.parentMapID == map
            end
        else
            here = onCont == map
        end
        if here then
            local x, y = G:PlaceOn(e, map)
            local zk = ZoneKey(e)
            if zoneView and not e.i and e.s and not e.z then zk = "s" .. e.s end
            local z = byZone[zk]
            if not z then
                local name
                if e.i then name = e.n or "?"
                elseif zoneView and zk:sub(1, 1) == "s" then name = e.s
                else name = G:GetMapName(e.m) or "?" end
                z = { key = zk, name = name, keys = {}, inst = e.i ~= nil,
                      sub = e.i and ((G:GetMapName((G:GetEntrance(e.i))) or "") .. " · " .. "instance") or nil,
                      zoom = (not zoneView) and (e.i and (G:GetEntrance(e.i)) or e.m) or nil }
                byZone[zk] = z
                zoneList[#zoneList + 1] = z
            end
            z.keys[#z.keys + 1] = key
            if x and y and x >= -0.05 and x <= 1.05 and y >= -0.05 and y <= 1.05 then
                local px, py = place(x, y)
                items[#items + 1] = { key = key, e = e, px = px, py = py, zoneKey = zk }
            end
        end
    end
    local function nameSort(a, b)
        if ns.Util.IsMe(a) ~= ns.Util.IsMe(b) then return ns.Util.IsMe(b) end
        return a < b
    end
    for _, z in ipairs(zoneList) do table.sort(z.keys, nameSort) end
    table.sort(zoneList, function(a, b)
        if #a.keys ~= #b.keys then return #a.keys > #b.keys end
        return a.name < b.name
    end)
    -- pins: me apart; an instance's members in one; on a continent, dots this close make a crowd
    local pins, used, groups = {}, {}, {}
    table.sort(items, function(a, b) return a.key < b.key end)
    for i, it in ipairs(items) do
        if not used[i] then
            if it.e.me then
                used[i] = true
                pins[#pins + 1] = { kind = "me", key = it.key, e = it.e, px = it.px, py = it.py, zoneKey = it.zoneKey }
            elseif it.e.i then
                local keys = {}
                for j = i, #items do
                    local o = items[j]
                    if not used[j] and not o.e.me and o.e.i == it.e.i then used[j] = true keys[#keys + 1] = o.key end
                end
                table.sort(keys)
                pins[#pins + 1] = { kind = "dungeon", keys = keys, px = it.px, py = it.py, title = it.e.n,
                                    zoneKey = it.zoneKey, zoom = (not zoneView) and (GM():GetEntrance(it.e.i)) or nil }
            else
                used[i] = true
                groups[#groups + 1] = { it, cx = it.px, cy = it.py }
            end
        end
    end
    -- on a continent, dots this close make a crowd, and crowds this close one crowd (until none are)
    local merged = not zoneView
    while merged do
        merged = false
        for a = 1, #groups do
            for b = a + 1, #groups do
                local A, B = groups[a], groups[b]
                local limit = (#A > 1 or #B > 1) and CROWD_PX or CLUSTER_PX
                if not merged and sqrt((A.cx - B.cx) ^ 2 + (A.cy - B.cy) ^ 2) < limit then
                    for _, o in ipairs(B) do A[#A + 1] = o end
                    local sx, sy = 0, 0
                    for _, o in ipairs(A) do sx, sy = sx + o.px, sy + o.py end
                    A.cx, A.cy = sx / #A, sy / #A
                    table.remove(groups, b)
                    merged = true
                end
            end
            if merged then break end
        end
    end
    local W0 = W
    for _, group in ipairs(groups) do
        local it = group[1]
        if #group == 1 then
            pins[#pins + 1] = { kind = "dot", key = it.key, e = it.e, px = it.px, py = it.py, zoneKey = it.zoneKey,
                                label = zoneView and ns.Util.ShortName(it.key) or nil,
                                labelLeft = zoneView and it.px > W0 - 90 }
        else
            -- (a crowd zooms into the zone most of them are in)
            local keys, per, top = {}, {}, it.e.m
            for _, o in ipairs(group) do
                keys[#keys + 1] = o.key
                per[o.e.m] = (per[o.e.m] or 0) + 1
                if per[o.e.m] > (per[top] or 0) then top = o.e.m end
            end
            table.sort(keys)
            pins[#pins + 1] = { kind = "crowd", keys = keys, px = group.cx, py = group.cy,
                                title = GM():GetMapName(top), zoneKey = it.zoneKey, zoom = top }
        end
    end
    -- no pin hides another: overlapping ones are nudged apart (me never moves; crowds and dungeons stay near enough
    -- to their spot to read right)
    local function radius(d)
        if d.kind == "dungeon" then return 19 end   -- (its count badge sticks out)
        if d.kind == "crowd" then return 16 end
        if d.kind == "me" then return 15 end
        return (d.e and d.e.z) and 9 or 7
    end
    for _ = 1, 12 do
        local moved = false
        for i = 1, #pins do
            for j = i + 1, #pins do
                local A, B = pins[i], pins[j]
                local dx, dy = B.px - A.px, B.py - A.py
                local dist = sqrt(dx * dx + dy * dy)
                local need = radius(A) + radius(B) + 2
                if dist < need then
                    if dist < 0.01 then dx, dy, dist = 1, 0, 1 end
                    local push = need - dist
                    local ux, uy = dx / dist, dy / dist
                    local wa = (A.kind == "me") and 0 or ((B.kind == "me") and 1 or 0.5)
                    A.px, A.py = A.px - ux * push * wa, A.py - uy * push * wa
                    B.px, B.py = B.px + ux * push * (1 - wa), B.py + uy * push * (1 - wa)
                    moved = true
                end
            end
        end
        if not moved then break end
    end
    -- a name by a dot, or under a dungeon, only where it doesn't run into another pin (the tooltip and the list have
    -- it anyway)
    for _, d in ipairs(pins) do
        if d.kind == "dungeon" then
            d.showName = true
            for _, o in ipairs(pins) do
                local ro = radius(o)
                if o ~= d and abs(o.px - d.px) < 58 + ro and o.py - d.py > 10 - ro and o.py - d.py < 34 + ro then
                    d.showName = false
                    break
                end
            end
        end
    end
    for _, d in ipairs(pins) do
        if d.label then
            for _, o in ipairs(pins) do
                if o ~= d then
                    local dx = o.px - d.px
                    if abs(o.py - d.py) < 14 and ((d.labelLeft and dx < 0 and dx > -80) or (not d.labelLeft and dx > 0 and dx < 80)) then
                        d.label = nil
                        break
                    end
                end
            end
        end
    end
    return pins, zoneList
end

function GuildMapUI:Refresh()
    local p = panel
    if not p or not p:IsVisible() then return end
    p.dirty, p.lastDraw = false, GetTime()
    local G = GM()
    local sharing = G:IsSharing()
    -- (demo mode shows its made-up guild without asking)
    p.veil:SetShown(not sharing and not G:IsDemo())
    p.card.choice = p.card.choice or "exact"
    self:PaintCard()
    local entries = G:GetEntries()
    -- the continent tabs, with how many are on each
    local counts = {}
    for _, e in pairs(entries) do
        local c = G:ContinentOf(e.i and (G:GetEntrance(e.i)) or e.m)
        if c then counts[c] = (counts[c] or 0) + 1 end
    end
    for _, t in ipairs(p.tabs) do
        local n = counts[t.cont.id]
        t:SetLabel(n and (t.cont.name .. "  |cff8a8a8e" .. n .. "|r") or t.cont.name)
        if t.SetActive then t:SetActive(t.cont.id == state.cont) end
    end
    local share = G:GetShare()
    p.eye.icon:SetVertexColor(sharing and GOLD[1] or 0.6, sharing and GOLD[2] or 0.6, sharing and GOLD[3] or 0.62)
    p.eye.tipTitle = "Sharing: " .. (share == "exact" and "exact spot" or (share == "zone" and "zone only" or "off"))
    p.eye.tipText = "Who sees you: guildmates who share too. Click to change it."
    local map = state.zone or state.cont
    local W, H = ViewSize(p)
    DrawArt(p.art, map, W, H)
    state.region = nil
    p.hl:Hide()
    p.tag:Hide()
    local pins, zones = Build(entries, map, state.zone ~= nil, W, H, p.art.place)
    p.zones = zones
    -- each pin glides from where it is drawn to its new place (a new map, or a pin seen first, starts in place)
    local now = GetTime()
    p.glide = p.glide or {}
    local snap = state.drawn ~= map
    state.drawn = map
    local seen = {}
    for i, d in ipairs(pins) do
        local b = p.pins[i] or NewPin(p.pinLayer)
        p.pins[i] = b
        b.data = d
        b.big = b.big and b:IsMouseOver()
        local id = d.kind == "me" and "me" or (d.key and ("k:" .. d.key))
            or ((d.kind == "dungeon" and "d:" or "c:") .. tostring(d.zoneKey) .. ":" .. tostring(d.keys and d.keys[1]))
        seen[id] = true
        local g = p.glide[id]
        if not g or snap then
            g = { x = d.px, y = d.py, fx = d.px, fy = d.py, tx = d.px, ty = d.py, t0 = now }
            p.glide[id] = g
        elseif abs(g.tx - d.px) > 0.3 or abs(g.ty - d.py) > 0.3 then
            g.fx, g.fy, g.tx, g.ty, g.t0 = g.x, g.y, d.px, d.py, now
        end
        b.glide = g
        b:ClearAllPoints()
        b:SetPoint("CENTER", p.pinLayer, "TOPLEFT", g.x, -g.y)
        b:Paint()
        b:Show()
    end
    for id in pairs(p.glide) do
        if not seen[id] then p.glide[id] = nil end
    end
    for i = #pins + 1, #p.pins do
        p.pins[i]:Hide()
        p.pins[i].data = nil
        p.pins[i].glide = nil
    end
    -- the crumb in a zone
    p.crumb:SetShown(state.zone ~= nil)
    if state.zone then
        -- the way up: continent › (zone ›) here; a click goes up one step
        local chain, id, hops = {}, state.zone, 0
        while id and id ~= state.cont and hops < 4 do
            table.insert(chain, 1, G:GetMapName(id) or "")
            local info = Info(id)
            id = info and info.parentMapID
            hops = hops + 1
        end
        table.insert(chain, 1, G:GetMapName(state.cont) or "")
        for i = 1, #chain - 1 do chain[i] = "|cffa8a8a8" .. chain[i] .. "|r" end
        p.crumb.text:SetText(table.concat(chain, "  |cff666666›|r  "))
        p.crumb:SetWidth(floor((p.crumb.text:GetStringWidth() or 120) + 34))
    end
    self:PaintList()
    local n = G:CountNotSharing()
    p.foot:SetText(sharing and n > 0 and (n .. " online " .. (n == 1 and "isn't" or "aren't") .. " sharing") or "")
end

-- Moves my arrow (between refreshes).
-- Moves the pins a frame further on their glide (linear: a walker keeps a steady pace between two reports).
function GuildMapUI:Glide(now)
    local p = panel
    if not p then return end
    for _, b in ipairs(p.pins) do
        local g = b.glide
        if g and b:IsShown() and b.data and b.data.kind ~= "me" and (g.x ~= g.tx or g.y ~= g.ty) then
            local t = min(1, (now - g.t0) / GLIDE)
            g.x, g.y = g.fx + (g.tx - g.fx) * t, g.fy + (g.ty - g.fy) * t
            b:ClearAllPoints()
            b:SetPoint("CENTER", p.pinLayer, "TOPLEFT", g.x, -g.y)
        end
    end
end

-- My arrow where I stand right now, turned the way I face (every frame: my own position needs no message).
function GuildMapUI:MoveMe()
    local p = panel
    if not p or not p:IsVisible() or not p.art.place then return end
    for _, b in ipairs(p.pins) do
        local d = b.data
        if d and d.kind == "me" and b:IsShown() then
            local x, y
            local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
            local pos = map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, "player")
            if pos then
                local mx, my = pos:GetXY()
                x, y = GM():Translate(map, mx, my, state.zone or state.cont)
            end
            if x and y then
                local px, py = p.art.place(x, y)
                b:ClearAllPoints()
                b:SetPoint("CENTER", p.pinLayer, "TOPLEFT", px, -py)
            end
            if b.arrow.SetRotation then b.arrow:SetRotation(GetPlayerFacing and GetPlayerFacing() or 0) end
        end
    end
end

function GuildMapUI:PaintList()
    local p = panel
    if not p then return end
    local y = 0
    local w = SIDE_W - 14
    for i, z in ipairs(p.zones or {}) do
        local r = ListRow(p, i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p.listChild, "TOPLEFT", 0, -y)
        r:SetWidth(w)
        r.zoom = z.zoom
        r.line:SetShown(i > 1)
        r.bar:SetShown(state.hot == z.key)
        r.icon:SetShown(z.inst)
        r.name:ClearAllPoints()
        r.name:SetPoint("TOPLEFT", z.inst and 28 or 10, -7)
        r.name:SetPoint("RIGHT", r.count, "LEFT", -6, 0)
        r.name:SetText(z.name)
        r.count:SetText(#z.keys)
        local top = 24
        r.sub:SetShown(z.sub ~= nil)
        if z.sub then
            r.sub:ClearAllPoints()
            r.sub:SetPoint("TOPLEFT", 10, -23)
            r.sub:SetText(z.sub)
            top = 38
        end
        local names = {}
        for _, key in ipairs(z.keys) do
            local e = (GM():GetEntries())[key]
            if ns.Util.IsMe(key) then names[#names + 1] = "|cffffd100You|r"
            else
                local s = ColoredName(key)
                if e and e.a then s = "|cff7a7a7c" .. ns.Util.ShortName(key) .. "|r" end
                names[#names + 1] = s
            end
        end
        r.people:ClearAllPoints()
        r.people:SetPoint("TOPLEFT", 10, -top)
        r.people:SetWidth(w - 10)
        r.people:SetText(table.concat(names, "   "))
        local ph = r.people:GetStringHeight() or 14
        if ph < 12 then ph = 14 end
        local h = top + ph + 9
        r:SetHeight(h)
        r:Show()
        y = y + h
    end
    for i = #(p.zones or {}) + 1, #p.rows do p.rows[i]:Hide() end
    p.listChild:SetHeight(max(y, 10))
    local none = #(p.zones or {}) == 0
    p.empty:SetShown(none and GM():IsSharing())
    p.empty:SetText(state.zone and "Nobody here right now." or "Nobody who shares is on this continent right now.")
end

---------------------------------------------------------------------------
-- The game's world map: the same dots (no crowds, no list), on every map they fall on
---------------------------------------------------------------------------

local WorldMap = {}
GuildMapUI.WorldMap = WorldMap

local function WorldPins()
    WorldMap.pins = WorldMap.pins or {}
    return WorldMap.pins
end

function WorldMap:Refresh()
    local wm = WorldMapFrame
    local pins = WorldPins()
    local G = GM()
    local show = wm and wm.IsShown and wm:IsShown() and G and G:GetShowOnWorldMap() and G:IsSharing()
    local canvas = show and wm.GetCanvas and wm:GetCanvas()
    local mapID = show and wm.GetMapID and wm:GetMapID()
    local n = 0
    if canvas and mapID then
        local W, H = canvas:GetWidth() or 0, canvas:GetHeight() or 0
        local scale = (wm.GetCanvasScale and wm:GetCanvasScale()) or 1
        if scale <= 0 then scale = 1 end
        for key, e in pairs(G:GetEntries()) do
            if not e.me then
                local x, y = G:PlaceOn(e, mapID)
                if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                    n = n + 1
                    local b = pins[n]
                    if not b then
                        b = NewPin(canvas)
                        pins[n] = b
                    end
                    if b:GetParent() ~= canvas then b:SetParent(canvas) end
                    b.data = { kind = e.i and "dungeon" or "dot", key = (not e.i) and key or nil, keys = { key },
                               e = e, title = e.n }
                    b:SetScale(1 / scale)
                    b:ClearAllPoints()
                    b:SetPoint("CENTER", canvas, "TOPLEFT", x * W * scale, -y * H * scale)
                    b:SetFrameStrata("HIGH")
                    b:Paint()
                    b:Show()
                end
            end
        end
    end
    for i = n + 1, #pins do pins[i]:Hide() end
    WorldMap.count = n
end

local hooked = false
local function HookWorldMap()
    if hooked or not WorldMapFrame then return end
    hooked = true
    local function later() C_Timer.After(0, function() WorldMap:Refresh() end) end
    WorldMapFrame:HookScript("OnShow", later)
    WorldMapFrame:HookScript("OnHide", function() WorldMap:Refresh() end)
    if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", later) end
    if WorldMapFrame.OnCanvasScaleChanged then hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", later) end
    -- (positions move while it is open)
    local t = 0
    WorldMapFrame:HookScript("OnUpdate", function(_, elapsed)
        t = t + (elapsed or 0)
        if t >= 2 then
            t = 0
            WorldMap:Refresh()
        end
    end)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function GuildMapUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("map", "Map", 3.61, function(parent) return GuildMapUI:CreatePanel(parent) end,
            function() return IsInGuild() end)   -- (in a guild only: it is the guild's map)
    end
    local function refresh()
        if panel and panel:IsVisible() then
            panel.dirty = true   -- (redrawn on its next frame, at most every 0.25 s)
        end
        if WorldMapFrame and WorldMapFrame:IsShown() then WorldMap:Refresh() end
    end
    for _, msg in ipairs({ "GUILDMAP_UPDATED", "SETTINGS_CHANGED", "DEMO_TOGGLED", "ROSTER_UPDATED" }) do
        ns:On(msg, refresh)
    end
    ns:RegisterSlash("map", function() ns.MainFrame:Open("map") end, "open Guild > Map: where guildmates who share are")
end

function GuildMapUI:OnLogin()
    HookWorldMap()
end
