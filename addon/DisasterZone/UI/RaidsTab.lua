if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RaidsTab.lua", ...) then return end -- DisasterZone: "Raids" tab. Three views (Addendum J §58):
--   Upcoming - planned raids and sign-ups (everyone; UI/RaidPlanUI.lua)
--   Teams    - the raid teams (everyone can look; organizers edit; UI/RaidPlanUI.lua)
--   Strategies - the strategy boards per boss (everyone looks and builds, each changes their own; Addendum K,
--               UI/StrategiesView.lua)
--   Raid log - council only (Addendum I §51), with two modes:
--     Raids   - the raid sessions (newest first) and, for the selected one, its boss timeline, attendance (with
--               bench marks, right-click to change) and the awards made during it.
--     Players - attendance % / boss kills / items received per player over the last N raids.
-- Start / End raid for the raid's authority sits in the toolbar. The Raid log is for raid log members (GM, guild
-- council, raid leaders; Addendum J §62), its awarded items for the loot council only.
local addonName, ns = ...

local RaidsUI = ns:NewModule("RaidsUI")

local LIST_W = 290
local RAID_ROW_H = 34
local ROW_H = 20
local RANGES = { 4, 8, 12, 0 }   -- 0 = all raids

local state = { view = "upcoming", mode = "raids", selected = nil, range = 8, showGuests = false }
local panel

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function grey(text) return "|cff808080" .. tostring(text) .. "|r" end

local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

local function colored(key, classFile)
    return ns.UI:ColoredName(key, classFile or (ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)))
        .. ns.UI:GuestTag(key)
end

local function duration(sec)
    sec = math.floor(math.max(0, sec or 0))
    return ("%d:%02d"):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end

local function fmtTime(ts, fmt) return ts and date(fmt or "%H:%M", ts) or "-" end

local function RL() return ns.RaidLog end

local function rangeLabel(n) return n == 0 and "All raids" or ("Last " .. n .. " raids") end

local function demoOn()
    return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() and true or false
end

-- The Raid log view (Addendum J §62): the GM, the guild council and the raid leaders list (not whoever happens to
-- lead a group: that is loot council for one raid only).
local function isCouncil()
    local G = ns.Guild
    return (demoOn() or (G and G.AmIRaidLogMember and G:AmIRaidLogMember())) and true or false
end

-- Awarded items in the raid log: loot council data (GM / guild council), not for raid leaders.
local function seesItems()
    local G = ns.Guild
    return (demoOn() or (G and G.IsGuildCouncil and G:IsGuildCouncil(ns.Util.PlayerKey()))) and true or false
end

local function raidSummary(rec)
    local kills = #(rec.bosses or {})
    local total = RL():GetBossTotal(rec.instID)
    local parts = {
        duration((rec.stop or GetServerTime()) - (rec.start or 0)),
        total and ("%d/%d bosses"):format(kills, total) or (kills .. " bosses"),
        ns.Util.Count(rec.att or {}) .. " raiders",
    }
    if seesItems() then parts[#parts + 1] = #RL():GetAwards(rec) .. " items" end
    return table.concat(parts, " · ")
end

local function raidTag(rec)
    if not rec.stop then return " |cff33ff33(in progress)|r" end
    if rec.autoEnded then return " " .. grey("(auto-ended)") end
    return ""
end

----------------------------------------------------------------------------
-- Raid list (left)
----------------------------------------------------------------------------

local function initRaidRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.5)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.12)
        row.l1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.l1:SetPoint("TOPLEFT", 6, -3)
        row.l1:SetPoint("RIGHT", -4, 0)
        row.l1:SetJustifyH("LEFT")
        row.l1:SetWordWrap(false)
        row.l2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.l2:SetPoint("TOPLEFT", 6, -19)
        row.l2:SetPoint("RIGHT", -4, 0)
        row.l2:SetJustifyH("LEFT")
        row.l2:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            state.selected = self.cdlRec and self.cdlRec.id
            RaidsUI:Refresh()
        end)
    end
    local rec = d.rec
    row.cdlRec = rec
    row.l1:SetText(fmtTime(rec.start, "%a %m/%d") .. "  " .. (rec.zone or grey("zone not seen")) .. raidTag(rec))
    row.l2:SetText(raidSummary(rec))
    row.sel:SetShown(rec.id == state.selected)
end

----------------------------------------------------------------------------
-- Detail / players list (shared row type with columns)
----------------------------------------------------------------------------

local COLS = { 6, 150, 250, 330, 410 }

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

