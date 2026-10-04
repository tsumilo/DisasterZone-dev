if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Atlas.lua", ...) then return end -- DisasterZone UI/Atlas.lua
-- ns.AtlasUI: the Atlas tab, a loot browser for every member (no guild or raid needed). Three columns: the sources
-- (categories that fold open: Raids, Dungeons, Crafting, Reputation, PvP, Badges & Sunmote, Collections, World
-- Events, Sets), the pages of the chosen source (bosses, sub-lists, standings) and the page's items. One search box
-- finds any item by name (or number) across everything; a click on a result opens its page.
-- Items: hover = tooltip, shift-click = link, ctrl-click = dressing room, right-click = menu with "add to my BiS list"
-- (phase, best / alt, the slot for rings / trinkets / one-handers, "and later phases"), try on, link. Marks: on my
-- list (best / alt / off spec, with the phases), owned, and for the Loot Council how many members want it.
-- Model: Core/Atlas.lua (ns.Atlas).
local addonName, ns = ...

local AtlasUI = {}
ns.AtlasUI = AtlasUI

local ipairs, pairs, type, tonumber, tostring = ipairs, pairs, type, tonumber, tostring
local format = string.format

local TOP_H = 34
local LEFT_W, MID_W, COL_GAP = 180, 172, 10
local ROW_CAT, ROW_SRC, ROW_PAGE, ROW_ITEM, ROW_HEADER = 22, 20, 20, 34, 22
local ROW_TWO_LINES = 32          -- a source / page name that needs two lines
local MAX_SHOWN = 300             -- search results drawn at most (Found in narrows them down)
local RIGHT_COL_W = 112
local DOT = "  ·  "
local PLUS_TEX = "Interface\\Buttons\\UI-PlusButton-Up"
local MINUS_TEX = "Interface\\Buttons\\UI-MinusButton-Up"
local FOOTER_TEXT = "Right-click an item to add it to your BiS list  ·  shift-click links it  ·  ctrl-click tries it on"
local CLASS_WEAPON, CLASS_ARMOR = 2, 4   -- Enum.ItemClass

local panel, searchBox, showDD, slotDD, srcList, pageList, itemList
local srcTitle, srcSub, itemTitle, itemSub, diffNormal, diffHeroic, footer
local state = {
    cat = nil, src = nil, page = nil, heroic = false,
    expanded = nil,      -- the category folded open in the left column
    search = "",
    slot = nil,          -- slot filter: nil = any, sid, or 0 = not gear
    selected = nil,      -- the item a search result jumped to (highlighted)
    facet = nil,         -- search: the category the results are narrowed to (nil = all)
}
local searchCache        -- { key, entries, facets } of the last search
local marks = {}         -- Atlas:GetMyListMarks() of the last refresh
local SelectSource, ShowItemMenu, SearchResults   -- forward declarations
local wantCache = {}     -- [itemID] = number of members who want it (council only; per refresh)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Atlas() return ns.Atlas end

local function Debounce(key, sec, fn)
    if ns.Util and ns.Util.Debounce then ns.Util.Debounce(key, sec, fn) else C_Timer.After(sec, fn) end
end

-- The Show filter: "all" | "class" | "spec" | "os" (remembered; a spec I no longer have falls back).
local function ShowMode()
    local v = ns.DB and ns.DB.GetSetting and ns.DB:GetSetting("atlas.show")
    return Atlas():ValidShow(v)
end

local function SetShowMode(mode)
    if ns.db and ns.DB and ns.DB.SetSetting then ns.DB:SetSetting("atlas.show", mode) end
end

local function Filtered()
    return ShowMode() ~= "all" or state.slot ~= nil
end

local function IsCouncil()
    return (ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil()) and true or false
end

local function GuildPhase()
    local p = ns.Guild and ns.Guild.GetGuildPhase and tonumber(ns.Guild:GetGuildPhase())
    if p and p >= 1 and p <= (ns.MAX_PHASE or 5) then return math.floor(p) end
    return nil
end

local function SlotLabel(sid)
    local s = ns.SLOTS and ns.SLOTS[sid]
    return s and s.label or ("Slot " .. tostring(sid))
end

local function Colorize(text, key)
    return ns.UI:Colorize(text, ns.COLORS and ns.COLORS[key])
end

local function IsSearching()
    local A = Atlas()
    return A and #(state.search or "") > 0 and (tonumber(state.search) ~= nil or #state.search >= A.MIN_SEARCH)
end

-- "Shoulder  ·  Leather", "Two-Hand  ·  Mace", "Recipe", "Mount" ... (instant info: never waits for the server).
local function TypeLine(id)
    if id < 0 then return "Enchant" end
    if not (C_Item and C_Item.GetItemInfoInstant) then return "" end
    local _, itemType, subType, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(id)
    local slotText = (equipLoc and equipLoc ~= "" and type(_G[equipLoc]) == "string") and _G[equipLoc] or nil
    if slotText then
        local kind
        if classID == CLASS_WEAPON then
            kind = subType
        elseif classID == CLASS_ARMOR and equipLoc ~= "INVTYPE_CLOAK" and subclassID and subclassID >= 1 then
            kind = subType
        end
        if type(kind) == "string" and kind ~= "" then return slotText .. DOT .. kind end
        return slotText
    end
    if type(subType) == "string" and subType ~= "" and subType ~= "Junk" and subType ~= "Other" then return subType end
    return type(itemType) == "string" and itemType or ""
end

