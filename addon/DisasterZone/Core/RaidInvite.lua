if DisasterZoneBoot and DisasterZoneBoot.Run("Core/RaidInvite.lua", ...) then return end -- DisasterZone: Core/RaidInvite.lua
-- Invite & sort (Addendum J §60): invites the players of a raid's group layout and moves everyone into their planned
-- group. While it runs, players who join later are sorted automatically (until the raid session ends, I leave the
-- group, or it is stopped); "Re-sort" runs the sorting on demand. Needs the raid leader or an assistant (the game only
-- lets them invite and move players); nothing is moved in combat.
-- The Groups tab is who has a spot: only the players placed in a group are invited, guild member or guest (an
-- accepted player without a group is not; the organizer is told who). Blacklisted players are never invited. Who is
-- still missing, and why (offline, declined, already in a group, no answer yet), is in GetStatus, with who is in the
-- raid without being on the raid's roster.
local addonName, ns = ...

local RaidInvite = ns:NewModule("RaidInvite")
local Util = ns.Util

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tsort = table.sort

local GROUP_SIZE = 5
local MAX_MOVES = 8          -- subgroup moves per pass (the next pass follows the roster update)
local MAX_AGE = 8 * 3600     -- a run stops after this
local REPASS_DELAY = 2       -- a pass that moved people checks again after this (in case no roster update comes)

local active                 -- { occ, plan = { [key] = g }, name,
                             --   invited = { [key] = GetTime() }, failed = { [key] = "declined" | "offline" |
                             --   "grouped" }, at, session, wasInGroup, announced, waitCombat, offline = { key, ... } }

local function Now() return GetServerTime() end

local function IsLeaderOrAssist()
    if not IsInGroup() then return false end
    if UnitIsGroupLeader("player") then return true end
    return IsInRaid() and UnitIsGroupAssistant("player") and true or false
end

local function Session()
    local GR = ns.GroupRules
    local s = GR and GR.GetSession and GR:GetSession()
    return type(s) == "table" and s.id or nil
end

local function Invite(key)
    local name = Ambiguate and Ambiguate(key, "none") or key
    if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(name) else InviteUnit(name) end
end

-- The global ConvertToRaid exists on 2.5.x (Attune calls it).
local function Convert()
    ConvertToRaid()
end

local function Save()
    local db = ns.db
    if not db then return end
    if active then
        db.raidInvite = { occ = active.occ, plan = active.plan, name = active.name, at = active.at,
                          session = active.session }
    else
        db.raidInvite = nil
    end
end

-- The live raid: { [key] = { index, sub, online } }, count per subgroup.
local function Roster()
    local out, count = {}, {}
    for g = 1, 8 do count[g] = 0 end
    if not IsInRaid() then return out, count end
    for i = 1, GetNumGroupMembers() or 0 do
        local name, _, sub, _, _, _, _, online = GetRaidRosterInfo(i)
        local key = type(name) == "string" and Util.NormalizeName(name) or nil
        if key then
            sub = tonumber(sub) or 1
            out[key] = { index = i, sub = sub, online = online and true or false }
            count[sub] = (count[sub] or 0) + 1
        end
    end
    return out, count
end

local function IsOnline(key)
    if Util.IsMe(key) then return true end
    local G = ns.Guild
    if G and G.IsInGuild and G:IsInGuild(key) then return G:IsOnline(key) and true or false end
    return true   -- not in my guild: let the game decide
end

-- Blacklisted players, and members the organizers declined for this raid, are never invited.
local function IsBlocked(key)
    local RP = ns.RaidPlan
    if not RP then return false end
    if RP.IsBlacklisted and RP:IsBlacklisted(key) then return true end
    return active ~= nil and RP.GetSignupBlock ~= nil and RP:GetSignupBlock(active.occ, key) == "declined"
end

