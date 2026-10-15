if DisasterZoneBoot and DisasterZoneBoot.Run("UI/DungeonsTab.lua", ...) then return end -- DisasterZone: the "Dungeons" tab (everyone).
-- The guild's 5-man runs (Core/DungeonRuns.lua) as cards: the dungeon's loading-screen art, the leader and when, at
-- most one hint (what stops me, else what drops my BiS) and the five places of the party; the empty place that wants
-- one of my roles glows. Join asks the leader. My own run sits on top with the players asking to join and the
-- members up for a run who fit. "List a run" opens a sheet: the dungeons by complex, when, a note, my role and a
-- preview that is exactly the card the guild will see. A small pop-up pings me when a run needs me while I'm up for
-- one, and the leader when somebody asks to join; a run's party invite is a pop-up too. The eye on my run lists it
-- in Blizzard's Group Finder (it looks around while listed) and the players from outside the guild show up under it.
-- 1.4: a Board page (UI:CreateLayout): the toolbar holds "I'm up for a run" (the shared switch, the roles as sleek
-- buttons) and the main action List a run (my own run in its place: a quiet line); the runs are shared cards
-- (UI:CreateCard; my run wears the picked look) under section headers, the members up for a run are chips
-- (UI:CreateChip), the shared empty state. The List a run sheet (UI:CreateSheet, a cover) has Normal / Heroic, When and
-- my role as segments (UI:CreateSegments), the complexes as art rows (UI:CreateArtRow) with their dungeons' tiles, a
-- caps header over the preview; the pop-up is UI:Toast. Shared role icons, pills, text styles, ns.Style colours.
local addonName, ns = ...

local DungeonsUI = ns:NewModule("DungeonsUI")
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local PAD = S.PAD
local KIND_TABS   -- (the board's tabs, set with the page below)
local STRIP_H = 30               -- the members up for a run
local CARD_H = 72
local ART_W = 180
local TEXT_X = ART_W + 4
local SLOT, SLOT_GAP = 30, 5
local ACT_W = 92
local GAP = 6
local SECTION_H = 26
local TOAST_KEY = "dz-dungeon-run"   -- the run pop-up's UI:Toast key (one at a time)
local REQ_H = 30
local ROW_H, ROW_GAP = S.ROW.art, 6   -- the sheet's complex rows (UI:CreateArtRow)
local TILE_W, TILE_H, TILE_GAP = 130, 34, 5
local TOAST_W, TOAST_H, TOAST_ART = 440, 76, 112
local TOAST_FOR = 25

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local HEROIC_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-HEROIC"
local STAR_TEX = "Interface\\AddOns\\DisasterZone\\Media\\Icons\\bis"
local NO_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local STAR = "|T" .. STAR_TEX .. ":11:11:0:0|t"
local ROLE_NAME = { tank = "tank", healer = "healer", dps = "DPS" }

local GOLD = S.C.GOLD
-- (1.5) a raid group's loot, in words
local LOOT_WORDS = { roll = "everyone rolls", sr = "soft reserves", lc = "the loot council" }
local SHEET_BG = { 0.035, 0.035, 0.043, 1 }       -- the List a run sheet: a cover over the page (opaque: nothing under it shows)

local panel, toast
local state = ns.GroupsCard.state   -- (shared with the cards: the focus, the members I invited; the sheet)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function R() return ns.DungeonRuns end
local function UI() return ns.UI end
local function Me() return ns.Util.PlayerKey() end
-- The run pop-up on screen (UI:Toast under TOAST_KEY), or nil.
local function RunToast() return UI():GetToast(TOAST_KEY) end

-- The run pop-up's opts, on screen or still waiting in the shared queue (its dzMode / dzRun), or nil.
local function RunToastOpts()
    local t = RunToast()
    if t and t.opts then return t.opts end
    for _, o in ipairs(UI():ToastQueue()) do
        if o.key == TOAST_KEY then return o end
    end
    return nil
end


local G = ns.GroupsCard
local WhenText, DayLabel, DungeonName, ItemLinkText, HideTip = G.WhenText, G.DayLabel, G.DungeonName, G.ItemLinkText, G.HideTip
local RedrawHoveredTip, HintFor, CardTip = G.RedrawHoveredTip, G.HintFor, G.CardTip
local NewRunCard, FillCard, NewPersonChip, FillChip, Disc = G.NewRunCard, G.FillCard, G.NewPersonChip, G.FillChip, G.Disc

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

-- The board's tabs: every group, or one kind (and the kinds' names on the "I'm up for" chips).
KIND_TABS = { { "all", "All" }, { "dungeon", "Dungeons" }, { "raid", "Raids" }, { "quest", "Quests" }, { "pvp", "PvP" } }
local EMPTY_TITLE = { all = "No groups listed right now.", dungeon = "No dungeon runs listed right now.",
                      raid = "No raid groups listed right now.", quest = "No quest groups listed right now.",
                      pvp = "No PvP groups listed right now." }

