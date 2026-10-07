if DisasterZoneBoot and DisasterZoneBoot.Run("UI/GemEditor.lua", ...) then return end -- DisasterZone UI/GemEditor.lua
-- ns.GemEditor: the gems and enchant of one BiS pick, in a flat panel beside its My BiS tile (the tile's strip opens
-- it). Top to bottom: the item; a row per socket (the gem in a socket-coloured edge, or the empty socket); the socket
-- bonus (green while every socket holds a gem of its colour, else what it still needs) and a meta gem's rule; the
-- choices for the picked row (the spec's suggestions first - "Best", "No bonus" when the guide's top gem skips it -
-- then every other gem of that colour, or every enchant that fits; a search box looks through all of them); the
-- enchant row; Clear and Use suggested.
-- A choice is stored at once (BiS:SetGemSetup) and the next empty socket is picked. Right-click a row: empty it.
-- A click outside, Escape, the page hiding or another tile's strip closes / moves it.
local addonName, ns = ...

local GemEditor = {}
ns.GemEditor = GemEditor

local floor, min, max = math.floor, math.min, math.max

local W = 280
local PAD = 10
local ROW_H, CHOICE_H = 30, 28
local CHIP, CHOICE_CHIP = 22, 18
local VISIBLE_CHOICES = 6
local GOLD = { 1, 0.82, 0 }
local GREEN = { 0.3, 0.9, 0.3 }
local GREY = { 0.62, 0.62, 0.65 }
local DIM = { 0.45, 0.45, 0.48 }
local ENCHANT_NAME = { 0.12, 1, 0 }

local frame
local state = {}   -- sid, itemID, phase, list, target ("s1".."s4" or "e"), search

local function G() return ns.Gems end
local function UI() return ns.UI end

local function Text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function Fill(f, layer)
    local t = f:CreateTexture(nil, layer or "BACKGROUND")
    t:SetAllPoints()
    return t
end

local function View()
    local BiS = ns.BiS
    return BiS and BiS:GetListView(state.list) or nil
end

local function Setup()
    return G():GetSetup(View(), state.itemID)
end

local function Profs()
    return G():ProfessionSet()
end

local function Guide()
    return G():GuideFor(View())
end

-- Stores the setup with one socket / the enchant changed (value 0 = empty it).
local function Store(target, value)
    local enchant, gems = Setup()
    local sockets = G():Sockets(state.itemID)
    local out = {}
    for i = 1, #sockets do out[i] = gems[i] or 0 end
    if target == "e" then
        enchant = value
    else
        out[tonumber(target:sub(2))] = value
    end
    ns.BiS:SetGemSetup(state.itemID, enchant, out, state.list)
end

-- The next row that is still empty after `target` (from target itself when inclusive; sockets in order, then the
-- enchant), else target.
local function NextEmpty(target, inclusive)
    local enchant, gems = Setup()
    local sockets = G():Sockets(state.itemID)
    local order = {}
    for i = 1, #sockets do order[#order + 1] = "s" .. i end
    if G():CanEnchant(state.itemID, Profs()) then order[#order + 1] = "e" end
    local start = 0
    for i, t in ipairs(order) do if t == target then start = inclusive and (i - 1) or i end end
    for k = 1, #order do
        local t = order[(start + k - 1) % #order + 1]
        local empty = (t == "e") and enchant == 0 or (t ~= "e" and (gems[tonumber(t:sub(2))] or 0) == 0)
        if empty then return t end
    end
    return target
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function CreateChip(parent, size)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(size, size)
    c.bg = Fill(c)
    c.bg:SetColorTexture(0.05, 0.05, 0.06, 1)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetPoint("TOPLEFT", 1, -1)
    c.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    c.plus = Text(c, "GameFontHighlight", "CENTER")
    c.plus:SetPoint("CENTER", 0, 0)
    c.plus:SetText("+")
    c.plus:SetTextColor(0.6, 0.6, 0.64)
    UI():AddEdges(c, "OVERLAY")
    return c
end

local function PaintChip(c, icon, edge, crop, plus)
    c.icon:SetTexture(icon)
    c.icon:SetShown(icon ~= nil)
    if crop then c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) else c.icon:SetTexCoord(0, 1, 0, 1) end
    c.plus:SetShown(plus and true or false)
    UI():SetEdgeColor(c, edge[1], edge[2], edge[3], edge[4] or 1)
end

-- A socket / enchant row: chip, name, effect line; gold edges while it is the picked row.
local function CreateRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(W - 2 * PAD, ROW_H)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.fill = Fill(r)
    r.fill:SetColorTexture(1, 1, 1, 0)
    UI():AddEdges(r, "BORDER")
    UI():SetEdgeColor(r, 0, 0, 0, 0)
    r.chip = CreateChip(r, CHIP)
    r.chip:SetPoint("LEFT", r, "LEFT", 4, 0)
    r.name = Text(r, "GameFontHighlight")
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", CHIP + 12, -3)
    r.name:SetPoint("TOPRIGHT", r, "TOPRIGHT", -4, -3)
    r.effect = Text(r, "GameFontHighlightSmall")
    r.effect:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", CHIP + 12, 3)
    r.effect:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -4, 3)
    r:SetScript("OnEnter", function(self)
        self.hovered = true
        GemEditor:PaintRow(self)
        if self.tip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            self.tip(GameTooltip)
            GameTooltip:Show()
        end
    end)
    r:SetScript("OnLeave", function(self)
        self.hovered = false
        GemEditor:PaintRow(self)
        GameTooltip:Hide()
    end)
    r:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            Store(self.target, 0)
            state.target = self.target
        else
            state.target = self.target
            state.search = nil
            if frame.search then frame.search:SetText("") end
        end
        GemEditor:Refresh()
    end)
    return r
