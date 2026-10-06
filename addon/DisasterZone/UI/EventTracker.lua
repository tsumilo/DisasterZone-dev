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

-- The live event I play in or host (my match being played first): occ, st, def, bk.
function T:MyEvent()
    local me = Me()
    -- demo mode's live cup: only once its board was opened (switching demo mode on puts nothing in the world)
    if ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() and not self.demoSeen then return nil end
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
    if not best then return nil end
    local st = L():GetState(best)
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
    head:SetScript("OnClick", function() if cur.occ then Board():Toggle(cur.occ) end end)
    head:SetScript("OnEnter", function(self)
        f.name:SetTextColor(1, 0.92, 0.5)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(f.name:GetText() or "Event")
        GameTooltip:AddLine("Click: the live board", 1, 1, 1)
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
    f.tick = 0
    f:SetScript("OnUpdate", function(self, dt)
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

-- Lays the tracker's lines out top to bottom (shown ones only) and sizes it.
local function LayTracker(f)
    local y = 18
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
    f:SetHeight(y)
end

-- The lines for the event (occ) and my place in it.
function T:FillTracker(occ, st, def, bk)
    local f = trk or CreateTracker()
    local h = H()
    local me = Me()
    f.icon:SetTexture(def and def.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    h.Fit(f.name, def and def.name or "Event", TRK_W - 23 - 44, 12.5, 10)
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
    elseif entrant or Contains(st.signups, me) then
        local n = #(st.entrants or {})
        f.l1:SetText("You're signed up" .. (n > 0 and (" · " .. n .. " players") or ""))
        f.l2:SetText(EUI():StageSub(def, st) == "signing up" and "The bracket is drawn when sign-up closes" or "")
        f.l3:SetText(place and ("Meet at " .. place) or "")
    end
    -- the host (who doesn't play right now): how it runs, a dispute to settle
    if L():IsHostOf(occ) and not m then
        local n = bk and #h.Playing(bk) or 0
        local disputes = Board():Disputes(st)
        local sub = (bk and EUI():StageSub(def, st)) or (st.stage and ns.EventBlocks:StageName(def, st.stage)) or ""
        f.l1:SetText("You're hosting" .. (sub ~= "" and (" · " .. sub) or ""))
        local parts = { bk and (n == 1 and "1 match playing" or (n .. " matches playing")) or (#h.SignedUp(st) .. " signed up") }
        if #disputes > 0 then parts[#parts + 1] = "|cffffcf99" .. #disputes .. (#disputes == 1 and " dispute" or " disputes") .. "|r" end
        f.l2:SetText(table.concat(parts, " · "))
        f.l3:SetText("")
        f.board:SetShown(#disputes > 0)
    end
    LayTracker(f)
    self:TickClocks()
    Anchor()
    f:Show()
end

function T:TickClocks()
    local f = trk
    if not (f and f:IsShown()) then return end
    local m = f.clockMatch
    local st = cur.occ and L():GetState(cur.occ)
    if m and st and m.st == "play" then
        f.clock:SetText(H().Clock(Elapsed(cur.occ, st, m)))
    else
        f.clock:SetText("")
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

local function Stack()
    local y = 175
    for _, f in ipairs({ card, ask, waitc, toast }) do
        if f and f:IsShown() then
            f:ClearAllPoints()
            f:SetPoint("TOP", UIParent, "CENTER", 0, y)
            y = y - f:GetHeight() - 10
        end
    end
end

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
    local occ, st, def, bk = self:MyEvent()
    cur.occ = occ
    if not occ then
        if trk then trk:Hide() end
        for _, f in ipairs({ card, ask, waitc }) do if f then f:Hide() end end
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
end

function T:Later()
    ns.Util.Debounce("dz-eventtracker", 0.1, function() T:Refresh() end)
end

-- Hides the tracker and the cards (they come back with the next change).
function T:Hide()
    for _, f in ipairs({ trk, card, ask, waitc, toast, cdown, rwarn }) do if f then f:Hide() end end
end

function T:GetFrames()
    return { tracker = trk, card = card, toast = toast, ask = ask, wait = waitc, countdown = cdown, warning = rwarn }
end

function T:GetOcc() return cur.occ end

function T:OnInit()
    ns:On("EVENT_LIVE_UPDATED", function() T:Later() end)
    ns:On("DEMO_TOGGLED", function()
        T.demoSeen = nil
        T:Later()
    end)
    ns:On("EVENT_ANNOUNCE", function(_, text) T:Announce(text) end)
    ns:On("EVENT_COUNTDOWN", function(_, seconds) T:Countdown(seconds) end)
    ns:RegisterEvent("QUEST_WATCH_UPDATE", function() if trk and trk:IsShown() then Anchor() end end)
end

function T:OnLogin() T:Later() end
