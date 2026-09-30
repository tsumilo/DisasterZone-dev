-- CDLoot: Core/Strategy.lua
-- Strategy boards (Addendum K): per-boss strategies built from generic tools, and per-raid fills.
--
-- A strategy (kind B) belongs to one boss ("BlackTemple:Council") and holds pages (P1, P2, ...). Each page has a map
-- (a built-in instance map, panned / zoomed, or blank) with drawn elements (zones, arrows, icons, text, slot tokens)
-- and blocks: small tables whose columns are player slots (optionally limited to classes / roles), targets (an icon
-- and / or a label, or another slot), order numbers or text. A player slot is addressed "<block>.<row>.<col>"; block ids
-- are unique in the strategy, so a slot token on page 2 can show a slot of a page-1 block.
-- A fill (kind F) is one raid's names for one boss: the strategy picked for it and { [slotRef] = player key }.
--
-- Who: the GM, the guild council and the raid leaders write strategies and fills (the raid-groups rule, §62); everyone
-- in the guild caches and reads both. Sync mirrors the raid plan (§56): live edits on GUILD (SBU), and at login the
-- HELLO carries a hash of my data (sd); a client whose data differs answers with its digest (SBD), the new client asks
-- for what differs (SBW) and both send their copies one item per message (SBG). Records merge by rev (then hash).
local addonName, ns = ...

local Strategy = ns:NewModule("Strategy")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next = type, pairs, ipairs, tonumber, tostring, next
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat
local strformat = string.format

local DAY = 86400
local FUTURE_SLACK = 300
local TOMBSTONE_DAYS = 30 * DAY
local FILL_KEEP = 45 * DAY           -- fills are kept this long after their raid
local ROUND_WINDOW = 20
local SBD_DELAY_COUNCIL = { 0.5, 2.5 }
local SBD_DELAY_MEMBER = { 3, 8 }

-- The board's own coordinate space (the map art of an instance floor is about 1002 x 668).
local BOARD_W, BOARD_H = 1000, 666

local MAX_STRATS = 80
local MAX_FILLS = 120
local MAX_DIGEST_ITEMS = 200
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
local MAX_CELL = 64
local MAX_FILTER = 80
local MAX_ICON = 64
local MAX_COLOR = 12

local ROLES = { tank = true, healer = true, melee = true, ranged = true }
local COL_TYPES = { p = true, g = true, o = true, x = true }

Strategy.BOARD_W, Strategy.BOARD_H = BOARD_W, BOARD_H
Strategy.MAX_PAGES, Strategy.MAX_ELEMENTS, Strategy.MAX_BLOCKS = MAX_PAGES, MAX_ELEMENTS, MAX_BLOCKS
Strategy.MAX_COLS, Strategy.MAX_ROWS = MAX_COLS, MAX_ROWS
Strategy.MAX_NAME_LEN, Strategy.MAX_LABEL, Strategy.MAX_CELL = MAX_NAME_LEN, MAX_LABEL, MAX_CELL
Strategy.MAX_HEADER, Strategy.MAX_PAGE_NAME = MAX_HEADER, MAX_PAGE_NAME
Strategy.ROLES = { "tank", "healer", "melee", "ranged" }

local roundSeen = {}
local answeredAt = -1000
local idCounter = 0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

local function IsInt(n, lo, hi)
    return type(n) == "number" and n == floor(n) and n >= lo and n <= hi
end

local function CleanText(s, maxLen)
    if type(s) ~= "string" then return nil end
    s = Util.Trim(s)
    if s == "" or #s > maxLen or s:find("[%c|]") then return nil end
    return s
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
-- it:<item id>, boss:<creature display id> (a boss portrait).
local function IsIconKey(s)
    if type(s) ~= "string" or #s > MAX_ICON then return false end
    if s:find("^rt[1-8]$") or s:find("^sp:%d%d?%d?%d?%d?%d?$") or s:find("^it:%d%d?%d?%d?%d?%d?$")
        or s:find("^boss:%d%d?%d?%d?%d?%d?%d?$") then return true end
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

-- Authors (strategies and fills): the GM, the guild council and the raid leaders.
local function CanWrite(key)
    local G = Guild()
    return type(key) == "string" and G ~= nil and G.IsRaidLogMember ~= nil and G:IsRaidLogMember(key) and true or false
end

local REFUSED = "Only the Guild Master, the guild council and the raid leaders can change strategies and assignments."

local function Send(msg, dist, target, class)
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, class)) and true or false
end

local function RateLimit(key, seconds)
    local Comm = ns.Comm
    if not (Comm and Comm.RateLimit) then return true end
    return Comm:RateLimit(key, seconds)
end

