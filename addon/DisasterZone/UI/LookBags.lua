if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LookBags.lua", ...) then return end -- DisasterZone UI/LookBags.lua
-- Bags (Settings > UI > Bags): the bags, the key ring and the bank in the part's look. Mockup
-- dev/art/casc/bags_mockup (claude.ai/artifact/Am3pZTp3YnApUWJ4EXKPNT); user 2026-10-13: all three layouts,
-- configurable, One bag the default, bank and key ring too.
-- Two windows of one kind: Bags (backpack + bags 1-4, the key ring folded in on demand) and Bank (the bank's slots +
-- its bags, while at a banker). Layouts (ui.bags.layout):
--   one      every bag poured into one grid in bag order (nothing moves under your hand)
--   shelves  sorted into sections (New, Gear, Consumables, Trade goods, Gems, Quest & keys, Other, Junk, Free): a
--            view only, the items stay in their slots; a section folds; Junk sells at a vendor
--   bags     a column per bag, its free slots in its head
-- The slots are the game's own item buttons (ContainerFrameItemButtonTemplate, the bank's BankItemButtonGenericTemplate)
-- made by us, one per slot, in a holder frame whose ID is the bag (the template reads the bag from its parent's ID
-- and the slot from its own): clicks, drags, splitting, using items in combat, selling and banking stay the game's
-- code. They are plain buttons (not protected), so they move in combat too. Faces from UI/LookBars.lua (the Dock's
-- size and look), the item's quality as their calm colour; a dot on junk, a glow on new items. (Tags for BiS / kit /
-- shopping were tried and dropped 2026-10-13: "just clutter".) While an item is held the slots stay where they are:
-- a refresh never hides a button that keeps its slot (hiding the one under the cursor dropped the drag).
-- The game's bag windows stay hidden while the part has a look; B, the bag slots, the key ring and anything that
-- opens all bags (mail, vendors) open ours; the bank opens the Bank window instead of the game's.
local addonName, ns = ...

local Bags = ns:NewModule("LookBags")
local UI = ns.UI

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tsort, tinsert = table.sort, table.insert

local function Look() return ns.Look end
local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting(path)
    if v == nil then return default end
    return v
end

local BANK, KEYRING = -1, -2
local BAG_IDS = { 0, 1, 2, 3, 4 }
local BANK_IDS = { BANK, 5, 6, 7, 8, 9, 10, 11 }
local Q = { [0] = { 0.62, 0.62, 0.62 }, { 1, 1, 1 }, { 0.12, 1, 0 }, { 0, 0.44, 0.87 }, { 0.64, 0.21, 0.93 },
            { 1, 0.5, 0 }, { 0.9, 0.8, 0.5 } }
