if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Strategy.lua", ...) then return end -- DisasterZone: Core/Strategy.lua
-- Strategy boards (Addendum K): per-boss strategies built from generic tools, and per-raid fills.
--
-- A strategy (kind B) belongs to one boss ("BlackTemple:Council") and holds pages (P1, P2, ...). Each page has a map
-- (a built-in instance map, panned / zoomed, or blank) with drawn elements (zones, arrows, icons, text, slot tokens)
-- and blocks: small tables whose columns are player slots (optionally limited to classes / roles), targets (an icon
-- and / or a label, or another slot), order numbers or text. A player slot is addressed "<block>.<row>.<col>"; block ids
-- are unique in the strategy, so a slot token on page 2 can show a slot of a page-1 block.
-- A fill (kind F) is one raid's names for one boss: the strategy picked for it and { [slotRef] = player key }.
--
-- Who (1.0): every guild member builds strategies. A strategy belongs to its creator (ow; a record from before 1.0
-- has none: its last editor owns it); only the owner and the collaborators the owner invited (co) change it, only
-- the owner changes the collaborators, and the GM and the guild council may edit and delete any strategy. A raid's
-- fills (its strategy picks and names) are written only by who leads it: its own leader (RaidPlan rl), or on a raid
-- without one the raid leaders on the list; and the GM (RaidPlan:CanAssignStrategies, user rule 2026-10-04); fills
-- from anyone else are ignored, judged anew on every read (a leader whose crown goes stops leading at once, on every
-- client). Everyone in the guild caches and reads
-- both. Sync mirrors the raid plan (§56): live edits on GUILD (SBU), and at login the
-- HELLO carries a hash of my data (sd); a client whose data differs answers with its digest (SBD), the new client asks
-- for what differs (SBW) and both send their copies one item per message (SBG). Records merge by rev (then hash); a
-- strategy built on a newer list of collaborators (cr) wins first, and a deletion wins over any edit (MergeStrategy).
-- Every member's strategy may be as large as a council member's message (Comm:AllowLarge, user rule 2026-10-04).
local addonName, ns = ...

local Strategy = ns:NewModule("Strategy")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next = type, pairs, ipairs, tonumber, tostring, next
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local DAY = 86400
local FUTURE_SLACK = 300
local TOMBSTONE_DAYS = 30 * DAY     -- a deletion is in the digest this long; then kept as a grave (DigestSync.lua)
local GRAVE_KEEP = 365 * DAY
local MAX_GRAVES = 150
local FILL_KEEP = 45 * DAY           -- fills are kept this long after their raid
local SBD_DELAY_COUNCIL = { 0.5, 2.5 }
local SBD_DELAY_MEMBER = { 3, 8 }

-- The board's own coordinate space (the map art of an instance floor is about 1002 x 668).
local BOARD_W, BOARD_H = 1000, 666

local MAX_STRATS = 150               -- strategies in the guild (deleted ones don't count)
local MAX_OWN = 20                   -- strategies per owner
local MAX_COLLAB = 10                -- collaborators per strategy
local MAX_FILLS = 120
local MAX_DIGEST_ITEMS = 300
-- Strategy records stored, deletions (in the digest TOMBSTONE_DAYS) included, graves not: with every fill they fit
-- one digest. When full, a new strategy makes room by forgetting the oldest deletion.
local MAX_RECORDS = MAX_DIGEST_ITEMS - MAX_FILLS
local SIZE_HEADROOM = 0.1            -- of the message caps, kept free when a strategy is saved (Comm:Fits)
local MAX_PAGES = 6
local MAX_ELEMENTS = 80              -- per page
local MAX_BLOCKS = 12                -- per page
local MAX_COLS = 5
local MAX_ROWS = 25
local MAX_ASSIGN = 150               -- per fill
local MAX_ID_LEN = 24
local MAX_KEY_LEN = 48
local MAX_NAME_LEN = 32
local MAX_PAGE_NAME = 24
local MAX_HEADER = 20
local MAX_LABEL = 48
local MAX_CELL = 64                  -- a target's label
local MAX_TEXT = 160                 -- a text cell, a text on the map
local MAX_TEXT_LINES = 8             -- lines of such a text
local MAX_NOTES = 1000               -- a page's notes
local TEXT_MIN, TEXT_MAX = 8, 48     -- a map text's font size
local TEXT_BOX_MIN = 40              -- a map text's narrowest box (board units)
local MAX_FILTER = 80
local MAX_ICON = 64
local MAX_COLOR = 12

local ROLES = { tank = true, healer = true, melee = true, ranged = true }
-- Tracked tables: rot = interrupt rotation, md / bl = once per pull (Misdirection, Bloodlust / Heroism),
-- pi / iv = cooldown on a target (Power Infusion, Innervate), curse = keep a curse up, dsp = remove an effect
-- (block.ds = its spell ids, block.dy = its dispel type, block.en = it sits on the enemy, not on our raid).
local TRACK_KINDS = { rot = true, md = true, bl = true, pi = true, iv = true, curse = true, dsp = true }
-- Dispel types (m = Magic, c = Curse, p = Poison, d = Disease, e = Enrage) and the classes that remove each in TBC,
-- from a friend and from an enemy (a warlock's is the Felhunter's Devour Magic).
local DISPEL_NAME = { m = "Magic", c = "Curse", p = "Poison", d = "Disease", e = "Enrage" }
local DISPEL_FRIEND = {
    m = { "PRIEST", "PALADIN", "WARLOCK" }, c = { "MAGE", "DRUID" },
    p = { "DRUID", "PALADIN", "SHAMAN" }, d = { "PRIEST", "PALADIN", "SHAMAN" },
}
local DISPEL_ENEMY = { m = { "PRIEST", "SHAMAN", "MAGE", "WARLOCK" }, e = { "HUNTER" } }
local MAX_DISPELS = 8                -- effects per dispel table
local CURSE_IDS = { [1714] = true, [702] = true, [1490] = true, [704] = true, [603] = true, [980] = true, [17862] = true }
local COL_TYPES = { p = true, g = true, o = true, x = true }

Strategy.BOARD_W, Strategy.BOARD_H = BOARD_W, BOARD_H
Strategy.MAX_PAGES, Strategy.MAX_ELEMENTS, Strategy.MAX_BLOCKS = MAX_PAGES, MAX_ELEMENTS, MAX_BLOCKS
Strategy.MAX_COLS, Strategy.MAX_ROWS = MAX_COLS, MAX_ROWS
Strategy.MAX_NAME_LEN, Strategy.MAX_LABEL, Strategy.MAX_CELL = MAX_NAME_LEN, MAX_LABEL, MAX_CELL
Strategy.MAX_HEADER, Strategy.MAX_PAGE_NAME = MAX_HEADER, MAX_PAGE_NAME
Strategy.MAX_COLLAB = MAX_COLLAB
Strategy.MAX_TEXT, Strategy.MAX_NOTES = MAX_TEXT, MAX_NOTES
Strategy.TEXT_MIN, Strategy.TEXT_MAX, Strategy.TEXT_BOX_MIN = TEXT_MIN, TEXT_MAX, TEXT_BOX_MIN
Strategy.ROLES = { "tank", "healer", "melee", "ranged" }
Strategy.DISPEL_NAME, Strategy.DISPEL_ORDER, Strategy.MAX_DISPELS = DISPEL_NAME, { "m", "c", "p", "d", "e" }, MAX_DISPELS

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local Now = Util.Now          -- (the server clock: ns.Util.Now)

local function IsInt(n, lo, hi)
    return type(n) == "number" and n == floor(n) and n >= lo and n <= hi
end

local function CleanText(s, maxLen)
    if type(s) ~= "string" then return nil end
    s = Util.Trim(s)
    if s == "" or #s > maxLen or s:find("[%c|]") then return nil end
    return s
end

-- A text of several lines (a text cell, a text on the map): line breaks are fine, other control characters aren't.
local function CleanLines(s, maxLen)
    if type(s) ~= "string" then return nil end
    s = Util.Trim(s)
    if s == "" or #s > maxLen or s:find("|") then return nil end
    local flat, breaks = s:gsub("\n", "")
    if breaks >= MAX_TEXT_LINES or flat:find("%c") then return nil end
    return s
end

-- Typed text made fit for a text cell / a text on the map: no |, at most MAX_TEXT_LINES lines, maxLen characters.
function Strategy.TidyText(text, maxLen)
    text = tostring(text or ""):gsub("|", ""):gsub("\r", ""):gsub("[^%C\n]", " ")
    local n = 0
    text = Util.Trim(text):gsub("\n", function()
        n = n + 1
        if n >= MAX_TEXT_LINES then return " " end
    end)
    return Util.Trim(text:sub(1, maxLen))
end

local function WireKey(s)
    if type(s) ~= "string" or s == "" or #s > MAX_KEY_LEN or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

local function IsId(s, maxLen)
    return type(s) == "string" and #s <= (maxLen or MAX_ID_LEN) and s:find("^%w+$") ~= nil
end

-- A boss reference as ItemDB uses it ("BlackTemple:Council").
local function IsBossRef(s)
    return type(s) == "string" and #s <= MAX_KEY_LEN and s:find("^%w+:%w+$") ~= nil
end

-- A raid occurrence id of the raid plan ("<id>" or "<seriesId>#<k>").
local function IsOccId(s)
    return type(s) == "string" and #s <= MAX_ID_LEN + 6 and (s:find("^%w+$") or s:find("^%w+#%d+$")) ~= nil
end

-- Icon keys: rt1..rt8 (raid marks), cls:<CLASS>, role:<role>, i:<file name under Interface\Icons>, sp:<spell id>,
-- it:<item id>, boss:<creature display id> (a boss portrait), obj:<game object entry> and npc:<NPC ID> (an
-- encounter's assets, Core/StrategyObjects.lua).
local function IsIconKey(s)
    if type(s) ~= "string" or #s > MAX_ICON then return false end
    if s:find("^rt[1-8]$") or s:find("^sp:%d%d?%d?%d?%d?%d?$") or s:find("^it:%d%d?%d?%d?%d?%d?$")
        or s:find("^boss:%d%d?%d?%d?%d?%d?%d?$") or s:find("^obj:%d%d?%d?%d?%d?%d?$")
        or s:find("^npc:%d%d?%d?%d?%d?%d?%d?$") then return true end
    local cls = s:match("^cls:(%u+)$")
    if cls then return ns.SPECS ~= nil and ns.SPECS[cls] ~= nil end
    local role = s:match("^role:(%l+)$")
    if role then return ROLES[role] == true end
    return s:find("^i:[%w_%-]+$") ~= nil
end

-- "<block>.<row>.<col>" -> block, row, col
local function SplitSlot(ref)
    if type(ref) ~= "string" or #ref > 20 then return nil end
    local b, r, c = ref:match("^(%w+)%.(%d+)%.(%d+)$")
    if not b then return nil end
    return b, tonumber(r), tonumber(c)
end

local function SlotRef(b, r, c)
    return b .. "." .. r .. "." .. c
end
Strategy.SlotRef = SlotRef
Strategy.SplitSlot = SplitSlot
Strategy.IsIconKey = IsIconKey

-- A link from a zone: "<block>", "<block>.<col>" or "<block>.<row>.<col>".
local function IsLinkRef(s)
    if type(s) ~= "string" or #s > 20 then return false end
    return s:find("^%w+$") ~= nil or s:find("^%w+%.%d+$") ~= nil or s:find("^%w+%.%d+%.%d+$") ~= nil
end

local function Guild() return ns.Guild end

local function GuildKey()
    local G = Guild()
    return G and G.GetGuildKey and G:GetGuildKey() or nil
end

-- The raid planners and the guild council: they answer a digest first (SBD). Who writes a raid's fills: CanWriteRaid.
local function CanWrite(key)
    local G = Guild()
    return type(key) == "string" and G ~= nil and G.IsRaidLogMember ~= nil and G:IsRaidLogMember(key) and true or false
end

-- One raid's fills: who leads that raid and the GM (RaidPlan:CanAssignStrategies). A raid I don't know (yet): the GM
-- and the raid leaders on the list. Returns allowed, and whether the raid was known.
local function CanWriteRaid(occId, key)
    local RP = ns.RaidPlan
    if not RP then return false, false end
    local v = RP.GetRaid and RP:GetRaid(occId)
    if v then return RP:CanAssignStrategies(v, key) and true or false, true end
    return RP.IsOrganizer ~= nil and RP:IsOrganizer(key) and true or false, false
end

-- Does a fill come from someone who may write that raid's fills, as things are now? Second: the raid is known (while
-- it isn't, the raid leaders on the list and the GM). Never remembered: who leads a raid can change, and every client
-- must then judge its fills the same way at once.
local function FillWriter(rec)
    return CanWriteRaid(rec.o, rec.by)
end

-- The GM and the guild council may edit and delete anyone's strategy (its collaborators stay the owner's to pick).
local function CanModerate(key)
    local G = Guild()
    return type(key) == "string" and G ~= nil
        and ((G.IsGM ~= nil and G:IsGM(key)) or (G.IsGuildCouncil ~= nil and G:IsGuildCouncil(key))) and true or false
end

-- The owner of a strategy: its creator (a record from before 1.0 names none: its last editor).
local function Owner(rec)
    return rec.ow or rec.by
end

-- (1.4.1) One player: the same character, or two characters of one account (Guild:SameAccount). The owner and the
-- collaborators act from any of their characters, as in RaidPlan / Prized / Attendance.
local function SamePlayer(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if a == b then return true end
    local G = Guild()
    return (G and G.SameAccount and G:SameAccount(a, b)) and true or false
end

local function IsOwnerKey(rec, key)
    return SamePlayer(Owner(rec), key)
end

local function IsCollab(rec, key)
    for _, k in ipairs(rec.co or {}) do
        if SamePlayer(k, key) then return true end
    end
    return false
end

local function SameList(a, b)
    a, b = a or {}, b or {}
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- May the strategy `rec` replace the strategy `cur` (nil: it is new to me)? The owner stays the owner; the owner, the
-- collaborators and the moderators change the board; only the owner changes the collaborators (and their version cr).
local function Allowed(cur, rec)
    if not cur then return IsOwnerKey(rec, rec.by) or IsCollab(rec, rec.by) or CanModerate(rec.by) end
    if Owner(rec) ~= Owner(cur) then return false end
    if IsOwnerKey(cur, rec.by) then return true end
    return (IsCollab(cur, rec.by) or CanModerate(rec.by)) and SameList(cur.co, rec.co) and rec.cr == cur.cr
end

-- Does the deletion `t` delete the strategy `rec`? Its owner's and a moderator's do; one from anyone else never counts.
local function Deletes(t, rec)
    return IsOwnerKey(rec, t.by) or CanModerate(t.by)
end

local REFUSED = "Only the Guild Master and the raid leaders pick a raid's strategies and assign its players."
local REFUSED_LED = "Only this raid's leader and the Guild Master pick its strategies and assign its players."

local function Send(msg, dist, target, class)
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, class)) and true or false
end

