-- CDLoot UI/MainFrame.lua
-- ns.MainFrame: the 800x580 main window, its bottom-tab registry (panels created lazily),
-- the sync status in the title bar, and the minimap / LibDataBroker launcher.
local addonName, ns = ...

local MainFrame = ns:NewModule("MainFrame")

local FRAME_NAME = "CDLootMainFrame"
local WIDTH, HEIGHT = 800, 580

local tabDefs = {}      -- key -> { key, label, order, createFn, isAvailableFn, panel }
local tabList = {}      -- defs sorted by order
local frame, tabs, statusText
local currentKey

---------------------------------------------------------------------------
-- Tab registry (accepts registrations before the frame exists)
---------------------------------------------------------------------------

local function SortTabs()
    table.sort(tabList, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.key < b.key
    end)
end

local function IsAvailable(def)
    if not def then return false end
    if not def.isAvailableFn then return true end
    local ok, result = pcall(def.isAvailableFn)
    if not ok then
        ns:Debug("tab availability check failed for %s: %s", def.key, tostring(result))
        return false
    end
    return result and true or false
end

local function FirstAvailableKey()
    if tabDefs.home and IsAvailable(tabDefs.home) then return "home" end
    if tabDefs.mybis and IsAvailable(tabDefs.mybis) then return "mybis" end
    for _, def in ipairs(tabList) do
        if IsAvailable(def) then return def.key end
    end
    return nil
end

local ShowPanel   -- forward

local function BuildTabs()
    if not frame then return end
    if tabs then
        for _, button in ipairs(tabs.buttons) do button:Hide() end
    end
    local defs = {}
    for i, def in ipairs(tabList) do
        defs[i] = { key = def.key, label = def.label }
    end
    tabs = ns.UI:CreateTabs(frame, defs, function(key) ShowPanel(key) end)
end

function MainFrame:RegisterTab(key, label, order, createFn, isAvailableFn)
    if type(key) ~= "string" then return end
    local def = tabDefs[key]
    if not def then
        def = { key = key }
        tabDefs[key] = def
        tabList[#tabList + 1] = def
    end
    def.label = label or key
    def.order = tonumber(order) or (#tabList * 10)
    def.createFn = createFn
    def.isAvailableFn = isAvailableFn
    SortTabs()
    if frame then
        BuildTabs()
        self:RefreshTabs()
        if currentKey and tabs then tabs:Select(currentKey) end
    end
end

---------------------------------------------------------------------------
-- Title & status
---------------------------------------------------------------------------

local function UpdateTitle()
    if not frame then return end
    local guild = ns.Guild and ns.Guild.GetGuildName and ns.Guild:GetGuildName()
    if not guild or guild == "" then
        guild = IsInGuild() and GetGuildInfo("player") or nil
    end
    if guild and guild ~= "" then
        frame:SetWindowTitle("CDLoot - <" .. guild .. ">")
    else
        frame:SetWindowTitle("CDLoot")
    end
end

local function UpdateStatus()
    if not frame or not statusText then return end
    local text = ns.Sync and ns.Sync.GetStatusText and ns.Sync:GetStatusText() or ""
    if ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() then
        text = "|cffff8000Demo mode|r" .. (text ~= "" and ("  ·  " .. text) or "")
    end
    statusText:SetText(ns.UI:SafeText(text or ""))
end

---------------------------------------------------------------------------
-- Panels
---------------------------------------------------------------------------

ShowPanel = function(key)
    local def = tabDefs[key]
    if not def or not frame then return end
    currentKey = key
    for k, other in pairs(tabDefs) do
        if k ~= key and other.panel then other.panel:Hide() end
    end
    if not def.panel and def.createFn then
        local content = frame.content
        local ok, panel = xpcall(function() return def.createFn(content) end, geterrorhandler())
        if ok and panel then
            def.panel = panel
            panel:ClearAllPoints()
            panel:SetAllPoints(frame.content)
        end
    end
    local panel = def.panel
    if panel then
        panel:Show()
        if panel.OnPanelShown then
            xpcall(function() panel:OnPanelShown() end, geterrorhandler())
        end
    end
end

local function EnsureFrame()
    if frame then return frame end
    local UI = ns.UI
    frame = UI:CreateWindow(FRAME_NAME, "CDLoot", WIDTH, HEIGHT)
    frame:Hide()

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -6)
    statusText:SetWidth(250)
    statusText:SetHeight(14)
    statusText:SetJustifyH("RIGHT")
    statusText:SetWordWrap(false)
    statusText:SetTextColor(0.75, 0.75, 0.75)

    frame:HookScript("OnShow", function()
        if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN) end
        UpdateTitle()
        UpdateStatus()
        MainFrame:RefreshTabs()
    end)
    frame:HookScript("OnHide", function()
        if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_CLOSE then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE) end
        -- "Open on: the tab used last" keeps it across sessions (only then: nothing is saved by default)
        local settings = ns.db and ns.db.settings
        if settings and settings.openOn == "last" and currentKey then settings.lastTab = currentKey end
        -- flush pending list edits so they sync right away
        if ns.BiS and ns.BiS.Commit then ns.BiS:Commit() end
        if ns.Picker and ns.Picker.Close then ns.Picker:Close() end
    end)

    BuildTabs()
    return frame
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function MainFrame:GetFrame()
    return EnsureFrame()
