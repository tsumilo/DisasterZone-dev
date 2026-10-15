if DisasterZoneBoot and DisasterZoneBoot.Run("Core/RecruitMessage.lua", ...) then return end -- DisasterZone: Core/RecruitMessage.lua
-- Recruitment > Message (1.6): the guild's recruitment line for Trade, LookingForGroup and GuildRecruitment, built
-- from blocks like the Groups LFG message (Core/GroupsLFG.lua): the guild tag, who we are, what we do, the raid
-- nights, the classes we're after (one team's open places; the team is never named), my own words, Discord, "/w us".
-- Each block on or off; who / what / my words / Discord are texts I can change. 255 bytes at most.
-- Posting needs a click (the client posts to public channels only inside a hardware event): Post now sends it; with
-- the repeat on, the message is ready again every N minutes (RECRUIT_MSG_READY: a toast with Post) after the last post
-- by any officer: posts are told to the recruiters online (RCP), so officers take turns instead of posting twice.
-- Saved (account-wide, per guild): db.recruitMsg[guildKey] = { off, text = { who, what, custom, discord }, team,
-- skip = { ["CLASS:sp"] = true }, every, chans = { trade, lfg, gr }, posts = { at, ... } }.
local addonName, ns = ...

local Msg = ns:NewModule("RecruitMessage")
local Util = ns.Util

local floor, max, min = math.floor, math.max, math.min
local tconcat, tsort = table.concat, table.sort

local MAX_LEN = 255
local EVERY = { 1800, 3600, 7200 }
local DAY = 86400

Msg.BLOCKS = {
    { key = "tag", label = "Guild tag" },
    { key = "who", label = "Who we are", text = "chill guild for raiders and new or returning players" },
    { key = "what", label = "What we do", text = "raids, dungeons and levelling together" },
    { key = "nights", label = "Raid nights" },
    { key = "classes", label = "Classes we're after" },
    { key = "custom", label = "Your words", text = "", off = true },
    { key = "discord", label = "Discord", text = "", off = true },
    { key = "wme", label = "/w us" },
}
Msg.MAX_LEN = MAX_LEN
Msg.EVERY = EVERY
Msg.CHANNELS = { { key = "trade", label = "Trade", name = "Trade" }, { key = "lfg", label = "LookingForGroup", name = "LookingForGroup" },
                 { key = "gr", label = "GuildRecruitment", name = "GuildRecruitment" } }
local BLOCK = {}
for _, b in ipairs(Msg.BLOCKS) do BLOCK[b.key] = b end

local function R() return ns.Recruit end
local Now = Util.Now

local demoStore
local function DB()
    local d
    if Util.DemoOn() then
        demoStore = demoStore or { posts = { Now() - 2400, Now() - 2 * DAY - 1800, Now() - 4 * DAY - 600 } }
        d = demoStore
    else
        d = ns.DB:GuildBucket("recruitMsg", true) or {}
    end
    d.off = type(d.off) == "table" and d.off or {}
    d.text = type(d.text) == "table" and d.text or {}
    d.skip = type(d.skip) == "table" and d.skip or {}
    d.chans = type(d.chans) == "table" and d.chans or { trade = true, lfg = true, gr = true }
    d.posts = type(d.posts) == "table" and d.posts or {}
    d.every = (d.every == 1800 or d.every == 7200) and d.every or 3600
    for _, b in ipairs(Msg.BLOCKS) do
        if d.off[b.key] == nil and b.off then d.off[b.key] = true end
    end
    return d
end

---------------------------------------------------------------------------
-- The blocks
---------------------------------------------------------------------------

-- The team the classes come from: the one picked, else the first with open places; "none" = no classes line.
function Msg:GetTeam()
    local d = DB()
    if d.team == "none" then return nil end
    local teams = R():GetTeams()
    for _, t in ipairs(teams) do if t.id == d.team then return t end end
    for _, t in ipairs(teams) do if #self:OpenOf(t) > 0 then return t end end
    return teams[1]
end

function Msg:SetTeam(id)
    DB().team = id
    ns:Fire("RECRUIT_MSG_CHANGED")
end

