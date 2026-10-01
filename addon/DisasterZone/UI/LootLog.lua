if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LootLog.lua", ...) then return end -- DisasterZone: "Loot Log" tab (SPEC §12.7): the council's award ledger with search, void/restore and manual awards.
-- Dungeon-mode awards (entries with dg = true, ADDENDUM B §22.2) carry a grey "(dungeon)" tag and can be hidden.
-- Also owns the "Record award" dialog that the Council view and the drop panel reuse (LootLogUI:OpenAwardDialog).
local addonName, ns = ...

local LootLogUI = ns:NewModule("LootLogUI")

local ROW_HEIGHT = 26
local MAX_NOTE = 60
local MAX_ITEM_ID = 200000
local MENU_CHUNK = 25
local ROW_HILIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

-- Column x offsets / widths inside a row (and the header above the list).
local COL = {
    date = { x = 6, w = 74 },
    icon = { x = 84 },
    item = { x = 110, w = 200 },
    winner = { x = 314, w = 104 },
    reason = { x = 422, w = 70 },    -- award reason (ADDENDUM G)
    boss = { x = 496, w = 130 },
    by = { x = 630, w = 120 },
}

local ITEM_HINT = "Shift-click, drag or type an item ID."

local state = { search = "", showVoid = false, showDungeon = true }
local panel, dialog
local linkHookInstalled = false
local prefetched = {}       -- [itemID] = true once item data was requested

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function grey(text)
    return "|cff808080" .. tostring(text) .. "|r"
end

local function trim(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shortName(key)
    if not key then return "?" end
    if ns.Util and ns.Util.ShortName then
        return ns.Util.ShortName(key) or key
    end
    return key
end

local function classOf(key)
    if type(key) ~= "string" then return nil end
    local cl = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)
    if not cl and ns.Store and ns.Store.Get then
        local rec = ns.Store:Get(key)
        local data = type(rec) == "table" and rec.data
        if type(data) == "table" and type(data.cl) == "string" then cl = data.cl end
    end
    return cl
end

local function coloredName(key, classFile)
    if ns.UI and ns.UI.ColoredName then
        return ns.UI:ColoredName(key, classFile or classOf(key))
    end
    return shortName(key)
end

local function itemText(itemID)
    if not itemID then return "" end
    if ns.UI and ns.UI.ItemText then
        local text = ns.UI:ItemText(itemID)   -- drop the extra "loading" return value
        return text
    end
    return "item " .. tostring(itemID)
end

local function itemName(itemID)
    return itemID and ns.ItemDB and ns.ItemDB.GetName and ns.ItemDB:GetName(itemID)
end

local function itemLink(itemID)
    return itemID and ns.ItemDB and ns.ItemDB.GetLink and ns.ItemDB:GetLink(itemID)
end

local function bossName(bossKey, withRaid)
    if type(bossKey) ~= "string" or bossKey == "" then return nil end
    local ref = ns.ItemDB and ns.ItemDB.GetBossRef and ns.ItemDB:GetBossRef(bossKey)
    if not (ref and ref.boss and ref.boss.name) then return nil end
    if withRaid and ref.raid and ref.raid.name then
        return ref.boss.name .. " · " .. ref.raid.name
    end
    return ref.boss.name
end

local function formatAgo(ts)
    if ns.Util and ns.Util.FormatAgo then
        return ns.Util.FormatAgo(ts)
    end
    return tostring(ts or "never")
end

local function formatDate(ts, fmt)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return "-" end
    return date(fmt or "%m/%d %H:%M", ts)
end

-- Puts an item link into chat (ns.UI:LinkInChat opens the chat box when none is active).
local function linkInChat(itemID)
    if not itemID then return end
    if ns.UI and ns.UI.LinkInChat then
        ns.UI:LinkInChat(itemID)
        return
    end
    local link = itemLink(itemID)
    if not link then return end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        ChatFrameUtil.InsertLink(link)
    elseif ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
    end
end

local function hideTooltip()
    GameTooltip:Hide()
end

local function isInGroup(key)
    return ns.Util and ns.Util.IsInMyGroup and ns.Util.IsInMyGroup(key) or false
