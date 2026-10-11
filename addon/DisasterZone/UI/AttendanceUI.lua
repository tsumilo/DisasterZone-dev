if DisasterZoneBoot and DisasterZoneBoot.Run("UI/AttendanceUI.lua", ...) then return end -- DisasterZone: UI/AttendanceUI.lua
-- The time-based attendance's pages and prompts (Core/Attendance.lua; approved mockup 2026-10-11):
--   Timeline   - Raids > Raid log > Raids > Attendance: a time bar per player over the night (boss kills as gold
--                pips, the expected window as gold ticks), the lineup, then who came to help, and the credit.
--   Overview   - Raids > Raid log > Attendance: every member with their lineups, the last raids as squares, late,
--                left early, no-shows and attendance; a click opens the player's page.
--   Player     - a member's page: the number, four facts, the last 12 raids as columns and each raid (also the
--                member card's Attendance tab, and a member's own).
--   Reviews    - Raids > Raid log > Reviews: what waits for a decision (Excuse / Counts, a note, Pick from chat),
--                then what was decided.
--   Picker     - the chat lines a player said around the raid, ticked to keep as the reason.
--   Prompts    - the raid leader's (an expected player left: their chat lines, Swap in / I benched them / Officers
--                decide; who is not here yet) and the player's own (you left before the end: why?).
local addonName, ns = ...

local AUI = ns:NewModule("AttendanceUI")

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local C = {
    present = { 0.30, 0.66, 0.40 }, missed = { 0.86, 0.32, 0.28 }, excused = { 0.45, 0.58, 0.78 },
    pending = { 1, 0.62, 0.18 }, fill = { 0.22, 0.72, 0.72 }, bench = { 0.91, 0.73, 0.14 },
    track = { 1, 1, 1, 0.05 }, gold = { 0.91, 0.73, 0.14 }, grey = { 0.62, 0.62, 0.62 }, dim = { 0.55, 0.55, 0.58 },
    card = { 0.10, 0.10, 0.12, 0.92 }, picked = { 0.17, 0.15, 0.10, 0.94 }, gap = { 0.55, 0.55, 0.6 },
    guest = { 0.55, 0.62, 0.72 },
}
AUI.C = C
local CHAT_COLOR = { Raid = { 1, 0.5, 0 }, Whisper = { 1, 0.5, 1 }, Guild = { 0.25, 1, 0.25 }, Party = { 0.67, 0.67, 1 },
                     Officer = { 0.25, 0.75, 0.25 }, Say = { 1, 1, 1 } }
AUI.CHAT_COLOR = CHAT_COLOR
local REASON = { life = "Real life", dc = "Disconnected", asked = "Asked to leave", other = "Other" }
AUI.REASON = REASON
local ROW_H = 21
local ART_TOP = 0.29

local function UI() return ns.UI end
local function Att() return ns.Attendance end
local function Util() return ns.Util end
local function Now() return GetServerTime() end

local function demoOn() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() and true or false end

local function hex(c, s) return ("|cff%02x%02x%02x%s|r"):format(c[1] * 255, c[2] * 255, c[3] * 255, s) end
local function grey(s) return hex({ 0.5, 0.5, 0.5 }, s) end
local function short(key) return Util().ShortName(key) or tostring(key) end

local function name(key, cls)
    local G = ns.Guild
    local text = UI():ColoredName(key, cls or (G and G.GetClass and G:GetClass(key)))
    return (text:gsub("%*|r$", "|r"))
end

local function classOf(key, cls)
    local G = ns.Guild
    return cls or (G and G.GetClass and G:GetClass(key)) or nil
end

local function clock(t) return t and date("%H:%M", t) or "-" end

-- "42 min", "1 h 08"
local function dur(sec)
    sec = floor(max(0, sec or 0) / 60 + 0.5)
    if sec >= 60 then return ("%d h %02d"):format(floor(sec / 60), sec % 60) end
    return sec .. " min"
end
AUI.Dur = dur

local function pctText(r)
    if not r.credit then return grey("-") end
    return floor(r.credit * 100 + 0.5) .. "%"
end

local function newText(parent, size, color, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    local path, _, flags = fs:GetFont()
    if path and size then fs:SetFont(path, size, flags) end
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    return fs
end
AUI.Text = newText

local function tex(parent, layer, c, a, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    t:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1)
    return t
end

-- A night's instance key (the raid plan's: its loading screen art) and short name.
local function instOf(n)
    local RP = ns.RaidPlan
    for _, inst in ipairs(RP and RP.GetInstances and RP:GetInstances() or {}) do
        if inst.instID and inst.instID == n.instID then return inst.key end
    end
    return "other"
end

local function setArt(t, n, w, h, fw)
    local PlanUI = ns.RaidPlanUI
    if not (PlanUI and PlanUI.RaidArt) then t:Hide() return end
    local file, l, r, tt, b = PlanUI:RaidArt(type(n) == "string" and n or instOf(n), w, h, fw or 0.4)
    if h < 60 and tt < ART_TOP then tt, b = ART_TOP, b + ART_TOP - tt end
    t:SetTexture(file)
    t:SetTexCoord(l, r, tt, b)
    t:Show()
end
AUI.SetArt = setArt

