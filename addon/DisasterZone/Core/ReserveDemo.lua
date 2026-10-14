if DisasterZoneBoot and DisasterZoneBoot.Run("Core/ReserveDemo.lua", ...) then return end -- DisasterZone: Core/ReserveDemo.lua
-- The loot reserves demo (1.4.3): a made-up pug night in Serpentshrine Cavern, step by step, on any character
-- (/dz reserves demo, Settings > Demo). Demo mode's raid plays the raid; four of them are pugs tonight. Every step
-- drives the real code (the reserve list, the whisper answers, the rolls, the drop panel, the windows) on demo data:
-- nothing is sent, saved or whispered. The steps (ns.ReserveDemo.STEPS):
--   1 Set up          the crest before the start, Reserves picked, its drawer open
--   2 Reserves open   the list opens (2 each, Fang of Vashj and the Nether Vortex held for the guild); the rules in chat
--   3 Players reserve reserves come in by every way there is: the picker, LootReserve, whispers, an import
--   4 Your pick       my own reserve in the picker (the Lightfathom Scepter)
--   5 First pull      reserves close
--   6 Vashj drops     the drop panel with the four cases; Roll all plays them (the demo raid rolls)
--   7 Wrap-up         who got what and how
-- Each step can be seen as the raid leader, a raider with DisasterZone or a pug with chat only (SetView): the windows
-- that person has open, and the chat lines they'd read (Lines). The UI is UI/Reserves.lua's demo panel.
local addonName, ns = ...

local RD = ns:NewModule("ReserveDemo")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local strformat = string.format
local tsort, tinsert = table.sort, table.insert
local min = math.min

local RAID = "SerpentshrineCavern"
local VASHJ = "SerpentshrineCavern:Vashj"
local SCEPTER, LONGBOW, FANG, COILS, VORTEX, CORAL, GAUNTLETS, VESTMENTS = 30108, 30105, 30103, 30109, 30183, 30110,
    30112, 30107
local DROP_ITEMS = { SCEPTER, LONGBOW, FANG, COILS }
local MAX_LINES = 40

RD.STEPS = {
    { key = "setup", title = "Set up",
      text = "Before the start the crest has a fourth switch: reserves. Its drawer holds the rules: how many each, "
          .. "which items the guild holds, what happens to the rest, the ways in." },
    { key = "open", title = "Reserves open",
      text = "Open reserves posts the rules in raid warning. Raiders with DisasterZone get a pop-up with a Reserve "
          .. "button; pugs read the rules in chat." },
    { key = "reserve", title = "Players reserve",
      text = "Reserves come in every way there is: the picker, LootReserve's own window, a whisper (!sr), a softres.it "
          .. "import. They all land in one list, marked with where they came from." },
    { key = "mine", title = "Your pick",
      text = "A raider picks from the raid's loot, boss by boss: a star on what is on their BiS list, the guild's "
          .. "items greyed out, who else is on each item. Click a tile to reserve or take it back." },
    { key = "pull", title = "First pull",
      text = "The first pull closes reserves (the leader can still change any player's). The raid hears it once." },
    { key = "drop", title = "Vashj drops",
      text = "The drop panel says how each item is decided: the reservers roll, one reserve takes it without a roll, "
          .. "the guild's item goes to the council, the rest is up for grabs. Roll all plays them." },
    { key = "wrap", title = "Wrap-up",
      text = "After the last boss: what was reserved, who got it and how. Post it to raid chat or export it for "
          .. "softres.it, LootReserve or Gargul." },
}
RD.VIEWS = { { "lead", "Raid leader" }, { "raider", "Raider" }, { "pug", "Pug (chat only)" } }

local st = { on = false, step = 1, view = "lead", lines = {}, cast = nil, timers = 0 }

local function R() return ns.Reserves end

