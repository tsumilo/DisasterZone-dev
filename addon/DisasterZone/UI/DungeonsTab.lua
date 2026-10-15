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
    top.label.text:SetText("I'm up for a run")
    top.label:SetSize((top.label.text:GetStringWidth() or 100) + 4, 20)
    top.label:SetPoint("LEFT", top.switch, "RIGHT", 9, 0)
    top.label:SetScript("OnClick", function() R():SetUp(not R():IsUp()) end)
    top.label:SetScript("OnEnter", UpTip)
    top.label:SetScript("OnLeave", HideTip)
    top.roles = {}
    for _, role in ipairs(R().ROLES) do
        top.roles[role] = NewRoleChip(top, role, function(self) R():SetMyRole(role, not self.on) end)
    end
    top.list = bar:SetPrimary({ text = "List a run", width = 110, onClick = function() DungeonsUI:OpenSheet() end })
end

local function UpdateTop(p)
    local top = p.top
    top.switch:SetOn(R():IsUp())
    top.label.text:SetTextColor(S:Color(R():IsUp() and "TEXT" or "SUB"))
    local mine = R():GetMyRoles()
    local x = top.label:GetWidth() + 9 + 34 + 12
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

-- The runs to show, by section: mine, now (joinable first, blocked last), later (by start).
local function Sections()
    local mine, now, later = nil, {}, {}
    for _, run in ipairs(R():GetRuns()) do
        if run.o == Me() then
            mine = run
        elseif R():IsNow(run) then
            now[#now + 1] = run
        else
            later[#later + 1] = run
        end
    end
    local function rank(run)
        if R():GetBlocker(run.d, run.h) then return 4 end
        if R():IsInRun(run) then return 0 end
        local fits = R():FitsMe(run) ~= nil
        local bis = #R():GetMyBiSDrops(run.d, run.h) > 0
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
        if a.at ~= b.at then return a.at < b.at end
        return a.id < b.id
    end)
    return mine, now, later
end

function DungeonsUI:Refresh()
    if not panel or not panel:IsVisible() then return end
    local p = panel
    if state.sheet then self:RefreshSheet() end
    local width = p:GetWidth()
    if not width or width < 300 then width = 780 end
    local mine, now, later = Sections()
    -- the bar and the strip are for finding a run: my own run takes their place
    p.top:SetShown(mine == nil)
    local body = p.layout.body
    local y = 0
    if mine == nil then
        p.layout.toolbar:SetPrimary({ text = "List a run", width = 110, onClick = function() DungeonsUI:OpenSheet() end })
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
    if mine then
        header("Your run")
        card(mine, { mine = true })
        cy = cy + 4
    end
    if #now > 0 then
        header("Now")
        for _, run in ipairs(now) do card(run, {}) end
    end
    -- later runs by day: "Later  today", then "Tomorrow", "Saturday 11 Oct", ...
    local lastDay
    for _, run in ipairs(later) do
        local day = DayLabel(run.at)
        if day ~= lastDay then
            if lastDay == nil then header("Later", day) else header(day) end
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
        p.empty:SetContent({ glyph = UI().ICON.team, title = "No runs listed right now.",
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
    if o and o.dzRun and o.dzMode == nil and not R():GetRun(o.dzRun) then UI():HideToast(TOAST_KEY) end
end

-- Opens the tab on a run (a chat link, the Home calendar): scrolls to it and lights it up for a moment. Returns false
-- when the run is not on the board (over, or not here yet).
function DungeonsUI:Focus(id)
    if ns.MainFrame then ns.MainFrame:Open("dungeons") end
    if state.sheet then self:CloseSheet() end
    local run = R():GetRun(id)   -- (a run whose lead passed is found by its old id: focus the run as it is now)
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
        entry(16, "Edit", "Change the dungeon, the time, the note or your role.",
            function() DungeonsUI:OpenSheet(true) end)
        entry(18, "Post in LFG", "Posts the open places in the LookingForGroup channel: "
            .. (R():GetChannelText() or "nothing is open") .. ".", function()
                local ok, why = R():PostToChannel()
                if not ok and why then ns:Print("%s", why) end
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
    CreateStrip(p)
    p.scroll = UI():CreateScrollFrame(p.layout.body)
    p.content = CreateFrame("Frame", nil, p.scroll)
    p.content:SetSize(760, 10)
    p.scroll:SetScrollChild(p.content)
    p.empty = UI():CreateEmptyState(p.layout.body, { glyph = UI().ICON.team, title = "No runs listed right now." })
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
-- List a run: the sheet
---------------------------------------------------------------------------

local WHEN = { { key = "now", text = "Now" }, { key = "30", text = "In 30 min" }, { key = "60", text = "In 1 h" },
               { key = "later", text = "Later" } }
local FORM_LABEL_W = 62
local FORM_W = 286
local DAYS_AHEAD = 6
local HEROIC_ICON = "|T" .. HEROIC_TEX .. ":13:10:0:0:32:32:0:16:0:20|t"   -- (the skull of UI-LFG-ICON-HEROIC)
local DAILY_ICON = "|TInterface\\GossipFrame\\DailyQuestIcon:12:12:0:0|t"

-- Minutes after midnight of now (local clock).
local function NowMinutes()
    local t = date("*t", ns.Util.Now())
    return t.hour * 60 + t.min
end

-- The earliest start a later run can have on day `day` (0 = today): a quarter of an hour from now, on a quarter.
local function MinMinutes(day)
    if day > 0 then return 0 end
    return math.ceil((NowMinutes() + 15) / 15) * 15
end

local function DayTime(day, mins)
    local t = date("*t", ns.Util.Now())
    return time({ year = t.year, month = t.month, day = t.day + day, hour = floor(mins / 60), min = mins % 60,
                  sec = 0 })
end

local function SheetTime(s)
    if s.when == "now" then return 0 end
    if s.when == "30" then return ns.Util.Now() + 1800 end
    if s.when == "60" then return ns.Util.Now() + 3600 end
    return DayTime(s.day or 0, s.mins or 0)
end

-- A later run's first suggestion: the next full hour at least an hour away (tomorrow when today is over).
local function DefaultLater(s)
    local mins = math.ceil((NowMinutes() + 60) / 60) * 60
    if mins >= 24 * 60 then
        s.day, s.mins = 1, 20 * 60
    else
        s.day, s.mins = 0, mins
    end
end

-- Keeps day / time valid: today never before now + 15 min.
local function ClampLater(s)
    s.day = min(max(s.day or 0, 0), DAYS_AHEAD)
    if MinMinutes(s.day) >= 24 * 60 then s.day = s.day + 1 end
    s.mins = min(max(s.mins or 0, MinMinutes(s.day)), 24 * 60 - 15)
end

local function DayText(day)
    if day == 0 then return "Today" end
    if day == 1 then return "Tomorrow" end
    local t = DayTime(day, 12 * 60)
    return date("%a ", t) .. tonumber(date("%d", t)) .. date(" %b", t)
end

-- A dungeon tile: the short name, then at most one badge (★ guildies with BiS there, or "Saved"), the DAILY pill on
-- its edge; the sleek button's surface (UI:PaintSleek: "chosen" while picked, quiet while it can't be picked).
local function NewTile(parent)
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(TILE_W, TILE_H)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    UI():AddEdges(t, "BORDER")
    t.name = UI():Text(t, "emph", "TEXT")
    t.name:SetPoint("LEFT", 10, 0)
    t.count = UI():Text(t, "emph", "GOLD")
    t.count:SetPoint("RIGHT", -9, 0)
    t.star = t:CreateTexture(nil, "OVERLAY")
    t.star:SetTexture(STAR_TEX)
    t.star:SetSize(11, 11)
    t.star:SetPoint("RIGHT", t.count, "LEFT", -2, 0)
    t.saved = UI():Text(t, "small", "SUB")
    t.saved:SetPoint("RIGHT", -8, 0)
    t.saved:SetText("Saved")
    t.lock = t:CreateTexture(nil, "OVERLAY")
    t.lock:SetTexture(UI().ICON_LOCK)
    t.lock:SetSize(12, 12)
    t.lock:SetPoint("RIGHT", t.saved, "LEFT", -2, 0)
    t.daily = UI():CreatePill(t, "bis", "DAILY")
    t.daily:SetPoint("TOPRIGHT", t, "TOPRIGHT", -8, 7)
    t.daily:SetFrameLevel(t:GetFrameLevel() + 2)
    t.liveTip = true
    t:SetScript("OnEnter", function(self)
        local lines = self.tip and self.tip()
        if lines then UI():SetTextTooltip(self, lines, "ANCHOR_TOP") end
    end)
    t:SetScript("OnLeave", HideTip)
    return t
end

local DAILY_WORDS = {
    log = "Your daily quest for it is in your quest log.",
    today = "Today's daily: you haven't done it yet.",
    done = "Today's daily: done.",
}

-- The tile's tooltip, or nil when it would only repeat the name on the tile.
local function TileTip(info, heroic)
    return function()
        local lines = { info.name .. (heroic and " (Heroic)" or "") }
        local block, kind = R():GetBlocker(info.key, heroic)
        if kind == "saved" then
            lines[#lines + 1] = S:Wrap("WARN", block) .. S:Wrap("SUB", " (the daily reset)")
        elseif block then
            lines[#lines + 1] = S:Wrap("WARN", block)
        end
        local daily = R():GetMyDaily(info.key, heroic)
        if daily then
            lines[#lines + 1] = (daily == "done" and S:Wrap("SUB", DAILY_WORDS.done))
                or (DAILY_ICON .. " " .. S:Wrap("GOLD", DAILY_WORDS[daily]))
        end
        local n, who = R():GetNeeders(info.key, heroic)
        if n > 0 then
            local names = {}
            for i, k in ipairs(who) do
                if i > 8 then names[#names + 1] = "+" .. (#who - 8) break end
                names[#names + 1] = UI():ColoredName(k)
            end
            lines[#lines + 1] = STAR .. " " .. n .. (n == 1 and " guildie online has" or " guildies online have")
                .. " BiS here: " .. tconcat(names, ", ")
        end
        local drops = R():GetMyBiSDrops(info.key, heroic)
        if #drops > 0 then
            lines[#lines + 1] = S:Wrap("GOLD", "Drops your BiS:")
            for i, id in ipairs(drops) do
                if i > 6 then lines[#lines + 1] = S:Wrap("SUB", "+" .. (#drops - 6) .. " more") break end
                lines[#lines + 1] = "  " .. ItemLinkText(id)
            end
        end
        if #lines == 1 and info.short == info.name then return nil end
        return lines
    end
end

-- A dungeon complex in the sheet: the shared art row (UI:CreateArtRow: its picture, its icon, the name, what holds
-- back the whole complex), its dungeons' tiles on the right.
local function NewComplexRow(parent)
    local r = UI():CreateArtRow(parent, { rule = false })
    UI():AttachTooltip(r, nil, function(self) return self.whyTip end, { anchor = "ANCHOR_TOP" })
    r.tiles = {}
    return r
end

local function SheetSelect(key)
    local s = state.sheet
    if not s then return end
    s.d = key
    s.err = nil
    DungeonsUI:RefreshSheet()
end

local function CreateSheet(p)
    -- the shared sheet as a cover over the page (its title, its close X; Escape closes it too)
    -- (only the sheet's own close counts: hidden with the tab or the window, it stays open with its draft)
    local sh = UI():CreateSheet(p, { cover = true, bg = SHEET_BG, rule = false, onClose = function()
        if state.sheet and p:IsVisible() then DungeonsUI:CloseSheet() end
    end })
    -- Normal / Heroic: the shared segments, after the sheet's title
    sh.mode = UI():CreateSegments(sh, { { key = "normal", label = "Normal" },
        { key = "heroic", label = HEROIC_ICON .. " Heroic" } }, function(key)
        state.sheet.h = key == "heroic"
        state.sheet.err = nil
        DungeonsUI:RefreshSheet()
    end, { h = S.BTN_H, itemW = 82 })
    UI():AttachTooltip(sh.close, "Close", "Nothing is listed.", { anchor = "ANCHOR_LEFT" })
    sh.rows = {}

    -- the form: When, (At), Note, You go as; its rows anchored once inside sh.form
    local form = CreateFrame("Frame", nil, sh)
    form:SetSize(FORM_LABEL_W + FORM_W, 140)
    sh.form = form
    sh.whenLabel = UI():Text(form, "body", "SUB")
    sh.whenLabel:SetText("When")
    sh.whenLabel:SetPoint("TOPLEFT", 0, -6)
    local whenItems = {}
    for i, def in ipairs(WHEN) do whenItems[i] = { key = def.key, label = def.text } end
    sh.when = UI():CreateSegments(form, whenItems, function(key)
        local s = state.sheet
        if s.when == key then return end
        s.when = key
        if key == "later" and not s.mins then DefaultLater(s) end
        DungeonsUI:RefreshSheet()
    end, { h = S.BTN_H })
    sh.when:SetPoint("TOPLEFT", FORM_LABEL_W, 0)
    sh.atRow = CreateFrame("Frame", nil, form)
    sh.atRow:SetSize(FORM_LABEL_W + FORM_W, 24)
    sh.atRow:SetPoint("TOPLEFT", 0, -33)
    sh.atLabel = UI():Text(sh.atRow, "body", "SUB")
    sh.atLabel:SetText("At")
    sh.atLabel:SetPoint("LEFT", 0, 0)
    local stepTip = { "Pick the time", "Click the arrows or scroll. Your clock; everybody sees it in theirs." }
    sh.day = UI():CreateStepper(sh.atRow, 150, function(dir)
        local s = state.sheet
        s.day = (s.day or 0) + dir
        ClampLater(s)
        DungeonsUI:RefreshSheet()
    end, { tip = stepTip })
    sh.day:SetPoint("LEFT", FORM_LABEL_W, 0)
    sh.time = UI():CreateStepper(sh.atRow, 96, function(dir)
        local s = state.sheet
        s.mins = (s.mins or 0) + dir * 15
        ClampLater(s)
        DungeonsUI:RefreshSheet()
    end, { tip = stepTip })
    sh.time:SetPoint("LEFT", sh.day, "RIGHT", 6, 0)
    sh.noteRow = CreateFrame("Frame", nil, form)
    sh.noteRow:SetSize(FORM_LABEL_W + FORM_W, 24)
    sh.noteLabel = UI():Text(sh.noteRow, "body", "SUB")
    sh.noteLabel:SetText("Note")
    sh.noteLabel:SetPoint("LEFT", 0, 0)
    sh.note = UI():CreateSleekEditBox(sh.noteRow, FORM_W, 24, "GameFontHighlightSmall")
    sh.note:SetPoint("LEFT", FORM_LABEL_W, 0)
    sh.note:SetMaxLetters(R().NOTE_MAX)
    sh.fields[#sh.fields + 1] = sh.note
    sh.note:SetScript("OnTextChanged", function(self)
        if state.sheet then state.sheet.no = self:GetText() end
        DungeonsUI:RefreshSheetPreview()
    end)
    UI():SetEditPlaceholder(sh.note, "Optional, e.g. \"badge run, fast pulls\"")
    sh.roleRow = CreateFrame("Frame", nil, form)
    sh.roleRow:SetSize(FORM_LABEL_W + FORM_W, 24)
    sh.roleRow:SetPoint("TOPLEFT", sh.noteRow, "BOTTOMLEFT", 0, -9)
    sh.roleLabel = UI():Text(sh.roleRow, "body", "SUB")
    sh.roleLabel:SetText("You go as")
    sh.roleLabel:SetPoint("LEFT", 0, 0)
    -- the role I play: one of the roles my class plays (the shared segments, their role icons)
    sh.roles = UI():CreateSegments(sh.roleRow, {}, function(key)
        state.sheet.role = key
        DungeonsUI:RefreshSheet()
    end, { h = S.BTN_H, itemW = 34 })
    sh.roles:SetPoint("LEFT", FORM_LABEL_W, 0)
    -- the Group Finder too (a run for now: listed with the same click; for later: a pop-up when it starts)
    sh.gfRow = CreateFrame("Frame", nil, form)
    sh.gfRow:SetSize(FORM_LABEL_W + FORM_W, 24)
    sh.gfRow:SetPoint("TOPLEFT", sh.roleRow, "BOTTOMLEFT", 0, -9)
    sh.gfLabel = UI():Text(sh.gfRow, "body", "SUB")
    sh.gfLabel:SetText("Pugs")
    sh.gfLabel:SetPoint("LEFT", 0, 0)
    local function flip()
        state.sheet.gf = not state.sheet.gf
        DungeonsUI:RefreshSheet()
    end
    local function gfTip(self)
        UI():SetTextTooltip(self, { "Group Finder", "Also puts your run in Blizzard's Group Finder, for players outside the guild. "
            .. "Whoever looks for this dungeon there, or whispers you, shows up on your run.",
            S:Wrap("SUB", "A run for later: you get a pop-up when it starts.") }, "ANCHOR_TOP")
    end
    sh.gf = UI():CreateSwitch(sh.gfRow, nil, function() flip() end)
    sh.gf:SetPoint("LEFT", FORM_LABEL_W, 0)
    sh.gf:SetScript("OnEnter", gfTip)
    sh.gf:SetScript("OnLeave", HideTip)
    sh.gfText = CreateFrame("Button", nil, sh.gfRow)
    sh.gfText.text = UI():Text(sh.gfText, "emph", "TEXT")
    sh.gfText.text:SetPoint("LEFT")
    sh.gfText:SetPoint("LEFT", sh.gf, "RIGHT", 8, 0)
    sh.gfText:SetScript("OnClick", flip)
    sh.gfText:SetScript("OnEnter", gfTip)
    sh.gfText:SetScript("OnLeave", HideTip)

    -- the preview and the button
    sh.previewLabel = UI():CreateSectionHeader(sh, "Preview", { style = "caps" })
    sh.preview = NewRunCard(sh)
    sh.preview:EnableMouse(false)
    sh.pick = UI():Text(sh, "emph", "SUB")
    sh.pick:SetText("Pick a dungeon above.")
    sh.err:ClearAllPoints()
    sh.go = UI():CreateSleekButton(sh, "List run", 130, S.BTN_H, function() DungeonsUI:SubmitSheet() end, "primary")
    sh:Hide()
    p.sheet = sh
    return sh
end

function DungeonsUI:RefreshSheetPreview()
    local sh = panel and panel.sheet
    local s = state.sheet
    if not sh or not s then return end
    local info = s.d and R():GetDungeon(s.d)
    sh.preview:SetShown(info ~= nil)
    sh.pick:SetShown(info == nil)
    if not info then return end
    local party = { { k = Me(), r = s.role } }
    for key in pairs(ns.Util.group or {}) do
        if not ns.Util.IsMe(key) then party[#party + 1] = { k = key, r = R():GetRoleOf(key) } end
    end
    local mine = R():GetMine()
    local run = { id = "preview", o = Me(), d = s.d, h = s.h or nil, at = SheetTime(s), c = mine and mine.c or ns.Util.Now(),
                  no = (s.no and ns.Util.Trim(s.no) ~= "") and ns.Util.Trim(s.no) or nil, s = party }
    if run.at > 0 and run.at <= ns.Util.Now() + 60 then run.at = 0 end
    FillCard(sh.preview, run, { width = sh.previewW or 390, compact = true })
end

-- Lays out the complex rows (art rows, their tiles in one grid on the right); returns the y under them.
local function SheetRows(sh, s, width)
    local y = -44
    local rowW = width - 2 * PAD
    local tilesW = 4 * (TILE_W + TILE_GAP)
    local ri = 0
    for _, c in ipairs(R():GetComplexes()) do
        ri = ri + 1
        local r = sh.rows[ri] or NewComplexRow(sh)
        sh.rows[ri] = r
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, y)
        r:SetWidth(rowW)
        -- the heroic key or the level holds back the whole complex: said once, on the row
        local whyAll, whyTip
        if s.h then
            local text, kind = R():GetBlocker(c.dungeons[1].key, true)
            if kind == "rep" or kind == "level" then
                whyAll = kind == "rep" and "Needs Revered" or text
                whyTip = { { c.name, S:Color("GOLD") }, text .. (kind == "rep" and " for the heroic key." or ".") }
            end
        end
        -- (the complex's loading screen, cropped round its first dungeon: clear of the logo band)
        local first = c.dungeons[1] and c.dungeons[1].key
        r:SetData({ art = function(tex, w, h)
                local file, l, rr, t, b = R():GetArt(first, w, h)
                tex:SetTexture(file)
                if file then tex:SetTexCoord(l, rr, t, b) end
            end, icon = c.icon, title = c.name, sub = whyAll and S:Wrap("WARN", whyAll) or nil })
        r.title:SetTextColor(S:Color("GOLD"))
        r.whyTip = whyTip
        r:SetRightWidth(tilesW)
        for i, info in ipairs(c.dungeons) do
            local tile = r.tiles[i] or NewTile(r.right)
            r.tiles[i] = tile
            tile:ClearAllPoints()
            tile:SetPoint("LEFT", r.right, "RIGHT", -tilesW + (i - 1) * (TILE_W + TILE_GAP), 0)
            tile.name:SetText(info.short)
            local block, kind = R():GetBlocker(info.key, s.h)
            local daily = R():GetMyDaily(info.key, s.h)
            local n = R():GetNeeders(info.key, s.h)
            local sel = s.d == info.key
            local off = block ~= nil
            -- picked: the gold of a pick (the segments' thumb); one I can't go to: the quiet surface, its name dimmed
            UI():PaintSleek(tile, sel and not off and "primary" or "secondary", false, off and 0.3 or nil)
            tile.bg:SetAlpha(off and 0.6 or 1)
            tile.name:SetTextColor(S:Color(off and "DIM" or "TEXT"))
            local saved = kind == "saved"
            tile.saved:SetShown(saved)
            tile.lock:SetShown(saved)
            local showCount = n > 0 and not off
            tile.count:SetShown(showCount)
            tile.star:SetShown(showCount)
            tile.count:SetText(n)
            tile.daily:SetShown((daily == "log" or daily == "today") and not off)
            tile.tip = TileTip(info, s.h)
            local dkey = info.key
            tile:SetScript("OnClick", function() if not off then SheetSelect(dkey) end end)
            tile:Show()
        end
        for i = #c.dungeons + 1, #r.tiles do r.tiles[i]:Hide() end
        r:Show()
        y = y - ROW_H - ROW_GAP
    end
    for i = ri + 1, #sh.rows do sh.rows[i]:Hide() end
    return y
end

function DungeonsUI:RefreshSheet()
    local sh = panel and panel.sheet
    local s = state.sheet
    if not sh or not s then return end
    local width = panel:GetWidth()
    if not width or width < 300 then width = 780 end
    sh.title:SetText(s.edit and "Edit your run" or "List a run")
    sh.mode:ClearAllPoints()
    sh.mode:SetPoint("LEFT", sh.title, "RIGHT", 18, 0)
    sh.mode:Select(s.h and "heroic" or "normal")

    local y = SheetRows(sh, s, width)
    -- a picked dungeon the switch to heroic made impossible is dropped
    if s.d and R():GetBlocker(s.d, s.h) then s.d = nil end

    -- the form (left) and the preview (right)
    y = y - 8
    sh.form:ClearAllPoints()
    sh.form:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, y)
    sh.when:Select(s.when)
    local later = s.when == "later"
    sh.atRow:SetShown(later)
    if later then
        ClampLater(s)
        local minDay = MinMinutes(0) >= 24 * 60 and 1 or 0
        sh.day:Set(DayText(s.day), s.day > minDay, s.day < DAYS_AHEAD)
        sh.time:Set(("%02d:%02d"):format(floor(s.mins / 60), s.mins % 60), s.mins > MinMinutes(s.day),
            s.mins < 24 * 60 - 15)
    end
    sh.noteRow:ClearAllPoints()
    sh.noteRow:SetPoint("TOPLEFT", sh.form, "TOPLEFT", 0, later and -66 or -33)
    local roles = {}
    for i, role in ipairs(R():GetPlayableRoles()) do
        roles[i] = { key = role, label = UI():RoleIconText(role, 16), tip = R().ROLE_LABEL[role] .. ": the role you play "
            .. "in this run." }
    end
    sh.roles:SetItems(roles)
    sh.roles:Select(s.role)
    local GF = ns.GroupFinder
    sh.gfRow:SetShown(GF ~= nil and GF:IsAvailable())
    sh.gf:SetOn(s.gf)
    sh.gfText.text:SetText(later and "List it in the Group Finder when it starts" or "Also list it in the Group Finder")
    sh.gfText.text:SetTextColor(S:Color(s.gf and "TEXT" or "SUB"))
    sh.gfText:SetSize((sh.gfText.text:GetStringWidth() or 200) + 2, 20)

    local px = PAD + FORM_LABEL_W + FORM_W + 24
    sh.previewW = width - PAD - px
    sh.previewLabel:ClearAllPoints()
    sh.previewLabel:SetPoint("TOPLEFT", sh, "TOPLEFT", px, y + 2)
    sh.previewLabel:SetWidth(sh.previewW)
    sh.preview:ClearAllPoints()
    sh.preview:SetPoint("TOPLEFT", sh, "TOPLEFT", px, y - 18)
    sh.pick:ClearAllPoints()
    sh.pick:SetPoint("TOPLEFT", sh, "TOPLEFT", px, y - 44)
    sh.go:ClearAllPoints()
    sh.go:SetPoint("TOPRIGHT", sh, "TOPRIGHT", -PAD, y - 18 - CARD_H - 8)
    sh.go:SetText(s.edit and "Save" or "List run")
    sh.go:SetEnabled(s.d ~= nil)
    sh.err:ClearAllPoints()
    sh.err:SetPoint("RIGHT", sh.go, "LEFT", -10, 0)
    sh.err:SetText(s.err or "")
    sh.err:SetShown(s.err ~= nil)
    self:RefreshSheetPreview()
end

function DungeonsUI:OpenSheet(edit)
    if not panel then
        if ns.MainFrame then ns.MainFrame:Open("dungeons") end
        if not panel then return end
    end
    local mine = R():GetMine()
    local level = UnitLevel and tonumber(UnitLevel("player")) or 70
    local s = { h = level >= 70, when = "now", role = R():GetGoAs(), edit = edit and mine ~= nil or nil }
    if s.edit then
        s.d, s.h, s.no, s.gf = mine.d, mine.h and true or false, mine.no, mine.gf
        if (mine.at or 0) > ns.Util.Now() then
            local t, n = date("*t", mine.at), date("*t", ns.Util.Now())
            s.when = "later"
            s.day = floor((time({ year = t.year, month = t.month, day = t.day, hour = 12 })
                - time({ year = n.year, month = n.month, day = n.day, hour = 12 })) / 86400 + 0.5)
            s.mins = t.hour * 60 + t.min - t.min % 15
        end
    else
        -- today's daily that is still mine to do, when I can go
        for _, c in ipairs(R():GetComplexes()) do
            for _, info in ipairs(c.dungeons) do
                local daily = R():GetMyDaily(info.key, s.h)
                if not s.d and (daily == "log" or daily == "today") and not R():GetBlocker(info.key, s.h) then
                    s.d = info.key
                end
            end
        end
    end
    if not R():GetMyRoles()[s.role] then
        for _, role in ipairs(R().ROLES) do
            if R():GetMyRoles()[role] then s.role = role break end
        end
    end
    state.sheet = s
    local sh = panel.sheet or CreateSheet(panel)
    sh.note:SetText(s.no or "")
    sh:Open()
    -- (the sheet covers the page: the toolbar under it goes, so nothing under the cover takes a click)
    panel.layout.toolbar:Hide()
    self:RefreshSheet()
end

function DungeonsUI:CloseSheet()
    state.sheet = nil
    if panel and panel.sheet then
        panel.sheet.note:ClearFocus()
        panel.sheet:Close()
        panel.layout.toolbar:Show()
    end
    self:Refresh()
end

function DungeonsUI:SubmitSheet()
    local s = state.sheet
    if not s or not s.d then return end
    local GF = ns.GroupFinder
    local before = R():GetMine()
    local wasListed = GF and before and select(2, GF:GetListing(before)) or false
    local run, why = R():List({ d = s.d, h = s.h, at = SheetTime(s), no = s.no, role = s.role, gf = s.gf })
    if not run then
        s.err = why
        self:RefreshSheet()
        return
    end
    -- the Group Finder follows the run, with this very click (the client lists only inside one): a run for now that
    -- was listed, or is meant to be, is listed as its dungeon (switched when that changed); one moved to later
    -- comes out
    if GF and R():IsNow(run) and (s.gf or wasListed) and not select(2, GF:GetListing(run)) then
        local ok, gfWhy = GF:List(run)
        if not ok and gfWhy then ns:Print("%s", gfWhy) end
    elseif GF and wasListed and not R():IsNow(run) then
        GF:Unlist()
    end
    self:CloseSheet()
end

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
    local file, l, r, tt, b = R():GetArt(run.d, TOAST_ART, TOAST_H - 2)
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
            ToastHeroic(t, run.h and true or false)
            if mode ~= "invite" then Chime() end
        end,
    })
end

-- True while the Dungeons tab is on screen: the board itself shows what a pop-up would say.
local function BoardShown()
    return panel ~= nil and panel:IsVisible() and not state.sheet
end

function DungeonsUI:OnPing(id)
    local run = R():GetRun(id)
    if not run or BoardShown() then return end
    local role = R():FitsMe(run)
    if not role then return end
    local hint = HintFor(run)
    ShowToast(run, UI():ColoredName(run.o) .. S:Wrap("SUB", " needs a " .. ROLE_NAME[role]), hint, "Join", function()
        local ok, why = R():Join(id)
        if not ok and why then ns:Print("%s", why) end
    end)
end

function DungeonsUI:OnRequest(id, key)
    local run = R():GetRun(id)
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
    local run = R():GetRun(id)
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
        ns.MainFrame:RegisterTab("dungeons", "Dungeons", 3.55,
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
