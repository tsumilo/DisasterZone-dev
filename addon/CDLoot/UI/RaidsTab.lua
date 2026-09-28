-- CDLoot: "Raids" tab (Addendum I §51): the raid log. Two views:
--   Raids   - the raid sessions (newest first) and, for the selected one, its boss timeline, attendance (with
--             bench marks, right-click to change) and the awards made during it.
--   Players - attendance % / boss kills / items received per player over the last N raids.
-- Council only (like the Loot Log). Start / End raid for the raid's authority sits in the toolbar.
local addonName, ns = ...

local RaidsUI = ns:NewModule("RaidsUI")

local LIST_W = 290
local RAID_ROW_H = 34
local ROW_H = 20
local RANGES = { 4, 8, 12, 0 }   -- 0 = all raids

local state = { mode = "raids", selected = nil, range = 8 }
local panel

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function grey(text) return "|cff808080" .. tostring(text) .. "|r" end

local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

local function colored(key, classFile)
    return ns.UI:ColoredName(key, classFile or (ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)))
end

local function duration(sec)
    sec = math.floor(math.max(0, sec or 0))
    return ("%d:%02d"):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end

local function fmtTime(ts, fmt) return ts and date(fmt or "%H:%M", ts) or "-" end

local function RL() return ns.RaidLog end

local function rangeLabel(n) return n == 0 and "All raids" or ("Last " .. n .. " raids") end

