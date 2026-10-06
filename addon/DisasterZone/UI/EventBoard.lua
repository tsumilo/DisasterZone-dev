if DisasterZoneBoot and DisasterZoneBoot.Run("UI/EventBoard.lua", ...) then return end -- DisasterZone: an event's live board.
-- The live board (mockup shots 7-8): its own window that draws a running event from its state (EventLive:GetState):
--   the header (the event's art, Live / Practice / Ended, the title, how many watch, share and a More menu, the stage
--   progress and "You're up next"); the bracket on the left (single elimination as columns of match cards joined by
--   lines, the champion's slot over the final; a round robin as standings and this round's matches; before the
--   bracket, who signed up); the rail on the right (the matches being played with their game pips and clocks, my next
--   match, the moments worth telling).
--   The host's board adds a gold bar (pause, the More menu for the rare fixes) and the dispute card: a game the two
--   players disagree on, with what each of them said and the host's three answers.
-- Board.H: small drawing helpers the tracker (UI/EventTracker.lua) shares.
local addonName, ns = ...

local Board = ns:NewModule("EventBoard")

local CreateFrame = CreateFrame
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tsort, tconcat = table.sort, table.concat
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber

local function UI() return ns.UI end
local function EUI() return ns.EventUI end
local function L() return ns.EventLive end
local function E() return ns.EventEngine end
local function B() return ns.EventBlocks end
local function Ev() return ns.Events end
local function Me() return ns.Util.PlayerKey() end
local function DemoOn() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() or false end
local function ServerNow() return (GetServerTime and GetServerTime()) or time() end

local WIN_W, WIN_H = 800, 608
local CW, CH = 790, 576            -- the window's inside (BasicFrameTemplateWithInset's inset, 3px in)
local HDR_H, HOST_H = 98, 34
local BR_X, BR_Y, BR_W = 12, 106, 560
local RAIL_W = 196
local DISP_W = 296
local CARD_W, ROW_H = 122, 19
local COL_GAP_MIN = 14
local BOTTOM = 10

local WHITE = "Interface\\Buttons\\WHITE8X8"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local RING = "Interface\\AddOns\\DisasterZone\\Media\\Events\\ring"
local WARN = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"

local BG = { 0.043, 0.043, 0.051 }               -- the board's floor
local CARD_BG = { 0.086, 0.086, 0.106, 0.96 }
local CARD_EDGE = { 0.34, 0.34, 0.38, 0.6 }
local LIVE_EDGE = { 1, 0.38, 0.29, 0.85 }
local NEXT_EDGE = { 0.4, 0.72, 1, 0.75 }
local RED = { 1, 0.35, 0.27 }
local GOLD = { 1, 0.82, 0 }
local GREY = { 0.62, 0.62, 0.62 }
local DIM = { 0.44, 0.44, 0.46 }
local YOU_ROW = { 0.62, 0.82, 1 }
local TBD = { 0.40, 0.40, 0.43 }

local win
local state = { occ = nil }

---------------------------------------------------------------------------
-- Helpers (shared with the tracker)
---------------------------------------------------------------------------

local H = {}
Board.H = H

function H.Sized(fs, size)
    local path, _, flags = fs:GetFont()
    if path then fs:SetFont(path, size, flags) end
    return fs
end

