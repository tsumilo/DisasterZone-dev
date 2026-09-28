-- CDLoot UI/Picker.lua
-- ns.Picker: item picker flyout docked next to the main window. Lists raid (and 5-man dungeon) loot that
-- fits one slot (raid -> boss -> item), with search and class / armor filters; accepts shift-clicked or
-- dragged items.
local addonName, ns = ...

local Picker = {}
ns.Picker = Picker

local WIDTH, HEIGHT = 360, 560
local ROW_ITEM, ROW_RAID, ROW_BOSS = 34, 20, 18
local ARMOR_SLOTS = { [1] = true, [3] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true, [10] = true }
local CLASS_WEAPON, CLASS_ARMOR = 2, 4   -- Enum.ItemClass

local EMPTY_TEXT = "No raid items match. Try 'All raids' or untick the filters - or shift-click any item."
local EMPTY_DUNGEON_TEXT = "No 5-man dungeon items match. Untick the filters - or shift-click any item."
local HINT_TEXT = "Shift-click an item link or drag an item from your bags here to use a non-raid item."
local DUNGEON_SUFFIX = " (5-man)"
local HEROIC_TAG = "|cffff7f3fHeroic|r"

-- Picker scope -> ItemDB:GetCandidates filter.scope ("raids" | "dungeons" | "all"; nil = raids).
-- The dungeon scopes list items up to the phase being edited, like the default raid scope.
local SCOPE_SOURCES = { dungeons = "dungeons", both = "all" }

local win, list, searchBox, scopeDD, cbUsable, cbArmor, current, hint
local state = {
    phase = 1, sid = 1, which = "main",
    search = "", scope = "upto", usable = true, armorOnly = true,
}
local listMarks = {}     -- itemID -> { which=, sid= } for the phase being edited
local currentPick        -- itemID currently in the slot being edited

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function MyClass()
    local data = ns.BiS and ns.BiS.GetData and ns.BiS:GetData()
    if data and type(data.cl) == "string" and data.cl ~= "" then return data.cl end
    local _, classFile = UnitClass("player")
    return classFile
end

local function SlotInfo(sid)
    return ns.SLOTS and ns.SLOTS[sid] or nil
end

local function SlotLabel(sid)
    local s = SlotInfo(sid)
    return s and s.label or ("Slot " .. tostring(sid))
end

local function SlotShort(sid)
    local s = SlotInfo(sid)
    return s and s.short or tostring(sid)
end

local function Debounce(key, sec, fn)
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce(key, sec, fn)
    else
        C_Timer.After(sec, fn)
    end
end

local function TypeLine(itemID)
    if not (C_Item and C_Item.GetItemInfoInstant) then return "" end
    local _, _, subType, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
    local slotText = (equipLoc and equipLoc ~= "" and _G[equipLoc]) or nil
    local kind
    if classID == CLASS_WEAPON then
        kind = subType
    elseif classID == CLASS_ARMOR and equipLoc ~= "INVTYPE_CLOAK" and subclassID and subclassID >= 1 then
        kind = subType   -- Cloth/Leather/Mail/Plate, Shield, Libram, Idol, Totem
    end
    if kind and kind ~= "" and slotText and type(slotText) == "string" then
        return kind .. "  ·  " .. slotText
    end
    return type(slotText) == "string" and slotText or (kind or "")
end

local function IsDungeonRef(ref)
    return type(ref) == "table" and ref.dungeon == true
end

local function BuildFilter()
    local f = { includeTrash = true }
    local sources = SCOPE_SOURCES[state.scope]
    if state.scope == "upto" or sources then
        f.maxPhase = state.phase
    elseif state.scope == "only" then
        f.phase = state.phase
    end
    if sources then f.scope = sources end
    local armorOnly = state.armorOnly and ARMOR_SLOTS[state.sid] or false
    if state.usable or armorOnly then f.class = MyClass() end
    f.usableOnly = state.usable and true or false
    f.primaryArmorOnly = armorOnly and true or false
    return f
end

