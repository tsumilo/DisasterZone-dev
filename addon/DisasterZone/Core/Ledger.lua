if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Ledger.lua", ...) then return end -- DisasterZone: Core/Ledger.lua
-- Award log (council only): auto/manual entries, void/restore, merge rules, a de-duplicated
-- view that is identical on every client, and digest-based sync (A / LW / LG messages).
-- Addendum E §29: single awards (A) go between council members of any kind (a raid leader's picks share
-- the awards of that raid); the log itself (LW / LG digest sync) only between guild-wide council members.
-- Demo mode (Addendum A §20): reads and user writes go to an in-memory table, nothing is sent,
-- and demo awards that older versions saved are purged at login.
-- Dungeon mode (Addendum B §22.2): entries created in dungeon mode inside a 5-man instance carry
-- dg = true (optional wire field; older clients drop it). CountSince ignores them unless asked.
-- Award reasons (Addendum G §40): optional r = reason key (ns.AWARD_REASONS) and rts = the time it was last
-- changed. A changed reason spreads like a void (the greater rts wins) and is part of the digest only once
-- changed, so entries whose reason was never edited digest exactly like DisasterZone 0.5's. Offspec / disenchant /
-- guild bank awards don't count as loot received, and disenchant / bank awards don't mark the item awarded.
-- Raid log (Addendum I §49): optional rid = the raid session the award was made in (every council client in the raid
-- knows the same session). Not part of the digest; a peer's rid fills in a missing one.
-- 1.3: the disenchant / guild bank hand-outs of a master looter outside the council (Loot LT) are recorded by every
-- council client in the group under one id (RecordTargetAward).
local addonName, ns = ...

