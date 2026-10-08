if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIWindows.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIWindows.lua
-- CraftUI's windows, on WoW's own 384 x 512 panel art: the gossip and quest frames (greeting, details, progress,
-- reward choice), the merchant, the class trainer, the spellbook, the character sheet (your WoW character's model
-- dressed in what you wear here), the quest log, the bags, the loot window, the game menu. Items and spells move on
-- the cursor like in WoW: click to pick up, click to put down; drop an item on the world to destroy it.
local addonName, ns = ...

local UI = ns.CraftUI
local K = UI.Kit
local Craft = ns.Craft
local D = Craft.D
local Combat = Craft.Combat
local Items = Craft.Items

local floor, max, min = math.floor, math.max, math.min
local Wn = {}
UI.Windows = Wn

---------------------------------------------------------------------------
-- Panels on WoW's art
---------------------------------------------------------------------------

-- a 384 x 512 panel from four art pieces (base .. "-TopLeft" ...); bot = "Bot" | "Bottom"
local function Panel(parent, base, bot, title)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(384, 512)
    f:EnableMouse(true)
    f:SetFrameStrata("HIGH")
    local function piece(name, w, h, x, y)
        local t = K.Tex(f, "BORDER", base .. "-" .. name)
        t:SetSize(w, h)
        t:SetPoint("TOPLEFT", x, y)
        return t
    end
    bot = bot or "Bot"
    piece("TopLeft", 256, 256, 0, 0)
    piece("TopRight", 128, 256, 256, 0)
    piece(bot .. "Left", 256, 256, 0, -256)
    piece(bot .. "Right", 128, 256, 256, -256)
    f.portrait = K.Tex(f, "BACKGROUND")
    f.portrait:SetSize(60, 60)
    f.portrait:SetPoint("TOPLEFT", 7, -6)
    f.title = K.Text(f, "GameFontNormal", "OVERLAY", "CENTER")
    f.title:SetPoint("TOP", 0, -17)
    f.title:SetText(title or "")
    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", -29, -8)
    f.close:SetScript("OnClick", function() UI.CloseWindow(f) end)
    f:Hide()
    return f
end
Wn.Panel = Panel

UI.open = {}                     -- name -> frame (the windows on screen)
local LEFT_SLOTS = {}            -- (WoW's UIPanel layout: windows open at the left, side by side)

function UI.ShowWindow(name, f, side)
    if not f then return end
    UI.SetLevelTree(f, UI.hudFrame:GetFrameLevel() + 60)       -- (over the chat box and the bars)
    UI.open[name] = f
    f:ClearAllPoints()
    if side == "right" then f:SetPoint("TOPRIGHT", UI.hudFrame, "TOPRIGHT", -8, -90)
    elseif side == "free" then
    else
        -- the left-most free panel slot
        local x = 0
        for n, g in pairs(UI.open) do
            if g ~= f and g:IsShown() and g.panelSlot then x = max(x, g.panelSlot + 1) end
        end
        if x > 1 then x = 1 end
        f.panelSlot = x
        f:SetPoint("TOPLEFT", UI.hudFrame, "TOPLEFT", 0 + x * 352, -104)
    end
    f:Show()
end

function UI.CloseWindow(f)
    for n, g in pairs(UI.open) do
        if g == f then
            UI.open[n] = nil
            if f.onClose then f.onClose() end
        end
    end
    f:Hide()
    f.panelSlot = nil
    K.Play(K.SFX.close, 0.1)
end

function UI.CloseAll()
    local any = false
    for n, f in pairs(UI.open) do
        if f:IsShown() then any = true end
        UI.CloseWindow(f)
    end
    return any
end

function UI.MouseOverWindow()
    for _, f in pairs(UI.open) do if f:IsShown() and f:IsMouseOver() then return true end end
    if UI.Hud and UI.Hud.bar and UI.Hud.bar:IsMouseOver() then return true end
    return false
end

---------------------------------------------------------------------------
-- The cursor: an item or an action held by the mouse
---------------------------------------------------------------------------

function UI.BuildCursor(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(30, 30)
    c:SetFrameStrata("TOOLTIP")
    c.icon = K.Tex(c, "OVERLAY")
    c.icon:SetAllPoints()
    c:Hide()
    c:EnableMouse(false)
    UI.cursorFrame = c
    c:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local s = self:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / s + 6, y / s - 6)
    end)
end

function UI.PickupBagItem(b, s)
    local x = Items.Get(b, s)
    if not x then return end
    UI.ClearCursorItem()
    UI.cursorItem = { b = b, s = s, id = x.id }
    UI.cursorFrame.icon:SetTexture(Items.Icon(x.id))
    UI.cursorFrame:Show()
    K.Play(K.SFX.loot, 0.05)
end

function UI.PickupEquipped(slot)
    local id = Craft.char.equip[slot]
    if not id then return end
    UI.ClearCursorItem()
    UI.cursorItem = { slot = slot, id = id }
    UI.cursorFrame.icon:SetTexture(Items.Icon(id))
    UI.cursorFrame:Show()
end

function UI.PickupAction(kind, id)
    UI.ClearCursorItem()
    UI.cursorAction = { kind, id }
    UI.cursorFrame.icon:SetTexture(kind == "spell" and Combat.SpellIcon(id) or Items.Icon(id))
    UI.cursorFrame:Show()
