if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Settings.lua", ...) then return end -- DisasterZone UI/Settings.lua
-- "Settings" tab, 1.4.2 (mockup claude.ai/artifact/Fk8sCeKjVS2TuM1juxp2AC, the user's pick "Spotlight"; then the
-- clean-up mockup's "B · Feature tiles"): a rail of groups on the left (General, Alerts, Loot, Combat, Interface,
-- Guild; Help small at its foot), each with a live line that says how it is set. A group opens as tiles, one per
-- card (a feature): its glyph, its name, its master switch when it has one (flipped right there), a line that says
-- how it is set, "Settings >". A tile opens the card's own page: "< Group" back, its name, who sets it, its master
-- switch, a lead line, then its rows: the 3-5 most used ones, the rest folded under "More options" (open or shut is
-- remembered per card). Off means off: a card whose master switch is off shows one box (what it does, Switch on, Try
-- it), and a row that only matters while another switch is on is hidden while it is off (Relayout re-stacks a
-- section). Every option is a row: its name, a one-line explanation and a switch (UI:CreateSwitch) or a dropdown; a
-- gold dot after the name when it is not the default, and a page with such rows offers "Back to defaults". The
-- search at the rail's top finds any option on any card (folded and hidden ones, class tool cards and look pages
-- too) with its path and a working control; a click on its name opens its page (and fold) and lights the row.
-- Interface > Looks holds every look: the look for everything, then a tile per part (the game's parts, the meters, the
-- class bars, the timers) that opens the part's page: a sample of it in its look, the look tiles, its options.
-- Group loot rules (ADDENDUM D §26/§27) that come from someone else show their values as plain text under "Set by X";
-- the raid leader's "Lock BiS lists" (ADDENDUM F §38); the read-only Loot Council summary with "Edit council"
-- (ADDENDUM E §30); a Blizzard Settings entry (SPEC §12.10).
local addonName, ns = ...

local SettingsUI = ns:NewModule("SettingsUI")

local _G = _G
local CreateFrame = CreateFrame
local format = string.format
local floor, max = math.floor, math.max
local ipairs, type, tonumber, tostring = ipairs, type, tonumber, tostring
local UI, S = ns.UI, ns.Style

-- The page (S.PAGE_W x S.PAGE_H, 790 x 548): the rail | a hairline | the head (the group's name and its lead line;
-- on a card's page the way back, its name and switch) over the tiles or the card in a scroll frame (its bar in the
-- right margin).
local RAIL_W = 208                             -- the groups
local RULE_X = S.PAD + RAIL_W + 8              -- the hairline (226)
local BODY_X = RULE_X + 8                      -- the head and the cards (234)
local PAGE_TOP = 8
local HEAD_H = 46                              -- a group's tiles, the search: its name, a line under it
local PAGE_HEAD_H = 66                         -- a card's or a look's page: back, its name and switch, its lead
local CARDS_W = S.PAGE_W - S.PAD - BODY_X      -- 546
local CARDS_H = S.PAGE_H - PAGE_TOP - HEAD_H - S.PAD     -- the scroll frame's height under the short head
local BODY_W = CARDS_W                         -- a card's rows (a page of its own: the whole width)
local TILE_H, TILE_GAP = 90, 8                 -- a group's tiles, two to a row
local FOLD_H = 36                              -- the "More options" row
local STAGE_H = 150                            -- a look part's page: the sample's stage over its options
local GROUP_H, HELP_H, GROUP_GAP = 54, 40, 2   -- a group's row in the rail, the Help row
local SEARCH_H = 22
local SUB_H = 18                               -- the line under a card's head (who sets the rules, my council seat)
local ROW_H = 44
local DD_W, SWITCH_W = 196, 34
local TEXT_GAP = 16                            -- between a row's text and its control
local MEMBER_COLS, MEMBER_ROW_H = 3, 24
local DOT = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\disc"

-- The groups (the rail) and their cards, top to bottom. icon: UI.ICON_ATLAS index. lead: the line under the group's
-- name over its tiles. small: the Help row at the rail's foot (tutorials, demo mode, about: help, not settings).
local CATS = {
    { key = "general", label = "General", icon = 13, lead = "The window, the lines on item tooltips and the phase you look at.",
      cards = { "window", "tooltips", "phase" } },
    { key = "alerts", label = "Alerts", icon = 56, lead = "What reaches you, and when to stay quiet.", cards = { "quiet", "reach" } },
    { key = "loot", label = "Loot", icon = 40, lead = "Drops, rolls and what your group decided.", cards = { "session", "drops", "rolls", "rules" } },
    { key = "combat", label = "Combat", icon = 62, lead = "What runs while you fight.",
      cards = { "meters", "bossmods", "classtools", "strategy", "mylog" } },
    { key = "interface", label = "Interface", icon = 31, lead = "How everything looks and where it goes.", cards = { "looks", "layout" } },
    { key = "guild", label = "Guild", icon = 26, lead = "The guild's council and how attendance counts: the Guild Master sets them.",
      cards = { "council", "attendance", "discord", "setup" } },
    { key = "help", label = "Help", icon = 11, small = true, lead = "Tutorials, demo mode and what version you have.",
      cards = { "tutorials", "demo", "about" } },
}
local CAT = {}
for _, c in ipairs(CATS) do CAT[c.key] = c end

