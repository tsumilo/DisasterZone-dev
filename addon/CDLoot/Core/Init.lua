-- CDLoot: namespace bootstrap.
-- Module registry + lifecycle (OnInit / OnLogin), event dispatcher, internal message bus,
-- slash commands and Print / Debug output. Every other file builds on this one.
local addonName, ns = ...

CDLoot = ns                       -- the ONE debugging global
ns.name = addonName               -- "CDLoot"
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "0.0.0"
ns.PROTO = 1                      -- wire protocol major (matches TOC X-CDL-Protocol)
ns.initialized = false            -- true once OnInit has been dispatched
ns.loggedIn = false               -- true right before OnLogin is dispatched

local type, pairs, ipairs, select, tostring = type, pairs, ipairs, select, tostring
local tinsert, tsort, tconcat = table.insert, table.sort, table.concat
local strformat, strlower = string.format, string.lower

local CHAT_PREFIX = "|cffff8000CDLoot|r: "

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

local function ErrorHandler()
    local h = geterrorhandler and geterrorhandler()
    return h or FallbackErrorHandler
end

-- xpcall(fn, geterrorhandler(), ...) that also works on plain Lua 5.1, whose xpcall
-- does not forward extra arguments. The error handler is looked up per call so that
-- error-catching addons installed later are honoured.
local function SafeCall(fn, ...)
    local n = select("#", ...)
    if n == 0 then
        return xpcall(fn, ErrorHandler())
    end
    local args = { ... }
    return xpcall(function() return fn(unpack(args, 1, n)) end, ErrorHandler())
end
ns.SafeCall = SafeCall

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
        error("CDLoot:NewModule: a module name is required", 2)
    end
    if ns[name] ~= nil then
        error("CDLoot:NewModule: '" .. name .. "' already exists", 2)
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

local function DispatchLifecycle(method)
    for i = 1, #modules do
        local M = modules[i]
        local fn = M[method]
        if type(fn) == "function" then
            SafeCall(fn, M)
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
        error("CDLoot:RegisterEvent(event, fn): bad arguments", 2)
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

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = eventHandlers[event]
    if not list then return end
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
    -- Addendum A §19: roll sessions (Core/Roll.lua)
    ROLL_UPDATED = true,   -- (sessionID) any change: start, roll, response, close, award, cancel
    ROLL_STARTED = true,   -- (session) a roll session opened (raider popup)
    -- Addendum B §22.1: dungeon mode (Core/Dungeon.lua)
    DUNGEON_MODE_CHANGED = true,   -- (active) Util.IsDungeonModeActive() or the group's enabler changed
    -- Addendum D §25: the group's loot rules (Core/GroupRules.lua): the active rules, their source or my
    -- own authority status changed (DB:GetEffective values may differ)
    GROUP_RULES_CHANGED = true,
    -- Addendum F §38: (locked) GroupRules:IsLocked() changed: the raid's BiS lists were locked / unlocked, or
    -- the lock ended (disband, authority change). Store clears its "changed during lock" flags on false.
    BIS_LOCK_CHANGED = true,
    -- CDLoot 0.5: (guildKey) the guild name became known after login (GetGuildInfo can lag behind the roster);
    -- fired once per resolved guild, deferred (never from inside a Guild call).
    GUILD_KEY_READY = true,
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
        error("CDLoot:On(msg, fn): bad arguments", 2)
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
    for i = 1, #list do
        SafeCall(list[i], ...)
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local slashCommands = {}   -- [sub] = { fn = fn, help = text }

function ns:RegisterSlash(sub, fn, help)
    if type(sub) ~= "string" or sub == "" or type(fn) ~= "function" then
        error("CDLoot:RegisterSlash(sub, fn, help): bad arguments", 2)
    end
    slashCommands[strlower(sub)] = { fn = fn, help = help }
end

function ns:PrintSlashHelp()
    ns:Print("commands (/cdl or /cdloot):")
    Output("  |cffffd100/cdl|r - open or close the CDLoot window")
    local subs = {}
    for sub in pairs(slashCommands) do subs[#subs + 1] = sub end
    tsort(subs)
    for _, sub in ipairs(subs) do
        local help = slashCommands[sub].help
        if help and help ~= "" then
            Output("  |cffffd100/cdl " .. sub .. "|r - " .. tostring(help))
        else
            Output("  |cffffd100/cdl " .. sub .. "|r")
        end
    end
end

local function HandleSlash(input)
    input = type(input) == "string" and input or ""
    local sub, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    sub = strlower(sub or "")
    rest = rest or ""

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

SLASH_CDLOOT1 = "/cdl"
SLASH_CDLOOT2 = "/cdloot"
if SlashCmdList then
    SlashCmdList["CDLOOT"] = HandleSlash
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
    if ns.initialized then return end
    ns.initialized = true
    -- Modules run in TOC order, so ns.DB (after Init/Util/Constants/ItemDB) sets ns.db
    -- before any later module's OnInit.
    DispatchLifecycle("OnInit")
    for event in pairs(skippedEvents) do
        ns:Debug("Event %s is unknown on this client (handlers skipped).", event)
    end
    for msg in pairs(unknownMessages) do
        ns:Debug("Message '%s' is not in the message catalogue.", msg)
    end
end

local function RunLogin()
    if ns.loggedIn then return end
    RunInit()
    ns.loggedIn = true
    DispatchLifecycle("OnLogin")
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
