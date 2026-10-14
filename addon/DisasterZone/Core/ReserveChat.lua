if DisasterZoneBoot and DisasterZoneBoot.Run("Core/ReserveChat.lua", ...) then return end -- DisasterZone: Core/ReserveChat.lua
-- Loot reserves in chat (1.4.3): what players without the addon need, answered by the host's client (Core/Reserves.lua).
--   Whispers to the host (and raid chat lines starting with "!"): !sr / !res / !reserve / !softres <item link or name>
--   reserves; !sr list (also !myres, !sr alone) lists yours; !sr cancel [item] (also !cancel, !unres) takes one back;
--   !sr rules sends the rules. Gargul's and LootReserve's words work too, so a habit from either carries over.
--   Answers are whispers starting with [DZ]. The host's own chat frame doesn't show the !sr whispers nor the answers
--   (the reserve list shows them); a setting can show them.
--   Announcements (raid warning when allowed, else raid): reserves opened (the rules), closed, the reservers of a roll
--   (Core/Roll.lua's own line), a wrap-up post (Core/ReserveIO.lua).
local addonName, ns = ...

local ReserveChat = ns:NewModule("ReserveChat")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local strlower, strmatch, strformat, strgsub, strfind, strsub = string.lower, string.match, string.format,
    string.gsub, string.find, string.sub
local tsort, tconcat = table.sort, table.concat
local min = math.min

local TAG = "[DZ] "
local MAX_LINE = 250
local ANSWER_LIMIT = 0.3         -- (a player's command loop can't flood the host)
local hidden = {}                -- [lowered text] = expiry: my own answers, hidden from my chat frame

local function R() return ns.Reserves end

local function Send(text, chatType, target)
    if Util.DemoOn() then
        ns:Print("|cff999999(demo, not sent)|r %s%s", chatType == "WHISPER" and ("to " .. tostring(target) .. ": ") or "",
            text)
        return
    end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if not send then return end
    text = strsub(text, 1, MAX_LINE)
    if chatType == "WHISPER" then hidden[strlower(text)] = GetTime() + 10 end
    pcall(send, text, chatType, nil, target)
end

-- To the raid: raid warning when I may, else raid chat.
local function Announce(text)
    local channel = "RAID"
    if UnitIsGroupLeader("player") or (UnitIsGroupAssistant and UnitIsGroupAssistant("player")) then
        channel = "RAID_WARNING"
    end
    Send(text, channel)
end
ReserveChat.Announce = function(_, text) Announce(text) end

local function Whisper(key, text)
    Send(TAG .. text, "WHISPER", Ambiguate and Ambiguate(key, "none") or key)
end

local function Link(itemID)
    local DB = ns.ItemDB
    local link = DB and DB.GetLink and DB:GetLink(itemID)
    if link then return link end
    local names = ns.Data and ns.Data.AtlasNames
    return "[" .. ((names and names[itemID]) or ("item " .. itemID)) .. "]"
end
ReserveChat.Link = function(_, itemID) return Link(itemID) end

local function NameOf(itemID)
    local DB = ns.ItemDB
    local name = DB and DB.GetName and DB:GetName(itemID)
    if name then return name end
    local names = ns.Data and ns.Data.AtlasNames
    return names and names[itemID] or nil
end

-- Lines of at most MAX_LINE characters from parts joined by sep.
local function Pack(head, parts, sep)
    local lines, line = {}, head
    for _, p in ipairs(parts) do
        local add = (line == head) and p or (sep .. p)
        if #line + #add > MAX_LINE then
            lines[#lines + 1] = line
            line = p
        else
            line = line .. add
        end
    end
    lines[#lines + 1] = line
    return lines
end
ReserveChat.Pack = function(_, head, parts, sep) return Pack(head, parts, sep) end

---------------------------------------------------------------------------
-- Reading an item out of a chat line
---------------------------------------------------------------------------

-- The item a player means: an item link, an item id, or (part of) a name of the raid's loot. Returns itemID or nil,
-- and a second value "many" when a name fits several items (the candidates' names in a third).
function ReserveChat:FindItem(text, rk)
    if type(text) ~= "string" then return nil end
    local id = tonumber(strmatch(text, "|Hitem:(%d+)"))
    if id then return id end
    local t = Util.Trim(strgsub(text, "|c%x%x%x%x%x%x%x%x", ""))
    t = strgsub(t, "|r", "")
    t = strgsub(t, "^%[(.*)%]$", "%1")
    if t == "" then return nil end
    id = tonumber(t)
    if id then return id end
    local needle = strlower(t)
    local loot = R():RaidLoot(rk)
    local exact, starts, has = nil, {}, {}
    for itemID in pairs(loot) do
        local name = NameOf(itemID)
        local low = name and strlower(name)
        if low == needle then
            exact = itemID
        elseif low and strsub(low, 1, #needle) == needle then
            starts[#starts + 1] = itemID
        elseif low and strfind(low, needle, 1, true) then
            has[#has + 1] = itemID
        end
    end
    if exact then return exact end
    local pick = #starts > 0 and starts or has
    if #pick == 1 then return pick[1] end
    if #pick > 1 then
        tsort(pick)
        local names = {}
        for i = 1, min(#pick, 4) do names[i] = NameOf(pick[i]) or tostring(pick[i]) end
        return nil, "many", names
    end
    return nil
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

-- The command in a line: verb ("reserve" | "cancel" | "list" | "rules"), the rest; nil when it isn't one.
-- whisper: a whisper (the "!" is optional there), else a raid chat line (needs the "!").
function ReserveChat:Parse(text, whisper)
    if type(text) ~= "string" then return nil end
    local t = Util.Trim(text)
    local bang = strmatch(t, "^[!¡]+")
    if not bang and not whisper then return nil end
    local body = bang and strsub(t, #bang + 1) or t
    local low = strlower(body)
    local word, rest = strmatch(low, "^(%a+)%s*(.*)$")
    if not word then return nil end
    local restRaw = Util.Trim(strsub(body, #word + 1))
    if word == "myres" or word == "myreserves" or word == "reserves" then return "list", "" end
    if word == "cancel" or word == "unres" or word == "unreserve" or word == "cancelres" then return "cancel", restRaw end
    if word == "sr" or word == "res" or word == "reserve" or word == "softres" or word == "softreserve" then
        local sub, subRest = strmatch(rest, "^(%a+)%s*(.*)$")
        if rest == "" or sub == "list" or sub == "mine" then
            if rest == "" or (sub and subRest == "") then return "list", "" end
        end
        if sub == "cancel" or sub == "remove" or sub == "unres" then
            return "cancel", Util.Trim(strsub(restRaw, #sub + 1))
        end
        if sub == "rules" or sub == "help" then return "rules", "" end
        return "reserve", restRaw
    end
    return nil
end

local function RulesText(L)
    local held = {}
    for _, id in ipairs(L.h or {}) do held[#held + 1] = Link(id) end
    local per = L.n == 1 and "1 soft reserve each" or strformat("%d soft reserves each", L.n)
    return per, held
end

-- The rules as whisper / raid lines.
function ReserveChat:RulesLines(L)
    L = L or R():Get()
    if not L then return {} end
    local per, held = RulesText(L)
    local lines = {
        strformat("Soft reserves: %s. Whisper %s !sr and an item link. Only who reserved an item rolls on it; "
            .. "nobody reserved it: everyone rolls.", per, Util.ShortName(L.by)),
    }
    if #held > 0 then
        for _, l in ipairs(Pack("Held for the guild (the loot council decides): ", held, " ")) do lines[#lines + 1] = l end
    end
    lines[#lines + 1] = L.o and "Reserves close at the first pull. !sr list shows yours, !sr cancel takes one back."
        or "Reserves are closed."
    return lines
end

local function ListLine(key)
    local L = R():Get()
    local mine = R():Of(key)
    if #mine == 0 then
        return strformat("You have no reserves yet (%d to pick). Whisper !sr and an item link.", L.n or 1)
    end
    local parts = {}
    for _, id in ipairs(mine) do
        local others = #R():Reservers(id) - 1
        parts[#parts + 1] = Link(id) .. (others > 0 and strformat(" (+%d)", others) or "")
    end
    local left = R():Left(key)
    return tconcat(parts, ", ") .. (left > 0 and strformat(" · %d left", left) or "")
        .. (L.o and "" or " · closed")
end

local function CodeText(code, itemID)
    local t = R().CODE_TEXT[code] or "That didn't work."
    if itemID and strfind(t, "^%l") then return Link(itemID) .. " " .. t end
    return t
end

-- Runs a command from key (sender): returns the answer lines (also whispered unless quiet).
function ReserveChat:Handle(key, text, whisper, quiet)
    local Res = R()
    local L = Res and Res:Get()
    if not (L and Res:IsHost()) then return nil end
    local verb, rest = self:Parse(text, whisper)
    if not verb then return nil end
    local out = {}
    if verb == "rules" then
        out = self:RulesLines(L)
    elseif verb == "list" then
        out[1] = ListLine(key)
    elseif verb == "cancel" then
        local itemID = rest ~= "" and self:FindItem(rest, L.rk) or nil
        if not itemID then
            local mine = Res:Of(key)
            if #mine == 1 then itemID = mine[1] end
        end
        if not itemID then
            out[1] = "Which one? Whisper !sr cancel and the item link."
        else
            local ok, code = Res:CancelFor(key, itemID)
            out[1] = ok and (strformat("Took back %s. ", Link(itemID)) .. ListLine(key)) or CodeText(code, itemID)
        end
    elseif verb == "reserve" then
        local itemID, why, names = self:FindItem(rest, L.rk)
        if not itemID then
            if why == "many" then
                out[1] = "Which one: " .. tconcat(names, ", ") .. "? Send the item link."
            else
                out[1] = "Send the item link: !sr [item]. !sr rules for the rules."
            end
        else
            local ok, code = Res:AddFor(key, itemID, "w")
            if ok then
                local others = #Res:Reservers(itemID) - 1
                out[1] = strformat("Reserved %s. %s", Link(itemID),
                    others > 0 and strformat("%d other%s on it.", others, others == 1 and "" or "s")
                    or "Nobody else on it yet.")
                local left = Res:Left(key)
                out[1] = out[1] .. (left > 0 and strformat(" %d left.", left) or "")
            else
                out[1] = CodeText(code, itemID)
                if code == "full" then out[1] = out[1] .. " " .. ListLine(key) .. ". !sr cancel [item] frees one." end
            end
        end
    end
    if not quiet then
        for _, line in ipairs(out) do Whisper(key, line) end
    end
    return out
end

---------------------------------------------------------------------------
-- Announcements
---------------------------------------------------------------------------

function ReserveChat:AnnounceRules()
    for _, line in ipairs(self:RulesLines()) do Announce(line) end
end

function ReserveChat:AnnounceClosed()
    local Res = R()
    local _, done, total = Res:Missing()
    Announce(strformat("Reserves are closed (%d of %d reserved). !sr list shows yours.", done, total))
end

-- Whispers the players without a full set of reserves (the host's "Whisper them").
function ReserveChat:NudgeMissing()
    local Res = R()
    local L = Res:Get()
    if not (L and Res:IsHost()) then return 0 end
    local missing = Res:Missing()
    local n = 0
    for _, key in ipairs(missing) do
        if not Util.IsMe(key) then
            Whisper(key, strformat("You have %d soft reserve%s left: whisper !sr and an item link. !sr rules for the rules.",
                Res:Left(key), Res:Left(key) == 1 and "" or "s"))
            n = n + 1
        end
    end
    return n
end

---------------------------------------------------------------------------
-- Chat events
---------------------------------------------------------------------------

local function OnWhisper(_, text, sender)
    local key = Util.NormalizeName(sender)
    if not key or Util.IsMe(key) or not Util.IsInMyGroup(key) then return end
    if not ReserveChat:Parse(text, true) then return end
    if Util.RateLimit and not Util.RateLimit("rvw-" .. key, ANSWER_LIMIT) then return end
    ReserveChat:Handle(key, text, true)
end

local function OnRaid(_, text, sender)
    local key = Util.NormalizeName(sender)
    if not key or Util.IsMe(key) then return end
    if not ReserveChat:Parse(text, false) then return end
    if Util.RateLimit and not Util.RateLimit("rvw-" .. key, ANSWER_LIMIT) then return end
    ReserveChat:Handle(key, text, false)
end

local function Showing()
    local DB = ns.DB
    return DB and DB.GetSetting and DB:GetSetting("reserves.showWhispers") == true
end

-- My chat frame: the !sr whispers to me and my [DZ] answers are hidden (the reserve list says it all).
local function FilterIn(_, _, text)
    local Res = R()
    if Showing() or not (Res and Res:Get() and Res:IsHost()) then return false end
    return ReserveChat:Parse(text, true) ~= nil
end

local function FilterOut(_, _, text)
    if Showing() or type(text) ~= "string" then return false end
    local low = strlower(text)
    local exp = hidden[low]
    if exp and exp > GetTime() then return true end
    hidden[low] = nil
    return false
end

function ReserveChat:OnInit()
    ns:RegisterEvent("CHAT_MSG_WHISPER", OnWhisper)
    ns:RegisterEvent("CHAT_MSG_RAID", OnRaid)
    ns:RegisterEvent("CHAT_MSG_RAID_LEADER", OnRaid)
    if ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", FilterIn)
        ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", FilterOut)
    end
end
