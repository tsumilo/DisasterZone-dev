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
local tsort, tconcat, tinsert = table.sort, table.concat, table.insert
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

-- A header's words in its room: smaller first (size down to minSize), else on two lines there (never cut).
function H.Fit2(fs, text, width, size, minSize)
    fs:SetWordWrap(false)
    if H.Fit(fs, text, width, size, minSize) then
        fs:SetWidth(max(1, floor(H.Width(fs) + 4.5)))
        return true
    end
    fs:SetWordWrap(true)
    fs:SetWidth(max(1, floor(width)))
    fs:SetText(text or "")
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

local DemoKinds      -- (forward) demo mode's part 2 boards: states built here, never sent

-- A state from another client is only read here: what isn't of its shape reads as empty (a broken or odd state
-- never stops the board). Once a state change (weak keys: nothing is added to the state itself, it goes out).
local cleaned = setmetatable({}, { __mode = "k" })
local SETS = { "tags", "scores", "lists", "lt", "buttons", "inplace" }
function H.Clean(st)
    if type(st) ~= "table" or cleaned[st] == st.seq then return st end
    for _, k in ipairs({ "entrants", "blocks", "tags", "scores", "lists", "lt", "last", "qa", "buttons", "point", "shown",
        "tstart", "timers", "moments", "awards", "vars", "stats" }) do
        if type(st[k]) ~= "table" then st[k] = {} end
    end
    for _, k in ipairs(SETS) do
        for id, set in pairs(type(st[k]) == "table" and st[k] or {}) do if type(set) ~= "table" then st[k][id] = nil end end
    end
    -- (numbers where numbers are counted and sorted)
    for _, k in ipairs({ "scores", "lists" }) do
        for _, t in pairs(st[k]) do
            for key, n in pairs(t) do if type(n) ~= "number" or n ~= n then t[key] = nil end end
        end
    end
    for _, t in pairs(st.stats) do
        if type(t) == "table" then for key, n in pairs(t) do if type(n) ~= "number" then t[key] = nil end end end
    end
    for lid, t in pairs(st.lt) do
        for key, times in pairs(t) do
            if type(times) ~= "table" then t[key] = nil else
                for i, x in pairs(times) do if type(x) ~= "number" then times[i] = nil end end
            end
        end
    end
    for key, l in pairs(st.last) do if type(l) ~= "table" then st.last[key] = nil end end
    for aid, q in pairs(st.qa) do
        if type(q) ~= "table" then st.qa[aid] = nil else
            if type(q.who) ~= "table" then q.who = {} end
            if type(q.ans) ~= "table" then q.ans = {} end
        end
    end
    for i = #st.moments, 1, -1 do if type(st.moments[i]) ~= "table" then table.remove(st.moments, i) end end
    for i = #st.timers, 1, -1 do if type(st.timers[i]) ~= "table" then table.remove(st.timers, i) end end
    cleaned[st] = st.seq
    return st
end

-- A run's state and def: a live one's, the practice run's, or one of demo mode's boards.
local function StateOf(occ)
    local d = DemoKinds and DemoKinds(occ)
    if d then return d.st, d.def end
    return H.Clean(L():GetState(occ)), L():GetDef(occ)
end
Board.StateOf = function(_, occ) return StateOf(occ) end

