if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Loon.lua", ...) then return end -- DisasterZone: Core/Loon.lua
-- "Suggest BiS" templates for My BiS, built from the BiS lists that ship with DisasterZone (Data/BiSLists.lua,
-- generated from LoonBestInSlot's class guides). Nothing is read from other addons, so every member gets the same
-- suggestions whether LoonBestInSlot is installed or not. (The module keeps its old name, ns.Loon.)
local addonName, ns = ...

local Loon = ns:NewModule("Loon")

-- The guide (key of ns.Data.BiSLists) per spec label (ns.SPECS). There is one Rogue guide ("Dps"), separate Druid
-- Cat and Bear guides, and no Discipline guide (Holy is the closest healing set).
local GUIDES = {
    WARRIOR = { Arms = "WarriorArms", Fury = "WarriorFury", Protection = "WarriorProtection" },
    PALADIN = { Holy = "PaladinHoly", Protection = "PaladinProtection", Retribution = "PaladinRetribution" },
    HUNTER = {
        ["Beast Mastery"] = "HunterBeastMastery", Marksmanship = "HunterMarksmanship", Survival = "HunterSurvival",
    },
    ROGUE = { Assassination = "RogueDps", Combat = "RogueDps", Subtlety = "RogueDps" },
    PRIEST = { Discipline = "PriestHoly", Holy = "PriestHoly", Shadow = "PriestShadow" },
    SHAMAN = { Elemental = "ShamanElemental", Enhancement = "ShamanEnhancement", Restoration = "ShamanRestoration" },
    MAGE = { Arcane = "MageArcane", Fire = "MageFire", Frost = "MageFrost" },
    WARLOCK = { Affliction = "WarlockAffliction", Demonology = "WarlockDemonology", Destruction = "WarlockDestruction" },
    DRUID = {
        Balance = "DruidBalance", ["Feral (Cat)"] = "DruidCat", ["Feral (Bear)"] = "DruidBear",
        Restoration = "DruidRestoration",
    },
}

-- The slot numbers of the data strings (the generator, gen_bis_lists.py, has the same list).
local DATA_SLOTS = {
    "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet",
    "Ring", "Trinket", "Main Hand", "Off Hand", "Two Hand", "Ranged/Relic",
}

local SIMPLE_SLOTS = {
    Head = 1, Neck = 2, Shoulder = 3, Back = 4, Chest = 5, Wrist = 6, Hands = 7, Waist = 8,
    Legs = 9, Feet = 10, ["Ranged/Relic"] = 17,
}

local templateCache = {}  -- [guide .. ":" .. phase] = template or false

local function Lists()
    local data = ns.Data and ns.Data.BiSLists
    return type(data) == "table" and data or nil
end

-- The lists ship with the addon; false only when the data file is missing (a broken install).
function Loon:IsAvailable()
    return Lists() ~= nil
end

-- { [spec label] = guide } of the class's specs that have a list.
function Loon:GetSpecFunctions(classFile)
    local out = {}
    local map = GUIDES[classFile]
    local lists = Lists()
    if not map or not lists then return out end
    for label, guide in pairs(map) do
        if type(lists[guide]) == "table" then out[label] = guide end
    end
    return out
end

-- The guide (key of ns.Data.BiSLists / ns.Data.GemGuides) of a class's spec label, or nil.
function Loon:GetGuide(classFile, specLabel)
    local map = GUIDES[classFile]
    return map and map[specLabel] or nil
end

-- Forgets the built templates (tests change ns.Data.BiSLists).
function Loon:ClearCache()
    templateCache = {}
end

---------------------------------------------------------------------------
-- Reading a list: "slot:item[*],..." -> { { slot = name, id =, rank = "BIS" | "Alt", order = }, ... }
---------------------------------------------------------------------------

local function ParseList(text)
    local out = {}
    if type(text) ~= "string" then return out end
    local order = 0
    for slot, id, bis in text:gmatch("(%d+):(%d+)(%*?)") do
        local canon = DATA_SLOTS[tonumber(slot)]
        local itemID = tonumber(id)
        if canon and itemID and itemID >= 1 and itemID <= 200000 then
            order = order + 1
            out[#out + 1] = { slot = canon, id = itemID, rank = bis == "*" and "BIS" or "Alt", order = order }
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Template building (list order = the guide's priority order)
---------------------------------------------------------------------------

local function IsBis(rank)
    return type(rank) == "string" and rank:upper():find("^BIS") ~= nil
end

local function Fits(itemID, sid)
    if ns.ItemDB and ns.ItemDB.FitsSlot then
        return ns.ItemDB:FitsSlot(itemID, sid) and true or false
    end
    return true
end

-- First BIS entry that fits (else the first entry that fits) as main; the next distinct entry as alt.
local function PickMainAlt(list, sid)
    if not list then return nil end
    local mainIdx
    for k, e in ipairs(list) do
        if IsBis(e.rank) and Fits(e.id, sid) then
            mainIdx = k
            break
        end
    end
    if not mainIdx then
        for k, e in ipairs(list) do
            if Fits(e.id, sid) then
                mainIdx = k
                break
            end
        end
    end
    if not mainIdx then return nil end
    local main = list[mainIdx].id
    for k = mainIdx + 1, #list do
        local e = list[k]
        if e.id ~= main and Fits(e.id, sid) then return main, e.id end
    end
    for k = 1, mainIdx - 1 do
        local e = list[k]
        if e.id ~= main and Fits(e.id, sid) then return main, e.id end
    end
    return main, nil
end

-- Rings / trinkets: the first two distinct BIS entries fill both slots (topped up from Alt),
-- the next two distinct entries become their alts.
local function PickPair(list, sidA, sidB, tpl)
    if not list then return end
    local picks, used = {}, {}
    for pass = 1, 2 do
        for _, e in ipairs(list) do
            if #picks >= 4 then break end
            if (pass == 1) == IsBis(e.rank) and not used[e.id] and Fits(e.id, sidA) then
                used[e.id] = true
                picks[#picks + 1] = e.id
            end
        end
    end
    if picks[1] then tpl[sidA] = { picks[1], picks[3] or 0 } end
    if picks[2] then tpl[sidB] = { picks[2], picks[4] or 0 } end
end

local function FirstBis(list, sid)
    if not list then return nil end
    for _, e in ipairs(list) do
        if IsBis(e.rank) and Fits(e.id, sid) then return e end
    end
    return nil
end

local DUAL_WIELD_FALLBACK = { WARRIOR = true, ROGUE = true, HUNTER = true, SHAMAN = true }

-- Dual-wield guides that list both weapons under "Main Hand" (e.g. Fury): the first two distinct
-- BIS entries (topped up from Alt) fill 15 and 16, the next ones become their alts.
local function PickDualFromMainHand(mainHand, tpl)
    local ordered, used = {}, {}
    for pass = 1, 2 do
        for _, e in ipairs(mainHand) do
            if (pass == 1) == IsBis(e.rank) and not used[e.id] then
                used[e.id] = true
                ordered[#ordered + 1] = e.id
            end
        end
    end
    local taken = {}
    local function take(sid)
        for k, id in ipairs(ordered) do
            if not taken[k] and Fits(id, sid) then
                taken[k] = true
                return id
            end
        end
        return nil
    end
    local main15, main16 = take(15), nil
    if main15 then main16 = take(16) end
    local alt15 = main15 and take(15)
    local alt16 = main16 and take(16)
    if main15 then tpl[15] = { main15, alt15 or 0 } end
    if main16 then tpl[16] = { main16, alt16 or 0 } end
end

-- A Two Hand BIS listed before the first Main Hand BIS wins slot 15 and leaves 16 empty.
local function PickWeapons(mainHand, twoHand, offHand, tpl, dualWield)
    local mh, th = FirstBis(mainHand, 15), FirstBis(twoHand, 15)
    local main, alt
    local useTwoHand = th and (not mh or th.order < mh.order)
    if useTwoHand then
        main, alt = PickMainAlt(twoHand, 15)
    elseif mh then
        main, alt = PickMainAlt(mainHand, 15)
    else
        -- no BIS weapon at all: take whichever weapon entry comes first
        local combined = {}
        for _, e in ipairs(mainHand or {}) do combined[#combined + 1] = e end
        for _, e in ipairs(twoHand or {}) do combined[#combined + 1] = e end
        table.sort(combined, function(a, b) return a.order < b.order end)
        main, alt = PickMainAlt(combined, 15)
        local first = combined[1]
        useTwoHand = first ~= nil and first.slot == "Two Hand" and first.id == main
    end
    if main then tpl[15] = { main, alt or 0 } end
    if not useTwoHand then
        local ohMain, ohAlt = PickMainAlt(offHand, 16)
        if ohMain then
            tpl[16] = { ohMain, ohAlt or 0 }
        elseif dualWield and mainHand then
            PickDualFromMainHand(mainHand, tpl)
        end
    end
end

local function BuildTemplate(entries, classFile)
    if type(entries) ~= "table" or #entries == 0 then return nil end
    local bySlot = {}
    for _, e in ipairs(entries) do
        local list = bySlot[e.slot]
        if not list then
            list = {}
            bySlot[e.slot] = list
        end
        list[#list + 1] = e
    end
    local tpl = {}
    for canon, sid in pairs(SIMPLE_SLOTS) do
        local main, alt = PickMainAlt(bySlot[canon], sid)
        if main then tpl[sid] = { main, alt or 0 } end
    end
    PickPair(bySlot["Ring"], 11, 12, tpl)
    PickPair(bySlot["Trinket"], 13, 14, tpl)
    local dual = (ns.DUAL_WIELD or DUAL_WIELD_FALLBACK)[classFile] and true or false
    PickWeapons(bySlot["Main Hand"], bySlot["Two Hand"], bySlot["Off Hand"], tpl, dual)
    if next(tpl) == nil then return nil end
    return tpl
end

local function CopyTemplate(tpl)
    local out = {}
    for sid, s in pairs(tpl) do
        out[sid] = { s[1], s[2] }
    end
    return out
end

-- Returns { [sid] = {mainID, altID} } (0 = empty) for a spec and phase 0..5 (0 = the guide's Pre-raid list), or nil.
function Loon:GetTemplate(classFile, specLabel, phase)
    phase = tonumber(phase)
    if not phase or phase < 0 or phase > (ns.MAX_PHASE or 5) or phase ~= math.floor(phase) then return nil end
    local lists = Lists()
    local guide = GUIDES[classFile] and GUIDES[classFile][specLabel]
    local byPhase = lists and guide and lists[guide]
    if type(byPhase) ~= "table" then return nil end

    local key = guide .. ":" .. phase
    local tpl = templateCache[key]
    if tpl == nil then
        tpl = false
        local ok, result = pcall(BuildTemplate, ParseList(byPhase[phase]), classFile)
        if ok and result then
            tpl = result
        elseif not ok then
            ns:Debug("BiS lists: template error: %s", tostring(result))
        end
        templateCache[key] = tpl
    end
    if not tpl then return nil end
    return CopyTemplate(tpl)
end
