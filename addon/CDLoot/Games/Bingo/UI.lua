-- CDLoot Games/Bingo/UI.lua
-- ns.BingoUI: the Council Bingo panel (5x5 card, status, start / stop, season leaderboard) and a small
-- movable counter ("Bingo 12/25") shown while a game runs and the main window is closed.
local addonName, ns = ...

local BingoUI = ns:NewModule("BingoUI")
local Util = ns.Util

local CELL_W, CELL_H, GAP = 86, 64, 4
local RARITY_COLOR = {
    c = { 0.85, 0.85, 0.85 },
    r = { 0.35, 0.65, 1.0 },
    l = { 1.0, 0.5, 0.0 },
}

local panel, cells, statusText, startBtn, stopBtn, announceBox, boardText
local mini

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function CreateCell(parent, i)
    local b = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    b:SetSize(CELL_W, CELL_H)
    local row, col = math.floor((i - 1) / 5), (i - 1) % 5
    b:SetPoint("TOPLEFT", col * (CELL_W + GAP), -row * (CELL_H + GAP))
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("TOPLEFT", 4, -4)
    b.text:SetPoint("BOTTOMRIGHT", -4, 4)
    b.text:SetJustifyH("CENTER")
    b.text:SetJustifyV("MIDDLE")
    b.check = b:CreateTexture(nil, "OVERLAY")
    b.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    b.check:SetSize(16, 16)
    b.check:SetPoint("TOPRIGHT", -2, -2)
    b:EnableMouse(true)
    b:SetScript("OnEnter", function(self)
        if self.tip then ns.UI:SetTextTooltip(self, self.tip) end
    end)
    b:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    return b
end