local function Candidates()
    local ItemDB = ns.ItemDB
    if not (ItemDB and ItemDB.GetCandidates) then return {} end
    local rows = ItemDB:GetCandidates(state.sid, BuildFilter())
    if type(rows) ~= "table" then return {} end
    if state.scope == "dungeons" then
        -- Safety net: an ItemDB without filter.scope would return raid rows here.
        local out = {}
        for _, c in ipairs(rows) do
            if type(c) == "table" and IsDungeonRef(c.ref) then out[#out + 1] = c end
        end
        return out
    end
    return rows
end

local function RefreshMarks()
    wipe(listMarks)
    currentPick = nil
    local BiS = ns.BiS
    if not BiS then return end
    for _, e in ipairs(BiS:GetPhaseItems(state.phase) or {}) do
        local id = tonumber(e.itemID)
        if id then
            local prev = listMarks[id]
            if not prev or (prev.which == "alt" and e.which == "main") or (e.sid == state.sid and prev.sid ~= state.sid) then
                listMarks[id] = { which = e.which, sid = e.sid }
            end
        end
    end
    local main, alt = BiS:GetSlot(state.phase, state.sid)
    if state.which == "alt" then currentPick = alt else currentPick = main end
end

---------------------------------------------------------------------------
-- Picking
---------------------------------------------------------------------------

local function Pick(itemID)
    itemID = tonumber(itemID)
    if not itemID or not ns.BiS then return end
    if ns.BiS:SetSlot(state.phase, state.sid, state.which, itemID) then
        Picker:Close()
    end
end

local function OnDropItem(_, itemID)
    Pick(itemID)
end

-- Shift-clicked links (bags, chat, other addons) while the picker is open.
local function OnInsertLink(text)
    if not Picker:IsOpen() then return end
    if ns.UI and ns.UI:IsOwnLinkClick() then return end
    if type(text) ~= "string" then return end
    local id = tonumber(text:match("item:(%d+)"))
    if id and id > 0 then Pick(id) end
end

local hooked = false
local function HookInsertLink()
    if hooked then return end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)
        hooked = true
    elseif ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", OnInsertLink)
        hooked = true
    end
end

---------------------------------------------------------------------------
-- List rows
---------------------------------------------------------------------------

local function RowTooltip(row)
    local d = row.__cdlData
    if not d or d.type ~= "item" then return end
    ns.UI:SetItemTooltip(row, d.itemID, function(tt)
        tt:AddLine(" ")
        local src = ns.ItemDB and ns.ItemDB:GetSourceText(d.itemID)
        if src then tt:AddLine(src, 0.7, 0.7, 0.7, true) end
        local r, g, b = ns.UI:Color(state.which == "alt" and "alt" or "main")
        tt:AddLine(("Click: set as %s for %s (P%d)"):format(state.which == "alt" and "alt" or "main BiS", SlotLabel(state.sid), state.phase), r, g, b)
    end)
end

local function SetupRow(row)
    local UI = ns.UI
    row.cdl = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 0.82, 0, 0.08)

    row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.sel:SetAllPoints()
    row.sel:SetTexture(UI:Tex("rowHilight"))
    row.sel:SetBlendMode("ADD")
    row.sel:SetVertexColor(1, 0.82, 0, 0.6)

    row:SetHighlightTexture(UI:Tex("rowHilight"), "ADD")

    row.header = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.header:SetJustifyH("LEFT")
    row.header:SetWordWrap(false)

    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.count:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.count:SetJustifyH("RIGHT")

    row.icon = UI:CreateItemButton(row, 28)
    row.icon:SetPoint("LEFT", row, "LEFT", 16, 0)
    row.icon.onClick = function(btn) Pick(btn.itemID) end
    row.icon.onReceiveItem = OnDropItem

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
    row.name:SetPoint("RIGHT", row, "RIGHT", -74, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 2)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -74, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)

    row.mark1 = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.mark1:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -5)
    row.mark1:SetJustifyH("RIGHT")

    row.mark2 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.mark2:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 5)
    row.mark2:SetJustifyH("RIGHT")

    row:SetScript("OnClick", function(self)
        if self.__cdlDropTime and self.__cdlDropTime == GetTime() then return end
        local d = self.__cdlData
        if not d or d.type ~= "item" then return end
        if ns.UI:HandleModifiedItemClick(d.itemID) then return end
        Pick(d.itemID)
    end)
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI:AttachItemDrop(row, OnDropItem)
end