local GAP = { flat = 2, halo = 6, sigil = 3, slate = 2, gilded = 4 }      -- (the Dock's; Halo's tighter: no key binds)
Bags.LAYOUTS = { "one", "shelves", "bags" }
-- the shelves, in order
Bags.SECTIONS = {
    { key = "new", name = "New" }, { key = "gear", name = "Gear" }, { key = "cons", name = "Consumables" },
    { key = "trade", name = "Trade goods" }, { key = "gems", name = "Gems" }, { key = "quest", name = "Quest & keys" },
    { key = "other", name = "Other" }, { key = "junk", name = "Junk" }, { key = "free", name = "Free slots" },
}
-- item class -> shelf (GetItemInfoInstant's classID)
local CLASS_SHELF = { [0] = "cons", [2] = "gear", [4] = "gear", [3] = "gems", [5] = "trade", [7] = "trade",
                      [12] = "quest", [13] = "quest" }

function Bags:Wanted() return Look():IsOn("bags") end
function Bags:Layout() return Look():Opt("bags", "layout", "one") end
function Bags:Size() return (ns.LookDock and ns.LookDock:Size()) or 36 end

---------------------------------------------------------------------------
-- Item facts
---------------------------------------------------------------------------

local function Info(bag, slot)
    local C = C_Container
    if C and C.GetContainerItemInfo then return C.GetContainerItemInfo(bag, slot) end
    return nil
end

local function NumSlots(bag)
    local C = C_Container
    return (C and C.GetContainerNumSlots and C.GetContainerNumSlots(bag)) or 0
end

-- (this client has C_Item.GetItemInfo; older ones the global)
local function GII(id)
    local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not f or not id then return nil end
    return f(id)
end

local function ItemName(id)
    if not id then return "" end
    local n = GII(id)
    if not n and C_Item and C_Item.GetItemNameByID then n = C_Item.GetItemNameByID(id) end
    return n or ""
end

local function ItemType(id)
    if not id then return "" end
    local _, _, _, _, _, t, sub = GII(id)
    return sub or t or ""
end

local function ClassOf(id)
    if not id then return nil end
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local _, _, _, _, _, classID = f(id)
    return classID
end

local function IsNew(bag, slot)
    return C_NewItems and C_NewItems.IsNewItem and C_NewItems.IsNewItem(bag, slot) and true or false
end

---------------------------------------------------------------------------
-- The windows
---------------------------------------------------------------------------

local windows = {}
Bags.windows = windows

local function Tex(parent, layer, sub, path) return Look().Tex(parent, layer, sub, path) end

local function Text(parent, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", size == "small" and "GameFontHighlightSmall" or "GameFontNormal")
    if r then fs:SetTextColor(r, g, b) end
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    return fs
end

-- kind: "bags" | "bank"
local function NewWindow(kind)
    local name = kind == "bank" and "DisasterZoneBank" or "DisasterZoneBags"
    local f = CreateFrame("Frame", name, UIParent)
    f.kind = kind
    f:SetFrameStrata("MEDIUM")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetSize(480, 300)
    f:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, name) end
    f.panel = Look():Panel(f)
    f.floor = Tex(f, "BACKGROUND", -8)                   -- (Halo: a plain dark ground, no edges: the rings carry it)
    f.floor:SetAllPoints(f)
    f.floor:Hide()

    -- header: title, free slots, search, sort, close (dragging it moves the window)
    local hd = CreateFrame("Frame", nil, f)
    hd:SetPoint("TOPLEFT", 10, -8); hd:SetPoint("TOPRIGHT", -10, -8); hd:SetHeight(22)
    hd:EnableMouse(true)
    hd:RegisterForDrag("LeftButton")
    hd:SetScript("OnDragStart", function() f:StartMoving() end)
    hd:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local L = ns.Layout
        if L and L.MoveTo and f:GetLeft() then
            local r = L.Ratio and L.Ratio(f) or 1
            L:MoveTo(Bags:LayoutId(kind), f:GetLeft() * r, f:GetBottom() * r)
        end
    end)
    f.hd = hd
    f.title = Text(hd, "normal")
    f.title:SetPoint("LEFT", 0, 0)
    f.title:SetText(kind == "bank" and "Bank" or "Bags")
    f.free = Text(hd, "small", 0.8, 0.78, 0.72)
    f.free:SetPoint("LEFT", f.title, "RIGHT", 6, 0)
    f.close = CreateFrame("Button", nil, hd)
    f.close:SetSize(18, 18)
    f.close:SetPoint("RIGHT", 0, 0)
    f.close.x = Text(f.close, "normal", 0.85, 0.83, 0.78)
    f.close.x:SetPoint("CENTER"); f.close.x:SetText("x")
    f.close:SetScript("OnClick", function() f:Hide() end)
    f.sort = CreateFrame("Button", nil, hd)
    f.sort:SetSize(40, 20)
    f.sort:SetPoint("RIGHT", f.close, "LEFT", -6, 0)
    f.sort.bg = Tex(f.sort, "BACKGROUND", 0)
    f.sort.bg:SetAllPoints()
    f.sort.t = Text(f.sort, "small"); f.sort.t:SetPoint("CENTER"); f.sort.t:SetText("Sort")
    f.sort:SetScript("OnClick", function() Bags:Sort(kind) end)
    if UI.CreateSearchBox then
        f.search = UI:CreateSearchBox(hd, 180, function(text) Bags:Search(text) end, "Search (or junk, new)")
        f.search:SetPoint("LEFT", f.free, "RIGHT", 10, 0)
        f.search:SetPoint("RIGHT", f.sort, "LEFT", -8, 0)
    end

    -- body: the slots (each bag's holder carries the bag's id: the item button template reads it), section heads
    f.body = CreateFrame("Frame", nil, f)
    f.body:SetPoint("TOPLEFT", 10, -38)
    f.body:SetSize(10, 10)
    f.holders, f.buttons, f.heads = {}, {}, {}

    -- footer: bag slots, slot count, the key ring (bags) or buying a bank slot (bank), money
    f.ft = CreateFrame("Frame", nil, f)
    f.ft:SetPoint("BOTTOMLEFT", 10, 8); f.ft:SetPoint("BOTTOMRIGHT", -10, 8); f.ft:SetHeight(22)
    f.slots = Text(f.ft, "small", 0.8, 0.78, 0.72)
    f.money = Text(f.ft, "small", 1, 1, 1)
    f.money:SetPoint("RIGHT", 0, 0)
    f.bagIcons = {}
    if kind == "bags" then
        f.keys = CreateFrame("Button", nil, f.ft)
        f.keys:SetSize(20, 20)
        f.keys.icon = Tex(f.keys, "ARTWORK", 0, "Interface\\Icons\\INV_Misc_Key_14")
        f.keys.icon:SetAllPoints(); f.keys.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        f.keys:SetScript("OnClick", function() Bags:ShowKeys(not Bags.keys) end)
        f.keys:SetScript("OnEnter", function(s)
            GameTooltip:SetOwner(s, "ANCHOR_TOP"); GameTooltip:AddLine(KEYRING or "Key ring"); GameTooltip:Show()
        end)
        f.keys:SetScript("OnLeave", function() GameTooltip:Hide() end)
    else
        f.buy = CreateFrame("Button", nil, f.ft)
        f.buy:SetSize(110, 20)
        f.buy.bg = Tex(f.buy, "BACKGROUND", 0); f.buy.bg:SetAllPoints()
        f.buy.t = Text(f.buy, "small"); f.buy.t:SetPoint("CENTER")
        f.buy:SetScript("OnClick", function()
            if StaticPopup_Show then StaticPopup_Show("CONFIRM_BUY_BANK_SLOT") end
        end)
        f.bankBags = {}
    end
    f.junk = CreateFrame("Button", nil, f)
    f.junk:SetSize(130, 18)
    f.junk.t = Text(f.junk, "small", 1, 0.82, 0)
    f.junk.t:SetPoint("RIGHT")
    f.junk:SetScript("OnClick", function() Bags:SellJunk() end)
    f.junk:Hide()

    f:SetScript("OnShow", function() Bags:Refresh(kind) end)
    f:SetScript("OnHide", function()
        if kind == "bank" and Bags.atBank and CloseBankFrame then CloseBankFrame() end
        if kind == "bags" and C_NewItems and C_NewItems.ClearAll and Get("ui.bags.newglow", true) then
            -- (new items are new until you have seen them once)
            pcall(C_NewItems.ClearAll)
        end
    end)
    windows[kind] = f
    return f