end

local function isOnline(key)
    return ns.Guild and ns.Guild.IsOnline and ns.Guild:IsOnline(key) or false
end

local function demoEnabled()
    return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() or false
end

local function sortByShortName(keys)
    local lower = {}
    for _, k in ipairs(keys) do
        lower[k] = shortName(k):lower()
    end
    table.sort(keys, function(a, b)
        if lower[a] ~= lower[b] then return lower[a] < lower[b] end
        return a < b
    end)
    return keys
end

-- ns.UI lists keep their scroll position on SetData unless resetScroll is passed.
local function setListData(list, rows, resetScroll)
    if not list then return end
    list:SetData(rows, resetScroll and true or false)
    if resetScroll and list.box and list.box.SetScrollPercentage then
        list.box:SetScrollPercentage(0)
    end
end

local function validEntry(e)
    return type(e) == "table" and tonumber(e.i) ~= nil and type(e.w) == "string" and type(e.id) == "string"
end

-- Recorded in a 5-man dungeon while dungeon mode was active.
local function isDungeonEntry(e)
    return e.dg == true
end

-- Award reason label ("BiS", "Offspec", ...) of an entry, or nil (ADDENDUM G).
local function reasonLabel(e)
    return ns.ReasonLabel and ns.ReasonLabel(e.r) or nil
end

-- Offspec / disenchant / guild bank: not counted as loot received.
local function reasonCounts(e)
    local r = ns.AWARD_REASON and e.r and ns.AWARD_REASON[e.r]
    return not r or r.counts
end

local DUNGEON_TAG = grey("(dungeon)")

----------------------------------------------------------------------------
-- Ledger list
----------------------------------------------------------------------------

local function entryMatches(e)
    local s = state.search
    if s == "" then return true end
    local function has(text)
        return type(text) == "string" and text:lower():find(s, 1, true) ~= nil
    end
    return has(shortName(e.w)) or has(itemName(e.i)) or has(bossName(e.b))
        or has(e.by and shortName(e.by)) or has(e.n) or tostring(e.i) == s
        or (isDungeonEntry(e) and has("dungeon")) or has(reasonLabel(e))
end

