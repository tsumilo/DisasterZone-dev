if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Chat.lua", ...) then return end -- DisasterZone Games/Azeromon/Chat.lua
-- ns.AzeroChat: talking to guildmates inside the game.
--   Enter opens a chat line; what you type shows as a speech bubble over you for everyone on your map, and as a line
--   in the chat log for every guildmate playing (with [Place] when they are somewhere else).
--   Emotes: /wave, /dance, /cheer, /sit play on your character for everyone on the map (a bubble "*waves*" too);
--   /sit lasts until you walk or say something.
-- Messages go on the game prefix (CDLg), GUILD only, like presence (Net.lua):
--   { t = "AZK", v, m = map, x = text } | { t = "AZK", v, m = map, e = emote }
-- Text is cut to MAX_LEN, cleaned of escape codes, and limited both ways: you can send one line every GAP seconds,
-- and a sender who floods (more than BURST lines in BURST_WINDOW seconds) is ignored for the rest of the burst.
-- CONTROLS: "Guild chat" off hides others' lines and bubbles and closes the chat line; "Chat bubbles" off keeps the
-- log but draws no bubbles. Nothing here touches loot or council state.
local addonName, ns = ...

local Chat = ns:NewModule("AzeroChat")
local G = ns.Azero
local Maps = ns.AzeroMaps

Chat.VERSION = 1
Chat.MAX_LEN = 120
Chat.GAP = 1.2               -- seconds between my lines
Chat.BURST, Chat.BURST_WINDOW = 5, 10
Chat.LOG_MAX = 30            -- lines kept (the screen shows the last LOG_SHOWN)
Chat.LOG_SHOWN = 6
Chat.LOG_FADE = 15           -- seconds a line stays on screen after it arrives (all of them while typing)
Chat.EMOTES = {
    wave = { say = "*waves*", secs = 3 },
    dance = { say = "*dances*", secs = 6 },
    cheer = { say = "*cheers!*", secs = 3 },
    sit = { say = nil, secs = nil },             -- until they walk or talk
}
Chat.EMOTE_ORDER = { "wave", "dance", "cheer", "sit" }

local log = {}               -- { who, text, place, at, me, system }
local said = {}              -- key -> { text, at, secs } (bubbles; "me" = mine)
local emotes = {}            -- key -> { e, at }
local heard = {}             -- key -> { times } (flood check)
local lastSend = -999

local function Now() return GetTime and GetTime() or 0 end
local function InCombat() return InCombatLockdown and InCombatLockdown() or false end

function Chat:On() return G:Data().chat ~= false end
function Chat:BubblesOn() return G:Data().chatBubbles ~= false end