end

function GemEditor:PaintRow(r)
    local picked = state.target == r.target
    if picked then
        r.fill:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.1)
        UI():SetEdgeColor(r, GOLD[1], GOLD[2], GOLD[3], 0.9)
    elseif r.hovered then
        r.fill:SetColorTexture(1, 1, 1, 0.06)
        UI():SetEdgeColor(r, 0.5, 0.5, 0.54, 0.6)
    else
        r.fill:SetColorTexture(1, 1, 1, 0)
        UI():SetEdgeColor(r, 0, 0, 0, 0)
    end
end

-- A choice row: icon, name (quality / enchant green), effect, a tag on the right ("Best", "No bonus", a source).
local function CreateChoice(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(W - 2 * PAD - 8, CHOICE_H)
    r.fill = Fill(r)
    r.fill:SetColorTexture(1, 1, 1, 0)
    r.chip = CreateChip(r, CHOICE_CHIP)
    r.chip:SetPoint("LEFT", r, "LEFT", 3, 0)
    r.tag = Text(r, "GameFontHighlightSmall", "RIGHT")
    r.tag:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    r.name = Text(r, "GameFontHighlightSmall")
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", CHOICE_CHIP + 9, -3)
    r.effect = Text(r, "GameFontHighlightSmall")
    r.effect:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", CHOICE_CHIP + 9, 3)
    r:SetScript("OnEnter", function(self)
        self.fill:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.12)
        if self.kind == "gem" then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.id)
            GameTooltip:Show()
        elseif self.kind == "enchant" then
            local e = G():Enchant(self.id)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(e.name, ENCHANT_NAME[1], ENCHANT_NAME[2], ENCHANT_NAME[3])
            if e.text and e.text ~= "" then GameTooltip:AddLine(e.text, 1, 1, 1, true) end
            local src = G():SourceWords("enchant", e.id)
            if src then GameTooltip:AddLine(src, GREY[1], GREY[2], GREY[3]) end
            GameTooltip:Show()
        end
    end)
    r:SetScript("OnLeave", function(self)
        self.fill:SetColorTexture(1, 1, 1, self.current and 0.07 or 0)
        GameTooltip:Hide()
    end)
    r:SetScript("OnClick", function(self)
        local target = state.target
        Store(target, self.id)
        state.target = NextEmpty(target)
        state.search = nil
        if frame.search then frame.search:SetText("") end
        GemEditor:Refresh()
    end)
    return r
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

local function EventValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then return C_EventUtils.IsEventValid(event) and true or false end
    return true
end

