if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Atlas.lua", ...) then return end -- DisasterZone UI/Atlas.lua
-- ns.AtlasUI: the Atlas tab, a loot browser for every member (no guild or raid needed). One wide page under a path of
-- drop-downs (UI/AtlasNav.lua): era › category › place › boss. Each part is both where I am and how I move: the era
-- (Classic | TBC), the category (its words open the category as art tiles; its arrow the jump panel), the place (the
-- jump panel: Recent in both eras, every place of a category grouped by phase or level, the categories, the era) and
-- the boss (the bosses as portraits, or a menu of a source's pages). Views:
--   source    a raid or dungeon opens on ALL its loot: a banner (loading screen, size, phase, my BiS stars, dots that
--             jump to a boss) over one section per boss (portrait, items, stars, "Open ›") with the items as tiles
--   page      one boss (or a vendor's / faction's / set class's page): the banner with the boss's Encounter Journal
--             portrait, ‹ › to step and the dots, over the items in a grid
--   category  every place of a category as art tiles (recently viewed first; Classic dungeons by level, the ones that
--             fit my level first)
--   search    the search field takes the path's place: places first (both eras: a wing, a raid, a boss; Enter opens
--             one and the era follows), then the items grouped by where they're from ("Show all ›"), the categories
--             as chips ("In Classic": the other era's count, a click switches). ↑ ↓ move, Enter opens, Shift+Enter
--             adds to my BiS list, Esc leaves.
--   shop      the shopping list (UI/AtlasShop.lua) behind the bag button on the path's right
-- Under the banner a row of chips filters the items: All / Weapons / Armor / Jewelry / Tokens (the kinds the page has),
-- "For me ▾" (all items, my class, a spec) and the slot. Items are tiles: icon, name, slot · type (a token's classes),
-- my marks / the cost on the right; hover = tooltip, "+ BiS" (or "+ List" for a craft); right-click = the menu (BiS
-- phases, shopping list, try on, link); shift-click = link, ctrl-click = dressing room. What an item gives or comes
-- from (a token's pieces for my class, a Sunmote upgrade, what a recipe makes) follows it with a gold bar.
-- An item a vendor sells shows its cost with the currencies' icons, red while I hold less; the currency bar along the
-- bottom has Honor, Arena Points and Badges always, then what the page pays with, lit by a hovered item.
-- Ctrl+F focuses the search. Model: Core/Atlas.lua (ns.Atlas).
local addonName, ns = ...

local AtlasUI = {}
ns.AtlasUI = AtlasUI

local S = ns.Style
local GearUI = ns.GearUI          -- (UI/PaperDoll.lua: the helpers the Gear pages share)

local ipairs, pairs, type, tonumber, tostring = ipairs, pairs, type, tonumber, tostring
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local PAD, GAP, IN = S.PAD, S.GAP, S.IN
local CTRL_H = 22                                 -- the chips row, the search field
local BAR_H = 30                                  -- the currency bar along the bottom
local BOTTOM = PAD + BAR_H + GAP                  -- the layout's bottom margin: the currency bar's place
local BODY_W = S.INNER_W                          -- sizes before the first layout (fixed window)
local HERO_H = 92                                 -- the banner over a place / a page
local PORTRAIT_W = 176                            -- a boss's portrait in the banner (128 x 64 art, 2:1)
local CELL_GAP = 6                                -- between item cards (both ways)
local CELL_MIN, CELL_MAX = 54, 68                 -- an item card's least height; the grid's even height at most
local CARD_X = 10                                 -- an item card's inner margin left and right
local SECTION_H, LABEL_H, PLACE_H, SRCHEAD_H = 38, 26, 46, 34
local TILE_H, TILES_PER_ROW = 74, 4               -- the category view's place tiles
local ROW_SECTION, ROW_MORE = 28, 36              -- a set's header, a "showing the first ..." note
local ICON, ICON_REWARD = 36, 30
local NAME_LH, SUB_LH = 14, 12                    -- line heights of an item's name (12) and its second line (10)
local BAR_SPACE = 10                              -- the grid's scroll bar: 6 wide, 4 from the tiles
local PLUS = 22                                   -- the hover buttons on a tile
local MAX_SHOWN = 300                             -- search results drawn at most (the chips narrow them down)
local GROUP_SHOWN = 6                             -- search: a source's first tiles (two rows); "Show all ›" for more
local PLACES_SHOWN = 5                            -- search: places listed before the items
local RECENT_MAX = 6
local DOT = "  ·  "
local CLASS_WEAPON, CLASS_ARMOR = 2, 4            -- Enum.ItemClass
local GOLD_HEX = S:Hex("GOLD")
local EJ_DEFAULT = 521744                         -- UI-EJ-BOSS-Default (also Data/AtlasPortraits.lua's DEFAULT)

-- English names of a weapon / armor subclass, one item's worth ("Main Hand · Dagger", not "Daggers").
local WEAPON_KIND = { [0] = "Axe", [1] = "Axe", [2] = "Bow", [3] = "Gun", [4] = "Mace", [5] = "Mace", [6] = "Polearm",
                      [7] = "Sword", [8] = "Sword", [10] = "Staff", [13] = "Fist Weapon", [15] = "Dagger",
                      [16] = "Thrown", [18] = "Crossbow", [19] = "Wand", [20] = "Fishing Pole" }
local ARMOR_KIND = { [6] = "Shield", [7] = "Libram", [8] = "Idol", [9] = "Totem" }
local JEWELRY = { INVTYPE_NECK = true, INVTYPE_FINGER = true, INVTYPE_TRINKET = true }

-- The kinds the chips filter by, in their order.
local KINDS = { { key = "weapon", name = "Weapons" }, { key = "armor", name = "Armor" },
                { key = "jewelry", name = "Jewelry" }, { key = "token", name = "Tokens" }, { key = "other", name = "Other" } }

-- A category's icon (the jump panel, a place tile without art), by its key without the Classic "c_".
local CAT_ICON = {
    raids = "Interface\\Icons\\INV_Misc_Head_Dragon_01", dungeons = 136339,
    crafting = "Interface\\Icons\\Trade_BlackSmithing", reputation = "Interface\\Icons\\INV_Shirt_GuildTabard_01",
    pvp = "Interface\\Icons\\INV_Jewelry_TrinketPVP_02", vendors = "Interface\\Icons\\Spell_Holy_ChampionsBond",
    collections = "Interface\\Icons\\Ability_Mount_RidingHorse", events = "Interface\\Icons\\INV_Misc_Ribbon_01",
    sets = "Interface\\Icons\\INV_Chest_Plate03",
}
local CAT_ICON_DEFAULT = "Interface\\Icons\\INV_Misc_Book_09"

local panel, layout, searchBox, grid, hero, chipsRow, curBar, toast
local state = {
    cat = nil, src = nil, page = nil, heroic = false,
    view = "page",       -- "source" (all a place's loot) | "page" | "category" | "shop" (search: state.search)
    search = "",
    slot = nil,          -- slot filter: nil = any, sid, or 0 = not gear
    kind = nil,          -- the kind chip: nil = all, or a KINDS key
    selected = nil,      -- the item a search result jumped to (highlighted)
    facet = nil,         -- search: the category the results are narrowed to (nil = all)
    showSrc = nil,       -- search: the source whose matches show in full ("Show all ›")
    cursor = 1,          -- search: the highlighted result (↑ ↓, Enter)
    places = {},         -- [era] = { cat, src, page, heroic, view }: where I was in the other era
    recent = {},         -- the places opened last: { { cat, src, heroic }, ... } (both eras)
}
local ERA_FACET = "@era"  -- search: the chip that switches to the other era
local searchCache        -- { key, entries, facets } of the last search
local hits = {}          -- search: the results ↑ ↓ walk through ({ place = p } / { item = d })
local marks = {}         -- Atlas:GetMyListMarks() of the last refresh
local pickCache = {}     -- [heroic and 2 or 1][page] = my BiS picks on that page
local wantCache = {}     -- [itemID] = number of members who want it (council only; per refresh)
local layCache = {}      -- [cell data] = its layout (per refresh of the grid)
local listLocked = false -- my BiS lists are locked (no + buttons)
local rowW = { item = 250, grid = BODY_W - BAR_SPACE }   -- a tile's width, the grid's
local cols = 2           -- item cards per row
local flatRows = {}      -- the grid's item-level rows in order (GetLists, tests)
local SelectSource, ShowItemMenu, ShowAddMenu, SearchResults, AddToShop, ShopButtonTooltip   -- forward declarations

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Atlas() return ns.Atlas end
local function Nav() return ns.AtlasNav end

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
    return ShowMode() ~= "all" or state.slot ~= nil or state.kind ~= nil
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
    local _, mine = UnitClass("player")
    for i, cf in ipairs(classes) do
        local n = (type(loc) == "table" and loc[cf]) or cf
        names[i] = cf == mine and ns.UI:Colorize(n, ns.UI:ClassColor(cf)) or n
    end
    return "Token" .. DOT .. table.concat(names, ", ")
end

-- The kind chip an entry falls under: weapon / armor / jewelry / token / other.
local function KindOf(id)
    if type(id) ~= "number" or id < 0 then return "other" end
    local DB = ns.ItemDB
    if DB and DB.GetTokenClasses and type(DB:GetTokenClasses(id)) == "table" then return "token" end
    if not (C_Item and C_Item.GetItemInfoInstant) then return "other" end
    local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(id)
    if classID == CLASS_WEAPON then return "weapon" end
    if classID == CLASS_ARMOR then return JEWELRY[equipLoc] and "jewelry" or "armor" end
    return "other"
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

-- Width of a text in a style: tiles whose text needs more get two lines instead of cutting a name off.
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

-- A colour fading from `bottom` (alpha at the foot) to `top` (UI:Gradient, vertical).
local function Fade(tex, r, g, b, bottom, top)
    ns.UI:Gradient(tex, "VERTICAL", { r, g, b, bottom }, { r, g, b, top })
end

---------------------------------------------------------------------------
-- Costs and the currency bar
---------------------------------------------------------------------------
local barKeys = {}       -- the bar's currencies after the pinned ones: what the list shown pays with
local hoverRow           -- the item tile whose cost the bar shows
local Cur, CostOf, AddCostLines, BarShowCost, LayoutBar, ContextKeys, SetTotals, CreateCurrencyBar
do

    local CHIP_ICON, CHIP_GAP, MAX_CONTEXT = 16, 1, 4
    local CHIP_FONT, CHIP_STYLE = 12, "emph"
    local RED_HEX, GREEN_HEX, YELLOW_HEX = S:Hex("BAD"), S:Hex("OK"), S:Hex("GOLD")

    function Cur() return ns.Currency end

    -- An item's cost: parts ({ { key, n }, ... }), where it comes from; nil when no vendor price is known.
    function CostOf(id)
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
    function AddCostLines(tt, parts, from)
        local C = Cur()
        tt:AddLine(" ")
        tt:AddLine("Cost", S:RGB("GOLD"))
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
        tt:AddLine((key == C.MONEY and "" or (C:IconMarkup(key, 14) .. " ")) .. C:Name(key), S:RGB("GOLD"))
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
    function BarShowCost(d)
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
    function LayoutBar()
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
    function ContextKeys(rows)
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
    -- returns the page's total when it has no headers (one set: its note in the banner).
    function SetTotals(rows)
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
    function CreateCurrencyBar(parent)
        local bar = CreateFrame("Frame", nil, parent)
        bar:SetHeight(BAR_H)
        -- no box: a dark shade fading up into the panel under one hairline, gold in the middle and gone at the ends
        bar.bg = bar:CreateTexture(nil, "BACKGROUND")
        bar.bg:SetAllPoints()
        local card = S.C.CARD
        Fade(bar.bg, card[1] * 0.6, card[2] * 0.6, card[3] * 0.6, 0.85, 0.35)
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

-- The slot and Show filters (the kind chip is applied where the chips' counts are made).
local function Passes(id)
    if not PassesSlot(id) then return false end
    return Atlas():PassesShow(id, ShowMode())
end

local function PassesKind(id)
    return state.kind == nil or KindOf(id) == state.kind
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
-- recipe whose piece / product is the pick. The slot filter narrows it like the items.
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

-- My BiS picks over a whole source (its pages' counts).
local function SourceStars(src)
    local n = 0
    for _, p in ipairs(type(src) == "table" and src.pages or {}) do n = n + PickCount(p) end
    return n
end

local function ClassicShown()
    return Atlas():GetEra() == "classic"
end

-- Can the + button add this item to my list (something that fits a slot, my class can use it, lists not locked)?
local function CanAdd(id)
    if id <= 0 or listLocked or ClassicShown() then return false end
    local A = Atlas()
    local targets = A:GetBiSTargets(id)
    if #targets == 0 then return false end
    for _, t in ipairs(targets) do
        if A:IsUsableByMe(t.itemID) == false then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Places: art, portraits, icons, tags
---------------------------------------------------------------------------

-- A source's picture cropped for a w x h box: file, l, r, t, b (nil: it has none). Classic places carry their loading
-- screen; TBC raids and dungeons theirs (ItemDB / DungeonRuns).
local function SourceArt(src, w, h, fw)
    if type(src) ~= "table" or not (w and h and w > 0 and h > 0) then return nil end
    fw = fw or 0.9
    if src.art then
        -- (a 4:3 loading screen: a band across its middle, clear of the logo on top and the frame below)
        local fh = min(fw * (4 / 3) * (h / w), 0.7)
        local t = 0.55 - fh / 2
        return src.art, (1 - fw) / 2, (1 + fw) / 2, t, t + fh
    end
    if src.kind == "dungeon" then
        local R = ns.DungeonRuns
        if R and R.GetArt then return R:GetArt(src.key, w, h, fw) end
        return nil
    end
    if src.kind == "raid" then
        local DB = ns.ItemDB
        local key = DB and DB.GetRaidByInstance and DB:GetRaidByInstance(src.instanceID or 0)
        if key and DB.RaidArt then return DB:RaidArt(key, w, h, fw, true) end
    end
    return nil
end

-- A boss's Encounter Journal portrait (Data/AtlasPortraits.lua; the Journal's stand-in without one).
local function PortraitOf(page)
    local P = ns.Data and ns.Data.AtlasPortraits
    local name = type(page) == "table" and page.name or page
    local own = P and name and P[name]
    return own or (P and P.DEFAULT) or EJ_DEFAULT, own ~= nil
end

-- Does a source list bosses (portraits, "All bosses")?
local function HasBosses(src)
    return type(src) == "table" and (src.kind == "raid" or src.kind == "dungeon")
end

-- Does a source open on all its loot (a raid or dungeon with more than one boss)?
local function OpensOnAll(src)
    return HasBosses(src) and #src.pages > 1
end

local function CatIcon(cat)
    local key = type(cat) == "table" and cat.key or cat
    key = tostring(key or ""):gsub("^c_", "")
    return CAT_ICON[key] or CAT_ICON_DEFAULT
end

local function ProfessionOf(src)
    local P = ns.Professions
    if not (P and P.GetProfessions and type(src) == "table" and src.kind == "crafting") then return nil end
    for _, def in ipairs(P:GetProfessions()) do
        if def.name == src.name or def.name == src.key then return def end
    end
    return nil
end

-- A source's small icon (the jump panel, a tile without art): the raid's / dungeon's own, a profession's, else its
-- category's.
local function SourceIcon(src, cat)
    local prof = ProfessionOf(src)
    if prof and prof.icon then return prof.icon end
    if type(src) == "table" and src.kind == "raid" then
        local DB = ns.ItemDB
        local key = DB and DB.GetRaidByInstance and DB:GetRaidByInstance(src.instanceID or 0)
        local m = key and DB.GetRaidMeta and DB:GetRaidMeta(key)
        if m and m.icon then return m.icon end
    end
    return CatIcon(cat)
end

-- "P2" .. "P5" for a later phase's place (what has been out from the start goes without); a Classic dungeon's levels.
local function PhaseTag(src)
    if src and src.lv then return src.lv end
    local p = tonumber(src and src.phase)
    return (p and p > 1) and ("P" .. p) or nil
end

-- "10 players", "Levels 18-21", "You're Revered" (a faction: its pages are the standings).
local function SourceSub(src)
    local sub = {}
    if src.lv then sub[#sub + 1] = "Levels " .. src.lv end
    if src.size then sub[#sub + 1] = src.size .. " players" end
    local p = tonumber(src.phase)
    if p and p > 1 then sub[#sub + 1] = "Phase " .. p end
    if src.factionID and GetFactionInfoByID then
        local name, _, standing = GetFactionInfoByID(src.factionID)
        standing = tonumber(standing)
        local label = standing and GearUI.StandingName(standing)
        if name and type(label) == "string" and label ~= "" then sub[#sub + 1] = "You're " .. label end
    end
    return table.concat(sub, DOT)
end

-- The guild's crafters of a profession for a crafting place's banner: { { key, skill, online }, ... } (online first,
-- then by skill; at most n).
local function GuildCrafters(prof, n)
    local P, G = ns.Professions, ns.Guild
    if not (prof and P and P.GetMembers and P.GetSkill) then return {} end
    local out = {}
    for _, key in ipairs(P:GetMembers()) do
        local skill = P:GetSkill(key, prof.id)
        if skill then
            out[#out + 1] = { key = key, skill = skill, online = (G and G.IsOnline and G:IsOnline(key)) and true or false }
        end
    end
    table.sort(out, function(a, b)
        if a.online ~= b.online then return a.online end
        if a.skill ~= b.skill then return a.skill > b.skill end
        return a.key < b.key
    end)
    for i = #out, (n or 3) + 1, -1 do out[i] = nil end
    return out
end

---------------------------------------------------------------------------
-- Recent places
---------------------------------------------------------------------------

local function LoadRecent()
    local saved = ns.DB and ns.DB.GetSetting and ns.DB:GetSetting("atlas.recent")
    state.recent = {}
    for _, r in ipairs(type(saved) == "table" and saved or {}) do
        if type(r) == "table" and Atlas():GetSource(r.cat, r.src) then
            state.recent[#state.recent + 1] = { cat = r.cat, src = r.src, heroic = r.heroic and true or nil }
        end
    end
end

local function NoteRecent(catKey, srcKey, heroic)
    local list = { { cat = catKey, src = srcKey, heroic = heroic and true or nil } }
    for _, r in ipairs(state.recent) do
        if #list >= RECENT_MAX then break end
        if not (r.cat == catKey and r.src == srcKey) then list[#list + 1] = r end
    end
    state.recent = list
    if ns.db and ns.DB and ns.DB.SetSetting then ns.DB:SetSetting("atlas.recent", list) end
end

---------------------------------------------------------------------------
-- Item tiles
---------------------------------------------------------------------------
local ShowShopToast, Layout, SetRowHover, InitItemRow
do

    -- My marks on an item as pills (UI:CreatePill): on my list (best ★ / alt / off spec, with the phases), owned.
    local function MarkPills(id)
        local out = {}
        local m = marks[id]
        if m then
            if m.main then
                out[#out + 1] = { pill = "rank", text = Atlas():PhasesText(m.main) }
            elseif m.alt then
                out[#out + 1] = { pill = "alt", text = "Alt " .. Atlas():PhasesText(m.alt) }
            elseif m.os then
                out[#out + 1] = { pill = "os", text = "OS " .. Atlas():PhasesText(m.os) }
            end
        end
        if id > 0 and ns.BiS and ns.BiS.IsObtained and ns.BiS:IsObtained(id) then
            out[#out + 1] = { pill = "ok", text = "Owned" }
        end
        return out
    end

    -- The note after a craft went on my shopping list: what, who can make it, Undo, Open list.
    function ShowShopToast(id)
        if not toast then return end
        local Shop = ns.Shop
        local name = NameText(id)
        local who
        if Shop and Shop.CanMake and Shop:CanMake(id) then
            who = "you can make it"
        else
            local crafters = Shop and Shop.GetCrafters and Shop:GetCrafters(id) or {}
            if crafters[1] then who = ns.UI:ColoredName(crafters[1].key) .. " can make it" end
        end
        toast.id = id
        toast.text:SetText(name .. " added" .. (who and (DOT .. who) or ""))
        toast:Layout()
        toast:Show()
        toast.left = 5
    end

    -- Puts a craft on my shopping list (UI/AtlasShop.lua: with the amount / breakdown set with Shift).
    function AddToShop(id)
        if ns.AtlasShopUI and ns.AtlasShopUI:AddCraft(id) then ShowShopToast(id) end
    end

    -- The bag button's tooltip: who can make the craft for me, what a click adds.
    function ShopButtonTooltip(btn, row)
        local d = row.__cdlData
        if ns.AtlasShopUI and d and d.type == "item" then ns.AtlasShopUI:AddTooltip(btn, d.id) end
    end

    -- The bag on a craft tile's right: on my shopping list, and how many.
    local function ShopMark(id)
        local n = ns.Shop and ns.Shop:GetAmount(id)
        if not n then return "" end
        return ns.UI:AtlasIconText(ns.UI.ICON.bag, 10, { 0.85, 0.85, 0.85 }) .. " |cffd8d8d8" .. n .. "|r"
    end

    -- The right of a card, at most two lines, each a text or a pill: the cost (icons, red while I hold less) / skill,
    -- my marks, my shopping list, the council's "N want" (a quiet line under the rest).
    local function RightParts(d)
        local id = d.id
        local main = {}
        local parts = CostOf(id)
        if parts then
            main[#main + 1] = { text = Cur():CostText(parts, 12) }
        elseif d.x then
            main[#main + 1] = { text = "|cffe0e0e0" .. d.x .. "|r" }
        end
        for _, m in ipairs(MarkPills(id)) do main[#main + 1] = m end
        local bag = ShopMark(id)
        if bag ~= "" then main[#main + 1] = { text = bag } end
        if IsCouncil() and id > 0 then
            local n = Wanted(id)
            if n > 0 then main[#main + 1] = { text = Colorize(n .. " want", "council") } end
        end
        -- two lines at most: what doesn't fit joins the last text line (a pill stands alone)
        local out = {}
        for _, e in ipairs(main) do
            if #out < 2 then
                out[#out + 1] = e
            elseif e.text and out[2].text then
                out[2].text = out[2].text .. "  " .. e.text
            elseif e.text and out[1].text then
                out[1].text = out[1].text .. "  " .. e.text
            end
        end
        for _, e in ipairs(out) do
            e.w = e.pill and (ceil(TextWidth(e.text, "small")) + (e.pill == "rank" and 26 or 14))
                or ceil(CodedWidth(e.text, "small"))
        end
        return out
    end

    -- The second line: the slot and type, a token's classes, how a following tile relates to the one before it, a set
    -- piece's source.
    local function SubText(d)
        local id = d.id
        local sub = (id > 0 and TokenLine(id)) or TypeLine(id) or ""
        local function lead(word) return sub ~= "" and (word .. DOT .. sub) or word end
        if d.viaKind == "token" then
            -- (no word: the gold bar says it comes from the token before it)
        elseif d.viaKind == "upgrade" then
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

    -- A tile's layout (per refresh): icon, text width and lines, the right column, the hover buttons, the height. A name
    -- or second line that doesn't fit gets two lines (a taller tile), never "...". A set's header and the "showing the
    -- first ..." note span the grid.
    function Layout(d)
        local lay = layCache[d]
        if lay then return lay end
        lay = {}
        layCache[d] = lay
        if d.type == "header" then
            -- a set's header: its total at the right (the amounts alone when the words don't fit), the name on two
            -- lines rather than cut
            local avail = rowW.grid - 2 * IN
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
        local w = rowW.item
        lay.icon = d.via and ICON_REWARD or ICON
        lay.iconX = CARD_X + (d.via and 6 or 0)
        lay.textX = lay.iconX + lay.icon + 10
        lay.right = RightParts(d)
        lay.lines = lay.right       -- (how many lines the right takes)
        local rw = 0
        for _, e in ipairs(lay.right) do rw = max(rw, e.w) end
        lay.rightW = rw
        lay.canAdd = CanAdd(id)
        lay.canShop = ns.Shop ~= nil and ns.Shop:CanAdd(id)
        -- (the hover buttons take the right while hovered; the marks keep their place otherwise)
        lay.textW = w - lay.textX - CARD_X - (rw > 0 and (lay.rightW + 12) or 0)
        lay.sub = SubText(d)
        lay.nameLines = CodedWidth(NameText(id), "emph") > lay.textW and 2 or 1
        lay.subLines = (lay.sub == "" and 0) or (TextWidth(lay.sub, "small") > lay.textW and 2) or 1
        lay.h = max(CELL_MIN, 18 + lay.nameLines * NAME_LH + max(lay.subLines, 1) * SUB_LH)
        return lay
    end

    local function RowTooltip(row)
        local d = row.__cdlData
        if not d or d.type ~= "item" then return end
        local id = d.id
        local function extra(tt)
            local viaName = d.via and (Atlas():GetName(d.via) or "the item before")
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
            if T then T.noMats = true end   -- the materials go under the tile's own lines (extra)
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

    -- Hovering a tile shows "+ BiS" (when it can add to my BiS list) and "+ List" (a craft: my shopping list) at its
    -- top right, over the marks.
    function SetRowHover(row, on)
        local lay = row.lay
        local item = lay and lay.textX ~= nil
        row:SetHover(on and item or false)
        row:PaintCard(on and item)
        -- the currency bar shows the hovered item's cost (a card being drawn while another is hovered leaves it)
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
        row.shop:SetPoint("RIGHT", row, "RIGHT", plus and -(CARD_X + row.plus:GetWidth() + 6) or -CARD_X, 0)
        row.hoverBack:SetShown(plus or shop)
        local busy = plus or shop
        for i, part in ipairs(row.parts) do
            local e = item and lay.right[i]
            part.pill:SetShown(e ~= nil and e.pill ~= nil and not busy)
            part.text:SetShown(e ~= nil and e.pill == nil and not busy)
        end
    end

    -- A card: a quiet surface (a soft vertical gradient under a hairline edge; hover lifts it and turns the edge gold,
    -- the picked one is gold), the item's icon in its quality frame, its name in its quality colour over the slot and
    -- type, the status on the right as pills (the shared UI:CreatePill), the hover buttons over it.
    local CARD_TOP, CARD_FOOT = { 0.125, 0.125, 0.145, 0.96 }, { 0.085, 0.085, 0.10, 0.96 }
    local EDGE_REST, EDGE_HOVER = S.C.HAIRLINE, S:WithAlpha("GOLD", 0.45)

    local function PaintCard(row, hot)
        local sel = row.dzSelected
        if sel then
            ns.UI:SetEdgeColor(row, S:Color("GOLD"))
        else
            ns.UI:SetEdgeColor(row, S:Color(hot and EDGE_HOVER or EDGE_REST))
        end
        row.lift:SetShown(hot or sel)
    end

    local function SetupItemRow(row)
        local UI = ns.UI
        row.cdl = true
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.card = row:CreateTexture(nil, "BACKGROUND")
        row.card:SetAllPoints()
        UI:Gradient(row.card, "VERTICAL", CARD_FOOT, CARD_TOP)
        row.lift = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.lift:SetAllPoints()
        UI:Gradient(row.lift, "VERTICAL", S:WithAlpha("TEXT", 0.015), S:WithAlpha("TEXT", 0.05))
        row.lift:Hide()
        UI:AddEdges(row, "BORDER")
        -- (the hover buttons sit on a fade of the card's colour over the right end)
        row.hoverBack = row:CreateTexture(nil, "ARTWORK", nil, 2)
        row.hoverBack:SetPoint("TOPRIGHT", row, "TOPRIGHT", -1, -1)
        row.hoverBack:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
        row.hoverBack:SetWidth(150)
        UI:Gradient(row.hoverBack, "HORIZONTAL", { CARD_TOP[1], CARD_TOP[2], CARD_TOP[3], 0 },
            { CARD_TOP[1], CARD_TOP[2], CARD_TOP[3], 1 })
        row.hoverBack:Hide()
        -- the picked look (a search result jumped to, the search's cursor); hover is the card's own lift
        UI:DecorateRow(row, { selectable = true })
        if row.dzHover then row.dzHover:SetAlpha(0) end
        -- (picked: the gold edge says it; the shared fill stays faint and the side bar goes)
        if row.dzSelFill then row.dzSelFill:SetAlpha(0.35) end
        if row.dzSelBar then row.dzSelBar:SetAlpha(0) end
        local setSel = row.SetSelected
        row.SetSelected = function(self, on)
            self.dzSelected = on and true or false
            setSel(self, on)
            PaintCard(self, self:IsMouseOver())
        end
        row.PaintCard = PaintCard

        row.icon = UI:CreateItemButton(row, ICON)
        row.icon:EnableMouse(false)   -- the card handles hover and clicks
        -- what this card gives / comes from (it follows the card it belongs to): a gold bar inside its left edge
        row.guide = row:CreateTexture(nil, "ARTWORK")
        row.guide:SetWidth(2)
        row.guide:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
        row.guide:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 1, 1)
        row.guide:SetColorTexture(S:Color(S:WithAlpha("GOLD", 0.6)))

        row.name = UI:Text(row, "emph", "TEXT")
        if row.name.SetMaxLines then row.name:SetMaxLines(2) end
        row.sub = UI:Text(row, "small", "SUB")
        if row.sub.SetMaxLines then row.sub:SetMaxLines(2) end
        -- the right: two lines, each a pill or a text
        row.parts = {}
        for i = 1, 2 do
            row.parts[i] = { pill = UI:CreatePill(row, nil, nil, 16),
                             text = UI:Text(row, "small", "TEXT", { justify = "RIGHT" }) }
        end
        -- the status as one text (tests, the UI audit)
        function row:StatusText()
            local t = {}
            for i, part in ipairs(self.parts) do
                local e = self.lay and self.lay.right[i]
                if e then t[#t + 1] = e.pill and part.pill.fs:GetText() or part.text:GetText() end
            end
            return table.concat(t, "  ")
        end

        -- "+ BiS" (hover): add to my BiS list
        local plus = UI:CreateSleekButton(row, "+ BiS", 54, 20, function(self) ShowAddMenu(self, row.__cdlData) end, "primary")
        plus:SetPoint("RIGHT", row, "RIGHT", -CARD_X, 0)
        plus:SetScript("OnEnter", function() SetRowHover(row, true) end)
        plus:SetScript("OnLeave", function()
            if not row:IsMouseOver() then SetRowHover(row, false) end
        end)
        UI:AttachTooltip(plus, "Add to your BiS list", "Pick the phase, then best or alt.")
        plus:Hide()
        row.plus = plus

        -- "+ List" (hover, a craft): add it to my shopping list
        local shop = UI:CreateSleekButton(row, "+ List", 54, 20, function()
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
            -- the cursor went onto a hover button (still over the card): stay hovered
            if not ((self.plus:IsShown() or self.shop:IsShown()) and self:IsMouseOver()) then SetRowHover(self, false) end
        end)
        -- Shift: a craft's materials; Shift + mouse wheel: how many to make; Shift + click / right-click: break down
        if ns.Tooltip and ns.Tooltip.CraftRow then ns.Tooltip:CraftRow(row, RowTooltip, true) end
    end

    function InitItemRow(row, d)
        if not row.cdl then SetupItemRow(row) end
        local lay = Layout(d)
        row.lay = lay
        local id = d.id
        -- every tile of the grid is as tall as its tallest one: the icon and the text block sit in the middle
        local h = d.cellH or lay.h
        local block = lay.nameLines * NAME_LH + (lay.subLines > 0 and (2 + lay.subLines * SUB_LH) or 0)
        local top = floor((h - block) / 2)
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
        row.guide:SetShown(d.via ~= nil)
        row.name:ClearAllPoints()
        row.name:SetPoint("TOPLEFT", row, "TOPLEFT", lay.textX, -top)
        row.name:SetWidth(lay.textW)
        row.name:SetWordWrap(lay.nameLines > 1)
        row.name:SetText(NameText(id))
        row.sub:SetShown(lay.subLines > 0)
        row.sub:ClearAllPoints()
        row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)   -- (right under the name, however it wraps)
        row.sub:SetWidth(lay.textW)
        row.sub:SetWordWrap(lay.subLines > 1)
        row.sub:SetText(lay.sub)
        -- the right: one part in the middle, two stacked around it
        local n = #lay.right
        for i, part in ipairs(row.parts) do
            local e = lay.right[i]
            local y = n == 2 and (i == 1 and 9 or -9) or 0
            part.pill:ClearAllPoints()
            part.pill:SetPoint("RIGHT", row, "RIGHT", -CARD_X, y)
            part.text:ClearAllPoints()
            part.text:SetPoint("RIGHT", row, "RIGHT", -CARD_X, y)
            if e and e.pill then
                part.pill:SetPill(e.pill, e.text)
            elseif e then
                part.text:SetWidth(max(e.w, 1) + 2)
                part.text:SetText(e.text)
            end
        end
        row:SetSelected((state.selected ~= nil and id == state.selected) or d.hot == true)
        SetRowHover(row, row:IsMouseOver() and true or false)
    end
end

---------------------------------------------------------------------------
-- The item menu (right-click) and the + menu
---------------------------------------------------------------------------
do

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
                    tooltip:AddLine(("Phase %d and later"):format(from), S:RGB("GOLD"))
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
                    elseif not locked and not ClassicShown() then
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
end

---------------------------------------------------------------------------
-- The grid's rows
---------------------------------------------------------------------------

-- Does a page list something the filters let through? Show: My class / a spec: something my class can use (so a set
-- source lists my class's sets); a slot: something for that slot. Instant data only: the stats a spec is judged by
-- are left to the items.
local function PageVisible(page)
    local mode = ShowMode()
    if mode == "all" and state.slot == nil then return true end
    local A = Atlas()
    for _, id in ipairs(A:GetPageEntries(page, state.heroic)) do
        if type(id) == "number" and PassesSlot(id) and (mode == "all" or A:EntryUsable(id)) then return true end
    end
    return false
end

-- The pages a source shows under the filters.
local function VisiblePages(src)
    local out = {}
    if not src then return out end
    for i, page in ipairs(src.pages) do
        if PageVisible(page) then out[#out + 1] = { type = "page", page = page, index = i } end
    end
    return out
end

-- Item rows of a list of entries: headers kept only when an item follows them. After an item, what it turns into or
-- comes from (they work like any item): a token's pieces for my class (filtered like the page), a Sunwell drop's
-- Sunmote upgrade, a Sunmote item's base drop, what a recipe makes. kinds (optional) counts the kinds that pass the
-- other filters, for the chips.
local function EntryRows(entries, x, setPage, kinds)
    local rows, pendingHeader, count = {}, nil, 0
    local A = Atlas()
    for i, e in ipairs(entries) do
        if type(e) == "string" then
            pendingHeader = { type = "header", text = e }
        elseif type(e) == "number" and Passes(e) then
            local k = KindOf(e)
            if kinds then kinds[k] = (kinds[k] or 0) + 1 end
            if state.kind == nil or k == state.kind then
                if pendingHeader then
                    rows[#rows + 1] = pendingHeader
                    pendingHeader = nil
                end
                local item = { type = "item", id = e, x = type(x) == "table" and x[i] or nil, setPage = setPage }
                rows[#rows + 1] = item
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

-- Packs item rows into grid rows: `cols` tiles a row; a set's header or a note spans the grid. Adds to out (and to
-- flatRows, the item-level order).
local function Pack(rows, out)
    local cur
    local function flush()
        if cur then
            local h = CELL_MIN
            for _, c in ipairs(cur.cells) do h = max(h, Layout(c).h) end
            cur.h = h
            out[#out + 1] = cur
            cur = nil
        end
    end
    for _, r in ipairs(rows) do
        flatRows[#flatRows + 1] = r
        if r.type == "item" then
            cur = cur or { type = "cells", cells = {} }
            cur.cells[#cur.cells + 1] = r
            if #cur.cells >= cols then flush() end
        else
            flush()
            out[#out + 1] = r
        end
    end
    flush()
end

-- Every match of the search that passes the filters, and where they are from: { key, entries, facets = { { key,
-- name, count }, ... } } (facets in category order, "All" first). Cached until the search or a filter changes.
function SearchResults()
    local A = Atlas()
    local era = A:GetEra()
    local key = table.concat({ state.search, ShowMode(), tostring(state.slot), era }, "\0")
    if searchCache and searchCache.key == key then return searchCache end
    local entries, counts = {}, {}
    local found, other = A:Search(state.search)
    for _, loc in ipairs(found or {}) do
        if Passes(loc.id) then
            entries[#entries + 1] = { type = "item", id = loc.id, loc = loc }
            counts[loc.cat.key] = (counts[loc.cat.key] or 0) + 1
        end
    end
    local facets = { { key = nil, name = "All", count = #entries } }
    for _, cat in ipairs(A:GetCategories()) do
        if counts[cat.key] then facets[#facets + 1] = { key = cat.key, name = cat.name, count = counts[cat.key] } end
    end
    -- (the other era's matches: before the filters, which judge a page at a time)
    local otherEra = era == "classic" and "tbc" or "classic"
    if (other or 0) > 0 then
        facets[#facets + 1] = { key = ERA_FACET, era = otherEra, name = "In " .. A.ERA_NAMES[otherEra],
                                count = other }
    end
    searchCache = { key = key, entries = entries, facets = facets, other = other or 0, otherEra = otherEra,
                    places = A:SearchPlaces(state.search) or {} }
    return searchCache
end

-- The grid while searching: the places (both eras) first, then the items in one group per source.
local function SearchRows(out)
    local A = Atlas()
    local res = SearchResults()
    if state.facet == ERA_FACET then state.facet = nil end
    local facetOK = state.facet == nil
    for _, f in ipairs(res.facets) do
        if f.key ~= nil and f.key == state.facet then facetOK = true end
    end
    if not facetOK then state.facet = nil end
    hits = {}
    local places = (state.facet == nil) and res.places or {}
    if #places > 0 then
        out[#out + 1] = { type = "label", text = "Places" }
        for i, p in ipairs(places) do
            if i > PLACES_SHOWN then break end
            local d = { type = "place", place = p }
            hits[#hits + 1] = { place = p, row = d }
            out[#out + 1] = d
        end
    end
    -- the items, grouped by source in result order
    local groups, byKey = {}, {}
    local total = 0
    for _, e in ipairs(res.entries) do
        if state.facet == nil or e.loc.cat.key == state.facet then
            local k = e.loc.cat.key .. "\0" .. e.loc.src.key
            local g = byKey[k]
            if not g then
                g = { key = k, cat = e.loc.cat, src = e.loc.src, entries = {} }
                byKey[k] = g
                groups[#groups + 1] = g
            end
            g.entries[#g.entries + 1] = e
            total = total + 1
        end
    end
    if total > 0 and #places > 0 then
        out[#out + 1] = { type = "label", text = "Items" }
    end
    local drawn = 0
    for _, g in ipairs(groups) do
        if drawn >= MAX_SHOWN then break end
        local all = state.showSrc == g.key or #groups == 1 or state.facet ~= nil
        local n = all and #g.entries or min(#g.entries, GROUP_SHOWN)
        out[#out + 1] = { type = "srchead", group = g, count = #g.entries, more = (n < #g.entries) }
        local rows = {}
        for i = 1, n do
            if drawn >= MAX_SHOWN then break end
            rows[#rows + 1] = g.entries[i]
            hits[#hits + 1] = { item = g.entries[i] }
            drawn = drawn + 1
        end
        Pack(rows, out)
    end
    if total > drawn then
        local more = { type = "more",
            text = ("Showing the first %d of %d: type more of the name, or pick a category."):format(drawn, total) }
        flatRows[#flatRows + 1] = more
        out[#out + 1] = more
    end
    -- the cursor (↑ ↓): its result highlighted
    if state.cursor > #hits then state.cursor = #hits end
    if state.cursor < 1 then state.cursor = 1 end
    for i, h in ipairs(hits) do
        local hot = i == state.cursor
        if h.item then h.item.hot = hot else h.row.hot = hot end
    end
    return res, total
end

-- The category view: the recently viewed places of the category, then every place (Classic dungeons: the ones that
-- fit my level first, then all by level; raids by phase).
local function CategoryRows(out)
    local A = Atlas()
    local cat = A:GetCategory(state.cat)
    if not cat then return end
    local function tiles(list, label, sub)
        if #list == 0 then return end
        out[#out + 1] = { type = "label", text = label, sub = sub }
        for i = 1, #list, TILES_PER_ROW do
            local row = { type = "tiles", tiles = {} }
            for j = i, min(i + TILES_PER_ROW - 1, #list) do row.tiles[#row.tiles + 1] = { cat = cat, src = list[j] } end
            out[#out + 1] = row
        end
    end
    local recent = {}
    for _, r in ipairs(state.recent) do
        if r.cat == cat.key then recent[#recent + 1] = A:GetSource(r.cat, r.src) end
    end
    tiles(recent, "Recently viewed")
    local function lo(src) return tonumber((src.lv or ""):match("^(%d+)")) or 0 end
    local function hi(src) return tonumber((src.lv or ""):match("%-(%d+)$")) or lo(src) end
    local lv = UnitLevel and tonumber(UnitLevel("player")) or 70
    local all = {}
    for _, src in ipairs(cat.sources) do all[#all + 1] = src end
    if all[1] and all[1].lv then
        table.sort(all, function(a, b)
            if lo(a) ~= lo(b) then return lo(a) < lo(b) end
            return (a.name or "") < (b.name or "")
        end)
        if lv < 60 then
            local fit = {}
            for _, src in ipairs(all) do
                if lo(src) <= lv + 3 and hi(src) >= lv - 2 then fit[#fit + 1] = src end
            end
            tiles(fit, "Right for you", "level " .. lv)
        end
        tiles(all, "All " .. (cat.name or ""):lower(), "by level")
        return
    end
    local byPhase, phases = {}, {}
    for _, src in ipairs(all) do
        local p = tonumber(src.phase) or 0
        if not byPhase[p] then
            byPhase[p] = {}
            phases[#phases + 1] = p
        end
        local list = byPhase[p]
        list[#list + 1] = src
    end
    if #phases > 1 then
        table.sort(phases)
        for _, p in ipairs(phases) do tiles(byPhase[p], p > 0 and ("Phase " .. p) or (cat.name or "")) end
    else
        tiles(all, "All " .. (cat.name or ""):lower())
    end
end

-- A place's rows: one section per boss with its tiles (all its loot), or one page's tiles. kinds: the chips' counts.
local function ItemRows(out, kinds)
    local A = Atlas()
    local src = state.cat and A:GetSource(state.cat, state.src)
    if not src then return 0, nil, nil end
    local count = 0
    if state.view == "source" then
        local all = {}
        for _, pr in ipairs(VisiblePages(src)) do
            local page = pr.page
            local heroic = state.heroic and page.heroicItems ~= nil
            local plain = not state.heroic or not page.heroicItems
            local rows, n = EntryRows(A:GetPageEntries(page, heroic), plain and page.x or nil, false, kinds)
            if n > 0 then
                out[#out + 1] = { type = "section", page = page, count = n, stars = PickCount(page) }
                Pack(rows, out)
                for _, r in ipairs(rows) do all[#all + 1] = r end
                count = count + n
            end
        end
        return count, src, all
    end
    local page = A:GetPage(state.cat, state.src, state.page)
    if not page then return 0, src, {} end
    local heroic = state.heroic and page.heroicItems ~= nil
    local plain = not state.heroic or not page.heroicItems
    local rows, n = EntryRows(A:GetPageEntries(page, heroic), plain and page.x or nil, src.kind == "sets", kinds)
    Pack(rows, out)
    return n, src, rows, page
end

---------------------------------------------------------------------------
-- The grid's row frames
---------------------------------------------------------------------------
local GridExtent, InitGridRow
do

    local function Hide(...)
        for i = 1, select("#", ...) do
            local f = select(i, ...)
            if f then f:Hide() end
        end
    end

    function GridExtent(d)
        local t = d.type
        if t == "cells" then return d.h + CELL_GAP end
        if t == "section" then return SECTION_H end
        if t == "label" then return LABEL_H end
        if t == "place" then return PLACE_H + 2 end
        if t == "tiles" then return TILE_H + GAP end
        if t == "srchead" then return SRCHEAD_H + 4 end
        return Layout(d).h
    end

    -- A tile of a place (the category view): its art (or its icon on a card), name, levels / phase, my stars.
    local function SetupPlaceTile(t)
        local UI = ns.UI
        t:RegisterForClicks("LeftButtonUp")
        t.card = UI:Fill(t, "CARD")
        t.art = t:CreateTexture(nil, "BACKGROUND", nil, 1)
        t.art:SetPoint("TOPLEFT", 1, -1)
        t.art:SetPoint("BOTTOMRIGHT", -1, 1)
        t.shade = t:CreateTexture(nil, "BORDER")
        t.shade:SetPoint("TOPLEFT", 1, -1)
        t.shade:SetPoint("BOTTOMRIGHT", -1, 1)
        UI:Gradient(t.shade, "VERTICAL", { 0, 0, 0, 0.85 }, { 0, 0, 0, 0 })
        UI:AddEdges(t, "ARTWORK")
        t.icon = t:CreateTexture(nil, "ARTWORK")
        t.icon:SetSize(32, 32)
        t.icon:SetPoint("TOPLEFT", 8, -8)
        t.name = UI:Text(t, "emph", "TEXT", { shadow = true })
        t.name:SetPoint("BOTTOMLEFT", 9, 7)
        t.name:SetPoint("RIGHT", t, "RIGHT", -8, 0)
        t.tag = UI:CreatePill(t, nil, nil, 16)
        t.tag:SetPoint("TOPRIGHT", -6, -6)
        t.stars = UI:CreatePill(t, nil, nil, 16)
        t.stars:SetPoint("TOPLEFT", 6, -6)
        local hl = t:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(S:Color("HOVER"))
        t:SetScript("OnClick", function(self)
            if self.place then AtlasUI:OpenSource(self.place.cat.key, self.place.src.key) end
        end)
    end

    local function InitPlaceTile(t, p, w)
        if not t.card then SetupPlaceTile(t) end
        t.place = p
        t:SetSize(w, TILE_H)
        local src = p.src
        local file, l, r, tt, b = SourceArt(src, w, TILE_H, 0.9)
        t.art:SetShown(file ~= nil)
        t.shade:SetShown(file ~= nil)
        t.icon:SetShown(file == nil)
        if file then
            t.art:SetTexture(file)
            t.art:SetTexCoord(l, r, tt, b)
        else
            t.icon:SetTexture(SourceIcon(src, p.cat))
            t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        local here = state.cat == p.cat.key and state.src == src.key
        ns.UI:SetEdgeColor(t, S:Color(here and "GOLD" or "EDGE_QUIET"))
        t.name:SetText(src.name or "?")
        t.name:SetTextColor(S:Color(here and "GOLD" or "TEXT"))
        local tag = PhaseTag(src)
        t.tag:SetShown(tag ~= nil)
        if tag then t.tag:SetPill("mute", tag) end
        local n = SourceStars(src)
        t.stars:SetShown(n > 0)
        if n > 0 then t.stars:SetPill("bis", StarText(9) .. " " .. n) end
        t:Show()
    end

    -- One search result that is a place: its picture, name, where it is (a boss: its place), the era.
    local function InitPlaceRow(row, d)
        local UI = ns.UI
        local b = row.placeBtn
        if not b then
            b = CreateFrame("Button", nil, row)
            b:RegisterForClicks("LeftButtonUp")
            UI:DecorateRow(b, { selectable = true })
            b.thumb = b:CreateTexture(nil, "ARTWORK")
            b.thumb:SetSize(64, 34)
            b.thumb:SetPoint("LEFT", 4, 0)
            b.port = b:CreateTexture(nil, "ARTWORK", nil, 1)
            b.port:SetSize(64, 32)
            b.port:SetPoint("LEFT", 4, 0)
            b.name = UI:Text(b, "title", "TEXT")
            b.name:SetPoint("TOPLEFT", 78, -8)
            b.sub = UI:Text(b, "small", "SUB")
            b.sub:SetPoint("TOPLEFT", 78, -26)
            b.tag = UI:CreatePill(b, nil, nil, 16)
            b.tag:SetPoint("RIGHT", -10, 0)
            b:SetScript("OnClick", function(self)
                if self.place then AtlasUI:OpenPlace(self.place) end
            end)
            row.placeBtn = b
        end
        b:SetAllPoints(row)
        b:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 2)
        local p = d.place
        b.place = p
        local A = Atlas()
        local file, l, r, t, bb = SourceArt(p.src, 64, 34, 0.9)
        b.thumb:SetShown(p.page == nil and file ~= nil)
        if file then
            b.thumb:SetTexture(file)
            b.thumb:SetTexCoord(l, r, t, bb)
        end
        b.port:SetShown(p.page ~= nil)
        if p.page then b.port:SetTexture(PortraitOf(p.page)) end
        b.name:SetText(p.page and p.page.name or p.src.name)
        local where = {}
        if p.page then where[#where + 1] = p.src.name end
        where[#where + 1] = p.cat.name
        local sub = SourceSub(p.src)
        if sub ~= "" then where[#where + 1] = sub end
        b.sub:SetText(table.concat(where, DOT))
        b.sub:SetWidth(max(1, rowW.grid - 78 - 90))
        local otherEra = p.cat.era ~= A:GetEra()
        -- (the era only when it's the other one: opening it switches)
        b.tag:SetShown(otherEra)
        b.tag:SetPill("alt", A.ERA_NAMES[p.cat.era] or "")
        b:SetSelected(d.hot == true)
        b:Show()
    end

    -- A boss section in a place's view: the portrait (when the Journal has one), the name, how many items, my stars;
    -- the whole header opens the boss.
    local function InitSection(row, d)
        local UI = ns.UI
        local s = row.sec
        if not s then
            s = CreateFrame("Button", nil, row)
            s:RegisterForClicks("LeftButtonUp")
            s.rule = s:CreateTexture(nil, "ARTWORK")
            s.rule:SetHeight(1)
            s.rule:SetPoint("BOTTOMLEFT", 0, 4)
            s.rule:SetPoint("BOTTOMRIGHT", 0, 4)
            UI:Gradient(s.rule, "HORIZONTAL", { 1, 0.82, 0.35, 0.35 }, { 1, 0.82, 0.35, 0.03 })
            local hl = s:CreateTexture(nil, "HIGHLIGHT")
            hl:SetPoint("TOPLEFT", 0, -4)
            hl:SetPoint("BOTTOMRIGHT", 0, 5)
            UI:Gradient(hl, "HORIZONTAL", S:WithAlpha("GOLD", 0.08), S:WithAlpha("GOLD", 0))
            s.port = s:CreateTexture(nil, "ARTWORK")
            s.port:SetSize(56, 28)
            s.port:SetPoint("BOTTOMLEFT", 0, 6)
            s.title = UI:Text(s, "title", "GOLD", { shadow = true })
            s.count = UI:Text(s, "small", "SUB")
            s.count:SetPoint("LEFT", s.title, "RIGHT", 8, 0)
            s.stars = UI:Text(s, "small", "GOLD")
            s.stars:SetPoint("LEFT", s.count, "RIGHT", 8, 0)
            s.chev = s:CreateTexture(nil, "ARTWORK")
            s.chev:SetSize(10, 10)
            s.chev:SetPoint("BOTTOMRIGHT", -6, 12)
            UI:SetChevron(s.chev, true)
            s.chev:SetVertexColor(S:Color("GOLD"))
            s.hint = UI:Text(s, "small", "SUB", { text = "Open" })
            s.hint:SetPoint("RIGHT", s.chev, "LEFT", -4, 0)
            s.hint:Hide()
            s:SetScript("OnEnter", function(self) self.hint:Show() end)
            s:SetScript("OnLeave", function(self) self.hint:Hide() end)
            s:SetScript("OnClick", function(self)
                if self.page then AtlasUI:OpenPage(self.page.key) end
            end)
            row.sec = s
        end
        s:SetAllPoints(row)
        local page = d.page
        local tex, own = PortraitOf(page)
        s.port:SetShown(own)
        if own then s.port:SetTexture(tex) end
        s.title:ClearAllPoints()
        s.title:SetPoint("BOTTOMLEFT", own and 62 or 2, 10)
        s.title:SetText(page.name or "?")
        s.count:SetText(d.count == 1 and "1 item" or (d.count .. " items"))
        s.stars:SetText(d.stars > 0 and (StarText(10) .. " " .. d.stars) or "")
        s.page = page
        s:Show()
    end

    -- A label over a group (Places, Items, Recently viewed, Phase 2, Right for you · level 34).
    local function InitLabel(row, d)
        local UI = ns.UI
        if not row.lab then
            row.lab = UI:Text(row, "emph", "GOLD", { shadow = true })
            row.labSub = UI:Text(row, "small", "SUB")
            row.labSub:SetPoint("LEFT", row.lab, "RIGHT", 8, 0)
        end
        row.lab:ClearAllPoints()
        row.lab:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2, 6)
        row.lab:SetText(d.text or "")
        local sub = d.sub or ((d.count and d.count > 0) and tostring(d.count) or "")
        row.labSub:SetText(sub)
        row.lab:Show()
        row.labSub:Show()
    end

    -- Search: a source's group header (its art as a band, its name, where, the count, "Show all ›").
    local function InitSrcHead(row, d)
        local UI = ns.UI
        local h = row.srch
        if not h then
            h = CreateFrame("Frame", nil, row)
            h.card = UI:Fill(h, "CARD")
            h.art = h:CreateTexture(nil, "BACKGROUND", nil, 1)
            h.art:SetPoint("TOPLEFT", 1, -1)
            h.art:SetPoint("BOTTOMRIGHT", -1, 1)
            h.shade = h:CreateTexture(nil, "BORDER")
            h.shade:SetPoint("TOPLEFT", 1, -1)
            h.shade:SetPoint("BOTTOMRIGHT", -1, 1)
            UI:Gradient(h.shade, "HORIZONTAL", { 0, 0, 0, 0.85 }, { 0, 0, 0, 0.35 })
            UI:AddEdges(h, "ARTWORK")
            UI:SetEdgeColor(h, S:Color("EDGE_QUIET"))
            h.icon = h:CreateTexture(nil, "ARTWORK")
            h.icon:SetSize(20, 20)
            h.icon:SetPoint("LEFT", 8, 0)
            h.title = UI:Text(h, "title", "GOLD", { shadow = true })
            h.title:SetPoint("LEFT", 34, 0)
            h.sub = UI:Text(h, "small", "TEXT", { shadow = true })
            h.sub:SetPoint("LEFT", h.title, "RIGHT", 8, 0)
            h.all = UI:CreateSleekButton(h, "Show all", 80, 18, function(self)
                state.showSrc = self.key
                AtlasUI:RefreshItems(false)
            end)
            h.all:SetPoint("RIGHT", -8, 0)
            h.count = UI:CreatePill(h, nil, nil, 16)
            row.srch = h
        end
        h:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
        h:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 2)
        local g = d.group
        local file, l, r, t, b = SourceArt(g.src, floor(rowW.grid), SRCHEAD_H, 0.95)
        h.art:SetShown(file ~= nil)
        h.shade:SetShown(file ~= nil)
        if file then
            h.art:SetTexture(file)
            h.art:SetTexCoord(l, r, t, b)
        end
        h.icon:SetTexture(SourceIcon(g.src, g.cat))
        h.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        h.title:SetText(g.src.name or "?")
        h.sub:SetText(g.cat.name or "")
        h.all.key = g.key
        h.all:SetShown(d.more)
        if d.more then h.all:SetText("Show all " .. d.count .. " ›") end
        h.count:Hide()
        h:Show()
    end

    -- A set's header or the "showing the first ..." note (spanning the grid).
    local function InitWide(row, d)
        local UI = ns.UI
        if not row.header then
            row.header = UI:Text(row, "emph", "GOLD")
            if row.header.SetMaxLines then row.header:SetMaxLines(2) end
            row.headCost = UI:Text(row, "small", "TEXT", { justify = "RIGHT" })
            row.headCost:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -IN, 8)
        end
        local lay = Layout(d)
        row.header:ClearAllPoints()
        if d.type == "more" then
            ns.UI:SetTextStyle(row.header, "small", "DIM")
            row.header:SetWordWrap(true)
            row.header:SetPoint("LEFT", row, "LEFT", IN, 0)
            row.header:SetWidth(rowW.grid - 2 * IN)
        else
            ns.UI:SetTextStyle(row.header, "emph", "GOLD")
            row.header:SetWordWrap((lay.headLines or 1) > 1)
            row.header:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", IN, 7)
            row.header:SetWidth(lay.headW or (rowW.grid - 2 * IN))
        end
        row.header:SetText(d.text or "")
        row.header:Show()
        row.headCost:SetShown(lay.cost ~= nil)
        row.headCost:SetText(lay.cost or "")
        row.headCost:SetWidth(max((lay.costW or 0) - 12, 1) + 2)
    end

    function InitGridRow(row, d)
        row:EnableMouse(false)
        Hide(row.sec, row.placeBtn, row.lab, row.labSub, row.srch, row.header, row.headCost)
        for _, c in ipairs(row.cells or {}) do c:Hide() end
        for _, t in ipairs(row.tiles or {}) do t:Hide() end
        local t = d.type
        if t == "cells" then
            row.cells = row.cells or {}
            for i, cd in ipairs(d.cells) do
                local c = row.cells[i]
                if not c then
                    c = CreateFrame("Button", nil, row)
                    row.cells[i] = c
                end
                c.__cdlData = cd
                c:ClearAllPoints()
                c:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (rowW.item + CELL_GAP), 0)
                cd.cellH = d.h
                c:SetSize(rowW.item, d.h)
                InitItemRow(c, cd)
                c:Show()
            end
        elseif t == "tiles" then
            row.tiles = row.tiles or {}
            local w = floor((rowW.grid - (TILES_PER_ROW - 1) * GAP) / TILES_PER_ROW)
            for i, p in ipairs(d.tiles) do
                local tile = row.tiles[i]
                if not tile then
                    tile = CreateFrame("Button", nil, row)
                    row.tiles[i] = tile
                end
                tile:ClearAllPoints()
                tile:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (w + GAP), 0)
                InitPlaceTile(tile, p, w)
            end
        elseif t == "section" then
            InitSection(row, d)
        elseif t == "label" then
            InitLabel(row, d)
        elseif t == "place" then
            InitPlaceRow(row, d)
        elseif t == "srchead" then
            InitSrcHead(row, d)
        else
            InitWide(row, d)
        end
    end
end

---------------------------------------------------------------------------
-- The banner over a place or a page
---------------------------------------------------------------------------
local CreateHero, FillHero
do

    local DOT_W, DOT_ON_W, DOT_GAP = 7, 18, 5

    function CreateHero(parent)
        local UI = ns.UI
        local h = CreateFrame("Frame", nil, parent)
        h:SetHeight(HERO_H)
        h.plain = UI:Fill(h, "CARD")
        h.art = h:CreateTexture(nil, "BACKGROUND", nil, 1)
        h.art:SetPoint("TOPLEFT", 1, -1)
        h.art:SetPoint("BOTTOMRIGHT", -1, 1)
        h.shade = h:CreateTexture(nil, "BORDER")
        h.shade:SetPoint("TOPLEFT", 1, -1)
        h.shade:SetPoint("BOTTOMRIGHT", -1, 1)
        UI:Gradient(h.shade, "HORIZONTAL", { 0, 0, 0, 0.82 }, { 0, 0, 0, 0.12 })
        h.foot = h:CreateTexture(nil, "BORDER", nil, 1)
        h.foot:SetPoint("BOTTOMLEFT", 1, 1)
        h.foot:SetPoint("BOTTOMRIGHT", -1, 1)
        h.foot:SetHeight(30)
        UI:Gradient(h.foot, "VERTICAL", { 0, 0, 0, 0.55 }, { 0, 0, 0, 0 })
        UI:AddEdges(h, "ARTWORK")
        UI:SetEdgeColor(h, S:Color("EDGE"))
        h.port = h:CreateTexture(nil, "ARTWORK", nil, 1)
        h.port:SetSize(PORTRAIT_W, PORTRAIT_W / 2)
        h.port:SetPoint("BOTTOMLEFT", 1, 1)
        h.icon = h:CreateTexture(nil, "ARTWORK", nil, 1)
        h.icon:SetSize(46, 46)
        h.icon:SetPoint("LEFT", 16, 0)
        h.kicker = UI:Text(h, "caps", "GOLD", { shadow = true })
        h.title = UI:Text(h, "hero", "GOLD", { shadow = true })
        h.sub = UI:Text(h, "small", "TEXT", { shadow = true })
        h.stars = UI:CreatePill(h, nil, nil, 18)
        h.stars:SetPoint("TOPRIGHT", -10, -10)
        -- the bosses as dots: a click opens one (a place's view: jumps to its section)
        h.dots = CreateFrame("Frame", nil, h)
        h.dots:SetHeight(12)
        h.dotPool = {}
        -- ‹ › step to the boss before / after
        h.prev = UI:CreateSleekButton(h, "‹", 120, 22, function(self) if self.page then AtlasUI:OpenPage(self.page.key) end end)
        h.next = UI:CreateSleekButton(h, "›", 120, 22, function(self) if self.page then AtlasUI:OpenPage(self.page.key) end end)
        h.next:SetPoint("BOTTOMRIGHT", -10, 10)
        h.prev:SetPoint("RIGHT", h.next, "LEFT", -6, 0)
        -- Normal / Heroic (a TBC dungeon)
        h.diff = UI:CreateSegments(h, { { key = "normal", label = "Normal" }, { key = "heroic", label = "Heroic" } },
            function(key) AtlasUI:SetHeroic(key == "heroic") end, { h = 20, look = "pill" })
        -- a crafting place: the guild's crafters of its profession
        h.who = CreateFrame("Frame", nil, h)
        h.who:SetSize(10, 22)
        h.who:SetPoint("BOTTOMRIGHT", -10, 10)
        h.whoLabel = UI:Text(h.who, "small", "TEXT", { shadow = true, text = "Guild crafters" })
        h.whoPool = {}
        return h
    end

    -- A place without a loading screen of its own (a profession, a vendor, a faction): its world's, dimmed.
    local WORLD_ART = { tbc = "Interface\\Glues\\LoadingScreens\\LoadScreenOutland",
                        classic = "Interface\\Glues\\LoadingScreens\\LoadScreenEasternKingdom" }

    local function SetHeroArt(src, w)
        local file, l, r, t, b = SourceArt(src, w, HERO_H, 0.95)
        local own = file ~= nil
        if not own then
            file = WORLD_ART[Atlas():GetEra()] or WORLD_ART.tbc
            local fh = 0.95 * (4 / 3) * (HERO_H / w)
            l, r, t, b = 0.025, 0.975, 0.5 - fh / 2, 0.5 + fh / 2
        end
        hero.art:Show()
        hero.plain:Hide()
        hero.art:SetTexture(file)
        hero.art:SetTexCoord(l, r, t, b)
        local v = own and 1 or 0.45
        hero.art:SetVertexColor(v, v, v)
    end

    -- The dots of a place's bosses (the one open wide and gold; gold-ish where I have BiS picks).
    local function FillDots(src, pages, x, y)
        local d = hero.dots
        d:ClearAllPoints()
        d:SetPoint("BOTTOMLEFT", hero, "BOTTOMLEFT", x, y)
        local xx = 0
        for i, pr in ipairs(pages) do
            local b = hero.dotPool[i]
            if not b then
                b = CreateFrame("Button", nil, d)
                b.tex = b:CreateTexture(nil, "ARTWORK")
                b.tex:SetPoint("CENTER")
                b:SetScript("OnClick", function(self)
                    if state.view == "source" then
                        AtlasUI:JumpToSection(self.page)
                    else
                        AtlasUI:OpenPage(self.page.key)
                    end
                end)
                ns.UI:AttachTooltip(b, function(self, tt)
                    tt:AddLine(self.page and self.page.name or "?", S:RGB("GOLD"))
                    local n = PickCount(self.page)
                    if n > 0 then tt:AddLine(n == 1 and "1 item here is on your BiS list" or (n .. " items here are on your BiS list"), 1, 1, 1) end
                end)
                hero.dotPool[i] = b
            end
            b.page = pr.page
            local on = state.view == "page" and pr.page.key == state.page
            local w = on and DOT_ON_W or DOT_W
            b:SetSize(w + DOT_GAP, 12)
            b.tex:SetSize(w, DOT_W)
            b.tex:SetTexture(on and "Interface\\Buttons\\WHITE8X8" or "Interface\\CharacterFrame\\TempPortraitAlphaMask")
            if on then
                b.tex:SetVertexColor(S:Color("GOLD"))
            elseif PickCount(pr.page) > 0 then
                b.tex:SetVertexColor(S:Color(S:WithAlpha("GOLD", 0.6)))
            else
                b.tex:SetVertexColor(1, 1, 1, 0.3)
            end
            b:ClearAllPoints()
            b:SetPoint("LEFT", d, "LEFT", xx, 0)
            b:Show()
            xx = xx + w + DOT_GAP
        end
        for i = #pages + 1, #hero.dotPool do hero.dotPool[i]:Hide() end
        d:SetWidth(max(1, xx))
        d:SetShown(#pages > 1)
    end

    local function FillCrafters(prof)
        local list = GuildCrafters(prof, 3)
        hero.who:SetShown(#list > 0)
        if #list == 0 then return end
        local UI = ns.UI
        local x = 0
        for i = #list, 1, -1 do
            local c = list[i]
            local chip = hero.whoPool[i]
            if not chip then
                chip = UI:CreateChip(hero.who, { kind = "plain" })
                hero.whoPool[i] = chip
            end
            local cf = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(c.key)
            local text = (ns.Util.ShortName(c.key) or c.key) .. " " .. S:Wrap("SUB", tostring(c.skill))
            if cf then
                chip:Set(text, nil, cf)
            else
                chip:Set(text, c.online and S.C.OK or S.C.DIM)
            end
            chip:SetAlpha(c.online and 1 or 0.7)
            chip:ClearAllPoints()
            chip:SetPoint("RIGHT", hero.who, "RIGHT", -x, 0)
            chip:Show()
            x = x + chip:GetWidth() + 6
        end
        for i = #list + 1, #hero.whoPool do hero.whoPool[i]:Hide() end
        hero.whoLabel:ClearAllPoints()
        hero.whoLabel:SetPoint("RIGHT", hero.who, "RIGHT", -x - 2, 0)
    end

    -- Fills the banner for the view: a place (all its loot) or a page. Returns false when there is none (category,
    -- search, shop).
    function FillHero(src, page, extraNote)
        local A = Atlas()
        local w = hero:GetWidth()
        w = (w and w > 1) and w or BODY_W
        SetHeroArt(src, w)
        local bosses = HasBosses(src)
        local onPage = state.view == "page" and page ~= nil
        local portrait = onPage and bosses
        hero.port:SetShown(portrait)
        if portrait then hero.port:SetTexture(PortraitOf(page)) end
        local prof = ProfessionOf(src)
        hero.icon:SetShown(prof ~= nil)
        if prof then
            hero.icon:SetTexture(prof.icon)
            hero.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        local x = portrait and (PORTRAIT_W + 8) or (prof and 74 or 16)
        -- the texts
        local kicker, title, sub
        local pages = VisiblePages(src)
        if onPage then
            local idx = 0
            for i, pr in ipairs(pages) do
                if pr.page.key == page.key then idx = i end
            end
            title = page.title or page.name or ""
            if bosses then
                kicker = src.name
            else
                kicker = src.name
            end
            local note = {}
            local where = SourceSub(src)
            if where ~= "" then note[#note + 1] = where end
            if page.phase and page.phase ~= (src.phase or 1) then note[#note + 1] = "Phase " .. page.phase end
            if page.title and page.name then note[#note + 1] = page.name end
            if extraNote then note[#note + 1] = extraNote end
            sub = table.concat(note, DOT)
            -- ‹ › (a source with pages)
            local prev, nxt = pages[idx - 1], pages[idx + 1]
            hero.prev:SetShown(#pages > 1 and prev ~= nil)
            hero.next:SetShown(#pages > 1 and nxt ~= nil)
            hero.prev.page, hero.next.page = prev and prev.page, nxt and nxt.page
            if prev then hero.prev:SetText("‹  " .. (prev.page.name or "")) end
            if nxt then hero.next:SetText((nxt.page.name or "") .. "  ›") end
            for _, b in ipairs({ hero.prev, hero.next }) do
                local fs = b:GetFontString()
                local w = min(170, ceil((fs and fs:GetStringWidth() or 60)) + 22)
                b:SetWidth(w)
                if fs and (fs:GetStringWidth() or 0) > w - 22 then ns.UI:FitText(fs, fs:GetText(), w - 22) end
            end
        else
            hero.prev:Hide()
            hero.next:Hide()
            title = src.name or ""
            local parts = {}
            if src.size then parts[#parts + 1] = src.size .. " players" end
            if src.lv then parts[#parts + 1] = "Levels " .. src.lv end
            local p = tonumber(src.phase)
            if p then parts[#parts + 1] = "Phase " .. p end
            if bosses then parts[#parts + 1] = #src.pages .. " bosses" end
            kicker = table.concat(parts, DOT)
            if kicker == "" then kicker = (A:GetCategory(state.cat) or {}).name end
            sub = extraNote
        end
        hero.kicker:ClearAllPoints()
        hero.kicker:SetPoint("TOPLEFT", hero, "TOPLEFT", x, -16)
        hero.kicker:SetText((kicker or ""):upper())
        hero.kicker:SetShown((kicker or "") ~= "")
        hero.title:ClearAllPoints()
        hero.title:SetPoint("TOPLEFT", hero, "TOPLEFT", x, -30)
        hero.title:SetText(title)
        hero.sub:ClearAllPoints()
        hero.sub:SetPoint("TOPLEFT", hero, "TOPLEFT", x, -54)
        hero.sub:SetText(sub or "")
        hero.sub:SetShown((sub or "") ~= "")
        -- the boss dots: under the title on a page, at the foot of a place's banner
        local showDots = bosses and #pages > 1
        if showDots then
            FillDots(src, pages, x, (sub and sub ~= "") and 8 or 12)
        else
            hero.dots:Hide()
        end
        -- my stars over the place / the page
        local n = onPage and PickCount(page) or SourceStars(src)
        hero.stars:SetShown(n > 0)
        if n > 0 then
            hero.stars:SetPill("bis", StarText(10) .. " " .. n .. " on your BiS list")
        end
        -- Normal / Heroic
        local heroic = A:HasHeroic(src)
        hero.diff:SetShown(heroic)
        if heroic then
            hero.diff:ClearAllPoints()
            hero.diff:SetPoint("TOPRIGHT", hero, "TOPRIGHT", n > 0 and -(hero.stars:GetWidth() + 18) or -10, -9)
            hero.diff:Select(state.heroic and "heroic" or "normal")
        end
        -- a crafting place: who in the guild makes it
        if prof and not onPage then
            FillCrafters(prof)
        elseif prof then
            FillCrafters(prof)
            hero.who:SetShown(hero.who:IsShown() and not (hero.next:IsShown() or hero.prev:IsShown()))
        else
            hero.who:Hide()
        end
        hero:Show()
    end
end

---------------------------------------------------------------------------
-- The chips row: kinds / categories, "For me ▾", the slot
---------------------------------------------------------------------------
local CreateChipsRow, FillChips, KindChips, FacetChips
do

    local function ShowLabel()
        local mode = ShowMode()
        for _, o in ipairs(Atlas():GetShowOptions()) do
            if o.value == mode then return o.text end
        end
        return "All items"
    end

    local function SlotText()
        for _, o in ipairs(SlotOptions()) do
            if o.value == state.slot then return o.text end
        end
        return "Any slot"
    end

    function CreateChipsRow(parent)
        local UI = ns.UI
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(CTRL_H)
        r.left = {}
        r.forMe = UI:CreateChip(r, { kind = "plain", text = "For me", menu = true, onClick = function(self)
            UI:ContextMenu(self, function(root)
                root:CreateTitle("Show")
                for _, o in ipairs(Atlas():GetShowOptions()) do
                    root:CreateRadio(o.text, function(v) return ShowMode() == v end, function(v)
                        SetShowMode(v)
                        searchCache = nil
                        AtlasUI:RefreshItems(true)
                    end, o.value)
                end
            end)
        end })
        r.forMe:SetIcon(ns.UI:Tex("star"))
        r.slot = UI:CreateChip(r, { kind = "plain", text = "Any slot", menu = true, onClick = function(self)
            UI:ContextMenu(self, function(root)
                for _, o in ipairs(SlotOptions()) do
                    local b = root:CreateRadio(o.text, function(v) return state.slot == (v ~= "any" and v or nil) end,
                        function(v)
                            state.slot = v ~= "any" and v or nil
                            searchCache = nil
                            AtlasUI:RefreshItems(true)
                        end, o.value == nil and "any" or o.value)
                    if o.tooltip and b and b.SetTooltip then
                        b:SetTooltip(function(tt) tt:AddLine(o.tooltip, 1, 1, 1, true) end)
                    end
                end
            end)
        end })
        r.slot:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        r.forMe:SetPoint("RIGHT", r.slot, "LEFT", -6, 0)
        return r
    end

    -- items: { { key, text, count, selected, onClick, info } ... } on the left.
    function FillChips(items)
        local UI = ns.UI
        local r = chipsRow
        local x = 0
        for i, it in ipairs(items) do
            local c = r.left[i]
            if not c then
                c = UI:CreateChip(r, { kind = "plain", onClick = function(self) if self.onPick then self.onPick() end end })
                r.left[i] = c
            end
            c.onPick = it.onClick
            c:SetLook(it.info and "you" or "plain")
            c:Set(it.text .. ((it.count and it.count > 0) and ("  " .. S:Wrap("SUB", tostring(it.count))) or ""))
            c:SetSelected(it.selected and true or false)
            c:ClearAllPoints()
            c:SetPoint("LEFT", r, "LEFT", x, 0)
            c:Show()
            x = x + c:GetWidth() + 6
        end
        for i = #items + 1, #r.left do r.left[i]:Hide() end
        local mode = ShowMode()
        r.forMe:Set(mode == "all" and "For me" or ShowLabel())
        r.forMe:SetSelected(mode ~= "all")
        r.slot:Set(SlotText())
        r.slot:SetSelected(state.slot ~= nil)
        r:Show()
    end

    function KindChips(kinds)
        local present, total = {}, 0
        for _, k in ipairs(KINDS) do
            if (kinds[k.key] or 0) > 0 then
                present[#present + 1] = k
                total = total + kinds[k.key]
            end
        end
        local items = {}
        if #present < 2 then return items end
        items[1] = { text = "All", count = total, selected = state.kind == nil, onClick = function()
            state.kind = nil
            AtlasUI:RefreshItems(true)
        end }
        for _, k in ipairs(present) do
            items[#items + 1] = { text = k.name, count = kinds[k.key], selected = state.kind == k.key, onClick = function()
                state.kind = (state.kind == k.key) and nil or k.key
                AtlasUI:RefreshItems(true)
            end }
        end
        return items
    end

    function FacetChips(res)
        local items = {}
        for _, f in ipairs(res.facets) do
            if f.key == ERA_FACET then
                items[#items + 1] = { text = f.name, count = f.count, info = true, onClick = function()
                    AtlasUI:SetEra(f.era)
                end }
            elseif res.facets[1].count > 0 then
                items[#items + 1] = { text = f.name, count = f.count, selected = state.facet == f.key, onClick = function()
                    state.facet = f.key
                    state.showSrc = nil
                    state.cursor = 1
                    AtlasUI:RefreshItems(true)
                end }
            end
        end
        return items
    end
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

-- The grid's empty state: the illustrated one (title + text) and, under it, the same text as the plain line.
local function ItemsEmpty(title, text)
    grid:SetEmptyText(text)
    local same = text == title or text == title .. "."
    grid:SetEmptyState({ glyph = ns.UI.ICON.notes, title = title, text = (not same) and text or nil })
end

-- While my BiS lists are locked (§38) a notice above the page says why the + buttons are gone (display only:
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

local function ShowingShop()
    return state.view == "shop" and not IsSearching() and ns.AtlasShopUI ~= nil
end

-- Places the grid under what is shown above it (the banner, the chips).
local function PlaceGrid(top)
    grid.frame:ClearAllPoints()
    grid.frame:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, -top)
    grid.frame:SetPoint("BOTTOMRIGHT", panel.body, "BOTTOMRIGHT", 0, 0)
end

local function BodyW()
    local w = panel and panel.body and panel.body:GetWidth()
    return (w and w > 1) and w or BODY_W
end

function AtlasUI:RefreshItems(resetScroll)
    if not grid then return end
    if Nav() then Nav():Update() end
    if ShowingShop() then
        hero:Hide()
        chipsRow:Hide()
        grid.frame:Hide()
        if ns.AtlasShopUI then ns.AtlasShopUI:Show() end
        barKeys = {}
        LayoutBar()
        return
    end
    if ns.AtlasShopUI then ns.AtlasShopUI:Hide() end
    grid.frame:Show()
    local A = Atlas()
    RefreshMarks()
    wantCache = {}
    layCache = {}
    flatRows = {}
    listLocked = ns.UI:IsMyListLocked() and true or false
    UpdateLockNotice()
    rowW.grid = BodyW() - BAR_SPACE
    local out = {}
    local top = 0
    local itemRows = {}
    if IsSearching() then
        hero:Hide()
        cols = 2
        rowW.item = floor((rowW.grid - (cols - 1) * CELL_GAP) / cols)
        local res, total = SearchRows(out)
        FillChips(FacetChips(res))
        chipsRow:ClearAllPoints()
        chipsRow:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, 0)
        chipsRow:SetPoint("TOPRIGHT", panel.body, "TOPRIGHT", -BAR_SPACE, 0)
        top = CTRL_H + GAP
        for _, r in ipairs(flatRows) do itemRows[#itemRows + 1] = r end
        if total == 0 and #(res.places or {}) == 0 and res.other > 0 then
            ItemsEmpty("Not in " .. A.ERA_NAMES[A:GetEra()], ("%d %s in %s: pick \"In %s\" above.")
                :format(res.other, res.other == 1 and "match" or "matches", A.ERA_LONG[res.otherEra],
                        A.ERA_NAMES[res.otherEra]))
        else
            ItemsEmpty("No matches", Filtered()
                and "Nothing matches with these filters. Try For me: All items, or Any slot."
                or "No item or place has that name.")
        end
    elseif state.view == "category" then
        hero:Hide()
        chipsRow:Hide()
        CategoryRows(out)
        ItemsEmpty("Nothing here", "Nothing here.")
    else
        local src = state.cat and A:GetSource(state.cat, state.src)
        -- two columns when the page lists costs (they take the tile's right)
        cols = 2
        if src and state.view == "page" then
            local page = A:GetPage(state.cat, state.src, state.page)
            -- (two columns everywhere: a card has room for its name on one line and its cost / status)
        end
        rowW.item = floor((rowW.grid - (cols - 1) * CELL_GAP) / cols)
        local kinds = {}
        local count, _, rows, page = ItemRows(out, kinds)
        itemRows = rows or {}
        if src then
            local note = src.kind == "sets" and state.view == "page" and SetTotals(itemRows) or nil
            FillHero(src, page, note or nil)
            top = HERO_H + GAP
            FillChips(KindChips(kinds))
            chipsRow:ClearAllPoints()
            chipsRow:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, -top)
            chipsRow:SetPoint("TOPRIGHT", panel.body, "TOPRIGHT", -BAR_SPACE, -top)
            top = top + CTRL_H + GAP
            ItemsEmpty("Nothing here", Filtered()
                and "Nothing here passes the filters. Try For me: All items, Any slot, or All."
                or "Nothing here.")
        else
            hero:Hide()
            chipsRow:Hide()
            ItemsEmpty("Pick a place", "Pick a place from the path at the top.")
        end
        if count == 0 then out = {} end
    end
    local even = CELL_MIN
    for _, r in ipairs(out) do
        if r.type == "cells" then even = max(even, r.h) end
    end
    even = min(even, CELL_MAX)
    for _, r in ipairs(out) do
        if r.type == "cells" then r.h = max(even, r.h) end
    end
    PlaceGrid(top)
    grid:SetData(out, resetScroll)
    Prefetch(itemRows)
    barKeys = ContextKeys(itemRows)
    LayoutBar()
end

function AtlasUI:Refresh()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    panel.dirty = false
    if not state.cat and state.view ~= "shop" then
        local cat, src = Atlas():DefaultSource()
        if cat then
            SelectSource(cat, src)
            return
        end
    end
    self:RefreshItems()
end

-- Opens a place: a raid / dungeon on all its loot (or at a page), another source at a page (the first with something
-- for my class: a set source opens on my class's set).
function SelectSource(catKey, srcKey, pageKey)
    local A = Atlas()
    local src = A:GetSource(catKey, srcKey)
    if not src then return end
    -- (a place in the other era: the switch follows)
    local era = A:EraOf(catKey)
    if era and era ~= A:GetEra() then A:SetEra(era) end
    state.cat, state.src = catKey, srcKey
    if not A:HasHeroic(src) then state.heroic = false end
    local page = pageKey and A:GetPage(catKey, srcKey, pageKey)
    if not page and OpensOnAll(src) then
        state.view = "source"
        state.page = nil
    else
        if not page then
            for _, p in ipairs(src.pages) do
                if A:PageUsable(p, state.heroic) then
                    page = p
                    break
                end
            end
        end
        state.view = "page"
        state.page = page and page.key or (src.pages[1] and src.pages[1].key)
    end
    state.selected = nil
    state.kind = nil
    NoteRecent(catKey, srcKey, state.heroic)
    AtlasUI:RefreshItems(true)
end

---------------------------------------------------------------------------
-- Moving around (the path's drop-downs, search results, other tabs)
---------------------------------------------------------------------------

local function ClearSearch()
    if toast then toast:Hide() end      -- (the shopping list's note is about the page I leave)
    if searchBox and (searchBox:GetText() or "") ~= "" then searchBox:SetText("") end
    if searchBox then searchBox:ClearFocus() end
    state.search = ""
    state.facet = nil
    state.showSrc = nil
    state.cursor = 1
end

function AtlasUI:OpenSource(catKey, srcKey, pageKey, heroic)
    if heroic ~= nil then state.heroic = heroic and true or false end
    ClearSearch()
    if Nav() then Nav():Close() end
    SelectSource(catKey, srcKey, pageKey)
end

-- One page of the open place (a boss, a class, a standing).
function AtlasUI:OpenPage(pageKey)
    if Nav() then Nav():Close() end
    ClearSearch()
    if pageKey == nil then
        SelectSource(state.cat, state.src, nil)
        return
    end
    state.view = "page"
    state.page = pageKey
    state.selected = nil
    state.kind = nil
    self:RefreshItems(true)
end

-- All the place's loot again (a raid's / dungeon's "All bosses").
function AtlasUI:OpenAll()
    if Nav() then Nav():Close() end
    ClearSearch()
    state.view = "source"
    state.page = nil
    state.kind = nil
    self:RefreshItems(true)
end

-- A place's view scrolled to a boss's section.
function AtlasUI:JumpToSection(page)
    if not (grid and page) then return end
    for i, d in ipairs(grid:GetData()) do
        if d.type == "section" and d.page == page then
            if grid.box.ScrollToElementDataIndex then
                grid.box:ScrollToElementDataIndex(i, ScrollBoxConstants and ScrollBoxConstants.AlignBegin)
            end
            return
        end
    end
end

-- A category as art tiles.
function AtlasUI:OpenCategory(catKey)
    local A = Atlas()
    if not A:GetCategory(catKey) then return end
    if Nav() then Nav():Close() end
    ClearSearch()
    local era = A:EraOf(catKey)
    if era and era ~= A:GetEra() then A:SetEra(era) end
    state.view = "category"
    state.cat = catKey
    self:RefreshItems(true)
end

-- A search result that is a place: the place (all its loot), or a boss's page.
function AtlasUI:OpenPlace(p)
    if type(p) ~= "table" or not (p.cat and p.src) then return end
    self:OpenSource(p.cat.key, p.src.key, p.page and p.page.key or nil)
end

function AtlasUI:SetHeroic(on)
    state.heroic = on and true or false
    NoteRecent(state.cat, state.src, state.heroic)
    self:RefreshItems(true)
end

-- Opens the page of a search result (or any location from Atlas:GetLocations) and highlights the item.
function AtlasUI:GoTo(loc)
    if type(loc) ~= "table" or not (loc.cat and loc.src and loc.page) then return end
    ClearSearch()
    state.heroic = loc.heroic and true or false
    SelectSource(loc.cat.key, loc.src.key, loc.page.key)
    state.selected = loc.id
    self:RefreshItems(true)
    -- scroll the item into view (a piece of another class or spec isn't listed: its token is)
    local shown = false
    for _, r in ipairs(flatRows) do
        if r.type == "item" and r.id == loc.id then shown = true break end
    end
    if not shown and loc.via then
        state.selected = loc.via
        grid:Refresh()
    end
    for i, r in ipairs(grid:GetData()) do
        local hit = false
        for _, c in ipairs(r.type == "cells" and r.cells or {}) do
            if c.id == state.selected then hit = true end
        end
        if hit then
            if grid.box and grid.box.ScrollToElementDataIndex then
                grid.box:ScrollToElementDataIndex(i, ScrollBoxConstants and ScrollBoxConstants.AlignCenter)
            end
            break
        end
    end
end

-- Opens the shopping list (groupId: "all" (default), "you", "nobody", "bop" or a member's key).
function AtlasUI:OpenShop(groupId)
    if Nav() then Nav():Close() end
    ClearSearch()
    state.view = "shop"
    state.selected = nil
    if ns.AtlasShopUI and groupId then ns.AtlasShopUI:GetState().group = groupId end
    if not panel then return end
    self:RefreshItems(true)
end

-- Opens the Atlas tab at an item (e.g. from a chat command): its first location.
function AtlasUI:ShowItem(itemID)
    local A = Atlas()
    local locs = A:GetLocations(itemID)
    if not locs then return false end
    if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("atlas") end
    local pick = locs[1]
    for _, loc in ipairs(locs) do
        if loc.cat.era == A:GetEra() then pick = loc break end
    end
    self:GoTo(pick)
    return true
end

-- Classic | TBC. Where I was in the era I leave is kept for coming back; the other opens where I last was there,
-- else at its default (Classic: the dungeon for my level). A search stays, now over that era.
function AtlasUI:SetEra(e)
    local A = Atlas()
    if not A:HasEra(e) then return end
    local cur = A:GetEra()
    if e == cur then return end
    if state.cat and state.view ~= "shop" then
        state.places[cur] = { cat = state.cat, src = state.src, page = state.page, heroic = state.heroic,
                              view = state.view }
    end
    A:SetEra(e)
    state.facet = nil
    state.selected = nil
    state.showSrc = nil
    searchCache = nil
    if IsSearching() or state.view == "shop" then
        local place = state.places[e]
        if place then state.cat, state.src, state.page, state.view = place.cat, place.src, place.page, place.view end
        if state.view == "shop" then
            state.cat = nil
        end
        self:RefreshItems(true)
        return
    end
    local place = state.places[e]
    if place and A:GetSource(place.cat, place.src) then
        state.heroic = place.heroic and true or false
        if place.view == "source" then
            SelectSource(place.cat, place.src, nil)
        else
            SelectSource(place.cat, place.src, place.page)
        end
    elseif place and place.view == "category" and A:GetCategory(place.cat) then
        self:OpenCategory(place.cat)
    else
        local cat, src = A:DefaultSource()
        state.cat = nil
        if cat then SelectSource(cat, src) end
    end
end

---------------------------------------------------------------------------
-- The search field: ↑ ↓ through the results, Enter opens, Shift+Enter adds to my BiS list, Esc leaves
---------------------------------------------------------------------------

local function CursorTo(i)
    if #hits == 0 then return end
    state.cursor = max(1, min(#hits, i))
    for j, h in ipairs(hits) do
        local hot = j == state.cursor
        if h.item then h.item.hot = hot else h.row.hot = hot end
    end
    grid:Refresh()
    -- scroll the cursor's row into view
    local target = hits[state.cursor]
    for i2, r in ipairs(grid:GetData()) do
        local hit = (target.row and r == target.row)
        for _, c in ipairs(r.type == "cells" and r.cells or {}) do
            if target.item and c == target.item then hit = true end
        end
        if hit then
            if grid.box.ScrollToElementDataIndex then
                grid.box:ScrollToElementDataIndex(i2, ScrollBoxConstants and ScrollBoxConstants.AlignNearest)
            end
            break
        end
    end
end

local function OpenCursor(addToBiS)
    local h = hits[state.cursor]
    if not h then return false end
    if h.place then
        if addToBiS then return false end
        AtlasUI:OpenPlace(h.place)
        return true
    end
    if addToBiS then
        local owner
        grid.box:ForEachFrame(function(row)
            for _, c in ipairs(row.cells or {}) do
                if c:IsShown() and c.__cdlData == h.item then owner = c end
            end
        end)
        ShowAddMenu(owner or panel, h.item)
        return true
    end
    AtlasUI:GoTo(h.item.loc)
    return true
end

local function SetupSearchKeys(eb)
    eb:SetScript("OnArrowPressed", function(_, key)
        if not IsSearching() then return end
        if key == "UP" then CursorTo(state.cursor - 1) elseif key == "DOWN" then CursorTo(state.cursor + 1) end
    end)
    eb:SetScript("OnEnterPressed", function(self)
        if IsSearching() then
            OpenCursor(IsShiftKeyDown())
        else
            self:ClearFocus()
        end
    end)
    eb:SetScript("OnEscapePressed", function()
        ClearSearch()
        AtlasUI:RefreshItems(true)
    end)
    eb:HookScript("OnEditFocusGained", function() if Nav() then Nav():SetSearching(true) end end)
    eb:HookScript("OnEditFocusLost", function()
        if Nav() and not IsSearching() then Nav():SetSearching(false) end
    end)
end

---------------------------------------------------------------------------
-- The note after adding a craft to my shopping list
---------------------------------------------------------------------------

local function CreateToast(parent)
    local UI = ns.UI
    local t = CreateFrame("Frame", nil, parent)
    t:SetHeight(32)
    t:SetFrameLevel(parent:GetFrameLevel() + 30)
    t.bg = UI:Fill(t, "DROP_BG")
    UI:AddEdges(t, "BORDER")
    UI:SetEdgeColor(t, S:Color("OK"))
    t.text = UI:Text(t, "body", "TEXT")
    t.text:SetPoint("LEFT", 12, 0)
    t.undo = UI:CreateSleekButton(t, "Undo", 54, 20, function()
        if t.id and ns.Shop then ns.Shop:Remove(t.id) end
        t:Hide()
    end)
    t.open = UI:CreateSleekButton(t, "Open list ›", 84, 20, function()
        t:Hide()
        AtlasUI:OpenShop()
    end, "primary")
    t.open:SetPoint("RIGHT", -6, 0)
    t.undo:SetPoint("RIGHT", t.open, "LEFT", -6, 0)
    function t:Layout()
        local w = ceil(self.text:GetStringWidth() or 200) + 12 + 12 + 54 + 6 + 84 + 6
        self:SetWidth(w)
    end
    t:SetScript("OnUpdate", function(self, el)
        if self.left then
            self.left = self.left - (el or 0)
            if self.left <= 0 and not self:IsMouseOver() then
                self.left = nil
                self:Hide()
            end
        end
    end)
    t:Hide()
    return t
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function AtlasUI:CreatePanel(parent)
    if panel then return panel end
    local UI = ns.UI
    panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints(parent)
    -- (a board: the toolbar row holds the path (UI/AtlasNav.lua), the search and the bag; the body the banner, the
    -- chips and the grid; the currency bar sits in the layout's bottom margin)
    layout = UI:CreateLayout("board", panel, { bottom = BOTTOM })
    panel.layout = layout
    local bar = layout.toolbar
    LoadRecent()

    searchBox = UI:CreateSearchBox(bar, 150, function(text)
        state.search = text or ""
        state.selected = nil
        state.facet = nil
        state.showSrc = nil
        state.cursor = 1
        if Nav() then Nav():SetSearching(IsSearching() or (searchBox and searchBox:HasFocus())) end
        AtlasUI:RefreshItems(true)
    end, "Search  (Ctrl+F)")
    searchBox:SetHeight(CTRL_H)
    SetupSearchKeys(searchBox)
    panel.searchBox = searchBox

    panel.body = layout.body
    hero = CreateHero(panel.body)
    hero:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, 0)
    hero:SetPoint("TOPRIGHT", panel.body, "TOPRIGHT", -BAR_SPACE, 0)   -- (its right edge = the tiles')
    hero:Hide()
    panel.hero = hero
    chipsRow = CreateChipsRow(panel.body)
    chipsRow:Hide()
    panel.chips = chipsRow

    grid = UI:CreateScrollList(panel.body, 60, InitGridRow, GridExtent)
    grid.frame:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, 0)
    grid.frame:SetPoint("BOTTOMRIGHT", panel.body, "BOTTOMRIGHT", 0, 0)
    grid.box:ClearAllPoints()
    grid.box:SetPoint("TOPLEFT", grid.frame, "TOPLEFT", 0, 0)
    grid.box:SetPoint("BOTTOMRIGHT", grid.frame, "BOTTOMRIGHT", -BAR_SPACE, 0)
    grid.bar:ClearAllPoints()
    grid.bar:SetPoint("TOPLEFT", grid.box, "TOPRIGHT", 4, 0)
    grid.bar:SetPoint("BOTTOMLEFT", grid.box, "BOTTOMRIGHT", 4, 0)
    panel.grid = grid

    curBar = CreateCurrencyBar(panel)
    curBar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, PAD)
    curBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, PAD)
    panel.currencyBar = curBar

    toast = CreateToast(panel)
    toast:SetPoint("BOTTOM", panel, "BOTTOM", 0, PAD + BAR_H + 6)
    panel.toast = toast

    -- the path of drop-downs on the toolbar's left, the search and the bag on its right
    if Nav() then Nav():Create(panel, bar, searchBox) end

    -- the shopping list: the body while it's open
    if ns.AtlasShopUI then
        ns.AtlasShopUI:Create({ TextWidth = TextWidth, CodedWidth = CodedWidth, NameText = NameText,
                                BODY_W = BODY_W }, panel.body)
    end

    -- Ctrl+F: the search (every other key goes on to the game)
    panel:EnableKeyboard(true)
    if panel.SetPropagateKeyboardInput then panel:SetPropagateKeyboardInput(true) end
    panel:SetScript("OnKeyDown", function(self, key)
        if key == "F" and IsControlKeyDown() and not InCombatLockdown() then
            self:SetPropagateKeyboardInput(false)
            searchBox:SetFocus()
            C_Timer.After(0, function()
                if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
            end)
        end
    end)

    panel:SetScript("OnShow", function(self)
        if self.dirty then AtlasUI:Refresh() end
    end)
    panel.OnPanelShown = function(self)
        if self.dirty then AtlasUI:Refresh() end
    end
    panel.dirty = true
    return panel
end

---------------------------------------------------------------------------
-- For the path (UI/AtlasNav.lua), tests and the UI audit
---------------------------------------------------------------------------

function AtlasUI:GetState()
    return state
end

function AtlasUI:GetPanel() return panel end
AtlasUI.SourceArt = function(_, ...) return SourceArt(...) end
AtlasUI.PortraitOf = function(_, page) return PortraitOf(page) end
AtlasUI.CatIcon = function(_, cat) return CatIcon(cat) end
AtlasUI.SourceIcon = function(_, src, cat) return SourceIcon(src, cat) end
AtlasUI.PhaseTag = function(_, src) return PhaseTag(src) end
AtlasUI.SourceStars = function(_, src) return SourceStars(src) end
AtlasUI.PickCount = function(_, page) return PickCount(page) end
AtlasUI.HasBosses = function(_, src) return HasBosses(src) end
AtlasUI.OpensOnAll = function(_, src) return OpensOnAll(src) end
AtlasUI.StarText = function(_, size) return StarText(size) end
AtlasUI.VisiblePages = function(_, src) return VisiblePages(src) end
function AtlasUI:IsSearching() return IsSearching() end

function AtlasUI:SetSearch(text, facet)
    if toast then toast:Hide() end
    if searchBox then searchBox:SetText(text or "") end
    state.search = text or ""
    state.selected = nil
    state.facet = facet
    state.showSrc = nil
    state.cursor = 1
    if Nav() then Nav():SetSearching(IsSearching()) end
    self:RefreshItems(true)
end

-- Moves the search's cursor / opens what it is on (tests, the UI audit): delta, or "enter" / "shift-enter".
function AtlasUI:SearchKey(key)
    if key == "enter" then return OpenCursor(false) end
    if key == "shift-enter" then return OpenCursor(true) end
    CursorTo(state.cursor + (tonumber(key) or 0))
end

function AtlasUI:Select(catKey, srcKey, pageKey, heroic)
    self:OpenSource(catKey, srcKey, pageKey, heroic)
end

function AtlasUI:SetSlotFilter(sid)
    state.slot = sid
    searchCache = nil
    self:RefreshItems(true)
end

function AtlasUI:SetKind(kind)
    state.kind = kind
    self:RefreshItems(true)
end

-- The lists the old three-column Atlas had, as views over the new page (tests): the places of the open category
-- (cat / src rows), its pages or the search's categories (page / facet rows), and the items (item / header / more
-- rows; .box:GetFrames() / ForEachFrame give the item tiles).
local function ListView(getData, frames)
    local v = {}
    function v:GetData() return getData() end
    v.box = {
        GetFrames = function() return frames() end,
        ForEachFrame = function(_, fn) for _, f in ipairs(frames()) do fn(f) end end,
        ScrollToElementDataIndex = function() end,
    }
    function v:Refresh() if grid then grid:Refresh() end end
    return v
end

local srcView, pageView, itemView
function AtlasUI:GetLists()
    if not srcView then
        srcView = ListView(function()
            local rows = {}
            for _, cat in ipairs(Atlas():GetCategories()) do
                local open = cat.key == state.cat
                rows[#rows + 1] = { type = "cat", cat = cat, expanded = open }
                if open then
                    for _, src in ipairs(cat.sources) do rows[#rows + 1] = { type = "src", cat = cat, src = src } end
                end
            end
            return rows
        end, function() return {} end)
        pageView = ListView(function()
            if IsSearching() then
                local res = SearchResults()
                local rows = {}
                for _, f in ipairs(res.facets) do
                    if res.facets[1].count > 0 or f.key == ERA_FACET then
                        rows[#rows + 1] = { type = "facet", key = f.key, name = f.name, count = f.count, era = f.era }
                    end
                end
                return rows
            end
            local src = state.cat and Atlas():GetSource(state.cat, state.src)
            return VisiblePages(src)
        end, function() return {} end)
        -- (shown: the source has more than one page, so the path has a page part)
        pageView.frame = { IsShown = function()
            local src = state.cat and Atlas():GetSource(state.cat, state.src)
            return src ~= nil and #src.pages > 1
        end }
        itemView = ListView(function() return flatRows end, function()
            local out = {}
            if grid then
                grid.box:ForEachFrame(function(row)
                    for _, c in ipairs(row.cells or {}) do
                        if c:IsShown() then out[#out + 1] = c end
                    end
                    -- (a set's header, a note: the grid's own row)
                    local d = row.__cdlData
                    if d and (d.type == "header" or d.type == "more") then out[#out + 1] = row end
                end)
            end
            return out
        end)
    end
    if grid then
        itemView.emptyText = grid.emptyText
        itemView.frame = grid.frame
    end
    return srcView, pageView, itemView
end

-- Opens the item menu (right-click) / the + button's menu of a tile's data (tests, the UI audit).
function AtlasUI:OpenMenu(d, owner)
    ShowItemMenu(owner or panel, d)
end

function AtlasUI:OpenAddMenu(d, owner)
    ShowAddMenu(owner or panel, d)
end

-- Shows a tile as hovered (its hover buttons), for the UI audit.
function AtlasUI:HoverItem(itemID)
    if not grid then return end
    grid.box:ForEachFrame(function(row)
        for _, c in ipairs(row.cells or {}) do
            local d = c.__cdlData
            if c:IsShown() and d and d.type == "item" and d.id == itemID then SetRowHover(c, true) end
        end
    end)
end

-- The "added to your shopping list" note (the UI audit).
function AtlasUI:ShowShopNote(id) ShowShopToast(id) end

---------------------------------------------------------------------------
-- Registration & messages
---------------------------------------------------------------------------

if ns.MainFrame and ns.MainFrame.RegisterTab then
    ns.MainFrame:RegisterTab("atlas", "Atlas", 1.5, function(parent) return AtlasUI:CreatePanel(parent) end, nil,
        { layout = "board" })
end

-- The grid a moment later (the stars, marks and names).
local function RefreshLater(sec)
    Debounce("atlas-items", sec, function()
        if not panel:IsVisible() then
            panel.dirty = true
            return
        end
        AtlasUI:RefreshItems()
    end)
end

-- My list / the council's lists changed: the marks, the + buttons and the star counts.
local function RequestItems()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    RefreshLater(0.05)
end

-- Item names / stats arrived: names may need other line breaks, and the spec filter may judge more items now.
local function ItemInfoReady()
    if not (panel and panel:IsVisible() and grid) then return end
    local mode = ShowMode()
    if mode == "spec" or mode == "os" then searchCache = nil end
    RefreshLater(0.1)
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
-- my shopping list changed: its count on the bag, the bag marks on the tiles
ns:On("SHOP_UPDATED", function()
    if not panel then return end
    if Nav() then Nav():Update() end
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
