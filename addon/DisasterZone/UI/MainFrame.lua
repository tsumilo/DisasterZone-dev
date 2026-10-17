if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MainFrame.lua", ...) then return end -- DisasterZone UI/MainFrame.lua
-- ns.MainFrame: the main window, its navigation strip and page registry (panels created lazily), the sync status
-- at the right of the strip, and the minimap / LibDataBroker launcher.
local addonName, ns = ...

local MainFrame = ns:NewModule("MainFrame")
local S = ns.Style

local FRAME_NAME = "DisasterZoneMainFrame"
local NAV_H = 28                          -- the navigation strip, along the foot of the header
local HEAD_H = 60                         -- the header (UI:CreateWindow's, made tall): the seal, the guild's line, the strip
-- (every page keeps the space it had under the old 26 px title bar + the strip: 790 x 548)
local WIDTH, HEIGHT = 800, 580 + HEAD_H + 1 - 27
-- (the page area every page gets: the window's content frame, 5 px in from its sides and its foot (UI:CreateWindow),
-- under the header's rule: ns.Style's PAGE_W / PAGE_H / INNER_W, which the pages and UI:CreateLayout read)
ns.Style.PAGE_W, ns.Style.PAGE_H = WIDTH - 2 * 5, HEIGHT - (HEAD_H + 1) - 5
ns.Style.INNER_W = ns.Style.PAGE_W - 2 * ns.Style.PAD

-- Pages shown as an icon at the right of the strip (in the pages' order: Feedback, Changelog, Settings), and pages
-- without a tab (none at the moment).
local NAV_ICONS = {
    feedback  = { icon = 42, tip = { "Feedback", "Send a bug, an idea or a change to the developer; see what the guild "
                  .. "asked for and where it stands. Ctrl+right-click anything in DisasterZone to start from it." } },
    changelog = { icon = 25, tip = { "What's new", "The changes of every DisasterZone release." } },
    -- (the developer's only: UI/PerfUI.lua; the bar chart from art pack 6, else the gear)
    perf      = { icon = ns:HasAssets(6) and 58 or 13, tip = { "Performance", "What DisasterZone costs this client: "
                  .. "memory, garbage, CPU and who makes it. Only you see this page." } },
    settings  = { icon = 13, tip = { "Settings" } },
}
-- Text tabs with a small pill after their label (UI:CreateNavStrip's badge): pages still being tried out.
local NAV_BADGES = {
    events = { text = "BETA", color = { 0.73, 0.55, 1 }, kind = "os",
               tip = { "Events (beta)", "New and still being tested: pages and pieces may change from one version "
                   .. "to the next, and a few things may not work yet." } },
}
-- Pages without a place in the strip: Notifications opens from the bell's tray (UI/Notify.lua).
local NAV_HIDDEN = { notify = true }

-- Pages grouped under one text tab that opens a menu of them (the strip stays the same for every rank). A tab
-- sits at its own order among the pages'; resting the mouse on it opens the menu, clicking it shows the page used
-- last in it (settings.navLast). Groups follow shared data: raid nights and their loot, items, the guild's people and pastimes.
local NAV_GROUPS = {
    { key = "grp:raids", label = "Raids", order = 0.8,  pages = { "raids", "council", "lootrules", "mylog" } },
    { key = "grp:gear",  label = "Gear",  order = 1,    pages = { "mybis", "gearsim", "consumables", "wardrobe", "atlas" } },
    { key = "grp:guild", label = "Guild", order = 3.58, pages = { "members", "map", "events", "polls", "recruit", "games" } },
}
-- A line under each page in a group's menu (its tooltip).
local NAV_PAGE_TIPS = {
    raids   = "Raid nights, teams, strategies, guests and the raid log.",
    council = "Loot decisions: the roster, items, the loot log and the council.",
    lootrules = "How the loot council's suggestion is made, and the prized items. For everyone.",
    mylog   = "Your own boss pulls, run against run. Only you can see it.",
    mybis   = "Your BiS lists and what you still need.",
    gearsim = "Try gear before you have it: simulated fights.",
    consumables = "The flask, food and potions for your spec.",
    wardrobe = "Your outfits: one click (or a rule) swaps your gear.",
    atlas   = "Every raid and dungeon's drops, sets and costs.",
    members = "The guild's members, professions and recipes.",
    map     = "Where guildmates are right now.",
    events  = "Guild events and cups (beta).",
    polls   = "Questions from the officers: answer and see results.",
    recruit = "The people you talk to about joining, and the team each one fits.",
    games   = "Bingo and the other games to play with the guild.",
}
-- Class tools with a window of their own (their planners): a minimap pin for the classes they are for
-- (ClassKit:IsMine; demo mode: every class). Not in the nav menus (the user, 2026-10-11). A pin opens the window.
local NAV_TOOLS = {
    { key = "blessings", kit = "bless", label = "Blessings",
      tip = "Pally Power: which paladin blesses which class, and the auras.",
      open = function() if ns.BlessingsUI then ns.BlessingsUI:Open() end end },
    { key = "totems", kit = "totems", label = "Totems",
      tip = "ShamanPower: each shaman's totems, Heroism and Earth Shield.",
      open = function() if ns.TotemsUI then ns.TotemsUI:Open() end end },
    -- (not a planner: Edit layout, for everyone)
    { key = "editlayout", always = true, label = "Edit layout",
      tip = "Move, line up and mirror every frame on your screen.",
      open = function() if ns.EditMode then ns.EditMode:Toggle() end end },
    { key = "keybinds", always = true, label = "Key binds",
      tip = "Point at any action button and press a key.",
      open = function() if ns.KeyBinds then ns.KeyBinds:Toggle() end end },
}
local TOOL = {}
for _, t in ipairs(NAV_TOOLS) do TOOL[t.key] = t end

local function ToolAvailable(t)
    if t ~= nil and t.always then return true end
    return t ~= nil and ns.ClassKit ~= nil and ns.ClassKit:IsMine(t.kit) and true or false
end

local GROUP_OF = {}       -- page key -> group
for _, g in ipairs(NAV_GROUPS) do
    for _, key in ipairs(g.pages) do GROUP_OF[key] = g end
end

-- Pages that became a view of another tab: their old key opens that view (a saved "tab used last", callers that
-- still say the old key). Returns true when it handled the open.
local MOVED = {
    loot = function() return ns.CouncilUI and ns.CouncilUI.ShowLog and (ns.CouncilUI:ShowLog() or true) end,
}

local tabDefs = {}      -- key -> { key, label, order, createFn, isAvailableFn, panel }
local tabList = {}      -- defs sorted by order
local frame, tabs, status, shareBtn, bellBtn, kicker
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

-- The strip's key for a page: its group's, or its own.
local function NavKey(pageKey)
    local g = GROUP_OF[pageKey]
    return g and g.key or pageKey
end

-- The page a group's tab opens: the one used last in it while still there, else its first available page.
local function GroupPage(g)
    local settings = ns.db and ns.db.settings
    local last = settings and type(settings.navLast) == "table" and settings.navLast[g.key]
    if last and tabDefs[last] and IsAvailable(tabDefs[last]) then return last end
    for _, key in ipairs(g.pages) do
        if tabDefs[key] and IsAvailable(tabDefs[key]) then return key end
    end
end

-- Shows a page and lights its tab (its group's tab for a grouped page).
local function SelectPage(key)
    if not tabs then return end
    local nav = NavKey(key)
    tabs.selected = nav
    for k, tab in pairs(tabs.byKey) do tab:SetActive(k == nav) end
    ShowPanel(key)
end

-- A group's menu: the spotlight of its pages (UI/NavMenu.lua): the list on the left, the page under the mouse big on
-- the right with its live facts and jumps into its views; a click opens the page (and the view).
local function GroupMenu(g, owner)
    local pages = {}
    for _, key in ipairs(g.pages) do
        local def = tabDefs[key]
        if def and IsAvailable(def) then
            -- (what waits for me on the page: its count, the notification center's; else the strip's pill)
            local n = ns.Notify and ns.Notify:IsLoaded() and ns.Notify:Count({ page = key }) or 0
            pages[#pages + 1] = { key = key, label = def.label, line = NAV_PAGE_TIPS[key] or "",
                                  count = n > 0 and n or nil, badge = n <= 0 and NAV_BADGES[key] or nil }
        end
    end
    local current = GROUP_OF[currentKey] == g and currentKey or nil
    return ns.NavMenu:Open(owner, { pages = pages, current = current, focus = current or GroupPage(g),
        onPick = function(key, view)
            SelectPage(key)
            ns.NavMenu:OpenView(key, view)
        end })
end

local groupByKey = {}
for _, g in ipairs(NAV_GROUPS) do groupByKey[g.key] = g end

-- A group's menu opens on hover (a short rest on the tab) and closes once the mouse has left both the tab and the
-- menu for a moment; a click goes to the group's page used last and closes the menu (it opens again on the next
-- rest on a tab).
local HOVER_OPEN, HOVER_CLOSE = 0.15, 0.35
local hoverSeq = 0
local watch = CreateFrame("Frame")
watch:Hide()

watch:SetScript("OnUpdate", function(self, elapsed)
    local NM = ns.NavMenu
    if not (self.owner and NM:IsOpenFor(self.owner)) then
        self:Hide()
        return
    end
    if self.owner:IsMouseOver() or NM:IsMouseOver() then
        self.away = 0
    else
        self.away = self.away + (elapsed or 0)
        if self.away >= HOVER_CLOSE then
            NM:Close()
            self:Hide()
        end
    end
end)

-- Opens g's menu under owner (not when it is open already).
local function OpenGroupMenu(g, owner)
    if not owner or ns.NavMenu:IsOpenFor(owner) then return end
    GroupMenu(g, owner)
    if ns.NavMenu:IsOpenFor(owner) then
        watch.owner, watch.away = owner, 0
        watch:Show()
    end
end

local function OnNavSelect(navKey)
    local g = groupByKey[navKey]
    if not g then
        ShowPanel(navKey)
        return
    end
    local page = GroupPage(g)
    -- (the click is the choice: the menu closes, and a rest still pending on the tab doesn't open it after all)
    hoverSeq = hoverSeq + 1
    ns.NavMenu:Close()
    if page then SelectPage(page) end
end

local function HookGroupHover()
    for _, g in ipairs(NAV_GROUPS) do
        local tab = tabs.byKey[g.key]
        if tab then
            tab:HookScript("OnEnter", function(self)
                hoverSeq = hoverSeq + 1
                local seq = hoverSeq
                C_Timer.After(HOVER_OPEN, function()
                    if seq == hoverSeq and self:IsVisible() and self:IsMouseOver() then OpenGroupMenu(g, self) end
                end)
            end)
            tab:HookScript("OnLeave", function() hoverSeq = hoverSeq + 1 end)
        end
    end
end

local function BuildTabs()
    if not frame then return end
    if tabs then tabs.frame:Hide() end
    local defs, placed = {}, {}
    for _, def in ipairs(tabList) do
        local g = GROUP_OF[def.key]
        if g then
            if not placed[g.key] then
                placed[g.key] = true
                defs[#defs + 1] = { key = g.key, label = g.label, menu = true, order = g.order }
            end
        elseif not NAV_HIDDEN[def.key] then
            local icon = NAV_ICONS[def.key]
            defs[#defs + 1] = { key = def.key, label = def.label, icon = icon and icon.icon, tip = icon and icon.tip,
                badge = NAV_BADGES[def.key], order = def.order }
        end
    end
    for i, d in ipairs(defs) do d.seq = i end
    table.sort(defs, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.seq < b.seq
    end)
    tabs = ns.UI:CreateNavStrip(frame, defs, OnNavSelect)
    HookGroupHover()
    -- along the header's foot, right of the seal; the window's gold rule under it instead of the strip's own
    tabs.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 64, -(HEAD_H - NAV_H))
    tabs.frame:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -(HEAD_H - NAV_H))
    if tabs.rule then tabs.rule:Hide() end
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
    -- the notification bell, left of the sync mark (UI/Notify.lua); its counts on the tabs
    if bellBtn then
        bellBtn:ClearAllPoints()
        bellBtn:SetPoint("RIGHT", status or right, "LEFT", status and -6 or -4, 0)
    end
    if ns.NotifyUI and ns.NotifyUI.OnTabsBuilt then ns.NotifyUI:OnTabsBuilt() end
end

-- opts (optional): { layout = "board" | "listdetail" | "detail" | "rail" | "tool" } - the page's layout kind (UI/Comp/
-- Layouts.lua), kept on the tab (MainFrame:GetTabLayout); a page without one works as before.
function MainFrame:RegisterTab(key, label, order, createFn, isAvailableFn, opts)
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
    def.opts = type(opts) == "table" and opts or nil
    def.layout = def.opts and def.opts.layout or nil
    SortTabs()
    if frame then
        BuildTabs()
        self:RefreshTabs()
        if currentKey and tabs then SelectPage(currentKey) end
    end
end

-- The layout kind a tab registered with (opts.layout), or nil.
function MainFrame:GetTabLayout(key)
    local def = tabDefs[key]
    return def and def.layout or nil
end

---------------------------------------------------------------------------
-- Title & status
---------------------------------------------------------------------------

-- The header's line: the guild in capitals, then who is online and the next raid ("CASUAL DISASTER  · 9 online ·
-- next raid in 13 min"). The window title (hidden here, read by Feedback) keeps "DisasterZone - <guild>".
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
    if not kicker then return end
    local facts = {}
    if IsInGuild() and GetNumGuildMembers then
        local _, online = GetNumGuildMembers()
        if (tonumber(online) or 0) > 0 then facts[#facts + 1] = online .. " online" end
    end
    local v = ns.UI:NextRaid()
    local D = ns.Dashboard
    if v and v.t and D and D.Countdown then
        facts[#facts + 1] = (v.t > GetServerTime() and "next raid " or "raid ") .. D:Countdown(v.t)
    end
    local line = (guild and guild ~= "") and guild:upper() or "DISASTERZONE"
    if #facts > 0 then line = line .. "  " .. S:Wrap("SUB", "\194\183 " .. table.concat(facts, " \194\183 ")) end
    kicker:SetText(line)
end

-- The sync status at the right of the strip: a mark with the full text in its tooltip; words only when something
-- needs a look (not shared, demo mode). The mark: arrows turning while the list is being shared, coming to rest and
-- giving way to a check that draws itself as it turns from the sync colour to green once it is shared; the arrows at
-- rest in orange when nobody can receive it.
local MARK_TEX = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\"
local MARK = 16
local C_SYNC, C_OK, C_WARN = S.C.YOU, S.C.OK, S.C.WARN
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
    if demo then words[#words + 1] = S:Wrap("WARN", "Demo mode") end
    if kind == "warn" then words[#words + 1] = S:Wrap("WARN", "Not shared yet") end
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
    s.text = ns.UI:Text(s, "small", "TEXT", { justify = "RIGHT" })
    s.text:SetPoint("RIGHT", s.mark, "LEFT", -8, 0)
    ns.UI:AttachTooltip(s, function(self, tt)
        UpdateStatus()   -- "1m ago" stays current
        tt:AddLine("Your BiS lists", S:RGB("GOLD"))
        if self.tip and self.tip ~= "" then tt:AddLine(self.tip, 1, 1, 1, true) end
        if ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() then
            local r, g, b = S:Color("WARN")
            tt:AddLine("Demo mode: made-up members, lists and a raid to try the council views; never saved.", r, g, b, true)
        end
    end, nil, { anchor = "ANCHOR_BOTTOMLEFT" })
    return s
end

---------------------------------------------------------------------------
-- Panels
---------------------------------------------------------------------------

-- Page timings (/dz perf): ms to build each page the first time, and its last / slowest show (OnPanelShown).
local timings = {}      -- key -> { build, show, maxShow, shows }
local clock = debugprofilestop or function() return 0 end

local function Timing(key)
    local t = timings[key]
    if not t then t = { shows = 0, show = 0, maxShow = 0 } timings[key] = t end
    return t
end

-- Builds a page's panel (hidden while it is not the current page).
local function BuildPanel(def)
    if def.panel or not def.createFn or not frame then return def.panel end
    local t0 = clock()
    local content = frame.content
    local ok, panel = xpcall(function() return def.createFn(content) end, geterrorhandler())
    if ok and panel then
        def.panel = panel
        panel:ClearAllPoints()
        panel:SetAllPoints(frame.content)
        -- (pages can share a panel, e.g. My BiS / Gear sim / Consumables: never hide the one on show)
        local cur = currentKey and tabDefs[currentKey]
        if def.key ~= currentKey and not (cur and cur.panel == panel) then panel:Hide() end
    end
    Timing(def.key).build = clock() - t0
    return def.panel
end

-- The page comes in over a few frames (alpha 0 -> 1), so the swap never pops.
local FADE_IN = 0.12
local function FadeIn(panel)
    panel:SetAlpha(0)
    local fader = panel.dzFader
    if not fader then
        fader = CreateFrame("Frame", nil, panel)
        panel.dzFader = fader
    end
    fader.t = 0
    fader:SetScript("OnUpdate", function(self, elapsed)
        self.t = self.t + (elapsed or 0)
        local p = clamp01(self.t / FADE_IN)
        panel:SetAlpha(easeOut(p))
        if p >= 1 then self:SetScript("OnUpdate", nil) end
    end)
end

ShowPanel = function(key)
    local def = tabDefs[key]
    if not def or not frame then return end
    local switching = currentKey ~= key
    currentKey = key
    if switching then ns:Trail("page " .. key) end
    local g = GROUP_OF[key]
    local settings = ns.db and ns.db.settings
    if g and settings then
        if type(settings.navLast) ~= "table" then settings.navLast = {} end
        settings.navLast[g.key] = key
    end
    local panel = BuildPanel(def)
    for k, other in pairs(tabDefs) do
        if k ~= key and other.panel and other.panel ~= panel then other.panel:Hide() end
    end
    if panel then
        if switching and frame:IsShown() then FadeIn(panel) else panel:SetAlpha(1) end
        local t0 = clock()
        panel:Show()
        -- (the page's key: a panel shared by several pages shows the one asked for)
        if panel.OnPanelShown then
            xpcall(function() panel:OnPanelShown(key) end, geterrorhandler())
        end
        local t, ms = Timing(key), clock() - t0
        t.show, t.shows = ms, t.shows + 1
        if ms > t.maxShow then t.maxShow = ms end
    end
end

-- After the window first opens, the other pages are built in the background, one per frame (never in combat), so
-- a first visit to a page is a plain show. MainFrame.prebuild = false leaves each page to its first visit (the test
-- harness: building every page was most of a UI test's time; tests/boot-ui/test_broad.py keeps it on).
local prebuilding

-- The heavier pages are also painted once in the background (shown and hidden again in the same frame, so nothing is
-- drawn): their rows exist and their data is read before the first visit.
-- Item data is read from the cache only while one is warmed (ItemDB:SetQuiet): nothing is asked of the server for a
-- page nobody is looking at (the Atlas asked for ~180 items of a raid).
local WARM = { raids = true, members = true, home = true, atlas = true }
local function WarmPanel(def)
    local panel = def.panel
    if not (panel and WARM[def.key] and frame:IsShown() and def.key ~= currentKey and not panel:IsShown()) then return end
    local ItemDB = ns.ItemDB
    if ItemDB and ItemDB.SetQuiet then ItemDB:SetQuiet(true) end
    panel:Show()
    if panel.OnPanelShown then xpcall(function() panel:OnPanelShown(def.key) end, geterrorhandler()) end
    if ItemDB and ItemDB.SetQuiet then ItemDB:SetQuiet(false) end
    if def.key ~= currentKey then panel:Hide() end
end

local function PrebuildPages()
    if prebuilding or MainFrame.prebuild == false then return end
    prebuilding = true
    local queue = {}
    for _, def in ipairs(tabList) do
        if not def.panel and def.createFn then queue[#queue + 1] = def end
    end
    local i = 0
    local function step()
        if InCombatLockdown and InCombatLockdown() then
            C_Timer.After(2, step)
            return
        end
        i = i + 1
        local def = queue[i]
        if not def then return end
        if not def.panel and IsAvailable(def) then
            BuildPanel(def)
            WarmPanel(def)
        end
        C_Timer.After(0.05, step)
    end
    C_Timer.After(0.3, step)
end

-- Every registered page as the Performance page (UI/PerfUI.lua) lists it: { key, label, panel (nil until built),
-- build (ms), show (ms, the last), maxShow, shows }. A fresh table each call.
function MainFrame:GetPageStats()
    local out = {}
    for _, def in ipairs(tabList) do
        local t = timings[def.key] or {}
        out[#out + 1] = { key = def.key, label = def.label, panel = def.panel, build = t.build, show = t.show,
                          maxShow = t.maxShow, shows = t.shows or 0 }
    end
    return out
end

function MainFrame:PrintTimings()
    local keys = {}
    for k in pairs(timings) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        return (timings[a].build or 0) + timings[a].maxShow > (timings[b].build or 0) + timings[b].maxShow
    end)
    ns:Print("Page timings (ms): build / last show / slowest show (shows)")
    for _, k in ipairs(keys) do
        local t = timings[k]
        ns:Print(string.format("  %-10s %6s / %5.1f / %5.1f  (%d)", k,
            t.build and string.format("%.1f", t.build) or "-", t.show, t.maxShow, t.shows))
    end
end

local function EnsureFrame()
    if frame then return frame end
    local UI = ns.UI
    frame = UI:CreateWindow(FRAME_NAME, "DisasterZone", WIDTH, HEIGHT)
    frame:Hide()
    -- the tall header: the seal big with a soft gold halo, the guild's line beside it, the strip along its foot
    -- (BuildTabs); the pages start under its gold rule
    UI:SetWindowHeadHeight(frame, HEAD_H)
    frame.titleText:Hide()
    frame.seal:SetSize(46, 46)
    frame.seal:ClearAllPoints()
    frame.seal:SetPoint("TOPLEFT", frame, "TOPLEFT", 11, -7)
    local RADIAL = "Interface\\AddOns\\DisasterZone\\Media\\MyBiS\\Radial"
    local halo = frame:CreateTexture(nil, "BORDER")
    halo:SetTexture(RADIAL)
    halo:SetVertexColor(S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 0.2)
    halo:SetSize(84, 84)
    halo:SetPoint("CENTER", frame.seal)
    local under = frame:CreateTexture(nil, "BORDER", nil, 1)
    under:SetTexture(RADIAL)
    under:SetVertexColor(0, 0, 0, 0.75)
    under:SetSize(60, 60)
    under:SetPoint("CENTER", frame.seal, "CENTER", 0, -2)
    kicker = UI:Text(frame, "small", "GOLD")
    kicker:SetPoint("TOPLEFT", frame, "TOPLEFT", 70, -11)
    kicker:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -34, -11)
    frame.content:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -(HEAD_H + 1))
    -- (the countdown in the line moves on while the window is open)
    local since = 0
    frame:HookScript("OnUpdate", function(_, elapsed)
        since = since + (elapsed or 0)
        if since >= 30 then
            since = 0
            UpdateTitle()
        end
    end)

    status = CreateStatus()
    -- a link in chat to what the page shows (the raid, the member, ... picked on it; UI/Share.lua)
    if ns.Share and ns.Share.CreateNavButton then
        shareBtn = ns.Share:CreateNavButton(frame, function() return ns.Share:CurrentRef() end)
    end
    if ns.NotifyUI and ns.NotifyUI.CreateBell then bellBtn = ns.NotifyUI:CreateBell(frame) end

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

-- The Share icon of the navigation strip (it shares what the window shows, e.g. the raid whose page is open).
function MainFrame:GetShareButton() return shareBtn end

-- The strip's tabs by key (a group's tab under its "grp:" key), and the pages a strip key stands for.
function MainFrame:GetNavTabs() return tabs and tabs.byKey or {} end
function MainFrame:GetNavPages(navKey)
    local g = groupByKey[navKey]
    return g and g.pages or { navKey }
end

function MainFrame:IsShown()
    return frame ~= nil and frame:IsShown()
end

function MainFrame:RefreshTabs()
    if not frame or not tabs then return end
    -- a group's tab shows while any of its pages does
    local shown = {}
    for _, def in ipairs(tabList) do
        local nav = NavKey(def.key)
        shown[nav] = shown[nav] or IsAvailable(def)
    end
    for nav, on in pairs(shown) do tabs:SetTabShown(nav, on) end
    if currentKey and not IsAvailable(tabDefs[currentKey]) and frame:IsShown() then
        local fallback = FirstAvailableKey()
        if fallback then SelectPage(fallback) end
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

-- Opens a group tab's menu as resting the mouse on it does (navKey "grp:raids" ...): tests and the audit's views.
function MainFrame:OpenGroupMenu(navKey)
    local g = groupByKey[navKey]
    if g and tabs then OpenGroupMenu(g, tabs.byKey[navKey]) end
end

function MainFrame:Open(key)
    -- a planner (a minimap pin): its own window
    if TOOL[key] then
        if ToolAvailable(TOOL[key]) then TOOL[key].open() end
        return
    end
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
        SelectPage(key)
    end
    PrebuildPages()
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

-- The pages the window offers now (a tab of their own or a line in a group's menu), in the pages' order.
function MainFrame:GetShownPages()
    local out = {}
    for _, def in ipairs(tabList) do
        if not NAV_HIDDEN[def.key] and IsAvailable(def) then out[#out + 1] = def.key end
    end
    return out
end

-- A page's tab label (nil for an unknown key), and whether the window offers it now.
function MainFrame:GetPageLabel(key)
    if TOOL[key] then return TOOL[key].label end
    return tabDefs[key] and tabDefs[key].label or nil
end

-- The planners my class has (keys, for the minimap's pins): { key, ... }.
function MainFrame:GetShownTools()
    local out = {}
    for _, t in ipairs(NAV_TOOLS) do
        if ToolAvailable(t) then out[#out + 1] = t.key end
    end
    return out
end

-- A page's one-line description (its line in a group's menu), nil for a page without one.
function MainFrame:GetPageTip(key)
    if TOOL[key] then return TOOL[key].tip end
    return NAV_PAGE_TIPS[key]
end

function MainFrame:IsPageShown(key)
    if TOOL[key] then return ToolAvailable(TOOL[key]) end
    return tabDefs[key] ~= nil and not NAV_HIDDEN[key] and IsAvailable(tabDefs[key])
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
        tt:AddLine("Loot Council member", S:RGB("GOLD"))
    elseif IsInGuild() then
        tt:AddLine("Raider", S:RGB("TEXT"))
    else
        tt:AddLine("Not in a guild", S:RGB("SUB"))
    end
    local status = ns.Sync and ns.Sync.GetStatusText and ns.Sync:GetStatusText()
    if status and status ~= "" then
        tt:AddLine(ns.UI:SafeText(status), 1, 1, 1, true)
    end
    if ns.NotifyUI and ns.NotifyUI.AddTooltipLines then ns.NotifyUI:AddTooltipLines(tt) end
    tt:AddLine(" ")
    tt:AddLine("Left-click: your pinned sections  ·  Right-click: open", S:RGB("SUB"))
    tt:AddLine("Shift-click: boss drops", S:RGB("SUB"))
end

local function SetupLauncher()
    if not LibStub then return end
    local ldb = LibStub("LibDataBroker-1.1", true)
    if not ldb then return end
    local obj = ldb:GetDataObjectByName("DisasterZone") or ldb:NewDataObject("DisasterZone", {
        type = "launcher",
        label = "DisasterZone",
        text = "DisasterZone",
        icon = ns:HasAssets(4) and "Interface\\AddOns\\DisasterZone\\Media\\Launcher\\seal_mm"
            or "Interface\\Icons\\INV_Misc_Bag_10_Blue",
        OnClick = function(btn, button)
            if IsShiftKeyDown() and ns.DropPanel and ns.DropPanel.ShowHistory then
                ns.DropPanel:ShowHistory()   -- the drop panel (one Escape closes it with the loot window)
            elseif button == "RightButton" or not ns.MinimapArc then
                if ns.MinimapArc then ns.MinimapArc:Close(true) end
                MainFrame:Toggle()
            else
                ns.MinimapArc:Toggle(btn)    -- the pinned sections fan out around the button
            end
        end,
        OnTooltipShow = function(tt)
            if ns.MinimapArc and ns.MinimapArc:IsOpen() then return end   -- the arc's own labels say enough
            LauncherTooltip(tt)
        end,
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
ns:RegisterSlash("perf", function() MainFrame:PrintTimings() end, "page build / show times")
