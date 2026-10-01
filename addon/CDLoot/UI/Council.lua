if CDLootBoot and CDLootBoot.Run("UI/Council.lua", ...) then return end -- CDLoot: "Council" tab (SPEC §12.6): roster x slot matrix, "who wants it" per boss, read-only member view,
-- and the Loot Council view (ADDENDUM E §30: guild council picked by the GM, raid council by the raid leader).
-- Only offered to Loot Council members (or in demo mode). Built from ns.UI widgets and ns.PaperDoll.
-- ADDENDUM F: slots a player disabled show a dark "–" and are left out of the counts (§36); the raid leader
-- locks / unlocks the BiS lists from the toolbar, and players who changed their list while locked carry a
-- warning marker in the roster, the Items view and the member header (§38).
local addonName, ns = ...

local CouncilUI = ns:NewModule("CouncilUI")

local NUM_SLOTS = ns.NUM_SLOTS or 17
local ROW_HEIGHT = 24
local CELL_SIZE = 20
local CELL_PITCH = 22
local CELL_X0 = 262
local GROUP_GAP = 6
local TREE_WIDTH = 200
local TREE_ROW_HEIGHT = 18
local ITEM_ROW_HEIGHT = 40
local STALE_SECONDS = 7 * 86400
local MAX_TOOLTIP_WANTERS = 20
local MAX_WEAR_LINES = 10           -- "Wearing: A, B" sub-lines in the Items view tooltip
local MAX_AWARD_LINES = 4
local ANNOUNCE_COOLDOWN = 2
local OTHER_NODE = "OTHER"

local ROLE_ORDER = { "tank", "healer", "melee", "caster", "ranged" }
local DEFAULT_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local PRESENCE_RANK = { raid = 1, online = 2, offline = 3 }
local PRESENCE_TEX = {
    raid = "Interface\\COMMON\\Indicator-Green",
    online = "Interface\\COMMON\\Indicator-Yellow",
    offline = "Interface\\COMMON\\Indicator-Gray",
}
local PRESENCE_TEXT = { raid = "In your raid", online = "Online", offline = "Offline" }
-- Paired slots (ADDENDUM A §18): rings, trinkets and weapons show both worn items.
local SLOT_GROUP_FALLBACK = {
    [11] = { 11, 12 }, [12] = { 11, 12 }, [13] = { 13, 14 }, [14] = { 13, 14 }, [15] = { 15, 16 }, [16] = { 15, 16 },
}
local CHECK_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"
local ROW_HILIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
local SLOT_BG = "Interface\\Buttons\\UI-Quickslot2"
local FALLBACK_COLORS = {
    main = { 0.98, 0.78, 0.22 },
    alt = { 0.41, 0.80, 0.94 },
    obtained = { 0.30, 0.90, 0.40 },
    needed = { 1, 1, 1 },
    muted = { 0.55, 0.55, 0.55 },
    warn = { 1.00, 0.55, 0.20 },
    bad = { 1.00, 0.30, 0.30 },
    council = { 1.00, 0.50, 0.00 },
}

-- Session-only view state (not saved).
local state = {
    phase = nil,           -- nil = follow ns.Guild:GetViewPhase()
    view = "roster",       -- "roster" | "items" | "member"
    search = "",           -- lower-cased search text
    class = "ALL",
    role = "ALL",
    raidOnly = false,
    hideObtained = true,
    sort = "presence",     -- "presence" | "name" | "need" | "age"
    selectedNode = nil,    -- bossRef key or OTHER_NODE (Items view)
    focus = nil,           -- set of itemIDs to highlight in the Items view
    scrollToFocus = false,
    memberKey = nil,       -- Member view
    offspec = false,       -- Addendum H: Roster / Items / Member show the off-spec lists
}

local panel                 -- created lazily by MainFrame
local order = {}            -- filtered + sorted roster keys, used by the member view arrows
local lastAnnounce = {}     -- [itemID] = GetTime() of the last announce
local prefetched = {}       -- [itemID] = true once item data was requested

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

local function color(name)
    local c = ns.COLORS and ns.COLORS[name]
    if type(c) ~= "table" then c = FALLBACK_COLORS[name] or FALLBACK_COLORS.needed end
    return c[1], c[2], c[3]
end

local function colorCode(name)
    local r, g, b = color(name)
    return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function grey(text)
    return "|cff808080" .. tostring(text) .. "|r"
end

local function texPath(name, fallback)
    local t = ns.TEX and ns.TEX[name]
    return t or fallback
end

local function shortName(key)
    if not key then return "?" end
    if ns.Util and ns.Util.ShortName then
        return ns.Util.ShortName(key) or key
    end
    return key
end

local function coloredName(key, classFile)
    if ns.UI and ns.UI.ColoredName then
        return ns.UI:ColoredName(key, classFile)
    end
    return shortName(key)
end

local function className(classFile)
    if type(classFile) ~= "string" or classFile == "" then return "" end
    local loc = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]
    if loc then return loc end
    return classFile:sub(1, 1) .. classFile:sub(2):lower()
end

local function formatAgo(ts)
    if ns.Util and ns.Util.FormatAgo then
        return ns.Util.FormatAgo(ts)
    end
    return tostring(ts or "never")
end

-- Compact age for the roster column: "5m", "3h", "2d"; "-" when unknown.
local function shortAge(ts)
    ts = tonumber(ts) or 0
    if ts <= 0 then return "-" end
    local d = GetServerTime() - ts
    if d < 3600 then return math.max(1, math.floor(d / 60)) .. "m" end
    if d < 86400 then return math.floor(d / 3600) .. "h" end
    return math.floor(d / 86400) .. "d"
end

local function toSet(arr)
    local s = {}
    if type(arr) == "table" then
        for _, v in ipairs(arr) do
            s[v] = true
        end
    end
    return s
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

local function itemIcon(itemID)
    if itemID and ns.ItemDB and ns.ItemDB.GetIcon then
        return ns.ItemDB:GetIcon(itemID)
    end
    return 134400
end

local function slotGroup(sid)
    local g = ns.SLOT_GROUP and ns.SLOT_GROUP[sid]
    if type(g) == "table" and #g > 0 then return g end
    return SLOT_GROUP_FALLBACK[sid] or { sid }
end

-- Worn item IDs of a ListData table for the slot group of `sid`, in slot order.
local function wornInGroup(data, sid)
    local out = {}
    local eq = type(data) == "table" and type(data.eq) == "table" and data.eq
    if not eq or not sid then return out end
    for _, g in ipairs(slotGroup(sid)) do
        local id = tonumber(eq[g])
        if id and id > 0 then out[#out + 1] = id end
    end
    return out
end

-- "Wearing: A, B" from a Store:GetWanters entry (equippedList, else the single equipped item).
local function wearingLine(e)
    local list = type(e.equippedList) == "table" and e.equippedList or { e.equipped }
    local parts = {}
    for _, v in ipairs(list) do
        local id = tonumber(v)
        if id and id > 0 and #parts < 2 then parts[#parts + 1] = (itemText(id)) end
    end
    if #parts == 0 then return nil end
    return "Wearing: " .. table.concat(parts, ", ")
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

local function presenceOf(key)
    if isInGroup(key) then return "raid" end
    if isOnline(key) then return "online" end
    return "offline"
end

local function hasAward(key, itemID)
    if not (itemID and ns.Ledger and ns.Ledger.HasAward) then return false end
    return ns.Ledger:HasAward(key, itemID) and true or false
end

local function currentPhase()
    local p = state.phase
    if not p and ns.Guild and ns.Guild.GetViewPhase then
        p = ns.Guild:GetViewPhase()
    end
    p = tonumber(p) or 1
    if p < 1 or p > (ns.MAX_PHASE or 5) then p = 1 end
    return p
end

-- §36: the player disabled this slot for the phase (Store:IsSlotDisabled, else the record's dx).
local function slotDisabled(rec, phase, sid)
    local S = ns.Store
    if type(S) == "table" and type(S.IsSlotDisabled) == "function" then
        return S:IsSlotDisabled(rec, phase, sid) and true or false
    end
    local data = type(rec) == "table" and type(rec.data) == "table" and rec.data or nil
    local dx = data and type(data.dx) == "table" and data.dx[phase]
    return type(dx) == "table" and dx[sid] == true
end

-- §38: when the player changed their list while the lists were locked (serverTime), else nil.
local function lockChangedAt(key)
    return ns.UI and ns.UI.LockChangedAt and ns.UI:LockChangedAt(key) or nil
end

local function warnIcon(size)
    if ns.UI and ns.UI.WarnIcon then return ns.UI:WarnIcon(size or 12) end
    return "!"
end

-- main, alt item IDs of one slot in one phase of a ListData table (nil when empty / malformed).
local function getPicks(data, phase, sid)
    local ph = type(data) == "table" and type(data.ph) == "table" and data.ph[phase]
    local s = type(ph) == "table" and ph[sid]
    if type(s) ~= "table" then return nil, nil end
    local main, alt = tonumber(s[1]), tonumber(s[2])
    if main and main <= 0 then main = nil end
    if alt and alt <= 0 then alt = nil end
    return main, alt
end

local function memberClass(key, data)
    local cl = type(data) == "table" and data.cl
    if type(cl) ~= "string" or cl == "" then
        cl = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)
    end
    return cl
end

local function specRole(classFile, spec)
    if ns.GetSpecRole and classFile and spec and spec ~= "" then
        return ns.GetSpecRole(classFile, spec)
    end
    return nil
end

-- Class / role / raid filters. The search text is handled separately (it means different things per view).
local function passesFilters(classFile, spec, inRaid)
    if state.class ~= "ALL" and classFile ~= state.class then return false end
    if state.role ~= "ALL" and specRole(classFile, spec) ~= state.role then return false end
    if state.raidOnly and not inRaid then return false end
    return true
end

local function nameMatches(key)
    if state.search == "" then return true end
    return shortName(key):lower():find(state.search, 1, true) ~= nil
end

-- ns.UI lists keep their scroll position on SetData unless resetScroll is passed.
local function setListData(list, rows, resetScroll)
    if not list then return end
    list:SetData(rows, resetScroll and true or false)
    if resetScroll and list.box and list.box.SetScrollPercentage then
        list.box:SetScrollPercentage(0)
    end
end

local function scrollListTo(list, predicate)
    local box = list and list.box
    if not (box and box.FindElementDataIndexByPredicate and box.ScrollToElementDataIndex) then return end
    local index = box:FindElementDataIndexByPredicate(predicate)
    if index then
        box:ScrollToElementDataIndex(index, 0.5)
    end
end

local function openAwardDialog(itemID, winnerKey, bossKey)
    local log = ns.LootLogUI
    if log and log.OpenAwardDialog then
        log:OpenAwardDialog(itemID, winnerKey, bossKey)
    end
end

-- A roll of this item that is still running or waiting for its award (open / closed), in a drop of the last
-- 15 minutes: session, drop. nil when there is none (loot-marked or awarded rolls are settled already).
local LIVE_ROLL_AGE = 15 * 60
local function liveRollFor(itemID)
    itemID = tonumber(itemID)
    local Loot, DP = ns.Loot, ns.DropPanel
    if not (itemID and Loot and Loot.GetHistory and DP and DP.FindRollSession) then return nil end
    local hist = Loot:GetHistory()
    local cutoff = GetServerTime() - LIVE_ROLL_AGE
    for k = #hist, 1, -1 do
        local d = hist[k]
        if type(d) == "table" and type(d.i) == "table" and (tonumber(d.ts) or 0) >= cutoff then
            for _, id in ipairs(d.i) do
                if tonumber(id) == itemID then
                    local ses = DP:FindRollSession(itemID, d)
                    if type(ses) == "table" and (ses.state == "open" or ses.state == "closed") then return ses, d end
                    break
                end
            end
        end
    end
    return nil
end

-- An award from the Items view goes through the item's running roll when there is one (it closes the roll on
-- every client and records exactly one log entry, Addendum C §23.2); otherwise it is a plain log entry.
-- reason (optional, ADDENDUM G): an award reason key (main pick -> "bis", alt -> "alt").
local function recordAward(itemID, key, bossKey, reason)
    if not (itemID and key) then return end
    local ses, drop = liveRollFor(itemID)
    if ses and ns.DropPanel and ns.DropPanel.Award then
        local ok, why = ns.DropPanel:Award(itemID, key, drop.b, ses.c, drop, nil, reason)
        if not ok and why then ns:Print("%s", why) end
        return
    end
    if not (ns.Ledger and ns.Ledger.Award) then return end
    local entry = ns.Ledger:Award(itemID, key, bossKey or "", nil, nil, reason)
    if entry then
        ns:Print("Recorded award: %s to %s.", itemLink(itemID) or itemName(itemID) or ("item " .. itemID), shortName(key))
    end
end

local function awardSomeoneElse(itemID, bossKey)
    local ses, drop = liveRollFor(itemID)
    if ses and ns.DropPanel and ns.DropPanel.AwardSomeoneElse then
        ns.DropPanel:AwardSomeoneElse(itemID, drop.b, ses.c, drop)
        return
    end
    openAwardDialog(itemID, nil, bossKey)
end

----------------------------------------------------------------------------
-- Data building
----------------------------------------------------------------------------

-- All members with a list that pass the class/role/raid filters (search is flagged, not applied).
local function buildMembers(phase)
    local members = {}
    local stats = { total = 0, inRaid = 0, stale = 0 }
    local store = ns.Store
    if not (store and store.GetAllKeys and store.Get) then return members, stats end
    local now = GetServerTime()
    for _, key in ipairs(store:GetAllKeys() or {}) do
        local rec = store:Get(key)
        local data = type(rec) == "table" and rec.data
        -- Addendum H: the off-spec view shows the players who have an off-spec list, as that list.
        if state.offspec then
            if type(data) == "table" and ns.HasOffSpec(data) then
                rec = ns.ListRecordView(rec, "os")
                data = rec.data
            else
                data = nil
            end
        end
        if type(data) == "table" then
            local cl = memberClass(key, data)
            local spec = type(data.sp) == "string" and data.sp or ""
            local pres = presenceOf(key)
            local ts = tonumber(rec.ts) or 0
            local stale = ts > 0 and (now - ts) > STALE_SECONDS
            stats.total = stats.total + 1
            if pres == "raid" then stats.inRaid = stats.inRaid + 1 end
            if stale then stats.stale = stats.stale + 1 end
            if passesFilters(cl, spec, pres == "raid") then
                local ob = toSet(data.ob)
                local filled, need, disabled = 0, 0, 0
                for sid = 1, NUM_SLOTS do
                    if slotDisabled(rec, phase, sid) then
                        disabled = disabled + 1   -- not needed: left out of the counts (§36)
                    else
                        local main = getPicks(data, phase, sid)
                        if main then
                            filled = filled + 1
                            if not ob[main] then need = need + 1 end
                        end
                    end
                end
                local short = shortName(key)
                members[#members + 1] = {
                    key = key, record = rec, data = data, classFile = cl, spec = spec,
                    presence = pres, inRaid = pres == "raid", ts = ts, stale = stale,
                    rev = tonumber(rec.rev) or 0, ob = ob, filled = filled, need = need, disabled = disabled,
                    lockChanged = lockChangedAt(key),
                    sortName = short:lower(), searchHit = nameMatches(key),
                }
            end
        end
    end
    return members, stats
