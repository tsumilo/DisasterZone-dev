if DisasterZoneBoot and DisasterZoneBoot.Run("Core/SessionInfo.lua", ...) then return end -- DisasterZone: Core/SessionInfo.lua
-- What the raid session crest (UI/SessionBar.lua) and its drawer (UI/SessionDrawer.lua) show, as one plain table
-- (1.4.2, mockup claude.ai/artifact/2jy2CFhKHvwJVDxHeEYA3T, look B "Crest"): the raid and its bosses (killed, how
-- long each fight took, the one being fought), the drops still waiting for a decision (and which wait on my vote),
-- Free for All loot awarded but still in someone's bags (the 2-hour trade window), who of the lineup left or is not
-- here, the planned raid the night is linked to, the council in the raid and who has DisasterZone. The UI only draws
-- this table, so demo mode (SessionInfo:Demo, a made-up night in Serpentshrine Cavern) and the real raid look alike.
--
-- SessionInfo:Get() -> info, or nil outside a raid:
--   zone, raidKey (ItemDB item key), started, at (session start, server time), by, el (seconds since the start)
--   lead (I run the session: GroupRules:IsAuthority), leader (who runs it), feats { loot, rolls, lock, reserve }
--   bosses { { ref, name, enc, portrait (file id), killed, dur, ts } } in the raid's order, kills, total
--   fight { i (bosses index or nil), name, since (GetTime) } while a boss fight runs
--   drops { { itemID, drop, copy, state ("queued" | "open" | "closed" | "none"), sid, needMe, votes, left } },
--     needVote (how many wait on my vote)
--   trades { { itemID, to, holder, mine, expires (server time) } }, myTrades
--   left { { key, at } } (left the raid, nobody marked them yet), missing { keys } (expected, never came)
--   link { occ, title, team, t } | nil, unlinked (started, not linked and not unlinked on purpose)
--   council { here = { keys }, away = { keys } }, addon { have, total, without = { keys } }
--   lineup { here, total, missing = { keys } } (before the start: the planned raid the session would link to)
--   cls { [key] = classFile } (demo names' classes), demo
local addonName, ns = ...

local SI = ns:NewModule("SessionInfo")
local Util = ns.Util

local floor, max, min = math.floor, math.max, math.min
local pairs, ipairs, type, tonumber = pairs, ipairs, type, tonumber
local tsort = table.sort

local DROP_WINDOW = 40 * 60      -- a drop older than this stops counting as waiting (handed out some other way)
local HELD_AGE = 2 * 3600        -- the game's trade window for loot picked up from a boss (Core/Loot.lua's too)
local LEFT_KEEP = 30 * 60        -- a leaver nobody marked stops being shown after this

local fight                      -- { enc, name, since } while a boss fight runs
local leavers = {}               -- { { rec, e (expected key), key, at } }, oldest first

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------
local P = {}

function P.Now() return GetServerTime and GetServerTime() or time() end

function P.Mod(name) return ns[name] end

-- The raid instance I am in: itemKey, raid (ns.Data.Raids entry), instance id; nil outside one.
function P.Raid()
    if not (GetInstanceInfo and ns.ItemDB and ns.ItemDB.GetRaidByInstance) then return nil end
    local _, kind, _, _, _, _, _, instID = GetInstanceInfo()
    instID = tonumber(instID)
    local key, raid = ns.ItemDB:GetRaidByInstance(instID)
    if not key and kind ~= "raid" then return nil end
    return key, raid, instID
end

-- The raid's bosses in order, one per encounter (Karazhan's Opera shares one; the rares have none), with the kills
-- of record `rec`.
function P.Bosses(raidKey, raid, rec)
    local out, seen = {}, {}
    local killed = {}
    for _, b in ipairs(rec and rec.bosses or {}) do
        local enc = tonumber(b.enc)
        if enc and not killed[enc] then killed[enc] = b end
    end
    local J = ns.Data and ns.Data.BossJournal or {}
    for _, b in ipairs(raid and raid.bosses or {}) do
        local enc = tonumber(b.encounterID)
        if enc and not b.isTrash and not seen[enc] then
            seen[enc] = true
            local ref = raidKey .. ":" .. b.key
            local k = killed[enc]
            out[#out + 1] = { ref = ref, name = (k and k.name) or b.name, enc = enc, portrait = J[ref],
                              killed = k ~= nil, dur = k and tonumber(k.dur) or nil, ts = k and k.ts or nil }
        end
    end
    return out