-- Tier tokens: "Token  ·  Paladin, Priest, Warlock".
local function TokenLine(id)
    local DB = ns.ItemDB
    local classes = DB and DB.GetTokenClasses and DB:GetTokenClasses(id)
    if type(classes) ~= "table" then return nil end
    local names, loc = {}, _G.LOCALIZED_CLASS_NAMES_MALE
    for i, cf in ipairs(classes) do names[i] = (type(loc) == "table" and loc[cf]) or cf end
    return "Token" .. DOT .. table.concat(names, ", ")
end

local function NameText(id)
    local A = Atlas()
    if id < 0 then
        return "|cffffd100" .. (A:GetName(id) or ("Spell " .. -id)) .. "|r"
    end
    local name, _, quality = ns.ItemDB:GetInfo(id)
    if name then
        return "|c" .. ns.UI:ColorHex(ns.UI:QualityColor(quality)) .. name .. "|r"
    end
    return "|cffb0b0b0" .. (A:GetShippedName(id) or "Loading...") .. "|r"
end

local function Wanted(id)
    local n = wantCache[id]
    if n ~= nil then return n end
    n = 0
    if id > 0 and ns.Store and ns.Store.GetWanters then
        local seen = {}
        for _, w in ipairs(ns.Store:GetWanters(id, { list = "ms" }) or {}) do
            if type(w) == "table" and type(w.key) == "string" and not seen[w.key] and not w.cantUse then
                seen[w.key] = true
                n = n + 1
            end
        end
    end
    wantCache[id] = n
    return n
end

---------------------------------------------------------------------------
-- Filters
---------------------------------------------------------------------------

local function PassesSlot(id)
    if state.slot == nil then return true end
    if id < 0 then return state.slot == 0 end
    local DB = ns.ItemDB
    if state.slot == 0 then return #DB:GetSlotsForItem(id) == 0 end
    return DB:FitsSlot(id, state.slot)
end

local function Passes(id)
    if not PassesSlot(id) then return false end
    return Atlas():PassesShow(id, ShowMode())
end