local function Root(create)
    local db = ns.db
    local g = GuildKey()
    if not db or not g then return nil end
    if type(db.strategy) ~= "table" then
        if not create then return nil end
        db.strategy = {}
    end
    local r = db.strategy[g]
    if type(r) ~= "table" then
        if not create then return nil end
        r = {}
        db.strategy[g] = r
    end
    for _, k in ipairs({ "B", "F", "L", "OK" }) do
        if type(r[k]) ~= "table" then r[k] = {} end
    end
    return r
end

local function Changed()
    ns:Fire("STRATEGY_CHANGED")
end

local function NextRev(cur)
    local prev = type(cur) == "table" and tonumber(cur.rev) or 0
    return max(Now(), prev + 1)
end

local function NewId()
    idCounter = idCounter + 1
    local now = Now()
    return strformat("%x", now) .. Util.Hash({ Util.PlayerKey() or "", now, idCounter, GetTime() }):sub(1, 4)
end

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
        out.l = CleanText(e.l, MAX_LABEL)
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
    elseif t == "x" then
        if not out.l then return nil end
        if e.z ~= nil then
            if not IsInt(e.z, 1, 3) then return nil end
            out.z = e.z
        end
    elseif t == "s" then
        if not SplitSlot(e.r) then return nil end
        out.r = e.r
    else
        return nil
    end
    return out
end

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
    if colType == "x" then
        return CleanText(v, MAX_CELL)
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
        if type(p.no) ~= "string" or #p.no > 400 or p.no:find("|") then return nil end
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

local function Trusted(root, kind, rec)
    if not rec then return false end
    local k = kind .. ":" .. tostring(rec.id) .. ":" .. tostring(rec.rev)
    if root.OK[k] then return true end
    if CanWrite(rec.by) then
        root.OK[k] = true
        return true
    end
    return false
end

local function Newer(a, b)
    if not b then return true end
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

local CAP = { B = MAX_STRATS, F = MAX_FILLS }

local function MergeRecord(root, kind, rec)
    local store = root[kind]
    local cur = store[rec.id]
    if cur then
        if not Newer(rec, cur) then return false end
    elseif CountTable(store) >= CAP[kind] then
        ns:Debug("Strategy: %s store full, %s dropped", kind, rec.id)
        return false
    end
    store[rec.id] = rec
    if Trusted(root, kind, rec) and kind == "F" then NoteLast(root, rec) end
    return true
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

local function ItemHash(root, item)
    local kind, id = item:match("^(%u):(.+)$")
    local rec = kind and root[kind] and root[kind][id]
    return rec and Util.Hash(rec):sub(1, 6) or nil
end

