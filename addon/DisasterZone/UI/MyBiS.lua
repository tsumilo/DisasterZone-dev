if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MyBiS.lua", ...) then return end -- DisasterZone UI/MyBiS.lua
-- ns.MyBiS: the "My BiS" tab - phase buttons, spec, copy / suggest / clear tools, the editable
-- paper doll and the progress card (what's obtained, which raids still have loot for you).
-- ADDENDUM F: slots can be disabled per phase from the tile menu (§36; left out of the progress card),
-- crafted / reputation / badge / PvP items get their own "Still needed from" lines (§37), and while the
-- group's raid leader locks the BiS lists a banner shows and the editing controls are disabled (§38).
-- ADDENDUM H: [Main spec] / [Off spec] buttons switch the whole tab (doll, spec, tools, card) between the two lists.
local addonName, ns = ...

local MyBiS = {}
ns.MyBiS = MyBiS

local NUM_SLOTS = 17
local AUTO_SPEC = "__auto"
local REMOVE_OS = "__removeos"
local LOCK_BANNER_H = 40
local FOOTER_TEXT = "Click a slot to choose  ·  Right-click for options  ·  Drag items from your bags onto a slot  ·  Shift-click to link"
local FOOTER_LOCKED = "BiS lists are locked during the raid  ·  Obtained items still update  ·  Right-click a slot to mark it obtained"

-- "Still needed from" lines for the non-raid sources (§37), after the raids and the 5-man line.
local KIND_LINES = {
    { kind = "craft", label = "Crafted" },
    { kind = "rep",   label = "Reputation" },
    { kind = "badge", label = "Badges" },
    { kind = "pvp",   label = "PvP" },
}

local panel, doll, card, footer
local phaseButtons = {}
local specDD, copyBtn, suggestBtn, clearBtn, msBtn, osBtn
local selectedPhase, userPickedPhase
local selectedList = "ms"   -- Addendum H: "ms" | "os" (session only)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function MaxPhase() return ns.MAX_PHASE or 5 end

local function ClampPhase(p)
    p = tonumber(p) or 1
    if p < 1 then p = 1 end
    if p > MaxPhase() then p = MaxPhase() end
    return math.floor(p)
end

local function GuildPhase()
    if ns.Guild and ns.Guild.GetGuildPhase then
        local p = ns.Guild:GetGuildPhase()
        if tonumber(p) then return ClampPhase(p) end
    end
    return nil
end

local function CurrentPhase()
    if not selectedPhase then selectedPhase = GuildPhase() or 1 end
    return selectedPhase
end

-- The list argument for BiS calls: "os" while the off-spec list is shown, else nil (the main spec).
local function ListArg()
    return selectedList == "os" and "os" or nil
end

local function IsOffSpecView()
    return selectedList == "os"
end

local function HasOffSpec()
    return ns.BiS and ns.BiS.HasOffSpec and ns.BiS:HasOffSpec() or false
end

local function MyClass()
    local data = ns.BiS and ns.BiS.GetData and ns.BiS:GetData()
    if data and type(data.cl) == "string" and data.cl ~= "" then return data.cl end
    local _, classFile = UnitClass("player")
    return classFile
end

local function SlotLabel(sid)
    local s = ns.SLOTS and ns.SLOTS[sid]
    return s and s.label or ("Slot " .. tostring(sid))
end

local function PhaseItems(p)
    if not (ns.BiS and ns.BiS.GetPhaseItems) then return {} end
    return ns.BiS:GetPhaseItems(p, ListArg()) or {}
end

-- "Prince Malchezaar" -> "Malchezaar", "The Curator" -> "Curator", "High King Maulgar" -> "Maulgar".
local TITLE_WORDS = {
    ["The"] = true, ["High"] = true, ["King"] = true, ["Lady"] = true, ["Prince"] = true,
    ["Mother"] = true, ["Fathom-Lord"] = true, ["Astromancer"] = true, ["Warlord"] = true, ["Lord"] = true,
}
local function ShortBossName(name)
    if type(name) ~= "string" then return "?" end
    for word in name:gmatch("%S+") do
        if not TITLE_WORDS[word] then return word end
    end
    return name
end

-- The progress card's single "5-man dungeons" line (sorted after every raid).
local DUNGEON_GROUP = { key = "Dungeons", name = "5-man dungeons", phase = 100 }

-- "The Black Morass" -> "Black Morass"
local function DungeonShortName(dungeon)
    local name = type(dungeon) == "table" and (dungeon.name or dungeon.key) or nil
    if type(name) ~= "string" or name == "" then return "?" end
    return (name:gsub("^The ", ""))
end

local function Debounce(key, sec, fn)
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce(key, sec, fn)
    else
        C_Timer.After(sec, fn)
    end
end

-- §38: my list is locked by the group's raid leader (BiS:IsLocked). locked, { by, at } | nil.
local function ListLocked()
    if ns.UI and ns.UI.IsMyListLocked then return ns.UI:IsMyListLocked() end
    return false, nil
end

-- §36: the slot is disabled in that phase (BiS:IsSlotDisabled; else the own record's dx).
local function SlotDisabled(phase, sid)
    local BiS = ns.BiS
    if not BiS then return false end
    if type(BiS.IsSlotDisabled) == "function" then return BiS:IsSlotDisabled(phase, sid, ListArg()) and true or false end
    local PD = ns.PaperDoll
    if PD and PD.IsSlotDisabled and BiS.GetRecord then return PD:IsSlotDisabled(BiS:GetRecord(), phase, sid) end
    return false
end

local function DisabledInAllPhases(sid)
    for p = 1, MaxPhase() do
        if not SlotDisabled(p, sid) then return false end
    end
    return true
end

local function CanDisableSlots()
    local BiS = ns.BiS
    return BiS and type(BiS.SetSlotDisabled) == "function" and type(BiS.SetSlotDisabledAllPhases) == "function"
end

local function SetSlotDisabled(phase, sid, disabled)
    if not CanDisableSlots() then
        ns:Print("This DisasterZone version can't disable slots.")
        return false
    end
    return ns.BiS:SetSlotDisabled(phase, sid, disabled and true or false, ListArg())
end

local function SetSlotDisabledAll(sid, disabled)
    if not CanDisableSlots() then
        ns:Print("This DisasterZone version can't disable slots.")
        return false
    end
    return ns.BiS:SetSlotDisabledAllPhases(sid, disabled and true or false, ListArg())
end

-- Primary source kind of an item: "raid" | "dungeon" | "craft" | "rep" | "badge" | "pvp" | nil (§37).
local function SourceKind(itemID)
    local ItemDB = ns.ItemDB
    if not ItemDB then return nil end
    if type(ItemDB.GetSourceKind) == "function" then
        local k = ItemDB:GetSourceKind(itemID)
        if k ~= nil then return k end
    end
    local sources = ItemDB.GetSources and ItemDB:GetSources(itemID)
    local first = type(sources) == "table" and sources[1] or nil
    if type(first) ~= "table" then return nil end
    if type(first.kind) == "string" then return first.kind end
    if type(first.ref) == "table" then return first.ref.dungeon == true and "dungeon" or "raid" end
    return nil
end

-- The group name of an item's first source of `kind` (profession, faction, vendor, season).
local function SourceGroupName(itemID, kind)
    local ItemDB = ns.ItemDB
    local sources = ItemDB and ItemDB.GetSources and ItemDB:GetSources(itemID)
    if type(sources) ~= "table" then return nil end
    for _, e in ipairs(sources) do
        if type(e) == "table" and e.kind == kind then
            local g = e.group or e.craft or e.rep or e.badge or e.pvp
            local name = e.groupName or (type(g) == "table" and g.name) or nil
            if type(name) == "string" then return name end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Popups (defined lazily; only DISASTERZONE_* names)
---------------------------------------------------------------------------

local popupsReady = false
local function EnsurePopups()
    if popupsReady then return end
    popupsReady = true
    StaticPopupDialogs["DISASTERZONE_CLEAR_PHASE"] = {
        text = "Clear every main and alt pick in %s?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data)
            if data and data.phase and ns.BiS then ns.BiS:ClearPhase(data.phase, data.list) end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopupDialogs["DISASTERZONE_REPLACE_TEMPLATE"] = {
        text = "Replace every pick in %s with the suggested BiS list for %s?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data)
            if data then MyBiS:ApplySuggestion(data.phase, true, data.list) end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopupDialogs["DISASTERZONE_REMOVE_OFFSPEC"] = {
        text = "Remove your off-spec list and all its picks?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function()
            if ns.BiS and ns.BiS:RemoveOffSpec() then
                selectedList = "ms"
                MyBiS:Refresh()
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function OpenPicker(sid, which, tile)
    if not (ns.Picker and ns.Picker.Open) then return end
    -- The picker refuses (and says why) while the lists are locked (§38).
    if ns.Picker:Open(CurrentPhase(), sid, which, tile, ListArg()) == false then return end
    if doll then doll:SetHighlight(sid) end
end

function MyBiS:OnPickerClosed()
    if doll then doll:SetHighlight(nil) end
end

-- list: "os" = fill the off-spec list from its spec (default: the list shown).
function MyBiS:ApplySuggestion(phase, overwrite, list)
    local BiS, Loon = ns.BiS, ns.Loon
    if not (BiS and Loon and Loon.IsAvailable and Loon:IsAvailable()) then
        ns:Print("The suggested BiS lists are missing: reinstall DisasterZone.")
        return
    end
    if list == nil then list = ListArg() end
    local spec = BiS:GetSpec(list) or ""
    if spec == "" then
        ns:Print("Choose your spec first (Spec dropdown).")
        return
    end
    phase = ClampPhase(phase or CurrentPhase())
    local template = Loon:GetTemplate(MyClass(), spec, phase)
    if type(template) ~= "table" or next(template) == nil then
        ns:Print("There is no suggested %s list for P%d.", spec, phase)
        return
    end
    -- false: refused (the lists were locked meanwhile, e.g. while the "Replace all" popup was open; §38)
    if BiS:ApplyTemplate(phase, template, overwrite and true or false, list) == false then return end
    if overwrite then
        ns:Print("Replaced P%d with the suggested %s list.", phase, spec)
    else
        ns:Print("Filled empty P%d slots from the suggested %s list.", phase, spec)
    end
end

-- A menu button that is greyed out while the lists are locked (the BiS editing APIs refuse then).
local function EditButton(root, text, fn, locked)
    local b = root:CreateButton(text, fn)
    if locked and b and b.SetEnabled then b:SetEnabled(false) end
    return b
end

-- "Disable slot (P1)" / "Enable slot (P1)" and "Disable in all phases" / "Enable in all phases" (§36).
local function AddDisableEntries(root, phase, sid, locked)
    if not CanDisableSlots() then return end
    if SlotDisabled(phase, sid) then
        EditButton(root, ("Enable slot (P%d)"):format(phase), function() SetSlotDisabled(phase, sid, false) end, locked)
    else
        EditButton(root, ("Disable slot (P%d)"):format(phase), function() SetSlotDisabled(phase, sid, true) end, locked)
    end
    if DisabledInAllPhases(sid) then
        EditButton(root, "Enable in all phases", function() SetSlotDisabledAll(sid, false) end, locked)
    else
        EditButton(root, "Disable in all phases", function() SetSlotDisabledAll(sid, true) end, locked)
    end
end

local function ShowSlotMenu(sid, tile)
    local BiS = ns.BiS
    if not BiS then return end
    local phase = CurrentPhase()
    local list = ListArg()
    local main, alt = BiS:GetSlot(phase, sid, list)
    local locked = ListLocked()
    local disabled = SlotDisabled(phase, sid)
    local suffix = list and "  ·  Off spec" or ""
    ns.UI:ContextMenu(tile, function(root)
        if disabled then
            -- A disabled slot only offers to enable it (its picks are kept).
            root:CreateTitle(SlotLabel(sid) .. "  ·  P" .. phase .. suffix .. "  ·  disabled")
            AddDisableEntries(root, phase, sid, locked)
            if main or alt then
                if root.CreateDivider then root:CreateDivider() end
                EditButton(root, "Clear slot", function() BiS:ClearSlot(phase, sid, list) end, locked)
            end
            if main then
                root:CreateButton("Link main in chat", function() ns.UI:LinkInChat(main) end)
            end
            return
        end
        root:CreateTitle(SlotLabel(sid) .. "  ·  P" .. phase .. suffix)
        EditButton(root, "Choose main...", function() OpenPicker(sid, "main", tile) end, locked)
        EditButton(root, "Choose alt...", function() OpenPicker(sid, "alt", tile) end, locked)
        if main or alt then
            EditButton(root, "Swap main / alt", function() BiS:SwapMainAlt(phase, sid, list) end, locked)
        end
        if main then
            -- Manual "obtained" marks still work while the lists are locked (§38).
            local state = BiS:GetObtainedState(main)
            if state == nil then
                root:CreateButton("Mark obtained", function() BiS:SetManualObtained(main, true) end)
            elseif state == "manual" then
                root:CreateButton("Mark not obtained", function() BiS:SetManualObtained(main, false) end)
            else
                root:CreateTitle("Obtained: " .. (ns.UI.OBTAINED_LABELS[state] or state))
            end
        end
        if main or alt then
            EditButton(root, "Clear slot", function() BiS:ClearSlot(phase, sid, list) end, locked)
        end
        if main then
            root:CreateButton("Link main in chat", function() ns.UI:LinkInChat(main) end)
        end
        if CanDisableSlots() then
            if root.CreateDivider then root:CreateDivider() end
            AddDisableEntries(root, phase, sid, locked)
        end
    end)
end

local function OnSlotClick(sid, which, mouseButton, tile)
    if mouseButton == "RightButton" or SlotDisabled(CurrentPhase(), sid) then
        -- clicking a disabled slot offers "Enable slot"
        ShowSlotMenu(sid, tile)
    else
        OpenPicker(sid, which, tile)
    end
end

local function OnSlotReceiveItem(sid, itemID, which)
    if not ns.BiS then return end
    local phase = CurrentPhase()
    if SlotDisabled(phase, sid) then
        ns:Print("%s is disabled in P%d: enable the slot first (click it).", SlotLabel(sid), phase)
        return
    end
    ns.BiS:SetSlot(phase, sid, which == "alt" and "alt" or "main", itemID, ListArg())
end

function MyBiS:SetPhase(p, byUser)
    p = ClampPhase(p)
    if byUser then userPickedPhase = true end
    if p == selectedPhase and panel then
        self:Refresh()
        return
    end
    selectedPhase = p
    if ns.Picker and ns.Picker.IsOpen and ns.Picker:IsOpen() then ns.Picker:Close() end
    self:Refresh()
end

function MyBiS:GetPhase()
    return CurrentPhase()
end

-- Addendum H: show the main-spec ("ms") or the off-spec ("os") list.
function MyBiS:SetList(list)
    list = (list == "os") and "os" or "ms"
    if list == selectedList then return end
    selectedList = list
    if ns.Picker and ns.Picker.IsOpen and ns.Picker:IsOpen() then ns.Picker:Close() end
    self:Refresh()
end

function MyBiS:GetList()
    return selectedList
end

-- "Remove off-spec list..." (the off-spec spec dropdown): asks, then deletes the list and shows the main spec.
function MyBiS:ConfirmRemoveOffSpec()
    if not HasOffSpec() then return false end
    EnsurePopups()
    StaticPopup_Show("DISASTERZONE_REMOVE_OFFSPEC")
    return true
end

---------------------------------------------------------------------------
-- Menus & dropdown content
---------------------------------------------------------------------------

local function SpecOptions()
    local opts = {}
    local specs = ns.SPECS and ns.SPECS[MyClass()] or {}
    for _, s in ipairs(specs) do
        if s.label then opts[#opts + 1] = { value = s.label, text = s.label } end
    end
    if IsOffSpecView() then
        -- The off spec is always chosen by hand; it can be removed from here.
        if HasOffSpec() then
            opts[#opts + 1] = { value = REMOVE_OS, text = "Remove off-spec list...",
                tooltip = "Deletes the off-spec list and its picks (asks first)." }
        end
        return opts
    end
    opts[#opts + 1] = { value = AUTO_SPEC, text = "Auto-detect", tooltip = "Use the talent tree with the most points." }
    return opts
end

local function SelectedSpec()
    return ns.BiS and ns.BiS.GetSpec and ns.BiS:GetSpec(ListArg()) or nil
end

local function OnSpecSelected(value)
    local BiS = ns.BiS
    if not BiS then return end
    if value == REMOVE_OS then
        MyBiS:ConfirmRemoveOffSpec()
    elseif IsOffSpecView() then
        BiS:SetSpec(value, "os")
    elseif value == AUTO_SPEC then
        local spec = BiS:DetectSpec()
        if spec and spec ~= "" then
            -- (SetSpec refuses and says why while the lists are locked, §38)
            if BiS:SetSpec(spec) then ns:Print("Spec detected: %s", spec) end
        else
            ns:Print("Couldn't detect a spec (no talent points spent yet).")
        end
    else
        BiS:SetSpec(value)
    end
    if specDD then specDD:Refresh() end
    MyBiS:Refresh()
end

local function BuildCopyMenu(root)
    local BiS = ns.BiS
    local phase = CurrentPhase()
    local list = ListArg()
    root:CreateTitle("Copy into P" .. phase .. (list and " (off spec)" or ""))
    local any = false
    for p = 1, MaxPhase() do
        if p ~= phase and #PhaseItems(p) > 0 then
            any = true
            root:CreateButton(("Copy P%d (fill empty)"):format(p), function()
                if BiS then BiS:CopyPhase(p, phase, false, list) end
            end)
            root:CreateButton(("Copy P%d (overwrite)"):format(p), function()
                if BiS then BiS:CopyPhase(p, phase, true, list) end
            end)
        end
    end
    -- Addendum H: the other list of the same phase (shared items such as rings, trinkets and cloaks).
    local other = (not list) and "os" or nil
    local otherName = list and "main spec" or "off spec"
    if BiS and (list or HasOffSpec()) and #(BiS:GetPhaseItems(phase, other) or {}) > 0 then
        any = true
        if root.CreateDivider then root:CreateDivider() end
        root:CreateButton(("Copy %s P%d (fill empty)"):format(otherName, phase), function()
            BiS:CopyPhase(phase, phase, false, list, other)
        end)
        root:CreateButton(("Copy %s P%d (overwrite)"):format(otherName, phase), function()
            BiS:CopyPhase(phase, phase, true, list, other)
        end)
    end
    if not any then
        root:CreateTitle("No other phase has items yet")
    end
end

local function BuildSuggestMenu(root)
    local phase = CurrentPhase()
    local spec = SelectedSpec() or ""
    root:CreateTitle("Suggested BiS list")
    if not (ns.Loon and ns.Loon.IsAvailable and ns.Loon:IsAvailable()) then
        root:CreateTitle("The lists are missing: reinstall DisasterZone")
        return
    end
    if spec == "" then
        root:CreateTitle("Choose your spec first")
        return
    end
    root:CreateButton(("Fill empty slots (%s P%d)"):format(spec, phase), function()
        MyBiS:ApplySuggestion(phase, false)
    end)
    root:CreateButton("Replace all (confirm)", function()
        EnsurePopups()
        StaticPopup_Show("DISASTERZONE_REPLACE_TEMPLATE", "P" .. phase .. (ListArg() and " (off spec)" or ""), spec,
            { phase = phase, list = ListArg() })
    end)
end

---------------------------------------------------------------------------
-- Progress card
---------------------------------------------------------------------------

-- §37: a crafted / rep / badge / PvP item still needed, grouped per kind ("Crafted (2)").
local function AddKindItem(result, kind, itemID, sid)
    local entry = result.kinds[kind]
    if not entry then
        entry = { kind = kind, count = 0, items = {}, groups = {}, groupOrder = {} }
        result.kinds[kind] = entry
    end
    entry.count = entry.count + 1
    local gname = SourceGroupName(itemID, kind) or "?"
    if not entry.groups[gname] then
        entry.groups[gname] = 0
        entry.groupOrder[#entry.groupOrder + 1] = gname
    end
    entry.groups[gname] = entry.groups[gname] + 1
    local src = ns.ItemDB and ns.ItemDB.GetSourceText and ns.ItemDB:GetSourceText(itemID, true) or gname
    entry.items[#entry.items + 1] = { itemID = itemID, boss = src, sid = sid }
end

local function ComputeProgress(phase)
    local BiS, ItemDB = ns.BiS, ns.ItemDB
    local result = { filled = 0, obtained = 0, total = NUM_SLOTS, disabled = 0, raids = {}, other = 0,
                     otherItems = {}, kinds = {} }
    local data = BiS and (BiS.GetListView and BiS:GetListView(ListArg()) or BiS:GetData())
    for sid = 1, NUM_SLOTS do
        if SlotDisabled(phase, sid) then result.disabled = result.disabled + 1 end
    end
    result.total = NUM_SLOTS - result.disabled
    local ph = data and type(data.ph) == "table" and data.ph[phase]
    if type(ph) ~= "table" then return result end

    local byRaid = {}
    for sid = 1, NUM_SLOTS do
        local e = ph[sid]
        local main = type(e) == "table" and tonumber(e[1]) or nil
        if main and main > 0 and not SlotDisabled(phase, sid) then
            result.filled = result.filled + 1
            local kind = SourceKind(main)
            if BiS:IsObtained(main) then
                result.obtained = result.obtained + 1
            elseif kind == "craft" or kind == "rep" or kind == "badge" or kind == "pvp" then
                AddKindItem(result, kind, main, sid)
            else
                local sources = ItemDB and ItemDB:GetSources(main)
                local ref = type(sources) == "table" and sources[1] and sources[1].ref or nil
                local raid, boss = ref and ref.raid, ref and ref.boss
                if raid and boss then
                    -- All 5-man dungeons share one line after the raids, counted per dungeon.
                    local dungeon = ref.dungeon == true
                    local group = dungeon and DUNGEON_GROUP or raid
                    local entry = byRaid[group]
                    if not entry then
                        entry = { raid = group, count = 0, bosses = {}, bossOrder = {}, items = {}, dungeon = dungeon }
                        byRaid[group] = entry
                        result.raids[#result.raids + 1] = entry
                    end
                    entry.count = entry.count + 1
                    local bname = boss.name or "?"
                    if dungeon then bname = DungeonShortName(raid) end
                    if not entry.bosses[bname] then
                        entry.bosses[bname] = 0
                        entry.bossOrder[#entry.bossOrder + 1] = bname
                    end
                    entry.bosses[bname] = entry.bosses[bname] + 1
                    local itemBoss = dungeon and ((boss.name or "?") .. " (" .. bname .. ")") or bname
                    entry.items[#entry.items + 1] = { itemID = main, boss = itemBoss, sid = sid }
                else
                    result.other = result.other + 1
                    result.otherItems[#result.otherItems + 1] = { itemID = main, sid = sid }
                end
            end
        end
    end

    -- a two-hander leaves the off hand intentionally empty (unless one of them is disabled anyway)
    local mh = type(ph[15]) == "table" and tonumber(ph[15][1]) or nil
    local oh = type(ph[16]) == "table" and tonumber(ph[16][1]) or nil
    if mh and mh > 0 and not (oh and oh > 0) and ItemDB and ItemDB:GetEquipLoc(mh) == "INVTYPE_2HWEAPON"
        and not SlotDisabled(phase, 15) and not SlotDisabled(phase, 16) then
        result.total = result.total - 1
    end

    table.sort(result.raids, function(a, b)
        local pa, pb = tonumber(a.raid.phase) or 99, tonumber(b.raid.phase) or 99
        if pa ~= pb then return pa < pb end
        return (a.raid.name or "") < (b.raid.name or "")
    end)
    for _, entry in ipairs(result.raids) do
        table.sort(entry.bossOrder, function(x, y)
            if entry.bosses[x] ~= entry.bosses[y] then return entry.bosses[x] > entry.bosses[y] end
            return x < y
        end)
    end
    return result
end

-- §38: "BiS lists are locked" banner at the top of the card (shown while my list is locked).
local function CreateLockBanner(c)
    local UI = ns.UI
    local b = CreateFrame("Frame", nil, c, "BackdropTemplate")
    b:SetPoint("TOPLEFT", c, "TOPLEFT", 8, -8)
    b:SetPoint("TOPRIGHT", c, "TOPRIGHT", -8, -8)
    b:SetHeight(LOCK_BANNER_H)
    if b.SetBackdrop then
        b:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        b:SetBackdropColor(0.35, 0.10, 0.02, 0.85)
        b:SetBackdropBorderColor(1, 0.55, 0.2, 0.9)
    end
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("LEFT", b, "LEFT", 8, 0)
    b.icon:SetTexture(UI.ICON_LOCK or "Interface\\PetBattles\\PetBattle-LockIcon")
    b.title = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.title:SetPoint("TOPLEFT", b, "TOPLEFT", 32, -6)
    b.title:SetPoint("RIGHT", b, "RIGHT", -8, 0)
    b.title:SetJustifyH("LEFT")
    b.title:SetWordWrap(false)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("TOPLEFT", b.title, "BOTTOMLEFT", 0, -3)
    b.text:SetPoint("RIGHT", b, "RIGHT", -8, 0)
    b.text:SetJustifyH("LEFT")
    b.text:SetWordWrap(false)
    b.text:SetText("Obtained items still update.")
    b:EnableMouse(true)
    b:SetScript("OnEnter", function(self)
        local _, info = ListLocked()
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("BiS lists are locked", 1, 0.82, 0)
        GameTooltip:AddLine(("%s locked every BiS list in the group for the raid. You can't change picks, "
            .. "spec or disabled slots until they unlock the lists or the group disbands. Items you get "
            .. "(and \"Mark obtained\") still update."):format(ns.UI:LockByText(info, true)), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    return b
end

-- The centre card: the player model wearing the phase's BiS picks. A slot that is empty, disabled or
-- holds something that can't be worn (a tier token) keeps the currently equipped item.
local function CreateCard(parent)
    local UI = ns.UI
    local c = UI:CreatePanel(parent)
    c:SetAllPoints(parent)

    c.lockBanner = CreateLockBanner(c)

    c.title = UI:CreateLabel(c, "", "GameFontNormal")
    c.title:SetPoint("TOPLEFT", c, "TOPLEFT", 12, -12)

    local m = UI:CreateBiSModel(c)
    m:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", -8, -4)
    m:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -4, 4)
    m:SetScript("OnShow", function() if c.phase then c:Dress(c.phase) end end)
    c.model = m

    c.hint = UI:CreateLabel(c, "Drag to rotate", "GameFontDisableSmall")
    c.hint:SetPoint("BOTTOM", c, "BOTTOM", 0, 8)

    function c:Dress(phase)
        self.phase = phase
        if not self.model:IsVisible() then return end
        local BiS = ns.BiS
        local data = BiS and (BiS.GetListView and BiS:GetListView(ListArg()) or BiS:GetData())
        local ph = data and type(data.ph) == "table" and data.ph[phase]
        self.model:DressBiS("player", function(sid)
            local e = type(ph) == "table" and ph[sid]
            local itemID = type(e) == "table" and tonumber(e[1]) or nil
            if itemID and itemID > 0 and not SlotDisabled(phase, sid) then return itemID end
        end)
    end

    return c
end

-- §38: lock banner (the card's content moves below it) and the footer text.
local function UpdateLockBanner()
    if not card then return end
    local locked, info = ListLocked()
    card.lockBanner:SetShown(locked)
    card.title:ClearAllPoints()
    card.title:SetPoint("TOPLEFT", card, "TOPLEFT", 12, locked and -(12 + LOCK_BANNER_H + 2) or -12)
    if locked then
        card.lockBanner.title:SetText("BiS lists locked by " .. ns.UI:LockByText(info))
    end
    if footer then footer:SetText(locked and FOOTER_LOCKED or FOOTER_TEXT) end
end

local function UpdateCard(phase)
    if not card then return end
    UpdateLockBanner()
    local info = ComputeProgress(phase)
    local short = (ns.PHASE_INFO and ns.PHASE_INFO[phase] and ns.PHASE_INFO[phase].short) or ("P" .. phase)
    local label = ("%s  ·  %d / %d obtained"):format(short, info.obtained, info.total)
    card.title:SetText(IsOffSpecView() and ns.UI:Colorize("Off spec  ·  " .. label, ns.COLORS and ns.COLORS.offspec)
        or label)
    card:Dress(phase)
end

---------------------------------------------------------------------------
-- Top bar
---------------------------------------------------------------------------

local function PhaseButtonTooltip(button)
    local p = button.phase
    local pinfo = ns.PHASE_INFO and ns.PHASE_INFO[p]
    GameTooltip:SetOwner(button, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(pinfo and pinfo.name or ("Phase " .. p), 1, 0.82, 0)
    if pinfo and pinfo.raids then GameTooltip:AddLine(pinfo.raids, 1, 1, 1, true) end
    local main, alt = 0, 0
    for _, e in ipairs(PhaseItems(p)) do
        if e.which == "alt" then alt = alt + 1 else main = main + 1 end
    end
    GameTooltip:AddLine(("%d main  ·  %d alt picks"):format(main, alt), 0.7, 0.7, 0.7)
    if GuildPhase() == p then
        -- GetGuildPhase() is the group's phase while the group's loot rules set one (Addendum E §32).
        local GR = ns.GroupRules
        local groupSet = type(GR) == "table" and type(GR.GetRulePhase) == "function" and GR:GetRulePhase() ~= nil
        local text = "Guild's current phase"
        if groupSet then
            local status, from = "own", nil
            if type(GR.GetStatus) == "function" then status, from = GR:GetStatus() end
            if status == "remote" and type(from) == "string" then
                text = "Your group's current phase (set by " .. ns.Util.ShortName(from) .. ")"
            elseif status == "mine" then
                text = "Your group's current phase (set by you)"
            else
                text = "Your group's current phase"
            end
        end
        GameTooltip:AddLine(text, ns.UI:Color("main"))
    end
    GameTooltip:Show()
end

local function UpdatePhaseButtons()
    local phase = CurrentPhase()
    local guildPhase = GuildPhase()
    for p, b in ipairs(phaseButtons) do
        if b.SetKind then b:SetKind(p == phase and "chosen" or "secondary") end   -- the shown phase lit
        b.marker:SetShown(guildPhase == p)
    end
end

local function CreateTopBar(p)
    local UI = ns.UI
    for i = 1, MaxPhase() do
        local b = UI:CreateButton(p, "P" .. i, 38, 22, function() MyBiS:SetPhase(i, true) end)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", 8 + (i - 1) * 41, -8)
        b.phase = i
        b.marker = b:CreateTexture(nil, "OVERLAY")
        b.marker:SetTexture(UI:Tex("star"))
        b.marker:SetSize(11, 11)
        b.marker:SetPoint("CENTER", b, "TOPRIGHT", -3, -2)
        b.marker:Hide()
        b:HookScript("OnEnter", PhaseButtonTooltip)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
        phaseButtons[i] = b
    end

    -- Addendum H: which list the tab shows. The spec dropdown next to them belongs to that list.
    msBtn = UI:CreateButton(p, "Main spec", 76, 22, function() MyBiS:SetList("ms") end)
    msBtn:SetPoint("LEFT", phaseButtons[#phaseButtons], "RIGHT", 10, 0)
    osBtn = UI:CreateButton(p, "Off spec", 72, 22, function() MyBiS:SetList("os") end)
    osBtn:SetPoint("LEFT", msBtn, "RIGHT", 2, 0)
    for _, b in ipairs({ msBtn, osBtn }) do
        b:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            if self == msBtn then
                GameTooltip:AddLine("Main-spec list", 1, 0.82, 0)
                GameTooltip:AddLine("Your best-in-slot list. The council ranks these picks first.", 1, 1, 1, true)
            else
                GameTooltip:AddLine("Off-spec list", ns.UI:Color("offspec"))
                GameTooltip:AddLine("A second list for your other spec. The council sees these picks after "
                    .. "everyone's main-spec wants, and such an award counts as Offspec (not as loot won).", 1, 1, 1, true)
                if not HasOffSpec() then GameTooltip:AddLine("Click to start one.", 0.7, 0.7, 0.7) end
            end
            GameTooltip:Show()
        end)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end

    specDD = UI:CreateDropdown(p, 128, SpecOptions, SelectedSpec, OnSpecSelected)
    if specDD.SetDefaultText then specDD:SetDefaultText("Choose spec") end
    specDD:SetPoint("LEFT", osBtn, "RIGHT", 6, 0)

    copyBtn = UI:CreateMenuButton(p, "Copy from", 96, BuildCopyMenu)
    copyBtn:SetPoint("LEFT", specDD, "RIGHT", 6, 0)

    suggestBtn = UI:CreateMenuButton(p, "Suggest", 80, BuildSuggestMenu)
    suggestBtn:SetPoint("LEFT", copyBtn, "RIGHT", 4, 0)

    -- Actions that can't be undone wait behind "More" (asked again in a popup).
    local function clearPhase()
        local phase = CurrentPhase()
        if #PhaseItems(phase) == 0 then
            ns:Print("P%d has no picks to clear.", phase)
            return
        end
        EnsurePopups()
        StaticPopup_Show("DISASTERZONE_CLEAR_PHASE", "P" .. phase .. (ListArg() and " (off spec)" or ""), nil,
            { phase = phase, list = ListArg() })
    end
    local function buildMore(root)
        local phase = CurrentPhase()
        root:CreateButton("Clear P" .. phase .. (ListArg() and " (off spec)" or "") .. "...", clearPhase)
    end
    clearBtn = UI:CreateTipIconButton(p, 22, UI.ICON.more, "More", "Clear this phase's picks.", function(self)
        UI:ContextMenu(self, buildMore)
    end)
    clearBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -8, -8)
    p.moreBtn = clearBtn
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function MyBiS:CreatePanel(parent)
    if panel then return panel end
    panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints(parent)

    CreateTopBar(panel)

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -38)
    body:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 20)

    doll = ns.PaperDoll:Create(body, {
        readOnly = false,
        onSlotClick = OnSlotClick,
        onSlotReceiveItem = OnSlotReceiveItem,
    })
    card = CreateCard(doll.center)

    footer = ns.UI:CreateLabel(panel, FOOTER_TEXT, "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 4)
    footer:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 4)
    footer:SetJustifyH("CENTER")

    panel:SetScript("OnShow", function(self)
        if self.dirty then MyBiS:Refresh() end
    end)
    panel:SetScript("OnHide", function()
        if ns.Picker and ns.Picker.IsOpen and ns.Picker:IsOpen() then ns.Picker:Close() end
    end)
    panel.OnPanelShown = function(self)
        if self.dirty then MyBiS:Refresh() end
    end

    panel.dirty = true
    return panel
end

function MyBiS:Refresh()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    panel.dirty = false
    local BiS = ns.BiS
    if not BiS then return end

    local phase = CurrentPhase()
    UpdatePhaseButtons()
    -- Addendum H: the list buttons (the shown one highlighted; "+ Off spec" until there is one).
    if msBtn and osBtn then
        local os = IsOffSpecView()
        msBtn:SetKind(os and "secondary" or "chosen")
        osBtn:SetKind(os and "chosen" or "secondary")
        osBtn:SetText(HasOffSpec() and "Off spec" or "+ Off spec")
    end
    if specDD and specDD.SetDefaultText then
        specDD:SetDefaultText(IsOffSpecView() and "Off-spec spec" or "Choose spec")
    end
    if specDD and specDD.Refresh then specDD:Refresh() end
    local loon = ns.Loon and ns.Loon.IsAvailable and ns.Loon:IsAvailable()
    suggestBtn:SetShown(loon and true or false)

    -- §38: while the lists are locked every editing control is disabled (viewing phases still works).
    local locked = ListLocked()
    for _, ctrl in ipairs({ specDD, copyBtn, suggestBtn, clearBtn }) do
        if ctrl and ctrl.SetEnabled then ctrl:SetEnabled(not locked) end
    end
    if locked and ns.Picker and ns.Picker.IsOpen and ns.Picker:IsOpen() then ns.Picker:Close() end

    local record = ns.ListRecordView(BiS:GetRecord(), ListArg())
    if doll.SetLocked then doll:SetLocked(locked) end
    doll:Update(record, phase, {
        obtainedState = function(itemID) return BiS:GetObtainedState(itemID) end,
        showEquipped = true,
        isDisabled = function(sid) return SlotDisabled(phase, sid) end,
    })
    UpdateCard(phase)
end

-- DisasterZone extension (§36): the progress numbers of a phase as the card shows them (for tests / tooltips).
function MyBiS:GetProgress(phase)
    local info = ComputeProgress(ClampPhase(phase or CurrentPhase()))
    return { filled = info.filled, obtained = info.obtained, total = info.total, disabled = info.disabled }
end

local function RequestRefresh()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    Debounce("mybis-refresh", 0.05, function() MyBiS:Refresh() end)
end

---------------------------------------------------------------------------
-- Registration & messages
---------------------------------------------------------------------------

if ns.MainFrame and ns.MainFrame.RegisterTab then
    ns.MainFrame:RegisterTab("mybis", "My BiS", 1, function(parent) return MyBiS:CreatePanel(parent) end)
end

ns:On("MYLIST_CHANGED", RequestRefresh)
ns:On("OWNED_UPDATED", RequestRefresh)
ns:On("ITEMINFO_READY", RequestRefresh)
ns:On("LISTS_RESET", RequestRefresh)
ns:On("CONFIG_UPDATED", function()
    -- follow the guild phase until the player picks one themselves
    if not userPickedPhase then
        local gp = GuildPhase()
        if gp then selectedPhase = gp end
    end
    RequestRefresh()
end)
-- §38: the raid lock started / ended (GS lk from the group's loot authority).
ns:On("BIS_LOCK_CHANGED", RequestRefresh)
ns:On("GROUP_RULES_CHANGED", RequestRefresh)
ns:On("GROUP_UPDATED", RequestRefresh)