local function SlotOptions()
    local opts = { { value = nil, text = "Any slot" } }
    local seen = {}
    for sid = 1, ns.NUM_SLOTS or 17 do
        local group = ns.SLOT_GROUP and ns.SLOT_GROUP[sid]
        local first = group and group[1] or sid
        if not seen[first] then
            seen[first] = true
            local label = SlotLabel(first)
            if group and #group > 1 and (first == 11 or first == 13) then label = label:gsub(" 1$", "") end
            opts[#opts + 1] = { value = first, text = label }
        end
    end
    opts[#opts + 1] = { value = 0, text = "Not gear", tooltip = "Recipes, mounts, pets, enchants and other items you can't wear." }
    return opts
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

-- Width of a text in a font (a hidden FontString), for rows that need two lines instead of cutting a name off.
local measureFS
local function TextWidth(text, font)
    if not measureFS then
        measureFS = (panel or UIParent):CreateFontString(nil, "OVERLAY", font)
        measureFS:Hide()
    end
    measureFS:SetFontObject(font)
    measureFS:SetText(text or "")
    return measureFS:GetStringWidth() or 0
end

local function ListWidth(list, fallback)
    local w = list and list.box and list.box:GetWidth()
    if w and w > 0 then return w end
    return fallback
end

local function SetupTextRow(row)
    row.cdl = true
    row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(1, 0.82, 0, 0.14)
    row.sel:Hide()
    row:SetHighlightTexture(ns.UI:Tex("rowHilight"), "ADD")
    row.toggle = row:CreateTexture(nil, "ARTWORK")
    row.toggle:SetSize(12, 12)
    row.toggle:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    if row.label.SetMaxLines then row.label:SetMaxLines(2) end
    row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.tag:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.tag:SetJustifyH("RIGHT")
    row:RegisterForClicks("LeftButtonUp")
end

local function InitSourceRow(row, d)
    if not row.cdl then SetupTextRow(row) end
    row.label:ClearAllPoints()
    if d.type == "cat" then
        row.toggle:SetTexture(d.expanded and MINUS_TEX or PLUS_TEX)
        row.toggle:Show()
        row.label:SetFontObject("GameFontNormal")
        row.label:SetWordWrap(false)
        row.label:SetPoint("LEFT", row.toggle, "RIGHT", 5, 0)
        row.label:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.label:SetText(d.cat.name)
        row.tag:SetText("")
        row.sel:Hide()
    else
        row.toggle:Hide()
        row.label:SetFontObject("GameFontHighlightSmall")
        row.label:SetWordWrap(true)
        row.label:SetPoint("LEFT", row, "LEFT", 21, 0)
        row.label:SetPoint("RIGHT", row, "RIGHT", -30, 0)
        row.label:SetText(d.src.name)
        row.tag:SetText(d.src.phase and ("P" .. d.src.phase) or "")
        row.sel:SetShown(not IsSearching() and state.cat == d.cat.key and state.src == d.src.key)
    end
    row:SetScript("OnClick", function()
        if d.type == "cat" then
            state.expanded = (state.expanded ~= d.cat.key) and d.cat.key or nil
            AtlasUI:RefreshSources()
        else
            if searchBox and (searchBox:GetText() or "") ~= "" then searchBox:SetText("") end
            state.search = ""
            SelectSource(d.cat.key, d.src.key)
        end
    end)
end

local function InitPageRow(row, d)
    if not row.cdl then SetupTextRow(row) end
    row.toggle:Hide()
    row.label:ClearAllPoints()
    row.label:SetFontObject("GameFontHighlightSmall")
    row.label:SetWordWrap(true)
    row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
    if d.type == "facet" then
        -- search: where the results are from (All, Raids, PvP, ...) with their counts
        row.label:SetPoint("RIGHT", row, "RIGHT", -36, 0)
        row.label:SetText(d.name)
        row.tag:SetText(tostring(d.count))
        row.sel:SetShown(state.facet == d.key)
        row:SetScript("OnClick", function()
            state.facet = d.key
            state.selected = nil
            AtlasUI:RefreshPages()
            AtlasUI:RefreshItems(true)
        end)
        return
    end
    row.label:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.label:SetText(d.page.name or "?")
    row.tag:SetText("")
    row.sel:SetShown(not IsSearching() and state.page == d.page.key)
    row:SetScript("OnClick", function()
        if searchBox and (searchBox:GetText() or "") ~= "" then searchBox:SetText("") end
        state.search = ""
        state.page = d.page.key
        state.selected = nil
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end)
end

local function SourceExtent(d)
    if d.type == "cat" then return ROW_CAT end
    local w = ListWidth(srcList, LEFT_W - 20) - 21 - 30
    return TextWidth(d.src.name, "GameFontHighlightSmall") > w and ROW_TWO_LINES or ROW_SRC
end

local function PageExtent(d)
    local w = ListWidth(pageList, MID_W - 20) - 8 - (d.type == "facet" and 36 or 6)
    return TextWidth(d.type == "facet" and d.name or d.page.name, "GameFontHighlightSmall") > w and ROW_TWO_LINES or ROW_PAGE
end

-- Right column: the extra text (skill, cost) and my marks / the council's count.
local function MarksText(id)
    local parts = {}
    local m = marks[id]
    if m then
        if m.main then
            parts[#parts + 1] = "|T" .. ns.UI:Tex("star") .. ":0|t " .. Colorize(Atlas():PhasesText(m.main), "main")
        elseif m.alt then
            parts[#parts + 1] = Colorize("Alt " .. Atlas():PhasesText(m.alt), "alt")
        elseif m.os then
            parts[#parts + 1] = Colorize("OS " .. Atlas():PhasesText(m.os), "offspec")
        end
    end
    if id > 0 and ns.BiS and ns.BiS.IsObtained and ns.BiS:IsObtained(id) then
        parts[#parts + 1] = "|T" .. ns.UI:Tex("check") .. ":0|t"
    end
    return table.concat(parts, " ")
end

local function RowTooltip(row)
    local d = row.__cdlData
    if not d or d.type ~= "item" then return end
    local id = d.id
    local function extra(tt)
        local viaName = d.via and (Atlas():GetName(d.via) or "the item above")
        local viaText = (d.viaKind == "token" and ("From " .. tostring(viaName)))
            or (d.viaKind == "upgrade" and ("Upgrade of " .. tostring(viaName) .. ": bring it and a Sunmote to the Sunwell vendor"))
            or (d.viaKind == "base" and ("Bring this and a Sunmote to the Sunwell vendor for " .. tostring(viaName)))
            or (d.viaKind == "makes" and ("Made with " .. tostring(viaName)))
        if viaText then
            tt:AddLine(" ")
            tt:AddLine(viaText, 0.7, 0.7, 0.7, true)
        end
        if d.xt or d.x then
            tt:AddLine(" ")
            tt:AddLine((d.x and d.x:find("^Skill") and "" or "Cost: ") .. (d.xt or d.x), 1, 0.82, 0, true)
        end
        if d.loc then
            tt:AddLine(" ")
            tt:AddLine(Atlas():LocationText(d.loc) or "", 0.7, 0.7, 0.7, true)
        end
        if id > 0 and #Atlas():GetBiSTargets(id) > 0 then
            tt:AddLine(" ")
            tt:AddLine("Right-click: add to your BiS list", 0.55, 0.8, 1)
        end
        if d.loc and IsSearching() then tt:AddLine("Click: open its page", 0.55, 0.8, 1) end
    end
    if id > 0 then
        ns.UI:SetItemTooltip(row, id, extra)
    else
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        if GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(-id)
        else
            GameTooltip:SetHyperlink("spell:" .. -id)
        end
        extra(GameTooltip)
        GameTooltip:Show()
    end
end

local function OnItemClick(row, mouseButton)
    local d = row.__cdlData
    if not d or d.type ~= "item" then return end
    local id = d.id
    if mouseButton == "RightButton" then
        ShowItemMenu(row, d)
        return
    end
    if id > 0 then
        if ns.UI:HandleModifiedItemClick(id) then return end
    elseif IsShiftKeyDown() then
        local link = GetSpellLink and GetSpellLink(-id)
        local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
        if link and insert then insert(link) end
        return
    end
    if d.loc and IsSearching() then AtlasUI:GoTo(d.loc) end
end

local function SetupItemRow(row)
    local UI = ns.UI
    row.cdl = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(1, 0.82, 0, 0.16)
    row.sel:Hide()
    row:SetHighlightTexture(UI:Tex("rowHilight"), "ADD")

    row.header = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.header:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.header:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.header:SetJustifyH("LEFT")
    row.header:SetWordWrap(false)
    row.headerLine = row:CreateTexture(nil, "ARTWORK")
    row.headerLine:SetHeight(1)
    row.headerLine:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 1)
    row.headerLine:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 1)
    row.headerLine:SetColorTexture(1, 0.82, 0, 0.25)

    row.icon = UI:CreateItemButton(row, 28)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.icon:EnableMouse(false)   -- the row handles hover and clicks
    -- the guide line in front of a token's / item's rewards (indented rows)
    row.guide = row:CreateTexture(nil, "ARTWORK")
    row.guide:SetWidth(2)
    row.guide:SetPoint("TOPLEFT", row, "TOPLEFT", 14, 0)
    row.guide:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 14, 0)
    row.guide:SetColorTexture(1, 0.82, 0, 0.35)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
    row.name:SetPoint("RIGHT", row, "RIGHT", -RIGHT_COL_W, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 2)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -RIGHT_COL_W, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)

    row.extra = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.extra:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -5)
    row.extra:SetWidth(RIGHT_COL_W - 10)
    row.extra:SetJustifyH("RIGHT")
    row.extra:SetWordWrap(false)

    row.mark = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.mark:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 5)
    row.mark:SetWidth(RIGHT_COL_W - 10)
    row.mark:SetJustifyH("RIGHT")
    row.mark:SetWordWrap(false)

    row:SetScript("OnClick", OnItemClick)
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function InitItemRow(row, d)
    if not row.cdl then SetupItemRow(row) end
    local hl = row:GetHighlightTexture()
    if d.type ~= "item" then
        row.icon:Hide()
        row.name:Hide()
        row.sub:Hide()
        row.extra:Hide()
        row.mark:Hide()
        row.sel:Hide()
        if hl then hl:SetAlpha(0) end
        row.guide:Hide()
        row.header:Show()
        row.header:SetFontObject(d.type == "more" and "GameFontDisableSmall" or "GameFontNormal")
        row.header:SetText(d.text or "")
        row.headerLine:SetShown(d.type == "header")
        return
    end
    if hl then hl:SetAlpha(1) end
    row.header:Hide()
    row.headerLine:Hide()
    local id = d.id
    row.icon:ClearAllPoints()
    row.icon:SetPoint("LEFT", row, "LEFT", d.via and 26 or 4, 0)
    row.guide:SetShown(d.via ~= nil)
    row.icon:Show()
    if id > 0 then
        row.icon:SetItem(id)
    else
        row.icon:SetItem(nil)
        local tex = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(-id))
            or (GetSpellTexture and GetSpellTexture(-id))
        row.icon.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.icon.icon:SetAlpha(1)
        if row.icon.icon.SetDesaturated then row.icon.icon:SetDesaturated(false) end
    end
    row.name:Show()
    row.name:SetText(NameText(id))
    row.sub:Show()
    local sub
    if d.loc and IsSearching() then
        sub = Atlas():LocationText(d.loc)
    else
        sub = (id > 0 and TokenLine(id)) or TypeLine(id)
        if d.viaKind == "upgrade" then
            sub = "Sunmote upgrade" .. DOT .. sub
        elseif d.viaKind == "base" then
            sub = "Made from" .. DOT .. sub
        elseif d.viaKind == "makes" then
            sub = "Makes" .. DOT .. sub
        elseif d.setPage and id > 0 then
            -- a set piece: its slot and where it comes from ("Token · Prince Malchezaar", "Arena Season 2")
            local slotText = TypeLine(id):match("^(.-)  ·  ") or TypeLine(id)
            local from = ns.ItemDB and ns.ItemDB:GetSourceText(id, true)
            if from then sub = slotText .. DOT .. from end
        end
    end
    row.sub:SetText(sub or "")
    row.extra:SetShown(d.x ~= nil)
    row.extra:SetText(d.x or "")
    local markText = MarksText(id)
    if IsCouncil() and id > 0 then
        local n = Wanted(id)
        if n > 0 then
            markText = (markText ~= "" and (markText .. "  ") or "") .. Colorize(n .. " want", "council")
        end
    end
    row.mark:SetShown(markText ~= "")
    row.mark:SetText(markText)
    row.sel:SetShown(state.selected ~= nil and id == state.selected)
