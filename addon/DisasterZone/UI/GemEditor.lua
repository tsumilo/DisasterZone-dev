if DisasterZoneBoot and DisasterZoneBoot.Run("UI/GemEditor.lua", ...) then return end -- DisasterZone UI/GemEditor.lua
-- ns.GemEditor: the gems and enchant of one BiS pick, in a flat panel beside its My BiS tile (the tile's strip opens
-- it). Top to bottom: the item; a row per socket (the gem in a socket-coloured edge, or the empty socket); the socket
-- bonus (green while every socket holds a gem of its colour, else what it still needs) and a meta gem's rule; an
-- Epic | Rare | Uncommon switch (a gem socket but the meta's: the choices are that quality's gems; it starts on the
-- quality of the gem in the socket, else the list's from the Suggest menu); the choices for the picked row (the spec's
-- suggestions first - "Best", "No bonus" when the guide's top gem skips it - then every other gem of that colour, or
-- every enchant that fits; a search box looks through all of them); the enchant row; Clear and Use suggested.
-- A choice is stored at once (BiS:SetGemSetup) and the next empty socket is picked. Right-click a row: empty it.
-- The Gear sim page opens it with a host (its Working set's slot: ns.SimPanel:GemHost): the setup is read from and
-- stored into that, and the host's view (the page's record) stands in for the list.
-- A click outside, Escape, the page hiding or another tile's strip closes / moves it.
-- 1.4: a popover on the dropdowns' surface (no page layout: it hangs beside its tile); its rows have the shared row
-- looks (UI:DecorateRow: hover, the picked row / the current choice selected), the socket chips are ns.GearUI's (the
-- doll's), shared text styles, Style tokens, the quality switch is UI:CreateSegments (f.quality = its buttons),
-- tooltips through UI:AttachTooltip.
local addonName, ns = ...

local GemEditor = {}
ns.GemEditor = GemEditor

local S = ns.Style

local floor, min, max = math.floor, math.min, math.max

local W = 322
local PAD = 10
local ROW_H, CHOICE_H = 30, 28
local SWITCH_H = 24
local QUALITIES = { 4, 3, 2 }   -- the switch, left to right
local CHIP, CHOICE_CHIP = 22, 18
local VISIBLE_CHOICES = 6
local GOLD = S.C.GOLD
local GREEN = S.C.OK
local GREY = S.C.SUB
local DIM = S.C.DIM
local ENCHANT_NAME = { 0.12, 1, 0 }

local frame
local state = {}   -- sid, itemID, phase, list, target ("s1".."s4" or "e"), search, quality (2..4) + qFor (its row),
                   -- host ({ view(), get() -> enchant, gems, set(enchant, gems) }; nil = the BiS list)

local function G() return ns.Gems end
local function UI() return ns.UI end

local function View()
    if state.host then return state.host.view() end
    local BiS = ns.BiS
    return BiS and BiS:GetListView(state.list) or nil
end

local function Setup()
    if state.host then return state.host.get() end
    return G():GetSetup(View(), state.itemID)
end

-- Stores a whole setup (nil, nil = clear it) where it lives: the host, else the BiS list.
local function Write(enchant, gems)
    if state.host then
        state.host.set(enchant, gems)
    else
        ns.BiS:SetGemSetup(state.itemID, enchant, gems, state.list)
    end
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
    Write(enchant, out)
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