end

function MainFrame:IsShown()
    return frame ~= nil and frame:IsShown()
end

function MainFrame:RefreshTabs()
    if not frame or not tabs then return end
    for _, def in ipairs(tabList) do
        tabs:SetTabShown(def.key, IsAvailable(def))
    end
    if currentKey and not IsAvailable(tabDefs[currentKey]) and frame:IsShown() then
        local fallback = FirstAvailableKey()
        if fallback then tabs:Select(fallback) end
    end
end

-- The tab a plain open lands on (settings.openOn): "home" (default) = the Home dashboard every time, "last" = the
-- tab used last (kept across sessions).
local function DefaultKey()
    local settings = ns.db and ns.db.settings
    if settings and settings.openOn == "last" then
        return currentKey or (type(settings.lastTab) == "string" and settings.lastTab) or "home"
    end
    return "home"
end

function MainFrame:Open(key)
    EnsureFrame()
    self:RefreshTabs()
    key = key or DefaultKey()
    if not tabDefs[key] or not IsAvailable(tabDefs[key]) then
        key = FirstAvailableKey()
    end
    frame:Show()
    frame:Raise()
    if key and tabs then
        tabs:Select(key)
    end
end

function MainFrame:Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:Open()
    end
end

function MainFrame:Close()
    if frame then frame:Hide() end
end

-- Returns the panel for a tab if it has been created (nil otherwise).
function MainFrame:GetPanel(key)
    local def = tabDefs[key]
    return def and def.panel or nil
end

function MainFrame:GetSelectedTab()
    return frame and frame:IsShown() and currentKey or nil
end

---------------------------------------------------------------------------
-- Launcher (LibDataBroker + LibDBIcon, both embedded in CDLoot/Libs)
---------------------------------------------------------------------------

local function LauncherTooltip(tt)
    if not tt or not tt.AddLine then return end
    tt:AddLine("CDLoot", 1, 0.5, 0)
    local council = ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil()
    if council then
        tt:AddLine("Loot Council member", 1, 0.82, 0)
    elseif IsInGuild() then
        tt:AddLine("Raider", 0.8, 0.8, 0.8)
    else
        tt:AddLine("Not in a guild", 0.6, 0.6, 0.6)
    end
    local status = ns.Sync and ns.Sync.GetStatusText and ns.Sync:GetStatusText()
    if status and status ~= "" then
        tt:AddLine(ns.UI:SafeText(status), 1, 1, 1, true)
    end
    tt:AddLine(" ")
    tt:AddLine("Left-click: open  ·  Right-click: settings", 0.6, 0.6, 0.6)
    tt:AddLine("Shift-click: boss drops", 0.6, 0.6, 0.6)
end

local function SetupLauncher()
    if not LibStub then return end
    local ldb = LibStub("LibDataBroker-1.1", true)
    if not ldb then return end
    local obj = ldb:GetDataObjectByName("CDLoot") or ldb:NewDataObject("CDLoot", {
        type = "launcher",
        label = "CDLoot",
        text = "CDLoot",
        icon = "Interface\\Icons\\INV_Misc_Bag_10_Blue",
        OnClick = function(_, button)
            if button == "RightButton" then
                MainFrame:Open("settings")
            elseif IsShiftKeyDown() and ns.DropPanel and ns.DropPanel.ShowHistory then
                ns.DropPanel:ShowHistory()   -- the drop panel (one Escape closes it with the loot window)
            else
                MainFrame:Toggle()
            end
        end,
        OnTooltipShow = LauncherTooltip,
    })
    local icon = LibStub("LibDBIcon-1.0", true)
    if not (obj and icon and ns.db and ns.db.settings) then return end
    if type(ns.db.settings.minimap) ~= "table" then ns.db.settings.minimap = { hide = false } end
    if not icon:IsRegistered("CDLoot") then
        icon:Register("CDLoot", obj, ns.db.settings.minimap)
    end
end

function MainFrame:OnInit() end

function MainFrame:OnLogin()
    SetupLauncher()
end

---------------------------------------------------------------------------
-- Messages & slash commands
---------------------------------------------------------------------------

ns:On("SYNC_STATUS", UpdateStatus)
ns:On("PEERS_UPDATED", UpdateStatus)
ns:On("ROSTER_UPDATED", UpdateTitle)
ns:On("CONFIG_UPDATED", function()
    UpdateTitle()
    MainFrame:RefreshTabs()
end)
ns:On("DEMO_TOGGLED", function()
    UpdateStatus()
    MainFrame:RefreshTabs()
end)

ns:RegisterSlash("bis", function() MainFrame:Open("mybis") end, "open My BiS")
ns:RegisterSlash("council", function() MainFrame:Open("council") end, "open the Loot Council view")
ns:RegisterSlash("log", function() MainFrame:Open("loot") end, "open the Loot Log")
ns:RegisterSlash("settings", function() MainFrame:Open("settings") end, "open the settings")
ns:RegisterSlash("config", function() MainFrame:Open("settings") end, "open the settings")
