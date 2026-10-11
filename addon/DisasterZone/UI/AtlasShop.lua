if DisasterZoneBoot and DisasterZoneBoot.Run("UI/AtlasShop.lua", ...) then return end -- DisasterZone UI/AtlasShop.lua
-- ns.AtlasShopUI: the shopping list inside the Atlas tab (model: Core/ShoppingList.lua). It is a place in the Atlas's
-- left column like Raids or Crafting and then fills the other two columns: the middle lists who makes my crafts
-- (Everything, me, the guild member who can make the most of what is left first, nobody, bind on pickup), the right
-- shows the chosen group's crafts (amount, how far the materials are broken down; a stepper and a bin on hover) over
-- their materials (what my bags and bank hold of what they need, the missing ones first) and, with Auctionator, what
-- the rest costs. A member's group has a Whisper button that types the ask with the item links.
-- UI/Atlas.lua creates it (ShopUI:Create) with its own text helpers and shows / hides it (ShowIn / Hide).
-- (1.4: the Atlas's List + detail layout; the rows' shared looks, text styles and tokens.)
local addonName, ns = ...

local ShopUI = {}
ns.AtlasShopUI = ShopUI

local Style = ns.Style            -- (S is the shopping list model in this file's functions)

local ipairs, type, tonumber, tostring = ipairs, type, tonumber, tostring
local floor, max, min = math.floor, math.max, math.min
local tconcat = table.concat

local IN = Style.IN
local ROW_GROUP, ROW_ITEM, ROW_SECT, ROW_MAT, ROW_MAT2, ROW_COST = 22, 34, 32, 24, 34, 30
local ICON, MAT_ICON, CLASS_ICON = 26, 18, 16
local BTN, NUM_W = 20, 26
local BAR_SPACE = 10
local MAX_NAMES = 3
local DIM = { 0.55, 0.55, 0.58 }
local GREEN_HEX, GREY_HEX, OFF_HEX = Style:Hex("OK"), Style:Hex("SUB"), Style:Hex("SUB")
local EMPTY_TEXT = "Nothing here yet. Hover a craft in the Atlas and click its bag."
local BOP_TEXT = "Binds when picked up: only its crafter can wear it"
local NOBODY_TEXT = "Nobody in the guild knows this craft yet"
local NOBODY_SHORT = "No guild crafter yet"       -- (the row's second line; the tooltip says it in full)
local LEFT_OUT_TEXT = "Not in materials"
local HOVER_W = 130   -- what the hover buttons (eye, - n +, bin) take at a craft row's right

local H              -- the Atlas's helpers and sizes: TextWidth, CodedWidth, NameText, HEAD_H, BANNER_H
local mid, right, midHead, groupList, head, list
local state = { group = "all" }   -- "all", "you", "nobody", "bop" or a member's key
local shown = false

local function Shop() return ns.Shop end
local function UI() return ns.UI end

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
    UI():DecorateRow(row, { selectable = true })   -- (hover, and the picked look: row:SetSelected)
    row.class = row:CreateTexture(nil, "ARTWORK")
    row.class:SetSize(CLASS_ICON, CLASS_ICON)
    row.class:SetPoint("LEFT", row, "LEFT", IN, 0)
    row.dot = row:CreateTexture(nil, "OVERLAY")
    row.dot:SetSize(7, 7)
    row.dot:SetPoint("BOTTOMRIGHT", row.class, "BOTTOMRIGHT", 2, -2)
    row.dot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    row.dot:SetVertexColor(0.24, 0.81, 0.36)
    row.count = UI():Text(row, "small", "DIM", { justify = "RIGHT", width = 24 })
    row.count:SetPoint("RIGHT", row, "RIGHT", -IN, 0)
    row.label = UI():Text(row, "body", "TEXT")
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
    row:SetSelected(state.group == d.id)
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
    row:SetHover(on)
    row.amt:SetShown(item and not on)
    row.bin:SetShown(on)
    row.plusBtn:SetShown(item and on)
    row.num:SetShown(item and on)
    row.minusBtn:SetShown(item and on and d.e.n > 1)
    row.eye:SetShown(on)
    if on then
        row.eye:ClearAllPoints()
        if item then
            row.eye:SetPoint("RIGHT", row.num, "LEFT", -(BTN + 6), 0)
        else
            row.eye:SetPoint("RIGHT", row.bin, "LEFT", -6, 0)
        end
        local counted = d.counted
        row.eye.icon:SetAlpha(counted and 1 or 0.35)
        row.eye.tipTitle = counted and "Leave out of materials" or "Count its materials"
        row.eye.tipText = counted and "Its materials stop counting in the list below."
            or "Its materials count in the list below again."
    end
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
            local gr, gg, gb = Style:Color("GOLD")
            tt:AddLine("Made by " .. tconcat(names, ", "), gr, gg, gb, true)
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
    -- the shared hover (SetHover holds it while the row's buttons are under the cursor)
    U:DecorateRow(row)
    row.rule = row:CreateTexture(nil, "ARTWORK")
    row.rule:SetHeight(1)
    row.rule:SetColorTexture(Style:Color("HAIRLINE"))

    row.icon = U:CreateItemButton(row, ICON)
    row.icon:EnableMouse(false)   -- the row handles hover and clicks
    row.name = U:Text(row, "emph", "TEXT")
    row.sub = U:Text(row, "small", "SUB")
    row.step = U:CreateLinkDropdown(row, { font = "GameFontDisableSmall", size = 10, color = { 0.82, 0.82, 0.82 },
                                           chevSize = 9, height = 14, build = function(root) BuildStepMenu(root, row) end })
    row.amt = U:Text(row, "emph", "TEXT", { justify = "RIGHT" })
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
    row.num = U:Text(row, "emph", "TEXT", { justify = "CENTER", width = NUM_W })
    row.num:SetPoint("RIGHT", row.plusBtn, "LEFT", 0, 0)
    row.minusBtn = U:CreateSleekButton(row, "-", BTN, BTN, function() Step(row, -1) end)
    row.minusBtn:SetPoint("RIGHT", row.num, "LEFT", 0, 0)
    row.eye = U:CreateTipIconButton(row, 18, U.ICON.eye, "Leave out of materials", nil, function()
        local d = row.__cdlData
        if d and d.type == "item" then Shop():SetCounted(d.e.id, not d.counted, d.g.kind == "bop") end
    end)
    -- the buttons keep the row hovered
    for _, b in ipairs({ row.bin, row.plusBtn, row.minusBtn, row.eye, row.step }) do
        b:HookScript("OnEnter", function() SetHover(row, true) end)
        b:HookScript("OnLeave", function() if not row:IsMouseOver() then SetHover(row, false) end end)
    end

    -- a material's count, a section's title and bar, the cost's value
    row.have = U:Text(row, "body", "TEXT", { justify = "RIGHT" })
    row.have:SetPoint("RIGHT", row, "RIGHT", -IN, 0)
    row.title = U:Text(row, "emph", "GOLD")
    row.barBg = row:CreateTexture(nil, "ARTWORK")
    row.barBg:SetHeight(3)
    row.barBg:SetColorTexture(Style:Color("HAIRLINE"))
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
            MatTooltip(self)
        elseif d.type == "cost" and d.unpriced > 0 then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Auctionator's last scan", Style:Color("GOLD"))
            GameTooltip:AddLine(("%d of the missing materials have no price there yet."):format(d.unpriced), 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if not self:IsMouseOver() then SetHover(self, false) end
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
    row.dzHover:Show()
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
    local off = not d.counted
    row.icon:SetAlpha((bop or off) and 0.5 or 1)
    local x = IN + ICON + 9
    row.name:Show()
    row.name:ClearAllPoints()
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", x, -4)
    row.name:SetWidth(w - x - IN - 70)
    row.name:SetText(H.NameText(e.id))
    row.name:SetAlpha((bop or off) and 0.55 or 1)
    -- the second line: who makes it (Everything), how far its materials are broken down
    local who = ""
    if bop then
        who = BOP_TEXT
    elseif d.g.kind == "nobody" then
        who = NOBODY_SHORT
    elseif d.showWho then
        who = d.g.kind == "you" and "You" or UI():ColoredName(d.g.key)
    end
    if off and not bop then who = who .. (who ~= "" and "  ·  " or "") .. LEFT_OUT_TEXT end
    local step = d.counted and d.maxDepth > 0
    if who == "" and not step then
        -- nothing under the name (a crafter's own view): the name in the middle, level with the amount
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row, "LEFT", x, 0)
    end
    row.sub:SetShown(who ~= "" or step)
    row.sub:ClearAllPoints()
    row.sub:SetPoint("TOPLEFT", row, "TOPLEFT", x, -19)
    row.sub:SetText(who .. ((who ~= "" and step) and "  ·  " or ""))
    row.sub:SetWordWrap(false)
    row.step:SetShown(step)
    local room = w - x - HOVER_W
    if step then
        row.step:SetLabel(StepText(e.d))
        room = room - (row.step:GetWidth() or 0)
    end
    -- (a long line ends in "..." before the step dropdown and the buttons on the right)
    row.sub:SetWidth(max(1, min(room, H.CodedWidth(row.sub:GetText(), "small"))))
    if step then
        row.step:ClearAllPoints()
        row.step:SetPoint("LEFT", row.sub, who ~= "" and "RIGHT" or "LEFT", 0, 0)
    end
    row.amt:SetText("×" .. e.n)
    row.num:SetText(tostring(e.n))
    Hide(row.have, row.title, row.barBg, row.barFill, row.rule)
    SetHover(row, row:IsMouseOver())
end

local function InitMat(row, d)
    local m = d.m
    Hide(row.amt, row.num, row.plusBtn, row.minusBtn, row.bin, row.eye, row.step, row.title, row.barBg, row.barFill, row.rule)
    row:SetHover(false)
    row.dzHover:Show()
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
        row.sub:SetWordWrap(false)
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
    Hide(row.icon, row.name, row.sub, row.step, row.amt, row.num, row.plusBtn, row.minusBtn, row.bin, row.eye, row.rule)
    row:SetHover(false)
    row.dzHover:Hide()                  -- (a section takes no hover)
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
    Hide(row.icon, row.sub, row.step, row.amt, row.num, row.plusBtn, row.minusBtn, row.bin, row.eye, row.title, row.barBg,
        row.barFill)
    row:SetHover(false)
    row.dzHover:Hide()
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

-- The detail's banner (D3: UI:CreatePageBanner, tool size, like the Atlas's pages): the group's name, what its crafter
-- knows, Whisper as its action and More (Clear) as its tool. head.title / head.sub are the banner's texts; head.whisper
-- the Whisper button while it is offered.
local WHISPER_ACTION = {
    text = "Whisper", kind = "primary",
    onClick = function()
        local g = FindGroup(ShopUI.groups, state.group)
        if g then Shop():Whisper(g) end
    end,
}
local MORE_TOOL = {
    icon = "more", title = "More",
    menu = function(root)
        local U = UI()
        local b = root:CreateButton(U:AtlasIconText(U.ICON.trash, 12) .. " Clear", function()
            ns.Popup:Show("DISASTERZONE_SHOP_CLEAR")
        end)
        if b and b.SetTooltip then
            b:SetTooltip(function(tt) GameTooltip_SetTitle(tt, "Take everything off the list") end)
        end
    end,
}

local function CreateTitle(parent)
    local h = UI():CreatePageBanner(parent, { size = "tool", width = 392 })
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    h:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    -- (the Whisper button: the banner's first action button, made once and kept)
    h:SetActions({ WHISPER_ACTION })
    h.whisper = h.actions[1]
    h:SetActions(nil)
    return h
end

local function FillTitle(groups, sel, entries)
    local S = Shop()
    local title, sub, whisper = "Shopping list", "", false
    if not sel then
        head:SetTools(#entries > 0 and { MORE_TOOL } or nil)
        if #entries > 0 then sub = #entries == 1 and "1 craft" or (#entries .. " crafts") end
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
        whisper = sel.reach ~= nil
    else
        title = GroupLabel(sel)
    end
    if sel then head:SetTools(nil) end
    head:SetActions(whisper and { WHISPER_ACTION } or nil)
    head:SetKicker(sel and "Shopping list" or nil)
    head:SetTitle(title)
    head:SetSub(sub ~= "" and sub or nil)
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
    -- (a layout region is 1 x 1 until the client lays it out: the detail's width from the layout then)
    self.rowW = (w and w > 1) and w or (H.DETAIL_W or 392)
    local rows = {}
    for _, g in ipairs(sel and { sel } or groups) do
        for _, e in ipairs(g.entries) do
            rows[#rows + 1] = { type = "item", e = e, g = g, showWho = sel == nil,
                                counted = S:IsCounted(e, g.kind == "bop"), maxDepth = S:GetMaxDepth(e.id) }
        end
    end
    local matEntries = S:GetMaterialEntries(sel and { sel } or groups)
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
    -- (empty: the illustrated state in the column; the plain text stays set for whoever reads it)
    list:SetEmptyState(#entries == 0 and { glyph = UI().ICON.bag, title = "Your shopping list is empty",
                                           text = "Hover a craft in the Atlas and click its bag." } or nil)
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
    GameTooltip:AddLine("Add to shopping list", Style:Color("GOLD"))
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

-- helpers: { TextWidth, CodedWidth (text, style), NameText, HEAD_H, BANNER_H }; midFrame / rightFrame: the
-- Atlas's middle and right columns.
function ShopUI:Create(helpers, midFrame, rightFrame)
    if list then return end
    H = helpers
    local U = UI()
    mid = CreateFrame("Frame", nil, midFrame)
    mid:SetAllPoints(midFrame)
    right = CreateFrame("Frame", nil, rightFrame)
    right:SetAllPoints(rightFrame)

    midHead = U:CreateSectionHeader(mid, "Made by", { style = "title" })
    midHead:SetPoint("TOPLEFT", mid, "TOPLEFT", 0, 0)
    midHead:SetPoint("TOPRIGHT", mid, "TOPRIGHT", 0, 0)
    groupList = U:CreateScrollList(mid, ROW_GROUP, InitGroupRow)
    groupList.frame:SetPoint("TOPLEFT", mid, "TOPLEFT", 0, -(H.HEAD_H + 4))
    groupList.frame:SetPoint("BOTTOMRIGHT", mid, "BOTTOMRIGHT", 0, 0)
    groupList.box:ClearAllPoints()
    groupList.box:SetAllPoints(groupList.frame)

    head = CreateTitle(right)
    list = U:CreateScrollList(right, ROW_ITEM, InitRow, Extent)
    list.frame:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -(H.BANNER_H + Style.GAP))
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

    ns.Popup.dialogs["DISASTERZONE_SHOP_CLEAR"] = {
        title = "Clear the shopping list",
        danger = true,
        text = "Take everything off your shopping list?",
        button1 = "Clear",
        button2 = CANCEL or "Cancel",
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