local Ledger = ns:NewModule("Ledger")
local Util = ns.Util

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local DAY = 86400
local DIGEST_DAYS = 120
local SAME_KIND_WINDOW = 120          -- two auto (or two manual) entries this close = one award
local MANUAL_WINS_AFTER = 6 * 3600    -- an auto entry up to 6h after a manual one is hidden
local MANUAL_WINS_BEFORE = 600        -- ... and up to 10 min before it (award clicked after handing out)
local MAX_DAYS_PER_LW = 30
local MAX_ENTRIES_PER_LG = 20
local MAX_ENTRIES_PER_LG_RECV = 40
local MAX_PENDING_DAYS = 130
local MAX_ID_LEN = 64
local MAX_GUILD_LEN = 128
local MAX_NOTE_LEN = 200
local MAX_REASON_LEN = 8
local MAX_TS = 4102444800             -- year 2100; anything larger is junk
local FUTURE_SLACK = 300              -- a ts / vts from the network more than 5 min ahead of server time is junk
local RAID_SCOPE_AGE = 12 * 3600      -- a raid-scope council member may only touch awards of the last 12 h
local AWARD_LOOKBACK = 120            -- AwardsForDrop: entries up to this long before the drop count as its awards
local AWARD_HORIZON = 6 * 3600        -- ... and up to this long after it
local LEDGER_REQ_STALE = 90           -- a day asked from a peer (LW) is asked again elsewhere after 90 s without LG
local AUTO_SEND_MIN, AUTO_SEND_MAX = 0.5, 3   -- jittered broadcast of an auto entry (cancelled when a peer's arrives)
-- DisasterZone 0.1 (the only version that saved demo awards to the real log) was retired before this server time
-- (2026-09-29 00:00 UTC): the demo purge / merge filter only ever looks at entries older than it, so a real award
-- to a pug or former member that happens to carry a demo name is never touched.
local LEGACY_DEMO_CUTOFF = 1790640000

local LibDeflate = LibStub and LibStub("LibDeflate", true)

local NextVoidTs   -- forward declaration (Recording section)

-- View cache (rebuilt lazily after any change)
local view            -- { all = {...newest first, visible non-void + voided}, byWinner = {[key]={entries}}, awarded = {[key]={[itemID]=true}} }
local pendingLW = {}  -- [senderKey] = {[day]=true} ledger days requested by a council peer

-- Demo isolation (§20)
local demoEntries = {}      -- [id] = entry: the ledger while demo mode is on (in memory only)
local deferredSend = {}     -- [id] = true: real entries recorded while demo was on, sent when it ends
local purgeDone = false
local scopeKey              -- guild key the view / legacy adoption was last computed for
local pendingScope = {}     -- [id] = true: recorded / merged before my guild name was known (tagged, sent later)
local pendingAuto = {}      -- [id] = entry: my auto entries waiting for their jittered broadcast
local ledgerReq = {}        -- [day] = { peer=, at= }: days asked from a peer (LW) and its last progress

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function LedgerDB()
    local db = ns.db
    if not db then return nil end
    if type(db.ledger) ~= "table" then db.ledger = {} end
    return db.ledger
end

local function DemoOn()
    local Demo = ns.Demo
    return (Demo and Demo.IsEnabled and Demo:IsEnabled()) and true or false
end

-- Where reads and user-initiated writes go: the demo table while demo mode is on.
local function ActiveDB()
    if DemoOn() then return demoEntries end
    return LedgerDB()
end

-- DisasterZoneDB is account-wide: every real entry carries g = the guild key it belongs to, and only the
-- current guild's entries are shown, digested or served (an alt in another guild must not mix logs).
local function CurrentGuildKey()
    local Guild = ns.Guild
    return Guild and Guild.GetGuildKey and Guild:GetGuildKey() or nil
end

local function InScope(e, gkey)
    return gkey ~= nil and e.g == gkey
end

-- Network copy of a stored entry (the guild tag stays local; the receiver applies its own).
local function Wire(e)
    local out = {}
    for k, v in pairs(e) do
        if k ~= "g" then out[k] = v end
    end
    return out
end

local function IsInt(n, lo, hi)
    return type(n) == "number" and n == floor(n) and n >= lo and n <= hi
end

local function IsStr(s, maxLen, allowEmpty)
    return type(s) == "string" and #s <= maxLen and (allowEmpty or s ~= "")
end

-- Real council membership (demo mode makes AmICouncil() true for everyone; the real ledger and
-- the network must never rely on that).
local function AmRealCouncil()
    return ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil(true) or false
end

-- May record into the active ledger: real council, or anyone while demo mode is on.
local function CanRecord()
    return DemoOn() or AmRealCouncil()
end

-- Addendum B §22.2: dungeon mode is active and I am inside a 5-man instance.
local function DungeonContext()
    return (Util.IsDungeonModeActive and Util.IsDungeonModeActive() and Util.InPartyInstance
        and Util.InPartyInstance()) and true or false
end

-- rid of a new entry: the raid session running now (Addendum I), else nil.
local function CurrentRaidID()
    local RL = ns.RaidLog
    return RL and RL.GetCurrentID and RL:GetCurrentID() or nil
end

-- dg field of a new entry: an explicit true / false from the caller, else the current context.
local function DgFlag(dg)
    if dg == nil then dg = DungeonContext() end
    return dg and true or nil
end

local function IsCouncilPair(sender)
    return AmRealCouncil() and ns.Guild.IsCouncil and ns.Guild:IsCouncil(sender, true) or false
end

-- Guild-wide council (the GM or on the guild council list), not raid-scope (Addendum E §29).
local function IsGuildCouncil(key)
    local Guild = ns.Guild
    if not (Guild and type(key) == "string") then return false end
    if Guild.IsGuildCouncil then return Guild:IsGuildCouncil(key) and true or false end
    return Guild.IsCouncil and Guild:IsCouncil(key, true) and true or false
end

-- The award log itself (digest requests LW / replies LG) is exchanged between guild-wide council members
-- only, like the manifests (Sync): a raid-scope council member (a raid leader's pick, possibly from
-- another guild) shares the awards of that raid (A) but never receives the guild's history.
local function IsGuildCouncilPair(sender)
    local me = Util.PlayerKey()
    return me ~= nil and IsGuildCouncil(me) and IsGuildCouncil(sender)
end

-- [name] = true for the demo roster's fake names (§20 purge / merge filter).
local function FakeNameSet()
    local Demo = ns.Demo
    local names = Demo and Demo.GetFakeNames and Demo:GetFakeNames()
    local set = {}
    if type(names) == "table" then
        for _, n in ipairs(names) do
            if type(n) == "string" then set[n] = true end
        end
    end
    return set
end

-- A winner key that looks like a demo award: the name part is a demo fake name and the key is
-- not a real guild member. Only decidable once the real roster is known.
local function IsDemoWinner(key, fakeSet)
    if type(key) ~= "string" then return false end
    local name = key:match("^([^%-]+)") or key
    if not fakeSet[name] then return false end
    local Guild = ns.Guild
    if Guild and Guild.IsInGuild and Guild:IsInGuild(key, true) then return false end
    return true
end

local function RosterKnown()
    local Guild = ns.Guild
    return (Guild and Guild.IsReady and Guild:IsReady()) and true or false
end

-- 8 hex digits without relying on %x handling values above 2^31.
local function Hex32(n)
    n = n or 0
    return string.format("%04x%04x", floor(n / 65536) % 65536, n % 65536)
end

local function Checksum(str)
    if LibDeflate and LibDeflate.Adler32 then
        return Hex32(LibDeflate:Adler32(str))
    end
    return Hex32(#str)
end

local function IdName(key)
    local short = Util.ShortName(key) or key or "?"
    return short:sub(1, 24)
end

local function Invalidate()
    view = nil
    Util.Debounce("ledger-updated", 0.2, function() ns:Fire("LEDGER_UPDATED") end)
end

local function ExpandDrop(itemID)
    if ns.ItemDB and ns.ItemDB.ExpandDrop then
        local list = ns.ItemDB:ExpandDrop(itemID)
        if type(list) == "table" then return list end
    end
    return { itemID }
end

-- Nothing is sent while demo mode is on (§20).
local function Send(msg, target, class)
    if DemoOn() then return false end
    if ns.Comm and ns.Comm.Send then
        return ns.Comm:Send(msg, "WHISPER", target, class)
    end
    return false
end

-- Sends a REAL ledger entry to the online council. While demo mode is on it is remembered and
-- sent when demo mode ends.
local function Broadcast(entry)
    if type(entry) ~= "table" then return end
    if DemoOn() then
        deferredSend[entry.id] = true
        return
    end
    if ns.Comm and ns.Comm.SendToCouncil and AmRealCouncil() and InScope(entry, CurrentGuildKey()) then
        ns.Comm:SendToCouncil({ t = "A", e = Wire(entry) }, "ctrl")
    end
end

local function FlushDeferred()
    local db = LedgerDB()
    local ids = deferredSend
    deferredSend = {}
    if not db or DemoOn() then return end
    for id in pairs(ids) do
        local e = db[id]
        if type(e) == "table" then Broadcast(e) end
    end
end

-- The next edit timestamp after `prev` (a vts / rts): strictly increasing so a quick void + restore still wins on
-- every peer, never past MAX_TS, and a time poisoned into the future (a forged A) is treated as "now".
local function NextTs(prev)
    local now = GetServerTime()
    return min(MAX_TS, max(now, min(tonumber(prev) or 0, now) + 1))
end

NextVoidTs = function(e)
    return NextTs(e.vts)
end

-- A reason key from the network: known keys, and (so digests keep matching a newer version) any short lowercase
-- word. nil for no reason.
local function CleanReason(r)
    if type(r) ~= "string" or r == "" or #r > MAX_REASON_LEN or not r:find("^%l+$") then return nil end
    return r
end

-- The reason's rules (ns.AWARD_REASON); an unknown or missing reason counts and owns like a normal award.
local function ReasonCounts(e)
    local r = ns.AWARD_REASON and e.r and ns.AWARD_REASON[e.r]
    return not r or r.counts
end

local function ReasonOwns(e)
    local r = ns.AWARD_REASON and e.r and ns.AWARD_REASON[e.r]
    return not r or r.owns
end

-- Validates an (untrusted) entry and returns a clean copy with known fields only.
local function Clean(e)
    if type(e) ~= "table" then return nil, "not a table" end
    if not IsStr(e.id, MAX_ID_LEN) then return nil, "bad id" end
    if not IsInt(e.i, 1, 200000) then return nil, "bad item" end
    if not IsStr(e.w, MAX_ID_LEN) then return nil, "bad winner" end
    if not IsStr(e.by, MAX_ID_LEN) then return nil, "bad recorder" end
    if not IsInt(e.ts, 1, MAX_TS) then return nil, "bad ts" end
    if e.s ~= "a" and e.s ~= "m" then return nil, "bad source" end
    if e.b ~= nil and not IsStr(e.b, MAX_ID_LEN, true) then return nil, "bad boss" end
    if e.n ~= nil and not IsStr(e.n, MAX_NOTE_LEN, true) then return nil, "bad note" end
    if e.vd ~= nil and type(e.vd) ~= "boolean" then return nil, "bad void flag" end
    if e.vts ~= nil and not IsInt(e.vts, 0, MAX_TS) then return nil, "bad void ts" end
    if e.dg ~= nil and type(e.dg) ~= "boolean" then return nil, "bad dungeon flag" end
    if e.rts ~= nil and not IsInt(e.rts, 0, MAX_TS) then return nil, "bad reason ts" end
    if e.rid ~= nil and not (IsStr(e.rid, MAX_ID_LEN) and not e.rid:find("[%c|]")) then return nil, "bad raid id" end
    if e.w:find("[%c|]") or e.by:find("[%c|]") then return nil, "bad names" end
    local w = Util.NormalizeName(e.w)
    local by = Util.NormalizeName(e.by)
    if not w or not by then return nil, "bad names" end
    -- Free text from peers is shown in tooltips: no UI escape codes (|T textures, |H links, colours) or controls.
    local n = e.n
    if n ~= nil then
        n = n:gsub("[%c|]", " ")
        if n:find("^%s*$") then n = nil end
    end
    local b = e.b and (e.b:gsub("[%c|]", "")) or ""
    return {
        id = e.id, i = e.i, w = w, b = b, ts = e.ts, by = by, s = e.s,
        n = n,
        vd = e.vd and true or nil,
        vts = e.vts,
        dg = e.dg and true or nil,                      -- 5-man dungeon loot (Addendum B)
        r = CleanReason(e.r),                           -- award reason (Addendum G)
        rts = e.rts,
        rid = e.rid,                                    -- raid session (Addendum I)
        g = IsStr(e.g, MAX_GUILD_LEN) and e.g or nil,   -- local guild tag (Merge replaces it)
    }
end

local function OrderAsc(a, b)
    if a.ts ~= b.ts then return a.ts < b.ts end
    return a.id < b.id
end

local function OrderDesc(a, b)
    if a.ts ~= b.ts then return a.ts > b.ts end
    return a.id > b.id
end

---------------------------------------------------------------------------
-- De-duplicated view. Depends only on entry contents, so every client that holds the
-- same entries shows exactly the same awards.
--   Within each (winner, item) group of non-void entries:
--   1. same-kind entries (auto/auto or manual/manual) within 120s of the last kept one are
--      hidden (sorted by ts, then id: the earliest / smallest id wins);
--   2. an auto entry from 10 min before to 6h after a kept manual entry is hidden.
---------------------------------------------------------------------------

local function BuildView()
    local demo = DemoOn()
    local db = ActiveDB() or {}
    local gkey = CurrentGuildKey()
    local groups, all = {}, {}   -- groups[winner][itemID] = { entries }
    for _, e in pairs(db) do
        if type(e) == "table" and type(e.ts) == "number" and type(e.w) == "string" and type(e.i) == "number"
            and (demo or InScope(e, gkey)) then
            if e.vd then
                all[#all + 1] = e
            else
                local byItem = groups[e.w]
                if not byItem then
                    byItem = {}
                    groups[e.w] = byItem
                end
                local g = byItem[e.i]
                if not g then
                    g = {}
                    byItem[e.i] = g
                end
                g[#g + 1] = e
            end
        end
    end

    for _, byItem in pairs(groups) do
        for _, g in pairs(byItem) do
            tsort(g, OrderAsc)
            local manuals, autos = {}, {}
            local lastManual, lastAuto
            for _, e in ipairs(g) do
                if e.s == "m" then
                    if not (lastManual and e.ts - lastManual.ts <= SAME_KIND_WINDOW) then
                        manuals[#manuals + 1] = e
                        lastManual = e
                    end
                else
                    if not (lastAuto and e.ts - lastAuto.ts <= SAME_KIND_WINDOW) then
                        autos[#autos + 1] = e
                        lastAuto = e
                    end
                end
            end
            for _, m in ipairs(manuals) do
                all[#all + 1] = m
            end
            for _, a in ipairs(autos) do
                local hidden = false
                for _, m in ipairs(manuals) do
                    if a.ts >= m.ts - MANUAL_WINS_BEFORE and a.ts <= m.ts + MANUAL_WINS_AFTER then
                        hidden = true
                        break
                    end
                end
                if not hidden then all[#all + 1] = a end
            end
        end
    end

    tsort(all, OrderDesc)
    local byWinner, awarded = {}, {}
    for _, e in ipairs(all) do
        if not e.vd then
            local list = byWinner[e.w]
            if not list then
                list = {}
                byWinner[e.w] = list
                awarded[e.w] = {}
            end
            list[#list + 1] = e
            if ReasonOwns(e) then
                local set = awarded[e.w]
                set[e.i] = true
                for _, id in ipairs(ExpandDrop(e.i)) do
                    set[id] = true
                end
            end
        end
    end
    view = { all = all, byWinner = byWinner, awarded = awarded, gkey = gkey, demo = demo }
    return view
end

local UpdateScope   -- forward declaration (Scope section)

-- The cached view is only valid for the guild key it was built for: right after a login GetGuildInfo can be
-- nil for a few seconds, and a view built then (nothing in scope) must not outlive it.
local function GetView()
    if view and (view.demo ~= DemoOn() or (not view.demo and view.gkey ~= CurrentGuildKey())) then
        view = nil
        if CurrentGuildKey() ~= scopeKey then Util.Debounce("ledger-scope", 0, function() UpdateScope() end) end
    end
    return view or BuildView()
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

-- The guild key for a new or merged entry: the current one, or false while I am in a guild whose name the client
-- has not told me yet (the entry is then kept untagged and adopted by UpdateScope). nil = no guild at all.
local function EntryGuildKey()
    local gkey = CurrentGuildKey()
    if gkey then return gkey end
    if IsInGuild() then return false end
    return nil
end

-- Every council member in the raid records the same loot line: each one broadcasts after a short random delay,
-- and a peer's entry for the same (winner, item, moment) arriving first cancels it (Merge).
local function ScheduleAutoBroadcast(entry)
    if DemoOn() then
        Broadcast(entry)   -- (remembered and sent when demo mode ends)
        return
    end
    local id = entry.id
    pendingAuto[id] = entry
    Util.RandomDelay(AUTO_SEND_MIN, AUTO_SEND_MAX, function()
        if pendingAuto[id] ~= entry then return end
        pendingAuto[id] = nil
        Broadcast(entry)
    end)
end

-- A peer's auto entry for the same loot line that wins the view's de-dupe over mine (earlier, or the same id): my
-- own pending broadcast is not needed any more. A later one does not cancel mine, so every client still ends up
-- with the earliest entry of the line (the one every view shows).
local function CancelAutoFor(e)
    if e.s ~= "a" then return end
    for id, pe in pairs(pendingAuto) do
        if pe.w == e.w and pe.i == e.i and math.abs((pe.ts or 0) - (e.ts or 0)) <= SAME_KIND_WINDOW
            and (e.ts < pe.ts or (e.ts == pe.ts and e.id <= pe.id)) then
            pendingAuto[id] = nil
        end
    end
end

-- A real loot message: always recorded into the REAL ledger (real council only), also while demo
-- mode is on (then it is sent to the council once demo mode ends).
-- dg (optional): true = 5-man dungeon loot; nil = derived from the current dungeon-mode context.
function Ledger:RecordAuto(itemID, winnerKey, bossKey, dg)
    if not AmRealCouncil() then return nil end
    local db = LedgerDB()
    local me = Util.PlayerKey()
    winnerKey = Util.NormalizeName(winnerKey)
    if not db or not me or not winnerKey or not IsInt(itemID, 1, 200000) then return nil end
    local gkey = EntryGuildKey()
    if gkey == nil then return nil end
    local ts = GetServerTime()
    local id = ("a" .. ts .. IdName(winnerKey) .. itemID):sub(1, MAX_ID_LEN)
    if db[id] then return db[id] end   -- same loot line seen twice / already received from a peer
    local entry = {
        id = id, i = itemID, w = winnerKey, ts = ts, by = me, s = "a",
        b = IsStr(bossKey, MAX_ID_LEN, true) and bossKey or "", g = gkey or nil, dg = DgFlag(dg),
        rid = CurrentRaidID(),
    }
    db[id] = entry
    Invalidate()
    if gkey then
        ScheduleAutoBroadcast(entry)
    else
        pendingScope[id] = true   -- tagged and sent once the guild name is known
    end
    return entry
end

-- Manual award. In demo mode it goes to the in-memory demo ledger and is never sent.
-- dg (optional): true / false = 5-man dungeon loot or not; nil = derived from the dungeon-mode context.
-- reason (optional): an ns.AWARD_REASONS key.
function Ledger:Award(itemID, winnerKey, bossKey, note, dg, reason)
    if not CanRecord() then
        ns:Print("Only loot council members can record awards.")
        return nil
    end
    local demo = DemoOn()
    local db = ActiveDB()
    local me = Util.PlayerKey()
    itemID = tonumber(itemID)
    winnerKey = Util.NormalizeName(winnerKey)
    if not db or not me or not winnerKey or not IsInt(itemID, 1, 200000) then return nil end
    if type(note) == "string" then
        note = note:gsub("^%s+", ""):gsub("%s+$", "")
        if note == "" then note = nil else note = note:sub(1, MAX_NOTE_LEN) end
    else
        note = nil
    end
    local ts = GetServerTime()
    local base = ("m" .. ts .. IdName(me) .. itemID):sub(1, MAX_ID_LEN - 4)
    local id, n = base, 1
    while db[id] do
        n = n + 1
        id = base .. "-" .. n
    end
    local gkey = nil
    if not demo then gkey = EntryGuildKey() end   -- (false = in a guild whose name is not known yet)
    local entry = {
        id = id, i = itemID, w = winnerKey, ts = ts, by = me, s = "m", n = note,
        b = IsStr(bossKey, MAX_ID_LEN, true) and bossKey or "",
        g = gkey or nil,
        dg = DgFlag(dg),
        r = ns.AWARD_REASON[reason] and reason or nil,
        rid = not demo and CurrentRaidID() or nil,
    }
    db[id] = entry
    Invalidate()
    if gkey == false then
        pendingScope[id] = true   -- the guild name is not known yet: tagged and sent once it is
    elseif not demo then
        Broadcast(entry)
    end
    return entry
end

-- Roll awards (Addendum A §19.1 step 3) go to the REAL ledger, also while demo mode is on. The id
-- depends only on the session and the winner, so every council client that sees the award (its own
-- click, or the RW of a non-council master looter) writes the very same entry.
local function RollAwardID(sessionID, winnerKey)
    return ("m" .. sessionID .. "-" .. IdName(winnerKey)):sub(1, MAX_ID_LEN)
end

-- broadcast: true for the awarding client (receivers of RW record it themselves).
-- dg: true / false = a party (dungeon mode) roll or not, so every council client writes the same
-- entry; nil = derived from the dungeon-mode context.
-- reason (optional): the award reason the awarder chose (RW r), the same on every council client.
function Ledger:RecordRollAward(sessionID, itemID, winnerKey, bossKey, note, byKey, ts, broadcast, dg, reason)
    if not AmRealCouncil() or not IsStr(sessionID, MAX_ID_LEN) then return nil end
    local db = LedgerDB()
    local gkey = EntryGuildKey()
    winnerKey = Util.NormalizeName(winnerKey)
    byKey = Util.NormalizeName(byKey) or Util.PlayerKey()
    itemID = tonumber(itemID)
    if not db or gkey == nil or not winnerKey or not byKey or not IsInt(itemID, 1, 200000) then return nil end
    reason = ns.AWARD_REASON[reason] and reason or nil
    local id = RollAwardID(sessionID, winnerKey)
    local cur = db[id]
    if type(cur) == "table" then
        if cur.i == itemID and cur.w == winnerKey then
            if reason and not cur.r then   -- (an older client's copy of this award, without its reason)
                cur.r = reason
                Invalidate()
            end
            return cur
        end
        -- Someone pre-seeded this roll's id with other content: the RW decides what it records.
        ns:Debug("Ledger: roll award %s had other content (%s / %s); replaced", id, tostring(cur.w), tostring(cur.i))
    end
    local now = GetServerTime()
    ts = tonumber(ts)
    -- The award time comes from the RW sender: a time far in the past or in the future is not believed.
    if not IsInt(ts, 1, MAX_TS) or ts > now + FUTURE_SLACK or ts < now - DIGEST_DAYS * DAY then ts = now end
    if type(note) == "string" and note ~= "" then note = note:sub(1, MAX_NOTE_LEN) else note = nil end
    local entry = {
        id = id, i = itemID, w = winnerKey, ts = ts, by = byKey, s = "m", n = note,
        b = IsStr(bossKey, MAX_ID_LEN, true) and bossKey or "", g = gkey or nil, dg = DgFlag(dg), r = reason,
        rid = CurrentRaidID(),
    }
    db[id] = entry
    Invalidate()
    if gkey == false then
        pendingScope[id] = broadcast and true or "quiet"
    elseif broadcast then
        Broadcast(entry)
    end
    return entry
end

-- 1.3: a master looter outside the council gave itemID to the disenchanter / guild bank character (Loot LT): every
-- council client in the group records the same manual award with that reason (the id is built like Ledger:Award's,
-- from the master looter, its time and the item), so the loot line's auto entry is hidden and the hand-out does not
-- count as loot won. Not broadcast: each council client in the group records it, the others get it by sync.
function Ledger:RecordTargetAward(itemID, winnerKey, bossKey, reason, byKey, ts)
    if not AmRealCouncil() or (reason ~= "de" and reason ~= "bank") or not ns.AWARD_REASON[reason] then return nil end
    local db = LedgerDB()
    local gkey = EntryGuildKey()
    winnerKey, byKey = Util.NormalizeName(winnerKey), Util.NormalizeName(byKey)
    itemID = tonumber(itemID)
    if not db or gkey == nil or not winnerKey or not byKey or not IsInt(itemID, 1, 200000) then return nil end
    local now = GetServerTime()
    ts = tonumber(ts)
    if not IsInt(ts, 1, MAX_TS) or ts > now + FUTURE_SLACK or ts < now - DAY then ts = now end
    local base = ("m" .. ts .. IdName(byKey) .. itemID):sub(1, MAX_ID_LEN - 4)
    local id, n = base, 1
    while db[id] do
        local cur = db[id]
        if type(cur) == "table" and cur.i == itemID and cur.w == winnerKey then return cur end   -- (recorded already)
        n = n + 1
        id = base .. "-" .. n
    end
    local entry = {
        id = id, i = itemID, w = winnerKey, ts = ts, by = byKey, s = "m",
        b = IsStr(bossKey, MAX_ID_LEN, true) and bossKey or "", g = gkey or nil, dg = DgFlag(nil), r = reason,
        rid = CurrentRaidID(),
    }
    db[id] = entry
    if gkey == false then pendingScope[id] = "quiet" end
    Invalidate()
    return entry
end

-- Voids the roll award of sessionID to winnerKey (lost a conflicting award). Returns true if changed.
function Ledger:VoidRollAward(sessionID, winnerKey)
    if not AmRealCouncil() or not IsStr(sessionID, MAX_ID_LEN) then return false end
    local db = LedgerDB()
    winnerKey = Util.NormalizeName(winnerKey)
    local e = db and winnerKey and db[RollAwardID(sessionID, winnerKey)]
    if type(e) ~= "table" or e.vd then return false end
    e.vd = true
    e.vts = NextVoidTs(e)
    Invalidate()
    Broadcast(e)
    return true
end

-- Entries that stand for the same award as an auto entry: every council member records the loot line under its
-- own id (one server second apart at most), so voiding or restoring one of them does it for all of them.
local function AutoCluster(db, e, gkey, demo)
    local list = { e }
    if e.s ~= "a" then return list end
    for _, o in pairs(db) do
        if o ~= e and type(o) == "table" and o.s == "a" and o.w == e.w and o.i == e.i and type(o.ts) == "number"
            and math.abs(o.ts - (e.ts or 0)) <= SAME_KIND_WINDOW and (demo or InScope(o, gkey)) then
            list[#list + 1] = o
        end
    end
    return list
end

local function SetVoid(list, value, demo)
    local changed = false
    for _, x in ipairs(list) do
        if x.vd ~= value then
            x.vd = value
            x.vts = NextVoidTs(x)
            changed = true
        end
    end
    if changed then
        Invalidate()
        if not demo then
            for _, x in ipairs(list) do Broadcast(x) end
        end
    end
    return changed
end

function Ledger:Void(id, voided)
    if not CanRecord() then return false end
    local demo = DemoOn()
    local db = ActiveDB()
    local e = db and type(id) == "string" and db[id]
    if type(e) ~= "table" then return false end
    local value = voided and true or nil
    if e.vd == value then return false end
    -- 1.3.5: a voided award of a prized item leaves its public history (and its cooldown / queue / pair rules)
    local P = ns.Prized
    if value and P and P.IsPrized and P:IsPrized(e.i) and P.VoidGiven then P:VoidGiven(e.i, e.w, e.ts) end
    return SetVoid(AutoCluster(db, e, CurrentGuildKey(), demo), value, demo)
end

-- Addendum G §40: changes the award reason of an entry (reason nil = none). Like a void, it covers the other
-- council members' copies of an auto entry's loot line, and the newer change (rts) wins on every peer.
function Ledger:SetReason(id, reason)
    if not CanRecord() then return false end
    if reason ~= nil and not ns.AWARD_REASON[reason] then return false end
    local demo = DemoOn()
    local db = ActiveDB()
    local e = db and type(id) == "string" and db[id]
    if type(e) ~= "table" or e.r == reason then return false end
    local list = AutoCluster(db, e, CurrentGuildKey(), demo)
    for _, x in ipairs(list) do
        x.r = reason
        x.rts = NextTs(x.rts)
    end
    Invalidate()
    if not demo then
        for _, x in ipairs(list) do Broadcast(x) end
    end
    return true
end

-- DisasterZone 0.5: voids every visible auto entry of winnerKey + itemID recorded around ts (the loot line of a hand-out
-- that the council says belongs to someone else). Returns true if anything changed.
function Ledger:VoidAutoNear(winnerKey, itemID, ts)
    if not CanRecord() then return false end
    local demo = DemoOn()
    local db = ActiveDB()
    winnerKey = Util.NormalizeName(winnerKey)
    itemID, ts = tonumber(itemID), tonumber(ts)
    if not db or not winnerKey or not itemID or not ts then return false end
    local gkey = CurrentGuildKey()
    local list = {}
    for _, e in pairs(db) do
        if type(e) == "table" and e.s == "a" and not e.vd and e.w == winnerKey and e.i == itemID
            and type(e.ts) == "number" and math.abs(e.ts - ts) <= SAME_KIND_WINDOW + 600 and (demo or InScope(e, gkey)) then
            list[#list + 1] = e
        end
    end
    return SetVoid(list, true, demo)
end

function Ledger:GetEntry(id)
    local db = ActiveDB()
    return db and type(id) == "string" and db[id] or nil
end

-- True while reads/writes use the in-memory demo ledger (§20).
function Ledger:IsDemo()
    return DemoOn()
end

-- Union by id. For an id we already hold, only the void state can change:
-- the side with the greater vts wins; on a tie the voided side wins. The dungeon flag (dg) is only
-- ever added (an older client relays entries without it).
-- Network data always goes to the REAL ledger, also while demo mode is on.
-- Network entries: a ts or vts more than FUTURE_SLACK ahead of server time is junk (a forged or broken sender).
local function PlausibleTimes(e, now)
    if type(e) ~= "table" then return false end
    local ts = tonumber(e.ts)
    if ts and ts > now + FUTURE_SLACK then return false end
    if e.vts ~= nil and (type(e.vts) ~= "number" or e.vts > now + FUTURE_SLACK) then return false end
    if e.rts ~= nil and (type(e.rts) ~= "number" or e.rts > now + FUTURE_SLACK) then return false end
    return true
end

-- A roll award's id ends in "-<winner>" (RollAwardID): an entry under a roll id naming someone else is a squatter.
local function SquattedRollID(e)
    -- "m" .. <session id "Name-<server time>-<n>"> .. "-" .. <winner> (manual awards are "m<digits>...")
    if #e.id >= MAX_ID_LEN or not e.id:find("^m%D.-%-%d+%-%d+%-") then return false end
    local suffix = "-" .. IdName(e.w)
    return e.id:sub(-#suffix) ~= suffix
end

function Ledger:Merge(entry, fromKey)
    local e, err = Clean(entry)
    if not e then
        ns:Debug("Ledger: rejected entry from %s: %s", tostring(fromKey), tostring(err))
        return false
    end
    local now = GetServerTime()
    if not PlausibleTimes(entry, now) then
        ns:Debug("Ledger: rejected entry %s from %s: time in the future", e.id, tostring(fromKey))
        return false
    end
    if SquattedRollID(e) then
        ns:Debug("Ledger: rejected entry %s from %s: roll id of another winner", e.id, tostring(fromKey))
        return false
    end
    -- Demo awards saved and synced by DisasterZone 0.1 must not come back through sync (§20).
    if e.ts < LEGACY_DEMO_CUTOFF and RosterKnown() and IsDemoWinner(e.w, FakeNameSet()) then
        ns:Debug("Ledger: rejected demo award %s from %s", e.id, tostring(fromKey))
        return false
    end
    local db = LedgerDB()
    local gkey = EntryGuildKey()
    if not db or gkey == nil then return false end
    CancelAutoFor(e)
    -- entries from a peer belong to the guild we share with it (untagged until my guild name is known)
    e.g = gkey or nil
    local cur = db[e.id]
    if type(cur) ~= "table" then
        db[e.id] = e
        if gkey == false then pendingScope[e.id] = "quiet" end
        Invalidate()
        return true
    end
    local changed = false
    if e.dg and not cur.dg then
        cur.dg = true
        changed = true
    end
    if e.rid and not cur.rid then
        cur.rid = e.rid
        changed = true
    end
    local cv, ev = cur.vts or 0, e.vts or 0
    -- A stored vts in the future was poisoned by a forged A (DisasterZone 0.4 took any vts): a sane one replaces it.
    if cv > now + FUTURE_SLACK then cv = -1 end
    local take = (ev > cv) or (ev == cv and e.vd and not cur.vd)
    if take and not (cur.vd == e.vd and cur.vts == e.vts) then
        cur.vd = e.vd
        cur.vts = e.vts
        changed = true
    end
    -- The reason (Addendum G): the newer change wins; on a tie a missing reason is filled in, and two different
    -- ones settle on the smaller key, so every peer ends up with the same.
    local cr, er = cur.rts or 0, e.rts or 0
    if cr > now + FUTURE_SLACK then cr = -1 end
    local takeR = (er > cr) or (er == cr and e.r ~= nil and e.r ~= cur.r and (cur.r == nil or e.r < cur.r))
    if takeR and not (cur.r == e.r and cur.rts == e.rts) then
        cur.r = e.r
        cur.rts = e.rts
        changed = true
    end
    if changed then Invalidate() end
    return changed
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------

-- filter = { player = key, includeVoid = bool, since = ts, excludeDungeon = bool, dungeonOnly = bool }.
-- Newest first. Returned tables are the stored entries: treat them as read-only. Voided ones have
-- vd = true; 5-man dungeon loot has dg = true.
-- The award log as the viewer may see it: all of it for the guild council (and demo mode); for council of one raid
-- only (its leader or picks, Addendum E), the awards of that raid (its raid session, else since I joined the raid).
function Ledger:GetVisibleEntries(filter)
    local all = self:GetEntries(filter)
    local Guild = ns.Guild
    local me = Util.PlayerKey()
    local demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    if demo or not Guild or (me and Guild.IsGuildCouncil and Guild:IsGuildCouncil(me)) then return all end
    local GR = ns.GroupRules
    local s = GR and GR.GetSession and GR:GetSession()
    local since = s and s.at or (Guild.GetRaidSince and Guild:GetRaidSince())
    if not since then return {} end
    local out = {}
    for _, e in ipairs(all) do
        if (s and e.rid == s.id) or (tonumber(e.ts) or 0) >= since then out[#out + 1] = e end
    end
    return out
end

function Ledger:GetEntries(filter)
    filter = type(filter) == "table" and filter or {}
    local player = filter.player and Util.NormalizeName(filter.player)
    local since = tonumber(filter.since)
    local out = {}
    for _, e in ipairs(GetView().all) do
        if (filter.includeVoid or not e.vd)
            and (not player or e.w == player)
            and (not since or e.ts >= since)
            and not (filter.excludeDungeon and e.dg)
            and not (filter.dungeonOnly and not e.dg) then
            out[#out + 1] = e
        end
    end
    return out
end

-- 1.3.5: a token that is a new table whenever the log changes (Attendance's dry streaks cache against it).
function Ledger:GetViewToken()
    return GetView()
end

function Ledger:HasAward(key, wantedItemID)
    if not key or not wantedItemID then return false end
    local set = GetView().awarded[key]
    return set and set[wantedItemID] and true or false
end

-- Awards to key since ts ("won N tonight"). 5-man dungeon loot (dg) is not counted unless
-- includeDungeon is true; offspec / disenchant / guild bank awards (Addendum G) never are.
function Ledger:CountSince(key, ts, includeDungeon)
    local list = key and GetView().byWinner[key]
    if not list then return 0 end
    ts = tonumber(ts) or 0
    local n = 0
    for _, e in ipairs(list) do
        if e.ts >= ts and (includeDungeon or not e.dg) and ReasonCounts(e) then n = n + 1 end
    end
    return n
end

-- DisasterZone 0.5: the visible (non-void) awards that belong to a drop: { [itemID] = { entries, oldest first } }.
-- An award belongs to the drop when it was recorded from AWARD_LOOKBACK before the drop to AWARD_HORIZON after it,
-- for the same boss (either side "" matches), and - when the drop carries the group snapshot taken when it was
-- seen (drop.grp, local only) - it was recorded by me, or its recorder or winner was in that group. The award
-- A messages of every guild council member reach every other one, so without that snapshot another raid group's
-- award of the same item from the same boss would pass for this drop's (split Karazhan groups).
function Ledger:AwardsForDrop(drop)
    local byItem = {}
    if type(drop) ~= "table" then return byItem end
    local dts = tonumber(drop.ts) or GetServerTime()
    local boss = type(drop.b) == "string" and drop.b or ""
    local grp = type(drop.grp) == "table" and drop.grp or nil
    local me = Util.PlayerKey()
    for _, e in ipairs(GetView().all) do
        if not e.vd and e.i and e.ts >= dts - AWARD_LOOKBACK and e.ts <= dts + AWARD_HORIZON then
            local eb = type(e.b) == "string" and e.b or ""
            if (boss == "" or eb == "" or eb == boss)
                and (not grp or e.by == me or grp[e.by] or grp[e.w]) then
                local list = byItem[e.i]
                if not list then
                    list = {}
                    byItem[e.i] = list
                end
                list[#list + 1] = e
            end
        end
    end
    for _, list in pairs(byItem) do tsort(list, OrderAsc) end
    return byItem
end

-- true while new entries get dg = true (dungeon mode active inside a 5-man instance).
function Ledger:IsDungeonContext()
    return DungeonContext()
end

---------------------------------------------------------------------------
-- Digest sync
---------------------------------------------------------------------------

function Ledger:GetDigest()
    local db = LedgerDB()
    local out = {}
    if not db then return out end
    local minDay = floor(GetServerTime() / DAY) - DIGEST_DAYS
    local gkey = CurrentGuildKey()
    local perDay = {}
    for id, e in pairs(db) do
        if type(e) == "table" and type(e.ts) == "number" and InScope(e, gkey) then
            local day = floor(e.ts / DAY)
            if day >= minDay then
                local list = perDay[day]
                if not list then
                    list = {}
                    perDay[day] = list
                end
                local d = e.vd and (id .. "v" .. tostring(floor(e.vts or 0))) or id
                -- A changed reason (rts) is part of the digest; a reason set when the award was made is not.
                if e.rts then d = d .. "r" .. tostring(e.r or "") .. tostring(floor(e.rts)) end
                list[#list + 1] = d
            end
        end
    end
    for day, list in pairs(perDay) do
        tsort(list)
        out[day] = Checksum(tconcat(list, "\n"))
    end
    return out
end

-- Requests the days where X's digest differs from ours. Days X has no entries for are skipped:
-- X asks us for those itself when it processes our digest (H/M carry both sides' digests).
function Ledger:SyncFromDigest(X, digest)
    if DemoOn() or type(X) ~= "string" or type(digest) ~= "table" or not IsGuildCouncilPair(X) then return end
    local mine = self:GetDigest()
    local today = floor(GetServerTime() / DAY)
    local now = GetTime()
    local Guild = ns.Guild
    local days, seen = {}, 0
    for day, h in pairs(digest) do
        seen = seen + 1
        if seen > 400 then break end   -- untrusted table size guard
        if IsInt(day, today - DIGEST_DAYS, today + 1) and IsStr(h, 16) and mine[day] ~= h then
            -- Asked from another peer that is still sending (or was asked moments ago): not again from this one,
            -- or a council member catching up gets the whole history once per online council peer.
            local r = ledgerReq[day]
            local busy = r and r.peer ~= X and now - r.at < LEDGER_REQ_STALE
                and (not Guild or not Guild.IsOnline or Guild:IsOnline(r.peer, true))
            if not busy then
                ledgerReq[day] = { peer = X, at = now }
                days[#days + 1] = day
            end
        end
    end
    if #days == 0 then return end
    tsort(days, function(a, b) return a > b end)
    for i = 1, #days, MAX_DAYS_PER_LW do
        local batch = {}
        for j = i, min(i + MAX_DAYS_PER_LW - 1, #days) do
            batch[#batch + 1] = days[j]
        end
        Send({ t = "LW", d = batch }, X, "ctrl")
    end
end

local function FlushLedgerWant(sender)
    local days = pendingLW[sender]
    pendingLW[sender] = nil
    local db = LedgerDB()
    if not days or not db or not IsGuildCouncilPair(sender) then return end
    local gkey = CurrentGuildKey()
    local list = {}
    for _, e in pairs(db) do
        if type(e) == "table" and type(e.ts) == "number" and days[floor(e.ts / DAY)] and InScope(e, gkey) then
            list[#list + 1] = Wire(e)
        end
    end
    tsort(list, OrderDesc)   -- newest first: what "won tonight" / "already awarded" read arrives first
    for i = 1, #list, MAX_ENTRIES_PER_LG do
        local batch = {}
        for j = i, min(i + MAX_ENTRIES_PER_LG - 1, #list) do
            batch[#batch + 1] = list[j]
        end
        Send({ t = "LG", e = batch }, sender, "data")
    end
end

-- A {e}: WHISPER only (SPEC: A is whispered to the council; RAID would let any group member's leader of another guild
-- in). A raid-scope council member (a raid leader or their pick, Addendum E §29) shares the awards of its raid: it
-- may add entries under its own name and void / restore entries of the last 12 h, nothing older.
local function OnAward(sender, msg, dist)
    if dist ~= "WHISPER" or not IsCouncilPair(sender) or type(msg) ~= "table" or type(msg.e) ~= "table" then return end
    if not IsGuildCouncil(sender) then
        local e = msg.e
        local db = LedgerDB()
        local cur = type(e.id) == "string" and db and db[e.id] or nil
        local now = GetServerTime()
        local ts = type(cur) == "table" and tonumber(cur.ts) or tonumber(e.ts)
        if not ts or ts < now - RAID_SCOPE_AGE then
            ns:Debug("Ledger: A from raid-scope %s about an old award ignored", sender)
            return
        end
        if type(cur) ~= "table" and Util.NormalizeName(e.by) ~= sender then
            ns:Debug("Ledger: A from raid-scope %s recorded by someone else ignored", sender)
            return
        end
    end
    Ledger:Merge(msg.e, sender)
end

local function OnLedgerWant(sender, msg)
    if DemoOn() then return end   -- nothing is sent in demo mode; the peer asks again later
    if not IsGuildCouncilPair(sender) or type(msg) ~= "table" or type(msg.d) ~= "table" then return end
    local set = pendingLW[sender] or {}
    local count = 0
    for _ in pairs(set) do count = count + 1 end
    for k = 1, MAX_DAYS_PER_LW do
        local day = msg.d[k]
        if day == nil or count >= MAX_PENDING_DAYS then break end
        if IsInt(day, 0, 1000000) and not set[day] then
            set[day] = true
            count = count + 1
        end
    end
    pendingLW[sender] = set
    -- coalesce repeated requests from the same peer into one reply burst
    Util.Debounce("ledger-lw:" .. sender, 1, function() FlushLedgerWant(sender) end)
end

local function OnLedger(sender, msg)
    if not IsGuildCouncilPair(sender) or type(msg) ~= "table" or type(msg.e) ~= "table" then return end
    local now = GetTime()
    for _, r in pairs(ledgerReq) do
        if r.peer == sender then r.at = now end   -- progress: the days asked from this peer are still coming
    end
    for k = 1, MAX_ENTRIES_PER_LG_RECV do
        local e = msg.e[k]
        if e == nil then break end
        Ledger:Merge(e, sender)
    end
end

---------------------------------------------------------------------------
-- Demo isolation (§20)
---------------------------------------------------------------------------

-- Removes awards to demo fake members from the saved ledger (DisasterZone 0.1 wrote them there).
-- Needs the real guild roster, so it runs once the roster is ready (or, for a character without
-- a guild, a while after login). Returns the number removed.
function Ledger:PurgeDemoAwards()
    local db = LedgerDB()
    if not db then return 0 end
    if not RosterKnown() and IsInGuild() then return 0 end
    purgeDone = true
    local fakeSet = FakeNameSet()
    if next(fakeSet) == nil then return 0 end
    local removed = 0
    for id, e in pairs(db) do
        if type(e) == "table" and (tonumber(e.ts) or 0) < LEGACY_DEMO_CUTOFF and IsDemoWinner(e.w, fakeSet) then
            db[id] = nil
            deferredSend[id] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        Invalidate()
        ns:Print("removed %d demo award(s) from the loot log.", removed)
    end
    return removed
end

-- allowNoGuild: also purge when the character is not in a guild (only used well after login,
-- when IsInGuild() is settled).
local function TryPurge(allowNoGuild)
    if purgeDone or not ns.loggedIn then return end
    if RosterKnown() or (allowNoGuild == true and not IsInGuild()) then
        Ledger:PurgeDemoAwards()
    end
end

-- Entries saved by DisasterZone 0.1 have no guild tag: adopt those recorded by (or awarded to) a member of
-- the current guild. Others stay untagged until a character of their guild logs in. Also drops the
-- cached view when the guild changed.
UpdateScope = function()
    local gkey = CurrentGuildKey()
    if gkey ~= scopeKey then
        scopeKey = gkey
        Invalidate()
    end
    local db = LedgerDB()
    if not db or not gkey then return end
    -- Entries this session recorded or merged while the guild name was unknown belong to this guild.
    if next(pendingScope) ~= nil then
        local pend = pendingScope
        pendingScope = {}
        local mine = {}
        for id, how in pairs(pend) do
            local e = db[id]
            if type(e) == "table" and e.g == nil then
                e.g = gkey
                if how == true then
                    Broadcast(e)
                    mine[#mine + 1] = e
                end
            end
        end
        Invalidate()
        -- Right after a login few council peers are known yet (and my login HELLO carried a digest without these
        -- entries): send them again once the login exchange is done. Receivers ignore a copy they hold.
        if #mine > 0 then
            Util.After(30, function()
                for _, e in ipairs(mine) do Broadcast(e) end
            end)
        end
    end
    local Guild = ns.Guild
    if not RosterKnown() or not Guild.IsInGuild then return end
    local adopted = 0
    for _, e in pairs(db) do
        if type(e) == "table" and e.g == nil
            and (Guild:IsInGuild(e.by, true) or Guild:IsInGuild(e.w, true)) then
            e.g = gkey
            adopted = adopted + 1
        end
    end
    if adopted > 0 then Invalidate() end
end

local function OnDemoToggled(enabled)
    -- A fresh, empty demo ledger on every enable; disabling discards it.
    demoEntries = {}
    view = nil
    Invalidate()
    if not enabled then FlushDeferred() end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Ledger:OnInit()
    if ns.Comm and ns.Comm.Register then
        ns.Comm:Register("A", OnAward)
        ns.Comm:Register("LW", OnLedgerWant)
        ns.Comm:Register("LG", OnLedger)
    end
    ns:On("DEMO_TOGGLED", OnDemoToggled)
    ns:On("ROSTER_UPDATED", function()
        TryPurge(false)
        UpdateScope()
    end)
    ns:On("GUILD_KEY_READY", function() UpdateScope() end)
    ns:On("CONFIG_UPDATED", function() TryPurge(false) end)
end

local ENTRY_FIELDS = { "id", "i", "w", "b", "ts", "by", "s", "n", "vd", "vts", "dg", "r", "rts", "rid", "g" }

-- A stored entry equals its Clean() copy (no extra fields, same values).
local function SameEntry(a, b)
    for k in pairs(a) do
        if b[k] == nil then return false end
    end
    for _, k in ipairs(ENTRY_FIELDS) do
        if a[k] ~= b[k] then return false end
    end
    return true
end

function Ledger:OnLogin()
    -- Drop or repair malformed saved entries so the view can trust field types
    -- (done at login: name normalization needs the player's realm).
    local db = LedgerDB()
    if not db then return end
    local now = GetServerTime()
    for id, e in pairs(db) do
        local clean = Clean(e)
        if not clean or clean.id ~= id or clean.ts > now + 2 * DAY then
            db[id] = nil   -- malformed, or dated in the future (a forged award; never an honest one)
        else
            -- A void time poisoned into the future (forged A, DisasterZone 0.4): reset, so a void / restore works again.
            if clean.vts and clean.vts > now + FUTURE_SLACK then clean.vts = 0 end
            if clean.rts and clean.rts > now + FUTURE_SLACK then clean.rts = 0 end
            if not SameEntry(e, clean) then db[id] = clean end   -- keep the stored table unless it changes
        end
    end
    view = nil
    -- Demo purge: as soon as the guild roster is known (ROSTER_UPDATED), or 20s after login for a
    -- character without a guild.
    TryPurge(false)
    Util.After(20, function() TryPurge(true) end)
end
