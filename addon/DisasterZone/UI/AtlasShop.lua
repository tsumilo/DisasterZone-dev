if DisasterZoneBoot and DisasterZoneBoot.Run("UI/AtlasShop.lua", ...) then return end -- DisasterZone UI/AtlasShop.lua
-- ns.AtlasShopUI: the shopping list inside the Atlas tab (model: Core/ShoppingList.lua). It is a place in the Atlas's
-- left column like Raids or Crafting and then fills the other two columns: the middle lists who makes my crafts
-- (Everything, me, the guild member who can make the most of what is left first, nobody, bind on pickup), the right
-- shows the chosen group's crafts (amount, how far the materials are broken down; a stepper and a bin on hover) over
-- their materials (what my bags and bank hold of what they need, the missing ones first) and, with Auctionator, what
-- the rest costs. A member's group has a Whisper button that types the ask with the item links.
-- UI/Atlas.lua creates it (ShopUI:Create) with its own text helpers and shows / hides it (ShowIn / Hide).
local addonName, ns = ...

local ShopUI = {}
ns.AtlasShopUI = ShopUI

local ipairs, type, tonumber, tostring = ipairs, type, tonumber, tostring
local floor, max, min = math.floor, math.max, math.min
local tconcat = table.concat

local IN = 8
local ROW_GROUP, ROW_ITEM, ROW_SECT, ROW_MAT, ROW_MAT2, ROW_COST = 22, 34, 32, 24, 34, 30
local ICON, MAT_ICON, CLASS_ICON = 26, 18, 16
local BTN, NUM_W = 20, 26
local BAR_SPACE = 10
local MAX_NAMES = 3
local GREY = { 0.62, 0.62, 0.62 }
local DIM = { 0.55, 0.55, 0.58 }
local GREEN_HEX, GREY_HEX, OFF_HEX = "|cff4fd36b", "|cff8d8d93", "|cff8d8d93"
local EMPTY_TEXT = "Nothing here yet. Hover a craft in the Atlas and click its bag."
local BOP_TEXT = "Binds when picked up: only its crafter can wear it"
local NOBODY_TEXT = "Nobody in the guild knows this craft yet"

local H              -- the Atlas's helpers: NewText, TextWidth, CreateHead, FillHead, NameText, HEAD_H
local mid, right, midHead, groupList, head, list
local state = { group = "all" }   -- "all", "you", "nobody", "bop" or a member's key
local shown = false

local function Shop() return ns.Shop end
local function UI() return ns.UI end

local function Hex(c)
    return ("|cff%02x%02x%02x"):format(floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5))
end

local function StepText(d)
    if d <= 0 then return "As made" end
    return d == 1 and "1 step down" or (d .. " steps down")
end

local function GroupId(g)
    return g.kind == "member" and g.key or g.kind
end

local function FindGroup(groups, id)
    for _, g in ipairs(groups or {}) do
        if GroupId(g) == id then return g end
    end
    return nil
end

local function ClassOf(key)
    local cf = key and ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)
    if not cf and key and ns.Util.IsMe(key) and UnitClass then cf = select(2, UnitClass("player")) end
    return cf
end

local function GroupLabel(g)
    if g.kind == "you" then return "You" end
    if g.kind == "nobody" then return "Nobody in the guild" end
    if g.kind == "bop" then return "Can't be made for you" end
    return UI():ColoredName(g.key)
end

