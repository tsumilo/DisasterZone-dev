if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Picker.lua", ...) then return end -- DisasterZone UI/Picker.lua
-- ns.Picker: item picker flyout docked next to the main window. Lists the items that fit one slot from the
-- ticked sources (ADDENDUM F §35: raids, 5-man dungeons, crafted, reputation, badge vendors, PvP), grouped
-- into sections (raid -> boss, "Crafted — Blacksmithing" -> specialisation, ...), with a phase filter,
-- search and class / armor filters; accepts shift-clicked or dragged items. It won't open while the
-- group's raid leader has locked the BiS lists (§38).
local addonName, ns = ...

local Picker = {}
ns.Picker = Picker

local WIDTH, HEIGHT = 360, 560
local ROW_ITEM, ROW_RAID, ROW_BOSS = 34, 20, 18
local ARMOR_SLOTS = { [1] = true, [3] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true, [10] = true }
local CLASS_WEAPON, CLASS_ARMOR = 2, 4   -- Enum.ItemClass
local LOCK_MESSAGE_GAP = 3               -- seconds between two "lists are locked" prints

local EMPTY_TEXT = "No items match. Try 'All phases', tick more sources or untick the filters - or shift-click any item."
local EMPTY_NO_SOURCES = "No sources ticked. Choose at least one under Sources."
local HINT_TEXT = "Shift-click an item link or drag an item from your bags here to use any other item."
local DUNGEON_SUFFIX = " (5-man)"
local HEROIC_TAG = "|cffff7f3fHeroic|r"
local DASH = " \226\128\148 "            -- " — " (U+2014 is in the game fonts)

-- Sources (§35): filter.sources keys, in menu / section order.
local SOURCE_KEYS = { "raids", "dungeons", "crafted", "rep", "badges", "pvp" }
local SOURCE_INFO = {
    raids    = { text = "Raids", short = "Raids" },
    dungeons = { text = "5-man dungeons", short = "5-man" },
    crafted  = { text = "Crafted", short = "Crafted",
                 tooltip = "Blacksmithing, Leatherworking, Tailoring, Jewelcrafting, Engineering and Alchemy." },
    rep      = { text = "Reputation", short = "Rep", tooltip = "Faction rewards; each item shows the standing it needs." },
    badges   = { text = "Badge vendors", short = "Badges", tooltip = "Badge of Justice rewards (G'eras and the Sunwell vendors)." },
    pvp      = { text = "PvP", short = "PvP",
                 tooltip = "Arena seasons, honor and world PvP gear. Faction items are only listed for your faction." },
}
local DEFAULT_SOURCES = { raids = true, dungeons = true, crafted = false, rep = false, badges = false, pvp = false }
-- Candidate row kind -> source key / section header prefix.
local KIND_SOURCE = { raid = "raids", dungeon = "dungeons", craft = "crafted", rep = "rep", badge = "badges", pvp = "pvp" }
local KIND_HEADER = { craft = "Crafted", rep = "Reputation", badge = "Badge of Justice", pvp = "PvP" }

-- Phase filter (applies to every source that has a phase; items without one count as phase 1).
local PHASE_MODES = { "upto", "only", "all" }
local PHASE_TEXT = {
    upto = function(p) return ("Up to P%d"):format(p) end,
    only = function(p) return ("Only P%d"):format(p) end,
    all  = function() return "All phases" end,
}

local win, list, searchBox, phaseDD, sourcesDD, cbUsable, cbArmor, current, hint
local state = {
    phase = 1, sid = 1, which = "main",
    search = "", phaseMode = "upto", usable = true, armorOnly = true,
    sources = nil,       -- { raids=, dungeons=, crafted=, rep=, badges=, pvp= } (loaded on first open)
}
local listMarks = {}     -- itemID -> { which=, sid= } for the phase being edited
local currentPick        -- itemID currently in the slot being edited
local lastLockMessage = -100

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function MyClass()
    local data = ns.BiS and ns.BiS.GetData and ns.BiS:GetData()
    if data and type(data.cl) == "string" and data.cl ~= "" then return data.cl end
    local _, classFile = UnitClass("player")
    return classFile
end

local function SlotInfo(sid)
    return ns.SLOTS and ns.SLOTS[sid] or nil
end

local function SlotLabel(sid)
    local s = SlotInfo(sid)
    return s and s.label or ("Slot " .. tostring(sid))
end

local function SlotShort(sid)
    local s = SlotInfo(sid)
    return s and s.short or tostring(sid)
end

local function Debounce(key, sec, fn)
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce(key, sec, fn)
    else
        C_Timer.After(sec, fn)
    end