local function Root(create)
    local r = ns.DB:GuildBucket("strategy", create)
    if not r then return nil end
    for _, k in ipairs({ "B", "F", "L" }) do
        if type(r[k]) ~= "table" then r[k] = {} end
    end
    return r
end

local function Changed()
    ns:Fire("STRATEGY_CHANGED")
end

-- Synced by Core/DigestSync.lua: SBU / SBD / SBK / SBW / SBG, the HELLO's sd (strategies B and fills F; L stays here).
-- Its own Root, merge and commit (below); a member's strategy may be as large as a council member's message.
local sync = ns.DigestSync.New({
    module = Strategy, bucket = "strategy", kinds = { "B", "F" }, root = Root, send = Send, prefix = "SB",
    maxItems = MAX_DIGEST_ITEMS, maxItemLen = MAX_ID_LEN + 4, itemPattern = "^[BF]:%w+$", wireKey = WireKey,
    helloField = "sd", helloOrder = 40, large = true, keepHash = true,
    tombKeep = { B = TOMBSTONE_DAYS }, graveKeep = GRAVE_KEEP, maxGraves = MAX_GRAVES,
    delay = function() return CanWrite(Util.PlayerKey()) and SBD_DELAY_COUNCIL or SBD_DELAY_MEMBER end,
})
local NextRev = sync.NextRev

local function NewId() return sync:NewId() end

local function CountTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function Copy(t)
    return Util.CopyTable(t)
end

-- The id of the fill of (raid, boss).
local function FillId(occId, bossRef)
    return Util.Hash({ occId, bossRef }):sub(1, 8)
end
Strategy.FillId = FillId

---------------------------------------------------------------------------
-- Validation (untrusted records -> clean copies; nil = rejected)
---------------------------------------------------------------------------

local function Coord(n, hi)
    return IsInt(n, -50, hi + 50)
end

