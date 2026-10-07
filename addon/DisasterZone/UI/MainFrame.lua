if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MainFrame.lua", ...) then return end -- DisasterZone UI/MainFrame.lua
-- ns.MainFrame: the main window, its navigation strip and page registry (panels created lazily), the sync status
-- at the right of the strip, and the minimap / LibDataBroker launcher.
local addonName, ns = ...

local MainFrame = ns:NewModule("MainFrame")

local FRAME_NAME = "DisasterZoneMainFrame"
local NAV_H = 28                          -- the navigation strip; every page keeps an 800x580 window's space
local WIDTH, HEIGHT = 800, 580 + NAV_H

-- Pages shown as an icon at the right of the strip (in the pages' order: Games, Changelog, Settings), and pages
-- without a tab (none at the moment).
local NAV_ICONS = {
    games     = { icon = 21, tip = { "Games", "Bingo and the other games to play with the guild." } },
    changelog = { icon = 25, tip = { "What's new", "The changes of every DisasterZone release." } },
    settings  = { icon = 13, tip = { "Settings" } },
}
-- Text tabs with a small pill after their label (UI:CreateNavStrip's badge): pages still being tried out.
local NAV_BADGES = {
    events = { text = "BETA", color = { 0.73, 0.55, 1 },
               tip = { "Events (beta)", "New and still being tested: pages and pieces may change from one version "
                   .. "to the next, and a few things may not work yet." } },
}
local NAV_HIDDEN = {}

-- Pages that became a view of another tab: their old key opens that view (a saved "tab used last", callers that
-- still say the old key). Returns true when it handled the open.
local MOVED = {
    loot = function() return ns.CouncilUI and ns.CouncilUI.ShowLog and (ns.CouncilUI:ShowLog() or true) end,
}

local tabDefs = {}      -- key -> { key, label, order, createFn, isAvailableFn, panel }
local tabList = {}      -- defs sorted by order
local frame, tabs, status, shareBtn
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
    if tabs then tabs.frame:Hide() end
    local defs = {}
    for _, def in ipairs(tabList) do
        if not NAV_HIDDEN[def.key] then
            local icon = NAV_ICONS[def.key]
            defs[#defs + 1] = { key = def.key, label = def.label, icon = icon and icon.icon, tip = icon and icon.tip,
                badge = NAV_BADGES[def.key] }
        end
    end
    tabs = ns.UI:CreateNavStrip(frame, defs, function(key) ShowPanel(key) end)
    local inset = frame.Inset
    tabs.frame:SetPoint("TOPLEFT", inset or frame, "TOPLEFT", inset and 3 or 6, inset and -3 or -26)
    tabs.frame:SetPoint("TOPRIGHT", inset or frame, "TOPRIGHT", inset and -3 or -6, inset and -3 or -26)
    -- right to left before the icon tabs: Share (what the page shows), then the sync status
    local right = tabs.rightAnchor
    if shareBtn then
        shareBtn:ClearAllPoints()
        shareBtn:SetPoint("RIGHT", tabs.rightAnchor, "RIGHT", 4, 0)
        right = shareBtn
    end
    if status then
        status:ClearAllPoints()
        -- (the mark on the icons' rhythm: its centre 32 left of the share icon's, like the icon tabs')
        status:SetPoint("RIGHT", right, shareBtn and "LEFT" or "RIGHT", shareBtn and -10 or 0, 0)
    end
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
        frame:SetWindowTitle("DisasterZone - <" .. guild .. ">")
    else
        frame:SetWindowTitle("DisasterZone")
    end
end

-- The sync status at the right of the strip: a mark with the full text in its tooltip; words only when something
-- needs a look (not shared, demo mode). The mark: arrows turning while the list is being shared, coming to rest and
-- giving way to a check that draws itself as it turns from the sync colour to green once it is shared; the arrows at
-- rest in orange when nobody can receive it.
local MARK_TEX = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\"
local MARK = 16
local C_SYNC, C_OK, C_WARN = { 0.42, 0.74, 1 }, { 0.33, 0.86, 0.42 }, { 1, 0.55, 0.1 }
local TURN = 1.1          -- seconds the arrows take for a turn
local MIN_TURN = 0.9      -- a share shows at least this long (no flicker)
local FADE = 0.18         -- the arrows fade in / out
local DRAW = 0.34         -- the check draws itself
local TINT = 0.5          -- the check turns green
local SPEED = 2 * math.pi / TURN

local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end
local function easeOut(t) return 1 - (1 - t) ^ 3 end
local function easeInOut(t) return t < 0.5 and 4 * t ^ 3 or 1 - (2 - 2 * t) ^ 3 / 2 end
local function mix(a, b, t) return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t end

local function Turn(m, angle)
    m.angle = angle
    if m.arrows.SetRotation then m.arrows:SetRotation(-angle) end      -- clockwise
end

-- The check drawn up to p (0..1), left to right.
local function DrawCheck(m, p)
    if p <= 0 then
        m.check:Hide()
        return
    end
    m.check:SetWidth(MARK * p)
    m.check:SetTexCoord(0, p, 0, 1)
    m.check:Show()
end

local MarkUpdate

-- Shows kind ("busy", "ok", "warn", nil) at once: the window opening, a hidden window, nothing to animate from.
local function Settle(m, kind)
    m:SetScript("OnUpdate", nil)
    m.phase, m.fadeIn = nil, nil
    Turn(m, 0)
    m.arrows:SetAlpha(1)
    m.check:SetAlpha(1)
    m.arrows:SetShown(kind == "busy" or kind == "warn")
    m.arrows:SetVertexColor(unpack(kind == "warn" and C_WARN or C_SYNC))
    if kind == "ok" then
        DrawCheck(m, 1)
        m.check:SetVertexColor(unpack(C_OK))
    else
        m.check:Hide()
    end
    if kind == "busy" then
        m.phase, m.since = "turn", GetTime()
        m:SetScript("OnUpdate", MarkUpdate)
    end
end

MarkUpdate = function(m, elapsed)
    local now = GetTime()
    if m.phase == "turn" then
        Turn(m, m.angle + (elapsed or 0) * SPEED)
        if m.want ~= "busy" and now - m.since >= MIN_TURN then
            -- slow down evenly to rest on a half turn (the arrows look the same every half turn)
            local rest = math.ceil((m.angle + 0.8) / math.pi) * math.pi
            m.phase, m.t0, m.a0, m.rest = "stop", now, m.angle, rest
            m.stopFor = 2 * (rest - m.angle) / SPEED
        end
    elseif m.phase == "stop" then
        local p = clamp01((now - m.t0) / m.stopFor)
        Turn(m, m.a0 + (m.rest - m.a0) * (1 - (1 - p) * (1 - p)))
        if p >= 1 then
            Turn(m, 0)
            if m.want == "ok" then
                m.phase, m.t0 = "draw", now
                m.check:SetAlpha(1)
            elseif m.want == "warn" then
                m.phase, m.t0 = "warn", now
            else
                Settle(m, m.want)
                return
            end
        end
    end
    -- the arrows coming in (over a check, or from nothing)
    if m.fadeIn then
        local p = clamp01((now - m.fadeIn) / FADE)
        m.arrows:SetAlpha(p)
        m.check:SetAlpha(1 - p)
        if p >= 1 then
            m.fadeIn = nil
            m.check:Hide()
            m.check:SetAlpha(1)
        end
    end
    if m.phase == "draw" then
        local t = now - m.t0
        m.arrows:SetAlpha(1 - clamp01(t / FADE))
        DrawCheck(m, easeOut(clamp01((t - 0.06) / DRAW)))
        m.check:SetVertexColor(mix(C_SYNC, C_OK, easeInOut(clamp01((t - 0.12) / TINT))))
        if t >= 0.12 + TINT then Settle(m, "ok") end
    elseif m.phase == "warn" then
        local p = clamp01((now - m.t0) / 0.3)
        m.arrows:SetVertexColor(mix(C_SYNC, C_WARN, p))
        if p >= 1 then Settle(m, "warn") end
    end
end

-- Moves the mark to kind. animate: false shows it at once.
local function SetMark(m, kind, animate)
    local was = m.want
    m.want = kind
    if not animate or not m:IsVisible() then
        Settle(m, kind)
        return
    end
    if kind == was then return end
    if kind == "busy" then
        m.arrows:SetVertexColor(unpack(C_SYNC))
        m.arrows:Show()
        if m.phase == "stop" then
            m.since = GetTime()                       -- (another share: keep turning)
        elseif m.phase ~= "turn" then
            m.arrows:SetAlpha(0)
            m.fadeIn, m.since = GetTime(), GetTime()
            Turn(m, 0)
        end
        m.phase = "turn"
        m:SetScript("OnUpdate", MarkUpdate)
    elseif (kind == "ok" or kind == "warn") and (m.phase == "turn" or m.phase == "stop") then
        return                                        -- (the turning arrows come to rest first)
    else
        Settle(m, kind)
    end
end

local function CreateMark(parent)
    local m = CreateFrame("Frame", nil, parent)
    m:SetSize(MARK, MARK)
    m.arrows = m:CreateTexture(nil, "ARTWORK")
    m.arrows:SetTexture(MARK_TEX .. "sync")
    m.arrows:SetAllPoints()
    m.check = m:CreateTexture(nil, "ARTWORK")
    m.check:SetTexture(MARK_TEX .. "check")
    m.check:SetPoint("LEFT", m, "LEFT", 0, 0)
    m.check:SetSize(MARK, MARK)
    m.angle = 0
    Settle(m, nil)
    return m
end

-- instant: the window just opened (no animation into the state it is in).
local function UpdateStatus(instant)
    if not frame or not status then return end
    local kind, text = "none", ""
    if ns.Sync and ns.Sync.GetStatus then kind, text = ns.Sync:GetStatus() end
    local demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    local words = {}
    if demo then words[#words + 1] = "|cffff8000Demo mode|r" end
    if kind == "warn" then words[#words + 1] = "|cffff8000Not shared yet|r" end
    status.text:SetText(table.concat(words, "  ·  "))
    local marked = kind == "ok" or kind == "busy" or kind == "warn"
    status.mark:SetShown(marked)
    SetMark(status.mark, marked and kind or nil, not instant)
    status.tip = ns.UI:SafeText(text or "")
    local tw = status.text:GetStringWidth() or 0
    local w = (marked and MARK or 0) + (tw > 0 and (tw + (marked and 8 or 0)) or 0)
    status:SetWidth(math.max(1, w))
    status:SetShown(w > 0)
end

local function CreateStatus()
    local s = CreateFrame("Frame", nil, frame)
    s:SetHeight(18)
    s.mark = CreateMark(s)
    s.mark:SetPoint("RIGHT", 0, 1)
    s.text = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    s.text:SetPoint("RIGHT", s.mark, "LEFT", -8, 0)
    s.text:SetJustifyH("RIGHT")
    s.text:SetWordWrap(false)
    s:EnableMouse(true)
    s:SetScript("OnEnter", function(self)
        UpdateStatus()   -- "1m ago" stays current
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Your BiS lists")
        if self.tip and self.tip ~= "" then GameTooltip:AddLine(self.tip, 1, 1, 1, true) end
        if ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() then
            GameTooltip:AddLine("Demo mode: made-up members, lists and a raid to try the council views; never saved.",
                1, 0.5, 0, true)
        end
        GameTooltip:Show()
    end)
    s:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return s
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
    frame = UI:CreateWindow(FRAME_NAME, "DisasterZone", WIDTH, HEIGHT)
    frame:Hide()
    -- the pages start under the navigation strip
    local inset = frame.Inset
    frame.content:SetPoint("TOPLEFT", inset or frame, "TOPLEFT", inset and 3 or 6, (inset and -3 or -26) - NAV_H)

    status = CreateStatus()
    -- a link in chat to what the page shows (the raid, the member, ... picked on it; UI/Share.lua)
    if ns.Share and ns.Share.CreateNavButton then
        shareBtn = ns.Share:CreateNavButton(frame, function() return ns.Share:CurrentRef() end)
    end

    frame:HookScript("OnShow", function()
        if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN) end
        UpdateTitle()
        UpdateStatus(true)
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
    if MOVED[key] and MOVED[key]() then return end
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
-- Launcher (LibDataBroker + LibDBIcon, both embedded in DisasterZone/Libs)
---------------------------------------------------------------------------

local function LauncherTooltip(tt)
    if not tt or not tt.AddLine then return end
    tt:AddLine("DisasterZone", 1, 0.5, 0)
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
    local obj = ldb:GetDataObjectByName("DisasterZone") or ldb:NewDataObject("DisasterZone", {
        type = "launcher",
        label = "DisasterZone",
        text = "DisasterZone",
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
    if not icon:IsRegistered("DisasterZone") then
        icon:Register("DisasterZone", obj, ns.db.settings.minimap)
    end
end

function MainFrame:OnInit() end

function MainFrame:OnLogin()
    SetupLauncher()
end

---------------------------------------------------------------------------
-- Messages & slash commands
---------------------------------------------------------------------------

ns:On("SYNC_STATUS", function() UpdateStatus() end)
ns:On("PEERS_UPDATED", function() UpdateStatus() end)
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