local function InitRow(row, d)
    if not row.cdl then SetupRow(row) end
    local UI = ns.UI
    local hl = row:GetHighlightTexture()
    row:SetAlpha(1)

    if d.type == "raid" or d.type == "boss" then
        row.icon:Hide()
        row.name:Hide()
        row.sub:Hide()
        row.mark1:Hide()
        row.mark2:Hide()
        row.sel:Hide()
        if hl then hl:SetAlpha(0) end
        row.header:Show()
        row.header:ClearAllPoints()
        if d.type == "raid" then
            row.bg:Show()
            row.header:SetFontObject("GameFontNormal")
            row.header:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.header:SetText(d.name or "?")
            row.count:SetText(d.count and (d.count .. (d.count == 1 and " item" or " items")) or "")
            row.count:Show()
        else
            row.bg:Hide()
            row.header:SetFontObject("GameFontHighlightSmall")
            row.header:SetPoint("LEFT", row, "LEFT", 14, 0)
            row.header:SetText(d.name or "?")
            row.count:Hide()
        end
        row.header:SetPoint("RIGHT", row, "RIGHT", -60, 0)
        return
    end

    -- item row
    row.bg:Hide()
    row.header:Hide()
    row.count:Hide()
    if hl then hl:SetAlpha(1) end
    local id = d.itemID
    row.icon:Show()
    row.icon:SetItem(id)
    row.name:Show()
    row.name:SetText((UI:ItemText(id)))
    row.sub:Show()
    local subText
    if d.via == "token" then
        local tokenName = d.viaItem and ns.ItemDB and ns.ItemDB:GetName(d.viaItem)
        subText = "via " .. (tokenName or "tier token")
    else
        subText = TypeLine(id)
    end
    if d.heroic then
        -- only on a heroic loot table (5-man dungeons)
        subText = (subText ~= "") and (HEROIC_TAG .. "  ·  " .. subText) or HEROIC_TAG
    end
    row.sub:SetText(subText)

    local mark = listMarks[id]
    if mark then
        local text = mark.which == "alt" and "Alt" or "Main"
        if mark.sid and mark.sid ~= state.sid then text = text .. " (" .. SlotShort(mark.sid) .. ")" end
        row.mark1:SetText(UI:Colorize(text, ns.COLORS and ns.COLORS[mark.which == "alt" and "alt" or "main"]))
        row.mark1:Show()
    else
        row.mark1:Hide()
    end
    if ns.BiS and ns.BiS:IsObtained(id) then
        row.mark2:SetText("|T" .. UI:Tex("check") .. ":0|t " .. UI:Colorize("owned", ns.COLORS and ns.COLORS.obtained))
        row.mark2:Show()
    else
        row.mark2:Hide()
    end
    row.sel:SetShown(currentPick ~= nil and id == currentPick)

    -- filters off: keep unusable items visible but dimmed
    if not state.usable and ns.ItemDB and ns.ItemDB.IsUsableBy then
        if ns.ItemDB:IsUsableBy(id, MyClass(), state.sid) == false then row:SetAlpha(0.45) end
    end
end

local function RowExtent(d)
    if d.type == "raid" then return ROW_RAID end
    if d.type == "boss" then return ROW_BOSS end
    return ROW_ITEM
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

