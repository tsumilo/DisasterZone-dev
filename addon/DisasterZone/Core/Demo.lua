if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Demo.lua", ...) then return end -- DisasterZone: demo mode (ns.Demo).
-- In-memory fake guild members, BiS lists and a demo raid so the council views can be tried
-- solo. Generated with a fixed-seed PRNG so the data is identical every time; never saved.
local addonName, ns = ...

local Demo = ns:NewModule("Demo")

local floor = math.floor
local tsort = table.sort

local enabled = false
local generated   -- { records=, roster=, raidSet=, memberKeys= } built on first enable

-- name, classFile, spec index in ns.SPECS[class], guild rank index, in demo raid
local MEMBERS = {
    { "Aldrin",   "WARRIOR", 3, 1, true },
    { "Brakka",   "WARRIOR", 2, 3, true },
    { "Caelith",  "PALADIN", 1, 1, true },
    { "Dornoth",  "PALADIN", 3, 3, false },
    { "Elowen",   "HUNTER",  2, 3, true },
    { "Faelar",   "HUNTER",  1, 4, false },
    { "Grimtusk", "ROGUE",   2, 3, true },
    { "Halvard",  "ROGUE",   1, 3, false },
    { "Isolde",   "PRIEST",  2, 2, true },
    { "Jorvik",   "PRIEST",  3, 3, false },
    { "Kaelyn",   "SHAMAN",  3, 3, true },
    { "Lorvane",  "SHAMAN",  2, 4, false },
    { "Mirabel",  "MAGE",    3, 3, true },
    { "Nortok",   "MAGE",    2, 3, false },
    { "Orinel",   "WARLOCK", 3, 3, true },
    { "Pyria",    "WARLOCK", 1, 4, false },
    { "Quillon",  "DRUID",   4, 2, true },
    { "Rhosyn",   "DRUID",   3, 3, false },
}

local RANK_NAMES = { [0] = "Guild Master", [1] = "Officer", [2] = "Class Lead", [3] = "Raider", [4] = "Trial" }

-- Demo members with an off-spec list (Addendum H): { name, spec index of the off spec }.
local OFFSPEC_MEMBERS = { { "Brakka", 3 }, { "Caelith", 2 }, { "Kaelyn", 1 }, { "Quillon", 3 } }

-- Chance a slot is filled, and a pick is already obtained, per phase.
local FILL_CHANCE = { 1, 1, 1, 0.6, 0.35 }
local OBTAINED_CHANCE = { 0.55, 0.35, 0.2, 0.1, 0.05 }
local ALT_CHANCE = 0.4

---------------------------------------------------------------------------
-- Deterministic PRNG (Park-Miller minimal standard; products stay exact in doubles)
---------------------------------------------------------------------------

local SEED = 20070116   -- TBC release date
local rngState = SEED

local function Reseed()
    rngState = SEED
end

local function Rnd()
    rngState = (rngState * 16807) % 2147483647
    return rngState / 2147483647
end

local function RndInt(n)
    return 1 + floor(Rnd() * n)
end

---------------------------------------------------------------------------
-- Generation
---------------------------------------------------------------------------

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