end

function Bags:Window(kind)
    return windows[kind] or NewWindow(kind)
end

function Bags:LayoutId(kind) return kind == "bank" and "bags.bank" or "bags.bags" end

---------------------------------------------------------------------------
-- Slots
---------------------------------------------------------------------------

local function Holder(f, bag)
    local h = f.holders[bag]
    if h then return h end
    h = CreateFrame("Frame", nil, f.body)
    h:SetID(bag)
    h:SetAllPoints(f.body)
    f.holders[bag] = h
    return h
end

local function ButtonName(bag, slot) return ("DisasterZoneBagSlot%d_%d"):format(bag + 3, slot) end

-- The game's item button for a bag slot (made once).
function Bags:Button(f, bag, slot)
    f.buttons[bag] = f.buttons[bag] or {}
    local b = f.buttons[bag][slot]
    if b then return b end
    local h = Holder(f, bag)
    local template = (bag == BANK) and "BankItemButtonGenericTemplate" or "ContainerFrameItemButtonTemplate"
    b = CreateFrame("Button", ButtonName(bag, slot), h, template)
    b:SetID(slot)
    b.dzBag, b.dzSlot = bag, slot
    b.icon = b.icon or b.Icon or _G[b:GetName() .. "IconTexture"]
    b.Count = b.Count or _G[b:GetName() .. "Count"]
    b.cooldown = b.cooldown or b.Cooldown or _G[b:GetName() .. "Cooldown"]
    -- our marks over it: the junk dot, the new glow
    b.dzJunk = b:CreateTexture(nil, "OVERLAY", nil, 6)
    b.dzJunk:SetTexture(Look().DISC)
    b.dzJunk:SetSize(7, 7)
    b.dzJunk:SetPoint("TOPRIGHT", -2, -2)
    b.dzJunk:SetVertexColor(0.62, 0.62, 0.62, 1)
    b.dzNew = b:CreateTexture(nil, "OVERLAY", nil, 4)
    b.dzNew:SetTexture("Interface\\AddOns\\DisasterZone\\Media\\SoftGlow")
    b.dzNew:SetBlendMode("ADD")
    b.dzNew:SetVertexColor(1, 0.8, 0.3, 0.8)
    b.dzNew:SetPoint("TOPLEFT", -8, 8); b.dzNew:SetPoint("BOTTOMRIGHT", 8, -8)
    b:Show()
    f.buttons[bag][slot] = b
    return b
end

