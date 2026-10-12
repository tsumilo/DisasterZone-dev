if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Council.lua", ...) then return end -- DisasterZone: "Council" tab (SPEC §12.6): roster x slot matrix, "who wants it" per boss, read-only member view,
-- and the Loot Council view (ADDENDUM E §30: guild council picked by the GM, raid council by the raid leader).
-- Only offered to Loot Council members (or in demo mode). Built from ns.UI widgets and ns.PaperDoll.
-- ADDENDUM F: slots a player disabled show a dark "–" and are left out of the counts (§36); the raid leader
-- locks / unlocks the BiS lists from the toolbar, and players who changed their list while locked carry a
-- warning marker in the roster, the Items view and the member header (§38).
-- 1.4 (the shared structure): the panel is a List + detail layout (UI:CreateLayout "listdetail"): the view tabs, the
-- phase and the search in its toolbar, the filter strip under it; Roster fills the content, Items is the tree (the
-- list column) and the boss's cards (the detail, under the boss's banner), the member page opens with a banner (back
-- link, class, the member's line, previous / next as its tools), the Loot council view is two cards. The texts are
-- the type scale, the colours ns.Style tokens, the empty lists illustrated empty states, the questions Popup:Confirm.
local addonName, ns = ...

local CouncilUI = ns:NewModule("CouncilUI")
local UI, S = ns.UI, ns.Style

local NUM_SLOTS = ns.NUM_SLOTS or 17
-- The look (one table: this file is close to Lua's 200 locals per chunk). The page grid is the Raids tab's: 10 at
-- the sides, 8 between blocks, 12 inside cards. Every view starts its first block at TOP_Y (under the view tabs);
-- Roster / Items / Loot log put their lists under a filter row (CONTENT_Y).
local K = {
    PAD = S.PAD, GAP = S.GAP, IN = S.PAD,
    W = S.INNER_W,                   -- the panel's inside width (790 - 2 PAD; GetWidth() is 0 in the mock)
    TOP_Y = -UI.LAYOUT.TOP,          -- the toolbar's foot: every view starts here (the Loot log / Rules too)
    FILTER_H = 24,                   -- the filter strip under the toolbar (Roster, Items)
    FOOT_H = S.ROW.compact,
    -- Roster
    ROW_H = S.ROW.list, HEAD_H = 24, CELL = 20, CELL_PITCH = 25, CELL_X0 = 288, GROUP_GAP = 8,
    -- Items
    TREE_W = 196, TREE_ROW_H = 18, STRIP_H = 30, STRIP_GAP = 4,
    CHIP_H = UI.CHIP_LOOK.track.h, CHIP_GAP = 4, FOLD_H = 30, QUIET_H = 30,
    DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
    SYNC_ICON = "Interface\\Buttons\\UI-RefreshButton",
    -- the role chips (the LFG icons): melee, casters and ranged share the damage chip
    ROLE_CHIPS = { { key = "tank", label = "Tanks" }, { key = "healer", label = "Healers" },
                   { key = "dps", label = "Damage dealers" } },
    ROLE_GROUP = { tank = "tank", healer = "healer", melee = "dps", caster = "dps", ranged = "dps" },
    -- the presence dot: in the raid green, online gold, offline grey
    PRESENCE_COLOR = { raid = "OK", online = "GOLD_DEEP", offline = "DIM" },
    VIEW_LABEL = { roster = "Roster", items = "Items", log = "Loot log", council = "Loot council", rules = "Rules" },
}
K.CONTENT_Y = K.TOP_Y - K.FILTER_H - S.GAP    -- the Roster / Items content under the filter strip
K.LIST_BOTTOM = 6 + K.FOOT_H + K.GAP   -- the Roster / Items lists end above the footer
local STALE_SECONDS = 7 * 86400
local MAX_TOOLTIP_WANTERS = 20
local MAX_WEAR_LINES = 10           -- "Wearing: A, B" sub-lines in the Items view tooltip
local ANNOUNCE_COOLDOWN = 2
local OTHER_NODE = "OTHER"

local DEFAULT_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local PRESENCE_RANK = { raid = 1, online = 2, offline = 3 }
local PRESENCE_TEXT = { raid = "In your raid", online = "Online", offline = "Offline" }
-- Paired slots (ADDENDUM A §18): rings, trinkets and weapons show both worn items.
local SLOT_GROUP_FALLBACK = {
    [11] = { 11, 12 }, [12] = { 11, 12 }, [13] = { 13, 14 }, [14] = { 13, 14 }, [15] = { 15, 16 }, [16] = { 15, 16 },
}
local CHECK_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"

-- Session-only view state (not saved).
local state = {
    phase = nil,           -- nil = follow ns.Guild:GetViewPhase()
    view = "roster",       -- "roster" | "items" | "member" | "log" (the Loot Log, UI/LootLog.lua) | "council"
    backView = "roster",   -- the view the member page goes back to (its tab stays lit)
    search = "",           -- lower-cased search text
    classes = {},          -- [classFile] = true: the class chips picked (none = every class)
    roles = {},            -- [tank | healer | dps] = true: the role chips picked (none = every role)
    showUnwanted = false,  -- Items view: the items nobody wants are unfolded
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

-- The loot colours (ns.COLORS: main / alt / obtained / warn ...): r, g, b, and as a |cff code.
local function color(name)
    local c = ns.COLORS[name] or ns.COLORS.needed
    return c[1], c[2], c[3]
end

local function colorCode(name)
    return "|c" .. UI:ColorHex(color(name))
end

local shortName = ns.Util.ShortName
local formatAgo = ns.Util.FormatAgo

local function coloredName(key, classFile)
    return UI:ColoredName(key, classFile)
end

local function className(classFile)
    return ns.ClassName(classFile, true) or ""
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

-- (one value: UI:ItemText's second return says the name is still loading)
local function itemText(itemID)
    if not itemID then return "" end
    local text = UI:ItemText(itemID)
    return text
end

local function itemName(itemID)
    return itemID and UI:ItemName(itemID)
end

local function itemLink(itemID)
    return itemID and UI:GetItemLink(itemID)
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

-- Puts an item link into chat (UI:LinkInChat opens the chat box when none is active).
local function linkInChat(itemID)
    if itemID then UI:LinkInChat(itemID) end
end

-- The page's small pieces, in one table V (this file is close to Lua's 200 locals per chunk).
local V = {}

-- (an "ignore" pass for script handlers: the tooltip goes)
V.hideTip = UI.HideTooltip

-- A title and lines as a frame's tooltip (UI:AttachTooltip; anchored on top like the toolbar's).
function V.tip(frame, title, ...)
    local lines = { ... }
    UI:AttachTooltip(frame, title, lines, { anchor = "ANCHOR_TOP" })
end

function V.desaturate(tex, on)
    if tex.SetDesaturation then tex:SetDesaturation(on and 1 or 0) else tex:SetDesaturated(on and true or false) end
end

-- A class circle of `size` (a grey disc for an unknown class), with a presence dot of `dot` px on its lower right
-- when dot is given: c:Set(classFile, presence) ("raid" | "online" | "offline" | nil = no dot).
-- TODO(refactor): move into Controls (a class circle with a presence dot: the roster, the council lists)
function V.classCircle(parent, size, dot)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(size, size)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetAllPoints()
    if dot then
        c.ring = c:CreateTexture(nil, "OVERLAY", nil, 1)
        c.ring:SetTexture(K.DISC)
        c.ring:SetSize(dot + 3, dot + 3)
        c.ring:SetPoint("CENTER", c, "BOTTOMRIGHT", -dot / 2 + 1, dot / 2 - 1)
        c.ring:SetVertexColor(0.04, 0.04, 0.05, 1)
        c.dot = c:CreateTexture(nil, "OVERLAY", nil, 2)
        c.dot:SetTexture(K.DISC)
        c.dot:SetSize(dot, dot)
        c.dot:SetPoint("CENTER", c.ring, "CENTER", 0, 0)
    end
    function c:Set(classFile, presence)
        self.icon:SetVertexColor(1, 1, 1, 1)
        ns.UI:ClassIcon(self.icon, classFile)
        if not (classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]) then
            self.icon:SetTexture(K.DISC)
            self.icon:SetTexCoord(0, 1, 0, 1)
            self.icon:SetVertexColor(0.3, 0.3, 0.33, 1)
            self.icon:Show()
        end
        if self.dot then
            local pc = presence and K.PRESENCE_COLOR[presence]
            self.dot:SetShown(pc ~= nil)
            self.ring:SetShown(pc ~= nil)
            if pc then
                local r, g, b = S:Color(pc)
                self.dot:SetVertexColor(r, g, b, 1)
            end
        end
    end
    return c
end

-- A scroll list whose bar sits in the margin 4px right of its rows (CreateScrollList reserves 20px inside).
function V.barInMargin(list)
    local box, bar = list.box, list.bar
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", list.frame, "TOPLEFT", 0, 0)
    box:SetPoint("BOTTOMRIGHT", list.frame, "BOTTOMRIGHT", 0, 0)
    if bar then
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
        bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
    end
    return list
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
    if next(state.classes) and not (classFile and state.classes[classFile]) then return false end
    if next(state.roles) then
        local group = K.ROLE_GROUP[specRole(classFile, spec) or ""]
        if not (group and state.roles[group]) then return false end
    end
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
    if ns.Prized and ns.Prized.IsPrized and ns.Prized:IsPrized(itemID) then
        ns:Print("Prized item: award it from the drop panel, so the council can vote (Raids > Loot rules).")
        return
    end
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
        local bossRows, total, first, firstAny = {}, 0, nil, nil
        for _, boss in ipairs(raid.bosses or {}) do
            if raid.key and boss.key then
                local key = raid.key .. ":" .. boss.key
                local n = byBoss[key] or 0
                if n > 0 or key == state.selectedNode or (raid.phase == phase and not boss.isTrash) then
                    bossRows[#bossRows + 1] = { type = "boss", key = key, name = boss.name or boss.key, count = n,
                                                raidKey = raid.key }
                    total = total + n
                    firstAny = firstAny or key
                    if n > 0 and not first then first = key end
                end
            end
        end
        if #bossRows > 0 then
            rows[#rows + 1] = { type = "raid", name = raid.name or raid.key or "?", phase = raid.phase, count = total,
                                raidKey = raid.key, instanceID = raid.instanceID, firstKey = first or firstAny }
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
    tt:AddLine(string.format("|cffff8000DisasterZone|r · P%d: %d wanting", d.phase or currentPhase(), d.n or 0))
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
            left = left .. S:Wrap("DIM", " " .. e.spec)
        end
        if e.wanted and e.wanted ~= d.itemID then
            left = left .. S:Wrap("DIM", " > " .. (itemName(e.wanted) or ("item " .. e.wanted)))
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

----------------------------------------------------------------------------
-- Roster view: one row per member (class circle with the presence dot, name, spec, picks still needed), the 17
-- picks as item icons (obtained ones dimmed while "Hide obtained" is ticked), the list's age.
----------------------------------------------------------------------------

local Roster = (function()
local PAD = K.PAD
local NAME_X, NAME_W = 32, 108
local SPEC_X, SPEC_W = 146, 96
local NEED_R, AGE_R = 274, 764     -- right edges (the numbers line up on the right)
local CELL_X0, CELL_PITCH, GROUP_GAP, CELL_SIZE = K.CELL_X0, K.CELL_PITCH, K.GROUP_GAP, K.CELL

local function cellX(sid)
    local x = CELL_X0 + (sid - 1) * CELL_PITCH
    if sid > 10 then x = x + GROUP_GAP end
    if sid > 14 then x = x + GROUP_GAP end
    return x
end

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
        tt:AddLine(coloredName(d.key, d.classFile) .. S:Wrap("DIM", string.format(" doesn't need this slot in P%d.", phase)))
        tt:AddLine("Click: member view", 0.5, 0.5, 0.5)
        return
    end
    if main then
        tt:AddLine(" ")
        tt:AddLine("|cffff8000DisasterZone|r · " .. coloredName(d.key, d.classFile) .. " - " .. slotLabel)
        tt:AddLine(string.format("Main (P%d)", phase), color("main"))
    else
        tt:AddLine(slotLabel)
        tt:AddLine(coloredName(d.key, d.classFile) .. S:Wrap("DIM", string.format(" has no P%d pick here.", phase)))
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

-- §36: a disabled slot is a faint square with a "–" (quieter than an empty one).
local function setCellDisabled(cell, disabled)
    if disabled and not cell.cdlDash then
        cell.cdlDash = UI:Text(cell, "small", "DIM", { justify = "CENTER", text = "\226\128\147" })   -- "–" (U+2013)
        cell.cdlDash:SetPoint("CENTER", cell, "CENTER", 0, 0)
    end
    if cell.cdlDash then cell.cdlDash:SetShown(disabled) end
end

-- A pick: its icon in a 1px black frame (no quality glow: 17 of them side by side read as noise). Obtained picks
-- are dimmed while "Hide obtained" is ticked, else they carry the check; awarded ones the star. Empty and disabled
-- slots are faint squares.
local function paintCell(cell, d, sid, phase)
    local disabled = slotDisabled(d.record, phase, sid)
    local main, alt = getPicks(d.data, phase, sid)
    if disabled then main, alt = nil, nil end
    cell.cdlRow, cell.cdlSid, cell.cdlMain, cell.cdlAlt = d, sid, main, alt
    cell.cdlDisabled = disabled or nil
    cell:SetItem(main)
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
    if main then
        cell.bg:SetColorTexture(0, 0, 0, 0.9)
        if dim then
            cell.overlay:Hide()
            V.desaturate(cell.icon, true)
            cell:SetAlpha(0.3)
        end
    else
        cell.icon:SetAlpha(0)
        cell.bg:SetColorTexture(S:Color(disabled and "STRIPE" or "QUIET"))
    end
    setCellDisabled(cell, disabled)
end

-- The row's tooltip (UI:AttachTooltip's title function).
local function rosterTip(row, tt)
    local d = row.cdlData
    if not d then return false end
    local phase = currentPhase()
    tt:AddLine(coloredName(d.key, d.classFile))
    local specClass = (d.spec ~= "" and (d.spec .. " ") or "") .. className(d.classFile)
    if specClass ~= "" then tt:AddLine(specClass, 1, 1, 1) end
    local rank = ns.Guild and ns.Guild.GetRankName and ns.Guild:GetRankName(d.key)
    if rank then tt:AddLine(rank, 0.8, 0.8, 0.8) end
    tt:AddLine(PRESENCE_TEXT[d.presence] or "", 0.8, 0.8, 0.8)
    local counts = string.format("P%d: %d picks · %d obtained · %d needed", phase, d.filled, d.filled - d.need, d.need)
    if (d.disabled or 0) > 0 then counts = counts .. string.format(" · %d disabled", d.disabled) end
    tt:AddLine(counts, 1, 1, 1)
    local updated = "List updated " .. formatAgo(d.ts)
    if d.rev > 0 then updated = updated .. string.format(" (rev %d)", d.rev) end
    if d.stale then
        tt:AddLine(updated, color("warn"))
    else
        tt:AddLine(updated, 0.8, 0.8, 0.8)
    end
    if d.lockChanged then
        UI:AddLockChangedLine(tt, d.lockChanged, "Not suggested as a roll winner; the council can still award.")
    end
    tt:AddLine("Click: open member view", 0.5, 0.5, 0.5)
end

local function setupRosterRow(row)
    row.cdlInit = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- the shared list row: its stripe (every second row) and hover
    UI:DecorateRow(row, { hover = true, stripe = true })

    row.circle = V.classCircle(row, 18, 7)
    row.circle:SetPoint("LEFT", 6, 0)

    row.name = UI:Text(row, "emph")
    row.name:SetPoint("LEFT", NAME_X, 0)
    row.name:SetWidth(NAME_W)

    -- §38: "changed during lock" marker right after the name (tooltip: the row's)
    row.lockWarn = row:CreateTexture(nil, "OVERLAY")
    row.lockWarn:SetSize(12, 12)
    row.lockWarn:SetTexture((ns.UI and ns.UI.ICON_WARN) or "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
    row.lockWarn:Hide()

    row.spec = UI:Text(row, "small", "SUB")
    row.spec:SetPoint("LEFT", SPEC_X, 0)
    row.spec:SetWidth(SPEC_W)

    row.need = UI:Text(row, "emph", "TEXT", { justify = "RIGHT", width = 30 })
    row.need:SetPoint("RIGHT", row, "LEFT", NEED_R, 0)

    row.cells = {}
    for sid = 1, NUM_SLOTS do
        local cell = ns.UI:CreateItemButton(row, CELL_SIZE)
        cell:SetPoint("LEFT", row, "LEFT", cellX(sid), 0)
        cell.bg:SetVertexColor(1, 1, 1, 1)
        cell.border:SetAlpha(0)
        cell.onTooltip = cellTooltip
        cell.onClick = cellClick
        row.cells[sid] = cell
    end

    row.age = UI:Text(row, "small", "TEXT", { justify = "RIGHT", width = 40 })
    row.age:SetPoint("RIGHT", row, "LEFT", AGE_R, 0)

    row:SetScript("OnClick", function(self)
        if self.cdlData then CouncilUI:ShowMember(self.cdlData.key) end
    end)
    UI:AttachTooltip(row, rosterTip, nil, { anchor = "ANCHOR_TOPLEFT" })
end

local function initRosterRow(row, d)
    if not row.cdlInit then setupRosterRow(row) end
    row.cdlData = d
    local phase = currentPhase()
    row:SetStripe(d.rowIndex or 0)
    row.circle:Set(d.classFile, d.presence)
    row.name:SetText(coloredName(d.key, d.classFile))
    if d.lockChanged then
        local w = math.min(row.name:GetStringWidth() or 0, NAME_W - 16)
        row.name:SetWidth(NAME_W - 16)
        row.lockWarn:ClearAllPoints()
        row.lockWarn:SetPoint("LEFT", row, "LEFT", NAME_X + w + 4, 0)
        row.lockWarn:Show()
    else
        row.name:SetWidth(NAME_W)
        row.lockWarn:Hide()
    end
    row.spec:SetText(d.spec ~= "" and d.spec or "-")
    if d.filled == 0 then
        row.need:SetText(S:Wrap("DIM", "-"))
    elseif d.need == 0 then
        row.need:SetText(colorCode("obtained") .. "0|r")
    else
        row.need:SetText(tostring(d.need))
    end
    for sid = 1, NUM_SLOTS do
        paintCell(row.cells[sid], d, sid, phase)
    end
    row.age:SetText(shortAge(d.ts))
    row.age:SetTextColor(S:Color(d.stale and "WARN" or "SUB"))
end

local SORT_LABELS = { presence = "presence", name = "name", need = "most needed", age = "oldest list" }

local function createRosterHeader(parent)
    local h = ns.UI:CreateColumnHeader(parent, K.HEAD_H)
    h.sortButtons = {}
    h.rule = UI:Rule(h, { bottom = 0, layer = "BORDER" })

    -- sortKeys: clicking cycles through them (Name: presence -> name).
    local function textHeader(text, x, width, sortKeys, justify)
        local b = h:AddColumn(text, x, width, {
            justify = justify,
            onClick = function()
                local nextKey = sortKeys[1]
                for i, k in ipairs(sortKeys) do
                    if k == state.sort then
                        nextKey = sortKeys[i % #sortKeys + 1]
                        break
                    end
                end
                state.sort = nextKey
                CouncilUI:Refresh(true)
            end,
            tip = function()
                local labels = {}
                for _, k in ipairs(sortKeys) do
                    labels[#labels + 1] = SORT_LABELS[k] or k
                end
                GameTooltip:AddLine("Sort by " .. table.concat(labels, " / "))
                GameTooltip:AddLine("Current: " .. (SORT_LABELS[state.sort] or state.sort), 1, 1, 1)
            end,
        })
        b.sortKeys = sortKeys
        h.sortButtons[#h.sortButtons + 1] = b
        return b
    end

    textHeader("Name", 6, NAME_X + NAME_W - 6, { "presence", "name" })
    h:AddColumn("Spec", SPEC_X, SPEC_W)
    textHeader("Need", NEED_R - 30, 30, { "need" }, "RIGHT")
    textHeader("Age", AGE_R - 40, 40, { "age" }, "RIGHT")

    -- the slots: their empty-slot art, lit (the game's own is near black)
    for sid = 1, NUM_SLOTS do
        local f = CreateFrame("Frame", nil, h)
        f:SetSize(CELL_SIZE, CELL_SIZE)
        f:SetPoint("LEFT", cellX(sid), 0)
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetAllPoints()
        local empty = ns.UI and ns.UI.EmptySlotTexture and ns.UI:EmptySlotTexture(sid)
        t:SetTexture(empty or ns.TEX.slotBg)
        t:SetTexCoord(0.12, 0.88, 0.12, 0.88)
        t:SetBlendMode("ADD")
        t:SetAlpha(1)
        V.tip(f, ns.SlotLabel(sid))
    end

    function h:UpdateSort()
        for _, b in ipairs(self.sortButtons) do
            local active = false
            for _, k in ipairs(b.sortKeys) do
                if k == state.sort then active = true end
            end
            b.label:SetTextColor(S:Color(active and "TEXT" or "GOLD"))
        end
    end
    return h
end

-- The roster fills the layout's content (under the filter strip, above the footer).
local function createRosterView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints(parent.layout.content)
    v.header = createRosterHeader(v)
    v.header:SetPoint("TOPLEFT", 0, 0)
    v.header:SetPoint("TOPRIGHT", 0, 0)
    v.list = V.barInMargin(ns.UI:CreateScrollList(v, K.ROW_H, initRosterRow))
    v.list.frame:ClearAllPoints()
    v.list.frame:SetPoint("TOPLEFT", 0, -K.HEAD_H - 2)
    v.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    return v
end

local function refreshRoster(rows, stats, resetScroll)
    local v = panel.rosterView
    v.header:UpdateSort()
    for i, r in ipairs(rows) do r.rowIndex = i end
    -- nothing to list: the illustrated empty state (no lists yet, or the filters leave nobody)
    if stats.total == 0 then
        v.list:SetEmptyState({ icon = UI.ICON.notes, title = "No BiS lists received yet",
            text = "Members share their lists automatically while a council member is online." })
    else
        v.list:SetEmptyState({ icon = UI.ICON.notes, title = "No members match the current filters",
            text = "Pick other classes or roles, untick In my raid, or clear the search." })
    end
    setListData(v.list, rows, resetScroll)
    v.empty = v.list.emptyState
end

return { create = createRosterView, refresh = refreshRoster }
end)()

----------------------------------------------------------------------------
-- Items view: the raids as art strips (the open one lists its bosses), the chosen boss's items as cards with who
-- wants each (class-circle chips: alt picks and owners marked), the items nobody wants folded into one line.
----------------------------------------------------------------------------

local Items = (function()
local PAD, GAP = K.PAD, K.GAP
local TREE_W, STRIP_H, STRIP_GAP, TREE_ROW_H = K.TREE_W, K.STRIP_H, K.STRIP_GAP, K.TREE_ROW_H
local COL_W = K.W - TREE_W - GAP      -- the detail column (the layout's list + detail): 566
local ICON = 32
local CARD_PAD = S.PAD               -- a card's inside margin
local TEXT_X = CARD_PAD + ICON + 10  -- name and chips start here inside a card
local CHIPS_W = COL_W - TEXT_X - CARD_PAD - 4      -- (a little room before the card's edge)
local CARD_TOP = S.IN                -- name line top inside a card
local CHIPS_Y = 30                   -- first chip line top inside a card
local MAX_CHIP_LINES = 2

-- A text that fits `width`: the full one, else each shorter form in turn.
local function fitText(fs, width, full, ...)
    fs:SetText(full)
    if (fs:GetStringWidth() or 0) <= width then return end
    for i = 1, select("#", ...) do
        local alt = select(i, ...)
        if alt then
            fs:SetText(alt)
            if (fs:GetStringWidth() or 0) <= width then return end
        end
    end
end

-- Shorter boss names: without "the X" ("Attumen the Huntsman" -> "Attumen"), then without leading titles.
local function bossShort(name)
    local noTitle = name:gsub(" the .*$", "")
    if noTitle ~= name then return noTitle end
    local last = name:match("(%S+)$")
    return last ~= name and last or nil
end

----------------------------------------------------------------------------
-- The tree
----------------------------------------------------------------------------

local function treeRowClick(row)
    local d = row.cdlData
    if not d then return end
    if d.type == "raid" then
        if not d.firstKey or d.open then return end
        state.selectedNode = d.firstKey
    elseif d.key then
        state.selectedNode = d.key
    else
        return
    end
    state.focus = nil
    CouncilUI:Refresh(false, true)
end

-- (a raid strip's shade: the banners' slate, dark on the text side)
local STRIP_SHADE = { 0.035, 0.035, 0.043 }

local function setupTreeRow(row)
    row.cdlInit = true
    -- a raid (or "Other"): an art strip (its textures on the row, under the texts; the edges on a frame)
    row.strip = CreateFrame("Frame", nil, row)
    row.strip:SetPoint("BOTTOMLEFT", 0, 0)
    row.strip:SetPoint("BOTTOMRIGHT", 0, 0)
    row.strip:SetHeight(STRIP_H)
    row.strip:EnableMouse(false)
    row.art = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.art:SetAllPoints(row.strip)
    row.shade = row:CreateTexture(nil, "BACKGROUND", nil, 2)
    row.shade:SetAllPoints(row.strip)
    local c = STRIP_SHADE
    UI:Gradient(row.shade, "HORIZONTAL", { c[1], c[2], c[3], 0.92 }, { c[1], c[2], c[3], 0.5 })
    UI:AddEdges(row.strip, "BORDER")
    row.stripHl = row:CreateTexture(nil, "BORDER")
    row.stripHl:SetAllPoints(row.strip)
    row.stripHl:SetColorTexture(S:Color("HOVER"))
    row.stripHl:Hide()
    -- a boss: the shared row looks (the hover, the chosen one's gold wash and bar)
    UI:DecorateRow(row, { hover = true, selectable = true })
    row.sel = row.dzSelFill      -- (the chosen boss's fill, as the 1.3 field)
    row.count = UI:Text(row, "body", "TEXT", { justify = "RIGHT" })
    row.text = UI:Text(row, "body")
    row:SetScript("OnClick", treeRowClick)
    row:SetScript("OnEnter", function(self)
        if self.cdlData and self.cdlData.type ~= "boss" then self.stripHl:Show() end
    end)
    row:SetScript("OnLeave", function(self) self.stripHl:Hide() end)
end

local function initTreeRow(row, d)
    if not row.cdlInit then setupTreeRow(row) end
    row.cdlData = d
    local phase = currentPhase()
    local strip = d.type ~= "boss"
    local chosen = d.key ~= nil and d.key == state.selectedNode
    row.strip:SetShown(strip)
    row.shade:SetShown(strip)
    if not strip then row.art:Hide() end
    row:SetSelected(not strip and chosen)
    row.dzHover:SetAlpha(strip and 0 or 1)
    row.count:ClearAllPoints()
    row.text:ClearAllPoints()
    if strip then
        row.count:SetPoint("RIGHT", row.strip, "RIGHT", -8, 0)
        row.text:SetPoint("LEFT", row.strip, "LEFT", 8, 0)
        -- the raid's loading screen (ItemDB:RaidArt, by the raid's item key); "Other" has none
        if d.type == "raid" and d.raidKey then
            UI:SetArtTexture(row.art, d.raidKey, TREE_W, STRIP_H)
            row.art:Show()
        else
            row.art:Hide()
        end
        local on = d.open or (d.type == "other" and chosen)
        local idle = (d.count or 0) == 0 and not on
        V.desaturate(row.art, idle)
        row.art:SetAlpha(idle and 0.45 or 1)
        UI:SetEdgeColor(row.strip, S:Color(on and "EDGE_FOCUS" or "EDGE"))
        local tag = (d.phase and d.phase ~= phase) and S:Wrap("DIM", "  P" .. d.phase) or ""
        local room = TREE_W - 16 - 34
        local short = d.type == "raid" and d.raidKey and ns.ItemDB:RaidShort(d.raidKey)
        UI:SetTextStyle(row.text, "emph", idle and "SUB" or "GOLD")
        fitText(row.text, room, d.name .. tag, short and (short .. tag) or nil)
        row.count:SetText(d.count > 0 and tostring(d.count) or "")
        row.count:SetTextColor(S:Color("TEXT"))
    else
        row.count:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        row.text:SetPoint("LEFT", row, "LEFT", 14, 0)
        UI:SetTextStyle(row.text, "body", (chosen and "TEXT") or (d.count > 0 and "TEXT") or "DIM")
        if chosen then row.text:SetTextColor(1, 1, 1) end
        fitText(row.text, TREE_W - 14 - 34, d.name, bossShort(d.name))
        row.count:SetText(d.count > 0 and tostring(d.count) or "")
        row.count:SetTextColor(S:Color("SUB"))
    end
end

-- Tree rows are 18 high; a strip is 30 with a 4px gap above it (none for the first row).
local function treeExtent(d)
    if d.type == "boss" then return TREE_ROW_H end
    return STRIP_H + (d.first and 0 or STRIP_GAP)
end

----------------------------------------------------------------------------
-- The item cards
----------------------------------------------------------------------------

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
        text = "DisasterZone: " .. label .. " - " .. table.concat(parts, " · ")
    else
        text = "DisasterZone: " .. label .. " - nobody has this on their BiS list"
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
        local award = root:CreateButton(live and ("Record award to " .. S:Wrap("DIM", "(closes the open roll)"))
            or "Record award to")
        for _, e in ipairs(people) do
            local key = e.key
            local label = coloredName(key, e.classFile)
            if e.which == "alt" then label = label .. S:Wrap("DIM", " (alt)") end
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
    if d.type == "fold" then
        state.showUnwanted = not state.showUnwanted
        CouncilUI:Refresh()
        -- unfolded: the fold goes to the top, the items it held under it
        local box = panel.itemsView and panel.itemsView.list.box
        if state.showUnwanted and box and box.FindElementDataIndexByPredicate and box.ScrollToElementDataIndex then
            local index = box:FindElementDataIndexByPredicate(function(x) return x.type == "fold" end)
            if index then box:ScrollToElementDataIndex(index, 0) end
        end
        return
    end
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
    if row.card then UI:SetEdgeColor(row.card, S:Color("EDGE_STRONG")) end
    if d.type == "fold" then
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(state.showUnwanted and "Fold these items away" or "Show these items")
        for i, r in ipairs(d.items) do
            if i > 12 then
                GameTooltip:AddLine(string.format("+%d more", #d.items - 12), 0.6, 0.6, 0.6)
                break
            end
            GameTooltip:AddLine(itemText(r.itemID))
        end
        GameTooltip:Show()
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(itemText(d.itemID))
    addWantersTooltip(GameTooltip, d)
    GameTooltip:Show()
end

local function itemRowLeave(row)
    V.hideTip()
    if row.cdlData and row.card then
        local f = row.cdlData.focus
        if f then
            UI:SetEdgeColor(row.card, S:Color("EDGE_FOCUS"))
        else
            UI:SetEdgeColor(row.card, 0, 0, 0, 0)
        end
    end
end

-- One wanter, for the chip's tooltip.
local function chipEnter(chip)
    local e = chip.entry
    if not e then return end
    GameTooltip:SetOwner(chip, "ANCHOR_TOP")
    if chip.rest then
        for _, x in ipairs(chip.rest) do
            GameTooltip:AddLine(coloredName(x.key, x.classFile) .. (x.which == "alt" and S:Wrap("DIM", " (alt)") or ""))
        end
        GameTooltip:Show()
        return
    end
    local left = coloredName(e.key, e.classFile)
    if type(e.spec) == "string" and e.spec ~= "" then left = left .. S:Wrap("DIM", " " .. e.spec) end
    GameTooltip:AddLine(left)
    local flags = { e.which == "alt" and (colorCode("alt") .. "Alt pick|r") or (colorCode("main") .. "BiS|r") }
    if e.obtained then flags[#flags + 1] = colorCode("obtained") .. "has it|r" end
    if e.inRaid then flags[#flags + 1] = "in raid" else flags[#flags + 1] = e.online and "online" or "offline" end
    local att = ns.RaidLog and ns.RaidLog.GetAttendance and ns.RaidLog:GetAttendance(e.key)
    if att then flags[#flags + 1] = "att " .. att .. "%" end
    GameTooltip:AddLine(table.concat(flags, " · "), 0.8, 0.8, 0.8)
    if e.wanted and e.wanted ~= chip.itemID then
        GameTooltip:AddLine("For " .. (itemName(e.wanted) or ("item " .. e.wanted)), 0.8, 0.8, 0.8)
    end
    local wear = not e.obtained and wearingLine(e)
    if wear then GameTooltip:AddLine(wear, 0.6, 0.6, 0.6) end
    if e.lockChanged or lockChangedAt(e.key) then
        if ns.UI and ns.UI.AddLockChangedLine then ns.UI:AddLockChangedLine(GameTooltip, lockChangedAt(e.key)) end
    end
    GameTooltip:AddLine("Click: show member", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

-- A wanter as the shared chip (UI:CreateChip: the class circle, the name, "alt" / "has it" after it, the lock
-- warning); a click shows the member.
local function newChip(row)
    local c = UI:CreateChip(row, { onClick = function(self)
        if self.entry and not self.rest then CouncilUI:ShowMember(self.entry.key) end
    end })
    c:HookScript("OnEnter", chipEnter)
    c:HookScript("OnLeave", V.hideTip)
    c.name = c.fs        -- (the chip's words: the name the 1.3 chip had as its own field)
    return c
end

-- A chip's words: the name, then "has it" / "alt", then the lock warning.
local function chipText(e)
    local t = coloredName(e.key, e.classFile)
    if e.obtained then
        t = t .. " " .. colorCode("obtained") .. "has it|r"
    elseif e.which == "alt" then
        t = t .. " " .. S:Wrap("DIM", "alt")
    end
    if e.lockChanged or lockChangedAt(e.key) then t = t .. " " .. UI:WarnIcon(12) end
    return t
end

-- (a chip's width: UI:CreateChip's insets around the class circle and the words)
local CHIP_IN = UI.CHIP_LOOK.track.x + 14 + 6 + UI.CHIP_LOOK.track.pad

-- The chips of a card: the mains, then the alt picks (the owners dimmed), on at most two lines; what doesn't fit
-- becomes a "+N" chip. Measured like the chip measures itself; returns the number of lines.
local function layoutChips(v, d)
    local people = uniqueWanters(d.wanters)
    local mains, alts = {}, {}
    for _, e in ipairs(people) do
        if e.which == "alt" then alts[#alts + 1] = e else mains[#mains + 1] = e end
    end
    for _, e in ipairs(alts) do mains[#mains + 1] = e end
    local chips, x, line = {}, 0, 1
    local function width(e)
        return math.floor(CHIP_IN + UI:TextWidth(chipText(e), "body") + 0.5)
    end
    local function moreWidth(n)
        return math.floor(UI.CHIP_LOOK.track.x + 3 + UI:TextWidth("+" .. n, "body") + UI.CHIP_LOOK.track.pad + 0.5)
    end
    for i, e in ipairs(mains) do
        local w = width(e)
        if x > 0 and x + w > CHIPS_W then
            line, x = line + 1, 0
        end
        local rest = #mains - i
        local needMore = rest > 0 and line == MAX_CHIP_LINES
        if line > MAX_CHIP_LINES or (needMore and x + w + K.CHIP_GAP + moreWidth(rest) > CHIPS_W) then
            -- no room: "+N" for this one and the rest (on the last line)
            if line > MAX_CHIP_LINES then line, x = MAX_CHIP_LINES, chips[#chips] and (chips[#chips].x + chips[#chips].w + K.CHIP_GAP) or 0 end
            local left = #mains - i + 1
            local mw = moreWidth(left)
            while #chips > 0 and chips[#chips].line == line and x + mw > CHIPS_W do
                local last = table.remove(chips)
                left = left + 1
                mw = moreWidth(left)
                x = last.x
            end
            local restList = {}
            for j = #mains - left + 1, #mains do restList[#restList + 1] = mains[j] end
            chips[#chips + 1] = { more = left, rest = restList, x = x, line = line, w = mw }
            break
        end
        chips[#chips + 1] = { entry = e, x = x, line = line, w = w }
        x = x + w + K.CHIP_GAP
    end
    d.chips = chips
    local lines = 1
    for _, c in ipairs(chips) do lines = math.max(lines, c.line) end
    return lines
end

local function setupItemRow(row)
    row.cdlInit = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- the shared card (its edge shows under the mouse and on the item a jump came for)
    row.card = UI:CreateCard(row, { tone = "card" })
    row.card:SetPoint("TOPLEFT", 0, 0)
    row.card:SetPoint("BOTTOMRIGHT", 0, GAP / 2)
    row.card:EnableMouse(false)
    UI:SetEdgeColor(row.card, 0, 0, 0, 0)
    row.tint = row.card:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.tint:SetAllPoints()
    row.tint:SetColorTexture(S:Color("SELECT"))

    row.btn = ns.UI:CreateItemButton(row, ICON)
    row.btn.onTooltip = function(btn, tt)
        local d = btn:GetParent().cdlData
        if d then addWantersTooltip(tt, d) end
    end
    row.btn.onClick = function(btn, mouseButton)
        itemRowClick(btn:GetParent(), mouseButton)
    end

    -- the right side of the first line: the slot, "Token" with its classes, or where the item comes from
    row.source = UI:Text(row.card, "small", "SUB", { justify = "RIGHT" })
    row.name = UI:Text(row.card, "emph")
    row.chips = {}

    -- the fold: a stack of the hidden items' icons, one line, a chevron
    row.stack = {}
    for i = 1, 5 do
        local t = row.card:CreateTexture(nil, "ARTWORK", nil, i)
        t:SetSize(16, 16)
        t:SetPoint("LEFT", row, "LEFT", CARD_PAD + (i - 1) * 12, 1)
        t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.stack[i] = t
    end
    row.foldText = UI:Text(row.card, "sub")
    row.chev = row.card:CreateTexture(nil, "ARTWORK")
    row.chev:SetSize(10, 10)
    row.chev:SetPoint("RIGHT", row, "RIGHT", -CARD_PAD, 1)
    row.chev:SetTexture(UI.ICON_ATLAS)
    row.chev:SetVertexColor(S:Color("SUB"))

    row:SetScript("OnClick", itemRowClick)
    row:SetScript("OnEnter", itemRowEnter)
    row:SetScript("OnLeave", itemRowLeave)
end

-- A class circle inside text.
local function classIconText(classFile, size)
    local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
    if not c then return "" end
    local function px(v) return math.floor(v * 256 + 0.5) end
    return ("|T%s:%d:%d:0:0:256:256:%d:%d:%d:%d|t"):format(ns.TEX.classIcons,
        size, size, px(c[1]), px(c[2]), px(c[3]), px(c[4]))
end

local function sourceText(d)
    if d.isToken then
        -- a tier token: who can use it, as class circles
        local classes = ns.ItemDB and ns.ItemDB.GetTokenClasses and ns.ItemDB:GetTokenClasses(d.itemID)
        local icons = {}
        for _, cl in ipairs(type(classes) == "table" and classes or {}) do icons[#icons + 1] = classIconText(cl, 13) end
        return #icons > 0 and ("Token  " .. table.concat(icons, " ")) or "Token"
    end
    local typeText = itemTypeText(d.itemID, false)
    if d.bossKey == "" then
        local src = ns.ItemDB and ns.ItemDB.GetSourceText and ns.ItemDB:GetSourceText(d.itemID, true)
        typeText = src or "No raid source"
    end
    return typeText
end

local function initItemRow(row, d)
    if not row.cdlInit then setupItemRow(row) end
    row.cdlData = d
    row.card:SetFrameLevel(row:GetFrameLevel())   -- under the icon and the chips (they sit one level up)
    local fold, quiet = d.type == "fold", d.quiet
    row.btn:SetShown(not fold)
    row.name:SetShown(not fold)
    row.source:SetShown(not fold)
    row.foldText:SetShown(fold)
    row.chev:SetShown(fold)
    for i, t in ipairs(row.stack) do t:SetShown(fold and d.items[i] ~= nil) end
    row.tint:SetShown(d.focus and true or false)
    if d.focus then
        UI:SetEdgeColor(row.card, S:Color("EDGE_FOCUS"))
    else
        UI:SetEdgeColor(row.card, 0, 0, 0, 0)
    end
    for _, c in ipairs(row.chips) do c:Hide() end
    row:SetAlpha(1)

    if fold then
        row.card.bg:SetColorTexture(S:Color("STRIPE"))
        for i, t in ipairs(row.stack) do
            if d.items[i] then
                t:SetTexture(UI:ItemIcon(d.items[i].itemID))
                t:SetAlpha(0.55)
            end
        end
        local n = #d.items
        row.foldText:ClearAllPoints()
        row.foldText:SetPoint("LEFT", row, "LEFT", CARD_PAD + (math.min(n, 5) - 1) * 12 + 16 + 10, 1)
        row.foldText:SetText(string.format("%d %s nobody has on a P%d list", n, n == 1 and "item" or "items",
            d.phase or currentPhase()))
        UI:SetChevronUp(row.chev, state.showUnwanted)
        return
    end

    row.card:SetTone("card")
    if not d.focus then UI:SetEdgeColor(row.card, 0, 0, 0, 0) end
    row.btn:SetItem(d.itemID)
    row.btn:SetState(nil)
    row.btn:SetBadge(nil)
    row.btn:ClearAllPoints()
    row.name:ClearAllPoints()
    row.source:ClearAllPoints()
    row.source:SetText(sourceText(d))
    if quiet then
        -- an item nobody wants: one quiet line
        row:SetAlpha(0.55)
        row.btn:SetSize(20, 20)
        row.btn:SetPoint("LEFT", row, "LEFT", CARD_PAD, GAP / 4)
        row.name:SetPoint("LEFT", row, "LEFT", CARD_PAD + 30, GAP / 4)
        row.source:SetPoint("RIGHT", row, "RIGHT", -CARD_PAD, GAP / 4)
    else
        row.btn:SetSize(ICON, ICON)
        row.btn:SetPoint("TOPLEFT", row, "TOPLEFT", CARD_PAD, -CARD_TOP)
        row.name:SetPoint("TOPLEFT", row, "TOPLEFT", TEXT_X, -CARD_TOP - 1)
        row.source:SetPoint("TOPRIGHT", row, "TOPRIGHT", -CARD_PAD, -CARD_TOP - 2)
    end
    row.name:SetPoint("RIGHT", row.source, "LEFT", -10, 0)
    row.name:SetText(itemText(d.itemID))
    if quiet then return end

    for i, spec in ipairs(d.chips or {}) do
        local c = row.chips[i] or newChip(row)
        row.chips[i] = c
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", row, "TOPLEFT", TEXT_X + spec.x, -CHIPS_Y - (spec.line - 1) * (K.CHIP_H + K.CHIP_GAP))
        c:SetWidth(spec.w)
        c.itemID = d.itemID
        c.rest = spec.rest
        c.entry = spec.entry or (spec.rest and spec.rest[1])
        c:SetAlpha(1)
        if spec.more then
            c:Set(S:Wrap("DIM", "+" .. spec.more))
        else
            local e = spec.entry
            c:Set(chipText(e), nil, e.key)
            -- (the class we know from the list, also for players the guild roster doesn't have)
            if e.classFile then UI:ClassIcon(c.cls, e.classFile) end
            if e.obtained then c:SetAlpha(0.55) end
        end
        c:SetWidth(spec.w)
        c:Show()
    end
end

local function itemExtent(d)
    return d.extent or 60
end

-- The List + detail of the layout: the tree in its list column; the chosen boss's banner (its raid's art) heads the
-- detail, the cards fill the detail's body (CouncilUI:Refresh shows the list and the detail with the view).
local function createItemsView(parent)
    local L = parent.layout
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints(L.content)

    v.tree = V.barInMargin(UI:CreateScrollList(L.list, TREE_ROW_H, initTreeRow, treeExtent))
    v.tree.frame:ClearAllPoints()
    v.tree.frame:SetPoint("TOPLEFT", L.list, "TOPLEFT", 0, 0)
    v.tree.frame:SetPoint("BOTTOMRIGHT", L.list, "BOTTOMRIGHT", 0, 0)

    v.banner = L.banner
    v.title = L.banner.title

    v.list = V.barInMargin(UI:CreateScrollList(L.body, 60, initItemRow, itemExtent))
    v.list.frame:ClearAllPoints()
    v.list.frame:SetPoint("TOPLEFT", L.body, "TOPLEFT", 0, 0)
    v.list.frame:SetPoint("BOTTOMRIGHT", L.body, "BOTTOMRIGHT", 0, 0)
    return v
end

local function nodeExists(tree, key)
    for _, r in ipairs(tree) do
        if r.key == key then return true end
    end
    return false
end

-- The cards in order: the wanted items (most wanted first), the fold, the unwanted ones while unfolded.
local function cardRows(v, rows, phase)
    local wanted, unwanted, focusHidden = {}, {}, false
    for _, r in ipairs(rows) do
        if r.n > 0 then
            wanted[#wanted + 1] = r
        else
            r.quiet = true
            r.extent = K.QUIET_H
            unwanted[#unwanted + 1] = r
            if r.focus then focusHidden = true end
        end
    end
    for _, r in ipairs(wanted) do
        local lines = layoutChips(v, r)
        r.extent = CHIPS_Y + lines * K.CHIP_H + (lines - 1) * K.CHIP_GAP + 8 + GAP / 2
    end
    if #unwanted == 0 then return wanted end
    -- a search shows its matches; a jump to one of these items unfolds them
    local open = state.showUnwanted or focusHidden or state.search ~= ""
    local out = wanted
    if #wanted > 0 then
        out[#out + 1] = { type = "fold", n = 0, wanters = {}, items = unwanted, phase = phase,
                          extent = K.FOLD_H + GAP / 2 }
    end
    if open or #wanted == 0 then
        for _, r in ipairs(unwanted) do out[#out + 1] = r end
    end
    return out
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

    -- Only the chosen boss's raid lists its bosses.
    local openRaid
    for _, r in ipairs(tree) do
        if r.type == "boss" and r.key == state.selectedNode then openRaid = r.raidKey end
    end
    local shown = {}
    for _, r in ipairs(tree) do
        if r.type == "raid" then r.open = (r.raidKey == openRaid) end
        if r.type ~= "boss" or r.raidKey == openRaid then shown[#shown + 1] = r end
    end
    if shown[1] then shown[1].first = true end
    setListData(v.tree, shown, resetScroll and not keepTreeScroll)

    local rows = cardRows(v, buildItemRows(phase, state.selectedNode, other), phase)
    setListData(v.list, rows, resetScroll or keepTreeScroll)

    -- the detail's banner: the boss on its raid's art, the raid and how many of its items someone wants
    local ref = state.selectedNode ~= OTHER_NODE and ns.ItemDB.GetBossRef and ns.ItemDB:GetBossRef(state.selectedNode)
    local wantedN = 0
    for _, r in ipairs(rows) do
        if (r.n or 0) > 0 then wantedN = wantedN + 1 end
    end
    local sub = string.format("%d %s wanted in P%d", wantedN, wantedN == 1 and "item" or "items", phase)
    if state.selectedNode == OTHER_NODE then
        v.banner:SetArt(nil)
        v.banner:SetTitle("Other / no raid source")
    else
        v.banner:SetArt(ref and ref.raid and ref.raid.key or nil)
        v.banner:SetTitle(bossName(state.selectedNode) or "Select a boss")
        if ref and ref.raid and ref.raid.name then sub = ref.raid.name .. "  \194\183  " .. sub end
    end
    v.banner:SetSub(sub)

    -- nothing to list: the illustrated empty state
    local emptyTitle
    if #tree == 0 then
        emptyTitle = "No raids or wanted items for this phase."
    elseif state.search ~= "" then
        emptyTitle = "No items match the search."
    else
        emptyTitle = "No items to show for this boss."
    end
    v.list:SetEmptyState({ icon = UI.ICON.notes, title = emptyTitle })
    v.empty = v.list.emptyState

    if state.scrollToFocus then
        state.scrollToFocus = false
        local node = state.selectedNode
        scrollListTo(v.tree, function(d) return d.key == node end)
        scrollListTo(v.list, function(d) return d.focus end)
    end
end

return { create = createItemsView, refresh = refreshItems }
end)()

----------------------------------------------------------------------------
-- Member view: one member's page, opened from a name (Roster, an Items chip, the Loot log) with a way back like
-- a raid page; their BiS list on the read-only paper doll, the summary, model and recent awards in its centre.
----------------------------------------------------------------------------

local Member = (function()
local PAD = K.PAD
local AWARDS, AWARD_PITCH = 3, 30     -- the recent awards in the doll's centre: item, then why / when

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

-- The banner's tools: the next / previous member of the list it came from (chevrons), "3 / 19" beside them.
local function setPager(v, shown)
    local ban = v.banner
    if not shown then
        ban:SetTools(nil)
        v.prevBtn, v.nextBtn = nil, nil
        v.pos:Hide()
        return
    end
    ban:SetTools({ { icon = "chevron", title = "Next member", onClick = function() stepMember(1) end },
                   { icon = "chevron", title = "Previous member", onClick = function() stepMember(-1) end } })
    v.nextBtn, v.prevBtn = ban.tools[1], ban.tools[2]
    UI:SetChevron(v.nextBtn.icon, true)
    UI:SetChevron(v.prevBtn.icon, false)
    v.pos:ClearAllPoints()
    v.pos:SetPoint("RIGHT", v.prevBtn, "LEFT", -8, 0)
    v.pos:Show()
end

-- The "changed during lock" pill's tooltip (the banner's pill, §38).
local function lockTip(pill, tt)
    local v = pill.view
    if not (v and v.lockKey) then return false end
    tt:AddLine(coloredName(v.lockKey))
    UI:AddLockChangedLine(tt, v.lockTs, "Their picks differ from the snapshot taken when the "
        .. "lists were locked. They are not suggested as a roll winner; the council can still award.")
end

-- The doll object may be a frame itself or a table holding one.
local function dollFrame(doll)
    if type(doll) ~= "table" then return nil end
    if doll.GetObjectType then return doll end
    if type(doll.frame) == "table" and doll.frame.GetObjectType then return doll.frame end
    return nil
end

-- The member page: the detail page's banner (the way back to the view it came from, the class, the name with the
-- "changed during lock" pill, one line about them, the previous / next member as its tools), the read-only paper
-- doll under it.
local function createMemberView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints(parent.layout.content)

    v.banner = UI:CreatePageBanner(v, { size = "tool", width = K.W,
        back = { text = K.VIEW_LABEL.roster, onClick = function() CouncilUI:SetView(state.backView or "roster") end } })
    v.banner:SetPoint("TOPLEFT", v, "TOPLEFT", 0, 0)
    v.banner:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, 0)
    v.back = v.banner.back
    v.name = v.banner.title
    v.info = v.banner.sub
    v.pos = UI:Text(v.banner, "small", "SUB", { justify = "RIGHT" })
    v.pos:Hide()

    -- §38: "changed during lock" as the title's pill (hover for details)
    v.lockFlag = v.banner.pill
    v.lockFlag.text = v.banner.pill.fs
    v.lockFlag.view = v
    UI:AttachTooltip(v.lockFlag, lockTip, nil, { anchor = "ANCHOR_BOTTOM" })

    -- the doll's default layout puts its tiles 8 inside its frame: they line up with the page's margin
    v.dollHolder = CreateFrame("Frame", nil, v)
    v.dollHolder:SetPoint("TOPLEFT", v.banner, "BOTTOMLEFT", -8, -S.GAP)
    v.dollHolder:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", 8, 0)

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
    local c = { host = host }
    c.summary = UI:Text(host, "emph", "TEXT", { justify = "CENTER", wrap = true })
    if host == v.dollHolder then
        c.summary:SetPoint("TOP", 0, -8)
        c.summary:SetWidth(260)
    else
        c.summary:SetPoint("TOPLEFT", 4, -4)
        c.summary:SetPoint("TOPRIGHT", -4, -4)
    end

    -- recent awards along the bottom (icon + item; under it, grey: why, when), the model between
    c.lines, c.metas, c.icons = {}, {}, {}
    for i = 1, AWARDS do
        local y = 4 + (AWARDS - i) * AWARD_PITCH
        local icon = host:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 18)
        icon:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, y + 4)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        local meta = UI:Text(host, "small", "SUB")
        meta:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 24, y)
        meta:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, y)
        local fs = UI:Text(host, "body")
        fs:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 24, y + 13)
        fs:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, y + 13)
        c.lines[i], c.metas[i], c.icons[i] = fs, meta, icon
        fs.y = y
    end
    c.title = UI:Text(host, "caps", "SUB", { text = "Recent awards" })
    c.title:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 4 + AWARDS * AWARD_PITCH + 4)
    c.title:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 4 + AWARDS * AWARD_PITCH + 4)

    if ns.UI and ns.UI.CreateBiSModel then
        c.model = ns.UI:CreateBiSModel(host)
        c.model:SetPoint("TOPLEFT", c.summary, "BOTTOMLEFT", 0, -4)
        c.model:SetPoint("BOTTOMRIGHT", c.title, "TOPRIGHT", 0, 4)
        c.model:SetScript("OnShow", function() if v.redress then v.redress() end end)
        c.noModel = UI:Text(host, "small", "DIM", { justify = "CENTER", wrap = true })
        c.noModel:SetPoint("CENTER", c.model, "CENTER", 0, 0)
        c.noModel:SetPoint("LEFT", c.model, "LEFT", 10, 0)
        c.noModel:SetPoint("RIGHT", c.model, "RIGHT", -10, 0)
    end
    v.centerParts = c

    -- nobody picked: the illustrated empty state under the banner
    v.empty = UI:CreateEmptyState(v, { icon = UI.ICON.notes, title = "No member selected",
        text = "Pick someone in the Roster." })
    v.empty:SetPoint("TOP", v.banner, "BOTTOM", 0, -60)
    v.empty:Hide()

    if not v.doll then
        v.noDoll = UI:Text(v.dollHolder, "body", "DIM", { text = "Paper doll unavailable." })
        v.noDoll:SetPoint("BOTTOM", 0, 20)
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
        local text = "list updated " .. formatAgo(ts)
        if ts > 0 and GetServerTime() - ts > STALE_SECONDS then
            text = colorCode("warn") .. text .. "|r"
        end
        parts[#parts + 1] = text
    else
        parts[#parts + 1] = "no list received"
    end
    -- their DisasterZone only when it is not the one I run (that is when it matters)
    local isMe = ns.Util and ns.Util.IsMe and ns.Util.IsMe(key)
    local peer = not isMe and ns.Sync and ns.Sync.GetPeer and ns.Sync:GetPeer(key)
    if type(peer) == "table" and peer.v and tostring(peer.v) ~= tostring(ns.version) then
        parts[#parts + 1] = colorCode("warn") .. "DisasterZone " .. tostring(peer.v) .. "|r"
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
        if disabled > 0 then text = text .. S:Wrap("DIM", string.format(" · %d disabled", disabled)) end
        c.summary:SetText(text)
    else
        c.summary:SetText(S:Wrap("DIM", "No BiS list received yet."))
    end

    local entries = ns.Ledger and ns.Ledger.GetVisibleEntries and ns.Ledger:GetVisibleEntries({ player = key }) or {}
    local shown = 0
    for _, e in ipairs(entries) do
        if shown >= AWARDS then break end
        if type(e) == "table" and tonumber(e.i) and not e.vd then
            shown = shown + 1
            c.icons[shown]:SetTexture(UI:ItemIcon(e.i))
            c.icons[shown]:Show()
            c.lines[shown]:SetPoint("BOTTOMLEFT", c.host, "BOTTOMLEFT", 24, c.lines[shown].y + 13)
            c.lines[shown]:SetText(itemText(e.i))
            local label = ns.ReasonLabel and ns.ReasonLabel(e.r)
            c.metas[shown]:SetText((label and (label .. " · ") or "") .. formatAgo(e.ts))
            c.lines[shown]:Show()
            c.metas[shown]:Show()
        end
    end
    if shown == 0 then
        c.lines[1]:SetPoint("BOTTOMLEFT", c.host, "BOTTOMLEFT", 0, c.lines[1].y + 13)
        c.lines[1]:SetText(S:Wrap("DIM", "None yet"))
        c.lines[1]:Show()
        c.metas[1]:Hide()
        c.icons[1]:Hide()
        shown = 1
    end
    for i = shown + 1, AWARDS do
        c.lines[i]:SetText("")
        c.lines[i]:Hide()
        c.metas[i]:Hide()
        c.icons[i]:Hide()
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
    c.noModel:SetText(shown and "" or (shortName(key) .. "'s model shows when nearby."))
end

local function refreshMember(phase)
    local v = panel.memberView
    local key = state.memberKey
    local n = #order
    local idx = key and indexOf(order, key)
    local ban = v.banner
    ban:SetBack(K.VIEW_LABEL[state.backView or "roster"] or "Roster",
        function() CouncilUI:SetView(state.backView or "roster") end)
    v.pos:SetText(n > 0 and string.format("%s / %d", idx and tostring(idx) or "-", n) or "")
    setPager(v, n > 1)

    if not key then
        ban:SetIcon(nil)
        ban:SetTitle("")
        ban:SetSub("")
        ban:SetPill(nil, nil)
        v.dollHolder:Hide()
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

    -- the class as the banner's icon (a grey disc while it is unknown)
    local tc = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
    ban:SetIcon(tc and { ns.TEX.classIcons, tc[1], tc[2], tc[3], tc[4] } or { K.DISC, 0, 1, 0, 1 })
    ban:SetTitle(coloredName(key, classFile))
    ban:SetSub(memberHeaderInfo(key, rec, data, classFile))
    local changedAt = lockChangedAt(key)
    v.lockKey, v.lockTs = key, changedAt
    if changedAt ~= nil then
        ban:SetPill("warn", UI:WarnIcon(12) .. " changed during lock")
    else
        ban:SetPill(nil, nil)
    end

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
            -- the member's gems and enchants (read-only; ring enchants count when they have Enchanting)
            gems = true,
            gemProfs = ns.Gems and ns.Gems:ProfessionSet(key) or nil,
        }
        v.doll:Update(shownRecord, phase, ctx)
    end
    refreshMemberCenter(v, key, data, phase, rec)
    v.redress = function() dressMember(v, key, data, phase, rec) end
    v.redress()
end

return { create = createMemberView, refresh = refreshMember }
end)()

----------------------------------------------------------------------------
-- Loot Council view (ADDENDUM E §29/§30): who is on the council, plus the pickers for the guild
-- council (Guild Master) and this raid's council (raid leader). Read-only for everyone else.
-- Every ns.Guild council call is guarded: an older core simply shows nothing to edit.
----------------------------------------------------------------------------

local MAX_COUNCIL_NAMES = 40         -- CG / CR carry at most 40 names (§31)
local COUNCIL_KINDS = { "guild", "raid" }

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
    if type(key) ~= "string" then return S:Wrap("DIM", "?") end
    return coloredName(key, councilClass(key))
end

-- Online per the guild roster, else per the raid roster (a raid list may name a pug, who never counts: 1.3).
local function councilOnline(key)
    if isOnline(key) then return true end
    local e = groupEntry(key)
    return (e and e.online) and true or false
end

local function rankNote(key)
    if realGuildMember(key) then
        return ns.Guild.GetRankName and ns.Guild:GetRankName(key) or ""
    end
    return groupEntry(key) and "not in your guild: never council" or ""
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

-- Items of the raid picker: my raid first, then online guild members. The raid leader is fixed. (1.3: guild members
-- only: a pug on the list would never be council.)
local function raidPickerItems()
    local out, seen = {}, {}
    local leader = raidLeaderKey()
    local raidKeys = {}
    local g = ns.Util and ns.Util.group
    if inRaid() and type(g) == "table" then
        for key in pairs(g) do
            if realGuildMember(key) then raidKeys[#raidKeys + 1] = key end
        end
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


-- The two cards (guild council, this raid's council) ---------------------------------------------------------------

local CouncilView = (function()
local PAD, GAP, IN = K.PAD, K.GAP, K.IN
local COL_W = (K.W - GAP) / 2         -- 381
local INNER_W = COL_W - 2 * IN
local ROW_H = S.ROW.compact
local LABEL_W = 92
local CTRL_W = INNER_W - LABEL_W
local SHORT_H = IN + 16 + 6 + 14 + IN   -- the card when there is nothing to show: title + one line
local FULL_H = S.PAGE_H + K.TOP_Y - PAD      -- the tallest a card gets (its list scrolls then)

-- A council row's tooltip (UI:AttachTooltip's title function).
local function councilRowTip(row, tt)
    local d = row.cdlData
    if not d then return false end
    tt:AddLine(councilName(d.key))
    local note = rankNote(d.key)
    if note ~= "" then tt:AddLine(note, 0.8, 0.8, 0.8) end
    tt:AddLine(councilOnline(d.key) and "Online" or "Offline", 0.6, 0.6, 0.6)
    if d.fixed then
        tt:AddLine(d.fixed .. ": always on the council", 0.6, 0.6, 0.6, true)
    elseif d.isNew then
        tt:AddLine("Added, not saved yet", color("warn"))
    end
end

local function initCouncilRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        UI:DecorateRow(row, { hover = true })
        row.circle = V.classCircle(row, 16, 6)
        row.circle:SetPoint("LEFT", row, "LEFT", 2, 0)
        row.remove = ns.UI:CreateRemoveButton(row, "Remove from the list")
        row.remove.tipText = "Save & share to apply the change."
        row.remove:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.remove:SetScript("OnClick", function(btn)
            local data = btn:GetParent().cdlData
            if data and data.removable then CouncilUI:ToggleCouncilDraft(data.kind, data.key) end
        end)
        row.note = UI:Text(row, "small", "SUB", { justify = "RIGHT" })
        row.name = UI:Text(row, "emph")
        row.name:SetPoint("LEFT", row, "LEFT", 26, 0)
        row.name:SetPoint("RIGHT", row.note, "LEFT", -8, 0)
        UI:AttachTooltip(row, councilRowTip)
    end
    row.cdlData = d
    row.circle:Set(councilClass(d.key), councilOnline(d.key) and "raid" or "offline")
    row.name:SetText(councilName(d.key))
    row.remove:SetShown(d.removable and true or false)
    row.note:ClearAllPoints()
    row.note:SetPoint("RIGHT", row, "RIGHT", d.inEditor and -26 or -2, 0)   -- (the bins' column while editing)
    if d.fixed then
        row.note:SetText(d.fixed)
    elseif d.isNew then
        row.note:SetText(colorCode("warn") .. "not saved|r")
    else
        row.note:SetText(d.note or "")
    end
end

local function label(s, text)
    return UI:Text(s, "sub", nil, { text = text })
end

-- One council as the shared card: its title (what the list is in the title's tooltip), its state at the right, the
-- picker and settings while editing, the list of names, one quiet line on why it is read-only.
local function createCouncilSection(parent, kind)
    local s = UI:CreateCard(parent, { tone = "card", pad = IN, title = " " })
    s.kind = kind
    local isGuild = kind == "guild"

    s.title:ClearAllPoints()
    s.title:SetPoint("TOPLEFT", IN, -IN)
    -- what the list is: the title's tooltip
    s.titleTip = CreateFrame("Frame", nil, s)
    s.titleTip:SetPoint("TOPLEFT", s.title, "TOPLEFT", -2, 2)
    s.titleTip:SetPoint("BOTTOMRIGHT", s.title, "BOTTOMRIGHT", 2, -2)
    UI:AttachTooltip(s.titleTip, function(_, tt)
        tt:AddLine(s.title:GetText() or "", S:Color("GOLD"))
        if s.sub then tt:AddLine(s.sub, 1, 1, 1, true) end
    end, nil, { anchor = "ANCHOR_TOP" })
    s.status = UI:Text(s, "body", "TEXT", { justify = "RIGHT" })
    s.status:SetPoint("TOPRIGHT", -IN, -IN - 2)
    -- one quiet line: why it is read-only, or (the short card) the state
    s.foot = UI:Text(s, "sub", nil, { wrap = true, width = INNER_W })

    s.picker = ns.UI:CreateSearchDropdown(s, INNER_W, {
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
    s.picker.frame:SetPoint("TOPLEFT", s, "TOPLEFT", IN, -40)

    if isGuild then
        s.phaseLabel = label(s, "Guild phase")
        s.phaseDD = ns.UI:CreateDropdown(s, CTRL_W, councilPhaseOptions,
            function() return getDraft("guild").phase end,
            function(value) CouncilUI:SetCouncilDraftPhase(value) end)
    end

    -- ADDENDUM G §41: the disenchanter / guild bank character (part of the draft; Save & share sends them).
    local function targetButton(field)
        local b = UI:CreateSleekMenuButton(s, "", CTRL_W, function() end)
        b:SetScript("OnClick", function(self) CouncilUI:OpenTargetMenu(kind, field, self) end)
        UI:AttachTooltip(b, field == "de" and "Disenchanter" or "Guild bank character", {
            (field == "de" and "The drop panel's DE button gives items to this character, recorded as Disenchant."
                or "The drop panel's Bank button gives items to this character, recorded as Guild bank.")
                .. " Such awards don't count as loot received.",
            { isGuild and "Applies to every raid unless the raid leader picks one for their raid."
                or "Replaces the guild's pick in the raids you lead.", 0.7, 0.7, 0.7, wrap = true },
            { "Save & share to apply the change.", 0.7, 0.7, 0.7, wrap = true },
        }, { anchor = "ANCHOR_TOP" })
        return b
    end
    s.deLabel = label(s, "Disenchanter")
    s.deBtn = targetButton("de")
    s.bankLabel = label(s, "Guild bank")
    s.bankBtn = targetButton("bank")
    -- read-only: the two picks as one line
    s.targets = UI:Text(s, "body", "TEXT", { width = INNER_W })

    s.listLabel = UI:Text(s, "caps", "SUB", { text = "On the council" })
    -- Clear list: a quiet text link on the list's label row (the rows have the bins)
    s.clear = CreateFrame("Button", nil, s)
    s.clear:SetHeight(18)
    s.clear.text = UI:Text(s.clear, "body", "SUB", { text = "Clear list" })
    s.clear.text:SetPoint("RIGHT", 0, 0)
    s.clear:SetWidth(math.floor((s.clear.text:GetStringWidth() or 50) + 4))
    s.clear:SetScript("OnClick", function() CouncilUI:ConfirmClearCouncil(kind) end)
    s.clear:SetScript("OnEnter", function(self) self.text:SetTextColor(S:Color("GOLD")) end)
    s.clear:SetScript("OnLeave", function(self) self.text:SetTextColor(S:Color("SUB")) end)
    V.tip(s.clear, "Clear list", isGuild
        and "Removes everyone from the guild council list (asks first). The Guild Master stays council."
        or "Removes everyone from your raid council list (asks first). As raid leader you stay council.")
    s.list = V.barInMargin(UI:CreateScrollList(s, ROW_H, initCouncilRow))

    s.save = UI:CreateSleekButton(s, "Save & share", 112, S.BTN_H, function() CouncilUI:SaveCouncil(kind) end, "primary")
    V.tip(s.save, "Save & share", isGuild
        and "Saves the guild council and sends it to every online guild member. Members who log in later get it too."
        or "Saves your raid council list. It is sent to your raid now if you lead it, and again whenever you lead a raid.")
    s.save:SetPoint("TOPRIGHT", s, "TOPRIGHT", -IN, -S.IN)
    s.revert = UI:CreateSleekButton(s, "Revert", 72, S.BTN_H, function() CouncilUI:RevertCouncil(kind) end)
    V.tip(s.revert, "Revert", "Discard your unsaved changes.")
    s.revert:SetPoint("RIGHT", s.save, "LEFT", -6, 0)
    return s
end

-- Places a section's parts: "edit" (the picker, its settings, the list, Save / Revert), "read" (the picks as a
-- line, the list, why it's read-only) or "short" (title + one line: nothing to list).
local function layoutSection(s, mode)
    local edit, read, short = mode == "edit", mode == "read", mode == "short"
    s.editable = edit
    s.picker.frame:SetShown(edit)
    if s.phaseDD then
        s.phaseDD:SetShown(edit)
        s.phaseLabel:SetShown(edit)
    end
    for _, w in ipairs({ s.deBtn, s.bankBtn, s.deLabel, s.bankLabel }) do w:SetShown(edit) end
    s.targets:SetShown(read)
    s.listLabel:SetShown(not short)
    s.list.frame:SetShown(not short)
    s.foot:SetShown(not edit)
    s.foot:ClearAllPoints()
    if short then
        s.foot:SetPoint("TOPLEFT", s, "TOPLEFT", IN, -IN - 22)
        s.clear:Hide()
        return 0, 0
    end
    local y
    if edit then
        y = -74
        local rows = s.phaseDD and { { s.phaseLabel, s.phaseDD }, { s.deLabel, s.deBtn }, { s.bankLabel, s.bankBtn } }
            or { { s.deLabel, s.deBtn }, { s.bankLabel, s.bankBtn } }
        for _, r in ipairs(rows) do
            r[2]:ClearAllPoints()
            r[2]:SetPoint("TOPLEFT", s, "TOPLEFT", IN + LABEL_W, y)
            r[1]:ClearAllPoints()
            r[1]:SetPoint("LEFT", s, "TOPLEFT", IN, y - 11)
            y = y - 28
        end
        y = y - 10
    else
        s.targets:ClearAllPoints()
        s.targets:SetPoint("TOPLEFT", s, "TOPLEFT", IN, -40)
        y = -66
        s.foot:SetPoint("BOTTOMLEFT", s, "BOTTOMLEFT", IN, IN)
    end
    s.listLabel:ClearAllPoints()
    s.listLabel:SetPoint("TOPLEFT", s, "TOPLEFT", IN, y)
    s.clear:ClearAllPoints()
    s.clear:SetPoint("RIGHT", s, "TOPRIGHT", -IN, y - 5)
    local bottom = edit and (IN - 4) or (IN + 22)
    s.list.frame:ClearAllPoints()
    s.list.frame:SetPoint("TOPLEFT", s, "TOPLEFT", IN - 2, y - 18)
    s.list.frame:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", -IN + 2, bottom)
    return -(y - 18), bottom
end

-- The card is as tall as what it lists (at most the page; the list scrolls then).
local function sizeCard(s, top, bottom, n)
    if top == 0 then
        s.cardH = SHORT_H
    else
        s.cardH = math.min(FULL_H, top + math.max(n, 1) * ROW_H + bottom)
    end
end

-- Rows of the draft: the fixed member (GM / raid leader) first, then the picked names.
local function draftRows(kind, fixedKey, fixedText)
    local rows = {}
    if fixedKey then rows[1] = { kind = kind, key = fixedKey, fixed = fixedText, inEditor = true } end
    local saved = savedList(kind)
    local savedSet = copySet(saved and saved.members)
    for _, key in ipairs(sortedSet(getDraft(kind).members)) do
        if key ~= fixedKey then
            rows[#rows + 1] = { kind = kind, key = key, removable = true, isNew = not savedSet[key], note = rankNote(key),
                                inEditor = true }
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

-- 1.3: the master looter is council of the raid while it runs the loot council (Guild source "ml"): listed after the
-- raid leader, not removable.
local function addMasterLooterRow(rows)
    local ml = guildCall("GetRaidMasterLooter")
    if not ml or guildCall("GetCouncilSource", ml) ~= "ml" then return rows end
    for _, r in ipairs(rows) do
        if r.key == ml then return rows end
    end
    table.insert(rows, math.min(2, #rows + 1), { kind = "raid", key = ml, note = "master looter",
                                                 inEditor = rows[1] and rows[1].inEditor })
    return rows
end

-- The editor's state, short (the list shows who is on it).
local function editorStatus(kind, saved)
    if draftDirty(kind) then
        return colorCode("warn") .. "Unsaved changes|r"
    end
    if not saved then
        return S:Wrap("DIM", kind == "guild" and "Not shared yet" or "Not saved yet")
    end
    local ago = formatAgo(saved.rev)
    if kind == "guild" then
        return S:Wrap("DIM", "Shared " .. ago)
    end
    if amRaidLeader() then
        return S:Wrap("DIM", "Shared with this raid")
    end
    return S:Wrap("DIM", "Saved " .. ago)
end

-- ADDENDUM G §41: the loot targets of a section (pickers while editing, one line otherwise).
local function targetName(key)
    return key and councilName(key) or S:Wrap("DIM", "none")
end

local function paintTargetButtons(s, d)
    s.deBtn:SetText(targetName(d.de))
    s.bankBtn:SetText(targetName(d.bank))
end

local function targetsLine(t, emptyText)
    local de, bank = savedTarget(t, "de"), savedTarget(t, "bank")
    if not de and not bank then return S:Wrap("DIM", emptyText) end
    return S:Wrap("DIM", "Disenchanter ") .. targetName(de) .. S:Wrap("DIM", "   Guild bank ") .. targetName(bank)
end

local function refreshGuildSection(s)
    local inGuild = IsInGuild and IsInGuild()
    local editable = inGuild and canEditGuildCouncil() or false
    s:SetTitle("Guild council")
    s.sub = "Everyone in the guild. Kept until the Guild Master changes it."
    local saved = savedList("guild")
    local gm = guildCall("GetGM")
    local rows
    local top, bottom
    if not inGuild then
        top, bottom = layoutSection(s, "short")
        rows = {}
        s.status:SetText("")
        s.foot:SetText("You are not in a guild.")
    elseif editable then
        top, bottom = layoutSection(s, "edit")
        rows = draftRows("guild", gm, "Guild Master")
        local d = getDraft("guild")
        local n = countSet(d.members) - ((gm and d.members[gm]) and 1 or 0)
        local dirty = draftDirty("guild")
        s.status:SetText(editorStatus("guild", saved))
        s.status:SetShown(not dirty)
        s.save:SetShown(dirty)
        s.save:SetEnabled(dirty)
        s.revert:SetShown(dirty)
        s.revert:SetEnabled(dirty)
        s.clear:SetShown(countSet(copySet(saved and saved.members)) > 0 or n > 0)
        s.phaseDD:Refresh()
        paintTargetButtons(s, d)
        s.list:SetEmptyText("")
    else
        top, bottom = layoutSection(s, "read")
        s.save:Hide()
        s.revert:Hide()
        s.clear:Hide()
        s.status:Show()
        s.targets:SetText(targetsLine(saved, "No disenchanter or guild bank character."))
        rows = sharedRows("guild", gm, "Guild Master", saved and saved.members)
        if saved then
            local by = type(saved.by) == "string" and saved.by or gm
            s.status:SetText(S:Wrap("DIM", "Set by ") .. councilName(by) .. S:Wrap("DIM", " " .. formatAgo(saved.rev) .. " · P"
                .. savedPhase(saved)))
        else
            s.status:SetText(S:Wrap("DIM", "Only the Guild Master so far"))
        end
        s.foot:SetText("Only the Guild Master can change this list.")
        s.list:SetEmptyText(gm and "" or "Waiting for the guild roster...")
    end
    s.list:SetData(rows)
    sizeCard(s, top, bottom, #rows)
    if s.picker:IsOpen() then s.picker:Refresh(true) end
end

local function refreshRaidSection(s)
    local leading = amRaidLeader()
    local editable = canEditRaidCouncil()
    local rows, top, bottom
    s.save:Hide()
    s.revert:Hide()
    s.clear:Hide()
    s.status:Show()
    if editable then
        top, bottom = layoutSection(s, "edit")
        local me = playerKey()
        local fixedKey = leading and me or nil
        rows = draftRows("raid", fixedKey, "Raid leader")
        local d = getDraft("raid")
        local n = countSet(d.members) - ((fixedKey and d.members[fixedKey]) and 1 or 0)
        local dirty = draftDirty("raid")
        local saved = savedList("raid")
        if leading then
            s:SetTitle("This raid's council")
            s.sub = "Guild members in your raid only. You lead it, so you are always council."
            addMasterLooterRow(rows)
        else
            s:SetTitle("Your raid council")
            s.sub = "Shared automatically whenever you lead a raid."
        end
        s.status:SetText(editorStatus("raid", saved))
        s.status:SetShown(not dirty)
        s.save:SetShown(dirty)
        s.save:SetEnabled(dirty)
        s.revert:SetShown(dirty)
        s.revert:SetEnabled(dirty)
        s.clear:SetShown(countSet(copySet(saved and saved.members)) > 0 or n > 0)
        paintTargetButtons(s, d)
        s.list:SetEmptyText(#rows <= (fixedKey and 1 or 0) and "Nobody picked yet: use the search above." or "")
    else
        s:SetTitle("This raid's council")
        s.sub = "Guild members in your current raid only. The raid leader is always council."
        s.save:SetEnabled(false)
        s.revert:SetEnabled(false)
        if not inRaid() then
            top, bottom = layoutSection(s, "short")
            rows = {}
            s.status:SetText("")
            s.foot:SetText("Not in a raid. Lead one to pick its council.")
            s.list:SetEmptyText("")
        elseif raidLeaderKey() and not realGuildMember(raidLeaderKey()) then
            -- 1.3: pugs are never loot council (not as raid leader either), and their raid list is ignored
            top, bottom = layoutSection(s, "read")
            rows = addMasterLooterRow({})
            s.targets:SetText(targetsLine(nil, "Disenchanter and guild bank: the guild's picks."))
            s.status:SetText(S:Wrap("DIM", "Led by a guest"))
            s.foot:SetText("Players outside your guild are never loot council.")
            s.list:SetEmptyText("")
        else
            top, bottom = layoutSection(s, "read")
            local leader = raidLeaderKey()
            local rc = guildCall("GetRaidCouncil")
            if type(rc) ~= "table" or (leader and rc.leader and rc.leader ~= leader) then rc = nil end
            s.targets:SetText(targetsLine(rc, "Disenchanter and guild bank: the guild's picks."))
            rows = sharedRows("raid", leader, "Raid leader", rc and rc.members)
            addMasterLooterRow(rows)
            if rc then
                s.status:SetText(S:Wrap("DIM", "Set by ") .. councilName(rc.leader or leader))
            elseif leader then
                s.status:SetText(S:Wrap("DIM", "None picked by the raid leader"))
            else
                s.status:SetText(S:Wrap("DIM", "Waiting for the raid roster..."))
            end
            s.foot:SetText("Only the raid leader can change this list.")
            s.list:SetEmptyText("")
        end
    end
    s.list:SetData(rows)
    sizeCard(s, top, bottom, #rows)
    if s.picker:IsOpen() then s.picker:Refresh(true) end
end

-- The two cards side by side in the layout's content.
local function createCouncilView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints(parent.layout.content)
    v.guild = createCouncilSection(v, "guild")
    v.raid = createCouncilSection(v, "raid")
    return v
end

local function fitCard(v, s, side)
    s:ClearAllPoints()
    s:SetPoint("TOP" .. side, v, "TOP" .. side, 0, 0)
    s:SetSize(COL_W, s.cardH or SHORT_H)
end

local function refreshCouncilView()
    local v = panel and panel.councilView
    if not v then return end
    refreshGuildSection(v.guild)
    refreshRaidSection(v.raid)
    fitCard(v, v.guild, "LEFT")
    fitCard(v, v.raid, "RIGHT")
end

return { create = createCouncilView, refresh = refreshCouncilView }
end)()

----------------------------------------------------------------------------
-- Panel: the view tabs with the phase, Drops and the search on their right; the filter row (class circles, role
-- icons, three ticks, the lock); the footer (the lists' counts, Request sync as an icon)
----------------------------------------------------------------------------

local Chrome = (function()
local PAD, GAP = K.PAD, K.GAP
local CLASS_CHIP, CLASS_GAP, ROLE_CHIP, ROLE_GAP = 20, 3, 22, 3

-- The view tabs of the toolbar. The member page has no tab: it is opened from a name and lights the tab it came from.
local VIEWS = {
    { key = "roster", text = K.VIEW_LABEL.roster }, { key = "items", text = K.VIEW_LABEL.items },
    { key = "log", text = K.VIEW_LABEL.log, tip = "Every item handed out: search, void or restore, add an award." },
    { key = "council", text = K.VIEW_LABEL.council,
      tip = "Who is on the Loot Council. The Guild Master picks the guild council; a raid leader can add council members for their own raid." },
    { key = "rules", text = K.VIEW_LABEL.rules,
      tip = "How the winner is picked (the Guild Master's rules, with an example that re-ranks as you change them) and the prized items." },
}

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

local function toggleIn(set, key)
    if set[key] then set[key] = nil else set[key] = true end
    CouncilUI:Refresh(true)
end

-- The filter toggles: a class circle (the picked ones carry a gold ring, the others fade while any is picked) and a
-- role icon on a flat square ("chosen" look while picked). Icon-only, nine and three of them on one strip.
-- TODO(refactor): move into UI:CreateChip (an icon-only toggle chip: a class circle / a role icon)
local function classChip(parent, classFile)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(CLASS_CHIP, CLASS_CHIP)
    b.ring = b:CreateTexture(nil, "BACKGROUND")
    b.ring:SetTexture(K.DISC)
    b.ring:SetSize(CLASS_CHIP + 4, CLASS_CHIP + 4)
    b.ring:SetPoint("CENTER")
    local r, g, bl = S:Color("GOLD")
    b.ring:SetVertexColor(r, g, bl, 0.95)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    UI:ClassIcon(b.icon, classFile)
    b.classFile = classFile
    function b:Paint()
        local any = next(state.classes) ~= nil
        local on = state.classes[classFile] and true or false
        self.ring:SetShown(on)
        local faded = any and not on and not self.hovered
        V.desaturate(self.icon, faded)
        self.icon:SetAlpha(faded and 0.35 or 1)
    end
    b:SetScript("OnClick", function() toggleIn(state.classes, classFile) end)
    b:SetScript("OnEnter", function(self)
        self.hovered = true
        self:Paint()
    end)
    b:SetScript("OnLeave", function(self)
        self.hovered = false
        self:Paint()
    end)
    UI:AttachTooltip(b, "|c" .. (ns.Util.ClassColorHex and ns.Util.ClassColorHex(classFile) or "ffffffff")
        .. className(classFile) .. "|r", nil, { anchor = "ANCHOR_TOP" })
    return b
end

local function roleChip(parent, info)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(ROLE_CHIP, ROLE_CHIP)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    UI:AddEdges(b)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    b.icon:SetTexture(UI.ROLE_TEX)
    b.icon:SetTexCoord(UI:RoleCoords(info.key))
    b.role = info.key
    function b:Paint()
        local any = next(state.roles) ~= nil
        local on = state.roles[info.key] and true or false
        UI:PaintSleek(self, on and "chosen" or "secondary", self.hovered, not on and 0.6 or nil)
        local faded = any and not on and not self.hovered
        V.desaturate(self.icon, faded)
        self.icon:SetAlpha(faded and 0.4 or 1)
    end
    b:SetScript("OnClick", function() toggleIn(state.roles, info.key) end)
    b:SetScript("OnEnter", function(self)
        self.hovered = true
        self:Paint()
    end)
    b:SetScript("OnLeave", function(self)
        self.hovered = false
        self:Paint()
    end)
    V.tip(b, info.label)
    return b
end

local function separator(parent, x)
    return UI:Rule(parent, { vertical = true, left = x, top = 4, bottom = 4, alpha = 0.15 })
end

-- The lock state for everyone but the raid leader ("Locked by X"), its tooltip.
local function lockStatusTip(_, tt)
    local locked, info = UI:GetBiSLock()
    if not locked then return false end
    tt:AddLine("BiS lists are locked", S:Color("GOLD"))
    tt:AddLine("Locked by " .. UI:LockByText(info, true) .. ". Raiders can't edit their lists; "
        .. "anyone whose list still changes gets a warning marker and is not suggested in rolls.", 1, 1, 1, true)
end

local function createToolbar(p)
    local L = p.layout
    local bar = L.toolbar

    -- The toolbar: the views as its tabs; the phase and the search as its controls on the right.
    bar:SetTabs(VIEWS, function(key) CouncilUI:SetView(key) end)
    p.viewButtons = bar.tabByKey

    p.search = UI:CreateSearchBox(bar, 150, function(text)
        text = type(text) == "string" and text or ""
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        state.search = text:lower()
        CouncilUI:Refresh(true)
    end)

    -- (1.3.5: no Drops button here; /dz drops, Shift-click on the minimap button and the session bar open it)

    -- the phase: "Phase [P1]"; the menu says which phase is the guild's (or the group's)
    local box = CreateFrame("Frame", nil, bar)
    box:SetSize(100, S.BTN_H)
    p.phaseDD = UI:CreateDropdown(box, 60, phaseOptions, currentPhase, function(value)
        state.phase = tonumber(value) or state.phase
        -- A new phase starts on its own first boss (only ShowItem/ShowBoss jumps keep a sticky node).
        state.selectedNode = nil
        state.focus = nil
        CouncilUI:Refresh(true)
    end)
    local baseRefresh = p.phaseDD.Refresh
    function p.phaseDD:Refresh()
        baseRefresh(self)
        self:SetText("P" .. currentPhase())
    end
    p.phaseDD:Refresh()
    p.phaseDD:SetPoint("RIGHT", box, "RIGHT", 0, 0)
    p.phaseLabel = UI:Text(box, "sub", nil, { text = "Phase", justify = "RIGHT" })
    p.phaseLabel:SetPoint("RIGHT", p.phaseDD, "LEFT", -6, 0)
    box:SetWidth(math.floor(60 + 6 + UI:TextWidth(p.phaseLabel) + 0.5))
    p.phaseBox = box
    bar:SetFilters({ box, p.search })

    -- The filter strip under the toolbar (Roster and Items): class circles | role icons | In my raid, Hide obtained,
    -- Off-spec lists | the lock.
    -- TODO(refactor): move into UI:CreateLayout (a filter strip under the toolbar that the content makes room for)
    local row2 = CreateFrame("Frame", nil, p)
    row2:SetPoint("TOPLEFT", PAD, K.TOP_Y)
    row2:SetPoint("TOPRIGHT", -PAD, K.TOP_Y)
    row2:SetHeight(K.FILTER_H)
    p.row2 = row2

    p.classChips = {}
    local x = 0
    for _, cl in ipairs(ns.CLASSES or DEFAULT_CLASSES) do
        local b = classChip(row2, cl)
        b:SetPoint("LEFT", row2, "LEFT", x, 0)
        p.classChips[cl] = b
        x = x + CLASS_CHIP + CLASS_GAP
    end
    x = x - CLASS_GAP + 12
    separator(row2, x)
    x = x + 13
    p.roleChips = {}
    for _, info in ipairs(K.ROLE_CHIPS) do
        local b = roleChip(row2, info)
        b:SetPoint("LEFT", row2, "LEFT", x, 0)
        p.roleChips[info.key] = b
        x = x + ROLE_CHIP + ROLE_GAP
    end
    x = x - ROLE_GAP + 12
    separator(row2, x)
    x = x + 9

    p.raidCB = UI:CreateCheckbox(row2, "In my raid", function() return state.raidOnly end, toggleSetter("raidOnly"))
    p.raidCB:SetPoint("LEFT", row2, "LEFT", x, 0)
    p.raidCB.tooltipText = "Only the members in your raid or party."
    p.obtainedCB = UI:CreateCheckbox(row2, "Hide obtained", function() return state.hideObtained end,
        toggleSetter("hideObtained"))
    p.obtainedCB:SetPoint("LEFT", p.raidCB.label, "RIGHT", 10, 0)
    p.obtainedCB.tooltipText = "Leaves out the picks members already have (dimmed in the roster)."
    -- Addendum H: switch the Roster / Items / Member views to the players' off-spec lists.
    p.offspecCB = UI:CreateCheckbox(row2, "Off-spec lists", function() return state.offspec end,
        toggleSetter("offspec"))
    p.offspecCB:SetPoint("LEFT", p.obtainedCB.label, "RIGHT", 10, 0)
    p.offspecCB.tooltipText = "Shows the members' off-spec lists instead of their main ones."

    -- §38: "Lock lists" / "Unlock lists" for the raid leader (the group's loot authority); everyone else on the
    -- council sees "Locked by X" while the lists are locked.
    if UI.CreateBiSLockButton then
        p.lockBtn = UI:CreateBiSLockButton(row2, 96, S.ROW.compact, { short = true })
        p.lockBtn:SetPoint("RIGHT", row2, "RIGHT", 0, 0)
    end
    p.lockStatus = CreateFrame("Frame", nil, row2)
    p.lockStatus:SetSize(120, 20)
    p.lockStatus:SetPoint("RIGHT", row2, "RIGHT", 0, 0)
    p.lockStatus.text = UI:Text(p.lockStatus, "body", "TEXT", { justify = "RIGHT" })
    p.lockStatus.text:SetPoint("RIGHT", 0, 0)
    UI:AttachTooltip(p.lockStatus, lockStatusTip, nil, { anchor = "ANCHOR_TOP" })
    p.lockStatus:Hide()
end

-- The lock button (the raid leader: "Unlock lists" says it is locked) or "Locked by X" for everyone else (§38).
local function updateLockControls()
    local p = panel
    if p.lockBtn and p.lockBtn.Refresh then p.lockBtn:Refresh() end
    local locked, info = UI:GetBiSLock()
    local st = p.lockStatus
    if locked and not (p.lockBtn and p.lockBtn:IsShown()) then
        st.text:SetText(UI:LockIcon(12) .. " " .. colorCode("warn") .. "Locked by " .. UI:LockByText(info) .. "|r")
        st:Show()
    else
        st:Hide()
    end
end

-- The footer: the lists' counts (quiet), Request sync as an icon at the right.
local function createFooter(p)
    local f = CreateFrame("Frame", nil, p)
    f:SetPoint("BOTTOMLEFT", PAD, 6)
    f:SetPoint("BOTTOMRIGHT", -PAD, 6)
    f:SetHeight(K.FOOT_H)
    p.footer = f

    f.text = UI:Text(f, "sub")
    f.text:SetPoint("LEFT", 0, 0)

    f.sync = UI:CreateIconButton(f, K.FOOT_H, K.SYNC_ICON, nil, function(self)
        if not (ns.Sync and ns.Sync.RequestSync and ns.Sync:RequestSync()) then return end
        -- HELLO is rate-limited to once per 30s; mirror that on the button.
        local b = f.sync
        b:Disable()
        C_Timer.After(30, function() b:Enable() end)
    end)
    f.sync.icon:SetDesaturated(true)
    f.sync.icon:ClearAllPoints()
    f.sync.icon:SetPoint("TOPLEFT", 4, -4)
    f.sync.icon:SetPoint("BOTTOMRIGHT", -4, 4)
    f.sync:SetPoint("RIGHT", 0, 0)
    V.tip(f.sync, "Request sync", "Ask online guild members and council for newer lists and awards.")
end

-- The layout's room for the view: the filter strip and the footer take theirs on Roster / Items; the member page
-- and the Loot council view start right under the toolbar.
local function placeContent(view)
    local L = panel.layout
    local lists = view == "roster" or view == "items"
    L.y0 = -K.TOP_Y + (lists and (K.FILTER_H + GAP) or 0)
    L.bottom = lists and K.LIST_BOTTOM or (view == "council" and PAD or UI.LAYOUT.BOTTOM)
    L:Layout()
end

local function updateToolbar()
    local p = panel
    if p.phaseDD and p.phaseDD.Refresh then p.phaseDD:Refresh() end
    if p.raidCB and p.raidCB.Refresh then p.raidCB:Refresh() end
    if p.obtainedCB and p.obtainedCB.Refresh then p.obtainedCB:Refresh() end
    if p.offspecCB and p.offspecCB.Refresh then p.offspecCB:Refresh() end
    for _, b in pairs(p.classChips or {}) do b:Paint() end
    for _, b in pairs(p.roleChips or {}) do b:Paint() end
    updateLockControls()
    -- the current view lit (the member page lights the view it was opened from)
    local lit = state.view == "member" and (state.backView or "roster") or state.view
    p.layout.toolbar:SelectTab(lit)
    placeContent(state.view)
end

local function updateFooter(stats)
    local parts = { string.format("%d %s", stats.total, stats.total == 1 and "list" or "lists") }
    if stats.inRaid > 0 then parts[#parts + 1] = string.format("%d in raid", stats.inRaid) end
    if stats.stale > 0 then
        parts[#parts + 1] = colorCode("warn") .. string.format("%d older than 7 days", stats.stale) .. "|r"
    end
    panel.footer.text:SetText(table.concat(parts, " · "))
end

return { createToolbar = createToolbar, createFooter = createFooter, update = updateToolbar,
         updateFooter = updateFooter }
end)()

-- The panel: a List + detail layout (UI:CreateLayout): the toolbar (views, phase, search), the content the views
-- share (Roster, the member page and the Loot council fill it; Items uses its list column and its detail, with the
-- boss's banner), the filter strip and the footer around it. The Loot log and the Rules views place themselves under
-- the toolbar (UI/LootLog.lua, UI/CouncilRules.lua).
function CouncilUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", "DisasterZoneCouncilPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    p.dirty = true

    p.layout = UI:CreateLayout("listdetail", p, { listWidth = K.TREE_W,
        banner = { size = "strip", title = "Select a boss" } })
    p.layout.list:Hide()
    p.layout.detail:Hide()

    Chrome.createToolbar(p)
    Chrome.createFooter(p)
    p.rosterView = Roster.create(p)

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

    -- The Loot Log and Loot Council views have their own controls: the phase / search / filters don't apply to them.
    local council, log = state.view == "council", state.view == "log"
    local rules = state.view == "rules" and ns.CouncilRulesUI ~= nil
    if council and not panel.councilView then
        panel.councilView = CouncilView.create(panel)
    end
    -- 1.3.5: Council > Rules (UI/CouncilRules.lua)
    if rules and not panel.rulesView then panel.rulesView = ns.CouncilRulesUI:Create(panel) end
    if panel.rulesView then panel.rulesView:SetShown(rules) end
    if log and not panel.logView and ns.LootLogUI then
        panel.logView = ns.LootLogUI:CreatePanel(panel)
    end
    if panel.councilView then panel.councilView:SetShown(council) end
    if panel.logView then panel.logView:SetShown(log) end
    local own = council or log or rules
    panel.phaseBox:SetShown(not own)
    panel.search:SetShown(not own)
    -- (the layout's list column and detail are the Items view's)
    panel.layout.list:SetShown(not own and state.view == "items")
    panel.layout.detail:SetShown(not own and state.view == "items")
    if own then
        panel.rosterView:Hide()
        if panel.itemsView then panel.itemsView:Hide() end
        if panel.memberView then panel.memberView:Hide() end
        panel.row2:Hide()
        panel.footer:Hide()
        Chrome.update()
        if council then CouncilView.refresh() end
        if rules then ns.CouncilRulesUI:Refresh() end
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
        panel.itemsView = Items.create(panel)
    end
    if view == "member" and not panel.memberView then
        panel.memberView = Member.create(panel)
    end

    panel.rosterView:SetShown(view == "roster")
    if panel.itemsView then panel.itemsView:SetShown(view == "items") end
    if panel.memberView then panel.memberView:SetShown(view == "member") end
    panel.row2:SetShown(view ~= "member")
    panel.footer:SetShown(view ~= "member")

    Chrome.update()
    if view == "roster" then
        Roster.refresh(rosterRows, stats, resetScroll)
    elseif view == "items" then
        Items.refresh(phase, members, resetScroll, keepTreeScroll)
    else
        Member.refresh(phase)
    end
    Chrome.updateFooter(stats)
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
    if view ~= "roster" and view ~= "items" and view ~= "member" and view ~= "log" and view ~= "council"
        and view ~= "rules" then return end
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
    if state.view ~= "member" then state.backView = state.view end
    state.memberKey = key
    state.view = "member"
    self:OpenPanel()
end

-- The Loot Log view (/dz log, the Home cards, "loot" share links; MainFrame:Open("loot") lands here).
function CouncilUI:ShowLog()
    state.view = "log"
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
        CouncilView.refresh()
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
        ns:Print("The council list was not saved: %s", tostring(err or "this DisasterZone core can't share council lists"))
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
    local text
    if kind == "guild" then
        text = "Remove everyone from the guild council and share the empty list with the guild?\n\n"
            .. "The Guild Master always stays on the council."
    else
        text = "Remove everyone from your raid council list?\n\nThe raid leader always stays on the council of their raid."
    end
    if ns.Popup then
        ns.Popup:Confirm({ key = "CLEAR_COUNCIL", title = "Clear the council", text = text, ok = "Clear",
            danger = true, onAccept = function() CouncilUI:ClearCouncil(kind) end })
    end
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
        ns:Print("The council list was not cleared: %s", tostring(err or "this DisasterZone core can't share council lists"))
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
--   inRaid, raidLeader, raidLeaderOutside (1.3: the leader is not in my guild, so never council), raidShared,
--   raidMembers = {...} (1.3: with the master looter while it is council), mySource, canEdit }
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
        out.raidLeaderOutside = (leader and out.inGuild and not realGuildMember(leader)) or nil
        local rc = guildCall("GetRaidCouncil")
        if type(rc) ~= "table" or (leader and rc.leader and rc.leader ~= leader) then rc = nil end
        if not rc and leader and leader == me and not out.raidLeaderOutside then
            local mine = savedList("raid")   -- I lead: my own list is this raid's council
            if mine then rc = { leader = me, members = mine.members } end
        end
        out.raidShared = rc ~= nil
        if leader and not out.raidLeaderOutside then out.raidMembers[1] = entry(leader, "Raid leader") end
        for _, key in ipairs(sortedSet(copySet(rc and rc.members))) do
            if key ~= leader and realGuildMember(key) then out.raidMembers[#out.raidMembers + 1] = entry(key) end
        end
        local ml = guildCall("GetRaidMasterLooter")
        if ml and guildCall("GetCouncilSource", ml) == "ml" then
            out.raidMembers[#out.raidMembers + 1] = entry(ml, "Master looter")
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
