if DisasterZoneBoot and DisasterZoneBoot.Run("Games/HubUI.lua", ...) then return end -- DisasterZone Games/HubUI.lua
-- ns.GamesUI: the "Games" tab. A spotlight carousel: one game's poster in front, its neighbours dimmed at the sides
-- (arrows, mouse wheel, the dots or a click on a side poster turn it). A poster is the game's cover, alive while the
-- tab is open (your Bingo card filling in, the Trainer's bosses and best times, Disastercraft's Northshire),
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
    bingo = { 1, 0.82, 0 }, trainer = { 0.31, 0.83, 0.88 }, disastercraft = { 1, 0.69, 0.25 },
    chess = { 0.74, 0.58, 1 },
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

-- Disastercraft: your best character (level and class) and the quests done; who is playing now.
INFO.disastercraft = function()
    local out = { kicker = "ADVENTURE" }
    local data = Saved("disastercraft")
    local best, quests = nil, 0
    for _, c in pairs(type(data.chars) == "table" and data.chars or {}) do
        if type(c) == "table" and (not best or (c.level or 1) > (best.level or 1)) then best = c end
        for _ in pairs(type(c) == "table" and type(c.done) == "table" and c.done or {}) do quests = quests + 1 end
    end
    if best then
        local names = { [1] = "Warrior", [5] = "Priest", [8] = "Mage" }
        out.stat = string.format("Level |cffffffff%d|r %s  \194\183  |cffffffff%d|r %s", best.level or 1,
            names[best.class] or "", quests, quests == 1 and "quest" or "quests")
    else
        out.stat = "|cff8a8a8aNot started yet|r"
    end
    local P = ns.Craft and ns.Craft.Party
    local keys = P and P.PlayingKeys and P.PlayingKeys() or {}
    if #keys > 0 then
        out.faces = keys
        out.foot = string.format("%d playing now", #keys)
    end
    return out
end

-- Karazhan Chess: games waiting for your move, else your guild rating or your record against Medivh.
INFO.chess = function()
    local out = { kicker = "THE GAMESMAN'S HALL", art = "kara" }
    local C = ns.Chess
    local data = Saved("chess")
    local waiting = C and C:MyTurnCount() or 0
    local open = 0
    for _, g in pairs(type(data.games) == "table" and data.games or {}) do
        if type(g) == "table" and g.status ~= "over" then open = open + 1 end
    end
    local mine = C and C:MyRating()
    if waiting > 0 then
        out.stat = string.format("|cffc9a2ffYour move|r in |cffffffff%d|r %s", waiting, waiting == 1 and "game" or "games")
    elseif mine then
        out.stat = string.format("Guild rating |cffffffff%d|r  \194\183  %d-%d-%d", mine.rating, mine.w, mine.l, mine.d)
    else
        local w, n = 0, 0
        for _, s in pairs(type(data.stats) == "table" and data.stats or {}) do
            if type(s) == "table" then
                w = w + (tonumber(s.w) or 0)
                n = n + (tonumber(s.w) or 0) + (tonumber(s.l) or 0) + (tonumber(s.d) or 0)
            end
        end
        out.stat = n > 0 and string.format("Beat Medivh |cffffffff%d|r of %d", w, n) or "|cff8a8a8aNot played yet|r"
    end
    if open > 0 then out.foot = string.format("%d %s open", open, open == 1 and "game" or "games") end
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

-- Karazhan Chess, in 3D: a moment of a game in the Gamesman's Hall, frozen mid-fight - the event's own pieces on the
-- hall's own marble (the floor textures of the chess room: 127857 the board, two squares a side to a picture,
-- 127914 the pale floor round it), a footman and a grunt trading blows, a charger on a wolf, the Horde queen casting at
-- the footman from behind the grunts, a grunt fallen, Medivh's fire burning in front, Blackhand looming at the back.
-- Cheap on purpose: one ModelScene with seven models and an effect, 196 flat textures (one per square) bent into
-- perspective (as the room renderer does), and a camera that never moves - nothing is worked out per frame once it
-- stands, and it is only drawn while the poster is in front. Without the 3D files (no client restart yet) the
-- flat board below stands in.
local CHESS_S = 5.6                         -- yd: one square (the event's)
local CHESS_LV = { floor = 1, lines = 2, room0 = 3, scene = 4, copy0 = 5, plates = 6 }
local CHESS_BOARD, CHESS_FLOOR = 127857, 127914
-- the pieces: display, size (CreatureDisplayInfo), square (file, rank), facing (towards a square), animation (17 a
-- one-handed blow, 16 an unarmed / beast one, 52 a cast, 6 lying dead, 0 standing). Framed for CHESS_CAM: checked by
-- projecting every square in the mock (the clash mid-poster, the far pieces under its top).
local CHESS_CAST = {
    { d = 16276, s = 1.5, f = 3, r = 3, at = { 4, 4 }, anim = 17 },     -- Human Footman (d4) on the grunt
    { d = 16264, s = 1.5, f = 4, r = 4, at = { 3, 3 }, anim = 17 },     -- Orc Grunt (e5) striking back
    { d = 19783, s = 1.75, f = 4, r = 2, at = { 5, 3 }, anim = 16 },    -- Human Charger (e3) on the wolf
    { d = 2352, s = 2, f = 5, r = 3, at = { 4, 2 }, anim = 16 },        -- Orc Wolf (f4)
    { d = 16263, s = 2.5, f = 4, r = 6, at = { 3, 3 }, anim = 52 },     -- Orc Warlock (e7) casting at the footman
    { d = 16264, s = 1.5, f = 3, r = 4, at = { 0, 2 }, anim = 6 },      -- a grunt fallen on d5
    { d = 16270, s = 3, f = 3, r = 7, at = { 4, 4 }, anim = 0 },        -- Warchief Blackhand (d8) looming
}
local CHESS_FIRE = { fdid = 165599, size = 6.6, f = 3, r = 2 }         -- Fury of Medivh's fire on d3, in front
-- the camera: low behind the Alliance's side, looking up the board at the clash (squares, yd, radians)
local CHESS_CAM = { x = 3.8, y = 3.4, z = 1.6, heading = math.pi / 2 - 0.38, pitch = 0.33, dist = 21 }

-- the flat stand-in (no 3D yet): your latest game on a small board, a disc and a letter per piece
local function ChessMiniBoard(parent)
    local c = CreateFrame("Frame", nil, parent)
    c.cells = {}
    for i = 1, 64 do
        local cell = CreateFrame("Frame", nil, c)
        cell.bg = cell:CreateTexture(nil, "BACKGROUND")
        cell.bg:SetAllPoints()
        cell.disc = cell:CreateTexture(nil, "ARTWORK")
        cell.disc:SetTexture(CIRCLE)
        cell.letter = Label(cell, 9, "GameFontHighlightSmall")
        cell.letter:SetJustifyH("CENTER")
        cell.letter:SetPoint("CENTER", 0, 0)
        c.cells[i] = cell
    end
    function c:Layout(w, h)
        local size = floor(min(w - 40, h - 16, 176))
        if size < 40 then size = 40 end
        local cs = size / 8
        self:SetSize(size, size)
        for i, cell in ipairs(self.cells) do
            local r, col = floor((i - 1) / 8), (i - 1) % 8
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", self, "TOPLEFT", col * cs, -r * cs)
            cell:SetSize(cs, cs)
            cell.disc:ClearAllPoints()
            cell.disc:SetPoint("CENTER")
            cell.disc:SetSize(cs * 0.74, cs * 0.74)
            local path, _, flags = cell.letter:GetFont()
            if path then cell.letter:SetFont(path, max(6, floor(cs * 0.5)), flags) end
        end
    end
    function c:Refresh()
        local C, R = ns.Chess, ns.ChessRules
        if not (C and R) then return end
        local g
        for _, x in ipairs(C:List()) do
            if x.status ~= "invited" and x.status ~= "asked" then g = x break end
        end
        local pos = g and C:Position(g) or R.New()
        local me = g and g.me or 1
        local last = g and #g.moves > 0 and g.moves[#g.moves] or nil
        local lf, lt = last and R.ParseSquare(last:sub(1, 2)), last and R.ParseSquare(last:sub(3, 4))
        for i, cell in ipairs(self.cells) do
            local row, col = floor((i - 1) / 8), (i - 1) % 8
            -- (your side at the bottom)
            local rank, file = me == 1 and (7 - row) or row, me == 1 and col or (7 - col)
            local sq = R.Square(file, rank)
            local light = (file + rank) % 2 == 1
            if sq == lf or sq == lt then
                cell.bg:SetColorTexture(0.42, 0.32, 0.6, 0.92)
            elseif light then
                cell.bg:SetColorTexture(0.72, 0.69, 0.66, 0.88)
            else
                cell.bg:SetColorTexture(0.14, 0.13, 0.15, 0.9)
            end
            local v = pos.b[sq]
            if v ~= 0 then
                if v > 0 then
                    cell.disc:SetVertexColor(0.2, 0.36, 0.72, 1)
                    cell.letter:SetTextColor(0.9, 0.95, 1)
                else
                    cell.disc:SetVertexColor(0.62, 0.14, 0.1, 1)
                    cell.letter:SetTextColor(1, 0.86, 0.8)
                end
                cell.letter:SetText(R.LETTER[v > 0 and v or -v]:upper())
                cell.disc:Show()
                cell.letter:Show()
            else
                cell.disc:Hide()
                cell.letter:Hide()
            end
        end
    end
    return c
end

COVERS.chess = function(parent)
    local R3 = ns.Render3D
    local probe = parent:CreateTexture()
    local canBend = probe.SetVertexOffset ~= nil
    probe:Hide()
    if not (R3 and R3.NewView and canBend) then return ChessMiniBoard(parent) end
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(FRONT_W, 300)
    c:SetClipsChildren(true)
    local v = R3.NewView(c, { room = false, lv = CHESS_LV, fov = 0.95, near = 0.5, far = 400, label = "Chess poster" })
    if not v then
        c:Hide()
        return ChessMiniBoard(parent)
    end
    c.frontOnly = true                       -- (drawn only in front: the side posters keep their painting)
    c.view = v

    -- the floor: a picture's quarter per square (a picture holds 2 x 2), the board and three rows of the pale floor
    -- round it, fading out. One square a piece: a piece reaching behind the camera is hidden whole, and one square is
    -- small enough to lie under the view's bottom edge then (a bigger one would leave a hole there).
    c.tiles = {}
    for r = -3, 10 do
        for f = -3, 10 do
            local board = f >= 0 and f <= 7 and r >= 0 and r <= 7
            local ring = max(-f, -r, f - 7, r - 7, 0)
            local t = v.floorFrame:CreateTexture(nil, "BACKGROUND", nil, board and 2 or 0)
            t:SetSize(1, 1)
            t:SetPoint("CENTER", v.floorFrame, "CENTER", 0, 0)
            if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
            if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
            t:SetTexture(board and CHESS_BOARD or CHESS_FLOOR, "REPEAT", "REPEAT")
            -- (the picture's top left quarter is dark: a1's; u along the files, v along the ranks)
            local u0, v0 = (f % 2) * 0.5, (r % 2) * 0.5
            t:SetTexCoord(u0, v0 + 0.5, u0, v0, u0 + 0.5, v0 + 0.5, u0 + 0.5, v0)
            local light = board and 0.8 or 0.62
            local a = board and 1 or ({ 0.85, 0.55, 0.25 })[ring]
            t:SetVertexColor(light, light, light * 1.04, a)
            c.tiles[#c.tiles + 1] = { tex = t, x0 = (f - 0.5) * CHESS_S, y0 = (r - 0.5) * CHESS_S }
        end
    end

    -- the poster's low shade over the floor (the floor draws above the poster's own shade, which the painting
    -- fades under): a frame of its own between the floor and the pieces (CHESS_LV lines), the ground colour solid at
    -- the foot and a gradient over it, so the floor is dark before the title as the paintings are (one texture in
    -- the floor's own frame was too faint in game)
    local shadeFrame = CreateFrame("Frame", nil, c)
    shadeFrame:SetAllPoints()
    shadeFrame:SetFrameLevel(c:GetFrameLevel() + CHESS_LV.lines)
    c.shadeSolid = shadeFrame:CreateTexture(nil, "ARTWORK")
    c.shadeSolid:SetPoint("BOTTOMLEFT")
    c.shadeSolid:SetPoint("BOTTOMRIGHT")
    c.shadeSolid:SetHeight(14)
    c.shadeSolid:SetColorTexture(BASE[1], BASE[2], BASE[3], 1)
    c.shade = shadeFrame:CreateTexture(nil, "ARTWORK")
    c.shade:SetPoint("BOTTOMLEFT", c.shadeSolid, "TOPLEFT")
    c.shade:SetPoint("BOTTOMRIGHT", c.shadeSolid, "TOPRIGHT")
    Gradient(c.shade, "VERTICAL", BASE[1], BASE[2], BASE[3], 1, BASE[1], BASE[2], BASE[3], 0)

    -- the pieces and the fire
    c.actors = {}
    for i, p in ipairs(CHESS_CAST) do
        local a = (i == 1 and v.probe) or v:NewActor()
        if a then
            a.anim = p.anim
            pcall(a.SetModelByCreatureDisplayID, a, p.d)
            pcall(a.SetUseCenterForOrigin, a, false, false, false)
            pcall(a.SetScale, a, p.s)
            pcall(a.SetAnimation, a, p.anim)
            c.actors[i] = { a = a, p = p }
        end
    end
    local fire = v:NewActor()
    if fire then
        fire.anim = 0
        pcall(fire.SetModelByFileID, fire, CHESS_FIRE.fdid)   -- (the spell's own effect model: tools/spell_visuals.py)
        pcall(fire.SetUseCenterForOrigin, fire, false, false, false)
        c.fire = fire
    end

    local dist = CHESS_CAM.dist
    local function Place()
        local cam = CHESS_CAM
        v:Orbit(cam.x * CHESS_S, cam.y * CHESS_S, cam.z, cam.heading, cam.pitch, dist)
    end

    -- The camera's distance that fits every piece (feet and head) inside the poster, a margin round it: the client's
    -- lens was found to frame tighter than the test mock's (pieces cut at the edges in game), so it is measured here.
    local function Fit(w, h)
        local cx, cy = v:Project(CHESS_CAM.x * CHESS_S, CHESS_S * CHESS_CAM.y, CHESS_CAM.z)
        if not cx then return end
        local need = 0
        for _, p in ipairs(CHESS_CAST) do
            for _, z in ipairs({ 0, 2.2 * p.s }) do
                local x, y = v:Project(p.f * CHESS_S, p.r * CHESS_S, z)
                if not x then
                    need = max(need, 2)
                else
                    need = max(need, abs(x - cx) / max(1, w / 2 - 14), abs(y - cy) / max(1, h / 2 - 14))
                end
            end
        end
        return need
    end

    -- the scene as it stands: camera, floor pictures bent onto their corners, models on their squares
    -- -> true once it stands; false to try again next frame. Only a stage the client could project counts: a
    -- scene it cannot project yet (just shown or resized) returns nothing, and a stage set then lost its whole floor
    -- for good (seen in game twice).
    function c:Stage()
        local w, h = self:GetWidth() or 0, self:GetHeight() or 0
        self.tries = (self.tries or 0) + 1
        if w <= 0 or h <= 0 then self.why = "no size" return false end
        Place()
        if not v:Project(CHESS_CAM.x * CHESS_S, CHESS_CAM.y * CHESS_S, CHESS_CAM.z) then
            self.why = "no projection"
            return false
        end
        if not self.calibrated then
            local cam = CHESS_CAM
            local x, y = cam.x * CHESS_S, cam.y * CHESS_S
            self.calibrated = v:Calibrate(Place, x, y, cam.z, x - math.sin(cam.heading) * 2,
                y + math.cos(cam.heading) * 2, cam.z)
            if not self.calibrated then return false end
        end
        dist = CHESS_CAM.dist
        Place()
        -- (pulled back until it all fits: a few steps, the picture roughly shrinks with the distance)
        for _ = 1, 4 do
            local need = Fit(w, h)
            if not need or need <= 1.02 then break end
            dist = dist * min(2, need * 1.04)
            Place()
        end
        local ox, oy = w / 2, h / 2
        local S2 = CHESS_S
        local shown = 0
        for _, tl in ipairs(self.tiles) do
            -- corners: A north-west, B south-west, C south-east, D north-east (the picture's UL, LL, LR, UR)
            local ax, ay = v:Project(tl.x0, tl.y0 + S2, 0)
            local bx, by = v:Project(tl.x0, tl.y0, 0)
            local cx, cy = v:Project(tl.x0 + S2, tl.y0, 0)
            local dx, dy = v:Project(tl.x0 + S2, tl.y0 + S2, 0)
            local t = tl.tex
            if ax and bx and cx and dx then
                t:SetVertexOffset(UPPER_LEFT_VERTEX or 1, ax - ox + 0.5, ay - oy - 0.5)
                t:SetVertexOffset(LOWER_LEFT_VERTEX or 2, bx - ox + 0.5, by - oy + 0.5)
                t:SetVertexOffset(UPPER_RIGHT_VERTEX or 3, dx - ox - 0.5, dy - oy - 0.5)
                t:SetVertexOffset(LOWER_RIGHT_VERTEX or 4, cx - ox - 0.5, cy - oy + 0.5)
                t:Show()
                shown = shown + 1
            else
                t:Hide()
            end
        end
        local mirror = v.cam.mirror or 1
        for _, e in ipairs(self.actors) do
            local p, a = e.p, e.a
            local x, y = p.f * CHESS_S, p.r * CHESS_S
            local face = math.atan2((p.at[2] - p.r), (p.at[1] - p.f))
            pcall(a.SetPosition, a, x / p.s, v:SY(y) / p.s, 0)
            pcall(a.SetYaw, a, mirror * face)
            pcall(a.SetShown, a, true)
        end
        if self.fire then
            local s = CHESS_S * 0.5 / CHESS_FIRE.size
            pcall(self.fire.SetScale, self.fire, s)
            pcall(self.fire.SetPosition, self.fire, CHESS_FIRE.f * CHESS_S / s, v:SY(CHESS_FIRE.r * CHESS_S) / s, 0)
            pcall(self.fire.SetShown, self.fire, true)
        end
        self.shownTiles, self.dist = shown, dist
        if shown == 0 then self.why = "no floor" return false end
        self.why = nil
        return true
    end

    function c:Layout(w, h)
        w, h = floor(w), floor(max(60, h))
        if w == self.lw and h == self.lh then return end
        self.lw, self.lh = w, h
        -- (1 px inside the poster's border on each side, as the painting: the floor reached over the edge line)
        self:SetSize(w - 2, h)
        -- (the cover ends where the art does, 52 under its top: the art's height is h + 52, as Place has it)
        self.shade:SetHeight(max(1, (h + 52) * 0.45))
        self.dirty = true
    end
    function c:Refresh() end
    -- (only while the scene still has to be set: a resize, or the client gave no size yet)
    -- (only while it can be seen: a hidden ModelScene projects nothing, and a stage set then lost its whole floor -
    -- seen in game after coming back from a game; shown again, it is set again)
    function c:Tick()
        if self.dirty and self:IsVisible() and self:Stage() then self.dirty = false end
    end
    c:SetScript("OnShow", function(self) self.dirty = true end)
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

-- Disastercraft: a short film of Northshire Valley on a loop. Shots of the real valley - WoW's own ground, scenery
-- and creatures from the game's generated map (ns.AzeroLand) - each a slow camera move with something happening in
-- it (FILM_SHOTS): the heroes stepping out of the Abbey, a fight with a wolf in the woods, the kobolds at Echo Ridge
-- Mine, the Defias among the vines. The place's name comes up as the game's zone text does; shots cross-fade (two
-- reels); cloud shadows drift over it all. A small renderer of its own (the game's UIWorld needs a player in the
-- world): ground cells laid once a shot as they come into view, everything standing on the ground drawn back to
-- front by its ground row (Draw / Flush, as UIWorld does), spells and numbers over it all.
local Film = {}
local FILM_TILE = 34                -- pixels a tile at zoom 1 (the game draws ~46)
local FILM_SHOT, FILM_FADE = 8.5, 1.4   -- seconds a shot; its last FILM_FADE cross-fades into the next
local FILM_DEPTH = 4                -- depth frames a reel, 32 ordered slots each
local FILM_FOCUS = 0.42             -- the camera's point down the art box (its foot is under the title's shade)
local FILM_ACT = { windup = 0, strike = 1, ready = 2, release = 3, dead = 4, sit = 5 }
local FILM_STEP = { 0, 1, 2, 1 }    -- walk frames: stride, stand, stride, stand
local SPARK = "Interface\\Cooldown\\star4"
local FILM_KOBOLD = { [6] = true, [40] = true, [80] = true, [257] = true, [476] = true }   -- (candles on their heads)
local cos, sqrt = math.cos, math.sqrt

-- a body's picture on the model sheets: Disastercraft's own (CraftUI.Kit.BodyCoords: the sheets' layout, the
-- eight facings)
local function FilmCoords(spr, face, frame, act)
    return ns.CraftUI.Kit.BodyCoords(spr, face, not act and frame or nil, act and FILM_ACT[act] or nil)
end

local function FilmSprite(e)
    if e.spr then return e.spr end
    local S = ns.AzeroData and ns.AzeroData.worldSpecies
    local key = S and S._byEntry and S._byEntry[e.e]
    return key and S[key] and S[key].spr
end

local function FilmHero(token)
    local spr = ns.AzeroData and ns.AzeroData.CLASS_SPR
    return spr and spr[token] or 0
end

-- a body on the film: where it stands (tiles), its facing, its picture; wanderers stroll round where they stand
function Film.Body(spr, x, y, face, wander)
    local b = { spr = spr, x = x, y = y, hx = x, hy = y, face = face or "down", wander = wander, walk = 0 }
    b.seed = ((x * 7919 + y * 104729) % 9973) / 9973
    b.wait = b.seed * 4
    return b
end

local function Rand(b)
    b.seed = (b.seed * 9301 + 0.4929) % 1
    return b.seed
end

local function FaceTo(dx, dy) return ns.Craft.FaceOf(dx, dy) end

-- walks b toward (x, y) at speed tiles a second; true once there
function Film.WalkTo(b, x, y, speed, dt)
    local dx, dy = x - b.x, y - b.y
    local d = sqrt(dx * dx + dy * dy)
    local step = speed * dt
    if d <= step or d < 0.001 then
        b.x, b.y, b.moving = x, y, nil
        return true
    end
    b.x, b.y = b.x + dx / d * step, b.y + dy / d * step
    b.face, b.moving = FaceTo(dx, dy), true
    b.walk = b.walk + dt
    return false
end

local function Wander(b, dt)
    if b.tx then
        if Film.WalkTo(b, b.tx, b.ty, b.speed or 0.9, dt) then b.tx, b.wait = nil, 2 + Rand(b) * 5 end
    else
        b.wait = b.wait - dt
        if b.wait <= 0 then
            local a, r = Rand(b) * 2 * pi, 0.5 + Rand(b) * 1.5
            b.tx, b.ty = b.hx + cos(a) * r, b.hy + sin(a) * r
        end
    end
end

-- A reel: one shot's picture (two reels cross-fade from shot to shot). Everything is placed in the view's own
-- pixels each frame (the camera's zoom is the tile's size: a scaled frame would round its pieces apart).
function Film.NewReel(parent, level)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()
    f:SetFrameLevel(level)
    local L = { frame = f, grid = {}, depth = {}, pools = {}, reqs = {}, n = 0, order = {}, fx = {}, nfx = 0,
                nums = {}, nnum = 0, cx = 0, cy = 0, ts = FILM_TILE, vx = 0, vy = 0, keep = {}, fade = {}, cast = {} }
    for k = 1, FILM_DEPTH do
        local d = CreateFrame("Frame", nil, f)
        d:SetAllPoints()
        d:SetFrameLevel(level + k)
        L.depth[k], L.pools[k] = d, {}
    end
    L.over = CreateFrame("Frame", nil, f)
    L.over:SetAllPoints()
    L.over:SetFrameLevel(level + 1 + FILM_DEPTH)
    return L
end

-- where tile point (x, y) is in the view (pixels from its top left)
local function FilmXY(L, x, y) return L.vx + (x - L.cx) * L.ts, L.vy + (y - L.cy) * L.ts end

-- starts shot `shot` on reel L: its scenery and creatures looked up round the camera's path
function Film.Begin(L, shot)
    local WS = ns.AzeroLand
    L.shot, L.t, L.fade = shot, 0, {}
    local c = shot.cam or shot.area0
    local x0, x1 = min(c[1], c[3]) - 16, max(c[1], c[3]) + 16
    local y0, y1 = min(c[2], c[4]) - 10, max(c[2], c[4]) + 12
    if shot.area then x0, y0, x1, y1 = shot.area[1], shot.area[2], shot.area[3], shot.area[4] end
    L.scen = WS and WS.SceneryIn and WS.SceneryIn(x0, y0, x1, y1) or {}
    L.bodies = {}
    local ents = WS and WS.EntitiesNear and WS.EntitiesNear((x0 + x1) / 2, (y0 + y1) / 2, max(x1 - x0, y1 - y0) / 2 + 2)
    for _, e in ipairs(ents or {}) do
        local x, y = e.xf or (e.x + 0.5), e.yf or (e.y + 0.5)
        -- (a spawn indoors stands under the roof: not shown, as in the game while you are outside)
        local spr = (e.k == "mob" or e.k == "npc" or e.k == "critter") and not e.ht and FilmSprite(e)
        local clear = true
        for _, s in ipairs(shot.clear or {}) do
            if abs(x - s[1]) < s[3] and abs(y - s[2]) < s[3] then clear = false end
        end
        if spr and clear and x >= x0 and x <= x1 and y >= y0 and y <= y1 then
            local b = Film.Body(spr, x, y, e.f, e.k ~= "npc")
            b.speed = e.k == "critter" and 0.7 or 0.9
            b.candle = FILM_KOBOLD[e.e]
            if shot.marks and e.n and shot.marks[e.n] then b.mark = true end
            L.bodies[#L.bodies + 1] = b
        end
    end
    L.cast = shot.setup and shot.setup(L) or {}
    for _, b in pairs(L.cast) do L.bodies[#L.bodies + 1] = b end
    L.frame:Show()
end

-- the ground in view: one cell a tile, WoW's own blended terrain (a cell keeps its picture while it stays)
local function Ground(L, w, h)
    local WS = ns.AzeroLand
    local ts = L.ts
    local x0, y0 = floor(L.cx - L.vx / ts), floor(L.cy - L.vy / ts)
    local cols, rows = floor(w / ts) + 2, floor(h / ts) + 2
    local size = floor(ts + 1.5)
    for i = 0, max(cols, L.cols or 0) do
        local col = L.grid[i]
        if not col then col = {} L.grid[i] = col end
        for j = 0, max(rows, L.rows or 0) do
            local t = col[j]
            if i <= cols and j <= rows then
                if not t then
                    t = L.frame:CreateTexture(nil, "BACKGROUND")
                    col[j] = t
                end
                local file, slot, row = WS.GroundTile(x0 + i, y0 + j)
                if file then
                    if t.file ~= file then t:SetTexture(file) t.file, t.slot = file, nil end
                    if t.slot ~= slot then
                        t.slot = slot
                        local cc, rr, e = slot % row, floor(slot / row), 0.5 / 1024
                        t:SetTexCoord(cc / row + e, (cc + 1) / row - e, rr / row + e, (rr + 1) / row - e)
                    end
                    local sx, sy = FilmXY(L, x0 + i, y0 + j)
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", L.frame, "TOPLEFT", floor(sx + 0.5), -floor(sy + 0.5))
                    t:SetSize(size, size)
                    t:Show()
                else
                    t:Hide()
                end
            elseif t then
                t:Hide()
            end
        end
    end
    L.cols, L.rows = cols, rows
end

-- a picture standing on ground row `sort` this frame (see Flush)
local function Draw(L, sort)
    L.n = L.n + 1
    local r = L.reqs[L.n]
    if not r then r = {} L.reqs[L.n] = r end
    r.sort, r.idx, r.alpha, r.cr, r.cg, r.cb, r.pt = sort, L.n, 1, 1, 1, 1, "TOPLEFT"
    return r
end

-- every picture its own slot back to front (a crowded view shares them out evenly), from the depth frames' pools
local function Flush(L)
    local order = L.order
    for i = #order, 1, -1 do order[i] = nil end
    for i = 1, L.n do order[i] = L.reqs[i] end
    table.sort(order, function(a, b)
        if a.sort ~= b.sort then return a.sort < b.sort end
        return a.idx < b.idx
    end)
    local n, total, used = #order, FILM_DEPTH * 32, {}
    for i, r in ipairs(order) do
        local slot = n <= total and (i - 1) or floor((i - 1) * total / n)
        local f, s = floor(slot / 32) + 1, slot % 32
        local k = (used[f] or 0) + 1
        used[f] = k
        local t = L.pools[f][k]
        if not t then
            t = L.depth[f]:CreateTexture(nil, "ARTWORK")
            L.pools[f][k] = t
        end
        if t.file ~= r.file then t:SetTexture(r.file) t.file = r.file end
        t:SetTexCoord(r.l, r.r, r.t, r.b)
        t:SetSize(max(1, r.w), max(1, r.h))
        t:ClearAllPoints()
        t:SetPoint(r.pt, L.frame, "TOPLEFT", r.x, -r.y)
        t:SetVertexColor(r.cr, r.cg, r.cb)
        t:SetAlpha(r.alpha)
        if s < 16 then t:SetDrawLayer("BORDER", s - 8) else t:SetDrawLayer("ARTWORK", s - 24) end
        t:Show()
    end
    for f = 1, FILM_DEPTH do
        local pool = L.pools[f]
        for i = (used[f] or 0) + 1, #pool do pool[i]:Hide() end
    end
    L.n = 0
end

-- a glow over everything (spells, sparks, quest marks): x, y in tiles, w / h in tiles
function Film.Glow(L, file, x, y, w, h, r, g, b, a, add)
    L.nfx = L.nfx + 1
    local t = L.fx[L.nfx]
    if not t then
        t = L.over:CreateTexture(nil, "ARTWORK")
        L.fx[L.nfx] = t
    end
    if t.file ~= file then t:SetTexture(file) t.file = file end
    t:SetBlendMode(add and "ADD" or "BLEND")
    t:SetVertexColor(r, g, b)
    t:SetAlpha(max(0, min(1, a)))
    t:SetSize(max(1, w * L.ts), max(1, h * L.ts))
    local sx, sy = FilmXY(L, x, y)
    t:ClearAllPoints()
    t:SetPoint("CENTER", L.frame, "TOPLEFT", sx, -sy)
    t:Show()
end

-- a combat number rising over (x, y): age 0..1
function Film.Number(L, x, y, text, r, g, b, age, big)
    L.nnum = L.nnum + 1
    local fs = L.nums[L.nnum]
    if not fs then
        fs = L.over:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        L.nums[L.nnum] = fs
    end
    -- (it pops in big and settles, as the game's combat text)
    local size = floor((big and 19 or 15) * (age < 0.12 and (1 + (0.12 - age) * 4) or 1) + 0.5)
    if fs.size ~= size then
        fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, "OUTLINE")
        fs.size = size
    end
    fs:SetText(text)
    fs:SetTextColor(r, g, b)
    fs:SetAlpha(age < 0.7 and 1 or max(0, 1 - (age - 0.7) / 0.3))
    local sx, sy = FilmXY(L, x, y)
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", L.frame, "TOPLEFT", sx, -(sy - age * 30))
    fs:Show()
end

-- one frame of reel L in a view w x h: the shot's script and its wanderers, the camera, the ground in view, the
-- scenery and bodies back to front, the glows over them
function Film.Frame(L, dt, w, h)
    local shot = L.shot
    if not shot then return end
    L.t = L.t + dt
    local u = min(1, L.t / (FILM_SHOT + FILM_FADE))
    local e = 0.5 - 0.5 * cos(pi * u)
    local c, z = shot.cam, shot.zoom
    L.ts = FILM_TILE * Lerp(z and z[1] or 1, z and z[2] or 1, e)
    L.vx, L.vy = w / 2, h * FILM_FOCUS
    L.nfx, L.nnum = 0, 0
    if c then L.cx, L.cy = Lerp(c[1], c[3], e), Lerp(c[2], c[4], e) end
    if shot.act then shot.act(L, L.t, dt) end
    if shot.follow then
        -- (a tracking shot: the camera rides with the party; its script draws no glows, placed by the camera)
        local sx, sy, n = 0, 0, 0
        for _, b in pairs(L.cast) do sx, sy, n = sx + b.x, sy + b.y, n + 1 end
        L.cx, L.cy = sx / max(1, n) + shot.follow[1], sy / max(1, n) + shot.follow[2]
    end
    for _, b in ipairs(L.bodies) do
        if b.wander and not b.held then Wander(b, dt) end
    end
    Ground(L, w, h)
    local ts = L.ts
    local x0, x1 = L.cx - L.vx / ts, L.cx + (w - L.vx) / ts
    local y0, y1 = L.cy - L.vy / ts, L.cy + (h - L.vy) / ts
    -- what must stay in sight: the shot's actors and the camera's point (Northshire's crowns are 10-20 tiles across)
    local keep = L.keep
    for i = #keep, 1, -1 do keep[i] = nil end
    keep[1] = { L.cx, L.cy }
    for _, b in pairs(L.cast) do
        if (b.alpha or 1) > 0.01 then keep[#keep + 1] = { b.x, b.y } end
    end
    -- scenery in view (a sprite's picture half a texel in from its edges, as UIWorld's ScenPicture); a tree crown in
    -- front of something kept in sight turns see-through, eased, as round you in the game
    for _, sc in ipairs(L.scen) do
        local sp, k = sc.sp, sc.k / sc.pxt
        local l, tt = sc.x - sp.ox * k, sc.y - sp.oy * k
        if l < x1 + 1 and l + sp.w * k > x0 - 1 and tt < y1 + 1 and tt + sp.h * k > y0 - 1 then
            local px = ts * k
            local r = Draw(L, sc.sort)
            if sc.tree then
                local want, rr = 1, sp.w * k
                for _, q in ipairs(keep) do
                    if sc.sort > q[2] - 0.5 and q[1] > l - 1 and q[1] < l + rr + 1 and q[2] > tt - 1 and
                       q[2] < tt + sp.h * k + 1 then
                        want = 0.22
                        break
                    end
                end
                local a = L.fade[sc] or want
                a = a < want and min(want, a + dt * 1.6) or max(want, a - dt * 1.6)
                L.fade[sc] = a
                r.alpha = a
            end
            r.file = sc.file
            r.l, r.r = (sp.u + 0.5) / 1024, (sp.u + sp.w - 0.5) / 1024
            r.t, r.b = (sp.v + 0.5) / 1024, (sp.v + sp.h - 0.5) / 1024
            r.w, r.h = (sp.w - 1) * px, (sp.h - 1) * px
            local sx, sy = FilmXY(L, sc.x, sc.y)
            r.x, r.y = sx - (sp.ox - 0.5) * px, sy - (sp.oy - 0.5) * px
        end
    end
    -- bodies: feet on their point
    local now = L.t
    for _, b in ipairs(L.bodies) do
        if b.x > x0 - 2 and b.x < x1 + 2 and b.y > y0 - 1 and b.y < y1 + 3 and (b.alpha or 1) > 0.01 then
            local r = Draw(L, b.y)
            local frame = b.moving and FILM_STEP[floor(b.walk * 7) % 4 + 1] or 1
            r.file, r.l, r.r, r.t, r.b = FilmCoords(b.spr, b.face, frame, b.act)
            local size = ts * (b.size or 1)
            local sx, sy = FilmXY(L, b.x, b.y)
            r.w, r.h, r.pt, r.x, r.y = size, size, "BOTTOM", sx, sy + 0.06 * ts
            r.alpha = b.alpha or 1
            if b.flash and now < b.flash then r.cr, r.cg, r.cb = 1, 0.45, 0.45
            elseif b.act == "dead" then r.cr, r.cg, r.cb = 0.62, 0.62, 0.62 end
            if b.mark then
                Film.Glow(L, "Interface\\GossipFrame\\AvailableQuestIcon", b.x, b.y - 1.45 - 0.06 * sin(now * 3),
                          0.42, 0.42, 1, 1, 1, 1)
            end
            -- a kobold's candle on its head, flickering
            if b.candle and b.act ~= "dead" then
                local f = 0.75 + 0.15 * sin(now * 11 + b.hx) + 0.1 * sin(now * 17 + b.hy)
                Film.Glow(L, RADIAL, b.x, b.y - 0.92, 0.7 * f, 0.7 * f, 1, 0.7, 0.3, 0.55 * f, true)
            end
        end
    end
    Flush(L)
    for i = L.nfx + 1, #L.fx do L.fx[i]:Hide() end
    for i = L.nnum + 1, #L.nums do L.nums[i]:Hide() end
end

-- The shots. cam = { x, y from, x, y to } (tiles), zoom = { from, to }; clear = { { x, y, r } } spawns not shown
-- (the scene's own actors stand there); marks: an NPC's quest mark by name; setup(L) -> the shot's own actors;
-- act(L, t, dt) moves them.
local function Swing(t, at) return (t >= at - 0.22 and t < at and "windup") or (t >= at and t < at + 0.2 and "strike") or nil end
local function Age(t, at, len) local a = (t - at) / (len or 1) return a >= 0 and a < 1 and a or nil end

-- the party walks in turn: { body, start time, path { { x, y }, ... }, facing once there, speed }
local function Walks(t, dt, list)
    for _, q in ipairs(list) do
        local b = q[1]
        if t >= q[2] then
            b.alpha = min(1, (b.alpha or 1) + dt * 3)
            b.leg = b.leg or 1
            local pt = q[3][b.leg]
            if pt and Film.WalkTo(b, pt[1], pt[2], q[5] or 1.1, dt) then
                b.leg = b.leg + 1
                if not q[3][b.leg] and q[4] then b.face = q[4] end
            end
        end
    end
end

-- A fight in front of you: the warrior's swings, the foe's blows until it falls, the mage's Fireballs (1.5 s casts
-- flying 0.45 s), the priest mending the warrior; numbers rise as the game's combat text does.
local function Fight(L, t)
    local C = L.cast
    local foe, war, mage, pri = C.foe, C.war, C.mage, C.pri
    local dead = t >= 6.45
    war.act, mage.act, pri.act = nil, nil, nil
    for _, at in ipairs({ 0.6, 2.1, 3.6, 5.1 }) do war.act = war.act or Swing(t, at) end
    foe.act = dead and "dead" or nil
    if not dead then
        for _, at in ipairs({ 1.2, 2.9, 4.6 }) do
            foe.act = foe.act or Swing(t, at)
            if t >= at and t < at + 0.18 then war.flash = t + 0.01 end
        end
    end
    for _, h in ipairs({ { 0.6, "11" }, { 2.1, "14" }, { 3.6, "9" }, { 5.1, "13" } }) do
        local a = Age(t, h[1], 1)
        if a then Film.Number(L, foe.x + 0.55, foe.y - 1.15, h[2], 1, 1, 1, a) end
        if t >= h[1] and t < h[1] + 0.15 then foe.flash = t + 0.01 end
    end
    for _, cast in ipairs({ { 0.3, "41" }, { 2.4, "38" }, { 4.5, "44" } }) do
        local st, rel = cast[1], cast[1] + 1.5
        local hx, hy = mage.x + 0.3, mage.y - 0.5
        if t >= st and t < rel then
            mage.act = "ready"
            local k = (t - st) / 1.5
            Film.Glow(L, RADIAL, hx, hy, 0.5 + 0.4 * k, 0.5 + 0.4 * k, 1, 0.55, 0.15, 0.5 + 0.4 * k, true)
        elseif t >= rel and t < rel + 0.3 then
            mage.act = "release"
        end
        local f = Age(t, rel, 0.45)
        if f then
            local tx, ty = foe.x, foe.y - 0.55
            for j = 3, 0, -1 do
                local g = max(0, f - j * 0.07)
                local x, y = Lerp(hx, tx, g), Lerp(hy, ty, g) - sin(g * pi) * 0.5
                Film.Glow(L, RADIAL, x, y, 0.9 - j * 0.17, 0.9 - j * 0.17, 1, 0.5 - j * 0.08, 0.1, 0.95 - j * 0.22, true)
            end
            Film.Glow(L, RADIAL, Lerp(hx, tx, f), Lerp(hy, ty, f) - sin(f * pi) * 0.5, 0.35, 0.35, 1, 0.95, 0.7, 1, true)
        end
        local b = Age(t, rel + 0.45, 0.5)
        if b then
            Film.Glow(L, RADIAL, foe.x, foe.y - 0.5, 0.8 + 1.6 * b, 0.8 + 1.6 * b, 1, 0.45, 0.1, 1 - b, true)
            Film.Glow(L, SPARK, foe.x, foe.y - 0.5, 1.4 - 0.7 * b, 1.4 - 0.7 * b, 1, 0.8, 0.4, 1 - b, true)
        end
        local a = Age(t, rel + 0.45, 1.1)
        if a then Film.Number(L, foe.x - 0.45, foe.y - 1.55, cast[2], 1, 0.87, 0.2, a, true) end
        if t >= rel + 0.45 and t < rel + 0.6 then foe.flash = t + 0.01 end
    end
    if t >= 3.0 and t < 4.2 then
        pri.act = "ready"
        Film.Glow(L, RADIAL, pri.x + 0.3, pri.y - 0.5, 0.7, 0.7, 1, 0.9, 0.5, 0.5 + 0.3 * sin(t * 9), true)
    elseif t >= 4.2 and t < 4.5 then
        pri.act = "release"
    end
    local hl = Age(t, 4.2, 1.0)
    if hl then
        Film.Glow(L, RADIAL, war.x, war.y - 0.6, 1.3, 2.2, 1, 0.92, 0.45, 0.8 * (1 - hl), true)
        for j = 1, 3 do
            Film.Glow(L, SPARK, war.x + (j - 2) * 0.3, war.y - 0.4 - hl * (0.8 + j * 0.25), 0.45, 0.45, 1, 1, 0.7,
                      1 - hl, true)
        end
    end
    local hn = Age(t, 4.2, 1.1)
    if hn then Film.Number(L, war.x, war.y - 1.4, "+27", 0.25, 1, 0.25, hn) end
    if dead then war.act = nil end
end

local FILM_SHOTS = {
    -- the Abbey's doors: three heroes come out into the morning; Deputy Willem has work for them
    -- (the way out is the Abbey's own walk grid: the hall ends in its door at about 4130.75, 6234.9, then the porch
    -- turns and its steps run south to the yard; a hero is not seen until it steps through the door, as the game
    -- hides who is inside a building while you are out)
    { name = "Northshire Abbey", cam = { 4130.2, 6235.8, 4128.6, 6240.2 }, zoom = { 1.25, 0.98 },
      marks = { ["Deputy Willem"] = true },
      setup = function()
          local war = Film.Body(FilmHero("WARRIOR0"), 4131.3, 6234.88, "left")
          local mage = Film.Body(FilmHero("MAGE1"), 4131.3, 6234.88, "left")
          local pri = Film.Body(FilmHero("PRIEST0"), 4131.3, 6234.88, "left")
          war.alpha, mage.alpha, pri.alpha = 0, 0, 0
          return { war = war, mage = mage, pri = pri }
      end,
      act = function(L, t, dt)
          local C = L.cast
          local function out(x, y)
              return { { 4130.4, 6234.95 }, { 4129.62, 6235.3 }, { 4129.62, 6236.6 }, { 4128.62, 6236.95 },
                       { 4128.62, 6239.5 }, { x, y } }
          end
          Walks(t, dt, { { C.war, 0.3, out(4129.4, 6241.3), "up", 1.5 }, { C.mage, 0.8, out(4127.7, 6241.5), "up", 1.5 },
                         { C.pri, 1.3, out(4128.7, 6242.3), "up", 1.5 } })
          for _, b in pairs(C) do
              -- (still in the hall: unseen; through the door: there at once, as a body stepping out)
              if b.x > 4130.72 then b.alpha = 0 else b.alpha = min(1, (b.alpha or 0) + dt * 8) end
          end
      end },
    -- Echo Ridge Mine: on the meadow under its mouth a kobold worker meets the warrior's sword, the mage's fire and
    -- the priest's light; the other kobolds' candles flicker round them
    { name = "Echo Ridge Mine", cam = { 4120.6, 6182.4, 4121.4, 6183.6 }, zoom = { 1.04, 1.14 },
      clear = { { 4120.5, 6185, 3.2 } },
      setup = function()
          local foe = Film.Body(FilmSprite({ e = 257 }) or 38, 4122.4, 6185.0, "left")
          foe.candle = true
          return { foe = foe,
                   war = Film.Body(FilmHero("WARRIOR1"), 4121.5, 6185.0, "right"),
                   mage = Film.Body(FilmHero("MAGE0"), 4118.3, 6185.8, "right"),
                   pri = Film.Body(FilmHero("PRIEST1"), 4118.6, 6183.8, "right") }
      end,
      act = function(L, t) Fight(L, t) end },
    -- over the river's bridge into the vines, the Defias among them
    { name = "Northshire Vineyards", cam = { 4169, 6254.5, 4177, 6265.5 }, zoom = { 1.04, 0.96 } },
    -- the road out of the valley: down from the Abbey and west past the walled garden, toward Elwynn Forest
    { name = "Northshire Valley", follow = { 0.4, -0.6 }, area0 = { 4106, 6248, 4124, 6258 }, zoom = { 1.0, 1.06 },
      clear = { { 4116, 6254, 4 } },
      setup = function()
          return { war = Film.Body(FilmHero("WARRIOR0"), 4121.6, 6250.2, "down"),
                   mage = Film.Body(FilmHero("MAGE1"), 4122.4, 6249.3, "down"),
                   pri = Film.Body(FilmHero("PRIEST0"), 4121.0, 6249.0, "down") }
      end,
      act = function(L, t, dt)
          local C = L.cast
          Walks(t, dt, { { C.war, 0, { { 4118.6, 6254.6 }, { 4108, 6256.9 } }, nil, 1.45 },
                         { C.mage, 0.15, { { 4119.6, 6254.0 }, { 4109.2, 6256.2 } }, nil, 1.45 },
                         { C.pri, 0.3, { { 4118.4, 6253.4 }, { 4109.0, 6255.5 } }, nil, 1.45 } })
      end },
}
Film.SHOTS = FILM_SHOTS

COVERS.disastercraft = function(parent, poster)
    local c = CreateFrame("Frame", nil, poster.artFrame)
    c:SetAllPoints(poster.artFrame)
    local WS = ns.AzeroLand
    if not WS or not WS.GroundTile then return c end
    local base = c:GetFrameLevel()
    c.reels = { Film.NewReel(c, base + 1), Film.NewReel(c, base + 3 + FILM_DEPTH) }
    -- over the film: cloud shadows drifting by, a warm light from the top, the place's name
    c.sky = CreateFrame("Frame", nil, c)
    c.sky:SetAllPoints()
    c.sky:SetFrameLevel(base + 5 + 2 * FILM_DEPTH)
    c.clouds = {}
    for k = 1, 3 do
        local t = c.sky:CreateTexture(nil, "BACKGROUND")
        t:SetTexture(RADIAL)
        t:SetVertexColor(0, 0, 0)
        t:SetAlpha(0.2)
        c.clouds[k] = { tex = t, x = (k - 1) * 260 - 80, y = (k * 170) % 380 - 40, w = 300 + k * 70, h = 210 + k * 40 }
    end
    c.light = c.sky:CreateTexture(nil, "ARTWORK")
    c.light:SetPoint("TOPLEFT")
    c.light:SetPoint("TOPRIGHT")
    c.light:SetBlendMode("ADD")
    Gradient(c.light, "VERTICAL", 1, 0.75, 0.4, 0, 1, 0.75, 0.4, 0.16)
    -- (the name is on the poster's words layer: always over the art, whatever the film's frames do)
    c.cap = Label(parent, 21, "GameFontNormalHuge")
    c.cap:SetJustifyH("CENTER")
    c.cap:SetFont("Fonts\\MORPHEUS.TTF", 21, "OUTLINE")
    c.cap:SetTextColor(1, 0.82, 0)
    c.cap:SetShadowOffset(1, -1)
    c.capRule = parent:CreateTexture(nil, "ARTWORK")
    c.capRule:SetHeight(1)
    c.capRule:SetWidth(150)
    c.capRule:SetPoint("TOP", c.cap, "BOTTOM", 0, -6)
    Gradient(c.capRule, "HORIZONTAL", 1, 0.82, 0, 0.7, 1, 0.82, 0, 0.7)
    c.capFade = {}
    for k, side in ipairs({ "LEFT", "RIGHT" }) do
        local t = parent:CreateTexture(nil, "ARTWORK")
        t:SetHeight(1)
        t:SetWidth(60)
        t:SetPoint(k == 1 and "RIGHT" or "LEFT", c.capRule, side, 0, 0)
        if k == 1 then Gradient(t, "HORIZONTAL", 1, 0.82, 0, 0, 1, 0.82, 0, 0.7)
        else Gradient(t, "HORIZONTAL", 1, 0.82, 0, 0.7, 1, 0.82, 0, 0) end
        c.capFade[k] = t
    end
    c.live, c.shotIdx = 1, 1
    c.reels[2].frame:Hide()
    Film.Begin(c.reels[1], FILM_SHOTS[1])
    c.cap:SetText(FILM_SHOTS[1].name)

    -- the view: the art box (Place hands the poster's size; its art box is 1 px in on each side)
    local function View(self)
        if self.vw then return self.vw, self.vh end
        local w, h = self:GetSize()
        if not w or w < 10 or not h or h < 10 then w, h = FRONT_W - 2, 380 end
        return w, h
    end
    function c:Layout(w, h)
        self.vw, self.vh = max(10, w - 2), max(10, h + 51)
        self.light:SetHeight(max(1, (h + 52) * 0.45))
        self.cap:ClearAllPoints()
        self.cap:SetPoint("TOP", self, "TOP", 0, -max(44, (h + 52) * 0.12))
    end
    function c:Refresh() end
    -- The film's frames in order, just under the poster's words: reel 1 (its ground, depth frames, glows), reel 2,
    -- the sky. Put back every frame should a level change elsewhere (the carousel raising its front poster) have
    -- moved them apart: a depth frame over the sky drew the scenery over the light and the clouds.
    local function Relevel(self)
        local top = poster.over:GetFrameLevel() - 1
        if self.sky:GetFrameLevel() == top and self.lvTop == top then return end
        self.lvTop = top
        local lv = top - 2 * (FILM_DEPTH + 2) - 1
        self:SetFrameLevel(lv)
        for _, L in ipairs(self.reels) do
            lv = lv + 1
            L.frame:SetFrameLevel(lv)
            for k = 1, FILM_DEPTH do L.depth[k]:SetFrameLevel(lv + k) end
            L.over:SetFrameLevel(lv + FILM_DEPTH + 1)
            lv = lv + FILM_DEPTH + 1
        end
        self.sky:SetFrameLevel(top)
    end
    -- (time jumps: the hub hands at most 0.1 s a frame)
    function c:Tick(elapsed)
        Relevel(self)
        local w, h = View(self)
        local A = self.reels[self.live]
        local B = self.reels[3 - self.live]
        Film.Frame(A, elapsed, w, h)
        local into = A.t - FILM_SHOT
        if into >= 0 then
            if not B.frame:IsShown() then
                self.shotIdx = self.shotIdx % #FILM_SHOTS + 1
                Film.Begin(B, FILM_SHOTS[self.shotIdx])
                B.frame:SetAlpha(0)
                self.cap:SetText(FILM_SHOTS[self.shotIdx].name)
            end
            Film.Frame(B, elapsed, w, h)
            -- (a true cross-fade either way round: the upper reel fades in over the lower, or out from over it)
            local a = min(1, into / FILM_FADE)
            if self.live == 1 then B.frame:SetAlpha(a) else A.frame:SetAlpha(1 - a) B.frame:SetAlpha(1) end
            if a >= 1 then
                A.frame:Hide()
                A.frame:SetAlpha(1)
                B.frame:SetAlpha(1)
                self.live = 3 - self.live
            end
        end
        -- the name of the newest shot: in after a beat, out before the cut (the front poster only; the last shot's
        -- name is gone before the next one begins)
        local L = B.frame:IsShown() and B or A
        local t = L.t
        local ca = min(1, max(0, (t - 0.5) / 0.8), max(0, (FILM_SHOT - 0.3 - t) / 0.7))
        if poster.off ~= 0 then ca = 0 end
        self.cap:SetAlpha(ca)
        self.capRule:SetAlpha(ca)
        for _, f in ipairs(self.capFade) do f:SetAlpha(ca) end
        self.capRule:SetWidth(40 + 110 * min(1, max(0, (t - 0.6) / 1.2)))
        -- the clouds' shadows sail east-south-east and come round again
        for _, cl in ipairs(self.clouds) do
            cl.x = cl.x + elapsed * 9
            cl.y = cl.y + elapsed * 2.5
            if cl.x > w + 40 then cl.x, cl.y = -cl.w - 40, (cl.y + 170) % (h + 120) - 120 end
            cl.tex:ClearAllPoints()
            cl.tex:SetPoint("TOPLEFT", self, "TOPLEFT", cl.x, -cl.y)
            cl.tex:SetSize(cl.w, cl.h)
        end
    end
    -- (for the test suites and the audit: shot i, t seconds in)
    function c:Seek(i, t)
        self.reels[2].frame:Hide()
        self.reels[1].frame:SetAlpha(1)
        self.live, self.shotIdx = 1, i
        Film.Begin(self.reels[1], FILM_SHOTS[i])
        self.cap:SetText(FILM_SHOTS[i].name)
        local n = floor((t or 0) / 0.05 + 0.5)
        for _ = 1, n do self:Tick(0.05) end
        if n == 0 then self:Tick(0) end
    end
    c:Tick(0)
    return c
end
GamesUI.Film = Film     -- (for the test suites)

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
    p.over:SetFrameLevel(p:GetFrameLevel() + 20)    -- (over the cover's film: see COVERS.disastercraft)
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
    p.top:SetFrameLevel(p:GetFrameLevel() + 40)
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
    if p.id ~= "disastercraft" then
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
    local want = carousel:GetFrameLevel() + (front and 60 or 5)
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
        b:SetFrameLevel(carousel:GetFrameLevel() + 120)
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
-- Disastercraft's film: shot i, t seconds in (for the test suites and the audit)
function GamesUI:FilmSeek(i, t)
    for _, p in ipairs(posters) do
        if p.id == "disastercraft" and p.cover and p.cover.Seek then p.cover:Seek(i, t) end
    end
end
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
