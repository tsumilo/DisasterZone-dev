if DisasterZoneBoot and DisasterZoneBoot.Run("Games/HubUI.lua", ...) then return end -- DisasterZone Games/HubUI.lua
-- ns.GamesUI: the "Games" tab. A spotlight carousel: one game's poster in front, its neighbours dimmed at the sides
-- (arrows, mouse wheel, the dots or a click on a side poster turn it). A poster is the game's cover, alive while the
-- tab is open (your Bingo card filling in, the Trainer's bosses and best times, a walk through Azeromon's Elwynn),
-- then its name, one line, one stat of yours and who plays it now. Clicking the front poster grows it into the game:
-- a slim strip on top ("< GAMES", the game, who plays, share) and the game's panel under it.
-- While a Bingo game runs the carousel opens on Bingo (LIVE); otherwise on the game you opened last.
-- Covers are drawn here for the three games (COVERS); a game without one gets its icon.
-- (Games' panels are created lazily, once, and kept.)
local addonName, ns = ...

local GamesUI = ns:NewModule("GamesUI")

local floor, min, max, abs, sin, pi = math.floor, math.min, math.max, math.abs, math.sin, math.pi

local STRIP_H = 30
local FRONT_W, SIDE_W, SIDE_K = 300, 196, 0.88     -- poster widths; a side poster's height share of the front's
local SIDE_DIM = 0.55                              -- the dark over a side poster
local TURN_TIME, OPEN_TIME, BACK_TIME = 0.32, 0.58, 0.52
local OPEN_DARK = 0.72                              -- how dark the painting gets as it becomes the game's backdrop
local BASE = { 0.086, 0.086, 0.102 }               -- the posters' ground (#16161a)
local FALLBACK_W, FALLBACK_H = 786, 548            -- the tab's size before the client has laid it out
local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
local RADIAL = MEDIA .. "MyBiS\\Radial"
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local RAID_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"

-- the games' colours (the front poster's edge, the room's glow, the rule under the text)
local ACCENT = {
    bingo = { 1, 0.82, 0 }, trainer = { 0.31, 0.83, 0.88 }, azeromon = { 0.53, 0.85, 0.42 },
}
local DEFAULT_ACCENT = { 1, 0.82, 0 }

-- Raid loading screens by RaidPlan instance key (by FileDataID: the client doesn't resolve them by path), and where
-- the painting's subject stands across the image (the poster crop centres on it).
local LOADSCREEN = {
    kara = 131849, gruul = 131842, mag = 131846, ssc = 131832, tk = 131875, hyjal = 131847, bt = 131826,
    za = 131884, swp = 131873,
}
local FOCUS = { kara = 0.2, ssc = 0.2, bt = 0.45 }
local INST_BY_ID = { [532] = "kara", [565] = "gruul", [544] = "mag", [548] = "ssc", [550] = "tk", [534] = "hyjal",
                     [564] = "bt", [568] = "za", [580] = "swp" }

local root, carousel, aura, strip, stage, dots, arrows
local posters = {}      -- in game order
local panels = {}       -- id -> the game's frame
local selected          -- the open game's id (nil on the carousel)
local cur = 1           -- the front poster's index
local anim              -- { t, dur, kind, done }
local W, H = FALLBACK_W, FALLBACK_H

local function Accent(id) return ACCENT[id] or DEFAULT_ACCENT end

-- A game's saved table, read only (Games:GetData would create it: looking at the hub must not change saved data).
local EMPTY = {}
local function Saved(id)
    local g = ns.db and ns.db.games
    local t = type(g) == "table" and g[id]
    return type(t) == "table" and t or EMPTY
end

local function Size()
    local w, h = root and root:GetWidth() or 0, root and root:GetHeight() or 0
    if w < 100 or h < 100 then w, h = FALLBACK_W, FALLBACK_H end
    W, H = w, h
end

local function Label(parent, size, font, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

local gradA = CreateColor and CreateColor(0, 0, 0, 0)
local gradB = CreateColor and CreateColor(0, 0, 0, 0)
-- A gradient (orient "VERTICAL": colour 1 at the bottom) or, without SetGradient, its midpoint.
local function Gradient(tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if gradA and tex.SetGradient then
        gradA:SetRGBA(r1, g1, b1, a1)
        gradB:SetRGBA(r2, g2, b2, a2)
        tex:SetGradient(orient, gradA, gradB)
    else
        tex:SetColorTexture((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
    end
end

local function Ease(t) t = 1 - t return 1 - t * t * t end   -- ease-out cubic
local function Lerp(a, b, t) return a + (b - a) * t end

local function ClassRGB(key)
    local cls = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)
    if not cls and UnitClass and ns.Util then
        local _, c = UnitClass(ns.Util.ShortName(key))
        cls = c
    end
    local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
    if c then return c.r, c.g, c.b end
    return 0.6, 0.6, 0.6
end

local function Short(key) return ns.Util and ns.Util.ShortName(key) or tostring(key) end

local function Clock(sec)
    sec = floor((tonumber(sec) or 0) + 0.5)
    return string.format("%d:%02d", floor(sec / 60), sec % 60)
end

---------------------------------------------------------------------------
-- What each poster says (kicker over the art, the stat, who plays): real data only, nothing when there is none
---------------------------------------------------------------------------

-- The next raid this member can see: its view (or nil).
local function NextRaid()
    local RP = ns.RaidPlan
    if not (RP and RP.GetRaids) then return nil end
    local now = time()
    local ok, list = pcall(RP.GetRaids, RP, now - 3 * 3600, now + 14 * 86400)
    if not ok or type(list) ~= "table" then return nil end
    for _, v in ipairs(list) do
        if not v.cancelled and (v.t or 0) >= now - 3 * 3600 then return v end
    end
    return nil
end

local function InstanceHere()
    if not GetInstanceInfo then return nil end
    local name, kind, _, _, _, _, _, id = GetInstanceInfo()
    if kind ~= "raid" then return nil end
    return INST_BY_ID[id], name
end

-- My Bingo card now: card (nil without a game), marked[cell], onLine[cell], near[cell] (on a line one square away),
-- need[cell] (that missing square), away (fewest squares still missing from a line; 0 without a card), fresh (the
-- cell that filled in the last 8 seconds).
local function BingoState()
    local B, Card = ns.Bingo, ns.BingoCard
    local st = { marked = {}, onLine = {}, near = {}, need = {}, away = 0 }
    local g = B and B:GetGame()
    local card = g and B:GetMyCard()
    local hits = g and g.hits or {}
    st.card = card
    for i = 1, 25 do st.marked[i] = (i == 13) or (card ~= nil and Card.IsMarked(card[i], hits)) end
    if not card then return st end
    local best = 99
    for _, line in ipairs(Card.LINES or {}) do
        local miss, missAt = 0, nil
        for _, i in ipairs(line) do
            if not st.marked[i] then miss, missAt = miss + 1, i end
        end
        if miss == 0 then
            for _, i in ipairs(line) do st.onLine[i] = true end
        else
            if miss == 1 then
                for _, i in ipairs(line) do st.near[i] = true end
                st.need[missAt] = true
            end
            if miss < best then best = miss end
        end
    end
    st.away = best < 99 and best or 0
    local newT = 0
    for i = 1, 25 do
        local t = tonumber(hits[card[i]])
        if t and t > newT then st.fresh, newT = i, t end
    end
    if st.fresh and time() - newT > 8 then st.fresh = nil end
    return st
end

local INFO = {}

-- Bingo: LIVE while a game runs (then the raid's own loading screen), else the next raid.
INFO.bingo = function()
    local B, out = ns.Bingo, { art = "kara" }
    local live = B and B:IsActive()
    local data = Saved("bingo")
    if live then
        out.live = true
        local key, name = InstanceHere()
        out.art = key or out.art
        out.kicker = name and ("LIVE   \194\183   " .. name:upper()) or "LIVE"
        local lines, marked = B:GetScore(ns.Util.PlayerKey())
        local need = BingoState().away
        if lines > 0 then
            out.stat = string.format("|cffffd100%d %s|r  \194\183  %d squares", lines, lines == 1 and "line" or "lines", marked)
        elseif need > 0 then
            out.stat = string.format("|cffffd100%d %s|r from a line", need, need == 1 and "square" or "squares")
        else
            out.stat = string.format("%d squares marked", marked)
        end
        local race = B:GetRace()
        out.faces = {}
        for i = 1, #race do out.faces[i] = race[i].key end
        out.foot = string.format("%d playing", #race)
        return out
    end
    local v = NextRaid()
    if v then
        local first = ns.RaidPlan:GetRaidInstances(v)[1]
        if first and LOADSCREEN[first] then out.art = first end
        out.kicker = "NEXT RAID   \194\183   " .. (date("%a ", v.t) .. tonumber(date("%d", v.t))):upper()
    else
        out.kicker = "RAID NIGHT"
    end
    local season = B and B:GetSeason() or {}
    local row = season[ns.Util.PlayerKey()]
    local bingos = type(row) == "table" and tonumber(row.bingos) or 0
    if bingos > 0 then
        out.stat = string.format("Bingos this season |cffffffff%d|r", bingos)
    elseif data.best then
        out.stat = string.format("Best card |cffffffff%d|r squares", data.best)
    else
        out.stat = "|cff8a8a8aNot played yet|r"
    end
    out.foot = "|cff8a8a8aStarts with the raid|r"
    return out
end

-- Raid Trainer: clears and tries over every boss and difficulty (the bosses' best times are on the cover).
INFO.trainer = function()
    local out = { kicker = "PRACTICE", art = "ssc" }
    local data = Saved("trainer")
    local tries, clears = 0, 0
    for _, diffs in pairs(type(data.enc) == "table" and data.enc or {}) do
        for _, rec in pairs(type(diffs) == "table" and diffs or {}) do
            if type(rec) == "table" then
                tries, clears = tries + (tonumber(rec.tries) or 0), clears + (tonumber(rec.clears) or 0)
            end
        end
    end
    local T = ns.Trainer
    local last = T and T:GetEncounter(data.last)
    if last and last.id == "teron" then out.art = "bt" end
    if tries > 0 then
        out.stat = string.format("|cffffffff%d|r %s  \194\183  |cffffffff%d|r %s", clears, clears == 1 and "clear" or "clears",
            tries, tries == 1 and "try" or "tries")
    else
        out.stat = "|cff8a8a8aNot played yet|r"
    end
    return out
end

-- Azeromon: badges and tamed beasts from the save; who is out walking Elwynn now.
INFO.azeromon = function()
    local out = { kicker = "ADVENTURE" }
    local s = Saved("azeromon").save
    local D = ns.AzeroData
    if type(s) == "table" and D and type(D.badges) == "table" then
        local badges, total, tamed = 0, 0, 0
        for id in pairs(D.badges) do
            total = total + 1
            if type(s.flags) == "table" and s.flags["badge_" .. id] then badges = badges + 1 end
        end
        for _ in pairs(type(s.caught) == "table" and s.caught or {}) do tamed = tamed + 1 end
        out.stat = string.format("Badges |cffffffff%d of %d|r  \194\183  |cffffffff%d|r tamed", badges, total, tamed)
    else
        out.stat = "|cff8a8a8aNot started yet|r"
    end
    local Net = ns.AzeroNet
    local keys = Net and Net.PlayingKeys and Net:PlayingKeys() or {}
    local n = Net and Net.PlayingNow and Net:PlayingNow() or #keys
    if n > 0 then
        out.faces = keys
        out.foot = string.format("%d playing now", n)
    end
    return out
end

local function Info(id)
    local fn = INFO[id]
    if fn then
        local ok, out = pcall(fn)
        if ok and type(out) == "table" then return out end
    end
    local data = Saved(id)
    return { stat = data.best and ("Best |cffffffff" .. data.best .. "|r") or "|cff8a8a8aNot played yet|r" }
end

---------------------------------------------------------------------------
-- Covers: the live part of a poster (cover:Layout(w, h) for its box, cover:Refresh(), cover:Tick(elapsed))
---------------------------------------------------------------------------

local COVERS = {}

-- Bingo: your card. Your dauber on the marked squares, gold edges on complete lines and on a line one square away
-- (its missing square pulses), the square that just filled glows.
COVERS.bingo = function(parent)
    local c = CreateFrame("Frame", nil, parent)
    c.cells = {}
    for i = 1, 25 do
        local cell = CreateFrame("Frame", nil, c)
        cell.bg = cell:CreateTexture(nil, "BACKGROUND")
        cell.bg:SetAllPoints()
        ns.UI:AddEdges(cell, "BORDER")
        cell.glow = cell:CreateTexture(nil, "ARTWORK", nil, 1)
        cell.glow:SetTexture(RADIAL)
        cell.glow:SetBlendMode("ADD")
        cell.glow:SetVertexColor(1, 0.82, 0)
        cell.glow:SetPoint("TOPLEFT", -10, 10)
        cell.glow:SetPoint("BOTTOMRIGHT", 10, -10)
        cell.glow:Hide()
        cell.mark = cell:CreateTexture(nil, "ARTWORK", nil, 2)
        c.cells[i] = cell
    end
    c.clock = 0
    function c:Layout(w, h)
        local size = floor(min(w - 40, h - 16, 180))
        if size < 40 then size = 40 end
        local gap = 3
        local cs = (size - 4 * gap) / 5
        self:SetSize(size, size)
        for i, cell in ipairs(self.cells) do
            local r, col = floor((i - 1) / 5), (i - 1) % 5
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", self, "TOPLEFT", col * (cs + gap), -r * (cs + gap))
            cell:SetSize(cs, cs)
            cell.mark:ClearAllPoints()
            local inset = cs * (i == 13 and 0.12 or 0.17)
            cell.mark:SetPoint("TOPLEFT", inset, -inset)
            cell.mark:SetPoint("BOTTOMRIGHT", -inset, inset)
        end
    end
    function c:Refresh()
        local st = BingoState()
        local marked, onLine, near = st.marked, st.onLine, st.near
        local dauber = tonumber(Saved("bingo").dauber) or 1
        if dauber < 1 or dauber > 8 then dauber = 1 end
        self.need, self.fresh = st.need, st.fresh
        for i, cell in ipairs(self.cells) do
            if i == 13 then
                cell.mark:SetTexture(MEDIA .. "Launcher\\seal")
                cell.mark:SetTexCoord(0, 1, 0, 1)
                cell.mark:SetAlpha(0.9)
                cell.mark:Show()
            elseif marked[i] then
                cell.mark:SetTexture(RAID_ICON .. dauber)
                cell.mark:SetAlpha(1)
                cell.mark:Show()
            else
                cell.mark:Hide()
            end
            local line = onLine[i] or near[i] or i == 13
            if marked[i] and i ~= 13 then
                cell.bg:SetColorTexture(0.14, 0.12, 0.06, 0.9)
            else
                cell.bg:SetColorTexture(0.08, 0.067, 0.04, 0.84)
            end
            ns.UI:SetEdgeColor(cell, 1, 0.82, 0, (line and marked[i]) and 0.7 or 0.16)
            cell.glow:SetShown(i == self.fresh)
        end
    end
    function c:Tick(elapsed)
        self.clock = self.clock + elapsed
        local p = 0.45 + 0.4 * sin(self.clock * 3.2)
        for i in pairs(self.need or {}) do ns.UI:SetEdgeColor(self.cells[i], 1, 0.82, 0, p) end
        if self.fresh then self.cells[self.fresh].glow:SetAlpha(0.35 + 0.3 * sin(self.clock * 4)) end
    end
    return c
end

-- Raid Trainer: one chip per boss with your best clear time (any difficulty); the one you played last is lit.
COVERS.trainer = function(parent)
    local c = CreateFrame("Frame", nil, parent)
    c.chips, c.shown = {}, {}
    c.frontOnly = true      -- (a side poster is too narrow for the boss names)
    local function chip(i)
        local ch = c.chips[i]
        if ch then return ch end
        ch = CreateFrame("Frame", nil, c)
        ch:SetHeight(26)
        ch.bg = ch:CreateTexture(nil, "BACKGROUND")
        ch.bg:SetAllPoints()
        ch.bg:SetColorTexture(0.03, 0.06, 0.07, 0.78)
        ns.UI:AddEdges(ch, "BORDER")
        ch.dot = ch:CreateTexture(nil, "ARTWORK")
        ch.dot:SetTexture(CIRCLE)
        ch.dot:SetSize(6, 6)
        ch.dot:SetPoint("LEFT", 10, 0)
        ch.name = Label(ch, 11.5)
        ch.name:SetPoint("LEFT", ch.dot, "RIGHT", 8, 0)
        ch.time = Label(ch, 11.5)
        ch.time:SetJustifyH("RIGHT")
        ch.time:SetPoint("RIGHT", -10, 0)
        ch.name:SetPoint("RIGHT", ch.time, "LEFT", -8, 0)
        c.chips[i] = ch
        return ch
    end
    function c:Layout(w, h)
        self:SetSize(w - 32, max(60, h - 64))     -- (the chips end above the title)
        for i, ch in ipairs(self.chips) do
            ch:ClearAllPoints()
            ch:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 0, (#self.shown - i) * 32)
            ch:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, (#self.shown - i) * 32)
        end
    end
    function c:Refresh()
        local T = ns.Trainer
        local encs = T and T:GetEncounters() or {}
        local data = Saved("trainer")
        local a = Accent("trainer")
        self.shown = {}
        for i = 1, min(3, #encs) do
            local e = encs[#encs - i + 1]     -- (the newest boss first)
            local ch = chip(i)
            local best
            local diffs = type(data.enc) == "table" and data.enc[e.id]
            for _, rec in pairs(type(diffs) == "table" and diffs or {}) do
                local bt = type(rec) == "table" and tonumber(rec.bestTime)
                if bt and (not best or bt < best) then best = bt end
            end
            local on = data.last == e.id
            ch.name:SetText(e.name or e.id)
            ch.name:SetTextColor(on and 1 or 0.81, on and 1 or 0.81, on and 1 or 0.81)
            ch.time:SetText(best and Clock(best) or "|cff8a8a8anot cleared|r")
            ch.dot:SetVertexColor(a[1], a[2], a[3], on and 1 or 0.35)
            ns.UI:SetEdgeColor(ch, a[1], a[2], a[3], on and 0.55 or 0.18)
            ch:Show()
            self.shown[i] = ch
        end
        for i = #self.shown + 1, #self.chips do self.chips[i]:Hide() end
        local w, h = self:GetSize()
        if w and w > 0 then self:Layout(w + 32, h + 64) end
    end
    return c
end

-- Azeromon: a little Elwynn of the game's own tiles (a house, its path, tall grass, trees) with the hero walking
-- down the path and back. Drawn into the poster's art box (clipped there).
-- (the meadow is wider than any poster: the front one grows to the whole tab when its game opens, and the scene
-- must still reach both edges; the house and its path sit in the middle at column SCENE_OX + 6)
local SCENE_C, SCENE_R, SCENE_OX, TILE = 32, 16, 9, 32
local function SceneTiles()
    local t = {}
    local function put(name, x, y) t[#t + 1] = { name, x, y } end
    for y = 0, SCENE_R - 1 do
        for x = 0, SCENE_C - 1 do put(((x * 7 + y * 3) % 5 == 0) and "grass2" or "grass1", x, y) end
    end
    local function big(prefix, x, y, w, h)
        for j = 0, h - 1 do for i = 0, w - 1 do put(prefix .. "_" .. i .. "_" .. j, x + i, y + j) end end
    end
    local function tall(x0, y0, w, h)
        for y = y0, y0 + h - 1 do
            for x = x0, x0 + w - 1 do
                local e = (y == y0 and "t" or y == y0 + h - 1 and "b" or "") .. (x == x0 and "l" or x == x0 + w - 1 and "r" or "")
                put(e == "" and "tall_c" or ("tall_" .. e), x, y)
            end
        end
    end
    -- the middle: the house, its path, the tall grass, trees and flowers round it
    local X = SCENE_OX
    for y = 7, SCENE_R - 1 do put("path_l", X + 5, y) put("path_c", X + 6, y) put("path_r", X + 7, y) end
    big("house", X + 4, 1, 5, 6)
    big("bigtree", X + 0, 2, 3, 3)
    big("bigtree", X + 10, 0, 3, 3)
    for _, p in ipairs({ { 9, 4 }, { 12, 4 }, { 1, 6 }, { 0, 9 }, { 12, 13 }, { 1, 14 } }) do put("tree", X + p[1], p[2]) end
    put("pine", X + 13, 6) put("pine", X + 2, 0) put("oak", X + 3, 11)
    tall(X + 9, 9, 4, 4)
    for _, p in ipairs({ { 3, 8 }, { 2, 12 }, { 8, 8 }, { 4, 14 }, { 9, 14 }, { 13, 10 } }) do put("flowers", X + p[1], p[2]) end
    put("sign", X + 8, 7)
    -- the meadow beyond, left and right
    big("bigtree", 1, 1, 3, 3)
    big("bigtree", 25, 8, 3, 3)
    big("bigtree", 28, 0, 3, 3)
    tall(1, 9, 4, 3)
    tall(24, 3, 3, 3)
    for _, p in ipairs({ { 6, 3 }, { 7, 7 }, { 0, 6 }, { 5, 13 }, { 2, 14 }, { 7, 11 }, { 23, 0 }, { 30, 5 },
                         { 23, 8 }, { 29, 12 }, { 24, 14 }, { 31, 9 } }) do put("tree", p[1], p[2]) end
    for _, p in ipairs({ { 5, 0 }, { 8, 12 }, { 22, 11 }, { 31, 14 }, { 27, 4 } }) do put("pine", p[1], p[2]) end
    for _, p in ipairs({ { 4, 5 }, { 0, 12 }, { 6, 9 }, { 3, 15 }, { 26, 13 }, { 28, 6 }, { 22, 3 }, { 30, 11 },
                         { 24, 11 } }) do put("flowers", p[1], p[2]) end
    put("rock", 8, 4) put("rock", 27, 15) put("oak", 31, 3)
    return t
end

local function PixelTexture(t, file)
    if not pcall(t.SetTexture, t, file, nil, nil, "NEAREST") then t:SetTexture(file) end
    if t.SetSnapToPixelGrid then pcall(t.SetSnapToPixelGrid, t, false) end
    if t.SetTexelSnappingBias then pcall(t.SetTexelSnappingBias, t, 0) end
end

COVERS.azeromon = function(parent, poster)
    local A = ns.AzeroAtlas
    local c = CreateFrame("Frame", nil, poster.artFrame)
    c:SetAllPoints(poster.artFrame)
    if not A then return c end
    local AH = ns.AzeroAtlasHeight or 256
    local E = 0.02 / 256
    c.world = CreateFrame("Frame", nil, c)
    c.world:SetSize(SCENE_C * TILE, SCENE_R * TILE)
    for _, tl in ipairs(SceneTiles()) do
        local i = A[tl[1]]
        if i then
            local t = c.world:CreateTexture(nil, "ARTWORK", nil, tl[1]:find("^grass") and -1 or (tl[1]:find("^path") and 0 or 1))
            PixelTexture(t, MEDIA .. "Azeromon\\atlas")
            local col, row = i % 16, floor(i / 16)
            t:SetTexCoord(col * 16 / 256 + E, (col + 1) * 16 / 256 - E, row * 16 / AH + E, (row + 1) * 16 / AH - E)
            t:SetSize(TILE, TILE)
            t:SetPoint("TOPLEFT", tl[2] * TILE, -tl[3] * TILE)
        end
    end
    c.hero = c.world:CreateTexture(nil, "ARTWORK", nil, 3)
    PixelTexture(c.hero, MEDIA .. "Azeromon\\chars")
    c.hero:SetSize(TILE, TILE)
    c.y, c.dir, c.pause, c.clock = 7.4, 1, 1.2, 0
    local function frame(face, f)
        local col, row = 3 + f, (face == "up") and 3 or 0
        c.hero:SetTexCoord(col * 16 / 256 + E, (col + 1) * 16 / 256 - E, row * 16 / 128 + E, (row + 1) * 16 / 128 - E)
    end
    function c:Layout(w, h)
        self.world:ClearAllPoints()
        -- the house and the path in the middle of the art, the roof just under the kicker
        self.world:SetPoint("TOPLEFT", self, "TOP", -(SCENE_OX + 6.5) * TILE, 0.4 * TILE)
    end
    function c:Refresh() end
    function c:Tick(elapsed)
        self.clock = self.clock + elapsed
        if self.pause > 0 then
            self.pause = self.pause - elapsed
            frame(self.dir > 0 and "down" or "up", 1)
        else
            self.y = self.y + self.dir * elapsed * 2.2
            if self.y >= 10.2 or self.y <= 7.2 then
                self.y = max(7.2, min(10.2, self.y))
                self.dir, self.pause = -self.dir, 1.6
            end
            local steps = { 0, 1, 2, 1 }
            frame(self.dir > 0 and "down" or "up", steps[floor(self.clock * 7) % 4 + 1])
        end
        self.hero:ClearAllPoints()
        self.hero:SetPoint("TOPLEFT", self.world, "TOPLEFT", (SCENE_OX + 6) * TILE, -floor(self.y * TILE + 0.5))
    end
    frame("down", 1)
    return c
end

---------------------------------------------------------------------------
-- A poster
---------------------------------------------------------------------------

-- The loading screen's painting sits between 18.5% and 79.5% of the stored square, shown at 4:3 (its frame's
-- corner pieces reach a little further in): crop it to w x h around the subject (cx across).
local function CropArt(tex, w, h, cx)
    if w <= 0 or h <= 0 then return end
    local fh = 0.535
    local fw = fh * 3 * w / (4 * h)
    if fw > 0.94 then fw, fh = 0.94, 0.94 * 4 * h / (3 * w) end
    local l = max(0.03, min(0.97 - fw, (cx or 0.5) - fw / 2))
    local t = 0.25 + (0.535 - fh) * 0.5
    tex:SetTexCoord(l, l + fw, t, t + fh)
end

local function SetFaces(p, keys)
    keys = keys or {}
    local n = min(4, #keys)
    for i = 1, 4 do
        local f = p.faces[i]
        if i <= n then
            f.tex:SetVertexColor(ClassRGB(keys[i]))
            f.fs:SetText(Short(keys[i]):sub(1, 1):upper())
            f:Show()
        else
            f:Hide()
        end
    end
    p.more:SetText(#keys > 4 and ("+" .. (#keys - 4)) or "")
    p.footText:ClearAllPoints()
    if n > 0 then
        p.footText:SetPoint("LEFT", #keys > 4 and p.more or p.faces[n], "RIGHT", #keys > 4 and 8 or 8, 0)
    else
        p.footText:SetPoint("LEFT", p.foot, "LEFT", 0, 0)
    end
end

-- A side poster: the title and the stat only, smaller. A front poster without a "who plays" line keeps its stat at
-- the bottom.
local function SetSideLook(p, side)
    local key = (side and "s" or "f") .. (p.hasFoot and "1" or "0")
    if p.side == side and p.lookKey == key then return end
    p.side, p.lookKey = side, key
    p.title:ClearAllPoints()
    p.stat:ClearAllPoints()
    if side or not p.hasFoot then
        p.stat:SetPoint("BOTTOMLEFT", p.over, "BOTTOMLEFT", 16, 16)
        p.stat:SetPoint("BOTTOMRIGHT", p.over, "BOTTOMRIGHT", -16, 16)
    else
        p.stat:SetPoint("BOTTOMLEFT", p.foot, "TOPLEFT", 0, 12)
        p.stat:SetPoint("BOTTOMRIGHT", p.foot, "TOPRIGHT", 0, 12)
    end
    if side then
        p.title:SetPoint("BOTTOMLEFT", p.stat, "TOPLEFT", 0, 6)
        p.title:SetPoint("BOTTOMRIGHT", p.stat, "TOPRIGHT", 0, 6)
        p.title:SetFont(p.titleFont, 17, p.titleFlags)
    else
        p.title:SetPoint("BOTTOMLEFT", p.desc, "TOPLEFT", 0, 7)
        p.title:SetPoint("BOTTOMRIGHT", p.desc, "TOPRIGHT", 0, 7)
        p.title:SetFont(p.titleFont, 26, p.titleFlags)
    end
    p.desc:SetShown(not side)
    p.rule:SetShown(not side)
    p.foot:SetShown(not side and p.hasFoot)
end

-- The sheen: a light band crossing the poster once (two ADD gradient halves, cut at the poster's edges by hand).
local function PlaceSheen(p, e)
    local w = p:GetWidth() or 0
    local bw = 90
    local c = -bw / 2 + (w + bw) * e
    local a = 0.13
    for i, half in ipairs({ { c - bw / 2, c, 0, a }, { c, c + bw / 2, a, 0 } }) do
        local tex = p["sheen" .. i]
        local x0, x1, a0, a1 = half[1], half[2], half[3], half[4]
        local l, r = max(0, x0), min(w, x1)
        if r - l < 0.5 then
            tex:Hide()
        else
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", p, "TOPLEFT", l, 0)
            tex:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", l, 0)
            tex:SetWidth(r - l)
            local span = x1 - x0
            Gradient(tex, "HORIZONTAL", 1, 1, 1, a0 + (a1 - a0) * (l - x0) / span, 1, 1, 1, a0 + (a1 - a0) * (r - x0) / span)
            tex:Show()
        end
    end
end

local function Sheen(p)
    if p.sheenT then return end
    p.sheenT = 0
end

local function PaintEdge(p)
    local a = Accent(p.id)
    local hot = p.off == 0 and (p.hover or p.live)
    if p.live and p.off == 0 then
        Gradient(p.edge, "HORIZONTAL", 1, 0.29, 0.24, 1, 1, 0.82, 0, 1)
        ns.UI:SetEdgeColor(p.top, 1, 0.29, 0.24, 0.5)
    elseif p.off == 0 then
        p.edge:SetColorTexture(a[1], a[2], a[3], 1)
        ns.UI:SetEdgeColor(p.top, a[1], a[2], a[3], hot and 0.75 or 0.45)
    else
        p.edge:SetColorTexture(a[1], a[2], a[3], 0)
        ns.UI:SetEdgeColor(p.top, 1, 1, 1, p.hover and 0.14 or 0.07)
    end
    p.dim:SetAlpha(p.off == 0 and 0 or (p.hover and SIDE_DIM * 0.6 or SIDE_DIM))
end

local OpenGame, Turn
local SoftShadow

-- A soft shadow round frame f: a 9-slice of the radial texture's falloff (its quarters are the round corners, its
-- middle row and column the sides), black at alpha, fading over r px; dropped dy px and starting inset px inside
-- the frame. (Radial.tga is solid to a quarter of its radius and gone at ~81%: only that band is used, so the
-- whole r is a smooth S-shaped fade.)
local SH_IN, SH_OUT = 0.5 - 0.125, 0.5 - 0.406      -- texcoords of the fade's start / end in the top-left quarter
SoftShadow = function(f, r, alpha, dy, inset)
    local function piece(l, rgt, t, b)
        local tex = f:CreateTexture(nil, "BACKGROUND", nil, -8)
        tex:SetTexture(RADIAL)
        tex:SetVertexColor(0, 0, 0, alpha)
        tex:SetTexCoord(l, rgt, t, b)
        return tex
    end
    local m1, m2 = 0.499, 0.501
    local a, b, c, d = SH_OUT, SH_IN, 1 - SH_IN, 1 - SH_OUT
    local L, R, T, B = inset, -inset, -inset - dy, inset - dy     -- the shadow's inner rectangle, from f's edges
    local tl = piece(a, b, a, b)
    tl:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", L, T)
    tl:SetSize(r, r)
    local tr = piece(c, d, a, b)
    tr:SetPoint("BOTTOMLEFT", f, "TOPRIGHT", R, T)
    tr:SetSize(r, r)
    local bl = piece(a, b, c, d)
    bl:SetPoint("TOPRIGHT", f, "BOTTOMLEFT", L, B)
    bl:SetSize(r, r)
    local br = piece(c, d, c, d)
    br:SetPoint("TOPLEFT", f, "BOTTOMRIGHT", R, B)
    br:SetSize(r, r)
    local top = piece(m1, m2, a, b)
    top:SetPoint("BOTTOMLEFT", tl, "BOTTOMRIGHT")
    top:SetPoint("TOPRIGHT", tr, "TOPLEFT")
    local bottom = piece(m1, m2, c, d)
    bottom:SetPoint("TOPLEFT", bl, "TOPRIGHT")
    bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
    local left = piece(a, b, m1, m2)
    left:SetPoint("TOPRIGHT", tl, "BOTTOMRIGHT")
    left:SetPoint("BOTTOMLEFT", bl, "TOPLEFT")
    local right = piece(c, d, m1, m2)
    right:SetPoint("TOPLEFT", tr, "BOTTOMLEFT")
    right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
    local mid = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    mid:SetColorTexture(0, 0, 0, alpha)
    mid:SetPoint("TOPLEFT", tl, "BOTTOMRIGHT")
    mid:SetPoint("BOTTOMRIGHT", br, "TOPLEFT")
end

local function CreatePoster(i, def)
    local p = CreateFrame("Button", nil, carousel)
    p.id, p.def, p.index = def.id, def, i
    p:RegisterForClicks("LeftButtonUp")
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    p.bg:SetColorTexture(BASE[1], BASE[2], BASE[3], 1)
    -- a soft drop shadow under the poster (below its fill, so only the part outside shows): a broad, faint one
    -- falling well below it and a tight one hugging its edge
    SoftShadow(p, 56, 0.42, 14, 12)
    SoftShadow(p, 12, 0.3, 2, 2)

    -- the art (a loading screen, or the cover's own scene), clipped to the top of the poster
    p.artFrame = CreateFrame("Frame", nil, p)
    -- (1 px inside the poster's border: a clip edge is rounded to whole pixels on its own, and while a poster moves
    -- by fractions of a pixel a sliver of the bright art showed past the dark / the border at its side)
    p.artFrame:SetPoint("TOPLEFT", 1, -1)
    p.artFrame:SetPoint("TOPRIGHT", -1, -1)
    p.artFrame:SetFrameLevel(p:GetFrameLevel() + 1)
    pcall(p.artFrame.SetClipsChildren, p.artFrame, true)
    p.art = p.artFrame:CreateTexture(nil, "BACKGROUND")
    p.art:SetAllPoints()

    -- over the art: the shades, the kicker, the cover, the text
    p.over = CreateFrame("Frame", nil, p)
    p.over:SetAllPoints()
    p.over:SetFrameLevel(p:GetFrameLevel() + 6)
    p.topShade = p.over:CreateTexture(nil, "BACKGROUND")
    p.topShade:SetPoint("TOPLEFT")
    p.topShade:SetPoint("TOPRIGHT")
    Gradient(p.topShade, "VERTICAL", BASE[1], BASE[2], BASE[3], 0, BASE[1], BASE[2], BASE[3], 0.6)
    p.lowShade = p.over:CreateTexture(nil, "BACKGROUND")
    -- (it reaches 2 px past the art's foot, solid there, so no line of art shows above the title mid-animation)
    p.lowShade:SetPoint("BOTTOMLEFT", p.artFrame, "BOTTOMLEFT", -1, -2)
    p.lowShade:SetPoint("BOTTOMRIGHT", p.artFrame, "BOTTOMRIGHT", 1, -2)
    Gradient(p.lowShade, "VERTICAL", BASE[1], BASE[2], BASE[3], 1, BASE[1], BASE[2], BASE[3], 0)

    p.kicker = Label(p.over, 9.5)
    p.kicker:SetPoint("TOPLEFT", 16, -15)
    p.kicker:SetTextColor(0.84, 0.84, 0.84)
    p.dot = p.over:CreateTexture(nil, "OVERLAY")
    p.dot:SetTexture(CIRCLE)
    p.dot:SetSize(7, 7)
    p.dot:SetVertexColor(1, 0.29, 0.24)
    p.dot:SetPoint("TOPLEFT", 16, -16)
    p.dot:Hide()
    p.dotGlow = p.over:CreateTexture(nil, "ARTWORK")
    p.dotGlow:SetTexture(RADIAL)
    p.dotGlow:SetBlendMode("ADD")
    p.dotGlow:SetVertexColor(1, 0.29, 0.24)
    p.dotGlow:SetPoint("CENTER", p.dot, "CENTER")
    p.dotGlow:SetSize(22, 22)
    p.dotGlow:Hide()

    -- the words (title, line, stat, who plays) on their own frame: it fades while a poster turns between front and
    -- side, so the switch of size happens unseen
    p.words = CreateFrame("Frame", nil, p.over)
    p.words:SetAllPoints()
    p.foot = CreateFrame("Frame", nil, p.words)
    p.foot:SetHeight(20)
    p.foot:SetPoint("BOTTOMLEFT", 16, 16)
    p.foot:SetPoint("BOTTOMRIGHT", -16, 16)
    p.faces = {}
    for k = 1, 4 do
        local f = CreateFrame("Frame", nil, p.foot)
        f:SetSize(18, 18)
        f:SetPoint("LEFT", (k - 1) * 14, 0)
        f:SetFrameLevel(p.foot:GetFrameLevel() + 6 - k)
        f.ring = f:CreateTexture(nil, "BACKGROUND")
        f.ring:SetTexture(CIRCLE)
        f.ring:SetVertexColor(BASE[1], BASE[2], BASE[3])
        f.ring:SetPoint("TOPLEFT", -2, 2)
        f.ring:SetPoint("BOTTOMRIGHT", 2, -2)
        f.tex = f:CreateTexture(nil, "ARTWORK")
        f.tex:SetTexture(CIRCLE)
        f.tex:SetAllPoints()
        f.fs = Label(f, 9.5, "GameFontHighlightSmall")
        f.fs:SetPoint("CENTER", 0, 0)
        f.fs:SetTextColor(0, 0, 0, 0.8)
        f.fs:SetShadowOffset(0, 0)
        f:Hide()
        p.faces[k] = f
    end
    p.more = Label(p.foot, 10.5)
    p.more:SetPoint("LEFT", p.faces[4], "RIGHT", 8, 0)
    p.more:SetTextColor(0.62, 0.62, 0.62)
    p.footText = Label(p.foot, 11)
    p.footText:SetTextColor(0.81, 0.81, 0.81)

    p.stat = Label(p.words, 12)
    p.stat:SetTextColor(0.74, 0.74, 0.74)
    p.rule = p.words:CreateTexture(nil, "ARTWORK")
    p.rule:SetHeight(1)
    p.rule:SetPoint("BOTTOMLEFT", p.stat, "TOPLEFT", 0, 12)
    p.rule:SetPoint("BOTTOMRIGHT", p.stat, "TOPRIGHT", 0, 12)
    local a = Accent(def.id)
    Gradient(p.rule, "HORIZONTAL", a[1], a[2], a[3], 0.6, a[1], a[2], a[3], 0)
    p.desc = Label(p.words, 11)
    p.desc:SetWordWrap(true)
    p.desc:SetJustifyV("BOTTOM")
    p.desc:SetSpacing(3)
    p.desc:SetTextColor(0.65, 0.65, 0.65)
    p.desc:SetPoint("BOTTOMLEFT", p.rule, "TOPLEFT", 0, 13)
    p.desc:SetWidth(FRONT_W - 32)          -- (fixed: it never re-wraps while the poster grows)
    p.title = Label(p.words, 26, "GameFontHighlightLarge")
    local font, _, flags = p.title:GetFont()
    p.titleFont, p.titleFlags = font, flags

    -- the live cover
    local make = COVERS[def.id]
    if make then
        local ok, cover = xpcall(function() return make(p.over, p) end, geterrorhandler())
        if ok and cover then p.cover = cover end
    end
    if not p.cover then
        local c = CreateFrame("Frame", nil, p.over)
        c.icon = c:CreateTexture(nil, "ARTWORK")
        c.icon:SetPoint("CENTER")
        c.icon:SetSize(64, 64)
        c.icon:SetTexture(def.icon)
        c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        function c:Layout() end
        function c:Refresh() end
        p.cover = c
    end
    if p.cover:GetParent() == p.over then
        p.cover:SetPoint("TOP", p.over, "TOP", 0, -52)
    end

    -- on top: the side poster's dark, the edges, the sheen
    p.top = CreateFrame("Frame", nil, p)
    p.top:SetAllPoints()
    p.top:SetFrameLevel(p:GetFrameLevel() + 20)
    p.dim = p.top:CreateTexture(nil, "BACKGROUND")
    p.dim:SetAllPoints()
    p.dim:SetColorTexture(0, 0, 0, 1)
    ns.UI:AddEdges(p.top, "BORDER")
    p.edge = p.top:CreateTexture(nil, "ARTWORK")
    p.edge:SetPoint("TOPLEFT")
    p.edge:SetPoint("TOPRIGHT")
    p.edge:SetHeight(2)
    for k = 1, 2 do
        local t = p.top:CreateTexture(nil, "OVERLAY")
        t:SetBlendMode("ADD")
        t:Hide()
        p["sheen" .. k] = t
    end

    p:SetScript("OnClick", function(self)
        if anim then return end
        if self.off == 0 then OpenGame(self.id, true) else Turn(self.index) end
    end)
    p:SetScript("OnEnter", function(self)
        self.hover = true
        PaintEdge(self)
        if self.off == 0 then Sheen(self) end
    end)
    p:SetScript("OnLeave", function(self)
        self.hover = nil
        PaintEdge(self)
    end)
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(_, d) if not anim then Turn(cur - d) end end)
    p.side = nil
    SetSideLook(p, false)
    return p
end

local function FillPoster(p)
    local info = Info(p.id)
    p.info = info
    p.live = info.live
    p.title:SetText(p.def.name)
    p.desc:SetText(p.def.tagline or p.def.desc or "")
    p.kicker:SetText(info.kicker or "")
    p.kicker:ClearAllPoints()
    p.kicker:SetPoint("TOPLEFT", info.live and 31 or 16, -15)
    p.dot:SetShown(info.live and true or false)
    p.dotGlow:SetShown(info.live and true or false)
    p.stat:SetText(info.stat or "")
    p.footText:SetText(info.foot or "")
    SetFaces(p, info.faces)
    p.hasFoot = (info.foot or "") ~= ""
    SetSideLook(p, p.side or false)
    if p.id ~= "azeromon" then
        local key = info.art or "kara"
        p.art:SetTexture(LOADSCREEN[key] or LOADSCREEN.kara)
        p.art:SetVertexColor(0.78, 0.78, 0.8)
        p.artKey = key
        p.art:Show()
    else
        p.art:Hide()
    end
    if p.cover.Refresh then xpcall(function() p.cover:Refresh() end, geterrorhandler()) end
    PaintEdge(p)
end

-- Places poster p at x, y (from the carousel's top left), w x h.
local function Place(p, x, y, w, h)
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", carousel, "TOPLEFT", x, -y)
    p:SetSize(w, h)
    local artH = floor(h * 0.76)
    p.artFrame:SetHeight(artH - 1)
    p.topShade:SetHeight(max(1, h * 0.14))
    p.lowShade:SetHeight(max(1, artH * 0.4 + 2))
    if p.art:IsShown() then CropArt(p.art, w - 2, artH - 1, FOCUS[p.artKey]) end
    if p.cover.Layout then p.cover:Layout(w, artH - 52) end
    if p.sheenT then PlaceSheen(p, p.sheenT) end
end

---------------------------------------------------------------------------
-- The carousel
---------------------------------------------------------------------------

-- The rectangle and dark of the slot `off` places from the front (0 front, -1 left, 1 right, further = off stage).
local function Slot(off)
    local fh = H - 46
    local sh = floor(fh * SIDE_K)
    if off == 0 then return (W - FRONT_W) / 2, 10, FRONT_W, fh, 0 end
    local y = 10 + (fh - sh) / 2
    if off < 0 then return 22 - (-off - 1) * (SIDE_W + 40), y, SIDE_W, sh, -off > 1 and 1 or 0 end
    return W - 22 - SIDE_W + (off - 1) * (SIDE_W + 40), y, SIDE_W, sh, off > 1 and 1 or 0
end

local function OffsetOf(i)
    local n = #posters
    local off = (i - cur) % n
    if off > n / 2 then off = off - n end
    return off
end

local auraFrom, auraTo     -- the room's glow: two textures crossfading to the front game's colour

local function SetAura(id, instant)
    local a = Accent(id)
    auraFrom, auraTo = auraTo, auraFrom
    auraTo:SetVertexColor(a[1], a[2], a[3])
    auraTo.target = 0.22
    auraFrom.target = 0
    if instant then
        auraTo:SetAlpha(0.22)
        auraFrom:SetAlpha(0)
    end
end

local function PaintDots()
    for i, d in ipairs(dots) do
        local on = i == cur
        local a = Accent(posters[i] and posters[i].id)
        d.tex:SetWidth(on and 20 or 6)
        d.mid:SetShown(on)
        d.capR:SetShown(on)
        for _, t in ipairs({ d.capL, d.capR, d.mid }) do
            if on then t:SetVertexColor(a[1], a[2], a[3], 1) else t:SetVertexColor(1, 1, 1, 0.24) end
        end
    end
end

-- Raises / lowers frame f and everything in it by the same steps (a frame's level doesn't carry its children).
local function ShiftLevel(f, d)
    f:SetFrameLevel(max(0, f:GetFrameLevel() + d))
    for _, ch in ipairs({ f:GetChildren() }) do ShiftLevel(ch, d) end
end

-- Front poster above the sides (they cross while the carousel turns).
local function SetPosterLevel(p, front)
    local want = carousel:GetFrameLevel() + (front and 30 or 5)
    local d = want - p:GetFrameLevel()
    if d ~= 0 then ShiftLevel(p, d) end
end

-- Puts every poster where it belongs (no animation).
local function LayoutCarousel()
    if not carousel then return end
    Size()
    for i, p in ipairs(posters) do
        local off = OffsetOf(i)
        p.off = off
        local x, y, w, h, gone = Slot(off)
        SetSideLook(p, off ~= 0)
        p.words:SetAlpha(1)
        p.over:SetAlpha(1)
        Place(p, x, y, w, h)
        p:SetAlpha(gone == 1 and 0 or 1)
        p.cover:SetAlpha(1)
        p.cover:SetShown(off == 0 or not p.cover.frontOnly)
        p:SetShown(abs(off) <= 1)
        SetPosterLevel(p, off == 0)
        PaintEdge(p)
    end
    local show = #posters > 1
    arrows[1]:SetShown(show)
    arrows[2]:SetShown(show)
    PaintDots()
end

-- Turns the carousel so poster i is in front (animated).
function Turn(i)
    local n = #posters
    if n < 2 or not carousel:IsVisible() then
        cur = ((i - 1) % max(1, n)) + 1
        LayoutCarousel()
        return
    end
    i = ((i - 1) % n) + 1
    if i == cur then return end
    local from = {}
    for k, p in ipairs(posters) do
        local x, y, w, h = Slot(p.off or OffsetOf(k))
        from[k] = { x, y, w, h, p.off or OffsetOf(k) }
    end
    cur = i
    local to = {}
    for k, p in ipairs(posters) do
        local off = OffsetOf(k)
        local x, y, w, h = Slot(off)
        to[k] = { x, y, w, h, off }
        p.off = off
        p:Show()
        SetPosterLevel(p, off == 0)
        p.hover = nil
        PaintEdge(p)
    end
    SetAura(posters[cur].id)
    PaintDots()
    anim = { t = 0, dur = TURN_TIME, kind = "turn", from = from, to = to }
end

local function StepTurn(e)
    for k, p in ipairs(posters) do
        local a, b = anim.from[k], anim.to[k]
        -- a poster wrapping round (left edge to right edge) fades out and back in instead of crossing the front
        local wrap = abs(b[5] - a[5]) > 1
        local x, y, w, h
        if wrap then
            x, y, w, h = b[1], b[2], b[3], b[4]
            p:SetAlpha(e)
        else
            x, y, w, h = Lerp(a[1], b[1], e), Lerp(a[2], b[2], e), Lerp(a[3], b[3], e), Lerp(a[4], b[4], e)
            p:SetAlpha(abs(b[5]) > 1 and (1 - e) or 1)
        end
        Place(p, x, y, w, h)
        if (a[5] == 0) ~= (b[5] == 0) then
            -- front <-> side: the words fade out, swap size at the midpoint, fade back in
            if e >= 0.5 then SetSideLook(p, b[5] ~= 0) end
            p.words:SetAlpha(e < 0.5 and (1 - 2 * e) or (2 * e - 1))
        end
        local frontness = b[5] == 0 and e or (a[5] == 0 and 1 - e or 0)
        p.dim:SetAlpha(SIDE_DIM * (1 - frontness))
        if p.cover.frontOnly then
            p.cover:SetShown(frontness > 0)
            p.cover:SetAlpha(frontness)
        end
    end
end

local function EndTurn()
    LayoutCarousel()
    Sheen(posters[cur])
end

---------------------------------------------------------------------------
-- A game, opened: the strip and the game's panel
---------------------------------------------------------------------------

local function StripFill(id)
    local def = ns.Games:Get(id)
    if not def or not strip then return end
    strip.icon:SetTexture(def.icon)
    strip.name:SetText(def.name)
    local a = Accent(id)
    Gradient(strip.accent, "HORIZONTAL", a[1], a[2], a[3], 0.9, a[1], a[2], a[3], 0)
    local info = Info(id)
    strip.playing:SetText(info.foot and info.foot:find("playing") and info.foot or "")
end

local function HideGamePanel()
    if selected and panels[selected] then
        local old = panels[selected]
        old:Hide()
        if old.OnGameHidden then pcall(old.OnGameHidden, old) end
    end
end

-- The game's panel (created once), placed on the stage; nil when it can't be made.
local function GamePanel(id)
    local def = ns.Games:Get(id)
    if not def or not stage then return nil end
    local p = panels[id]
    if not p then
        local ok, frame = xpcall(function() return def.create(stage) end, geterrorhandler())
        if not ok or not frame then return nil end
        p = frame
        p:ClearAllPoints()
        p:SetAllPoints(stage)
        panels[id] = p
    end
    return p
end

-- The strip and the stage, dy px off their places (they glide in / out), at alpha a.
local function PlaceGame(dyStrip, dyStage, a)
    strip:ClearAllPoints()
    strip:SetPoint("TOPLEFT", 0, dyStrip)
    strip:SetPoint("TOPRIGHT", 0, dyStrip)
    strip:SetAlpha(a)
    stage:ClearAllPoints()
    stage:SetPoint("TOPLEFT", 0, -STRIP_H - dyStage)
    stage:SetPoint("BOTTOMRIGHT", 0, -dyStage)
    stage:SetAlpha(a)
end

-- Shows game id on the stage at once (the carousel goes).
local function ShowGamePanel(id)
    if selected ~= id then HideGamePanel() end
    local p = GamePanel(id)
    if not p then return false end
    selected = id
    ns.Games:GetData(id).opened = time()
    carousel:Hide()
    carousel:SetAlpha(1)
    PlaceGame(0, 0, 1)
    strip:Show()
    stage:Show()
    StripFill(id)
    p:SetAlpha(1)
    p:Show()
    if p.OnGameShown then xpcall(function() p:OnGameShown() end, geterrorhandler()) end
    return true
end

-- The poster's look while it is the doorway into its game: its words / cover / shading at alpha `words`, the
-- painting darkened by `dark` (0..1).
local function DoorLook(p, words, dark)
    p.over:SetAlpha(words)
    p.dim:SetAlpha(OPEN_DARK * dark)
end

local function InOut(t) -- ease-in-out cubic
    if t < 0.5 then return 4 * t * t * t end
    t = -2 * t + 2
    return 1 - t * t * t / 2
end
local function Phase(t, from, to) return max(0, min(1, (t - from) / (to - from))) end

-- Opens game id: animated (the front poster grows into the tab and darkens while its words go, its neighbours
-- drift away, then the game rises in under the strip as the poster dissolves) or at once.
function OpenGame(id, animate)
    local idx
    for i, p in ipairs(posters) do if p.id == id then idx = i end end
    if not idx then return end
    if not (animate and carousel:IsVisible()) then
        cur = idx
        LayoutCarousel()
        ShowGamePanel(id)
        return
    end
    -- make the game now (a first build can take a moment: better at the click than mid-flight)
    if selected and selected ~= id then HideGamePanel() end
    local panel = GamePanel(id)
    if not panel then return end
    local from = {}
    for k, p in ipairs(posters) do
        local x, y, w, h = Slot(p.off)
        from[k] = { x, y, w, h, p.off }
    end
    for _, tex in ipairs({ auraFrom, auraTo }) do tex.target = 0 end
    StripFill(id)
    PlaceGame(0, 14, 0)
    strip:Show()
    stage:Show()
    panel:SetAlpha(1)
    panel:Show()
    anim = { t = 0, dur = OPEN_TIME, kind = "open", from = from, id = id, panel = panel }
end

local function StepOpen(t)
    local g = InOut(Phase(t, 0, 0.66))          -- the poster grows
    local words = 1 - Phase(t, 0, 0.32)          -- its words go first
    local side = Ease(Phase(t, 0, 0.6))          -- the neighbours drift away
    local r = Ease(Phase(t, 0.45, 1))            -- the game comes in, the poster dissolves
    for k, p in ipairs(posters) do
        local a = anim.from[k]
        if a[5] == 0 then
            Place(p, Lerp(a[1], 0, g), Lerp(a[2], 0, g), Lerp(a[3], W, g), Lerp(a[4], H, g))
            DoorLook(p, words, g)
        else
            Place(p, a[1] + (a[5] < 0 and -70 or 70) * side, a[2], a[3], a[4])
            p:SetAlpha(1 - side)
        end
    end
    carousel:SetAlpha(1 - r)
    PlaceGame(0, 14 * (1 - r), r)
end

-- The open's end (also when the tab hides mid-way): the game in place, the carousel put back for later.
local function EndOpen()
    local id = anim and anim.id
    anim = nil
    if not id then return end
    for _, p in ipairs(posters) do
        p.over:SetAlpha(1)
        p:SetAlpha(1)
    end
    ShowGamePanel(id)
end

-- Back to the carousel: the game fades and sinks, the darkened painting shrinks back into its slot and brightens,
-- its words return, its neighbours glide back in.
local function BackToCarousel()
    if not selected then return end
    local leaving = panels[selected]
    selected = nil
    for _, p in ipairs(posters) do FillPoster(p) end
    LayoutCarousel()
    carousel:Show()
    carousel:SetAlpha(1)
    SetAura(posters[cur] and posters[cur].id, false)
    local to = {}
    for k, p in ipairs(posters) do
        local x, y, w, h = Slot(p.off)
        to[k] = { x, y, w, h, p.off }
        if p.off == 0 then
            Place(p, 0, 0, W, H)
            DoorLook(p, 0, 1)
        elseif abs(p.off) == 1 then
            p:SetAlpha(0)
        end
    end
    anim = { t = 0, dur = BACK_TIME, kind = "back", to = to, leaving = leaving }
end

local function StepBack(t)
    local out = Ease(Phase(t, 0, 0.35))           -- the game goes
    local g = InOut(Phase(t, 0.1, 0.8))           -- the poster shrinks back
    local words = Ease(Phase(t, 0.6, 1))          -- its words return
    local side = Ease(Phase(t, 0.35, 1))          -- the neighbours glide in
    PlaceGame(0, 10 * out, 1 - out)
    for k, p in ipairs(posters) do
        local b = anim.to[k]
        if b[5] == 0 then
            Place(p, Lerp(0, b[1], g), Lerp(0, b[2], g), Lerp(W, b[3], g), Lerp(H, b[4], g))
            DoorLook(p, words, 1 - g)
        elseif abs(b[5]) == 1 then
            Place(p, b[1] + (b[5] < 0 and -70 or 70) * (1 - side), b[2], b[3], b[4])
            p:SetAlpha(side)
        end
    end
end

local function EndBack()
    local leaving = anim and anim.leaving
    anim = nil
    if leaving then
        leaving:Hide()
        if leaving.OnGameHidden then pcall(leaving.OnGameHidden, leaving) end
    end
    strip:Hide()
    stage:Hide()
    PlaceGame(0, 0, 1)
    for _, p in ipairs(posters) do p.over:SetAlpha(1) end
    LayoutCarousel()
    Sheen(posters[cur])
end

---------------------------------------------------------------------------
-- The driver: animations, the covers, the room's glow and motes (only while the tab shows)
---------------------------------------------------------------------------

local motes = {}
local refreshIn = 0

local paused        -- (tests and the audit's frame-by-frame views: animations wait for GamesUI:StepAnim)

local function OnUpdate(_, elapsed, stepping)
    elapsed = min(elapsed or 0, 0.1)
    if anim and (stepping or not paused) then
        anim.t = anim.t + elapsed
        local t = min(1, anim.t / anim.dur)
        local e = Ease(t)
        if anim.kind == "turn" then StepTurn(e)
        elseif anim.kind == "open" then StepOpen(t)
        elseif anim.kind == "back" then StepBack(t)
        elseif anim.kind == "fadein" then anim.frame:SetAlpha(e) end
        if t >= 1 then
            local kind = anim.kind
            if kind == "turn" then anim = nil EndTurn()
            elseif kind == "open" then EndOpen()
            elseif kind == "back" then EndBack()
            else anim.frame:SetAlpha(1) anim = nil end
        end
    end
    if not carousel:IsShown() then return end
    for _, tex in ipairs({ auraFrom, auraTo }) do
        local a = tex:GetAlpha()
        local d = (tex.target or 0) - a
        if abs(d) > 0.002 then tex:SetAlpha(a + d * min(1, elapsed * 6)) end
    end
    for _, m in ipairs(motes) do
        m.y = m.y + m.v * elapsed
        if m.y > H + 4 then m.y, m.x = -4, (m.x + 211) % max(1, W) end
        m.tex:ClearAllPoints()
        m.tex:SetPoint("BOTTOMLEFT", carousel, "BOTTOMLEFT", m.x + sin(m.y / 40 + m.ph) * 6, m.y)
    end
    for _, p in ipairs(posters) do
        if p:IsShown() then
            if p.cover.Tick then p.cover:Tick(elapsed) end
            if p.sheenT then
                p.sheenT = p.sheenT + elapsed / 0.75
                if p.sheenT >= 1 then
                    p.sheenT = nil
                    p.sheen1:Hide()
                    p.sheen2:Hide()
                else
                    PlaceSheen(p, p.sheenT)
                end
            end
            if p.live and p.off == 0 then p.dotGlow:SetAlpha(0.35 + 0.35 * sin(GetTime() * 4)) end
        end
    end
    -- stats and covers change on their own (a square fills, someone starts playing): refresh every few seconds
    refreshIn = refreshIn - elapsed
    if refreshIn <= 0 and not anim then
        refreshIn = 3
        for _, p in ipairs(posters) do FillPoster(p) end
    end
end

---------------------------------------------------------------------------
-- The tab
---------------------------------------------------------------------------

local function BuildPosters()
    local games = ns.Games:GetList()
    for i, def in ipairs(games) do
        if not posters[i] or posters[i].id ~= def.id then
            if posters[i] then posters[i]:Hide() end
            posters[i] = CreatePoster(i, def)
        end
        posters[i].def, posters[i].index = def, i
    end
    for i = #games + 1, #posters do
        posters[i]:Hide()
        posters[i] = nil
    end
    for i = #posters + 1, #dots do dots[i]:Hide() end
    for i = 1, #posters do
        local d = dots[i]
        if not d then
            d = CreateFrame("Button", nil, carousel)
            d:SetSize(22, 14)
            -- a rounded pill: two circles and the bar between their centres
            d.tex = CreateFrame("Frame", nil, d)
            d.tex:SetHeight(6)
            d.tex:SetPoint("CENTER")
            d.capL = d.tex:CreateTexture(nil, "ARTWORK")
            d.capL:SetTexture(CIRCLE)
            d.capL:SetSize(6, 6)
            d.capL:SetPoint("LEFT")
            d.capR = d.tex:CreateTexture(nil, "ARTWORK")
            d.capR:SetTexture(CIRCLE)
            d.capR:SetSize(6, 6)
            d.capR:SetPoint("RIGHT")
            d.mid = d.tex:CreateTexture(nil, "ARTWORK")
            d.mid:SetTexture("Interface\\Buttons\\WHITE8X8")
            d.mid:SetPoint("TOPLEFT", 3, 0)
            d.mid:SetPoint("BOTTOMRIGHT", -3, 0)
            d:SetScript("OnClick", function(self) if not anim then Turn(self.index) end end)
            dots[i] = d
        end
        d.index = i
        d:Show()
    end
    local total = #posters * 22
    for i = 1, #posters do
        dots[i]:ClearAllPoints()
        dots[i]:SetPoint("BOTTOMLEFT", carousel, "BOTTOM", -total / 2 + (i - 1) * 22, 8)
    end
    if cur > #posters then cur = 1 end
end

-- The poster in front when the tab opens: Bingo while a game runs, else the game opened last.
local function PickFront()
    local best, bestT
    for i, p in ipairs(posters) do
        if p.id == "bingo" and ns.Bingo and ns.Bingo:IsActive() then return i end
        local t = tonumber(Saved(p.id).opened)
        if t and (not bestT or t > bestT) then best, bestT = i, t end
    end
    return best or cur
end

local function Refresh()
    if not root then return end
    BuildPosters()
    for _, p in ipairs(posters) do FillPoster(p) end
    if not selected then LayoutCarousel() end
end

function GamesUI:CreatePanel(parent)
    root = CreateFrame("Frame", nil, parent)
    local bg = root:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    Gradient(bg, "VERTICAL", 0.055, 0.055, 0.063, 1, 0.098, 0.098, 0.114, 1)

    carousel = CreateFrame("Frame", nil, root)
    carousel:SetAllPoints()
    -- nothing the carousel draws may leave the page: posters sliding out, their shadows, a poster growing
    pcall(carousel.SetClipsChildren, carousel, true)
    carousel:EnableMouseWheel(true)
    carousel:SetScript("OnMouseWheel", function(_, d) if not anim then Turn(cur - d) end end)
    local glows = {}
    for i = 1, 2 do
        local t = carousel:CreateTexture(nil, "BACKGROUND", nil, -6)
        t:SetTexture(RADIAL)
        t:SetBlendMode("ADD")
        t:SetSize(760, 500)                       -- (its top edge on the page's: it stays inside too)
        t:SetPoint("CENTER", carousel, "TOP", 0, -250)
        t:SetAlpha(0)
        glows[i] = t
    end
    auraFrom, auraTo = glows[1], glows[2]
    for i = 1, 14 do
        local t = carousel:CreateTexture(nil, "BACKGROUND", nil, -5)
        t:SetTexture(RADIAL)
        local s = 2 + (i % 3)
        t:SetSize(s, s)
        t:SetVertexColor(1, 0.92, 0.75, 0.10 + (i % 4) * 0.04)
        motes[i] = { tex = t, x = (i * 97) % FALLBACK_W, y = (i * 53) % FALLBACK_H, v = 4 + (i % 5) * 1.6, ph = i }
    end
    dots = {}
    arrows = {}
    for k, right in ipairs({ false, true }) do
        local b = ns.UI:CreateArrowButton(carousel, right, 28, 28, function()
            if not anim then Turn(cur + (right and 1 or -1)) end
        end)
        b:SetPoint(right and "RIGHT" or "LEFT", carousel, right and "RIGHT" or "LEFT", right and -4 or 4, 0)
        b:SetFrameLevel(carousel:GetFrameLevel() + 80)
        local fill = b:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        fill:SetColorTexture(0, 0, 0, 0.4)
        arrows[k] = b
    end

    -- an open game: the strip and the stage under it
    strip = CreateFrame("Frame", nil, root)
    strip:SetPoint("TOPLEFT")
    strip:SetPoint("TOPRIGHT")
    strip:SetHeight(STRIP_H)
    local sbg = strip:CreateTexture(nil, "BACKGROUND")
    sbg:SetAllPoints()
    sbg:SetColorTexture(0.078, 0.078, 0.09, 1)
    local line = strip:CreateTexture(nil, "BORDER")
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetHeight(1)
    line:SetColorTexture(1, 1, 1, 0.07)
    strip.accent = strip:CreateTexture(nil, "ARTWORK")
    strip.accent:SetPoint("BOTTOMLEFT")
    strip.accent:SetSize(160, 1)
    local back = CreateFrame("Button", nil, strip)
    back:SetHeight(STRIP_H)
    back.chev = back:CreateTexture(nil, "ARTWORK")
    back.chev:SetSize(10, 10)
    back.chev:SetPoint("LEFT", 12, 0)
    ns.UI:SetChevron(back.chev, false)
    back.chev:SetVertexColor(0.63, 0.63, 0.63)
    back.fs = Label(back, 9.5)
    back.fs:SetPoint("LEFT", back.chev, "RIGHT", 6, 0)
    back.fs:SetText("GAMES")
    back.fs:SetTextColor(0.63, 0.63, 0.63)
    back:SetPoint("LEFT")
    back:SetWidth(84)
    back:SetScript("OnEnter", function(self) self.fs:SetTextColor(1, 1, 1) self.chev:SetVertexColor(1, 1, 1) end)
    back:SetScript("OnLeave", function(self)
        self.fs:SetTextColor(0.63, 0.63, 0.63)
        self.chev:SetVertexColor(0.63, 0.63, 0.63)
    end)
    back:SetScript("OnClick", function() if not anim then BackToCarousel() end end)
    strip.back = back
    local sep = strip:CreateTexture(nil, "ARTWORK")
    sep:SetSize(1, 14)
    sep:SetPoint("LEFT", back, "RIGHT", 0, 0)
    sep:SetColorTexture(1, 1, 1, 0.12)
    strip.icon = strip:CreateTexture(nil, "ARTWORK")
    strip.icon:SetSize(18, 18)
    strip.icon:SetPoint("LEFT", sep, "RIGHT", 12, 0)
    strip.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    strip.name = Label(strip, 13)
    strip.name:SetPoint("LEFT", strip.icon, "RIGHT", 8, 0)
    strip.share = ns.Share:CreateNavButton(strip, function() return selected and ns.Share:GameRef(selected) end)
    strip.share.tipTitle = "Share this game"
    strip.share:SetPoint("RIGHT", -8, 0)
    strip.playing = Label(strip, 11)
    strip.playing:SetPoint("RIGHT", strip.share, "LEFT", -12, 0)
    strip.playing:SetTextColor(0.81, 0.81, 0.81)
    strip:Hide()

    stage = CreateFrame("Frame", nil, root)
    stage:SetPoint("TOPLEFT", 0, -STRIP_H)
    stage:SetPoint("BOTTOMRIGHT")
    stage:Hide()

    root:SetScript("OnSizeChanged", function()
        if not anim and not selected then LayoutCarousel() end
    end)
    root:SetScript("OnUpdate", OnUpdate)
    root:SetScript("OnHide", function()
        if anim and anim.kind == "open" then EndOpen() end
        if anim and anim.kind == "back" then EndBack() end
        if anim then
            if anim.frame then anim.frame:SetAlpha(1) end
            anim = nil
            if not selected then LayoutCarousel() end
        end
    end)
    root.OnPanelShown = function()
        BuildPosters()
        if selected then
            ShowGamePanel(selected)
        else
            cur = PickFront()
            Refresh()
            SetAura(posters[cur] and posters[cur].id, true)
        end
    end
    BuildPosters()
    cur = PickFront()
    Refresh()
    SetAura(posters[cur] and posters[cur].id, true)
    return root
end

-- Opens game id at once (links, /dz play, other tabs).
function GamesUI:Select(id)
    if not root then
        selected = id
        return
    end
    BuildPosters()
    OpenGame(id, false)
end

-- Back to the carousel (nothing open).
function GamesUI:ShowHub()
    if root and selected then
        if anim then
            if anim.kind == "open" then EndOpen() elseif anim.kind == "back" then EndBack() end
            anim = nil
        end
        HideGamePanel()
        selected = nil
        strip:Hide()
        stage:Hide()
        PlaceGame(0, 0, 1)
        carousel:Show()
        carousel:SetAlpha(1)
        Refresh()
    end
end

function GamesUI:GetSelected() return selected end

-- Shared with the games' own panels (Bingo's header): a raid's loading screen (FileDataID) and where its subject
-- stands across it, the crop of it to w x h, and the raid instance the player is in (key, name) or nil.
function GamesUI:RaidArt(key)
    key = LOADSCREEN[key] and key or "kara"
    return LOADSCREEN[key], FOCUS[key]
end
GamesUI.CropArt = CropArt
function GamesUI:InstanceHere() return InstanceHere() end

-- Puts game id's poster in front at once (tests, the audit's views).
function GamesUI:ShowFront(id)
    for i, p in ipairs(posters) do
        if p.id == id then
            cur = i
            Refresh()
            SetAura(id, true)
        end
    end
end

-- The poster in front (its game id), for tests.
function GamesUI:GetFront() return posters[cur] and posters[cur].id end
function GamesUI:Turn(i) Turn(i) end
function GamesUI:IsAnimating() return anim ~= nil end
-- Holds the animations (true) so a test can move them on by hand with StepAnim(seconds).
function GamesUI:PauseAnim(on) paused = on and true or nil end
function GamesUI:StepAnim(sec)
    for _ = 1, math.ceil((sec or 0) / 0.01) do OnUpdate(nil, 0.01, true) end
end
GamesUI.__posters = posters

function GamesUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("games", "Games", 3.8,
            function(parent) return GamesUI:CreatePanel(parent) end)
    end
    ns:On("GAMES_UPDATED", function() if root and root:IsVisible() then Refresh() end end)
end
