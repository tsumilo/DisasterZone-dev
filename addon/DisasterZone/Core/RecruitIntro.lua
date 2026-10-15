if DisasterZoneBoot and DisasterZoneBoot.Run("Core/RecruitIntro.lua", ...) then return end -- DisasterZone: Core/RecruitIntro.lua
-- Recruitment, the members' side (1.6; Core/Recruit.lua is the recruiters'). Every member can:
--   introduce a friend (when the GM's rules allow it): the name and a line go to the GM and officers online, and wait
--     on my client until one of them took it (offline: sent when one comes online). When the friend joins the guild,
--     I hear about it (the game's own "X has joined the guild." line, no message needed).
--   answer "How did it go?" (an officer asks about someone I played with): one line back, it goes in their story.
--   say Sure / Not tonight to "Could you take them along?".
-- Messages (WHISPER, class "data"):
--   RCN  { k, c, t }        an introduction (member -> recruiter)      RCNA { k }      taken (recruiter -> member)
--   RCQ  { k, c }           how did it go? (recruiter -> member)       RCW  { k, t }   the answer (member -> recruiter)
--   RCT  { k, c, lv, z, t } take them along? (recruiter -> member)     RCTA { k, y }   yes / no (member -> recruiter)
-- Asks and answers are taken only from who may send them: questions from recruiters, answers only to a question I
-- asked (Core/Recruit.lua keeps those).
local addonName, ns = ...

local Intro = ns:NewModule("RecruitIntro")
local Util = ns.Util

local type, pairs, ipairs, tostring = type, pairs, ipairs, tostring
local floor, max = math.floor, math.max
local tsort = table.sort

local DAY = 86400
local MAX_LINE = 160
local MAX_ANSWER = 200
local KEEP_DAYS = 14

local H = {}

local function Me() return Util.PlayerKey() end
local function R() return ns.Recruit end
local Now = Util.Now

function H.WireKey(s)
    if type(s) ~= "string" or s == "" or #s > 48 or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

function H.Text(s, n)
    if type(s) ~= "string" then return nil end
    s = Util.Trim((s:gsub("[%z\1-\31|]", " "))) or ""
    if #s > n then s = s:sub(1, n) end
    return s
end

function H.Send(msg, target)
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, "WHISPER", target, "data")) and true or false
end

-- My data (this character): db.recruitMember[guildKey] = { intro = { [key] = { c, t, at, ack } },
-- asks = { [id] = { kind = "q" | "t", k, by, at, c, lv, z, t, done } }, joined = { [key] = at } }.
function H.Store(create)
    if not IsInGuild() or Util.DemoOn() and not create then return nil end
    local b = ns.DB:GuildBucket("recruitMember", create)
    if not b then return nil end
    if create then
        b.intro = type(b.intro) == "table" and b.intro or {}
        b.asks = type(b.asks) == "table" and b.asks or {}
        b.joined = type(b.joined) == "table" and b.joined or {}
    end
    return b
end