end

local function tieBreak(a, b)
    if a.sortName ~= b.sortName then return a.sortName < b.sortName end
    return a.key < b.key
end

local SORTS = {
    presence = function(a, b)
        local ra, rb = PRESENCE_RANK[a.presence] or 9, PRESENCE_RANK[b.presence] or 9
        if ra ~= rb then return ra < rb end
        return tieBreak(a, b)
    end,
    name = tieBreak,
    need = function(a, b)
        if a.need ~= b.need then return a.need > b.need end
        return tieBreak(a, b)
    end,
    age = function(a, b)
        if a.ts ~= b.ts then return a.ts < b.ts end
        return tieBreak(a, b)
    end,
}

-- Demand per boss for the Items tree, counted straight from the lists (cheap; no per-item GetWanters).
local function buildDemand(phase, members)
    local byBoss, other = {}, {}
    local itemDB = ns.ItemDB
    local seen, m

    -- Counts one wanted item once per member, against every distinct raid boss that drops it (or its token).
    -- Only raid sources: the tree lists raids, so 5-man dungeon items are counted under "Other".
    local function count(id)
        if not id or seen[id] or (state.hideObtained and m.ob[id]) then return end
        seen[id] = true
        local srcs = itemDB and itemDB.GetSources and itemDB:GetSources(id, "raids")
        if type(srcs) == "table" and #srcs > 0 then
            local bosses = {}
            for _, src in ipairs(srcs) do
                local k = src.ref and src.ref.key
                if k and not bosses[k] then
                    bosses[k] = true
                    byBoss[k] = (byBoss[k] or 0) + 1
                end
            end
        else
            other[id] = (other[id] or 0) + 1
        end
    end

    for _, member in ipairs(members) do
        m, seen = member, {}
        for sid = 1, NUM_SLOTS do
            if not slotDisabled(member.record, phase, sid) then
                local main, alt = getPicks(member.data, phase, sid)
                count(main)
                count(alt)
            end
        end
    end
    return byBoss, other
end

