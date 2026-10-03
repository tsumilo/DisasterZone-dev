if DisasterZoneBoot and DisasterZoneBoot.Run("UI/DropPanel.lua", ...) then return end -- DisasterZone UI/DropPanel.lua
-- Boss-drop alerts: the Loot Council drop panel (with DisasterZone rolls, ADDENDUM A §19.5; also for the party
-- leader in dungeon mode, ADDENDUM B §22.2), the personal "On your BiS list!" toast, and BiS badges / glow
-- on the default loot frame buttons (SPEC §12.8). Awards of an item that has a roll go through the roll
-- so every popup closes (ADDENDUM C §23.2). The raid leader can lock / unlock the group's BiS lists from
-- the footer, and candidates / roll rows of players who changed their list while locked carry a warning
-- marker (ADDENDUM F §38). ADDENDUM G: council votes on roll rows (a vote column you click to vote), award
-- reasons ("Award to X as ▸", "Reason ▸"), and one-click DE / Bank buttons for the guild's disenchanter / bank.
local addonName, ns = ...

local DropPanel = ns:NewModule("DropPanel")

local _G = _G
local CreateFrame = CreateFrame
local GetTime = GetTime
local format = string.format
local tinsert, tremove, tconcat, sort = table.insert, table.remove, table.concat, table.sort
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local ipairs, pairs, type, tonumber, tostring, pcall = ipairs, pairs, type, tonumber, tostring, pcall

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local PANEL_NAME = "DisasterZoneDropPanel"
local PANEL_W, PANEL_MIN_H, PANEL_MAX_H = 430, 150, 520
local HEADER_H, FOOTER_H, SCROLLBAR_W = 40, 30, 26
local ITEM_HEAD_H, ROW_H, ACTION_H, BLOCK_GAP = 36, 18, 22, 8
local ROLL_ROW_H = 20
local MAX_ROWS = 8
local MAX_ROLL_ROWS = 10
local ROLL_TICK = 0.5         -- countdown refresh while a roll of the shown drop is open
local EQ_SIZE = 14
local MAX_DROP_ITEMS = 16
local TOAST_HOLD, TOAST_FADE, TOAST_LINGER = 8, 1, 3
local TOAST_QUEUE_MAX = 10
local ALERT_DEDUPE = 90       -- seconds: the same item (corpse drop + group-loot roll) alerts only once
local ANNOUNCE_COOLDOWN = 2
local AWARD_WINDOW = 120      -- ledger entries up to this long before the drop still count as its awards

-- Texture escapes instead of star / check glyphs: the default WoW fonts do not contain them.
local STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t"
local STAR_SMALL = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:10:10|t"

local FALLBACK_COLORS = {
    main     = { 0.98, 0.78, 0.22 },
    alt      = { 0.41, 0.80, 0.94 },
    obtained = { 0.30, 0.90, 0.40 },
    muted    = { 0.55, 0.55, 0.55 },
    warn     = { 1.00, 0.55, 0.20 },
    bad      = { 1.00, 0.30, 0.30 },
    council  = { 1.00, 0.50, 0.00 },
    offspec  = { 0.72, 0.60, 0.92 },
}

-- Row column layouts {x, width} (rows are ~384px wide at PANEL_W 430; the equipped icons sit
-- right-aligned in the last 34px). Spec needs ~70px for "Beast Mastery" / "Assassination".
local NORMAL_COLS = { name = { 30, 76 }, spec = { 108, 74 }, badge = { 184, 48 }, status = { 234, 84 } }
-- Roll rows: "Shadowmelder" needs 71 px, "Marksmanship" 69, "[BiS] P3" 36, votes (check icon + "12") 28,
-- "Suggested" 50 (the §38 warning icon moved to the name column), roll text "100 x3" 41.
local ROLL_COLS = { name = { 30, 76 }, spec = { 108, 70 }, badge = { 180, 38 }, votes = { 220, 30 }, tag = { 252, 56 } }
local VOTE_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:11:11|t"

local SLOT_GROUP_FALLBACK = {
    [11] = { 11, 12 }, [12] = { 11, 12 }, [13] = { 13, 14 }, [14] = { 13, 14 }, [15] = { 15, 16 }, [16] = { 15, 16 },
}
local GROUP_LABELS = { [11] = "Ring", [12] = "Ring", [13] = "Trinket", [14] = "Trinket", [15] = "Weapon", [16] = "Weapon" }

---------------------------------------------------------------------------
-- Small helpers (all nil-safe: other modules may not have data yet)
---------------------------------------------------------------------------
local function Color(key)
    local c = ns.COLORS and ns.COLORS[key]
    return c or FALLBACK_COLORS[key] or FALLBACK_COLORS.muted
end

local function Paint(text, key)
    local c = Color(key)
    return format("|cff%02x%02x%02x%s|r", floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5),
        floor(c[3] * 255 + 0.5), text)
end

local function Setting(path, default)
    if ns.db and ns.DB and ns.DB.GetSetting then
        local v = ns.DB:GetSetting(path)
        if v ~= nil then return v end
    end
    return default
end

local function IsCouncil()
    return (ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil()) and true or false
end

-- Dungeon mode (ADDENDUM B §22.1). Guarded: older cores have no Util.IsDungeonModeActive.
local function DungeonModeActive()
    local fn = ns.Util and ns.Util.IsDungeonModeActive
    if type(fn) ~= "function" then return false end
    local ok, active = pcall(fn)
    return (ok and active) and true or false
end

-- "party" in a dungeon-mode 5-man party, else "raid" (tooltips and row texts).
local function GroupWord()
    local inRaid = _G.IsInRaid and _G.IsInRaid()
    return (not inRaid and DungeonModeActive()) and "party" or "raid"
end

-- The party leader runs the drop panel in dungeon mode (like the council does in raids).
local function IsDungeonLeader()
    if not DungeonModeActive() then return false end
    local leader = _G.UnitIsGroupLeader
    return (leader and leader("player")) and true or false
end

local function ViewPhase()
    local p = ns.Guild and ns.Guild.GetViewPhase and ns.Guild:GetViewPhase()
    return tonumber(p) or 1
end

local function ShortName(key)
    if type(key) ~= "string" then return "?" end
    if ns.Util and ns.Util.ShortName then return ns.Util.ShortName(key) or key end
    return key
end

local function IsMe(key)
    return ns.Util and ns.Util.IsMe and ns.Util.IsMe(key) or false
end

local function ClassOf(key)
    if ns.Guild and ns.Guild.GetClass then return ns.Guild:GetClass(key) end
    return nil
end

local function ColoredName(key, classFile)
    classFile = classFile or ClassOf(key)
    if ns.UI and ns.UI.ColoredName then return ns.UI:ColoredName(key, classFile) end
    return ShortName(key)
end

local function ItemText(itemID)
    if ns.UI and ns.UI.ItemText then
        local text = ns.UI:ItemText(itemID)   -- drop the extra "loading" return value
        return text
    end
    return (ns.ItemDB and ns.ItemDB:GetName(itemID)) or ("item " .. tostring(itemID))
end

local function ItemName(itemID)
    return (ns.ItemDB and ns.ItemDB.GetName and ns.ItemDB:GetName(itemID)) or ("item " .. tostring(itemID))
end

local function ItemLink(itemID)
    if ns.ItemDB and ns.ItemDB.GetLink then return ns.ItemDB:GetLink(itemID) end
    return nil
end

local function ItemIcon(itemID)
    if ns.ItemDB and ns.ItemDB.GetIcon then return ns.ItemDB:GetIcon(itemID) end
    return 134400
end

local function SlotLabel(sid)
    local s = ns.SLOTS and ns.SLOTS[sid]
    return s and s.label or "?"
end

local function ClassName(classFile)
    local names = _G.LOCALIZED_CLASS_NAMES_MALE
    if names and names[classFile] then return names[classFile] end
    if type(classFile) ~= "string" then return "?" end
    return classFile:sub(1, 1) .. classFile:sub(2):lower()
end

local function GroupKeys()
    if ns.Util and ns.Util.GetGroupKeys then return ns.Util.GetGroupKeys() or {} end
    return {}
end

local function History()
    local h = ns.Loot and ns.Loot.GetHistory and ns.Loot:GetHistory()
    return type(h) == "table" and h or {}
end

local function PlayAlertSound()
    local kit, play = _G.SOUNDKIT, _G.PlaySound
    if kit and kit.RAID_WARNING and play then play(kit.RAID_WARNING, "Master") end
end

local function Trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function HideTooltip()
    _G.GameTooltip:Hide()
end

