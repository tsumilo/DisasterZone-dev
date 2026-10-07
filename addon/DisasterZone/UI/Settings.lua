if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Settings.lua", ...) then return end -- DisasterZone UI/Settings.lua
-- "Settings" tab: the sections in a nav on the left (Alerts, Group loot rules, Rolls, Strategy boards, Tooltips,
-- Window, Loot Council, Demo mode, About), one section at a time on the right. Every option is a row: its name, a
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

-- The page is 790 x 548: PAD at its sides, the nav on the left, the open section in a scroll frame on the right
-- (its bar in the right margin).
local PAD = 10
local PAGE_W, PAGE_H = 790, 548
local TOP_Y = 8
local NAV_W, NAV_H = 150, 28
local BODY_X = PAD + NAV_W + 18                -- 178
local BODY_W = PAGE_W - PAD - BODY_X           -- 602
local BODY_H = PAGE_H - TOP_Y - PAD            -- 530
local TITLE_H = 28                             -- a section's title (lines up with its nav item)
local SUB_H = 18                               -- the line under a title (who sets the rules, my council seat)
local ROW_H = 44
local DD_W, SWITCH_W = 196, 34
local TEXT_GAP = 16                            -- between a row's text and its control
local MEMBER_COLS, MEMBER_ROW_H = 3, 20
local GREY = { 0.62, 0.62, 0.62 }

local SECTIONS = {
    { key = "alerts", label = "Alerts" },
    { key = "rules", label = "Group loot rules" },
    { key = "rolls", label = "Rolls" },
    { key = "strategy", label = "Strategy boards" },
    { key = "tooltips", label = "Tooltips" },
    { key = "mylog", label = "My Log" },
    { key = "window", label = "Window" },
    { key = "council", label = "Loot Council" },
    { key = "demo", label = "Demo mode" },
    { key = "about", label = "About" },
}

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

-- The raids of a phase, short (a dropdown is 196 wide).
local PHASE_RAIDS = { "Kara, Gruul, Mag", "SSC, TK", "Hyjal, BT", "ZA", "Sunwell" }

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

local function Grey(text)
    return format("|cff%02x%02x%02x%s|r", floor(GREY[1] * 255 + 0.5), floor(GREY[2] * 255 + 0.5),
        floor(GREY[3] * 255 + 0.5), text)
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

local function ShowTip(owner, title, text)
    local tt = _G.GameTooltip
    tt:SetOwner(owner, "ANCHOR_TOP")
    tt:AddLine(title, 1, 0.82, 0)
    tt:AddLine(text, 1, 1, 1, true)
    tt:Show()
end

local function AddTooltip(frame, title, text)
    frame:HookScript("OnEnter", function(self) ShowTip(self, title, text) end)
    frame:HookScript("OnLeave", function() _G.GameTooltip:Hide() end)
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
                           "GROUP_RULES_CHANGED", "BIS_LOCK_CHANGED", "MYLOG_CHANGED" }) do
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