-- The button shows its slot now: icon, count, lock, cooldown (what the game's container frame does for its own).
local function Fill(b, info)
    local tex = info and info.iconFileID
    if SetItemButtonTexture then SetItemButtonTexture(b, tex) elseif b.icon then b.icon:SetTexture(tex) end
    if SetItemButtonCount then SetItemButtonCount(b, info and info.stackCount or 0) end
    if SetItemButtonDesaturated then SetItemButtonDesaturated(b, info and info.isLocked or false) end
    b.hasItem = tex and 1 or nil
    b.readable = info and info.isReadable
    if b.IconBorder then b.IconBorder:Hide() end
    local qt = _G[(b:GetName() or "") .. "IconQuestTexture"] or b.IconQuestTexture
    if qt then qt:Hide() end
    if b.JunkIcon then b.JunkIcon:Hide() end
    if b.NewItemTexture then b.NewItemTexture:Hide() end
    if b.BattlepayItemTexture then b.BattlepayItemTexture:Hide() end
    local cd = b.cooldown
    if cd then
        local getCd = (C_Container and C_Container.GetContainerItemCooldown) or GetContainerItemCooldown
        if tex and getCd and CooldownFrame_Set then
            local start, dur, on = getCd(b.dzBag, b.dzSlot)
            CooldownFrame_Set(cd, start, dur, on)
        else
            cd:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Refresh: what is in the window's bags, laid out in the layout
---------------------------------------------------------------------------

-- Every slot of a window: { bag, slot, info, id, q, shelf, new } in bag order (the key ring last when shown).
function Bags:Slots(kind)
    local out = {}
    local ids = kind == "bank" and BANK_IDS or BAG_IDS
    local list = {}
    for _, b in ipairs(ids) do list[#list + 1] = b end
    if kind == "bags" and self.keys then list[#list + 1] = KEYRING end
    for _, bag in ipairs(list) do
        for slot = 1, NumSlots(bag) do
            local info = Info(bag, slot)
            local id = info and info.itemID
            local q = info and info.quality
            local shelf = "free"
            if id then
                if q == 0 then shelf = "junk"
                else shelf = CLASS_SHELF[ClassOf(id) or -1] or "other" end
            end
            local new = id and Get("ui.bags.newglow", true) and IsNew(bag, slot) or false
            out[#out + 1] = { bag = bag, slot = slot, info = info, id = id, q = q, shelf = (new and "new") or shelf, new = new }
        end
    end
    return out
end

local function Matches(s, q)
    if q == "" then return true end
    if not s.id then return false end
    if q == "junk" then return s.q == 0 end
    if q == "new" then return s.new end
    local n = ItemName(s.id):lower()
    if n:find(q, 1, true) then return true end
    return ItemType(s.id):lower():find(q, 1, true) and true or false
end

-- One slot's face and marks.
function Bags:Paint(b, s, look, S, dim)
    Fill(b, s.info)
    local LB = ns.LookBars
    if LB and LB.Apply then
        b:SetSize(S, S)
        LB:Apply(b, look)
        local sk = LB.skinned and LB.skinned[b]
        if sk then
            -- (the item's quality is the face's calm colour: Halo's ring, Sigil's frame, Flat's edge)
            local qc = s.q and s.q >= 2 and Q[s.q]
            sk.calm = qc and { qc[1], qc[2], qc[3], 0.9 } or nil
            LB:Status(b)
        end
    end
    -- (Slate's action buttons keep a strip under the icon for the key bind; a bag slot has none: the icon fills the
    -- cell and the strip is a thin line in the item's quality colour)
    if look.key == "slate" and b.icon then
        b.icon:ClearAllPoints()
        b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
        b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 5)
        local sk = LB and LB.skinned and LB.skinned[b]
        if sk and sk.under then
            local qc = s.q and s.q >= 2 and Q[s.q]
            if qc then
                sk.under:ClearAllPoints()
                sk.under:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 2, 1)
                sk.under:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 1)
                sk.under:SetHeight(2)
                Look().Color(sk.under, { qc[1], qc[2], qc[3], 0.9 })
            else
                sk.under:Hide()
            end
        end
    end
    if b.Count then b.Count:SetAlpha(1) end
    b.dzJunk:SetShown(s.q == 0 and s.id ~= nil)
    b.dzNew:SetShown(s.new and true or false)
    b:SetAlpha(dim and 0.22 or 1)
    if b.icon and b.icon.SetDesaturated then b.icon:SetDesaturated(dim or (s.info and s.info.isLocked) or false) end
end

local function Head(f, i)
    local h = f.heads[i]
    if h then return h end
    h = CreateFrame("Button", nil, f.body)
    h:SetHeight(16)
    h.t = Text(h, "small", 1, 0.82, 0)
    h.t:SetPoint("LEFT", 0, 0)
    h.n = Text(h, "small", 0.7, 0.68, 0.62)
    h.n:SetPoint("LEFT", h.t, "RIGHT", 6, 0)
    h.rule = Tex(h, "BORDER", 0)
    h.rule:SetHeight(1)
    h.rule:SetPoint("LEFT", h.n, "RIGHT", 8, 0)
    h.rule:SetPoint("RIGHT", h, "RIGHT", 0, 0)
    h:SetScript("OnClick", function(self)
        if not self.key then return end
        local folded = Get("ui.bags.fold." .. self.key, false)
        ns.DB:SetSetting("ui.bags.fold." .. self.key, not folded)
        Bags:Refresh()
    end)
    f.heads[i] = h
    return h
end

local HEAD_C = { flat = { 0.91, 0.89, 0.82 }, halo = { 0.96, 0.9, 0.72 }, sigil = { 1, 0.82, 0 },
                 slate = { 0.7, 0.7, 0.7 }, gilded = { 0.95, 0.81, 0.47 } }

function Bags:Refresh(kind)
    if not kind then
        for k, w in pairs(windows) do if w:IsShown() then self:Refresh(k) end end
        return
    end
    local f = windows[kind]
    if not f or not f:IsShown() then return end
    local L = Look()
    local look = L:For("bags")
    local k = look.key
    local S = self:Size()
    local G = GAP[k] or 2
    local layout = self:Layout()
    local q = (self.query or ""):lower()
    local slots = self:Slots(kind)
    -- the ground in the look (Halo: no plate, a light dark ground the rings float on)
    if k == "halo" then
        f.panel:Apply(nil)
        f.floor:Show(); f.floor:SetVertexColor(0.05, 0.05, 0.06, 0.62)
    else
        f.floor:Hide()
        f.panel:Apply(look)
    end
    local hc = HEAD_C[k] or HEAD_C.flat
    for _, h in ipairs(f.heads) do h:Hide() end
    local cols = (kind == "bank") and 14 or 12
    local y, w, hUsed = 0, 0, 0
    local nHead = 0
    -- (buttons that keep a slot are moved, never hidden and shown again: hiding the one under a held item drops it)
    local used = {}
    local function Put(s, px, py)
        local b = self:Button(f, s.bag, s.slot)
        used[b] = true
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f.body, "TOPLEFT", px, -py)
        self:Paint(b, s, look, S, not Matches(s, q))
        if not b:IsShown() then b:Show() end
        w = max(w, px + S)
        hUsed = max(hUsed, py + S)
    end
    local function Grid(list, x0, y0, ncols)
        for i, s in ipairs(list) do
            local c, r = (i - 1) % ncols, floor((i - 1) / ncols)
            Put(s, x0 + c * (S + G), y0 + r * (S + G))
        end
        local rows = ceil(#list / ncols)
        return y0 + rows * S + max(0, rows - 1) * G
    end
    local function Header(key, name, count, x0, y0, width, extra)
        nHead = nHead + 1
        local h = Head(f, nHead)
        h.key = key
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", f.body, "TOPLEFT", x0, -y0)
        h:SetWidth(width)
        h.t:SetText((k == "sigil" or k == "gilded") and name:upper() or name)
        h.t:SetTextColor(hc[1], hc[2], hc[3])
        h.n:SetText(extra or (count .. ""))
        h.rule:SetTexture(L.WHITE)
        h.rule:SetVertexColor(hc[1], hc[2], hc[3], 0.25)
        h:Show()
        return y0 + 20
    end
    local atVendor = MerchantFrame and MerchantFrame:IsShown() and true or false
    f.junk:Hide()
    if layout == "shelves" then
        local by = {}
        for _, s in ipairs(slots) do by[s.shelf] = by[s.shelf] or {}; tinsert(by[s.shelf], s) end
        for _, sec in ipairs(Bags.SECTIONS) do
            local list = by[sec.key]
            if list and #list > 0 then
                local folded = Get("ui.bags.fold." .. sec.key, false)
                local width = cols * S + (cols - 1) * G
                y = Header(sec.key, sec.name, #list, 0, y, width, folded and (#list .. " (folded)") or nil)
                if sec.key == "junk" and atVendor then
                    f.junk:ClearAllPoints(); f.junk:SetPoint("TOPRIGHT", f.body, "TOPLEFT", width, -(y - 19))
                    f.junk.t:SetText("Sell junk")
                    f.junk:Show()
                end
                if not folded then y = Grid(list, 0, y, cols) + 10 else y = y + 2 end
            end
        end
    elseif layout == "bags" then
        local bagCols = 4
        local colW = bagCols * S + (bagCols - 1) * G
        local perRow = kind == "bank" and 4 or 5
        local byBag, order = {}, {}
        for _, s in ipairs(slots) do
            if not byBag[s.bag] then byBag[s.bag] = {}; order[#order + 1] = s.bag end
            tinsert(byBag[s.bag], s)
        end
        local cx, cy, lineH = 0, 0, 0
        for i, bag in ipairs(order) do
            local list = byBag[bag]
            local free = 0
            for slot = 1, NumSlots(bag) do if not Info(bag, slot) then free = free + 1 end end
            local name = bag == 0 and "Backpack" or bag == BANK and "Bank" or bag == KEYRING and "Key ring"
                or (bag >= 5 and ("Bank bag " .. (bag - 4)) or ("Bag " .. bag))
            local yy = Header("bag" .. bag, name, 0, cx, cy, colW, free .. " free of " .. NumSlots(bag))
            local bottom = Grid(list, cx, yy, bagCols)
            lineH = max(lineH, bottom - cy)
            if i % perRow == 0 then cx, cy, lineH = 0, cy + lineH + 12, 0
            else cx = cx + colW + 14 end
        end
        y = cy + lineH
    else
        y = Grid(slots, 0, 0, cols)
    end
    -- the slots no longer in the window (a bag taken off, a folded shelf, the key ring put away)
    for _, list in pairs(f.buttons) do
        for _, b in pairs(list) do if not used[b] and b:IsShown() then b:Hide() end end
    end
    -- size: the body, header and footer
    local bw = max(w, 300)
    f.body:SetSize(bw, max(y, hUsed))
    f:SetSize(bw + 20, max(y, hUsed) + 38 + 40)
    self:Footer(f, kind, look)
end

-- The footer: the bag slots, how many slots, the key ring / buying a bank slot, money; the free slots in the head.
function Bags:Footer(f, kind, look)
    local L = Look()
    local free, total = 0, 0
    for _, bag in ipairs(kind == "bank" and BANK_IDS or BAG_IDS) do
        local n = NumSlots(bag)
        total = total + n
        for slot = 1, n do if not Info(bag, slot) then free = free + 1 end end
    end
    f.free:SetText(free .. " free")
    f.slots:SetText(total .. " slots")
    local x = 0
    local ids = kind == "bank" and { 5, 6, 7, 8, 9, 10, 11 } or { 1, 2, 3, 4 }
    for i, bag in ipairs(ids) do
        local ic = f.bagIcons[i]
        if not ic then
            ic = CreateFrame("Frame", nil, f.ft)
            ic:SetSize(18, 18)
            ic.t = Tex(ic, "ARTWORK", 0)
            ic.t:SetAllPoints(); ic.t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            ic:EnableMouse(true)
            ic:SetScript("OnEnter", function(s)
                -- (pointing at a bag lights its slots)
                for b2, list in pairs(f.buttons) do
                    for _, b in pairs(list) do if b:IsShown() then b:SetAlpha(b2 == s.bag and 1 or 0.3) end end
                end
            end)
            ic:SetScript("OnLeave", function() Bags:Refresh(kind) end)
            f.bagIcons[i] = ic
        end
        ic.bag = bag
        local inv = C_Container and C_Container.ContainerIDToInventoryID and C_Container.ContainerIDToInventoryID(bag)
        local tex = inv and GetInventoryItemTexture and GetInventoryItemTexture("player", inv)
        ic.t:SetTexture(tex or "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
        ic:ClearAllPoints()
        ic:SetPoint("LEFT", f.ft, "LEFT", x, 0)
        ic:Show()
        x = x + 22
    end
    f.slots:ClearAllPoints()
    f.slots:SetPoint("LEFT", f.ft, "LEFT", x + 6, 0)
    if f.keys then
        f.keys:ClearAllPoints()
        f.keys:SetPoint("LEFT", f.slots, "RIGHT", 10, 0)
        f.keys:SetAlpha(self.keys and 1 or 0.6)
    end
    if f.buy then
        local n, full = nil, true
        if GetNumBankSlots then n, full = GetNumBankSlots() end
        local cost
        if GetBankSlotCost and n and not full then
            local ok, c = pcall(GetBankSlotCost, n)
            cost = ok and c or nil
        end
        local can = cost and cost > 0
        f.buy:SetShown(can and true or false)
        if can then
            f.buy:ClearAllPoints()
            f.buy:SetPoint("LEFT", f.slots, "RIGHT", 10, 0)
            f.buy.t:SetText("Buy a bag slot · " .. (GetCoinTextureString and GetCoinTextureString(cost) or cost))
            L.Color(f.buy.bg, { 0, 0, 0, 0.35 })
        end
    end
    local m = GetMoney and GetMoney() or 0
    f.money:SetText(GetCoinTextureString and GetCoinTextureString(m) or tostring(m))
    f.sort:SetShown(self:CanSort(kind))
    f.sort.t:SetText(self.sorting and self.sorting.kind == kind and "Sorting" or "Sort")
    L.Color(f.sort.bg, { 0, 0, 0, 0.35 })
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function Bags:Search(text)
    self.query = text or ""
    self:Refresh()
end

-- Sort: the game's own where this client has it (C_Container.SortBags / SortBankBags), else ours (Round below):
-- partial stacks merged, then every item put in order (kind as the shelves have it, quality, name, id, bigger stacks
-- first), many moves per round. Special bags (herbs, soul shards, ...) and the key ring keep their items. It stops
-- in combat, when the cursor holds something or the bank closes.
local SHELF_RANK = {}
for i, sec in ipairs(Bags.SECTIONS) do SHELF_RANK[sec.key] = i end

function Bags:CanSort(kind)
    if kind == "bank" then return self.atBank and true or false end
    return true
end

local function GameSort(kind)
    local C = C_Container
    if kind == "bank" and C and C.SortBankBags then C.SortBankBags() return true end
    if kind ~= "bank" and C and C.SortBags then C.SortBags() return true end
    return false
end

-- The bags a sort may use: plain bags only (a special bag's family is not 0).
local function SortBags(kind)
    local out = {}
    for _, bag in ipairs(kind == "bank" and BANK_IDS or BAG_IDS) do
        local fam = 0
        if bag ~= 0 and bag ~= BANK and C_Container and C_Container.GetContainerNumFreeSlots then
            local _, f = C_Container.GetContainerNumFreeSlots(bag)
            fam = f or 0
        end
        if fam == 0 then
            for slot = 1, NumSlots(bag) do out[#out + 1] = { bag, slot } end
        end
    end
    return out
end

local function Key(info)
    local id = info.itemID
    local shelf = (info.quality == 0) and "junk" or (CLASS_SHELF[ClassOf(id) or -1] or "other")
    return SHELF_RANK[shelf] or 99, -(info.quality or 1), ItemName(id), id, -(info.stackCount or 1)
end

local function Before(a, b)
    local a1, a2, a3, a4, a5 = Key(a)
    local b1, b2, b3, b4, b5 = Key(b)
    if a1 ~= b1 then return a1 < b1 end
    if a2 ~= b2 then return a2 < b2 end
    if a3 ~= b3 then return a3 < b3 end
    if a4 ~= b4 then return a4 < b4 end
    return a5 < b5
end

Bags.Before = Before          -- (the sort's order, for tests)

-- One round of the sort, from what the bags hold right now (so it can never go wrong when the server refuses a move,
-- a bag changes or loot lands mid-sort): every move that doesn't touch a locked slot or a slot already used this
-- round is made at once (each move locks only its two slots; the next round starts when the server unlocks them).
--   merge  while an item has two or more partial stacks: partial stacks of it paired up, each pair one move
--   order  the target arrangement (items sorted by Key, then the free slots); slots already holding what belongs
--          there stay put; the rest follow their cycles, each move putting one item in its final slot (a swap moves
--          the displaced item to where the source was; the fewest moves a sort by swaps can make)
-- Returns the moves made this round and whether anything is left to do.
local function Round(slots)
    local C = C_Container
    local cells, locked, partial = {}, {}, {}
    for i, p in ipairs(slots) do
        local info = Info(p[1], p[2])
        cells[i] = info and info.itemID and info or false
        if info and info.isLocked then locked[i] = true end
    end
    local used = {}
    local function Free(i) return not locked[i] and not used[i] end
    local function Do(from, to)
        C.PickupContainerItem(slots[from][1], slots[from][2])
        C.PickupContainerItem(slots[to][1], slots[to][2])
        if CursorHasItem and CursorHasItem() then
            -- (the server took neither: put it back where it came from)
            C.PickupContainerItem(slots[from][1], slots[from][2])
        end
        used[from], used[to] = true, true
    end
    local made, pending = 0, false
    -- merge: per item, its partial stacks paired up
    for i, info in ipairs(cells) do
        if info then
            local stackMax = select(8, GII(info.itemID)) or 1
            if stackMax > 1 and (info.stackCount or 1) < stackMax then
                local list = partial[info.itemID] or {}
                list[#list + 1] = i
                partial[info.itemID] = list
            end
        end
    end
    for _, list in pairs(partial) do
        if #list > 1 then
            pending = true
            for k = 1, #list - 1, 2 do
                local a, b = list[k + 1], list[k]          -- (the later stack onto the earlier one)
                if Free(a) and Free(b) then Do(a, b); made = made + 1 end
            end
        end
    end
    if pending then return made, true end
    -- order: the arrangement the bags should have
    local items = {}
    for i, info in ipairs(cells) do if info then items[#items + 1] = { info = info, at = i } end end
    tsort(items, function(x, y)
        if Before(x.info, y.info) then return true end
        if Before(y.info, x.info) then return false end
        return x.at < y.at
    end)
    local function Same(a, b)
        if not a or not b then return a == b end
        return a.itemID == b.itemID and (a.stackCount or 1) == (b.stackCount or 1)
    end
    -- target[i]: the item (info) slot i should hold; nil = free
    local target = {}
    for k, it in ipairs(items) do target[k] = it.info end
    -- sources: the slots whose item is not where it belongs, by what they hold
    local fixed, want = {}, {}
    for i = 1, #slots do
        if Same(cells[i] or nil, target[i]) then fixed[i] = true end
    end
    local byItem = {}
    for i = 1, #slots do
        local c = cells[i]
        if c and not fixed[i] then
            local key = c.itemID .. ":" .. (c.stackCount or 1)
            byItem[key] = byItem[key] or {}
            tinsert(byItem[key], i)
        end
    end
    -- each wrong slot takes its item from a source holding it (preferring a source that wants this slot's item back:
    -- a two-slot cycle, one move)
    local taken = {}
    for i = 1, #slots do
        local t = target[i]
        if t and not fixed[i] then
            pending = true
            local key = t.itemID .. ":" .. (t.stackCount or 1)
            local list = byItem[key] or {}
            local pick, pickK
            for k, j in ipairs(list) do
                if not taken[j] then
                    if not pick then pick, pickK = j, k end
                    if Same(cells[i] or nil, target[j]) then pick, pickK = j, k; break end
                end
            end
            if pick then
                taken[pick] = true
                want[i] = pick
            end
        elseif not t and cells[i] then
            pending = true
        end
    end
    for i, j in pairs(want) do
        if Free(i) and Free(j) then Do(j, i); made = made + 1 end
    end
    return made, pending
end

function Bags:Sort(kind)
    kind = kind or "bags"
    if InCombatLockdown and InCombatLockdown() then return false end
    if GameSort(kind) then return true end
    if self.sorting then return false end
    if CursorHasItem and CursorHasItem() then return false end
    self.sorting = { kind = kind, slots = SortBags(kind), rounds = 0, waves = 0, idle = 0, wait = 0,
                     started = GetTime and GetTime() or 0 }
    -- (a round as soon as the server unlocks what the last one moved; the timer is only the fallback)
    self.sorter = self.sorter or CreateFrame("Frame")
    local fr = self.sorter
    pcall(fr.RegisterEvent, fr, "ITEM_LOCK_CHANGED")
    pcall(fr.RegisterEvent, fr, "BAG_UPDATE_DELAYED")
    local function Step()
        local st = Bags.sorting
        if not st then return end
        if (InCombatLockdown and InCombatLockdown()) or (CursorHasItem and CursorHasItem())
            or (st.kind == "bank" and not Bags.atBank) then Bags:StopSort() return end
        local made, pending = Round(st.slots)
        st.rounds = st.rounds + 1
        if not pending then Bags:StopSort() return end
        -- (nothing could move: everything waits for the server; give up after a while without any progress)
        if made == 0 then st.idle = st.idle + 1 else st.idle = 0; st.waves = st.waves + 1 end
        if st.idle > 200 or st.rounds > 2000 then Bags:StopSort() end
    end
    fr:SetScript("OnEvent", function() Step() end)
    fr:SetScript("OnUpdate", function(_, dt)
        local st = Bags.sorting
        if not st then return end
        st.wait = st.wait - (dt or 0)
        if st.wait > 0 then return end
        st.wait = 0.1
        Step()
    end)
    Step()
    self:Refresh(kind)
    return true
end

function Bags:StopSort()
    -- (how long it took, in seconds: tests read it)
    self.lastTime = self.sorting and GetTime and (GetTime() - (self.sorting.started or GetTime())) or nil
    self.sorting = nil
    if self.sorter then
        self.sorter:SetScript("OnUpdate", nil)
        self.sorter:SetScript("OnEvent", nil)
        self.sorter:UnregisterAllEvents()
    end
    self:Queue()
end

-- Sells every grey item in the bags (at a vendor; one per click handler run, the way the game allows it).
function Bags:SellJunk()
    if not (MerchantFrame and MerchantFrame:IsShown()) then return end
    local n = 0
    for _, s in ipairs(self:Slots("bags")) do
        if s.id and s.q == 0 and not (s.info and s.info.hasNoValue) and C_Container and C_Container.UseContainerItem then
            C_Container.UseContainerItem(s.bag, s.slot)
            n = n + 1
        end
    end
    return n
end

function Bags:ShowKeys(on)
    self.keys = on and true or false
    local f = self:Window("bags")
    if on and not f:IsShown() then f:Show() else self:Refresh("bags") end
end

function Bags:Toggle(kind)
    if not self.active then return end
    local f = self:Window(kind or "bags")
    f:SetShown(not f:IsShown())
end

function Bags:Open(kind)
    if not self.active then return end
    self:Window(kind or "bags"):Show()
end

function Bags:Close(kind)
    local f = windows[kind or "bags"]
    if f then f:Hide() end
end

---------------------------------------------------------------------------
-- Taking over from the game's bag windows
---------------------------------------------------------------------------

-- (one toggle per key press: the game's own functions call each other)
local lastToggle = 0
local function Once()
    local t = GetTime and GetTime() or 0
    if t == lastToggle then return false end
    lastToggle = t
    return true
end

local function HideGameBags()
    for i = 1, (NUM_CONTAINER_FRAMES or 13) do
        local cf = _G["ContainerFrame" .. i]
        if cf and cf:IsShown() then cf:Hide() end
    end
end

function Bags:Hook()
    if self.hooked then return end
    self.hooked = true
    for i = 1, (NUM_CONTAINER_FRAMES or 13) do
        local cf = _G["ContainerFrame" .. i]
        if cf then cf:HookScript("OnShow", function(s) if Bags.active then s:Hide() end end) end
    end
    self:HookGame()
    -- the bank: ours instead of the game's (its window never opens; leaving ours closes the bank)
    if BankFrame and BankFrame.UnregisterEvent then BankFrame:UnregisterEvent("BANKFRAME_OPENED") end
    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "BAG_UPDATE_DELAYED", "ITEM_LOCK_CHANGED", "BAG_UPDATE_COOLDOWN", "PLAYERBANKSLOTS_CHANGED",
                         "PLAYERBANKBAGSLOTS_CHANGED", "PLAYER_MONEY", "BAG_NEW_ITEMS_UPDATED", "MERCHANT_SHOW",
                         "MERCHANT_CLOSED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "GET_ITEM_INFO_RECEIVED",
                         "BAG_UPDATE" }) do
        pcall(ev.RegisterEvent, ev, e)
    end
    ev:SetScript("OnEvent", function(_, e)
        if not Bags.active then return end
        if e == "BANKFRAME_OPENED" then
            Bags.atBank = true
            Bags:Open("bank"); Bags:Open("bags")
        elseif e == "BANKFRAME_CLOSED" then
            Bags.atBank = false
            Bags:Close("bank")
        else
            Bags:Queue()
        end
    end)
end

-- The game's open / close functions, each hooked once (whichever this client has; called again later in case one
-- loads late).
function Bags:HookGame()
    self.gameHooks = self.gameHooks or {}
    local hooks = self.gameHooks
    local function H(name, fn)
        if not hooks[name] and type(_G[name]) == "function" then hooks[name] = true; hooksecurefunc(name, fn) end
    end
    H("ToggleAllBags", function() if Bags.active and Once() then HideGameBags(); Bags:Toggle("bags") end end)
    H("ToggleBackpack", function() if Bags.active and Once() then HideGameBags(); Bags:Toggle("bags") end end)
    H("ToggleBag", function(id)
        if not Bags.active or not Once() then return end
        HideGameBags()
        if id == KEYRING then Bags:ShowKeys(not (Bags.keys and windows.bags and windows.bags:IsShown())) return end
        if id and id >= 5 then Bags:Toggle("bank") else Bags:Toggle("bags") end
    end)
    H("ToggleKeyRing", function()
        if not Bags.active or not Once() then return end
        HideGameBags()
        Bags:ShowKeys(not (Bags.keys and windows.bags and windows.bags:IsShown()))
    end)
    H("OpenAllBags", function(frame)
        if not Bags.active then return end
        HideGameBags()
        Bags.openedBy = Bags.openedBy or (frame and frame.GetName and frame:GetName()) or nil
        Bags:Open("bags")
    end)
    H("CloseAllBags", function(frame)
        if not Bags.active then return end
        local by = frame and frame.GetName and frame:GetName()
        if by and Bags.openedBy and by ~= Bags.openedBy then return end
        Bags.openedBy = nil
        Bags:Close("bags")
    end)
end

-- Refreshes once soon (a burst of bag events is one refresh).
function Bags:Queue()
    if self.queued then return end
    self.queued = true
    local run = function() Bags.queued = false; Bags:Refresh() end
    if C_Timer and C_Timer.After then C_Timer.After(0.05, run) else run() end
end

function Bags:Start()
    if self.active then return end
    self.active = true
    self:Hook()
    if BankFrame and BankFrame.UnregisterEvent then BankFrame:UnregisterEvent("BANKFRAME_OPENED") end
    local Lay = ns.Layout
    if Lay then
        for _, kind in ipairs({ "bags", "bank" }) do
            local id = self:LayoutId(kind)
            if not Lay:Item(id) then
                Lay:Register(id, { name = kind == "bank" and "Bank" or "Bags", group = "Game frames",
                    order = kind == "bank" and 21 or 20, noHide = true,
                    default = kind == "bank" and { "TOPLEFT", 40, -110 } or { "BOTTOMRIGHT", -40, 150 },
                    frame = function() return Bags:Window(kind) end,
                    preview = function(on)
                        local w = Bags:Window(kind)
                        if on then w.wasShown = w:IsShown(); w:Show() elseif not w.wasShown then w:Hide() end
                    end })
            end
            Lay:Place(id)
        end
    end
end

-- Off: the game's windows again (its bank window after a reload: a replaced part).
function Bags:Stop()
    self.active = false
    for _, w in pairs(windows) do w:Hide() end
end

function Bags:OnLogin()
    Look():SetApplied("bags", Look():Key("bags"))
    if self:Wanted() then self:Start() end
    ns:On("UI_LOOK_CHANGED", function(part)
        if part ~= "bags" then return end
        if Bags:Wanted() then Bags:Start(); Bags:Refresh() else Bags:Stop() end
    end)
    ns:On("DOCK_LAID_OUT", function() if Bags.active then Bags:Queue() end end)
end
