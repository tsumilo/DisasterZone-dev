if DisasterZoneBoot and DisasterZoneBoot.Run("UI/EventTracker.lua", ...) then return end -- DisasterZone: an event in the world.
-- What a live event puts on my screen (mockup shots 9-10), drawn from its state (EventLive:GetState):
--   the tracker under the minimap (like a quest: the event, my match, how far it is, where to go, Ready), while I play
--   in or host a live event; the "your match is ready" card when my match starts (both players, the no-show timer,
--   Ready); the event's raid warnings (EVENT_ANNOUNCE) and countdowns (EVENT_COUNTDOWN) big on the screen;
--   the result prompts: a toast when a game of my match counts, "Who won game N?" when my game and my opponent's
--   disagree (EventLive:MyAsk), and the wait for an opponent who isn't ready, with a Whisper button.
-- The drawing helpers are the board's (ns.EventBoard.H).
local addonName, ns = ...

local T = ns:NewModule("EventTracker")

local CreateFrame = CreateFrame
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber

local function UI() return ns.UI end
local function EUI() return ns.EventUI end
local function L() return ns.EventLive end
local function E() return ns.EventEngine end
local function Ev() return ns.Events end
local function Board() return ns.EventBoard end
local function Me() return ns.Util.PlayerKey() end
local function H() return ns.EventBoard.H end

local TRK_W, TRK_IN = 232, 23
local CARD_W = 360
local ASK_W = 360
local WHITE = "Interface\\Buttons\\WHITE8X8"
local RING = "Interface\\AddOns\\DisasterZone\\Media\\Events\\ring"
local WARN = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"
local CHECK = "Interface\\Buttons\\UI-CheckBox-Check"
local CROSS = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local GOLD = { 1, 0.82, 0 }
local ORANGE = { 1, 0.55, 0.1 }
local CARD_TOP, CARD_BOT = { 0.114, 0.114, 0.133 }, { 0.078, 0.078, 0.094 }

local trk, card, toast, ask, waitc, cdown, rwarn
local cur = { occ = nil }
local follow = {}          -- [occ] = { mid, st, wa, wb } the match of mine I follow
local cardShown = {}       -- [occ .. ":" .. mid] = true: the match card came up once
local cardOff = {}         -- [occ .. ":" .. mid] = true: "Need a minute"
local asked = {}           -- [occ .. ":" .. mid .. ":" .. game] = "players" | "host"
local answered = {}        -- [occ .. ":" .. askId] = true: I answered (until the state says so)

local function Snd(key)
    local kit = SOUNDKIT
    if kit and kit[key] and PlaySound then pcall(PlaySound, kit[key]) end
end

local function Gradient(tex, top, bottom)
    tex:SetTexture(WHITE)
    if tex.SetGradient and CreateColor then
        tex:SetGradient("VERTICAL", CreateColor(bottom[1], bottom[2], bottom[3], bottom[4] or 1),
            CreateColor(top[1], top[2], top[3], top[4] or 1))
    else
        tex:SetColorTexture(top[1], top[2], top[3], top[4] or 1)
    end
end

-- The flat HUD card: a dark gradient, a 1px edge, a soft shadow under it.
local function HudCard(name, w, h, edge)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetSize(w, h)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f.shadow = f:CreateTexture(nil, "BACKGROUND", nil, -2)
    f.shadow:SetPoint("TOPLEFT", -8, 6)
    f.shadow:SetPoint("BOTTOMRIGHT", 8, -14)
    f.shadow:SetColorTexture(0, 0, 0, 0.4)
    f.bg = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    f.bg:SetAllPoints()
    Gradient(f.bg, CARD_TOP, CARD_BOT)
    UI():AddEdges(f, "BORDER", true)
    local e = edge or { 0.47, 0.47, 0.51, 0.75 }
    UI():SetEdgeColor(f, e[1], e[2], e[3], e[4])
    f:EnableMouse(true)
    f:Hide()
    return f
end

local function Contains(list, v)
    for i = 1, #(list or {}) do if list[i] == v then return i end end
    return nil
end

local function Short(key) return (Ambiguate and type(key) == "string" and Ambiguate(key, "none")) or ns.Util.ShortName(key) end

local function Whisper(key)
    if type(key) ~= "string" then return end
    local fn = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if fn then fn("/w " .. Short(key) .. " ") end
end

---------------------------------------------------------------------------
-- Which event is mine, and where my match stands
---------------------------------------------------------------------------

local function Bracket(occ, st)
    local def = L():GetDef(occ)
    return def and st and E():BracketOf(def, st) or nil, def
end

local function DemoOn() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() or false end

-- A run's state and def (the board's reader: live runs, practice, demo mode's boards).
local function StateOf(occ)
    local b = Board()
    if b and b.StateOf then return b:StateOf(occ) end
    return L():GetState(occ), L():GetDef(occ)
end

-- The practice run gives me (its host) something to do or see: an ask, a button, a tag, an arrow, a line.
local function PracticeForMe()
    local run = L().GetPractice and L():GetPractice()
    local st = run and run.st
    if not (st and st.phase == "live") then return false end
    local me = Me()
    for _, q in pairs(st.qa or {}) do if type(q) == "table" and q.open and q.who and q.who[me] then return true end end
    for _, who in pairs(st.buttons or {}) do if type(who) == "table" and who[me] then return true end end
    for _, set in pairs(st.tags or {}) do if type(set) == "table" and set[me] then return true end end
    if st.point and st.point[me] then return true end
    local feed = L().MyFeed and L():MyFeed("practice")
    return feed and feed[1] ~= nil or false
end

-- The live event I play in or host (my match being played first): occ, st, def, bk.
function T:MyEvent()
    local me = Me()
    -- demo mode's live cup (or the board last looked at): only once its board was opened (switching demo mode on puts
    -- nothing in the world)
    if DemoOn() then
        if not self.demoSeen then return nil end
        local occ = self.demoOcc or "odemo1"
        local st, def = StateOf(occ)
        if not (st and def) then return nil end
        return occ, st, def, (E():BracketOf(def, st))
    end
    local best, bestScore
    for _, occ in ipairs(L():GetLiveList() or {}) do
        local st = L():GetState(occ)
        if st and st.phase == "live" then
            local entrant = Contains(st.entrants, me) or Contains(st.signups, me)
            local host = st.host == me or L():IsHostOf(occ)
            if entrant or host then
                local bk = Bracket(occ, st)
                local m = bk and H().MyNext(bk, me)
                local score = (m and m.st == "play") and 4 or (m and 3) or (entrant and 2) or 1
                if not bestScore or score > bestScore then best, bestScore = occ, score end
            end
        end
    end
    if not best then
        -- the builder's practice run, when it puts something on my screen
        if PracticeForMe() then
            local st, def = StateOf("practice")
            if st and def then return "practice", st, def, (E():BracketOf(def, st)) end
        end
        -- a planned event I'm in, about to start, with a place to meet (or one I asked the way to)
        local occ, o = self:Upcoming()
        if occ then return occ, nil, o.def, nil, o end
        return nil
    end
    local st = StateOf(best)
    local bk, def = Bracket(best, st)
    return best, st, def, bk
end

local function Elapsed(occ, st, m)
    local now = H().Now(occ)
    if type(st.paused) == "number" then now = min(now, st.paused) end
    return max(0, now - (m.t or now))
end

local function NoShow(bk) return tonumber(bk and bk.noshow) or 300 end

---------------------------------------------------------------------------
-- The tracker under the minimap
---------------------------------------------------------------------------

local function Anchor()
    if not trk then return end
    trk:ClearAllPoints()
    local qw = _G.QuestWatchFrame or _G.WatchFrame
    local watches = GetNumQuestWatches and GetNumQuestWatches() or 0
    if qw and qw.IsVisible and qw:IsVisible() and watches > 0 and (qw:GetHeight() or 0) > 12 and qw:GetBottom() then
        trk:SetPoint("TOPRIGHT", qw, "BOTTOMRIGHT", 0, -12)
        trk.anchoredTo = qw
        return
    end
    local mc = _G.MinimapCluster
    if mc and mc.GetNumPoints and mc:GetNumPoints() > 0 and (mc:GetHeight() or 0) > 0 then
        trk:SetPoint("TOPRIGHT", mc, "BOTTOMRIGHT", -16, -10)
        trk.anchoredTo = mc
    else
        trk:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -22, -214)
        trk.anchoredTo = UIParent
    end
end

local function Line(parent, size, r, g, b)
    local fs = H().Text(parent, "GameFontHighlight", size, r, g, b)
    fs:SetWordWrap(true)
    fs:SetSpacing(2)
    fs:SetWidth(TRK_W - TRK_IN)
    return fs
end