local function Build()
    if frame then return frame end
    local U = UI()
    local f = CreateFrame("Frame", "DisasterZoneGemEditor", UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetWidth(W)
    f:Hide()
    f.bg = Fill(f)
    f.bg:SetColorTexture(U.DROP_BG[1], U.DROP_BG[2], U.DROP_BG[3], U.DROP_BG[4])
    U:AddEdges(f, "BORDER")
    U:SetEdgeColor(f, U.DROP_EDGE[1], U.DROP_EDGE[2], U.DROP_EDGE[3], U.DROP_EDGE[4])

    -- the item
    f.item = U:CreateItemButton(f, 28)
    f.item:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
    f.title = Text(f, "GameFontHighlight")
    f.title:SetPoint("TOPLEFT", f.item, "TOPRIGHT", 8, -1)
    f.title:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    f.sub = Text(f, "GameFontHighlightSmall")
    f.sub:SetPoint("BOTTOMLEFT", f.item, "BOTTOMRIGHT", 8, 1)
    f.sub:SetTextColor(GREY[1], GREY[2], GREY[3])
    f.line1 = f:CreateTexture(nil, "ARTWORK")
    f.line1:SetHeight(1)
    f.line1:SetColorTexture(1, 1, 1, 0.1)

    f.rows = {}
    for i = 1, 4 do
        f.rows[i] = CreateRow(f)
        f.rows[i].target = "s" .. i
    end
    f.enchantRow = CreateRow(f)
    f.enchantRow.target = "e"
    f.bonus = Text(f, "GameFontHighlightSmall")
    f.bonusHint = Text(f, "GameFontHighlightSmall")
    f.bonusHint:SetWordWrap(true)
    f.bonusHint:SetWidth(W - 2 * PAD - 4)
    f.bonusHint:SetTextColor(DIM[1], DIM[2], DIM[3])

    -- the choices
    f.choiceTitle = Text(f, "GameFontDisableSmall")
    f.search = U:CreateSearchBox(f, W - 2 * PAD, function(text)
        state.search = (text and text ~= "") and text:lower() or nil
        state.offset = 0
        GemEditor:Refresh()
    end, "Search all")
    f.list = CreateFrame("Frame", nil, f)
    f.list:SetSize(W - 2 * PAD, VISIBLE_CHOICES * CHOICE_H)
    f.list:EnableMouseWheel(true)
    f.list:SetScript("OnMouseWheel", function(_, delta)
        local n = #(state.choices or {})
        state.offset = max(0, min(n - VISIBLE_CHOICES, (state.offset or 0) - (delta or 0)))
        GemEditor:PaintChoices()
    end)
    f.choices = {}
    for i = 1, VISIBLE_CHOICES do
        local c = CreateChoice(f.list)
        c:SetPoint("TOPLEFT", f.list, "TOPLEFT", 0, -(i - 1) * CHOICE_H)
        f.choices[i] = c
    end
    f.thumb = f.list:CreateTexture(nil, "OVERLAY")
    f.thumb:SetWidth(3)
    f.thumb:SetColorTexture(1, 1, 1, 0.22)
    f.none = Text(f.list, "GameFontDisableSmall")
    f.none:SetPoint("TOPLEFT", f.list, "TOPLEFT", 4, -6)
    f.line2 = f:CreateTexture(nil, "ARTWORK")
    f.line2:SetHeight(1)
    f.line2:SetColorTexture(1, 1, 1, 0.1)

    -- the buttons
    f.clear = U:CreateSleekButton(f, "Clear", 70, 22, function()
        ns.BiS:SetGemSetup(state.itemID, nil, nil, state.list)
        state.target = "s1"
        if #G():Sockets(state.itemID) == 0 then state.target = "e" end
        GemEditor:Refresh()
    end)
    f.suggest = U:CreateSleekButton(f, "Use suggested", 120, 22, function()
        local enchant, gems = G():Suggest(state.itemID, state.sid, Guide(), state.phase, Profs())
        ns.BiS:SetGemSetup(state.itemID, enchant, gems, state.list)
        GemEditor:Refresh()
    end, "primary")
    f.clear:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD)
    f.suggest:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)

    -- closing: a click outside (not on the strip that opened it), Escape, the owner hiding
    f:SetScript("OnShow", function(self)
        if EventValid("GLOBAL_MOUSE_DOWN") then self:RegisterEvent("GLOBAL_MOUSE_DOWN") end
        if not InCombatLockdown() then
            self:EnableKeyboard(true)
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        if not InCombatLockdown() then self:EnableKeyboard(false) end
        if state.tile and state.tile.editBorder then state.tile.editBorder:Hide() end
        state.tile = nil
    end)
    f:SetScript("OnKeyDown", function(self, key)
        if key ~= "ESCAPE" then return end
        if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
        self:Hide()
    end)
    f:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() then return end
        local strip = state.tile and state.tile.strip
        if strip and strip:IsVisible() and strip:IsMouseOver() then return end
        local menu = UI().GetOpenMenu and UI():GetOpenMenu()
        if menu then return end
        self:Hide()
    end)
    f:SetScript("OnUpdate", function(self)
        local t = state.tile
        if not (t and t:IsVisible()) then self:Hide() end
    end)
    ns:On("MYLIST_CHANGED", function()
        if f:IsShown() then GemEditor:Refresh() end
    end)
    frame = f
    return f