end

function UI.ClearCursorItem()
    UI.cursorItem, UI.cursorAction = nil, nil
    if UI.cursorFrame then UI.cursorFrame:Hide() end
end

-- the held item dropped on bag slot (b, s)
function UI.DropOnBag(b, s)
    local h = UI.cursorItem
    if not h then return false end
    UI.ClearCursorItem()
    if h.slot then return Items.Unequip(h.slot, b, s) end
    return Items.Move(h.b, h.s, b, s)
end

function UI.DropOnBagSlot(bagSlot)
    local h = UI.cursorItem
    if not h or not h.b then UI.ClearCursorItem() return end
    UI.ClearCursorItem()
    local it = D.items[h.id]
    if it and it.slots then Items.EquipBag(h.b, h.s, bagSlot) return end
    -- an item onto a bag: into that bag's first free slot
    local bag = Craft.char.bags[bagSlot]
    if bag and bag.item then
        for s = 1, bag.size do if not bag[s] then Items.Move(h.b, h.s, bagSlot, s) return end end
        Craft:Error("That bag is full.")
    end
end

function UI.DropOnEquip(slot)
    local h = UI.cursorItem
    if not h then return false end
    UI.ClearCursorItem()
    if h.b then return Items.EquipFromBag(h.b, h.s, slot) end
    return false
end

-- an item dropped on the world: WoW asks before destroying it
function UI.DropOnWorld()
    local h = UI.cursorItem
    if UI.cursorAction then UI.ClearCursorItem() return true end
    if not h then return false end
    UI.ClearCursorItem()
    local it = D.items[h.id]
    UI.Popup("destroy", "Do you want to destroy " .. Items.Link(h.id) .. "?",
        { "Yes", function()
            if h.b then Items.Destroy(h.b, h.s)
            elseif h.slot then Craft.char.equip[h.slot] = nil Items.AfterGearChange() end
        end }, { "No", function() end })
    return true
end

---------------------------------------------------------------------------
-- Bags
---------------------------------------------------------------------------

local bagFrames = {}

local function BagSlot(parent, b, s)
    local btn = K.SlotButton(parent, 37)
    btn.bg:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
    btn.b, btn.s = b, s
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            UI.ClearCursorItem()
            if UI.open.merchant then Items.Sell(self.b, self.s) K.Play(K.SFX.coin) return end
            Items.Use(self.b, self.s)
            return
        end
        if UI.cursorAction then UI.ClearCursorItem() return end
        if UI.cursorItem then UI.DropOnBag(self.b, self.s) return end
        if IsShiftKeyDown and IsShiftKeyDown() then
            local x = Items.Get(self.b, self.s)
            if x and x.n > 1 then
                -- (half a stack on the cursor - WoW's split, kept simple)
                local half = floor(x.n / 2)
                local fb, fs = Items.FirstFree()
                if fb then Items.Move(self.b, self.s, fb, fs, half) end
                return
            end
        end
        UI.PickupBagItem(self.b, self.s)
    end)
    btn:SetScript("OnDragStart", function(self)
        if not UI.cursorItem then UI.PickupBagItem(self.b, self.s) end
    end)
    btn:SetScript("OnReceiveDrag", function(self) if UI.cursorItem then UI.DropOnBag(self.b, self.s) end end)
    btn:SetScript("OnEnter", function(self)
        local x = Items.Get(self.b, self.s)
        if x then K.ItemTooltip(self, x.id) end
    end)
    btn:SetScript("OnLeave", K.HideTooltip)
    return btn
end