-- (the socket chips: the doll's, ns.GearUI)
local function CreateChip(parent, size) return ns.GearUI.CreateSocketChip(parent, size, "emph") end
local function PaintChip(c, icon, edge, crop, plus) ns.GearUI.PaintSocketChip(c, icon, edge, crop, plus) end

-- A socket / enchant row: chip, name, effect line; the shared row looks (the picked row selected).
local function CreateRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(W - 2 * PAD, ROW_H)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    UI():DecorateRow(r, { selectable = true })
    r.chip = CreateChip(r, CHIP)
    r.chip:SetPoint("LEFT", r, "LEFT", 4, 0)
    r.name = UI():Text(r, "emph", "TEXT")
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", CHIP + 12, -3)
    r.name:SetPoint("TOPRIGHT", r, "TOPRIGHT", -4, -3)
    r.effect = UI():Text(r, "small", "TEXT")
    r.effect:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", CHIP + 12, 3)
    r.effect:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -4, 3)
    UI():AttachTooltip(r, function(self, tt)
        if not self.tip then return false end
        self.tip(tt)
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
    r:SetSelected(state.target == r.target)
end

-- A choice row: icon, name (quality / enchant green), effect, a tag on the right ("Best", "No bonus", a source).
local function CreateChoice(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(W - 2 * PAD - 8, CHOICE_H)
    UI():DecorateRow(r, { selectable = true })   -- (the current choice: selected)
    r.chip = CreateChip(r, CHOICE_CHIP)
    r.chip:SetPoint("LEFT", r, "LEFT", 3, 0)
    r.tag = UI():Text(r, "small", "TEXT", { justify = "RIGHT" })
    r.tag:SetPoint("TOPRIGHT", r, "TOPRIGHT", -4, -3)     -- (on the name's line: the effect gets the whole width)
    r.name = UI():Text(r, "small", "TEXT")
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", CHOICE_CHIP + 9, -3)
    r.effect = UI():Text(r, "small", "TEXT")
    r.effect:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", CHOICE_CHIP + 9, 3)
    -- (a gem: the game's item tooltip; an enchant: its name, what it gives and where it comes from)
    UI():AttachTooltip(r, function(self, tt)
        if self.kind == "gem" then
            tt:SetItemByID(self.id)
        elseif self.kind == "enchant" then
            local e = G():Enchant(self.id)
            tt:AddLine(e.name, ENCHANT_NAME[1], ENCHANT_NAME[2], ENCHANT_NAME[3])
            if e.text and e.text ~= "" then tt:AddLine(e.text, 1, 1, 1, true) end
            local src = G():SourceWords("enchant", e.id)
            if src then tt:AddLine(src, GREY[1], GREY[2], GREY[3]) end
        else
            return false
        end
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
    f.bg = U:Fill(f, "DROP_BG")
    U:AddEdges(f, "BORDER")
    U:SetEdgeColor(f, S:Color("DROP_EDGE"))

    -- the item
    f.item = U:CreateItemButton(f, 28)
    f.item:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
    f.title = U:Text(f, "emph", "TEXT")
    f.title:SetPoint("TOPLEFT", f.item, "TOPRIGHT", 8, -1)
    f.title:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    f.sub = U:Text(f, "small", "SUB")
    f.sub:SetPoint("BOTTOMLEFT", f.item, "BOTTOMRIGHT", 8, 1)
    f.line1 = U:Rule(f, { alpha = 0.1 })

    f.rows = {}
    for i = 1, 4 do
        f.rows[i] = CreateRow(f)
        f.rows[i].target = "s" .. i
    end
    f.enchantRow = CreateRow(f)
    f.enchantRow.target = "e"
    f.bonus = U:Text(f, "small", "TEXT")

    -- the quality switch: Epic | Rare | Uncommon in the quality colours (UI:CreateSegments); f.quality = its buttons
    local items = {}
    for i, q in ipairs(QUALITIES) do
        local r, g, b = U:QualityColor(q)
        items[i] = { key = q, label = G().QUALITY_WORDS[q], color = { r, g, b } }
    end
    f.qualitySeg = U:CreateSegments(f, items, function(q)
        state.quality = q
        state.offset = 0
        GemEditor:Refresh()
    end, { width = W - 2 * PAD, h = SWITCH_H, textSize = "small" })
    f.quality = f.qualitySeg.buttons
    for i, q in ipairs(QUALITIES) do f.quality[i].q = q end

    -- the choices
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
    f.none = U:Text(f.list, "small", "DIM")
    f.none:SetPoint("TOPLEFT", f.list, "TOPLEFT", 4, -6)
    f.line2 = U:Rule(f, { alpha = 0.1 })

    -- the buttons
    f.clear = U:CreateSleekButton(f, "Clear", 70, 22, function()
        Write(nil, nil)
        state.target = "s1"
        if #G():Sockets(state.itemID) == 0 then state.target = "e" end
        GemEditor:Refresh()
    end)
    f.suggest = U:CreateSleekButton(f, "Use suggested", 120, 22, function()
        local used = G():UsedUniques(View(), state.phase, state.itemID)
        local enchant, gems = G():WithQuality(G():GetQuality(state.list), G().Suggest, G(), state.itemID, state.sid,
            Guide(), state.phase, Profs(), used)
        Write(enchant, gems)
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
    local gd = Gm:GuideData(Guide(), state.phase)
    local phaseCap = max(1, state.phase or 1)
    if state.target == "e" then
        local first = Gm:BestEnchant(state.itemID, state.sid, gd, Profs())
        if first == 0 then first = nil end
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
    local function tag(id)
        local g = Gm:Gem(id)
        if not Gm:Fits(id, socket) then return "No bonus" end
        if g.unique then return "Unique" end
        if g.jc then return "Jewelcrafter" end
        return nil
    end
    -- the switch's quality (a meta socket: every quality, they come in one)
    local quality = socket ~= "M" and state.quality or nil
    local function ofQuality(id)
        return not quality or Gm:Gem(id).quality == quality
    end
    if not search then
        local used = Gm:UsedUniques(View(), state.phase, state.itemID)
        local list = Gm:WithQuality(quality, Gm.SocketChoices, Gm, state.itemID, tonumber(state.target:sub(2)), gd,
            state.phase, Profs(), used)
        for _, c in ipairs(list) do
            if ofQuality(c.id) then
                if c.best then add("gem", c.id, "Best", GOLD) else add("gem", c.id, tag(c.id), DIM) end
            end
        end
    end
    -- the rest: every gem that fits (a search: every gem), the most worth to the spec first
    local rest = {}
    for _, id in ipairs(Gm:AllGems()) do
        local g = Gm:Gem(id)
        local fitsKind = (socket == "M") == (g.color == "M")
        if (search and matches(g)) or (not search and fitsKind and Gm:Fits(id, socket) and g.phase <= phaseCap
            and g.quality >= 2 and ofQuality(id)) then
            rest[#rest + 1] = id
        end
    end
    local w = gd.w
    table.sort(rest, function(a, b)
        local sa, sb = Gm:GemScore(a, w), Gm:GemScore(b, w)
        if sa ~= sb then return sa > sb end
        return a < b
    end)
    for _, id in ipairs(rest) do add("gem", id, tag(id), DIM) end
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
            local fullW = row:GetWidth() - (CHOICE_CHIP + 9) - 4
            row.name:SetWidth(fullW - (c.tag and ((row.tag:GetStringWidth() or 0) + 6) or 0))
            row.effect:SetWidth(fullW)
            row:SetSelected(row.current)
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

-- The quality the switch starts on for the picked row: the gem's in the socket, else the one Suggest would put there
-- (at the list's quality from the Suggest menu); one the phase has no gems of yet steps down.
local function StartQuality(gems)
    local Gm = G()
    local index = tonumber((state.target or ""):sub(2)) or 0
    local g = Gm:Gem(gems[index])
    if not (g and g.color ~= "M") then
        local cap = Gm:GetQuality(state.list)
        local used = Gm:UsedUniques(View(), state.phase, state.itemID)
        local list = Gm:WithQuality(cap, Gm.SocketChoices, Gm, state.itemID, index, Gm:GuideData(Guide(), state.phase),
            state.phase, Profs(), used)
        g = list[1] and list[1].best and Gm:Gem(list[1].id)
        if not g then g = { quality = cap } end
    end
    local q = g.quality
    q = max(2, min(4, q))
    while q > 2 and not G():QualityOut(q, state.phase) do q = q - 1 end
    return q
end

-- The switch: a quality the phase has no gems of yet can't be picked; the row's quality is the pick.
function GemEditor:PaintQuality()
    local f = frame
    if not f then return end
    local seg = f.qualitySeg
    for _, q in ipairs(QUALITIES) do seg:SetItemEnabled(q, G():QualityOut(q, state.phase) and true or false) end
    seg:Select(state.quality)
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
                    if words and not active then line = S:Wrap("WARN", "Needs " .. words) end
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
        y = y - 20
    end

    -- the quality switch (a gem socket but the meta's; another row picked starts it again)
    if state.qFor ~= state.target then state.quality, state.qFor = nil, state.target end
    local socket = state.target ~= "e" and sockets[tonumber((state.target or ""):sub(2)) or 0]
    if socket and socket ~= "M" then
        state.quality = state.quality or StartQuality(gems)
        f.qualitySeg:ClearAllPoints()
        f.qualitySeg:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
        f.qualitySeg:Show()
        for _, b in ipairs(f.quality) do b:Show() end
        self:PaintQuality()
        y = y - SWITCH_H - 8
    else
        -- (the buttons too: they say whether the switch is there)
        f.qualitySeg:Hide()
        for _, b in ipairs(f.quality) do b:Hide() end
    end

    -- the choices
    local guide = Guide()
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
            local sug = Gm:Enchant(Gm:BestEnchant(state.itemID, state.sid, Gm:GuideData(guide, state.phase), Profs()))
            if sug then
                er.effect:SetText(sug.short)
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
-- page's middle. Opening it for the tile it is already on closes it. host: where the setup lives instead of the list
-- (the Gear sim's Working set).
function GemEditor:Open(tile, itemID, phase, list, host)
    local Gm = G()
    if not (tile and itemID and Gm) then return end
    local f = Build()
    if f:IsShown() and state.tile == tile and state.itemID == itemID then
        f:Hide()
        return
    end
    if state.tile and state.tile ~= tile and state.tile.editBorder then state.tile.editBorder:Hide() end
    state.tile, state.sid, state.itemID, state.phase, state.list = tile, tile.sid, itemID, phase, list
    state.host = host
    state.search, state.offset = nil, 0
    state.quality, state.qFor = nil, nil
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

-- Is it open on a host (the Gear sim's Working set) rather than the BiS list?
function GemEditor:HasHost()
    return self:IsShown() and state.host ~= nil
end

-- (tests) the panel and its state
function GemEditor:GetFrame() return frame, state end