end

local function ItemExtent(d)
    if d.type == "item" then return ROW_ITEM end
    return ROW_HEADER
end

---------------------------------------------------------------------------
-- The item menu (right-click)
---------------------------------------------------------------------------

local function MenuLocked(root)
    local locked, info = ns.UI:IsMyListLocked()
    if locked then
        root:CreateTitle(ns.UI:LockIcon(12) .. " BiS lists are locked by " .. ns.UI:LockByText(info))
    end
    return locked
end

-- The "best" / "alt" choices of one phase: one pair per piece (a token can give several) and slot (rings, trinkets
-- and one-handers fit two).
local function AddPhaseChoices(sub, targets, phase, list, later)
    local BiS = ns.BiS
    local A = Atlas()
    for _, t in ipairs(targets) do
        for _, sid in ipairs(t.sids) do
            local prefix = ""
            if #targets > 1 then prefix = (A:GetName(t.itemID) or "?") .. DOT end
            if #t.sids > 1 then prefix = prefix .. SlotLabel(sid) .. DOT end
            for _, which in ipairs({ "main", "alt" }) do
                local main, alt = BiS:GetSlot(phase, sid, list)
                local cur = which == "main" and main or alt
                local text = prefix .. (which == "main" and "As best" or "As alt")
                if cur == t.itemID then text = text .. "  |cff808080(already)|r" end
                local b = sub:CreateButton(text, function()
                    local n = A:AddToBiS(t.itemID, sid, which, phase, list, later)
                    if n > 0 then
                        local link = ns.ItemDB:GetLink(t.itemID) or A:GetName(t.itemID) or "item"
                        local where = later and (n > 1 and ("P%d-%d"):format(phase, phase + n - 1) or ("P" .. phase))
                            or ("P" .. phase)
                        ns:Print("%s is now your %s for %s (%s%s).", link, which == "main" and "BiS" or "alt",
                            SlotLabel(sid), where, list == "os" and ", off spec" or "")
                    end
                end)
                if cur and cur ~= t.itemID and b and b.SetTooltip then
                    b:SetTooltip(function(tooltip)
                        tooltip:AddLine(("Replaces %s"):format(A:GetName(cur) or "?"), 1, 1, 1, true)
                    end)
                end
            end
        end
    end