-- A list of people: "You, Mirabel, Isolde +2" (reachable ones in their class colour, the rest grey).
local function PeopleText(mine, crafters)
    local names = {}
    if mine then names[1] = "You" end
    for _, c in ipairs(crafters) do
        if #names >= MAX_NAMES then break end
        names[#names + 1] = c.reach and UI():ColoredName(c.key) or (OFF_HEX .. (ns.Util.ShortName(c.key) or c.key) .. "|r")
    end
    local more = (mine and 1 or 0) + #crafters - #names
    return tconcat(names, ", ") .. (more > 0 and (GREY_HEX .. " +" .. more .. "|r") or "")
end

local function ProfIcon(prof)
    local def = prof and ns.Professions and ns.Professions:GetProfession(prof)
    return def and def.icon and ("|T" .. def.icon .. ":12:12:0:0:64:64:5:59:5:59|t ") or ""
end

local function Money(copper)
    copper = floor(tonumber(copper) or 0)
    if copper >= 1000000 then copper = floor(copper / 10000 + 0.5) * 10000 end   -- 100g and more: whole gold
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    return floor(copper / 10000) .. "g"
end

---------------------------------------------------------------------------
-- Middle column: who makes what
---------------------------------------------------------------------------

local function SetupGroupRow(row)
    row.cdl = true
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.05)
    row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(1, 0.82, 0, 0.10)
    row.selBar = row:CreateTexture(nil, "ARTWORK")
    row.selBar:SetWidth(2)
    row.selBar:SetPoint("TOPLEFT")
    row.selBar:SetPoint("BOTTOMLEFT")
    row.selBar:SetColorTexture(1, 0.82, 0, 0.9)
    row.class = row:CreateTexture(nil, "ARTWORK")
    row.class:SetSize(CLASS_ICON, CLASS_ICON)
    row.class:SetPoint("LEFT", row, "LEFT", IN, 0)
    row.dot = row:CreateTexture(nil, "OVERLAY")
    row.dot:SetSize(7, 7)
    row.dot:SetPoint("BOTTOMRIGHT", row.class, "BOTTOMRIGHT", 2, -2)
    row.dot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    row.dot:SetVertexColor(0.24, 0.81, 0.36)
    row.count = H.NewText(row, "GameFontDisableSmall", 10)
    row.count:SetJustifyH("RIGHT")
    row.count:SetPoint("RIGHT", row, "RIGHT", -IN, 0)
    row.count:SetWidth(24)
    row.label = H.NewText(row, "GameFontHighlight", 11)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function(self)
        local d = self.__cdlData
        if not d then return end
        state.group = d.id
        ShopUI:Refresh(true)
    end)
end

local function InitGroupRow(row, d)
    if not row.cdl then SetupGroupRow(row) end
    local cf = d.classFile
    row.class:SetShown(cf ~= nil)
    if cf then UI():ClassIcon(row.class, cf) end
    row.dot:SetShown(d.online == true)
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", row, "LEFT", cf and (IN + CLASS_ICON + 7) or IN, 0)
    row.label:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
    row.label:SetText(d.label)
    local c = d.dim and DIM or { 0.92, 0.92, 0.92 }
    row.label:SetTextColor(c[1], c[2], c[3])
    row.count:SetText(d.count and tostring(d.count) or "")
    local on = state.group == d.id
    row.sel:SetShown(on)
    row.selBar:SetShown(on)
end

---------------------------------------------------------------------------
-- Right column: the crafts, then their materials
---------------------------------------------------------------------------

local function Hide(...)
    for i = 1, select("#", ...) do
        local r = select(i, ...)
        if r then r:Hide() end
    end
end

local function SetHover(row, on)
    local d = row.__cdlData
    local item = d and d.type == "item" and d.g.kind ~= "bop"
    on = on and (d and d.type == "item") or false
    row.hover:SetShown(on)
    row.amt:SetShown(item and not on)
    row.bin:SetShown(on)
    row.plusBtn:SetShown(item and on)
    row.num:SetShown(item and on)
    row.minusBtn:SetShown(item and on and d.e.n > 1)
end

local function Step(row, delta)
    local d = row.__cdlData
    if not (d and d.type == "item") then return end
    Shop():SetAmount(d.e.id, d.e.n + delta)
end

local function BuildStepMenu(root, row)
    local d = row.__cdlData
    if not (d and d.type == "item") then return end
    for depth = 0, d.maxDepth do
        root:CreateRadio(StepText(depth), function(v) return d.e.d == v end, function(v)
            Shop():SetDepth(d.e.id, v)
        end, depth)
    end
end