end

-- The choices for the picked row: { { kind, id, tag, tagColor } }.
local function Choices()
    local Gm = G()
    local out, seen = {}, {}
    local search = state.search
    local function add(kind, id, tag, tagColor)
        if seen[id] then return end
        seen[id] = true
        out[#out + 1] = { kind = kind, id = id, tag = tag, tagColor = tagColor }
    end
    local guide = Guide()
    local guideGems, guideEnchants = Gm:GuidePicks(guide, state.phase)
    local phaseCap = max(1, state.phase or 1)
    if state.target == "e" then
        local first = guideEnchants[state.sid]
        if first and not Gm:EnchantFitsItem(first, state.itemID) then first = nil end
        for _, id in ipairs(Gm:EnchantsFor(state.itemID, Profs(), first)) do
            local e = Gm:Enchant(id)
            if not search or e.name:lower():find(search, 1, true) or (e.text or ""):lower():find(search, 1, true) then
                if id == first then
                    add("enchant", id, "Best", GOLD)
                else
                    add("enchant", id, Gm:SourceWords("enchant", id), DIM)
                end
            end
        end
        return out
    end
    local socket = Gm:Sockets(state.itemID)[tonumber(state.target:sub(2))]
    if not socket then return out end
    local function matches(g)
        return not search or g.name:lower():find(search, 1, true) or (g.text or ""):lower():find(search, 1, true)
    end
    if not search then
        local _, picks = Gm:SocketChoices(guideGems, socket)
        for _, c in ipairs(picks) do
            add("gem", c.id, c.best and "Best" or (not c.fits and "No bonus" or nil), c.best and GOLD or DIM)
        end
    end
    for _, id in ipairs(Gm:AllGems()) do
        local g = Gm:Gem(id)
        local fitsKind = (socket == "M") == (g.color == "M")
        if (search and matches(g)) or (not search and fitsKind and Gm:Fits(id, socket) and g.phase <= phaseCap
            and g.quality >= 2) then
            add("gem", id, (not Gm:Fits(id, socket)) and "No bonus" or nil, DIM)
        end
    end
    return out
end

function GemEditor:PaintChoices()
    local f = frame
    local list = state.choices or {}
    local enchant, gems = Setup()
    local current = state.target == "e" and enchant or gems[tonumber((state.target or "s1"):sub(2))]
    local offset = state.offset or 0
    for i, row in ipairs(f.choices) do
        local c = list[offset + i]
        if c then
            row.kind, row.id = c.kind, c.id
            row.current = (current == c.id)
            if c.kind == "gem" then
                local g = G():Gem(c.id)
                local col = G().COLORS[g.color] or GREY
                PaintChip(row.chip, g.icon, { col[1], col[2], col[3], 1 }, true)
                row.name:SetText(g.name)
                row.name:SetTextColor(UI():QualityColor(g.quality))
                row.effect:SetText(g.text or "")
            else
                local e = G():Enchant(c.id)
                PaintChip(row.chip, e.icon, { 0.25, 0.85, 0.3, 0.95 }, true)
                row.name:SetText(e.short)
                row.name:SetTextColor(ENCHANT_NAME[1], ENCHANT_NAME[2], ENCHANT_NAME[3])
                row.effect:SetText(e.text or "")
            end
            row.effect:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
            local tc = c.tagColor or DIM
            row.tag:SetText(c.tag or "")
            row.tag:SetTextColor(tc[1], tc[2], tc[3])
            -- the name and effect get the row's width up to the tag
            local textW = row:GetWidth() - (CHOICE_CHIP + 9) - (c.tag and ((row.tag:GetStringWidth() or 0) + 10) or 4)
            row.name:SetWidth(textW)
            row.effect:SetWidth(textW)
            row.fill:SetColorTexture(1, 1, 1, row.current and 0.07 or 0)
            row:Show()
        else
            row:Hide()
        end
    end
    f.none:SetShown(#list == 0)
    f.none:SetText(state.search and "Nothing matches" or "Nothing fits here")
    local n = #list
    if n > VISIBLE_CHOICES then
        local h = f.list:GetHeight()
        local th = max(12, h * VISIBLE_CHOICES / n)
        f.thumb:SetHeight(th)
        f.thumb:ClearAllPoints()
        f.thumb:SetPoint("TOPRIGHT", f.list, "TOPRIGHT", 0, -(h - th) * offset / (n - VISIBLE_CHOICES))
        f.thumb:Show()
    else
        f.thumb:Hide()
    end
end

-- Lays out and paints everything from the stored setup.
function GemEditor:Refresh()
    local f = frame
    if not (f and state.itemID) then return end
    local Gm = G()
    local enchant, gems = Setup()
    local sockets, bonus = Gm:Sockets(state.itemID)
    local canEnchant = Gm:CanEnchant(state.itemID, Profs())

    f.item:SetItem(state.itemID)
    f.item.itemLink = Gm:LinkFor(View(), state.itemID)
    local text = UI():ItemText(state.itemID)
    f.title:SetText(text)
    f.sub:SetText(#sockets > 0 and (canEnchant and "Gems and enchant" or "Gems") or "Enchant")

    local y = -(PAD + 28 + 8)
    f.line1:ClearAllPoints()
    f.line1:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
    f.line1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
    y = y - 7

    local counts = Gm:ColorCounts(View(), state.phase)
    for i, row in ipairs(f.rows) do
        local s = sockets[i]
        if s then
            local g = Gm:Gem(gems[i])
            local col = Gm.COLORS[s]
            if g then
                PaintChip(row.chip, g.icon, { col[1], col[2], col[3], 1 }, true)
                row.name:SetText(g.name)
                row.name:SetTextColor(UI():QualityColor(g.quality))
                local line = g.text or ""
                if g.color == "M" then
                    local active, words = Gm:MetaState(g.id, counts)
                    if words and not active then line = "|cffe6735aNeeds " .. words .. "|r" end
                end
                row.effect:SetText(line)
                row.effect:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
            else
                PaintChip(row.chip, Gm.EMPTY_SOCKET[s], { col[1] * 0.8, col[2] * 0.8, col[3] * 0.8, 0.9 }, false)
                row.name:SetText(Gm.SOCKET_NAMES[s] .. " socket")
                row.name:SetTextColor(1, 1, 1)
                row.effect:SetText(state.target == row.target and "Pick a gem below" or "Empty")
                row.effect:SetTextColor(GREY[1], GREY[2], GREY[3])
            end
            row.tip = nil
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
            row:Show()
            self:PaintRow(row)
            y = y - ROW_H - 2
        else
            row:Hide()
        end
    end

    -- the socket bonus
    f.bonus:Hide()
    f.bonusHint:Hide()
    if bonus then
        y = y - 2
        local active = Gm:BonusActive(state.itemID, gems)
        f.bonus:ClearAllPoints()
        f.bonus:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 2, y)
        f.bonus:SetText("Socket bonus: " .. bonus)
        if active then
            f.bonus:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
        else
            f.bonus:SetTextColor(GREY[1], GREY[2], GREY[3])
        end
        f.bonus:Show()
        y = y - 14
        if not active then
            local need = {}
            for i, s in ipairs(sockets) do
                if not ((gems[i] or 0) ~= 0 and Gm:Fits(gems[i], s)) then
                    need[#need + 1] = Gm.SOCKET_NAMES[s]:lower()
                end
            end
            f.bonusHint:ClearAllPoints()
            f.bonusHint:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 2, y)
            if #need == 1 then
                f.bonusHint:SetText("Needs a " .. need[1] .. " gem in the " .. need[1] .. " socket")
            else
                local last = table.remove(need)
                f.bonusHint:SetText("Needs " .. table.concat(need, ", ") .. " and " .. last .. " gems in their sockets")
            end
            f.bonusHint:Show()
            y = y - (f.bonusHint:GetStringHeight() or 12) - 2
        end
        y = y - 6
    end

    -- the choices
    local guide = Guide()
    local view = View()
    local specName = view and view.sp ~= "" and view.sp or nil
    local title
    if state.search then
        title = "SEARCH"
    elseif state.target == "e" then
        title = "ENCHANTS"
    else
        local s = sockets[tonumber(state.target:sub(2))] or "R"
        title = (Gm.SOCKET_NAMES[s] or ""):upper() .. " SOCKET"
    end
    if guide and specName and not state.search then title = title .. "  ·  SUGGESTED FOR " .. specName:upper() end
    f.choiceTitle:SetText(title)
    f.choiceTitle:ClearAllPoints()
    f.choiceTitle:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 2, y)
    y = y - 16
    f.search:ClearAllPoints()
    f.search:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
    y = y - 26
    f.list:ClearAllPoints()
    f.list:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 4, y)
    state.choices = Choices()
    state.offset = max(0, min(state.offset or 0, #state.choices - VISIBLE_CHOICES))
    self:PaintChoices()
    y = y - VISIBLE_CHOICES * CHOICE_H - 6

    -- the enchant row
    local er = f.enchantRow
    if canEnchant then
        f.line2:ClearAllPoints()
        f.line2:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
        f.line2:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
        f.line2:Show()
        y = y - 7
        local e = Gm:Enchant(enchant)
        if e then
            PaintChip(er.chip, e.icon, { 0.25, 0.85, 0.3, 0.95 }, true)
            er.name:SetText(e.short)
            er.name:SetTextColor(ENCHANT_NAME[1], ENCHANT_NAME[2], ENCHANT_NAME[3])
            er.effect:SetText(e.text or "")
            er.effect:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
        else
            PaintChip(er.chip, nil, { 0.42, 0.42, 0.46, 0.9 }, false, true)
            er.name:SetText("Enchant")
            er.name:SetTextColor(1, 1, 1)
            local _, guideEnchants = Gm:GuidePicks(guide, state.phase)
            local sug = Gm:Enchant(guideEnchants[state.sid])
            if sug and Gm:EnchantFitsItem(sug.id, state.itemID) then
                er.effect:SetText("Suggested: " .. sug.short)
            else
                er.effect:SetText("None")
            end
            er.effect:SetTextColor(GREY[1], GREY[2], GREY[3])
        end
        er:ClearAllPoints()
        er:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
        er:Show()
        self:PaintRow(er)
        y = y - ROW_H - 4
    else
        er:Hide()
        f.line2:Hide()
    end

    f.suggest:SetEnabled(guide ~= nil)
    y = y - 6 - 22 - PAD
    f:SetHeight(-y)
end

-- Opens the editor for the main pick of tile (a My BiS tile) in phase / list. Anchored beside the tile, toward the
-- page's middle. Opening it for the tile it is already on closes it.
function GemEditor:Open(tile, itemID, phase, list)
    local Gm = G()
    if not (tile and itemID and Gm) then return end
    local f = Build()
    if f:IsShown() and state.tile == tile and state.itemID == itemID then
        f:Hide()
        return
    end
    if state.tile and state.tile ~= tile and state.tile.editBorder then state.tile.editBorder:Hide() end
    state.tile, state.sid, state.itemID, state.phase, state.list = tile, tile.sid, itemID, phase, list
    state.search, state.offset = nil, 0
    f.search:SetText("")
    state.target = (#Gm:Sockets(itemID) > 0) and "s1" or "e"
    state.target = NextEmpty(state.target, true)
    f:ClearAllPoints()
    if tile.side == "R" then
        f:SetPoint("TOPRIGHT", tile, "TOPLEFT", -8, 0)
    elseif tile.side == "C" then
        f:SetPoint("BOTTOM", tile, "TOP", 0, 8)
    else
        f:SetPoint("TOPLEFT", tile, "TOPRIGHT", 8, 0)
    end
    if tile.editBorder then tile.editBorder:Show() end
    self:Refresh()
    f:Show()
end

function GemEditor:Close()
    if frame then frame:Hide() end
end

function GemEditor:IsShown()
    return frame and frame:IsShown() or false
end

-- (tests) the panel and its state
function GemEditor:GetFrame() return frame, state end