-- A team's open places as { { c, sp, key = "CLASS:sp", name = "Holy Paladin" } } (one per spec).
function Msg:OpenOf(team)
    local out, seen = {}, {}
    local list = team and team.demoOpen
    if not list and team then
        local RP = ns.RaidPlan
        list = RP and RP.GetTeamOpenSlots and (RP:GetTeamOpenSlots(team)) or {}
    end
    for _, o in ipairs(list or {}) do
        local key = tostring(o.c) .. ":" .. tostring(o.sp)
        if o.c and not seen[key] then
            seen[key] = true
            local spec = o.sp and ns.SPECS[o.c] and ns.SPECS[o.c][o.sp]
            out[#out + 1] = { c = o.c, sp = o.sp, key = key, name = (spec and (spec.label .. " ") or "") .. ns.ClassName(o.c) }
        end
    end
    return out
end

function Msg:IsSkipped(key) return DB().skip[key] == true end
function Msg:SetSkipped(key, on)
    DB().skip[key] = on and true or nil
    ns:Fire("RECRUIT_MSG_CHANGED")
end

function Msg:GetText(key)
    local t = DB().text[key]
    if t == nil then t = BLOCK[key] and BLOCK[key].text or "" end
    return t
end

function Msg:SetText(key, text)
    if not BLOCK[key] then return end
    text = Util.Trim((tostring(text or ""):gsub("[%c|]", " "))) or ""
    DB().text[key] = text:sub(1, 160)
    ns:Fire("RECRUIT_MSG_CHANGED")
end

function Msg:IsOn(key) return not DB().off[key] end
function Msg:SetOn(key, on)
    DB().off[key] = not on      -- (false, not nil: a block that starts off stays on once switched on)
    ns:Fire("RECRUIT_MSG_CHANGED")
end

function Msg:BlockText(key)
    if key == "tag" then
        local g = (GetGuildInfo and GetGuildInfo("player")) or "Guild"
        local f = UnitFactionGroup and UnitFactionGroup("player")
        return "<" .. g .. ">" .. (f == "Horde" and " (H)" or f == "Alliance" and " (A)" or "")
    elseif key == "nights" then
        local team = self:GetTeam()
        if not team or not team.nights or #team.nights == 0 then return nil end
        local days = ns.RaidNights:DaysText(team.nights)
        local first = team.nights[1]
        local start = first and ns.RaidNights:Clock((tonumber(first.w) or 0) % 1440) or nil
        return "raids " .. days .. (start and (" " .. start) or "")
    elseif key == "classes" then
        local want = {}
        for _, o in ipairs(self:OpenOf(self:GetTeam())) do
            if not self:IsSkipped(o.key) then want[#want + 1] = o.name end
        end
        return #want > 0 and ("especially after " .. tconcat(want, ", ")) or "all classes welcome"
    elseif key == "wme" then
        return "/w " .. (Util.ShortName(Util.PlayerKey()) or "me") .. " or any officer for a chat"
    end
    local t = self:GetText(key)
    return t ~= "" and t or nil
end

-- The message: text (nil when empty), its length, too long?
function Msg:Compose()
    local parts = {}
    for _, b in ipairs(Msg.BLOCKS) do
        if self:IsOn(b.key) then
            local t = self:BlockText(b.key)
            if t and t ~= "" then parts[#parts + 1] = t end
        end
    end
    local text = tconcat(parts, " · ")
    if text == "" then return nil, 0, false end
    return text, #text, #text > MAX_LEN
end

---------------------------------------------------------------------------
-- Posting, the channels, turns
---------------------------------------------------------------------------

function Msg:GetChannels() return DB().chans end
function Msg:SetChannel(key, on)
    DB().chans[key] = on and true or nil
    ns:Fire("RECRUIT_MSG_CHANGED")
end

function Msg:GetEvery() return DB().every end
function Msg:SetEvery(sec)
    DB().every = (sec == 1800 or sec == 7200) and sec or 3600
    ns:Fire("RECRUIT_MSG_CHANGED")
end

-- Posts (mine and the other officers'), newest first.
function Msg:GetPosts()
    local list = {}
    for _, at in ipairs(DB().posts) do list[#list + 1] = at end
    tsort(list, function(a, b) return a > b end)
    return list
end

function Msg:LastPost() return self:GetPosts()[1] end

function Msg:NextDue()
    local last = self:LastPost()
    return last and (last + self:GetEvery()) or Now()
end

function Msg:Record(at)
    local d = DB()
    d.posts[#d.posts + 1] = at
    tsort(d.posts, function(a, b) return a > b end)
    for i = #d.posts, 1, -1 do
        if i > 60 or d.posts[i] < Now() - 14 * DAY then table.remove(d.posts, i) end
    end
    ns:Fire("RECRUIT_MSG_CHANGED")
end

-- Sends the message to the channels I picked that I'm in (from a click). Returns ok, why / the channels it went to.
function Msg:Post()
    if not (R() and R():CanUse()) then return false, "only the Guild Master and officers post it" end
    local text, _, long = self:Compose()
    if not text then return false, "The message is empty: switch a block on." end
    if long then text = text:sub(1, MAX_LEN) end
    local sent = {}
    if Util.DemoOn() then
        ns:Print("Demo mode, not sent: %s", text)
        sent[1] = "demo"
    else
        for _, ch in ipairs(Msg.CHANNELS) do
            if self:GetChannels()[ch.key] then
                local id = GetChannelName and tonumber((GetChannelName(ch.name)))
                if id and id > 0 then
                    SendChatMessage(text, "CHANNEL", nil, id)
                    sent[#sent + 1] = ch.label
                end
            end
        end
        if #sent == 0 then return false, "You're not in any of the picked channels (Trade and GuildRecruitment are in cities)." end
    end
    local at = Now()
    self:Record(at)
    self.ready = false
    -- the other officers online hear it: their turn waits
    if not Util.DemoOn() then
        local G = ns.Guild
        for _, k in ipairs(G and G.GetOnlineMembers and G:GetOnlineMembers() or {}) do
            if not Util.IsMe(k) and R():IsRecruiter(k) then
                ns.Comm:Send({ t = "RCP", at = at }, "WHISPER", k, "data")
            end
        end
    end
    ns:Fire("RECRUIT_MSG_POSTED")
    return true, sent
end

function Msg:IsRepeating() return DB().rep == true end
function Msg:SetRepeat(on)
    DB().rep = on and true or nil
    self.ready = false
    ns:Fire("RECRUIT_MSG_CHANGED")
end
function Msg:IsReady() return self.ready == true end

local function OnPost(sender, msg, dist)
    if dist ~= "WHISPER" or not (R() and R():IsRecruiter(sender) and R():CanUse()) then return end
    local at = tonumber(msg.at)
    if not Util.IsInt(at, Now() - DAY, Now() + 60) then return end
    Msg:Record(at)
end

local function Tick()
    if not Msg:IsRepeating() or Msg.ready or not (R() and R():CanUse()) then return end
    if Now() >= Msg:NextDue() then
        Msg.ready = true
        ns:Fire("RECRUIT_MSG_READY")
    end
end

-- Lately: posts this week, the people who whispered within 2 hours of a post (added from a whisper or trade), and
-- how many of those joined.
function Msg:Lately()
    local posts = self:GetPosts()
    local week = 0
    for _, at in ipairs(posts) do if at >= Now() - 7 * DAY then week = week + 1 end end
    local came, joined = {}, 0
    for _, r in ipairs(R():GetPeople()) do
        if (r.src == "whisper" or r.src == "trade") and r.at then
            for _, at in ipairs(posts) do
                if r.at >= at and r.at <= at + 7200 then
                    came[#came + 1] = r
                    if r.st == "joined" or r.st == "gone" then joined = joined + 1 end
                    break
                end
            end
        end
    end
    tsort(came, function(a, b) return a.at > b.at end)
    return { week = week, last = posts[1], came = came, joined = joined }
end

function Msg:OnInit()
    if ns.Comm and ns.Comm.Register then ns.Comm:Register("RCP", OnPost) end
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(5, Tick) end
    ns:On("DEMO_TOGGLED", function() demoStore = nil end)
end

function Msg:_Due() DB().posts = {}; self.ready = false; Tick() end
