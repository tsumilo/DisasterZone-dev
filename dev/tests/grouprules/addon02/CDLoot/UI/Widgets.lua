-- CDLoot UI/Widgets.lua
-- ns.UI: shared widget factory (windows, item buttons, scroll lists, dropdowns, menus, tabs) and
-- small colour / tooltip / chat helpers. Native WoW look; every frame is created on demand.
local addonName, ns = ...

local UI = ns:NewModule("UI")

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local UIParent = UIParent
local floor = math.floor
local format = string.format
local tinsert = table.insert

-- Fallbacks in case Constants did not load (keeps the UI alive instead of erroring).
local DEFAULT_TEX = {
    check      = "Interface\\RaidFrame\\ReadyCheck-Ready",
    cross      = "Interface\\RaidFrame\\ReadyCheck-NotReady",
    waiting    = "Interface\\RaidFrame\\ReadyCheck-Waiting",
    slotBg     = "Interface\\Buttons\\UI-Quickslot2",
    border     = "Interface\\Common\\WhiteIconFrame",
    hilight    = "Interface\\Buttons\\ButtonHilight-Square",
    rowHilight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
    star       = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1",
    classIcons = "Interface\\TargetingFrame\\UI-Classes-Circles",
}
local QUESTION_MARK_ICON = 134400

local function Tex(key)
    return (ns.TEX and ns.TEX[key]) or DEFAULT_TEX[key]
end
UI.Tex = function(_, key) return Tex(key) end

-- Human labels for BiS:GetObtainedState() results (shared by the doll, picker and others).
UI.OBTAINED_LABELS = {
    equipped = "Equipped",
    bags     = "In bags",
    bank     = "In bank",
    token    = "Have token",
    manual   = "Marked obtained",
}

function UI:OnInit() end
function UI:OnLogin() end

---------------------------------------------------------------------------
-- Small private helpers
---------------------------------------------------------------------------

local localTimers = {}
local function Debounce(key, sec, fn)
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce(key, sec, fn)
        return
    end
    if localTimers[key] then localTimers[key]:Cancel() end
    localTimers[key] = C_Timer.NewTimer(sec, function()
        localTimers[key] = nil
        fn()
    end)
end

local function ShortName(key)
    if not key then return "?" end
    if ns.Util and ns.Util.ShortName then
        return ns.Util.ShortName(key) or key
    end
    return (key:gsub("%-.*$", ""))
end

local function Hex(r, g, b)
    return format("ff%02x%02x%02x", floor((r or 1) * 255 + 0.5), floor((g or 1) * 255 + 0.5), floor((b or 1) * 255 + 0.5))
end

function UI:ColorHex(r, g, b)
    return Hex(r, g, b)
end

-- Wraps text in a colour escape from an {r,g,b} table (ns.COLORS entries).
function UI:Colorize(text, color)
    if not text then return "" end
    if type(color) ~= "table" then return text end
    return "|c" .. Hex(color[1], color[2], color[3]) .. text .. "|r"
end

function UI:Color(key)
    local c = ns.COLORS and ns.COLORS[key]
    if c then return c[1], c[2], c[3] end
    return 1, 1, 1
end

local function GetLink(itemID)
    if not itemID then return nil end
    local link
    if ns.ItemDB and ns.ItemDB.GetLink then link = ns.ItemDB:GetLink(itemID) end
    if not link and C_Item and C_Item.GetItemInfo then
        local _
        _, link = C_Item.GetItemInfo(itemID)
    end
    return link
end
UI.GetItemLink = function(_, itemID) return GetLink(itemID) end