local function CleanElement(e)
    if type(e) ~= "table" then return nil end
    local t = e.t
    if not (Coord(e.x, BOARD_W) and Coord(e.y, BOARD_H)) then return nil end
    local out = { t = t, x = e.x, y = e.y }
    if e.c ~= nil then
        if not IsInt(e.c, 1, MAX_COLOR) then return nil end
        out.c = e.c
    end
    if e.l ~= nil then
        if t == "x" then out.l = CleanLines(e.l, MAX_TEXT) else out.l = CleanText(e.l, MAX_LABEL) end
        if not out.l then return nil end
    end
    -- any drawing can be linked to a block / column / slot, belong to a group, and (icons, zones) wear a raid mark
    if e.ln ~= nil then
        if not IsLinkRef(e.ln) then return nil end
        out.ln = e.ln
    end
    if e.g ~= nil then
        if not IsId(e.g, 6) then return nil end
        out.g = e.g
    end
    if e.rm ~= nil then
        if not IsInt(e.rm, 1, 8) then return nil end
        out.rm = e.rm
    end
    if t == "z" then
        if e.s ~= "c" and e.s ~= "r" then return nil end
        if not (IsInt(e.w, 4, BOARD_W) and IsInt(e.h, 4, BOARD_W)) then return nil end
        out.s, out.w, out.h = e.s, e.w, e.h
    elseif t == "a" then
        if not (Coord(e.x2, BOARD_W) and Coord(e.y2, BOARD_H)) then return nil end
        out.x2, out.y2 = e.x2, e.y2
        if e.h == true then out.h = true end
    elseif t == "i" then
        if not IsIconKey(e.i) then return nil end
        out.i = e.i
        if e.z ~= nil then
            if not IsInt(e.z, 12, 96) then return nil end
            out.z = e.z
        end
        -- a boss / add as its model in the 3D room: which way it faces (degrees, 0 = east, 90 = north; nil = towards
        -- the nearest player marker) and its size (percent of its real size; nil = 100)
        if e.f ~= nil then
            if not IsInt(e.f, 0, 359) then return nil end
            out.f = e.f
        end
        if e.ms ~= nil then
            if not IsInt(e.ms, 25, 400) then return nil end
            out.ms = e.ms
        end
        -- an encounter asset's state (Data/EncounterObjects.lua; 1 = its first, kept as nil); dropped on any other
        -- icon (one changed from an asset keeps the field until here)
        if IsInt(e.st, 2, 4) and (out.i:find("^obj:") or out.i:find("^npc:")) then out.st = e.st end
    elseif t == "x" then
        if not out.l then return nil end
        -- the size: 1-3 (small / normal / large) or the font size itself (dragged at the corner)
        if e.z ~= nil then
            if not (IsInt(e.z, 1, 3) or IsInt(e.z, TEXT_MIN, TEXT_MAX)) then return nil end
            out.z = e.z
        end
        -- its lines start at the left / end at the right of its box; nil = centred
        if e.j ~= nil then
            if e.j ~= "l" and e.j ~= "r" then return nil end
            out.j = e.j
        end
        -- the width of its box (the text wraps inside); nil = as wide as its size allows
        if e.w ~= nil then
            if not IsInt(e.w, TEXT_BOX_MIN, BOARD_W) then return nil end
            out.w = e.w
        end
    elseif t == "s" then
        if not SplitSlot(e.r) then return nil end
        out.r = e.r
    else
        return nil
    end
    return out
end

Strategy._CleanElement = CleanElement        -- (tests)

