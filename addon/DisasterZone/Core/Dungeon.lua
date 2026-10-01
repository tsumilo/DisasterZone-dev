if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Dungeon.lua", ...) then return end -- DisasterZone: Core/Dungeon.lua
-- Dungeon mode (Addendum B §22.1): 5-man loot sharing (drops) and rolls in a party. The switch is my own
-- setting (settings.dungeon.enabled) or a DM message from the party leader / a council member, which
-- is remembered for this session only (Dungeon.groupEnabledBy). The effective checks are
-- Util.IsDungeonModeActive() and Util.GetGroupChannel(); DUNGEON_MODE_CHANGED(active) fires on changes.
--
-- Addendum D §24-§26 (group rules): dungeon mode on/off and its quality are group rules now. The group's
-- loot authority decides for the whole party (GS, Core/GroupRules.lua) and everyone reads them through
-- ns.DB:GetEffective. DM stays for DisasterZone 0.2 clients: the authority still sends it, and a DM from a
-- client that does not speak GS is still honoured (the legacy groupEnabledBy switch).
--
-- Like Util this file is not a lifecycle module (it loads before DB, so it must not shift the module
-- order): it wires itself with ns:RegisterEvent / ns:On and registers its Comm handler at load / login.
local addonName, ns = ...

local Dungeon = {}
ns.Dungeon = Dungeon
local Util = ns.Util

local type, tostring, tonumber = type, tostring, tonumber