-- A one-line text in a game font (shadowed like the game's), sized and coloured.
function H.Text(parent, font, size, r, g, b, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then H.Sized(fs, size) end
    if r then fs:SetTextColor(r, g, b) end
    return fs
end

-- A text's whole width on one line (GetStringWidth stops at a width the string was given).
function H.Width(fs)
    if fs.GetUnboundedStringWidth then return fs:GetUnboundedStringWidth() or 0 end
    return fs:GetStringWidth() or 0
end

-- Sets the text, a size smaller each time it does not fit width (down to minSize). True when it fits.
function H.Fit(fs, text, width, size, minSize)
    fs:SetText(text or "")
    size = size or 12
    for s = size, minSize or size, -1 do
        H.Sized(fs, s)
        if H.Width(fs) <= width then return true end
    end
    return false
end

-- The first of the texts that fits at the size; else the last one, smaller. shrink: each text may go down to
-- minSize before the next one is tried (a slot's names before its label).
function H.FitAny(fs, list, width, size, minSize, shrink)
    for i = 1, #list - 1 do
        if shrink then
            if H.Fit(fs, list[i], width, size, minSize) then return true end
        else
            H.Sized(fs, size)
            fs:SetText(list[i])
            if H.Width(fs) <= width then return true end
        end
    end
    return H.Fit(fs, list[#list], width, size, minSize)
end

function H.Hex(c) return ("|cff%02x%02x%02x"):format(floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5)) end
function H.Grey(text) return "|cff9e9e9e" .. tostring(text) .. "|r" end

function H.Disc(parent, layer, sub, size, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    t:SetTexture(DISC)
    t:SetSize(size, size)
    t:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
    return t
end

-- A fill and a 1px edge (soft corners) on a frame.
function H.Panel(f, fill, edge, layer)
    f.bg = f.bg or f:CreateTexture(nil, layer or "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(fill[1], fill[2], fill[3], fill[4] or 1)
    if not f.edges then UI():AddEdges(f, "BORDER", true) end
    UI():SetEdgeColor(f, edge[1], edge[2], edge[3], edge[4] or 1)
end

function H.Contains(list, v)
    for i = 1, #(list or {}) do if list[i] == v then return i end end
    return nil
end

-- "1:42", "12:05", "1:02:03".
function H.Clock(sec)
    sec = max(0, floor(tonumber(sec) or 0))
    if sec >= 3600 then return ("%d:%02d:%02d"):format(floor(sec / 3600), floor(sec % 3600 / 60), sec % 60) end
    return ("%d:%02d"):format(floor(sec / 60), sec % 60)
end

-- The run's clock: the practice run's own, else the server's.
function H.Now(occ)
    if occ == "practice" and L() and L().PracticeNow then return L():PracticeNow() end
    return ServerNow()
end

-- A class circle (a grey disc for nobody); dim: the loser's look.
function H.SetClass(tex, key, dim)
    tex:SetVertexColor(1, 1, 1, 1)
    EUI():SetClass(tex, key)
    if dim then
        tex:SetDesaturated(true)
        tex:SetVertexColor(0.6, 0.6, 0.6, 1)
    end
    tex:Show()
end

function H.Plain(key)
    if key and ns.Util.IsMe(key) then return "You" end
    return EUI():Plain(key)
end

function H.Name(key) return EUI():Name(key) end

-- First to how many game wins.
function H.Need(bo) return floor((tonumber(bo) or 1) / 2) + 1 end

function H.BoOf(bk, m)
    return tonumber(m.bo) or ((m.final or m.bronze) and tonumber(bk.fbo) or tonumber(bk.bo)) or 1
end

-- The round of a match in words: "Quarterfinal", "Semifinal", "Final", "Round 2", "3rd place match".
function H.RoundTitle(bk, r, m)
    if m and m.bronze then return "3rd place match" end
    if bk.fmt == "robin" then return "Round " .. r end
    local left = (bk.last or 1) - r
    if left == 0 then return "Final" end
    if left == 1 then return "Semifinal" end
    if left == 2 then return "Quarterfinal" end
    return "Round " .. r
end

-- A round as a whole: "Quarterfinals", "Semifinals", "The final", "Round 2".
function H.RoundPlural(bk, r)
    if bk.fmt == "robin" then return "Round " .. r end
    local left = (bk.last or 1) - r
    if left == 0 then return "The final" end
    if left == 1 then return "Semifinals" end
    if left == 2 then return "Quarterfinals" end
    return "Round " .. r
end

-- A match by name: "Semifinal 1", "Quarterfinal 3", "the final", "match 12".
function H.MatchLabel(bk, f)
    if not f then return "" end
    if f.bronze then return "3rd place" end
    if bk.fmt == "robin" then return "Round " .. f.r end
    local left = (bk.last or 1) - f.r
    if left == 0 then return "Final" end
    if left <= 2 then return H.RoundTitle(bk, f.r) .. " " .. f.i end
    return "Round " .. f.r .. " · " .. f.i
end

-- The text in a match's empty slot (side "a" | "b"): "Ysolde / Orrigan", "Semifinal 1", "Loser of Semifinal 1".
function H.SlotText(bk, m, side)
    local fid = side == "a" and (m.fa or m.la) or (m.fb or m.lb)
    local loser = (side == "a" and m.la) or (side == "b" and m.lb)
    local f = fid and bk.m[fid]
    if not f then return { "" } end
    local label = (loser and "Loser of " or "") .. H.MatchLabel(bk, f)
    if type(f.a) == "string" and type(f.b) == "string" and f.st ~= "done" then
        return { H.Plain(f.a) .. " / " .. H.Plain(f.b), label }
    end
    return { label }
end

function H.SeedOf(bk, key) return H.Contains(bk.seeds, key) end

-- The other player of a match.
function H.Opp(m, key)
    if m.a == key then return m.b end
    if m.b == key then return m.a end
    return nil
end

function H.Where(occ)
    if occ == "practice" then return nil end
    local o = Ev() and Ev():GetOcc(occ)
    local w = o and o.where
    if type(w) == "string" and w ~= "" then return w end
    return nil
end

-- "Ring of Trials" from "Ring of Trials, Nagrand".
function H.Place(occ)
    local w = H.Where(occ)
    return w and (w:match("^([^,]+)") or w) or nil
end

-- The matches being played: mine first, then the oldest.
function H.Playing(bk)
    local out = {}
    for r = 1, bk.last or 0 do
        for _, mid in ipairs(bk.rounds[r] or {}) do
            local m = bk.m[mid]
            if m and m.st == "play" then out[#out + 1] = m end
        end
    end
    local me = Me()
    tsort(out, function(x, y)
        local xm, ym = (x.a == me or x.b == me), (y.a == me or y.b == me)
        if xm ~= ym then return xm end
        if (x.t or 0) ~= (y.t or 0) then return (x.t or 0) < (y.t or 0) end
        return x.id < y.id
    end)
    return out
end

-- My next match not played yet (this round or a later one), or nil. None for a player taken out (their later
-- matches are walkovers).
function H.MyNext(bk, key)
    if bk.out and bk.out[key] then return nil end
    for r = max(1, bk.r or 1), bk.last or 0 do
        for _, mid in ipairs(bk.rounds[r] or {}) do
            local m = bk.m[mid]
            if m and (m.a == key or m.b == key) and (m.st == "wait" or m.st == "play") then return m end
        end
    end
    return nil
end

-- The next match to start (the first one waiting in the current round with both players), or nil.
function H.NextUp(bk)
    for _, mid in ipairs(bk.rounds[bk.r or 0] or {}) do
        local m = bk.m[mid]
        if m and m.st == "wait" and m.a and m.b then return m end
    end
    return nil
end

-- Names in a moment's text in their class colour ("You" in blue).
function H.ColorNames(text, keys)
    text = tostring(text or "")
    local done = {}
    for _, k in ipairs(keys or {}) do
        local n = EUI():Plain(k)
        if type(n) == "string" and #n >= 3 and not done[n] and not n:find("[%%%[%]%^%$%(%)%.%*%+%-%?]") then
            done[n] = true
            local colored = ns.Util.IsMe(k) and "|cff66b8ff" .. n .. "|r" or EUI():Name(k, true)
            text = text:gsub("%f[%w]" .. n .. "%f[^%w]", colored)
        end
    end
    text = text:gsub("^You%f[^%w]", "|cff66b8ffYou|r")
    return text
end

-- Game pips: a row of rings, the won ones gold discs. p:Set(n, won). alpha: the empty rings' (0.3 on a card).
function H.NewPips(parent, size, gap, alpha)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(size, size)
    p.dots = {}
    function p:Set(n, won)
        n = max(0, min(7, n or 0))
        for i = 1, n do
            local d = self.dots[i]
            if not d then
                d = { ring = self:CreateTexture(nil, "ARTWORK", nil, 1), fill = H.Disc(self, "ARTWORK", 2, size, 1, 0.82, 0, 1) }
                d.ring:SetTexture(RING)
                d.ring:SetSize(size + 1, size + 1)
                d.ring:SetVertexColor(1, 1, 1, alpha or 0.32)
                self.dots[i] = d
            end
            local x = (i - 1) * (size + gap)
            for _, t in pairs(d) do
                t:ClearAllPoints()
                t:SetPoint("CENTER", self, "LEFT", x + size / 2, 0)
            end
            local on = i <= (won or 0)
            d.ring:SetShown(not on)
            d.fill:SetShown(on)
        end
        for i = n + 1, #self.dots do
            for _, t in pairs(self.dots[i]) do t:Hide() end
        end
        self:SetWidth(max(1, n * size + max(0, n - 1) * gap))
    end
    return p
end

-- A ring timer: the track and a gold (or any colour) arc of what is left, the time in the middle.
-- r:Set(left, total [, color]).
function H.NewRing(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.hole = H.Disc(f, "BACKGROUND", 1, size - 2, 0.09, 0.09, 0.106, 1)
    f.hole:SetPoint("CENTER")
    f.track = f:CreateTexture(nil, "ARTWORK", nil, 0)
    f.track:SetTexture(RING)
    f.track:SetAllPoints()
    f.track:SetVertexColor(1, 1, 1, 0.14)
    f.arc = {}
    local n = 40
    local rad = size / 2 - size * 0.047 - 0.15
    local dot = max(2.4, size * 0.094)
    for i = 1, n do
        local a = (i - 0.5) / n * 2 * math.pi
        local t = H.Disc(f, "ARTWORK", 1, dot, 1, 0.82, 0, 1)
        t:SetPoint("CENTER", f, "CENTER", math.sin(a) * rad, math.cos(a) * rad)
        f.arc[i] = t
    end
    f.fs = H.Text(f, "GameFontHighlight", max(9, floor(size * 0.32)), 1, 1, 1)
    f.fs:SetJustifyH("CENTER")
    f.fs:SetPoint("CENTER", 0.5, 0)
    function f:Set(left, total, color)
        left, total = max(0, tonumber(left) or 0), max(1, tonumber(total) or 1)
        local c = color or GOLD
        local on = ceil(min(1, left / total) * n - 0.001)
        for i = 1, n do
            local t = self.arc[i]
            -- the arc that is left runs clockwise from the top
            t:SetShown(i <= on)
            t:SetVertexColor(c[1], c[2], c[3], 1)
        end
        self.fs:SetText(H.Clock(left))
    end
    return f
end

-- A rounded pill: Live (a red dot), Practice (teal), Paused, Ended, Now.
local PILL = {
    live = { text = { 1, 0.77, 0.72 }, tint = { 0.9, 0.16, 0.1 }, a = 0.22, edge = { 1, 0.38, 0.29, 0.8 }, dot = true },
    practice = { text = { 0.62, 0.95, 0.86 }, tint = { 0.24, 0.82, 0.68 }, a = 0.14, edge = { 0.37, 0.88, 0.76, 0.6 } },
    paused = { text = { 1, 0.72, 0.45 }, tint = { 1, 0.55, 0.1 }, a = 0.13, edge = { 1, 0.55, 0.1, 0.65 } },
    ended = { text = { 0.74, 0.74, 0.74 }, tint = { 1, 1, 1 }, a = 0.05, edge = { 1, 1, 1, 0.22 } },
}
function H.NewPill(parent, h, base)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(30, h)
    UI():AddPillShape(p, h)
    p.base = base or BG
    p.glow = H.Disc(p, "ARTWORK", 0, 12, 1, 0.35, 0.27, 0.3)
    p.dot = H.Disc(p, "ARTWORK", 1, 6, 1, 0.35, 0.27, 1)
    p.fs = H.Text(p, "GameFontHighlightSmall", 10)
    function p:SetKind(text, kind)
        local d = PILL[kind] or PILL.ended
        local b, t = self.base, d.tint
        self:SetPillColors({ b[1] + (t[1] - b[1]) * d.a, b[2] + (t[2] - b[2]) * d.a, b[3] + (t[3] - b[3]) * d.a, 1 }, d.edge)
        self.fs:SetText(text or "")
        self.fs:SetTextColor(d.text[1], d.text[2], d.text[3])
        local x = 7
        self.dot:SetShown(d.dot and true or false)
        self.glow:SetShown(d.dot and true or false)
        if d.dot then
            self.dot:ClearAllPoints()
            self.dot:SetPoint("CENTER", self, "LEFT", 9, 0)
            self.glow:ClearAllPoints()
            self.glow:SetPoint("CENTER", self.dot)
            x = 15
        end
        self.fs:ClearAllPoints()
        self.fs:SetPoint("LEFT", x, 0)
        self:SetWidth(floor(x + (self.fs:GetStringWidth() or 16) + 7 + 0.5))
    end
    return p
end

-- An atlas glyph in front of a menu entry.
local function Glyph(i, color) return UI():AtlasIconText(i, 13, color) .. "  " end

---------------------------------------------------------------------------
-- The state the board shows
---------------------------------------------------------------------------

local function Data()
    local occ = state.occ
    if not occ then return nil end
    local st, def = L():GetState(occ), L():GetDef(occ)
    local bk = st and def and E():BracketOf(def, st) or nil
    return occ, st, def, bk
end

-- I run this event while it's on (the host's controls); never in demo mode or for the practice run.
function Board:IsHost()
    local occ = state.occ
    if not occ or occ == "practice" or DemoOn() or not L():IsHostOf(occ) then return false end
    local st = L():GetState(occ)
    return (st and st.phase == "live") and true or false
end

-- Who signed up (the sign-up blocks' lists), first come first.
function H.SignedUp(st)
    local list = {}
    for _, b in pairs(st and st.blocks or {}) do
        if type(b) == "table" and b.kind == "signup" and type(b.list) == "table" then
            for _, k in ipairs(b.list) do if not H.Contains(list, k) then list[#list + 1] = k end end
        end
    end
    return list
end

-- The asks that are the host's to settle (a dispute): to me, not answered, not one I play in (or with claims).
local function Disputes(st)
    local out = {}
    local me = Me()
    for _, a in pairs(st and st.asks or {}) do
        if type(a) == "table" and H.Contains(a.to, me) and a.ans and a.ans[me] == nil
            and (a.claims ~= nil or not H.Contains(a.opts, me)) then
            out[#out + 1] = a
        end
    end
    tsort(out, function(x, y) return (x.id or 0) < (y.id or 0) end)
    return out
end
Board.Disputes = function(_, st) return Disputes(st) end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local NewCard

local function HeaderLayout()
    local hdr = win.hdr
    -- right to left: More, Share, "N watching"
    local x = -12
    hdr.more:ClearAllPoints()
    hdr.more:SetPoint("RIGHT", hdr, "TOPRIGHT", x, -23)
    local anchor = hdr.more
    if hdr.share and hdr.share:IsShown() then
        hdr.share:ClearAllPoints()
        hdr.share:SetPoint("RIGHT", anchor, "LEFT", -6, 0)
        anchor = hdr.share
    end
    hdr.watch:ClearAllPoints()
    hdr.watch:SetPoint("RIGHT", anchor, "LEFT", -12, 0)
end

local function CreateWindow()
    local f = UI():CreateWindow("DisasterZoneEventBoard", "Event", WIN_W, WIN_H)
    f:SetFrameStrata("HIGH")
    win = f
    local root = CreateFrame("Frame", nil, f.content)
    root:SetPoint("TOPLEFT")
    root:SetPoint("BOTTOMRIGHT")
    f.root = root
    root.bg = root:CreateTexture(nil, "BACKGROUND", nil, -8)
    root.bg:SetAllPoints()
    root.bg:SetColorTexture(BG[1], BG[2], BG[3], 1)

    ------------------------------------------------------------------ header
    local hdr = CreateFrame("Frame", nil, root)
    hdr:SetPoint("TOPLEFT")
    hdr:SetPoint("TOPRIGHT")
    hdr:SetHeight(HDR_H)
    f.hdr = hdr
    hdr.art = hdr:CreateTexture(nil, "BACKGROUND", nil, 1)
    hdr.art:SetAllPoints()
    EUI():AddShade(hdr)
    -- the bottom melts into the board
    hdr.melt = hdr:CreateTexture(nil, "BORDER", nil, 3)
    hdr.melt:SetPoint("BOTTOMLEFT")
    hdr.melt:SetPoint("BOTTOMRIGHT")
    hdr.melt:SetHeight(26)
    hdr.melt:SetTexture(WHITE)
    EUI():Gradient(hdr.melt, "VERTICAL", BG[1], BG[2], BG[3], 1, 0)

    hdr.pill = H.NewPill(hdr, 16, { 0.05, 0.05, 0.06 })
    hdr.pill:SetPoint("LEFT", hdr, "TOPLEFT", 14, -23)
    hdr.title = H.Text(hdr, "GameFontHighlightLarge", 18, 1, 1, 1)
    hdr.title:SetPoint("LEFT", hdr.pill, "RIGHT", 9, 0)
    hdr.more = UI():CreateTipIconButton(hdr, 22, UI().ICON.more, "More", "The event page, the host, leaving the event.",
        function(b) Board:HeaderMenu(b) end)
    if ns.Share and ns.Share.CreateButton then
        hdr.share = ns.Share:CreateButton(hdr, 22, function() return Board:ShareRef() end, "Share the event")
    end
    hdr.watch = H.Text(hdr, "GameFontHighlightSmall", 11, 0.74, 0.74, 0.74)
    hdr.eye = hdr:CreateTexture(nil, "ARTWORK")
    hdr.eye:SetSize(13, 13)
    EUI():Glyph(hdr.eye, UI().ICON.eye, 1, 1, 1, 0.7)
    hdr.eye:SetPoint("RIGHT", hdr.watch, "LEFT", -5, 0)
    HeaderLayout()

    hdr.prog = EUI():CreateProgress(hdr)
    hdr.prog:SetPoint("LEFT", hdr, "BOTTOMLEFT", 14, 23)
    -- "You're up next": a blue chip with the opponent's class
    local chip = CreateFrame("Frame", nil, hdr)
    chip:SetSize(100, 22)
    UI():AddPillShape(chip, 22)
    chip:SetPillColors({ 0.055, 0.055, 0.066, 1 }, { 0.4, 0.72, 1, 0.75 })
    chip.cls = chip:CreateTexture(nil, "ARTWORK")
    chip.cls:SetSize(15, 15)
    chip.cls:SetPoint("LEFT", 6, 0)
    chip.fs = H.Text(chip, "GameFontHighlightSmall", 11, 0.84, 0.93, 1)
    chip.fs:SetPoint("LEFT", chip.cls, "RIGHT", 6, 0)
    chip:SetPoint("RIGHT", hdr, "BOTTOMRIGHT", -12, 23)
    chip:EnableMouse(true)
    chip:SetScript("OnEnter", function(self)
        if not self.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine(self.tip[1])
        if self.tip[2] then GameTooltip:AddLine(self.tip[2], 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    hdr.chip = chip

    ------------------------------------------------------------------ host bar
    local hb = CreateFrame("Frame", nil, root)
    hb:SetPoint("TOPLEFT", 0, -HDR_H)
    hb:SetPoint("TOPRIGHT", 0, -HDR_H)
    hb:SetHeight(HOST_H)
    hb:SetFrameLevel(root:GetFrameLevel() + 5)
    hb.bg = hb:CreateTexture(nil, "BACKGROUND")
    hb.bg:SetAllPoints()
    hb.bg:SetColorTexture(0.42, 0.30, 0.04, 0.2)
    for i, p in ipairs({ "TOP", "BOTTOM" }) do
        local t = hb:CreateTexture(nil, "BORDER")
        t:SetPoint(p .. "LEFT")
        t:SetPoint(p .. "RIGHT")
        t:SetHeight(1)
        t:SetColorTexture(1, 0.82, 0, 0.3)
        hb["line" .. i] = t
    end
    hb.crown = hb:CreateTexture(nil, "ARTWORK")
    hb.crown:SetSize(14, 14)
    EUI():Glyph(hb.crown, UI().ICON.crown, 1, 0.82, 0)
    hb.crown:SetPoint("LEFT", 12, 0)
    hb.t = H.Text(hb, "GameFontHighlight", 11.5, 1, 0.95, 0.8)
    hb.t:SetPoint("LEFT", hb.crown, "RIGHT", 6, 0)
    hb.t:SetText("You're hosting")
    hb.sub = H.Text(hb, "GameFontHighlightSmall", 10.5, 0.74, 0.71, 0.6)
    hb.sub:SetPoint("LEFT", hb.t, "RIGHT", 8, 0)
    hb.more = UI():CreateSleekMenuButton(hb, "More", 76, function(rootDesc) Board:HostMenu(rootDesc) end, 22)
    hb.more:SetPoint("RIGHT", -12, 0)
    hb.pause = UI():CreateSleekButton(hb, "Pause", 80, 22, function() Board:TogglePause() end)
    hb.pause:SetPoint("RIGHT", hb.more, "LEFT", -6, 0)
    local pfs = hb.pause:GetFontString()
    H.Sized(pfs, 11)
    pfs:ClearAllPoints()
    pfs:SetPoint("CENTER", 8, 0)
    hb.pause.icon = hb.pause:CreateTexture(nil, "ARTWORK")
    hb.pause.icon:SetSize(12, 12)
    hb.pause.icon:SetPoint("RIGHT", pfs, "LEFT", -6, 0)
    hb.pause:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local paused = L():IsPaused(state.occ)
        GameTooltip:AddLine(paused and "Resume" or "Pause")
        GameTooltip:AddLine(paused and "The clocks and timers go on from where they stopped."
            or "Stops the event's clocks and timers (no-shows too) until you resume. Duels still count.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    hb.pause:HookScript("OnLeave", function() GameTooltip:Hide() end)
    hb:Hide()
    f.hostbar = hb

    ------------------------------------------------------------------ the bracket and the rail
    local br = CreateFrame("Frame", nil, root)
    br:SetPoint("TOPLEFT", BR_X, -BR_Y)
    br:SetSize(BR_W, CH - BR_Y - BOTTOM)
    br.cards, br.lines, br.heads, br.rows = {}, {}, {}, {}
    f.br = br
    -- the champion's slot over the final
    local ch = CreateFrame("Frame", nil, br)
    ch:SetSize(112, 96)
    ch.halo = H.Disc(ch, "BACKGROUND", 0, 60, 1, 0.82, 0, 0.05)
    ch.halo:SetPoint("TOP", 0, 4)
    ch.outer = H.Disc(ch, "BACKGROUND", 1, 52, 1, 0.82, 0, 0.4)
    ch.outer:SetPoint("TOP", 0, 0)
    ch.inner = H.Disc(ch, "BACKGROUND", 2, 50, BG[1], BG[2], BG[3], 1)
    ch.inner:SetPoint("CENTER", ch.outer)
    ch.cup = ch:CreateTexture(nil, "ARTWORK")
    ch.cup:SetSize(26, 26)
    ch.cup:SetPoint("CENTER", ch.outer)
    ch.t = H.Text(ch, "GameFontHighlightSmall", 10, GREY[1], GREY[2], GREY[3])
    ch.t:SetJustifyH("CENTER")
    ch.t:SetPoint("TOP", ch.outer, "BOTTOM", 0, -6)
    ch.n = H.Text(ch, "GameFontHighlightSmall", 11, 0.37, 0.37, 0.4)
    ch.n:SetJustifyH("CENTER")
    ch.n:SetPoint("TOP", ch.t, "BOTTOM", 0, -2)
    br.champ = ch
    -- a line under the empty board ("Waiting for the host's board")
    br.note = H.Text(br, "GameFontHighlight", 12, GREY[1], GREY[2], GREY[3])
    br.note:SetJustifyH("CENTER")
    br.note:SetWordWrap(true)
    br.note:SetWidth(BR_W - 80)
    br.note:SetPoint("CENTER", 0, 20)

    local rail = CreateFrame("Frame", nil, root)
    rail:SetPoint("TOPRIGHT", -12, -BR_Y)
    rail:SetSize(RAIL_W, CH - BR_Y - BOTTOM)
    rail.nows, rail.moms, rail.heads = {}, {}, {}
    f.rail = rail

    ------------------------------------------------------------------ the dispute card (the host's)
    local d = CreateFrame("Frame", nil, root)
    d:SetSize(DISP_W, 170)
    d:SetFrameLevel(root:GetFrameLevel() + 20)
    d.bg = d:CreateTexture(nil, "BACKGROUND")
    d.bg:SetAllPoints()
    d.bg:SetTexture(WHITE)
    EUI():Gradient(d.bg, "VERTICAL", 0.09, 0.078, 0.055, 1, 1)
    if d.bg.SetGradient and CreateColor then
        d.bg:SetGradient("VERTICAL", CreateColor(0.09, 0.078, 0.055, 1), CreateColor(0.122, 0.102, 0.071, 1))
    end
    UI():AddEdges(d, "BORDER", true)
    UI():SetEdgeColor(d, 1, 0.55, 0.1, 0.7)
    -- a soft shadow: what lies close around the card dims
    d.shadow = d:CreateTexture(nil, "BACKGROUND", nil, -1)
    d.shadow:SetPoint("TOPLEFT", -6, 4)
    d.shadow:SetPoint("BOTTOMRIGHT", 6, -10)
    d.shadow:SetColorTexture(0, 0, 0, 0.45)
    d.shadow2 = d:CreateTexture(nil, "BACKGROUND", nil, -2)
    d.shadow2:SetPoint("TOPLEFT", -16, 12)
    d.shadow2:SetPoint("BOTTOMRIGHT", 16, -20)
    d.shadow2:SetColorTexture(0, 0, 0, 0.3)
    d.icon = d:CreateTexture(nil, "ARTWORK")
    d.icon:SetSize(15, 15)
    d.icon:SetTexture(WARN)
    d.icon:SetPoint("TOPLEFT", 12, -10)
    d.h1 = H.Text(d, "GameFontHighlight", 12.5, 1, 0.81, 0.6)
    d.h1:SetPoint("LEFT", d.icon, "RIGHT", 7, 0)
    d.p = H.Text(d, "GameFontHighlightSmall", 11, 0.81, 0.81, 0.81)
    d.p:SetWordWrap(true)
    d.p:SetSpacing(2)
    d.p:SetWidth(DISP_W - 24)
    d.p:SetPoint("TOPLEFT", 12, -32)
    d.cl = {}
    for i = 1, 2 do
        local r = {}
        r.cls = d:CreateTexture(nil, "ARTWORK")
        r.cls:SetSize(16, 16)
        r.name = H.Text(d, "GameFontHighlight", 11.5)
        r.name:SetPoint("LEFT", r.cls, "RIGHT", 7, 0)
        r.says = H.Text(d, "GameFontHighlightSmall", 10.5, GREY[1], GREY[2], GREY[3])
        r.says:SetJustifyH("RIGHT")
        d.cl[i] = r
    end
    d.btns = {}
    for i = 1, 3 do
        local b = UI():CreateSleekButton(d, "", 80, 22, function(self) Board:AnswerDispute(self.answer, self.replay) end)
        H.Sized(b:GetFontString(), 11)
        d.btns[i] = b
    end
    d:Hide()
    f.dispute = d

    ------------------------------------------------------------------ a confirm sheet over the board
    local dim = CreateFrame("Frame", nil, root)
    dim:SetAllPoints()
    dim:SetFrameLevel(root:GetFrameLevel() + 40)
    dim:EnableMouse(true)
    dim.bg = dim:CreateTexture(nil, "BACKGROUND")
    dim.bg:SetAllPoints()
    dim.bg:SetColorTexture(0, 0, 0, 0.6)
    local sh = CreateFrame("Frame", nil, dim)
    sh:SetSize(320, 130)
    sh:SetPoint("CENTER", 0, 30)
    H.Panel(sh, { 0.09, 0.09, 0.106, 1 }, { 0.47, 0.47, 0.51, 0.75 })
    sh.t = H.Text(sh, "GameFontNormal", 14)
    sh.t:SetPoint("TOPLEFT", 14, -14)
    sh.p = H.Text(sh, "GameFontHighlightSmall", 11, 0.81, 0.81, 0.81)
    sh.p:SetWordWrap(true)
    sh.p:SetSpacing(2)
    sh.p:SetWidth(292)
    sh.p:SetPoint("TOPLEFT", sh.t, "BOTTOMLEFT", 0, -8)
    sh.no = UI():CreateSleekButton(sh, "Keep going", nil, 24, function() dim:Hide() end)
    sh.no:SetPoint("BOTTOMRIGHT", -12, 12)
    sh.yes = UI():CreateSleekButton(sh, "OK", nil, 24, function()
        dim:Hide()
        if dim.fn then dim.fn() end
    end, "danger")
    sh.yes:SetPoint("RIGHT", sh.no, "LEFT", -6, 0)
    dim.sheet = sh
    dim:SetScript("OnMouseDown", function(self) self:Hide() end)
    dim:Hide()
    f.confirm = dim

    -- the clocks tick once a second (the rest redraws on a change)
    f.tick = 0
    f:SetScript("OnUpdate", function(self, dt)
        self.tick = self.tick + dt
        if self.tick < 1 then return end
        self.tick = 0
        Board:TickClocks()
    end)
    f:HookScript("OnHide", function()
        if L() and L().Unwatch then L():Unwatch() end
        if f.confirm then f.confirm:Hide() end
        if UI().CloseMenus then UI():CloseMenus() end
    end)
    f:Hide()
    return f
end

---------------------------------------------------------------------------
-- The header
---------------------------------------------------------------------------

function Board:ShareRef()
    local occ = state.occ
    if not occ or occ == "practice" or DemoOn() or not ns.Share then return nil end
    local ref = "event:" .. occ
    if ns.Share:Describe(ref) then return ref end
    if ns.Share:Describe("events") then return "events" end
    return nil
end

local function RefreshHeader(occ, st, def, bk)
    local hdr = win.hdr
    EUI():SetArt(hdr.art, def and def.art, CW, HDR_H, 0.5, 0.6, 0.98)
    local name = def and def.name or "Event"
    win:SetWindowTitle(name)
    -- the pill: Practice, Ended, Paused, Live
    if occ == "practice" then
        hdr.pill:SetKind("Practice", "practice")
    elseif st and (st.phase == "done" or st.phase == "cancelled") then
        hdr.pill:SetKind(st.phase == "cancelled" and "Cancelled" or "Ended", "ended")
    elseif st and st.paused then
        hdr.pill:SetKind("Paused", "paused")
    elseif st and st.phase == "live" then
        hdr.pill:SetKind("Live", "live")
    else
        hdr.pill:SetKind("Not started", "ended")
    end
    -- the right side: watching, share, more
    local share = hdr.share
    if share then share:SetShown(Board:ShareRef() ~= nil) end
    HeaderLayout()
    local n = st and tonumber(st.watch) or 0
    hdr.watch:SetText(n > 0 and (n .. " watching") or "")
    hdr.watch:SetShown(n > 0)
    hdr.eye:SetShown(n > 0)
    local rightW = 12 + 22 + ((share and share:IsShown()) and 28 or 0) + (n > 0 and (12 + (hdr.watch:GetStringWidth() or 0) + 18) or 0)
    local titleW = CW - 14 - hdr.pill:GetWidth() - 9 - rightW - 16
    H.Fit(hdr.title, name, titleW, 18, 13)
    hdr.title:SetWidth(titleW)
    -- the stage progress; the chip
    local sub = st and def and EUI():StageSub(def, st) or nil
    hdr.prog:Set(def, st, sub)
    local chip = hdr.chip
    chip.tip = nil
    local me = Me()
    local m = bk and H.MyNext(bk, me)
    local live = st and st.phase == "live"
    if live and m and m.st == "play" then
        chip:SetPillColors({ 0.075, 0.045, 0.045, 1 }, { 1, 0.38, 0.29, 0.8 })
        chip.fs:SetTextColor(1, 0.85, 0.8)
        chip.fs:SetText("Your match is on")
        chip.tip = { "Your match is on", "Duel " .. H.Plain(H.Opp(m, me)) .. (H.Place(occ) and (" at " .. H.Place(occ)) or "")
            .. ". Each duel counts by itself." }
    elseif live and m and m.st == "wait" and m.a and m.b and bk.r == m.r then
        chip:SetPillColors({ 0.055, 0.055, 0.066, 1 }, { 0.4, 0.72, 1, 0.75 })
        chip.fs:SetTextColor(0.84, 0.93, 1)
        chip.fs:SetText("You're up next")
        chip.tip = { "You're up next", "vs " .. H.Plain(H.Opp(m, me)) .. " · best of " .. H.BoOf(bk, m) }
    else
        m = nil
    end
    if m then
        H.SetClass(chip.cls, H.Opp(m, me))
        chip:SetWidth(floor(6 + 15 + 6 + (chip.fs:GetStringWidth() or 60) + 10 + 0.5))
        chip:Show()
    else
        chip:Hide()
    end
    -- the progress line and the chip share the row: no sub text when they would touch (then only the current
    -- stage's name)
    local room = CW - 14 - 12 - (chip:IsShown() and (chip:GetWidth() + 16) or 0)
    hdr.prog:SetMaxWidth(room)
    if (hdr.prog:GetWidth() or 0) > room then hdr.prog:Set(def, st, sub) end
end

---------------------------------------------------------------------------
-- The bracket: match cards, lines, round headers, the champion
---------------------------------------------------------------------------

local function NewRow(c)
    local r = {}
    r.seed = H.Text(c, "GameFontHighlightSmall", 9, 0.37, 0.37, 0.4)
    r.seed:SetJustifyH("RIGHT")
    r.cls = c:CreateTexture(nil, "ARTWORK")
    r.name = H.Text(c, "GameFontHighlight", 11)
    r.score = H.Text(c, "GameFontHighlight", 12)
    r.score:SetJustifyH("RIGHT")
    return r
end

local function CardTip(self)
    local m, bk = self.m, self.bk
    if not m or not bk then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local bo = H.BoOf(bk, m)
    local title = (bk.fmt == "robin") and ("Round " .. m.r) or H.MatchLabel(bk, m)
    if m.final then title = "The final" end
    GameTooltip:AddLine(title .. "  |cff9e9e9e· best of " .. bo .. "|r")
    for _, side in ipairs({ "a", "b" }) do
        local k = m[side]
        if type(k) == "string" then
            GameTooltip:AddDoubleLine(H.Name(k), (m.st == "play" or m.st == "done") and tostring(side == "a" and m.wa or m.wb) or "",
                1, 1, 1, 1, 1, 1)
        end
    end
    local occ = state.occ
    if m.st == "play" then
        GameTooltip:AddLine("Playing for " .. H.Clock(H.Now(occ) - (m.t or H.Now(occ))) .. ", game " .. ((m.g or 0) + 1),
            1, 0.55, 0.5)
    elseif m.st == "done" then
        local loser = H.Opp(m, m.win)
        local how = m.wo and " (walkover)" or ""
        if m.te and m.t then how = how .. " in " .. H.Clock(m.te - m.t) end
        GameTooltip:AddLine(H.Plain(m.win) .. " won" .. (loser and (" against " .. H.Plain(loser)) or "") .. how, 0.62, 0.62, 0.62, true)
    elseif m.st == "bye" then
        GameTooltip:AddLine("A bye: " .. H.Plain(m.win) .. " goes through.", 0.62, 0.62, 0.62)
    else
        GameTooltip:AddLine("Not started yet", 0.62, 0.62, 0.62)
    end
    if Board:IsHost() and (m.st == "play" or m.st == "wait") and m.a and m.b then
        GameTooltip:AddLine("Click: decide this match", 1, 0.82, 0)
    end
    GameTooltip:Show()
end

function NewCard(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:EnableMouse(true)
    c:SetSize(CARD_W, 39)
    c.glow2 = c:CreateTexture(nil, "BACKGROUND", nil, -3)
    c.glow2:SetPoint("TOPLEFT", -4, 4)
    c.glow2:SetPoint("BOTTOMRIGHT", 4, -4)
    c.glow2:SetColorTexture(1, 0.35, 0.27, 0.06)
    c.glow = c:CreateTexture(nil, "BACKGROUND", nil, -2)
    c.glow:SetPoint("TOPLEFT", -2, 2)
    c.glow:SetPoint("BOTTOMRIGHT", 2, -2)
    c.glow:SetColorTexture(1, 0.35, 0.27, 0.12)
    c.bg = c:CreateTexture(nil, "BACKGROUND", nil, 0)
    c.bg:SetAllPoints()
    c.bg:SetColorTexture(CARD_BG[1], CARD_BG[2], CARD_BG[3], CARD_BG[4])
    UI():AddEdges(c, "BORDER", true)
    c.div = c:CreateTexture(nil, "BORDER", nil, 1)
    c.div:SetHeight(1)
    c.div:SetColorTexture(1, 1, 1, 0.06)
    c.rows = { NewRow(c), NewRow(c) }
    c.dotGlow = H.Disc(c, "OVERLAY", 0, 16, 1, 0.35, 0.27, 0.3)
    c.dotGlow:SetPoint("CENTER", c, "TOPRIGHT", 0, 0)
    c.dotRing = H.Disc(c, "OVERLAY", 1, 11, BG[1], BG[2], BG[3], 1)
    c.dotRing:SetPoint("CENTER", c, "TOPRIGHT", 0, 0)
    c.dot = H.Disc(c, "OVERLAY", 2, 8, RED[1], RED[2], RED[3], 1)
    c.dot:SetPoint("CENTER", c, "TOPRIGHT", 0, 0)
    c:SetScript("OnEnter", CardTip)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    c:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        local m = self.m
        if not (m and Board:IsHost() and (m.st == "play" or m.st == "wait") and m.a and m.b) then return end
        UI():ContextMenu(self, function(rootDesc)
            rootDesc:CreateTitle(H.MatchLabel(self.bk, m))
            for _, k in ipairs({ m.a, m.b }) do
                rootDesc:CreateButton(H.Plain(k) .. " won", function() Board:Decide(m.id, k) end)
            end
        end)
    end)
    return c
end

-- Lays a card's rows out: rh = a row's height, seedW = 0 hides the seeds.
local function LayCard(c, cw, rh, seedW, circ, fsize)
    c:SetSize(cw, 2 * rh + 1)
    c.div:ClearAllPoints()
    c.div:SetPoint("TOPLEFT", 1, -rh)
    c.div:SetPoint("TOPRIGHT", -1, -rh)
    c.layout = { cw = cw, rh = rh, seedW = seedW, circ = circ, fsize = fsize }
    for i, r in ipairs(c.rows) do
        local y = -((i - 1) * (rh + 1) + rh / 2)
        r.seed:ClearAllPoints()
        r.seed:SetPoint("RIGHT", c, "TOPLEFT", 4 + seedW, y)
        r.seed:SetShown(seedW > 0)
        H.Sized(r.seed, max(8, fsize - 2))
        r.cls:ClearAllPoints()
        r.cls:SetSize(circ, circ)
        r.cls:SetPoint("LEFT", c, "TOPLEFT", 4 + seedW + (seedW > 0 and 5 or 0), y)
        r.name:ClearAllPoints()
        r.name:SetPoint("LEFT", r.cls, "RIGHT", 5, 0)
        r.tbdX = 4 + seedW + (seedW > 0 and 5 or 0)
        r.score:ClearAllPoints()
        r.score:SetPoint("RIGHT", c, "TOPRIGHT", -6, y)
        H.Sized(r.score, fsize + 1)
    end
end

-- One row: key (or nil with text = the empty slot's words), look = "w" | "l" | "n" | "tbd".
local function FillRow(c, r, bk, key, look, score, tbd)
    local lay = c.layout
    local me = Me()
    r.score:SetText(score or "")
    local scoreW = (score and score ~= "") and ((r.score:GetStringWidth() or 8) + 4) or 0
    if key then
        H.SetClass(r.cls, key, look == "l")
        local seed = H.SeedOf(bk, key)
        r.seed:SetText(seed and tostring(seed) or "")
        local nameW = lay.cw - (r.tbdX + lay.circ + 5) - 6 - scoreW - 2
        r.name:ClearAllPoints()
        r.name:SetPoint("LEFT", r.cls, "RIGHT", 5, 0)
        H.Fit(r.name, H.Plain(key), nameW, lay.fsize, max(8, lay.fsize - 3))
        r.name:SetWidth(nameW)
        local col = ns.Util.IsMe(key) and YOU_ROW or (look == "w" and { 1, 1, 1 } or GREY)
        r.name:SetTextColor(col[1], col[2], col[3])
        if look == "w" then r.score:SetTextColor(1, 1, 1) else r.score:SetTextColor(0.47, 0.47, 0.49) end
        r.name:Show()
        r.seed:SetShown(lay.seedW > 0)
    else
        r.cls:Hide()
        r.seed:SetText("")
        local w = lay.cw - r.tbdX - 6 - scoreW
        r.name:ClearAllPoints()
        r.name:SetPoint("LEFT", c, "TOPLEFT", r.tbdX, select(5, r.cls:GetPoint(1)) or 0)
        H.FitAny(r.name, tbd or { "" }, w, lay.fsize, max(8, lay.fsize - 3), true)
        r.name:SetWidth(w)
        r.name:SetTextColor(TBD[1], TBD[2], TBD[3])
        r.name:Show()
    end
    if key == me then r.name:SetTextColor(YOU_ROW[1], YOU_ROW[2], YOU_ROW[3]) end
end

-- Fills a card from a match. look: "live" | "next" | "plain".
local function FillCard(c, bk, m, look)
    c.m, c.bk = m, bk
    local shown = m.st == "play" or m.st == "done"
    for i, side in ipairs({ "a", "b" }) do
        local key = m[side]
        local r = c.rows[i]
        if type(key) == "string" then
            local rl = "n"
            if m.st == "done" then rl = (m.win == key) and "w" or "l"
            elseif m.st == "bye" then rl = "w" end
            local sc = shown and tostring(side == "a" and m.wa or m.wb) or nil
            if m.st == "done" and m.wo and m.win == key and (m.wa + m.wb) == 0 then sc = "w/o" end
            if m.st == "done" and m.wo and m.win ~= key and (m.wa + m.wb) == 0 then sc = nil end
            FillRow(c, r, bk, key, rl, sc)
        else
            FillRow(c, r, bk, nil, "tbd", nil, m.st == "bye" and { "bye" } or H.SlotText(bk, m, side))
        end
    end
    local e = look == "live" and LIVE_EDGE or (look == "next" and NEXT_EDGE or CARD_EDGE)
    UI():SetEdgeColor(c, e[1], e[2], e[3], e[4])
    local live = look == "live"
    c.glow:SetShown(live)
    c.glow2:SetShown(live)
    c.dot:SetShown(live)
    c.dotRing:SetShown(live)
    c.dotGlow:SetShown(live)
    c:Show()
end

local function Card(i)
    local br = win.br
    local c = br.cards[i]
    if not c then
        c = NewCard(br)
        br.cards[i] = c
    end
    return c
end

local function Line(i)
    local br = win.br
    local t = br.lines[i]
    if not t then
        t = br:CreateTexture(nil, "BORDER", nil, -1)
        br.lines[i] = t
    end
    return t
end

local function Head(i)
    local br = win.br
    local fs = br.heads[i]
    if not fs then
        fs = H.Text(br, "GameFontHighlightSmall", 10)
        br.heads[i] = fs
    end
    return fs
end

local function HideFrom(list, n)
    for i = n, #list do list[i]:Hide() end
end

-- When the champion should be known: "about 22:00" (the matches left at the pace so far).
local function Eta(bk, now)
    local sum, n, left = 0, 0, 0
    for _, m in pairs(bk.m) do
        if m.st == "done" and m.t and m.te and not m.wo and m.te > m.t then
            sum, n = sum + (m.te - m.t), n + 1
        elseif m.st ~= "done" and m.st ~= "bye" then
            left = left + 1
        end
    end
    if left == 0 then return nil end
    local avg = n > 0 and (sum / n) or 360
    local slots = max(1, tonumber(bk.atonce) or 2)
    -- the rounds after this one wait for it: at least one match a round
    local rounds = max(1, (bk.last or 1) - (bk.r or 1) + 1)
    local steps = max(rounds, ceil(left / slots))
    return now + steps * (avg + 60)
end

function Board:DrawTree(bk, st, height)
    local br = win.br
    local me = Me()
    local R = max(1, bk.last or 1)
    local main = {}
    local bronze
    for r = 1, R do
        main[r] = {}
        for _, mid in ipairs(bk.rounds[r] or {}) do
            local m = bk.m[mid]
            if m and m.bronze then bronze = m elseif m then main[r][#main[r] + 1] = m end
        end
    end
    local n1 = max(1, #main[1])
    local top = 20
    local hh = height - top - 6
    local slot = hh / n1
    -- a small bracket stays together in the middle (not spread over the whole height)
    local y0 = top
    if slot > 110 then
        y0 = top + (hh - 110 * n1) / 2
        slot = 110
    end
    local rh = ROW_H
    if slot < 2 * ROW_H + 9 then rh = max(11, floor((slot - 3) / 2)) end
    local chh = 2 * rh + 1
    -- small brackets get wider cards (long names keep their size), 32 players narrower ones
    local cw, pitch = (R <= 3) and 150 or CARD_W, 0
    if R > 1 then
        pitch = (BR_W - cw) / (R - 1)
        if pitch < cw + COL_GAP_MIN then
            cw = floor((BR_W - COL_GAP_MIN * (R - 1)) / R)
            pitch = (BR_W - cw) / (R - 1)
        end
        pitch = min(pitch, 196)
    end
    local seedW = (R >= 5) and 0 or 13
    local fsize = rh >= 17 and 11 or (rh >= 14 and 10 or 9)
    local circ = min(13, rh - 4)
    local function X(r) return floor((r - 1) * pitch + 0.5) end
    -- the centres of the cards, round by round
    local cy = { {} }
    for i = 1, #main[1] do cy[1][i] = y0 + (i - 0.5) * slot end
    for r = 2, R do
        cy[r] = {}
        for i = 1, #main[r] do
            local a, b = cy[r - 1][2 * i - 1], cy[r - 1][2 * i]
            cy[r][i] = (a and b) and (a + b) / 2 or (a or (top + hh / 2))
        end
    end
    local myNext = H.MyNext(bk, me)
    -- the round headers (the current one gold)
    local nh = 0
    for r = 1, R do
        nh = nh + 1
        local fs = Head(nh)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", br, "TOPLEFT", X(r) + 2, 0)
        H.Fit(fs, EUI():RoundName(bk, r), cw, 10, 8)
        local now = (r == bk.r) and not bk.done
        if now then fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) else fs:SetTextColor(GREY[1], GREY[2], GREY[3]) end
        fs:Show()
    end
    -- the cards
    local nc = 0
    local function place(m, x, y)
        nc = nc + 1
        local c = Card(nc)
        LayCard(c, cw, rh, seedW, circ, fsize)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", br, "TOPLEFT", x, -floor(y + 0.5))
        local look = (m.st == "play") and "live" or ((myNext and myNext.id == m.id) and "next" or "plain")
        FillCard(c, bk, m, look)
        return c
    end
    for r = 1, R do
        for i, m in ipairs(main[r]) do place(m, X(r), cy[r][i] - chh / 2) end
    end
    -- the lines between the rounds: bright where the match before is decided
    local nl = 0
    local function seg(x, y, w, h, on)
        nl = nl + 1
        local t = Line(nl)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", br, "TOPLEFT", floor(x + 0.5), -floor(y + 0.5))
        t:SetSize(max(1, floor(w + 0.5)), max(1, floor(h + 0.5)))
        t:SetColorTexture(1, 1, 1, on and 0.34 or 0.12)
        t:Show()
    end
    for r = 2, R do
        for i = 1, #main[r] do
            local x1, y1 = X(r), cy[r][i]
            local x0 = X(r - 1) + cw
            local xm = x0 + floor((x1 - x0) / 2)
            local anyOn = false
            for j = 2 * i - 1, 2 * i do
                local f, y0 = main[r - 1][j], cy[r - 1][j]
                if f and y0 then
                    local on = f.st == "done" or f.st == "bye"
                    anyOn = anyOn or on
                    seg(x0, y0, xm - x0, 1, on)
                    seg(xm, min(y0, y1), 1, math.abs(y1 - y0) + 1, on)
                end
            end
            seg(xm, y1, x1 - xm, 1, anyOn)
        end
    end
    HideFrom(br.lines, nl + 1)
    -- the final: the champion's slot over it, the 3rd place match under it
    local fm = main[R][1]
    local fy = cy[R][1] or (top + hh / 2)
    local champ = br.champ
    champ:ClearAllPoints()
    champ:SetPoint("TOP", br, "TOPLEFT", X(R) + cw / 2, -max(16, floor(fy - chh / 2 - 100 + 0.5)))
    local won = bk.done and bk.champ
    if won then
        EUI():Glyph(champ.cup, UI().ICON.trophy, 1, 0.82, 0, 1)
        champ.outer:SetVertexColor(1, 0.82, 0, 0.85)
        champ.halo:SetVertexColor(1, 0.82, 0, 0.12)
        champ.t:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        champ.t:SetText("CHAMPION")
        H.Fit(champ.n, H.Name(bk.champ), 150, 12, 10)
    else
        EUI():Glyph(champ.cup, UI().ICON.trophy, 0.75, 0.75, 0.75, 0.45)
        champ.outer:SetVertexColor(1, 0.82, 0, 0.4)
        champ.halo:SetVertexColor(1, 0.82, 0, 0.05)
        champ.t:SetTextColor(GREY[1], GREY[2], GREY[3])
        champ.t:SetText("CHAMPION")
        local eta = st.phase == "live" and Eta(bk, H.Now(state.occ))
        champ.n:SetText(eta and ("about " .. date("%H:%M", eta)) or "")
        H.Sized(champ.n, 11)
        champ.n:SetTextColor(0.37, 0.37, 0.4)
    end
    champ:Show()
    if bronze and fm then
        local by = fy + chh / 2 + 34
        if by + chh <= height then
            nh = nh + 1
            local fs = Head(nh)
            fs:ClearAllPoints()
            fs:SetPoint("BOTTOMLEFT", br, "TOPLEFT", X(R) + 2, -floor(by - 4 + 0.5))
            fs:SetText("3RD PLACE")
            H.Sized(fs, 10)
            local now = bronze.st == "play"
            if now then fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) else fs:SetTextColor(GREY[1], GREY[2], GREY[3]) end
            fs:Show()
            place(bronze, X(R), by)
        end
    end
    HideFrom(br.heads, nh + 1)
    HideFrom(br.cards, nc + 1)
end

-- A round robin: the standings, this round's matches (and the next round's when there is room).
local function RobinTable(bk)
    local rows = {}
    for i, k in ipairs(bk.seeds or {}) do rows[k] = { k = k, w = 0, d = 0, p = 0, s = i } end
    for _, m in pairs(bk.m) do
        if m.st == "done" and m.a and m.b then
            local w = m.win
            local l = (w == m.a) and m.b or m.a
            local gw, gl = (w == m.a) and m.wa or m.wb, (w == m.a) and m.wb or m.wa
            if rows[w] then rows[w].w, rows[w].d, rows[w].p = rows[w].w + 1, rows[w].d + gw - gl, rows[w].p + 1 end
            if rows[l] then rows[l].d, rows[l].p = rows[l].d + gl - gw, rows[l].p + 1 end
        end
    end
    local out = {}
    for _, r in pairs(rows) do out[#out + 1] = r end
    tsort(out, function(x, y)
        if x.w ~= y.w then return x.w > y.w end
        if x.d ~= y.d then return x.d > y.d end
        return x.s < y.s
    end)
    return out
end
Board.RobinTable = function(_, bk) return RobinTable(bk) end

local function RobinRow(i)
    local br = win.br
    local r = br.rows[i]
    if not r then
        r = CreateFrame("Frame", nil, br)
        r:SetSize(272, 22)
        r.band = r:CreateTexture(nil, "BACKGROUND")
        r.band:SetAllPoints()
        r.rank = H.Text(r, "GameFontHighlightSmall", 10, GREY[1], GREY[2], GREY[3])
        r.rank:SetJustifyH("RIGHT")
        r.rank:SetPoint("RIGHT", r, "LEFT", 18, 0)
        r.cls = r:CreateTexture(nil, "ARTWORK")
        r.cls:SetSize(14, 14)
        r.cls:SetPoint("LEFT", 26, 0)
        r.name = H.Text(r, "GameFontHighlight", 11)
        r.name:SetPoint("LEFT", r.cls, "RIGHT", 6, 0)
        r.w = H.Text(r, "GameFontHighlight", 11)
        r.w:SetJustifyH("RIGHT")
        r.w:SetPoint("RIGHT", r, "RIGHT", -64, 0)
        r.d = H.Text(r, "GameFontHighlight", 11)
        r.d:SetJustifyH("RIGHT")
        r.d:SetPoint("RIGHT", r, "RIGHT", -8, 0)
        br.rows[i] = r
    end
    return r
end

function Board:DrawRobin(bk, st, height)
    local br = win.br
    local me = Me()
    local rows = RobinTable(bk)
    local nh = 0
    local function head(text, x, y, gold, w, right)
        nh = nh + 1
        local fs = Head(nh)
        fs:ClearAllPoints()
        if right then
            fs:SetPoint("TOPRIGHT", br, "TOPLEFT", x, -y)
            fs:SetJustifyH("RIGHT")
        else
            fs:SetPoint("TOPLEFT", br, "TOPLEFT", x, -y)
            fs:SetJustifyH("LEFT")
        end
        H.Fit(fs, text, w or 200, 10, 8)
        local c = gold and GOLD or GREY
        fs:SetTextColor(c[1], c[2], c[3])
        fs:Show()
    end
    head("STANDINGS", 2, 0)
    head("WON", 272 - 64, 0, false, 40, true)
    head("GAMES", 272 - 8, 0, false, 50, true)
    local rowH = min(22, floor((height - 22) / max(1, #rows)))
    for i, row in ipairs(rows) do
        local r = RobinRow(i)
        r:SetHeight(rowH)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", br, "TOPLEFT", 0, -(20 + (i - 1) * rowH))
        r.band:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.025 or 0)
        r.rank:SetText(tostring(i))
        if i == 1 and row.w > 0 then r.rank:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) else r.rank:SetTextColor(GREY[1], GREY[2], GREY[3]) end
        H.SetClass(r.cls, row.k)
        H.Fit(r.name, H.Name(row.k), 272 - 46 - 100, 11, 9)
        r.name:SetWidth(272 - 46 - 100)
        r.w:SetText(tostring(row.w))
        r.d:SetText((row.d > 0 and "+" or "") .. row.d)
        if row.d > 0 then r.d:SetTextColor(0.62, 0.94, 0.69) elseif row.d < 0 then r.d:SetTextColor(GREY[1], GREY[2], GREY[3])
        else r.d:SetTextColor(0.8, 0.8, 0.8) end
        r:SetShown(20 + i * rowH <= height)
    end
    HideFrom(br.rows, #rows + 1)
    -- this round's matches (the next round's when there is room)
    local x, w = 296, BR_W - 296
    local y = 0
    local nc = 0
    local myNext = H.MyNext(bk, me)
    for r = max(1, bk.r or 1), bk.last or 1 do
        local list = bk.rounds[r] or {}
        if #list == 0 then break end
        local need = 20 + #list * (39 + 8)
        if r > (bk.r or 1) and y + need > height then break end
        local roundText = "ROUND " .. r .. " OF " .. (bk.last or r)
        head(roundText, x + 2, y, r == bk.r and not bk.done, w)
        y = y + 20
        for _, mid in ipairs(list) do
            local m = bk.m[mid]
            if y + 39 > height then break end
            nc = nc + 1
            local c = Card(nc)
            LayCard(c, w, ROW_H, 0, 13, 11)
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", br, "TOPLEFT", x, -y)
            FillCard(c, bk, m, m.st == "play" and "live" or ((myNext and myNext.id == m.id) and "next" or "plain"))
            y = y + 39 + 8
        end
        y = y + 8
        if bk.done then break end
    end
    HideFrom(br.cards, nc + 1)
    HideFrom(br.heads, nh + 1)
    HideFrom(br.lines, 1)
    br.champ:Hide()
end

-- Before the bracket (or an event without one): who signed up, in a grid. note: a line under it (else the
-- sign-up's while it is open).
function Board:DrawPlayers(st, def, height, note)
    local br = win.br
    local list = {}
    for _, b in pairs(st.blocks or {}) do
        if type(b) == "table" and b.kind == "signup" and type(b.list) == "table" then
            for _, k in ipairs(b.list) do if not H.Contains(list, k) then list[#list + 1] = k end end
        end
    end
    if #list == 0 then for _, k in ipairs(st.entrants or {}) do list[#list + 1] = k end end
    local open = false
    for _, b in pairs(st.blocks or {}) do if type(b) == "table" and b.kind == "signup" and b.open then open = true end end
    local nh = 1
    local fs = Head(1)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", br, "TOPLEFT", 2, 0)
    fs:SetText((open and "SIGNED UP" or "PLAYERS") .. "  |cff9e9e9e" .. #list .. "|r")
    H.Sized(fs, 10)
    fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    fs:Show()
    local cols, colW, rowH = 4, 140, 22
    local n = 0
    for i, k in ipairs(list) do
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        if 20 + (row + 1) * rowH > height - 30 then break end
        n = n + 1
        local r = RobinRow(n)
        r:SetSize(colW - 6, rowH)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", br, "TOPLEFT", col * colW - 20, -(20 + row * rowH))
        r.band:SetColorTexture(0, 0, 0, 0)
        r.rank:SetText("")
        H.SetClass(r.cls, k)
        H.Fit(r.name, H.Name(k), colW - 50, 11, 9)
        r.name:SetWidth(colW - 50)
        r.w:SetText("")
        r.d:SetText("")
        r:Show()
    end
    HideFrom(br.rows, n + 1)
    HideFrom(br.heads, nh + 1)
    HideFrom(br.cards, 1)
    HideFrom(br.lines, 1)
    br.champ:Hide()
    note = note or (open and "The bracket is drawn when sign-up closes.") or nil
    br.note:SetText(note or "")
    br.note:ClearAllPoints()
    br.note:SetPoint("BOTTOM", br, "BOTTOM", 0, 8)
    br.note:SetShown(note ~= nil)
end

---------------------------------------------------------------------------
-- The rail: now, up next, moments
---------------------------------------------------------------------------

local function RailHead(i)
    local rail = win.rail
    local h = rail.heads[i]
    if not h then
        h = CreateFrame("Frame", nil, rail)
        h:SetSize(RAIL_W, 16)
        h.pill = H.NewPill(h, 16)
        h.pill:SetPoint("LEFT")
        h.fs = H.Text(h, "GameFontHighlightSmall", 10, GREY[1], GREY[2], GREY[3])
        rail.heads[i] = h
    end
    return h
end

local function NowCard(i)
    local rail = win.rail
    local c = rail.nows[i]
    if not c then
        c = CreateFrame("Frame", nil, rail)
        c:EnableMouse(true)
        c:SetSize(RAIL_W, 81)
        H.Panel(c, CARD_BG, { 1, 0.38, 0.29, 0.7 })
        c.rows = {}
        for k = 1, 2 do
            local r = {}
            r.cls = c:CreateTexture(nil, "ARTWORK")
            r.cls:SetSize(18, 18)
            r.cls:SetPoint("LEFT", c, "TOPLEFT", 10, -(9 + 11 + (k - 1) * 22))
            r.name = H.Text(c, "GameFontHighlight", 12)
            r.name:SetPoint("LEFT", r.cls, "RIGHT", 7, 0)
            r.pips = H.NewPips(c, 8, 3)
            r.pips:SetPoint("RIGHT", c, "TOPRIGHT", -10, -(9 + 11 + (k - 1) * 22))
            c.rows[k] = r
        end
        c.where = H.Text(c, "GameFontHighlightSmall", 10.5, GREY[1], GREY[2], GREY[3])
        c.where:SetPoint("BOTTOMLEFT", 10, 9)
        c.clock = H.Text(c, "GameFontHighlightSmall", 10.5, 1, 0.71, 0.66)
        c.clock:SetJustifyH("RIGHT")
        c.clock:SetPoint("BOTTOMRIGHT", -10, 9)
        c:SetScript("OnEnter", CardTip)
        c:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rail.nows[i] = c
    end
    return c
end

local function MomentRow(i)
    local rail = win.rail
    local r = rail.moms[i]
    if not r then
        r = CreateFrame("Frame", nil, rail)
        r:SetSize(RAIL_W, 30)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16)
        r.icon:SetPoint("TOPLEFT", 0, -1)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.fs = H.Text(r, "GameFontHighlightSmall", 11, 0.82, 0.82, 0.82)
        r.fs:SetWordWrap(true)
        r.fs:SetSpacing(2)
        r.fs:SetWidth(RAIL_W - 24)
        r.fs:SetPoint("TOPLEFT", 24, 0)
        r.t = H.Text(r, "GameFontHighlightSmall", 10, 0.44, 0.44, 0.46)
        r.t:SetPoint("TOPLEFT", r.fs, "BOTTOMLEFT", 0, -2)
        rail.moms[i] = r
    end
    return r
end

local function NextCard()
    local rail = win.rail
    local c = rail.next
    if not c then
        c = CreateFrame("Frame", nil, rail)
        c:SetSize(RAIL_W, 56)
        c.bg = c:CreateTexture(nil, "BACKGROUND")
        c.bg:SetAllPoints()
        UI():AddEdges(c, "BORDER", true)
        c.c1 = c:CreateTexture(nil, "ARTWORK")
        c.c1:SetSize(18, 18)
        c.c1:SetPoint("LEFT", c, "TOPLEFT", 10, -19)
        c.n1 = H.Text(c, "GameFontHighlight", 12)
        c.n1:SetPoint("LEFT", c.c1, "RIGHT", 7, 0)
        c.vs = H.Text(c, "GameFontHighlightSmall", 11, GREY[1], GREY[2], GREY[3])
        c.vs:SetText("vs")
        c.vs:SetPoint("LEFT", c.n1, "RIGHT", 7, 0)
        c.c2 = c:CreateTexture(nil, "ARTWORK")
        c.c2:SetSize(18, 18)
        c.c2:SetPoint("LEFT", c.vs, "RIGHT", 7, 0)
        c.n2 = H.Text(c, "GameFontHighlight", 12)
        c.n2:SetPoint("LEFT", c.c2, "RIGHT", 7, 0)
        c.sub = H.Text(c, "GameFontHighlightSmall", 10.5, GREY[1], GREY[2], GREY[3])
        c.sub:SetPoint("TOPLEFT", 10, -35)
        rail.next = c
    end
    return c
end

-- A podium row (the bracket's result): place, class, name.
local function PodiumRow(i)
    local rail = win.rail
    rail.pods = rail.pods or {}
    local r = rail.pods[i]
    if not r then
        r = CreateFrame("Frame", nil, rail)
        r:SetSize(RAIL_W, 24)
        r.place = H.Text(r, "GameFontNormal", 12)
        r.place:SetJustifyH("CENTER")
        r.place:SetPoint("CENTER", r, "LEFT", 8, 0)
        r.cls = r:CreateTexture(nil, "ARTWORK")
        r.cls:SetSize(18, 18)
        r.cls:SetPoint("LEFT", 22, 0)
        r.name = H.Text(r, "GameFontHighlight", 12)
        r.name:SetPoint("LEFT", r.cls, "RIGHT", 7, 0)
        rail.pods[i] = r
    end
    return r
end

local PLACE_COLOR = { { 1, 0.82, 0 }, { 0.86, 0.89, 0.95 }, { 0.86, 0.56, 0.32 } }

local function ElapsedOf(st, m, occ)
    local now = H.Now(occ)
    if type(st.paused) == "number" and occ ~= "practice" then now = min(now, st.paused) end
    return now - (m.t or now)
end

function Board:DrawRail(occ, st, def, bk, height)
    local rail = win.rail
    local me = Me()
    local y = 0
    local nhead, nnow = 0, 0
    local function head(text, pill, kind)
        nhead = nhead + 1
        local h = RailHead(nhead)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -y)
        h.fs:ClearAllPoints()
        if pill then
            h.pill:SetKind(pill, kind)
            h.pill:Show()
            h.fs:SetPoint("LEFT", h.pill, "RIGHT", 6, 0)
        else
            h.pill:Hide()
            h.fs:SetPoint("LEFT", 0, 0)
        end
        h.fs:SetText(text or "")
        h:Show()
        y = y + 16 + 5
    end
    local live = st.phase == "live"
    ------------------------------------------------ now
    local playing = (bk and live) and H.Playing(bk) or {}
    if #playing > 0 then
        local first = playing[1]
        head(#playing == 1 and ("game " .. ((first.g or 0) + 1)) or (#playing .. " matches"), "Now", st.paused and "paused" or "live")
        local place = H.Place(occ)
        for k = 1, min(2, #playing) do
            local m = playing[k]
            nnow = nnow + 1
            local c = NowCard(nnow)
            c.m, c.bk, c.st = m, bk, st
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -y)
            local need = H.Need(H.BoOf(bk, m))
            for i, side in ipairs({ "a", "b" }) do
                local r = c.rows[i]
                local key = m[side]
                H.SetClass(r.cls, key)
                H.Fit(r.name, H.Name(key), RAIL_W - 35 - 10 - (need * 11) - 6, 12, 10)
                r.pips:Set(need, side == "a" and m.wa or m.wb)
            end
            local gameText = (#playing > 1) and ("Game " .. ((m.g or 0) + 1)) or nil
            local list = {}
            if gameText and place then list[#list + 1] = gameText .. " · " .. place end
            if place then list[#list + 1] = place end
            if gameText then list[#list + 1] = gameText end
            list[#list + 1] = H.MatchLabel(bk, m)
            H.FitAny(c.where, list, RAIL_W - 20 - 40, 10.5, 9)
            c.clock:SetText(H.Clock(ElapsedOf(st, m, occ)))
            c:Show()
            y = y + 81 + 6
        end
        y = y + 4
    end
    for i = nnow + 1, #rail.nows do rail.nows[i]:Hide() end
    ------------------------------------------------ the result (the bracket is done)
    local npod = 0
    if bk and bk.done and bk.champ then
        head("RESULT")
        for i, k in ipairs({ bk.champ, bk.second, bk.third }) do
            if type(k) == "string" then
                npod = npod + 1
                local r = PodiumRow(npod)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -y)
                r.place:SetText(tostring(i))
                local c = PLACE_COLOR[i]
                r.place:SetTextColor(c[1], c[2], c[3])
                H.SetClass(r.cls, k)
                H.Fit(r.name, H.Name(k), RAIL_W - 47, 12, 10)
                r:Show()
                y = y + 24
            end
        end
        y = y + 10
    end
    for i = npod + 1, #(rail.pods or {}) do rail.pods[i]:Hide() end
    ------------------------------------------------ up next
    local nextM, mine = nil, false
    if bk and live then
        local m = H.MyNext(bk, me)
        if m and m.st == "wait" then nextM, mine = m, true end
        if not nextM then nextM = H.NextUp(bk) end
    end
    local nc = rail.next
    if nextM then
        head("UP NEXT")
        local c = NextCard()
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -y)
        if mine then
            c.bg:SetColorTexture(0.4, 0.72, 1, 0.06)
            UI():SetEdgeColor(c, 0.4, 0.72, 1, 0.45)
        else
            c.bg:SetColorTexture(CARD_BG[1], CARD_BG[2], CARD_BG[3], CARD_BG[4])
            UI():SetEdgeColor(c, CARD_EDGE[1], CARD_EDGE[2], CARD_EDGE[3], CARD_EDGE[4])
        end
        local a, b = nextM.a, nextM.b
        if mine and b == me then a, b = b, a end
        -- one row ("You vs Hollowmane") while both names fit; else a row each
        local function side(tex, fs, key, slot, w, size)
            fs:ClearAllPoints()
            if type(key) == "string" then
                H.SetClass(tex, key)
                tex:Show()
                fs:SetPoint("LEFT", tex, "RIGHT", 7, 0)
                return H.Fit(fs, H.Name(key), w, size, size)
            end
            tex:Hide()
            fs:SetPoint("LEFT", tex, "LEFT", 0, 0)
            local ok = H.FitAny(fs, H.SlotText(bk, nextM, slot), w + 25, size - 1, size - 1, true)
            fs:SetTextColor(TBD[1] + 0.15, TBD[2] + 0.15, TBD[3] + 0.15)
            return ok
        end
        local sa, sb = (a == nextM.a) and "a" or "b", (b == nextM.b) and "b" or "a"
        local inner = RAIL_W - 20
        local oneRow = false
        for _, size in ipairs({ 12, 11 }) do
            side(c.c1, c.n1, a, sa, inner, size)
            local w1 = (c.c1:IsShown() and 25 or 0) + H.Width(c.n1)
            side(c.c2, c.n2, b, sb, inner, size)
            local w2 = (c.c2:IsShown() and 25 or 0) + H.Width(c.n2)
            if w1 + 7 + H.Width(c.vs) + 7 + w2 <= inner then
                oneRow = true
                break
            end
        end
        c.c2:ClearAllPoints()
        if oneRow then
            c.c2:SetPoint("LEFT", c.vs, "RIGHT", 7, 0)
        else
            side(c.c1, c.n1, a, sa, inner - 25 - 30, 12)
            c.c2:SetPoint("LEFT", c, "TOPLEFT", 10, -41)
            side(c.c2, c.n2, b, sb, inner - 25, 12)
        end
        if not c.c2:IsShown() then
            c.n2:ClearAllPoints()
            c.n2:SetPoint("LEFT", c.c2, "LEFT", 0, 0)
        end
        local subY = oneRow and 35 or 57
        c.sub:ClearAllPoints()
        c.sub:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -subY)
        c:SetHeight(subY + 21)
        -- what it waits for
        local bo = H.BoOf(bk, nextM)
        local list = {}
        if nextM.r == bk.r then
            local p = H.Playing(bk)[1]
            if p and p.id ~= nextM.id then
                list[#list + 1] = "after " .. H.Plain(p.a) .. " vs " .. H.Plain(p.b) .. " · best of " .. bo
            end
            list[#list + 1] = "next up · best of " .. bo
        else
            list[#list + 1] = H.RoundTitle(bk, nextM.r, nextM) .. " · best of " .. bo
        end
        H.FitAny(c.sub, list, RAIL_W - 20, 10.5, 9)
        c:Show()
        y = y + c:GetHeight() + 10
    elseif nc then
        nc:Hide()
    end
    ------------------------------------------------ moments
    local moms = {}
    for _, m in ipairs(st.moments or {}) do if type(m) == "table" and m.text then moms[#moms + 1] = m end end
    tsort(moms, function(p, q) return (p.at or 0) > (q.at or 0) end)
    local nm = 0
    if #moms > 0 or (live and y < height - 60) then
        head("MOMENTS")
        local keys = st.entrants or {}
        for _, m in ipairs(moms) do
            local r = MomentRow(nm + 1)
            r.icon:SetTexture(m.i or (def and def.icon) or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.fs:SetTextColor(0.82, 0.82, 0.82)
            r.fs:SetText(H.ColorNames(m.text, keys))
            r.t:SetText(m.at and date("%H:%M", m.at) or "")
            local hgt = (r.fs:GetStringHeight() or 15) + 2 + 12
            if y + hgt > height then break end
            nm = nm + 1
            r:SetHeight(hgt)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -y)
            r:Show()
            y = y + hgt + 8
        end
        if #moms == 0 then
            local r = MomentRow(1)
            nm = 1
            r.icon:SetTexture(def and def.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.fs:SetText("Upsets, fast duels and comebacks show up here as they happen.")
            r.fs:SetTextColor(0.55, 0.55, 0.57)
            r.t:SetText("")
            r:SetHeight((r.fs:GetStringHeight() or 30) + 4)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -y)
            r:Show()
        end
    end
    for i = nm + 1, #rail.moms do rail.moms[i]:Hide() end
    for i = nhead + 1, #rail.heads do rail.heads[i]:Hide() end
end

-- The clocks of the matches being played (once a second).
function Board:TickClocks()
    if not (win and win:IsShown()) then return end
    local occ, st = Data()
    if not st then return end
    for _, c in ipairs(win.rail.nows) do
        if c:IsShown() and c.m and c.m.st == "play" then c.clock:SetText(H.Clock(ElapsedOf(st, c.m, occ))) end
    end
end

---------------------------------------------------------------------------
-- The host: the bar, the dispute card, the More menu
---------------------------------------------------------------------------

local function RefreshHostBar(occ, st, bk, disputes)
    local hb = win.hostbar
    local playing = bk and #H.Playing(bk) or 0
    local parts = {}
    if st.paused then parts[#parts + 1] = "|cffffb066paused|r" end
    if bk then
        parts[#parts + 1] = playing == 1 and "1 match playing" or (playing .. " matches playing")
    else
        parts[#parts + 1] = #H.SignedUp(st) .. " signed up"
    end
    if #disputes > 0 then parts[#parts + 1] = "|cffffcf99" .. #disputes .. (#disputes == 1 and " dispute" or " disputes") .. "|r" end
    hb.sub:SetText(tconcat(parts, " · "))
    local paused = st.paused and true or false
    local b = hb.pause
    b:SetText(paused and "Resume" or "Pause")
    EUI():Glyph(b.icon, paused and UI().ICON.play or UI().ICON.pause, 1, 1, 1, 0.85)
    b:SetWidth(floor(10 + 12 + 6 + (b:GetFontString():GetStringWidth() or 40) + 12 + 0.5))
    hb:Show()
end

function Board:TogglePause()
    local occ = state.occ
    if not self:IsHost() then return end
    L():SetPaused(occ, not L():IsPaused(occ))
    self:Refresh()
end

function Board:Decide(mid, winner)
    if not self:IsHost() then return false end
    local ok = L():DecideMatch(state.occ, mid, winner)
    if not ok then ns:Print("That match can't be decided any more: it's over or not on the board.") end
    self:Refresh()
    return ok
end

-- The dispute card's answers (winner = a player key, replay = true: nobody, the game is played again).
function Board:AnswerDispute(winner, replay)
    local d = win and win.dispute
    local a = d and d.ask
    if not a then return false end
    local occ = state.occ
    local v = (not replay) and winner or nil
    if occ == "practice" then
        local run = L():GetPractice()
        if run then run:Answer(a.id, run.st.host, v) end
    else
        L():HostAnswer(occ, a.id, v)
    end
    d:Hide()
    self:Refresh()
    return true
end

local function Says(a, key)
    local v = a.claims and a.claims[key]
    if v == nil or v == false then return "didn't answer" end
    if v == key then return "claims the win" end
    return "says " .. H.Plain(v) .. " won"
end

local function RefreshDispute(occ, st, bk, disputes)
    local d = win.dispute
    local a = disputes[1]
    if not a then
        d.ask = nil
        d:Hide()
        return
    end
    d.ask = a
    -- (the ask's own bracket: an event can have more than one)
    local abk = (a.b and st.blocks and type(st.blocks[a.b]) == "table" and st.blocks[a.b].m) and st.blocks[a.b] or bk
    local m = abk and a.match and abk.m[a.match]
    local g = a.g or (m and (m.g or 0) + 1) or 1
    d.h1:SetText("Game " .. g .. " is disputed")
    local p
    if a.claims and next(a.claims) then
        p = "Their games saw different winners and they didn't agree when asked. The match waits for you."
    else
        p = "Their games saw different winners and they didn't answer when asked. The match waits for you."
    end
    d.p:SetText(p)
    local ph = d.p:GetStringHeight() or 30
    local y = 32 + ph + 10
    local opts = a.opts or {}
    for i = 1, 2 do
        local r = d.cl[i]
        local k = opts[i]
        r.cls:ClearAllPoints()
        r.cls:SetPoint("LEFT", d, "TOPLEFT", 12, -(y + 11 + (i - 1) * 22))
        r.says:ClearAllPoints()
        r.says:SetPoint("RIGHT", d, "TOPRIGHT", -12, -(y + 11 + (i - 1) * 22))
        if k then
            H.SetClass(r.cls, k)
            r.says:SetText(Says(a, k))
            H.Fit(r.name, H.Name(k), DISP_W - 24 - 23 - (r.says:GetStringWidth() or 60) - 8, 11.5, 9.5)
            r.cls:Show()
            r.name:Show()
            r.says:Show()
        else
            r.cls:Hide()
            r.name:Hide()
            r.says:Hide()
        end
    end
    y = y + 44 + 10
    -- "<A> won", "<B> won", "Replay" (both names the same way: "X won", or the names alone when one won't fit)
    local nameW = floor((DISP_W - 24 - 12 - 60) / 2)
    local bw = { nameW, nameW, DISP_W - 24 - 12 - 2 * nameW }
    local fs1 = d.btns[1]:GetFontString()
    local withWon = true
    for i = 1, 2 do
        if opts[i] then
            H.Sized(fs1, 11)
            fs1:SetText(H.Plain(opts[i]) .. " won")
            if H.Width(fs1) > nameW - 14 then withWon = false end
        end
    end
    local x = 12
    for i = 1, 3 do
        local b = d.btns[i]
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", d, "TOPLEFT", x, -y)
        b:SetWidth(bw[i])
        local fs = b:GetFontString()
        if i < 3 then
            local k = opts[i]
            b.answer, b.replay = k, nil
            H.Fit(fs, H.Plain(k) .. (withWon and " won" or ""), bw[i] - 14, 11, 9)
            b:SetShown(k ~= nil)
        else
            b.answer, b.replay = nil, true
            b:SetText("Replay")
            H.Sized(fs, 11)
            b:Show()
        end
        x = x + bw[i] + 6
    end
    local hgt = y + 22 + 12
    d:SetHeight(hgt)
    -- beside the disputed match, where it covers the fewest other cards (inside the bracket's side of the board)
    d:ClearAllPoints()
    local br = win.br
    local card
    local rects = {}
    for _, c in ipairs(br.cards) do
        if c:IsShown() then
            local _, _, _, cx, cy = c:GetPoint(1)
            if c.m and m and c.m == m then card = { cx or 0, -(cy or 0), c:GetWidth(), c:GetHeight() }
            else rects[#rects + 1] = { cx or 0, -(cy or 0), c:GetWidth(), c:GetHeight() } end
        end
    end
    if br.champ:IsShown() then
        local _, _, _, chx, chy = br.champ:GetPoint(1)
        rects[#rects + 1] = { (chx or 0) - 56, -(chy or 0), 112, 96 }
    end
    local bh = br:GetHeight()
    if bh <= 0 then bh = CH - BR_Y - BOTTOM end
    local maxL = BR_W - DISP_W + 40
    local function cost(l, t)
        local sum = 0
        for _, r in ipairs(rects) do
            local w = min(l + DISP_W, r[1] + r[3]) - max(l, r[1])
            local h = min(t + hgt, r[2] + r[4]) - max(t, r[2])
            if w > 0 and h > 0 then sum = sum + w * h end
        end
        return sum
    end
    if card then
        local pl, pt = card[1] + card[3] - 30, card[2] + card[4] / 2 - hgt / 2
        local best, bl, bt
        for _, l in ipairs({ pl, card[1] + card[3] + 10, card[1] + 20, pl - 60 }) do
            l = min(maxL, max(0, l))
            for k = -12, 12 do
                local t = min(bh - hgt, max(0, pt + k * 8))
                local c = cost(l, t) + (math.abs(l - pl) + math.abs(t - pt)) * 4
                if not best or c < best then best, bl, bt = c, l, t end
            end
        end
        d:SetPoint("TOPLEFT", br, "TOPLEFT", floor(bl + 0.5), -floor(bt + 0.5))
    else
        d:SetPoint("CENTER", br, "CENTER", 0, 0)
    end
    d:Show()
end

-- hostOnly: a host's action (the sheet goes when I stop hosting: the action would do nothing then).
local function Confirm(title, text, yes, fn, hostOnly)
    local dim = win.confirm
    local sh = dim.sheet
    dim.hostOnly = hostOnly and true or nil
    sh.t:SetText(title)
    sh.p:SetText(text)
    sh.yes:SetText(yes)
    sh.yes:SetWidth(floor((sh.yes:GetFontString():GetStringWidth() or 50) + 28))
    sh.no:SetWidth(floor((sh.no:GetFontString():GetStringWidth() or 60) + 28))
    sh:SetHeight(floor(14 + 16 + 8 + (sh.p:GetStringHeight() or 30) + 16 + 24 + 12 + 0.5))
    dim.fn = fn
    dim:Show()
    dim:Raise()
end
Board.Confirm = function(_, ...) return Confirm(...) end

local function OnlineMembers(exclude)
    local G = ns.Guild
    local out = {}
    for _, k in ipairs(G and G.GetOnlineMembers and G:GetOnlineMembers() or {}) do
        if not (exclude and exclude[k]) and not ns.Util.IsMe(k) then out[#out + 1] = k end
    end
    return out
end

function Board:HostMenu(rootDesc)
    local occ, st, def, bk = Data()
    if not (st and self:IsHost()) then
        rootDesc:CreateTitle("You don't host this event")
        return
    end
    -- Change a result: a match of this round, then its winner
    local cr = rootDesc:CreateButton(Glyph(16) .. "Change a result")
    cr:SetTitleAndTextTooltip("Change a result", "Decide a match that is being played or waiting: its winner goes on.")
    local any = false
    for _, mid in ipairs(bk and bk.rounds[bk.r or 0] or {}) do
        local m = bk.m[mid]
        if m and m.a and m.b and (m.st == "play" or m.st == "wait") then
            any = true
            local e = cr:CreateButton(H.Plain(m.a) .. " vs " .. H.Plain(m.b))
            for _, k in ipairs({ m.a, m.b }) do
                e:CreateButton(H.Plain(k) .. " won", function() Board:Decide(m.id, k) end)
            end
        end
    end
    if not any then
        cr:CreateTitle("No match to decide right now")
    end
    -- Add a player: online members who aren't in it. They join the sign-up (the engine takes nobody once it has
    -- closed): after that the entry says so when clicked.
    local ex = {}
    for _, k in ipairs(st.entrants or {}) do ex[k] = true end
    local su, suId
    for bid, b in pairs(st.blocks or {}) do
        if type(b) == "table" and b.kind == "signup" and b.open then su, suId = b, bid end
    end
    if not su then
        local add = rootDesc:CreateButton(Glyph(19) .. "Add a player", function()
            ns:Print("%s", "nobody can join now: the sign-up has closed.")
        end)
        add:SetTitleAndTextTooltip("Add a player", "Only while the sign-up is open, and it has closed.")
    else
        local add = rootDesc:CreateButton(Glyph(19) .. "Add a player")
        add:SetTitleAndTextTooltip("Add a player", "An online member joins the sign-up, as if they had signed up.")
        local online = OnlineMembers(ex)
        if #online == 0 then
            add:CreateTitle("Nobody else is online")
        else
            add:CreateTitle("Online members")
            for _, k in ipairs(online) do
                add:CreateButton(H.Name(k), function()
                    local ok, why = L():AddPlayer(occ, k)
                    if not ok then
                        local spots = def and def.blocks and def.blocks[suId] and B():SmartSetting(def.blocks[suId], "spots")
                        -- (the core's reason is a whole sentence: "Sign-ups are closed: the bracket is set.")
                        if not why and spots and #(su.list or {}) >= spots then why = "The sign-up is full." end
                        if not why and H.Contains(su.list, k) then why = "They're in it already." end
                        ns:Print("%s can't join. %s", H.Plain(k), why or "Try again in a moment.")
                    end
                    Board:Refresh()
                end)
            end
            if #online > 14 then add:SetScrollMode(14 * 20) end
        end
    end
    -- Remove a player
    local rem = rootDesc:CreateButton(Glyph(UI().ICON.trash) .. "Remove a player")
    rem:SetTitleAndTextTooltip("Remove a player", "Takes a player out: their match now is lost, later ones are walkovers.")
    local out = bk and bk.out or {}
    local n = 0
    for _, k in ipairs(st.entrants or {}) do
        if not out[k] then
            n = n + 1
            rem:CreateButton(H.Name(k), function()
                Confirm("Remove " .. H.Plain(k) .. "?", H.Plain(k) .. " loses the match they're in and is out of the event.",
                    "Remove", function()
                        L():RemovePlayer(occ, k)
                        Board:Refresh()
                    end, true)
            end)
        end
    end
    if n == 0 then rem:CreateTitle("Nobody to remove") end
    if n > 14 then rem:SetScrollMode(14 * 20) end
    -- Go to a stage
    local go = rootDesc:CreateButton(Glyph(UI().ICON.skip) .. "Go to a stage")
    go:SetTitleAndTextTooltip("Go to a stage", "Jumps the event to a stage (its smart blocks and scripts start there).")
    for _, s in ipairs(def and def.stages or {}) do
        go:CreateRadio(s.name, function() return st.stage == s.id end, function()
            L():GoStage(occ, s.id)
            Board:Refresh()
        end, s.id)
    end
    -- Close sign-up (while one is open)
    for _, b in pairs(st.blocks or {}) do
        if type(b) == "table" and b.kind == "signup" and b.open then
            local cs = rootDesc:CreateButton(Glyph(UI().ICON.lock) .. "Close sign-up", function()
                L():CloseSignup(occ)
                Board:Refresh()
            end)
            cs:SetTitleAndTextTooltip("Close sign-up", "Nobody else joins; the event goes on with who signed up.")
            break
        end
    end
    -- Hand over hosting
    local ho = rootDesc:CreateButton(Glyph(UI().ICON.crown) .. "Hand over hosting")
    ho:SetTitleAndTextTooltip("Hand over hosting", "Another online member runs the event from here; you watch.")
    local cands = OnlineMembers()
    -- (the players first: they're there)
    tsort(cands, function(x, y)
        local xe, ye = ex[x] and true or false, ex[y] and true or false
        if xe ~= ye then return xe end
        return x < y
    end)
    if #cands == 0 then
        ho:CreateTitle("Nobody else is online")
    else
        for _, k in ipairs(cands) do
            ho:CreateButton(H.Name(k), function()
                Confirm("Hand the event to " .. H.Plain(k) .. "?", H.Plain(k) .. " runs it from now on (the bracket, the "
                    .. "timers, the disputes). You keep watching.", "Hand over", function()
                        local ok, why = L():HandOver(occ, k)
                        if not ok then ns:Print("%s", why or "the event couldn't be handed over.") end
                        Board:Refresh()
                    end, true)
            end)
        end
        if #cands > 14 then ho:SetScrollMode(14 * 20) end
    end
    rootDesc:CreateDivider()
    local red = { 1, 0.55, 0.5 }
    local fin = rootDesc:CreateButton(Glyph(UI().ICON.flag, red) .. "|cffff8d80End the event|r", function()
        Confirm("End the event?", "It stops now for everyone: matches being played stay unfinished and the results are "
            .. "saved as they stand.", "End it", function()
                L():EndEvent(occ)
                Board:Refresh()
            end, true)
    end)
    fin:SetTitleAndTextTooltip("End the event", "Stops it now and saves the results as they stand.")
end

-- The header's More: the event page, the host, leaving.
function Board:HeaderMenu(owner)
    local occ, st = Data()
    UI():ContextMenu(owner, function(rootDesc)
        local EU = ns.EventsUI
        local open = EU and (EU.OpenEvent or EU.ShowEvent)
        if open and occ ~= "practice" then
            rootDesc:CreateButton(Glyph(UI().ICON.calendar) .. "Event page", function() open(EU, occ) end)
        end
        local host = st and st.host
        if host and not ns.Util.IsMe(host) and occ ~= "practice" then
            rootDesc:CreateButton(Glyph(UI().ICON.whisper) .. "Whisper the host", function()
                local fn = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
                if fn then fn("/w " .. ((Ambiguate and Ambiguate(host, "none")) or ns.Util.ShortName(host)) .. " ") end
            end)
        end
        local me = Me()
        if st and st.phase == "live" and H.Contains(st.entrants, me) and not ns.Util.IsMe(host or "") and occ ~= "practice" then
            rootDesc:CreateButton(Glyph(UI().ICON.trash, { 1, 0.55, 0.5 }) .. "|cffff8d80Leave the event|r", function()
                Confirm("Leave the event?", "Your match now is lost and you're out of the bracket.", "Leave", function()
                    if Ev() then Ev():SignUp(occ, false) end
                end)
            end)
        end
        if #(rootDesc.children or {}) == 0 then
            rootDesc:CreateTitle(occ == "practice" and "A practice run" or "Nothing to do here")
        end
    end)
end

---------------------------------------------------------------------------
-- Refresh, open, close
---------------------------------------------------------------------------

function Board:Refresh()
    if not (win and win:IsShown()) then return end
    local occ, st, def, bk = Data()
    RefreshHeader(occ, st, def, bk)
    local host = self:IsHost() and st ~= nil
    if not host and win.confirm:IsShown() and win.confirm.hostOnly then win.confirm:Hide() end
    local off = host and HOST_H or 0
    local br, rail = win.br, win.rail
    local height = CH - BR_Y - off - BOTTOM
    br:ClearAllPoints()
    br:SetPoint("TOPLEFT", win.root, "TOPLEFT", BR_X, -(BR_Y + off))
    br:SetHeight(height)
    rail:ClearAllPoints()
    rail:SetPoint("TOPRIGHT", win.root, "TOPRIGHT", -12, -(BR_Y + off))
    rail:SetHeight(height)
    if not st then
        win.hostbar:Hide()
        win.dispute:Hide()
        HideFrom(br.cards, 1)
        HideFrom(br.lines, 1)
        HideFrom(br.heads, 1)
        HideFrom(br.rows, 1)
        br.champ:Hide()
        br.note:ClearAllPoints()
        br.note:SetPoint("CENTER", br, "CENTER", 0, 20)
        br.note:SetText(L():IsLive(occ) and "Waiting for the host's board..." or "This event isn't running.")
        br.note:Show()
        for _, c in ipairs(rail.nows) do c:Hide() end
        for _, c in ipairs(rail.moms) do c:Hide() end
        for _, c in ipairs(rail.heads) do c:Hide() end
        for _, c in ipairs(rail.pods or {}) do c:Hide() end
        if rail.next then rail.next:Hide() end
        return
    end
    br.note:Hide()
    local disputes = (host or occ == "practice") and Disputes(st) or {}
    if host then RefreshHostBar(occ, st, bk, disputes) else win.hostbar:Hide() end
    if bk and not next(bk.m or {}) then
        -- a bracket drawn for fewer than 2 players has no match (it is over at once, no champion): who was there
        self:DrawPlayers(st, def, height, "Too few players for a bracket.")
    elseif bk and bk.fmt == "robin" then
        self:DrawRobin(bk, st, height)
    elseif bk then
        HideFrom(br.rows, 1)
        self:DrawTree(bk, st, height)
    else
        self:DrawPlayers(st, def, height)
    end
    self:DrawRail(occ, st, def, bk, height)
    RefreshDispute(occ, st, bk, disputes)
end

local function Fit()
    local sw, sh = UIParent:GetWidth() or WIN_W, UIParent:GetHeight() or WIN_H
    if sw <= 0 then sw = WIN_W end
    if sh <= 0 then sh = WIN_H end
    win:SetScale(min(1, (sw - 20) / WIN_W, (sh - 20) / WIN_H))
end

function Board:Open(occId)
    if type(occId) ~= "string" then return false end
    if not win then CreateWindow() end
    if state.occ ~= occId and win:IsShown() then
        if win.confirm then win.confirm:Hide() end
    end
    state.occ = occId
    if L() and L().Watch then L():Watch(occId) end
    -- (demo mode: the tracker shows the demo cup once its board was looked at)
    local T = ns.EventTracker
    if DemoOn() and T and not T.demoSeen then
        T.demoSeen = true
        if T.Later then T:Later() end
    end
    Fit()
    win:Show()
    win:Raise()
    self:Refresh()
    return true
end

function Board:Close()
    if win then win:Hide() end
end

function Board:IsShown() return win ~= nil and win:IsShown() end
function Board:GetWindow() return win end
function Board:GetOcc() return (win and win:IsShown()) and state.occ or nil end

function Board:Toggle(occId)
    if self:IsShown() and state.occ == occId then self:Close() else self:Open(occId) end
end

local function Later()
    if not (win and win:IsShown()) then return end
    ns.Util.Debounce("dz-eventboard", 0.15, function() Board:Refresh() end)
end

function Board:OnInit()
    ns:On("EVENT_LIVE_UPDATED", function(occId)
        if win and win:IsShown() and (occId == state.occ or occId == "demo") then Later() end
    end)
    ns:On("EVENT_PRACTICE_UPDATED", function()
        if state.occ == "practice" then Later() end
    end)
    ns:On("DEMO_TOGGLED", Later)
    ns:On("EVENTS_UPDATED", Later)
    if ns.RegisterSlash then
        ns:RegisterSlash("board", function()
            local list = L():GetLiveList()
            if list[1] then Board:Toggle(list[1]) else ns:Print("No event is running.") end
        end, "open the live board of the event that's on")
    end
end
