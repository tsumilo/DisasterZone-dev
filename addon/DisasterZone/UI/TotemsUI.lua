if DisasterZoneBoot and DisasterZoneBoot.Run("UI/TotemsUI.lua", ...) then return end -- DisasterZone: totem planner.
-- The Totem planner window (Core/Totems.lua): shamans as rows, the four elements as columns, then Heroism and Earth
-- Shield (layout A of dev/art/casc/totem_mockup, the Blessings planner's sibling).
--   banner     the raid's art, "Totems", where, how many shamans and groups they cover; who assigns; Report, More,
--              Auto-assign
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

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format
local tinsert, tconcat = table.insert, table.concat

local W = 760
local PAD, GAP = 10, 8
local BANNER_H = 72
local TABS_H = 24
local GRID_W = 722               -- the Blessings planner's grid (cards to the last cell): both windows line up
local CARD_W, ROW_H, ROW_GAP = 176, 50, 6
local GROUP_X, GROUP_W = CARD_W + GAP, 104
local CELL_X, CELL_W, ICON = CARD_W + GAP + GROUP_W + 2, 58, 32
local HERO_X, HERO_W = CELL_X + 4 * CELL_W + 6, 68
local ES_X = HERO_X + HERO_W + 6
local ES_W = GRID_W - ES_X
-- boss changes: a rule across the width ("BOSS CHANGES 2 ---- +"), then chips from the left edge, 4 a line (the
-- Blessings planner's exceptions)
local RULE_H, CHIP_PER, CHIP_H = 22, 4, 36
local CHIP_W = floor((GRID_W - (CHIP_PER - 1) * 6) / CHIP_PER)
local CHIP_PITCH = CHIP_W + 6
local SHAMAN_RGB = { 0.0, 0.44, 0.87 }
local NAME_RGB = { 0.18, 0.55, 0.94 }          -- shaman blue lifted a little for names on dark cards
local GOLD = { 1, 0.82, 0 }
local GREY = { 0.62, 0.62, 0.64 }
local RED = { 0.88, 0.38, 0.31 }
local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local EJ = "Interface\\EncounterJournal\\UI-EJ-BOSS-"
local INST_ART = { [532] = "kara", [565] = "gruul", [544] = "mag", [548] = "ssc", [550] = "tk", [534] = "hyjal",
    [564] = "bt", [568] = "za", [580] = "swp" }
local RAID_ART = { Karazhan = "kara", GruulsLair = "gruul", MagtheridonsLair = "mag", SerpentshrineCavern = "ssc",
    TempestKeep = "tk", HyjalSummit = "hyjal", BlackTemple = "bt", ZulAman = "za", SunwellPlateau = "swp" }

local function UI() return ns.UI end
local function T() return ns.Totems end
local function EUI() return ns.EventUI end

local frame
local bossTab                  -- nil = All bosses, else a boss key

local function Text(parent, size, color, layer, font)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    local path, _, flags = fs:GetFont()
    if path and size then fs:SetFont(path, size, flags) end
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 1)
    return fs
end

local function Fill(tex, r, g, b, a)
    tex:SetTexture(WHITE8)
    tex:SetVertexColor(r, g, b, a or 1)
    return tex
end

local function Edge(f, r, g, b, a)
    if not f.edges then UI():AddEdges(f) end
    UI():SetEdgeColor(f, r, g, b, a)
end

local function ClassCircle(tex, cls)
    local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls]
    tex:SetTexture(CIRCLES)
    if c then tex:SetTexCoord(c[1], c[2], c[3], c[4]) end
end

local function Tip(owner, title, lines)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(title)
    for _, l in ipairs(lines or {}) do
        if type(l) == "table" then GameTooltip:AddLine(l[1], l[2] or 1, l[3] or 1, l[4] or 1, true)
        else GameTooltip:AddLine(l, 0.85, 0.85, 0.85, true) end
    end
    GameTooltip:Show()
end

local function IconText(tex, size)
    return strformat("|T%s:%d:%d:0:0:64:64:5:59:5:59|t", tostring(tex), size or 16, size or 16)
end

local function Hex(r, g, b) return strformat("|cff%02x%02x%02x", r * 255, g * 255, b * 255) end

local function ElColor(el) return T().D.ELEMENTS[el].color end

-- "OperaRomulo" -> "Opera Romulo"
local function TabLabel(short) return (short:gsub("(%l)(%u)", "%1 %2")) end

local function GroupLabel(g)
    return strformat("Group %d · %s", g.sub, T().GROUP_KIND[g.kind].label)
end

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
    UI():ContextMenu(owner, function(root)
        if bossTab then
            local _, short = Tm:BossName(bossTab)
            root:CreateTitle(strformat("%s%s|r · %s · %s", Hex(c[1], c[2], c[3]), elName, name, TabLabel(short or "")))
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
        root:CreateTitle(strformat("%s%s|r · %s%s", Hex(c[1], c[2], c[3]), elName, name, sub and (" · group " .. sub) or ""))
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
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(strformat("%s · %s", Tm:HeroName(), name))
        for _, h in ipairs(Tm.D.HERO_WHEN) do
            root:CreateRadio(h.long, function() return Tm:GetHero(name) == h.key end, function() Tm:SetHero(name, h.key) end)
        end
    end)
end

local function ESMenu(owner, name)
    local Tm = T()
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(strformat("%s · %s", Tm:ESName(), name))
        local roster = Tm:Roster()
        local any = false
        for _, m in ipairs(roster) do
            if m.tank then
                if not any then root:CreateTitle("Tanks") end
                any = true
                local r, g, b = UI():ClassColor(m.class)
                root:CreateRadio(Hex(r, g, b) .. m.name .. "|r", function() return Tm:GetES(name) == m.name end,
                    function() Tm:SetES(name, m.name) end)
            end
        end
        local everyone = root:CreateButton("Someone else")
        for _, m in ipairs(roster) do
            local r, g, b = UI():ClassColor(m.class)
            everyone:CreateRadio(Hex(r, g, b) .. m.name .. "|r", function() return Tm:GetES(name) == m.name end,
                function() Tm:SetES(name, m.name) end)
        end
        root:CreateRadio("Nobody", function() return Tm:GetES(name) == nil end, function() Tm:SetES(name, nil) end)
    end)