-- Text as it may be shown: no escape codes (|c colours, |T textures, |H links), no control characters, trimmed, cut.
function Chat.Clean(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("|", "/"):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s%s+", " ")
    if #text > Chat.MAX_LEN then
        text = text:sub(1, Chat.MAX_LEN)
        -- don't leave half a UTF-8 character at the end
        while #text > 0 and text:byte(#text) >= 0x80 and text:byte(#text) < 0xC0 do text = text:sub(1, -2) end
        if #text > 0 and text:byte(#text) >= 0xC0 then text = text:sub(1, -2) end
    end
    if text == "" then return nil end
    return text
end

-- How long a bubble stays: longer lines longer.
function Chat.BubbleSecs(text) return math.min(9, 4 + #text * 0.05) end

local function PlaceName(mapId)
    local def = mapId and Maps[mapId]
    return type(def) == "table" and def.name or nil
end

local function AddLog(entry)
    entry.at = Now()
    log[#log + 1] = entry
    while #log > Chat.LOG_MAX do table.remove(log, 1) end
    Chat.changed = (Chat.changed or 0) + 1
end

-- A local line (a note from the game itself: "You can't chat in combat.").
function Chat:System(text) AddLog({ text = text, system = true }) end


---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- What the player typed. Returns ok, or false and why ("off" | "empty" | "fast" | "combat" | "guild").
function Chat:Say(input)
    if not self:On() then return false, "off" end
    local text = Chat.Clean(input)
    if not text then return false, "empty" end
    local now = Now()
    if now - lastSend < Chat.GAP then return false, "fast" end
    local s = G.save
    if not (s and G.started) then return false, "empty" end
    local emote = text:match("^/(%a+)$")
    emote = emote and emote:lower()
    if emote and not Chat.EMOTES[emote] then
        self:System("Emotes: /" .. table.concat(Chat.EMOTE_ORDER, ", /"))
        return false, "empty"
    end
    if InCombat() then
        self:System("Chat waits until you're out of combat.")
        return false, "combat"
    end
    lastSend = now
    local msg = { t = "AZK", v = Chat.VERSION, m = s.map }
    if emote then msg.e = emote else msg.x = text end
    local sent = IsInGuild and IsInGuild() and ns.Games and ns.Games:Send(G.GAME_ID, msg, "GUILD")
    self:Show("me", G:PlayerName(), s.map, text, emote, true)
    if not sent then
        self:System("Only you can hear that: you're not in a guild.")
        return true, "guild"
    end
    return true
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- A line or emote from `key` (mine: key "me") on `mapId`: into the log, a bubble, an emote.
function Chat:Show(key, who, mapId, text, emote, me)
    local here = G.save and G.save.map == mapId
    local place = (not me and not here) and PlaceName(mapId) or nil
    if emote then
        local def = Chat.EMOTES[emote]
        if here or me then emotes[key] = { e = emote, at = Now() } end
        if def.say and (here or me) then said[key] = { text = def.say, at = Now(), secs = 2.5 } end
        AddLog({ who = who, text = (def.say or "*sits down*"), place = place, me = me, emote = true })
        return
    end
    if here or me then
        said[key] = { text = text, at = Now(), secs = Chat.BubbleSecs(text) }
        if emotes[key] and emotes[key].e == "sit" then emotes[key] = nil end      -- talking stands you up
    end
    AddLog({ who = who, text = text, place = place, me = me })
end

local function Flooding(key)
    local now, h = Now(), heard[key]
    if not h then h = {} heard[key] = h end
    while h[1] and now - h[1] > Chat.BURST_WINDOW do table.remove(h, 1) end
    h[#h + 1] = now
    return #h > Chat.BURST
end

local function OnChat(senderKey, msg)
    if type(msg) ~= "table" or msg.v ~= Chat.VERSION or type(msg.m) ~= "string" then return end
    if not Chat:On() or not G.started then return end
    if Flooding(senderKey) then return end
    local who = ns.Util and ns.Util.ShortName(senderKey, true) or senderKey
    if type(msg.e) == "string" then
        if Chat.EMOTES[msg.e] then Chat:Show(senderKey, who, msg.m, nil, msg.e) end
        return
    end
    local text = Chat.Clean(msg.x)
    if text then Chat:Show(senderKey, who, msg.m, text) end
end

---------------------------------------------------------------------------
-- For the UI
---------------------------------------------------------------------------

-- The bubble over `key` right now (text), or nil. Peers: their sender key; me: "me".
function Chat:Bubble(key)
    if not (self:On() and self:BubblesOn()) then return nil end
    local b = said[key]
    if not b then return nil end
    if Now() - b.at > b.secs then said[key] = nil return nil end
    return b.text
end

-- The emote playing on `key`: name and seconds since it began, or nil.
function Chat:Emote(key)
    local e = emotes[key]
    if not e then return nil end
    local def = Chat.EMOTES[e.e]
    local age = Now() - e.at
    if def.secs and age > def.secs then emotes[key] = nil return nil end
    return e.e, age
end

-- Walking ends a sit (mine from the UI, a peer's when it moves).
function Chat:Stand(key)
    local e = emotes[key]
    if e and e.e == "sit" then emotes[key] = nil end
end

-- The lines to show: newest last, at most n, with how visible each is (1, fading to 0 after LOG_FADE).
function Chat:Lines(n, all)
    local out, now = {}, Now()
    for i = math.max(1, #log - (n or Chat.LOG_SHOWN) + 1), #log do
        local l = log[i]
        local age = now - l.at
        local a = all and 1 or math.max(0, math.min(1, (Chat.LOG_FADE - age) / 2))
        if a > 0 then out[#out + 1] = { line = l, alpha = a } end
    end
    return out
end

function Chat:Log() return log end

function Chat:OnInit()
    if ns.Comm then ns.Comm:Register("AZK", OnChat) end
    G:On("step", function() Chat:Stand("me") end)        -- walking ends my /sit
end

-- For tests
Chat._Reset = function() log, said, emotes, heard, lastSend = {}, {}, {}, {}, -999 Chat.changed = nil end
Chat._OnChat = OnChat
Chat._Said = function() return said end