-- A filter: comma-separated class files (MAGE) and roles (tank / healer / melee / ranged). "" / nil = anyone.
local function CleanFilter(f)
    if f == nil or f == "" then return nil, true end
    if type(f) ~= "string" or #f > MAX_FILTER then return nil, false end
    local out, seen = {}, {}
    for tok in f:gmatch("[^,]+") do
        tok = Util.Trim(tok)
        local ok = (ROLES[tok] == true) or (ns.SPECS ~= nil and ns.SPECS[tok] ~= nil)
        if not ok then return nil, false end
        if not seen[tok] then
            seen[tok] = true
            out[#out + 1] = tok
        end
    end
    if #out == 0 then return nil, true end
    return tconcat(out, ","), true
end

local function CleanCell(colType, v)
    if colType == "p" then
        -- a player slot's own "who fits" (overrides its column's)
        if type(v) ~= "table" or v.f == nil then return nil end
        local f, ok = CleanFilter(v.f)
        if not ok or not f then return nil end
        return { f = f }
    elseif colType == "x" then
        return CleanLines(v, MAX_TEXT)
    elseif colType == "g" then
        if type(v) ~= "table" then return nil end
        local out = {}
        if v.i ~= nil then
            if not IsIconKey(v.i) then return nil end
            out.i = v.i
        end
        if v.l ~= nil then
            out.l = CleanText(v.l, MAX_CELL)
            if not out.l then return nil end
        end
        if v.s ~= nil then
            if not SplitSlot(v.s) then return nil end
            out.s = v.s
        end
        -- the boss abilities this row is about (spell ids; Data/BossAbilities.lua or any id)
        if v.a ~= nil then
            if type(v.a) ~= "table" then return nil end
            local seen, list = {}, {}
            for i = 1, 9 do
                local id = v.a[i]
                if id == nil then break end
                if i > 8 or not IsInt(id, 1, 9999999) then return nil end
                if not seen[id] then
                    seen[id] = true
                    list[#list + 1] = id
                end
            end
            if #list > 0 then out.a = list end
        end
        -- only when: "a:<spell id>" (the boss has that buff / immunity) or "hp:<1-99>" (the boss is below that health)
        if v.w ~= nil then
            if type(v.w) ~= "string" or not (v.w:find("^a:%d%d?%d?%d?%d?%d?%d?$") or v.w:find("^hp:%d%d?$")) then
                return nil
            end
            out.w = v.w
        end
        if not next(out) then return nil end
        return out
    end
    return nil
end

local function CleanBlock(k)
    if type(k) ~= "table" or not IsId(k.id, 6) then return nil end
    local out = { id = k.id }
    out.n = CleanText(k.n, MAX_NAME_LEN)
    if not out.n or not IsInt(k.r, 1, MAX_ROWS) or type(k.c) ~= "table" then return nil end
    out.r = k.r
    if k.i ~= nil then
        if not IsIconKey(k.i) then return nil end
        out.i = k.i
    end
    if k.cl ~= nil then
        if not IsInt(k.cl, 1, MAX_COLOR) then return nil end
        out.cl = k.cl
    end
    -- what the encounter helpers track for this table (Core/StrategyLive.lua)
    if k.tr ~= nil then
        if not TRACK_KINDS[k.tr] then return nil end
        out.tr = k.tr
    end
    -- a dispel table: the effects to remove (spell ids), their dispel type, and whether they sit on the enemy
    if k.ds ~= nil then
        if type(k.ds) ~= "table" then return nil end
        local seen, list = {}, {}
        for i = 1, MAX_DISPELS + 1 do
            local id = k.ds[i]
            if id == nil then break end
            if i > MAX_DISPELS or not IsInt(id, 1, 9999999) then return nil end
            if not seen[id] then
                seen[id] = true
                list[#list + 1] = id
            end
        end
        if #list > 0 then out.ds = list end
    end
    if k.dy ~= nil then
        if not DISPEL_NAME[k.dy] then return nil end
        out.dy = k.dy
    end
    if k.en ~= nil then
        if k.en ~= true then return nil end
        out.en = true
    end
    -- the backup kickers' rows of an interrupt rotation
    if k.bk ~= nil then
        if type(k.bk) ~= "table" then return nil end
        local seen, list = {}, {}
        for i = 1, MAX_ROWS + 1 do
            local row = k.bk[i]
            if row == nil then break end
            if i > MAX_ROWS or not IsInt(row, 1, out.r) then return nil end
            if not seen[row] then
                seen[row] = true
                list[#list + 1] = row
            end
        end
        table.sort(list)
        if #list > 0 then out.bk = list end
    end
    out.c = {}
    for i = 1, MAX_COLS + 1 do
        local col = k.c[i]
        if col == nil then break end
        if i > MAX_COLS or type(col) ~= "table" or not COL_TYPES[col.t] then return nil end
        local cc = { t = col.t }
        if col.n ~= nil and col.n ~= "" then
            cc.n = CleanText(col.n, MAX_HEADER)
            if not cc.n then return nil end
        end
        if col.t == "p" then
            local f, ok = CleanFilter(col.f)
            if not ok then return nil end
            cc.f = f
        end
        out.c[i] = cc
    end
    if #out.c == 0 then return nil end
    if k.d ~= nil then
        if type(k.d) ~= "table" then return nil end
        for row, cells in pairs(k.d) do
            if not IsInt(row, 1, out.r) or type(cells) ~= "table" then return nil end
            for col, v in pairs(cells) do
                if not IsInt(col, 1, #out.c) then return nil end
                local cell = CleanCell(out.c[col].t, v)
                if cell ~= nil then
                    out.d = out.d or {}
                    out.d[row] = out.d[row] or {}
                    out.d[row][col] = cell
                end
            end
        end
    end
    return out
end

local function CleanPage(p, blockIds)
    if type(p) ~= "table" or not IsId(p.id, 6) then return nil end
    local out = { id = p.id }
    out.n = CleanText(p.n, MAX_PAGE_NAME)
    if not out.n then return nil end
    if not IsInt(p.m, 0, 999999) then return nil end
    out.m = p.m
    if p.vx ~= nil or p.vy ~= nil or p.vz ~= nil then
        if not (IsInt(p.vx, 0, 1000) and IsInt(p.vy, 0, 1000) and IsInt(p.vz, 100, 1000)) then return nil end
        out.vx, out.vy, out.vz = p.vx, p.vy, p.vz
    end
    if p.no ~= nil then
        -- page notes: free text (several lines allowed)
        if type(p.no) ~= "string" or #p.no > MAX_NOTES or p.no:find("|") then return nil end
        local s = Util.Trim(p.no)
        if s ~= "" then out.no = s end
    end
    out.e = {}
    if p.e ~= nil then
        if type(p.e) ~= "table" then return nil end
        for i = 1, MAX_ELEMENTS + 1 do
            local e = p.e[i]
            if e == nil then break end
            if i > MAX_ELEMENTS then return nil end
            local ce = CleanElement(e)
            if not ce then return nil end
            out.e[#out.e + 1] = ce
        end
    end
    out.k = {}
    if p.k ~= nil then
        if type(p.k) ~= "table" then return nil end
        for i = 1, MAX_BLOCKS + 1 do
            local k = p.k[i]
            if k == nil then break end
            if i > MAX_BLOCKS then return nil end
            local ck = CleanBlock(k)
            if not ck or blockIds[ck.id] then return nil end
            blockIds[ck.id] = true
            out.k[#out.k + 1] = ck
        end
    end
    return out
end

local function CleanCommon(r, now)
    if type(r) ~= "table" or not IsInt(r.rev, 1, now + FUTURE_SLACK) then return nil end
    local by = WireKey(r.by)
    if not by then return nil end
    return { rev = r.rev, by = by }
end

local function CleanStrategy(r, now)
    local out = CleanCommon(r, now)
    if not out or not IsId(r.id) then return nil end
    out.id = r.id
    if r.del == true then
        out.del = true
        return out
    end
    if not IsBossRef(r.b) then return nil end
    out.b = r.b
    if r.am == false then out.am = false end      -- auto-marking off for this strategy
    if r.ow ~= nil then
        out.ow = WireKey(r.ow)
        if not out.ow then return nil end
    end
    if r.co ~= nil then
        if type(r.co) ~= "table" then return nil end
        local owner, seen, list = out.ow or out.by, {}, {}
        for i = 1, MAX_COLLAB + 1 do
            local v = r.co[i]
            if v == nil then break end
            local k = WireKey(v)
            if i > MAX_COLLAB or not k then return nil end
            if k ~= owner and not seen[k] then
                seen[k] = true
                list[#list + 1] = k
            end
        end
        tsort(list)
        if #list > 0 then out.co = list end
    end
    -- the collaborators' version: the rev of the owner's latest change of them (SetCollaborators)
    if r.cr ~= nil then
        if not IsInt(r.cr, 1, out.rev) then return nil end
        out.cr = r.cr
    end
    out.n = CleanText(r.n, MAX_NAME_LEN)
    if not out.n or type(r.p) ~= "table" then return nil end
    out.p = {}
    local blockIds, pageIds = {}, {}
    for i = 1, MAX_PAGES + 1 do
        local p = r.p[i]
        if p == nil then break end
        if i > MAX_PAGES then return nil end
        local cp = CleanPage(p, blockIds)
        if not cp or pageIds[cp.id] then return nil end
        pageIds[cp.id] = true
        out.p[#out.p + 1] = cp
    end
    if #out.p == 0 then return nil end
    return out
end

local function CleanFill(r, now)
    local out = CleanCommon(r, now)
    if not out or not IsOccId(r.o) or not IsBossRef(r.b) then return nil end
    out.o, out.b = r.o, r.b
    out.id = FillId(r.o, r.b)
    if r.id ~= out.id then return nil end
    if not IsInt(r.t, 0, now + 400 * DAY) then return nil end
    out.t = r.t
    if r.s ~= nil then
        if not IsId(r.s) then return nil end
        out.s = r.s
    end
    -- x = true: the raid uses no strategy for this boss (picked so; 1.3.3 - older clients drop the field and fall
    -- back to the default pick)
    if r.x == true and r.s == nil then out.x = true end
    out.a = {}
    if r.a ~= nil then
        if type(r.a) ~= "table" then return nil end
        local n = 0
        for ref, key in pairs(r.a) do
            n = n + 1
            if n > MAX_ASSIGN or not SplitSlot(ref) then return nil end
            local k = WireKey(key)
            if not k then return nil end
            out.a[ref] = k
        end
    end
    return out
end

Strategy._CleanStrategy = CleanStrategy   -- for tests

---------------------------------------------------------------------------
-- Merge
---------------------------------------------------------------------------

-- Is that fill shown (FillWriter, judged now)?
local function Trusted(rec)
    return rec ~= nil and (FillWriter(rec))
end

-- Strategies built on a newer list of collaborators (cr) come first: the owner's change of them beats an edit made on
-- the list before it, whichever arrives first. Then the rev, then the hash (fills have no cr).
local function Newer(a, b)
    if not b then return true end
    if (a.cr or 0) ~= (b.cr or 0) then return (a.cr or 0) > (b.cr or 0) end
    if a.rev ~= b.rev then return a.rev > b.rev end
    return Util.Hash(a) > Util.Hash(b)
end

-- Remembers the newest fill of every strategy (carry over, even after the fill itself is pruned).
local function NoteLast(root, f)
    if not f.s or not next(f.a) then return end
    local cur = root.L[f.s]
    if cur and (cur.t or 0) > f.t then return end
    root.L[f.s] = { t = f.t, o = f.o, a = Copy(f.a) }
end

-- The strategies (not deleted) one member owns.
local function CountOwned(root, key)
    local n = 0
    for _, rec in pairs(root.B) do
        if not rec.del and Owner(rec) == key then n = n + 1 end
    end
    return n
end

-- The strategies in the guild (not deleted): MAX_STRATS of them at most.
local function CountLive(root)
    local n = 0
    for _, rec in pairs(root.B) do
        if not rec.del then n = n + 1 end
    end
    return n
end

-- Room to store one more strategy record (MAX_RECORDS): a new strategy forgets the oldest deletion for it; a new
-- deletion of a strategy I never had is not kept then. The same on the sender (Commit) and the receivers. Graves
-- (deletions out of the digest, 1.4.1) don't count, as clients before 1.4.1 no longer hold them; a strategy is never
-- forgotten.
local function Room(root, live)
    local now = Now()
    local n, oldest = 0, nil
    for id, rec in pairs(root.B) do
        if not sync:IsGrave("B", rec, now) then
            n = n + 1
            if rec.del and (not oldest or rec.rev < root.B[oldest].rev
                or (rec.rev == root.B[oldest].rev and id < oldest)) then oldest = id end
        end
    end
    if n < MAX_RECORDS then return true end
    if not live or not oldest then return false end
    root.B[oldest] = nil
    return true
end

-- Strategies (user rule 2026-10-04): a deletion wins. Its owner's or a moderator's deletion replaces the strategy
-- whatever the revs (one that crossed a later edit still deletes it), and no edit brings a deleted strategy back
-- (Copy makes a new one); a deletion from anyone else never counts, so the strategy replaces it. Otherwise the newer
-- record wins (Newer) if it may (Allowed). Every client ends up with the same, whatever the order things arrive in.
-- 1.4.1: a deletion stays a grave for a year (DigestSync.lua), so a copy from a member who was away that long is
-- refused and they get the deletion back (it still comes back after a deletion Room forgot, or after that year).
local function MergeStrategy(root, cur, rec)
    local live = cur and not cur.del and cur or nil
    if rec.del then
        if live then
            if not Deletes(rec, live) then
                ns:Debug("Strategy: deletion of %s by %s refused (not its owner)", rec.id, rec.by)
                return false
            end
        elseif cur then
            if not Newer(rec, cur) then return false end
        elseif not Room(root, false) then
            return false
        end
    elseif cur and cur.del and Deletes(cur, rec) then
        ns:Debug("Strategy: %s is deleted, %s's edit dropped", rec.id, rec.by)
        return false
    elseif live then
        if not Newer(rec, live) then return false end
        if not Allowed(live, rec) then
            ns:Debug("Strategy: %s by %s refused (not its owner or a collaborator)", rec.id, rec.by)
            return false
        end
    else
        if not Allowed(nil, rec) or CountOwned(root, Owner(rec)) >= MAX_OWN then return false end
        if CountLive(root) >= MAX_STRATS or (not cur and not Room(root, true)) then
            ns:Debug("Strategy: store full, %s dropped", rec.id)
            return false
        end
    end
    root.B[rec.id] = rec
    return true
end

-- Fills: one from someone who may write that raid's fills beats one from someone who may not, whatever the revs (an
-- untrusted fill never replaces a trusted one, and the same wins in any order); otherwise the newer one.
local function MergeFill(root, cur, rec)
    if cur then
        local curOk, known = FillWriter(cur)
        local recOk = FillWriter(rec)
        if known and curOk and not recOk then
            ns:Debug("Strategy: fill %s by %s refused (not who leads that raid)", rec.id, rec.by)
            return false
        end
        if not (known and recOk and not curOk) and not Newer(rec, cur) then return false end
    elseif CountTable(root.F) >= MAX_FILLS then
        ns:Debug("Strategy: fill store full, %s dropped", rec.id)
        return false
    end
    root.F[rec.id] = rec
    if Trusted(rec) then NoteLast(root, rec) end
    return true
end

local function MergeRecord(root, kind, rec)
    if kind == "B" then return MergeStrategy(root, root.B[rec.id], rec) end
    return MergeFill(root, root.F[rec.id], rec)
end

local function StoreRecord(kind, r)
    local root = Root(true)
    if not root then return false end
    local now = Now()
    local rec
    if kind == "B" then rec = CleanStrategy(r, now)
    elseif kind == "F" then rec = CleanFill(r, now)
    end
    if not rec then return false end
    return MergeRecord(root, kind, rec)
end

---------------------------------------------------------------------------
-- Digest / sync
---------------------------------------------------------------------------

local function Broadcast(kind, rec)
    Send({ t = "SBU", k = kind, r = rec }, "GUILD", nil, "data")
end

-- SBU { k, r }: a live edit (the editor must be the sender).
local function OnUpdate(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.r) ~= "table" or WireKey(msg.r.by) ~= sender then return end
    if msg.k ~= "B" and msg.k ~= "F" then return end
    if StoreRecord(msg.k, msg.r) then Changed() else sync:ReturnGrave(msg.k, msg.r, sender) end
end

-- SBG { k, r }: one item, relayed by anyone in the guild.
local function OnGive(sender, msg, dist)
    if dist ~= "WHISPER" or (msg.k ~= "B" and msg.k ~= "F") or type(msg.r) ~= "table" then return end
    if StoreRecord(msg.k, msg.r) then Changed() else sync:ReturnGrave(msg.k, msg.r, sender) end
end

---------------------------------------------------------------------------
-- Bosses
---------------------------------------------------------------------------

local SKIP_BOSS = { Trash = true, Patterns = true, TimedChests = true }

-- The bosses of a raid plan instance key ("bt") or an ItemDB raid key ("BlackTemple"): { ref, name } in raid order.
function Strategy:GetBosses(instKey)
    local out = {}
    local ItemDB = ns.ItemDB
    if not ItemDB then return out end
    local RP = ns.RaidPlan
    local inst = RP and RP.GetInstance and RP:GetInstance(instKey)
    for _, raid in ipairs(ItemDB:GetRaids()) do
        if raid.key == instKey or (inst and inst.instID and raid.instanceID == inst.instID) then
            for _, b in ipairs(raid.bosses or {}) do
                if not SKIP_BOSS[b.key] and not b.isTrash then
                    out[#out + 1] = { ref = raid.key .. ":" .. b.key, name = b.name, raid = raid.key, raidName = raid.name }
                end
            end
        end
    end
    return out
end

-- The bosses of a planned raid (a view): those of each of its instances, in the night's order (1.3.2: a raid can hold
-- several, e.g. Gruul + Magtheridon). Same shape as GetBosses.
function Strategy:GetRaidBosses(v)
    local RP = ns.RaidPlan
    local out = {}
    local keys = (RP and RP.GetRaidInstances and type(v) == "table") and RP:GetRaidInstances(v) or {}
    if #keys == 0 and type(v) == "table" then keys = { v.i } end
    for _, key in ipairs(keys) do
        for _, b in ipairs(self:GetBosses(key)) do out[#out + 1] = b end
    end
    return out
end

-- Every raid with its bosses (for the strategy library): { { key, name, bosses = { {ref, name} } } }.
function Strategy:GetRaidTree()
    local out = {}
    local ItemDB = ns.ItemDB
    if not ItemDB then return out end
    for _, raid in ipairs(ItemDB:GetRaids()) do
        local bosses = self:GetBosses(raid.key)
        if #bosses > 0 then out[#out + 1] = { key = raid.key, name = raid.name, bosses = bosses } end
    end
    return out
end

function Strategy:GetBossName(ref)
    local ItemDB = ns.ItemDB
    local b = ItemDB and ItemDB.GetBossRef and ItemDB:GetBossRef(ref)
    if b then return b.name or (b.boss and b.boss.name) or ref end
    return ref and (tostring(ref):match(":(.+)$") or ref) or "?"
end

-- The raid name of a boss reference.
function Strategy:GetRaidName(ref)
    local key = type(ref) == "string" and ref:match("^(%w+):") or nil
    local ItemDB = ns.ItemDB
    local raid = key and ItemDB and ItemDB:GetRaid(key)
    return raid and raid.name or key or "?"
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

-- May I write a raid's assignments (fills): pick its strategies and assign its players? With a raid id: who leads
-- that raid and the GM (RaidPlan:CanAssignStrategies). Without: the GM and the raid leaders on the list.
function Strategy:CanAssign(occId)
    local me = Util.PlayerKey()
    if occId ~= nil then return (CanWriteRaid(occId, me)) end
    local RP = ns.RaidPlan
    return RP ~= nil and RP.IsOrganizer ~= nil and RP:IsOrganizer(me) and true or false
end

function Strategy:CanWrite(key)
    return CanWrite(key)
end

-- May I build strategies? Every guild member.
function Strategy:CanBuild()
    return Util.PlayerKey() ~= nil and GuildKey() ~= nil
end

-- The owner of a strategy (a record or its id), or nil.
function Strategy:GetOwner(s)
    if type(s) == "string" then
        local root = Root(false)
        s = root and root.B[s]
    end
    return type(s) == "table" and not s.del and Owner(s) or nil
end

function Strategy:IsOwner(s, key)
    local owner = self:GetOwner(s)
    return owner ~= nil and SamePlayer(owner, key or Util.PlayerKey())
end

-- May I (or that member) change this strategy (a record or its id)? Its owner, the collaborators the owner invited,
-- and (as an exception) the GM and the guild council.
function Strategy:CanEditStrategy(s, key)
    if type(s) == "string" then
        local root = Root(false)
        s = root and root.B[s]
    end
    local me = key or Util.PlayerKey()
    if type(s) ~= "table" or s.del or not me then return false end
    return IsOwnerKey(s, me) or IsCollab(s, me) or CanModerate(me)
end

-- Did the owner invite that member (default: me) to this strategy (a record or its id)?
function Strategy:IsCollaborator(s, key)
    if type(s) == "string" then
        local root = Root(false)
        s = root and root.B[s]
    end
    return type(s) == "table" and not s.del and IsCollab(s, key or Util.PlayerKey())
end

-- May I delete it? Its owner, the GM and the guild council.
function Strategy:CanDeleteStrategy(s)
    local me = Util.PlayerKey()
    return self:IsOwner(s, me) or (self:GetOwner(s) ~= nil and CanModerate(me))
end

local function Visible(root, rec)
    return rec and not rec.del
end

-- Visible strategies (copies), optionally of one boss, sorted by raid order then name.
function Strategy:GetStrategies(bossRef)
    local out = {}
    local root = Root(false)
    if not root then return out end
    for _, rec in pairs(root.B) do
        if Visible(root, rec) and (bossRef == nil or rec.b == bossRef) then out[#out + 1] = Copy(rec) end
    end
    tsort(out, function(a, b)
        if a.b ~= b.b then return a.b < b.b end
        local la, lb = a.n:lower(), b.n:lower()
        if la ~= lb then return la < lb end
        return a.id < b.id
    end)
    return out
end

function Strategy:GetStrategy(id)
    local root = Root(false)
    local rec = root and type(id) == "string" and root.B[id]
    if not Visible(root, rec) then return nil end
    return Copy(rec)
end

-- The number of strategies per boss { [ref] = n }.
function Strategy:CountByBoss()
    local out = {}
    for _, s in ipairs(self:GetStrategies()) do out[s.b] = (out[s.b] or 0) + 1 end
    return out
end

-- The strategies that match a filter (copies; raid order, then boss order, then name). f (every field optional):
-- raid = an ItemDB raid key ("BlackTemple"), boss = a boss ref, by = the owner's key, co = a collaborator's key,
-- text = free search (every word must occur in its name, boss, raid, owner, collaborators, page names or table
-- names).
function Strategy:Find(f)
    f = type(f) == "table" and f or {}
    local out = {}
    local root = Root(false)
    if not root then return out end
    local order, names, n = {}, {}, 0
    for _, raid in ipairs(self:GetRaidTree()) do
        for _, b in ipairs(raid.bosses) do
            n = n + 1
            order[b.ref] = n
            names[b.ref] = b.name .. "\n" .. raid.name
        end
    end
    local words = {}
    for w in tostring(f.text or ""):lower():gmatch("%S+") do words[#words + 1] = w end
    for _, rec in pairs(root.B) do
        if Visible(root, rec) and (f.boss == nil or rec.b == f.boss)
            and (f.raid == nil or rec.b:match("^(%w+):") == f.raid)
            and (f.by == nil or Owner(rec) == f.by)
            and (f.co == nil or IsCollab(rec, f.co)) then
            local ok = true
            if #words > 0 then
                local hay = { rec.n, names[rec.b] or rec.b, Util.ShortName(Owner(rec)) or Owner(rec) }
                for _, k in ipairs(rec.co or {}) do hay[#hay + 1] = Util.ShortName(k) or k end
                for _, p in ipairs(rec.p) do
                    hay[#hay + 1] = p.n
                    for _, k in ipairs(p.k or {}) do hay[#hay + 1] = k.n end
                end
                local text = tconcat(hay, "\n"):lower()
                for _, w in ipairs(words) do
                    if not text:find(w, 1, true) then
                        ok = false
                        break
                    end
                end
            end
            if ok then out[#out + 1] = Copy(rec) end
        end
    end
    tsort(out, function(a, b)
        local oa, ob = order[a.b] or 9999, order[b.b] or 9999
        if oa ~= ob then return oa < ob end
        if a.b ~= b.b then return a.b < b.b end
        local la, lb = a.n:lower(), b.n:lower()
        if la ~= lb then return la < lb end
        return a.id < b.id
    end)
    return out
end

-- The members who own a strategy: { { key, n = how many } }, by name.
function Strategy:GetAuthors()
    local count = {}
    local root = Root(false)
    for _, rec in pairs(root and root.B or {}) do
        if Visible(root, rec) then count[Owner(rec)] = (count[Owner(rec)] or 0) + 1 end
    end
    local out = {}
    for key, n in pairs(count) do out[#out + 1] = { key = key, n = n } end
    tsort(out, function(a, b) return a.key < b.key end)
    return out
end

-- Every player slot of a strategy, in page / block / row / column order:
-- { ref, page, pageName, block, blockName, row, col, f = filter, label }.
function Strategy:GetSlots(strat)
    local out = {}
    if type(strat) ~= "table" then return out end
    for pi, p in ipairs(strat.p or {}) do
        for _, k in ipairs(p.k or {}) do
            for row = 1, k.r do
                local rowLabel
                for ci, col in ipairs(k.c) do
                    local cell = k.d and k.d[row] and k.d[row][ci]
                    if not rowLabel and cell ~= nil then
                        if col.t == "x" then rowLabel = (cell:gsub("\n", " "))
                        elseif col.t == "g" and cell.l then rowLabel = cell.l end
                    end
                end
                for ci, col in ipairs(k.c) do
                    if col.t == "p" then
                        local own = k.d and k.d[row] and k.d[row][ci]
                        local parts = { k.n }
                        if rowLabel then parts[#parts + 1] = rowLabel elseif k.r > 1 then parts[#parts + 1] = "#" .. row end
                        if col.n and #k.c > 1 then parts[#parts + 1] = col.n end
                        out[#out + 1] = { ref = SlotRef(k.id, row, ci), page = pi, pageName = p.n, block = k.id,
                                          blockName = k.n, row = row, col = ci,
                                          f = (type(own) == "table" and own.f) or col.f,
                                          label = tconcat(parts, " · ") }
                    end
                end
            end
        end
    end
    return out
end

-- Finds a block by id: block, page index.
function Strategy:FindBlock(strat, blockId)
    for pi, p in ipairs(type(strat) == "table" and strat.p or {}) do
        for _, k in ipairs(p.k or {}) do
            if k.id == blockId then return k, pi end
        end
    end
    return nil
end

-- Does a player (class, spec index) fit a slot filter?
function Strategy:MatchFilter(f, classFile, sp)
    if f == nil or f == "" then return true end
    local role = ns.RaidComp and ns.RaidComp:RoleOf(classFile, sp) or nil
    for tok in f:gmatch("[^,]+") do
        if tok == classFile or (role ~= nil and tok == role) then return true end
    end
    return false
end

-- A filter in words ("Hunter", "Tank or Healer").
function Strategy:FilterText(f)
    if f == nil or f == "" then return "Anyone" end
    local parts = {}
    for tok in f:gmatch("[^,]+") do
        local label = ns.CLASS_NAMES and ns.CLASS_NAMES[tok] or (tok:sub(1, 1):upper() .. tok:sub(2))
        parts[#parts + 1] = label
    end
    return tconcat(parts, " or ")
end

---------------------------------------------------------------------------
-- Writing strategies
---------------------------------------------------------------------------

local NO_GUILD = "Your guild is not known yet; try again in a moment."

-- Fills (of that raid).
local function RequireWriter(occId)
    if not CanWriteRaid(occId, Util.PlayerKey()) then
        local RP = ns.RaidPlan
        return nil, (RP and RP.GetRaidLeader and RP:GetRaidLeader(occId)) and REFUSED_LED or REFUSED
    end
    local root = Root(true)
    if not root then return nil, NO_GUILD end
    return root
end

-- Strategies.
local function RequireBuilder()
    local root = Util.PlayerKey() and Root(true)
    if not root then return nil, NO_GUILD end
    return root
end

local TOO_BIG = "it is too big to send to the guild (remove some pages, tables, drawings or notes)"

local function Commit(root, kind, rec)
    local now = Now()
    local clean = kind == "B" and CleanStrategy(rec, now) or CleanFill(rec, now)
    if not clean then return false, kind == "B" and Strategy:Explain(rec) or "invalid assignment data" end
    local cur = root[kind][clean.id]
    if kind == "F" then
        if not cur and CountTable(root.F) >= MAX_FILLS then return false, "too many assignments stored" end
    else
        -- everyone must take it (with room to spare for whoever passes it on later): nothing is dropped unseen
        local Comm = ns.Comm
        if Comm and Comm.Fits and not Comm:Fits({ t = "SBU", k = "B", r = clean }, SIZE_HEADROOM) then
            return false, TOO_BIG
        end
        if not clean.del and not cur and (CountLive(root) >= MAX_STRATS or not Room(root, true)) then
            return false, "the guild has " .. MAX_STRATS .. " strategies already (delete some old ones)"
        end
    end
    root[kind][clean.id] = clean
    if kind == "F" then NoteLast(root, clean) end
    Broadcast(kind, clean)
    Changed()
    return true, clean
end

-- A fresh id for a page or block that isn't used in the strategy yet.
function Strategy:NewPartId(strat, prefix)
    local used = {}
    for _, p in ipairs(type(strat) == "table" and strat.p or {}) do
        used[p.id] = true
        for _, k in ipairs(p.k or {}) do used[k.id] = true end
    end
    for i = 1, 999 do
        local id = (prefix or "k") .. i
        if not used[id] then return id end
    end
    return nil
end

-- A copy of a block under a new id of the strategy (not yet on any page): cells that showed one of the block's own
-- slots show the copy's slot instead; references into other blocks stay. nil when the strategy has no free id.
function Strategy:CopyBlock(strat, k)
    local id = self:NewPartId(strat, "k")
    if not id or type(k) ~= "table" then return nil end
    local c = Copy(k)
    c.id = id
    local prefix = k.id .. "."
    for _, cells in pairs(c.d or {}) do
        for _, v in pairs(cells) do
            if type(v) == "table" and type(v.s) == "string" and v.s:sub(1, #prefix) == prefix then
                v.s = id .. "." .. v.s:sub(#prefix + 1)
            end
        end
    end
    return c
end

-- Rewrites the references into one block after its rows / columns changed. fn(row, col) -> newRow, newCol, or nil
-- when that cell is gone. Covers drawings (links, slot tokens) and target cells showing a slot. A link to a whole
-- column follows the column (fn(nil, col)).
function Strategy:RemapBlockRefs(strat, blockId, fn)
    local function map(ref)
        if type(ref) ~= "string" then return ref end
        local b, r, c = ref:match("^(%w+)%.(%d+)%.(%d+)$")
        if b == blockId then
            local nr, nc = fn(tonumber(r), tonumber(c))
            return nr and SlotRef(b, nr, nc) or false
        end
        b, c = ref:match("^(%w+)%.(%d+)$")
        if b == blockId then
            local _, nc = fn(nil, tonumber(c))
            return nc and (b .. "." .. nc) or false
        end
        return ref
    end
    for _, p in ipairs(type(strat) == "table" and strat.p or {}) do
        local keep = {}
        for _, e in ipairs(p.e or {}) do
            local drop = false
            if e.ln then
                local n = map(e.ln)
                e.ln = n or nil
            end
            if e.t == "s" then
                local n = map(e.r)
                if n then e.r = n else drop = true end
            end
            if not drop then keep[#keep + 1] = e end
        end
        p.e = keep
        for _, k in ipairs(p.k or {}) do
            for _, cells in pairs(k.d or {}) do
                for _, v in pairs(cells) do
                    if type(v) == "table" and v.s then
                        local n = map(v.s)
                        v.s = n or nil
                    end
                end
            end
        end
    end
end

-- An unsaved strategy for a boss (one page P1, map picked by the UI).
function Strategy:NewDraft(bossRef, name, mapID)
    return { b = bossRef, n = name or "Strategy", p = { { id = "p1", n = "P1", m = tonumber(mapID) or 0, e = {}, k = {} } } }
end

-- Validates the draft without saving: clean copy or nil, error.
function Strategy:Validate(draft)
    if type(draft) ~= "table" then return nil, "invalid strategy" end
    local r = Copy(draft)
    r.id = r.id or "draft"
    r.rev, r.by, r.cr = Now(), Util.PlayerKey() or "x-y", nil
    local clean = CleanStrategy(r, Now())
    if not clean then return nil, self:Explain(r) end
    return clean
end

-- What the encounter helpers follow for a table: its "Track in fight" setting, else what its cells say (boss
-- abilities picked -> an interrupt rotation; only curses picked -> curses), for tables made before tracking existed.
function Strategy.TrackKind(k)
    if type(k) ~= "table" then return nil end
    if k.tr then return k.tr end
    local any, curses = false, true
    for _, cells in pairs(k.d or {}) do
        for _, v in pairs(cells) do
            if type(v) == "table" and type(v.a) == "table" then
                for _, id in ipairs(v.a) do
                    any = true
                    if not CURSE_IDS[id] then curses = false end
                end
            end
        end
    end
    if not any then return nil end
    return curses and "curse" or "rot"
end

-- Dispel tables: the classes that can remove an effect of that type (from the enemy when `enemy`), in class order.
function Strategy.DispelClasses(dy, enemy)
    local list = (enemy and DISPEL_ENEMY or DISPEL_FRIEND)[dy]
    local out = {}
    for i, c in ipairs(list or {}) do out[i] = c end
    return out
end

-- The same as a player column's "who fits" filter (nil when nobody can).
function Strategy.DispelFilter(dy, enemy)
    local list = Strategy.DispelClasses(dy, enemy)
    return #list > 0 and tconcat(list, ",") or nil
end

-- Can that class remove such an effect?
function Strategy.CanDispel(class, dy, enemy)
    for _, c in ipairs((enemy and DISPEL_ENEMY or DISPEL_FRIEND)[dy] or {}) do
        if c == class then return true end
    end
    return false
end

-- Where an effect of that type can be removed at all: Enrage only from the enemy, curses / poisons / diseases only
-- from our raid, Magic from both. Returns the side to use (true = enemy) for the one asked for.
function Strategy.DispelSide(dy, enemy)
    if dy == "e" then return true end
    if dy == "m" then return enemy and true or false end
    return false
end

-- The removable effects of a boss (Data/BossAbilities.lua): { { id, t = type, en = true when on the enemy }, ... }.
function Strategy:GetBossDispels(bossRef)
    local known = ns.Data and ns.Data.BossAbilities and ns.Data.BossAbilities[bossRef]
    return known and known.d or {}
end

-- The dispel type of a spell id any boss' list knows (an effect typed in by id), and whether it sits on the enemy.
function Strategy:DispelTypeOf(id)
    for _, known in pairs(ns.Data and ns.Data.BossAbilities or {}) do
        for _, e in ipairs(known.d or {}) do
            if e.id == id then return e.t, e.en end
        end
    end
    return nil
end

-- What makes a draft invalid, in words (the first problem found).
function Strategy:Explain(r)
    if not IsBossRef(r.b) then return "no boss" end
    if not CleanText(r.n, MAX_NAME_LEN) then return "the name must be 1-32 characters without |" end
    if type(r.p) ~= "table" or #r.p == 0 then return "no pages" end
    if #r.p > MAX_PAGES then return "at most " .. MAX_PAGES .. " pages" end
    local blockIds = {}
    for pi, p in ipairs(r.p) do
        local where = "page " .. tostring(p.n or pi)
        if not CleanText(p.n, MAX_PAGE_NAME) then return where .. ": the page name must be 1-24 characters" end
        if type(p.no) == "string" and (#p.no > MAX_NOTES or p.no:find("|")) then
            return where .. ": the notes are " .. #p.no .. " characters (at most " .. MAX_NOTES .. ", no |)"
        end
        if #(p.e or {}) > MAX_ELEMENTS then return where .. ": more than " .. MAX_ELEMENTS .. " drawings" end
        for ei, e in ipairs(p.e or {}) do
            if not CleanElement(e) then
                return where .. ": drawing " .. ei .. (e.l and (" (" .. tostring(e.l) .. ")") or "") .. " is not valid"
            end
        end
        for _, k in ipairs(p.k or {}) do
            if not CleanBlock(k) then return where .. ": the block \"" .. tostring(k.n) .. "\" is not valid" end
            if blockIds[k.id] then return where .. ": two blocks share the id " .. tostring(k.id) end
            blockIds[k.id] = true
        end
    end
    return "something in this strategy is not valid"
end

local NOT_YOURS = "Only its owner, the collaborators the owner invited, the Guild Master and the guild council can change this strategy (Copy makes one of your own)."

-- Saves a draft (new when draft.id is nil: it is mine). The owner and the collaborators of a saved strategy stay
-- what they are (SetCollaborators changes them). Returns ok, idOrErr.
function Strategy:SaveStrategy(draft)
    local root, err = RequireBuilder()
    if not root then return false, err end
    if type(draft) ~= "table" then return false, "invalid strategy" end
    if not IsBossRef(draft.b) then return false, "Pick a boss." end
    if not CleanText(draft.n, MAX_NAME_LEN) then return false, "Strategy names are 1-32 characters." end
    local me = Util.PlayerKey()
    local cur = draft.id and root.B[draft.id]
    if draft.id and (not cur or cur.del) then return false, "unknown strategy" end
    if cur and not self:CanEditStrategy(cur) then return false, NOT_YOURS end
    if not cur and CountOwned(root, me) >= MAX_OWN then
        return false, "you have " .. MAX_OWN .. " strategies already (delete an old one)"
    end
    local rec = Copy(draft)
    rec.id = draft.id or NewId()
    rec.rev, rec.by, rec.del = NextRev(cur), me, nil
    rec.ow = cur and Owner(cur) or me
    rec.co = cur and cur.co and Copy(cur.co) or nil
    rec.cr = cur and cur.cr or nil
    local ok, e = Commit(root, "B", rec)
    if not ok then return false, e end
    return true, rec.id
end

function Strategy:DeleteStrategy(id)
    local root, err = RequireBuilder()
    if not root then return false, err end
    local cur = type(id) == "string" and root.B[id]
    if not cur or cur.del then return false, "unknown strategy" end
    if not self:CanDeleteStrategy(cur) then
        return false, "Only its owner, the Guild Master and the guild council can delete this strategy."
    end
    return (Commit(root, "B", { id = id, rev = NextRev(cur), by = Util.PlayerKey(), del = true }))
end

-- The collaborators of a strategy (sorted keys; a copy).
function Strategy:GetCollaborators(id)
    local root = Root(false)
    local cur = root and type(id) == "string" and root.B[id]
    return cur and not cur.del and cur.co and Copy(cur.co) or {}
end

-- Sets who else may change my strategy: keys (an array or a set), at most MAX_COLLAB guild members. Returns ok, err.
function Strategy:SetCollaborators(id, keys)
    local root, err = RequireBuilder()
    if not root then return false, err end
    local cur = type(id) == "string" and root.B[id]
    if not cur or cur.del then return false, "unknown strategy" end
    local me = Util.PlayerKey()
    if not IsOwnerKey(cur, me) then return false, "Only the owner of a strategy picks its collaborators." end
    local G = Guild()
    local list, seen = {}, {}
    for k, v in pairs(type(keys) == "table" and keys or {}) do
        local key = type(k) == "string" and v and k or (type(v) == "string" and v) or nil
        key = key and WireKey(key)
        if key and key ~= me and key ~= Owner(cur) and not seen[key] then
            if G and G.IsInGuild and not G:IsInGuild(key, true) and not IsCollab(cur, key) then
                return false, (Util.ShortName(key) or key) .. " is not in the guild"
            end
            seen[key] = true
            list[#list + 1] = key
        end
    end
    if #list > MAX_COLLAB then return false, "A strategy has at most " .. MAX_COLLAB .. " collaborators." end
    tsort(list)
    local rec = Copy(cur)
    rec.rev, rec.by, rec.ow = NextRev(cur), me, Owner(cur)   -- (an alt of the owner keeps the owner the owner)
    rec.co = #list > 0 and list or nil
    -- a new list is a new version of it: an edit made on the old list, arriving later, loses to this (Newer)
    if not SameList(cur.co, rec.co) then rec.cr = rec.rev end
    return (Commit(root, "B", rec))
end

function Strategy:AddCollaborator(id, key)
    local list = self:GetCollaborators(id)
    list[#list + 1] = key
    return self:SetCollaborators(id, list)
end

function Strategy:RemoveCollaborator(id, key)
    key = WireKey(key)
    local list = {}
    for _, k in ipairs(self:GetCollaborators(id)) do
        if k ~= key then list[#list + 1] = k end
    end
    return self:SetCollaborators(id, list)
end

-- Copies a strategy under a new name (optionally to another boss); the copy is mine. Returns ok, newIdOrErr.
function Strategy:CopyStrategy(id, name, bossRef)
    local s = self:GetStrategy(id)
    if not s then return false, "unknown strategy" end
    s.id, s.rev, s.by, s.ow, s.co, s.cr = nil, nil, nil, nil, nil, nil
    s.n = name or (s.n .. " (copy)"):sub(1, MAX_NAME_LEN)
    if bossRef then s.b = bossRef end
    return self:SaveStrategy(s)
end

---------------------------------------------------------------------------
-- Fills (per raid, per boss)
---------------------------------------------------------------------------

local function FillRec(root, occId, bossRef)
    local rec = root and root.F[FillId(occId, bossRef)]
    if rec and rec.o == occId and rec.b == bossRef and Trusted(rec) then return rec end
    return nil
end

-- The fill of (raid, boss): { s = strategy id | nil, a = { [slotRef] = key }, by, rev } (copy) or nil.
function Strategy:GetFill(occId, bossRef)
    local rec = FillRec(Root(false), occId, bossRef)
    return rec and Copy(rec) or nil
end

-- The strategy the guild picked for a boss in its latest raid up to `before` (else in its latest raid at all), other
-- than raid exceptOcc: a strategy id or nil. Pruned fills count through root.L.
local function LastPick(root, bossRef, exceptOcc, before)
    local best, bestT, latest, latestT
    local function consider(sid, o, t)
        if o == exceptOcc or type(t) ~= "number" then return end
        local s = root.B[sid]
        if not s or s.del or s.b ~= bossRef then return end
        if t <= before and (not bestT or t > bestT) then best, bestT = sid, t end
        if not latestT or t > latestT then latest, latestT = sid, t end
    end
    for _, f in pairs(root.F) do
        if f.b == bossRef and f.s and f.o ~= exceptOcc and Trusted(f) then consider(f.s, f.o, f.t) end
    end
    for sid, l in pairs(root.L) do consider(sid, l.o, l.t) end
    return best or latest
end

-- The strategy a raid uses for a boss, its fill, and why that one: "picked" (the raid's pick), "last" (none picked:
-- the one the guild used last time), "only" (the boss has one) or "first" (none used yet: the first by name). nil
-- when the boss has no strategy, or (how = "none") when the raid picked none for it.
function Strategy:GetRaidStrategy(occId, bossRef)
    local f = self:GetFill(occId, bossRef)
    if f and f.x then return nil, f, "none" end
    local s = f and f.s and self:GetStrategy(f.s)
    if s and s.b == bossRef then return s, f, "picked" end
    local list = self:GetStrategies(bossRef)
    if #list <= 1 then return list[1], f, list[1] and "only" or nil end
    local root = Root(false)
    local RP = ns.RaidPlan
    local v = RP and RP.GetRaid and RP:GetRaid(occId)
    local last = root and LastPick(root, bossRef, occId, v and v.t or Now())
    s = last and self:GetStrategy(last)
    if s then return s, f, "last" end
    return list[1], f, "first"
end

-- The strategy the guild used for a boss last time (another raid than occId): its id or nil.
function Strategy:GetLastPick(bossRef, occId)
    local root = Root(false)
    local RP = ns.RaidPlan
    local v = occId and RP and RP.GetRaid and RP:GetRaid(occId)
    return root and LastPick(root, bossRef, occId, v and v.t or Now()) or nil
end

-- Picks the strategy a raid uses for a boss and saves it at once; the names in the slots both strategies have stay.
-- stratId nil: the raid uses no strategy for the boss (e.g. its only one is still a work in progress); the names stay
-- for a later pick. Returns ok, err.
function Strategy:PickStrategy(occId, bossRef, stratId)
    if stratId == nil then
        local cur = self:GetFill(occId, bossRef)
        return self:SaveFill(occId, bossRef, nil, cur and cur.a, true)
    end
    local s = self:GetStrategy(stratId)
    if not s or s.b ~= bossRef then return false, "unknown strategy" end
    local cur = self:GetFill(occId, bossRef)
    return self:SaveFill(occId, bossRef, s.id, self:ValidAssignments(s, cur and cur.a))
end

-- Saves (raid, boss) -> strategy + names. assignments: { [slotRef] = key } (nil keeps the current ones); none = true:
-- no strategy for the boss in this raid (stratId nil).
function Strategy:SaveFill(occId, bossRef, stratId, assignments, none)
    local root, err = RequireWriter(occId)
    if not root then return false, err end
    if not IsOccId(occId) or not IsBossRef(bossRef) then return false, "unknown raid or boss" end
    local RP = ns.RaidPlan
    local v = RP and RP:GetRaid(occId)
    local id = FillId(occId, bossRef)
    local cur = root.F[id]
    local t = (v and v.t) or (cur and cur.t) or Now()
    local rec = { id = id, o = occId, b = bossRef, t = t, rev = NextRev(cur), by = Util.PlayerKey(), s = stratId,
                  x = (none and stratId == nil) and true or nil }
    local a = assignments
    if a == nil then a = cur and cur.a or {} end
    rec.a = {}
    for ref, key in pairs(a) do
        if SplitSlot(ref) and WireKey(key) then rec.a[ref] = WireKey(key) end
    end
    local ok, e = Commit(root, "F", rec)
    if not ok then return false, e end
    return true
end

-- The newest earlier fill of a strategy (another raid): { [slotRef] = key } or nil, plus its raid time.
function Strategy:GetLastFill(stratId, exceptOcc)
    local root = Root(false)
    if not root or type(stratId) ~= "string" then return nil end
    local best
    for _, f in pairs(root.F) do
        if f.s == stratId and f.o ~= exceptOcc and next(f.a) and Trusted(f) then
            if not best or f.t > best.t then best = f end
        end
    end
    if best then return Copy(best.a), best.t end
    local l = root.L[stratId]
    if l and l.o ~= exceptOcc and type(l.a) == "table" then return Copy(l.a), l.t end
    return nil
end

-- The players a raid's slots are filled from: the group layout members (Accepted / Tentative / Bench sign-ups, and
-- whoever is placed in its groups), plus the people in my raid group now. { key, c, sp, st }.
function Strategy:GetRaidMembers(occId)
    local out, seen = {}, {}
    local RP = ns.RaidPlan
    local v = RP and occId and RP:GetRaid(occId)
    if v then
        for _, m in ipairs(RP:GetLayoutMembers(v)) do
            out[#out + 1] = { key = m.key, c = m.c, sp = m.sp, st = m.st }
            seen[m.key] = true
        end
    end
    if IsInRaid and IsInRaid() then
        for i = 1, GetNumGroupMembers() or 0 do
            local name, _, _, _, _, classFile = GetRaidRosterInfo(i)
            local key = type(name) == "string" and Util.NormalizeName(name) or nil
            if key and not seen[key] then
                local sp, c = nil, classFile
                if RP then sp, c = RP:GetMemberSpec(key) end
                out[#out + 1] = { key = key, c = c or classFile, sp = sp, inRaid = true }
                seen[key] = true
            end
        end
    end
    tsort(out, function(a, b) return a.key < b.key end)
    return out
end

-- Keeps only the assignments whose slot exists in the strategy. Returns a new table.
function Strategy:ValidAssignments(strat, a)
    local out = {}
    if type(a) ~= "table" then return out end
    local slots = {}
    for _, s in ipairs(self:GetSlots(strat)) do slots[s.ref] = true end
    for ref, key in pairs(a) do
        if slots[ref] then out[ref] = key end
    end
    return out
end

-- Fills the empty slots of `a` (a copy is returned) from `members` ({ key, c, sp }): each slot takes a matching
-- player who isn't in that block yet, the one with the fewest assignments first. Returns the new table, n filled.
function Strategy:SuggestFill(strat, a, members)
    local out = {}
    for k, v in pairs(type(a) == "table" and a or {}) do out[k] = v end
    local slots = self:GetSlots(strat)
    local byKey, used, inBlock = {}, {}, {}
    for _, m in ipairs(members or {}) do byKey[m.key] = m end
    for _, s in ipairs(slots) do
        local key = out[s.ref]
        if key then
            used[key] = (used[key] or 0) + 1
            inBlock[s.block] = inBlock[s.block] or {}
            inBlock[s.block][key] = true
        end
    end
    local order = {}
    for _, m in ipairs(members or {}) do order[#order + 1] = m end
    tsort(order, function(x, y) return x.key < y.key end)
    local n = 0
    for _, s in ipairs(slots) do
        if not out[s.ref] and s.f then        -- open slots ("Anyone") stay for the raid leader to pick
            local best
            for _, m in ipairs(order) do
                if self:MatchFilter(s.f, m.c, m.sp) and not (inBlock[s.block] and inBlock[s.block][m.key]) then
                    if not best or (used[m.key] or 0) < (used[best.key] or 0) then best = m end
                end
            end
            if best then
                out[s.ref] = best.key
                used[best.key] = (used[best.key] or 0) + 1
                inBlock[s.block] = inBlock[s.block] or {}
                inBlock[s.block][best.key] = true
                n = n + 1
            end
        end
    end
    return out, n
end

-- Players placed twice in the same block: { [slotRef] = true }.
function Strategy:FindDuplicates(strat, a)
    local out, seen = {}, {}
    for _, s in ipairs(self:GetSlots(strat)) do
        local key = a and a[s.ref]
        if key then
            local k = s.block .. "|" .. key
            if seen[k] then
                out[s.ref] = true
                out[seen[k]] = true
            else
                seen[k] = s.ref
            end
        end
    end
    return out
end

-- Every assignment of one player in a strategy: { slot, ... }.
function Strategy:GetPlayerSlots(strat, a, key)
    local out = {}
    for _, s in ipairs(self:GetSlots(strat)) do
        if a and a[s.ref] == key then out[#out + 1] = s end
    end
    return out
end

---------------------------------------------------------------------------
-- Retention
---------------------------------------------------------------------------

function Strategy:Prune(now)
    local root = Root(false)
    if not root then return end
    now = now or Now()
    -- deleted strategies: graves after TOMBSTONE_DAYS, dropped after GRAVE_KEEP (DigestSync.lua)
    local changed = sync:PruneGraves(root, now)
    for id, f in pairs(root.F) do
        if f.t < now - FILL_KEEP then root.F[id] = nil; changed = true end
    end
    for sid in pairs(root.L) do
        local s = root.B[sid]
        if not s or s.del then root.L[sid] = nil end
    end
    root.OK = nil           -- (up to 1.2 the fills found trusted were remembered here; FillWriter judges them now)
    if changed then Changed() end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Strategy:OnInit()
    -- everyone builds strategies: a member's (and the digest of them) may be as large as a council member's
    sync:Register(OnUpdate, OnGive)
    -- The raid leaders / council lists decide which fills are shown: repaint when they change.
    ns:On("CONFIG_UPDATED", Changed)
end

function Strategy:OnLogin()
    local function Daily()
        Strategy:Prune()
        Util.After(DAY / 4, Daily)
    end
    Util.RandomDelay(15, 30, Daily)
end
