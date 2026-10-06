if DisasterZoneBoot and DisasterZoneBoot.Run("Core/RaidLink.lua", ...) then return end -- DisasterZone: Core/RaidLink.lua
-- Addendum J §61: links a running raid session (Addendum I) to the planned raid it is, automatically. The raid leader's
-- client decides (it is the session's authority) and the link rides on the session's GS (rp / rpAt), so every raider
-- records the same one. 1.3: anyone with the raid log (the raid leaders list, the GM, the guild council) in the raid can
-- change it in the Raid log, for the whole raid (GroupRules:RequestSessionPlan); after the raid, for its record.
--
-- A planned raid matches when it starts between 4 hours before and 3 hours after the session started, isn't cancelled
-- and isn't for another instance (when I am inside one). Evidence, strongest first: Invite & sort ran for it; the
-- players in the raid who signed up for it (at least 3, and clearly more than for any other candidate); the right
-- instance; the closest start time. Until the evidence is clear it keeps trying (roster changes, zoning) for 2 hours.
local addonName, ns = ...

local RaidLink = ns:NewModule("RaidLink")
local Util = ns.Util

local pairs, ipairs, type, abs = pairs, ipairs, type, math.abs

local BEFORE, AFTER = 4 * 3600, 3 * 3600   -- the planned start may be 4 h before / 3 h after the session start
local GIVE_UP = 2 * 3600                  -- stop trying this long after the session started
local MIN_OVERLAP = 3                     -- signed-up players in the raid needed (without Invite & sort)
local MARGIN = 2                          -- ... and this many more than the runner-up

local function RP() return ns.RaidPlan end

-- The raid's members { [key] = true } (the real roster).
local function RosterKeys()
    local out = {}
    if not IsInRaid() then return out end
    for i = 1, GetNumGroupMembers() or 0 do
        local name = GetRaidRosterInfo(i)
        local key = type(name) == "string" and Util.NormalizeName(name) or nil
        if key then out[key] = true end
    end
    return out
end

-- The instance map id when I am inside a raid instance, else nil.
local function CurrentInstance()
    local inInstance, kind = IsInInstance()
    if not inInstance or kind ~= "raid" then return nil end
    local id = select(8, GetInstanceInfo())
    return tonumber(id)
end

-- Best planned raid for a session started at `start` with `roster` in it. Returns occId, why ("invite" | "signups")
-- or nil while unclear. preferOcc: the raid Invite & sort ran for.
function RaidLink:Match(start, roster, instID, preferOcc)
    local plan = RP()
    if not plan then return nil end
    local best, second
    for _, v in ipairs(plan:GetRaids(start - BEFORE, start + AFTER, true)) do
        -- (1.3.2: a raid of several instances matches in any of them; "Other" has no place)
        local here, known = false, true
        for _, key in ipairs(plan.GetRaidInstances and plan:GetRaidInstances(v) or { v.i }) do
            local inst = plan:GetInstance(key)
            if not (inst and inst.instID) then known = false
            elseif inst.instID == instID then here = true end
        end
        local wrongPlace = instID and known and not here
        if not v.cancelled and not wrongPlace then
            local overlap = 0
            local seen = {}
            for key, s in pairs(plan:GetSignups(v.id)) do
                if s.st ~= "X" and roster[key] then overlap = overlap + 1; seen[key] = true end
            end
            for key in pairs(v.grp or {}) do
                if roster[key] and not seen[key] then overlap = overlap + 1 end
            end
            local score = overlap * 10 - abs(start - v.t) / 600
            if instID and here then score = score + 5 end
            local c = { id = v.id, score = score, overlap = overlap, invited = preferOcc == v.id }
            if c.invited then c.score = c.score + 10000 end
            if not best or c.score > best.score then
                best, second = c, best
            elseif not second or c.score > second.score then
                second = c
            end
        end
    end
    if not best then return nil end
    if best.invited then return best.id, "invite" end
    if best.overlap >= MIN_OVERLAP and (not second or best.overlap >= second.overlap + MARGIN) then
        return best.id, "signups"
    end
    return nil
end

local function TryLink()
    local GR = ns.GroupRules
    if not (GR and GR.IsAuthority and GR:IsAuthority()) then return end
    local s = GR:GetSession()
    if not s or s.rp or s.rpAt then return end          -- linked (or unlinked on purpose) already
    if GetServerTime() - (s.at or 0) > GIVE_UP then return end
    local inv = ns.RaidInvite
    local st = inv and inv.GetStatus and inv:GetStatus()
    local occ = RaidLink:Match(s.at, RosterKeys(), CurrentInstance(), st and st.occ or nil)
    if not occ then return end
    if GR:SetSessionPlan(occ) then
        local v = RP():GetRaid(occ)
        ns:Print("This raid is linked to the planned raid %s (%s). Raid leaders and the guild council can change that "
            .. "in the Raid log, for the whole raid.", v and RP():GetRaidName(v) or "?", v and date("%a %d %b %H:%M", v.t) or "?")
    end
end

local function Schedule(delay)
    Util.Debounce("raidlink-try", delay or 2, TryLink)
end

-- The raid leader: link or unlink the running session by hand (nil unlinks and stops the automatic link).
function RaidLink:SetLink(occId)
    local GR = ns.GroupRules
    if not GR then return false end
    return GR:SetSessionPlan(occId)
end

function RaidLink:OnInit()
    ns:On("GROUP_RULES_CHANGED", function() Schedule(1) end)
    ns:On("RAIDINVITE_CHANGED", function() Schedule(2) end)
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function() Schedule(3) end)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() Schedule(3) end)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() Schedule(3) end)
end
