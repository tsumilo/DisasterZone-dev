if DisasterZoneBoot and DisasterZoneBoot.Run("UI/BlessingsUI.lua", ...) then return end -- DisasterZone: blessings planner.
-- The Blessings planner window (Core/Blessings.lua): paladins as rows, classes as columns, one Greater Blessing per
-- cell (Pally Power's layout, made over). Under it the exceptions: one player getting a single blessing instead of
-- the class one (tanks: no Salvation). The window, its tool banner and the shared parts (cards, cells, chips, the
-- rule, dragging) are the class planner window's (UI/PlannerWindow.lua).
--   banner     the raid's art, "Blessings", who assigns, where and how many; Auto-assign, More, Presets, Report
--   palette    the six Greater Blessings: drag one onto a cell (that class), a paladin's card (every class) or the
--              exceptions' "+" (pick a player)
--   cards      a paladin: spec icon, name (crown: leads), talents, a Symbols warning; the aura on the right (click:
--              pick, right-click: none; red edge: another paladin in the same party runs it)
--   cells      click: pick a blessing (or "every class"), right-click: none, wheel: the next one, Shift-click: the
--              same for every class; badges: gold count = players missing it, the time = running out, grey = that
--              many players get a single blessing instead
-- Rows I may not change are dimmed and only show what they hold. Open with /dz bless.
local addonName, ns = ...

local BUI = ns:NewModule("BlessingsUI")

local floor, max = math.floor, math.max
local strformat = string.format
local tinsert = table.insert

local W = 760
local GAP = 8
local CARD_W, ROW_H, ROW_GAP = 192, 54, 6
local CELL_W = 58
local HEAD_H = 52
-- exceptions: a rule across the width ("EXCEPTIONS 12 ---- +"), then chips from the left edge, 4 a line
local EXC_W = CARD_W + GAP + 9 * CELL_W - 2        -- the grid's width (cards to the last cell)
local RULE_H, CHIP_PER = 22, 4
local CHIP_H = 36
local CHIP_W = floor((EXC_W - (CHIP_PER - 1) * 6) / CHIP_PER)
local CHIP_PITCH = CHIP_W + 6
local PALETTE = { 3, 2, 1, 4, 5, 6 }
local PAL_PINK = { 0.96, 0.55, 0.73 }
local CARD_FROM, CARD_TO = { 0.27, 0.16, 0.21, 0.95 }, { 0.12, 0.12, 0.14, 0.95 }
local CLASH = { 0.88, 0.38, 0.31, 1 }
local BLACK = { 0, 0, 0, 1 }

local UI = ns.UI
local PW = ns.PlannerWindow
local HINT = PW.HINT
local IconText, Plural = PW.IconText, PW.Plural
local function B() return ns.Blessings end

local frame

-- ---------------------------------------------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------------------------------------------
-- The blessings paladin `name` can give as a Greater (radio entries) for class ci, and a submenu "Every class".
local function CellMenu(owner, name, ci)
    local Bl = B()
    local cls = Bl.D.CLASSES[ci]
    UI:ContextMenu(owner, function(root)
        root:CreateTitle(strformat("%s · %s", name, Plural(cls)))
        for _, bi in ipairs(PALETTE) do
            if Bl:Can(name, bi) then
                local other = Bl:Giver(ci, bi)
                local label = IconText(Bl:BlessingIcon(bi, true)) .. " " .. Bl.D.BLESSINGS[bi].short
                local e = root:CreateRadio(label, function() return Bl:GetAssign(name, ci) == bi end,
                    function() Bl:SetAssign(name, ci, bi) end)
                if other and other ~= name then e:SetHint("from " .. other) end
            end
        end
        root:CreateRadio("None", function() return Bl:GetAssign(name, ci) == nil end,
            function() Bl:SetAssign(name, ci, 0) end)
        root:CreateDivider()
        local every = root:CreateButton("Every class")
        for _, bi in ipairs(PALETTE) do
            if Bl:Can(name, bi) then
                every:CreateButton(IconText(Bl:BlessingIcon(bi, true)) .. " " .. Bl.D.BLESSINGS[bi].short,
                    function() Bl:SetRow(name, bi) end)
            end
        end
        every:CreateButton("None", function() Bl:SetRow(name, 0) end)
    end)
end

local function AuraMenu(owner, name)
    local Bl = B()
    UI:ContextMenu(owner, function(root)
        root:CreateTitle(name .. " · aura")
        for ai, a in ipairs(Bl.D.AURAS) do
            if Bl:CanAura(name, ai) then
                root:CreateRadio(IconText(Bl:AuraIcon(ai)) .. " " .. a.short,
                    function() return Bl:GetAura(name) == ai end, function() Bl:SetAura(name, ai) end)
            end
        end
        root:CreateRadio("None", function() return Bl:GetAura(name) == nil end, function() Bl:SetAura(name, 0) end)
    end)
end

-- The single blessings paladin `pal` can give `target` (class ci): radio entries.
local function AddSingleChoices(menu, pal, ci, target)
    local Bl = B()
    for bi = 1, #Bl.D.BLESSINGS do
        if Bl:Can(pal, bi) and not (bi == 7 and target == pal) then
            menu:CreateRadio(IconText(Bl:BlessingIcon(bi)) .. " " .. Bl.D.BLESSINGS[bi].short,
                function() return Bl:GetSingle(pal, ci, target) == bi end,
                function() Bl:SetSingle(pal, ci, target, bi) end)
        end
    end
end

-- "+": Class > Player > Paladin > blessing (preset to bi when a blessing was dropped on it).
local function AddExceptionMenu(owner, bi)
    local Bl = B()
    UI:ContextMenu(owner, function(root)
        root:CreateTitle(bi and ("Give one player " .. Bl.D.BLESSINGS[bi].short) or "A single blessing for one player")
        local byClass = Bl:ByClass()
        local any = false
        for _, cls in ipairs(Bl.D.DISPLAY) do
            local ci = Bl.CLASS_INDEX[cls]
            local members = byClass[ci]
            if #members > 0 then
                local r, g, b = UI:ClassColor(cls)
                local ce = root:CreateButton(PW.ColorCode(r, g, b) .. Plural(cls) .. "|r")
                for _, m in ipairs(members) do
                    local pe = ce:CreateButton(m.name .. (m.pet and " (pet)" or ""))
                    for _, p in ipairs(Bl:Paladins()) do
                        if Bl:CanEdit(p.name) then
                            any = true
                            if bi then
                                if Bl:Can(p.name, bi) then
                                    pe:CreateButton(p.name, function() Bl:SetSingle(p.name, ci, m.name, bi) end)
                                end
                            else
                                local sub = pe:CreateButton(p.name)
                                AddSingleChoices(sub, p.name, ci, m.name)
                            end
                        end
                    end
                end
            end
        end
        if not any then root:CreateTitle("You can't change any paladin here") end
    end)
end

local function PresetMenu(root)
    local Bl = B()
    local suggestion = Bl:PresetSuggestion()
    root:CreateButton("Save as \"" .. suggestion .. "\"", function() Bl:SavePreset(suggestion) end)
    local list = Bl:Presets()
    if #list > 0 then
        root:CreateDivider()
        root:CreateTitle("Load")
        for _, name in ipairs(list) do
            local e = root:CreateButton(name, function() Bl:LoadPreset(name) end)
            e:SetEnabled(Bl:CanEditAny())
            e:SetHint("Delete", function() Bl:DeletePreset(name) end)
        end
    end
end

local function MoreMenu(root)
    local Bl = B()
    if Bl:IsPaladin() then
        local e = root:CreateCheckbox("Anyone may assign me", function() return Bl.Setting("free", false) end,
            function() ns.DB:SetSetting("bless.free", not Bl.Setting("free", false)) end)
        e:SetTitleAndTextTooltip("Anyone may assign me", "Pally Power's Free Assignment: any paladin or "
            .. "player can change your blessings, not only the leader and assistants.")
    end
    root:CreateCheckbox("Pets count in their class", function() return Bl.Setting("pets", true) end,
        function() ns.DB:SetSetting("bless.pets", not Bl.Setting("pets", true)) end)
    if Bl:IsPaladin() and ns.BlessingsBar then
        root:CreateDivider()
        root:CreateTitle("Buff bar")
        for _, o in ipairs(ns.BlessingsBar.LAYOUTS) do
            root:CreateRadio(o.text, function() return Bl.Setting("layout", "vertical") == o.value end,
                function() ns.DB:SetSetting("bless.layout", o.value) end)
        end
    end
    root:CreateDivider()
    local c = root:CreateButton("Clear all", function() Bl:ClearAll() end)
    c:SetEnabled(Bl:CanEditAny())
    root:CreateButton("Ask the paladins again", function() Bl.Hello() end)
    if Bl:IsPaladin() then
        root:CreateButton("Settings", function()
            if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("settings") end
            if ns.SettingsUI then ns.SettingsUI:SelectSection("bless") end
        end)
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Drag a blessing
-- ---------------------------------------------------------------------------------------------------------------
local drag

local function DropTargets()
    local out = {}
    for _, row in ipairs(frame.rows) do
        if row:IsShown() and row.name then
            for _, cell in ipairs(row.cells) do out[#out + 1] = cell end
            out[#out + 1] = row.card
        end
    end
    local add = frame.rule.add
    if add and add:IsShown() then out[#out + 1] = add end
    return out
end

-- the target under the cursor that takes the dragged blessing
local function TargetUnderCursor()
    local bi = drag and drag.payload
    for _, f in ipairs(DropTargets()) do
        if f:IsVisible() and f:IsMouseOver() then
            if f.CanDrop and f:CanDrop(bi) then return f end
            return nil
        end
    end
    return nil
end

local function StartDrag(bi)
    if not drag then drag = PW.NewDrag(frame, 34) end
    drag:Begin(B():BlessingIcon(bi, true), bi, TargetUnderCursor)
end

local function EndDrag()
    if not drag then return end
    local t, bi = drag:Finish()
    if t then t:Drop(bi) end
end
BUI.EndDrag = EndDrag

-- ---------------------------------------------------------------------------------------------------------------
-- Building (in the window's body; y from the body's top)
-- ---------------------------------------------------------------------------------------------------------------
local function BuildPalette(c)
    local cap = UI:Text(c, "caps", "SUB", { shadow = true, text = "Drag a blessing" })
    cap:SetPoint("TOPLEFT", c, "TOPLEFT", 2, -4)
    local list = {}
    for i, bi in ipairs(PALETTE) do
        local b = CreateFrame("Button", nil, c)
        b:SetSize(25, 25)
        b:SetPoint("TOPLEFT", c, "TOPLEFT", 2 + (i - 1) * 31, -22)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        PW.Crop(b.icon)
        PW.SetEdge(b, BLACK)
        b:RegisterForDrag("LeftButton")
        b:SetScript("OnDragStart", function() StartDrag(bi) end)
        b:SetScript("OnDragStop", EndDrag)
        PW.Tip(b, function()
            return B():BlessingName(bi, true), { "Drag onto a class (one paladin), a paladin's card (every class) "
                .. "or the exceptions' + (one player)." }
        end)
        b.bi = bi
        list[#list + 1] = b
    end
    return list
end

local function BuildHeader(c)
    local heads = {}
    local x0 = CARD_W + GAP
    for j, cls in ipairs(B().D.DISPLAY) do
        local h = CreateFrame("Frame", nil, c)
        h:SetSize(CELL_W, HEAD_H - 6)
        h:SetPoint("TOPLEFT", c, "TOPLEFT", x0 + (j - 1) * CELL_W, 0)
        h.icon = h:CreateTexture(nil, "ARTWORK")
        h.icon:SetSize(28, 28)
        h.icon:SetPoint("TOP", h, "TOP", 0, 0)
        UI:ClassIcon(h.icon, cls)
        h.count = UI:Text(h, "small", { UI:ClassColor(cls) }, { shadow = true })
        h.count:SetPoint("TOP", h.icon, "BOTTOM", 0, -3)
        PW.Tip(h, function(self)
            local lines = {}
            for _, m in ipairs(self.members or {}) do
                lines[#lines + 1] = m.name .. (m.pet and " (pet)" or "") .. (m.tank and " · tank" or "")
            end
            if #lines == 0 then lines[1] = "Nobody in the group." end
            return Plural(cls), lines
        end)
        h.cls = cls
        heads[j] = h
    end
    return heads
end

local function NewCell(row, j)
    local cell = PW.NewCell(row, CELL_W - 4, ROW_H)
    cell:SetPoint("TOPLEFT", row, "TOPLEFT", CARD_W + GAP + (j - 1) * CELL_W + 2, 0)
    cell.time = UI:Text(cell, "small", "GOLD", { shadow = true })
    cell.time:SetPoint("BOTTOM", cell, "BOTTOM", 0, 2)
    cell.exc = UI:CreateCountBadge(cell, 13, "muted")
    cell.exc:SetPoint("CENTER", cell.icon, "BOTTOMRIGHT", -1, 1)
    cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    cell:EnableMouseWheel(true)
    cell.ci = B().CLASS_INDEX[B().D.DISPLAY[j]]
    cell:SetScript("OnClick", function(self, button)
        local name = row.name
        if not name or not B():CanEdit(name) then return end
        if button == "RightButton" then
            B():SetAssign(name, self.ci, 0)
        elseif IsShiftKeyDown() then
            local bi = B():GetAssign(name, self.ci)
            if bi then B():SetRow(name, bi) end
        else
            CellMenu(self, name, self.ci)
        end
    end)
    cell:SetScript("OnMouseWheel", function(self, delta)
        local name = row.name
        if not name or not B():CanEdit(name) then return end
        local cur = B():GetAssign(name, self.ci) or 0
        for _ = 1, 7 do
            cur = (cur - delta) % 7                         -- 0 = none, 1..6
            if cur == 0 or B():Can(name, cur) then break end
        end
        B():SetAssign(name, self.ci, cur)
    end)
    cell:SetScript("OnEnter", function(self) PW.HoverEdge(self, true, row.name and B():CanEdit(row.name)) end)
    cell:SetScript("OnLeave", function(self) PW.HoverEdge(self, false) end)
    PW.Tip(cell, function(self) return BUI:CellTip(self, row.name) end)
    function cell:CanDrop(bi) return row.name and B():CanEdit(row.name) and B():Can(row.name, bi) end
    function cell:Drop(bi) B():SetAssign(row.name, self.ci, bi) end
    return cell
end

local function NewRow(c, i)
    local row = CreateFrame("Frame", nil, c)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -(HEAD_H + (i - 1) * (ROW_H + ROW_GAP)))
    row:SetPoint("RIGHT", c, "RIGHT", 0, 0)
    -- the card
    local card = PW.NewCard(row, { w = CARD_W, h = ROW_H, from = CARD_FROM, to = CARD_TO, bar = PAL_PINK,
        name = PAL_PINK, lineRight = 34 })
    card:SetPoint("TOPLEFT")
    -- the aura
    local aura = CreateFrame("Button", nil, card)
    aura:SetSize(22, 22)
    aura:SetPoint("RIGHT", card, "RIGHT", -8, 0)
    aura.icon = aura:CreateTexture(nil, "ARTWORK")
    aura.icon:SetAllPoints()
    PW.Crop(aura.icon)
    PW.SetEdge(aura, BLACK)
    aura:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    aura:SetScript("OnClick", function(self, button)
        if not row.name or not B():CanEdit(row.name) then return end
        if button == "RightButton" then B():SetAura(row.name, 0) else AuraMenu(self, row.name) end
    end)
    PW.Tip(aura, function(self)
        local ai = row.name and B():GetAura(row.name)
        local lines = { ai and B():AuraName(ai) or "No aura" }
        if self.clash then tinsert(lines, { "Same as " .. self.clash .. " in their party", 1, 0.45, 0.4 }) end
        if row.name and B():CanEdit(row.name) then
            tinsert(lines, { "Click: pick · Right-click: none", HINT[1], HINT[2], HINT[3] })
        end
        return "Aura", lines
    end)
    card.aura = aura
    PW.Tip(card, function(self) return BUI:CardTip(self, row.name) end)
    function card:CanDrop(bi) return row.name and B():CanEdit(row.name) and B():Can(row.name, bi) end
    function card:Drop(bi) B():SetRow(row.name, bi) end
    row.card = card
    row.cells = {}
    for j = 1, #B().D.DISPLAY do row.cells[j] = NewCell(row, j) end
    return row
end

local function NewChip(c)
    local chip = PW.NewSwapChip(c, CHIP_W, CHIP_H)
    chip:SetScript("OnClick", function(self, button)
        local e = self.ex
        if not e or not B():CanEdit(e.pal) then return end
        if button == "RightButton" then
            B():SetSingle(e.pal, e.ci, e.target, 0)
        else
            UI:ContextMenu(self, function(root)
                root:CreateTitle(strformat("%s · from %s", e.target, e.pal))
                AddSingleChoices(root, e.pal, e.ci, e.target)
                root:CreateDivider()
                root:CreateButton("Remove", function() B():SetSingle(e.pal, e.ci, e.target, 0) end)
            end)
        end
    end)
    PW.Tip(chip, function(self)
        local e = self.ex
        if not e then return nil end
        local Bl = B()
        local greater = Bl:GetAssign(e.pal, e.ci)
        local lines = { strformat("%s gives %s %s%s.", e.pal, e.target, Bl:BlessingName(e.bi),
            greater and (" instead of " .. Bl:BlessingName(greater, true)) or "") }
        if Bl:CanEdit(e.pal) then tinsert(lines, { "Click: change · Right-click: remove", HINT[1], HINT[2], HINT[3] }) end
        return "Exception", lines
    end)
    return chip
end

-- the "+" on the exceptions' rule: a menu, or a dropped blessing for one player
local ADD = { icon = "plus", onClick = function(self) AddExceptionMenu(self) end,
    tip = { "Add an exception", "One player gets a single blessing from a paladin instead of the class one, e.g. "
        .. "tanks on Light instead of Salvation. Or drop a blessing here." } }

local function Build(f, c)
    frame = f
    f.palette = BuildPalette(c)
    f.heads = BuildHeader(c)
    f.rows = {}
    f.chips = {}
    f.rule = PW.NewRule(c, "Exceptions", EXC_W)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Tooltips: title, lines
-- ---------------------------------------------------------------------------------------------------------------
function BUI:CellTip(cell, name)
    if not name then return nil end
    local Bl = B()
    local cls = Bl.D.CLASSES[cell.ci]
    local bi = Bl:GetAssign(name, cell.ci)
    local lines = {}
    local st = cell.state
    if st and st.total > 0 then
        lines[#lines + 1] = strformat("%d of %d have it", st.have, st.total)
        for _, m in ipairs(st.missing) do
            local why = (not m.demo and not UnitIsVisible(m.unit)) and " (far away)" or ""
            lines[#lines + 1] = { "Missing: " .. m.name .. why, 1, 0.55, 0.45 }
        end
        if st.left then lines[#lines + 1] = strformat("Runs out in %d min", floor(st.left / 60)) end
        if st.single > 0 then
            lines[#lines + 1] = strformat("%d get a single blessing instead (exceptions)", st.single)
        end
    end
    if Bl:CanEdit(name) then
        lines[#lines + 1] = { "Click: pick · Right-click: none · Wheel: next · Shift-click: every class", HINT[1], HINT[2],
            HINT[3] }
    else
        lines[#lines + 1] = { "Only " .. name .. ", the leader or an assistant can change it.", HINT[1], HINT[2], HINT[3] }
    end
    return strformat("%s · %s: %s", name, Plural(cls), bi and Bl:BlessingName(bi, true) or "nothing"), lines
end

function BUI:CardTip(card, name)
    if not name then return nil end
    local Bl = B()
    local p = Bl.pals[name]
    local lines = { Bl:SpecOf(name) .. " Paladin" }
    if p then
        local known = {}
        for bi = 1, 6 do
            local b = p.bless[bi]
            if b then
                known[#known + 1] = Bl.D.BLESSINGS[bi].short .. (b[2] and b[2] > 0 and strformat(" (+%d)", b[2]) or "")
            end
        end
        lines[#lines + 1] = "Can give: " .. (#known > 0 and table.concat(known, ", ") or "nothing yet")
        if p.symbols then lines[#lines + 1] = strformat("%d Symbols of Kings", p.symbols) end
        if p.free then lines[#lines + 1] = "Anyone may assign them" end
    end
    if Bl:CanEdit(name) then lines[#lines + 1] = { "Drop a blessing here: every class", HINT[1], HINT[2], HINT[3] } end
    return name, lines
end

-- ---------------------------------------------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------------------------------------------
local SPEC_ICON = { Holy = "Interface\\Icons\\Spell_Holy_HolyBolt", Protection = "Interface\\Icons\\Spell_Holy_DevotionAura",
    Retribution = "Interface\\Icons\\Spell_Holy_AuraOfLight" }

-- The banner's picture: the raid I am in (its instance id), else the generic one.
local function InstanceArt()
    local id = tonumber((select(8, GetInstanceInfo())))
    return (id and id > 0) and id or "other"
end

function BUI:Refresh()
    if not frame then return end
    local Bl = B()
    local c = frame.body
    local roster = Bl:Roster()
    local byClass = Bl:ByClass(roster)
    local pals = Bl:Paladins()

    -- banner
    local where = GetInstanceInfo()
    local inst = select(2, GetInstanceInfo())
    local parts = {}
    if inst == "raid" or inst == "party" then parts[#parts + 1] = where end
    local players = 0
    for _, m in ipairs(roster) do if not m.pet then players = players + 1 end end
    parts[#parts + 1] = strformat("%d player%s", players, players == 1 and "" or "s")
    parts[#parts + 1] = strformat("%d paladin%s", #pals, #pals == 1 and "" or "s")
    PW:Head(frame, Bl, table.concat(parts, " · "), InstanceArt())
    local canAny = Bl:CanEditAny()

    -- header
    for _, h in ipairs(frame.heads) do
        local ci = Bl.CLASS_INDEX[h.cls]
        h.members = byClass[ci]
        h.count:SetText(#byClass[ci])
        h.icon:SetAlpha(#byClass[ci] > 0 and 1 or 0.35)
        h.count:SetAlpha(#byClass[ci] > 0 and 1 or 0.35)
    end
    for _, b in ipairs(frame.palette) do b.icon:SetTexture(Bl:BlessingIcon(b.bi, true)) end

    -- rows
    local warnMin = (tonumber(Bl.Setting("warnMin", 5)) or 5) * 60
    local symWarn = tonumber(Bl.Setting("symbols", 20)) or 20
    local subOf = {}
    for _, m in ipairs(roster) do if not m.pet then subOf[m.name] = m.subgroup end end
    for i, p in ipairs(pals) do
        local row = frame.rows[i]
        if not row then
            row = NewRow(c, i)
            frame.rows[i] = row
        end
        row:Show()
        row.name = p.name
        local edit = Bl:CanEdit(p.name)
        local card = row.card
        card.name:SetText(p.name)
        card.crown:SetShown(Bl:IsLeader(p.name))
        local spec = Bl:SpecOf(p.name)
        card.spec:SetTexture(SPEC_ICON[spec] or SPEC_ICON.Holy)
        -- the talents; a low stock of Symbols of Kings instead when that needs doing (talents stay in the tooltip)
        local line = Bl:TalentLine(p.name)
        if p.symbols and p.symbols < symWarn then
            line = strformat("|cffff7a6aOnly %d Symbols left|r", p.symbols)
        end
        card.line:SetText(line ~= "" and line or (spec .. " Paladin"))
        local ai = Bl:GetAura(p.name)
        card.aura.icon:SetTexture(ai and Bl:AuraIcon(ai) or "Interface\\Icons\\INV_Misc_QuestionMark")
        card.aura.icon:SetDesaturated(not ai)
        card.aura.icon:SetAlpha(ai and 1 or 0.35)
        -- the same aura in the same party
        card.aura.clash = nil
        if ai then
            for _, q in ipairs(pals) do
                if q.name ~= p.name and Bl:GetAura(q.name) == ai and (subOf[q.name] or 1) == (subOf[p.name] or 1) then
                    card.aura.clash = q.name
                end
            end
        end
        PW.SetEdge(card.aura, card.aura.clash and CLASH or BLACK)
        card:SetAlpha(edit and 1 or 0.8)
        for _, cell in ipairs(row.cells) do
            local bi = Bl:GetAssign(p.name, cell.ci)
            cell.icon:SetShown(bi ~= nil)
            cell.empty:SetShown(bi == nil)
            if bi then cell.icon:SetTexture(Bl:BlessingIcon(bi, true)) end
            cell.icon:SetAlpha(edit and 1 or 0.75)
            local st = Bl:ClassState(p.name, cell.ci, byClass)
            cell.state = st
            if Bl:InGroup() and st.total > 0 then
                cell.miss:SetCount(#st.missing)
                local soon = st.left and st.left < warnMin
                cell.time:SetText(soon and strformat("%dm", max(0, floor(st.left / 60))) or "")
            else
                cell.miss:SetCount(0)
                cell.time:SetText("")
            end
            cell.exc:SetCount(st.single)
        end
    end
    for i = #pals + 1, #frame.rows do
        frame.rows[i]:Hide()
        frame.rows[i].name = nil
    end
    local rowsH = max(1, #pals) * (ROW_H + ROW_GAP)
    local empty = frame.empty
    empty:SetShown(#pals == 0)
    if #pals == 0 then
        empty:ClearAllPoints()
        empty:SetPoint("TOP", c, "TOPLEFT", CARD_W + GAP + 9 * CELL_W / 2, -(HEAD_H + 6))
        rowsH = floor(empty:GetHeight() + 0.5) + 16
    end

    -- exceptions: the rule ("EXCEPTIONS 12 ---- +"), then the chips under it from the left edge
    local ey = HEAD_H + rowsH + 6
    local ex = Bl:Exceptions()
    local rule = frame.rule
    rule:ClearAllPoints()
    rule:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -(ey + 2))
    rule:SetCount(#ex > 0 and #ex or nil)
    rule:SetAdd((#pals > 0 and canAny) and ADD or nil)
    if rule.add and not rule.add.CanDrop then
        function rule.add:CanDrop() return B():CanEditAny() end
        function rule.add:Drop(bi) AddExceptionMenu(self, bi) end
    end
    local cy = ey + RULE_H + 8
    for i, e in ipairs(ex) do
        local chip = frame.chips[i]
        if not chip then
            chip = NewChip(c)
            frame.chips[i] = chip
        end
        local col, line = (i - 1) % CHIP_PER, floor((i - 1) / CHIP_PER)
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", c, "TOPLEFT", col * CHIP_PITCH, -(cy + line * (CHIP_H + 6)))
        chip.ex = e
        local rgb = { UI:ClassColor(Bl.D.CLASSES[e.ci]) }
        local greater = Bl:GetAssign(e.pal, e.ci)
        PW.FillSwapChip(chip, greater and Bl:BlessingIcon(greater, true) or nil, Bl:BlessingIcon(e.bi), rgb, e.target,
            rgb, "from " .. e.pal)
        chip:Show()
    end
    for i = #ex + 1, #frame.chips do frame.chips[i]:Hide() end
    local lines = math.ceil(#ex / CHIP_PER)
    PW:Fit(frame, (lines > 0) and (cy + lines * (CHIP_H + 6) - 6) or (ey + RULE_H))
end

-- ---------------------------------------------------------------------------------------------------------------
-- The window (Open / Close / Toggle / IsShown / GetFrame: UI/PlannerWindow.lua)
-- ---------------------------------------------------------------------------------------------------------------
PW:Install(BUI, {
    name = "DisasterZoneBlessings", title = "Blessings", width = W, every = 5, event = "BLESSINGS_CHANGED",
    core = function() return ns.Blessings end,
    autoTip = "Gives every paladin you may change the blessings that fit their talents: Kings first, the best Might "
        .. "and Wisdom, then Salvation and Light. Tanks get a single blessing instead of Salvation, and each party "
        .. "gets different auras.",
    actions = {
        { icon = "more", menu = MoreMenu, tip = "More" },
        { key = "presets", icon = "notes", menu = PresetMenu,
          tip = { "Presets", "Save this plan for a raid, or load a saved one." } },
        { key = "report", icon = "whisper", onClick = function() B():Report() end,
          tip = { "Report", "Posts who gives what to the raid (or party) chat." } },
    },
    empty = { icon = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings", title = "No paladins here yet",
        text = "Paladins in your group show up here, with DisasterZone or Pally Power." },
    build = Build,
})
