if DisasterZoneBoot and DisasterZoneBoot.Run("Core/RecruitMessage.lua", ...) then return end -- DisasterZone: Core/RecruitMessage.lua
-- Recruitment > Message (1.6): the guild's recruitment message, written by the officers themselves (255 bytes at
-- most), and where it goes: a list of places, each with its own interval and an optional "major cities only" tick.
-- A place is Say, Yell, or a chat channel by name (Trade, LookingForGroup, GuildRecruitment, General, LocalDefense,
-- or any custom channel I'm in).
-- Posting needs a click (the game sends to channels, Say and Yell only inside a hardware event): Post now sends it to
-- every place that's on (and allowed where I stand); with Reminders on, a place that is due (its interval since the
-- last post there, by any officer) brings a toast whose click posts to every place that is due. Posts are told to the
-- recruiters online (RCP, with the place), so officers take turns per place instead of posting twice.
-- Saved (per guild): db.recruitMsg[guildKey] = { v = 2, text, rep, places = { { id, kind = "SAY" | "YELL" |
-- "CHANNEL", name, every = minutes, on, city }, ... }, posts = { [place id] = { at, ... } } }.
local addonName, ns = ...

local Msg = ns:NewModule("RecruitMessage")
local Util = ns.Util

local floor, max, min = math.floor, math.max, math.min
local tconcat, tsort = table.concat, table.sort

local MAX_LEN = 255
local MAX_PLACES = 12
local MIN_EVERY, MAX_EVERY = 1, 720          -- minutes
local DAY = 86400
Msg.MAX_LEN = MAX_LEN
Msg.MIN_EVERY, Msg.MAX_EVERY = MIN_EVERY, MAX_EVERY

