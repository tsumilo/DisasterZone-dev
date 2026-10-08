if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIFrames.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIFrames.lua
-- CraftUI's windows on the client's own frames (UI.Build from Layouts.lua: Blizzard's FrameXML): the loot window,
-- the bags, the merchant, the quest frame (details, progress, reward) and the gossip frame - each filled the way
-- Blizzard's own code fills it (LootFrame.lua, ContainerFrame_Shared.lua, MerchantFrame.lua, QuestFrame.lua /
-- QuestInfo.lua, GossipFrameShared.lua: the same anchors, offsets, sizes and colours), driven by the game here.
-- Panels open where the client opens them: the left slot at (16, -116), the next one beside it.
local addonName, ns = ...

local UI = ns.CraftUI
local K = UI.Kit
local Craft = ns.Craft
local D = Craft.D
local Items = Craft.Items
local Combat = Craft.Combat

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local F = {}
UI.Frames = F

---------------------------------------------------------------------------
-- Shared pieces: panels, item buttons, money, tabs
---------------------------------------------------------------------------

local LEFT_OFFSET, TOP_OFFSET = 16, -116            -- (UIParent's LEFT_OFFSET / TOP_OFFSET attributes)

-- a panel's place in the left-to-right row of open panels: { xoffset, yoffset, width } as in UIPanelWindows
local PANEL = {
    loot = nil, quest = { 0, 0, 338 }, gossip = { 0, 0, 338 }, merchant = { 0, 0, 338 },
    trainer = { -16, 12, 353 }, questlog = { -16, 12, 353 }, spellbook = { -16, 12, 353 },
    character = { -16, 12, 353 },
}

function UI.ShowWindow(name, f, side)
    if not f then return end
    UI.SetLevelTree(f, UI.hudFrame:GetFrameLevel() + 60)
    UI.open[name] = f
    local info = PANEL[name]
    if info then
        -- the next free slot from the left, like the client's panel manager
        local x = LEFT_OFFSET
        for n, g in pairs(UI.open) do
            if g ~= f and g:IsShown() and g.panelX and PANEL[n] then x = max(x, g.panelX + g.panelW) end
        end
        if x > LEFT_OFFSET + 360 then
            -- (two panels at most: the newest replaces the one on the right)
            for n, g in pairs(UI.open) do
                if g ~= f and g:IsShown() and g.panelX and g.panelX > LEFT_OFFSET then UI.CloseWindow(g) end
            end
            x = LEFT_OFFSET + 338
        end
        f.panelX, f.panelW = x, info[3]
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UI.hudFrame, "TOPLEFT", x + info[1], TOP_OFFSET + info[2])
    end
    f:Show()
end

local function CloseButtonOf(f, refs, name)
    local b = refs[name .. "CloseButton"] or f.CloseButton
    if b then b:SetScript("OnClick", function() UI.CloseWindow(f) end) end
end

-- ButtonFrameTemplate_HideButtonBar
local function HideButtonBar(f, refs, name)
    local inset = refs[name .. "Inset"] or f.Inset
    if inset then inset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 4) end
    for _, k in ipairs({ "BtnCornerLeft", "BtnCornerRight", "ButtonBottomBorder" }) do
        local t = refs[name .. k]
        if t then t:Hide() end
    end
end

-- the frame title and the round portrait (PortraitFrameTemplate)
local function TitleAndPortrait(f, refs, name, title, portraitFn)
    local t = refs[name .. "TitleText"] or (f.TitleContainer and f.TitleContainer.TitleText)
    if t then t:SetText(title or "") end
    local p = refs[name .. "Portrait"] or f.portrait
    if p and portraitFn then portraitFn(p) end
end

local function NpcPortrait(t, u)
    if u and u.cr and u.cr.disp and SetPortraitTextureFromCreatureDisplayID then
        local ok = pcall(SetPortraitTextureFromCreatureDisplayID, t, u.cr.disp)
        if ok then return end
    end
    if SetPortraitToTexture then pcall(SetPortraitToTexture, t, "Interface\\CharacterFrame\\TempPortrait")
    else t:SetTexture("Interface\\CharacterFrame\\TempPortrait") end
end
F.NpcPortrait = NpcPortrait

-- an ItemButtonTemplate (by its Blizzard name): icon, count, quality border, tint
function F.SetItemButton(refs, bname, id, count, tintRed)
    local b = refs[bname]
    if not b then return end
    local icon = refs[bname .. "IconTexture"] or b.icon
    local cnt = refs[bname .. "Count"] or b.Count
    b.itemId = id
    if icon then
        if id then icon:SetTexture(Items.Icon(id)) icon:Show() else icon:SetTexture(nil) end
        if tintRed then icon:SetVertexColor(0.9, 0, 0) else icon:SetVertexColor(1, 1, 1) end
    end
    if cnt then
        if count and count > 1 then cnt:SetText(count) cnt:Show() else cnt:Hide() end
    end
    local border = b.IconBorder
    if border then
        local it = id and D.items[id]
        if it and (it.q or 1) >= 2 then
            local c = Items.QUALITY_RGB[it.q]
            border:SetTexture("Interface\\Common\\WhiteIconFrame")
            border:SetVertexColor(c[1], c[2], c[3])
            border:Show()
        else
            border:Hide()
        end
    end
end

-- MoneyFrame_Update: gold / silver / copper buttons with their coin icons, the empty ones folded away
local ICON_W, SPACING = 13, -4
local COIN = { Gold = { 0, 0.25 }, Silver = { 0.25, 0.5 }, Copper = { 0.5, 0.75 } }
function F.Money(refs, fname, copper, red)
    local frame = refs[fname]
    if not frame then return end
    copper = floor(copper or 0)
    local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
    local vals = { Gold = g, Silver = s, Copper = c }
    local prev
    local show = false
    for _, den in ipairs({ "Gold", "Silver", "Copper" }) do
        local b = refs[fname .. den .. "Button"]
        if b then
            if not b.coin then
                b.coin = b:CreateTexture(nil, "ARTWORK")
                b.coin:SetTexture("Interface\\MoneyFrame\\UI-MoneyIcons")
                b.coin:SetTexCoord(COIN[den][1], COIN[den][2], 0, 1)
                b.coin:SetSize(ICON_W, ICON_W)
                b.coin:SetPoint("RIGHT", b, "RIGHT", 0, 0)
                b.text = b:GetFontString() or b:CreateFontString(nil, "OVERLAY", "NumberFontNormalRight")
                if not b:GetFontString() then b:SetFontString(b.text) end
                if b.text.SetFontObject and _G.NumberFontNormalRight then b.text:SetFontObject(_G.NumberFontNormalRight) end
                b.text:ClearAllPoints()
                b.text:SetPoint("RIGHT", b, "RIGHT", -ICON_W, 0)
            end
            local v = vals[den]
            if v > 0 or show or den == "Copper" and copper == 0 then
                show = true
                b:SetText(v)
                b.text:SetTextColor(red and 1 or 1, red and 0.1 or 1, red and 0.1 or 1)
                b:SetWidth((b.text:GetStringWidth() or 8) + ICON_W)
                b:SetHeight(13)
                b:Show()
            else
                b:Hide()
            end
        end
    end
    -- right to left, copper on the frame's right edge
    local cb, sb, gb = refs[fname .. "CopperButton"], refs[fname .. "SilverButton"], refs[fname .. "GoldButton"]
    if cb then cb:ClearAllPoints() cb:SetPoint("RIGHT", frame, "RIGHT", 0, 0) end
    if sb then sb:ClearAllPoints() sb:SetPoint("RIGHT", cb, "LEFT", -SPACING, 0) end
    if gb then gb:ClearAllPoints() gb:SetPoint("RIGHT", sb, "LEFT", -SPACING, 0) end
    frame:Show()
end

-- PanelTemplates_SetTab: the selected tab drawn in its active art
local function SetTabs(refs, prefix, n, selected)
    for i = 1, n do
        local tab = refs[prefix .. i]
        if tab then
            local on = i == selected
            for _, part in ipairs({ "Left", "Middle", "Right" }) do
                local a, b = refs[prefix .. i .. part], refs[prefix .. i .. part .. "Disabled"]
                if a then a:SetShown(not on) end
                if b then b:SetShown(on) end
            end
            local fs = tab:GetFontString()
            if fs then fs:SetTextColor(on and 1 or 1, on and 1 or 0.82, on and 1 or 0) end
            -- PanelTemplates_TabResize: the middle as wide as the text + 24, the tab that plus its two sides
            local left, mid, midD = refs[prefix .. i .. "Left"], refs[prefix .. i .. "Middle"], refs[prefix .. i .. "MiddleDisabled"]
            if fs and left then
                fs:SetWidth(0)
                local w = (fs:GetStringWidth() or 40) + 24
                if mid then mid:SetWidth(w) end
                if midD then midD:SetWidth(w) end
                tab:SetWidth(w + 2 * (left:GetWidth() or 20))
                local hl = refs[prefix .. i .. "HighlightTexture"] or (tab.GetHighlightTexture and tab:GetHighlightTexture())
                if hl then hl:SetWidth(w + 2 * (left:GetWidth() or 20)) end
            end
        end
    end
end

-- a scroll frame of the layouts (UIPanelScrollFrameTemplate): the wheel scrolls it, the bar follows
local function WireScroll(refs, sname)
    local sf = refs[sname]
    if not sf or sf.wired then return sf end
    sf.wired = true
    local bar = refs[sname .. "ScrollBar"]
    local up, down = refs[sname .. "ScrollBarScrollUpButton"], refs[sname .. "ScrollBarScrollDownButton"]
    local function range()
        local child = sf.GetScrollChild and sf:GetScrollChild()
        local h = child and child:GetHeight() or 0
        return max(0, h - (sf:GetHeight() or 0))
    end
    local function set(v)
        v = max(0, min(range(), v))
        sf:SetVerticalScroll(v)
        if bar and bar.SetMinMaxValues then bar:SetMinMaxValues(0, range()) bar:SetValue(v) end
    end
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, d) set(sf:GetVerticalScroll() - d * 20) end)
    if bar and bar.SetScript then
        bar:SetMinMaxValues(0, 1)
        bar:SetValueStep(1)
        bar:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
    end
    if up then up:SetScript("OnClick", function() set(sf:GetVerticalScroll() - 20) end) end
    if down then down:SetScript("OnClick", function() set(sf:GetVerticalScroll() + 20) end) end
    sf.SetTo = set
    return sf
end
F.WireScroll = WireScroll

---------------------------------------------------------------------------
-- The loot window (LootFrame)
---------------------------------------------------------------------------

local loot, lootRefs
local LOOT_BUTTONS = 4

