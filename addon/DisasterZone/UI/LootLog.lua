if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LootLog.lua", ...) then return end -- DisasterZone: the Council tab's "Loot Log" view (SPEC §12.7): the council's award ledger with search, void/restore and manual awards.
-- The Council panel hosts it (CouncilUI, view "log"): its search sits where the Council's own search is, the filters
-- and Add award... (the page's main action, far right) on the row below the views. 1.4: a board layout
-- (UI:CreateLayout): its toolbar row has the count at the left, the filters and Add award... at the right; the body the
-- column titles and the rows (the shared row looks), an illustrated empty state. The award dialog is a tool window: the
-- strip banner shows the item being awarded (icon, name, boss), the form under it.
-- Dungeon-mode awards (entries with dg = true, ADDENDUM B §22.2) carry a grey "(dungeon)" tag and can be hidden.
-- Also owns the "Record award" dialog that the Council view and the drop panel reuse (LootLogUI:OpenAwardDialog).
local addonName, ns = ...

local LootLogUI = ns:NewModule("LootLogUI")

local S = ns.Style

local ROW_HEIGHT = 26
local MAX_NOTE = 60
local MAX_ITEM_ID = 200000
local MENU_CHUNK = 25
-- The Council page's grid (UI/Council.lua): its view tabs on the top row, the page's toolbar row under them (the
-- layout's), then the column titles and the list; the list's scroll bar in the right margin.
local PAD, TOP, HEAD_H = S.PAD, 36, 24
local DLG_W, DLG_H, FIELD_X = 340, 300, 64     -- the award dialog; its fields after their labels

-- Column x offsets / widths inside a row (and the header above the list); a row is 770 wide.
local COL = {
    date = { x = 6, w = 64 },
    icon = { x = 74 },
    item = { x = 100, w = 232 },     -- the longest raid item names (36 letters) fit
    winner = { x = 338, w = 128 },   -- a 12-letter name with its (guest) mark fits
    reason = { x = 470, w = 64 },    -- award reason (ADDENDUM G)
    boss = { x = 538, w = 132 },
    by = { x = 674, w = 90 },
}

local ITEM_HINT = "Shift-click, drag or type an item ID."

local state = { search = "", showVoid = false, showDungeon = true }
local panel, dialog
local linkHookInstalled = false
local prefetched = {}       -- [itemID] = true once item data was requested

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function dim(text) return S:Wrap("DIM", text) end

local function trim(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function short(key)
    if not key then return "?" end
    return ns.Util.ShortName(key) or key
end

-- The class of a winner: the guild's, else what the store learned (an outsider). TODO(refactor): UI:ClassOf.
local function classFor(key)
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
    return ns.UI:ColoredName(key, classFile or classFor(key)) .. ns.UI:GuestTag(key)
end

local function itemText(itemID)
    if not itemID then return "" end
    local text = ns.UI:ItemText(itemID)   -- drop the extra "loading" return value
    return text
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

local function isInGroup(key)
    return ns.Util and ns.Util.IsInMyGroup and ns.Util.IsInMyGroup(key) or false
end

local function isOnline(key)
    return ns.Guild and ns.Guild.IsOnline and ns.Guild:IsOnline(key) or false
end

local function sortByShortName(keys)
    local lower = {}
    for _, k in ipairs(keys) do
        lower[k] = short(k):lower()
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

local DUNGEON_TAG = dim("(dungeon)")

----------------------------------------------------------------------------
-- Ledger list
----------------------------------------------------------------------------

local function entryMatches(e)
    local s = state.search
    if s == "" then return true end
    local function has(text)
        return type(text) == "string" and text:lower():find(s, 1, true) ~= nil
    end
    return has(short(e.w)) or has(itemName(e.i)) or has(bossName(e.b))
        or has(e.by and short(e.by)) or has(e.n) or tostring(e.i) == s
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
                rows[#rows + 1] = { entry = e, itemID = id, classFile = classFor(e.w), index = #rows + 1 }
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
    tt:AddLine(S:Wrap("GOLD", "DisasterZone") .. " award")
    local r, g, b = S:Color("SUB")
    tt:AddDoubleLine("Winner", coloredName(e.w), r, g, b, 1, 1, 1)
    local label = reasonLabel(e)
    if label then
        tt:AddDoubleLine("Reason", label .. (reasonCounts(e) and "" or dim(" (not counted as loot won)")),
            r, g, b, 1, 1, 1)
    end
    if reasonCounts(e) and not ns.AwardCounts(e) then
        tt:AddLine(dim("Not gear: not counted as loot won"))
    end
    local where = bossName(e.b, true)
    if where then tt:AddDoubleLine("Boss", where, r, g, b, 1, 1, 1) end
    if isDungeonEntry(e) then tt:AddLine("5-man dungeon loot (dungeon mode)", r, g, b) end
    tt:AddDoubleLine("Date", formatDate(e.ts, "%Y-%m-%d %H:%M"), r, g, b, 1, 1, 1)
    local kind = e.s == "m" and "Manual" or "Auto (loot message)"
    tt:AddDoubleLine("Recorded", kind .. (e.by and (" by " .. short(e.by)) or ""), r, g, b, 1, 1, 1)
    if type(e.n) == "string" and e.n ~= "" then
        tt:AddLine("Note: " .. e.n, 1, 1, 1, true)
    end
    if e.vd then
        tt:AddLine("Voided " .. formatAgo(e.vts), S:Color("BAD"))
    end
    tt:AddLine("Right-click: reason, void / restore, link, show member", S:Color("DIM"))
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

local function rowTip(row, tt)
    local e = row.cdlEntry
    if not e then return false end
    tt:AddLine(itemText(tonumber(e.i)))
    addEntryLines(tt, e)
end

-- A cell of a row: a one-line text in its column (style, colour: UI:Text).
local function cellText(row, col, style, color)
    local fs = ns.UI:Text(row, style, color, { width = col.w })
    fs:SetPoint("LEFT", col.x, 0)
    return fs
end

local function setupRow(row)
    row.cdlInit = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    ns.UI:DecorateRow(row, { stripe = true })

    row.date = cellText(row, COL.date, "body", "SUB")
    row.btn = ns.UI:CreateItemButton(row, 20)
    row.btn:SetPoint("LEFT", COL.icon.x, 0)
    row.btn.onTooltip = function(btn, tt)
        addEntryLines(tt, btn:GetParent().cdlEntry)
    end
    row.btn.onClick = function(btn, mouseButton)
        rowClick(btn:GetParent(), mouseButton)
    end
    row.item = cellText(row, COL.item, "emph", "TEXT")
    row.winner = cellText(row, COL.winner, "emph", "TEXT")
    row.reason = cellText(row, COL.reason, "body", "TEXT")
    row.boss = cellText(row, COL.boss, "body", "TEXT")
    row.by = cellText(row, COL.by, "body", "DIM")

    row:SetScript("OnClick", rowClick)
    ns.UI:AttachTooltip(row, rowTip)
end

local function initRow(row, d)
    if not row.cdlInit then setupRow(row) end
    local e = d.entry
    row.cdlEntry = e
    row:SetStripe(d.index or 0)
    row.date:SetText(formatDate(e.ts))
    row.btn:SetItem(d.itemID)
    row.btn:SetBadge(nil)
    row.btn:SetState(e.vd and "dim" or nil)
    if e.vd then
        row.item:SetText(dim((itemName(d.itemID) or ("item " .. d.itemID)) .. " (void)"))
        row.winner:SetText(dim(short(e.w)))
    else
        row.item:SetText(itemText(d.itemID))
        row.winner:SetText(coloredName(e.w, d.classFile))
    end
    local label = reasonLabel(e)
    if not label then
        row.reason:SetText(dim("-"))
    elseif reasonCounts(e) and not e.vd then
        row.reason:SetText(label)
    else
        row.reason:SetText(dim(label))   -- offspec / disenchant / bank: not counted as loot won
    end
    local boss = bossName(e.b) or dim("-")
    if isDungeonEntry(e) then boss = boss .. " " .. DUNGEON_TAG end
    row.boss:SetText(boss)
    -- who typed a manual entry in; the rest came from loot messages (the tooltip has the details)
    local by = e.s == "m" and (e.by and short(e.by) or "manual") or "auto"
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
    f.bossText:SetText("Boss: " .. (where or dim("none")))
    if f.banner then f.banner:SetSub(where or "No boss") end
end

local function updateItemPreview()
    local f = dialog
    if not f then return end
    local id = parseItem(f.itemBox:GetText())
    f.itemID = id
    f.itemBtn:SetItem(id)
    -- the banner: the item being awarded
    if f.banner then
        f.banner:SetIcon(id and ns.UI:ItemIcon(id) or 134400)
        f.banner:SetTitle(id and itemText(id) or "Record award")
    end
    if id then
        f.itemHint:SetText(itemText(id))
    else
        f.itemHint:SetText(dim(ITEM_HINT))
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
    f.winBox:SetText(key and short(key) or "")
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
    if ns.Util.DemoOn() and ns.Store and ns.Store.GetAllKeys then
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
    if ns.Util.DemoOn() and ns.Store and ns.Store.GetAllKeys then
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
            if key:lower() == lower or short(key):lower() == lower then return key end
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
            local chunk = sub:CreateButton(short(keys[i]) .. " - " .. short(keys[last]))
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
    ns:Print("Recorded award: %s to %s.", itemLink(id) or itemName(id) or ("item " .. id), short(key))
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
    local eb = ns.UI:CreateSleekEditBox(parent, width, 22)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(maxLetters)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return eb
end

-- The "Record award" tool window: the strip banner shows the item being awarded (its icon, its name, the boss), the form
-- under it (item, winner, note, reason), Cancel and Save at its foot.
local function createDialog()
    local UI = ns.UI
    if not (UI and UI.CreateWindow) then return nil end
    local f = UI:CreateWindow("DisasterZoneAwardDialog", "Record award", DLG_W, DLG_H)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:Hide()
    dialog = f
    local L = UI:CreateLayout("tool", f.content or f, { width = DLG_W - 10,
        banner = { size = "strip", icon = 134400, title = "Record award" } })
    f.layout, f.banner = L, L.banner
    local c = L.body

    local function label(text, y)
        local fs = UI:Text(c, "body", "GOLD")
        fs:SetPoint("TOPLEFT", 0, y)
        fs:SetText(text)
        return fs
    end

    -- Item
    label("Item", -6)
    f.itemBtn = UI:CreateItemButton(c, 24)
    f.itemBtn:SetPoint("TOPLEFT", FIELD_X - 12, 0)
    f.itemBtn.onReceiveItem = function(_, itemID)
        setItemText(itemLink(itemID) or tostring(itemID))
    end
    f.itemBox = createEditBox(c, DLG_W - 10 - 2 * PAD - FIELD_X - 20, 255)
    f.itemBox:SetPoint("TOPLEFT", FIELD_X + 20, -1)
    f.itemBox:SetScript("OnTextChanged", function() updateItemPreview() end)
    f.itemBox:SetScript("OnReceiveDrag", receiveCursorItem)
    f.itemBox:SetScript("OnMouseUp", receiveCursorItem)
    f.itemHint = UI:Text(c, "body", "TEXT", { width = DLG_W - 10 - 2 * PAD - FIELD_X })
    f.itemHint:SetPoint("TOPLEFT", FIELD_X, -27)

    -- Winner
    label("Winner", -52)
    f.winBox = createEditBox(c, 150, 48)
    f.winBox:SetPoint("TOPLEFT", FIELD_X, -48)
    f.winBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then f.winnerKey = nil end
    end)
    f.pickBtn = UI:CreateButton(c, "Choose", 76, 22, function() openWinnerMenu(f.pickBtn) end)
    f.pickBtn:SetPoint("LEFT", f.winBox, "RIGHT", 8, 0)

    -- Note
    label("Note", -82)
    f.noteBox = createEditBox(c, DLG_W - 10 - 2 * PAD - FIELD_X, MAX_NOTE)
    f.noteBox:SetPoint("TOPLEFT", FIELD_X, -78)

    -- Reason (ADDENDUM G): offspec / disenchant / guild bank awards don't count as loot won.
    label("Reason", -112)
    f.reasonDD = UI:CreateDropdown(c, 160, function()
        local opts = { { value = "", text = "None" } }
        for _, r in ipairs(ns.AWARD_REASONS or {}) do opts[#opts + 1] = { value = r.key, text = r.label } end
        return opts
    end, function() return f.reasonKey or "" end, function(value)
        f.reasonKey = (type(value) == "string" and value ~= "") and value or nil
    end)
    f.reasonDD:SetPoint("TOPLEFT", FIELD_X, -106)

    f.bossText = UI:Text(c, "body", "SUB", { width = DLG_W - 10 - 2 * PAD })
    f.bossText:SetPoint("TOPLEFT", 0, -138)

    f.status = UI:Text(c, "body", "BAD", { width = DLG_W - 10 - 2 * PAD, wrap = true })
    f.status:SetPoint("TOPLEFT", 0, -156)

    f.saveBtn = UI:CreateSleekButton(c, "Save", 90, S.BTN_H, saveAward, "primary")
    f.saveBtn:SetPoint("BOTTOMRIGHT", 0, 0)
    f.cancelBtn = UI:CreateSleekButton(c, "Cancel", 90, S.BTN_H, function() f:Hide() end)
    f.cancelBtn:SetPoint("RIGHT", f.saveBtn, "LEFT", -6, 0)

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

local function createHeader(parent)
    local h = ns.UI:CreateColumnHeader(parent, HEAD_H)
    h:SetPoint("TOPLEFT", 0, 0)
    h:SetPoint("TOPRIGHT", 0, 0)
    h.rule = ns.UI:Rule(h, { bottom = 0, layer = "BORDER" })
    local titles = {
        { COL.date, "Date" }, { COL.item, "Item" }, { COL.winner, "Winner" }, { COL.reason, "Reason" },
        { COL.boss, "Boss" }, { COL.by, "Recorded" },
    }
    for _, t in ipairs(titles) do h:AddColumn(t[2], t[1].x, t[1].w) end
    return h
end

-- parent: the Council panel. The frame covers it; the Council's view tabs (top left) stay clickable above it.
function LootLogUI:CreatePanel(parent)
    if panel then return panel end
    local UI = ns.UI
    local p = CreateFrame("Frame", "DisasterZoneLootLogPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    p.dirty = true

    -- the Council's top row: the search in the Council search's place (hidden on this view)
    p.search = UI:CreateSearchBox(p, 150, function(text)
        state.search = trim(text):lower()
        LootLogUI:Refresh(true)
    end)
    p.search:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, -6)

    -- the page: a board layout under the Council's view tabs. Its toolbar: the count at the left, the filters and
    -- Add award... (the page's main action) at the right; the body: the column titles, then the rows.
    local L = UI:CreateLayout("board", p, { top = TOP })
    p.layout = L
    local bar = L.toolbar
    p.toolbar = bar
    bar:SetText("0 awards")
    p.count = bar.label

    -- the filters: two checkboxes in one control (the labels are part of their click areas)
    local filters = CreateFrame("Frame", nil, bar)
    filters:SetHeight(24)
    p.voidCB = UI:CreateCheckbox(filters, "Show voided", function() return state.showVoid end, function(value)
        if type(value) == "boolean" then
            state.showVoid = value
        else
            state.showVoid = not state.showVoid
        end
        LootLogUI:Refresh(true)
    end)
    p.voidCB:SetPoint("LEFT", filters, "LEFT", -4, 0)
    p.voidCB.tooltipText = "Also list the entries the council voided (greyed, right-click to restore)."
    p.dungeonCB = UI:CreateCheckbox(filters, "Show dungeon loot", function() return state.showDungeon end, function(value)
        if type(value) == "boolean" then
            state.showDungeon = value
        else
            state.showDungeon = not state.showDungeon
        end
        LootLogUI:Refresh(true)
    end)
    p.dungeonCB:SetPoint("LEFT", p.voidCB.label, "RIGHT", 10, 0)
    p.dungeonCB.tooltipText = "Awards recorded in 5-man dungeons while dungeon mode was on."
    filters:SetWidth(math.floor(64 + UI:TextWidth("Show voided", "body") + 10 + UI:TextWidth("Show dungeon loot", "body") + 0.5))
    p.filters = filters
    bar:SetFilters({ filters })
    p.addBtn = bar:SetPrimary({ text = "Add award...", onClick = function() LootLogUI:OpenAwardDialog() end })

    p.header = createHeader(L.body)

    p.list = UI:CreateScrollList(L.body, ROW_HEIGHT, initRow)
    p.list.frame:ClearAllPoints()
    p.list.frame:SetPoint("TOPLEFT", 0, -(HEAD_H + 2))
    p.list.frame:SetPoint("BOTTOMRIGHT", 0, PAD - 4)
    -- the rows take the whole width; the bar sits in the margin 4px right of them
    p.list.box:ClearAllPoints()
    p.list.box:SetPoint("TOPLEFT", p.list.frame, "TOPLEFT", 0, 0)
    p.list.box:SetPoint("BOTTOMRIGHT", p.list.frame, "BOTTOMRIGHT", 0, 0)
    if p.list.bar then
        p.list.bar:ClearAllPoints()
        p.list.bar:SetPoint("TOPLEFT", p.list.box, "TOPRIGHT", 4, 0)
        p.list.bar:SetPoint("BOTTOMLEFT", p.list.box, "BOTTOMRIGHT", 4, 0)
    end

    -- nothing to list: an illustrated empty state (p.empty:GetText() reads its words)
    p.empty = UI:CreateEmptyState(L.body, { glyph = UI.ICON.notes })
    p.empty:SetPoint("TOP", p.list.frame, "TOP", 0, -48)
    p.empty:SetFrameLevel(p.list.box:GetFrameLevel() + 5)
    p.empty:Hide()
    function p.empty:SetText(title, text)
        self:SetContent({ glyph = UI.ICON.notes, title = title, text = text })
    end
    function p.empty:GetText()
        local t = self.content or {}
        return (t.title or "") .. ((t.text and t.text ~= "") and ("\n" .. t.text) or "")
    end

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
    panel.count:SetShown(total > 0)
    if #rows > 0 then
        panel.empty:Hide()
    else
        if total == 0 then
            panel.empty:SetText("No awards recorded yet.", "They are logged from loot messages while you raid.")
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