-- The places offered in "Add a place" (custom channels I'm in are added to the menu as they are).
Msg.SUGGESTED = {
    { kind = "CHANNEL", name = "Trade" }, { kind = "CHANNEL", name = "LookingForGroup" },
    { kind = "CHANNEL", name = "GuildRecruitment" }, { kind = "CHANNEL", name = "General" },
    { kind = "CHANNEL", name = "LocalDefense" }, { kind = "YELL", name = "Yell" }, { kind = "SAY", name = "Say" },
}

-- The capitals (uiMapID, and the zone name as a fallback): Stormwind, Ironforge, Darnassus, The Exodar, Orgrimmar,
-- Thunder Bluff, Undercity, Silvermoon, Shattrath.
local CITY_MAPS = { [1453] = true, [1455] = true, [1457] = true, [1947] = true, [1454] = true, [1456] = true,
                    [1458] = true, [1954] = true, [1955] = true }
local CITY_NAMES = { ["Stormwind City"] = true, ["Ironforge"] = true, ["Darnassus"] = true, ["The Exodar"] = true,
                     ["Orgrimmar"] = true, ["Thunder Bluff"] = true, ["Undercity"] = true, ["Silvermoon City"] = true,
                     ["Shattrath City"] = true }

local function R() return ns.Recruit end
local Now = Util.Now

local function PlaceId(kind, name) return kind == "CHANNEL" and ("ch:" .. tostring(name):lower()) or kind:lower() end

local function DefaultPlaces()
    return { { id = "ch:trade", kind = "CHANNEL", name = "Trade", every = 60, on = true, city = true },
             { id = "ch:guildrecruitment", kind = "CHANNEL", name = "GuildRecruitment", every = 60, on = true, city = true } }
end

local demoStore
local function DB()
    local d
    if Util.DemoOn() then
        if not demoStore then
            local now = Now()
            demoStore = { v = 2, text = "<Casual Disaster> chill guild for new, returning and raiding players. Thu + Sun "
                .. "19:30, SSC/TK. Looking for a holy paladin and a resto druid. /w me for a chat!",
                places = { { id = "ch:trade", kind = "CHANNEL", name = "Trade", every = 60, on = true, city = true },
                           { id = "ch:guildrecruitment", kind = "CHANNEL", name = "GuildRecruitment", every = 30, on = true,
                             city = true },
                           { id = "yell", kind = "YELL", name = "Yell", every = 120, on = false, city = true } },
                posts = { ["ch:trade"] = { now - 2400, now - 2 * DAY - 1800 }, ["ch:guildrecruitment"] = { now - 4 * DAY - 600 } } }
        end
        d = demoStore
    else
        d = ns.DB:GuildBucket("recruitMsg", true) or {}
    end
    if d.v ~= 2 then                       -- (the first, block-built message: started over)
        for k in pairs(d) do d[k] = nil end
        d.v = 2
    end
    if type(d.text) ~= "string" then d.text = "" end
    if type(d.places) ~= "table" then d.places = DefaultPlaces() end
    if type(d.posts) ~= "table" then d.posts = {} end
    return d
end

---------------------------------------------------------------------------
-- The message
---------------------------------------------------------------------------

function Msg:GetText() return DB().text end

-- Saves the message (line breaks become spaces: a chat line is one line). Kept whole past 255: the counter says.
function Msg:SetText(text)
    text = tostring(text or ""):gsub("[\r\n]+", " "):gsub("|", "")
    DB().text = text:sub(1, 400)
    ns:Fire("RECRUIT_MSG_CHANGED")
end

-- The message: text (nil when empty), its length in bytes, too long?
function Msg:Compose()
    local text = Util.Trim(DB().text or "") or ""
    if text == "" then return nil, 0, false end
    return text, #text, #text > MAX_LEN
end

---------------------------------------------------------------------------
-- Places
---------------------------------------------------------------------------

-- The places, in their order (copies).
function Msg:GetPlaces()
    local out = {}
    for _, p in ipairs(DB().places) do
        out[#out + 1] = { id = p.id, kind = p.kind, name = p.name, every = p.every, on = p.on and true or false,
                          city = p.city and true or false }
    end
    return out
end

function Msg:GetPlace(id)
    for _, p in ipairs(DB().places) do if p.id == id then return p end end
end

function Msg:CleanEvery(v)
    v = floor(tonumber(v) or 60)
    return min(MAX_EVERY, max(MIN_EVERY, v))
end

-- Adds a place (kind "SAY" | "YELL" | "CHANNEL" and a channel's name). Returns ok, err / id.
function Msg:AddPlace(kind, name, every)
    if kind ~= "SAY" and kind ~= "YELL" and kind ~= "CHANNEL" then return false, "not a place" end
    if kind == "CHANNEL" then
        name = Util.Trim((tostring(name or ""):gsub("[%c|]", ""))) or ""
        if name == "" or #name > 32 then return false, "a channel needs a name" end
    else
        name = kind == "YELL" and "Yell" or "Say"
    end
    local d = DB()
    local id = PlaceId(kind, name)
    if self:GetPlace(id) then return false, "already in the list" end
    if #d.places >= MAX_PLACES then return false, "that's enough places" end
    local lower = name:lower()
    d.places[#d.places + 1] = { id = id, kind = kind, name = name, every = self:CleanEvery(every or 60), on = true,
                                city = kind ~= "CHANNEL" or lower == "trade" or lower == "guildrecruitment" }
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true, id
end

function Msg:RemovePlace(id)
    local d = DB()
    for i, p in ipairs(d.places) do
        if p.id == id then
            table.remove(d.places, i)
            ns:Fire("RECRUIT_MSG_CHANGED")
            return true
        end
    end
    return false
end

-- Changes a place: fields on, city, every (minutes).
function Msg:SetPlace(id, f)
    local p = self:GetPlace(id)
    if not p then return false end
    if f.on ~= nil then p.on = f.on and true or false end
    if f.city ~= nil then p.city = f.city and true or false end
    if f.every ~= nil then p.every = self:CleanEvery(f.every) end
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true
end

-- The channels I'm in now (for "Add a place"): their names, without the numbers.
function Msg:JoinedChannels()
    local out = {}
    if not GetChannelList then return out end
    local list = { GetChannelList() }
    for i = 1, #list, 3 do
        local name = list[i + 1]
        if type(name) == "string" and name ~= "" then out[#out + 1] = (name:gsub(" %- .*$", "")) end
    end
    return out
end

function Msg:InMajorCity()
    if Util.DemoOn() then return true end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if map and CITY_MAPS[map] then return true end
    local z = GetRealZoneText and GetRealZoneText()
    return (z and CITY_NAMES[z]) and true or false
end

-- Why I can't post there now ("only in major cities", "you're not in <channel>"), or nil.
function Msg:Blocker(p)
    if p.city and not self:InMajorCity() then return "only in major cities" end
    if p.kind == "CHANNEL" and not Util.DemoOn() then
        local id = GetChannelName and tonumber((GetChannelName(p.name)))
        if not (id and id > 0) then return "you're not in " .. p.name end
    end
    return nil
end

---------------------------------------------------------------------------
-- Posting, turns, reminders
---------------------------------------------------------------------------

function Msg:LastPost(id)
    local best
    for _, at in ipairs(DB().posts[id] or {}) do if not best or at > best then best = at end end
    return best
end

function Msg:NextDue(id)
    local p = self:GetPlace(id)
    if not p then return nil end
    local last = self:LastPost(id)
    return last and (last + p.every * 60) or Now()
end

function Msg:Record(id, at)
    local d = DB()
    local list = d.posts[id] or {}
    list[#list + 1] = at
    tsort(list, function(a, b) return a > b end)
    for i = #list, 1, -1 do
        if i > 40 or list[i] < Now() - 14 * DAY then table.remove(list, i) end
    end
    d.posts[id] = list
    ns:Fire("RECRUIT_MSG_CHANGED")
end

-- The places that are on, due now and allowed where I stand (ids).
function Msg:DuePlaces()
    local out = {}
    for _, p in ipairs(DB().places) do
        if p.on and Now() >= (self:NextDue(p.id) or 0) and not self:Blocker(p) then out[#out + 1] = p.id end
    end
    return out
end

local function SendTo(p, text)
    if p.kind == "CHANNEL" then
        local id = GetChannelName and tonumber((GetChannelName(p.name)))
        if id and id > 0 then SendChatMessage(text, "CHANNEL", nil, id) end
        return
    end
    SendChatMessage(text, p.kind)
end

-- Posts (from a click) to the places given (ids), or to every place that is on. Returns ok, why | the places' names,
-- the ones skipped ("Trade: only in major cities").
function Msg:Post(ids)
    if not (R() and R():CanUse()) then return false, "only the Guild Master and officers post it" end
    local text, _, long = self:Compose()
    if not text then return false, "Write the message first." end
    if long then return false, "The message is longer than 255: shorten it first." end
    local want = {}
    for _, id in ipairs(ids or {}) do want[id] = true end
    local sent, skipped = {}, {}
    for _, p in ipairs(DB().places) do
        if (ids and want[p.id]) or (not ids and p.on) then
            local why = self:Blocker(p)
            if why then
                skipped[#skipped + 1] = p.name .. ": " .. why
            else
                if Util.DemoOn() then ns:Print("Demo mode, not sent to %s: %s", p.name, text) else SendTo(p, text) end
                sent[#sent + 1] = p
            end
        end
    end
    if #sent == 0 then return false, #skipped > 0 and tconcat(skipped, "; ") or "No place is on." end
    local at = Now()
    local names = {}
    for _, p in ipairs(sent) do
        self:Record(p.id, at)
        names[#names + 1] = p.name
    end
    self.ready, self.readyKey = nil, nil
    if not Util.DemoOn() then
        local G = ns.Guild
        for _, k in ipairs(G and G.GetOnlineMembers and G:GetOnlineMembers() or {}) do
            if not Util.IsMe(k) and R():IsRecruiter(k) then
                for _, p in ipairs(sent) do ns.Comm:Send({ t = "RCP", at = at, p = p.id }, "WHISPER", k, "data") end
            end
        end
    end
    ns:Fire("RECRUIT_MSG_POSTED")
    return true, names, skipped
end

function Msg:IsRepeating() return DB().rep == true end
function Msg:SetRepeat(on)
    DB().rep = on and true or nil
    self.ready, self.readyKey = nil, nil
    ns:Fire("RECRUIT_MSG_CHANGED")
end
-- The places waiting for a click (the toast's), or nil.
function Msg:Ready() return self.ready end

local function OnPost(sender, msg, dist)
    if dist ~= "WHISPER" or not (R() and R():IsRecruiter(sender) and R():CanUse()) then return end
    local at = tonumber(msg.at)
    if not Util.IsInt(at, Now() - DAY, Now() + 60) or type(msg.p) ~= "string" or #msg.p > 40 then return end
    Msg:Record(msg.p, at)
end

local function Tick()
    if not Msg:IsRepeating() or not (R() and R():CanUse()) then return end
    local due = Msg:DuePlaces()
    if #due == 0 then
        Msg.ready, Msg.readyKey = nil, nil
        return
    end
    local key = tconcat(due, ",")
    if Msg.readyKey ~= key then
        Msg.ready, Msg.readyKey = due, key
        ns:Fire("RECRUIT_MSG_READY", due)
    end
end

-- Lately: posts this week (every place), and the people who whispered within 2 hours of a post.
function Msg:Lately()
    local all = {}
    for _, list in pairs(DB().posts) do for _, at in ipairs(list) do all[#all + 1] = at end end
    tsort(all, function(a, b) return a > b end)
    local week = 0
    for _, at in ipairs(all) do if at >= Now() - 7 * DAY then week = week + 1 end end
    local came, joined = {}, 0
    for _, r in ipairs(R():GetPeople()) do
        if (r.src == "whisper" or r.src == "trade") and r.at then
            for _, at in ipairs(all) do
                if r.at >= at and r.at <= at + 7200 then
                    came[#came + 1] = r
                    if r.st == "joined" or r.st == "gone" then joined = joined + 1 end
                    break
                end
            end
        end
    end
    tsort(came, function(a, b) return a.at > b.at end)
    return { week = week, last = all[1], came = came, joined = joined }
end

function Msg:OnInit()
    if ns.Comm and ns.Comm.Register then ns.Comm:Register("RCP", OnPost) end
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(5, Tick) end
    ns:On("DEMO_TOGGLED", function() demoStore = nil; Msg.ready, Msg.readyKey = nil, nil end)
end

-- (tests) check now
function Msg:_Tick() Tick() end