function Strategy:GetDigest()
    local out = {}
    local root = Root(false)
    if not root then return out end
    local items = {}
    for id in pairs(root.B) do items[#items + 1] = "B:" .. id end
    for id in pairs(root.F) do items[#items + 1] = "F:" .. id end
    tsort(items)
    local n = 0
    for _, item in ipairs(items) do
        local h = ItemHash(root, item)
        if h then
            n = n + 1
            if n > MAX_DIGEST_ITEMS then break end
            out[item] = h
        end
    end
    return out
end

function Strategy:GetDigestHash()
    local d = self:GetDigest()
    local list = {}
    for item, h in pairs(d) do list[#list + 1] = item .. "=" .. h end
    if #list == 0 then return "0" end
    tsort(list)
    return Util.Hash(list)
end

local function Broadcast(kind, rec)
    Send({ t = "SBU", k = kind, r = rec }, "GUILD", nil, "data")
end

local function SendItem(root, item, target)
    local kind, id = item:match("^(%u):(.+)$")
    if (kind == "B" or kind == "F") and root[kind][id] then
        Send({ t = "SBG", k = kind, r = root[kind][id] }, "WHISPER", target, "data")
    end
end

-- SBU { k, r }: a live edit (the editor must be the sender).
local function OnUpdate(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.r) ~= "table" or WireKey(msg.r.by) ~= sender then return end
    if msg.k ~= "B" and msg.k ~= "F" then return end
    if StoreRecord(msg.k, msg.r) then Changed() end
end

-- SBG { k, r }: one item, relayed by anyone in the guild.
local function OnGive(sender, msg, dist)
    if dist ~= "WHISPER" or (msg.k ~= "B" and msg.k ~= "F") or type(msg.r) ~= "table" then return end
    if StoreRecord(msg.k, msg.r) then Changed() end
end

local function OnWant(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.w) ~= "table" or not RateLimit("SBW:" .. sender, 5) then return end
    local root = Root(false)
    if not root then return end
    for i = 1, MAX_DIGEST_ITEMS do
        local item = msg.w[i]
        if item == nil then break end
        if type(item) == "string" and #item <= MAX_ID_LEN + 4 then SendItem(root, item, sender) end
    end
end

local function CleanDigest(d)
    if type(d) ~= "table" then return nil end
    local out, n = {}, 0
    for item, h in pairs(d) do
        n = n + 1
        if n > MAX_DIGEST_ITEMS then return nil end
        if type(item) ~= "string" or #item > MAX_ID_LEN + 4 or not item:find("^[BF]:%w+$") then return nil end
        if type(h) ~= "string" or #h > 8 then return nil end
        out[item] = h
    end
    return out
end

local function OnDigest(sender, msg, dist)
    if dist ~= "GUILD" then return end
    local to = WireKey(msg.to)
    if not to then return end
    if not Util.IsMe(to) then
        if type(msg.h) == "string" then roundSeen[to] = { h = msg.h, at = GetTime() } end
        return
    end
    if GetTime() - answeredAt < ROUND_WINDOW then return end
    local theirs = CleanDigest(msg.d)
    if not theirs then return end
    answeredAt = GetTime()
    local root = Root(true)
    if not root then return end
    local mine = Strategy:GetDigest()
    local want, give = {}, {}
    for item, h in pairs(theirs) do
        if mine[item] ~= h then want[#want + 1] = item end
    end
    for item, h in pairs(mine) do
        if theirs[item] ~= h then give[#give + 1] = item end
    end
    tsort(want)
    tsort(give)
    if #want > 0 then Send({ t = "SBW", w = want }, "WHISPER", sender, "ctrl") end
    for _, item in ipairs(give) do SendItem(root, item, sender) end
end

-- Sync calls this for every HELLO on GUILD (sd = the sender's strategy hash; nil from older clients).
function Strategy:OnHelloDigest(sender, sd)
    if type(sd) ~= "string" or #sd > 8 or type(sender) ~= "string" then return end
    local mine = self:GetDigestHash()
    if mine == "0" or sd == mine then return end
    if not RateLimit("SBDh:" .. sender, ROUND_WINDOW) then return end
    local delay = CanWrite(Util.PlayerKey()) and SBD_DELAY_COUNCIL or SBD_DELAY_MEMBER
    Util.RandomDelay(delay[1], delay[2], function()
        local h = Strategy:GetDigestHash()
        local seen = roundSeen[sender]
        if h == "0" or (seen and GetTime() - seen.at < ROUND_WINDOW and seen.h == h) then return end
        roundSeen[sender] = { h = h, at = GetTime() }
        Send({ t = "SBD", to = sender, h = h, d = Strategy:GetDigest() }, "GUILD", nil, "data")
    end)
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

function Strategy:CanEdit()
    return CanWrite(Util.PlayerKey())
end

function Strategy:CanWrite(key)
    return CanWrite(key)
end

local function Visible(root, rec)
    return rec and not rec.del and Trusted(root, "B", rec)
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
                        if col.t == "x" then rowLabel = cell
                        elseif col.t == "g" and cell.l then rowLabel = cell.l end
                    end
                end
                for ci, col in ipairs(k.c) do
                    if col.t == "p" then
                        local parts = { k.n }
                        if rowLabel then parts[#parts + 1] = rowLabel elseif k.r > 1 then parts[#parts + 1] = "#" .. row end
                        if col.n and #k.c > 1 then parts[#parts + 1] = col.n end
                        out[#out + 1] = { ref = SlotRef(k.id, row, ci), page = pi, pageName = p.n, block = k.id,
                                          blockName = k.n, row = row, col = ci, f = col.f,
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

local function RequireWriter()
    if not CanWrite(Util.PlayerKey()) then return nil, REFUSED end
    local root = Root(true)
    if not root then return nil, "Your guild is not known yet; try again in a moment." end
    return root
end

local function Commit(root, kind, rec)
    local now = Now()
    local clean = kind == "B" and CleanStrategy(rec, now) or CleanFill(rec, now)
    if not clean then return false, kind == "B" and Strategy:Explain(rec) or "invalid assignment data" end
    if not root[kind][clean.id] and CountTable(root[kind]) >= CAP[kind] then
        return false, kind == "B" and "too many strategies (delete some old ones)" or "too many assignments stored"
    end
    root[kind][clean.id] = clean
    Trusted(root, kind, clean)
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
    r.rev, r.by = Now(), Util.PlayerKey() or "x-y"
    local clean = CleanStrategy(r, Now())
    if not clean then return nil, self:Explain(r) end
    return clean
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
        if type(p.no) == "string" and (#p.no > 400 or p.no:find("|")) then
            return where .. ": the notes are " .. #p.no .. " characters (at most 400, no |)"
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

-- Saves a draft (new when draft.id is nil). Returns ok, idOrErr.
function Strategy:SaveStrategy(draft)
    local root, err = RequireWriter()
    if not root then return false, err end
    if type(draft) ~= "table" then return false, "invalid strategy" end
    if not IsBossRef(draft.b) then return false, "Pick a boss." end
    if not CleanText(draft.n, MAX_NAME_LEN) then return false, "Strategy names are 1-32 characters." end
    local cur = draft.id and root.B[draft.id]
    if draft.id and not cur then return false, "unknown strategy" end
    local rec = Copy(draft)
    rec.id = draft.id or NewId()
    rec.rev, rec.by, rec.del = NextRev(cur), Util.PlayerKey(), nil
    local ok, e = Commit(root, "B", rec)
    if not ok then return false, e end
    return true, rec.id
end

function Strategy:DeleteStrategy(id)
    local root, err = RequireWriter()
    if not root then return false, err end
    local cur = type(id) == "string" and root.B[id]
    if not cur or cur.del then return false, "unknown strategy" end
    return (Commit(root, "B", { id = id, rev = NextRev(cur), by = Util.PlayerKey(), del = true }))
end

-- Copies a strategy under a new name (optionally to another boss). Returns ok, newIdOrErr.
function Strategy:CopyStrategy(id, name, bossRef)
    local s = self:GetStrategy(id)
    if not s then return false, "unknown strategy" end
    s.id, s.rev, s.by = nil, nil, nil
    s.n = name or (s.n .. " (copy)"):sub(1, MAX_NAME_LEN)
    if bossRef then s.b = bossRef end
    return self:SaveStrategy(s)
end

---------------------------------------------------------------------------
-- Fills (per raid, per boss)
---------------------------------------------------------------------------

local function FillRec(root, occId, bossRef)
    local rec = root and root.F[FillId(occId, bossRef)]
    if rec and Trusted(root, "F", rec) and rec.o == occId and rec.b == bossRef then return rec end
    return nil
end

-- The fill of (raid, boss): { s = strategy id | nil, a = { [slotRef] = key }, by, rev } (copy) or nil.
function Strategy:GetFill(occId, bossRef)
    local rec = FillRec(Root(false), occId, bossRef)
    return rec and Copy(rec) or nil
end

-- The strategy a raid uses for a boss: the fill's pick, else the only (or first) strategy of that boss.
function Strategy:GetRaidStrategy(occId, bossRef)
    local f = self:GetFill(occId, bossRef)
    local s = f and f.s and self:GetStrategy(f.s)
    if s and s.b == bossRef then return s, f end
    local list = self:GetStrategies(bossRef)
    return list[1], f
end

-- Saves (raid, boss) -> strategy + names. assignments: { [slotRef] = key } (nil keeps the current ones).
function Strategy:SaveFill(occId, bossRef, stratId, assignments)
    local root, err = RequireWriter()
    if not root then return false, err end
    if not IsOccId(occId) or not IsBossRef(bossRef) then return false, "unknown raid or boss" end
    local RP = ns.RaidPlan
    local v = RP and RP:GetRaid(occId)
    local id = FillId(occId, bossRef)
    local cur = root.F[id]
    local t = (v and v.t) or (cur and cur.t) or Now()
    local rec = { id = id, o = occId, b = bossRef, t = t, rev = NextRev(cur), by = Util.PlayerKey(), s = stratId }
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
        if f.s == stratId and f.o ~= exceptOcc and next(f.a) and Trusted(root, "F", f) then
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
    local changed = false
    for id, rec in pairs(root.B) do
        if rec.del and rec.rev < now - TOMBSTONE_DAYS then root.B[id] = nil; changed = true end
    end
    for id, f in pairs(root.F) do
        if f.t < now - FILL_KEEP then root.F[id] = nil; changed = true end
    end
    for sid in pairs(root.L) do
        local s = root.B[sid]
        if not s or s.del then root.L[sid] = nil end
    end
    for k in pairs(root.OK) do
        local kind, id, rev = k:match("^(%u):(.+):(%d+)$")
        local rec = kind and root[kind] and root[kind][id]
        if not rec or tostring(rec.rev) ~= rev then root.OK[k] = nil end
    end
    if changed then Changed() end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Strategy:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("SBU", OnUpdate)
        Comm:Register("SBD", OnDigest)
        Comm:Register("SBW", OnWant)
        Comm:Register("SBG", OnGive)
    end
    -- The raid leaders / council lists decide what is shown: repaint when they change.
    ns:On("CONFIG_UPDATED", Changed)
end

function Strategy:OnLogin()
    local function Daily()
        Strategy:Prune()
        Util.After(DAY / 4, Daily)
    end
    Util.RandomDelay(15, 30, Daily)
end