local RESEND_DELAY = 3        -- the enabler re-sends DM{on=true} this long after the party changed
local EVAL_DELAY = 0.35       -- after GROUP_ROSTER_UPDATE (Util's own group refresh waits 0.3s)
local QUERY_DELAY = 5         -- after login / reload in a party: ask who has dungeon mode on
local QUERY_REPLY_LIMIT = 10  -- seconds between two answers to one member's query

local QUALITY_NAMES = { [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary" }

Dungeon.groupEnabledBy = nil  -- key of the party leader / council member whose DM{on=true} is in effect

local lastActive = false
local lastBy = nil
local lastSetting = nil       -- my setting as last seen (nil until login)
local wasInParty = false
local setupDone = false
local queried = false
local toldParty = false       -- I sent DM{on=true} to the current party (I may turn it off again after
                              -- passing the lead on)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Setting(path, default)
    local DB = ns.DB
    local v = DB and DB.GetSetting and DB:GetSetting(path)
    if v == nil then return default end
    return v
end

-- My own switch (settings.dungeon.enabled), whatever the group rules say.
local function SettingOn()
    return Setting("dungeon.enabled", false) == true
end

-- The effective value of a group-rule setting (the loot authority's while group rules are active).
local function Effective(path, default)
    local DB = ns.DB
    local v
    if DB and DB.GetEffective then
        v = DB:GetEffective(path)
    elseif DB and DB.GetSetting then
        v = DB:GetSetting(path)
    end
    if v == nil then return default end
    return v
end

local function GroupRulesStatus()
    local GR = ns.GroupRules
    if GR and GR.GetStatus then return GR:GetStatus() end
    return "own", nil
end

local function InParty()
    return (IsInGroup() and not IsInRaid()) and true or false
end

local function AmRealCouncil()
    local Guild = ns.Guild
    return (Guild and Guild.AmICouncil and Guild:AmICouncil(true)) and true or false
end

local function IsRealCouncil(key)
    local Guild = ns.Guild
    return (Guild and Guild.IsCouncil and Guild:IsCouncil(key, true)) and true or false
end

-- May tell the party (DM, for DisasterZone 0.2 members): the party's loot authority (Addendum D §24), or the
-- party leader, who becomes the authority by turning dungeon mode on. Without GroupRules: the party
-- leader or a (real) council member.
local function CanTellParty()
    if not InParty() then return false end
    if UnitIsGroupLeader("player") then return true end
    local GR = ns.GroupRules
    if GR and GR.IsAuthority then return GR:IsAuthority() and true or false end
    return AmRealCouncil()
end

local function SendDM(msg)
    local Comm = ns.Comm
    if not (Comm and Comm.Send) or not InParty() then return false end
    local ok = Comm:Send(msg, "PARTY", nil, "alert") and true or false
    if ok and msg.on == true then toldParty = true end
    return ok
end

local function Short(key)
    return Util.ShortName(key)
end

-- The enabler is still in my party (conservative: unknown = present).
local function EnablerPresent(key)
    if Util.GetPartyUnit and Util.GetPartyUnit(key) then return true end
    local name = (Ambiguate and Ambiguate(key, "none")) or key
    if UnitInParty and UnitInParty(name) then return true end
    -- The roster may still be loading ("Unknown" names): keep the flag while Util.group is incomplete.
    local n = tonumber(GetNumGroupMembers and GetNumGroupMembers()) or 0
    return Util.Count(Util.group) < n
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

-- Re-checks the effective mode; fires DUNGEON_MODE_CHANGED(active) when it (or the enabler) changed.
local function Evaluate()
    local inParty = InParty()
    local by = Dungeon.groupEnabledBy
    if by and (not inParty or not EnablerPresent(by)) then
        -- Left the group, the group became a raid, or the enabler left: the group switch is gone.
        Dungeon.groupEnabledBy = nil
        by = nil
    end
    if not inParty then toldParty = false end
    -- Joined a party (or a raid became a party) with dungeon mode on: tell the new party.
    if inParty and not wasInParty and SettingOn() then
        Dungeon:ScheduleResend()
    end
    wasInParty = inParty
    local active = Util.IsDungeonModeActive()
    if active ~= lastActive or by ~= lastBy then
        lastActive = active
        lastBy = by
        ns:Fire("DUNGEON_MODE_CHANGED", active)
    end
    return active
end

local function ScheduleEvaluate()
    Util.Debounce("cdl-dungeon-eval", EVAL_DELAY, Evaluate)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Effective dungeon mode (same as Util.IsDungeonModeActive()).
function Dungeon:IsActive()
    return Util.IsDungeonModeActive()
end

-- My own switch (settings.dungeon.enabled).
function Dungeon:IsEnabled()
    return SettingOn()
end

-- Key of the party leader / council member who turned dungeon mode on for my party, or nil.
function Dungeon:GetEnabledBy()
    return Dungeon.groupEnabledBy
end

-- Minimum drop quality inside 5-man instances (the effective dungeon.quality: the group's rule while
-- group rules are active, else my setting; 2..5, default 3 = Rare).
function Dungeon:GetQuality()
    local q = tonumber(Effective("dungeon.quality", 3)) or 3
    q = math.floor(q)
    if q < 2 then q = 2 elseif q > 5 then q = 5 end
    return q
end

function Dungeon:GetQualityName(q)
    q = tonumber(q) or self:GetQuality()
    return QUALITY_NAMES[q] or tostring(q)
end

-- I may turn it on for the whole party (party leader or council, in a party).
function Dungeon:CanTellParty()
    return CanTellParty()
end

-- Sets my switch (fires SETTINGS_CHANGED; the party is told by the settings listener below).
function Dungeon:SetEnabled(on)
    local DB = ns.DB
    if not (DB and DB.SetSetting and ns.db) then return false end
    DB:SetSetting("dungeon.enabled", on and true or false)
    return SettingOn()
end

-- The enabler re-sends DM{on=true} (debounced) so members who joined meanwhile pick it up.
function Dungeon:ScheduleResend(delay)
    Util.Debounce("cdl-dungeon-resend", tonumber(delay) or RESEND_DELAY, function()
        if SettingOn() and CanTellParty() then SendDM({ t = "DM", on = true }) end
    end)
end

---------------------------------------------------------------------------
-- Settings / group changes
---------------------------------------------------------------------------

local function OnSettingChanged(path)
    if type(path) ~= "string" or (path ~= "dungeon" and path:sub(1, 8) ~= "dungeon.") then return end
    local on = SettingOn()
    -- Off also reaches the party when I told it earlier and have passed the lead on since.
    if lastSetting ~= nil and on ~= lastSetting and (CanTellParty() or (not on and toldParty and InParty())) then
        Util.CancelDebounce("cdl-dungeon-resend")
        SendDM({ t = "DM", on = on })
    end
    lastSetting = on
    Evaluate()
end

local function OnGroupUpdated()
    ScheduleEvaluate()
    if SettingOn() and CanTellParty() then Dungeon:ScheduleResend() end
end

-- After a login / reload inside a party: the group switch was session-only, ask for it again.
local function QueryParty()
    if queried then return end
    queried = true
    Util.After(QUERY_DELAY, function()
        if InParty() and not Dungeon.groupEnabledBy and not SettingOn() then
            SendDM({ t = "DM", q = true })
        end
    end)
end

---------------------------------------------------------------------------
-- DM {on = bool} (PARTY, alert class). DisasterZone 0.3 extension: {q = true} asks the enablers to re-send.
-- Gate: the sender is in my party AND is the party leader or a council member (an "off" is also taken
-- from the member who turned it on, after they passed the lead on).
---------------------------------------------------------------------------

local function OnDungeonMessage(sender, msg, dist)
    if dist ~= "PARTY" or type(msg) ~= "table" or type(sender) ~= "string" or not InParty() then return end
    local unit = Util.GetPartyUnit and Util.GetPartyUnit(sender)
    if not unit then return end
    if msg.q == true then
        local Comm = ns.Comm
        if SettingOn() and CanTellParty() and (not (Comm and Comm.RateLimit) or Comm:RateLimit("dm-q:" .. sender, QUERY_REPLY_LIMIT)) then
            Dungeon:ScheduleResend(1)
        end
        return
    end
    local on = msg.on
    if on ~= true and on ~= false then return end
    local leader = UnitIsGroupLeader(unit) and true or false
    -- Turning it on needs the party leader or a council member. Turning it off is honoured from the
    -- enabler (also after they passed the lead on) or the party leader (below).
    local enabler = on == false and Dungeon.groupEnabledBy == sender
    if not (leader or enabler or IsRealCouncil(sender)) then
        ns:Debug("Dungeon: DM from %s ignored (not the party leader or council).", tostring(sender))
        return
    end
    -- A leader toggling back and forth must not flood the chat frame: at most one line per 5s per sender.
    local Comm = ns.Comm
    local function MayPrint()
        return not (Comm and Comm.RateLimit) or Comm:RateLimit("dm-print:" .. sender, 5)
    end
    if on then
        if Dungeon.groupEnabledBy ~= sender then
            local was = Dungeon.groupEnabledBy
            Dungeon.groupEnabledBy = sender
            if not was and MayPrint() then
                ns:Print("dungeon mode enabled by %s (5-man loot sharing & rolls)", Short(sender))
            end
        end
    elseif Dungeon.groupEnabledBy and (Dungeon.groupEnabledBy == sender or leader) then
        Dungeon.groupEnabledBy = nil
        if MayPrint() then
            if SettingOn() then
                ns:Print("%s turned dungeon mode off for the party (it stays on in your own settings).", Short(sender))
            else
                ns:Print("dungeon mode turned off by %s.", Short(sender))
            end
        end
    end
    -- Group rules (Addendum D §25): a DM from the group's loot authority switches its dm rule at once (the GS
    -- carrying the same change may wait for its 5 s rate limit).
    local GR = ns.GroupRules
    if GR and GR.OnDungeonSwitch then GR:OnDungeonSwitch(sender, on, leader) end
    Evaluate()
end

---------------------------------------------------------------------------
-- Slash: /dz dungeon [on | off | rare | epic | status]
---------------------------------------------------------------------------

local function StatusText()
    local q = Dungeon:GetQualityName()
    local status, from = GroupRulesStatus()
    if Util.IsDungeonModeActive() then
        local by = Dungeon.groupEnabledBy
        local who = ""
        if status == "remote" and Effective("dungeon.enabled", false) == true then
            who = " (set by " .. Short(from) .. " for this group)"
        elseif by and not SettingOn() then
            who = " (turned on by " .. Short(by) .. ")"
        end
        return "dungeon mode is |cff33ff33active|r" .. who .. ": drops of " .. q
            .. " quality or better inside 5-man dungeons are shared with the party, and rolls run in party chat."
    end
    if status == "remote" and InParty() then
        return "dungeon mode is |cffff3333off|r for this group (set by " .. Short(from) .. ")."
    end
    if SettingOn() then
        if IsInRaid() then
            return "dungeon mode is on, but it only applies to 5-man parties (raids work as usual)."
        end
        return "dungeon mode is on; it becomes active when you are in a party (minimum quality " .. q .. ")."
    end
    return "dungeon mode is |cffff3333off|r. Type /dz dungeon on to share 5-man drops and rolls with your party."
end

local function SlashDungeon(rest)
    local arg = type(rest) == "string" and rest:lower():match("^%s*(%S*)") or ""
    if not ns.db then
        ns:Print("settings are not loaded yet.")
        return
    end
    if arg == "status" then
        ns:Print("%s", StatusText())
        return
    end
    if arg == "rare" or arg == "epic" then
        ns.DB:SetSetting("dungeon.quality", arg == "rare" and 3 or 4)
        local status, from = GroupRulesStatus()
        if status == "remote" and InParty() then
            ns:Print("dungeon mode: your own minimum quality is now %s, but %s sets it for this group (%s).",
                arg == "rare" and "Rare" or "Epic", Short(from), Dungeon:GetQualityName())
        else
            ns:Print("dungeon mode: minimum drop quality inside 5-man dungeons is now %s.", Dungeon:GetQualityName())
        end
        return
    end
    local want
    if arg == "on" or arg == "1" then
        want = true
    elseif arg == "off" or arg == "0" then
        want = false
    elseif arg == "" or arg == "toggle" then
        want = not SettingOn()
    else
        ns:Print("Usage: /dz dungeon [on|off|rare|epic|status]")
        return
    end
    Dungeon:SetEnabled(want)
    local status, from = GroupRulesStatus()
    if status == "remote" and InParty() then
        ns:Print("dungeon mode %s in your own settings, but %s sets the loot rules for this group: %s",
            want and "on" or "off", Short(from), StatusText())
        return
    end
    if want then
        local extra = ""
        if InParty() then
            if CanTellParty() then
                extra = " Your party has been told."
            else
                extra = " Only your client uses it: the party leader or a loot council member can turn it on for the whole party."
            end
        end
        ns:Print("%s%s", StatusText(), extra)
    else
        local by = Dungeon.groupEnabledBy
        if by and Util.IsDungeonModeActive() then
            ns:Print("dungeon mode off in your settings, but it stays active in this party: %s turned it on for the group.", Short(by))
        else
            ns:Print("dungeon mode |cffff3333off|r.")
        end
    end
end

ns:RegisterSlash("dungeon", SlashDungeon,
    "[on|off|rare|epic|status] - dungeon mode: share 5-man drops and run rolls in your party")

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

local function Setup()
    if setupDone then return end
    local Comm = ns.Comm
    if not (Comm and Comm.Register) then return end
    setupDone = true
    Comm:Register("DM", OnDungeonMessage)
end

ns:On("SETTINGS_CHANGED", OnSettingChanged)
ns:On("GROUP_UPDATED", OnGroupUpdated)
ns:On("DEMO_TOGGLED", function() Evaluate() end)
ns:On("GROUP_RULES_CHANGED", function() ScheduleEvaluate() end)   -- the group's dungeon mode switch
ns:RegisterEvent("GROUP_ROSTER_UPDATE", ScheduleEvaluate)
ns:RegisterEvent("PARTY_LEADER_CHANGED", function()
    ScheduleEvaluate()
    if SettingOn() and CanTellParty() then Dungeon:ScheduleResend() end
end)
local function OnAddonLoaded(_, name)
    if name ~= addonName then return end
    ns:UnregisterEvent("ADDON_LOADED", OnAddonLoaded)
    Setup()
end
ns:RegisterEvent("ADDON_LOADED", OnAddonLoaded)
ns:RegisterEvent("PLAYER_LOGIN", function()
    Setup()
    lastSetting = SettingOn()
end)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    Setup()
    if lastSetting == nil and ns.db then lastSetting = SettingOn() end
    ScheduleEvaluate()
    if InParty() then QueryParty() end
end)