-- Everyone the run invites: the planned players, by group.
local function InviteKeys()
    local keys = {}
    for key in pairs(active.plan) do keys[#keys + 1] = key end
    tsort(keys, function(a, b)
        if active.plan[a] ~= active.plan[b] then return active.plan[a] < active.plan[b] end
        return a < b
    end)
    return keys
end

---------------------------------------------------------------------------
-- The game's answers to an invite ("X declines your group invitation.", "Cannot find player 'X'.", "X is already
-- in a group."): remembered per player, so the organizer sees why somebody is missing.
---------------------------------------------------------------------------

local ANSWERS = {
    { global = "ERR_DECLINE_GROUP_S", fallback = "%s declines your group invitation.", why = "declined" },
    { global = "ERR_BAD_PLAYER_NAME_S", fallback = "Cannot find player '%s'.", why = "offline" },
    { global = "ERR_ALREADY_IN_GROUP_S", fallback = "%s is already in a group.", why = "grouped" },
}
local answerPatterns

local function AnswerPatterns()
    if answerPatterns then return answerPatterns end
    answerPatterns = {}
    for i, a in ipairs(ANSWERS) do
        local fmt = _G[a.global]
        if type(fmt) ~= "string" or not fmt:find("%%s") then fmt = a.fallback end
        local pat = fmt:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"):gsub("%%s", "(.+)")
        answerPatterns[i] = { pat = "^" .. pat .. "$", why = a.why }
    end
    return answerPatterns
end

-- The invited player a name in a system message stands for (the game leaves the realm off on my own realm).
local function InvitedKey(name)
    local key = Util.NormalizeName(name)
    if key and active.invited[key] then return key end
    local base = name:match("^([^%-]+)")
    for k in pairs(active.invited) do
        if k:match("^([^%-]+)") == base then return k end
    end
    return nil
end

---------------------------------------------------------------------------
-- Sorting
---------------------------------------------------------------------------

-- target group for everyone in the raid: planned players their group; the others stay put when their group has room
-- next to the planned players heading there, else the free spots of the highest unplanned groups (8, 7, 6, ...).
local function Targets(plan, roster)
    local target, demand = {}, {}
    for g = 1, 8 do demand[g] = 0 end
    for key in pairs(roster) do
        local g = plan[key]
        if g then
            target[key] = g
            demand[g] = demand[g] + 1
        end
    end
    local others = {}
    for key in pairs(roster) do
        if not plan[key] then others[#others + 1] = key end
    end
    tsort(others)
    for _, key in ipairs(others) do
        local cur = roster[key].sub
        if demand[cur] < GROUP_SIZE then
            target[key] = cur
            demand[cur] = demand[cur] + 1
        else
            for g = 8, 1, -1 do
                if demand[g] < GROUP_SIZE then
                    target[key] = g
                    demand[g] = demand[g] + 1
                    break
                end
            end
        end
    end
    return target
end

-- One pass of subgroup moves. Returns moved, sorted, total (planned players in the raid, and how many are in place).
local function SortPass(plan)
    local roster, count = Roster()
    local target = Targets(plan, roster)
    local sorted, total = 0, 0
    for key in pairs(roster) do
        if plan[key] then
            total = total + 1
            if roster[key].sub == plan[key] then sorted = sorted + 1 end
        end
    end
    if not IsLeaderOrAssist() or InCombatLockdown() then return 0, sorted, total end
    local keys = {}
    for key in pairs(roster) do keys[#keys + 1] = key end
    tsort(keys, function(a, b)
        local pa, pb = plan[a] and 0 or 1, plan[b] and 0 or 1   -- planned players move first
        if pa ~= pb then return pa < pb end
        return a < b
    end)
    local moved = 0
    for _, key in ipairs(keys) do
        if moved >= MAX_MOVES then break end
        local r, g = roster[key], target[key]
        if g and r.sub ~= g then
            if count[g] < GROUP_SIZE then
                SetRaidSubgroup(r.index, g)
                count[r.sub] = count[r.sub] - 1
                count[g] = count[g] + 1
                r.sub = g
                moved = moved + 1
            else
                -- swap with someone in group g who doesn't belong there
                for other, o in pairs(roster) do
                    if o.sub == g and target[other] ~= g then
                        SwapRaidSubgroup(r.index, o.index)
                        o.sub, r.sub = r.sub, g
                        moved = moved + 1
                        break
                    end
                end
            end
        end
    end
    return moved, sorted, total
end

---------------------------------------------------------------------------
-- The run
---------------------------------------------------------------------------

local function Stop(reason)
    if not active then return end
    active = nil
    Save()
    if reason then ns:Print(reason) end
    ns:Fire("RAIDINVITE_CHANGED")
end

local Pump

local function SchedulePump(delay)
    Util.Debounce("raidinvite-pump", delay or 0.5, function() Pump() end)
end

Pump = function()
    if not active then return end
    if Now() - active.at > MAX_AGE then return Stop() end
    if InCombatLockdown() then
        active.waitCombat = true
        ns:Fire("RAIDINVITE_CHANGED")
        return
    end
    active.waitCombat = nil
    local inGroup = IsInGroup()
    if inGroup then active.wasInGroup = true end
    if active.wasInGroup and not inGroup then return Stop("Invite & sort stopped: you left the group.") end
    local session = Session()
    if session then active.session = session end
    if active.session and not session then return Stop() end
    if inGroup and not IsLeaderOrAssist() then
        ns:Fire("RAIDINVITE_CHANGED")
        return
    end

    -- a party becomes a raid as soon as someone joined
    if inGroup and not IsInRaid() and UnitIsGroupLeader("player") then
        Convert()
        SchedulePump(1)
        return
    end

    -- invites: a party (or no group) has room for 4 more; a raid for everyone
    if active.inviting then
        local roster = Roster()
        local members = GetNumGroupMembers() or 0
        local pending = 0
        for key, at in pairs(active.invited) do
            if not roster[key] and GetTime() - at < 60 then pending = pending + 1 end
        end
        local room = IsInRaid() and 40 or (GROUP_SIZE - math.max(1, members) - pending)
        active.offline = {}
        for _, key in ipairs(InviteKeys()) do
            if not Util.IsMe(key) and not roster[key] and not active.invited[key] and not IsBlocked(key) then
                if not IsOnline(key) then
                    active.offline[#active.offline + 1] = key
                elseif room > 0 then
                    Invite(key)
                    active.invited[key] = GetTime()
                    room = room - 1
                end
            end
        end
    end

    if IsInRaid() then
        local moved, sorted, total = SortPass(active.plan)
        active.sorted, active.total = sorted, total
        if moved > 0 then
            SchedulePump(REPASS_DELAY)
        elseif total > 0 and sorted == total and not active.announced then
            active.announced = true
            ns:Print("Groups sorted for %s.", active.name or "the raid")
        end
    end
    ns:Fire("RAIDINVITE_CHANGED")
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- ok, err: can I invite and move players now?
function RaidInvite:CanRun()
    if IsInGroup() and not IsLeaderOrAssist() then
        return false, "Only the raid leader or an assistant can invite and move players."
    end
    if IsInGroup() and not IsInRaid() and not UnitIsGroupLeader("player") then
        return false, "Only the party leader can invite."
    end
    return true
end

local function Begin(occ, plan, name, inviting)
    local clean = {}
    for key, g in pairs(type(plan) == "table" and plan or {}) do
        if type(key) == "string" and type(g) == "number" and g >= 1 and g <= 8 then clean[key] = g end
    end
    if active and active.occ == occ then
        active.plan, active.name = clean, name or active.name
        active.inviting = active.inviting or inviting
        active.announced = nil
    else
        active = { occ = occ, plan = clean, name = name, invited = {}, failed = {}, at = Now(),
                   session = Session(), wasInGroup = IsInGroup(), inviting = inviting, offline = {} }
    end
    Save()
    return clean
end

-- Invites everyone in `plan` ({ [key] = group }) who is online and not in my group yet, then sorts the raid.
-- Players who join later are sorted as they come. Returns ok, err.
function RaidInvite:Start(occ, plan, name)
    local ok, err = self:CanRun()
    if not ok then return false, err end
    Begin(occ, plan, name, true)
    active.invited, active.failed = {}, {}   -- a new press invites the missing players again
    local n = #InviteKeys()
    ns:Print("Inviting and sorting %d players for %s.", n, name or "the raid")
    Pump()
    return true
end

-- Moves everyone in the raid to their planned group now (no invites unless a run is inviting), and keeps sorting
-- late joiners. Returns ok, err.
function RaidInvite:Resort(occ, plan, name)
    if not IsInRaid() then return false, "You are not in a raid." end
    if not IsLeaderOrAssist() then return false, "Only the raid leader or an assistant can move players." end
    Begin(occ, plan, name, false)
    Pump()
    return true
end

-- The plan changed (the layout was saved, a player was taken off the raid) while a run is going: follow it.
function RaidInvite:UpdatePlan(occ, plan)
    if active and active.occ == occ then
        Begin(occ, plan, nil, false)
        SchedulePump(0.2)
    end
end

-- A system chat line: the game's answer to one of my invites? Returns true when it was one.
function RaidInvite:OnSystemMessage(text)
    if not active or type(text) ~= "string" or text == "" or #text > 255 then return false end
    for _, a in ipairs(AnswerPatterns()) do
        local name = text:match(a.pat)
        if name then
            local key = InvitedKey(name)
            if not key then return false end
            active.failed[key] = a.why
            ns:Fire("RAIDINVITE_CHANGED")
            return true
        end
    end
    return false
end

function RaidInvite:Stop() Stop() end

function RaidInvite:IsActive(occ)
    return active ~= nil and (occ == nil or active.occ == occ)
end

-- { occ, planned, inRaid, sorted, invited, waitCombat, canRun, and who is missing (sorted lists of keys):
--   offline  = offline guild members, and players the game could not find,
--   declined = declined the invite,   grouped = already in another group,
--   pending  = invited, no answer yet,
--   unlisted = in my group but not on the raid's roster } or nil when nothing runs.
-- planned / inRaid count everyone the run invites (the players placed in a group).
function RaidInvite:GetStatus()
    if not active then return nil end
    local roster = Roster()
    if not IsInRaid() and IsInGroup() then
        for i = 1, GetNumSubgroupMembers() or 0 do
            local key = Util.UnitKey("party" .. i)
            if key then roster[key] = { sub = 1 } end
        end
    end
    local planned, inRaid, sorted, invited = 0, 0, 0, 0
    local wanted = {}
    local offline, declined, grouped, pending, unlisted = {}, {}, {}, {}, {}
    for _, key in ipairs(active.offline or {}) do offline[#offline + 1] = key end
    for _, key in ipairs(InviteKeys()) do
        wanted[key] = true
        planned = planned + 1
        local r = roster[key]
        local g = active.plan[key]
        if r or Util.IsMe(key) then inRaid = inRaid + 1 end
        if r and g and r.sub == g then sorted = sorted + 1 end
        if active.invited[key] then
            invited = invited + 1
            if not r then
                local why = active.failed[key]
                if why == "declined" then declined[#declined + 1] = key
                elseif why == "grouped" then grouped[#grouped + 1] = key
                elseif why == "offline" then offline[#offline + 1] = key
                else pending[#pending + 1] = key end
            end
        end
    end
    for key in pairs(roster) do
        if not wanted[key] and not Util.IsMe(key) then unlisted[#unlisted + 1] = key end
    end
    for _, list in ipairs({ offline, declined, grouped, pending, unlisted }) do tsort(list) end
    return { occ = active.occ, planned = planned, inRaid = inRaid, sorted = sorted, invited = invited,
             offline = offline, declined = declined, grouped = grouped, pending = pending, unlisted = unlisted,
             waitCombat = active.waitCombat, canRun = self:CanRun() }
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function RaidInvite:OnInit()
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function() if active then SchedulePump(0.5) end end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() if active then SchedulePump(0.5) end end)
    ns:On("GROUP_RULES_CHANGED", function() if active then SchedulePump(0.5) end end)
    ns:RegisterEvent("CHAT_MSG_SYSTEM", function(_, text) if active then RaidInvite:OnSystemMessage(text) end end)
end

function RaidInvite:OnLogin()
    -- a /reload during a run picks it up again (sorting only; invites were sent already)
    local saved = ns.db and ns.db.raidInvite
    if type(saved) == "table" and type(saved.plan) == "table" and tonumber(saved.at)
        and Now() - saved.at < MAX_AGE then
        active = { occ = saved.occ, plan = saved.plan,
                   name = saved.name, invited = {}, failed = {}, at = saved.at, session = saved.session,
                   wasInGroup = true, offline = {} }
        Util.After(3, function() Pump() end)
    elseif ns.db then
        ns.db.raidInvite = nil
    end
end