local function LootFrame()
    if loot then return loot end
    loot, lootRefs = UI.Build("LootFrame", UI.hudFrame)
    -- (loot: the HUD frame's strata; frame levels order the windows)
    HideButtonBar(loot, lootRefs, "LootFrame")
    CloseButtonOf(loot, lootRefs, "LootFrame")
    lootRefs.LootFrameCloseButton:SetScript("OnClick", function() Craft.Loot.Close() end)
    loot.page = 1
    for i = 1, LOOT_BUTTONS do
        local b = lootRefs["LootButton" .. i]
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnLeave", K.HideTooltip)
    end
    lootRefs.LootFrameUpButton:SetScript("OnClick", function() loot.page = loot.page - 1 UI.RefreshLoot() end)
    lootRefs.LootFrameDownButton:SetScript("OnClick", function() loot.page = loot.page + 1 UI.RefreshLoot() end)
    loot.onClose = function() if Craft.Loot.open then Craft.Loot.Close() end end
    return loot
end

function UI.RefreshLoot()
    if not loot or not loot:IsShown() then return end
    local l = Craft.Loot.Items()
    if not l then UI.CloseWindow(loot) return end
    local entries = {}
    if l.money > 0 then entries[#entries + 1] = { money = l.money } end
    for i, it in ipairs(l.items) do
        if not it.taken and (not it.owner or it.owner == Craft.player.guid) then entries[#entries + 1] = { idx = i, it = it } end
    end
    if #entries == 0 then Craft.Loot.Close() return end
    -- (more than four: three a page and the page buttons)
    local per = #entries > LOOT_BUTTONS and LOOT_BUTTONS - 1 or LOOT_BUTTONS
    local pages = ceil(#entries / per)
    loot.page = max(1, min(loot.page, pages))
    for i = 1, LOOT_BUTTONS do
        local name = "LootButton" .. i
        local b = lootRefs[name]
        local e = entries[(loot.page - 1) * per + i]
        if e and i <= per then
            local text = lootRefs[name .. "Text"]
            if e.money then
                lootRefs[name .. "IconTexture"]:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
                lootRefs[name .. "Count"]:Hide()
                text:SetText(Craft.MoneyText(e.money):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
                text:SetVertexColor(1, 1, 1)
                if b.IconBorder then b.IconBorder:Hide() end
                b:SetScript("OnClick", function() Craft.Loot.TakeMoney() UI.RefreshLoot() end)
                b:SetScript("OnEnter", nil)
            else
                F.SetItemButton(lootRefs, name, e.it.id, e.it.n)
                local it = D.items[e.it.id]
                local q = Items.QUALITY_RGB[it and it.q or 1]
                text:SetText((it and it.n or "?"))
                text:SetVertexColor(q[1], q[2], q[3])
                local nf = lootRefs[name .. "NameFrame"]
                if nf then nf:SetVertexColor(e.it.rolling and 1 or 0.5, e.it.rolling and 0 or 0.5, e.it.rolling and 0 or 0.5) end
                b:SetScript("OnClick", function() Craft.Loot.Take(e.idx) UI.RefreshLoot() end)
                b:SetScript("OnEnter", function(self) K.ItemTooltip(self, e.it.id) end)
            end
            b:Show()
        else
            b:Hide()
        end
    end
    local paged = #entries > LOOT_BUTTONS
    lootRefs.LootFrameUpButton:SetShown(paged)
    lootRefs.LootFrameDownButton:SetShown(paged)
    lootRefs.LootFramePrev:SetShown(paged)
    lootRefs.LootFrameNext:SetShown(paged)
    if paged then
        lootRefs.LootFrameUpButton:SetEnabled(loot.page > 1)
        lootRefs.LootFrameDownButton:SetEnabled(loot.page < pages)
    end
end

function UI.OpenLoot()
    local f = LootFrame()
    UI.open.loot = f
    f.page = 1
    UI.SetLevelTree(f, UI.hudFrame:GetFrameLevel() + 70)
    -- under the cursor, the client's way (x - 40, y + 95; never lower than 350 from the bottom)
    local x, y = GetCursorPosition()
    local s = UI.hudFrame:GetEffectiveScale()
    local l, b = UI.hudFrame:GetLeft() or 0, UI.hudFrame:GetBottom() or 0
    x, y = x / s - l, y / s - b
    local posX, posY = x - 40, max(350, y + 95)
    local W, H = UI.PanelSize()
    local hs = UI.hudFrame:GetScale() or 1
    W, H = W / hs, H / hs
    posX = Craft.Clamp(posX, 0, max(0, W - 170))
    posY = Craft.Clamp(posY, 240, H)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UI.hudFrame, "BOTTOMLEFT", posX, posY)
    f:Show()
    UI.RefreshLoot()
end

Craft:On("lootclose", function() if loot and loot:IsShown() then UI.open.loot = nil loot:Hide() end end)

---------------------------------------------------------------------------
-- Bags (ContainerFrameTemplate, ContainerFrame_GenerateFrame)
---------------------------------------------------------------------------

local bags = {}                      -- [bag] = { f, refs }
local CNAME = "ContainerFrameTemplate"
local CONTAINER_WIDTH = 192

local function GenerateBag(f, refs, size, id)
    local top, mid1, mid2, bot = refs[CNAME .. "BackgroundTop"], refs[CNAME .. "BackgroundMiddle1"],
                                 refs[CNAME .. "BackgroundMiddle2"], refs[CNAME .. "BackgroundBottom"]
    local one = refs[CNAME .. "Background1Slot"]
    local rows = ceil(size / 4)
    one:Hide()
    if id == 0 then
        top:SetTexture("Interface\\ContainerFrame\\UI-BackpackBackground")
        top:SetHeight(255)
        top:SetTexCoord(0, 1, 0, 1)
        top:Show()
        bot:Hide() mid1:Hide() mid2:Hide()
        local m = refs[CNAME .. "MoneyFrame"]
        m:ClearAllPoints()
        m:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -215)
        m:Show()
        f:SetHeight(240)
    else
        local file = "Interface\\ContainerFrame\\UI-Bag-Components"
        top:SetTexture(file) mid1:SetTexture(file) mid2:SetTexture(file) bot:SetTexture(file)
        bot:SetHeight(10)
        bot:SetTexCoord(0, 1, 0.330078125, 0.349609375)
        refs[CNAME .. "MoneyFrame"]:Hide()
        top:Show()
        if size % 4 == 2 then
            top:SetTexCoord(0, 1, 0.189453125, 0.330078125) top:SetHeight(72)
        elseif rows == 1 then
            top:SetTexCoord(0, 1, 0.00390625, 0.16796875) top:SetHeight(86)
        else
            top:SetTexCoord(0, 1, 0.00390625, 0.18359375) top:SetHeight(94)
        end
        local middle = 0
        mid1:Hide() mid2:Hide()
        if rows == 1 then
            bot:ClearAllPoints()
            bot:SetPoint("TOP", mid1, "TOP", 0, 0)
        else
            local remaining = rows - 1
            local last = mid1
            for i, tex in ipairs({ mid1, mid2 }) do
                if remaining <= 0 then break end
                local h
                if remaining > 6 then
                    h = 6 * 41 + 0.353515625
                    remaining = remaining - 6
                else
                    h = remaining * 41 - 9
                    remaining = 0
                end
                tex:SetHeight(h)
                tex:SetTexCoord(0, 1, 0.353515625, h / 512 + 0.353515625)
                tex:Show()
                middle = middle + h
                last = tex
            end
            bot:ClearAllPoints()
            bot:SetPoint("TOP", last, "BOTTOM", 0, 0)
        end
        bot:Show()
        f:SetHeight(top:GetHeight() + bot:GetHeight() + middle)
    end
    f:SetWidth(CONTAINER_WIDTH)
    -- the buttons: from the bottom right, right to left, rows upward; button i shows slot size - i + 1
    for i = 1, 36 do
        local b = refs[CNAME .. "Item" .. i]
        if b then
            if i <= size then
                b.slotIndex = size - i + 1
                b:ClearAllPoints()
                if i == 1 then
                    if id == 0 then b:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -12, -208)
                    else b:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 9) end
                elseif (i - 1) % 4 == 0 then
                    b:SetPoint("BOTTOMRIGHT", refs[CNAME .. "Item" .. (i - 4)], "TOPRIGHT", 0, 4)
                else
                    b:SetPoint("BOTTOMRIGHT", refs[CNAME .. "Item" .. (i - 1)], "BOTTOMLEFT", -5, 0)
                end
                b:Show()
            else
                b:Hide()
            end
        end
    end
end

local function BagSlotButton(b, bag)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnClick", function(self, button)
        local s = self.slotIndex
        if button == "RightButton" then
            UI.ClearCursorItem()
            if UI.open.merchant then Items.Sell(bag, s) K.Play(K.SFX.coin) return end
            Items.Use(bag, s)
            return
        end
        if UI.cursorAction then UI.ClearCursorItem() return end
        if UI.cursorItem then UI.DropOnBag(bag, s) return end
        if IsShiftKeyDown and IsShiftKeyDown() then
            local x = Items.Get(bag, s)
            if x and x.n > 1 then
                local fb, fs = Items.FirstFree()
                if fb then Items.Move(bag, s, fb, fs, floor(x.n / 2)) end
                return
            end
        end
        UI.PickupBagItem(bag, s)
    end)
    b:SetScript("OnDragStart", function(self) if not UI.cursorItem then UI.PickupBagItem(bag, self.slotIndex) end end)
    b:SetScript("OnReceiveDrag", function(self) if UI.cursorItem then UI.DropOnBag(bag, self.slotIndex) end end)
    b:SetScript("OnEnter", function(self)
        local x = Items.Get(bag, self.slotIndex)
        if x then K.ItemTooltip(self, x.id) end
    end)
    b:SetScript("OnLeave", K.HideTooltip)
end