local function PickItem(list, exclude)
    local pool = {}
    for i = 1, #list do
        local id = list[i].itemID
        if not exclude[id] then pool[#pool + 1] = list[i] end
    end
    if #pool == 0 then return nil end
    return pool[RndInt(#pool)]
end

-- Prefers items from exactly `phase` (so later phases look like real upgrades).
local function PickForPhase(cands, phase, exclude)
    local latest = {}
    for i = 1, #cands do
        if cands[i].ref and cands[i].ref.phase == phase then latest[#latest + 1] = cands[i] end
    end
    local row
    if #latest > 0 and Rnd() < 0.7 then
        row = PickItem(latest, exclude)
    end
    row = row or PickItem(cands, exclude)
    return row and row.itemID or nil
end

local function IsTwoHander(itemID)
    return ns.ItemDB:GetEquipLoc(itemID) == "INVTYPE_2HWEAPON"
end

local function GenerateList(classFile, specLabel, candidateCache)
    local ItemDB = ns.ItemDB
    local function Candidates(sid, phase)
        local key = classFile .. ":" .. sid .. ":" .. phase
        local c = candidateCache[key]
        if not c then
            c = ItemDB:GetCandidates(sid, { maxPhase = phase, class = classFile, usableOnly = true, primaryArmorOnly = true })
            candidateCache[key] = c
        end
        return c
    end

    local ph, obSet = {}, {}
    local prevPhase
    for phase = 1, ns.MAX_PHASE do
        local slots = {}
        local usedMain = {}
        for sid = 1, ns.NUM_SLOTS do
            local skip = Rnd() >= FILL_CHANCE[phase]
            if sid == 16 and slots[15] and IsTwoHander(slots[15][1]) then
                skip = true
            end
            if not skip then
                local cands = Candidates(sid, phase)
                local main
                local carried = prevPhase and prevPhase[sid] and prevPhase[sid][1]
                if carried and not usedMain[carried] and Rnd() < 0.3 then
                    main = carried
                else
                    main = PickForPhase(cands, phase, usedMain)
                end
                if main then
                    usedMain[main] = true
                    local alt = 0
                    if Rnd() < ALT_CHANCE then
                        local exclude = { [main] = true }
                        for id in pairs(usedMain) do exclude[id] = true end
                        local row = PickItem(cands, exclude)
                        alt = row and row.itemID or 0
                    end
                    slots[sid] = { main, alt }
                    if Rnd() < OBTAINED_CHANCE[phase] then obSet[main] = true end
                    if alt ~= 0 and Rnd() < OBTAINED_CHANCE[phase] * 0.6 then obSet[alt] = true end
                end
            end
        end
        if next(slots) then
            ph[phase] = slots
            prevPhase = slots
        end
    end

    -- Currently equipped: the phase-1 pick when obtained, else often some phase-1 item.
    local eq = {}
    for sid = 1, ns.NUM_SLOTS do
        local p1 = ph[1] and ph[1][sid] and ph[1][sid][1]
        local pairedID = ns.SLOT_PAIR[sid] and eq[ns.SLOT_PAIR[sid]]
        local wearing
        if p1 and obSet[p1] and p1 ~= pairedID then
            wearing = p1
        elseif Rnd() < 0.6 then
            local row = PickItem(Candidates(sid, 1), pairedID and { [pairedID] = true } or {})
            wearing = row and row.itemID
        end
        if sid == 16 and eq[15] and IsTwoHander(eq[15]) then
            wearing = nil
        end
        eq[sid] = wearing
    end

    local ob = {}
    for id in pairs(obSet) do ob[#ob + 1] = id end
    tsort(ob)

    return { v = 1, cl = classFile, sp = specLabel or "", ph = ph, ob = ob, eq = eq }
end

local function Generate()
    local Util = ns.Util
    local realm = Util.GetPlayerRealm()
    Reseed()
    local now = Now()
    local records, roster, raidSet, memberKeys = {}, {}, {}, {}
    local candidateCache = {}
    local canBuildLists = ns.ItemDB and ns.ItemDB.GetCandidates

    for _, m in ipairs(MEMBERS) do
        local name, classFile, specIndex, rankIndex, inRaid = m[1], m[2], m[3], m[4], m[5]
        local key = (realm ~= "" and (name .. "-" .. realm)) or name
        local specs = ns.SPECS[classFile]
        local spec = specs and specs[specIndex] and specs[specIndex].label or ""
        local online = inRaid or Rnd() < 0.5

        local data
        if canBuildLists then
            data = GenerateList(classFile, spec, candidateCache)
        else
            data = { v = 1, cl = classFile, sp = spec, ph = {}, ob = {}, eq = {} }
        end
        local ts = now - floor(Rnd() * 10 * 86400)
        records[key] = {
            rev = RndInt(30),
            ts = ts,
            hash = Util.Hash(data),
            data = data,
            recvAt = ts + floor(Rnd() * 3600),
            via = "direct",
        }
        roster[key] = {
            key = key,
            name = name,
            rankIndex = rankIndex,
            rankName = RANK_NAMES[rankIndex] or "Member",
            classFile = classFile,
            online = online and true or false,
            level = 70,
        }
        if inRaid then raidSet[key] = true end
        memberKeys[#memberKeys + 1] = key
    end
    -- Addendum H: a few hybrids keep an off-spec list (generated after everyone else, so the main lists and the
    -- rest of the demo stay the same as before).
    if canBuildLists then
        for _, pick in ipairs(OFFSPEC_MEMBERS) do
            local key = (realm ~= "" and (pick[1] .. "-" .. realm)) or pick[1]
            local rec = records[key]
            local specs = rec and ns.SPECS[rec.data.cl]
            local label = specs and specs[pick[2]] and specs[pick[2]].label
            if label then
                local offList = GenerateList(rec.data.cl, label, candidateCache)
                rec.data.os = label
                rec.data.op = offList.ph
                rec.hash = Util.Hash(rec.data)
            end
        end
    end
    tsort(memberKeys)
    return { records = records, roster = roster, raidSet = raidSet, memberKeys = memberKeys, realm = realm }
end

local function EnsureGenerated()
    local realm = ns.Util.GetPlayerRealm()
    if not generated or generated.realm ~= realm then
        generated = Generate()
    end
    return generated
end

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------

function Demo:IsEnabled()
    return enabled
end

-- In-memory only. Fires DEMO_TOGGLED(enabled), then LISTS_RESET. Returns the new state.
function Demo:SetEnabled(on)
    on = on and true or false
    if on == enabled then return enabled end
    if on then
        if not ns.loggedIn or not ns.Util.PlayerKey() then
            ns:Print("demo mode is available once you are logged in.")
            return enabled
        end
        EnsureGenerated()
    end
    enabled = on
    ns:Fire("DEMO_TOGGLED", enabled)
    ns:Fire("LISTS_RESET")
    return enabled
end

function Demo:Toggle()
    return self:SetEnabled(not enabled)
end

-- { [key] = record } of the fake members (empty when disabled). Do not modify.
function Demo:GetRecords()
    if not enabled or not generated then return {} end
    return generated.records
end

function Demo:GetRecord(key)
    if not enabled or not generated or type(key) ~= "string" then return nil end
    return generated.records[key]
end

-- { [key] = { key=, name=, rankIndex=, rankName=, classFile=, online=, level= } } (empty when disabled).
function Demo:GetRoster()
    if not enabled or not generated then return {} end
    return generated.roster
end

-- Sorted array of the fake members' keys (empty when disabled).
function Demo:GetMembers()
    if not enabled or not generated then return {} end
    local out = {}
    for i, key in ipairs(generated.memberKeys) do out[i] = key end
    return out
end

-- The player plus ~10 fake members are "in raid" while demo mode is on.
function Demo:IsInDemoRaid(key)
    if not enabled or not generated or type(key) ~= "string" then return false end
    return generated.raidSet[key] == true or ns.Util.IsMe(key)
end

-- Sorted array: the player + fake raid members (empty when disabled).
function Demo:GetRaidKeys()
    if not enabled or not generated then return {} end
    local out = {}
    local me = ns.Util.PlayerKey()
    if me then out[#out + 1] = me end
    for key in pairs(generated.raidSet) do out[#out + 1] = key end
    tsort(out)
    return out
end

-- Addendum G §41: stand-in disenchanter ("de") / guild bank ("bank") characters from the demo raid, so the drop
-- panel's DE / Bank buttons can be tried without a guild setting. nil when disabled.
function Demo:GetLootTarget(kind)
    if not enabled or not generated then return nil end
    local keys = {}
    for key in pairs(generated.raidSet) do
        local r = generated.roster[key]
        if not (r and (tonumber(r.rankIndex) or 99) <= 1) then keys[#keys + 1] = key end   -- not an officer
    end
    tsort(keys)
    if kind == "de" then return keys[1] end
    if kind == "bank" then return keys[2] end
    return nil
end

-- Names (without realm) of all fake members, also while demo mode is off. Used by the Ledger to
-- purge demo awards that DisasterZone 0.1 saved (§20).
function Demo:GetFakeNames()
    local out = {}
    for i, m in ipairs(MEMBERS) do out[i] = m[1] end
    return out
end

---------------------------------------------------------------------------
-- Simulated rolls (§19.2)
---------------------------------------------------------------------------

local ROLL_FORMAT_FALLBACK = "%s rolls %d (%d-%d)"

-- Small independent Park-Miller generator, seeded per item so the same item always plays out the
-- same way (and the list generator's sequence is not disturbed).
local function NewRng(seed)
    local state = (floor(tonumber(seed) or 1) % 2147483646) + 1
    local rng = {}
    function rng.Next()
        state = (state * 16807) % 2147483647
        return state / 2147483647
    end
    function rng.Int(n)
        return 1 + floor(rng.Next() * n)
    end
    return rng
end

local function Shuffle(list, rng)
    for i = #list, 2, -1 do
        local j = rng.Int(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function RemoveKey(list, key)
    for i = #list, 1, -1 do
        if list[i] == key then table.remove(list, i) end
    end
end

---------------------------------------------------------------------------
-- Raid log (Addendum I): ~10 past raids for the Raids tab, built on first use with their own generator (the
-- lists above are unchanged). Records are shaped like RaidLog's; awards ride along as demoAwards (ledger-entry
-- shaped), since the demo ledger starts empty. Never saved, never synced.
---------------------------------------------------------------------------

-- raid key, weeks ago, weekday offset (0 = Wednesday), bosses killed (nil = all), auto-ended
local DEMO_RAIDS = {
    { "Karazhan", 0, 0 }, { "GruulsLair", 0, 1 }, { "MagtheridonsLair", 0, 1 },
    { "Karazhan", 1, 0, nil }, { "GruulsLair", 1, 1, 1, true },
    { "Karazhan", 2, 0, 8 }, { "MagtheridonsLair", 2, 1 },
    { "Karazhan", 3, 0, 6 }, { "GruulsLair", 3, 1 },
    { "Karazhan", 4, 0, 4 },
}
local DEMO_REASONS = { "bis", "bis", "bis", "alt", "up", "os", "de" }

-- 1.3.5 (time-based attendance): a demo raid as a planned raid with its expected players, presence pieces, and the
-- cases the Reviews page shows: the newest Karazhan has someone who left early with a reason (and chat lines to pick),
-- a late joiner who told us before, a fill-in and a no-show; older raids' early leaves are decided.
local DEMO_NOTE = "Work until 20:00, I'll be a bit late."
local DEMO_DECISIONS = { { "x", "Disconnect loop, came back on the alt" }, { "c", "No word, second time" },
                         { "x", "Asked to leave for a tank swap" } }

local function DecorateAttendance(rec, n, raid, keys, showRate, present, me)
    rec.pl = "demo-pl-" .. n
    rec.exAt, rec.ef = rec.start, rec.start
    -- the lineup: whoever came, and a few of the core who didn't (no-shows)
    local ex, missing = {}, 0
    for _, key in ipairs(present) do ex[key] = "l" end
    for _, key in ipairs(keys) do
        if not ex[key] and not rec.att[key] and showRate[key] >= 0.75 and missing < 2 then
            ex[key] = "l"
            missing = missing + 1
        end
    end
    rec.ex = ex
    for _, a in pairs(rec.att) do
        if a.j and a.l then a.s = { a.j, a.l } end
    end
    rec.dc, rec.rs, rec.sn, rec.mk = {}, {}, {}, {}
    local leaver = #present > 4 and present[#present - 1] or nil
    local late = #present > 4 and present[#present] or nil
    if n == 1 and leaver then
        local leftAt = rec.att[leaver].l
        rec.rs[leaver] = { c = "life", n = "Power went out, sorry!", at = leftAt + 180 }
        if late then rec.sn[late] = { n = DEMO_NOTE, at = rec.start - 3 * 86400 } end
        -- somebody who wasn't expected fills in a few minutes after the leave
        for _, key in ipairs(keys) do
            if not ex[key] and not rec.att[key] then
                rec.att[key] = { c = rec.att[leaver].c, j = leftAt + 240, l = rec.stop, k = 1,
                                 s = { leftAt + 240, rec.stop } }
                local G = ns.Guild
                rec.att[key].c = G and G.GetClass and G:GetClass(key) or nil
                break
            end
        end
        local Att = ns.Attendance
        if Att and Att.NoteChat then
            Att:NoteChat(leaver, "Raid", "sorry guys power is flickering", leftAt - 120)
            Att:NoteChat(leaver, "Whisper", "power went out :( back sunday", leftAt + 60)
            Att:NoteChat(leaver, "Guild", "anyone got a spare primal might?", leftAt - 5400)
        end
    elseif n == 2 then
        -- an Absent answer given before the raid: waits for an officer
        for key in pairs(ex) do
            if not rec.att[key] and key ~= me then
                rec.sn[key] = { x = true, n = "Away for the weekend", at = rec.start - 2 * 86400 }
                break
            end
        end
    elseif leaver then
        local d = DEMO_DECISIONS[(n % #DEMO_DECISIONS) + 1]
        rec.dc[leaver] = { d = d[1], by = me or present[1], at = rec.stop + 3600, n = d[2] }
    end
end

local function BuildRaidLog()
    local rng = NewRng(SEED + 4242)
    local out = {}
    local raidsByKey = {}
    for _, r in ipairs(ns.ItemDB and ns.ItemDB.GetRaids and ns.ItemDB:GetRaids() or {}) do raidsByKey[r.key] = r end
    local me = ns.Util.PlayerKey()
    local classOf = {}
    for key, m in pairs(generated.roster) do classOf[key] = m.classFile end
    if me then classOf[me] = select(2, UnitClass("player")) end
    local keys = {}
    for key in pairs(classOf) do keys[#keys + 1] = key end
    tsort(keys)
    -- a steady core, a few regulars who miss some weeks, and trials who come now and then
    local showRate = {}
    for i, key in ipairs(keys) do
        showRate[key] = (key == me) and 1 or ({ 0.95, 0.9, 0.75, 0.55 })[1 + (i % 4)]
    end
    local base = Now() - (Now() % 86400) - 3 * 86400 + 19 * 3600 + 30 * 60   -- a recent evening, 19:30
    for n, def in ipairs(DEMO_RAIDS) do
        local raid = raidsByKey[def[1]]
        if raid then
            local start = base - def[2] * 7 * 86400 - def[3] * 86400 + (def[3] > 0 and 3600 or 0)
            local bosses = {}
            for _, b in ipairs(raid.bosses or {}) do
                if b.encounterID and not b.isTrash then
                    local dup = false
                    for _, x in ipairs(bosses) do if x.encounterID == b.encounterID then dup = true end end
                    if not dup then bosses[#bosses + 1] = b end
                end
            end
            local kills = math.min(def[4] or #bosses, #bosses)
            local att, present = {}, {}
            local cap = raid.size or 25
            for _, key in ipairs(keys) do
                if #present < cap and rng.Next() < showRate[key] then
                    present[#present + 1] = key
                    att[key] = { c = classOf[key], j = start - rng.Int(10) * 60, k = kills }
                end
            end
            local rec = { id = "demo-" .. n, start = start, by = present[1], zone = raid.name, instID = raid.instanceID,
                bosses = {}, att = att, demo = true, demoAwards = {} }
            local t = start + 15 * 60
            for bi = 1, kills do
                local b = bosses[bi]
                t = t + (15 + rng.Int(20)) * 60
                local roster = {}
                for _, key in ipairs(present) do roster[#roster + 1] = key end
                tsort(roster)
                rec.bosses[bi] = { enc = b.encounterID, name = b.name, ts = t, roster = roster }
                -- one or two awards per boss from its loot
                local items = b.items or {}
                for a = 1, (#items > 0) and (1 + rng.Int(2) - 1) or 0 do
                    local winner = present[rng.Int(#present)]
                    rec.demoAwards[#rec.demoAwards + 1] = { id = "demo-" .. n .. "-" .. bi .. "-" .. a,
                        i = items[rng.Int(#items)], w = winner, ts = t + 60 * a, b = b.key or "",
                        by = present[1], s = "m", r = DEMO_REASONS[rng.Int(#DEMO_REASONS)] }
                end
            end
            -- a late joiner, an early leaver and a bench player
            if #present > 4 then
                att[present[#present]].j = start + 50 * 60
                att[present[#present]].k = math.max(0, kills - 1)
                local left = att[present[#present - 1]]
                left.k = math.max(0, kills - 2)
            end
            for _, key in ipairs(keys) do
                if not att[key] and rng.Next() < 0.15 then
                    att[key] = { c = classOf[key], j = start, k = 0, b = true }
                    break
                end
            end
            rec.stop = t + 10 * 60
            if def[5] then rec.autoEnded = true else rec.endedBy = rec.by end
            for _, a in pairs(att) do a.l = a.l or rec.stop end
            if #present > 4 then att[present[#present - 1]].l = rec.stop - 40 * 60 end
            DecorateAttendance(rec, n, raid, keys, showRate, present, me)
            out[#out + 1] = rec
        end
    end
    tsort(out, function(a, b) return a.start > b.start end)
    return out
end

-- Demo raid log records, newest first (empty when disabled).
function Demo:GetRaidLog()
    if not enabled or not generated then return {} end
    if not generated.raidLog then generated.raidLog = BuildRaidLog() end
    return generated.raidLog
end

-- Schedules the fake raid members' outcomes for a demo roll session over 2-12 seconds, fed
-- through the same paths as real rolls: Roll:OnSystemMessage(RANDOM_ROLL_RESULT line) and
-- Roll:OnResponse(key, id, "pass"). Roles (when enough members are in the demo raid):
--   one BiS wanter never responds, two members pass, one rolls twice (the second roll is
--   ignored and flagged), one rolls 1-50 (invalid), everybody else rolls 1-100.
-- Returns the number of scheduled outcomes.
function Demo:SimulateRolls(session)
    local Roll, Util = ns.Roll, ns.Util
    if not enabled or not generated or type(session) ~= "table" or not Roll then return 0 end
    local id, itemID = session.id, tonumber(session.i)
    if type(id) ~= "string" or not itemID then return 0 end
    -- (1.3.5: a staged scenario waiting for this roll plays its own script, Core/DemoScenarios.lua)
    local staged = self.RunScenarioRolls and self:RunScenarioRolls(session)
    if staged then return staged end

    local rng = NewRng(SEED + itemID * 7919 + (tonumber(session.c) or 1) * 104729)
    local me = Util.PlayerKey()
    local members = {}
    for key in pairs(generated.raidSet) do
        if key ~= me then members[#members + 1] = key end
    end
    tsort(members)
    Shuffle(members, rng)
    if #members == 0 then return 0 end

    -- The silent one is a BiS wanter of this item when there is one in the demo raid.
    local silent
    local Store = ns.Store
    local wanters = Store and Store.GetWanters and Store:GetWanters(itemID, { raidOnly = true }) or {}
    for _, w in ipairs(wanters) do
        if type(w) == "table" and w.key ~= me and generated.raidSet[w.key] then
            silent = w.key
            break
        end
    end
    silent = silent or members[1]
    RemoveKey(members, silent)

    local plan = {}   -- { key=, kind="roll"|"pass"|"double"|"invalid" }
    for idx, key in ipairs(members) do
        local kind = "roll"
        if idx <= 2 then
            kind = "pass"
        elseif idx == 3 then
            kind = "double"
        elseif idx == 4 then
            kind = "invalid"
        end
        plan[#plan + 1] = { key = key, kind = kind }
    end

    local fmt = type(RANDOM_ROLL_RESULT) == "string" and RANDOM_ROLL_RESULT ~= "" and RANDOM_ROLL_RESULT
        or ROLL_FORMAT_FALLBACK

    local function StillOpen()
        if not enabled then return false end
        local active = Roll.GetActive and Roll:GetActive()
        return active ~= nil and active.id == id
    end

    local function RollLine(key, low, high)
        local value = low + rng.Int(high - low + 1) - 1
        local ok, line = pcall(string.format, fmt, Util.ShortName(key), value, low, high)
        if ok and type(line) == "string" then return line end
        return string.format(ROLL_FORMAT_FALLBACK, Util.ShortName(key), value, low, high)
    end

    local count = 0
    for _, p in ipairs(plan) do
        -- everything lands 2-12s after the start (the double roller's second roll included)
        local delay = 2 + rng.Next() * ((p.kind == "double") and 7 or 10)
        -- Pre-compute the lines so the outcome does not depend on timer order.
        local first, second
        if p.kind == "roll" or p.kind == "double" then
            first = RollLine(p.key, 1, 100)
            if p.kind == "double" then second = RollLine(p.key, 1, 100) end
        elseif p.kind == "invalid" then
            first = RollLine(p.key, 1, 50)
        end
        local key = p.key
        if p.kind == "pass" then
            Util.After(delay, function()
                if StillOpen() then Roll:OnResponse(key, id, "pass") end
            end)
        else
            Util.After(delay, function()
                if StillOpen() then Roll:OnSystemMessage(first) end
            end)
            if second then
                Util.After(delay + 1 + rng.Next() * 2, function()
                    if StillOpen() then Roll:OnSystemMessage(second) end
                end)
            end
        end
        count = count + 1
    end

    -- Addendum G: the demo council votes too, a few seconds in: the first officer for the BiS wanter who never
    -- rolls, the second for one of the rollers, so the vote-based suggestion can be tried.
    local officers = {}
    for key, r in pairs(generated.roster) do
        if key ~= me and (tonumber(r.rankIndex) or 99) <= 1 then officers[#officers + 1] = key end
    end
    tsort(officers)
    local picks = { silent, members[#members] }
    for i = 1, math.min(2, #officers) do
        local voter, cand = officers[i], picks[i]
        if cand and Roll.OnDemoVote then
            Util.After(6 + rng.Next() * 6, function()
                if enabled then Roll:OnDemoVote(voter, id, cand) end
            end)
        end
    end
    return count
end

---------------------------------------------------------------------------
-- Slash: /dz demo [on|off]
---------------------------------------------------------------------------

ns:RegisterSlash("demo", function(rest)
    local arg = type(rest) == "string" and rest:lower() or ""
    arg = arg:gsub("^%s+", ""):gsub("%s+$", "")
    -- (1.3.5: /dz demo <scenario>, /dz demo list)
    if arg ~= "" and arg ~= "on" and arg ~= "off" and arg ~= "1" and arg ~= "0" and Demo.ScenarioSlash
        and Demo:ScenarioSlash(arg) then
        return
    end
    local want
    if arg == "on" or arg == "1" then
        want = true
    elseif arg == "off" or arg == "0" then
        want = false
    else
        want = not enabled
    end
    local nowOn = Demo:SetEnabled(want)
    if nowOn ~= want then return end
    if nowOn then
        local raidCount = 0
        for _ in pairs(generated.raidSet) do raidCount = raidCount + 1 end
        ns:Print("demo mode |cff33ff33on|r: %d fake guild members with BiS lists, %d of them in your demo raid. Try /dz council. Type /dz demo again to turn it off.",
            #generated.memberKeys, raidCount)
    else
        ns:Print("demo mode |cffff3333off|r.")
    end
end, "toggle demo data (fake guild members, lists and raid)")
