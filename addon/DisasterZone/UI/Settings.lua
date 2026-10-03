if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Settings.lua", ...) then return end -- DisasterZone UI/Settings.lua
-- "Settings" tab (alerts, group loot rules, rolls, tooltips, minimap, view phase, demo, about), the read-only
-- Loot Council summary with an "Edit council…" shortcut to the picker (ADDENDUM E §30), the group-rules
-- status line (ADDENDUM D §27), the raid leader's "Lock BiS lists" control (ADDENDUM F §38) and a Blizzard
-- Settings entry (SPEC §12.10).
local addonName, ns = ...

local SettingsUI = ns:NewModule("SettingsUI")

local _G = _G
local CreateFrame = CreateFrame
local format = string.format
local floor, ceil, max = math.floor, math.ceil, math.max
local ipairs, type, tonumber, tostring = ipairs, type, tonumber, tostring

local CHILD_W = 740
local COL_W = 350
local LEFT_X, RIGHT_X = 10, 384
local ROW_CHECK, ROW_DROPDOWN = 26, 32
local DD_X, DD_W = 150, 190
local MEMBER_ROW_H = 16
local ONLINE_DOT = { 0.25, 0.85, 0.30 }
local OFFLINE_DOT = { 0.45, 0.45, 0.45 }

local FALLBACK_COLORS = {
    obtained = { 0.30, 0.90, 0.40 },
    muted    = { 0.55, 0.55, 0.55 },
    warn     = { 1.00, 0.55, 0.20 },
}

-- GetCouncilSource(me) -> text for the status line.
local SOURCE_TEXT = {
    gm = "Guild Master",
    guild = "guild council list",
    raidleader = "raid leader of this raid",
    raid = "this raid's council",
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Color(key)
    local c = ns.COLORS and ns.COLORS[key]
    return c or FALLBACK_COLORS[key] or FALLBACK_COLORS.muted
end

local function Paint(text, key)
    local c = Color(key)
    return format("|cff%02x%02x%02x%s|r", floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5),
        floor(c[3] * 255 + 0.5), text)
end

local function Get(path, default)
    if ns.db and ns.DB and ns.DB.GetSetting then
        local v = ns.DB:GetSetting(path)
        if v ~= nil then return v end
    end
    return default
end

-- The value in effect: the group's rule for group-rule paths (ADDENDUM D §26), else my own setting.
local function Effective(path, default)
    local DB = ns.DB
    if ns.db and DB then
        local v
        if type(DB.GetEffective) == "function" then
            v = DB:GetEffective(path)
        elseif DB.GetSetting then
            v = DB:GetSetting(path)
        end
        if v ~= nil then return v end
    end
    return default
end

local function Set(path, value)
    if ns.DB and ns.DB.SetSetting then ns.DB:SetSetting(path, value) end
end

-- Checkbox setters may be called as setter(checked) or setter(button, checked).
local function Bool(a, b)
    if type(a) == "table" then a = b end
    return a and true or false
end

-- Dropdown callbacks may pass extra arguments; the first non-table one is the value.
local function Value(a, b)
    if type(a) == "table" then return b end
    return a
end

local function IsCouncil()
    return (ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil()) and true or false
end

local function ShortName(key)
    if type(key) ~= "string" then return "?" end
    if ns.Util and ns.Util.ShortName then return ns.Util.ShortName(key) or key end
    return key
end

-- Class from the guild roster, else from my group (raid members from other guilds).
local function ClassOf(key)
    local cl = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)
    if not cl then
        local g = ns.Util and ns.Util.group
        local e = type(g) == "table" and type(key) == "string" and g[key]
        cl = type(e) == "table" and e.classFile or nil
    end
    return cl
end

local function IsMe(key)
    return (ns.Util and ns.Util.IsMe and ns.Util.IsMe(key)) and true or false
end

local function InGroup()
    return (_G.IsInGroup and _G.IsInGroup()) and true or false
end

-- Dungeon mode (ADDENDUM B §22.1); every core call is guarded (older cores lack it).
local function DungeonModeActive()
    local fn = ns.Util and ns.Util.IsDungeonModeActive
    if type(fn) ~= "function" then return false end
    local ok, active = pcall(fn)
    return (ok and active) and true or false
end

-- Who turned dungeon mode on for my party (DM from the leader / a council member), or nil.
local function DungeonEnabledBy()
    local D = ns.Dungeon
    if type(D) == "table" then
        if type(D.GetEnabledBy) == "function" then
            local ok, key = pcall(D.GetEnabledBy, D)
            if ok and type(key) == "string" and key ~= "" then return key end
        end
        if type(D.groupEnabledBy) == "string" and D.groupEnabledBy ~= "" then return D.groupEnabledBy end
    end
    local fn = ns.Util and ns.Util.GetDungeonEnabledBy
    if type(fn) == "function" then
        local ok, key = pcall(fn)
        if ok and type(key) == "string" and key ~= "" then return key end
    end
    return nil
end

local function ColoredName(key, classFile)
    if ns.UI and ns.UI.ColoredName then return ns.UI:ColoredName(key, classFile or ClassOf(key)) end
    return ShortName(key)