local function BagFrame(bag)
    local e = bags[bag]
    if e and e.size == Items.BagSize(bag) then return e end
    if e then e.f:Hide() end
    local f, refs = UI.Build(CNAME, UI.hudFrame)
    -- (f: the HUD frame's strata; frame levels order the windows)
    e = { f = f, refs = refs, size = Items.BagSize(bag) }
    bags[bag] = e
    GenerateBag(f, refs, e.size, bag)
    for i = 1, e.size do BagSlotButton(refs[CNAME .. "Item" .. i], bag) end
    local close = refs[CNAME .. "CloseButton"] or f.CloseButton
    if close then close:SetScript("OnClick", function() UI.CloseWindow(f) end) end
    f.bag = bag
    return e
end

-- the client's stacking: up from the bottom right over the bags bar, a new column to the left when full
local function AnchorBags()
    local W, H = UI.PanelSize()
    local hs = UI.hudFrame:GetScale() or 1
    H = H / hs
    local x, y = -4, 70
    local colW = 0
    for _, b in ipairs(Items.BagList()) do
        local e = bags[b]
        if e and e.f:IsShown() then
            local h = e.f:GetHeight() or 200
            if y + h > H - 40 and y > 70 then
                x = x - CONTAINER_WIDTH
                y = 70
            end
            e.f:ClearAllPoints()
            e.f:SetPoint("BOTTOMRIGHT", UI.hudFrame, "BOTTOMRIGHT", x, y)
            UI.SetLevelTree(e.f, UI.hudFrame:GetFrameLevel() + 50)
            y = y + h
        end
    end
end

function UI.ToggleBag(b)
    if Items.BagSize(b) <= 0 then return end
    local e = BagFrame(b)
    if e.f:IsShown() then UI.CloseWindow(e.f) AnchorBags() return end
    UI.open["bag" .. b] = e.f
    e.f:Show()
    AnchorBags()
    K.Play(K.SFX.bag, 0.1)
    UI.RefreshBags()
end

function UI.OpenAllBags(open)
    for _, b in ipairs(Items.BagList()) do
        local e = bags[b]
        local shown = e and e.f:IsShown()
        if open and not shown then UI.ToggleBag(b) elseif not open and shown then UI.CloseWindow(e.f) end
    end
    AnchorBags()
end

function UI.ToggleAllBags()
    local any = false
    for _, e in pairs(bags) do if e.f:IsShown() then any = true end end
    UI.OpenAllBags(not any)
end

function UI.RefreshBags()
    local c = Craft.char
    if not c then return end
    for b, e in pairs(bags) do
        if e.f:IsShown() then
            local refs = e.refs
            local it = b > 0 and c.bags[b] and c.bags[b].item
            refs[CNAME .. "Name"]:SetText(b == 0 and "Backpack" or (it and D.items[it] and D.items[it].n or "Bag"))
            local p = refs[CNAME .. "Portrait"]
            local tex = b == 0 and "Interface\\Buttons\\Button-Backpack-Up" or Items.Icon(it)
            if SetPortraitToTexture then pcall(SetPortraitToTexture, p, tex) else p:SetTexture(tex) end
            for i = 1, e.size do
                local name = CNAME .. "Item" .. i
                local bt = refs[name]
                local x = Items.Get(b, bt.slotIndex)
                F.SetItemButton(refs, name, x and x.id, x and x.n)
                local q = refs[name .. "IconQuestTexture"]
                if q then
                    local d = x and D.items[x.id]
                    if d and d.c == 12 then
                        q:SetTexture(d.quest and "Interface\\ContainerFrame\\UI-Icon-QuestBang" or "Interface\\ContainerFrame\\UI-Icon-QuestBorder")
                        q:Show()
                    else
                        q:Hide()
                    end
                end
            end
            if b == 0 then F.Money(refs, CNAME .. "MoneyFrame", c.money) end
        end
    end
end

---------------------------------------------------------------------------
-- The merchant (MerchantFrame, TBC)
---------------------------------------------------------------------------

local mer, merRefs
local function MerchantFrame()
    if mer then return mer end
    mer, merRefs = UI.Build("MerchantFrame", UI.hudFrame)
    -- (mer: the HUD frame's strata; frame levels order the windows)
    CloseButtonOf(mer, merRefs, "MerchantFrame")
    mer.page, mer.tab = 1, 1
    merRefs.MerchantPrevPageButton:SetScript("OnClick", function() mer.page = max(1, mer.page - 1) UI.RefreshMerchant() end)
    merRefs.MerchantNextPageButton:SetScript("OnClick", function() mer.page = mer.page + 1 UI.RefreshMerchant() end)
    merRefs.MerchantFrameTab1:SetText(UI.Str("MERCHANT"))
    merRefs.MerchantFrameTab2:SetText(UI.Str("BUYBACK"))
    merRefs.MerchantFrameTab1:SetScript("OnClick", function() mer.tab = 1 UI.RefreshMerchant() end)
    merRefs.MerchantFrameTab2:SetScript("OnClick", function() mer.tab = 2 UI.RefreshMerchant() end)
    -- (no durability in this game: no repair buttons; the money sits where a non-repairing vendor shows it)
    for _, k in ipairs({ "MerchantRepairAllButton", "MerchantRepairItemButton", "MerchantGuildBankRepairButton", "MerchantRepairText" }) do
        if merRefs[k] then merRefs[k]:Hide() end
    end
    merRefs.MerchantMoneyFrame:ClearAllPoints()
    merRefs.MerchantMoneyFrame:SetPoint("BOTTOMRIGHT", mer, "BOTTOMRIGHT", -4, 8)
    for i = 1, 12 do
        local ib = merRefs["MerchantItem" .. i .. "ItemButton"]
        if ib then
            ib:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            ib:SetScript("OnLeave", K.HideTooltip)
        end
    end
    merRefs.MerchantBuyBackItemItemButton:SetScript("OnClick", function() Items.BuyBack(1) UI.RefreshMerchant() end)
    merRefs.MerchantBuyBackItemItemButton:SetScript("OnEnter", function(self)
        local e = Items.buyback[1]
        if e then K.ItemTooltip(self, e.id, "nosell") end
    end)
    merRefs.MerchantBuyBackItemItemButton:SetScript("OnLeave", K.HideTooltip)
    mer.onClose = function() mer.npc = nil end
    return mer
end

function UI.OpenMerchant(u)
    local f = MerchantFrame()
    f.npc = u
    f.page, f.tab = 1, 1
    TitleAndPortrait(f, merRefs, "MerchantFrame", u.name, function(p) NpcPortrait(p, u) end)
    if UI.open.gossip then UI.CloseWindow(UI.open.gossip) end
    if UI.open.quest then UI.CloseWindow(UI.open.quest) end
    UI.ShowWindow("merchant", f)
    UI.OpenAllBags(true)
    K.Play(K.SFX.coin, 0.1)
    UI.RefreshMerchant()
end

local function MerchantRow(i, id, count, price, onClick, canAfford, usable, tooltipExtra)
    local name = "MerchantItem" .. i
    local row = merRefs[name]
    local ib = merRefs[name .. "ItemButton"]
    if not id then
        merRefs[name .. "Name"]:SetText("")
        merRefs[name .. "MoneyFrame"]:Hide()
        ib:Hide()
        return
    end
    row:Show()
    local it = D.items[id]
    merRefs[name .. "Name"]:SetText(it and it.n or "?")
    F.SetItemButton(merRefs, name .. "ItemButton", id, count, not usable)
    local nf = merRefs[name .. "NameFrame"]
    if nf then if usable then nf:SetVertexColor(0.5, 0.5, 0.5) else nf:SetVertexColor(1, 0, 0) end end
    local slot = merRefs[name .. "SlotTexture"]
    if slot then if usable then slot:SetVertexColor(1, 1, 1) else slot:SetVertexColor(1, 0, 0) end end
    F.Money(merRefs, name .. "MoneyFrame", price, not canAfford)
    ib:SetScript("OnClick", onClick)
    ib:SetScript("OnEnter", function(self) K.ItemTooltip(self, id, tooltipExtra or "nosell") end)
    ib:Show()
end

function UI.RefreshMerchant()
    local f = mer
    if not f or not f:IsShown() or not f.npc then return end
    SetTabs(merRefs, "MerchantFrameTab", 2, f.tab)
    local money = Craft:Money()
    if f.tab == 1 then
        merRefs.MerchantNameText:SetText(f.npc.name)
        local stock = Craft.Npc.Stock(f.npc)
        local pages = max(1, ceil(#stock / 10))
        f.page = min(f.page, pages)
        merRefs.MerchantPageText:SetFormattedText(UI.Str("PAGE_NUMBER"), f.page)
        for i = 1, 10 do
            local e = stock[(f.page - 1) * 10 + i]
            if e then
                local it = D.items[e.id]
                local usable = not (it.inv and Items.INV_SLOTS[it.inv]) or Items.CanEquip(it, Craft.char)
                MerchantRow(i, e.id, e.count, e.price, function(_, button)
                    local n = (IsShiftKeyDown and IsShiftKeyDown()) and 5 or 1
                    if Items.Buy(e.id, n) then K.Play(K.SFX.coin) end
                end, money >= e.price, usable)
            else
                MerchantRow(i)
            end
        end
        for i = 11, 12 do if merRefs["MerchantItem" .. i] then merRefs["MerchantItem" .. i]:Hide() end end
        local paged = #stock > 10
        merRefs.MerchantPageText:SetShown(paged)
        merRefs.MerchantPrevPageButton:SetShown(paged)
        merRefs.MerchantNextPageButton:SetShown(paged)
        if paged then
            merRefs.MerchantPrevPageButton:SetEnabled(f.page > 1)
            merRefs.MerchantNextPageButton:SetEnabled(f.page < pages)
        end
        merRefs.MerchantItem3:SetPoint("TOPLEFT", merRefs.MerchantItem1, "BOTTOMLEFT", 0, -8)
        merRefs.MerchantItem5:SetPoint("TOPLEFT", merRefs.MerchantItem3, "BOTTOMLEFT", 0, -8)
        merRefs.MerchantItem7:SetPoint("TOPLEFT", merRefs.MerchantItem5, "BOTTOMLEFT", 0, -8)
        merRefs.MerchantItem9:SetPoint("TOPLEFT", merRefs.MerchantItem7, "BOTTOMLEFT", 0, -8)
        if merRefs.BuybackBG then merRefs.BuybackBG:Hide() end
        -- the last item sold, in its slot at the bottom
        local bb = Items.buyback[1]
        local bbr = merRefs.MerchantBuyBackItem
        bbr:Show()
        if bb then
            merRefs.MerchantBuyBackItemName:SetText(D.items[bb.id] and D.items[bb.id].n or "")
            F.SetItemButton(merRefs, "MerchantBuyBackItemItemButton", bb.id, bb.n)
            F.Money(merRefs, "MerchantBuyBackItemMoneyFrame", bb.price)
        else
            merRefs.MerchantBuyBackItemName:SetText("")
            F.SetItemButton(merRefs, "MerchantBuyBackItemItemButton", nil)
            merRefs.MerchantBuyBackItemMoneyFrame:Hide()
        end
    else
        -- the buyback tab: the last twelve sold, two columns, 15 apart
        merRefs.MerchantNameText:SetText(UI.Str("BUYBACK"))
        merRefs.MerchantPageText:Hide()
        merRefs.MerchantPrevPageButton:Hide()
        merRefs.MerchantNextPageButton:Hide()
        merRefs.MerchantBuyBackItem:Hide()
        if merRefs.BuybackBG then merRefs.BuybackBG:Show() end
        for i = 1, 12 do
            local e = Items.buyback[i]
            if merRefs["MerchantItem" .. i] then
                if e then
                    MerchantRow(i, e.id, e.n, e.price, function() Items.BuyBack(i) UI.RefreshMerchant() end, money >= e.price, true)
                else
                    MerchantRow(i)
                end
            end
        end
        merRefs.MerchantItem3:SetPoint("TOPLEFT", merRefs.MerchantItem1, "BOTTOMLEFT", 0, -15)
        merRefs.MerchantItem5:SetPoint("TOPLEFT", merRefs.MerchantItem3, "BOTTOMLEFT", 0, -15)
        merRefs.MerchantItem7:SetPoint("TOPLEFT", merRefs.MerchantItem5, "BOTTOMLEFT", 0, -15)
        merRefs.MerchantItem9:SetPoint("TOPLEFT", merRefs.MerchantItem7, "BOTTOMLEFT", 0, -15)
    end
    F.Money(merRefs, "MerchantMoneyFrame", money)
end

---------------------------------------------------------------------------
-- The quest frame (QuestFrame + QuestInfo, TBC) and the gossip frame
---------------------------------------------------------------------------

local qf, qRefs, qi, qiRefs, rw, rwRefs
local rewardButtons = {}
local TEXT_COLOR, TITLE_COLOR = { 0.18, 0.12, 0.06 }, { 0, 0, 0 }   -- (the parchment's text colours)
local OFFSET = 5                                                      -- (REWARDS_SECTION_OFFSET)

local function QuestFrame()
    if qf then return qf end
    qf, qRefs = UI.Build("QuestFrame", UI.hudFrame)
    -- (qf: the HUD frame's strata; frame levels order the windows)
    qf:SetSize(338, 424)                                -- (QUEST_FRAME_DIMENSIONS for TBC)
    CloseButtonOf(qf, qRefs, "QuestFrame")
    qi, qiRefs = UI.Build("QuestInfoFrame", qf)
    rw, rwRefs = UI.Build("QuestInfoRewardsFrame", qf)
    for k, v in pairs(qiRefs) do qRefs[k] = v end
    for k, v in pairs(rwRefs) do qRefs[k] = v end
    for _, n in ipairs({ "QuestInfoTitleHeader", "QuestInfoDescriptionHeader", "QuestInfoObjectivesHeader" }) do
        qRefs[n]:SetTextColor(TITLE_COLOR[1], TITLE_COLOR[2], TITLE_COLOR[3])
    end
    rw.Header:SetTextColor(TITLE_COLOR[1], TITLE_COLOR[2], TITLE_COLOR[3])
    for _, fs in ipairs({ qRefs.QuestInfoDescriptionText, qRefs.QuestInfoObjectivesText, qRefs.QuestInfoRewardText,
                          rw.ItemChooseText, rw.ItemReceiveText }) do
        fs:SetTextColor(TEXT_COLOR[1], TEXT_COLOR[2], TEXT_COLOR[3])
    end
    rewardButtons[1] = rwRefs.QuestInfoRewardsFrameQuestInfoItem1
    for _, s in ipairs({ "QuestDetailScrollFrame", "QuestProgressScrollFrame", "QuestRewardScrollFrame", "QuestGreetingScrollFrame" }) do
        WireScroll(qRefs, s)
    end
    for _, b in ipairs({ "QuestFrameDeclineButton", "QuestFrameGoodbyeButton", "QuestFrameCancelButton", "QuestFrameGreetingGoodbyeButton" }) do
        if qRefs[b] then qRefs[b]:SetScript("OnClick", function() UI.CloseWindow(qf) end) end
    end
    qf.onClose = function() qf.npc = nil end
    return qf
end

local function ShowPanel(which)
    for _, p in ipairs({ "QuestFrameDetailPanel", "QuestFrameProgressPanel", "QuestFrameRewardPanel", "QuestFrameGreetingPanel" }) do
        if qRefs[p] then qRefs[p]:SetShown(p == which) end
    end
end

local function RewardButton(i)
    local b = rewardButtons[i]
    if not b then
        local r
        b, r = UI.Build("LargeQuestRewardItemButtonTemplate", rw)
        b.refs = r
        rewardButtons[i] = b
    end
    return b
end

local function FillRewardButton(b, id, n, selected, onClick)
    local r = b.refs or rwRefs
    local base = b.refs and "LargeQuestRewardItemButtonTemplate" or "QuestInfoRewardsFrameQuestInfoItem1"
    local icon = r[base .. "IconTexture"]
    local name = r[base .. "Name"]
    local count = r[base .. "Count"]
    icon:SetTexture(Items.Icon(id))
    local it = D.items[id]
    name:SetText(it and it.n or "?")
    if count then if n and n > 1 then count:SetText(n) count:Show() else count:Hide() end end
    local usable = not (it and it.inv and Items.INV_SLOTS[it.inv]) or Items.CanEquip(it, Craft.char)
    icon:SetVertexColor(1, usable and 1 or 0, usable and 1 or 0)
    local nf = r[base .. "NameFrame"]
    if nf then nf:SetVertexColor(1, usable and 1 or 0, usable and 1 or 0) end
    b:SetScript("OnEnter", function(self) K.ItemTooltip(self, id, "nosell") end)
    b:SetScript("OnLeave", K.HideTooltip)
    b:SetScript("OnClick", onClick)
    b:Show()
end

-- QuestInfo_ShowRewards: returns the rewards frame (or nil), laid out the client's way
local function ShowRewards(q, choose, choice, onPick)
    local x = Craft.Quests.Extra(q.id)
    local choices, items = x.choice or {}, x.rew or {}
    local money = x.money or 0
    if #choices == 0 and #items == 0 and money == 0 then rw:Hide() return nil end
    for _, b in ipairs(rewardButtons) do b:Hide() b:ClearAllPoints() end
    local last = rw.Header
    local total = rw.Header:GetHeight() or 18
    local bh = rewardButtons[1]:GetHeight() or 40
    local idx = 0
    rw.ItemChooseText:ClearAllPoints()
    local hl = rwRefs.QuestInfoItemHighlight
    if hl then hl:Hide() end
    if #choices > 0 then
        rw.ItemChooseText:Show()
        rw.ItemChooseText:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -5)
        for i, c in ipairs(choices) do
            idx = idx + 1
            local b = RewardButton(idx)
            FillRewardButton(b, c[1], c[2], choice == i, onPick and function() onPick(i) end or nil)
            if i > 1 then
                if i % 2 == 1 then
                    b:SetPoint("TOPLEFT", rewardButtons[idx - 2], "BOTTOMLEFT", 0, -2)
                    last = b
                    total = total + bh + 2
                else
                    b:SetPoint("TOPLEFT", rewardButtons[idx - 1], "TOPRIGHT", 1, 0)
                end
            else
                b:SetPoint("TOPLEFT", rw.ItemChooseText, "BOTTOMLEFT", 0, -OFFSET)
                last = b
                total = total + bh + OFFSET
            end
            if choice == i and hl then
                hl:ClearAllPoints()
                hl:SetPoint("TOPLEFT", b, "TOPLEFT", -8, 7)
                hl:Show()
            end
        end
        if #choices == 1 then rw.ItemChooseText:SetText(UI.Str("REWARD_ITEMS_ONLY"))
        elseif choose then rw.ItemChooseText:SetText(_G.REWARD_CHOOSE or "Choose your reward:")
        else rw.ItemChooseText:SetText(UI.Str("REWARD_CHOICES")) end
        total = total + (rw.ItemChooseText:GetHeight() or 14) + OFFSET
    else
        rw.ItemChooseText:Hide()
    end
    if #items > 0 or money > 0 then
        local t = rw.ItemReceiveText
        t:SetText(#choices > 0 and UI.Str("REWARD_ITEMS") or UI.Str("REWARD_ITEMS_ONLY"))
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -OFFSET)
        t:Show()
        total = total + (t:GetHeight() or 14) + OFFSET
        last = t
        if money > 0 then F.Money(qRefs, "QuestInfoMoneyFrame", money) else qRefs.QuestInfoMoneyFrame:Hide() end
        local n = 0
        for _, r in ipairs(items) do
            n = n + 1
            idx = idx + 1
            local b = RewardButton(idx)
            FillRewardButton(b, r[1], r[2], false, nil)
            if n > 1 then
                if n % 2 == 1 then
                    b:SetPoint("TOPLEFT", rewardButtons[idx - 2], "BOTTOMLEFT", 0, -2)
                    last = b
                    total = total + bh + 2
                else
                    b:SetPoint("TOPLEFT", rewardButtons[idx - 1], "TOPRIGHT", 1, 0)
                end
            else
                b:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -OFFSET)
                last = b
                total = total + bh + OFFSET
            end
        end
    else
        rw.ItemReceiveText:Hide()
        qRefs.QuestInfoMoneyFrame:Hide()
    end
    for _, k in ipairs({ "QuestInfoXPFrame", "QuestInfoSkillPointFrame", "QuestInfoPlayerTitleFrame" }) do
        if qRefs[k] then qRefs[k]:Hide() end
    end
    if rw.HonorFrame then rw.HonorFrame:Hide() end
    if rw.ArtifactXPFrame then rw.ArtifactXPFrame:Hide() end
    rw.PlayerTitleText:Hide()
    rw:SetHeight(total)
    rw:Show()
    return rw
end

-- QuestInfo_Display: the elements of a template stacked into the scroll child
local function Display(parent, elements)
    for _, n in ipairs({ "QuestInfoTitleHeader", "QuestInfoDescriptionText", "QuestInfoObjectivesHeader",
                         "QuestInfoObjectivesText", "QuestInfoRewardText", "QuestInfoDescriptionHeader",
                         "QuestInfoQuestType", "QuestInfoGroupSize", "QuestInfoRequiredMoneyText", "QuestInfoAnchor" }) do
        if qRefs[n] then qRefs[n]:Hide() end
    end
    if qRefs.QuestInfoSealFrame then qRefs.QuestInfoSealFrame:Hide() end
    rw:Hide()
    local last
    for _, el in ipairs(elements) do
        local w = el[1]
        if w then
            if w.SetParent and w:GetObjectType() ~= "FontString" and w:GetObjectType() ~= "Texture" then w:SetParent(parent) end
            if w:GetObjectType() == "FontString" then
                -- (font strings belong to QuestInfoFrame; it rides along in the scroll child)
                qi:SetParent(parent)
                qi:ClearAllPoints()
                qi:SetAllPoints(parent)
                qi:Show()
            end
            w:ClearAllPoints()
            if last then w:SetPoint("TOPLEFT", last, "BOTTOMLEFT", el[2], el[3])
            else w:SetPoint("TOPLEFT", parent, "TOPLEFT", el[2], el[3]) end
            w:Show()
            last = w
        end
    end
end

local function ScrollChildOf(sname, cname)
    local child = qRefs[cname]
    local sf = qRefs[sname]
    if sf and sf.SetTo then sf.SetTo(0) end
    return child
end

local function Text(fsName, s)
    local fs = qRefs[fsName]
    fs:SetText(Craft.Quests.Text(s))
    return fs
end

function UI.QuestDetail(u, q)
    local f = QuestFrame()
    f.npc = u
    TitleAndPortrait(f, qRefs, "QuestFrame", u and u.name or "", function(p) NpcPortrait(p, u) end)
    if qRefs.QuestFrameNpcNameText then qRefs.QuestFrameNpcNameText:SetText(u and u.name or "") end
    ShowPanel("QuestFrameDetailPanel")
    local child = ScrollChildOf("QuestDetailScrollFrame", "QuestDetailScrollChildFrame")
    qRefs.QuestInfoTitleHeader:SetWidth(275)
    local els = {
        { Text("QuestInfoTitleHeader", q.title), 5, -10 },
        { Text("QuestInfoDescriptionText", q.text), 0, -5 },
        { qRefs.QuestInfoObjectivesHeader, 0, -15 },
        { Text("QuestInfoObjectivesText", q.goal), 0, -5 },
    }
    local r = ShowRewards(q, false)
    if r then els[#els + 1] = { r, 0, -15 } end
    els[#els + 1] = { qRefs.QuestInfoSpacerFrame, 0, -15 }
    Display(child, els)
    qRefs.QuestFrameAcceptButton:SetScript("OnClick", function()
        if Craft.Quests.Accept(q.id) then UI.CloseWindow(f) end
    end)
    UI.ShowWindow("quest", f)
    K.Play(K.SFX.open, 0.1)
end

function UI.QuestProgress(u, q)
    if Craft.Quests.Complete(q.id) then return UI.QuestReward(u, q) end
    local f = QuestFrame()
    f.npc = u
    TitleAndPortrait(f, qRefs, "QuestFrame", u and u.name or "", function(p) NpcPortrait(p, u) end)
    ShowPanel("QuestFrameProgressPanel")
    WireScroll(qRefs, "QuestProgressScrollFrame").SetTo(0)
    local x = Craft.Quests.Extra(q.id)
    qRefs.QuestProgressTitleText:SetText(q.title)
    qRefs.QuestProgressText:SetText(Craft.Quests.Text(x.req or q.ask or q.goal))
    -- the required items (QuestFrameProgressItems_Update)
    local n = 0
    for _, it in ipairs(q.items or {}) do
        local src = x.src
        if not (src and src[1] == it.id and #(it.from or {}) == 0) then
            n = n + 1
            local name = "QuestProgressItem" .. n
            if qRefs[name] then
                F.SetItemButton(qRefs, name, it.id, it.count)
                if qRefs[name .. "Name"] then qRefs[name .. "Name"]:SetText(it.name) end
                qRefs[name]:SetScript("OnEnter", function(self) K.ItemTooltip(self, it.id, "nosell") end)
                qRefs[name]:SetScript("OnLeave", K.HideTooltip)
                qRefs[name]:Show()
            end
        end
    end
    for i = n + 1, 6 do if qRefs["QuestProgressItem" .. i] then qRefs["QuestProgressItem" .. i]:Hide() end end
    if qRefs.QuestProgressRequiredMoneyText then qRefs.QuestProgressRequiredMoneyText:Hide() end
    if qRefs.QuestProgressRequiredMoneyFrame then qRefs.QuestProgressRequiredMoneyFrame:Hide() end
    if qRefs.QuestProgressRequiredItemsText then qRefs.QuestProgressRequiredItemsText:SetShown(n > 0) end
    if n > 0 and qRefs.QuestProgressItem1 then
        qRefs.QuestProgressItem1:ClearAllPoints()
        qRefs.QuestProgressItem1:SetPoint("TOPLEFT", qRefs.QuestProgressRequiredItemsText, "BOTTOMLEFT", -3, -5)
    end
    qRefs.QuestFrameCompleteButton:Disable()
    UI.ShowWindow("quest", f)
end

function UI.QuestReward(u, q, choice)
    local f = QuestFrame()
    f.npc = u
    TitleAndPortrait(f, qRefs, "QuestFrame", u and u.name or "", function(p) NpcPortrait(p, u) end)
    ShowPanel("QuestFrameRewardPanel")
    local x = Craft.Quests.Extra(q.id)
    local child = ScrollChildOf("QuestRewardScrollFrame", "QuestRewardScrollChildFrame")
    qRefs.QuestInfoTitleHeader:SetWidth(285)
    local els = {
        { Text("QuestInfoTitleHeader", q.title), 5, -10 },
        { Text("QuestInfoRewardText", x.offer or q.done or ""), 0, -5 },
    }
    local r = ShowRewards(q, true, choice, function(i) UI.QuestReward(u, q, i) end)
    if r then els[#els + 1] = { r, 0, -10 } end
    els[#els + 1] = { qRefs.QuestInfoSpacerFrame, 0, -10 }
    Display(child, els)
    qRefs.QuestFrameCompleteQuestButton:SetScript("OnClick", function()
        if x.choice and #x.choice > 1 and not choice then Craft:Error("You must choose a reward.") return end
        local pick = choice or ((x.choice and #x.choice == 1) and 1 or nil)
        if Craft.Quests.TurnIn(q.id, pick) then
            UI.CloseWindow(f)
            if u and x.next and Craft.Quests.Get(x.next) and Craft.Quests.Get(x.next).giver == u.entry then
                local nq = Craft.Quests.Get(x.next)
                if Craft.Quests.Available(nq) then UI.QuestDetail(u, nq) end
            end
        end
    end)
    UI.ShowWindow("quest", f)
end

-- the gossip frame: the greeting, then quests and options (GossipFrameShared's linear list)
local gf, gRefs
local gPool = {}

local function GossipFrame()
    if gf then return gf end
    gf, gRefs = UI.Build("GossipFrame", UI.hudFrame)
    -- (gf: the HUD frame's strata; frame levels order the windows)
    gf:SetSize(338, 424)
    CloseButtonOf(gf, gRefs, "GossipFrame")
    local inset = gRefs.GossipFrameInset or gf.Inset
    if inset then inset:SetPoint("BOTTOMRIGHT", gf, "BOTTOMRIGHT", -27, 24) end
    local gp = gf.GreetingPanel
    if gp and gp.GoodbyeButton then
        gp.GoodbyeButton:SetText(UI.Str("GOODBYE"))
        gp.GoodbyeButton:SetScript("OnClick", function() UI.CloseWindow(gf) end)
    end
    gf.onClose = function() gf.npc = nil end
    return gf
end

local GOSSIP_ICONS = { Vendor = "Interface\\GossipFrame\\VendorGossipIcon", Trainer = "Interface\\GossipFrame\\TrainerGossipIcon",
                       Binder = "Interface\\GossipFrame\\BinderGossipIcon", Gossip = "Interface\\GossipFrame\\GossipGossipIcon",
                       offer = "Interface\\GossipFrame\\AvailableQuestIcon", done = "Interface\\GossipFrame\\ActiveQuestIcon",
                       going = "Interface\\GossipFrame\\ActiveQuestIcon" }

local function GossipElement(kind, i)
    local key = kind .. i
    local e = gPool[key]
    if not e then
        local target = gf.GreetingPanel.ScrollBox.ScrollTarget or gf.GreetingPanel.ScrollBox
        if kind == "text" then e = UI.Build("GossipGreetingTextTemplate", target)
        elseif kind == "spacer" then e = UI.Build("GossipSpacerFrameTemplate", target)
        else e = UI.Build("GossipTitleButtonTemplate", target) end
        gPool[key] = e
    end
    return e
end

function UI.OpenGossip(u)
    local g = Craft.Npc.Gossip(u)
    local direct = Craft.Npc.Direct(g)
    if direct == "vendor" then return UI.OpenMerchant(u) end
    if direct == "trainer" then return UI.OpenTrainer(u) end
    if #g.quests == 1 and #g.options == 0 and not (u.cr and u.cr.say) then
        local x = g.quests[1]
        if x.kind == "offer" then return UI.QuestDetail(u, x.q) end
        return UI.QuestProgress(u, x.q)
    end
    local f = GossipFrame()
    f.npc = u
    TitleAndPortrait(f, gRefs, "GossipFrame", u.name, function(p) NpcPortrait(p, u) end)
    for _, e in pairs(gPool) do e:Hide() end
    local box = f.GreetingPanel.ScrollBox
    local target = box.ScrollTarget or box
    local y = 0
    local function place(e, h)
        e:ClearAllPoints()
        e:SetPoint("TOPLEFT", target, "TOPLEFT", 0, -y)
        e:Show()
        y = y + h
    end
    -- the greeting (GossipGreetingTextTemplate: 270 wide, 10 in)
    local t = GossipElement("text", 1)
    t.GreetingText:SetText(g.text or "")
    t.GreetingText:SetTextColor(TEXT_COLOR[1], TEXT_COLOR[2], TEXT_COLOR[3])
    local th = (t.GreetingText:GetStringHeight() or 14)
    t:SetSize(270, th)
    place(t, th + 10)
    place(GossipElement("spacer", 1), 15)
    local i = 0
    local function button(text, icon, grey, onClick)
        i = i + 1
        local b = GossipElement("btn", i)
        b:SetText(text)
        local fs = b:GetFontString()
        if fs then fs:SetTextColor(grey and 0.4 or 0, grey and 0.4 or 0, grey and 0.4 or 0) end
        if b.Icon then
            b.Icon:SetTexture(icon)
            b.Icon:SetVertexColor(1, 1, 1)
        end
        local h = max(((fs and fs:GetStringHeight()) or 12) + 2, b.Icon and b.Icon:GetHeight() or 16)
        b:SetHeight(h)
        b:SetWidth(300)
        b:SetScript("OnClick", onClick)
        place(b, h)
    end
    for _, x in ipairs(g.quests) do
        button(x.q.title, GOSSIP_ICONS[x.kind], x.kind == "going", function()
            if x.kind == "offer" then UI.QuestDetail(u, x.q) else UI.QuestProgress(u, x.q) end
            if UI.open.gossip then UI.CloseWindow(UI.open.gossip) end
        end)
    end
    for _, o in ipairs(g.options) do
        button(o.text, GOSSIP_ICONS[o.icon] or GOSSIP_ICONS.Gossip, false, function()
            if o.action == "vendor" then UI.OpenMerchant(u)
            elseif o.action == "trainer" then UI.OpenTrainer(u)
            elseif o.action == "bind" then Craft.Npc.Bind(u) UI.CloseWindow(f) end
        end)
    end
    target:SetSize(300, max(y, 10))
    UI.ShowWindow("gossip", f)
    K.Play(K.SFX.open, 0.1)
end

---------------------------------------------------------------------------
-- The character sheet (CharacterFrame + PaperDollFrame, TBC): the slots, the model, the two stat boxes
-- (PaperDollFrame.lua: UpdatePaperdollStats - Base Stats on the left, Melee or Spell on the right)
---------------------------------------------------------------------------

local SLOT_BUTTON = { "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrist", "Hands",
                      "Finger0", "Finger1", "Trinket0", "Trinket1", "Back", "MainHand", "SecondaryHand", "Ranged",
                      "Tabard" }
local STAT_CATS = { "PLAYERSTAT_BASE_STATS", "PLAYERSTAT_MELEE_COMBAT", "PLAYERSTAT_RANGED_COMBAT",
                    "PLAYERSTAT_SPELL_COMBAT", "PLAYERSTAT_DEFENSES" }
local STAT_CAT_NAMES = { PLAYERSTAT_BASE_STATS = "Base Stats", PLAYERSTAT_MELEE_COMBAT = "Melee",
                         PLAYERSTAT_RANGED_COMBAT = "Ranged", PLAYERSTAT_SPELL_COMBAT = "Spell",
                         PLAYERSTAT_DEFENSES = "Defenses" }
local cha, chaRefs

local function Pct(v) return string.format("%.2f%%", v or 0) end

-- the six lines of one stat box: { label, value } (UpdatePaperdollStats)
local function StatLines(cat, p)
    local g = p.gearStats or {}
    if cat == "PLAYERSTAT_BASE_STATS" then
        return { { "Strength:", p.str }, { "Agility:", p.agi }, { "Stamina:", p.sta }, { "Intellect:", p.int },
                 { "Spirit:", p.spi }, { "Armor:", p.armor } }
    elseif cat == "PLAYERSTAT_MELEE_COMBAT" then
        local mh, k = p.mh, p.ap / 14 * p.mh[4]
        return { { "Damage:", string.format("%d - %d", max(1, floor(mh[1] + k)), max(1, ceil(mh[2] + k))) },
                 { "Speed:", string.format("%.2f", mh[4] / (p.hasteMult or 1)) }, { "Power:", p.ap },
                 { "Hit Rating:", g.hitR or 0 }, { "Crit Chance:", Pct(p.crit) }, { "Expertise:", 0 } }
    elseif cat == "PLAYERSTAT_RANGED_COMBAT" then
        local r = p.ranged
        if not r then return { { "Damage:", "N/A" }, { "Speed:", "N/A" }, { "Power:", p.ap }, { "Hit Rating:", g.hitR or 0 },
                               { "Crit Chance:", Pct(p.crit) } } end
        return { { "Damage:", string.format("%d - %d", max(1, floor(r[1])), max(1, ceil(r[2]))) },
                 { "Speed:", string.format("%.2f", r[4] or 0) }, { "Power:", p.ap }, { "Hit Rating:", g.hitR or 0 },
                 { "Crit Chance:", Pct(p.crit) } }
    elseif cat == "PLAYERSTAT_SPELL_COMBAT" then
        return { { "Bonus Damage:", p.sp or 0 }, { "Bonus Healing:", g.heal or p.sp or 0 }, { "Hit Rating:", g.spellHitR or 0 },
                 { "Crit Chance:", Pct(p.spellCrit) }, { "Haste Rating:", 0 },
                 { "Mana Regen:", p.powerType == Craft.POWER_MANA and floor((12.5 + p.spi / 4) * 2.5) or 0 } }
    end
    return { { "Armor:", p.armor }, { "Defense:", (p.level or 1) * 5 }, { "Dodge:", Pct(p.dodge) },
             { "Parry:", Pct(p.parry) }, { "Block:", Pct(p.block) }, { "Resilience:", 0 } }
end

-- the category menus over the boxes: Blizzard's dropdown where the client has it, a plain label otherwise
local function StatDropdown(dd, side)
    if not dd then return end
    if dd.SetupMenu then
        pcall(dd.SetWidth, dd, 114)
        dd:SetupMenu(function(_, root)
            for _, cat in ipairs(STAT_CATS) do
                root:CreateRadio(UI.Str(cat) ~= cat and UI.Str(cat) or STAT_CAT_NAMES[cat],
                    function() return cha[side] == cat end,
                    function() cha[side] = cat UI.RefreshCharacter() end, cat)
            end
        end)
        return
    end
    dd:SetSize(114, 18)
    dd.label = dd:CreateFontString(nil, "OVERLAY")
    dd.label:SetFontObject(GameFontHighlightSmall)
    dd.label:SetPoint("LEFT", 4, 0)
    dd:EnableMouse(true)
    dd:SetScript("OnMouseUp", function()
        local i = 1
        for k, cat in ipairs(STAT_CATS) do if cha[side] == cat then i = k end end
        cha[side] = STAT_CATS[i % #STAT_CATS + 1]
        UI.RefreshCharacter()
    end)
end

local function CharacterSheet()
    if cha then return cha end
    cha, chaRefs = UI.Build("CharacterFrame", UI.hudFrame)
    local pd, pdRefs = UI.Build("PaperDollFrame", cha, chaRefs)
    for k, v in pairs(pdRefs) do chaRefs[k] = v end
    pd:SetAllPoints(cha)
    cha.paperDoll = pd
    pd:Show()
    CloseButtonOf(cha, chaRefs, "CharacterFrame")
    -- (one tab: the sheet; no pet, reputation, skills or PvP in Northshire)
    for i = 2, 5 do if chaRefs["CharacterFrameTab" .. i] then chaRefs["CharacterFrameTab" .. i]:Hide() end end
    if chaRefs.PlayerTitleDropdown then chaRefs.PlayerTitleDropdown:Hide() end
    if chaRefs.CharacterResistanceFrame then chaRefs.CharacterResistanceFrame:Show() end
    -- the slots (PaperDollItemSlotButton_OnLoad / _OnClick / _OnEnter)
    for id, nm in ipairs(SLOT_BUTTON) do
        local b = chaRefs["Character" .. nm .. "Slot"]
        if b then
            b.slot = id
            b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            b:RegisterForDrag("LeftButton")
            b:SetScript("OnClick", function(self, button)
                if UI.cursorItem then UI.DropOnEquip(self.slot) return end
                if button == "RightButton" then Items.Unequip(self.slot) return end
                UI.PickupEquipped(self.slot)
            end)
            b:SetScript("OnDragStart", function(self) if not UI.cursorItem then UI.PickupEquipped(self.slot) end end)
            b:SetScript("OnReceiveDrag", function(self) if UI.cursorItem then UI.DropOnEquip(self.slot) end end)
            b:SetScript("OnEnter", function(self)
                local it = Craft.char.equip[self.slot]
                if it then K.ItemTooltip(self, it)
                else
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(Items.SLOT_NAMES[self.slot], 1, 1, 1)
                    GameTooltip:Show()
                end
            end)
            b:SetScript("OnLeave", K.HideTooltip)
        end
    end
    -- the model: drag to turn it, the two round buttons too (Model_OnLoad / Model_RotateLeft)
    local m = chaRefs.CharacterModelFrame
    if m then
        m.rot = 0
        local function turn(d)
            m.rot = (m.rot + d) % (2 * math.pi)
            if m.SetFacing then pcall(m.SetFacing, m, m.rot) end
        end
        local l, r = chaRefs.CharacterModelFrameRotateLeftButton, chaRefs.CharacterModelFrameRotateRightButton
        if r then r:SetScript("OnClick", function() turn(0.25) end) end
        if l then l:SetScript("OnClick", function() turn(-0.25) end) end
        m:EnableMouse(true)
        m:SetScript("OnMouseDown", function(self) self.dragX = GetCursorPosition() end)
        m:SetScript("OnMouseUp", function(self)
            self.dragX = nil
            if UI.cursorItem and UI.cursorItem.b then
                local it = D.items[UI.cursorItem.id]
                if it and it.inv then UI.DropOnEquip(nil) end
            end
        end)
        m:HookScript("OnUpdate", function(self)
            if self.dragX then
                local x = GetCursorPosition()
                turn((x - self.dragX) * 0.02)
                self.dragX = x
            end
        end)
    end
    cha.left, cha.right = "PLAYERSTAT_BASE_STATS", nil
    StatDropdown(chaRefs.PlayerStatFrameLeftDropdown, "left")
    StatDropdown(chaRefs.PlayerStatFrameRightDropdown, "right")
    return cha
end
UI.CharacterSheet = CharacterSheet

function UI.RefreshCharacter()
    local f = cha
    if not f or not f:IsShown() then return end
    local c, p = Craft.char, Craft.player
    chaRefs.CharacterNameText:SetText(c.name)
    chaRefs.CharacterLevelText:SetFormattedText("Level %d %s %s", c.level, "Human", Craft.CLASS_NAMES[c.class])
    K.HeroPortrait(chaRefs.CharacterFramePortrait, c.sex or 0)
    SetTabs(chaRefs, "CharacterFrameTab", 1, 1)
    for id, nm in ipairs(SLOT_BUTTON) do
        local bn = "Character" .. nm .. "Slot"
        local b = chaRefs[bn]
        if b then
            local item = c.equip[id]
            F.SetItemButton(chaRefs, bn, item)
            if not item then
                local icon = chaRefs[bn .. "IconTexture"] or b.icon
                if icon then icon:SetTexture("Interface\\PaperDoll\\UI-PaperDoll-Slot-" .. Items.SLOT_ART[id]) icon:Show() end
            end
        end
    end
    -- the model in this game's gear
    local m = chaRefs.CharacterModelFrame
    if m then
        local key, items = tostring(c.sex), {}
        for s = 1, 19 do
            key = key .. "," .. (c.equip[s] or 0)
            if c.equip[s] then items[#items + 1] = c.equip[s] end
        end
        if f.modelKey ~= key then
            f.modelKey = key
            K.DressModel(m, c.sex or 0, items)
        end
    end
    -- the stat boxes
    f.right = f.right or (p.powerType == Craft.POWER_MANA and "PLAYERSTAT_SPELL_COMBAT" or "PLAYERSTAT_MELEE_COMBAT")
    for side, prefix in pairs({ left = "PlayerStatFrameLeft", right = "PlayerStatFrameRight" }) do
        local lines = StatLines(f[side], p)
        for i = 1, 6 do
            local row = chaRefs[prefix .. i]
            local l = lines[i]
            if row then
                row:SetShown(l ~= nil)
                if l then
                    chaRefs[prefix .. i .. "Label"]:SetText(l[1])
                    chaRefs[prefix .. i .. "StatText"]:SetText(l[2])
                end
            end
        end
        local dd = chaRefs[prefix .. "Dropdown"]
        if dd then
            local name = UI.Str(f[side]) ~= f[side] and UI.Str(f[side]) or STAT_CAT_NAMES[f[side]]
            if dd.label then dd.label:SetText(name)
            elseif dd.GenerateMenu then pcall(dd.GenerateMenu, dd) end
        end
    end
    -- the resistances (MagicResFrame1-5: arcane, fire, nature, frost, shadow)
    local res = p.res or {}
    for i, school in ipairs({ 6, 2, 3, 4, 5 }) do          -- (Items.GearStats: holy, fire, nature, frost, shadow, arcane)
        local t = chaRefs["MagicResText" .. i]
        if t then t:SetText(res[school] or 0) end
    end
end

---------------------------------------------------------------------------
-- The quest log (QuestLogFrame, TBC): zone headers and quests in six rows (QuestLog_Update), the selected quest's
-- details on the parchment below (QuestLog_UpdateQuestDetails, QuestFrameItems_Update). Shift-click a quest to
-- track it or not; the light by "Track" shows which.
---------------------------------------------------------------------------

local QUESTS_DISPLAYED, QUEST_HEIGHT = 6, 16
local ql, qlRefs
local diffFonts = {}

-- a font object in a quest's difficulty colour (QuestDifficultyColors' fonts)
local function DiffFont(r, g, b)
    local k = string.format("%.2f%.2f%.2f", r, g, b)
    if diffFonts[k] == nil then
        local ok, fo = pcall(CreateFont, "DZCraftQuestDiff" .. k:gsub("%.", ""))
        if ok and fo then
            fo:SetFontObject(GameFontNormal)
            fo:SetTextColor(r, g, b)
            diffFonts[k] = fo
        else
            diffFonts[k] = false
        end
    end
    return diffFonts[k] or nil
end

local function QuestZone(id)
    local x = Craft.Quests.Extra(id)
    return x.zone or "Northshire Valley"
end

-- the log's lines: { header = zone } or { quest = log entry }, headers in the order their quests come
local function LogEntries()
    local log = Craft.Quests.Log()
    local zones, byZone = {}, {}
    for _, q in ipairs(log) do
        local z = QuestZone(q.id)
        if not byZone[z] then byZone[z] = {} zones[#zones + 1] = z end
        table.insert(byZone[z], q)
    end
    local out = {}
    for _, z in ipairs(zones) do
        out[#out + 1] = { header = z }
        if not ql.collapsed[z] then
            for _, q in ipairs(byZone[z]) do out[#out + 1] = { quest = q } end
        end
    end
    return out, #log
end

local function QuestLogWindow()
    if ql then return ql end
    ql, qlRefs = UI.Build("QuestLogFrame", UI.hudFrame)
    ql.collapsed, ql.offset = {}, 0
    CloseButtonOf(ql, qlRefs, "QuestLogFrame")
    qlRefs.QuestFrameExitButton:SetScript("OnClick", function() UI.CloseWindow(ql) end)
    qlRefs.QuestFramePushQuestButton:Disable()
    qlRefs.QuestLogFrameAbandonButton:SetScript("OnClick", function()
        local q = ql.selected and Craft.Quests.Get(ql.selected)
        if not q then return end
        local id = ql.selected
        UI.Popup("abandon", "Abandon \"" .. q.title .. "\"?",
            { UI.Str("ACCEPT"), function() Craft.Quests.Abandon(id) ql.selected = nil UI.RefreshQuestLog() end },
            { UI.Str("CANCEL"), function() end })
    end)
    if qlRefs.QuestLogTrackTracking then qlRefs.QuestLogTrackTracking:SetVertexColor(1, 0, 0) end
    if qlRefs.QuestLogTrack then
        qlRefs.QuestLogTrack:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(_G.QUEST_WATCH_TOOLTIP or "Shift-click a quest to track it.", nil, nil, nil, nil, 1)
            GameTooltip:Show()
        end)
        qlRefs.QuestLogTrack:SetScript("OnLeave", K.HideTooltip)
    end
    -- "All": collapse / expand every header (QuestLogCollapseAllButton_OnClick)
    qlRefs.QuestLogCollapseAllButton:SetScript("OnClick", function(self)
        local any = next(ql.collapsed) ~= nil
        ql.collapsed = {}
        if not any then
            for _, e in ipairs((LogEntries())) do if e.header then ql.collapsed[e.header] = true end end
        end
        UI.RefreshQuestLog()
    end)
    for i = 1, QUESTS_DISPLAYED do
        local b = qlRefs["QuestLogTitle" .. i]
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", function(self)
            local e = self.entry
            if not e then return end
            if e.header then
                ql.collapsed[e.header] = not ql.collapsed[e.header] or nil
            elseif IsShiftKeyDown and IsShiftKeyDown() then
                local c = Craft.char
                c.unwatch = c.unwatch or {}
                c.unwatch[e.quest.id] = not c.unwatch[e.quest.id] or nil
                ql.selected = e.quest.id
            else
                ql.selected = e.quest.id
                ql.scrollDetail = true
            end
            K.Play(K.SFX.click or 856)
            UI.RefreshQuestLog()
        end)
    end
    -- the list scrolls by the wheel (FauxScrollFrame)
    local list = qlRefs.QuestLogListScrollFrame
    ql:EnableMouseWheel(true)
    ql:SetScript("OnMouseWheel", function(_, d)
        local n = #(LogEntries())
        ql.offset = max(0, min(n - QUESTS_DISPLAYED, ql.offset - d))
        UI.RefreshQuestLog()
    end)
    WireScroll(qlRefs, "QuestLogDetailScrollFrame")
    return ql
end
UI.QuestLogWindow = QuestLogWindow

local function SetLastShown(child, w)
    local sp = qlRefs.QuestLogSpacerFrame
    if sp and w then
        sp:ClearAllPoints()
        sp:SetPoint("TOP", w, "BOTTOM", 0, 0)
        ql.lastShown = w
    end
end

-- QuestFrameItems_Update("QuestLog")
local function QuestLogRewards(id)
    local x = Craft.Quests.Extra(id)
    local choices, items, money = x.choice or {}, x.rew or {}, x.money or 0
    local R = qlRefs
    for i = 1, 10 do if R["QuestLogItem" .. i] then R["QuestLogItem" .. i]:Hide() end end
    if #choices + #items == 0 and money == 0 then
        R.QuestLogRewardTitleText:Hide()
        R.QuestLogItemChooseText:Hide()
        R.QuestLogItemReceiveText:Hide()
        if R.QuestLogMoneyFrame then R.QuestLogMoneyFrame:Hide() end
        return
    end
    R.QuestLogRewardTitleText:Show()
    R.QuestLogRewardTitleText:SetTextColor(TITLE_COLOR[1], TITLE_COLOR[2], TITLE_COLOR[3])
    SetLastShown(nil, R.QuestLogRewardTitleText)
    local function fill(index, id, n)
        local bn = "QuestLogItem" .. index
        local b = R[bn]
        F.SetItemButton(R, bn, id, n)
        local it = D.items[id]
        if R[bn .. "Name"] then R[bn .. "Name"]:SetText(it and it.n or "?") end
        local usable = not (it and it.inv and Items.INV_SLOTS[it.inv]) or Items.CanEquip(it, Craft.char)
        local icon = R[bn .. "IconTexture"]
        if icon then icon:SetVertexColor(1, usable and 1 or 0, usable and 1 or 0) end
        if R[bn .. "NameFrame"] then R[bn .. "NameFrame"]:SetVertexColor(1, usable and 1 or 0, usable and 1 or 0) end
        b:SetScript("OnEnter", function(self) K.ItemTooltip(self, id, "nosell") end)
        b:SetScript("OnLeave", K.HideTooltip)
        b:ClearAllPoints()
        b:Show()
        SetLastShown(nil, b)
        return b
    end
    local count = 0
    if #choices > 0 then
        local t = R.QuestLogItemChooseText
        t:SetText(UI.Str("REWARD_CHOICES"))
        t:SetTextColor(TEXT_COLOR[1], TEXT_COLOR[2], TEXT_COLOR[3])
        t:Show()
        SetLastShown(nil, t)
        for i, c in ipairs(choices) do
            count = count + 1
            local b = fill(count, c[1], c[2])
            if i > 1 then
                if i % 2 == 1 then b:SetPoint("TOPLEFT", R["QuestLogItem" .. (count - 2)], "BOTTOMLEFT", 0, -2)
                else b:SetPoint("TOPLEFT", R["QuestLogItem" .. (count - 1)], "TOPRIGHT", 1, 0) end
            else
                b:SetPoint("TOPLEFT", t, "BOTTOMLEFT", -3, -5)
            end
        end
    else
        R.QuestLogItemChooseText:Hide()
    end
    if #items > 0 or money > 0 then
        local t = R.QuestLogItemReceiveText
        t:SetTextColor(TEXT_COLOR[1], TEXT_COLOR[2], TEXT_COLOR[3])
        t:ClearAllPoints()
        if #choices > 0 then
            t:SetText(UI.Str("REWARD_ITEMS"))
            local index = #choices
            if index % 2 == 0 then index = index - 1 end
            t:SetPoint("TOPLEFT", R["QuestLogItem" .. index], "BOTTOMLEFT", 3, -5)
        else
            t:SetText(UI.Str("REWARD_ITEMS_ONLY"))
            t:SetPoint("TOPLEFT", R.QuestLogRewardTitleText, "BOTTOMLEFT", 3, -5)
        end
        t:Show()
        SetLastShown(nil, t)
        if money > 0 and R.QuestLogMoneyFrame then
            F.Money(R, "QuestLogMoneyFrame", money)
            R.QuestLogMoneyFrame:Show()
            SetLastShown(nil, R.QuestLogMoneyFrame)
        elseif R.QuestLogMoneyFrame then
            R.QuestLogMoneyFrame:Hide()
        end
        local base = count
        for i, r in ipairs(items) do
            count = count + 1
            local b = fill(count, r[1], r[2])
            if i > 1 then
                if i % 2 == 1 then b:SetPoint("TOPLEFT", R["QuestLogItem" .. (count - 2)], "BOTTOMLEFT", 0, -2)
                else b:SetPoint("TOPLEFT", R["QuestLogItem" .. (count - 1)], "TOPRIGHT", 1, 0) end
            else
                b:SetPoint("TOPLEFT", t, "BOTTOMLEFT", -3, -5)
            end
        end
        if base == count and money > 0 then SetLastShown(nil, R.QuestLogMoneyFrame) end
    else
        R.QuestLogItemReceiveText:Hide()
        if R.QuestLogMoneyFrame then R.QuestLogMoneyFrame:Hide() end
    end
end

-- QuestLog_UpdateQuestDetails
local function QuestLogDetails(id)
    local R = qlRefs
    local q = Craft.Quests.Get(id)
    R.QuestLogQuestTitle:SetText(q.title)
    R.QuestLogQuestTitle:SetTextColor(TITLE_COLOR[1], TITLE_COLOR[2], TITLE_COLOR[3])
    R.QuestLogObjectivesText:SetText(Craft.Quests.Text(q.goal))
    R.QuestLogObjectivesText:SetTextColor(TEXT_COLOR[1], TEXT_COLOR[2], TEXT_COLOR[3])
    SetLastShown(nil, R.QuestLogObjectivesText)
    R.QuestLogTimerText:Hide()
    R.QuestLogObjective1:SetPoint("TOPLEFT", R.QuestLogObjectivesText, "BOTTOMLEFT", 0, -10)
    local lines = Craft.Quests.Progress(id)
    for i, l in ipairs(lines) do
        local fs = R["QuestLogObjective" .. i]
        if fs then
            if l.done then fs:SetTextColor(0.2, 0.2, 0.2) fs:SetText(l.text .. " (" .. UI.Str("COMPLETE") .. ")")
            else fs:SetTextColor(0, 0, 0) fs:SetText(l.text) end
            fs:Show()
            SetLastShown(nil, fs)
        end
    end
    for i = #lines + 1, 10 do if R["QuestLogObjective" .. i] then R["QuestLogObjective" .. i]:Hide() end end
    R.QuestLogRequiredMoneyText:Hide()
    if R.QuestLogRequiredMoneyFrame then R.QuestLogRequiredMoneyFrame:Hide() end
    R.QuestLogSuggestedGroupNum:Hide()
    R.QuestLogDescriptionTitle:ClearAllPoints()
    R.QuestLogDescriptionTitle:SetPoint("TOPLEFT", #lines > 0 and R["QuestLogObjective" .. #lines] or R.QuestLogObjectivesText,
        "BOTTOMLEFT", 0, -10)
    R.QuestLogDescriptionTitle:SetTextColor(TITLE_COLOR[1], TITLE_COLOR[2], TITLE_COLOR[3])
    R.QuestLogQuestDescription:SetText(Craft.Quests.Text(q.text))
    R.QuestLogQuestDescription:SetTextColor(TEXT_COLOR[1], TEXT_COLOR[2], TEXT_COLOR[3])
    SetLastShown(nil, R.QuestLogQuestDescription)
    for _, k in ipairs({ "QuestLogSpellLearnText", "QuestLogHonorFrame", "QuestLogPlayerTitleFrame" }) do
        if R[k] then R[k]:Hide() end
    end
    QuestLogRewards(id)
    -- the scroll child as tall as what is in it (UpdateScrollChildRect)
    local child, sp = R.QuestLogDetailScrollChildFrame, R.QuestLogSpacerFrame
    local top, bottom = child and child:GetTop(), sp and sp:GetBottom()
    if child then child:SetHeight((top and bottom and top > bottom) and (top - bottom) or 400) end
    if ql.scrollDetail then
        ql.scrollDetail = nil
        local sf = R.QuestLogDetailScrollFrame
        if sf and sf.SetTo then sf.SetTo(0) elseif sf then sf:SetVerticalScroll(0) end
    end
end

function UI.RefreshQuestLog()
    local f = ql
    if not f or not f:IsShown() then return end
    local R = qlRefs
    local entries, numQuests = LogEntries()
    local has = #entries > 0
    R.EmptyQuestLogFrame:SetShown(not has)
    R.QuestLogDetailScrollFrame:SetShown(has)
    R.QuestLogExpandButtonFrame:SetShown(has)
    if has then R.QuestLogFrameAbandonButton:Enable() else R.QuestLogFrameAbandonButton:Disable() end
    R.QuestLogQuestCount:SetFormattedText(UI.Str("QUEST_LOG_COUNT_TEMPLATE"), numQuests, Craft.Quests.MAX_LOG)
    -- the list (FauxScrollFrame_Update: the bar only when it does not all fit; rows 293 wide with it, 316 without)
    f.offset = max(0, min(f.offset, #entries - QUESTS_DISPLAYED))
    local scrolls = #entries > QUESTS_DISPLAYED
    R.QuestLogListScrollFrame:SetShown(scrolls)
    local rowW = scrolls and 293 or 316
    R.QuestLogHighlightFrame:SetWidth(rowW)
    -- the selection: still in the log, else the first quest
    local selOk = false
    for _, e in ipairs(entries) do if e.quest and e.quest.id == f.selected then selOk = true end end
    if not selOk then
        f.selected = nil
        for _, q in ipairs(Craft.Quests.Log()) do f.selected = q.id break end
    end
    R.QuestLogHighlightFrame:Hide()
    local unwatch = Craft.char.unwatch or {}
    for i = 1, QUESTS_DISPLAYED do
        local b = R["QuestLogTitle" .. i]
        local e = entries[i + f.offset]
        b.entry = e
        b:SetWidth(rowW)
        local tag, check = R["QuestLogTitle" .. i .. "Tag"], R["QuestLogTitle" .. i .. "Check"]
        local text, hl = R["QuestLogTitle" .. i .. "NormalText"], R["QuestLogTitle" .. i .. "Highlight"]
        R["QuestLogTitle" .. i .. "GroupMates"]:SetText("")
        if e then
            local r, g, bl
            if e.header then
                b:SetText(e.header)
                b:SetNormalTexture(f.collapsed[e.header] and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
                local nt = b:GetNormalTexture()
                if nt then nt:SetAlpha(1) end
                if hl then hl:SetTexture("Interface\\Buttons\\UI-PlusButton-Hilight") end
                tag:SetText("")
                check:Hide()
                r, g, bl = 0.7, 0.7, 0.7                -- (QuestDifficultyColors.header)
            else
                local q = e.quest
                b:SetText("  " .. q.title)
                if b.ClearNormalTexture then b:ClearNormalTexture() end
                local nt = b:GetNormalTexture()
                if nt then nt:SetAlpha(0) end
                if hl then hl:SetTexture("") end
                r, g, bl = Craft.Quests.Color(q.level, Craft.char.level)
                tag:SetText(q.done and ("(" .. UI.Str("COMPLETE") .. ")") or "")
                text:SetWidth(0)
                local tw = text:GetStringWidth() or 0
                local maxW = 275 - 15 - (q.done and (tag:GetStringWidth() or 0) or 0)
                if tw > maxW then text:SetWidth(maxW) tw = maxW end
                check:ClearAllPoints()
                check:SetPoint("LEFT", b, "LEFT", tw + 24, 0)
                check:SetShown(not unwatch[q.id])
            end
            local fo = DiffFont(r, g, bl)
            if fo then b:SetNormalFontObject(fo) elseif text then text:SetTextColor(r, g, bl) end
            tag:SetTextColor(r, g, bl)
            b:Show()
            if e.quest and e.quest.id == f.selected then
                R.QuestLogSkillHighlight:SetVertexColor(r, g, bl)
                R.QuestLogHighlightFrame:ClearAllPoints()
                R.QuestLogHighlightFrame:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
                R.QuestLogHighlightFrame:Show()
                tag:SetTextColor(1, 1, 1)
                b:LockHighlight()
            else
                b:UnlockHighlight()
            end
        else
            b:Hide()
        end
    end
    R.QuestLogCollapseAllButton:SetNormalTexture(next(f.collapsed) and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    if R.QuestLogTrackTracking then
        local w = f.selected and not unwatch[f.selected]
        R.QuestLogTrackTracking:SetVertexColor(w and 0 or 1, w and 1 or 0, 0)
    end
    if f.selected then QuestLogDetails(f.selected) end
end

---------------------------------------------------------------------------
-- The class trainer (Blizzard_TrainerUI, classic): the spells under their skill lines (Fire, Frost, Arms ...) in
-- eleven rows, green to learn, red not yet, grey known (hidden by the filter, like WoW's default); the chosen
-- one's icon, requirements, cost and text below (ClassTrainerFrame_Update, ClassTrainer_SetSelection).
---------------------------------------------------------------------------

local SKILLS_DISPLAYED = 11
local tr, trRefs
local TRAIN_COLOR = { available = { 0.25, 0.75, 0.25 }, unavailable = { 0.9, 0, 0 }, used = { 0.5, 0.5, 0.5 } }
local TRAIN_SUB = { available = { 0, 0.6, 0 }, unavailable = { 0.6, 0, 0 }, used = { 0.5, 0.5, 0.5 } }
local trainFonts = {}

local function TrainFont(state)
    if trainFonts[state] == nil then
        local c = TRAIN_COLOR[state]
        local ok, fo = pcall(CreateFont, "DZCraftTrain" .. state)
        if ok and fo then fo:SetFontObject(GameFontNormalLeft or GameFontNormal) fo:SetTextColor(c[1], c[2], c[3]) end
        trainFonts[state] = ok and fo or false
    end
    return trainFonts[state] or nil
end

-- the services: { header = line } and { e = TrainerList entry } in skill-line order, filtered
local function TrainerEntries(f)
    local lines, by = {}, {}
    for _, e in ipairs(Craft.Npc.TrainerList(f.npc)) do
        if f.filter[e.state] then
            local sp = D.spells[e.spell]
            local line = sp.line or Craft.CLASS_NAMES[Craft.char.class]
            if not by[line] then by[line] = {} lines[#lines + 1] = line end
            table.insert(by[line], e)
        end
    end
    table.sort(lines)
    local out = {}
    for _, line in ipairs(lines) do
        out[#out + 1] = { header = line }
        if not f.collapsed[line] then
            table.sort(by[line], function(a, b)
                if a.level ~= b.level then return a.level < b.level end
                return D.spells[a.spell].n < D.spells[b.spell].n
            end)
            for _, e in ipairs(by[line]) do out[#out + 1] = { e = e } end
        end
    end
    return out
end

local function TrainerWindow()
    if tr then return tr end
    tr, trRefs = UI.Build("ClassTrainerFrame", UI.hudFrame)
    tr.filter = { available = true, unavailable = true, used = false }
    tr.collapsed, tr.offset = {}, 0
    -- ClassTrainer_SetToClassTrainer: eleven rows, the details below the bar
    trRefs.ClassTrainerListScrollFrame:SetHeight(184)
    trRefs.ClassTrainerDetailScrollFrame:SetHeight(119)
    trRefs.ClassTrainerHorizontalBarLeft:ClearAllPoints()
    trRefs.ClassTrainerHorizontalBarLeft:SetPoint("TOPLEFT", tr, "TOPLEFT", 15, -275)
    WireScroll(trRefs, "ClassTrainerDetailScrollFrame")
    CloseButtonOf(tr, trRefs, "ClassTrainerFrame")
    trRefs.ClassTrainerCancelButton:SetScript("OnClick", function() UI.CloseWindow(tr) end)
    tr.onClose = function() tr.npc = nil end
    trRefs.ClassTrainerTrainButton:SetScript("OnClick", function()
        local e = tr.selected
        if e and e.state == "available" and Craft.Npc.Learn(e.spell, e.cost) then
            K.Play(K.SFX.quest)
            tr.selected = nil                         -- (the next one to learn is picked)
        end
        UI.RefreshTrainer()
    end)
    trRefs.ClassTrainerCollapseAllButton:SetScript("OnClick", function()
        local any = next(tr.collapsed) ~= nil
        tr.collapsed = {}
        if not any then
            for _, x in ipairs(TrainerEntries(tr)) do if x.header then tr.collapsed[x.header] = true end end
        end
        UI.RefreshTrainer()
    end)
    for i = 1, SKILLS_DISPLAYED do
        trRefs["ClassTrainerSkill" .. i]:SetScript("OnClick", function(self)
            local x = self.entry
            if not x then return end
            if x.header then tr.collapsed[x.header] = not tr.collapsed[x.header] or nil
            else tr.selected = x.e end
            UI.RefreshTrainer()
        end)
    end
    trRefs.ClassTrainerSkillIcon:SetScript("OnEnter", function(self)
        if tr.selected then K.SpellTooltip(self, tr.selected.spell) end
    end)
    trRefs.ClassTrainerSkillIcon:SetScript("OnLeave", K.HideTooltip)
    -- the filter (Available / Unavailable / Used), Blizzard's dropdown where the client has it
    local dd = tr.FilterDropdown
    if dd and dd.SetupMenu then
        if dd.SetSelectionText then dd:SetSelectionText(function() return _G.FILTER or "Filter" end) end
        dd:SetupMenu(function(_, root)
            for _, s in ipairs({ { "available", "|cff20ff20" .. (_G.AVAILABLE or "Available") .. "|r" },
                                 { "unavailable", "|cffff2020" .. (_G.UNAVAILABLE or "Unavailable") .. "|r" },
                                 { "used", "|cff808080" .. (_G.USED or "Used") .. "|r" } }) do
                root:CreateCheckbox(s[2], function() return tr.filter[s[1]] end,
                    function() tr.filter[s[1]] = not tr.filter[s[1]] UI.RefreshTrainer() end, s[1])
            end
        end)
    elseif dd then
        dd:Hide()
    end
    tr:EnableMouseWheel(true)
    tr:SetScript("OnMouseWheel", function(_, d)
        tr.offset = max(0, min(#TrainerEntries(tr) - SKILLS_DISPLAYED, tr.offset - d))
        UI.RefreshTrainer()
    end)
    return tr
end

function UI.OpenTrainer(u)
    local f = TrainerWindow()
    f.npc, f.selected, f.offset = u, nil, 0
    trRefs.ClassTrainerNameText:SetText(u.name)
    NpcPortrait(trRefs.ClassTrainerFramePortrait, u)
    if UI.open.quest then UI.CloseWindow(UI.open.quest) end
    if UI.open.gossip then UI.CloseWindow(UI.open.gossip) end
    UI.ShowWindow("trainer", f)
    K.Play(K.SFX.book, 0.1)
    UI.RefreshTrainer()
end

-- ClassTrainer_SetSelection: the chosen spell's details
local function TrainerDetails(e)
    local R = trRefs
    local show = e ~= nil
    for _, k in ipairs({ "ClassTrainerSkillName", "ClassTrainerSubSkillName", "ClassTrainerSkillIcon",
                         "ClassTrainerSkillRequirements", "ClassTrainerSkillDescription", "ClassTrainerDetailMoneyFrame",
                         "ClassTrainerCostLabel" }) do
        if R[k] then R[k]:SetShown(show) end
    end
    R.ClassTrainerSkillHighlightFrame:SetShown(show)
    if not e then R.ClassTrainerTrainButton:Disable() return end
    local sp = D.spells[e.spell]
    local c = TRAIN_COLOR[e.state]
    R.ClassTrainerSkillHighlight:SetVertexColor(e.state == "available" and 0 or c[1], e.state == "available" and 1 or c[2],
        e.state == "available" and 0 or c[3])
    R.ClassTrainerSkillName:SetText(sp.n)
    R.ClassTrainerSubSkillName:SetText(sp.r and ("(" .. sp.r .. ")") or "")
    R.ClassTrainerSkillIcon:SetNormalTexture(Combat.SpellIcon(e.spell))
    -- Requires: Level 4, Fireball (Rank 1) - red when not met
    local reqs, c0 = {}, Craft.char
    if e.level > 1 then
        reqs[#reqs + 1] = (c0.level >= e.level and "" or "|cffff2020") .. string.format("Level %d", e.level) .. (c0.level >= e.level and "" or "|r")
    end
    if sp.prev and D.spells[sp.prev] then
        local p = D.spells[sp.prev]
        local s = p.n .. (p.r and (" (" .. p.r .. ")") or "")
        reqs[#reqs + 1] = c0.spells[sp.prev] and s or ("|cffff2020" .. s .. "|r")
    end
    R.ClassTrainerSkillRequirements:SetText(#reqs > 0 and ((_G.REQUIRES_LABEL or "Requires:") .. " " .. table.concat(reqs, ", ")) or "")
    local unaffordable = Craft:Money() < e.cost
    if e.cost > 0 then
        R.ClassTrainerCostLabel:Show()
        R.ClassTrainerDetailMoneyFrame:Show()
        F.Money(R, "ClassTrainerDetailMoneyFrame", e.cost, unaffordable)
        R.ClassTrainerSkillDescription:SetPoint("TOPLEFT", R.ClassTrainerCostLabel, "BOTTOMLEFT", 0, -10)
    else
        R.ClassTrainerCostLabel:Hide()
        R.ClassTrainerDetailMoneyFrame:Hide()
        R.ClassTrainerSkillDescription:SetPoint("TOPLEFT", R.ClassTrainerCostLabel, "TOPLEFT", 0, 0)
    end
    R.ClassTrainerSkillDescription:SetText(Combat.SpellText(e.spell, Craft.player))
    R.ClassTrainerTrainButton:SetEnabled(e.state == "available" and not unaffordable)
end

function UI.RefreshTrainer()
    local f = tr
    if not f or not f:IsShown() or not f.npc then return end
    local R = trRefs
    local g = Craft.Npc.Gossip(f.npc)
    R.ClassTrainerGreetingText:SetText(g.text or "")
    local entries = TrainerEntries(f)
    -- the selection: still listed, else the first one to learn (ClassTrainer_SelectFirstLearnableSkill)
    local sel
    for _, x in ipairs(entries) do if x.e and f.selected and x.e.spell == f.selected.spell then sel = x.e end end
    if not sel then
        for _, x in ipairs(entries) do if x.e and x.e.state == "available" then sel = x.e break end end
        if not sel then for _, x in ipairs(entries) do if x.e then sel = x.e break end end end
    end
    f.selected = sel
    f.offset = max(0, min(f.offset, #entries - SKILLS_DISPLAYED))
    local scrolls = #entries > SKILLS_DISPLAYED
    R.ClassTrainerListScrollFrame:SetShown(scrolls)
    R.ClassTrainerSkillHighlightFrame:Hide()
    if #entries > 0 then R.ClassTrainerCollapseAllButton:Enable() else R.ClassTrainerCollapseAllButton:Disable() end
    for i = 1, SKILLS_DISPLAYED do
        local b = R["ClassTrainerSkill" .. i]
        local x = entries[i + f.offset]
        b.entry = x
        local text, sub, hl = R["ClassTrainerSkill" .. i .. "Text"], R["ClassTrainerSkill" .. i .. "SubText"],
                              R["ClassTrainerSkill" .. i .. "Highlight"]
        if x then
            b:SetWidth(scrolls and 293 or 323)
            if x.header then
                text:SetText(x.header)
                text:SetWidth(0)
                b:SetNormalFontObject(GameFontNormal)
                sub:Hide()
                b:SetNormalTexture(f.collapsed[x.header] and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
                local nt = b:GetNormalTexture()
                if nt then nt:SetAlpha(1) end
                if hl then hl:SetTexture("Interface\\Buttons\\UI-PlusButton-Hilight") end
                b:UnlockHighlight()
            else
                local e = x.e
                local sp = D.spells[e.spell]
                if b.ClearNormalTexture then b:ClearNormalTexture() end
                local nt = b:GetNormalTexture()
                if nt then nt:SetAlpha(0) end
                if hl then hl:SetTexture("") end
                text:SetText("  " .. sp.n)
                if sp.r then
                    sub:SetText("(" .. sp.r .. ")")
                    sub:ClearAllPoints()
                    sub:SetPoint("LEFT", text, "RIGHT", 10, 0)
                    sub:Show()
                    text:SetWidth(0)
                else
                    sub:Hide()
                    text:SetWidth(270)
                end
                local fo = TrainFont(e.state)
                if fo then b:SetNormalFontObject(fo) end
                if e ~= sel then text:SetTextColor(unpack(TRAIN_COLOR[e.state])) end
                local sc = TRAIN_SUB[e.state]
                sub:SetTextColor(sc[1], sc[2], sc[3])
                if e == sel then
                    R.ClassTrainerSkillHighlightFrame:ClearAllPoints()
                    R.ClassTrainerSkillHighlightFrame:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
                    R.ClassTrainerSkillHighlightFrame:Show()
                    b:LockHighlight()
                    sub:SetTextColor(1, 1, 1)
                else
                    b:UnlockHighlight()
                end
            end
            b:Show()
        else
            b:Hide()
        end
    end
    R.ClassTrainerCollapseAllButton:SetNormalTexture(next(f.collapsed) and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    TrainerDetails(sel)
    F.Money(R, "ClassTrainerMoneyFrame", Craft:Money())
end

---------------------------------------------------------------------------
-- The spellbook (SpellBookFrame, the classic book TBC uses): twelve spells a page - the left column first, then
-- the right (SpellButton ids 1-6, 7-12) - the skill-line tabs down the right edge (General, Arcane, Fire ...),
-- pages, "Show all spell ranks" (SpellButton_UpdateButton, SpellBookFrame_UpdateSkillLineTabs)
---------------------------------------------------------------------------

local SPELLS_PER_PAGE = 12
local sb, sbRefs
local PASSIVE_COLOR, NORMAL_COLOR = { 0.77, 0.64, 0 }, { 1, 0.82, 0 }

local function SpellBookWindow()
    if sb then return sb end
    sb, sbRefs = UI.Build("SpellBookFrame", UI.hudFrame)
    sb.tab, sb.pages, sb.allRanks = 2, {}, false
    CloseButtonOf(sb, sbRefs, "SpellBook")
    sbRefs.SpellBookTitleText:SetText(UI.Str("SPELLBOOK"))
    -- one book (no pet): the bottom tab says Spellbook, the others hide
    local t1 = sbRefs.SpellBookFrameTabButton1
    if t1 then
        t1:SetText(UI.Str("SPELLBOOK"))
        t1:Show()
        t1:Disable()
    end
    for i = 2, 3 do if sbRefs["SpellBookFrameTabButton" .. i] then sbRefs["SpellBookFrameTabButton" .. i]:Hide() end end
    sbRefs.SpellBookPrevPageButton:SetScript("OnClick", function()
        sb.pages[sb.tab] = max(1, (sb.pages[sb.tab] or 1) - 1)
        K.Play(K.SFX.page or 836)
        UI.RefreshSpellbook()
    end)
    sbRefs.SpellBookNextPageButton:SetScript("OnClick", function()
        sb.pages[sb.tab] = (sb.pages[sb.tab] or 1) + 1
        K.Play(K.SFX.page or 836)
        UI.RefreshSpellbook()
    end)
    local cb = sbRefs.ShowAllSpellRanksCheckbox
    if cb then
        if cb.Text then cb.Text:SetText(_G.SHOW_ALL_SPELL_RANKS or "Show all spell ranks") end
        cb:SetScript("OnClick", function(self) sb.allRanks = self:GetChecked() and true or false UI.RefreshSpellbook() end)
    end
    for i = 1, 8 do
        local t = sbRefs["SpellBookSkillLineTab" .. i]
        if t then
            t:SetScript("OnClick", function()
                sb.tab = i
                K.Play(K.SFX.page or 836)
                UI.RefreshSpellbook()
            end)
            t:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.tooltip or "", 1, 1, 1)
                GameTooltip:Show()
            end)
            t:SetScript("OnLeave", K.HideTooltip)
        end
    end
    for i = 1, SPELLS_PER_PAGE do
        local b = sbRefs["SpellButton" .. i]
        b:RegisterForDrag("LeftButton")
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local function pickup(self)
            if self.spell and not Combat.IsPassive(D.spells[self.spell]) then UI.PickupAction("spell", self.spell) end
        end
        b:SetScript("OnDragStart", pickup)
        b:SetScript("OnClick", function(self)
            self:SetChecked(false)
            if not self.spell then return end
            if (IsShiftKeyDown and IsShiftKeyDown()) or UI.cursorAction then pickup(self) return end
            if self.spell == 6603 then Combat.StartAttack(Craft.player) return end
            if not Combat.IsPassive(D.spells[self.spell]) then Combat.CastSpell(Craft.player, self.spell) end
        end)
        b:SetScript("OnEnter", function(self) if self.spell then K.SpellTooltip(self, self.spell) end end)
        b:SetScript("OnLeave", K.HideTooltip)
    end
    return sb
end
UI.SpellBookWindow = SpellBookWindow

function UI.RefreshSpellbook()
    local f = sb
    if not f or not f:IsShown() then return end
    local R = sbRefs
    local cls = Craft.char.class
    if R.ShowAllSpellRanksCheckbox then
        -- (warriors and rogues have no ranks to show, like WoW)
        R.ShowAllSpellRanksCheckbox:SetShown(cls ~= 1 and cls ~= 4)
        R.ShowAllSpellRanksCheckbox:SetChecked(f.allRanks)
    end
    local tabs = Craft.Npc.Spellbook(f.allRanks)
    if not tabs[f.tab] then f.tab = 1 end
    for i = 1, 8 do
        local t = R["SpellBookSkillLineTab" .. i]
        local tab = tabs[i]
        if t then
            if tab then
                local icon = tab.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
                t:SetNormalTexture(icon)
                t.tooltip = tab.name
                t:SetChecked(f.tab == i)
                t:Show()
            else
                t:Hide()
            end
            if R["SpellBookSkillLineTab" .. i .. "Flash"] then R["SpellBookSkillLineTab" .. i .. "Flash"]:Hide() end
        end
    end
    local list = tabs[f.tab].list
    local maxPages = max(1, ceil(#list / SPELLS_PER_PAGE))
    local page = min(f.pages[f.tab] or 1, maxPages)
    f.pages[f.tab] = page
    R.SpellBookPrevPageButton:SetEnabled(page > 1)
    R.SpellBookNextPageButton:SetEnabled(page < maxPages)
    R.SpellBookPageText:SetFormattedText(UI.Str("PAGE_NUMBER"), page)
    for i = 1, SPELLS_PER_PAGE do
        local b = R["SpellButton" .. i]
        local n = "SpellButton" .. i
        local id = list[(b:GetID() or i) + SPELLS_PER_PAGE * (page - 1)]
        b.spell = id
        local icon, name, sub = R[n .. "IconTexture"], R[n .. "SpellName"], R[n .. "SubSpellName"]
        local nt, hl, cd = R[n .. "NormalTexture"], R[n .. "Highlight"], R[n .. "Cooldown"]
        if R[n .. "AutoCastOverlay"] then R[n .. "AutoCastOverlay"]:Hide() end
        b:SetChecked(false)
        if not id then
            icon:Hide() name:Hide() sub:Hide()
            if cd then cd:Hide() end
            if hl then hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square") end
            if nt then nt:SetVertexColor(1, 1, 1) end
            b:Disable()
        else
            b:Enable()
            local sp = D.spells[id]
            local passive = Combat.IsPassive(sp)
            icon:SetTexture(Combat.SpellIcon(id))
            name:SetText(sp.n)
            local subText = sp.r or (passive and (_G.SPELL_PASSIVE or "Passive")) or ""
            sub:SetText(subText)
            name:ClearAllPoints()
            name:SetPoint("LEFT", b, "RIGHT", 5, subText == "" and 1 or 3)
            icon:Show() name:Show() sub:Show()
            local col = passive and PASSIVE_COLOR or NORMAL_COLOR
            name:SetTextColor(col[1], col[2], col[3])
            if nt then if passive then nt:SetVertexColor(0, 0, 0) else nt:SetVertexColor(1, 1, 1) end end
            if hl then hl:SetTexture(passive and "Interface\\Buttons\\UI-PassiveHighlight" or "Interface\\Buttons\\ButtonHilight-Square") end
            if cd then
                local left, total = Combat.CooldownLeft(Craft.player, id)
                if left and left > 0 and total then cd:SetCooldown(GetTime() - (total - left), total) cd:Show()
                else cd:Hide() end
            end
        end
    end
end

-- the events that redraw these windows
Craft:On("money", function() UI.RefreshMerchant() end)