local function Flatten(cands)
    local rows = {}
    local lastRaid, lastRef, raidRow
    for _, c in ipairs(cands) do
        local ref = c.ref
        local raid = ref and ref.raid or nil
        if raid ~= lastRaid or not raidRow then
            local name = raid and raid.name or "Other"
            if raid and IsDungeonRef(ref) then name = name .. DUNGEON_SUFFIX end
            raidRow = { type = "raid", name = name, count = 0, dungeon = IsDungeonRef(ref) }
            rows[#rows + 1] = raidRow
            lastRaid, lastRef = raid, nil
        end
        if ref ~= lastRef then
            local boss = ref and ref.boss
            rows[#rows + 1] = { type = "boss", name = boss and boss.name or "Unknown source" }
            lastRef = ref
        end
        raidRow.count = raidRow.count + 1
        rows[#rows + 1] = { type = "item", itemID = c.itemID, via = c.via, viaItem = c.viaItem, ref = ref,
                            heroic = c.heroic and true or nil }
    end
    return rows
end

function Picker:Rebuild(resetScroll)
    if not win or not list then return end
    RefreshMarks()
    local cands = Candidates()
    if state.search ~= "" and ns.ItemDB and ns.ItemDB.Search then
        cands = ns.ItemDB:Search(state.search, cands) or {}
    end
    list:SetEmptyText(state.scope == "dungeons" and EMPTY_DUNGEON_TEXT or EMPTY_TEXT)
    list:SetData(Flatten(cands), resetScroll)
end

local function Prefetch()
    local ItemDB = ns.ItemDB
    if not (ItemDB and ItemDB.Prefetch) then return end
    local ids, seen = {}, {}
    for _, c in ipairs(Candidates()) do
        if c.itemID and not seen[c.itemID] then seen[c.itemID] = true; ids[#ids + 1] = c.itemID end
        if c.viaItem and not seen[c.viaItem] then seen[c.viaItem] = true; ids[#ids + 1] = c.viaItem end
    end
    ItemDB:Prefetch(ids)
end

local function UpdateHeader()
    if not win then return end
    local whichText = state.which == "alt" and "Alt" or "Main"
    win:SetWindowTitle(("Choose %s (%s)  ·  P%d"):format(SlotLabel(state.sid), whichText, state.phase))
end

local function UpdateCurrent()
    if not current then return end
    local UI = ns.UI
    RefreshMarks()
    local id = currentPick
    current.btn:SetItem(id, UI:EmptySlotTexture(state.sid))
    if id then
        current.name:SetText((UI:ItemText(id)))
        local src = ns.ItemDB and ns.ItemDB:GetSourceText(id, true)
        current.sub:SetText(src or "Other source")
        current.clear:Enable()
    else
        current.name:SetText("|cff808080Nothing chosen yet|r")
        current.sub:SetText(("Current %s pick for %s"):format(state.which == "alt" and "alt" or "main", SlotLabel(state.sid)))
        current.clear:Disable()
    end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local SCOPE_TEXT = {
    upto = function(p) return ("Raids up to P%d"):format(p) end,
    only = function(p) return ("Only P%d raids"):format(p) end,
    all  = function() return "All raids" end,
    dungeons = function() return "5-man dungeons" end,
    both = function() return "Raids + dungeons" end,
}

local function ScopeOptions()
    return {
        { value = "upto", text = SCOPE_TEXT.upto(state.phase) },
        { value = "only", text = SCOPE_TEXT.only(state.phase) },
        { value = "all",  text = SCOPE_TEXT.all() },
        { value = "dungeons", text = SCOPE_TEXT.dungeons() },
        { value = "both", text = SCOPE_TEXT.both() },
    }
end

local function EnsureWindow()
    if win then return win end
    local UI = ns.UI
    win = UI:CreateWindow("CDLootPicker", "Choose", WIDTH, HEIGHT, { noSavePosition = true })
    win:Hide()
    local c = win.content

    -- current selection
    current = CreateFrame("Frame", nil, c)
    current:SetPoint("TOPLEFT", c, "TOPLEFT", 4, -4)
    current:SetPoint("TOPRIGHT", c, "TOPRIGHT", -4, -4)
    current:SetHeight(36)
    current.btn = UI:CreateItemButton(current, 32)
    current.btn:SetPoint("LEFT", current, "LEFT", 0, 0)
    current.clear = UI:CreateButton(current, "Clear", 60, 22, function()
        if ns.BiS then ns.BiS:SetSlot(state.phase, state.sid, state.which, nil) end
        UpdateCurrent()
        if list then list:Refresh() end
    end)
    current.clear:SetPoint("RIGHT", current, "RIGHT", 0, 0)
    current.name = current:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    current.name:SetPoint("TOPLEFT", current.btn, "TOPRIGHT", 8, -1)
    current.name:SetPoint("RIGHT", current.clear, "LEFT", -6, 0)
    current.name:SetJustifyH("LEFT")
    current.name:SetWordWrap(false)
    current.sub = current:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    current.sub:SetPoint("BOTTOMLEFT", current.btn, "BOTTOMRIGHT", 8, 1)
    current.sub:SetPoint("RIGHT", current.clear, "LEFT", -6, 0)
    current.sub:SetJustifyH("LEFT")
    current.sub:SetWordWrap(false)

    -- filters
    searchBox = UI:CreateSearchBox(c, WIDTH - 40, function(text)
        text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if text == state.search then return end
        state.search = text
        Picker:Rebuild(true)
    end, "Search items, bosses, raids or item ID")
    searchBox:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -48)
    searchBox:SetPoint("TOPRIGHT", c, "TOPRIGHT", -6, -48)

    scopeDD = UI:CreateDropdown(c, 180, ScopeOptions, function() return state.scope end, function(value)
        state.scope = value or "upto"
        Prefetch()
        Picker:Rebuild(true)
    end)
    scopeDD:SetPoint("TOPLEFT", c, "TOPLEFT", 4, -74)

    cbUsable = UI:CreateCheckbox(c, "Usable by my class", function() return state.usable end, function(v)
        state.usable = v
        Prefetch()
        Picker:Rebuild(true)
    end)
    cbUsable:SetPoint("TOPLEFT", c, "TOPLEFT", 2, -102)

    cbArmor = UI:CreateCheckbox(c, "My armor type only", function() return state.armorOnly end, function(v)
        state.armorOnly = v
        Prefetch()
        Picker:Rebuild(true)
    end)
    cbArmor:SetPoint("TOPLEFT", c, "TOPLEFT", 172, -102)

    -- list
    list = UI:CreateScrollList(c, ROW_ITEM, InitRow, RowExtent)
    list.frame:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -130)
    list.frame:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 38)
    list:SetEmptyText(EMPTY_TEXT)
    list.emptyText:SetWordWrap(true)

    hint = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 6, 6)
    hint:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -6, 6)
    hint:SetJustifyH("LEFT")
    hint:SetText(HINT_TEXT)

    -- the whole window accepts items dragged from the bags
    UI:AttachItemDrop(win, OnDropItem)
    current.btn.onReceiveItem = OnDropItem

    win:HookScript("OnHide", function()
        if searchBox then searchBox:ClearFocus() end
        if ns.MyBiS and ns.MyBiS.OnPickerClosed then ns.MyBiS:OnPickerClosed() end
    end)
    return win