-- The tabs row: All / Dungeons / Raids / Quests / PvP, each with how many groups it holds.
local TABS_H = 30
local function CreateTabs(p)
    local row = CreateFrame("Frame", nil, p.layout.body)
    row:SetHeight(TABS_H)
    row.tabs = {}
    local x = 0
    for _, t in ipairs(KIND_TABS) do
        local key = t[1]
        local b = UI():CreateUnderlineTab(row, t[2], function()
            state.tab = key
            state.open = nil
            DungeonsUI:Refresh()
        end, "small")
        b.key, b.label = key, t[2]
        b:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", x, 0)
        x = x + b:GetWidth() + 14
        row.tabs[#row.tabs + 1] = b
    end
    row.rule = UI():Rule(row, { bottom = 0 })
    p.tabsRow = row
end

local function UpdateTabs(p)
    local row = p.tabsRow
    local x = 0
    for _, b in ipairs(row.tabs) do
        local n = #R():GetGroups(b.key ~= "all" and b.key or nil)
        b:SetLabel(b.label .. "  " .. S:Wrap("SUB", tostring(n)))
        b:SetActive((state.tab or "all") == b.key)
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", x, 0)
        x = x + b:GetWidth() + 14
    end
end

-- A role I'm up for (the toolbar's tank / healer / DPS): the sleek button, "chosen" while on, its role icon greyed
-- while off.
local function NewRoleChip(parent, role, onClick)
    local b = UI():CreateSleekButton(parent, "", 24, 24, function(self) onClick(self) end)
    b.icon = b:CreateTexture(nil, "ARTWORK", nil, 2)
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("CENTER")
    UI():SetRoleIcon(b.icon, role)
    b.role = role
    function b:SetOn(on)
        self.on = on and true or false
        self:SetKind(self.on and "chosen" or "secondary")
        self.icon:SetDesaturated(not self.on)
        self.icon:SetAlpha(self.on and 1 or 0.3)
    end
    UI():AttachTooltip(b, R().ROLE_LABEL[role], function(self)
        return { self.tipText or (self.on and "You're up for this role. Click to drop it." or "Click to add this role.") }
    end, { anchor = "ANCHOR_TOP" })
    b:SetOn(false)
    return b
end

