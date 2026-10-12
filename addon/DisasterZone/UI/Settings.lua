if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Settings.lua", ...) then return end -- DisasterZone UI/Settings.lua
-- "Settings" tab: the sections in a nav on the left (Alerts, Group loot rules, Rolls, Strategy boards, Tooltips,
-- Window, Loot Council, Attendance, Demo mode, About), one section at a time on the right. Every option is a row: its name, a
-- one-line explanation and a switch (UI:CreateSwitch) or a dropdown. Group loot rules (ADDENDUM D §26/§27) that come
-- from someone else show their values as plain text under "Set by X"; the raid leader's "Lock BiS lists"
-- (ADDENDUM F §38); the read-only Loot Council summary with "Edit council..." (ADDENDUM E §30); a Blizzard Settings
-- entry (SPEC §12.10).
local addonName, ns = ...

local SettingsUI = ns:NewModule("SettingsUI")

local _G = _G
local CreateFrame = CreateFrame
local format = string.format
local floor, max = math.floor, math.max
local ipairs, type, tonumber, tostring = ipairs, type, tonumber, tostring
local UI, S = ns.UI, ns.Style

-- The page (S.PAGE_W x S.PAGE_H, 790 x 548) is a side menu layout (UI:CreateLayout "rail"): the nav on the left
-- (UI:CreateRailNav), the open section in the layout's scroll frame on the right (its bar in the right margin).
local LG = UI.LAYOUT
local BODY_X = S.PAD + LG.RAIL_W + LG.RAIL_GAP            -- 178
local BODY_W = S.PAGE_W - S.PAD - BODY_X                  -- 602
local BODY_H = S.PAGE_H - LG.RAIL_TOP - S.PAD             -- 530
local TITLE_H = 28                             -- a section's title (lines up with its nav item)
local SUB_H = 18                               -- the line under a title (who sets the rules, my council seat)
local ROW_H = 44
local DD_W, SWITCH_W = 196, 34
local TEXT_GAP = 16                            -- between a row's text and its control
local MEMBER_COLS, MEMBER_ROW_H = 3, 24

local SECTIONS = {
    { key = "alerts", label = "Alerts" },
    { key = "notify", label = "Notifications" },
    { key = "rules", label = "Group loot rules" },
    { key = "rolls", label = "Rolls" },
    { key = "strategy", label = "Strategy boards" },
    { key = "tooltips", label = "Tooltips" },
    { key = "mylog", label = "My Log" },
    { key = "meters", label = "Meters" },
    -- class tools (Core/ClassKit.lua): a collapsible card per tool of my class (every class's in demo mode)
    { key = "classtools", label = "Class tools", visible = function() return SettingsUI:HasClassTools() end },
    { key = "window", label = "Window" },
    { key = "council", label = "Loot Council" },
    -- the GM's attendance margins (Guild:SetAttendanceRules): everyone sees them, the GM changes them
    { key = "attendance", label = "Attendance" },
    -- the Welcome tour's parts, the strategy board's tutorial, the GM's set-up checklist (UI/WelcomeTour.lua)
    { key = "tutorials", label = "Tutorials" },
    { key = "demo", label = "Demo mode" },
    { key = "about", label = "About" },
}

-- GetCouncilSource(me) -> text for the status line.
local SOURCE_TEXT = {
    gm = "Guild Master",
    guild = "guild council list",
    raidleader = "raid leader of this raid",
    raid = "this raid's council",
}

-- The raids of a phase, short (a dropdown is 196 wide).
local PHASE_RAIDS = { "Kara, Gruul, Mag", "SSC, TK", "Hyjal, BT", "ZA", "Sunwell" }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
-- an aside in the secondary grey (S.C.SUB)
local function Grey(text)
    return S:Wrap("SUB", text)
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

-- Switch setters may be called as setter(checked) or setter(button, checked).
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

-- a player's name without the realm ("?" for none)
local function NameOf(key)
    if type(key) ~= "string" then return "?" end
    return ns.Util.ShortName(key) or key
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
    return NameOf(key)
end

local function FormatAgo(ts)
    if ns.Util and ns.Util.FormatAgo then return ns.Util.FormatAgo(ts) end
    return ""
end

local function Put(region, parent, x, y)
    region:ClearAllPoints()
    region:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
end

local function TextHeight(fs)
    local h = fs:GetStringHeight()
    return max(12, tonumber(h) or 12)
end

local function MaxPhase()
    return ns.MAX_PHASE or 5
end

local function PhaseLabel(p)
    local raids = PHASE_RAIDS[p]
    if raids then return format("P%d · %s", p, raids) end
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

-- A row's tooltip (its owner may be the row's control): the title in gold, the text in white.
local function ShowTip(owner, title, text)
    local tt = _G.GameTooltip
    tt:SetOwner(owner, "ANCHOR_TOP")
    tt:AddLine(title, S:RGB("GOLD"))
    tt:AddLine(text, 1, 1, 1, true)
    tt:Show()
end

local function AddTooltip(frame, title, text)
    UI:AttachTooltip(frame, title, text, { anchor = "ANCHOR_TOP" })
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function SettingsUI:OnInit()
    self.refreshers = {}
    self.ruleControls = {}
    self.section = "alerts"
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("settings", "Settings", 4,
            function(parent) return SettingsUI:CreatePanel(parent) end,
            function() return true end)
    end
    local function changed() SettingsUI:RequestRefresh() end
    for _, msg in ipairs({ "SETTINGS_CHANGED", "CONFIG_UPDATED", "ROSTER_UPDATED", "PEERS_UPDATED",
                           "DEMO_TOGGLED", "SYNC_STATUS", "DUNGEON_MODE_CHANGED", "GROUP_UPDATED",
                           "GROUP_RULES_CHANGED", "BIS_LOCK_CHANGED", "MYLOG_CHANGED", "ATTENDANCE_RULES_CHANGED",
                           "TOUR_CHANGED", "LOOT_RULES_CHANGED", "RAIDPLAN_CHANGED" }) do
        ns:On(msg, changed)
    end
end

function SettingsUI:OnLogin()
    self:RegisterBlizzardCategory()
    -- a respec shows or hides class tool sections (Swing timer: Retribution only)
    ns:On("CLASSKIT_CHANGED", function()
        SettingsUI:LayoutNav()
        SettingsUI:LayoutClassTools()
    end)
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

-- The panel in Blizzard's Options > AddOns, built from the window's own parts: a page banner (the next raid's loading
-- screen, the seal as its icon, the version, the name, the guild, a live line of facts; Open DisasterZone and
-- Settings as its actions), a section header over a card for every page of the window (click = open it there,
-- right-click = pin it to the minimap arc; a Pinned pill on the pinned ones) and an inset footer with the sync status
-- and the slash commands as chips. Built the first time it is shown, so every page has registered by then; the cards
-- are laid out again on every show (the panel's width can change).
local DISC = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\disc"
-- Cards: CARD_H with the title over a one-line tip, CARD_H_SMALL with the title alone (when the panel is too short
-- for the tall ones); the page's full tip is always in the card's tooltip.
local CARD_W, CARD_H, CARD_H_SMALL, GAP = 196, 44, 32, 6
-- One short line per card, short enough for one line at three columns (the window's page tips are too long).
local CARD_TIPS = {
    home = "Raids this week, calendar.", raids = "Raid nights, teams, plans.",
    council = "Loot decisions and log.", lootrules = "How loot gets decided.",
    mylog = "Your pulls, run by run.", mybis = "BiS lists, what's missing.",
    gearsim = "Gear compared in fights.", consumables = "Flasks, food, potions.",
    atlas = "Every drop, set and cost.", members = "Members and professions.",
    map = "Where guildmates are.", dungeons = "Find a dungeon group.",
    events = "Guild events and cups.", polls = "Officers' questions.",
    games = "Bingo and guild games.", feedback = "Bugs, ideas and changes.",
    changelog = "What's new each release.", perf = "What DisasterZone costs.",
    settings = "Alerts, minimap and more.", blessings = "Who blesses which class.",
    totems = "Each shaman's totems.",
}
local HERO_H = 150

local function CloseBlizzardPanel()
    local sp = _G.SettingsPanel
    if sp and sp:IsShown() then
        if _G.HideUIPanel then _G.HideUIPanel(sp) else sp:Hide() end
    end
end

-- (UI:AttachTooltip's builder for a page card: its name, its line, the clicks)
local function CardTip(c, tt)
    local Arc = ns.MinimapArc
    tt:AddLine(ns.MainFrame:GetPageLabel(c.key) or c.key, S:RGB("TEXT"))
    local tip = ns.MainFrame:GetPageTip(c.key) or CARD_TIPS[c.key]
    if type(tip) == "string" and tip ~= "" then tt:AddLine(tip, S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], true) end
    tt:AddLine("Click: open it", S:RGB("SUB"))
    if Arc then
        tt:AddLine(Arc:IsPinned(c.key) and "Right-click: unpin from the minimap" or "Right-click: pin to the minimap",
            S:Color("SUB"))
    end
end

-- A page's card (UI:CreateCard with the shared hover): its icon tile, name and one-line tip; Pinned while it is on
-- the minimap arc.
local function PageCard(parent, key)
    local Arc = ns.MinimapArc
    local c = UI:CreateCard(parent, { pad = 0, width = CARD_W, height = CARD_H })
    c.body:Hide()
    c.key = key
    UI:DecorateRow(c)
    c.tile = UI:CreateIconTile(c, 22)
    local tc = UI:IconCoords(Arc and Arc.GetPageIcon and Arc:GetPageIcon(key) or UI.ICON.more)
    c.tile.tex:SetTexture(UI.ICON_ATLAS)
    c.tile.tex:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
    c.tile.tex:SetVertexColor(S:Color("GOLD"))
    c.tile.outer:SetColorTexture(S:Color("INSET"))
    c.title = UI:Text(c, "emph", "TEXT")
    c.title:SetText(ns.MainFrame:GetPageLabel(key) or key)
    c.tip = UI:Text(c, "small", "SUB")
    c.tip:SetText(CARD_TIPS[key] or ns.MainFrame:GetPageTip(key) or "")
    c.pill = UI:CreatePill(c, "bis", "Pinned")
    c.pill:SetPoint("TOPRIGHT", c, "TOPRIGHT", -6, -6)
    -- w x h: the tip shows under the title when the card is tall and the tip fits on one line, else the title sits
    -- alone in the middle
    function c:Layout(w, h)
        self:SetSize(w, h)
        self.tile:ClearAllPoints()
        self.tile:SetPoint("LEFT", self, "LEFT", 12, 0)
        local pinned = Arc and Arc:IsPinned(self.key) or false
        self.pill:SetShown(pinned)
        local room = w - (12 + 22 + 10) - 10 - (pinned and (self.pill:GetWidth() + 6) or 0)
        local tw = UI:TextWidth(self.tip)
        local withTip = h >= CARD_H and tw > 0 and tw <= w - (12 + 22 + 10) - 10
        self.title:ClearAllPoints()
        self.title:SetPoint(withTip and "BOTTOMLEFT" or "LEFT", self.tile, "RIGHT", 10, withTip and 1 or 0)
        self.title:SetWidth(max(20, room))
        self.tip:ClearAllPoints()
        self.tip:SetPoint("TOPLEFT", self.tile, "RIGHT", 10, -3)
        self.tip:SetWidth(w - (12 + 22 + 10) - 10)
        self.tip:SetShown(withTip)
    end
    UI:AttachTooltip(c, CardTip, nil, { anchor = "ANCHOR_TOP" })
    c:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            if Arc then Arc:SetPinned(self.key, not Arc:IsPinned(self.key)) end
            self:Layout(self:GetWidth(), self:GetHeight())
            UI:RefreshTooltip(self)        -- (its pin / unpin line follows at once)
            return
        end
        CloseBlizzardPanel()
        ns.MainFrame:Open(self.key)
    end)
    return c
end

local function NextRaid()
    local RP = ns.RaidPlan
    if not (RP and RP.GetRaids) then return nil end
    local now, best = time(), nil
    local ok, list = pcall(RP.GetRaids, RP, now - 4 * 3600, now + 14 * 86400)
    if not ok or type(list) ~= "table" then return nil end
    for _, v in ipairs(list) do
        if type(v.t) == "number" and v.t >= now - 4 * 3600 and (not best or v.t < best.t) then best = v end
    end
    return best
end

local function Countdown(s)
    if s <= 0 then return "now" end
    local d, h, m = floor(s / 86400), floor(s % 86400 / 3600), floor(s % 3600 / 60)
    if d > 0 then return ("in %dd %dh"):format(d, h) end
    if h > 0 then return ("in %dh %dm"):format(h, m) end
    return ("in %dm"):format(max(1, m))
end

-- The banner: the next raid's loading screen (else Outland's), the seal, the version, the name, the guild and a line
-- of facts (the next raid, members online, my BiS progress); the two ways in as its actions.
local function BuildHero(canvas, p)
    local applied = ns.Boot and ns.Boot.applied and (ns.Boot.applied.files or 0) > 0
    local hero = UI:CreatePageBanner(canvas, {
        size = HERO_H, art = "other", artFw = 1, kickerCaps = false,
        icon = ns:HasAssets(4) and "Interface\\AddOns\\DisasterZone\\Media\\Launcher\\seal"
            or "Interface\\Icons\\INV_Misc_Bag_10_Blue",
        kicker = "v" .. tostring(ns.version or "?") .. (applied and ("  ·  update on " .. tostring(ns.diskVersion)) or ""),
        title = "DisasterZone",
        actions = {
            { text = "Open DisasterZone", kind = "primary", width = 150, onClick = function()
                CloseBlizzardPanel()
                ns.MainFrame:Open()
            end },
            { text = "Settings", width = 100, onClick = OpenFromBlizzard },
        },
    })
    hero:SetPoint("TOPLEFT", 12, -12)
    hero:SetPoint("TOPRIGHT", -12, -12)
    p.guild = hero.sub
    -- the facts, under the guild line
    p.facts = UI:Text(hero, "body", "TEXT")
    p.facts:SetPoint("TOPLEFT", hero.sub, "BOTTOMLEFT", 0, -8)
    p.raidName = UI:Text(hero, "small", "SUB", { justify = "RIGHT" })     -- whose painting it is
    p.raidName:SetPoint("TOPRIGHT", hero, "TOPRIGHT", -12, -12)
    p.hero = hero
    return hero
