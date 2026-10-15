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
-- The roster
---------------------------------------------------------------------------

local ROLE_TITLE = { tank = "Tanks", healer = "Healers", dps = "Damage" }

-- The raid-wide buffs nobody in the group brings yet: names (three at most) and the buff records.
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

local function IsGuest(key)
    local Gd = ns.Guild
    return Gd and Gd.IsInGuild and not Gd:IsInGuild(key)
end

local function LayoutRoster(run, width)
    local slots = R():GetSlots(run)
    local want, have = R():GetWant(run), {}
    for _, d in ipairs(slots) do
        if not d.empty then have[d.role] = (have[d.role] or 0) + 1 end
    end
    local per = max(2, floor((width + CELL_GAP) / (104 + CELL_GAP)))
    local cw = floor((width - (per - 1) * CELL_GAP) / per)
    local y, ci, hi = 0, 0, 0
    local missingNames = MissingBuffs(run)
    for _, role in ipairs(R().ROLES) do
        local list = {}
        for _, d in ipairs(slots) do
            if d.role == role then list[#list + 1] = d end
        end
        if #list > 0 or (want[role] or 0) > 0 then
            hi = hi + 1
            local hd = sh.heads[hi]
            if not hd then
                hd = CreateFrame("Frame", nil, sh.body)
                hd:SetHeight(24)
                hd.icon = hd:CreateTexture(nil, "ARTWORK")
                hd.icon:SetSize(15, 15)
                hd.icon:SetPoint("LEFT", 0, 0)
                hd.title = UI():Text(hd, "emph", "TEXT")
                hd.title:SetPoint("LEFT", hd.icon, "RIGHT", 7, 0)
                hd.hint = UI():Text(hd, "body", "GOLD")
                hd.hint:SetPoint("RIGHT", 0, 0)
                sh.heads[hi] = hd
            end
            hd:ClearAllPoints()
            hd:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, -y)
            hd:SetWidth(width)
            UI():SetRoleIcon(hd.icon, role)
            hd.title:SetText(ROLE_TITLE[role] .. "  " .. S:Wrap("SUB", (have[role] or 0) .. "/" .. (want[role] or 0)))
            local hint = ""
            if role == "dps" and #missingNames > 0 and run.k == "raid" then
                hint = "nobody brings yet: " .. tconcat(missingNames, ", ")
                hd.tipText = hint
            elseif role ~= "dps" and (want[role] or 0) > (have[role] or 0) then
                local n = want[role] - (have[role] or 0)
                hint = n .. " more " .. (role == "tank" and (n == 1 and "tank" or "tanks") or (n == 1 and "healer" or "healers"))
            end
            hd.hint:SetText(hint)
            hd.hint:SetWidth(max(60, width - (hd.title:GetStringWidth() or 80) - 40))
            hd.hint:SetWordWrap(false)
            hd.hint:SetJustifyH("RIGHT")
            hd:Show()
            y = y + 28
            for i, d in ipairs(list) do
                ci = ci + 1
                local c = sh.cells[ci] or NewCell(sh.body)
                sh.cells[ci] = c
                c:ClearAllPoints()
                c:SetPoint("TOPLEFT", sh.body, "TOPLEFT", ((i - 1) % per) * (cw + CELL_GAP),
                    -(y + floor((i - 1) / per) * (CELL_H + CELL_GAP)))
                c:SetWidth(cw)
                if d.empty then
                    c.key = nil
                    c.icon:Hide()
                    c.name:ClearAllPoints()
                    c.name:SetPoint("CENTER")
                    c.name:SetJustifyH("CENTER")
                    c.name:SetText(S:Wrap("GOLD", "open"))
                    c.bg:SetAlpha(0.35)
                    UI():SetEdgeColor(c, GOLD[1], GOLD[2], GOLD[3], 0.6)
                    c.tag:Hide()
                    c.crown:Hide()
                else
                    c.key = d.key
                    c.icon:Show()
                    UI():ClassIcon(c.icon, d.class)
                    c.name:ClearAllPoints()
                    c.name:SetPoint("LEFT", c.icon, "RIGHT", 6, 0)
                    c.name:SetPoint("RIGHT", -24, 0)
                    c.name:SetJustifyH("LEFT")
                    c.name:SetText(UI():ColoredName(d.key, d.class))
                    c.bg:SetAlpha(1)
                    local lead = d.owner
                    UI():SetEdgeColor(c, lead and GOLD[1] or S.C.EDGE[1], lead and GOLD[2] or S.C.EDGE[2],
                        lead and GOLD[3] or S.C.EDGE[3], lead and 0.8 or S.C.EDGE[4])
                    c.crown:SetShown(lead and true or false)
                    local guest = IsGuest(d.key)
                    c.tag:SetShown(guest and not lead)
                    c.tag:SetText(S:Wrap("SUB", "guest"))
                    c.tipLine = lead and "Leads the group" or (guest and "Guest: not in the guild" or nil)
                end
                c:Show()
            end
            y = y + math.ceil(#list / per) * (CELL_H + CELL_GAP) + 8
        end
    end
    for i = ci + 1, #sh.cells do sh.cells[i]:Hide() end
    for i = hi + 1, #sh.heads do sh.heads[i]:Hide() end
    return y
end

-- Reserves so far: the items with who reserved them.
local function LayoutReserves(run, width)
    local RS = ns.Reserves
    local lines = {}
    if run.lo ~= "sr" then
        lines[1] = "This group isn't on soft reserves: " .. G().LootText(run) .. "."
    elseif not (RS and RS.IsOpen and RS:IsOpen()) then
        lines[1] = "Soft reserves open when the raid session starts: " .. (run.lr or 1) .. " each. Start it from ··· "
            .. "or the pop-up when you arrive."
    else
        local by = RS:ByItem()
        local ids = {}
        for id in pairs(by) do ids[#ids + 1] = id end
        tsort(ids)
        for _, id in ipairs(ids) do
            local names = {}
            for _, k in ipairs(by[id]) do names[#names + 1] = UI():ColoredName(k) end
            lines[#lines + 1] = G().ItemLinkText(id) .. "  " .. tconcat(names, ", ")
        end
        if #lines == 0 then lines[1] = "Nobody has reserved anything yet." end
    end
    sh.note:SetParent(sh.body)
    sh.note:ClearAllPoints()
    sh.note:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, -4)
    sh.note:SetWidth(width)
    sh.note:SetText(tconcat(lines, "\n"))
    sh.note:Show()
    return (sh.note:GetStringHeight() or 20) + 8
end

-- The parties as Auto-fill would place the group (25: tanks, melee, melee, ranged, healers; 10: two groups).
local function LayoutGroups(run, width)
    local Comp = ns.RaidComp
    local members = {}
    for _, d in ipairs(R():GetSlots(run)) do
        if not d.empty and d.class then members[#members + 1] = { key = d.key, c = d.class } end
    end
    local byKey = (Comp and Comp.AutoFill) and Comp:AutoFill(members, R():GetSize(run)) or {}
    local groups = {}
    for key, g in pairs(byKey) do
        groups[g] = groups[g] or {}
        groups[g][#groups[g] + 1] = key
    end
    local n = R():GetSize(run) <= 10 and 2 or 5
    local cw = floor((width - (n - 1) * CELL_GAP) / n)
    local ci = 0
    for i = 1, #sh.heads do sh.heads[i]:Hide() end
    local maxRows = 0
    for g = 1, n do
        local list = groups[g] or {}
        tsort(list)
        for r = 1, 5 do
            ci = ci + 1
            local c = sh.cells[ci] or NewCell(sh.body)
            sh.cells[ci] = c
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", sh.body, "TOPLEFT", (g - 1) * (cw + CELL_GAP), -(22 + (r - 1) * (CELL_H + 4)))
            c:SetWidth(cw)
            local key = list[r]
            c.crown:Hide()
            c.tag:Hide()
            c.name:ClearAllPoints()
            c.name:SetPoint("LEFT", c.icon, "RIGHT", 6, 0)
            c.name:SetPoint("RIGHT", -6, 0)
            c.name:SetJustifyH("LEFT")
            if key then
                c.key = key
                c.icon:Show()
                UI():ClassIcon(c.icon, R():GetClass(key))
                c.name:SetText(UI():ColoredName(key, R():GetClass(key)))
                c.bg:SetAlpha(1)
            else
                c.key = nil
                c.icon:Hide()
                c.name:SetText("")
                c.bg:SetAlpha(0.3)
            end
            UI():SetEdgeColor(c, unpack(S.C.EDGE))
            c:Show()
        end
        maxRows = 5
    end
    for i = ci + 1, #sh.cells do sh.cells[i]:Hide() end
    sh.note:SetParent(sh.body)
    sh.note:ClearAllPoints()
    sh.note:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, 0)
    sh.note:SetWidth(width)
    sh.note:SetText("Group 1 to " .. n .. " as Auto-fill places them (Raids > Groups moves players in the raid itself).")
    sh.note:Show()
    return 22 + maxRows * (CELL_H + 4)
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
    sh.note:Hide()
    for _, c in ipairs(sh.cells) do c:Hide() end
    for _, hd in ipairs(sh.heads) do hd:Hide() end
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
