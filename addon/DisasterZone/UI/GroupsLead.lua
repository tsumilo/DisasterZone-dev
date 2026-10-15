if DisasterZoneBoot and DisasterZoneBoot.Run("UI/GroupsLead.lua", ...) then return end -- DisasterZone: UI/GroupsLead.lua
-- (1.5) My group, the leader's page: a group bigger than a party (a raid group, a battleground premade) filled
-- without a spreadsheet. A cover over the Groups tab (UI:CreateSheet), opened from my card's Manage. The hero: the
-- group's art, its icons, "YOUR GROUP · when", the name with its size and loot, share and ···, the role meters, the
-- tabs Roster / Reserves / Groups. Roster: the players by role in name cells (the leader's crown, guests tagged,
-- open places in gold) with what each role lacks; on the right the requests with what matters for each (BiS here,
-- a buff the group lacks, a blacklist warning, guest) and the guildies up for this kind of group who fit a place,
-- with Invite. Reserves: the soft reserves so far. Groups: the parties as Auto-fill would make them.
local addonName, ns = ...

local GL = {}
ns.GroupsLead = GL
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local tconcat, tsort = table.concat, table.sort

local function R() return ns.DungeonRuns end
local function UI() return ns.UI end
local function G() return ns.GroupsCard end
local function DUI() return ns.DungeonsUI end

local PAD = S.PAD
local GOLD = S.C.GOLD
local SHEET_BG = { 0.035, 0.035, 0.043, 1 }
local HERO_H = 124
local CELL_H, CELL_GAP = 26, 6
local SIDE_W = 300
local REQ_H = 54

local sh, runId, tab = nil, nil, "roster"

local function HideTip() GameTooltip:Hide() end

local function MyGroup()
    local run = R():GetMyGroup()
    return (run and run.id == runId) and run or nil
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------