-- The panel in Blizzard's Options > AddOns: a hero band (the seal in a soft glow, the name, the version, the guild),
-- the two ways in (open, settings), a card for every page of the window (click = open it there, right-click = pin it
-- to the minimap arc) and a footer with the sync status and the slash commands. Built the first time it is shown, so
-- every page has registered by then; the cards are laid out again on every show (the panel's width can change).
local GOLD, CREAM = { 0.84, 0.69, 0.36 }, { 0.96, 0.9, 0.72 }
local DISC = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\disc"
local RING = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\ring"
local CARD_W, CARD_H, GAP = 196, 58, 10
-- One short line per card (the window's own page tips are too long for a card).
local CARD_TIPS = {
    home = "This week's raids and the calendar.", raids = "Raid nights, teams and strategies.",
    council = "Loot decisions and the loot log.", mybis = "Your BiS lists and what's missing.",
    atlas = "Every drop, set and cost.", members = "Members, professions, recipes.",
    dungeons = "Find a group for a dungeon.", events = "Guild events and cups (beta).",
    games = "Bingo and other guild games.", changelog = "What's new in every release.",
    settings = "Alerts, the minimap and more.",
}

local function Fill(tex, r, g, b, a) tex:SetColorTexture(r, g, b, a) return tex end

-- A 1px frame around f (r, g, b, a); returns the four edges so a caller can recolour them.
local function Edge(f, r, g, b, a)
    local e = {}
    for i, pts in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
                           { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetPoint(pts[1])
        t:SetPoint(pts[2])
        if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
        e[i] = Fill(t, r, g, b, a)
    end
    function e:Color(r2, g2, b2, a2) for _, t in ipairs(self) do t:SetColorTexture(r2, g2, b2, a2) end end
    return e
end

local function HeroFont(size)
    local name = "DisasterZoneHeroFont" .. size
    local font = _G[name] or CreateFont(name)
    local path = GameFontNormal:GetFont()
    font:SetFont(path, size, "")
    return font
end

local function NewCard(parent, key)
    local UI, Arc = ns.UI, ns.MinimapArc
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(CARD_W, CARD_H)
    c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    c.key = key
    c.bg = Fill(c:CreateTexture(nil, "BACKGROUND"), 0.06, 0.07, 0.09, 0.82)
    c.bg:SetAllPoints()
    c.glow = Fill(c:CreateTexture(nil, "BACKGROUND", nil, 1), GOLD[1], GOLD[2], GOLD[3], 0)
    c.glow:SetAllPoints()
    c.edge = Edge(c, 1, 1, 1, 0.07)
    c.bar = Fill(c:CreateTexture(nil, "ARTWORK"), GOLD[1], GOLD[2], GOLD[3], 1)
    c.bar:SetPoint("TOPLEFT")
    c.bar:SetPoint("BOTTOMLEFT")
    c.bar:SetWidth(2)
    c.disc = c:CreateTexture(nil, "ARTWORK")
    c.disc:SetTexture(DISC)
    c.disc:SetSize(34, 34)
    c.disc:SetPoint("LEFT", 12, 0)
    c.disc:SetVertexColor(0.13, 0.11, 0.18)
    c.ring = c:CreateTexture(nil, "ARTWORK", nil, 1)
    c.ring:SetTexture(RING)
    c.ring:SetAllPoints(c.disc)
    c.icon = c:CreateTexture(nil, "OVERLAY")
    c.icon:SetSize(18, 18)
    c.icon:SetPoint("CENTER", c.disc)
    local i = Arc and Arc.GetPageIcon and Arc:GetPageIcon(key) or UI.ICON.more
    local tc = UI:IconCoords(i)
    c.icon:SetTexture(UI.ICON_ATLAS)
    c.icon:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
    c.title = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.title:SetPoint("TOPLEFT", c.disc, "TOPRIGHT", 10, -1)
    c.title:SetText(ns.MainFrame:GetPageLabel(key) or key)
    c.tip = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.tip:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -3)
    c.tip:SetPoint("RIGHT", c, "RIGHT", -10, 0)
    c.tip:SetJustifyH("LEFT")
    c.tip:SetJustifyV("TOP")
    c.tip:SetHeight(26)
    c.tip:SetText(CARD_TIPS[key] or ns.MainFrame:GetPageTip(key) or "")
    c.pin = c:CreateTexture(nil, "OVERLAY")         -- on the minimap arc
    c.pin:SetTexture(DISC)
    c.pin:SetSize(6, 6)
    c.pin:SetPoint("TOPRIGHT", -7, -7)
    c.pin:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    c.h = 0
    c:SetScript("OnEnter", function(self)
        self.over = true
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(ns.MainFrame:GetPageLabel(self.key) or self.key, 1, 1, 1)
        GameTooltip:AddLine("Click: open it", 0.7, 0.7, 0.7)
        if Arc then
            GameTooltip:AddLine(Arc:IsPinned(self.key) and "Right-click: unpin from the minimap"
                or "Right-click: pin to the minimap", 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function(self) self.over = false GameTooltip:Hide() end)
    c:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if Arc then Arc:SetPinned(self.key, not Arc:IsPinned(self.key)) end
            if self:GetScript("OnEnter") and self.over then self:GetScript("OnEnter")(self) end
            return
        end
        local sp = _G.SettingsPanel
        if sp and sp:IsShown() then
            if _G.HideUIPanel then _G.HideUIPanel(sp) else sp:Hide() end
        end
        ns.MainFrame:Open(self.key)
    end)
    -- hover eases in and out: the card lifts, the gold bar and ring light up
    c:SetScript("OnUpdate", function(self, elapsed)
        local goal = self.over and 1 or 0
        if math.abs(self.h - goal) < 0.01 and self.settled then return end
        self.h = self.h + (goal - self.h) * math.min(1, elapsed * 12)
        self.settled = math.abs(self.h - goal) < 0.01
        local h = self.h
        self.glow:SetAlpha(0.07 * h)
        self.edge:Color(GOLD[1], GOLD[2], GOLD[3], 0.07 + 0.38 * h)
        self.bar:SetAlpha(0.25 + 0.75 * h)
        local l = 0.45 + 0.55 * h
        self.ring:SetVertexColor(GOLD[1] * l, GOLD[2] * l, GOLD[3] * l)
        self.icon:SetVertexColor(CREAM[1], CREAM[2], CREAM[3], 0.75 + 0.25 * h)
        self.pin:SetShown(Arc and Arc:IsPinned(self.key) or false)
    end)
    return c
end

-- The hero band, from the back: the raid's loading screen (the next raid's, else Outland), a dark fade from the left
-- so the text reads, embers drifting up, the seal in its glow with a sheen that sweeps its gold now and then, then
-- the name, the guild, a live line (next raid, members online, BiS) and the two buttons. p.intro() plays the opening:
-- the seal grows in, the text rises and fades in, the gold line draws across.
local HERO_H = 176
local EMBERS = 16

local function Countdown(s)
    if s <= 0 then return "now" end
    local d, h, m = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60)
    if d > 0 then return ("in %dd %dh"):format(d, h) end
    if h > 0 then return ("in %dh %dm"):format(h, m) end
    return ("in %dm"):format(math.max(1, m))
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

local function EaseOutBack(t)
    t = t - 1
    return 1 + 2.4 * t * t * t + 1.4 * t * t
end

local function Shade(parent, layer, dir, a1, a2, r, g, b)
    local t = parent:CreateTexture(nil, "BACKGROUND", nil, layer)
    t:SetColorTexture(1, 1, 1, 1)
    if not (CreateColor and pcall(t.SetGradient, t, dir, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2))) then
        t:SetColorTexture(r, g, b, (a1 + a2) / 2)
    end
    return t
end