local function raidSummary(rec)
    local kills = #(rec.bosses or {})
    local total = RL():GetBossTotal(rec.instID)
    local parts = {
        duration((rec.stop or GetServerTime()) - (rec.start or 0)),
        total and ("%d/%d bosses"):format(kills, total) or (kills .. " bosses"),
        ns.Util.Count(rec.att or {}) .. " raiders",
        #RL():GetAwards(rec) .. " items",
    }
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
        if d.header and i == 1 then fs:SetWidth(460) elseif i == 1 then fs:SetWidth(COLS[2] - COLS[1] - 4) end
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
    add({ "Started " .. fmtTime(rec.start) .. " by " .. by .. "  ·  ended " .. ended })
    add({ raidSummary(rec) })

    add({ "Bosses" }, { header = true })
    local nBoss = #(rec.bosses or {})
    if nBoss == 0 then add({ grey("No boss kills logged.") }) end
    for _, b in ipairs(rec.bosses or {}) do
        local off = 0
        for _ in pairs(b.off or {}) do off = off + 1 end
        add({ fmtTime(b.ts), b.name or ("Encounter " .. tostring(b.enc)),
            b.roster and (#b.roster .. " in raid") or "", off > 0 and ("|cffff8080" .. off .. " offline|r") or "" })
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

    add({ "Awards" }, { header = true })
    local awards = RL():GetAwards(rec)
    if #awards == 0 then add({ grey("No awards during this raid.") }) end
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
        local last = s.lastItem and (s.items .. "  " .. ns.UI:ItemText(s.lastItem.i)) or tostring(s.items)
        rows[#rows + 1] = { cols = { colored(s.key, s.class), ("%d/%d"):format(s.raids, total) ..
            (s.bench > 0 and grey(" (" .. s.bench .. " bench)") or ""), s.pct .. "%",
            ("%d/%d"):format(s.kills, s.killTotal), last }, itemID = s.lastItem and s.lastItem.i }
    end
    return rows, total
end

----------------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------------

local function updateToolbar(p)
    p.raidsBtn:SetEnabled(state.mode ~= "raids")
    p.playersBtn:SetEnabled(state.mode ~= "players")
    p.rangeBtn:SetShown(state.mode == "players")
    p.rangeBtn:SetText(rangeLabel(state.range))
    local GR = ns.GroupRules
    local auth = IsInRaid() and GR and GR:IsAuthority()
    p.sessionBtn:SetShown(auth and true or false)
    p.sessionBtn:SetText(GR and GR:GetSession() and "End raid" or "Start raid")
end

function RaidsUI:CreatePanel(parent)
    if panel then return panel end
    local UI = ns.UI
    local p = CreateFrame("Frame", "CDLootRaidsPanel", parent)
    p:SetAllPoints(parent)
    panel = p

    p.raidsBtn = UI:CreateButton(p, "Raids", 80, 22, function() state.mode = "raids"; RaidsUI:Refresh() end)
    p.raidsBtn:SetPoint("TOPLEFT", 8, -6)
    p.playersBtn = UI:CreateButton(p, "Players", 80, 22, function() state.mode = "players"; RaidsUI:Refresh() end)
    p.playersBtn:SetPoint("LEFT", p.raidsBtn, "RIGHT", 4, 0)
    p.rangeBtn = UI:CreateMenuButton(p, rangeLabel(state.range), 120, function(root)
        for _, n in ipairs(RANGES) do
            root:CreateButton(rangeLabel(n), function()
                state.range = n
                RaidsUI:Refresh()
            end)
        end
    end)
    p.rangeBtn:SetPoint("LEFT", p.playersBtn, "RIGHT", 12, 0)
    p.sessionBtn = UI:CreateButton(p, "Start raid", 100, 22, function()
        if ns.GroupRules:GetSession() then
            ns.SessionBar:ConfirmEnd()
        else
            ns.RaidLog:Start()
        end
    end)
    p.sessionBtn:SetPoint("TOPRIGHT", -8, -6)
    p.count = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.count:SetPoint("RIGHT", p.sessionBtn, "LEFT", -12, 0)

    p.raidList = UI:CreateScrollList(p, RAID_ROW_H, initRaidRow)
    p.raidList.frame:SetPoint("TOPLEFT", 0, -36)
    p.raidList.frame:SetPoint("BOTTOMLEFT", 0, 4)
    p.raidList.frame:SetWidth(LIST_W)
    p.raidList:SetEmptyText("No raids logged yet.\nThe raid leader starts a session with Start raid (or /cdl raid start).")

    p.detail = UI:CreateScrollList(p, ROW_H, initDetailRow, function(d) return d.header and 26 or ROW_H end)
    p.detail.frame:SetPoint("TOPLEFT", LIST_W + 8, -36)
    p.detail.frame:SetPoint("BOTTOMRIGHT", 0, 4)

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
    local raidsMode = state.mode == "raids"
    panel.raidList.frame:SetShown(raidsMode)
    panel.detail.frame:SetShown(raidsMode)
    panel.players.frame:SetShown(not raidsMode)
    if raidsMode then
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
        panel.count:SetText(#raids == 1 and "1 raid" or (#raids .. " raids"))
    else
        local rows, total = playerRows()
        panel.players:SetData(#rows > 1 and rows or {})
        panel.count:SetText(rangeLabel(state.range) .. ": " .. total .. " logged")
    end
end

function RaidsUI:RequestRefresh()
    if panel and panel:IsVisible() then ns.Util.Debounce("raids-ui", 0.2, function() RaidsUI:Refresh() end) end
end

-- For tests / other modules: selects a raid (and the Raids view).
function RaidsUI:Select(id)
    state.mode, state.selected = "raids", id
    self:Refresh()
end

function RaidsUI:SetMode(mode, range)
    state.mode = mode == "players" and "players" or "raids"
    if range then state.range = range end
    self:Refresh()
end

function RaidsUI:GetPanel() return panel end

function RaidsUI:IsAvailable()
    local council = ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil()
    local demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    return (council or demo) and true or false
end

function RaidsUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("raids", "Raids", 3.5,
            function(parent) return RaidsUI:CreatePanel(parent) end,
            function() return RaidsUI:IsAvailable() end)
    end
    local function refresh() RaidsUI:RequestRefresh() end
    for _, msg in ipairs({ "RAIDLOG_CHANGED", "LEDGER_UPDATED", "GROUP_RULES_CHANGED", "ROSTER_UPDATED", "ITEMINFO_READY", "DEMO_TOGGLED" }) do
        ns:On(msg, refresh)
    end
    ns:RegisterSlash("raids", function() ns.MainFrame:Open("raids") end, "open the raid log (council)")
end