function H.OnlineRecruiters()
    local G = ns.Guild
    local out = {}
    if not (G and G.IsReady and G:IsReady()) then return out end
    for _, key in ipairs(G:GetOnlineMembers()) do
        if not Util.IsMe(key) and R():IsRecruiter(key) then out[#out + 1] = key end
    end
    return out
end

---------------------------------------------------------------------------
-- Introduce a friend
---------------------------------------------------------------------------

function Intro:CanIntroduce()
    if Util.DemoOn() then return true end
    if not IsInGuild() then return false end
    return R():GetRules().it ~= false
end

-- Introduces someone (name, a line about them, class file optional). Returns ok, err.
function Intro:Introduce(name, line, c)
    if not self:CanIntroduce() then return false, "the Guild Master turned introductions off" end
    local key = H.WireKey(name and ns.Util.Trim(name))
    if not key then return false, "not a character name" end
    local G = ns.Guild
    if G and G.IsInGuild and G:IsInGuild(key, true) then return false, "they're already in the guild" end
    line = H.Text(line or "", MAX_LINE) or ""
    if Util.DemoOn() then
        ns:Print("Demo: %s would be introduced to the officers.", Util.ShortName(key))
        return true
    end
    -- (a recruiter introducing someone: straight into Recruitment, unclaimed)
    if R():IsRecruiter(Me()) then
        if R():Get(key) then return false, "already in Recruitment" end
        return R():Add(key, { src = "intro", claim = false, ib = Me(), it = line, c = c })
    end
    local b = H.Store(true)
    if not b then return false, "your guild is not known yet" end
    b.intro[key] = { c = c, t = line, at = Now() }
    H.SendIntros()
    ns:Fire("RECRUIT_MEMBER_UPDATED")
    return true
end

-- My introductions, newest first: { key, t, at, ack (taken), joined (at) }.
function Intro:GetIntros()
    local out = {}
    local b = H.Store(false)
    for key, e in pairs(b and b.intro or {}) do
        out[#out + 1] = { key = key, t = e.t, at = e.at, ack = e.ack, joined = b.joined[key] }
    end
    tsort(out, function(a, b2) return (a.at or 0) > (b2.at or 0) end)
    return out
end

-- The introductions no recruiter took yet go to the recruiters online (each one takes it; the first answer counts).
function H.SendIntros()
    local b = H.Store(false)
    if not b then return end
    local to = H.OnlineRecruiters()
    if #to == 0 then return end
    H.sentTo = H.sentTo or {}
    for key, e in pairs(b.intro) do
        if not e.ack then
            for _, who in ipairs(to) do
                if not H.sentTo[key .. "|" .. who] then
                    H.sentTo[key .. "|" .. who] = true
                    H.Send({ t = "RCN", k = key, c = e.c, t2 = e.t }, who)
                end
            end
        end
    end
end

function H.OnIntro(sender, msg, dist)
    if dist ~= "WHISPER" or not R():IsRecruiter(Me()) then return end
    local G = ns.Guild
    if not (G and G:IsInGuild(sender, true)) then return end
    if R():GetRules().it == false then return end
    local key = H.WireKey(msg.k)
    if not key or G:IsInGuild(key, true) then return end
    if not R():Get(key) then
        R():Add(key, { src = "intro", claim = false, ib = sender, it = H.Text(msg.t2, MAX_LINE) or "", c = msg.c })
        ns:Fire("RECRUIT_INTRODUCED", key, sender)
    end
    H.Send({ t = "RCNA", k = key }, sender)
end

function H.OnIntroAck(sender, msg, dist)
    if dist ~= "WHISPER" or not R():IsRecruiter(sender) then return end
    local b = H.Store(false)
    local key = H.WireKey(msg.k)
    local e = b and key and b.intro[key]
    if e and not e.ack then
        e.ack = Now()
        ns:Fire("RECRUIT_MEMBER_UPDATED")
    end
end

-- "X has joined the guild." for someone I introduced: noted (Notify thanks me).
function H.OnSystem(text)
    local fmt = _G.ERR_GUILD_JOIN_S
    if type(text) ~= "string" or type(fmt) ~= "string" then return end
    local p = "^" .. fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$"
    local name = text:match(p)
    if not name then return end
    local key = Util.NormalizeName((name:gsub("|H[^|]*|h", ""):gsub("|h", ""):gsub("[%[%]]", "")))
    local b = H.Store(false)
    if b and key and b.intro[key] then
        b.joined[key] = Now()
        ns:Fire("RECRUIT_MEMBER_UPDATED")
    end
end

function Intro:DismissIntro(key)
    local b = H.Store(false)
    if b then b.intro[key], b.joined[key] = nil, nil end
    ns:Fire("RECRUIT_MEMBER_UPDATED")
end

---------------------------------------------------------------------------
-- Asked by an officer: how did it go, take them along
---------------------------------------------------------------------------

function H.OnAsk(sender, msg, dist)
    if dist ~= "WHISPER" or not R():IsRecruiter(sender) then return end
    local key = H.WireKey(msg.k)
    if not key then return end
    local b = H.Store(true)
    if not b then return end
    local kind = msg.t == "RCT" and "t" or "q"
    local id = kind .. ":" .. key
    b.asks[id] = { kind = kind, k = key, by = sender, at = Now(), c = type(msg.c) == "string" and #msg.c <= 12 and msg.c or nil,
                   lv = Util.IsInt(msg.lv, 1, 80) and msg.lv or nil, z = H.Text(msg.z, 40), t = H.Text(msg.t2, 120) }
    ns:Fire("RECRUIT_MEMBER_UPDATED")
end

-- What officers asked me, open first: { id, kind ("q" how did it go | "t" take along), key, by, at, c, lv, z, t }.
function Intro:GetAsks()
    local out = {}
    local b = H.Store(false)
    for id, a in pairs(b and b.asks or {}) do
        if not a.done and (a.at or 0) > Now() - KEEP_DAYS * DAY then
            out[#out + 1] = { id = id, kind = a.kind, key = a.k, by = a.by, at = a.at, c = a.c, lv = a.lv, z = a.z, t = a.t }
        end
    end
    tsort(out, function(x, y) return x.at > y.at end)
    return out
end

-- Answers "how did it go" (one line). Returns ok, err.
function Intro:Answer(id, text)
    local b = H.Store(false)
    local a = b and b.asks[id]
    if not a or a.kind ~= "q" then return false, "nothing to answer" end
    text = H.Text(text, MAX_ANSWER)
    if not text or text == "" then return false, "the answer is empty" end
    H.Send({ t = "RCW", k = a.k, t2 = text }, a.by)
    a.done = Now()
    ns:Fire("RECRUIT_MEMBER_UPDATED")
    return true
end

-- Sure / Not tonight to "take them along".
function Intro:TakeAlong(id, yes)
    local b = H.Store(false)
    local a = b and b.asks[id]
    if not a or a.kind ~= "t" then return false, "nothing to answer" end
    H.Send({ t = "RCTA", k = a.k, y = yes and 1 or 0 }, a.by)
    a.done = Now()
    ns:Fire("RECRUIT_MEMBER_UPDATED")
    return true
end

function Intro:Dismiss(id)
    local b = H.Store(false)
    if b and b.asks[id] then b.asks[id].done = Now() end
    ns:Fire("RECRUIT_MEMBER_UPDATED")
end

---------------------------------------------------------------------------
-- The recruiter's side of the questions (they live with the people: Core/Recruit.lua)
---------------------------------------------------------------------------

H.asked = {}                      -- [member .. "|" .. key] = "q" | "t": what I asked whom (this session)

-- Asks a member how it went with someone (they played with them). Returns ok, err.
function Intro:AskHowItWent(key, member)
    if not R():IsRecruiter(Me()) and not Util.DemoOn() then return false, "only the Guild Master and officers ask" end
    local r = R():Get(key)
    if not r then return false, "not in Recruitment" end
    if Util.DemoOn() then ns:Print("Demo: %s would be asked how it went.", Util.ShortName(member)) return true end
    H.asked[member .. "|" .. r.key] = "q"
    H.Send({ t = "RCQ", k = r.key, c = r.c }, member)
    return true
end

-- Asks a member to take someone along. Returns ok, err.
function Intro:AskTakeAlong(key, member, line)
    if not R():IsRecruiter(Me()) and not Util.DemoOn() then return false, "only the Guild Master and officers ask" end
    local r = R():Get(key)
    if not r then return false, "not in Recruitment" end
    if Util.DemoOn() then ns:Print("Demo: %s would be asked to take them along.", Util.ShortName(member)) return true end
    local live = R():Live(r.key) or {}
    H.asked[member .. "|" .. r.key] = "t"
    H.Send({ t = "RCT", k = r.key, c = r.c, lv = live.lv or r.lv, z = live.zone, t2 = H.Text(line or "", 120) }, member)
    return true
end

function H.OnAnswer(sender, msg, dist)
    if dist ~= "WHISPER" then return end
    local key = H.WireKey(msg.k)
    if not key or H.asked[sender .. "|" .. key] ~= "q" then return end
    H.asked[sender .. "|" .. key] = nil
    local text = H.Text(msg.t2, MAX_ANSWER)
    if text and text ~= "" then
        R():AddNote(key, "\"" .. text .. "\"", sender)
        ns:Fire("RECRUIT_ANSWERED", key, sender)
    end
end

function H.OnTakeAlong(sender, msg, dist)
    if dist ~= "WHISPER" then return end
    local key = H.WireKey(msg.k)
    if not key or H.asked[sender .. "|" .. key] ~= "t" then return end
    H.asked[sender .. "|" .. key] = nil
    local yes = msg.y == 1
    if yes then R():AddNote(key, Util.ShortName(sender) .. " will take them along.", Me()) end
    ns:Print("%s: %s", Util.ShortName(sender), yes and ("sure, they'll take " .. Util.ShortName(key) .. " along.") or "not tonight.")
    ns:Fire("RECRUIT_TAKE_ALONG", key, sender, yes)
end

function Intro:IsAsked(member, key) return H.asked[member .. "|" .. key] end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Intro:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("RCN", H.OnIntro)
        Comm:Register("RCNA", H.OnIntroAck)
        Comm:Register("RCQ", H.OnAsk)
        Comm:Register("RCT", H.OnAsk)
        Comm:Register("RCW", H.OnAnswer)
        Comm:Register("RCTA", H.OnTakeAlong)
    end
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("CHAT_MSG_SYSTEM")
    ev:SetScript("OnEvent", function(_, _, text) H.OnSystem(text) end)
end

function Intro:OnLogin()
    Util.After(35, H.SendIntros)
    ns:On("ROSTER_UPDATED", function() Util.Debounce("recruit-intro-send", 10, H.SendIntros) end)
end

Intro._H = H