local function BuildBag(b)
    local size = Items.BagSize(b)
    local rows = math.ceil(size / 4)
    local f = CreateFrame("Frame", nil, UI.hudFrame)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(true)
    -- (WoW's container art: the frame is its right 194 pixels; the slots are drawn on it, 42 apart)
    local h = 50 + rows * 42 + (b == 0 and 18 or 4)
    f:SetSize(194, h)
    local art
    if b == 0 then art = "Interface\\ContainerFrame\\UI-BackpackBackground"
    else art = "Interface\\ContainerFrame\\UI-Bag-" .. min(4, rows) .. "x4" end
    f.art = K.Tex(f, "BORDER", art)
    f.art:SetSize(256, 256)
    f.art:SetPoint("TOPLEFT", -62, 0)
    f.portrait = K.Tex(f, "BACKGROUND")
    f.portrait:SetSize(36, 36)
    f.portrait:SetPoint("TOPLEFT", 4, -1)
    f.title = K.Text(f, "GameFontHighlight", "OVERLAY", "LEFT")
    f.title:SetPoint("TOPLEFT", 46, -11)
    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", 6, 0)
    f.close:SetScript("OnClick", function() UI.CloseWindow(f) end)
    f.slots = {}
    for s = 1, size do
        local btn = BagSlot(f, b, s)
        local idx = s - 1
        local row, col = floor(idx / 4), idx % 4
        btn:SetPoint("TOPLEFT", 19 + col * 42, -(51 + row * 42))
        btn.bg:Hide()
        f.slots[s] = btn
    end
    if b == 0 then
        f.money = K.Text(f, "GameFontHighlight", "OVERLAY", "RIGHT")
        f.money:SetPoint("BOTTOMRIGHT", -14, 8)
    end
    f.b = b
    f.size = size
    f:Hide()
    return f
end

function UI.ToggleBag(b)
    local f = bagFrames[b]
    if f and f.size ~= Items.BagSize(b) then f:Hide() f = nil end
    if not f then
        if Items.BagSize(b) <= 0 then return end
        f = BuildBag(b)
        bagFrames[b] = f
    end
    if f:IsShown() then UI.CloseWindow(f) return end
    UI.open["bag" .. b] = f
    -- bags stack up from the bottom right, the backpack first
    local y = 120
    for i = 0, 4 do
        local g = bagFrames[i]
        if g and g:IsShown() and g ~= f then y = max(y, g.stackTop or 0) end
    end
    f:ClearAllPoints()
    f:SetPoint("BOTTOMRIGHT", UI.hudFrame, "BOTTOMRIGHT", -8, y)
    f.stackTop = y + f:GetHeight() + 4
    f:SetFrameLevel(UI.hudFrame:GetFrameLevel() + 50)
    f:Show()
    K.Play(K.SFX.bag, 0.1)
    UI.RefreshBags()
end

function UI.OpenAllBags(open)
    for _, b in ipairs(Items.BagList()) do
        local f = bagFrames[b]
        local shown = f and f:IsShown()
        if open and not shown then UI.ToggleBag(b) elseif not open and shown then UI.CloseWindow(f) end
    end
end

function UI.ToggleAllBags()
    local any = false
    for _, f in pairs(bagFrames) do if f:IsShown() then any = true end end
    UI.OpenAllBags(not any)
end

function UI.RefreshBags()
    local c = Craft.char
    if not c then return end
    for b, f in pairs(bagFrames) do
        if f:IsShown() then
            local it = b > 0 and c.bags[b] and c.bags[b].item
            f.title:SetText(b == 0 and "Backpack" or (it and D.items[it] and D.items[it].n or "Bag"))
            f.portrait:SetTexture(b == 0 and "Interface\\Icons\\INV_Misc_Bag_08" or Items.Icon(it))
            if f.portrait.SetMask then pcall(f.portrait.SetMask, f.portrait, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
            for s, btn in ipairs(f.slots) do
                local x = Items.Get(b, s)
                K.SetItem(btn, x and x.id, x and x.n)
                if x and D.items[x.id] and D.items[x.id].c == 12 then
                    -- quest items: WoW's yellow "!" corner in later clients; a gold border here
                    btn.border:SetVertexColor(1, 0.82, 0, 0.8) btn.border:Show()
                end
            end
            if f.money then f.money:SetText(Craft.MoneyText(c.money, true)) end
        end
    end
end

---------------------------------------------------------------------------
-- Gossip and quests
---------------------------------------------------------------------------

local function ScrollText(parent, x, y, w, h)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", x, y)
    sf:SetSize(w, h)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(w, h)
    sf:SetScrollChild(child)
    sf.child = child
    return sf
end

local function Para(parent, font, w)
    local fs = K.Text(parent, font or "QuestFont", "OVERLAY", "LEFT")
    fs:SetWidth(w or 280)
    if fs.SetSpacing then fs:SetSpacing(2) end
    fs:SetTextColor(0.18, 0.12, 0.06)
    return fs
end

local function NpcPortrait(t, u)
    if not u then return end
    if u.cr and u.cr.disp and SetPortraitTextureFromCreatureDisplayID then
        pcall(SetPortraitTextureFromCreatureDisplayID, t, u.cr.disp)
    else
        t:SetTexture("Interface\\CharacterFrame\\TempPortrait")
    end
end

local qf                         -- the one quest / gossip frame (WoW's QuestFrame + GossipFrame)
local function QuestFrame()
    if qf then return qf end
    qf = Panel(UI.hudFrame, "Interface\\QuestFrame\\UI-QuestGreeting", "Bot", "")
    qf.detailArt = {}
    -- the parchment body
    qf.scroll = ScrollText(qf, 20, -74, 296, 330)
    qf.body = qf.scroll.child
    qf.lines = {}
    qf.btn1 = K.Button(qf, "Accept", 77, 21)
    qf.btn1:SetPoint("BOTTOMLEFT", 20, 76)       -- (on the art's bottom strip: it ends 69 px above the frame's foot)
    qf.btn2 = K.Button(qf, "Decline", 77, 21)
    qf.btn2:SetPoint("BOTTOMRIGHT", -37, 76)
    qf.onClose = function() qf.npc = nil end
    return qf
end

-- lays out content rows in the quest frame's body: rows = { { kind = "text"|"title"|"option"|"item"|"money", ... } }
local function Fill(rows)
    local f = QuestFrame()
    local body = f.body
    for _, l in ipairs(f.lines) do l:Hide() end
    local pool = f.pool or {}
    f.pool = pool
    local used = 0
    local y = -4
    local function get(kind)
        used = used + 1
        local w = pool[used]
        if not w or w.kind ~= kind then
            if kind == "title" then w = K.Text(body, "QuestTitleFont", "OVERLAY", "LEFT") w:SetWidth(280) w:SetTextColor(0, 0, 0)
            elseif kind == "text" then w = Para(body)
            elseif kind == "option" then
                w = CreateFrame("Button", nil, body)
                w:SetSize(280, 18)
                w.icon = K.Tex(w, "ARTWORK")
                w.icon:SetSize(16, 16)
                w.icon:SetPoint("LEFT", 2, 0)
                w.text = K.Text(w, "QuestFontNormalSmall", "OVERLAY", "LEFT")
                w.text:SetPoint("LEFT", 22, 0)
                w.text:SetWidth(255)
                w.text:SetTextColor(0, 0, 0)
                w:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            elseif kind == "item" then
                w = CreateFrame("Button", nil, body)
                w:SetSize(147, 41)
                w.bg = K.Tex(w, "BACKGROUND", "Interface\\QuestFrame\\UI-QuestItemNameFrame")
                w.bg:SetSize(128, 64)
                w.bg:SetPoint("LEFT", 30, 0)
                w.slot = K.SlotButton(w, 37)
                w.slot:SetPoint("LEFT", 0, 0)
                w.slot:EnableMouse(false)
                w.name = K.Text(w, "GameFontHighlightSmall", "OVERLAY", "LEFT")
                w.name:SetPoint("LEFT", 43, 0)
                w.name:SetWidth(100)
                w.name:SetTextColor(0, 0, 0)
                w.sel = K.Tex(w, "OVERLAY", "Interface\\QuestFrame\\UI-QuestItemHighlight")
                w.sel:SetBlendMode("ADD")
                w.sel:SetSize(256, 64)
                w.sel:SetPoint("LEFT", -8, 0)
                w.sel:Hide()
            elseif kind == "money" then
                w = K.Text(body, "GameFontHighlight", "OVERLAY", "LEFT")
            end
            w.kind = kind
            pool[used] = w
        end
        w:Show()
        f.lines[#f.lines + 1] = w
        return w
    end
    local col = 0
    for _, r in ipairs(rows) do
        local w = get(r.kind)
        w:ClearAllPoints()
        if r.kind == "item" then
            w:SetPoint("TOPLEFT", body, "TOPLEFT", col * 150, y)
            K.SetItem(w.slot, r.id, r.n)
            local it = D.items[r.id]
            w.name:SetText(it and it.n or "?")
            w.sel:SetShown(r.selected and true or false)
            w:SetScript("OnEnter", function(self) K.ItemTooltip(self, r.id) end)
            w:SetScript("OnLeave", K.HideTooltip)
            w:SetScript("OnClick", r.onClick)
            if col == 1 or r.last then col = 0 y = y - 44 else col = 1 end
        else
            if col == 1 then col = 0 y = y - 44 end
            w:SetPoint("TOPLEFT", body, "TOPLEFT", 0, y)
            if r.kind == "option" then
                w.text:SetText(r.text)
                w.icon:SetTexture(r.icon)
                if r.grey then w.text:SetTextColor(0.35, 0.35, 0.35) else w.text:SetTextColor(0, 0, 0) end
                w:SetScript("OnClick", r.onClick)
                y = y - 20
            elseif r.kind == "money" then
                w:SetText(r.text)
                y = y - 18
            else
                w:SetText(r.text)
                if r.kind == "title" then y = y - (w:GetStringHeight() or 16) - 6
                else y = y - (w:GetStringHeight() or 14) - 10 end
            end
        end
    end
    f.body:SetHeight(max(334, -y + 8))
    f.scroll:SetVerticalScroll(0)
end

local QUEST_ICON = { offer = "Interface\\GossipFrame\\AvailableQuestIcon", done = "Interface\\GossipFrame\\ActiveQuestIcon",
                     going = "Interface\\GossipFrame\\ActiveQuestIcon" }

function UI.OpenGossip(u)
    local g = Craft.Npc.Gossip(u)
    local direct = Craft.Npc.Direct(g)
    if direct == "vendor" then return UI.OpenMerchant(u) end
    if direct == "trainer" then return UI.OpenTrainer(u) end
    -- one quest to hand in or one to take and nothing else: straight to it, like WoW
    if #g.quests == 1 and #g.options == 0 and not (u.cr and u.cr.say) then
        local q = g.quests[1]
        if q.kind == "offer" then return UI.QuestDetail(u, q.q) end
        return UI.QuestProgress(u, q.q)
    end
    local f = QuestFrame()
    f.npc = u
    f.title:SetText(u.name)
    NpcPortrait(f.portrait, u)
    local rows = { { kind = "text", text = g.text } }
    for _, x in ipairs(g.quests) do
        rows[#rows + 1] = { kind = "option", text = x.q.title, icon = QUEST_ICON[x.kind], grey = x.kind == "going",
            onClick = function()
                if x.kind == "offer" then UI.QuestDetail(u, x.q) else UI.QuestProgress(u, x.q) end
            end }
    end
    local ICONS = { Vendor = "Interface\\GossipFrame\\VendorGossipIcon", Trainer = "Interface\\GossipFrame\\TrainerGossipIcon",
                    Binder = "Interface\\GossipFrame\\BinderGossipIcon" }
    for _, o in ipairs(g.options) do
        rows[#rows + 1] = { kind = "option", text = o.text, icon = ICONS[o.icon] or "Interface\\GossipFrame\\GossipGossipIcon",
            onClick = function()
                if o.action == "vendor" then UI.OpenMerchant(u)
                elseif o.action == "trainer" then UI.OpenTrainer(u)
                elseif o.action == "bind" then Craft.Npc.Bind(u) UI.CloseWindow(f) end
            end }
    end
    Fill(rows)
    f.btn1:Hide()
    f.btn2:SetText("Goodbye")
    f.btn2:SetScript("OnClick", function() UI.CloseWindow(f) end)
    UI.ShowWindow("quest", f)
    K.Play(K.SFX.open, 0.1)
end

local function RewardRows(q, rows, choice, onPick)
    local x = Craft.Quests.Extra(q.id)
    local any = (x.choice and #x.choice > 0) or (x.rew and #x.rew > 0) or (x.money and x.money > 0) or (x.xpm and x.xpm > 0)
    if not any then return end
    rows[#rows + 1] = { kind = "title", text = "Rewards" }
    if x.choice and #x.choice > 0 then
        rows[#rows + 1] = { kind = "text", text = "You will be able to choose one of these rewards:" }
        for i, r in ipairs(x.choice) do
            rows[#rows + 1] = { kind = "item", id = r[1], n = r[2], selected = choice == i, last = i == #x.choice,
                                onClick = onPick and function() onPick(i) end or nil }
        end
    end
    if x.rew and #x.rew > 0 then
        rows[#rows + 1] = { kind = "text", text = (x.choice and #x.choice > 0) and "You will also receive:" or "You will receive:" }
        for i, r in ipairs(x.rew) do rows[#rows + 1] = { kind = "item", id = r[1], n = r[2], last = i == #x.rew } end
    end
    if x.money and x.money > 0 then rows[#rows + 1] = { kind = "money", text = Craft.MoneyText(x.money, true) } end
    local xp = Craft.QuestXP(Craft.char.level, x.lvl or q.lvl or 1, x.xpm)
    if xp > 0 then rows[#rows + 1] = { kind = "text", text = "Experience: " .. xp } end
end

function UI.QuestDetail(u, q)
    local f = QuestFrame()
    f.npc = u
    f.title:SetText(u and u.name or q.title)
    if u then NpcPortrait(f.portrait, u) end
    local rows = {
        { kind = "title", text = q.title },
        { kind = "text", text = Craft.Quests.Text(q.text) },
        { kind = "title", text = "Quest Objectives" },
        { kind = "text", text = Craft.Quests.Text(q.goal) },
    }
    RewardRows(q, rows)
    Fill(rows)
    f.btn1:Show()
    f.btn1:SetText("Accept")
    f.btn1:SetScript("OnClick", function()
        if Craft.Quests.Accept(q.id) then UI.CloseWindow(f) end
    end)
    f.btn2:SetText("Decline")
    f.btn2:SetScript("OnClick", function() UI.CloseWindow(f) end)
    UI.ShowWindow("quest", f)
end

function UI.QuestProgress(u, q)
    local f = QuestFrame()
    f.npc = u
    f.title:SetText(u and u.name or q.title)
    if u then NpcPortrait(f.portrait, u) end
    local x = Craft.Quests.Extra(q.id)
    local complete = Craft.Quests.Complete(q.id)
    if complete then return UI.QuestReward(u, q) end
    local rows = { { kind = "title", text = q.title },
                   { kind = "text", text = Craft.Quests.Text(x.req or q.ask or q.goal) } }
    for _, it in ipairs(q.items or {}) do
        local src = x.src
        if not (src and src[1] == it.id and #(it.from or {}) == 0) then
            rows[#rows + 1] = { kind = "item", id = it.id, n = it.count, last = true }
        end
    end
    Fill(rows)
    f.btn1:Show()
    f.btn1:SetText("Continue")
    f.btn1:Disable()
    f.btn2:SetText("Cancel")
    f.btn2:SetScript("OnClick", function() UI.CloseWindow(f) end)
    UI.ShowWindow("quest", f)
end

function UI.QuestReward(u, q, choice)
    local f = QuestFrame()
    f.npc = u
    f.title:SetText(u and u.name or q.title)
    if u then NpcPortrait(f.portrait, u) end
    local x = Craft.Quests.Extra(q.id)
    local rows = { { kind = "title", text = q.title },
                   { kind = "text", text = Craft.Quests.Text(x.offer or q.done or "Well done.") } }
    RewardRows(q, rows, choice, function(i) UI.QuestReward(u, q, i) end)
    Fill(rows)
    f.btn1:Show()
    f.btn1:Enable()
    f.btn1:SetText("Complete Quest")
    f.btn1:SetWidth(120)
    f.btn1:SetScript("OnClick", function()
        if x.choice and #x.choice > 0 and not choice then Craft:Error("You must choose a reward.") return end
        if Craft.Quests.TurnIn(q.id, choice) then
            UI.CloseWindow(f)
            -- the next quest of the chain from the same NPC, as WoW offers it
            if u and x.next and Craft.Quests.Get(x.next) and Craft.Quests.Get(x.next).giver == u.entry then
                local nq = Craft.Quests.Get(x.next)
                if Craft.Quests.Available(nq) then UI.QuestDetail(u, nq) end
            end
        end
    end)
    f.btn2:SetText("Cancel")
    f.btn2:SetScript("OnClick", function() UI.CloseWindow(f) end)
    UI.ShowWindow("quest", f)
end

---------------------------------------------------------------------------
-- Merchant
---------------------------------------------------------------------------

local mf
local function MerchantFrame()
    if mf then return mf end
    mf = Panel(UI.hudFrame, "Interface\\MerchantFrame\\UI-Merchant", "Bot", "")
    mf.items = {}
    for i = 1, 10 do
        local row = CreateFrame("Frame", nil, mf)
        row:SetSize(153, 44)
        local col, r = (i - 1) % 2, floor((i - 1) / 2)
        row:SetPoint("TOPLEFT", 21 + col * 158, -74 - r * 51)
        row.slot = K.SlotButton(row, 37)
        row.slot:SetPoint("TOPLEFT", 0, 0)
        row.name = K.Text(row, "GameFontNormalSmall", "OVERLAY", "LEFT")
        row.name:SetPoint("TOPLEFT", 43, -2)
        row.name:SetWidth(105)
        row.name:SetHeight(28)
        row.price = K.Text(row, "GameFontHighlightSmall", "OVERLAY", "LEFT")
        row.price:SetPoint("TOPLEFT", 43, -28)
        row.slot:SetScript("OnLeave", K.HideTooltip)
        mf.items[i] = row
    end
    mf.page = 1
    mf.prev = CreateFrame("Button", nil, mf, "UIPanelButtonTemplate")
    mf.prev:SetSize(26, 22) mf.prev:SetText("<")
    mf.prev:SetPoint("BOTTOMLEFT", 25, 104)
    mf.next = CreateFrame("Button", nil, mf, "UIPanelButtonTemplate")
    mf.next:SetSize(26, 22) mf.next:SetText(">")
    mf.next:SetPoint("BOTTOMRIGHT", -56, 104)
    mf.pageText = K.Text(mf, "GameFontNormalSmall", "OVERLAY", "CENTER")
    mf.pageText:SetPoint("BOTTOM", -12, 110)
    mf.prev:SetScript("OnClick", function() mf.page = max(1, mf.page - 1) UI.RefreshMerchant() end)
    mf.next:SetScript("OnClick", function() mf.page = mf.page + 1 UI.RefreshMerchant() end)
    mf.money = K.Text(mf, "GameFontHighlight", "OVERLAY", "RIGHT")
    mf.money:SetPoint("BOTTOMRIGHT", -45, 88)
    mf.junk = K.Button(mf, "Sell Junk", 90, 22, function()
        local total = Items.SellJunk()
        if total > 0 then Craft:Msg("You sold your junk for " .. Craft.MoneyText(total) .. ".", "money") end
    end)
    mf.junk:SetPoint("BOTTOMLEFT", 25, 84)
    mf.buyback = K.Text(mf, "GameFontNormalSmall", "OVERLAY", "LEFT")
    mf.buyback:SetPoint("BOTTOMLEFT", 25, 136)
    mf.backBtn = K.SlotButton(mf, 30)
    mf.backBtn:SetPoint("BOTTOMLEFT", 120, 128)
    mf.backBtn:SetScript("OnClick", function() Items.BuyBack(1) UI.RefreshMerchant() end)
    mf.backBtn:SetScript("OnEnter", function(self) local e = Items.buyback[1] if e then K.ItemTooltip(self, e.id, "Buy back for " .. Craft.MoneyText(e.price)) end end)
    mf.backBtn:SetScript("OnLeave", K.HideTooltip)
    mf.onClose = function() mf.npc = nil end
    return mf
end

function UI.OpenMerchant(u)
    local f = MerchantFrame()
    f.npc = u
    f.page = 1
    f.title:SetText(u.name)
    NpcPortrait(f.portrait, u)
    if UI.open.quest then UI.CloseWindow(UI.open.quest) end
    UI.ShowWindow("merchant", f)
    UI.OpenAllBags(true)
    K.Play(K.SFX.coin, 0.1)
    UI.RefreshMerchant()
end

function UI.RefreshMerchant()
    local f = mf
    if not f or not f:IsShown() or not f.npc then return end
    local stock = Craft.Npc.Stock(f.npc)
    local pages = max(1, math.ceil(#stock / 10))
    f.page = min(f.page, pages)
    f.pageText:SetText("Page " .. f.page .. " of " .. pages)
    f.prev:SetEnabled(f.page > 1)
    f.next:SetEnabled(f.page < pages)
    for i = 1, 10 do
        local row = f.items[i]
        local e = stock[(f.page - 1) * 10 + i]
        if e then
            row:Show()
            K.SetItem(row.slot, e.id, e.count > 1 and e.count or nil)
            local it = D.items[e.id]
            local q = Items.QUALITY_RGB[it.q or 1]
            row.name:SetText(it.n)
            row.name:SetTextColor(q[1], q[2], q[3])
            row.price:SetText(Craft.MoneyText(e.price, true))
            local can = Items.CanEquip(it, Craft.char) or not it.inv or not Items.INV_SLOTS[it.inv]
            row.slot.icon:SetVertexColor(can and 1 or 1, can and 1 or 0.2, can and 1 or 0.2)
            row.slot:SetScript("OnClick", function(_, button)
                local n = (IsShiftKeyDown and IsShiftKeyDown()) and 5 or 1
                if Items.Buy(e.id, n) then K.Play(K.SFX.coin) end
            end)
            row.slot:SetScript("OnEnter", function(self) K.ItemTooltip(self, e.id, "nosell") end)
        else
            row:Hide()
        end
    end
    f.money:SetText(Craft.MoneyText(Craft:Money(), true))
    local bb = Items.buyback[1]
    f.buyback:SetText(bb and "Buyback:" or "")
    if bb then K.SetItem(f.backBtn, bb.id, bb.n) f.backBtn:Show() else f.backBtn:Hide() end
end

---------------------------------------------------------------------------
-- Loot window
---------------------------------------------------------------------------

local lf
local function LootFrame()
    if lf then return lf end
    lf = CreateFrame("Frame", nil, UI.hudFrame)
    lf:SetSize(256, 256)
    lf:SetFrameStrata("HIGH")
    lf:EnableMouse(true)
    lf.art = K.Tex(lf, "BORDER", "Interface\\LootFrame\\UI-LootPanel")
    lf.art:SetAllPoints()
    lf.portrait = K.Tex(lf, "BACKGROUND", "Interface\\LootFrame\\LootPanel-Icon")
    lf.portrait:SetSize(64, 64)
    lf.portrait:SetPoint("TOPLEFT", 8, -5)
    lf.title = K.Text(lf, "GameFontHighlight", "OVERLAY", "CENTER")
    lf.title:SetPoint("TOP", 12, -20)
    lf.title:SetText("Items")
    lf.close = CreateFrame("Button", nil, lf, "UIPanelCloseButton")
    lf.close:SetPoint("TOPRIGHT", -46, -10)
    lf.close:SetScript("OnClick", function() Craft.Loot.Close() end)
    lf.slots = {}
    for i = 1, 4 do
        local b = CreateFrame("Button", nil, lf)
        b:SetSize(147, 41)
        b:SetPoint("TOPLEFT", 9, -68 - (i - 1) * 41)
        b.slot = K.SlotButton(b, 37)
        b.slot:SetPoint("LEFT")
        b.slot:EnableMouse(false)
        b.bg = K.Tex(b, "BACKGROUND", "Interface\\QuestFrame\\UI-QuestItemNameFrame")
        b.bg:SetSize(128, 64)
        b.bg:SetPoint("LEFT", 30, 0)
        b.name = K.Text(b, "GameFontNormalSmall", "OVERLAY", "LEFT")
        b.name:SetPoint("LEFT", 45, 0)
        b.name:SetWidth(100)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestItemHighlight", "ADD")
        b:SetScript("OnLeave", K.HideTooltip)
        lf.slots[i] = b
    end
    lf.page = 1
    lf.onClose = function() if Craft.Loot.open then Craft.Loot.Close() end end
    return lf
end

function UI.RefreshLoot()
    local f = lf
    if not f or not f:IsShown() then return end
    local l = Craft.Loot.Items()
    if not l then UI.CloseWindow(f) return end
    -- money first, then the items not taken
    local entries = {}
    if l.money > 0 then entries[#entries + 1] = { money = l.money } end
    for i, it in ipairs(l.items) do
        if not it.taken and (not it.owner or it.owner == Craft.player.guid) then entries[#entries + 1] = { idx = i, it = it } end
    end
    if #entries == 0 then Craft.Loot.Close() return end
    for i, b in ipairs(f.slots) do
        local e = entries[i]
        if e then
            b:Show()
            if e.money then
                b.slot.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
                b.slot.icon:Show()
                b.slot.count:SetText("")
                b.slot.border:Hide()
                b.name:SetText(Craft.MoneyText(e.money))
                b.name:SetTextColor(1, 1, 1)
                b:SetScript("OnClick", function() Craft.Loot.TakeMoney() UI.RefreshLoot() end)
                b:SetScript("OnEnter", nil)
            else
                K.SetItem(b.slot, e.it.id, e.it.n)
                local it = D.items[e.it.id]
                local q = Items.QUALITY_RGB[it and it.q or 1]
                b.name:SetText((it and it.n or "?") .. (e.it.rolling and " |cffff8080(rolling)|r" or ""))
                b.name:SetTextColor(q[1], q[2], q[3])
                b:SetScript("OnClick", function() Craft.Loot.Take(e.idx) UI.RefreshLoot() end)
                b:SetScript("OnEnter", function(self) K.ItemTooltip(self, e.it.id) end)
            end
        else
            b:Hide()
        end
    end
end

function UI.OpenLoot()
    local f = LootFrame()
    UI.open.loot = f
    f:SetFrameLevel(UI.hudFrame:GetFrameLevel() + 70)
    f:ClearAllPoints()
    local x, y = GetCursorPosition()
    local s = UI.hudFrame:GetEffectiveScale()
    local l, t = UI.hudFrame:GetLeft() or 0, UI.hudFrame:GetTop() or 0
    f:SetPoint("TOPLEFT", UI.hudFrame, "TOPLEFT", Craft.Clamp(x / s - l - 40, 0, max(0, (UI.hudFrame:GetWidth() or 800) - 200)),
               -Craft.Clamp(t - y / s - 30, 0, max(0, (UI.hudFrame:GetHeight() or 600) - 260)))
    f:Show()
    UI.RefreshLoot()
end

---------------------------------------------------------------------------
-- Game menu
---------------------------------------------------------------------------

local gm
function UI.ToggleMenu()
    if not gm then
        gm = K.Frame(UI.hudFrame, 220, 200, K.BACKDROP)
        gm:SetPoint("CENTER", 0, 40)
        gm:SetFrameStrata("DIALOG")
        gm:EnableMouse(true)
        local hdr = K.Tex(gm, "ARTWORK", "Interface\\DialogFrame\\UI-DialogBox-Header")
        hdr:SetSize(256, 64)
        hdr:SetPoint("TOP", 0, 12)
        local t = K.Text(gm, "GameFontNormal", "OVERLAY", "CENTER")
        t:SetPoint("TOP", hdr, "TOP", 0, -14)
        t:SetText("Game Menu")
        local items = {
            { "Controls", function() UI.ShowHelp() end },
            { "Sound: on", function(b)
                local d = Craft:Data()
                d.sfx = d.sfx == false and true or false
                b:SetText("Sound: " .. (d.sfx == false and "off" or "on"))
            end },
            { "Character Select", function() gm:Hide() UI.ToGlue() end },
            { "Release Keyboard", function() gm:Hide() UI.SetFocus(false) end },
            { "Return to Game", function() gm:Hide() end },
        }
        for i, it in ipairs(items) do
            local b = K.Button(gm, it[1], 160, 24)
            b:SetPoint("TOP", 0, -34 - (i - 1) * 30)
            b:SetScript("OnClick", function(self) it[2](self) end)
            if i == 2 then b:SetText("Sound: " .. (Craft:Data().sfx == false and "off" or "on")) end
        end
        gm:Hide()
    end
    gm:SetShown(not gm:IsShown())
    if gm:IsShown() then K.Play(K.SFX.open) end
    UI.open.menu = gm:IsShown() and gm or nil
end

function UI.ShowHelp()
    UI.Popup("help", "WASD / arrows: move   Tab: next enemy   1-0 - =: action bar (Shift: 2nd row)\n" ..
        "Left-click: target   Right-click: attack / talk / loot (Shift: loot all)\n" ..
        "F: interact   X: sit   C: character   B: bags   P: spellbook   N: talents   L: quest log   O: party\n" ..
        "Enter: chat (/s /p /e /invite name /leave)   Esc: close / menu   Wheel: zoom",
        { "Okay", function() end })
end

---------------------------------------------------------------------------
-- Opening and closing by name (the keys and the micro menu)
---------------------------------------------------------------------------

function UI.Toggle(name)
    if name == "character" then
        local f = UI.CharacterSheet()
        if f:IsShown() then UI.CloseWindow(f) else UI.ShowWindow("character", f) K.Play(K.SFX.sheet) UI.RefreshCharacter() end
    elseif name == "talents" then
        local f = UI.TalentWindow()
        if f:IsShown() then UI.CloseWindow(f) else UI.ShowWindow("talents", f) K.Play(K.SFX.book) UI.RefreshTalents() end
    elseif name == "spellbook" then
        local f = UI.SpellBookWindow()
        if f:IsShown() then UI.CloseWindow(f) else UI.ShowWindow("spellbook", f) K.Play(K.SFX.book) UI.RefreshSpellbook() end
    elseif name == "questlog" then
        local f = UI.QuestLogWindow()
        if f:IsShown() then UI.CloseWindow(f) else UI.ShowWindow("questlog", f) K.Play(K.SFX.questlog) UI.RefreshQuestLog() end
    elseif name == "menu" then
        UI.ToggleMenu()
    elseif name == "party" then
        if UI.ToggleParty then UI.ToggleParty() end
    end
end

-- what changed -> which open window redraws
Craft:On("item", function() UI.RefreshBags() UI.RefreshMerchant() UI.RefreshCharacter() UI.RefreshLoot() end)
Craft:On("equip", function() UI.RefreshCharacter() UI.RefreshBags() end)
Craft:On("money", function() UI.RefreshBags() UI.RefreshMerchant() UI.RefreshTrainer() end)
Craft:On("spell", function() UI.RefreshSpellbook() UI.RefreshTrainer() end)
Craft:On("level", function() UI.RefreshCharacter() UI.RefreshTrainer() UI.RefreshSpellbook() end)
Craft:On("quest", function() UI.RefreshQuestLog() end)
Craft:On("sold", function() UI.RefreshMerchant() end)
Craft:On("gossip", function(u) UI.OpenGossip(u) end)
Craft:On("questoffer", function(q, u) UI.QuestDetail(u, q) end)
Craft:On("loot", function() UI.OpenLoot() K.Play(K.SFX.loot) end)
Craft:On("lootupdate", function() UI.RefreshLoot() end)
Craft:On("lootclose", function() if lf and lf:IsShown() then UI.open.loot = nil lf:Hide() end end)