local function buildTree(phase, byBoss, other)
    local rows = {}
    local raids = ns.ItemDB and ns.ItemDB.GetRaids and ns.ItemDB:GetRaids() or {}
    -- The chosen phase's raids first, then other raids that have demand.
    local ordered = {}
    for _, raid in ipairs(raids) do
        if raid.phase == phase then ordered[#ordered + 1] = raid end
    end
    for _, raid in ipairs(raids) do
        if raid.phase ~= phase then ordered[#ordered + 1] = raid end
    end
    for _, raid in ipairs(ordered) do
        local bossRows, total = {}, 0
        for _, boss in ipairs(raid.bosses or {}) do
            if raid.key and boss.key then
                local key = raid.key .. ":" .. boss.key
                local n = byBoss[key] or 0
                if n > 0 or key == state.selectedNode or (raid.phase == phase and not boss.isTrash) then
                    bossRows[#bossRows + 1] = { type = "boss", key = key, name = boss.name or boss.key, count = n }
                    total = total + n
                end
            end
        end
        if #bossRows > 0 then
            rows[#rows + 1] = { type = "raid", name = raid.name or raid.key or "?", phase = raid.phase, count = total }
            for _, r in ipairs(bossRows) do
                rows[#rows + 1] = r
            end
        end
    end
    local otherTotal = 0
    for _, n in pairs(other) do
        otherTotal = otherTotal + n
    end
    if otherTotal > 0 or state.selectedNode == OTHER_NODE then
        rows[#rows + 1] = { type = "other", key = OTHER_NODE, name = "Other / no raid source", count = otherTotal }
    end
    return rows
end

local function phaseListed(e, phase)
    if type(e.phases) == "table" then
        for _, p in ipairs(e.phases) do
            if p == phase then return true end
        end
        return false
    end
    return e.phase == nil or e.phase == phase
end

local function wantersFor(itemID, phase)
    local out = {}
    local store = ns.Store
    if not (store and store.GetWanters) then return out end
    local list = store:GetWanters(itemID, { includeObtained = not state.hideObtained, phase = phase,
        list = state.offspec and "os" or nil })
    if type(list) ~= "table" then return out end
    for _, e in ipairs(list) do
        if type(e) == "table" and e.key and phaseListed(e, phase)
            and (not state.hideObtained or not e.obtained)
            and passesFilters(e.classFile, e.spec, e.inRaid) then
            out[#out + 1] = e
        end
    end
    return out
end

-- One entry per player (the first = best-sorted one).
local function uniqueWanters(wanters)
    local seen, out = {}, {}
    for _, e in ipairs(wanters or {}) do
        if not seen[e.key] then
            seen[e.key] = true
            out[#out + 1] = e
        end
    end
    return out
end

local function itemTypeText(itemID, isToken)
    if isToken then return "Token" end
    local loc = ns.ItemDB and ns.ItemDB.GetEquipLoc and ns.ItemDB:GetEquipLoc(itemID)
    if type(loc) == "string" and loc ~= "" then
        local label = _G[loc]
        return type(label) == "string" and label or loc
    end
    return ""
end

local function itemRowMatchesSearch(row)
    if state.search == "" then return true end
    local name = itemName(row.itemID)
    if name and name:lower():find(state.search, 1, true) then return true end
    if tostring(row.itemID) == state.search then return true end
    for _, e in ipairs(row.wanters) do
        if nameMatches(e.key) then return true end
    end
    return false
end

local function buildItemRows(phase, node, other)
    local rows = {}
    if not node then return rows end
    local itemDB = ns.ItemDB
    local ids, bossKey = {}, ""
    if node == OTHER_NODE then
        for id in pairs(other) do
            ids[#ids + 1] = id
        end
        table.sort(ids)
    else
        local ref = itemDB and itemDB.GetBossRef and itemDB:GetBossRef(node)
        ids = ref and ref.boss and ref.boss.items or {}
        bossKey = node
    end
    for index, id in ipairs(ids) do
        if type(id) == "number" then
            local isToken = itemDB and itemDB.IsToken and itemDB:IsToken(id) or false
            local equippable = itemDB and itemDB.GetEquipLoc and itemDB:GetEquipLoc(id)
            if node == OTHER_NODE or isToken or equippable then
                local w = wantersFor(id, phase)
                local row = {
                    itemID = id, isToken = isToken, wanters = w, n = #uniqueWanters(w),
                    index = index, bossKey = bossKey, phase = phase,
                    focus = state.focus and state.focus[id] or false,
                }
                if itemRowMatchesSearch(row) then
                    rows[#rows + 1] = row
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.index < b.index
    end)
    -- Request item data once per item per session (avoids re-requesting IDs that never load).
    if itemDB and itemDB.Prefetch then
        local pre = {}
        for _, r in ipairs(rows) do
            if not prefetched[r.itemID] then
                prefetched[r.itemID] = true
                pre[#pre + 1] = r.itemID
            end
        end
        if #pre > 0 then itemDB:Prefetch(pre) end
    end
    return rows
end

----------------------------------------------------------------------------
-- Tooltips
----------------------------------------------------------------------------

local function findAward(key, itemID)
    if not (ns.Ledger and ns.Ledger.GetVisibleEntries and key and itemID) then return nil end
    for _, e in ipairs(ns.Ledger:GetVisibleEntries({ player = key }) or {}) do
        if not e.vd then
            if e.i == itemID then return e end
            local expanded = ns.ItemDB and ns.ItemDB.ExpandDrop and ns.ItemDB:ExpandDrop(e.i)
            for _, id in ipairs(expanded or {}) do
                if id == itemID then return e end
            end
        end
    end
    return nil
end

local function addWantersTooltip(tt, d)
    local wanters = d.wanters or {}
    tt:AddLine(" ")
    tt:AddLine(string.format("|cffff8000CDLoot|r · P%d: %d wanting", d.phase or currentPhase(), d.n or 0))
    if #wanters == 0 then
        tt:AddLine("Nobody has this on their list.", 0.6, 0.6, 0.6)
    end
    local wearLines = 0
    for i, e in ipairs(wanters) do
        if i > MAX_TOOLTIP_WANTERS then
            tt:AddLine(string.format("+%d more", #wanters - MAX_TOOLTIP_WANTERS), 0.6, 0.6, 0.6)
            break
        end
        local left = coloredName(e.key, e.classFile)
        if type(e.spec) == "string" and e.spec ~= "" then
            left = left .. grey(" " .. e.spec)
        end
        if e.wanted and e.wanted ~= d.itemID then
            left = left .. grey(" > " .. (itemName(e.wanted) or ("item " .. e.wanted)))
        end
        local flags = {}
        if e.which == "alt" then
            flags[#flags + 1] = colorCode("alt") .. "Alt|r"
        else
            flags[#flags + 1] = colorCode("main") .. "BiS|r"
        end
        if e.obtained then flags[#flags + 1] = colorCode("obtained") .. "obtained|r" end
        if e.awarded then flags[#flags + 1] = "awarded" end
        local won = tonumber(e.wonTonight)
        if won and won > 0 then
            flags[#flags + 1] = "won " .. won
        end
        local att = ns.RaidLog and ns.RaidLog.GetAttendance and ns.RaidLog:GetAttendance(e.key)
        if att then flags[#flags + 1] = "att " .. att .. "%" end   -- Addendum I: last 8 raids
        if e.inRaid then
            flags[#flags + 1] = "in raid"
        else
            flags[#flags + 1] = e.online and "online" or "offline"
        end
        if e.lockChanged or lockChangedAt(e.key) then
            -- §38: changed their list while the lists were locked
            left = left .. " " .. warnIcon(12)
            flags[#flags + 1] = colorCode("warn") .. "changed during lock|r"
        end
        tt:AddDoubleLine(left, table.concat(flags, " · "), 1, 1, 1, 0.8, 0.8, 0.8)
        if not e.obtained and wearLines < MAX_WEAR_LINES then
            local wear = wearingLine(e)
            if wear then
                wearLines = wearLines + 1
                tt:AddLine("    " .. wear, 0.6, 0.6, 0.6)
            end
        end
    end
    tt:AddLine("Click: link, announce, award or show a member", 0.5, 0.5, 0.5)
end

local function wantersLine(d)
    local wanters = d.wanters or {}
    if #wanters == 0 then
        return grey(string.format("Nobody has this on their P%d list", d.phase or currentPhase()))
    end
    local mains, alts = {}, {}
    for _, e in ipairs(uniqueWanters(wanters)) do
        local name
        if e.obtained then
            name = grey(shortName(e.key)) .. CHECK_ICON
        else
            name = coloredName(e.key, e.classFile)
        end
        if e.lockChanged or lockChangedAt(e.key) then name = name .. warnIcon(10) end
        if e.which == "alt" then
            alts[#alts + 1] = name .. grey(" (alt)")
        else
            mains[#mains + 1] = name
        end
    end
    for _, a in ipairs(alts) do
        mains[#mains + 1] = a
    end
    return table.concat(mains, ", ")
end

----------------------------------------------------------------------------
-- Roster view
----------------------------------------------------------------------------

local function cellX(sid)
    local x = CELL_X0 + (sid - 1) * CELL_PITCH
    if sid > 10 then x = x + GROUP_GAP end
    if sid > 14 then x = x + GROUP_GAP end
    return x
end

local AGE_X = cellX(NUM_SLOTS) + CELL_SIZE + 10

local function cellTooltip(cell, tt)
    local d = cell.cdlRow
    if not d then return end
    local sid, main, alt = cell.cdlSid, cell.cdlMain, cell.cdlAlt
    local slot = ns.SLOTS and ns.SLOTS[sid]
    local slotLabel = slot and slot.label or ("Slot " .. tostring(sid))
    local phase = currentPhase()
    if cell.cdlDisabled then
        -- §36: the player doesn't need this slot in this phase
        tt:AddLine(slotLabel)
        tt:AddLine("Disabled by player", 0.75, 0.75, 0.75)
        tt:AddLine(coloredName(d.key, d.classFile) .. grey(string.format(" doesn't need this slot in P%d.", phase)))
        tt:AddLine("Click: member view", 0.5, 0.5, 0.5)
        return
    end
    if main then
        tt:AddLine(" ")
        tt:AddLine("|cffff8000CDLoot|r · " .. coloredName(d.key, d.classFile) .. " - " .. slotLabel)
        tt:AddLine(string.format("Main (P%d)", phase), color("main"))
    else
        tt:AddLine(slotLabel)
        tt:AddLine(coloredName(d.key, d.classFile) .. grey(string.format(" has no P%d pick here.", phase)))
    end
    if alt then
        tt:AddLine("Alt: " .. itemText(alt), color("alt"))
    end
    if main then
        if d.ob[main] then
            tt:AddLine("Obtained", color("obtained"))
        else
            local e = findAward(d.key, main)
            if e then
                tt:AddLine("Awarded " .. formatAgo(e.ts), color("main"))
            end
        end
    end
    -- Rings / trinkets / weapons: both worn items of the pair ("Wearing: A, B").
    local worn = wornInGroup(d.data, sid)
    if #worn == 1 and worn[1] == main then
        tt:AddLine("Wearing it", color("obtained"))
    elseif #worn > 0 then
        local parts = {}
        for i, id in ipairs(worn) do
            parts[i] = (itemText(id)) .. (id == main and (" " .. CHECK_ICON) or "")
        end
        tt:AddLine("Wearing: " .. table.concat(parts, ", "), 0.8, 0.8, 0.8)
    end
    if main then
        tt:AddLine("Click: who wants items from this boss", 0.5, 0.5, 0.5)
        tt:AddLine("Right-click: member view", 0.5, 0.5, 0.5)
    else
        tt:AddLine("Click: member view", 0.5, 0.5, 0.5)
    end
end

local function cellClick(cell, mouseButton)
    local d = cell.cdlRow
    if not d then return end
    if mouseButton == "RightButton" or not cell.cdlMain or cell.cdlDisabled then
        CouncilUI:ShowMember(d.key)
    else
        CouncilUI:ShowItem(cell.cdlMain, d.key)
    end
end

-- §36: a dark cell with a "–" (created on first use).
local function setCellDisabled(cell, disabled)
    if disabled and not cell.cdlShade then
        cell.cdlShade = cell:CreateTexture(nil, "OVERLAY", nil, 1)
        cell.cdlShade:SetAllPoints()
        cell.cdlShade:SetColorTexture(0, 0, 0, 0.6)
        cell.cdlDash = cell:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        cell.cdlDash:SetPoint("CENTER", cell, "CENTER", 0, 1)
        cell.cdlDash:SetText("\226\128\147")   -- "–" (U+2013 is in the game fonts)
    end
    if cell.cdlShade then
        cell.cdlShade:SetShown(disabled)
        cell.cdlDash:SetShown(disabled)
    end
end

local function paintCell(cell, d, sid, phase)
    local disabled = slotDisabled(d.record, phase, sid)
    local main, alt = getPicks(d.data, phase, sid)
    if disabled then main, alt = nil, nil end
    cell.cdlRow, cell.cdlSid, cell.cdlMain, cell.cdlAlt = d, sid, main, alt
    cell.cdlDisabled = disabled or nil
    setCellDisabled(cell, disabled)
    cell:SetAlpha(1)
    cell:SetItem(main, texPath("slotBg", SLOT_BG))
    cell:SetBadge(nil)
    local st, dim = nil, false
    if main then
        if d.ob[main] then
            st = "obtained"
            dim = state.hideObtained
        elseif hasAward(d.key, main) then
            st = "awarded"
        end
    end
    cell:SetState(st)
    if dim then cell:SetAlpha(0.35) end
end

local function rosterRowEnter(row)
    local d = row.cdlData
    if not d then return end
    local phase = currentPhase()
    GameTooltip:SetOwner(row, "ANCHOR_TOPLEFT")
    GameTooltip:AddLine(coloredName(d.key, d.classFile))
    local specClass = (d.spec ~= "" and (d.spec .. " ") or "") .. className(d.classFile)
    if specClass ~= "" then GameTooltip:AddLine(specClass, 1, 1, 1) end
    local rank = ns.Guild and ns.Guild.GetRankName and ns.Guild:GetRankName(d.key)
    if rank then GameTooltip:AddLine(rank, 0.8, 0.8, 0.8) end
    GameTooltip:AddLine(PRESENCE_TEXT[d.presence] or "", 0.8, 0.8, 0.8)
    local counts = string.format("P%d: %d picks · %d obtained · %d needed", phase, d.filled, d.filled - d.need, d.need)
    if (d.disabled or 0) > 0 then counts = counts .. string.format(" · %d disabled", d.disabled) end
    GameTooltip:AddLine(counts, 1, 1, 1)
    local updated = "List updated " .. formatAgo(d.ts)
    if d.rev > 0 then updated = updated .. string.format(" (rev %d)", d.rev) end
    if d.stale then
        GameTooltip:AddLine(updated, color("warn"))
    else
        GameTooltip:AddLine(updated, 0.8, 0.8, 0.8)
    end
    if d.lockChanged and ns.UI and ns.UI.AddLockChangedLine then
        ns.UI:AddLockChangedLine(GameTooltip, d.lockChanged, "Not suggested as a roll winner; the council can still award.")
    end
    GameTooltip:AddLine("Click: open member view", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function setupRosterRow(row)
    row.cdlInit = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(texPath("rowHilight", ROW_HILIGHT))
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.5)

    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetSize(12, 12)
    row.dot:SetPoint("LEFT", 4, 0)

    row.classIcon = row:CreateTexture(nil, "ARTWORK")
    row.classIcon:SetSize(14, 14)
    row.classIcon:SetPoint("LEFT", 20, 0)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", 38, 0)
    row.name:SetWidth(116)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    -- §38: "changed during lock" marker at the end of the name column (tooltip: the row's)
    row.lockWarn = row:CreateTexture(nil, "OVERLAY")
    row.lockWarn:SetSize(13, 13)
    row.lockWarn:SetPoint("LEFT", 141, 0)
    row.lockWarn:SetTexture((ns.UI and ns.UI.ICON_WARN) or "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
    row.lockWarn:Hide()

    row.spec = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.spec:SetPoint("LEFT", 158, 0)
    row.spec:SetWidth(70)   -- "Marksmanship" / "Beast Mastery" need ~69 px
    row.spec:SetJustifyH("LEFT")
    row.spec:SetWordWrap(false)

    row.need = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.need:SetPoint("LEFT", 230, 0)
    row.need:SetWidth(28)
    row.need:SetJustifyH("CENTER")

    row.cells = {}
    for sid = 1, NUM_SLOTS do
        local cell = ns.UI:CreateItemButton(row, CELL_SIZE)
        cell:SetPoint("LEFT", row, "LEFT", cellX(sid), 0)
        cell.onTooltip = cellTooltip
        cell.onClick = cellClick
        row.cells[sid] = cell
    end

    row.age = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.age:SetPoint("LEFT", AGE_X, 0)
    row.age:SetWidth(36)
    row.age:SetJustifyH("LEFT")

    row:SetScript("OnClick", function(self)
        if self.cdlData then CouncilUI:ShowMember(self.cdlData.key) end
    end)
    row:SetScript("OnEnter", rosterRowEnter)
    row:SetScript("OnLeave", hideTooltip)
end

local function initRosterRow(row, d)
    if not row.cdlInit then setupRosterRow(row) end
    row.cdlData = d
    local phase = currentPhase()
    row.dot:SetTexture(PRESENCE_TEX[d.presence] or PRESENCE_TEX.offline)
    if ns.UI and ns.UI.ClassIcon then ns.UI:ClassIcon(row.classIcon, d.classFile) end
    row.name:SetText(coloredName(d.key, d.classFile))
    row.name:SetWidth(d.lockChanged and 101 or 116)
    row.lockWarn:SetShown(d.lockChanged and true or false)
    row.spec:SetText(d.spec ~= "" and d.spec or "-")
    if d.filled == 0 then
        row.need:SetText(grey("-"))
    elseif d.need == 0 then
        row.need:SetText(colorCode("obtained") .. "0|r")
    else
        row.need:SetText(tostring(d.need))
    end
    for sid = 1, NUM_SLOTS do
        paintCell(row.cells[sid], d, sid, phase)
    end
    row.age:SetText(shortAge(d.ts))
    if d.stale then
        row.age:SetTextColor(color("warn"))
    else
        row.age:SetTextColor(0.55, 0.55, 0.55)
    end
end

local SORT_LABELS = { presence = "presence", name = "name", need = "most needed", age = "oldest list" }

local function createRosterHeader(parent)
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(20)
    h.sortButtons = {}

    -- sortKeys: clicking cycles through them (Name: presence -> name).
    local function textHeader(text, x, width, sortKeys, justify)
        local b = CreateFrame("Button", nil, h)
        b:SetPoint("LEFT", x, 0)
        b:SetSize(width, 18)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetAllPoints()
        fs:SetJustifyH(justify or "LEFT")
        fs:SetText(text)
        b.label = fs
        b.sortKeys = sortKeys
        b:SetScript("OnClick", function()
            local nextKey = sortKeys[1]
            for i, k in ipairs(sortKeys) do
                if k == state.sort then
                    nextKey = sortKeys[i % #sortKeys + 1]
                    break
                end
            end
            state.sort = nextKey
            CouncilUI:Refresh(true)
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local labels = {}
            for _, k in ipairs(sortKeys) do
                labels[#labels + 1] = SORT_LABELS[k] or k
            end
            GameTooltip:AddLine("Sort by " .. table.concat(labels, " / "))
            GameTooltip:AddLine("Current: " .. (SORT_LABELS[state.sort] or state.sort), 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", hideTooltip)
        h.sortButtons[#h.sortButtons + 1] = b
        return b
    end

    textHeader("Name", 4, 150, { "presence", "name" })
    textHeader("Need", 230, 28, { "need" }, "CENTER")
    textHeader("Age", AGE_X, 36, { "age" })
    local specLabel = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    specLabel:SetPoint("LEFT", 158, 0)
    specLabel:SetText("Spec")

    for sid = 1, NUM_SLOTS do
        local f = CreateFrame("Frame", nil, h)
        f:SetSize(16, 16)
        f:SetPoint("LEFT", cellX(sid) + 2, 0)
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetAllPoints()
        local empty = ns.UI and ns.UI.EmptySlotTexture and ns.UI:EmptySlotTexture(sid)
        t:SetTexture(empty or texPath("slotBg", SLOT_BG))
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self)
            local slot = ns.SLOTS and ns.SLOTS[sid]
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(slot and slot.label or ("Slot " .. sid))
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", hideTooltip)
    end

    function h:UpdateSort()
        for _, b in ipairs(self.sortButtons) do
            local active = false
            for _, k in ipairs(b.sortKeys) do
                if k == state.sort then active = true end
            end
            if active then
                b.label:SetTextColor(1, 1, 1)
            else
                b.label:SetTextColor(1, 0.82, 0)
            end
        end
    end
    return h
end

local function createRosterView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints(parent)
    v.header = createRosterHeader(v)
    v.header:SetPoint("TOPLEFT", 0, 0)
    v.header:SetPoint("TOPRIGHT", 0, 0)
    v.list = ns.UI:CreateScrollList(v, ROW_HEIGHT, initRosterRow)
    v.list.frame:ClearAllPoints()
    v.list.frame:SetPoint("TOPLEFT", 0, -22)
    v.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    v.empty = v:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    v.empty:SetPoint("CENTER", v.list.frame, "CENTER", 0, 20)
    v.empty:SetWidth(460)
    return v
end

local function refreshRoster(rows, stats, resetScroll)
    local v = panel.rosterView
    v.header:UpdateSort()
    setListData(v.list, rows, resetScroll)
    if #rows > 0 then
        v.empty:Hide()
    else
        if stats.total == 0 then
            v.empty:SetText("No BiS lists received yet.\nMembers share their lists automatically while a council member is online - try Request sync.")
        else
            v.empty:SetText("No members match the current filters.")
        end
        v.empty:Show()
    end
end

----------------------------------------------------------------------------
-- Items view
----------------------------------------------------------------------------

local function treeRowClick(row)
    local d = row.cdlData
    if not (d and d.key) then return end
    state.selectedNode = d.key
    state.focus = nil
    CouncilUI:Refresh(false, true)
end

local function initTreeRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.18)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetTexture(texPath("rowHilight", ROW_HILIGHT))
        row.hl:SetBlendMode("ADD")
        row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.count:SetPoint("RIGHT", -4, 0)
        row.count:SetJustifyH("RIGHT")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row:SetScript("OnClick", treeRowClick)
    end
    row.cdlData = d
    local phase = currentPhase()
    if d.type == "raid" then
        row.text:SetFontObject("GameFontNormal")
        row.text:SetPoint("LEFT", 4, 0)
        local label = d.name
        if d.phase and d.phase ~= phase then
            label = label .. grey(" P" .. d.phase)
        end
        row.text:SetText(label)
        row.hl:SetAlpha(0)
    else
        row.text:SetFontObject("GameFontHighlightSmall")
        row.text:SetPoint("LEFT", d.type == "boss" and 14 or 4, 0)
        row.text:SetText(d.name)
        row.hl:SetAlpha(1)
    end
    if d.count > 0 then
        row.count:SetText("(" .. d.count .. ")")
        row.count:SetTextColor(1, 1, 1)
    else
        row.count:SetText("(0)")
        row.count:SetTextColor(0.5, 0.5, 0.5)
    end
    row.sel:SetShown(d.key ~= nil and d.key == state.selectedNode)
end

local function announceItem(d)
    if not (ns.UI and ns.UI.AnnounceLine) then return end
    local now = GetTime()
    if lastAnnounce[d.itemID] and now - lastAnnounce[d.itemID] < ANNOUNCE_COOLDOWN then return end
    lastAnnounce[d.itemID] = now
    local mains, alts = {}, {}
    for _, e in ipairs(uniqueWanters(d.wanters)) do
        if not e.obtained then
            if e.which == "alt" then
                alts[#alts + 1] = shortName(e.key)
            else
                mains[#mains + 1] = shortName(e.key)
            end
        end
    end
    local label = itemLink(d.itemID) or itemName(d.itemID) or ("item " .. d.itemID)
    local parts = {}
    if #mains > 0 then parts[#parts + 1] = "BiS: " .. table.concat(mains, ", ") end
    if #alts > 0 then parts[#parts + 1] = "Alt: " .. table.concat(alts, ", ") end
    local text
    if #parts > 0 then
        text = "CDLoot: " .. label .. " - " .. table.concat(parts, " · ")
    else
        text = "CDLoot: " .. label .. " - nobody has this on their BiS list"
    end
    if ns.Demo and ns.Demo:IsEnabled() then
        ns:Print("[demo, not sent] %s", text)   -- the names are fake; never post them to real chat
        return
    end
    ns.UI:AnnounceLine(text)
end

local function openItemMenu(row, d)
    if not (ns.UI and ns.UI.ContextMenu) then return end
    local people = uniqueWanters(d.wanters)
    ns.UI:ContextMenu(row, function(root)
        root:CreateTitle(itemName(d.itemID) or ("Item " .. d.itemID))
        root:CreateButton("Link item in chat", function() linkInChat(d.itemID) end)
        root:CreateButton("Announce to raid", function() announceItem(d) end)
        if #people > 0 then
            local show = root:CreateButton("Show member")
            for _, e in ipairs(people) do
                local key = e.key
                show:CreateButton(coloredName(key, e.classFile), function() CouncilUI:ShowMember(key) end)
            end
        end
        local live = liveRollFor(d.itemID)
        local award = root:CreateButton(live and ("Record award to " .. grey("(closes the open roll)"))
            or "Record award to")
        for _, e in ipairs(people) do
            local key = e.key
            local label = coloredName(key, e.classFile)
            if e.which == "alt" then label = label .. grey(" (alt)") end
            local reason = e.os and "os" or ((e.which == "alt") and "alt" or "bis")
            award:CreateButton(label, function() recordAward(d.itemID, key, d.bossKey, reason) end)
        end
        if #people > 0 then award:CreateDivider() end
        award:CreateButton("Someone else...", function() awardSomeoneElse(d.itemID, d.bossKey) end)
    end)
end

local function itemRowClick(row, mouseButton)
    local d = row.cdlData
    if not d then return end
    if mouseButton == "LeftButton" and IsModifiedClick() then
        local link = itemLink(d.itemID)
        if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end
        return
    end
    openItemMenu(row, d)
end

local function itemRowEnter(row)
    local d = row.cdlData
    if not d then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(itemText(d.itemID))
    addWantersTooltip(GameTooltip, d)
    GameTooltip:Show()
end

local function setupItemRow(row)
    row.cdlInit = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.focusTex = row:CreateTexture(nil, "BACKGROUND")
    row.focusTex:SetAllPoints()
    row.focusTex:SetColorTexture(1, 0.82, 0, 0.12)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(texPath("rowHilight", ROW_HILIGHT))
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.5)

    row.btn = ns.UI:CreateItemButton(row, 28)
    row.btn:SetPoint("LEFT", 6, 0)
    row.btn.onTooltip = function(btn, tt)
        local d = btn:GetParent().cdlData
        if d then addWantersTooltip(tt, d) end
    end
    row.btn.onClick = function(btn, mouseButton)
        itemRowClick(btn:GetParent(), mouseButton)
    end

    row.source = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.source:SetPoint("TOPRIGHT", -8, -6)
    row.source:SetWidth(150)
    row.source:SetJustifyH("RIGHT")
    row.source:SetWordWrap(false)

    -- Both anchors of each line share the same vertical reference (top / bottom edge).
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 42, -6)
    row.name:SetPoint("TOPRIGHT", row.source, "TOPLEFT", -8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.who = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.who:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 42, 7)
    row.who:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -8, 7)
    row.who:SetJustifyH("LEFT")
    row.who:SetWordWrap(false)

    row:SetScript("OnClick", itemRowClick)
    row:SetScript("OnEnter", itemRowEnter)
    row:SetScript("OnLeave", hideTooltip)
end

local function initItemRow(row, d)
    if not row.cdlInit then setupItemRow(row) end
    row.cdlData = d
    row.btn:SetItem(d.itemID)
    row.btn:SetState(nil)
    row.btn:SetBadge(nil)
    local name = itemText(d.itemID)
    if d.isToken then name = name .. grey(" (token)") end
    row.name:SetText(name)
    local typeText = itemTypeText(d.itemID, d.isToken)
    if d.bossKey == "" then
        local src = ns.ItemDB and ns.ItemDB.GetSourceText and ns.ItemDB:GetSourceText(d.itemID, true)
        typeText = src or "No raid source"
    end
    local count = d.n == 1 and "1 wants" or (d.n .. " want")
    row.source:SetText(typeText ~= "" and (typeText .. "  ·  " .. count) or count)
    row.who:SetText(wantersLine(d))
    row:SetAlpha(d.n > 0 and 1 or 0.55)
    row.focusTex:SetShown(d.focus and true or false)
end

local function createItemsView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints(parent)

    v.tree = ns.UI:CreateScrollList(v, TREE_ROW_HEIGHT, initTreeRow)
    v.tree.frame:ClearAllPoints()
    v.tree.frame:SetPoint("TOPLEFT", 0, 0)
    v.tree.frame:SetPoint("BOTTOMLEFT", 0, 0)
    v.tree.frame:SetWidth(TREE_WIDTH)

    v.title = v:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    v.title:SetPoint("TOPLEFT", TREE_WIDTH + 14, -3)
    v.title:SetPoint("TOPRIGHT", -8, -3)
    v.title:SetJustifyH("LEFT")
    v.title:SetWordWrap(false)

    v.list = ns.UI:CreateScrollList(v, ITEM_ROW_HEIGHT, initItemRow)
    v.list.frame:ClearAllPoints()
    v.list.frame:SetPoint("TOPLEFT", TREE_WIDTH + 8, -22)
    v.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)

    v.empty = v:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    v.empty:SetPoint("CENTER", v.list.frame, "CENTER", 0, 20)
    v.empty:SetWidth(360)
    return v
end

local function nodeExists(tree, key)
    for _, r in ipairs(tree) do
        if r.key == key then return true end
    end
    return false
end

local function refreshItems(phase, members, resetScroll, keepTreeScroll)
    local v = panel.itemsView
    local byBoss, other = buildDemand(phase, members)
    local tree = buildTree(phase, byBoss, other)

    -- Default selection: first boss with demand in the list, else the first boss.
    if not (state.selectedNode and nodeExists(tree, state.selectedNode)) then
        state.selectedNode = nil
        for _, r in ipairs(tree) do
            if r.key and r.count > 0 then state.selectedNode = r.key break end
        end
        if not state.selectedNode then
            for _, r in ipairs(tree) do
                if r.key then state.selectedNode = r.key break end
            end
        end
    end

    setListData(v.tree, tree, resetScroll and not keepTreeScroll)
    local rows = buildItemRows(phase, state.selectedNode, other)
    setListData(v.list, rows, resetScroll or keepTreeScroll)

    -- Title: "<Boss> · <Raid>  -  N items · M claims"
    local claims = 0
    for _, r in ipairs(rows) do
        claims = claims + r.n
    end
    local title
    if state.selectedNode == OTHER_NODE then
        title = "Other / no raid source"
    else
        title = bossName(state.selectedNode, true) or "Select a boss"
    end
    if state.selectedNode then
        title = title .. grey(string.format("  -  %d items · %d claims", #rows, claims))
    end
    v.title:SetText(title)

    if #rows > 0 then
        v.empty:Hide()
    else
        if #tree == 0 then
            v.empty:SetText("No raids or wanted items for this phase.")
        elseif state.search ~= "" then
            v.empty:SetText("No items match the search.")
        else
            v.empty:SetText("No items to show for this boss.")
        end
        v.empty:Show()
    end

    if state.scrollToFocus then
        state.scrollToFocus = false
        local node = state.selectedNode
        scrollListTo(v.tree, function(d) return d.key == node end)
        scrollListTo(v.list, function(d) return d.focus end)
    end
end

----------------------------------------------------------------------------
-- Member view
----------------------------------------------------------------------------

local function arrowButton(parent, dir, tooltip, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(26, 26)
    b:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-Down")
    b:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-Disabled")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(tooltip)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", hideTooltip)
    return b
end

local function indexOf(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return nil
end

local function stepMember(delta)
    local n = #order
    if n == 0 then return end
    local i = indexOf(order, state.memberKey)
    if not i then
        i = delta > 0 and 0 or (n + 1)
    end
    i = ((i - 1 + delta) % n) + 1
    state.memberKey = order[i]
    CouncilUI:Refresh()
end

-- The doll object may be a frame itself or a table holding one.
local function dollFrame(doll)
    if type(doll) ~= "table" then return nil end
    if doll.GetObjectType then return doll end
    if type(doll.frame) == "table" and doll.frame.GetObjectType then return doll.frame end
    return nil
end

local function createMemberView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetPoint("TOPLEFT", 0, -32)
    v:SetPoint("BOTTOMRIGHT", 0, 0)

    v.classIcon = v:CreateTexture(nil, "ARTWORK")
    v.classIcon:SetSize(26, 26)
    v.classIcon:SetPoint("TOPLEFT", 8, -2)

    v.nextBtn = arrowButton(v, "Next", "Next member", function() stepMember(1) end)
    v.nextBtn:SetPoint("TOPRIGHT", -6, 0)
    v.prevBtn = arrowButton(v, "Prev", "Previous member", function() stepMember(-1) end)
    v.prevBtn:SetPoint("RIGHT", v.nextBtn, "LEFT", -2, 0)
    v.pos = v:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    v.pos:SetPoint("RIGHT", v.prevBtn, "LEFT", -6, 0)

    v.name = v:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    v.name:SetPoint("TOPLEFT", v.classIcon, "TOPRIGHT", 8, 0)
    v.name:SetJustifyH("LEFT")

    -- §38: "changed during lock" marker next to the name (hover for details)
    v.lockFlag = CreateFrame("Frame", nil, v)
    v.lockFlag:SetHeight(16)
    v.lockFlag:SetPoint("LEFT", v.name, "RIGHT", 10, 0)
    v.lockFlag.text = v.lockFlag:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    v.lockFlag.text:SetPoint("LEFT", 0, 0)
    v.lockFlag.text:SetText(warnIcon(14) .. " " .. colorCode("warn") .. "changed during lock|r")
    v.lockFlag:SetWidth(150)
    v.lockFlag:EnableMouse(true)
    v.lockFlag:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(coloredName(self.key))
        if ns.UI and ns.UI.AddLockChangedLine then
            ns.UI:AddLockChangedLine(GameTooltip, self.ts, "Their picks differ from the snapshot taken when the "
                .. "lists were locked. They are not suggested as a roll winner; the council can still award.")
        end
        GameTooltip:Show()
    end)
    v.lockFlag:SetScript("OnLeave", hideTooltip)
    v.lockFlag:Hide()

    v.info = v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    v.info:SetPoint("TOPLEFT", v.name, "BOTTOMLEFT", 0, -3)
    v.info:SetWidth(600)
    v.info:SetJustifyH("LEFT")
    v.info:SetWordWrap(false)

    v.dollHolder = CreateFrame("Frame", nil, v)
    v.dollHolder:SetPoint("TOPLEFT", 0, -32)
    v.dollHolder:SetPoint("BOTTOMRIGHT", 0, 0)

    if ns.PaperDoll and ns.PaperDoll.Create then
        v.doll = ns.PaperDoll:Create(v.dollHolder, { readOnly = true })
        local f = dollFrame(v.doll)
        if f then
            f:ClearAllPoints()
            f:SetAllPoints(v.dollHolder)
        end
    end

    -- Member summary + recent awards live in the doll's centre area.
    local host = (v.doll and v.doll.center) or v.dollHolder
    local c = {}
    c.summary = host:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if host == v.dollHolder then
        c.summary:SetPoint("TOP", 0, -8)
        c.summary:SetWidth(260)
    else
        c.summary:SetPoint("TOPLEFT", 6, -6)
        c.summary:SetPoint("TOPRIGHT", -6, -6)
    end
    c.summary:SetJustifyH("LEFT")

    -- recent awards along the bottom, the member's model (wearing their BiS picks) between
    c.lines = {}
    for i = MAX_AWARD_LINES, 1, -1 do
        local fs = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if i == MAX_AWARD_LINES then
            fs:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 6, 6)
            fs:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -6, 6)
        else
            fs:SetPoint("BOTTOMLEFT", c.lines[i + 1], "TOPLEFT", 0, 2)
            fs:SetPoint("BOTTOMRIGHT", c.lines[i + 1], "TOPRIGHT", 0, 2)
        end
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        c.lines[i] = fs
    end
    c.title = host:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.title:SetPoint("BOTTOMLEFT", c.lines[1], "TOPLEFT", 0, 4)
    c.title:SetPoint("BOTTOMRIGHT", c.lines[1], "TOPRIGHT", 0, 4)
    c.title:SetJustifyH("LEFT")
    c.title:SetText("Recent awards")

    if ns.UI and ns.UI.CreateBiSModel then
        c.model = ns.UI:CreateBiSModel(host)
        c.model:SetPoint("TOPLEFT", c.summary, "BOTTOMLEFT", 0, -4)
        c.model:SetPoint("BOTTOMRIGHT", c.title, "TOPRIGHT", 0, 4)
        c.model:SetScript("OnShow", function() if v.redress then v.redress() end end)
        c.noModel = host:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        c.noModel:SetPoint("CENTER", c.model, "CENTER", 0, 0)
        c.noModel:SetPoint("LEFT", c.model, "LEFT", 10, 0)
        c.noModel:SetPoint("RIGHT", c.model, "RIGHT", -10, 0)
    end
    v.centerParts = c

    v.empty = v:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    v.empty:SetPoint("CENTER", 0, 0)
    v.empty:SetWidth(420)

    if not v.doll then
        v.noDoll = v.dollHolder:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        v.noDoll:SetPoint("BOTTOM", 0, 20)
        v.noDoll:SetText("Paper doll unavailable.")
    end
    return v
end

local function memberHeaderInfo(key, rec, data, classFile)
    local parts = {}
    local spec = type(data) == "table" and type(data.sp) == "string" and data.sp or ""
    local specClass = (spec ~= "" and (spec .. " ") or "") .. className(classFile)
    if specClass ~= "" then parts[#parts + 1] = specClass end
    local rank = ns.Guild and ns.Guild.GetRankName and ns.Guild:GetRankName(key)
    if rank then parts[#parts + 1] = rank end
    parts[#parts + 1] = PRESENCE_TEXT[presenceOf(key)] or ""
    local att = ns.RaidLog and ns.RaidLog.GetAttendanceText and ns.RaidLog:GetAttendanceText(key)
    if att then parts[#parts + 1] = "attendance " .. att end   -- Addendum I: last 8 raids
    if rec then
        local ts = tonumber(rec.ts) or 0
        local text = "updated " .. formatAgo(ts)
        if (tonumber(rec.rev) or 0) > 0 then text = text .. " (rev " .. rec.rev .. ")" end
        if ts > 0 and GetServerTime() - ts > STALE_SECONDS then
            text = colorCode("warn") .. text .. "|r"
        end
        parts[#parts + 1] = text
    else
        parts[#parts + 1] = "no list received"
    end
    local isMe = ns.Util and ns.Util.IsMe and ns.Util.IsMe(key)
    if isMe then
        parts[#parts + 1] = "CDLoot " .. tostring(ns.version or "?")
    else
        local peer = ns.Sync and ns.Sync.GetPeer and ns.Sync:GetPeer(key)
        if type(peer) == "table" and peer.v then
            parts[#parts + 1] = "CDLoot " .. tostring(peer.v)
        else
            parts[#parts + 1] = "CDLoot version unknown"
        end
    end
    return table.concat(parts, " · ")
end

local function refreshMemberCenter(v, key, data, phase, rec)
    local c = v.centerParts
    if not c then return end
    if type(data) == "table" then
        local ob = toSet(data.ob)
        local filled, need, disabled = 0, 0, 0
        for sid = 1, NUM_SLOTS do
            if slotDisabled(rec or { data = data }, phase, sid) then
                disabled = disabled + 1
            else
                local main = getPicks(data, phase, sid)
                if main then
                    filled = filled + 1
                    if not ob[main] then need = need + 1 end
                end
            end
        end
        local text
        if filled == 0 then
            text = string.format("P%d: no picks yet", phase)
        else
            text = string.format("P%d: %d / %d obtained · %d needed", phase, filled - need, filled, need)
        end
        if disabled > 0 then text = text .. grey(string.format(" · %d disabled", disabled)) end
        c.summary:SetText(text)
    else
        c.summary:SetText("No BiS list received yet.")
    end

    local entries = ns.Ledger and ns.Ledger.GetVisibleEntries and ns.Ledger:GetVisibleEntries({ player = key }) or {}
    local shown = 0
    for _, e in ipairs(entries) do
        if shown >= MAX_AWARD_LINES then break end
        if type(e) == "table" and tonumber(e.i) and not e.vd then
            shown = shown + 1
            local text = "|T" .. tostring(itemIcon(e.i)) .. ":14:14|t " .. itemText(e.i)
            local where = bossName(e.b)
            local label = ns.ReasonLabel and ns.ReasonLabel(e.r)
            local suffix = (label and (label .. " · ") or "") .. (where and (where .. " · ") or "") .. formatAgo(e.ts)
            c.lines[shown]:SetText(text .. grey("  " .. suffix))
            c.lines[shown]:Show()
        end
    end
    if shown == 0 then
        c.lines[1]:SetText(grey("No awards recorded."))
        c.lines[1]:Show()
        shown = 1
    end
    for i = shown + 1, MAX_AWARD_LINES do
        c.lines[i]:SetText("")
        c.lines[i]:Hide()
    end
end

-- Unit token of a member the client can see ("player", "partyN", "raidN"), or nil.
local function memberUnit(key)
    local U = ns.Util
    if U and U.IsMe and U.IsMe(key) then return "player" end
    local unit = U and U.GetPartyUnit and U.GetPartyUnit(key)
    if unit then return unit end
    if IsInRaid() and U and U.UnitKey then
        for i = 1, 40 do
            if U.UnitKey("raid" .. i) == key then return "raid" .. i end
        end
    end
    return nil
end

-- The member's model wearing their BiS picks for the phase (only while they're nearby: the client
-- can't render someone it doesn't see).
local function dressMember(v, key, data, phase, rec)
    local c = v.centerParts
    if not (c and c.model) or not c.model:IsVisible() then return end
    local shown = c.model:DressBiS(memberUnit(key), function(sid)
        if slotDisabled(rec or { data = data }, phase, sid) then return nil end
        return (getPicks(data, phase, sid))
    end)
    c.noModel:SetText(shown and "" or (shortName(key) .. "'s model shows while they're nearby."))
end

local function refreshMember(phase)
    local v = panel.memberView
    local key = state.memberKey
    local n = #order
    local idx = key and indexOf(order, key)
    v.pos:SetText(n > 0 and string.format("%s / %d", idx and tostring(idx) or "-", n) or "")
    v.prevBtn:SetEnabled(n > 0)
    v.nextBtn:SetEnabled(n > 0)

    if not key then
        v.classIcon:Hide()
        v.name:SetText("")
        v.info:SetText("")
        v.lockFlag:Hide()
        v.dollHolder:Hide()
        v.empty:SetText("No member selected. Pick someone in the Roster view.")
        v.empty:Show()
        return
    end
    v.empty:Hide()
    v.dollHolder:Show()

    local rec = ns.Store and ns.Store.Get and ns.Store:Get(key)
    if state.offspec and type(rec) == "table" then rec = ns.ListRecordView(rec, "os") end   -- (Addendum H)
    local data = type(rec) == "table" and type(rec.data) == "table" and rec.data or nil
    if not data then rec = nil end
    local classFile = memberClass(key, data)

    v.classIcon:Show()
    if ns.UI and ns.UI.ClassIcon then ns.UI:ClassIcon(v.classIcon, classFile) end
    v.name:SetText(coloredName(key, classFile))
    v.info:SetText(memberHeaderInfo(key, rec, data, classFile))
    local changedAt = lockChangedAt(key)
    v.lockFlag.key, v.lockFlag.ts = key, changedAt
    v.lockFlag:SetShown(changedAt ~= nil)

    if v.doll and v.doll.Update then
        local shownData = data or { cl = classFile, sp = "", ph = {}, ob = {}, eq = {} }
        local shownRecord = rec or { rev = 0, ts = 0, data = shownData }
        local ob = toSet(shownData.ob)
        local worn = {}
        if type(shownData.eq) == "table" then
            for _, id in pairs(shownData.eq) do
                worn[id] = true
            end
        end
        -- Other players only report obtained (data.ob) and worn (data.eq) items; no bag/bank detail.
        local ctx = {
            obtainedState = function(itemID)
                if not itemID then return nil end
                if worn[itemID] then return "equipped" end
                if ob[itemID] then return "obtained" end
                return nil
            end,
            awarded = function(itemID)
                return hasAward(key, itemID)
            end,
            showEquipped = true,
        }
        v.doll:Update(shownRecord, phase, ctx)
    end
    refreshMemberCenter(v, key, data, phase, rec)
    v.redress = function() dressMember(v, key, data, phase, rec) end
    v.redress()
end

----------------------------------------------------------------------------
-- Loot Council view (ADDENDUM E §29/§30): who is on the council, plus the pickers for the guild
-- council (Guild Master) and this raid's council (raid leader). Read-only for everyone else.
-- Every ns.Guild council call is guarded: an older core simply shows nothing to edit.
----------------------------------------------------------------------------

local MAX_COUNCIL_NAMES = 40         -- CG / CR carry at most 40 names (§31)
local COUNCIL_ROW_HEIGHT = 20
local SECTION_PAD = 10
local PICKER_WIDTH = 300
local COUNCIL_KINDS = { "guild", "raid" }
local ONLINE_DOT = "Interface\\COMMON\\Indicator-Green"
local OFFLINE_DOT = "Interface\\COMMON\\Indicator-Gray"

local drafts = {}                    -- [kind] = { members = set, phase = n (guild only), base = signature }
local showOfflineMembers = false     -- "Show offline members" in the guild picker (session only)

-- ns.Guild:<method>(...) when the core has it, else nil.
local function guildCall(method, ...)
    local G = ns.Guild
    local fn = G and G[method]
    if type(fn) ~= "function" then return nil end
    return fn(G, ...)
end

local function copySet(t)
    local out = {}
    if type(t) == "table" then
        for k, v in pairs(t) do
            if v and type(k) == "string" and k ~= "" then out[k] = true end
        end
    end
    return out
end

local function countSet(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function nameLess(a, b)
    local sa, sb = shortName(a):lower(), shortName(b):lower()
    if sa ~= sb then return sa < sb end
    return a < b
end

local function sortedSet(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out, nameLess)
    return out
end

local function playerKey()
    return ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() or nil
end

local function inRaid()
    return (IsInRaid and IsInRaid()) and true or false
end

-- Util.group entry of a member of my (real) group.
local function groupEntry(key)
    local g = ns.Util and ns.Util.group
    local e = type(g) == "table" and type(key) == "string" and g[key]
    return type(e) == "table" and e or nil
end

-- In the live guild roster (never demo members).
local function realGuildMember(key)
    local G = ns.Guild
    return (type(key) == "string" and G and G.IsInGuild and G:IsInGuild(key, true)) and true or false
end

local function councilClass(key)
    local cl = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)
    if not cl then
        local e = groupEntry(key)
        cl = e and e.classFile
    end
    return cl
end

local function councilName(key)
    if type(key) ~= "string" then return grey("?") end
    return coloredName(key, councilClass(key))
end

-- Online per the guild roster, else per the raid roster (raid council members may be from other guilds).
local function councilOnline(key)
    if isOnline(key) then return true end
    local e = groupEntry(key)
    return (e and e.online) and true or false
end

local function rankNote(key)
    if realGuildMember(key) then
        return ns.Guild.GetRankName and ns.Guild:GetRankName(key) or ""
    end
    return groupEntry(key) and "not in your guild" or ""
end

local function raidLeaderKey()
    if not inRaid() then return nil end
    local g = ns.Util and ns.Util.group
    if type(g) == "table" then
        for key, e in pairs(g) do
            if type(e) == "table" and tonumber(e.rank) == 2 then return key end
        end
    end
    local rc = guildCall("GetRaidCouncil")
    return type(rc) == "table" and type(rc.leader) == "string" and rc.leader or nil
end

local function canEditGuildCouncil()
    return guildCall("CanEditGuildCouncil") and true or false
end

local function amRaidLeader()
    return guildCall("AmIRaidLeader") and true or false
end

-- guild: the accepted guild council; raid: my own saved raid list ("until changed").
local function savedList(kind)
    local t
    if kind == "guild" then
        t = guildCall("GetGuildCouncil")
    else
        t = guildCall("GetMyRaidList")
    end
    return type(t) == "table" and t or nil
end

-- The raid list is edited by the current raid leader, or out of a raid by whoever has a saved list.
local function canEditRaidCouncil()
    if amRaidLeader() then return true end
    return not inRaid() and savedList("raid") ~= nil
end

local function clampPhase(p)
    p = tonumber(p)
    if p and p >= 1 and p <= (ns.MAX_PHASE or 5) then return math.floor(p) end
    return nil
end

local function savedPhase(saved)
    return clampPhase(type(saved) == "table" and saved.phase) or 1
end

-- t: a draft or a saved list ({ members, phase, de, bank }); de / bank = the loot targets (ADDENDUM G §41).
local function signature(kind, t)
    local keys = {}
    for k in pairs(t.members or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local s = table.concat(keys, ",")
    if kind == "guild" then s = s .. "|p" .. tostring(t.phase or 1) end
    return s .. "|de" .. tostring(t.de or "") .. "|bk" .. tostring(t.bank or "")
end

local function savedTarget(saved, field)
    local v = type(saved) == "table" and saved[field]
    return type(v) == "string" and v ~= "" and v or nil
end

local function savedSignature(kind)
    local saved = savedList(kind)
    return signature(kind, { members = copySet(saved and saved.members), phase = savedPhase(saved),
        de = savedTarget(saved, "de"), bank = savedTarget(saved, "bank") })
end

local function resetDraft(kind)
    local saved = savedList(kind)
    local d = { members = copySet(saved and saved.members), de = savedTarget(saved, "de"),
                bank = savedTarget(saved, "bank") }
    if kind == "guild" then d.phase = savedPhase(saved) end
    d.base = signature(kind, d)
    drafts[kind] = d
    return d
end

local function getDraft(kind)
    return drafts[kind] or resetDraft(kind)
end

local function draftDirty(kind)
    return signature(kind, getDraft(kind)) ~= savedSignature(kind)
end

-- CONFIG_UPDATED: follow the saved lists unless the editor has unsaved edits.
local function syncCouncilDrafts()
    for _, kind in ipairs(COUNCIL_KINDS) do
        local d = drafts[kind]
        if d and signature(kind, d) == d.base then resetDraft(kind) end
    end
end

local function membersText(n)
    return string.format("%d %s", n, n == 1 and "member" or "members")
end

-- Items of the guild picker: online (or all) guild members, sorted by name. The GM is fixed.
local function guildPickerItems()
    local G = ns.Guild
    local keys
    if showOfflineMembers then
        keys = G and G.GetMembers and G:GetMembers() or {}
    else
        keys = guildCall("GetOnlineMembers")
        if type(keys) ~= "table" then
            keys = {}
            for _, k in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
                if isOnline(k) then keys[#keys + 1] = k end
            end
        end
    end
    local gm = guildCall("GetGM")
    local out = {}
    for _, key in ipairs(keys) do
        if realGuildMember(key) then
            out[#out + 1] = {
                key = key, text = shortName(key), classFile = councilClass(key), note = rankNote(key),
                dim = not isOnline(key), fixed = (key == gm) and "Guild Master" or nil,
            }
        end
    end
    table.sort(out, function(a, b) return nameLess(a.key, b.key) end)
    return out
end

-- Items of the raid picker: my raid first, then online guild members. The raid leader is fixed.
local function raidPickerItems()
    local out, seen = {}, {}
    local leader = raidLeaderKey()
    local raidKeys = {}
    local g = ns.Util and ns.Util.group
    if inRaid() and type(g) == "table" then
        for key in pairs(g) do raidKeys[#raidKeys + 1] = key end
        table.sort(raidKeys, nameLess)
    end
    if #raidKeys > 0 then
        out[#out + 1] = { header = "In your raid" }
        for _, key in ipairs(raidKeys) do
            seen[key] = true
            out[#out + 1] = {
                key = key, text = shortName(key), classFile = councilClass(key), note = rankNote(key),
                dim = not councilOnline(key), fixed = (key == leader) and "Raid leader" or nil,
            }
        end
    end
    local online = {}
    local keys = guildCall("GetOnlineMembers")
    if type(keys) ~= "table" then
        keys = {}
        for _, k in ipairs(ns.Guild and ns.Guild.GetMembers and ns.Guild:GetMembers() or {}) do
            if isOnline(k) then keys[#keys + 1] = k end
        end
    end
    for _, key in ipairs(keys) do
        if not seen[key] and realGuildMember(key) then
            online[#online + 1] = {
                key = key, text = shortName(key), classFile = councilClass(key), note = rankNote(key),
            }
        end
    end
    table.sort(online, function(a, b) return nameLess(a.key, b.key) end)
    if #online > 0 then
        out[#out + 1] = { header = "Online guild members" }
        for _, e in ipairs(online) do out[#out + 1] = e end
    end
    return out
end

local function councilPhaseOptions()
    local opts = {}
    for _, p in ipairs(ns.PHASES or { 1, 2, 3, 4, 5 }) do
        local info = ns.PHASE_INFO and ns.PHASE_INFO[p]
        local text = "P" .. p
        if info and info.raids then text = text .. " · " .. info.raids end
        opts[#opts + 1] = { value = p, text = text }
    end
    return opts
end

local function ensureClearPopup()
    local dialogs = StaticPopupDialogs
    if type(dialogs) ~= "table" or dialogs.CDLOOT_CLEAR_COUNCIL then return end
    dialogs.CDLOOT_CLEAR_COUNCIL = {
        text = "%s",
        button1 = YES or "Yes",
        button2 = CANCEL or "Cancel",
        OnAccept = function(self, data)
            CouncilUI:ClearCouncil(data or self.data)
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

-- Member rows (the draft while editing, else the shared list) ----------------------------------------

local function councilRowEnter(row)
    local d = row.cdlData
    if not d then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(councilName(d.key))
    local note = rankNote(d.key)
    if note ~= "" then GameTooltip:AddLine(note, 0.8, 0.8, 0.8) end
    GameTooltip:AddLine(councilOnline(d.key) and "Online" or "Offline", 0.6, 0.6, 0.6)
    if d.fixed then
        GameTooltip:AddLine(d.fixed .. ": always on the council", 0.6, 0.6, 0.6, true)
    elseif d.isNew then
        GameTooltip:AddLine("Added, not saved yet", color("warn"))
    end
    GameTooltip:Show()
end

local function initCouncilRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(texPath("rowHilight", ROW_HILIGHT))
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.35)
        row.dot = row:CreateTexture(nil, "ARTWORK")
        row.dot:SetSize(10, 10)
        row.dot:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.classIcon = row:CreateTexture(nil, "ARTWORK")
        row.classIcon:SetSize(14, 14)
        row.classIcon:SetPoint("LEFT", row, "LEFT", 18, 0)
        row.remove = CreateFrame("Button", nil, row)
        row.remove:SetSize(18, 18)
        row.remove:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.remove:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        row.remove:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
        row.remove:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight", "ADD")
        row.remove:SetScript("OnClick", function(btn)
            local data = btn:GetParent().cdlData
            if data and data.removable then CouncilUI:ToggleCouncilDraft(data.kind, data.key) end
        end)
        row.remove:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Remove from the list")
            GameTooltip:AddLine("Save & share to apply the change.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row.remove:SetScript("OnLeave", hideTooltip)
        row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.note:SetPoint("RIGHT", row, "RIGHT", -24, 0)
        row.note:SetJustifyH("RIGHT")
        row.note:SetWordWrap(false)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row, "LEFT", 36, 0)
        row.name:SetPoint("RIGHT", row.note, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row:SetScript("OnEnter", councilRowEnter)
        row:SetScript("OnLeave", hideTooltip)
    end
    row.cdlData = d
    row.dot:SetTexture(councilOnline(d.key) and ONLINE_DOT or OFFLINE_DOT)
    if ns.UI and ns.UI.ClassIcon then ns.UI:ClassIcon(row.classIcon, councilClass(d.key)) end
    row.name:SetText(councilName(d.key))
    if d.fixed then
        row.note:SetText(d.fixed .. " · always")
    elseif d.isNew then
        row.note:SetText(colorCode("warn") .. "not saved|r")
    else
        row.note:SetText(d.note or "")
    end
    row.remove:SetShown(d.removable and true or false)
end

-- Sections ----------------------------------------------------------------------------------------

local function sectionButton(s, text, width, onClick, tip)
    local b = ns.UI:CreateButton(s, text, width, 22, onClick)
    if tip then
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(text)
            GameTooltip:AddLine(tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", hideTooltip)
    end
    return b
end

local function sectionText(s, font, y)
    local fs = s:CreateFontString(nil, "OVERLAY", font)
    fs:SetPoint("TOPLEFT", s, "TOPLEFT", SECTION_PAD, y)
    fs:SetPoint("TOPRIGHT", s, "TOPRIGHT", -SECTION_PAD, y)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function createCouncilSection(parent, kind)
    local s = ns.UI:CreatePanel(parent)
    s.kind = kind
    s.title = sectionText(s, "GameFontNormal", -SECTION_PAD)
    s.sub = sectionText(s, "GameFontDisableSmall", -28)
    s.status = sectionText(s, "GameFontHighlightSmall", -46)

    local isGuild = kind == "guild"
    s.picker = ns.UI:CreateSearchDropdown(s, PICKER_WIDTH, {
        placeholder = isGuild and "Add guild members..." or "Add raid or guild members...",
        emptyText = isGuild and "No matching guild members." or "No matching raid or guild members.",
        getItems = isGuild and guildPickerItems or raidPickerItems,
        isChecked = function(key) return getDraft(kind).members[key] and true or false end,
        onToggle = function(key) CouncilUI:ToggleCouncilDraft(kind, key) end,
        toggle = isGuild and {
            label = "Show offline members",
            get = function() return showOfflineMembers end,
            set = function(v) showOfflineMembers = v and true or false end,
        } or nil,
    })
    s.picker.frame:SetPoint("TOPLEFT", s, "TOPLEFT", SECTION_PAD - 2, -64)

    if isGuild then
        s.phaseLabel = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        s.phaseLabel:SetPoint("TOPLEFT", s, "TOPLEFT", SECTION_PAD, -103)
        s.phaseLabel:SetText("Guild phase")
        s.phaseDD = ns.UI:CreateDropdown(s, 220, councilPhaseOptions,
            function() return getDraft("guild").phase end,
            function(value) CouncilUI:SetCouncilDraftPhase(value) end)
        s.phaseDD:SetPoint("TOPLEFT", s, "TOPLEFT", 90, -96)
    end

    -- ADDENDUM G §41: the disenchanter / guild bank character (part of the draft; Save & share sends them).
    local function targetButton(field)
        local b
        b = ns.UI:CreateButton(s, "", 176, 22, function() CouncilUI:OpenTargetMenu(kind, field, b) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(field == "de" and "Disenchanter" or "Guild bank character")
            GameTooltip:AddLine((field == "de" and "The drop panel's DE button gives items to this character, recorded as Disenchant."
                or "The drop panel's Bank button gives items to this character, recorded as Guild bank.")
                .. " Such awards don't count as loot received.", 1, 1, 1, true)
            GameTooltip:AddLine(isGuild and "Applies to every raid unless the raid leader picks one for their raid."
                or "Replaces the guild's pick in the raids you lead.", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("Save & share to apply the change.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", hideTooltip)
        return b
    end
    s.deBtn = targetButton("de")
    s.bankBtn = targetButton("bank")
    s.targets = sectionText(s, "GameFontHighlightSmall", -64)

    s.listLabel = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    s.listLabel:SetJustifyH("LEFT")
    s.list = ns.UI:CreateScrollList(s, COUNCIL_ROW_HEIGHT, initCouncilRow)

    s.save = sectionButton(s, "Save & share", 110, function() CouncilUI:SaveCouncil(kind) end, isGuild
        and "Saves the guild council and sends it to every online guild member. Members who log in later get it too."
        or "Saves your raid council list. It is sent to your raid now if you lead it, and again whenever you lead a raid.")
    s.save:SetPoint("BOTTOMLEFT", s, "BOTTOMLEFT", SECTION_PAD, SECTION_PAD)
    s.revert = sectionButton(s, "Revert", 70, function() CouncilUI:RevertCouncil(kind) end,
        "Discard your unsaved changes.")
    s.revert:SetPoint("LEFT", s.save, "RIGHT", 6, 0)
    s.clear = sectionButton(s, "Clear list", 84, function() CouncilUI:ConfirmClearCouncil(kind) end,
        isGuild and "Removes everyone from the guild council list (asks first). The Guild Master stays council."
        or "Removes everyone from your raid council list (asks first). As raid leader you stay council.")
    s.clear:SetPoint("LEFT", s.revert, "RIGHT", 6, 0)

    s.foot = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    s.foot:SetPoint("BOTTOMLEFT", s, "BOTTOMLEFT", SECTION_PAD, SECTION_PAD + 2)
    s.foot:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", -SECTION_PAD, SECTION_PAD + 2)
    s.foot:SetJustifyH("LEFT")
    return s
end

-- Editor or read-only layout of a section.
local function layoutSection(s, editable)
    s.editable = editable
    s.picker.frame:SetShown(editable)
    if s.phaseDD then
        s.phaseDD:SetShown(editable)
        s.phaseLabel:SetShown(editable)
    end
    s.save:SetShown(editable)
    s.revert:SetShown(editable)
    s.clear:SetShown(editable)
    s.foot:SetShown(not editable)
    s.deBtn:SetShown(editable)
    s.bankBtn:SetShown(editable)
    s.targets:SetShown(not editable)
    local top = -84
    if editable then
        local ty = s.phaseDD and -128 or -94
        s.deBtn:ClearAllPoints()
        s.deBtn:SetPoint("TOPLEFT", s, "TOPLEFT", SECTION_PAD, ty)
        s.bankBtn:ClearAllPoints()
        s.bankBtn:SetPoint("LEFT", s.deBtn, "RIGHT", 6, 0)
        top = ty - 32
    end
    s.listLabel:ClearAllPoints()
    s.listLabel:SetPoint("TOPLEFT", s, "TOPLEFT", SECTION_PAD, top)
    s.list.frame:ClearAllPoints()
    s.list.frame:SetPoint("TOPLEFT", s, "TOPLEFT", SECTION_PAD - 4, top - 16)
    s.list.frame:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", -SECTION_PAD + 2, editable and 40 or 30)
end

-- Rows of the draft: the fixed member (GM / raid leader) first, then the picked names.
local function draftRows(kind, fixedKey, fixedText)
    local rows = {}
    if fixedKey then rows[1] = { kind = kind, key = fixedKey, fixed = fixedText } end
    local saved = savedList(kind)
    local savedSet = copySet(saved and saved.members)
    for _, key in ipairs(sortedSet(getDraft(kind).members)) do
        if key ~= fixedKey then
            rows[#rows + 1] = { kind = kind, key = key, removable = true, isNew = not savedSet[key], note = rankNote(key) }
        end
    end
    return rows
end

local function sharedRows(kind, fixedKey, fixedText, members)
    local rows = {}
    if fixedKey then rows[1] = { kind = kind, key = fixedKey, fixed = fixedText } end
    for _, key in ipairs(sortedSet(copySet(members))) do
        if key ~= fixedKey then rows[#rows + 1] = { kind = kind, key = key, note = rankNote(key) } end
    end
    return rows
end

local function editorStatus(kind, n, saved)
    if draftDirty(kind) then
        return colorCode("warn") .. "Unsaved changes|r · " .. membersText(n)
    end
    if not saved then
        return grey((kind == "guild" and "Not shared yet" or "Not saved yet") .. " · " .. membersText(n))
    end
    local ago = formatAgo(saved.rev)
    if kind == "guild" then
        return string.format("Shared %s · %s · phase P%d", ago, membersText(n), savedPhase(saved))
    end
    if amRaidLeader() then
        return "Shared with this raid · " .. membersText(n) .. grey(" · saved " .. ago)
    end
    return "Saved " .. ago .. " · " .. membersText(n) .. grey(" · shared whenever you lead a raid")
end

-- ADDENDUM G §41: the loot targets of a section (buttons while editing, one line otherwise).
local function targetName(key)
    return key and councilName(key) or grey("none")
end

local function paintTargetButtons(s, d)
    s.deBtn:SetText("Disenchanter: " .. targetName(d.de))
    s.bankBtn:SetText("Guild bank: " .. targetName(d.bank))
end

local function targetsLine(t, emptyText)
    local de, bank = savedTarget(t, "de"), savedTarget(t, "bank")
    if not de and not bank then return grey(emptyText) end
    return "Disenchanter: " .. targetName(de) .. "  ·  Guild bank: " .. targetName(bank)
end

local function refreshGuildSection(s)
    local inGuild = IsInGuild and IsInGuild()
    local editable = inGuild and canEditGuildCouncil() or false
    layoutSection(s, editable)
    s.title:SetText("Guild council")
    s.sub:SetText("Everyone in the guild · kept until the Guild Master changes it")
    local saved = savedList("guild")
    local gm = guildCall("GetGM")
    local rows
    if not inGuild then
        rows = {}
        s.targets:SetText("")
        s.status:SetText(grey("You are not in a guild."))
        s.foot:SetText("")
        s.list:SetEmptyText("")
    elseif editable then
        rows = draftRows("guild", gm, "Guild Master")
        local d = getDraft("guild")
        local n = countSet(d.members) - ((gm and d.members[gm]) and 1 or 0)
        local dirty = draftDirty("guild")
        s.status:SetText(editorStatus("guild", n, saved))
        s.save:SetEnabled(dirty)
        s.revert:SetEnabled(dirty)
        s.clear:SetEnabled(countSet(copySet(saved and saved.members)) > 0 or n > 0)
        s.phaseDD:Refresh()
        paintTargetButtons(s, d)
        s.list:SetEmptyText("")
    else
        s.targets:SetText(targetsLine(saved, "No disenchanter / guild bank character set."))
        rows = sharedRows("guild", gm, "Guild Master", saved and saved.members)
        local n = #rows - (gm and 1 or 0)
        if saved then
            local by = type(saved.by) == "string" and saved.by or gm
            s.status:SetText(string.format("Set by %s %s · %s · phase P%d", councilName(by), formatAgo(saved.rev),
                membersText(n), savedPhase(saved)))
        else
            s.status:SetText(grey("No guild council shared yet: only the Guild Master is council."))
        end
        s.foot:SetText("Only the Guild Master can change this list.")
        s.list:SetEmptyText(gm and "" or "Waiting for the guild roster...")
    end
    s.listLabel:SetText(string.format("On the council (%d)", #rows))
    s.list:SetData(rows)
    if s.picker:IsOpen() then s.picker:Refresh(true) end
end

local function refreshRaidSection(s)
    local leading = amRaidLeader()
    local editable = canEditRaidCouncil()
    layoutSection(s, editable)
    local rows
    if editable then
        local me = playerKey()
        local fixedKey = leading and me or nil
        rows = draftRows("raid", fixedKey, "Raid leader")
        local d = getDraft("raid")
        local n = countSet(d.members) - ((fixedKey and d.members[fixedKey]) and 1 or 0)
        local dirty = draftDirty("raid")
        local saved = savedList("raid")
        if leading then
            s.title:SetText("This raid's council")
            s.sub:SetText("Members of your raid only · you lead it, so you are always council")
        else
            s.title:SetText("Your raid council list")
            s.sub:SetText("Shared automatically whenever you lead a raid")
        end
        s.status:SetText(editorStatus("raid", n, saved))
        s.save:SetEnabled(dirty)
        s.revert:SetEnabled(dirty)
        s.clear:SetEnabled(countSet(copySet(saved and saved.members)) > 0 or n > 0)
        paintTargetButtons(s, d)
        s.list:SetEmptyText(#rows <= (fixedKey and 1 or 0) and "Nobody picked yet: use the search box above." or "")
    else
        s.title:SetText("This raid's council")
        s.sub:SetText("Members of your current raid only · the raid leader is always council")
        if not inRaid() then
            rows = {}
            s.targets:SetText("")
            s.status:SetText(grey("You are not in a raid."))
            s.foot:SetText("Lead a raid to pick extra council members for it.")
            s.list:SetEmptyText("")
        else
            local leader = raidLeaderKey()
            local rc = guildCall("GetRaidCouncil")
            if type(rc) ~= "table" or (leader and rc.leader and rc.leader ~= leader) then rc = nil end
            s.targets:SetText(targetsLine(rc, "Disenchanter / guild bank: the guild's picks."))
            rows = sharedRows("raid", leader, "Raid leader", rc and rc.members)
            local n = #rows - (leader and 1 or 0)
            if rc then
                s.status:SetText("Set by raid leader " .. councilName(rc.leader or leader) .. " · " .. membersText(n))
            elseif leader then
                s.status:SetText(grey("The raid leader (") .. councilName(leader) .. grey(") has not picked a raid council."))
            else
                s.status:SetText(grey("Waiting for the raid roster..."))
            end
            s.foot:SetText("Only the raid leader can change this list.")
            s.list:SetEmptyText("")
        end
    end
    s.listLabel:SetText(string.format("On the council (%d)", #rows))
    s.list:SetData(rows)
    if s.picker:IsOpen() then s.picker:Refresh(true) end
end

local function createCouncilView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -32)
    v:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    v.guild = createCouncilSection(v, "guild")
    v.guild:SetPoint("TOPLEFT", v, "TOPLEFT", 4, -2)
    v.guild:SetPoint("BOTTOMRIGHT", v, "BOTTOM", -4, 4)
    v.raid = createCouncilSection(v, "raid")
    v.raid:SetPoint("TOPLEFT", v, "TOP", 4, -2)
    v.raid:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", -4, 4)
    return v
end

local function refreshCouncilView()
    local v = panel and panel.councilView
    if not v then return end
    refreshGuildSection(v.guild)
    refreshRaidSection(v.raid)
end

----------------------------------------------------------------------------
-- Panel, toolbar, footer
----------------------------------------------------------------------------

local function phaseOptions()
    local opts = {}
    local guildPhase = ns.Guild and ns.Guild.GetGuildPhase and ns.Guild:GetGuildPhase()
    -- GetGuildPhase() is the group's phase while group rules set one (ADDENDUM E §32).
    local GR = ns.GroupRules
    local groupSet = type(GR) == "table" and type(GR.GetRulePhase) == "function" and GR:GetRulePhase() ~= nil
    local marker = groupSet and " (group)" or " (guild)"
    for _, p in ipairs(ns.PHASES or { 1, 2, 3, 4, 5 }) do
        local info = ns.PHASE_INFO and ns.PHASE_INFO[p]
        local text = (info and info.short) or ("P" .. p)
        if p == guildPhase then text = text .. marker end
        opts[#opts + 1] = { value = p, text = text }
    end
    return opts
end

local function classOptions()
    local opts = { { value = "ALL", text = "All classes" } }
    for _, cl in ipairs(ns.CLASSES or DEFAULT_CLASSES) do
        local text = className(cl)
        if ns.Util and ns.Util.ClassColorHex then
            text = "|c" .. ns.Util.ClassColorHex(cl) .. text .. "|r"
        end
        opts[#opts + 1] = { value = cl, text = text }
    end
    return opts
end

local function roleOptions()
    local opts = { { value = "ALL", text = "All roles" } }
    for _, role in ipairs(ROLE_ORDER) do
        local label = ns.ROLE_LABELS and ns.ROLE_LABELS[role] or role
        opts[#opts + 1] = { value = role, text = label }
    end
    return opts
end

-- Checkbox setters: accept a boolean if the widget passes one, else toggle.
local function toggleSetter(field)
    return function(value)
        if type(value) == "boolean" then
            state[field] = value
        else
            state[field] = not state[field]
        end
        CouncilUI:Refresh(true)
    end
end

local function createToolbar(p)
    local UI = ns.UI

    -- Row 1: phase, view switch, search.
    local phaseLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    phaseLabel:SetPoint("LEFT", p, "TOPLEFT", 8, -16)
    phaseLabel:SetText("Phase")
    p.phaseLabel = phaseLabel

    p.phaseDD = UI:CreateDropdown(p, 100, phaseOptions, currentPhase, function(value)
        state.phase = tonumber(value) or state.phase
        -- A new phase starts on its own first boss (only ShowItem/ShowBoss jumps keep a sticky node).
        state.selectedNode = nil
        state.focus = nil
        CouncilUI:Refresh(true)
    end)
    p.phaseDD:SetPoint("LEFT", phaseLabel, "RIGHT", 8, 0)

    p.viewButtons = {}
    local views = {
        { key = "roster", label = "Roster" }, { key = "items", label = "Items" }, { key = "member", label = "Member" },
        { key = "council", label = "Loot Council", width = 100,
          tip = "Who is on the Loot Council. The Guild Master picks the guild council; a raid leader can add council members for their own raid." },
    }
    local prev
    for _, info in ipairs(views) do
        local key = info.key
        local b = UI:CreateButton(p, info.label, info.width or 72, 22, function() CouncilUI:SetView(key) end)
        if info.tip then
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(info.label)
                GameTooltip:AddLine(info.tip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", hideTooltip)
        end
        if prev then
            b:SetPoint("LEFT", prev, "RIGHT", 2, 0)
        else
            b:SetPoint("LEFT", p, "TOPLEFT", 180, -16)
        end
        p.viewButtons[key] = b
        prev = b
    end
    -- Opens the boss drop panel (one Escape closes it together with the loot window).
    p.dropsBtn = UI:CreateButton(p, "Drops", 64, 22, function()
        if ns.DropPanel and ns.DropPanel.ShowHistory then ns.DropPanel:ShowHistory() end
    end)
    p.dropsBtn:SetPoint("LEFT", prev, "RIGHT", 6, 0)
    p.dropsBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Drops")
        GameTooltip:AddLine("Open the boss drop panel with tonight's drops (also /cdl drops, or Shift-click the "
            .. "minimap button).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    p.dropsBtn:SetScript("OnLeave", hideTooltip)

    p.search = UI:CreateSearchBox(p, 170, function(text)
        text = type(text) == "string" and text or ""
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        state.search = text:lower()
        CouncilUI:Refresh(true)
    end)
    p.search:SetPoint("RIGHT", p, "TOPRIGHT", -10, -16)

    -- Row 2: class, role, raid-only, hide obtained (hidden in the member view).
    local row2 = CreateFrame("Frame", nil, p)
    row2:SetPoint("TOPLEFT", 0, -30)
    row2:SetPoint("TOPRIGHT", 0, -30)
    row2:SetHeight(28)
    p.row2 = row2

    p.classDD = UI:CreateDropdown(row2, 130, classOptions, function() return state.class end, function(value)
        state.class = value or "ALL"
        CouncilUI:Refresh(true)
    end)
    p.classDD:SetPoint("LEFT", row2, "LEFT", 8, 0)

    p.roleDD = UI:CreateDropdown(row2, 110, roleOptions, function() return state.role end, function(value)
        state.role = value or "ALL"
        CouncilUI:Refresh(true)
    end)
    p.roleDD:SetPoint("LEFT", p.classDD, "RIGHT", 8, 0)

    p.raidCB = UI:CreateCheckbox(row2, "In my raid only", function() return state.raidOnly end, toggleSetter("raidOnly"))
    p.raidCB:SetPoint("LEFT", row2, "LEFT", 272, 0)

    p.obtainedCB = UI:CreateCheckbox(row2, "Hide obtained", function() return state.hideObtained end, toggleSetter("hideObtained"))
    p.obtainedCB:SetPoint("LEFT", row2, "LEFT", 420, 0)

    -- Addendum H: switch the Roster / Items / Member views to the players' off-spec lists.
    p.offspecCB = UI:CreateCheckbox(row2, "Off-spec lists", function() return state.offspec end, toggleSetter("offspec"))
    p.offspecCB:SetPoint("LEFT", row2, "LEFT", 540, 0)

    -- §38: "Lock BiS lists" / "Unlock BiS lists" for the raid leader (the group's loot authority), and the
    -- lock state for every council member.
    if UI.CreateBiSLockButton then
        p.lockBtn = UI:CreateBiSLockButton(row2, 128, 22)
        p.lockBtn:SetPoint("RIGHT", row2, "RIGHT", -10, 0)
    end
    p.lockStatus = CreateFrame("Frame", nil, row2)
    p.lockStatus:SetSize(116, 20)
    p.lockStatus.text = p.lockStatus:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.lockStatus.text:SetPoint("RIGHT", 0, 0)
    p.lockStatus.text:SetJustifyH("RIGHT")
    p.lockStatus.text:SetWordWrap(false)
    p.lockStatus:EnableMouse(true)
    p.lockStatus:SetScript("OnEnter", function(self)
        if not UI.GetBiSLock then return end
        local locked, info = UI:GetBiSLock()
        if not locked then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("BiS lists are locked", 1, 0.82, 0)
        GameTooltip:AddLine("Locked by " .. UI:LockByText(info, true) .. ". Raiders can't edit their lists; "
            .. "anyone whose list still changes gets a warning marker and is not suggested in rolls.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    p.lockStatus:SetScript("OnLeave", hideTooltip)
    p.lockStatus:Hide()
end

-- The toolbar's lock button and "Locked by X" status (§38).
local function updateLockControls()
    local p = panel
    if p.lockBtn and p.lockBtn.Refresh then p.lockBtn:Refresh() end
    local locked, info
    if ns.UI and ns.UI.GetBiSLock then locked, info = ns.UI:GetBiSLock() end
    local st = p.lockStatus
    st:ClearAllPoints()
    if p.lockBtn and p.lockBtn:IsShown() then
        st:SetPoint("RIGHT", p.lockBtn, "LEFT", -6, 0)
    else
        st:SetPoint("RIGHT", p.row2, "RIGHT", -10, 0)
    end
    if locked then
        st.text:SetText(ns.UI:LockIcon(12) .. " " .. colorCode("warn") .. "Locked by " .. ns.UI:LockByText(info) .. "|r")
        st:Show()
    else
        st:Hide()
    end
end

local function createFooter(p)
    local f = CreateFrame("Frame", nil, p)
    f:SetPoint("BOTTOMLEFT", 0, 0)
    f:SetPoint("BOTTOMRIGHT", 0, 0)
    f:SetHeight(26)
    p.footer = f

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("LEFT", 8, 0)
    f.text:SetJustifyH("LEFT")

    f.sync = ns.UI:CreateButton(f, "Request sync", 110, 22, function(self)
        if not (ns.Sync and ns.Sync.RequestSync and ns.Sync:RequestSync()) then return end
        -- HELLO is rate-limited to once per 30s; mirror that on the button.
        local b = f.sync
        b:Disable()
        C_Timer.After(30, function() b:Enable() end)
    end)
    f.sync:SetPoint("RIGHT", -6, 0)
    f.sync:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Request sync")
        GameTooltip:AddLine("Ask online guild members and council for newer lists and awards.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.sync:SetScript("OnLeave", hideTooltip)
end

local function updateToolbar()
    local p = panel
    if p.phaseDD and p.phaseDD.Refresh then p.phaseDD:Refresh() end
    if p.classDD and p.classDD.Refresh then p.classDD:Refresh() end
    if p.roleDD and p.roleDD.Refresh then p.roleDD:Refresh() end
    if p.raidCB and p.raidCB.Refresh then p.raidCB:Refresh() end
    if p.obtainedCB and p.obtainedCB.Refresh then p.obtainedCB:Refresh() end
    if p.offspecCB and p.offspecCB.Refresh then p.offspecCB:Refresh() end
    updateLockControls()
    for key, b in pairs(p.viewButtons or {}) do
        if key == state.view then
            b:LockHighlight()
        else
            b:UnlockHighlight()
        end
    end
end

local function updateFooter(stats)
    local text = string.format("%d members with lists · %d in raid · ", stats.total, stats.inRaid)
    if stats.stale > 0 then
        text = text .. colorCode("warn") .. string.format("%d lists older than 7 days", stats.stale) .. "|r"
    else
        text = text .. "0 lists older than 7 days"
    end
    panel.footer.text:SetText(text)
end

function CouncilUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", "CDLootCouncilPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    p.dirty = true

    createToolbar(p)
    createFooter(p)

    p.viewArea = CreateFrame("Frame", nil, p)
    p.viewArea:SetPoint("TOPLEFT", 0, -60)
    p.viewArea:SetPoint("BOTTOMRIGHT", 0, 28)

    p.rosterView = createRosterView(p.viewArea)

    p:SetScript("OnShow", function(self)
        if self.dirty then CouncilUI:Refresh() end
    end)
    function p:OnPanelShown()
        if self.dirty then CouncilUI:Refresh() end
    end
    -- A freshly created frame gets no OnShow; paint once the tab has been laid out.
    C_Timer.After(0, function()
        if panel and panel.dirty then CouncilUI:Refresh() end
    end)
    return p
end

----------------------------------------------------------------------------
-- Refresh
----------------------------------------------------------------------------

-- resetScroll: jump lists to the top (filter/view changes). keepTreeScroll: only the item list resets.
function CouncilUI:Refresh(resetScroll, keepTreeScroll)
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    panel.dirty = false
    if ns.Util and ns.Util.CancelDebounce then ns.Util.CancelDebounce("council-ui") end

    -- The Loot Council view has its own controls: the phase / search / filters don't apply to it.
    local council = state.view == "council"
    if council and not panel.councilView then
        panel.councilView = createCouncilView(panel)
    end
    if panel.councilView then panel.councilView:SetShown(council) end
    panel.phaseLabel:SetShown(not council)
    panel.phaseDD:SetShown(not council)
    panel.search:SetShown(not council)
    if council then
        panel.rosterView:Hide()
        if panel.itemsView then panel.itemsView:Hide() end
        if panel.memberView then panel.memberView:Hide() end
        panel.viewArea:Hide()
        panel.row2:Hide()
        panel.footer:Hide()
        updateToolbar()
        refreshCouncilView()
        return
    end

    local phase = currentPhase()
    local members, stats = buildMembers(phase)
    table.sort(members, SORTS[state.sort] or SORTS.presence)
    local rosterRows = {}
    order = {}
    for _, m in ipairs(members) do
        if m.searchHit then
            rosterRows[#rosterRows + 1] = m
            order[#order + 1] = m.key
        end
    end

    local view = state.view
    if view == "member" and not state.memberKey then
        state.memberKey = order[1]
    end
    if view == "items" and not panel.itemsView then
        panel.itemsView = createItemsView(panel.viewArea)
    end
    if view == "member" and not panel.memberView then
        panel.memberView = createMemberView(panel)
    end

    panel.rosterView:SetShown(view == "roster")
    if panel.itemsView then panel.itemsView:SetShown(view == "items") end
    if panel.memberView then panel.memberView:SetShown(view == "member") end
    panel.viewArea:SetShown(view ~= "member")
    panel.row2:SetShown(view ~= "member")
    panel.footer:SetShown(view ~= "member")

    updateToolbar()
    if view == "roster" then
        refreshRoster(rosterRows, stats, resetScroll)
    elseif view == "items" then
        refreshItems(phase, members, resetScroll, keepTreeScroll)
    else
        refreshMember(phase)
    end
    updateFooter(stats)
end

function CouncilUI:RequestRefresh()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce("council-ui", 0.2, function() CouncilUI:Refresh() end)
    else
        self:Refresh()
    end
end

----------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------

function CouncilUI:IsAvailable()
    local council = ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil()
    local demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    return (council or demo) and true or false
end

function CouncilUI:SetView(view)
    if view ~= "roster" and view ~= "items" and view ~= "member" and view ~= "council" then return end
    state.view = view
    if panel then
        panel.dirty = true
        self:Refresh(true)
    end
end

function CouncilUI:GetView()
    return state.view
end

-- Opens the Council tab (if available) and marks the panel for refresh.
function CouncilUI:OpenPanel()
    if ns.MainFrame and ns.MainFrame.Open then
        ns.MainFrame:Open("council")
    end
    if panel then
        panel.dirty = true
        self:Refresh(true)
    end
end

-- Member view for one name key (used by roster rows, the Items view and the Loot Log).
function CouncilUI:ShowMember(key)
    if type(key) ~= "string" or key == "" then return end
    state.memberKey = key
    state.view = "member"
    self:OpenPanel()
end

-- Items view focused on the boss that drops itemID (or its token); member view when it has no raid source
-- (5-man dungeon items are not in the Items tree: they count under "Other").
function CouncilUI:ShowItem(itemID, fromKey)
    itemID = tonumber(itemID)
    if not itemID then return end
    local srcs = ns.ItemDB and ns.ItemDB.GetSources and ns.ItemDB:GetSources(itemID, "raids")
    local first = type(srcs) == "table" and srcs[1]
    if first and first.ref and first.ref.key then
        state.selectedNode = first.ref.key
        state.focus = { [itemID] = true }
        if first.viaItem then state.focus[first.viaItem] = true end
    elseif fromKey then
        return self:ShowMember(fromKey)
    else
        state.selectedNode = OTHER_NODE
        state.focus = { [itemID] = true }
    end
    state.scrollToFocus = true
    state.view = "items"
    self:OpenPanel()
end

-- Items view for one boss (bossRef key).
function CouncilUI:ShowBoss(bossKey)
    if type(bossKey) ~= "string" or bossKey == "" then return end
    state.selectedNode = bossKey
    state.focus = nil
    state.scrollToFocus = true
    state.view = "items"
    self:OpenPanel()
end

-- Loot Council view (ADDENDUM E §30) --------------------------------------------------------------

-- Opens the Council tab on the Loot Council view.
function CouncilUI:ShowCouncil()
    state.view = "council"
    self:OpenPanel()
end

-- kind: "guild" | "raid" | nil (either).
function CouncilUI:CanEditCouncil(kind)
    if kind == "guild" then return (IsInGuild and IsInGuild() and canEditGuildCouncil()) and true or false end
    if kind == "raid" then return canEditRaidCouncil() end
    return self:CanEditCouncil("guild") or canEditRaidCouncil()
end

function CouncilUI:RefreshCouncilView()
    if panel and panel.councilView and panel:IsVisible() and state.view == "council" then
        refreshCouncilView()
    elseif panel then
        panel.dirty = true
    end
end

-- A copy of the editor's draft: { members = {[key]=true}, phase = n (guild), dirty = bool }.
function CouncilUI:GetCouncilDraft(kind)
    if kind ~= "guild" and kind ~= "raid" then return nil end
    local d = getDraft(kind)
    return { members = copySet(d.members), phase = d.phase, de = d.de, bank = d.bank, dirty = draftDirty(kind) }
end

function CouncilUI:IsCouncilDirty(kind)
    return (kind == "guild" or kind == "raid") and draftDirty(kind) or false
end

-- Adds / removes one name in the draft (nothing is sent until Save & share).
function CouncilUI:ToggleCouncilDraft(kind, key)
    if type(key) ~= "string" or key == "" or not self:CanEditCouncil(kind) then return false end
    local d = getDraft(kind)
    if d.members[key] then
        d.members[key] = nil
    else
        if countSet(d.members) >= MAX_COUNCIL_NAMES then
            ns:Print("A council list holds at most %d names.", MAX_COUNCIL_NAMES)
            return false
        end
        d.members[key] = true
    end
    self:RefreshCouncilView()
    return true
end

function CouncilUI:SetCouncilDraftPhase(phase)
    phase = clampPhase(phase)
    if not phase or not self:CanEditCouncil("guild") then return false end
    getDraft("guild").phase = phase
    self:RefreshCouncilView()
    return true
end

-- ADDENDUM G §41: sets the draft's disenchanter (field "de") or guild bank character ("bank"); key nil = none.
function CouncilUI:SetCouncilDraftTarget(kind, field, key)
    if (field ~= "de" and field ~= "bank") or not self:CanEditCouncil(kind) then return false end
    if key ~= nil and (type(key) ~= "string" or key == "") then return false end
    getDraft(kind)[field] = key
    self:RefreshCouncilView()
    return true
end

-- The picker menu of a target button: None, my raid, online guild members (guild list: also everyone).
function CouncilUI:OpenTargetMenu(kind, field, owner)
    if not self:CanEditCouncil(kind) or not (ns.UI and ns.UI.ContextMenu) then return end
    local d = getDraft(kind)
    local cur = d[field]
    local function add(menu, key)
        menu:CreateButton((cur == key and "* " or "") .. councilName(key), function()
            CouncilUI:SetCouncilDraftTarget(kind, field, key)
        end)
    end
    local raidKeys = {}
    local g = ns.Util and ns.Util.group
    if inRaid() and type(g) == "table" then
        for key in pairs(g) do raidKeys[#raidKeys + 1] = key end
        table.sort(raidKeys, nameLess)
    end
    local online = {}
    for _, key in ipairs(guildCall("GetOnlineMembers") or {}) do
        if realGuildMember(key) then online[#online + 1] = key end
    end
    table.sort(online, nameLess)
    local all = {}
    if kind == "guild" and ns.Guild and ns.Guild.GetMembers then
        for _, key in ipairs(ns.Guild:GetMembers() or {}) do
            if realGuildMember(key) then all[#all + 1] = key end
        end
        table.sort(all, nameLess)
    end
    local function fill(sub, keys)
        if sub.SetScrollMode and #keys > 20 then sub:SetScrollMode(400) end
        for _, key in ipairs(keys) do add(sub, key) end
    end
    ns.UI:ContextMenu(owner, function(root)
        root:CreateTitle(field == "de" and "Disenchanter" or "Guild bank character")
        root:CreateButton((cur == nil and "* " or "") .. "None", function()
            CouncilUI:SetCouncilDraftTarget(kind, field, nil)
        end)
        if cur and not realGuildMember(cur) and not (g and g[cur]) then add(root, cur) end   -- keep showing the pick
        if #raidKeys > 0 then
            fill(root:CreateButton(string.format("In your raid (%d)", #raidKeys)), raidKeys)
        end
        if #online > 0 then
            fill(root:CreateButton(string.format("Guild - online (%d)", #online)), online)
        end
        if #all > 0 then
            fill(root:CreateButton(string.format("Guild - all (%d)", #all)), all)
        end
    end)
end

function CouncilUI:RevertCouncil(kind)
    if kind ~= "guild" and kind ~= "raid" then return end
    resetDraft(kind)
    self:RefreshCouncilView()
end

-- Save & share: guild -> Guild:SetGuildCouncil (GM only, sends CG); raid -> Guild:SetMyRaidList (sends CR
-- when I lead the raid).
function CouncilUI:SaveCouncil(kind)
    if kind ~= "guild" and kind ~= "raid" then return false end
    if not self:CanEditCouncil(kind) then
        ns:Print(kind == "guild" and "Only the Guild Master can change the guild council."
            or "Only the raid leader can change this raid's council.")
        return false
    end
    local d = getDraft(kind)
    local members = copySet(d.members)
    local targets = { de = d.de or false, bank = d.bank or false }   -- (ADDENDUM G: false = none)
    local ok, err
    if kind == "guild" then
        ok, err = guildCall("SetGuildCouncil", members, d.phase, targets)
    else
        ok, err = guildCall("SetMyRaidList", members, targets)
    end
    if not ok then
        ns:Print("The council list was not saved: %s", tostring(err or "this CDLoot core can't share council lists"))
        self:RefreshCouncilView()
        return false
    end
    resetDraft(kind)
    local n = countSet(members)
    if kind == "guild" then
        ns:Print("Guild council saved and shared: %s, phase P%d.", membersText(n), d.phase or 1)
    elseif amRaidLeader() then
        ns:Print("Raid council saved and shared with your raid: %s.", membersText(n))
    else
        ns:Print("Raid council saved (%s). It is shared automatically whenever you lead a raid.", membersText(n))
    end
    self:RefreshCouncilView()
    return true
end

-- "Clear list" asks first, then saves (and shares) an empty list.
function CouncilUI:ConfirmClearCouncil(kind)
    if (kind ~= "guild" and kind ~= "raid") or not self:CanEditCouncil(kind) then return false end
    ensureClearPopup()
    local text
    if kind == "guild" then
        text = "Remove everyone from the guild council and share the empty list with the guild?\n\n"
            .. "The Guild Master always stays on the council."
    else
        text = "Remove everyone from your raid council list?\n\nThe raid leader always stays on the council of their raid."
    end
    if StaticPopup_Show then StaticPopup_Show("CDLOOT_CLEAR_COUNCIL", text, nil, kind) end
    return true
end

function CouncilUI:ClearCouncil(kind)
    if (kind ~= "guild" and kind ~= "raid") or not self:CanEditCouncil(kind) then return false end
    local ok, err
    if kind == "guild" then
        local saved = savedList("guild")
        ok, err = guildCall("SetGuildCouncil", {}, saved and savedPhase(saved) or getDraft("guild").phase)
    else
        ok, err = guildCall("SetMyRaidList", {})
    end
    if not ok then
        ns:Print("The council list was not cleared: %s", tostring(err or "this CDLoot core can't share council lists"))
        self:RefreshCouncilView()
        return false
    end
    resetDraft(kind)
    ns:Print(kind == "guild" and "Guild council cleared and shared: only the Guild Master is council now."
        or "Raid council list cleared.")
    self:RefreshCouncilView()
    return true
end

-- Read-only summary for the Settings tab (everyone):
-- { inGuild, gm, guild = {rev, by, phase} or nil, guildMembers = { {key, name, online, fixed}... },
--   inRaid, raidLeader, raidShared, raidMembers = {...}, mySource, canEdit }
function CouncilUI:GetCouncilSummary()
    local function entry(key, fixed)
        return { key = key, name = councilName(key), online = councilOnline(key), fixed = fixed }
    end
    local saved = savedList("guild")
    local gm = guildCall("GetGM")
    local out = {
        inGuild = (IsInGuild and IsInGuild()) and true or false,
        gm = gm,
        guild = saved and { rev = saved.rev, by = saved.by or gm, phase = savedPhase(saved) } or nil,
        guildMembers = {},
        inRaid = inRaid(),
        raidLeader = raidLeaderKey(),
        raidShared = false,
        raidMembers = {},
        canEdit = self:CanEditCouncil(),
    }
    local me = playerKey()
    out.mySource = me and guildCall("GetCouncilSource", me) or nil
    if gm then out.guildMembers[1] = entry(gm, "Guild Master") end
    for _, key in ipairs(sortedSet(copySet(saved and saved.members))) do
        if key ~= gm then out.guildMembers[#out.guildMembers + 1] = entry(key) end
    end
    if out.inRaid then
        local leader = out.raidLeader
        local rc = guildCall("GetRaidCouncil")
        if type(rc) ~= "table" or (leader and rc.leader and rc.leader ~= leader) then rc = nil end
        if not rc and leader and leader == me then
            local mine = savedList("raid")   -- I lead: my own list is this raid's council
            if mine then rc = { leader = me, members = mine.members } end
        end
        out.raidShared = rc ~= nil
        if leader then out.raidMembers[1] = entry(leader, "Raid leader") end
        for _, key in ipairs(sortedSet(copySet(rc and rc.members))) do
            if key ~= leader then out.raidMembers[#out.raidMembers + 1] = entry(key) end
        end
    end
    return out
end

----------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------

function CouncilUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("council", "Council", 2,
            function(parent) return CouncilUI:CreatePanel(parent) end,
            function() return CouncilUI:IsAvailable() end)
    end

    local function refresh()
        CouncilUI:RequestRefresh()
    end
    -- A new saved council list replaces the editor's draft unless it has unsaved edits.
    ns:On("CONFIG_UPDATED", syncCouncilDrafts)
    for _, msg in ipairs({
        "LIST_UPDATED", "LISTS_RESET", "LEDGER_UPDATED", "RAIDLOG_CHANGED", "GROUP_UPDATED", "ROSTER_UPDATED",
        "ITEMINFO_READY", "CONFIG_UPDATED", "DEMO_TOGGLED", "PEERS_UPDATED",
        "MYLIST_CHANGED", "MYLIST_COMMITTED", "OWNED_UPDATED", "GROUP_RULES_CHANGED",
        "BIS_LOCK_CHANGED",
    }) do
        ns:On(msg, refresh)
    end
    local function resetSelection()
        state.memberKey, state.selectedNode, state.focus = nil, nil, nil
        refresh()
    end
    ns:On("DEMO_TOGGLED", resetSelection)
    ns:On("SETTINGS_CHANGED", function(key)
        if key == "viewPhase" then refresh() end
    end)
end