end

local function RefreshHero(p)
    local hero = p.hero
    local guild = IsInGuild() and GetGuildInfo("player")
    local council = ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil()
    hero:SetSub(guild and ("<" .. guild .. ">  ·  " .. (council and "Loot Council" or "Raider"))
        or "Your guild's raids, loot and pastimes in one place")
    local v = NextRaid()
    hero:SetArt(v and v.i or "other")
    local G = function(t) return S:Wrap("GOLD", t) end
    local parts = {}
    if v then
        local name = ns.RaidPlan.GetRaidName and ns.RaidPlan:GetRaidName(v) or "Raid"
        parts[1] = G("Next raid") .. "  " .. name .. "  ·  " .. date("%a %H:%M", v.t) .. "  ·  " .. Countdown(v.t - time())
        local inst = ns.RaidPlan.GetInstance and ns.RaidPlan:GetInstance(v.i)
        p.raidName:SetText(inst and inst.name or "")
    else
        parts[1] = G("Next raid") .. "  none planned"
        p.raidName:SetText("")
    end
    local online = 0
    if IsInGuild() then
        local _, on = GetNumGuildMembers()
        online = tonumber(on) or 0
    end
    parts[2] = G("Online") .. "  " .. online
    local ok, prog = false, nil
    if ns.MyBiS and ns.MyBiS.GetProgress then ok, prog = pcall(ns.MyBiS.GetProgress, ns.MyBiS) end
    if ok and type(prog) == "table" and (prog.total or 0) > 0 then
        parts[3] = G("BiS") .. "  " .. (prog.obtained or 0) .. "/" .. prog.total
    else
        parts[3] = G("BiS") .. "  no list yet"
    end
    -- the line stays inside the banner: too long, the next raid drops its day and time, then its countdown
    local room = (hero:GetWidth() or 0) - (hero.textX or 70) - 14
    if room <= 0 then room = 520 end
    local sep = S:Wrap("DIM", "   |   ")
    p.facts:SetText(table.concat(parts, sep))
    if v and UI:TextWidth(p.facts) > room then
        local name = ns.RaidPlan.GetRaidName and ns.RaidPlan:GetRaidName(v) or "Raid"
        parts[1] = G("Next raid") .. "  " .. name .. "  ·  " .. Countdown(v.t - time())
        p.facts:SetText(table.concat(parts, sep))
        if UI:TextWidth(p.facts) > room then
            parts[1] = G("Next raid") .. "  " .. name
            p.facts:SetText(table.concat(parts, sep))
        end
    end
end

local function BuildBlizzardPanel(canvas)
    local p = {}
    local hero = BuildHero(canvas, p)

    -- the cards, under a section header
    local head = UI:CreateSectionHeader(canvas, "Jump to", { right = "Right-click a card to pin it to the minimap button" })
    head:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", 0, -10)
    head:SetPoint("TOPRIGHT", hero, "BOTTOMRIGHT", 0, -10)
    p.grid = CreateFrame("Frame", nil, canvas)
    p.grid:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -8)
    p.grid:SetPoint("RIGHT", hero, "RIGHT")
    p.grid:SetHeight(1)
    p.cards = {}

    -- the footer: an inset card with the sync status and the slash commands
    local foot = UI:CreateCard(canvas, { tone = "inset", pad = 0 })
    foot.body:Hide()
    foot:SetPoint("BOTTOMLEFT", 12, 12)
    foot:SetPoint("BOTTOMRIGHT", -12, 12)
    foot:SetHeight(34)
    local dot = foot:CreateTexture(nil, "ARTWORK")
    dot:SetTexture(DISC)
    dot:SetSize(7, 7)
    dot:SetPoint("LEFT", 12, 0)
    dot:SetVertexColor(S:Color("OK"))
    p.status = UI:Text(foot, "small", "TEXT")
    p.status:SetPoint("LEFT", dot, "RIGHT", 8, 0)
    local last
    for _, cmd in ipairs({ "/dz help", "/dz settings", "/dz" }) do
        local chip = UI:CreateChip(foot, { text = cmd })
        if last then chip:SetPoint("RIGHT", last, "LEFT", -6, 0) else chip:SetPoint("RIGHT", -8, 0) end
        last = chip
    end
    p.status:SetPoint("RIGHT", last, "LEFT", -12, 0)
    return p
end

local function RefreshBlizzardPanel(canvas, p)
    RefreshHero(p)
    local status = ns.Sync and ns.Sync.GetStatusText and ns.Sync:GetStatusText()
    p.status:SetText(((status and status ~= "" and ns.UI:SafeText(status)) or "Ready"))

    local keys = ns.MainFrame:GetShownPages()
    local gw = p.grid:GetWidth() or 0
    if gw < CARD_W then gw = max((canvas:GetWidth() or 0) - 24, 3 * CARD_W + 2 * GAP) end
    -- the room between the "Jump to" header and the footer (12 + 34, then a gap)
    local ch, top, gridTop = canvas:GetHeight() or 0, canvas:GetTop(), p.grid:GetTop()
    local off = (top and gridTop) and (top - gridTop) or 0
    if off <= 0 or off >= ch then off = 12 + HERO_H + 42 end
    local avail = ch - off - 54
    -- the first layout that fits: tall cards, tall cards in one more column (if they stay wide enough), small
    -- cards, small cards in one more column; the last one when none does
    local base = max(1, floor((gw + GAP) / (CARD_W + GAP)))
    local cols, h
    for _, try in ipairs({ { base, CARD_H }, { base + 1, CARD_H }, { base, CARD_H_SMALL }, { base + 1, CARD_H_SMALL } }) do
        local n, th = try[1], try[2]
        local rows = math.ceil(#keys / n)
        if (gw - (n - 1) * GAP) / n >= CARD_W * 0.8 or n == base then
            cols, h = n, th
            if rows * th + (rows - 1) * GAP <= avail then break end
        end
    end
    local w = (gw - (cols - 1) * GAP) / cols
    for _, c in pairs(p.cards) do c:Hide() end
    for i, key in ipairs(keys) do
        local c = p.cards[key] or PageCard(p.grid, key)
        p.cards[key] = c
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        c:Layout(w, h)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", p.grid, "TOPLEFT", col * (w + GAP), -row * (h + GAP))
        c:Show()
    end
end

function SettingsUI:RegisterBlizzardCategory()
    local BS = _G.Settings
    if self.category or not (BS and BS.RegisterCanvasLayoutCategory and BS.RegisterAddOnCategory) then return end
    local canvas = CreateFrame("Frame", "DisasterZoneBlizzardOptions")
    local panel
    canvas:SetScript("OnShow", function(f)
        if not (ns.UI and ns.MainFrame) then return end
        panel = panel or BuildBlizzardPanel(f)
        -- the canvas gets its size in the same frame it shows: lay the cards out once it has one
        C_Timer.After(0, function() if f:IsShown() then RefreshBlizzardPanel(f, panel) end end)
    end)

    local cat = BS.RegisterCanvasLayoutCategory(canvas, "DisasterZone")
    BS.RegisterAddOnCategory(cat)
    self.category = cat
end

---------------------------------------------------------------------------
-- Building blocks: the nav, a section, its rows
---------------------------------------------------------------------------

-- A section: its title (gold, as big as the nav item is tall), rows from sec.y down.
function SettingsUI:NewSection(def)
    local sec = CreateFrame("Frame", nil, self.child)
    sec:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, 0)
    sec:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, 0)
    sec:SetHeight(BODY_H)
    sec.key = def.key
    sec.rows = {}
    sec.title = UI:Text(sec, "page")
    sec.title:SetPoint("LEFT", sec, "TOPLEFT", 0, -TITLE_H / 2)
    sec.title:SetText(def.label)
    sec.y = -TITLE_H
    sec:Hide()
    self.sections[def.key] = sec
    return sec
end

-- The line under a section's title (who sets the rules, my council seat): white, its asides grey.
function SettingsUI:Subtitle(sec)
    local fs = UI:Text(sec, "small", "TEXT")
    fs:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - 1)
    fs:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y - 1)
    sec.y = sec.y - SUB_H
    return fs
end

