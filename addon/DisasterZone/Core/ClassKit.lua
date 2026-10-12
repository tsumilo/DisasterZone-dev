if DisasterZoneBoot and DisasterZoneBoot.Run("Core/ClassKit.lua", ...) then return end -- DisasterZone: class tools.
-- Class tools ("kits"): features that belong to one class, or to some of its specs, such as the Retribution swing
-- timer or the paladin Blessings planner. A kit says which class and specs it is for; everything that asks "is this
-- for me?" goes through here, so one spec check serves every kit and a respec updates them all at once.
--
--   ns.ClassKit:Register({
--       key = "swing",                    -- also the Settings section key
--       label = "Swing timer",            -- Settings nav item and section title
--       class = "PALADIN",
--       specs = { "Retribution" },        -- nil = every spec of the class
--       order = 20,                       -- Settings order among kits
--       icon = 31892,                     -- spell id or texture (Settings, menus)
--       fallback = function() ... end,    -- optional: true when the spec check can't tell (no talent points yet)
--       settings = function(SettingsUI, sec) ... end,   -- optional: fills the kit's Settings section (UI files add it)
--   })
--
-- CLASSKIT_CHANGED fires (no arguments) when the player's spec may have changed; kits then call ClassKit:IsMine(key).
-- Settings (UI/Settings.lua) gives every kit of the player's class its own section, shown while IsMine is true.
local addonName, ns = ...

local ClassKit = ns:NewModule("ClassKit")

local ipairs, pairs, type, tonumber, select = ipairs, pairs, type, tonumber, select
local tsort = table.sort

local kits, order = {}, {}

function ClassKit:Register(def)
    if type(def) ~= "table" or type(def.key) ~= "string" or type(def.class) ~= "string" then
        error("ClassKit:Register: key and class are required", 2)
    end
    if kits[def.key] then error("ClassKit:Register: '" .. def.key .. "' already exists", 2) end
    def.order = def.order or 50
    kits[def.key] = def
    order[#order + 1] = def
    tsort(order, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.key < b.key
    end)
    return def
end

function ClassKit:Get(key) return kits[key] end

-- Every kit, in Settings order; with classFile only that class's.
function ClassKit:List(classFile)
    local out = {}
    for _, k in ipairs(order) do
        if not classFile or k.class == classFile then out[#out + 1] = k end
    end
    return out
end

-- Adds fields to a kit registered elsewhere (UI files give Core kits their settings builder).
function ClassKit:Extend(key, fields)
    local k = kits[key]
    if not k then return nil end
    for f, v in pairs(fields) do k[f] = v end
    return k
end

-- ---------------------------------------------------------------------------------------------------------------
-- The player's class and spec
-- ---------------------------------------------------------------------------------------------------------------
function ClassKit:MyClass()
    local _, cls = UnitClass("player")
    return cls
end

-- Points spent in a talent tab. 2.5.6: C_SpecializationInfo.GetSpecializationInfo (points are the 7th return);
-- GetTalentTabInfo is the fallback (id, name, desc, icon, points; the old 2.4 order had points 3rd).
local function TabPoints(tab)
    local C = C_SpecializationInfo
    if C and C.GetSpecializationInfo then
        local ok, _, _, _, _, _, _, points = pcall(C.GetSpecializationInfo, tab, false, false, nil, nil, nil)
        if ok and tonumber(points) then return tonumber(points) end
    end
    if GetTalentTabInfo then
        local r1, _, r3, _, r5 = GetTalentTabInfo(tab)
        return (type(r1) == "string") and tonumber(r3) or tonumber(r5)
    end
    return nil
end
ClassKit.TabPoints = TabPoints

-- The talent tab with the most points (nil with no points spent).
function ClassKit:MyTab()
    local n = (GetNumTalentTabs and GetNumTalentTabs()) or 3
    local best, bestTab = 0, nil
    for tab = 1, n do
        local p = TabPoints(tab)
        if p and p > best then best, bestTab = p, tab end
    end
    return bestTab
end

-- The spec labels (ns.SPECS) the player's talents point to: Druids with most points in Feral are both Feral specs.
function ClassKit:MySpecs()
    local cls, tab = self:MyClass(), self:MyTab()
    local out = {}
    if not (cls and tab and ns.SPECS and ns.SPECS[cls]) then return out end
    for _, s in ipairs(ns.SPECS[cls]) do
        if s.tab == tab then out[#out + 1] = s.label end
    end
    return out
end

-- Demo mode (Core/Demo.lua): every class tool is on for anyone, with made-up data, to try them out.
function ClassKit:IsDemo()
    return ns.Util.DemoOn()
end

-- True when the kit is for this character: its class, and one of its specs (any spec when it names none); every
-- kit in demo mode.
function ClassKit:IsMine(key)
    local k = kits[key]
    if not k then return false end
    if self:IsDemo() then return true end
    if k.class ~= self:MyClass() then return false end
    if not k.specs then return true end
    local mine = self:MySpecs()
    if #mine == 0 then return k.fallback and k.fallback() and true or false end
    for _, want in ipairs(k.specs) do
        for _, have in ipairs(mine) do
            if want == have then return true end
        end
    end
    return false
end

-- Switched on (Settings > Class tools, the switch on each card): the setting '<key>.enabled', on by default. A kit
-- that is off shows nothing (no bar, no HUD, no warnings); its planner still opens.
function ClassKit:IsOn(key)
    if not kits[key] then return false end
    local v = ns.DB and ns.DB.GetSetting and ns.DB:GetSetting(key .. ".enabled")
    if v == nil then return true end
    return v and true or false
end

function ClassKit:SetOn(key, on)
    if kits[key] and ns.DB and ns.DB.SetSetting then ns.DB:SetSetting(key .. ".enabled", on and true or false) end
end

-- Kits for this character right now, in order.
function ClassKit:Mine()
    local out = {}
    for _, k in ipairs(order) do
        if self:IsMine(k.key) then out[#out + 1] = k end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------------------------
function ClassKit:OnLogin()
    local function changed() ns:Fire("CLASSKIT_CHANGED") end
    ns:RegisterEvent("PLAYER_TALENT_UPDATE", changed)
    ns:RegisterEvent("CHARACTER_POINTS_CHANGED", changed)
    ns:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", changed)   -- skipped where the client has no dual spec
    ns:On("DEMO_TOGGLED", changed)
end

-- Who a kit is for, in words: "Every Paladin spec", "Retribution Paladins".
function ClassKit:ForWhom(key)
    local k = kits[key]
    if not k then return "" end
    local cls = ns.ClassName(k.class, true) or k.class
    if not k.specs then return "Every " .. cls .. " spec" end
    return table.concat(k.specs, " and ") .. " " .. cls .. "s"
end
