if DisasterZoneBoot and DisasterZoneBoot.Run("UI/TotemsUI.lua", ...) then return end -- DisasterZone: totem planner.
-- The Totem planner window (Core/Totems.lua): shamans as rows, the four elements as columns, then Heroism and Earth
-- Shield (layout A of dev/art/casc/totem_mockup, the Blessings planner's sibling). The window, its tool banner and the
-- shared parts (cards, cells, chips, the rule, dragging) are the class planner window's (UI/PlannerWindow.lua).
--   banner     the raid's art, "Totems", who assigns, where, how many shamans and groups they cover; Auto-assign,
--              More, Report
--   boss tabs  All bosses, then this raid's bosses (a gold dot: totems change for that boss); outside a raid a
--              picker on the right chooses the raid. A boss tab shows only what changes for that fight.
--   cards      a shaman: spec icon, name (crown: leads), talents. Drag a card onto a "No shaman" row to move them
--              to that raid group (leader / assistant, out of combat)
--   group      "Group 2 · Melee" and its players' class circles: totems only reach the shaman's own party
--   cells      click: pick a totem (Air: twist Windfury too), right-click: none, wheel: the next one; a gold count =
--              players of the party out of the totem's range
--   no shaman  a raid group nobody covers: what it misses, and a swap to fix it
-- Rows I may not change are dimmed. Open with /dz totems.
local addonName, ns = ...

local TUI = ns:NewModule("TotemsUI")

local floor, max = math.floor, math.max
local strformat = string.format
local tinsert, tconcat = table.insert, table.concat

local W = 760
local GAP = 8
local TABS_H = 24
local GRID_W = 722               -- the Blessings planner's grid (cards to the last cell): both windows line up
local CARD_W, ROW_H, ROW_GAP = 170, 50, 6
local GROUP_X, GROUP_W = CARD_W + GAP, 104
local CELL_X, CELL_W = CARD_W + GAP + GROUP_W + 2, 58
local HERO_X, HERO_W = CELL_X + 4 * CELL_W + 6, 74
local ES_X = HERO_X + HERO_W + 6
local ES_W = GRID_W - ES_X
-- boss changes: a rule across the width ("BOSS CHANGES 2 ---- +"), then chips from the left edge, 4 a line (the
-- Blessings planner's exceptions)
local RULE_H, CHIP_PER, CHIP_H = 22, 4, 36
local CHIP_W = floor((GRID_W - (CHIP_PER - 1) * 6) / CHIP_PER)
local CHIP_PITCH = CHIP_W + 6
-- (y from the body's top: the boss tabs, their line, a boss tab's strip, the column heads)
local TABS_Y, LINE_Y, STRIP_Y, HEAD_Y = 0, TABS_H, TABS_H + 6, TABS_H + 12
local SHAMAN_RGB = { 0.0, 0.44, 0.87 }
local NAME_RGB = { 0.18, 0.55, 0.94 }          -- shaman blue lifted a little for names on dark cards
local CARD_FROM, CARD_TO = { 0.08, 0.17, 0.30, 0.95 }, { 0.12, 0.12, 0.14, 0.95 }
local RED = { 0.88, 0.38, 0.31 }
local GROUP_TEXT = { 0.81, 0.81, 0.83 }
local EJ = "Interface\\EncounterJournal\\UI-EJ-BOSS-"

local UI = ns.UI
local S = ns.Style
local GOLD = S.C.GOLD
local PW = ns.PlannerWindow
local HINT = PW.HINT
local IconText, ColorCode = PW.IconText, PW.ColorCode
local function T() return ns.Totems end

local frame
local bossTab                  -- nil = All bosses, else a boss key

local function ElColor(el) return T().D.ELEMENTS[el].color end

-- "OperaRomulo" -> "Opera Romulo"
local function TabLabel(short) return (short:gsub("(%l)(%u)", "%1 %2")) end

local function GroupLabel(g)
    return strformat("Group %d · %s", g.sub, T().GROUP_KIND[g.kind].label)
end

local function HintLine(text) return { text, HINT[1], HINT[2], HINT[3] } end

-- ---------------------------------------------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------------------------------------------
-- The totems of element el that shaman `name` knows, as radio entries (situational ones under "More").
local function AddTotemChoices(root, name, el, isSet, set)
    local Tm = T()
    local more
    for idx, t in ipairs(Tm.D.TOTEMS[el]) do
        if Tm:Knows(name, el, idx) then
            local parent = root
            if t.extra then
                more = more or root:CreateButton("More")
                parent = more
            end
            local e = parent:CreateRadio(IconText(t.icon) .. " " .. t.short, function() return isSet(idx) end,
                function() set(idx) end)
            e:SetHint(t.fx)
        end
    end
end

local function CellMenu(owner, name, el)
    local Tm = T()
    local elName = Tm.D.ELEMENTS[el].name
    local c = ElColor(el)
    UI:ContextMenu(owner, function(root)
        if bossTab then
            local _, short = Tm:BossName(bossTab)
            root:CreateTitle(strformat("%s%s|r · %s · %s", ColorCode(c[1], c[2], c[3]), elName, name, TabLabel(short or "")))
            local function cur() return Tm:GetBoss(bossTab, name, el) end
            AddTotemChoices(root, name, el, function(idx) local o = cur(); return o and not o.alt and o.i == idx end,
                function(idx) Tm:SetBoss(bossTab, name, el, idx, false) end)
            root:CreateDivider()
            local second = root:CreateButton("Second, on right-click")
            second:SetTitleAndTextTooltip("Second, on right-click", "For a fight with two phases: the bar keeps the "
                .. "All bosses totem on click and puts this one on right-click.")
            AddTotemChoices(second, name, el, function(idx) local o = cur(); return o and o.alt and o.i == idx end,
                function(idx) Tm:SetBoss(bossTab, name, el, idx, true) end)
            root:CreateRadio("Same as All bosses", function() return cur() == nil end,
                function() Tm:SetBoss(bossTab, name, el, 0) end)
            return
        end
        local sub = Tm:SubgroupOf(name)
        root:CreateTitle(strformat("%s%s|r · %s%s", ColorCode(c[1], c[2], c[3]), elName, name,
            sub and (" · group " .. sub) or ""))
        AddTotemChoices(root, name, el, function(idx) return Tm:GetAssign(name, el) == idx end,
            function(idx) Tm:SetAssign(name, el, idx) end)
        root:CreateRadio("None", function() return Tm:GetAssign(name, el) == nil end,
            function() Tm:SetAssign(name, el, 0) end)
        if el == 4 and Tm:Knows(name, 4, Tm.D.WINDFURY[2]) then
            root:CreateDivider()
            local partner = tonumber(Tm.Setting("twistWith", 2)) or 2
            local e = root:CreateCheckbox("Twist Windfury with " .. Tm.D.TOTEMS[4][partner].short,
                function() return Tm:GetTwist(name) end, function()
                    local on = not Tm:GetTwist(name)
                    Tm:SetTwist(name, on)
                    if on then Tm:SetAssign(name, 4, Tm.D.WINDFURY[2]) end
                end)
            e:SetTitleAndTextTooltip("Twisting", "Drop Windfury, then " .. Tm.D.TOTEMS[4][partner].short .. ": the "
                .. "party keeps Windfury on their weapons for 10 seconds after. The bar tells when to drop it again.")
        end
        root:CreateDivider()
        local only = root:CreateButton("Only for one boss")
        for _, b in ipairs(Tm:Bosses()) do
            only:CreateButton(b.name, function() TUI:SetBossTab(b.key) end)
        end
    end)
end

local function HeroMenu(owner, name)
    local Tm = T()
    UI:ContextMenu(owner, function(root)
        root:CreateTitle(strformat("%s · %s", Tm:HeroName(), name))
        for _, h in ipairs(Tm.D.HERO_WHEN) do
            root:CreateRadio(h.long, function() return Tm:GetHero(name) == h.key end, function() Tm:SetHero(name, h.key) end)
        end
    end)
end

local function ESMenu(owner, name)
    local Tm = T()
    UI:ContextMenu(owner, function(root)
        root:CreateTitle(strformat("%s · %s", Tm:ESName(), name))
        local roster = Tm:Roster()
        local any = false
        for _, m in ipairs(roster) do
            if m.tank then
                if not any then root:CreateTitle("Tanks") end
                any = true
                local r, g, b = UI:ClassColor(m.class)
                root:CreateRadio(ColorCode(r, g, b) .. m.name .. "|r", function() return Tm:GetES(name) == m.name end,
                    function() Tm:SetES(name, m.name) end)
            end
        end
        local everyone = root:CreateButton("Someone else")
        for _, m in ipairs(roster) do
            local r, g, b = UI:ClassColor(m.class)
            everyone:CreateRadio(ColorCode(r, g, b) .. m.name .. "|r", function() return Tm:GetES(name) == m.name end,
                function() Tm:SetES(name, m.name) end)
        end
        root:CreateRadio("Nobody", function() return Tm:GetES(name) == nil end, function() Tm:SetES(name, nil) end)
    end)
end

local function SwapMenu(owner, sub)
    local Tm = T()
    UI:ContextMenu(owner, function(root)
        root:CreateTitle("Move a shaman to group " .. sub)
        local roster = Tm:Roster()
        local groups = Tm:Groups(roster)
        local best = Tm:SwapSuggestion(sub, roster)
        local list = {}
        for _, s in ipairs(Tm:Shamans(roster)) do
            if s.name == best then tinsert(list, 1, s) else list[#list + 1] = s end
        end
        for _, s in ipairs(list) do
            local from = Tm:SubgroupOf(s.name, roster)
            local g = from and groups[from]
            local e = root:CreateButton(s.name .. (s.name == best and "  |cffffd100(best)|r" or ""),
                function() Tm:MoveShaman(s.name, sub) end)
            if g then
                local alone = #g.shamans == 1
                e:SetHint(alone and ("group " .. from .. " loses theirs") or ("from group " .. from))
            end
            e:SetEnabled(Tm:CanMove())
        end
        if not Tm:CanMove() then root:CreateTitle("Only the leader or an assistant, out of combat") end
    end)
end

local function MoreMenu(root)
    local Tm = T()
    if Tm:IsShaman() then
        local e = root:CreateCheckbox("Anyone may assign me", function() return Tm.Setting("free", false) end,
            function() ns.DB:SetSetting("totems.free", not Tm.Setting("free", false)) end)
        e:SetTitleAndTextTooltip("Anyone may assign me", "Any shaman or player can change your totems, not only "
            .. "the leader and assistants.")
        if ns.TotemBar then
            root:CreateDivider()
            root:CreateTitle("Totem bar")
            for _, o in ipairs(ns.TotemBar.LAYOUTS) do
                root:CreateRadio(o.text, function() return Tm.Setting("layout", "vertical") == o.value end,
                    function() ns.DB:SetSetting("totems.layout", o.value) end)
            end
        end
    end
    root:CreateDivider()
    local c = root:CreateButton("Clear all", function() Tm:ClearAll() end)
    c:SetEnabled(Tm:CanEditAny())
    root:CreateButton("Ask the shamans again", function() Tm.Hello(true) end)
    if Tm:IsShaman() then
        root:CreateButton("Settings", function()
            if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("settings") end
            if ns.SettingsUI then ns.SettingsUI:SelectSection("totems") end
        end)
    end
end

local function RaidMenu(owner)
    local Tm = T()
    UI:ContextMenu(owner, function(root)
        root:CreateTitle("Plan for")
        for _, r in ipairs(Tm:Raids()) do
            root:CreateRadio(r.name, function() return Tm:RaidKey() == r.key end, function()
                ns.DB:SetSetting("totems.raid", r.key)
                bossTab = nil
                TUI:Refresh()
            end)
        end
    end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Drag a shaman onto a group without one
-- ---------------------------------------------------------------------------------------------------------------
local drag

local function EmptyRowUnderCursor()
    for _, row in ipairs(frame.rows) do
        if row:IsShown() and row.emptySub and row:IsMouseOver() then return row end
    end
    return nil
end

local function StartDrag(name, icon)
    if not T():CanMove() then return end
    if not drag then drag = PW.NewDrag(frame, 30) end
    drag:Begin(icon, name, EmptyRowUnderCursor)
end

local function EndDrag()
    if not drag then return end
    local row, name = drag:Finish()
    if row then T():MoveShaman(name, row.emptySub) end
end
TUI.EndDrag = EndDrag

-- ---------------------------------------------------------------------------------------------------------------
-- Building (in the window's body; y from the body's top)
-- ---------------------------------------------------------------------------------------------------------------
local function BuildHeader(c)
    local h = {}
    local function cap(text, x)
        local fs = UI:Text(c, "caps", "SUB", { shadow = true, text = text })
        fs:SetPoint("TOPLEFT", c, "TOPLEFT", x + 2, -(HEAD_Y + 2))
        return fs
    end
    h.shaman = cap("Shaman", 0)
    h.group = cap("Group", GROUP_X)
    h.els = {}
    for el = 1, 4 do
        local fs = UI:Text(c, "body", ElColor(el), { shadow = true, justify = "CENTER", width = CELL_W })
        fs:SetPoint("TOPLEFT", c, "TOPLEFT", CELL_X + (el - 1) * CELL_W, -HEAD_Y)
        fs:SetText(T().D.ELEMENTS[el].name)
        h.els[el] = fs
    end
    h.hero = cap("Heroism", HERO_X + 4)
    h.es = cap("Earth shield", ES_X + 4)
    return h
end

local function NewCell(row, el)
    local cell = PW.NewCell(row, CELL_W - 4, ROW_H, 1)
    cell:SetPoint("TOPLEFT", row, "TOPLEFT", CELL_X + (el - 1) * CELL_W + 2, 0)
    local c = ElColor(el)
    cell.line = UI:Fill(cell, { c[1], c[2], c[3], 0.85 }, "BORDER")
    cell.line:ClearAllPoints()
    cell.line:SetPoint("BOTTOMLEFT", 1, 2)
    cell.line:SetPoint("BOTTOMRIGHT", -1, 2)
    cell.line:SetHeight(2)
    -- the twist partner (or a boss's second totem) in a frame of its own above the cell, its icon inside its edge
    cell.twinEdge = CreateFrame("Frame", nil, cell)
    cell.twinEdge:SetFrameLevel(cell:GetFrameLevel() + 4)
    cell.twinEdge:SetSize(17, 17)
    cell.twinEdge:SetPoint("BOTTOMRIGHT", cell.icon, "BOTTOMRIGHT", 7, -6)
    PW.SetEdge(cell.twinEdge, c, 1)
    cell.twin = cell.twinEdge:CreateTexture(nil, "ARTWORK")
    cell.twin:SetPoint("TOPLEFT", 1, -1)
    cell.twin:SetPoint("BOTTOMRIGHT", -1, 1)
    PW.Crop(cell.twin)
    -- a boss change: gold inset, the phase digit in the corner
    cell.gold = CreateFrame("Frame", nil, cell)
    cell.gold:SetAllPoints()
    PW.SetEdge(cell.gold, GOLD, 1)
    cell.phase = UI:Text(cell, "caps", "GOLD", { shadow = true })
    cell.phase:SetPoint("TOPRIGHT", cell, "TOPRIGHT", -4, -3)
    cell.miss:SetFrameLevel(cell:GetFrameLevel() + 6)
    cell.el = el
    cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    cell:EnableMouseWheel(true)
    cell:SetScript("OnClick", function(self, button)
        local name = row.name
        if not name or not T():CanEdit(name) then return end
        if button == "RightButton" then
            if bossTab then T():SetBoss(bossTab, name, el, 0) else T():SetAssign(name, el, 0) end
        else
            CellMenu(self, name, el)
        end
    end)
    cell:SetScript("OnMouseWheel", function(self, delta)
        local name = row.name
        if not name or bossTab or not T():CanEdit(name) then return end
        local n = #T().D.TOTEMS[el]
        local cur = T():GetAssign(name, el) or 0
        for _ = 1, n + 1 do
            cur = (cur - delta) % (n + 1)
            local t = T():Totem(el, cur)
            if cur == 0 or (T():Knows(name, el, cur) and t and not t.extra) then break end
        end
        T():SetAssign(name, el, cur)
    end)
    cell:SetScript("OnEnter", function(self) PW.HoverEdge(self, true, row.name and T():CanEdit(row.name)) end)
    cell:SetScript("OnLeave", function(self) PW.HoverEdge(self, false) end)
    PW.Tip(cell, function(self) return TUI:CellTip(self, row.name) end)
    return cell
end

-- A dark tile of the row (Heroism, Earth Shield)
local function NewTile(row, x, w)
    local b = CreateFrame("Button", nil, row)
    b:SetSize(w, ROW_H)
    b:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
    b.bg = UI:Fill(b, PW.CELL_BG, "BACKGROUND")
    PW.SetEdge(b, PW.CELL_EDGE)
    return b
end

local function NewRow(c)
    local row = CreateFrame("Frame", nil, c)
    row:SetHeight(ROW_H)
    row:SetWidth(GRID_W)
    -- the card
    local card = PW.NewCard(row, { w = CARD_W, h = ROW_H, from = CARD_FROM, to = CARD_TO, bar = SHAMAN_RGB,
        name = NAME_RGB })
    card:SetPoint("TOPLEFT")
    card:RegisterForDrag("LeftButton")
    card:SetScript("OnDragStart", function()
        if row.name then StartDrag(row.name, card.spec:GetTexture()) end
    end)
    card:SetScript("OnDragStop", EndDrag)
    PW.Tip(card, function(self) return TUI:CardTip(self, row.name) end)
    row.card = card
    -- the group
    row.group = UI:Text(row, "small", GROUP_TEXT, { shadow = true })
    row.group:SetPoint("TOPLEFT", row, "TOPLEFT", GROUP_X, -7)
    row.circles = {}
    for k = 1, 5 do
        local t = row:CreateTexture(nil, "ARTWORK")
        t:SetSize(15, 15)
        t:SetPoint("TOPLEFT", row, "TOPLEFT", GROUP_X + (k - 1) * 17, -24)
        row.circles[k] = t
    end
    row.groupHit = CreateFrame("Frame", nil, row)
    row.groupHit:SetPoint("TOPLEFT", row, "TOPLEFT", GROUP_X, 0)
    row.groupHit:SetSize(GROUP_W, ROW_H)
    PW.Tip(row.groupHit, function(self) return TUI:GroupTip(self, row.sub) end)
    -- the elements
    row.cells = {}
    for el = 1, 4 do row.cells[el] = NewCell(row, el) end
    -- Heroism (stacked: the icon, the timing under it; centred so any label fits the narrow column)
    local hero = NewTile(row, HERO_X, HERO_W)
    hero.icon = hero:CreateTexture(nil, "ARTWORK")
    hero.icon:SetSize(22, 22)
    hero.icon:SetPoint("TOP", hero, "TOP", 0, -6)
    PW.Crop(hero.icon)
    hero.text = UI:Text(hero, "caps", "TEXT", { shadow = true, justify = "CENTER" })
    hero.text:SetPoint("TOP", hero.icon, "BOTTOM", 0, -3)
    hero:RegisterForClicks("LeftButtonUp")
    hero:SetScript("OnClick", function(self)
        if row.name and not bossTab and T():CanEdit(row.name) then HeroMenu(self, row.name) end
    end)
    PW.Tip(hero, function(self)
        if not row.name then return nil end
        local h = T():GetHero(row.name)
        local long = ""
        for _, x in ipairs(T().D.HERO_WHEN) do if x.key == h then long = x.long end end
        local lines = { long, "The whole raid gets it; Exhaustion stops a second one for 10 minutes, so one shaman casts it." }
        if self.clash then tinsert(lines, { "Also set to cast: " .. self.clash, 1, 0.45, 0.4 }) end
        if T():CanEdit(row.name) and not bossTab then tinsert(lines, HintLine("Click: when")) end
        return T():HeroName(), lines
    end)
    row.hero = hero
    -- Earth Shield
    local es = NewTile(row, ES_X, ES_W)
    es:SetClipsChildren(true)
    es.icon = es:CreateTexture(nil, "ARTWORK")
    es.icon:SetSize(24, 24)
    es.icon:SetPoint("LEFT", es, "LEFT", 8, 0)
    PW.Crop(es.icon)
    es.name = UI:Text(es, "body", nil, { shadow = true })
    es.name:SetPoint("TOPLEFT", es, "TOPLEFT", 38, -10)
    es.name:SetPoint("RIGHT", es, "RIGHT", -6, 0)
    es.sub = UI:Text(es, "caps", "SUB", { shadow = true })
    es.sub:SetPoint("TOPLEFT", es, "TOPLEFT", 38, -27)
    es.sub:SetPoint("RIGHT", es, "RIGHT", -6, 0)
    es:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    es:SetScript("OnClick", function(self, button)
        if not row.name or bossTab or not self.can or not T():CanEdit(row.name) then return end
        if button == "RightButton" then T():SetES(row.name, nil) else ESMenu(self, row.name) end
    end)
    PW.Tip(es, function(self)
        if not row.name or not self.can then return nil end
        local t = T():GetES(row.name)
        local lines = { t and strformat("%s keeps it on %s.", row.name, t) or "Nobody yet." }
        if T():CanEdit(row.name) and not bossTab then tinsert(lines, HintLine("Click: pick · Right-click: nobody")) end
        return T():ESName(), lines
    end)
    row.es = es
    -- a group without a shaman
    local e = CreateFrame("Frame", nil, row)
    e:SetAllPoints()
    e.bg = UI:Fill(e, { RED[1], RED[2], RED[3], 0.05 }, "BACKGROUND")
    PW.SetEdge(e, { 0.35, 0.23, 0.21, 1 })
    e.title = UI:Text(e, "emph", RED, { shadow = true })
    e.title:SetPoint("TOPLEFT", e, "TOPLEFT", 10, -7)
    e.title:SetText("No shaman")
    e.swap = UI:CreateSleekButton(e, "Suggest a swap", 112, 19, function(self) SwapMenu(self, row.emptySub) end)
    e.swap:SetPoint("TOPLEFT", e, "TOPLEFT", 9, -25)
    PW.Tip(e.swap, function()
        return "Suggest a swap", { "Moves a shaman into this group, swapping them with one of its players. Or "
            .. "drag a shaman's card onto this row.", T():CanMove() and "" or { "Only the leader or an assistant, out of "
            .. "combat.", 1, 0.55, 0.45 } }
    end)
    e.ghosts = {}
    for el = 1, 4 do
        local g = e:CreateTexture(nil, "ARTWORK")
        g:SetSize(26, 26)
        g:SetPoint("CENTER", row, "TOPLEFT", CELL_X + (el - 0.5) * CELL_W, -ROW_H / 2)
        PW.Crop(g)
        g:SetDesaturated(true)
        g:SetVertexColor(0.5, 0.5, 0.5)
        g:SetAlpha(0.8)
        e.ghosts[el] = g
    end
    e.misses = UI:Text(e, "small", { 0.84, 0.6, 0.56 }, { shadow = true, wrap = true, width = GRID_W - HERO_X - 12 })
    e.misses:SetPoint("TOPLEFT", e, "TOPLEFT", HERO_X + 4, -10)
    e.misses:SetMaxLines(2)
    row.emptyFace = e
    return row
end

-- A boss change, as the Blessings planner's exception chips: the boss and who, then the swap (UI/PlannerWindow.lua).
local function NewChip(c)
    local chip = PW.NewSwapChip(c, CHIP_W, CHIP_H)
    chip:SetScript("OnClick", function(self, button)
        local e = self.change
        if not e then return end
        if button == "RightButton" then
            for _, n in ipairs(e.names) do
                if T():CanEdit(n) then T():SetBoss(e.boss, n, e.el, 0) end
            end
        else
            TUI:SetBossTab(e.boss)
        end
    end)
    chip:SetScript("OnEnter", function(self) PW.HoverEdge(self, true, true) end)
    chip:SetScript("OnLeave", function(self) PW.HoverEdge(self, false) end)
    PW.Tip(chip, function(self)
        local e = self.change
        if not e then return nil end
        local Tm = T()
        local what = Tm:TotemName(e.el, e.i)
        local lines = { strformat("%s: %s %s%s.", e.bossName, what, e.alt and "on right-click (a second phase)"
            or "instead", (e.was and not e.alt) and (" of " .. Tm.D.TOTEMS[e.el][e.was].short) or "") }
        lines[#lines + 1] = tconcat(e.names, ", ")
        lines[#lines + 1] = HintLine("Click: open the boss · Right-click: remove")
        return "Boss change", lines
    end)
    return chip
end

local function BuildBossStrip(c)
    -- (a boss tab's header: portrait, what this tab is, how the bar uses a second totem)
    local s = CreateFrame("Frame", nil, c)
    s:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -STRIP_Y)
    s:SetWidth(GRID_W)
    s:SetHeight(50)
    s.bg = UI:Fill(s, { 0.094, 0.094, 0.11, 1 }, "BACKGROUND")
    PW.SetEdge(s, PW.CELL_EDGE)
    s.artBox = CreateFrame("Frame", nil, s)
    s.artBox:SetSize(76, 38)
    s.artBox:SetPoint("LEFT", s, "LEFT", 6, 0)
    PW.SetEdge(s.artBox, GOLD, 1)
    s.art = s.artBox:CreateTexture(nil, "ARTWORK")
    s.art:SetAllPoints()
    s.art:SetTexCoord(0, 1, 0.1, 0.85)
    s.title = UI:Text(s, "emph", "GOLD", { shadow = true })
    s.title:SetPoint("TOPLEFT", s, "TOPLEFT", 94, -8)
    s.title:SetText("Changes for this boss only")
    s.sub = UI:Text(s, "small", "SUB", { shadow = true })
    s.sub:SetPoint("TOPLEFT", s, "TOPLEFT", 94, -27)
    s.sub:SetText("The rest follows All bosses. Faded = no change.")
    s.k1 = UI:Text(s, "small", "TEXT", { shadow = true })
    s.k1:SetPoint("TOPLEFT", s, "TOPLEFT", 520, -10)
    s.k1:SetText(S:Wrap("GOLD", "1") .. "  click on the bar")
    s.k2 = UI:Text(s, "small", "TEXT", { shadow = true })
    s.k2:SetPoint("TOPLEFT", s, "TOPLEFT", 520, -27)
    s.k2:SetText(S:Wrap("GOLD", "2") .. "  right-click: a second phase")
    s:Hide()
    return s
end

-- the "+" on the boss changes' rule: pick a boss
local ADD = { icon = "plus", onClick = function(self)
        UI:ContextMenu(self, function(root)
            root:CreateTitle("Change totems for one boss")
            for _, b in ipairs(T():Bosses()) do root:CreateButton(b.name, function() TUI:SetBossTab(b.key) end) end
        end)
    end,
    tip = { "Change totems for one boss", "Resistance totems, Tremor against fear: pick a boss and change only what "
        .. "differs. The bar switches when you fight it." } }

local function Build(f, c)
    frame = f
    f.tabs = {}
    f.tabLine = UI:Rule(c, { top = LINE_Y, right = max(0, f.layout.innerW - GRID_W) })
    local raidBtn = CreateFrame("Button", nil, c)
    raidBtn:SetHeight(TABS_H)
    raidBtn.text = UI:Text(raidBtn, "small", "SUB", { shadow = true })
    raidBtn.text:SetPoint("RIGHT", raidBtn, "RIGHT", -14, 0)
    raidBtn.chev = raidBtn:CreateTexture(nil, "OVERLAY")
    raidBtn.chev:SetSize(8, 8)
    raidBtn.chev:SetPoint("RIGHT", raidBtn, "RIGHT", -2, 0)
    if UI.SetChevronUp then UI:SetChevronUp(raidBtn.chev, false) end
    raidBtn.chev:SetVertexColor(S:Color("SUB"))
    raidBtn:SetPoint("TOPRIGHT", c, "TOPLEFT", GRID_W, -TABS_Y)
    raidBtn:SetScript("OnClick", function(self) if self.pick then RaidMenu(self) end end)
    raidBtn:SetScript("OnEnter", function(self) if self.pick then self.text:SetTextColor(S:Color("GOLD")) end end)
    raidBtn:SetScript("OnLeave", function(self) self.text:SetTextColor(S:Color("SUB")) end)
    PW.Tip(raidBtn, function(self)
        return "Raid", { self.pick and "Pick the raid to plan for." or "The raid you are in." }
    end)
    f.raidBtn = raidBtn
    f.head = BuildHeader(c)
    f.bossStrip = BuildBossStrip(c)
    f.rows = {}
    f.chips = {}
    f.rule = PW.NewRule(c, "Boss changes", GRID_W)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Tooltips: title, lines
-- ---------------------------------------------------------------------------------------------------------------
function TUI:CellTip(cell, name)
    if not name then return nil end
    local Tm = T()
    local el = cell.el
    local idx, alt, why = Tm:Effective(name, el, bossTab)
    local t = idx and Tm:Totem(el, idx)
    local lines = {}
    if t then lines[#lines + 1] = t.fx end
    if why == "twist" then
        lines[#lines + 1] = { "Twisted with " .. Tm.D.TOTEMS[4][alt].short .. ": Windfury stays on weapons 10 s after.", 0.75, 0.62, 1 }
    elseif why == "boss1" and alt then
        lines[#lines + 1] = { strformat("Right-click on the bar: %s (All bosses)", Tm.D.TOTEMS[el][alt].short),
            GOLD[1], GOLD[2], GOLD[3] }
    elseif why == "boss2" then
        lines[#lines + 1] = { strformat("Right-click on the bar: %s", Tm.D.TOTEMS[el][alt].short), GOLD[1], GOLD[2], GOLD[3] }
    end
    local st = cell.state
    if st and st.total > 0 and st.have > 0 then
        lines[#lines + 1] = strformat("%d of %d in the party have it", st.have, st.total)
        for _, m in ipairs(st.missing) do lines[#lines + 1] = { "Out of range: " .. m.name, 1, 0.55, 0.45 } end
    end
    if Tm:CanEdit(name) then
        lines[#lines + 1] = HintLine(bossTab and "Click: change for this boss · Right-click: as All bosses"
            or "Click: pick · Right-click: none · Wheel: next")
    else
        lines[#lines + 1] = HintLine("Only " .. name .. ", the leader or an assistant can change it.")
    end
    local elName = Tm.D.ELEMENTS[el].name
    return strformat("%s · %s: %s", name, elName, t and Tm:TotemName(el, idx) or "nothing"), lines
end

function TUI:CardTip(card, name)
    if not name then return nil end
    local Tm = T()
    local s = Tm.shamans[name]
    local lines = { Tm:SpecOf(name) .. " Shaman" }
    if s then
        if s.noAddon then
            lines[#lines + 1] = { "No DisasterZone or ShamanPower: the leader plans for them, they read it in chat (Report).", 1, 0.7, 0.4 }
        end
        if s.free then lines[#lines + 1] = "Anyone may assign them" end
    end
    if Tm:CanMove() then lines[#lines + 1] = HintLine("Drag onto a \"No shaman\" row to move them there") end
    return name, lines
end

function TUI:GroupTip(owner, sub)
    if not sub then return nil end
    local Tm = T()
    local roster = Tm:Roster()
    local lines = {}
    for _, m in ipairs(roster) do
        if m.subgroup == sub then
            local r, g, b = UI:ClassColor(m.class)
            lines[#lines + 1] = { m.name .. (m.tank and " · tank" or ""), r, g, b }
        end
    end
    lines[#lines + 1] = HintLine("Totems only reach this party.")
    return "Group " .. sub, lines
end

-- ---------------------------------------------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------------------------------------------
-- The banner's picture: the raid I am in, else the raid planned for (demo: Serpentshrine).
local function ArtKey()
    if T():IsDemo() then return "SerpentshrineCavern" end
    local id = tonumber((select(8, GetInstanceInfo())))
    if id and ns.ItemDB and ns.ItemDB.ItemKeyOf and ns.ItemDB:ItemKeyOf(id) then return id end
    return T():RaidKey() or "other"
end

function TUI:SetBossTab(key)
    bossTab = key
    self:Refresh()
end

function TUI:BossTab() return bossTab end

local function LayoutTabs(c)
    local Tm = T()
    local bosses = Tm:Bosses()
    local list = { { key = nil, label = "All bosses" } }
    for _, b in ipairs(bosses) do list[#list + 1] = { key = b.key, label = TabLabel(b.short), changed = Tm:BossHasChanges(b.key) } end
    -- the raid picker on the right
    local rb = frame.raidBtn
    local inRaid = not Tm:IsDemo() and select(2, GetInstanceInfo()) == "raid"
    rb.pick = not inRaid and not Tm:IsDemo()
    rb.text:SetText(Tm:RaidName())
    rb.chev:SetShown(rb.pick)
    rb:SetWidth((rb.text:GetStringWidth() or 100) + (rb.pick and 18 or 4))
    local limit = GRID_W - rb:GetWidth() - 16
    local x = 0
    local rest = {}
    for i, e in ipairs(list) do
        local tab = frame.tabs[i]
        if not tab then
            tab = UI:CreateUnderlineTab(c, e.label, nil, "page")
            tab.dot = tab:CreateTexture(nil, "OVERLAY")
            tab.dot:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
            tab.dot:SetSize(4, 4)
            frame.tabs[i] = tab
        end
        if tab.SetLabel then tab:SetLabel(e.label) else tab:SetText(e.label) end
        local key = e.key
        tab:SetScript("OnClick", function() TUI:SetBossTab(key) end)
        local w = tab:GetWidth()
        if x + w > limit and i > 1 then
            tab:Hide()
            rest[#rest + 1] = e
        else
            tab:ClearAllPoints()
            tab:SetPoint("TOPLEFT", c, "TOPLEFT", x, -TABS_Y)
            tab:Show()
            if tab.SetActive then tab:SetActive(bossTab == key) end
            tab.dot:ClearAllPoints()
            tab.dot:SetPoint("TOPRIGHT", tab, "TOPRIGHT", 1, -4)
            tab.dot:SetShown(e.changed or false)
            x = x + w + 4
        end
    end
    for i = #list + 1, #frame.tabs do frame.tabs[i]:Hide() end
    -- the bosses that don't fit: one "More" tab with a menu (it names the boss while one of them is open)
    if #rest > 0 then
        if not frame.moreTab then
            frame.moreTab = UI:CreateUnderlineTab(c, "More", nil, "page")
        end
        local mt = frame.moreTab
        local active
        for _, e in ipairs(rest) do if e.key == bossTab then active = e end end
        if mt.SetLabel then mt:SetLabel(active and active.label or "More") else mt:SetText(active and active.label or "More") end
        mt:ClearAllPoints()
        mt:SetPoint("TOPLEFT", c, "TOPLEFT", x, -TABS_Y)
        mt:SetScript("OnClick", function(self)
            UI:ContextMenu(self, function(root)
                for _, e in ipairs(rest) do
                    root:CreateRadio(e.label .. (e.changed and "  |cffffd100•|r" or ""), function() return bossTab == e.key end,
                        function() TUI:SetBossTab(e.key) end)
                end
            end)
        end)
        if mt.SetActive then mt:SetActive(active ~= nil) end
        mt:Show()
    elseif frame.moreTab then
        frame.moreTab:Hide()
    end
end

-- One shaman's row (the cells, Heroism, Earth Shield) for now.
local function FillShaman(row, s, roster, inGroup, heroCasters)
    local Tm = T()
    local name = s.name
    row.name = name
    row.emptySub = nil
    row.emptyFace:Hide()
    row.card:Show()
    row.hero:Show()
    row.es:Show()
    local edit = Tm:CanEdit(name)
    local card = row.card
    card.name:SetText(name)
    card.crown:SetShown(Tm:IsLeader(name))
    local spec = Tm:SpecOf(name)
    card.spec:SetTexture(Tm.D.SPEC_ICONS[spec] or Tm.D.SPEC_ICONS.Enhancement)
    local line = Tm:TalentLine(name)
    if s.noAddon then line = "|cffd9a066No totem addon|r" end
    card.line:SetText(line ~= "" and line or (spec .. " Shaman"))
    card:SetAlpha(edit and 1 or 0.8)
    for el = 1, 4 do
        local cell = row.cells[el]
        cell:Show()
        local idx, alt, why = Tm:Effective(name, el, bossTab)
        local o = bossTab and Tm:GetBoss(bossTab, name, el)
        local shownIdx = idx
        if why == "boss2" then shownIdx = alt end
        cell.icon:SetShown(shownIdx ~= nil)
        cell.empty:SetShown(shownIdx == nil)
        if shownIdx then cell.icon:SetTexture(Tm:TotemIcon(el, shownIdx)) end
        -- boss tab: changed cells gold with their phase, the rest faded
        local faded = bossTab and not o
        cell.icon:SetAlpha(faded and 0.4 or (edit and 1 or 0.75))
        cell.icon:SetDesaturated(faded and true or false)
        cell.gold:SetShown(o ~= nil and o ~= false)
        local twin = (why == "twist") and alt or nil
        cell.twinEdge:SetShown(twin ~= nil)
        if twin then cell.twin:SetTexture(Tm:TotemIcon(el, twin)) end
        local digit = ""
        if o then
            local hasAlt = false
            for e2 = 1, 4 do
                local o2 = Tm:GetBoss(bossTab, name, e2)
                if o2 and o2.alt then hasAlt = true end
            end
            digit = o.alt and "2" or (hasAlt and "1" or "")
        end
        cell.phase:SetText(digit)
        -- live: the party out of range of it
        local st = (inGroup and idx and not bossTab) and Tm:PartyState(name, el, idx, roster) or nil
        cell.state = st
        cell.miss:SetCount(st and #st.missing or 0)
    end
    -- Heroism
    local hero = row.hero
    local _, heroIcon = Tm:HeroSpell()
    hero.icon:SetTexture(heroIcon)
    local hk = Tm:GetHero(name)
    local htext = "Pull"
    for _, x in ipairs(Tm.D.HERO_WHEN) do if x.key == hk then htext = x.text end end
    hero.text:SetText(htext)
    hero.icon:ClearAllPoints()
    if htext == "" then hero.icon:SetPoint("CENTER", hero, "CENTER", 0, 0)
    else hero.icon:SetPoint("TOP", hero, "TOP", 0, -6) end
    hero.icon:SetAlpha(bossTab and 0.4 or 1)
    hero.text:SetAlpha(bossTab and 0.55 or 1)
    hero.icon:SetDesaturated(not Tm:HeroCasts(hk) or bossTab ~= nil)
    if hk == "none" then hero.icon:SetAlpha(0.3) end
    -- two shamans set to cast it: only one counts (red edge on both, like two auras in one party)
    hero.clash = nil
    if Tm:HeroCasts(hk) then
        for _, other in ipairs(heroCasters) do
            if other ~= name then hero.clash = other end
        end
    end
    PW.SetEdge(hero, hero.clash and RED or PW.CELL_EDGE)
    -- Earth Shield
    local es = row.es
    es.can = s.es and true or false
    local target = Tm:GetES(name)
    es.icon:SetShown(es.can)
    es.name:SetShown(es.can)
    es.sub:SetShown(es.can)
    if es.can then
        es.icon:SetTexture(Tm.D.EARTH_SHIELD_ICON)
        es.icon:SetDesaturated(target == nil or bossTab ~= nil)
        es.icon:SetAlpha(bossTab and 0.4 or 1)
        if target then
            local cls, tank = nil, false
            for _, m in ipairs(roster) do
                if m.name == target then
                    cls = m.class
                    if m.tank then tank = true end
                end
            end
            es.name:SetText(target)
            es.name:SetTextColor(UI:ClassColor(cls or "WARRIOR"))
            local charges = inGroup and Tm:ESCharges(target) or nil
            local subText = tank and "tank" or ""
            if charges and charges > 0 then
                subText = (subText ~= "" and (subText .. " · ") or "") .. strformat("%d charge%s", charges, charges == 1 and "" or "s")
            elseif inGroup then
                subText = (subText ~= "" and (subText .. " · ") or "") .. "|cffff8a7anot on them|r"
            end
            es.sub:SetText(subText)
        else
            es.name:SetText("Nobody")
            es.name:SetTextColor(0.55, 0.55, 0.58)
            es.sub:SetText(edit and "click to pick a tank" or "")
        end
        es.name:SetAlpha(bossTab and 0.55 or 1)
        es.sub:SetAlpha(bossTab and 0.55 or 1)
    end
end

-- A raid group nobody covers: what it misses, the totems it would want (faded), and a swap.
local function FillEmpty(row, e)
    local Tm = T()
    row.name = nil
    row.emptySub = e.sub
    row.card:Hide()
    for el = 1, 4 do row.cells[el]:Hide() end
    row.hero:Hide()
    row.es:Hide()
    local f = row.emptyFace
    f:Show()
    f.swap:SetEnabled(Tm:CanMove())
    local needs = Tm.GROUP_KIND[e.g.kind].needs
    for el = 1, 4 do
        local pick
        for _, n in ipairs(needs) do if n[1] == el and not pick then pick = n[2] end end
        if not pick then pick = (el == 3) and 1 or nil end
        f.ghosts[el]:SetShown(pick ~= nil)
        if pick then f.ghosts[el]:SetTexture(Tm:TotemIcon(el, pick)) end
    end
    f.misses:SetText("Misses " .. Tm:MissesText(e.g))
end

function TUI:Refresh()
    if not frame then return end
    local Tm = T()
    local c = frame.body
    local roster = Tm:Roster()
    local shamans = Tm:Shamans(roster)
    local groups, order = Tm:Groups(roster)
    if bossTab then
        local ok = false
        for _, b in ipairs(Tm:Bosses()) do if b.key == bossTab then ok = true end end
        if not ok then bossTab = nil end
    end

    -- banner
    local parts = {}
    if bossTab then
        local name = Tm:BossName(bossTab)
        local n = 0
        local s = Tm.Store()
        for sh, row in pairs((s and s.boss[bossTab]) or {}) do
            if Tm.shamans[sh] then for _ in pairs(row) do n = n + 1 end end
        end
        parts[#parts + 1] = name
        parts[#parts + 1] = n == 0 and "no changes yet" or strformat("%d totem%s change", n, n == 1 and "" or "s")
    else
        parts[#parts + 1] = Tm:RaidName()
        parts[#parts + 1] = strformat("%d player%s", #roster, #roster == 1 and "" or "s")
        parts[#parts + 1] = strformat("%d shaman%s", #shamans, #shamans == 1 and "" or "s")
        if IsInRaid() or Tm:IsDemo() then
            local covered = 0
            for _, sub in ipairs(order) do if #groups[sub].shamans > 0 then covered = covered + 1 end end
            parts[#parts + 1] = strformat("%d of %d groups covered", covered, #order)
        end
    end
    PW:Head(frame, Tm, tconcat(parts, " · "), ArtKey(), not bossTab)

    LayoutTabs(c)
    frame.bossStrip:SetShown(bossTab ~= nil)
    if bossTab then
        local name = Tm:BossName(bossTab)
        frame.bossStrip.art:SetTexture(EJ .. name)
    end

    -- header (under the boss strip on a boss tab)
    local headY = HEAD_Y + (bossTab and 58 or 0)
    local h = frame.head
    local function placeCap(fs, x) fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", c, "TOPLEFT", x + 2, -(headY + 2)) end
    placeCap(h.shaman, 0)
    placeCap(h.group, GROUP_X)
    placeCap(h.hero, HERO_X + 4)
    placeCap(h.es, ES_X + 4)
    for el = 1, 4 do
        h.els[el]:ClearAllPoints()
        h.els[el]:SetPoint("TOPLEFT", c, "TOPLEFT", CELL_X + (el - 1) * CELL_W, -headY)
    end
    h.hero:SetText(Tm:HeroName():upper())

    -- rows: each raid group in order, its shamans, or a "No shaman" row (raids only); shamans outside the roster last
    local entries = {}
    local placed = {}
    local raid = IsInRaid() or Tm:IsDemo()
    for _, sub in ipairs(order) do
        local g = groups[sub]
        local any = false
        for _, s in ipairs(shamans) do
            if Tm:SubgroupOf(s.name, roster) == sub then
                entries[#entries + 1] = { shaman = s, sub = sub, g = g }
                placed[s.name] = true
                any = true
            end
        end
        if not any and raid and not bossTab then entries[#entries + 1] = { empty = true, sub = sub, g = g } end
    end
    for _, s in ipairs(shamans) do
        if not placed[s.name] then entries[#entries + 1] = { shaman = s } end
    end

    local rowsTop = headY + 20
    local inGroup = Tm:InGroup()
    local heroCasters = Tm:HeroCasters(roster)
    for i, e in ipairs(entries) do
        local row = frame.rows[i]
        if not row then
            row = NewRow(c)
            frame.rows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -(rowsTop + (i - 1) * (ROW_H + ROW_GAP)))
        row:Show()
        row.sub = e.sub
        -- the group column (both kinds)
        if e.g then
            row.group:SetText(GroupLabel(e.g))
            for k = 1, 5 do
                local m = e.g.members[k]
                row.circles[k]:SetShown(m ~= nil)
                if m then
                    UI:ClassIcon(row.circles[k], m.class)
                    row.circles[k]:SetAlpha((e.shaman and m.name == e.shaman.name) and 0.45 or 1)
                end
            end
        else
            row.group:SetText(inGroup and "Not in the group" or "Solo")
            for k = 1, 5 do row.circles[k]:Hide() end
        end
        if e.empty then FillEmpty(row, e) else FillShaman(row, e.shaman, roster, inGroup, heroCasters) end
    end
    for i = #entries + 1, #frame.rows do
        frame.rows[i]:Hide()
        frame.rows[i].name = nil
        frame.rows[i].emptySub = nil
    end
    local rowsH = max(1, #entries) * (ROW_H + ROW_GAP)
    local empty = frame.empty
    empty:SetShown(#entries == 0)
    if #entries == 0 then
        empty:ClearAllPoints()
        empty:SetPoint("TOP", c, "TOPLEFT", GRID_W / 2, -(headY + 4))
        rowsH = floor(empty:GetHeight() + 0.5) + 4
    end
    for _, fs in pairs({ h.shaman, h.group, h.hero, h.es }) do fs:SetShown(#entries > 0) end
    for el = 1, 4 do h.els[el]:SetShown(#entries > 0) end

    -- bottom (All bosses tab): the rule ("BOSS CHANGES 2 ---- +"), then a chip per change under it, 4 a line
    local ey = rowsTop + rowsH
    local changes = (not bossTab) and Tm:BossChanges() or {}
    local showStrip = not bossTab and #shamans > 0
    local rule = frame.rule
    rule:SetShown(showStrip)
    rule:ClearAllPoints()
    rule:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -(ey + 2))
    rule:SetCount(#changes > 0 and #changes or nil)
    rule:SetAdd((showStrip and Tm:CanEditAny()) and ADD or nil)
    local cy = ey + RULE_H + 8
    for i, e in ipairs(changes) do
        local chip = frame.chips[i]
        if not chip then
            chip = NewChip(c)
            frame.chips[i] = chip
        end
        local col, line = (i - 1) % CHIP_PER, floor((i - 1) / CHIP_PER)
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", c, "TOPLEFT", col * CHIP_PITCH, -(cy + line * (CHIP_H + 6)))
        chip.change = e
        local who = (#e.names == #shamans) and "all" or (#e.names == 1 and e.names[1] or (#e.names .. " shamans"))
        PW.FillSwapChip(chip, e.was and Tm:TotemIcon(e.el, e.was) or nil, Tm:TotemIcon(e.el, e.i), ElColor(e.el),
            TabLabel(e.short), nil, strformat("%s%s · %s", Tm.D.ELEMENTS[e.el].name, e.alt and " phase 2" or "", who))
        chip:SetShown(showStrip)
    end
    for i = #changes + 1, #frame.chips do frame.chips[i]:Hide() end
    local lines = showStrip and math.ceil(#changes / CHIP_PER) or 0
    local bodyH = showStrip and ((lines > 0) and (cy + lines * (CHIP_H + 6) - 6) or (ey + RULE_H)) or ey
    PW:Fit(frame, bodyH)
end

-- ---------------------------------------------------------------------------------------------------------------
-- The window (Open / Close / Toggle / IsShown / GetFrame: UI/PlannerWindow.lua)
-- ---------------------------------------------------------------------------------------------------------------
PW:Install(TUI, {
    name = "DisasterZoneTotems", title = "Totems", width = W, every = 3, event = "TOTEMS_CHANGED",
    core = function() return ns.Totems end,
    autoTip = "Gives every shaman you may change the totems their party wants: Windfury and Strength of Earth for "
        .. "melee (Enhancement twists Grace of Air in), Wrath of Air and Totem of Wrath for casters, Mana Spring for "
        .. "all. Restoration shamans shield a tank each. One shaman casts Heroism for the raid, another backs up.",
    actions = {
        { icon = "more", menu = MoreMenu, tip = "More" },
        { key = "report", icon = "whisper", onClick = function() T():Report() end,
          tip = { "Report", "Posts who drops what, and which groups have no shaman, to the raid (or party) chat." } },
    },
    empty = { icon = "Interface\\Icons\\Spell_Nature_Windfury", title = "No shamans here yet",
        text = "Shamans in your group show up here, with DisasterZone, ShamanPower or no addon at all." },
    build = Build,
})