local function CreateTracker()
    local f = CreateFrame("Frame", "DisasterZoneEventTracker", UIParent)
    f:SetSize(TRK_W, 80)
    f:SetFrameStrata("LOW")
    f:SetClampedToScreen(true)
    -- a soft shade behind the text (the world can be bright), no box: it reads like the quest tracker
    f.shade = f:CreateTexture(nil, "BACKGROUND")
    f.shade:SetPoint("TOPLEFT", -14, 8)
    f.shade:SetPoint("BOTTOMRIGHT", 10, -8)
    f.shade:SetTexture(WHITE)
    if f.shade.SetGradient and CreateColor then
        f.shade:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.42))
    else
        f.shade:SetColorTexture(0, 0, 0, 0.25)
    end
    local head = CreateFrame("Button", nil, f)
    head:SetPoint("TOPLEFT")
    head:SetPoint("TOPRIGHT")
    head:SetHeight(18)
    head:RegisterForClicks("LeftButtonUp")
    head:SetScript("OnClick", function()
        if not cur.occ then return end
        -- (a planned event has no board yet: its page)
        if cur.planned and ns.EventsUI and ns.EventsUI.OpenEvent then
            ns.EventsUI:OpenEvent(cur.occ)
            return
        end
        Board():Toggle(cur.occ)
    end)
    head:SetScript("OnEnter", function(self)
        f.name:SetTextColor(1, 0.92, 0.5)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(f.name:GetText() or "Event")
        GameTooltip:AddLine(cur.planned and "Click: the event's page" or "Click: the live board", 1, 1, 1)
        GameTooltip:Show()
    end)
    head:SetScript("OnLeave", function()
        f.name:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        GameTooltip:Hide()
    end)
    f.head = head
    f.icon = head:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(16, 16)
    f.icon:SetPoint("LEFT", 0, 0)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.name = H().Text(head, "GameFontNormal", 12.5, GOLD[1], GOLD[2], GOLD[3])
    f.name:SetPoint("LEFT", f.icon, "RIGHT", 7, 0)
    f.clock = H().Text(head, "GameFontHighlight", 12, 0.91, 0.91, 0.91)
    EUI():Narrow(f.clock, 12.5)
    f.clock:SetJustifyH("RIGHT")
    f.clock:SetPoint("RIGHT", 0, 0)
    f.l1 = Line(f, 11.5, 0.94, 0.94, 0.94)
    f.l2 = Line(f, 11, 0.78, 0.78, 0.78)
    f.l3 = Line(f, 11, 0.78, 0.78, 0.78)
    f.pips = H().NewPips(f, 9, 4, 0.5)
    f.pipText = H().Text(f, "GameFontHighlightSmall", 10.5, 0.78, 0.78, 0.78)
    f.pipText:SetPoint("LEFT", f.pips, "RIGHT", 6, 0)
    f.ready = UI():CreateSleekButton(f, "Ready", 72, 22, function() T:Ready() end, "primary")
    f.ready:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Ready")
        GameTooltip:AddLine("Tells the host you're there. A duel with your opponent counts as ready too.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.ready:HookScript("OnLeave", function() GameTooltip:Hide() end)
    f.board = UI():CreateSleekButton(f, "Settle it", 80, 22, function() if cur.occ then Board():Open(cur.occ) end end)
    -- part 2: the stage line, my tags, the arrow to a place, a walked list's progress, my scores, my buttons, the feed
    f.stage = Line(f, 11, 0.78, 0.78, 0.78)
    f.chips, f.scores, f.btns, f.feed = {}, {}, {}, {}
    local arr = CreateFrame("Frame", nil, f)
    arr:SetSize(TRK_W - TRK_IN, 38)
    arr.bg = H().Disc(arr, "ARTWORK", 0, 38, 0.039, 0.039, 0.051, 0.7)
    arr.bg:SetPoint("LEFT", 0, 0)
    arr.ring = arr:CreateTexture(nil, "ARTWORK", nil, 1)
    arr.ring:SetTexture(EUI().RING)
    arr.ring:SetSize(38, 38)
    arr.ring:SetPoint("CENTER", arr.bg)
    arr.ring:SetVertexColor(0.337, 0.839, 0.941, 0.55)
    arr.arrow = arr:CreateTexture(nil, "ARTWORK", nil, 3)
    arr.arrow:SetTexture(EUI().ARROW)
    arr.arrow:SetSize(24, 24)
    arr.arrow:SetPoint("CENTER", arr.bg)
    arr.arrow:SetVertexColor(0.337, 0.839, 0.941, 1)
    arr.shadow = arr:CreateTexture(nil, "ARTWORK", nil, 2)
    arr.shadow:SetTexture(EUI().ARROW)
    arr.shadow:SetSize(26, 26)
    arr.shadow:SetPoint("CENTER", arr.bg, "CENTER", 0, 0)
    arr.shadow:SetVertexColor(0.016, 0.15, 0.18, 0.9)
    arr.pin = arr:CreateTexture(nil, "ARTWORK", nil, 3)
    arr.pin:SetSize(16, 16)
    arr.pin:SetPoint("CENTER", arr.bg)
    EUI():Glyph(arr.pin, UI().ICON.pin or 7, 0.337, 0.839, 0.941, 1)
    arr.name = H().Text(arr, "GameFontHighlight", 12.5, 1, 1, 1)
    arr.name:SetPoint("BOTTOMLEFT", arr.bg, "RIGHT", 10, 0)
    arr.yd = H().Text(arr, "GameFontHighlight", 13, 0.612, 0.937, 1)
    EUI():Narrow(arr.yd, 13)
    arr.yd:SetPoint("TOPLEFT", arr.bg, "RIGHT", 10, -1)
    arr:EnableMouse(true)
    arr:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(self.tipTitle or "Where to go")
        GameTooltip:AddLine(self.tipText or "The event points you here. Its ring is on your minimap.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    arr:SetScript("OnLeave", function() GameTooltip:Hide() end)
    arr:Hide()
    f.arr = arr
    f.segs = EUI():CreateSegments(f, TRK_W - TRK_IN, 5, "track")
    f.segs:Hide()
    f.tick = 0
    f.fast = 0
    f:SetScript("OnUpdate", function(self, dt)
        -- the arrow and the minimap's ring follow me ten times a second; the clocks once a second
        self.fast = self.fast + dt
        if self.fast >= 0.1 then
            self.fast = 0
            T:TickArrow()
        end
        self.tick = self.tick + dt
        if self.tick < 1 then return end
        self.tick = 0
        T:TickClocks()
    end)
    f:Hide()
    trk = f
    Anchor()
    return f
end

-- The event's name at the top: smaller when long, else on two lines (the clock keeps its place at the right).
local function TitleFit(f, name)
    local one = H().Fit2(f.name, name, TRK_W - 23 - 44, 12.5, 10)
    f.headH = one and 18 or 32
    f.head:SetHeight(f.headH)
end

-- Lays the tracker's lines out top to bottom (shown ones only) and sizes it.
local function LayTracker(f)
    local y = f.headH or 18
    for _, fs in ipairs({ f.l1, f.l2, f.l3 }) do
        fs:ClearAllPoints()
        if fs:IsShown() and (fs:GetText() or "") ~= "" then
            fs:SetPoint("TOPLEFT", f, "TOPLEFT", TRK_IN, -(y + 4))
            y = y + 4 + (fs:GetStringHeight() or 13)
        else
            fs:Hide()
        end
    end
    if f.pips:IsShown() then
        f.pips:ClearAllPoints()
        f.pips:SetPoint("TOPLEFT", f, "TOPLEFT", TRK_IN, -(y + 8))
        y = y + 8 + 14
    end
    local by = y + 8
    local x = TRK_IN
    for _, b in ipairs({ f.ready, f.board }) do
        if b:IsShown() then
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -by)
            x = x + b:GetWidth() + 6
        end
    end
    if f.ready:IsShown() or f.board:IsShown() then y = by + 22 end
    -- part 2 under part 1's lines: the stage line, my tags, the arrow, a list's progress, my scores, buttons, the feed
    local W = TRK_W - TRK_IN
    if f.stage:IsShown() and (f.stage:GetText() or "") ~= "" then
        f.stage:ClearAllPoints()
        f.stage:SetPoint("TOPLEFT", f, "TOPLEFT", TRK_IN, -(y + 4))
        y = y + 4 + (f.stage:GetStringHeight() or 13)
    else
        f.stage:Hide()
    end
    local x, rowY, any = 0, y + 6, false
    for _, c in ipairs(f.chips) do
        if c:IsShown() then
            if any and x + c:GetWidth() > W then x, rowY = 0, rowY + 18 + 4 end
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", f, "TOPLEFT", TRK_IN + x, -rowY)
            x = x + c:GetWidth() + 4
            any = true
        end
    end
    if any then y = rowY + 18 end
    if f.arr:IsShown() then
        f.arr:ClearAllPoints()
        f.arr:SetPoint("TOPLEFT", f, "TOPLEFT", TRK_IN, -(y + 8))
        y = y + 8 + 38
    end
    if f.segs:IsShown() then
        f.segs:ClearAllPoints()
        f.segs:SetPoint("TOPLEFT", f, "TOPLEFT", TRK_IN, -(y + 8))
        y = y + 8 + 5
    end
    for _, s in ipairs(f.scores) do
        if s:IsShown() then
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", f, "TOPLEFT", TRK_IN, -(y + 6))
            y = y + 6 + 26
        end
    end
    x, rowY, any = 0, y + 8, false
    for _, b in ipairs(f.btns) do
        if b:IsShown() then
            if any and x + b:GetWidth() > W then x, rowY = 0, rowY + 22 + 6 end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", f, "TOPLEFT", TRK_IN + x, -rowY)
            x = x + b:GetWidth() + 6
            any = true
        end
    end
    if any then y = rowY + 22 end
    for i, r in ipairs(f.feed) do
        if r:IsShown() then
            local gap = (i == 1) and 6 or 3
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", f, "TOPLEFT", TRK_IN, -(y + gap))
            local hgt = max(15, (r.fs:GetStringHeight() or 15))
            r:SetHeight(hgt)
            y = y + gap + hgt
        end
    end
    f:SetHeight(y)
end

---------------------------------------------------------------------------
-- Part 2 on the tracker (mockup shot 24)
---------------------------------------------------------------------------

local function B() return ns.EventBlocks end
local function ServerNow() return (GetServerTime and GetServerTime()) or time() end

-- What a run gives me: tags (shown to me), scores, buttons, the place I'm pointed to (pid, yards, bearing), the feed.
-- Demo mode's boards: made up with them (nothing is sent).
function T:Mine(occ, st, def)
    local me = Me()
    local out = { tags = {}, scores = {}, buttons = {}, feed = {} }
    local demo = Board().DemoKinds and Board():DemoKinds(occ)
    if demo or not L().MyTags then
        for _, t in ipairs(B():Defs(def, "tags", true)) do
            local shown = t.shown or "all"
            if st.tags and st.tags[t.id] and st.tags[t.id][me] and (shown ~= "host" or st.host == me) then
                out.tags[#out.tags + 1] = { id = t.id, n = t.n, c = t.c, shown = shown }
            end
        end
        local r = E():Reader(def, st)
        for _, sc in ipairs(B():Defs(def, "scores", true)) do
            local n = st.scores and st.scores[sc.id] and st.scores[sc.id][me]
            local p = n ~= nil and r:PlaceBy(sc.id, me) or nil
            out.scores[#out.scores + 1] = { sid = sc.id, n = n, place = (p and p > 0) and p or nil, name = sc.n, fmt = sc.fmt,
                high = sc.high ~= false, board = sc.board and true or false }
        end
        out.buttons = E():ButtonsOf(st, me)
        if demo then
            if demo.point then out.pid, out.yards, out.bearing = demo.point[1], demo.point[2], demo.point[3] end
            for i, t in ipairs(demo.tell or {}) do out.feed[i] = { at = ServerNow() - i * 60, text = t } end
        end
        return out
    end
    out.tags = L():MyTags(occ) or {}
    if L().MyScores then out.scores = L():MyScores(occ) or {} end
    if L().MyButtons then out.buttons = L():MyButtons(occ) or {} end
    if L().MyPoint then out.pid, out.yards, out.bearing = L():MyPoint(occ) end
    if L().MyFeed then out.feed = L():MyFeed(occ) or {} end
    return out
end

local function Chip(f, i)
    local c = f.chips[i]
    if not c then
        c = EUI():CreateChip(f, "track")
        f.chips[i] = c
    end
    return c
end

local function ScoreLine(f, i)
    local s = f.scores[i]
    if not s then
        s = CreateFrame("Frame", nil, f)
        s:SetSize(TRK_W - TRK_IN, 26)
        s.big = H().Text(s, "GameFontHighlight", 24, 1, 1, 1)
        EUI():Narrow(s.big, 24)
        s.big:SetPoint("BOTTOMLEFT", 0, 0)
        s.sub = H().Text(s, "GameFontHighlight", 11.5, 0.91, 0.91, 0.91)
        s.sub:SetPoint("BOTTOMLEFT", s.big, "BOTTOMRIGHT", 8, 3)
        f.scores[i] = s
    end
    return s
end

local function Button(f, i)
    local b = f.btns[i]
    if not b then
        b = UI():CreateSleekButton(f, "", 60, 22, function(self) T:Press(self.occ, self.label) end)
        H().Sized(b:GetFontString(), 11.5)
        b:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine(self.label or "")
            GameTooltip:AddLine("The event gave you this button: pressing it tells the host's addon.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
        f.btns[i] = b
    end
    return b
end

local function FeedLine(f, i)
    local r = f.feed[i]
    if not r then
        r = CreateFrame("Frame", nil, f)
        r:SetSize(TRK_W - TRK_IN, 15)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(10, 10)
        r.icon:SetPoint("TOPLEFT", 0, -3)
        EUI():Glyph(r.icon, UI().ICON.whisper, 1, 1, 1, 0.8)
        r.fs = H().Text(r, "GameFontHighlight", 11.5, 0.957, 0.957, 0.957)
        r.fs:SetWordWrap(true)
        r.fs:SetSpacing(1)
        r.fs:SetWidth(TRK_W - TRK_IN - 16)
        r.fs:SetPoint("TOPLEFT", 16, 0)
        f.feed[i] = r
    end
    return r
end

local FEED_SHOWN, FEED_FOR = 3, 15 * 60

-- The stage I'm in and what it's about: "Seek · ends 21:15", "Race · Route 3 of 8".
function T:StageLine(occ, st, def, v)
    local name = B():StageName(def, st.stage)
    if not st.stage then name = st.phase == "done" and "Over" or "" end
    local me = Me()
    if v.walked and v.list then
        local n = #(v.list.items or {})
        local pos = (st.lists and st.lists[v.walked] and tonumber(st.lists[v.walked][me])) or 1
        if n > 0 and Contains(st.entrants, me) then
            if pos > n then return name .. " · " .. v.list.n .. " done" end
            return name .. " · " .. v.list.n .. " " .. pos .. " of " .. n
        end
    end
    local timers = H().ShownTimers(occ, st)
    if timers[1] then return name .. " · ends " .. date("%H:%M", timers[1].ends) end
    return name
end

-- Fills part 2's lines (bk: the event has Matches: part 1's lines say what's on, the stage line isn't needed).
function T:FillPart2(f, occ, st, def, bk)
    local h = H()
    local me = Me()
    local v = Board():Views(def, st)
    local mine = self:Mine(occ, st, def)
    f.mine = mine
    -- the stage
    if not bk then
        f.stage:SetText(self:StageLine(occ, st, def, v))
        f.stage:SetTextColor(0.78, 0.78, 0.78)
        f.stage:Show()
    else
        f.stage:SetText("")
    end
    -- my tags
    local n = 0
    for _, t in ipairs(mine.tags) do
        n = n + 1
        local c = Chip(f, n)
        c:Set(t.n, B():TagColor(t.c))
        c:Show()
    end
    for i = n + 1, #f.chips do f.chips[i]:Hide() end
    -- the arrow to the place I'm pointed to; while the sign-up runs (nobody pointed yet), to where everyone meets
    local place = mine.pid and type(def.places) == "table" and def.places[mine.pid]
    local arr = f.arr
    local inIt = Contains(st.entrants, me) or Contains(st.signups, me) or L():IsHostOf(occ)
    if not place and inIt and L().MyMeet and EUI():StageSub(def, st) == "signing up" then
        local pid, yd, br = L():MyMeet(occ)
        place = pid and type(def.places) == "table" and def.places[pid]
        if place then mine.pid, mine.yards, mine.bearing, mine.meet = pid, yd, br, true end
    end
    if place then
        self:ArrowTo(f, place, mine.yards, mine.bearing, mine.meet)
    else
        arr:Hide()
    end
    -- a list I walk: its progress
    if v.walked and v.list and #(v.list.items or {}) > 0 and Contains(st.entrants, me) then
        local items = v.list.items
        local pos = (st.lists and st.lists[v.walked] and tonumber(st.lists[v.walked][me])) or 1
        f.segs:Set(#items, min(#items, pos - 1), pos > #items)
        f.segs:Show()
    else
        f.segs:Hide()
    end
    -- my scores on the board (the ones I have): "24 Fish · 3rd"
    n = 0
    for _, s in ipairs(mine.scores) do
        if s.board and s.place and n < 2 then
            n = n + 1
            local line = ScoreLine(f, n)
            line.big:SetText(B():FormatScore(def, s.sid, s.n))
            h.Fit(line.sub, (s.name or "") .. " · " .. h.Ordinal(s.place), TRK_W - TRK_IN - h.Width(line.big) - 8, 11.5, 9.5)
            line:Show()
        end
    end
    for i = n + 1, #f.scores do f.scores[i]:Hide() end
    -- my buttons
    n = 0
    for _, label in ipairs(mine.buttons) do
        if n < 6 then
            n = n + 1
            local b = Button(f, n)
            b.occ, b.label = occ, label
            b:SetText(label)
            b:SetWidth(floor(H().Width(b:GetFontString()) + 24 + 0.5))
            b:Show()
        end
    end
    for i = n + 1, #f.btns do f.btns[i]:Hide() end
    -- the last lines the event told me, newest first (the older ones grey)
    n = 0
    local now = ServerNow()
    for _, e in ipairs(mine.feed) do
        if n < FEED_SHOWN and (now - (tonumber(e.at) or now)) < FEED_FOR then
            n = n + 1
            local r = FeedLine(f, n)
            local old = n > 1
            h.Sized(r.fs, old and 11 or 11.5)
            r.fs:SetText(h.ColorNames(e.text, st.entrants))
            if old then r.fs:SetTextColor(0.72, 0.72, 0.72) else r.fs:SetTextColor(0.957, 0.957, 0.957) end
            r.icon:SetAlpha(old and 0.45 or 0.8)
            r:Show()
        end
    end
    for i = n + 1, #f.feed do f.feed[i]:Hide() end
    self:RefreshMinimapRing(occ, st, def, mine)
end

-- The arrow: the texture points up; bearing = radians from where I face, counterclockwise (0 ahead, pi/2 left).
function T:SetArrow(bearing)
    local arr = trk and trk.arr
    if not arr then return end
    local on = type(bearing) == "number"
    arr.arrow:SetShown(on)
    arr.shadow:SetShown(on)
    arr.pin:SetShown(not on)
    if on then
        arr.arrow:SetRotation(bearing)
        arr.shadow:SetRotation(bearing)
    end
    arr.bearing = bearing
end

-- Ten times a second: the arrow follows where I face and walk (the run's state says where; my game where I am).
function T:TickArrow()
    local f = trk
    if not (f and f:IsShown() and cur.occ) then return end
    if f.arr:IsShown() and f.mine and not (Board().DemoKinds and Board():DemoKinds(cur.occ)) and L().MyPoint then
        local pid, yards, bearing
        if f.mine.meet then pid, yards, bearing = L():MyMeet(cur.occ) else pid, yards, bearing = L():MyPoint(cur.occ) end
        if pid and pid == f.mine.pid then
            if yards then f.arr.yd:SetText(self:YardsText(f.arr, yards)) end
            self:SetArrow(bearing)
        elseif not pid and not f.mine.meet then
            -- (I got there: my own point ends by itself)
            self:Later()
        end
    end
    self:MoveMinimapRing()
end

---------------------------------------------------------------------------
-- The pointed place's ring on the minimap (the part of it the minimap shows)
---------------------------------------------------------------------------

-- The minimap's radius in yards (its zoom; indoors it shows less).
local MM_OUT = { [0] = 233.33, 200, 166.67, 133.33, 100, 66.67 }
local MM_IN = { [0] = 150, 120, 90, 60, 40, 25 }
local function MinimapYards()
    local mm = _G.Minimap
    local z = (mm and mm.GetZoom and mm:GetZoom()) or 0
    local indoors = IsIndoors and IsIndoors()
    return (indoors and MM_IN or MM_OUT)[z] or 233.33
end

local mmRing
function T:RefreshMinimapRing(occ, st, def, mine)
    local place = mine and mine.pid and type(def.places) == "table" and def.places[mine.pid]
    local real = place and occ ~= "practice" and not (Board().DemoKinds and Board():DemoKinds(occ))
    if not (real and tonumber(place.map) and _G.Minimap) then
        if mmRing then mmRing:Hide() end
        if mmRing then mmRing.place = nil end
        return
    end
    if not mmRing then
        mmRing = CreateFrame("Frame", "DisasterZoneEventMinimapRing", _G.Minimap)
        mmRing:SetAllPoints(_G.Minimap)
        mmRing:SetFrameLevel((_G.Minimap:GetFrameLevel() or 1) + 4)
        mmRing.circle = EUI():CreateCircle(mmRing)
    end
    if mmRing.place ~= place then mmRing.last = nil end
    mmRing.place = place
    mmRing:Show()
    self:MoveMinimapRing()
end

function T:MoveMinimapRing()
    local r = mmRing
    if not (r and r:IsShown() and r.place) then return end
    local S = ns.EventSensors
    local me = S and S.MyPos and S:MyPos()
    local p = r.place
    if not me then r.circle:Hide() r.last = nil return end
    local c1, mx, my = S.World(me.map, me.x, me.y)
    local c2, px, py = S.World(p.map, p.x, p.y)
    if not (c1 and c2 and c1 == c2) then r.circle:Hide() r.last = nil return end
    -- world x grows to the north, y to the west: on a minimap with north up, east is right
    local north, east = px - mx, -(py - my)
    if GetCVar and GetCVar("rotateMinimap") == "1" then
        local f = S.Facing and S.Facing() or 0
        east, north = east * math.cos(f) + north * math.sin(f), -east * math.sin(f) + north * math.cos(f)
    end
    local R = (_G.Minimap:GetWidth() or 140) / 2
    local k = R / MinimapYards()
    local cx, cy = east * k, north * k
    local rad = max(4, (tonumber(p.r) or 30) * k)
    -- (only what the round minimap shows: the ring when it's near, an arc when I'm inside a big one)
    if math.sqrt(cx * cx + cy * cy) - rad > R then r.circle:Hide() r.last = nil return end
    -- (redrawn only when it moved: ten times a second otherwise)
    local last = r.last
    if last and r.circle:IsShown() and math.abs(last[1] - cx) < 0.25 and math.abs(last[2] - cy) < 0.25
        and math.abs(last[3] - rad) < 0.1 and last[4] == R then return end
    r.last = { cx, cy, rad, R }
    r.circle:ClearAllPoints()
    r.circle:SetPoint("CENTER", r, "CENTER", cx, cy)
    r.circle:Set(rad, { stroke = EUI().TEAL, width = 2, shadow = true, fill = { 0.337, 0.839, 0.941, 0.25 },
        clip = { -cx, -cy, R - 2 } })
end

---------------------------------------------------------------------------
-- Where to go before it starts (EVENTS_KINDS.md "Where to go"): the meeting place
---------------------------------------------------------------------------

local MEET_BEFORE, MEET_AFTER = 30 * 60, 60 * 60

-- The planned event the tracker shows: one I'm in (or host) starting within 30 min (an hour late at most) with a
-- place to meet, else one I asked the way to (Show the way). occ, o.
function T:Upcoming()
    if DemoOn() then return nil end
    local ev, me = Ev(), Me()
    if not (ev and ev.GetOccurrences) then return nil end
    local now = ServerNow()
    local best, bestAt, asked
    for _, o in ipairs(ev:GetOccurrences(now - 6 * 3600, now + 7 * 86400) or {}) do
        local state = ev:OccState(o)
        if state == "planned" and type(o.def) == "table" then
            local mineToo = ev:IsSignedUp(o.id) or ev:HostOf(o) == me
            local soon = o.at - now <= MEET_BEFORE and now - o.at <= MEET_AFTER
            if mineToo and soon and ev:MeetOf(o) and (not bestAt or o.at < bestAt) then best, bestAt = o, o.at end
            -- (a place I asked the way to, on its page or its map)
            if not asked and L().MyPoint and L():MyPoint(o.id) then asked = o end
        end
    end
    local o = best or asked
    if o then return o.id, o end
    return nil
end

-- "Starts in 12 min" (a minute's words), "Starts any minute" once it's due, "Starts Wed 20:00" further off.
local function StartsText(at)
    local left = at - ServerNow()
    if left <= 30 then return "Starts any minute" end
    if left < 90 * 60 then return "Starts in " .. max(1, ceil(left / 60)) .. " min" end
    local day = EUI().Day and EUI():Day(at)
    return "Starts " .. (day and (day .. " ") or "") .. date("%H:%M", at)
end
T.StartsText = StartsText

-- The arrow's row for a place: "Meet at Start line" (meet) or its name; "340 yd", "Zangarmarsh · 2400 yd" when it's
-- in another zone, "Zangarmarsh" when the way isn't known (an instance, another continent).
function T:ArrowTo(f, place, yards, bearing, meet)
    local h = H()
    local arr = f.arr
    local name = place.n or "A place"
    h.Fit(arr.name, meet and ("Meet at " .. name) or name, TRK_W - TRK_IN - 48, 12.5, 10.5)
    arr.tipTitle = meet and ("Meet at " .. name) or name
    local zone = EUI():PlaceZone(place)
    local S = ns.EventSensors
    local me = S and S.MyPos and S:MyPos()
    local elsewhere = zone and me and tonumber(me.map) ~= tonumber(place.map) and EUI():MapName(me.map) ~= zone
    arr.prefix = elsewhere and (zone .. " · ") or ""
    -- (where everyone meets: "you're there" inside it; a place the event points me to stops pointing there by itself)
    arr.r = meet and (tonumber(place.r) or 30) or nil
    if yards then
        arr.yd:SetText(self:YardsText(arr, yards))
        arr.yd:SetTextColor(0.612, 0.937, 1)
        arr.tipText = (meet and "Where everyone meets before it starts: follow the arrow. " or
            "The event points you here: follow the arrow. ") .. "Its ring is on your minimap."
    else
        local xy = EUI():Coords(place, 0)
        arr.yd:SetText(zone or (xy and ("at " .. xy)) or "outside instances")
        arr.yd:SetTextColor(0.62, 0.62, 0.62)
        arr.tipText = ((zone and xy) and (zone .. " " .. xy .. ". ") or "")
            .. "The arrow shows the way once you're in the open world on the same continent."
    end
    self:SetArrow(bearing)
    arr:Show()
end

-- "340 yd" ("Zangarmarsh · 2400 yd" in another zone), "you're there" inside the place.
function T:YardsText(arr, yards)
    if arr.r and yards <= arr.r then return "you're there" end
    return (arr.prefix or "") .. floor(yards + 0.5) .. " yd"
end

-- A planned event's tracker: its name, when it starts, and the way to where everyone meets (or the place I asked
-- the way to).
function T:FillPlanned(occ, o)
    local f = trk or CreateTracker()
    local h = H()
    local def = o.def
    f.icon:SetTexture(def.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    TitleFit(f, def.name or "Event")
    f.clockMatch = nil
    for _, x in ipairs({ f.ready, f.board, f.pips, f.segs }) do x:Hide() end
    f.pipText:SetText("")
    for _, fs in ipairs({ f.l1, f.l2, f.l3 }) do fs:SetText("") end
    for _, list in ipairs({ f.chips, f.scores, f.btns, f.feed }) do for _, x in ipairs(list) do x:Hide() end end
    f.planned = o
    f.stage:SetText(StartsText(o.at))
    f.stage:SetTextColor(0.94, 0.94, 0.94)
    f.stage:Show()
    -- the place I asked the way to first, else where everyone meets
    local pid, yards, bearing = L():MyPoint(occ)
    local meet = false
    if not pid then
        pid, yards, bearing = L():MyMeet(occ)
        meet = pid ~= nil
    end
    local place = pid and type(def.places) == "table" and def.places[pid]
    f.mine = { pid = place and pid or nil, yards = yards, bearing = bearing, meet = meet, tags = {}, scores = {},
        buttons = {}, feed = {} }
    if place then self:ArrowTo(f, place, yards, bearing, meet) else f.arr:Hide() end
    self:RefreshMinimapRing(occ, nil, def, f.mine)
    LayTracker(f)
    f:Show()
    self:TickClocks()
    Anchor()
end

-- The lines for the event (occ) and my place in it.
function T:FillTracker(occ, st, def, bk)
    local f = trk or CreateTracker()
    local h = H()
    local me = Me()
    f.planned = nil
    f.icon:SetTexture(def and def.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    TitleFit(f, def and def.name or "Event")
    f.clockMatch = nil
    f.ready:Hide()
    f.board:Hide()
    f.pips:Hide()
    f.pipText:SetText("")
    for _, fs in ipairs({ f.l1, f.l2, f.l3 }) do
        fs:SetText("")
        fs:Show()
    end
    local m = bk and h.MyNext(bk, me)
    local entrant = Contains(st.entrants, me)
    local place = h.Where(occ)
    if m then
        local opp = h.Opp(m, me)
        local round = h.RoundTitle(bk, m.r, m)
        local bo = h.BoOf(bk, m)
        local oppText
        if type(opp) == "string" then
            local cls = EUI():ClassOf(opp)
            local icon = cls and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls]
            local itext = ""
            if icon then
                local c = icon
                itext = ("|T%s:12:12:0:0:256:256:%d:%d:%d:%d|t "):format(UI():Tex("classIcons"), floor(c[1] * 256 + 0.5),
                    floor(c[2] * 256 + 0.5), floor(c[3] * 256 + 0.5), floor(c[4] * 256 + 0.5))
            end
            oppText = itext .. h.Name(opp)
        else
            -- the slot is filled by a match not over yet: its winner (its loser for the 3rd place match)
            local slot = (m.a == me) and "b" or "a"
            local s = h.SlotText(bk, m, slot)
            local loser = (slot == "a" and m.la) or (slot == "b" and m.lb)
            local what = s[1] or ""
            if loser then
                -- ("Loser of Semifinal 1" when its players aren't known yet: it says it already)
                what = what:find("^Loser of ") and ("l" .. what:sub(2)) or ("loser of " .. what)
            else
                what = "winner of " .. what
            end
            oppText = "|cffc8c8c8" .. what .. "|r"
        end
        f.l1:SetText(round .. ": you vs " .. oppText)
        if m.st == "play" then
            f.clockMatch = m
            local game = (m.g or 0) + 1
            local ready = st.ready and st.ready[me]
            local oppReady = type(opp) == "string" and st.ready and st.ready[opp]
            if not ready then
                f.l2:SetText("Your match is on · best of " .. bo)
            elseif not oppReady then
                f.l2:SetText("Waiting for " .. h.Plain(opp) .. " · best of " .. bo)
            else
                f.l2:SetText("Game " .. game .. " · best of " .. bo)
            end
            f.ready:SetShown(not ready)
        elseif m.r == bk.r then
            local p = h.Playing(bk)[1]
            if p then
                -- (" · best of 3" only when the line keeps it on one line: "first to 2" says it too)
                local base = "Up after " .. h.Plain(p.a) .. " vs " .. h.Plain(p.b)
                f.l2:SetText(base .. " · best of " .. bo)
                if H().Width(f.l2) > TRK_W - TRK_IN then f.l2:SetText(base) end
                f.clockMatch = p
            else
                f.l2:SetText("Up next · best of " .. bo)
            end
        else
            local rp = h.RoundPlural(bk, bk.r)
            f.l2:SetText("When " .. (rp == "The final" and "the final is" or (rp:gsub("^%u", string.lower) .. " are"))
                .. " done · best of " .. bo)
        end
        f.l3:SetText(place and ("Meet at " .. place) or "")
        local need = h.Need(bo)
        local mine = (m.a == me) and m.wa or m.wb
        local theirs = (m.a == me) and m.wb or m.wa
        if m.st == "play" or m.st == "wait" then
            f.pips:Set(need, mine or 0)
            f.pips:Show()
            local games = (mine or 0) + (theirs or 0)
            f.pipText:SetText((games > 0 and ((mine or 0) .. "-" .. (theirs or 0) .. " · ") or "") .. "first to " .. need)
        end
    elseif bk and entrant then
        -- no match ahead: through to the next round, out, or done
        local outIn = bk.elim and bk.elim[me]
        if outIn or (bk.out and bk.out[me]) then
            local rp = outIn and h.RoundPlural(bk, outIn)
            f.l1:SetText(rp and ("Out in " .. (rp == "The final" and "the final" or (rp:match("^Round") and rp:lower()
                or ("the " .. rp:lower())))) or "You're out")
            local n = #h.Playing(bk)
            f.l2:SetText(bk.done and "The bracket is done" or (h.RoundPlural(bk, bk.r) .. " · "
                .. (n == 1 and "1 match playing" or (n .. " matches playing"))))
        elseif bk.done then
            f.l1:SetText(bk.champ == me and "|cffffd100You won the bracket!|r" or "The bracket is done")
        else
            f.l1:SetText("Through to the next round")
            f.l2:SetText("Your next match is drawn when this round is done")
        end
    elseif (entrant or Contains(st.signups, me)) and (bk or EUI():StageSub(def, st) == "signing up") then
        local n = #(st.entrants or {})
        f.l1:SetText("You're signed up" .. (n > 0 and (" · " .. n .. " players") or ""))
        local open = EUI():StageSub(def, st) == "signing up"
        f.l2:SetText(open and (bk and "The bracket is drawn when sign-up closes" or "It starts when the sign-up closes") or "")
        f.l3:SetText(place and ("Meet at " .. place) or "")
    end
    -- the host (who doesn't play right now): how it runs, a dispute to settle
    if L():IsHostOf(occ) and not m then
        local n = bk and #h.Playing(bk) or 0
        local disputes = Board():Disputes(st)
        local sub = (bk and EUI():StageSub(def, st)) or (st.stage and ns.EventBlocks:StageName(def, st.stage)) or ""
        f.l1:SetText("You're hosting" .. (sub ~= "" and (" · " .. sub) or ""))
        local players = #(st.entrants or {})
        local parts = { bk and (n == 1 and "1 match playing" or (n .. " matches playing"))
            or ((EUI():StageSub(def, st) == "signing up") and (#h.SignedUp(st) .. " signed up")
            or (players == 1 and "1 player" or (players .. " players"))) }
        if #disputes > 0 then parts[#parts + 1] = "|cffffcf99" .. #disputes .. (#disputes == 1 and " dispute" or " disputes") .. "|r" end
        f.l2:SetText(table.concat(parts, " · "))
        f.l3:SetText("")
        f.board:SetShown(#disputes > 0)
    end
    self:FillPart2(f, occ, st, def, bk)
    -- (the meeting place's arrow says where: the "where" text of the calendar event isn't needed under it)
    if f.mine and f.mine.meet and (f.l3:GetText() or ""):find("^Meet at ") then f.l3:SetText("") end
    -- (part 2's stage line says where it stands: the host's line doesn't repeat the stage)
    if not bk and f.l1:GetText() and f.l1:GetText():find("^You're hosting") then f.l1:SetText("You're hosting") end
    LayTracker(f)
    -- (shown first: the clock ticks only on a shown tracker, and one coming back must not show the last event's time)
    f:Show()
    self:TickClocks()
    Anchor()
end

function T:TickClocks()
    local f = trk
    if not (f and f:IsShown()) then return end
    if f.planned then
        -- (before it starts: the time to its start, under an hour)
        local left = f.planned.at - ServerNow()
        f.clock:SetText((left > 0 and left < 3600) and H().Clock(left) or "")
        f.stage:SetText(StartsText(f.planned.at))
        return
    end
    local m = f.clockMatch
    local st = cur.occ and StateOf(cur.occ)
    if m and st and m.st == "play" then
        f.clock:SetText(H().Clock(Elapsed(cur.occ, st, m)))
    else
        -- (part 2: the time left on the timer the event shows)
        local t = st and H().ShownTimers(cur.occ, st)[1]
        f.clock:SetText(t and H().Clock(t.left) or "")
    end
    if card and card:IsShown() and card.m and st then
        card.ring:Set(NoShow(card.bk) - Elapsed(cur.occ, st, card.m), NoShow(card.bk))
    end
    if waitc and waitc:IsShown() and waitc.m and st then
        waitc.ring:Set(NoShow(waitc.bk) - Elapsed(cur.occ, st, waitc.m), NoShow(waitc.bk), ORANGE)
    end
    -- the anchor can change (quests watched, the minimap moved)
    if f.anchoredTo then
        local qw = _G.QuestWatchFrame or _G.WatchFrame
        local want = (qw and qw:IsVisible() and (GetNumQuestWatches and GetNumQuestWatches() or 0) > 0) and qw or nil
        if (want and f.anchoredTo ~= want) or (not want and f.anchoredTo == qw) then Anchor() end
    end
end

function T:Ready()
    local occ = cur.occ
    if not occ then return false end
    local ok = L():Ready(occ)
    if card then card:Hide() end
    self:Later()
    return ok
end

---------------------------------------------------------------------------
-- The cards in the middle of the screen: match ready, who won, waiting, a game counted
---------------------------------------------------------------------------

-- part 2's prompts on screen: the cards of open asks and the results of closed ones, in the order they came
local p2 = { order = {}, cards = {}, free = {}, results = {}, seen = {}, shownResult = {}, answered = {} }

local banners = {}      -- the "show" banners at the top of the screen (T:Show), the newest first

-- The cards stack in the middle of the screen, top down from above its centre (below the banners when they reach
-- that far); when they don't fit, in two columns side by side (they never overlap).
local function Stack()
    local list = {}
    for _, f in ipairs({ card, ask, waitc, toast }) do if f and f:IsShown() then list[#list + 1] = f end end
    for _, f in ipairs(p2.order) do if f:IsShown() then list[#list + 1] = f end end
    local top = 175
    local sh = (UIParent and UIParent:GetHeight()) or 768
    if not sh or sh <= 0 then sh = 768 end
    -- (the banners' foot, from the screen's top: 150 down, 8 between them)
    local foot = 0
    for _, f in ipairs(banners) do if f:IsShown() then foot = max(foot, 150) + f:GetHeight() + 8 end end
    if foot > 0 then top = min(top, floor(sh / 2 - foot - 4)) end
    local room = sh / 2 + top - 24
    local total = 0
    for i, f in ipairs(list) do total = total + f:GetHeight() + (i > 1 and 10 or 0) end
    local cols = { list }
    if total > room and #list > 1 then
        local a, b, used = {}, {}, 0
        for _, f in ipairs(list) do
            if #a == 0 or used + f:GetHeight() <= room then
                a[#a + 1] = f
                used = used + f:GetHeight() + 10
            else
                b[#b + 1] = f
            end
        end
        cols = { a, b }
    end
    local widths, sum = {}, 0
    for i, c in ipairs(cols) do
        local w = 0
        for _, f in ipairs(c) do w = max(w, f:GetWidth() or 0) end
        widths[i] = w
        sum = sum + w + (i > 1 and 12 or 0)
    end
    local x = -sum / 2
    for i, c in ipairs(cols) do
        local y = top
        local cx = (#cols == 1) and 0 or (x + widths[i] / 2)
        for _, f in ipairs(c) do
            f:ClearAllPoints()
            f:SetPoint("TOP", UIParent, "CENTER", floor(cx + 0.5), y)
            y = y - f:GetHeight() - 10
        end
        x = x + widths[i] + 12
    end
end
T.Stack = function() Stack() end

local function PlayerFace(parent, size, layer)
    local p = {}
    p.halo = parent:CreateTexture(nil, layer or "ARTWORK", nil, 1)
    p.halo:SetTexture(RING)
    p.halo:SetSize(size + 6, size + 6)
    p.cls = parent:CreateTexture(nil, layer or "ARTWORK", nil, 2)
    p.cls:SetSize(size, size)
    p.halo:SetPoint("CENTER", p.cls)
    p.name = H().Text(parent, "GameFontHighlight", 12.5)
    p.name:SetJustifyH("CENTER")
    p.name:SetPoint("TOP", p.cls, "BOTTOM", 0, -6)
    return p
end

local function CreateMatchCard()
    local f = HudCard("DisasterZoneEventMatchCard", CARD_W, 230, { 1, 0.82, 0, 0.55 })
    f.art = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.art:SetPoint("TOPLEFT", 1, -1)
    f.art:SetPoint("TOPRIGHT", -1, -1)
    f.art:SetHeight(64)
    f.fade = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    f.fade:SetAllPoints(f.art)
    Gradient(f.fade, { CARD_TOP[1], CARD_TOP[2], CARD_TOP[3], 0.15 }, { CARD_TOP[1], CARD_TOP[2], CARD_TOP[3], 1 })
    f.ring = H().NewRing(f, 34)
    f.ring:SetPoint("TOPRIGHT", -12, -10)
    f.ring:EnableMouse(true)
    f.ring:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("No-show timer")
        GameTooltip:AddLine("When it runs out, a player who isn't there loses the match.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.ring:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.me = PlayerFace(f, 46)
    f.me.cls:SetPoint("TOP", f, "TOP", -69, -30)
    f.opp = PlayerFace(f, 46)
    f.opp.cls:SetPoint("TOP", f, "TOP", 69, -30)
    f.vs = H().Text(f, "GameFontNormal", 13, GOLD[1], GOLD[2], GOLD[3])
    f.vs:SetJustifyH("CENTER")
    f.vs:SetText("vs")
    f.vs:SetPoint("CENTER", f, "TOP", 0, -48)
    f.kick = H().Text(f, "GameFontNormal", 10.5, GOLD[1], GOLD[2], GOLD[3])
    f.kick:SetJustifyH("CENTER")
    f.kick:SetPoint("TOP", f, "TOP", 0, -122)
    f.kick:SetText("YOUR MATCH IS READY")
    f.text = H().Text(f, "GameFontHighlight", 12, 0.85, 0.85, 0.85)
    f.text:SetJustifyH("CENTER")
    f.text:SetWordWrap(true)
    f.text:SetSpacing(4)
    f.text:SetWidth(CARD_W - 32)
    f.text:SetPoint("TOP", f.kick, "BOTTOM", 0, -6)
    f.go = UI():CreateSleekButton(f, "Ready", 78, 26, function() T:Ready() end, "primary")
    f.later = UI():CreateSleekButton(f, "Need a minute", nil, 26, function()
        if f.key then cardOff[f.key] = true end
        f:Hide()
        Stack()
    end)
    f.later:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Need a minute")
        GameTooltip:AddLine("Closes this card. Ready is on the tracker under the minimap when you're there.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.later:HookScript("OnLeave", function() GameTooltip:Hide() end)
    card = f
    return f
end

function T:ShowMatchCard(occ, st, def, bk, m)
    local f = card or CreateMatchCard()
    local h = H()
    local me = Me()
    local opp = h.Opp(m, me)
    f.m, f.bk, f.key = m, bk, occ .. ":" .. m.id
    EUI():SetArt(f.art, def and def.art, CARD_W - 2, 64, 0.5, 0.58, 0.7)
    h.SetClass(f.me.cls, me)
    f.me.halo:SetVertexColor(0.4, 0.72, 1, 0.95)
    f.me.name:SetText("|cff66b8ffYou|r")
    h.SetClass(f.opp.cls, opp)
    f.opp.halo:SetVertexColor(1, 1, 1, 0.22)
    h.Fit(f.opp.name, h.Name(opp), 120, 12.5, 10)
    local bo = h.BoOf(bk, m)
    local place = h.Place(occ)
    -- ("at the Ring of Trials", "at Shattrath")
    local at = place and (" at " .. ((place:find(" of ") and not place:find("^[Tt]he ")) and "the " or "") .. place) or ""
    f.text:SetText(("Best of %d. Find %s%s and challenge them to a duel. Each duel counts by itself."):format(bo,
        h.Plain(opp), at))
    local th = f.text:GetStringHeight() or 34
    local by = 122 + 13 + 6 + th + 12
    local gw = f.go:GetWidth() + 6 + f.later:GetWidth()
    f.later:SetWidth(floor((f.later:GetFontString():GetStringWidth() or 90) + 28))
    gw = f.go:GetWidth() + 6 + f.later:GetWidth()
    f.go:ClearAllPoints()
    f.go:SetPoint("TOPLEFT", f, "TOP", -gw / 2, -by)
    f.later:ClearAllPoints()
    f.later:SetPoint("LEFT", f.go, "RIGHT", 6, 0)
    f:SetHeight(floor(by + 26 + 14 + 0.5))
    f.ring:Set(NoShow(bk) - Elapsed(occ, st, m), NoShow(bk))
    local was = f:IsShown()
    f:Show()
    Stack()
    if not was then Snd("READY_CHECK") end
end

---------------------------------------------------------------------------

local function CreateToast()
    local f = HudCard("DisasterZoneEventToast", 260, 78)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(22, 22)
    f.icon:SetPoint("TOPLEFT", 14, -13)
    f.t = H().Text(f, "GameFontHighlight", 13, 1, 1, 1)
    f.t:SetPoint("TOPLEFT", 46, -12)
    f.s = H().Text(f, "GameFontHighlightSmall", 11, 0.62, 0.62, 0.62)
    f.s:SetPoint("TOPLEFT", f.t, "BOTTOMLEFT", 0, -3)
    f.pips = H().NewPips(f, 9, 4, 0.5)
    f.pips:SetPoint("RIGHT", f, "TOPRIGHT", -14, -24)
    f.l = H().Text(f, "GameFontHighlightSmall", 11, 0.81, 0.81, 0.81)
    f.l:SetPoint("TOPLEFT", 14, -52)
    f:SetScript("OnUpdate", function(self, dt)
        self.left = (self.left or 0) - dt
        if self.left <= 0 and not self:IsMouseOver() then
            self:Hide()
            Stack()
        end
    end)
    toast = f
    return f
end

-- A game of my match counted: won (true / false), m (after the game), how ("players" | "host" | nil).
function T:ShowGameToast(occ, bk, m, won, how)
    local f = toast or CreateToast()
    local h = H()
    local me = Me()
    local opp = h.Opp(m, me)
    local mine = (m.a == me) and m.wa or m.wb
    local theirs = (m.a == me) and m.wb or m.wa
    local game = (m.wa or 0) + (m.wb or 0)
    f.icon:SetTexture(won and CHECK or CROSS)
    if won then f.icon:SetVertexColor(1, 1, 1, 1) else f.icon:SetVertexColor(0.85, 0.85, 0.85, 0.9) end
    f.t:SetText("Game " .. game .. " · you " .. (won and "won" or "lost"))
    f.s:SetText(how == "host" and "The host decided it" or (how == "players" and "You two agreed on it" or "Both games saw the duel"))
    local need = h.Need(h.BoOf(bk, m))
    f.pips:Set(need, mine)
    local tail
    if mine >= need then tail = "you take the match"
    elseif theirs >= need then tail = h.Plain(opp) .. " takes the match"
    elseif mine == need - 1 and theirs == need - 1 then tail = "the next game decides"
    elseif mine == need - 1 then tail = "one more win takes the match"
    elseif theirs == need - 1 then tail = h.Plain(opp) .. " needs one more"
    else tail = "first to " .. need end
    h.Fit(f.l, mine .. "-" .. theirs .. " · " .. tail, 260 - 28, 11, 9)
    h.Fit(f.t, f.t:GetText(), 260 - 46 - 14 - (f.pips:GetWidth() or 22) - 8, 13, 11)
    f.left = 7
    f:Show()
    Stack()
end

---------------------------------------------------------------------------

local function CreateAsk()
    local f = HudCard("DisasterZoneEventAsk", ASK_W, 130)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(14, 14)
    f.icon:SetTexture(WARN)
    f.icon:SetPoint("TOPLEFT", 14, -12)
    f.t = H().Text(f, "GameFontHighlight", 13, 1, 0.81, 0.6)
    f.t:SetPoint("LEFT", f.icon, "RIGHT", 7, 0)
    f.p = H().Text(f, "GameFontHighlightSmall", 11, 0.81, 0.81, 0.81)
    f.p:SetWordWrap(true)
    f.p:SetSpacing(2)
    f.p:SetWidth(ASK_W - 28)
    f.p:SetPoint("TOPLEFT", 14, -31)
    f.b = {}
    for i = 1, 2 do
        local b = UI():CreateSleekButton(f, "", (ASK_W - 36) / 2, 44, function(self) T:Answer(self.key) end)
        b.cls = b:CreateTexture(nil, "ARTWORK")
        b.cls:SetSize(24, 24)
        local fs = b:GetFontString()
        H().Sized(fs, 12)
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", 16, 0)
        b.cls:SetPoint("RIGHT", fs, "LEFT", -8, 0)
        f.b[i] = b
    end
    ask = f
    return f
end

function T:ShowAsk(occ, st, bk, a)
    local f = ask or CreateAsk()
    local h = H()
    local me = Me()
    f.occ, f.a = occ, a
    -- (the ask's own bracket: an event can have more than one)
    local abk = (a.b and st and st.blocks and type(st.blocks[a.b]) == "table" and st.blocks[a.b].m) and st.blocks[a.b] or bk
    local m = abk and a.match and abk.m[a.match]
    local opp = m and h.Opp(m, me) or nil
    if not opp then
        for _, k in ipairs(a.opts or {}) do if k ~= me then opp = k end end
    end
    f.t:SetText(a.q or ("Who won game " .. (a.g or 1) .. "?"))
    f.p:SetText(("Your game and %s's saw different winners. Pick what happened; if you two disagree, the host decides.")
        :format(h.Plain(opp)))
    local ph = f.p:GetStringHeight() or 30
    local by = 31 + ph + 12
    local opts = { me, opp }
    for i = 1, 2 do
        local b = f.b[i]
        local k = opts[i]
        b.key = k
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + (i - 1) * ((ASK_W - 36) / 2 + 8), -by)
        h.SetClass(b.cls, k)
        local fs = b:GetFontString()
        if i == 1 then
            b:SetText("|cff66b8ffI won|r")
            h.Sized(fs, 12)
        else
            local tw = (ASK_W - 36) / 2 - 24 - 8 - 20
            local won = h.Name(k):gsub("|r$", " won|r")
            if not h.Fit(fs, won, tw, 12, 11) then h.Fit(fs, h.Name(k), tw, 12, 10) end
        end
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", 16, 0)
    end
    f:SetHeight(floor(by + 44 + 14 + 0.5))
    local was = f:IsShown()
    f:Show()
    Stack()
    if not was then Snd("RAID_WARNING") end
end

function T:Answer(key)
    local f = ask
    if not (f and f.a and f.occ) then return false end
    local ok = L():AnswerAsk(f.occ, f.a.id, key)
    answered[f.occ .. ":" .. f.a.id] = true
    f:Hide()
    Stack()
    return ok
end

---------------------------------------------------------------------------

local function CreateWait()
    local f = HudCard("DisasterZoneEventWait", 260, 92)
    f.cls = f:CreateTexture(nil, "ARTWORK")
    f.cls:SetSize(30, 30)
    f.cls:SetPoint("TOPLEFT", 14, -12)
    f.t = H().Text(f, "GameFontHighlight", 13, 1, 1, 1)
    f.t:SetPoint("TOPLEFT", 54, -12)
    f.s = H().Text(f, "GameFontHighlightSmall", 11, 0.62, 0.62, 0.62)
    f.s:SetWordWrap(true)
    f.s:SetWidth(150)
    f.s:SetPoint("TOPLEFT", f.t, "BOTTOMLEFT", 0, -3)
    f.ring = H().NewRing(f, 34)
    f.ring:SetPoint("TOPRIGHT", -14, -10)
    f.wh = UI():CreateSleekButton(f, "Whisper", nil, 22, function() Whisper(f.opp) end)
    local fs = f.wh:GetFontString()
    H().Sized(fs, 11)
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", 8, 0)
    f.wh.icon = f.wh:CreateTexture(nil, "ARTWORK")
    f.wh.icon:SetSize(12, 12)
    EUI():Glyph(f.wh.icon, UI().ICON.whisper, 1, 1, 1, 0.85)
    f.wh.icon:SetPoint("RIGHT", fs, "LEFT", -6, 0)
    f.wh:SetWidth(floor(10 + 12 + 6 + (fs:GetStringWidth() or 44) + 12))
    waitc = f
    return f
end

function T:ShowWait(occ, st, bk, m)
    local f = waitc or CreateWait()
    local h = H()
    local opp = h.Opp(m, Me())
    f.m, f.bk, f.opp = m, bk, opp
    h.SetClass(f.cls, opp)
    h.Fit(f.t, "Waiting for " .. h.Name(opp), 260 - 54 - 56, 13, 10)
    f.s:SetText("After " .. ns.EventBlocks:DurationText(NoShow(bk)) .. " the match is yours")
    local sh = f.s:GetStringHeight() or 13
    local by = max(12 + 34, 12 + 16 + 3 + sh) + 12
    f.wh:ClearAllPoints()
    f.wh:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -by)
    f:SetHeight(floor(by + 22 + 12 + 0.5))
    f.ring:Set(NoShow(bk) - Elapsed(occ, st, m), NoShow(bk), ORANGE)
    f:Show()
    Stack()
end

---------------------------------------------------------------------------
-- Part 2's asks (mockup shot 23): a card for each ask put to me, with its time ring: pick players (their class
-- circles, Inspect), a choice, a typed answer, 1 to 10, yes / no; and the result once it closes.
---------------------------------------------------------------------------

local ASK_W = { player = 392, text = 332, number = 320, yesno = 232, choice = 300 }
local TEAL3 = { 0.337, 0.839, 0.941 }
local MAX_ASKS, MAX_RESULTS = 3, 2

-- My answer reaches the run (the practice run's own input for the builder's practice).
function T:AnswerAsk2(occ, aid, v)
    if Board().DemoKinds and Board():DemoKinds(occ) then return false end
    if occ == "practice" then
        if L().PracticeAnswer then L():PracticeAnswer(Me(), aid, v) end
        self:Later()
        return true
    end
    local ok = L().AnswerAsk2 and L():AnswerAsk2(occ, aid, v) or false
    self:Later()
    return ok
end

-- I press a button the event gave me.
function T:Press(occ, label)
    if not (occ and label) then return false end
    if Board().DemoKinds and Board():DemoKinds(occ) then
        ns:Print("Demo mode: the event's buttons are only for show here.")
        return false
    end
    if occ == "practice" then
        if L().PracticePress then L():PracticePress(Me(), label) end
        self:Later()
        return true
    end
    local ok = L().Press and L():Press(occ, label) or false
    if not ok then ns:Print("%s isn't yours to press any more.", label) end
    self:Later()
    return ok
end

-- Inspect a player: the game inspects the ones I target or group with.
local function UnitOfKey(key)
    local short = ns.Util.ShortName(key)
    for _, u in ipairs({ "target", "mouseover", "focus" }) do
        if UnitExists and UnitExists(u) and UnitName(u) == short then return u end
    end
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    local raid = IsInRaid and IsInRaid()
    for i = 1, n do
        local u = raid and ("raid" .. i) or ("party" .. i)
        if UnitName and UnitName(u) == short then return u end
    end
    return nil
end

function T:Inspect(key)
    if type(key) ~= "string" then return false end
    local u = UnitOfKey(key)
    if u and InspectUnit and (not CanInspect or CanInspect(u)) then
        InspectUnit(u)
        return true
    end
    ns:Print("Target %s to inspect them (the game inspects players you target or group with, up close).", H().Plain(key))
    return false
end

local function Kicker(parent)
    local fs = H().Text(parent, "GameFontNormal", 10.5, GOLD[1], GOLD[2], GOLD[3])
    return fs
end

-- The card of an ask: the art strip, the ring, the kicker and the question. kind: player | choice | text | number |
-- yesno.
local function NewAskCard(kind)
    local w = ASK_W[kind] or 320
    p2.made = (p2.made or 0) + 1
    local f = HudCard("DisasterZoneEventPrompt" .. p2.made, w, 200, { 1, 0.82, 0, 0.55 })
    f.kind = kind
    f.withArt = kind == "player" or kind == "text" or kind == "number"
    f.art = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.art:SetPoint("TOPLEFT", 1, -1)
    f.art:SetPoint("TOPRIGHT", -1, -1)
    f.art:SetHeight(56)
    f.fade = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    f.fade:SetAllPoints(f.art)
    Gradient(f.fade, { CARD_TOP[1], CARD_TOP[2], CARD_TOP[3], 0 }, { CARD_TOP[1], CARD_TOP[2], CARD_TOP[3], 1 })
    f.art:SetShown(f.withArt)
    f.fade:SetShown(f.withArt)
    f.ring = H().NewRing(f, 34)
    f.ring:SetPoint("TOPRIGHT", -12, -10)
    f.ring:SetFrameLevel(f:GetFrameLevel() + 3)
    f.ring:EnableMouse(true)
    f.ring:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Time to answer")
        GameTooltip:AddLine("The card closes by itself when it runs out, or when everyone asked has answered.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.ring:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.kick = Kicker(f)
    f.q = H().Text(f, "GameFontHighlight", 15, 1, 1, 1)
    f.q:SetWordWrap(true)
    f.q:SetSpacing(3)
    f.foot = H().Text(f, "GameFontHighlightSmall", 11, 0.62, 0.62, 0.62)
    f.tiles, f.nums, f.opts = {}, {}, {}
    if kind == "player" then
        f.pips = H().NewPips(f, 9, 4, 0.45)
        f.send = UI():CreateSleekButton(f, "Send votes", nil, 26, function() T:SendPicks(f) end, "primary")
        f.prev = UI():CreateArrowButton(f, false, 20, 20, function() f.page = max(1, (f.page or 1) - 1); T:LayAsk(f) end)
        f.next = UI():CreateArrowButton(f, true, 20, 20, function() f.page = (f.page or 1) + 1; T:LayAsk(f) end)
        f.pageFs = H().Text(f, "GameFontHighlightSmall", 10.5, 0.62, 0.62, 0.62)
    elseif kind == "text" then
        f.eb = UI():CreateSleekEditBox(f, w - 32 - 6 - 84, 30, "GameFontHighlight")
        f.eb:SetMaxLetters(120)
        f.eb:SetScript("OnEnterPressed", function() T:SendText(f) end)
        f.eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        UI():SetEditPlaceholder(f.eb, "Your answer")
        f.send = UI():CreateSleekButton(f, "Answer", 84, 30, function() T:SendText(f) end, "primary")
    elseif kind == "number" then
        f.cand = {}
        f.cand.cls = f:CreateTexture(nil, "ARTWORK")
        f.cand.cls:SetSize(34, 34)
        f.cand.name = H().Text(f, "GameFontHighlight", 13)
        f.cand.sub = H().Text(f, "GameFontHighlightSmall", 11, 0.62, 0.62, 0.62)
        f.cand.ins = UI():CreateSleekButton(f, "Inspect", nil, 22, function() T:Inspect(f.cand.key) end)
        H().Sized(f.cand.ins:GetFontString(), 11)
        f.cand.ins:SetWidth(floor(H().Width(f.cand.ins:GetFontString()) + 22))
        for i = 1, 10 do
            local b = UI():CreateSleekButton(f, tostring(i), 26, 28, function(self)
                f.pick = self.n
                T:LayAsk(f)
            end)
            b.n = i
            EUI():Narrow(b:GetFontString(), 14)
            f.nums[i] = b
        end
        f.send = UI():CreateSleekButton(f, "Send", nil, 26, function() T:SendNumber(f) end, "primary")
    end
    f:SetScript("OnHide", function(self) if self.eb then self.eb:ClearFocus() end end)
    f.tk = 0
    f:SetScript("OnUpdate", function(self, dt)
        self.tk = self.tk + dt
        if self.tk < 0.5 then return end
        self.tk = 0
        T:TickAsk(self)
    end)
    return f
end

local function Tile(f, i)
    local t = f.tiles[i]
    if not t then
        t = CreateFrame("Button", nil, f)
        t:SetSize(116, 96)
        t.bg = t:CreateTexture(nil, "BACKGROUND")
        t.bg:SetAllPoints()
        UI():AddEdges(t, "BORDER", true)
        t.halo = t:CreateTexture(nil, "ARTWORK", nil, 1)
        t.halo:SetTexture(RING)
        t.halo:SetSize(38, 38)
        t.halo:SetPoint("TOP", 0, -6)
        t.halo:SetVertexColor(1, 0.82, 0, 0.9)
        t.cls = t:CreateTexture(nil, "ARTWORK", nil, 2)
        t.cls:SetSize(32, 32)
        t.cls:SetPoint("TOP", 0, -9)
        t.name = H().Text(t, "GameFontHighlight", 12)
        t.name:SetJustifyH("CENTER")
        t.name:SetPoint("TOP", t.cls, "BOTTOM", 0, -6)
        t.chk = H().Disc(t, "OVERLAY", 1, 15, 1, 0.82, 0, 1)
        t.chk:SetPoint("TOPRIGHT", -6, -6)
        t.chkMark = t:CreateTexture(nil, "OVERLAY", nil, 2)
        t.chkMark:SetTexture(CHECK)
        t.chkMark:SetSize(12, 12)
        t.chkMark:SetPoint("CENTER", t.chk)
        t.chkMark:SetVertexColor(0.16, 0.11, 0, 1)
        t.ins = UI():CreateSleekButton(t, "Inspect", nil, 22, function(self) T:Inspect(self:GetParent().key) end)
        H().Sized(t.ins:GetFontString(), 11)
        t.ins:SetWidth(floor(H().Width(t.ins:GetFontString()) + 22))
        t.ins:SetPoint("BOTTOM", 0, 8)
        t.you = H().Text(t, "GameFontHighlightSmall", 11, 0.62, 0.62, 0.62)
        t.you:SetJustifyH("CENTER")
        t.you:SetPoint("BOTTOM", 0, 12)
        t.you:SetText("that's you")
        t:SetScript("OnClick", function(self) T:TogglePick(f, self.key) end)
        f.tiles[i] = t
    end
    return t
end

local function Has(list, v)
    for i = 1, #(list or {}) do if list[i] == v then return i end end
    return nil
end

-- The player "on the stage" of a 1 to 10 ask: one of the event's players named in its question (a player variable's
-- value first).
local function OnStage(st, def, q)
    q = tostring(q or "")
    if q == "" then return nil end
    local function named(k)
        local n = H().Plain(k)
        return type(n) == "string" and #n >= 2 and q:find(n, 1, true) ~= nil
    end
    for _, v in ipairs(def.vars or {}) do
        local k = st.vars and st.vars[v.n]
        if v.t == "player" and type(k) == "string" and named(k) then return k end
    end
    for _, k in ipairs(st.entrants or {}) do if named(k) then return k end end
    return nil
end

local function Upper(s) return (tostring(s or ""):upper()) end

-- The kicker over the question: "BEST OUTFIT · PICK 3", "TRIVIA NIGHT · QUESTION 4 OF 10", "JUDGES' SCORE · 1 TO 10".
local function KickerText(a, def, st)
    local name = Upper(a.n or "Ask")
    if a.kind == "player" then return name .. " · PICK " .. (a.votes or 1) end
    if a.kind == "number" then return name .. " · 1 TO 10" end
    if a.kind == "choice" then return name .. " · PICK ONE" end
    if a.kind == "text" then
        local q = st.qa and st.qa[a.id]
        local item = q and type(q.item) == "table" and q.item
        local l = item and type(def.lists) == "table" and def.lists[item.ql]
        if l and type(l.items) == "table" then
            return Upper(def.name or "") .. " · QUESTION " .. (item.qi or 1) .. " OF " .. #l.items
        end
        return name
    end
    return Upper(def.name or name)
end

-- Lays an ask's card out for its kind; f.a = the ask (Live:MyAsks's), f.occ, f.st, f.def.
function T:LayAsk(f)
    local a, st, def = f.a, f.st, f.def
    local h = H()
    local w = f:GetWidth()
    local me = Me()
    if f.withArt then EUI():SetArt(f.art, def.art, w - 2, 56, 0.5, 0.55, 0.7) end
    local y = f.withArt and 64 or 12
    f.kick:ClearAllPoints()
    f.kick:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -y)
    h.Fit(f.kick, KickerText(a, def, st), w - 32 - (f.withArt and 0 or 46), 10.5, 9)
    y = y + 16
    f.q:ClearAllPoints()
    f.q:SetWidth(w - 32 - (f.withArt and 0 or 46))
    f.q:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -y)
    f.q:SetText(a.q and a.q ~= "" and a.q or (a.n or "Your answer"))
    y = y + (f.q:GetStringHeight() or 20) + 12
    local kind = f.kind
    if kind == "player" then
        local players = a.players or {}
        -- me too (that's me), when I'm among who could be picked by the others
        local list = {}
        for _, k in ipairs(players) do list[#list + 1] = k end
        if not a.self and Has(st.entrants, me) and not Has(list, me) then list[#list + 1] = me end
        local per = 9
        local pages = max(1, ceil(#list / per))
        f.page = min(max(1, f.page or 1), pages)
        local first = (f.page - 1) * per
        local tw = floor((w - 32 - 12) / 3)
        local n = 0
        for i = 1, min(per, #list - first) do
            local k = list[first + i]
            n = n + 1
            local t = Tile(f, n)
            t.key = k
            t:SetSize(tw, 96)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + ((n - 1) % 3) * (tw + 6), -(y + floor((n - 1) / 3) * 102))
            local mine = ns.Util.IsMe(k) and not a.self
            local on = Has(f.picks, k) ~= nil
            h.SetClass(t.cls, k)
            h.Fit(t.name, h.Name(k), tw - 8, 12, 10)
            t.halo:SetShown(on)
            t.chk:SetShown(on)
            t.chkMark:SetShown(on)
            t.ins:SetShown(not mine)
            t.you:SetShown(mine)
            t:SetAlpha(mine and 0.7 or 1)
            if on then
                t.bg:SetColorTexture(1, 0.82, 0, 0.07)
                UI():SetEdgeColor(t, 1, 0.82, 0, 0.75)
            else
                t.bg:SetColorTexture(1, 1, 1, 0.03)
                UI():SetEdgeColor(t, 1, 1, 1, 0.09)
            end
            t:Show()
        end
        for i = n + 1, #f.tiles do f.tiles[i]:Hide() end
        y = y + ceil(max(1, n) / 3) * 102 - 6
        -- pages of nine
        if pages > 1 then
            f.prev:ClearAllPoints()
            f.pageFs:SetText(f.page .. " of " .. pages)
            f.pageFs:ClearAllPoints()
            f.pageFs:SetPoint("TOP", f, "TOP", 0, -(y + 10))
            f.prev:SetPoint("RIGHT", f.pageFs, "LEFT", -6, 0)
            f.next:ClearAllPoints()
            f.next:SetPoint("LEFT", f.pageFs, "RIGHT", 6, 0)
            f.prev:Show(); f.next:Show(); f.pageFs:Show()
            y = y + 30
        else
            f.prev:Hide(); f.next:Hide(); f.pageFs:Hide()
        end
        -- the footer: my picks, Send votes
        local votes = a.votes or 1
        y = y + 12
        local picked = #(f.picks or {})
        local fx = 16
        if votes > 1 then
            f.pips:Set(votes, picked)
            f.pips:ClearAllPoints()
            f.pips:SetPoint("LEFT", f, "TOPLEFT", 16, -(y + 13))
            f.pips:Show()
            fx = 16 + f.pips:GetWidth() + 8
        else
            f.pips:Hide()
        end
        f.send:SetText(votes > 1 and "Send votes" or "Send vote")
        f.send:SetWidth(floor(H().Width(f.send:GetFontString()) + 28))
        f.send:ClearAllPoints()
        f.send:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -y)
        local foot = f.hint or ((votes > 1 and (picked .. " of " .. votes .. " picked") or (picked > 0 and ("Your pick: "
            .. h.Plain(f.picks[1])) or "Pick one")) .. (a.secret and " · counts stay hidden" or ""))
        f.foot:ClearAllPoints()
        f.foot:SetPoint("LEFT", f, "TOPLEFT", fx, -(y + 13))
        h.Fit(f.foot, foot, w - fx - 16 - f.send:GetWidth() - 8, 11, 9.5)
        f.foot:Show()
        y = y + 26 + 14
    elseif kind == "text" then
        f.eb:ClearAllPoints()
        f.eb:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -y)
        f.send:ClearAllPoints()
        f.send:SetPoint("LEFT", f.eb, "RIGHT", 6, 0)
        y = y + 30 + 10
        local item = st.qa and st.qa[a.id] and type(st.qa[a.id].item) == "table"
        f.foot:ClearAllPoints()
        f.foot:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -y)
        h.Sized(f.foot, 10.5)
        f.foot:SetText(f.hint or (item and "Capitals and spaces don't matter" or "Type your answer, then Answer"))
        f.foot:Show()
        y = y + 14 + 14
    elseif kind == "number" then
        local k = OnStage(st, def, a.q)
        f.cand.key = k
        if k then
            f.cand.cls:ClearAllPoints()
            f.cand.cls:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -y)
            h.SetClass(f.cand.cls, k)
            f.cand.name:ClearAllPoints()
            f.cand.name:SetPoint("TOPLEFT", f.cand.cls, "TOPRIGHT", 10, -2)
            h.Fit(f.cand.name, h.Name(k), w - 32 - 44 - f.cand.ins:GetWidth() - 8, 13, 11)
            f.cand.sub:ClearAllPoints()
            f.cand.sub:SetPoint("TOPLEFT", f.cand.name, "BOTTOMLEFT", 0, -3)
            f.cand.sub:SetText("on the stage now")
            f.cand.ins:ClearAllPoints()
            f.cand.ins:SetPoint("RIGHT", f, "TOPRIGHT", -16, -(y + 17))
            for _, x in ipairs({ f.cand.cls, f.cand.name, f.cand.sub, f.cand.ins }) do x:Show() end
            y = y + 34 + 10
        else
            for _, x in ipairs({ f.cand.cls, f.cand.name, f.cand.sub, f.cand.ins }) do x:Hide() end
        end
        local bw = (w - 32 - 9 * 3) / 10
        for i, b in ipairs(f.nums) do
            b:SetSize(floor(bw), 28)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", f, "TOPLEFT", floor(16 + (i - 1) * (bw + 3) + 0.5), -y)
            b:SetKind(f.pick == i and "chosen" or "secondary")
        end
        y = y + 28 + 12
        f.send:SetText(f.pick and ("Send " .. f.pick) or "Send")
        f.send:SetWidth(floor(H().Width(f.send:GetFontString()) + 28))
        f.send:ClearAllPoints()
        f.send:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -y)
        f.foot:ClearAllPoints()
        f.foot:SetPoint("LEFT", f, "TOPLEFT", 16, -(y + 13))
        h.Fit(f.foot, f.hint or (a.secret and "Counts stay hidden until it closes" or "Pick a number, then send it"),
            w - 32 - f.send:GetWidth() - 8, 11, 9.5)
        f.foot:Show()
        y = y + 26 + 14
    else
        -- yes / no, a choice: a button each (answering at once)
        local choices = kind == "yesno" and { "Yes", "No" } or (a.choices or {})
        local cols = 2
        local bh = kind == "yesno" and 40 or 34
        -- (long choices: one a row; longer still, on two lines in a taller button: never cut)
        local wrap = false
        if kind ~= "yesno" then
            f.measure = f.measure or H().Text(f, "GameFontHighlight", 10)
            local widest = 0
            for _, c in ipairs(choices) do
                f.measure:SetText(tostring(c))
                widest = max(widest, H().Width(f.measure))
            end
            f.measure:SetText("")
            if widest > floor((w - 28 - 8) / 2) - 12 then cols = 1 end
            if widest > (w - 28) - 16 then wrap, bh = true, 46 end
        end
        local bw = floor((w - 28 - 8 * (cols - 1)) / cols)
        for i, c in ipairs(choices) do
            local b = f.opts[i]
            if not b then
                b = UI():CreateSleekButton(f, "", bw, bh, function(self) T:SendChoice(f, self.value) end)
                f.opts[i] = b
            end
            b.value = (kind == "yesno") and (i == 1) or c
            b:SetSize(bw, bh)
            local fs = b:GetFontString()
            fs:SetWordWrap(wrap)
            if wrap then
                H().Sized(fs, 11)
                fs:SetWidth(bw - 16)
                fs:SetText(tostring(c))
            else
                fs:SetWidth(bw - 12)
                h.Fit(fs, tostring(c), bw - 12, 12.5, 10)
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + ((i - 1) % cols) * (bw + 8), -(y + floor((i - 1) / cols) * (bh + 8)))
            b:Show()
        end
        for i = #choices + 1, #f.opts do f.opts[i]:Hide() end
        y = y + ceil(max(1, #choices) / cols) * (bh + 8) - 8 + 14
        if f.hint then
            f.foot:ClearAllPoints()
            f.foot:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -(y - 6))
            h.Fit(f.foot, f.hint, w - 28, 11, 9.5)
            f.foot:Show()
            y = y + 16
        else
            f.foot:Hide()
        end
    end
    f:SetHeight(floor(y + 0.5))
    self:TickAsk(f)
end

function T:TickAsk(f)
    local a = f.a
    if not a then return end
    local now = H().Now(f.occ)
    local total = max(1, (tonumber(a.ends) or now) - (tonumber(a.at) or now))
    f.ring:Set((tonumber(a.ends) or now) - now, total, f.kind == "text" and TEAL3 or nil)
end

-- Picks on the catwalk: one more (up to the ask's votes; one vote: that one), or one less.
function T:TogglePick(f, key)
    local a = f.a
    if not (a and key) then return end
    if ns.Util.IsMe(key) and not a.self then
        f.hint = "You can't vote for yourself"
        self:LayAsk(f)
        return
    end
    f.picks = f.picks or {}
    local i = Has(f.picks, key)
    local votes = a.votes or 1
    f.hint = nil
    if i then
        table.remove(f.picks, i)
    elseif votes == 1 then
        f.picks = { key }
    elseif #f.picks >= votes then
        f.hint = "That's " .. votes .. " picked: click one to drop it"
    else
        f.picks[#f.picks + 1] = key
    end
    self:LayAsk(f)
end

local function Sent(f, ok, why)
    if ok then
        p2.cards[f.key] = nil
        p2.answered[f.key] = true
        f:Hide()
        Stack()
    else
        f.hint = why or "That answer wasn't taken (the ask may be over)"
        T:LayAsk(f)
    end
end

function T:SendPicks(f)
    local a = f.a
    local picks = f.picks or {}
    if #picks == 0 then
        f.hint = (a.votes or 1) > 1 and "Pick up to " .. a.votes .. " players first" or "Pick a player first"
        self:LayAsk(f)
        return false
    end
    local v = (a.votes or 1) > 1 and picks or picks[1]
    local ok = self:AnswerAsk2(f.occ, a.id, v)
    Sent(f, ok)
    return ok
end

function T:SendText(f)
    local text = (f.eb:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        f.hint = "Type an answer first"
        self:LayAsk(f)
        return false
    end
    local ok = self:AnswerAsk2(f.occ, f.a.id, text)
    if ok then f.eb:SetText("") end
    Sent(f, ok)
    return ok
end

function T:SendNumber(f)
    if not f.pick then
        f.hint = "Pick a number from 1 to 10 first"
        self:LayAsk(f)
        return false
    end
    local ok = self:AnswerAsk2(f.occ, f.a.id, f.pick)
    Sent(f, ok)
    return ok
end

function T:SendChoice(f, v)
    local ok = self:AnswerAsk2(f.occ, f.a.id, v)
    Sent(f, ok)
    return ok
end

-- The asks open for me in the events I'm in (and the practice run's): { { occ, st, def, a } }, oldest first.
function T:OpenAsks()
    local out = {}
    local function add(occ)
        if not L().MyAsks then return end
        local st, def = StateOf(occ)
        if not (st and def) then return end
        for _, a in ipairs(L():MyAsks(occ) or {}) do
            if not a.answered then out[#out + 1] = { occ = occ, st = st, def = def, a = a } end
        end
    end
    if not DemoOn() then
        for _, occ in ipairs(L():GetLiveList() or {}) do add(occ) end
    end
    if L().GetPractice and L():GetPractice() then add("practice") end
    return out
end

local function AskKey(occ, a) return tostring(occ) .. ":" .. tostring(a.id) .. "@" .. tostring(a.at or 0) end

-- The cards follow the open asks: a new one opens, an answered or closed one goes (then its result comes).
function T:RefreshAsks()
    p2.answered = p2.answered or {}
    local want = {}
    local list = self:OpenAsks()
    for _, e in ipairs(list) do
        local key = AskKey(e.occ, e.a)
        if not p2.answered[key] and #want < MAX_ASKS then
            want[key] = true
            want[#want + 1] = key
            local f = p2.cards[key]
            if not f then
                local kind = ASK_W[e.a.kind] and e.a.kind or "choice"
                local pool = p2.free[kind]
                f = pool and table.remove(pool) or NewAskCard(kind)
                f.picks, f.pick, f.hint, f.page = nil, nil, nil, 1
                if f.eb then f.eb:SetText("") end
                p2.cards[key] = f
                p2.order[#p2.order + 1] = f
                Snd("RAID_WARNING")
            end
            f.key, f.occ, f.st, f.def, f.a = key, e.occ, e.st, e.def, e.a
            self:LayAsk(f)
            f:Show()
            -- (its result once it closes)
            p2.seen[key] = { occ = e.occ, aid = e.a.id, at = e.a.at }
        end
    end
    for key, f in pairs(p2.cards) do
        if not want[key] then
            p2.cards[key] = nil
            f:Hide()
        end
    end
    -- the cards no longer up go back to their pool
    for i = #p2.order, 1, -1 do
        local f = p2.order[i]
        if not f:IsShown() then
            table.remove(p2.order, i)
            if f.kind and not f.isResult then
                p2.free[f.kind] = p2.free[f.kind] or {}
                table.insert(p2.free[f.kind], f)
            end
        end
    end
    self:RefreshResults()
    Stack()
end

---------------------------------------------------------------------------
-- An ask's result (it closed): the most picked, the counts, what I said
---------------------------------------------------------------------------

local RESULT_W, RESULT_FOR = 320, 15

local function tsortr(list)
    table.sort(list, function(x, y)
        local a, b = tonumber(x.q.closed) or 0, tonumber(y.q.closed) or 0
        if a ~= b then return a < b end
        return tostring(x.s.aid) < tostring(y.s.aid)
    end)
end

local function NewResult()
    p2.madeR = (p2.madeR or 0) + 1
    local f = HudCard("DisasterZoneEventResult" .. p2.madeR, RESULT_W, 200, { 0.47, 0.47, 0.51, 0.75 })
    f.isResult = true
    f.kick = Kicker(f)
    f.kick:SetPoint("TOPLEFT", 14, -12)
    f.badge = EUI():CreateBadge(f, 30)
    f.badge:SetPoint("TOPLEFT", 12, -30)
    f.badge.noTip = true
    f.cls = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.cls:SetSize(30, 30)
    f.cls:SetPoint("CENTER", f.badge)
    f.clsRing = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.clsRing:SetTexture(EUI().RING)
    f.clsRing:SetSize(36, 36)
    f.clsRing:SetPoint("CENTER", f.cls)
    f.clsRing:SetVertexColor(1, 0.82, 0, 0.9)
    f.head = H().Text(f, "GameFontHighlight", 13, 1, 1, 1)
    f.head:SetPoint("TOPLEFT", f, "TOPLEFT", 58, -36)
    f.sub = H().Text(f, "GameFontHighlightSmall", 10.5, 0.62, 0.62, 0.62)
    f.sub:SetPoint("TOPLEFT", f.head, "BOTTOMLEFT", 0, -3)
    f.rows = {}
    f.mine = CreateFrame("Frame", nil, f)
    f.mine:SetHeight(30)
    f.mine.bg = f.mine:CreateTexture(nil, "BACKGROUND")
    f.mine.bg:SetAllPoints()
    f.mine.bg:SetColorTexture(0.4, 0.72, 1, 0.07)
    UI():AddEdges(f.mine, "BORDER", true)
    UI():SetEdgeColor(f.mine, 0.4, 0.72, 1, 0.4)
    f.mine.fs = H().Text(f.mine, "GameFontHighlight", 11.5, 0.88, 0.88, 0.88)
    f.mine.fs:SetPoint("LEFT", 10, 0)
    f.close = CreateFrame("Button", nil, f)
    f.close:SetSize(18, 18)
    f.close:SetPoint("TOPRIGHT", -8, -8)
    f.close.lines = {}
    for i = 1, 2 do
        local l = f.close:CreateLine(nil, "ARTWORK")
        l:SetThickness(1.5)
        l:SetColorTexture(0.66, 0.66, 0.68, 1)
        f.close.lines[i] = l
    end
    f.close.lines[1]:SetStartPoint("CENTER", f.close, -4, 4)
    f.close.lines[1]:SetEndPoint("CENTER", f.close, 4, -4)
    f.close.lines[2]:SetStartPoint("CENTER", f.close, -4, -4)
    f.close.lines[2]:SetEndPoint("CENTER", f.close, 4, 4)
    f.close:SetScript("OnEnter", function(self) for _, l in ipairs(self.lines) do l:SetColorTexture(1, 1, 1, 1) end end)
    f.close:SetScript("OnLeave", function(self) for _, l in ipairs(self.lines) do l:SetColorTexture(0.66, 0.66, 0.68, 1) end end)
    f.close:SetScript("OnClick", function()
        f:Hide()
        T:RefreshResults()
        Stack()
    end)
    f:SetScript("OnUpdate", function(self, dt)
        self.left = (self.left or RESULT_FOR) - dt
        if self.left <= 0 and not self:IsMouseOver() then
            self:Hide()
            T:RefreshResults()
            Stack()
        end
    end)
    return f
end

local function ResultRow(f, i)
    local r = f.rows[i]
    if not r then
        r = CreateFrame("Frame", nil, f)
        r:SetHeight(28)
        r.rank = H().Text(r, "GameFontHighlight", 12, 0.62, 0.62, 0.62)
        EUI():Narrow(r.rank, 12)
        r.rank:SetPoint("LEFT", 0, 0)
        r.cls = r:CreateTexture(nil, "ARTWORK")
        r.cls:SetSize(20, 20)
        r.cls:SetPoint("LEFT", 16, 0)
        r.name = H().Text(r, "GameFontHighlight", 12)
        r.track = r:CreateTexture(nil, "ARTWORK")
        r.track:SetHeight(8)
        r.track:SetColorTexture(1, 1, 1, 0.06)
        r.fill = r:CreateTexture(nil, "ARTWORK", nil, 1)
        r.fill:SetHeight(8)
        r.fill:SetTexture(WHITE)
        r.n = H().Text(r, "GameFontHighlight", 13, 1, 1, 1)
        EUI():Narrow(r.n, 13)
        r.n:SetJustifyH("RIGHT")
        r.n:SetPoint("RIGHT", 0, 0)
        f.rows[i] = r
    end
    return r
end

local function Plain(s) return (tostring(s or ""):lower():gsub("%s+", "")) end

-- The right answers of a quiz question (its list item's), or nil.
local function RightAnswers(def, q)
    local item = q and type(q.item) == "table" and q.item
    local l = item and type(def.lists) == "table" and def.lists[item.ql]
    local it = l and type(l.items) == "table" and l.items[item.qi]
    return type(it) == "table" and type(it.a) == "table" and it.a or nil
end

local function IsRight(v, right)
    if not right then return false end
    for _, r in ipairs(right) do if Plain(r) == Plain(v) then return true end end
    return false
end

local function NameList(keys)
    local names = {}
    for i, k in ipairs(keys) do names[i] = H().Name(k) end
    if #names <= 1 then return names[1] or "" end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- Fills a result card from a closed ask (q: st.qa[aid]).
function T:FillResult(f, occ, st, def, aid, q)
    local h = H()
    local ad = type(def.asks) == "table" and def.asks[aid] or {}
    local kind = ad.kind or q.kind or "player"
    local r = E():Reader(def, st)
    local ok, tally = pcall(r.Tally, r, aid)
    tally = ok and tally or {}
    local total, people = 0, 0
    for _, t in ipairs(tally) do total = total + t.n end
    -- (answers lost in a takeover are in ans but count for nothing: q.lost, the engine's rule)
    local lost = type(q.lost) == "table" and q.lost or {}
    for k in pairs(q.ans or {}) do if not lost[k] then people = people + 1 end end
    local me = Me()
    local mine
    if q.ans and not lost[me] then mine = q.ans[me] end
    -- (an open secret ask's answers travel as true; a closed one's are real: yes is true too)
    if mine == true and kind ~= "yesno" then mine = nil end
    f.kick:SetText(Upper(ad.n or "Ask") .. " · CLOSED")
    local top = tally[1]
    local head, sub
    f.badge:SetBadge({ n = def.name, i = def.icon, f = "gold" })
    f.cls:Hide()
    f.clsRing:Hide()
    local right = kind == "text" and RightAnswers(def, q)
    if not top then
        head, sub = "Nobody answered", "It closed with no answers"
    elseif kind == "player" then
        local who = h.Name(top.v)
        local verb = tostring(q.q or ad.q or ""):match("^[Ww]ho (.-)%??$")
        local tied = {}
        for _, t in ipairs(tally) do if t.n == top.n and type(t.v) == "string" then tied[#tied + 1] = t.v end end
        if #tied > 1 then
            head = "A tie: " .. NameList(tied)
        else
            head = verb and (who .. " " .. verb) or (who .. " got the most votes")
        end
        sub = total .. (total == 1 and " vote" or " votes") .. " from " .. people .. (people == 1 and " player" or " players")
        f.badge:Hide()
        h.SetClass(f.cls, top.v)
        f.cls:Show()
        f.clsRing:Show()
    elseif kind == "yesno" then
        local yes, no = 0, 0
        for _, t in ipairs(tally) do if t.v == true then yes = t.n elseif t.v == false then no = t.n end end
        head = (yes == no) and ("A tie, " .. yes .. " to " .. no) or ((yes > no and "Yes, " or "No, ") .. max(yes, no) .. " to " .. min(yes, no))
        sub = people .. (people == 1 and " answer" or " answers")
    elseif kind == "number" then
        local sum, n = 0, 0
        for _, t in ipairs(tally) do
            local x = tonumber(t.v)
            if x then sum, n = sum + x * t.n, n + t.n end
        end
        head = n > 0 and (("Average %.1f"):format(sum / n):gsub("%.0$", "")) or "No scores"
        sub = "from " .. n .. (n == 1 and " score" or " scores")
    elseif kind == "text" and right then
        local good = 0
        for _, t in ipairs(tally) do if IsRight(t.v, right) then good = good + t.n end end
        head = "The answer: " .. tostring(right[1])
        sub = good .. " of " .. people .. " got it right"
    else
        head = h.AnswerText(top.v, true) .. (kind == "choice" and " got the most votes" or "")
        if kind == "text" then head = "Most said " .. h.AnswerText(top.v) end
        sub = people .. (people == 1 and " answer" or " answers")
    end
    f.badge:SetShown(not f.cls:IsShown())
    h.Fit(f.head, head, RESULT_W - 58 - 30, 13, 10.5)
    f.sub:SetText(sub or "")
    -- the counts (numbers: the scores given, most first)
    local y = 76
    local best = top and top.n or 1
    local n = 0
    for i, t in ipairs(tally) do
        if i > 6 then break end
        n = n + 1
        local row = ResultRow(f, n)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -y)
        row:SetWidth(RESULT_W - 28)
        row.rank:SetText(tostring(i))
        local player = kind == "player"
        row.cls:SetShown(player)
        if player then h.SetClass(row.cls, t.v) end
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row, "LEFT", player and 44 or 16, 0)
        local label = h.AnswerText(t.v, true)
        if right and IsRight(t.v, right) then label = "|cff9ff0b0" .. h.AnswerText(t.v) .. "|r" end
        h.Fit(row.name, label, player and 96 or 124, i == 1 and 13 or 12, 10)
        row.name:SetWidth(player and 96 or 124)
        row.track:ClearAllPoints()
        row.track:SetPoint("LEFT", row, "LEFT", player and 146 or 146, 0)
        row.track:SetPoint("RIGHT", row, "RIGHT", -28, 0)
        local tw = RESULT_W - 28 - 146 - 28
        row.fill:ClearAllPoints()
        row.fill:SetPoint("LEFT", row.track, "LEFT")
        row.fill:SetWidth(max(1, tw * t.n / max(1, best)))
        if i <= 3 and row.fill.SetGradient and CreateColor then
            row.fill:SetGradient("HORIZONTAL", CreateColor(1, 0.82, 0, 0.35), CreateColor(1, 0.82, 0, 0.85))
        elseif i <= 3 then
            row.fill:SetColorTexture(1, 0.82, 0, 0.7)
        else
            row.fill:SetColorTexture(1, 1, 1, 0.22)
        end
        row.n:SetText(tostring(t.n))
        row:Show()
        y = y + 30
    end
    for i = n + 1, #f.rows do f.rows[i]:Hide() end
    -- what I said
    local text
    if mine == nil then
        text = (q.who and q.who[me]) and "|cff9e9e9eYou didn't answer|r" or nil
    elseif kind == "player" then
        local list = type(mine) == "table" and mine or { mine }
        text = "You picked " .. NameList(list)
    elseif kind == "number" then
        text = "You gave " .. tostring(mine)
    elseif kind == "yesno" then
        text = "You said " .. (mine and "yes" or "no")
    else
        text = "You said " .. h.AnswerText(mine) .. ((right and IsRight(mine, right)) and " |cff9ff0b0· right|r" or "")
    end
    if text then
        y = y + 8
        f.mine:ClearAllPoints()
        f.mine:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -y)
        f.mine:SetWidth(RESULT_W - 28)
        h.Fit(f.mine.fs, text, RESULT_W - 28 - 20, 11.5, 9.5)
        f.mine:Show()
        y = y + 30
    else
        f.mine:Hide()
    end
    f:SetHeight(y + 14)
    f.left = RESULT_FOR
end

-- The asks I saw open that closed since: their result, once each, in the order they closed (two at a time: the
-- others wait their turn, a minute at most).
function T:RefreshResults()
    local ready = {}
    for key, s in pairs(p2.seen) do
        local st, def = StateOf(s.occ)
        local q = st and type(st.qa) == "table" and st.qa[s.aid]
        local closed = q and not q.open and (q.at == s.at)
        local gone = not q or (q.at ~= s.at and not q.open)
        if closed and not p2.shownResult[key] then
            if H().Now(s.occ) - (tonumber(q.closed) or H().Now(s.occ)) > 60 then
                p2.seen[key] = nil
            else
                ready[#ready + 1] = { key = key, s = s, st = st, def = def, q = q }
            end
        elseif gone or not st then
            p2.seen[key] = nil
        end
    end
    tsortr(ready)
    for _, e in ipairs(ready) do
        local f
        for _, r in ipairs(p2.results) do if not r:IsShown() then f = r break end end
        if not f and #p2.results < MAX_RESULTS then
            f = NewResult()
            p2.results[#p2.results + 1] = f
        end
        if not f then break end
        p2.shownResult[e.key] = true
        p2.seen[e.key] = nil
        self:FillResult(f, e.s.occ, e.st, e.def, e.s.aid, e.q)
        local at = Has(p2.order, f)
        if at then table.remove(p2.order, at) end
        p2.order[#p2.order + 1] = f
        f:Show()
    end
end

---------------------------------------------------------------------------
-- "show": a banner in the middle of my screen, in the event's look (part 1's raid warning)
---------------------------------------------------------------------------

local BANNER_W, BANNER_FOR = 520, 6

local function NewBanner()
    local f = CreateFrame("Frame", "DisasterZoneEventBanner" .. (#banners + 1), UIParent)
    f:SetSize(BANNER_W, 64)
    f:SetFrameStrata("HIGH")
    f.shadow = f:CreateTexture(nil, "BACKGROUND", nil, -2)
    f.shadow:SetPoint("TOPLEFT", -10, 8)
    f.shadow:SetPoint("BOTTOMRIGHT", 10, -14)
    f.shadow:SetColorTexture(0, 0, 0, 0.35)
    f.art = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    f.art:SetAllPoints()
    f.shade = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.shade:SetAllPoints()
    f.shade:SetTexture(WHITE)
    if f.shade.SetGradient and CreateColor then
        f.shade:SetGradient("HORIZONTAL", CreateColor(0.035, 0.035, 0.043, 0.92), CreateColor(0.035, 0.035, 0.043, 0.55))
    else
        f.shade:SetColorTexture(0.035, 0.035, 0.043, 0.75)
    end
    UI():AddEdges(f, "BORDER", true)
    UI():SetEdgeColor(f, 1, 0.82, 0, 0.55)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(30, 30)
    -- (from the top, as the words: a banner of three lines grows down, the icon beside its first two)
    f.icon:SetPoint("TOPLEFT", 14, -17)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.kick = Kicker(f)
    f.kick:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + 30 + 12, -15)
    f.t = H().Text(f, "GameFontHighlightLarge", 17, 1, 1, 1)
    f.t:SetWordWrap(true)
    f.t:SetSpacing(2)
    f.t:SetWidth(BANNER_W - 14 - 30 - 12 - 16)
    f.t:SetPoint("TOPLEFT", f.kick, "BOTTOMLEFT", 0, -4)
    f:SetScript("OnUpdate", function(self, dt)
        self.left = (self.left or 0) - dt
        if self.left <= 0 then
            self:Hide()
            T:LayBanners()
            return
        end
        self:SetAlpha(min(1, self.left / 0.8))
    end)
    f:Hide()
    return f
end

function T:LayBanners()
    local y = -150
    for _, f in ipairs(banners) do
        if f:IsShown() then
            f:ClearAllPoints()
            f:SetPoint("TOP", UIParent, "TOP", 0, y)
            y = y - f:GetHeight() - 8
        end
    end
    -- (the cards in the middle start below them)
    Stack()
end

-- A banner for me (EVENT_SHOW): the event's art and name, the text big; the newest on top, two at most.
function T:Show(occ, text)
    text = tostring(text or "")
    if text == "" then return end
    local st, def = StateOf(occ)
    def = def or {}
    local f
    for _, b in ipairs(banners) do if not b:IsShown() then f = b break end end
    if not f and #banners < 2 then
        f = NewBanner()
        banners[#banners + 1] = f
    end
    if not f then
        -- (two up already: the older one goes)
        local oldest = banners[1]
        for _, b in ipairs(banners) do if (b.left or 0) < (oldest.left or 0) then oldest = b end end
        f = oldest
    end
    EUI():SetArt(f.art, def.art, BANNER_W, 64, 0.5, 0.58, 0.95)
    f.icon:SetTexture(def.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.kick:SetText(Upper(def.name or "Event"))
    f.t:SetText(H().ColorNames(text, st and st.entrants or {}))
    local th = f.t:GetStringHeight() or 20
    f:SetHeight(floor(max(64, 12 + 14 + 4 + th + 12) + 0.5))
    f.left = BANNER_FOR + min(4, #text / 30)
    f:SetAlpha(1)
    -- the newest on top
    local at = Has(banners, f)
    if at then table.remove(banners, at) end
    table.insert(banners, 1, f)
    f:Show()
    self:LayBanners()
    Snd("RAID_WARNING")
end

---------------------------------------------------------------------------
-- Big texts: raid warnings, countdowns
---------------------------------------------------------------------------

local function CreateWarn()
    local f = CreateFrame("Frame", "DisasterZoneEventWarning", UIParent)
    f:SetSize(900, 32)
    f:SetFrameStrata("HIGH")
    f:SetPoint("TOP", UIParent, "TOP", 0, -200)
    f.t = H().Text(f, "GameFontNormalHuge", 24, GOLD[1], GOLD[2], GOLD[3])
    f.t:SetJustifyH("CENTER")
    f.t:SetPoint("TOP")
    f.t:SetShadowOffset(2, -2)
    f:SetScript("OnUpdate", function(self, dt)
        self.left = (self.left or 0) - dt
        if self.left <= 0 then self:Hide() return end
        self:SetAlpha(min(1, self.left / 1.5))
    end)
    f:Hide()
    rwarn = f
    return f
end

-- A raid warning of the event on my screen (the game's raid warning frame when there is one).
function T:Announce(text)
    text = tostring(text or "")
    if text == "" then return end
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, text, { r = 1, g = 0.82, b = 0 })
    else
        local f = rwarn or CreateWarn()
        H().Fit(f.t, text, 880, 24, 16)
        f.left = 8
        f:SetAlpha(1)
        f:Show()
    end
    Snd("RAID_WARNING")
end

local function CreateCountdown()
    local f = CreateFrame("Frame", "DisasterZoneEventCountdown", UIParent)
    f:SetSize(200, 90)
    f:SetFrameStrata("HIGH")
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
    f.t = H().Text(f, "GameFontNormalHuge", 60, GOLD[1], GOLD[2], GOLD[3])
    f.t:SetJustifyH("CENTER")
    f.t:SetPoint("CENTER")
    f.t:SetShadowOffset(2, -2)
    f:SetScript("OnUpdate", function(self)
        local left = self.endAt - GetTime()
        if left <= -1 then self:Hide() return end
        local n = ceil(left)
        if n ~= self.n then
            self.n = n
            self.t:SetText(n > 0 and tostring(n) or "Go!")
            if n > 0 and n <= 3 then Snd("UI_BATTLEGROUND_COUNTDOWN_TIMER") end
            if n <= 0 then Snd("UI_BATTLEGROUND_COUNTDOWN_FINISHED") end
        end
        -- each number lands a little big and settles
        local frac = (left > 0) and (left - floor(left)) or (left + 1)
        self:SetScale(1 + 0.25 * max(0, frac - 0.75) * 4)
        self:SetAlpha(left > 0 and 1 or max(0, left + 1))
    end)
    f:Hide()
    cdown = f
    return f
end

function T:Countdown(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return end
    local f = cdown or CreateCountdown()
    f.endAt = GetTime() + seconds
    f.n = nil
    f:SetAlpha(1)
    f:Show()
end

---------------------------------------------------------------------------
-- Watching the state
---------------------------------------------------------------------------

-- What changed for me since the last state: a game counted (the toast), my match started (the card).
function T:Observe(occ, st, def, bk)
    local me = Me()
    if not bk then return end
    -- asks of my matches seen (how a game was decided)
    for _, a in pairs(st.asks or {}) do
        if type(a) == "table" and a.match and a.g then
            local k = occ .. ":" .. a.match .. ":" .. a.g
            local hostAsk = a.claims ~= nil or (#(a.to or {}) == 1 and a.to[1] == st.host)
            if hostAsk or not asked[k] then asked[k] = hostAsk and "host" or "players" end
        end
    end
    local rec = follow[occ]
    local nextM = H().MyNext(bk, me)
    if rec and bk.m[rec.mid] then
        local m = bk.m[rec.mid]
        local myKey = (m.a == me) and "wa" or "wb"
        local oppKey = (myKey == "wa") and "wb" or "wa"
        local mine, theirs = m[myKey] or 0, m[oppKey] or 0
        if mine + theirs > rec.mine + rec.theirs and (m.a == me or m.b == me) then
            local won = mine > rec.mine
            self:ShowGameToast(occ, bk, m, won, asked[occ .. ":" .. m.id .. ":" .. (mine + theirs)])
        end
        rec.mine, rec.theirs, rec.st = mine, theirs, m.st
        if m.st == "done" or m.st == "bye" then rec = nil end
    else
        rec = nil
    end
    if not rec and nextM then
        local myKey = (nextM.a == me) and "wa" or "wb"
        rec = { mid = nextM.id, st = nextM.st, mine = nextM[myKey] or 0, theirs = nextM[myKey == "wa" and "wb" or "wa"] or 0 }
    end
    follow[occ] = rec
    -- the match card: my match is being played, I'm not ready, it came up once
    local m = rec and bk.m[rec.mid]
    local key = m and (occ .. ":" .. m.id)
    local playing = m and m.st == "play" and type(H().Opp(m, me)) == "string"
    local ready = st.ready and st.ready[me]
    if playing and not ready and not cardOff[key] then
        local fresh = Elapsed(occ, st, m) < NoShow(bk)
        if (not cardShown[key] and fresh) or (card and card:IsShown() and card.key == key) then
            cardShown[key] = true
            self:ShowMatchCard(occ, st, def, bk, m)
        end
    elseif card and card:IsShown() then
        card:Hide()
    end
    -- waiting for the opponent (I'm ready, they're not)
    local opp = m and H().Opp(m, me)
    if playing and ready and not (st.ready and st.ready[opp]) and (m.g or 0) == 0 then
        self:ShowWait(occ, st, bk, m)
    elseif waitc and waitc:IsShown() then
        waitc:Hide()
    end
    -- who won (my game and my opponent's disagree)
    local a = L():MyAsk(occ)
    if a and Contains(a.opts, me) and not answered[occ .. ":" .. a.id] then
        self:ShowAsk(occ, st, bk, a)
    elseif ask and ask:IsShown() and ask.occ == occ then
        ask:Hide()
    end
    Stack()
end

function T:Refresh()
    local occ, st, def, bk, planned = self:MyEvent()
    if type(planned) ~= "table" then planned = nil end
    cur.occ, cur.planned = occ, planned and true or nil
    if planned then
        for _, f in ipairs({ card, ask, waitc }) do if f then f:Hide() end end
        self:FillPlanned(occ, planned)
        self:RefreshAsks()
        return
    end
    if not occ then
        if trk then trk:Hide() end
        if mmRing then mmRing:Hide() end
        for _, f in ipairs({ card, ask, waitc }) do if f then f:Hide() end end
        self:RefreshAsks()
        return
    end
    self:FillTracker(occ, st, def, bk)
    self:Observe(occ, st, def, bk)
    -- a question from another event of mine (Observe follows this one) stays only while that event still asks it
    if ask and ask:IsShown() and ask.occ ~= occ then
        local a = L():IsLive(ask.occ) and L():MyAsk(ask.occ)
        if not (a and ask.a and a.id == ask.a.id) or answered[ask.occ .. ":" .. a.id] then
            ask:Hide()
            Stack()
        end
    end
    self:RefreshAsks()
end

function T:Later()
    ns.Util.Debounce("dz-eventtracker", 0.1, function() T:Refresh() end)
end

-- Hides the tracker and the cards (they come back with the next change).
function T:Hide()
    for _, f in ipairs({ trk, card, ask, waitc, toast, cdown, rwarn, mmRing }) do if f then f:Hide() end end
    for _, f in pairs(p2.cards) do f:Hide() end
    for _, f in ipairs(p2.results) do f:Hide() end
    for _, f in ipairs(banners) do f:Hide() end
end

function T:GetFrames()
    local asks = {}
    for _, f in ipairs(p2.order) do if f:IsShown() and not f.isResult then asks[#asks + 1] = f end end
    local results = {}
    for _, f in ipairs(p2.order) do if f:IsShown() and f.isResult then results[#results + 1] = f end end
    return { tracker = trk, card = card, toast = toast, ask = ask, wait = waitc, countdown = cdown, warning = rwarn,
        asks = asks, results = results, banners = banners, minimap = mmRing }
end

function T:GetOcc() return cur.occ end

function T:OnInit()
    ns:On("EVENT_LIVE_UPDATED", function() T:Later() end)
    ns:On("EVENT_PRACTICE_UPDATED", function() T:Later() end)
    ns:On("DEMO_TOGGLED", function()
        T.demoSeen, T.demoOcc = nil, nil
        T:Later()
    end)
    ns:On("EVENT_ANNOUNCE", function(_, text) T:Announce(text) end)
    ns:On("EVENT_COUNTDOWN", function(_, seconds) T:Countdown(seconds) end)
    -- part 2: the addon's own messages for me (EventLive played a sound already: EVENT_SOUND needs nothing here)
    ns:On("EVENT_SHOW", function(occ, text) T:Show(occ, text) end)
    ns:On("EVENT_TELL", function() T:Later() end)
    ns:RegisterEvent("QUEST_WATCH_UPDATE", function() if trk and trk:IsShown() then Anchor() end end)
    ns:RegisterEvent("MINIMAP_UPDATE_ZOOM", function() T:MoveMinimapRing() end)
end

function T:OnLogin() T:Later() end
