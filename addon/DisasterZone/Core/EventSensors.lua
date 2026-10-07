if DisasterZoneBoot and DisasterZoneBoot.Run("Core/EventSensors.lua", ...) then return end -- DisasterZone: what my game sees while I'm in a live event.
-- While I'm an entrant of a live event (Core/EventLive.lua), my client watches what that event's pieces use
-- (EventBlocks:Senses of its def) and tells the host, a fact at a time (Live:SendFact -> EVF):
--   h      a thing that happened to me: I killed a creature (COMBAT_LOG PARTY_KILL by me or my pet), looted an item
--          (CHAT_MSG_LOOT), caught a fish (the same, from a loot window IsFishingLoot opened), died (PLAYER_DEAD),
--          mounted / dismounted (IsMounted), started / stopped moving (GetUnitSpeed), did an emote (DoEmote, echoed by
--          CHAT_MSG_TEXT_EMOTE; "You point at X." in English without the hook). Duels stay with the duel parsing.
--   place  I went into / out of one of the event's places (world yards from C_Map, about twice a second).
--   touch  I touched an entrant: a click (the target changed while the mouse was over them in the world, or the mouse
--          went down over them while they're my target already), a /point or an emote at them (the token from the
--          DoEmote / C_ChatInfo.PerformEmote hooks); near = CheckInteractDistance(.., 3) (about 10 yards).
--   radar  I targeted an entrant without clicking them (a macro, a keybind, a raid frame).
--   pos    where and how I am, only what the def uses: my position while it uses distances (every 5 s or after 20
--          yards), my zone / subzone, my World flags (flying, swimming, in combat, mounted, moving, dead), how many of
--          its items I have, the gold I gained since it began; each part when it changes (the host keeps it, never
--          sends it on).
-- The host's answer "hide friendly nameplates" comes back as EVM plates: SetPlates keeps the CVar's old value and puts
-- it back when the event ends, at logout, or at the next login after a crash.
-- Nothing is watched outside live events, in demo mode or in practice (the builder's dummies panel drives practice);
-- places are off in instances (the position APIs are too). Every game API is checked before use.
local addonName, ns = ...

local S = ns:NewModule("EventSensors")
local Util = ns.Util

local type, pairs, ipairs, tostring, tonumber, next, pcall = type, pairs, ipairs, tostring, tonumber, next, pcall
local floor, sqrt, atan2, pi, huge = math.floor, math.sqrt, math.atan2, math.pi, math.huge
local strupper = string.upper

local POLL = 0.5              -- seconds between two looks at where I am and how I move
local PLACE_SLACK = 2         -- yards past a place's edge before I count as out of it (no flicker at the edge)
local POS_MOVED = 20          -- a position goes out after this many yards ...
local POS_GAP = 2.5           -- (but not more often than this: an addon prefix carries about one message a second)
local POS_EVERY = 5           -- ... or after this long when I moved a little
local POS_STILL = 2
local POS_KEEP = 30           -- ... and at least this often (a new host learns it soon)
local TOUCH_GAP = 2           -- the same touch again within this long is one touch
local RADAR_GAP = 5
local EMOTE_WAIT = 2          -- DoEmote's token waits this long for its echo
local FISH_AFTER = 3          -- loot lines this long after a fishing window closed are still the catch
local NEAR = 3                -- CheckInteractDistance index 3: duel range, about 10 yards
local DEFAULT_RADIUS = 30     -- (a place without its own radius: EventBlocks' default)
local PLATES_CVAR = "nameplateShowFriends"
local PLATES_GRACE = 120      -- after a login: how long the event that hid my nameplates has to show up live again
local TWO_PI = 2 * pi

-- the happenings this client senses (EVENTS_KINDS.md: B.HAPPEN keys); the rest are the host's own
S.SENSED = { kill = true, loot = true, fish = true, die = true, mount = true, dismount = true, move = true, stop = true,
    emote = true }

local active = {}             -- [occId] = { def, st, senses, host, inside = { [pid] = bool }, pos, sent = {} }
local want = { happen = {}, touch = {}, radar = false, state = false, places = false, emote = false, target = false }
local sensesOf = setmetatable({}, { __mode = "k" })   -- [def] = senses
local ticker
local watched = {}            -- [event] = handler registered now
local state = {}              -- moving, mounted (my last look)
local pendingEmote
local fishUntil = 0
local lootPatterns
local platesSince = 0         -- GetTime() of the login (PLATES_GRACE)
local hooked = false

local function Me() return Util.PlayerKey() end
local function Live() return ns.EventLive end
local function B() return ns.EventBlocks end
local function DemoOn() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() or false end

local function Contains(list, v)
    if type(list) ~= "table" then return nil end
    for i = 1, #list do if list[i] == v then return i end end
    return nil
end

-- A game API that may be missing (or refuse): all its results, or nil.
local function Results(ok, ...)
    if ok then return ... end
    return nil
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    return Results(pcall(fn, ...))
end

local function InInstance()
    return Call(IsInInstance) and true or false
end

local function ZoneText() return Call(GetRealZoneText) or Call(GetZoneText) or "" end
local function SubZoneText() return Call(GetSubZoneText) or "" end

-- An entrant of the run, or its host.
local function InRun(st, key)
    return type(key) == "string" and st and (st.host == key or Contains(st.entrants, key) ~= nil) or false
end

---------------------------------------------------------------------------
-- Positions: map points, world yards, bearings (also for the host's run and the tracker's arrow)
---------------------------------------------------------------------------

-- A map's place in the world: map position -> world is affine, taken from three points (0,0, 0.5,0 and 0,0.5; 1,1 is
-- off on some maps, HereBeDragons says), so it doesn't matter which world axis a map axis runs along.
-- [map] = { cont, x0, y0, xx, xy, yx, yy } (the world point of 0,0; what a whole map x / y adds to it).
local mapRect = {}

local function RawWorld(map, x, y)
    local C = C_Map
    if not (C and C.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, cont, v = pcall(C.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
    if not ok or not cont or type(v) ~= "table" or not v.GetXY then return nil end
    local ok2, wx, wy = pcall(v.GetXY, v)
    if not ok2 or type(wx) ~= "number" or type(wy) ~= "number" then return nil end
    return cont, wx, wy
end

local function Rect(map)
    local r = mapRect[map]
    if r then return r end
    local c1, ax, ay = RawWorld(map, 0, 0)
    local c2, bx, by = RawWorld(map, 0.5, 0)
    local c3, cx, cy = RawWorld(map, 0, 0.5)
    if not c1 or c1 ~= c2 or c1 ~= c3 or (ax == bx and ay == by) or (ax == cx and ay == cy) then return nil end
    r = { cont = c1, x0 = ax, y0 = ay, xx = (bx - ax) * 2, xy = (by - ay) * 2, yx = (cx - ax) * 2, yy = (cy - ay) * 2 }
    mapRect[map] = r
    return r
end

-- A map point in the world: continent, world x (grows to the north), world y (grows to the west); nil if unknown.
function S.World(map, x, y)
    map, x, y = tonumber(map), tonumber(x), tonumber(y)
    if not (map and x and y) or x ~= x or y ~= y then return nil end
    local r = Rect(map)
    if not r then return nil end
    return r.cont, r.x0 + x * r.xx + y * r.yx, r.y0 + x * r.xy + y * r.yy
end

-- Yards between two things with map, x, y (a position, a place): nil when either is unknown or they're on two
-- continents.
function S.Yards(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return nil end
    local c1, x1, y1 = S.World(a.map, a.x, a.y)
    local c2, x2, y2 = S.World(b.map, b.x, b.y)
    if not c1 or not c2 or c1 ~= c2 then return nil end
    return sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2))
end

-- The direction from a to b: radians, 0 = north, growing counterclockwise (GetPlayerFacing's way); nil if unknown.
function S.Bearing(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return nil end
    local c1, x1, y1 = S.World(a.map, a.x, a.y)
    local c2, x2, y2 = S.World(b.map, b.x, b.y)
    if not c1 or not c2 or c1 ~= c2 then return nil end
    local north, west = x2 - x1, y2 - y1
    if north == 0 and west == 0 then return 0 end
    local ang = atan2(west, north)
    if ang < 0 then ang = ang + TWO_PI end
    return ang
end

-- Where I face: radians 0..2pi (0 = north, counterclockwise), nil where the client doesn't say (instances).
function S.Facing()
    local f = Call(GetPlayerFacing)
    if type(f) ~= "number" or f ~= f then return nil end
    f = f % TWO_PI
    return f
end

-- Where I am: { map, x, y } (0..1 on my best map), nil in instances or where the client doesn't say.
function S:MyPos()
    if InInstance() then return nil end
    local C = C_Map
    if not (C and C.GetBestMapForUnit and C.GetPlayerMapPosition) then return nil end
    local map = Call(C.GetBestMapForUnit, "player")
    if not map then return nil end
    local v = Call(C.GetPlayerMapPosition, map, "player")
    if type(v) ~= "table" or not v.GetXY then return nil end
    local x, y = Call(v.GetXY, v)
    if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then return nil end
    return { map = map, x = x, y = y }
end

local function Round(v) return floor(v * 10000 + 0.5) / 10000 end

---------------------------------------------------------------------------
-- Facts
---------------------------------------------------------------------------

local function Send(occId, fact)
    local L = Live()
    if DemoOn() or not (L and L.SendFact) then return false end
    return L:SendFact(occId, fact)
end

-- A happening, to every live event that uses it.
local function Happen(what, data)
    for occId, a in pairs(active) do
        if a.senses.happen[what] then
            local fact = { k = "h", what = what }
            for k, v in pairs(data or {}) do fact[k] = v end
            Send(occId, fact)
        end
    end
end

-- One touch (whom, how, near) at most every TOUCH_GAP seconds.
local function Touch(occId, a, whom, how, near, emote)
    local key = "t" .. whom .. how .. (near and "1" or "0") .. (emote or "")
    if GetTime() - (a.sent[key] or -100) < TOUCH_GAP then return end
    a.sent[key] = GetTime()
    Send(occId, { k = "touch", whom = whom, how = how, near = near and true or false, emote = emote })
end

local function Radar(occId, a, whom)
    local key = "r" .. whom
    if GetTime() - (a.sent[key] or -100) < RADAR_GAP then return end
    a.sent[key] = GetTime()
    Send(occId, { k = "radar", whom = whom })
end

---------------------------------------------------------------------------
-- Touches: clicks, targets, emotes
---------------------------------------------------------------------------

-- The mouse is over a unit frame (a raid frame, a party frame, the target frame): "mouseover" is set there too, but
-- that isn't a click in the world. Nameplates count as the world.
local function FocusIsUnitFrame()
    local focus
    if GetMouseFoci then
        local list = Call(GetMouseFoci)
        focus = type(list) == "table" and list[1] or nil
    elseif GetMouseFocus then
        focus = Call(GetMouseFocus)
    end
    if type(focus) ~= "table" or focus == WorldFrame then return false end
    local ok, unit = pcall(function()
        if focus.IsForbidden and focus:IsForbidden() then return nil end
        return (focus.GetAttribute and focus:GetAttribute("unit")) or rawget(focus, "unit")
    end)
    if not ok then return false end
    return type(unit) == "string" and not unit:find("^nameplate")
end

-- My target, as a touch (a click: the mouse over them in the world) or radar (no click) for the events they're in.
local function Targeted(clickOnly)
    if not Call(UnitIsPlayer, "target") then return end
    local whom = Util.UnitKey("target")
    if not whom or whom == Me() then return end
    local click = Call(UnitIsUnit, "mouseover", "target") and not FocusIsUnitFrame()
    if clickOnly and not click then return end
    local near = click and Call(CheckInteractDistance, "target", NEAR) and true or false
    for occId, a in pairs(active) do
        if InRun(a.st, whom) then
            if click and a.senses.touch.click then
                Touch(occId, a, whom, "click", near)
            elseif not click and a.senses.radar then
                Radar(occId, a, whom)
            end
        end
    end
end

local function OnTargetChanged()
    if want.target then Targeted(false) end
end

-- A click on the player who is my target already (the target doesn't change, so PLAYER_TARGET_CHANGED stays quiet):
-- the mouse goes down over them in the world.
local function OnMouseDown(_, button)
    if not want.touch.click or (button ~= "LeftButton" and button ~= "RightButton") then return end
    if Call(UnitIsPlayer, "mouseover") and Call(UnitIsUnit, "mouseover", "target") then Targeted(true) end
end

-- A unit token for a player I can measure to: my target, the mouseover, or a member of my group.
local function UnitOf(key)
    for _, u in ipairs({ "target", "mouseover" }) do
        if Call(UnitExists, u) and Util.UnitKey(u) == key then return u end
    end
    local n = Call(GetNumGroupMembers) or 0
    local raid = Call(IsInRaid)
    for i = 1, n do
        local u = raid and ("raid" .. i) or ("party" .. i)
        if Call(UnitExists, u) and Util.UnitKey(u) == key then return u end
    end
    return nil
end

local function NearTo(key)
    local unit = key and UnitOf(key)
    return unit and Call(CheckInteractDistance, unit, NEAR) and true or false
end

-- A name as typed ("/point bert"): its key (names start with a capital, the rest small).
local function TypedName(s)
    local name, realm = Util.Trim(s):match("^([^%-%s]+)%-?(%S*)$")
    if not name then return nil end
    name = Util.CapitalizeName(name)
    return Util.NormalizeName(realm ~= "" and (name .. "-" .. realm) or name)
end

-- DoEmote(token, target): what I did and at whom (a name I typed, a unit, else my target). Its echo
-- (CHAT_MSG_TEXT_EMOTE) says it happened.
local function OnDoEmote(token, target)
    if not want.emote or type(token) ~= "string" or token == "" then return end
    local who
    if type(target) == "string" and target ~= "" then
        if Call(UnitExists, target) then
            who = Call(UnitIsPlayer, target) and Util.UnitKey(target) or nil
        else
            who = TypedName(target)
        end
    elseif Call(UnitIsPlayer, "target") then
        who = Util.UnitKey("target")
    end
    pendingEmote = { token = strupper(token), who = who, at = GetTime() }
end

-- English without the hook: "You point at Bert." -> POINT, Bert.
function S.ParseEmote(text)
    if type(text) ~= "string" then return nil end
    local verb, name = text:match("^You (%a+) at (.-)%.$")
    if not verb or name == "" then return nil end
    return strupper(verb), Util.NormalizeName(name)
end

local function OnTextEmote(_, text, sender)
    if not want.emote or Util.NormalizeName(sender) ~= Me() then return end
    local token, who
    local p = pendingEmote
    pendingEmote = nil
    if p and GetTime() - p.at <= EMOTE_WAIT then
        token, who = p.token, p.who
    else
        local locale = Call(GetLocale) or "enUS"
        if locale ~= "enUS" and locale ~= "enGB" then return end
        token, who = S.ParseEmote(text)
    end
    if not token then return end
    if who == Me() then who = nil end
    local near
    for occId, a in pairs(active) do
        -- (its target only when they're in that event)
        local whom = who and InRun(a.st, who) and who or nil
        if a.senses.happen.emote then Send(occId, { k = "h", what = "emote", emote = token, other = whom }) end
        if whom and (a.senses.touch.point or a.senses.touch.emote) then
            if near == nil then near = NearTo(whom) end
            if token == "POINT" and a.senses.touch.point then Touch(occId, a, whom, "point", near) end
            if a.senses.touch.emote then Touch(occId, a, whom, "emote", near, token) end
        end
    end
end

---------------------------------------------------------------------------
-- Kills, loot, fish, deaths
---------------------------------------------------------------------------

local function OnCombatLog()
    if not want.happen.kill then return end
    local _, sub, _, src, _, _, _, dst, dstName = Call(CombatLogGetCurrentEventInfo)
    if sub ~= "PARTY_KILL" or type(src) ~= "string" then return end
    if src ~= Call(UnitGUID, "player") and src ~= Call(UnitGUID, "pet") then return end
    if type(dst) ~= "string" or dst:find("^Player") then return end   -- creatures only
    Happen("kill", { creature = type(dstName) == "string" and dstName or nil })
end

-- "You receive loot: %s." (and "...: %sx%d.") as Lua patterns (any language): { {pat, multiple} }.
local function FormatToPattern(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    fmt = fmt:gsub("%%%d+%$", "%%")
    local out, i, n = {}, 1, #fmt
    while i <= n do
        local c = fmt:sub(i, i)
        local nx = fmt:sub(i + 1, i + 1)
        if c == "%" and nx == "s" then
            out[#out + 1] = "(.+)"; i = i + 2
        elseif c == "%" and nx == "d" then
            out[#out + 1] = "(%d+)"; i = i + 2
        elseif c:find("^[%^%$%(%)%%%.%[%]%*%+%-%?]$") then
            out[#out + 1] = "%" .. c; i = i + 1
        else
            out[#out + 1] = c; i = i + 1
        end
    end
    return "^" .. table.concat(out) .. "$"
end

-- link, count of a loot line of mine, or nil.
function S.ParseLoot(text)
    if type(text) ~= "string" then return nil end
    if not lootPatterns then
        lootPatterns = {}
        for _, name in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF" }) do
            local pat = FormatToPattern(rawget(_G, name))
            if pat then lootPatterns[#lootPatterns + 1] = pat end
        end
    end
    for _, pat in ipairs(lootPatterns) do
        local ok, link, count = pcall(string.match, text, pat)
        if ok and link then return link, tonumber(count) or 1 end
    end
    return nil
end

local function OnLoot(_, text)
    if not (want.happen.loot or want.happen.fish) then return end
    local link, count = S.ParseLoot(text)
    if not link then return end
    local data = { item = tonumber(link:match("item:(%d+)")), name = link:match("%[(.-)%]"), count = count }
    if not data.item and not data.name then return end
    if GetTime() <= fishUntil then Happen("fish", data) end
    Happen("loot", data)
end

local function OnLootOpened()
    fishUntil = Call(IsFishingLoot) and huge or 0
end

local function OnLootClosed()
    if fishUntil == huge then fishUntil = GetTime() + FISH_AFTER end
end

local function OnDead() Happen("die", nil) end

---------------------------------------------------------------------------
-- Places, movement, position (polled)
---------------------------------------------------------------------------

-- In this place? true / false, nil when it can't be told (where I am isn't known).
local function Inside(p, me, was)
    if p.map and p.x and p.y then
        if not me then return nil end
        local c1, x1, y1 = S.World(p.map, p.x, p.y)
        local c2, x2, y2 = S.World(me.map, me.x, me.y)
        if not c1 or not c2 then return nil end
        if c1 ~= c2 then return false end
        local d = sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2))
        local r = tonumber(p.r) or DEFAULT_RADIUS
        return d <= r + (was and PLACE_SLACK or 0)
    elseif type(p.sz) == "string" and p.sz ~= "" then
        return SubZoneText() == p.sz
    elseif type(p.z) == "string" and p.z ~= "" then
        return ZoneText() == p.z
    end
    return nil
end

local function UpdatePlaces(occId, a, me, instance)
    local places = type(a.def.places) == "table" and a.def.places or {}
    -- a new host (a takeover, a handover) doesn't know where I am: the places I'm in again
    if a.placesHost ~= a.host then
        a.placesHost = a.host
        for pid, inside in pairs(a.inside) do
            if inside and a.senses.places[pid] then Send(occId, { k = "place", pid = pid, ["in"] = true }) end
        end
    end
    for pid in pairs(a.senses.places) do
        local p = places[pid]
        if type(p) == "table" then
            local was = a.inside[pid]
            local now
            if instance then now = false else now = Inside(p, me, was) end
            if now ~= nil then
                if now ~= (was or false) or was == nil then
                    a.inside[pid] = now
                    -- (never a first "out": a place I wasn't in is where I'm not)
                    if now or was then Send(occId, { k = "place", pid = pid, ["in"] = now }) end
                end
            end
        end
    end
end

-- My World flags as the run keeps them (EventEngine Run:Pos): flying, swimming, in combat, mounted, moving, dead.
local function Flags()
    local speed = tonumber((Call(GetUnitSpeed, "player"))) or 0
    return { fl = Call(IsFlying) and true or false, sw = Call(IsSwimming) and true or false,
        cb = Call(UnitAffectingCombat, "player") and true or false, mt = Call(IsMounted) and true or false,
        mv = speed > 0, dd = Call(UnitIsDeadOrGhost, "player") and true or false }
end

-- Copper gained since the event began for me (kept across a /reload: db.eventMoney[occId]).
local function GoldGained(occId)
    local money = tonumber((Call(GetMoney)))
    local db = ns.db
    if not money or not db then return nil end
    db.eventMoney = type(db.eventMoney) == "table" and db.eventMoney or {}
    local start = tonumber(db.eventMoney[occId])
    if not start then
        start = money
        db.eventMoney[occId] = money
    end
    return money - start
end

local ITEMS_EVERY = 2   -- seconds between two counts of the items an event asks about

-- Where I am and how I am, as the event uses it: one "pos" fact with what changed (a position by POS_* rules; the
-- zone / subzone, flags, item counts and gold whenever they change; everything again for a new host).
local function UpdateState(occId, a, me, instance)
    local s = a.senses
    local fact, any = { k = "pos" }, false
    local now = GetTime()
    local newHost = a.sentHost ~= a.host
    local sent = a.state
    if newHost then
        sent = {}
        a.state = sent
        a.pos, a.itemsAt = nil, nil
        a.sentHost = a.host
    end
    -- the position (not in instances: there, once, that it isn't known; out again, at once)
    if s.pos and instance then
        if not sent.inst then
            fact.inst, sent.inst = true, true
            a.pos = nil
            any = true
        end
    elseif s.pos and me then
        sent.inst = nil
        local cont, wx, wy = S.World(me.map, me.x, me.y)
        if cont then
            local last = a.pos
            local moved = (last and last.cont == cont) and sqrt((wx - last.wx) ^ 2 + (wy - last.wy) ^ 2) or huge
            local since = last and now - last.at or huge
            if not last or (moved >= POS_MOVED and since >= POS_GAP) or (since >= POS_EVERY and moved >= POS_STILL)
                or since >= POS_KEEP then
                a.pos = { cont = cont, wx = wx, wy = wy, at = now }
                fact.map, fact.x, fact.y = me.map, Round(me.x), Round(me.y)
                fact.cont, fact.wx, fact.wy = cont, floor(wx * 10 + 0.5) / 10, floor(wy * 10 + 0.5) / 10
                any = true
            end
        end
    end
    -- the zone and subzone
    if s.zone or s.pos then
        local z, sz = ZoneText(), SubZoneText()
        if z ~= sent.z or sz ~= sent.sz or fact.map then
            fact.z, fact.sz = z, sz
            sent.z, sent.sz = z, sz
            any = true
        end
    end
    -- flying, swimming, in combat, mounted, moving, dead (all of them while the def asks "is ..."; else the ones its
    -- happenings keep, once for each host: mounting and moving are facts of their own)
    if s.flags then
        for f, v in pairs(Flags()) do
            if sent[f] ~= v then
                fact[f], sent[f] = v, v
                any = true
            end
        end
    elseif not sent.flagsOnce then
        sent.flagsOnce = true
        local fl = Flags()
        local h = s.happen
        if h.mount or h.dismount then fact.mt = fl.mt; any = true end
        if h.move or h.stop then fact.mv = fl.mv; any = true end
        if h.die then fact.dd = fl.dd; any = true end
    end
    -- how many of the items it asks about I have
    if next(s.items) and now - (a.itemsAt or -100) >= ITEMS_EVERY then
        a.itemsAt = now
        local items, changed = {}, false
        sent.items = sent.items or {}
        for item in pairs(s.items) do
            local n = tonumber((Call(GetItemCount, item))) or 0
            items[tostring(item)] = n
            if sent.items[tostring(item)] ~= n then changed = true end
        end
        if changed then
            fact.items, sent.items = items, items
            any = true
        end
    end
    -- the gold gained since it began
    if s.gold then
        local g = GoldGained(a.occId or occId)
        if g and g ~= sent.gold then
            fact.gold, sent.gold = g, g
            any = true
        end
    end
    if any then Send(occId, fact) end
end

local function Look(name, sensed, on, onWhat, offWhat)
    if not sensed then
        state[name] = nil
        return
    end
    if state[name] ~= nil and state[name] ~= on then Happen(on and onWhat or offWhat, nil) end
    state[name] = on
end

---------------------------------------------------------------------------
-- Friendly nameplates (EVM plates)
---------------------------------------------------------------------------

local function GetPlates()
    local get = (C_CVar and C_CVar.GetCVar) or GetCVar
    local v = Call(get, PLATES_CVAR)
    return v ~= nil and tostring(v) or nil
end

local function SetPlatesCVar(v)
    local set = (C_CVar and C_CVar.SetCVar) or SetCVar
    if type(set) ~= "function" then return false end
    local ok, res = pcall(set, PLATES_CVAR, v)
    return ok and res ~= false
end

local function OnRegen()
    ns:UnregisterEvent("PLAYER_REGEN_ENABLED", OnRegen)
    S:ApplyPlates()
end

-- Hidden while an event wants it, else back as they were (never in combat: the client refuses it; at its end).
function S:ApplyPlates(leaving)
    local db = ns.db
    local rec = db and type(db.eventPlates) == "table" and db.eventPlates or nil
    if not rec then return end
    if type(rec.occs) ~= "table" then rec.occs = {} end
    if Call(InCombatLockdown) then
        ns:RegisterEvent("PLAYER_REGEN_ENABLED", OnRegen)
        return
    end
    local cur = GetPlates()
    if next(rec.occs) and not leaving then
        if cur ~= "0" and SetPlatesCVar("0") then cur = "0" end
        rec.on = cur == "0"
        return
    end
    -- back as they were (kept while logging out: hidden again after a /reload if the event still runs)
    if rec.on and cur ~= rec.was then SetPlatesCVar(rec.was) end
    rec.on = false
    if not leaving then db.eventPlates = nil end
end

-- The host says: hide (off = true) or show my friendly nameplates again for this event.
function S:SetPlates(occId, off)
    local db = ns.db
    if not db or DemoOn() or type(occId) ~= "string" then return end
    local rec = type(db.eventPlates) == "table" and db.eventPlates or nil
    if off then
        local L = Live()
        local st = L and L.GetState and L:GetState(occId)
        if not (st and st.phase == "live" and Contains(st.entrants, Me())) then return end
        if not rec then
            local was = GetPlates()
            if not was then return end
            rec = { was = was, occs = {} }
            db.eventPlates = rec
        end
        rec.occs[occId] = true
    elseif rec and type(rec.occs) == "table" then
        rec.occs[occId] = nil
    end
    self:ApplyPlates()
    self:Refresh()
end

function S:PlatesHidden()
    local db = ns.db
    local rec = db and type(db.eventPlates) == "table" and db.eventPlates
    return rec and rec.on and true or false
end

-- Events that hid them and aren't live for me any more let go (after a login: once they had time to show up).
local function CheckPlates()
    local db = ns.db
    local rec = db and type(db.eventPlates) == "table" and db.eventPlates
    if not rec then return false end
    local L = Live()
    for occId in pairs(type(rec.occs) == "table" and rec.occs or {}) do
        local st = L and L.GetState and L:GetState(occId)
        local mine = st and st.phase == "live" and Contains(st.entrants, Me()) and not DemoOn()
        if not mine and (st or GetTime() - platesSince >= PLATES_GRACE or DemoOn()) then rec.occs[occId] = nil end
    end
    S:ApplyPlates()
    return db.eventPlates ~= nil
end

---------------------------------------------------------------------------
-- What to watch
---------------------------------------------------------------------------

local function Watch(event, fn, on)
    if on and not watched[event] then
        if ns:RegisterEvent(event, fn) then watched[event] = fn end
    elseif not on and watched[event] then
        ns:UnregisterEvent(event, watched[event])
        watched[event] = nil
    end
end

-- What a def's entrants watch (EventBlocks:Senses), every part a table / boolean.
local function SensesOf(def)
    local s = sensesOf[def]
    if s ~= nil then return s or nil end
    local Bk = B()
    local raw
    if Bk and Bk.Senses then
        local ok, res = pcall(Bk.Senses, Bk, def)
        raw = ok and type(res) == "table" and res or nil
    end
    if not raw then
        sensesOf[def] = false
        return nil
    end
    local function set(t)
        local out = {}
        for k, v in pairs(type(t) == "table" and t or {}) do if v then out[k] = true end end
        return out
    end
    s = { happen = set(raw.happen), places = set(raw.places), touch = set(raw.touch), radar = raw.radar and true or false,
        pos = raw.pos and true or false, zone = raw.zone and true or false, flags = raw.flags and true or false,
        items = set(raw.items), gold = raw.gold and true or false, asks = raw.asks and true or false,
        buttons = raw.buttons and true or false }
    sensesOf[def] = s
    return s
end
S.SensesOf = SensesOf

local function Poll()
    if DemoOn() then
        S:Refresh()
        return
    end
    local any = next(active) ~= nil
    if any then
        if want.happen.move or want.happen.stop then
            local speed = Call(GetUnitSpeed, "player")
            Look("moving", true, (tonumber(speed) or 0) > 0, "move", "stop")
        end
        if want.happen.mount or want.happen.dismount then
            Look("mounted", true, Call(IsMounted) and true or false, "mount", "dismount")
        end
        if want.places or want.state then
            local instance = InInstance()
            local me = not instance and S:MyPos() or nil
            for occId, a in pairs(active) do
                if next(a.senses.places) then UpdatePlaces(occId, a, me, instance) end
                if a.wantsState then UpdateState(occId, a, me, instance) end
            end
        end
    end
    local plates = CheckPlates()
    if not plates and not (want.poll and any) and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function EnsureTicker()
    if ticker or not (C_Timer and C_Timer.NewTicker) then return end
    ticker = C_Timer.NewTicker(POLL, Poll)
end

-- Which live events I'm in and what they use; (un)registers what that needs.
function S:Refresh()
    local L = Live()
    local mine = (not DemoOn() and L and L.MyLiveEvents) and L:MyLiveEvents() or {}
    local new = {}
    for occId, st in pairs(mine) do
        local def = L:GetDef(occId)
        local senses = type(def) == "table" and SensesOf(def)
        if senses then
            -- (one record a live event: its def's table may be a new copy of the same event after a sync)
            local a = active[occId] or { inside = {}, sent = {}, state = {} }
            -- (host: who runs it, and how often its run was started again: a host's /reload is a new host to tell
            -- the places I'm in and where I am)
            a.def, a.st, a.senses = def, st, senses
            a.host = tostring(st.host) .. "#" .. tostring(tonumber(st.boot) or 0)
            local h = senses.happen
            a.wantsState = (senses.pos or senses.zone or senses.flags or senses.gold or next(senses.items) or h.mount
                or h.dismount or h.move or h.stop or h.die) and true or false
            new[occId] = a
        end
    end
    active = new
    local w = { happen = {}, touch = {}, radar = false, state = false, places = false }
    for _, a in pairs(active) do
        for k in pairs(a.senses.happen) do if S.SENSED[k] then w.happen[k] = true end end
        for k in pairs(a.senses.touch) do w.touch[k] = true end
        if a.senses.radar then w.radar = true end
        if a.wantsState then w.state = true end
        if next(a.senses.places) then w.places = true end
    end
    -- (the gold an event counts from: let go once it isn't live for me)
    local db = ns.db
    if db and type(db.eventMoney) == "table" then
        for occId in pairs(db.eventMoney) do
            if not new[occId] and not (L and L.GetState and L:GetState(occId)) then db.eventMoney[occId] = nil end
        end
        if not next(db.eventMoney) then db.eventMoney = nil end
    end
    w.emote = (w.happen.emote or w.touch.point or w.touch.emote) and true or false
    w.target = (w.touch.click or w.radar) and true or false
    w.poll = (w.places or w.state or w.happen.move or w.happen.stop or w.happen.mount or w.happen.dismount) and true or false
    if not (w.happen.move or w.happen.stop) then state.moving = nil end
    if not (w.happen.mount or w.happen.dismount) then state.mounted = nil end
    want = w
    Watch("PLAYER_TARGET_CHANGED", OnTargetChanged, w.target)
    Watch("GLOBAL_MOUSE_DOWN", OnMouseDown, w.touch.click)
    Watch("CHAT_MSG_TEXT_EMOTE", OnTextEmote, w.emote)
    Watch("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog, w.happen.kill)
    Watch("CHAT_MSG_LOOT", OnLoot, w.happen.loot or w.happen.fish)
    Watch("LOOT_OPENED", OnLootOpened, w.happen.fish)
    Watch("LOOT_CLOSED", OnLootClosed, w.happen.fish)
    Watch("PLAYER_DEAD", OnDead, w.happen.die)
    -- (an emote's token in any language: DoEmote, and C_ChatInfo.PerformEmote where the client has it)
    if w.emote and not hooked and hooksecurefunc then
        hooked = true
        if type(DoEmote) == "function" then
            pcall(hooksecurefunc, "DoEmote", function(token, target) OnDoEmote(token, target) end)
        end
        if type(C_ChatInfo) == "table" and type(C_ChatInfo.PerformEmote) == "function" then
            pcall(hooksecurefunc, C_ChatInfo, "PerformEmote", function(token, target) OnDoEmote(token, target) end)
        end
    end
    if (w.poll and next(active)) or (db and db.eventPlates) then
        EnsureTicker()
        if w.poll then Poll() end
    end
end

-- (harness / debugging)
function S:_State() return active, want end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function S:OnInit()
    ns:On("EVENT_LIVE_UPDATED", function() Util.Debounce("event-sensors", 0.2, function() S:Refresh() end) end)
    ns:On("DEMO_TOGGLED", function() S:Refresh() end)
    -- (at logout friendly nameplates go back as they were; a /reload hides them again if the event still runs)
    ns:RegisterEvent("PLAYER_LOGOUT", function() S:ApplyPlates(true) end)
end

function S:OnLogin()
    platesSince = GetTime()
    local db = ns.db
    local rec = db and db.eventPlates
    if rec ~= nil and type(rec) ~= "table" then db.eventPlates = nil end
    -- a crash left them hidden: back now (the event, if it still runs, hides them again)
    if type(db and db.eventPlates) == "table" then
        S:ApplyPlates(true)
        EnsureTicker()
    end
end
