if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Threat.lua", ...) then return end -- DisasterZone: threat meter.
-- My group's threat on one enemy, read from the game itself (UnitDetailedThreatSituation, the source ThreatClassic2
-- uses), so the numbers are exact. Shown as a Threat panel of UI/MeterPanels.lua. Off until the player turns it on (Settings >
-- Meters, meters.thr). Nothing is sent: every client asks its own game.
--
-- The enemy: my target when I can attack it; with a friendly player targeted, their target; else the first boss
-- unit; else my focus.
-- A row: raw = threat as a share of the tank's (100 = the tank, it can pass 100 up to the pull point), scaled = share
-- of that player's own pull point (100 = they pull). The pull point is raw / scaled (110% in melee range, 130% at
-- range), so it needs no range check; without numbers yet it falls back to CheckInteractDistance (10 yd = melee).
-- Warning: when I am not tanking and my scaled share reaches meters.warn (85): the window pulses, the screen edges
-- flash (meters.flash) and a sound plays once per crossing (meters.sound).
-- Tank view (meters.tankView "auto" = while I tank the enemy or my group role is tank, "always", "never"): the one
-- holding aggro on top (me, while I do), then everyone by their scaled share, the closest to pulling first.
local addonName, ns = ...

local Threat = ns:NewModule("Threat")
local Util = ns.Util

local pairs, ipairs, tonumber, type = pairs, ipairs, tonumber, type
local floor, max, min = math.floor, math.max, math.min
local tsort = table.sort

local POLL = 0.2
local SOUND = 8959                -- the raid warning sound

local state = { rows = {}, mob = nil }   -- the last scan (Threat:GetState)
local ticker
local listening = false
local wasHot = false
local listeners = {}

local function Setting(path, default)
    local v = ns.DB and ns.DB.GetSetting and ns.DB:GetSetting("meters." .. path)
    if v == nil then return default end
    return v
end
Threat.Setting = Setting

