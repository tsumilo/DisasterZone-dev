if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Atlas.lua", ...) then return end -- DisasterZone UI/Atlas.lua
-- ns.AtlasUI: the Atlas tab, a loot browser for every member (no guild or raid needed). Three columns: the sources
-- (categories that fold open: Raids, Dungeons, Crafting, Reputation, PvP, Badges & Sunmote, Collections, World
-- Events, Sets; a later phase's tag beside a source), the chosen source (a raid's or dungeon's loading screen as a
-- banner, else a title row) over its pages (bosses, sub-lists, standings, each with a star count of my BiS picks
-- there), and the page's items with their icons. No rules between rows: type, colour and whitespace do the grouping.
-- One search box finds any item by name (or number) across everything; the middle column then says where the matches
-- are from ("Found in") and a click on a result opens its page.
-- Items: hover = tooltip and a + button that adds the item to my BiS list (phase, best / alt, the slot for rings /
-- trinkets / one-handers, "and later phases"); right-click = the same choices plus try on and link; shift-click =
-- link, ctrl-click = dressing room. Marks: on my list (best / alt / off spec, with the phases), owned, and for the
-- Loot Council how many members want it. An item a vendor sells shows its cost with the currencies' icons, each
-- amount red while I hold less (the vendor window's rule); a set page says what the pieces I don't own cost.
-- The currency bar along the bottom: Honor, Arena Points and Badges of Justice always, then what the list shown pays
-- with; hovering an item lights its currencies there with how many I lack or keep (model: Core/Currency.lua).
-- One spacing grid: PAD at the page's sides, GAP between the columns, IN inside rows and cards. The item list's scroll
-- bar sits in the page's right margin, the sources' over their right padding, the pages' takes room while they scroll.
-- Model: Core/Atlas.lua (ns.Atlas).
-- 1.4: a List + detail page in its 3-column form (UI:CreateLayout "listdetail" with a nav column): the toolbar holds
-- the search (left) and the Show / slot filters (right); nav = the sources, list = the source's pages, detail = the
-- items; the currency bar sits in the layout's bottom margin. While my lists are locked a notice says so (the +
-- buttons are gone, as before).
local addonName, ns = ...

local AtlasUI = {}
ns.AtlasUI = AtlasUI

local S = ns.Style
local GearUI = ns.GearUI          -- (UI/PaperDoll.lua: the helpers the Gear pages share)

local ipairs, pairs, type, tonumber, tostring = ipairs, pairs, type, tonumber, tostring
local floor, ceil, max = math.floor, math.ceil, math.max

