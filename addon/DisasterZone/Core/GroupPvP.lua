if DisasterZoneBoot and DisasterZoneBoot.Run("Core/GroupPvP.lua", ...) then return end -- DisasterZone: Core/GroupPvP.lua
-- (1.5) PvP for the Groups board: my arena teams (GetArenaTeam: name, bracket, team rating, my personal rating, the
-- members), so a rated arena group is my team's (its name on the group, newcomers get a team invite from me first),
-- and a guildie on another team of that bracket can't join it. The guild learns my teams through my profile
-- (Core/DungeonRuns.lua). Demo mode: a made-up 3v3 team.
local addonName, ns = ...

local PvP = ns:NewModule("GroupPvP")

local ipairs, type, tonumber = ipairs, type, tonumber

local BRACKETS = { 2, 3, 5 }
local demoTeams = { [3] = { index = 2, name = "Disastrous Decisions", size = 3, rating = 1712, personal = 1698,
                            members = {} } }


-- My arena teams by bracket: [2|3|5] = { index (for the team API), name, size, rating, personal, members (keys) }.
function PvP:GetTeams()
    if ns.Util.DemoOn() then return demoTeams end
    local out = {}
    if not GetArenaTeam then return out end
    for i = 1, 3 do
        local name, size, rating, _, _, _, _, _, _, _, personal = GetArenaTeam(i)
        size = tonumber(size)
        if name and size then
            local t = { index = i, name = name, size = size, rating = tonumber(rating) or 0,
                        personal = tonumber(personal) or 0, members = {} }
            local n = GetNumArenaTeamMembers and tonumber(GetNumArenaTeamMembers(i, true)) or 0
            for j = 1, n do
                local who = GetArenaTeamRosterInfo and GetArenaTeamRosterInfo(i, j)
                if who then t.members[#t.members + 1] = ns.Util.NormalizeName(who) or who end
            end
            out[size] = t
        end
    end
    return out
end

-- My team of a bracket (2 / 3 / 5), or nil.
function PvP:GetTeam(bracket)
    return self:GetTeams()[tonumber(bracket) or 0]
end

-- The profile's list: { { bracket, team rating, team name }, ... }.
function PvP:ProfileList()
    local out = {}
    local teams = ns.Util.DemoOn() and {} or self:GetTeams()
    for _, b in ipairs(BRACKETS) do
        local t = teams[b]
        if t then out[#out + 1] = { b, t.rating, (t.name or ""):sub(1, 24) } end
    end
    return out
end

-- A profile's list read back: [bracket] = { rating, name }.
function PvP:ReadList(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, e in ipairs(list) do
        local b, r, n = type(e) == "table" and tonumber(e[1]), type(e) == "table" and tonumber(e[2]),
            type(e) == "table" and e[3]
        if (b == 2 or b == 3 or b == 5) and r and r >= 0 and r < 5000 and type(n) == "string" and #n <= 24 then
            out[b] = { rating = r, name = n }
        end
    end
    return out
end

-- (owner) Invites a player into my team of that bracket: true when sent.
function PvP:InviteToTeam(bracket, key)
    local t = self:GetTeam(bracket)
    if ns.Util.DemoOn() or not t or not ArenaTeamInviteByName then return false end
    ArenaTeamInviteByName(t.index, ns.Util.ShortName and ns.Util.ShortName(key, true) or key)
    return true
end

function PvP:OnInit()
    if ArenaTeamRoster then
        ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
            for i = 1, 3 do ArenaTeamRoster(i) end
        end)
    end
    ns:RegisterEvent("ARENA_TEAM_UPDATE", function() ns:Fire("GROUP_PVP_UPDATED") end)
    ns:RegisterEvent("ARENA_TEAM_ROSTER_UPDATE", function() ns:Fire("GROUP_PVP_UPDATED") end)
end