function Threat:IsEnabled() return Setting("thr", false) and true or false end
function Threat:IsDemo() return Util.DemoOn() and ns.MeterDemo ~= nil end
function Threat:OnChange(fn) listeners[#listeners + 1] = fn end
local function Changed() for _, fn in ipairs(listeners) do pcall(fn, state) end end

local function Attackable(unit)
    return UnitExists(unit) and UnitCanAttack("player", unit) and not (UnitIsDead and UnitIsDead(unit))
end

-- The enemy the window follows (a unit token) or nil.
function Threat:Mob()
    if Attackable("target") then return "target" end
    if UnitExists("target") and not UnitCanAttack("player", "target") and Attackable("targettarget") then
        return "targettarget"
    end
    for i = 1, 4 do
        local u = "boss" .. i
        if Attackable(u) then return u end
    end
    if Attackable("focus") then return "focus" end
    return nil
end

local function Units()
    local list = { "player" }
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    if IsInRaid and IsInRaid() then
        list = {}
        for i = 1, n do list[#list + 1] = "raid" .. i end
    elseif n > 0 then
        for i = 1, n - 1 do list[#list + 1] = "party" .. i end
    end
    return list
end

local function MyRole()
    local r = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player")
    return r
end

function Threat:TankView(me)
    local mode = Setting("tankView", "auto")
    if mode == "always" then return true end
    if mode == "never" then return false end
    -- (a main tank: the raid's flag, Core/Tanks.lua)
    return (me and me.tank) or self:AmITank()
end

-- Am I a tank here: my group role, or a main tank of the raid (Core/Tanks.lua).
function Threat:AmITank()
    return MyRole() == "TANK" or (ns.Tanks and ns.Tanks:IsMe()) or false
end

-- Scans the group's threat on mob: state = { mob, name, combat, rows = { { unit, guid, name, cls, tank, raw, scaled,
-- value, me } } (raw order, highest first), me, pull (my pull point, % of the tank), hot, tankView, view (the rows
-- the window shows, in order) }.
function Threat:Scan()
    local mob = self:Mob()
    local st = { rows = {}, mob = mob }
    if mob then
        st.name = UnitName(mob)
        st.guid = UnitGUID and UnitGUID(mob)
        st.combat = UnitAffectingCombat and UnitAffectingCombat(mob) or false
        for _, unit in ipairs(Units()) do
            if UnitExists(unit) and UnitDetailedThreatSituation then
                local isTanking, _, scaled, raw, value = UnitDetailedThreatSituation(unit, mob)
                if raw or isTanking then
                    local _, cls = UnitClass(unit)
                    local isMe = UnitIsUnit and UnitIsUnit(unit, "player")
                    local row = { unit = unit, guid = UnitGUID(unit), name = UnitName(unit), cls = cls,
                                  tank = isTanking and true or false, raw = isTanking and 100 or (tonumber(raw) or 0),
                                  scaled = isTanking and 100 or (tonumber(scaled) or 0), value = tonumber(value) or 0,
                                  me = isMe or nil }
                    st.rows[#st.rows + 1] = row
                    if isMe then st.me = row end
                end
            end
        end
        tsort(st.rows, function(a, b)
            if a.raw ~= b.raw then return a.raw > b.raw end
            return (a.name or "") < (b.name or "")
        end)
    end
    self:Derive(st)
    state = st
    return st
end

-- The parts every scan (and the demo) shares: my pull point, the warning, the view.
function Threat:Derive(st)
    local me = st.me
    if me and not me.tank then
        if me.scaled > 0 and me.raw > 0 then
            st.pull = floor(me.raw / me.scaled * 100 + 0.5)
        else
            local near = st.mob and CheckInteractDistance and CheckInteractDistance(st.mob, 3)
            st.pull = near and 110 or 130
        end
        local warn = tonumber(Setting("warn", 85)) or 85
        st.hot = warn > 0 and me.scaled >= warn
    end
    st.tankView = self:TankView(me)
    if st.tankView then
        -- (me too: on top while I hold it, else where my share puts me; feedback #44, a tank missing from their own
        -- meter couldn't see they were tanking)
        local view = {}
        for _, r in ipairs(st.rows) do view[#view + 1] = r end
        tsort(view, function(a, b)
            -- the one holding aggro (when it isn't me) on top: the 100% the others are measured against (it was
            -- last, found only by scrolling down; in-game report 2026-10-11)
            if a.tank ~= b.tank then return a.tank end
            if a.scaled ~= b.scaled then return a.scaled > b.scaled end
            return (a.name or "") < (b.name or "")
        end)
        st.view = view
        st.hot = false
    else
        st.view = st.rows
    end
    return st
end

function Threat:GetState()
    if self:IsDemo() and ns.MeterDemo and ns.MeterDemo.Threat then return ns.MeterDemo:Threat() end
    return state
end

local function Warn(st)
    local hot = st.hot and true or false
    if hot and not wasHot and Setting("sound", true) and PlaySound then pcall(PlaySound, SOUND, "Master") end
    wasHot = hot
end

-- Would the window draw scans a and b the same? (a poll that changed nothing redraws nothing: five polls a second
-- each redrew every meter panel, ~5 MB of garbage a minute standing around; Performance page 2026-10-11)
local ROW_KEYS = { "unit", "guid", "name", "cls", "tank", "raw", "scaled", "value", "me" }
local function Same(a, b)
    if a.mob ~= b.mob or a.guid ~= b.guid or a.name ~= b.name or a.combat ~= b.combat or a.pull ~= b.pull
        or a.hot ~= b.hot or a.tankView ~= b.tankView or #a.rows ~= #b.rows then
        return false
    end
    for i, ra in ipairs(a.rows) do
        local rb = b.rows[i]
        for _, k in ipairs(ROW_KEYS) do if ra[k] ~= rb[k] then return false end end
    end
    return true
end

local function Poll()
    if not listening then return end
    if Threat:IsDemo() then
        local st = Threat:Scan()
        Warn(st)
        Changed()
        return
    end
    -- nothing to follow before or now: the scan would come out the same, so none is made (no tables either)
    if not state.mob and not Threat:Mob() and state.tankView ~= nil and state.tankView == Threat:TankView(nil) then
        return
    end
    local old = state
    local st = Threat:Scan()
    Warn(st)
    if not Same(old, st) then Changed() end
end

local function Listen(on)
    if on == listening then return end
    listening = on
    if on then
        if C_Timer and C_Timer.NewTicker then ticker = C_Timer.NewTicker(POLL, Poll) end
        Poll()
    else
        if ticker then ticker:Cancel(); ticker = nil end
        state = { rows = {} }
        wasHot = false
        Changed()
    end
end

function Threat:Refresh() Listen(self:IsEnabled()) end

function Threat:OnLogin()
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:sub(1, 7) == "meters." then Threat:Refresh() end
    end)
    ns:RegisterSlash("threat", function(arg)
        arg = (arg or ""):lower()
        if arg == "on" or arg == "off" then ns.DB:SetSetting("meters.thr", arg == "on")
        elseif ns.MeterPanels then ns.MeterPanels:Toggle() end
    end, "show or hide the threat meter (on | off)")
    self:Refresh()
end

Threat._Poll = Poll