end

local function AddListMenu(root, text, targets, list)
    local sub = root:CreateButton(text)
    local now = GuildPhase()
    local m = marks
    for p = 1, ns.MAX_PHASE or 5 do
        local label = "Phase " .. p
        if p == now then label = label .. "  |cff808080(now)|r" end
        local onList = false
        for _, t in ipairs(targets) do
            local mk = m[t.itemID]
            if mk and ((list == "os" and mk.os and mk.os[p]) or (list ~= "os" and ((mk.main and mk.main[p]) or (mk.alt and mk.alt[p])))) then
                onList = true
            end
        end
        if onList then label = label .. "  |T" .. ns.UI:Tex("check") .. ":0|t" end
        AddPhaseChoices(sub:CreateButton(label), targets, p, list, false)
    end
    local from = now or 1
    if from < (ns.MAX_PHASE or 5) then
        if sub.CreateDivider then sub:CreateDivider() end
        local later = sub:CreateButton(("Phase %d and later"):format(from))
        if later.SetTooltip then
            later:SetTooltip(function(tooltip)
                tooltip:AddLine(("Phase %d and later"):format(from), 1, 0.82, 0)
                tooltip:AddLine(("Sets it in P%d, and in every later phase where that place is still empty."):format(from), 1, 1, 1, true)
            end)
        end
        AddPhaseChoices(later, targets, from, list, true)
    end
end

function ShowItemMenu(row, d)
    local id = d.id
    local A = Atlas()
    ns.UI:ContextMenu(row, function(root)
        root:CreateTitle(A:GetName(id) or "?")
        if id > 0 then
            local targets = A:GetBiSTargets(id)
            if #targets > 0 then
                local locked = MenuLocked(root)
                local usable = true
                for _, t in ipairs(targets) do
                    if A:IsUsableByMe(t.itemID) == false then usable = false end
                end
                if not usable then
                    root:CreateTitle("Your class can't use this")
                elseif not locked then
                    local BiS = ns.BiS
                    if BiS and BiS.HasOffSpec and BiS:HasOffSpec() then
                        local ms = BiS.GetSpec and BiS:GetSpec() or ""
                        local os = BiS.GetSpec and BiS:GetSpec("os") or ""
                        AddListMenu(root, "Add to main spec" .. (ms ~= "" and (" (" .. ms .. ")") or ""), targets, nil)
                        AddListMenu(root, "Add to off spec" .. (os ~= "" and (" (" .. os .. ")") or ""), targets, "os")
                    else
                        AddListMenu(root, "Add to my BiS list", targets, nil)
                    end
                end
                root:CreateButton("Try on", function()
                    local link = ns.ItemDB:GetLink(targets[1].itemID)
                    if link and DressUpItemLink then DressUpItemLink(link) end
                end)
            end
            root:CreateButton("Link in chat", function() ns.UI:LinkInChat(id) end)
        else
            root:CreateButton("Link in chat", function()
                local link = GetSpellLink and GetSpellLink(-id)
                local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
                if link and insert and not insert(link) then
                    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
                    if open then open(link) end
                end
            end)
        end
        if d.loc and IsSearching() then
            root:CreateButton("Open its page", function() AtlasUI:GoTo(d.loc) end)
        end
    end)
end

---------------------------------------------------------------------------
-- Lists
---------------------------------------------------------------------------