local function UpTip(owner)
    local untilT = R():GetUpUntil()
    local lines = { "I'm up for a run" }
    if untilT then
        local left = max(1, floor((untilT - ns.Util.Now()) / 60))
        lines[#lines + 1] = "The guild sees you're free for another " .. (left >= 60 and (floor(left / 60) .. " h "
            .. (left % 60) .. " min") or (left .. " min")) .. ", and you get a ping when a run needs one of your roles."
        lines[#lines + 1] = S:Wrap("SUB", "It switches off in a full party or a dungeon.")
    else
        lines[#lines + 1] = "Switch it on to show the guild you're free for 2 hours, with the roles beside it. You get "
            .. "a ping when a run needs one of them."
    end
    UI():SetTextTooltip(owner, lines, "ANCHOR_BOTTOMLEFT")
end

-- "I'm up for a run" (the switch, its words, my roles) on the toolbar's left; List a run is its main action.
local function CreateTop(p)
    local bar = p.layout.toolbar
    local top = CreateFrame("Frame", nil, bar)
    top:SetPoint("LEFT", bar, "TOPLEFT", PAD, -UI().LAYOUT.ROW_MID)
    top:SetPoint("RIGHT", bar, "TOPRIGHT", -PAD - 130, -UI().LAYOUT.ROW_MID)
    top:SetHeight(30)
    p.top = top
    -- (the shared on / off switch: a click asks, s:SetOn(on) shows the answer)
    top.switch = UI():CreateSwitch(top, nil, function() R():SetUp(not R():IsUp()) end)
    top.switch:SetPoint("LEFT", 0, 0)
    top.switch:HookScript("OnEnter", UpTip)
    top.switch:HookScript("OnLeave", HideTip)
    top.label = CreateFrame("Button", nil, top)
    top.label.text = UI():Text(top.label, "title", "TEXT")
    top.label.text:SetPoint("LEFT")
    top.label.text:SetText("I'm up for")
    top.label:SetSize((top.label.text:GetStringWidth() or 100) + 4, 20)
    top.label:SetPoint("LEFT", top.switch, "RIGHT", 9, 0)
    top.label:SetScript("OnClick", function() R():SetUp(not R():IsUp()) end)
    top.label:SetScript("OnEnter", UpTip)
    top.label:SetScript("OnLeave", HideTip)
    -- (1.5) the kinds of groups I'm up for, then "as" and my roles
    top.kinds = {}
    for _, kind in ipairs(KIND_TABS) do
        if kind[1] ~= "all" then
            local key = kind[1]
            local chip = UI():CreateChip(top, { kind = "track", onClick = function(self)
                R():SetMyKind(key, not self.on)
            end })
            chip.kindKey = key
            UI():AttachTooltip(chip, kind[2], function(self)
                return { self.on and "You get a ping for these groups while you're up for a run. Click to stop."
                    or "Click to get a ping for these groups too." }
            end, { anchor = "ANCHOR_TOP" })
            top.kinds[#top.kinds + 1] = chip
        end
    end
    top.as = UI():Text(top, "body", "SUB")
    top.as:SetText("as")
    top.roles = {}
    for _, role in ipairs(R().ROLES) do
        top.roles[role] = NewRoleChip(top, role, function(self) R():SetMyRole(role, not self.on) end)
    end
    top.list = bar:SetPrimary({ text = "List a group", width = 120, onClick = function() DungeonsUI:OpenSheet() end })
end

local function UpdateTop(p)
    local top = p.top
    top.switch:SetOn(R():IsUp())
    top.label.text:SetTextColor(S:Color(R():IsUp() and "TEXT" or "SUB"))
    local mine = R():GetMyRoles()
    local x = top.label:GetWidth() + 9 + 34 + 10
    local kinds = R():GetMyKinds()
    for i, chip in ipairs(top.kinds) do
        chip.on = kinds[chip.kindKey] and true or false
        chip:Set(KIND_TABS[i + 1][2], chip.on and GOLD or nil)
        chip:SetSelected(chip.on)
        chip:ClearAllPoints()
        chip:SetPoint("LEFT", top, "LEFT", x, 0)
        x = x + chip:GetWidth() + 5
    end
    top.as:ClearAllPoints()
    top.as:SetPoint("LEFT", top, "LEFT", x + 4, 0)
    x = x + (top.as:GetStringWidth() or 12) + 12
    for _, role in ipairs(R().ROLES) do top.roles[role]:Hide() end
    for _, role in ipairs(R():GetPlayableRoles()) do
        local b = top.roles[role]
        b:SetOn(mine[role])
        b:ClearAllPoints()
        b:SetPoint("LEFT", top, "LEFT", x, 0)
        b:Show()
        x = x + 28
    end
end

local function UpdateStrip(p, width)
    local strip = p.strip
    local list = R():GetUpForRun()
    strip.chips = strip.chips or {}
    local x = (strip.label:GetStringWidth() or 70) + 10
    local shown = 0
    for i, e in ipairs(list) do
        local chip = strip.chips[i]
        if not chip then
            chip = NewPersonChip(strip, function(self)
                local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
                if self.key and open then open("/w " .. ((Ambiguate and Ambiguate(self.key, "none")) or self.key) .. " ") end
            end)
            strip.chips[i] = chip
        end
        FillChip(chip, e)
        local w = chip:GetWidth()
        if x + w <= width - 40 then
            chip:ClearAllPoints()
            chip:SetPoint("LEFT", strip, "LEFT", x, 0)
            chip:Show()
            x = x + w + 6
            shown = shown + 1
        else
            chip:Hide()
        end
    end
    for i = #list + 1, #strip.chips do strip.chips[i]:Hide() end
    local rest = #list - shown
    strip.more:SetShown(rest > 0)
    if rest > 0 then
        strip.more.text:SetText("+" .. rest)
        strip.more:SetWidth((strip.more.text:GetStringWidth() or 20) + 8)
        strip.more:ClearAllPoints()
        strip.more:SetPoint("LEFT", strip, "LEFT", x, 0)
        local names = { "Also up for a run" }
        for i = shown + 1, #list do names[#names + 1] = UI():ColoredName(list[i].key, list[i].class) end
        strip.more.tip = names
    end
    return #list > 0
end

local function CreateStrip(p)
    local strip = CreateFrame("Frame", nil, p.layout.body)
    strip:SetHeight(STRIP_H)
    p.strip = strip
    strip.label = UI():Text(strip, "caps")
    strip.label:SetPoint("LEFT", 0, 0)
    strip.label:SetText(UI():CapsText("Up for a run"))
    strip.more = CreateFrame("Frame", nil, strip)
    strip.more:SetHeight(20)
    strip.more.text = UI():Text(strip.more, "body", "SUB")
    strip.more.text:SetPoint("LEFT", 4, 0)
    strip.more:EnableMouse(true)
    strip.more:SetScript("OnEnter", function(self) UI():SetTextTooltip(self, self.tip or {}, "ANCHOR_TOP") end)
    strip.more:SetScript("OnLeave", HideTip)
end

-- The i-th section header (UI:CreateSectionHeader: the title, the day after it in grey).
local function SectionHeader(p, i)
    p.headers[i] = p.headers[i] or UI():CreateSectionHeader(p.content, "", { style = "title" })
    return p.headers[i]
end

-- The groups to show, by section: mine, now, later (by day); in each the ones that want me first, those I can't join
-- last. (1.5) Every kind, or the tab's.
local function Sections()
    local mine, now, later = nil, {}, {}
    local tab = state.tab or "all"
    for _, run in ipairs(R():GetGroups(tab ~= "all" and tab or nil)) do
        if run.o == Me() then
            mine = run
        elseif R():IsNow(run) then
            now[#now + 1] = run
        else
            later[#later + 1] = run
        end
    end
    local function rank(run)
        if R():GetGroupBlocker(run) then return 4 end
        if R():IsInRun(run) then return 0 end
        local fits = R():FitsMe(run) ~= nil
        local bis = R():GetKind(run) == "dungeon" and #R():GetMyBiSDrops(run.d, run.h) > 0
        if fits and bis then return 1 end
        if fits then return 2 end
        return 3
    end
    tsort(now, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return (a.c or 0) > (b.c or 0)
    end)
    tsort(later, function(a, b)
        local da, db = date("%Y%m%d", a.at), date("%Y%m%d", b.at)
        if da ~= db then return da < db end
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        if a.at ~= b.at then return a.at < b.at end
        return a.id < b.id
    end)
    return mine, now, later
end

function DungeonsUI:Refresh()
    if not panel or not panel:IsVisible() then return end
    local p = panel
    if state.sheet then self:RefreshSheet() end
    if ns.GroupsLead and ns.GroupsLead:IsOpen() then ns.GroupsLead:Refresh() end
    local width = p:GetWidth()
    if not width or width < 300 then width = 780 end
    local mine, now, later = Sections()
    -- the bar and the strip are for finding a run: my own run takes their place
    p.top:SetShown(mine == nil)
    local body = p.layout.body
    local y = 0
    -- the tabs: every group, or one kind
    UpdateTabs(p)
    p.tabsRow:ClearAllPoints()
    p.tabsRow:SetPoint("TOPLEFT", body, "TOPLEFT", 0, y)
    p.tabsRow:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, y)
    y = y - TABS_H - 4
    if mine == nil then
        p.layout.toolbar:SetPrimary({ text = "List a group", width = 120, onClick = function() DungeonsUI:OpenSheet() end })
        UpdateTop(p)
        p.strip:ClearAllPoints()
        p.strip:SetPoint("TOPLEFT", body, "TOPLEFT", 0, y)
        p.strip:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, y)
        if UpdateStrip(p, width - 2 * PAD) then
            p.strip:Show()
            y = y - STRIP_H - 2
        else
            p.strip:Hide()
        end
    else
        p.layout.toolbar:SetPrimary(nil)
        p.strip:Hide()
    end
    -- (my own run takes the toolbar's place for finding one: a quiet line says what joining another does)
    p.layout.toolbar:SetText(mine and "Your run is on the board. Joining another run takes it off." or nil)
    p.scroll:ClearAllPoints()
    p.scroll:SetPoint("TOPLEFT", body, "TOPLEFT", 0, y - 2)
    p.scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -16, 2)
    local cw = width - 2 * PAD - 16
    p.content:SetWidth(cw)

    local cy, hi, ci = 0, 0, 0
    local function header(text, sub)
        hi = hi + 1
        local h = SectionHeader(p, hi)
        h:SetTitle(text)
        h:SetCount(sub)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", p.content, "TOPLEFT", 0, -cy)
        h:SetPoint("TOPRIGHT", p.content, "TOPRIGHT", 0, -cy)
        h:Show()
        cy = cy + SECTION_H + 2
    end
    local function card(run, opts)
        ci = ci + 1
        local c = p.cards[ci]
        if not c then
            c = NewRunCard(p.content)
            p.cards[ci] = c
        end
        opts.width = cw
        local h = FillCard(c, run, opts)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", p.content, "TOPLEFT", 0, -cy)
        c:Show()
        if run.id == state.focus then state.focusY = cy end
        cy = cy + h + GAP
    end
    -- "4 want you": how many groups in a section have a place for me (gold, after its title)
    local function wanting(list, day)
        local n = 0
        for _, run in ipairs(list) do
            if (day == nil or DayLabel(run.at) == day) and R():FitsMe(run) and not R():GetGroupBlocker(run) then n = n + 1 end
        end
        return n > 0 and S:Wrap("GOLD", n .. (n == 1 and " wants you" or " want you")) or nil
    end
    local function join(a, b)
        if a and b then return a .. S:Wrap("SUB", " · ") .. b end
        return a or b
    end
    if mine then
        header(R():GetKind(mine) == "dungeon" and "Your run" or "Your group")
        card(mine, { mine = true })
        cy = cy + 4
    end
    if #now > 0 then
        header("Now", wanting(now))
        for _, run in ipairs(now) do card(run, {}) end
    end
    -- later groups by day: "Later  today", then "Tomorrow", "Saturday 11 Oct", ...
    local lastDay
    for _, run in ipairs(later) do
        local day = DayLabel(run.at)
        if day ~= lastDay then
            if lastDay == nil then header("Later", join(day, wanting(later, day))) else header(day, wanting(later, day)) end
            lastDay = day
        end
        card(run, {})
    end
    for i = hi + 1, #p.headers do p.headers[i]:Hide() end
    for i = ci + 1, #p.cards do p.cards[i]:Hide() end
    p.content:SetHeight(max(cy, 1))

    -- nothing on the board
    local empty = mine == nil and #now == 0 and #later == 0
    p.empty:SetShown(empty)
    if empty then
        p.empty:ClearAllPoints()
        p.empty:SetPoint("TOP", body, "TOP", 0, y - 80)
        p.empty:SetContent({ glyph = UI().ICON.team, title = EMPTY_TITLE[state.tab or "all"] or EMPTY_TITLE.all,
            text = R():IsUp() and "You'll get a ping as soon as a run needs one of your roles."
                or "List one, or switch on \"I'm up for a run\" to get a ping when a run needs you." })
    end
end

function DungeonsUI:RequestRefresh()
    if panel and panel:IsVisible() then
        ns.Util.Debounce("dungeons-ui", 0.1, function()
            DungeonsUI:Refresh()
            RedrawHoveredTip()
        end)
    end
    -- a ping or a request goes with its run (an invite, or the Group Finder's word on an ended run, doesn't)
    local o = RunToastOpts()
    if o and o.dzRun and o.dzMode == nil and not R():GetGroup(o.dzRun) then UI():HideToast(TOAST_KEY) end
end

-- Opens the tab on a run (a chat link, the Home calendar): scrolls to it and lights it up for a moment. Returns false
-- when the run is not on the board (over, or not here yet).
function DungeonsUI:Focus(id)
    if ns.MainFrame then ns.MainFrame:Open("dungeons") end
    if state.sheet then self:CloseSheet() end
    local run = R():GetGroup(id)   -- (a group whose lead passed is found by its old id: focus it as it is now)
    if not run then return false end
    state.focus, state.focusUntil, state.focusY = run.id, GetTime() + 2.5, nil
    self:Refresh()
    if panel and state.focusY then
        local range = panel.scroll:GetVerticalScrollRange() or 0
        panel.scroll:SetVerticalScroll(min(range, max(0, state.focusY - 30)))
    end
    ns.Util.After(2.6, function() DungeonsUI:Refresh() end)
    return true
end

-- What a run's card tooltip says (the Home calendar uses it too).
function DungeonsUI:GetRunTip(run)
    return CardTip(run)()
end

-- The role somebody plays in my run: Tank / Healer / DPS (the ones their class plays).
function DungeonsUI:OpenRoleMenu(owner, key)
    local run = R():GetMine()
    if not run then return end
    local current
    for _, x in ipairs(run.s or {}) do
        if x.k == key then current = x.r end
    end
    local classFile = R():GetClass(key)
    for _, s in ipairs(R():GetSlots(run)) do
        if s.key == key then classFile = s.class or classFile end
    end
    UI():ContextMenu(owner, function(root)
        if root.CreateTitle then root:CreateTitle(UI():ColoredName(key, classFile)) end
        for _, role in ipairs(R().ROLES) do
            if R():CanPlayRole(classFile, role) then
                root:CreateRadio(UI():RoleIconText(role, 14) .. "  " .. R().ROLE_LABEL[role],
                    function() return current == role end,
                    function() R():SetPartyRole(key, role) end)
            end
        end
    end)
end

-- My run's More menu: Edit, Post in LookingForGroup, (listed in the Group Finder:) Look again, Note, Unlist.
function DungeonsUI:OpenMineMenu(owner)
    local Ui = UI()
    Ui:ContextMenu(owner, function(root)
        local function entry(icon, text, tip, fn, color)
            local b = root:CreateButton(Ui:AtlasIconText(icon, 14, color or GOLD) .. "  " .. text, fn)
            if b and b.SetTooltip then
                b:SetTooltip(function(tt)
                    tt:AddLine(text, S:RGB("GOLD"))
                    tt:AddLine(tip, 1, 1, 1, true)
                end)
            end
        end
        local group = R():GetMyGroup()
        local raid = group and R():GetKind(group) == "raid"
        entry(16, "Edit", raid and "Change the raids, the places, the loot, the time or the note."
            or "Change the dungeon, the time, the note or your role.", function() DungeonsUI:OpenSheet(true) end)
        if group and R():GetSize(group) > 5 and not (ns.GroupsLead and ns.GroupsLead:IsOpen()) then
            entry(Ui.ICON.team or 16, "Manage group", "The roster by role, the requests and who fits a place.",
                function() ns.GroupsLead:Open(group.id) end)
        end
        -- (1.5) a raid group: its raid session, the way it was listed (rolls, soft reserves, the loot council)
        local GR = ns.GroupRules
        if raid and not (GR and GR.GetSession and GR:GetSession()) then
            entry(Ui.ICON.play or 16, "Start raid session", "Starts the raid session with your group's loot: "
                .. LOOT_WORDS[group.lo or "roll"] .. ".", function() DungeonsUI:StartSession() end)
        end
        -- (1.5, feedback #8) the message as built on the LFG message tab
        local LFG = ns.GroupsLFG
        local msg = LFG and LFG:Compose()
        entry(18, "Post in LFG", "Posts your message in the LookingForGroup channel: "
            .. (msg or "nothing is open") .. ".", function()
                local ok, why = LFG:Post()
                if not ok and why then ns:Print("%s", why) end
            end)
        entry(18, "LFG message", "Build the message: what you need, the specs you're after, the order of its parts; "
            .. "and post it again every 30 s.", function()
                if ns.GroupsLead then ns.GroupsLead:Open(group and group.id, "message") end
            end)
        -- listed in the Group Finder (the eye on the card): search again, and the note only the player can type
        local GF, mine = ns.GroupFinder, R():GetMine()
        if GF and mine and select(2, GF:GetListing(mine)) then
            entry(Ui.ICON.eye, "Look again", "Searches the Group Finder again for players who want this dungeon.",
                function() GF:Search(mine) end)
            entry(Ui.ICON.notes, "Note", "Opens Blizzard's Group Finder on your listing to write its note. Only you "
                .. "can type it: addons aren't allowed to.", function()
                    if not GF:OpenBlizzard() then ns:Print("Blizzard's Group Finder didn't open.") end
                end)
        end
        if root.CreateDivider then root:CreateDivider() end
        entry(Ui.ICON.trash, "Unlist", "Takes your run off the board, and out of the Group Finder.", function()
            -- (a click: the Group Finder takes listings down only inside one)
            if GF and mine and select(2, GF:GetListing(mine)) then GF:Unlist() end
            R():Unlist()
        end, { 1, 0.4, 0.35 })
    end)
end

-- Starts my raid group's session (its loot as listed); says why it couldn't.
function DungeonsUI:StartSession()
    local ok, why = R():StartGroupSession()
    if not ok and why then ns:Print("%s", why) end
    return ok
end

function DungeonsUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", "DisasterZoneDungeonsPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    -- a Board page: the toolbar ("I'm up for a run", List a run), then the members up for a run and the runs by
    -- section in the body
    p.layout = UI():CreateLayout("board", p, { bottom = 6 })
    p.headers, p.cards = {}, {}
    CreateTop(p)
    CreateTabs(p)
    CreateStrip(p)
    p.scroll = UI():CreateScrollFrame(p.layout.body)
    p.content = CreateFrame("Frame", nil, p.scroll)
    p.content:SetSize(760, 10)
    p.scroll:SetScrollChild(p.content)
    p.empty = UI():CreateEmptyState(p.layout.body, { glyph = UI().ICON.team, title = "No groups listed right now." })
    p.empty:SetFrameLevel(p.scroll:GetFrameLevel() + 5)
    p.empty:Hide()
    -- (MainFrame calls this on every show of the page, the first one too; an OnShow as well painted it twice
    -- per switch, 1.4.1)
    p.OnPanelShown = function() DungeonsUI:Refresh() end
    p.elapsed = 0
    p:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed >= 30 then
            self.elapsed = 0
            DungeonsUI:Refresh()
        end
    end)
    return p
end

---------------------------------------------------------------------------
-- List a group: the sheet (UI/GroupsSheet.lua)
---------------------------------------------------------------------------

function DungeonsUI:OpenSheet(edit)
    if not panel then
        if ns.MainFrame then ns.MainFrame:Open("dungeons") end
        if not panel then return end
    end
    ns.GroupsSheet:Open(panel, edit)
end
function DungeonsUI:CloseSheet() ns.GroupsSheet:Close() end
function DungeonsUI:SubmitSheet() ns.GroupsSheet:Submit() end
function DungeonsUI:RefreshSheet() ns.GroupsSheet:Refresh() end
function DungeonsUI:RefreshSheetPreview() ns.GroupsSheet:RefreshPreview() end

---------------------------------------------------------------------------
-- The pop-up: a run needs me / somebody asks to join my run
---------------------------------------------------------------------------

local function Chime()
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_PLAYER_INVITE then PlaySound(SOUNDKIT.IG_PLAYER_INVITE) end
end

-- The heroic skull and its word over the pop-up's art (in the toast's slot for a caller's own pieces).
local function ToastHeroic(t, heroic)
    local slot = t.slot
    if not slot.dzRunSkull then
        slot.dzRunSkull = slot:CreateTexture(nil, "OVERLAY")
        slot.dzRunSkull:SetTexture(HEROIC_TEX)
        slot.dzRunSkull:SetTexCoord(0, 0.5, 0, 0.625)
        slot.dzRunSkull:SetSize(11, 14)
        slot.dzRunSkull:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 8, 8)
        slot.dzRunHeroic = UI():Text(slot, "small", "GOLD")
        slot.dzRunHeroic:SetText("Heroic")
        slot.dzRunHeroic:SetPoint("LEFT", slot.dzRunSkull, "RIGHT", 2, 0)
    end
    slot.dzRunSkull:SetShown(heroic)
    slot.dzRunHeroic:SetShown(heroic)
end

-- The pop-up (UI:Toast): the dungeon's art, its name over the line l2 (nil: none) and the hint l3, one button.
-- mode: "invite" (a party invite: no countdown, the cross declines, no chime: Blizzard's invite sound already played)
-- Fields kept for the callers and the harness: t.run, t.mode, t.btn (the button), t.x (the cross), t.t2 (l2's text).
local function ShowToast(run, l2, l3, btnText, onClick, mode)
    -- a party invite waiting for its answer is never pushed out by a ping
    -- (shown, or still waiting behind other pop-ups)
    local pending = RunToastOpts()
    if mode ~= "invite" and pending and pending.dzMode == "invite" then
        Chime()
        return
    end
    local file, l, r, tt, b = R():GetGroupArt(run, TOAST_ART, TOAST_H - 2)
    local full, short = DungeonName(run)
    UI():Toast({
        key = TOAST_KEY,
        dzMode = mode, dzRun = run.id,
        kind = "info",
        width = TOAST_W,
        art = file and { file, l, r, tt, b } or nil,
        artWidth = TOAST_ART,
        kicker = (UI():TextWidth(full, "caps") > TOAST_W - TOAST_ART - 130 and short) or full,
        title = l2,   -- (nil: the text alone under the dungeon's name, one paragraph)
        text = l3,
        lines = 2,
        duration = mode == "invite" and 0 or TOAST_FOR,
        buttons = { { text = btnText, kind = "primary", onClick = function() onClick() end } },
        -- a click on the pop-up opens the tab (an invite stays: it is the invite)
        onClick = function()
            if ns.MainFrame then ns.MainFrame:Open("dungeons") end
            return mode == "invite"
        end,
        -- the cross: closes the pop-up; on a party invite it declines (the invite is the pop-up's whole point)
        onClose = function(_, reason)
            if reason == "close" and mode == "invite" then R():AnswerInvite(false) end
        end,
        -- each time it is filled to be shown (at once, or later from the shared queue): its fields, the X's
        -- tooltip, the heroic skull (the toast frames are shared: nothing of this stays on another's pop-up)
        onShow = function(t)
            toast = t
            t.mode, t.run = mode, run.id
            t.btn, t.x, t.t2 = t.btns[1], t.close, t.title
            if mode == "invite" then
                UI():AttachTooltip(t.close, "Decline", "Says no to the party invite.", { anchor = "ANCHOR_TOP" })
            end
            ToastHeroic(t, (R():GetKind(run) == "dungeon" and run.h) and true or false)
            if mode ~= "invite" then Chime() end
        end,
    })
end

-- True while the Dungeons tab is on screen: the board itself shows what a pop-up would say.
local function BoardShown()
    return panel ~= nil and panel:IsVisible() and not state.sheet
end

-- (1.5) My raid group's leader arrived in its raid with no session running: a pop-up offers to start it.
function DungeonsUI:OnRaidArrived(id)
    local run = R():GetGroup(id)
    if not run then return end
    ShowToast(run, "You're in", "Start the raid session: " .. LOOT_WORDS[run.lo or "roll"] .. ".", "Start",
        function() DungeonsUI:StartSession() end)
end

function DungeonsUI:OnPing(id)
    local run = R():GetGroup(id)
    if not run or BoardShown() then return end
    local role = R():FitsMe(run)
    if not role then return end
    local hint = HintFor(run)
    -- (sized to the group: "7/10")
    local filled = 0
    for _, d in ipairs(R():GetSlots(run)) do if not d.empty then filled = filled + 1 end end
    ShowToast(run, UI():ColoredName(run.o) .. S:Wrap("SUB", " needs a " .. ROLE_NAME[role] .. "  ·  " .. filled .. "/"
        .. R():GetSize(run)), hint, "Join", function() G.TryJoin(run) end)
end

function DungeonsUI:OnRequest(id, key)
    local run = R():GetGroup(id)
    if not run or run.o ~= Me() then return end
    if BoardShown() then
        Chime()
        return
    end
    local req
    for _, q in ipairs(R():GetRequests(id)) do
        if q.key == key then req = q end
    end
    if not req then return end
    local spec = R():GetSpecLabel(key)
    local l3 = UI():RoleIconText(req.r, 12) .. " " .. S:Wrap("SUB", (spec and (spec .. " ") or "") .. R().ROLE_LABEL[req.r])
    if req.b then l3 = l3 .. "   " .. S:Wrap("GOLD", STAR .. " BiS here") end
    ShowToast(run, UI():ColoredName(key) .. S:Wrap("SUB", " wants to join"), l3, "Accept", function() R():Accept(id, key) end)
end

-- A run's leader invites me (Blizzard's pop-up closed by Core): this pop-up is the invite, even over the board.
function DungeonsUI:OnInvite(id, from)
    local run = R():GetGroup(id)
    if not run then return end
    local a = R():GetAsked(id)
    local role = (a and a.r) or R():FitsMe(run)
    local l3 = role and (UI():RoleIconText(role, 12) .. " " .. S:Wrap("SUB", "as " .. R().ROLE_LABEL[role])) or nil
    ShowToast(run, UI():ColoredName(from) .. S:Wrap("SUB", " invites you"), l3, "Accept", function() R():AnswerInvite(true) end,
        "invite")
    if panel and panel:IsVisible() then self:RequestRefresh() end
end

function DungeonsUI:OnInviteGone()
    local o = RunToastOpts()
    if o and o.dzMode == "invite" then UI():HideToast(TOAST_KEY) end
    self:RequestRefresh()
end

-- My run is meant for the Group Finder but isn't listed there (a run for later that started, or one I took over
-- with the lead: Blizzard delists a party whose leader changes): one click lists it.
function DungeonsUI:OnFinderPrompt(id)
    local run = R():GetRun(id)
    local GF = ns.GroupFinder
    if not run or not GF then return end
    local parts = {}
    local open = R():GetOpenRoles(run)
    for _, role in ipairs(R().ROLES) do
        local n = open[role]
        if n then parts[#parts + 1] = (n > 1 and (n .. " ") or "") .. R().ROLE_LABEL[role] end
    end
    ShowToast(run, tconcat(parts, ", ") .. S:Wrap("SUB", " open in your run"),
        S:Wrap("SUB", "List it in the Group Finder for pugs?"), "List", function()
            local ok, why = GF:List(run)
            if not ok and why then ns:Print("%s", why) end
        end)
end

-- My run ended by itself (full, time up, a raid) but its Group Finder listing is still up: one click takes it down.
-- old = { id, d, h } (the run is gone).
function DungeonsUI:OnFinderLeftover(old)
    local GF = ns.GroupFinder
    if not GF or not old or not R():GetDungeon(old.d) then return end
    ShowToast(old, nil, S:Wrap("SUB", "Your run is over, but it's still in the Group Finder."), "Remove",
        function() GF:RemoveLeftover(old) end, "finder")
end

-- For the harness / UI audit.
function DungeonsUI:GetPanel() return panel end
-- (1.5) the board's tab ("all" | "dungeon" | "raid" | "quest" | "pvp") and the opened card (a group's id, or nil)
function DungeonsUI:SetTab(tab)
    state.tab, state.open = tab, nil
    self:Refresh()
end
function DungeonsUI:GetTab() return state.tab or "all" end
function DungeonsUI:OpenCard(id)
    state.open = id
    self:Refresh()
end
function DungeonsUI:GetOpenCard() return state.open end
function DungeonsUI:GetToast()
    -- (the shared toast frames are reused: only the one showing my run's pop-up is mine)
    local t = RunToast()
    if t then return t end
    if toast and not toast:IsShown() then return toast end
    return nil
end
function DungeonsUI:GetSheetState() return state.sheet end
function DungeonsUI:SetSheet(fields)
    for k, v in pairs(fields or {}) do state.sheet[k] = v end
    self:RefreshSheet()
end

function DungeonsUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("dungeons", "Groups", 3.55,
            function(parent) return DungeonsUI:CreatePanel(parent) end,
            function() return (IsInGuild() or (ns.Demo and ns.Demo:IsEnabled())) and true or false end,
            { layout = "board" })
    end
    local function refresh() DungeonsUI:RequestRefresh() end
    for _, msg in ipairs({ "DUNGEON_RUNS_UPDATED", "ROSTER_UPDATED", "GROUP_UPDATED", "ITEMINFO_READY",
                           "DEMO_TOGGLED", "PROFESSIONS_UPDATED", "GROUP_FINDER_UPDATED" }) do
        ns:On(msg, refresh)
    end
    ns:On("DUNGEON_RUN_PING", function(id) DungeonsUI:OnPing(id) end)
    ns:On("GROUP_RAID_ARRIVED", function(id) DungeonsUI:OnRaidArrived(id) end)
    ns:On("DUNGEON_RUN_REQUEST", function(id, key) DungeonsUI:OnRequest(id, key) end)
    ns:On("DUNGEON_RUN_INVITE", function(id, from) DungeonsUI:OnInvite(id, from) end)
    ns:On("DUNGEON_RUN_INVITE_GONE", function() DungeonsUI:OnInviteGone() end)
    ns:On("GROUP_FINDER_PROMPT", function(id) DungeonsUI:OnFinderPrompt(id) end)
    ns:On("GROUP_FINDER_LEFTOVER", function(old) DungeonsUI:OnFinderLeftover(old) end)
    -- an invite of mine that went nowhere (declined, in a group, offline): Invite again
    ns:On("PARTY_INVITE_FAILED", function(key)
        if state.invited[key] then
            state.invited[key] = nil
            DungeonsUI:RequestRefresh()
        end
    end)
end