local function BuildHero(canvas, p)
    local UI = ns.UI
    local hero = CreateFrame("Frame", nil, canvas)
    hero:SetPoint("TOPLEFT", 12, -12)
    hero:SetPoint("TOPRIGHT", -12, -12)
    hero:SetHeight(HERO_H)
    hero:SetClipsChildren(true)
    Fill(hero:CreateTexture(nil, "BACKGROUND"), 0.05, 0.04, 0.08, 1):SetAllPoints()

    -- the painting and its shades
    p.art = hero:CreateTexture(nil, "BACKGROUND", nil, 1)
    p.art:SetAllPoints()
    local left = Shade(hero, 2, "HORIZONTAL", 0.97, 0.15, 0.04, 0.03, 0.07)
    left:SetPoint("TOPLEFT")
    left:SetPoint("BOTTOMLEFT")
    left:SetPoint("RIGHT", hero, "CENTER", 120, 0)
    local rest = Fill(hero:CreateTexture(nil, "BACKGROUND", nil, 2), 0.04, 0.03, 0.07, 0.15)
    rest:SetPoint("TOPLEFT", left, "TOPRIGHT")
    rest:SetPoint("BOTTOMRIGHT")
    local low = Shade(hero, 3, "VERTICAL", 0.75, 0, 0.03, 0.02, 0.05)   -- (vertical: the first colour is the bottom's)
    low:SetPoint("BOTTOMLEFT")
    low:SetPoint("BOTTOMRIGHT")
    low:SetHeight(60)
    Fill(hero:CreateTexture(nil, "BACKGROUND", nil, 4), 0.25, 0.12, 0.4, 0.12):SetAllPoints()   -- a purple cast
    Edge(hero, GOLD[1], GOLD[2], GOLD[3], 0.18)
    p.line = Fill(hero:CreateTexture(nil, "OVERLAY", nil, 7), GOLD[1], GOLD[2], GOLD[3], 0.9)
    p.line:SetPoint("BOTTOMLEFT")
    p.line:SetHeight(2)
    p.line:SetWidth(1)
    p.raidName = hero:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")   -- whose painting it is
    p.raidName:SetPoint("BOTTOMRIGHT", -10, 8)
    p.raidName:SetTextColor(0.75, 0.7, 0.62, 0.8)

    -- embers
    local embers = {}
    for i = 1, EMBERS do
        local e = hero:CreateTexture(nil, "ARTWORK", nil, 0)
        e:SetTexture(DISC)
        e:SetBlendMode("ADD")
        embers[i] = e
    end
    local function Spawn(e, anywhere)
        local w = hero:GetWidth() or 600
        if w < 100 then w = 600 end
        e.x = math.random() * w
        e.y = -6
        e.v = 9 + math.random() * 16
        e.ph = math.random() * 6.28
        e.span = (HERO_H + 12) / e.v
        e.life = anywhere and math.random() * e.span or 0
        local s = 2 + math.random() * 3
        e:SetSize(s, s)
        if math.random() < 0.6 then e:SetVertexColor(1, 0.62, 0.22) else e:SetVertexColor(0.95, 0.82, 0.45) end
    end

    -- the seal, in a frame of its own so the opening can scale it
    local sealF = CreateFrame("Frame", nil, hero)
    sealF:SetSize(150, 150)
    local halo = sealF:CreateTexture(nil, "ARTWORK")
    halo:SetTexture(DISC)
    halo:SetAllPoints()
    halo:SetVertexColor(0.45, 0.3, 0.65)
    local orbit = sealF:CreateTexture(nil, "ARTWORK", nil, 1)
    orbit:SetTexture(RING)
    orbit:SetPoint("CENTER")
    orbit:SetSize(124, 124)
    orbit:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.35)
    local seal = sealF:CreateTexture(nil, "OVERLAY")
    seal:SetSize(108, 108)
    seal:SetPoint("CENTER")
    local hasSeal = ns:HasAssets(4)
    seal:SetTexture(hasSeal and "Interface\\AddOns\\DisasterZone\\Media\\Launcher\\seal"
        or "Interface\\Icons\\INV_Misc_Bag_10_Blue")
    if not hasSeal then seal:SetSize(72, 72) end
    -- the sheen: a slanted band of light, cut to the seal's disc
    local mask = sealF:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(seal)
    local sheen = {}
    for i = 1, 2 do
        local s = sealF:CreateTexture(nil, "OVERLAY", nil, 2)
        s:SetColorTexture(1, 1, 1, 1)
        s:SetBlendMode("ADD")
        s:SetSize(14, 160)
        local c1 = CreateColor and CreateColor(1, 0.92, 0.7, 0)
        local c2 = CreateColor and CreateColor(1, 0.92, 0.7, 0.55)
        if not (c1 and pcall(s.SetGradient, s, "HORIZONTAL", i == 1 and c1 or c2, i == 1 and c2 or c1)) then
            s:SetColorTexture(1, 0.92, 0.7, 0.2)
        end
        s:SetRotation(math.rad(-25))
        s:AddMaskTexture(mask)
        s:Hide()
        sheen[i] = s
    end

    -- the text column
    local col = CreateFrame("Frame", nil, hero)
    col:SetPoint("TOPLEFT", 172, 0)
    col:SetPoint("BOTTOMRIGHT")
    local title = col:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(HeroFont(30))
    title:SetPoint("TOPLEFT", 0, -26)
    title:SetText("|cffff8000Disaster|r|cfff5e6b8Zone|r")
    title:SetShadowOffset(1, -2)
    title:SetShadowColor(0, 0, 0, 0.9)

    local ver = CreateFrame("Frame", nil, col)
    ver.text = ver:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ver.text:SetPoint("CENTER")
    ver.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    local applied = ns.Boot and ns.Boot.applied and (ns.Boot.applied.files or 0) > 0
    ver.text:SetText("v" .. tostring(ns.version or "?")
        .. (applied and ("  ·  update on " .. tostring(ns.diskVersion)) or ""))
    ver:SetSize(ver.text:GetStringWidth() + 16, 18)
    ver:SetPoint("LEFT", title, "RIGHT", 12, 0)
    Fill(ver:CreateTexture(nil, "BACKGROUND"), 0.08, 0.06, 0.03, 0.75):SetAllPoints()
    Edge(ver, GOLD[1], GOLD[2], GOLD[3], 0.5)

    p.guild = col:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.guild:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 1, -6)
    p.guild:SetTextColor(0.85, 0.82, 0.9)
    p.guild:SetShadowOffset(1, -1)

    -- the live line: three small facts, each with a gold label, split by thin gold rules
    local function fact(anchor, dx)
        local f = col:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if anchor then
            f:SetPoint("LEFT", anchor, "RIGHT", dx, 0)
        else
            f:SetPoint("TOPLEFT", p.guild, "BOTTOMLEFT", 0, -10)
        end
        f:SetShadowOffset(1, -1)
        return f
    end
    local function rule(anchor)
        local r = Fill(col:CreateTexture(nil, "OVERLAY"), GOLD[1], GOLD[2], GOLD[3], 0.5)
        r:SetSize(1, 10)
        r:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
        return r
    end
    p.factRaid = fact()
    p.factOnline = fact(rule(p.factRaid), 10)
    p.factBis = fact(rule(p.factOnline), 10)
    p.bisBar = CreateFrame("Frame", nil, col)
    p.bisBar:SetSize(54, 4)
    p.bisBar:SetPoint("LEFT", p.factBis, "RIGHT", 8, 0)
    Fill(p.bisBar:CreateTexture(nil, "BACKGROUND"), 1, 1, 1, 0.12):SetAllPoints()
    p.bisFill = Fill(p.bisBar:CreateTexture(nil, "ARTWORK"), GOLD[1], GOLD[2], GOLD[3], 1)
    p.bisFill:SetPoint("TOPLEFT")
    p.bisFill:SetPoint("BOTTOMLEFT")

    local open = UI:CreateButton(col, "Open DisasterZone", 150, 26, function()
        local sp = _G.SettingsPanel
        if sp and sp:IsShown() then
            if _G.HideUIPanel then _G.HideUIPanel(sp) else sp:Hide() end
        end
        ns.MainFrame:Open()
    end)
    if open.SetKind then open:SetKind("primary") end
    open:SetPoint("TOPLEFT", p.factRaid, "BOTTOMLEFT", -1, -16)
    local settings = UI:CreateButton(col, "Settings", 100, 26, OpenFromBlizzard)
    settings:SetPoint("LEFT", open, "RIGHT", 8, 0)

    -- motion: the glow breathes, embers rise, the sheen passes every few seconds, the opening plays on show
    local t, intro, sheenAt = 0, nil, 1.2
    local function placeSeal(scale)
        scale = math.max(scale, 0.05)
        sealF:SetScale(scale)
        sealF:ClearAllPoints()
        sealF:SetPoint("CENTER", hero, "TOPLEFT", 85 / scale, -HERO_H / 2 / scale)
    end
    placeSeal(1)
    function p.intro()
        intro = 0
        sheenAt = t + 1.1
        for _, e in ipairs(embers) do Spawn(e, true) end
    end
    hero:SetScript("OnUpdate", function(_, elapsed)
        t = t + elapsed
        local b = math.sin(t * 1.4)
        halo:SetAlpha(0.3 + 0.12 * b)
        orbit:SetSize(124 + 6 * b, 124 + 6 * b)
        orbit:SetAlpha(0.7 + 0.3 * b)
        -- embers (dimmer over the seal's side)
        local w = hero:GetWidth() or 600
        for _, e in ipairs(embers) do
            if not e.span then Spawn(e, true) end
            e.life = e.life + elapsed
            if e.life >= e.span then Spawn(e) end
            local x = e.x + math.sin(e.ph + e.life * 1.3) * 8
            local k = e.life / e.span
            e:SetAlpha(math.min(1, k * 5) * (1 - k) * 0.85 * (x < 170 and 0.45 or 1))
            e:ClearAllPoints()
            e:SetPoint("CENTER", hero, "BOTTOMLEFT", x, e.y + e.v * e.life)
        end
        -- the sheen: 0.8 s across the seal, then again 5 s later
        local s = (t - sheenAt) / 0.8
        if s >= 1 then
            sheenAt = t + 5
            s = -1
        end
        for i, tex in ipairs(sheen) do
            tex:SetShown(s >= 0)
            if s >= 0 then
                tex:ClearAllPoints()
                tex:SetPoint("CENTER", seal, "CENTER", -80 + 160 * s + (i == 1 and -7 or 7), 0)
            end
        end
        -- the opening
        if intro then
            intro = intro + elapsed
            placeSeal(0.55 + 0.45 * EaseOutBack(math.min(1, intro / 0.55)))
            sealF:SetAlpha(math.min(1, intro / 0.25))
            local c = math.min(1, math.max(0, (intro - 0.15) / 0.45))
            local ce = 1 - (1 - c) ^ 3
            col:SetAlpha(ce)
            col:ClearAllPoints()
            col:SetPoint("TOPLEFT", 172, -10 * (1 - ce))
            col:SetPoint("BOTTOMRIGHT", 0, -10 * (1 - ce))
            local l = math.min(1, math.max(0, (intro - 0.25) / 0.6))
            p.line:SetWidth(math.max(1, w * (1 - (1 - l) ^ 3)))
            if intro > 0.9 then
                intro = nil
                placeSeal(1)
            end
        else
            p.line:SetWidth(w)
        end
    end)
    p.hero = hero
    return hero
end

local function RefreshHero(p)
    local guild = IsInGuild() and GetGuildInfo("player")
    local council = ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil()
    p.guild:SetText(guild and ("<" .. guild .. ">  ·  " .. (council and "Loot Council" or "Raider"))
        or "Your guild's raids, loot and pastimes in one place")

    local v = NextRaid()
    local PUI = ns.RaidPlanUI
    local w = math.max(p.hero:GetWidth() or 0, 600)
    local file, l, r, t, b
    if PUI and PUI.RaidArt then file, l, r, t, b = PUI:RaidArt(v and v.i or "other", w, HERO_H, 1) end
    if not file then
        file, l, r, t, b = "Interface\\Glues\\LoadingScreens\\LoadScreenOutland", 0, 1, 0.3, 0.3 + HERO_H / w
    end
    p.art:SetTexture(file)
    p.art:SetTexCoord(l, r, t, b)
    local G = "|cffd6b05c"
    if v then
        local name = ns.RaidPlan.GetRaidName and ns.RaidPlan:GetRaidName(v) or "Raid"
        p.factRaid:SetText(G .. "Next raid|r  " .. name .. "  ·  " .. date("%a %H:%M", v.t) .. "  ·  "
            .. Countdown(v.t - time()))
        local inst = ns.RaidPlan.GetInstance and ns.RaidPlan:GetInstance(v.i)
        p.raidName:SetText(inst and inst.name or "")
    else
        p.factRaid:SetText(G .. "Next raid|r  none planned")
        p.raidName:SetText("")
    end
    local online = 0
    if IsInGuild() then
        local _, on = GetNumGuildMembers()
        online = tonumber(on) or 0
    end
    p.factOnline:SetText(G .. "Online|r  " .. online)
    local ok, prog = false, nil
    if ns.MyBiS and ns.MyBiS.GetProgress then ok, prog = pcall(ns.MyBiS.GetProgress, ns.MyBiS) end
    if ok and type(prog) == "table" and (prog.total or 0) > 0 then
        p.factBis:SetText(G .. "BiS|r  " .. (prog.obtained or 0) .. "/" .. prog.total)
        p.bisFill:SetWidth(math.max(1, 54 * math.min(1, (prog.obtained or 0) / prog.total)))
        p.bisBar:Show()
    else
        p.factBis:SetText(G .. "BiS|r  no list yet")
        p.bisBar:Hide()
    end
    p.intro()
end

local function BuildBlizzardPanel(canvas)
    local UI = ns.UI
    local p = {}

    local hero = BuildHero(canvas, p)

    -- the cards
    local head = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", 2, -18)
    head:SetText("Jump to")
    head:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    local sub = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("LEFT", head, "RIGHT", 10, 0)
    sub:SetText("Right-click a card to pin it to the minimap button")
    local rule = Fill(canvas:CreateTexture(nil, "ARTWORK"), 1, 1, 1, 0.08)
    rule:SetPoint("LEFT", sub, "RIGHT", 10, 0)
    rule:SetPoint("RIGHT", hero, "RIGHT", 0, 0)
    rule:SetHeight(1)
    p.grid = CreateFrame("Frame", nil, canvas)
    p.grid:SetPoint("TOPLEFT", head, "BOTTOMLEFT", -2, -10)
    p.grid:SetPoint("RIGHT", hero, "RIGHT")
    p.grid:SetHeight(1)
    p.cards = {}

    -- the footer
    local foot = CreateFrame("Frame", nil, canvas)
    foot:SetPoint("BOTTOMLEFT", 12, 12)
    foot:SetPoint("BOTTOMRIGHT", -12, 12)
    foot:SetHeight(34)
    Fill(foot:CreateTexture(nil, "BACKGROUND"), 0.05, 0.06, 0.08, 0.8):SetAllPoints()
    Edge(foot, 1, 1, 1, 0.06)
    local dot = foot:CreateTexture(nil, "ARTWORK")
    dot:SetTexture(DISC)
    dot:SetSize(7, 7)
    dot:SetPoint("LEFT", 12, 0)
    dot:SetVertexColor(0.5, 0.82, 0.5)
    p.status = foot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.status:SetPoint("LEFT", dot, "RIGHT", 8, 0)
    p.status:SetJustifyH("LEFT")
    local last
    for i, cmd in ipairs({ "/dz help", "/dz settings", "/dz" }) do
        local chip = CreateFrame("Frame", nil, foot)
        chip.text = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        chip.text:SetPoint("CENTER")
        chip.text:SetText(cmd)
        chip.text:SetTextColor(CREAM[1], CREAM[2], CREAM[3])
        chip:SetSize(chip.text:GetStringWidth() + 14, 20)
        Fill(chip:CreateTexture(nil, "BACKGROUND"), 1, 1, 1, 0.05):SetAllPoints()
        Edge(chip, 1, 1, 1, 0.1)
        if last then chip:SetPoint("RIGHT", last, "LEFT", -6, 0) else chip:SetPoint("RIGHT", -8, 0) end
        last = chip
    end
    p.status:SetPoint("RIGHT", last, "LEFT", -12, 0)
    p.status:SetWordWrap(false)
    return p
end

local function RefreshBlizzardPanel(canvas, p)
    RefreshHero(p)
    local status = ns.Sync and ns.Sync.GetStatusText and ns.Sync:GetStatusText()
    p.status:SetText(((status and status ~= "" and ns.UI:SafeText(status)) or "Ready"))

    local keys = ns.MainFrame:GetShownPages()
    local gw = p.grid:GetWidth() or 0
    if gw < CARD_W then gw = math.max((canvas:GetWidth() or 0) - 24, 3 * CARD_W + 2 * GAP) end
    local cols = math.max(1, math.floor((gw + GAP) / (CARD_W + GAP)))
    local w = (gw - (cols - 1) * GAP) / cols
    for _, c in pairs(p.cards) do c:Hide() end
    for i, key in ipairs(keys) do
        local c = p.cards[key] or NewCard(p.grid, key)
        p.cards[key] = c
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        c:SetWidth(w)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", p.grid, "TOPLEFT", col * (w + GAP), -row * (CARD_H + GAP))
        c.settled = false
        c:SetAlpha(0)
        c.fade = 0.35 + (i - 1) * 0.03                    -- the cards appear one after another
        c:Show()
    end
    -- the fade-in, run from the canvas so cards keep their own OnUpdate for hover
    local t = 0
    canvas:SetScript("OnUpdate", function(_, elapsed)
        t = t + elapsed
        local busy = false
        for _, c in pairs(p.cards) do
            if c:IsShown() and c.fade then
                local a = math.min(1, math.max(0, (t - c.fade) / 0.25))
                c:SetAlpha(a)
                if a >= 1 then c.fade = nil else busy = true end
            end
        end
        if not busy then canvas:SetScript("OnUpdate", nil) end
    end)
end

function SettingsUI:RegisterBlizzardCategory()
    local S = _G.Settings
    if self.category or not (S and S.RegisterCanvasLayoutCategory and S.RegisterAddOnCategory) then return end
    local canvas = CreateFrame("Frame", "DisasterZoneBlizzardOptions")
    local panel
    canvas:SetScript("OnShow", function(f)
        if not (ns.UI and ns.MainFrame) then return end
        panel = panel or BuildBlizzardPanel(f)
        -- the canvas gets its size in the same frame it shows: lay the cards out once it has one
        C_Timer.After(0, function() if f:IsShown() then RefreshBlizzardPanel(f, panel) end end)
    end)

    local cat = S.RegisterCanvasLayoutCategory(canvas, "DisasterZone")
    S.RegisterAddOnCategory(cat)
    self.category = cat
end

---------------------------------------------------------------------------
-- Building blocks: the nav, a section, its rows
---------------------------------------------------------------------------

-- A nav item: grey text; the open section's is gold with a gold bar on its left and a soft gold fill.
local function NewNavItem(parent, text, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(NAV_W, NAV_H)
    b.fill = b:CreateTexture(nil, "BACKGROUND")
    b.fill:SetAllPoints()
    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetPoint("TOPLEFT")
    b.bar:SetPoint("BOTTOMLEFT")
    b.bar:SetWidth(2)
    b.bar:SetColorTexture(1, 0.82, 0, 0.9)
    b.text = NewFS(b, "GameFontHighlight", NAV_W - 16, false)
    b.text:SetPoint("LEFT", b, "LEFT", 12, 0)
    b.text:SetText(text)
    local function paint(self)
        if self.active then
            self.fill:SetColorTexture(1, 0.82, 0, 0.08)
            self.text:SetTextColor(1, 0.82, 0)
        elseif self.hovered then
            self.fill:SetColorTexture(1, 1, 1, 0.04)
            self.text:SetTextColor(1, 1, 1)
        else
            self.fill:SetColorTexture(0, 0, 0, 0)
            self.text:SetTextColor(0.74, 0.74, 0.74)
        end
        self.bar:SetShown(self.active and true or false)
    end
    function b:SetActive(on)
        self.active = on and true or false
        paint(self)
    end
    b:SetScript("OnEnter", function(self) self.hovered = true; paint(self) end)
    b:SetScript("OnLeave", function(self) self.hovered = false; paint(self) end)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", onClick)
    paint(b)
    return b
end

-- A section: its title (gold, as big as the nav item is tall), rows from sec.y down.
function SettingsUI:NewSection(def)
    local sec = CreateFrame("Frame", nil, self.child)
    sec:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, 0)
    sec:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, 0)
    sec:SetHeight(BODY_H)
    sec.key = def.key
    sec.rows = {}
    sec.title = NewFS(sec, "GameFontNormalLarge", nil, false)
    sec.title:SetPoint("LEFT", sec, "TOPLEFT", 0, -TITLE_H / 2)
    sec.title:SetText(def.label)
    sec.y = -TITLE_H
    sec:Hide()
    self.sections[def.key] = sec
    return sec