end

local function Lower(s)
    return type(s) == "string" and s:lower() or ""
end

local function TypeLine(itemID)
    if not (C_Item and C_Item.GetItemInfoInstant) then return "" end
    local _, _, subType, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
    local slotText = (equipLoc and equipLoc ~= "" and _G[equipLoc]) or nil
    local kind
    if classID == CLASS_WEAPON then
        kind = subType
    elseif classID == CLASS_ARMOR and equipLoc ~= "INVTYPE_CLOAK" and subclassID and subclassID >= 1 then
        kind = subType   -- Cloth/Leather/Mail/Plate, Shield, Libram, Idol, Totem
    end
    if kind and kind ~= "" and slotText and type(slotText) == "string" then
        return kind .. "  ·  " .. slotText
    end
    return type(slotText) == "string" and slotText or (kind or "")
end

local function IsDungeonRef(ref)
    return type(ref) == "table" and ref.dungeon == true
end

-- "raid" | "dungeon" | "craft" | "rep" | "badge" | "pvp" (an older ItemDB has no row.kind: raid / dungeon).
local function RowKind(c)
    if type(c.kind) == "string" and KIND_SOURCE[c.kind] then return c.kind end
    if type(c.ref) == "table" then return IsDungeonRef(c.ref) and "dungeon" or "raid" end
    return nil
end

-- The locked-lists print, at most once per 3 s (the BiS editing APIs print their own).
local function LockedMessage(info)
    local now = GetTime()
    if now - lastLockMessage < LOCK_MESSAGE_GAP then return end
    lastLockMessage = now
    local by = ns.UI and ns.UI.LockByText and ns.UI:LockByText(info) or "the raid leader"
    if by == "you" then
        ns:Print("BiS lists are locked by you during the raid (/dz unlock to edit).")
    else
        ns:Print("BiS lists are locked by %s during the raid.", by)
    end
end

local function ListLocked()
    if not (ns.UI and ns.UI.IsMyListLocked) then return false, nil end
    return ns.UI:IsMyListLocked()
end

---------------------------------------------------------------------------
-- Sources (session + settings.pickerSources)
---------------------------------------------------------------------------

local function LoadSources()
    local saved = ns.DB and ns.DB.GetSetting and ns.DB:GetSetting("pickerSources")
    local out = {}
    for _, key in ipairs(SOURCE_KEYS) do
        local v = type(saved) == "table" and saved[key]
        if type(v) == "boolean" then out[key] = v else out[key] = DEFAULT_SOURCES[key] end
    end
    return out
end

local function Sources()
    if not state.sources then state.sources = LoadSources() end
    return state.sources
end

local function AnySource()
    for _, key in ipairs(SOURCE_KEYS) do
        if Sources()[key] then return true end
    end
    return false
end

local function SetSource(key, on)
    if not SOURCE_INFO[key] then return end
    on = on and true or false
    Sources()[key] = on
    if ns.db and ns.DB and ns.DB.SetSetting then ns.DB:SetSetting("pickerSources." .. key, on) end
end

local function IsDefaultSources()
    for _, key in ipairs(SOURCE_KEYS) do
        if (Sources()[key] and true or false) ~= DEFAULT_SOURCES[key] then return false end
    end
    return true
end

