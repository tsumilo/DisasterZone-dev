if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RaidsTab.lua", ...) then return end -- DisasterZone: "Raids" tab. Three views (Addendum J §58):
--   Upcoming - planned raids and sign-ups (everyone; UI/RaidPlanUI.lua)
--   Teams    - the raid teams (everyone can look; organizers edit; UI/RaidPlanUI.lua)
--   Strategies - the strategy boards per boss (everyone looks and builds, each changes their own; Addendum K,
--               UI/StrategiesView.lua)
--   Guests   - the guest book and the raid blacklist (the GM, officers and the raid leaders; UI/GuestBook.lua)
--   Raid log - council only (Addendum I §51), with two modes:
--     Raids   - the raid sessions (newest first) as cards with their raid's art and, for the selected one, a banner
--               (when, how long, who started it, a bin to delete it), the planned raid it is linked to (a picker) and
--               how its sign-ups turned out, then tabs: Attendance (bench marks, right-click to change), Bosses (the
--               kills) and Awards (the items given during it).
--     Attendance - 1.3.5 (UI/AttendanceUI.lua): every member's time-based attendance over the last N raids, a click
--               opens their page; the selected raid's Attendance tab is a time bar per player.
--     Reviews - 1.3.5: early leaves and reasons waiting for the GM, an officer or the guild council.
-- Start / End raid for the raid's authority sits in the toolbar. The Raid log is for raid log members (GM, guild
-- council, raid leaders; Addendum J §62) and, since 1.3.5, the officers (attendance reviewers), its awarded items for
-- the loot council only.
local addonName, ns = ...

local RaidsUI = ns:NewModule("RaidsUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tconcat = table.concat

-- The Raid log on the Raids tab's spacing grid (PAD at the page's sides, GAP between blocks).
local PAD, GAP = 10, 8
local INNER_W = 770                  -- the page inside its sides (the mock's anchored frames have no width)
local LOG_W = 236                    -- the logged raids column
local DETAIL_W = INNER_W - LOG_W - GAP
local CARD_H, CARD_GAP = 46, 6       -- a logged raid: its card and the gap under it
local THUMB_W = 62                   -- its raid's art
local BAN_H = 88                     -- the selected raid's banner
local LINK_H = 22                    -- the planned raid it is linked to, and how the sign-ups turned out
local TABS_H = 24
local HEAD_H = 18                    -- a table's column titles
local ROW_H = 22
local TOP = 36                       -- the views start under the Raids tab's view row
local CARD_BG = { 0.10, 0.10, 0.12, 0.92 }
local PICKED_BG = { 0.17, 0.15, 0.10, 0.94 }
local EDGE = { 0.34, 0.34, 0.38, 0.5 }
local RANGES = { 4, 8, 12, 0 }   -- 0 = all raids
local ART_TOP = 0.29                 -- a loading screen's picture starts under the game's logo
local INST_SHORT = { kara = "Kara", gruul = "Gruul", mag = "Mag", ssc = "SSC", tk = "TK", hyjal = "Hyjal", bt = "BT",
                     za = "ZA", swp = "Sunwell" }

-- The tables, columns left to right: one (flex) takes the room the others leave, so the last column ends at the table's
-- right edge; numbers are right-aligned (r), under a right-aligned title. icon: a class circle / an item's icon first.
-- opt: a column shown only when the table needs it (somebody left early, somebody was offline at a kill).
local COL_GAP = 16
local TABLES = {
    att = { { "Player", flex = true, icon = true }, { "Boss kills", w = 64, r = true }, { "Joined", w = 52, r = true },
            { "Left", w = 52, r = true, opt = true } },
    boss = { { "Time", w = 44 }, { "Boss", flex = true }, { "Raiders", w = 60, r = true },
             { "Offline", w = 60, r = true, opt = true } },
    award = { { "Item", flex = true, icon = true }, { "Winner", w = 120 }, { "Reason", w = 84 },
              { "Time", w = 44, r = true } },
}

-- Where a table's columns go in `width`: { [i] = { x, w, r, icon } } for the shown ones (show[i] for the opt ones).
local function placeColumns(key, width, show)
    local def = TABLES[key]
    local fixed, n = 0, 0
    for i, c in ipairs(def) do
        if not c.opt or (show and show[i]) then
            n = n + 1
            if not c.flex then fixed = fixed + c.w end
        end
    end
    local out, x = { key = key }, 0
    for i, c in ipairs(def) do
        if not c.opt or (show and show[i]) then
            local w = c.flex and (width - fixed - COL_GAP * (n - 1)) or c.w
            out[i] = { x = x, w = w, r = c.r, icon = c.icon, title = c[1] }
            x = x + w + COL_GAP
        end
    end
    return out
end

local state = { view = "upcoming", mode = "raids", selected = nil, range = 8, showGuests = false, tab = "att",
                player = nil, lineup = nil }
local panel

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function grey(text) return "|cff808080" .. tostring(text) .. "|r" end

local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

-- The name in its class colour. (Other lists mark a player from another realm "Name*"; the raid log's tables leave
-- the mark out: the GUEST tag says they are outside the guild, the row's tooltip names the realm.)
local function colored(key, classFile)
    local text = ns.UI:ColoredName(key, classFile or (ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)))
    return (text:gsub("%*|r$", "|r"))
end

-- "Darkstalkerr", and "from Pyrewood Village" for a player from another realm (tooltips).
local function nameLines(tt, key)
    tt:AddLine((shortName(key):match("^([^%-]+)") or shortName(key)))
    local realm = ns.Util.RealmOf and ns.Util.RealmOf(key)
    if realm then tt:AddLine("from " .. realm:gsub("(%l)(%u)", "%1 %2"), 1, 1, 1) end
end

local function classOf(key, classFile)
    return classFile or (ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)) or nil
end

-- "3 h 17 min", "45 min".
local function duration(sec)
    sec = floor(max(0, sec or 0))
    local h, m = floor(sec / 3600), floor(sec % 3600 / 60)
    return h > 0 and ("%d h %02d min"):format(h, m) or (m .. " min")
end

local function fmtTime(ts, fmt) return ts and date(fmt or "%H:%M", ts) or "-" end

local function RL() return ns.RaidLog end

local function rangeLabel(n) return n == 0 and "All raids" or ("Last " .. n .. " raids") end

local function demoOn()
    return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() and true or false
end

local function newText(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

local function setSize(fs, size)
    local path, _, flags = fs:GetFont()
    if path then fs:SetFont(path, size, flags) end
end

local function gradient(tex, orient, r, g, b, a1, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2)) end
end