end

local function FormatAgo(ts)
    if ns.Util and ns.Util.FormatAgo then return ns.Util.FormatAgo(ts) end
    return ""
end

local function Put(region, parent, x, y)
    region:ClearAllPoints()
    region:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
end

local function NewFS(parent, font, width, wrap)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(wrap and true or false)
    return fs
end

local function TextHeight(fs)
    local h = fs:GetStringHeight()
    return max(12, tonumber(h) or 12)
end

local function MaxPhase()
    return ns.MAX_PHASE or 5
end

local function PhaseLabel(p)
    local info = ns.PHASE_INFO and ns.PHASE_INFO[p]
    if info and info.raids then return format("P%d · %s", p, info.raids) end
    return "P" .. p
end

local function ViewPhaseOptions()
    local gp = ns.Guild and ns.Guild.GetGuildPhase and ns.Guild:GetGuildPhase()
    local out = { { value = 0, text = format("Follow guild (P%d)", tonumber(gp) or 1) } }
    for p = 1, MaxPhase() do out[#out + 1] = { value = p, text = PhaseLabel(p) } end
    return out
end

-- The guild council's phase (set by the GM), without any group rule on top.
local function GuildCouncilPhase()
    local G = ns.Guild
    if G and type(G.GetCouncilPhase) == "function" then
        return tonumber(G:GetCouncilPhase()) or 1
    end
    if G and type(G.GetGuildCouncil) == "function" then
        local c = G:GetGuildCouncil()
        local p = type(c) == "table" and tonumber(c.phase)
        if p and p >= 1 and p <= MaxPhase() then return floor(p) end
        return 1
    end
    return tonumber(G and G.GetGuildPhase and G:GetGuildPhase()) or 1
end

local function GroupPhaseOptions()
    local out = { { value = 0, text = format("Use guild phase (P%d)", GuildCouncilPhase()) } }
    for p = 1, MaxPhase() do out[#out + 1] = { value = p, text = PhaseLabel(p) } end
    return out
end

local function SetMinimapShown(shown)
    local LS = _G.LibStub
    local icon = LS and LS("LibDBIcon-1.0", true)
    if icon and icon.IsRegistered and icon:IsRegistered("DisasterZone") then
        if shown then icon:Show("DisasterZone") else icon:Hide("DisasterZone") end
    end
end

-- Enables / disables a checkbox or dropdown created here and greys its label.
local function SetControlEnabled(ctrl, on)
    if not ctrl then return end
    on = on and true or false
    if ctrl.SetEnabled then ctrl:SetEnabled(on) end
    local label = ctrl.cdlLabel or ctrl.label
    if label and label.SetTextColor then
        if on then label:SetTextColor(1, 1, 1) else label:SetTextColor(0.5, 0.5, 0.5) end
    end
end

local function AddTooltip(frame, title, text)
    frame:HookScript("OnEnter", function(self)
        _G.GameTooltip:SetOwner(self, "ANCHOR_TOP")
        _G.GameTooltip:AddLine(title, 1, 0.82, 0)
        _G.GameTooltip:AddLine(text, 1, 1, 1, true)
        _G.GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() _G.GameTooltip:Hide() end)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function SettingsUI:OnInit()
    self.refreshers = {}
    self.ruleControls = {}
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("settings", "Settings", 4,
            function(parent) return SettingsUI:CreatePanel(parent) end,
            function() return true end)
    end
    local function changed() SettingsUI:RequestRefresh() end
    for _, msg in ipairs({ "SETTINGS_CHANGED", "CONFIG_UPDATED", "ROSTER_UPDATED", "PEERS_UPDATED",
                           "DEMO_TOGGLED", "SYNC_STATUS", "DUNGEON_MODE_CHANGED", "GROUP_UPDATED",
                           "GROUP_RULES_CHANGED", "BIS_LOCK_CHANGED" }) do
        ns:On(msg, changed)
    end
end

function SettingsUI:OnLogin()
    self:RegisterBlizzardCategory()
end

---------------------------------------------------------------------------
-- Blizzard Settings entry (a canvas that points to the DisasterZone window)
---------------------------------------------------------------------------
local function OpenFromBlizzard()
    local sp = _G.SettingsPanel
    if sp and sp:IsShown() then
        if _G.HideUIPanel then _G.HideUIPanel(sp) else sp:Hide() end
    end
    if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("settings") end
end

function SettingsUI:RegisterBlizzardCategory()
    local S = _G.Settings
    if self.category or not (S and S.RegisterCanvasLayoutCategory and S.RegisterAddOnCategory) then return end
    local canvas = CreateFrame("Frame", "DisasterZoneBlizzardOptions")

    local title = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, -16)
    title:SetText("|cffff8000Disaster|rZone")
    local ver = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ver:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
    ver:SetText("v" .. tostring(ns.version or "?")
        .. ((ns.Boot and ns.Boot.applied and (ns.Boot.applied.files or 0) > 0)
            and (" (in-game update on " .. tostring(ns.diskVersion) .. ")") or ""))

    local desc = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    desc:SetWidth(560)
    desc:SetJustifyH("LEFT")
    desc:SetText("BiS lists, the Loot Council overview and boss-drop alerts for <Casual Disaster>.\n"
        .. "All options live in the DisasterZone window. Slash commands: /dz, /dz settings, /dz help.")

    local btn = ns.UI and ns.UI.CreateButton and ns.UI:CreateButton(canvas, "Open DisasterZone settings", 200, 26, OpenFromBlizzard)
    if btn then btn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16) end

    local cat = S.RegisterCanvasLayoutCategory(canvas, "DisasterZone")
    S.RegisterAddOnCategory(cat)
    self.category = cat