-- A notice under a section's title (UI:CreateNotice): whose values these are, read-only while someone else sets them.
-- It only shows what the section already decides. notice.text is its line.
local NOTICE_SPACE = 26 + 8
function SettingsUI:Notice(sec, kind)
    local n = UI:CreateNotice(sec, kind or "info", "")
    n:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - 2)
    n:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y - 2)
    sec.y = sec.y - NOTICE_SPACE
    return n
end

-- Ends a section: no rule under its last row; its height.
function SettingsUI:EndSection(sec, extra)
    local last = sec.rows[#sec.rows]
    if last and last.line then last.line:Hide() end
    sec.height = -sec.y + (extra or 0)
end

-- Places a row's texts left of a control ctrlW wide: name on top, the explanation under it (or the name alone,
-- centred).
local function PlaceText(row, ctrlW)
    local right = -(((ctrlW or 0) > 0) and (ctrlW + TEXT_GAP) or 0)
    row.title:ClearAllPoints()
    row.desc:ClearAllPoints()
    if row.hasDesc then
        row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -8)
        row.title:SetPoint("TOPRIGHT", row, "TOPRIGHT", right, -8)
        row.desc:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -25)
        row.desc:SetPoint("TOPRIGHT", row, "TOPRIGHT", right, -25)
    else
        row.title:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.title:SetPoint("RIGHT", row, "RIGHT", right, 0)
    end
end

local function RowEnter(row)
    local c = row.control
    if c and c.SetHover and c:IsShown() and c:IsEnabled() then c:SetHover(true) end
    if row.tip then ShowTip(row, row.tipTitle or row.title:GetText() or "", row.tip) end
end

local function RowLeave(row)
    local c = row.control
    if c and c.SetHover then c:SetHover(false) end
    if row.tip then _G.GameTooltip:Hide() end
end

