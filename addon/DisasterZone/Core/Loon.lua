if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Loon.lua", ...) then return end -- DisasterZone: Core/Loon.lua
-- Optional "Suggest BiS" templates captured at runtime from LoonBestInSlot's guides.
-- DisasterZone never requires LoonBestInSlot: without it every function here returns nothing.
local addonName, ns = ...

local Loon = ns:NewModule("Loon")

-- Loader names from LoonBestInSlot/Guides/*.lua (function LBIS:Load<Class><Spec>()),
-- keyed by our spec labels (ns.SPECS). Loon has one Rogue guide ("Dps"), separate Druid
-- Cat and Bear guides, and no Discipline guide (Holy is the closest healing set).
local LOADERS = {
    WARRIOR = { Arms = "LoadWarriorArms", Fury = "LoadWarriorFury", Protection = "LoadWarriorProtection" },
    PALADIN = { Holy = "LoadPaladinHoly", Protection = "LoadPaladinProtection", Retribution = "LoadPaladinRetribution" },
    HUNTER = {
        ["Beast Mastery"] = "LoadHunterBeastMastery", Marksmanship = "LoadHunterMarksmanship",
        Survival = "LoadHunterSurvival",
    },
    ROGUE = { Assassination = "LoadRogueDps", Combat = "LoadRogueDps", Subtlety = "LoadRogueDps" },
    PRIEST = { Discipline = "LoadPriestHoly", Holy = "LoadPriestHoly", Shadow = "LoadPriestShadow" },
    SHAMAN = { Elemental = "LoadShamanElemental", Enhancement = "LoadShamanEnhancement", Restoration = "LoadShamanRestoration" },
    MAGE = { Arcane = "LoadMageArcane", Fire = "LoadMageFire", Frost = "LoadMageFrost" },
    WARLOCK = { Affliction = "LoadWarlockAffliction", Demonology = "LoadWarlockDemonology", Destruction = "LoadWarlockDestruction" },
    DRUID = {
        Balance = "LoadDruidBalance", ["Feral (Cat)"] = "LoadDruidCat", ["Feral (Bear)"] = "LoadDruidBear",
        Restoration = "LoadDruidRestoration",
    },
}

-- Loon's canonical (English) slot keys; guides pass them through LBIS.L[...] (localized).
local CANON_SLOTS = {
    "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet",
    "Ring", "Trinket", "Main Hand", "Off Hand", "Two Hand", "Ranged/Relic",
}

local SIMPLE_SLOTS = {
    Head = 1, Neck = 2, Shoulder = 3, Back = 4, Chest = 5, Wrist = 6, Hands = 7, Waist = 8,
    Legs = 9, Feet = 10, ["Ranged/Relic"] = 17,
}

local captureCache = {}   -- [loaderName] = { [phase] = { {slot=, id=, rank=, order=}, ... } } or false
local templateCache = {}  -- [loaderName .. ":" .. phase] = template or false

local function GetLBIS()
    local lbis = _G.LBIS
    if type(lbis) == "table" then return lbis end
    return nil
end

function Loon:IsAvailable()
    local lbis = GetLBIS()
    return lbis ~= nil and type(lbis.RegisterSpec) == "function"
end

function Loon:GetSpecFunctions(classFile)
    local out = {}
    local map = LOADERS[classFile]
    local lbis = GetLBIS()
    if not map or not lbis or not self:IsAvailable() then return out end
    for label, fnName in pairs(map) do
        if type(lbis[fnName]) == "function" then out[label] = fnName end
    end
    return out
end

---------------------------------------------------------------------------
-- Capture: run one Loon guide loader with RegisterSpec/AddItem/AddGem/AddEnchant replaced
-- by recorders. Loon's originals are ALWAYS put back, whatever the loader does.
---------------------------------------------------------------------------

local function BuildSlotReverseMap(lbis)
    local rev = {}
    local L = lbis.L
    for _, canon in ipairs(CANON_SLOTS) do
        local localized = type(L) == "table" and L[canon] or nil   -- Loon's L falls back to the key
        if type(localized) == "string" and rev[localized] == nil then rev[localized] = canon end
    end
    for _, canon in ipairs(CANON_SLOTS) do
        if rev[canon] == nil then rev[canon] = canon end
    end
    return rev
end

local function Capture(fnName)
    local lbis = GetLBIS()
    local loader = lbis and lbis[fnName]
    if type(loader) ~= "function" then return nil end

    local okMap, rev = pcall(BuildSlotReverseMap, lbis)
    if not okMap then
        ns:Debug("Loon: slot names unreadable: %s", tostring(rev))
        return nil
    end

    local out, order = {}, 0
    local function registerSpec(_, _, _, phase)
        return { cdlPhase = tonumber(phase) }
    end
    local function addItem(_, entry, id, slot, rank)
        local phase = type(entry) == "table" and entry.cdlPhase
        local itemID = tonumber(id)
        local canon = type(slot) == "string" and rev[slot]
        if not (phase and itemID and canon) then return end
        if itemID < 1 or itemID > 200000 or itemID ~= math.floor(itemID) then return end
        order = order + 1
        local list = out[phase]
        if not list then
            list = {}
            out[phase] = list
        end
        list[#list + 1] = { slot = canon, id = itemID, rank = type(rank) == "string" and rank or "", order = order }
    end
    local function ignore() end

    local origRegister, origAddItem = lbis.RegisterSpec, lbis.AddItem
    local origAddGem, origAddEnchant = lbis.AddGem, lbis.AddEnchant
    lbis.RegisterSpec, lbis.AddItem, lbis.AddGem, lbis.AddEnchant = registerSpec, addItem, ignore, ignore
    local ok, err = pcall(loader, lbis)
    lbis.RegisterSpec, lbis.AddItem, lbis.AddGem, lbis.AddEnchant = origRegister, origAddItem, origAddGem, origAddEnchant

    if not ok then
        ns:Debug("Loon: %s failed: %s", fnName, tostring(err))
        return nil
    end
    return out
end

---------------------------------------------------------------------------
-- Template building (file order = Loon's priority order)
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

-- Returns { [sid] = {mainID, altID} } (0 = empty) for a spec and phase 1..5, or nil.
function Loon:GetTemplate(classFile, specLabel, phase)
    phase = tonumber(phase)
    if not phase or phase < 1 or phase > (ns.MAX_PHASE or 5) or phase ~= math.floor(phase) then return nil end
    if not self:IsAvailable() then return nil end
    local fnName = LOADERS[classFile] and LOADERS[classFile][specLabel]
    if not fnName then return nil end

    local key = fnName .. ":" .. phase
    local tpl = templateCache[key]
    if tpl == nil then
        local captured = captureCache[fnName]
        if captured == nil then
            local ok, result = pcall(Capture, fnName)
            captured = ok and result or false
            if not ok then ns:Debug("Loon: capture error: %s", tostring(result)) end
            captureCache[fnName] = captured
        end
        tpl = false
        if captured then
            local ok, result = pcall(BuildTemplate, captured[phase], classFile)
            if ok and result then
                tpl = result
            elseif not ok then
                ns:Debug("Loon: template error: %s", tostring(result))
            end
        end
        templateCache[key] = tpl
    end
    if not tpl then return nil end
    return CopyTemplate(tpl)
end