-- The first of the texts that fits in `room` (the last one when none does): never cut off with "...".
-- (measured without its colour codes: the game's width ignores them, the test harness's doesn't)
local function fitText(fs, variants, room)
    for i, text in ipairs(variants) do
        fs:SetText((text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
        local fits = (fs:GetStringWidth() or 0) <= room
        fs:SetText(text)
        if i == #variants or fits then return text end
    end
end

-- The Raid log view (Addendum J §62): the GM, the guild council and the raid leaders list (not whoever happens to
-- lead a group: that is loot council for one raid only).
local function isCouncil()
    local G = ns.Guild
    if demoOn() then return true end
    if G and G.AmIRaidLogReader then return G:AmIRaidLogReader() and true or false end
    return (G and G.AmIRaidLogMember and G:AmIRaidLogMember()) and true or false
end

local function AUI() return ns.AttendanceUI end
local function Att() return ns.Attendance end

-- Awarded items in the raid log: loot council data (GM / guild council), not for raid leaders.
local function seesItems()
    local G = ns.Guild
    return (demoOn() or (G and G.IsGuildCouncil and G:IsGuildCouncil(ns.Util.PlayerKey()))) and true or false
end

-- A logged raid's instance (the raid plan's key: its loading screen) and its name, full and short.
local function instOf(rec)
    local RP = ns.RaidPlan
    for _, inst in ipairs(RP and RP.GetInstances and RP:GetInstances() or {}) do
        if inst.instID and inst.instID == rec.instID then return inst.key end
    end
    return "other"
end

local function setArt(tex, rec, w, h, fw)
    local PlanUI = ns.RaidPlanUI
    if not (PlanUI and PlanUI.RaidArt) then
        tex:Hide()
        return
    end
    local file, l, r, t, b = PlanUI:RaidArt(instOf(rec), w, h, fw)
    -- (a small crop stays under the game's logo at the top of the screen)
    if h < 60 and t < ART_TOP then t, b = ART_TOP, b + ART_TOP - t end
    tex:SetTexture(file)
    tex:SetTexCoord(l, r, t, b)
    tex:Show()
end

local function killsText(rec)
    local kills = #(rec.bosses or {})
    local total = RL():GetRecordBossTotal(rec)
    return total and ("%d/%d bosses"):format(kills, total) or (kills == 1 and "1 boss" or (kills .. " bosses"))
end

----------------------------------------------------------------------------
-- Raid list (left): a card per logged raid
----------------------------------------------------------------------------

local function lightCard(row, on)
    local picked = row.cdlRec and row.cdlRec.id == state.selected
    if picked then
        ns.UI:SetEdgeColor(row.card, 1, 0.82, 0, 0.85)
    elseif on then
        ns.UI:SetEdgeColor(row.card, 1, 0.82, 0, 0.4)
    else
        ns.UI:SetEdgeColor(row.card, 0, 0, 0, 0)
    end
end

local function initRaidRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        local card = CreateFrame("Frame", nil, row)
        card:SetPoint("TOPLEFT")
        card:SetPoint("TOPRIGHT")
        card:SetHeight(CARD_H)
        row.card = card
        card.bg = card:CreateTexture(nil, "BACKGROUND")
        card.bg:SetAllPoints()
        ns.UI:AddEdges(card, "OVERLAY")
        row.art = card:CreateTexture(nil, "ARTWORK", nil, 0)
        row.art:SetPoint("TOPLEFT")
        row.art:SetSize(THUMB_W, CARD_H)
        row.fade = card:CreateTexture(nil, "ARTWORK", nil, 1)
        row.fade:SetPoint("TOPRIGHT", row.art, "TOPRIGHT")
        row.fade:SetPoint("BOTTOMRIGHT", row.art, "BOTTOMRIGHT")
        row.fade:SetWidth(20)
        row.l1 = newText(card, "GameFontHighlight", 13)
        row.l1:SetPoint("TOPLEFT", THUMB_W + 10, -8)
        row.tag = newText(card, "GameFontHighlightSmall", 10)
        row.tag:SetPoint("LEFT", row.l1, "RIGHT", 6, 0)
        row.l2 = newText(card, "GameFontHighlightSmall", 11)
        row.l2:SetTextColor(0.62, 0.62, 0.62)
        row.l2:SetPoint("TOPLEFT", THUMB_W + 10, -27)
        row.time = newText(card, "GameFontHighlightSmall", 11)
        row.time:SetTextColor(0.62, 0.62, 0.62)
        row.time:SetJustifyH("RIGHT")
        row.time:SetPoint("TOPRIGHT", -10, -10)
        row.time:SetWidth(44)
        row:SetScript("OnClick", function(self)
            state.selected = self.cdlRec and self.cdlRec.id
            RaidsUI:Refresh()
        end)
        row:SetScript("OnEnter", function(self) lightCard(self, true) end)
        row:SetScript("OnLeave", function(self) lightCard(self, false) end)
    end
    local rec = d.rec
    row.cdlRec = rec
    local picked = rec.id == state.selected
    local bg = picked and PICKED_BG or CARD_BG
    row.card.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    gradient(row.fade, "HORIZONTAL", bg[1], bg[2], bg[3], 0, 1)
    lightCard(row, false)
    setArt(row.art, rec, THUMB_W, CARD_H, 0.36)
    -- a raid still going / ended when the group broke up
    if not rec.stop then row.tag:SetText("|cff33ff33live|r")
    elseif rec.autoEnded then row.tag:SetText(grey("auto-ended"))
    else row.tag:SetText("") end
    -- the start time, top right, when another raid was logged that day
    row.time:SetText(d.sameDay and fmtTime(rec.start) or "")
    local room = LOG_W - THUMB_W - 10 - 10 - (row.tag:GetText() ~= "" and ((row.tag:GetStringWidth() or 0) + 6) or 0)
        - (d.sameDay and ((row.time:GetStringWidth() or 0) + 8) or 0)
    local zone = rec.zone or "Raid"
    fitText(row.l1, { zone, INST_SHORT[instOf(rec)] or zone }, room)
    -- the day, the kills
    local kills = killsText(rec)
    local day = fmtTime(rec.start, "%a ") .. tonumber(fmtTime(rec.start, "%d")) .. fmtTime(rec.start, " %b")
    fitText(row.l2, { day .. " · " .. kills, ((day .. " · " .. kills):gsub(" bosses?$", "")) }, LOG_W - THUMB_W - 20)
end

----------------------------------------------------------------------------
-- The tables (the selected raid's tabs, the Players view): rows without boxes, columns per TABLES
----------------------------------------------------------------------------

-- A small rounded tag ("bench"): p:Set(text).
local function newPill(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetHeight(16)
    ns.UI:AddPillShape(p, 16)
    p:SetPillColors({ 0.2, 0.17, 0.07, 1 }, { 0.55, 0.45, 0.08, 1 })
    p.fs = newText(p, "GameFontHighlightSmall", 10)
    p.fs:SetPoint("CENTER", 0, 0)
    function p:Set(text)
        self.fs:SetText("|cffffd100" .. text .. "|r")
        self:SetWidth(floor((self.fs:GetStringWidth() or 40) + 14 + 0.5))
    end
    return p
end

-- A cell's text in its column: 12, else 11, else 10, else two lines (never cut off).
local function fitCell(fs, text, width)
    fs:SetWordWrap(false)
    fs:SetWidth(0)
    fs:SetText(text or "")
    for _, size in ipairs({ 12, 11, 10 }) do
        setSize(fs, size)
        if (fs:GetStringWidth() or 0) <= width then return end
    end
    fs:SetWidth(width)
    fs:SetWordWrap(true)
end

local function rowClick(self, button)
    if button == "RightButton" and self.cdlMenu then self.cdlMenu(self) end
end

local function rowEnter(self)
    local d = self.__cdlData
    if not d then return end
    if d.itemID then
        ns.UI:SetItemTooltip(self, d.itemID)
    elseif d.tip then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        d.tip(GameTooltip)
        GameTooltip:Show()
    end
end

local function initColRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.05)
        row.line = row:CreateTexture(nil, "BACKGROUND")
        row.line:SetPoint("BOTTOMLEFT")
        row.line:SetPoint("BOTTOMRIGHT")
        row.line:SetHeight(1)
        row.line:SetColorTexture(1, 1, 1, 0.035)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 0, 0)
        row.cols = {}
        for i = 1, 5 do row.cols[i] = newText(row, "GameFontHighlight", 12) end
        row.tag = newText(row, "GameFontHighlightSmall", 9)
        row.tag:SetTextColor(0.4, 0.8, 1)
        row.tag:SetText("GUEST")
        row.pill = newPill(row)
        row:SetScript("OnClick", rowClick)
        row:SetScript("OnEnter", rowEnter)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local L = d.place
    -- the icon column: a class circle or an item's icon before the name / item
    row.icon:SetShown(false)
    if d.class then
        ns.UI:ClassIcon(row.icon, d.class)
    elseif d.itemID and d.place.key == "award" then
        local icon = ns.ItemDB and ns.ItemDB.GetIcon and ns.ItemDB:GetIcon(d.itemID)
        row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.icon:Show()
    end
    -- after the name: GUEST, a bench tag
    row.tag:SetShown(d.guest and true or false)
    if d.pill then row.pill:Set(d.pill) end
    row.pill:SetShown(d.pill ~= nil)
    local tags = (d.guest and ((row.tag:GetStringWidth() or 30) + 6) or 0) + (d.pill and (row.pill:GetWidth() + 8) or 0)
    local first
    for i, fs in ipairs(row.cols) do
        local c = L[i]
        local text = d.cols[i]
        fs:SetShown(c ~= nil and text ~= nil and text ~= "")
        if c and text and text ~= "" then
            local indent = c.icon and 22 or 0
            fs:ClearAllPoints()
            if c.r then
                fs:SetJustifyH("RIGHT")
                fs:SetPoint("RIGHT", row, "LEFT", c.x + c.w, 0)
            else
                fs:SetJustifyH("LEFT")
                fs:SetPoint("LEFT", c.x + indent, 0)
            end
            fitCell(fs, text, c.w - indent - (c.icon and tags or 0))
            if c.r and not fs:CanWordWrap() then fs:SetWidth(c.w) end
            if c.icon then
                first = fs
                row.icon:ClearAllPoints()
                row.icon:SetPoint("LEFT", c.x, 0)
            end
        end
    end
    local prev = first
    if d.guest and prev then
        row.tag:ClearAllPoints()
        row.tag:SetPoint("LEFT", prev, "RIGHT", 6, 0)
        prev = row.tag
    end
    if d.pill and prev then
        row.pill:ClearAllPoints()
        row.pill:SetPoint("LEFT", prev, "RIGHT", 8, 0)
    end
    row.cdlMenu = d.menu
end

-- The column titles over a table (gold, a hairline under them).
local function newHead(parent)
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(HEAD_H)
    h.line = h:CreateTexture(nil, "BACKGROUND")
    h.line:SetPoint("BOTTOMLEFT")
    h.line:SetPoint("BOTTOMRIGHT")
    h.line:SetHeight(1)
    h.line:SetColorTexture(1, 1, 1, 0.08)
    h.cols = {}
    for i = 1, 5 do
        h.cols[i] = newText(h, "GameFontNormalSmall", 11)
    end
    -- (titles over numbers are right-aligned like them; a title over an icon column starts where the icon does)
    function h:SetPlace(L)
        for i, fs in ipairs(self.cols) do
            local c = L[i]
            fs:SetShown(c ~= nil)
            if c then
                fs:ClearAllPoints()
                if c.r then
                    fs:SetJustifyH("RIGHT")
                    fs:SetPoint("RIGHT", self, "LEFT", c.x + c.w, 1)
                else
                    fs:SetJustifyH("LEFT")
                    fs:SetPoint("LEFT", c.x, 1)
                end
                fs:SetText(c.title)
                if c.r then fs:SetWidth(max(c.w, ceil(fs:GetStringWidth() or 0))) else fs:SetWidth(0) end
            end
        end
    end
    return h
end

----------------------------------------------------------------------------
-- The selected raid: banner, link, tabs
----------------------------------------------------------------------------

local function benchMenu(row, rec, key, a)
    ns.UI:ContextMenu(row, function(root)
        root:CreateTitle(shortName(key))
        if a and a.b then
            root:CreateButton("Remove bench mark", function() RL():SetBench(rec.id, key, false) end)
        else
            root:CreateButton("Mark as bench / standby", function() RL():SetBench(rec.id, key, true) end)
        end
    end)
end

-- Addendum J §61: link a logged raid to a planned raid (raid log members). The running session is relinked for the
-- whole raid (GS: by the raid's authority, at the request of anyone else with the raid log; 1.3); any other record is
-- changed here and reaches the raid planners through the raid log sync.
local function planMenu(root, rec)
    local RP = ns.RaidPlan
    if not RP then return end
    local function set(occ)
        local GR = ns.GroupRules
        local s = GR and GR:GetSession()
        if s and s.id == rec.id and GR:IsAuthority() then
            ns.RaidLink:SetLink(occ)
        else
            RL():SetPlanned(rec.id, occ)
        end
    end
    root:CreateTitle("Planned raid")
    for _, v in ipairs(RP:GetRaids((rec.start or 0) - 2 * 86400, (rec.start or 0) + 2 * 86400)) do
        local label = ("%s  %s"):format(date("%a %d %b %H:%M", v.t), RP:GetRaidName(v))
        root:CreateRadio(label, function() return rec.pl == v.id end, function() set(v.id) end)
    end
    root:CreateRadio("Not linked", function() return rec.pl == nil end, function() set(nil) end)
end

-- The link picker's text: "Linked to  <planned raid>", or that it isn't linked.
local function linkText(rec)
    local RP = ns.RaidPlan
    local v = rec.pl and RP and RP:GetRaid(rec.pl)
    if v then return "|cff8c8c8cLinked to|r  " .. RP:GetRaidName(v), v end
    if rec.pl then return "|cff8c8c8cLinked to|r  " .. grey("a raid no longer planned") end
    return grey("Not linked to a planned raid")
end

-- How the sign-ups turned out: "8 of 9 came · no-show A, B" (nil when the raid had no sign-ups), and the no-shows.
local function signupCheck(rec)
    if not rec.su then return nil end
    local acc, came, noShow = 0, 0, {}
    for key, st in pairs(rec.su) do
        if st == "A" then
            acc = acc + 1
            if rec.att and rec.att[key] then came = came + 1 else noShow[#noShow + 1] = key end
        end
    end
    if acc == 0 then return nil end
    table.sort(noShow, function(a, b) return shortName(a):lower() < shortName(b):lower() end)
    return acc, came, noShow
end

local DASH = "|cff5c5c5c-|r"        -- nothing to say in a cell: a dim dash

-- The selected raid's open tab as rows, and where its columns go.
local function detailRows(rec)
    local rows = {}
    if state.tab == "boss" then
        -- (Offline only when somebody was offline at a kill)
        local offs, anyOff = {}, false
        for i, b in ipairs(rec.bosses or {}) do
            local n = 0
            for _ in pairs(b.off or {}) do n = n + 1 end
            offs[i], anyOff = n, anyOff or n > 0
        end
        local place = placeColumns("boss", DETAIL_W, { [4] = anyOff })
        for i, b in ipairs(rec.bosses or {}) do
            rows[#rows + 1] = { place = place, cols = { grey(fmtTime(b.ts)), b.name or ("Encounter " .. tostring(b.enc)),
                b.roster and tostring(#b.roster) or DASH, offs[i] > 0 and ("|cffff8080" .. offs[i] .. "|r") or DASH } }
        end
        return rows, place
    elseif state.tab == "award" and seesItems() then
        local place = placeColumns("award", DETAIL_W)
        for _, e in ipairs(RL():GetAwards(rec)) do
            rows[#rows + 1] = { place = place, itemID = e.i, cols = { ns.UI:ItemText(e.i), colored(e.w)
                .. (ns.UI:IsGuest(e.w) and grey(" guest") or ""), ns.ReasonLabel and ns.ReasonLabel(e.r) or "",
                e.vd and grey("void") or grey(fmtTime(e.ts)) } }
        end
        return rows, place
    end
    -- Attendance (Left only when somebody left before the end: a dash for who stayed)
    local nBoss = #(rec.bosses or {})
    local keys = ns.Util.Keys(rec.att or {})
    table.sort(keys, function(a, b) return shortName(a):lower() < shortName(b):lower() end)
    local function leftEarly(a) return a.j ~= nil and a.l ~= nil and a.l ~= rec.stop end
    local anyLeft = false
    for _, key in ipairs(keys) do anyLeft = anyLeft or leftEarly(rec.att[key]) end
    local place = placeColumns("att", DETAIL_W, { [4] = anyLeft })
    for _, key in ipairs(keys) do
        local a = rec.att[key]
        rows[#rows + 1] = { place = place, key = key, class = classOf(key, a.c), guest = ns.UI:IsGuest(key),
            cols = { colored(key, a.c), ("%d/%d"):format(tonumber(a.k) or 0, nBoss), a.j and fmtTime(a.j) or DASH,
                     leftEarly(a) and fmtTime(a.l) or DASH },
            pill = a.b and "bench" or nil,
            menu = function(row) benchMenu(row, rec, key, a) end,
            tip = function(tt)
                nameLines(tt, key)
                tt:AddLine(a.b and "Right-click to remove the bench mark." or "Right-click to mark as bench / standby.",
                    0.62, 0.62, 0.62)
            end }
    end
    return rows, place
end

-- The selected raid's banner: its art, the raid and whether it is still going, when / how long / who started it.
local function fillBanner(p, rec)
    local b = p.banner
    setArt(b.art, rec, DETAIL_W, BAN_H, 0.98)
    local tag
    if not rec.stop then tag = { "in progress", 0.2, 1, 0.2 }
    elseif rec.autoEnded then tag = { "auto-ended", 0.6, 0.6, 0.6 } end
    b.tag:SetShown(tag ~= nil)
    if tag then
        b.tag.text:SetText(tag[1])
        b.tag.text:SetTextColor(tag[2], tag[3], tag[4])
        ns.UI:SetEdgeColor(b.tag, tag[2], tag[3], tag[4], 0.45)
        b.tag:SetWidth((b.tag.text:GetStringWidth() or 40) + 18)
    end
    local room = DETAIL_W - 28 - (tag and (b.tag:GetWidth() + 12) or 0) - 40
    b.title:SetWordWrap(false)
    for _, size in ipairs({ 19, 17, 15 }) do
        setSize(b.title, size)
        b.title:SetText(rec.zone or "Raid")
        if (b.title:GetStringWidth() or 0) <= room then break end
    end
    -- "Thursday 1 October · 19:45 – 23:02 · 3 h 17 min · started by X" (who ended it when someone else did)
    local day = fmtTime(rec.start, "%A ") .. tonumber(fmtTime(rec.start, "%d")) .. fmtTime(rec.start, " %B")
    local span = fmtTime(rec.start) .. " – " .. (rec.stop and fmtTime(rec.stop) or "now")
    local parts = { day, span, duration((rec.stop or GetServerTime()) - (rec.start or 0)) }
    local by = rec.by and shortName(rec.by)
    if by then parts[#parts + 1] = "started by " .. colored(rec.by) end
    if rec.stop and rec.endedBy and rec.endedBy ~= rec.by then
        parts[#parts + 1] = "ended by " .. colored(rec.endedBy)
    elseif rec.autoEnded then
        parts[#parts + 1] = "ended when the group broke up"
    end
    local full = tconcat(parts, " · ")
    fitText(b.meta, { full, (full:gsub(fmtTime(rec.start, "%A "), fmtTime(rec.start, "%a "))) }, DETAIL_W - 28)
end

local function fillLink(p, rec)
    local text = linkText(rec)
    local btn = p.linkBtn
    btn:SetText(text)
    local fs = btn:GetFontString()
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", 8, 0)
    local w = min(300, max(180, floor((fs:GetStringWidth() or 0) + 34 + 0.5)))
    btn:SetWidth(w)
    fs:SetPoint("RIGHT", -20, 0)
    -- how the sign-ups turned out, at the right of the same row
    local acc, came, noShow = signupCheck(rec)
    local line = p.signupLine
    line.noShow = noShow
    line:SetShown(acc ~= nil)
    if not acc then return end
    local head = came == acc and ("|cff8fe39d%d of %d came|r"):format(came, acc) or ("%d of %d came"):format(came, acc)
    local room = DETAIL_W - w - 16
    local variants = { head }
    if #noShow > 0 then
        local names = {}
        for _, key in ipairs(noShow) do names[#names + 1] = colored(key) end
        variants = {}
        for n = #names, 1, -1 do
            local shown = { unpack(names, 1, n) }
            variants[#variants + 1] = head .. grey(" · no-show ") .. tconcat(shown, ", ")
                .. (n < #names and grey(" +" .. (#names - n)) or "")
        end
        variants[#variants + 1] = head .. grey(" · " .. #names .. " no-show")
    end
    fitText(line.fs, variants, room)
    line.fs:SetWidth(room)
    line:SetWidth(room)
end

local function fillTabs(p, rec)
    local nAtt = ns.Util.Count(rec.att or {})
    local kills = #(rec.bosses or {})
    local total = RL():GetRecordBossTotal(rec)
    p.tabAtt:SetLabel("Attendance  |cff8c8c8c" .. nAtt .. "|r")
    p.tabBoss:SetLabel("Bosses  |cff8c8c8c" .. (total and (kills .. "/" .. total) or kills) .. "|r")
    local items = seesItems()
    p.tabAward:SetShown(items)
    if items then p.tabAward:SetLabel("Awards  |cff8c8c8c" .. #RL():GetAwards(rec) .. "|r") end
    if state.tab == "award" and not items then state.tab = "att" end
    p.tabAtt:SetActive(state.tab == "att")
    p.tabBoss:SetActive(state.tab == "boss")
    p.tabAward:SetActive(state.tab == "award")
    if state.tab == "boss" then
        p.detail:SetEmptyText("No boss kills logged.")
    elseif state.tab == "award" then
        p.detail:SetEmptyText("No awards during this raid.")
    else
        p.detail:SetEmptyText("Nobody was logged in this raid.")
    end
end

----------------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------------

local function canOrganize()
    local RP = ns.RaidPlan
    return RP and RP.CanOrganize and RP:CanOrganize() or false
end

local function canTeams()
    local RP = ns.RaidPlan
    return RP and RP.CanManageTeams and RP:CanManageTeams() or false
end

local function canRoster()
    local RP = ns.RaidPlan
    return RP and RP.CanManageRoster and RP:CanManageRoster() or false
end

local function updateToolbar(p)
    if state.view == "log" and not isCouncil() then state.view = "upcoming" end
    if state.view == "guests" and not canRoster() then state.view = "upcoming" end
    local log = state.view == "log"
    -- the current view's tab is the lit one
    p.upcomingBtn:SetActive(state.view == "upcoming")
    p.teamsBtn:SetActive(state.view == "teams")
    p.stratBtn:SetActive(state.view == "strategies")
    p.guestsBtn:SetShown(canRoster())
    p.guestsBtn:SetActive(state.view == "guests")
    p.logBtn:ClearAllPoints()
    p.logBtn:SetPoint("LEFT", p.guestsBtn:IsShown() and p.guestsBtn or p.stratBtn, "RIGHT", 4, 0)
    p.logBtn:SetShown(isCouncil())
    p.logBtn:SetActive(log)
    p.logSep:SetShown(log)
    p.raidsBtn:SetShown(log)
    p.playersBtn:SetShown(log)
    p.reviewsBtn:SetShown(log)
    p.raidsBtn:SetActive(state.mode == "raids")
    p.playersBtn:SetActive(state.mode == "players")
    p.reviewsBtn:SetActive(state.mode == "reviews")
    -- (1.3.5: the reviews waiting for a decision, gold for those who decide)
    local Att_ = Att()
    local pending = log and Att_ and Att_.CanReview and Att_:CanReview() and Att_:PendingCount() or 0
    ns.UI:SetTabCount(p.reviewsBtn, pending > 0 and pending or nil)
    local overview = log and state.mode == "players" and not state.player
    p.rangeBtn:SetShown(overview)
    p.rangeBtn:SetText(rangeLabel(state.range))
    p.guestsToggle:Hide()       -- (1.3.5: "Show guests" is in the range menu)
    p.lineupBtn:SetShown(overview)
    p.lineupBtn:SetText(state.lineup and state.lineup.label or "All lineups")
    local GR = ns.GroupRules
    local auth = IsInRaid() and GR and GR:IsAuthority()
    p.sessionBtn:SetShown(auth and true or false)
    p.sessionBtn:SetText(GR and GR:GetSession() and "End raid" or "Start raid")
    -- the Players view's filters at the right of the row (left of Start / End raid)
    p.guestsToggle:ClearAllPoints()
    if auth then p.guestsToggle:SetPoint("RIGHT", p.sessionBtn, "LEFT", -6, 0) else p.guestsToggle:SetPoint("TOPRIGHT", -10, -6) end
    p.rangeBtn:ClearAllPoints()
    if auth then p.rangeBtn:SetPoint("RIGHT", p.sessionBtn, "LEFT", -6, 0) else p.rangeBtn:SetPoint("TOPRIGHT", -10, -6) end
    p.lineupBtn:ClearAllPoints()
    p.lineupBtn:SetPoint("RIGHT", p.rangeBtn, "LEFT", -6, 0)
    local organizer = canOrganize()
    local RP = ns.RaidPlan
    p.newRaidBtn:SetShown(organizer and state.view == "upcoming")
    -- (no teams yet: the Teams view's empty card has the New team button)
    p.newTeamBtn:SetShown(canTeams() and state.view == "teams" and RP ~= nil and #RP:GetTeams() > 0)
    for _, b in ipairs({ p.newRaidBtn, p.newTeamBtn }) do
        b:ClearAllPoints()
        if auth then b:SetPoint("RIGHT", p.sessionBtn, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", -10, -6) end
    end
    p.leadersBtn:SetShown(state.view == "teams")
    p.leadersBtn:ClearAllPoints()
    if p.newTeamBtn:IsShown() then
        p.leadersBtn:SetPoint("RIGHT", p.newTeamBtn, "LEFT", -6, 0)
    elseif auth then
        p.leadersBtn:SetPoint("RIGHT", p.sessionBtn, "LEFT", -6, 0)
    else
        p.leadersBtn:SetPoint("TOPRIGHT", -10, -6)
    end
end

-- The Raids view of the Raid log: the logged raids on the left, the selected one on the right.
local function createLogRaids(p)
    local UI = ns.UI
    p.raidList = UI:CreateScrollList(p, CARD_H + CARD_GAP, initRaidRow)
    p.raidList.frame:SetPoint("TOPLEFT", PAD, -TOP)
    p.raidList.frame:SetPoint("BOTTOMLEFT", PAD, 4)
    p.raidList.frame:SetWidth(LOG_W + 20)
    -- (its bar in the gap beside the column)
    p.raidList.bar:ClearAllPoints()
    p.raidList.bar:SetPoint("TOPLEFT", p.raidList.box, "TOPRIGHT", 1, 0)
    p.raidList.bar:SetPoint("BOTTOMLEFT", p.raidList.box, "BOTTOMRIGHT", 1, 0)
    -- nothing logged yet: one line across the page instead of an empty column and an empty detail
    p.logEmpty = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    p.logEmpty:SetPoint("TOP", 0, -TOP - 60)
    p.logEmpty:SetText("No raids logged yet. The raid leader starts one with Start raid (or /dz raid start).")

    local det = CreateFrame("Frame", nil, p)
    det:SetPoint("TOPLEFT", PAD + LOG_W + GAP, -TOP)
    det:SetPoint("BOTTOMRIGHT", -PAD, 4)
    p.logDetail = det

    -- the banner: the raid's art, its name (and whether it is still going) and its facts bottom left, the bin top right
    local b = CreateFrame("Frame", nil, det)
    b:SetPoint("TOPLEFT")
    b:SetPoint("TOPRIGHT")
    b:SetHeight(BAN_H)
    p.banner = b
    b.art = b:CreateTexture(nil, "BACKGROUND", nil, 0)
    b.art:SetPoint("TOPLEFT", 1, -1)
    b.art:SetPoint("BOTTOMRIGHT", -1, 1)
    b.shadeB = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.shadeB:SetAllPoints(b.art)
    gradient(b.shadeB, "VERTICAL", 0.035, 0.035, 0.043, 0.92, 0.15)
    b.shadeL = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    b.shadeL:SetPoint("TOPLEFT", b.art)
    b.shadeL:SetPoint("BOTTOMLEFT", b.art)
    b.shadeL:SetWidth(320)
    gradient(b.shadeL, "HORIZONTAL", 0.035, 0.035, 0.043, 0.7, 0)
    UI:AddEdges(b, "BORDER")
    UI:SetEdgeColor(b, EDGE[1], EDGE[2], EDGE[3], 0.7)
    b.meta = newText(b, "GameFontHighlightSmall", 11)
    b.meta:SetTextColor(0.86, 0.86, 0.86)
    b.meta:SetPoint("BOTTOMLEFT", 14, 12)
    b.title = newText(b, "GameFontHighlightLarge", 19)
    b.title:SetPoint("BOTTOMLEFT", b.meta, "TOPLEFT", 0, 6)
    b.tag = CreateFrame("Frame", nil, b)
    b.tag:SetHeight(18)
    b.tag:SetPoint("LEFT", b.title, "RIGHT", 12, 1)
    b.tag.bg = b.tag:CreateTexture(nil, "BACKGROUND")
    b.tag.bg:SetAllPoints()
    b.tag.bg:SetColorTexture(0.035, 0.035, 0.043, 0.75)
    UI:AddEdges(b.tag)
    b.tag.text = newText(b.tag, "GameFontNormalSmall", 11)
    b.tag.text:SetPoint("CENTER", 0, 0)
    -- GM / guild council: delete the logged raid
    p.deleteLogBtn = UI:CreateTipIconButton(b, 22, 12, "Delete this raid from the log",
        "Removes the logged raid for every raid planner: its boss kills and attendance no longer count. Awards stay "
        .. "in the Loot Log. This can't be undone.", function()
        local rec = state.selected and RL():GetRaid(state.selected)
        if not rec then return end
        ns.RaidPlanUI:Confirm(("Delete the logged raid %s (%s)?\n\nIts boss kills and attendance are removed for "
            .. "everyone. Awards stay in the Loot Log. This can't be undone."):format(rec.zone or "Raid",
            fmtTime(rec.start, "%a %d %b")), function()
            local ok, err = RL():Delete(rec.id)
            if not ok then ns:Print("%s", err or "Could not delete the raid.") end
        end)
    end)
    p.deleteLogBtn:SetPoint("TOPRIGHT", -10, -8)

    -- the planned raid it is linked to (a picker), how its sign-ups turned out on the right
    p.linkBtn = UI:CreateSleekMenuButton(det, "", 240, function(root)
        local rec = state.selected and RL():GetRaid(state.selected)
        if rec then planMenu(root, rec) end
    end, LINK_H)
    p.linkBtn:SetPoint("TOPLEFT", 0, -(BAN_H + GAP))
    p.linkBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Planned raid")
        GameTooltip:AddLine("The raid on the Upcoming board this one was: its sign-ups tell who came and who didn't. "
            .. "Pick another to relink it.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    p.linkBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    local sl = CreateFrame("Frame", nil, det)
    sl:SetHeight(LINK_H)
    sl:SetPoint("TOPRIGHT", 0, -(BAN_H + GAP))
    sl.fs = newText(sl, "GameFontHighlightSmall", 11)
    sl.fs:SetJustifyH("RIGHT")
    sl.fs:SetPoint("RIGHT", 0, 0)
    sl:EnableMouse(true)
    sl:SetScript("OnEnter", function(self)
        if not (self.noShow and #self.noShow > 0) then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Accepted but didn't come")
        for _, key in ipairs(self.noShow) do GameTooltip:AddLine(colored(key)) end
        GameTooltip:Show()
    end)
    sl:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p.signupLine = sl

    -- Attendance / Bosses / Awards
    local tabs = CreateFrame("Frame", nil, det)
    tabs:SetHeight(TABS_H)
    tabs:SetPoint("TOPLEFT", 0, -(BAN_H + GAP + LINK_H + GAP))
    tabs:SetPoint("TOPRIGHT", 0, -(BAN_H + GAP + LINK_H + GAP))
    p.logTabs = tabs
    local function tab(label, key)
        return UI:CreateUnderlineTab(tabs, label, function()
            state.tab = key
            RaidsUI:Refresh()
        end, "small")
    end
    p.tabAtt = tab("Attendance", "att")
    p.tabAtt:SetPoint("BOTTOMLEFT", -4, 0)
    p.tabBoss = tab("Bosses", "boss")
    p.tabBoss:SetPoint("LEFT", p.tabAtt, "RIGHT", 4, 0)
    p.tabAward = tab("Awards", "award")
    p.tabAward:SetPoint("LEFT", p.tabBoss, "RIGHT", 4, 0)
    tabs.line = tabs:CreateTexture(nil, "BORDER")
    tabs.line:SetPoint("BOTTOMLEFT")
    tabs.line:SetPoint("BOTTOMRIGHT")
    tabs.line:SetHeight(1)
    tabs.line:SetColorTexture(1, 1, 1, 0.1)

    local top = BAN_H + GAP + LINK_H + GAP + TABS_H + GAP
    p.logHead = newHead(det)
    p.logHead:SetPoint("TOPLEFT", 0, -top)
    p.logHead:SetPoint("TOPRIGHT", 0, -top)
    p.detail = UI:CreateScrollList(det, ROW_H, initColRow)
    p.detail.frame:SetPoint("TOPLEFT", 0, -(top + HEAD_H + 2))
    p.detail.frame:SetPoint("BOTTOMRIGHT", 20, 0)
    p.detail.bar:ClearAllPoints()
    p.detail.bar:SetPoint("TOPLEFT", p.detail.box, "TOPRIGHT", 4, 0)
    p.detail.bar:SetPoint("BOTTOMLEFT", p.detail.box, "BOTTOMRIGHT", 4, 0)
    -- 1.3.5: the Attendance tab is a time bar per player (UI/AttendanceUI.lua)
    p.timeline = AUI():CreateTimeline(det, DETAIL_W)
    p.timeline:SetPoint("TOPLEFT", 0, -top)
    p.timeline:SetPoint("BOTTOMRIGHT", 0, 0)
    p.timeline.menuExtra = function(root, r)
        local rec = state.selected and RL():GetRaid(state.selected)
        local G = ns.Guild
        if not (rec and (demoOn() or (G and G.AmIRaidLogMember and G:AmIRaidLogMember()))) then return end
        local a = rec.att and rec.att[r.key]
        if a and a.b then
            root:CreateButton("Remove bench mark", function() RL():SetBench(rec.id, r.key, false) end)
        else
            root:CreateButton("Mark as bench / standby", function() RL():SetBench(rec.id, r.key, true) end)
        end
    end
end

-- The Attendance view of the Raid log (1.3.5, UI/AttendanceUI.lua): every member, or one member's page.
local function createLogPlayers(p)
    local f = CreateFrame("Frame", nil, p)
    f:SetPoint("TOPLEFT", PAD, -TOP)
    f:SetPoint("BOTTOMRIGHT", -PAD, 4)
    p.playersView = f
    p.overview = AUI():CreateOverview(f, INNER_W)
    p.overview:SetPoint("TOPLEFT")
    p.overview:SetPoint("BOTTOMRIGHT")
    p.overview.onPick = function(key)
        state.player = key
        RaidsUI:Refresh()
    end
    p.playerPage = AUI():CreatePlayerPage(f, INNER_W)
    p.playerPage:SetPoint("TOPLEFT")
    p.playerPage:SetPoint("BOTTOMRIGHT")
    p.playerPage.onBack = function()
        state.player = nil
        RaidsUI:Refresh()
    end
    -- Reviews: what waits for a decision, then what was decided
    p.reviews = AUI():CreateReviews(p, INNER_W)
    p.reviews:SetPoint("TOPLEFT", PAD, -TOP)
    p.reviews:SetPoint("BOTTOMRIGHT", -PAD, 4)
end

-- The lineups to filter the Attendance view by: every team's lineups.
local function lineupMenu(root)
    root:CreateRadio("All lineups", function() return state.lineup == nil end, function()
        state.lineup = nil
        RaidsUI:Refresh()
    end)
    local RP = ns.RaidPlan
    for _, t in ipairs(RP and RP.GetTeams and RP:GetTeams() or {}) do
        for _, l in ipairs(t.lineups or {}) do
            local label = t.name .. " · " .. (RP:LineupName(t, l) or "")
            root:CreateRadio(label, function() return state.lineup and state.lineup.id == l.id and state.lineup.team == t.id end,
                function()
                    state.lineup = { team = t.id, id = l.id, label = label }
                    RaidsUI:Refresh()
                end)
        end
    end
end

function RaidsUI:CreatePanel(parent)
    if panel then return panel end
    local UI = ns.UI
    local p = CreateFrame("Frame", "DisasterZoneRaidsPanel", parent)
    p:SetAllPoints(parent)
    panel = p

    -- the page's views (text tabs); the Raid log's own Raids / Players views are smaller tabs beside them
    p.upcomingBtn = UI:CreateUnderlineTab(p, "Upcoming", function() RaidsUI:SetView("upcoming") end)
    p.upcomingBtn:SetPoint("TOPLEFT", 6, -6)
    p.teamsBtn = UI:CreateUnderlineTab(p, "Teams", function() RaidsUI:SetView("teams") end)
    p.teamsBtn:SetPoint("LEFT", p.upcomingBtn, "RIGHT", 4, 0)
    p.stratBtn = UI:CreateUnderlineTab(p, "Strategies", function() RaidsUI:SetView("strategies") end)
    p.stratBtn:SetPoint("LEFT", p.teamsBtn, "RIGHT", 4, 0)
    -- 1.3.2: the guest book and the blacklist (players kept out of every raid), for the GM, officers and the raid
    -- leaders
    p.guestsBtn = UI:CreateUnderlineTab(p, "Guests", function() RaidsUI:SetView("guests") end)
    p.guestsBtn:SetPoint("LEFT", p.stratBtn, "RIGHT", 4, 0)
    p.logBtn = UI:CreateUnderlineTab(p, "Raid log", function() RaidsUI:SetView("log") end)
    p.logBtn:SetPoint("LEFT", p.guestsBtn, "RIGHT", 4, 0)

    p.logSep = p:CreateTexture(nil, "ARTWORK")
    p.logSep:SetColorTexture(1, 1, 1, 0.15)
    p.logSep:SetSize(1, 14)
    p.logSep:SetPoint("LEFT", p.logBtn, "RIGHT", 8, -1)
    p.raidsBtn = UI:CreateUnderlineTab(p, "Raids", function() state.mode = "raids"; RaidsUI:Refresh() end, "small")
    p.raidsBtn:SetPoint("LEFT", p.logBtn, "RIGHT", 16, -1)
    p.playersBtn = UI:CreateUnderlineTab(p, "Attendance", function()
        state.mode, state.player = "players", nil
        RaidsUI:Refresh()
    end, "small")
    p.playersBtn:SetPoint("LEFT", p.raidsBtn, "RIGHT", 2, 0)
    p.reviewsBtn = UI:CreateUnderlineTab(p, "Reviews", function() state.mode = "reviews"; RaidsUI:Refresh() end, "small")
    p.reviewsBtn:SetPoint("LEFT", p.playersBtn, "RIGHT", 2, 0)
    p.lineupBtn = UI:CreateSleekMenuButton(p, "All lineups", 116, function(root) lineupMenu(root) end)
    -- the Players view's filters, at the right of the row: how many raids count, and the guests (pugs)
    p.rangeBtn = UI:CreateSleekMenuButton(p, rangeLabel(state.range), 110, function(root)
        for _, n in ipairs(RANGES) do
            root:CreateRadio(rangeLabel(n), function() return state.range == n end, function()
                state.range = n
                RaidsUI:Refresh()
            end)
        end
        -- 1.3.5: players outside the guild (pugs), left out unless asked for
        root:CreateDivider()
        local cb = root:CreateCheckbox("Show guests", function() return state.showGuests end, function()
            state.showGuests = not state.showGuests
            RaidsUI:Refresh()
        end)
        cb:SetTitleAndTextTooltip("Show guests", "Players outside the guild (pugs) who raided with us.")
    end)
    -- 1.3: players outside the guild (the guest book has them) are left out of the attendance list unless shown
    -- (a switch: lit while they are shown)
    local function guestsTip(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(state.showGuests and "Guests shown" or "Guests left out")
        GameTooltip:AddLine("Players outside the guild (pugs) who raided with us. Click to "
            .. (state.showGuests and "leave them out." or "list them too."), 1, 1, 1, true)
        GameTooltip:Show()
    end
    p.guestsToggle = UI:CreateSleekButton(p, "Guests", 64, 22, function(self)
        state.showGuests = not state.showGuests
        RaidsUI:Refresh()
        if GameTooltip:GetOwner() == self then guestsTip(self) end
    end)
    p.guestsToggle:SetPoint("TOPRIGHT", -10, -6)
    p.guestsToggle:HookScript("OnEnter", guestsTip)
    p.guestsToggle:HookScript("OnLeave", function() GameTooltip:Hide() end)
    p.rangeBtn:SetPoint("RIGHT", p.guestsToggle, "LEFT", -6, 0)
    p.sessionBtn = UI:CreateSleekButton(p, "Start raid", 88, 22, function()
        if ns.GroupRules:GetSession() then
            ns.SessionBar:ConfirmEnd()
        else
            ns.SessionBar:OpenStart()
        end
    end)
    p.sessionBtn:SetPoint("TOPRIGHT", -10, -6)
    p.newRaidBtn = UI:CreateSleekButton(p, "New raid", 90, 22, function() ns.RaidPlanUI:OpenEditor() end, "primary")
    p.newTeamBtn = UI:CreateSleekButton(p, "New team", 90, 22, function() ns.RaidPlanUI:NewTeam() end)
    -- Addendum J §62: who the raid leaders are (everyone can look; the GM edits)
    p.leadersBtn = UI:CreateTipIconButton(p, 22, UI.ICON.crown, "Raid leaders", "Who plans and leads raids. "
        .. "Everyone can look; officers and the Guild Master change the list.", function() ns.RaidLeadersUI:Open() end)

    local PlanUI = ns.RaidPlanUI
    p.upcoming = PlanUI:CreateUpcoming(p)
    p.upcoming:SetPoint("TOPLEFT", 0, -36)
    p.upcoming:SetPoint("BOTTOMRIGHT", 0, 4)
    p.teams = PlanUI:CreateTeams(p)
    p.teams:SetPoint("TOPLEFT", 0, -36)
    p.teams:SetPoint("BOTTOMRIGHT", 0, 4)
    p.strategies = ns.StrategiesUI:CreateLibrary(p)
    p.strategies:SetPoint("TOPLEFT", 0, -36)
    p.strategies:SetPoint("BOTTOMRIGHT", 0, 4)
    p.guests = ns.GuestBookUI:CreateView(p)
    p.guests:SetPoint("TOPLEFT", 0, -36)
    p.guests:SetPoint("BOTTOMRIGHT", 0, 4)

    createLogRaids(p)
    createLogPlayers(p)

    -- (a page switch shows the panel, then calls OnPanelShown: one refresh per frame is enough)
    p:SetScript("OnShow", function(self)
        self.shownAt = GetTime()
        RaidsUI:Refresh()
    end)
    function p:OnPanelShown()
        if self.shownAt ~= GetTime() then RaidsUI:Refresh() end
    end
    C_Timer.After(0, function() RaidsUI:Refresh() end)
    return p
end

local function refreshLogRaids(p)
    local raids = RL():GetRaids()
    local found = false
    for _, rec in ipairs(raids) do
        if rec.id == state.selected then found = true end
    end
    if not found then state.selected = raids[1] and raids[1].id or nil end
    -- (a day with more than one logged raid: their cards say the time)
    local perDay = {}
    for _, rec in ipairs(raids) do
        local day = fmtTime(rec.start, "%Y%m%d")
        perDay[day] = (perDay[day] or 0) + 1
    end
    local rows = {}
    for _, rec in ipairs(raids) do
        rows[#rows + 1] = { rec = rec, sameDay = perDay[fmtTime(rec.start, "%Y%m%d")] > 1 }
    end
    p.raidList:SetData(rows)
    local sel = state.selected and RL():GetRaid(state.selected)
    p.logEmpty:SetShown(#raids == 0)
    p.raidList.frame:SetShown(#raids > 0)
    p.logDetail:SetShown(sel ~= nil)
    if not sel then
        p.deleteLogBtn:Hide()
        p.detail:SetData({})
        return
    end
    fillBanner(p, sel)
    p.deleteLogBtn:SetShown(sel.stop ~= nil and RL():CanDelete())
    fillLink(p, sel)
    fillTabs(p, sel)
    -- 1.3.5: the Attendance tab draws the night's time bars; the link row says how it went
    local att = state.tab == "att" and Att() ~= nil
    p.timeline:SetShown(att)
    p.logHead:SetShown(not att)
    p.detail.frame:SetShown(not att)
    if att then
        local night = Att():NightOf(sel)
        if night then
            local sum = p.timeline:SetNight(night)
            local text = AUI():SummaryText(sum)
            local line = p.signupLine
            if text then
                local room = DETAIL_W - p.linkBtn:GetWidth() - 16
                line.noShow = nil
                line:SetShown(true)
                fitText(line.fs, { text }, room)
                line.fs:SetWidth(room)
                line:SetWidth(room)
            end
        end
        return
    end
    local rows, place = detailRows(sel)
    p.logHead:SetPlace(place)
    p.detail:SetData(rows)
end

function RaidsUI:Refresh()
    if not panel or not panel:IsVisible() then return end
    -- (the New / Edit raid sheet covers the tab: the page under it comes back when it closes)
    if ns.RaidPlanUI and ns.RaidPlanUI.IsEditorOpen and ns.RaidPlanUI:IsEditorOpen() then return end
    updateToolbar(panel)
    local log = state.view == "log"
    panel.upcoming:SetShown(state.view == "upcoming")
    panel.teams:SetShown(state.view == "teams")
    panel.strategies:SetShown(state.view == "strategies")
    panel.guests:SetShown(state.view == "guests")
    local raidsMode = state.mode == "raids"
    panel.raidList.frame:SetShown(log and raidsMode)
    panel.logDetail:SetShown(log and raidsMode)
    panel.logEmpty:SetShown(false)
    panel.playersView:SetShown(log and state.mode == "players")
    panel.reviews:SetShown(log and state.mode == "reviews")
    if state.view == "strategies" then
        ns.StrategiesUI:RefreshLibrary()
    elseif state.view == "guests" then
        ns.GuestBookUI:Refresh()
    elseif not log then
        ns.RaidPlanUI:Refresh()
    elseif raidsMode then
        refreshLogRaids(panel)
    elseif state.mode == "reviews" then
        panel.reviews:Refresh()
    else
        panel.overview:SetShown(state.player == nil)
        panel.playerPage:SetShown(state.player ~= nil)
        if state.player then
            panel.playerPage:SetPlayer(state.player)
        else
            panel.overview.state.range = state.range
            panel.overview.state.guests = state.showGuests
            panel.overview.state.lineup = state.lineup
            panel.overview:Refresh()
        end
    end
end

function RaidsUI:RequestRefresh()
    if panel and panel:IsVisible() then ns.Util.Debounce("raids-ui", 0.2, function() RaidsUI:Refresh() end) end
end

-- For tests / other modules: selects a logged raid (and the Raid log's Raids mode).
function RaidsUI:Select(id)
    state.view, state.mode, state.selected, state.tab = "log", "raids", id, "att"
    self:Refresh()
end

-- For tests / other modules: the Raid log's Raids (on a raid's Attendance), Attendance ("players") or Reviews view.
function RaidsUI:SetMode(mode, range)
    state.view, state.tab = "log", "att"
    state.mode = (mode == "players" or mode == "reviews") and mode or "raids"
    state.player = nil
    if range then state.range = range end
    self:Refresh()
end

-- 1.3.5: the Attendance view lists players outside the guild (pugs) too.
function RaidsUI:SetShowGuests(on)
    state.showGuests = on and true or false
    self:Refresh()
end

-- 1.3.5: a member's attendance page (Raid log > Attendance).
function RaidsUI:ShowAttendancePlayer(key)
    state.view, state.mode, state.player = "log", "players", key
    self:Refresh()
end

-- The member whose attendance page is open (or nil).
function RaidsUI:GetAttendancePlayer() return state.player end

-- The Attendance view's lineup filter: { team, id, label } or nil.
function RaidsUI:SetLineupFilter(f)
    state.lineup = f
    self:Refresh()
end

-- The selected logged raid's tab: "att" (Attendance) | "boss" (Bosses) | "award" (Awards).
function RaidsUI:SetLogTab(tab)
    state.tab = (tab == "boss" or tab == "award") and tab or "att"
    self:Refresh()
end

-- "upcoming" | "teams" | "strategies" | "guests" (roster managers) | "log" (the log is council only).
function RaidsUI:SetView(view)
    if view ~= "teams" and view ~= "log" and view ~= "strategies" and view ~= "guests" then view = "upcoming" end
    -- leaving Teams with unsaved changes asks first (Save / Discard / Cancel)
    if state.view == "teams" and view ~= "teams" and panel and panel:IsVisible() and ns.RaidPlanUI.GuardDraft then
        return ns.RaidPlanUI:GuardDraft(function()
            state.view = view
            RaidsUI:Refresh()
        end)
    end
    state.view = view
    self:Refresh()
end

function RaidsUI:GetView() return state.view end

function RaidsUI:GetPanel() return panel end

-- Everyone in a guild plans raids here; the raid log inside stays council only.
function RaidsUI:IsAvailable()
    return (IsInGuild() or isCouncil()) and true or false
end

function RaidsUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("raids", "Raids", 3.5,
            function(parent) return RaidsUI:CreatePanel(parent) end,
            function() return RaidsUI:IsAvailable() end)
    end
    local function refresh() RaidsUI:RequestRefresh() end
    for _, msg in ipairs({ "RAIDLOG_CHANGED", "LEDGER_UPDATED", "GROUP_RULES_CHANGED", "ROSTER_UPDATED", "ITEMINFO_READY",
                           "DEMO_TOGGLED", "CONFIG_UPDATED", "ATTENDANCE_RULES_CHANGED" }) do
        ns:On(msg, refresh)
    end
    ns:RegisterSlash("raids", function()
        state.view = "upcoming"
        ns.MainFrame:Open("raids")
        RaidsUI:Refresh()
    end, "open the Raids tab: upcoming raids and sign-ups")
end