-- Drop payloads may come from the network: keep only sane item IDs (order and duplicates kept).
local function SanitizeItems(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, id in ipairs(list) do
        id = tonumber(id)
        if id and id >= 1 and id <= 200000 and id == floor(id) then
            out[#out + 1] = id
            if #out >= MAX_DROP_ITEMS then break end
        end
    end
    return out
end

-- Store:GetWanters returns one entry per (player, wanted item); the panel needs one per player.
local function UniqueWanters(itemID, opts)
    local out = {}
    if not (ns.Store and ns.Store.GetWanters) then return out end
    local list = ns.Store:GetWanters(itemID, opts)
    if type(list) ~= "table" then return out end
    local seen = {}
    for _, w in ipairs(list) do
        if type(w) == "table" and type(w.key) == "string" and not seen[w.key] then
            seen[w.key] = true
            out[#out + 1] = w
        end
    end
    return out
end

-- First not-yet-obtained BiS match of the player for a dropped item (MatchItem is sorted best first).
-- includeOS (Addendum H): an off-spec match counts too (MatchItem lists main-spec matches first).
local function OwnNeededMatch(itemID, includeOS)
    if not (ns.BiS and ns.BiS.MatchItem) then return nil end
    local matches = ns.BiS:MatchItem(itemID)
    if type(matches) ~= "table" then return nil end
    for _, m in ipairs(matches) do
        if type(m) == "table" and not m.obtained and (includeOS or not m.os) then return m end
    end
    return nil
end

local function OffSpecLabel()
    local sp = ns.BiS and ns.BiS.GetSpec and ns.BiS:GetSpec("os") or ""
    return sp ~= "" and sp or nil
end

local function BadgeText(w, viewPhase)
    local t
    if w.os then
        t = Paint(w.which == "alt" and "[OS alt]" or "[OS]", "offspec")   -- off-spec list (Addendum H)
    else
        t = (w.which == "alt") and Paint("[Alt]", "alt") or Paint("[BiS]", "main")
    end
    local p = tonumber(w.phase)
    if p and p ~= viewPhase then t = t .. Paint(" P" .. p, "muted") end
    return t
end

local function PresenceText(w)
    if w.inRaid then return "in raid" end
    if w.online then return "online" end
    return "offline"
end

-- §38: serverTime when the player changed their list while the lists were locked (the GetWanters /
-- GetResults field, else Store:GetLockFlag), or nil.
local function LockChanged(row)
    if type(row) ~= "table" then return nil end
    local ts = tonumber(row.lockChanged)
    if ts then return ts end
    if row.lockChanged == true then return 0 end
    return ns.UI and ns.UI.LockChangedAt and ns.UI:LockChangedAt(row.key) or nil
end

local function WarnIcon(size)
    if ns.UI and ns.UI.WarnIcon then return ns.UI:WarnIcon(size or 10) end
    return "!"
end

local function AddLockChangedLine(tt, ts, extra)
    if ns.UI and ns.UI.AddLockChangedLine then ns.UI:AddLockChangedLine(tt, ts ~= 0 and ts or nil, extra) end
end

local function ItemSubtitle(itemID)
    local data = ns.Data
    if data and data.Tokens and data.Tokens[itemID] then
        local slot
        local sids = ns.ItemDB and ns.ItemDB.GetSlotsForItem and ns.ItemDB:GetSlotsForItem(itemID)
        if type(sids) == "table" and sids[1] then slot = SlotLabel(sids[1]) end
        local text = slot and ("Token: " .. slot) or "Token / quest item"
        local classes = data.TokenClasses and data.TokenClasses[itemID]
        if type(classes) == "table" and #classes > 0 then
            local names = {}
            for i, cf in ipairs(classes) do names[i] = ClassName(cf) end
            text = text .. " (" .. tconcat(names, ", ") .. ")"
        end
        return text
    end
    local CI = _G.C_Item
    if CI and CI.GetItemInfoInstant then
        local _, _, subType, equipLoc, _, classID, subclassID = CI.GetItemInfoInstant(itemID)
        local slot = type(equipLoc) == "string" and equipLoc ~= "" and _G[equipLoc]
        if type(slot) == "string" then
            -- classID 2 = Weapon, 4 = Armor (subclass 0 = miscellaneous: rings, trinkets, ...)
            local showSub = classID == 2 or (classID == 4 and (subclassID or 0) > 0)
            if showSub and type(subType) == "string" and subType ~= "" then
                return slot .. " · " .. subType
            end
            return slot
        end
    end
    return ""
end

-- Match ledger awards to the items of a drop: k-th copy of an item gets the k-th award (oldest first). The
-- awards come from Ledger:AwardsForDrop (the same matching Roll all uses): only awards recorded by or for the group
-- that saw the drop, so another raid group's award of the same item is not shown as this drop's.
local function CollectAwards(drop, items)
    local result = {}
    if not (ns.Ledger and ns.Ledger.AwardsForDrop) then return result end
    local byItem = ns.Ledger:AwardsForDrop(drop)
    if type(byItem) ~= "table" then return result end
    local used = {}
    for idx, itemID in ipairs(items) do
        local k = (used[itemID] or 0) + 1
        used[itemID] = k
        local list = byItem[itemID]
        if list and list[k] then result[idx] = list[k] end
    end
    return result
end

local function LinkToChat(itemID)
    local link = ItemLink(itemID)
    if not link then return end
    local util = _G.ChatFrameUtil
    local insert = (util and util.InsertLink) or _G.ChatEdit_InsertLink
    if insert and insert(link) then return end
    local open = (util and util.OpenChat) or _G.ChatFrame_OpenChat
    if open then open(link) end
end

local function FindInHistory(drop)
    local hist = History()
    for i = #hist, 1, -1 do
        local h = hist[i]
        if h == drop or (type(h) == "table" and h.s ~= nil and h.s == drop.s) then return i end
    end
    return nil
end

local function PopupEditBox(popup)
    return (popup.GetEditBox and popup:GetEditBox()) or popup.editBox
end

-- Resolve a typed character name: group members first, then the guild roster, else normalise it.
local function ResolvePlayer(text)
    if type(text) ~= "string" then return nil end
    text = Trim(text)
    if text == "" then return nil end
    -- Lua's lower() is byte-wise: fold the Latin-1 accents too, so "élise" finds Élise.
    local Util = ns.Util
    local fold = (Util and Util.FoldCase) or string.lower
    local lower = fold(text)
    local function matches(key)
        if type(key) ~= "string" then return false end
        if fold(key) == lower or fold(ShortName(key)) == lower then return true end
        local base = key:match("^[^-]+")
        return base ~= nil and fold(base) == lower
    end
    for _, key in ipairs(GroupKeys()) do
        if matches(key) then return key end
    end
    if ns.Guild and ns.Guild.GetMembers then
        for _, key in ipairs(ns.Guild:GetMembers() or {}) do
            if matches(key) then return key end
        end
    end
    local name, realm = text:match("^([^-]+)%-?(.*)$")
    if not name then return nil end
    name = (Util and Util.CapitalizeName) and Util.CapitalizeName(name) or (name:sub(1, 1):upper() .. name:sub(2):lower())
    local full = (realm and realm ~= "") and (name .. "-" .. realm) or name
    if ns.Util and ns.Util.NormalizeName then return ns.Util.NormalizeName(full) end
    return full
end

local function DemoEnabled()
    return (ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()) and true or false
end

-- Simulated (/dz test) drops only get awards and rolls in demo mode, where both stay local
-- (Roll is local-only and the Ledger uses its in-memory demo log there).
local function FakeDropLocked(drop)
    return type(drop) == "table" and drop.test and not DemoEnabled() or false
end

---------------------------------------------------------------------------
-- Paired slots: "currently wearing" for rings / trinkets / weapons (ADDENDUM A §18)
---------------------------------------------------------------------------
local function SlotGroup(sid)
    sid = tonumber(sid)
    if not sid then return nil end
    local g = ns.SLOT_GROUP and ns.SLOT_GROUP[sid]
    if type(g) == "table" and #g > 0 then return g end
    return SLOT_GROUP_FALLBACK[sid] or { sid }
end

local function FirstSlotOfItem(itemID)
    local sids = ns.ItemDB and ns.ItemDB.GetSlotsForItem and ns.ItemDB:GetSlotsForItem(itemID)
    return type(sids) == "table" and tonumber(sids[1]) or nil
end

-- Worn items of a candidate: array (max 2) of { id=, label= } in slot order. `list` is
-- Store:GetWanters' equippedList (or {equipped}); the player's synced record tells which slot is which.
local function WornItems(key, sid, list)
    local out = {}
    if type(list) ~= "table" then return out end
    local group = SlotGroup(sid)
    local eq
    if group and type(key) == "string" and ns.Store and ns.Store.Get then
        local rec = ns.Store:Get(key)
        local data = type(rec) == "table" and rec.data
        eq = type(data) == "table" and type(data.eq) == "table" and data.eq or nil
    end
    local ids = {}
    for _, v in ipairs(list) do
        local id = tonumber(v)
        if id and id > 0 then ids[#ids + 1] = id end
    end
    local used = {}
    for i, id in ipairs(ids) do
        local label
        if eq then
            for _, g in ipairs(group) do
                if not used[g] and tonumber(eq[g]) == id then
                    used[g] = true
                    label = SlotLabel(g)
                    break
                end
            end
        end
        if not label and group then
            if #ids == #group then
                label = SlotLabel(group[i])
            else
                label = GROUP_LABELS[group[1]] or SlotLabel(group[1])
            end
        end
        out[#out + 1] = { id = id, label = label or "?" }
        if #out >= 2 then break end
    end
    return out
end

local function WornOfWanter(w, fallbackSid)
    local list = w.equippedList
    if type(list) ~= "table" then list = { w.equipped } end
    return WornItems(w.key, tonumber(w.sid) or fallbackSid, list)
end

local function WearingText(worn)
    local parts = {}
    for i, e in ipairs(worn) do parts[i] = ItemText(e.id) end
    return "Wearing: " .. tconcat(parts, ", ")
end

---------------------------------------------------------------------------
-- Rolls (ns.Roll, ADDENDUM A §19). Every call is guarded: the panel must work without it.
---------------------------------------------------------------------------
local rollErrors = {}
local function CallRoll(method, ...)
    local R = ns.Roll
    local fn = R and R[method]
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, R, ...)
    if ok then return a, b end
    if not rollErrors[method] then
        rollErrors[method] = true      -- report once, keep the panel alive
        local handler = _G.geterrorhandler and _G.geterrorhandler()
        if handler then handler(a) end
    end
    ns:Debug("Roll:%s failed: %s", method, tostring(a))
    return nil
end

local function HasRoll(method)
    return ns.Roll ~= nil and type(ns.Roll[method]) == "function"
end

local function CanStartRolls(drop)
    if not HasRoll("Start") or FakeDropLocked(drop) then return false end
    return CallRoll("CanStart") and true or false
end

local function FormatLeft(sec)
    sec = max(0, ceil((tonumber(sec) or 0) - 0.05))
    return format("%d:%02d", floor(sec / 60), sec % 60)
end

local function RollTimeLeft(session)
    return (tonumber(session.endsAt) or 0) - GetTime()
end

-- Position in my roll queue (Roll:GetQueue, sessions in start order) of a queued session, or of
-- an item of this drop (entries read defensively). nil = not queued.
local function QueuePosition(session, itemID, dropS, copy)
    if not HasRoll("GetQueue") then return nil end
    local q = CallRoll("GetQueue")
    if type(q) ~= "table" then return nil end
    for i, e in ipairs(q) do
        if type(e) == "table" then
            if session then
                if e == session or (e.id ~= nil and e.id == session.id) then return i end
            else
                local id = tonumber(e.i or e.itemID)
                local s = e.s
                if s == nil and type(e.drop) == "table" then s = e.drop.s end
                local c = tonumber(e.c)
                if id == itemID and (s == nil or s == dropS) and (c == nil or copy == nil or c == copy) then
                    return i
                end
            end
        end
    end
    return nil
end

-- Roll state of the copy-th copy of an item of a drop: session (or nil), mode "normal" | "queued"
-- | "roll", queue position. Cancelled sessions do not count (the item can be rolled again).
local function RollStateFor(itemID, drop, copy)
    if not HasRoll("GetForItem") then return nil, "normal" end
    local dropS = type(drop) == "table" and drop.s or nil
    local session = CallRoll("GetForItem", itemID, dropS, copy)
    if type(session) ~= "table" or type(session.id) ~= "string" or session.state == "cancelled" then
        session = nil
    end
    local state = session and session.state
    if state == "queued" then return session, "queued", QueuePosition(session) end
    if state == "open" or state == "closed" or state == "awarded" then return session, "roll" end
    local pos = QueuePosition(nil, itemID, dropS, copy)
    if pos then return nil, "queued", pos end
    return nil, "normal"
end

-- Roll permission checks (Roll:CanAward / CanEnd); `fallback` when this Roll build lacks them.
local function RollAllows(method, fallback, ...)
    if not HasRoll(method) then return fallback end
    return CallRoll(method, ...) and true or false
end

local function TierBadge(row, vp)
    local tier = tonumber(row.tier) or 4
    if tier == 3 then
        local t = Paint("[OS]", "offspec")   -- off-spec list (Addendum H)
        local p = tonumber(row.phase)
        if p and p ~= vp then t = t .. Paint(" P" .. p, "muted") end
        return t
    end
    if tier == 1 or tier == 2 then
        local t = (tier == 2 or row.which == "alt") and Paint("[Alt]", "alt") or Paint("[BiS]", "main")
        local p = tonumber(row.phase)
        if p and p ~= vp then t = t .. Paint(" P" .. p, "muted") end
        return t
    end
    if row.which and row.obtained then return Paint("has it", "muted") end
    return Paint("-", "muted")
end

local function TierWord(row)
    local tier = tonumber(row.tier) or 4
    if tier == 1 then return "BiS (main)" end
    if tier == 2 then return "BiS alt" end
    if tier == 3 then return "off-spec list" .. ((type(row.spec) == "string" and row.spec ~= "") and (" (" .. row.spec .. ")") or "") end
    if row.which and row.obtained then return "listed, already obtained" end
    return "not on their BiS list"
end

local function RollCounts(results)
    local rolled, passed, votes = 0, 0, 0
    local tie = false
    for _, r in ipairs(results) do
        if type(r) == "table" then
            if r.response == "pass" and not tonumber(r.roll) then
                passed = passed + 1
            elseif tonumber(r.roll) then
                rolled = rolled + 1
            end
            if r.suggested and r.tie then tie = true end
            votes = votes + (tonumber(r.votes) or 0)
        end
    end
    return rolled, passed, tie, votes
end

local function VotesText(n)
    n = tonumber(n) or 0
    return n == 1 and "1 vote" or (n .. " votes")
end

-- ADDENDUM G: label of an award reason key ("BiS"), or nil.
local function ReasonLabel(key)
    return ns.ReasonLabel and ns.ReasonLabel(key) or nil
end

-- The guild's / raid's disenchanter ("de") or guild bank ("bank") character, or nil.
local function LootTarget(kind)
    local G = ns.Guild
    if not (G and G.GetLootTarget) then return nil end
    local key = G:GetLootTarget(kind)
    return key
end

-- I am master looter and itemID is in the open loot window (I can hand it out right now).
local function CanMasterLoot(itemID)
    local Loot = ns.Loot
    if not (Loot and Loot.CanGiveItem) then return false end
    local ok, can = pcall(Loot.CanGiveItem, Loot, itemID)
    return (ok and can) and true or false
end

-- Default award reason for a BiS candidate (Store:GetWanters entry): main pick -> BiS, alt -> Alt, off-spec
-- list -> Offspec (Addendum H).
local function WanterReason(w)
    if type(w) ~= "table" or w.cantUse then return nil end
    if w.os then return "os" end
    return w.which == "alt" and "alt" or "bis"
end

-- Bag loot: the player holding the session's item for the council (Loot:GetHolder), or nil.
local function HolderOf(session)
    local Loot = ns.Loot
    if session.demo or not (Loot and Loot.GetHolder) then return nil end
    local ok, key = pcall(Loot.GetHolder, Loot, session.i)
    return ok and key or nil
end

local function RollStateText(session, stats, queuePos)
    if not session or queuePos then
        if queuePos and queuePos > 1 then
            return Paint(format("Queued (#%d) - starts after the current roll", queuePos), "muted")
        end
        return Paint("Queued - starts after the current roll", "muted")
    end
    stats = stats or {}
    local st = session.state
    if st == "open" then
        local left = RollTimeLeft(session)
        local head = left > 0 and ("Rolling - " .. FormatLeft(left) .. " left") or "Rolling - closing..."
        local t = Paint(head, "main") .. Paint(format("  ·  %d rolled, %d passed", stats.rolled or 0, stats.passed or 0), "muted")
        if (stats.votes or 0) > 0 then t = t .. Paint("  ·  " .. VotesText(stats.votes), "muted") end
        return t
    elseif st == "awarded" then
        local t = Paint("Awarded to ", "obtained") .. ColoredName(session.winner)
        local label = ReasonLabel(session.reason)
        if label then t = t .. Paint("  ·  " .. label, "muted") end
        if session.via == "loot" then
            t = t .. Paint(" (looted)", "muted")      -- closed by the loot message (ADDENDUM C §23.1)
        elseif session.given then
            t = t .. Paint("  ·  handed out", "muted")
        else
            -- bag loot (Free for All): still in the looter's bags until they trade it
            local holder = HolderOf(session)
            if holder and holder ~= session.winner then
                t = t .. Paint("  ·  in ", "muted") .. ColoredName(holder) .. Paint("'s bags (trade)", "muted")
            end
        end
        return t
    end
    local t = Paint("Rolls closed", "warn") .. Paint(format("  ·  %d rolled", stats.rolled or 0), "muted")
    local holder = HolderOf(session)
    if holder then t = t .. Paint("  ·  held by ", "muted") .. ColoredName(holder) end
    if (stats.votes or 0) > 0 then t = t .. Paint("  ·  " .. VotesText(stats.votes), "muted") end
    if stats.tie then t = t .. Paint("  ·  tie", "warn") end
    return t
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function DropPanel:OnInit()
    self.blocks = {}
    self.toastQueue = {}
    self.recentAlerts = {}
    self.lastAnnounce = {}

    ns:On("DROP", function(drop) DropPanel:OnDrop(drop) end)

    local function dataChanged()
        DropPanel:RequestRefresh()
        local lf = _G.LootFrame
        if lf and lf:IsShown() then DropPanel:UpdateAllLootButtons() end
    end
    for _, msg in ipairs({ "LEDGER_UPDATED", "LIST_UPDATED", "LISTS_RESET", "GROUP_UPDATED",
                           "OWNED_UPDATED", "MYLIST_CHANGED", "SETTINGS_CHANGED" }) do
        ns:On(msg, dataChanged)
    end
    ns:On("ITEMINFO_READY", function()
        DropPanel:RequestRefresh()
        DropPanel:RefreshToastText()
    end)
    -- Master looters / raid leads (and the party leader in dungeon mode) may keep the panel open for
    -- rolls (/dz drops); everyone else loses it with their council seat or the dungeon mode.
    local function accessChanged()
        local f = DropPanel.frame
        if f and f:IsShown() and not IsCouncil() and not IsDungeonLeader() and not CanStartRolls(DropPanel.drop) then
            f:Hide()
        end
        dataChanged()
    end
    ns:On("CONFIG_UPDATED", accessChanged)
    ns:On("DUNGEON_MODE_CHANGED", accessChanged)
    local function rollChanged() DropPanel:RequestRefresh(0.1) end
    ns:On("ROLL_UPDATED", rollChanged)
    ns:On("ROLL_STARTED", rollChanged)
    ns:On("LOOT_HELD", rollChanged)
    ns:On("DEMO_TOGGLED", rollChanged)
    -- §38: the lock button's label / visibility and the "changed during lock" markers
    ns:On("BIS_LOCK_CHANGED", rollChanged)
    ns:On("GROUP_RULES_CHANGED", rollChanged)

    if ns.RegisterSlash then
        ns:RegisterSlash("drops", function() DropPanel:ShowHistory() end,
            "show the boss drop panel with tonight's drops")
    end
end

function DropPanel:OnLogin()
    self:HookLootFrame()
end

---------------------------------------------------------------------------
-- DROP handling
---------------------------------------------------------------------------
function DropPanel:OnDrop(drop)
    if type(drop) ~= "table" then return end
    local items = SanitizeItems(drop.i)
    if #items == 0 then return end
    if ns.ItemDB and ns.ItemDB.Prefetch then ns.ItemDB:Prefetch(items) end

    local soundPlayed = false
    if not drop.roll and Setting("alerts.councilPanel", true) and (IsCouncil() or IsDungeonLeader()) then
        if self:IsBusyWithShownDrop() then
            -- The shown drop still has a roll running or waiting for its award: stay on it; the new drop is one
            -- page further (the pager says so).
            self.newDrops = (self.newDrops or 0) + 1
            local f = self.frame
            if f and f:IsShown() then self:RenderHeader(self.drop) end
        else
            self:ShowDrop(drop)
        end
        if Setting("alerts.sound", true) then
            PlayAlertSound()
            soundPlayed = true
        end
    end
    self:HandlePersonal(drop, items, soundPlayed)
end

-- The panel shows a drop with an open roll, or a roll that closed in the last 5 minutes with rolls but no award yet
-- (the council is deciding it).
local BUSY_CLOSED_FOR = 300
function DropPanel:IsBusyWithShownDrop()
    local f, drop = self.frame, self.drop
    if not (f and f:IsShown()) or type(drop) ~= "table" or drop.test then return false end
    for _, b in ipairs(self.blocks or {}) do
        local s = b:IsShown() and b.rollSession
        if type(s) == "table" then
            if s.state == "open" then return true end
            if s.state == "closed" and b.rollStats and (tonumber(b.rollStats.rolled) or 0) > 0
                and GetTime() - (tonumber(s.closedAt) or 0) < BUSY_CLOSED_FOR then
                return true
            end
        end
    end
    return false
end

function DropPanel:HandlePersonal(drop, items, soundPlayed)
    local wantToast = Setting("alerts.personalToast", true)
    local wantChat = Setting("alerts.chat", true)
    local wantOS = Setting("alerts.offspec", true)
    local now = GetTime()
    local any = false
    local seen = {}
    for _, id in ipairs(items) do
        if not seen[id] then
            seen[id] = true
            local m = OwnNeededMatch(id, wantOS)
            local last = self.recentAlerts[id]
            if m and (drop.test or not last or now - last > ALERT_DEDUPE) then
                self.recentAlerts[id] = now
                any = true
                if wantToast then self:QueueToast(id, m, drop.test) end
                if wantChat then self:PrintOwnDrop(id, m, drop.test, 0) end
            end
        end
    end
    if any then
        if not soundPlayed and Setting("alerts.sound", true) then PlayAlertSound() end
        local lf = _G.LootFrame
        if lf and lf:IsShown() then self:UpdateAllLootButtons() end
    end
end

-- Chat line for an own BiS drop; waits briefly for the item link to be cached.
function DropPanel:PrintOwnDrop(itemID, m, test, tries)
    local link = ItemLink(itemID)
    if not link and (tries or 0) < 4 then
        C_Timer.After(0.5, function() DropPanel:PrintOwnDrop(itemID, m, test, (tries or 0) + 1) end)
        return
    end
    local which = (m.which == "alt") and "alt" or "main"
    if m.via then which = which .. ", " .. ((ns.VIA_TEXT and ns.VIA_TEXT[m.via]) or "via token") end
    if m.os then
        local sp = OffSpecLabel()
        ns:Print("%s is on your off-spec list%s: %s, P%d (%s)%s", link or ItemName(itemID),
            sp and (" (" .. sp .. ")") or "", SlotLabel(m.sid), tonumber(m.phase) or 0, which, test and " [test]" or "")
        return
    end
    ns:Print("%s %s is on your BiS list: %s, P%d (%s)%s", STAR, link or ItemName(itemID),
        SlotLabel(m.sid), tonumber(m.phase) or 0, which, test and " [test]" or "")
end

---------------------------------------------------------------------------
-- Council panel
---------------------------------------------------------------------------
local function PageButton(parent, dir, tip, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(24, 24)
    local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-"
    b:SetNormalTexture(base .. "Up")
    b:SetPushedTexture(base .. "Down")
    b:SetDisabledTexture(base .. "Disabled")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        _G.GameTooltip:SetOwner(self, "ANCHOR_TOP")
        _G.GameTooltip:AddLine(tip, 1, 1, 1)
        _G.GameTooltip:Show()
    end)
    b:SetScript("OnLeave", HideTooltip)
    return b
end

local function AddButtonTooltip(btn, textFn)
    if btn.SetMotionScriptsWhileDisabled then btn:SetMotionScriptsWhileDisabled(true) end
    btn:HookScript("OnEnter", function(self)
        local text = textFn(self)
        if not text then return end
        _G.GameTooltip:SetOwner(self, "ANCHOR_TOP")
        _G.GameTooltip:AddLine(text, 1, 1, 1, true)
        _G.GameTooltip:Show()
    end)
    btn:HookScript("OnLeave", HideTooltip)
end

function DropPanel:GetFrame()
    if self.frame then return self.frame end
    local UI = ns.UI
    local f = UI:CreateWindow(PANEL_NAME, "DisasterZone - Boss drop", PANEL_W, 300)
    f:Hide()
    self.frame = f
    local c = f.content or f
    self.content = c
    -- A manual drag turns an attached panel into a floating one (CreateWindow saves the position).
    f:HookScript("OnDragStop", function() DropPanel.attached = false end)

    -- Header: boss / raid / time, and the history pager.
    local nextBtn = PageButton(c, "Next", "Newer drop", function() DropPanel:Page(1) end)
    nextBtn:SetPoint("TOPRIGHT", c, "TOPRIGHT", -4, -6)
    local pageText = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pageText:SetPoint("RIGHT", nextBtn, "LEFT", -2, 0)
    local prevBtn = PageButton(c, "Prev", "Older drop", function() DropPanel:Page(-1) end)
    prevBtn:SetPoint("RIGHT", pageText, "LEFT", -2, 0)
    self.nextBtn, self.prevBtn, self.pageText = nextBtn, prevBtn, pageText

    local title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", c, "TOPLEFT", 8, -6)
    title:SetWidth(PANEL_W - 120)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    local sub = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    sub:SetWidth(PANEL_W - 120)
    sub:SetJustifyH("LEFT")
    sub:SetWordWrap(false)
    self.title, self.sub = title, sub

    -- Scrollable item blocks.
    local scroll = CreateFrame("ScrollFrame", PANEL_NAME .. "Scroll", c, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", c, "TOPLEFT", 4, -HEADER_H)
    scroll:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -SCROLLBAR_W, FOOTER_H)
    scroll.scrollBarHideable = true
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(PANEL_W - 12 - 4 - SCROLLBAR_W, 1)
    scroll:SetScrollChild(child)
    self.scroll, self.child = scroll, child

    local empty = child:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("TOPLEFT", child, "TOPLEFT", 8, -10)
    empty:SetText("No drop to show.")
    self.emptyText = empty

    -- Footer.
    local announceAll = UI:CreateButton(c, "Announce all", 100, 22, function() DropPanel:AnnounceAll() end)
    announceAll:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 6, 5)
    AddButtonTooltip(announceAll, function()
        if DropPanel.drop and DropPanel.drop.test then
            return "Simulated drop: the lines are only printed in your chat window."
        end
        return "Announce every item of this drop and who has it on their BiS list."
    end)
    local rollAll = UI:CreateButton(c, "Roll all", 80, 22, function() DropPanel:RollAll() end)
    rollAll:SetPoint("LEFT", announceAll, "RIGHT", 4, 0)
    AddButtonTooltip(rollAll, function()
        local text = "Roll every item of this drop, one after another (awarded items are skipped). "
            .. "Everyone in the " .. GroupWord() .. " gets a Roll / Pass popup for each item."
        if DemoEnabled() then text = text .. "\n\nDemo mode: fake raiders roll; nothing is sent." end
        return text
    end)
    rollAll:Hide()
    self.rollAllBtn = rollAll
    local close = UI:CreateButton(c, _G.CLOSE or "Close", 80, 22, function() f:Hide() end)
    close:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -6, 5)
    -- §38: small "Lock lists" / "Unlock lists" button for the raid leader (the group's loot authority).
    if UI.CreateBiSLockButton then
        local lock = UI:CreateBiSLockButton(c, 96, 22, { short = true })
        lock:SetPoint("RIGHT", close, "LEFT", -4, 0)
        self.lockBtn = lock
    end

    f:HookScript("OnHide", function() DropPanel:StopRollTicker() end)
    return f
end

function DropPanel:Place()
    local f = self.frame
    local lf = _G.LootFrame
    if Setting("dropPanelMode", "auto") == "auto" and lf and lf:IsShown() then
        f:ClearAllPoints()
        -- Beside the loot window, on the side with room (loot-under-mouse can put it at the right screen edge).
        local r, pr = lf:GetRight(), _G.UIParent and _G.UIParent:GetRight()
        local ls, ps = lf.GetEffectiveScale and lf:GetEffectiveScale() or 1,
            _G.UIParent and _G.UIParent.GetEffectiveScale and _G.UIParent:GetEffectiveScale() or 1
        if r and pr and (r + 4 + PANEL_W) * ls > pr * ps then
            f:SetPoint("TOPRIGHT", lf, "TOPLEFT", -4, 0)
        else
            f:SetPoint("TOPLEFT", lf, "TOPRIGHT", 4, 0)
        end
        self.attached = true
    elseif self.attached then
        -- Back to the floating (saved) position; saved as { point, relPoint, x, y }.
        if ns.UI and ns.UI.RestorePosition then
            ns.UI:RestorePosition(f)
        else
            f:ClearAllPoints()
            local windows = ns.db and ns.db.settings and ns.db.settings.windows
            local pos = type(windows) == "table" and windows[PANEL_NAME]
            if type(pos) == "table" and type(pos[1]) == "string" then
                f:SetPoint(pos[1], _G.UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
            else
                f:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 0)
            end
        end
        self.attached = false
    end
end

function DropPanel:ShowDrop(drop)
    if type(drop) ~= "table" or not ns.UI then return end
    local f = self:GetFrame()
    self.drop = drop
    self.histIndex = FindInHistory(drop)
    self.newDrops = nil
    self:Place()
    f:Show()
    if f.Raise then f:Raise() end
    self:Render()
end

function DropPanel:ShowHistory()
    local hist = History()
    if #hist == 0 then
        ns:Print("No boss drops recorded in the last 24 hours.")
        return
    end
    self:ShowDrop(hist[#hist])
end

function DropPanel:Hide()
    if self.frame then self.frame:Hide() end
end

function DropPanel:Page(delta)
    local hist = History()
    local n = #hist
    if n == 0 then return end
    local i = self.histIndex or (n + 1)
    i = max(1, min(n, i + delta))
    self.drop = hist[i]
    self.histIndex = i
    if i == n then self.newDrops = nil end
    self:Render()
end

-- delay (optional): debounce seconds, default 0.2 (roll updates use 0.1).
function DropPanel:RequestRefresh(delay)
    local f = self.frame
    if not f or not f:IsShown() then return end
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce("droppanel-refresh", tonumber(delay) or 0.2, function() DropPanel:Render() end)
    else
        self:Render()
    end
end

---------------------------------------------------------------------------
-- Roll countdown: a 0.5s ticker that only runs while a shown block has an open roll
---------------------------------------------------------------------------
function DropPanel:StopRollTicker()
    if self.rollTicker then
        self.rollTicker:Cancel()
        self.rollTicker = nil
    end
end

function DropPanel:UpdateRollTicker(anyOpen)
    local f = self.frame
    if anyOpen and f and f:IsShown() then
        if not self.rollTicker then
            self.rollTicker = C_Timer.NewTicker(ROLL_TICK, function() DropPanel:TickRolls() end)
        end
    else
        self:StopRollTicker()
    end
end

function DropPanel:TickRolls()
    local f = self.frame
    if not f or not f:IsShown() then
        self:StopRollTicker()
        return
    end
    local any = false
    for _, b in ipairs(self.blocks) do
        local s = b:IsShown() and b.rollSession
        if s and s.state == "open" then
            any = true
            b.sub:SetText(RollStateText(s, b.rollStats))
        end
    end
    if not any then self:StopRollTicker() end
end

function DropPanel:RenderHeader(drop)
    local title, sub = "No drop selected", ""
    if type(drop) == "table" then
        local ref
        if type(drop.b) == "string" and drop.b ~= "" and ns.ItemDB and ns.ItemDB.GetBossRef then
            ref = ns.ItemDB:GetBossRef(drop.b)
        end
        local parts = {}
        if ref and ref.boss then
            title = ref.boss.name or "?"
            if ref.raid and ref.raid.name then
                parts[#parts + 1] = ref.raid.name .. (ref.dungeon == true and " (5-man)" or "")
            end
        else
            title = "Unknown source"
        end
        local ts = tonumber(drop.ts)
        if ts and ts > 1000000000 and ts < 4000000000 then parts[#parts + 1] = _G.date("%H:%M", ts) end
        if type(drop.from) == "string" and not IsMe(drop.from) then
            parts[#parts + 1] = "from " .. ShortName(drop.from)
        end
        if drop.test then parts[#parts + 1] = Paint("simulated", "warn") end
        sub = tconcat(parts, " · ")
    end
    self.title:SetText(title)
    self.sub:SetText(sub)

    local n = #History()
    local i = self.histIndex
    if n == 0 then
        self.pageText:SetText("")
        self.prevBtn:Disable()
        self.nextBtn:Disable()
    else
        local page = format("%s/%d", i and tostring(i) or "-", n)
        if (self.newDrops or 0) > 0 and i and i < n then
            page = "|cffff8000" .. page .. " new|r"   -- newer drops arrived while this one was being worked on
        end
        self.pageText:SetText(page)
        if (i or (n + 1)) > 1 then self.prevBtn:Enable() else self.prevBtn:Disable() end
        if i and i < n then self.nextBtn:Enable() else self.nextBtn:Disable() end
    end
end

function DropPanel:Render()
    local f = self.frame
    if not f then return end
    local drop = self.drop

    if not self.chrome then
        local fh, ch = f:GetHeight(), self.content:GetHeight()
        if fh and ch and ch > 0 and fh > ch and fh - ch < 90 then self.chrome = fh - ch end
    end
    local sw = self.scroll:GetWidth()
    if sw and sw > 50 then self.child:SetWidth(sw) end

    self:RenderHeader(drop)

    local y, used = 0, 0
    local anyOpen = false
    local canRoll = CanStartRolls(drop)
    if type(drop) == "table" then
        local items = SanitizeItems(drop.i)
        local awards = FakeDropLocked(drop) and {} or CollectAwards(drop, items)
        local vp = ViewPhase()
        local copies = {}   -- two identical tokens are copies 1 and 2, each with its own roll
        for idx, itemID in ipairs(items) do
            used = idx
            copies[itemID] = (copies[itemID] or 0) + 1
            local b = self.blocks[idx]
            if not b then
                b = self:NewBlock(self.child)
                self.blocks[idx] = b
            end
            local h = self:FillBlock(b, itemID, awards[idx], drop, vp, canRoll, copies[itemID])
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, -y)
            b:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, -y)
            b:SetHeight(h)
            b:Show()
            if b.rollSession and b.rollSession.state == "open" then anyOpen = true end
            y = y + h + BLOCK_GAP
        end
    end
    for i = used + 1, #self.blocks do
        local b = self.blocks[i]
        b.rollSession = nil
        b:Hide()
    end
    self.emptyText:SetShown(used == 0)
    if used == 0 then y = 40 end
    self.child:SetHeight(max(y, 1))
    if self.rollAllBtn then self.rollAllBtn:SetShown(canRoll and used > 0 and HasRoll("StartAll")) end
    if self.lockBtn and self.lockBtn.Refresh then self.lockBtn:Refresh() end
    self:UpdateRollTicker(anyOpen)

    local height = (self.chrome or 32) + HEADER_H + FOOTER_H + y + 4
    f:SetHeight(min(PANEL_MAX_H, max(PANEL_MIN_H, height)))
end

---------------------------------------------------------------------------
-- Item blocks and candidate rows
---------------------------------------------------------------------------
local function IsInMyGroup(key)
    return ns.Util and ns.Util.IsInMyGroup and ns.Util.IsInMyGroup(key) or false
end

local function LinkItem(itemID)
    if ns.UI and ns.UI.LinkInChat then
        ns.UI:LinkInChat(itemID)
    else
        LinkToChat(itemID)
    end
end

-- Roll column of a result row: "87", "87 x2", red "(1-50)", "pass", "..." (waiting) or "no roll".
local function RollCell(row, session)
    local n = tonumber(row.roll)
    if n then
        if row.invalid then
            local r = type(session) == "table" and type(session.rolls) == "table" and session.rolls[row.key]
            local lo = tonumber(row.min) or (type(r) == "table" and tonumber(r.min))
            local hi = tonumber(row.max) or (type(r) == "table" and tonumber(r.max))
            if lo and hi then return Paint(format("(%d-%d)", lo, hi), "bad") end
            return Paint(tostring(n) .. "*", "bad")
        end
        local t = "|cffffffff" .. tostring(n) .. "|r"
        local c = tonumber(row.count) or 1
        if c > 1 then t = t .. Paint(" x" .. c, "muted") end
        return t
    end
    if row.response == "pass" then return Paint("pass", "muted") end
    if type(session) == "table" and session.state == "open" then return Paint("...", "muted") end
    return Paint("no roll", "muted")
end

-- Vote column: a check + the count (gold when my vote is among them); a faint "vote" prompt on rows I may vote for.
local function VoteCell(row, canVote)
    local n = tonumber(row.votes) or 0
    if n > 0 then
        local t = VOTE_ICON .. tostring(n)
        return row.myVote and Paint(t, "main") or ("|cffffffff" .. t .. "|r")
    end
    if canVote and row.response ~= "pass" then return Paint("vote", "muted") end
    return ""
end

-- Addendum I §51: "Attendance 92% (7/8 raids)" from the raid log, when any raid is logged.
local function AddAttendanceLine(tt, key)
    if not IsCouncil() then return end   -- other raiders' attendance is council data
    local RL = ns.RaidLog
    local pct, a, n = RL and RL.GetAttendance and RL:GetAttendance(key)
    if pct then tt:AddLine(format("Attendance %d%% (%d of the last %d raids)", pct, a, n), 0.7, 0.7, 0.7) end
end

local function RollTag(row, session)
    if type(session) == "table" and session.state == "awarded" and session.winner == row.key then
        return Paint("Winner", "obtained")
    end
    if row.tie then return Paint("tie", "warn") end
    if row.suggested then return Paint("Suggested", "main") end
    if row.cantUse then return Paint("can't use", "bad") end
    if row.wonCopy then return Paint("won a copy", "muted") end
    local won = tonumber(row.wonTonight) or 0
    if won > 0 then return Paint("won " .. won, "muted") end
    if LockChanged(row) then return Paint("changed", "warn") end
    return ""
end

-- Worn items of a roll result row; falls back to the synced record when Roll gives no list.
local function WornOfRow(row, itemSid)
    local list = row.equippedList
    if type(list) ~= "table" then
        list = {}
        local group = SlotGroup(itemSid)
        local rec = group and ns.Store and ns.Store.Get and ns.Store:Get(row.key)
        local eq = type(rec) == "table" and type(rec.data) == "table" and type(rec.data.eq) == "table" and rec.data.eq
        if eq then
            for _, g in ipairs(group) do
                local id = tonumber(eq[g])
                if id and id > 0 then list[#list + 1] = id end
            end
        end
    end
    return WornItems(row.key, itemSid, list)
end

local function RollRowTooltip(self, tt, vp)
    local row, session = self.data, self.session
    if type(row) ~= "table" then return end
    tt:AddLine(ColoredName(row.key, row.classFile))
    local specLine = ((type(row.spec) == "string" and row.spec ~= "") and (row.spec .. " ") or "") .. ClassName(row.classFile)
    tt:AddLine(specLine, 0.8, 0.8, 0.8)
    local tier = tonumber(row.tier) or 4
    local c = (tier == 1 and Color("main")) or (tier == 2 and Color("alt")) or (tier == 3 and Color("offspec")) or Color("muted")
    local p = tonumber(row.phase)
    tt:AddLine(TierWord(row) .. ((tier <= 3 and p) and format(" in P%d", p) or ""), c[1], c[2], c[3])

    local n = tonumber(row.roll)
    local r = type(session) == "table" and type(session.rolls) == "table" and session.rolls[row.key]
    if n then
        if row.invalid then
            local lo = tostring(row.min or (type(r) == "table" and r.min) or "?")
            local hi = tostring(row.max or (type(r) == "table" and r.max) or "?")
            local bad = Color("bad")
            tt:AddLine(format("Rolled %d (%s-%s): not a 1-100 roll, never suggested", n, lo, hi), bad[1], bad[2], bad[3])
        else
            tt:AddLine(format("Rolled %d", n), 1, 1, 1)
        end
        local count = tonumber(row.count) or 1
        if count > 1 then tt:AddLine(format("Rolled %d times - the first roll counts", count), 0.7, 0.7, 0.7) end
    elseif row.response == "pass" then
        tt:AddLine("Passed", 0.7, 0.7, 0.7)
    elseif row.response == "roll" then
        tt:AddLine("Rolling...", 0.7, 0.7, 0.7)
    elseif type(session) == "table" and session.state == "open" then
        tt:AddLine("Has not rolled yet", 0.7, 0.7, 0.7)
    else
        tt:AddLine("Did not roll", 0.7, 0.7, 0.7)
    end
    local votes = tonumber(row.votes) or 0
    if votes > 0 and IsCouncil() then   -- Addendum G §42: votes and voter names are for the council
        local names = {}
        for i, v in ipairs(type(row.voters) == "table" and row.voters or {}) do names[i] = ShortName(v) end
        local m = Color("main")
        tt:AddLine(format("%s: %s", VotesText(votes), tconcat(names, ", ")), m[1], m[2], m[3], true)
        if row.myVote then tt:AddLine("Includes your vote", 0.7, 0.7, 0.7) end
    end
    if row.suggested then
        local m = Color("main")
        local why = row.suggestedBy == "votes" and "Suggested winner (most council votes)" or "Suggested winner"
        tt:AddLine(row.tie and (why .. " - tied: pick one or re-roll") or why, m[1], m[2], m[3])
    elseif row.tie then
        local w = Color("warn")
        tt:AddLine("Tied with the suggested winner", w[1], w[2], w[3])
    end
    local won = tonumber(row.wonTonight) or 0
    if won > 0 then tt:AddLine(format("Won %d item(s) tonight", won), 0.7, 0.7, 0.7) end
    AddAttendanceLine(tt, row.key)
    if row.wonCopy then
        tt:AddLine("Won another copy of this item from this drop: not suggested", Color("warn")[1], Color("warn")[2], Color("warn")[3])
    end
    if row.cantUse then
        tt:AddLine("Their class cannot use this item: never suggested", Color("bad")[1], Color("bad")[2], Color("bad")[3])
    end
    local note = ns.Store and ns.Store.GetLockNote and ns.Store:GetLockNote(row.key)
    if note then
        tt:AddLine("List changed during the lock but claims an earlier save: please check", Color("warn")[1],
            Color("warn")[2], Color("warn")[3], true)
    end
    local inRaid = row.inRaid
    if inRaid == nil then inRaid = IsInMyGroup(row.key) end
    if not inRaid then tt:AddLine("Not in your raid", 0.7, 0.7, 0.7) end
    local changed = LockChanged(row)
    if changed then AddLockChangedLine(tt, changed, "Never suggested as the winner; you can still award it.") end
    local worn = WornOfRow(row, self.itemSid)
    if #worn > 0 then tt:AddLine(WearingText(worn), 0.7, 0.7, 0.7) end
    if self.canVote then
        tt:AddLine("Click: vote, award or link the item", 0.5, 0.5, 0.5)
    else
        tt:AddLine("Click: award or link the item", 0.5, 0.5, 0.5)
    end
    tt:Show()
end

local function RowOnEnter(self)
    local tt = _G.GameTooltip
    local vp = ViewPhase()
    tt:SetOwner(self, "ANCHOR_RIGHT")
    if self.more then
        tt:AddLine(format("%d more", #self.more), 1, 0.82, 0)
        for _, x in ipairs(self.more) do
            local warn = LockChanged(x) and (" " .. WarnIcon(10)) or ""
            if self.moreKind == "roll" then
                tt:AddDoubleLine(ColoredName(x.key, x.classFile) .. warn .. " " .. TierBadge(x, vp), RollCell(x, self.session),
                    1, 1, 1, 0.8, 0.8, 0.8)
            else
                tt:AddDoubleLine(ColoredName(x.key, x.classFile) .. warn .. " " .. BadgeText(x, vp), PresenceText(x),
                    1, 1, 1, 0.6, 0.6, 0.6)
            end
        end
        tt:Show()
        return
    end
    if self.rollRow then
        RollRowTooltip(self, tt, vp)
        return
    end
    local w = self.data
    if type(w) ~= "table" then return end
    tt:AddLine(ColoredName(w.key, w.classFile))
    local specLine = ((type(w.spec) == "string" and w.spec ~= "") and (w.spec .. " ") or "") .. ClassName(w.classFile)
    tt:AddLine(specLine, 0.8, 0.8, 0.8)
    local p = tonumber(w.phase) or 0
    if w.os then
        local o = Color("offspec")
        tt:AddLine(format("Off-spec %s in P%d%s", w.which == "alt" and "alt pick" or "BiS", p,
            (type(w.spec) == "string" and w.spec ~= "") and (" (" .. w.spec .. ")") or ""), o[1], o[2], o[3])
        tt:AddLine("Ranked after main-spec wanters; an award counts as Offspec", 0.6, 0.6, 0.6, true)
    elseif w.which == "alt" then
        tt:AddLine(format("Alt pick in P%d", p), Color("alt")[1], Color("alt")[2], Color("alt")[3])
    else
        tt:AddLine(format("BiS (main) in P%d", p), Color("main")[1], Color("main")[2], Color("main")[3])
    end
    if type(w.phases) == "table" and #w.phases > 1 then
        local ps = {}
        for i, ph in ipairs(w.phases) do ps[i] = "P" .. tostring(ph) end
        tt:AddLine("Listed in " .. tconcat(ps, ", "), 0.7, 0.7, 0.7)
    end
    if w.wanted and w.wanted ~= self.itemID then
        tt:AddLine("Wants " .. ItemText(w.wanted) .. " (via this item)", 0.7, 0.7, 0.7)
    end
    tt:AddLine(w.inRaid and "In your raid" or (w.online and "Online, not in your raid" or "Offline"), 0.7, 0.7, 0.7)
    if (tonumber(w.wonTonight) or 0) > 0 then
        tt:AddLine(format("Won %d item(s) tonight", w.wonTonight), 0.7, 0.7, 0.7)
    end
    AddAttendanceLine(tt, w.key)
    if w.awarded then tt:AddLine("Already awarded this item", Color("warn")[1], Color("warn")[2], Color("warn")[3]) end
    if w.cantUse then tt:AddLine("Their class cannot use this item", Color("bad")[1], Color("bad")[2], Color("bad")[3]) end
    local changed = LockChanged(w)
    if changed then AddLockChangedLine(tt, changed, "Not suggested in rolls; the council can still award.") end
    local worn = WornOfWanter(w, self.itemSid)
    if #worn > 0 then tt:AddLine(WearingText(worn), 0.7, 0.7, 0.7) end
    if w.listTs and ns.Util and ns.Util.FormatAgo then
        tt:AddLine("List updated " .. ns.Util.FormatAgo(w.listTs), 0.5, 0.5, 0.5)
    end
    tt:Show()
end

local function RowOnClick(self)
    if self.rollRow and type(self.data) == "table" then
        DropPanel:OpenRollRowMenu(self)
    elseif self.more and self.moreKind == "roll" then
        DropPanel:OpenMoreRollMenu(self)
    end
end

local function EquippedOnEnter(self)
    if not self.itemID then return end
    local tt = _G.GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    tt:SetItemByID(self.itemID)
    tt:AddLine(self.label and ("Currently wearing (" .. self.label .. ")") or "Currently wearing", 0.6, 0.6, 0.6)
    tt:Show()
end

local function EquippedOnClick(self)
    if self.itemID and ns.UI and ns.UI.HandleModifiedItemClick then ns.UI:HandleModifiedItemClick(self.itemID) end
end

local function NewFS(parent, font, x, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetPoint("LEFT", parent, "LEFT", x, 0)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function Place(fs, parent, col)
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", parent, "LEFT", col[1], 0)
    fs:SetWidth(col[2])
end

local function NewEquippedButton(r)
    local e = CreateFrame("Button", nil, r)
    e:SetSize(EQ_SIZE, EQ_SIZE)
    e.icon = e:CreateTexture(nil, "ARTWORK")
    e.icon:SetAllPoints()
    e.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    e:SetScript("OnEnter", EquippedOnEnter)
    e:SetScript("OnLeave", HideTooltip)
    e:SetScript("OnClick", EquippedOnClick)
    e:Hide()
    return e
end

function DropPanel:NewRow(b)
    local r = CreateFrame("Button", nil, b)
    r:SetHeight(ROW_H)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.mark = r:CreateTexture(nil, "BACKGROUND")       -- suggested (gold) / winner (green) highlight
    r.mark:SetAllPoints()
    r.mark:Hide()
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    r.dot = r:CreateTexture(nil, "ARTWORK")
    r.dot:SetSize(7, 7)
    r.dot:SetPoint("LEFT", r, "LEFT", 4, 0)
    r.cls = r:CreateTexture(nil, "ARTWORK")
    r.cls:SetSize(12, 12)
    r.cls:SetPoint("LEFT", r, "LEFT", 15, 0)
    r.name = NewFS(r, "GameFontHighlightSmall", NORMAL_COLS.name[1], NORMAL_COLS.name[2])
    r.spec = NewFS(r, "GameFontDisableSmall", NORMAL_COLS.spec[1], NORMAL_COLS.spec[2])
    r.badge = NewFS(r, "GameFontHighlightSmall", NORMAL_COLS.badge[1], NORMAL_COLS.badge[2])
    r.status = NewFS(r, "GameFontDisableSmall", NORMAL_COLS.status[1], NORMAL_COLS.status[2])
    r.tag = NewFS(r, "GameFontNormalSmall", ROLL_COLS.tag[1], ROLL_COLS.tag[2])
    -- ADDENDUM G: the vote column; clicking it votes for the row's player (or takes my vote back).
    r.votes = NewFS(r, "GameFontHighlightSmall", ROLL_COLS.votes[1], ROLL_COLS.votes[2])
    r.voteBtn = CreateFrame("Button", nil, r)
    r.voteBtn:SetPoint("LEFT", r, "LEFT", ROLL_COLS.votes[1] - 2, 0)
    r.voteBtn:SetSize(ROLL_COLS.votes[2] + 2, ROLL_ROW_H)
    r.voteBtn:SetScript("OnClick", function(btn) DropPanel:ToggleVote(btn:GetParent()) end)
    r.voteBtn:SetScript("OnEnter", function(btn) RowOnEnter(btn:GetParent()) end)
    r.voteBtn:SetScript("OnLeave", HideTooltip)
    r.voteBtn:Hide()
    r.roll = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.roll:SetPoint("RIGHT", r, "RIGHT", -(2 * EQ_SIZE + 8), 0)
    r.roll:SetWidth(42)
    r.roll:SetJustifyH("RIGHT")
    r.roll:SetWordWrap(false)
    r.moreText = NewFS(r, "GameFontDisableSmall", 30, 240)
    r.layout = "normal"
    -- Two right-aligned "currently wearing" icons (paired slots show both, ADDENDUM A §18).
    r.eqs = { NewEquippedButton(r), NewEquippedButton(r) }
    r.eqs[2]:SetPoint("RIGHT", r, "RIGHT", -2, 0)
    r.eqs[1]:SetPoint("RIGHT", r.eqs[2], "LEFT", -2, 0)
    r.eq = r.eqs[2]   -- v0.1 field name (single icon); a lone item sits in the right-hand column
    r:SetScript("OnEnter", RowOnEnter)
    r:SetScript("OnLeave", HideTooltip)
    r:SetScript("OnClick", RowOnClick)
    return r
end

-- worn: array of { id=, label= } (max 2); a single item sits in the right-hand column.
local function SetEquipped(r, worn)
    local n = min(#worn, 2)
    for i = 1, 2 do
        local btn = r.eqs[i]
        local e = worn[i - (2 - n)]
        if e then
            btn.itemID, btn.label = e.id, e.label
            btn.icon:SetTexture(ItemIcon(e.id))
            btn:Show()
        else
            btn.itemID, btn.label = nil, nil
            btn:Hide()
        end
    end
end

-- mode: "normal" (BiS candidates), "roll" (roll results) or "more" ("+N more").
local function SetRowMode(r, mode)
    local more, roll = mode == "more", mode == "roll"
    r.dot:SetShown(not more)
    r.cls:SetShown(not more)
    r.name:SetShown(not more)
    r.spec:SetShown(not more)
    r.badge:SetShown(not more)
    r.status:SetShown(mode == "normal")
    r.tag:SetShown(roll)
    r.votes:SetShown(roll and IsCouncil())
    if not roll then
        r.voteBtn:Hide()
        r.canVote = nil
    end
    r.roll:SetShown(roll)
    r.moreText:SetShown(more)
    if not more and r.layout ~= mode then
        local cols = roll and ROLL_COLS or NORMAL_COLS
        Place(r.name, r, cols.name)
        Place(r.spec, r, cols.spec)
        Place(r.badge, r, cols.badge)
        if roll then Place(r.tag, r, cols.tag) else Place(r.status, r, cols.status) end
        r.layout = mode
    end
    if more then SetEquipped(r, {}) end
    r.mark:Hide()
    r.rollRow = roll
    r:SetHeight(roll and ROLL_ROW_H or ROW_H)
end

local function FillRow(r, w, itemID, vp, itemSid)
    SetRowMode(r, "normal")
    r.data, r.itemID, r.more, r.moreKind, r.session, r.itemSid = w, itemID, nil, nil, nil, itemSid
    if w.inRaid then
        r.dot:SetColorTexture(0.25, 0.85, 0.3, 1)
    elseif w.online then
        r.dot:SetColorTexture(0.95, 0.8, 0.2, 1)
    else
        r.dot:SetColorTexture(0.45, 0.45, 0.45, 1)
    end
    if ns.UI and ns.UI.ClassIcon then ns.UI:ClassIcon(r.cls, w.classFile) end
    r.name:SetText(ColoredName(w.key, w.classFile))
    r.spec:SetText(type(w.spec) == "string" and w.spec or "")
    r.badge:SetText(BadgeText(w, vp))
    local status = ""
    if w.cantUse then
        status = Paint("can't use", "bad")
    elseif not w.inRaid then
        status = "not in " .. GroupWord()
    elseif (tonumber(w.wonTonight) or 0) > 0 then
        status = "won " .. tostring(w.wonTonight)
    end
    if LockChanged(w) then
        -- §38: changed their list while the lists were locked
        status = WarnIcon(10) .. " " .. (status ~= "" and status or Paint("changed", "warn"))
    end
    r.status:SetText(status)
    SetEquipped(r, WornOfWanter(w, itemSid))
    r:SetAlpha(w.inRaid and 1 or 0.6)
    return ROW_H
end

local function FillRollRow(r, row, session, itemID, vp, itemSid)
    SetRowMode(r, "roll")
    r.data, r.itemID, r.more, r.moreKind, r.session, r.itemSid = row, itemID, nil, nil, session, itemSid
    local inRaid = row.inRaid
    if inRaid == nil then inRaid = IsInMyGroup(row.key) end
    if inRaid then
        r.dot:SetColorTexture(0.25, 0.85, 0.3, 1)
    else
        r.dot:SetColorTexture(0.45, 0.45, 0.45, 1)
    end
    local classFile = row.classFile or ClassOf(row.key)
    if ns.UI and ns.UI.ClassIcon then ns.UI:ClassIcon(r.cls, classFile) end
    -- §38 marker at the end of the name (the tag column only fits "Suggested")
    r.name:SetText(ColoredName(row.key, classFile) .. (LockChanged(row) and (" " .. WarnIcon(10)) or ""))
    r.spec:SetText(type(row.spec) == "string" and row.spec or "")
    r.badge:SetText(TierBadge(row, vp))
    r.tag:SetText(RollTag(row, session))
    local canVote = type(session) == "table" and HasRoll("CanVote") and CallRoll("CanVote", session.id) and inRaid
        and row.response ~= "pass" and true or false
    r.canVote = canVote
    r.votes:SetText(VoteCell(row, canVote))
    r.voteBtn:SetShown(canVote)
    r.roll:SetText(RollCell(row, session))
    SetEquipped(r, WornOfRow(row, itemSid))

    local winner = type(session) == "table" and session.state == "awarded" and session.winner == row.key
    if winner then
        r.mark:SetColorTexture(0.3, 0.9, 0.4, 0.16)
        r.mark:Show()
    elseif row.suggested then
        r.mark:SetColorTexture(1, 0.82, 0, 0.16)
        r.mark:Show()
    end
    local alpha = 1
    if row.response == "pass" and not tonumber(row.roll) then
        alpha = 0.5
    elseif not tonumber(row.roll) then
        alpha = 0.75
    elseif not inRaid then
        alpha = 0.6
    end
    r:SetAlpha(alpha)
    return ROLL_ROW_H
end

local function FillMoreRow(r, rest, kind, session)
    SetRowMode(r, "more")
    r.data, r.more, r.moreKind, r.session = nil, rest, kind, session
    r.moreText:SetText(format("+%d more", #rest))
    r:SetAlpha(1)
    return ROW_H
end

function DropPanel:NewBlock(parent)
    local UI = ns.UI
    local b = CreateFrame("Frame", nil, parent)
    b.rows = {}

    b.button = UI:CreateItemButton(b, 32)
    b.button:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)

    b.count = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.count:SetPoint("TOPRIGHT", b, "TOPRIGHT", -2, -3)
    b.count:SetJustifyH("RIGHT")

    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.name:SetPoint("TOPLEFT", b, "TOPLEFT", 38, -2)
    b.name:SetPoint("TOPRIGHT", b, "TOPRIGHT", -56, -2)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)

    -- Second header line: item type, or the roll state in roll mode.
    b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.sub:SetPoint("TOPLEFT", b, "TOPLEFT", 38, -19)
    b.sub:SetPoint("TOPRIGHT", b, "TOPRIGHT", -2, -19)
    b.sub:SetJustifyH("LEFT")
    b.sub:SetWordWrap(false)

    b.none = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.none:SetText("Nobody has this on their BiS list")

    b.announce = UI:CreateButton(b, "Announce", 74, 20, function() DropPanel:AnnounceItem(b.itemID) end)
    AddButtonTooltip(b.announce, function()
        if DropPanel.drop and DropPanel.drop.test then
            return "Simulated drop: the line is only printed in your chat window."
        end
        return "Announce this item and its BiS candidates in " .. GroupWord() .. " chat."
    end)
    b.award = UI:CreateButton(b, "Award...", 74, 20, function() DropPanel:OpenAwardMenu(b, b.award) end)
    AddButtonTooltip(b.award, function()
        if FakeDropLocked(DropPanel.drop) then
            return "Simulated drop: awards are disabled so the loot log stays clean. Turn on demo mode to try them."
        end
        if DropPanel.drop and DropPanel.drop.test then
            return "Demo mode: awards go to a temporary demo log that is never saved or sent."
        end
        local s = b.rollSession
        if type(s) == "table" and (s.state == "open" or s.state == "closed") then
            return "Award this item: closes its roll and everyone's Roll / Pass popup, "
                .. "and records the award in the loot log."
        end
        if not IsCouncil() then return "Only loot council members can record awards in the loot log." end
        return "Record who received this item in the loot log."
    end)

    b.rollBtn = UI:CreateButton(b, "Roll", 54, 20, function() DropPanel:StartRoll(b.itemID, b.copy) end)
    AddButtonTooltip(b.rollBtn, function()
        local text = "Start a roll: everyone in the " .. GroupWord() .. " gets a Roll / Pass popup (a normal /roll 1-100). "
            .. "DisasterZone suggests the winner: BiS main first, then BiS alt, then everyone else; "
            .. "the highest roll wins within each group. You confirm the award."
        if DemoEnabled() then text = text .. "\n\nDemo mode: fake raiders roll; nothing is sent." end
        return text
    end)
    b.endRoll = UI:CreateButton(b, "End roll", 70, 20, function() DropPanel:EndRoll(b.rollSession) end)
    AddButtonTooltip(b.endRoll, function()
        return "Close the roll now. Rolls that arrive afterwards are ignored."
    end)
    b.awardRoll = UI:CreateButton(b, "Award", 110, 20, function() DropPanel:AwardSuggested(b) end)
    AddButtonTooltip(b.awardRoll, function() return DropPanel:AwardSuggestedTooltip(b) end)
    b.reroll = UI:CreateButton(b, "Re-roll", 64, 20, function() DropPanel:ConfirmReroll(b) end)
    AddButtonTooltip(b.reroll, function()
        return "Start a new roll for this item (for example after a tie or when nobody rolled). "
            .. "The rolls so far are discarded."
    end)
    b.unqueue = UI:CreateButton(b, "Cancel roll", 86, 20, function() DropPanel:EndRoll(b.queuedSession) end)
    AddButtonTooltip(b.unqueue, function()
        return "Take this item out of the roll queue."
    end)
    -- ADDENDUM G §41: one click to the guild's (or this raid's) disenchanter / guild bank character.
    b.deBtn = UI:CreateButton(b, "DE", 40, 20, function() DropPanel:AwardToTarget(b, "de") end)
    AddButtonTooltip(b.deBtn, function() return DropPanel:TargetTooltip("de") end)
    b.bankBtn = UI:CreateButton(b, "Bank", 50, 20, function() DropPanel:AwardToTarget(b, "bank") end)
    AddButtonTooltip(b.bankBtn, function() return DropPanel:TargetTooltip("bank") end)
    b.actionButtons = { b.announce, b.award, b.rollBtn, b.endRoll, b.awardRoll, b.reroll, b.unqueue, b.deBtn, b.bankBtn }

    b.awarded = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.awarded:SetJustifyH("LEFT")
    b.awarded:SetWordWrap(false)

    b.sep = b:CreateTexture(nil, "ARTWORK")
    b.sep:SetColorTexture(1, 1, 1, 0.12)
    b.sep:SetHeight(1)
    b.sep:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, -BLOCK_GAP / 2)
    b.sep:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, -BLOCK_GAP / 2)
    return b
end

function DropPanel:GetRow(b, i)
    local r = b.rows[i]
    if not r then
        r = self:NewRow(b)
        b.rows[i] = r
    end
    return r
end

local function PlaceRow(r, b, y)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -y)
    r:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, -y)
    r:Show()
end

-- Shows `buttons` left to right on the action line (y) and puts the "Awarded to" text after them.
local function LayoutActions(b, y, buttons, blockW)
    for _, btn in ipairs(b.actionButtons) do
        btn:Hide()
        btn:ClearAllPoints()
    end
    local x = 36
    for _, btn in ipairs(buttons) do
        btn:SetPoint("TOPLEFT", b, "TOPLEFT", x, -y)
        btn:Show()
        x = x + (btn:GetWidth() or 60) + 4
    end
    if #buttons > 0 then x = x + 2 end
    b.awarded:ClearAllPoints()
    b.awarded:SetPoint("TOPLEFT", b, "TOPLEFT", x, -(y + 4))
    b.awarded:SetWidth(max(60, (tonumber(blockW) or (PANEL_W - 46)) - x - 2))
end

-- open: the roll is still open, so the click ends it for everyone first (the label says so).
local function SetAwardRollButton(btn, row, open)
    if row then
        btn:SetText((open and "End roll & award to " or "Award to ") .. ShortName(row.key))
        btn:Enable()
    else
        btn:SetText("Award")
        btn:Disable()
    end
    local fs = btn.GetFontString and btn:GetFontString()
    local w = fs and tonumber(fs:GetStringWidth()) or 0
    btn:SetWidth(min(open and 200 or 170, max(96, w + 24)))
end

-- Paints one item block; returns its height. copy: which copy of itemID in the drop (1 = first).
function DropPanel:FillBlock(b, itemID, award, drop, vp, canRoll, copy)
    b.itemID = itemID
    b.copy = copy
    b.awardEntry = award
    b.button:SetItem(itemID)
    b.name:SetText(ItemText(itemID))

    local session, mode, queuePos = RollStateFor(itemID, drop, copy)
    local rolling = mode == "roll" and session ~= nil
    b.rollSession = rolling and session or nil
    b.queuedSession = (mode == "queued") and session or nil
    b.rollStats, b.suggested, b.results = nil, nil, nil
    local winnerKey = award and award.w
        or (rolling and session.state == "awarded" and type(session.winner) == "string" and session.winner) or nil
    b.button:SetState(winnerKey and "awarded" or nil)
    local itemSid = FirstSlotOfItem(itemID)

    -- Roll mode lists roll results; the Award... menu then fetches the wanters itself.
    local wanters = (not rolling) and UniqueWanters(itemID, { includeObtained = false, list = "both" }) or nil
    b.wanters = wanters

    local y, rowIdx, n = ITEM_HEAD_H, 0, 0
    local noneText = "Nobody has this on their BiS list"
    if rolling then
        local results = {}
        local raw = CallRoll("GetResults", session.id)
        if type(raw) == "table" then
            for _, row in ipairs(raw) do
                if type(row) == "table" and type(row.key) == "string" then results[#results + 1] = row end
            end
        end
        b.results = results
        local rolled, passed, tie, votes = RollCounts(results)
        b.rollStats = { rolled = rolled, passed = passed, tie = tie, votes = votes }
        for _, row in ipairs(results) do
            if row.suggested then
                b.suggested = row
                break
            end
        end
        n = #results
        b.count:SetText("")
        b.sub:SetText(RollStateText(session, b.rollStats))
        -- "+N more" only when it hides at least two rows.
        local limit = (n > MAX_ROLL_ROWS + 1) and MAX_ROLL_ROWS or n
        for i = 1, limit do
            rowIdx = rowIdx + 1
            local r = self:GetRow(b, rowIdx)
            local h = FillRollRow(r, results[i], session, itemID, vp, itemSid)
            PlaceRow(r, b, y)
            y = y + h
        end
        if n > limit then
            rowIdx = rowIdx + 1
            local rest = {}
            for i = limit + 1, n do rest[#rest + 1] = results[i] end
            local r = self:GetRow(b, rowIdx)
            local h = FillMoreRow(r, rest, "roll", session)
            PlaceRow(r, b, y)
            y = y + h
        end
        noneText = session.state == "open" and "Waiting for rolls..." or "Nobody rolled"
        if session.state == "open" then
            -- While the roll is open, keep room for all rows (up to MAX_ROLL_ROWS + "+N more", at most the group
            -- size): incoming rolls must not move End roll / Award (or the panel) under the cursor.
            local groupN = tonumber((_G.GetNumGroupMembers and _G.GetNumGroupMembers())) or 0
            local reserve = min(MAX_ROLL_ROWS + 1, max(1, groupN))
            b.reservedY = ITEM_HEAD_H + reserve * ROLL_ROW_H
        else
            b.reservedY = nil
        end
    else
        b.reservedY = nil
        n = #wanters
        local nOS = 0
        for _, w in ipairs(wanters) do
            if w.os then nOS = nOS + 1 end
        end
        local nMS = n - nOS
        -- Addendum H: "3 want", plus the off-spec wanters listed after them ("3 want +2 OS").
        local countText = nMS > 0 and (nMS .. " want") or ""
        if nOS > 0 then countText = countText .. (countText ~= "" and " " or "") .. Paint("+" .. nOS .. " OS", "offspec") end
        b.count:SetText(countText)
        if mode == "queued" then
            b.sub:SetText(RollStateText(nil, nil, queuePos or 1))
        else
            b.sub:SetText(ItemSubtitle(itemID))
        end
        local limit = (n > MAX_ROWS + 1) and MAX_ROWS or n
        for i = 1, limit do
            rowIdx = rowIdx + 1
            local r = self:GetRow(b, rowIdx)
            local h = FillRow(r, wanters[i], itemID, vp, itemSid)
            PlaceRow(r, b, y)
            y = y + h
        end
        if n > limit then
            rowIdx = rowIdx + 1
            local rest = {}
            for i = limit + 1, n do rest[#rest + 1] = wanters[i] end
            local r = self:GetRow(b, rowIdx)
            local h = FillMoreRow(r, rest, "wanters")
            PlaceRow(r, b, y)
            y = y + h
        end
    end
    for i = rowIdx + 1, #b.rows do b.rows[i]:Hide() end

    if n == 0 then
        b.none:SetText(noneText)
        b.none:ClearAllPoints()
        b.none:SetPoint("TOPLEFT", b, "TOPLEFT", 38, -(y + 3))
        b.none:Show()
        y = y + ROW_H
    else
        b.none:Hide()
    end

    if b.reservedY and y < b.reservedY then y = b.reservedY end
    -- Action line.
    y = y + 3
    local manage = canRoll or IsCouncil()
    local buttons = {}
    if rolling then
        if not winnerKey then
            local canAward = RollAllows("CanAward", manage)
            if session.state == "open" then
                if RollAllows("CanEnd", manage, session.id) then buttons[#buttons + 1] = b.endRoll end
                if canAward then buttons[#buttons + 1] = b.awardRoll end
            elseif canAward then
                buttons[#buttons + 1] = b.suggested and b.awardRoll or b.award
                if b.suggested then buttons[#buttons + 1] = b.award end   -- someone else (e.g. a "+N more" row)
                if canRoll then buttons[#buttons + 1] = b.reroll end
            end
            SetAwardRollButton(b.awardRoll, b.suggested, session.state == "open")
        end
    else
        buttons[1] = b.announce
        buttons[2] = b.award
        if mode == "normal" and canRoll and not winnerKey then
            buttons[3] = b.rollBtn
        elseif mode == "queued" and b.queuedSession and RollAllows("CanEnd", manage, b.queuedSession.id) then
            buttons[3] = b.unqueue
        end
    end
    -- Award...: the council records it in the log; an item with an open / closed roll can also be awarded
    -- by whoever may award rolls (master looter, leader), because the award then goes through the roll.
    local rollAwardable = rolling and not winnerKey and (session.state == "open" or session.state == "closed")
    local canAwardItem = IsCouncil() or (rollAwardable and RollAllows("CanAward", manage))
    -- DE / Bank (ADDENDUM G §41): while nobody is picked (no roll, or a roll without a suggestion) and a target is
    -- set; the Award... menu has them too.
    if not winnerKey and not FakeDropLocked(drop) and (mode == "normal" or (rolling and not b.suggested))
        and (canAwardItem or CanMasterLoot(itemID)) then
        for _, kind in ipairs({ "de", "bank" }) do
            local key = LootTarget(kind)
            if key then
                local btn = kind == "de" and b.deBtn or b.bankBtn
                buttons[#buttons + 1] = btn
                if IsInMyGroup(key) then btn:Enable() else btn:Disable() end
            end
        end
    end
    if rolling and type(session.lootOther) == "string" and IsCouncil() and not buttons[1] then
        buttons[1] = b.award   -- the fix of a loot-message conflict lives in the Award... menu
    end
    if FakeDropLocked(drop) or not canAwardItem then b.award:Disable() else b.award:Enable() end
    LayoutActions(b, y, buttons, self.child and self.child:GetWidth())
    if winnerKey then
        local t = Paint("Awarded to ", "obtained") .. ColoredName(winnerKey)
        local label = ReasonLabel(award and award.r or (rolling and session.reason) or nil)
        if label then t = t .. Paint(" · " .. label, "muted") end
        if rolling and session.state == "awarded" and session.via == "loot" and session.winner == winnerKey then
            t = t .. Paint(" (looted)", "muted")
        end
        if rolling and type(session.lootOther) == "string" then
            -- The loot message named someone else (0.5): the Award... menu offers the fix.
            t = t .. Paint(" · loot: ", "warn") .. ColoredName(session.lootOther)
        end
        b.awarded:SetText(t)
    else
        b.awarded:SetText("")
    end
    b:SetAlpha((n == 0 and not winnerKey and not rolling) and 0.75 or 1)
    return y + ACTION_H + 4
end

---------------------------------------------------------------------------
-- Rolls: start / end / award (all through ns.Roll)
---------------------------------------------------------------------------
-- copy (optional): which copy of the item in the drop (duplicates roll separately).
function DropPanel:StartRoll(itemID, copy)
    local drop = self.drop
    if not itemID or type(drop) ~= "table" then return end
    if FakeDropLocked(drop) then
        ns:Print("Simulated drop: turn on demo mode (/dz demo) to try rolls.")
        return
    end
    if not HasRoll("Start") then
        ns:Print("Rolls are not available.")
        return
    end
    if not CanStartRolls(drop) then
        ns:Print("Only loot council members, the master looter or the raid leader / assistants can start rolls.")
        return
    end
    CallRoll("Start", itemID, drop, copy)
    self:RequestRefresh(0.1)
end

function DropPanel:RollAll()
    local drop = self.drop
    if type(drop) ~= "table" then return end
    if FakeDropLocked(drop) then
        ns:Print("Simulated drop: turn on demo mode (/dz demo) to try rolls.")
        return
    end
    if not CanStartRolls(drop) or not HasRoll("StartAll") then
        ns:Print("Only loot council members, the master looter or the raid leader / assistants can start rolls.")
        return
    end
    CallRoll("StartAll", drop)
    self:RequestRefresh(0.1)
end

-- Re-roll of a closed roll: asks first when rolls would be thrown away.
function DropPanel:ConfirmReroll(b)
    local s = b and b.rollSession
    local rolled = b and b.rollStats and tonumber(b.rollStats.rolled) or 0
    if type(s) ~= "table" or rolled == 0 or not _G.StaticPopup_Show then
        self:StartRoll(b.itemID, b.copy)
        return
    end
    local dialogs = _G.StaticPopupDialogs
    if dialogs and not dialogs.DISASTERZONE_REROLL then
        dialogs.DISASTERZONE_REROLL = {
            text = "Start a new roll for %s?\n(%s so far are discarded)",
            button1 = "Re-roll",
            button2 = _G.CANCEL or "Cancel",
            OnAccept = function(_, data)
                if type(data) == "table" then DropPanel:StartRoll(data.itemID, data.copy) end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    _G.StaticPopup_Show("DISASTERZONE_REROLL", ItemLink(b.itemID) or ItemName(b.itemID),
        rolled == 1 and "1 roll" or (rolled .. " rolls"), { itemID = b.itemID, copy = b.copy })
end

function DropPanel:EndRoll(session)
    if type(session) ~= "table" or type(session.id) ~= "string" then return end
    CallRoll("End", session.id)
    self:RequestRefresh(0.1)
end

-- reason (optional, ADDENDUM G): an award reason key; nil = from the winner's BiS tier.
function DropPanel:AwardRoll(sessionID, key, reason)
    if type(sessionID) ~= "string" or type(key) ~= "string" then return end
    CallRoll("Award", sessionID, key, reason)
    self:RequestRefresh(0.1)
end

-- The vote column of a roll row: vote for its player, or take my vote back (ADDENDUM G §42).
function DropPanel:ToggleVote(r)
    local row, session = r and r.data, r and r.session
    if type(row) ~= "table" or type(session) ~= "table" or not HasRoll("Vote") then return end
    CallRoll("Vote", session.id, row.key)
    self:RequestRefresh(0.05)
end

-- Adds "<prefix> as ▸" with every award reason to a menu; fn(reasonKey) awards.
local function AddReasonSubmenu(root, text, fn)
    local sub = root:CreateButton(text)
    for _, r in ipairs(ns.AWARD_REASONS or {}) do
        local rk = r.key
        sub:CreateButton(r.label, function() fn(rk) end)
    end
    return sub
end

function DropPanel:AwardSuggested(b)
    local s, row = b and b.rollSession, b and b.suggested
    if type(s) ~= "table" or type(row) ~= "table" then return end
    self:AwardRoll(s.id, row.key)
end

function DropPanel:AwardSuggestedTooltip(b)
    local row = b and b.suggested
    if type(row) ~= "table" then return "Nobody has a valid roll or a council vote yet." end
    local parts = {}
    if row.suggestedBy == "votes" then parts[#parts + 1] = VotesText(row.votes) end
    local n = tonumber(row.roll)
    if n then parts[#parts + 1] = "rolled " .. n end
    parts[#parts + 1] = TierWord(row)
    local won = tonumber(row.wonTonight) or 0
    if won > 0 then parts[#parts + 1] = format("won %d tonight", won) end
    local text = format("Award to %s (%s).", ShortName(row.key), tconcat(parts, ", "))
    if row.tie then
        local tied = {}
        for _, r in ipairs(b.results or {}) do
            if r.tie then tied[#tied + 1] = ShortName(r.key) end
        end
        text = text .. "\n\nTie between " .. tconcat(tied, ", ") .. ": click a row to pick someone else, or re-roll."
    end
    local s = b.rollSession
    if s and s.state == "open" then
        text = text .. "\n\nThe roll is still open: this ends it for everyone right away (Cancel in the next "
            .. "window does not reopen it)."
    end
    return text .. "\n\nAs master looter with the loot window open, DisasterZone hands the item over after a "
        .. "confirmation. Otherwise the award is recorded and announced."
end

function DropPanel:OpenRollRowMenu(r)
    local row, session = r and r.data, r and r.session
    if type(row) ~= "table" or type(session) ~= "table" or not (ns.UI and ns.UI.ContextMenu) then return end
    local key, itemID, id = row.key, r.itemID, session.id
    local canAward = (session.state == "open" or session.state == "closed")
        and RollAllows("CanAward", IsCouncil() or CanStartRolls(self.drop))
    local open = session.state == "open"
    local canVote = r.canVote
    ns.UI:ContextMenu(r, function(root)
        root:CreateTitle(ShortName(key))
        if canVote then
            root:CreateButton(row.myVote and "Remove my vote" or ("Vote for " .. ShortName(key)), function()
                CallRoll("Vote", id, key)
                DropPanel:RequestRefresh(0.05)
            end)
        end
        if canAward then
            local verb = (open and "End roll & award to " or "Award to ") .. ShortName(key)
            root:CreateButton(verb, function() DropPanel:AwardRoll(id, key) end)
            AddReasonSubmenu(root, verb .. " as", function(rk) DropPanel:AwardRoll(id, key, rk) end)
        end
        root:CreateButton("Link item", function() LinkItem(itemID) end)
    end)
end

-- The "+N more" row of roll results: each hidden roller can be awarded from here too.
function DropPanel:OpenMoreRollMenu(r)
    local rest, session = r and r.more, r and r.session
    if type(rest) ~= "table" or type(session) ~= "table" or not (ns.UI and ns.UI.ContextMenu) then return end
    local canAward = (session.state == "open" or session.state == "closed")
        and RollAllows("CanAward", IsCouncil() or CanStartRolls(self.drop))
    if not canAward then return end
    local id, vp = session.id, ViewPhase()
    local open = session.state == "open"
    ns.UI:ContextMenu(r, function(root)
        root:CreateTitle(format("%d more", #rest))
        for _, x in ipairs(rest) do
            local key = x.key
            root:CreateButton((open and "End roll & award to " or "Award to ") .. ColoredName(key, x.classFile)
                .. " " .. TierBadge(x, vp) .. " " .. RollCell(x, session), function() DropPanel:AwardRoll(id, key) end)
        end
    end)
end

---------------------------------------------------------------------------
-- Announce & award
---------------------------------------------------------------------------
function DropPanel:BuildAnnounceLine(itemID)
    local link = ItemLink(itemID) or ItemName(itemID)
    local wanters = UniqueWanters(itemID, { includeObtained = false, list = "both" })
    local inGroup = _G.IsInGroup and _G.IsInGroup()
    local mains, alts, offs = {}, {}, {}
    for _, w in ipairs(wanters) do
        if w.inRaid or not inGroup then
            if w.os then
                offs[#offs + 1] = ShortName(w.key)
            elseif w.which == "alt" then
                alts[#alts + 1] = ShortName(w.key)
            else
                mains[#mains + 1] = ShortName(w.key)
            end
        end
    end
    local parts = {}
    if #mains > 0 then parts[#parts + 1] = "BiS: " .. tconcat(mains, ", ") end
    if #alts > 0 then parts[#parts + 1] = "Alt: " .. tconcat(alts, ", ") end
    if #offs > 0 then parts[#parts + 1] = "OS: " .. tconcat(offs, ", ") end
    if #parts == 0 then return format("DisasterZone: %s - not on anyone's BiS list", link) end
    return format("DisasterZone: %s - %s", link, tconcat(parts, "; "))
end

-- test: nil = use the currently shown drop's flag.
function DropPanel:AnnounceItem(itemID, test)
    if not itemID then return false end
    if test == nil then test = self.drop and self.drop.test end
    local now = GetTime()
    local last = self.lastAnnounce[itemID]
    if last and now - last < ANNOUNCE_COOLDOWN then return false end
    self.lastAnnounce[itemID] = now
    local line = self:BuildAnnounceLine(itemID)
    if test then
        ns:Print("[simulated, not sent] " .. line)
    elseif DemoEnabled() then
        ns:Print("[demo, not sent] %s", line)   -- the wanters are fake demo members
    elseif ns.UI and ns.UI.AnnounceLine then
        ns.UI:AnnounceLine(line)
    end
    return true
end

function DropPanel:AnnounceAll()
    local drop = self.drop
    if type(drop) ~= "table" then return end
    local test = drop.test and true or false
    local seen, n = {}, 0
    for _, id in ipairs(SanitizeItems(drop.i)) do
        if not seen[id] then
            seen[id] = true
            local delay = n * 0.4
            n = n + 1
            if delay == 0 then
                self:AnnounceItem(id, test)
            else
                C_Timer.After(delay, function() DropPanel:AnnounceItem(id, test) end)
            end
        end
    end
end

local function IsResolvable(session)
    return type(session) == "table" and (session.state == "open" or session.state == "closed")
end

-- Resolved only by a loot message (ADDENDUM C §23.1): handed out, but nobody recorded the award yet.
-- An explicit award still goes through the roll (it records + announces it).
local function IsLootMarked(session)
    return type(session) == "table" and session.state == "awarded" and session.via == "loot"
end

local function NormalKey(key)
    return (ns.Util and ns.Util.NormalizeName and ns.Util.NormalizeName(key)) or key
end

-- The roll session an award of itemID from `drop` goes through (ADDENDUM C §23.2): the session of that
-- copy of the item when `copy` is given; else the lowest copy with an open / closed roll, then the
-- lowest loot-marked one, then the lowest queued one. nil when the drop has no such roll for the item.
function DropPanel:FindRollSession(itemID, drop, copy)
    itemID = tonumber(itemID)
    if not itemID or type(drop) ~= "table" or FakeDropLocked(drop) or not HasRoll("GetForItem") then return nil end
    local copies = 0
    for _, id in ipairs(SanitizeItems(drop.i)) do
        if id == itemID then copies = copies + 1 end
    end
    if copies == 0 then return nil end
    local function sessionOf(c)
        local s = CallRoll("GetForItem", itemID, drop.s, c)
        if type(s) == "table" and type(s.id) == "string" and s.i == itemID then return s end
        return nil
    end
    copy = tonumber(copy)
    if copy then
        local s = sessionOf(copy)
        if IsResolvable(s) or IsLootMarked(s) or (s and s.state == "queued") then return s end
        return nil
    end
    local looted, queued
    for c = 1, copies do
        local s = sessionOf(c)
        if IsResolvable(s) then return s end
        if IsLootMarked(s) and not looted then looted = s end
        if s and s.state == "queued" and not queued then queued = s end
    end
    return looted or queued
end

-- Awards itemID to key. copy / drop (optional) say which copy of which drop it is; drop nil = the drop
-- shown in the panel (when it holds the item and the boss matches), false = no drop context (plain log
-- entry). When that drop copy has an open / closed (or loot-marked) roll, the award goes through the
-- roll: Roll:MarkAwardedExternally records the one log entry (council clients), sends RW and announces,
-- and everyone's popup closes. Otherwise the council records it in the loot log (a queued roll of the
-- copy is then cancelled). Exactly one log entry either way. Returns true, or false plus a reason.
-- awardReason (optional, ADDENDUM G): an ns.AWARD_REASONS key; nil = the roll's default (tier) or none.
function DropPanel:Award(itemID, key, bossKey, copy, drop, note, awardReason)
    itemID = tonumber(itemID)
    if not itemID or type(key) ~= "string" or key == "" then return false, "No item or winner." end
    if drop == nil then drop = self.drop end
    if type(drop) == "table" and type(bossKey) == "string" and bossKey ~= ""
        and type(drop.b) == "string" and drop.b ~= "" and drop.b ~= bossKey then
        drop = nil    -- another boss's drop: no roll context
    end
    local session = type(drop) == "table" and self:FindRollSession(itemID, drop, copy) or nil

    if (IsResolvable(session) or IsLootMarked(session)) and HasRoll("MarkAwardedExternally") then
        local id = session.id
        local done = CallRoll("MarkAwardedExternally", id, key, note, awardReason)
        local now = CallRoll("Get", id)
        if type(now) ~= "table" then now = session end
        self:RequestRefresh(0.1)
        local recorded = now.state == "awarded" and now.via ~= "loot"
        if done == true or (recorded and (now.winner == key or now.winner == NormalKey(key))) then
            ns:Print("Awarded %s to %s (roll closed).", ItemLink(itemID) or ItemName(itemID), ShortName(key))
            return true
        end
        if recorded then
            return false, "Already awarded to " .. ShortName(now.winner) .. "."
        end
        -- Not taken by the roll (no permission, roll gone or failed): a plain log entry below.
    end

    if not (ns.Ledger and ns.Ledger.Award) then return false, "The award log is not available." end
    if not IsCouncil() then
        ns:Print("Only Loot Council members can record awards.")
        return false, "Could not record the award (council members only)."
    end
    local entry = ns.Ledger:Award(itemID, key, (type(bossKey) == "string" and bossKey) or "", note, nil, awardReason)
    if not entry then return false, "Could not record the award." end
    local label = ReasonLabel(awardReason)
    ns:Print("Recorded award: %s to %s%s.", ItemLink(itemID) or ItemName(itemID), ShortName(key),
        label and (" (" .. label .. ")") or "")
    if type(session) == "table" and session.state == "queued" then
        CallRoll("End", session.id)   -- handed out already: its queued roll must not start
    end
    self:RequestRefresh(0.1)
    return true
end

function DropPanel:AwardByName(data, text)
    if type(data) ~= "table" or not data.itemID then return end
    local key = ResolvePlayer(text)
    if not key then
        ns:Print("Type the name of the character who received the item.")
        return
    end
    self:Award(data.itemID, key, data.bossKey, data.copy, data.drop)
end

local function EnsureAwardPopup()
    local dialogs = _G.StaticPopupDialogs
    if not dialogs or dialogs.DISASTERZONE_AWARD_OTHER then return end
    dialogs.DISASTERZONE_AWARD_OTHER = {
        text = "Record %s as awarded to (character name):",
        button1 = _G.ACCEPT or "Accept",
        button2 = _G.CANCEL or "Cancel",
        hasEditBox = 1,
        maxLetters = 48,
        OnShow = function(self)
            local eb = PopupEditBox(self)
            if eb then
                eb:SetText("")
                eb:SetFocus()
            end
        end,
        OnAccept = function(self, data)
            local eb = PopupEditBox(self)
            DropPanel:AwardByName(data or self.data, eb and eb:GetText())
        end,
        EditBoxOnEnterPressed = function(editBox)
            local popup = editBox:GetParent()
            DropPanel:AwardByName(popup and popup.data, editBox:GetText())
            if popup then popup:Hide() end
        end,
        EditBoxOnEscapePressed = function(editBox)
            local popup = editBox:GetParent()
            if popup then popup:Hide() end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

-- copy / drop: the drop copy the award belongs to (see DropPanel:Award); both optional.
function DropPanel:AwardSomeoneElse(itemID, bossKey, copy, drop)
    -- Prefer the Loot Log award dialog when that module offers one; its Save comes back here, so an
    -- award of this item still goes through its roll (a different item typed there is a plain entry).
    local log = ns.LootLogUI
    if log and type(log.OpenAwardDialog) == "function" then
        local wantID = tonumber(itemID)
        log:OpenAwardDialog(itemID, nil, bossKey, nil, {
            onSave = function(id, key, boss, note, reason)
                if wantID and tonumber(id) == wantID then
                    return DropPanel:Award(id, key, boss, copy, drop, note, reason)
                end
                return DropPanel:Award(id, key, boss, nil, false, note, reason)
            end,
        })
        return
    end
    EnsureAwardPopup()
    if _G.StaticPopup_Show then
        _G.StaticPopup_Show("DISASTERZONE_AWARD_OTHER", ItemLink(itemID) or ItemName(itemID), nil,
            { itemID = itemID, bossKey = bossKey, copy = copy, drop = drop })
    end
end

---------------------------------------------------------------------------
-- Disenchanter / guild bank (ADDENDUM G §41)
---------------------------------------------------------------------------
local TARGET_LABELS = { de = "Disenchant", bank = "Guild bank" }
local TARGET_WHO = { de = "disenchanter", bank = "guild bank character" }

function DropPanel:TargetTooltip(kind)
    local key, src = nil, nil
    if ns.Guild and ns.Guild.GetLootTarget then key, src = ns.Guild:GetLootTarget(kind) end
    if not key then return "No " .. TARGET_WHO[kind] .. " is set (Council > Loot Council)." end
    local from = (src == "raid" and "set by the raid leader for this raid")
        or (src == "demo" and "demo mode stand-in") or "set by the Guild Master"
    local text = format("%s: give this item to %s (%s).\nRecorded as \"%s\": not counted as loot received.",
        TARGET_LABELS[kind], ShortName(key), from, TARGET_LABELS[kind])
    if not IsInMyGroup(key) then
        text = text .. "\n\n" .. ShortName(key) .. " is not in your " .. GroupWord() .. "."
    end
    return text
end

-- One step of the non-roll hand-out: master looter -> give with master loot after a confirmation, then record;
-- anyone else -> record (council).
local function EnsureTargetPopups()
    local dialogs = _G.StaticPopupDialogs
    if not dialogs or dialogs.DISASTERZONE_GIVE_TARGET then return end
    dialogs.DISASTERZONE_GIVE_TARGET = {
        text = "Give %s to %s?",
        button1 = "Give",
        button2 = _G.CANCEL or "Cancel",
        OnAccept = function(self, data) DropPanel:GiveToTarget(data or self.data) end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    dialogs.DISASTERZONE_RECORD_TARGET = {
        text = "Award %s to %s anyway?\n(hand it out via master loot or trade)",
        button1 = "Award",
        button2 = _G.CANCEL or "Cancel",
        OnAccept = function(self, data)
            data = data or self.data
            if type(data) == "table" then
                local ok, why = DropPanel:Award(data.itemID, data.key, data.bossKey, data.copy, data.drop, nil, data.kind)
                if not ok and why then ns:Print("%s", why) end
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

function DropPanel:GiveToTarget(data)
    if type(data) ~= "table" then return end
    local Loot = ns.Loot
    local function fallback(why)
        ns:Print("Could not hand %s to %s: %s.", ItemLink(data.itemID) or ItemName(data.itemID), ShortName(data.key),
            tostring(why or "unknown error"))
        EnsureTargetPopups()
        if _G.StaticPopup_Show then
            _G.StaticPopup_Show("DISASTERZONE_RECORD_TARGET", ItemLink(data.itemID) or ItemName(data.itemID),
                ColoredName(data.key), data)
        end
    end
    if not (Loot and Loot.GiveItem) then return fallback("master loot is not available") end
    local ok, why = Loot:GiveItem(data.itemID, data.key, function(done, reason)
        if done then
            local okAward, whyAward = DropPanel:Award(data.itemID, data.key, data.bossKey, data.copy, data.drop, nil, data.kind)
            if not okAward and whyAward then ns:Print("%s", whyAward) end
        else
            fallback(reason)
        end
    end)
    if ok == false then fallback(why) end
end

-- DE / Bank buttons (and the Award... menu entries): award the item of block b to the target character.
function DropPanel:AwardToTarget(b, kind)
    local itemID, drop = b and b.itemID, self.drop
    local key = LootTarget(kind)
    if not itemID or type(drop) ~= "table" then return end
    if not key then
        ns:Print("No %s is set: the Guild Master (or the raid leader, for a raid) picks one in Council > Loot Council.",
            TARGET_WHO[kind] or kind)
        return
    end
    if FakeDropLocked(drop) then
        ns:Print("Simulated drop: turn on demo mode (/dz demo) to try awards.")
        return
    end
    local bossKey = type(drop.b) == "string" and drop.b or ""
    -- An item with a roll: through the roll (master-loot give or confirm popup; closes everyone's popup).
    local session = self:FindRollSession(itemID, drop, b.copy)
    if (IsResolvable(session) or IsLootMarked(session)) and HasRoll("Award") then
        self:AwardRoll(session.id, key, kind)
        return
    end
    -- Master looter with the item in the loot window: hand it over, then record.
    if not drop.test and CanMasterLoot(itemID) then
        EnsureTargetPopups()
        if _G.StaticPopup_Show then
            _G.StaticPopup_Show("DISASTERZONE_GIVE_TARGET", ItemLink(itemID) or ItemName(itemID),
                ColoredName(key) .. " (" .. TARGET_LABELS[kind] .. ")",
                { itemID = itemID, key = key, kind = kind, bossKey = bossKey, copy = b.copy, drop = drop })
        end
        return
    end
    local ok, why = self:Award(itemID, key, bossKey, b.copy, drop, nil, kind)
    if not ok and why then ns:Print("%s", why) end
end

function DropPanel:OpenAwardMenu(b, owner)
    local itemID, drop = b.itemID, self.drop
    if not itemID or type(drop) ~= "table" or not (ns.UI and ns.UI.ContextMenu) then return end
    local bossKey = type(drop.b) == "string" and drop.b or ""
    local copy = b.copy
    local vp = ViewPhase()
    -- Fetched when the menu opens (the group may have changed since the panel was painted).
    local wanters = UniqueWanters(itemID, { includeObtained = false, list = "both" })
    local awardEntry = b.awardEntry
    local conflict = b.rollSession and type(b.rollSession.lootOther) == "string" and b.rollSession or nil
    local function award(key, reason) DropPanel:Award(itemID, key, bossKey, copy, drop, nil, reason) end
    local inGroup = _G.IsInGroup and _G.IsInGroup()
    local awarded = type(awardEntry) == "table" and awardEntry.id and not awardEntry.vd
    ns.UI:ContextMenu(owner, function(root)
        root:CreateTitle("Award " .. ItemName(itemID))
        -- ADDENDUM G: the reason of the recorded award can be changed (it decides whether it counts as loot won).
        if awarded and IsCouncil() and ns.Ledger and ns.Ledger.SetReason then
            local id = awardEntry.id
            local cur = ReasonLabel(awardEntry.r) or "none"
            local sub = root:CreateButton("Reason: " .. cur)
            for _, r in ipairs(ns.AWARD_REASONS or {}) do
                local rk = r.key
                sub:CreateButton((awardEntry.r == rk and "* " or "") .. r.label, function() ns.Ledger:SetReason(id, rk) end)
            end
            root:CreateDivider()
        end
        -- The disenchanter / guild bank character (ADDENDUM G §41), when set.
        if not awarded then
            local any = false
            for _, kind in ipairs({ "de", "bank" }) do
                local key = LootTarget(kind)
                if key then
                    any = true
                    local label = kind == "de" and "Disenchant" or "Guild bank"
                    local text = label .. ": " .. ColoredName(key)
                    if not IsInMyGroup(key) then text = text .. Paint(" (not in " .. GroupWord() .. ")", "muted") end
                    root:CreateButton(text, function() DropPanel:AwardToTarget(b, kind) end)
                end
            end
            if any then root:CreateDivider() end
        end
        if conflict and IsCouncil() and HasRoll("ResolveLootConflict") then
            -- The loot message named someone else than the recorded winner (DisasterZone 0.5).
            local id, other, winner = conflict.id, conflict.lootOther, conflict.winner
            root:CreateButton(Paint(ShortName(other) .. " passes it to " .. ShortName(winner), "warn"),
                function() CallRoll("ResolveLootConflict", id, "passing") end)
            root:CreateButton(Paint(ShortName(other) .. " keeps it (void the award to " .. ShortName(winner) .. ")", "warn"),
                function() CallRoll("ResolveLootConflict", id, "keeps") end)
            root:CreateDivider()
        end
        -- Players who are here first; wanters who are not in the group (offline, elsewhere) are kept apart: an award
        -- to them can't be handed out, and a misclick would record a wrong winner.
        local listed, away, here = {}, {}, {}
        for _, w in ipairs(wanters) do
            local key = w.key
            listed[key] = true
            if w.inRaid or not inGroup then
                here[#here + 1] = key
                local reason = WanterReason(w)
                root:CreateButton(ColoredName(key, w.classFile) .. "  " .. BadgeText(w, vp)
                    .. (w.cantUse and (" " .. Paint("can't use", "bad")) or ""), function() award(key, reason) end)
            else
                away[#away + 1] = w
            end
        end
        local others = {}
        for _, key in ipairs(GroupKeys()) do
            if type(key) == "string" and not listed[key] then others[#others + 1] = key end
        end
        sort(others, function(x, y) return ShortName(x) < ShortName(y) end)
        if #wanters > #away then root:CreateDivider() end
        if #others > 0 then
            local sub = root:CreateButton("Other " .. GroupWord() .. " member")
            for _, key in ipairs(others) do
                sub:CreateButton(ColoredName(key), function() award(key) end)
            end
        end
        -- Offspec awards (ADDENDUM G): not counted as loot won. BiS candidates first, then the rest of the group.
        local osList = {}
        for _, key in ipairs(here) do osList[#osList + 1] = key end
        for _, key in ipairs(others) do osList[#osList + 1] = key end
        if #osList > 0 then
            local sub = root:CreateButton("Award as offspec")
            for _, key in ipairs(osList) do
                sub:CreateButton(ColoredName(key), function() award(key, "os") end)
            end
        end
        if #away > 0 then
            local sub = root:CreateButton(format("Not in %s (%d)", GroupWord(), #away))
            for _, w in ipairs(away) do
                local key = w.key
                sub:CreateButton(ColoredName(key, w.classFile) .. "  " .. BadgeText(w, vp)
                    .. Paint(" - " .. PresenceText(w), "muted"), function() award(key) end)
            end
        end
        root:CreateButton("Someone else...", function() DropPanel:AwardSomeoneElse(itemID, bossKey, copy, drop) end)
        if type(awardEntry) == "table" and awardEntry.id and ns.Ledger and ns.Ledger.Void then
            root:CreateDivider()
            local id = awardEntry.id
            root:CreateButton("Void the award to " .. ShortName(awardEntry.w),
                function() ns.Ledger:Void(id, true) end)
        end
    end)
end

---------------------------------------------------------------------------
-- Personal toast
---------------------------------------------------------------------------
function DropPanel:GetToast()
    if self.toast then return self.toast end
    local t = CreateFrame("Button", "DisasterZoneToast", _G.UIParent, "BackdropTemplate")
    t:SetSize(300, 56)
    t:SetPoint("TOP", _G.UIParent, "TOP", 0, -160)
    t:SetFrameStrata("DIALOG")
    t:SetClampedToScreen(true)
    t:Hide()
    if t.SetBackdrop then
        t:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        t:SetBackdropColor(0, 0, 0, 0.92)
        local c = Color("main")
        t:SetBackdropBorderColor(c[1], c[2], c[3], 1)
    end

    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(36, 36)
    t.icon:SetPoint("LEFT", t, "LEFT", 10, 0)
    t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    t.title = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t.title:SetPoint("TOPLEFT", t, "TOPLEFT", 54, -10)
    t.title:SetWidth(200)
    t.title:SetJustifyH("LEFT")
    t.title:SetWordWrap(false)

    t.text = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t.text:SetPoint("TOPLEFT", t, "TOPLEFT", 54, -30)
    t.text:SetWidth(238)
    t.text:SetJustifyH("LEFT")
    t.text:SetWordWrap(false)

    t.more = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    t.more:SetPoint("TOPRIGHT", t, "TOPRIGHT", -8, -10)

    local ag = t:CreateAnimationGroup()
    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetDuration(TOAST_FADE)
    ag:SetScript("OnFinished", function() DropPanel:FinishToast() end)
    t.fadeAnim = ag

    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            DropPanel:DismissToast()
        elseif self.entry then
            LinkToChat(self.entry.itemID)
        end
    end)
    t:SetScript("OnEnter", function(self)
        DropPanel.toastHovered = true
        if self.fadeAnim:IsPlaying() then
            self.fadeAnim:Stop()
            DropPanel.toastWaiting = true
        end
        self:SetAlpha(1)
        local e = self.entry
        if e then
            local tt = _G.GameTooltip
            tt:SetOwner(self, "ANCHOR_BOTTOM")
            tt:SetItemByID(e.itemID)
            tt:AddLine(" ")
            tt:AddLine("Click: link in chat. Right-click: dismiss.", 0.6, 0.6, 0.6)
            tt:Show()
        end
    end)
    t:SetScript("OnLeave", function()
        DropPanel.toastHovered = false
        HideTooltip()
        if DropPanel.toastWaiting then
            DropPanel.toastWaiting = false
            DropPanel:StartToastTimer(TOAST_LINGER)
        end
    end)
    self.toast = t
    return t
end

function DropPanel:StartToastTimer(seconds)
    if self.toastTimer then self.toastTimer:Cancel() end
    self.toastTimer = C_Timer.NewTimer(seconds, function()
        DropPanel.toastTimer = nil
        DropPanel:ToastTimeout()
    end)
end

function DropPanel:ToastTimeout()
    local t = self.toast
    if not t or not t:IsShown() then return end
    if self.toastHovered then
        self.toastWaiting = true      -- OnLeave restarts a short timer
    else
        t.fadeAnim:Play()
    end
end

function DropPanel:QueueToast(itemID, match, test)
    if #self.toastQueue >= TOAST_QUEUE_MAX then return end
    tinsert(self.toastQueue, { itemID = itemID, match = match, test = test })
    local t = self.toast
    if t and t:IsShown() then
        self:RefreshToastText()
    else
        self:ShowNextToast()
    end
end

function DropPanel:ShowNextToast()
    local entry = tremove(self.toastQueue, 1)
    if not entry then return end
    local t = self:GetToast()
    t.entry = entry
    self.toastWaiting = false
    self:RefreshToastText()
    t.fadeAnim:Stop()
    t:SetAlpha(1)
    t:Show()
    self:StartToastTimer(TOAST_HOLD)
end

function DropPanel:RefreshToastText()
    local t = self.toast
    local e = t and t.entry
    if not e then return end
    local m = e.match or {}
    t.icon:SetTexture(ItemIcon(e.itemID))
    local title = STAR .. " On your BiS list!"
    if m.os then
        local sp = OffSpecLabel()
        title = Paint("On your off-spec list" .. (sp and (" (" .. sp .. ")") or ""), "offspec")
    end
    if e.test then title = title .. Paint(" (test)", "muted") end
    t.title:SetText(title)
    local shown = (m.via and m.wanted) or e.itemID
    local which = (m.which == "alt") and "alt" or "main"
    if m.via then which = which .. ", " .. ((ns.VIA_TEXT and ns.VIA_TEXT[m.via]) or "via token") end
    -- The icon and its tooltip name the item; the line keeps what matters and fits (long names were cut off).
    local via = (m.via and shown ~= e.itemID) and (ItemText(shown) .. " - ") or ""
    t.text:SetText(format("%s%s · P%d (%s)", via, SlotLabel(m.sid), tonumber(m.phase) or 0, which))
    local queued = #self.toastQueue
    t.more:SetText(queued > 0 and ("+" .. queued) or "")
end

function DropPanel:FinishToast()
    local t = self.toast
    if self.toastTimer then
        self.toastTimer:Cancel()
        self.toastTimer = nil
    end
    if t then
        t:Hide()
        t:SetAlpha(1)
        t.entry = nil
    end
    self.toastWaiting = false
    self:ShowNextToast()
end

function DropPanel:DismissToast()
    local t = self.toast
    if t and t.fadeAnim:IsPlaying() then t.fadeAnim:Stop() end
    HideTooltip()
    self:FinishToast()
end

---------------------------------------------------------------------------
-- Default loot frame decoration (classic LootButton1..N paging frame)
---------------------------------------------------------------------------
local function NumLootButtons()
    return tonumber(_G.LOOTFRAME_NUMBUTTONS) or 4
end

local function SetGlow(btn, on)
    if on and not btn.cdlGlow then
        if ns.UI and ns.UI.Glow then ns.UI:Glow(btn, true) end
        btn.cdlGlow = true
    elseif not on and btn.cdlGlow then
        if ns.UI and ns.UI.Glow then ns.UI:Glow(btn, false) end
        btn.cdlGlow = nil
    end
end

local function SetBadge(btn, text)
    local holder = btn.cdlBadge
    if not text then
        if holder then holder:Hide() end
        return
    end
    if not holder then
        holder = CreateFrame("Frame", nil, btn)
        holder:SetAllPoints(btn)
        holder:SetFrameLevel(btn:GetFrameLevel() + 5)
        holder.text = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        holder.text:SetPoint("TOPLEFT", holder, "TOPLEFT", 2, -2)
        holder.text:SetJustifyH("LEFT")
        holder.text:SetWordWrap(false)
        holder.bg = holder:CreateTexture(nil, "ARTWORK")
        holder.bg:SetColorTexture(0, 0, 0, 0.75)
        holder.bg:SetPoint("TOPLEFT", holder.text, "TOPLEFT", -2, 1)
        holder.bg:SetPoint("BOTTOMRIGHT", holder.text, "BOTTOMRIGHT", 2, -1)
        btn.cdlBadge = holder
    end
    holder.text:SetText(text)
    holder:Show()
end

function DropPanel:ClearLootButton(btn)
    if not btn then return end
    SetBadge(btn, nil)
    SetGlow(btn, false)
end

-- In-raid, not-obtained wanters of a loot item: distinct players with a main pick, and alt-only players.
local function CountRaidWanters(itemID)
    local mains, alts = 0, 0
    for _, w in ipairs(UniqueWanters(itemID, { raidOnly = true })) do
        if w.which == "alt" then alts = alts + 1 else mains = mains + 1 end
    end
    return mains, alts
end

function DropPanel:DecorateLootButton(index)
    local btn = _G["LootButton" .. tostring(index)]
    if not btn then return end
    if not btn.cdlHooked then
        btn.cdlHooked = true
        btn:HookScript("OnHide", function(self) DropPanel:ClearLootButton(self) end)
    end
    local showBadges = Setting("alerts.lootBadges", true)
    local showGlow = Setting("alerts.glow", true)
    if (not showBadges and not showGlow) or not btn:IsShown() or not btn.slot then
        self:ClearLootButton(btn)
        return
    end
    local link = _G.GetLootSlotLink and _G.GetLootSlotLink(btn.slot)
    local itemID = type(link) == "string" and tonumber(link:match("item:(%d+)"))
    if not itemID or itemID <= 0 then
        self:ClearLootButton(btn)
        return
    end

    local mine = OwnNeededMatch(itemID) ~= nil
    local text
    if showBadges then
        if IsCouncil() then
            local mains, alts = CountRaidWanters(itemID)
            if mains > 0 then
                text = Paint("BiS ×" .. mains, "main")
            elseif alts > 0 then
                text = Paint("Alt ×" .. alts, "alt")
            end
            if mine then text = STAR_SMALL .. (text or Paint("Yours", "main")) end
        elseif mine then
            text = STAR_SMALL .. Paint("Yours", "main")
        end
    end
    SetBadge(btn, text)
    SetGlow(btn, showGlow and mine)
end

function DropPanel:UpdateAllLootButtons()
    for i = 1, NumLootButtons() do self:DecorateLootButton(i) end
end

function DropPanel:ClearLootButtons()
    for i = 1, NumLootButtons() do self:ClearLootButton(_G["LootButton" .. i]) end
end

function DropPanel:HookLootFrame()
    if self.lootHookDone then return end
    self.lootHookDone = true
    -- A boss drop fires on LOOT_READY, before Blizzard shows the loot window (LOOT_OPENED): place the panel again
    -- once the window is shown and positioned (LootFrame_Show moves it under the mouse after Show()).
    local function replace()
        local f = DropPanel.frame
        if f and f:IsShown() and Setting("dropPanelMode", "auto") == "auto" then DropPanel:Place() end
    end
    if type(_G.LootFrame_Show) == "function" then
        hooksecurefunc("LootFrame_Show", replace)
    elseif _G.LootFrame and _G.LootFrame.HookScript then
        _G.LootFrame:HookScript("OnShow", function() C_Timer.After(0, replace) end)
    end
    if type(_G.LootFrame_UpdateButton) == "function" then
        hooksecurefunc("LootFrame_UpdateButton", function(index) DropPanel:DecorateLootButton(index) end)
    else
        -- No per-button hook on this client build: repaint after Blizzard's own loot handlers ran.
        local function later()
            C_Timer.After(0, function() DropPanel:UpdateAllLootButtons() end)
        end
        ns:RegisterEvent("LOOT_OPENED", later)
        ns:RegisterEvent("LOOT_SLOT_CLEARED", later)
    end
    ns:RegisterEvent("LOOT_CLOSED", function() DropPanel:ClearLootButtons() end)
end