end

local function Position(anchor)
    win:ClearAllPoints()
    local main = ns.MainFrame and ns.MainFrame:IsShown() and ns.MainFrame:GetFrame() or nil
    if main then
        local right, left = main:GetRight(), main:GetLeft()
        local screenRight = UIParent:GetRight()
        if right and left and screenRight and right + WIDTH + 2 > screenRight and left - WIDTH - 2 >= 0 then
            win:SetPoint("TOPRIGHT", main, "TOPLEFT", -2, 0)
        else
            win:SetPoint("TOPLEFT", main, "TOPRIGHT", 2, 0)
        end
    elseif anchor and anchor.GetRight then
        win:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    else
        win:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function Picker:Open(phase, sid, which, anchor)
    sid = tonumber(sid)
    if not sid or not SlotInfo(sid) then return end
    state.phase = tonumber(phase) or state.phase or 1
    state.sid = sid
    state.which = which == "alt" and "alt" or "main"
    state.search = ""

    EnsureWindow()
    HookInsertLink()
    Position(anchor)
    UpdateHeader()

    searchBox:SetText("")
    cbUsable:Refresh()
    cbArmor:Refresh()
    cbArmor:SetShown(ARMOR_SLOTS[sid] and true or false)
    scopeDD:Refresh()

    Prefetch()
    win:Show()
    win:Raise()
    UpdateCurrent()
    self:Rebuild(true)
end

function Picker:Close()
    if win and win:IsShown() then win:Hide() end
end

function Picker:IsOpen()
    return win ~= nil and win:IsShown()
end

function Picker:GetState()
    return state.phase, state.sid, state.which
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------

ns:On("ITEMINFO_READY", function()
    if not Picker:IsOpen() then return end
    UpdateCurrent()
    if state.search ~= "" then
        -- names that just loaded may now match the search
        Debounce("picker-search", 0.2, function() if Picker:IsOpen() then Picker:Rebuild(false) end end)
    else
        list:Refresh()
    end
end)

local function RefreshMarkers()
    if not Picker:IsOpen() then return end
    UpdateCurrent()
    list:Refresh()
end
ns:On("MYLIST_CHANGED", RefreshMarkers)
ns:On("OWNED_UPDATED", RefreshMarkers)