-- A row: the option's name (white) and a one-line explanation (grey) on the left, its control on the right, a faint
-- rule under it. tip (optional): more about it on hover.
function SettingsUI:Row(sec, title, desc, tip)
    local row = CreateFrame("Button", nil, sec)
    row:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y)
    row:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y)
    row:SetHeight(ROW_H)
    row.title = UI:Text(row, "emph")
    row.title:SetText(title or "")
    row.desc = UI:Text(row, "small")
    row.desc:SetText(desc or "")
    row.hasDesc = desc ~= nil
    UI:DecorateRow(row, { rule = true })     -- (the shared hover and the hairline under it)
    row.line = row.dzRule
    row.tip = tip
    row:SetScript("OnEnter", RowEnter)
    row:SetScript("OnLeave", RowLeave)
    sec.y = sec.y - ROW_H
    sec.rows[#sec.rows + 1] = row
    PlaceText(row, 0)
    return row
end

-- The plain-text value shown instead of a control while the option is set by someone else.
local function AddValueText(row)
    row.value = UI:Text(row, "emph")
    row.value:SetJustifyH("RIGHT")
    row.value:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.value:Hide()
end

-- Shows a row's control, or (read-only) its value as text in its place. The control is disabled while read-only.
local function SetReadOnly(row, readOnly, valueText)
    local c = row.control
    if not c then return end
    readOnly = readOnly and true or false
    if c.SetEnabled then c:SetEnabled(not readOnly) end
    c:SetShown(not readOnly)
    if row.value then
        row.value:SetText(valueText or "")
        row.value:SetShown(readOnly)
    end
    row.readOnly = readOnly
end

function SettingsUI:Switch(sec, title, desc, getter, setter, tip)
    local row = self:Row(sec, title, desc, tip)
    local sw = ns.UI:CreateSwitch(row, getter, setter)
    sw:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    sw.label = row.title          -- the switch's name (what a click on the row toggles)
    sw:HookScript("OnEnter", function() if row.tip then RowEnter(row) end end)
    sw:HookScript("OnLeave", function() if row.tip then _G.GameTooltip:Hide() end end)
    row.control = sw
    AddValueText(row)
    PlaceText(row, SWITCH_W)
    row:SetScript("OnClick", function()
        if sw:IsShown() and sw:IsEnabled() then sw:Click() end
    end)
    self.refreshers[#self.refreshers + 1] = sw
    return sw, row
end

function SettingsUI:SwitchSetting(sec, title, desc, path, default, tip)
    return self:Switch(sec, title, desc,
        function() return Get(path, default) and true or false end,
        function(a, b) Set(path, Bool(a, b)) end, tip)
end

function SettingsUI:Dropdown(sec, title, desc, getOptions, getSelected, onSelect, tip)
    local row = self:Row(sec, title, desc, tip)
    local dd = ns.UI:CreateSleekDropdown(row, DD_W, getOptions, getSelected, onSelect)
    dd:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    dd.cdlLabel = row.title
    if tip then
        dd:HookScript("OnEnter", function() RowEnter(row) end)
        dd:HookScript("OnLeave", function() _G.GameTooltip:Hide() end)
    end
    row.control = dd
    AddValueText(row)
    PlaceText(row, DD_W)
    self.refreshers[#self.refreshers + 1] = dd
    return dd, row
end

function SettingsUI:DropdownSetting(sec, title, desc, path, default, options, tip)
    return self:Dropdown(sec, title, desc,
        function() return options end,
        function() return Get(path, default) end,
        function(a, b) Set(path, Value(a, b)) end, tip)
end

-- A group-rule dropdown (ADDENDUM D §26/§27): shows the value in effect, writes my own setting; read-only (its value
-- as text) while the rules come from the group's loot leader.
function SettingsUI:RuleDropdown(sec, title, desc, path, default, options, tip)
    local dd, row = self:Dropdown(sec, title, desc,
        function() return options end,
        function() return Effective(path, default) end,
        function(a, b)
            if SettingsUI:GroupRulesEditable() then Set(path, Value(a, b)) end
        end, tip)
    self.ruleControls[#self.ruleControls + 1] = dd
    return dd, row
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------
function SettingsUI:CreatePanel(parent)
    if self.panel then return self.panel end
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints(parent)
    panel.dirty = true
    self.panel = panel

    -- the side menu layout: the nav (UI:CreateRailNav) | a hairline | the open section in a scroll frame
    local layout = UI:CreateLayout("rail", panel, {
        width = S.PAGE_W, scroll = true, selected = self.section,
        onSelect = function(key) SettingsUI:SelectSection(key) end,
    })
    self.layout, self.rail = layout, layout.rail
    -- self.nav[key]: a section's nav row (a hidden stand-in while the section is not in the nav)
    self.nav = {}
    self.navHidden = CreateFrame("Frame", nil, panel)
    self.navHidden:Hide()
    self:LayoutNav()

    local scroll, child = layout.scroll, layout.body
    child:SetSize(BODY_W, BODY_H)
    self.scroll, self.child = scroll, child
    -- the column's right edge is the page's minus PAD, whatever the page's real width (GetWidth is 0 until laid out)
    scroll:HookScript("OnSizeChanged", function()
        if SettingsUI:SyncWidth() then SettingsUI:RequestRefresh() end
    end)

    self.sections = {}
    for _, def in ipairs(SECTIONS) do self:NewSection(def) end
    self:BuildAlerts(self.sections.alerts)
    self:BuildNotify(self.sections.notify)
    self:BuildGroupRules(self.sections.rules)
    self:BuildRolls(self.sections.rolls)
    self:BuildStrategy(self.sections.strategy)
    self:BuildTooltips(self.sections.tooltips)
    self:BuildMyLog(self.sections.mylog)
    self:BuildMeters(self.sections.meters)
    self:BuildClassTools(self.sections.classtools)
    self:BuildWindow(self.sections.window)
    self:BuildCouncil(self.sections.council)
    self:BuildAttendance(self.sections.attendance)
    self:BuildTutorials(self.sections.tutorials)
    self:BuildDemo(self.sections.demo)
    self:BuildAbout(self.sections.about)

    panel:SetScript("OnShow", function(p)
        if p.dirty then SettingsUI:Refresh() end
    end)
    function panel:OnPanelShown()
        SettingsUI:Refresh()
    end
    self:SelectSection(self.section or "alerts")
    self:Refresh()
    return panel
end

-- Class tools (Core/ClassKit.lua): one section, a card per tool of my class: its header (icon, name, who it is for,
-- the tool's own action, an on/off switch, a chevron) opens and closes its settings. Every card starts closed (open
-- state lasts the session); tools for another spec are grey with "not your spec", tools switched off are dimmed. In
-- demo mode every class's tools show (and work with made-up data). A kit's settings(SettingsUI, body) fills the card
-- with the usual rows (body works as a section of its own) and ends it.
local KIT_HEAD_H, KIT_GAP, KIT_INSET = 46, 8, 14

function SettingsUI:HasClassTools()
    local CK = ns.ClassKit
    if not CK then return false end
    return CK:IsDemo() or #CK:List(CK:MyClass()) > 0
end

local kitOpen = {}   -- key -> true while that card is open (this session only)

local function KitOpen(key) return kitOpen[key] and true or false end

function SettingsUI:BuildClassTools(sec)
    sec.y = sec.y - 2
    sec.lead = self:Subtitle(sec)
    sec.lead:SetTextColor(S:Color("SUB"))
    sec.top = -sec.y + 8
    sec.cards = {}
    for _, kit in ipairs(ns.ClassKit and ns.ClassKit:List() or {}) do
        local key = kit.key
        -- a card (UI:CreateCard) whose header is a row with the shared hover: the tool's icon tile, name, who it is
        -- for, its action, its switch and a chevron
        local card = UI:CreateCard(sec, { pad = 0 })
        card.body:Hide()                -- (the kit's settings get a body of their own, under the header)
        card.kit = kit
        local head = CreateFrame("Button", nil, card)
        head:SetPoint("TOPLEFT")
        head:SetPoint("TOPRIGHT")
        head:SetHeight(KIT_HEAD_H)
        UI:DecorateRow(head)
        local tile = UI:CreateIconTile(head, 28)
        tile:SetPoint("LEFT", head, "LEFT", 10, 0)
        local icon = kit.iconPath or kit.icon
        if type(icon) == "number" and GetSpellTexture then icon = GetSpellTexture(icon) end
        tile:Set(icon)
        head.icon = tile.tex
        head.title = UI:Text(head, "title", "TEXT")
        head.title:SetPoint("TOPLEFT", head, "TOPLEFT", 48, -9)
        head.title:SetText(kit.label)
        head.sub = UI:Text(head, "small")
        head.sub:SetPoint("TOPLEFT", head, "TOPLEFT", 48, -27)
        head.chev = head:CreateTexture(nil, "ARTWORK")
        head.chev:SetSize(12, 12)
        head.chev:SetPoint("RIGHT", head, "RIGHT", -12, 0)
        head.chev:SetTexture(UI.ICON_ATLAS)
        head.chev:SetVertexColor(S:Color("SUB"))
        local sw = ns.UI:CreateSwitch(head, function() return ns.ClassKit:IsOn(key) end, function(a, b)
            ns.ClassKit:SetOn(key, Bool(a, b))
            SettingsUI:LayoutClassTools()
        end)
        sw:SetPoint("RIGHT", head, "RIGHT", -36, 0)
        sw.label = head.title
        sw:Refresh()
        head.switch = sw
        self.refreshers[#self.refreshers + 1] = sw
        if kit.action then
            local btn = ns.UI:CreateSleekButton(head, kit.action.label, kit.action.width or 110, 22,
                function() kit.action.run() end, "primary")
            btn:SetPoint("RIGHT", sw, "LEFT", -14, 0)
            head.action = btn
        end
        head:SetScript("OnClick", function()
            kitOpen[key] = not KitOpen(key) or nil
            SettingsUI:LayoutClassTools()
        end)
        card.head = head
        local body = CreateFrame("Frame", nil, card)
        body:SetPoint("TOPLEFT", head, "BOTTOMLEFT", KIT_INSET, 0)
        body:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", -KIT_INSET, 0)
        body.rows = {}
        body.y = 0
        body.key = key
        if kit.settings then kit.settings(self, body) else body.height = 0 end
        body:SetHeight(max(1, body.height or 0))
        card.body = body
        sec.cards[#sec.cards + 1] = card
    end
    self:LayoutClassTools()
end

-- Stacks the cards (open ones show their settings) and sizes the section.
function SettingsUI:LayoutClassTools()
    local sec = self.sections and self.sections.classtools
    if not sec or not sec.cards then return end
    local CK = ns.ClassKit
    local demo, mine = CK:IsDemo(), CK:MyClass()
    sec.lead:SetText(demo and "Demo mode: every class's tools, with made-up data. Nothing is cast or sent."
        or "Tools for your class and spec. Switch one off to hide it; open a card for its settings.")
    local y = sec.top
    for _, card in ipairs(sec.cards) do
        local kit = card.kit
        if demo or kit.class == mine then
            local open = KitOpen(kit.key)
            local forMe, on = CK:IsMine(kit.key), CK:IsOn(kit.key)
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, -y)
            card:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, -y)
            local bodyH = open and ((card.body.height or 0) + 10) or 0
            card:SetHeight(KIT_HEAD_H + bodyH)
            card.body:SetShown(open)
            card.head.sub:SetText(CK:ForWhom(kit.key) .. (forMe and "" or " · not your spec") .. (on and "" or " · off"))
            local lit = forMe and on
            card.head.title:SetTextColor(S:Color(lit and "TEXT" or "SUB"))
            card.head.icon:SetDesaturated(not lit)
            card.head.icon:SetAlpha(lit and 1 or 0.7)
            card.head.switch:SetChecked(on)
            if card.head.action then card.head.action:SetShown(forMe) end
            -- the chevron points up while open
            UI:SetChevronUp(card.head.chev, open)
            card:Show()
            y = y + KIT_HEAD_H + bodyH + KIT_GAP
        else
            card:Hide()
        end
    end
    sec.height = y
    if self.section == "classtools" then self:FitChild() end
end

-- Opens a class tool's card (its key, e.g. "swing", "bless") in Class tools and scrolls to it.
function SettingsUI:OpenKit(key)
    if not (self.sections and self.sections.classtools) then return end
    kitOpen[key] = true
    self:SelectSection("classtools")
    self:LayoutClassTools()
    for _, card in ipairs(self.sections.classtools.cards) do
        if card.kit.key == key and card:IsShown() and self.scroll then
            local _, _, _, _, y = card:GetPoint(1)
            self.scroll:SetVerticalScroll(max(0, -(tonumber(y) or 0) - 8))
        end
    end
end

-- Is that tool's card shown in Class tools (and the section in the nav)?
function SettingsUI:KitShown(key)
    if not (self.nav and self.nav.classtools and self.nav.classtools:IsShown()) then return false end
    for _, card in ipairs(self.sections.classtools.cards or {}) do
        if card.kit.key == key then return card:IsShown() end
    end
    return false
end

SettingsUI.PlaceText = PlaceText

-- A section with visible() shows only while it returns true (class tools: their class and spec); the nav closes up.
local function SectionVisible(key)
    for _, def in ipairs(SECTIONS) do
        if def.key == key then return not def.visible or def.visible() and true or false end
    end
    return false
end

function SettingsUI:LayoutNav()
    if not self.panel then return end
    local items, sig = {}, ""
    for _, def in ipairs(SECTIONS) do
        if SectionVisible(def.key) then
            items[#items + 1] = { key = def.key, label = def.label }
            sig = sig .. def.key .. ","
        end
    end
    if sig ~= self.navSig then
        self.navSig = sig
        self.rail:SetItems(items)
    end
    for _, def in ipairs(SECTIONS) do self.nav[def.key] = self.rail.byKey[def.key] or self.navHidden end
    if self.section and not SectionVisible(self.section) then self:SelectSection("alerts") end
end

-- Opens one section (key as in SECTIONS); the others hide. The page keeps its size: only the scroll range follows.
function SettingsUI:SelectSection(key)
    if ns.ClassKit and ns.ClassKit:Get(key) and self.sections and not self.sections[key] then
        return self:OpenKit(key)
    end
    if not (self.sections and self.sections[key]) or not SectionVisible(key) then key = "alerts" end
    self.section = key
    if not self.sections then return end
    for k, sec in pairs(self.sections) do sec:SetShown(k == key) end
    if self.rail then self.rail:Select(key) end
    self:FitChild()
    if self.scroll then self.scroll:SetVerticalScroll(0) end
end

function SettingsUI:GetSection()
    return self.section
end

-- The section column's width: the scroll frame's, once it is laid out (BODY_W before).
function SettingsUI:BodyWidth()
    return self.bodyW or BODY_W
end

-- Takes over the scroll frame's real width; true when it changed.
function SettingsUI:SyncWidth()
    local w = self.scroll and tonumber(self.scroll:GetWidth())
    if not w or w <= 100 then return false end
    w = floor(w + 0.5)
    if w == self.bodyW then return false end
    self.bodyW = w
    self.child:SetWidth(w)
    return true
end

function SettingsUI:FitChild()
    local sec = self.sections and self.sections[self.section]
    if sec and self.child then
        self.child:SetHeight(max(BODY_H, sec.height or 0))
        sec:SetHeight(max(BODY_H, sec.height or 0))
    end
end

---------------------------------------------------------------------------
-- The sections
---------------------------------------------------------------------------
function SettingsUI:BuildAlerts(sec)
    sec.y = sec.y - 4
    self:SwitchSetting(sec, "Boss drop panel", "Opens on boss drops for the Loot Council and the master looter.",
        "alerts.councilPanel", true)
    self:SwitchSetting(sec, "\"On your BiS list!\" toast", "A pop-up when something on your list drops.",
        "alerts.personalToast", true)
    self:SwitchSetting(sec, "Sound with drop alerts", "Plays with the toast and the drop panel.", "alerts.sound", true)
    self:SwitchSetting(sec, "Glow on BiS loot buttons", "Your list's items glow in the loot window.",
        "alerts.glow", true)
    self:SwitchSetting(sec, "Chat message for BiS drops", "A line in your chat, for when the toast is missed.",
        "alerts.chat", true)
    self:SwitchSetting(sec, "BiS badges on the loot window",
        "Marks your items; on the Loot Council also how many raiders need each one.", "alerts.lootBadges", true)
    self:SwitchSetting(sec, "Off-spec items too", "The alerts above also fire for your off-spec list.",
        "alerts.offspec", true)
    self:DropdownSetting(sec, "Drop panel position", "Next to the loot window, or where you left it.",
        "dropPanelMode", "auto", {
            { value = "auto", text = "Attach to the loot window" },
            { value = "floating", text = "Always floating" },
        })
    self:DropdownSetting(sec, "Announce channel", "Where awards and rolls are announced in a raid.",
        "announceChannel", "RAID", {
            { value = "RAID", text = "Raid" },
            { value = "RAID_WARNING", text = "Raid Warning" },
        }, "Raid Warning needs raid lead or assist; without them announcements go to Raid.")
    self:EndSection(sec)
end

-- Notifications (Core/Notify.lua, UI/Notify.lua): the bell keeps everything; these decide what interrupts. One row per
-- kind the sections registered, three switches each (pop-up, sound, chat line) under the columns' names.
local NOTIFY_COLS = { { what = "popup", label = "Pop-up" }, { what = "sound", label = "Sound" }, { what = "chat", label = "Chat" } }
local NOTIFY_COL_W = 58

function SettingsUI:BuildNotify(sec)
    local N = ns.Notify
    sec.y = sec.y - 4
    local function quiet(field)
        return function()
            local s = N and N.Settings()
            if not s then return false end
            if field == "quietCombat" then return s.quietCombat ~= false end
            return s[field] and true or false
        end, function(a, b)
            local s = N and N.Settings(true)
            if s then s[field] = Bool(a, b) end
            ns:Fire("SETTINGS_CHANGED", "notify")
        end
    end
    local g, st = quiet("quietCombat")
    self:Switch(sec, "Quiet in combat", "Pop-ups wait until the fight is over (boss fights too).", g, st)
    g, st = quiet("quietOpen")
    self:Switch(sec, "Quiet while the window is open", "Only the bell counts up while DisasterZone is open.", g, st)
    self:Switch(sec, "Pause pop-ups for an hour", "Nothing pops up or plays a sound; the bell still collects.",
        function()
            local s = N and N.Settings()
            return s and (tonumber(s.dndUntil) or 0) > time() or false
        end,
        function(a, b)
            local s = N and N.Settings(true)
            if s then s.dndUntil = Bool(a, b) and (time() + 3600) or nil end
        end)
    local kinds = N and N:GetKinds() or {}
    if #kinds == 0 then
        self:EndSection(sec)
        return
    end
    -- the columns' names over the switches
    local head = CreateFrame("Frame", nil, sec)
    head:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - 10)
    head:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y - 10)
    head:SetHeight(18)
    for i, col in ipairs(NOTIFY_COLS) do
        local fs = UI:Text(head, "small", nil, { justify = "CENTER", width = NOTIFY_COL_W })
        fs:SetPoint("RIGHT", head, "RIGHT", -(#NOTIFY_COLS - i) * NOTIFY_COL_W + (NOTIFY_COL_W - SWITCH_W) / 2 - 2, 0)
        fs:SetText(col.label)
    end
    sec.y = sec.y - 28
    for _, def in ipairs(kinds) do
        local row = self:Row(sec, def.label, def.desc)
        for i, col in ipairs(NOTIFY_COLS) do
            local kind, what = def.kind, col.what
            local sw = ns.UI:CreateSwitch(row, function() return N:Wants(kind, what) end,
                function(a, b) N:SetWants(kind, what, Bool(a, b)) end)
            sw:SetPoint("RIGHT", row, "RIGHT", -(#NOTIFY_COLS - i) * NOTIFY_COL_W, 0)
            sw.label = row.title
            self.refreshers[#self.refreshers + 1] = sw
        end
        PlaceText(row, #NOTIFY_COLS * NOTIFY_COL_W - (NOTIFY_COL_W - SWITCH_W))
    end
    self:EndSection(sec)
end

-- Group loot rules (ADDENDUM D §24-§27, ADDENDUM E §32): the loot leader of the group decides these for everyone in
-- it. The line under the title says whose values are in effect; while they come from someone else every rule shows
-- its value as text.
local RULES_TIP = "The group's loot leader sets these for everyone in the group: in a raid the raid leader (else "
    .. "the master looter); in a party the leader if on the Loot Council or if they turned dungeon mode on (else a "
    .. "council member). Without one, your own values apply. /dz rules prints the rules in effect."

function SettingsUI:BuildGroupRules(sec)
    -- whose values are in effect: read-only while they come from the group's loot leader
    self.rulesNotice = self:Notice(sec, "info")
    self.rulesStatus = self.rulesNotice.text
    AddTooltip(self.rulesNotice, "Group loot rules", RULES_TIP)

    local durations = {}
    for _, s in ipairs({ 15, 20, 30, 45, 60 }) do durations[#durations + 1] = { value = s, text = s .. " seconds" } end
    local _, r1 = self:RuleDropdown(sec, "Roll duration", "How long a roll stays open.", "roll.duration", 30, durations)
    local _, r2 = self:RuleDropdown(sec, "Minimum quality", "Raid drops below it get no drop panel, alerts or rolls.",
        "qualityThreshold", 4, {
            { value = 4, text = "Epic" },
            { value = 3, text = "Rare" },
        })
    local phaseDD, r3 = self:Dropdown(sec, "Raid phase", "The group's phase: council views, tooltips and alerts follow it.",
        GroupPhaseOptions,
        function() return SettingsUI:GroupPhaseSelected() end,
        function(a, b)
            if not SettingsUI:GroupPhaseEditable() then return end
            local v = tonumber(Value(a, b))
            Set("groupPhase", (v and v >= 1 and v <= MaxPhase()) and v or nil)
        end,
        "As the group's loot leader you send it with the loot rules: everyone's council views, tooltips and drop "
        .. "alerts follow it (unless they picked their own view phase). \"Use guild phase\" keeps the Guild Master's.")
    self.phaseRuleDD = phaseDD

    -- ADDENDUM F §38: the raid leader locks / unlocks every BiS list in the group for the raid. The button is there
    -- for whoever may use it; everyone else reads the state.
    local lockRow = self:Row(sec, "BiS lists", "")
    self.lockRow = lockRow
    if ns.UI.CreateBiSLockButton then
        self.lockBtn = ns.UI:CreateBiSLockButton(lockRow, 128, 22)
        self.lockBtn:SetPoint("RIGHT", lockRow, "RIGHT", 0, 0)
    end
    self.lockStatus = lockRow.desc
    PlaceText(lockRow, 128)

    self.dungeonCheck, self.dungeonRow = self:Switch(sec, "Dungeon mode (5-man parties)", "",
        function() return Effective("dungeon.enabled", false) and true or false end,
        function(a, b)
            if SettingsUI:GroupRulesEditable() then
                SettingsUI:SetDungeonMode(Bool(a, b))
            else
                SettingsUI:RequestRefresh()
            end
        end,
        "Boss drops and DisasterZone rolls work in a 5-man party like in a raid (also /dz dungeon on|off). "
        .. "Dungeon awards are tagged (dungeon) in the loot log.")
    self.ruleControls[#self.ruleControls + 1] = self.dungeonCheck
    -- its line under the name is the live state ("Status: Active — enabled by Lee")
    local drow = self.dungeonRow
    drow.isSwitch = true
    self.dungeonStatus = drow.desc
    local _, r6 = self:RuleDropdown(sec, "Dungeon minimum quality", "Drops below it are skipped in 5-man dungeons.",
        "dungeon.quality", 3, {
            { value = 3, text = "Rare" },
            { value = 4, text = "Epic" },
        })
    self.ruleRows = { r1, r2, drow, r6 }
    self.phaseRow = r3
    self:EndSection(sec)
end

function SettingsUI:BuildRolls(sec)
    sec.y = sec.y - 4
    self:SwitchSetting(sec, "Announce rolls and winners", "Roll starts and winners go to raid chat.",
        "roll.announce", true)
    self:SwitchSetting(sec, "Roll / Pass popup", "Pops up when a roll starts, so you can roll or pass.",
        "roll.popup", true)
    self:EndSection(sec)
    local note = UI:Text(sec, "small", nil, { wrap = true })
    note:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - 14)
    note:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y - 14)
    note:SetText("Everyone in the raid may roll. BiS mains win first, then BiS alts, then everyone else; the "
        .. "council confirms. Start a roll from the boss drop panel or with /dz roll [item].")
    sec.height = -sec.y + 14 + 30
end

function SettingsUI:BuildStrategy(sec)
    sec.y = sec.y - 4
    self:SwitchSetting(sec, "Auto-mark the planned mobs",
        "When you lead the raid, the board's raid marks go on the mobs. Needs enemy nameplates on.",
        "strategy.autoMark", true,
        "The marks are the raid mark badges on the board's boss portraits. /dz strat debug prints what the helpers see.")
    self:SwitchSetting(sec, "Show my jobs near a planned boss",
        "A reminder of your jobs when you get close to a boss with a picked strategy.", "strategy.reminder", true)
    self:EndSection(sec)
end

function SettingsUI:BuildTooltips(sec)
    sec.y = sec.y - 4
    self:SwitchSetting(sec, "DisasterZone lines on item tooltips", "Whether an item is on your BiS list.",
        "tooltip.enabled", true)
    self:SwitchSetting(sec, "Who wants it (Loot Council)", "Council members see everyone who has the item on a list.",
        "tooltip.council", true)
    local nameOptions = {}
    for _, n in ipairs({ 3, 5, 8, 12 }) do nameOptions[#nameOptions + 1] = { value = n, text = tostring(n) } end
    self:DropdownSetting(sec, "Names shown", "Hold Shift over an item to see every name.", "tooltip.maxNames", 5,
        nameOptions)
    self:EndSection(sec)
end

function SettingsUI:BuildWindow(sec)
    sec.y = sec.y - 4
    self:DropdownSetting(sec, "Open on", "What the window shows when you open it.", "openOn", "home", {
        { value = "home", text = "Home (dashboard)" },
        { value = "last", text = "The tab used last" },
    })
    self:Dropdown(sec, "View phase", "The phase your council views, tooltips and drop alerts use.", ViewPhaseOptions,
        function() return tonumber(Get("viewPhase", nil)) or 0 end,
        function(a, b)
            local v = tonumber(Value(a, b))
            Set("viewPhase", (v and v >= 1 and v <= MaxPhase()) and v or nil)
        end)
    self:Switch(sec, "Minimap button", "Click opens this window, right-click Settings, Shift-click the boss drops.",
        function() return not Get("minimap.hide", false) end,
        function(a, b)
            local shown = Bool(a, b)
            Set("minimap.hide", not shown)
            SetMinimapShown(shown)
        end)
    self:EndSection(sec)
end

-- My Log (Core/MyLog.lua): the opt-in switch, heroics, how long pulls are kept, and Delete (click twice).
function SettingsUI:BuildMyLog(sec)
    sec.y = sec.y - 4
    self:SwitchSetting(sec, "Record my raid performance",
        "Your own damage, healing, casts and deaths in every boss pull. Saved on this PC only, never sent.",
        "mylog.enabled", false,
        "Nobody else can see that you use it or read your numbers, the loot council included. Turn it off and "
            .. "recording stops at once. /dz mylog last prints your latest pull.")
    self:SwitchSetting(sec, "Heroic dungeons too", "Also record heroic 5-man bosses.", "mylog.heroics", false)
    local weeks = {}
    for _, n in ipairs({ 4, 8, 12, 26, 52 }) do weeks[#weeks + 1] = { value = n, text = n .. " weeks" } end
    self:DropdownSetting(sec, "Keep pulls for", "Older pulls are deleted. The newest kills keep every detail.",
        "mylog.keepWeeks", 12, weeks)
    local row = self:Row(sec, "Stored pulls", "")
    local armed, del
    local function disarm()
        armed = nil
        del:SetText("Delete all my logs")
    end
    del = ns.UI:CreateSleekButton(row, "Delete all my logs", 150, 22, function()
        if armed then
            disarm()
            if ns.MyLog then ns.MyLog:DeleteAll() end
            return
        end
        local token = {}
        armed = token
        del:SetText("Click again to delete")
        C_Timer.After(4, function() if armed == token then disarm() end end)
    end)
    del:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.hasDesc = true
    PlaceText(row, 150)
    self.refreshers[#self.refreshers + 1] = {
        Refresh = function()
            local n, chars = 0, 0
            local db = DisasterZoneLogDB
            if type(db) == "table" and type(db.chars) == "table" then
                for _, c in pairs(db.chars) do
                    chars = chars + 1
                    n = n + #(c.pulls or {})
                end
            end
            row.desc:SetText(n == 0 and "None yet."
                or string.format("%d pull%s on %d character%s.", n, n == 1 and "" or "s", chars, chars == 1 and "" or "s"))
            del:SetEnabled(n > 0 or armed ~= nil)
        end,
    }
    self:EndSection(sec)
end

-- Meters (Core/Meter.lua, Core/Threat.lua): a switch per window, then their options in three groups. An option is
-- dimmed and locked while the window it belongs to is off (the shared ones while both are off).
function SettingsUI:BuildMeters(sec)
    local sub = self:Subtitle(sec)
    sub:SetText("Damage and threat in panels that dock together. Your own combat log only; nothing is shared or posted.")
    sub:SetTextColor(S:Color("SUB"))
    local groups = { dmg = {}, thr = {}, both = {} }
    -- a group of the section: a section header with the meter's icon
    local function Head(text, icon)
        local h = UI:CreateSectionHeader(sec, (icon and ("|T" .. icon .. ":16:16:0:0:64:64:5:59:5:59|t  ") or "") .. text)
        h:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - 10)
        h:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y - 10)
        sec.y = sec.y - 38
    end
    local function Track(g, ctrl, row) groups[g][#groups[g] + 1] = { ctrl = ctrl, row = row } end

    Head("Damage meter", "Interface\\Icons\\Ability_Warrior_SavageBlow")
    self:SwitchSetting(sec, "Show the damage meter",
        "Damage, healing, taken, deaths, interrupts, dispels and active time for your group.", "meters.dmg", false,
        "Hover a bar for a player's top abilities, click it for the full breakdown. /dz meter shows or hides it.")
    Track("dmg", self:DropdownSetting(sec, "Fights to keep", "Older fights drop off the list. Whole raid always stays.",
        "meters.keep", 25, { { value = 10, text = "Last 10" }, { value = 25, text = "Last 25" }, { value = 50, text = "Last 50" } }))
    Track("dmg", self:DropdownSetting(sec, "Start a new fight on", "Boss pulls always start their own fight.",
        "meters.split", "all", { { value = "all", text = "Every combat" }, { value = "boss", text = "Boss pulls only" } }))
    Track("dmg", self:DropdownSetting(sec, "Per second by", "Fight time ranks like the totals; active time leaves out idle gaps.",
        "meters.rate", "fight", { { value = "fight", text = "Fight time" }, { value = "active", text = "Active time" } },
        "Fight time: damage over the fight's length, as Warcraft Logs counts it. Active time: over the time each player "
            .. "was doing something, as Details counts it by default; it favours players who stood idle."))
    local row = self:Row(sec, "Clear all fights", "Empties the fight list and Whole raid.")
    local armed, clr
    local function disarm() armed = nil; clr:SetText("Clear") end
    clr = ns.UI:CreateSleekButton(row, "Clear", 120, 22, function()
        if armed then
            disarm()
            if ns.Meter then ns.Meter:ClearAll() end
            return
        end
        local token = {}
        armed = token
        clr:SetText("Click again")
        C_Timer.After(4, function() if armed == token then disarm() end end)
    end)
    clr:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.control = clr
    PlaceText(row, 120)
    Track("dmg", clr, row)

    Head("Threat meter", "Interface\\Icons\\Ability_Warrior_DefensiveStance")
    self:SwitchSetting(sec, "Show the threat meter", "Your target's threat table, from the game itself, with your pull point.",
        "meters.thr", false, "The same numbers ThreatClassic2 reads. /dz threat shows or hides it.")
    Track("thr", self:DropdownSetting(sec, "Warn me at",
        "Share of your pull point. Melee pulls at 110% of the tank, ranged at 130%.", "meters.warn", 85,
        { { value = 0, text = "Never" }, { value = 75, text = "75%" }, { value = 85, text = "85%" },
          { value = 90, text = "90%" }, { value = 95, text = "95%" } }))
    Track("thr", self:SwitchSetting(sec, "Warning sound", "Plays once each time you cross the line.", "meters.sound", true))
    Track("thr", self:SwitchSetting(sec, "Flash the screen edges", "A soft red pulse while you stay over the line.",
        "meters.flash", true))
    Track("thr", self:DropdownSetting(sec, "Tank view", "Shows how close each player is to their own pull point.",
        "meters.tankView", "auto", { { value = "auto", text = "While I tank" }, { value = "always", text = "Always" },
                                     { value = "never", text = "Never" } }))

    -- the look (UI/MeterTheme.lua): a theme, then overrides on top of it
    Head("Look", nil)
    if ns.MeterTheme then
        local strip, trow = ns.MeterTheme:SettingsTiles(self, sec)
        Track("both", nil, trow)
        Track("both", nil, strip)
    end
    Track("both", self:DropdownSetting(sec, "Bar colour", "What colours the bars.", "meters.barColor", "class",
        { { value = "class", text = "Class colour" }, { value = "role", text = "Role colour" },
          { value = "one", text = "One colour" } }))
    Track("both", self:DropdownSetting(sec, "Icons", "The picture in front of each name.", "meters.icons", "theme",
        { { value = "theme", text = "Theme default" }, { value = "spec", text = "Spec" }, { value = "class", text = "Class" },
          { value = "none", text = "None" } }))
    Track("both", self:DropdownSetting(sec, "Rows", "Bar height; the theme sets its own.", "meters.rowSize", "theme",
        { { value = "compact", text = "Compact" }, { value = "theme", text = "Theme default" }, { value = "roomy", text = "Roomy" } }))
    Track("both", self:DropdownSetting(sec, "Numbers", "How amounts are written.", "meters.numbers", "short",
        { { value = "short", text = "380.1k" }, { value = "full", text = "380,112" }, { value = "round", text = "380k" } }))
    Track("both", self:DropdownSetting(sec, "Background", "How dark the panels are behind the bars.", "meters.bg", "theme",
        { { value = "theme", text = "Theme default" }, { value = 0, text = "None" }, { value = 25, text = "25%" },
          { value = 50, text = "50%" }, { value = 75, text = "75%" }, { value = 90, text = "90%" } }))
    Track("both", self:DropdownSetting(sec, "Size", "Bar height and text size together.", "meters.size", "normal",
        { { value = "small", text = "Small" }, { value = "normal", text = "Normal" }, { value = "large", text = "Large" } }))

    Head("Panels", nil)
    Track("both", self:DropdownSetting(sec, "Show them", "When the panels appear on their own.", "meters.show", "group",
        { { value = "group", text = "In a group" }, { value = "instance", text = "In instances" },
          { value = "always", text = "Always" } }))
    Track("both", self:DropdownSetting(sec, "Out of combat", "What the panels do a few seconds after a fight.",
        "meters.ooc", "fade", { { value = "fade", text = "Fade" }, { value = "hide", text = "Hide" },
                                { value = "stay", text = "Stay" } }))
    Track("both", self:SwitchSetting(sec, "Lock panels", "Unlock to move, dock and resize them.", "meters.locked", true,
        "Unlocked, drag a header next to another panel to dock it, or onto its header to make a tab. + on a header adds a panel."))
    local lrow = self:Row(sec, "Reset layout", "Back to one stack: Threat over Damage done.")
    local lbtn = ns.UI:CreateSleekButton(lrow, "Reset", 120, 22, function()
        if ns.MeterPanels then ns.MeterPanels:ResetLayout() end
    end)
    lbtn:SetPoint("RIGHT", lrow, "RIGHT", 0, 0)
    lrow.control = lbtn
    PlaceText(lrow, 120)
    Track("both", lbtn, lrow)
    self:EndSection(sec)

    self.refreshers[#self.refreshers + 1] = {
        Refresh = function()
            local dmg, thr = Get("meters.dmg", false), Get("meters.thr", false)
            local on = { dmg = dmg, thr = thr, both = dmg or thr }
            for g, list in pairs(groups) do
                for _, e in ipairs(list) do
                    local enabled = on[g] and true or false
                    if e.ctrl and e.ctrl.SetEnabled then e.ctrl:SetEnabled(enabled) end
                    if e.row then e.row:SetAlpha(enabled and 1 or 0.42) end
                end
            end
        end,
    }
end

-- Tutorials (1.3.5): the Welcome tour's parts for my roles (done / where I stopped / not started, with Start, Go on
-- or Again), a look at the other roles' parts on demo data, the strategy board's tutorial, new-role offers on or off,
-- and for the Guild Master the set-up checklist (each open item opens its page). Rows are made once and laid out
-- again on every refresh (my roles can change).
local TUT_BTN_W = 86

function SettingsUI:BuildTutorials(sec)
    local W = ns.WelcomeTour
    sec.y = sec.y - 4
    local sub = self:Subtitle(sec)
    sub:SetText("Short tours on the real windows. Nothing you do in one is sent to the guild.")
    sec.top = sec.y
    local t = { parts = {}, setup = {} }
    self.tut = t
    local function rowWithButton(title, label, onClick)
        local row = self:Row(sec, title, " ")
        local b = ns.UI:CreateSleekButton(row, label, TUT_BTN_W, 22, onClick)
        b:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.btn = b
        PlaceText(row, TUT_BTN_W)
        return row
    end
    for _, key in ipairs(W and W.ORDER or {}) do
        t.parts[key] = rowWithButton(W.PARTS[key].label, "Start", function()
            if ns.WelcomeTour then ns.WelcomeTour:StartPart(key) end
        end)
    end
    t.peek = rowWithButton("Other roles", "Look around", function(b) SettingsUI:OpenTourPeekMenu(b) end)
    t.strategy = rowWithButton("Strategy board", "Open", function()
        local T = ns.Tour
        if not (T and T:Start("strategy")) then ns:Print("Open Raids > Strategies to start the strategy board's tutorial.") end
    end)
    local _, offers = self:Switch(sec, "Offer a part when I get a new role",
        "Once per role: when you become an officer, a raid leader or join the guild council.",
        function() return ns.WelcomeTour and ns.WelcomeTour:RoleOffersOn() or false end,
        function(a, b) if ns.WelcomeTour then ns.WelcomeTour:SetRoleOffers(Bool(a, b)) end end)
    t.offers = offers
    -- the GM's checklist
    t.setupHead = self:Row(sec, "Set up your guild", " ")
    t.setupHead.title:SetTextColor(S:Color("GOLD"))
    local hide = ns.UI:CreateSwitch(t.setupHead,
        function() return not (ns.WelcomeTour and ns.WelcomeTour:IsSetupHidden()) end,
        function(a, b) if ns.WelcomeTour then ns.WelcomeTour:SetSetupHidden(not Bool(a, b)) end end)
    hide:SetPoint("RIGHT", t.setupHead, "RIGHT", 0, 0)
    t.setupHead.control = hide
    self.refreshers[#self.refreshers + 1] = hide
    PlaceText(t.setupHead, SWITCH_W)
    AddTooltip(hide, "On Home", "A chip on Home says how much is left, until it is all done.")
    for i = 1, 5 do
        t.setup[i] = rowWithButton("", "Open", function(b)
            local it = b:GetParent().item
            if it and it.open then it.open() end
        end)
    end
    self:EndSection(sec)
end

-- Scrolls Settings > Tutorials so the GM's checklist is in view (the Welcome tour's last GM step); returns the rows.
function SettingsUI:ShowSetupChecklist()
    self:SelectSection("tutorials")
    self:Refresh()
    local t = self.tut
    if not (t and t.setupHead and t.setupHead:IsShown()) then return nil end
    if self.scroll and t.setupHead.y then self.scroll:SetVerticalScroll(max(0, -t.setupHead.y - 8)) end
    return t.setupHead, t.setup
end

-- The other roles' parts, to look at on demo data.
function SettingsUI:OpenTourPeekMenu(owner)
    local W = ns.WelcomeTour
    if not W then return end
    local mine = W:Roles()
    ns.UI:ContextMenu(owner, function(root)
        root:CreateTitle("A look around, on demo data")
        for _, key in ipairs(W.ORDER) do
            if not mine[key] then
                root:CreateButton(W.PARTS[key].label, function() W:StartPart(key, true) end)
            end
        end
    end)
end

function SettingsUI:RefreshTutorials()
    local t, sec, W = self.tut, self.sections and self.sections.tutorials, ns.WelcomeTour
    if not (t and sec and W) then return end
    local y = sec.top
    local function put(row, on)
        row:SetShown(on)
        if not on then return end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, y)
        row.y = y
        if row.line then row.line:Show() end
        y = y - ROW_H
    end
    local mine, others = W:Roles(), 0
    for _, key in ipairs(W.ORDER) do
        local row = t.parts[key]
        local state, n, steps = W:PartState(key)
        if state == "done" then
            row.desc:SetText(S:Wrap("OK", "Done") .. Grey(" · " .. steps .. " steps"))
            row.btn:SetText("Again")
        elseif state == "at" then
            row.desc:SetText(S:Wrap("GOLD", format("Step %d of %d", n, steps)) .. Grey(" · " .. W.PARTS[key].line))
            row.btn:SetText("Go on")
        else
            row.desc:SetText(Grey(W.PARTS[key].line))
            row.btn:SetText("Start")
        end
        local c = W.PARTS[key].color
        row.title:SetTextColor(c[1], c[2], c[3])
        put(row, mine[key] == true)
        if not mine[key] then others = others + 1 end
    end
    t.peek.desc:SetText(Grey("What the other roles see and do, on demo data. Nothing changes."))
    put(t.peek, others > 0)
    local TR, p = ns.Tour, ns.Tour and ns.Tour:Peek("strategy")
    local def = TR and TR:Get("strategy")
    local total, done = def and #def.chapters or 0, 0
    for _ in pairs(p and p.done or {}) do done = done + 1 end
    t.strategy.desc:SetText(Grey(format("%d chapters on a practice board: drawing, the room in 3D, jobs, reading a plan"
        .. " · %d done", total, done)))
    put(t.strategy, def ~= nil)
    put(t.offers, true)
    local gm = mine.gm == true
    local list = gm and W:Checklist() or {}
    local n = 0
    for _, it in ipairs(list) do if it.done then n = n + 1 end end
    t.setupHead.desc:SetText(Grey(format("%d of %d done · shown on Home until then", n, #list)))
    y = y - 10
    put(t.setupHead, gm)
    for i, row in ipairs(t.setup) do
        local it = list[i]
        row.item = it
        if it then
            row.title:SetText((it.done and "|TInterface\\RAIDFRAME\\ReadyCheck-Ready:14|t " or "") .. it.label)
            row.title:SetTextColor(S:Color(it.done and "SUB" or "TEXT"))
            row.desc:SetText(Grey(it.sub or ""))
            row.btn:SetShown(not it.done)
            row.btn:SetText(it.where or "Open")
        end
        put(row, it ~= nil)
    end
    sec.height = -y + 8
end

function SettingsUI:BuildDemo(sec)
    sec.y = sec.y - 4
    self:Switch(sec, "Demo data", "Fake guild members and a raid to try the council views solo. Never saved or sent.",
        function() return (ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()) and true or false end,
        function(a, b)
            if ns.Demo and ns.Demo.SetEnabled then ns.Demo:SetEnabled(Bool(a, b)) end
        end)
    self:EndSection(sec)
    local y = sec.y - 16
    local sim = ns.UI:CreateSleekButton(sec, "Simulate a boss drop", nil, 22, function()
        if ns.Loot and ns.Loot.SimulateDrop then ns.Loot:SimulateDrop() end
    end)
    Put(sim, sec, 0, y)
    AddTooltip(sim, "Simulate a boss drop", "Opens the drop panel with a made-up boss drop. In demo mode, click Roll "
        .. "on any of its items to watch a roll.")
    local demoRoll
    demoRoll = ns.UI:CreateSleekButton(sec, "Demo a roll", nil, 22, function() SettingsUI:OpenDemoRollMenu(demoRoll) end)
    demoRoll:SetPoint("LEFT", sim, "RIGHT", 8, 0)
    AddTooltip(demoRoll, "Demo a roll", "Turns on demo mode and starts a roll the demo raid answers: a random prized "
        .. "drop, or a scenario that shows one of the guild's loot rules (also /dz demo <name>). Nothing is sent.")
    local recent = ns.UI:CreateSleekButton(sec, "Recent drops", nil, 22, function()
        if ns.DropPanel and ns.DropPanel.ShowHistory then ns.DropPanel:ShowHistory() end
    end)
    recent:SetPoint("LEFT", demoRoll, "RIGHT", 8, 0)
    AddTooltip(recent, "Recent drops", "The boss drops seen this session, in the drop panel.")
    sec.height = -(y - 22) + 8
end

function SettingsUI:BuildAbout(sec)
    sec.y = sec.y - 4
    local vrow = self:Row(sec, "", "")
    self.aboutText = vrow.title
    self.aboutPeers = vrow.desc
    local srow = self:Row(sec, "BiS list sharing", "")
    self.aboutSync = srow.desc
    local syncBtn = ns.UI:CreateSleekButton(srow, "Request sync", 112, 22, function()
        if ns.Sync and ns.Sync.RequestSync then ns.Sync:RequestSync() end
    end)
    syncBtn:SetPoint("RIGHT", srow, "RIGHT", 0, 0)
    PlaceText(srow, 112)
    self:SwitchSetting(sec, "Debug messages in chat", "Extra lines in your chat for tracking down problems.",
        "debug", false)
    -- the Performance page (Core/Perf.lua): per character, after a /reload (its hooks go in while the files load)
    local P = ns.Perf
    if P and P.IsWanted then
        local _, row = self:Switch(sec, "Performance page",
            "DisasterZone's memory, garbage and CPU on this character, for tracking down problems. After a /reload.",
            function() return P:IsWanted() end,
            function(a, b)
                P:SetWanted(Bool(a, b))
                if P:IsWanted() ~= P:IsOn() then
                    ns:Print("The Performance page %s after a /reload.", P:IsWanted() and "comes" or "goes")
                end
            end,
            "An icon at the right of the top strip: memory, garbage a minute, CPU, addon messages, and Measure 30 s "
                .. "to find what makes garbage. It costs a little while it is on (a memory sample every 10 s), so leave "
                .. "it off unless you are looking into something. Only on this character.")
        self.perfRow = row
        if P:IsDev() and row.control then row.control:SetEnabled(false) end
    end
    self:EndSection(sec)
end

-- 1.3.5: the Demo a roll menu - a random prized drop, or one of the scenarios (Core/DemoScenarios.lua).
function SettingsUI:OpenDemoRollMenu(owner)
    local D = ns.Demo
    ns.UI:ContextMenu(owner, function(root)
        root:CreateButton("Random prized drop", function() SettingsUI:DemoRoll() end)
        root:CreateDivider()
        root:CreateTitle("Loot rules scenarios")
        for _, def in ipairs(D and D.SCENARIOS or {}) do
            local b = root:CreateButton(def.label, function()
                local ok, err = D:RunScenario(def.key)
                if not ok then ns:Print("Demo scenario not started: %s", tostring(err)) end
            end)
            b:SetTitleAndTextTooltip(def.label, def.desc)
        end
    end)
end

-- "Demo a roll": demo mode on, a simulated drop, and a local roll on its first item.
function SettingsUI:DemoRoll()
    if ns.Demo and ns.Demo.ClearScenario then ns.Demo:ClearScenario() end
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
    L:SimulateDrop({ prized = true })   -- (1.3.5: the roll is on a prized item; in demo mode I meet its rules)
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

-- The dungeon mode switch: through the core's toggle when it has one (it also tells the party), else the plain
-- setting (the core reacts to SETTINGS_CHANGED "dungeon.enabled").
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

-- "Status: Active — enabled by X" / "Status: Inactive (not in a 5-man party)".
function SettingsUI:DungeonStatusText()
    if DungeonModeActive() then
        local who, extra = nil, ""
        local by = DungeonEnabledBy()
        local rulesStatus, rulesFrom = self:GroupRulesStatus()
        if rulesStatus == "remote" and Effective("dungeon.enabled", false) then
            who = rulesFrom and NameOf(rulesFrom) or nil
        elseif Get("dungeon.enabled", false) then
            who = "you"
            -- only my client uses it unless I may tell the party (leader / council) or someone did
            local D = ns.Dungeon
            if not by and rulesStatus ~= "mine" and type(D) == "table" and type(D.CanTellParty) == "function" then
                local ok, can = pcall(D.CanTellParty, D)
                if ok and not can then extra = Grey(" (only for you)") end
            end
        elseif by then
            who = IsMe(by) and "you" or NameOf(by)
        end
        return Grey("Status: ") .. S:Wrap("OK", who and ("Active — enabled by " .. who) or "Active") .. extra
    end
    local reason
    if _G.IsInRaid and _G.IsInRaid() then
        reason = "Inactive (in a raid: raid rules apply)"
    elseif not InGroup() then
        reason = "Inactive (not in a 5-man party)"
    else
        reason = "Inactive (not turned on for this party)"
    end
    return Grey("Status: " .. reason)
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
    elseif status == "mine" then
        return S:Wrap("OK", "You set these for your group") .. Grey(" (changes are sent to everyone in it)")
    end
    if InGroup() then
        return "Your own settings" .. Grey(" (no loot leader with DisasterZone in this group)")
    end
    return "Your own settings" .. Grey(" (not in a group)")
end

-- The state of the group's BiS lists (ADDENDUM F §38), under "BiS lists".
function SettingsUI:LockStatusText()
    if not (UI and UI.GetBiSLock) then return "" end
    local locked, info = UI:GetBiSLock()
    if locked then
        return S:Wrap("WARN", "Locked by " .. UI:LockByText(info, true))
            .. Grey(": nobody can change their list until it is unlocked")
    end
    if not (_G.IsInRaid and _G.IsInRaid()) then return "Unlocked" .. Grey(" (the raid leader can lock them in a raid)") end
    if UI.CanSetBiSLock and UI:CanSetBiSLock() then
        return "Unlocked" .. Grey(" (locking stops list changes until you unlock or the raid ends)")
    end
    -- 1.3: the raid leader can't lock yet either: the lock needs a raid started with the loot council
    local GR = ns.GroupRules
    if GR and GR.IsAuthority and GR:IsAuthority() then
        return "Unlocked" .. Grey(" (locking needs a raid started with the loot council)")
    end
    return "Unlocked" .. Grey(" (raid leader only)")
end

local function DropdownText(dd)
    if dd.Refresh then dd:Refresh() end
    return dd:GetText() or ""
end

function SettingsUI:RefreshGroupRules()
    local status = self:GroupRulesStatus()
    local remote = status == "remote"
    if self.rulesNotice then
        self.rulesNotice:SetNotice(remote and "readonly" or "info", self:GroupRulesStatusText())
    end
    for _, row in ipairs(self.ruleRows or {}) do
        local c = row.control
        local text
        if row.isSwitch then
            text = Effective("dungeon.enabled", false) and "On" or "Off"
        elseif c then
            text = DropdownText(c)
        end
        SetReadOnly(row, remote, text)
    end
    if self.phaseRow then
        SetReadOnly(self.phaseRow, not self:GroupPhaseEditable(), DropdownText(self.phaseRuleDD))
    end
    if self.lockBtn and self.lockBtn.Refresh then self.lockBtn:Refresh() end
    if self.lockStatus then self.lockStatus:SetText(self:LockStatusText()) end
end

-- "Version 1.3.0 · protocol 1"; peers seen; how my BiS list is shared.
function SettingsUI:RefreshAbout()
    local fs = self.aboutText
    if not fs then return end
    local SY = ns.Sync
    local peers = SY and SY.GetVersions and SY:GetVersions()
    local online = SY and SY.GetOnlineCouncilPeers and SY:GetOnlineCouncilPeers()
    local status = (SY and SY.GetStatusText and SY:GetStatusText()) or ""
    status = tostring(status):gsub("\226\128\166$", ""):gsub("%.%.%.$", "")
    local nPeers = type(peers) == "table" and #peers or 0
    local nOnline = type(online) == "table" and #online or 0
    fs:SetText(format("Version %s", tostring(ns.version or "?")) .. Grey(" · protocol " .. tostring(ns.PROTO or "?")))
    if self.aboutPeers then
        self.aboutPeers:SetText(format("%d %s with DisasterZone seen · %d council %s online", nPeers,
            nPeers == 1 and "player" or "players", nOnline, nOnline == 1 and "member" or "members"))
    end
    if self.aboutSync then self.aboutSync:SetText(status ~= "" and status or "Not in a guild") end
end

---------------------------------------------------------------------------
-- Loot Council section: read-only summary for everyone + "Edit council..." (ADDENDUM E §30)
---------------------------------------------------------------------------
-- (UI:AttachTooltip's builder: the name, rank, online and why they are on the council)
local function MemberTip(self, tt)
    if not self.key then return false end
    tt:AddLine(ColoredName(self.key))
    local G = ns.Guild
    local rank = G and G.GetRankName and G:GetRankName(self.key)
    if rank then tt:AddLine(rank, S:RGB("TEXT")) end
    tt:AddLine(self.online and "Online" or "Offline", S:RGB("SUB"))
    if self.fixed == "Master looter" then
        tt:AddLine("Master looter: on this raid's council while the raid runs the loot council", S:RGB("SUB"))
    elseif self.fixed then
        tt:AddLine(self.fixed .. ": always on the council", S:RGB("SUB"))
    end
end

-- A council member: a chip (UI:CreateChip) with the class circle and the class-coloured name; offline members are
-- dimmed.
local function NewMemberEntry(parent)
    local e = UI:CreateChip(parent, { kind = "track" })
    e.text = e.fs
    UI:AttachTooltip(e, MemberTip)
    return e
end

-- Lays out a grid of name entries from `pool` (MEMBER_COLS columns); returns the new y.
local function LayoutMembers(cs, pool, list, y)
    local colW = floor(SettingsUI:BodyWidth() / MEMBER_COLS)
    for i, m in ipairs(list) do
        local e = pool[i]
        if not e then
            e = NewMemberEntry(cs)
            pool[i] = e
        end
        e.key, e.online, e.fixed = m.key, m.online and true or false, m.fixed
        Put(e, cs, ((i - 1) % MEMBER_COLS) * colW, y - floor((i - 1) / MEMBER_COLS) * MEMBER_ROW_H)
        local text = m.name or ColoredName(m.key)
        if m.fixed == "Guild Master" then
            text = text .. Grey(" (GM)")
        elseif m.fixed then
            text = text .. Grey(" (" .. m.fixed:lower() .. ")")
        end
        e:Set(text, nil, m.key)
        -- (the chip's circle knows the guild roster only: a member from my group outside it keeps their class icon)
        local EU = ns.EventUI
        local cls = m.classFile or ClassOf(m.key)
        if cls and e.cls and not (EU and EU.ClassOf and EU:ClassOf(m.key)) then
            UI:ClassIcon(e.cls, cls)
            e.cls:SetVertexColor(1, 1, 1, 1)
            e.cls:SetDesaturated(false)
        end
        if e:GetWidth() > colW - 8 then
            UI:FitText(e.fs, text, colW - 8 - 28)
            e:SetWidth(colW - 8)
        end
        e:SetAlpha(e.online and 1 or 0.5)
        e:Show()
    end
    for i = #list + 1, #pool do pool[i]:Hide() end
    if #list == 0 then return y end
    return y - (floor((#list - 1) / MEMBER_COLS) + 1) * MEMBER_ROW_H
end

function SettingsUI:BuildCouncil(sec)
    local cs = sec
    self.cs = cs
    cs.notice = self:Notice(sec, "info")
    cs.status = cs.notice.text
    cs.top = sec.y - 6
    cs.summary = UI:Text(cs, "emph", nil, { width = BODY_W, wrap = true })
    cs.members = {}
    cs.raidSummary = UI:Text(cs, "emph", nil, { width = BODY_W, wrap = true })
    cs.raidMembers = {}
    cs.editBtn = ns.UI:CreateSleekButton(cs, "Edit council", 116, 22, function() SettingsUI:OpenCouncilEditor() end)
    cs.editBtn:SetPoint("RIGHT", cs, "TOPRIGHT", 0, -TITLE_H / 2)
    AddTooltip(cs.editBtn, "Edit council",
        "Opens the Loot Council picker (Council tab). The Guild Master picks the guild council; "
        .. "the raid leader picks extra council members for their raid.")
    cs.info = UI:Text(cs, "small", nil, { width = BODY_W, wrap = true })
    sec.height = BODY_H
end

-- What "Edit council…" opens for me: the lists of the Council tab's picker I can change, only while the Council tab
-- itself is open to me (a council seat, or demo mode). A plain raider who once led a raid still has a saved raid list,
-- but the tab does not open for them: no button, and no "you can edit" text. Empty = no button.
function SettingsUI:EditableCouncilParts()
    local CU = ns.CouncilUI
    local parts = {}
    if not (CU and CU.CanEditCouncil) or (CU.IsAvailable ~= nil and not CU:IsAvailable()) then return parts end
    if CU:CanEditCouncil("guild") then parts[#parts + 1] = "the guild council (Guild Master)" end
    if CU:CanEditCouncil("raid") then
        -- (in a raid only its leader edits the raid list; outside one, whoever has a saved list)
        parts[#parts + 1] = (_G.IsInRaid and _G.IsInRaid()) and "this raid's council list"
            or "your raid council list (used whenever you lead a raid)"
    end
    return parts
end

function SettingsUI:CanEditCouncil()
    return #self:EditableCouncilParts() > 0
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
    local w = self:BodyWidth()
    cs.summary:SetWidth(w)
    cs.raidSummary:SetWidth(w)
    cs.info:SetWidth(w)

    local demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    local CU = ns.CouncilUI
    local sum = CU and CU.GetCouncilSummary and CU:GetCouncilSummary() or nil
    if demo and IsCouncil() then
        cs.status:SetText(S:Wrap("OK", "You are on the Loot Council.") .. Grey(" (demo mode)"))
    elseif IsCouncil() then
        local src = sum and SOURCE_TEXT[sum.mySource]
        cs.status:SetText(S:Wrap("OK", "You are on the Loot Council.") .. (src and Grey(" · " .. src) or ""))
    else
        cs.status:SetText(Grey("You are not on the Loot Council."))
    end
    -- (read-only for whoever can't change it: the Edit council button says who can)
    cs.notice:SetNotice(self:CanEditCouncil() and "info" or "readonly", cs.status:GetText())

    -- Guild council
    local guildList = {}
    if not sum then
        cs.summary:SetText(Grey("The council summary is not available."))
    elseif not sum.inGuild then
        cs.summary:SetText("You are not in a guild. The Loot Council needs a guild; your own BiS list "
            .. "and personal drop alerts work anyway.")
    else
        guildList = sum.guildMembers or {}
        local g = sum.guild
        local text
        if g then
            text = "Guild council" .. Grey(format(" · set by %s %s · phase P%d", NameOf(g.by or sum.gm or "?"),
                FormatAgo(g.rev), tonumber(g.phase) or 1))
        elseif sum.gm then
            text = "Guild council" .. Grey(" · only the Guild Master so far")
        else
            text = "Guild council" .. Grey(" · waiting for the guild roster")
        end
        cs.summary:SetText(text)
    end
    Put(cs.summary, cs, 0, y)
    y = y - (TextHeight(cs.summary) + 8)
    y = LayoutMembers(cs, cs.members, guildList, y)

    -- This raid's council (only while in a raid)
    local raidList = {}
    if sum and sum.inRaid then
        raidList = sum.raidMembers or {}
        local leader = sum.raidLeader
        if sum.raidLeaderOutside and leader then
            cs.raidSummary:SetText("This raid's council" .. Grey(format(": %s leads it but is not in your guild, so is "
                .. "never loot council", NameOf(leader))))
        elseif sum.raidShared and leader then
            cs.raidSummary:SetText("This raid's council" .. Grey(" · set by raid leader " .. NameOf(leader)))
        elseif leader then
            cs.raidSummary:SetText("This raid's council" .. Grey(" · only the raid leader " .. NameOf(leader)))
        else
            cs.raidSummary:SetText("This raid's council" .. Grey(" · waiting for the raid roster"))
        end
        y = y - 14
        Put(cs.raidSummary, cs, 0, y)
        cs.raidSummary:Show()
        y = y - (TextHeight(cs.raidSummary) + 8)
    else
        cs.raidSummary:Hide()
    end
    y = LayoutMembers(cs, cs.raidMembers, raidList, y)

    -- "Edit council…" for the Guild Master / raid leader, an explanation for everyone else (both follow what the
    -- button really opens: EditableCouncilParts).
    local parts = self:EditableCouncilParts()
    if #parts > 0 then
        cs.editBtn:Show()
        cs.info:SetText("You can edit " .. table.concat(parts, " and ") .. ".")
    else
        cs.editBtn:Hide()
        cs.info:SetText("The Guild Master picks the guild council in DisasterZone. A raid leader from the guild can add "
            .. "guild members as council for their own raid, and while a raid runs the loot council its master looter "
            .. "is council too; they count only inside that raid. Players outside the guild are never loot council.")
    end
    y = y - 16
    Put(cs.info, cs, 0, y)
    y = y - (TextHeight(cs.info) + 8)
    cs.height = -y
    return -y
end

---------------------------------------------------------------------------
-- Attendance: the GM's two margins everyone's attendance is measured by (Guild:SetAttendanceRules, shared with
-- every member). The GM steps them (saved a moment after the last step: one message, not one per click); everyone
-- else sees the values as text.
---------------------------------------------------------------------------
local ATT_ROWS = {
    { field = "o", title = "On time", desc = "Arriving this many minutes late still counts as on time" },
    { field = "d", title = "Short disconnects", desc = "A disconnect shorter than this doesn't count against anyone" },
}
local ATT_MAX = 60
local STEP_W = 110

local function CanSetAttendance()
    local G = ns.Guild
    return G and G.IsGM and ns.Util and G:IsGM(ns.Util.PlayerKey()) and true or false
end

function SettingsUI:BuildAttendance(sec)
    self.att = sec
    sec.notice = self:Notice(sec, "info")
    sec.status = sec.notice.text
    sec.steppers = {}
    for _, r in ipairs(ATT_ROWS) do
        local row = self:Row(sec, r.title, r.desc)
        local st = UI:CreateStepper(row, STEP_W, function(dir) SettingsUI:StepAttendance(r.field, dir) end)
        st:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.control = st
        AddValueText(row)
        PlaceText(row, STEP_W)
        sec.steppers[r.field] = st
        sec.rows[#sec.rows].field = r.field
    end
    self:EndSection(sec)
end

-- The GM's step: shown at once, saved (and sent) a moment after the last one.
function SettingsUI:StepAttendance(field, dir)
    if not CanSetAttendance() then return end
    local cur = self.attDraft or ns.Guild:GetAttendanceRules()
    local d = { o = cur.o, d = cur.d }
    d[field] = math.min(ATT_MAX, max(0, (tonumber(d[field]) or 0) + dir))
    self.attDraft = d
    self:RefreshAttendance()
    ns.Util.Debounce("settings-attendance", 0.8, function()
        local draft = SettingsUI.attDraft
        SettingsUI.attDraft = nil
        if not draft then return end
        local ok, err = ns.Guild:SetAttendanceRules(draft.o, draft.d)
        if not ok then ns:Print("%s", tostring(err)) end
        SettingsUI:RefreshAttendance()
    end)
end

function SettingsUI:RefreshAttendance()
    local sec = self.att
    if not sec then return end
    local G = ns.Guild
    local rules = self.attDraft or (G and G.GetAttendanceRules and G:GetAttendanceRules()) or { o = 5, d = 10 }
    local gm = CanSetAttendance()
    if not _G.IsInGuild() then
        sec.status:SetText(Grey("Attendance needs a guild."))
    elseif gm then
        sec.status:SetText("You set these as Guild Master." .. Grey(" They reach every member."))
    else
        sec.status:SetText(Grey("Set by the Guild Master for the whole guild."))
    end
    sec.notice:SetNotice(gm and "info" or "readonly", sec.status:GetText())
    for _, row in ipairs(sec.rows) do
        local n = tonumber(rules[row.field]) or 0
        row.control:Set(n .. " min", n > 0, n < ATT_MAX)
        SetReadOnly(row, not gm, n .. " min")
    end
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
    self:LayoutNav()
    self:SyncWidth()
    self:LayoutClassTools()
    for _, w in ipairs(self.refreshers) do
        if w.Refresh then w:Refresh() end
    end
    self:RefreshGroupRules()
    self:RefreshAbout()
    self:RefreshDungeon()
    self:RefreshCouncil()
    self:RefreshAttendance()
    self:RefreshTutorials()
    self:FitChild()
end