-- A night's name: the planned raid's when it was logged as several raids (Gruul + Mag), else its zone.
local function nightName(n)
    if n.recs and #n.recs > 1 and n.pl then
        local RP = ns.RaidPlan
        local v = RP and RP.GetRaid and RP:GetRaid(n.pl)
        if v then return RP:GetRaidName(v) end
        local zones = {}
        for i = #n.recs, 1, -1 do
            local z = n.recs[i].zone
            if z and zones[#zones] ~= z then zones[#zones + 1] = z end
        end
        return tconcat(zones, " + ")
    end
    return n.zone or "Raid"
end
AUI.NightName = function(_, n) return nightName(n) end

-- "Serpentshrine Cavern" for "Coilfang: Serpentshrine Cavern" (a tight column).
local function shortZone(z) return (tostring(z or "Raid"):gsub("^[^:]+:%s*", "")) end

-- The first of the texts that fits in `room` (else the last).
local function fit(fs, variants, room)
    for i, t in ipairs(variants) do
        fs:SetText(t)
        if i == #variants or (fs:GetStringWidth() or 0) <= room then return end
    end
end

local function nightTitle(n)
    return nightName(n) .. "  " .. grey(date("%a %d %b", n.start or Now()))
end

-- What the planned raid of a night was: "T1 · Main", "Raid without a team", or nil (not linked).
function AUI:LineupLabel(n)
    local RP = ns.RaidPlan
    local v = n.pl and RP and RP.GetRaid and RP:GetRaid(n.pl)
    if not v then return nil end
    local parts = {}
    for _, id in ipairs(v.tm or {}) do
        local t = RP:GetTeam(id)
        local l = t and RP:GetRaidLineup(v, id)
        if t then parts[#parts + 1] = t.name .. (l and (" · " .. (RP:LineupName(t, l) or "")) or "") end
    end
    if #parts == 0 then return "Raid without a team" end
    return tconcat(parts, ", ")
end

local function whisper(key)
    local nm = (Ambiguate and Ambiguate(key, "none")) or short(key)
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then open("/w " .. nm .. " ") end
end
AUI.Whisper = whisper

-- A note and two actions (buttons = { first, second }): onButton(1 | 2, text). Escape, the X and Cancel do nothing
-- (Cancel is button2, the dialog's cancel; the second action is button3).
local function textPrompt(title, body, buttons, onButton)
    local P = ns.Popup
    if not P then return end
    P.dialogs.DISASTERZONE_ATT_NOTE = {
        title = title, text = body, button1 = buttons[1], button2 = "Cancel", button3 = buttons[2],
        hasEditBox = true, maxLetters = 200, hideOnEscape = true,
        OnAccept = function(d) onButton(1, d.editBox:GetText()) end,
        OnAlt = function(d) onButton(2, d.editBox:GetText()) end,
    }
    P:Show("DISASTERZONE_ATT_NOTE")
end

---------------------------------------------------------------------------
-- Widgets: a time bar, a square, a pill
---------------------------------------------------------------------------

-- A time bar: b:Set(lo, hi, segs, ticks, labelOK): segs = { { from, to, kind, alpha, label } } (server times), ticks
-- = { time, ... } (gold window edges).
local function NewBar(parent, w, h)
    local b = CreateFrame("Frame", nil, parent)
    b:SetSize(w, h)
    b.w, b.h = w, h
    b.track = tex(b, "BACKGROUND", C.track)
    b.track:SetAllPoints()
    b.segs, b.ticks, b.labels = {}, {}, {}
    function b:SetWidthPx(px)
        self.w = px
        self:SetWidth(px)
    end
    function b:Set(lo, hi, segs, ticks)
        local sc = (hi > lo) and self.w / (hi - lo) or 0
        for i, s in ipairs(segs or {}) do
            local t = self.segs[i]
            if not t then
                t = self:CreateTexture(nil, "ARTWORK", nil, 1)
                self.segs[i] = t
            end
            local c = C[s[3]] or C.present
            local x1, x2 = (max(s[1], lo) - lo) * sc, (min(s[2], hi) - lo) * sc
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", self, "TOPLEFT", x1, 0)
            t:SetSize(max(1, x2 - x1), self.h)
            t:SetColorTexture(c[1], c[2], c[3], s[4] or (s[3] == "missed" and 0.55 or 0.9))
            t:SetShown(x2 > x1)
            local fs = self.labels[i]
            if s[5] then
                if not fs then
                    fs = newText(self, 10, { 1, 1, 1 }, "GameFontHighlightSmall")
                    self.labels[i] = fs
                end
                fs:ClearAllPoints()
                fs:SetPoint("LEFT", t, "LEFT", 4, 0)
                fs:SetText(s[5])
                fs:SetShown((fs:GetStringWidth() or 0) + 8 <= x2 - x1)
            elseif fs then
                fs:Hide()
            end
        end
        for i = #(segs or {}) + 1, #self.segs do
            self.segs[i]:Hide()
            if self.labels[i] then self.labels[i]:Hide() end
        end
        for i, m in ipairs(ticks or {}) do
            local t = self.ticks[i]
            if not t then
                t = self:CreateTexture(nil, "OVERLAY")
                t:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.7)
                self.ticks[i] = t
            end
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", self, "TOPLEFT", (m - lo) * sc, 2)
            t:SetSize(1, self.h + 4)
            t:SetShown(m >= lo and m <= hi)
        end
        for i = #(ticks or {}) + 1, #self.ticks do self.ticks[i]:Hide() end
    end
    return b
end
AUI.NewBar = NewBar

-- The bar's segments for a player's night: where they were there, what they missed of the expected time (red; blue
-- when excused; amber while it waits for a review), bench, help (fill-ins). Labels say what happened.
function AUI:Segments(r)
    local segs = {}
    local p = r.pieces or {}
    if r.guest then
        for i = 1, #p - 1, 2 do segs[#segs + 1] = { p[i], p[i + 1], "guest", 0.6 } end
        return segs
    end
    if not r.kind then
        for i = 1, #p - 1, 2 do segs[#segs + 1] = { p[i], p[i + 1], "fill", 0.9 } end
        if segs[1] and r.forKey then segs[1][5] = "for " .. short(r.forKey) end
        if r.night.bench[r.key] and #segs == 0 then segs[1] = { r.F, r.T, "bench", 0.22, "bench" } end
        return segs
    end
    if r.bench and r.present <= 0 then return { { r.F, r.T, "bench", 0.22, "bench · on call" } } end
    local missKind = r.loose and "gap" or r.excused and "excused" or (r.pending and "pending") or "missed"
    local missAlpha = missKind == "missed" and 0.5 or (missKind == "gap" and 0.18) or 0.4
    if r.noShow then
        local label = r.otherRaid and ("in " .. (r.otherRaid.zone or "another raid"))
            or (r.note and r.note.x and "absent · told us") or (r.excused and "excused") or "no-show"
        return { { r.E, r.T, missKind, missAlpha, label } }
    end
    -- the missed parts of [E, T]: before the first piece, the gaps, after the last
    local cur = r.E
    local first = true
    for i = 1, #p - 1, 2 do
        local f, t = max(p[i], r.E), min(p[i + 1], r.T)
        if t > f then
            if f > cur + 60 then
                local label = first and r.late > 0 and ("late " .. dur(r.late)) or nil
                segs[#segs + 1] = { cur, f, missKind, missAlpha, label }
            end
            first = false
            cur = max(cur, t)
        end
    end
    if r.left > 0 and cur < r.T then
        segs[#segs + 1] = { cur, r.T, missKind, missAlpha, "left " .. clock(r.last) }
    end
    for i = 1, #p - 1, 2 do segs[#segs + 1] = { p[i], p[i + 1], r.bench and "bench" or "present", 0.9 } end
    return segs
end

-- A square of the overview: F full, pN part, N no-show, E excused, B bench, R in review, H helped, - not expected.
local function NewSquare(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.bg = f:CreateTexture(nil, "ARTWORK")
    f.bg:SetAllPoints()
    f.part = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.part:SetPoint("BOTTOMLEFT")
    f.dot = f:CreateTexture(nil, "OVERLAY", nil, 2)
    f.dot:SetSize(4, 4)
    f.dot:SetPoint("TOPRIGHT", -1, -1)
    f.dash = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.dash:SetSize(4, 1)
    f.dash:SetPoint("CENTER")
    UI():AddEdges(f, "OVERLAY")
    function f:SetCode(code)
        local s = self:GetWidth()
        self.part:Hide()
        self.dot:Hide()
        self.dash:Hide()
        UI():SetEdgeColor(self, 0, 0, 0, 0)
        local function fill(c, a) self.bg:SetColorTexture(c[1], c[2], c[3], a) end
        if code == "F" then fill(C.present, 0.9)
        elseif code == "N" then fill(C.missed, 0.85)
        elseif code == "E" then fill(C.excused, 0.85)
        elseif code == "H" then fill(C.fill, 0.75)
        elseif code == "B" then
            fill(C.bench, 0.25)
            UI():SetEdgeColor(self, C.bench[1], C.bench[2], C.bench[3], 0.9)
        elseif code == "R" then
            fill(C.present, 0.9)
            UI():SetEdgeColor(self, C.pending[1], C.pending[2], C.pending[3], 1)
            self.dot:SetColorTexture(C.pending[1], C.pending[2], C.pending[3], 1)
            self.dot:Show()
        elseif type(code) == "string" and code:sub(1, 1) == "p" then
            local n = tonumber(code:sub(2)) or 5
            fill(C.missed, 0.55)
            self.part:SetColorTexture(C.present[1], C.present[2], C.present[3], 0.9)
            self.part:SetSize(s, s * n / 10)
            self.part:Show()
        else
            fill({ 1, 1, 1 }, 0.04)
            self.dash:SetColorTexture(1, 1, 1, 0.18)
            self.dash:Show()
        end
    end
    return f
end
AUI.NewSquare = NewSquare

local CODE_TEXT = { F = "Full night", N = "No-show", E = "Excused", B = "Bench", R = "Waiting for review",
                    H = "Came to help", ["-"] = "Not expected" }
AUI.CODE_TEXT = CODE_TEXT

local function codeText(code)
    if type(code) == "string" and code:sub(1, 1) == "p" then
        return "Part of it (" .. (tonumber(code:sub(2)) or 5) * 10 .. "%)"
    end
    return CODE_TEXT[code] or code
end

local function pill(parent, h)
    return ns.EventUI:CreatePill(parent, h or 16)
end

-- A legend line of squares: code + words.
function AUI:CreateLegend(parent)
    local lg = CreateFrame("Frame", nil, parent)
    lg:SetSize(760, 16)
    local x = 0
    for _, it in ipairs({ { "F", "Full night" }, { "p6", "Part (late, left or away)" }, { "N", "No-show" },
                          { "E", "Excused" }, { "B", "Bench" }, { "R", "Waiting for review" }, { "H", "Came to help" },
                          { "-", "Not expected" } }) do
        local sq = NewSquare(lg, 11)
        sq:SetCode(it[1])
        sq:SetPoint("LEFT", x, 0)
        local fs = newText(lg, 10, C.grey, "GameFontHighlightSmall")
        fs:SetText(it[2])
        fs:SetPoint("LEFT", sq, "RIGHT", 5, 0)
        x = x + 16 + (fs:GetStringWidth() or 60) + 14
    end
    return lg
end

---------------------------------------------------------------------------
-- The tooltip of a player's night
---------------------------------------------------------------------------

function AUI:ResultTooltip(tt, r)
    local n = r.night
    tt:AddLine(name(r.key, r.cls))
    if r.lateCancel then
        tt:AddLine("Cancelled late: answered Absent " .. ((r.note.at and r.F and r.note.at >= r.F) and "after the start"
            or "less than 2 hours before the start") .. ".", 1, 0.69, 0.4, true)
    end
    if r.guest then
        tt:AddLine("Outside the guild: a guest, never counted.", 0.8, 0.8, 0.8, true)
        if r.first then tt:AddLine("In the group " .. clock(r.pieces[1]) .. " – " .. clock(r.pieces[#r.pieces]), 1, 1, 1) end
        return
    end
    if not r.kind then
        if r.clash then
            tt:AddLine("Signed up, but " .. (r.clash.zone or "their team raid") .. " was their team's raid at the same time: "
                .. "the team raid counts.", 0.8, 0.8, 0.8, true)
        elseif r.help then
            tt:AddLine("Not expected: came to help for " .. dur(r.help)
                .. (r.forKey and (", in place of " .. short(r.forKey)) or "") .. ".", 0.8, 0.8, 0.8, true)
        end
        return
    end
    local why = r.kind == "l" and "In the raid's lineup" or "Answered Accept"
    tt:AddLine(why .. " · expected " .. clock(r.F) .. " – " .. clock(r.T), 0.8, 0.8, 0.8)
    if r.loose then
        tt:AddLine(n.pl and "Logged before attendance tracking, so there is no planned time: they came, so it counts as there."
            or "Not linked to a planned raid, so there is no planned time: they came, so it counts as there.",
            0.62, 0.62, 0.62, true)
    elseif r.E > r.F then
        tt:AddLine("The raid formed at " .. clock(r.E) .. ": late counts from then.", 0.62, 0.62, 0.62, true)
    end
    if r.noShow then
        tt:AddLine(r.bench and "Bench: on call, counts as there." or "Didn't come.", 1, 0.5, 0.45)
    else
        tt:AddLine(("In the raid %s of %s"):format(dur(r.present), dur(r.expected)), 1, 1, 1)
        if r.late > 0 then tt:AddLine("Joined " .. clock(r.first) .. ": " .. dur(r.late) .. " late", 1, 0.69, 0.4) end
        if r.away > 60 then tt:AddLine("Away " .. dur(r.away) .. " (gone longer than a disconnect)", 1, 0.69, 0.4) end
        if r.left > 0 then tt:AddLine("Left " .. clock(r.last) .. ": " .. dur(r.left) .. " before the end", 1, 0.69, 0.4) end
    end
    if r.replacedBy then tt:AddLine(short(r.replacedBy) .. " filled in.", C.fill[1], C.fill[2], C.fill[3]) end
    if r.removed then tt:AddLine("The raid leader removed them: counts as there.", 0.8, 0.8, 0.8, true) end
    if r.outside and r.outside >= 30 * 60 then
        tt:AddLine("Outside the instance " .. dur(r.outside) .. " while the raid was inside (in the group, so it counts).",
            0.8, 0.8, 0.8, true)
    end
    if n.facts and n.facts.broke then
        tt:AddLine("The raid broke up at " .. clock(n.facts.broke) .. ": leaving with it isn't leaving early.", 0.62, 0.62, 0.62, true)
    end
    if r.mark and r.mark.b then tt:AddLine("The raid leader benched them: counts as there.", 0.8, 0.8, 0.8, true) end
    if r.otherRaid then tt:AddLine("Was in " .. (r.otherRaid.zone or "another guild raid") .. " at the same time: excused.", 0.8, 0.8, 0.8, true) end
    if r.reason then
        tt:AddLine("Their reason: " .. (REASON[r.reason.c] or "") .. (r.reason.n and (" \"" .. r.reason.n .. "\"") or ""),
            1, 0.93, 0.75, true)
    end
    if r.note then
        tt:AddLine((r.note.x and "Answered Absent" or "Sign-up note") .. (r.note.n and (": \"" .. r.note.n .. "\"") or ""),
            1, 0.93, 0.75, true)
    end
    for _, l in ipairs(r.picked and r.picked.l or {}) do
        local c = CHAT_COLOR[l.ch] or { 1, 1, 1 }
        tt:AddLine("[" .. l.ch .. "] " .. l.t, c[1], c[2], c[3], true)
    end
    if r.decision then
        tt:AddLine((r.decision.d == "x" and "Excused" or "Counts") .. " by " .. short(r.decision.by)
            .. (r.decision.n and (": \"" .. r.decision.n .. "\"") or ""), 0.62, 0.94, 0.69, true)
    elseif r.pending then
        tt:AddLine("Waiting for the GM, an officer or the guild council. Doesn't count until then.", C.pending[1],
            C.pending[2], C.pending[3], true)
    end
    if r.credit then tt:AddLine("Credit " .. pctText(r), 1, 0.82, 0) end
end

-- The menu of a player's night (right-click): decisions and Pick from chat for reviewers.
function AUI:ResultMenu(owner, r, extra)
    local A = Att()
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(short(r.key))
        if extra then extra(root) end
        if r.kind and A:CanReview() then
            local nk = r.night.key
            local function decide(d, note)
                local ok, err = A:Decide(nk, r.key, d, note)
                if not ok and err then ns:Print("%s", err) end
            end
            if not r.decision or r.decision.d ~= "x" then root:CreateButton("Excuse", function() decide("x") end) end
            if not r.decision or r.decision.d ~= "c" then root:CreateButton("Counts", function() decide("c") end) end
            root:CreateButton("Decide with a note...", function()
                textPrompt("Attendance: " .. short(r.key), "Excuse or count it, with a note the others see.",
                    { "Excuse", "Counts" }, function(i, text)
                        if i == 1 then decide("x", text) elseif i == 2 then decide("c", text) end
                    end)
            end)
            if r.decision then root:CreateButton("Undo the decision", function() decide(nil) end) end
            root:CreateButton("Pick from chat...", function() AUI:OpenPicker(owner, r) end)
        end
        root:CreateButton("Open their attendance", function() AUI:ShowPlayer(r.key) end)
    end)
end

-- Opens a player's page (the Raid log's Attendance page).
function AUI:ShowPlayer(key)
    local R = ns.RaidsUI
    if ns.MainFrame then ns.MainFrame:Open("raids") end
    if R and R.ShowAttendancePlayer then R:ShowAttendancePlayer(key) end
end

---------------------------------------------------------------------------
-- 1. Timeline: one night, a time bar per player
---------------------------------------------------------------------------

function AUI:CreateTimeline(parent, width)
    local v = CreateFrame("Frame", nil, parent)
    v:SetSize(width, 300)
    local NAME_W, CREDIT_W = 150, 54
    local BAR_X = NAME_W + 8
    local BAR_W = width - BAR_X - CREDIT_W - 10
    v.barW = BAR_W
    local hd = newText(v, 11, C.gold, "GameFontNormalSmall")
    hd:SetText("Player")
    hd:SetPoint("TOPLEFT", 0, -6)
    local hc = newText(v, 11, C.gold, "GameFontNormalSmall")
    hc:SetText("Credit")
    hc:SetJustifyH("RIGHT")
    hc:SetPoint("TOPRIGHT", 0, -6)
    v.axis = CreateFrame("Frame", nil, v)
    v.axis:SetSize(BAR_W, 22)
    v.axis:SetPoint("TOPLEFT", BAR_X, 0)
    v.axis.lane = tex(v.axis, "BACKGROUND", { 1, 1, 1 }, 0.08)
    v.axis.lane:SetPoint("TOPLEFT", 0, -17)
    v.axis.lane:SetSize(BAR_W, 1)
    v.axis.hours, v.axis.pips = {}, {}

    local function initRow(row, d)
        if not row.cdlInit then
            row.cdlInit = true
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row.hl = tex(row, "BACKGROUND", { 1, 1, 1 }, 0.04)
            row.hl:SetAllPoints()
            row.hl:Hide()
            row.sec = newText(row, 10, C.dim, "GameFontHighlightSmall")
            row.sec:SetPoint("LEFT", 0, -2)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(14, 14)
            row.icon:SetPoint("LEFT", 0, 0)
            row.name = newText(row, 12)
            row.name:SetPoint("LEFT", 20, 0)
            row.pill = pill(row, 14)
            row.pill:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
            row.bar = NewBar(row, BAR_W, 10)
            row.bar:SetPoint("LEFT", BAR_X, 0)
            row.credit = newText(row, 12)
            row.credit:SetJustifyH("RIGHT")
            row.credit:SetPoint("RIGHT", 0, 0)
            row:SetScript("OnEnter", function(self)
                local r = self.cdlR
                if not r then return end
                self.hl:Show()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                AUI:ResultTooltip(GameTooltip, r)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Click: their attendance. Right-click: " .. (Att():CanReview() and "decide, pick from chat." or "more."),
                    0.5, 0.5, 0.5, true)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function(self)
                self.hl:Hide()
                GameTooltip:Hide()
            end)
            row:SetScript("OnClick", function(self, button)
                local r = self.cdlR
                if not r then return end
                if button == "RightButton" then
                    AUI:ResultMenu(self, r, v.menuExtra and function(root) v.menuExtra(root, r) end)
                else
                    AUI:ShowPlayer(r.key)
                end
            end)
        end
        local sec = d.sec ~= nil
        row.cdlR = d.r
        row.sec:SetShown(sec)
        row.icon:SetShown(not sec)
        row.name:SetShown(not sec)
        row.bar:SetShown(not sec)
        row.credit:SetShown(not sec)
        row.pill:Hide()
        row:EnableMouse(not sec)
        if sec then
            row.sec:SetText(d.sec .. "   |cff6f6f74" .. (d.n or "") .. "|r")
            return
        end
        local r = d.r
        UI():ClassIcon(row.icon, classOf(r.key, r.cls))
        row.name:SetText(name(r.key, r.cls))
        local p
        if r.pending then p = { "review", "warn" }
        elseif r.excused then p = { "excused", "ok" }
        elseif r.removed then p = { "removed", "mute" }
        elseif r.bench and r.kind then p = { "bench", "mute" }
        elseif r.clash then p = { "team raid", "mute" } end
        if p then
            row.pill:SetKind(p[1], p[2])
            row.pill:Show()
        end
        local nameRoom = 150 - 20 - (p and (row.pill:GetWidth() + 8) or 0)
        fit(row.name, { name(r.key, r.cls), name(short(r.key):sub(1, 10), r.cls) }, nameRoom)
        row.name:SetWidth(min(nameRoom, (row.name:GetStringWidth() or nameRoom) + 2))
        row.bar:Set(d.lo, d.hi, AUI:Segments(r), { r.F, r.T })
        local text
        if r.guest then
            text = grey("guest")
        elseif not r.kind then
            text = r.help and hex(C.fill, "+" .. dur(r.help)) or grey("-")
        elseif r.pending then
            text = hex(C.pending, pctText(r))
        elseif r.excused then
            text = hex(C.excused, pctText(r))
        elseif r.noShow and not r.bench then
            text = hex(C.missed, pctText(r))
        else
            text = pctText(r)
        end
        row.credit:SetText(text)
    end

    v.list = UI():CreateScrollList(v, ROW_H, initRow)
    v.list.frame:SetPoint("TOPLEFT", 0, -24)
    v.list.frame:SetPoint("BOTTOMRIGHT", 20, 0)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPLEFT", v.list.box, "TOPRIGHT", 4, 0)
    v.list.bar:SetPoint("BOTTOMLEFT", v.list.box, "BOTTOMRIGHT", 4, 0)
    v.list:SetEmptyText("Nobody was expected or came.")

    -- n: a night (Attendance:GetNight). Returns the summary counts { onTime, late, left, noShow, fill, pending }.
    function v:SetNight(n)
        local A = Att()
        local rules = A:Rules()
        local res = A:NightResults(n, rules)
        local F, T = n.facts and n.facts.F or n.start, n.facts and n.facts.T or (n.stop or Now())
        local lo, hi = F, T
        for _, list in ipairs({ res.expected, res.helpers }) do
            for _, r in ipairs(list) do
                local p = r.pieces or {}
                if p[1] then lo = min(lo, max(p[1], F - 3600)) end
                if p[#p] then hi = max(hi, min(p[#p], T + 3600)) end
            end
        end
        lo, hi = lo - 600, hi + 600
        -- the axis: whole hours, boss kills
        local sc = BAR_W / max(1, hi - lo)
        local ax = self.axis
        local h0 = lo - (lo % 3600) + 3600
        local i = 0
        local step = (hi - lo) > 6 * 3600 and 7200 or 3600
        for t = h0, hi - 900, step do
            i = i + 1
            local fs = ax.hours[i] or newText(ax, 10, C.grey, "GameFontHighlightSmall")
            ax.hours[i] = fs
            fs:ClearAllPoints()
            fs:SetPoint("TOP", ax, "TOPLEFT", (t - lo) * sc, 0)
            fs:SetText(date("%H:%M", t))
            fs:Show()
        end
        for k = i + 1, #ax.hours do ax.hours[k]:Hide() end
        for k, b in ipairs(n.bosses) do
            local pip = ax.pips[k]
            if not pip then
                pip = CreateFrame("Frame", nil, ax)
                pip:SetSize(9, 9)
                pip.t = pip:CreateTexture(nil, "OVERLAY")
                pip.t:SetTexture(ns.EventUI.MASK)
                pip.t:SetSize(5, 5)
                pip.t:SetPoint("CENTER")
                pip.t:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.9)
                pip:EnableMouse(true)
                pip:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    GameTooltip:AddLine(self.boss or "Boss")
                    GameTooltip:AddLine(self.when or "", 1, 1, 1)
                    GameTooltip:Show()
                end)
                pip:SetScript("OnLeave", function() GameTooltip:Hide() end)
                ax.pips[k] = pip
            end
            pip.boss = b.name or ("Encounter " .. tostring(b.enc))
            pip.when = "Killed " .. clock(b.ts)
            pip:ClearAllPoints()
            pip:SetPoint("CENTER", ax, "TOPLEFT", (max(lo, min(hi, b.ts or lo)) - lo) * sc, -17)
            pip:Show()
        end
        for k = #n.bosses + 1, #ax.pips do ax.pips[k]:Hide() end
        -- the rows: the lineup, then who came to help
        local rows = {}
        local label = AUI:LineupLabel(n)
        local sum = { onTime = 0, late = 0, left = 0, noShow = 0, fill = 0, pending = 0 }
        if #res.expected > 0 then
            local head = n.legacy and "WHO CAME" or (label and label:upper()) or "EXPECTED"
            rows[#rows + 1] = { sec = head, n = n.legacy and (n.pl and "logged before attendance tracking: who came counts as there"
                or "not linked to a planned raid: who came counts as there") or (#res.expected .. " expected") }
            for _, r in ipairs(res.expected) do
                rows[#rows + 1] = { r = r, lo = lo, hi = hi }
                if r.pending then sum.pending = sum.pending + 1 end
                if r.noShow and not r.bench and not r.excused then sum.noShow = sum.noShow + 1
                elseif r.loose then sum.onTime = sum.onTime + 1
                elseif r.left > 0 then sum.left = sum.left + 1
                elseif r.late > 0 then sum.late = sum.late + 1
                elseif not r.noShow then sum.onTime = sum.onTime + 1 end
            end
        end
        if #res.helpers > 0 then
            rows[#rows + 1] = { sec = "CAME TO HELP", n = "not expected" }
            for _, r in ipairs(res.helpers) do
                rows[#rows + 1] = { r = r, lo = lo, hi = hi }
                sum.fill = sum.fill + 1
            end
        end
        if #res.guests > 0 then
            rows[#rows + 1] = { sec = "GUESTS", n = "outside the guild · not counted" }
            for _, r in ipairs(res.guests) do rows[#rows + 1] = { r = r, lo = lo, hi = hi } end
        end
        self.list:SetData(rows)
        return sum
    end
    return v
end

-- "7 on time   1 late   1 left early   1 no-show   1 fill-in" (coloured), or nil.
function AUI:SummaryText(sum, short)
    if not sum then return nil end
    local parts = {}
    local function add(n, word, c)
        if n > 0 then parts[#parts + 1] = hex(c, n .. " " .. word) end
    end
    add(sum.onTime, "on time", { 0.62, 0.94, 0.69 })
    add(sum.late, "late", { 1, 0.69, 0.4 })
    add(sum.left, "left early", { 1, 0.69, 0.4 })
    add(sum.noShow, sum.noShow == 1 and "no-show" or "no-shows", { 1, 0.5, 0.5 })
    if not short then
        add(sum.fill, sum.fill == 1 and "fill-in" or "fill-ins", C.fill)
        add(sum.pending or 0, "waiting", C.pending)
    end
    if #parts == 0 then return nil end
    return tconcat(parts, "   ")
end

---------------------------------------------------------------------------
-- 2. Overview: every member over the last raids
---------------------------------------------------------------------------

function AUI:CreateOverview(parent, width)
    local v = CreateFrame("Frame", nil, parent)
    v:SetSize(width, 500)
    v.state = { range = 8, lineup = nil, guests = false }
    local SQ, SQ_GAP = 15, 5
    v.cols = {}
    local function head(textKey, x, w, right)
        local fs = newText(v, 11, C.gold, "GameFontNormalSmall")
        fs:SetText(textKey)
        if right then
            fs:SetJustifyH("RIGHT")
            fs:SetPoint("TOPRIGHT", v, "TOPLEFT", x + w, 0)
        else
            fs:SetPoint("TOPLEFT", x, 0)
        end
        return fs
    end
    -- placed in Layout (the squares' width depends on the range)
    v.hPlayer = head("Player", 0, 150)
    v.hLineups = head("Lineups", 0, 80)
    v.hSquares = head("Last raids  (newest first)", 0, 180)
    v.hLate = head("Late", 0, 62, true)
    v.hLeft = head("Left early", 0, 76, true)
    v.hNo = head("No-shows", 0, 64, true)
    v.hPct = head("Attendance", 0, 84, true)
    v.line = tex(v, "BORDER", { 1, 1, 1 }, 0.1)
    v.line:SetPoint("TOPLEFT", 0, -16)
    v.line:SetSize(width, 1)

    local X = {}
    local function layout(nSq, noLineups)
        local sqW = nSq * SQ + max(0, nSq - 1) * SQ_GAP
        X.pct = width - 84
        X.no = X.pct - 16 - 64
        X.left = X.no - 16 - 76
        X.late = X.left - 16 - 62
        X.sq = X.late - 20 - sqW
        X.lineups = X.sq - 16 - 92
        X.nSq = nSq
        v.hLineups:SetShown(not noLineups)
        local function place(fs, x, w, right)
            fs:ClearAllPoints()
            if right then fs:SetPoint("TOPRIGHT", v, "TOPLEFT", x + w, 0) else fs:SetPoint("TOPLEFT", x, 0) end
        end
        place(v.hLineups, X.lineups, 92)
        place(v.hSquares, X.sq, sqW)
        place(v.hLate, X.late, 62, true)
        place(v.hLeft, X.left, 76, true)
        place(v.hNo, X.no, 64, true)
        place(v.hPct, X.pct, 84, true)
        v.hSquares:SetText(nSq >= 6 and "Last raids  (newest first)" or "Last raids")
    end
    layout(8)

    local function initRow(row, d)
        if not row.cdlInit then
            row.cdlInit = true
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row.zebra = tex(row, "BACKGROUND", { 1, 1, 1 }, 0.02)
            row.zebra:SetAllPoints()
            row.hl = tex(row, "BACKGROUND", { 1, 1, 1 }, 0.05, 1)
            row.hl:SetAllPoints()
            row.hl:Hide()
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(15, 15)
            row.icon:SetPoint("LEFT", 0, 0)
            row.name = newText(row, 13)
            row.name:SetPoint("LEFT", 22, 0)
            row.dot = tex(row, "OVERLAY", C.pending, 1)
            row.dot:SetSize(6, 6)
            row.extra = newText(row, 10, C.fill, "GameFontHighlightSmall")
            row.lineups = newText(row, 11, C.grey, "GameFontHighlightSmall")
            row.sq = {}
            row.late = newText(row, 12, { 1, 0.69, 0.4 })
            row.left = newText(row, 12, { 1, 0.69, 0.4 })
            row.no = newText(row, 12, C.missed)
            row.pct = newText(row, 12)
            for _, fs in ipairs({ row.late, row.left, row.no, row.pct }) do fs:SetJustifyH("RIGHT") end
            row.bar = CreateFrame("Frame", nil, row)
            row.bar:SetSize(40, 4)
            row.bar.bg = tex(row.bar, "BACKGROUND", C.track)
            row.bar.bg:SetAllPoints()
            row.bar.fill = row.bar:CreateTexture(nil, "ARTWORK")
            row.bar.fill:SetPoint("LEFT")
            row:SetScript("OnEnter", function(self)
                self.hl:Show()
                local s = self.cdlS
                if not s then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(name(s.key, s.cls))
                if s.lineups then GameTooltip:AddLine("Lineups: " .. s.lineups, 0.8, 0.8, 0.8) end
                GameTooltip:AddLine(s.pct and (("%d%% over %d raids that expected them"):format(s.pct, s.counted))
                    or "No raid expected them yet.", 1, 1, 1)
                if s.pending > 0 then GameTooltip:AddLine(s.pending .. " waiting for a review (not counted yet)", C.pending[1], C.pending[2], C.pending[3]) end
                if s.excused > 0 then GameTooltip:AddLine(s.excused .. " excused (counted as there)", C.excused[1], C.excused[2], C.excused[3]) end
                if s.fills > 0 then GameTooltip:AddLine(("Came to help %d times (%s)"):format(s.fills, dur(s.help)), C.fill[1], C.fill[2], C.fill[3]) end
                if s.clashes > 0 then GameTooltip:AddLine(s.clashes .. " sign-up(s) clashed with their team raid", 0.8, 0.8, 0.8) end
                if (s.lateCancels or 0) > 0 then
                    GameTooltip:AddLine(s.lateCancels .. " late cancel(s): Absent less than 2 hours before the start", 1, 0.69, 0.4)
                end
                GameTooltip:AddLine("Click for their raids.", 0.5, 0.5, 0.5)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function(self)
                self.hl:Hide()
                GameTooltip:Hide()
            end)
            row:SetScript("OnClick", function(self)
                if self.cdlS and v.onPick then v.onPick(self.cdlS.key) end
            end)
        end
        local s = d.s
        row.cdlS = s
        row.zebra:SetShown(d.i % 2 == 0)
        UI():ClassIcon(row.icon, classOf(s.key, s.cls))
        row.name:SetText(name(s.key, s.cls))
        local room = (v.noLineups and X.sq or X.lineups) - 22 - 10
        row.name:SetWidth(min(room, (row.name:GetStringWidth() or room) + 2))
        row.dot:ClearAllPoints()
        row.dot:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
        row.dot:SetShown(s.pending > 0)
        row.extra:ClearAllPoints()
        row.extra:SetPoint("LEFT", row.name, "RIGHT", s.pending > 0 and 16 or 8, 0)
        row.extra:SetText(s.fills > 0 and ("+" .. s.fills .. (s.fills == 1 and " fill-in" or " fill-ins")) or "")
        -- (only where it fits before the next column)
        row.extra:SetShown(22 + (row.name:GetWidth() or 0) + 24 + (row.extra:GetStringWidth() or 0) <= room + 22)
        row.lineups:ClearAllPoints()
        row.lineups:SetPoint("LEFT", X.lineups, 0)
        row.lineups:SetText(s.lineups or grey("-"))
        row.lineups:SetShown(not v.noLineups)
        for k = 1, X.nSq do
            local sq = row.sq[k]
            if not sq then
                sq = NewSquare(row, SQ)
                sq:EnableMouse(true)
                sq:SetScript("OnEnter", function(self)
                    row:GetScript("OnEnter")(row)
                    if self.night then
                        GameTooltip:SetOwner(self, "ANCHOR_TOP")
                        GameTooltip:AddLine(nightTitle(self.night))
                        GameTooltip:AddLine(codeText(self.code), 1, 1, 1)
                        GameTooltip:Show()
                    end
                end)
                sq:SetScript("OnLeave", function() row:GetScript("OnLeave")(row) end)
                sq:SetScript("OnMouseUp", function() row:Click() end)
                row.sq[k] = sq
            end
            sq:ClearAllPoints()
            sq:SetPoint("LEFT", X.sq + (k - 1) * (SQ + SQ_GAP), 0)
            sq.code = s.codes[k] or "-"
            sq.night = d.nights[k]
            sq:SetCode(sq.code)
            sq:SetShown(d.nights[k] ~= nil)
        end
        for k = X.nSq + 1, #row.sq do row.sq[k]:Hide() end
        local function place(fs, x, w, text)
            fs:ClearAllPoints()
            fs:SetPoint("RIGHT", row, "LEFT", x + w, 0)
            fs:SetText(text)
        end
        place(row.late, X.late, 62, s.late.n > 0 and dur(s.late.sec) or grey("-"))
        place(row.left, X.left, 76, s.left > 0 and tostring(s.left) or grey("-"))
        place(row.no, X.no, 64, s.noShows > 0 and tostring(s.noShows) or grey("-"))
        local pct = s.pct
        local pc = not pct and C.grey or pct >= 90 and { 0.62, 0.94, 0.69 } or pct >= 75 and { 1, 0.82, 0.3 } or { 1, 0.5, 0.45 }
        place(row.pct, X.pct, 84, pct and hex(pc, pct .. "%") or grey("-"))
        row.bar:ClearAllPoints()
        row.bar:SetPoint("RIGHT", row, "LEFT", X.pct + 84 - 44, 0)
        row.bar:SetShown(pct ~= nil)
        row.bar.fill:SetColorTexture(pc[1], pc[2], pc[3], 0.9)
        row.bar.fill:SetSize(max(1, 40 * (pct or 0) / 100), 4)
    end

    v.list = UI():CreateScrollList(v, 22, initRow)
    v.list.frame:SetPoint("TOPLEFT", 0, -20)
    v.list.frame:SetPoint("BOTTOMRIGHT", 20, 22)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPLEFT", v.list.box, "TOPRIGHT", 4, 0)
    v.list.bar:SetPoint("BOTTOMLEFT", v.list.box, "BOTTOMRIGHT", 4, 0)
    v.list:SetEmptyText("No raids logged yet.")
    v.legend = AUI:CreateLegend(v)
    v.legend:SetPoint("BOTTOMLEFT", 0, 2)

    function v:Refresh()
        local A = Att()
        local range = self.state.range
        local rows, nights = A:GetStats(range ~= 0 and range or nil, { guests = self.state.guests })
        local shown = {}
        for i = 1, min(#nights, 12) do shown[i] = nights[i] end
        local anyLineup = false
        for _, s in ipairs(rows) do if s.lineups then anyLineup = true break end end
        layout(max(1, min(#nights, 12)), not anyLineup)
        self.noLineups = not anyLineup
        local data = {}
        local lu = self.state.lineup
        for _, s in ipairs(rows) do
            if not lu or A:InLineup(s.key, lu.team, lu.id) then
                data[#data + 1] = { s = s, i = #data + 1, nights = shown }
            end
        end
        self.list:SetEmptyText(#nights == 0 and "No raids logged yet."
            or (lu and "Nobody in that lineup was expected or came.") or "Nobody was expected or came.")
        self.list:SetData(data)
        return #data, #nights
    end
    return v
end

---------------------------------------------------------------------------
-- 3. A player's page
---------------------------------------------------------------------------

function AUI:CreatePlayerPage(parent, width, opts)
    opts = opts or {}
    local v = CreateFrame("Frame", nil, parent)
    v:SetSize(width, 500)
    local BAN_H = 104
    -- the banner: art, back link, the player, the big number
    local b = CreateFrame("Frame", nil, v)
    b:SetSize(width, BAN_H)
    b:SetPoint("TOPLEFT")
    v.banner = b
    b.art = b:CreateTexture(nil, "BACKGROUND")
    b.art:SetAllPoints()
    ns.EventUI:AddShade(b)
    UI():AddEdges(b, "BORDER")
    UI():SetEdgeColor(b, 0.34, 0.34, 0.38, 0.6)
    if not opts.noBack then
        b.back = CreateFrame("Button", nil, b)
        b.back:SetSize(120, 18)
        b.back:SetPoint("TOPLEFT", 10, -8)
        b.back.chev = b.back:CreateTexture(nil, "OVERLAY")
        b.back.chev:SetSize(10, 10)
        b.back.chev:SetPoint("LEFT", 4, 0)
        UI():SetChevron(b.back.chev, false)
        b.back.fs = newText(b.back, 11, { 0.85, 0.85, 0.85 }, "GameFontHighlightSmall")
        b.back.fs:SetPoint("LEFT", b.back.chev, "RIGHT", 6, 0)
        b.back.fs:SetText("ATTENDANCE")
        b.back:SetScript("OnClick", function() if v.onBack then v.onBack() end end)
        b.back:SetScript("OnEnter", function(self) self.fs:SetTextColor(1, 0.82, 0) end)
        b.back:SetScript("OnLeave", function(self) self.fs:SetTextColor(0.85, 0.85, 0.85) end)
    end
    b.ring = b:CreateTexture(nil, "OVERLAY", nil, 1)
    b.ring:SetTexture(ns.EventUI.RING)
    b.ring:SetSize(58, 58)
    b.ring:SetPoint("BOTTOMLEFT", 12, 10)
    b.icon = b:CreateTexture(nil, "OVERLAY", nil, 0)
    b.icon:SetSize(46, 46)
    b.icon:SetPoint("CENTER", b.ring)
    b.name = newText(b, 19, nil, "GameFontHighlightLarge")
    b.name:SetPoint("BOTTOMLEFT", 82, 38)
    b.tag = pill(b, 16)
    b.tag:SetPoint("LEFT", b.name, "RIGHT", 10, 0)
    b.sub = newText(b, 11, { 0.86, 0.86, 0.86 }, "GameFontHighlightSmall")
    b.sub:SetPoint("BOTTOMLEFT", 82, 18)
    b.big = newText(b, 30, { 1, 0.82, 0.3 }, "GameFontHighlightLarge")
    b.big:SetJustifyH("RIGHT")
    b.big:SetPoint("BOTTOMRIGHT", -16, 30)
    b.cap = newText(b, 11, { 0.86, 0.86, 0.86 }, "GameFontHighlightSmall")
    b.cap:SetJustifyH("RIGHT")
    b.cap:SetPoint("BOTTOMRIGHT", -16, 14)
    -- reviewers: excuse a stretch away
    b.away = UI():CreateSleekButton(b, "Excuse a period", 120, 22, function() AUI:OpenAwayDialog(v.key) end)
    b.away:SetPoint("TOPRIGHT", -10, -8)
    -- the away periods set here (this computer), each with Remove (which takes back the raids it excused)
    b.awayList = UI():CreateSleekMenuButton(b, "Away", 76, function(root)
        local list = Att():GetAway(v.key)
        root:CreateTitle("Away periods")
        for _, p in ipairs(list) do
            local label = date("%d %b", p.f) .. " – " .. date("%d %b", p.t) .. (p.n and p.n:find(":") and ("  " .. p.n:match(":%s*(.*)$")) or "")
            local e = root:CreateButton("Remove: " .. label, function() Att():RemoveAway(p) end)
            e:SetTitleAndTextTooltip("Remove this away period", "Takes back the excuses it gave (set by " .. short(p.by) .. ").")
        end
    end, 22)
    b.awayList:SetPoint("RIGHT", b.away, "LEFT", -6, 0)
    -- four facts
    local GAP = 8
    local FW = floor((width - 3 * GAP) / 4)
    v.facts = {}
    for i = 1, 4 do
        local c = CreateFrame("Frame", nil, v)
        c:SetSize(FW, 54)
        c:SetPoint("TOPLEFT", (i - 1) * (FW + GAP), -(BAN_H + 8))
        c.bg = tex(c, "BACKGROUND", C.card)
        c.bg:SetAllPoints()
        UI():AddEdges(c, "BORDER")
        UI():SetEdgeColor(c, 0.34, 0.34, 0.38, 0.45)
        c.l = newText(c, 10, C.grey, "GameFontHighlightSmall")
        c.l:SetPoint("TOPLEFT", 12, -9)
        c.n = newText(c, 16)
        c.n:SetPoint("TOPLEFT", 12, -26)
        c.s = newText(c, 11, C.grey, "GameFontHighlightSmall")
        c.s:SetPoint("LEFT", c.n, "RIGHT", 8, -1)
        v.facts[i] = c
    end
    -- the last 12 raids as columns
    local ch = CreateFrame("Frame", nil, v)
    ch:SetSize(width, 104)
    ch:SetPoint("TOPLEFT", 0, -(BAN_H + 8 + 54 + 8))
    ch.bg = tex(ch, "BACKGROUND", C.card)
    ch.bg:SetAllPoints()
    UI():AddEdges(ch, "BORDER")
    UI():SetEdgeColor(ch, 0.34, 0.34, 0.38, 0.45)
    ch.l = newText(ch, 10, C.grey, "GameFontHighlightSmall")
    ch.l:SetText("LAST 12 RAIDS")
    ch.l:SetPoint("TOPLEFT", 12, -9)
    ch.cols = {}
    v.chart = ch
    local CW, CG, CHT = 46, 14, 54
    for i = 1, 12 do
        local col = CreateFrame("Frame", nil, ch)
        col:SetSize(CW, CHT + 20)
        col:SetPoint("BOTTOMLEFT", floor((width - (12 * CW + 11 * CG)) / 2) + (i - 1) * (CW + CG), 6)
        col.base = tex(col, "ARTWORK", C.track)
        col.base:SetPoint("BOTTOMLEFT", 0, 18)
        col.base:SetSize(CW, CHT)
        col.fill = col:CreateTexture(nil, "ARTWORK", nil, 1)
        col.fill:SetPoint("BOTTOMLEFT", 0, 18)
        col.miss = col:CreateTexture(nil, "ARTWORK", nil, 1)
        col.dot = tex(col, "OVERLAY", C.pending, 1)
        col.dot:SetSize(6, 6)
        col.lb = newText(col, 10, C.dim, "GameFontHighlightSmall")
        col.lb:SetJustifyH("CENTER")
        col.lb:SetPoint("BOTTOM", 0, 2)
        col:EnableMouse(true)
        col:SetScript("OnEnter", function(self)
            if not self.night then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(nightTitle(self.night))
            if self.r then AUI:ResultTooltip(GameTooltip, self.r) else GameTooltip:AddLine("Not expected", 0.8, 0.8, 0.8) end
            GameTooltip:Show()
        end)
        col:SetScript("OnLeave", function() GameTooltip:Hide() end)
        ch.cols[i] = col
    end
    -- the raids, newest first
    local TOP = BAN_H + 8 + 54 + 8 + 104 + 10
    local cols = { { "Raid", 0 }, { "Why expected", width * 0.31 }, { "Expected", width * 0.445 },
                   { "In the group", width * 0.59 }, { "Result", width * 0.74 }, { "Credit", width, r = true } }
    v.colX = {}
    for _, c in ipairs(cols) do
        local fs = newText(v, 11, C.gold, "GameFontNormalSmall")
        fs:SetText(c[1])
        if c.r then
            fs:SetJustifyH("RIGHT")
            fs:SetPoint("TOPRIGHT", v, "TOPLEFT", c[2], -TOP)
        else
            fs:SetPoint("TOPLEFT", floor(c[2]), -TOP)
        end
        v.colX[c[1]] = floor(c[2])
    end
    local function initRow(row, d)
        if not row.cdlInit then
            row.cdlInit = true
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row.hl = tex(row, "BACKGROUND", { 1, 1, 1 }, 0.04)
            row.hl:SetAllPoints()
            row.hl:Hide()
            row.art = row:CreateTexture(nil, "ARTWORK")
            row.art:SetSize(40, 22)
            row.art:SetPoint("LEFT", 0, 0)
            row.raid = newText(row, 12)
            row.raid:SetPoint("TOPLEFT", 48, -4)
            row.when = newText(row, 10, C.grey, "GameFontHighlightSmall")
            row.when:SetPoint("BOTTOMLEFT", 48, 5)
            row.why = newText(row, 11, C.grey, "GameFontHighlightSmall")
            row.exp = newText(row, 11, { 0.86, 0.86, 0.86 }, "GameFontHighlightSmall")
            row.ing = newText(row, 11, { 0.86, 0.86, 0.86 }, "GameFontHighlightSmall")
            row.pill = pill(row, 16)
            row.credit = newText(row, 12)
            row.credit:SetJustifyH("RIGHT")
            row.credit:SetPoint("RIGHT", 0, 0)
            row:SetScript("OnEnter", function(self)
                self.hl:Show()
                if not self.cdlR then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                AUI:ResultTooltip(GameTooltip, self.cdlR)
                if Att():CanReview() then GameTooltip:AddLine("Right-click to decide or pick from chat.", 0.5, 0.5, 0.5) end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function(self)
                self.hl:Hide()
                GameTooltip:Hide()
            end)
            row:SetScript("OnClick", function(self, button)
                if button == "RightButton" and self.cdlR and Att():CanReview() then AUI:ResultMenu(self, self.cdlR) end
            end)
        end
        local r, n = d.r, d.night
        row.cdlR = r
        setArt(row.art, n, 40, 22, 0.3)
        local room = v.colX["Why expected"] - 48 - 10
        local full = nightName(n)
        fit(row.raid, { full, shortZone(full) }, room)
        row.raid:SetWidth(room)
        row.when:SetText(date("%a %d %b", n.start or Now()))
        local function at(fs, key, text)
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", v.colX[key], 0)
            fs:SetText(text)
        end
        local why = r.clash and "Team raid instead" or (r.kind == "l" and (d.lineup or "Lineup"))
            or (r.kind == "a" and "Signed up") or (r.help and "Came to help") or "-"
        at(row.why, "Why expected", why)
        local whyRoom = v.colX["Expected"] - v.colX["Why expected"] - 10
        fit(row.why, { why, (why:gsub("^[^·]+·%s*", "")), "Lineup" }, whyRoom)
        row.why:SetWidth(whyRoom)
        at(row.exp, "Expected", r.kind and (clock(r.F) .. " – " .. clock(r.T)) or "-")
        at(row.ing, "In the group", (r.first and r.last) and (clock(r.first) .. " – " .. clock(r.last))
            or (r.noShow and grey("not there") or "-"))
        local text, kind = AUI:ResultWord(r)
        row.pill:ClearAllPoints()
        row.pill:SetPoint("LEFT", v.colX["Result"], 0)
        row.pill:SetKind(text, kind)
        local credit
        if not r.kind then credit = r.help and hex(C.fill, "+" .. dur(r.help)) or grey("-")
        elseif r.pending then credit = hex(C.pending, pctText(r))
        else credit = pctText(r) end
        row.credit:SetText(credit)
    end
    v.list = UI():CreateScrollList(v, 36, initRow)
    v.list.frame:SetPoint("TOPLEFT", 0, -(TOP + 18))
    v.list.frame:SetPoint("BOTTOMRIGHT", 20, 0)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPLEFT", v.list.box, "TOPRIGHT", 4, 0)
    v.list.bar:SetPoint("BOTTOMLEFT", v.list.box, "BOTTOMRIGHT", 4, 0)
    v.list:SetEmptyText("No raid expected them yet.")

    -- key: the player; remote = { p, n, h } (a member's own attendance from a reader) instead of computing it.
    function v:SetPlayer(key, remote)
        self.key = key
        local A = Att()
        local cls = classOf(key)
        UI():ClassIcon(b.icon, cls)
        b.name:SetText(name(key, cls))
        local lineups = A:LineupsOf(key)
        b.tag:SetShown(lineups ~= nil)
        if lineups then b.tag:SetKind(lineups, "mute") end
        local G = ns.Guild
        local rank = G and G.GetRankName and G:GetRankName(key)
        local alts = G and G.GetLinkedCharacters and G:GetLinkedCharacters(key) or {}
        local sub = rank or ""
        if #alts > 0 then
            local names = {}
            for i, m in ipairs(alts) do if i <= 3 then names[#names + 1] = name(m) end end
            sub = sub .. (sub ~= "" and " · " or "") .. "also plays " .. tconcat(names, ", ") .. grey(" (counts as one player)")
        end
        -- (the loot council: the items they received over the same raids)
        if not remote and (demoOn() or (G and G.IsGuildCouncil and G:IsGuildCouncil(ns.Util.PlayerKey()))) then
            local RL = ns.RaidLog
            for _, ps in ipairs(RL and RL.GetPlayerStats and RL:GetPlayerStats(12) or {}) do
                if ps.key == key and ps.items > 0 then
                    sub = sub .. (sub ~= "" and " · " or "") .. ps.items .. (ps.items == 1 and " item" or " items")
                        .. (ps.lastItem and (", last " .. UI():ItemText(ps.lastItem.i)) or "")
                    break
                end
            end
        end
        b.sub:SetText(sub)
        b.away:SetShown(A:CanReview() and not remote and not opts.noAway)
        local away = A:CanReview() and not remote and not opts.noAway and A:GetAway(key) or {}
        b.awayList:SetShown(#away > 0)
        b.awayList:SetText("Away (" .. #away .. ")")
        local hist, stats, nNights
        if remote then
            hist, stats = {}, { pct = remote.p, counted = remote.n or 0 }
        else
            hist, stats, nNights = A:GetHistory(key, 12)
        end
        setArt(b.art, (hist[1] and hist[1].night) or "kara", width, BAN_H, 0.98)
        local pct = stats and stats.pct
        b.big:SetText(pct and (pct .. "%") or "-")
        b.cap:SetText(pct and ("of the expected time · " .. (stats.counted or 0) .. " raids") or "no raid expected them yet")
        -- facts
        local s = stats or {}
        local team, signed = 0, 0
        for _, e in ipairs(hist) do
            if e.r.kind == "l" then team = team + 1 elseif e.r.kind == "a" then signed = signed + 1 end
        end
        local facts = {
            { "Expected", (s.counted or 0) .. " raids", (s.excused or 0) > 0 and (s.excused .. " excused")
                or (team > 0 and signed > 0) and (team .. " lineup · " .. signed .. " sign-up")
                or (signed > 0 and "signed up") or (team > 0 and "in a lineup") or "" },
            { "Late", ((s.late and s.late.n) or 0) .. " times", s.late and s.late.n > 0 and (dur(s.late.sec) .. " in all") or "" },
            { "Left early", (s.left or 0) .. " times", "" },
            { "No-shows", tostring(s.noShows or 0), (s.lateCancels or 0) > 0 and ("late cancels: " .. s.lateCancels)
                or ((s.fills or 0) > 0 and ("fill-ins: " .. s.fills) or "") },
        }
        for i, f in ipairs(facts) do
            local c = v.facts[i]
            c.l:SetText(f[1]:upper())
            c.n:SetText(f[2])
            c.s:SetText(f[3])
        end
        -- the chart: the last 12 nights of the guild
        local nights, rmap = {}, {}
        if remote then
            for i, e in ipairs(remote.h or {}) do
                nights[i] = { start = e.d, zone = e.z, remote = e }
            end
        else
            local rules = A:Rules()
            for i, item in ipairs(A:Results(A:ClosedNights(12), rules)) do
                nights[i] = item.night
                local r = item.results[key]
                if not r then
                    for other, x in pairs(item.results) do
                        if G and G.SameAccount and G:SameAccount(other, key) and (x.kind or x.help) then r = x break end
                    end
                end
                rmap[i] = r
            end
        end
        for i = 1, 12 do
            local col = ch.cols[13 - i]           -- newest on the right
            local n = nights[i]
            col.night, col.r = n and not n.remote and n or nil, rmap[i]
            col:SetShown(n ~= nil)
            if n then
                local code, credit
                if n.remote then
                    code, credit = n.remote.s, (n.remote.c or 0) / 100
                else
                    local r = rmap[i]
                    code = A.Code(r)
                    credit = r and r.credit or 0
                end
                local CHT2 = 54
                local col0 = code == "E" and C.excused or code == "H" and C.fill or code == "-" and { 1, 1, 1 }
                    or code == "B" and C.bench or C.present
                local h = (code == "-") and 2 or (code == "H" and 18) or (code == "N" and 2) or CHT2 * max(0, min(1, credit))
                col.fill:SetColorTexture(col0[1], col0[2], col0[3], code == "-" and 0.2 or 0.85)
                if code == "N" then col.fill:SetColorTexture(C.missed[1], C.missed[2], C.missed[3], 0.85) end
                col.fill:SetSize(46, max(2, h))
                local partial = (type(code) == "string" and code:sub(1, 1) == "p") or code == "R"
                col.miss:ClearAllPoints()
                col.miss:SetPoint("BOTTOMLEFT", 0, 18 + h)
                col.miss:SetSize(46, max(1, CHT2 - h))
                col.miss:SetColorTexture(C.missed[1], C.missed[2], C.missed[3], 0.55)
                col.miss:SetShown(partial and h < CHT2)
                col.dot:ClearAllPoints()
                col.dot:SetPoint("BOTTOM", col, "BOTTOM", 0, 18 + CHT2 + 3)
                col.dot:SetShown(code == "R")
                col.lb:SetText(date("%d %b", n.start or Now()):gsub("^0", ""))
            end
        end
        -- the raids
        local rows = {}
        for _, e in ipairs(hist) do
            rows[#rows + 1] = { r = e.r, night = e.night, lineup = AUI:LineupLabel(e.night) }
        end
        if remote then
            self.list:SetEmptyText("")
        end
        self.list:SetData(rows, true)
        self.list.frame:SetShown(not remote)
    end
    return v
end

-- The member card's Attendance tab (UI/Members.lua): the number, the facts in a line, each raid. Reviewers and the
-- raid log's readers see anyone's; a member sees their own (from a raid log reader when they don't keep the log).
function AUI:CreateMemberAttendance(parent, width)
    local v = CreateFrame("Frame", nil, parent)
    v:SetSize(width, 300)
    v.big = newText(v, 24, { 1, 0.82, 0.3 }, "GameFontHighlightLarge")
    v.big:SetPoint("TOPLEFT", 2, -10)
    v.cap = newText(v, 11, C.grey, "GameFontHighlightSmall")
    v.cap:SetPoint("LEFT", v.big, "RIGHT", 10, -2)
    v.facts = newText(v, 11, { 0.86, 0.86, 0.86 }, "GameFontHighlightSmall")
    v.facts:SetPoint("TOPLEFT", 2, -42)
    v.facts:SetWidth(width - 4)
    v.src = newText(v, 10, { 0.5, 0.5, 0.52 }, "GameFontHighlightSmall")
    v.src:SetJustifyH("RIGHT")
    v.src:SetPoint("TOPRIGHT", -4, -16)
    local function initRow(row, d)
        if not row.cdlInit then
            row.cdlInit = true
            row.art = row:CreateTexture(nil, "ARTWORK")
            row.art:SetSize(34, 20)
            row.art:SetPoint("LEFT", 0, 0)
            row.raid = newText(row, 12)
            row.raid:SetPoint("LEFT", 42, 0)
            row.pill = pill(row, 16)
            row.credit = newText(row, 12)
            row.credit:SetJustifyH("RIGHT")
            row.credit:SetPoint("RIGHT", -2, 0)
            row:SetScript("OnEnter", function(self)
                if not self.cdlR then return end
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                AUI:ResultTooltip(GameTooltip, self.cdlR)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.explain = UI():CreateSleekButton(row, "Explain", 70, 20, function(self)
                local dd = self:GetParent().cdlD
                if dd and dd.id then AUI:ShowExplain(dd.id, dd.zone, dd.start) end
            end)
            row.explain:SetPoint("RIGHT", row, "RIGHT", -52 - 4, 0)
        end
        row.cdlR = d.r
        row.cdlD = d
        if d.inst then setArt(row.art, d.inst, 34, 20, 0.3) else row.art:Hide() end
        local room = width - 42 - 52 - 140 - (d.explain and 78 or 0)
        fit(row.raid, { (d.zone or "Raid") .. grey("  " .. date("%a %d %b", d.start or Now())),
                        shortZone(d.zone) .. grey("  " .. date("%d %b", d.start or Now())) }, room)
        row.raid:SetWidth(room)
        -- (my own raid that didn't go as planned: Explain sends my reason to the officers)
        row.explain:SetShown(d.explain and true or false)
        row.pill:ClearAllPoints()
        if d.explain then
            row.pill:SetPoint("RIGHT", row.explain, "LEFT", -8, 0)
        else
            row.pill:SetPoint("RIGHT", row, "RIGHT", -52, 0)
        end
        row.pill:SetKind(d.word, d.kind)
        row.credit:SetText(d.credit)
    end
    v.list = UI():CreateScrollList(v, 26, initRow)
    v.list.frame:SetPoint("TOPLEFT", 0, -64)
    v.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)

    -- key: the member.
    function v:SetPlayer(key)
        local A = Att()
        local rows = {}
        local G0 = ns.Guild
        local own = ns.Util.IsMe(key) or (G0 and G0.SameAccount and G0:SameAccount(ns.Util.PlayerKey(), key)) or false
        local pct, counted, s
        if A:CanSeeAll() then
            local hist
            hist, s = A:GetHistory(key, 12)
            pct, counted = s and s.pct, s and s.counted or 0
            for _, e in ipairs(hist) do
                local word, kind = AUI:ResultWord(e.r)
                local r = e.r
                local mine = r.kind and own and not r.reason and not r.decision and (r.noShow or r.late > 0 or r.left > 0)
                    and not r.bench and not r.loose
                rows[#rows + 1] = { r = r, zone = nightName(e.night), start = e.night.start, inst = instOf(e.night), word = word,
                    kind = kind, credit = not r.kind and (r.help and hex(C.fill, "+" .. dur(r.help)) or grey("-"))
                        or (r.pending and hex(C.pending, pctText(r))) or pctText(r),
                    id = e.night.primary and e.night.primary.id, explain = mine }
            end
            v.src:SetText("")
        else
            local mine = A:GetMine()
            A:RequestMine()
            if mine then
                pct, counted = mine.p, mine.n
                for _, e in ipairs(mine.h or {}) do
                    local code = e.s or "-"
                    local word = code == "F" and "Full" or (code:sub(1, 1) == "p" and "Part of it") or CODE_TEXT[code] or code
                    local kind = (code == "F" or code == "B" or code == "H") and "ok" or (code == "E" and "alt")
                        or (code == "-" and "mute") or "warn"
                    local miss = code == "N" or code == "R" or (code:sub(1, 1) == "p")
                    rows[#rows + 1] = { zone = e.z, start = e.d, word = word, kind = kind,
                        credit = e.c and (e.c .. "%") or grey("-"), id = e.i, explain = miss and e.i and not e.rs }
                end
                v.src:SetText(mine.from and ("from " .. short(mine.from) .. "'s raid log, " .. date("%d %b %H:%M", mine.at or Now())) or "")
            else
                v.src:SetText("")
            end
        end
        v.big:SetText(pct and (pct .. "%") or "-")
        v.cap:SetText(pct and ("of the expected time · " .. (counted or 0) .. " raids") or "")
        if s then
            local parts = {}
            parts[#parts + 1] = "Late " .. (s.late.n > 0 and (s.late.n .. " (" .. dur(s.late.sec) .. ")") or "0")
            parts[#parts + 1] = "Left early " .. s.left .. (s.excused > 0 and (" · " .. s.excused .. " excused") or "")
            parts[#parts + 1] = "No-shows " .. s.noShows
            if s.fills > 0 then parts[#parts + 1] = "Came to help " .. s.fills end
            if s.pending > 0 then parts[#parts + 1] = hex(C.pending, s.pending .. " waiting for a review") end
            v.facts:SetText(tconcat(parts, "   ·   "))
        else
            v.facts:SetText("")
        end
        self.list:SetEmptyText(A:CanSeeAll() and "No raid expected them yet."
            or (A:GetMine() and "No raid expected you yet.")
            or "Your attendance comes from the officers' raid log: it shows here once one of them is online.")
        self.list:SetData(rows, true)
        return true
    end
    return v
end

-- The result's word and pill kind: "Full", "Late 42 min", "Left early · excused", "No-show", "Came to help", ...
function AUI:ResultWord(r)
    if not r.kind then
        if r.clash then return "Team raid instead", "mute" end
        return "Came to help", "ok"
    end
    if r.loose then return "Came", "ok" end
    if r.otherRaid and not r.pending then return "Other raid", "alt" end
    local w
    if r.bench then w = "Bench"
    elseif r.removed then w = "Removed"
    elseif r.otherRaid then w = "In another raid"
    elseif r.noShow then w = (r.note and r.note.x) and "Absent · told us" or "No-show"
    elseif r.left > 0 then w = "Left early"
    elseif r.late > 0 then w = "Late " .. dur(r.late)
    elseif r.away > 60 then w = "Away " .. dur(r.away)
    else w = "Full" end
    if r.pending then return w .. " · review", "warn" end
    if r.excused and w ~= "Full" then return w .. " · excused", "alt" end
    if w == "Full" or r.bench or r.removed then return w, "ok" end
    if r.noShow then return w, "warn" end
    return w, "warn"
end

-- Reviewers: excuse every raid of a stretch. The polls' calendar look (UI/PollsTab.lua): a month of days, click the
-- first day and then the last, the days between lit; a dot marks a day with a raid for them (grey: logged, gold:
-- planned), and a line under says what gets excused.
local AWAY = { CELL_W = 44, CELL_H = 30, W = 392, MAX_DAYS = 120 }

local function dayStart(t)
    local d = date("*t", t)
    return time({ year = d.year, month = d.month, day = d.day, hour = 0 })
end

-- The days (day start -> "logged" | "planned") with a raid for `key` in the month shown, and the raids in [from, to].
local function awayRaids(key, from, to)
    local A = Att()
    local days, inRange = {}, { logged = 0, planned = 0 }
    for _, n in ipairs(A:GetNights()) do
        if A:ExpectedKey(n, key) and n.start then
            local d = dayStart(n.start)
            days[d] = "logged"
            if from and d >= from and d <= to then inRange.logged = inRange.logged + 1 end
        end
    end
    local RP = ns.RaidPlan
    local G = ns.Guild
    for _, v in ipairs(RP and RP.GetRaids and RP:GetRaids(Now() - 3600, Now() + 90 * 86400) or {}) do
        if not v.cancelled then
            local inv = RP:GetInvited(v)
            local s = RP:GetSignups(v.id)
            local me = (inv and inv[key]) or (s[key] and s[key].st == "A")
            if not me then
                for _, m in ipairs(G and G.GetLinkedCharacters and G:GetLinkedCharacters(key) or {}) do
                    if (inv and inv[m]) or (s[m] and s[m].st == "A") then me = true break end
                end
            end
            if me then
                local d = dayStart(v.t)
                if not days[d] then
                    days[d] = "planned"
                    if from and d >= from and d <= to then inRange.planned = inRange.planned + 1 end
                end
            end
        end
    end
    return days, inRange
end

function AUI:OpenAwayDialog(key)
    if not key then return end
    local f = self.awayDialog
    local CW, CH = AWAY.CELL_W, AWAY.CELL_H
    if not f then
        f = CreateFrame("Frame", "DisasterZoneAttendanceAway", UIParent)
        if UISpecialFrames then tinsert(UISpecialFrames, "DisasterZoneAttendanceAway") end
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        f:SetClampedToScreen(true)
        f:EnableMouse(true)
        f:SetSize(AWAY.W, 104 + 6 * CH + 26 + 24 + 52)
        f:SetPoint("CENTER", 0, 60)
        ns.Popup:SkinPanel(f)
        f.title:SetPoint("TOPLEFT", 16, -14)
        f.glint:SetPoint("TOPLEFT", 1, -1)
        f.glint:SetWidth(AWAY.W - 2)
        f.close = UI():CreateCloseButton(f, 20, function() f:Hide() end)
        f.close:SetPoint("TOPRIGHT", -8, -8)
        f.hint = newText(f, 11, C.grey, "GameFontHighlightSmall")
        f.hint:SetPoint("TOPLEFT", 16, -38)
        f.hint:SetText("Click the first day away, then the last.")
        -- the month: name, arrows, weekday letters, the days
        local gridW = 7 * CW
        local x0 = floor((AWAY.W - gridW) / 2)
        f.month = newText(f, 13)
        f.month:SetPoint("TOPLEFT", x0, -62)
        f.next = UI():CreateArrowButton(f, true, 16, 16, function() f.shift(1) end)
        f.next:SetPoint("TOPRIGHT", -x0, -60)
        f.prev = UI():CreateArrowButton(f, false, 16, 16, function() f.shift(-1) end)
        f.prev:SetPoint("RIGHT", f.next, "LEFT", -6, 0)
        for i, w in ipairs({ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }) do
            local fs = newText(f, 9, { 0.55, 0.55, 0.55 }, "GameFontHighlightSmall")
            fs:SetJustifyH("CENTER")
            fs:SetWidth(CW)
            fs:SetPoint("TOPLEFT", x0 + (i - 1) * CW, -86)
            fs:SetText(w)
        end
        f.cells = {}
        for i = 1, 42 do
            local b = CreateFrame("Button", nil, f)
            b:SetSize(CW, CH)
            b:SetPoint("TOPLEFT", x0 + ((i - 1) % 7) * CW, -(100 + floor((i - 1) / 7) * CH))
            b.band = b:CreateTexture(nil, "BACKGROUND", nil, 1)
            b.band:SetPoint("TOPLEFT", 0, -3)
            b.band:SetPoint("BOTTOMRIGHT", 0, 3)
            b.band:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.16)
            b.disc = b:CreateTexture(nil, "ARTWORK")
            b.disc:SetTexture(ns.EventUI.MASK)
            b.disc:SetSize(25, 25)
            b.disc:SetPoint("CENTER")
            b.disc:SetVertexColor(C.gold[1], C.gold[2], C.gold[3])
            b.hl = b:CreateTexture(nil, "HIGHLIGHT")
            b.hl:SetTexture(ns.EventUI.MASK)
            b.hl:SetSize(25, 25)
            b.hl:SetPoint("CENTER")
            b.hl:SetVertexColor(1, 1, 1, 0.1)
            b.fs = newText(b, 11)
            b.fs:SetJustifyH("CENTER")
            b.fs:SetPoint("CENTER", 0, 1)
            b.dot = b:CreateTexture(nil, "OVERLAY")
            b.dot:SetTexture(ns.EventUI.MASK)
            b.dot:SetSize(4, 4)
            b.dot:SetPoint("BOTTOM", 0, 3)
            b:SetScript("OnClick", function(self) if self.day then f.pick(self.day) end end)
            b:SetScript("OnEnter", function(self)
                if not self.day then return end
                f.hover = self.day
                if f.choosing then f.paint() end
                local kind = f.raidDays[self.day]
                if kind then
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    GameTooltip:AddLine(date("%A %d %B", self.day))
                    GameTooltip:AddLine(kind == "logged" and "A raid they were expected at" or "A raid planned for them", 1, 1, 1)
                    GameTooltip:Show()
                end
            end)
            b:SetScript("OnLeave", function()
                GameTooltip:Hide()
                f.hover = nil
                if f.choosing then f.paint() end
            end)
            f.cells[i] = b
        end
        -- what gets excused, a note, the buttons
        f.sum = newText(f, 12, { 0.9, 0.9, 0.9 })
        f.sum:SetPoint("TOPLEFT", 16, -(104 + 6 * CH + 4))
        f.sum:SetWidth(AWAY.W - 32)
        f.note = UI():CreateSleekEditBox(f, AWAY.W - 32, 24)
        f.note:SetPoint("TOPLEFT", 16, -(104 + 6 * CH + 26))
        UI():SetEditPlaceholder(f.note, "A note (holiday, moving, ...)")
        f.ok = UI():CreateSleekButton(f, "Excuse", 96, 24, function()
            local ok, res = Att():ExcusePeriod(f.key, f.from, f.to, f.note:GetText())
            if ok then
                ns:Print("excused %s from %d raid(s); raids logged later in those days are excused too.", short(f.key), res or 0)
                f:Hide()
            else
                ns:Print("%s", tostring(res))
            end
        end, "primary")
        f.ok:SetPoint("BOTTOMRIGHT", -14, 14)
        f.cancel = UI():CreateSleekButton(f, "Cancel", 90, 24, function() f:Hide() end)
        f.cancel:SetPoint("RIGHT", f.ok, "LEFT", -6, 0)

        function f.shift(delta)
            local y, m = f.y, f.m + delta
            if m < 1 then y, m = y - 1, 12 elseif m > 12 then y, m = y + 1, 1 end
            f.y, f.m = y, m
            f.paint()
        end
        function f.pick(day)
            if not f.choosing or day < f.from then
                f.from, f.to, f.choosing = day, day, true
            else
                local fd = date("*t", f.from)
                f.to = min(day, time({ year = fd.year, month = fd.month, day = fd.day + AWAY.MAX_DAYS - 1, hour = 0 }))
                f.choosing = false
            end
            f.paint()
        end
        function f.paint()
            local first = time({ year = f.y, month = f.m, day = 1, hour = 0 })
            local wd = (tonumber(date("%w", first)) + 6) % 7          -- Monday first
            local dim = tonumber(date("%d", time({ year = f.y, month = f.m + 1, day = 0, hour = 12 })))
            f.month:SetText(date("%B %Y", first))
            local to = f.to
            if f.choosing and f.hover and f.hover > f.from then to = f.hover end
            local today = dayStart(Now())
            for i, b in ipairs(f.cells) do
                local dd = i - wd
                if dd >= 1 and dd <= dim then
                    local day = time({ year = f.y, month = f.m, day = dd, hour = 0 })
                    b.day = day
                    b.fs:SetText(tostring(dd))
                    local edge = day == f.from or day == to
                    local inside = f.from and day >= f.from and day <= to
                    b.disc:SetShown(edge)
                    b.band:SetShown(inside and not (f.from == to))
                    b.band:ClearAllPoints()
                    b.band:SetPoint("TOPLEFT", day == f.from and floor(CW / 2) or 0, -3)
                    b.band:SetPoint("BOTTOMRIGHT", day == to and -floor(CW / 2) or 0, 3)
                    if edge then
                        b.fs:SetTextColor(0.1, 0.08, 0)
                        b.fs:SetShadowColor(0, 0, 0, 0)
                    else
                        local c = day == today and C.gold or (inside and { 1, 0.93, 0.75 }) or { 0.86, 0.86, 0.86 }
                        b.fs:SetTextColor(c[1], c[2], c[3])
                        b.fs:SetShadowColor(0, 0, 0, 1)
                    end
                    local kind = f.raidDays[day]
                    b.dot:SetShown(kind ~= nil and not edge)
                    if kind == "planned" then b.dot:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 1)
                    else b.dot:SetVertexColor(0.7, 0.7, 0.72, 1) end
                    b:Show()
                else
                    b.day = nil
                    b:Hide()
                end
            end
            -- what gets excused
            local days = floor((to - f.from) / 86400 + 0.5) + 1      -- (rounded: a clock change moves it an hour)
            local _, r = awayRaids(f.key, f.from, to)
            local raids = r.logged + r.planned
            local span = f.from == to and date("%a %d %b", f.from)
                or (date("%a %d %b", f.from) .. " – " .. date("%a %d %b", to))
            local tail = raids == 0 and grey("no raid for them in those days yet")
                or ((r.logged > 0 and (r.logged .. " logged") or "") .. ((r.logged > 0 and r.planned > 0) and ", " or "")
                    .. (r.planned > 0 and (r.planned .. " planned") or "") .. (raids == 1 and " raid" or " raids"))
            f.sum:SetText(span .. grey("  ·  " .. days .. (days == 1 and " day" or " days") .. "  ·  ") .. tail)
        end
        self.awayDialog = f
    end
    f.key = key
    f.title:SetText("Away: " .. short(key))
    local today = dayStart(Now())
    local td = date("*t", today)
    f.from, f.to, f.choosing, f.hover = today, time({ year = td.year, month = td.month, day = td.day + 6, hour = 0 }), false, nil
    local t = date("*t", today)
    f.y, f.m = t.year, t.month
    f.raidDays = awayRaids(key)
    f.note:SetText("")
    f.paint()
    f:Show()
end

---------------------------------------------------------------------------
-- 4. Reviews
---------------------------------------------------------------------------

-- The lines a review card says: { { text, color }, ... } (what happened, the reasons, the fill-in).
function AUI:ReviewLines(r)
    local n = r.night
    local out = {}
    local what
    if r.noShow then
        if r.note and r.note.x then
            what = "Answered Absent" .. (r.note.at and (" on " .. date("%a %d %b", r.note.at)) or "")
        else
            what = (r.kind == "l" and "In the raid's lineup" or "Answered Accept") .. " · never joined the group"
        end
    elseif r.left > 0 then
        local missed = 0
        for _, b in ipairs(n.bosses) do
            if (b.ts or 0) > (r.last or 0) and (b.ts or 0) <= r.T then missed = missed + 1 end
        end
        what = ("Left at %s · %s before the planned end"):format(clock(r.last), dur(r.left))
            .. (missed > 0 and (" · missed " .. missed .. " of " .. #n.bosses .. " bosses") or "")
    elseif r.late > 0 then
        local missed = {}
        for _, b in ipairs(n.bosses) do
            if (b.ts or 0) < (r.first or 0) then missed[#missed + 1] = b.name or "a boss" end
        end
        what = ("Joined at %s · the raid started at %s"):format(clock(r.first), clock(r.E))
            .. (#missed > 0 and (" · missed " .. tconcat(missed, ", ", 1, min(#missed, 2))
                .. (#missed > 2 and (" +" .. (#missed - 2)) or "")) or "")
    else
        what = ("In the raid %s of %s"):format(dur(r.present), dur(r.expected))
    end
    out[#out + 1] = { what, { 0.9, 0.9, 0.9 } }
    if r.reason then
        out[#out + 1] = { "Their reason: " .. (REASON[r.reason.c] or "") .. (r.reason.n and ("  \"" .. r.reason.n .. "\"") or "")
            .. "   " .. grey("sent " .. clock(r.reason.at)), { 1, 0.93, 0.75 } }
    end
    if r.note and r.note.n then
        out[#out + 1] = { "\"" .. r.note.n .. "\"   " .. grey("sign-up note"), { 1, 0.93, 0.75 } }
    end
    local picked = r.picked and r.picked.l or {}
    for i, l in ipairs(picked) do
        local tail = "[" .. l.ch .. "] " .. clock(l.at)
        if i == #picked then tail = tail .. " · picked by " .. short(r.picked.by) end
        out[#out + 1] = { "\"" .. l.t .. "\"   " .. grey(tail), CHAT_COLOR[l.ch] or { 1, 1, 1 } }
    end
    if r.mark and r.mark.od then
        out[#out + 1] = { "The raid leader left it to the officers.", C.grey }
    end
    if r.replacedBy then
        local h = Att():Result(n, r.replacedBy)
        out[#out + 1] = { short(r.replacedBy) .. " filled in" .. (h and h.first and (" from " .. clock(h.first)) or "")
            .. ". Not counted as late for them.", C.fill }
    end
    if #picked == 0 and not r.reason and not (r.note and r.note.n) then
        out[#out + 1] = { "No reason given.", { 0.5, 0.5, 0.52 } }
    end
    return out
end

function AUI:CreateReviews(parent, width)
    local v = CreateFrame("Frame", nil, parent)
    v:SetSize(width, 500)
    local LINE = 18
    local function cardHeight(r) return max(110, 52 + #AUI:ReviewLines(r) * LINE + 12) end

    local function initRow(row, d)
        if not row.cdlInit then
            row.cdlInit = true
            row.card = CreateFrame("Frame", nil, row)
            row.card:SetPoint("TOPLEFT")
            row.card:SetPoint("BOTTOMRIGHT", 0, 8)
            row.card.bg = tex(row.card, "BACKGROUND", C.card)
            row.card.bg:SetAllPoints()
            UI():AddEdges(row.card, "BORDER")
            UI():SetEdgeColor(row.card, 0.34, 0.34, 0.38, 0.45)
            local c = row.card
            c.art = c:CreateTexture(nil, "ARTWORK")
            c.art:SetSize(64, 38)
            c.art:SetPoint("TOPLEFT", 12, -12)
            c.ring = c:CreateTexture(nil, "OVERLAY", nil, 1)
            c.ring:SetTexture(ns.EventUI.RING)
            c.ring:SetSize(28, 28)
            c.ring:SetPoint("CENTER", c.art, "BOTTOMRIGHT", -2, 2)
            c.icon = c:CreateTexture(nil, "OVERLAY", nil, 0)
            c.icon:SetSize(22, 22)
            c.icon:SetPoint("CENTER", c.ring)
            c.bar = NewBar(c, 64, 6)
            c.bar:SetPoint("TOPLEFT", 12, -66)
            c.name = newText(c, 15)
            c.name:SetPoint("TOPLEFT", 96, -11)
            c.pill = pill(c, 16)
            c.pill:SetPoint("LEFT", c.name, "RIGHT", 8, 0)
            c.pill2 = pill(c, 16)
            c.pill2:SetPoint("LEFT", c.pill, "RIGHT", 6, 0)
            c.where = newText(c, 11, C.grey, "GameFontHighlightSmall")
            c.where:SetPoint("TOPLEFT", 96, -32)
            c.lines = {}
            c.excuse = UI():CreateSleekButton(c, "Excuse", 96, 24, function()
                local r = row.cdlR
                if r then Att():Decide(r.night.key, r.key, "x") end
            end, "primary")
            c.excuse:SetPoint("TOPRIGHT", -12, -14)
            c.counts = UI():CreateSleekButton(c, "Counts", 96, 24, function()
                local r = row.cdlR
                if r then Att():Decide(r.night.key, r.key, "c") end
            end)
            c.counts:SetPoint("TOPRIGHT", -12, -44)
            c.note = UI():CreateTipIconButton(c, 24, UI().ICON.notes, "Decide with a note",
                "Excuse or count it with a note the others see.", function(self)
                    local r = row.cdlR
                    if not r then return end
                    textPrompt("Attendance: " .. short(r.key), "Excuse or count it, with a note the others see.",
                        { "Excuse", "Counts" }, function(i, text)
                            if i == 1 then Att():Decide(r.night.key, r.key, "x", text)
                            elseif i == 2 then Att():Decide(r.night.key, r.key, "c", text) end
                        end)
                end)
            c.note:SetPoint("TOPRIGHT", -12, -74)
            c.wh = UI():CreateTipIconButton(c, 24, UI().ICON.whisper or UI().ICON.notes, "Whisper",
                "Ask them in a whisper.", function()
                    if row.cdlR then whisper(row.cdlR.key) end
                end)
            c.wh:SetPoint("RIGHT", c.note, "LEFT", -6, 0)
            c.pick = UI():CreateSleekButton(c, "Pick from chat", 116, 22, function(self)
                if row.cdlR then AUI:OpenPicker(self, row.cdlR) end
            end)
            c.wait = newText(c, 11, C.grey, "GameFontHighlightSmall")
            c.wait:SetJustifyH("RIGHT")
            c.wait:SetPoint("TOPRIGHT", -12, -18)
            c.wait:SetText("Waiting for the GM, an officer\nor the guild council")
            c.wait:SetWordWrap(true)
            -- a handled row
            row.h = CreateFrame("Frame", nil, row)
            row.h:SetAllPoints()
            row.h.icon = row.h:CreateTexture(nil, "ARTWORK")
            row.h.icon:SetSize(15, 15)
            row.h.icon:SetPoint("LEFT", 0, 0)
            row.h.text = newText(row.h, 12)
            row.h.text:SetPoint("LEFT", 22, 0)
            row.h.pill = pill(row.h, 16)
            row.h.pill:SetPoint("LEFT", floor(width * 0.52), 0)
            row.h.by = newText(row.h, 11, C.grey, "GameFontHighlightSmall")
            row.h.by:SetPoint("LEFT", row.h.pill, "RIGHT", 10, 0)
            row.h.by:SetWidth(floor(width * 0.48) - 100)
            row.sec = newText(row, 11, C.dim, "GameFontHighlightSmall")
            row.sec:SetPoint("LEFT", 0, -2)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(self, button)
                local r = self.cdlR
                if not r then return end
                if button == "RightButton" then AUI:ResultMenu(self, r) else AUI:ShowPlayer(r.key) end
            end)
            row:SetScript("OnEnter", function(self)
                if not self.cdlR then return end
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                AUI:ResultTooltip(GameTooltip, self.cdlR)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        row.cdlR = d.r
        row.card:SetShown(d.kind == "card")
        row.h:SetShown(d.kind == "handled")
        row.sec:SetShown(d.kind == "sec")
        row:EnableMouse(d.kind ~= "sec")
        if d.kind == "sec" then
            row.sec:SetText(d.text)
            return
        end
        local r = d.r
        local cls = classOf(r.key, r.cls)
        if d.kind == "handled" then
            UI():ClassIcon(row.h.icon, cls)
            local word = AUI:ResultWord(r)
            word = word:gsub(" · excused$", ""):gsub(" · review$", "")
            row.h.text:SetWidth(floor(width * 0.52) - 30)
            row.h.text:SetText(name(r.key, cls) .. grey("  ·  " .. word .. "  ·  " .. shortZone(nightName(r.night)) .. " "
                .. date("%a %d %b", r.night.start or Now())))
            local ex = r.decision.d == "x"
            row.h.pill:SetKind(ex and "Excused" or "Counts", ex and "ok" or "mute")
            row.h.by:SetText(short(r.decision.by) .. (r.decision.n and (": \"" .. r.decision.n .. "\"") or ""))
            return
        end
        local c = row.card
        setArt(c.art, r.night, 64, 38, 0.36)
        UI():ClassIcon(c.icon, cls)
        c.bar:Set(r.F - 600, r.T + 600, AUI:Segments(r), { r.F, r.T })
        c.name:SetText(name(r.key, cls))
        local word = AUI:ResultWord(r)
        c.pill:SetKind((word:gsub(" · review$", "")), "warn")
        c.pill2:SetShown(r.note ~= nil)
        if r.note then c.pill2:SetKind(r.note.x and "Answered Absent" or "Told us before", "ok") end
        local label = AUI:LineupLabel(r.night)
        c.where:SetWidth(width - 96 - 240)
        c.where:SetText(nightName(r.night) .. " · " .. date("%a %d %b", r.night.start or Now())
            .. (label and (" · " .. label) or ""))
        local lines = AUI:ReviewLines(r)
        for i, l in ipairs(lines) do
            local fs = c.lines[i]
            if not fs then
                fs = newText(c, 12)
                fs:SetPoint("TOPLEFT", 96, -50 - (i - 1) * LINE)
                fs:SetWidth(width - 96 - 240)
                c.lines[i] = fs
            end
            fs:SetText(l[1])
            fs:SetTextColor(l[2][1], l[2][2], l[2][3])
            fs:Show()
        end
        for i = #lines + 1, #c.lines do c.lines[i]:Hide() end
        local canDecide = Att():CanReview()
        c.excuse:SetShown(canDecide)
        c.counts:SetShown(canDecide)
        c.note:SetShown(canDecide)
        c.wh:SetShown(canDecide)
        c.wait:SetShown(not canDecide)
        c.pick:SetShown(canDecide)
        c.pick:ClearAllPoints()
        c.pick:SetPoint("TOPRIGHT", c.wh, "TOPLEFT", -8, 0)
        local hasPick = r.picked and #(r.picked.l or {}) > 0
        c.pick:SetText(hasPick and "Change lines" or "Pick from chat")
    end

    v.list = UI():CreateScrollList(v, 24, initRow, function(d)
        if d.kind == "card" then return cardHeight(d.r) + 8 end
        if d.kind == "sec" then return 26 end
        return 24
    end)
    -- the margins (the GM's): on the page's top line, right; the GM changes them
    v.rules = newText(v, 11, C.grey, "GameFontHighlightSmall")
    v.rules:SetJustifyH("RIGHT")
    v.rulesBtn = UI():CreateSleekButton(v, "Change", 70, 20, function() AUI:OpenRulesDialog() end)
    v.rulesBtn:SetPoint("TOPRIGHT", 0, -2)
    v.list.frame:SetPoint("TOPLEFT", 0, -26)
    v.list.frame:SetPoint("BOTTOMRIGHT", 20, 0)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPLEFT", v.list.box, "TOPRIGHT", 4, 0)
    v.list.bar:SetPoint("BOTTOMLEFT", v.list.box, "BOTTOMRIGHT", 4, 0)
    v.list:SetEmptyText("Nothing waits for a decision.")

    function v:Refresh()
        local rv = Att():GetReviews()
        local data = {}
        local rules = Att():Rules()
        local G = ns.Guild
        local gm = G and G.IsGM and G:IsGM(ns.Util.PlayerKey())
        self.rulesBtn:SetShown(gm and true or false)
        self.rules:ClearAllPoints()
        if gm then self.rules:SetPoint("RIGHT", self.rulesBtn, "LEFT", -8, 0) else self.rules:SetPoint("TOPRIGHT", 0, -6) end
        self.rules:SetText(("On time within %d min · disconnects under %d min don't count"):format(rules.o, rules.d))
        data[#data + 1] = { kind = "sec", text = "WAITING FOR A DECISION   |cff6f6f74doesn't count against anyone until decided|r" }
        if #rv.pending == 0 then
            data[#data + 1] = { kind = "sec", text = "|cff6f6f74Nothing waits for a decision.|r" }
        end
        for _, r in ipairs(rv.pending) do data[#data + 1] = { kind = "card", r = r } end
        if #rv.handled > 0 then
            data[#data + 1] = { kind = "sec", text = "HANDLED   |cff6f6f74last 14 days · change a decision from the player's page|r" }
            for _, r in ipairs(rv.handled) do data[#data + 1] = { kind = "handled", r = r } end
        end
        self.list:SetData(data)
        return #rv.pending
    end
    return v
end

---------------------------------------------------------------------------
-- 5. Pick from chat
---------------------------------------------------------------------------

local function NewChatRow(parent, w)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(w, 24)
    f.bg = tex(f, "BACKGROUND", { 1, 1, 1 }, 0.03)
    f.bg:SetAllPoints()
    UI():AddEdges(f, "BORDER")
    f.box = CreateFrame("Frame", nil, f)
    f.box:SetSize(12, 12)
    f.box:SetPoint("LEFT", 8, 0)
    f.box.bg = tex(f.box, "ARTWORK", { 0.08, 0.08, 0.1 }, 1)
    f.box.bg:SetAllPoints()
    UI():AddEdges(f.box, "BORDER")
    f.tick = f.box:CreateTexture(nil, "OVERLAY", nil, 2)
    f.tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    f.tick:SetSize(18, 18)
    f.tick:SetPoint("CENTER", 1, 1)
    f.tag = newText(f, 11, nil, "GameFontHighlightSmall")
    f.tag:SetPoint("LEFT", 26, 0)
    f.text = newText(f, 12)
    f.text:SetPoint("LEFT", 26 + 112, 0)
    f.text:SetWidth(w - 26 - 112 - 60)
    f.likely = pill(f, 14)
    f.likely:SetPoint("RIGHT", -6, 0)
    function f:SetLine(l, picked)
        self.line = l
        local c = CHAT_COLOR[l.ch] or { 1, 1, 1 }
        self.tag:SetText(hex(c, "[" .. l.ch .. "]") .. "  " .. grey(date("%a %H:%M", l.at)))
        self.text:SetText(l.t)
        self.text:SetTextColor(c[1], c[2], c[3])
        self.likely:SetShown(l.likely and true or false)
        if l.likely then self.likely:SetKind("likely", "ok") end
        self:SetPicked(picked)
    end
    function f:SetPicked(on)
        self.picked = on and true or false
        self.tick:SetShown(self.picked)
        self.bg:SetColorTexture(on and 0.17 or 1, on and 0.14 or 1, on and 0.05 or 1, on and 0.95 or 0.03)
        UI():SetEdgeColor(self, C.gold[1], C.gold[2], C.gold[3], on and 0.75 or 0)
        UI():SetEdgeColor(self.box, on and C.gold[1] or 0.45, on and C.gold[2] or 0.45, on and C.gold[3] or 0.5, 1)
    end
    return f
end
AUI.NewChatRow = NewChatRow

-- The picker: what the player said around the raid, ticked to keep as the reason (at most 5 lines).
function AUI:OpenPicker(owner, r)
    local A = Att()
    local W = 480
    local f = self.picker
    if not f then
        f = CreateFrame("Frame", "DisasterZoneAttendancePicker", UIParent)
        if UISpecialFrames then tinsert(UISpecialFrames, "DisasterZoneAttendancePicker") end
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        f:SetClampedToScreen(true)
        f:EnableMouse(true)
        f:SetWidth(W)
        ns.Popup:SkinPanel(f)
        f.title:SetPoint("TOPLEFT", 14, -12)
        f.glint:SetPoint("TOPLEFT", 1, -1)
        f.glint:SetWidth(W - 2)
        f.close = UI():CreateCloseButton(f, 18, function() f:Hide() end)
        f.close:SetPoint("TOPRIGHT", -8, -8)
        f.sub = newText(f, 11, C.grey, "GameFontHighlightSmall")
        f.sub:SetPoint("TOPLEFT", 14, -34)
        f.rows = {}
        f.empty = newText(f, 12, { 0.5, 0.5, 0.52 })
        f.empty:SetPoint("TOPLEFT", 14, -60)
        f.empty:SetWidth(W - 28)
        f.empty:SetWordWrap(true)
        f.note = newText(f, 10, { 0.5, 0.5, 0.52 }, "GameFontHighlightSmall")
        f.note:SetPoint("BOTTOMLEFT", 14, 18)
        f.note:SetText("A whisper is only shared with the officers if you pick it.")
        f.use = UI():CreateSleekButton(f, "Use", 100, 24, function()
            local lines = {}
            for _, row in ipairs(f.rows) do
                if row:IsShown() and row.picked then lines[#lines + 1] = row.line end
            end
            local ok, err = A:Pick(f.r.night.key, f.r.key, lines)
            if not ok and err then ns:Print("%s", err) end
            f:Hide()
        end, "primary")
        f.use:SetPoint("BOTTOMRIGHT", -12, 12)
        self.picker = f
    end
    f.r = r
    f.title:SetText("What " .. short(r.key) .. " said")
    local from, to = A:ChatWindow(r)
    f.sub:SetText(r.left > 0 and not r.noShow and "Messages your game saw, 15 minutes before they left to 30 after"
        or "Messages your game saw, from the day before the raid to the day after")
    local lines = A:GetChat(r.key, from, to)
    -- the newest 10, oldest first; the lines kept already are listed even when this game never heard them
    while #lines > 10 do table.remove(lines, 1) end
    local kept, seen = {}, {}
    for _, l in ipairs(lines) do seen[l.t .. "@" .. l.at] = true end
    for _, l in ipairs(r.picked and r.picked.l or {}) do
        local k = l.t .. "@" .. l.at
        kept[k] = true
        if not seen[k] then lines[#lines + 1] = { t = l.t, ch = l.ch, at = l.at } end
    end
    tsort(lines, function(a, b) return a.at < b.at end)
    f.anyKept = next(kept) ~= nil
    function f.updateUse()
        local n = 0
        for _, row in ipairs(f.rows) do if row:IsShown() and row.picked then n = n + 1 end end
        f.use:SetText(n == 0 and (f.anyKept and "Clear" or "Use") or (n == 1 and "Use 1 line" or ("Use " .. n .. " lines")))
        f.use:SetEnabled(n > 0 or f.anyKept)
    end
    local ticked = 0
    for i, l in ipairs(lines) do
        local row = f.rows[i]
        if not row then
            row = NewChatRow(f, W - 28)
            row:SetPoint("TOPLEFT", 14, -54 - (i - 1) * 28)
            row:SetScript("OnClick", function(self)
                local n = 0
                for _, x in ipairs(f.rows) do if x:IsShown() and x.picked then n = n + 1 end end
                if not self.picked and n >= 5 then return end
                self:SetPicked(not self.picked)
                f.updateUse()
            end)
            f.rows[i] = row
        end
        -- (likely lines ticked for you, at most 5, never a whisper: that one is yours to share)
        local picked = kept[l.t .. "@" .. l.at]
        if not f.anyKept then picked = l.likely and l.ch ~= "Whisper" and ticked < 5 end
        if picked then ticked = ticked + 1 end
        row:SetLine(l, picked and true or false)
        row:Show()
    end
    for i = #lines + 1, #f.rows do f.rows[i]:Hide() end
    f.empty:SetShown(#lines == 0)
    f.empty:SetText("Your game heard nothing from them in that time. Only what your own client saw is listed: "
        .. "ask a raid member who was there, or add a note to your decision.")
    f:SetHeight(54 + max(1, #lines) * 28 + (#lines == 0 and 30 or 0) + 54)
    f.updateUse()
    -- (over the Raid log, not on a list row: rows are reused as the list scrolls)
    f:ClearAllPoints()
    local panel = ns.RaidsUI and ns.RaidsUI.GetPanel and ns.RaidsUI:GetPanel()
    if panel and panel:IsVisible() then f:SetPoint("TOP", panel, "TOP", 0, -60) else f:SetPoint("CENTER", 0, 60) end
    f:Show()
    return f
end

---------------------------------------------------------------------------
-- 6. During the raid: the raid leader's prompt, my own
---------------------------------------------------------------------------

-- The night the prompts are about: the raid running now, or (demo mode, /dz attendance demo) the demo's newest.
local function LiveNight()
    if AUI.demoNight and demoOn() then return AUI.demoNight end
    return Att():GetLiveNight()
end

local function NotHereYet()
    local n = AUI.demoNight and demoOn() and AUI.demoNight
    if not n then return Att():GetNotHereYet() end
    local out = {}
    for _, r in ipairs(Att():NightResults(n).expected) do
        if r.noShow and not r.bench then out[#out + 1] = r end
    end
    return out
end

local function Panel(name_, w, h, title)
    local f = CreateFrame("Frame", name_, UIParent)
    if UISpecialFrames and name_ then tinsert(UISpecialFrames, name_) end
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetSize(w, h)
    ns.Popup:SkinPanel(f)
    f.title:SetText(title)
    f.title:SetPoint("TOPLEFT", 16, -14)
    f.glint:SetPoint("TOPLEFT", 1, -1)
    f.glint:SetWidth(w - 2)
    f.close = UI():CreateCloseButton(f, 18, function() f:Hide() end)
    f.close:SetPoint("TOPRIGHT", -8, -8)
    return f
end

-- The raid leader's attendance panel: who left (oldest first: a leaver arriving while another is shown waits its
-- turn, so ticks are never lost), their chat lines to tick (whispers never ticked for you), and who is not here yet.
-- Lines are kept only through a button (Swap in, I benched them, Officers decide), never by closing the panel;
-- closing keeps the queue (the session bar's button brings it back). It waits out combat.
function AUI:ShowLeaderPrompt(recId, key)
    local A = Att()
    local W = 420
    local f = self.leader
    if not f then
        f = Panel("DisasterZoneAttendanceLeader", W, 300, "Attendance")
        f:SetPoint("TOP", 0, -160)
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetSize(18, 18)
        f.icon:SetPoint("TOPLEFT", 16, -46)
        f.who = newText(f, 13)
        f.who:SetPoint("LEFT", f.icon, "RIGHT", 8, 0)
        f.said = newText(f, 10, C.dim, "GameFontHighlightSmall")
        f.said:SetPoint("TOPLEFT", 16, -72)
        f.rows = {}
        f.none = newText(f, 11, { 0.5, 0.5, 0.52 }, "GameFontHighlightSmall")
        f.none:SetPoint("TOPLEFT", 16, -90)
        f.none:SetWidth(W - 32)
        f.none:SetWordWrap(true)
        f.swap = UI():CreateSleekButton(f, "Swap in...", 108, 24, function(self) AUI:SwapMenu(self, f.key) end, "primary")
        f.bench = UI():CreateSleekButton(f, "I benched them", 116, 24, function()
            local key = f.key
            if not key then return end
            if not A:LeaderMark(key, "b") then return AUI:MarkFailed() end
            AUI:LeaderNext(key)
        end)
        f.od = UI():CreateSleekButton(f, "Officers decide", 112, 24, function()
            local key = f.key
            if not key then return end
            AUI:LeaderKeep(key)
            if not A:LeaderMark(key, "od") then return AUI:MarkFailed() end
            AUI:LeaderNext(key)
        end)
        f.sep = tex(f, "ARTWORK", { 1, 1, 1 }, 0.08)
        f.sep:SetSize(W - 32, 1)
        f.nh = newText(f, 10, C.dim, "GameFontHighlightSmall")
        f.nhList = newText(f, 12)
        f.nhList:SetWidth(W - 32)
        f.nhList:SetWordWrap(true)
        f.nhList:SetJustifyV("TOP")
        f.whisper = UI():CreateSleekButton(f, "Whisper them", 104, 22, function()
            local first = f.notHere and f.notHere[1]
            if first then whisper(first.key) end
        end)
        f.whisper:SetPoint("BOTTOMRIGHT", -14, 14)
        f.queue = {}
        self.leader = f
    end
    if key then
        for _, k in ipairs(f.queue) do
            if k == key then key = nil break end
        end
        if key then f.queue[#f.queue + 1] = key end
        f.recId = recId or f.recId
    end
    -- (a pull is no time for a panel: after combat)
    if (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) then
        self.leaderAfterCombat = true
        return
    end
    -- (the one shown stays: a new leaver only updates the count)
    if f:IsShown() and f.key and f.key == f.queue[1] then
        self:LeaderCount()
        return
    end
    self:LeaderRender()
    f:Show()
end

function AUI:MarkFailed()
    ns:Print("only the raid's leader can mark this, while the raid session runs.")
end

-- "(2 more)" after the name, without touching the ticks.
function AUI:LeaderCount()
    local f = self.leader
    if not (f and f.key and f.whoText) then return end
    f.who:SetText(f.whoText .. (#f.queue > 1 and grey("   (" .. (#f.queue - 1) .. " more)") or ""))
end

-- Keeps the ticked lines of `key` as their reason (only while their lines are shown).
function AUI:LeaderKeep(key)
    local f = self.leader
    if not (f and key and f.key == key and f.lines) then return end
    local lines = {}
    for _, row in ipairs(f.rows) do
        if row:IsShown() and row.picked then lines[#lines + 1] = row.line end
    end
    if #lines > 0 then
        local n = LiveNight()
        if n then Att():Pick(n.key, key, lines) end
    end
end

-- `key` is done: take them off the queue and show the next one (or close when nothing is left).
function AUI:LeaderNext(key)
    local f = self.leader
    if not f then return end
    for i = #f.queue, 1, -1 do if f.queue[i] == key then table.remove(f.queue, i) end end
    if f.key == key then f.key, f.lines = nil, nil end
    if not f:IsShown() then return end
    if #f.queue == 0 and #NotHereYet() == 0 then f:Hide() return end
    self:LeaderRender()
end

function AUI:LeaderRender()
    local f = self.leader
    if not f then return end
    local A = Att()
    local W = 420
    local key = f.queue[1]
    f.key = key
    f.lines = nil
    local y = -46
    local left = key ~= nil
    for _, x in ipairs({ f.icon, f.who, f.said, f.swap, f.bench, f.od }) do x:SetShown(left) end
    f.none:Hide()
    for _, row in ipairs(f.rows) do row:Hide() end
    if left then
        local n = LiveNight()
        local r = n and A:Result(n, key)
        UI():ClassIcon(f.icon, classOf(key))
        local lastOut = r and r.last or Now()
        f.whoText = name(key) .. " left the raid" .. grey("  " .. clock(lastOut))
        self:LeaderCount()
        f.said:SetText("THEY SAID   |cff6f6f74tick the lines to keep as the reason|r")
        local lines = A:GetChat(key, lastOut - 15 * 60, max(Now(), lastOut + 30 * 60))
        while #lines > 4 do table.remove(lines, 1) end
        f.lines = lines
        y = -88
        for i, l in ipairs(lines) do
            local row = f.rows[i]
            if not row then
                row = NewChatRow(f, W - 32)
                row:SetScript("OnClick", function(self) self:SetPicked(not self.picked) end)
                f.rows[i] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 16, y)
            -- (a whisper is private: only you tick it)
            row:SetLine(l, l.likely and l.ch ~= "Whisper")
            row:Show()
            y = y - 26
        end
        if #lines == 0 then
            f.none:SetText("Nothing yet in raid chat or whispers. Lines they send now show up here.")
            f.none:ClearAllPoints()
            f.none:SetPoint("TOPLEFT", 16, y)
            f.none:Show()
            y = y - 20
        end
        y = y - 8
        f.swap:ClearAllPoints()
        f.swap:SetPoint("TOPLEFT", 16, y)
        f.bench:ClearAllPoints()
        f.bench:SetPoint("LEFT", f.swap, "RIGHT", 6, 0)
        f.od:ClearAllPoints()
        f.od:SetPoint("LEFT", f.bench, "RIGHT", 6, 0)
        y = y - 36
    end
    -- who is not here yet
    local notHere = NotHereYet()
    f.notHere = notHere
    local showNH = #notHere > 0
    f.sep:SetShown(left and showNH)
    f.nh:SetShown(showNH)
    f.nhList:SetShown(showNH)
    f.whisper:SetShown(showNH)
    if showNH then
        f.sep:ClearAllPoints()
        f.sep:SetPoint("TOPLEFT", 16, y)
        y = y - 12
        local n = LiveNight()
        f.nh:ClearAllPoints()
        f.nh:SetPoint("TOPLEFT", 16, y)
        f.nh:SetText("NOT HERE YET   |cff6f6f74expected since " .. clock(n and n.facts and n.facts.F) .. "|r")
        y = y - 18
        local parts = {}
        for i, r in ipairs(notHere) do
            if i > 8 then parts[#parts + 1] = grey("+" .. (#notHere - 8)) break end
            local why = r.note and r.note.n and ("\"" .. r.note.n:sub(1, 24) .. "\"") or (r.note and r.note.x and "told us: absent")
                or "no word"
            parts[#parts + 1] = name(r.key, r.cls) .. grey("  " .. why)
        end
        f.nhList:ClearAllPoints()
        f.nhList:SetPoint("TOPLEFT", 16, y)
        f.nhList:SetText(tconcat(parts, "     "))
        y = y - max(18, (f.nhList:GetStringHeight() or 16)) - 8
        f.whisper:SetText(#notHere == 1 and "Whisper them" or ("Whisper " .. short(notHere[1].key)))
        local fsw = f.whisper:GetFontString()
        f.whisper:SetWidth(max(104, floor((fsw and fsw:GetStringWidth() or 80) + 28)))
    end
    if not left and not showNH then
        f.title:SetText("Attendance")
        f.none:SetText("Everyone who is expected is here.")
        f.none:ClearAllPoints()
        f.none:SetPoint("TOPLEFT", 16, -48)
        f.none:Show()
        y = -70
    else
        local n = LiveNight()
        f.title:SetText("Attendance · " .. (n and nightName(n) or "the raid"))
    end
    f:SetHeight(-y + (showNH and 44 or 14))
end

-- Swap in...: guild members in the raid who weren't expected (mark them), or online guild members at level 70 to
-- invite in their place (sorted by name; pugs and offline players left out).
function AUI:SwapMenu(owner, out)
    if not out then return end
    local A = Att()
    local G = ns.Guild
    local function inGuild(key) return demoOn() or (G and G.IsInGuild and G:IsInGuild(key, true)) end
    UI():ContextMenu(owner, function(root)
        root:CreateTitle("Who replaces " .. short(out) .. "?")
        local n = LiveNight()
        local inRaid, here = {}, {}
        for i = 1, (GetNumGroupMembers() or 0) do
            local nm, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
            local key = type(nm) == "string" and ns.Util.NormalizeName(nm)
            if key then
                inRaid[key] = true
                if online and n and not A:ExpectedKey(n, key) and not ns.Util.IsMe(key) and inGuild(key) then
                    here[#here + 1] = key
                end
            end
        end
        tsort(here)
        for _, key in ipairs(here) do
            root:CreateButton(name(key) .. grey("  in the raid"), function()
                AUI:LeaderKeep(out)
                if not A:LeaderMark(key, "sw", out) then return AUI:MarkFailed() end
                AUI:LeaderNext(out)
            end)
        end
        local online = {}
        for _, key in ipairs(G and G.GetOnlineMembers and G:GetOnlineMembers() or {}) do
            local m = G.GetMember and G:GetMember(key)
            local level = m and tonumber(m.level)
            if not inRaid[key] and not ns.Util.IsMe(key) and (not level or level >= 70) then online[#online + 1] = key end
        end
        tsort(online)
        if #online > 0 then
            if #here > 0 then root:CreateDivider() end
            root:CreateTitle("Invite")
            local sub = root
            if #online > 12 then sub = root:CreateButton("Online guild members") end
            for _, key in ipairs(online) do
                sub:CreateButton(name(key), function()
                    AUI:LeaderKeep(out)
                    A:InviteFor(key, out)
                    AUI:LeaderNext(out)
                end)
            end
        elseif #here == 0 then
            root:CreateTitle("Nobody to swap in")
        end
    end)
end

-- My own prompt: I left a raid that expects me before its end.
function AUI:ShowLeftEarly(recId, plannedEnd)
    local A = Att()
    local W = 400
    local f = self.mine
    if not f then
        f = Panel("DisasterZoneAttendanceLeftEarly", W, 214, "")
        f:SetPoint("TOP", 0, -180)
        f.d = newText(f, 12, { 0.86, 0.86, 0.86 })
        f.d:SetWordWrap(true)
        f.d:SetWidth(W - 32)
        f.d:SetPoint("TOPLEFT", 16, -42)
        f.chips = {}
        local x = 16
        for _, c in ipairs({ { "life", "Real life" }, { "dc", "Disconnected" }, { "asked", "Asked to leave" },
                             { "other", "Other" } }) do
            local w = floor(c[2]:len() * 6.4 + 22)
            local b = UI():CreateSleekButton(f, c[2], w, 24, function()
                f.code = c[1]
                for _, x2 in ipairs(f.chips) do x2:SetKind(x2.code == f.code and "chosen" or "secondary") end
                f.canSend()
            end)
            b.code = c[1]
            b:SetPoint("TOPLEFT", x, -88)
            x = x + w + 6
            f.chips[#f.chips + 1] = b
        end
        f.eb = UI():CreateSleekEditBox(f, W - 32, 26)
        f.eb:SetPoint("TOPLEFT", 16, -124)
        f.eb:HookScript("OnTextChanged", function() if f.canSend then f.canSend() end end)
        UI():SetEditPlaceholder(f.eb, "A few words for the officers (optional)")
        f.send = UI():CreateSleekButton(f, "Send", 90, 24, function()
            if A:SendReason(f.recId, f.code, f.eb:GetText()) then
                ns:Print(demoOn() and "demo: nothing was sent." or "your reason was sent to the officers.")
            end
            f:Hide()
        end, "primary")
        -- (a reason first: a chip or a few words)
        function f.canSend()
            local text = f.eb:GetText() or ""
            f.send:SetEnabled(f.code ~= nil or text:match("%S") ~= nil)
        end
        f.send:SetPoint("BOTTOMRIGHT", -14, 14)
        f.later = UI():CreateSleekButton(f, "Not now", 90, 24, function() f:Hide() end)
        f.later:SetPoint("RIGHT", f.send, "LEFT", -6, 0)
        self.mine = f
    end
    local rec = ns.RaidLog and ns.RaidLog:GetRaid(recId)
    f.recId = recId
    f.code = nil
    for _, x in ipairs(f.chips) do x:SetKind("secondary") end
    f.eb:SetText("")
    f.canSend()
    f.title:SetText("You left " .. ((rec and rec.zone) or "the raid") .. " before the end")
    f.d:SetText((plannedEnd and ("The raid runs until " .. clock(plannedEnd) .. ". ") or "The raid is still going. ")
        .. "Tell the officers why; they decide whether it counts.")
    f:Show()
end

-- The GM: the two margins everyone's attendance is measured by.
function AUI:OpenRulesDialog()
    local f = self.rulesDialog
    if not f then
        f = CreateFrame("Frame", "DisasterZoneAttendanceRules", UIParent)
        if UISpecialFrames then tinsert(UISpecialFrames, "DisasterZoneAttendanceRules") end
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        f:EnableMouse(true)
        f:SetSize(380, 196)
        f:SetPoint("CENTER", 0, 80)
        ns.Popup:SkinPanel(f)
        f.title:SetText("Attendance margins")
        f.title:SetPoint("TOPLEFT", 16, -14)
        f.glint:SetPoint("TOPLEFT", 1, -1)
        f.glint:SetWidth(378)
        f.close = UI():CreateCloseButton(f, 20, function() f:Hide() end)
        f.close:SetPoint("TOPRIGHT", -8, -8)
        f.hint = newText(f, 11, C.grey, "GameFontHighlightSmall")
        f.hint:SetPoint("TOPLEFT", 16, -38)
        f.hint:SetText("Everyone's attendance is measured by these. They reach every member.")
        local function stepper(y, label, field)
            local l = newText(f, 12, { 0.9, 0.9, 0.9 })
            l:SetPoint("TOPLEFT", 16, y)
            l:SetText(label)
            local val = newText(f, 13)
            val:SetJustifyH("CENTER")
            val:SetWidth(70)
            val:SetPoint("TOPRIGHT", -44, y + 1)
            local down = UI():CreateArrowButton(f, false, 18, 18, function()
                f[field] = max(0, f[field] - 1)
                f.paint()
            end)
            down:SetPoint("RIGHT", val, "LEFT", -2, 0)
            local up = UI():CreateArrowButton(f, true, 18, 18, function()
                f[field] = min(60, f[field] + 1)
                f.paint()
            end)
            up:SetPoint("LEFT", val, "RIGHT", 2, 0)
            return val
        end
        f.oVal = stepper(-70, "Arriving this late still counts as on time", "o")
        f.dVal = stepper(-100, "A disconnect shorter than this doesn't count", "d")
        function f.paint()
            f.oVal:SetText(f.o .. " min")
            f.dVal:SetText(f.d .. " min")
        end
        f.ok = UI():CreateSleekButton(f, "Save", 90, 24, function()
            local ok, err = ns.Guild:SetAttendanceRules(f.o, f.d)
            if not ok then ns:Print("%s", tostring(err)) else f:Hide() end
        end, "primary")
        f.ok:SetPoint("BOTTOMRIGHT", -14, 14)
        f.cancel = UI():CreateSleekButton(f, "Cancel", 90, 24, function() f:Hide() end)
        f.cancel:SetPoint("RIGHT", f.ok, "LEFT", -6, 0)
        self.rulesDialog = f
    end
    local r = Att():Rules()
    f.o, f.d = r.o, r.d
    f.paint()
    f:Show()
end

-- My own reason for a raid that didn't go as planned (from my Members card), days later too.
function AUI:ShowExplain(recId, zone, start)
    self:ShowLeftEarly(recId, nil)
    local f = self.mine
    f.title:SetText("Tell the officers about " .. (zone or "the raid"))
    f.d:SetText((start and (date("%a %d %b", start) .. ". ") or "") .. "Your reason goes to the Guild Master, officers and "
        .. "the guild council; they decide whether it counts.")
end

-- The picker and the dialogs belong to the window: they close with it.
function AUI:CloseFloating()
    for _, f in ipairs({ self.picker, self.awayDialog, self.rulesDialog }) do
        if f and f:IsShown() then f:Hide() end
    end
end

-- Demo mode: both prompts on the demo's newest raid (its early leaver, its no-shows), nothing sent.
function AUI:ShowDemo()
    if not demoOn() then
        ns:Print("turn demo mode on first (/dz demo on).")
        return
    end
    local A = Att()
    local n = A:ClosedNights()[1]
    if not n then return end
    self.demoNight = n
    local leaver
    for _, r in ipairs(A:NightResults(n).expected) do
        if r.left > 0 and not r.noShow then leaver = r.key break end
    end
    if self.leader then self.leader.queue = {} end
    self:ShowLeaderPrompt(n.primary.id, leaver)
    self:ShowLeftEarly(n.primary.id, n.facts and n.facts.T)
    self.leader:ClearAllPoints()
    self.leader:SetPoint("TOPRIGHT", UIParent, "TOP", -10, -150)
    self.mine:ClearAllPoints()
    self.mine:SetPoint("TOPLEFT", UIParent, "TOP", 10, -150)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function AUI:OnInit()
    ns:On("ATTENDANCE_PLAYER_LEFT", function(recId, _, key)
        if demoOn() then return end
        local A = Att()
        local n = A:GetLiveNight()
        local e = n and A:ExpectedKey(n, key)
        if e then AUI:ShowLeaderPrompt(recId, e) end
    end)
    ns:On("ATTENDANCE_LEFT_EARLY", function(recId, plannedEnd) AUI:ShowLeftEarly(recId, plannedEnd) end)
    ns:On("ATTENDANCE_BREAKUP", function()
        local f = AUI.leader
        if f and f:IsShown() then
            f.queue = {}
            f.key = nil
            f:Hide()
        end
    end)
    ns:On("RAIDLOG_CHANGED", function()
        if AUI.leader and AUI.leader:IsShown() then
            ns.Util.Debounce("att-leader", 1, function()
                if AUI.leader:IsShown() and not AUI.leader.key then AUI:LeaderRender() end
            end)
        end
    end)
    -- a leaver who comes back is off the list
    ns:On("RAIDLOG_JOINED", function(_, key)
        local f = AUI.leader
        if not (f and f.queue) then return end
        local n = Att():GetLiveNight()
        local e = n and Att():ExpectedKey(n, key) or key
        for _, k in ipairs(f.queue) do
            if k == e then return AUI:LeaderNext(e) end
        end
    end)
    -- the session ended, or I no longer lead it: the panel and its queue go
    ns:On("GROUP_RULES_CHANGED", function()
        local f = AUI.leader
        local GR = ns.GroupRules
        if f and not (GR and GR:GetSession() and GR:IsAuthority()) and not (AUI.demoNight and demoOn()) then
            f.queue, f.key, f.lines = {}, nil, nil
            AUI.leaderAfterCombat = nil
            f:Hide()
        end
    end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if AUI.leaderAfterCombat then
            AUI.leaderAfterCombat = nil
            local f = AUI.leader
            if f and #f.queue > 0 then
                AUI:LeaderRender()
                f:Show()
            end
        end
    end)
    ns:RegisterSlash("attendance", function(rest)
        if (rest or ""):match("^%s*demo") then return AUI:ShowDemo() end
        local A = Att()
        if A:GetLiveNight() and ns.GroupRules and ns.GroupRules:IsAuthority() then
            AUI:ShowLeaderPrompt()
        elseif A:CanSeeAll() and ns.MainFrame and ns.RaidsUI and ns.RaidsUI.SetMode then
            ns.MainFrame:Open("raids")
            ns.RaidsUI:SetMode("players")
        elseif ns.MainFrame and ns.MembersUI then
            -- (a member: their own, on their Members card)
            ns.MainFrame:Open("members")
            ns.MembersUI:ShowMember(ns.Util.PlayerKey())
            ns.MembersUI:SetCard("att")
        end
    end, "your attendance (the raid's for its leader; the Raid log's Attendance page for officers); demo: both prompts")
end
