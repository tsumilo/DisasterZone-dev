if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Init.lua", ...) then return end -- DisasterZone: namespace bootstrap.
-- Module registry + lifecycle (OnInit / OnLogin), event dispatcher, internal message bus,
-- slash commands and Print / Debug output. Every other file builds on this one.
local addonName, ns = ...

DisasterZone = ns                       -- the ONE debugging global
ns.name = addonName               -- "DisasterZone"
ns.MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"   -- the core's art (a game pack's own art is in its folder)
-- The boot loader (Core/Boot.lua); nil when the TOC does not list it. While an in-game update is running,
-- ns.version is that update's version and ns.diskVersion the installed release it runs on top of.
local Boot = DisasterZoneBoot
ns.diskVersion = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "0.0.0"
ns.version = (Boot and Boot.applied and Boot.applied.version) or ns.diskVersion
ns.assetPack = (Boot and Boot.assetPack) or 0   -- number of the art set installed on disk (Core/BuildInfo.lua)
ns.PROTO = 1                      -- wire protocol major (matches TOC X-CDL-Protocol)
ns.initialized = false            -- true once OnInit has been dispatched
ns.loggedIn = false               -- true right before OnLogin is dispatched

local type, pairs, ipairs, select, tostring, tonumber = type, pairs, ipairs, select, tostring, tonumber
local tinsert, tsort, tconcat = table.insert, table.sort, table.concat
local strformat, strlower = string.format, string.lower

local CHAT_PREFIX = "|cffff8000DisasterZone|r: "

-- True when the art set on disk is at least number n. Code that needs art added in set n must check this:
-- an in-game update delivers code, never art, so a member may run this code with an older art set.
function ns:HasAssets(n)
    return ns.assetPack >= (tonumber(n) or 0)
end

---------------------------------------------------------------------------
-- Protected calls
---------------------------------------------------------------------------

local function FallbackErrorHandler(err)
    local frame = DEFAULT_CHAT_FRAME
    if frame then
        frame:AddMessage(CHAT_PREFIX .. "|cffff3333error:|r " .. tostring(err))
    end
    return err
end