local PAD, GAP, IN = S.PAD, S.GAP, S.IN
local CTRL_H = 22                                 -- the search / filter row (on the toolbar's row)
local COLS_Y = ns.UI.LAYOUT.TOP                   -- where the three columns start (under the toolbar)
local LEFT_W, MID_W = 180, 182
local RIGHT_W = S.INNER_W - LEFT_W - MID_W - 2 * GAP   -- 392: sizes before the first layout (fixed window)
local BAR_H = 30                                  -- the currency bar along the bottom
local BOTTOM = PAD + BAR_H + GAP                  -- the layout's bottom margin: the currency bar's place
local BODY_H = S.PAGE_H - COLS_Y - BOTTOM         -- 464
local SLOT_W = 148                                -- the slot filter; Show takes the rest of the item column
local BANNER_H, ART_FW = S.BANNER.tool, 0.95      -- the detail's banner (D3); the share of a loading screen it shows
local HEAD_H = 24                                 -- the pages column's section header (UI:CreateSectionHeader "title")
local TABS_H = 18                                 -- Normal / Heroic under a dungeon's banner
local ROW_CAT, ROW_SRC, ROW_PAGE, ROW_TWO = 26, 23, 22, 34
local ROW_ITEM, ROW_SECTION, ROW_MORE = 34, 28, 36
local ICON, ICON_REWARD = 26, 22
local NAME_LH, SUB_LH = 14, 12                    -- line heights of an item's name (12) and its second line (10)
local SRC_X = IN + 10                             -- a source's indent under its category
local SRC_R = 12                                  -- the sources' right padding (their scroll bar lies over it)
local TAG_W, COUNT_W = 18, 28                     -- the phase tag (left column), the star count (middle column)
local BAR_SPACE = 10                              -- a scroll bar inside its column: 6 wide, 4 from the rows
local PLUS = 22                                   -- the hover button that adds an item to my BiS list
local MAX_SHOWN = 300                             -- search results drawn at most (Found in narrows them down)
local DOT = "  ·  "
local SHOP = "shop"                               -- state.cat of the shopping list (UI/AtlasShop.lua)
local CLASS_WEAPON, CLASS_ARMOR = 2, 4            -- Enum.ItemClass
local CARD_BG = S.C.CARD
local ROW_TEXT = S.C.TEXT
local GOLD_HEX = S:Hex("GOLD")

-- English names of a weapon / armor subclass, one item's worth ("Main Hand · Dagger", not "Daggers").
local WEAPON_KIND = { [0] = "Axe", [1] = "Axe", [2] = "Bow", [3] = "Gun", [4] = "Mace", [5] = "Mace", [6] = "Polearm",
                      [7] = "Sword", [8] = "Sword", [10] = "Staff", [13] = "Fist Weapon", [15] = "Dagger",
                      [16] = "Thrown", [18] = "Crossbow", [19] = "Wand", [20] = "Fishing Pole" }
local ARMOR_KIND = { [6] = "Shield", [7] = "Libram", [8] = "Idol", [9] = "Totem" }

local panel, layout, searchBox, showDD, slotDD, srcList, pageList, itemList
local banner, midHead, diffNormal, diffHeroic, curBar
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
local pickCache = {}     -- [heroic and 2 or 1][page] = my BiS picks on that page
local wantCache = {}     -- [itemID] = number of members who want it (council only; per refresh)
local layCache = {}      -- [row data] = its layout (per refresh of the item list)
local listLocked = false -- my BiS lists are locked (no + buttons)
local rowW = { src = LEFT_W, page = MID_W, item = RIGHT_W }   -- the rows' widths (less while a list scrolls)
local SelectSource, ShowItemMenu, ShowAddMenu, SearchResults, AddToShop, ShopButtonTooltip   -- forward declarations

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
    local p = GearUI.GuildPhase()
    if p and p >= 1 and p <= (ns.MAX_PHASE or 5) then return p end
    return nil
end

local SlotLabel = ns.SlotLabel

local function Colorize(text, key)
    return ns.UI:Colorize(text, ns.COLORS and ns.COLORS[key])
end

local function IsSearching()
    local A = Atlas()
    return A and #(state.search or "") > 0 and (tonumber(state.search) ~= nil or #state.search >= A.MIN_SEARCH)
end

local function English()
    local loc = GetLocale and GetLocale()
    return loc == nil or loc == "enUS" or loc == "enGB"
end

-- "Shoulder  ·  Leather", "Two-Hand  ·  Mace", "Recipe", "Mount" ... (instant info: never waits for the server).
local function TypeLine(id)
    if id < 0 then
        -- a craft listed as its spell: an enchant, or (when its page lists what it makes already, a transmute) the
        -- type of what it makes
        local craft = Atlas():GetCraft(id)
        if not (craft and craft.item > 0) then return "Enchant" end
        id = craft.item
    end
    if not (C_Item and C_Item.GetItemInfoInstant) then return "" end
    local _, itemType, subType, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(id)
    local slotText = (equipLoc and equipLoc ~= "" and type(_G[equipLoc]) == "string") and _G[equipLoc] or nil
    if slotText then
        local kind
        if classID == CLASS_WEAPON then
            kind = (English() and WEAPON_KIND[subclassID]) or subType
        elseif classID == CLASS_ARMOR and equipLoc ~= "INVTYPE_CLOAK" and subclassID and subclassID >= 1 then
            kind = (English() and ARMOR_KIND[subclassID]) or subType
        end
        if type(kind) == "string" and kind ~= "" and kind ~= slotText then return slotText .. DOT .. kind end
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
        return GOLD_HEX .. (A:GetName(id) or ("Spell " .. -id)) .. "|r"
    end
    local name, _, quality = ns.ItemDB:GetInfo(id)
    if name then
        return "|c" .. ns.UI:ColorHex(ns.UI:QualityColor(quality)) .. name .. "|r"
    end
    return S:Wrap("SUB", A:GetShippedName(id) or "Loading...")
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

local function RefreshMarks()
    marks = Atlas():GetMyListMarks()
    pickCache = {}
end

---------------------------------------------------------------------------
-- Text: styles and widths (every text is drawn and measured in a ns.Style text style: UI:Text / UI:TextWidth)
---------------------------------------------------------------------------

-- Width of a text in a style: rows whose text needs more get two lines instead of cutting a name off.
local function TextWidth(text, style)
    return ns.UI:TextWidth(text or "", style) + 1
end

-- The same for a text with colour codes and |T icons (an icon is as wide as the line is high).
local function CodedWidth(text, style)
    local icons = 0
    local s = tostring(text or ""):gsub("|T.-|t", function()
        icons = icons + 1
        return ""
    end)
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return TextWidth(s, style) + icons * (S:Size(style) + 2)
end

local function StarText(size)
    return "|T" .. ns.UI:Tex("star") .. ":" .. size .. ":" .. size .. "|t"
end

-- A category's chevron: the atlas chevron pointing down (open) or right (UI:SetChevron).
local function SetChevron(tex, down)
    if down then
        tex:SetTexture(ns.UI.ICON_ATLAS)
        tex:SetTexCoord(unpack(ns.UI:IconCoords(ns.UI.ICON.chevron)))
    else
        ns.UI:SetChevron(tex, true)
    end
end

-- A colour fading from `bottom` (alpha at the foot) to `top` (UI:Gradient, vertical).
local function Fade(tex, r, g, b, bottom, top)
    ns.UI:Gradient(tex, "VERTICAL", { r, g, b, bottom }, { r, g, b, top })
end

---------------------------------------------------------------------------
-- Costs and the currency bar
---------------------------------------------------------------------------

local CHIP_ICON, CHIP_GAP, MAX_CONTEXT = 16, 1, 4
local CHIP_FONT, CHIP_STYLE = 12, "emph"
local RED_HEX, GREEN_HEX, YELLOW_HEX = S:Hex("BAD"), S:Hex("OK"), S:Hex("GOLD")
local barKeys = {}       -- the bar's currencies after the pinned ones: what the list shown pays with
local hoverRow           -- the item row whose cost the bar shows

local function Cur() return ns.Currency end

-- An item's cost: parts ({ { key, n }, ... }), where it comes from; nil when no vendor price is known.
local function CostOf(id)
    local C = Cur()
    if not (C and type(id) == "number" and id > 0) then return nil end
    return C:GetCost(id)
end

-- "1,875 Arena Points" / "12g 50s" (an amount with the currency's name; money says itself).
local function AmountName(C, key, n)
    if key == C.MONEY then return C:AmountText(key, n, 12) end
    return C:AmountText(key, n, 12) .. " " .. C:Name(key)
end

-- The tooltip's cost block: each currency with what I lack, or what I have.
local function AddCostLines(tt, parts, from)
    local C = Cur()
    tt:AddLine(" ")
    tt:AddLine("Cost", S:Color("GOLD"))
    for _, c in ipairs((C:Check(parts))) do
        local left = (c.key == C.MONEY and "" or (C:IconMarkup(c.key, 14) .. " ")) .. AmountName(C, c.key, c.n)
        local right
        if c.short > 0 then
            right = RED_HEX .. C:AmountText(c.key, c.short, 12) .. " more needed|r"
        else
            local _, bags = C:Have(c.key)
            right = bags < c.n and (YELLOW_HEX .. "Some is in your bank|r")
                or (GREEN_HEX .. "You have " .. C:AmountText(c.key, c.have, 12) .. "|r")
        end
        tt:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1)
    end
    if from == "season" then
        tt:AddLine("The price of this season's other pieces for this slot.", 0.6, 0.6, 0.6, true)
    end
end

local function ChipTooltip(chip, tt)
    local C, key = Cur(), chip.key
    if not (C and key) then return false end
    tt:AddLine((key == C.MONEY and "" or (C:IconMarkup(key, 14) .. " ")) .. C:Name(key), S:Color("GOLD"))
    local total, bags = C:Have(key)
    tt:AddDoubleLine("You have", C:AmountText(key, total, 12), 0.8, 0.8, 0.8, 1, 1, 1)
    if total > bags then
        tt:AddDoubleLine("Of that in your bank", C:AmountText(key, total - bags, 12), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    local most = C:Max(key)
    if most then tt:AddDoubleLine("The most you can hold", C:Number(most), 0.8, 0.8, 0.8, 1, 1, 1) end
end

-- One currency on the bar: its icon in a slot frame, the amount, lit by a hovered item's cost.
-- TODO(refactor): move into a currency strip component (UI:CreateCurrencyBar: chips that light up with a cost) - no
-- shared component draws an amount strip; UI:CreateChip is a toggle chip.
local function CreateChip(parent)
    local chip = CreateFrame("Button", nil, parent)
    chip:SetHeight(BAR_H - 6)
    -- a cost lights the chip: a faint wash fading up and an underline in its colour
    chip.bg = chip:CreateTexture(nil, "BACKGROUND")
    chip.bg:SetAllPoints()
    chip.bg:SetColorTexture(1, 1, 1, 0)
    chip.line = chip:CreateTexture(nil, "BORDER")
    chip.line:SetPoint("BOTTOMLEFT", chip, "BOTTOMLEFT", 6, 0)
    chip.line:SetPoint("BOTTOMRIGHT", chip, "BOTTOMRIGHT", -6, 0)
    chip.line:SetHeight(2)
    chip.line:Hide()
    local hl = chip:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    local wr, wg, wb = S:Color("HOVER")      -- (white: a lift that fades up)
    Fade(hl, wr, wg, wb, 0.06, 0)
    -- the icon in a thin dark frame, like an item slot
    chip.frame = chip:CreateTexture(nil, "BORDER")
    chip.frame:SetSize(CHIP_ICON + 2, CHIP_ICON + 2)
    chip.frame:SetPoint("LEFT", chip, "LEFT", 7, 0)
    chip.frame:SetColorTexture(0, 0, 0, 0.7)
    chip.icon = chip:CreateTexture(nil, "ARTWORK")
    chip.icon:SetSize(CHIP_ICON, CHIP_ICON)
    chip.icon:SetPoint("CENTER", chip.frame, "CENTER", 0, 0)
    chip.amount = ns.UI:Text(chip, CHIP_STYLE, { 0.93, 0.9, 0.82 })
    chip.amount:SetPoint("LEFT", chip.frame, "RIGHT", 6, 0)
    -- a faint rule on the chip's right: the gap to the next one
    chip.sep = chip:CreateTexture(nil, "ARTWORK")
    chip.sep:SetSize(1, BAR_H - 14)
    chip.sep:SetPoint("LEFT", chip, "RIGHT", 0, 0)
    chip.sep:SetColorTexture(S:Color("HAIRLINE"))
    ns.UI:AttachTooltip(chip, ChipTooltip, nil, { anchor = "ANCHOR_TOP" })
    return chip
end

-- Lights the chips of a cost (red: I lack some, green: enough); nil clears it. The tooltip says the amounts.
local function BarShowCost(d)
    if not curBar then return end
    local C = Cur()
    local parts = C and d and d.type == "item" and CostOf(d.id)
    local checks = parts and C:Check(parts)
    local byKey = {}
    for _, c in ipairs(checks or {}) do byKey[c.key] = c end
    for _, chip in ipairs(curBar.chips) do
        local c = chip:IsShown() and byKey[chip.key]
        chip.state = c and (c.short > 0 and "short" or "ok") or nil
        if not c then
            chip.bg:SetColorTexture(1, 1, 1, 0)
            chip.line:Hide()
        else
            local r, g, b = S:Color(c.short > 0 and "BAD" or "OK")
            Fade(chip.bg, r, g, b, 0.16, 0)
            chip.line:SetColorTexture(r, g, b, 0.85)
            chip.line:Show()
        end
    end
end

-- The bar: Honor, Arena Points and Badges always, a rule, then what the list shown pays with (most used first).
local function LayoutBar()
    if not curBar then return end
    local C = Cur()
    curBar:SetShown(C ~= nil)
    if not C then return end
    local keys = {}
    for _, k in ipairs(C.PINNED) do keys[#keys + 1] = k end
    local pinned = #keys
    for _, k in ipairs(barKeys) do keys[#keys + 1] = k end
    local x = 2
    curBar.rule:Hide()
    for i, key in ipairs(keys) do
        local chip = curBar.chips[i] or CreateChip(curBar)
        curBar.chips[i] = chip
        chip.key = key
        local tex, l, r, t, b = C:Icon(key)
        chip.icon:SetTexture(tex)
        -- money says itself with its coins: no icon in front
        local money = key == C.MONEY
        chip.icon:SetShown(not money)
        chip.frame:SetShown(not money)
        chip.amount:ClearAllPoints()
        if money then
            chip.amount:SetPoint("LEFT", chip, "LEFT", 8, 0)
        else
            chip.amount:SetPoint("LEFT", chip.frame, "RIGHT", 6, 0)
        end
        if l then
            chip.icon:SetTexCoord(l, r, t, b)
        elseif key:match("^%d+$") then
            chip.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- an item's icon: without its border
        else
            chip.icon:SetTexCoord(0, 1, 0, 1)
        end
        local have = C:Have(key)
        local text = C:AmountText(key, have, CHIP_FONT)
        chip.amount:SetText(text)
        if i == pinned + 1 then
            curBar.rule:ClearAllPoints()
            curBar.rule:SetPoint("LEFT", curBar, "LEFT", x + 4, 0)
            curBar.rule:Show()
            x = x + 10
        end
        -- the rule between pinned and context currencies stands in for the chip's own
        chip.sep:SetShown(i ~= pinned and i ~= #keys)
        local w = (money and 8 or (7 + CHIP_ICON + 2 + 6)) + ceil(CodedWidth(text, CHIP_STYLE)) + 12
        chip:ClearAllPoints()
        chip:SetPoint("LEFT", curBar, "LEFT", x, 0)
        chip:SetWidth(w)
        chip:Show()
        x = x + w + CHIP_GAP
    end
    for i = #keys + 1, #curBar.chips do curBar.chips[i]:Hide() end
    BarShowCost(hoverRow and hoverRow:IsShown() and hoverRow.__cdlData or nil)
end

-- What the rows pay with besides the pinned currencies, most used first (at most MAX_CONTEXT).
local function ContextKeys(rows)
    local C = Cur()
    if not C then return {} end
    local pinned, count, order = {}, {}, {}
    for _, k in ipairs(C.PINNED) do pinned[k] = true end
    for _, r in ipairs(rows) do
        local parts = r.type == "item" and CostOf(r.id)
        for _, p in ipairs(parts or {}) do
            if not pinned[p.key] then
                if not count[p.key] then order[#order + 1] = p.key end
                count[p.key] = (count[p.key] or 0) + 1
            end
        end
    end
    table.sort(order, function(a, b)
        if count[a] ~= count[b] then return count[a] > count[b] end
        return a < b
    end)
    local out = {}
    for i = 1, math.min(#order, MAX_CONTEXT) do out[i] = order[i] end
    return out
end

-- What a set's pieces I don't own cost together: (full text, the amounts alone), e.g. ("Set 8,250 [A]", "8,250 [A]")
-- or ("Still to buy 4,500 [A]", ...); nil unless every piece has a price and one is still to buy.
local function SetTotal(items)
    local C = Cur()
    if not C or #items == 0 then return nil end
    local sum, order, owned = {}, {}, 0
    for _, id in ipairs(items) do
        local parts = CostOf(id)
        if not parts then return nil end
        if ns.BiS and ns.BiS.IsObtained and ns.BiS:IsObtained(id) then
            owned = owned + 1
        else
            for _, p in ipairs(parts) do
                if not sum[p.key] then order[#order + 1] = p.key end
                sum[p.key] = (sum[p.key] or 0) + p.n
            end
        end
    end
    if #order == 0 then return nil end
    local parts = {}
    for i, k in ipairs(order) do parts[i] = { key = k, n = sum[k] } end
    local amounts = C:CostText(parts, 12)
    return S:Wrap("SUB", owned > 0 and "Still to buy" or "Set") .. "  " .. amounts, amounts
end

-- A set page (one class's sets, a header per set): each header gets its set's total (row.cost / row.costShort);
-- returns the page's total when it has no headers (one set: its note in the column's title row).
local function SetTotals(rows)
    local header, items, pageItems = nil, {}, {}
    local function close()
        if header then header.cost, header.costShort = SetTotal(items) end
    end
    for _, r in ipairs(rows) do
        if r.type == "header" then
            close()
            header, items = r, {}
        elseif r.type == "item" and not r.via and r.id > 0 then
            items[#items + 1] = r.id
            pageItems[#pageItems + 1] = r.id
        end
    end
    close()
    if header then return nil end
    return (SetTotal(pageItems))
end

-- TODO(refactor): move into the currency strip component (see CreateChip above).
local function CreateCurrencyBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(BAR_H)
    -- no box: a dark shade fading up into the panel under one hairline, gold in the middle and gone at the ends
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    Fade(bar.bg, CARD_BG[1] * 0.6, CARD_BG[2] * 0.6, CARD_BG[3] * 0.6, 0.85, 0.35)
    local function hairline(l, r, a0, a1)
        local t = bar:CreateTexture(nil, "BORDER")
        t:SetHeight(1)
        t:SetPoint("TOPLEFT", bar, l, 0, 0)
        t:SetPoint("TOPRIGHT", bar, r, 0, 0)
        ns.UI:Gradient(t, "HORIZONTAL", { 1, 0.82, 0.35, a0 }, { 1, 0.82, 0.35, a1 })
    end
    hairline("TOPLEFT", "TOP", 0, 0.35)
    hairline("TOP", "TOPRIGHT", 0.35, 0)
    bar.rule = bar:CreateTexture(nil, "ARTWORK")
    bar.rule:SetSize(1, BAR_H - 10)
    bar.rule:SetColorTexture(1, 0.82, 0.35, 0.3)
    bar.chips = {}
    return bar
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

-- My BiS picks on a page (the list shown: normal or heroic): an entry counts once, also when it is a token or a
-- recipe whose piece / product is the pick. The slot filter narrows it like the page list.
local function PickCount(page)
    local which = state.heroic and 2 or 1
    pickCache[which] = pickCache[which] or {}
    local n = pickCache[which][page]
    if n then return n end
    n = 0
    local A = Atlas()
    for _, e in ipairs(A:GetPageEntries(page, state.heroic)) do
        if type(e) == "number" and PassesSlot(e) then
            local hit = marks[e] ~= nil
            if not hit and e > 0 then
                for _, r in ipairs(A:GetRewards(e)) do
                    if marks[r.id] then
                        hit = true
                        break
                    end
                end
            end
            if hit then n = n + 1 end
        end
    end
    pickCache[which][page] = n
    return n
end

-- Can the + button add this item to my list (something that fits a slot, my class can use it, lists not locked)?
local function CanAdd(id)
    if id <= 0 or listLocked then return false end
    local A = Atlas()
    local targets = A:GetBiSTargets(id)
    if #targets == 0 then return false end
    for _, t in ipairs(targets) do
        if A:IsUsableByMe(t.itemID) == false then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Left and middle columns: sources, pages, search facets
---------------------------------------------------------------------------

local function SetupListRow(row)
    row.cdl = true
    ns.UI:DecorateRow(row, { selectable = true })   -- (hover, and the picked look: row:SetSelected)
    row.chev = row:CreateTexture(nil, "ARTWORK")
    row.chev:SetSize(10, 10)
    row.chev:SetPoint("RIGHT", row, "RIGHT", -IN, 0)
    row.chev:SetTexture(ns.UI.ICON_ATLAS)
    row.chev:SetVertexColor(0.55, 0.55, 0.58)
    row.label = ns.UI:Text(row, "body", "TEXT")
    if row.label.SetMaxLines then row.label:SetMaxLines(2) end
    row.tag = ns.UI:Text(row, "small", "DIM", { justify = "RIGHT" })
    row.tag:SetPoint("RIGHT", row, "RIGHT", -IN, 0)
    row:RegisterForClicks("LeftButtonUp")
end

local function SetRowSelected(row, on)
    row:SetSelected(on)
    if on then
        row.label:SetTextColor(1, 1, 1)
    else
        row.label:SetTextColor(ROW_TEXT[1], ROW_TEXT[2], ROW_TEXT[3])
    end
end

-- "P2" .. "P5" beside a source of a later phase (what has been out from the start goes without).
local function PhaseTag(src)
    local p = tonumber(src and src.phase)
    return (p and p > 1) and ("P" .. p) or nil
end

local function ClearSearch()
    if searchBox and (searchBox:GetText() or "") ~= "" then searchBox:SetText("") end
    state.search = ""
end

-- The shopping list at the top of the left column: a bag, its name like a category's, how many crafts are on it
-- (quiet while it's empty).
local function InitShopRow(row)
    if not row.bag then
        row.bag = row:CreateTexture(nil, "ARTWORK")
        row.bag:SetSize(14, 14)
        row.bag:SetPoint("LEFT", row, "LEFT", IN, 0)
        row.bag:SetTexture(ns.UI.ICON_ATLAS)
        row.bag:SetTexCoord(unpack(ns.UI:IconCoords(ns.UI.ICON.bag)))
    end
    local n = ns.Shop and ns.Shop:Count() or 0
    local on = not IsSearching() and state.cat == SHOP
    row.bag:Show()
    row.chev:Hide()
    ns.UI:SetTextStyle(row.label, "emph", "GOLD")
    row.label:SetWordWrap(false)
    row.label:SetPoint("LEFT", row, "LEFT", IN + 20, 0)
    row.label:SetWidth(rowW.src - IN - 20 - SRC_R - TAG_W)
    row.label:SetText("Shopping list")
    row.tag:ClearAllPoints()
    row.tag:SetPoint("RIGHT", row, "RIGHT", -SRC_R, 0)
    row.tag:SetWidth(TAG_W + 6)
    row.tag:SetText(n > 0 and ("|cffcfcfcf" .. n .. "|r") or "")
    row:SetSelected(on)
    if n > 0 or on then
        row.label:SetTextColor(S:Color("GOLD"))
        row.bag:SetVertexColor(on and 1 or 0.9, on and 0.82 or 0.9, on and 0 or 0.9)
    else
        row.label:SetTextColor(0.55, 0.55, 0.58)
        row.bag:SetVertexColor(0.55, 0.55, 0.58)
    end
    row:SetScript("OnClick", function()
        ClearSearch()
        AtlasUI:OpenShop()
    end)
end

local function InitSourceRow(row, d)
    if not row.cdl then SetupListRow(row) end
    local w = rowW.src
    local cat = d.type == "cat"
    row.label:ClearAllPoints()
    if row.bag then row.bag:Hide() end
    if d.type == "shop" then return InitShopRow(row) end
    row.chev:SetShown(cat)
    row.chev:ClearAllPoints()
    row.chev:SetPoint("RIGHT", row, "RIGHT", -SRC_R, 0)
    row.tag:ClearAllPoints()
    row.tag:SetPoint("RIGHT", row, "RIGHT", -SRC_R, 0)
    if cat then
        ns.UI:SetTextStyle(row.label, "emph", "GOLD")
        row.label:SetWordWrap(false)
        row.label:SetPoint("LEFT", row, "LEFT", IN, 0)
        row.label:SetWidth(w - IN - SRC_R - 14)
        row.label:SetText(d.cat.name)
        SetChevron(row.chev, d.expanded)
        row.tag:SetText("")
        row:SetSelected(false)
    else
        ns.UI:SetTextStyle(row.label, "body", "TEXT")
        row.label:SetWordWrap(true)
        row.label:SetPoint("LEFT", row, "LEFT", SRC_X, 0)
        row.label:SetWidth(w - SRC_X - SRC_R - (PhaseTag(d.src) and TAG_W or 0))
        row.label:SetText(d.src.name)
        row.tag:SetWidth(TAG_W)
        row.tag:SetText(PhaseTag(d.src) or "")
        SetRowSelected(row, not IsSearching() and state.cat == d.cat.key and state.src == d.src.key)
    end
    row:SetScript("OnClick", function()
        if d.type == "cat" then
            state.expanded = (state.expanded ~= d.cat.key) and d.cat.key or nil
            AtlasUI:RefreshSources()
        else
            ClearSearch()
            SelectSource(d.cat.key, d.src.key)
        end
    end)
end

local function PageTooltip(row, tt)
    local d = row.__cdlData
    local n = d and d.type == "page" and PickCount(d.page) or 0
    if n <= 0 then return false end
    tt:AddLine(d.page.name or "?", S:Color("GOLD"))
    tt:AddLine(n == 1 and "1 item here is on your BiS list" or (n .. " items here are on your BiS list"), 1, 1, 1)
end

local function InitPageRow(row, d)
    if not row.cdl then
        SetupListRow(row)
        ns.UI:AttachTooltip(row, PageTooltip)
    end
    row.chev:Hide()
    ns.UI:SetTextStyle(row.label, "body", "TEXT")
    row.label:SetWordWrap(true)
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", row, "LEFT", IN, 0)
    row.label:SetWidth(rowW.page - 2 * IN - COUNT_W)
    row.tag:SetWidth(COUNT_W)
    if d.type == "facet" then
        -- search: where the results are from (All, Raids, PvP, ...) with their counts
        row.label:SetText(d.name)
        row.tag:SetText(tostring(d.count))
        SetRowSelected(row, state.facet == d.key)
        row:SetScript("OnClick", function()
            state.facet = d.key
            state.selected = nil
            AtlasUI:RefreshPages()
            AtlasUI:RefreshItems(true)
        end)
        return
    end
    row.label:SetText(d.page.name or "?")
    local n = PickCount(d.page)
    row.tag:SetText(n > 0 and (StarText(10) .. " " .. GOLD_HEX .. n .. "|r") or "")
    SetRowSelected(row, not IsSearching() and state.page == d.page.key)
    row:SetScript("OnClick", function()
        ClearSearch()
        state.page = d.page.key
        state.selected = nil
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end)
end

local function SourceExtent(d)
    if d.type == "cat" then return ROW_CAT end
    if d.type == "shop" then return ROW_CAT end
    local w = rowW.src - SRC_X - SRC_R - (PhaseTag(d.src) and TAG_W or 0)
    return TextWidth(d.src.name, "body") > w and ROW_TWO or ROW_SRC
end

local function PageExtent(d)
    local w = rowW.page - 2 * IN - COUNT_W
    return TextWidth(d.type == "facet" and d.name or d.page.name, "body") > w and ROW_TWO or ROW_PAGE
end

---------------------------------------------------------------------------
-- The item list
---------------------------------------------------------------------------

-- My marks on an item: on my list (best / alt / off spec with the phases), owned.
local function MarksText(id)
    local parts = {}
    local m = marks[id]
    if m then
        if m.main then
            parts[#parts + 1] = StarText(10) .. " " .. Colorize(Atlas():PhasesText(m.main), "main")
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

-- Puts a craft on my shopping list (UI/AtlasShop.lua: with the amount / breakdown set with Shift).
function AddToShop(id)
    if ns.AtlasShopUI then ns.AtlasShopUI:AddCraft(id) end
end

-- The bag button's tooltip: who can make the craft for me, what a click adds.
function ShopButtonTooltip(btn, row)
    local d = row.__cdlData
    if ns.AtlasShopUI and d and d.type == "item" then ns.AtlasShopUI:AddTooltip(btn, d.id) end
end

-- The bag on a craft row's right: on my shopping list, and how many.
local function ShopMark(id)
    local n = ns.Shop and ns.Shop:GetAmount(id)
    if not n then return "" end
    return ns.UI:AtlasIconText(ns.UI.ICON.bag, 10, { 0.85, 0.85, 0.85 }) .. " |cffd8d8d8" .. n .. "|r"
end

-- The right of an item row, at most two lines: the cost (icons, red while I hold less) / skill, my marks, the
-- council's "N want", my shopping list.
local function RightLines(d)
    local id = d.id
    local lines = {}
    local parts = CostOf(id)
    if parts then
        lines[#lines + 1] = Cur():CostText(parts, 12)
    elseif d.x then
        lines[#lines + 1] = "|cffe0e0e0" .. d.x .. "|r"
    end
    local mine = MarksText(id)
    local bag = ShopMark(id)
    if bag ~= "" then mine = mine ~= "" and (mine .. "  " .. bag) or bag end
    if mine ~= "" then lines[#lines + 1] = mine end
    if IsCouncil() and id > 0 then
        local n = Wanted(id)
        if n > 0 then
            local want = Colorize(n .. " want", "council")
            if #lines == 2 then lines[2] = lines[2] .. "  " .. want else lines[#lines + 1] = want end
        end
    end
    return lines
end

-- The second line: the slot and type, a token's classes, where a search result is from, how a reward row relates.
local function SubText(d)
    local id = d.id
    if d.loc and IsSearching() then return Atlas():LocationText(d.loc) or "" end
    local sub = (id > 0 and TokenLine(id)) or TypeLine(id) or ""
    local function lead(word) return sub ~= "" and (word .. DOT .. sub) or word end
    if d.viaKind == "upgrade" then
        sub = lead("Sunmote upgrade")
    elseif d.viaKind == "base" then
        sub = lead("Made from")
    elseif d.viaKind == "makes" then
        sub = lead("Makes")
    elseif d.setPage and id > 0 then
        -- a set piece: its slot and where it comes from ("Token · Prince Malchezaar", "Arena Season 2")
        local slotText = TypeLine(id):match("^(.-)  ·  ") or TypeLine(id)
        local from = ns.ItemDB and ns.ItemDB:GetSourceText(id, true)
        if from then sub = slotText .. DOT .. from end
    end
    return sub or ""
end

-- A row's layout (per refresh): icon, text width and lines, the right column, the + button, the height. A name or
-- second line that doesn't fit gets two lines (a taller row), never "...".
local function Layout(d)
    local lay = layCache[d]
    if lay then return lay end
    lay = {}
    layCache[d] = lay
    if d.type == "header" then
        -- a set's header: its total at the right (the amounts alone when the words don't fit), the name on two
        -- lines rather than cut
        local avail = rowW.item - 2 * IN
        local tw = TextWidth(d.text or "", "emph")
        lay.cost = d.cost
        local cw = d.cost and (ceil(CodedWidth(d.cost, "small")) + 12) or 0
        if cw > 0 and tw + cw > avail and d.costShort then
            lay.cost = d.costShort
            cw = ceil(CodedWidth(d.costShort, "small")) + 12
        end
        lay.costW = cw
        lay.headW = avail - cw
        lay.headLines = tw > lay.headW and 2 or 1
        lay.h = ROW_SECTION + (lay.headLines - 1) * 14
        return lay
    end
    if d.type ~= "item" then
        lay.h = d.type == "more" and ROW_MORE or ROW_SECTION
        return lay
    end
    local id = d.id
    lay.icon = d.via and ICON_REWARD or ICON
    lay.iconX = d.via and (IN + 24) or IN
    lay.textX = lay.iconX + lay.icon + 9
    lay.lines = RightLines(d)
    local rw = 0
    for _, l in ipairs(lay.lines) do rw = max(rw, CodedWidth(l, "small")) end
    lay.rightW = rw > 0 and (ceil(rw) + 2) or 0
    lay.canAdd = CanAdd(id)
    lay.canShop = ns.Shop ~= nil and ns.Shop:CanAdd(id)
    lay.textW = rowW.item - lay.textX - IN - (lay.canAdd and (PLUS + 8) or 0) - (lay.canShop and (PLUS + 6) or 0)
        - (rw > 0 and (lay.rightW + 10) or 0)
    lay.sub = SubText(d)
    lay.nameLines = CodedWidth(NameText(id), "emph") > lay.textW and 2 or 1
    lay.subLines = (lay.sub == "" and 0) or (TextWidth(lay.sub, "small") > lay.textW and 2) or 1
    lay.h = 8 + lay.nameLines * NAME_LH + max(lay.subLines, 1) * SUB_LH - (d.via and 2 or 0)
    return lay
end

local function ItemExtent(d)
    return Layout(d).h
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
        local parts, from = CostOf(id)
        if parts then
            AddCostLines(tt, parts, from)
        elseif d.x then
            tt:AddLine(" ")
            local gr, gg, gb = S:Color("GOLD")
            tt:AddLine(d.x, gr, gg, gb, true)
        end
        if d.loc then
            tt:AddLine(" ")
            tt:AddLine(Atlas():LocationText(d.loc) or "", 0.7, 0.7, 0.7, true)
        end
        -- a craft's materials (Shift held), then the hints
        local matsHint, stepHint
        if ns.Tooltip then matsHint, stepHint = ns.Tooltip:AddMaterials(tt, id) end
        local hints = {}
        -- (while the materials show, clicks break them down instead)
        local clicksTaken = matsHint ~= nil and IsShiftKeyDown()
        if id > 0 and #Atlas():GetBiSTargets(id) > 0 and not clicksTaken then
            hints[#hints + 1] = "Right-click: add to your BiS list"
        end
        if d.loc and IsSearching() and not clicksTaken then hints[#hints + 1] = "Click: open its page" end
        hints[#hints + 1] = matsHint
        hints[#hints + 1] = stepHint
        if #hints > 0 then tt:AddLine(" ") end
        for _, h in ipairs(hints) do tt:AddLine(h, 0.55, 0.8, 1) end
    end
    if id > 0 then
        local T = ns.Tooltip
        if T then T.noMats = true end   -- the materials go under the row's own lines (extra)
        ns.UI:SetItemTooltip(row, id, extra)
        if T then T.noMats = nil end
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

-- Hovering an item row shows its + button (when it can add to my BiS list) and its bag (a craft: add it to my
-- shopping list), and moves the marks left of them.
local function SetRowHover(row, on)
    local lay = row.lay
    local item = lay and lay.textX ~= nil
    row:SetHover(on and item or false)
    -- the currency bar shows the hovered item's cost (a row being drawn while another is hovered leaves it)
    if on and item then
        hoverRow = row
        BarShowCost(row.__cdlData)
    elseif hoverRow == row then
        hoverRow = nil
        BarShowCost(nil)
    end
    local plus = on and item and lay.canAdd or false
    local shop = on and item and lay.canShop or false
    row.plus:SetShown(plus)
    row.shop:SetShown(shop)
    row.shop:ClearAllPoints()
    row.shop:SetPoint("RIGHT", row, "RIGHT", plus and -(IN + PLUS + 6) or -IN, 0)
    local x = -IN - (plus and (PLUS + 8) or 0) - (shop and (PLUS + (plus and 6 or 8)) or 0)
    local two = item and #lay.lines > 1
    row.mark:ClearAllPoints()
    row.mark:SetPoint("RIGHT", row, "RIGHT", x, two and 7 or 0)
    row.mark2:ClearAllPoints()
    row.mark2:SetPoint("RIGHT", row, "RIGHT", x, -7)
end

local function SetupItemRow(row)
    local UI = ns.UI
    row.cdl = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- the shared row looks: hover (SetRowHover holds it while the + and bag buttons are under the cursor) and the
    -- picked look (a search result jumped to: row:SetSelected)
    UI:DecorateRow(row, { selectable = true })

    -- section headers (a set per spec) and the "showing the first ..." note
    row.header = UI:Text(row, "emph", "GOLD")
    row.header:SetPoint("LEFT", row, "LEFT", IN, 0)
    if row.header.SetMaxLines then row.header:SetMaxLines(2) end
    -- a set header's total, at the right on the name's last line
    row.headCost = UI:Text(row, "small", "TEXT", { justify = "RIGHT" })
    row.headCost:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -IN, 8)
    row.headCost:Hide()

    row.icon = UI:CreateItemButton(row, ICON)
    row.icon:EnableMouse(false)   -- the row handles hover and clicks
    -- the guide line from an item down to what it gives / comes from (the indented rows under it)
    row.guide = row:CreateTexture(nil, "ARTWORK")
    row.guide:SetWidth(2)
    local gr, gg, gb = S:Color("GOLD")
    row.guide:SetColorTexture(gr, gg, gb, 0.55)

    row.name = UI:Text(row, "emph", "TEXT")
    if row.name.SetMaxLines then row.name:SetMaxLines(2) end
    row.sub = UI:Text(row, "small", "SUB")
    if row.sub.SetMaxLines then row.sub:SetMaxLines(2) end
    -- the right: one or two lines (cost / skill, my marks, the council's count)
    row.mark = UI:Text(row, "small", "TEXT", { justify = "RIGHT" })
    row.mark2 = UI:Text(row, "small", "TEXT", { justify = "RIGHT" })

    -- the + (hover): add to my BiS list
    local plus = UI:CreateSleekButton(row, "", PLUS, PLUS, function(self) ShowAddMenu(self, row.__cdlData) end)
    plus:SetPoint("RIGHT", row, "RIGHT", -IN, 0)
    for i, size in ipairs({ { 10, 2 }, { 2, 10 } }) do
        local t = plus:CreateTexture(nil, "ARTWORK")
        t:SetSize(size[1], size[2])
        t:SetPoint("CENTER")
        t:SetColorTexture(0.92, 0.92, 0.92, 1)
        plus[i == 1 and "barH" or "barV"] = t
    end
    plus:SetScript("OnEnter", function() SetRowHover(row, true) end)
    plus:SetScript("OnLeave", function()
        if not row:IsMouseOver() then SetRowHover(row, false) end
    end)
    UI:AttachTooltip(plus, "Add to your BiS list", "Pick the phase, then best or alt.")
    plus:Hide()
    row.plus = plus

    -- the bag (hover, a craft): add it to my shopping list
    local shop = UI:CreateIconButton(row, PLUS, UI.ICON_ATLAS, UI:IconCoords(UI.ICON.bagAdd), function()
        local d = row.__cdlData
        if d and d.type == "item" then AddToShop(d.id) end
    end)
    shop:HookScript("OnEnter", function(self)
        SetRowHover(row, true)
        ShopButtonTooltip(self, row)
    end)
    shop:HookScript("OnLeave", function()
        GameTooltip:Hide()
        if not row:IsMouseOver() then SetRowHover(row, false) end
    end)
    shop:Hide()
    row.shop = shop

    row:SetScript("OnClick", OnItemClick)
    row:SetScript("OnEnter", function(self)
        SetRowHover(self, true)
        RowTooltip(self)
    end)
    row:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        -- the cursor went onto the + (still over the row): stay hovered
        if not (self.plus:IsShown() and self:IsMouseOver()) then SetRowHover(self, false) end
    end)
    -- Shift: a craft's materials; Shift + mouse wheel: how many to make; Shift + click / right-click: break down
    if ns.Tooltip and ns.Tooltip.CraftRow then ns.Tooltip:CraftRow(row, RowTooltip, true) end
end

local function InitItemRow(row, d)
    if not row.cdl then SetupItemRow(row) end
    local lay = Layout(d)
    row.lay = lay
    local item = d.type == "item"
    row.icon:SetShown(item)
    row.name:SetShown(item)
    row.sub:SetShown(item and lay.subLines > 0)
    row.mark:SetShown(item and #lay.lines > 0)
    row.mark2:SetShown(item and #lay.lines > 1)
    row.header:SetShown(not item)
    row.dzHover:SetShown(item)          -- (headers and notes take no hover)
    if not item then
        row.guide:Hide()
        row:SetSelected(false)
        SetRowHover(row, false)
        row.header:ClearAllPoints()
        if d.type == "more" then
            ns.UI:SetTextStyle(row.header, "small", "DIM")
            row.header:SetWordWrap(true)
            row.header:SetPoint("LEFT", row, "LEFT", IN, 0)
            row.header:SetWidth(rowW.item - 2 * IN)
        else
            ns.UI:SetTextStyle(row.header, "emph", "GOLD")
            row.header:SetWordWrap((lay.headLines or 1) > 1)
            row.header:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", IN, 7)
            row.header:SetWidth(lay.headW or (rowW.item - 2 * IN))
        end
        row.header:SetText(d.text or "")
        row.headCost:SetShown(lay.cost ~= nil)
        row.headCost:SetText(lay.cost or "")
        row.headCost:SetWidth(max((lay.costW or 0) - 12, 1) + 2)
        return
    end
    row.headCost:Hide()
    local id = d.id
    row.icon:SetSize(lay.icon, lay.icon)
    row.icon:ClearAllPoints()
    row.icon:SetPoint("LEFT", row, "LEFT", lay.iconX, 0)
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
    -- the guide line runs from the item above down through its indented rows (the last one stops short)
    row.guide:SetShown(d.via ~= nil)
    if d.via then
        row.guide:ClearAllPoints()
        row.guide:SetPoint("TOPLEFT", row, "TOPLEFT", IN + 12, 0)
        row.guide:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", IN + 12, d.grouped and 0 or 8)
    end
    -- name and second line as one block, centred (a name alone is centred too)
    local block = lay.nameLines * NAME_LH + (lay.subLines > 0 and (2 + lay.subLines * SUB_LH) or 0)
    local top = floor((lay.h - block) / 2)
    row.name:ClearAllPoints()
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", lay.textX, -top)
    row.name:SetWidth(lay.textW)
    row.name:SetWordWrap(lay.nameLines > 1)
    row.name:SetText(NameText(id))
    row.sub:ClearAllPoints()
    row.sub:SetPoint("TOPLEFT", row, "TOPLEFT", lay.textX, -(top + lay.nameLines * NAME_LH + 2))
    row.sub:SetWidth(lay.textW)
    row.sub:SetWordWrap(lay.subLines > 1)
    row.sub:SetText(lay.sub)
    row.mark:SetWidth(max(lay.rightW, 1))
    row.mark:SetText(lay.lines[1] or "")
    row.mark2:SetWidth(max(lay.rightW, 1))
    row.mark2:SetText(lay.lines[2] or "")
    row:SetSelected(state.selected ~= nil and id == state.selected)
    SetRowHover(row, row:IsMouseOver() and true or false)
end

---------------------------------------------------------------------------
-- The item menu (right-click) and the + menu
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
                if cur == t.itemID then text = text .. "  " .. S:Wrap("DIM", "(already)") end
                local b = sub:CreateButton(text, function()
                    local n = A:AddToBiS(t.itemID, sid, which, phase, list, later)
                    if n > 0 then
                        local link = ns.ItemDB:GetLink(t.itemID) or A:GetName(t.itemID) or "item"
                        local label = ns.PhaseLabel and ns.PhaseLabel(phase) or ("P" .. phase)
                        local where = later and n > 1 and ("P%d-%d"):format(phase, phase + n - 1) or label
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

-- The phases of one list (main or off spec) as entries of `sub`, each opening its best / alt choices: the Pre-raid
-- list first, then Phase 1..5.
local function AddPhaseEntries(sub, targets, list)
    local now = GuildPhase()
    for _, p in ipairs(ns.LIST_PHASES or { 1, 2, 3, 4, 5 }) do
        local info = ns.PHASE_INFO and ns.PHASE_INFO[p]
        local label = info and info.name or ("Phase " .. p)
        if p == now then label = label .. "  " .. S:Wrap("DIM", "(now)") end
        local onList = false
        for _, t in ipairs(targets) do
            local mk = marks[t.itemID]
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
                tooltip:AddLine(("Phase %d and later"):format(from), S:Color("GOLD"))
                tooltip:AddLine(("Sets it in P%d, and in every later phase where that place is still empty."):format(from), 1, 1, 1, true)
            end)
        end
        AddPhaseChoices(later, targets, from, list, true)
    end
end

local function AddListMenu(root, text, targets, list)
    AddPhaseEntries(root:CreateButton(text), targets, list)
end

-- "Add to main spec (Ret)" / "Add to off spec (Prot)", or one "Add to my BiS list" without an off spec. bare = the
-- + menu: the phases right away when there is one list.
local function AddListMenus(root, targets, bare)
    local BiS = ns.BiS
    if BiS and BiS.HasOffSpec and BiS:HasOffSpec() then
        local ms = BiS.GetSpec and BiS:GetSpec() or ""
        local os = BiS.GetSpec and BiS:GetSpec("os") or ""
        AddListMenu(root, "Add to main spec" .. (ms ~= "" and (" (" .. ms .. ")") or ""), targets, nil)
        AddListMenu(root, "Add to off spec" .. (os ~= "" and (" (" .. os .. ")") or ""), targets, "os")
    elseif bare then
        AddPhaseEntries(root, targets, nil)
    else
        AddListMenu(root, "Add to my BiS list", targets, nil)
    end
end

function ShowItemMenu(row, d)
    local id = d.id
    local A = Atlas()
    ns.UI:ContextMenu(row, function(root)
        root:CreateTitle(A:GetName(id) or "?")
        if ns.Shop and ns.Shop:CanAdd(id) then
            root:CreateButton("Add to shopping list", function() AddToShop(id) end)
        end
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
                    AddListMenus(root, targets, false)
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

-- The + button's menu: straight to the phases (or main / off spec first).
function ShowAddMenu(owner, d)
    if not (d and d.type == "item") then return end
    local A = Atlas()
    local targets = A:GetBiSTargets(d.id)
    if #targets == 0 then return end
    ns.UI:ContextMenu(owner, function(root)
        root:CreateTitle(A:GetName(d.id) or "?")
        if MenuLocked(root) then return end
        AddListMenus(root, targets, true)
    end)
end

---------------------------------------------------------------------------
-- Lists
---------------------------------------------------------------------------

local function ColH()
    -- (a layout region has a 1 x 1 placeholder size until the client lays it out)
    local h = panel and panel.body and panel.body:GetHeight()
    return (h and h > 1) and h or BODY_H
end

-- A list's rows fill its column. Its scroll bar: "margin" = in the page's right margin, 4 right of the rows (the
-- item list, like the Raids tab's); "over" = over the rows' own right padding (the sources: their tags keep clear of
-- it); else inside the column, taking room from the rows only while they don't fit (the pages).
local function PlaceBox(list, scrolls, where)
    local box, bar = list.box, list.bar
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", list.frame, "TOPLEFT", 0, 0)
    box:SetPoint("BOTTOMRIGHT", list.frame, "BOTTOMRIGHT", (scrolls and not where) and -BAR_SPACE or 0, 0)
    local x = (where == "margin" and 4) or (where == "over" and -6) or (BAR_SPACE - 6)
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", x, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", x, 0)
    if where == "over" then bar:SetFrameLevel(box:GetFrameLevel() + 20) end
end

local function FillList(list, key, rows, fullW, viewH, extent, resetScroll)
    rowW[key] = fullW
    local total = 0
    for _, d in ipairs(rows) do total = total + extent(d) end
    local scrolls = total > viewH + 0.5
    if scrolls then rowW[key] = fullW - BAR_SPACE end
    PlaceBox(list, scrolls, nil)
    list:SetData(rows, resetScroll)
end

function AtlasUI:RefreshSources()
    if not srcList then return end
    local rows = { { type = "shop" } }
    for _, cat in ipairs(Atlas():GetCategories()) do
        local open = state.expanded == cat.key
        rows[#rows + 1] = { type = "cat", cat = cat, expanded = open }
        if open then
            for _, src in ipairs(cat.sources) do rows[#rows + 1] = { type = "src", cat = cat, src = src } end
        end
    end
    -- the scroll bar lies over the rows' right padding: nothing moves whichever category is open
    rowW.src = LEFT_W
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

-- The art behind the detail's banner: a raid's key (the banner crops its loading screen), a dungeon zone's loading
-- screen as { file, l, r, t, b }, or nil (other sources: the banner's plain card).
local function BannerArt(src, w, h)
    if type(src) ~= "table" then return nil end
    if src.kind == "dungeon" then
        local R = ns.DungeonRuns
        local file, l, r, t, b
        if R and R.GetArt then file, l, r, t, b = R:GetArt(src.key, w, h, ART_FW) end
        return file and { file, l, r, t, b } or nil
    end
    if src.kind ~= "raid" then return nil end
    local DB = ns.ItemDB
    local key = DB and DB.GetRaidByInstance and DB:GetRaidByInstance(src.instanceID or 0)
    return key or "other"
end

-- "10 players", "You're Revered" (a faction: its pages are the standings). The phase is beside the source already.
local function SourceSub(src)
    local sub = {}
    if src.size then sub[#sub + 1] = src.size .. " players" end
    if src.factionID and GetFactionInfoByID then
        local name, _, standing = GetFactionInfoByID(src.factionID)
        standing = tonumber(standing)
        local label = standing and GearUI.StandingName(standing)
        if name and type(label) == "string" and label ~= "" then sub[#sub + 1] = "You're " .. label end
    end
    return table.concat(sub, DOT)
end

-- The detail's banner (D3: UI:CreatePageBanner, tool size): the page's name under its source as the kicker, the
-- notes as its sub line, over the source's loading screen (a raid or dungeon) or the plain card. No title: hidden.
-- Returns where the item list starts under it.
local function FillBanner(kicker, title, sub, art)
    if not title or title == "" then
        banner:Hide()
        return 0
    end
    banner:SetArt(art)
    banner:SetKicker(kicker)
    banner:SetTitle(title)
    banner:SetSub((sub and sub ~= "") and sub or nil)
    banner:Show()
    return BANNER_H + GAP
end

-- The pages column's section header (UI:CreateSectionHeader): the title cut to the column. Returns where the column's
-- content starts under it.
local function FillHead(h, title)
    h:SetTitle(title or "")
    ns.UI:FitText(h.title, title or "", MID_W - 4)
    h:Show()
    return HEAD_H + 4
end

local function PlacePageList(top)
    pageList.frame:ClearAllPoints()
    pageList.frame:SetPoint("TOPLEFT", panel.mid, "TOPLEFT", 0, -top)
    pageList.frame:SetPoint("BOTTOMRIGHT", panel.mid, "BOTTOMRIGHT", 0, 0)
    return ColH() - top
end

-- The shopping list takes the middle and right columns (UI/AtlasShop.lua) while it's the place picked on the left
-- and nothing is searched.
local function ShowingShop()
    return state.cat == SHOP and not IsSearching() and ns.AtlasShopUI ~= nil
end

function AtlasUI:RefreshPages()
    if not pageList then return end
    local A = Atlas()
    RefreshMarks()
    if ShowingShop() then
        midHead:Hide()
        diffNormal:Hide()
        diffHeroic:Hide()
        pageList.frame:Hide()
        ns.AtlasShopUI:Show()
        return
    end
    if ns.AtlasShopUI then ns.AtlasShopUI:Hide() end
    if IsSearching() then
        local res = SearchResults()
        local rows = {}
        if res.facets[1].count > 0 then
            for _, f in ipairs(res.facets) do rows[#rows + 1] = { type = "facet", key = f.key, name = f.name, count = f.count } end
        end
        diffNormal:Hide()
        diffHeroic:Hide()
        local top = FillHead(midHead, "Found in")
        pageList:SetEmptyText(#rows == 0 and "No matches" or "")
        pageList.frame:Show()
        FillList(pageList, "page", rows, MID_W, PlacePageList(top), PageExtent, true)
        return
    end
    pageList:SetEmptyText("")
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
    -- the source's name over its pages (its art and sub line are the detail's banner)
    local top = 0
    midHead:Hide()
    if src then top = FillHead(midHead, src.name) end
    local heroic = A:HasHeroic(src)
    diffNormal:SetShown(heroic)
    diffHeroic:SetShown(heroic)
    if heroic then
        diffNormal:ClearAllPoints()
        diffNormal:SetPoint("TOPLEFT", panel.mid, "TOPLEFT", IN - 6, -top)
        diffNormal:SetActive(not state.heroic)
        diffHeroic:SetActive(state.heroic)
        top = top + TABS_H + 4
    end
    -- a source with a single page (a vendor, a collection) needs no list: the item list's title names it
    pageList.frame:SetShown(not (src and #src.pages == 1))
    FillList(pageList, "page", rows, MID_W, PlacePageList(top), PageExtent, false)
end

-- Item rows of a list of entries: headers kept only when an item follows them. Under an item, indented rows of what
-- it turns into or comes from (they work like any item): a token's pieces for my class (filtered like the page), a
-- Sunwell drop's Sunmote upgrade, a Sunmote item's base drop, what a recipe makes.
local function EntryRows(entries, x, setPage)
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
            local item = { type = "item", id = e, x = type(x) == "table" and x[i] or nil, setPage = setPage }
            rows[#rows + 1] = item
            count = count + 1
            if e > 0 then
                local last
                for _, r in ipairs(A:GetRewards(e)) do
                    if r.kind ~= "token" or Passes(r.id) then
                        last = { type = "item", id = r.id, via = e, viaKind = r.kind, grouped = true }
                        rows[#rows + 1] = last
                        item.grouped = true   -- no rule between an item and its indented rows
                    end
                end
                if last then last.grouped = nil end
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

-- The item list's empty state: the illustrated one (title + text) and, under it, the same text as the plain line.
local function ItemsEmpty(title, text)
    itemList:SetEmptyText(text)
    local same = text == title or text == title .. "."
    itemList:SetEmptyState({ glyph = ns.UI.ICON.notes, title = title, text = (not same) and text or nil })
end

-- While my BiS lists are locked (§38) a notice above the columns says why the + buttons are gone (display only:
-- CanAdd / the menus decide as before).
local lockNoticeOn = false
local function UpdateLockNotice()
    if not layout then return end
    if listLocked then
        local _, info = ns.UI:IsMyListLocked()
        layout:ShowNotice("locked", "BiS lists are locked by " .. ns.UI:LockByText(info)
            .. " during the raid: you can browse, but not add to your list.")
        lockNoticeOn = true
    elseif lockNoticeOn then
        layout:HideNotice()
        lockNoticeOn = false
    end
end

function AtlasUI:RefreshItems(resetScroll)
    if not itemList then return end
    if ShowingShop() then
        banner:Hide()
        itemList.frame:Hide()
        ns.AtlasShopUI:Refresh(resetScroll)
        barKeys = {}
        LayoutBar()
        return
    end
    itemList.frame:Show()
    local A = Atlas()
    RefreshMarks()
    wantCache = {}
    layCache = {}
    listLocked = ns.UI:IsMyListLocked() and true or false
    UpdateLockNotice()
    local w = panel.right and panel.right:GetWidth()
    rowW.item = (w and w > 1) and w or (layout and layout.detailW) or RIGHT_W
    local rows, count = {}, 0
    local title, sub, kicker, art = "", "", nil, nil
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
        -- (the counts are beside "Found in")
        title = facetName or "All results"
        kicker = "Search"
        sub = '"' .. state.search .. '"'
        ItemsEmpty("No matches", Filtered()
            and "Nothing matches with these filters. Try Show: All items, or Any slot."
            or "No item has that name.")
    else
        local src = state.cat and A:GetSource(state.cat, state.src)
        local page = src and A:GetPage(state.cat, state.src, state.page)
        if page then
            local heroic = state.heroic and page.heroicItems ~= nil
            local plain = not state.heroic or not page.heroicItems
            rows, count = EntryRows(A:GetPageEntries(page, heroic), plain and page.x or nil, src.kind == "sets")
            -- the page's name (Normal / Heroic shows beside the pages); a note only for what isn't visible: a set
            -- page's own name under its set title, a page of a later phase than its source, what the set costs
            title = page.title or page.name or ""
            kicker = src.name
            art = BannerArt(src, rowW.item - 2, BANNER_H - 2)
            local note = {}
            local where = SourceSub(src)
            if where ~= "" then note[#note + 1] = where end
            if page.phase and page.phase ~= (src.phase or 1) then note[#note + 1] = "Phase " .. page.phase end
            if page.title and page.name then note[#note + 1] = page.name end
            local total = src.kind == "sets" and SetTotals(rows)
            if total then note[#note + 1] = total end
            sub = table.concat(note, DOT)
            ItemsEmpty("Nothing here", Filtered()
                and "Nothing here passes the filters. Try Show: All items, or Any slot."
                or "Nothing here.")
        else
            ItemsEmpty("Pick a source", "Pick a source on the left.")
        end
    end
    local headH = FillBanner(kicker, title, sub, art)
    itemList.frame:ClearAllPoints()
    itemList.frame:SetPoint("TOPLEFT", panel.right, "TOPLEFT", 0, -headH)
    itemList.frame:SetPoint("BOTTOMRIGHT", panel.right, "BOTTOMRIGHT", 0, 0)
    itemList:SetData(rows, resetScroll)
    Prefetch(rows)
    barKeys = ContextKeys(rows)
    LayoutBar()
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

-- Opens the shopping list (groupId: "all" (default), "you", "nobody", "bop" or a member's key).
function AtlasUI:OpenShop(groupId)
    state.cat, state.src, state.page = SHOP, nil, nil
    state.selected = nil
    if ns.AtlasShopUI and groupId then ns.AtlasShopUI:GetState().group = groupId end
    if not panel then return end
    self:RefreshSources()
    self:RefreshPages()
    self:RefreshItems(true)
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

-- (the detail's banner and the pages column's header are the shared ones: FillBanner / FillHead fill them)
function AtlasUI:CreatePanel(parent)
    if panel then return panel end
    local UI = ns.UI
    panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints(parent)
    -- (List + detail, 3 columns: nav = the sources, list = the pages, detail = the items)
    layout = UI:CreateLayout("listdetail", panel, { navWidth = LEFT_W, listWidth = MID_W, banner = false,
                                                    bottom = BOTTOM })
    panel.layout = layout
    local bar = layout.toolbar

    -- the toolbar: the search over the first two columns, the filters over the item column
    searchBox = UI:CreateSearchBox(bar, LEFT_W + GAP + MID_W, function(text)
        state.search = text or ""
        state.selected = nil
        state.facet = nil
        AtlasUI:RefreshSources()
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end, "Search every item by name")
    searchBox:SetHeight(CTRL_H)
    searchBox:SetPoint("LEFT", bar, "TOPLEFT", PAD, -UI.LAYOUT.ROW_MID)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    slotDD = UI:CreateSleekDropdown(bar, SLOT_W, SlotOptions, function() return state.slot end, function(v)
        state.slot = v
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end)
    slotDD:SetHeight(CTRL_H)

    showDD = UI:CreateSleekDropdown(bar, RIGHT_W - SLOT_W - UI.LAYOUT.CTRL_GAP,
        function() return Atlas():GetShowOptions() end, ShowMode, function(v)
            SetShowMode(v)
            AtlasUI:RefreshPages()
            AtlasUI:RefreshItems(true)
        end)
    showDD:SetHeight(CTRL_H)
    bar:SetFilters({ showDD, slotDD })
    -- "Show" inside the dropdown, in front of the choice
    local showLabel = UI:Text(showDD, "small", "DIM", { text = "Show" })
    showLabel:SetPoint("LEFT", showDD, "LEFT", 8, 0)
    local fs = showDD:GetFontString()
    if fs then
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", showDD, "LEFT", 8 + ceil(TextWidth("Show", "small")) + 6, 0)
        fs:SetPoint("RIGHT", showDD, "RIGHT", -20, 0)
    end

    -- the columns (the layout's), the currency bar under them (in the layout's bottom margin)
    panel.body = layout.content

    curBar = CreateCurrencyBar(panel)
    curBar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, PAD)
    curBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, PAD)
    panel.currencyBar = curBar

    local left, mid, right = layout.nav, layout.list, layout.detail
    panel.left, panel.mid, panel.right = left, mid, right

    srcList = UI:CreateScrollList(left, ROW_SRC, InitSourceRow, SourceExtent)
    srcList.frame:SetAllPoints(left)
    PlaceBox(srcList, false, "over")

    midHead = UI:CreateSectionHeader(mid, "", { style = "title" })
    midHead:SetPoint("TOPLEFT", mid, "TOPLEFT", 0, 0)
    midHead:SetPoint("TOPRIGHT", mid, "TOPRIGHT", 0, 0)
    midHead:Hide()

    diffNormal = UI:CreateUnderlineTab(mid, "Normal", function()
        state.heroic = false
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end, "small")
    diffHeroic = UI:CreateUnderlineTab(mid, "Heroic", function()
        state.heroic = true
        AtlasUI:RefreshPages()
        AtlasUI:RefreshItems(true)
    end, "small")
    diffHeroic:SetPoint("LEFT", diffNormal, "RIGHT", 4, 0)
    diffNormal:Hide()
    diffHeroic:Hide()

    pageList = UI:CreateScrollList(mid, ROW_PAGE, InitPageRow, PageExtent)
    pageList.frame:SetPoint("TOPLEFT", mid, "TOPLEFT", 0, 0)
    pageList.frame:SetPoint("BOTTOMRIGHT", mid, "BOTTOMRIGHT", 0, 0)
    PlaceBox(pageList, false, nil)

    -- D3: the detail opens with a banner (the page, its source's art)
    banner = UI:CreatePageBanner(right, { size = "tool", width = RIGHT_W, artFw = ART_FW })
    banner:SetPoint("TOPLEFT", right, "TOPLEFT", 0, 0)
    banner:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, 0)
    banner:Hide()
    panel.banner = banner
    itemList = UI:CreateScrollList(right, ROW_ITEM, InitItemRow, ItemExtent)
    itemList.frame:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -(BANNER_H + GAP))
    itemList.frame:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)
    PlaceBox(itemList, true, "margin")

    -- the shopping list: the other two columns while it's picked
    if ns.AtlasShopUI then
        ns.AtlasShopUI:Create({ TextWidth = TextWidth, CodedWidth = CodedWidth, NameText = NameText, HEAD_H = HEAD_H,
                                BANNER_H = BANNER_H, DETAIL_W = layout.detailW or RIGHT_W }, mid, right)
    end

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
    ClearSearch()
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

-- Opens the item menu (right-click) / the + button's menu of a row's data (tests, the UI audit).
function AtlasUI:OpenMenu(d, owner)
    ShowItemMenu(owner or panel, d)
end

function AtlasUI:OpenAddMenu(d, owner)
    ShowAddMenu(owner or panel, d)
end

-- Shows an item row as hovered (its + button), for the UI audit.
function AtlasUI:HoverItem(itemID)
    if not itemList then return end
    itemList.box:ForEachFrame(function(row)
        local d = row.__cdlData
        if d and d.type == "item" and d.id == itemID then SetRowHover(row, true) end
    end)
end

---------------------------------------------------------------------------
-- Registration & messages
---------------------------------------------------------------------------

if ns.MainFrame and ns.MainFrame.RegisterTab then
    ns.MainFrame:RegisterTab("atlas", "Atlas", 1.5, function(parent) return AtlasUI:CreatePanel(parent) end, nil,
        { layout = "listdetail" })
end

-- The item list (and the star counts beside the pages) a moment later; facets = the search's "Found in" too.
local facetsPending = false
local function RefreshLater(sec, facets)
    facetsPending = facetsPending or facets
    Debounce("atlas-items", sec, function()
        if not panel:IsVisible() then
            panel.dirty = true
            return
        end
        if facetsPending and IsSearching() then AtlasUI:RefreshPages() end
        facetsPending = false
        AtlasUI:RefreshItems()
        if pageList then pageList:Refresh() end
    end)
end

-- My list / the council's lists changed: the marks, the + buttons and the star counts.
local function RequestItems()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    RefreshLater(0.05, false)
end

-- Item names / stats arrived: names may need other line breaks, and the spec filter may judge more items now.
local function ItemInfoReady()
    if not (panel and panel:IsVisible() and itemList) then return end
    local mode = ShowMode()
    local spec = mode == "spec" or mode == "os"
    if spec then searchCache = nil end
    RefreshLater(0.1, spec)
end

ns:On("MYLIST_CHANGED", RequestItems)
ns:On("OWNED_UPDATED", RequestItems)
ns:On("LISTS_RESET", RequestItems)
ns:On("LIST_UPDATED", function()
    if IsCouncil() then RequestItems() end
end)
ns:On("CONFIG_UPDATED", RequestItems)
ns:On("BIS_LOCK_CHANGED", RequestItems)
ns:On("ITEMINFO_READY", ItemInfoReady)
-- my shopping list changed: its count on the left, the bag marks on the rows
ns:On("SHOP_UPDATED", function()
    if not panel then return end
    if srcList then srcList:Refresh() end
    RequestItems()
end)
-- what I hold changed (honor, arena points, badges, marks, money): the bar and the red / white costs
ns:On("CURRENCY_CHANGED", function()
    if not panel then return end
    if panel:IsVisible() then LayoutBar() end
    RequestItems()
end)
-- a vendor told me new prices
ns:On("PRICES_UPDATED", RequestItems)