-- Addendum J §61: link a logged raid to a planned raid (council). The running session of the raid I lead is
-- relinked for everyone (GS); any other record is changed here and reaches the council through the raid log sync.
local function planMenu(row, rec)
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
    ns.UI:ContextMenu(row, function(root)
        root:CreateTitle("Planned raid")
        for _, v in ipairs(RP:GetRaids((rec.start or 0) - 2 * 86400, (rec.start or 0) + 2 * 86400)) do
            local label = ("%s  %s"):format(date("%a %d %b %H:%M", v.t), RP:GetRaidName(v))
            root:CreateRadio(label, function() return rec.pl == v.id end, function() set(v.id) end)
        end
        root:CreateRadio("Not linked", function() return rec.pl == nil end, function() set(nil) end)
    end)
end

local function planLines(rec)
    local RP = ns.RaidPlan
    local out = {}
    local v = rec.pl and RP and RP:GetRaid(rec.pl)
    if v then
        out[1] = ("Planned raid: %s · %s"):format(RP:GetRaidName(v), date("%a %d %b %H:%M", v.t))
    elseif rec.pl then
        out[1] = "Planned raid: " .. grey("(no longer in the plan)")
    else
        out[1] = grey("Not linked to a planned raid (right-click to link)")
    end
    if rec.su then
        local acc, came, noShow = 0, 0, {}
        for key, st in pairs(rec.su) do
            if st == "A" then
                acc = acc + 1
                if rec.att and rec.att[key] then came = came + 1 else noShow[#noShow + 1] = shortName(key) end
            end
        end
        table.sort(noShow)
        out[2] = ("Sign-ups: %d accepted, %d came"):format(acc, came)
            .. (#noShow > 0 and ("  ·  |cffff8080no-show: " .. table.concat(noShow, ", ") .. "|r") or "")
    end
    return out
end

local function initDetailRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.cols = {}
        for i, x in ipairs(COLS) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", x, 0)
            fs:SetWidth((COLS[i + 1] or (x + 200)) - x - 4)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            row.cols[i] = fs
        end
        row:SetScript("OnClick", function(self, button)
            if button == "RightButton" and self.cdlMenu then self.cdlMenu(self) end
        end)
        row:SetScript("OnEnter", function(self)
            if self.cdlItem then ns.UI:SetItemTooltip(self, self.cdlItem) end
        end)
        row:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    end
    for i, fs in ipairs(row.cols) do
        fs:SetFontObject(d.header and "GameFontNormal" or (d.colHeader and "GameFontNormalSmall" or "GameFontHighlightSmall"))
        fs:SetText(d.cols[i] or "")
        if (d.header or d.wide) and i == 1 then fs:SetWidth(460) elseif i == 1 then fs:SetWidth(COLS[2] - COLS[1] - 4) end
    end
    row.cdlMenu = d.menu
    row.cdlItem = d.itemID
end

local function detailRows(rec)
    local rows = {}
    local function add(cols, opts)
        local r = opts or {}
        r.cols = cols
        rows[#rows + 1] = r
    end
    local by = rec.by and shortName(rec.by) or "?"
    add({ (rec.zone or "Raid") .. "  " .. grey(fmtTime(rec.start, "%Y-%m-%d")) .. raidTag(rec) }, { header = true })
    local ended = rec.stop and (fmtTime(rec.stop) .. (rec.endedBy and (" by " .. shortName(rec.endedBy)) or
        (rec.autoEnded and " (group disbanded)" or ""))) or "running"
    add({ "Started " .. fmtTime(rec.start) .. " by " .. by .. "  ·  ended " .. ended }, { wide = true })
    add({ raidSummary(rec) }, { wide = true })
    for _, line in ipairs(planLines(rec)) do
        add({ line }, { menu = function(row) planMenu(row, rec) end, wide = true })
    end

    add({ "Bosses" }, { header = true })
    local nBoss = #(rec.bosses or {})
    if nBoss == 0 then add({ grey("No boss kills logged.") }, { wide = true }) end
    for _, b in ipairs(rec.bosses or {}) do
        local off = 0
        for _ in pairs(b.off or {}) do off = off + 1 end
        -- one line: when, who, how many were there
        local parts = { fmtTime(b.ts) .. "  " .. (b.name or ("Encounter " .. tostring(b.enc))) }
        if b.roster then parts[#parts + 1] = grey(#b.roster .. " in raid") end
        if off > 0 then parts[#parts + 1] = "|cffff8080" .. off .. " offline|r" end
        add({ table.concat(parts, "  ·  ") }, { wide = true })
    end

    add({ "Attendance" }, { header = true })
    add({ "Player", "Boss kills", "Joined", "Left", "" }, { colHeader = true })
    local keys = ns.Util.Keys(rec.att or {})
    table.sort(keys, function(a, b) return shortName(a):lower() < shortName(b):lower() end)
    for _, key in ipairs(keys) do
        local a = rec.att[key]
        local note = a.b and "|cffffd100bench|r" or ""
        add({ colored(key, a.c), ("%d/%d"):format(tonumber(a.k) or 0, nBoss), fmtTime(a.j),
            (a.l and a.l ~= rec.stop) and fmtTime(a.l) or grey("end"), note },
            { menu = function(row) benchMenu(row, rec, key, a) end })
    end

    if not seesItems() then return rows end
    add({ "Awards" }, { header = true })
    local awards = RL():GetAwards(rec)
    if #awards == 0 then add({ grey("No awards during this raid.") }, { wide = true }) end
    for _, e in ipairs(awards) do
        add({ fmtTime(e.ts), ns.UI:ItemText(e.i), colored(e.w), ns.ReasonLabel and ns.ReasonLabel(e.r) or "",
            e.vd and grey("void") or "" }, { itemID = e.i })
    end
    return rows
end

local function playerRows()
    local n = state.range ~= 0 and state.range or nil
    local stats, total = RL():GetPlayerStats(n)
    local rows = { { cols = { "Player", "Raids", "Attendance", "Boss kills", "Items (last)" }, colHeader = true } }
    for _, s in ipairs(stats) do
        -- 1.3: players outside the guild have the guest book; they show here only on request
        if state.showGuests or not ns.UI:IsGuest(s.key) then
            local last = s.lastItem and (s.items .. "  " .. ns.UI:ItemText(s.lastItem.i)) or tostring(s.items)
            -- Addendum J §61: accepted raids they didn't come to (raids linked to a planned raid)
            local rel = RL().GetReliability and RL():GetReliability(s.key, n or 1000)
            local noShow = rel and (rel.accepted - rel.came) or 0
            if not seesItems() then last = "" end
            rows[#rows + 1] = { cols = { colored(s.key, s.class), ("%d/%d"):format(s.raids, total) ..
                (s.bench > 0 and grey(" (" .. s.bench .. " bench)") or ""),
                s.pct .. "%" .. (noShow > 0 and (" |cffff8080" .. noShow .. " no-show|r") or ""),
                ("%d/%d"):format(s.kills, s.killTotal), last },
                itemID = seesItems() and s.lastItem and s.lastItem.i or nil }
        end
    end
    return rows, total
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

local function updateToolbar(p)
    if state.view == "log" and not isCouncil() then state.view = "upcoming" end
    local log = state.view == "log"
    -- the current view's tab is the lit one
    p.upcomingBtn:SetActive(state.view == "upcoming")
    p.teamsBtn:SetActive(state.view == "teams")
    p.stratBtn:SetActive(state.view == "strategies")
    p.logBtn:SetShown(isCouncil())
    p.logBtn:SetActive(log)
    p.logSep:SetShown(log)
    p.raidsBtn:SetShown(log)
    p.playersBtn:SetShown(log)
    p.raidsBtn:SetActive(state.mode == "raids")
    p.playersBtn:SetActive(state.mode == "players")
    p.rangeBtn:SetShown(log and state.mode == "players")
    p.rangeBtn:SetText(rangeLabel(state.range))
    p.guestsToggle:SetShown(log and state.mode == "players")
    p.guestsToggle:SetKind(state.showGuests and "chosen" or "secondary")
    -- the raid count, in the Raids list only (each player's "Raids" column already says how many raids count)
    p.count:SetShown(log and state.mode == "raids")
    local GR = ns.GroupRules
    local auth = IsInRaid() and GR and GR:IsAuthority()
    p.sessionBtn:SetShown(auth and true or false)
    p.sessionBtn:SetText(GR and GR:GetSession() and "End raid" or "Start raid")
    local organizer = canOrganize()
    local RP = ns.RaidPlan
    p.guestsBtn:SetShown(state.view == "upcoming" and RP and RP.CanManageRoster and RP:CanManageRoster() or false)
    p.guestsBtn:ClearAllPoints()
    if organizer then
        p.guestsBtn:SetPoint("RIGHT", p.newRaidBtn, "LEFT", -6, 0)
    elseif auth then
        p.guestsBtn:SetPoint("RIGHT", p.sessionBtn, "LEFT", -6, 0)
    else
        p.guestsBtn:SetPoint("TOPRIGHT", -8, -6)
    end
    p.newRaidBtn:SetShown(organizer and state.view == "upcoming")
    p.newTeamBtn:SetShown(canTeams() and state.view == "teams")
    for _, b in ipairs({ p.newRaidBtn, p.newTeamBtn }) do
        b:ClearAllPoints()
        if auth then b:SetPoint("RIGHT", p.sessionBtn, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", -8, -6) end
    end
    p.leadersBtn:SetShown(state.view == "teams")
    p.leadersBtn:ClearAllPoints()
    if canTeams() then
        p.leadersBtn:SetPoint("RIGHT", p.newTeamBtn, "LEFT", -6, 0)
    elseif auth then
        p.leadersBtn:SetPoint("RIGHT", p.sessionBtn, "LEFT", -6, 0)
    else
        p.leadersBtn:SetPoint("TOPRIGHT", -8, -6)
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
    p.upcomingBtn:SetPoint("TOPLEFT", 4, -6)
    p.teamsBtn = UI:CreateUnderlineTab(p, "Teams", function() RaidsUI:SetView("teams") end)
    p.teamsBtn:SetPoint("LEFT", p.upcomingBtn, "RIGHT", 4, 0)
    p.stratBtn = UI:CreateUnderlineTab(p, "Strategies", function() RaidsUI:SetView("strategies") end)
    p.stratBtn:SetPoint("LEFT", p.teamsBtn, "RIGHT", 4, 0)
    p.logBtn = UI:CreateUnderlineTab(p, "Raid log", function() RaidsUI:SetView("log") end)
    p.logBtn:SetPoint("LEFT", p.stratBtn, "RIGHT", 4, 0)

    p.logSep = p:CreateTexture(nil, "ARTWORK")
    p.logSep:SetColorTexture(1, 1, 1, 0.15)
    p.logSep:SetSize(1, 14)
    p.logSep:SetPoint("LEFT", p.logBtn, "RIGHT", 8, -1)
    p.raidsBtn = UI:CreateUnderlineTab(p, "Raids", function() state.mode = "raids"; RaidsUI:Refresh() end, "small")
    p.raidsBtn:SetPoint("LEFT", p.logBtn, "RIGHT", 16, -1)
    p.playersBtn = UI:CreateUnderlineTab(p, "Players", function() state.mode = "players"; RaidsUI:Refresh() end,
        "small")
    p.playersBtn:SetPoint("LEFT", p.raidsBtn, "RIGHT", 2, 0)
    p.rangeBtn = UI:CreateSleekMenuButton(p, rangeLabel(state.range), 100, function(root)
        for _, n in ipairs(RANGES) do
            root:CreateButton(rangeLabel(n), function()
                state.range = n
                RaidsUI:Refresh()
            end)
        end
    end)
    p.rangeBtn:SetPoint("LEFT", p.playersBtn, "RIGHT", 8, 0)
    -- 1.3: players outside the guild (the guest book has them) are left out of the attendance list unless shown
    -- (a switch: lit while they are shown; it stays clear of Start raid at the top right)
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
    p.guestsToggle:SetPoint("LEFT", p.rangeBtn, "RIGHT", 4, 0)
    p.guestsToggle:HookScript("OnEnter", guestsTip)
    p.guestsToggle:HookScript("OnLeave", function() GameTooltip:Hide() end)
    p.sessionBtn = UI:CreateSleekButton(p, "Start raid", 88, 22, function()
        if ns.GroupRules:GetSession() then
            ns.SessionBar:ConfirmEnd()
        else
            ns.SessionBar:OpenStart()
        end
    end)
    p.sessionBtn:SetPoint("TOPRIGHT", -8, -6)
    p.count = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.count:SetPoint("LEFT", p.playersBtn, "RIGHT", 12, 0)
    p.newRaidBtn = UI:CreateSleekButton(p, "New raid", 90, 22, function() ns.RaidPlanUI:OpenEditor() end, "primary")
    p.newTeamBtn = UI:CreateSleekButton(p, "New team", 90, 22, function() ns.RaidPlanUI:NewTeam() end, "primary")
    -- 1.3: the guest book (players outside the guild who raided with us) and the blacklist (players kept out of
    -- every raid), for the GM, officers and the raid leaders
    p.guestsBtn = UI:CreateSleekButton(p, "Guests", 70, 22, function() ns.GuestBookUI:Open() end)
    p.guestsBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Guests")
        GameTooltip:AddLine("The guest book (players outside the guild who raided with us: their raids, a note, "
            .. "recruits) and the raid blacklist.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    p.guestsBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    -- Addendum J §62: who the raid leaders are (everyone can look; the GM edits)
    p.leadersBtn = UI:CreateSleekButton(p, "Raid leaders", 96, 22, function() ns.RaidLeadersUI:Open() end)

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

    p.raidList = UI:CreateScrollList(p, RAID_ROW_H, initRaidRow)
    p.raidList.frame:SetPoint("TOPLEFT", 0, -36)
    p.raidList.frame:SetPoint("BOTTOMLEFT", 0, 4)
    p.raidList.frame:SetWidth(LIST_W)
    p.raidList:SetEmptyText("No raids logged yet.\nThe raid leader starts a session with Start raid (or /dz raid start).")

    p.detail = UI:CreateScrollList(p, ROW_H, initDetailRow, function(d) return d.header and 26 or ROW_H end)
    p.detail.frame:SetPoint("TOPLEFT", LIST_W + 8, -36)
    p.detail.frame:SetPoint("BOTTOMRIGHT", 0, 4)

    -- GM / guild council: delete the selected logged raid (a bin at the top right of its details)
    p.deleteLogBtn = UI:CreateTipIconButton(p.detail.frame, 22, 12, "Delete this raid from the log",
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
    p.deleteLogBtn:SetPoint("TOPRIGHT", -26, -2)
    p.deleteLogBtn:SetFrameLevel(p.detail.frame:GetFrameLevel() + 10)

    p.players = UI:CreateScrollList(p, ROW_H, initDetailRow)
    p.players.frame:SetPoint("TOPLEFT", 0, -36)
    p.players.frame:SetPoint("BOTTOMRIGHT", 0, 4)
    p.players:SetEmptyText("No raids logged yet.")

    p:SetScript("OnShow", function() RaidsUI:Refresh() end)
    function p:OnPanelShown() RaidsUI:Refresh() end
    C_Timer.After(0, function() RaidsUI:Refresh() end)
    return p
end

function RaidsUI:Refresh()
    if not panel or not panel:IsVisible() then return end
    updateToolbar(panel)
    local log = state.view == "log"
    panel.upcoming:SetShown(state.view == "upcoming")
    panel.teams:SetShown(state.view == "teams")
    panel.strategies:SetShown(state.view == "strategies")
    local raidsMode = state.mode == "raids"
    panel.raidList.frame:SetShown(log and raidsMode)
    panel.detail.frame:SetShown(log and raidsMode)
    panel.players.frame:SetShown(log and not raidsMode)
    if state.view == "strategies" then
        ns.StrategiesUI:RefreshLibrary()
    elseif not log then
        ns.RaidPlanUI:Refresh()
    elseif raidsMode then
        local raids = RL():GetRaids()
        local found = false
        for _, rec in ipairs(raids) do
            if rec.id == state.selected then found = true end
        end
        if not found then state.selected = raids[1] and raids[1].id or nil end
        local rows = {}
        for _, rec in ipairs(raids) do rows[#rows + 1] = { rec = rec } end
        panel.raidList:SetData(rows)
        local sel = state.selected and RL():GetRaid(state.selected)
        panel.detail:SetData(sel and detailRows(sel) or {})
        panel.deleteLogBtn:SetShown(sel ~= nil and sel.stop ~= nil and RL():CanDelete())
        panel.count:SetText(#raids == 1 and "1 raid" or (#raids .. " raids"))
    else
        local rows, total = playerRows()
        panel.players:SetData(#rows > 1 and rows or {})
        panel.count:SetText(total .. " logged")
    end
end

function RaidsUI:RequestRefresh()
    if panel and panel:IsVisible() then ns.Util.Debounce("raids-ui", 0.2, function() RaidsUI:Refresh() end) end
end

-- For tests / other modules: selects a logged raid (and the Raid log's Raids mode).
function RaidsUI:Select(id)
    state.view, state.mode, state.selected = "log", "raids", id
    self:Refresh()
end

function RaidsUI:SetMode(mode, range)
    state.view = "log"
    state.mode = mode == "players" and "players" or "raids"
    if range then state.range = range end
    self:Refresh()
end

-- "upcoming" | "teams" | "strategies" | "log" (the log is council only).
function RaidsUI:SetView(view)
    if view ~= "teams" and view ~= "log" and view ~= "strategies" then view = "upcoming" end
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
                           "DEMO_TOGGLED", "CONFIG_UPDATED" }) do
        ns:On(msg, refresh)
    end
    ns:RegisterSlash("raids", function()
        state.view = "upcoming"
        ns.MainFrame:Open("raids")
        RaidsUI:Refresh()
    end, "open the Raids tab: upcoming raids and sign-ups")
end