local function buildRows()
    local rows, total = {}, 0
    local ledger = ns.Ledger
    if not (ledger and ledger.GetVisibleEntries) then return rows, total end
    local pre = {}
    for _, e in ipairs(ledger:GetVisibleEntries({ includeVoid = state.showVoid }) or {}) do
        if validEntry(e) then
            total = total + 1
            local id = tonumber(e.i)
            if not prefetched[id] then
                prefetched[id] = true
                pre[#pre + 1] = id
            end
            if (state.showDungeon or not isDungeonEntry(e)) and entryMatches(e) then
                rows[#rows + 1] = { entry = e, itemID = id, classFile = classOf(e.w) }
            end
        end
    end
    if #pre > 0 and ns.ItemDB and ns.ItemDB.Prefetch then
        ns.ItemDB:Prefetch(pre)
    end
    return rows, total
end

local function addEntryLines(tt, e)
    if not e then return end
    tt:AddLine(" ")
    tt:AddLine("|cffff8000DisasterZone|r award")
    tt:AddDoubleLine("Winner", coloredName(e.w), 0.8, 0.8, 0.8, 1, 1, 1)
    local label = reasonLabel(e)
    if label then
        tt:AddDoubleLine("Reason", label .. (reasonCounts(e) and "" or grey(" (not counted as loot won)")),
            0.8, 0.8, 0.8, 1, 1, 1)
    end
    local where = bossName(e.b, true)
    if where then tt:AddDoubleLine("Boss", where, 0.8, 0.8, 0.8, 1, 1, 1) end
    if isDungeonEntry(e) then tt:AddLine("5-man dungeon loot (dungeon mode)", 0.6, 0.6, 0.6) end
    tt:AddDoubleLine("Date", formatDate(e.ts, "%Y-%m-%d %H:%M"), 0.8, 0.8, 0.8, 1, 1, 1)
    local kind = e.s == "m" and "Manual" or "Auto (loot message)"
    tt:AddDoubleLine("Recorded", kind .. (e.by and (" by " .. shortName(e.by)) or ""), 0.8, 0.8, 0.8, 1, 1, 1)
    if type(e.n) == "string" and e.n ~= "" then
        tt:AddLine("Note: " .. e.n, 1, 1, 1, true)
    end
    if e.vd then
        tt:AddLine("Voided " .. formatAgo(e.vts), 1, 0.3, 0.3)
    end
    tt:AddLine("Right-click: reason, void / restore, link, show member", 0.5, 0.5, 0.5)
end

local function voidEntry(e, voided)
    if ns.Ledger and ns.Ledger.Void and e and e.id then
        ns.Ledger:Void(e.id, voided)
    end
end

local function showMember(key)
    if ns.CouncilUI and ns.CouncilUI.ShowMember then
        ns.CouncilUI:ShowMember(key)
    end
end

local function openRowMenu(row, e)
    if not (ns.UI and ns.UI.ContextMenu) then return end
    ns.UI:ContextMenu(row, function(root)
        root:CreateTitle(itemName(e.i) or ("Item " .. tostring(e.i)))
        if not e.vd and ns.Ledger and ns.Ledger.SetReason then
            local sub = root:CreateButton("Reason: " .. (reasonLabel(e) or "none"))
            for _, r in ipairs(ns.AWARD_REASONS or {}) do
                local rk = r.key
                sub:CreateButton((e.r == rk and "* " or "") .. r.label, function() ns.Ledger:SetReason(e.id, rk) end)
            end
            if e.r then
                sub:CreateDivider()
                sub:CreateButton("No reason", function() ns.Ledger:SetReason(e.id, nil) end)
            end
        end
        if e.vd then
            root:CreateButton("Restore entry", function() voidEntry(e, false) end)
        else
            root:CreateButton("Void entry", function() voidEntry(e, true) end)
        end
        root:CreateButton("Link item in chat", function() linkInChat(tonumber(e.i)) end)
        root:CreateButton("Show member", function() showMember(e.w) end)
    end)
end

local function rowClick(row, mouseButton)
    local e = row.cdlEntry
    if not e then return end
    if mouseButton == "RightButton" then
        openRowMenu(row, e)
    elseif IsModifiedClick() then
        local link = itemLink(tonumber(e.i))
        if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end
    end
end

local function rowEnter(row)
    local e = row.cdlEntry
    if not e then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(itemText(tonumber(e.i)))
    addEntryLines(GameTooltip, e)
    GameTooltip:Show()
end

local function newText(row, col, font, justify)
    local fs = row:CreateFontString(nil, "OVERLAY", font)
    fs:SetPoint("LEFT", col.x, 0)
    fs:SetWidth(col.w)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function setupRow(row)
    row.cdlInit = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(ns.TEX and ns.TEX.rowHilight or ROW_HILIGHT)
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.5)

    row.date = newText(row, COL.date, "GameFontHighlightSmall")
    row.btn = ns.UI:CreateItemButton(row, 20)
    row.btn:SetPoint("LEFT", COL.icon.x, 0)
    row.btn.onTooltip = function(btn, tt)
        addEntryLines(tt, btn:GetParent().cdlEntry)
    end
    row.btn.onClick = function(btn, mouseButton)
        rowClick(btn:GetParent(), mouseButton)
    end
    row.item = newText(row, COL.item, "GameFontHighlight")
    row.winner = newText(row, COL.winner, "GameFontHighlight")
    row.reason = newText(row, COL.reason, "GameFontHighlightSmall")
    row.boss = newText(row, COL.boss, "GameFontHighlightSmall")
    row.by = newText(row, COL.by, "GameFontDisableSmall")

    row:SetScript("OnClick", rowClick)
    row:SetScript("OnEnter", rowEnter)
    row:SetScript("OnLeave", hideTooltip)
end

local function initRow(row, d)
    if not row.cdlInit then setupRow(row) end
    local e = d.entry
    row.cdlEntry = e
    row.date:SetText(formatDate(e.ts))
    row.btn:SetItem(d.itemID)
    row.btn:SetBadge(nil)
    row.btn:SetState(e.vd and "dim" or nil)
    if e.vd then
        row.item:SetText(grey((itemName(d.itemID) or ("item " .. d.itemID)) .. " (void)"))
        row.winner:SetText(grey(shortName(e.w)))
    else
        row.item:SetText(itemText(d.itemID))
        row.winner:SetText(coloredName(e.w, d.classFile))
    end
    local label = reasonLabel(e)
    if not label then
        row.reason:SetText(grey("-"))
    elseif reasonCounts(e) and not e.vd then
        row.reason:SetText(label)
    else
        row.reason:SetText(grey(label))   -- offspec / disenchant / bank: not counted as loot won
    end
    local boss = bossName(e.b) or grey("-")
    if isDungeonEntry(e) then boss = boss .. " " .. DUNGEON_TAG end
    row.boss:SetText(boss)
    local kind = e.s == "m" and "manual" or "auto"
    local by = kind .. (e.by and (" · " .. shortName(e.by)) or "")
    if type(e.n) == "string" and e.n ~= "" then by = by .. " · note" end
    row.by:SetText(by)
    row:SetAlpha(e.vd and 0.6 or 1)
end

----------------------------------------------------------------------------
-- Award dialog
----------------------------------------------------------------------------

local function parseItem(text)
    if type(text) ~= "string" then return nil end
    local id = ns.Util and ns.Util.ItemIDFromLink and ns.Util.ItemIDFromLink(text)
    id = tonumber(id) or tonumber(text:match("item:(%d+)")) or tonumber(text:match("^%s*(%d+)%s*$"))
    if id and id >= 1 and id <= MAX_ITEM_ID and id == math.floor(id) then
        return id
    end
    return nil
end

local function setStatus(text)
    if dialog then dialog.status:SetText(text or "") end
end

-- Boss for the new entry: the caller's boss, else the recent kill if it drops the item, else its first source.
local function resolveBoss()
    local f = dialog
    if f.explicitBoss then return f.explicitBoss end
    local id = f.itemID
    local srcs = id and ns.ItemDB and ns.ItemDB.GetSources and ns.ItemDB:GetSources(id)
    if type(srcs) ~= "table" or #srcs == 0 then return "" end
    local recent = ns.Loot and ns.Loot.GetRecentBossKey and ns.Loot:GetRecentBossKey()
    if recent then
        for _, s in ipairs(srcs) do
            if s.ref and s.ref.key == recent then return recent end
        end
    end
    return srcs[1].ref and srcs[1].ref.key or ""
end

local function updateBossText()
    local f = dialog
    local where = bossName(resolveBoss(), true)
    f.bossText:SetText("Boss: " .. (where or grey("none")))
end

local function updateItemPreview()
    local f = dialog
    if not f then return end
    local id = parseItem(f.itemBox:GetText())
    f.itemID = id
    f.itemBtn:SetItem(id)
    if id then
        f.itemHint:SetText(itemText(id))
    else
        f.itemHint:SetText(grey(ITEM_HINT))
    end
    updateBossText()
end

local function setItemText(text)
    local f = dialog
    f.itemBox:SetText(text or "")
    f.itemBox:SetCursorPosition(0)
    updateItemPreview()
end

local function receiveCursorItem()
    if not dialog then return end
    local kind, id, link = GetCursorInfo()
    if kind == "item" and id then
        ClearCursor()
        setItemText(link or tostring(id))
    end
end

local function setWinner(key)
    local f = dialog
    f.winnerKey = key
    f.winBox:SetText(key and shortName(key) or "")
    f.winBox:SetCursorPosition(0)
end

local function groupKeys()
    local keys, seen = {}, {}
    local function add(k)
        if type(k) == "string" and k ~= "" and not seen[k] then
            seen[k] = true
            keys[#keys + 1] = k
        end
    end
    if ns.Util and ns.Util.GetGroupKeys then
        for _, k in ipairs(ns.Util.GetGroupKeys() or {}) do add(k) end
    end
    if demoEnabled() and ns.Store and ns.Store.GetAllKeys then
        for _, k in ipairs(ns.Store:GetAllKeys() or {}) do
            if isInGroup(k) then add(k) end
        end
    end
    return sortByShortName(keys)
end

local function guildKeys()
    local all, online, seen = {}, {}, {}
    local function add(k)
        if type(k) == "string" and k ~= "" and not seen[k] then
            seen[k] = true
            all[#all + 1] = k
            if isOnline(k) then online[#online + 1] = k end
        end
    end
    if ns.Guild and ns.Guild.GetMembers then
        for _, k in ipairs(ns.Guild:GetMembers() or {}) do add(k) end
    end
    if demoEnabled() and ns.Store and ns.Store.GetAllKeys then
        for _, k in ipairs(ns.Store:GetAllKeys() or {}) do add(k) end
    end
    return sortByShortName(online), sortByShortName(all)
end

-- Typed names: match a known raid/guild name case-insensitively, else normalise as "Name-Realm".
local function resolveWinner()
    local f = dialog
    if f.winnerKey then return f.winnerKey end
    local text = trim(f.winBox:GetText())
    if text == "" then return nil end
    local lower = text:lower()
    local _, all = guildKeys()
    local pools = { groupKeys(), all }
    for _, pool in ipairs(pools) do
        for _, key in ipairs(pool) do
            if key:lower() == lower or shortName(key):lower() == lower then return key end
        end
    end
    if not text:find("-", 1, true) then
        text = text:sub(1, 1):upper() .. text:sub(2):lower()
    end
    if ns.Util and ns.Util.NormalizeName then
        return ns.Util.NormalizeName(text)
    end
    return text
end

local function addWinnerButton(menu, key)
    menu:CreateButton(coloredName(key), function() setWinner(key) end)
end

-- Long name lists scroll when the menu supports it, else they are split into alphabetical chunks.
local function fillWinnerMenu(sub, keys)
    if #keys <= MENU_CHUNK then
        for _, key in ipairs(keys) do addWinnerButton(sub, key) end
    elseif sub.SetScrollMode then
        sub:SetScrollMode(400)
        for _, key in ipairs(keys) do addWinnerButton(sub, key) end
    else
        for i = 1, #keys, MENU_CHUNK do
            local last = math.min(i + MENU_CHUNK - 1, #keys)
            local chunk = sub:CreateButton(shortName(keys[i]) .. " - " .. shortName(keys[last]))
            for j = i, last do addWinnerButton(chunk, keys[j]) end
        end
    end
end

local function openWinnerMenu(owner)
    if not (ns.UI and ns.UI.ContextMenu) then return end
    local raid = groupKeys()
    local online, all = guildKeys()
    ns.UI:ContextMenu(owner, function(root)
        if #raid > 0 then
            root:CreateTitle("Raid / party")
            for _, key in ipairs(raid) do addWinnerButton(root, key) end
        else
            root:CreateTitle("Not in a group")
        end
        if #online > 0 or #all > 0 then root:CreateDivider() end
        if #online > 0 then
            fillWinnerMenu(root:CreateButton(string.format("Guild - online (%d)", #online)), online)
        end
        if #all > 0 then
            fillWinnerMenu(root:CreateButton(string.format("Guild - all (%d)", #all)), all)
        end
    end)
end

local function saveAward()
    local f = dialog
    local id = parseItem(f.itemBox:GetText())
    if not id then
        setStatus("Enter an item: shift-click it, drag it here or type its item ID.")
        return
    end
    local key = resolveWinner()
    if not key then
        setStatus("Choose who received the item.")
        return
    end
    local note = trim(f.noteBox:GetText())
    if note == "" then note = nil end
    if note and #note > MAX_NOTE then note = note:sub(1, MAX_NOTE) end
    local awardReason = f.reasonKey   -- (ADDENDUM G) nil = no reason / the roll's default
    -- Opened by the drop panel: it records the award itself (through the item's roll when it has one).
    local onSave = f.onSave
    if type(onSave) == "function" then
        local ok, done, reason = pcall(onSave, id, key, resolveBoss(), note, awardReason)
        if not ok then
            local handler = geterrorhandler and geterrorhandler()
            if handler then handler(done) end
            setStatus("Could not record the award.")
        elseif done then
            f:Hide()
        else
            setStatus(type(reason) == "string" and reason or "Could not record the award.")
        end
        return
    end
    if not (ns.Ledger and ns.Ledger.Award) then
        setStatus("The award log is not available.")
        return
    end
    local entry = ns.Ledger:Award(id, key, resolveBoss(), note, nil, awardReason)
    if not entry then
        setStatus("Could not record the award (council members only).")
        return
    end
    ns:Print("Recorded award: %s to %s.", itemLink(id) or itemName(id) or ("item " .. id), shortName(key))
    f:Hide()
end

-- Shift-clicked item links go into the dialog's item box while it has focus.
local function onInsertLink(link)
    local f = dialog
    if not (f and f:IsShown() and type(link) == "string") then return end
    if f.itemBox:HasFocus() and link:find("item:%d") then
        setItemText(link)
    end
end

local function installLinkHook()
    if linkHookInstalled then return end
    linkHookInstalled = true
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        hooksecurefunc(ChatFrameUtil, "InsertLink", onInsertLink)
    elseif ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", onInsertLink)
    end
end

local function createEditBox(parent, width, maxLetters)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(width, 20)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(maxLetters)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return eb
end

local function createDialog()
    local UI = ns.UI
    if not (UI and UI.CreateWindow) then return nil end
    local f = UI:CreateWindow("DisasterZoneAwardDialog", "Record award", 320, 228)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:Hide()
    dialog = f
    local c = f.content or f

    local function label(text, y)
        local fs = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", 10, y)
        fs:SetText(text)
        return fs
    end

    -- Item
    label("Item", -12)
    f.itemBtn = UI:CreateItemButton(c, 24)
    f.itemBtn:SetPoint("TOPLEFT", 52, -6)
    f.itemBtn.onReceiveItem = function(_, itemID)
        setItemText(itemLink(itemID) or tostring(itemID))
    end
    f.itemBox = createEditBox(c, 200, 255)
    f.itemBox:SetPoint("TOPLEFT", 90, -8)
    f.itemBox:SetScript("OnTextChanged", function() updateItemPreview() end)
    f.itemBox:SetScript("OnReceiveDrag", receiveCursorItem)
    f.itemBox:SetScript("OnMouseUp", receiveCursorItem)
    f.itemHint = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.itemHint:SetPoint("TOPLEFT", 86, -32)
    f.itemHint:SetWidth(214)
    f.itemHint:SetJustifyH("LEFT")
    f.itemHint:SetWordWrap(false)

    -- Winner
    label("Winner", -58)
    f.winBox = createEditBox(c, 150, 48)
    f.winBox:SetPoint("TOPLEFT", 64, -54)
    f.winBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then f.winnerKey = nil end
    end)
    f.pickBtn = UI:CreateButton(c, "Choose", 76, 22, function() openWinnerMenu(f.pickBtn) end)
    f.pickBtn:SetPoint("LEFT", f.winBox, "RIGHT", 8, 0)

    -- Note
    label("Note", -88)
    f.noteBox = createEditBox(c, 234, MAX_NOTE)
    f.noteBox:SetPoint("TOPLEFT", 64, -84)

    -- Reason (ADDENDUM G): offspec / disenchant / guild bank awards don't count as loot won.
    label("Reason", -118)
    f.reasonDD = UI:CreateDropdown(c, 160, function()
        local opts = { { value = "", text = "None" } }
        for _, r in ipairs(ns.AWARD_REASONS or {}) do opts[#opts + 1] = { value = r.key, text = r.label } end
        return opts
    end, function() return f.reasonKey or "" end, function(value)
        f.reasonKey = (type(value) == "string" and value ~= "") and value or nil
    end)
    f.reasonDD:SetPoint("TOPLEFT", 64, -112)

    f.bossText = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.bossText:SetPoint("TOPLEFT", 10, -142)
    f.bossText:SetWidth(290)
    f.bossText:SetJustifyH("LEFT")
    f.bossText:SetWordWrap(false)

    f.status = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.status:SetTextColor(1, 0.3, 0.3)
    f.status:SetPoint("TOPLEFT", 10, -158)
    f.status:SetWidth(290)
    f.status:SetJustifyH("LEFT")

    f.cancelBtn = UI:CreateButton(c, "Cancel", 90, 22, function() f:Hide() end)
    f.cancelBtn:SetPoint("BOTTOMRIGHT", -8, 6)
    f.saveBtn = UI:CreateButton(c, "Save", 90, 22, saveAward)
    f.saveBtn:SetPoint("RIGHT", f.cancelBtn, "LEFT", -6, 0)

    -- Dropping an item anywhere on the dialog also sets it.
    f:HookScript("OnReceiveDrag", receiveCursorItem)
    f:HookScript("OnHide", function()
        f.itemBox:ClearFocus()
        f.winBox:ClearFocus()
        f.noteBox:ClearFocus()
    end)
    return f
end

----------------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------------

local function createHeader(p)
    local h = CreateFrame("Frame", nil, p)
    h:SetPoint("TOPLEFT", 0, -34)
    h:SetPoint("TOPRIGHT", 0, -34)
    h:SetHeight(18)
    local titles = {
        { COL.date, "Date" }, { COL.item, "Item" }, { COL.winner, "Winner" }, { COL.reason, "Reason" },
        { COL.boss, "Boss" }, { COL.by, "Recorded" },
    }
    for _, t in ipairs(titles) do
        local fs = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", t[1].x, 0)
        fs:SetWidth(t[1].w)
        fs:SetJustifyH("LEFT")
        fs:SetText(t[2])
    end
    return h
end

function LootLogUI:CreatePanel(parent)
    if panel then return panel end
    local UI = ns.UI
    local p = CreateFrame("Frame", "DisasterZoneLootLogPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    p.dirty = true

    p.search = UI:CreateSearchBox(p, 220, function(text)
        state.search = trim(text):lower()
        LootLogUI:Refresh(true)
    end)
    p.search:SetPoint("LEFT", p, "TOPLEFT", 14, -16)

    p.voidCB = UI:CreateCheckbox(p, "Show voided", function() return state.showVoid end, function(value)
        if type(value) == "boolean" then
            state.showVoid = value
        else
            state.showVoid = not state.showVoid
        end
        LootLogUI:Refresh(true)
    end)
    p.voidCB:SetPoint("LEFT", p, "TOPLEFT", 250, -16)

    p.dungeonCB = UI:CreateCheckbox(p, "Show dungeon loot", function() return state.showDungeon end, function(value)
        if type(value) == "boolean" then
            state.showDungeon = value
        else
            state.showDungeon = not state.showDungeon
        end
        LootLogUI:Refresh(true)
    end)
    p.dungeonCB:SetPoint("LEFT", p, "TOPLEFT", 370, -16)

    p.addBtn = UI:CreateButton(p, "Add award...", 110, 22, function() LootLogUI:OpenAwardDialog() end)
    p.addBtn:SetPoint("RIGHT", p, "TOPRIGHT", -8, -16)

    p.count = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.count:SetPoint("RIGHT", p.addBtn, "LEFT", -12, 0)
    p.count:SetJustifyH("RIGHT")

    p.header = createHeader(p)

    p.list = UI:CreateScrollList(p, ROW_HEIGHT, initRow)
    p.list.frame:ClearAllPoints()
    p.list.frame:SetPoint("TOPLEFT", 0, -54)
    p.list.frame:SetPoint("BOTTOMRIGHT", 0, 22)

    p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    p.empty:SetPoint("CENTER", p.list.frame, "CENTER", 0, 20)
    p.empty:SetWidth(460)

    p.hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.hint:SetPoint("BOTTOMLEFT", 8, 6)
    p.hint:SetPoint("BOTTOMRIGHT", -8, 6)
    p.hint:SetJustifyH("LEFT")
    p.hint:SetText("Awards are logged automatically from loot messages in raid instances and shared with the council. Right-click an entry to void or restore it.")
    p.hint:SetWordWrap(false)

    p:SetScript("OnShow", function(self)
        if self.dirty then LootLogUI:Refresh() end
    end)
    function p:OnPanelShown()
        if self.dirty then LootLogUI:Refresh() end
    end
    -- A freshly created frame gets no OnShow; paint once the tab has been laid out.
    C_Timer.After(0, function()
        if panel and panel.dirty then LootLogUI:Refresh() end
    end)
    return p
end

function LootLogUI:Refresh(resetScroll)
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    panel.dirty = false
    if ns.Util and ns.Util.CancelDebounce then ns.Util.CancelDebounce("lootlog-ui") end
    if panel.voidCB and panel.voidCB.Refresh then panel.voidCB:Refresh() end
    if panel.dungeonCB and panel.dungeonCB.Refresh then panel.dungeonCB:Refresh() end

    local rows, total = buildRows()
    setListData(panel.list, rows, resetScroll)

    if #rows == total then
        panel.count:SetText(total == 1 and "1 award" or (total .. " awards"))
    else
        panel.count:SetText(string.format("%d of %d awards", #rows, total))
    end
    if #rows > 0 then
        panel.empty:Hide()
    else
        if total == 0 then
            panel.empty:SetText("No awards recorded yet.\nAwards are logged automatically from loot messages while you raid, or use Add award... to record one.")
        elseif state.search == "" and not state.showDungeon then
            panel.empty:SetText("No awards to show: dungeon loot is hidden.")
        else
            panel.empty:SetText("No awards match the search.")
        end
        panel.empty:Show()
    end
end

function LootLogUI:RequestRefresh()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce("lootlog-ui", 0.2, function() LootLogUI:Refresh() end)
    else
        self:Refresh()
    end
end

----------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------

function LootLogUI:IsAvailable()
    local council = ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil()
    return (council or demoEnabled()) and true or false
end

-- Opens the "Record award" dialog, optionally prefilled (all arguments optional).
-- bossKey: bossRef key of the drop; when omitted the boss is derived from the item (and a recent kill).
-- opts.onSave(itemID, winnerKey, bossKey, note, awardReason) -> ok[, reason]: records the award instead of the plain
-- Ledger:Award (the drop panel uses it so an award of a rolled item closes the roll). The Loot Log's own
-- "Add award..." never passes it, so it does not touch rolls. opts.reason: the preselected award reason key.
function LootLogUI:OpenAwardDialog(itemID, winnerKey, bossKey, note, opts)
    local f = dialog or createDialog()
    if not f then return end
    installLinkHook()
    f.onSave = (type(opts) == "table" and type(opts.onSave) == "function") and opts.onSave or nil
    local preset = type(opts) == "table" and opts.reason or nil
    f.reasonKey = (ns.AWARD_REASON and ns.AWARD_REASON[preset]) and preset or nil
    if f.reasonDD and f.reasonDD.Refresh then f.reasonDD:Refresh() end
    f.explicitBoss = (type(bossKey) == "string" and bossKey ~= "") and bossKey or nil
    setStatus("")
    itemID = tonumber(itemID)
    setItemText(itemID and (itemLink(itemID) or tostring(itemID)) or "")
    setWinner((type(winnerKey) == "string" and winnerKey ~= "") and winnerKey or nil)
    f.noteBox:SetText(type(note) == "string" and note:sub(1, MAX_NOTE) or "")
    f:Show()
    f:Raise()
    if not itemID then f.itemBox:SetFocus() end
end

-- Alias for callers that use "Show" naming.
LootLogUI.ShowAwardDialog = LootLogUI.OpenAwardDialog

function LootLogUI:CloseAwardDialog()
    if dialog then dialog:Hide() end
end

----------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------

function LootLogUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("loot", "Loot Log", 3,
            function(parent) return LootLogUI:CreatePanel(parent) end,
            function() return LootLogUI:IsAvailable() end)
    end

    local function refresh()
        LootLogUI:RequestRefresh()
    end
    for _, msg in ipairs({ "LEDGER_UPDATED", "ROSTER_UPDATED", "LISTS_RESET", "DEMO_TOGGLED" }) do
        ns:On(msg, refresh)
    end
    ns:On("ITEMINFO_READY", function()
        refresh()
        if dialog and dialog:IsShown() then updateItemPreview() end
    end)
end
