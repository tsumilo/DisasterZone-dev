-- CDLoot UI/MyBiS.lua
-- ns.MyBiS: the "My BiS" tab - phase buttons, spec, copy / suggest / clear tools, the editable
-- paper doll and the progress card (what's obtained, which raids still have loot for you).
local addonName, ns = ...

local MyBiS = {}
ns.MyBiS = MyBiS

local NUM_SLOTS = 17
local AUTO_SPEC = "__auto"
local MAX_NEED_LINES = 6

local panel, doll, card
local phaseButtons = {}
local specDD, copyBtn, suggestBtn, clearBtn
local selectedPhase, userPickedPhase

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
    return ns.BiS:GetPhaseItems(p) or {}
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

---------------------------------------------------------------------------
-- Popups (defined lazily; only CDLOOT_* names)
---------------------------------------------------------------------------

local popupsReady = false
local function EnsurePopups()
    if popupsReady then return end
    popupsReady = true
    StaticPopupDialogs["CDLOOT_CLEAR_PHASE"] = {
        text = "Clear every main and alt pick in %s?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data)
            if data and data.phase and ns.BiS then ns.BiS:ClearPhase(data.phase) end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopupDialogs["CDLOOT_REPLACE_TEMPLATE"] = {
        text = "Replace every pick in %s with the LoonBestInSlot suggestions for %s?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data)
            if data then MyBiS:ApplySuggestion(data.phase, true) end
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
    ns.Picker:Open(CurrentPhase(), sid, which, tile)
    if doll then doll:SetHighlight(sid) end
end

function MyBiS:OnPickerClosed()
    if doll then doll:SetHighlight(nil) end
end

function MyBiS:ApplySuggestion(phase, overwrite)
    local BiS, Loon = ns.BiS, ns.Loon
    if not (BiS and Loon and Loon.IsAvailable and Loon:IsAvailable()) then
        ns:Print("LoonBestInSlot is not loaded.")
        return
    end
    local spec = BiS:GetSpec() or ""
    if spec == "" then
        ns:Print("Choose your spec first (Spec dropdown).")
        return
    end
    phase = ClampPhase(phase or CurrentPhase())
    local template = Loon:GetTemplate(MyClass(), spec, phase)
    if type(template) ~= "table" or next(template) == nil then
        ns:Print("LoonBestInSlot has no %s suggestions for P%d.", spec, phase)
        return
    end
    BiS:ApplyTemplate(phase, template, overwrite and true or false)
    if overwrite then
        ns:Print("Replaced P%d with LoonBestInSlot's %s suggestions.", phase, spec)
    else
        ns:Print("Filled empty P%d slots from LoonBestInSlot (%s).", phase, spec)
    end
end

local function ShowSlotMenu(sid, tile)
    local BiS = ns.BiS
    if not BiS then return end
    local phase = CurrentPhase()
    local main, alt = BiS:GetSlot(phase, sid)
    ns.UI:ContextMenu(tile, function(root)
        root:CreateTitle(SlotLabel(sid) .. "  ·  P" .. phase)
        root:CreateButton("Choose main...", function() OpenPicker(sid, "main", tile) end)
        root:CreateButton("Choose alt...", function() OpenPicker(sid, "alt", tile) end)
        if main or alt then
            root:CreateButton("Swap main / alt", function() BiS:SwapMainAlt(phase, sid) end)
        end
        if main then
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
            root:CreateButton("Clear slot", function() BiS:ClearSlot(phase, sid) end)
        end
        if main then
            root:CreateButton("Link main in chat", function() ns.UI:LinkInChat(main) end)
        end
    end)
end

local function OnSlotClick(sid, which, mouseButton, tile)
    if mouseButton == "RightButton" then
        ShowSlotMenu(sid, tile)
    else
        OpenPicker(sid, which, tile)
    end
end

local function OnSlotReceiveItem(sid, itemID, which)
    if ns.BiS then
        ns.BiS:SetSlot(CurrentPhase(), sid, which == "alt" and "alt" or "main", itemID)
    end
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

---------------------------------------------------------------------------
-- Menus & dropdown content
---------------------------------------------------------------------------

local function SpecOptions()
    local opts = {}
    local specs = ns.SPECS and ns.SPECS[MyClass()] or {}
    for _, s in ipairs(specs) do
        if s.label then opts[#opts + 1] = { value = s.label, text = s.label } end
    end
    opts[#opts + 1] = { value = AUTO_SPEC, text = "Auto-detect", tooltip = "Use the talent tree with the most points." }
    return opts
end

local function SelectedSpec()
    return ns.BiS and ns.BiS.GetSpec and ns.BiS:GetSpec() or nil
end

local function OnSpecSelected(value)
    local BiS = ns.BiS
    if not BiS then return end
    if value == AUTO_SPEC then
        local spec = BiS:DetectSpec()
        if spec and spec ~= "" then
            BiS:SetSpec(spec)
            ns:Print("Spec detected: %s", spec)
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
    root:CreateTitle("Copy into P" .. phase)
    local any = false
    for p = 1, MaxPhase() do
        if p ~= phase and #PhaseItems(p) > 0 then
            any = true
            root:CreateButton(("Copy P%d (fill empty)"):format(p), function()
                if BiS then BiS:CopyPhase(p, phase, false) end
            end)
            root:CreateButton(("Copy P%d (overwrite)"):format(p), function()
                if BiS then BiS:CopyPhase(p, phase, true) end
            end)
        end
    end
    if not any then
        root:CreateTitle("No other phase has items yet")
    end
end

local function BuildSuggestMenu(root)
    local phase = CurrentPhase()
    local spec = SelectedSpec() or ""
    root:CreateTitle("LoonBestInSlot")
    if not (ns.Loon and ns.Loon.IsAvailable and ns.Loon:IsAvailable()) then
        root:CreateTitle("LoonBestInSlot is not loaded")
        return
    end
    if spec == "" then
        root:CreateTitle("Choose your spec first")
        return
    end
    root:CreateButton(("Fill empty slots from LoonBestInSlot (%s P%d)"):format(spec, phase), function()
        MyBiS:ApplySuggestion(phase, false)
    end)
    root:CreateButton("Replace all (confirm)", function()
        EnsurePopups()
        StaticPopup_Show("CDLOOT_REPLACE_TEMPLATE", "P" .. phase, spec, { phase = phase })
    end)
end

---------------------------------------------------------------------------
-- Progress card
---------------------------------------------------------------------------

local function ComputeProgress(phase)
    local BiS, ItemDB = ns.BiS, ns.ItemDB
    local result = { filled = 0, obtained = 0, total = NUM_SLOTS, raids = {}, other = 0, otherItems = {} }
    local data = BiS and BiS:GetData()
    local ph = data and type(data.ph) == "table" and data.ph[phase]
    if type(ph) ~= "table" then return result end

    local byRaid = {}
    for sid = 1, NUM_SLOTS do
        local e = ph[sid]
        local main = type(e) == "table" and tonumber(e[1]) or nil
        if main and main > 0 then
            result.filled = result.filled + 1
            if BiS:IsObtained(main) then
                result.obtained = result.obtained + 1
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

    -- a two-hander leaves the off hand intentionally empty
    local mh = type(ph[15]) == "table" and tonumber(ph[15][1]) or nil
    local oh = type(ph[16]) == "table" and tonumber(ph[16][1]) or nil
    if mh and mh > 0 and not (oh and oh > 0) and ItemDB and ItemDB:GetEquipLoc(mh) == "INVTYPE_2HWEAPON" then
        result.total = NUM_SLOTS - 1
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

local function NeedLineTooltip(line)
    local info = line.info
    if not info then return end
    GameTooltip:SetOwner(line, "ANCHOR_RIGHT")
    GameTooltip:AddLine(info.title, 1, 0.82, 0)
    for _, it in ipairs(info.items) do
        local text = ns.UI:ItemText(it.itemID)
        GameTooltip:AddDoubleLine(text, (it.boss and (it.boss .. "  ·  ") or "") .. SlotLabel(it.sid), 1, 1, 1, 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

local function CreateCard(parent)
    local UI = ns.UI
    local c = UI:CreatePanel(parent)
    c:SetAllPoints(parent)

    c.title = UI:CreateLabel(c, "Phase progress", "GameFontNormal")
    c.title:SetPoint("TOPLEFT", c, "TOPLEFT", 12, -12)

    c.progress = UI:CreateLabel(c, "", "GameFontHighlight")
    c.progress:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -6)

    c.bar = CreateFrame("StatusBar", nil, c)
    c.bar:SetPoint("TOPLEFT", c.progress, "BOTTOMLEFT", 0, -6)
    c.bar:SetPoint("RIGHT", c, "RIGHT", -12, 0)
    c.bar:SetHeight(8)
    c.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    c.bar:SetStatusBarColor(ns.UI:Color("obtained"))
    c.bar:SetMinMaxValues(0, NUM_SLOTS)
    c.bar:SetValue(0)
    c.bar.bg = c.bar:CreateTexture(nil, "BACKGROUND")
    c.bar.bg:SetAllPoints()
    c.bar.bg:SetColorTexture(0.15, 0.15, 0.15, 0.9)

    c.filled = UI:CreateLabel(c, "", "GameFontDisableSmall")
    c.filled:SetPoint("TOPLEFT", c.bar, "BOTTOMLEFT", 0, -5)
    c.filled:SetPoint("RIGHT", c, "RIGHT", -12, 0)

    c.needTitle = UI:CreateLabel(c, "Still needed from", "GameFontNormal")
    c.needTitle:SetPoint("TOPLEFT", c.filled, "BOTTOMLEFT", 0, -14)

    c.lines = {}
    local prev = c.needTitle
    for i = 1, MAX_NEED_LINES + 1 do
        local line = CreateFrame("Button", nil, c)
        line:SetHeight(15)
        line:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, i == 1 and -4 or -1)
        line:SetPoint("RIGHT", c, "RIGHT", -12, 0)
        line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line.text:SetAllPoints()
        line.text:SetJustifyH("LEFT")
        line.text:SetWordWrap(false)
        line:SetScript("OnEnter", NeedLineTooltip)
        line:SetScript("OnLeave", function() GameTooltip:Hide() end)
        line:Hide()
        c.lines[i] = line
        prev = line
    end

    c.hint = UI:CreateLabel(c, "", "GameFontHighlightSmall")
    c.hint:SetPoint("TOPLEFT", c.needTitle, "BOTTOMLEFT", 0, -6)
    c.hint:SetPoint("RIGHT", c, "RIGHT", -12, 0)
    c.hint:SetJustifyV("TOP")
    c.hint:SetSpacing(2)

    c.sharingStatus = UI:CreateLabel(c, "", "GameFontHighlightSmall")
    c.sharingStatus:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 12, 12)
    c.sharingStatus:SetPoint("RIGHT", c, "RIGHT", -12, 0)
    c.sharingStatus:SetJustifyV("BOTTOM")

    c.sharingTitle = UI:CreateLabel(c, "Sharing", "GameFontNormal")
    c.sharingTitle:SetPoint("BOTTOMLEFT", c.sharingStatus, "TOPLEFT", 0, 4)

    return c
end

local function UpdateSharing()
    if not card then return end
    local text = ns.Sync and ns.Sync.GetStatusText and ns.Sync:GetStatusText() or ""
    if text == "" then text = "Not available" end
    card.sharingStatus:SetText(ns.UI:SafeText(text))
end

local EMPTY_HINT = "Click a slot to choose your best-in-slot item. Drag items from your bags onto a slot to use crafted / badge / dungeon items."

local function UpdateCard(phase)
    if not card then return end
    local info = ComputeProgress(phase)
    local short = (ns.PHASE_INFO and ns.PHASE_INFO[phase] and ns.PHASE_INFO[phase].short) or ("P" .. phase)
    card.progress:SetText(("%s  ·  %d / %d obtained"):format(short, info.obtained, info.total))
    card.bar:SetMinMaxValues(0, math.max(1, info.total))
    card.bar:SetValue(math.min(info.obtained, info.total))
    local spec = SelectedSpec() or ""
    card.filled:SetText(("%d of %d slots chosen%s"):format(info.filled, info.total, spec ~= "" and ("  ·  " .. spec) or ""))

    for _, line in ipairs(card.lines) do
        line:Hide()
        line.info = nil
    end

    if info.filled == 0 then
        card.needTitle:SetText("Get started")
        card.hint:SetText(EMPTY_HINT)
        card.hint:Show()
    elseif #info.raids == 0 and info.other == 0 then
        card.needTitle:SetText("Still needed from")
        card.hint:SetText(ns.UI:Colorize("Nothing left - every chosen item is obtained!", ns.COLORS and ns.COLORS.obtained))
        card.hint:Show()
    else
        card.needTitle:SetText("Still needed from")
        card.hint:Hide()
        local n = 0
        local maxRaidLines = info.other > 0 and MAX_NEED_LINES - 1 or MAX_NEED_LINES
        local hiddenRaids, hiddenCount = 0, 0
        for _, entry in ipairs(info.raids) do
            if n < maxRaidLines then
                n = n + 1
                local parts = {}
                for i, bname in ipairs(entry.bossOrder) do
                    if i > 3 then
                        parts[#parts + 1] = "..."
                        break
                    end
                    parts[#parts + 1] = (entry.dungeon and bname or ShortBossName(bname)) .. " " .. entry.bosses[bname]
                end
                local line = card.lines[n]
                line.text:SetText(("%s - %d |cff999999(%s)|r"):format(entry.raid.name or "?", entry.count, table.concat(parts, ", ")))
                line.info = { title = (entry.raid.name or "?") .. " - " .. entry.count, items = entry.items }
                line:Show()
            else
                hiddenRaids = hiddenRaids + 1
                hiddenCount = hiddenCount + entry.count
            end
        end
        if hiddenRaids > 0 and n < #card.lines then
            n = n + 1
            card.lines[n].text:SetText(("|cff999999+%d more raids - %d items|r"):format(hiddenRaids, hiddenCount))
            card.lines[n]:Show()
        end
        if info.other > 0 and n < #card.lines then
            n = n + 1
            local line = card.lines[n]
            line.text:SetText(("Other sources - %d"):format(info.other))
            line.info = { title = "Other sources (crafted, badges, quests...)", items = info.otherItems }
            line:Show()
        end
    end
    UpdateSharing()
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
        GameTooltip:AddLine("Guild's current phase", ns.UI:Color("main"))
    end
    GameTooltip:Show()
end

local function UpdatePhaseButtons()
    local phase = CurrentPhase()
    local guildPhase = GuildPhase()
    for p, b in ipairs(phaseButtons) do
        if p == phase then
            b:LockHighlight()
            b:SetNormalFontObject("GameFontHighlight")
        else
            b:UnlockHighlight()
            b:SetNormalFontObject("GameFontNormal")
        end
        b.marker:SetShown(guildPhase == p)
    end
end

local function CreateTopBar(p)
    local UI = ns.UI
    for i = 1, MaxPhase() do
        local b = UI:CreateButton(p, "P" .. i, 44, 22, function() MyBiS:SetPhase(i, true) end)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", 8 + (i - 1) * 48, -8)
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

    local specLabel = UI:CreateLabel(p, "Spec", "GameFontNormalSmall")
    specLabel:SetPoint("LEFT", phaseButtons[#phaseButtons], "RIGHT", 14, 0)
    specDD = UI:CreateDropdown(p, 150, SpecOptions, SelectedSpec, OnSpecSelected)
    if specDD.SetDefaultText then specDD:SetDefaultText("Choose spec") end
    specDD:SetPoint("LEFT", specLabel, "RIGHT", 6, 0)

    copyBtn = UI:CreateMenuButton(p, "Copy from", 108, BuildCopyMenu)
    copyBtn:SetPoint("LEFT", specDD, "RIGHT", 8, 0)

    suggestBtn = UI:CreateMenuButton(p, "Suggest", 96, BuildSuggestMenu)
    suggestBtn:SetPoint("LEFT", copyBtn, "RIGHT", 6, 0)

    clearBtn = UI:CreateButton(p, "Clear phase", 96, 22, function()
        local phase = CurrentPhase()
        if #PhaseItems(phase) == 0 then
            ns:Print("P%d has no picks to clear.", phase)
            return
        end
        EnsurePopups()
        StaticPopup_Show("CDLOOT_CLEAR_PHASE", "P" .. phase, nil, { phase = phase })
    end)
    clearBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -8, -8)
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

    local footer = ns.UI:CreateLabel(panel, "Click a slot to choose  ·  Right-click for options  ·  Drag items from your bags onto a slot  ·  Shift-click to link", "GameFontDisableSmall")
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
    if specDD and specDD.Refresh then specDD:Refresh() end
    local loon = ns.Loon and ns.Loon.IsAvailable and ns.Loon:IsAvailable()
    suggestBtn:SetShown(loon and true or false)

    local record = BiS:GetRecord()
    doll:Update(record, phase, {
        obtainedState = function(itemID) return BiS:GetObtainedState(itemID) end,
        showEquipped = true,
    })
    UpdateCard(phase)
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
ns:On("SYNC_STATUS", UpdateSharing)
ns:On("MYLIST_COMMITTED", UpdateSharing)