end

local function SwapMenu(owner, sub)
    local Tm = T()
    UI():ContextMenu(owner, function(root)
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

local function MoreMenu(owner)
    local Tm = T()
    UI():ContextMenu(owner, function(root)
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
    end)
end

local function RaidMenu(owner)
    local Tm = T()
    UI():ContextMenu(owner, function(root)
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
    if not drag then
        drag = CreateFrame("Frame", nil, UIParent)
        drag:SetSize(30, 30)
        drag:SetFrameStrata("TOOLTIP")
        drag.icon = drag:CreateTexture(nil, "ARTWORK")
        drag.icon:SetAllPoints()
        drag.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        drag.mark = CreateFrame("Frame", nil, frame)
        drag.mark:SetFrameStrata("DIALOG")
        Edge(drag.mark, 1, 0.82, 0, 1)
        drag.mark.fill = Fill(drag.mark:CreateTexture(nil, "BACKGROUND"), 1, 0.82, 0, 0.08)
        drag.mark.fill:SetAllPoints()
        drag.mark:EnableMouse(false)
    end
    drag.name = name
    drag.icon:SetTexture(icon)
    drag:Show()
    drag:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / s, y / s)
        local row = EmptyRowUnderCursor()
        if row then
            self.mark:ClearAllPoints()
            self.mark:SetAllPoints(row)
            self.mark:Show()
        else
            self.mark:Hide()
        end
    end)
end

local function EndDrag()
    if not drag or not drag:IsShown() then return end
    local row = EmptyRowUnderCursor()
    drag:Hide()
    drag:SetScript("OnUpdate", nil)
    drag.mark:Hide()
    if row then T():MoveShaman(drag.name, row.emptySub) end
end
TUI.EndDrag = EndDrag

-- ---------------------------------------------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------------------------------------------
local function BuildBanner(c)
    local bn = CreateFrame("Frame", nil, c)
    bn:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -PAD)
    bn:SetPoint("TOPRIGHT", c, "TOPRIGHT", -PAD, -PAD)
    bn:SetHeight(BANNER_H)
    bn:SetClipsChildren(true)
    bn.art = bn:CreateTexture(nil, "BACKGROUND")
    bn.art:SetAllPoints()
    bn.art:SetVertexColor(0.62, 0.62, 0.62)
    if EUI() then EUI():AddShade(bn) end
    Edge(bn, 0.16, 0.16, 0.18, 1)
    bn.title = Text(bn, 19, GOLD)
    bn.title:SetPoint("TOPLEFT", bn, "TOPLEFT", 14, -12)
    bn.title:SetText("Totems")
    bn.sub = Text(bn, 11, { 0.68, 0.68, 0.7 })
    bn.sub:SetPoint("TOPLEFT", bn, "TOPLEFT", 14, -43)
    bn.who = Text(bn, 9.5, { 0.68, 0.68, 0.7 })
    bn.who:SetPoint("TOPRIGHT", bn, "TOPRIGHT", -12, -11)
    bn.who:SetJustifyH("RIGHT")
    local auto = UI():CreateSleekButton(bn, "Auto-assign", 100, 22, function()
        if T():CanEditAny() then T():AutoAssign() end
    end, "primary")
    auto:SetPoint("TOPRIGHT", bn, "TOPRIGHT", -12, -36)
    auto:HookScript("OnEnter", function(self)
        Tip(self, "Auto-assign", { "Gives every shaman you may change the totems their party wants: Windfury and "
            .. "Strength of Earth for melee (Enhancement twists Grace of Air in), Wrath of Air and Totem of Wrath for "
            .. "casters, Mana Spring for all. Restoration shamans shield a tank each." })
    end)
    auto:HookScript("OnLeave", function() GameTooltip:Hide() end)
    bn.auto = auto
    local more = UI():CreateTipIconButton(bn, 22, UI().ICON.more, "More", nil, function(self) MoreMenu(self) end)
    more:SetPoint("RIGHT", auto, "LEFT", -6, 0)
    local report = UI():CreateTipIconButton(bn, 22, UI().ICON.whisper, "Report",
        "Posts who drops what, and which groups have no shaman, to the raid (or party) chat.", function() T():Report() end)
    report:SetPoint("RIGHT", more, "LEFT", -4, 0)
    bn.report = report
    return bn
end

local function BuildHeader(c)
    local y = -(PAD + BANNER_H + TABS_H + 18)
    local h = {}
    local function cap(text, x)
        local fs = Text(c, 9.5, GREY)
        fs:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + x + 2, y - 2)
        fs:SetText(text)
        return fs
    end
    h.shaman = cap("SHAMAN", 0)
    h.group = cap("GROUP", GROUP_X)
    h.els = {}
    for el = 1, 4 do
        local fs = Text(c, 11.5, ElColor(el))
        fs:SetJustifyH("CENTER")
        fs:SetWidth(CELL_W)
        fs:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + CELL_X + (el - 1) * CELL_W, y)
        fs:SetText(T().D.ELEMENTS[el].name)
        h.els[el] = fs
    end
    h.hero = cap("HEROISM", HERO_X + 4)
    h.es = cap("EARTH SHIELD", ES_X + 4)
    return h
end