local CatchError    -- (below, "Errors": DisasterZone's own errors go to the feedback, never on screen)

local function ErrorHandler()
    if CatchError then return CatchError end
    local h = geterrorhandler and geterrorhandler()
    return h or FallbackErrorHandler
end

-- xpcall(fn, geterrorhandler(), ...) that also works on plain Lua 5.1, whose xpcall
-- does not forward extra arguments. The error handler is looked up per call so that
-- error-catching addons installed later are honoured.
-- Every event and message goes through here, so it makes no garbage: the game's xpcall forwards the arguments
-- (checked once); on plain 5.1 they wait in a slot per nesting depth (a handler may fire another event), read by
-- that depth's runner - both made once, the slot emptied after the call. (A table and a closure per call were the
-- addon's steadiest garbage.)
local XPCALL_ARGS = select(2, xpcall(function(v) return v end, FallbackErrorHandler, true)) == true
local SafeCall
if XPCALL_ARGS then
    SafeCall = function(fn, ...)
        return xpcall(fn, ErrorHandler(), ...)
    end
else
    local depth, slots, runners = 0, {}, {}
    local function Finish(d, ...)
        local s = slots[d]
        for i = 1, s.n do s[i] = nil end
        s.fn, s.n = nil, 0
        depth = d - 1
        return ...
    end
    SafeCall = function(fn, ...)
        local n = select("#", ...)
        if n == 0 then
            return xpcall(fn, ErrorHandler())
        end
        local d = depth + 1
        depth = d
        local s = slots[d]
        if not s then
            s = { n = 0 }
            slots[d] = s
            runners[d] = function() return s.fn(unpack(s, 1, s.n)) end
        end
        s.fn, s.n = fn, n
        for i = 1, n do s[i] = (select(i, ...)) end
        return Finish(d, xpcall(runners[d], ErrorHandler()))
    end
end
ns.SafeCall = SafeCall

---------------------------------------------------------------------------
-- Errors: DisasterZone's own Lua errors never reach the screen (the game's error window, BugSack). They go to the
-- feedback (Core/Feedback.lua sets the sink: ns:SetErrorSink), which reports them to the developer; other addons'
-- errors pass through untouched. Three ways in:
--   * our protected calls (events, messages, OnInit / OnLogin: SafeCall above) use CatchError as their handler;
--   * without BugGrabber, the game's error handler is wrapped (frame scripts, timers, everything else);
--   * BugGrabber keeps the error handler to itself (seterrorhandler does nothing once it loaded): its new errors are
--     looked at (EventRegistry "BugGrabber.BugGrabbed"), ours taken out of its list, and every other listener of that
--     event (BugSack's sound, chat line and window, the error icons of UI packs) skips them.
-- The sink may say no (the developer's own characters): such an error shows the usual way.
---------------------------------------------------------------------------

local strfind, strmatch, strgsub, tremove = string.find, string.match, string.gsub, table.remove

local errorSink         -- function(msg, stack, count, locals) -> true (taken) | false (show it the usual way)
local errorMode         -- "handler" (the game's handler wrapped) | "buggrabber" | nil
local waiting = {}      -- errors caught before the sink was set (load time) or while it was busy: { msg, stack, ... }
local inSink = false
local gameHook          -- our wrapper of the game's error handler

-- The file a message or a stack line starts with ("Interface/AddOns/X/y.lua"), "[C]" for the game's C code, or nil.
local function PathOf(line)
    line = strgsub(line, "\\", "/")
    return strmatch(line, '^%s*%[string "@([^"]+)"%]') or strmatch(line, "^%s*([^%s:]+%.lua):%d")
        or strmatch(line, "^%s*(%[C%])") or (strmatch(line, '^%s*%[string "=%[C%]"%]') and "[C]")
end

local function IsGameCode(path)
    return path == "[C]" or strfind(path, "FrameXML/", 1, true) or strfind(path, "SharedXML", 1, true)
        or strfind(path, "AddOns/Blizzard_", 1, true)
end

local function IsOursPath(path)
    return strfind(path, "AddOns/DisasterZone", 1, true) ~= nil or strfind(path, "^DisasterZone") ~= nil
end

-- Is a Lua error DisasterZone's? Its message starts with the file it happened in: ours when that is one of our files.
-- One in the game's own code (or without a place) is ours when the first addon code down the stack is ours; a
-- blocked action names its addon.
local function OwnsError(msg, stack)
    if type(msg) ~= "string" then msg = tostring(msg) end
    local name = strmatch(msg, "AddOn '([^']+)' tried")
    if name then return strfind(name, "^DisasterZone") ~= nil end
    local p = PathOf(msg)
    if p and not IsGameCode(p) then return IsOursPath(p) end
    if type(stack) == "string" then
        for line in string.gmatch(stack, "[^\n]+") do
            local q = PathOf(line)
            if q and not IsGameCode(q) then return IsOursPath(q) end
        end
    end
    return strfind(strgsub(msg, "\\", "/"), "AddOns/DisasterZone", 1, true) ~= nil
end
ns.OwnsError = OwnsError

-- Shows an error the usual way (the sink said no, or failed).
local function ShowError(msg)
    local h = geterrorhandler and geterrorhandler()
    if h then pcall(h, msg) else FallbackErrorHandler(msg) end
end

-- The errors that waited: to the sink now (each one at most once; new ones wait for the next turn).
local function Drain()
    if not errorSink or inSink or not waiting[1] then return end
    local list = waiting
    waiting = {}
    for _, w in ipairs(list) do
        inSink = true
        local ok, taken = pcall(errorSink, w[1], w[2], w[3], w[4])
        inSink = false
        if not (ok and taken) then ShowError(w[1]) end
    end
end

-- An error from any of the ways in. True: it was ours and is taken (it must not show); false: show it.
local function Take(msg, stack, count, locals)
    if not OwnsError(msg, stack) then return false end
    local tap = ns.errorTap         -- (the test harness records every error caught here; nil in the game)
    if tap then pcall(tap, msg, stack) end
    if not errorSink or inSink then
        -- (load time, or an error inside the sink's own work: it waits)
        if #waiting < 20 then waiting[#waiting + 1] = { msg, stack, count, locals } end
        return true
    end
    inSink = true
    local ok, taken = pcall(errorSink, msg, stack, count, locals)
    inSink = false
    Drain()
    -- (a sink that failed: the error shows rather than being lost)
    return (ok and taken) and true or false
end

-- The stack and locals of the error being handled (called straight from a handler: level 3 is where it happened,
-- as BugGrabber reads it). Locals only for a message not seen just before and never in a boss fight (they can take
-- long to read).
local lastLocals
local function Locals(msg)
    if msg == lastLocals or not debuglocals or (IsEncounterInProgress and IsEncounterInProgress()) then return nil end
    lastLocals = msg
    local ok, l = pcall(debuglocals, 4)
    return ok and l or nil
end

CatchError = function(msg)
    local stack = debugstack and debugstack(3, 12, 0) or nil
    local ok, taken = pcall(Take, msg, stack, nil, Locals(msg))
    if ok and taken then return msg end
    local h = geterrorhandler and geterrorhandler()
    if h then return h(msg) end
    return FallbackErrorHandler(msg)
end

-- Without BugGrabber: our wrapper around the game's handler (the one before keeps every other error).
local function HookGameHandler()
    if not (geterrorhandler and seterrorhandler) then return false end
    local prev = geterrorhandler()
    if gameHook and prev == gameHook then return true end
    local busy = false
    local hook
    hook = function(msg, ...)
        if busy then return msg end
        busy = true
        local stack = debugstack and debugstack(3, 12, 0) or nil
        local ok, taken = pcall(Take, msg, stack, nil, Locals(msg))
        busy = false
        if ok and taken then return msg end
        if prev then return prev(msg, ...) end
        return msg
    end
    seterrorhandler(hook)
    if geterrorhandler() ~= hook then return false end     -- (BugGrabber keeps the handler to itself)
    gameHook = hook
    return true
end

local BG_EVENT = "BugGrabber.BugGrabbed"
local bgOwner = {}
local claimed, claimedN = {}, 0     -- [error table id] = BugGrabber's error table we took (kept: the id is never reused)
local quieted = setmetatable({}, { __mode = "k" })

-- One of BugGrabber's errors, by the id its event names. Ours is taken out of its list. True when ours.
local function ClaimBug(id)
    if type(id) ~= "string" then return false end
    if claimed[id] then return true end
    local BG = BugGrabber
    local db = type(BG) == "table" and BG.GetDB and BG:GetDB()
    if type(db) ~= "table" then return false end
    for i = #db, 1, -1 do
        local e = db[i]
        if tostring(e) == id then
            if type(e) ~= "table" or not Take(e.message, e.stack, e.counter, e.locals) then return false end
            tremove(db, i)
            if claimedN >= 200 then claimed, claimedN = {}, 0 end
            claimed[id], claimedN = e, claimedN + 1
            return true
        end
    end
    return false
end

-- Every other listener of BugGrabber's new errors skips ours. EventRegistry keeps them per event as [owner] = fn (a
-- closure is called with the error's id, a plain function with its owner and then the id); each is wrapped once.
local function QuietListeners()
    local reg = EventRegistry
    local tables = type(reg) == "table" and reg.GetCallbackTables and reg:GetCallbackTables()
    if type(tables) ~= "table" then return end
    for _, byEvent in pairs(tables) do
        local list = type(byEvent) == "table" and byEvent[BG_EVENT]
        if type(list) == "table" then
            for owner, fn in pairs(list) do
                if owner ~= bgOwner and type(fn) == "function" and not quieted[fn] then
                    local orig = fn
                    local wrap = function(a, b, ...)
                        local ok, mine = pcall(ClaimBug, type(a) == "string" and a or b)
                        if ok and mine then return end
                        return orig(a, b, ...)
                    end
                    quieted[wrap] = true
                    list[owner] = wrap
                end
            end
        end
    end
end

local function HookBugGrabber()
    local BG = BugGrabber
    if type(BG) ~= "table" then return false end
    local reg = EventRegistry
    if type(reg) == "table" and reg.RegisterCallback then
        pcall(reg.RegisterCallback, reg, BG_EVENT, function(_, id) pcall(ClaimBug, id) end, bgOwner)
        -- (a display that loads later says so: quiet it too)
        pcall(reg.RegisterCallback, reg, "BugGrabber.DisplayRegistered", function() pcall(QuietListeners) end, bgOwner)
        pcall(QuietListeners)
        return true
    end
    -- an older BugGrabber (CallbackHandler): its error table comes with the callback
    if type(BG.RegisterCallback) == "function" then
        return (pcall(BG.RegisterCallback, ns, "BugGrabber_BugGrabbed", function(_, e) pcall(ClaimBug, tostring(e)) end))
    end
    return false
end

local function HookErrors()
    if errorMode ~= "buggrabber" and HookBugGrabber() then
        errorMode = "buggrabber"
    elseif errorMode == "buggrabber" then
        pcall(QuietListeners)
    elseif HookGameHandler() then
        errorMode = "handler"
    end
end
HookErrors()

-- Feedback's sink (Core/Feedback.lua): every error of ours goes to it; what waited since load goes now.
function ns:SetErrorSink(fn)
    errorSink = type(fn) == "function" and fn or nil
    Drain()
end

function ns:ErrorMode() return errorMode end

do
    -- At login: a BugGrabber that loaded after us (inside a UI pack), a display that registered late, another
    -- addon's handler put over ours. A blocked action of ours is told to the sink when BugGrabber isn't there to
    -- catch it (the game still shows its own line for it).
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    pcall(f.RegisterEvent, f, "ADDON_ACTION_BLOCKED")
    pcall(f.RegisterEvent, f, "ADDON_ACTION_FORBIDDEN")
    f:SetScript("OnEvent", function(_, event, addon, fn)
        if event == "PLAYER_LOGIN" then
            HookErrors()
        elseif errorMode ~= "buggrabber" and type(addon) == "string" and strfind(addon, "^DisasterZone") then
            pcall(Take, ("[%s] AddOn '%s' tried to call the protected function '%s'."):format(event, addon,
                tostring(fn or "?")))
        end
    end)
end

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

local function FormatMessage(fmt, ...)
    if select("#", ...) == 0 then
        return tostring(fmt)
    end
    local ok, msg = pcall(strformat, tostring(fmt), ...)
    if ok then return msg end
    -- Bad format / nil argument: degrade to a plain concatenation instead of erroring.
    local parts = { tostring(fmt) }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    return tconcat(parts, " ")
end

local function Output(text)
    local frame = DEFAULT_CHAT_FRAME
    if frame and frame.AddMessage then
        frame:AddMessage(text)
    elseif print then
        print(text)
    end
end

function ns:Print(fmt, ...)
    Output(CHAT_PREFIX .. FormatMessage(fmt, ...))
end

function ns:IsDebug()
    local db = ns.db
    return (db and db.settings and db.settings.debug) and true or false
end

function ns:Debug(fmt, ...)
    if not ns:IsDebug() then return end
    Output(CHAT_PREFIX .. "|cff999999[debug]|r " .. FormatMessage(fmt, ...))
end

---------------------------------------------------------------------------
-- Module registry & lifecycle
---------------------------------------------------------------------------

local modules = {}   -- ordered by registration (= TOC order)

function ns:NewModule(name)
    if type(name) ~= "string" or name == "" then
        error("DisasterZone:NewModule: a module name is required", 2)
    end
    if ns[name] ~= nil then
        error("DisasterZone:NewModule: '" .. name .. "' already exists", 2)
    end
    local M = { name = name }
    ns[name] = M
    modules[#modules + 1] = M
    return M
end

-- Returns a copy of the ordered module list (for the harness / debugging).
function ns:GetModules()
    local out = {}
    for i = 1, #modules do out[i] = modules[i] end
    return out
end

local initDone, loginDone = 0, 0   -- modules[1..n] have had OnInit / OnLogin (game packs add modules later)

local function DispatchLifecycle(method, from)
    for i = from or 1, #modules do
        local M = modules[i]
        local fn = M[method]
        if type(fn) == "function" then
            local ok = SafeCall(fn, M)
            if not ok and Boot and Boot.applied then Boot.NoteStartupError() end
        end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local eventHandlers = {}     -- [event] = array of fns (replaced, never mutated, so dispatch can iterate safely)
local skippedEvents = {}     -- events refused because the client does not know them

local function IsEventKnown(event)
    if C_EventUtils and C_EventUtils.IsEventValid then
        return C_EventUtils.IsEventValid(event) and true or false
    end
    return true
end

function ns:RegisterEvent(event, fn)
    if type(event) ~= "string" or type(fn) ~= "function" then
        error("DisasterZone:RegisterEvent(event, fn): bad arguments", 2)
    end
    local list = eventHandlers[event]
    if list then
        for i = 1, #list do
            if list[i] == fn then return true end
        end
    else
        if not IsEventKnown(event) then
            skippedEvents[event] = true
            ns:Debug("Event %s does not exist on this client; handler skipped.", event)
            return false
        end
        local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then
            skippedEvents[event] = true
            ns:Debug("Could not register event %s; handler skipped.", event)
            return false
        end
        list = {}
    end
    local newList = {}
    for i = 1, #list do newList[i] = list[i] end
    newList[#newList + 1] = fn
    eventHandlers[event] = newList
    if ns.PerfNote then ns.PerfNote(fn) end      -- (the Performance page: which file registered it)
    return true
end

function ns:UnregisterEvent(event, fn)
    local list = eventHandlers[event]
    if not list then return end
    local newList = {}
    for i = 1, #list do
        if list[i] ~= fn then newList[#newList + 1] = list[i] end
    end
    if #newList == 0 then
        eventHandlers[event] = nil
        pcall(eventFrame.UnregisterEvent, eventFrame, event)
    else
        eventHandlers[event] = newList
    end
end

-- ns.PerfProbe (Core/Perf.lua, the developer's Performance page, only while it measures) runs the handlers itself,
-- timing them and weighing the garbage they make.
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if Boot and Boot.safeMode then return end   -- an in-game update failed to load: the addon stays inert
    local list = eventHandlers[event]
    if not list then return end
    local probe = ns.PerfProbe
    if probe then return probe("event", event, list, ...) end
    for i = 1, #list do
        SafeCall(list[i], event, ...)
    end
end)

---------------------------------------------------------------------------
-- Internal message bus (§3.3)
---------------------------------------------------------------------------

local KNOWN_MESSAGES = {
    ROSTER_UPDATED = true, CONFIG_UPDATED = true, GROUP_UPDATED = true,
    MYLIST_CHANGED = true, MYLIST_COMMITTED = true, OWNED_UPDATED = true,
    LIST_UPDATED = true, LISTS_RESET = true, ITEMINFO_READY = true,
    DROP = true, LEDGER_UPDATED = true, PEERS_UPDATED = true,
    SYNC_STATUS = true, SETTINGS_CHANGED = true, DEMO_TOGGLED = true,
    RESERVES_CHANGED = true, RESERVES_OPENED = true, RESERVES_CLOSED = true, RESERVES_CLEARED = true,
    RESERVES_RULES = true, RESERVE_ADDED = true, RESERVE_REMOVED = true, RESERVE_DEMO_STEP = true,
    -- Core/Layout.lua: LAYOUT_CHANGED (what: "profiles" | "profile" | "items" | "hidden" | "applied"), LAYOUT_RECEIVED
    -- (owner, profile id, data | nil) a shared layout came; UI/EditMode.lua: EDIT_LAYOUT (on) the overlay opened / closed
    LAYOUT_CHANGED = true, LAYOUT_RECEIVED = true, EDIT_LAYOUT = true,
    -- UI/Look.lua: UI_LOOK_CHANGED (part, setting path) a part's look or option changed
    UI_LOOK_CHANGED = true,
    -- Core/SwingTimer.lua: SWING_STATE (active) on/off for this character, SWING_VALUES the sim's damage values,
    -- SWING_REPORT (report) a fight ended
    SWING_STATE = true, SWING_VALUES = true, SWING_REPORT = true,
    -- Core/SwingPractice.lua: SWING_PRACTICE ("start", lesson | "stop", reason, result), SWING_PRACTICE_KEYS (keys
    -- changed), SWING_PRACTICE_CAST (spell) a practice press went off, SWING_PRACTICE_SWING (kind) a swing graded
    SWING_PRACTICE = true, SWING_PRACTICE_KEYS = true, SWING_PRACTICE_CAST = true, SWING_PRACTICE_SWING = true,
    -- Core/ClassKit.lua: the player's spec may have changed (class tools re-check ClassKit:IsMine)
    CLASSKIT_CHANGED = true,
    -- Core/Blessings.lua: the blessings plan, a paladin, or who has which blessing changed
    BLESSINGS_CHANGED = true,
    -- Addendum A §19: roll sessions (Core/Roll.lua)
    ROLL_UPDATED = true,   -- (sessionID) any change: start, roll, response, close, award, cancel
    ROLL_STARTED = true,   -- (session) a roll session opened (raider popup)
    -- Addendum B §22.1: dungeon mode (Core/Dungeon.lua)
    DUNGEON_MODE_CHANGED = true,   -- (active) Util.IsDungeonModeActive() or the group's enabler changed
    -- Addendum D §25: the group's loot rules (Core/GroupRules.lua): the active rules, their source or my
    -- own authority status changed (DB:GetEffective values may differ)
    GROUP_RULES_CHANGED = true,
    -- Core/SessionInfo.lua: what the raid session crest shows changed (a boss fight began / ended, someone left, the
    -- demo night changed)
    SESSION_INFO_CHANGED = true,
    -- Addendum F §38: (locked) GroupRules:IsLocked() changed: the raid's BiS lists were locked / unlocked, or
    -- the lock ended (disband, authority change). Store clears its "changed during lock" flags on false.
    BIS_LOCK_CHANGED = true,
    -- DisasterZone 0.5: (guildKey) the guild name became known after login (GetGuildInfo can lag behind the roster);
    -- fired once per resolved guild, deferred (never from inside a Guild call).
    GUILD_KEY_READY = true,
    -- Minigames (Games/Hub.lua): the game list / a highscore changed; (inCombat) combat started / ended
    GAMES_UPDATED = true, GAMES_COMBAT = true, CHESS_UPDATED = true,
    PATCH_UPDATED = true,   -- in-game updates (Core/Patch.lua): download progress / an update is ready / status
    BINGO_UPDATED = true,   -- Council Bingo (Games/Bingo): game started / square marked / game ended
    BINGO_MOMENT = true,    -- (squareId, who, onMyCard) a square went off this moment (the toasts, the legendary takeover)
    OFFICER_NOTES_UPDATED = true,   -- (key | nil) an officer note, or my access to them, changed
    PROFESSIONS_UPDATED = true,   -- the guild's professions / recipes changed (Core/Professions.lua)
    SHOP_UPDATED = true,          -- my Atlas shopping list changed (Core/ShoppingList.lua)
    WARDROBE_UPDATED = true,      -- my outfits, what I wear or carry, or a swap changed (Core/Wardrobe.lua)
    -- who has a strategy open / what they have selected changed (Core/StrategyCollab.lua)
    STRATEGY_PRESENCE_CHANGED = true,
    -- the guild's dungeon runs (Core/DungeonRuns.lua): anything on the board changed; (id) a run needs me while I'm
    -- up for one; (id, key) somebody asks to join my run
    DUNGEON_RUNS_UPDATED = true, DUNGEON_RUN_PING = true, DUNGEON_RUN_REQUEST = true,
    -- events (Core/Events.lua, Core/EventLive.lua): the library / calendar / results / season changed; (occId) a live
    -- event's state changed; (occId, text) a raid warning piece for me; (occId, seconds) a countdown for me; the
    -- builder's practice run changed / logged a line / ran a script (scriptId, blockId)
    EVENTS_UPDATED = true, EVENT_LIVE_UPDATED = true, EVENT_ANNOUNCE = true, EVENT_COUNTDOWN = true,
    EVENT_PRACTICE_UPDATED = true, EVENT_PRACTICE_LOG = true, EVENT_PRACTICE_RAN = true,
    -- (occId, text) a banner for me / a tracker line for me (Live:MyFeed keeps them); (occId, soundKey) a sound for me
    -- (EventLive played it already)
    EVENT_SHOW = true, EVENT_TELL = true, EVENT_SOUND = true,
    -- raids / strategies / guests / loot
    RAIDINVITE_CHANGED = true, RAIDLOG_CHANGED = true, RAIDPLAN_CHANGED = true, PARTY_INVITE_FAILED = true,
    STRATEGY_CHANGED = true, STRATEGY_DRAFTS_CHANGED = true, STRATEGY_LIVE = true,
    -- Core/Tanks.lua: the raid's main tanks, their order or the plan's tanks changed
    TANKS_CHANGED = true,
    GUESTBOOK_CHANGED = true, LOOT_HELD = true, CHANGELOG_READ = true,
    -- the guild's feedback (Core/Feedback.lua): (none) records changed; (error) DisasterZone hit a Lua error; (error,
    -- how, item | nil, why) the error reported itself (how: filed / joined / fixed / known) or couldn't
    FEEDBACK_UPDATED = true, FEEDBACK_ERROR = true, FEEDBACK_AUTO = true,
    -- the notification center (Core/Notify.lua): (none) the feed or its counts changed; (id) something new arrived
    NOTIFY_CHANGED = true, NOTIFY_NEW = true,
    POLLS_UPDATED = true, POLL_ANSWERED = true, POLL_ARRIVED = true, POLL_NUDGED = true,
    -- Core/Prized.lua: prized items (Raids > Loot rules) changed; (recordId, text, by) someone else changed the rules
    PRIZED_UPDATED = true, PRIZED_RULES_CHANGED = true,
    -- UI/RollFrame.lua: a prized item rolled out that I don't qualify for (session id, item, why, free again)
    PRIZED_NOT_ELIGIBLE = true,
    -- Core/Guild.lua: the GM's loot rules (Council > Rules) changed
    LOOT_RULES_CHANGED = true,
    -- Group Finder + dungeon run invites
    GROUP_FINDER_UPDATED = true, GROUP_FINDER_PROMPT = true, GROUP_FINDER_LEFTOVER = true,
    DUNGEON_RUN_INVITE = true, DUNGEON_RUN_INVITE_GONE = true,
    -- Atlas costs / prices, Azeromon guild data
    CURRENCY_CHANGED = true, PRICES_UPDATED = true, AZERO_GUILD_UPDATED = true,
    -- My Log: a pull started / ended (bool); the stored pulls changed (pull id | nil)
    MYLOG_RECORDING = true, MYLOG_CHANGED = true,
    -- the developer's Performance page (Core/Perf.lua): a memory sample, a cleanup or a measurement came in
    PERF_UPDATED = true,
    -- the guild map (Core/GuildMap.lua): somebody moved / came / left, or my sharing changed
    GUILDMAP_UPDATED = true,
    -- attendance (Core/RaidLog.lua, Core/Attendance.lua): (recId, key) somebody left / joined the raid group while it
    -- is logged; (recId, key, character) an expected player left the raid I lead before its end; (recId, plannedEnd) I
    -- left a raid that expects me before its end; the GM's margins changed; my own attendance arrived
    RAIDLOG_LEFT = true, RAIDLOG_JOINED = true, ATTENDANCE_PLAYER_LEFT = true, ATTENDANCE_LEFT_EARLY = true,
    ATTENDANCE_RULES_CHANGED = true, ATTENDANCE_MINE = true,
    -- the reviews may have changed (debounced after raid log changes); several expected players left at once
    ATTENDANCE_REVIEWS_CHANGED = true, ATTENDANCE_BREAKUP = true,
    -- (CONFIG_UPDATED, Addendum E §29: the effective council set, my council status or the phase changed)
}
local messageHandlers = {}   -- [msg] = array of fns (copy-on-write, like eventHandlers)
local unknownMessages = {}

local function NoteUnknownMessage(msg, where)
    if KNOWN_MESSAGES[msg] or unknownMessages[msg] then return end
    unknownMessages[msg] = true
    ns:Debug("%s: '%s' is not in the message catalogue.", where, tostring(msg))
end

function ns:On(msg, fn)
    if type(msg) ~= "string" or type(fn) ~= "function" then
        error("DisasterZone:On(msg, fn): bad arguments", 2)
    end
    NoteUnknownMessage(msg, "On")
    local list = messageHandlers[msg] or {}
    for i = 1, #list do
        if list[i] == fn then return end
    end
    local newList = {}
    for i = 1, #list do newList[i] = list[i] end
    newList[#newList + 1] = fn
    messageHandlers[msg] = newList
    if ns.PerfNote then ns.PerfNote(fn) end
end

function ns:Off(msg, fn)
    local list = messageHandlers[msg]
    if not list then return end
    local newList = {}
    for i = 1, #list do
        if list[i] ~= fn then newList[#newList + 1] = list[i] end
    end
    messageHandlers[msg] = (#newList > 0) and newList or nil
end

function ns:Fire(msg, ...)
    NoteUnknownMessage(msg, "Fire")
    local list = messageHandlers[msg]
    if not list then return end
    local probe = ns.PerfProbe
    if probe then return probe("message", msg, list, ...) end
    for i = 1, #list do
        SafeCall(list[i], ...)
    end
end

---------------------------------------------------------------------------
-- Trail: the last steps before something went wrong (an automatic error report sends them, Core/Feedback.lua)
---------------------------------------------------------------------------

-- A ring of the last TRAIL_N steps (pages opened, slash commands, fights, zones); a repeat of the newest step only
-- counts up. The slots are reused, so a step makes no garbage.
local TRAIL_N = 12
local trailText, trailAt, trailCount, trailLast = {}, {}, {}, 0

function ns:Trail(text)
    if type(text) ~= "string" then return end
    local now = GetTime and GetTime() or 0
    if trailLast > 0 and trailText[trailLast] == text then
        trailCount[trailLast] = trailCount[trailLast] + 1
        trailAt[trailLast] = now
        return
    end
    trailLast = trailLast % TRAIL_N + 1
    trailText[trailLast], trailAt[trailLast], trailCount[trailLast] = text, now, 1
end

-- The steps, oldest first: { { text, at = GetTime() of the last time, n = times in a row }, ... }.
function ns:GetTrail()
    local out = {}
    for i = 1, TRAIL_N do
        local slot = (trailLast + i - 1) % TRAIL_N + 1
        if trailText[slot] then out[#out + 1] = { text = trailText[slot], at = trailAt[slot], n = trailCount[slot] } end
    end
    return out
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local slashCommands = {}   -- [sub] = { fn = fn, help = text }

function ns:RegisterSlash(sub, fn, help)
    if type(sub) ~= "string" or sub == "" or type(fn) ~= "function" then
        error("DisasterZone:RegisterSlash(sub, fn, help): bad arguments", 2)
    end
    slashCommands[strlower(sub)] = { fn = fn, help = help }
end

function ns:PrintSlashHelp()
    ns:Print("commands (/dz or /disasterzone):")
    Output("  |cffffd100/dz|r - open or close the DisasterZone window")
    local subs = {}
    for sub in pairs(slashCommands) do subs[#subs + 1] = sub end
    tsort(subs)
    for _, sub in ipairs(subs) do
        local help = slashCommands[sub].help
        if help and help ~= "" then
            Output("  |cffffd100/dz " .. sub .. "|r - " .. tostring(help))
        else
            Output("  |cffffd100/dz " .. sub .. "|r")
        end
    end
end

local function HandleSlash(input)
    input = type(input) == "string" and input or ""
    local sub, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    sub = strlower(sub or "")
    rest = rest or ""
    ns:Trail(sub == "" and "/dz" or ("/dz " .. sub))

    if Boot and Boot.safeMode then
        ns:Print("an in-game update failed to load; reload the interface (/reload) to go back to the installed version.")
        return
    end
    if sub == "" then
        if ns.MainFrame and ns.MainFrame.Toggle then
            ns.MainFrame:Toggle()
        else
            ns:Print("the main window is not available.")
        end
        return
    end
    if sub == "help" or sub == "?" then
        ns:PrintSlashHelp()
        return
    end
    local cmd = slashCommands[sub]
    if cmd then
        SafeCall(cmd.fn, rest)
    else
        ns:Print("unknown command '%s'.", sub)
        ns:PrintSlashHelp()
    end
end

SLASH_DISASTERZONE1 = "/dz"
SLASH_DISASTERZONE2 = "/disasterzone"
SLASH_DISASTERZONE3 = "/cdl"             -- the addon was called CDLoot before 0.12
SLASH_DISASTERZONE4 = "/cdloot"
if SlashCmdList then
    SlashCmdList["DISASTERZONE"] = HandleSlash
end

ns:RegisterSlash("debug", function()
    local on = not ns:IsDebug()
    if ns.DB and ns.DB.SetSetting and ns.db then
        ns.DB:SetSetting("debug", on)
    elseif ns.db and ns.db.settings then
        ns.db.settings.debug = on
    else
        ns:Print("settings are not loaded yet.")
        return
    end
    ns:Print("debug output %s.", on and "enabled" or "disabled")
end, "toggle debug output")

---------------------------------------------------------------------------
-- Lifecycle wiring
---------------------------------------------------------------------------

local function RunInit()
    if ns.initialized or (Boot and Boot.safeMode) then return end
    ns.initialized = true
    -- Modules run in TOC order, so ns.DB (after Init/Util/Constants/ItemDB) sets ns.db
    -- before any later module's OnInit.
    DispatchLifecycle("OnInit")
    initDone = #modules
    for event in pairs(skippedEvents) do
        ns:Debug("Event %s is unknown on this client (handlers skipped).", event)
    end
    for msg in pairs(unknownMessages) do
        ns:Debug("Message '%s' is not in the message catalogue.", msg)
    end
end

local function RunLogin()
    if ns.loggedIn or (Boot and Boot.safeMode) then return end
    RunInit()
    ns.loggedIn = true
    DispatchLifecycle("OnLogin")
    loginDone = #modules
    if Boot and Boot.LifecycleDone then Boot.LifecycleDone() end
end

-- Game packs (the DisasterZone_<Game> folders, dev/docs/GAME_PACKS.md) load after this addon's ADDON_LOADED, so
-- their modules miss the OnInit above. A pack's last file (Done.lua) calls this with its own (folder, ns): the boot
-- loader runs the files an in-game update added to the pack's end, then the pack's new modules get OnInit, and
-- OnLogin as well when the login stage has passed already. A pack the boot loader skipped does nothing.
ns.packs = {}   -- [folder] = true once that pack started
function ns:PackLoaded(folder, packNs)
    if type(folder) ~= "string" or ns.packs[folder] then return end
    if Boot and (Boot.safeMode or Boot.dormant) then return end
    local state = Boot and Boot.PackState and Boot.PackState(folder)
    if state and state ~= "ok" then return end
    if Boot and Boot.EndPack then Boot.EndPack(folder, folder, packNs) end
    ns.packs[folder] = true
    if ns.initialized then
        local from = initDone + 1
        initDone = #modules
        DispatchLifecycle("OnInit", from)
    end
    if ns.loggedIn then
        local from = loginDone + 1
        loginDone = #modules
        DispatchLifecycle("OnLogin", from)
    end
end

local function OnAddonLoaded(_, loadedName)
    if loadedName ~= addonName then return end
    ns:UnregisterEvent("ADDON_LOADED", OnAddonLoaded)
    RunInit()
    -- Loaded after login (e.g. load-on-demand): run the login stage right away.
    if IsLoggedIn and IsLoggedIn() then
        RunLogin()
    end
end

ns:RegisterEvent("ADDON_LOADED", OnAddonLoaded)
ns:RegisterEvent("PLAYER_LOGIN", function()
    RunLogin()
end)