local function NewCell(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetHeight(CELL_H)
    c.bg = UI():Fill(c, "CARD", "BACKGROUND")
    UI():AddEdges(c, "BORDER")
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(18, 18)
    c.icon:SetPoint("LEFT", 5, 0)
    c.name = UI():Text(c, "body", "TEXT")
    c.name:SetPoint("LEFT", c.icon, "RIGHT", 6, 0)
    c.name:SetPoint("RIGHT", -6, 0)
    c.name:SetJustifyH("LEFT")
    c.tag = UI():Text(c, "small", "SUB")
    c.tag:SetPoint("RIGHT", -6, 0)
    c.crown = c:CreateTexture(nil, "OVERLAY")
    c.crown:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    c.crown:SetSize(13, 13)
    c.crown:SetPoint("RIGHT", -6, 0)
    c:EnableMouse(true)
    c:SetScript("OnEnter", function(self)
        if self.key then UI():SetTextTooltip(self, { UI():ColoredName(self.key), self.tipLine }, "ANCHOR_TOP") end
    end)
    c:SetScript("OnLeave", HideTip)
    return c
end

local function Create(panel)
    sh = UI():CreateSheet(panel, { cover = true, bg = SHEET_BG, rule = false, onClose = function()
        if runId and panel:IsVisible() then GL:Close() end
    end })
    sh.title:SetText("")
    -- the hero
    local h = CreateFrame("Frame", nil, sh)
    h:SetPoint("TOPLEFT", PAD, -8)
    h:SetPoint("TOPRIGHT", -PAD, -8)
    h:SetHeight(HERO_H)
    h.art = h:CreateTexture(nil, "BACKGROUND")
    h.art:SetAllPoints()
    h.art:SetAlpha(0.55)
    h.shade = h:CreateTexture(nil, "BORDER")
    h.shade:SetAllPoints()
    h.shade:SetColorTexture(1, 1, 1, 1)
    UI():Gradient(h.shade, "HORIZONTAL", { 0.03, 0.03, 0.04, 0.88 }, { 0.03, 0.03, 0.04, 0.35 })
    UI():AddEdges(h, "ARTWORK")
    UI():SetEdgeColor(h, GOLD[1], GOLD[2], GOLD[3], 0.35)
    h.ring2 = UI():CreateFace(h, 40)
    h.ring2:SetPoint("TOPLEFT", 34, -34)
    h.ring = UI():CreateFace(h, 40)
    h.ring:SetPoint("TOPLEFT", 14, -14)
    h.kicker = UI():Text(h, "caps", "GOLD")
    h.kicker:SetPoint("TOPLEFT", 96, -18)
    h.name = UI():Text(h, "hero", "TEXT")
    h.name:SetPoint("TOPLEFT", h.kicker, "BOTTOMLEFT", 0, -6)
    h.size = UI():CreatePill(h, "mute", "")
    h.loot = UI():CreatePill(h, "bis", "")
    h.more = UI():CreateTipIconButton(h, 28, UI().ICON.more, "Your group", "Edit it, start the raid session, "
        .. "post it in the LookingForGroup channel, or take it off the board.")
    -- (the sheet's close sits in the hero, after share and ···: the hero keeps the page's full width)
    sh.close:SetParent(h)
    sh.close:ClearAllPoints()
    sh.close:SetPoint("TOPRIGHT", h, "TOPRIGHT", -10, -13)
    sh.close:SetFrameLevel(h:GetFrameLevel() + 5)
    h.more:SetPoint("RIGHT", sh.close, "LEFT", -10, 0)
    h.more:SetScript("OnClick", function(self) DUI():OpenMineMenu(self) end)
    if ns.Share and ns.Share.CreateButton then
        h.share = ns.Share:CreateButton(h, 28, function() return runId and ns.Share:RunRef(runId) or nil end,
            "Share your group")
        h.share:SetPoint("RIGHT", h.more, "LEFT", -6, 0)
    end
    h.meters = G().NewMeters(h)
    h.meters:SetPoint("BOTTOMRIGHT", -14, 14)
    h.tabs = {}
    for _, t in ipairs({ { "roster", "Roster" }, { "reserves", "Reserves" }, { "groups", "Groups" },
                         { "message", "LFG message" } }) do
        local key = t[1]
        local b = UI():CreateUnderlineTab(h, t[2], function()
            tab = key
            GL:Refresh()
        end)
        b.key, b.label = key, t[2]
        h.tabs[#h.tabs + 1] = b
    end
    h.back = UI():CreateBackLink(sh, "Groups", function() GL:Close() end)
    sh.hero = h
    -- the body: the roster (scrolls) on the left, the requests and the members up for it on the right
    sh.scroll = UI():CreateScrollFrame(sh)
    sh.body = CreateFrame("Frame", nil, sh.scroll)
    sh.body:SetSize(400, 10)
    sh.scroll:SetScrollChild(sh.body)
    sh.cells, sh.heads, sh.hints = {}, {}, {}
    sh.side = CreateFrame("Frame", nil, sh)
    sh.reqCard = UI():CreateCard(sh.side, { title = "Requests" })
    sh.reqCount = UI():CreateCountBadge(sh.reqCard, 16)
    sh.reqRows = {}
    sh.reqEmpty = UI():Text(sh.reqCard, "body", "SUB", { wrap = true })
    sh.upCard = UI():CreateCard(sh.side, { title = "Up for it, fits a place" })
    sh.upChips = {}
    sh.upHint = UI():Text(sh.upCard, "body", "TEXT", { wrap = true })
    sh.note = UI():Text(sh, "body", "SUB", { wrap = true })
    sh:Hide()
    panel.lead = sh
end

---------------------------------------------------------------------------
-- The body's parts (pooled): section heads, member rows, "+n open" lines, cards, item rows, the empty state
---------------------------------------------------------------------------

local ROLE_TITLE = { tank = "Tanks", healer = "Healers", dps = "Damage" }
local MROW_H = 22                -- a member row
local SEG_MAX = 25

local pools = { heads = {}, rows = {}, opens = {}, cards = {}, items = {}, bosses = {} }
local used = {}
GL.pools = pools   -- (tests: the shown member rows, open lines, cards)

local function Take(kind, make)
    used[kind] = (used[kind] or 0) + 1
    local list = pools[kind]
    local f = list[used[kind]]
    if not f then
        f = make()
        list[used[kind]] = f
    end
    f:ClearAllPoints()
    f:Show()
    return f
end

local function HideBody()
    for kind, list in pairs(pools) do
        for _, f in ipairs(list) do f:Hide() end
        used[kind] = 0
    end
    if sh.empty then sh.empty:Hide() end
    if sh.arrange then sh.arrange:Hide() end
    if sh.summary then sh.summary:Hide() end
    sh.note:Hide()
end

local function IsGuest(key)
    local Gd = ns.Guild
    return Gd and Gd.IsInGuild and not Gd:IsInGuild(key)
end

-- The raid-wide buffs nobody in the group brings yet: names (two at most) and the buff records.
local function MissingBuffs(run)
    local Comp = ns.RaidComp
    local out, names = {}, {}
    if not (Comp and Comp.Coverage) then return names, out end
    local members = {}
    for _, d in ipairs(R():GetSlots(run)) do
        if not d.empty and d.class then members[#members + 1] = { key = d.key, c = d.class } end
    end
    for _, e in ipairs(Comp:Coverage(members, "raid")) do
        if #e.providers == 0 then
            out[#out + 1] = e.buff
            if #names < 2 then names[#names + 1] = e.buff.name end
        end
    end
    return names, out
end

-- A section's head: the role's icon, its name and have / want, a hint on the right, a segmented bar under it.
local function NewHead()
    local hd = CreateFrame("Frame", nil, sh.body)
    hd:SetHeight(30)
    hd.icon = hd:CreateTexture(nil, "ARTWORK")
    hd.icon:SetSize(16, 16)
    hd.icon:SetPoint("TOPLEFT", 0, -2)
    hd.title = UI():Text(hd, "emph", "TEXT")
    hd.title:SetPoint("LEFT", hd.icon, "RIGHT", 7, 0)
    hd.hint = UI():Text(hd, "small", "GOLD", { justify = "RIGHT" })
    hd.hint:SetPoint("TOPRIGHT", 0, -4)
    hd.hint:SetWordWrap(false)
    hd.segs = {}
    hd:EnableMouse(true)
    hd:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_TOP") end end)
    hd:SetScript("OnLeave", HideTip)
    return hd
end

local function FillHead(hd, width, icon, title, have, want, hint, tip)
    hd:SetWidth(width)
    if icon then
        hd.icon:Show()
        UI():SetRoleIcon(hd.icon, icon)
    else
        hd.icon:Hide()
    end
    hd.title:ClearAllPoints()
    if icon then hd.title:SetPoint("LEFT", hd.icon, "RIGHT", 7, 0) else hd.title:SetPoint("TOPLEFT", 0, -3) end
    hd.title:SetText(title .. (want and ("  " .. S:Wrap(have >= want and "OK" or "SUB", have .. "/" .. want)) or ""))
    hd.hint:SetText(hint or "")
    hd.hint:SetWidth(max(40, width - (hd.title:GetStringWidth() or 80) - 40))
    hd.tip = tip
    -- the bar: one segment per place (up to 25), filled ones gold
    local n = want and min(want, SEG_MAX) or 0
    local segW = n > 0 and (width - (n - 1) * 2) / n or 0
    for i = 1, max(n, #hd.segs) do
        local t = hd.segs[i]
        if i <= n then
            if not t then
                t = hd:CreateTexture(nil, "ARTWORK")
                hd.segs[i] = t
            end
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", hd, "BOTTOMLEFT", (i - 1) * (segW + 2), 0)
            t:SetSize(segW, 3)
            local filled = i <= floor(have * n / max(want, 1) + 0.5)
            if filled then t:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.85)
            else t:SetColorTexture(S.C.HAIRLINE[1], S.C.HAIRLINE[2], S.C.HAIRLINE[3], 0.12) end
            t:Show()
        elseif t then
            t:Hide()
        end
    end
end

-- A member: the class icon, the class-coloured name, the spec (dim), the leader's crown or a guest tag; a soft wash
-- under the mouse.
local function NewMemberRow()
    local r = CreateFrame("Frame", nil, sh.body)
    r:SetHeight(MROW_H)
    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(S.C.HOVER[1], S.C.HOVER[2], S.C.HOVER[3], S.C.HOVER[4])
    r.hl:Hide()
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("LEFT", 2, 0)
    r.name = UI():Text(r, "body", "TEXT")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.spec = UI():Text(r, "small", "SUB")
    r.spec:SetPoint("RIGHT", -4, 0)
    r.mark = r:CreateTexture(nil, "OVERLAY")
    r.mark:SetSize(12, 12)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        self.hl:Show()
        if self.key then UI():SetTextTooltip(self, self.tip or { UI():ColoredName(self.key) }, "ANCHOR_TOP") end
    end)
    r:SetScript("OnLeave", function(self)
        self.hl:Hide()
        HideTip()
    end)
    return r
end

local function FillMember(r, width, key, class, opts)
    opts = opts or {}
    r:SetWidth(width)
    r.key = key
    if class then
        r.icon:Show()
        UI():ClassIcon(r.icon, class)
    else
        r.icon:Hide()
    end
    local guest = key and IsGuest(key)
    local spec = key and R():GetSpecLabel(key)
    r.spec:SetText(opts.lead and "" or (guest and S:Wrap("SUB", "guest") or (spec or "")))
    r.name:SetText(UI():ColoredName(key, class))
    r.name:SetPoint("RIGHT", r.spec, "LEFT", -6, 0)
    r.mark:ClearAllPoints()
    if opts.lead then
        r.mark:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
        r.mark:SetPoint("RIGHT", -4, 0)
        r.mark:Show()
    else
        r.mark:Hide()
    end
    r.tip = { UI():ColoredName(key, class), opts.lead and "Leads the group" or (guest and "Guest: not in the guild")
        or spec }
end

-- "+n open": the places still free in a section, one quiet line (not n empty boxes).
local function NewOpenLine()
    local o = CreateFrame("Frame", nil, sh.body)
    o:SetHeight(MROW_H)
    o.icon = o:CreateTexture(nil, "ARTWORK")
    o.icon:SetSize(14, 14)
    o.icon:SetPoint("LEFT", 3, 0)
    o.icon:SetDesaturated(true)
    o.icon:SetAlpha(0.5)
    o.text = UI():Text(o, "body", "SUB")
    o.text:SetPoint("LEFT", o.icon, "RIGHT", 7, 0)
    return o
end

---------------------------------------------------------------------------
-- Roster: a section per role, its players as slim rows in columns, what is still open on one line
---------------------------------------------------------------------------

local function LayoutRoster(run, width)
    local slots = R():GetSlots(run)
    local want = R():GetWant(run)
    local cols = width >= 380 and 3 or 2
    local gap = 10
    local colW = floor((width - (cols - 1) * gap) / cols)
    local y = 0
    local missingNames = MissingBuffs(run)
    for _, role in ipairs(R().ROLES) do
        local list, open = {}, 0
        for _, d in ipairs(slots) do
            if d.role == role then
                if d.empty then open = open + 1 else list[#list + 1] = d end
            end
        end
        local w = want[role] or 0
        if #list > 0 or w > 0 then
            local hint, tip
            if role == "dps" and #missingNames > 0 and run.k == "raid" then
                hint = "nobody brings " .. tconcat(missingNames, ", ")
                tip = { "Raid buffs nobody in the group brings yet", tconcat(missingNames, ", ") }
            end
            local hd = Take("heads", NewHead)
            hd:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, -y)
            FillHead(hd, width, role, ROLE_TITLE[role], #list, w, hint, tip)
            y = y + 36
            local i = 0
            for _, d in ipairs(list) do
                i = i + 1
                local r = Take("rows", NewMemberRow)
                local col, row = (i - 1) % cols, floor((i - 1) / cols)
                r:SetPoint("TOPLEFT", sh.body, "TOPLEFT", col * (colW + gap), -(y + row * MROW_H))
                FillMember(r, colW, d.key, d.class, { lead = d.owner })
            end
            if open > 0 then
                i = i + 1
                local o = Take("opens", NewOpenLine)
                local col, row = (i - 1) % cols, floor((i - 1) / cols)
                o:SetPoint("TOPLEFT", sh.body, "TOPLEFT", col * (colW + gap), -(y + row * MROW_H))
                o:SetWidth(colW)
                UI():SetRoleIcon(o.icon, role)
                o.text:SetText(S:Wrap("SUB", "+" .. open .. " open"))
            end
            y = y + math.ceil(i / cols) * MROW_H + 14
        end
    end
    return y
end

---------------------------------------------------------------------------
-- Reserves: who reserved what, by boss; an empty state until they are open
---------------------------------------------------------------------------

local function EmptyState(width, opts)
    if not sh.empty then sh.empty = UI():CreateEmptyState(sh.body, opts) end
    sh.empty:SetParent(sh.body)
    sh.empty:SetContent(opts)
    if sh.empty.SetBoxWidth then sh.empty:SetBoxWidth(min(width, 380)) end
    sh.empty:ClearAllPoints()
    sh.empty:SetPoint("TOP", sh.body, "TOP", 0, -24)
    sh.empty:Show()
    return (sh.empty:GetHeight() or 160) + 40
end

local function NewItemRow()
    local r = CreateFrame("Frame", nil, sh.body)
    r:SetHeight(26)
    r.bg = UI():Fill(r, "CARD", "BACKGROUND")
    r.bg:SetAlpha(0.55)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(20, 20)
    r.icon:SetPoint("LEFT", 4, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.name = UI():Text(r, "body", "TEXT")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 7, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.who = UI():Text(r, "small", "TEXT", { justify = "RIGHT" })
    r.who:SetPoint("RIGHT", -7, 0)
    r.who:SetWordWrap(false)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        if self.itemID and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.itemID)
            GameTooltip:Show()
        end
    end)
    r:SetScript("OnLeave", HideTip)
    return r
end

local function NewBossHead()
    local b = UI():Text(sh.body, "caps", "GOLD")
    return b
end

local function LayoutReserves(run, width)
    local RS = ns.Reserves
    if run.lo ~= "sr" then
        return EmptyState(width, { glyph = UI().ICON.reserve or UI().ICON.team, title = "No soft reserves",
            text = "This group's loot: " .. (G().LootText(run) or "rolls") .. ". Edit the group to use soft reserves." })
    end
    if not (RS and RS.IsOpen and RS:IsOpen()) then
        local GR = ns.GroupRules
        local canStart = IsInRaid and IsInRaid() and not (GR and GR.GetSession and GR:GetSession())
        return EmptyState(width, { glyph = UI().ICON.reserve or UI().ICON.team, title = "Reserves open with the raid session",
            text = (run.lr or 1) .. (run.lr == 2 and " items" or (run.lr == 3 and " items" or " item")) .. " each. "
                .. (canStart and "Start the session now and everyone can reserve." or
                    "Start it from ··· once the group is a raid, or from the pop-up when you arrive."),
            action = canStart and { text = "Start raid session", onClick = function() DUI():StartSession() end } or nil })
    end
    local L = RS:Get()
    local by = RS:ByItem()
    -- (the group's own players: who of them has a reserve)
    local missing, done, total = {}, 0, 0
    for _, d in ipairs(R():GetSlots(run)) do
        if not d.empty then
            total = total + 1
            if #RS:Of(d.key) > 0 then done = done + 1 else missing[#missing + 1] = d.key end
        end
    end
    table.sort(missing)
    -- the summary: how many reserved, who hasn't
    if not sh.summary then
        sh.summary = CreateFrame("Frame", nil, sh.body)
        sh.summary:SetHeight(40)
        sh.summary.bg = UI():Fill(sh.summary, "CARD", "BACKGROUND")
        UI():AddEdges(sh.summary, "BORDER")
        sh.summary.big = UI():Text(sh.summary, "title", "GOLD")
        sh.summary.big:SetPoint("LEFT", 12, 0)
        sh.summary.text = UI():Text(sh.summary, "small", "SUB", { wrap = true })
        sh.summary.text:SetPoint("LEFT", sh.summary.big, "RIGHT", 12, 0)
    end
    local sm = sh.summary
    sm:SetParent(sh.body)
    sm:ClearAllPoints()
    sm:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, 0)
    sm:SetWidth(width)
    sm.big:SetText(done .. "/" .. total)
    local names = {}
    for i, k in ipairs(missing) do
        if i > 5 then names[#names + 1] = "+" .. (#missing - 5) break end
        names[#names + 1] = UI():ColoredName(k)
    end
    sm.text:SetWidth(width - (sm.big:GetStringWidth() or 40) - 36)
    sm.text:SetText("have reserved (" .. (L and L.n or 1) .. " each)" .. (#missing > 0 and ("\nStill to reserve: "
        .. tconcat(names, ", ")) or "\nEveryone has reserved."))
    sm:Show()
    local y = 50
    -- by boss
    local any = false
    local rk = L and L.rk
    for _, boss in ipairs(rk and RS:Bosses(rk) or {}) do
        local rows = {}
        for _, id in ipairs(boss.items or {}) do
            if by[id] then rows[#rows + 1] = id end
        end
        if #rows > 0 then
            any = true
            local bh = Take("bosses", NewBossHead)
            bh:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 2, -(y + 4))
            bh:SetText((boss.name or "?"):upper())
            y = y + 20
            for _, id in ipairs(rows) do
                local r = Take("items", NewItemRow)
                r:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, -y)
                r:SetWidth(width)
                r.itemID = id
                r.icon:SetTexture(GetItemIcon and GetItemIcon(id) or 134400)
                r.name:SetText(G().ItemLinkText(id))
                local who = {}
                for _, k in ipairs(by[id]) do who[#who + 1] = UI():ColoredName(k) end
                r.who:SetText(tconcat(who, ", "))
                r.name:SetPoint("RIGHT", r.who, "LEFT", -10, 0)
                y = y + 28
            end
            y = y + 6
        end
    end
    if not any then
        local bh = Take("bosses", NewBossHead)
        bh:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 2, -(y + 4))
        bh:SetText("NOTHING RESERVED YET")
        y = y + 24
    end
    return y
end

---------------------------------------------------------------------------
-- Groups: the parties as cards (Auto-fill's layout), and Arrange the raid
---------------------------------------------------------------------------

local THEME = { [25] = { "Tanks", "Melee", "Melee", "Ranged", "Healers" }, [10] = { "Tanks + melee", "Ranged + healers" } }

local function NewPartyCard()
    local c = CreateFrame("Frame", nil, sh.body)
    c.bg = UI():Fill(c, "CARD", "BACKGROUND")
    UI():AddEdges(c, "BORDER")
    c.title = UI():Text(c, "emph", "GOLD")
    c.title:SetPoint("TOPLEFT", 10, -8)
    c.theme = UI():Text(c, "small", "SUB")
    c.theme:SetPoint("LEFT", c.title, "RIGHT", 7, 0)
    c.rows = {}
    return c
end

-- The spec index Auto-fill places a player by: their known spec, else the first spec of their class for the role
-- they have in the group (a damage place: the class's first damage spec).
local function SpecFor(key, classFile, role)
    local specs = ns.SPECS[classFile] or {}
    local label = R():GetSpecLabel(key)
    for i, sp in ipairs(specs) do
        if sp.label == label then return i end
    end
    for i, sp in ipairs(specs) do
        if (role == "tank" and sp.role == "tank") or (role == "healer" and sp.role == "healer")
            or (role == "dps" and sp.role ~= "tank" and sp.role ~= "healer") then
            return i
        end
    end
    return nil
end

local function LayoutGroups(run, width)
    local Comp = ns.RaidComp
    local members = {}
    for _, d in ipairs(R():GetSlots(run)) do
        if not d.empty and d.class then
            members[#members + 1] = { key = d.key, c = d.class, sp = SpecFor(d.key, d.class, d.role) }
        end
    end
    local size = R():GetSize(run)
    local n = size <= 10 and 2 or 5
    local byKey = (Comp and Comp.AutoFill) and Comp:AutoFill(members, size) or {}
    local groups = {}
    for g = 1, n do groups[g] = {} end
    for key, g in pairs(byKey) do
        if groups[g] then groups[g][#groups[g] + 1] = key end
    end
    local per = n == 2 and 2 or 3
    local gap = 10
    local cw = floor((width - (per - 1) * gap) / per)
    local ch = 30 + 5 * MROW_H + 8
    local y = 0
    for g = 1, n do
        local c = Take("cards", NewPartyCard)
        local col, row = (g - 1) % per, floor((g - 1) / per)
        c:SetPoint("TOPLEFT", sh.body, "TOPLEFT", col * (cw + gap), -(row * (ch + gap)))
        c:SetSize(cw, ch)
        c.title:SetText("Group " .. g)
        c.theme:SetText((THEME[n == 2 and 10 or 25] or {})[g] or "")
        local list = groups[g]
        table.sort(list)
        for i = 1, 5 do
            local r = c.rows[i]
            if not r then
                r = NewMemberRow()
                r:SetParent(c)
                c.rows[i] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", c, "TOPLEFT", 6, -(28 + (i - 1) * MROW_H))
            local key = list[i]
            if key then
                FillMember(r, cw - 12, key, (R():GetClass(key)))
                r:SetAlpha(1)
            else
                r.key = nil
                r:SetWidth(cw - 12)
                r.icon:Hide()
                r.mark:Hide()
                r.spec:SetText("")
                r.name:SetText(S:Wrap("SUB", "empty"))
                r:SetAlpha(0.45)
            end
            r:Show()
        end
        y = max(y, (row + 1) * (ch + gap))
    end
    -- Arrange the raid: moves everyone in the raid into these groups (the raid leader or an assistant)
    if not sh.arrange then
        sh.arrange = UI():CreateSleekButton(sh.body, "Arrange the raid", 140, S.BTN_H, function()
            local plan = {}
            for key, g in pairs(sh.arrangePlan or {}) do plan[key] = g end
            local RI = ns.RaidInvite
            local ok, why = RI and RI.Resort and RI:Resort("group:" .. tostring(runId), plan, "your group")
            if not ok and why then ns:Print("%s", why) end
        end, "primary")
        sh.arrangeHint = UI():Text(sh.body, "small", "SUB", { wrap = true })
    end
    sh.arrangePlan = byKey
    local inRaid = IsInRaid and IsInRaid()
    sh.arrange:SetParent(sh.body)
    sh.arrange:ClearAllPoints()
    sh.arrange:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, -(y + 4))
    sh.arrange:SetEnabled(inRaid and true or false)
    sh.arrange:Show()
    sh.arrangeHint:ClearAllPoints()
    sh.arrangeHint:SetPoint("LEFT", sh.arrange, "RIGHT", 12, 0)
    sh.arrangeHint:SetWidth(width - 160)
    sh.arrangeHint:SetText(inRaid and "Moves everyone in the raid into these groups now, and the ones who join later."
        or "Once the group is a raid, this moves everyone into these groups.")
    sh.arrangeHint:Show()
    return y + S.BTN_H + 12
end

---------------------------------------------------------------------------
-- The side: requests and the members up for it
---------------------------------------------------------------------------

local function ReqRow(i)
    local r = sh.reqRows[i]
    if not r then
        r = CreateFrame("Frame", nil, sh.reqCard)
        r:SetHeight(REQ_H)
        r.line = UI():Rule(r, { layer = "BORDER", bottom = 0 })
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(26, 26)
        r.icon:SetPoint("LEFT", 0, 0)
        r.name = UI():Text(r, "emph", "TEXT")
        r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, 4)
        r.what = UI():Text(r, "small", "SUB", { wrap = true })
        r.what:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
        r.no = UI():CreateSleekButton(r, "", 24, 24, nil, "secondary")
        r.no:SetPoint("RIGHT", 0, 0)
        r.no.x = r.no:CreateTexture(nil, "ARTWORK")
        r.no.x:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
        r.no.x:SetSize(14, 14)
        r.no.x:SetPoint("CENTER")
        r.yes = UI():CreateSleekButton(r, "Accept", 64, 24, nil, "primary")
        r.yes:SetPoint("RIGHT", r.no, "LEFT", -5, 0)
        r.state = UI():Text(r, "small", "SUB")
        r.state:SetPoint("RIGHT", r.no, "LEFT", -8, 0)
        sh.reqRows[i] = r
    end
    return r
end

local function LayoutSide(run, x, y, height)
    sh.side:ClearAllPoints()
    -- (on the hero's right edge: both hang from the sheet's right side)
    sh.side:SetPoint("TOPRIGHT", sh, "TOPRIGHT", -PAD, y)
    sh.side:SetSize(SIDE_W, height)
    sh.side:Show()
    local inner = SIDE_W - 28
    local reqs = R():GetRequests(run.id)
    local hintsFor = G().RequestHints(run)
    local card = sh.reqCard
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", sh.side, "TOPLEFT", 0, 0)
    card:SetWidth(SIDE_W)
    if sh.reqCount then
        sh.reqCount:ClearAllPoints()
        sh.reqCount:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -10)
        if sh.reqCount.SetCount then sh.reqCount:SetCount(#reqs) end
    end
    local yy = 38
    for i, q in ipairs(reqs) do
        if i > 4 then break end
        local r = ReqRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -yy)
        r:SetWidth(inner)
        local classFile = R():GetClass(q.key)
        UI():ClassIcon(r.icon, classFile)
        local tags = {}
        if IsGuest(q.key) then tags[#tags + 1] = "guest" end
        if q.gf then tags[#tags + 1] = "Group Finder" end
        r.name:SetText(UI():ColoredName(q.key, classFile) .. (#tags > 0 and S:Wrap("SUB", "  " .. tconcat(tags, " · ")) or ""))
        local bits = { R():GetSpecLabel(q.key) or R().ROLE_LABEL[q.r] }
        if q.b then bits[#bits + 1] = S:Wrap("GOLD", G().STAR .. " BiS here") end
        local h = hintsFor(q.key, classFile)
        if h then bits[#bits + 1] = h end
        r.what:SetWidth(inner - 34 - 112)
        r.what:SetText(tconcat(bits, S:Wrap("SUB", " · ")))
        local key = q.key
        if q.st == "invited" then
            r.yes:Hide()
            r.state:SetText("Invited")
            r.state:Show()
        else
            r.state:Hide()
            r.yes:Show()
            r.yes:SetScript("OnClick", function() R():Accept(run.id, key) end)
        end
        r.no:SetScript("OnClick", function() R():Decline(run.id, key) end)
        r:Show()
        yy = yy + REQ_H
    end
    for i = min(#reqs, 4) + 1, #sh.reqRows do sh.reqRows[i]:Hide() end
    sh.reqEmpty:ClearAllPoints()
    sh.reqEmpty:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -40)
    sh.reqEmpty:SetWidth(inner)
    sh.reqEmpty:SetShown(#reqs == 0)
    sh.reqEmpty:SetText("Nobody has asked yet. Guildies up for this get a ping; share the group in chat for the rest.")
    if #reqs == 0 then yy = yy + 40 end
    card:SetHeight(yy + 8)
    -- up for it, fits a place
    local up = sh.upCard
    up:ClearAllPoints()
    up:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -10)
    up:SetWidth(SIDE_W)
    local open = R():GetOpenRoles(run)
    local asking = {}
    for _, q in ipairs(reqs) do asking[q.key] = true end
    local fitting = {}
    for _, e in ipairs(R():GetUpForRun()) do
        local ok = false
        for role in pairs(e.roles) do if open[role] then ok = true end end
        local kindOk = (e.kinds or { dungeon = true })[R():GetKind(run)]
        local saved = false
        for _, rk in ipairs(run.k == "raid" and run.a or {}) do
            if R():IsSavedToRaid(e.key, rk) then saved = true end
        end
        if ok and kindOk and not asking[e.key] and not saved then fitting[#fitting + 1] = e end
    end
    local cx, cy = 14, 38
    local _, missing = MissingBuffs(run)
    local fills
    for i = 1, max(#fitting, #sh.upChips) do
        local e = fitting[i]
        local chip = sh.upChips[i]
        if e then
            if not chip then
                chip = CreateFrame("Frame", nil, up)
                chip:SetHeight(26)
                chip.p = G().NewPersonChip(chip, nil)
                chip.p:SetPoint("LEFT", 0, 0)
                chip.inv = UI():CreateSleekButton(chip, "Invite", 56, 22, nil, "secondary")
                sh.upChips[i] = chip
            end
            G().FillChip(chip.p, e)
            chip.inv:ClearAllPoints()
            chip.inv:SetPoint("LEFT", chip.p, "RIGHT", 4, 0)
            local done = G().state.invited[e.key]
            chip.inv:SetText(done and "Invited" or "Invite")
            chip.inv:SetEnabled(not done and not e.grouped)
            local key = e.key
            chip.inv:SetScript("OnClick", function()
                if R():InviteFree(key) then
                    G().state.invited[key] = true
                    GL:Refresh()
                end
            end)
            local w = chip.p:GetWidth() + 62
            chip:SetWidth(w)
            if cx + w > SIDE_W - 14 then cx, cy = 14, cy + 30 end
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", up, "TOPLEFT", cx, -cy)
            chip:Show()
            cx = cx + w + 6
            -- the first one who brings a buff the group lacks
            if not fills and ns.RaidComp then
                local cls = R():GetClass(e.key)
                for _, b in ipairs(missing) do
                    if not fills and ns.RaidComp:Provides(b.key, cls, nil) then
                        fills = ns.Util.ShortName(e.key) .. " is a " .. (UI().ClassName and UI():ClassName(cls) or
                            (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls]) or cls) .. ": brings "
                            .. S:Wrap("GOLD", b.name) .. "."
                    end
                end
            end
        elseif chip then
            chip:Hide()
        end
    end
    if #fitting > 0 then cy = cy + 30 end
    sh.upHint:ClearAllPoints()
    sh.upHint:SetPoint("TOPLEFT", up, "TOPLEFT", 14, -cy)
    sh.upHint:SetWidth(SIDE_W - 28)
    sh.upHint:SetText(#fitting == 0 and S:Wrap("SUB", "Nobody up for this right now fits an open place.") or (fills or ""))
    cy = cy + (sh.upHint:GetStringHeight() or 14) + 12
    up:SetHeight(cy)
end

---------------------------------------------------------------------------
-- Refresh, open, close
---------------------------------------------------------------------------

function GL:Refresh()
    if not sh or not sh:IsShown() then return end
    local run = MyGroup()
    if not run then
        self:Close()
        return
    end
    -- (the sheet's own size: the hero and the columns hang from it)
    local panel = DUI():GetPanel()
    local width = sh:GetWidth() or (panel and panel:GetWidth()) or 780
    local height = sh:GetHeight() or (panel and panel:GetHeight()) or 540
    if width < 300 then width = 780 end
    if height < 300 then height = 540 end
    -- the hero
    local h = sh.hero
    local file, l, r, t, b = R():GetGroupArt(run, width - 2 * PAD, HERO_H, 1)
    h.art:SetTexture(file)
    if file then h.art:SetTexCoord(l, r, t, b) end
    local function face(f, key)
        local probe = key and { k = run.k, a = { key }, d = run.d } or run
        local ic, il, ir, it, ib = R():GetGroupIcon(probe)
        if ic then f:SetPhoto(ic) end
        if f.photo and il then f.photo:SetTexCoord(il, ir, it, ib) end
    end
    local two = run.k == "raid" and run.a and run.a[2]
    face(h.ring, run.k == "raid" and run.a[1] or nil)
    h.ring2:SetShown(two and true or false)
    if two then face(h.ring2, run.a[2]) end
    h.kicker:SetText(("Your group · " .. G().WhenText(run)):upper())
    h.name:SetText(R():GetName(run))
    h.size:ClearAllPoints()
    h.size:SetPoint("LEFT", h.name, "RIGHT", 10, 0)
    h.size:SetPill("mute", tostring(R():GetSize(run)))
    h.loot:ClearAllPoints()
    h.loot:SetPoint("LEFT", h.size, "RIGHT", 6, 0)
    h.loot:SetShown(run.k == "raid")
    if run.k == "raid" then h.loot:SetPill("bis", G().LootText(run)) end
    G().FillMeters(h.meters, run, nil)
    local filled = 0
    for _, d in ipairs(R():GetSlots(run)) do if not d.empty then filled = filled + 1 end end
    local RS = ns.Reserves
    local reserved = 0
    if RS and RS.IsOpen and RS:IsOpen() then
        for _ in pairs(RS:ByItem()) do reserved = reserved + 1 end
    end
    local labels = { roster = "Roster  " .. S:Wrap("SUB", filled .. "/" .. R():GetSize(run)),
                     reserves = "Reserves" .. (run.lo == "sr" and ("  " .. S:Wrap("SUB", tostring(reserved))) or ""),
                     groups = "Groups",
                     message = "LFG message" .. ((ns.GroupsLFG and ns.GroupsLFG:IsRepeating()) and ("  " .. S:Wrap("OK", "on")) or "") }
    local x = 96
    for _, b in ipairs(h.tabs) do
        b:SetLabel(labels[b.key])
        b:SetActive(tab == b.key)
        b:SetShown(b.key ~= "reserves" or run.k == "raid")
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", h, "BOTTOMLEFT", x, 6)
        if b:IsShown() then x = x + b:GetWidth() + 14 end
    end
    h.back:ClearAllPoints()
    h.back:SetPoint("BOTTOMLEFT", h, "TOPLEFT", 0, 1)
    h.back:Hide()
    -- the body
    local top = -8 - HERO_H - 12
    local bodyW = width - 2 * PAD - SIDE_W - 16
    local bodyH = height + top - 10
    sh.scroll:ClearAllPoints()
    sh.scroll:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, top)
    sh.scroll:SetSize(bodyW, bodyH)
    sh.body:SetWidth(bodyW - 12)
    HideBody()
    if sh.arrangeHint then sh.arrangeHint:Hide() end
    local used
    if tab ~= "message" and ns.GroupsMessage then ns.GroupsMessage:Hide() end
    if tab == "message" and ns.GroupsMessage then
        used = ns.GroupsMessage:Layout(sh.body, bodyW - 12)
    elseif tab == "reserves" and run.k == "raid" then
        used = LayoutReserves(run, bodyW - 12)
    elseif tab == "groups" then
        used = LayoutGroups(run, bodyW - 12)
    else
        tab = "roster"
        used = LayoutRoster(run, bodyW - 12)
    end
    sh.body:SetHeight(max(used, 10))
    LayoutSide(run, width - PAD - SIDE_W, top, bodyH)
end

function GL:Open(id, startTab)
    local panel = DUI():GetPanel()
    if not panel then return end
    runId = id or (R():GetMyGroup() and R():GetMyGroup().id)
    if not MyGroup() then return end
    if not sh then Create(panel) end
    tab = startTab or "roster"
    sh:Open()
    panel.layout.toolbar:Hide()
    if panel.tabsRow then panel.tabsRow:Hide() end
    self:Refresh()
end

function GL:Close()
    runId = nil
    local panel = DUI():GetPanel()
    if sh and sh:IsShown() then sh:Close() end
    if panel and not (ns.GroupsCard.state.sheet) then
        panel.layout.toolbar:Show()
        if panel.tabsRow then panel.tabsRow:Show() end
    end
    if DUI().Refresh then DUI():Refresh() end
end

function GL:IsOpen() return sh ~= nil and sh:IsShown() end
function GL:Get() return sh end
function GL:SetTab(key)
    tab = key
    self:Refresh()
end