end

---------------------------------------------------------------------------
-- Panel construction
---------------------------------------------------------------------------
function SettingsUI:NewColumn(parent, x, width)
    return { parent = parent, x = x, w = width, y = -4 }
end

function SettingsUI:Header(col, text)
    col.y = col.y - 8
    local fs = col.parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", col.parent, "TOPLEFT", col.x, col.y)
    fs:SetText(text)
    local line = col.parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetHeight(1)
    line:SetWidth(col.w)
    line:SetPoint("TOPLEFT", col.parent, "TOPLEFT", col.x, col.y - 16)
    col.y = col.y - 22
    return fs
end

function SettingsUI:Note(col, text)
    local fs = NewFS(col.parent, "GameFontDisableSmall", col.w - 8, true)
    fs:SetPoint("TOPLEFT", col.parent, "TOPLEFT", col.x + 4, col.y)
    fs:SetText(text)
    col.y = col.y - (TextHeight(fs) + 6)
    return fs
end

function SettingsUI:Check(col, label, getter, setter)
    local cb = ns.UI:CreateCheckbox(col.parent, label, getter, setter)
    cb:SetPoint("TOPLEFT", col.parent, "TOPLEFT", col.x, col.y)
    col.y = col.y - ROW_CHECK
    self.refreshers[#self.refreshers + 1] = cb
    return cb
end

function SettingsUI:CheckSetting(col, label, path, default)
    return self:Check(col, label,
        function() return Get(path, default) and true or false end,
        function(a, b) Set(path, Bool(a, b)) end)
end

function SettingsUI:Dropdown(col, label, getOptions, getSelected, onSelect)
    local fs = NewFS(col.parent, "GameFontHighlightSmall", DD_X - 8, false)
    fs:SetPoint("TOPLEFT", col.parent, "TOPLEFT", col.x + 4, col.y - 7)
    fs:SetText(label)
    local dd = ns.UI:CreateDropdown(col.parent, DD_W, getOptions, getSelected, onSelect)
    dd:SetPoint("TOPLEFT", col.parent, "TOPLEFT", col.x + DD_X, col.y)
    dd.cdlLabel = fs
    col.y = col.y - ROW_DROPDOWN
    self.refreshers[#self.refreshers + 1] = dd
    return dd
end

function SettingsUI:DropdownSetting(col, label, path, default, options)
    return self:Dropdown(col, label,
        function() return options end,
        function() return Get(path, default) end,
        function(a, b) Set(path, Value(a, b)) end)
end

-- A group-rule dropdown (ADDENDUM D §26/§27): shows the value in effect, writes my own setting, and is
-- disabled while the rules come from the group's loot leader.
function SettingsUI:RuleDropdown(col, label, path, default, options)
    local dd = self:Dropdown(col, label,
        function() return options end,
        function() return Effective(path, default) end,
        function(a, b)
            if SettingsUI:GroupRulesEditable() then Set(path, Value(a, b)) end
        end)
    self.ruleControls[#self.ruleControls + 1] = dd
    return dd
end

function SettingsUI:CreatePanel(parent)
    if self.panel then return self.panel end
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints(parent)
    panel.dirty = true
    self.panel = panel

    local scroll = CreateFrame("ScrollFrame", "DisasterZoneSettingsScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 4)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CHILD_W, 600)
    scroll:SetScrollChild(child)
    scroll:HookScript("OnSizeChanged", function(_, w)
        if w and w > 100 then child:SetWidth(w) end
    end)
    self.scroll, self.child = scroll, child

    self:BuildLeft(child)
    self:BuildCouncil(child)

    panel:SetScript("OnShow", function(p)
        if p.dirty then SettingsUI:Refresh() end
    end)
    function panel:OnPanelShown()
        SettingsUI:Refresh()
    end
    self:Refresh()
    return panel
end

function SettingsUI:BuildLeft(parent)
    local col = self:NewColumn(parent, LEFT_X, COL_W)

    self:Header(col, "Alerts")
    self:CheckSetting(col, "Boss drop panel (Loot Council)", "alerts.councilPanel", true)
    self:CheckSetting(col, "\"On your BiS list!\" toast", "alerts.personalToast", true)
    self:CheckSetting(col, "Play a sound with drop alerts", "alerts.sound", true)
    self:CheckSetting(col, "Glow loot buttons for your BiS items", "alerts.glow", true)
    self:CheckSetting(col, "Chat message when your BiS item drops", "alerts.chat", true)
    self:CheckSetting(col, "BiS badges on the loot window", "alerts.lootBadges", true)
    self:CheckSetting(col, "Alerts for off-spec list items", "alerts.offspec", true)
    self:DropdownSetting(col, "Drop panel position", "dropPanelMode", "auto", {
        { value = "auto", text = "Attach to loot window when open" },
        { value = "floating", text = "Always floating" },
    })
    self:DropdownSetting(col, "Announce channel", "announceChannel", "RAID", {
        { value = "RAID", text = "Raid" },
        { value = "RAID_WARNING", text = "Raid Warning" },
    })

    self:BuildGroupRules(col, parent)

    self:Header(col, "Rolls")
    self:CheckSetting(col, "Announce rolls and winners in raid chat", "roll.announce", true)
    self:CheckSetting(col, "Show the Roll / Pass popup", "roll.popup", true)
    self:Note(col, "Everyone in the raid may roll. DisasterZone suggests the winner: BiS main first, then BiS alt, "
        .. "then everyone else; the highest roll wins within each group. The council confirms. "
        .. "Start rolls from the boss drop panel (Roll / Roll all) or with /dz roll [item].")

    self:Header(col, "Strategy boards")
    self:CheckSetting(col, "Auto-mark the planned mobs when I lead the raid", "strategy.autoMark", true)
    self:CheckSetting(col, "Show my jobs when I'm near a planned boss", "strategy.reminder", true)
    self:Note(col, "The marks are the raid mark badges on the board's boss portraits; enemy nameplates must be on "
        .. "for the leader. /dz strat debug prints what the helpers see.")

    self:Header(col, "Tooltips")
    self:CheckSetting(col, "Show DisasterZone lines on item tooltips", "tooltip.enabled", true)
    self:CheckSetting(col, "Council: list who wants the item", "tooltip.council", true)
    local nameOptions = {}
    for _, n in ipairs({ 3, 5, 8, 12 }) do nameOptions[#nameOptions + 1] = { value = n, text = tostring(n) } end
    self:DropdownSetting(col, "Names shown", "tooltip.maxNames", 5, nameOptions)
    self:Note(col, "Hold Shift over an item to show every name.")

    self:Header(col, "Main window")
    self:DropdownSetting(col, "Open on", "openOn", "home", {
        { value = "home", text = "Home (dashboard)" },
        { value = "last", text = "The tab used last" },
    })

    self:Header(col, "Minimap button")
    self:Check(col, "Show the minimap button",
        function() return not Get("minimap.hide", false) end,
        function(a, b)
            local shown = Bool(a, b)
            Set("minimap.hide", not shown)
            SetMinimapShown(shown)
        end)

    self:Header(col, "View phase")
    self:Note(col, "The phase used by the Council views, tooltips and drop alerts.")
    self:Dropdown(col, "Phase", ViewPhaseOptions,
        function() return tonumber(Get("viewPhase", nil)) or 0 end,
        function(a, b)
            local v = tonumber(Value(a, b))
            Set("viewPhase", (v and v >= 1 and v <= MaxPhase()) and v or nil)
        end)

    self:Header(col, "Demo mode")
    self:Check(col, "Demo data (fake guild members & raid)",
        function() return (ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()) and true or false end,
        function(a, b)
            if ns.Demo and ns.Demo.SetEnabled then ns.Demo:SetEnabled(Bool(a, b)) end
        end)
    self:Note(col, "Try the council views solo. Demo data is never saved or sent.")
    local sim = ns.UI:CreateButton(parent, "Simulate a boss drop", 160, 22, function()
        if ns.Loot and ns.Loot.SimulateDrop then ns.Loot:SimulateDrop() end
    end)
    Put(sim, parent, col.x + 4, col.y)
    local recent = ns.UI:CreateButton(parent, "Recent drops", 120, 22, function()
        if ns.DropPanel and ns.DropPanel.ShowHistory then ns.DropPanel:ShowHistory() end
    end)
    recent:SetPoint("LEFT", sim, "RIGHT", 6, 0)
    col.y = col.y - 30
    local demoRoll = ns.UI:CreateButton(parent, "Demo a roll", 160, 22, function() SettingsUI:DemoRoll() end)
    Put(demoRoll, parent, col.x + 4, col.y)
    AddTooltip(demoRoll, "Demo a roll", "Turns on demo mode, simulates a boss drop and starts a roll on its first item: "
        .. "you get the Roll / Pass popup and fake raiders roll in the drop panel. Nothing is sent.")
    col.y = col.y - 28
    self:Note(col, "In demo mode, click Roll on any item of the drop panel to watch a roll.")

    self:Header(col, "About")
    self.aboutText = NewFS(parent, "GameFontHighlightSmall", col.w - 8, true)
    Put(self.aboutText, parent, col.x + 4, col.y)
    col.y = col.y - 80
    local syncBtn = ns.UI:CreateButton(parent, "Request sync", 120, 22, function()
        if ns.Sync and ns.Sync.RequestSync then ns.Sync:RequestSync() end
    end)
    Put(syncBtn, parent, col.x + 4, col.y)
    col.y = col.y - 30
    self:CheckSetting(col, "Debug messages in chat", "debug", false)

    self.leftHeight = -col.y + 10
end

-- Group loot rules (ADDENDUM D §24-§27, ADDENDUM E §32): the loot leader of the group decides these for
-- everyone in it. A status line says whose values are in effect; the controls are read-only while the
-- rules come from someone else.
function SettingsUI:BuildGroupRules(col, parent)
    self:Header(col, "Group loot rules")
    self.rulesStatus = NewFS(parent, "GameFontHighlightSmall", col.w - 8, true)
    Put(self.rulesStatus, parent, col.x + 4, col.y)
    col.y = col.y - 30

    -- ADDENDUM F §38: the raid leader locks / unlocks every BiS list in the group for the raid.
    if ns.UI.CreateBiSLockButton then
        self.lockBtn = ns.UI:CreateBiSLockButton(parent, 130, 22, { keepShown = true })
        Put(self.lockBtn, parent, col.x + 4, col.y)
        self.lockStatus = NewFS(parent, "GameFontHighlightSmall", col.w - 150, false)
        self.lockStatus:SetPoint("LEFT", self.lockBtn, "RIGHT", 8, 0)
        col.y = col.y - 30
    end

    local durations = {}
    for _, s in ipairs({ 15, 20, 30, 45, 60 }) do durations[#durations + 1] = { value = s, text = s .. " seconds" } end
    self:RuleDropdown(col, "Roll duration", "roll.duration", 30, durations)
    self:RuleDropdown(col, "Minimum quality", "qualityThreshold", 4, {
        { value = 4, text = "Epic" },
        { value = 3, text = "Rare" },
    })
    self.dungeonCheck = self:Check(col, "Enable dungeon mode (5-man parties)",
        function() return Effective("dungeon.enabled", false) and true or false end,
        function(a, b)
            if SettingsUI:GroupRulesEditable() then
                SettingsUI:SetDungeonMode(Bool(a, b))
            else
                SettingsUI:RequestRefresh()
            end
        end)
    self.ruleControls[#self.ruleControls + 1] = self.dungeonCheck
    self:RuleDropdown(col, "Dungeon min. quality", "dungeon.quality", 3, {
        { value = 3, text = "Rare" },
        { value = 4, text = "Epic" },
    })
    self.phaseRuleDD = self:Dropdown(col, "Raid phase", GroupPhaseOptions,
        function() return SettingsUI:GroupPhaseSelected() end,
        function(a, b)
            if not SettingsUI:GroupPhaseEditable() then return end
            local v = tonumber(Value(a, b))
            Set("groupPhase", (v and v >= 1 and v <= MaxPhase()) and v or nil)
        end)
    AddTooltip(self.phaseRuleDD, "Raid phase",
        "The phase your group is working on. As the group's loot leader you send it with the loot rules: "
        .. "everyone's council views, tooltips and drop alerts follow it (unless they picked their own view phase). "
        .. "\"Use guild phase\" keeps the Guild Master's phase.")

    self.dungeonStatus = NewFS(parent, "GameFontHighlightSmall", col.w - 8, false)
    Put(self.dungeonStatus, parent, col.x + 4, col.y)
    col.y = col.y - 18
    self:Note(col, "The group's loot leader sets these for everyone in the group: in a raid the raid leader "
        .. "(else the master looter); in a party the leader if on the Loot Council or if they turned dungeon mode on "
        .. "(else a council member). Without one, your own values apply. /dz rules shows the rules in effect.")
    self:Note(col, "Lock BiS lists (also /dz lock and /dz unlock): nobody in the group can change their BiS "
        .. "list until the loot leader unlocks them or the group disbands; obtained items still update.")
    self:Note(col, "Dungeon mode: boss drops and DisasterZone rolls work in a 5-man party like in a raid "
        .. "(also /dz dungeon on|off). Dungeon awards are tagged (dungeon) in the loot log.")
end

-- "Demo a roll": demo mode on, a simulated drop, and a local roll on its first item.
function SettingsUI:DemoRoll()
    local D = ns.Demo
    if not (D and D.IsEnabled and D.SetEnabled) then return end
    if not D:IsEnabled() then D:SetEnabled(true) end
    if not D:IsEnabled() then return end   -- SetEnabled printed why
    local R = ns.Roll
    if not (R and type(R.Start) == "function") then
        ns:Print("Rolls are not available.")
        return
    end
    local L = ns.Loot
    if not (L and L.SimulateDrop and L.GetHistory) then return end
    L:SimulateDrop()
    local hist = L:GetHistory()
    local drop = type(hist) == "table" and hist[#hist]
    if type(drop) ~= "table" or not drop.test or type(drop.i) ~= "table" or not tonumber(drop.i[1]) then return end
    local ok, err = pcall(R.Start, R, tonumber(drop.i[1]), drop)
    if not ok then
        ns:Debug("Roll:Start failed: %s", tostring(err))
        local handler = _G.geterrorhandler and _G.geterrorhandler()
        if handler then handler(err) end
    end
end

-- The dungeon mode checkbox: through the core's toggle when it has one (it also tells the party),
-- else the plain setting (the core reacts to SETTINGS_CHANGED "dungeon.enabled").
function SettingsUI:SetDungeonMode(enabled)
    enabled = enabled and true or false
    local D = ns.Dungeon
    if type(D) == "table" and type(D.SetEnabled) == "function" then
        local ok, err = pcall(D.SetEnabled, D, enabled)
        if ok then
            self:RequestRefresh()
            return
        end
        local handler = _G.geterrorhandler and _G.geterrorhandler()
        if handler then handler(err) end
    end
    Set("dungeon.enabled", enabled)
end

-- "Active — enabled by X" / "Inactive (not in a 5-man party)".
function SettingsUI:DungeonStatusText()
    if DungeonModeActive() then
        local who, extra = nil, ""
        local by = DungeonEnabledBy()
        local rulesStatus, rulesFrom = self:GroupRulesStatus()
        if rulesStatus == "remote" and Effective("dungeon.enabled", false) then
            who = rulesFrom and ShortName(rulesFrom) or nil
        elseif Get("dungeon.enabled", false) then
            who = "you"
            -- only my client uses it unless I may tell the party (leader / council) or someone did
            local D = ns.Dungeon
            if not by and rulesStatus ~= "mine" and type(D) == "table" and type(D.CanTellParty) == "function" then
                local ok, can = pcall(D.CanTellParty, D)
                if ok and not can then extra = Paint(" (only for you)", "muted") end
            end
        elseif by then
            who = IsMe(by) and "you" or ShortName(by)
        end
        return "Status: " .. Paint(who and ("Active — enabled by " .. who) or "Active", "obtained") .. extra
    end
    local reason
    if _G.IsInRaid and _G.IsInRaid() then
        reason = "Inactive (in a raid: raid rules apply)"
    elseif not InGroup() then
        reason = "Inactive (not in a 5-man party)"
    else
        reason = "Inactive (not turned on for this party)"
    end
    return "Status: " .. Paint(reason, "muted")
end

function SettingsUI:RefreshDungeon()
    local fs = self.dungeonStatus
    if fs then fs:SetText(self:DungeonStatusText()) end
end

---------------------------------------------------------------------------
-- Group loot rules status (ADDENDUM D §27)
---------------------------------------------------------------------------

-- "own" | "mine" | "remote", plus the key of the loot leader whose rules are in effect.
function SettingsUI:GroupRulesStatus()
    local GR = ns.GroupRules
    if type(GR) ~= "table" or type(GR.GetStatus) ~= "function" then return "own", nil end
    local status, from = GR:GetStatus()
    if status ~= "mine" and status ~= "remote" then return "own", nil end
    if status == "remote" and type(from) ~= "string" and type(GR.GetActive) == "function" then
        local active = GR:GetActive()
        from = type(active) == "table" and type(active.from) == "string" and active.from or nil
    end
    return status, from
end

function SettingsUI:GroupRulesEditable()
    return (self:GroupRulesStatus()) ~= "remote"
end

-- The raid phase is sent by the loot leader: editable when I am it, or out of a group (prepared for later).
function SettingsUI:GroupPhaseEditable()
    local status = self:GroupRulesStatus()
    return status == "mine" or (status == "own" and not InGroup())
end

function SettingsUI:GroupPhaseSelected()
    local status = self:GroupRulesStatus()
    if status == "remote" then
        local GR = ns.GroupRules
        local active = type(GR.GetActive) == "function" and GR:GetActive()
        local values = type(active) == "table" and active.values
        local ph = type(values) == "table" and tonumber(values.ph)
        return (ph and ph >= 1 and ph <= MaxPhase()) and ph or 0
    end
    local v = tonumber(Get("groupPhase", nil))
    return (v and v >= 1 and v <= MaxPhase()) and v or 0
end

function SettingsUI:GroupRulesStatusText()
    local status, from = self:GroupRulesStatus()
    if status == "remote" then
        return "Set by " .. (from and ColoredName(from) or "the group's loot leader") .. " for this group"
            .. Paint(" (read-only while you are in this group)", "muted")
    elseif status == "mine" then
        return Paint("You set these for your group", "obtained")
            .. Paint(" (changes are sent to the group)", "muted")
    end
    if InGroup() then
        return "Your own settings" .. Paint(" (no loot leader with DisasterZone in this group)", "muted")
    end
    return "Your own settings" .. Paint(" (not in a group)", "muted")
end

-- "BiS lists: unlocked" / "Locked by X (since 20:14)" next to the lock button (ADDENDUM F §38).
function SettingsUI:LockStatusText()
    local UI = ns.UI
    if not (UI and UI.GetBiSLock) then return "" end
    local locked, info = UI:GetBiSLock()
    if locked then
        return UI:LockIcon(12) .. " " .. Paint("Locked by " .. UI:LockByText(info, true), "warn")
    end
    if not (_G.IsInRaid and _G.IsInRaid()) then return "BiS lists: unlocked" .. Paint(" (raids only)", "muted") end
    if UI.CanSetBiSLock and UI:CanSetBiSLock() then return "BiS lists: unlocked" end
    return "BiS lists: unlocked" .. Paint(" (raid leader only)", "muted")
end

function SettingsUI:RefreshGroupRules()
    if self.rulesStatus then self.rulesStatus:SetText(self:GroupRulesStatusText()) end
    local editable = self:GroupRulesEditable()
    for _, ctrl in ipairs(self.ruleControls or {}) do SetControlEnabled(ctrl, editable) end
    SetControlEnabled(self.phaseRuleDD, self:GroupPhaseEditable())
    if self.lockBtn and self.lockBtn.Refresh then self.lockBtn:Refresh() end
    if self.lockStatus then self.lockStatus:SetText(self:LockStatusText()) end
end

function SettingsUI:RefreshAbout()
    local fs = self.aboutText
    if not fs then return end
    local S = ns.Sync
    local peers = S and S.GetVersions and S:GetVersions()
    local online = S and S.GetOnlineCouncilPeers and S:GetOnlineCouncilPeers()
    local status = (S and S.GetStatusText and S:GetStatusText()) or ""
    fs:SetText(format("Version %s · protocol %s\nPeers seen: %d · council online: %d\nSharing: %s\n%s",
        tostring(ns.version or "?"), tostring(ns.PROTO or "?"),
        type(peers) == "table" and #peers or 0, type(online) == "table" and #online or 0,
        tostring(status),
        Paint("Standalone: all libraries and the suggested BiS lists are built in.", "muted")))
end

---------------------------------------------------------------------------
-- Loot Council section: read-only summary for everyone + "Edit council…" (ADDENDUM E §30)
---------------------------------------------------------------------------
local function MemberOnEnter(self)
    if not self.key then return end
    local tt = _G.GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    tt:AddLine(ColoredName(self.key))
    local G = ns.Guild
    local rank = G and G.GetRankName and G:GetRankName(self.key)
    if rank then tt:AddLine(rank, 0.8, 0.8, 0.8) end
    tt:AddLine(self.online and "Online" or "Offline", 0.6, 0.6, 0.6)
    if self.fixed then tt:AddLine(self.fixed .. ": always on the council", 0.6, 0.6, 0.6, true) end
    tt:Show()
end

local function NewMemberEntry(parent)
    local e = CreateFrame("Frame", nil, parent)
    e:SetHeight(MEMBER_ROW_H)
    e.dot = e:CreateTexture(nil, "ARTWORK")
    e.dot:SetSize(7, 7)
    e.dot:SetPoint("LEFT", e, "LEFT", 0, 0)
    e.text = NewFS(e, "GameFontHighlightSmall", nil, false)
    e.text:SetPoint("LEFT", e, "LEFT", 11, 0)
    e.text:SetPoint("RIGHT", e, "RIGHT", 0, 0)
    e:EnableMouse(true)
    e:SetScript("OnEnter", MemberOnEnter)
    e:SetScript("OnLeave", function() _G.GameTooltip:Hide() end)
    return e
end

-- Lays out a 2-column grid of name entries from `pool`; returns the new y.
local function LayoutMembers(cs, pool, list, y)
    local colW = floor(COL_W / 2)
    for i, m in ipairs(list) do
        local e = pool[i]
        if not e then
            e = NewMemberEntry(cs)
            pool[i] = e
        end
        e.key, e.online, e.fixed = m.key, m.online and true or false, m.fixed
        e:SetWidth(colW - 10)
        Put(e, cs, ((i - 1) % 2) * colW + 8, y - floor((i - 1) / 2) * MEMBER_ROW_H)
        local c = e.online and ONLINE_DOT or OFFLINE_DOT
        e.dot:SetColorTexture(c[1], c[2], c[3], 1)
        local text = m.name or ColoredName(m.key)
        if m.fixed == "Guild Master" then
            text = text .. Paint(" (GM)", "muted")
        elseif m.fixed then
            text = text .. Paint(" (" .. m.fixed:lower() .. ")", "muted")
        end
        if not e.online then text = text .. Paint(" (offline)", "muted") end
        e.text:SetText(text)
        e:Show()
    end
    for i = #list + 1, #pool do pool[i]:Hide() end
    if #list == 0 then return y end
    return y - ceil(#list / 2) * MEMBER_ROW_H - 6
end

function SettingsUI:BuildCouncil(parent)
    local cs = CreateFrame("Frame", nil, parent)
    cs:SetPoint("TOPLEFT", parent, "TOPLEFT", RIGHT_X, 0)
    cs:SetSize(COL_W, 400)
    self.cs = cs

    local col = { parent = cs, x = 0, w = COL_W, y = -4 }
    self:Header(col, "Loot Council")
    cs.top = col.y
    cs.status = NewFS(cs, "GameFontHighlight", COL_W - 8, false)
    cs.summary = NewFS(cs, "GameFontHighlightSmall", COL_W - 8, true)
    cs.members = {}
    cs.raidSummary = NewFS(cs, "GameFontHighlightSmall", COL_W - 8, true)
    cs.raidMembers = {}
    cs.editBtn = ns.UI:CreateButton(cs, "Edit council\226\128\166", 130, 22, function() SettingsUI:OpenCouncilEditor() end)
    AddTooltip(cs.editBtn, "Edit council",
        "Opens the Loot Council picker (Council tab). The Guild Master picks the guild council; "
        .. "the raid leader picks extra council members for their raid.")
    cs.info = NewFS(cs, "GameFontDisableSmall", COL_W - 8, true)
end

function SettingsUI:CanEditCouncil()
    local CU = ns.CouncilUI
    if not (CU and CU.CanEditCouncil and CU:CanEditCouncil()) then return false end
    return (CU.IsAvailable == nil or CU:IsAvailable()) and true or false
end

function SettingsUI:OpenCouncilEditor()
    local CU = ns.CouncilUI
    if CU and CU.ShowCouncil then CU:ShowCouncil() end
end

-- Repaints the council section; returns its height.
function SettingsUI:RefreshCouncil()
    local cs = self.cs
    if not cs then return 0 end
    local y = cs.top

    local demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    local CU = ns.CouncilUI
    local sum = CU and CU.GetCouncilSummary and CU:GetCouncilSummary() or nil
    if demo and IsCouncil() then
        cs.status:SetText(Paint("You are on the Loot Council.", "obtained") .. Paint(" (demo mode)", "muted"))
    elseif IsCouncil() then
        local src = sum and SOURCE_TEXT[sum.mySource]
        cs.status:SetText(Paint("You are on the Loot Council.", "obtained") .. (src and Paint(" · " .. src, "muted") or ""))
    else
        cs.status:SetText(Paint("You are not on the Loot Council.", "muted"))
    end
    Put(cs.status, cs, 4, y)
    y = y - 20

    -- Guild council
    local guildList = {}
    if not sum then
        cs.summary:SetText(Paint("The council summary is not available.", "muted"))
    elseif not sum.inGuild then
        cs.summary:SetText("You are not in a guild. The Loot Council needs a guild; your own BiS list "
            .. "and personal drop alerts work anyway.")
    else
        guildList = sum.guildMembers or {}
        local g = sum.guild
        local text
        if g then
            text = format("Guild council (set by %s %s · phase P%d):", ColoredName(g.by or sum.gm or "?"),
                FormatAgo(g.rev), tonumber(g.phase) or 1)
        elseif sum.gm then
            text = "Guild council: only the Guild Master so far (no list shared yet)."
        else
            text = "Guild council: waiting for the guild roster..."
        end
        cs.summary:SetText(text)
    end
    Put(cs.summary, cs, 4, y)
    y = y - (TextHeight(cs.summary) + 6)
    y = LayoutMembers(cs, cs.members, guildList, y)

    -- This raid's council (only while in a raid)
    local raidList = {}
    if sum and sum.inRaid then
        raidList = sum.raidMembers or {}
        local leader = sum.raidLeader
        if sum.raidShared and leader then
            cs.raidSummary:SetText(format("This raid's council (set by raid leader %s):", ColoredName(leader)))
        elseif leader then
            cs.raidSummary:SetText(format("This raid's council: only the raid leader %s.", ColoredName(leader)))
        else
            cs.raidSummary:SetText("This raid's council: waiting for the raid roster...")
        end
        Put(cs.raidSummary, cs, 4, y - 4)
        cs.raidSummary:Show()
        y = y - (TextHeight(cs.raidSummary) + 10)
    else
        cs.raidSummary:Hide()
    end
    y = LayoutMembers(cs, cs.raidMembers, raidList, y)
    y = y - 6

    -- "Edit council…" for the Guild Master / raid leader, an explanation for everyone else.
    if self:CanEditCouncil() then
        Put(cs.editBtn, cs, 4, y)
        cs.editBtn:Show()
        y = y - 28
        local parts = {}
        if CU.CanEditCouncil and CU:CanEditCouncil("guild") then parts[#parts + 1] = "the guild council (Guild Master)" end
        if CU.CanEditCouncil and CU:CanEditCouncil("raid") then parts[#parts + 1] = "your raid's council list" end
        cs.info:SetText("You can edit " .. table.concat(parts, " and ") .. ".")
    else
        cs.editBtn:Hide()
        cs.info:SetText("The Guild Master picks the guild council in DisasterZone. A raid leader can add council "
            .. "members for their own raid; they count as council only inside that raid.")
    end
    Put(cs.info, cs, 4, y)
    y = y - (TextHeight(cs.info) + 8)
    cs:SetHeight(-y)
    return -y
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
function SettingsUI:RequestRefresh()
    local p = self.panel
    if not p then return end
    if not p:IsVisible() then
        p.dirty = true
        return
    end
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce("settings-refresh", 0.1, function() SettingsUI:Refresh() end)
    else
        self:Refresh()
    end
end

function SettingsUI:Refresh()
    local p = self.panel
    if not p then return end
    p.dirty = false
    for _, w in ipairs(self.refreshers) do
        if w.Refresh then w:Refresh() end
    end
    self:RefreshGroupRules()
    self:RefreshAbout()
    self:RefreshDungeon()
    local rightH = self:RefreshCouncil()
    self.child:SetHeight(max(self.leftHeight or 0, (rightH or 0) + 4) + 16)
end