-- The demo raid's cast: me, guild members, four pugs (by name order, so every client gets the same night).
local function Cast()
    if st.cast then return st.cast end
    local Demo = ns.Demo
    local me = Util.PlayerKey()
    local keys = {}
    for _, k in ipairs(Demo and Demo.GetRaidKeys and Demo:GetRaidKeys() or {}) do
        if k ~= me then keys[#keys + 1] = k end
    end
    tsort(keys)
    local c = { me = me, all = keys, guild = {}, pugs = {}, isPug = {} }
    for i, k in ipairs(keys) do
        if i > #keys - 4 then
            c.pugs[#c.pugs + 1] = k
            c.isPug[k] = true
        else
            c.guild[#c.guild + 1] = k
        end
    end
    st.cast = c
    local Demo = ns.Demo
    if Demo and Demo.SetGuests then Demo:SetGuests(c.isPug) end
    return c
end

-- (the demo raid's pugs: Roll and the UI ask)
function RD:IsPug(key)
    return st.on and Util.DemoOn() and st.cast ~= nil and st.cast.isPug[key] == true or false
end

local function Short(key) return Util.ShortName(key) end

local function Link(id)
    local Chat = ns.ReserveChat
    return Chat and Chat.Link and Chat:Link(id) or ("[" .. id .. "]")
end

-- A chat line for the pug's view: kind "rw" raid warning, "raid", "to" (my whisper), "from" (a whisper to me),
-- "sys" (a system line).
local function Say(kind, text)
    tinsert(st.lines, { kind = kind, text = text })
    while #st.lines > MAX_LINES do table.remove(st.lines, 1) end
    ns:Fire("RESERVE_DEMO_STEP", st.step)
end
RD.Say = function(_, kind, text) Say(kind, text) end

function RD:Lines() return st.lines end
function RD:GetState() return st end
function RD:IsRunning() return st.on and Util.DemoOn() end

-- How long the demo's rolls stay open (nil when the demo doesn't run).
function RD:RollDuration() return self:IsRunning() and 12 or nil end

-- A timer that dies with the demo (or a step change).
local function Later(sec, fn)
    local gen = st.timers
    Util.After(sec, function()
        if st.on and st.timers == gen and Util.DemoOn() then fn() end
    end)
end

local function NewList()
    local c = Cast()
    local L = { id = "demo-night", by = c.me, v = 1, at = GetServerTime(), rk = RAID, n = 2, o = true,
                h = { FANG, VORTEX }, r = {}, method = true }
    R():SetDemo(L)
    return L
end

local function Add(key, id, src)
    local ok = R():AddFor(key, id, src, true)
    return ok
end

---------------------------------------------------------------------------
-- The steps
---------------------------------------------------------------------------
local DO = {}

function DO.setup()
    R():SetDemo(nil)
    st.lines = {}
end

function DO.open()
    local L = NewList()
    st.lines = {}
    for _, line in ipairs(ns.ReserveChat:RulesLines(L)) do Say("rw", line) end
    Say("raid", Short(Cast().pugs[1]) .. ": what if nobody srs something?")
    Say("rw", "Then it's up for grabs: everyone rolls. Whisper !sr rules for the full text.")
end

-- The reserves of the night (key index into the cast, item, source); pugs[1] whispers live (its answers are real).
local function Script()
    local c = Cast()
    local g, p = c.guild, c.pugs
    return {
        { g[1], SCEPTER, "d" }, { g[2], GAUNTLETS, "d" }, { p[2], CORAL, "l" }, { g[3], CORAL, "d" },
        { p[3], VESTMENTS, "s" }, { g[4], 30106, "d" }, { p[4], 30104, "l" }, { g[5] or g[1], 30111, "d" },
    }
end

function DO.reserve()
    if not R():Get() then DO.open() end
    local c = Cast()
    local pug = c.pugs[1]
    local Chat = ns.ReserveChat
    -- the pug who whispers: their lines and the host's real answers
    local function whisper(delay, text)
        Later(delay, function()
            Say("to", text)
            for _, line in ipairs(Chat:Handle(pug, text, true, true) or {}) do Say("from", "[DZ] " .. line) end
        end)
    end
    whisper(0.4, "!sr " .. Link(LONGBOW))
    whisper(1.4, "!sr " .. Link(FANG))
    whisper(2.4, "!sr list")
    for i, e in ipairs(Script()) do
        Later(0.3 + i * 0.45, function()
            if e[1] then Add(e[1], e[2], e[3]) end
        end)
    end
end

function DO.mine()
    if not R():Get() then
        DO.open()
        for _, e in ipairs(Script()) do if e[1] then Add(e[1], e[2], e[3]) end end
    end
    local me = Cast().me
    if not R():SourceOf(me, SCEPTER) then Later(1.5, function() Add(me, SCEPTER, "d") end) end
end

function DO.pull()
    if not R():Get() then
        DO.open()
        for _, e in ipairs(Script()) do if e[1] then Add(e[1], e[2], e[3]) end end
    end
    local me = Cast().me
    if not R():SourceOf(me, SCEPTER) then Add(me, SCEPTER, "d") end
    if not R():SourceOf(Cast().pugs[1], LONGBOW) then Add(Cast().pugs[1], LONGBOW, "w") end
    R():Close()
    local _, done, total = R():Missing()
    Say("rw", strformat("Reserves are closed (%d of %d reserved). !sr list shows yours.", done, total))
end

local function DropNow()
    local Loot = ns.Loot
    if not (Loot and Loot.HandleDrop) then return nil end
    Loot:HandleDrop({ s = "DEMO-RESERVES-" .. tostring(GetTime()), b = VASHJ, i = DROP_ITEMS, ts = GetServerTime(),
                      test = true }, Util.PlayerKey())
    local hist = Loot:GetHistory()
    return type(hist) == "table" and hist[#hist] or nil
end

function DO.drop()
    if not (R():Get() and not R():IsOpen()) then DO.pull() end
    st.drop = DropNow()
    Say("sys", "Lady Vashj has been defeated!")
end

function DO.wrap()
    if not st.drop then DO.drop() end
    local Roll = ns.Roll
    -- every roll still open or closed gets its suggestion; anything not rolled yet is played out at once
    local done = {}
    for _, ses in ipairs(Roll:ReserveSessions()) do done[ses.i] = true end
    for _, ses in ipairs(Roll:ReserveSessions()) do
        if ses.state == "open" or ses.state == "closed" then
            local rows = Roll:GetResults(ses.id) or {}
            for _, r in ipairs(rows) do
                if r.suggested then
                    Roll:MarkAwardedExternally(ses.id, r.key)
                    break
                end
            end
        end
    end
    for _, line in ipairs(ns.ReserveIO:WrapUpLines()) do Say("raid", line) end
end

---------------------------------------------------------------------------
-- Rolls in the demo: the reservers (and someone who didn't reserve) roll
---------------------------------------------------------------------------
local VALUES = { 88, 64, 41, 77, 23, 95, 52, 12, 70, 33 }

function RD:SimulateRolls(session)
    if not (self:IsRunning() and type(session) == "table" and session.rv) then return nil end
    local Roll = ns.Roll
    local id = session.id
    local fmt = type(RANDOM_ROLL_RESULT) == "string" and RANDOM_ROLL_RESULT ~= "" and RANDOM_ROLL_RESULT
        or "%s rolls %d (%d-%d)"
    local c = Cast()
    local who = {}
    if session.rv == "s" then
        for _, k in ipairs(session.rk or {}) do if k ~= c.me then who[#who + 1] = k end end
        if #(session.rk or {}) > 1 then who[#who + 1] = c.guild[#c.guild] end   -- (didn't reserve it)
    elseif session.rv == "g" then
        for i = 1, min(3, #c.guild) do who[#who + 1] = c.guild[i] end
        who[#who + 1] = c.pugs[2]                                         -- (a pug: not guild)
    else
        for i, k in ipairs(c.all) do if i <= 6 then who[#who + 1] = k end end
    end
    Say("rw", Roll:ReserveAnnounce(session) or ("Roll for " .. Link(session.i)))
    if session.rv == "s" and #(session.rk or {}) == 1 then return 1 end
    for i, key in ipairs(who) do
        local v = VALUES[(i + session.i) % #VALUES + 1]
        local line = strformat(fmt, Short(key), v, 1, 100)
        Later(0.8 + i * 0.7, function()
            local cur = Roll:GetActive()
            if cur and cur.id == id then
                Roll:OnSystemMessage(line)
                Say("sys", line)
            end
        end)
    end
    if session.rv == "g" and c.guild[1] then
        Later(3, function()
            local cur = Roll:GetActive()
            if cur and cur.id == id and Roll.OnDemoVote then Roll:OnDemoVote(c.me, id, c.guild[1]) end
        end)
    end
    return #who
end

---------------------------------------------------------------------------
-- Driving it
---------------------------------------------------------------------------
-- Shows step n (1..#STEPS) for the current view.
function RD:Go(n)
    n = math.max(1, math.min(#self.STEPS, tonumber(n) or 1))
    st.timers = st.timers + 1           -- (the last step's timers stop)
    st.step = n
    DO[self.STEPS[n].key]()
    ns:Fire("RESERVE_DEMO_STEP", n)
    return true
end

function RD:Next() return self:Go(st.step + 1) end
function RD:Back() return self:Go(st.step - 1) end

function RD:SetView(view)
    for _, v in ipairs(self.VIEWS) do
        if v[1] == view then st.view = view end
    end
    ns:Fire("RESERVE_DEMO_STEP", st.step)
end

function RD:Start()
    local Demo = ns.Demo
    if Demo and Demo.IsEnabled and not Demo:IsEnabled() and Demo.SetEnabled then Demo:SetEnabled(true) end
    if not Util.DemoOn() then
        ns:Print("Reserves demo: demo mode could not be turned on.")
        return false
    end
    st.on, st.cast, st.lines, st.drop, st.view = true, nil, {}, nil, "lead"
    Cast()
    ns:Print("|cffffd100Reserves demo:|r a made-up pug night in Serpentshrine Cavern. Nothing is sent or saved.")
    return self:Go(1)
end

function RD:Stop()
    st.on = false
    st.timers = st.timers + 1
    st.drop = nil
    if R() then R():SetDemo(nil) end
    if ns.Demo and ns.Demo.SetGuests then ns.Demo:SetGuests(nil) end
    ns:Fire("RESERVE_DEMO_STEP", 0)
end

function RD:OnInit()
    ns:On("DEMO_TOGGLED", function(on)
        if not on and st.on then
            st.on = false
            st.timers = st.timers + 1
            ns:Fire("RESERVE_DEMO_STEP", 0)
        end
    end)
    -- (Demo:SimulateRolls asks first: the reserves demo plays its own rolls)
    local Demo = ns.Demo
    if Demo and Demo.SimulateRolls then
        local base = Demo.SimulateRolls
        Demo.SimulateRolls = function(self, session)
            local n = RD:SimulateRolls(session)
            if n then return n end
            return base(self, session)
        end
    end
end
