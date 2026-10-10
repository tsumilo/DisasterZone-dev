if DisasterZoneBoot and DisasterZoneBoot.Run("UI/BlessingsUI.lua", ...) then return end -- DisasterZone: blessings planner.
-- The Blessings planner window (Core/Blessings.lua): paladins as rows, classes as columns, one Greater Blessing per
-- cell (Pally Power's layout, made over). Under it the exceptions: one player getting a single blessing instead of
-- the class one (tanks: no Salvation).
--   banner     the raid's art, "Blessings", where and how many; who assigns; Report, Presets, More, Auto-assign
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

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format
local tinsert = table.insert

local W = 760
local PAD, GAP = 10, 8
local BANNER_H = 72
local CARD_W, ROW_H, ROW_GAP = 192, 54, 6
local CELL_W, ICON = 58, 32
local HEAD_H = 52
-- exceptions: a rule across the width ("EXCEPTIONS 12 ---- +"), then chips from the left edge, 4 a line
local EXC_W = CARD_W + GAP + 9 * CELL_W - 2        -- the grid's width (cards to the last cell)
local RULE_H, CHIP_PER = 22, 4
local CHIP_H = 36
local CHIP_W = floor((EXC_W - (CHIP_PER - 1) * 6) / CHIP_PER)
local CHIP_PITCH = CHIP_W + 6
local PALETTE = { 3, 2, 1, 4, 5, 6 }
local PAL_PINK = { 0.96, 0.55, 0.73 }
local GOLD = { 1, 0.82, 0 }
local GREY = { 0.62, 0.62, 0.64 }
local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local INST_ART = { [532] = "kara", [565] = "gruul", [544] = "mag", [548] = "ssc", [550] = "tk", [534] = "hyjal",
    [564] = "bt", [568] = "za", [580] = "swp" }

local function UI() return ns.UI end
local function B() return ns.Blessings end
local function EUI() return ns.EventUI end

local frame

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

local function ClassRGB(cls)
    return UI():ClassColor(cls)
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

local function ClassLabel(cls)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls]) or cls
end

local function Plural(cls)
    local n = ClassLabel(cls)
    return n:sub(-1) == "f" and n or (n .. "s")
end