local function SeasonBoard()
    local rows = {}
    for key, r in pairs(ns.Bingo:GetSeason()) do
        rows[#rows + 1] = { key = key, b = r.bingos or 0, f = r.firsts or 0, x = r.blackouts or 0 }
    end
    table.sort(rows, function(a, b)
        if a.b ~= b.b then return a.b > b.b end
        if a.f ~= b.f then return a.f > b.f end
        return a.key < b.key
    end)
    local lines = { "|cffffd100Season leaderboard|r" }
    for i = 1, math.min(#rows, 12) do
        local r = rows[i]
        lines[#lines + 1] = string.format("%d. %s  |cffffffff%d|r%s%s", i, r.key:match("^([^%-]+)") or r.key, r.b,
            r.f > 0 and ("  |cff33ff99" .. r.f .. " first|r") or "",
            r.x > 0 and ("  |cffff8000" .. r.x .. " blackout|r") or "")
    end
    if #rows == 0 then lines[#lines + 1] = "|cff888888No bingos yet.|r" end
    return table.concat(lines, "\n")
end

function BingoUI:Refresh()
    if mini then mini:Update() end
    if not panel or not panel:IsVisible() then return end
    local Bingo = ns.Bingo
    local g = Bingo:GetGame()
    local active = Bingo:IsActive()
    local card = g and Bingo:GetMyCard()
    local _, marked, onLine = 0, 0, {}
    local lines = 0
    if card then lines, marked, onLine = Bingo:GetScore(Util.PlayerKey()) end

    for i = 1, 25 do
        local c = cells[i]
        local id = card and card[i]
        if not id then
            c.text:SetText("")
            c.check:Hide()
            c.tip = nil
            c:SetBackdropColor(0.1, 0.1, 0.1, 0.6)
            c:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        elseif id == ns.BingoSquares.FREE then
            c.text:SetText("|cffff8000Casual\nDisaster|r\n|cff888888FREE|r")
            c.check:Show()
            c.tip = { "Free square", "Everyone starts with the centre." }
            c:SetBackdropColor(0.3, 0.15, 0, 0.8)
            c:SetBackdropBorderColor(1, 0.5, 0, 1)
        else
            local sq = ns.BingoSquares:Get(id)
            local col = RARITY_COLOR[sq.rarity] or RARITY_COLOR.c
            local hit = g.hits[id] ~= nil
            c.text:SetText(sq.text)
            c.text:SetTextColor(hit and 1 or col[1], hit and 1 or col[2], hit and 1 or col[3])
            c.check:SetShown(hit)
            c.tip = { sq.text, hit and ("Marked at " .. date("%H:%M", g.hits[id])) or "Not yet..." }
            if onLine[i] then
                c:SetBackdropColor(0.1, 0.45, 0.1, 0.9)
            elseif hit then
                c:SetBackdropColor(0.15, 0.3, 0.15, 0.8)
            else
                c:SetBackdropColor(0.05, 0.05, 0.05, 0.7)
            end
            c:SetBackdropBorderColor(col[1], col[2], col[3], hit and 1 or 0.5)
        end
    end

    if not g then
        statusText:SetText("No game yet. The raid leader starts one with |cffffd100/cdl bingo start|r.")
    else
        local host = (g.host or "?"):match("^([^%-]+)") or g.host
        local winners = {}
        for _, k in ipairs(g.winners or {}) do winners[#winners + 1] = k:match("^([^%-]+)") or k end
        statusText:SetText(string.format("%s  ·  host %s  ·  %d/25 marked  ·  %d line%s%s",
            active and "|cff33ff99Live|r" or "|cff888888Finished|r", host, marked, lines, lines == 1 and "" or "s",
            #winners > 0 and ("\nBingo: |cffffd100" .. table.concat(winners, ", ") .. "|r") or ""))
    end
    startBtn:SetEnabled(Bingo:CanStart() and not active)
    stopBtn:SetEnabled(active and Bingo:IsHost())
    announceBox:SetChecked(Bingo:GetAnnounce())
    boardText:SetText(SeasonBoard())
end

function BingoUI:CreatePanel(parent)
    panel = CreateFrame("Frame", nil, parent)

    local title = ns.UI:CreateLabel(panel, "Council Bingo", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)

    startBtn = ns.UI:CreateButton(panel, "Start game", 100, 22, function() ns.Bingo:Start() end)
    startBtn:SetPoint("TOPRIGHT", -10, -8)
    stopBtn = ns.UI:CreateButton(panel, "End game", 90, 22, function() ns.Bingo:Stop() end)
    stopBtn:SetPoint("RIGHT", startBtn, "LEFT", -4, 0)

    statusText = ns.UI:CreateLabel(panel, "", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    statusText:SetPoint("RIGHT", -10, 0)

    local grid = CreateFrame("Frame", nil, panel)
    grid:SetSize(5 * CELL_W + 4 * GAP, 5 * CELL_H + 4 * GAP)
    grid:SetPoint("TOPLEFT", 10, -64)
    cells = {}
    for i = 1, 25 do cells[i] = CreateCell(grid, i) end

    boardText = ns.UI:CreateLabel(panel, "", "GameFontHighlightSmall")
    boardText:SetPoint("TOPLEFT", grid, "TOPRIGHT", 12, 0)
    boardText:SetPoint("RIGHT", -8, 0)
    boardText:SetJustifyV("TOP")

    announceBox = ns.UI:CreateCheckbox(panel, "Announce bingos in raid chat (host)",
        function() return ns.Bingo:GetAnnounce() end,
        function(v) ns.Bingo:SetAnnounce(v) end)
    announceBox:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", -4, -6)

    panel:SetScript("OnShow", function() BingoUI:Refresh() end)
    panel.OnGameShown = function() BingoUI:Refresh() end
    return panel
end

---------------------------------------------------------------------------
-- Mini counter
---------------------------------------------------------------------------

local function CreateMini()
    local f = CreateFrame("Button", "CDLootBingoMini", UIParent, "BackdropTemplate")
    f:SetSize(130, 24)
    f:SetPoint("TOP", 0, -120)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(0, 0, 0, 0.7)
    f:SetBackdropBorderColor(1, 0.5, 0, 0.8)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        if point then ns.Games:GetData("bingo").miniPos = { point, relPoint, x, y } end
    end)
    f:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            self.dismissed = true
            self:Hide()
        else
            ns.Games:Open("bingo")
        end
    end)
    f:SetScript("OnEnter", function(self)
        ns.UI:SetTextTooltip(self, { "Council Bingo", "Left-click: open your card", "Right-click: hide until the next game" })
    end)
    f:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.text:SetPoint("CENTER")
    local pos = ns.Games:GetData("bingo").miniPos
    if type(pos) == "table" and type(pos[1]) == "string" then
        f:ClearAllPoints()
        f:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
    end
    -- Follows the main window (hidden while it is open) without forcing it to be created.
    local elapsed = 0
    f.driver = CreateFrame("Frame")
    f.driver:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.5 then return end
        elapsed = 0
        if ns.Bingo:IsActive() then f:Update() elseif f:IsShown() then f:Hide() end
    end)

    function f:Update()
        local Bingo = ns.Bingo
        local main = ns.MainFrame and ns.MainFrame:IsShown()
        if not Bingo:IsActive() or main or self.dismissed then
            self:Hide()
            return
        end
        local lines, marked = Bingo:GetScore(Util.PlayerKey())
        self.text:SetText(string.format("Bingo %d/25%s", marked, lines > 0 and "  |cff33ff99BINGO|r" or ""))
        self:Show()
    end
    f:Hide()
    return f
end

function BingoUI:OnInit()
    ns:On("BINGO_UPDATED", function() BingoUI:Refresh() end)
    ns:On("GAMES_UPDATED", function() BingoUI:Refresh() end)
end

function BingoUI:OnLogin()
    mini = CreateMini()
    local lastGame
    ns:On("BINGO_UPDATED", function()
        local g = ns.Bingo:GetGame()
        if g and g.id ~= lastGame then
            lastGame = g.id
            mini.dismissed = false
        end
    end)
    C_Timer.After(1, function() BingoUI:Refresh() end)
end
