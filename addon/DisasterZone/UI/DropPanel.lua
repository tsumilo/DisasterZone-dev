if DisasterZoneBoot and DisasterZoneBoot.Run("UI/DropPanel.lua", ...) then return end -- DisasterZone UI/DropPanel.lua
-- Boss-drop alerts: the Loot Council drop panel (with DisasterZone rolls, ADDENDUM A §19.5; also for the party
-- leader in dungeon mode, ADDENDUM B §22.2), the personal "On your BiS list!" toast, and BiS badges / glow
-- on the default loot frame buttons (SPEC §12.8). Awards of an item that has a roll go through the roll
-- so every popup closes (ADDENDUM C §23.2). The raid leader can lock / unlock the group's BiS lists from
-- the footer, and candidates / roll rows of players who changed their list while locked carry a warning
-- marker (ADDENDUM F §38). ADDENDUM G: council votes on roll rows (a vote column you click to vote), award
-- reasons ("Award to X as ▸", "Reason ▸"), and DE / Bank hand-outs to the guild's disenchanter / bank.
-- 1.3: a raid that runs rolls without the loot council gets a plain roll panel (PlainMode): items, rolls and awards,
-- no BiS candidates, badges, votes or lock button.
-- 1.3.1 (the in-raid makeover): the boss on its raid's art; each item a flat card with the candidates (class circle,
-- presence dot, BiS / Alt / OS pill), one action row (the roll button, then the one gold award: Award, or Award to
-- the suggested roller) and a More menu for the occasional ones (Announce, Disenchant, Guild bank, award to someone
-- else). The toast has the Dungeons tab's ping look.
-- 1.4 (the shared structure): the window is a tool window (UI:CreateWindow + UI:CreateLayout "tool": the boss strip
-- banner with the pager as its tools, the tool row with Announce all, the lock and the one main action Roll all, the
-- cards in the body), the cards are UI:CreateCard, the rows UI:DecorateRow, the texts the type scale, the colours the
-- ns.Style tokens, the personal "On your BiS list" pop-up a UI:Toast and the questions Popup:Confirm / Prompt.
local addonName, ns = ...

local DropPanel = ns:NewModule("DropPanel")
local UI, S = ns.UI, ns.Style

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
-- One grid (the shared spacing): S.PAD at the window's sides and inside an item card, S.GAP between blocks. The
-- window's content area is PANEL_W - 10 wide (UI:CreateWindow's content frame); the tool layout puts the banner,
-- the tool row and the body (the cards' scroll frame) in it.
local PANEL_W, PANEL_MIN_H, PANEL_MAX_H = 460, 170, 560
local CONTENT_W = PANEL_W - 10
local PAD, GAP, CARD_PAD = S.PAD, S.GAP, S.PAD
local CARD_W = CONTENT_W - 2 * PAD
local BANNER_H = S.BANNER.strip             -- the boss banner (the raid's loading-screen art)
local TOOLROW_H = UI.LAYOUT.ROW_H           -- the tool row under it (Announce all, the lock, Roll all)
-- the window's height around the cards: its head, the layout's margins, the banner and the tool row
local CHROME_H = UI.WIN_HEAD + 1 + PAD + BANNER_H + GAP + TOOLROW_H + GAP + PAD + 5
local ICON_SIZE = 32
local TEXT_X = CARD_PAD + ICON_SIZE + 10    -- the item's name, its rows and its actions line up here
local LIST_X = CARD_PAD                     -- 1.3.5: the rows (and the actions under them) run the card's full width
local ROW_W = CARD_W - 2 * CARD_PAD
local ITEM_HEAD_H = CARD_PAD + ICON_SIZE + 6   -- the rows start here
local ROW_H, ACTION_H = S.ROW.compact, S.BTN_H
local ROLL_ROW_H = ROW_H
local SLOT_W = 70                           -- the roll button's slot: Roll / End roll / Re-roll / Cancel
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local MAX_ROWS = 8
local MAX_ROLL_ROWS = 10
local ROLL_TICK = 0.5         -- countdown refresh while a roll of the shown drop is open
local EQ_SIZE = 14
local MAX_DROP_ITEMS = 16
local TOAST_HOLD = 8          -- seconds the "On your BiS list" pop-up stays (the mouse over it holds it)
local TOAST_QUEUE_MAX = 10
local ALERT_DEDUPE = 90       -- seconds: the same item (corpse drop + group-loot roll) alerts only once
local ANNOUNCE_COOLDOWN = 2
local AWARD_WINDOW = 120      -- ledger entries up to this long before the drop still count as its awards

-- Texture escapes instead of star / check glyphs: the default WoW fonts do not contain them.
local STAR = "|TInterface\\AddOns\\DisasterZone\\Media\\Icons\\bis:0|t"
local STAR_SMALL = "|TInterface\\AddOns\\DisasterZone\\Media\\Icons\\bis:10:10|t"

-- Row columns {x, width} from the row's left edge (1.3.5, the roll rows makeover: layout B of the mockup, the user's
-- pick 2026-10-11). Rows run the card's full width (LIST_X, ROW_W = 404 px; the two "currently wearing" icons take the
-- last 30). On the loot council's view a vote rail comes first (rail: a square with the votes; the click votes) and
-- keeps its room on the BiS rows too, so every card's class circles line up (cls = x without / with the rail). From
-- the spec on, the columns are the same in every row: the spec in its short form (Grid.SHORT: "Prot", "Resto", "MM";
-- the tooltip has it in full), the BiS / Alt / OS pill (up to "Alt P3"), the attendance % (council only), the loot
-- column (the dry streak bars, or a word: "won 1", "tie", "can't use"; BiS rows: "not in raid"), then on roll rows
-- the roll and a small note ("x2" for a repeated roll, the range of a bad one). Tried and dropped (user): a ring of
-- attendance dots around the class circle, and a roll meter (next to the dry streak bars it read as part of them).
local COL = { rail = 16, cls = { 4, 22 }, name = 18, spec = { 124, 44 }, pill = 170, att = { 216, 28 },
              status = { 253, 111 }, loot = { 253, 80 }, roll = { 326, 30 }, note = { 358, 14 } }
local VOTE_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:11:11|t"

-- A crafting material (Materials): the holdings squares at a row's right end, the craft's header line, and the
-- craft line of an awarded material (who crafts it, Whisper).
local MAT = { PIP_MAX = 5, PIP_SIZE = 7, MAT_GROUPS = 5, MAT_PER_GROUP = 3, MADE_H = 22 }
MAT.PIPS_W = 22 + MAT.PIP_MAX * (MAT.PIP_SIZE + 2)
local Mat = {}   -- the material helpers (functions; one local keeps the file under Lua's 200 locals)
local Dry, Grid = {}, {}   -- 1.3.5: the dry streak and the row grid helpers (same reason)

local SLOT_GROUP_FALLBACK = {
    [11] = { 11, 12 }, [12] = { 11, 12 }, [13] = { 13, 14 }, [14] = { 13, 14 }, [15] = { 15, 16 }, [16] = { 15, 16 },
}
local GROUP_LABELS = { [11] = "Ring", [12] = "Ring", [13] = "Trinket", [14] = "Trinket", [15] = "Weapon", [16] = "Weapon" }

---------------------------------------------------------------------------
-- Small helpers (all nil-safe: other modules may not have data yet)
---------------------------------------------------------------------------
-- The loot colours (ns.COLORS: main / alt / obtained / muted / warn / bad / offspec) and text painted in one.
local function Color(key)
    return ns.COLORS[key] or ns.COLORS.muted
end

local function Paint(text, key)
    return UI:Colorize(text, Color(key))
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

local ShortName = ns.Util.ShortName

local function IsMe(key)
    return ns.Util and ns.Util.IsMe and ns.Util.IsMe(key) or false
end

local function ColoredName(key, classFile)
    classFile = classFile or UI:ClassOf(key)
    -- players outside the guild (pugs) are marked: they roll and can be awarded like everyone else
    if Dry.preview and Dry.preview[key] then return UI:ColoredName(key, classFile) end   -- (the example roll)
    return UI:ColoredName(key, classFile) .. UI:GuestTag(key)
end

-- (one value: UI:ItemText's second return says the name is still loading)
local function ItemText(itemID)
    local text = UI:ItemText(itemID)
    return text
end

-- The plain name for chat lines and menus; "item <id>" while it loads.
local function ItemName(itemID)
    return UI:ItemName(itemID) or ("item " .. tostring(itemID))
end

local function ItemLink(itemID)
    return UI:GetItemLink(itemID)
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

-- A crafting material (Nether Vortex, ...): who wants it for which craft (Materials:GetWants), or nil.
local function MaterialWants(itemID, vp)
    local M = ns.Materials
    if not (M and M.IsMaterial and M:IsMaterial(itemID)) then return nil end
    return M:GetWants(itemID, { viewPhase = vp })
end

-- Store:GetWanters returns one entry per (player, wanted item); the panel needs one per player. A crafting material:
-- the players with a craft that uses it on a list (the craft they want it for, best first).
local function UniqueWanters(itemID, opts)
    local out = {}
    if not (ns.Store and ns.Store.GetWanters) then return out end
    local list = ns.Store:GetWanters(itemID, opts)
    if type(list) == "table" and #list == 0 then
        local mat = MaterialWants(itemID, opts and opts.viewPhase)
        if mat then list = mat.wants end
    end
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
    -- a crafting material: the craft on my lists it is for (the match of that craft, via = "craft")
    local M = ns.Materials
    local w = M and M.IsMaterial and M:IsMaterial(itemID) and M:GetOwnPick(itemID, includeOS)
    if w then
        local m = {}
        for k, v in pairs(w.match) do m[k] = v end
        m.via, m.wanted, m.need, m.held, m.completes = "craft", w.use.item, w.use.count, w.held, w.completes
        return m
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
        if type(sids) == "table" and sids[1] then slot = ns.SlotLabel(sids[1]) end
        local text = slot and ("Token: " .. slot) or "Token / quest item"
        local classes = data.TokenClasses and data.TokenClasses[itemID]
        if type(classes) == "table" and #classes > 0 then
            local names = {}
            for i, cf in ipairs(classes) do names[i] = ns.ClassName(cf, true) end
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

local DemoEnabled = ns.Util.DemoOn

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
                    label = ns.SlotLabel(g)
                    break
                end
            end
        end
        if not label and group then
            if #ids == #group then
                label = ns.SlotLabel(group[i])
            else
                label = GROUP_LABELS[group[1]] or ns.SlotLabel(group[1])
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

-- 1.3: the raid runs rolls without the loot council, so the panel is a plain roll panel: the items, rolls and
-- awards, without BiS candidates, badges, votes or the lock button. A roll keeps what it was started as
-- (session.plain); simulated drops (/dz test) keep the full panel.
local function PlainMode(drop, session)
    if type(session) == "table" then return session.plain and true or false end
    if type(drop) == "table" and drop.test then return false end
    return HasRoll("IsPlainRaid") and CallRoll("IsPlainRaid") and true or false
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
    local rolled, passed, votes, split = 0, 0, 0, 0
    local tie, picked = false, false
    for _, r in ipairs(results) do
        if type(r) == "table" then
            if r.split then
                split = split + 1
                if r.suggested then picked = true end
            end
            if r.response == "pass" and not tonumber(r.roll) then
                passed = passed + 1
            elseif tonumber(r.roll) then
                rolled = rolled + 1
            end
            if r.suggested and r.tie then tie = true end
            votes = votes + (tonumber(r.votes) or 0)
        end
    end
    return rolled, passed, tie, votes, split, picked
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
            return Paint(format("Queued #%d  ·  starts after the current roll", queuePos), "muted")
        end
        return Paint("Queued  ·  starts after the current roll", "muted")
    end
    stats = stats or {}
    local st = session.state
    if st == "open" then
        local left = RollTimeLeft(session)
        local head = left > 0 and ("Rolling  ·  " .. FormatLeft(left) .. " left") or "Rolling  ·  closing now"
        local t = Paint(head, "main") .. Paint(format("  ·  %d rolled, %d passed", stats.rolled or 0, stats.passed or 0), "muted")
        t = t .. Dry.VotesLine(stats)
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
    t = t .. Dry.VotesLine(stats)
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
                           "OWNED_UPDATED", "MYLIST_CHANGED", "SETTINGS_CHANGED", "MATERIALS_UPDATED",
                           "PROFESSIONS_UPDATED", "PRIZED_UPDATED", "LOOT_RULES_CHANGED" }) do
        ns:On(msg, dataChanged)
    end
    ns:On("ITEMINFO_READY", function()
        DropPanel:RequestRefresh()
        DropPanel:RefreshToastText()
    end)
    -- Master looters (and the party leader in dungeon mode) may keep the panel open for rolls (/dz drops);
    -- everyone else loses it with their council seat or the dungeon mode.
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
    -- 1.3: the master looter gets the panel too (it may always start rolls), also outside the council
    local ml = ns.Util and ns.Util.IsPlayerMasterLooter and ns.Util.IsPlayerMasterLooter() and CanStartRolls(drop)
    if not drop.roll and Setting("alerts.councilPanel", true) and (IsCouncil() or IsDungeonLeader() or ml) then
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
                if wantToast then self:QueueToast(id, m, drop.test, drop.b) end
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
    if m.via == "craft" then
        -- a crafting material: "Nether Vortex: for Belt of Blasting on your BiS list (you have 1 of 2)"
        ns:Print("%s %s: for %s on your %s list (you have %d of %d)%s", m.os and "" or STAR, link or ItemName(itemID),
            ItemLink(m.wanted) or ItemName(m.wanted), m.os and "off-spec" or "BiS", tonumber(m.held) or 0,
            tonumber(m.need) or 0, test and " [test]" or "")
        return
    end
    local which = (m.which == "alt") and "alt" or "main"
    if m.via then which = which .. ", " .. ((ns.VIA_TEXT and ns.VIA_TEXT[m.via]) or "via token") end
    if m.os then
        local sp = OffSpecLabel()
        ns:Print("%s is on your off-spec list%s: %s, P%d (%s)%s", link or ItemName(itemID),
            sp and (" (" .. sp .. ")") or "", ns.SlotLabel(m.sid), tonumber(m.phase) or 0, which, test and " [test]" or "")
        return
    end
    ns:Print("%s %s is on your BiS list: %s, P%d (%s)%s", STAR, link or ItemName(itemID),
        ns.SlotLabel(m.sid), tonumber(m.phase) or 0, which, test and " [test]" or "")
end

---------------------------------------------------------------------------
-- Council panel
---------------------------------------------------------------------------
-- (the panel's small pieces: one table, the file stays far from Lua's 200 locals)
local Look = {}

-- A tooltip from textFn(button) (nil: none), also over a disabled button.
function Look.Tip(btn, textFn)
    if btn.SetMotionScriptsWhileDisabled then btn:SetMotionScriptsWhileDisabled(true) end
    UI:AttachTooltip(btn, nil, function(self) return { textFn(self) } end, { anchor = "ANCHOR_TOP" })
end

-- The raid of a boss key (drop.b): its name, a dungeon flag and the raid's instance id (nil for 5-mans / unknown).
local function DropSource(bossKey)
    if type(bossKey) ~= "string" or bossKey == "" or not (ns.ItemDB and ns.ItemDB.GetBossRef) then return nil end
    return ns.ItemDB:GetBossRef(bossKey)
end