end

function P.CountKills(bosses)
    local n = 0
    for _, b in ipairs(bosses) do if b.killed then n = n + 1 end end
    return n
end

-- The drops of this session whose copies nobody has received yet (no award, no hand-out), newest drop first.
function P.Drops(since)
    local L, Roll, Ledger = P.Mod("Loot"), P.Mod("Roll"), P.Mod("Ledger")
    if not (L and L.GetHistory and Roll and Roll.GetForItem) then return {}, 0 end
    local out, need = {}, 0
    local now = P.Now()
    local hist = L:GetHistory()
    for h = #hist, 1, -1 do
        local d = hist[h]
        local ts = type(d) == "table" and tonumber(d.ts) or nil
        if ts and ts >= since and ts >= now - DROP_WINDOW and not d.test and type(d.i) == "table" then
            local byItem = Ledger and Ledger.AwardsForDrop and Ledger:AwardsForDrop(d) or {}
            local copies = {}
            for _, itemID in ipairs(d.i) do
                itemID = tonumber(itemID)
                if itemID then
                    local c = (copies[itemID] or 0) + 1
                    copies[itemID] = c
                    local awarded = byItem[itemID] and byItem[itemID][c]
                    local ses = not awarded and Roll:GetForItem(itemID, d.s, c) or nil
                    if not awarded and not (ses and ses.state == "awarded") then
                        local e = { itemID = itemID, drop = d, copy = c, state = ses and ses.state or "none",
                                    sid = ses and ses.id or nil, votes = 0 }
                        if ses then
                            for _ in pairs(ses.votes or {}) do e.votes = e.votes + 1 end
                            e.needMe = (Roll:CanVote(ses.id) and not Roll:GetMyVote(ses.id)) and true or false
                            if ses.state == "open" and Roll.GetTimeLeft then e.left = Roll:GetTimeLeft(ses.id) end
                        end
                        if e.needMe then need = need + 1 end
                        out[#out + 1] = e
                    end
                end
            end
        end
    end
    return out, need
end

-- The newest pick-up of itemID by holder (server time), from the saved held loot.
function P.HeldAt(itemID, holder)
    local list = ns.db and ns.db.heldLoot
    if type(list) ~= "table" then return nil end
    for k = #list, 1, -1 do
        local h = list[k]
        if type(h) == "table" and h.i == itemID and h.k == holder then return tonumber(h.ts) end
    end
    return nil
end

-- Free for All loot awarded and not handed out yet, with who holds it and when the trade window closes.
function P.Trades(group)
    local L, Roll = P.Mod("Loot"), P.Mod("Roll")
    if not (L and L.GetHolder and Roll and Roll.GetOwed) then return {}, 0 end
    local out, mine = {}, 0
    local now = P.Now()
    for _, key in ipairs(group) do
        for _, itemID in ipairs(Roll:GetOwed(key)) do
            local holder = L:GetHolder(itemID)
            local at = holder and P.HeldAt(itemID, holder)
            if holder and at and at + HELD_AGE > now then
                local t = { itemID = itemID, to = key, holder = holder, mine = Util.IsMe(holder), expires = at + HELD_AGE }
                if t.mine then mine = mine + 1 end
                out[#out + 1] = t
            end
        end
    end
    tsort(out, function(a, b) return a.expires < b.expires end)
    return out, mine
end

-- The planned raid `occ` as { occ, title, team, t }.
function P.Plan(occ)
    local RP = P.Mod("RaidPlan")
    local v = occ and RP and RP.GetRaid and RP:GetRaid(occ)
    if not v then return nil end
    local teams = {}
    for _, id in ipairs(v.tm or {}) do
        local t = RP:GetTeam(id)
        if t and t.name then teams[#teams + 1] = t.name end
    end
    return { occ = occ, title = RP:GetRaidName(v), team = #teams > 0 and table.concat(teams, ", ") or nil, t = v.t }
end

-- Before the start: the planned raid the session would link to now, and how many of its sign-ups are here.
function P.Lineup(roster, instID)
    local RL, RP = P.Mod("RaidLink"), P.Mod("RaidPlan")
    if not (RL and RL.Match and RP and RP.GetSignups) then return nil end
    local inv = P.Mod("RaidInvite")
    local st = inv and inv.GetStatus and inv:GetStatus()
    local occ = RL:Match(P.Now(), roster, instID, st and st.occ or nil)
    local plan = occ and P.Plan(occ)
    if not plan then return nil end
    local here, total, missing = 0, 0, {}
    for key, s in pairs(RP:GetSignups(occ) or {}) do
        if type(s) == "table" and s.st == "A" and not s.guest then
            total = total + 1
            if roster[key] then here = here + 1 else missing[#missing + 1] = key end
        end
    end
    tsort(missing)
    plan.here, plan.total, plan.missing = here, total, missing
    return plan
end

-- Council members in the raid; and, when the night has a planned raid, the guild council members who signed up for
-- it and are not here. (The guild's whole council list is no measure: most of it isn't on tonight's raid.)
function P.Council(occ)
    local G, Pz, RP = P.Mod("Guild"), P.Mod("Prized"), P.Mod("RaidPlan")
    local here = Pz and Pz.PresentCouncil and Pz:PresentCouncil() or {}
    local set = {}
    for _, k in ipairs(here) do set[k] = true end
    local away = {}
    if occ and RP and RP.GetSignups and G and G.IsGuildCouncil then
        for key, s in pairs(RP:GetSignups(occ) or {}) do
            if type(s) == "table" and s.st == "A" and not s.guest and not set[key] and G:IsGuildCouncil(key) then
                away[#away + 1] = key
            end
        end
    end
    tsort(away)
    return { here = here, away = away, planned = occ ~= nil }
end

-- Who in the raid has DisasterZone: heard in this group (GroupRules speakers) or known to the guild sync.
function P.Addon(group)
    local GR, Sync = P.Mod("GroupRules"), P.Mod("Sync")
    local have, without = 0, {}
    for _, key in ipairs(group) do
        local yes = Util.IsMe(key) or (GR and GR.IsSpeaker and GR:IsSpeaker(key))
            or (Sync and Sync.GetPeer and Sync:GetPeer(key) ~= nil)
        if yes then have = have + 1 else without[#without + 1] = key end
    end
    tsort(without)
    return { have = have, total = #group, without = without }
end

-- Leavers nobody has marked yet (the leader's attendance prompt), and who is expected but not here.
function P.Attendance(recId)
    local A = P.Mod("Attendance")
    local n = A and A.GetLiveNight and A:GetLiveNight()
    local left = {}
    local now = P.Now()
    for i = #leavers, 1, -1 do
        local l = leavers[i]
        local back = Util.IsInMyGroup(l.key) or Util.IsInMyGroup(l.e)
        local marked = n and n.mk and n.mk[l.e]
        if l.rec ~= recId or back or marked or now - l.at > LEFT_KEEP then
            table.remove(leavers, i)
        end
    end
    for _, l in ipairs(leavers) do left[#left + 1] = { key = l.e, at = l.at } end
    local missing = {}
    if A and A.GetNotHereYet then
        for _, r in ipairs(A:GetNotHereYet()) do missing[#missing + 1] = r.key end
    end
    return left, missing
end

---------------------------------------------------------------------------
-- The table
---------------------------------------------------------------------------
function SI:Get()
    if self.demo then return self:Demo(self.demo) end
    if not IsInRaid() then return nil end
    local GR, RL = P.Mod("GroupRules"), P.Mod("RaidLog")
    if not GR then return nil end
    local raidKey, raid, instID = P.Raid()
    local s = GR:GetSession()
    local rec = s and RL and RL.GetRaid and RL:GetRaid(s.id) or nil
    local info = { started = s ~= nil, lead = GR:IsAuthority() and true or false,
                   leader = GR.GetAuthority and GR:GetAuthority() or nil, cls = {} }
    info.raidKey = raidKey
    info.zone = (rec and rec.zone) or (raid and raid.name) or (GetInstanceInfo and GetInstanceInfo()) or "Raid"
    info.bosses = raidKey and P.Bosses(raidKey, raid, rec) or {}
    info.kills = rec and #(rec.bosses or {}) or 0
    info.total = (rec and RL.GetRecordBossTotal and RL:GetRecordBossTotal(rec)) or #info.bosses
    if #info.bosses > 0 then info.kills = max(info.kills, P.CountKills(info.bosses)) end
    if fight then
        info.fight = { name = fight.name, since = fight.since }
        for i, b in ipairs(info.bosses) do
            if b.enc == fight.enc then info.fight.i = i end
        end
    end
    local group = Util.GetGroupKeys()
    local roster = {}
    for _, k in ipairs(group) do roster[k] = true end
    info.addon = P.Addon(group)
    if s then
        info.at, info.by = s.at, s.by
        info.el = max(0, P.Now() - (s.at or P.Now()))
        local f = GR:GetSessionFeatures() or { loot = true, rolls = true }
        info.feats = { loot = f.loot and true or false, rolls = f.rolls and true or false,
                       lock = GR:IsLocked() and true or false, reserve = f.reserve and true or false }
        info.drops, info.needVote = P.Drops(s.at or 0)
        info.trades, info.myTrades = P.Trades(group)
        info.left, info.missing = P.Attendance(s.id)
        info.link = P.Plan(s.rp or (rec and rec.pl))
        info.unlinked = info.link == nil and not s.rpAt
    else
        info.drops, info.needVote, info.trades, info.myTrades = {}, 0, {}, 0
        info.left, info.missing = {}, {}
        if info.lead then info.lineup = P.Lineup(roster, instID) end
    end
    local plan = info.link or info.lineup
    info.council = P.Council(plan and plan.occ)
    return info
end

-- How many things wait on me (the crest's gold count): my votes, and the leader's / holder's trades.
function SI:NeedsMe(info)
    if not info then return 0 end
    local n = info.needVote or 0
    if info.lead then n = n + #(info.trades or {}) else n = n + (info.myTrades or 0) end
    return n
end

-- "1:42" (h:mm) / "4:12" (m:ss) for a fight or a duration under an hour.
function SI:Clock(sec, short)
    sec = floor(max(0, sec or 0))
    if short and sec < 3600 then return ("%d:%02d"):format(floor(sec / 60), sec % 60) end
    return ("%d:%02d"):format(floor(sec / 3600), floor(sec % 3600 / 60))
end

---------------------------------------------------------------------------
-- Demo: a made-up night in Serpentshrine Cavern (nothing sent or saved). moment: "idle" | "between" | "pull" |
-- "loot" | "done".
---------------------------------------------------------------------------
local DEMO_MOMENTS = { idle = true, between = true, pull = true, loot = true, done = true }
SI.DEMO_MOMENTS = { "idle", "between", "pull", "loot", "done" }

function SI:SetDemo(moment)
    self.demo = DEMO_MOMENTS[moment or ""] and moment or nil
    self.demoAt = GetTime and GetTime() or 0
    ns:Fire("SESSION_INFO_CHANGED")
end

function SI:IsDemo() return self.demo end

function SI:Demo(moment)
    local me = Util.PlayerKey() or "You-Realm"
    local realm = me:match("%-(.+)$") or "Realm"
    local function K(n) return n .. "-" .. realm end
    local cls = { [K("Gina")] = "PRIEST", [K("Shadowmelder")] = "ROGUE", [K("Moonwhisper")] = "DRUID",
                  [K("Victhar")] = "WARRIOR", [K("Darkstalkerr")] = "HUNTER", [K("Saltykim")] = "MAGE",
                  [K("Pugsyhealer")] = "PRIEST", [K("Fizzlecrank")] = "WARLOCK" }
    local raidKey = "SerpentshrineCavern"
    local raid
    if ns.ItemDB and ns.ItemDB.GetRaidByInstance then raid = select(2, ns.ItemDB:GetRaidByInstance(548)) end
    local kills = ({ idle = 0, between = 4, pull = 4, loot = 5, done = 6 })[moment] or 4
    local durs = { 252, 185, 331, 228, 280, 542 }
    local rec = { bosses = {} }
    local B = P.Bosses(raidKey, raid, nil)
    for i = 1, min(kills, #B) do rec.bosses[i] = { enc = B[i].enc, name = B[i].name, dur = durs[i], ts = 0 } end
    local info = { demo = moment, raidKey = raidKey, zone = (raid and raid.name) or "Serpentshrine Cavern",
                   started = moment ~= "idle", lead = true, leader = me, cls = cls }
    info.bosses = P.Bosses(raidKey, raid, rec)
    info.kills, info.total = kills, #info.bosses
    local t0 = (self.demoAt or 0)
    if moment == "pull" then info.fight = { i = 5, name = info.bosses[5] and info.bosses[5].name, since = t0 - 134 } end
    info.council = { here = { me, K("Gina"), K("Shadowmelder"), K("Moonwhisper") }, away = { K("Victhar") },
                     planned = true }
    info.addon = { have = 22, total = 25, without = { K("Darkstalkerr"), K("Fizzlecrank"), K("Pugsyhealer") } }
    info.drops, info.needVote, info.trades, info.myTrades, info.left, info.missing = {}, 0, {}, 0, {}, {}
    if moment == "idle" then
        info.lineup = { occ = "demo", title = "Thursday SSC", team = "Main team", t = P.Now() + 240,
                        here = 23, total = 25, missing = { K("Darkstalkerr"), K("Saltykim") } }
        return info
    end
    local el = ({ between = 6120, pull = 6660, loot = 6900, done = 9660 })[moment] or 6120
    info.at, info.by, info.el = P.Now() - el, me, el + floor((GetTime and GetTime() or 0) - t0)
    info.feats = { loot = true, rolls = true, lock = true }
    info.link = { occ = "demo", title = "Thursday SSC", team = "Main team", t = P.Now() - el - 300 }
    info.left = { { key = K("Darkstalkerr"), at = P.Now() - 1500 } }
    if moment == "loot" then
        info.drops = {
            { itemID = 30083, copy = 1, state = "open", votes = 3, needMe = true, demo = true },
            { itemID = 30008, copy = 1, state = "open", votes = 4, mine = K("Moonwhisper"), demo = true },
            { itemID = 30098, copy = 1, state = "open", plain = true, left = 12, demo = true },
        }
        info.needVote = 1
    elseif moment == "done" then
        info.trades = {
            { itemID = 30242, to = K("Gina"), holder = me, mine = true, expires = P.Now() + 6480 },
            { itemID = 30103, to = K("Shadowmelder"), holder = me, mine = true, expires = P.Now() + 6480 },
        }
        info.myTrades = 2
    end
    return info
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
function SI:OnInit()
    ns:RegisterEvent("ENCOUNTER_START", function(_, enc, name)
        fight = { enc = tonumber(enc), name = name, since = GetTime() }
        ns:Fire("SESSION_INFO_CHANGED")
    end)
    ns:RegisterEvent("ENCOUNTER_END", function()
        fight = nil
        ns:Fire("SESSION_INFO_CHANGED")
    end)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if not (IsEncounterInProgress and IsEncounterInProgress()) then fight = nil end
    end)
    ns:On("ATTENDANCE_PLAYER_LEFT", function(recId, e, key)
        if not e then return end
        for _, l in ipairs(leavers) do
            if l.e == e and l.rec == recId then return end
        end
        leavers[#leavers + 1] = { rec = recId, e = e, key = key, at = P.Now() }
        ns:Fire("SESSION_INFO_CHANGED")
    end)
    ns:On("DEMO_TOGGLED", function(on)
        if not on and self.demo then self:SetDemo(nil) end
    end)
end

-- (tests) the fight state and the leavers list
function SI:_Fight() return fight end
function SI:_Leavers() return leavers end