-- "Made by you, Mirabel, Isolde (offline)" under a craft's own tooltip.
local function ItemTooltipLines(tt, d)
    local S = Shop()
    tt:AddLine(" ")
    if d.g.kind == "bop" then
        tt:AddLine(BOP_TEXT .. ".", 0.7, 0.7, 0.7, true)
    else
        local names = {}
        if S:CanMake(d.e.id) then names[1] = "you" end
        for _, c in ipairs(S:GetCrafters(d.e.id)) do
            names[#names + 1] = c.reach and UI():ColoredName(c.key)
                or (OFF_HEX .. (ns.Util.ShortName(c.key) or c.key) .. " (offline)|r")
        end
        if #names > 0 then
            tt:AddLine("Made by " .. tconcat(names, ", "), 1, 0.82, 0, true)
        else
            tt:AddLine(NOBODY_TEXT .. ".", 0.7, 0.7, 0.7, true)
        end
    end
    tt:AddLine(" ")
    tt:AddLine("Click: open its page", 0.55, 0.8, 1)
end

local function ItemTooltip(row)
    local d = row.__cdlData
    if not (d and d.type == "item") then return end
    local id = d.e.id
    if id > 0 then
        local T = ns.Tooltip
        if T then T.noMats = true end   -- the list shows the materials itself
        UI():SetItemTooltip(row, id, function(tt) ItemTooltipLines(tt, d) end)
        if T then T.noMats = nil end
    else
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        if GameTooltip.SetSpellByID then GameTooltip:SetSpellByID(-id) end
        ItemTooltipLines(GameTooltip, d)
        GameTooltip:Show()
    end
end

-- A material's tooltip: the item, what on the list needs it, who in the guild makes it.
local function MatTooltip(row)
    local d = row.__cdlData
    if not (d and d.type == "mat") then return end
    local m = d.m
    UI():SetItemTooltip(row, m.id, function(tt)
        local A = ns.Atlas
        local parts = {}
        for _, e in ipairs(d.entries or {}) do
            for _, x in ipairs(A:GetMaterials(e.id, e.n, e.d) or {}) do
                if x.id == m.id then
                    parts[#parts + 1] = (A:GetName(e.id) or "?") .. " " .. GREY_HEX .. x.count .. "|r"
                end
            end
        end
        if #parts > 0 then
            tt:AddLine(" ")
            tt:AddLine("For " .. tconcat(parts, ", "), 1, 1, 1, true)
        end
        if d.people then tt:AddLine("Made by " .. d.people, 0.7, 0.7, 0.7, true) end
    end)
end

local function SetupRow(row)
    local U = UI()
    row.cdl = true
    row:RegisterForClicks("LeftButtonUp")
    row.hover = row:CreateTexture(nil, "BACKGROUND")
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(1, 1, 1, 0.05)
    row.hover:Hide()
    row.rule = row:CreateTexture(nil, "ARTWORK")
    row.rule:SetHeight(1)
    row.rule:SetColorTexture(1, 1, 1, 0.07)

    row.icon = U:CreateItemButton(row, ICON)
    row.icon:EnableMouse(false)   -- the row handles hover and clicks
    row.name = H.NewText(row, "GameFontHighlight", 12)
    row.sub = H.NewText(row, "GameFontDisableSmall", 10)
    row.sub:SetTextColor(GREY[1], GREY[2], GREY[3])
    row.step = U:CreateLinkDropdown(row, { font = "GameFontDisableSmall", size = 10, color = { 0.82, 0.82, 0.82 },
                                           chevSize = 9, height = 14, build = function(root) BuildStepMenu(root, row) end })
    row.amt = H.NewText(row, "GameFontHighlight", 12)
    row.amt:SetJustifyH("RIGHT")
    row.amt:SetPoint("RIGHT", row, "RIGHT", -IN, 0)

    -- on hover: - n + and the bin
    row.bin = U:CreateRemoveButton(row, "Take it off the list")
    row.bin:SetPoint("RIGHT", row, "RIGHT", -IN, 0)
    row.bin:SetScript("OnClick", function()
        local d = row.__cdlData
        if d and d.type == "item" then Shop():Remove(d.e.id) end
    end)
    row.plusBtn = U:CreateSleekButton(row, "+", BTN, BTN, function() Step(row, 1) end)
    row.plusBtn:SetPoint("RIGHT", row.bin, "LEFT", -6, 0)
    row.num = H.NewText(row, "GameFontHighlight", 12)
    row.num:SetJustifyH("CENTER")
    row.num:SetWidth(NUM_W)
    row.num:SetPoint("RIGHT", row.plusBtn, "LEFT", 0, 0)
    row.minusBtn = U:CreateSleekButton(row, "-", BTN, BTN, function() Step(row, -1) end)
    row.minusBtn:SetPoint("RIGHT", row.num, "LEFT", 0, 0)
    -- the buttons keep the row hovered
    for _, b in ipairs({ row.bin, row.plusBtn, row.minusBtn, row.step }) do
        b:HookScript("OnEnter", function() SetHover(row, true) end)
        b:HookScript("OnLeave", function() if not row:IsMouseOver() then SetHover(row, false) end end)
    end

    -- a material's count, a section's title and bar, the cost's value
    row.have = H.NewText(row, "GameFontHighlightSmall", 11)
    row.have:SetJustifyH("RIGHT")
    row.have:SetPoint("RIGHT", row, "RIGHT", -IN, 0)
    row.title = H.NewText(row, "GameFontNormal", 12)
    row.barBg = row:CreateTexture(nil, "ARTWORK")
    row.barBg:SetHeight(3)
    row.barBg:SetColorTexture(1, 1, 1, 0.07)
    row.barFill = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.barFill:SetHeight(3)
    row.barFill:SetColorTexture(0.24, 0.81, 0.36, 0.9)

    row:SetScript("OnEnter", function(self)
        local d = self.__cdlData
        if not d then return end
        if d.type == "item" then
            SetHover(self, true)
            ItemTooltip(self)
        elseif d.type == "mat" then
            self.hover:Show()
            MatTooltip(self)
        elseif d.type == "cost" and d.unpriced > 0 then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Auctionator's last scan")
            GameTooltip:AddLine(("%d of the missing materials have no price there yet."):format(d.unpriced), 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if not self:IsMouseOver() then SetHover(self, false) end
        local d = self.__cdlData
        if d and d.type == "mat" then self.hover:Hide() end
    end)
    row:SetScript("OnClick", function(self)
        local d = self.__cdlData
        if not (d and d.type == "item") then return end
        if d.e.id > 0 and IsModifiedClick and IsModifiedClick() and U:HandleModifiedItemClick(d.e.id) then return end
        if ns.AtlasUI then ns.AtlasUI:ShowItem(d.e.id) end
    end)
end

local function InitItem(row, d)
    local w = ShopUI.rowW
    local e = d.e
    row.icon:Show()
    row.icon:SetSize(ICON, ICON)
    row.icon:ClearAllPoints()
    row.icon:SetPoint("LEFT", row, "LEFT", IN, 0)
    if e.id > 0 then
        row.icon:SetItem(e.id)
    else
        row.icon:SetItem(nil)
        local tex = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(-e.id))
            or (GetSpellTexture and GetSpellTexture(-e.id))
        row.icon.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
    end
    local bop = d.g.kind == "bop"
    row.icon:SetAlpha(bop and 0.5 or 1)
    local x = IN + ICON + 9
    row.name:Show()
    row.name:ClearAllPoints()
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", x, -4)
    row.name:SetWidth(w - x - IN - 70)
    row.name:SetText(H.NameText(e.id))
    row.name:SetAlpha(bop and 0.55 or 1)
    -- the second line: who makes it (Everything), how far its materials are broken down
    local who = ""
    if bop then
        who = BOP_TEXT
    elseif d.g.kind == "nobody" then
        who = NOBODY_TEXT
    elseif d.showWho then
        who = d.g.kind == "you" and "You" or UI():ColoredName(d.g.key)
    end
    local step = not bop and d.maxDepth > 0
    if who == "" and not step then
        -- nothing under the name (a crafter's own view): the name in the middle, level with the amount
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row, "LEFT", x, 0)
    end
    row.sub:SetShown(who ~= "" or step)
    row.sub:ClearAllPoints()
    row.sub:SetPoint("TOPLEFT", row, "TOPLEFT", x, -19)
    row.sub:SetText(who .. ((who ~= "" and step) and "  ·  " or ""))
    row.sub:SetWidth(max(1, H.CodedWidth(row.sub:GetText(), "GameFontDisableSmall", 10)))
    row.step:SetShown(step)
    if step then
        row.step:ClearAllPoints()
        row.step:SetPoint("LEFT", row.sub, who ~= "" and "RIGHT" or "LEFT", 0, 0)
        row.step:SetLabel(StepText(e.d))
    end
    row.amt:SetText("×" .. e.n)
    row.num:SetText(tostring(e.n))
    Hide(row.have, row.title, row.barBg, row.barFill, row.rule)
    SetHover(row, row:IsMouseOver())
end

local function InitMat(row, d)
    local m = d.m
    Hide(row.amt, row.num, row.plusBtn, row.minusBtn, row.bin, row.step, row.title, row.barBg, row.barFill, row.rule)
    row.hover:Hide()
    row.icon:Show()
    row.icon:SetSize(MAT_ICON, MAT_ICON)
    row.icon:ClearAllPoints()
    row.icon:SetPoint("LEFT", row, "LEFT", IN, 0)
    row.icon:SetItem(m.id)
    local done = m.have >= m.need
    row.icon:SetAlpha(done and 0.55 or 1)
    local x = IN + MAT_ICON + 8
    row.name:Show()
    row.name:ClearAllPoints()
    row.name:SetWidth(ShopUI.rowW - x - IN - 70)
    row.name:SetText(H.NameText(m.id))
    row.name:SetAlpha(done and 0.55 or 1)
    local two = d.people ~= nil and not done
    if two then
        row.name:SetPoint("TOPLEFT", row, "TOPLEFT", x, -4)
        row.sub:Show()
        row.sub:ClearAllPoints()
        row.sub:SetPoint("TOPLEFT", row, "TOPLEFT", x, -19)
        row.sub:SetWidth(ShopUI.rowW - x - IN - 70)
        row.sub:SetText(d.profIcon .. (d.profName and (d.profName .. "  ·  ") or "") .. d.people)
    else
        row.name:SetPoint("LEFT", row, "LEFT", x, 0)
        row.sub:Hide()
    end
    row.have:Show()
    if done then
        row.have:SetText(GREEN_HEX .. "|T" .. UI():Tex("check") .. ":12:12|t " .. m.need .. "|r")
    else
        row.have:SetText(m.have .. GREY_HEX .. " / " .. m.need .. "|r")
    end
end

local function InitSect(row, d)
    Hide(row.icon, row.name, row.sub, row.step, row.amt, row.num, row.plusBtn, row.minusBtn, row.bin, row.rule)
    row.hover:Hide()
    row.title:Show()
    row.title:ClearAllPoints()
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", IN, -9)
    row.title:SetText("Materials")
    row.have:Show()
    row.have:ClearAllPoints()
    row.have:SetPoint("TOPRIGHT", row, "TOPRIGHT", -IN, -10)
    row.have:SetText(GREY_HEX .. d.done .. " of " .. d.total .. "|r")
    local bw = ShopUI.rowW - 2 * IN
    row.barBg:Show()
    row.barBg:ClearAllPoints()
    row.barBg:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", IN, 3)
    row.barBg:SetWidth(bw)
    local fill = d.total > 0 and floor(bw * d.done / d.total + 0.5) or 0
    row.barFill:SetShown(fill > 0)
    row.barFill:ClearAllPoints()
    row.barFill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", IN, 3)
    row.barFill:SetWidth(max(1, fill))
end

local function InitCost(row, d)
    Hide(row.icon, row.sub, row.step, row.amt, row.num, row.plusBtn, row.minusBtn, row.bin, row.title, row.barBg,
        row.barFill)
    row.hover:Hide()
    row.rule:Show()
    row.rule:ClearAllPoints()
    row.rule:SetPoint("TOPLEFT", row, "TOPLEFT", IN, -2)
    row.rule:SetPoint("TOPRIGHT", row, "TOPRIGHT", -IN, -2)
    row.name:Show()
    row.name:SetAlpha(1)
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", row, "LEFT", IN, -1)
    row.name:SetWidth(ShopUI.rowW - 2 * IN - 120)
    row.name:SetText(GREY_HEX .. "The rest at the auction house|r")
    row.have:Show()
    row.have:ClearAllPoints()
    row.have:SetPoint("RIGHT", row, "RIGHT", -IN, -1)
    row.have:SetText(Money(d.copper))
end

local function InitRow(row, d)
    if not row.cdl then SetupRow(row) end
    -- (the right edge of a material's count and a section's count move; reset them)
    row.have:ClearAllPoints()
    row.have:SetPoint("RIGHT", row, "RIGHT", -IN, 0)
    if d.type == "item" then
        InitItem(row, d)
    elseif d.type == "mat" then
        InitMat(row, d)
    elseif d.type == "sect" then
        InitSect(row, d)
    else
        InitCost(row, d)
    end
end

local function Extent(d)
    if d.type == "item" then return ROW_ITEM end
    if d.type == "sect" then return ROW_SECT end
    if d.type == "mat" then return (d.people and d.m.have < d.m.need) and ROW_MAT2 or ROW_MAT end
    return ROW_COST
end

---------------------------------------------------------------------------
-- The column titles
---------------------------------------------------------------------------

local function CreateTitle(parent)
    local U = UI()
    local h = CreateFrame("Frame", nil, parent)
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    h:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    h:SetHeight(H.HEAD_H)
    h.title = H.NewText(h, "GameFontNormal", 14)
    h.title:SetPoint("LEFT", h, "LEFT", IN, 0)
    h.sub = H.NewText(h, "GameFontDisableSmall", 10)
    h.sub:SetPoint("LEFT", h.title, "RIGHT", 8, -1)
    h.rule = h:CreateTexture(nil, "ARTWORK")
    h.rule:SetHeight(1)
    h.rule:SetPoint("BOTTOMLEFT")
    h.rule:SetPoint("BOTTOMRIGHT")
    h.rule:SetColorTexture(1, 1, 1, 0.12)
    h.whisper = U:CreateSleekButton(h, U:AtlasIconText(U.ICON.whisper, 12) .. " Whisper", 86, 20, function()
        local g = FindGroup(ShopUI.groups, state.group)
        if g then Shop():Whisper(g) end
    end, "primary")
    h.whisper:SetPoint("RIGHT", h, "RIGHT", 0, 1)
    h.more = U:CreateTipIconButton(h, 20, U.ICON.more, "More", nil, function(self)
        U:ContextMenu(self, function(root)
            local b = root:CreateButton(U:AtlasIconText(U.ICON.trash, 12) .. " Clear", function()
                StaticPopup_Show("DISASTERZONE_SHOP_CLEAR")
            end)
            if b and b.SetTooltip then
                b:SetTooltip(function(tt) GameTooltip_SetTitle(tt, "Take everything off the list") end)
            end
        end)
    end)
    h.more:SetPoint("RIGHT", h, "RIGHT", 0, 1)
    return h
end

local function FillTitle(groups, sel, entries)
    local S = Shop()
    head.whisper:Hide()
    head.more:Hide()
    local title, sub = "Shopping list", ""
    if not sel then
        head.more:SetShown(#entries > 0)
    elseif sel.kind == "you" then
        title = UI():ColoredName(sel.key)
        sub = S:SkillText(sel.key, sel.profs)
    elseif sel.kind == "member" then
        title = UI():ColoredName(sel.key)
        local parts = { S:SkillText(sel.key, sel.profs) }
        if sel.reach and sel.reach ~= sel.key then
            parts[#parts + 1] = "online as " .. (ns.Util.ShortName(sel.reach) or sel.reach)
        else
            parts[#parts + 1] = sel.reach and "online" or "offline"
        end
        sub = tconcat(parts, "  ·  "):gsub("^  ·  ", "")
        head.whisper:SetShown(sel.reach ~= nil)
    else
        title = GroupLabel(sel)
    end
    head.title:SetText(title)
    head.sub:SetText(sub)
    head.sub:SetShown(sub ~= "")
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function GroupRows(groups)
    local rows = { { id = "all", label = "Everything" } }
    for _, g in ipairs(groups) do
        local member = g.kind == "member"
        rows[#rows + 1] = { id = GroupId(g), label = GroupLabel(g), count = #g.entries,
                            classFile = (member or g.kind == "you") and ClassOf(g.key) or nil,
                            online = member and g.reach ~= nil, dim = g.kind == "nobody" or g.kind == "bop" }
    end
    return rows
end

-- A material's second line: who in the guild makes it (only for crafted materials).
local function MatPeople(id)
    local S = Shop()
    local mine = S:CanMake(id)
    local crafters = S:GetCrafters(id)
    if not mine and #crafters == 0 then return nil end
    return PeopleText(mine, crafters)
end

function ShopUI:Refresh(resetScroll)
    if not (shown and list) then return end
    local S = Shop()
    local entries = S:GetEntries()
    local groups = S:GetGroups(entries)
    self.groups = groups
    if state.group ~= "all" and not FindGroup(groups, state.group) then state.group = "all" end
    local sel = state.group ~= "all" and FindGroup(groups, state.group) or nil

    groupList:SetData(#entries > 0 and GroupRows(groups) or {})
    midHead:SetShown(#entries > 0)   -- (an empty list: no "Made by" over nothing)
    FillTitle(groups, sel, entries)

    local w = right:GetWidth()
    self.rowW = ((w and w > 0) and w or 392)
    local rows = {}
    for _, g in ipairs(sel and { sel } or groups) do
        for _, e in ipairs(g.entries) do
            rows[#rows + 1] = { type = "item", e = e, g = g, showWho = sel == nil,
                                maxDepth = g.kind ~= "bop" and S:GetMaxDepth(e.id) or 0 }
        end
    end
    local matEntries = sel and (sel.kind ~= "bop" and sel.entries or {}) or S:GetMaterialEntries(groups)
    if #matEntries > 0 then
        local mats = S:GetMaterials(matEntries)
        local done = 0
        for _, m in ipairs(mats) do
            if m.have >= m.need then done = done + 1 end
        end
        rows[#rows + 1] = { type = "sect", done = done, total = #mats }
        for _, m in ipairs(mats) do
            local prof = S:GetProfession(m.id)
            rows[#rows + 1] = { type = "mat", m = m, entries = matEntries, people = MatPeople(m.id),
                                profIcon = ProfIcon(prof),
                                profName = prof and ns.Professions:GetName(prof) or nil }
        end
        local cost, unpriced = S:GetCost(mats)
        if cost and cost > 0 then rows[#rows + 1] = { type = "cost", copper = cost, unpriced = unpriced } end
    end
    list:SetEmptyText(#entries == 0 and EMPTY_TEXT or "")
    list:SetData(rows, resetScroll)
end

---------------------------------------------------------------------------
-- Adding (the bag button on Atlas and Members rows)
---------------------------------------------------------------------------

-- Puts a craft on my shopping list: one, or as many as I set with Shift + the mouse wheel over it (and the breakdown
-- I clicked to while Shift was held). Returns true when it went on the list.
function ShopUI:AddCraft(id)
    local S = Shop()
    if not S then return false end
    local n, depth = 1, nil
    local T = ns.Tooltip
    local amt, level
    if T and T.GetMaterialsState then amt, level = T:GetMaterialsState(id) end
    if amt then
        n = amt
        if level and level > 0 then depth = level end
    end
    local ok, why = S:Add(id, n, depth)
    if not ok and why then ns:Print("Shopping list: " .. why .. ".") end
    return ok
end

-- The tooltip of a row's bag button: who can make the craft for me, what a click adds (the amount / breakdown set
-- with Shift), how many are on my list already.
function ShopUI:AddTooltip(owner, id)
    local S = Shop()
    if not S then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Add to shopping list")
    local who
    if S:CanMake(id) then
        who = "You can make it."
    elseif S:IsBindOnPickup(id) then
        who = BOP_TEXT .. "."
    else
        local crafters = S:GetCrafters(id)
        if #crafters == 0 then
            who = "Nobody in the guild can make it yet."
        else
            local first = UI():ColoredName(crafters[1].key)
            who = #crafters == 1 and (first .. " can make it for you.")
                or (first .. " and " .. (#crafters - 1) .. " more can make it for you.")
        end
    end
    GameTooltip:AddLine(who, 0.7, 0.7, 0.7, true)
    local T = ns.Tooltip
    local amt, level
    if T and T.GetMaterialsState then amt, level = T:GetMaterialsState(id) end
    if amt and (amt > 1 or (level or 0) > 0) then
        local text = "Adds " .. amt
        if level and level > 0 then
            text = text .. (level == 1 and ", broken down once" or (", broken down " .. level .. " steps"))
        end
        GameTooltip:AddLine(text, 0.55, 0.8, 1)
    end
    local on = S:GetAmount(id)
    if on then GameTooltip:AddLine("On your list: " .. on, 0.85, 0.85, 0.85) end
    GameTooltip:Show()
end

-- For tests and the UI audit.
function ShopUI:GetState()
    return state
end

function ShopUI:Select(groupId)
    state.group = groupId or "all"
    self:Refresh(true)
end

function ShopUI:GetLists()
    return groupList, list
end

function ShopUI:GetTitle()
    return head
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

-- helpers: { NewText, TextWidth, CodedWidth, CreateHead, FillHead, NameText, HEAD_H }; midFrame / rightFrame: the
-- Atlas's middle and right columns.
function ShopUI:Create(helpers, midFrame, rightFrame)
    if list then return end
    H = helpers
    local U = UI()
    mid = CreateFrame("Frame", nil, midFrame)
    mid:SetAllPoints(midFrame)
    right = CreateFrame("Frame", nil, rightFrame)
    right:SetAllPoints(rightFrame)

    midHead = H.CreateHead(mid)
    groupList = U:CreateScrollList(mid, ROW_GROUP, InitGroupRow)
    groupList.frame:SetPoint("TOPLEFT", mid, "TOPLEFT", 0, -(H.HEAD_H + 4))
    groupList.frame:SetPoint("BOTTOMRIGHT", mid, "BOTTOMRIGHT", 0, 0)
    groupList.box:ClearAllPoints()
    groupList.box:SetAllPoints(groupList.frame)

    head = CreateTitle(right)
    list = U:CreateScrollList(right, ROW_ITEM, InitRow, Extent)
    list.frame:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -(H.HEAD_H + 4))
    list.frame:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)
    list.box:ClearAllPoints()
    list.box:SetAllPoints(list.frame)
    list.bar:ClearAllPoints()
    list.bar:SetPoint("TOPLEFT", list.box, "TOPRIGHT", 4, 0)
    list.bar:SetPoint("BOTTOMLEFT", list.box, "BOTTOMRIGHT", 4, 0)
    list.emptyText:ClearAllPoints()
    list.emptyText:SetPoint("TOPLEFT", list.frame, "TOPLEFT", IN, -12)
    list.emptyText:SetPoint("TOPRIGHT", list.frame, "TOPRIGHT", -IN, -12)
    list.emptyText:SetJustifyH("LEFT")

    StaticPopupDialogs["DISASTERZONE_SHOP_CLEAR"] = {
        text = "Take everything off your shopping list?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function() Shop():Clear() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    mid:Hide()
    right:Hide()
end

-- Shows the list in the Atlas's middle and right columns.
function ShopUI:Show()
    if not list then return end
    shown = true
    mid:Show()
    right:Show()
    H.FillHead(midHead, mid:GetWidth() > 0 and mid:GetWidth() or 182, "Made by", nil)
    self:Refresh(true)
end

function ShopUI:Hide()
    shown = false
    if mid then mid:Hide() end
    if right then right:Hide() end
end

function ShopUI:IsShown()
    return shown
end

-- Bags, the guild's recipes, who is online or item names changed: the counts, groups and names.
local function RefreshLater()
    if not shown then return end
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce("atlas-shop", 0.15, function() ShopUI:Refresh() end)
    else
        ShopUI:Refresh()
    end
end

ns:On("SHOP_UPDATED", RefreshLater)
ns:On("PROFESSIONS_UPDATED", RefreshLater)
ns:On("ROSTER_UPDATED", RefreshLater)
ns:On("ITEMINFO_READY", RefreshLater)
if ns.RegisterEvent then
    ns:RegisterEvent("BAG_UPDATE_DELAYED", RefreshLater)
end