-- ---------------------------------------------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------------------------------------------
-- The blessings paladin `name` can give as a Greater (radio entries) for class ci, and a submenu "Every class".
local function CellMenu(owner, name, ci)
    local Bl = B()
    local cls = Bl.D.CLASSES[ci]
    UI():ContextMenu(owner, function(root)
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
    UI():ContextMenu(owner, function(root)
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
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(bi and ("Give one player " .. Bl.D.BLESSINGS[bi].short) or "A single blessing for one player")
        local byClass = Bl:ByClass()
        local any = false
        for _, cls in ipairs(Bl.D.DISPLAY) do
            local ci = Bl.CLASS_INDEX[cls]
            local members = byClass[ci]
            if #members > 0 then
                local r, g, b = ClassRGB(cls)
                local ce = root:CreateButton(strformat("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, Plural(cls)))
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

local function PresetMenu(owner)
    local Bl = B()
    UI():ContextMenu(owner, function(root)
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
    end)
end

local function MoreMenu(owner)
    local Bl = B()
    UI():ContextMenu(owner, function(root)
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
    end)
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
    if frame.addChip and frame.addChip:IsShown() then out[#out + 1] = frame.addChip end
    return out
end

local function TargetUnderCursor()
    for _, f in ipairs(DropTargets()) do
        if f:IsVisible() and f:IsMouseOver() then return f end
    end
    return nil
end

local function StartDrag(bi)
    if not drag then
        drag = CreateFrame("Frame", nil, UIParent)
        drag:SetSize(34, 34)
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
    drag.bi = bi
    drag.icon:SetTexture(B():BlessingIcon(bi, true))
    drag:Show()
    drag:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / s, y / s)
        local t = TargetUnderCursor()
        local ok = t and t.CanDrop and t:CanDrop(self.bi)
        if ok then
            self.mark:ClearAllPoints()
            self.mark:SetAllPoints(t)
            self.mark:Show()
        else
            self.mark:Hide()
        end
    end)
end

local function EndDrag()
    if not drag or not drag:IsShown() then return end
    local t = TargetUnderCursor()
    local bi = drag.bi
    drag:Hide()
    drag:SetScript("OnUpdate", nil)
    drag.mark:Hide()
    if t and t.CanDrop and t:CanDrop(bi) then t:Drop(bi) end
end
BUI.EndDrag = EndDrag

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
    bn.title:SetText("Blessings")
    bn.sub = Text(bn, 11, { 0.68, 0.68, 0.7 })
    bn.sub:SetPoint("TOPLEFT", bn, "TOPLEFT", 14, -43)
    bn.who = Text(bn, 9.5, { 0.68, 0.68, 0.7 })
    bn.who:SetPoint("TOPRIGHT", bn, "TOPRIGHT", -12, -11)
    bn.who:SetJustifyH("RIGHT")

    local auto = UI():CreateSleekButton(bn, "Auto-assign", 100, 22, function()
        if B():CanEditAny() then B():AutoAssign() end
    end, "primary")
    auto:SetPoint("TOPRIGHT", bn, "TOPRIGHT", -12, -36)
    auto:HookScript("OnEnter", function(self)
        Tip(self, "Auto-assign", { "Gives every paladin you may change the blessings that fit their talents: "
            .. "Kings first, the best Might and Wisdom, then Salvation and Light. Tanks get a single blessing "
            .. "instead of Salvation, and each party gets different auras." })
    end)
    auto:HookScript("OnLeave", function() GameTooltip:Hide() end)
    bn.auto = auto
    local more = UI():CreateTipIconButton(bn, 22, UI().ICON.more, "More", nil, function(self) MoreMenu(self) end)
    more:SetPoint("RIGHT", auto, "LEFT", -6, 0)
    local presets = UI():CreateTipIconButton(bn, 22, UI().ICON.notes, "Presets",
        "Save this plan for a raid, or load a saved one.", function(self) PresetMenu(self) end)
    presets:SetPoint("RIGHT", more, "LEFT", -4, 0)
    bn.presets = presets
    local report = UI():CreateTipIconButton(bn, 22, UI().ICON.whisper, "Report",
        "Posts who gives what to the raid (or party) chat.", function() B():Report() end)
    report:SetPoint("RIGHT", presets, "LEFT", -4, 0)
    bn.report = report
    return bn
end

local function BuildPalette(c)
    local cap = Text(c, 9.5, GREY)
    cap:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + 2, -(PAD + BANNER_H + 12))
    cap:SetText("DRAG A BLESSING")
    local list = {}
    for i, bi in ipairs(PALETTE) do
        local b = CreateFrame("Button", nil, c)
        b:SetSize(25, 25)
        b:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + 2 + (i - 1) * 31, -(PAD + BANNER_H + 30))
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        Edge(b, 0, 0, 0, 1)
        b:RegisterForDrag("LeftButton")
        b:SetScript("OnDragStart", function() StartDrag(bi) end)
        b:SetScript("OnDragStop", EndDrag)
        b:SetScript("OnEnter", function(self)
            Tip(self, B():BlessingName(bi, true), { "Drag onto a class (one paladin), a paladin's card (every class) "
                .. "or the exceptions' + (one player)." })
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b.bi = bi
        list[#list + 1] = b
    end
    return list
end

local function BuildHeader(c)
    local heads = {}
    local x0 = PAD + CARD_W + GAP
    for j, cls in ipairs(B().D.DISPLAY) do
        local h = CreateFrame("Frame", nil, c)
        h:SetSize(CELL_W, HEAD_H - 6)
        h:SetPoint("TOPLEFT", c, "TOPLEFT", x0 + (j - 1) * CELL_W, -(PAD + BANNER_H + 8))
        h.icon = h:CreateTexture(nil, "ARTWORK")
        h.icon:SetSize(28, 28)
        h.icon:SetPoint("TOP", h, "TOP", 0, 0)
        ClassCircle(h.icon, cls)
        h.count = Text(h, 10.5)
        h.count:SetPoint("TOP", h.icon, "BOTTOM", 0, -3)
        h.count:SetTextColor(ClassRGB(cls))
        h:EnableMouse(true)
        h:SetScript("OnEnter", function(self)
            local lines = {}
            for _, m in ipairs(self.members or {}) do
                lines[#lines + 1] = m.name .. (m.pet and " (pet)" or "") .. (m.tank and " · tank" or "")
            end
            if #lines == 0 then lines[1] = "Nobody in the group." end
            Tip(self, Plural(cls), lines)
        end)
        h:SetScript("OnLeave", function() GameTooltip:Hide() end)
        h.cls = cls
        heads[j] = h
    end
    return heads
end

local function NewCell(row, j)
    local cell = CreateFrame("Button", nil, row)
    cell:SetSize(CELL_W - 4, ROW_H)
    cell:SetPoint("TOPLEFT", row, "TOPLEFT", CARD_W + GAP + (j - 1) * CELL_W + 2, 0)
    cell.bg = Fill(cell:CreateTexture(nil, "BACKGROUND"), 0.1, 0.1, 0.118, 1)
    cell.bg:SetAllPoints()
    Edge(cell, 0.15, 0.15, 0.17, 1)
    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon:SetSize(ICON, ICON)
    cell.icon:SetPoint("CENTER")
    cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    cell.empty = cell:CreateTexture(nil, "ARTWORK")
    cell.empty:SetSize(ICON - 6, ICON - 6)
    cell.empty:SetPoint("CENTER")
    Fill(cell.empty, 1, 1, 1, 0.03)
    cell.miss = UI():CreateCountBadge(cell, 13)
    cell.miss:SetPoint("CENTER", cell.icon, "TOPRIGHT", -1, -1)
    cell.time = Text(cell, 10, GOLD, "OVERLAY", "GameFontHighlightSmall")
    cell.time:SetPoint("BOTTOM", cell, "BOTTOM", 0, 2)
    cell.exc = UI():CreateCountBadge(cell, 13, "muted")
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
    cell:SetScript("OnEnter", function(self)
        if row.name and B():CanEdit(row.name) then UI():SetEdgeColor(self, 1, 0.82, 0, 0.9) end
        BUI:CellTip(self, row.name)
    end)
    cell:SetScript("OnLeave", function(self)
        UI():SetEdgeColor(self, 0.15, 0.15, 0.17, 1)
        GameTooltip:Hide()
    end)
    function cell:CanDrop(bi) return row.name and B():CanEdit(row.name) and B():Can(row.name, bi) end
    function cell:Drop(bi) B():SetAssign(row.name, self.ci, bi) end
    return cell
end

local function NewRow(c, i)
    local row = CreateFrame("Frame", nil, c)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -(PAD + BANNER_H + HEAD_H + 8 + (i - 1) * (ROW_H + ROW_GAP)))
    row:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    -- the card
    local card = CreateFrame("Button", nil, row)
    card:SetSize(CARD_W, ROW_H)
    card:SetPoint("TOPLEFT")
    card.bg = card:CreateTexture(nil, "BACKGROUND")
    card.bg:SetAllPoints()
    card.bg:SetTexture(WHITE8)
    if card.bg.SetGradient and CreateColor then
        card.bg:SetGradient("HORIZONTAL", CreateColor(0.27, 0.16, 0.21, 0.95), CreateColor(0.12, 0.12, 0.14, 0.95))
    else
        card.bg:SetVertexColor(0.16, 0.13, 0.15, 0.95)
    end
    Edge(card, 0.17, 0.17, 0.19, 1)
    card.bar = Fill(card:CreateTexture(nil, "BORDER"), PAL_PINK[1], PAL_PINK[2], PAL_PINK[3], 1)
    card.bar:SetPoint("TOPLEFT")
    card.bar:SetPoint("BOTTOMLEFT")
    card.bar:SetWidth(2)
    card.spec = card:CreateTexture(nil, "ARTWORK")
    card.spec:SetSize(26, 26)
    card.spec:SetPoint("LEFT", card, "LEFT", 8, 0)
    card.spec:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    card.name = Text(card, 12.5, PAL_PINK)
    card.name:SetPoint("TOPLEFT", card, "TOPLEFT", 40, -10)
    card.crown = card:CreateTexture(nil, "OVERLAY")
    card.crown:SetSize(11, 11)
    card.crown:SetPoint("LEFT", card.name, "RIGHT", 4, 0)
    card.crown:SetTexture(UI().ICON_ATLAS)
    local cc = UI():IconCoords(UI().ICON.crown)
    card.crown:SetTexCoord(cc[1], cc[2], cc[3], cc[4])
    card.crown:SetVertexColor(1, 0.82, 0)
    card.line = Text(card, 10, GREY)
    card.line:SetPoint("TOPLEFT", card, "TOPLEFT", 40, -29)
    card.line:SetPoint("RIGHT", card, "RIGHT", -34, 0)
    -- the aura
    local aura = CreateFrame("Button", nil, card)
    aura:SetSize(22, 22)
    aura:SetPoint("RIGHT", card, "RIGHT", -8, 0)
    aura.icon = aura:CreateTexture(nil, "ARTWORK")
    aura.icon:SetAllPoints()
    aura.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    Edge(aura, 0, 0, 0, 1)
    aura:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    aura:SetScript("OnClick", function(self, button)
        if not row.name or not B():CanEdit(row.name) then return end
        if button == "RightButton" then B():SetAura(row.name, 0) else AuraMenu(self, row.name) end
    end)
    aura:SetScript("OnEnter", function(self)
        local ai = row.name and B():GetAura(row.name)
        local lines = { ai and B():AuraName(ai) or "No aura" }
        if self.clash then tinsert(lines, { "Same as " .. self.clash .. " in their party", 1, 0.45, 0.4 }) end
        if row.name and B():CanEdit(row.name) then tinsert(lines, { "Click: pick · Right-click: none", 0.6, 0.6, 0.6 }) end
        Tip(self, "Aura", lines)
    end)
    aura:SetScript("OnLeave", function() GameTooltip:Hide() end)
    card.aura = aura
    card:SetScript("OnEnter", function(self) BUI:CardTip(self, row.name) end)
    card:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function card:CanDrop(bi) return row.name and B():CanEdit(row.name) and B():Can(row.name, bi) end
    function card:Drop(bi) B():SetRow(row.name, bi) end
    row.card = card
    row.cells = {}
    for j = 1, #B().D.DISPLAY do row.cells[j] = NewCell(row, j) end
    return row
end

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
    -- the swap: the class's blessing faded, a hairline warming from grey to gold into a gold chevron, and the
    -- player's own blessing in a thin gold frame
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
        local e = self.ex
        if not e or not B():CanEdit(e.pal) then return end
        if button == "RightButton" then
            B():SetSingle(e.pal, e.ci, e.target, 0)
        else
            UI():ContextMenu(self, function(root)
                root:CreateTitle(strformat("%s · from %s", e.target, e.pal))
                AddSingleChoices(root, e.pal, e.ci, e.target)
                root:CreateDivider()
                root:CreateButton("Remove", function() B():SetSingle(e.pal, e.ci, e.target, 0) end)
            end)
        end
    end)
    chip:SetScript("OnEnter", function(self)
        local e = self.ex
        if not e then return end
        local Bl = B()
        local greater = Bl:GetAssign(e.pal, e.ci)
        local lines = { strformat("%s gives %s %s%s.", e.pal, e.target, Bl:BlessingName(e.bi),
            greater and (" instead of " .. Bl:BlessingName(greater, true)) or "") }
        if Bl:CanEdit(e.pal) then tinsert(lines, { "Click: change · Right-click: remove", 0.6, 0.6, 0.6 }) end
        Tip(self, "Exception", lines)
    end)
    chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return chip
end

local function Build()
    frame = UI():CreateWindow("DisasterZoneBlessings", "Blessings", W, 420)
    frame:Hide()
    frame:SetScript("OnShow", function() BUI:Refresh() end)
    local c = frame.content
    frame.banner = BuildBanner(c)
    frame.palette = BuildPalette(c)
    frame.heads = BuildHeader(c)
    frame.rows = {}
    frame.chips = {}
    frame.excCap = Text(c, 9.5, GREY)
    frame.excCap:SetText("EXCEPTIONS")
    frame.excCount = Text(c, 10, { 0.47, 0.47, 0.5 })
    frame.excRule = c:CreateTexture(nil, "ARTWORK")
    frame.excRule:SetTexture(WHITE8)
    frame.excRule:SetHeight(1)
    if frame.excRule.SetGradient and CreateColor then
        frame.excRule:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, 0.14), CreateColor(1, 1, 1, 0.04))
    else
        frame.excRule:SetVertexColor(1, 1, 1, 0.08)
    end
    local add = CreateFrame("Button", nil, c)
    add:SetSize(RULE_H, RULE_H)
    Edge(add, 0.24, 0.24, 0.27, 1)
    add.plus = Text(add, 15, { 0.6, 0.6, 0.64 })
    add.plus:SetPoint("CENTER", 0, 1)
    add.plus:SetText("+")
    add:SetScript("OnClick", function(self) AddExceptionMenu(self) end)
    add:SetScript("OnEnter", function(self)
        UI():SetEdgeColor(self, 1, 0.82, 0, 0.9)
        Tip(self, "Add an exception", { "One player gets a single blessing from a paladin instead of the class one, "
            .. "e.g. tanks on Light instead of Salvation. Or drop a blessing here." })
    end)
    add:SetScript("OnLeave", function(self)
        UI():SetEdgeColor(self, 0.24, 0.24, 0.27, 1)
        GameTooltip:Hide()
    end)
    function add:CanDrop(bi) return B():CanEditAny() end
    function add:Drop(bi) AddExceptionMenu(self, bi) end
    frame.addChip = add
    frame.emptyTitle = Text(c, 14, { 0.85, 0.85, 0.87 })
    frame.emptyTitle:SetText("No paladins here yet")
    frame.emptyText = Text(c, 11, GREY)
    frame.emptyText:SetText("Paladins in your group show up here, with DisasterZone or Pally Power.")
    frame.emptyTitle:SetPoint("TOPLEFT", c, "TOPLEFT", PAD + CARD_W + GAP, -(PAD + BANNER_H + HEAD_H + 26))
    frame.emptyText:SetPoint("TOPLEFT", frame.emptyTitle, "BOTTOMLEFT", 0, -6)
    -- live timers: refresh while open
    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc >= 5 then
            acc = 0
            BUI:Refresh()
        end
    end)
    ns:On("BLESSINGS_CHANGED", function() if frame:IsShown() then BUI:Refresh() end end)
    ns:On("GROUP_UPDATED", function() if frame:IsShown() then BUI:Refresh() end end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Tooltips
-- ---------------------------------------------------------------------------------------------------------------
function BUI:CellTip(cell, name)
    if not name then return end
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
        lines[#lines + 1] = { "Click: pick · Right-click: none · Wheel: next · Shift-click: every class", 0.6, 0.6, 0.6 }
    else
        lines[#lines + 1] = { "Only " .. name .. ", the leader or an assistant can change it.", 0.6, 0.6, 0.6 }
    end
    Tip(cell, strformat("%s · %s: %s", name, Plural(cls), bi and Bl:BlessingName(bi, true) or "nothing"), lines)
end

function BUI:CardTip(card, name)
    if not name then return end
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
    if Bl:CanEdit(name) then lines[#lines + 1] = { "Drop a blessing here: every class", 0.6, 0.6, 0.6 } end
    Tip(card, name, lines)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------------------------------------------
local function InstanceArt()
    local id = select(8, GetInstanceInfo())
    return INST_ART[tonumber(id) or 0] or "other"
end

function BUI:Refresh()
    if not frame then return end
    local Bl = B()
    local c = frame.content
    local roster = Bl:Roster()
    local byClass = Bl:ByClass(roster)
    local pals = Bl:Paladins()

    -- banner
    local bn = frame.banner
    local PlanUI = ns.RaidPlanUI
    if PlanUI and PlanUI.RaidArt then
        local path, l, r, t, b = PlanUI:RaidArt(InstanceArt(), W - 2 * PAD, BANNER_H, 0.62)
        bn.art:SetTexture(path)
        bn.art:SetTexCoord(l, r, t, b)
    end
    local where = GetInstanceInfo()
    local inst = select(2, GetInstanceInfo())
    local parts = {}
    if inst == "raid" or inst == "party" then parts[#parts + 1] = where end
    local players = 0
    for _, m in ipairs(roster) do if not m.pet then players = players + 1 end end
    parts[#parts + 1] = strformat("%d player%s", players, players == 1 and "" or "s")
    parts[#parts + 1] = strformat("%d paladin%s", #pals, #pals == 1 and "" or "s")
    bn.sub:SetText(table.concat(parts, " · "))
    local who
    if Bl:IsDemo() then who = "DEMO MODE · YOU ASSIGN"
    elseif not IsInGroup() then who = "SOLO"
    elseif Bl:AmLeader() or ns.Util.IsPlayerLeaderOrAssist() then who = "YOU ASSIGN"
    else
        local lead = Bl:LeaderName()
        who = lead and (lead:upper() .. " ASSIGNS") or ""
    end
    bn.who:SetText(who)
    local canAny = Bl:CanEditAny()
    bn.auto:SetEnabled(canAny)
    bn.report:SetEnabled(Bl:InGroup())

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
        local SPEC_ICON = { Holy = "Interface\\Icons\\Spell_Holy_HolyBolt", Protection = "Interface\\Icons\\Spell_Holy_DevotionAura",
            Retribution = "Interface\\Icons\\Spell_Holy_AuraOfLight" }
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
        if card.aura.clash then UI():SetEdgeColor(card.aura, 0.88, 0.38, 0.31, 1) else UI():SetEdgeColor(card.aura, 0, 0, 0, 1) end
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
    frame.emptyTitle:SetShown(#pals == 0)
    frame.emptyText:SetShown(#pals == 0)

    -- exceptions: the rule ("EXCEPTIONS 12 ---- +"), then the chips under it from the left edge
    local rowsH = max(1, #pals) * (ROW_H + ROW_GAP)
    local ey = PAD + BANNER_H + HEAD_H + 8 + rowsH + 6
    local ex = Bl:Exceptions()
    local x0 = PAD
    local perLine = CHIP_PER
    local mid = -(ey + RULE_H / 2)
    frame.excCap:ClearAllPoints()
    frame.excCap:SetPoint("LEFT", c, "TOPLEFT", x0 + 2, mid)
    frame.excCount:ClearAllPoints()
    frame.excCount:SetPoint("LEFT", frame.excCap, "RIGHT", 8, 0)
    frame.excCount:SetText(#ex > 0 and #ex or "")
    frame.addChip:ClearAllPoints()
    frame.addChip:SetPoint("TOPRIGHT", c, "TOPLEFT", x0 + EXC_W, -ey)
    frame.addChip:SetShown(#pals > 0 and canAny)
    frame.excRule:ClearAllPoints()
    frame.excRule:SetPoint("LEFT", #ex > 0 and frame.excCount or frame.excCap, "RIGHT", 10, 0)
    frame.excRule:SetPoint("RIGHT", c, "TOPLEFT", x0 + EXC_W - (frame.addChip:IsShown() and (RULE_H + 8) or 0), mid)
    local cy = ey + RULE_H + 8
    for i, e in ipairs(ex) do
        local chip = frame.chips[i]
        if not chip then
            chip = NewChip(c)
            frame.chips[i] = chip
        end
        local col, line = (i - 1) % perLine, floor((i - 1) / perLine)
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", c, "TOPLEFT", x0 + col * CHIP_PITCH, -(cy + line * (CHIP_H + 6)))
        chip.ex = e
        local cls = Bl.D.CLASSES[e.ci]
        local r, g, b = ClassRGB(cls)
        chip.bar:SetVertexColor(r, g, b, 1)
        chip.name:SetText(e.target)
        chip.name:SetTextColor(r, g, b)
        chip.sub:SetText("from " .. e.pal)
        local greater = Bl:GetAssign(e.pal, e.ci)
        chip.was:SetShown(greater ~= nil)
        chip.line:SetShown(greater ~= nil)
        chip.tip:SetShown(greater ~= nil)
        if greater then chip.was:SetTexture(Bl:BlessingIcon(greater, true)) end
        chip.now.icon:SetTexture(Bl:BlessingIcon(e.bi))
        chip:Show()
    end
    for i = #ex + 1, #frame.chips do frame.chips[i]:Hide() end
    local lines = math.ceil(#ex / perLine)
    local contentH = (lines > 0) and (cy + lines * (CHIP_H + 6) - 6 + PAD) or (ey + RULE_H + PAD)
    frame:SetHeight(contentH + 34)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------------------------------------------
function BUI:Open()
    if not frame then Build() end
    if InCombatLockdown() then
        -- (the window has no secure parts; it opens in combat too)
    end
    frame:Show()
    self:Refresh()
    if ns.Blessings and IsInGroup() then ns.Blessings.Hello() end
end

function BUI:Close() if frame then frame:Hide() end end

function BUI:Toggle()
    if frame and frame:IsShown() then self:Close() else self:Open() end
end

function BUI:IsShown() return frame and frame:IsShown() or false end
function BUI:GetFrame() return frame end