end

-- The line under a section's title (who sets the rules, my council seat): white, its asides grey.
function SettingsUI:Subtitle(sec)
    local fs = NewFS(sec, "GameFontHighlightSmall", nil, false)
    fs:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - 1)
    fs:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y - 1)
    sec.y = sec.y - SUB_H
    return fs
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
    row.title = NewFS(row, "GameFontHighlight", nil, false)
    row.title:SetText(title or "")
    row.desc = NewFS(row, "GameFontHighlightSmall", nil, false)
    row.desc:SetTextColor(GREY[1], GREY[2], GREY[3])
    row.desc:SetText(desc or "")
    row.hasDesc = desc ~= nil
    row.line = row:CreateTexture(nil, "BORDER")
    row.line:SetColorTexture(1, 1, 1, 0.06)
    row.line:SetHeight(1)
    row.line:SetPoint("BOTTOMLEFT")
    row.line:SetPoint("BOTTOMRIGHT")
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
    row.value = NewFS(row, "GameFontHighlight", nil, false)
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
    local dd = ns.UI:CreateDropdown(row, DD_W, getOptions, getSelected, onSelect)
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

    self.nav = {}
    for i, def in ipairs(SECTIONS) do
        local b = NewNavItem(panel, def.label, function() SettingsUI:SelectSection(def.key) end)
        b:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(TOP_Y + (i - 1) * NAV_H))
        self.nav[def.key] = b
    end
    local rule = panel:CreateTexture(nil, "BORDER")
    rule:SetColorTexture(1, 1, 1, 0.08)
    rule:SetWidth(1)
    rule:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + NAV_W, -TOP_Y)
    rule:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD + NAV_W, PAD)

    local scroll = ns.UI:CreateScrollFrame(panel, "DisasterZoneSettingsScroll")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", BODY_X, -TOP_Y)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, PAD)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(BODY_W, BODY_H)
    scroll:SetScrollChild(child)
    self.scroll, self.child = scroll, child
    -- the column's right edge is the page's minus PAD, whatever the page's real width (GetWidth is 0 until laid out)
    scroll:HookScript("OnSizeChanged", function()
        if SettingsUI:SyncWidth() then SettingsUI:RequestRefresh() end
    end)

    self.sections = {}
    for _, def in ipairs(SECTIONS) do self:NewSection(def) end
    self:BuildAlerts(self.sections.alerts)
    self:BuildGroupRules(self.sections.rules)
    self:BuildRolls(self.sections.rolls)
    self:BuildStrategy(self.sections.strategy)
    self:BuildTooltips(self.sections.tooltips)
    self:BuildMyLog(self.sections.mylog)
    self:BuildWindow(self.sections.window)
    self:BuildCouncil(self.sections.council)
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