-- The cards: label, the method that fills it, icon (its tile's glyph, UI.ICON_ATLAS), lead (the line under its name
-- on its page; a function for one that changes), summary() (its tile's line: how it is set now), scope ("group": the
-- group's loot leader sets it, "guild": the Guild Master does; the card's head says so), visible() (shown only while
-- it returns true). master: the switch for the whole feature, on its tile and in its head instead of a row ({ path,
-- default, title (its name in the search), desc, tip, off = the line of the box shown while it is off, try = the
-- box's Try it }). The summaries are filled in below, once the helpers they read are there.
local CARDS = {
    window = { label = "Window", build = "BuildWindow", icon = 30, lead = "The DisasterZone window itself." },
    tooltips = { label = "Item tooltips", build = "BuildTooltips", icon = 15, lead = "The lines DisasterZone adds to item tooltips.",
                 master = { path = "tooltip.enabled", default = true, title = "DisasterZone lines on item tooltips",
                            desc = "Whether an item is on your BiS list.",
                            off = "Switch it on to see on every item tooltip whether the item is on your BiS list, and "
                                .. "on the Loot Council who else wants it." } },
    phase = { label = "Phase", build = "BuildPhase", icon = 45,
              lead = "The raids your council views, tooltips and drop alerts are about." },
    quiet = { label = "When to stay quiet", build = "BuildQuiet", icon = 48,
              lead = "Pop-ups wait while these hold. The bell keeps everything." },
    -- one grid: every kind of notification (Core/Notify.lua) and the BiS drop alert, each by pop-up, sound and chat
    reach = { label = "What reaches you", build = "BuildNotify", icon = 56,
              lead = "What can pop up, play a sound or write a line in chat." },
    -- who sees the raid session crest (UI/SessionBar.lua)
    session = { label = "Raid session", build = "BuildSession", icon = 26,
                lead = "The crest that shows who runs the raid and what waits on them." },
    drops = { label = "Drop panel", build = "BuildDrops", icon = 40,
              lead = "The panel that opens when a boss drops loot, and the loot window's marks." },
    rolls = { label = "Rolls", build = "BuildRolls", icon = 21, lead = "Rolling for the loot the council leaves to rolls." },
    rules = { label = "Group rules", build = "BuildGroupRules", scope = "group", icon = 46,
              lead = "Your group's loot leader sets these for everyone in it." },
    meters = { label = "Meters", build = "BuildMeters", icon = 58,
               lead = "Damage and threat from your own combat log, in panels that dock together." },
    -- timer bars, warnings and the range frame for the raid bosses (UI/BossModSettings.lua)
    bossmods = { label = "Boss mods", build = "BuildBossMods", icon = 37,
                 lead = "Timers, warnings and the range frame for every TBC raid boss.",
                 master = { path = "bossmods.on", default = false, title = "Boss mods",
                            desc = "Timers, warnings and the range frame for every TBC raid boss. Off until you switch it on.",
                            tip = "Running DBM or BigWigs too? Turn one of them off, or every warning comes twice.",
                            off = "Switch it on for timer bars, warnings and the range frame on every TBC raid boss. "
                                .. "Pull and break timers work either way.",
                            try = function() if ns.BossModUI then ns.BossModUI:TryIt() end end } },
    -- class tools (Core/ClassKit.lua): a collapsible card per tool of my class (every class's in demo mode)
    classtools = { label = "Class tools", build = "BuildClassTools", icon = 60,
                   lead = function()
                       local CK = ns.ClassKit
                       if CK and CK:IsDemo() then return "Demo mode: every class's tools, with made-up data. Nothing is cast or sent." end
                       return "Tools for your class and spec. Switch one off to hide it; open a card for its settings."
                   end,
                   visible = function() return SettingsUI:HasClassTools() end },
    strategy = { label = "Strategy boards", build = "BuildStrategy", icon = 25,
                 lead = "The raid's plans: who stands where and who does what." },
    mylog = { label = "My Log", build = "BuildMyLog", icon = 55, lead = "Your own raid performance, kept on this computer.",
              master = { path = "mylog.enabled", default = false, title = "Record my raid performance",
                         desc = "Your own damage, healing, casts and deaths in every boss pull. Saved on this PC only, never sent.",
                         tip = "Nobody else can see that you use it or read your numbers, the loot council included. Turn "
                             .. "it off and recording stops at once. /dz mylog last prints your latest pull.",
                         off = "Switch it on to record your own damage, healing, casts and deaths in every boss pull. "
                             .. "It stays on this PC: nobody else sees it, the loot council included." } },
    -- the game's frames in the addon's looks (UI/Look.lua) and the addon's own themes, a page per part
    looks = { label = "Looks", build = "BuildLooks", icon = 31,
              lead = "How the game's frames and the addon's own parts are drawn." },
    -- where every on-screen frame goes (Core/Layout.lua)
    layout = { label = "Layout", build = "BuildLayout", icon = 2,
               lead = "Where every frame on your screen goes, yours and the game's." },
    council = { label = "Loot Council", build = "BuildCouncil", scope = "guild", icon = 26,
                lead = "Who votes on loot. The Guild Master picks the guild council." },
    -- the GM's attendance margins (Guild:SetAttendanceRules): everyone sees them, the GM changes them
    attendance = { label = "Attendance", build = "BuildAttendance", scope = "guild", icon = 61,
                   lead = "How attendance is counted. The Guild Master sets it for everyone." },
    -- the guild's Discord bot (Core/Bridge.lua, Guild:SetDiscord): who hosts it, where raids are posted
    discord = { label = "Discord", build = "BuildDiscord", scope = "guild", icon = 47,
                lead = "The guild's Discord bot: who runs it and where raids are posted.",
                visible = function() return SettingsUI:IsGM() or (ns.Bridge and ns.Bridge:IsHostPC()) or false end },
    -- the GM's set-up checklist (UI/WelcomeTour.lua)
    setup = { label = "Guild set-up", build = "BuildSetup", scope = "gm", icon = 64,
              lead = "What is left to set up for your guild. Each open item opens its page.",
              visible = function() return SettingsUI:IsGM() end },
    -- the Welcome tour's parts and the strategy board's tutorial (UI/WelcomeTour.lua)
    tutorials = { label = "Tutorials", build = "BuildTutorials", icon = 47,
                  lead = "Short tours on the real windows. Nothing you do in one is sent to the guild." },
    demo = { label = "Demo mode", build = "BuildDemo", icon = 22,
             lead = "Made-up guild members and a raid to try things solo. Never saved or sent." },
    about = { label = "About", build = "BuildAbout", icon = 34,
              lead = "Your version, how your list is shared, and help for tracking down problems." },
}
local CARD_CAT = {}
for _, c in ipairs(CATS) do for _, k in ipairs(c.cards) do CARD_CAT[k] = c.key end end

-- The sections of 1.4.1 and before (links from other pages, tours, changelog entries) and where they are now.
local OLD = { alerts = "reach", notify = "reach", ui = "looks" }

-- Interface > Looks: a page per part. The game's parts (Look.PARTS) wear the looks; meters, class bars and timers
-- have their own theme sets (ns.Themes kinds). kits: shown only for those class tools' classes (every one in demo).
local PARTS = {
    { key = "units", glyph = 61 }, { key = "group", glyph = 46 }, { key = "cast", glyph = 47 },
    { key = "bars", glyph = 38 }, { key = "bags", glyph = 40 }, { key = "minimap", glyph = 7 },
    { key = "sct", glyph = 8 }, { key = "bossmods", glyph = 37 },
    { key = "meters", label = "Meters", tip = "The damage and threat panels.", glyph = 58, kind = "meters" },
    { key = "classbars", label = "Class bars", tip = "The blessing and totem bars: every class tool bar shares it.",
      glyph = 60, kind = "classbar", kits = { "bless", "totems" } },
    { key = "timers", label = "Timers", tip = "The swing and shot timers: each has its own.", glyph = 59,
      kits = { "swing", "shot" } },
}
local PART = {}
for _, p in ipairs(PARTS) do PART[p.key] = p end
local PartInfo       -- (a part's name and line: with the look pages, below)
-- (a part with a switch of its own: combat text, off until turned on; its page is the box while it is off)
PART.sct.master = { path = "ui.sct.on", default = false, title = "Show combat text", desc = "Off until you turn it on.",
    tip = "Nothing else turns it on, not even a look for everything. With Blizzard as its look it wears Classic.",
    off = "Switch it on for your damage, healing and procs as numbers on the screen, in your look. Nothing else turns "
        .. "it on, not even a look for everything.",
    try = function() if ns.CombatTextUI then ns.CombatTextUI:TryIt() end end }

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
    self.section, self.cat = nil, "general"      -- (Settings opens on General's tiles)
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("settings", "Settings", 4,
            function(parent) return SettingsUI:CreatePanel(parent) end,
            function() return true end)
    end
    local function changed() SettingsUI:RequestRefresh() end
    for _, msg in ipairs({ "SETTINGS_CHANGED", "CONFIG_UPDATED", "ROSTER_UPDATED", "PEERS_UPDATED",
                           "DEMO_TOGGLED", "SYNC_STATUS", "DUNGEON_MODE_CHANGED", "GROUP_UPDATED",
                           "GROUP_RULES_CHANGED", "BIS_LOCK_CHANGED", "MYLOG_CHANGED", "ATTENDANCE_RULES_CHANGED",
                           "TOUR_CHANGED", "LOOT_RULES_CHANGED", "RAIDPLAN_CHANGED", "UI_LOOK_CHANGED",
                           "DISCORD_CHANGED" }) do
        ns:On(msg, changed)
    end
end

function SettingsUI:OnLogin()
    self:RegisterBlizzardCategory()
    -- a respec shows or hides class tool cards (Swing timer: Retribution only)
    ns:On("CLASSKIT_CHANGED", function()
        SettingsUI:LayoutClassTools()
        SettingsUI:RequestRefresh()
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
    settings = "Alerts, loot, looks and more.", blessings = "Who blesses which class.",
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
    local now, best = ns.Util.Now(), nil      -- (raid times are server time)
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
        parts[1] = G("Next raid") .. "  " .. name .. "  ·  " .. date("%a %H:%M", v.t) .. "  ·  " .. Countdown(v.t - ns.Util.Now())
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
        parts[1] = G("Next raid") .. "  " .. name .. "  ·  " .. Countdown(v.t - ns.Util.Now())
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

-- The master switch of a card or a part (CARDS[key].master, PART[key].master): on or off, and set (every switch for it
-- follows at once: its tile's, its head's).
local FitDesc        -- (a row's height with its line wrapped or not: below, with the rows)

local function MasterOn(m)
    return Get(m.path, m.default) and true or false
end

function SettingsUI:SetMaster(m, on)
    Set(m.path, on and true or false)
    for _, sw in ipairs(m.switches or {}) do sw:SetChecked(MasterOn(m)) end
    self:LayoutView()
end

-- A page's head (a card's or a look part's), shown in the head over the scroll frame while its page is open: its
-- name (gold), a pill saying who sets it, and on the right its master switch (On / Off and the switch), Back to
-- defaults while an option of it is not at its default, and the card's own action (Edit council).
local PAGE_TITLE_Y = -18
function SettingsUI:NewPageHead(title, onReset, master, ownerKey)
    local head = CreateFrame("Frame", nil, self.head)
    head:SetPoint("TOPLEFT", self.head, "TOPLEFT", 0, PAGE_TITLE_Y)
    head:SetPoint("TOPRIGHT", self.head, "TOPRIGHT", 0, PAGE_TITLE_Y)
    head:SetHeight(24)
    head:Hide()
    head.title = UI:Text(head, "page", "GOLD")
    head.title:SetPoint("LEFT", head, "LEFT", 0, 0)
    head.title:SetText(title or "")
    head.pill = UI:CreatePill(head, 16)
    head.pill:SetPoint("LEFT", head.title, "RIGHT", 10, 0)
    head.pill:Hide()
    head.reset = ns.UI:CreateSleekButton(head, "", 120, 20, onReset)
    head.reset:Hide()
    AddTooltip(head.reset, "Back to defaults", "Puts every option on this page back the way DisasterZone comes.")
    if master then
        -- On / Off and the switch; the switch's name (its label, the search's and its tooltip's) is the master's title
        local box = CreateFrame("Frame", nil, head)
        box:SetSize(80, 22)
        box:SetPoint("RIGHT", head, "RIGHT", 0, 0)
        box.masterOf = ownerKey
        local sw = ns.UI:CreateSwitch(box, function() return MasterOn(master) end,
            function(a, b) SettingsUI:SetMaster(master, Bool(a, b)) end)
        sw:SetPoint("RIGHT", box, "RIGHT", 0, 0)
        box.state = UI:Text(box, "small", "SUB", { justify = "RIGHT" })
        box.state:SetPoint("RIGHT", sw, "LEFT", -8, 0)
        box.name = UI:Text(box, "small")
        box.name:SetText(master.title)
        box.name:Hide()
        sw.label = box.name
        AddTooltip(sw, master.title, master.tip and (master.desc .. "\n\n" .. master.tip) or master.desc)
        box.switch = sw
        master.switches = master.switches or {}
        master.switches[#master.switches + 1] = sw
        self.refreshers[#self.refreshers + 1] = sw
        head.master = box
    end
    return head
end

-- Lays out a page head's right side: its master (On / Off), Back to defaults with the count of changed options, the
-- card's action left of them.
local function PaintPageHead(head, changed, master)
    local right = head
    local anchor, gap = "RIGHT", 0
    if head.master then
        local on = MasterOn(master)
        head.master.state:SetText(on and "On" or "Off")
        head.master.state:SetTextColor(S:Color(on and "OK" or "SUB"))
        head.master:SetWidth(SWITCH_W + 8 + floor(UI:TextWidth(head.master.state) + 0.5))
        head.master.switch:SetChecked(on)
        right, anchor, gap = head.master, "LEFT", -14
    end
    local r = head.reset
    r:SetShown(changed > 0)
    if changed > 0 then
        r:SetText(UI:AtlasIconText(9, 11, S.C.GOLD) .. " Back to defaults · " .. changed)
        local fs = r:GetFontString()
        r:SetWidth(floor((fs and UI:TextWidth(fs) or 110) + 22))
        r:ClearAllPoints()
        r:SetPoint("RIGHT", right, anchor, gap, 0)
        right, anchor, gap = r, "LEFT", -6
    end
    if head.action then
        head.action:ClearAllPoints()
        head.action:SetPoint("RIGHT", right, anchor, gap, 0)
    end
end

-- A card: a frame in the scroll child holding its section (sec: a frame its rows go into from sec.y down; sec.key =
-- the card's key, sec.card = the card), its page head (card.head) and, for a card with a master switch, the box shown
-- while it is off (card.off). The method named in CARDS fills the section.
function SettingsUI:NewCard(cat, key)
    local def = CARDS[key]
    local card = CreateFrame("Frame", nil, self.child)
    card:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, 0)
    card:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, 0)
    card:SetHeight(1)
    card.key, card.cat, card.def = key, cat.key, def
    card.head = self:NewPageHead(def.label, function() SettingsUI:ResetCard(key) end, def.master, key)
    local sec = CreateFrame("Frame", nil, card)
    sec:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
    sec:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, 0)
    sec:SetHeight(1)
    sec.key = key
    sec.rows = {}
    sec.y = 0
    sec.card = card
    card.sec = sec
    self.sections[key] = sec
    self.cards[key] = card
    self.ctx = { cat = cat.key, card = key, path = { cat.label, def.label } }
    local first = #self.index + 1
    if def.master then self:IndexMaster(def.master, first) end
    self[def.build](self, sec)
    self.ctx = nil
    card:Hide()
    return card
end

-- The master switch in the search: its title and line, a working switch in the results; its jump lights the head's.
function SettingsUI:IndexMaster(m, at)
    local ctx = self.ctx
    if not ctx then return end
    local getter = function() return MasterOn(m) end
    local setter = function(a, b) SettingsUI:SetMaster(m, Bool(a, b)) end
    local e = { title = m.title, desc = m.desc or "", path = ctx.path, cat = ctx.cat, card = ctx.card, part = ctx.part,
                master = m }
    e.make = function(rs) return select(2, SettingsUI:Switch(rs, m.title, m.desc, getter, setter, m.tip)) end
    table.insert(self.index, at or (#self.index + 1), e)
end

-- A button of the card's own in its head, left of Back to defaults (Edit council).
function SettingsUI:CardAction(sec, button)
    local head = sec.card and sec.card.head
    if not head then return end
    button:SetParent(head)
    button:ClearAllPoints()
    button:SetPoint("RIGHT", head, "RIGHT", 0, 0)
    head.action = button
end

-- The box a page with its master switch off shows instead of its options (no greyed rows): the page's glyph,
-- "<Name> is off", what switching it on gives, Switch on, and Try it when it has one. owner: the card or the look
-- page it fills; extra: { label, width, onClick, shown() } more buttons (My Log: delete what is stored).
local OFF_IN = 16
function SettingsUI:OffBox(owner, name, glyph, m, extra)
    local box = UI:CreateCard(owner, { pad = 0 })
    box.body:Hide()
    box:SetPoint("TOPLEFT", owner, "TOPLEFT", 0, -6)
    box:SetPoint("TOPRIGHT", owner, "TOPRIGHT", 0, -6)
    box.tile = UI:CreateIconTile(box, 40)
    box.tile:SetPoint("TOPLEFT", box, "TOPLEFT", OFF_IN, -OFF_IN)
    local co = UI:IconCoords(glyph or 24)
    box.tile.tex:SetTexture(UI.ICON_ATLAS)
    box.tile.tex:SetTexCoord(co[1], co[2], co[3], co[4])
    box.tile.tex:ClearAllPoints()
    box.tile.tex:SetPoint("CENTER")
    box.tile.tex:SetSize(20, 20)
    box.tile.tex:SetVertexColor(S:Color("DIM"))
    box.tile.outer:SetColorTexture(S:Color("INSET"))
    local x = OFF_IN + 40 + 14
    box.title = UI:Text(box, "emph", "TEXT")
    box.title:SetPoint("TOPLEFT", box, "TOPLEFT", x, -(OFF_IN + 1))
    box.title:SetText(name .. " is off")
    box.line = UI:Text(box, "body", "SUB", { wrap = true })
    box.line:SetPoint("TOPLEFT", box.title, "BOTTOMLEFT", 0, -5)
    box.line:SetText(m.off or "")
    box.on = ns.UI:CreateSleekButton(box, "Switch on", 96, 22, function() SettingsUI:SetMaster(m, true) end, "primary")
    box.buttons = { box.on }
    if m.try then
        box.try = ns.UI:CreateSleekButton(box, "Try it", 80, 22, function() m.try() end)
        AddTooltip(box.try, "Try it", "A made-up pull plays on your screen. Nothing is read or sent.")
        box.buttons[#box.buttons + 1] = box.try
    end
    for _, b in ipairs(extra or {}) do
        local btn = ns.UI:CreateSleekButton(box, b.label, b.width or 120, 22, b.onClick)
        btn.shownIf = b.shown
        box.buttons[#box.buttons + 1] = btn
        if b.make then b.make(btn) end
    end
    box.x = x
    -- w: the page's width; returns the box's height
    function box:Layout(w)
        self.line:SetWidth(max(80, w - self.x - OFF_IN))
        local lineH = TextHeight(self.line)
        local y = OFF_IN + 1 + 14 + 5 + lineH + 12
        local bx, last = self.x, nil
        for _, b in ipairs(self.buttons) do
            local on = not b.shownIf or b.shownIf()
            b:SetShown(on)
            if on then
                b:ClearAllPoints()
                if last then b:SetPoint("LEFT", last, "RIGHT", 8, 0) else b:SetPoint("TOPLEFT", self, "TOPLEFT", bx, -y) end
                last = b
            end
        end
        local h = y + 22 + OFF_IN
        self:SetHeight(h)
        return h
    end
    box:Hide()
    return box
end

-- The line under a section's title (who sets the rules, my council seat): white, its asides grey.
function SettingsUI:Subtitle(sec)
    local fs = UI:Text(sec, "small", "TEXT")
    fs:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - 1)
    fs:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y - 1)
    self:AddItem(sec, { f = fs, h = SUB_H })
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
    n:SetWidth(sec.fitW or self:BodyWidth())        -- (its width before the layout resolves: the text fits it)
    self:AddItem(sec, { f = n, gap = 2, h = NOTICE_SPACE })
    sec.y = sec.y - NOTICE_SPACE
    return n
end

-- Ends a section: no rule under its last row; its height. (What comes after it is the section's own: it moves with
-- the end when Relayout re-stacks the rows above.)
function SettingsUI:EndSection(sec, extra)
    local last = sec.rows[#sec.rows]
    if last and last.line then
        last.line:Hide()
        last.endHidden = true
    end
    sec.rowsEnd = sec.y
    sec.height = -sec.y + (extra or 0)
end

---------------------------------------------------------------------------
-- A section's items: what Relayout re-stacks (rows, headers, notices, the More options row), in the order they were
-- made. it = { f = the frame, top = its y when made, gap = how far under that it sits, h = its height (rows: their
-- own), more = inside the More options fold, need() = shown only while it returns true }. A section with a fold or a
-- row that needs another switch is dynamic: Refresh lays it out again (hidden items take no room, everything under
-- them moves up). Anything else the section made against itself (a theme row's tiles, a note) goes with the item it
-- sits in; what sits under its last item moves with the end.
---------------------------------------------------------------------------
function SettingsUI:AddItem(sec, it)
    local items = sec.items
    if not items then
        items = {}
        sec.items = items
    end
    it.top = it.top or sec.y
    it.gap = it.gap or 0
    if sec.inMore and it.more == nil then it.more = true end
    items[#items + 1] = it
    it.f.item = it
    return it
end

-- Places a frame of the section (a header, a strip) at sec.y + gap as an item h tall. opts: { gap (0), right (its
-- right inset), need, more }. Returns the frame.
function SettingsUI:Place(sec, f, h, opts)
    opts = opts or {}
    local gap = opts.gap or 0
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - gap)
    f:SetPoint("TOPRIGHT", sec, "TOPRIGHT", -(opts.right or 0), sec.y - gap)
    self:AddItem(sec, { f = f, gap = gap, h = h, right = opts.right, need = opts.need, more = opts.more })
    if opts.need then sec.dynamic = true end
    sec.y = sec.y - gap - h
    return f
end

-- Shows a row only while fn() is true (the options of a switch while it is on): hidden, not dimmed. owner: the row
-- whose switch it needs (a search result for a hidden row lights that one). Returns the row.
function SettingsUI:Needs(row, fn, owner)
    if not (row and row.item) then return row end
    row.need, row.needOf = fn, owner
    row.item.need = fn
    if row.sec then row.sec.dynamic = true end
    return row
end

-- (a setting switched on, for Needs)
local function IsOn(path, default)
    return function() return Get(path, default) and true or false end
end
SettingsUI.IsOn = IsOn

-- "More options": the rows made after it in this section are folded under one row (gold, a chevron, the first few
-- of their names in grey, how many there are), shut until opened; open or shut is remembered per section (an account
-- setting, settingsMore.<section key>). Returns the fold row.
local function MorePath(sec) return "settingsMore." .. tostring(sec.key) end

function SettingsUI:MoreOpen(sec)
    return sec and sec.fold and Get(MorePath(sec), false) and true or false
end

function SettingsUI:SetMoreOpen(sec, open)
    if not (sec and sec.fold) then return end
    Set(MorePath(sec), open and true or nil)
    self:Relayout(sec)
    self:LayoutView()
end

function SettingsUI:MoreOptions(sec)
    local fold = CreateFrame("Button", nil, sec)
    fold:SetHeight(FOLD_H)
    UI:DecorateRow(fold, { rule = true })
    fold.chev = fold:CreateTexture(nil, "ARTWORK")
    fold.chev:SetSize(10, 10)
    fold.chev:SetPoint("LEFT", fold, "LEFT", 0, 0)
    fold.chev:SetVertexColor(S:Color("GOLD"))
    fold.label = UI:Text(fold, "emph", "GOLD")
    fold.label:SetPoint("LEFT", fold.chev, "RIGHT", 7, 0)
    fold.label:SetText("More options")
    fold.badge = UI:CreateCountBadge(fold, 14)
    fold.badge:SetPoint("RIGHT", fold, "RIGHT", 0, 0)
    fold.list = UI:Text(fold, "small", "SUB")
    fold.list:SetWordWrap(false)
    fold.list:SetPoint("LEFT", fold.label, "RIGHT", 10, 0)
    fold.sec = sec
    fold:SetScript("OnClick", function(self) SettingsUI:SetMoreOpen(self.sec, not SettingsUI:MoreOpen(self.sec)) end)
    fold:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 1, 1) end)
    fold:SetScript("OnLeave", function(self) self.label:SetTextColor(S:Color("GOLD")) end)
    self:Place(sec, fold, FOLD_H)
    fold.item.fold = true
    sec.fold, sec.inMore, sec.dynamic = fold, true, true
    return fold
end

-- (the rows inside the fold that would show: their names for its list, their count for its badge)
local function FoldRows(sec)
    local out = {}
    for _, it in ipairs(sec.items or {}) do
        if it.more and it.isRow and (not it.need or it.need()) then out[#out + 1] = it.f end
    end
    return out
end

local function PaintFold(sec, open)
    local fold = sec.fold
    local rows = FoldRows(sec)
    UI:SetChevron(fold.chev, not open)
    if open then UI:SetChevronUp(fold.chev, false) end
    fold.badge:SetCount(#rows)
    local names = {}
    for i, r in ipairs(rows) do
        if i > 4 then break end
        names[#names + 1] = (r.title:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    end
    local room = ((sec.fitW or SettingsUI:BodyWidth()) - 17 - UI:TextWidth(fold.label) - 10 - 30)
    UI:FitText(fold.list, open and "" or (table.concat(names, ", ") .. (#rows > 4 and ", ..." or "")), max(20, room))
    return #rows
end

-- The frames and textures a section made against itself that are not items: each goes with the item it sits in (by
-- its top's y when the section was made), or with the end (under the last item); the ones over the first stay put.
local function Seal(sec)
    if sec.sealed then return end
    sec.sealed = true
    local items = sec.items or {}
    local endY = sec.rowsEnd
    for i, it in ipairs(items) do
        local nextTop = items[i + 1] and items[i + 1].top
        if nextTop then
            it.span = it.top - nextTop
        elseif endY then
            it.span = it.top - endY
        else
            it.span = it.gap + (it.h or (it.f:GetHeight() or ROW_H))
        end
        it.builtH = it.h == nil and (it.f:GetHeight() or ROW_H) or nil
        it.att = {}
        local line = it.f.line
        it.line0 = line and (line:IsShown() or it.f.endHidden) or false
    end
    local last = items[#items]
    sec.endTop = last and (last.top - last.span) or sec.y
    sec.tailAtt = {}
    local own = {}
    for _, it in ipairs(items) do own[it.f] = true end
    local function take(obj)
        if own[obj] or not (obj and obj.GetNumPoints) then return end
        local pts, top = {}, nil
        for p = 1, obj:GetNumPoints() do
            local pt, rel, rp, x, y = obj:GetPoint(p)
            local mine = rel == sec or rel == nil
            pts[#pts + 1] = { pt, mine and sec or rel, rp or pt, x or 0, y or 0, mine }
            if mine and top == nil and (rp or pt or ""):find("TOP") then top = y or 0 end
        end
        if top == nil then return end
        local a = { obj = obj, pts = pts }
        if top <= sec.endTop then
            sec.tailAtt[#sec.tailAtt + 1] = a
            return
        end
        for i = #items, 1, -1 do
            if top <= items[i].top then
                local list = items[i].att
                list[#list + 1] = a
                return
            end
        end
    end
    for _, ch in ipairs({ sec:GetChildren() }) do take(ch) end
    for _, rg in ipairs({ sec:GetRegions() }) do take(rg) end
end

local function MoveAtt(a, sec, dy)
    local obj = a.obj
    obj:ClearAllPoints()
    for _, p in ipairs(a.pts) do obj:SetPoint(p[1], p[2], p[3], p[4], p[5] + (p[6] and dy or 0)) end
end

-- Lays a dynamic section's items out again from its first: the shown ones stacked, the hidden ones (shut fold, a
-- switch they need off) out; the rule under the last row hidden; the end and what sits under it moved; sec.height.
-- sec.onRelayout(shift) (optional) lays out the section's own part under its rows (shift: how far the end moved up).
function SettingsUI:Relayout(sec)
    if not (sec and sec.dynamic and sec.items and sec.items[1]) then return end
    Seal(sec)
    local open = self:MoreOpen(sec)
    local items = sec.items
    local y = items[1].top
    local lastRow
    for _, it in ipairs(items) do
        local show = (not it.more or open) and (not it.need or it.need())
        if it.fold then show = PaintFold(sec, open) > 0 end
        local f = it.f
        if show then
            local h = it.span
            if it.builtH then h = h + (FitDesc(f) - it.builtH) end
            local dy = y - it.top
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, y - it.gap)
            f:SetPoint("TOPRIGHT", sec, "TOPRIGHT", -(it.right or 0), y - it.gap)
            for _, a in ipairs(it.att) do
                MoveAtt(a, sec, dy)
                if a.hid then a.obj:Show(); a.hid = nil end
            end
            if f.line then
                f.line:SetShown(it.line0)
                if it.isRow then lastRow = it end
            end
            y = y - h
        else
            for _, a in ipairs(it.att) do
                if a.obj:IsShown() then a.obj:Hide(); a.hid = true end
            end
        end
        f:SetShown(show)
    end
    if lastRow and sec.rowsEnd then lastRow.f.line:Hide() end
    local shift = y - sec.endTop                -- (> 0: the end moved up)
    for _, a in ipairs(sec.tailAtt) do MoveAtt(a, sec, shift) end
    sec.shift = shift
    if sec.height0 == nil then sec.height0 = sec.height or -sec.endTop end
    sec.height = sec.height0 - shift
    if sec.onRelayout then sec.onRelayout(shift) end
end

-- Places a row's texts left of a control ctrlW wide: name on top, the explanation under it (or the name alone,
-- centred).
-- A row's line wraps onto a second line when it is longer than its room (nothing is cut with "..."): the row grows by
-- a line. Returns the row's height. (row.sec.fitW: the section's width when it isn't a card's, BODY_W otherwise.)
local WRAP_H = 13
function FitDesc(row)
    local w = ((row.sec and row.sec.fitW) or SettingsUI:BodyWidth()) - (((row.ctrlW or 0) > 0) and (row.ctrlW + TEXT_GAP) or 0)
    local wrap = row.hasDesc and w > 40 and UI:TextWidth(row.desc) > w
    if wrap ~= (row.wrapped or false) then
        row.wrapped = wrap
        row.desc:SetWordWrap(wrap)
        if row.desc.SetMaxLines then row.desc:SetMaxLines(wrap and 2 or 1) end
        row:SetHeight(ROW_H + (wrap and WRAP_H or 0))
    end
    return ROW_H + (wrap and WRAP_H or 0)
end

local function PlaceText(row, ctrlW)
    local right = -(((ctrlW or 0) > 0) and (ctrlW + TEXT_GAP) or 0)
    row.ctrlW = ctrlW
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
    -- (the section's newest row: what comes after it moves down with it)
    local was = row:GetHeight() or ROW_H
    if was <= 0 then was = ROW_H end
    local h = FitDesc(row)
    local sec = row.sec
    if h ~= was and sec and sec.rows and sec.rows[#sec.rows] == row and sec.y then sec.y = sec.y - (h - was) end
end

SettingsUI.PlaceText = PlaceText

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
    row.sec = sec
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
    self:AddItem(sec, { f = row, isRow = true })
    row.more = row.item.more
    sec.y = sec.y - ROW_H
    sec.rows[#sec.rows + 1] = row
    PlaceText(row, 0)
    self:IndexRow(row, title, desc)
    return row
end

-- The search's index: every row made while a card or a look page is built (self.ctx: its group, card, kit, part and
-- path), with what makes it again in the results (entry.make(sec), set by Switch / Dropdown and the notification
-- rows; a row without one shows its words and a way to it).
function SettingsUI:IndexRow(row, title, desc)
    local ctx = self.ctx
    row.cardKey = ctx and (ctx.part and ("part:" .. ctx.part) or ctx.card) or nil
    if not ctx or self.noIndex or type(title) ~= "string" or title == "" then return end
    local e = { title = title, desc = type(desc) == "string" and desc or "", path = ctx.path, cat = ctx.cat,
                card = ctx.card, kit = ctx.kit, part = ctx.part, row = row, more = row.more }
    self.index[#self.index + 1] = e
    row.entry = e
end

-- A row's default (the gold dot after its name while it differs; Back to defaults puts it back): the value its
-- getter gives, compared to `default` (a switch's as true / false).
function SettingsUI:SetDefault(row, default)
    if not (row and row.getValue) then return end
    row.setting = { default = default }
    self.settingRows[#self.settingRows + 1] = row
end

local function RowChanged(row)
    if row.isChanged then return row.isChanged() and true or false end
    local s = row.setting
    if not (s and row.getValue) then return false end
    local v = row.getValue()
    if type(s.default) == "boolean" then v = v and true or false end
    return v ~= s.default
end

-- The gold dot after a row's name (not on rows someone else sets: those show the value as text).
local function PaintDot(row)
    local on = not row.readOnly and RowChanged(row)
    if on and not row.dot then
        row.dot = row:CreateTexture(nil, "OVERLAY")
        row.dot:SetTexture(DOT)
        row.dot:SetSize(5, 5)
        row.dot:SetVertexColor(S:Color("GOLD"))
    end
    if row.dot then
        if on then
            row.dot:ClearAllPoints()
            row.dot:SetPoint("LEFT", row.title, "LEFT", floor(UI:TextWidth(row.title) + 7), 0)
        end
        row.dot:SetShown(on)
    end
    return on
end
SettingsUI.RowChanged = RowChanged

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
    row.getValue, row.apply = getter, setter
    if row.entry then
        row.entry.make = function(rs) return select(2, SettingsUI:Switch(rs, title, desc, getter, setter, tip)) end
    end
    self.refreshers[#self.refreshers + 1] = sw
    return sw, row
end

function SettingsUI:SwitchSetting(sec, title, desc, path, default, tip)
    local sw, row = self:Switch(sec, title, desc,
        function() return Get(path, default) and true or false end,
        function(a, b) Set(path, Bool(a, b)) end, tip)
    self:SetDefault(row, default and true or false)
    return sw, row
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
    row.getValue, row.apply = getSelected, onSelect
    if row.entry then
        row.entry.make = function(rs)
            return select(2, SettingsUI:Dropdown(rs, title, desc, getOptions, getSelected, onSelect, tip))
        end
    end
    self.refreshers[#self.refreshers + 1] = dd
    return dd, row
end

function SettingsUI:DropdownSetting(sec, title, desc, path, default, options, tip)
    local dd, row = self:Dropdown(sec, title, desc,
        function() return options end,
        function() return Get(path, default) end,
        function(a, b) Set(path, Value(a, b)) end, tip)
    self:SetDefault(row, default)
    return dd, row
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

-- A row whose button opens Edit layout (/dz edit), where every frame on the screen moves: the class tools' and the
-- meters' place. Returns the button and the row.
function SettingsUI:EditLayoutRow(sec, title, desc)
    local row = self:Row(sec, title or "Position", desc or "Move it in Edit layout, together with every other frame.")
    local btn = ns.UI:CreateSleekButton(row, "Edit layout", 120, 22, function()
        if ns.EditMode then ns.EditMode:Open() end
    end)
    btn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.control = btn
    PlaceText(row, 120)
    return btn, row
end

-- The look a part wears, by name (Interface > Looks): the game's parts' look (combat text "Off" while it is off), the
-- theme of the meters / class bars / my timer.
function SettingsUI:PartLookName(part)
    local Look, T = ns.Look, ns.Themes
    if part == "sct" and not Get("ui.sct.on", false) then return "Off" end
    if Look and Look.BY_KEY and not (PART[part] and (PART[part].kind or PART[part].kits)) then
        local l = Look.BY_KEY[Look:Chosen(part)]
        return l and l.name or "Blizzard"
    end
    local kind = PART[part] and PART[part].kind
    if part == "timers" then
        kind = "ring_swing"
        local CK = ns.ClassKit
        if CK and CK:Get("shot") and CK:MyClass() == CK:Get("shot").class then kind = "ring_shot" end
    end
    local t = T and kind and T:Kind(kind) and T:Get(kind, T:Saved(kind))
    return t and t.name or "Default"
end

-- A row whose button shows a part's look and opens its page in Interface > Looks (where every look is picked): the
-- meters' and the class tools' cards.
function SettingsUI:LookLinkRow(sec, title, desc, part)
    local row = self:Row(sec, title, desc)
    local btn = ns.UI:CreateSleekButton(row, "", 120, 22, function() SettingsUI:OpenPart(part) end)
    btn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    btn.chev = btn:CreateTexture(nil, "OVERLAY")
    btn.chev:SetSize(10, 10)
    btn.chev:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
    UI:SetChevron(btn.chev, true)
    btn.chev:SetVertexColor(S:Color("GOLD"))
    row.control = btn
    PlaceText(row, 120)
    AddTooltip(btn, "Interface > Looks", "Every look is picked there: this opens its page.")
    self.refreshers[#self.refreshers + 1] = { Refresh = function() btn:SetText(SettingsUI:PartLookName(part)) end }
    btn:SetText(self:PartLookName(part))
    return btn, row
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
    self.index, self.settingRows = {}, {}

    -- the rail | a hairline | the head over the cards' scroll frame
    self:BuildRail(panel)
    local rule = UI:Rule(panel, { vertical = true, alpha = 0.08, layer = "BORDER" })
    rule:ClearAllPoints()
    rule:SetPoint("TOPLEFT", panel, "TOPLEFT", RULE_X, -PAGE_TOP)
    rule:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", RULE_X, S.PAD)
    rule:SetWidth(1)
    self:BuildHead(panel)
    local scroll = UI:CreateScrollFrame(panel)
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", BODY_X, -(PAGE_TOP + HEAD_H))
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -S.PAD, S.PAD)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CARDS_W, CARDS_H)
    scroll:SetScrollChild(child)
    self.scroll, self.child = scroll, child
    -- the cards' right edge is the page's minus PAD, whatever the page's real width (GetWidth is 0 until laid out)
    scroll:HookScript("OnSizeChanged", function()
        if SettingsUI:SyncWidth() then SettingsUI:RequestRefresh() end
    end)

    -- every card of every group (made once; a page shows one), the look pages, a group's tiles, the search's results
    self.sections, self.cards, self.parts = {}, {}, {}
    for _, cat in ipairs(CATS) do
        for _, key in ipairs(cat.cards) do self:NewCard(cat, key) end
    end
    for _, p in ipairs(PARTS) do self:NewPartPage(p) end
    self:BuildTiles()
    self:BuildResults()
    -- (1.4.1's section names stay readable: sections.notify is the alerts grid, sections.ui the Looks card)
    for old, new in pairs(OLD) do self.sections[old] = self.sections[old] or self.sections[new] end
    -- (1.4.1's tests and links ask whether a section is in the nav: now whether its card shows for me)
    self.nav = {}
    for key in pairs(CARDS) do
        self.nav[key] = { IsShown = function() return SettingsUI:CardVisible(key) end }
    end

    panel:SetScript("OnShow", function(p)
        if p.dirty then SettingsUI:Refresh() end
    end)
    function panel:OnPanelShown()
        SettingsUI:Refresh()
    end
    if self.section then self:SelectSection(self.section) else self:OpenCategory(self.cat or "general") end
    self:Refresh()
    return panel
end

---------------------------------------------------------------------------
-- The rail: the search, a row per group (its icon, name and a live line), Help at the foot
---------------------------------------------------------------------------
function SettingsUI:BuildRail(panel)
    local rail = CreateFrame("Frame", nil, panel)
    rail:SetPoint("TOPLEFT", panel, "TOPLEFT", S.PAD, -PAGE_TOP)
    rail:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", S.PAD, S.PAD)
    rail:SetWidth(RAIL_W)
    self.rail = rail
    self.searchBox = UI:CreateSearchBox(rail, RAIL_W, function(text) SettingsUI:Search(text) end, "Search settings")
    self.searchBox:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, 0)
    self.searchBox:SetHeight(SEARCH_H)
    rail.rows = {}
    local y = -(SEARCH_H + 8)
    for _, cat in ipairs(CATS) do
        local b = CreateFrame("Button", nil, rail)
        b.cat = cat.key
        local h, tile = cat.small and HELP_H or GROUP_H, cat.small and 22 or 30
        b:SetHeight(h)
        if cat.small then
            b:SetPoint("BOTTOMLEFT", rail, "BOTTOMLEFT", 0, 0)
            b:SetPoint("BOTTOMRIGHT", rail, "BOTTOMRIGHT", 0, 0)
        else
            b:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, y)
            b:SetPoint("TOPRIGHT", rail, "TOPRIGHT", 0, y)
            y = y - (h + GROUP_GAP)
        end
        UI:DecorateRow(b, { selectable = true })
        -- the group's glyph on a dark tile (the Blizzard options panel's page cards)
        b.tile = UI:CreateIconTile(b, tile)
        b.tile:SetPoint("LEFT", b, "LEFT", 10, 0)
        local co = UI:IconCoords(cat.icon)
        b.tile.tex:SetTexture(UI.ICON_ATLAS)
        b.tile.tex:SetTexCoord(co[1], co[2], co[3], co[4])
        b.tile.tex:ClearAllPoints()
        b.tile.tex:SetPoint("CENTER")
        b.tile.tex:SetSize(floor(tile * 0.55), floor(tile * 0.55))
        b.tile.outer:SetColorTexture(S:Color("INSET"))
        b.name = UI:Text(b, cat.small and "body" or "emph", "TEXT")
        b.line = UI:Text(b, "small", "SUB")
        b.line:SetWordWrap(false)
        local x = 10 + tile + 10
        if cat.small then
            b.name:SetPoint("LEFT", b, "LEFT", x, 0)
        else
            b.name:SetPoint("BOTTOMLEFT", b, "LEFT", x, 1)
            b.line:SetPoint("TOPLEFT", b, "LEFT", x, -3)
        end
        b.name:SetText(cat.label)
        b.lineW = RAIL_W - x - 8
        b:SetScript("OnClick", function() SettingsUI:OpenCategory(cat.key) end)
        rail.rows[cat.key] = b
    end
end

-- One line per group in the rail: how it is set right now.
local SUMMARY = {
    general = function()
        return format("Opens on %s · %s names", Get("openOn", "home") == "last" and "last tab" or "Home",
            tostring(Get("tooltip.maxNames", 5)))
    end,
    alerts = function()
        local N = ns.Notify
        local s = N and N.Settings and N.Settings()
        if s and (tonumber(s.dndUntil) or 0) > ns.Util.Now() then return "Paused for an hour" end
        local pop = Get("alerts.personalToast", true) and 1 or 0
        local snd = Get("alerts.sound", true) and 1 or 0
        for _, def in ipairs(N and N:GetKinds() or {}) do
            if N:Wants(def.kind, "popup") then pop = pop + 1 end
            if N:Wants(def.kind, "sound") then snd = snd + 1 end
        end
        return format("%d pop up · %d with a sound", pop, snd)
    end,
    loot = function()
        local status, from = SettingsUI:GroupRulesStatus()
        local secs = tonumber(Effective("roll.duration", 30)) or 30
        if status == "remote" then return format("%s's rules · %d s", from and NameOf(from) or "Leader", secs) end
        return format("%s rules · %d s rolls", status == "mine" and "Group" or "Your", secs)
    end,
    combat = function()
        return format("Damage %s · threat %s", Get("meters.dmg", false) and "on" or "off",
            Get("meters.thr", false) and "on" or "off")
    end,
    interface = function()
        local Look = ns.Look
        if not (Look and Look.PARTS) then return "" end
        local all, n = Get("ui.look", "blizzard"), 0
        for _, p in ipairs(Look.PARTS) do
            if Get("ui." .. p.key .. ".look", "inherit") == "inherit" and (p.key ~= "sct" or Get("ui.sct.on", false)) then
                n = n + 1
            end
        end
        local l = Look.BY_KEY[all]
        if all == "blizzard" and n == #Look.PARTS - (Get("ui.sct.on", false) and 0 or 1) then return "The game's own frames" end
        return format("%s on %d of %d parts", l and l.name or "Blizzard", n, #Look.PARTS)
    end,
    guild = function()
        local G = ns.Guild
        local r = (G and G.GetAttendanceRules and G:GetAttendanceRules()) or { o = 5, d = 10 }
        local CU = ns.CouncilUI
        local sum = CU and CU.GetCouncilSummary and CU:GetCouncilSummary()
        local n = sum and sum.guildMembers and #sum.guildMembers or 0
        return format("Council of %d · %d / %d min", n, tonumber(r.o) or 0, tonumber(r.d) or 0)
    end,
}
SettingsUI.SUMMARY = SUMMARY

function SettingsUI:LayoutRail()
    local rail = self.rail
    if not rail then return end
    for key, b in pairs(rail.rows) do
        local on = not self.query and self.cat == key
        b:SetSelected(on)
        b.name:SetTextColor(S:Color(on and "GOLD" or "TEXT"))
        b.tile.tex:SetVertexColor(S:Color(on and "GOLD" or "SUB"))
        local fn = SUMMARY[key]
        if fn then
            local ok, text = pcall(fn)
            UI:FitText(b.line, ok and text or "", b.lineW)
        end
    end
end

---------------------------------------------------------------------------
-- The head: the group's name (or "Search") and a line under it; on a card's or a look part's page the way back
-- ("< Combat"), that page's own head (its name, who sets it, its switch, Back to defaults) and its lead line
---------------------------------------------------------------------------
function SettingsUI:BuildHead(panel)
    local head = CreateFrame("Frame", nil, panel)
    head:SetPoint("TOPLEFT", panel, "TOPLEFT", BODY_X, -PAGE_TOP)
    head:SetSize(CARDS_W, PAGE_HEAD_H)
    head.title = UI:Text(head, "page")
    head.title:SetPoint("TOPLEFT", head, "TOPLEFT", 0, -2)
    head.back = UI:CreateBackLink(head, "", function() SettingsUI:GoBack() end)
    head.back:SetPoint("TOPLEFT", head, "TOPLEFT", 0, -1)
    head.back:Hide()
    -- (the group's or the page's line; while searching how many options match)
    head.lead = UI:Text(head, "body", "SUB")
    head.lead:SetWordWrap(false)
    head.sub = head.lead
    self.head = head
end

-- The open page's own head (a card's, a look part's), or nil on a group's tiles and the search.
function SettingsUI:PageHead()
    if self.mode == "card" then
        local card = self.cards and self.cards[self.section]
        return card and card.head, card
    elseif self.mode == "part" then
        local page = self.parts and self.parts[self.part]
        return page and page.head, page
    end
end

-- Back from a card's page to its group's tiles, from a look part's page to Interface > Looks.
function SettingsUI:GoBack()
    if self.mode == "part" then return self:SelectSection("looks") end
    return self:OpenCategory(self.cat)
end

local function LeadText(lead)
    if type(lead) == "function" then
        local ok, t = pcall(lead)
        return ok and t or ""
    end
    return lead or ""
end

function SettingsUI:LayoutHead()
    local head = self.head
    if not head then return end
    local cat = CAT[self.cat] or CATS[1]
    local mode = self.query and "search" or self.mode
    local mine = self:PageHead()
    for _, c in pairs(self.cards or {}) do c.head:SetShown(c.head == mine and not self.query) end
    for _, p in pairs(self.parts or {}) do p.head:SetShown(p.head == mine and not self.query) end
    local paged = (mode == "card" or mode == "part") and mine ~= nil
    head.title:SetShown(not paged)
    head.back:SetShown(paged)
    head.lead:ClearAllPoints()
    head.lead:SetPoint("TOPLEFT", head, "TOPLEFT", 0, paged and (PAGE_TITLE_Y - 27) or -27)
    local lead
    if mode == "search" then
        head.title:SetText("Search")
        lead = self.searchCount or ""
    elseif paged then
        if mode == "part" then
            head.back:SetText("Looks")
            local _, tip = PartInfo(self.part)
            lead = tip or ""
        else
            local card = self.cards[self.section]
            head.back:SetText((CAT[card.cat] or cat).label)
            lead = LeadText(card.def.lead)
        end
    else
        head.title:SetText(cat.label)
        lead = cat.lead or ""
    end
    UI:FitText(head.lead, lead, CARDS_W)
end

---------------------------------------------------------------------------
-- The cards of the open group, a look page, or the search's results
---------------------------------------------------------------------------

-- Is that card there for me (class tools for my class, the set-up checklist for the Guild Master)?
function SettingsUI:CardVisible(key)
    local def = CARDS[key]
    if not def then return false end
    return not def.visible or def.visible() and true or false
end

function SettingsUI:IsGM()
    local G = ns.Guild
    return (G and G.IsGM and ns.Util and G:IsGM(ns.Util.PlayerKey())) and true or false
end

-- Who sets a card, on its head: the group's loot leader, the Guild Master (nil: just me, no pill).
local function ScopePill(card)
    local scope = card.def.scope
    if scope == "group" then
        local status, from = SettingsUI:GroupRulesStatus()
        if status == "remote" then return "alt", "Your group · set by " .. (from and NameOf(from) or "the loot leader") end
        if status == "mine" then return "alt", "Your group · you set these" end
        return "alt", "Your group"
    elseif scope == "guild" then
        return "bis", SettingsUI:IsGM() and "Guild · you set these" or "Guild · set by the Guild Master"
    elseif scope == "gm" then
        return "bis", "Guild Master"
    end
end

-- The looks picked away from the defaults: the look for everything, each part's own look.
function SettingsUI:LooksChanged()
    local n = Get("ui.look", "blizzard") ~= "blizzard" and 1 or 0
    for _, p in ipairs(ns.Look and ns.Look.PARTS or {}) do
        if Get("ui." .. p.key .. ".look", "inherit") ~= "inherit" then n = n + 1 end
    end
    return n
end

-- How many rows of a card (or a look page: "part:<key>") are not at their defaults.
function SettingsUI:ChangedIn(key)
    local n = 0
    for _, row in ipairs(self.settingRows or {}) do
        if row.cardKey == key and RowChanged(row) then n = n + 1 end
    end
    -- (a game part's page: its own look too)
    local part = type(key) == "string" and key:match("^part:(%a+)$")
    if part and not (PART[part] and (PART[part].kind or PART[part].kits))
        and Get("ui." .. part .. ".look", "inherit") ~= "inherit" then
        n = n + 1
    end
    return n
end

function SettingsUI:ResetCard(key)
    for _, row in ipairs(self.settingRows or {}) do
        if row.cardKey == key and RowChanged(row) then
            if row.reset then
                row.reset()
            elseif row.apply and row.setting then
                row.apply(row.setting.default)
            end
        end
    end
    -- (Interface > Looks: the look for everything and every part's own look go back too; a part's page: its look)
    local part = type(key) == "string" and key:match("^part:(%a+)$")
    if ns.DB and key == "looks" then
        for _, p in ipairs(ns.Look and ns.Look.PARTS or {}) do
            if Get("ui." .. p.key .. ".look", "inherit") ~= "inherit" then ns.DB:SetSetting("ui." .. p.key .. ".look", nil) end
        end
        if Get("ui.look", "blizzard") ~= "blizzard" then ns.DB:SetSetting("ui.look", nil) end
    elseif ns.DB and part and Get("ui." .. part .. ".look", "inherit") ~= "inherit" then
        ns.DB:SetSetting("ui." .. part .. ".look", nil)
    end
    self:Refresh()
end

-- The head of a card's page: its pill, its master switch, Back to defaults with the count, its action.
local function PaintCardHead(card)
    local head = card.head
    local kind, text = ScopePill(card)
    if text then
        head.pill:SetPill(kind, text)
        head.pill:Show()
    else
        head.pill:Hide()
    end
    local n = SettingsUI:ChangedIn(card.key)
    if card.key == "looks" then n = n + SettingsUI:LooksChanged() end
    PaintPageHead(head, n, card.def.master)
end

-- The open page's master switch (a card's, a look part's), or nil.
function SettingsUI:PageMaster()
    if self.query then return nil end
    if self.mode == "card" then
        local def = CARDS[self.section]
        return def and def.master
    elseif self.mode == "part" then
        return PART[self.part] and PART[self.part].master
    end
end

-- The scroll frame's height (under the short head of a group's tiles and the search, the tall one of a page).
function SettingsUI:ViewH()
    local h = self.scroll and tonumber(self.scroll:GetHeight())
    if h and h > 50 then return h end
    return self.viewH or CARDS_H
end

function SettingsUI:PlaceScroll(headH)
    if not self.scroll or self.scrollHeadH == headH then return end
    self.scrollHeadH = headH
    self.scroll:ClearAllPoints()
    self.scroll:SetPoint("TOPLEFT", self.panel, "TOPLEFT", BODY_X, -(PAGE_TOP + headH))
    self.scroll:SetPoint("BOTTOMRIGHT", self.panel, "BOTTOMRIGHT", -S.PAD, S.PAD)
    self.viewH = S.PAGE_H - PAGE_TOP - headH - S.PAD
end

-- A card's page: its rows, or the box while its master switch is off. Returns its height.
function SettingsUI:LayoutCardPage(card)
    PaintCardHead(card)
    local m, sec = card.def.master, card.sec
    local h
    if m and not MasterOn(m) then
        sec:Hide()
        card.off = card.off or self:OffBox(card, card.def.label, card.def.icon, m, card.def.offExtra)
        h = card.off:Layout(self:BodyWidth()) + 6 + 8
        card.off:Show()
    else
        if card.off then card.off:Hide() end
        sec:Show()
        local sh = max(1, floor((sec.height or 0) + 0.5))
        sec:SetHeight(sh)
        h = sh + 8
    end
    card:SetHeight(h)
    card:Show()
    return h
end

-- A look part's page: its stage over its look tiles and options, or the box while its switch is off (combat text).
function SettingsUI:LayoutPartPage(page)
    local p = PART[page.part]
    local m = p and p.master
    PaintPageHead(page.head, self:ChangedIn("part:" .. page.part), m)
    local h
    if m and not MasterOn(m) then
        page.stage:Hide()
        page.sec:Hide()
        page.off = page.off or self:OffBox(page, (PartInfo(page.part)), p.glyph, m)
        h = page.off:Layout(self:BodyWidth()) + 6 + 8
        page.off:Show()
    else
        if page.off then page.off:Hide() end
        page.stage:Show()
        page.sec:Show()
        local sh = max(1, floor((page.sec.height or 0) + 0.5))
        page.sec:SetHeight(sh)
        h = STAGE_H + 6 + sh + 8
    end
    page.height = h
    page:SetHeight(h)
    return h
end

-- Shows the open view: a group's tiles, a card's page, a look part's page or the search's results; places the scroll
-- frame under the head and sizes the scroll child.
function SettingsUI:LayoutCards()
    if not self.child then return end
    local mode = self.query and "search" or self.mode or "tiles"
    local open = mode == "card" and self.cards[self.section] or nil
    for _, c in pairs(self.cards) do
        if c ~= open and c:IsShown() then c:Hide() end
    end
    for k, p in pairs(self.parts) do p:SetShown(mode == "part" and k == self.part) end
    if self.results then self.results:SetShown(mode == "search") end
    if self.tileBox then self.tileBox:SetShown(mode == "tiles") end
    self:PlaceScroll((mode == "card" or mode == "part") and PAGE_HEAD_H or HEAD_H)
    local h = 0
    if mode == "tiles" then
        h = self:LayoutTiles()
    elseif open then
        h = self:LayoutCardPage(open)
    elseif mode == "part" and self.parts[self.part] then
        h = self:LayoutPartPage(self.parts[self.part])
    elseif mode == "search" and self.results then
        h = self.results.height or 0
    end
    self.child:SetHeight(max(self:ViewH(), floor(h + 0.5)))
end
SettingsUI.FitChild = SettingsUI.LayoutCards

-- (the scroll, kept inside its range)
local function ScrollTo(y)
    local S2 = SettingsUI
    if not S2.scroll then return end
    local maxY = max(0, (S2.child:GetHeight() or 0) - S2:ViewH())
    S2.scroll:SetVerticalScroll(min(maxY, max(0, floor(y + 0.5))))
end

-- A short gold light on a frame (a row or a card's head a link or the search opened).
local function Flash(f)
    if not f then return end
    if not f.dzFlash then
        local t = f:CreateTexture(nil, "BACKGROUND", nil, 3)
        t:SetAllPoints()
        t:SetColorTexture(S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 0.2)
        f.dzFlash = t
        if t.CreateAnimationGroup then
            local ag = t:CreateAnimationGroup()
            local a = ag:CreateAnimation("Alpha")
            a:SetFromAlpha(1)
            a:SetToAlpha(0)
            a:SetStartDelay(0.5)
            a:SetDuration(1.3)
            ag:SetScript("OnFinished", function() t:Hide() end)
            f.dzFlashAnim = ag
        end
    end
    f.dzFlash:SetAlpha(1)
    f.dzFlash:Show()
    if f.dzFlashAnim then
        f.dzFlashAnim:Stop()
        f.dzFlashAnim:Play()
    elseif C_Timer then
        C_Timer.After(1.8, function() f.dzFlash:Hide() end)
    end
end
SettingsUI.Flash = Flash

-- (once the page is laid out: the next frame)
local function Later(fn)
    if C_Timer and C_Timer.After then C_Timer.After(0, fn) else fn() end
end

local function InChild(f)
    local child = SettingsUI.child
    while f do
        if f == child then return true end
        f = f.GetParent and f:GetParent() or nil
    end
    return false
end

-- Scrolls a row of the open page into the middle and lights it (a frame out of the scroll, a page head's switch: only
-- lit; on a page that shows its off box, its Switch on too).
function SettingsUI:ShowRow(row)
    if not (row and self.child) then return end
    if InChild(row) then
        local top, ct = row:GetTop(), self.child:GetTop()
        if top and ct then ScrollTo(ct - top - (self:ViewH() - ROW_H) / 2) end
    end
    Flash(row)
    local _, page = self:PageHead()
    if page and page.off and page.off:IsShown() then Flash(page.off.on) end
end

-- Makes a row of the open page showable and returns what to light: its More options fold opened; for a row hidden by
-- a switch it needs, that switch's row; on a page whose master switch is off, the head's switch.
function SettingsUI:RevealRow(row)
    local m = self:PageMaster()
    if m and not MasterOn(m) then
        local head = self:PageHead()
        return head and head.master or row
    end
    if row and row.need and not row.need() and row.needOf then row = row.needOf end
    local sec = row and row.sec
    if sec and row.more and not self:MoreOpen(sec) then self:SetMoreOpen(sec, true) end
    return row
end

-- Opens the page that holds a control or a row (a test's or a link's "show me this"): its card, look part or class
-- tool, the fold it is in. Returns the page's key.
function SettingsUI:Reveal(f)
    local p = f
    while p do
        local masterOf = rawget(p, "masterOf")
        if masterOf then
            self:SelectSection(masterOf)
            return masterOf
        end
        local sec = rawget(p, "sec")
        if sec and rawget(p, "title") and type(sec) == "table" and sec.rows then
            local key = sec.key
            if key == "search" then return nil end
            self:SelectSection(key)
            self:RevealRow(p)
            return key
        end
        local k = rawget(p, "key")
        if k and self.sections and self.sections[k] == p then
            self:SelectSection(k)
            return k
        end
        p = p:GetParent()
    end
end

-- Opens a group: its tiles.
function SettingsUI:OpenCategory(key)
    local cat = CAT[key] or CATS[1]
    self:ClearSearch()
    self.cat, self.section, self.part, self.mode = cat.key, nil, nil, "tiles"
    self:LayoutView()
    if self.scroll then self.scroll:SetVerticalScroll(0) end
end

-- Opens a part's page in Interface > Looks (its key in PARTS).
function SettingsUI:OpenPart(key)
    if not ns.MainFrame then return end
    if ns.MainFrame.GetSelectedTab and ns.MainFrame:GetSelectedTab() ~= "settings" then ns.MainFrame:Open("settings") end
    if not (self.parts and self.parts[key]) then return end
    self:ClearSearch()
    self.cat, self.section, self.part, self.mode = "interface", "looks", key, "part"
    self:PreparePart(key)
    self:Relayout(self.parts[key].sec)
    self:LayoutView()
    if self.scroll then self.scroll:SetVerticalScroll(0) end
end

function SettingsUI:LayoutView()
    self:LayoutRail()
    self:LayoutHead()
    self:LayoutCards()
end

---------------------------------------------------------------------------
-- A group's tiles: one per card there for me, two to a row: its glyph on a dark tile, its name (and who sets it), its
-- master switch (flips it right there), a line that says how it is set, "Settings >". A click opens its page.
---------------------------------------------------------------------------
function SettingsUI:BuildTiles()
    local box = CreateFrame("Frame", nil, self.child)
    box:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, 0)
    box:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, 0)
    box:SetHeight(1)
    box:Hide()
    self.tileBox, self.tiles = box, {}
end

local TILE_X = 12 + 34 + 12        -- the texts' left edge (after the glyph's tile)

local function TileEnter(t)
    UI:SetEdgeColor(t, S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 0.55)
end

local function TileLeave(t)
    UI:SetEdgeColor(t, S:Color("EDGE"))
end

function SettingsUI:NewTile(key)
    local def = CARDS[key]
    local t = UI:CreateCard(self.tileBox, { pad = 0, onClick = function(self) SettingsUI:SelectSection(self.key) end })
    t.body:Hide()
    t.key, t.def = key, def
    t:SetHeight(TILE_H)
    t.tile = UI:CreateIconTile(t, 34)
    t.tile:SetPoint("TOPLEFT", t, "TOPLEFT", 12, -12)
    local co = UI:IconCoords(def.icon or 24)
    t.tile.tex:SetTexture(UI.ICON_ATLAS)
    t.tile.tex:SetTexCoord(co[1], co[2], co[3], co[4])
    t.tile.tex:ClearAllPoints()
    t.tile.tex:SetPoint("CENTER")
    t.tile.tex:SetSize(18, 18)
    t.tile.outer:SetColorTexture(S:Color("INSET"))
    t.name = UI:Text(t, "emph", "TEXT")
    t.name:SetPoint("TOPLEFT", t, "TOPLEFT", TILE_X, -13)
    t.name:SetText(def.label)
    t.pill = UI:CreatePill(t, 14)
    t.pill:SetPoint("LEFT", t.name, "RIGHT", 8, 0)
    t.pill:Hide()
    t.sum = UI:Text(t, "small", "SUB", { wrap = true })
    t.sum:SetPoint("TOPLEFT", t, "TOPLEFT", TILE_X, -32)
    if t.sum.SetMaxLines then t.sum:SetMaxLines(2) end
    t.go = UI:Text(t, "small", "GOLD")
    t.go:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", TILE_X, 11)
    t.go:SetText("Settings")
    t.chev = t:CreateTexture(nil, "ARTWORK")
    t.chev:SetSize(8, 8)
    t.chev:SetPoint("LEFT", t.go, "RIGHT", 3, 0)
    UI:SetChevron(t.chev, true)
    t.chev:SetVertexColor(S:Color("GOLD"))
    local m = def.master
    if m then
        local sw = ns.UI:CreateSwitch(t, function() return MasterOn(m) end,
            function(a, b) SettingsUI:SetMaster(m, Bool(a, b)) end)
        sw:SetPoint("TOPRIGHT", t, "TOPRIGHT", -12, -12)
        sw.label = t.name
        AddTooltip(sw, m.title, m.desc)
        t.switch = sw
        m.switches = m.switches or {}
        m.switches[#m.switches + 1] = sw
    end
    t:HookScript("OnEnter", TileEnter)
    t:HookScript("OnLeave", TileLeave)
    self.tiles[key] = t
    return t
end

-- (who sets it, short, on its tile)
local TILE_SCOPE = { group = { "alt", "Your group" }, guild = { "bis", "Guild" }, gm = { "bis", "Guild Master" } }

-- A tile's look now: its line, its switch, dimmed while its feature is off.
function SettingsUI:PaintTile(t)
    local def = t.def
    local on = true
    if def.master then
        on = MasterOn(def.master)
        t.switch:SetChecked(on)
    end
    t.name:SetTextColor(S:Color(on and "TEXT" or "SUB"))
    t.tile.tex:SetVertexColor(S:Color(on and "GOLD" or "DIM"))
    local sc = TILE_SCOPE[def.scope or ""]
    if sc then
        t.pill:SetPill(sc[1], sc[2])
        t.pill:Show()
    else
        t.pill:Hide()
    end
    local w = t:GetWidth() or 0
    if w < 100 then w = floor((self:BodyWidth() - TILE_GAP) / 2) end
    t.sum:SetWidth(w - TILE_X - 12)
    local text = ""
    if def.summary then
        local ok, s = pcall(def.summary)
        text = ok and s or ""
    end
    t.sum:SetText(text or "")
end

-- Places the open group's tiles; returns their height.
function SettingsUI:LayoutTiles()
    local box = self.tileBox
    if not box then return 0 end
    for _, t in pairs(self.tiles) do t:Hide() end
    local cat = CAT[self.cat] or CATS[1]
    local w = floor((self:BodyWidth() - TILE_GAP) / 2)
    local i = 0
    for _, key in ipairs(cat.cards) do
        if self:CardVisible(key) then
            local t = self.tiles[key] or self:NewTile(key)
            local col, row = i % 2, floor(i / 2)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", box, "TOPLEFT", col * (w + TILE_GAP), -row * (TILE_H + TILE_GAP))
            t:SetSize(w, TILE_H)
            self:PaintTile(t)
            t:Show()
            i = i + 1
        end
    end
    local rows = math.ceil(i / 2)
    local h = max(1, rows * (TILE_H + TILE_GAP) - TILE_GAP)
    box:SetHeight(h)
    box:Show()
    return h + 6
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
    sec.top = 6
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
        body.fitW = BODY_W - 2 * KIT_INSET
        -- (its rows go into the search under Combat > Class tools > the tool)
        local outer = self.ctx
        if outer then
            self.ctx = { cat = outer.cat, card = outer.card, kit = key, path = { outer.path[1], outer.path[2], kit.label } }
        end
        if kit.settings then kit.settings(self, body) else body.height = 0 end
        self.ctx = outer
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
    if self.cards and self.cards.classtools and self.cards.classtools:IsShown() then self:LayoutCards() end
end

-- Opens a class tool's card (its key, e.g. "swing", "bless") in Combat > Class tools and scrolls to it.
function SettingsUI:OpenKit(key)
    if not (self.sections and self.sections.classtools) then return end
    kitOpen[key] = true
    self:SelectSection("classtools")
    self:LayoutClassTools()
    for _, card in ipairs(self.sections.classtools.cards) do
        if card.kit.key == key and card:IsShown() and self.scroll then
            local _, _, _, _, y = card:GetPoint(1)
            ScrollTo(-(tonumber(y) or 0) - 8)
            Flash(card.head)
        end
    end
end

-- Is that tool's card shown in Class tools (and Class tools there for me)?
function SettingsUI:KitShown(key)
    if not self:CardVisible("classtools") then return false end
    for _, card in ipairs(self.sections.classtools.cards or {}) do
        if card.kit.key == key then return card:IsShown() end
    end
    return false
end

SettingsUI.PlaceText = PlaceText

-- Opens a place in Settings and shows it: a card's page, a class tool ("bless", "swing": its card in Class tools,
-- open), a group's tiles ("loot"), a part's look page ("look.units"), or a section of 1.4.1 and before (OLD). A card
-- that is not there for me opens its group. rowTitle (optional): the option of that card to show and light (its fold
-- opened; hidden by a switch: that switch).
function SettingsUI:SelectSection(key, rowTitle)
    if type(key) ~= "string" then key = "general" end
    if ns.ClassKit and ns.ClassKit:Get(key) and not CARDS[key] then
        return self:OpenKit(key)
    end
    key = OLD[key] or key
    local part = key:match("^look[.:](%a+)$")
    if part and PART[part] then return self:OpenPart(part) end
    if CAT[key] and not CARDS[key] then return self:OpenCategory(key) end
    if not CARDS[key] then key = "window" end
    if not self:CardVisible(key) then return self:OpenCategory(CARD_CAT[key]) end
    self.section, self.cat, self.part, self.mode = key, CARD_CAT[key], nil, "card"
    if not self.sections then return end
    self:ClearSearch()
    self:Relayout(self.sections[key])
    self:LayoutView()
    if self.scroll then self.scroll:SetVerticalScroll(0) end
    if rowTitle then
        for _, row in ipairs(self.cards[key].sec.rows) do
            if row.title and row.title.GetText and row.title:GetText() == rowTitle then
                local target = self:RevealRow(row)
                Later(function() SettingsUI:ShowRow(target) end)
                return
            end
        end
    end
end

-- The open card (its key), "looks" on a look part's page, the group on its tiles.
function SettingsUI:GetSection()
    return self.section or self.cat
end

-- A card's rows' width: the scroll frame's, once it is laid out (BODY_W before).
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

---------------------------------------------------------------------------
-- The sections
---------------------------------------------------------------------------
-- The raid session crest: who sees it (UI/SessionBar.lua builds the row).
function SettingsUI:BuildSession(sec)
    if ns.SessionBar and ns.SessionBar.BuildSettings then ns.SessionBar:BuildSettings(self, sec) end
end

-- The drop panel and the loot window (the BiS toast, its sound and chat line are rows of the alerts grid now).
function SettingsUI:BuildDrops(sec)
    sec.y = sec.y - 4
    local _, panel = self:SwitchSetting(sec, "Boss drop panel", "Opens on boss drops for the Loot Council and the master looter.",
        "alerts.councilPanel", true)
    local _, pos = self:DropdownSetting(sec, "Drop panel position", "Next to the loot window, or where you left it.",
        "dropPanelMode", "auto", {
            { value = "auto", text = "Attach to the loot window" },
            { value = "floating", text = "Always floating" },
        })
    self:Needs(pos, IsOn("alerts.councilPanel", true), panel)
    self:SwitchSetting(sec, "Glow on BiS loot buttons", "Your list's items glow in the loot window.",
        "alerts.glow", true)
    self:SwitchSetting(sec, "BiS badges on the loot window",
        "Marks your items; on the Loot Council also how many raiders need each one.", "alerts.lootBadges", true)
    self:EndSection(sec)
end

-- Notifications (Core/Notify.lua, UI/Notify.lua): the bell keeps everything; these decide what interrupts. One row per
-- kind the sections registered, three switches each (pop-up, sound, chat line) under the columns' names.
local NOTIFY_COLS = { { what = "popup", label = "Pop-up" }, { what = "sound", label = "Sound" }, { what = "chat", label = "Chat" } }
local NOTIFY_COL_W = 58

-- The BiS drop alert in the grid: its toast, its sound (the drop panel plays it too) and its chat line are the
-- alerts.* settings of 1.4.1 (Core reads them as before).
local BIS_KIND = { kind = "bis", section = "Loot", label = "On your BiS list!",
    desc = "Something on your list drops: a toast, a sound, a line in chat.",
    paths = { popup = "alerts.personalToast", sound = "alerts.sound", chat = "alerts.chat" } }

-- A notification kind's row: its name and line, a switch per way it reaches me. labels: the columns' names over the
-- switches (a search result, away from the grid's head).
function SettingsUI:NotifyRow(sec, def, labels)
    local N = ns.Notify
    local row = self:Row(sec, def.label, def.desc)
    row.switches = {}
    for i, col in ipairs(NOTIFY_COLS) do
        local kind, what = def.kind, col.what
        local getter, setter
        if def.paths then
            local path = def.paths[what]
            getter = function() return Get(path, true) and true or false end
            setter = function(a, b) Set(path, Bool(a, b)) end
        else
            getter = function() return N:Wants(kind, what) end
            setter = function(a, b) N:SetWants(kind, what, Bool(a, b)) end
        end
        local sw = ns.UI:CreateSwitch(row, getter, setter)
        sw:SetPoint("RIGHT", row, "RIGHT", -(#NOTIFY_COLS - i) * NOTIFY_COL_W, labels and -6 or 0)
        sw.label = row.title
        row.switches[what] = sw
        if labels then
            local fs = UI:Text(row, "small", "SUB", { justify = "CENTER", width = NOTIFY_COL_W })
            fs:SetPoint("BOTTOM", sw, "TOP", 0, 1)
            fs:SetText(col.label)
        end
        self.refreshers[#self.refreshers + 1] = sw
    end
    PlaceText(row, #NOTIFY_COLS * NOTIFY_COL_W - (NOTIFY_COL_W - SWITCH_W))
    -- (a kind is changed while one of its ways differs from the kind's own default; Back to defaults forgets mine)
    if def.paths then
        row.isChanged = function()
            for _, path in pairs(def.paths) do if not Get(path, true) then return true end end
            return false
        end
        row.reset = function() for _, path in pairs(def.paths) do Set(path, true) end end
    else
        row.isChanged = function()
            local s = N.Settings and N.Settings()
            local mine = s and s.kinds and s.kinds[def.kind]
            if type(mine) ~= "table" then return false end
            for _, col in ipairs(NOTIFY_COLS) do
                if mine[col.what] ~= nil and (mine[col.what] and true or false) ~= (def[col.what] and true or false) then
                    return true
                end
            end
            return false
        end
        row.reset = function()
            local s = N.Settings and N.Settings(true)
            if s and s.kinds then s.kinds[def.kind] = nil end
            ns:Fire("SETTINGS_CHANGED", "notify")
        end
    end
    self.settingRows[#self.settingRows + 1] = row
    if row.entry then row.entry.make = function(rs) return SettingsUI:NotifyRow(rs, def, true) end end
    return row
end

-- When to stay quiet: in combat, while the window is open, an hour's pause (Core/Notify.lua's settings).
function SettingsUI:BuildQuiet(sec)
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
    local _, row = self:Switch(sec, "Quiet in combat", "Pop-ups wait until the fight is over (boss fights too).", g, st)
    self:SetDefault(row, true)
    g, st = quiet("quietOpen")
    _, row = self:Switch(sec, "Quiet while the window is open", "Only the bell counts up while DisasterZone is open.", g, st)
    self:SetDefault(row, false)
    self:Switch(sec, "Pause pop-ups for an hour", "Nothing pops up or plays a sound; the bell still collects.",
        function()
            local s = N and N.Settings()
            return s and (tonumber(s.dndUntil) or 0) > ns.Util.Now() or false   -- (UI/Notify reads it so)
        end,
        function(a, b)
            local s = N and N.Settings(true)
            if s then s.dndUntil = Bool(a, b) and (ns.Util.Now() + 3600) or nil end
        end)
    self:EndSection(sec)
end

-- What reaches you: one grid for every kind of notification and the BiS drop alert, grouped by the part of the addon
-- they come from (Loot first, with the BiS alert on top), then "Off-spec items too" for the BiS alert.
local KIND_GROUPS = { "Loot", "Raids", "Dungeons", "Polls", "Games", "Feedback", "DisasterZone" }

function SettingsUI:BuildNotify(sec)
    local N = ns.Notify
    sec.y = sec.y - 2
    -- the columns' names over the switches
    local head = CreateFrame("Frame", nil, sec)
    head:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - 8)
    head:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y - 8)
    head:SetHeight(18)
    for i, col in ipairs(NOTIFY_COLS) do
        local fs = UI:Text(head, "small", nil, { justify = "CENTER", width = NOTIFY_COL_W })
        fs:SetPoint("RIGHT", head, "RIGHT", -(#NOTIFY_COLS - i) * NOTIFY_COL_W + (NOTIFY_COL_W - SWITCH_W) / 2 - 2, 0)
        fs:SetText(col.label)
    end
    sec.y = sec.y - 26
    -- the kinds by group, in the groups' order (one not listed goes last)
    local groups, order = {}, {}
    local function add(def)
        local g = def.section or "DisasterZone"
        if not groups[g] then
            groups[g] = {}
            order[#order + 1] = g
        end
        local list = groups[g]
        list[#list + 1] = def
    end
    add(BIS_KIND)
    for _, def in ipairs(N and N:GetKinds() or {}) do add(def) end
    local rank = {}
    for i, g in ipairs(KIND_GROUPS) do rank[g] = i end
    table.sort(order, function(a, b) return (rank[a] or 99) < (rank[b] or 99) end)
    -- the first group (Loot, with the BiS alert and its off-spec switch), then the rest under More options
    for gi, g in ipairs(order) do
        local h = UI:CreateSectionHeader(sec, g, { style = "caps" })
        self:Place(sec, h, 20, { gap = gi == 1 and 2 or 10, right = #NOTIFY_COLS * NOTIFY_COL_W + 8 })
        for _, def in ipairs(groups[g]) do self:NotifyRow(sec, def) end
        if gi == 1 then
            self:SwitchSetting(sec, "Off-spec items too", "Your BiS alerts also fire for items on your off-spec list.",
                "alerts.offspec", true)
            if #order > 1 then self:MoreOptions(sec) end
        end
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

    self:MoreOptions(sec)
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
    self:DropdownSetting(sec, "Announce channel", "Where awards and rolls are announced in a raid.",
        "announceChannel", "RAID", {
            { value = "RAID", text = "Raid" },
            { value = "RAID_WARNING", text = "Raid Warning" },
        }, "Raid Warning needs raid lead or assist; without them announcements go to Raid.")
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
    self:SwitchSetting(sec, "Who wants it (Loot Council)", "Council members see everyone who has the item on a list.",
        "tooltip.council", true)
    local nameOptions = {}
    for _, n in ipairs({ 3, 5, 8, 12 }) do nameOptions[#nameOptions + 1] = { value = n, text = tostring(n) } end
    self:DropdownSetting(sec, "Names shown", "Hold Shift over an item to see every name.", "tooltip.maxNames", 5,
        nameOptions)
    self:EndSection(sec)
end

---------------------------------------------------------------------------
-- Interface > Looks (UI/Look.lua and the addon's own themes): the look for everything, Classic everywhere, a tile per
-- part (a sample of it in the look it wears, its name, its look); a tile opens the part's page: the sample big on a
-- stage, the look tiles (pointing at one shows it on the stage), the part's options. A part switched to or from
-- Blizzard asks for a reload (UI/Look.lua).
---------------------------------------------------------------------------

-- The game parts' options (a part's page): { key, name, line, default, options (a dropdown; none: a switch), tip,
-- classic = only while the part wears Classic }.
local PART_OPTS = {
    units = {
        { "portrait", "Portrait", "Class icon for players; the game's portrait for the rest.", "class",
          { { value = "class", text = "Class icon" }, { value = "portrait", text = "Portrait" }, { value = "none", text = "None" } } },
        { "healthColor", "Health colour", "The look's: the game's green in Classic, class colours in the rest.", "theme",
          { { value = "theme", text = "The look's" }, { value = "class", text = "Class" }, { value = "green", text = "Green" },
            { value = "gradient", text = "By health" } } },
        { "healthText", "Health text", "", "both",
          { { value = "both", text = "14.2k  84%" }, { value = "pct", text = "84%" },
            { value = "full", text = "14,212 / 16,840" }, { value = "none", text = "None" } } },
        { "debuffs", "Auras on target", "Your own first, everyone's, or only yours.", "mine",
          { { value = "mine", text = "Mine first" }, { value = "all", text = "All" }, { value = "onlymine", text = "Only mine" } } },
        { "timers", "Aura timers", "Seconds left under each aura.", true },
    },
    group = {
        { "healthColor", "Health colour", "The look's: the game's green in Classic, class colours in the rest.", "theme",
          { { value = "theme", text = "The look's" }, { value = "class", text = "Class" }, { value = "green", text = "Green" },
            { value = "gradient", text = "By health" } } },
        { "player", "Me in my party", "Your own frame at the top of the party frames.", false },
        { "partyInRaid", "Party frames in a raid", "Off: your group is already in the raid frames.", false },
        { "tanks", "Main tanks", "Each main tank and the mob they hold, by the raid frames.", true,
          tip = "The raid leader or an assistant sets them: + under the rows, the plan's tanks in one click, or "
              .. "/maintank. Drag a row to reorder; move the block in Edit layout." },
        { "range", "Fade out of range", "Party and raid members too far to heal.", true },
        { "dispel", "Light what I can remove", "A debuff you can dispel colours the frame's edge.", true },
    },
    cast = {
        { "latency", "Latency", "A soft red end on your own casts: from there the next cast can be queued.", true,
          tip = "It is as long as the time your cast takes to reach the server (your world latency). When the "
              .. "fill reaches it, pressing the next spell already queues it." },
        { "time", "Time", "", "left",
          { { value = "left", text = "0.6" }, { value = "both", text = "0.6 / 1.5" }, { value = "none", text = "None" } } },
        { "icon", "Spell icon", "", true },
        { "target", "Target's cast bar", "", true },
        { "focus", "Focus's cast bar", "", true },
    },
    bars = {
        { "dock", "Dock", "Every bottom bar on one grid: the bars, bags, menu, stance, pet and experience.", true,
          tip = "Action bars 1 to 3 make one block (turn bars 2 and 3 on in the game's Options > Action Bars), "
              .. "the bags and the menu stand beside it at its height, the stance and pet bars sit on top and "
              .. "the experience bar runs under it. Bars 4 and 5 stand at the right edge. Move it in Edit "
              .. "layout. Turning it off hands the bars back to the game after a reload." },
        { "size", "Button size", "Every gap and edge of the Dock grows with it.", 36,
          { { value = 30, text = "Compact (30)" }, { value = 33, text = "Small (33)" }, { value = 36, text = "Normal (36)" },
            { value = 39, text = "Big (39)" }, { value = 42, text = "Large (42)" } } },
        { "rail", "Bars 4 and 5 at the right edge", "In the Dock's look and size, two columns.", true },
        { "art", "Bar art", "The plate behind the bars: stone and steel, marble and gold, or the guild vault.",
          -- (listed here: UI/DockArt.lua loads after this file, so its SETS are not there yet)
          "ironforge", { { value = "ironforge", text = "Ironforge" }, { value = "stormwind", text = "Stormwind" },
                         { value = "vault", text = "Guild Vault" } }, classic = true,
          tip = "Ironforge: the vanilla bar's stone, a riveted steel frame and carved wells. Stormwind: dark marble "
              .. "set in gold with sapphires. Guild Vault: the guild bank's iron, crimson leather and brass slots." },
        { "caps", "End caps", "At the Dock's ends: the art's own, gryphons or lions.", "match",
          { { value = "match", text = "Match the art" }, { value = "gryphon", text = "Gryphons" },
            { value = "lion", text = "Lions" }, { value = "none", text = "None" } }, classic = true },
        { "keys", "Key binds", "", true },
        { "macros", "Macro names", "", false },
        { "cooldown", "Cooldowns", "", "theme",
          { { value = "theme", text = "Sweep and number" }, { value = "sweep", text = "Sweep" },
            { value = "numbers", text = "Number" } } },
        { "range", "Out of range", "", "icon", { { value = "icon", text = "Red icon" }, { value = "key", text = "Red key bind" } } },
        { "xp", "Experience bar", "Your experience and the reputation you watch, in the look.", true },
    },
    bags = {
        { "layout", "Layout", "How the window lays out your items. Only the view changes: items stay in their slots.",
          "one", { { value = "one", text = "One bag" }, { value = "shelves", text = "Shelves" },
                   { value = "bags", text = "Bag by bag" } } },
        { "newglow", "Glow on new items", "Until you have seen them once.", true },
    },
    minimap = {
        { "shape", "Shape", "The look's own: round for Halo and Gilded, square for the rest.", "theme",
          { { value = "theme", text = "The look's" }, { value = "round", text = "Round" }, { value = "square", text = "Square" } } },
        { "buttons", "Addon buttons", "Minimap buttons of other addons.", "edge",
          { { value = "edge", text = "Round the edge" }, { value = "drawer", text = "In a drawer" },
            { value = "hover", text = "On mouse-over" } } },
        { "clock", "Clock", "", true },
        { "zone", "Zone", "", true },
    },
    sct = {
        { "place", "Where numbers go", "On the nameplate of the mob you hit, or in fixed columns beside you.", "plate",
          { { value = "plate", text = "On the nameplate" }, { value = "columns", text = "Columns" } },
          tip = "Numbers ride the plate of the mob they hit (enemy nameplates on). A mob without a plate shown, or "
              .. "Columns, uses the target spot. Move the spots in Edit layout." },
        { "size", "Size", "", 1,
          { { value = 0.7, text = "Small" }, { value = 0.85, text = "Medium" }, { value = 1, text = "Large" },
            { value = 1.15, text = "Huge" } } },
        { "hideGame", "Hide the game's numbers", "Its damage and healing numbers stay off while these are on.", true },
        { "merge", "Merge hits", "Ticks and hits that land together count up as one.", "theme",
          { { value = "theme", text = "The look's" }, { value = "on", text = "Always" }, { value = "off", text = "Never" } },
          tip = "The look's: every look merges but Classic, which shows each number like the game." },
        { "taken", "Hits taken", "", true },
        { "heals", "Heals on me", "With the healer's name.", true },
        { "procs", "Procs", "Buffs you gain in combat that last a minute or less.", true },
        { "alerts", "Spells that light up", "Hammer of Wrath, Execute, Overpower, Revenge, Riposte ...", true },
        { "lowHealth", "Low health and mana", "", true },
        { "autoAttacks", "Auto attacks", "", true },
        { "minHit", "Hide hits under", "Crits always show.", 0,
          { { value = 0, text = "Show all" }, { value = 100, text = "100" }, { value = 250, text = "250" },
            { value = 500, text = "500" }, { value = 1000, text = "1,000" } } },
        { "minHeal", "Hide heals under", "", 0,
          { { value = 0, text = "Show all" }, { value = 100, text = "100" }, { value = 250, text = "250" },
            { value = 500, text = "500" }, { value = 1000, text = "1,000" } } },
    },
    -- (the meter panels' look, moved from Combat > Meters: { setting path, name, line, default, options })
    meters = {
        { "meters.barColor", "Bar colour", "What colours the bars.", "class",
          { { value = "class", text = "Class colour" }, { value = "role", text = "Role colour" },
            { value = "one", text = "One colour" } } },
        { "meters.icons", "Icons", "The picture in front of each name.", "theme",
          { { value = "theme", text = "Theme default" }, { value = "spec", text = "Spec" }, { value = "class", text = "Class" },
            { value = "none", text = "None" } } },
        { "meters.rowSize", "Rows", "Bar height; the theme sets its own.", "theme",
          { { value = "compact", text = "Compact" }, { value = "theme", text = "Theme default" }, { value = "roomy", text = "Roomy" } } },
        { "meters.numbers", "Numbers", "How amounts are written.", "short",
          { { value = "short", text = "380.1k" }, { value = "full", text = "380,112" }, { value = "round", text = "380k" } } },
        { "meters.bg", "Background", "How dark the panels are behind the bars.", "theme",
          { { value = "theme", text = "Theme default" }, { value = 0, text = "None" }, { value = 25, text = "25%" },
            { value = 50, text = "50%" }, { value = 75, text = "75%" }, { value = 90, text = "90%" } } },
        { "meters.size", "Size", "Bar height and text size together.", "normal",
          { { value = "small", text = "Small" }, { value = "normal", text = "Normal" }, { value = "large", text = "Large" } } },
    },
}

local PART_COLS, PART_TILE_H, PART_GAP, PV_H = 5, 80, 6, 42

-- (a part's name and line: the game's parts from Look.PARTS, the themed ones from PARTS)
function PartInfo(key)
    for _, p in ipairs(ns.Look and ns.Look.PARTS or {}) do
        if p.key == key then return p.name, p.tip end
    end
    local p = PART[key]
    return p and p.label or key, p and p.tip or ""
end

-- Is the part there for me (class bars and timers: their class tools are my class's, or demo mode)?
function SettingsUI:PartShown(key)
    local p = PART[key]
    if not (p and p.kits) then return true end
    local CK = ns.ClassKit
    if not CK then return false end
    for _, k in ipairs(p.kits) do
        local kit = CK:Get(k)
        if kit and (CK:IsDemo() or kit.class == CK:MyClass()) then return true end
    end
    return false
end

-- The look a part wears now (a game part's look key, a themed part's theme key).
local function PartLook(key)
    local p = PART[key]
    local T = ns.Themes
    if p and p.kind then
        local t = T and T:Kind(p.kind) and T:Current(p.kind)
        return t and t.key
    elseif key == "timers" then
        local kind = "ring_swing"
        local CK = ns.ClassKit
        if CK and CK:Get("shot") and CK:MyClass() == CK:Get("shot").class then kind = "ring_shot" end
        local t = T and T:Kind(kind) and T:Current(kind)
        return t and t.key, kind == "ring_shot" and "shot" or "swing"
    end
    local Look = ns.Look
    if not Look then return "blizzard" end
    local T2 = T and T:Kind("uilook." .. key) and T:Preview("uilook." .. key)
    if T2 then return T2 == "inherit" and Look:Chosen(key) or T2 end
    return Look:Chosen(key)
end

-- A made-up sample of a part in a look (the part's tile and its stage): units, group and cast from the parts' own
-- faces, the action and bag buttons in the look, the meter, class bar and timer theme samples. Returns the frame and
-- its size, or nil (Blizzard: the game's own frames; the minimap and combat text have none).
local SAMPLE_ICONS = { 132340, 132355, 132363, 132326, 135358, 136105 }
local function BuildSample(host, part, key, prefix)
    local Look = ns.Look
    local look = Look and Look.BY_KEY and Look.BY_KEY[key]
    local f = CreateFrame("Frame", nil, host)
    local w, h
    if part == "units" or part == "group" then
        local U = ns.LookUnits
        if not (U and look) or key == "blizzard" then return nil end
        local function face(kind, side, x, y, fake, fw)
            local hf = CreateFrame("Frame", nil, f)
            hf:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
            hf:SetSize(fw or 214, 48)
            local fc = U:NewFace(hf, kind, kind == "cell" and "group" or "units", side)
            fc.width = fw
            if fake.auras then fc.showAuras, fc.showCombo = true, true end
            fc:Apply(look)
            fc:Set(fake)
        end
        if part == "units" then
            face("big", "left", 0, 0, U.Fake("player"))
            face("big", "right", 0, -66, U.Fake("target"))
            w, h = 214, 142
        else
            for j = 1, 6 do
                face("cell", "left", ((j - 1) % 3) * 78, -floor((j - 1) / 3) * 42, U.Fake("member", j + 2), 72)
            end
            w, h = 228, 78
        end
    elseif part == "cast" then
        local C = ns.LookCast
        if not (C and look) or key == "blizzard" then return nil end
        for i, k in ipairs({ "player", "target" }) do
            local b = C:Sample(f, k, look)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(i - 1) * 40)
            w = max(w or 0, tonumber(b:GetWidth()) or 0)
        end
        w, h = (w and w > 20) and w or 220, 70
    elseif part == "bars" then
        local B = ns.LookBars
        if not (B and look) or key == "blizzard" then return nil end
        local list = {}
        for j, ic in ipairs(SAMPLE_ICONS) do
            local b = CreateFrame("Button", nil, f)
            b:SetSize(32, 32)
            b:SetPoint("TOPLEFT", f, "TOPLEFT", (j - 1) * 38, 0)
            b.icon = b:CreateTexture(nil, "BACKGROUND")
            b.icon:SetAllPoints()
            b.icon:SetTexture(ic)
            b.HotKey = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            b.HotKey:SetText(tostring(j))
            b.NormalTexture = b:CreateTexture()
            B:Apply(b, look)
            list[j] = b
        end
        -- (the bars switched back to the game's look unstyle every button LookBars styled, these too: again on show)
        f.restyle = function() for _, b in ipairs(list) do B:Apply(b, look) end end
        w, h = #SAMPLE_ICONS * 38 - 6, 34
    elseif part == "bags" then
        local B = ns.LookBars
        if not (B and look) or key == "blizzard" then return nil end
        local kr = CreateFrame("Button", nil, f)
        kr:SetSize(18, 36)
        kr.dzName = "KeyRingButton"
        kr:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        B:Tile(kr, look)
        local list = { kr }
        for j, ic in ipairs({ 133628, 133633, 133640, 133639 }) do
            local b = CreateFrame("Button", nil, f)
            b:SetSize(30, 30)
            b.dzName = "CharacterBag" .. (j - 1) .. "Slot"
            b.Icon = b:CreateTexture()
            b.Icon:SetTexture(ic)
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 24 + (j - 1) * 34, -3)
            B:Tile(b, look)
            list[#list + 1] = b
        end
        f.restyle = function() for _, b in ipairs(list) do B:Tile(b, look) end end
        w, h = 24 + 4 * 34 - 4, 36
    elseif part == "meters" then
        local MT, T = ns.MeterTheme, ns.Themes
        local t = T and T:Get("meters", key)
        if not (MT and MT._FillPreview and t) then return nil end
        local holder = CreateFrame("Frame", nil, f)
        holder:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        MT._FillPreview(holder, t)
        holder:SetScale(1)
        w, h = tonumber(holder:GetWidth()) or 150, tonumber(holder:GetHeight()) or 60
    elseif part == "classbars" then
        local BF, T = ns.BarFace, ns.Themes
        local t = T and T:Get("classbar", key)
        if not (BF and BF._FillPreview and t) then return nil end
        local holder = CreateFrame("Frame", nil, f)
        holder:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        BF._FillPreview(holder, t)
        holder:SetScale(1)
        w, h = tonumber(holder:GetWidth()) or 120, tonumber(holder:GetHeight()) or 40
    elseif part == "timers" then
        local RF = ns.RingFace
        if not (RF and RF.Sample) then return nil end
        local root, rw, rh, qw = RF:Sample(f, key, prefix or "swing")
        if not root then return nil end
        root:ClearAllPoints()
        root:SetPoint("TOPLEFT", f, "TOPLEFT", qw or 0, 0)
        w, h = rw + (qw or 0), rh
    else
        return nil
    end
    f:SetSize(w, h)
    return f, w, h
end

-- Shows a part's sample in look `key` inside `area` (made once per area and look, kept): scaled to fit (fit = true:
-- whole, at most `most`) or to fill and cut at the area's edges (the part tiles). Returns whether there is one.
local function ShowSample(area, part, key, aw, ah, fit, most, prefix)
    area.samples = area.samples or {}
    for k, s in pairs(area.samples) do if s and k ~= key then s.f:Hide() end end
    if not key then return false end
    local s = area.samples[key]
    if s == nil then
        local ok, f, w, h = pcall(BuildSample, area, part, key, prefix)
        s = (ok and f) and { f = f, w = w, h = h } or false
        if not ok and ns.Debug then ns:Debug("Settings sample %s/%s: %s", part, tostring(key), tostring(f)) end
        area.samples[key] = s
    end
    if not s then return false end
    if s.f.restyle then pcall(s.f.restyle) end
    local sc
    if fit then
        sc = min(most or 1.6, (aw - 24) / s.w, (ah - 24) / s.h)
    else
        sc = min(0.75, max(aw / s.w, ah / s.h))
    end
    sc = max(0.2, sc)
    local f = s.f
    f:SetScale(sc)
    local x = (s.w * sc <= aw) and floor((aw - s.w * sc) / 2) or 4
    local y = (s.h * sc <= ah) and floor((ah - s.h * sc) / 2) or 3
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", area, "TOPLEFT", x / sc, -y / sc)
    f:Show()
    return true
end

-- A part's tile: the sample on a dark band (cut at its edges), the name, the look it wears; a click opens its page.
local function NewPartTile(sec, p)
    local t = CreateFrame("Button", nil, sec)
    t.part = p.key
    t:SetHeight(PART_TILE_H)
    t.bg = UI:Fill(t, "CARD", "BACKGROUND", 0)
    UI:AddEdges(t, "BORDER")
    UI:SetEdgeColor(t, S:Color("EDGE"))
    t.pv = CreateFrame("Frame", nil, t)
    t.pv:SetPoint("TOPLEFT", 1, -1)
    t.pv:SetPoint("TOPRIGHT", -1, -1)
    t.pv:SetHeight(PV_H)
    if t.pv.SetClipsChildren then t.pv:SetClipsChildren(true) end
    t.pvbg = UI:Fill(t.pv, "INSET", "BACKGROUND", 0)
    t.glyph = t.pv:CreateTexture(nil, "ARTWORK")
    t.glyph:SetSize(20, 20)
    t.glyph:SetPoint("CENTER")
    local co = UI:IconCoords(p.glyph or 31)
    t.glyph:SetTexture(UI.ICON_ATLAS)
    t.glyph:SetTexCoord(co[1], co[2], co[3], co[4])
    t.glyph:SetVertexColor(S:Color("DIM"))
    t.name = UI:Text(t, "emph", "TEXT")
    t.name:SetPoint("TOPLEFT", t, "TOPLEFT", 8, -(PV_H + 6))
    t.look = UI:Text(t, "small", "SUB")
    t.look:SetPoint("TOPLEFT", t.name, "BOTTOMLEFT", 0, -2)
    local name, tip = PartInfo(p.key)
    t.name:SetText(name)
    UI:DecorateRow(t)
    UI:AttachTooltip(t, name, { tip, "Click: its look and options" })
    t:SetScript("OnClick", function() SettingsUI:OpenPart(p.key) end)
    return t
end

function SettingsUI:BuildLooks(sec)
    sec.y = sec.y - 4
    local Look = ns.Look
    Look:Tiles(self, sec)
    -- one click puts Classic on every part and on the addon's own themed parts (meters, class bars, timers)
    local row = self:Row(sec, "Classic everywhere", "Every part and the addon's own themes in the game's art.")
    local all = ns.UI:CreateSleekButton(row, "Use Classic everywhere", 160, 22, function()
        Look:UseEverywhere("classic")
        SettingsUI:Refresh()
    end)
    all:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.control = all
    PlaceText(row, 160)
    row.line:Hide()
    local h = UI:CreateSectionHeader(sec, "Every part", { style = "caps", right = "Open one for its look and options" })
    h:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - 10)
    h:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y - 10)
    sec.y = sec.y - 34
    sec.gridTop = sec.y
    sec.partTiles = {}
    for _, p in ipairs(PARTS) do sec.partTiles[#sec.partTiles + 1] = NewPartTile(sec, p) end
    self.looksSec = sec
    self:LayoutPartTiles()
end

-- Places the part tiles (the ones there for me) PART_COLS to a row and sizes the Looks card; repaints their samples.
function SettingsUI:LayoutPartTiles()
    local sec = self.looksSec
    if not sec then return end
    local w = self:BodyWidth()
    local tw = floor((w - (PART_COLS - 1) * PART_GAP) / PART_COLS)
    local i = 0
    for _, t in ipairs(sec.partTiles) do
        if self:PartShown(t.part) then
            local col, rowN = i % PART_COLS, floor(i / PART_COLS)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", sec, "TOPLEFT", col * (tw + PART_GAP), sec.gridTop - rowN * (PART_TILE_H + PART_GAP))
            t:SetWidth(tw)
            local key, prefix = PartLook(t.part)
            local has = ShowSample(t.pv, t.part, key, tw - 2, PV_H, false, nil, prefix)
            t.glyph:SetShown(not has)
            t.look:SetText(self:PartLookName(t.part) .. ((PART[t.part] and not PART[t.part].kind and not PART[t.part].kits
                and t.part ~= "sct" and Get("ui." .. t.part .. ".look", "inherit") ~= "inherit") and "  ·  own" or ""))
            t:Show()
            i = i + 1
        else
            t:Hide()
        end
    end
    local rows = max(1, math.ceil(i / PART_COLS))
    sec.height = -sec.gridTop + rows * (PART_TILE_H + PART_GAP) - PART_GAP + 6
end

-- The look tiles of a game part's page: "Same as everything" first, then every look (Look's own tile sample).
local function PaintLookTile(tile, t)
    local Look = ns.Look
    if not tile.word then
        tile.word = UI:Text(tile, "small", "SUB", { justify = "CENTER" })
        tile.word:SetPoint("TOP", tile, "TOP", 0, -12)
        tile.word:SetWidth((tile:GetWidth() or 60) - 6)
        tile.word:SetWordWrap(true)
    end
    if t.key == "inherit" then
        local all = Look and Look.BY_KEY[Get("ui.look", "blizzard")]
        tile.word:SetText("Follows\n" .. (all and all.name or "Blizzard"))
        tile.word:Show()
        if tile.preview.host then tile.preview.host:Hide() end
        return
    end
    tile.word:Hide()
    if Look and Look.PaintTile then Look.PaintTile(tile, t) end
end

-- A part's page (made with the panel so the search finds its options; its samples are made when it opens): its head
-- in the head over the scroll frame (the way back to Looks, its name, Back to defaults, its switch), the stage, the
-- look tiles and options under it.
function SettingsUI:NewPartPage(p)
    local page = CreateFrame("Frame", nil, self.child)
    page:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, 0)
    page:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, 0)
    page:SetHeight(1)
    page:Hide()
    page.part = p.key
    local name = PartInfo(p.key)
    page.head = self:NewPageHead(name, function() SettingsUI:ResetCard("part:" .. p.key) end, p.master, "look." .. p.key)
    page.reset = page.head.reset
    -- the stage: the sample of the part in the look it wears (or the look a tile points at)
    local stage = CreateFrame("Frame", nil, page)
    stage:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    stage:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
    stage:SetHeight(STAGE_H)
    if stage.SetClipsChildren then stage:SetClipsChildren(true) end
    stage.bg = UI:Fill(stage, "INSET", "BACKGROUND", 0)
    UI:AddEdges(stage, "BORDER")
    UI:SetEdgeColor(stage, S:Color("EDGE"))
    stage.tag = UI:Text(stage, "small", "SUB", { justify = "RIGHT" })
    stage.tag:SetPoint("TOPRIGHT", stage, "TOPRIGHT", -8, -7)
    stage.note = UI:Text(stage, "body", "SUB", { justify = "CENTER" })
    stage.note:SetPoint("CENTER", stage, "CENTER", 0, 0)
    stage.note:SetWidth(360)
    stage.note:SetWordWrap(true)
    page.stage = stage
    -- the look tiles and the options
    local sec = CreateFrame("Frame", nil, page)
    sec:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -(STAGE_H + 6))
    sec:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, -(STAGE_H + 6))
    sec:SetHeight(1)
    sec.key = "look." .. p.key
    sec.rows = {}
    sec.y = 0
    sec.page = page
    sec.fitW = CARDS_W
    page.sec = sec
    self.sections[sec.key] = sec
    self.parts[p.key] = page
    self.ctx = { cat = "interface", card = "looks", part = p.key, path = { "Interface", "Looks", name } }
    if p.master then self:IndexMaster(p.master) end
    self:BuildPart(sec, p)
    self.ctx = nil
    sec:SetHeight(max(1, sec.height or 0))
    page.height = STAGE_H + 6 + (sec.height or 0) + 8
    page:SetHeight(page.height)
    return page
end

-- How many of a game part's options are its essentials: the rest go under More options (a part with more than
-- PART_ESSENTIALS + 2 of them: the action bars, combat text).
local PART_ESSENTIALS = 4

-- A part's look tiles and options.
function SettingsUI:BuildPart(sec, p)
    local key, Look, T = p.key, ns.Look, ns.Themes
    sec.y = sec.y - 2
    local function repaint() SettingsUI:PaintStage(key) end
    local function TryRow(desc, run)
        local row = self:Row(sec, "Try it", desc)
        local try = ns.UI:CreateSleekButton(row, "Try it", 80, 22, run)
        try:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.control = try
        PlaceText(row, 80)
    end
    if key == "meters" then
        if ns.MeterTheme then ns.MeterTheme:SettingsTiles(self, sec) end
        for _, o in ipairs(PART_OPTS.meters) do self:DropdownSetting(sec, o[2], o[3], o[1], o[4], o[5]) end
    elseif key == "classbars" then
        if ns.BarFace then ns.BarFace:SettingsRow(self, sec) end
    elseif key == "timers" then
        local CK = ns.ClassKit
        for _, prefix in ipairs({ "swing", "shot" }) do
            local kit = CK and CK:Get(prefix)
            if kit and ns.RingFace and (CK:IsDemo() or kit.class == CK:MyClass()) then
                ns.RingFace:SettingsRow(self, sec, prefix, kit.label)
            end
        end
    else
        -- (combat text's own switch, off until turned on, is its page's master switch: PART.sct.master)
        local kind = "uilook." .. key
        if T then
            local list = { { key = "inherit", name = "Everything's", tip = "The look for everything (Interface > Looks)." } }
            for _, l in ipairs(Look and Look.LOOKS or {}) do list[#list + 1] = l end
            T:Define(kind, list, "inherit", { setting = "ui." .. key .. ".look", onPreview = repaint })
            T:SettingsRow(self, sec, kind, "Look", "Pick one for this part, or let it follow the look for everything.",
                { tileW = 63, tileH = 62, gap = 5, clip = true, band = true, nameY = 5, previewAt = { 3, -10 },
                  paint = PaintLookTile, fitWidth = CARDS_W, onPick = function() SettingsUI:Refresh() end })
        end
        local opts = PART_OPTS[key] or {}
        local fold = #opts > PART_ESSENTIALS + 2
        for i, o in ipairs(opts) do
            if fold and i == PART_ESSENTIALS + 1 then
                -- (the part's Try it stays out of the fold)
                if key == "sct" and ns.CombatTextUI then
                    TryRow("A made-up pull plays on your screen. Nothing is cast or sent.", function() ns.CombatTextUI:TryIt() end)
                end
                self:MoreOptions(sec)
            end
            local path = "ui." .. key .. "." .. o[1]
            local _, row
            if type(o[4]) == "boolean" then _, row = self:SwitchSetting(sec, o[2], o[3], path, o[4], o.tip)
            else _, row = self:DropdownSetting(sec, o[2], o[3], path, o[4], o[5], o.tip) end
            -- (Classic's own options: a choice only while the part wears Classic)
            if o.classic then
                self.refreshers[#self.refreshers + 1] = { Refresh = function()
                    SetReadOnly(row, not Look:For(key).game, "With Classic")
                end }
            end
        end
        if key == "bossmods" and ns.BossModUI then
            TryRow("A made-up Gruul pull plays on your screen. Nothing is read or sent.", function() ns.BossModUI:TryIt() end)
        end
        if key == "sct" and ns.CombatTextUI and not fold then
            TryRow("A made-up pull plays on your screen. Nothing is cast or sent.", function() ns.CombatTextUI:TryIt() end)
        end
    end
    self:EndSection(sec)
end

-- Readies a part's page before it shows (its stage).
function SettingsUI:PreparePart(key)
    local page = self.parts and self.parts[key]
    if not page then return end
    self:PaintStage(key)
end

-- The part's sample on its page's stage, in the look it wears (or the one a look tile is pointed at).
function SettingsUI:PaintStage(key)
    local page = self.parts and self.parts[key]
    if not page then return end
    local stage = page.stage
    local look, prefix = PartLook(key)
    local w = tonumber(stage:GetWidth()) or 0
    if w < 100 then w = CARDS_W end
    local name = self:PartLookName(key)
    local L = ns.Look
    if PART[key] and not PART[key].kind and not PART[key].kits and L and L.BY_KEY[look] then name = L.BY_KEY[look].name end
    stage.tag:SetText("Sample  ·  " .. (name or ""))
    local has = false
    if key == "sct" and not Get("ui.sct.on", false) then
        stage.note:SetText("Combat text is off.\nTurn it on below: nothing else turns it on.")
    elseif key == "bossmods" and (not Get("bossmods.on", false) or look == "blizzard") then
        stage.note:SetText(not Get("bossmods.on", false) and "Boss mods are off.\nTurn them on in Combat > Boss mods."
            or "With Blizzard as their look, boss mods wear Classic.\nTry it below.")
    elseif look == "blizzard" and not (PART[key].kind or PART[key].kits) then
        stage.note:SetText("The game's own " .. (PartInfo(key)):lower() .. ", as Blizzard made them.")
    else
        has = ShowSample(stage, key, look, w, STAGE_H, true, 1.4, prefix)
        if not has then
            stage.note:SetText((PartInfo(key)) .. " in " .. (name or "") .. ": see it on your screen.")
        end
    end
    if has then
        stage.note:Hide()
    else
        ShowSample(stage, key, nil)
        stage.note:Show()
    end
end

-- Layout: Edit layout, this character's profile, a new one and a share link.
function SettingsUI:BuildLayout(sec)
    sec.y = sec.y - 4
    local L = ns.Layout
    local open = self:EditLayoutRow(sec, "Edit layout", "Move, line up and mirror every frame on your screen.")
    open:SetKind("primary")
    self:Dropdown(sec, "Profile", "Where everything goes. Each character picks its own.",
        function()
            local out = {}
            for _, p in ipairs(L:Profiles()) do out[#out + 1] = { value = p.id, text = p.name } end
            return out
        end,
        function() return L:ActiveId() end,
        function(a, b) L:Use(Value(a, b)) end)
    local row = self:Row(sec, "Profiles", "New copies where things are now. Share links it in chat.")
    local share = ns.UI:CreateSleekButton(row, "Share", 60, 22, function(b)
        if ns.EditMode then ns.EditMode:Share(b) end
    end)
    share:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    local new = ns.UI:CreateSleekButton(row, "New", 56, 22, function()
        if ns.EditMode then ns.EditMode:PromptNew(function() SettingsUI:Refresh() end) end
    end)
    new:SetPoint("RIGHT", share, "LEFT", -6, 0)
    row.control = share
    PlaceText(row, 122)
    self:EndSection(sec)
end

function SettingsUI:BuildWindow(sec)
    sec.y = sec.y - 4
    self:DropdownSetting(sec, "Open on", "What the window shows when you open it.", "openOn", "home", {
        { value = "home", text = "Home (dashboard)" },
        { value = "last", text = "The tab used last" },
    })
    local _, row = self:Switch(sec, "Minimap button", "Click opens this window, right-click Settings, Shift-click the boss drops.",
        function() return not Get("minimap.hide", false) end,
        function(a, b)
            local shown = Bool(a, b)
            Set("minimap.hide", not shown)
            SetMinimapShown(shown)
        end)
    self:SetDefault(row, true)
    self:EndSection(sec)
end

-- The phase I look at (my council views, tooltips and drop alerts): beside the tooltips it decides.
function SettingsUI:BuildPhase(sec)
    sec.y = sec.y - 4
    local _, row = self:Dropdown(sec, "View phase", "The phase your council views, tooltips and drop alerts use.",
        ViewPhaseOptions,
        function() return tonumber(Get("viewPhase", nil)) or 0 end,
        function(a, b)
            local v = tonumber(Value(a, b))
            Set("viewPhase", (v and v >= 1 and v <= MaxPhase()) and v or nil)
        end)
    self:SetDefault(row, 0)
    self:EndSection(sec)
end

-- My Log (Core/MyLog.lua): the opt-in switch, heroics, how long pulls are kept, and Delete (click twice).
-- (the pulls saved on this PC, every character's, and on how many characters)
local function StoredPulls()
    local n, chars = 0, 0
    local db = DisasterZoneLogDB
    if type(db) == "table" and type(db.chars) == "table" then
        for _, c in pairs(db.chars) do
            chars = chars + 1
            n = n + #(c.pulls or {})
        end
    end
    return n, chars
end

-- (a button that deletes every stored pull on its second click within 4 s)
local function ArmDelete(btn, label)
    local armed
    local function disarm()
        armed = nil
        btn:SetText(label)
    end
    btn:SetScript("OnClick", function()
        if armed then
            disarm()
            if ns.MyLog then ns.MyLog:DeleteAll() end
            SettingsUI:RequestRefresh()
            return
        end
        local token = {}
        armed = token
        btn:SetText("Click again to delete")
        C_Timer.After(4, function() if armed == token then disarm() end end)
    end)
    return function() return armed ~= nil end
end

function SettingsUI:BuildMyLog(sec)
    sec.y = sec.y - 4
    -- (off, the box still offers to delete what was stored)
    CARDS.mylog.offExtra = { { label = "Delete all my logs", width = 150, onClick = function() end,
        shown = function() return (StoredPulls()) > 0 end,
        make = function(btn) ArmDelete(btn, "Delete all my logs") end } }
    self:SwitchSetting(sec, "Heroic dungeons too", "Also record heroic 5-man bosses.", "mylog.heroics", false)
    local weeks = {}
    for _, n in ipairs({ 4, 8, 12, 26, 52 }) do weeks[#weeks + 1] = { value = n, text = n .. " weeks" } end
    self:DropdownSetting(sec, "Keep pulls for", "Older pulls are deleted. The newest kills keep every detail.",
        "mylog.keepWeeks", 12, weeks)
    local row = self:Row(sec, "Stored pulls", "")
    local del = ns.UI:CreateSleekButton(row, "Delete all my logs", 150, 22, function() end)
    local armed = ArmDelete(del, "Delete all my logs")
    del:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.control = del
    row.hasDesc = true
    PlaceText(row, 150)
    self.refreshers[#self.refreshers + 1] = {
        Refresh = function()
            local n, chars = StoredPulls()
            row.desc:SetText(n == 0 and "None yet."
                or string.format("%d pull%s on %d character%s.", n, n == 1 and "" or "s", chars, chars == 1 and "" or "s"))
            del:SetEnabled(n > 0 or armed())
        end,
    }
    self:EndSection(sec)
end

-- Meters (Core/Meter.lua, Core/Threat.lua): a switch per window, the threat warning and when the panels show; under
-- More options the rest in three groups (the damage meter's, the threat meter's, the panels'). An option of a meter
-- is hidden while that meter is off (the panels' while both are), and so is its group's header.
function SettingsUI:BuildMeters(sec)
    sec.y = sec.y - 4
    local dmgOn, thrOn = IsOn("meters.dmg", false), IsOn("meters.thr", false)
    local function anyOn() return dmgOn() or thrOn() end
    -- a group inside the fold: a section header with the meter's icon, shown while its meter is on
    local function Head(text, icon, need)
        local h = UI:CreateSectionHeader(sec, (icon and ("|T" .. icon .. ":16:16:0:0:64:64:5:59:5:59|t  ") or "") .. text)
        self:Place(sec, h, 28, { gap = 10, need = need })
    end
    local function Button(title, desc, label, onClick)
        local row = self:Row(sec, title, desc)
        local btn = ns.UI:CreateSleekButton(row, label, 120, 22, onClick)
        btn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.control = btn
        PlaceText(row, 120)
        return btn, row
    end

    local _, dmg = self:SwitchSetting(sec, "Show the damage meter",
        "Damage, healing, taken, deaths, interrupts, dispels and active time for your group.", "meters.dmg", false,
        "Hover a bar for a player's top abilities, click it for the full breakdown. /dz meter shows or hides it.")
    local _, thr = self:SwitchSetting(sec, "Show the threat meter",
        "Your target's threat table, from the game itself, with your pull point.",
        "meters.thr", false, "The same numbers ThreatClassic2 reads. /dz threat shows or hides it.")
    self:Needs(select(2, self:DropdownSetting(sec, "Warn me at",
        "Share of your pull point. Melee pulls at 110% of the tank, ranged at 130%.", "meters.warn", 85,
        { { value = 0, text = "Never" }, { value = 75, text = "75%" }, { value = 85, text = "85%" },
          { value = 90, text = "90%" }, { value = 95, text = "95%" } })), thrOn, thr)
    self:Needs(select(2, self:DropdownSetting(sec, "Show them", "When the panels appear on their own.", "meters.show",
        "group", { { value = "group", text = "In a group" }, { value = "instance", text = "In instances" },
                   { value = "always", text = "Always" } })), anyOn, dmg)

    self:MoreOptions(sec)
    Head("Damage meter", "Interface\\Icons\\Ability_Warrior_SavageBlow", dmgOn)
    self:Needs(select(2, self:DropdownSetting(sec, "Fights to keep", "Older fights drop off the list. Whole raid always stays.",
        "meters.keep", 25, { { value = 10, text = "Last 10" }, { value = 25, text = "Last 25" }, { value = 50, text = "Last 50" } })),
        dmgOn, dmg)
    self:Needs(select(2, self:DropdownSetting(sec, "Start a new fight on", "Boss pulls always start their own fight.",
        "meters.split", "all", { { value = "all", text = "Every combat" }, { value = "boss", text = "Boss pulls only" } })),
        dmgOn, dmg)
    self:Needs(select(2, self:DropdownSetting(sec, "Per second by",
        "Fight time ranks like the totals; active time leaves out idle gaps.",
        "meters.rate", "fight", { { value = "fight", text = "Fight time" }, { value = "active", text = "Active time" } },
        "Fight time: damage over the fight's length, as Warcraft Logs counts it. Active time: over the time each player "
            .. "was doing something, as Details counts it by default; it favours players who stood idle.")), dmgOn, dmg)
    local armed, clr
    local function disarm() armed = nil; clr:SetText("Clear") end
    local _, crow = Button("Clear all fights", "Empties the fight list and Whole raid.", "Clear", function()
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
    clr = crow.control
    self:Needs(crow, dmgOn, dmg)

    Head("Threat meter", "Interface\\Icons\\Ability_Warrior_DefensiveStance", thrOn)
    self:Needs(select(2, self:SwitchSetting(sec, "Warning sound", "Plays once each time you cross the line.", "meters.sound",
        true)), thrOn, thr)
    self:Needs(select(2, self:SwitchSetting(sec, "Flash the screen edges", "A soft red pulse while you stay over the line.",
        "meters.flash", true)), thrOn, thr)
    self:Needs(select(2, self:DropdownSetting(sec, "Tank view", "Shows how close each player is to their own pull point.",
        "meters.tankView", "auto", { { value = "auto", text = "While I tank" }, { value = "always", text = "Always" },
                                     { value = "never", text = "Never" } })), thrOn, thr)

    Head("Panels", nil)
    -- (their look: Interface > Looks > Meters, where every look is picked; open to a look with both meters off too)
    self:LookLinkRow(sec, "Look", "Theme, bar colour, icons, rows, numbers, background and size.", "meters")
    self:Needs(select(2, self:DropdownSetting(sec, "Out of combat", "What the panels do a few seconds after a fight.",
        "meters.ooc", "fade", { { value = "fade", text = "Fade" }, { value = "hide", text = "Hide" },
                                { value = "stay", text = "Stay" } })), anyOn, dmg)
    self:Needs(select(2, self:EditLayoutRow(sec, "Move and dock", "Edit layout unlocks them: drag a header to move, dock "
        .. "or make a tab.")), anyOn, dmg)
    local _, lrow = Button("Reset layout", "Back to one stack: Threat over Damage done.", "Reset", function()
        if ns.MeterPanels then ns.MeterPanels:ResetLayout() end
    end)
    self:Needs(lrow, anyOn, dmg)
    self:EndSection(sec)
end

-- Tutorials (1.3.5): the Welcome tour's parts for my roles (done / where I stopped / not started, with Start, Go on
-- or Again), a look at the other roles' parts on demo data, the strategy board's tutorial, new-role offers on or off,
-- and for the Guild Master the set-up checklist (each open item opens its page). Rows are made once and laid out
-- again on every refresh (my roles can change).
local TUT_BTN_W = 86

function SettingsUI:BuildTutorials(sec)
    local W = ns.WelcomeTour
    sec.y = sec.y - 4
    sec.top = sec.y
    -- (Guild > Guild set-up is built first and keeps its rows in the same table)
    local t = self.tut or { setup = {} }
    t.parts = {}
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
    self:EndSection(sec)
end

-- Guild > Guild set-up (the Guild Master only): the checklist (each open item opens its page) and its chip on Home.
-- The rows live in self.tut (setupHead, setup[i]) as before, for the Welcome tour's last GM step.
function SettingsUI:BuildSetup(sec)
    local t = self.tut or { parts = {}, setup = {} }
    self.tut = t
    sec.y = sec.y - 4
    sec.top = sec.y
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
        local row = self:Row(sec, "", " ")
        local b = ns.UI:CreateSleekButton(row, "Open", TUT_BTN_W, 22, function(btn)
            local it = btn:GetParent().item
            if it and it.open then it.open() end
        end)
        b:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.btn = b
        PlaceText(row, TUT_BTN_W)
        t.setup[i] = row
    end
    self.setupSec = sec
    self:EndSection(sec)
end

-- Opens Guild > Guild set-up so the GM's checklist is in view (the Welcome tour's last GM step); returns the rows.
function SettingsUI:ShowSetupChecklist()
    self:SelectSection("setup")
    self:Refresh()
    local t = self.tut
    if not (t and t.setupHead and t.setupHead:IsVisible()) then return nil end
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
        y = y - FitDesc(row)
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
    sec.height = -y + 2
    -- Guild > Guild set-up (its own card, the GM's)
    sec = self.setupSec
    if not (sec and t.setupHead) then return end
    y = sec.top
    local gm = mine.gm == true
    local list = gm and W:Checklist() or {}
    local n = 0
    for _, it in ipairs(list) do if it.done then n = n + 1 end end
    t.setupHead.desc:SetText(Grey(format("%d of %d done · shown on Home until then", n, #list)))
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
    cs.editBtn = ns.UI:CreateSleekButton(cs, "Edit council", 116, 20, function() SettingsUI:OpenCouncilEditor() end)
    self:CardAction(sec, cs.editBtn)        -- (in the card's head)
    AddTooltip(cs.editBtn, "Edit council",
        "Opens the Loot Council picker (Council tab). The Guild Master picks the guild council; "
        .. "the raid leader picks extra council members for their raid.")
    cs.info = UI:Text(cs, "small", nil, { width = BODY_W, wrap = true })
    sec.height = 120
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

-- Discord: the host (the character whose launcher runs the bot; Discord sign-ups for others count only from it), the
-- channel for raids without a team, and one channel per team. The channel names come from the host's launcher
-- (DZBridgeInbox.channels); on another PC the dropdowns show the ids only.
local function ChannelOptions(current)
    local out = { { value = "", text = "Not posted" } }
    local seen = {}
    for _, c in ipairs(ns.Bridge and ns.Bridge:GetChannels() or {}) do
        out[#out + 1] = { value = c.id, text = c.name }
        seen[c.id] = true
    end
    if current and not seen[current] then out[#out + 1] = { value = current, text = "Channel " .. current } end
    return out
end

local function SetDiscord(patch)
    local ok, err = ns.Guild:SetDiscord(patch)
    if not ok then ns:Print("%s", tostring(err)) end
    SettingsUI:RefreshDiscord()
end

function SettingsUI:BuildDiscord(sec)
    self.dsc = sec
    sec.notice = self:Notice(sec, "info")
    sec.status = sec.notice.text
    local hostRow = self:Row(sec, "Bot host", "The character whose launcher runs the bot. Discord sign-ups count only from it.")
    local btn = ns.UI:CreateSleekButton(hostRow, "This character", 120, 22, function()
        SetDiscord({ host = ns.Util.PlayerKey() })
    end)
    btn:SetPoint("RIGHT", hostRow, "RIGHT", 0, 0)
    hostRow.control = btn
    AddValueText(hostRow)
    PlaceText(hostRow, 120)
    sec.hostRow = hostRow
    self:Dropdown(sec, "Raids without a team", "Where raids that belong to no team are posted.",
        function() return ChannelOptions(ns.Guild:GetDiscord().guild) end,
        function() return ns.Guild:GetDiscord().guild or "" end,
        function(a, b) local v = Value(a, b); SetDiscord({ guild = v ~= "" and v or false }) end)
    self:Dropdown(sec, "This week board", "One post the bot keeps up to date: every raid this week and how full it is.",
        function() return ChannelOptions(ns.Guild:GetDiscord().week) end,
        function() return ns.Guild:GetDiscord().week or "" end,
        function(a, b) local v = Value(a, b); SetDiscord({ week = v ~= "" and v or false }) end)
    self:Dropdown(sec, "Loot feed", "After each boss: what dropped and who got it, one post per raid night.",
        function() return ChannelOptions(ns.Guild:GetDiscord().loot) end,
        function() return ns.Guild:GetDiscord().loot or "" end,
        function(a, b) local v = Value(a, b); SetDiscord({ loot = v ~= "" and v or false }) end)
    local _, teamRow = self:Dropdown(sec, "Team", "Pick a team, then its channel below.",
        function()
            local out = {}
            for _, t in ipairs(ns.RaidPlan and ns.RaidPlan:GetTeams() or {}) do out[#out + 1] = { value = t.id, text = t.name } end
            if #out == 0 then out[1] = { value = "", text = "No teams yet" } end
            return out
        end,
        function()
            if not SettingsUI.dscTeam then
                local t = ns.RaidPlan and ns.RaidPlan:GetTeams() or {}
                SettingsUI.dscTeam = t[1] and t[1].id or ""
            end
            return SettingsUI.dscTeam
        end,
        function(a, b) SettingsUI.dscTeam = Value(a, b); SettingsUI:RequestRefresh() end)
    sec.teamRow = teamRow
    self:Dropdown(sec, "Its channel", "Where that team's raids are posted.",
        function() return ChannelOptions(ns.Guild:GetDiscord().teams[SettingsUI.dscTeam or ""]) end,
        function() return ns.Guild:GetDiscord().teams[SettingsUI.dscTeam or ""] or "" end,
        function(a, b)
            local id = SettingsUI.dscTeam
            if not id or id == "" then return end
            local v = Value(a, b)
            SetDiscord({ teams = { [id] = v ~= "" and v or false } })
        end)
    self:EndSection(sec)
end

function SettingsUI:RefreshDiscord()
    local sec = self.dsc
    if not sec then return end
    local d = ns.Guild:GetDiscord()
    local gm = ns.Guild:CanEditDiscord()
    local hasList = ns.Bridge and #ns.Bridge:GetChannels() > 0
    local text
    if not gm then
        text = Grey("Set by the Guild Master.")
    elseif not hasList then
        text = "Pick channels on the host's PC:" .. Grey(" its launcher lists the server's channels.")
    else
        text = "Every member's addon gets these." .. Grey(" Raids are posted by the host's launcher.")
    end
    sec.status:SetText(text)
    sec.notice:SetNotice(gm and "info" or "readonly", text)
    sec.hostRow.title:SetText("Bot host: " .. (d.host or Grey("not set")))
    SetReadOnly(sec.hostRow, not gm, "")
    for _, row in ipairs(sec.rows) do
        if row ~= sec.hostRow and row ~= sec.teamRow and row.getValue then
            local v, shown = row.getValue(), Grey("not posted")
            for _, o in ipairs(ChannelOptions(v ~= "" and v or nil)) do
                if o.value == v and v ~= "" then shown = o.text end
            end
            SetReadOnly(row, not gm, shown)
        end
    end
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
        sec.status:SetText("You set these as Guild Master." .. Grey(" Every member gets them."))
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
-- The tiles' lines: how each card is set right now, in a few words
---------------------------------------------------------------------------
local function OnOff(v) return v and "on" or "off" end

CARDS.window.summary = function()
    return format("Opens on %s · minimap button %s", Get("openOn", "home") == "last" and "the last tab" or "Home",
        OnOff(not Get("minimap.hide", false)))
end
CARDS.tooltips.summary = function()
    if not Get("tooltip.enabled", true) then return "Off · nothing added to item tooltips" end
    return format("BiS lines · %s names%s", tostring(Get("tooltip.maxNames", 5)),
        Get("tooltip.council", true) and " · who wants it" or "")
end
CARDS.phase.summary = function()
    local v = tonumber(Get("viewPhase", nil))
    if v and v >= 1 and v <= MaxPhase() then return PhaseLabel(v) end
    local gp = ns.Guild and ns.Guild.GetGuildPhase and ns.Guild:GetGuildPhase()
    return format("Follows the guild · P%d", tonumber(gp) or 1)
end
CARDS.quiet.summary = function()
    local N = ns.Notify
    local s = N and N.Settings and N.Settings()
    if s and (tonumber(s.dndUntil) or 0) > ns.Util.Now() then return "Paused for an hour" end
    local parts = {}
    if not s or s.quietCombat ~= false then parts[#parts + 1] = "Quiet in combat" end
    if s and s.quietOpen then parts[#parts + 1] = (#parts > 0 and "while" or "Quiet while") .. " the window is open" end
    return #parts > 0 and table.concat(parts, " · ") or "Never quiet"
end
CARDS.reach.summary = function() return SUMMARY.alerts() end
CARDS.session.summary = function()
    local v = Get("sessionBar.show", "auto")
    for _, o in ipairs(ns.SessionBar and ns.SessionBar.SHOW_OPTIONS or {}) do if o.value == v then return o.text end end
    return ""
end
CARDS.drops.summary = function()
    local where = not Get("alerts.councilPanel", true) and "No drop panel"
        or (Get("dropPanelMode", "auto") == "floating" and "Floating panel" or "Next to the loot window")
    return where .. (Get("alerts.glow", true) and " · BiS glow" or "")
end
CARDS.rolls.summary = function()
    local where = not Get("roll.announce", true) and "not announced"
        or (Get("announceChannel", "RAID") == "RAID_WARNING" and "raid warning" or "raid chat")
    return format("Roll pop-up %s · %s", OnOff(Get("roll.popup", true)), where)
end
CARDS.rules.summary = function()
    local status, from = SettingsUI:GroupRulesStatus()
    local secs = tonumber(Effective("roll.duration", 30)) or 30
    local q = (tonumber(Effective("qualityThreshold", 4)) or 4) >= 4 and "epics" or "rares"
    if status == "remote" then return format("Set by %s · %d s rolls · %s", from and NameOf(from) or "the leader", secs, q) end
    return format("%s · %d s rolls · %s", status == "mine" and "You set these" or "Your own", secs, q)
end
CARDS.meters.summary = function()
    local dmg, thr = Get("meters.dmg", false), Get("meters.thr", false)
    local show = ({ group = "in a group", instance = "in instances", always = "always" })[Get("meters.show", "group")]
    return format("Damage %s · threat %s", OnOff(dmg), OnOff(thr)) .. ((dmg or thr) and show and (" · " .. show) or "")
end
CARDS.bossmods.summary = function()
    if not Get("bossmods.on", false) then return "Off · pull timers still work" end
    local role = Get("bossmods.role", "auto")
    local names = { tank = "tank", healer = "healer", dps = "damage" }
    local mine = role == "auto" and ns.BossMod and ns.BossMod.MyRole and ns.BossMod:MyRole() or role
    -- (learning on: how many pulls the timers come from, the guild's included)
    local L = ns.BossLearn
    if L and L.Enabled and L:Enabled() and L.Store then
        local n = 0
        for _, l in next, L.Store().pulls do if type(l) == "table" then n = n + #l end end
        if n > 0 then return format("On · learned from %d pull%s", n, n == 1 and "" or "s") end
        return "On · learning from our pulls"
    end
    return format("On · %s%s", role == "auto" and "auto: " or "", names[mine] or "damage")
end
CARDS.classtools.summary = function()
    local CK = ns.ClassKit
    if not CK then return "" end
    if CK:IsDemo() then return "Demo: every class's tools" end
    local on = {}
    for _, kit in ipairs(CK:List(CK:MyClass())) do
        if CK:IsOn(kit.key) then on[#on + 1] = kit.label end
    end
    return #on > 0 and table.concat(on, " · ") or "All switched off"
end
CARDS.strategy.summary = function()
    local parts = {}
    if Get("strategy.autoMark", true) then parts[#parts + 1] = "Auto-marks" end
    if Get("strategy.reminder", true) then parts[#parts + 1] = (#parts > 0 and "shows" or "Shows") .. " my jobs" end
    return #parts > 0 and table.concat(parts, " · ") or "Quiet"
end
CARDS.mylog.summary = function()
    if not Get("mylog.enabled", false) then return "Off · records nothing" end
    local n = StoredPulls()
    return format("Recording · %d pull%s kept", n, n == 1 and "" or "s")
end
CARDS.looks.summary = function() return SUMMARY.interface() end
CARDS.layout.summary = function()
    local L = ns.Layout
    if not (L and L.ActiveId) then return "" end
    local id = L:ActiveId()
    for _, p in ipairs(L:Profiles()) do
        if p.id == id then return format("%s profile · /dz edit", p.name) end
    end
    return "Default profile · /dz edit"
end
CARDS.council.summary = function()
    local CU = ns.CouncilUI
    local sum = CU and CU.GetCouncilSummary and CU:GetCouncilSummary()
    local n = sum and sum.guildMembers and #sum.guildMembers or 0
    return format("Council of %d · %s", n, IsCouncil() and "you are on it" or "you are not on it")
end
CARDS.attendance.summary = function()
    local G = ns.Guild
    local r = (G and G.GetAttendanceRules and G:GetAttendanceRules()) or { o = 5, d = 10 }
    return format("Late after %d min · short drops %d min", tonumber(r.o) or 0, tonumber(r.d) or 0)
end
CARDS.discord.summary = function()
    local d = ns.Guild and ns.Guild.GetDiscord and ns.Guild:GetDiscord() or {}
    if not d.host then return "Not set up" end
    local n = 0
    for _ in pairs(d.teams or {}) do n = n + 1 end
    return format("Host %s · %s · %d team channel%s", ns.Util.ShortName and ns.Util.ShortName(d.host) or d.host,
        d.guild and "guild channel set" or "no guild channel", n, n == 1 and "" or "s")
end
CARDS.setup.summary = function()
    local W = ns.WelcomeTour
    local list = W and W.Checklist and W:Checklist() or {}
    local n = 0
    for _, it in ipairs(list) do if it.done then n = n + 1 end end
    return format("%d of %d done", n, #list)
end
CARDS.tutorials.summary = function()
    local W = ns.WelcomeTour
    if not (W and W.Roles) then return "" end
    local mine, n, done = W:Roles(), 0, 0
    for _, key in ipairs(W.ORDER or {}) do
        if mine[key] then
            n = n + 1
            if (W:PartState(key)) == "done" then done = done + 1 end
        end
    end
    return format("%d of %d tours done", done, n)
end
CARDS.demo.summary = function()
    local on = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    return on and "On · made-up guild and raid" or "Off · try the council views solo"
end
CARDS.about.summary = function()
    local SY = ns.Sync
    local peers = SY and SY.GetVersions and SY:GetVersions()
    local n = type(peers) == "table" and #peers or 0
    return format("Version %s · %d player%s seen", tostring(ns.version or "?"), n, n == 1 and "" or "s")
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
    self:RefreshDiscord()
    self:RefreshTutorials()
    for _, row in ipairs(self.settingRows) do PaintDot(row) end
    self:LayoutPartTiles()
    -- (the sections that hide rows: stacked again for what is on now)
    for _, sec in pairs(self.sections) do
        if sec.dynamic then self:Relayout(sec) end
    end
    -- (a card that is no longer there for me: back to its group's tiles)
    if self.mode == "card" and self.section and not self:CardVisible(self.section) then
        self.mode, self.section = "tiles", nil
    end
    if self.mode == "part" and self.part then self:PreparePart(self.part) end
    if self.query then self:LayoutResults() end
    self:LayoutView()
end

---------------------------------------------------------------------------
-- Search: every indexed option whose name, line or place (its kit, its part) has the words; grouped by where they
-- are (a path you can click), each with a working control (made again from the entry, once) and its name a link
-- that opens its card and lights it. A group, card or part whose name matches is a chip that opens it.
---------------------------------------------------------------------------
local RESULTS_MAX = 40
local GO_H = 26

function SettingsUI:BuildResults()
    local f = CreateFrame("Frame", nil, self.child)
    f:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, 0)
    f:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, 0)
    f:SetHeight(1)
    f:Hide()
    f.key = "search"
    f.fitW = CARDS_W
    f.rows = {}
    f.y = 0
    f.count = UI:Text(f, "small", "SUB")
    f.count:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -4)
    f.crumbs, f.chips = {}, {}
    f.empty = UI:Text(f, "body", "SUB", { justify = "CENTER" })
    f.empty:SetPoint("TOP", f, "TOP", 0, -60)
    f.empty:SetWidth(400)
    f.empty:SetWordWrap(true)
    self.results = f
end

local function Lower(s) return type(s) == "string" and s:lower() or "" end

-- (the words in gold in a name or line; plain text otherwise)
local function Marked(text, q)
    if type(text) ~= "string" or text == "" then return text or "" end
    local i, j = text:lower():find(q, 1, true)
    if not i then return text end
    return text:sub(1, i - 1) .. S:Wrap("GOLD", text:sub(i, j)) .. text:sub(j + 1)
end

function SettingsUI:Search(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local q = #text >= 2 and text:lower() or nil       -- (one letter would match almost everything)
    if q == self.query then return end
    self.query = q
    if q then
        if self.mode ~= "search" then self.prevMode = self.mode end
        self.mode = "search"
        self:LayoutResults()
        if self.scroll then self.scroll:SetVerticalScroll(0) end
    else
        -- (back to what was open before the search)
        self.mode = self.prevMode or "tiles"
    end
    self:LayoutView()
end

-- Leaves the search (a group, a card or a part opened from anywhere): the box empties.
function SettingsUI:ClearSearch()
    if self.mode == "search" then self.mode = self.prevMode or "tiles" end
    if not self.query then return end
    self.query = nil
    if self.searchBox then
        self.searchBox:SetText("")
        self.searchBox:ClearFocus()
    end
end

-- (a crumb: the gold path of the results under it and a chevron after it; a click opens that place)
local function Crumb(f, i)
    local c = f.crumbs[i]
    if not c then
        c = CreateFrame("Button", nil, f)
        c:SetHeight(16)
        c.text = UI:Text(c, "small", "GOLD")
        c.text:SetPoint("LEFT", c, "LEFT", 0, 0)
        c.icon = c:CreateTexture(nil, "ARTWORK")
        c.icon:SetSize(9, 9)
        UI:SetChevron(c.icon, true)
        c.icon:SetVertexColor(S:Color("GOLD"))
        c:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 1, 1) end)
        c:SetScript("OnLeave", function(self) self.text:SetTextColor(S:Color("GOLD")) end)
        c:SetScript("OnClick", function(self) if self.go then self.go() end end)
        function c:SetPath(text, go)
            self.text:SetText(text)
            local w = floor(UI:TextWidth(self.text) + 0.5)
            self.icon:ClearAllPoints()
            self.icon:SetPoint("LEFT", self, "LEFT", w + 5, 0)
            self:SetWidth(w + 16)
            self.go = go
        end
        f.crumbs[i] = c
    end
    return c
end

-- (a result row for an option without a control of its own to make again: its words and a way to it)
local function PlainResult(f, e)
    local SU = SettingsUI
    SU.noIndex = true
    local row = SU:Row(f, e.title, e.desc ~= "" and e.desc or nil)
    SU.noIndex = nil
    local b = ns.UI:CreateSleekButton(row, "Show", 70, 22, function() SU:Jump(e) end)
    b:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.control = b
    PlaceText(row, 70)
    return row
end

function SettingsUI:LayoutResults()
    local f, q = self.results, self.query
    if not (f and q) then return end
    -- the matches, in the order the cards come (the index's)
    local hits = {}
    for _, e in ipairs(self.index) do
        local where = e.path[#e.path]
        if (not e.kit or self:KitShown(e.kit) or (ns.ClassKit and ns.ClassKit:IsDemo()))
            and (not e.part or self:PartShown(e.part)) and (not e.card or self:CardVisible(e.card))
            and (Lower(e.title):find(q, 1, true) or Lower(e.desc):find(q, 1, true) or Lower(where):find(q, 1, true)) then
            hits[#hits + 1] = e
        end
    end
    -- places whose name matches: a chip each
    local places = {}
    for _, c in ipairs(CATS) do
        if Lower(c.label):find(q, 1, true) then places[#places + 1] = { c.label, function() SettingsUI:OpenCategory(c.key) end } end
        for _, k in ipairs(c.cards) do
            if CARDS[k].label ~= c.label and self:CardVisible(k) and Lower(CARDS[k].label):find(q, 1, true) then
                places[#places + 1] = { c.label .. " > " .. CARDS[k].label, function() SettingsUI:SelectSection(k) end }
            end
        end
    end
    for _, p in ipairs(PARTS) do
        local name = PartInfo(p.key)
        if self:PartShown(p.key) and Lower(name):find(q, 1, true) then
            places[#places + 1] = { "Looks > " .. name, function() SettingsUI:OpenPart(p.key) end }
        end
    end
    for _, r in ipairs(f.rows) do r:Hide() end
    for _, c in ipairs(f.crumbs) do c:Hide() end
    for _, c in ipairs(f.chips) do c:Hide() end
    local y = -2
    local n = min(#hits, RESULTS_MAX)
    self.searchCount = #hits == 0 and "" or (#hits > RESULTS_MAX
        and format("%d options match \"%s\": the first %d", #hits, q, RESULTS_MAX)
        or format("%d option%s match%s \"%s\"", #hits, #hits == 1 and "" or "s", #hits == 1 and "es" or "", q))
    f.count:Hide()
    if #places > 0 then
        local x = 0
        for i, pl in ipairs(places) do
            if i > 6 then break end
            local c = f.chips[i]
            if not c then
                c = UI:CreateChip(f, { kind = "plain", onClick = function(self) if self.go then self.go() end end })
                f.chips[i] = c
            end
            c.go = pl[2]
            c:Set(pl[1])
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", f, "TOPLEFT", x, y - 2)
            c:Show()
            x = x + c:GetWidth() + 6
        end
        y = y - GO_H - 4
    end
    f.empty:SetShown(#hits == 0 and #places == 0)
    f.empty:SetText(format("Nothing matches \"%s\".\nTry sound, phase, look or council.", q))
    local last, nc = nil, 0
    for i = 1, n do
        local e = hits[i]
        local key = table.concat(e.path, "  >  ")
        if key ~= last then
            nc = nc + 1
            local c = Crumb(f, nc)
            c:SetPath(key, function() SettingsUI:Jump(e, true) end)
            c:ClearAllPoints()
            local gap = nc == 1 and 2 or 12
            c:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y - gap)
            c:Show()
            y = y - gap - 18
            last = key
        end
        if e.result == nil then
            self.noIndex = true
            local ok, row = pcall(function() return e.make and e.make(f) or PlainResult(f, e) end)
            self.noIndex = nil
            e.result = ok and row or false
            if e.result then
                local r = e.result
                -- its name opens the option's own place and lights it
                r.jump = CreateFrame("Button", nil, r)
                r.jump:SetPoint("TOPLEFT", r.title, "TOPLEFT", -2, 2)
                r.jump:SetHeight(16)
                r.jump:SetScript("OnClick", function() SettingsUI:Jump(e) end)
                r.jump:SetScript("OnEnter", function() r.title:SetTextColor(S:Color("GOLD")) end)
                r.jump:SetScript("OnLeave", function() r.title:SetTextColor(S:Color("TEXT")) end)
                AddTooltip(r.jump, e.title, "Click: show it in " .. table.concat(e.path, " > "))
            end
        end
        local r = e.result
        if r then
            r.title:SetText(Marked(e.title, q))
            if e.desc ~= "" then r.desc:SetText(Marked(e.desc, q)) end
            r.jump:SetWidth(floor(UI:TextWidth(r.title) + 4))
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y)
            r:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, y)
            if r.line then r.line:Show() end
            if r.Refresh then r:Refresh() end
            if r.control and r.control.Refresh then r.control:Refresh() end
            r:Show()
            y = y - (r:GetHeight() > 0 and r:GetHeight() or ROW_H)
        end
    end
    f.height = -y + 8
    f:SetHeight(max(1, f.height))
end

-- Opens where an entry lives (its card, its kit's card open, or its part's page) and lights its row (its fold opened;
-- a row hidden by a switch it needs lights that switch, a page switched off its own switch); toCard: the crumb's
-- click, the card (or page) itself.
function SettingsUI:Jump(e, toCard)
    if e.kit then kitOpen[e.kit] = true end
    if e.part then
        self:OpenPart(e.part)
    else
        self:SelectSection(e.card)
        if e.kit then self:LayoutClassTools() end
    end
    if toCard then return end
    -- (a fold opened, or the switch its row needs, or the page's own switch while it is off)
    local target
    if e.master then
        local head = self:PageHead()
        target = head and head.master
    else
        target = self:RevealRow(e.row)
    end
    Later(function() SettingsUI:ShowRow(target) end)       -- (once the page is laid out)
end