local function Data()
    local occ = state.occ
    if not occ then return nil end
    local st, def = StateOf(occ)
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
    -- (part 2: my tag's colour)
    chip.dotEdge = H.Disc(chip, "ARTWORK", 1, 10, 0, 0, 0, 1)
    chip.dotEdge:SetPoint("CENTER", chip, "LEFT", 12, 0)
    chip.dot = H.Disc(chip, "ARTWORK", 2, 8, 1, 1, 1, 1)
    chip.dot:SetPoint("CENTER", chip.dotEdge)
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
    -- an event without Matches: my place by its board's score ("You're 3rd") or my tag ("You: Hiders")
    local p2
    if not m and st and def and not bk and (st.phase == "live" or st.phase == "done") then p2 = Board:MyChip(occ, st, def) end
    chip.dot:Hide()
    chip.dotEdge:Hide()
    if m then
        H.SetClass(chip.cls, H.Opp(m, me))
        chip.cls:Show()
        chip:SetWidth(floor(6 + 15 + 6 + H.Width(chip.fs) + 10 + 0.5))
        chip:Show()
    elseif p2 then
        chip:SetPillColors({ 0.055, 0.055, 0.066, 1 }, { 0.4, 0.72, 1, 0.75 })
        chip.fs:SetTextColor(0.84, 0.93, 1)
        chip.fs:SetText(p2.text)
        chip.fs:ClearAllPoints()
        if p2.rgb then
            chip.cls:Hide()
            chip.dot:SetVertexColor(p2.rgb[1], p2.rgb[2], p2.rgb[3], 1)
            chip.dot:Show()
            chip.dotEdge:Show()
            chip.fs:SetPoint("LEFT", chip.dot, "RIGHT", 6, 0)
            chip:SetWidth(floor(8 + 8 + 6 + H.Width(chip.fs) + 10 + 0.5))
        else
            H.SetClass(chip.cls, me)
            chip.cls:Show()
            chip.fs:SetPoint("LEFT", chip.cls, "RIGHT", 6, 0)
            chip:SetWidth(floor(6 + 15 + 6 + H.Width(chip.fs) + 10 + 0.5))
        end
        chip.tip = p2.tip
        chip:Show()
    else
        chip:Hide()
    end
    if not p2 then
        chip.fs:ClearAllPoints()
        chip.fs:SetPoint("LEFT", chip.cls, "RIGHT", 6, 0)
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
    local top = 20
    local hh = height - top - 6
    -- the first round drawn: the earliest whose matches fit as cards (two rows of 11 at least). A bracket of 33 to 64
    -- starts later: who comes out of the rounds before shows in the slots they lead to ("Round 1 · 5"), the matches
    -- being played in the rail.
    local r0 = 1
    while r0 < R and #main[r0] > 1 and hh / #main[r0] < 2 * 11 + 1 + 2 do r0 = r0 + 1 end
    local Rn = R - r0 + 1
    local n1 = max(1, #main[r0])
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
    local cw, pitch = (Rn <= 3) and 150 or CARD_W, 0
    if Rn > 1 then
        pitch = (BR_W - cw) / (Rn - 1)
        if pitch < cw + COL_GAP_MIN then
            cw = floor((BR_W - COL_GAP_MIN * (Rn - 1)) / Rn)
            pitch = (BR_W - cw) / (Rn - 1)
        end
        pitch = min(pitch, 196)
    end
    local seedW = (Rn >= 5) and 0 or 13
    local fsize = rh >= 17 and 11 or (rh >= 14 and 10 or 9)
    local circ = min(13, rh - 4)
    local function X(r) return floor((r - r0) * pitch + 0.5) end
    -- the centres of the cards, round by round
    local cy = { [r0] = {} }
    for i = 1, #main[r0] do cy[r0][i] = y0 + (i - 0.5) * slot end
    for r = r0 + 1, R do
        cy[r] = {}
        for i = 1, #main[r] do
            local a, b = cy[r - 1][2 * i - 1], cy[r - 1][2 * i]
            cy[r][i] = (a and b) and (a + b) / 2 or (a or (top + hh / 2))
        end
    end
    local myNext = H.MyNext(bk, me)
    -- the round headers (the current one gold)
    local nh = 0
    for r = r0, R do
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
    for r = r0, R do
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
    for r = r0 + 1, R do
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
        -- ("+12 more": who they are)
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(self)
            if not self.rest then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            for _, k in ipairs(self.rest) do GameTooltip:AddLine(H.Name(k)) end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        br.rows[i] = r
    end
    r.rest = nil
    return r
end

-- A row of the standings or the players' grid as "+12 more" (rest: their keys, for the tooltip).
local function MoreRow(r, rest)
    r.rest = rest
    r.rank:SetText("")
    r.cls:Hide()
    r.name:SetText("+" .. #rest .. " more")
    r.name:SetTextColor(GREY[1], GREY[2], GREY[3])
    H.Sized(r.name, 11)
    r.w:SetText("")
    r.d:SetText("")
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
    -- (rows of 18 at least: more players than fit show the top ones, me among them, and "+12 more")
    local fit = max(2, floor((height - 22) / 18))
    local list = {}
    for i, row in ipairs(rows) do list[i] = { row = row, rank = i } end
    local rest
    if #list > fit then
        local mine
        for i, e in ipairs(list) do if e.row.k == me then mine = i end end
        local keep = {}
        for i = 1, fit - 1 do keep[i] = list[i] end
        if mine and mine > fit - 1 then keep[fit - 1] = list[mine] end
        local kept = {}
        for _, e in ipairs(keep) do kept[e.row.k] = true end
        rest = {}
        for _, e in ipairs(list) do if not kept[e.row.k] then rest[#rest + 1] = e.row.k end end
        list = keep
    end
    local nrows = #list + (rest and 1 or 0)
    local rowH = min(22, floor((height - 22) / max(1, nrows)))
    for i, e in ipairs(list) do
        local row = e.row
        local r = RobinRow(i)
        r:SetSize(272, rowH)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", br, "TOPLEFT", 0, -(20 + (i - 1) * rowH))
        r.band:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.025 or 0)
        r.rank:SetText(tostring(e.rank))
        if e.rank == 1 and row.w > 0 then r.rank:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) else r.rank:SetTextColor(GREY[1], GREY[2], GREY[3]) end
        H.SetClass(r.cls, row.k)
        H.Fit(r.name, H.Name(row.k), 272 - 46 - 100, 11, 9)
        r.name:SetWidth(272 - 46 - 100)
        r.w:SetText(tostring(row.w))
        r.d:SetText((row.d > 0 and "+" or "") .. row.d)
        if row.d > 0 then r.d:SetTextColor(0.62, 0.94, 0.69) elseif row.d < 0 then r.d:SetTextColor(GREY[1], GREY[2], GREY[3])
        else r.d:SetTextColor(0.8, 0.8, 0.8) end
        r:Show()
    end
    if rest then
        local r = RobinRow(#list + 1)
        r:SetSize(272, rowH)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", br, "TOPLEFT", 0, -(20 + #list * rowH))
        r.band:SetColorTexture(0, 0, 0, 0)
        MoreRow(r, rest)
        r:Show()
    end
    HideFrom(br.rows, nrows + 1)
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
    -- (more than the room holds: the first ones, me among them, and "+12 more" in the last place)
    local room = cols * max(1, floor((height - 30 - 20) / rowH))
    local rest
    if #list > room then
        local me = Me()
        local mine = H.Contains(list, me)
        local keep = {}
        for i = 1, room - 1 do keep[i] = list[i] end
        if mine and mine > room - 1 then keep[room - 1] = me end
        rest = {}
        for _, k in ipairs(list) do if not H.Contains(keep, k) then rest[#rest + 1] = k end end
        list = keep
    end
    local n = 0
    local function cell(i)
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        local r = RobinRow(i)
        r:SetSize(colW - 6, rowH)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", br, "TOPLEFT", col * colW - 20, -(20 + row * rowH))
        r.band:SetColorTexture(0, 0, 0, 0)
        return r
    end
    for i, k in ipairs(list) do
        n = n + 1
        local r = cell(n)
        r.rank:SetText("")
        H.SetClass(r.cls, k)
        H.Fit(r.name, H.Name(k), colW - 50, 11, 9)
        r.name:SetWidth(colW - 50)
        r.w:SetText("")
        r.d:SetText("")
        r:Show()
    end
    if rest then
        n = n + 1
        local r = cell(n)
        MoreRow(r, rest)
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
local TickKinds   -- (forward: part 2's time left cards)

function Board:TickClocks()
    if not (win and win:IsShown()) then return end
    local occ, st = Data()
    if not st then return end
    for _, c in ipairs(win.rail.nows) do
        if c:IsShown() and c.m and c.m.st == "play" then c.clock:SetText(H.Clock(ElapsedOf(st, c.m, occ))) end
    end
    if TickKinds then TickKinds(occ, st) end
    -- ("2 min ago", the asking clock: a full redraw now and then)
    win.slow = (win.slow or 0) + 1
    if win.slow >= 15 then
        win.slow = 0
        if win.kv and win.kv:IsShown() then self:Refresh() end
    end
end

---------------------------------------------------------------------------
-- Part 2: the views drawn from what the event has (mockup shots 20-22): a column for each tag with the board's
-- scores next to the names, the event's places on the zone's map, leaderboards, a list walked per player as progress
-- (a race) with its splits, the shown timers as "time left", the prizes, the last ask's result, the moments.
---------------------------------------------------------------------------

local MAIN_W = BR_W
local MAP_H, MAP_MIN = 250, 150
local COL_ROW, LB_ROW, RACE_ROW = 26, 42, 37
local SECRET = "Where players are stays secret"
local TEAL = { 0.337, 0.839, 0.941 }
local MEDAL_TEXT = { { 1, 0.82, 0 }, { 0.875, 0.894, 0.925 }, { 0.91, 0.64, 0.416 } }

local function EachPiece(def, fn)
    B():EachScript(def, function(s) B():Walk(s.top, fn) end)
end

local function SetKeys(set, order)
    local out = {}
    if type(set) ~= "table" then return out end
    local at = {}
    for i, k in ipairs(order or {}) do at[k] = i end
    for k, on in pairs(set) do if type(k) == "string" and on then out[#out + 1] = k end end
    tsort(out, function(a, b)
        local x, y = at[a] or 1e6, at[b] or 1e6
        if x ~= y then return x < y end
        return a < b
    end)
    return out
end
Board.SetKeys = function(_, ...) return SetKeys(...) end

-- A tag may be seen on the board: everyone's (shown "all"), the host's own ("host") on the host's screen.
local function TagSeen(def, st, tid)
    local t = B():Definition(def, "tags", tid)
    if not t or t.builtin then return false end
    local shown = t.shown or "all"
    if shown == "all" then return true end
    return shown == "host" and st and st.host == Me() or false
end

local function RGB(c) return B():TagColor(c) end

-- What the board draws for an event: { layout = "bracket" | "race" | "columns" | "scores" | "players", tags (seen),
-- scores (on the board), main (the first of them), places (with a map point), walked (a list walked per player),
-- list, signup (a sign-up is open) }.
function Board:Views(def, st)
    local v = { tags = {}, scores = {}, places = {} }
    if not (def and st) then v.layout = "players"; return v end
    for _, sc in ipairs(B():Defs(def, "scores", true)) do if sc.board then v.scores[#v.scores + 1] = sc end end
    for _, t in ipairs(B():Defs(def, "tags", true)) do if TagSeen(def, st, t.id) then v.tags[#v.tags + 1] = t end end
    -- (the columns in the order the event made its tags: Hiders, Seekers, Found)
    local function num(id) return tonumber(tostring(id):match("(%d+)$")) or 1e6 end
    tsort(v.tags, function(a, b)
        if num(a.id) ~= num(b.id) then return num(a.id) < num(b.id) end
        return tostring(a.id) < tostring(b.id)
    end)
    for _, p in ipairs(B():Defs(def, "places", true)) do
        if tonumber(p.map) and tonumber(p.x) and tonumber(p.y) then v.places[#v.places + 1] = p end
    end
    -- a list walked per player: "move ... on in", "... 's item in", "... 's place in", "reaches the end of"
    EachPiece(def, function(p)
        local i = (p.k == "lo.lnext" or p.k == "lo.lmine" or p.k == "lo.lpos") and 2 or (p.k == "lo.lend" and 1) or nil
        local lid = i and p.a and p.a[i]
        if not v.walked and type(lid) == "string" and B():Definition(def, "lists", lid) then v.walked = lid end
    end)
    v.list = v.walked and B():Definition(def, "lists", v.walked) or nil
    v.main = v.scores[1]
    for _, b in pairs(st.blocks or {}) do
        if type(b) == "table" and b.kind == "signup" and b.open then v.signup = true end
    end
    if E():BracketOf(def, st) then v.layout = "bracket"
    elseif v.walked then v.layout = "race"
    elseif #v.tags >= 2 or (#v.tags == 1 and #v.scores == 0) then v.layout = "columns"
    elseif #v.scores > 0 then v.layout = "scores"
    else v.layout = "players" end
    -- (nobody has a tag or a score while the sign-up is open: who signed up instead)
    if v.signup and (v.layout == "columns" or v.layout == "scores") then v.main2 = v.layout; v.layout = "players" end
    return v
end

-- The prizes and how each is won, from the pieces that give it ("give ... the badge" under "if ... 's place by Fish
-- = 1", or to "top 1 by Fish"): { { id, b, sid, n, how } } in the def's order.
local function PrizeHow(def)
    local parent, how = {}, {}
    EachPiece(def, function(p, par, slot) parent[p] = { par, slot } end)
    local function placeOf(cond)
        if type(cond) ~= "table" or cond.k ~= "lo.eq" then return nil end
        local a1, a2 = cond.a and cond.a[1], cond.a and cond.a[2]
        if type(a2) == "table" and a2.k == "pt.place" then a1, a2 = a2, a1 end
        if type(a1) == "table" and a1.k == "pt.place" and type(a1.a and a1.a[2]) == "string" and tonumber(a2) then
            return a1.a[2], tonumber(a2)
        end
        return nil
    end
    EachPiece(def, function(p)
        if p.k ~= "pt.badge" or type(p.a and p.a[1]) ~= "string" then return end
        local bid = p.a[1]
        local who = p.a[2]
        if type(who) == "table" and who.k == "pl.top" and type(who.a and who.a[2]) == "string" and tonumber(who.a[1]) == 1 then
            how[bid] = how[bid] or { who.a[2], 1 }
            return
        end
        local cur, guard = p, 0
        while cur and guard < 60 do
            guard = guard + 1
            local up = parent[cur]
            if not up then break end
            if up[2] == "c1" and up[1].k == "lo.if" then
                local sid, n = placeOf(up[1].a and up[1].a[1])
                if sid then how[bid] = how[bid] or { sid, n } break end
            end
            cur = up[1]
        end
    end)
    local out = {}
    for _, e in ipairs(B():BadgeList(def)) do
        local h = how[e.id]
        out[#out + 1] = { id = e.id, b = e.b, sid = h and h[1], n = h and h[2] }
    end
    -- one score's 1st, 2nd and 3rd: the places; else what each is for ("most Finds", "longest Hidden")
    local one, places = nil, true
    for _, e in ipairs(out) do
        if not e.sid then places = false
        elseif one and one ~= e.sid then places = false
        else one = e.sid end
    end
    local ORD = { "1st", "2nd", "3rd" }
    for _, e in ipairs(out) do
        if e.sid then
            local sc = B():Definition(def, "scores", e.sid)
            local name = sc and sc.n or tostring(e.sid)
            if places and #out > 1 and ORD[e.n] then
                e.how, e.place = ORD[e.n], true
            elseif e.n == 1 then
                local high = not (sc and sc.high == false)
                local time = sc and sc.fmt == "time"
                local word = high and (time and "longest" or "most") or (time and "fastest" or "fewest")
                -- (a score named "Most mushrooms" is already said so: not "most Most mushrooms")
                local first = (tostring(name):match("^(%a+)") or ""):lower()
                local said = { most = true, longest = true, fastest = true, fewest = true, least = true, highest = true,
                    lowest = true, best = true }
                e.how = said[first] and name or (word .. " " .. name)
            else
                e.how = (ORD[e.n] or (e.n .. "th")) .. " by " .. name
            end
        end
    end
    -- (the places in order)
    if places then tsort(out, function(x, y) return (x.n or 9) < (y.n or 9) end) end
    return out
end
Board.PrizeHow = function(_, def) return PrizeHow(def) end

-- What comes when a timer runs out (its "when timer runs out" script in this stage or Always): "then Prizes".
local function ThenOf(def, st, name)
    local out
    for _, s in ipairs(def and def.scripts or {}) do
        local top = s.top
        if not out and top and top.k == "ev.timer" and top.a and top.a[1] == name and (s.st == st.stage or s.st == "*") then
            B():Walk(top, function(p)
                if out then return end
                if p.k == "sg.next" then
                    local _, i = B():Stage(def, st.stage)
                    local nx = i and def.stages[i + 1]
                    out = nx and ("then " .. nx.name) or "then it ends"
                elseif p.k == "sg.go" and p.a and p.a[1] then
                    out = "then " .. B():StageName(def, p.a[1])
                elseif p.k == "sg.end" then
                    out = "then it ends"
                end
            end)
        end
    end
    return out
end

-- The clock a run's timers count on (the practice run's own; a paused run stands still).
local function RunNow(occ, st)
    local now = H.Now(occ)
    if type(st.paused) == "number" and occ ~= "practice" then now = min(now, st.paused) end
    return now
end

-- The timers the event shows on the board, running: { { n, left, total, ends } }.
function H.ShownTimers(occ, st)
    local out = {}
    local now = RunNow(occ, st)
    for name in pairs(st.shown or {}) do
        for _, t in ipairs(st.timers or {}) do
            if t.n == name and not t.p and tonumber(t.at) then
                local start = tonumber(st.tstart and st.tstart[name]) or now
                out[#out + 1] = { n = name, left = max(0, t.at - now), total = max(1, t.at - start), ends = t.at }
                break
            end
        end
    end
    tsort(out, function(a, b) return a.ends < b.ends end)
    return out
end

-- My place among who has a score (ties alike), nil without one.
local function PlaceOf(def, st, sid, key)
    local r = E():Reader(def, st)
    local p = r:PlaceBy(sid, key)
    return (p and p > 0) and p or nil
end
H.PlaceOf = PlaceOf

function H.Ordinal(n)
    n = tonumber(n) or 0
    local d, t = n % 10, n % 100
    if t >= 11 and t <= 13 then return n .. "th" end
    return n .. ((d == 1 and "st") or (d == 2 and "nd") or (d == 3 and "rd") or "th")
end

-- The players with a score, best first ({ key, n }), then (all: true) the entrants without it.
local function Ranked(def, st, sid, all)
    local list = E():Reader(def, st):Ranked(sid)
    if all then
        local has = {}
        for _, r in ipairs(list) do has[r.key] = true end
        for _, k in ipairs(st.entrants or {}) do
            if not has[k] then list[#list + 1] = { key = k } end
        end
    end
    return list
end

local function ScoreText(def, sid, n) return n ~= nil and B():FormatScore(def, sid, n) or "" end

-- (the "you" row: a blue tint and a blue bar on its left)
local function YouBand(r, on)
    r.band:SetColorTexture(0.4, 0.72, 1, 0.08)
    r.band:SetShown(on)
    r.bar:SetShown(on)
end

local function NewBand(r)
    r.band = r:CreateTexture(nil, "BACKGROUND", nil, 1)
    r.band:SetAllPoints()
    r.bar = r:CreateTexture(nil, "BACKGROUND", nil, 2)
    r.bar:SetPoint("TOPLEFT")
    r.bar:SetPoint("BOTTOMLEFT")
    r.bar:SetWidth(2)
    r.bar:SetColorTexture(0.4, 0.72, 1, 1)
end

local function NameTip(self)
    if not self.key then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(H.Name(self.key))
    for _, l in ipairs(self.tip or {}) do GameTooltip:AddLine(l, 0.85, 0.85, 0.85, true) end
    GameTooltip:Show()
end

---------------------------------------------------------------------------

local function KV()
    if win.kv then return win.kv end
    local kv = CreateFrame("Frame", nil, win.root)
    kv:SetAllPoints()
    kv:SetFrameLevel(win.root:GetFrameLevel() + 2)
    kv.map = EUI():CreateZoneMap(kv, MAIN_W, MAP_H)
    -- "Where players are stays secret"
    local sc = CreateFrame("Frame", nil, kv.map.top)
    sc:SetSize(100, 22)
    UI():AddPillShape(sc, 22)
    sc:SetPillColors({ 0.055, 0.055, 0.066, 0.78 }, { 0.43, 0.43, 0.47, 0.6 })
    sc.eye = sc:CreateTexture(nil, "ARTWORK")
    sc.eye:SetSize(12, 12)
    sc.eye:SetPoint("LEFT", 8, 0)
    EUI():Glyph(sc.eye, UI().ICON.eye, 0.62, 0.62, 0.66, 1)
    sc.fs = H.Text(sc, "GameFontHighlightSmall", 11, 0.91, 0.91, 0.91)
    sc.fs:SetPoint("LEFT", sc.eye, "RIGHT", 6, 0)
    sc.fs:SetText(SECRET)
    sc:SetWidth(floor(8 + 12 + 6 + H.Width(sc.fs) + 10 + 0.5))
    sc:SetPoint("TOPLEFT", kv.map, "TOPLEFT", 10, -9)
    sc:EnableMouse(true)
    sc:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine(SECRET)
        GameTooltip:AddLine("The map shows the event's places. Where the players are isn't sent to anyone; only the host's "
            .. "addon uses it, for the pieces that need it.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    sc:SetScript("OnLeave", function() GameTooltip:Hide() end)
    kv.secret = sc
    kv.route = { lines = {}, cps = {}, dots = {} }
    kv.cols, kv.lbRows, kv.raceRows, kv.tabs = {}, {}, {}, {}
    -- the leaderboard's and the race's header rows
    local function header(n)
        local h = CreateFrame("Frame", nil, kv)
        h:SetHeight(24)
        h.line = h:CreateTexture(nil, "BORDER")
        h.line:SetPoint("BOTTOMLEFT")
        h.line:SetPoint("BOTTOMRIGHT")
        h.line:SetHeight(1)
        h.line:SetColorTexture(1, 1, 1, 0.09)
        h.fs = {}
        for i = 1, n do h.fs[i] = H.Text(h, "GameFontHighlightSmall", 10.5, GREY[1], GREY[2], GREY[3]) end
        return h
    end
    kv.lbHead = header(4)
    kv.raceHead = header(5)
    -- my splits under my row of the race
    local sp = CreateFrame("Frame", nil, kv)
    sp:SetHeight(50)
    sp.bg = sp:CreateTexture(nil, "BACKGROUND")
    sp.bg:SetAllPoints()
    sp.bg:SetColorTexture(0.4, 0.72, 1, 0.05)
    sp.bar = sp:CreateTexture(nil, "BACKGROUND", nil, 1)
    sp.bar:SetPoint("TOPLEFT")
    sp.bar:SetPoint("BOTTOMLEFT")
    sp.bar:SetWidth(2)
    sp.bar:SetColorTexture(0.4, 0.72, 1, 1)
    sp.line = sp:CreateTexture(nil, "BORDER")
    sp.line:SetPoint("BOTTOMLEFT")
    sp.line:SetPoint("BOTTOMRIGHT")
    sp.line:SetHeight(1)
    sp.line:SetColorTexture(1, 1, 1, 0.035)
    sp.cells = {}
    kv.splits = sp
    -- the rail of these views
    local rail = CreateFrame("Frame", nil, kv)
    rail:SetSize(RAIL_W, 100)
    rail.heads, rail.times, rail.prizes, rail.moms = {}, {}, {}, {}
    kv.rail = rail
    -- a note in the middle of an empty view
    kv.note = H.Text(kv, "GameFontHighlight", 12, GREY[1], GREY[2], GREY[3])
    kv.note:SetJustifyH("CENTER")
    kv.note:SetWordWrap(true)
    win.kv = kv
    return kv
end

local function HideKV()
    local kv = win.kv
    if not kv then return end
    kv:Hide()
end

---------------------------------------------------------------------------
-- The map: the event's places (columns view: all of them; a race: its route)
---------------------------------------------------------------------------

-- The map most of the places are on.
local function MapOfPlaces(list)
    local count, best, bestN = {}, nil, 0
    for _, p in ipairs(list) do
        local m = tonumber(p.map)
        if m then
            count[m] = (count[m] or 0) + 1
            if count[m] > bestN then best, bestN = m, count[m] end
        end
    end
    return best
end

local function DrawPlacesMap(occ, def, st, v, x, y, w, h)
    local kv = win.kv
    local m = kv.map
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", win.root, "TOPLEFT", x, -y)
    m:SetSize2(w, h)
    local map = MapOfPlaces(v.places)
    m:SetMap(map)
    local pts = {}
    for _, p in ipairs(v.places) do
        if tonumber(p.map) == map then pts[#pts + 1] = { tonumber(p.x), tonumber(p.y), tonumber(p.r) or 30, p } end
    end
    m:Fit(pts, 0.3)
    for i, q in ipairs(pts) do
        m:Place(i, q[1], q[2], q[3], q[4].n)
        -- (its card on hover: zone, coordinates, how far; a click shows me the way there)
        local pid = q[4].id
        m:PlaceInfo(i, { place = q[4], click = function() EUI():ShowTheWay(occ, pid, def) end })
    end
    m:Done(#pts)
    m:ShowZone(true)
    m:ShowMe(true)
    for _, l in ipairs(kv.route.lines) do l:Hide() end
    for _, c in ipairs(kv.route.cps) do c:Hide() end
    for _, d in ipairs(kv.route.dots) do d:Hide() end
    kv.secret:Show()
    m:Show()
end

-- The first stage's "point ... to {place}": where the players gather (a race's start).
local function StartPlace(def)
    local first = def.stages and def.stages[1]
    local out
    for _, s in ipairs(def.scripts or {}) do
        if not out and first and s.st == first.id then
            B():Walk(s.top, function(p)
                if not out and p.k == "pc.point" and type(p.a and p.a[2]) == "string" and B():Definition(def, "places", p.a[2]) then
                    out = p.a[2]
                end
            end)
        end
    end
    return out
end

local function RouteLine(i)
    local r = win.kv.route
    local l = r.lines[i]
    if not l then
        l = win.kv.map.canvas:CreateLine(nil, "ARTWORK", nil, 1)
        r.lines[i] = l
    end
    return l
end

local function Checkpoint(i)
    local r = win.kv.route
    local c = r.cps[i]
    if not c then
        c = CreateFrame("Frame", nil, win.kv.map.canvas)
        c:SetSize(19, 19)
        c:SetFrameLevel(win.kv.map.canvas:GetFrameLevel() + 3)
        c.glow = H.Disc(c, "ARTWORK", 0, 27, TEAL[1], TEAL[2], TEAL[3], 0.35)
        c.glow:SetPoint("CENTER")
        c.edge = H.Disc(c, "ARTWORK", 1, 20, 0, 0, 0, 1)
        c.edge:SetPoint("CENTER")
        c.disc = H.Disc(c, "ARTWORK", 2, 17, TEAL[1], TEAL[2], TEAL[3], 1)
        c.disc:SetPoint("CENTER")
        c.fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        EUI():Narrow(c.fs, 10)
        c.fs:SetShadowOffset(0, 0)
        c.fs:SetPoint("CENTER", 0.5, 0)
        c.flag = c:CreateTexture(nil, "OVERLAY")
        c.flag:SetSize(11, 11)
        c.flag:SetPoint("CENTER")
        EUI():Glyph(c.flag, UI().ICON.flag, 0.16, 0.11, 0)
        c:EnableMouse(true)
        c:SetScript("OnEnter", function(self)
            if not self.name then return end
            if self.place then
                -- (the place's card: zone, coordinates, how far from me, a click shows the way; then what it is here)
                EUI():PlaceTip(self, self.place, self.click ~= nil)
                if self.sub then GameTooltip:AddLine(self.sub, 0.85, 0.85, 0.85) end
                GameTooltip:Show()
                return
            end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.name)
            if self.sub then GameTooltip:AddLine(self.sub, 0.85, 0.85, 0.85) end
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", function() GameTooltip:Hide() end)
        c:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and self.click then self.click() end
        end)
        r.cps[i] = c
    end
    return c
end

local function RouteDot(i)
    local r = win.kv.route
    local d = r.dots[i]
    if not d then
        d = CreateFrame("Frame", nil, win.kv.map.canvas)
        d:SetSize(16, 16)
        d:SetFrameLevel(win.kv.map.canvas:GetFrameLevel() + 5)
        d.glow = H.Disc(d, "ARTWORK", 0, 20, 0.4, 0.72, 1, 0.45)
        d.glow:SetPoint("CENTER")
        d.you = H.Disc(d, "ARTWORK", 1, 15, 0.4, 0.72, 1, 1)
        d.you:SetPoint("CENTER")
        d.edge = H.Disc(d, "ARTWORK", 2, 12, 0, 0, 0, 1)
        d.edge:SetPoint("CENTER")
        d.disc = H.Disc(d, "ARTWORK", 3, 9, 1, 1, 1, 1)
        d.disc:SetPoint("CENTER")
        d:EnableMouse(true)
        d:SetScript("OnEnter", NameTip)
        d:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r.dots[i] = d
    end
    return d
end

---------------------------------------------------------------------------
-- Tag columns (hide and seek): a column a tag, the board's score its players have most next to the names
---------------------------------------------------------------------------

local function Column(i)
    local kv = win.kv
    local c = kv.cols[i]
    if not c then
        c = CreateFrame("Frame", nil, kv)
        c.dotEdge = H.Disc(c, "ARTWORK", 1, 11, 0, 0, 0, 1)
        c.dot = H.Disc(c, "ARTWORK", 2, 9, 1, 1, 1, 1)
        c.dot:SetPoint("CENTER", c, "TOPLEFT", 6.5, -12)
        c.dotEdge:SetPoint("CENTER", c.dot)
        c.title = H.Text(c, "GameFontNormal", 12, GOLD[1], GOLD[2], GOLD[3])
        c.title:SetPoint("LEFT", c, "TOPLEFT", 18, -12)
        c.right = H.Text(c, "GameFontHighlightSmall", 10.5, GREY[1], GREY[2], GREY[3])
        c.right:SetJustifyH("RIGHT")
        c.right:SetPoint("RIGHT", c, "TOPRIGHT", -2, -12)
        c.line = c:CreateTexture(nil, "BORDER")
        c.line:SetPoint("TOPLEFT", 0, -24)
        c.line:SetPoint("TOPRIGHT", 0, -24)
        c.line:SetHeight(1)
        c.line:SetColorTexture(1, 1, 1, 0.08)
        c.rows = {}
        kv.cols[i] = c
    end
    return c
end

local function ColRow(c, i)
    local r = c.rows[i]
    if not r then
        r = CreateFrame("Frame", nil, c)
        r:SetHeight(COL_ROW)
        NewBand(r)
        r.cls = r:CreateTexture(nil, "ARTWORK")
        r.cls:SetSize(18, 18)
        r.cls:SetPoint("LEFT", 6, 0)
        r.name = H.Text(r, "GameFontHighlight", 12)
        r.name:SetPoint("LEFT", r.cls, "RIGHT", 8, 0)
        r.val = H.Text(r, "GameFontHighlight", 13)
        EUI():Narrow(r.val, 13)
        r.val:SetJustifyH("RIGHT")
        r.val:SetPoint("RIGHT", -6, 0)
        r.more = H.Text(r, "GameFontHighlightSmall", 11, GREY[1], GREY[2], GREY[3])
        r.more:SetPoint("LEFT", 8, 0)
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(self)
            if self.rest then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(self.restTitle or "More")
                for _, k in ipairs(self.rest) do GameTooltip:AddLine(H.Name(k)) end
                GameTooltip:Show()
            else
                NameTip(self)
            end
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        c.rows[i] = r
    end
    return r
end

-- The score a column's players have most (nil: none of them has one).
local function ColumnScore(st, keys, scores)
    local best, bestN = nil, 0
    for _, sc in ipairs(scores) do
        local rows = type(st.scores) == "table" and st.scores[sc.id] or {}
        local n = 0
        for _, k in ipairs(keys) do if rows[k] ~= nil then n = n + 1 end end
        if n > bestN then best, bestN = sc, n end
    end
    return best
end

function Board:DrawColumns(st, def, v, x, y, w, h)
    local me = Me()
    local cols = {}
    for _, t in ipairs(v.tags) do
        cols[#cols + 1] = { title = t.n, rgb = RGB(t.c), keys = SetKeys(st.tags and st.tags[t.id], st.entrants) }
    end
    if #cols == 1 then
        -- one tag: its players and everyone else
        local set = st.tags and st.tags[v.tags[1].id] or {}
        local rest = {}
        for _, k in ipairs(st.entrants or {}) do if not set[k] then rest[#rest + 1] = k end end
        cols[2] = { title = "Everyone else", keys = rest }
    end
    -- (more than four tags: three columns and a fourth for the others, a row each: its colour, name and how many)
    if #cols > 4 then
        local others = {}
        for i = 4, #cols do others[#others + 1] = cols[i] end
        cols = { cols[1], cols[2], cols[3], { title = "Other tags", tags = others, keys = {} } }
    end
    local n = min(4, #cols)
    local gap = EUI().GAP
    local cw = floor((w - gap * (n - 1)) / n)
    local maxRows = max(1, floor((h - 28) / COL_ROW))
    for i = 1, n do
        local col = cols[i]
        local c = Column(i)
        c:ClearAllPoints()
        local cx = x + (i - 1) * (cw + gap)
        local width = (i == n) and (x + w - cx) or cw
        c:SetPoint("TOPLEFT", win.root, "TOPLEFT", cx, -y)
        c:SetSize(width, h)
        if col.rgb then
            c.dot:SetVertexColor(col.rgb[1], col.rgb[2], col.rgb[3], 1)
            c.dot:Show()
            c.dotEdge:Show()
            c.title:ClearAllPoints()
            c.title:SetPoint("LEFT", c, "TOPLEFT", 18, -12)
        else
            c.dot:Hide()
            c.dotEdge:Hide()
            c.title:ClearAllPoints()
            c.title:SetPoint("LEFT", c, "TOPLEFT", 2, -12)
        end
        local sc = not col.tags and ColumnScore(st, col.keys, v.scores) or nil
        -- (the tag's name and the score's share the header: each gets smaller before the score's name goes)
        local room = width - 18 - 2
        c.right:SetText(sc and sc.n or "")
        H.Sized(c.right, 10.5)
        H.Sized(c.title, 12)
        c.title:SetText(col.title)
        if sc and H.Width(c.title) + 8 + H.Width(c.right) > room then
            H.Fit(c.right, sc.n, max(40, floor(room * 0.45)), 10.5, 9)
            if H.Width(c.right) > floor(room * 0.45) + 1 then c.right:SetText("") end
        end
        local rw = (c.right:GetText() or "") ~= "" and (H.Width(c.right) + 8) or 0
        c.title:SetWordWrap(false)
        if not H.Fit(c.title, col.title, room - rw, 12, 10) then
            -- (the tag's name first: the score's goes, its values stay next to the names; then smaller, then two lines)
            c.right:SetText("")
            H.Fit2(c.title, col.title, room, 12, 9)
        end
        if col.tags then
            -- the other tags: a row each
            local ry = 28
            for j, t in ipairs(col.tags) do
                local r = ColRow(c, j)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -ry)
                r:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, -ry)
                r.key, r.tip = nil, nil
                r.rest, r.restTitle = t.keys, t.title
                YouBand(r, false)
                r.cls:SetTexture(EUI().MASK)
                r.cls:SetTexCoord(0, 1, 0, 1)
                r.cls:SetDesaturated(false)
                local c3 = t.rgb or { 0.8, 0.8, 0.8 }
                r.cls:SetVertexColor(c3[1], c3[2], c3[3], 1)
                r.cls:SetSize(10, 10)
                r.cls:Show()
                r.val:SetText(tostring(#t.keys))
                r.val:SetTextColor(0.91, 0.91, 0.91)
                -- (the name starts after the dot: 6 + 10 + 8; the count at the right)
                H.Fit2(r.name, t.title, width - 6 - 10 - 8 - 6 - (H.Width(r.val) + 8), 12, 10)
                r.name:SetTextColor(1, 1, 1)
                r.name:Show()
                r.more:Hide()
                r:Show()
                ry = ry + COL_ROW
                if 28 + j * COL_ROW + COL_ROW > h then
                    for x2 = j + 1, #c.rows do c.rows[x2]:Hide() end
                    break
                end
            end
            for j = #col.tags + 1, #c.rows do c.rows[j]:Hide() end
            c:Show()
        else
        -- best first by its score; else me first
        local rows = sc and (type(st.scores) == "table" and st.scores[sc.id]) or {}
        local order = {}
        for j, k in ipairs(st.entrants or {}) do order[k] = j end
        local keys = col.keys
        local low = sc and sc.high == false
        tsort(keys, function(a, b)
            if sc then
                local va, vb = rows[a], rows[b]
                if (va ~= nil) ~= (vb ~= nil) then return va ~= nil end
                if va ~= nil and va ~= vb then if low then return va < vb end return va > vb end
            else
                local ma, mb = a == me, b == me
                if ma ~= mb then return ma end
            end
            return (order[a] or 1e6) < (order[b] or 1e6)
        end)
        local shown = #keys
        local more = 0
        if shown > maxRows then shown, more = maxRows - 1, #keys - (maxRows - 1) end
        local ry = 28
        for j = 1, shown do
            local k = keys[j]
            local r = ColRow(c, j)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -ry)
            r:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, -ry)
            r.key, r.rest, r.tip = k, nil, nil
            YouBand(r, ns.Util.IsMe(k))
            r.cls:SetSize(18, 18)
            H.SetClass(r.cls, k)
            r.cls:Show()
            local val = sc and rows[k]
            local text = ""
            if sc then
                if val ~= nil then text = ScoreText(def, sc.id, val)
                elseif not low and (sc.fmt or "num") == "num" then text = "0" end
            end
            r.val:SetText(text)
            local dim = val == nil or tonumber(val) == 0
            if dim then r.val:SetTextColor(0.44, 0.44, 0.46) else r.val:SetTextColor(0.91, 0.91, 0.91) end
            local vw = text ~= "" and (H.Width(r.val) + 8) or 0
            H.Fit2(r.name, H.Name(k), width - 6 - 18 - 8 - 6 - vw, 12, 10)
            r.name:Show()
            r.more:Hide()
            r:Show()
            ry = ry + COL_ROW
        end
        local used = shown
        if more > 0 then
            used = used + 1
            local r = ColRow(c, used)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -ry)
            r:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, -ry)
            r.key, r.rest, r.restTitle = nil, {}, col.title
            for j = shown + 1, #keys do r.rest[#r.rest + 1] = keys[j] end
            YouBand(r, false)
            r.cls:Hide()
            r.name:Hide()
            r.val:SetText("")
            r.more:SetText("+" .. more .. " more")
            r.more:Show()
            r:Show()
        end
        for j = used + 1, #c.rows do c.rows[j]:Hide() end
        c:Show()
        end
    end
    for i = n + 1, #win.kv.cols do win.kv.cols[i]:Hide() end
end

---------------------------------------------------------------------------
-- Leaderboards (a score chase): # / player / score / the last catch (or a bar), top 10 with me
---------------------------------------------------------------------------

local function LbRow(i)
    local kv = win.kv
    local r = kv.lbRows[i]
    if not r then
        r = CreateFrame("Frame", nil, kv)
        r:SetHeight(LB_ROW)
        NewBand(r)
        r.top = r:CreateTexture(nil, "BACKGROUND", nil, 0)
        r.top:SetAllPoints()
        r.top:SetColorTexture(1, 0.82, 0, 0.035)
        r.line = r:CreateTexture(nil, "BORDER")
        r.line:SetPoint("BOTTOMLEFT")
        r.line:SetPoint("BOTTOMRIGHT")
        r.line:SetHeight(1)
        r.line:SetColorTexture(1, 1, 1, 0.04)
        r.medal = EUI():CreateMedal(r, 24)
        r.medal:SetPoint("CENTER", r, "LEFT", 8 + 12, 0)
        r.rank = H.Text(r, "GameFontHighlight", 15, 0.78, 0.78, 0.78)
        EUI():Narrow(r.rank, 15)
        r.rank:SetJustifyH("CENTER")
        r.rank:SetPoint("CENTER", r, "LEFT", 8 + 12, 0)
        r.cls = r:CreateTexture(nil, "ARTWORK")
        r.cls:SetSize(22, 22)
        r.cls:SetPoint("LEFT", 8 + 24 + 10, 0)
        r.name = H.Text(r, "GameFontHighlight", 12.5)
        r.name:SetPoint("LEFT", r.cls, "RIGHT", 10, 0)
        r.score = H.Text(r, "GameFontHighlight", 18, 1, 1, 1)
        EUI():Narrow(r.score, 18)
        r.score:SetJustifyH("RIGHT")
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(18, 18)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.last = H.Text(r, "GameFontHighlightSmall", 11, 0.81, 0.81, 0.81)
        r.ago = H.Text(r, "GameFontHighlightSmall", 10.5, 0.44, 0.44, 0.46)
        r.ago:SetJustifyH("RIGHT")
        r.ago:SetPoint("RIGHT", -10, 0)
        r.track = r:CreateTexture(nil, "ARTWORK")
        r.track:SetHeight(4)
        r.track:SetColorTexture(1, 1, 1, 0.07)
        r.fill = r:CreateTexture(nil, "ARTWORK", nil, 1)
        r.fill:SetHeight(4)
        r.fill:SetTexture(WHITE)
        if r.fill.SetGradient and CreateColor then
            r.fill:SetGradient("HORIZONTAL", CreateColor(0.18, 0.5, 0.66, 1), CreateColor(0.42, 0.78, 0.94, 1))
        else
            r.fill:SetColorTexture(0.42, 0.78, 0.94, 1)
        end
        r.chip = EUI():CreateChip(r, "track")
        r:EnableMouse(true)
        r:SetScript("OnEnter", NameTip)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        kv.lbRows[i] = r
    end
    return r
end

-- What "last catch" means for this event (fish / loot / kill, by what its happenings use), or nil.
local function LastKind(def)
    local s = B():Senses(def) or {}
    local h = s.happen or {}
    if h.fish then return "fish", "Last catch" end
    if h.loot then return "loot", "Last loot" end
    if h.kill then return "kill", "Last kill" end
    return nil
end

-- The word for the players' column: anglers, racers, players.
local function PlayersWord(def, v)
    local s = B():Senses(def) or {}
    if s.happen and s.happen.fish then return "Angler" end
    if v.walked then return "Racer" end
    return "Player"
end

local function Tab(i)
    local kv = win.kv
    local t = kv.tabs[i]
    if not t then
        t = UI():CreateUnderlineTab(kv, "", function(self)
            -- ("More": the scores the strip has no room for, in a menu)
            if self.rest then
                local rest = self.rest
                UI():ContextMenu(self, function(root)
                    for _, s in ipairs(rest) do
                        root:CreateButton(s.n or "Score", function()
                            state.tab = s.id
                            Board:Refresh()
                        end)
                    end
                end)
                return
            end
            state.tab = self.sid
            Board:Refresh()
        end, "small")
        kv.tabs[i] = t
    end
    return t
end

function Board:DrawScores(occ, st, def, v, x, y, w, h)
    local kv = win.kv
    local me = Me()
    -- tabs when more than one score is on the board
    local sc = v.main
    if #v.scores > 1 then
        local tx = x
        for i, s in ipairs(v.scores) do
            if s.id == state.tab then sc = s end
        end
        -- (as many as the width holds, the shown score among them; the rest in a "More" tab's menu)
        local order = {}
        for _, s in ipairs(v.scores) do if s.id == sc.id then order[#order + 1] = s end end
        for _, s in ipairs(v.scores) do if s.id ~= sc.id then order[#order + 1] = s end end
        local n, rest = 0, {}
        local MORE_W = 64
        for i, s in ipairs(order) do
            local t = Tab(n + 1)
            t.rest = nil
            t:SetLabel(s.n)
            local tw = t:GetWidth()
            local need = (i < #order) and MORE_W or 0
            if n > 0 and tx + tw + need > x + w then
                for j = i, #order do rest[#rest + 1] = order[j] end
                break
            end
            n = n + 1
            t.sid = s.id
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", win.root, "TOPLEFT", tx, -y)
            t:SetActive(s.id == sc.id)
            t:Show()
            tx = tx + tw + 4
        end
        -- (the strip keeps the scores' own order: the shown one where it belongs among those that fit)
        local shownTabs = {}
        for i = 1, n do shownTabs[i] = kv.tabs[i] end
        local pos = {}
        for i, s in ipairs(v.scores) do pos[s.id] = i end
        table.sort(shownTabs, function(a, b2) return pos[a.sid] < pos[b2.sid] end)
        tx = x
        for _, t in ipairs(shownTabs) do
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", win.root, "TOPLEFT", tx, -y)
            tx = tx + t:GetWidth() + 4
        end
        if #rest > 0 then
            n = n + 1
            local t = Tab(n)
            t.sid, t.rest = nil, rest
            t:SetLabel("+" .. #rest .. " more")
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", win.root, "TOPLEFT", tx, -y)
            t:SetActive(false)
            t:Show()
        end
        for i = n + 1, #kv.tabs do kv.tabs[i]:Hide() end
        y, h = y + 24, h - 24
    else
        for _, t in ipairs(kv.tabs) do t:Hide() end
    end
    local lastKind, lastWord = LastKind(def)
    -- the header
    local hd = kv.lbHead
    hd:ClearAllPoints()
    hd:SetPoint("TOPLEFT", win.root, "TOPLEFT", x, -y)
    hd:SetWidth(w)
    local f = hd.fs
    local nameX, scoreR = 8 + 24 + 10 + 22 + 10, 8 + 24 + 10 + 22 + 10 + 132 + 10 + 48
    f[1]:ClearAllPoints(); f[1]:SetPoint("CENTER", hd, "LEFT", 8 + 12, 0); f[1]:SetText("#")
    f[2]:ClearAllPoints(); f[2]:SetPoint("LEFT", hd, "LEFT", nameX, 0); f[2]:SetText(PlayersWord(def, v))
    f[3]:ClearAllPoints(); f[3]:SetPoint("RIGHT", hd, "LEFT", scoreR, 0); f[3]:SetJustifyH("RIGHT")
    -- (a long score name: smaller, clear of the players' word)
    H.Sized(f[2], 10.5)
    H.Fit2(f[3], sc and sc.n or "", max(40, scoreR - nameX - H.Width(f[2]) - 10), 10.5, 9)
    f[4]:ClearAllPoints(); f[4]:SetPoint("LEFT", hd, "LEFT", scoreR + 10, 0)
    f[4]:SetText(lastKind and lastWord or "")
    for i = 1, 4 do f[i]:Show() end
    hd:Show()
    -- the rows: top 10, me among them (my own row instead of the 10th when I'm further down)
    local list = sc and Ranked(def, st, sc.id, true) or {}
    local rows = max(1, min(10, floor((h - 24) / LB_ROW)))
    local mine
    for i, r in ipairs(list) do if r.key == me then mine = i end end
    local pick = {}
    for i = 1, min(rows, #list) do pick[#pick + 1] = i end
    if mine and mine > rows then pick[#pick] = mine end
    local best = list[1] and tonumber(list[1].n) or 0
    local ry = y + 24
    local now = H.Now(occ)
    for j, idx in ipairs(pick) do
        local e = list[idx]
        local r = LbRow(j)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", win.root, "TOPLEFT", x, -ry)
        r:SetWidth(w)
        r.key, r.tip = e.key, nil
        local isMe = ns.Util.IsMe(e.key)
        YouBand(r, isMe)
        local place = e.n ~= nil and PlaceOf(def, st, sc.id, e.key) or nil
        r.top:SetShown(place ~= nil and place <= 3 and not isMe)
        if place and place <= 3 then
            r.medal:Set(place)
            r.rank:SetText("")
        else
            r.medal:Set(nil)
            r.rank:SetText(place and tostring(place) or "–")
        end
        H.SetClass(r.cls, e.key)
        H.Fit(r.name, H.Name(e.key), 132, 12.5, 10)
        r.name:SetWidth(132)
        r.score:ClearAllPoints()
        r.score:SetPoint("RIGHT", r, "LEFT", scoreR, 0)
        local text = e.n ~= nil and ScoreText(def, sc.id, e.n) or ((sc.high ~= false and (sc.fmt or "num") == "num") and "0" or "")
        H.Fit(r.score, text, 48 + 10, 18, 12)
        if e.n == nil then r.score:SetTextColor(0.44, 0.44, 0.46) else r.score:SetTextColor(1, 1, 1) end
        -- the last catch (its item, its name, how long ago); else a bar of the score against the leader's, and the
        -- player's tags
        local lx = scoreR + 10
        local last = lastKind and type(st.last) == "table" and st.last[e.key]
        if last and last.w ~= lastKind and not (lastKind == "loot" and last.w == "fish") then last = nil end
        r.icon:Hide(); r.last:SetText(""); r.ago:SetText(""); r.track:Hide(); r.fill:Hide(); r.chip:Hide()
        if lastKind then
            if last then
                local icon = EUI():ItemIcon(last.i)
                local tx = lx
                if icon then
                    r.icon:SetTexture(icon)
                    r.icon:ClearAllPoints()
                    r.icon:SetPoint("LEFT", r, "LEFT", lx, 0)
                    r.icon:Show()
                    tx = lx + 18 + 7
                end
                local at = (st.t0 or now) + (tonumber(last.at) or 0)
                r.ago:SetText(EUI():Ago(now - at))
                local name = last.n or (last.i and C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(last.i))
                    or (last.i and ("Item " .. last.i)) or ""
                r.last:ClearAllPoints()
                r.last:SetPoint("LEFT", r, "LEFT", tx, 0)
                H.Fit(r.last, name, w - tx - 10 - H.Width(r.ago) - 10, 11, 9)
            end
        else
            -- (the bar fills the row, room left for a tag)
            local bw = max(70, min(260, w - lx - 10 - (#v.tags > 0 and 110 or 0)))
            r.track:ClearAllPoints()
            r.track:SetPoint("LEFT", r, "LEFT", lx, 0)
            r.track:SetWidth(bw)
            r.track:Show()
            local frac = (best ~= 0 and e.n) and max(0, min(1, (tonumber(e.n) or 0) / best)) or 0
            if sc.high == false and e.n and best > 0 then frac = max(0, min(1, best / max(0.001, tonumber(e.n)))) end
            if frac > 0 then
                r.fill:ClearAllPoints()
                r.fill:SetPoint("LEFT", r.track, "LEFT")
                r.fill:SetWidth(max(1, bw * frac))
                r.fill:Show()
            end
            -- the tags they have that everyone sees (the judges)
            for _, t in ipairs(v.tags) do
                if st.tags and st.tags[t.id] and st.tags[t.id][e.key] then
                    r.chip:Set(t.n, RGB(t.c))
                    r.chip:ClearAllPoints()
                    r.chip:SetPoint("LEFT", r.track, "RIGHT", 12, 0)
                    r.chip:Show()
                    break
                end
            end
        end
        r:Show()
        ry = ry + LB_ROW
    end
    for i = #pick + 1, #kv.lbRows do kv.lbRows[i]:Hide() end
    kv.note:Hide()
    if #pick == 0 then
        kv.note:ClearAllPoints()
        kv.note:SetWidth(w - 80)
        kv.note:SetPoint("TOP", win.root, "TOPLEFT", x + w / 2, -(y + 80))
        kv.note:SetText("Nobody is in the event yet.")
        kv.note:Show()
    end
end

---------------------------------------------------------------------------
-- A list walked per player (a race): progress, the Time score, the gap to the leader, my splits, the route's map
---------------------------------------------------------------------------

-- The tags that take a player out of a race: given where the arrow stops and no score is set ("off the mount: out").
local function OutTags(def)
    local out = {}
    local function stack(p)
        local tagged, unpoint, scored = {}, false, false
        local q = p
        while q do
            if q.k == "pl.tag" and type(q.a and q.a[2]) == "string" then tagged[#tagged + 1] = q.a[2] end
            if q.k == "pc.unpoint" then unpoint = true end
            if q.k == "pt.set" or q.k == "pt.add" then scored = true end
            q = q.n
        end
        if unpoint and not scored then for _, t in ipairs(tagged) do out[t] = true end end
    end
    EachPiece(def, function(p, par, slot)
        if slot == "c1" or slot == "c2" or not par then stack(p) end
    end)
    for _, t in ipairs(B():Defs(def, "tags", true)) do
        local n = (t.n or ""):lower()
        if n == "out" or n == "dnf" or n:find("^eliminated") or n:find("^disqualified") then out[t.id] = true end
    end
    -- (a tag the event no longer has: its pieces may still name it, the state may still hold it)
    for tid in pairs(out) do
        if not B():Definition(def, "tags", tid) then out[tid] = nil end
    end
    return out
end

local function RaceRow(i)
    local kv = win.kv
    local r = kv.raceRows[i]
    if not r then
        r = CreateFrame("Frame", nil, kv)
        r:SetHeight(RACE_ROW)
        NewBand(r)
        r.line = r:CreateTexture(nil, "BORDER")
        r.line:SetPoint("BOTTOMLEFT")
        r.line:SetPoint("BOTTOMRIGHT")
        r.line:SetHeight(1)
        r.line:SetColorTexture(1, 1, 1, 0.035)
        r.rank = H.Text(r, "GameFontHighlight", 14, 0.85, 0.85, 0.85)
        EUI():Narrow(r.rank, 14)
        r.rank:SetPoint("LEFT", 8, 0)
        r.cls = r:CreateTexture(nil, "ARTWORK")
        r.cls:SetSize(20, 20)
        r.cls:SetPoint("LEFT", 34, 0)
        r.name = H.Text(r, "GameFontHighlight", 12)
        r.name:SetPoint("LEFT", r.cls, "RIGHT", 8, 0)
        r.segs = EUI():CreateSegments(r, 128, 6, "board")
        r.flag = r:CreateTexture(nil, "ARTWORK")
        r.flag:SetSize(12, 12)
        r.flag:SetPoint("LEFT", r.segs, "RIGHT", 4, 0)
        EUI():Glyph(r.flag, UI().ICON.flag, 1, 0.82, 0)
        r.time = H.Text(r, "GameFontHighlight", 13, 1, 1, 1)
        EUI():Narrow(r.time, 13)
        r.time:SetJustifyH("RIGHT")
        r.gap = H.Text(r, "GameFontHighlight", 12, 0.69, 0.69, 0.71)
        EUI():Narrow(r.gap, 12)
        r.gap:SetJustifyH("RIGHT")
        r.gap:SetPoint("RIGHT", -8, 0)
        r.outfs = H.Text(r, "GameFontHighlightSmall", 10.5, 1, 0.54, 0.48)
        r.outfs:SetJustifyH("RIGHT")
        r.outfs:SetPoint("RIGHT", -8, 0)
        r:EnableMouse(true)
        r:SetScript("OnEnter", NameTip)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        kv.raceRows[i] = r
    end
    return r
end

local function Signed(d)
    if d == 0 then return "0" end
    return (d > 0 and "+" or "-") .. math.abs(d) .. "s"
end

-- The racers in order: finished (by the score), racing (furthest, then who got there first), not started, out.
local function Racers(def, st, v)
    local lid, items = v.walked, (v.list and v.list.items) or {}
    local n = #items
    local pos = type(st.lists) == "table" and st.lists[lid] or {}
    local times = type(st.lt) == "table" and st.lt[lid] or {}
    local sc = v.main
    local srows = sc and type(st.scores) == "table" and st.scores[sc.id] or {}
    local outTags = OutTags(def)
    local out = {}
    for i, k in ipairs(st.entrants or {}) do
        local p = tonumber(pos[k]) or 1
        local done = max(0, min(n, p - 1))
        local fin = n > 0 and p > n
        local isOut, outName = false, nil
        if not fin then
            for tid in pairs(outTags) do
                if st.tags and st.tags[tid] and st.tags[tid][k] then
                    isOut, outName = true, B():DefinitionName(def, "tags", tid)
                end
            end
        end
        local tl = type(times[k]) == "table" and times[k] or {}
        out[#out + 1] = { key = k, i = i, done = done, fin = fin, out = isOut, outName = outName, score = srows[k],
            times = tl, last = done > 0 and tonumber(tl[done]) or nil }
    end
    local low = not sc or sc.high == false
    tsort(out, function(a, b)
        local ga = a.fin and 1 or (a.out and 4 or (a.done > 0 and 2 or 3))
        local gb = b.fin and 1 or (b.out and 4 or (b.done > 0 and 2 or 3))
        if ga ~= gb then return ga < gb end
        if ga == 1 and a.score ~= nil and b.score ~= nil and a.score ~= b.score then
            if low then return a.score < b.score end
            return a.score > b.score
        end
        if a.done ~= b.done then return a.done > b.done end
        if a.last and b.last and a.last ~= b.last then return a.last < b.last end
        return a.i < b.i
    end)
    -- the leader's time at each item (the first one there)
    local lead = {}
    for _, r in ipairs(out) do
        for j, t in pairs(r.times) do
            t = tonumber(t)
            if type(j) == "number" and t and (not lead[j] or t < lead[j]) then lead[j] = t end
        end
    end
    return out, lead, n
end
Board.Racers = function(_, def, st, v) return Racers(def, st, v or Board:Views(def, st)) end

-- The base times are counted from: the shown timer's start (the race's clock), else this stage's.
local function RaceBase(st)
    local t0 = st.t0 or 0
    for name in pairs(st.shown or {}) do
        local s = tonumber(st.tstart and st.tstart[name])
        if s then return s - t0 end
    end
    return (tonumber(st.stageAt) or t0) - t0
end

function Board:DrawRace(occ, st, def, v, x, y, w, h)
    local kv = win.kv
    local me = Me()
    local racers, lead, n = Racers(def, st, v)
    local sc = v.main
    local base = RaceBase(st)
    -- columns: # 26 | racer | route 128 + flag 16 | time 64 | gap 56
    local gapR = w - 8
    local timeR = gapR - 56
    local routeX = timeR - 64 - 16 - 128
    local hd = kv.raceHead
    hd:ClearAllPoints()
    hd:SetPoint("TOPLEFT", win.root, "TOPLEFT", x, -y)
    hd:SetWidth(w)
    local f = hd.fs
    f[1]:ClearAllPoints(); f[1]:SetPoint("LEFT", hd, "LEFT", 8, 0); f[1]:SetText("#")
    f[2]:ClearAllPoints(); f[2]:SetPoint("LEFT", hd, "LEFT", 34, 0); f[2]:SetText(PlayersWord(def, v))
    f[3]:ClearAllPoints(); f[3]:SetPoint("LEFT", hd, "LEFT", routeX, 0)
    f[4]:ClearAllPoints(); f[4]:SetPoint("RIGHT", hd, "LEFT", timeR, 0); f[4]:SetJustifyH("RIGHT")
    -- (the list's and the score's names share the room over the route and the time: smaller before they'd touch)
    H.Fit2(f[3], v.list and v.list.n or "", 120, 10.5, 9)
    H.Fit2(f[4], sc and sc.n or "", max(40, timeR - routeX - f[3]:GetWidth() - 10), 10.5, 9)
    f[5]:ClearAllPoints(); f[5]:SetPoint("RIGHT", hd, "LEFT", gapR, 0); f[5]:SetJustifyH("RIGHT"); f[5]:SetText("Gap")
    for i = 1, 5 do f[i]:Show() end
    hd:Show()
    -- my splits open under my row
    local mineAt
    for i, r in ipairs(racers) do if r.key == me then mineAt = i end end
    local mine = mineAt and racers[mineAt]
    local showSplits = mine and not mine.out and n > 0 and (mine.done > 0 or not mine.fin)
    local spH = showSplits and 50 or 0
    local rowH = RACE_ROW
    local room = h - 24 - spH
    if #racers * rowH > room then rowH = max(26, floor(room / max(1, #racers))) end
    local fit = max(1, floor(room / rowH))
    -- (more racers than rows: the first ones, me among them, and "+24 more" in the last row)
    local more = #racers > fit
    local shown = more and max(1, fit - 1) or #racers
    local pick = {}
    for i = 1, shown do pick[#pick + 1] = i end
    if mineAt and mineAt > shown then pick[#pick] = mineAt end
    -- the leader: the first finished, else the furthest on
    local leader = racers[1]
    local ry = y + 24
    for j, idx in ipairs(pick) do
        local e = racers[idx]
        local r = RaceRow(j)
        r:SetHeight(rowH)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", win.root, "TOPLEFT", x, -ry)
        r:SetWidth(w)
        r.key = e.key
        r:SetScript("OnEnter", NameTip)
        r.cls:Show()
        r.name:SetTextColor(1, 1, 1)
        r.tip = { e.fin and ("Finished" .. (e.score and (" in " .. ScoreText(def, sc and sc.id, e.score)) or ""))
            or (e.out and ((e.outName or "Out") .. " of the race") or (e.done .. " of " .. n .. " done")) }
        local isMe = ns.Util.IsMe(e.key)
        YouBand(r, isMe)
        local rank = (e.out or (e.done == 0 and not e.fin)) and "–" or tostring(idx)
        r.rank:SetText(rank)
        local mc = MEDAL_TEXT[idx]
        if mc and rank ~= "–" then r.rank:SetTextColor(mc[1], mc[2], mc[3]) else r.rank:SetTextColor(0.85, 0.85, 0.85) end
        H.SetClass(r.cls, e.key, e.out)
        H.Fit(r.name, H.Name(e.key), routeX - 34 - 20 - 8 - 8, 12, 10)
        r.segs:ClearAllPoints()
        r.segs:SetPoint("LEFT", r, "LEFT", routeX, 0)
        r.segs:Set(n, e.done, e.fin)
        r.segs:SetAlpha(e.out and 0.55 or 1)
        r.flag:SetShown(e.fin)
        r.time:ClearAllPoints()
        r.time:SetPoint("RIGHT", r, "LEFT", timeR, 0)
        r.outfs:SetText("")
        r.gap:SetText("")
        if e.fin and e.score ~= nil then
            r.time:SetText(ScoreText(def, sc and sc.id, e.score))
            r.time:SetTextColor(1, 1, 1)
            if leader ~= e and leader.fin and leader.score ~= nil then
                r.gap:SetText("+" .. H.Clock(math.abs(e.score - leader.score)))
            end
        elseif e.last then
            r.time:SetText(H.Clock(e.last - base))
            r.time:SetTextColor(0.55, 0.55, 0.58)
            local lt = lead[e.done]
            if lt and e.last > lt then r.gap:SetText("+" .. H.Clock(e.last - lt)) end
        else
            r.time:SetText("")
        end
        if e.out then
            r.time:SetText("")
            r.gap:SetText("")
            r.outfs:SetText((e.outName or "out"):lower())
        end
        r:Show()
        ry = ry + rowH
        -- my splits: each place's time and the gap to the leader's there; the next one and how far it is
        if isMe and showSplits then
            local sp = kv.splits
            sp:ClearAllPoints()
            sp:SetPoint("TOPLEFT", win.root, "TOPLEFT", x, -ry)
            sp:SetWidth(w)
            local first = max(1, min(n - 9, e.done - 7))
            local last = min(n, first + 9)
            local cells = last - first + 1
            local cw = (w - 34 - 8) / max(1, cells)
            local _, yards = nil, nil
            if not e.fin then
                local d = DemoKinds and DemoKinds(occ)
                if d then
                    yards = d.point and d.point[2]
                elseif occ ~= "practice" then
                    local ok, pid, yd = pcall(L().MyPoint, L(), occ)
                    if ok then yards = yd end
                end
            end
            for c = 1, max(cells, #sp.cells) do
                local cell = sp.cells[c]
                if c <= cells and not cell then
                    cell = {}
                    cell.a = H.Text(sp, "GameFontHighlightSmall", 9.5, 0.47, 0.47, 0.49)
                    cell.b = H.Text(sp, "GameFontHighlight", 12, 0.91, 0.91, 0.91)
                    EUI():Narrow(cell.b, 12)
                    cell.c = H.Text(sp, "GameFontHighlight", 11, 0.62, 0.62, 0.62)
                    EUI():Narrow(cell.c, 11)
                    for _, t in ipairs({ cell.a, cell.b, cell.c }) do t:SetJustifyH("CENTER") end
                    sp.cells[c] = cell
                end
                if cell then
                    local show = c <= cells
                    for _, t in ipairs({ cell.a, cell.b, cell.c }) do t:SetShown(show) end
                    if show then
                        local j = first + c - 1
                        local cx = 34 + (c - 0.5) * cw
                        cell.a:ClearAllPoints(); cell.a:SetPoint("TOP", sp, "TOPLEFT", cx, -5)
                        cell.b:ClearAllPoints(); cell.b:SetPoint("TOP", sp, "TOPLEFT", cx, -17)
                        cell.c:ClearAllPoints(); cell.c:SetPoint("TOP", sp, "TOPLEFT", cx, -32)
                        cell.a:SetText(tostring(j))
                        local t = tonumber(e.times[j])
                        if j <= e.done and t then
                            cell.a:SetTextColor(0.47, 0.47, 0.49)
                            cell.b:SetText(H.Clock(t - base))
                            cell.b:SetTextColor(0.91, 0.91, 0.91)
                            local d = lead[j] and floor(t - lead[j] + 0.5) or 0
                            cell.c:SetText(Signed(d))
                            if d > 0 then cell.c:SetTextColor(1, 0.54, 0.48)
                            elseif d < 0 then cell.c:SetTextColor(0.44, 0.88, 0.54)
                            else cell.c:SetTextColor(0.62, 0.62, 0.62) end
                        elseif j == e.done + 1 and not e.fin then
                            cell.a:SetTextColor(EUI().TEAL_LT[1], EUI().TEAL_LT[2], EUI().TEAL_LT[3])
                            cell.b:SetText("next")
                            cell.b:SetTextColor(EUI().TEAL_LT[1], EUI().TEAL_LT[2], EUI().TEAL_LT[3])
                            cell.c:SetText(yards and (floor(yards + 0.5) .. " yd") or "")
                            cell.c:SetTextColor(EUI().TEAL_LT[1], EUI().TEAL_LT[2], EUI().TEAL_LT[3])
                        else
                            cell.a:SetTextColor(0.35, 0.35, 0.37)
                            cell.b:SetText("")
                            cell.c:SetText("")
                        end
                    end
                end
            end
            sp:Show()
            ry = ry + spH
        end
    end
    if not (showSplits and mine) then kv.splits:Hide() end
    local used = #pick
    if more then
        -- the rest: how many, and who on hover
        local inPick, rest = {}, {}
        for _, idx in ipairs(pick) do inPick[idx] = true end
        for i, e in ipairs(racers) do if not inPick[i] then rest[#rest + 1] = e.key end end
        used = used + 1
        local r = RaceRow(used)
        r:SetHeight(rowH)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", win.root, "TOPLEFT", x, -ry)
        r:SetWidth(w)
        YouBand(r, false)
        r.key, r.tip = nil, nil
        r.rank:SetText("")
        r.cls:Hide()
        r.name:SetText("+" .. #rest .. " more")
        r.name:SetTextColor(GREY[1], GREY[2], GREY[3])
        H.Sized(r.name, 11)
        r.segs:Set(0, 0, false)
        r.segs:SetAlpha(0)
        r.flag:Hide()
        r.time:SetText("")
        r.gap:SetText("")
        r.outfs:SetText("")
        r:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            for i, k in ipairs(rest) do
                if i > 30 then GameTooltip:AddLine("and " .. (#rest - 30) .. " more", 0.62, 0.62, 0.62) break end
                GameTooltip:AddLine(H.Name(k))
            end
            GameTooltip:Show()
        end)
        r:Show()
    end
    for i = used + 1, #kv.raceRows do kv.raceRows[i]:Hide() end
    return racers, lead
end

-- The route on the map: its places in order joined by a dashed line, the start's flag, numbered places, the racers'
-- dots on the leg they're on (where the event points them; mine where I am).
function Board:DrawRouteMap(occ, st, def, v, racers, lead, x, y, w, h)
    local kv = win.kv
    local m = kv.map
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", win.root, "TOPLEFT", x, -y)
    m:SetSize2(w, h)
    local items = v.list and v.list.items or {}
    local start = StartPlace(def)
    local pts = {}
    if start and items[1] ~= start then pts[1] = { pid = start, start = true } end
    for i, pid in ipairs(items) do pts[#pts + 1] = { pid = pid, item = i } end
    local places = {}
    for _, q in ipairs(pts) do
        local p = B():Definition(def, "places", q.pid)
        q.p = p
        if p and tonumber(p.map) then places[#places + 1] = p end
    end
    local map = MapOfPlaces(places)
    m:SetMap(map)
    local fitPts = {}
    for _, q in ipairs(pts) do
        if q.p and tonumber(q.p.map) == map then fitPts[#fitPts + 1] = { tonumber(q.p.x), tonumber(q.p.y), 60 } end
    end
    m:Fit(fitPts, 0.25)
    m:Done(0)
    m:ShowZone(true)
    m:ShowMe(true)
    kv.secret:Hide()
    local function at(q)
        if not (q and q.p and tonumber(q.p.map) == map) then return nil end
        return m:P(tonumber(q.p.x), tonumber(q.p.y))
    end
    -- the path: a dark line under a dashed teal one
    local nl = 0
    local function line(x1, y1, x2, y2, th, r, g, b, a)
        nl = nl + 1
        local l = RouteLine(nl)
        l:SetStartPoint("TOPLEFT", m.canvas, x1, -y1)
        l:SetEndPoint("TOPLEFT", m.canvas, x2, -y2)
        l:SetThickness(th)
        l:SetColorTexture(r, g, b, a)
        l:Show()
    end
    local legs = {}
    for i = 1, #pts - 1 do
        local x1, y1 = at(pts[i])
        local x2, y2 = at(pts[i + 1])
        if x1 and x2 then legs[#legs + 1] = { x1, y1, x2, y2, i } end
    end
    for _, g in ipairs(legs) do line(g[1], g[2], g[3], g[4], 5, 0, 0, 0, 0.55) end
    for _, g in ipairs(legs) do
        local dx, dy = g[3] - g[1], g[4] - g[2]
        local len = math.sqrt(dx * dx + dy * dy)
        local s = 0
        while s < len do
            local e = min(len, s + 6)
            line(g[1] + dx * s / len, g[2] + dy * s / len, g[1] + dx * e / len, g[2] + dy * e / len, 2, TEAL[1], TEAL[2], TEAL[3], 1)
            s = s + 10
        end
    end
    for i = nl + 1, #kv.route.lines do kv.route.lines[i]:Hide() end
    -- the places: the start's flag (also the finish of a loop), numbers for the rest; my next one glows
    local me = Me()
    local myNext
    for _, r in ipairs(racers or {}) do
        if r.key == me and not r.fin and not r.out then myNext = r.done + 1 end
    end
    -- the start's flag (a loop ends there too: no second mark); without a known start, the finish is the flag
    local nc = 0
    local loop = start ~= nil and items[#items] == start
    -- (a route that comes back to a place: one mark there, its card says each time it's on the route)
    local seen = {}
    for _, q in ipairs(pts) do
        local px, py = at(q)
        local dup = loop and q.item == #items and pts[1].start
        local again = seen[q.pid]
        if px and again and not dup then
            again.visits = again.visits or {}
            again.visits[#again.visits + 1] = q.item
            again.sub = (again.base or "") .. (#again.visits > 0 and ("; again " .. table.concat(again.visits, ", ")) or "")
            if q.item == myNext then again.glow:Show() end
            dup = true
        end
        if px and not dup then
            nc = nc + 1
            local c = Checkpoint(nc)
            c:ClearAllPoints()
            c:SetPoint("CENTER", m.canvas, "TOPLEFT", px, -py)
            local isStart = q.start or (start and q.pid == start and q.item == 1)
            local isFinish = not start and q.item == #items
            local flag = isStart or isFinish
            if flag then
                c.disc:SetSize(19, 19)
                c.edge:SetSize(22, 22)
                c.disc:SetVertexColor(1, 0.82, 0, 1)
                c.fs:SetText("")
                c.flag:Show()
            else
                c.disc:SetSize(17, 17)
                c.edge:SetSize(20, 20)
                c.disc:SetVertexColor(TEAL[1], TEAL[2], TEAL[3], 1)
                c.fs:SetText(tostring(q.item))
                c.fs:SetTextColor(0.012, 0.165, 0.2)
                c.flag:Hide()
            end
            c.glow:SetShown(q.item ~= nil and q.item == myNext)
            c.visits = nil
            seen[q.pid] = c
            c.name = q.p and q.p.n
            c.place = q.p
            local pid = q.pid
            c.click = q.p and function() EUI():ShowTheWay(occ, pid, def) end or nil
            c.sub = (isStart and (loop and "The start and the finish" or "The start")) or (isFinish and "The finish")
                or (q.item and (v.list.n .. " " .. q.item .. " of " .. #items))
            c.base = c.sub
            c:Show()
        end
    end
    for i = nc + 1, #kv.route.cps do kv.route.cps[i]:Hide() end
    -- the racers on their leg: how far along by the time since their last place against the leader's for that leg
    local now = RunNow(occ, st) - (st.t0 or 0)
    local nd = 0
    local myPos
    local S = ns.EventSensors
    if S and S.MyPos and occ ~= "practice" and not (DemoKinds and DemoKinds(occ)) then
        local ok, p = pcall(S.MyPos, S)
        if ok and p and tonumber(p.map) == map then myPos = p end
    end
    local function leg(r)
        local a = (start and pts[1].start) and (r.done + 1) or r.done
        local p1, p2 = pts[a], pts[a + 1]
        if not (p1 and p2) then return nil end
        local x1, y1 = at(p1)
        local x2, y2 = at(p2)
        if not (x1 and x2) then return nil end
        return x1, y1, x2, y2
    end
    for i, r in ipairs(racers or {}) do
        if not r.fin and not r.out and nd < 40 then
            local x1, y1, x2, y2 = leg(r)
            if x1 then
                local px, py
                if r.key == me and myPos then
                    px, py = m:P(myPos.x, myPos.y)
                else
                    local frac = 0.5
                    local since = r.last and (now - r.last) or (now - RaceBase(st))
                    local want = (lead[r.done + 1] and (lead[r.done] or RaceBase(st))) and (lead[r.done + 1] - (lead[r.done] or RaceBase(st))) or nil
                    if want and want > 0 and since then frac = max(0.12, min(0.88, since / want)) end
                    -- (side by side, not on top of each other)
                    local dx, dy = x2 - x1, y2 - y1
                    local len = math.sqrt(dx * dx + dy * dy)
                    local off = ((i % 3) - 1) * 4
                    px = x1 + dx * frac + (len > 0 and (-dy / len) * off or 0)
                    py = y1 + dy * frac + (len > 0 and (dx / len) * off or 0)
                end
                if px and px >= 0 and py >= 0 and px <= w and py <= h then
                    nd = nd + 1
                    local d = RouteDot(nd)
                    d:ClearAllPoints()
                    d:SetPoint("CENTER", m.canvas, "TOPLEFT", px, -py)
                    local cr, cg, cb = UI():ClassColor(EUI():ClassOf(r.key))
                    d.disc:SetVertexColor(cr or 1, cg or 1, cb or 1, 1)
                    local mine = ns.Util.IsMe(r.key)
                    d.you:SetShown(mine)
                    d.glow:SetShown(mine)
                    d.key, d.tip = r.key, { r.done .. " of " .. #items .. " done" }
                    d:Show()
                end
            end
        end
    end
    for i = nd + 1, #kv.route.dots do kv.route.dots[i]:Hide() end
    m:Show()
end

---------------------------------------------------------------------------
-- The rail of these views: asking now, time left, prizes, the last ask's result, moments
---------------------------------------------------------------------------

local function RailText(rail, i, size, r, g, b)
    rail.texts = rail.texts or {}
    local fs = rail.texts[i]
    if not fs then
        fs = H.Text(rail, "GameFontHighlightSmall", size or 10, r or GREY[1], g or GREY[2], b or GREY[3])
        rail.texts[i] = fs
    end
    H.Sized(fs, size or 10)
    fs:SetTextColor(r or GREY[1], g or GREY[2], b or GREY[3])
    fs:SetWordWrap(false)
    fs:SetJustifyH("LEFT")
    fs:ClearAllPoints()
    fs:Show()
    return fs
end

local function PrizeRow(rail, i)
    local r = rail.prizes[i]
    if not r then
        r = CreateFrame("Frame", nil, rail)
        r:SetHeight(26)
        r.badge = EUI():CreateBadge(r, 20)
        r.badge:SetPoint("LEFT", -1, 0)
        r.name = H.Text(r, "GameFontHighlight", 11.5, 0.88, 0.88, 0.88)
        r.name:SetPoint("LEFT", r.badge, "RIGHT", 6, 0)
        r.how = H.Text(r, "GameFontHighlightSmall", 10.5, GREY[1], GREY[2], GREY[3])
        r.how:SetJustifyH("RIGHT")
        r.how:SetPoint("RIGHT", 0, 0)
        rail.prizes[i] = r
    end
    return r
end

local function KMoment(rail, i)
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
        r.fs:SetPoint("TOPLEFT", 24, 0)
        r.t = H.Text(r, "GameFontHighlightSmall", 10, 0.44, 0.44, 0.46)
        r.t:SetPoint("TOPLEFT", r.fs, "BOTTOMLEFT", 0, -2)
        rail.moms[i] = r
    end
    return r
end

-- The ask that closed last (in this stage, the last ten minutes), and its tally: aid, qa, tally.
local function LastClosed(occ, st, def)
    local best, bestAid
    local now = H.Now(occ)
    for aid, q in pairs(type(st.qa) == "table" and st.qa or {}) do
        if type(q) == "table" and not q.open and tonumber(q.closed) and now - q.closed < 600 then
            if not best or q.closed > best.closed then best, bestAid = q, aid end
        end
    end
    if not best then return nil end
    -- (counted as the run counts them)
    local r = E():Reader(def, st)
    local ok, tally = pcall(r.Tally, r, bestAid)
    return bestAid, best, ok and tally or {}
end
Board.LastClosed = function(_, occ, st, def) return LastClosed(occ, st, def) end

-- An answer as words: a player's name, yes / no, a choice, a number.
function H.AnswerText(v, colored)
    if type(v) == "boolean" then return v and "Yes" or "No" end
    if type(v) == "string" and v:find("%-") and EUI():ClassOf(v) then return colored and H.Name(v) or H.Plain(v) end
    if type(v) == "string" and v:find("%-Practice$") then return colored and H.Name(v) or H.Plain(v) end
    if type(v) == "table" and v.q then return tostring(v.q) end
    return tostring(v)
end

function Board:DrawKindsRail(occ, st, def, v, x, y, w, h)
    local rail = win.kv.rail
    rail:ClearAllPoints()
    rail:SetPoint("TOPLEFT", win.root, "TOPLEFT", x, -y)
    rail:SetSize(w, h)
    local nt, ntime, nprize, nmom = 0, 0, 0, 0
    for _, fs in ipairs(rail.texts or {}) do fs:Hide() end
    rail.askHead, rail.askEnds = nil, nil
    local cy = 0
    local function head(text)
        nt = nt + 1
        local fs = RailText(rail, nt, 10, GREY[1], GREY[2], GREY[3])
        fs:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -cy)
        H.Fit(fs, text, w, 10, 9)
        cy = cy + 16 + 5
    end
    local now = H.Now(occ)
    -- asking now (the newest open ask): its question, how many answered
    local open, openAid
    for aid, q in pairs(type(st.qa) == "table" and st.qa or {}) do
        if type(q) == "table" and q.open and (not open or (q.id or 0) > (open.id or 0)) then open, openAid = q, aid end
    end
    if open then
        local who, ans = 0, 0
        for _ in pairs(open.who or {}) do who = who + 1 end
        for _ in pairs(open.ans or {}) do ans = ans + 1 end
        local ad = B():Definition(def, "asks", openAid)
        local left = max(0, (tonumber(open.ends) or now) - RunNow(occ, st))
        -- (a quiz question: which one of how many)
        local prefix = "ASKING · "
        local item = type(open.item) == "table" and open.item
        local l = item and type(def.lists) == "table" and def.lists[item.ql]
        if l and type(l.items) == "table" then prefix = "QUESTION " .. (item.qi or 1) .. " OF " .. #l.items .. " · " end
        head(prefix .. H.Clock(left))
        rail.askHead, rail.askEnds, rail.askPrefix = rail.texts[nt], tonumber(open.ends), prefix
        nt = nt + 1
        local q = RailText(rail, nt, 12, 1, 1, 1)
        q:SetWordWrap(true)
        q:SetWidth(w)
        q:SetText(tostring(open.q or (ad and ad.q) or (ad and ad.n) or ""))
        q:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -cy)
        cy = cy + (q:GetStringHeight() or 15) + 3
        nt = nt + 1
        local s = RailText(rail, nt, 10.5, GREY[1], GREY[2], GREY[3])
        s:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -cy)
        s:SetText(ans .. " of " .. who .. " answered" .. ((ad and ad.secret) and " · counts stay hidden" or ""))
        cy = cy + 14 + 10
    end
    -- time left on the shown timers (two at most)
    local timers = H.ShownTimers(occ, st)
    for i = 1, min(2, #timers) do
        local t = timers[i]
        if i == 1 then head("TIME LEFT") end
        ntime = ntime + 1
        local c = rail.times[ntime]
        if not c then
            c = EUI():CreateTimeLeft(rail, w)
            rail.times[ntime] = c
        end
        c:SetWidth(w)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -cy)
        c.timer = t.n
        c:Set(t.left, t.total, t.n .. " ends " .. date("%H:%M", t.ends), ThenOf(def, st, t.n))
        c:Show()
        cy = cy + c:GetHeight() + 10
    end
    for i = ntime + 1, #rail.times do rail.times[i]:Hide() end
    -- the prizes (when there is room for them and two moments)
    local prizes = PrizeHow(def)
    local moms = {}
    for _, m in ipairs(st.moments or {}) do if type(m) == "table" and m.text then moms[#moms + 1] = m end end
    tsort(moms, function(p, q) return (p.at or 0) > (q.at or 0) end)
    local closedAid, closed, tally = LastClosed(occ, st, def)
    local resH = closed and (21 + 18 + min(3, #tally) * 18 + 10) or 0
    local prizeH = #prizes > 0 and (21 + #prizes * 30 + 10) or 0
    local momMin = #moms > 0 and (21 + 2 * 38) or 0
    if cy + prizeH + resH + momMin > h then
        -- (the ask's result goes first: the prizes are on the event's page too)
        if cy + prizeH + momMin <= h then resH = 0 else prizeH = 0 end
    end
    local function drawPrizes()
    if prizeH > 0 then
        head("PRIZES")
        for _, e in ipairs(prizes) do
            nprize = nprize + 1
            local r = PrizeRow(rail, nprize)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -cy)
            r:SetWidth(w)
            r.badge:SetBadge({ n = e.b.n, i = e.b.i, f = e.b.f, ti = e.b.ti })
            -- (given already: who has it, instead of how it's won)
            local who = {}
            for _, a in ipairs(type(st.awards) == "table" and st.awards or {}) do
                if type(a) == "table" and a.b == e.id and type(a.p) == "string" then who[#who + 1] = a.p end
            end
            local how, place = e.how, e.place
            if #who > 0 then
                how = H.Name(who[1]) .. (#who > 1 and ("|cff9e9e9e +" .. (#who - 1) .. "|r") or "")
                place = false
            end
            r.how:SetText(how or "")
            if place then
                EUI():Narrow(r.how, 13)
                r.how:SetTextColor(1, 0.88, 0.54)
            else
                r.how:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10.5, "")
                r.how:SetTextColor(GREY[1], GREY[2], GREY[3])
            end
            -- name and how on one line; on two when they don't both fit
            local hw = how and (H.Width(r.how) + 8) or 0
            r.name:ClearAllPoints()
            r.how:ClearAllPoints()
            H.Sized(r.name, 11.5)
            r.name:SetText(e.b.n or "Badge")
            local rowH = 26
            if H.Width(r.name) + hw <= w - 28 - 6 then
                r.name:SetPoint("LEFT", r.badge, "RIGHT", 6, 0)
                r.how:SetPoint("RIGHT", r, "RIGHT", 0, 0)
                r.how:SetJustifyH("RIGHT")
            else
                rowH = 34
                H.Fit(r.name, e.b.n or "Badge", w - 28 - 6, 11.5, 9.5)
                r.name:SetPoint("BOTTOMLEFT", r.badge, "RIGHT", 6, 1)
                r.how:SetPoint("TOPLEFT", r.badge, "RIGHT", 6, -1)
                r.how:SetJustifyH("LEFT")
                H.Fit(r.how, how or "", w - 28 - 6, place and 13 or 10.5, 9)
            end
            r:SetHeight(rowH)
            r:Show()
            cy = cy + rowH
        end
        cy = cy + 10
    end
    end
    -- the last ask's result: the most picked answers
    local function drawResult()
    if resH > 0 then
        local ad = B():Definition(def, "asks", closedAid)
        local item = type(closed.item) == "table" and closed.item
        local l = item and type(def.lists) == "table" and def.lists[item.ql]
        local it = l and type(l.items) == "table" and l.items[item.qi]
        local right = type(it) == "table" and type(it.a) == "table" and it.a or nil
        local function ok(v)
            for _, a in ipairs(right or {}) do
                if tostring(a):lower():gsub("%s+", "") == tostring(v):lower():gsub("%s+", "") then return true end
            end
            return false
        end
        local function label(v)
            if right and ok(v) then return "|cff9ff0b0" .. H.AnswerText(v) .. "|r" end
            return H.AnswerText(v, true)
        end
        head(item and ("QUESTION " .. (item.qi or "?") .. " · CLOSED") or (((ad and ad.n) or "Ask"):upper() .. " · CLOSED"))
        local total = 0
        for _, t in ipairs(tally) do total = total + t.n end
        nt = nt + 1
        local top = RailText(rail, nt, 11.5, 1, 1, 1)
        top:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -cy)
        if tally[1] then
            H.Fit(top, label(tally[1].v) .. "|cff9e9e9e · " .. tally[1].n .. " of " .. total .. "|r", w, 11.5, 9.5)
        else
            top:SetText("|cff9e9e9eNobody answered|r")
        end
        cy = cy + 18
        for i = 2, min(4, #tally) do
            nt = nt + 1
            local fs = RailText(rail, nt, 10.5, 0.82, 0.82, 0.82)
            fs:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -cy)
            H.Fit(fs, label(tally[i].v) .. "|cff9e9e9e · " .. tally[i].n .. "|r", w, 10.5, 9)
            cy = cy + 18
        end
        cy = cy + 10
    end
    end
    -- moments, newest first, as many as there is room for (above `limit`)
    local function drawMoments(limit)
    if #moms > 0 or (st.phase == "live" and cy < limit - 60) then
        head("MOMENTS")
        local keys = st.entrants or {}
        for _, m in ipairs(moms) do
            local r = KMoment(rail, nmom + 1)
            r:SetWidth(w)
            r.fs:SetWidth(w - 24)
            r.icon:SetTexture(m.i or (def and def.icon) or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.fs:SetTextColor(0.82, 0.82, 0.82)
            r.fs:SetText(H.ColorNames(m.text, keys))
            r.t:SetText(m.at and date("%H:%M", m.at) or "")
            local hgt = (r.fs:GetStringHeight() or 15) + 2 + 12
            if cy + hgt > limit then break end
            nmom = nmom + 1
            r:SetHeight(hgt)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -cy)
            r:Show()
            cy = cy + hgt + 8
        end
        if #moms == 0 then
            local r = KMoment(rail, 1)
            nmom = 1
            r:SetWidth(w)
            r.fs:SetWidth(w - 24)
            r.icon:SetTexture(def and def.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.fs:SetText("Its moments show up here as they happen.")
            r.fs:SetTextColor(0.55, 0.55, 0.57)
            r.t:SetText("")
            r:SetHeight((r.fs:GetStringHeight() or 30) + 4)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -cy)
            r:Show()
            cy = cy + r:GetHeight() + 8
        end
    end
    end
    -- the order: the tag columns' rail (hide and seek) tells what happened before what's to win; the others put the
    -- prizes first (a score chase is about them), the moments last to fill the room
    if v.layout == "columns" then
        drawMoments(h - prizeH - resH)
        drawPrizes()
        drawResult()
    else
        drawPrizes()
        drawResult()
        drawMoments(h)
    end
    for i = nprize + 1, #rail.prizes do rail.prizes[i]:Hide() end
    for i = nmom + 1, #rail.moms do rail.moms[i]:Hide() end
    rail:Show()
end

-- The time left cards and the asking clock tick (once a second).
TickKinds = function(occ, st)
    local kv = win.kv
    if not (kv and kv:IsShown()) then return end
    local ah = kv.rail.askHead
    if ah and ah:IsShown() and kv.rail.askEnds then
        ah:SetText((kv.rail.askPrefix or "ASKING · ") .. H.Clock(max(0, kv.rail.askEnds - RunNow(occ, st))))
    end
    local byName = {}
    for _, t in ipairs(H.ShownTimers(occ, st)) do byName[t.n] = t end
    for _, c in ipairs(kv.rail.times) do
        local t = c:IsShown() and byName[c.timer]
        if t then c:Set(t.left, t.total, c.l:GetText(), c.r:GetText() ~= "" and c.r:GetText() or nil) end
    end
end

-- Draws an event without Matches from what it has.
function Board:DrawKinds(occ, st, def, v, top, height)
    local kv = KV()
    kv:Show()
    for _, c in ipairs(kv.cols) do c:Hide() end
    for _, r in ipairs(kv.lbRows) do r:Hide() end
    for _, r in ipairs(kv.raceRows) do r:Hide() end
    for _, t in ipairs(kv.tabs) do t:Hide() end
    kv.lbHead:Hide()
    kv.raceHead:Hide()
    kv.splits:Hide()
    kv.note:Hide()
    kv.map:Hide()
    local x = BR_X
    local railX = CW - 12 - RAIL_W
    local br = win.br
    br:Hide()
    if v.layout == "race" then
        local withMap = v.list and v.list.kind == "place" and #v.places > 0
        local tw = withMap and 452 or MAIN_W
        local racers, lead = self:DrawRace(occ, st, def, v, x, top, tw, height)
        if withMap then
            local mx = x + tw + EUI().GAP
            local mw = CW - 12 - mx
            local mh = 228
            self:DrawRouteMap(occ, st, def, v, racers, lead, mx, top, mw, mh)
            self:DrawKindsRail(occ, st, def, v, mx, top + mh + EUI().GAP, mw, height - mh - EUI().GAP)
        else
            self:DrawKindsRail(occ, st, def, v, railX, top, RAIL_W, height)
        end
        return
    end
    -- the map of the places on top (columns, scores, the sign-up)
    local y, h = top, height
    if #v.places > 0 then
        local mh = MAP_H
        if v.layout == "columns" then
            -- (smaller when the columns need the room)
            local most = 0
            for _, t in ipairs(v.tags) do
                local n = #SetKeys(st.tags and st.tags[t.id], st.entrants)
                if n > most then most = n end
            end
            local need = 28 + most * COL_ROW + 4
            mh = max(MAP_MIN, min(MAP_H, height - EUI().GAP - need))
        elseif v.layout == "scores" then
            mh = MAP_MIN
        elseif v.layout == "players" then
            -- (smaller when the names need the room)
            local n = #H.SignedUp(st)
            if n == 0 then n = #(st.entrants or {}) end
            local need = 20 + ceil(n / 4) * 22 + 30
            mh = max(MAP_MIN, min(MAP_H, height - EUI().GAP - need))
        end
        DrawPlacesMap(occ, def, st, v, x, top, MAIN_W, mh)
        y, h = top + mh + EUI().GAP, height - mh - EUI().GAP
    end
    if v.layout == "columns" then
        self:DrawColumns(st, def, v, x, y, MAIN_W, h)
    elseif v.layout == "scores" then
        self:DrawScores(occ, st, def, v, x, y, MAIN_W, h)
    else
        -- who signed up (part 1's grid), in the room under the map
        br:ClearAllPoints()
        br:SetPoint("TOPLEFT", win.root, "TOPLEFT", BR_X, -y)
        br:SetHeight(h)
        br:Show()
        self:DrawPlayers(st, def, h, v.signup and "It starts when the sign-up closes." or nil)
    end
    self:DrawKindsRail(occ, st, def, v, railX, top, RAIL_W, height)
end

-- The header's chip for an event without Matches: { text, rgb (my tag's dot) | nil (my class circle), tip }.
function Board:MyChip(occ, st, def)
    local me = Me()
    if not H.Contains(st.entrants, me) then return nil end
    local v = self:Views(def, st)
    -- a race or a score chase: my place
    if (v.layout == "race" or v.layout == "scores") and v.main then
        local place
        if v.layout == "race" then
            local racers = Racers(def, st, v)
            for i, r in ipairs(racers) do
                if r.key == me and not r.out and (r.done > 0 or r.fin) then place = i end
            end
        else
            place = PlaceOf(def, st, v.main.id, me)
        end
        if place then
            return { text = "You're " .. H.Ordinal(place), tip = { "You're " .. H.Ordinal(place),
                (v.layout == "race" and ("On the " .. (v.list and v.list.n or "list"))) or ("By " .. v.main.n) } }
        end
    end
    -- my tag (everyone's, then one only I see)
    local mine
    for _, t in ipairs(v.tags) do
        if not mine and st.tags and st.tags[t.id] and st.tags[t.id][me] then mine = t end
    end
    if not mine then
        for _, t in ipairs(B():Defs(def, "tags", true)) do
            if not mine and t.shown == "self" and st.tags and st.tags[t.id] and st.tags[t.id][me] then mine = t end
        end
    end
    if mine then
        return { text = "You: " .. mine.n, rgb = RGB(mine.c), tip = { "You: " .. mine.n,
            mine.shown == "self" and "Only you see this." or "Everyone sees who has it." } }
    end
    return nil
end

---------------------------------------------------------------------------
-- Demo mode's part 2 boards (never sent: the engine runs them here with no output at all)
---------------------------------------------------------------------------

Board.DEMO = {
    { key = "kdemo-hide", ex = "hide", label = "Hide and seek" },
    { key = "kdemo-race", ex = "race", label = "Mount race" },
    { key = "kdemo-fish", ex = "fish", label = "Fishing derby" },
}
local demoRuns = {}

-- (a number from a name: the same demo every time, no random)
local function Hash(s, n)
    local h = 7
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 100003 end
    return h % n
end

local DEMO_FISH = { { 27422, "Barbed Gill Trout" }, { 27425, "Spotted Feltail" }, { 27438, "Golden Darter" },
    { 27439, "Furious Crawdad" }, { 27437, "Icefin Bluefish" }, { 27429, "Zangarian Sporefish" } }

local function BuildDemo(e)
    local D = ns.Demo
    local def = B():Example(e.ex)
    if not (def and D and D.GetMembers) then return nil end
    local names = {}
    for _, k in ipairs(D:GetMembers()) do
        if #names >= 11 then break end
        names[#names + 1] = k
    end
    local me = Me() or "Me-Realm"
    tinsert(names, 3, me)
    local clock = ServerNow() - 3600
    local run = E():New(def, { id = e.key, host = names[1], signups = names, now = function() return clock end,
        nameOf = function(k) return EUI():Plain(k) end, out = {} })
    run:Start()
    local function tick(sec)
        clock = clock + sec
        run:Tick()
    end
    local st = run.st
    if e.ex == "hide" then
        -- the hide: me among the hiders, one seeker; then seeking, three found
        tick(5)
        local seekers = SetKeys(st.tags.tg2, st.entrants)
        if st.tags.tg2 and st.tags.tg2[me] then
            local other = names[5]
            st.tags.tg2[me], st.tags.tg1[me] = nil, true
            st.tags.tg2[other], st.tags.tg1[other] = true, nil
            seekers = { other }
        end
        for _ = 1, 4 do tick(46) end
        local seeker = seekers[1]
        local found, lastFound = 0, nil
        for _, k in ipairs(SetKeys(st.tags.tg1, st.entrants)) do
            if k ~= me and found < 3 then
                tick(130 + Hash(k, 90))
                run:Touch(seeker, k, "click")
                found, lastFound = found + 1, k
            end
        end
        tick(120)
        e.tell = { "Go back to the play area", (lastFound and EUI():Plain(lastFound) or "Someone") .. " was found" }
        e.point = { "pc1", 45, 1.25 }
    elseif e.ex == "race" then
        -- the race: everyone on the Route at their own pace, two finished, me on the last leg, one out
        run:CloseSignup("b1")
        -- (the countdown, then "Go!": the Race timer starts)
        for _ = 1, 40 do
            if st.tstart and st.tstart.Race then break end
            tick(1)
        end
        local items = def.lists.ls1.items
        local start, stop = clock, clock + 440
        local out = names[7]
        local events = {}
        for i, k in ipairs(st.entrants) do
            local t = start
            for j = 1, #items do
                t = t + 47 + 3 * i + Hash(k .. j, 7)
                if t > stop or (k == out and j > 3) then break end
                events[#events + 1] = { t, k, j }
            end
        end
        events[#events + 1] = { start + 230, out, 0 }
        tsort(events, function(x, y) return x[1] < y[1] end)
        for _, ev in ipairs(events) do
            clock = ev[1]
            if ev[3] == 0 then
                run:Happen(ev[2], "dismount", {})
            else
                run:Place(ev[2], items[ev[3]], true)
                run:Place(ev[2], items[ev[3]], false)
            end
        end
        clock = stop
        run:Tick()
        e.tell = { "3rd at " .. B():DefinitionName(def, "places", items[6] or items[1]) .. ", 0:09 behind " .. EUI():Plain(names[2]) }
        e.point = { items[(st.lists.ls1 and st.lists.ls1[me]) or 1], 303, -0.24 }
    elseif e.ex == "fish" then
        tick(5)
        local catches = {}
        for i, k in ipairs(st.entrants) do catches[k] = 30 - i * 2 - Hash(k, 4) end
        catches[me] = 24
        local fishers = {}
        for _, k in ipairs(st.entrants) do fishers[#fishers + 1] = k end
        for round = 1, 32 do
            for j, k in ipairs(fishers) do
                if (catches[k] or 0) >= round then
                    clock = clock + 2
                    local f = DEMO_FISH[1 + Hash(k .. round, #DEMO_FISH)]
                    if round == 12 and j == 4 then f = { 27388, "Mr. Pinchy" } end
                    run:Happen(k, "fish", { item = f[1], name = f[2], count = 1 })
                end
            end
            clock = clock + 18
            run:Tick()
        end
        tick(30)
        e.tell = { EUI():Plain(names[2]) .. " leads with " .. tostring((st.scores.sc1 or {})[names[2]] or 0) .. " fish" }
    end
    -- the clock that ran the demo is now: what it set stands as it is from here
    local shift = ServerNow() - clock
    for _, t in ipairs(st.timers or {}) do t.at = t.at + shift end
    for k, at in pairs(st.tstart or {}) do st.tstart[k] = at + shift end
    for _, m in ipairs(st.moments or {}) do m.at = (m.at or 0) + shift end
    for _, q in pairs(st.qa or {}) do
        if q.at then q.at = q.at + shift end
        if q.ends then q.ends = q.ends + shift end
        if q.closed then q.closed = q.closed + shift end
    end
    if st.stageAt then st.stageAt = st.stageAt + shift end
    if st.t0 then st.t0 = st.t0 + shift end
    st.watch = 9 + Hash(e.key, 14)
    st.seq = 40
    e.st, e.def, e.at = st, run.def, GetTime()
    return e
end

DemoKinds = function(occ)
    if type(occ) ~= "string" or not occ:find("^kdemo%-") or not DemoOn() then return nil end
    local d = demoRuns[occ]
    if d and d.st and GetTime() - (d.at or 0) < 900 then return d end
    for _, e in ipairs(Board.DEMO) do
        if e.key == occ then
            local copy = { key = e.key, ex = e.ex, label = e.label }
            local ok, res = pcall(BuildDemo, copy)
            demoRuns[occ] = ok and res or nil
            if not ok and ns.Debug then ns:Debug("demo board: %s", tostring(res)) end
            return demoRuns[occ]
        end
    end
    return nil
end
Board.DemoKinds = function(_, occ) return DemoKinds(occ) end

-- Demo mode: one of the part 2 boards (Board.DEMO's keys).
function Board:OpenDemo(key)
    if not DemoOn() then return false end
    return self:Open(key)
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
    elseif EUI():StageSub(L():GetDef(occ), st) == "signing up" then
        parts[#parts + 1] = #H.SignedUp(st) .. " signed up"
    else
        -- (part 2: who plays, an ask open)
        local n = #(st.entrants or {})
        parts[#parts + 1] = n == 1 and "1 player" or (n .. " players")
        local open = 0
        for _, q in pairs(type(st.qa) == "table" and st.qa or {}) do if type(q) == "table" and q.open then open = open + 1 end end
        if open > 0 then parts[#parts + 1] = open == 1 and "1 ask open" or (open .. " asks open") end
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
    -- Change a result: a match of this round, then its winner (an event with Matches)
    local cr = bk and rootDesc:CreateButton(Glyph(16) .. "Change a result")
    if cr then cr:SetTitleAndTextTooltip("Change a result", "Decide a match that is being played or waiting: its winner goes on.") end
    local any = not bk
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
        local made = occ == "practice" or (DemoKinds and DemoKinds(occ) ~= nil)
        if open and not made then
            rootDesc:CreateButton(Glyph(UI().ICON.calendar) .. "Event page", function() open(EU, occ) end)
        end
        local host = st and st.host
        if host and not ns.Util.IsMe(host) and not made then
            rootDesc:CreateButton(Glyph(UI().ICON.whisper) .. "Whisper the host", function()
                local fn = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
                if fn then fn("/w " .. ((Ambiguate and Ambiguate(host, "none")) or ns.Util.ShortName(host)) .. " ") end
            end)
        end
        local me = Me()
        if st and st.phase == "live" and H.Contains(st.entrants, me) and not ns.Util.IsMe(host or "") and not made then
            rootDesc:CreateButton(Glyph(UI().ICON.trash, { 1, 0.55, 0.5 }) .. "|cffff8d80Leave the event|r", function()
                Confirm("Leave the event?", "Your match now is lost and you're out of the bracket.", "Leave", function()
                    if Ev() then Ev():SignUp(occ, false) end
                end)
            end)
        end
        -- demo mode: the other kinds of board (made up here, nothing is sent)
        if DemoOn() then
            local sub = rootDesc:CreateButton(Glyph(UI().ICON.eye) .. "Other boards")
            sub:SetTitleAndTextTooltip("Other boards", "Demo mode: how the board looks for other kinds of events.")
            sub:CreateRadio("Friday duel cup", function() return state.occ == "odemo1" end, function() Board:Open("odemo1") end)
            for _, e in ipairs(Board.DEMO) do
                sub:CreateRadio(e.label, function() return state.occ == e.key end, function() Board:OpenDemo(e.key) end)
            end
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
        HideKV()
        br:Show()
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
    -- an event without Matches: the views from what it has
    local v = self:Views(def, st)
    state.views = v
    if v.layout ~= "bracket" then
        for _, c in ipairs(rail.nows) do c:Hide() end
        for _, c in ipairs(rail.moms) do c:Hide() end
        for _, c in ipairs(rail.heads) do c:Hide() end
        for _, c in ipairs(rail.pods or {}) do c:Hide() end
        if rail.next then rail.next:Hide() end
        HideFrom(br.cards, 1)
        HideFrom(br.lines, 1)
        br.champ:Hide()
        self:DrawKinds(occ, st, def, v, BR_Y + off, height)
        RefreshDispute(occ, st, bk, disputes)
        return
    end
    HideKV()
    br:Show()
    rail:Show()
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
    if DemoOn() and T and (occId == "odemo1" or DemoKinds(occId)) and (not T.demoSeen or T.demoOcc ~= occId) then
        T.demoSeen, T.demoOcc = true, occId
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