-- Replace glyphs the default game font may not have with inline textures / ASCII.
local GLYPHS = {
    ["\226\156\147"] = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t",          -- check mark
    ["\226\156\148"] = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t",          -- heavy check mark
    ["\226\152\133"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t", -- black star
    ["\226\128\166"] = "...",                                                    -- ellipsis
}
function UI:SafeText(text)
    if type(text) ~= "string" then return text end
    for glyph, rep in pairs(GLYPHS) do
        if text:find(glyph, 1, true) then
            text = text:gsub(glyph, rep)
        end
    end
    return text
end

---------------------------------------------------------------------------
-- Chat links (with a flag so the Picker's InsertLink hook can ignore our own links)
---------------------------------------------------------------------------

local ownLinkDepth = 0
local function WithOwnLink(fn, ...)
    ownLinkDepth = ownLinkDepth + 1
    local ok, result = pcall(fn, ...)
    ownLinkDepth = ownLinkDepth - 1
    if not ok then
        geterrorhandler()(result)
        return nil
    end
    return result
end

function UI:IsOwnLinkClick()
    return ownLinkDepth > 0
end

-- Insert an item link into the active chat edit box (opens chat if none is active).
function UI:InsertLink(itemID)
    local link = GetLink(itemID)
    if not link then return false end
    local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
    if insert and WithOwnLink(insert, link) then return true end
    return false
end

function UI:LinkInChat(itemID)
    if self:InsertLink(itemID) then return true end
    local link = GetLink(itemID)
    if not link then
        ns:Print("Item information is still loading, try again in a moment.")
        return false
    end
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then
        WithOwnLink(open, link)
        return true
    end
    return false
end

-- Standard modified-click handling for anything that shows an item.
-- Returns true when the click was consumed (shift = link, ctrl = dress up, ...).
function UI:HandleModifiedItemClick(itemID)
    if not itemID then return false end
    local shift = IsShiftKeyDown()
    if not shift and not IsModifiedClick() then return false end
    local link = GetLink(itemID)
    if link and IsModifiedClick() and HandleModifiedItemClick then
        if WithOwnLink(HandleModifiedItemClick, link) then return true end
    end
    if shift then
        if link then self:InsertLink(itemID) end
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Colours, names, icons
---------------------------------------------------------------------------

function UI:ClassColor(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function ClassHex(classFile)
    if classFile and ns.Util and ns.Util.ClassColorHex then
        local hex = ns.Util.ClassColorHex(classFile)
        if type(hex) == "string" and #hex == 8 then return hex end
    end
    return Hex(UI:ClassColor(classFile))
end

function UI:ColoredName(key, classFile)
    if not classFile and key and ns.Guild and ns.Guild.GetClass then
        classFile = ns.Guild:GetClass(key)
    end
    return "|c" .. ClassHex(classFile) .. ShortName(key) .. "|r"
end

function UI:ClassIcon(texture, classFile)
    if not texture then return end
    local coords = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
    if coords then
        texture:SetTexture(Tex("classIcons"))
        texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        texture:Show()
    else
        texture:Hide()
    end
end

function UI:QualityColor(q)
    q = tonumber(q)
    if not q then return 1, 1, 1 end
    if C_Item and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(q)
        if r then return r, g, b end
    end
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function ItemNameQuality(itemID)
    if not itemID then return nil end
    if ns.ItemDB and ns.ItemDB.GetInfo then
        local name, _, quality = ns.ItemDB:GetInfo(itemID)
        return name, quality
    end
    if C_Item and C_Item.GetItemInfo then
        local name, _, quality = C_Item.GetItemInfo(itemID)
        return name, quality
    end
    return nil
end

-- Quality-coloured item name, or a grey "Loading..." placeholder (item load is requested).
function UI:ItemText(itemID)
    local name, quality = ItemNameQuality(itemID)
    if not name then
        return "|cff808080Loading...|r", true
    end
    return "|c" .. Hex(self:QualityColor(quality)) .. name .. "|r", false
end

local emptySlotCache = {}
function UI:EmptySlotTexture(sid)
    if not sid then return Tex("slotBg") end
    local cached = emptySlotCache[sid]
    if cached then return cached end
    local slot = ns.SLOTS and ns.SLOTS[sid]
    local tex
    if slot and slot.slotName and GetInventorySlotInfo then
        local ok, _, texture = pcall(GetInventorySlotInfo, slot.slotName)
        if ok then tex = texture end
    end
    tex = tex or Tex("slotBg")
    emptySlotCache[sid] = tex
    return tex
end

---------------------------------------------------------------------------
-- Tooltips & glow
---------------------------------------------------------------------------

function UI:SetItemTooltip(owner, itemID, extraFn)
    if not owner then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if itemID then GameTooltip:SetItemByID(itemID) end
    if extraFn then extraFn(GameTooltip) end
    if GameTooltip:NumLines() > 0 then
        GameTooltip:Show()
    else
        GameTooltip:Hide()
    end
end

function UI:HideTooltip()
    GameTooltip:Hide()
end

-- Simple text tooltip helper: lines = { "title", "line", {text, r, g, b}, ... }
function UI:SetTextTooltip(owner, lines, anchor)
    if not owner or type(lines) ~= "table" then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    for i, line in ipairs(lines) do
        if type(line) == "table" then
            GameTooltip:AddLine(line[1], line[2] or 1, line[3] or 1, line[4] or 1, line.wrap)
        elseif i == 1 then
            GameTooltip:AddLine(line, 1, 0.82, 0)
        else
            GameTooltip:AddLine(line, 1, 1, 1, true)
        end
    end
    GameTooltip:Show()
end

function UI:Glow(frame, on)
    if not frame then return end
    local glow = LibStub and LibStub("LibCustomGlow-1.0", true)
    if not glow then return end
    if on then
        if not frame.__cdlGlow then
            glow.ButtonGlow_Start(frame)
            frame.__cdlGlow = true
        end
    elseif frame.__cdlGlow then
        glow.ButtonGlow_Stop(frame)
        frame.__cdlGlow = nil
    end
end

---------------------------------------------------------------------------
-- Drag & drop from bags
---------------------------------------------------------------------------

function UI:GetCursorItem()
    local kind, itemID = GetCursorInfo()
    if kind == "item" and tonumber(itemID) then
        return tonumber(itemID)
    end
    return nil
end

-- Makes `frame` accept items dropped from the cursor: fn(frame, itemID).
-- Sets frame.__cdlDropTime so an OnClick in the same frame can be ignored.
function UI:AttachItemDrop(frame, fn)
    if not frame or not fn then return end
    local function handler(self)
        local itemID = UI:GetCursorItem()
        if not itemID then return end
        ClearCursor()
        self.__cdlDropTime = GetTime()
        fn(self, itemID)
    end
    frame:HookScript("OnReceiveDrag", handler)
    frame:HookScript("OnMouseUp", handler)
end

---------------------------------------------------------------------------
-- Windows & panels
---------------------------------------------------------------------------

local function SavePosition(f)
    local name = f.cdlName
    if not name or f.noSavePosition or not (ns.db and ns.db.settings) then return end
    local point, _, relPoint, x, y = f:GetPoint(1)
    if not point then return end
    ns.db.settings.windows = ns.db.settings.windows or {}
    ns.db.settings.windows[name] = { point, relPoint or point, floor((x or 0) + 0.5), floor((y or 0) + 0.5) }
end

function UI:RestorePosition(f)
    f:ClearAllPoints()
    local name = f.cdlName
    local windows = ns.db and ns.db.settings and ns.db.settings.windows
    local pos = name and not f.noSavePosition and type(windows) == "table" and windows[name]
    if type(pos) == "table" and type(pos[1]) == "string" then
        local ok = pcall(f.SetPoint, f, pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
        if ok then return end
        f:ClearAllPoints()
    end
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

-- opts (optional, CDLoot extension): { noSavePosition = true }
function UI:CreateWindow(name, title, width, height, opts)
    local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
    f.cdlName = name
    f.noSavePosition = opts and opts.noSavePosition or nil
    f:SetSize(width or 400, height or 300)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    if name and UISpecialFrames then
        tinsert(UISpecialFrames, name)
    end

    local titleText = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
    if not titleText then
        titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        titleText:SetPoint("TOP", f, "TOP", 0, -5)
    end
    titleText:SetText(title or "")
    f.titleText = titleText
    f.SetWindowTitle = function(self, text) self.titleText:SetText(text or "") end

    local content = CreateFrame("Frame", nil, f)
    if f.Inset then
        content:SetPoint("TOPLEFT", f.Inset, "TOPLEFT", 3, -3)
        content:SetPoint("BOTTOMRIGHT", f.Inset, "BOTTOMRIGHT", -3, 3)
    else
        content:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -26)
        content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
    end
    f.content = content

    UI:RestorePosition(f)
    return f
end

local PANEL_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

function UI:CreatePanel(parent)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    p:SetBackdrop(PANEL_BACKDROP)
    p:SetBackdropColor(0, 0, 0, 0.6)
    p:SetBackdropBorderColor(0.45, 0.45, 0.45, 0.9)
    return p
end

function UI:CreateLabel(parent, text, fontObject)
    local fs = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    return fs
end

---------------------------------------------------------------------------
-- Item button
---------------------------------------------------------------------------

-- Buttons whose item quality is not cached yet; re-coloured on ITEMINFO_READY.
local pendingButtons = setmetatable({}, { __mode = "k" })

local function SetDesat(texture, amount)
    if texture.SetDesaturation then
        texture:SetDesaturation(amount)
    else
        texture:SetDesaturated(amount > 0)
    end
end

local function ApplyQuality(b)
    local id = b.itemID
    if not id then
        pendingButtons[b] = nil
        b.border:Hide()
        return
    end
    local q
    if ns.ItemDB and ns.ItemDB.GetQuality then
        q = ns.ItemDB:GetQuality(id)
    elseif C_Item and C_Item.GetItemQualityByID then
        q = C_Item.GetItemQualityByID(id)
    end
    if q == nil then
        pendingButtons[b] = true
        b.border:Hide()
        return
    end
    pendingButtons[b] = nil
    if q >= 2 then
        local r, g, bl = UI:QualityColor(q)
        b.border:SetVertexColor(r, g, bl, 0.9)
        b.border:Show()
    else
        b.border:Hide()
    end
end

local function ApplyState(b)
    local state = b.state
    local icon = b.icon
    b:SetAlpha(1)
    b.overlay:Hide()
    if not b.itemID then
        SetDesat(icon, 1)
        icon:SetAlpha(0.6)
        if state == "dim" then b:SetAlpha(0.35) end
        return
    end
    icon:SetAlpha(1)
    SetDesat(icon, 0)
    if state == "obtained" then
        SetDesat(icon, 0.6)
        b.overlay:SetTexture(Tex("check"))
        b.overlay:Show()
    elseif state == "equipped" then
        b.overlay:SetTexture(Tex("check"))
        b.overlay:Show()
    elseif state == "awarded" then
        b.overlay:SetTexture(Tex("star"))
        b.overlay:Show()
    elseif state == "dim" then
        b:SetAlpha(0.35)
    end
end

local ItemButtonMethods = {}

-- Sets the item (nil = empty slot look). Resets the state to normal; call SetState afterwards.
function ItemButtonMethods:SetItem(itemID, emptyTexture)
    itemID = tonumber(itemID)
    if itemID and itemID <= 0 then itemID = nil end
    self.itemID = itemID
    self.state = nil
    if itemID then
        local icon = (ns.ItemDB and ns.ItemDB.GetIcon and ns.ItemDB:GetIcon(itemID))
            or (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID))
            or QUESTION_MARK_ICON
        self.icon:SetTexture(icon)
    else
        self.icon:SetTexture(emptyTexture or Tex("slotBg"))
    end
    ApplyQuality(self)
    ApplyState(self)
end

function ItemButtonMethods:SetState(state)
    self.state = state
    ApplyState(self)
end

function ItemButtonMethods:SetBadge(text, r, g, b)
    if text == nil or text == "" then
        self.badge:Hide()
        return
    end
    self.badge:SetText(text)
    self.badge:SetTextColor(r or 1, g or 0.82, b or 0)
    self.badge:Show()
end

local function ItemButton_OnEnter(self)
    if not self.itemID and not self.onTooltip then return end
    local owner = self
    UI:SetItemTooltip(owner, self.itemID, self.onTooltip and function(tt) self.onTooltip(self, tt) end)
end

local function ItemButton_OnLeave()
    GameTooltip:Hide()
end

local function ItemButton_OnClick(self, mouseButton)
    if self.__cdlDropTime and self.__cdlDropTime == GetTime() then return end
    if self.itemID and UI:HandleModifiedItemClick(self.itemID) then return end
    if self.onClick then self.onClick(self, mouseButton) end
end

function UI:CreateItemButton(parent, size)
    size = size or 36
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetTexture(Tex("slotBg"))
    b.bg:SetVertexColor(0.25, 0.25, 0.25, 1)

    local inset = size >= 24 and 2 or 1
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", inset, -inset)
    b.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetAllPoints()
    b.border:SetTexture(Tex("border"))
    b.border:Hide()

    local ov = math.max(8, floor(size * 0.4 + 0.5))
    b.overlay = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.overlay:SetSize(ov, ov)
    b.overlay:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -2)
    b.overlay:Hide()

    b.badge = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.badge:SetPoint("TOPRIGHT", b, "TOPRIGHT", 2, 1)
    b.badge:SetJustifyH("RIGHT")
    b.badge:Hide()

    b:SetHighlightTexture(Tex("hilight"), "ADD")

    for k, fn in pairs(ItemButtonMethods) do b[k] = fn end

    b:SetScript("OnEnter", ItemButton_OnEnter)
    b:SetScript("OnLeave", ItemButton_OnLeave)
    b:SetScript("OnClick", ItemButton_OnClick)
    UI:AttachItemDrop(b, function(self, itemID)
        if self.onReceiveItem then self.onReceiveItem(self, itemID) end
    end)

    b:SetItem(nil)
    return b
end

ns:On("ITEMINFO_READY", function()
    for b in pairs(pendingButtons) do
        if b.itemID then
            ApplyQuality(b)
        else
            pendingButtons[b] = nil
        end
    end
end)

---------------------------------------------------------------------------
-- Scroll list (modern ScrollBox; call shapes as in Auctionator RecentsContainer/ListsContainer)
---------------------------------------------------------------------------

-- extentFn (optional, CDLoot extension): function(data) -> row height, for mixed-height rows.
function UI:CreateScrollList(parent, rowHeight, initRow, extentFn)
    rowHeight = rowHeight or 20
    local list = { data = {} }

    local frame = CreateFrame("Frame", nil, parent)
    list.frame = frame

    local box = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    box:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 0)
    list.box = box

    local bar = CreateFrame("EventFrame", nil, frame, "WowTrimScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
    list.bar = bar

    local view = CreateScrollBoxListLinearView(0, 0, 0, 0)
    view:SetElementExtent(rowHeight)
    if extentFn and view.SetElementExtentCalculator then
        view:SetElementExtentCalculator(function(_, data)
            return extentFn(data) or rowHeight
        end)
    end
    view:SetElementInitializer("Button", function(row, data)
        row.__cdlData = data
        initRow(row, data)
    end)
    if view.SetPanExtent then view:SetPanExtent(rowHeight * 2) end
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    list.view = view

    list.emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    list.emptyText:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -24)
    list.emptyText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -36, -24)
    list.emptyText:SetJustifyH("CENTER")
    list.emptyText:Hide()

    -- resetScroll (optional): true jumps back to the top instead of keeping the position.
    function list:SetData(array, resetScroll)
        self.data = type(array) == "table" and array or {}
        self.box:SetDataProvider(CreateDataProvider(self.data), not resetScroll)
        self.emptyText:SetShown(#self.data == 0 and (self.emptyText:GetText() or "") ~= "")
    end

    -- Re-runs initRow on every visible row (e.g. after item info arrived).
    function list:Refresh()
        self.box:ForEachFrame(function(row)
            local data = row.__cdlData
            if data == nil and row.GetElementData then data = row:GetElementData() end
            if data ~= nil then initRow(row, data) end
        end)
    end

    function list:GetData()
        return self.data
    end

    function list:SetEmptyText(text)
        self.emptyText:SetText(text or "")
        self.emptyText:SetShown(#self.data == 0 and (text or "") ~= "")
    end

    function list:ScrollToTop()
        if self.box.ScrollToBegin then self.box:ScrollToBegin() end
    end

    return list
end

---------------------------------------------------------------------------
-- Buttons, checkboxes, search box
---------------------------------------------------------------------------

function UI:CreateButton(parent, text, width, height, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetText(text or "")
    local w = width
    if not w then
        local fs = b:GetFontString()
        w = (fs and fs:GetStringWidth() or 60) + 24
    end
    b:SetSize(w, height or 22)
    if onClick then
        b:SetScript("OnClick", function(self, mouseButton) onClick(self, mouseButton) end)
    end
    return b
end

function UI:CreateCheckbox(parent, label, getter, setter)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    -- Hide the template's own label (name differs between clients) and use our own.
    if cb.Text then cb.Text:SetText("") end
    if cb.text then cb.text:SetText("") end
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.label:SetJustifyH("LEFT")
    cb.label:SetText(label or "")
    cb:SetHitRectInsets(0, -(cb.label:GetStringWidth() + 4), 0, 0)

    function cb:Refresh()
        self:SetChecked(getter and getter() and true or false)
    end
    function cb:SetLabel(text)
        self.label:SetText(text or "")
        self:SetHitRectInsets(0, -(self.label:GetStringWidth() + 4), 0, 0)
    end
    cb:SetScript("OnClick", function(self)
        if setter then setter(self:GetChecked() and true or false) end
    end)
    cb:HookScript("OnEnter", function(self)
        if self.tooltipText then
            UI:SetTextTooltip(self, { self.label:GetText() or "", self.tooltipText })
        end
    end)
    cb:HookScript("OnLeave", function() GameTooltip:Hide() end)
    cb:Refresh()
    return cb
end

local searchBoxCount = 0
-- placeholder (optional, CDLoot extension): instruction text shown while empty.
function UI:CreateSearchBox(parent, width, onChanged, placeholder)
    searchBoxCount = searchBoxCount + 1
    local key = "ui-search-" .. searchBoxCount
    local eb = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
    eb:SetSize(width or 200, 20)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(60)
    if placeholder and eb.Instructions then eb.Instructions:SetText(placeholder) end
    eb:HookScript("OnTextChanged", function(self)
        if not onChanged then return end
        Debounce(key, 0.2, function() onChanged(self:GetText() or "") end)
    end)
    eb:HookScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return eb
end

---------------------------------------------------------------------------
-- Dropdowns & menus (MenuUtil; pattern from Leatrix_Plus / Auctionator FilterKeySelector)
---------------------------------------------------------------------------

local function ModernDropdownAvailable()
    if not MenuUtil then return false end
    if DoesTemplateExist and not DoesTemplateExist("WowStyle1DropdownTemplate") then return false end
    return true
end

local NIL_VALUE = {}   -- stands in for option values that are nil (radio data can't be nil)

local function FindOption(options, value)
    for _, opt in ipairs(options) do
        if opt.value == value then return opt end
    end
    return nil
end

function UI:CreateDropdown(parent, width, getOptions, getSelected, onSelect)
    width = width or 150
    local function IsSelected(data)
        if data == NIL_VALUE then data = nil end
        return getSelected() == data
    end
    local function SetSelected(data)
        if data == NIL_VALUE then data = nil end
        onSelect(data)
    end

    if ModernDropdownAvailable() then
        local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
        dd:SetWidth(width)
        if dd.SetDefaultText then dd:SetDefaultText("-") end
        dd:SetupMenu(function(_, root)
            for _, opt in ipairs(getOptions() or {}) do
                if opt.isTitle then
                    root:CreateTitle(opt.text or "")
                else
                    local value = opt.value
                    if value == nil then value = NIL_VALUE end
                    local radio = root:CreateRadio(opt.text or tostring(opt.value), IsSelected, SetSelected, value)
                    if opt.disabled and radio and radio.SetEnabled then radio:SetEnabled(false) end
                    if opt.tooltip and radio and radio.SetTooltip then
                        radio:SetTooltip(function(tooltip)
                            tooltip:AddLine(opt.text or "", 1, 0.82, 0)
                            tooltip:AddLine(opt.tooltip, 1, 1, 1, true)
                        end)
                    end
                end
            end
        end)
        function dd:Refresh()
            self:GenerateMenu()
        end
        return dd
    end

    -- Fallback: a plain button that opens a context menu, or cycles options without MenuUtil.
    local b = UI:CreateButton(parent, "", width, 22)
    local function Update()
        local opt = FindOption(getOptions() or {}, getSelected())
        b:SetText(opt and opt.text or "-")
    end
    b:SetScript("OnClick", function(self)
        local options = getOptions() or {}
        if MenuUtil and MenuUtil.CreateContextMenu then
            UI:ContextMenu(self, function(root)
                for _, opt in ipairs(options) do
                    if not opt.isTitle then
                        local value = opt.value
                        if value == nil then value = NIL_VALUE end
                        root:CreateRadio(opt.text or tostring(opt.value), IsSelected, function(v) SetSelected(v); Update() end, value)
                    end
                end
            end)
            return
        end
        local selectable = {}
        for _, opt in ipairs(options) do
            if not opt.isTitle and not opt.disabled then selectable[#selectable + 1] = opt end
        end
        if #selectable == 0 then return end
        local cur = getSelected()
        local nextIndex = 1
        for i, opt in ipairs(selectable) do
            if opt.value == cur then nextIndex = (i % #selectable) + 1 break end
        end
        onSelect(selectable[nextIndex].value)
        Update()
    end)
    b.Refresh = Update
    Update()
    return b
end

function UI:ContextMenu(owner, build)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        if ns.Debug then ns:Debug("MenuUtil unavailable; context menu skipped") end
        return nil
    end
    return MenuUtil.CreateContextMenu(owner, function(_, root) build(root) end)
end

-- CDLoot extension: a dropdown-looking button whose menu holds actions (build(root) as in ContextMenu).
-- The menu is regenerated on hover so it always reflects the current state.
function UI:CreateMenuButton(parent, text, width, build)
    if ModernDropdownAvailable() then
        local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
        dd:SetWidth(width or 120)
        if dd.SetDefaultText then dd:SetDefaultText(text or "") end
        dd:SetupMenu(function(_, root) build(root) end)
        dd:HookScript("OnEnter", function(self)
            if not (self.IsMenuOpen and self:IsMenuOpen()) then self:GenerateMenu() end
        end)
        function dd:Refresh()
            self:GenerateMenu()
        end
        return dd
    end
    local b = UI:CreateButton(parent, text, width, 22, function(self)
        UI:ContextMenu(self, build)
    end)
    b.Refresh = function() end
    return b
end

---------------------------------------------------------------------------
-- Searchable dropdown (CDLoot extension, ADDENDUM E §30)
-- A SearchBoxTemplate edit box with a list panel below it (ScrollBox, at most ~10 visible rows).
-- Typing filters (case-insensitive substring), Up/Down (or Tab) move the highlight, Enter toggles the
-- highlighted (top) match, Escape closes. A click outside (GLOBAL_MOUSE_DOWN, as GudaBags does on this
-- client) also closes it. Each row: checkbox, class icon, class-coloured name, grey note on the right.
--
-- opts = {
--   getItems    = function() -> array of entries (required). An entry is
--                 { key=, text= (plain name; searched), classFile=, note= (grey, right side),
--                   dim= (offline look), fixed= (text; shown checked, cannot be toggled), search= (extra
--                   searchable text) } or a section header { header = "text" }.
--   isChecked   = function(key, entry) -> bool
--   onToggle    = function(key, entry)      (the rows are repainted afterwards)
--   onTooltip   = function(tooltip, entry)  (optional extra tooltip lines)
--   placeholder = "Search...", emptyText = "No matches.", maxRows = 10, rowHeight = 20,
--   panelWidth  = width of the list panel (default: the widget width),
--   toggle      = { label =, get = function() -> bool, set = function(bool) }  (optional footer checkbox)
-- }
-- Returns { frame, editBox, panel, list, Open, Close, Toggle, IsOpen, Refresh, RefreshRows, GetShown,
--           GetMatches, GetActive, MoveActive, ToggleActive, ToggleEntry, SetEnabled, IsEnabled, SetText }.
---------------------------------------------------------------------------

local SD_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
local SD_PAD = 8
local SD_FOOTER_H = 22
local SD_CHECK_BOX = "Interface\\Buttons\\UI-CheckBox-Up"
local SD_CHECK_MARK = "Interface\\Buttons\\UI-CheckBox-Check"

local function SDTrim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function SDEventValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then
        return C_EventUtils.IsEventValid(event) and true or false
    end
    return true
end

function UI:CreateSearchDropdown(parent, width, opts)
    opts = type(opts) == "table" and opts or {}
    width = tonumber(width) or 220
    local rowHeight = tonumber(opts.rowHeight) or 20
    local maxRows = math.max(1, tonumber(opts.maxRows) or 10)
    local sd = { items = {}, shown = {}, matches = {}, active = 1, enabled = true }

    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(width, 22)
    sd.frame = holder

    local eb = CreateFrame("EditBox", nil, holder, "SearchBoxTemplate")
    eb:SetPoint("LEFT", holder, "LEFT", 6, 0)
    eb:SetPoint("RIGHT", holder, "RIGHT", -26, 0)
    eb:SetHeight(20)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(48)
    if opts.placeholder and eb.Instructions then eb.Instructions:SetText(opts.placeholder) end
    sd.editBox = eb

    local arrow = CreateFrame("Button", nil, holder)
    arrow:SetSize(24, 24)
    arrow:SetPoint("RIGHT", holder, "RIGHT", 0, 0)
    arrow:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrow:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down")
    arrow:SetDisabledTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Disabled")
    arrow:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    sd.arrow = arrow

    local panel = CreateFrame("Frame", nil, holder, "BackdropTemplate")
    panel:SetBackdrop(SD_BACKDROP)
    panel:SetBackdropColor(0.05, 0.05, 0.05, 0.96)
    panel:SetBackdropBorderColor(0.65, 0.65, 0.65, 1)
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetToplevel(true)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -2)
    panel:SetWidth(tonumber(opts.panelWidth) or width)
    panel:SetHeight(SD_PAD + rowHeight + 4 + SD_FOOTER_H + 6)
    panel:Hide()
    sd.panel = panel

    local function RowChecked(e)
        if e.fixed then return true end
        return (opts.isChecked and opts.isChecked(e.key, e)) and true or false
    end

    local function RowClick(row)
        local e = row.cdlEntry
        if not e or e.header then return end
        for i, m in ipairs(sd.matches) do
            if m == e then sd.active = i break end
        end
        sd:ToggleEntry(e)
        if sd.enabled and eb:IsVisible() then eb:SetFocus() end
    end

    local function RowEnter(row)
        local e = row.cdlEntry
        if not e or e.header then return end
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(UI:ColoredName(e.key, e.classFile))
        if e.note and e.note ~= "" then GameTooltip:AddLine(e.note, 0.8, 0.8, 0.8) end
        if e.dim then GameTooltip:AddLine("Offline", 0.6, 0.6, 0.6) end
        if opts.onTooltip then opts.onTooltip(GameTooltip, e) end
        if e.fixed then
            GameTooltip:AddLine(e.fixed .. ": always on the council", 0.6, 0.6, 0.6, true)
        else
            GameTooltip:AddLine(RowChecked(e) and "Click to remove" or "Click to add", 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()
    end

    local function SetupRow(row)
        row.cdlSD = true
        row:RegisterForClicks("LeftButtonUp")
        row.activeTex = row:CreateTexture(nil, "BACKGROUND")
        row.activeTex:SetAllPoints()
        row.activeTex:SetColorTexture(1, 0.82, 0, 0.14)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetTexture(Tex("rowHilight"))
        row.hl:SetBlendMode("ADD")
        row.hl:SetAlpha(0.45)
        row.box = row:CreateTexture(nil, "ARTWORK")
        row.box:SetSize(18, 18)
        row.box:SetPoint("LEFT", row, "LEFT", 1, 0)
        row.box:SetTexture(SD_CHECK_BOX)
        row.check = row:CreateTexture(nil, "OVERLAY")
        row.check:SetSize(18, 18)
        row.check:SetPoint("CENTER", row.box, "CENTER", 0, 0)
        row.check:SetTexture(SD_CHECK_MARK)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.icon:SetPoint("LEFT", row, "LEFT", 22, 0)
        row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.note:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.note:SetJustifyH("RIGHT")
        row.note:SetWordWrap(false)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row, "LEFT", 40, 0)
        row.name:SetPoint("RIGHT", row.note, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.header = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.header:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.header:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.header:SetJustifyH("LEFT")
        row:SetScript("OnClick", RowClick)
        row:SetScript("OnEnter", RowEnter)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local function InitRow(row, e)
        if not row.cdlSD then SetupRow(row) end
        row.cdlEntry = e
        if e.header then
            row.header:SetText(e.header)
            row.header:Show()
            row.box:Hide()
            row.check:Hide()
            row.icon:Hide()
            row.name:SetText("")
            row.note:SetText("")
            row.hl:SetAlpha(0)
            row.activeTex:Hide()
            return
        end
        row.header:Hide()
        row.hl:SetAlpha(0.45)
        row.box:Show()
        row.check:SetShown(RowChecked(e))
        row.check:SetDesaturated(e.fixed and true or false)
        row.box:SetAlpha(e.fixed and 0.5 or 1)
        UI:ClassIcon(row.icon, e.classFile)
        row.icon:SetAlpha(e.dim and 0.5 or 1)
        local text = e.text or ShortName(e.key)
        if e.dim then
            row.name:SetText("|cff808080" .. text .. "|r")
        else
            row.name:SetText("|c" .. ClassHex(e.classFile) .. text .. "|r")
        end
        row.note:SetText(e.fixed or e.note or "")
        row.activeTex:SetShown(e == sd.matches[sd.active])
    end

    local list = UI:CreateScrollList(panel, rowHeight, InitRow)
    list.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", SD_PAD, -SD_PAD)
    list.frame:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -SD_PAD, -SD_PAD)
    list.frame:SetHeight(rowHeight)
    sd.list = list

    local empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("TOPLEFT", panel, "TOPLEFT", SD_PAD + 4, -SD_PAD - 4)
    empty:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -SD_PAD, -SD_PAD - 4)
    empty:SetJustifyH("LEFT")
    empty:SetText(opts.emptyText or "No matches.")
    empty:Hide()
    sd.emptyText = empty

    local footer = CreateFrame("Frame", nil, panel)
    footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", SD_PAD, 5)
    footer:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -SD_PAD, 5)
    footer:SetHeight(SD_FOOTER_H)
    footer.count = footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer.count:SetPoint("RIGHT", footer, "RIGHT", -2, 0)
    footer.count:SetJustifyH("RIGHT")
    sd.footer = footer
    if type(opts.toggle) == "table" then
        local t = opts.toggle
        footer.check = UI:CreateCheckbox(footer, t.label or "", t.get, function(value)
            if t.set then t.set(value and true or false) end
            sd:Refresh(true)
            if sd.enabled and eb:IsVisible() then eb:SetFocus() end
        end)
        footer.check:SetPoint("LEFT", footer, "LEFT", -4, 0)
        sd.toggleCheck = footer.check
    end

    -- Sizes the panel to the shown rows (1..maxRows) and hides the scroll bar when everything fits.
    local function Layout()
        local n = #sd.shown
        local visible = math.max(1, math.min(maxRows, n))
        local listH = visible * rowHeight
        list.frame:SetHeight(listH)
        local scroll = n > maxRows
        list.bar:SetShown(scroll)
        list.box:ClearAllPoints()
        list.box:SetPoint("TOPLEFT", list.frame, "TOPLEFT", 0, 0)
        list.box:SetPoint("BOTTOMRIGHT", list.frame, "BOTTOMRIGHT", scroll and -20 or 0, 0)
        empty:SetShown(n == 0)
        local m = #sd.matches
        footer.count:SetText(n == 0 and "" or (m == 1 and "1 match" or (m .. " matches")))
        panel:SetHeight(SD_PAD + listH + 4 + SD_FOOTER_H + 6)
    end

    -- Re-reads the items, applies the search text. keepActive: keep the highlighted row and scroll.
    function sd:Refresh(keepActive)
        local items = opts.getItems and opts.getItems() or {}
        self.items = type(items) == "table" and items or {}
        local q = SDTrim(eb:GetText() or ""):lower()
        local shown, matches, header = {}, {}, nil
        for _, e in ipairs(self.items) do
            if type(e) == "table" then
                if e.header then
                    header = e
                elseif e.key ~= nil then
                    local hay = ((e.text or ShortName(e.key)) .. " " .. (e.search or "")):lower()
                    if q == "" or hay:find(q, 1, true) then
                        if header then
                            shown[#shown + 1] = header
                            header = nil
                        end
                        shown[#shown + 1] = e
                        if not e.fixed then matches[#matches + 1] = e end
                    end
                end
            end
        end
        self.shown, self.matches = shown, matches
        if not keepActive or self.active > #matches then self.active = 1 end
        if panel:IsShown() then
            Layout()
            list:SetData(shown, not keepActive)
        end
    end

    function sd:RefreshRows()
        if panel:IsShown() then list:Refresh() end
    end

    function sd:IsOpen()
        return panel:IsShown() and true or false
    end

    function sd:Open()
        if not self.enabled or not holder:IsVisible() then return false end
        if not panel:IsShown() then panel:Show() end
        self:Refresh()
        return true
    end

    function sd:Close()
        if not panel:IsShown() then return end
        panel:Hide()
        if not opts.keepText and (eb:GetText() or "") ~= "" then eb:SetText("") end
    end

    function sd:Toggle()
        if self:IsOpen() then
            self:Close()
        elseif self:Open() then
            eb:SetFocus()
        end
    end

    function sd:GetShown() return self.shown end
    function sd:GetMatches() return self.matches end
    function sd:GetActive() return self.matches[self.active] end

    -- Toggles one entry through opts.onToggle (fixed entries and headers are ignored).
    function sd:ToggleEntry(e)
        if type(e) ~= "table" or e.header or e.fixed or not self.enabled then return false end
        if opts.onToggle then opts.onToggle(e.key, e) end
        self:RefreshRows()
        return true
    end

    function sd:ToggleActive()
        return self:ToggleEntry(self.matches[self.active] or self.matches[1])
    end

    function sd:MoveActive(delta)
        local n = #self.matches
        if n == 0 then return end
        if not panel:IsShown() then self:Open() end
        self.active = ((self.active - 1 + (tonumber(delta) or 1)) % n) + 1
        self:RefreshRows()
        local target = self.matches[self.active]
        local box = list.box
        if target and box.FindElementDataIndexByPredicate and box.ScrollToElementDataIndex then
            local index = box:FindElementDataIndexByPredicate(function(d) return d == target end)
            if index then box:ScrollToElementDataIndex(index) end
        end
    end

    function sd:SetEnabled(on)
        on = on and true or false
        self.enabled = on
        if eb.SetEnabled then eb:SetEnabled(on) end
        arrow:SetEnabled(on)
        holder:SetAlpha(on and 1 or 0.5)
        if not on then
            self:Close()
            eb:ClearFocus()
        end
    end

    function sd:IsEnabled()
        return self.enabled
    end

    function sd:SetText(text)
        eb:SetText(text or "")
        if panel:IsShown() then self:Refresh() end
    end

    -- Keyboard: typing filters, Enter toggles the highlighted match, Up/Down/Tab move, Escape closes.
    eb:HookScript("OnTextChanged", function(_, userInput)
        if userInput and not panel:IsShown() then
            sd:Open()
        elseif panel:IsShown() then
            sd:Refresh()
        end
    end)
    eb:HookScript("OnEditFocusGained", function()
        if not panel:IsShown() then sd:Open() end
    end)
    eb:HookScript("OnEditFocusLost", function()
        C_Timer.After(0.2, function()
            if panel:IsShown() and not eb:HasFocus() and not panel:IsMouseOver() and not holder:IsMouseOver() then
                sd:Close()
            end
        end)
    end)
    eb:SetScript("OnEnterPressed", function(self)
        if not panel:IsShown() then
            sd:Open()
            return
        end
        if sd:ToggleActive() then self:HighlightText() end
    end)
    eb:SetScript("OnEscapePressed", function(self)
        sd:Close()
        self:ClearFocus()
    end)
    eb:SetScript("OnArrowPressed", function(_, key)
        if key == "UP" then
            sd:MoveActive(-1)
        elseif key == "DOWN" then
            sd:MoveActive(1)
        end
    end)
    eb:SetScript("OnTabPressed", function()
        sd:MoveActive(IsShiftKeyDown() and -1 or 1)
    end)

    arrow:SetScript("OnClick", function() sd:Toggle() end)

    -- A click anywhere outside the widget closes the list.
    panel:SetScript("OnShow", function(self)
        if SDEventValid("GLOBAL_MOUSE_DOWN") then self:RegisterEvent("GLOBAL_MOUSE_DOWN") end
    end)
    panel:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    panel:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" and not self:IsMouseOver() and not holder:IsMouseOver() then
            sd:Close()
        end
    end)
    holder:SetScript("OnHide", function() sd:Close() end)

    return sd
end

---------------------------------------------------------------------------
-- Bottom tabs (CharacterFrameTabButtonTemplate, as GudaBags / LoonBestInSlot on this client)
---------------------------------------------------------------------------

local tabSetCount = 0

function UI:CreateTabs(frame, tabs, onSelect)
    tabSetCount = tabSetCount + 1
    local baseName = (frame:GetName() or ("CDLootTabSet" .. tabSetCount))
    if tabSetCount > 1 or not frame:GetName() then
        baseName = baseName .. "Set" .. tabSetCount
    end

    local obj = { frame = frame, buttons = {}, byKey = {}, selected = nil }
    frame.Tabs = {}

    for i, def in ipairs(tabs or {}) do
        local tab = CreateFrame("Button", baseName .. "Tab" .. i, frame, "CharacterFrameTabButtonTemplate")
        tab:SetID(i)
        tab:SetText(def.label or def.key)
        tab.cdlKey = def.key
        tab.cdlShown = true
        if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end
        tab:SetScript("OnClick", function(self)
            if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
            obj:Select(self.cdlKey)
        end)
        obj.buttons[i] = tab
        obj.byKey[def.key] = tab
        frame.Tabs[i] = tab
    end
    PanelTemplates_SetNumTabs(frame, #obj.buttons)
    -- keep the tabs on screen together with the window
    if frame.SetClampRectInsets then frame:SetClampRectInsets(0, 0, 0, -30) end

    function obj:Layout()
        local prev
        for _, tab in ipairs(self.buttons) do
            tab:ClearAllPoints()
            if tab.cdlShown then
                if prev then
                    tab:SetPoint("TOPLEFT", prev, "TOPRIGHT", -16, 0)
                else
                    tab:SetPoint("TOPLEFT", self.frame, "BOTTOMLEFT", 8, 2)
                end
                tab:Show()
                prev = tab
            else
                tab:Hide()
            end
        end
    end

    function obj:Select(key)
        local tab = self.byKey[key]
        if not tab then return end
        self.selected = key
        PanelTemplates_SetTab(self.frame, tab:GetID())
        if onSelect then onSelect(key) end
    end

    function obj:SetTabShown(key, shown)
        local tab = self.byKey[key]
        if not tab then return end
        shown = shown and true or false
        if tab.cdlShown ~= shown then
            tab.cdlShown = shown
            self:Layout()
        end
    end

    function obj:IsTabShown(key)
        local tab = self.byKey[key]
        return tab and tab.cdlShown or false
    end

    function obj:GetSelected()
        return self.selected
    end

    obj:Layout()
    return obj
end

---------------------------------------------------------------------------
-- Chat announce
---------------------------------------------------------------------------

local MAX_CHAT = 255

-- Splits text into <=255-byte chunks without breaking item links.
local function SplitChunks(text)
    local links = {}
    local function keep(l)
        links[#links + 1] = l
        return "\001" .. #links .. "\001"
    end
    local masked = text:gsub("|c[^|]*|H.-|h.-|h|r", keep)
    masked = masked:gsub("|H.-|h.-|h", keep)

    local chunks, cur = {}, ""
    for word in masked:gmatch("%S+") do
        word = word:gsub("\001(%d+)\001", function(i) return links[tonumber(i)] or "" end)
        if cur == "" then
            cur = word
        elseif #cur + 1 + #word <= MAX_CHAT then
            cur = cur .. " " .. word
        else
            chunks[#chunks + 1] = cur
            cur = word
        end
        while #cur > MAX_CHAT do
            chunks[#chunks + 1] = cur:sub(1, MAX_CHAT)
            cur = cur:sub(MAX_CHAT + 1)
        end
    end
    if cur ~= "" then chunks[#chunks + 1] = cur end
    return chunks
end

function UI:AnnounceLine(text)
    if type(text) ~= "string" or text == "" then return false end
    local channel = ns.db and ns.db.settings and ns.db.settings.announceChannel or "RAID"
    if IsInRaid() then
        if channel == "RAID_WARNING" and not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
            channel = "RAID"
        elseif channel ~= "RAID_WARNING" then
            channel = "RAID"
        end
    elseif IsInGroup() then
        channel = "PARTY"
    else
        ns:Print(text)
        return false
    end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if not send then return false end
    for _, chunk in ipairs(SplitChunks(text)) do
        send(chunk, channel)
    end
    return true
end