local function NewCell(row, el)
    local cell = CreateFrame("Button", nil, row)
    cell:SetSize(CELL_W - 4, ROW_H)
    cell:SetPoint("TOPLEFT", row, "TOPLEFT", CELL_X + (el - 1) * CELL_W + 2, 0)
    cell.bg = Fill(cell:CreateTexture(nil, "BACKGROUND"), 0.1, 0.1, 0.118, 1)
    cell.bg:SetAllPoints()
    Edge(cell, 0.15, 0.15, 0.17, 1)
    local c = ElColor(el)
    cell.line = Fill(cell:CreateTexture(nil, "BORDER"), c[1], c[2], c[3], 0.85)
    cell.line:SetPoint("BOTTOMLEFT", 1, 2)
    cell.line:SetPoint("BOTTOMRIGHT", -1, 2)
    cell.line:SetHeight(2)
    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon:SetSize(ICON, ICON)
    cell.icon:SetPoint("CENTER", 0, 1)
    cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    cell.empty = cell:CreateTexture(nil, "ARTWORK")
    cell.empty:SetSize(ICON - 6, ICON - 6)
    cell.empty:SetPoint("CENTER", 0, 1)
    Fill(cell.empty, 1, 1, 1, 0.03)
    -- the twist partner (or a boss's second totem) in the corner
    -- (the twist partner sits in a frame of its own above the cell, its icon inside its edge)
    cell.twinEdge = CreateFrame("Frame", nil, cell)
    cell.twinEdge:SetFrameLevel(cell:GetFrameLevel() + 4)
    cell.twinEdge:SetSize(17, 17)
    cell.twinEdge:SetPoint("BOTTOMRIGHT", cell.icon, "BOTTOMRIGHT", 7, -6)
    Edge(cell.twinEdge, c[1], c[2], c[3], 1)
    cell.twin = cell.twinEdge:CreateTexture(nil, "ARTWORK")
    cell.twin:SetPoint("TOPLEFT", 1, -1)
    cell.twin:SetPoint("BOTTOMRIGHT", -1, 1)
    cell.twin:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    -- a boss change: gold inset, the phase digit in the corner
    cell.gold = CreateFrame("Frame", nil, cell)
    cell.gold:SetAllPoints()
    Edge(cell.gold, GOLD[1], GOLD[2], GOLD[3], 1)
    cell.phase = Text(cell, 9.5, GOLD, "OVERLAY", "GameFontHighlightSmall")
    cell.phase:SetPoint("TOPRIGHT", cell, "TOPRIGHT", -4, -3)
    cell.miss = UI():CreateCountBadge(cell, 13)
    cell.miss:SetPoint("CENTER", cell.icon, "TOPRIGHT", -1, -1)
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
    cell:SetScript("OnEnter", function(self)
        if row.name and T():CanEdit(row.name) then UI():SetEdgeColor(self, 1, 0.82, 0, 0.9) end
        TUI:CellTip(self, row.name)
    end)
    cell:SetScript("OnLeave", function(self)
        UI():SetEdgeColor(self, 0.15, 0.15, 0.17, 1)
        GameTooltip:Hide()
    end)
    return cell
end

local function NewRow(c, i)
    local row = CreateFrame("Frame", nil, c)
    row:SetHeight(ROW_H)
    row:SetWidth(GRID_W)
    -- the card
    local card = CreateFrame("Button", nil, row)
    card:SetSize(CARD_W, ROW_H)
    card:SetPoint("TOPLEFT")
    card.bg = card:CreateTexture(nil, "BACKGROUND")
    card.bg:SetAllPoints()
    card.bg:SetTexture(WHITE8)
    if card.bg.SetGradient and CreateColor then
        card.bg:SetGradient("HORIZONTAL", CreateColor(0.08, 0.17, 0.30, 0.95), CreateColor(0.12, 0.12, 0.14, 0.95))
    else
        card.bg:SetVertexColor(0.11, 0.14, 0.19, 0.95)
    end
    Edge(card, 0.17, 0.17, 0.19, 1)
    card.bar = Fill(card:CreateTexture(nil, "BORDER"), SHAMAN_RGB[1], SHAMAN_RGB[2], SHAMAN_RGB[3], 1)
    card.bar:SetPoint("TOPLEFT")
    card.bar:SetPoint("BOTTOMLEFT")
    card.bar:SetWidth(2)
    card.spec = card:CreateTexture(nil, "ARTWORK")
    card.spec:SetSize(26, 26)
    card.spec:SetPoint("LEFT", card, "LEFT", 8, 0)
    card.spec:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    card.name = Text(card, 12.5, NAME_RGB)
    card.name:SetPoint("TOPLEFT", card, "TOPLEFT", 40, -8)
    card.crown = card:CreateTexture(nil, "OVERLAY")
    card.crown:SetSize(11, 11)
    card.crown:SetPoint("LEFT", card.name, "RIGHT", 4, 0)
    card.crown:SetTexture(UI().ICON_ATLAS)
    local cc = UI():IconCoords(UI().ICON.crown)
    card.crown:SetTexCoord(cc[1], cc[2], cc[3], cc[4])
    card.crown:SetVertexColor(1, 0.82, 0)
    card.line = Text(card, 10, GREY)
    card.line:SetPoint("TOPLEFT", card, "TOPLEFT", 40, -27)
    card.line:SetPoint("RIGHT", card, "RIGHT", -6, 0)
    card:RegisterForDrag("LeftButton")
    card:SetScript("OnDragStart", function()
        if row.name then StartDrag(row.name, card.spec:GetTexture()) end
    end)
    card:SetScript("OnDragStop", EndDrag)
    card:SetScript("OnEnter", function(self) TUI:CardTip(self, row.name) end)
    card:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.card = card
    -- the group
    row.group = Text(row, 10, { 0.81, 0.81, 0.83 })
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
    row.groupHit:EnableMouse(true)
    row.groupHit:SetScript("OnEnter", function(self) TUI:GroupTip(self, row.sub) end)
    row.groupHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- the elements
    row.cells = {}
    for el = 1, 4 do row.cells[el] = NewCell(row, el) end
    -- Heroism
    local hero = CreateFrame("Button", nil, row)
    hero:SetSize(HERO_W, ROW_H)
    hero:SetPoint("TOPLEFT", row, "TOPLEFT", HERO_X, 0)
    hero.bg = Fill(hero:CreateTexture(nil, "BACKGROUND"), 0.1, 0.1, 0.118, 1)
    hero.bg:SetAllPoints()
    Edge(hero, 0.15, 0.15, 0.17, 1)
    hero.icon = hero:CreateTexture(nil, "ARTWORK")
    hero.icon:SetSize(24, 24)
    hero.icon:SetPoint("LEFT", hero, "LEFT", 8, 0)
    hero.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    hero.text = Text(hero, 11, { 0.91, 0.91, 0.91 })
    hero.text:SetPoint("LEFT", hero.icon, "RIGHT", 7, 0)
    hero:RegisterForClicks("LeftButtonUp")
    hero:SetScript("OnClick", function(self)
        if row.name and not bossTab and T():CanEdit(row.name) then HeroMenu(self, row.name) end
    end)
    hero:SetScript("OnEnter", function(self)
        if not row.name then return end
        local h = T():GetHero(row.name)
        local long = ""
        for _, x in ipairs(T().D.HERO_WHEN) do if x.key == h then long = x.long end end
        local lines = { long, strformat("Only reaches %s's party.", row.name) }
        if T():CanEdit(row.name) and not bossTab then tinsert(lines, { "Click: when", 0.6, 0.6, 0.6 }) end
        Tip(self, T():HeroName(), lines)
    end)
    hero:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.hero = hero
    -- Earth Shield
    local es = CreateFrame("Button", nil, row)
    es:SetSize(ES_W, ROW_H)
    es:SetClipsChildren(true)
    es:SetPoint("TOPLEFT", row, "TOPLEFT", ES_X, 0)
    es.bg = Fill(es:CreateTexture(nil, "BACKGROUND"), 0.1, 0.1, 0.118, 1)
    es.bg:SetAllPoints()
    Edge(es, 0.15, 0.15, 0.17, 1)
    es.icon = es:CreateTexture(nil, "ARTWORK")
    es.icon:SetSize(24, 24)
    es.icon:SetPoint("LEFT", es, "LEFT", 8, 0)
    es.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    es.name = Text(es, 11.5)
    es.name:SetPoint("TOPLEFT", es, "TOPLEFT", 38, -10)
    es.name:SetPoint("RIGHT", es, "RIGHT", -6, 0)
    es.sub = Text(es, 9.5, GREY)
    es.sub:SetPoint("TOPLEFT", es, "TOPLEFT", 38, -27)
    es.sub:SetPoint("RIGHT", es, "RIGHT", -6, 0)
    es:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    es:SetScript("OnClick", function(self, button)
        if not row.name or bossTab or not self.can or not T():CanEdit(row.name) then return end
        if button == "RightButton" then T():SetES(row.name, nil) else ESMenu(self, row.name) end
    end)
    es:SetScript("OnEnter", function(self)
        if not row.name or not self.can then return end
        local t = T():GetES(row.name)
        local lines = { t and strformat("%s keeps it on %s.", row.name, t) or "Nobody yet." }
        if T():CanEdit(row.name) and not bossTab then tinsert(lines, { "Click: pick · Right-click: nobody", 0.6, 0.6, 0.6 }) end
        Tip(self, T():ESName(), lines)
    end)
    es:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.es = es
    -- a group without a shaman
    local e = CreateFrame("Frame", nil, row)
    e:SetAllPoints()
    e.bg = Fill(e:CreateTexture(nil, "BACKGROUND"), RED[1], RED[2], RED[3], 0.05)
    e.bg:SetAllPoints()
    Edge(e, 0.35, 0.23, 0.21, 1)
    e.title = Text(e, 12, RED)
    e.title:SetPoint("TOPLEFT", e, "TOPLEFT", 10, -7)
    e.title:SetText("No shaman")
    e.swap = UI():CreateSleekButton(e, "Suggest a swap", 112, 19, function(self) SwapMenu(self, row.emptySub) end)
    e.swap:SetPoint("TOPLEFT", e, "TOPLEFT", 9, -25)
    e.swap:HookScript("OnEnter", function(self)
        Tip(self, "Suggest a swap", { "Moves a shaman into this group, swapping them with one of its players. Or "
            .. "drag a shaman's card onto this row.", T():CanMove() and "" or { "Only the leader or an assistant, out of "
            .. "combat.", 1, 0.55, 0.45 } })
    end)
    e.swap:HookScript("OnLeave", function() GameTooltip:Hide() end)
    e.ghosts = {}
    for el = 1, 4 do
        local g = e:CreateTexture(nil, "ARTWORK")
        g:SetSize(26, 26)
        g:SetPoint("CENTER", row, "TOPLEFT", CELL_X + (el - 0.5) * CELL_W, -ROW_H / 2)
        g:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        g:SetDesaturated(true)
        g:SetVertexColor(0.5, 0.5, 0.5)
        g:SetAlpha(0.8)
        e.ghosts[el] = g
    end
    e.misses = Text(e, 10, { 0.84, 0.6, 0.56 })
    e.misses:SetPoint("TOPLEFT", e, "TOPLEFT", HERO_X + 4, -10)
    e.misses:SetWidth(GRID_W - HERO_X - 12)
    e.misses:SetWordWrap(true)
    e.misses:SetMaxLines(2)
    row.emptyFace = e
    return row
end

-- A boss change, as the Blessings planner's exception chips: the boss and who, then the swap: the All bosses
-- totem faded, a hairline warming from grey to gold into a gold chevron, and the boss's totem in a thin gold frame.
local function NewChip(c)
    local chip = CreateFrame("Button", nil, c)
    chip:SetSize(CHIP_W, CHIP_H)
    chip.bg = Fill(chip:CreateTexture(nil, "BACKGROUND"), 0.11, 0.11, 0.13, 1)
    chip.bg:SetAllPoints()
    Edge(chip, 0.17, 0.17, 0.19, 1)
    chip.bar = chip:CreateTexture(nil, "BORDER")
    chip.bar:SetTexture(WHITE8)
    chip.bar:SetPoint("TOPLEFT")
    chip.bar:SetPoint("BOTTOMLEFT")
    chip.bar:SetWidth(2)
    chip.name = Text(chip, 11.5)
    chip.name:SetPoint("TOPLEFT", chip, "TOPLEFT", 8, -4)
    chip.name:SetPoint("RIGHT", chip, "RIGHT", -63, 0)
    chip.sub = Text(chip, 9.5, GREY)
    chip.sub:SetPoint("TOPLEFT", chip, "TOPLEFT", 8, -20)
    chip.sub:SetPoint("RIGHT", chip, "RIGHT", -63, 0)
    chip.now = CreateFrame("Frame", nil, chip)
    chip.now:SetSize(18, 18)
    chip.now:SetPoint("RIGHT", chip, "RIGHT", -7, 0)
    Edge(chip.now, 1, 0.82, 0, 0.9)
    chip.now.icon = chip.now:CreateTexture(nil, "ARTWORK")
    chip.now.icon:SetPoint("TOPLEFT", 1, -1)
    chip.now.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    chip.now.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    chip.tip = chip:CreateTexture(nil, "OVERLAY")
    chip.tip:SetSize(9, 9)
    chip.tip:SetPoint("RIGHT", chip.now, "LEFT", -3, 0)
    UI():SetChevron(chip.tip, true)
    chip.tip:SetVertexColor(1, 0.82, 0, 0.95)
    chip.was = chip:CreateTexture(nil, "ARTWORK")
    chip.was:SetSize(13, 13)
    chip.was:SetPoint("RIGHT", chip, "RIGHT", -46, 0)
    chip.was:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    chip.was:SetDesaturated(true)
    chip.was:SetAlpha(0.5)
    chip.line = chip:CreateTexture(nil, "ARTWORK")
    chip.line:SetTexture(WHITE8)
    chip.line:SetHeight(1)
    chip.line:SetPoint("LEFT", chip.was, "RIGHT", 3, 0)
    chip.line:SetPoint("RIGHT", chip.tip, "LEFT", 3, 0)
    if chip.line.SetGradient and CreateColor then
        chip.line:SetGradient("HORIZONTAL", CreateColor(0.55, 0.55, 0.58, 0.35), CreateColor(1, 0.82, 0, 0.95))
    else
        chip.line:SetVertexColor(0.8, 0.68, 0.3, 0.7)
    end
    chip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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
    chip:SetScript("OnEnter", function(self)
        local e = self.change
        if not e then return end
        local Tm = T()
        UI():SetEdgeColor(self, 1, 0.82, 0, 0.9)
        local what = Tm:TotemName(e.el, e.i)
        local lines = { strformat("%s: %s %s%s.", e.bossName, what, e.alt and "on right-click (a second phase)"
            or "instead", (e.was and not e.alt) and (" of " .. Tm.D.TOTEMS[e.el][e.was].short) or "") }
        lines[#lines + 1] = tconcat(e.names, ", ")
        lines[#lines + 1] = { "Click: open the boss · Right-click: remove", 0.6, 0.6, 0.6 }
        Tip(self, "Boss change", lines)
    end)
    chip:SetScript("OnLeave", function(self)
        UI():SetEdgeColor(self, 0.17, 0.17, 0.19, 1)
        GameTooltip:Hide()
    end)
    return chip
end

local function BuildBossStrip(c)
    -- (a boss tab's header: portrait, what this tab is, how the bar uses a second totem)
    local s = CreateFrame("Frame", nil, c)
    s:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -(PAD + BANNER_H + TABS_H + 12))
    s:SetWidth(GRID_W)
    s:SetHeight(50)
    s.bg = Fill(s:CreateTexture(nil, "BACKGROUND"), 0.094, 0.094, 0.11, 1)
    s.bg:SetAllPoints()
    Edge(s, 0.15, 0.15, 0.17, 1)
    s.artBox = CreateFrame("Frame", nil, s)
    s.artBox:SetSize(76, 38)
    s.artBox:SetPoint("LEFT", s, "LEFT", 6, 0)
    Edge(s.artBox, GOLD[1], GOLD[2], GOLD[3], 1)
    s.art = s.artBox:CreateTexture(nil, "ARTWORK")
    s.art:SetAllPoints()
    s.art:SetTexCoord(0, 1, 0.1, 0.85)
    s.title = Text(s, 12.5, GOLD)
    s.title:SetPoint("TOPLEFT", s, "TOPLEFT", 94, -8)
    s.title:SetText("Changes for this boss only")
    s.sub = Text(s, 10, GREY)
    s.sub:SetPoint("TOPLEFT", s, "TOPLEFT", 94, -27)
    s.sub:SetText("The rest follows All bosses. Faded = no change.")
    s.k1 = Text(s, 10, { 0.86, 0.86, 0.88 })
    s.k1:SetPoint("TOPLEFT", s, "TOPLEFT", 520, -10)
    s.k1:SetText("|cffffd1001|r  click on the bar")
    s.k2 = Text(s, 10, { 0.86, 0.86, 0.88 })
    s.k2:SetPoint("TOPLEFT", s, "TOPLEFT", 520, -27)
    s.k2:SetText("|cffffd1002|r  right-click: a second phase")
    s:Hide()
    return s
end

local function Build()
    frame = UI():CreateWindow("DisasterZoneTotems", "DisasterZone - Totems", W, 420)
    frame:Hide()
    frame:SetScript("OnShow", function() TUI:Refresh() end)
    local c = frame.content
    frame.banner = BuildBanner(c)
    frame.tabs = {}
    frame.tabLine = Fill(c:CreateTexture(nil, "ARTWORK"), 1, 1, 1, 0.07)
    frame.tabLine:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -(PAD + BANNER_H + TABS_H + 6))
    frame.tabLine:SetWidth(GRID_W)
    frame.tabLine:SetHeight(1)
    local raidBtn = CreateFrame("Button", nil, c)
    raidBtn:SetHeight(TABS_H)
    raidBtn.text = Text(raidBtn, 10.5, GREY)
    raidBtn.text:SetPoint("RIGHT", raidBtn, "RIGHT", -14, 0)
    raidBtn.chev = raidBtn:CreateTexture(nil, "OVERLAY")
    raidBtn.chev:SetSize(8, 8)
    raidBtn.chev:SetPoint("RIGHT", raidBtn, "RIGHT", -2, 0)
    if UI().SetChevronUp then UI():SetChevronUp(raidBtn.chev, false) end
    raidBtn.chev:SetVertexColor(0.62, 0.62, 0.64)
    raidBtn:SetPoint("TOPRIGHT", c, "TOPLEFT", PAD + GRID_W, -(PAD + BANNER_H + 6))
    raidBtn:SetScript("OnClick", function(self) if self.pick then RaidMenu(self) end end)
    raidBtn:SetScript("OnEnter", function(self)
        if self.pick then self.text:SetTextColor(1, 0.82, 0) end
        Tip(self, "Raid", { self.pick and "Pick the raid to plan for." or "The raid you are in." })
    end)
    raidBtn:SetScript("OnLeave", function(self)
        self.text:SetTextColor(GREY[1], GREY[2], GREY[3])
        GameTooltip:Hide()
    end)
    frame.raidBtn = raidBtn
    frame.head = BuildHeader(c)
    frame.bossStrip = BuildBossStrip(c)
    frame.rows = {}
    frame.chips = {}
    frame.stripCap = Text(c, 9.5, GREY)
    frame.stripCap:SetText("BOSS CHANGES")
    frame.stripCount = Text(c, 10, { 0.47, 0.47, 0.5 })
    frame.stripRule = c:CreateTexture(nil, "ARTWORK")
    frame.stripRule:SetTexture(WHITE8)
    frame.stripRule:SetHeight(1)
    if frame.stripRule.SetGradient and CreateColor then
        frame.stripRule:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, 0.14), CreateColor(1, 1, 1, 0.04))
    else
        frame.stripRule:SetVertexColor(1, 1, 1, 0.08)
    end
    local add = CreateFrame("Button", nil, c)
    add:SetSize(RULE_H, RULE_H)
    Edge(add, 0.24, 0.24, 0.27, 1)
    add.plus = Text(add, 15, { 0.6, 0.6, 0.64 })
    add.plus:SetPoint("CENTER", 0, 1)
    add.plus:SetText("+")
    add:SetScript("OnClick", function(self)
        UI():ContextMenu(self, function(root)
            root:CreateTitle("Change totems for one boss")
            for _, b in ipairs(T():Bosses()) do root:CreateButton(b.name, function() TUI:SetBossTab(b.key) end) end
        end)
    end)
    add:SetScript("OnEnter", function(self)
        UI():SetEdgeColor(self, 1, 0.82, 0, 0.9)
        Tip(self, "Change totems for one boss", { "Resistance totems, Tremor against fear: pick a boss and change "
            .. "only what differs. The bar switches when you fight it." })
    end)
    add:SetScript("OnLeave", function(self)
        UI():SetEdgeColor(self, 0.24, 0.24, 0.27, 1)
        GameTooltip:Hide()
    end)
    frame.addBoss = add
    frame.emptyTitle = Text(c, 14, { 0.85, 0.85, 0.87 })
    frame.emptyTitle:SetText("No shamans here yet")
    frame.emptyText = Text(c, 11, GREY)
    frame.emptyText:SetText("Shamans in your group show up here, with DisasterZone, ShamanPower or no addon at all.")
    frame.emptyTitle:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + 2, -(PAD + BANNER_H + TABS_H + 50))
    frame.emptyText:SetPoint("TOPLEFT", frame.emptyTitle, "BOTTOMLEFT", 0, -6)
    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc >= 3 then
            acc = 0
            TUI:Refresh()
        end
    end)
    ns:On("TOTEMS_CHANGED", function() if frame:IsShown() then TUI:Refresh() end end)
    ns:On("GROUP_UPDATED", function() if frame:IsShown() then TUI:Refresh() end end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Tooltips
-- ---------------------------------------------------------------------------------------------------------------
function TUI:CellTip(cell, name)
    if not name then return end
    local Tm = T()
    local el = cell.el
    local idx, alt, why = Tm:Effective(name, el, bossTab)
    local t = idx and Tm:Totem(el, idx)
    local lines = {}
    if t then lines[#lines + 1] = t.fx end
    if why == "twist" then
        lines[#lines + 1] = { "Twisted with " .. Tm.D.TOTEMS[4][alt].short .. ": Windfury stays on weapons 10 s after.", 0.75, 0.62, 1 }
    elseif why == "boss1" and alt then
        lines[#lines + 1] = { strformat("Right-click on the bar: %s (All bosses)", Tm.D.TOTEMS[el][alt].short), 1, 0.82, 0 }
    elseif why == "boss2" then
        lines[#lines + 1] = { strformat("Right-click on the bar: %s", Tm.D.TOTEMS[el][alt].short), 1, 0.82, 0 }
    end
    local st = cell.state
    if st and st.total > 0 and st.have > 0 then
        lines[#lines + 1] = strformat("%d of %d in the party have it", st.have, st.total)
        for _, m in ipairs(st.missing) do lines[#lines + 1] = { "Out of range: " .. m.name, 1, 0.55, 0.45 } end
    end
    if Tm:CanEdit(name) then
        lines[#lines + 1] = { bossTab and "Click: change for this boss · Right-click: as All bosses"
            or "Click: pick · Right-click: none · Wheel: next", 0.6, 0.6, 0.6 }
    else
        lines[#lines + 1] = { "Only " .. name .. ", the leader or an assistant can change it.", 0.6, 0.6, 0.6 }
    end
    local elName = Tm.D.ELEMENTS[el].name
    Tip(cell, strformat("%s · %s: %s", name, elName, t and Tm:TotemName(el, idx) or "nothing"), lines)
end

function TUI:CardTip(card, name)
    if not name then return end
    local Tm = T()
    local s = Tm.shamans[name]
    local lines = { Tm:SpecOf(name) .. " Shaman" }
    if s then
        if s.noAddon then
            lines[#lines + 1] = { "No DisasterZone or ShamanPower: the leader plans for them, they read it in chat (Report).", 1, 0.7, 0.4 }
        end
        if s.free then lines[#lines + 1] = "Anyone may assign them" end
    end
    if Tm:CanMove() then lines[#lines + 1] = { "Drag onto a \"No shaman\" row to move them there", 0.6, 0.6, 0.6 } end
    Tip(card, name, lines)
end

function TUI:GroupTip(owner, sub)
    if not sub then return end
    local Tm = T()
    local roster = Tm:Roster()
    local lines = {}
    for _, m in ipairs(roster) do
        if m.subgroup == sub then
            local r, g, b = UI():ClassColor(m.class)
            lines[#lines + 1] = { m.name .. (m.tank and " · tank" or ""), r, g, b }
        end
    end
    lines[#lines + 1] = { "Totems and Heroism only reach this party.", 0.6, 0.6, 0.6 }
    Tip(owner, "Group " .. sub, lines)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------------------------------------------
local function ArtKey()
    if T():IsDemo() then return "ssc" end
    local id = select(8, GetInstanceInfo())
    return INST_ART[tonumber(id) or 0] or RAID_ART[T():RaidKey()] or "other"
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
    local shown, rest = 0, {}
    for i, e in ipairs(list) do
        local tab = frame.tabs[i]
        if not tab then
            tab = UI():CreateUnderlineTab(c, e.label, nil, "page")
            tab.dot = Fill(tab:CreateTexture(nil, "OVERLAY"), GOLD[1], GOLD[2], GOLD[3], 1)
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
            tab:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + x, -(PAD + BANNER_H + 6))
            tab:Show()
            if tab.SetActive then tab:SetActive(bossTab == key) end
            tab.dot:ClearAllPoints()
            tab.dot:SetPoint("TOPRIGHT", tab, "TOPRIGHT", 1, -4)
            tab.dot:SetShown(e.changed or false)
            x = x + w + 4
            shown = i
        end
    end
    for i = #list + 1, #frame.tabs do frame.tabs[i]:Hide() end
    -- the bosses that don't fit: one "More" tab with a menu (it names the boss while one of them is open)
    if #rest > 0 then
        if not frame.moreTab then
            frame.moreTab = UI():CreateUnderlineTab(c, "More", nil, "page")
        end
        local mt = frame.moreTab
        local active
        for _, e in ipairs(rest) do if e.key == bossTab then active = e end end
        if mt.SetLabel then mt:SetLabel(active and active.label or "More") else mt:SetText(active and active.label or "More") end
        mt:ClearAllPoints()
        mt:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + x, -(PAD + BANNER_H + 6))
        mt:SetScript("OnClick", function(self)
            UI():ContextMenu(self, function(root)
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

function TUI:Refresh()
    if not frame then return end
    local Tm = T()
    local c = frame.content
    local roster = Tm:Roster()
    local shamans = Tm:Shamans(roster)
    local groups, order = Tm:Groups(roster)
    if bossTab then
        local ok = false
        for _, b in ipairs(Tm:Bosses()) do if b.key == bossTab then ok = true end end
        if not ok then bossTab = nil end
    end

    -- banner
    local bn = frame.banner
    local PlanUI = ns.RaidPlanUI
    if PlanUI and PlanUI.RaidArt then
        local path, l, r, t, b = PlanUI:RaidArt(ArtKey(), W - 2 * PAD, BANNER_H, 0.62)
        bn.art:SetTexture(path)
        bn.art:SetTexCoord(l, r, t, b)
    end
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
    bn.sub:SetText(tconcat(parts, " · "))
    local who
    if Tm:IsDemo() then who = "DEMO MODE · YOU ASSIGN"
    elseif not IsInGroup() then who = "SOLO"
    elseif Tm:AmLeader() or ns.Util.IsPlayerLeaderOrAssist() then who = "YOU ASSIGN"
    else
        local lead = Tm:LeaderName()
        who = lead and (lead:upper() .. " ASSIGNS") or ""
    end
    bn.who:SetText(who)
    bn.auto:SetEnabled(Tm:CanEditAny() and not bossTab)
    bn.report:SetEnabled(Tm:InGroup())

    LayoutTabs(c)
    frame.bossStrip:SetShown(bossTab ~= nil)
    if bossTab then
        local name = Tm:BossName(bossTab)
        frame.bossStrip.art:SetTexture(EJ .. name)
    end

    -- header (under the boss strip on a boss tab)
    local headY = PAD + BANNER_H + TABS_H + 18 + (bossTab and 58 or 0)
    local h = frame.head
    local function placeCap(fs, x) fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + x + 2, -(headY + 2)) end
    placeCap(h.shaman, 0)
    placeCap(h.group, GROUP_X)
    placeCap(h.hero, HERO_X + 4)
    placeCap(h.es, ES_X + 4)
    for el = 1, 4 do
        h.els[el]:ClearAllPoints()
        h.els[el]:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + CELL_X + (el - 1) * CELL_W, -headY)
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
    for i, e in ipairs(entries) do
        local row = frame.rows[i]
        if not row then
            row = NewRow(c, i)
            frame.rows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -(rowsTop + (i - 1) * (ROW_H + ROW_GAP)))
        row:Show()
        row.sub = e.sub
        -- the group column (both kinds)
        if e.g then
            row.group:SetText(GroupLabel(e.g))
            for k = 1, 5 do
                local m = e.g.members[k]
                row.circles[k]:SetShown(m ~= nil)
                if m then
                    ClassCircle(row.circles[k], m.class)
                    row.circles[k]:SetAlpha((e.shaman and m.name == e.shaman.name) and 0.45 or 1)
                end
            end
        else
            row.group:SetText(inGroup and "Not in the group" or "Solo")
            for k = 1, 5 do row.circles[k]:Hide() end
        end
        if e.empty then
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
        else
            local s = e.shaman
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
                local base = Tm:GetAssign(name, el)
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
                local _ = base
            end
            -- Heroism
            local _, heroIcon = Tm:HeroSpell()
            row.hero.icon:SetTexture(heroIcon)
            local hk = Tm:GetHero(name)
            local htext = "Pull"
            for _, x in ipairs(Tm.D.HERO_WHEN) do if x.key == hk then htext = x.text end end
            row.hero.text:SetText(htext)
            row.hero.icon:SetAlpha(bossTab and 0.4 or 1)
            row.hero.text:SetAlpha(bossTab and 0.55 or 1)
            row.hero.icon:SetDesaturated(hk == "none" or bossTab ~= nil)
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
                    local cls
                    for _, m in ipairs(roster) do if m.name == target then cls = m.class end end
                    local r, g, b = UI():ClassColor(cls or "WARRIOR")
                    es.name:SetText(target)
                    es.name:SetTextColor(r, g, b)
                    local tank = false
                    for _, m in ipairs(roster) do if m.name == target and m.tank then tank = true end end
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
    end
    for i = #entries + 1, #frame.rows do
        frame.rows[i]:Hide()
        frame.rows[i].name = nil
        frame.rows[i].emptySub = nil
    end
    frame.emptyTitle:SetShown(#entries == 0)
    frame.emptyText:SetShown(#entries == 0)
    for _, fs in pairs({ h.shaman, h.group, h.hero, h.es }) do fs:SetShown(#entries > 0) end
    for el = 1, 4 do h.els[el]:SetShown(#entries > 0) end

    -- bottom (All bosses tab): the rule ("BOSS CHANGES 2 ---- +"), then a chip per change under it, 4 a line
    local ey = rowsTop + max(1, #entries) * (ROW_H + ROW_GAP) + (#entries == 0 and 40 or 0)
    local changes = (not bossTab) and Tm:BossChanges() or {}
    local showStrip = not bossTab and #shamans > 0
    frame.stripCap:SetShown(showStrip)
    frame.stripCount:SetShown(showStrip)
    frame.stripRule:SetShown(showStrip)
    frame.addBoss:SetShown(showStrip and Tm:CanEditAny())
    local mid = -(ey + RULE_H / 2)
    frame.stripCap:ClearAllPoints()
    frame.stripCap:SetPoint("LEFT", c, "TOPLEFT", PAD + 2, mid)
    frame.stripCount:ClearAllPoints()
    frame.stripCount:SetPoint("LEFT", frame.stripCap, "RIGHT", 8, 0)
    frame.stripCount:SetText(#changes > 0 and #changes or "")
    frame.addBoss:ClearAllPoints()
    frame.addBoss:SetPoint("TOPRIGHT", c, "TOPLEFT", PAD + GRID_W, -ey)
    frame.stripRule:ClearAllPoints()
    frame.stripRule:SetPoint("LEFT", #changes > 0 and frame.stripCount or frame.stripCap, "RIGHT", 10, 0)
    frame.stripRule:SetPoint("RIGHT", c, "TOPLEFT", PAD + GRID_W - (frame.addBoss:IsShown() and (RULE_H + 8) or 0), mid)
    local cy = ey + RULE_H + 8
    for i, e in ipairs(changes) do
        local chip = frame.chips[i]
        if not chip then
            chip = NewChip(c)
            frame.chips[i] = chip
        end
        local col, line = (i - 1) % CHIP_PER, floor((i - 1) / CHIP_PER)
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + col * CHIP_PITCH, -(cy + line * (CHIP_H + 6)))
        chip.change = e
        local ec = ElColor(e.el)
        chip.bar:SetVertexColor(ec[1], ec[2], ec[3], 1)
        chip.name:SetText(TabLabel(e.short))
        local who = (#e.names == #shamans) and "all" or (#e.names == 1 and e.names[1] or (#e.names .. " shamans"))
        chip.sub:SetText(strformat("%s%s · %s", Tm.D.ELEMENTS[e.el].name, e.alt and " phase 2" or "", who))
        chip.was:SetShown(e.was ~= nil)
        chip.line:SetShown(e.was ~= nil)
        chip.tip:SetShown(e.was ~= nil)
        if e.was then chip.was:SetTexture(Tm:TotemIcon(e.el, e.was)) end
        chip.now.icon:SetTexture(Tm:TotemIcon(e.el, e.i))
        chip:SetShown(showStrip)
    end
    for i = #changes + 1, #frame.chips do frame.chips[i]:Hide() end
    local lines = showStrip and math.ceil(#changes / CHIP_PER) or 0
    local contentH = showStrip and ((lines > 0) and (cy + lines * (CHIP_H + 6) - 6 + PAD) or (ey + RULE_H + PAD))
        or (ey + PAD)
    frame:SetHeight(contentH + 34)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------------------------------------------
function TUI:Open()
    if not frame then Build() end
    frame:Show()
    self:Refresh()
    if ns.Totems and IsInGroup() then ns.Totems.Hello() end
end

function TUI:Close() if frame then frame:Hide() end end

function TUI:Toggle()
    if frame and frame:IsShown() then self:Close() else self:Open() end
end

function TUI:IsShown() return frame and frame:IsShown() or false end
function TUI:GetFrame() return frame end
