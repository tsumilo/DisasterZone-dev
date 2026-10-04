if DisasterZoneBoot and DisasterZoneBoot.Run("Games/HubUI.lua", ...) then return end -- DisasterZone Games/HubUI.lua
-- ns.GamesUI: the "Games" tab. A game list on the left, the selected game's panel on the right
-- (panels are created lazily, once, and kept).
local addonName, ns = ...

local GamesUI = ns:NewModule("GamesUI")

local LIST_WIDTH = 180
local ROW_HEIGHT = 44

local root, listFrame, stage, emptyText
local rows = {}
local panels = {}       -- id -> frame
local selected

local function ShowGame(id)
    local def = ns.Games:Get(id)
    if not def or not stage then return end
    if selected and panels[selected] and selected ~= id then
        local old = panels[selected]
        old:Hide()
        if old.OnGameHidden then pcall(old.OnGameHidden, old) end
    end
    selected = id
    local p = panels[id]
    if not p then
        local ok, frame = xpcall(function() return def.create(stage) end, geterrorhandler())
        if not ok or not frame then return end
        p = frame
        p:ClearAllPoints()
        p:SetAllPoints(stage)
        panels[id] = p
    end
    emptyText:Hide()
    p:Show()
    if p.OnGameShown then xpcall(function() p:OnGameShown() end, geterrorhandler()) end
    for _, row in ipairs(rows) do
        row.highlight:SetShown(row.id == id)
    end
end

local function RefreshList()
    if not listFrame then return end
    local games = ns.Games:GetList()
    for i, def in ipairs(games) do
        local row = rows[i]
        if not row then
            row = CreateFrame("Button", nil, listFrame)
            row:SetSize(LIST_WIDTH - 8, ROW_HEIGHT)
            row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * (ROW_HEIGHT + 2))
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(36, 36)
            row.icon:SetPoint("LEFT", 4, 0)
            row.name = ns.UI:CreateLabel(row, "", "GameFontNormal")
            row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
            row.best = ns.UI:CreateLabel(row, "", "GameFontHighlightSmall")
            row.best:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 2)
            row.highlight = row:CreateTexture(nil, "BACKGROUND")
            row.highlight:SetAllPoints()
            row.highlight:SetColorTexture(1, 0.5, 0, 0.2)
            row.highlight:Hide()
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            row:SetScript("OnClick", function(self) ShowGame(self.id) end)
            -- a link to the game for the chat ("come play"; UI/Share.lua)
            row.share = ns.Share:CreateButton(row, 20, function(self)
                return ns.Share:GameRef(self:GetParent().id)
            end, "Share this game")
            row.share:SetPoint("RIGHT", -4, 0)
            rows[i] = row
        end
        row.id = def.id
        row.icon:SetTexture(def.icon)
        row.name:SetText(def.name)
        local data = ns.Games:GetData(def.id)
        local ok, status = true, nil
        if def.status then ok, status = pcall(def.status) end
        row.best:SetText((ok and status) or (data.best and ("Best: " .. data.best)) or "|cff888888Not played yet|r")
        row:SetScript("OnEnter", function(self)
            ns.UI:SetTextTooltip(self, { def.name, def.desc })
        end)
        row:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
        row:Show()
    end
    for i = #games + 1, #rows do rows[i]:Hide() end
end

function GamesUI:CreatePanel(parent)
    root = CreateFrame("Frame", nil, parent)

    listFrame = ns.UI:CreatePanel(root)
    listFrame:SetPoint("TOPLEFT", 4, -4)
    listFrame:SetPoint("BOTTOMLEFT", 4, 4)
    listFrame:SetWidth(LIST_WIDTH)

    stage = ns.UI:CreatePanel(root)
    stage:SetPoint("TOPLEFT", listFrame, "TOPRIGHT", 4, 0)
    stage:SetPoint("BOTTOMRIGHT", -4, 4)

    emptyText = ns.UI:CreateLabel(stage, "Pick a game on the left.\nAll just for fun, nothing here touches loot.", "GameFontDisable")
    emptyText:SetJustifyH("CENTER")
    emptyText:SetPoint("CENTER")

    root.OnPanelShown = function()
        RefreshList()
        if selected then ShowGame(selected) end
    end
    -- status lines ("2 playing now") change on their own: refresh them every few seconds while the list is shown
    local since = 0
    root:SetScript("OnUpdate", function(_, elapsed)
        since = since + elapsed
        if since >= 3 then
            since = 0
            RefreshList()
        end
    end)
    RefreshList()
    return root
end

function GamesUI:Select(id)
    if root then ShowGame(id) else selected = id end
end

function GamesUI:GetSelected() return selected end

function GamesUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("games", "Games", 3.8,
            function(parent) return GamesUI:CreatePanel(parent) end)
    end
    ns:On("GAMES_UPDATED", RefreshList)
end