-- The raid's art key of a drop source: its instance id when the raid is a known one (its loading screen on the
-- banner), nil for 5-mans and unknown sources (the banner's plain card).
function Look.RaidOf(ref)
    if not (ref and ref.dungeon ~= true and ref.raid) then return nil end
    local id = tonumber(ref.raid.instanceID)
    return id and ns.ItemDB.GetRaidByInstance and ns.ItemDB:GetRaidByInstance(id) and id or nil
end

-- The pager (the banner's tools): older / newer drop, the chevrons turned left / right.
function Look.SetPager(f, showPrev, showNext)
    local tools = {}
    if showNext then tools[#tools + 1] = { icon = "chevron", chevron = "right", title = "Newer drop", onClick = function() DropPanel:Page(1) end } end
    if showPrev then tools[#tools + 1] = { icon = "chevron", chevron = "left", title = "Older drop", onClick = function() DropPanel:Page(-1) end } end
    local ban = f.layout.banner
    ban:SetTools(tools)
    for i, t in ipairs(tools) do
        if t.title == "Newer drop" then DropPanel.nextBtn = ban.tools[i] else DropPanel.prevBtn = ban.tools[i] end
    end
end

function DropPanel:GetFrame()
    if self.frame then return self.frame end
    local f = UI:CreateWindow(PANEL_NAME, "Boss drop", PANEL_W, 300)
    f:Hide()
    self.frame = f
    local c = f.content or f
    self.content = c
    -- A manual drag turns an attached panel into a floating one (CreateWindow saves the position).
    f:HookScript("OnDragStop", function() DropPanel.attached = false end)

    -- The tool window: the boss on its raid's loading-screen art (a strip banner; the plain card for 5-mans) with the
    -- pager as its tools and "2 / 13" as its pill; the tool row (Announce all, the lock, Roll all); the cards.
    local L = UI:CreateLayout("tool", c, { width = CONTENT_W, toolbar = true,
        banner = { size = "strip", title = "No drop selected" } })
    f.layout = L
    local ban = L.banner
    self.banner = ban
    self.title, self.sub = ban.title, ban.sub
    self.pageText = ban.pill.fs
    self.pageText:Hide()

    -- Scrollable item cards (the scroll bar sits in the body's right edge).
    local scroll = UI:CreateScrollFrame(L.body, PANEL_NAME .. "Scroll")
    scroll:SetAllPoints(L.body)
    scroll.scrollBarHideable = true
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CARD_W, 1)
    scroll:SetScrollChild(child)
    self.scroll, self.child = scroll, child

    -- The tool row: Announce all and the lock (the raid leader's) as its controls, Roll all as its one main action.
    local bar = L.toolbar
    local announceAll = UI:CreateSleekButton(bar, "Announce all", 96, S.BTN_H, function() DropPanel:AnnounceAll() end)
    Look.Tip(announceAll, function()
        if DropPanel.drop and DropPanel.drop.test then
            return "Simulated drop: the lines are only printed in your chat window."
        end
        if PlainMode(DropPanel.drop) then return "Link every item of this drop in raid chat." end
        return "Announce every item of this drop and who has it on their BiS list."
    end)
    self.announceAllBtn = announceAll
    local filters = { announceAll }
    -- §38: small "Lock lists" / "Unlock lists" button for the raid leader (the group's loot authority).
    if UI.CreateBiSLockButton then
        local lock = UI:CreateBiSLockButton(bar, 92, S.BTN_H, { short = true })
        self.lockBtn = lock
        filters[#filters + 1] = lock
    end
    bar:SetFilters(filters)
    local rollAll = bar:SetPrimary({ text = "Roll all", width = 80, onClick = function() DropPanel:RollAll() end })
    Look.Tip(rollAll, function()
        local text = "Roll every item of this drop, one after another (awarded items are skipped). "
            .. "Everyone in the " .. GroupWord() .. " gets a Roll / Pass popup for each item."
        if DemoEnabled() then text = text .. "\n\nDemo mode: fake raiders roll; nothing is sent." end
        return text
    end)
    rollAll:Hide()
    self.rollAllBtn = rollAll
    -- (no Close button: the window's own X closes it)

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
        -- Back to the floating (saved) position (the one window-position store).
        UI:RestorePosition(f)
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
            b.sub:SetText(DropPanel.PrzSub(b.itemID, RollStateText(s, b.rollStats), true))
        end
    end
    if not any then self:StopRollTicker() end
end

function DropPanel:RenderHeader(drop)
    local title, sub, art = "No drop selected", "", nil
    if type(drop) == "table" then
        local ref = DropSource(drop.b)
        local parts = {}
        if ref and ref.boss then
            title = ref.boss.name or "?"
            if ref.raid and ref.raid.name then
                parts[#parts + 1] = ref.raid.name .. (ref.dungeon == true and " (5-man)" or "")
                art = Look.RaidOf(ref)
            end
        else
            title = "Unknown source"
        end
        local ts = tonumber(drop.ts)
        if ts and ts > 1000000000 and ts < 4000000000 then parts[#parts + 1] = _G.date("%H:%M", ts) end
        if type(drop.from) == "string" and not IsMe(drop.from) then
            parts[#parts + 1] = "looted by " .. ColoredName(drop.from)
        end
        if drop.test then
            -- a simulated drop gets awards and rolls in demo mode only (the one line that says why there are none)
            parts[#parts + 1] = Paint(FakeDropLocked(drop) and "simulated: awards need /dz demo" or "simulated", "warn")
        end
        sub = tconcat(parts, "  ·  ")
    end
    local ban = self.banner
    ban:SetArt(art)
    ban:SetTitle(title)
    ban:SetSub(sub)

    -- The pager shows only when there is more than one drop: "2 / 13" as the title's pill ("2 / 13 new" when newer
    -- drops came in while this one was worked on), the arrows as the banner's tools (one that leads nowhere is not
    -- there).
    local n = #History()
    local i = self.histIndex
    local paged = n > 1 or (n == 1 and i == nil)
    if not paged then
        ban:SetPill(nil, nil)
        self.pageText:SetText("")
        self.pageText:Hide()
        Look.SetPager(self.frame, false, false)
    else
        local page = format("%s / %d", i and tostring(i) or "-", n)
        local fresh = (self.newDrops or 0) > 0 and i and i < n
        if fresh then page = page .. " new" end
        ban:SetPill(fresh and "warn" or "mute", page)
        self.pageText:Show()
        Look.SetPager(self.frame, (i or (n + 1)) > 1, i ~= nil and i < n)
    end
end

function DropPanel:Render()
    local f = self.frame
    if not f then return end
    local drop = self.drop
    self.child:SetWidth(CARD_W)

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
            y = y + h + GAP
        end
        if used > 0 then y = y - GAP end
    end
    for i = used + 1, #self.blocks do
        local b = self.blocks[i]
        b.rollSession = nil
        b:Hide()
    end
    -- nothing to show: the layout's empty state in the body
    local L = f.layout
    if used == 0 then
        L:ShowEmpty({ icon = UI.ICON.games, title = "No drop to show",
            text = "Boss drops of the last 24 hours show here.", y = 12, compact = true })
        y = 120
    elseif L:IsEmptyShown() then
        L:HideEmpty()
    end
    self.child:SetHeight(max(y, 1))
    if self.rollAllBtn then self.rollAllBtn:SetShown(canRoll and used > 0 and HasRoll("StartAll")) end
    if self.lockBtn and self.lockBtn.Refresh then
        self.lockBtn:Refresh()
        -- nothing reads the BiS lists while the raid runs without the loot council (1.3)
        if PlainMode(drop) and not (ns.GroupRules and ns.GroupRules.IsLocked and ns.GroupRules:IsLocked()) then
            self.lockBtn:Hide()
        end
    end
    L.toolbar:LayoutRight()
    self:UpdateRollTicker(anyOpen)

    local panelH = min(PANEL_MAX_H, max(PANEL_MIN_H, CHROME_H + y))
    f:SetHeight(panelH)
    -- everything fits: no scroll bar (its own hooks only run once the frame is laid out)
    local bar = self.scroll.ScrollBar
    if bar and y <= panelH - CHROME_H + 0.5 then bar:Hide() end
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
    if type(session) == "table" and session.state == "open" then return "" end   -- still rolling (the row is dimmed)
    return Paint("no roll", "muted")
end

-- Addendum I §51: "Attendance 92% (7/8 raids)" from the raid log, when any raid is logged.
-- A crafting material: the craft they want it for, how many they hold (and where that number comes from).
function Mat.AddCraftLines(tt, w, itemID)
    tt:AddLine("For " .. ItemText(w.craft) .. format(" (%d per craft)", tonumber(w.need) or 0), 0.8, 0.8, 0.8)
    local held = tonumber(w.held) or 0
    local from = (w.heldSrc == "report" and "their DisasterZone told us")
        or (w.heldSrc == "live" and "your bags and bank") or "from the loot log: no word from their DisasterZone yet"
    tt:AddLine(format("Holds %d %s (%s)", held, ItemName(itemID), from), 0.7, 0.7, 0.7, true)
    if w.completes then
        local m = Color("main")
        tt:AddLine("This one completes the craft", m[1], m[2], m[3])
    elseif w.left then
        tt:AddLine(format("Still %d more after this one", w.left), 0.7, 0.7, 0.7)
    end
end

local function AddAttendanceLine(tt, key)
    if not IsCouncil() then return end   -- other raiders' attendance is council data
    local RL = ns.RaidLog
    if not (RL and RL.GetAttendance) then return end
    local pct, a, n = RL:GetAttendance(key)   -- (not after an `and`: that keeps only the first value)
    -- (1.3.5: time-based, over the raids that expected them)
    if pct then
        tt:AddLine(format("Attendance %d%% (expected at %d of the last %d raids)", pct, a, n), 0.7, 0.7, 0.7)
    end
end

-- Dry streak (1.3.5, Attendance:GetDryStreak): the raids a player came to since their last item, as a row of bars
-- that warm up from grey to ember (one bar per raid, DRY.SEGS at most) and "4 raids"; the tooltip names the item.
-- Council only, and only for the guild council (the only ones holding the whole Loot Log).
local DRY = { SEGS = 6, SEG_W = 3, SEG_H = 9, GAP = 2,
              -- raids without loot -> colour: 0-1 quiet, 2-3 warming, 4-5 dry, 6+ very dry
              LEVELS = { { 2, { 0.55, 0.55, 0.55 } }, { 4, { 0.93, 0.80, 0.45 } }, { 6, { 1.00, 0.58, 0.22 } },
                         { math.huge, { 1.00, 0.36, 0.18 } } } }
DRY.BARS_W = DRY.SEGS * DRY.SEG_W + (DRY.SEGS - 1) * DRY.GAP

-- 1.3.5 prized items (Core/Prized.lua, Raids > Loot rules): the item's record, a row's rule check, the short word for
-- the rule that keeps a player out (the row's loot column; the tooltip has it whole), the card's marks.
DropPanel.PRZ_SHORT = { att = "attendance", rank = "rank", main = "alt", guild = "guest", cd = "cooldown", order = "spec",
                   queue = "queue", pair = "pair", bis = "not listed" }
function DropPanel.PrzRec(itemID)
    local P = ns.Prized
    return P and P.ForItem and P:ForItem(itemID) or nil
end
function DropPanel.PrzCheck(itemID, key, hint)
    local rec = DropPanel.PrzRec(itemID)
    if not rec or type(key) ~= "string" then return nil end
    return ns.Prized:Check(rec, key, { hint = hint })
end
function DropPanel.PrzTag(c)
    if not c or c.ok ~= false then return nil end
    local res = c.by and c.by[c.failKey]
    if c.failKey == "att" and res and res.num then return Paint(res.num .. "% att", "warn") end
    return Paint(DropPanel.PRZ_SHORT[c.failKey] or "rules", "warn")
end
-- The card's name with the prized seal, and its second line with the votes the award needs.
-- 1.3.5 (prized look mockup, the user picked "ember glow" for the card): a prized item's card is warm - an amber
-- edge, a faint amber tint, a glow from the inside of the edges, and two soft sheens (blurred lights) gliding along
-- its top and bottom edges every few seconds. on = false puts the card back.
DropPanel.PRZ_GLOW = { EDGE = { 0.62, 0.34, 0.10, 1 }, TINT = { 1, 0.47, 0.08, 0.05 }, GLOW = { 1, 0.45, 0.08, 0.22 },
                       DEPTH = 22, PERIOD = 6, RUN = 3.2, SHEEN_L = 170, SHEEN_T = 30 }
-- (w: the frame's width, default the card's; offEdge: its edge colour when the glow is off, default the card's)
function DropPanel.PrzGlow(b, on, w, offEdge)
    local G = DropPanel.PRZ_GLOW
    local k = b.przGlow
    b.przGlowW = w or b.przGlowW or CARD_W
    if not k then
        if not on then return end
        k = {}
        k.tint = b:CreateTexture(nil, "BACKGROUND", nil, 1)
        k.tint:SetAllPoints()
        k.tint:SetColorTexture(G.TINT[1], G.TINT[2], G.TINT[3], G.TINT[4])
        local c = G.GLOW
        local function glow(p1, p2, orient, a1, a2, w, h)
            local t = b:CreateTexture(nil, "BACKGROUND", nil, 2)
            t:SetPoint(p1)
            t:SetPoint(p2)
            if w then t:SetWidth(w) else t:SetHeight(h) end
            UI:Gradient(t, orient, { c[1], c[2], c[3], a1 }, { c[1], c[2], c[3], a2 })
            return t
        end
        -- (VERTICAL: the first colour is the bottom; HORIZONTAL: the left)
        k.glow = { glow("TOPLEFT", "TOPRIGHT", "VERTICAL", 0, c[4], nil, G.DEPTH),
                   glow("BOTTOMLEFT", "BOTTOMRIGHT", "VERTICAL", c[4], 0, nil, G.DEPTH),
                   glow("TOPLEFT", "BOTTOMLEFT", "HORIZONTAL", c[4], 0, G.DEPTH),
                   glow("TOPRIGHT", "BOTTOMRIGHT", "HORIZONTAL", 0, c[4], G.DEPTH) }
        -- the sheen: a soft, blurred light (SoftGlow, added on top) that travels around the card's edge - a wide amber
        -- halo with a brighter core, stretched along the edge it is on, fading in and out as it goes round
        k.run = CreateFrame("Frame", nil, b)
        k.run:SetAllPoints()
        local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
        local function soft(layer, sub, r, g, bl, a)
            local t = k.run:CreateTexture(nil, layer, nil, sub)
            t:SetTexture(SOFT)
            t:SetBlendMode("ADD")
            t:SetVertexColor(r, g, bl, a)
            return t
        end
        -- (1.3.5, after the user's look in game: a light turning the corners looked bad) two sheens glide along the long
        -- edges, the top one left to right, the bottom one back, each fading in and out well before a corner
        k.top = { soft("OVERLAY", 1, 1, 0.55, 0.15, 0.6), soft("OVERLAY", 2, 1, 0.86, 0.55, 0.9) }
        k.bot = { soft("OVERLAY", 1, 1, 0.55, 0.15, 0.45), soft("OVERLAY", 2, 1, 0.86, 0.55, 0.7) }
        for _, pair in ipairs({ k.top, k.bot }) do
            pair[1]:SetSize(G.SHEEN_L, G.SHEEN_T)
            pair[2]:SetSize(G.SHEEN_L * 0.45, G.SHEEN_T * 0.35)
        end
        k.halo, k.core = k.top[1], k.top[2]   -- (the names the tests read)
        k.t = 0
        local function place(pair, x, y, a)
            for _, t in ipairs(pair) do
                t:ClearAllPoints()
                t:SetPoint("CENTER", b, "TOPLEFT", x, y)
                t:SetAlpha(a)
            end
        end
        k.run:SetScript("OnUpdate", function(self, dt)
            k.t = (k.t + (dt or 0)) % G.PERIOD
            local f = k.t / G.RUN                      -- 0..1 while the sheens run, then a rest
            if f > 1 then
                place(k.top, 0, 0, 0)
                place(k.bot, 0, 0, 0)
                return
            end
            local w = b.przGlowW or CARD_W
            local h = (b.GetHeight and b:GetHeight() or 0)
            if h < 40 then h = 160 end
            local m = G.SHEEN_L * 0.5 + 10             -- (stays clear of the corners)
            local a = math.sin(f * math.pi)            -- fades in, peaks in the middle, fades out
            place(k.top, m + f * (w - 2 * m), 0, a)
            place(k.bot, w - m - f * (w - 2 * m), -h, a * 0.8)
        end)
        b.przGlow = k
    end
    k.tint:SetShown(on)
    for _, t in ipairs(k.glow) do t:SetShown(on) end
    k.run:SetShown(on)
    local e = on and G.EDGE or offEdge or S.C.EDGE
    UI:SetEdgeColor(b, e[1], e[2], e[3], e[4])
end

function DropPanel.PrzName(itemID, text)
    if not DropPanel.PrzRec(itemID) or not (ns.UI and ns.UI.AtlasIconText) then return text end
    local i = (ns.HasAssets and ns:HasAssets(7)) and ns.UI.ICON.prized or ns.UI.ICON.trophy
    return text .. "  " .. ns.UI:AtlasIconText(i, 11, { 1, 0.6, 0.18 })
end
-- rolling: the subtitle says the roll's state; the council count goes into its votes ("1 of 3 votes",
-- Dry.VotesLine) instead of a "prized: needs ..." that would be cut off.
function DropPanel.PrzSub(itemID, text, rolling)
    local rec = DropPanel.PrzRec(itemID)
    if not rec then return text end
    if rolling then return text end
    local P = ns.Prized
    local n = #P:PresentCouncil()
    local need = P:NeededVotes(rec, n)
    local add = need > 0 and format("prized: needs %d of %d council", need, n) or "prized"
    return (text and text ~= "") and (text .. " · " .. add) or add
end

-- "  ·  3 votes", or on a split vote (Roll: several players with the most votes, r.split) "  ·  votes split 3 ways"
-- and, when nobody is suggested (the guild's rules: the council picks, or none of them rolled), ": pick one".
function Dry.VotesLine(stats)
    if (stats.split or 0) > 1 then
        return Paint(format("  ·  votes split %d ways", stats.split) .. (stats.picked and "" or ": pick one"), "warn")
    end
    if stats.need then
        -- (a prized item: the council's votes so far against how many must agree; gold once enough agree)
        local v = tonumber(stats.votes) or 0
        return Paint(format("  ·  %d of %d votes", v, stats.need), v >= stats.need and "main" or "muted")
    end
    if (stats.votes or 0) > 0 then return Paint("  ·  " .. VotesText(stats.votes), "muted") end
    return ""
end

-- The guild's attendance floor (Council > Rules), 0 = off.
function Dry.Floor()
    local G = ns.Guild
    local lr = G and G.GetLootRules and G:GetLootRules()
    return lr and tonumber(lr.f) or 0
end

-- "⚠ under 50%" in the loot column of a player under the floor (council only); true when shown.
function Dry.SetLow(r, key, att, floorPct)
    local f = tonumber(floorPct) or Dry.Floor()
    if f <= 0 or not IsCouncil() then return false end
    if att == nil then
        local RL = ns.RaidLog
        local pv = key and Dry.preview[key]
        if pv then att = pv.att else att = key and RL and RL.GetAttendance and (RL:GetAttendance(key)) or nil end
    end
    if not (tonumber(att) and att < f) then return false end
    r.dry:Hide()
    r.tag:SetText(WarnIcon(10) .. " " .. Paint(format("under %d%%", f), "warn"))
    r.tag:Show()
    return true
end

-- Council > Rules' preview card (DropPanel:FillPreviewRow): made-up players' attendance and dry streaks by key.
Dry.preview = {}

function Dry.Get(key)
    local pv = key and Dry.preview[key]
    if pv then return pv.dry end
    local Att = ns.Attendance
    if not IsCouncil() or not (Att and Att.GetDryStreak) then return nil end
    return Att:GetDryStreak(key)
end

function Dry.Color(nights)
    for _, l in ipairs(DRY.LEVELS) do
        if nights < l[1] then return l[2] end
    end
    return DRY.LEVELS[#DRY.LEVELS][2]
end

function Dry.Raids(n)
    return format("%d %s", n, n == 1 and "raid" or "raids")
end

function Dry.AddLines(tt, key)
    local d = Dry.Get(key)
    if not d then return end
    local c = Dry.Color(d.nights)
    local who = d.last and d.last.w ~= key and (" on " .. ShortName(d.last.w)) or ""
    if d.last then
        local days = floor(max(0, GetServerTime() - (tonumber(d.last.ts) or 0)) / 86400)
        local ago = days == 0 and "today" or (days == 1 and "yesterday" or format("%d days ago", days))
        tt:AddLine(format("Last item %s%s: %s", ago, who, ItemText(d.last.i)), c[1], c[2], c[3], true)
        local came = (tonumber(d.came) or d.nights) > d.nights and format(" (came to %d)", d.came) or ""
        tt:AddLine(format("Since then: there for %s, %d bosses%s", Dry.Raids(d.nights), d.bosses, came), c[1], c[2], c[3])
    else
        tt:AddLine(format("No item on record in %s (%d bosses)", Dry.Raids(d.nights), d.bosses), c[1], c[2], c[3])
    end
end

-- The bars + "4 raids" (compact: the number alone) at x of a row, hidden until Dry.Set.
function Dry.New(r, x)
    local f = CreateFrame("Frame", nil, r)
    f:SetSize(94, ROW_H)
    f:SetPoint("LEFT", r, "LEFT", x, 0)
    f.segs = {}
    for i = 1, DRY.SEGS do
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetSize(DRY.SEG_W, DRY.SEG_H)
        t:SetPoint("LEFT", f, "LEFT", (i - 1) * (DRY.SEG_W + DRY.GAP), 0)
        f.segs[i] = t
    end
    f.fs = UI:Text(f, "small", "SUB")
    f.fs:SetPoint("LEFT", f, "LEFT", DRY.BARS_W + 5, 0)
    f:Hide()
    r.dry = f
end

-- Shows the row's player's streak; false (hidden) when there is none to show.
function Dry.Set(r, key, compact)
    local f = r.dry
    local d = key and Dry.Get(key)
    if not d then
        f:Hide()
        return false
    end
    local c = Dry.Color(d.nights)
    for i, t in ipairs(f.segs) do
        if i <= d.nights then t:SetColorTexture(c[1], c[2], c[3], 0.95) else t:SetColorTexture(S:Color("HAIRLINE")) end
    end
    f.fs:SetText(compact and tostring(d.nights) or Dry.Raids(d.nights))
    f.fs:SetTextColor(c[1], c[2], c[3])
    f:Show()
    return true
end

local function RollTag(row, session)
    if type(session) == "table" and session.state == "awarded" and session.winner == row.key then
        return Paint("Winner", "obtained")
    end
    if row.tie then return Paint("tie", "warn") end
    -- (the suggested row is marked gold: no word for it)
    if row.cantUse then return Paint("can't use", "bad") end
    if row.wonCopy then return Paint("won a copy", "muted") end
    local won = tonumber(row.wonTonight) or 0
    if won > 0 then return Paint("won " .. won, "muted") end
    if not PlainMode(nil, session) and LockChanged(row) then return WarnIcon(10) .. " " .. Paint("changed", "warn") end
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
    local plain = PlainMode(nil, session)
    tt:AddLine(ColoredName(row.key, row.classFile))
    if row.prz and row.prz.ok == false then
        tt:AddLine("Prized item: " .. tostring(row.prz.fail or "breaks a loot rule") .. " (an award needs a reason)",
            1, 0.62, 0.36, true)
    end
    -- 1.3.5 longevity (the guild's "Longest use"): how long they keep it on their list
    local lg = tonumber(row.longevity)
    if lg and not plain then
        tt:AddLine(lg > 0 and format("On their list to P%d (%d phase%s)", tonumber(row.longevityTo) or 0, lg,
            lg == 1 and "" or "s") or "Not on their list from this phase on", 0.8, 0.8, 0.8)
    end
    local specLine = ((type(row.spec) == "string" and row.spec ~= "") and (row.spec .. " ") or "") .. (ns.ClassName(row.classFile, true) or "?")
    tt:AddLine(specLine, 0.8, 0.8, 0.8)
    if not plain then
        local tier = tonumber(row.tier) or 4
        local c = (tier == 1 and Color("main")) or (tier == 2 and Color("alt")) or (tier == 3 and Color("offspec")) or Color("muted")
        local p = tonumber(row.phase)
        tt:AddLine(TierWord(row) .. ((tier <= 3 and p) and format(" in P%d", p) or ""), c[1], c[2], c[3])
    end

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
    if row.craft then Mat.AddCraftLines(tt, row, self.itemID) end
    local won = tonumber(row.wonTonight) or 0
    if won > 0 then tt:AddLine(format("Won %d item(s) tonight", won), 0.7, 0.7, 0.7) end
    if not plain then Dry.AddLines(tt, row.key) end
    if row.lowAtt then
        local w = Color("warn")
        tt:AddLine(format("Under the guild's attendance floor (%d%%): never suggested", tonumber(row.lowAtt) or Dry.Floor()),
            w[1], w[2], w[3], true)
    end
    if row.split and not row.suggested then
        local w = Color("warn")
        tt:AddLine("Votes split: tied for the most votes", w[1], w[2], w[3])
    end
    AddAttendanceLine(tt, row.key)
    if row.wonCopy then
        tt:AddLine("Won another copy of this item from this drop: not suggested", Color("warn")[1], Color("warn")[2], Color("warn")[3])
    end
    if row.cantUse then
        tt:AddLine("Their class cannot use this item: never suggested", Color("bad")[1], Color("bad")[2], Color("bad")[3])
    end
    local note = not plain and ns.Store and ns.Store.GetLockNote and ns.Store:GetLockNote(row.key)
    if note then
        tt:AddLine("List changed during the lock but claims an earlier save: please check", Color("warn")[1],
            Color("warn")[2], Color("warn")[3], true)
    end
    local inRaid = row.inRaid
    if inRaid == nil then inRaid = IsInMyGroup(row.key) end
    if not inRaid then tt:AddLine("Not in your raid", 0.7, 0.7, 0.7) end
    local changed = not plain and LockChanged(row)
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
    if self.matOthers then
        Mat.MatOthersOnEnter(self)
        return
    end
    if self.more then
        tt:AddLine(format("%d more", #self.more), S:RGB("GOLD"))
        local plain = self.moreKind == "roll" and PlainMode(nil, self.session)
        for _, x in ipairs(self.more) do
            local warn = (not plain and LockChanged(x)) and (" " .. WarnIcon(10)) or ""
            if self.moreKind == "roll" then
                tt:AddDoubleLine(ColoredName(x.key, x.classFile) .. warn .. (plain and "" or (" " .. TierBadge(x, vp))),
                    RollCell(x, self.session), 1, 1, 1, 0.8, 0.8, 0.8)
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
    local specLine = ((type(w.spec) == "string" and w.spec ~= "") and (w.spec .. " ") or "") .. (ns.ClassName(w.classFile, true) or "?")
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
    if w.craft then
        Mat.AddCraftLines(tt, w, self.itemID)
    elseif w.wanted and w.wanted ~= self.itemID then
        tt:AddLine("Wants " .. ItemText(w.wanted) .. " (via this item)", 0.7, 0.7, 0.7)
    end
    tt:AddLine(w.inRaid and "In your raid" or (w.online and "Online, not in your raid" or "Offline"), 0.7, 0.7, 0.7)
    if (tonumber(w.wonTonight) or 0) > 0 then
        tt:AddLine(format("Won %d item(s) tonight", w.wonTonight), 0.7, 0.7, 0.7)
    end
    Dry.AddLines(tt, w.key)
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

-- (the worn item's tooltip: UI:AttachTooltip's title function)
local function EquippedTooltip(self, tt)
    if not self.itemID then return false end
    tt:SetItemByID(self.itemID)
    tt:AddLine(self.label and ("Currently wearing (" .. self.label .. ")") or "Currently wearing", S:Color("SUB"))
end

local function EquippedOnClick(self)
    if self.itemID and ns.UI and ns.UI.HandleModifiedItemClick then ns.UI:HandleModifiedItemClick(self.itemID) end
end

-- A text in one of the row grid's columns (col = { x, width }), in a style of the type scale.
function Grid.Cell(parent, style, color, col, opts)
    local fs = UI:Text(parent, style, color, opts)
    fs:SetPoint("LEFT", parent, "LEFT", col[1], 0)
    fs:SetWidth(col[2])
    return fs
end

-- A crafting material's holdings at the right end of a row: one square per material the craft takes (held gold, the
-- one this drop would add half gold, still missing grey) and "1/2" (grey when estimated from the loot log).
function Mat.NewPips(r)
    local p = CreateFrame("Frame", nil, r)
    p:SetSize(MAT.PIPS_W, ROW_H)
    p:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    p.count = UI:Text(p, "small", "TEXT", { justify = "RIGHT", width = 20 })
    p.count:SetPoint("RIGHT", p, "RIGHT", 0, 0)
    p.sq = {}
    for i = 1, MAT.PIP_MAX do
        local t = p:CreateTexture(nil, "ARTWORK")
        t:SetSize(MAT.PIP_SIZE, MAT.PIP_SIZE)
        t:SetPoint("RIGHT", p, "RIGHT", -(22 + (MAT.PIP_MAX - i) * (MAT.PIP_SIZE + 2)), 0)
        p.sq[i] = t
    end
    p:Hide()
    return p
end

-- held, need: counts (need nil hides the pips); estimated: held comes from the loot log; this: the drop adds one.
function Mat.SetPips(r, held, need, estimated, this)
    local p = r.pips
    need = tonumber(need)
    if not need or need < 1 then
        p:Hide()
        return
    end
    held = tonumber(held) or 0
    local n = min(need, MAT.PIP_MAX)
    for i = 1, MAT.PIP_MAX do
        local t, slot = p.sq[i], i - (MAT.PIP_MAX - n)   -- right-aligned: the last n squares
        if slot < 1 then
            t:Hide()
        else
            local r, g, b = S:Color("GOLD_DEEP")
            if slot <= held then
                t:SetColorTexture(r, g, b, 1)
            elseif slot == held + 1 and this then
                t:SetColorTexture(r, g, b, 0.4)
            else
                t:SetColorTexture(S:Color("EDGE_STRONG"))
            end
            t:Show()
        end
    end
    p.count:SetText(format("%d/%d", min(held, need), need))
    p.count:SetTextColor(S:Color(estimated and "SUB" or "TEXT"))
    p:Show()
end

local function NewEquippedButton(r)
    local e = CreateFrame("Button", nil, r)
    e:SetSize(EQ_SIZE, EQ_SIZE)
    e.icon = e:CreateTexture(nil, "ARTWORK")
    e.icon:SetAllPoints()
    e.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    e:SetScript("OnClick", EquippedOnClick)
    UI:AttachTooltip(e, EquippedTooltip)
    e:Hide()
    return e
end

-- The row grid's pieces (1.3.5 makeover): short spec names, the attendance %, the vote rail, the roll cells.
-- (Grid is declared with Dry: the file is near Lua's 200-locals limit.)

-- Spec names as raiders say them (the column is narrow; the row's tooltip has the full name).
Grid.SHORT = { ["Protection"] = "Prot", ["Retribution"] = "Ret", ["Beast Mastery"] = "BM", ["Marksmanship"] = "MM",
               ["Survival"] = "Surv", ["Assassination"] = "Assa", ["Subtlety"] = "Sub", ["Discipline"] = "Disc",
               ["Elemental"] = "Ele", ["Enhancement"] = "Enh", ["Restoration"] = "Resto", ["Affliction"] = "Affli",
               ["Demonology"] = "Demo", ["Destruction"] = "Destro", ["Feral (Cat)"] = "Cat", ["Feral (Bear)"] = "Bear",
               ["Feral"] = "Feral", ["Balance"] = "Boomy" }
function Grid.Spec(spec)
    if type(spec) ~= "string" then return "" end
    return Grid.SHORT[spec] or spec
end

-- The attendance % (council data; empty without a logged raid): green from 90, grey from 75, amber below.
function Grid.Att(r, key)
    local RL = ns.RaidLog
    local pv = key and Dry.preview[key]
    local p
    if pv then p = pv.att else p = key and IsCouncil() and RL and RL.GetAttendance and RL:GetAttendance(key) end
    if not p then
        r.att:SetText("")
        return
    end
    r.att:SetText(format("%d%%", p))
    r.att:SetTextColor(S:Color((p >= 90 and "OK") or (p >= 75 and "TEXT") or "WARN"))
end

-- Column titles over a card's rows (1.3.5, the user picked titles + dividers): small grey caps over the columns that
-- need a word, a hairline under them, and faint dividers where the column groups meet.
Grid.HEAD_H = 13
Grid.TITLES = {
    roll = { { "VOTE", 0, COL.rail, "CENTER" }, { "ATT", COL.att[1], COL.att[2], "RIGHT" },
             { "SINCE LOOT", COL.loot[1], 70, "LEFT" }, { "ROLL", COL.roll[1], COL.roll[2], "RIGHT" } },
    list = { { "ATT", COL.att[1], COL.att[2], "RIGHT" }, { "SINCE LOOT", COL.loot[1], 70, "LEFT" } },
}
Grid.DIVIDERS = { roll = { COL.loot[1] - 4, COL.roll[1] - 2 }, list = { COL.loot[1] - 4 } }

-- kind: "roll" / "list" / nil (hides them); top: the titles' y in the card; rowsH: the rows' height (dividers).
function Grid.Head(b, kind, top, rowsH)
    local h = b.colHead
    if not h then
        h = { fs = {}, divs = {} }
        h.line = UI:Rule(b)              -- (the shared hairline; placed under the titles below)
        b.colHead = h
    end
    for _, fs in ipairs(h.fs) do fs:Hide() end
    for _, d in ipairs(h.divs) do d:Hide() end
    h.line:Hide()
    if not kind then return end
    local railX = Grid.HasRail(b.rollSession) and 0 or nil
    do
        for i, t in ipairs(Grid.TITLES[kind]) do
            local fs = h.fs[i]
            if not fs then
                fs = UI:Text(b, "caps", "SUB")
                h.fs[i] = fs
            end
            if t[1] ~= "VOTE" or railX then
                fs:ClearAllPoints()
                fs:SetPoint("TOPLEFT", b, "TOPLEFT", LIST_X + t[2] + (t[1] == "VOTE" and -6 or 0), -(top + 1))
                fs:SetWidth(t[3] + (t[1] == "VOTE" and 12 or 0))
                fs:SetJustifyH(t[4])
                fs:SetText(t[1])
                fs:Show()
            end
        end
        h.line:ClearAllPoints()
        h.line:SetPoint("TOPLEFT", b, "TOPLEFT", LIST_X - 4, -(top + Grid.HEAD_H - 3))
        h.line:SetPoint("TOPRIGHT", b, "TOPRIGHT", -CARD_PAD + 4, -(top + Grid.HEAD_H - 3))
        h.line:Show()
    end
    if rowsH > 0 then
        for i, x in ipairs(Grid.DIVIDERS[kind]) do
            local d = h.divs[i]
            if not d then
                d = UI:Rule(b, { vertical = true })   -- (placed between the column groups below)
                h.divs[i] = d
            end
            d:ClearAllPoints()
            d:SetPoint("TOPLEFT", b, "TOPLEFT", LIST_X + x, -(top + Grid.HEAD_H + 3))
            d:SetHeight(rowsH - 6)
            d:Show()
        end
    end
end

-- Why a prized item's award isn't allowed yet: "breaks: 14% attendance, needs 75%", "1 of 3 votes".
function Grid.GateWhy(g)
    local parts = {}
    if g.broken then parts[#parts + 1] = "breaks: " .. tostring(g.fail or "a loot rule") end
    if (g.need or 0) > 0 and (g.votes or 0) < g.need then parts[#parts + 1] = format("%d of %d votes", g.votes or 0, g.need) end
    return tconcat(parts, " · ")
end

-- The gold award while it isn't allowed yet (g = Roll:PrizedReady, nil = no gate): greyed, with a pip per vote it
-- needs (gold when given) and a warning mark when a rule is broken; it turns gold as soon as it's allowed.
function Grid.AwardGate(btn, g)
    if not btn then return end
    btn.przGate = g
    if not btn.przPips then
        if not (g and not g.ok) then return end
        btn.przPips = {}
        for i = 1, 6 do
            local t = btn:CreateTexture(nil, "OVERLAY", nil, 2)
            t:SetSize(5, 5)
            btn.przPips[i] = t
        end
        btn.przWarn = UI:Text(btn, "small")
    end
    for _, t in ipairs(btn.przPips) do t:Hide() end
    btn.przWarn:Hide()
    local fs = btn.GetFontString and btn:GetFontString()
    if not (g and not g.ok) then
        if fs then
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", 0, 0)
        end
        return
    end
    btn:SetKind("secondary")
    local n = min(6, tonumber(g.need) or 0)
    local short = n > 0 and (g.votes or 0) < (g.need or 0)
    local extra = (short and (n * 8 + 4) or 0) + (g.broken and 16 or 0)
    btn:SetWidth((btn:GetWidth() or 96) + extra)
    if fs then
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", -extra / 2, 0)
    end
    local x = -10
    if short then
        for i = n, 1, -1 do
            local t = btn.przPips[i]
            t:ClearAllPoints()
            t:SetPoint("RIGHT", btn, "RIGHT", x, 0)
            if i <= (g.votes or 0) then t:SetColorTexture(S:Color("GOLD")) else t:SetColorTexture(1, 1, 1, 0.22) end
            t:Show()
            x = x - 8
        end
        x = x - 4
    end
    if g.broken then
        btn.przWarn:SetText(WarnIcon(11))
        btn.przWarn:ClearAllPoints()
        btn.przWarn:SetPoint("RIGHT", btn, "RIGHT", x, 0)
        btn.przWarn:Show()
    end
end

-- The council's view keeps the vote rail's room (a plain roll and the raiders' view have none).
function Grid.HasRail(session)
    return IsCouncil() and not PlainMode(nil, session)
end

-- The class circle and the name after it (right of the rail, or at the row's start); the name runs up to the spec.
function Grid.Place(r, rail)
    local x = rail and COL.cls[2] or COL.cls[1]
    r.cls:ClearAllPoints()
    r.cls:SetPoint("LEFT", r, "LEFT", x, 0)
    r.name:ClearAllPoints()
    r.name:SetPoint("LEFT", r, "LEFT", x + COL.name, 0)
    r.name:SetWidth(COL.spec[1] - 2 - x - COL.name)
end

-- The vote rail's square: the count (gold with my vote among them), a faint check where I may vote and nobody has,
-- nothing where I can't vote and nobody did (row nil hides it).
function Grid.Rail(r, row, canVote)
    local n = row and tonumber(row.votes) or 0
    if not row or (n == 0 and not canVote) then
        r.vEdge:Hide()
        r.vBox:Hide()
        r.votes:SetText("")
        r.votes:Hide()
        r.voteHint:Hide()
        return
    end
    r.vEdge:Show()
    r.votes:Show()
    -- (a split vote: the tied players' squares get an amber edge)
    if row.split then r.vEdge:SetColorTexture(1, 0.62, 0.2, 0.95) else r.vEdge:SetColorTexture(1, 1, 1, 0.22) end
    if n > 0 then
        if row.myVote then r.vBox:SetColorTexture(0.55, 0.44, 0.05, 1) else r.vBox:SetColorTexture(0.16, 0.16, 0.18, 1) end
        r.votes:SetText("|cffffffff" .. n .. "|r")
        r.voteHint:Hide()
    else
        r.vBox:SetColorTexture(0.08, 0.08, 0.09, 1)
        r.votes:SetText("")
        r.voteHint:Show()
    end
    r.vBox:Show()
end

-- The roll alone (red for a bad range); a repeated roll / the range go in the note after it.
function Grid.RollText(row, session)
    local n = tonumber(row.roll)
    if n then return row.invalid and Paint(tostring(n), "bad") or ("|cffffffff" .. tostring(n) .. "|r") end
    if row.response == "pass" then return Paint("pass", "muted") end
    if type(session) == "table" and session.state == "open" then return "" end   -- still rolling (the row is dimmed)
    return Paint("-", "muted")   -- (did not roll: the tooltip says so)
end

-- "x2" (rolled twice: the first roll counts) or the range of a bad roll ("1-50"; "!" when the note is narrow).
function Grid.RollNote(row, session, narrow)
    if tonumber(row.roll) and row.invalid then
        local rr = type(session) == "table" and type(session.rolls) == "table" and session.rolls[row.key]
        local lo = tonumber(row.min) or (type(rr) == "table" and tonumber(rr.min))
        local hi = tonumber(row.max) or (type(rr) == "table" and tonumber(rr.max))
        return Paint((lo and hi and not narrow) and format("%d-%d", lo, hi) or "!", "bad")
    end
    local c = tonumber(row.count) or 1
    if c > 1 then return Paint("x" .. c, "muted") end
    return ""
end

function DropPanel:NewRow(b)
    local r = CreateFrame("Button", nil, b)
    r:SetHeight(ROW_H)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- the shared row looks: the hover, and the selected look for the suggested roller (gold) / the winner (green): a
    -- soft fill with a 2 px bar on its left (Grid.Mark)
    UI:DecorateRow(r, { hover = true, selectable = true })
    -- the class circle with a presence dot on it (in the raid green, online yellow, offline grey)
    r.cls = r:CreateTexture(nil, "ARTWORK")
    r.cls:SetSize(15, 15)
    r.cls:SetPoint("LEFT", r, "LEFT", 0, 0)
    r.ring = r:CreateTexture(nil, "OVERLAY", nil, 1)
    r.ring:SetTexture(DISC)
    r.ring:SetSize(8, 8)
    r.ring:SetVertexColor(0.06, 0.06, 0.07, 1)
    r.ring:SetPoint("CENTER", r.cls, "BOTTOMRIGHT", -1, 2)
    r.dot = r:CreateTexture(nil, "OVERLAY", nil, 2)
    r.dot:SetTexture(DISC)
    r.dot:SetSize(6, 6)
    r.dot:SetPoint("CENTER", r.ring, "CENTER", 0, 0)
    r.name = Grid.Cell(r, "body", "TEXT", { COL.cls[1] + COL.name, 90 })
    r.spec = Grid.Cell(r, "small", "SUB", COL.spec)
    r.pill = UI:CreatePill(r, 16)
    r.pill:SetPoint("LEFT", r, "LEFT", COL.pill, 0)
    r.pill:Hide()
    r.badge = r.pill.fs      -- the pill's text: "BiS", "Alt P2", "OS"
    r.att = Grid.Cell(r, "small", "TEXT", COL.att, { justify = "RIGHT" })
    r.status = Grid.Cell(r, "small", "SUB", COL.status)
    r.tag = Grid.Cell(r, "small", "GOLD", COL.loot)
    -- ADDENDUM G: the vote rail (a square at the row's start: the count, gold with my vote in it); clicking it votes
    -- for the row's player (or takes my vote back).
    r.vEdge = r:CreateTexture(nil, "BACKGROUND", nil, 2)
    r.vEdge:SetSize(COL.rail + 2, COL.rail + 2)
    r.vEdge:SetPoint("LEFT", r, "LEFT", -1, 0)
    r.vEdge:SetColorTexture(1, 1, 1, 0.22)
    r.vEdge:Hide()
    r.vBox = r:CreateTexture(nil, "BORDER", nil, 1)
    r.vBox:SetSize(COL.rail, COL.rail)
    r.vBox:SetPoint("CENTER", r.vEdge, "CENTER", 0, 0)
    r.vBox:Hide()
    r.votes = UI:Text(r, "small", "TEXT", { justify = "CENTER", width = COL.rail })
    r.votes:SetPoint("CENTER", r.vBox, "CENTER", 0, 0)
    r.voteBtn = CreateFrame("Button", nil, r)
    r.voteBtn:SetPoint("CENTER", r.vBox, "CENTER", 0, 0)
    r.voteBtn:SetSize(COL.rail + 6, ROW_H)
    r.voteBtn:SetScript("OnClick", function(btn) DropPanel:ToggleVote(btn:GetParent()) end)
    r.voteBtn:SetScript("OnEnter", function(btn) RowOnEnter(btn:GetParent()) end)
    r.voteBtn:SetScript("OnLeave", UI.HideTooltip)
    r.voteBtn:Hide()
    -- a dim check where I may vote and nobody has yet (the click votes)
    r.voteHint = r:CreateTexture(nil, "ARTWORK")
    r.voteHint:SetSize(11, 11)
    r.voteHint:SetPoint("CENTER", r.vBox, "CENTER", 0, 0)
    r.voteHint:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    r.voteHint:SetDesaturated(true)
    r.voteHint:SetAlpha(0.35)
    r.voteHint:Hide()
    -- the roll, and a small note after it
    r.roll = Grid.Cell(r, "title", "TEXT", COL.roll, { justify = "RIGHT", font = S.FONT_NUM })
    r.note = Grid.Cell(r, "caps", "SUB", COL.note)
    r.moreText = Grid.Cell(r, "body", "SUB", { COL.cls[1], 200 })
    -- Two right-aligned "currently wearing" icons (paired slots show both, ADDENDUM A §18).
    r.eqs = { NewEquippedButton(r), NewEquippedButton(r) }
    r.eqs[2]:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    r.eqs[1]:SetPoint("RIGHT", r.eqs[2], "LEFT", -2, 0)
    r.eq = r.eqs[2]   -- v0.1 field name (single icon); a lone item sits in the right-hand column
    r.pips = Mat.NewPips(r)
    Dry.New(r, COL.loot[1])
    r:SetScript("OnEnter", RowOnEnter)
    r:SetScript("OnLeave", UI.HideTooltip)
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
            btn.icon:SetTexture(UI:ItemIcon(e.id))
            btn:Show()
        else
            btn.itemID, btn.label = nil, nil
            btn:Hide()
        end
    end
end

-- the presence dot: in the raid green, online gold, offline grey
local PRESENCE = { raid = "OK", online = "GOLD_DEEP", offline = "DIM" }
local function SetPresence(r, state)
    local r1, g1, b1 = S:Color(PRESENCE[state] or PRESENCE.offline)
    r.dot:SetVertexColor(r1, g1, b1, 1)
end

local function SetPill(r, text, kind)
    if text then
        r.pill:Set(text, kind)
        r.pill:Show()
    else
        r.pill.fs:SetText("")
        r.pill:Hide()
    end
end

-- "Alt" / "Alt P3" (a phase other than the one the council looks at).
local function PillText(base, phase, vp)
    local p = tonumber(phase)
    if p and p ~= vp then return base .. " P" .. p end
    return base
end

-- The pill of a BiS candidate (Store:GetWanters entry): text, kind.
local function WanterPill(w, vp)
    if w.os then return PillText("OS", w.phase, vp), "os" end           -- off-spec list (Addendum H)
    if w.which == "alt" then return PillText("Alt", w.phase, vp), "alt" end
    return PillText("BiS", w.phase, vp), "bis"
end

-- The pill of a roll result row (its tier), or nil: not on their list.
local function RollPill(row, vp)
    local tier = tonumber(row.tier) or 4
    if tier == 3 then return PillText("OS", row.phase, vp), "os" end
    if tier == 1 or tier == 2 then
        if tier == 2 or row.which == "alt" then return PillText("Alt", row.phase, vp), "alt" end
        return PillText("BiS", row.phase, vp), "bis"
    end
    if row.which and row.obtained then return "has it", "mute" end
    return nil
end

-- mode: "normal" (BiS candidates), "roll" (roll results) or "more" ("+N more").
local function SetRowMode(r, mode)
    local more, roll = mode == "more", mode == "roll"
    r.cls:SetShown(not more)
    r.ring:SetShown(not more)
    r.dot:SetShown(not more)
    r.name:SetShown(not more)
    r.spec:SetShown(not more)
    r.pill:Hide()
    r.status:SetShown(mode == "normal")
    r.status:SetText("")
    r.status:SetWidth(COL.status[2])
    r.pips:Hide()
    r.dry:Hide()
    r.tag:SetShown(roll)
    r.tag:SetText("")
    Grid.Rail(r, nil)
    r.att:SetShown(not more)
    r.att:SetText("")
    if not roll then
        r.voteBtn:Hide()
        r.canVote = nil
    end
    r.note:SetShown(roll)
    r.note:SetText("")
    r.roll:SetShown(roll)
    r.moreText:SetShown(more)
    if more then SetEquipped(r, {}) end
    r:SetSelected(false)
    r.rollRow = roll
    r:SetHeight(ROW_H)
end

-- The row's selected look in a tone: "SELECT" (the suggested roller: the shared gold) or "OK" (the winner: green).
function Grid.Mark(r, tone)
    if tone == "OK" then
        local cr, cg, cb = S:Color("OK")
        r.dzSelFill:SetColorTexture(cr, cg, cb, 0.09)
        r.dzSelBar:SetColorTexture(cr, cg, cb, 0.9)
    else
        r.dzSelFill:SetColorTexture(S:Color("SELECT"))
        r.dzSelBar:SetColorTexture(S:Color("SELECT_BAR"))
    end
    r:SetSelected(true)
end

local function FillRow(r, w, itemID, vp, itemSid)
    SetRowMode(r, "normal")
    r.data, r.itemID, r.more, r.moreKind, r.session, r.itemSid = w, itemID, nil, nil, nil, itemSid
    r.matOthers = nil
    Grid.Place(r, Grid.HasRail(nil))
    SetPresence(r, w.inRaid and "raid" or (w.online and "online" or "offline"))
    if ns.UI and ns.UI.ClassIcon then ns.UI:ClassIcon(r.cls, w.classFile) end
    r.name:SetText(ColoredName(w.key, w.classFile))
    r.spec:SetText(Grid.Spec(w.spec))
    Grid.Att(r, w.key)
    SetPill(r, WanterPill(w, vp))
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
    if w.craft then
        -- a crafting material: "completes it" and the holdings squares instead of the worn items
        if w.completes and w.inRaid and not w.cantUse then status = Paint("completes it", "main") end
        -- (the status runs up to the squares: fewer squares, more room)
        r.status:SetWidth(ROW_W - COL.status[1] - (22 + min(tonumber(w.need) or 0, MAT.PIP_MAX) * (MAT.PIP_SIZE + 2)) - 4)
        SetEquipped(r, {})
        Mat.SetPips(r, w.held, w.need, w.heldSrc == "log", true)
    else
        SetEquipped(r, WornOfWanter(w, itemSid))
    end
    local przTag = DropPanel.PrzTag(DropPanel.PrzCheck(itemID, w.key, w))
    if przTag and w.inRaid then status = przTag end
    r.status:SetText(status)
    if status == "" and not w.craft and not Dry.SetLow(r, w.key) then Dry.Set(r, w.key) end
    r:SetAlpha((w.inRaid and not przTag) and 1 or 0.55)
    return ROW_H
end

local function FillRollRow(r, row, session, itemID, vp, itemSid)
    SetRowMode(r, "roll")
    r.data, r.itemID, r.more, r.moreKind, r.session, r.itemSid = row, itemID, nil, nil, session, itemSid
    r.matOthers = nil
    local inRaid = row.inRaid
    if inRaid == nil then inRaid = IsInMyGroup(row.key) end
    SetPresence(r, inRaid and "raid" or "offline")
    local classFile = row.classFile or UI:ClassOf(row.key)
    if ns.UI and ns.UI.ClassIcon then ns.UI:ClassIcon(r.cls, classFile) end
    -- A plain roll (1.3): no BiS pill, no votes, no lock markers.
    local plain = PlainMode(nil, session)
    Grid.Place(r, Grid.HasRail(session))
    -- a pug: the name alone (the column is narrow), "guest" where their spec would be (we never have it)
    local guest = ns.UI and ns.UI.IsGuest and ns.UI:IsGuest(row.key)
    r.name:SetText(guest and ns.UI:ColoredName(row.key, classFile) or ColoredName(row.key, classFile))
    local spec = type(row.spec) == "string" and row.spec or ""
    r.spec:SetText((guest and spec == "") and "|cff66ccffguest|r" or Grid.Spec(spec))
    if not plain then Grid.Att(r, row.key) end
    if plain then SetPill(r, nil) else SetPill(r, RollPill(row, vp)) end
    local tag = RollTag(row, session)
    local przTag = not plain and DropPanel.PrzTag(row.prz)
    if przTag and not (type(session) == "table" and session.state == "awarded" and session.winner == row.key) then
        tag = przTag
    end
    -- §38: changed their list while the lists were locked (the warning icon in front of the tag)
    if not plain and LockChanged(row) and tag ~= "" and not tag:find("changed", 1, true) then
        tag = WarnIcon(10) .. " " .. tag
    end
    r.tag:SetText(tag)
    local canVote = not plain and type(session) == "table" and HasRoll("CanVote") and CallRoll("CanVote", session.id)
        and inRaid and row.response ~= "pass" and not row.cantUse and true or false
    r.canVote = canVote
    if Grid.HasRail(session) then Grid.Rail(r, row, canVote) end
    r.voteBtn:SetShown(canVote)
    r.roll:SetText(Grid.RollText(row, session))
    if row.need then
        -- a crafting material: what they hold of it toward their craft ("1/2", gold when this one completes it)
        SetEquipped(r, {})
        if tag == "" then
            r.tag:SetText(Paint(format("%d/%d", min(tonumber(row.held) or 0, row.need), row.need),
                row.completes and "main" or "muted"))
        end
    else
        SetEquipped(r, WornOfRow(row, itemSid))
        if tag == "" and not plain and not (row.lowAtt and Dry.SetLow(r, row.key, row.att, row.lowAtt)) then Dry.Set(r, row.key) end
    end
    -- (a bad range needs more room than "x2": it takes the first worn icon's place when there is only one)
    r.note:SetWidth(r.eqs[1]:IsShown() and COL.note[2] or (ROW_W - EQ_SIZE - 2 - COL.note[1]))
    r.note:SetText(Grid.RollNote(row, session, r.eqs[1]:IsShown()))

    local winner = type(session) == "table" and session.state == "awarded" and session.winner == row.key
    if winner then
        Grid.Mark(r, "OK")
    elseif row.suggested then
        Grid.Mark(r, "SELECT")
    end
    local alpha = 1
    if row.response == "pass" and not tonumber(row.roll) then
        alpha = 0.5
    elseif not tonumber(row.roll) then
        alpha = 0.7
    elseif not inRaid then
        alpha = 0.6
    end
    if row.prz and row.prz.ok == false and not winner then alpha = min(alpha, 0.55) end
    -- (a class that can't use it: greyed at the bottom, next to the passes)
    if row.cantUse and not winner then alpha = min(alpha, 0.5) end
    r:SetAlpha(alpha)
    return ROW_H
end

local function FillMoreRow(r, rest, kind, session)
    SetRowMode(r, "more")
    r.data, r.more, r.moreKind, r.session, r.matOthers = nil, rest, kind, session, nil
    r.moreText:ClearAllPoints()
    r.moreText:SetPoint("LEFT", r, "LEFT", Grid.HasRail(session) and COL.cls[2] or COL.cls[1], 0)
    r.moreText:SetText(format("+%d more", #rest))
    r:SetAlpha(1)
    return ROW_H
end

-- A gold-text link ("Show rolls (3)" / "Hide"): white while hovered (UI:CreateTextLink).
local function NewLink(parent, onClick)
    local l = UI:CreateTextLink(parent, "", onClick, { color = "GOLD", hover = "TEXT", align = "RIGHT", pad = 4 })
    l.label = l.fs
    return l
end

-- An item card: its icon, name and second line (the slot, the roll's state or who got it), the BiS candidates or the
-- rolls, and one row of actions: the roll button (Roll / End roll / Re-roll / Cancel) and the gold award (Award, or
-- Award to the suggested roller). Occasional actions sit in the card's More menu (top right).
function DropPanel:NewBlock(parent)
    -- the shared card (its fill and 1 px edge; a prized item's card glows: DropPanel.PrzGlow recolours the edge)
    local b = UI:CreateCard(parent, { tone = "card", pad = CARD_PAD })
    b.rows = {}

    b.button = UI:CreateItemButton(b, ICON_SIZE)
    b.button:SetPoint("TOPLEFT", b, "TOPLEFT", CARD_PAD, -CARD_PAD)

    b.moreBtn = UI:CreateTipIconButton(b, S.ROW.compact, UI.ICON.more, "More", nil, function(self) DropPanel:OpenMoreMenu(b, self) end)
    b.moreBtn.icon:ClearAllPoints()
    b.moreBtn.icon:SetPoint("TOPLEFT", 3, -3)
    b.moreBtn.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    b.moreBtn:SetPoint("TOPRIGHT", b, "TOPRIGHT", -CARD_PAD + 2, -CARD_PAD + 2)

    b.name = UI:Text(b, "title", "TEXT")
    b.name:SetPoint("TOPLEFT", b, "TOPLEFT", TEXT_X, -CARD_PAD)
    b.name:SetWidth(CARD_W - TEXT_X - CARD_PAD - 30)

    -- Second line: the item type, the roll's state, or who got it (b.awarded).
    b.sub = UI:Text(b, "sub")
    b.sub:SetPoint("TOPLEFT", b, "TOPLEFT", TEXT_X, -(CARD_PAD + 18))
    b.awarded = UI:Text(b, "body")
    b.awarded:SetPoint("TOPLEFT", b, "TOPLEFT", TEXT_X, -(CARD_PAD + 18))
    b.awarded:Hide()

    b.none = UI:Text(b, "sub")
    b.none:SetText("Nobody has this on their BiS list")

    -- Awarded items: show / hide the folded rolls (FillBlock), at the end of the second line.
    b.fold = NewLink(b, function() DropPanel:ToggleFold(b.itemID, b.copy) end)
    b.fold:SetPoint("TOPRIGHT", b, "TOPRIGHT", -CARD_PAD, -(CARD_PAD + 16))
    b.fold:Hide()

    local function slotButton(text, onClick)
        return UI:CreateSleekButton(b, text, SLOT_W, ACTION_H, onClick)
    end
    b.rollBtn = slotButton("Roll", function() DropPanel:StartRoll(b.itemID, b.copy) end)
    Look.Tip(b.rollBtn, function()
        local text = "Start a roll: everyone in the " .. GroupWord() .. " gets a Roll / Pass popup (a normal /roll 1-100). "
            .. "DisasterZone suggests the winner: BiS main first, then BiS alt, then everyone else; "
            .. "the highest roll wins within each group. You confirm the award."
        if PlainMode(DropPanel.drop) then
            text = "Start a roll: everyone in the raid gets a Roll / Pass popup, and players without DisasterZone type "
                .. "/roll. The loot council is off for this raid, so the highest roll is suggested (BiS lists don't "
                .. "count). You confirm the award."
        end
        if DemoEnabled() then text = text .. "\n\nDemo mode: fake raiders roll; nothing is sent." end
        return text
    end)
    b.endRoll = slotButton("End roll", function() DropPanel:EndRoll(b.rollSession) end)
    Look.Tip(b.endRoll, function()
        return "Close the roll now. Rolls that arrive afterwards are ignored."
    end)
    b.reroll = slotButton("Re-roll", function() DropPanel:ConfirmReroll(b) end)
    Look.Tip(b.reroll, function()
        return "Start a new roll for this item (for example after a tie or when nobody rolled). "
            .. "The rolls so far are discarded."
    end)
    b.unqueue = slotButton("Cancel", function() DropPanel:EndRoll(b.queuedSession) end)
    Look.Tip(b.unqueue, function()
        return "Take this item out of the roll queue."
    end)
    b.award = UI:CreateSleekButton(b, "Award", SLOT_W, ACTION_H, function() DropPanel:OpenAwardMenu(b, b.award) end)
    Look.Tip(b.award, function()
        if DropPanel.drop and DropPanel.drop.test then
            return "Demo mode: awards go to a temporary demo log that is never saved or sent."
        end
        local s = b.rollSession
        if type(s) == "table" and (s.state == "open" or s.state == "closed") then
            return "Award this item: closes its roll and everyone's Roll / Pass popup, "
                .. "and records the award in the loot log."
        end
        return "Pick who receives this item: its BiS candidates first, then the rest of the " .. GroupWord()
            .. ". The award goes in the loot log."
    end)
    b.awardRoll = UI:CreateSleekButton(b, "Award", 110, ACTION_H, function() DropPanel:AwardSuggested(b) end)
    Look.Tip(b.awardRoll, function() return DropPanel:AwardSuggestedTooltip(b) end)
    -- a crafting material: award it straight to the best wanter (whoever it completes a craft for, then the closest)
    b.awardMat = UI:CreateSleekButton(b, "Award", 110, ACTION_H, function() DropPanel:AwardMaterialBest(b) end)
    Look.Tip(b.awardMat, function()
        local w = b.matBest
        if type(w) ~= "table" then return "" end
        local why = w.completes and "this one completes their craft"
            or format("they will have %d of %d", (tonumber(w.held) or 0) + 1, tonumber(w.need) or 0)
        return format("Award to %s for %s: %s.\n\nFirst whoever a drop completes a craft for, then whoever is "
            .. "closest, BiS before off-spec. The More menu's Award picks someone else.", ShortName(w.key),
            ItemName(w.craft), why)
    end)
    b.actionButtons = { b.rollBtn, b.endRoll, b.reroll, b.unqueue, b.award, b.awardRoll, b.awardMat }
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
    r:SetPoint("TOPLEFT", b, "TOPLEFT", LIST_X, -y)
    r:SetPoint("TOPRIGHT", b, "TOPRIGHT", -CARD_PAD, -y)
    r:Show()
end

-- Shows `buttons` left to right on the action line (y), from the text column.
local function LayoutActions(b, y, buttons)
    for _, btn in ipairs(b.actionButtons) do
        btn:Hide()
        btn:ClearAllPoints()
    end
    local x = LIST_X
    for _, btn in ipairs(buttons) do
        btn:SetPoint("TOPLEFT", b, "TOPLEFT", x, -y)
        btn:Show()
        x = x + (btn:GetWidth() or SLOT_W) + 6
    end
end

-- The gold award of a roll: "Award to <suggested roller>" (while the roll is open, the click also ends it).
local function SetAwardRollButton(btn, row)
    if not row then return end
    btn:SetText("Award to " .. ShortName(row.key))
    btn:Enable()
    local fs = btn.GetFontString and btn:GetFontString()
    local w = fs and tonumber(fs:GetStringWidth()) or 0
    btn:SetWidth(min(220, max(96, w + 24)))
end


---------------------------------------------------------------------------
-- Crafting materials (Materials): a craft's header line, the "+N more crafts" line and an awarded material's craft
---------------------------------------------------------------------------
function Mat.PresenceOf(key)
    if IsInMyGroup(key) then return "in " .. GroupWord() end
    if IsMe(key) or (ns.Guild and ns.Guild.IsOnline and ns.Guild:IsOnline(key)) then return "online" end
    return "offline"
end

-- "No Swordsmith in the guild" / "Nobody in the guild crafts it" (only members who share professions are known).
function Mat.NoCrafterText(use)
    if type(use.spec) == "string" and use.spec ~= "" then return "No " .. use.spec .. " in the guild" end
    return "Nobody in the guild crafts it"
end

function Mat.ProfIcon(use)
    return use.prof and use.prof.icon or nil
end

function Mat.AddCraftersTooltip(tt, use)
    local M = ns.Materials
    local list = M and M.GetCrafters and M:GetCrafters(use) or {}
    if #list == 0 then
        local w = Color("warn")
        tt:AddLine(Mat.NoCrafterText(use), w[1], w[2], w[3])
        tt:AddLine("Only members who opened their profession window with DisasterZone are known.", 0.6, 0.6, 0.6, true)
        return
    end
    tt:AddLine("Crafted by", S:RGB("GOLD"))
    for _, key in ipairs(list) do
        tt:AddDoubleLine(ColoredName(key), Mat.PresenceOf(key), 1, 1, 1, 0.6, 0.6, 0.6)
    end
end

function Mat.MatHeadOnEnter(self)
    local use = self.use
    if type(use) ~= "table" then return end
    local tt = _G.GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    tt:SetItemByID(use.item)
    tt:AddLine(" ")
    tt:AddLine(format("Takes %d %s", use.count, ItemName(self.itemID)), 0.8, 0.8, 0.8)
    Mat.AddCraftersTooltip(tt, use)
    tt:Show()
end

function Mat.MatHeadOnClick(self)
    if self.use and ns.UI and ns.UI.HandleModifiedItemClick then ns.UI:HandleModifiedItemClick(self.use.item) end
end

function DropPanel:GetMatHead(b, i)
    b.matHeads = b.matHeads or {}
    local h = b.matHeads[i]
    if h then return h end
    h = CreateFrame("Button", nil, b)
    h:SetHeight(ROW_H)
    h.rule = UI:Rule(h, { top = -1, layer = "BACKGROUND" })
    h.icon = h:CreateTexture(nil, "ARTWORK")
    h.icon:SetSize(14, 14)
    h.icon:SetPoint("LEFT", h, "LEFT", 0, 0)
    h.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    h.name = UI:Text(h, "body")
    h.name:SetPoint("LEFT", h.icon, "RIGHT", 5, 0)
    h.per = UI:Text(h, "small", "SUB")
    h.per:SetPoint("LEFT", h.name, "RIGHT", 6, 0)
    h.crafter = UI:Text(h, "small", "TEXT", { justify = "RIGHT" })
    h.crafter:SetPoint("RIGHT", h, "RIGHT", 0, 0)
    h.prof = h:CreateTexture(nil, "ARTWORK")
    h.prof:SetSize(12, 12)
    h.prof:SetPoint("RIGHT", h.crafter, "LEFT", -4, 0)
    h.prof:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    h:SetScript("OnEnter", Mat.MatHeadOnEnter)
    h:SetScript("OnLeave", UI.HideTooltip)
    h:SetScript("OnClick", Mat.MatHeadOnClick)
    b.matHeads[i] = h
    return h
end

-- One craft's header: the item, "2 per craft", and the crafter on the right (the group's best wanter when they
-- craft it themselves, else someone in the raid, online, any), or a warning when nobody in the guild crafts it.
function Mat.FillMatHead(h, use, itemID, forKey, first)
    h.use, h.itemID = use, itemID
    h.rule:SetShown(not first)
    h.icon:SetTexture(UI:ItemIcon(use.item))
    h.per:SetText(format("%d per craft", use.count))
    local M = ns.Materials
    local key = M and M.PickCrafter and M:PickCrafter(use, forKey)
    local icon = Mat.ProfIcon(use)
    if key then
        h.crafter:SetText(ColoredName(key) .. Paint(" · " .. Mat.PresenceOf(key), "muted"))
    else
        h.crafter:SetText(Paint(Mat.NoCrafterText(use), "warn"))
    end
    h.prof:SetTexture(icon)
    h.prof:SetShown(icon ~= nil)
    -- the name takes what is left (it never pushes the crafter off the line)
    local right = (h.crafter:GetStringWidth() or 0) + (icon and 16 or 0) + 8
    local per = (h.per:GetStringWidth() or 0) + 6
    h.name:SetWidth(1000)
    h.name:SetText(ItemText(use.item))
    local room = ROW_W - 19 - per - right
    h.name:SetWidth(max(40, min(room, (h.name:GetStringWidth() or 0) + 2)))
    return ROW_H
end

-- The "+N more crafts" line of a material: crafts nobody here has on a list, in its tooltip.
function Mat.MatOthersOnEnter(self)
    local list = self.matOthers
    if type(list) ~= "table" then return end
    local tt = _G.GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    tt:AddLine(format("%d more crafts use %s", #list, ItemName(self.itemID)), S:Color("GOLD"))
    local M = ns.Materials
    for _, use in ipairs(list) do
        local key = M and M.PickCrafter and M:PickCrafter(use)
        tt:AddDoubleLine(ItemText(use.item) .. Paint(format("  x%d", use.count), "muted"),
            key and ColoredName(key) or Paint(Mat.NoCrafterText(use), "muted"), 1, 1, 1, 0.8, 0.8, 0.8)
    end
    tt:AddLine("Not on anyone's list here", 0.6, 0.6, 0.6)
    tt:Show()
end

-- The craft line of an awarded material: "[Belt of Blasting] 2/2 · ready to craft", and on the right who crafts it
-- with a Whisper button (or "Crafted by the winner").
function Mat.MadeOnEnter(self)
    local m = self:GetParent()
    local use = m.use
    if type(use) ~= "table" then return end
    local tt = _G.GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    tt:SetItemByID(use.item)
    tt:AddLine(" ")
    Mat.AddCraftersTooltip(tt, use)
    tt:Show()
end

function DropPanel:GetMade(b)
    if b.made then return b.made end
    local m = CreateFrame("Frame", nil, b)
    m:SetHeight(MAT.MADE_H)
    m.bg = UI:Fill(m, "QUIET", "BACKGROUND")
    m.hit = CreateFrame("Button", nil, m)
    m.hit:SetPoint("TOPLEFT", m, "TOPLEFT", 0, 0)
    m.hit:SetPoint("BOTTOMLEFT", m, "BOTTOMLEFT", 0, 0)
    m.hit:SetScript("OnEnter", Mat.MadeOnEnter)
    m.hit:SetScript("OnLeave", UI.HideTooltip)
    m.icon = m:CreateTexture(nil, "ARTWORK")
    m.icon:SetSize(14, 14)
    m.icon:SetPoint("LEFT", m, "LEFT", 6, 0)
    m.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    m.name = UI:Text(m, "body")
    m.name:SetPoint("LEFT", m.icon, "RIGHT", 5, 0)
    m.prog = UI:Text(m, "small", "TEXT")
    m.prog:SetPoint("LEFT", m.name, "RIGHT", 6, 0)
    m.whisper = UI:CreateSleekButton(m, "Whisper", 58, 18, function() DropPanel:WhisperCrafter(b) end)
    m.whisper:SetPoint("RIGHT", m, "RIGHT", -2, 0)
    Look.Tip(m.whisper, function()
        return "Whisper the crafter how many the winner has now, and for which craft."
    end)
    m.crafter = UI:Text(m, "small", "TEXT", { justify = "RIGHT" })
    m.prof = m:CreateTexture(nil, "ARTWORK")
    m.prof:SetSize(12, 12)
    m.prof:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    m.prof:SetPoint("RIGHT", m.crafter, "LEFT", -4, 0)
    b.made = m
    return m
end

-- What an awarded material counts toward: the winner's craft and how many they have with it (a report from before
-- the award gets it added; the loot log already counts it). nil when no craft on their lists uses it.
function Mat.MadeOf(itemID, winnerKey, award, vp)
    local M = ns.Materials
    if not (M and M.IsMaterial and M:IsMaterial(itemID)) then return nil end
    local w = M:GetWants(itemID, { viewPhase = vp }).byKey[winnerKey]
    if not w then return nil end
    local have = tonumber(w.held) or 0
    local at = type(award) == "table" and tonumber(award.ts) or nil
    if w.heldSrc == "report" and (not at or (tonumber(w.heldAt) or 0) <= at) then have = have + 1 end
    return w, min(have, w.need)
end

function DropPanel:FillMade(b, itemID, winnerKey, award, vp, y)
    local w, have = Mat.MadeOf(itemID, winnerKey, award, vp)
    if not w then
        if b.made then b.made:Hide() end
        return y
    end
    local m = self:GetMade(b)
    local M = ns.Materials
    local use = M:GetUse(itemID, w.craft)
    m.use, m.winner, m.have, m.itemID = use, winnerKey, have, itemID
    m.icon:SetTexture(UI:ItemIcon(w.craft))
    m.name:SetWidth(1000)
    m.name:SetText(ItemText(w.craft))
    local ready = have >= w.need
    m.prog:SetText(ready and Paint(format("%d/%d · ready to craft", have, w.need), "obtained")
        or Paint(format("%d/%d", have, w.need), "muted"))
    local key = use and M:PickCrafter(use, winnerKey)
    m.crafterKey = key
    local icon = use and Mat.ProfIcon(use)
    m.crafter:ClearAllPoints()
    local canWhisper = key and key ~= winnerKey and not IsMe(key)
    if canWhisper then
        m.crafter:SetPoint("RIGHT", m.whisper, "LEFT", -6, 0)
        m.crafter:SetText(ColoredName(key))
    else
        m.crafter:SetPoint("RIGHT", m, "RIGHT", -6, 0)
        if not key then
            m.crafter:SetText(Paint(use and Mat.NoCrafterText(use) or "", "warn"))
        elseif key == winnerKey then
            m.crafter:SetText(Paint("Crafted by the winner", "muted"))
        else
            m.crafter:SetText(Paint("You craft it", "muted"))
        end
    end
    m.whisper:SetShown(canWhisper and true or false)
    m.prof:SetTexture(icon)
    m.prof:SetShown(icon ~= nil and key ~= nil)
    -- the crafter never overlaps the craft: "ready to craft" goes first, then the name gets shorter
    local avail = ROW_W - 6 - 19 - (m.crafter:GetStringWidth() or 0) - ((icon and key) and 16 or 0)
        - (canWhisper and 64 or 6) - 12
    if ready and (m.name:GetStringWidth() or 0) + 6 + (m.prog:GetStringWidth() or 0) > avail then
        m.prog:SetText(Paint(format("%d/%d", have, w.need), "obtained"))
    end
    local nameRoom = avail - 6 - (m.prog:GetStringWidth() or 0)
    m.name:SetWidth(max(40, min(nameRoom, (m.name:GetStringWidth() or 0) + 2)))
    m.hit:SetWidth(max(40, 25 + (m.name:GetStringWidth() or 0)))
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", b, "TOPLEFT", LIST_X, -y)
    m:SetPoint("TOPRIGHT", b, "TOPRIGHT", -CARD_PAD, -y)
    m:Show()
    return y + MAT.MADE_H
end

-- Whisper: "Shadowmelder has 1/2 [Nether Vortex] for [Belt of Deep Shadow]" to the crafter.
function DropPanel:WhisperCrafter(b)
    local m = b and b.made
    if not (m and m.use and m.crafterKey and m.winner) then return end
    local line = format("%s has %d/%d %s for %s", ShortName(m.winner), m.have or 0, m.use.count,
        ItemLink(m.itemID) or ItemName(m.itemID), ItemLink(m.use.item) or ItemName(m.use.item))
    if DemoEnabled() or (self.drop and self.drop.test) then
        ns:Print("[not sent] To %s: %s", ShortName(m.crafterKey), line)
        return
    end
    if _G.SendChatMessage then _G.SendChatMessage(line, "WHISPER", nil, m.crafterKey) end
end

-- A material's candidates, grouped by craft: each craft's header, then up to MAT_PER_GROUP wanters ("+N more" past
-- that), then one "+N more crafts" line for the crafts nobody here wants. Returns y, rowIdx, headIdx.
function DropPanel:FillMaterial(b, mat, itemID, vp, y)
    local rowIdx, headIdx = 0, 0
    for gi, g in ipairs(mat.groups) do
        if gi > MAT.MAT_GROUPS then break end
        headIdx = headIdx + 1
        local h = self:GetMatHead(b, headIdx)
        y = y + (gi > 1 and 4 or 0)
        local hh = Mat.FillMatHead(h, g.use, itemID, g.wanters[1] and g.wanters[1].key, gi == 1)
        PlaceRow(h, b, y)
        y = y + hh
        local n = #g.wanters
        local limit = (n > MAT.MAT_PER_GROUP + 1) and MAT.MAT_PER_GROUP or n
        for i = 1, limit do
            rowIdx = rowIdx + 1
            local r = self:GetRow(b, rowIdx)
            local rh = FillRow(r, g.wanters[i], itemID, vp, nil)
            PlaceRow(r, b, y)
            y = y + rh
        end
        if n > limit then
            rowIdx = rowIdx + 1
            local rest = {}
            for i = limit + 1, n do rest[#rest + 1] = g.wanters[i] end
            local r = self:GetRow(b, rowIdx)
            PlaceRow(r, b, y)
            y = y + FillMoreRow(r, rest, "wanters")
        end
    end
    local others = {}
    for gi = MAT.MAT_GROUPS + 1, #mat.groups do others[#others + 1] = mat.groups[gi].use end
    for _, use in ipairs(mat.others) do others[#others + 1] = use end
    if #others > 0 and headIdx > 0 then
        rowIdx = rowIdx + 1
        local r = self:GetRow(b, rowIdx)
        FillMoreRow(r, {}, "crafts")
        r.matOthers = others
        r.moreText:SetText(format("+%d more crafts use it", #others))
        y = y + 2
        PlaceRow(r, b, y)
        y = y + ROW_H
    end
    return y, rowIdx, headIdx
end

-- The award button of a material's card: "Award to <the best wanter in the raid>".
function DropPanel:AwardMaterialBest(b)
    local w = b and b.matBest
    local drop = self.drop
    if type(w) ~= "table" or type(drop) ~= "table" then return end
    self:Award(b.itemID, w.key, type(drop.b) == "string" and drop.b or "", b.copy, drop, nil, WanterReason(w))
end

-- Awarded items whose rolls were opened again (per item and copy, until the panel shows another drop).
function DropPanel:IsUnfolded(itemID, copy)
    return self.unfolded ~= nil and self.unfolded.drop == self.drop and self.unfolded[tostring(itemID) .. ":" .. tostring(copy or 1)] == true
end

function DropPanel:ToggleFold(itemID, copy)
    if not itemID then return end
    if not (self.unfolded and self.unfolded.drop == self.drop) then self.unfolded = { drop = self.drop } end
    local k = tostring(itemID) .. ":" .. tostring(copy or 1)
    self.unfolded[k] = not self.unfolded[k] or nil
    self:RequestRefresh(0)
end

-- Paints one item card; returns its height. copy: which copy of itemID in the drop (1 = first).
function DropPanel:FillBlock(b, itemID, award, drop, vp, canRoll, copy)
    b.itemID = itemID
    b.copy = copy
    b.awardEntry = award
    b.button:SetItem(itemID)
    DropPanel.PrzGlow(b, DropPanel.PrzRec(itemID) ~= nil)
    UI:FitText(b.name, DropPanel.PrzName(itemID, ItemText(itemID)), CARD_W - TEXT_X - CARD_PAD - 30)

    local session, mode, queuePos = RollStateFor(itemID, drop, copy)
    local rolling = mode == "roll" and session ~= nil
    b.rollSession = rolling and session or nil
    b.queuedSession = (mode == "queued") and session or nil
    b.rollStats, b.suggested, b.results = nil, nil, nil
    local winnerKey = award and award.w
        or (rolling and session.state == "awarded" and type(session.winner) == "string" and session.winner) or nil
    b.button:SetState(winnerKey and "awarded" or nil)
    local itemSid = FirstSlotOfItem(itemID)

    -- Roll mode lists roll results; the Award menu then fetches the wanters itself. The plain roll panel (1.3, no
    -- loot council) lists no BiS candidates.
    local plain = PlainMode(drop, rolling and session or nil)
    local wanters = (not rolling) and (plain and {} or UniqueWanters(itemID, { includeObtained = false, list = "both" }))
        or nil
    b.wanters = wanters
    local mat = (not rolling and not plain) and MaterialWants(itemID, vp) or nil
    b.matBest = nil

    local y, rowIdx, n, headIdx = ITEM_HEAD_H, 0, 0, 0
    local headKind   -- the column titles over the rows: "roll" / "list" (nil: none)
    local noneText = (not plain) and "Nobody has this on their BiS list" or nil
    if rolling then
        local results = {}
        local raw = CallRoll("GetResults", session.id)
        if type(raw) == "table" then
            for _, row in ipairs(raw) do
                if type(row) == "table" and type(row.key) == "string" then results[#results + 1] = row end
            end
        end
        b.results = results
        local rolled, passed, tie, votes, split, picked = RollCounts(results)
        b.rollStats = { rolled = rolled, passed = passed, tie = tie, votes = votes, split = split, picked = picked }
        -- (a prized item the council decides: how many of them must agree, shown with the votes)
        local przRec = DropPanel.PrzRec(itemID)
        if przRec and ns.Prized.NeededVotes then
            local need = ns.Prized:NeededVotes(przRec, #ns.Prized:PresentCouncil())
            if need > 0 then b.rollStats.need = need end
        end
        for _, row in ipairs(results) do
            if row.suggested then
                b.suggested = row
                break
            end
        end
        n = #results
        if n > 0 and not plain then
            headKind = "roll"
            y = y + Grid.HEAD_H
        end
        b.sub:SetText(DropPanel.PrzSub(itemID, RollStateText(session, b.rollStats), true))
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
        noneText = session.state == "open" and "Waiting for rolls" or "Nobody rolled"
        if session.state == "open" then
            -- While the roll is open, keep room for all rows (up to MAX_ROLL_ROWS + "+N more", at most the group
            -- size): incoming rolls must not move End roll / Award (or the panel) under the cursor.
            local groupN = tonumber((_G.GetNumGroupMembers and _G.GetNumGroupMembers())) or 0
            local reserve = min(MAX_ROLL_ROWS + 1, max(1, groupN))
            b.reservedY = ITEM_HEAD_H + (headKind and Grid.HEAD_H or 0) + reserve * ROLL_ROW_H
        else
            b.reservedY = nil
        end
    elseif mat then
        -- a crafting material: its candidates grouped by the craft they want it for
        b.reservedY = nil
        n = #mat.wants
        b.sub:SetText(mode == "queued" and RollStateText(nil, nil, queuePos or 1) or "Crafting material")
        y, rowIdx, headIdx = self:FillMaterial(b, mat, itemID, vp, y)
        noneText = "No craft that uses it is on anyone's list"
    else
        b.reservedY = nil
        n = #wanters
        if n > 0 and IsCouncil() then
            headKind = "list"
            y = y + Grid.HEAD_H
        end
        if mode == "queued" then
            b.sub:SetText(DropPanel.PrzSub(itemID, RollStateText(nil, nil, queuePos or 1)))
        else
            b.sub:SetText(DropPanel.PrzSub(itemID, ItemSubtitle(itemID)))
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
    -- An awarded item folds its rolls / wanters away (they take a lot of room once it is dealt with); the
    -- "Show rolls" link on its second line opens them again.
    local folded = winnerKey ~= nil and n > 0 and not self:IsUnfolded(itemID, copy)
    if folded then headKind = nil end
    Grid.Head(b, headKind, ITEM_HEAD_H, rowIdx > 0 and (y - ITEM_HEAD_H - Grid.HEAD_H) or 0)
    if folded then
        rowIdx, headIdx, y = 0, 0, ITEM_HEAD_H
        b.reservedY = nil
    end
    for i = headIdx + 1, #(b.matHeads or {}) do b.matHeads[i]:Hide() end
    if winnerKey and n > 0 then
        b.fold:SetLabel(folded and format("Show %s (%d)", rolling and "rolls" or "list", n) or "Hide")
        b.fold:Show()
    else
        b.fold:Hide()
    end
    for i = rowIdx + 1, #b.rows do b.rows[i]:Hide() end
    local anyRows = rowIdx > 0
    -- an awarded material: the craft it counts toward and who crafts it
    if winnerKey and (folded or n == 0) then
        local y2 = self:FillMade(b, itemID, winnerKey, award, vp, y + 2)
        if y2 > y + 2 then
            y = y2
            anyRows = true
        end
    elseif b.made then
        b.made:Hide()
    end

    -- Nothing to list: one quiet line (none for an awarded item or the plain panel's items).
    if n == 0 and not winnerKey and noneText then
        b.none:SetText(noneText)
        b.none:ClearAllPoints()
        b.none:SetPoint("TOPLEFT", b, "TOPLEFT", LIST_X, -(y + 4))
        b.none:Show()
        y = y + ROW_H
        anyRows = true
    else
        b.none:Hide()
    end
    if b.reservedY and y < b.reservedY then y = b.reservedY end

    -- The action row: the roll button's slot (Roll / End roll / Re-roll / Cancel), then the gold award. 1.3:
    -- Roll:CanAward / CanEnd follow the roll's own rules (with the loot council on only the council awards; a plain
    -- roll's master looter may too); whoever may start rolls may re-roll.
    local manage = canRoll or IsCouncil()
    local canAward = rolling and RollAllows("CanAward", manage, session.id) or false
    -- the council records awards in the log; an item with an open / closed roll can also be awarded by whoever may
    -- award that roll (a plain roll's master looter), because the award then goes through the roll.
    local rollAwardable = rolling and not winnerKey and (session.state == "open" or session.state == "closed")
    local canAwardItem = IsCouncil() or (rollAwardable and canAward)
    local locked = FakeDropLocked(drop)
    local slot, gold
    if rolling then
        if not winnerKey then
            if session.state == "open" then
                if RollAllows("CanEnd", manage, session.id) then slot = b.endRoll end
                if canAward and b.suggested then gold = b.awardRoll end
            else
                if canRoll then slot = b.reroll end
                if canAward then gold = b.suggested and b.awardRoll or b.award end
            end
            SetAwardRollButton(b.awardRoll, b.suggested)
        end
    elseif not winnerKey then
        if mode == "normal" and canRoll then
            slot = b.rollBtn
        elseif mode == "queued" and b.queuedSession and RollAllows("CanEnd", manage, b.queuedSession.id) then
            slot = b.unqueue
        end
        if canAwardItem and not locked then gold = b.award end
        -- a crafting material: "Award to <the best wanter in the raid>" (the menu stays in More)
        local best = mat and mat.wants[1]
        if gold == b.award and best and best.inRaid and not best.cantUse then
            b.matBest = best
            b.awardMat:SetText("Award to " .. ShortName(best.key))
            local fs = b.awardMat.GetFontString and b.awardMat:GetFontString()
            b.awardMat:SetWidth(min(220, max(96, (fs and tonumber(fs:GetStringWidth()) or 0) + 24)))
            gold = b.awardMat
        end
    end
    b.award:Enable()
    -- one gold button: the award (Roll on the plain roll panel, where the highest roll decides)
    local primary = gold
    if plain and not rolling and slot == b.rollBtn then primary = b.rollBtn end
    for _, btn in ipairs(b.actionButtons) do btn:SetKind(btn == primary and "primary" or "secondary") end
    -- 1.3.5: a prized item's award that isn't allowed yet (rules / the council's votes): greyed, with why
    local gate = gold == b.awardRoll and rolling and b.suggested and HasRoll("PrizedReady")
        and CallRoll("PrizedReady", session.id, b.suggested.key) or nil
    Grid.AwardGate(b.awardRoll, gate)
    local buttons = {}
    if slot then buttons[#buttons + 1] = slot end
    if gold then buttons[#buttons + 1] = gold end
    if #buttons > 0 then
        y = y + (anyRows and 8 or 0)
        LayoutActions(b, y, buttons)
        y = y + ACTION_H
    else
        LayoutActions(b, y, buttons)
        if not anyRows then y = CARD_PAD + ICON_SIZE end
    end

    -- The More menu: Announce; Disenchant / Guild bank (ADDENDUM G §41) while nobody is picked (no roll, or a roll
    -- without a suggestion) and a target is set (a rolled item goes through its roll; an item without one also for
    -- the master looter who can hand it out now); the award menu when the gold button is not it (someone else, or the
    -- recorded award's reason / void, or the fix of a loot-message conflict).
    local more = { { key = "announce", icon = 18, label = "Announce" } }
    if not winnerKey and not locked and (mode == "normal" or (rolling and not b.suggested))
        and (canAwardItem or (mode == "normal" and CanMasterLoot(itemID))) then
        for _, kind in ipairs({ "de", "bank" }) do
            local key = LootTarget(kind)
            if key then
                local here = IsInMyGroup(key)
                more[#more + 1] = { key = kind, icon = kind == "de" and 22 or 23, label = kind == "de" and "Disenchant" or "Guild bank",
                    enabled = here, note = (not here) and ("not in " .. GroupWord()) or nil }
            end
        end
    end
    local conflict = rolling and type(session.lootOther) == "string" and IsCouncil()
    if gold ~= b.award and not locked
        and ((canAwardItem and not winnerKey) or (winnerKey and IsCouncil()) or conflict) then
        more[#more + 1] = { key = "award", icon = 19, label = "Award", sub = true }
    end
    b.moreEntries = more
    local words = {}
    for i, e in ipairs(more) do words[i] = e.label end
    b.moreBtn.tipText = tconcat(words, ", ")

    -- Who got it, on the second line (the roll's state stays in b.sub for the ticker).
    if winnerKey then
        local t = Paint("Awarded to ", "obtained") .. ColoredName(winnerKey)
        local label = ReasonLabel(award and award.r or (rolling and session.reason) or nil)
        if label then t = t .. Paint(" · " .. label, "muted") end
        if rolling and session.state == "awarded" and session.winner == winnerKey then
            if session.via == "loot" then
                t = t .. Paint(" (looted)", "muted")
            elseif not session.given then
                -- bag loot (Free for All): still in the looter's bags until they trade it
                local holder = HolderOf(session)
                if holder and holder ~= session.winner then
                    t = t .. Paint(" · in ", "muted") .. ColoredName(holder) .. Paint("'s bags", "muted")
                end
            end
        end
        if conflict then
            -- The loot message named someone else (0.5): the More menu's Award offers the fix.
            t = t .. Paint(" · loot: ", "warn") .. ColoredName(session.lootOther)
        end
        b.awarded:SetText(t)
        b.awarded:Show()
        b.sub:Hide()
    else
        b.awarded:SetText("")
        b.awarded:Hide()
        b.sub:Show()
    end
    local lineW = CARD_W - TEXT_X - CARD_PAD - (b.fold:IsShown() and (b.fold:GetWidth() + 8) or 0)
    b.sub:SetWidth(lineW)
    b.awarded:SetWidth(lineW)
    b:SetAlpha((n == 0 and not winnerKey and not rolling and not plain) and 0.8 or 1)
    return y + CARD_PAD
end

-- The More menu of a card (its entries were worked out by FillBlock).
local MENU_GOLD = S.C.GOLD
function DropPanel:MoreTooltip(b, key)
    if key == "announce" then
        if DropPanel.drop and DropPanel.drop.test then return "Simulated drop: the line is only printed in your chat window." end
        if PlainMode(DropPanel.drop) then return "Link this item in raid chat." end
        return "Announce this item and its BiS candidates in " .. GroupWord() .. " chat."
    elseif key == "de" or key == "bank" then
        return self:TargetTooltip(key)
    end
    return "Award it to someone else, or change the recorded award (its reason, or void it)."
end

function DropPanel:GetMoreActions(b)
    local out = {}
    for i, e in ipairs(b and b.moreEntries or {}) do
        out[i] = { key = e.key, label = e.label, enabled = e.enabled ~= false }
    end
    return out
end

function DropPanel:RunMoreAction(b, key)
    if not b then return end
    if key == "announce" then
        self:AnnounceItem(b.itemID)
    elseif key == "de" or key == "bank" then
        self:AwardToTarget(b, key)
    elseif key == "award" then
        self:OpenAwardMenu(b, b.moreBtn)
    end
end

function DropPanel:OpenMoreMenu(b, owner)
    local UI = ns.UI
    if not (b and UI and UI.ContextMenu) then return end
    UI:ContextMenu(owner or b.moreBtn, function(root)
        for _, e in ipairs(b.moreEntries or {}) do
            local text = UI:AtlasIconText(e.icon, 14, MENU_GOLD) .. "  " .. e.label
            if e.note then text = text .. Paint("  " .. e.note, "muted") end
            local entry
            if e.sub then
                entry = root:CreateButton(text)
                DropPanel:BuildAwardMenu(entry, b)
            else
                local key = e.key
                entry = root:CreateButton(text, function() DropPanel:RunMoreAction(b, key) end)
                if e.enabled == false and entry and entry.SetEnabled then entry:SetEnabled(false) end
            end
            if entry and entry.SetTooltip then
                local key, label = e.key, e.label
                entry:SetTooltip(function(tt)
                    tt:AddLine(label, S:RGB("GOLD"))
                    tt:AddLine(DropPanel:MoreTooltip(b, key), 1, 1, 1, true)
                end)
            end
        end
    end)
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
        ns:Print("Only the loot council (the raid leader counts) or the master looter can start rolls.")
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
        ns:Print("Only the loot council (the raid leader counts) or the master looter can start rolls.")
        return
    end
    CallRoll("StartAll", drop)
    self:RequestRefresh(0.1)
end

-- Re-roll of a closed roll: asks first when rolls would be thrown away.
function DropPanel:ConfirmReroll(b)
    local s = b and b.rollSession
    local rolled = b and b.rollStats and tonumber(b.rollStats.rolled) or 0
    if type(s) ~= "table" or rolled == 0 or not ns.Popup then
        self:StartRoll(b.itemID, b.copy)
        return
    end
    local itemID, copy = b.itemID, b.copy
    ns.Popup:Confirm({
        key = "REROLL",
        title = "Re-roll",
        text = format("Start a new roll for %s?\n(%s so far are discarded)", ItemLink(itemID) or ItemName(itemID),
            rolled == 1 and "1 roll" or (rolled .. " rolls")),
        ok = "Re-roll",
        onAccept = function() DropPanel:StartRoll(itemID, copy) end,
    })
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
    local gate = b.awardRoll and b.awardRoll.przGate
    if gate and not gate.ok then
        return format("Not yet: %s.\n\nClick to award %s anyway: you write a reason, and everyone sees it in the "
            .. "item's history.", Grid.GateWhy(gate), ShortName(row.key))
    end
    local parts = {}
    if row.suggestedBy == "votes" then parts[#parts + 1] = VotesText(row.votes) end
    local n = tonumber(row.roll)
    if n then parts[#parts + 1] = "rolled " .. n end
    if not PlainMode(nil, b.rollSession) then parts[#parts + 1] = TierWord(row) end
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
        and RollAllows("CanAward", IsCouncil() or CanStartRolls(self.drop), session.id)
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
            local gate = HasRoll("PrizedReady") and CallRoll("PrizedReady", id, key) or nil
            local blocked = gate and not gate.ok
            local e = root:CreateButton(blocked and ("|cff8c8c8c" .. verb .. "|r") or verb,
                function() DropPanel:AwardRoll(id, key) end)
            if blocked then
                e:SetSubtext(Grid.GateWhy(gate))
                e:SetTitleAndTextTooltip("Not yet", Grid.GateWhy(gate) .. ".\n\nClick to award anyway: you write a "
                    .. "reason everyone sees.")
            end
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
        and RollAllows("CanAward", IsCouncil() or CanStartRolls(self.drop), session.id)
    if not canAward then return end
    local id, vp = session.id, ViewPhase()
    local open = session.state == "open"
    local plain = PlainMode(nil, session)
    ns.UI:ContextMenu(r, function(root)
        root:CreateTitle(format("%d more", #rest))
        for _, x in ipairs(rest) do
            local key = x.key
            root:CreateButton((open and "End roll & award to " or "Award to ") .. ColoredName(key, x.classFile)
                .. (plain and "" or (" " .. TierBadge(x, vp))) .. " " .. RollCell(x, session),
                function() DropPanel:AwardRoll(id, key) end)
        end
    end)
end

---------------------------------------------------------------------------
-- Announce & award
---------------------------------------------------------------------------
-- " · Belt of Blasting 1/2" after a crafting material's candidate in a menu ("" for anything else).
function Mat.CraftNote(w)
    if not w.craft then return "" end
    return Paint(format(" · %s %d/%d", ItemName(w.craft), min(tonumber(w.held) or 0, w.need), w.need), "muted")
end

-- A crafting material: "Belt of Blasting: Vaenyria 1/2, Kaelyn 0/2; Red Belt of Battle: Victhar 0/2" (in the group).
function Mat.MaterialAnnounce(mat)
    local inGroup = _G.IsInGroup and _G.IsInGroup()
    local parts = {}
    for _, g in ipairs(mat.groups) do
        local names = {}
        for _, w in ipairs(g.wanters) do
            if (w.inRaid or not inGroup) and #names < 4 then
                names[#names + 1] = format("%s %d/%d", ShortName(w.key), min(tonumber(w.held) or 0, w.need), w.need)
            end
        end
        if #names > 0 and #parts < 4 then parts[#parts + 1] = ItemName(g.use.item) .. ": " .. tconcat(names, ", ") end
    end
    return parts
end

function DropPanel:BuildAnnounceLine(itemID)
    local link = ItemLink(itemID) or ItemName(itemID)
    -- No loot council (1.3): the item alone, BiS lists don't count in this raid.
    if PlainMode(self.drop) then return format("DisasterZone: %s", link) end
    local mat = MaterialWants(itemID, ViewPhase())
    if mat then
        local parts = Mat.MaterialAnnounce(mat)
        if #parts == 0 then return format("DisasterZone: %s - no craft that uses it is on anyone's list", link) end
        return format("DisasterZone: %s - %s", link, tconcat(parts, "; "))
    end
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
        local done, refused = CallRoll("MarkAwardedExternally", id, key, note, awardReason)
        local now = CallRoll("Get", id)
        if type(now) ~= "table" then now = session end
        self:RequestRefresh(0.1)
        -- 1.3.5: a prized item's rules or agree count held it (the roll printed why, or asks for an override reason)
        if refused == "prized" then return false end
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
    -- 1.3.5: a prized item goes to a player only through its roll (the council's votes and its loot rules)
    local Prized = ns.Prized
    if awardReason ~= "de" and awardReason ~= "bank" and Prized and Prized.IsPrized and Prized:IsPrized(itemID) then
        return false, "Prized item: start its roll first, so the council can vote (Raids > Loot rules)."
    end
    if not IsCouncil() then
        -- 1.3: a master looter outside the council gave the item to the disenchanter / guild bank character: the
        -- council clients record it with that reason (Loot LT), so it does not count as loot won.
        local Loot = ns.Loot
        if (awardReason == "de" or awardReason == "bank") and Loot and Loot.AnnounceTargetHandout
            and Loot:AnnounceTargetHandout(itemID, key, awardReason, bossKey) then
            ns:Print("%s went to %s (%s): the loot council records it.", ItemLink(itemID) or ItemName(itemID),
                ShortName(key), ReasonLabel(awardReason) or awardReason)
            if type(session) == "table" and session.state == "queued" then CallRoll("End", session.id) end
            self:RequestRefresh(0.1)
            return true
        end
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
    if ns.Popup then
        local data = { itemID = itemID, bossKey = bossKey, copy = copy, drop = drop }
        ns.Popup:Prompt({
            key = "AWARD_OTHER",
            title = "Award to someone else",
            text = format("Record %s as awarded to (character name):", ItemLink(itemID) or ItemName(itemID)),
            ok = "Award",
            maxLetters = 48,
            onAccept = function(value) DropPanel:AwardByName(data, value) end,
        })
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
-- "Give <item> to <who>?" (the master looter hands it over) / "Award <item> to <who> anyway?" (handing it over
-- failed: record it, hand it out by master loot or trade).
function Look.ConfirmGive(data, who)
    ns.Popup:Confirm({
        key = "GIVE_TARGET",
        title = "Give item",
        text = format("Give %s to %s?", ItemLink(data.itemID) or ItemName(data.itemID), who),
        ok = "Give",
        onAccept = function() DropPanel:GiveToTarget(data) end,
    })
end

function Look.ConfirmRecord(data)
    ns.Popup:Confirm({
        key = "RECORD_TARGET",
        title = "Award item",
        text = format("Award %s to %s anyway?\n(hand it out via master loot or trade)",
            ItemLink(data.itemID) or ItemName(data.itemID), ColoredName(data.key)),
        ok = "Award",
        onAccept = function()
            local ok, why = DropPanel:Award(data.itemID, data.key, data.bossKey, data.copy, data.drop, nil, data.kind)
            if not ok and why then ns:Print("%s", why) end
        end,
    })
end

function DropPanel:GiveToTarget(data)
    if type(data) ~= "table" then return end
    local Loot = ns.Loot
    local function fallback(why)
        ns:Print("Could not hand %s to %s: %s.", ItemLink(data.itemID) or ItemName(data.itemID), ShortName(data.key),
            tostring(why or "unknown error"))
        if ns.Popup then Look.ConfirmRecord(data) end
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
        if ns.Popup then
            Look.ConfirmGive({ itemID = itemID, key = key, kind = kind, bossKey = bossKey, copy = b.copy, drop = drop },
                ColoredName(key) .. " (" .. TARGET_LABELS[kind] .. ")")
        end
        return
    end
    local ok, why = self:Award(itemID, key, bossKey, b.copy, drop, nil, kind)
    if not ok and why then ns:Print("%s", why) end
end

function DropPanel:OpenAwardMenu(b, owner)
    if not (b and b.itemID and type(self.drop) == "table" and ns.UI and ns.UI.ContextMenu) then return end
    ns.UI:ContextMenu(owner, function(root) DropPanel:BuildAwardMenu(root, b) end)
end

-- The award menu of card b into `root` (a context menu, or the More menu's Award submenu).
function DropPanel:BuildAwardMenu(root, b)
    local itemID, drop = b.itemID, self.drop
    if not itemID or type(drop) ~= "table" then return end
    local bossKey = type(drop.b) == "string" and drop.b or ""
    local copy = b.copy
    local vp = ViewPhase()
    -- Fetched when the menu opens (the group may have changed since the panel was painted). None without the loot
    -- council (1.3): the menu offers the raid's members.
    local plain = PlainMode(drop, b.rollSession)
    local wanters = plain and {} or UniqueWanters(itemID, { includeObtained = false, list = "both" })
    local awardEntry = b.awardEntry
    local conflict = b.rollSession and type(b.rollSession.lootOther) == "string" and b.rollSession or nil
    local function award(key, reason) DropPanel:Award(itemID, key, bossKey, copy, drop, nil, reason) end
    local inGroup = _G.IsInGroup and _G.IsInGroup()
    local awarded = type(awardEntry) == "table" and awardEntry.id and not awardEntry.vd
    do
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
                root:CreateButton(ColoredName(key, w.classFile) .. "  " .. BadgeText(w, vp) .. Mat.CraftNote(w)
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
            local sub = root:CreateButton(plain and "Raid member" or ("Other " .. GroupWord() .. " member"))
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
    end
end

---------------------------------------------------------------------------
-- Personal toast
---------------------------------------------------------------------------
-- The "On your BiS list" pop-up is a UI:Toast (the one pop-up look and stack): the item's icon, the list it is on as
-- the kicker (the off-spec colour for an off-spec pick), the item as the title and where it goes as its line. The
-- panel keeps its own queue (one drop's toasts one after another, "+N more" in the kicker); a click links the item in
-- chat, the X dismisses it, the mouse over it holds it.
local TOAST_KEY = "dz-bis-drop"

-- What the toast of entry e says: kicker, kind (its colour), title, text.
function DropPanel:ToastContent(e)
    local m = e.match or {}
    local kicker, kind = "On your BiS list", "info"
    if m.os then
        local sp = OffSpecLabel()
        kicker, kind = "On your off-spec list" .. (sp and (" (" .. sp .. ")") or ""), Color("offspec")
    end
    if e.test then kicker = kicker .. " (test)" end
    local queued = #self.toastQueue
    if queued > 0 then kicker = kicker .. "  +" .. queued .. " more" end
    -- where it goes: "Head · P1", "(alt)" for an alt pick; a token / Sunmote names the piece it becomes
    local shown = (m.via and m.wanted) or e.itemID
    local paren = {}
    if m.which == "alt" then paren[#paren + 1] = "alt" end
    if m.via then paren[#paren + 1] = (ns.VIA_TEXT and ns.VIA_TEXT[m.via]) or "via token" end
    local line = format("%s · P%d", ns.SlotLabel(m.sid), tonumber(m.phase) or 0)
    if m.via and shown ~= e.itemID then line = ItemText(shown) .. " · " .. line end
    if #paren > 0 then line = line .. " (" .. tconcat(paren, ", ") .. ")" end
    if m.via == "craft" then
        -- a crafting material: the craft it is for and how many I have
        line = "For " .. ItemText(shown) .. Paint(format(" · you have %d of %d", tonumber(m.held) or 0,
            tonumber(m.need) or 0), "muted")
    end
    return kicker, kind, ItemText(e.itemID), line
end

function DropPanel:GetToast()
    return self.toast
end

-- Whether the current entry's toast is on screen or still waiting in the pop-ups' queue (behind UI.TOAST.MAX shown
-- ones): either way the next entries wait behind it in this panel's own queue.
function DropPanel:ToastBusy()
    if not self.toastEntry then return false end
    if UI:GetToast(TOAST_KEY) then return true end
    for _, o in ipairs(UI:ToastQueue() or {}) do
        if o.key == TOAST_KEY then return true end
    end
    return false
end

-- bossKey (optional): the drop's boss (drop.b).
function DropPanel:QueueToast(itemID, match, test, bossKey)
    if #self.toastQueue >= TOAST_QUEUE_MAX then return end
    tinsert(self.toastQueue, { itemID = itemID, match = match, test = test, b = bossKey })
    if self:ToastBusy() then
        self:RefreshToastText()            -- ("+N more" in its kicker, on screen or while it waits)
    else
        self:ShowNextToast()
    end
end

function DropPanel:ShowNextToast()
    local entry = tremove(self.toastQueue, 1)
    if not entry then return end
    self.toastEntry = entry
    self:RefreshToastText()
end

-- Shows (or fills again in place) the toast of the current entry.
function DropPanel:RefreshToastText()
    local e = self.toastEntry
    if not e then return end
    local kicker, kind, title, line = self:ToastContent(e)
    local t = UI:Toast({
        key = TOAST_KEY, kind = kind, kicker = kicker, title = title, text = line, lines = 2,
        icon = UI:ItemIcon(e.itemID), duration = TOAST_HOLD,
        onClick = function()
            LinkToChat(e.itemID)
            return true                    -- (the toast stays)
        end,
        onClose = function(frame) DropPanel:FinishToast(frame) end,
        -- (one that waited behind other pop-ups comes later: it is the panel's toast from then on)
        onShow = function(frame)
            DropPanel.toast = frame
            frame.entry = e
        end,
        itemID = e.itemID, tipLine = "Click: link in chat.", rightClose = true,   -- (hover: the item; right-click: away)
    })
    if not t then return end           -- (waiting behind other pop-ups: it comes when there is room)
    self.toast = t
    t.entry = e
end

-- The toast went (timed out, its X, dismissed): the next one of the queue.
function DropPanel:FinishToast(frame)
    local t = frame or self.toast
    if t then t.entry = nil end
    if self.toast == t then self.toast = nil end
    self.toastEntry = nil
    self:ShowNextToast()
end

function DropPanel:DismissToast()
    UI:HideTooltip()
    -- (on screen: its onClose shows the next one; one still waiting in the pop-ups' queue just goes)
    if not UI:HideToast(TOAST_KEY, "close") then self:FinishToast() end
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
        if IsCouncil() and not PlainMode() then   -- (no BiS counts while the raid runs without the loot council)
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

---------------------------------------------------------------------------
-- Council > Rules' preview card (UI/CouncilRules.lua): the drop panel's own roll rows on made-up results
---------------------------------------------------------------------------
DropPanel.PREVIEW = { ROW_H = ROW_H, ROW_W = ROW_W, HEAD_H = Grid.HEAD_H, CARD_PAD = CARD_PAD }

-- A roll row on parent (hover shows the usual tooltip; clicks do nothing).
function DropPanel:NewPreviewRow(parent)
    local r = self:NewRow(parent)
    r:SetScript("OnClick", nil)
    r.voteBtn:EnableMouse(false)
    return r
end

-- Fills r with a Roll:RankRows row. row.preview = { att = %, dry = { nights, bosses, came, last } } stands in for the
-- raid log and the Loot Log; session = { state = "open" | "closed" }.
function DropPanel:FillPreviewRow(r, row, session, itemID)
    if row.preview then Dry.preview[row.key] = row.preview end
    row.equippedList = row.equippedList or {}
    return FillRollRow(r, row, session, itemID, ViewPhase(), FirstSlotOfItem(itemID))
end

-- The column titles and dividers over preview rows (top: their y in b, rowsH: the rows' height).
function DropPanel:PreviewHead(b, top, rowsH)
    Grid.Head(b, "roll", top, rowsH)
end