-- Opens one section (key as in SECTIONS); the others hide. The page keeps its size: only the scroll range follows.
function SettingsUI:SelectSection(key)
    if not (self.sections and self.sections[key]) then key = "alerts" end
    self.section = key
    if not self.sections then return end
    for k, sec in pairs(self.sections) do sec:SetShown(k == key) end
    for k, b in pairs(self.nav or {}) do b:SetActive(k == key) end
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

-- Group loot rules (ADDENDUM D §24-§27, ADDENDUM E §32): the loot leader of the group decides these for everyone in
-- it. The line under the title says whose values are in effect; while they come from someone else every rule shows
-- its value as text.
local RULES_TIP = "The group's loot leader sets these for everyone in the group: in a raid the raid leader (else "
    .. "the master looter); in a party the leader if on the Loot Council or if they turned dungeon mode on (else a "
    .. "council member). Without one, your own values apply. /dz rules prints the rules in effect."

function SettingsUI:BuildGroupRules(sec)
    self.rulesLock = sec:CreateTexture(nil, "OVERLAY")
    self.rulesLock:SetTexture(ns.UI.ICON_LOCK or "Interface\\PetBattles\\PetBattle-LockIcon")
    self.rulesLock:SetSize(12, 12)
    self.rulesLock:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y - 2)
    self.rulesY = sec.y
    self.rulesStatus = self:Subtitle(sec)
    local hit = CreateFrame("Frame", nil, sec)
    hit:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y + SUB_H)
    hit:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y + SUB_H)
    hit:SetHeight(SUB_H)
    hit:EnableMouse(true)
    hit:SetScript("OnEnter", function(f) ShowTip(f, "Group loot rules", RULES_TIP) end)
    hit:SetScript("OnLeave", function() _G.GameTooltip:Hide() end)

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
    local note = NewFS(sec, "GameFontHighlightSmall", nil, true)
    note:SetTextColor(GREY[1], GREY[2], GREY[3])
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
    del = ns.UI:CreateButton(row, "Delete all my logs", 150, 22, function()
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

function SettingsUI:BuildDemo(sec)
    sec.y = sec.y - 4
    self:Switch(sec, "Demo data", "Fake guild members and a raid to try the council views solo. Never saved or sent.",
        function() return (ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()) and true or false end,
        function(a, b)
            if ns.Demo and ns.Demo.SetEnabled then ns.Demo:SetEnabled(Bool(a, b)) end
        end)
    self:EndSection(sec)
    local y = sec.y - 16
    local sim = ns.UI:CreateButton(sec, "Simulate a boss drop", nil, 22, function()
        if ns.Loot and ns.Loot.SimulateDrop then ns.Loot:SimulateDrop() end
    end)
    Put(sim, sec, 0, y)
    AddTooltip(sim, "Simulate a boss drop", "Opens the drop panel with a made-up boss drop. In demo mode, click Roll "
        .. "on any of its items to watch a roll.")
    local demoRoll = ns.UI:CreateButton(sec, "Demo a roll", nil, 22, function() SettingsUI:DemoRoll() end)
    demoRoll:SetPoint("LEFT", sim, "RIGHT", 8, 0)
    AddTooltip(demoRoll, "Demo a roll", "Turns on demo mode, simulates a boss drop and starts a roll on its first item: "
        .. "you get the Roll / Pass popup and fake raiders roll in the drop panel. Nothing is sent.")
    local recent = ns.UI:CreateButton(sec, "Recent drops", nil, 22, function()
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
    local syncBtn = ns.UI:CreateButton(srow, "Request sync", 112, 22, function()
        if ns.Sync and ns.Sync.RequestSync then ns.Sync:RequestSync() end
    end)
    syncBtn:SetPoint("RIGHT", srow, "RIGHT", 0, 0)
    PlaceText(srow, 112)
    self:SwitchSetting(sec, "Debug messages in chat", "Extra lines in your chat for tracking down problems.",
        "debug", false)
    self:EndSection(sec)
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
            who = rulesFrom and ShortName(rulesFrom) or nil
        elseif Get("dungeon.enabled", false) then
            who = "you"
            -- only my client uses it unless I may tell the party (leader / council) or someone did
            local D = ns.Dungeon
            if not by and rulesStatus ~= "mine" and type(D) == "table" and type(D.CanTellParty) == "function" then
                local ok, can = pcall(D.CanTellParty, D)
                if ok and not can then extra = Grey(" (only for you)") end
            end
        elseif by then
            who = IsMe(by) and "you" or ShortName(by)
        end
        return Grey("Status: ") .. Paint(who and ("Active — enabled by " .. who) or "Active", "obtained") .. extra
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
        return Paint("You set these for your group", "obtained") .. Grey(" (changes are sent to everyone in it)")
    end
    if InGroup() then
        return "Your own settings" .. Grey(" (no loot leader with DisasterZone in this group)")
    end
    return "Your own settings" .. Grey(" (not in a group)")
end

-- The state of the group's BiS lists (ADDENDUM F §38), under "BiS lists".
function SettingsUI:LockStatusText()
    local UI = ns.UI
    if not (UI and UI.GetBiSLock) then return "" end
    local locked, info = UI:GetBiSLock()
    if locked then
        return Paint("Locked by " .. UI:LockByText(info, true), "warn")
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
    if self.rulesStatus then
        self.rulesStatus:SetText(self:GroupRulesStatusText())
        local sec, y = self.sections.rules, (self.rulesY or -TITLE_H) - 1
        self.rulesStatus:ClearAllPoints()
        self.rulesStatus:SetPoint("TOPLEFT", sec, "TOPLEFT", remote and 17 or 0, y)
        self.rulesStatus:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, y)
        self.rulesLock:SetShown(remote)
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
    local S = ns.Sync
    local peers = S and S.GetVersions and S:GetVersions()
    local online = S and S.GetOnlineCouncilPeers and S:GetOnlineCouncilPeers()
    local status = (S and S.GetStatusText and S:GetStatusText()) or ""
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
local function MemberOnEnter(self)
    if not self.key then return end
    local tt = _G.GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    tt:AddLine(ColoredName(self.key))
    local G = ns.Guild
    local rank = G and G.GetRankName and G:GetRankName(self.key)
    if rank then tt:AddLine(rank, 0.8, 0.8, 0.8) end
    tt:AddLine(self.online and "Online" or "Offline", 0.6, 0.6, 0.6)
    if self.fixed == "Master looter" then
        tt:AddLine("Master looter: on this raid's council while the raid runs the loot council", 0.6, 0.6, 0.6, true)
    elseif self.fixed then
        tt:AddLine(self.fixed .. ": always on the council", 0.6, 0.6, 0.6, true)
    end
    tt:Show()
end

-- A council member: class circle and class-coloured name; offline members are dimmed.
local function NewMemberEntry(parent)
    local e = CreateFrame("Frame", nil, parent)
    e:SetHeight(MEMBER_ROW_H)
    e.icon = e:CreateTexture(nil, "ARTWORK")
    e.icon:SetSize(16, 16)
    e.icon:SetPoint("LEFT", e, "LEFT", 0, 0)
    e.text = NewFS(e, "GameFontHighlight", nil, false)
    e.text:SetPoint("LEFT", e, "LEFT", 22, 0)
    e.text:SetPoint("RIGHT", e, "RIGHT", 0, 0)
    e:EnableMouse(true)
    e:SetScript("OnEnter", MemberOnEnter)
    e:SetScript("OnLeave", function() _G.GameTooltip:Hide() end)
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
        e:SetWidth(colW - 8)
        Put(e, cs, ((i - 1) % MEMBER_COLS) * colW, y - floor((i - 1) / MEMBER_COLS) * MEMBER_ROW_H)
        local cls = m.classFile or ClassOf(m.key)
        if ns.UI and ns.UI.ClassIcon then ns.UI:ClassIcon(e.icon, cls) end
        local text = m.name or ColoredName(m.key)
        if m.fixed == "Guild Master" then
            text = text .. Grey(" (GM)")
        elseif m.fixed then
            text = text .. Grey(" (" .. m.fixed:lower() .. ")")
        end
        e.text:SetText(text)
        e.icon:SetAlpha(e.online and 1 or 0.4)
        e.text:SetAlpha(e.online and 1 or 0.45)
        e:Show()
    end
    for i = #list + 1, #pool do pool[i]:Hide() end
    if #list == 0 then return y end
    return y - (floor((#list - 1) / MEMBER_COLS) + 1) * MEMBER_ROW_H
end

function SettingsUI:BuildCouncil(sec)
    local cs = sec
    self.cs = cs
    cs.status = self:Subtitle(sec)
    cs.top = sec.y - 6
    cs.summary = NewFS(cs, "GameFontHighlight", BODY_W, true)
    cs.members = {}
    cs.raidSummary = NewFS(cs, "GameFontHighlight", BODY_W, true)
    cs.raidMembers = {}
    cs.editBtn = ns.UI:CreateButton(cs, "Edit council", 116, 22, function() SettingsUI:OpenCouncilEditor() end)
    cs.editBtn:SetPoint("RIGHT", cs, "TOPRIGHT", 0, -TITLE_H / 2)
    AddTooltip(cs.editBtn, "Edit council",
        "Opens the Loot Council picker (Council tab). The Guild Master picks the guild council; "
        .. "the raid leader picks extra council members for their raid.")
    cs.info = NewFS(cs, "GameFontHighlightSmall", BODY_W, true)
    cs.info:SetTextColor(GREY[1], GREY[2], GREY[3])
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
        cs.status:SetText(Paint("You are on the Loot Council.", "obtained") .. Grey(" (demo mode)"))
    elseif IsCouncil() then
        local src = sum and SOURCE_TEXT[sum.mySource]
        cs.status:SetText(Paint("You are on the Loot Council.", "obtained") .. (src and Grey(" · " .. src) or ""))
    else
        cs.status:SetText(Grey("You are not on the Loot Council."))
    end

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
            text = "Guild council" .. Grey(format(" · set by %s %s · phase P%d", ShortName(g.by or sum.gm or "?"),
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
                .. "never loot council", ShortName(leader))))
        elseif sum.raidShared and leader then
            cs.raidSummary:SetText("This raid's council" .. Grey(" · set by raid leader " .. ShortName(leader)))
        elseif leader then
            cs.raidSummary:SetText("This raid's council" .. Grey(" · only the raid leader " .. ShortName(leader)))
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
    for _, w in ipairs(self.refreshers) do
        if w.Refresh then w:Refresh() end
    end
    self:RefreshGroupRules()
    self:RefreshAbout()
    self:RefreshDungeon()
    self:RefreshCouncil()
    self:FitChild()
end