-- Button text: "Raids + 5-man", "Crafted", "Raids + 3 more", "All sources", "No sources".
local function SourcesSummary()
    local on = {}
    for _, key in ipairs(SOURCE_KEYS) do
        if Sources()[key] then on[#on + 1] = SOURCE_INFO[key].short end
    end
    if #on == 0 then return "No sources" end
    if #on == #SOURCE_KEYS then return "All sources" end
    if #on <= 2 then return table.concat(on, " + ") end
    return ("%s + %d more"):format(on[1], #on - 1)
end

local function SourceOptions()
    local opts = { { isTitle = true, text = "Show items from" } }
    for _, key in ipairs(SOURCE_KEYS) do
        local info = SOURCE_INFO[key]
        opts[#opts + 1] = { value = key, text = info.text, tooltip = info.tooltip }
    end
    if not IsDefaultSources() then
        opts[#opts + 1] = { isDivider = true }
        opts[#opts + 1] = { isButton = true, text = "Reset to raids + 5-man dungeons", onClick = function()
            for _, key in ipairs(SOURCE_KEYS) do SetSource(key, DEFAULT_SOURCES[key]) end
            if sourcesDD and sourcesDD.Refresh then sourcesDD:Refresh() end
            Picker:Rebuild(true)
        end }
    end
    return opts
end

---------------------------------------------------------------------------
-- Candidates
---------------------------------------------------------------------------

local function BuildFilter()
    local f = { includeTrash = true }
    if state.phaseMode == "upto" then
        f.maxPhase = state.phase
    elseif state.phaseMode == "only" then
        f.phase = state.phase
    end
    local src = {}
    for _, key in ipairs(SOURCE_KEYS) do src[key] = Sources()[key] and true or false end
    f.sources = src
    -- an ItemDB that predates filter.sources still understands the raid / dungeon scope
    if src.raids and src.dungeons then
        f.scope = "all"
    elseif src.dungeons then
        f.scope = "dungeons"
    else
        f.scope = "raids"
    end
    local armorOnly = state.armorOnly and ARMOR_SLOTS[state.sid] or false
    if state.usable or armorOnly then f.class = MyClass() end
    f.usableOnly = state.usable and true or false
    f.primaryArmorOnly = armorOnly and true or false
    return f
end

local function Candidates()
    local ItemDB = ns.ItemDB
    if not (ItemDB and ItemDB.GetCandidates) or not AnySource() then return {} end
    local rows = ItemDB:GetCandidates(state.sid, BuildFilter())
    if type(rows) ~= "table" then return {} end
    -- Safety net: only rows of a ticked source (an older ItemDB ignores filter.sources).
    local sources, out = Sources(), {}
    for _, c in ipairs(rows) do
        if type(c) == "table" and tonumber(c.itemID) then
            local kind = RowKind(c)
            if not kind or sources[KIND_SOURCE[kind]] then out[#out + 1] = c end
        end
    end
    return out
end

local function RefreshMarks()
    wipe(listMarks)
    currentPick = nil
    local BiS = ns.BiS
    if not BiS then return end
    for _, e in ipairs(BiS:GetPhaseItems(state.phase, state.list) or {}) do
        local id = tonumber(e.itemID)
        if id then
            local prev = listMarks[id]
            if not prev or (prev.which == "alt" and e.which == "main") or (e.sid == state.sid and prev.sid ~= state.sid) then
                listMarks[id] = { which = e.which, sid = e.sid }
            end
        end
    end
    local main, alt = BiS:GetSlot(state.phase, state.sid, state.list)
    if state.which == "alt" then currentPick = alt else currentPick = main end
end

---------------------------------------------------------------------------
-- Source texts (row subtitles, search)
---------------------------------------------------------------------------

-- The ItemDB:GetSources entry of an item that belongs to this row's kind / group.
local function FindSource(itemID, kind, groupKey)
    local ItemDB = ns.ItemDB
    local srcs = ItemDB and ItemDB.GetSources and ItemDB:GetSources(itemID)
    if type(srcs) ~= "table" then return nil end
    local fallback
    for _, e in ipairs(srcs) do
        if type(e) == "table" and e.kind == kind then
            if groupKey == nil or e.groupKey == groupKey then return e end
            fallback = fallback or e
        end
    end
    return fallback
end

-- Local formatting of one crafted / rep / badge / PvP source (used when the item's primary source is
-- another kind, so ItemDB:GetSourceText describes that one).
local function FormatSource(e, d)
    local group = e.group or e.craft or e.rep or e.badge or e.pvp
    local gname = e.groupName or (type(group) == "table" and group.name) or d.groupName or "?"
    if d.kind == "craft" then
        local t = gname
        if tonumber(e.skill) then t = t .. " (" .. e.skill .. ")" end
        if type(e.spec) == "string" and e.spec ~= "" then t = t .. "  ·  " .. e.spec end
        if e.bop then t = t .. "  ·  BoP" end
        return t
    elseif d.kind == "rep" then
        return gname .. (type(e.standing) == "string" and (DASH .. e.standing) or "")
    elseif d.kind == "badge" then
        return gname .. (tonumber(e.cost) and (DASH .. e.cost .. " badges") or "")
    elseif d.kind == "pvp" then
        local t = gname
        if e.cost ~= nil then t = t .. DASH .. tostring(e.cost) end
        if type(e.faction) == "string" then t = t .. "  ·  " .. e.faction end
        return t
    end
    return gname
end

-- Row subtitle of a crafted / rep / badge / PvP row (§35/§37): the row's own source as ItemDB formats it
-- ("Blacksmithing (375) · Armorsmith", "The Sha'tar — Exalted", "G'eras — 60 badges", ...); else
-- ItemDB:GetSourceText when the item's primary source is this kind; else formatted here.
local function RowSourceText(d)
    if d.srcText ~= nil then return d.srcText or nil end
    local ItemDB = ns.ItemDB
    local text
    if ItemDB and type(ItemDB.FormatSource) == "function" and type(d.src) == "table" then
        text = ItemDB:FormatSource(d.src, false)
    end
    local primary = not text and ItemDB and ItemDB.GetSourceKind and ItemDB:GetSourceKind(d.itemID)
    if not text and (primary == nil or primary == d.kind) then
        text = ItemDB and ItemDB.GetSourceText and ItemDB:GetSourceText(d.itemID, true)
    end
    if not text then
        local e = FindSource(d.itemID, d.kind, d.groupKey)
        if e then text = FormatSource(e, d) end
    end
    text = text or d.groupName
    d.srcText = text or false
    return text
end

-- Section header text of a candidate row, and its sub-header (nil = none).
local function SectionOf(c, kind)
    if kind == "raid" or kind == "dungeon" or (kind == nil and type(c.ref) == "table") then
        local ref = c.ref
        local raid = type(ref) == "table" and ref.raid or nil
        local name = type(raid) == "table" and raid.name or "Other"
        if raid and kind == "dungeon" then name = name .. DUNGEON_SUFFIX end
        local boss = type(ref) == "table" and ref.boss or nil
        return raid or "?", name, ref or "?", (type(boss) == "table" and boss.name) or "Unknown source"
    end
    local group = c.groupName or c.groupKey or "?"
    local key = tostring(kind) .. ":" .. tostring(c.groupKey or c.groupName or "")
    local prefix = KIND_HEADER[kind]
    local name = prefix and (prefix .. DASH .. tostring(group)) or tostring(group)
    local sub = type(c.subgroup) == "string" and c.subgroup ~= "" and c.subgroup or nil
    return key, name, sub and (key .. ":" .. sub) or nil, sub
end

-- Search (§35): item name / token / boss / raid / item ID (ItemDB:Search) plus profession, faction,
-- vendor and season names, specialisations and the row's source text ("exalted", "honor", ...).
local function GroupMatches(c, needle)
    local kind = RowKind(c)
    if kind == "raid" or kind == "dungeon" then return false end
    local _, header = SectionOf(c, kind)
    if Lower(header):find(needle, 1, true) then return true end
    if Lower(c.subgroup):find(needle, 1, true) or Lower(c.groupKey):find(needle, 1, true) then return true end
    local info = SOURCE_INFO[KIND_SOURCE[kind] or ""]
    if info and Lower(info.text):find(needle, 1, true) then return true end
    local text = RowSourceText({ itemID = c.itemID, kind = kind, groupKey = c.groupKey, groupName = c.groupName,
                                 src = c })
    return Lower(text):find(needle, 1, true) ~= nil
end

local function Search(cands, text)
    local needle = Lower(text):gsub("^%s+", ""):gsub("%s+$", "")
    if needle == "" then return cands end
    local hitIDs = {}
    local ItemDB = ns.ItemDB
    if ItemDB and ItemDB.Search then
        for _, c in ipairs(ItemDB:Search(text, cands) or {}) do
            if type(c) == "table" and c.itemID then hitIDs[c.itemID] = true end
        end
    end
    local out = {}
    for _, c in ipairs(cands) do
        if hitIDs[c.itemID] or GroupMatches(c, needle) then out[#out + 1] = c end
    end
    return out
end

---------------------------------------------------------------------------
-- Picking
---------------------------------------------------------------------------

local function Pick(itemID)
    itemID = tonumber(itemID)
    if not itemID or not ns.BiS then return end
    if ns.BiS:SetSlot(state.phase, state.sid, state.which, itemID, state.list) then
        Picker:Close()
    end
end

local function OnDropItem(_, itemID)
    Pick(itemID)
end

-- Shift-clicked links (bags, chat, other addons) while the picker is open.
local function OnInsertLink(text)
    if not Picker:IsOpen() then return end
    if ns.UI and ns.UI:IsOwnLinkClick() then return end
    if type(text) ~= "string" then return end
    local id = tonumber(text:match("item:(%d+)"))
    if id and id > 0 then Pick(id) end
end

local hooked = false
local function HookInsertLink()
    if hooked then return end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)
        hooked = true
    elseif ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", OnInsertLink)
        hooked = true
    end
end

---------------------------------------------------------------------------
-- List rows
---------------------------------------------------------------------------

local function RowTooltip(row)
    local d = row.__cdlData
    if not d or d.type ~= "item" then return end
    ns.UI:SetItemTooltip(row, d.itemID, function(tt)
        tt:AddLine(" ")
        local ItemDB = ns.ItemDB
        local src
        if d.kind and KIND_HEADER[d.kind] then
            src = RowSourceText(d)
            local e = type(d.src) == "table" and d.src.reagentsNote and d.src or FindSource(d.itemID, d.kind, d.groupKey)
            if e and type(e.reagentsNote) == "string" and e.reagentsNote ~= "" then
                tt:AddLine(src or "", 0.7, 0.7, 0.7, true)
                src = "Needs " .. e.reagentsNote
            end
        else
            src = ItemDB and ItemDB:GetSourceText(d.itemID)
        end
        if src then tt:AddLine(src, 0.7, 0.7, 0.7, true) end
        local r, g, b = ns.UI:Color(state.which == "alt" and "alt" or "main")
        tt:AddLine(("Click: set as %s for %s (P%d)"):format(state.which == "alt" and "alt" or "main BiS", SlotLabel(state.sid), state.phase), r, g, b)
    end)
end

local function SetupRow(row)
    local UI = ns.UI
    row.cdl = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 0.82, 0, 0.08)

    row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.sel:SetAllPoints()
    row.sel:SetTexture(UI:Tex("rowHilight"))
    row.sel:SetBlendMode("ADD")
    row.sel:SetVertexColor(1, 0.82, 0, 0.6)

    row:SetHighlightTexture(UI:Tex("rowHilight"), "ADD")

    row.header = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.header:SetJustifyH("LEFT")
    row.header:SetWordWrap(false)

    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.count:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.count:SetJustifyH("RIGHT")

    row.icon = UI:CreateItemButton(row, 28)
    row.icon:SetPoint("LEFT", row, "LEFT", 16, 0)
    row.icon.onClick = function(btn) Pick(btn.itemID) end
    row.icon.onReceiveItem = OnDropItem

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
    row.name:SetPoint("RIGHT", row, "RIGHT", -74, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 2)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -74, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)

    row.mark1 = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.mark1:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -5)
    row.mark1:SetJustifyH("RIGHT")

    row.mark2 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.mark2:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 5)
    row.mark2:SetJustifyH("RIGHT")

    row:SetScript("OnClick", function(self)
        if self.__cdlDropTime and self.__cdlDropTime == GetTime() then return end
        local d = self.__cdlData
        if not d or d.type ~= "item" then return end
        if ns.UI:HandleModifiedItemClick(d.itemID) then return end
        Pick(d.itemID)
    end)
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI:AttachItemDrop(row, OnDropItem)
end

local function InitRow(row, d)
    if not row.cdl then SetupRow(row) end
    local UI = ns.UI
    local hl = row:GetHighlightTexture()
    row:SetAlpha(1)

    if d.type == "raid" or d.type == "boss" then
        row.icon:Hide()
        row.name:Hide()
        row.sub:Hide()
        row.mark1:Hide()
        row.mark2:Hide()
        row.sel:Hide()
        if hl then hl:SetAlpha(0) end
        row.header:Show()
        row.header:ClearAllPoints()
        if d.type == "raid" then
            row.bg:Show()
            row.header:SetFontObject("GameFontNormal")
            row.header:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.header:SetText(d.name or "?")
            row.count:SetText(d.count and (d.count .. (d.count == 1 and " item" or " items")) or "")
            row.count:Show()
        else
            row.bg:Hide()
            row.header:SetFontObject("GameFontHighlightSmall")
            row.header:SetPoint("LEFT", row, "LEFT", 14, 0)
            row.header:SetText(d.name or "?")
            row.count:Hide()
        end
        row.header:SetPoint("RIGHT", row, "RIGHT", -60, 0)
        return
    end

    -- item row
    row.bg:Hide()
    row.header:Hide()
    row.count:Hide()
    if hl then hl:SetAlpha(1) end
    local id = d.itemID
    row.icon:Show()
    row.icon:SetItem(id)
    row.name:Show()
    row.name:SetText((UI:ItemText(id)))
    row.sub:Show()
    local subText
    if d.kind and KIND_HEADER[d.kind] then
        subText = RowSourceText(d) or TypeLine(id)
    elseif d.via == "token" then
        local tokenName = d.viaItem and ns.ItemDB and ns.ItemDB:GetName(d.viaItem)
        subText = "via " .. (tokenName or "tier token")
    else
        subText = TypeLine(id)
    end
    if d.heroic then
        -- only on a heroic loot table (5-man dungeons)
        subText = (subText ~= "") and (HEROIC_TAG .. "  ·  " .. subText) or HEROIC_TAG
    end
    -- Class-restricted items ("Classes: Rogue"): name the classes, so identically named variants (the class
    -- Medallions, ...) can be told apart and a pick for another class stands out.
    local classes = ns.ItemDB and ns.ItemDB.GetItemClasses and ns.ItemDB:GetItemClasses(id)
    if classes then
        local names = {}
        local loc = _G.LOCALIZED_CLASS_NAMES_MALE
        for i, cf in ipairs(classes) do names[i] = (type(loc) == "table" and loc[cf]) or cf end
        local tag = table.concat(names, ", ")
        subText = (subText ~= "") and (subText .. "  ·  " .. tag) or tag
    end
    row.sub:SetText(subText)

    local mark = listMarks[id]
    if mark then
        local text = mark.which == "alt" and "Alt" or "Main"
        if mark.sid and mark.sid ~= state.sid then text = text .. " (" .. SlotShort(mark.sid) .. ")" end
        row.mark1:SetText(UI:Colorize(text, ns.COLORS and ns.COLORS[mark.which == "alt" and "alt" or "main"]))
        row.mark1:Show()
    else
        row.mark1:Hide()
    end
    if ns.BiS and ns.BiS:IsObtained(id) then
        row.mark2:SetText("|T" .. UI:Tex("check") .. ":0|t " .. UI:Colorize("owned", ns.COLORS and ns.COLORS.obtained))
        row.mark2:Show()
    else
        row.mark2:Hide()
    end
    row.sel:SetShown(currentPick ~= nil and id == currentPick)

    -- filters off: keep unusable items visible but dimmed
    if not state.usable and ns.ItemDB and ns.ItemDB.IsUsableBy then
        if ns.ItemDB:IsUsableBy(id, MyClass(), state.sid) == false then row:SetAlpha(0.45) end
    end
end

local function RowExtent(d)
    if d.type == "raid" then return ROW_RAID end
    if d.type == "boss" then return ROW_BOSS end
    return ROW_ITEM
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

-- Sections in order of first appearance (raid -> boss, "Crafted — Blacksmithing" -> specialisation, ...):
-- header rows ("raid" = section, "boss" = sub-header) followed by the item rows.
local function Flatten(cands)
    local sections, byKey = {}, {}
    for _, c in ipairs(cands) do
        local kind = RowKind(c)
        local key, name, subKey, subName = SectionOf(c, kind)
        local sec = byKey[key]
        if not sec then
            sec = { name = name, kind = kind, subs = {}, subByKey = {}, count = 0 }
            byKey[key] = sec
            sections[#sections + 1] = sec
        end
        local sk = subKey or false
        local sub = sec.subByKey[sk]
        if not sub then
            sub = { name = subName, key = subKey, items = {} }
            sec.subByKey[sk] = sub
            -- items without a sub-header come first (the general recipes before the specialisations)
            if subKey == nil then table.insert(sec.subs, 1, sub) else sec.subs[#sec.subs + 1] = sub end
        end
        sec.count = sec.count + 1
        sub.items[#sub.items + 1] = {
            type = "item", itemID = c.itemID, via = c.via, viaItem = c.viaItem, ref = c.ref,
            heroic = c.heroic and true or nil, kind = kind, groupKey = c.groupKey, groupName = c.groupName,
            subgroup = c.subgroup, src = c,
        }
    end
    local rows = {}
    for _, sec in ipairs(sections) do
        rows[#rows + 1] = { type = "raid", name = sec.name, count = sec.count, kind = sec.kind,
                            dungeon = sec.kind == "dungeon" }
        for _, sub in ipairs(sec.subs) do
            if sub.key ~= nil then rows[#rows + 1] = { type = "boss", name = sub.name or "?" } end
            for _, item in ipairs(sub.items) do rows[#rows + 1] = item end
        end
    end
    return rows
end

function Picker:Rebuild(resetScroll)
    if not win or not list then return end
    RefreshMarks()
    local cands = Candidates()
    if state.search ~= "" then cands = Search(cands, state.search) end
    list:SetEmptyText(AnySource() and EMPTY_TEXT or EMPTY_NO_SOURCES)
    list:SetData(Flatten(cands), resetScroll)
end

local function Prefetch()
    local ItemDB = ns.ItemDB
    if not (ItemDB and ItemDB.Prefetch) then return end
    local ids, seen = {}, {}
    for _, c in ipairs(Candidates()) do
        if c.itemID and not seen[c.itemID] then seen[c.itemID] = true; ids[#ids + 1] = c.itemID end
        if c.viaItem and not seen[c.viaItem] then seen[c.viaItem] = true; ids[#ids + 1] = c.viaItem end
    end
    ItemDB:Prefetch(ids)
end

local function UpdateHeader()
    if not win then return end
    local whichText = state.which == "alt" and "Alt" or "Main"
    -- Addendum H: the off-spec list says so in the title.
    win:SetWindowTitle(("Choose %s (%s)  ·  P%d%s"):format(SlotLabel(state.sid), whichText, state.phase,
        state.list == "os" and "  ·  Off spec" or ""))
end

local function UpdateCurrent()
    if not current then return end
    local UI = ns.UI
    RefreshMarks()
    local id = currentPick
    current.btn:SetItem(id, UI:EmptySlotTexture(state.sid))
    if id then
        current.name:SetText((UI:ItemText(id)))
        local src = ns.ItemDB and ns.ItemDB:GetSourceText(id, true)
        current.sub:SetText(src or "Other source")
        current.clear:Enable()
    else
        current.name:SetText("|cff808080Nothing chosen yet|r")
        current.sub:SetText(("Current %s pick for %s"):format(state.which == "alt" and "alt" or "main", SlotLabel(state.sid)))
        current.clear:Disable()
    end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function PhaseOptions()
    local opts = {}
    for _, mode in ipairs(PHASE_MODES) do
        opts[#opts + 1] = { value = mode, text = PHASE_TEXT[mode](state.phase) }
    end
    return opts
end

local function OnFilterChanged()
    Prefetch()
    Picker:Rebuild(true)
end

local function EnsureWindow()
    if win then return win end
    local UI = ns.UI
    win = UI:CreateWindow("DisasterZonePicker", "Choose", WIDTH, HEIGHT, { noSavePosition = true })
    win:Hide()
    local c = win.content

    -- current selection
    current = CreateFrame("Frame", nil, c)
    current:SetPoint("TOPLEFT", c, "TOPLEFT", 4, -4)
    current:SetPoint("TOPRIGHT", c, "TOPRIGHT", -4, -4)
    current:SetHeight(36)
    current.btn = UI:CreateItemButton(current, 32)
    current.btn:SetPoint("LEFT", current, "LEFT", 0, 0)
    current.clear = UI:CreateButton(current, "Clear", 60, 22, function()
        if ns.BiS then ns.BiS:SetSlot(state.phase, state.sid, state.which, nil, state.list) end
        UpdateCurrent()
        if list then list:Refresh() end
    end)
    current.clear:SetPoint("RIGHT", current, "RIGHT", 0, 0)
    current.name = current:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    current.name:SetPoint("TOPLEFT", current.btn, "TOPRIGHT", 8, -1)
    current.name:SetPoint("RIGHT", current.clear, "LEFT", -6, 0)
    current.name:SetJustifyH("LEFT")
    current.name:SetWordWrap(false)
    current.sub = current:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    current.sub:SetPoint("BOTTOMLEFT", current.btn, "BOTTOMRIGHT", 8, 1)
    current.sub:SetPoint("RIGHT", current.clear, "LEFT", -6, 0)
    current.sub:SetJustifyH("LEFT")
    current.sub:SetWordWrap(false)

    -- filters
    searchBox = UI:CreateSearchBox(c, WIDTH - 40, function(text)
        text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if text == state.search then return end
        state.search = text
        Picker:Rebuild(true)
    end, "Search items, bosses, professions, factions...")
    searchBox:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -48)
    searchBox:SetPoint("TOPRIGHT", c, "TOPRIGHT", -6, -48)

    phaseDD = UI:CreateDropdown(c, 124, PhaseOptions, function() return state.phaseMode end, function(value)
        state.phaseMode = PHASE_TEXT[value] and value or "upto"
        OnFilterChanged()
    end)
    phaseDD:SetPoint("TOPLEFT", c, "TOPLEFT", 4, -74)

    sourcesDD = UI:CreateMultiDropdown(c, 196, SourceOptions,
        function(key) return Sources()[key] and true or false end,
        function(key, on)
            SetSource(key, on)
            OnFilterChanged()
        end,
        SourcesSummary)
    sourcesDD:SetPoint("LEFT", phaseDD, "RIGHT", 8, 0)

    cbUsable = UI:CreateCheckbox(c, "Usable by my class", function() return state.usable end, function(v)
        state.usable = v
        OnFilterChanged()
    end)
    cbUsable:SetPoint("TOPLEFT", c, "TOPLEFT", 2, -102)

    cbArmor = UI:CreateCheckbox(c, "My armor type only", function() return state.armorOnly end, function(v)
        state.armorOnly = v
        OnFilterChanged()
    end)
    cbArmor:SetPoint("TOPLEFT", c, "TOPLEFT", 172, -102)

    -- list
    list = UI:CreateScrollList(c, ROW_ITEM, InitRow, RowExtent)
    list.frame:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -130)
    list.frame:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 38)
    list:SetEmptyText(EMPTY_TEXT)
    list.emptyText:SetWordWrap(true)

    hint = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 6, 6)
    hint:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -6, 6)
    hint:SetJustifyH("LEFT")
    hint:SetText(HINT_TEXT)

    -- the whole window accepts items dragged from the bags
    UI:AttachItemDrop(win, OnDropItem)
    current.btn.onReceiveItem = OnDropItem

    win:HookScript("OnHide", function()
        if searchBox then searchBox:ClearFocus() end
        if ns.MyBiS and ns.MyBiS.OnPickerClosed then ns.MyBiS:OnPickerClosed() end
    end)
    return win
end

local function Position(anchor)
    win:ClearAllPoints()
    local main = ns.MainFrame and ns.MainFrame:IsShown() and ns.MainFrame:GetFrame() or nil
    if main then
        local right, left = main:GetRight(), main:GetLeft()
        local screenRight = UIParent:GetRight()
        if right and left and screenRight and right + WIDTH + 2 > screenRight and left - WIDTH - 2 >= 0 then
            win:SetPoint("TOPRIGHT", main, "TOPLEFT", -2, 0)
        else
            win:SetPoint("TOPLEFT", main, "TOPRIGHT", 2, 0)
        end
    elseif anchor and anchor.GetRight then
        win:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    else
        win:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Returns true when the picker opened (false while the group's BiS lists are locked, §38).
-- list (Addendum H): "ms" (default) or "os" = pick for the off-spec list.
function Picker:Open(phase, sid, which, anchor, list)
    sid = tonumber(sid)
    if not sid or not SlotInfo(sid) then return false end
    local locked, info = ListLocked()
    if locked then
        LockedMessage(info)
        self:Close()
        return false
    end
    state.phase = tonumber(phase) or state.phase or 1
    state.sid = sid
    state.which = which == "alt" and "alt" or "main"
    state.list = (list == "os") and "os" or nil
    state.search = ""
    Sources()

    EnsureWindow()
    HookInsertLink()
    Position(anchor)
    UpdateHeader()

    searchBox:SetText("")
    cbUsable:Refresh()
    cbArmor:Refresh()
    cbArmor:SetShown(ARMOR_SLOTS[sid] and true or false)
    phaseDD:Refresh()
    sourcesDD:Refresh()

    Prefetch()
    win:Show()
    win:Raise()
    UpdateCurrent()
    self:Rebuild(true)
    return true
end

function Picker:Close()
    if win and win:IsShown() then win:Hide() end
end

function Picker:IsOpen()
    return win ~= nil and win:IsShown()
end

function Picker:GetState()
    return state.phase, state.sid, state.which, state.list
end

-- DisasterZone extension (§35): the ticked sources (a copy) and the phase filter ("upto" | "only" | "all").
function Picker:GetSources()
    local out = {}
    for _, key in ipairs(SOURCE_KEYS) do out[key] = Sources()[key] and true or false end
    return out
end

function Picker:SetSourceEnabled(key, on)
    if not SOURCE_INFO[key] then return false end
    SetSource(key, on)
    if sourcesDD and sourcesDD.Refresh then sourcesDD:Refresh() end
    if self:IsOpen() then OnFilterChanged() end
    return true
end

function Picker:GetPhaseMode()
    return state.phaseMode
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------

ns:On("ITEMINFO_READY", function()
    if not Picker:IsOpen() then return end
    UpdateCurrent()
    if state.search ~= "" then
        -- names that just loaded may now match the search
        Debounce("picker-search", 0.2, function() if Picker:IsOpen() then Picker:Rebuild(false) end end)
    else
        list:Refresh()
    end
end)

local function RefreshMarkers()
    if not Picker:IsOpen() then return end
    UpdateCurrent()
    list:Refresh()
end
ns:On("MYLIST_CHANGED", RefreshMarkers)
ns:On("OWNED_UPDATED", RefreshMarkers)

-- A lock that starts while the picker is open closes it (§38).
local function OnLockChanged()
    if Picker:IsOpen() and ListLocked() then Picker:Close() end
end
ns:On("BIS_LOCK_CHANGED", OnLockChanged)
ns:On("GROUP_RULES_CHANGED", OnLockChanged)