function AtlasUI:RefreshSources()
    if not srcList then return end
    local rows = {}
    for _, cat in ipairs(Atlas():GetCategories()) do
        local open = state.expanded == cat.key
        rows[#rows + 1] = { type = "cat", cat = cat, expanded = open }
        if open then
            for _, src in ipairs(cat.sources) do rows[#rows + 1] = { type = "src", cat = cat, src = src } end
        end
    end
    srcList:SetData(rows)
end

-- Does a page list something the filters let through? Show: My class / a spec: something my class can use (so a set
-- source lists my class's sets); a slot: something for that slot (Ring: the bosses that drop rings). Instant data
-- only: the stats a spec is judged by are left to the item list.
local function PageVisible(page)
    local mode = ShowMode()
    if mode == "all" and state.slot == nil then return true end
    local A = Atlas()
    for _, id in ipairs(A:GetPageEntries(page, state.heroic)) do
        if type(id) == "number" and PassesSlot(id) and (mode == "all" or A:EntryUsable(id)) then return true end
    end
    return false
end

-- The pages the middle column lists.
local function VisiblePages(src)
    local out = {}
    if not src then return out end
    for i, page in ipairs(src.pages) do
        if PageVisible(page) then out[#out + 1] = { type = "page", page = page, index = i } end
    end
    return out
end

local function PlaceList(offset)
    pageList.frame:ClearAllPoints()
    pageList.frame:SetPoint("TOPLEFT", srcSub, "BOTTOMLEFT", 0, offset)
    pageList.frame:SetPoint("BOTTOMRIGHT", panel.mid, "BOTTOMRIGHT", 0, 0)
end

function AtlasUI:RefreshPages()
    if not pageList then return end
    local A = Atlas()
    if IsSearching() then
        local res = SearchResults()
        local rows = {}
        if res.facets[1].count > 0 then
            for _, f in ipairs(res.facets) do rows[#rows + 1] = { type = "facet", key = f.key, name = f.name, count = f.count } end
        end
        pageList:SetData(rows)
        pageList.frame:Show()
        srcTitle:SetText("Found in")
        srcSub:SetText(res.facets[1].count == 0 and "No matches" or "")
        diffNormal:Hide()
        diffHeroic:Hide()
        PlaceList(-8)
        return
    end
    local src = state.cat and A:GetSource(state.cat, state.src)
    local rows = VisiblePages(src)
    -- the shown page was filtered out: open the first one left
    if #rows > 0 then
        local still = false
        for _, r in ipairs(rows) do
            if r.page.key == state.page then still = true end
        end
        if not still then
            state.page = rows[1].page.key
            state.selected = nil
        end
    end
    pageList:SetData(rows)
    -- a source with a single page (a vendor, a collection) needs no list: the item list's title names it
    pageList.frame:SetShown(not (src and #src.pages == 1))
    srcTitle:SetText(src and src.name or "")
    local sub = {}
    if src and src.phase then sub[#sub + 1] = "Phase " .. src.phase end
    if src and src.size then sub[#sub + 1] = src.size .. " players" end
    srcSub:SetText(table.concat(sub, DOT))
    local heroic = A:HasHeroic(src)
    diffNormal:SetShown(heroic)
    diffHeroic:SetShown(heroic)
    diffNormal:SetActive(not state.heroic)
    diffHeroic:SetActive(state.heroic)
    PlaceList(heroic and -30 or -8)
end

-- Item rows of a list of entries: headers kept only when an item follows them. Under an item, indented rows of what
-- it turns into or comes from (they work like any item): a token's pieces for my class (filtered like the page), a
-- Sunwell drop's Sunmote upgrade, a Sunmote item's base drop, what a recipe makes.
local function EntryRows(entries, x, setPage, xt)
    local rows, pendingHeader, count = {}, nil, 0
    local A = Atlas()
    for i, e in ipairs(entries) do
        if type(e) == "string" then
            pendingHeader = { type = "header", text = e }
        elseif type(e) == "number" and Passes(e) then
            if pendingHeader then
                rows[#rows + 1] = pendingHeader
                pendingHeader = nil
            end
            rows[#rows + 1] = { type = "item", id = e, x = type(x) == "table" and x[i] or nil,
                                xt = type(xt) == "table" and xt[i] or nil, setPage = setPage }
            count = count + 1
            if e > 0 then
                for _, r in ipairs(A:GetRewards(e)) do
                    if r.kind ~= "token" or Passes(r.id) then
                        rows[#rows + 1] = { type = "item", id = r.id, via = e, viaKind = r.kind }
                    end
                end
            end
        end
    end
    return rows, count
end

local function Prefetch(rows)
    local ids = {}
    for _, r in ipairs(rows) do
        if r.type == "item" and r.id > 0 then ids[#ids + 1] = r.id end
    end
    if ns.ItemDB and ns.ItemDB.Prefetch then ns.ItemDB:Prefetch(ids) end
end

-- Every match of the search that passes the filters, and where they are from: { key, entries, facets = { { key,
-- name, count }, ... } } (facets in category order, "All" first). Cached until the search or a filter changes.
function SearchResults()
    local A = Atlas()
    local key = table.concat({ state.search, ShowMode(), tostring(state.slot) }, "\0")
    if searchCache and searchCache.key == key then return searchCache end
    local entries, counts = {}, {}
    for _, loc in ipairs(A:Search(state.search) or {}) do
        if Passes(loc.id) then
            entries[#entries + 1] = { type = "item", id = loc.id, loc = loc }
            counts[loc.cat.key] = (counts[loc.cat.key] or 0) + 1
        end
    end
    local facets = { { key = nil, name = "All", count = #entries } }
    for _, cat in ipairs(A:GetCategories()) do
        if counts[cat.key] then facets[#facets + 1] = { key = cat.key, name = cat.name, count = counts[cat.key] } end
    end
    searchCache = { key = key, entries = entries, facets = facets }
    return searchCache
end

function AtlasUI:RefreshItems(resetScroll)
    if not itemList then return end
    local A = Atlas()
    marks = A:GetMyListMarks()
    wantCache = {}
    local rows, count = {}, 0
    if IsSearching() then
        local res = SearchResults()
        local facetName
        for _, f in ipairs(res.facets) do
            if f.key ~= nil and f.key == state.facet then facetName = f.name end
        end
        if not facetName then state.facet = nil end
        for _, e in ipairs(res.entries) do
            if state.facet == nil or e.loc.cat.key == state.facet then
                count = count + 1
                if count <= MAX_SHOWN then rows[#rows + 1] = e end
            end
        end
        if count > MAX_SHOWN then
            rows[#rows + 1] = { type = "more",
                text = ("Showing the first %d of %d: type more of the name, or pick where it's from."):format(MAX_SHOWN, count) }
        end
        itemTitle:SetText(facetName and ("Search" .. DOT .. facetName) or "Search")
        itemSub:SetText(count == 1 and "1 item" or (count .. " items"))
        itemList:SetEmptyText(Filtered()
            and "Nothing matches with these filters. Try Show: All items, or Any slot."
            or "No item has that name.")
    else
        local src = state.cat and A:GetSource(state.cat, state.src)
        local page = src and A:GetPage(state.cat, state.src, state.page)
        if page then
            local heroic = state.heroic and page.heroicItems ~= nil
            local plain = not state.heroic or not page.heroicItems
            rows, count = EntryRows(A:GetPageEntries(page, heroic), plain and page.x or nil, src.kind == "sets",
                plain and page.xt or nil)
            -- a set page: the set's name over the list (the middle column names the class)
            local title = page.title or page.name or ""
            if heroic then title = title .. " (Heroic)" end
            itemTitle:SetText(title)
            local sub = count == 1 and "1 item" or (count .. " items")
            if page.title and page.name then sub = page.name .. DOT .. sub end
            if page.phase and page.phase ~= (src.phase or 1) then sub = "Phase " .. page.phase .. DOT .. sub end
            itemSub:SetText(sub)
            itemList:SetEmptyText(Filtered()
                and "Nothing here passes the filters. Try Show: All items, or Any slot."
                or "Nothing here.")
        else
            itemTitle:SetText("")
            itemSub:SetText("")
            itemList:SetEmptyText("Pick a source on the left.")
        end
    end
    itemList:SetData(rows, resetScroll)
    Prefetch(rows)
end

function AtlasUI:Refresh()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    panel.dirty = false
    if not state.cat then
        local cat, src = Atlas():DefaultSource()
        if cat then
            state.expanded = cat
            SelectSource(cat, src)
            return
        end
    end
    if showDD and showDD.Refresh then showDD:Refresh() end
    if slotDD and slotDD.Refresh then slotDD:Refresh() end
    self:RefreshSources()
    self:RefreshPages()
    self:RefreshItems()
end

function SelectSource(catKey, srcKey, pageKey)
    local A = Atlas()
    local src = A:GetSource(catKey, srcKey)
    if not src then return end
    state.cat, state.src = catKey, srcKey
    state.expanded = catKey
    local page = pageKey and A:GetPage(catKey, srcKey, pageKey)
    if not page then
        -- the first page with something for my class (a set source opens on my class's set)
        for _, p in ipairs(src.pages) do
            if A:PageUsable(p, state.heroic) then
                page = p
                break
            end
        end
    end
    state.page = page and page.key or (src.pages[1] and src.pages[1].key)
    if not A:HasHeroic(src) then state.heroic = false end
    state.selected = nil
    AtlasUI:RefreshSources()
    AtlasUI:RefreshPages()
    AtlasUI:RefreshItems(true)
end

-- Opens the page of a search result (or any location from Atlas:GetLocations) and highlights the item.
function AtlasUI:GoTo(loc)
    if type(loc) ~= "table" or not (loc.cat and loc.src and loc.page) then return end
    state.search = ""
    if searchBox and (searchBox:GetText() or "") ~= "" then
        searchBox:SetText("")
        searchBox:ClearFocus()
    end
    state.heroic = loc.heroic and true or false
    SelectSource(loc.cat.key, loc.src.key, loc.page.key)
    state.selected = loc.id
    self:RefreshItems(true)
    -- scroll the item into view (a piece of another class or spec isn't listed: its token is)
    local data = itemList and itemList:GetData() or {}
    local shown = false
    for _, r in ipairs(data) do
        if r.type == "item" and r.id == loc.id then shown = true break end
    end
    if not shown and loc.via then
        state.selected = loc.via
        itemList:Refresh()
    end
    for i, r in ipairs(data) do
        if r.type == "item" and r.id == state.selected then
            if itemList.box and itemList.box.ScrollToElementDataIndex then
                itemList.box:ScrollToElementDataIndex(i, ScrollBoxConstants and ScrollBoxConstants.AlignCenter)
            end
            break
        end
    end
end

-- Opens the Atlas tab at an item (e.g. from a chat command): its first location.
function AtlasUI:ShowItem(itemID)
    local locs = Atlas():GetLocations(itemID)
    if not locs then return false end
    if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("atlas") end
    self:GoTo(locs[1])
    return true
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function CreateColumnLine(parent, anchor)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetWidth(1)
    t:SetColorTexture(1, 1, 1, 0.08)
    t:SetPoint("TOPLEFT", anchor, "TOPRIGHT", COL_GAP / 2, 0)
    t:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", COL_GAP / 2, 0)
    return t
end

function AtlasUI:CreatePanel(parent)
    if panel then return panel end
    local UI = ns.UI
    panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints(parent)

    -- top bar: search, filters
    searchBox = UI:CreateSearchBox(panel, 300, function(text)
        state.search = text or ""
        state.selected = nil
        state.facet = nil
        AtlasUI:RefreshSources()
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end, "Search every item by name")
    searchBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    slotDD = UI:CreateSleekDropdown(panel, 130, SlotOptions, function() return state.slot end, function(v)
        state.slot = v
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end)
    slotDD:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -8)

    showDD = UI:CreateSleekDropdown(panel, 170, function() return Atlas():GetShowOptions() end, ShowMode, function(v)
        SetShowMode(v)
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end)
    showDD:SetPoint("RIGHT", slotDD, "LEFT", -8, 0)
    local showLabel = UI:CreateLabel(panel, "Show", "GameFontDisableSmall")
    showLabel:SetPoint("RIGHT", showDD, "LEFT", -6, 0)

    -- columns
    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -TOP_H - 6)
    body:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 22)

    local left = CreateFrame("Frame", nil, body)
    left:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    left:SetWidth(LEFT_W)
    panel.left = left

    local mid = CreateFrame("Frame", nil, body)
    mid:SetPoint("TOPLEFT", left, "TOPRIGHT", COL_GAP, 0)
    mid:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT", COL_GAP, 0)
    mid:SetWidth(MID_W)
    panel.mid = mid

    local right = CreateFrame("Frame", nil, body)
    right:SetPoint("TOPLEFT", mid, "TOPRIGHT", COL_GAP, 0)
    right:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    panel.right = right

    CreateColumnLine(body, left)
    CreateColumnLine(body, mid)

    srcList = UI:CreateScrollList(left, ROW_SRC, InitSourceRow, SourceExtent)
    srcList.frame:SetAllPoints(left)

    srcTitle = UI:CreateLabel(mid, "", "GameFontNormal")
    srcTitle:SetPoint("TOPLEFT", mid, "TOPLEFT", 4, -2)
    srcTitle:SetPoint("RIGHT", mid, "RIGHT", -4, 0)
    srcTitle:SetWordWrap(true)
    srcSub = UI:CreateLabel(mid, "", "GameFontDisableSmall")
    srcSub:SetPoint("TOPLEFT", srcTitle, "BOTTOMLEFT", 0, -3)
    srcSub:SetPoint("RIGHT", mid, "RIGHT", -4, 0)

    diffNormal = UI:CreateUnderlineTab(mid, "Normal", function()
        state.heroic = false
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end, "small")
    diffNormal:SetPoint("TOPLEFT", srcSub, "BOTTOMLEFT", -4, -6)
    diffHeroic = UI:CreateUnderlineTab(mid, "Heroic", function()
        state.heroic = true
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end, "small")
    diffHeroic:SetPoint("LEFT", diffNormal, "RIGHT", 4, 0)

    pageList = UI:CreateScrollList(mid, ROW_PAGE, InitPageRow, PageExtent)
    pageList.frame:SetPoint("TOPLEFT", srcSub, "BOTTOMLEFT", 0, -8)
    pageList.frame:SetPoint("BOTTOMRIGHT", mid, "BOTTOMRIGHT", 0, 0)

    itemTitle = UI:CreateLabel(right, "", "GameFontNormal")
    itemTitle:SetPoint("TOPLEFT", right, "TOPLEFT", 4, -2)
    itemTitle:SetPoint("RIGHT", right, "RIGHT", -90, 0)
    itemTitle:SetWordWrap(false)
    itemSub = UI:CreateLabel(right, "", "GameFontDisableSmall")
    itemSub:SetPoint("RIGHT", right, "RIGHT", -24, 0)
    itemSub:SetPoint("TOP", itemTitle, "TOP", 0, 0)
    itemSub:SetJustifyH("RIGHT")

    itemList = UI:CreateScrollList(right, ROW_ITEM, InitItemRow, ItemExtent)
    itemList.frame:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -22)
    itemList.frame:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)

    footer = UI:CreateLabel(panel, FOOTER_TEXT, "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 5)
    footer:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 5)
    footer:SetJustifyH("CENTER")

    panel:SetScript("OnShow", function(self)
        if self.dirty then AtlasUI:Refresh() end
    end)
    panel.OnPanelShown = function(self)
        if self.dirty then AtlasUI:Refresh() end
    end
    panel.dirty = true
    return panel
end

-- For tests and the UI audit.
function AtlasUI:GetState()
    return state
end

function AtlasUI:SetSearch(text, facet)
    if searchBox then searchBox:SetText(text or "") end
    state.search = text or ""
    state.selected = nil
    state.facet = facet
    self:RefreshSources()
    self:RefreshPages()
    self:RefreshItems(true)
end

function AtlasUI:Select(catKey, srcKey, pageKey, heroic)
    if heroic ~= nil then state.heroic = heroic and true or false end
    if searchBox and (searchBox:GetText() or "") ~= "" then searchBox:SetText("") end
    state.search = ""
    SelectSource(catKey, srcKey, pageKey)
end

function AtlasUI:SetSlotFilter(sid)
    state.slot = sid
    if slotDD and slotDD.Refresh then slotDD:Refresh() end
    self:RefreshPages()
    self:RefreshItems(true)
end

function AtlasUI:GetLists()
    return srcList, pageList, itemList
end

-- Opens the item menu of a row's data (tests).
function AtlasUI:OpenMenu(d, owner)
    ShowItemMenu(owner or panel, d)
end

---------------------------------------------------------------------------
-- Registration & messages
---------------------------------------------------------------------------

if ns.MainFrame and ns.MainFrame.RegisterTab then
    ns.MainFrame:RegisterTab("atlas", "Atlas", 1.5, function(parent) return AtlasUI:CreatePanel(parent) end)
end

local function RequestItems()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    Debounce("atlas-items", 0.05, function() AtlasUI:RefreshItems() end)
end

local function RefreshVisibleRows()
    if not (panel and panel:IsVisible() and itemList) then return end
    local mode = ShowMode()
    if mode == "spec" or mode == "os" then
        -- items the spec filter couldn't judge yet (not loaded) may drop out now
        searchCache = nil
        Debounce("atlas-items", 0.1, function()
            if IsSearching() then AtlasUI:RefreshPages() end
            AtlasUI:RefreshItems()
        end)
    else
        itemList:Refresh()
    end
end

ns:On("MYLIST_CHANGED", RequestItems)
ns:On("OWNED_UPDATED", RequestItems)
ns:On("LISTS_RESET", RequestItems)
ns:On("LIST_UPDATED", function()
    if IsCouncil() then RequestItems() end
end)
ns:On("CONFIG_UPDATED", RequestItems)
ns:On("ITEMINFO_READY", RefreshVisibleRows)
