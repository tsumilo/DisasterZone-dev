if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Wardrobe.lua", ...) then return end -- DisasterZone UI/Wardrobe.lua
-- Gear > Wardrobe (ns.WardrobeUI): the outfits of Core/Wardrobe.lua. Mockup dev/art/casc/wardrobe_mockup (the user
-- approved it 2026-10-13). The outfits on the left (art rows: the rule in words, a status pill) with the quick-swap
-- bar's card at their foot; the picked one on the right: a hero banner (Wear, its More menu), block tabs Outfit /
-- Wear automatically, the 17-slot doll previewing the swap (gold = swaps in, orange + a bank mark = in the bank, red
-- + a cross = missing, dim = keep current) with what Wear will do in the 18th cell, and the rules. A tile opens the
-- slot picker (bags, bank, worn, Keep current). The quick-swap bar is a HUD frame in the class bars' faces
-- (UI/BarFace.lua, setting classbar.theme) that Edit layout moves; a click wears an outfit.
local addonName, ns = ...

local WUI = ns:NewModule("WardrobeUI")

local UI, S = ns.UI, ns.Style
local floor, max = math.floor, math.max
local function W() return ns.Wardrobe end

local PAD, GAP = S.PAD or 10, S.GAP or 8
local LIST_W = 262
local DETAIL_W = S.INNER_W - LIST_W - GAP          -- 500
local BODY_W = DETAIL_W                            -- the detail body, no inner margin of its own
local TILE_H, TILE_GAP = 34, 3
local COL_W = floor((BODY_W - GAP) / 2)
local QUICK_H = 76
local PICK_W = 286
local GOLD = { 1, 0.82, 0 }
local ORANGE = { 1, 0.55, 0.1 }
local RED = { 0.95, 0.3, 0.26 }
local I = "Interface\\Icons\\"
local EMPTY_ICON = {
    [16] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-MainHand",
    [17] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-SecondaryHand",
    [18] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Relic",
}

local state = { sel = nil, tab = "outfit" }
local view

-- (the demo's items the item cache may not name)
local NAMES = { [33820] = "Weather-Beaten Fishing Hat", [19970] = "Arcanite Fishing Pole",
    [29508] = "Living Dragonscale Helm", [31364] = "Wildguard Breastplate", [31367] = "Wildguard Leggings",
    [30538] = "Midnight Legguards" }
local function nameOf(id)
    local n = ns.ItemDB and ns.ItemDB.GetName and ns.ItemDB:GetName(id)
    if not n and ns.Data and ns.Data.AtlasNames then n = ns.Data.AtlasNames[id] end
    if not n and GetItemInfo then n = GetItemInfo(id) end
    return NAMES[id] or n or ("item " .. tostring(id))
end
local function iconOf(id)
    local t = ns.ItemDB and ns.ItemDB.GetIcon and ns.ItemDB:GetIcon(id)
    if not t and GetItemIcon then t = GetItemIcon(id) end
    return t or 134400
end
local function qcolor(id)
    local q = ns.ItemDB and ns.ItemDB.GetQuality and ns.ItemDB:GetQuality(id)
    if not q then q = (id == 19970 or id == 33820) and 3 or 4 end
    return UI:QualityColor(q)
end
local function hex(col) return ("|cff%02x%02x%02x"):format(col[1] * 255, col[2] * 255, col[3] * 255) end

-- An outfit's pill: Wearing (green), n missing (red), n in bank (orange), or none.
local function status(o)
    local _, c = W():Status(o)
    if W():IsWorn(o) then return "ok", "Wearing" end
    if c.missing > 0 then return "bad", c.missing .. " missing" end
    if c.bank > 0 then return "warn", c.bank .. " in bank" end
    return nil
end

local function Selected()
    local list = W():List()
    local o = state.sel and W():Get(state.sel)
    if not o then
        o = W():Wearing() or list[1]
        state.sel = o and o.id
    end
    return o
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------
local function newRow(parent, i)
    local r = UI:CreateArtRow(parent, { width = LIST_W, selectable = true })
    r:SetWidth(LIST_W)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * S.ROW.art)
    r.stat = UI:CreatePill(r, 16)
    r.stat:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -8, 8)
    r:SetScript("OnClick", function(self, button)
        WUI:Select(self.key)
        if button == "RightButton" then WUI:OutfitMenu(self) end
    end)
    return r
end

local function fillRow(r, o)
    r.key = o.id
    r:SetData({ art = o.art, icon = o.icon, title = o.name, sub = W():RuleText(o) })
    r.title:SetTextColor(S:Color("TEXT"))
    local kind, text = status(o)
    if text then r.stat:SetPill(kind, text); r.stat:Show() else r.stat:Hide() end
    -- (a long rule gives way to the pill: just what kind of rule it is)
    if text and r.sub:GetStringWidth() > LIST_W - r.textX - r.stat:GetWidth() - 16 then
        local n = W():RuleCount(o)
        r.sub:SetText(n == 1 and "1 rule" or (n .. " rules"))
    end
    r:SetSelected(o.id == state.sel)
    r:Show()
end

---------------------------------------------------------------------------
-- The doll (tiles in the doll's flat look: a dark tile, the icon in a ring of the slot's state colour)
---------------------------------------------------------------------------
-- a slot's state: its edge (the icon's ring and the tile's 1 px edge), a mark on the icon's corner, the tooltip line
local LOOK = {
    swap    = { edge = GOLD,   tip = "Swaps in when you wear this outfit" },
    bank    = { edge = ORANGE, mark = "bank", tip = "In your bank: Wear takes it out while the bank is open" },
    missing = { edge = RED,    mark = "x",    tip = "Not on this character (bags, bank or worn)" },
    keep    = { tip = "Keep current: Wear never touches this slot" },
    worn    = { tip = "Already worn" },
}

local function TileEnter(t)
    GameTooltip:SetOwner(t, "ANCHOR_RIGHT")
    if t.itemID then
        GameTooltip:SetHyperlink("item:" .. (t.itemKey or t.itemID))   -- the saved copy: its enchant and gems
    else
        GameTooltip:AddLine(W().SLOT_NAME[t.inv] or "", 1, 1, 1)
    end
    if t.tip then GameTooltip:AddLine(t.tip, 1, 0.82, 0, true) end
    GameTooltip:AddLine("Click to pick another item or Keep current.", 0.6, 0.6, 0.62, true)
    GameTooltip:Show()
end

local function newTile(parent)
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(COL_W, TILE_H)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    UI:AddEdges(t, "BORDER")
    t.icon = UI:CreateIconTile(t, TILE_H - 8)
    t.icon:SetPoint("LEFT", 4, 0)
    t.mark = CreateFrame("Frame", nil, t)
    t.mark:SetSize(14, 14)
    t.mark:SetPoint("CENTER", t.icon, "BOTTOMRIGHT", -2, 3)
    t.mark:SetFrameLevel(t:GetFrameLevel() + 4)
    t.mark.bg = t.mark:CreateTexture(nil, "ARTWORK")
    t.mark.bg:SetAllPoints()
    t.mark.glyph = t.mark:CreateTexture(nil, "OVERLAY")
    t.mark.glyph:SetPoint("TOPLEFT", 2, -2)
    t.mark.glyph:SetPoint("BOTTOMRIGHT", -2, 2)
    t.name = UI:Text(t, "body", "TEXT", { wrap = true, width = COL_W - TILE_H - 12 })
    t.name:SetPoint("LEFT", t.icon, "RIGHT", 8, 0)
    if t.name.SetMaxLines then t.name:SetMaxLines(2) end
    t:SetScript("OnClick", function(self) WUI:OpenPicker(self) end)
    t:SetScript("OnEnter", TileEnter)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return t
end

local function fillTile(t, inv, s)
    local look = LOOK[s.st] or LOOK.worn
    t.inv = inv
    local id = s.id
    t.itemID = id
    t.itemKey = id and (s.key or (s.want and s.want.key)) or nil
    if id then
        t.icon:Set(iconOf(id))
        t.name:SetText(nameOf(id))
        t.name:SetTextColor(qcolor(id))
    else
        t.icon:Set(EMPTY_ICON[inv] or "Interface\\PaperDoll\\UI-PaperDoll-Slot-SecondaryHand")
        t.name:SetText(W().SLOT_NAME[inv] .. (s.empty and s.st == "swap" and ": taken off" or ": empty"))
        t.name:SetTextColor(S:Color("SUB"))
    end
    local e = look.edge
    if e then
        t.icon.outer:SetColorTexture(e[1], e[2], e[3], 1)
        t.bg:SetColorTexture(e[1] * 0.025 + 0.075, e[2] * 0.025 + 0.075, e[3] * 0.025 + 0.08, 0.95)
        UI:SetEdgeColor(t, e[1], e[2], e[3], 0.3)
    else
        t.icon.outer:SetColorTexture(0, 0, 0, 1)
        t.bg:SetColorTexture(0.075, 0.075, 0.085, 0.9)
        UI:SetEdgeColor(t, 1, 1, 1, 0.05)
    end
    if look.mark then
        t.mark.bg:SetColorTexture(e[1] * 0.35, e[2] * 0.35, e[3] * 0.35, 1)
        if look.mark == "x" then
            t.mark.glyph:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
            t.mark.glyph:SetTexCoord(0, 1, 0, 1)
            t.mark.glyph:SetVertexColor(1, 1, 1)
        else
            local c = UI:IconCoords(UI.ICON.bank)
            t.mark.glyph:SetTexture(UI.ICON_ATLAS)
            t.mark.glyph:SetTexCoord(c[1], c[2], c[3], c[4])
            t.mark.glyph:SetVertexColor(e[1], e[2], e[3])
        end
        t.mark:Show()
    else
        t.mark:Hide()
    end
    t.tip = look.tip
    t:SetAlpha(s.st == "keep" and 0.4 or 1)
    t.icon.tex:SetDesaturated(s.st == "keep")
end

---------------------------------------------------------------------------
-- Wear automatically
---------------------------------------------------------------------------
local function MyClass()
    if W().IsDemo() then return "PALADIN" end
    return UnitClass and select(2, UnitClass("player")) or nil
end

local function SpecIcon(label)
    for _, s in ipairs(ns.SPECS and ns.SPECS[MyClass() or ""] or {}) do
        if s.label == label and s.icon then return s.icon end
    end
    return I .. "Spell_Holy_AuraOfLight"
end

local RULES = {
    { key = "spec", title = "When I switch spec", sub = "Your talents changed, by hand or with a dual-spec swap",
      icon = function(o) return SpecIcon(o.rules and o.rules.spec) end,
      value = function(o) return o.rules.spec or "Pick a spec" end },
    { key = "boss", icon = 136356, title = "At a boss or in a zone",
      sub = "Before the pull when you target it; back after the kill",
      value = function(o)
          local b = o.rules.boss
          if not b then return "Choose" end
          return b.name
      end },
    { key = "pole", icon = I .. "Trade_Fishing", title = "When I equip a fishing pole",
      sub = "Back to what you wore when the pole comes off" },
    { key = "mount", icon = I .. "Ability_Mount_Charger", title = "While mounted",
      sub = "A riding-speed trinket or boots while you ride; back on landing" },
}

local function SpecMenu(o, root)
    for _, s in ipairs(ns.SPECS and ns.SPECS[MyClass() or ""] or {}) do
        local b = root:CreateButton(s.label, function() W():SetRule(o.id, "spec", s.label) end)
        if b.SetChecked and o.rules.spec == s.label then b:SetChecked(true) end
    end
end

local function BossMenu(o, root)
    local t = UnitName and UnitExists and UnitExists("target") and UnitName("target")
    if t then
        root:CreateButton("My target: " .. t, function() W():SetRule(o.id, "boss", { kind = "boss", name = t }) end)
    end
    local z = GetRealZoneText and GetRealZoneText() or ""
    if z ~= "" then
        root:CreateButton("This zone: " .. z, function() W():SetRule(o.id, "boss", { kind = "zone", name = z }) end)
    end
    root:CreateButton("Type a boss name\226\128\166", function()
        ns.Popup:Prompt({ title = "Wear it at a boss", text = "The boss's name, as it shows when you target it.",
            default = o.rules.boss and o.rules.boss.kind == "boss" and o.rules.boss.name or "", maxLetters = 60,
            trim = true, validate = function(v) return v ~= "" end,
            onAccept = function(v) W():SetRule(o.id, "boss", { kind = "boss", name = v }) end })
    end)
end

local function newRule(parent, i, d)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(BODY_W, 46)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * 50 - 6)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(0.085, 0.085, 0.095, 0.9)
    UI:AddEdges(r, "BORDER")
    UI:SetEdgeColor(r, 1, 1, 1, 0.06)
    r.icon = UI:CreateIconTile(r, 30)
    r.icon:SetPoint("LEFT", 8, 0)
    r.title = UI:Text(r, "emph", "TEXT")
    r.title:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 10, 0)
    r.sub = UI:Text(r, "small", "SUB")
    r.sub:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 10, 0)
    r.sw = UI:CreateSwitch(r, function() return r.on end, function(v) WUI:ToggleRule(d.key, v) end)
    r.sw:SetPoint("RIGHT", -10, 0)
    if d.value then
        r.val = UI:CreateSleekButton(r, "", 110, 22, function(b)
            local o = Selected()
            if not o then return end
            UI:ContextMenu(b, function(root)
                if d.key == "spec" then SpecMenu(o, root) else BossMenu(o, root) end
            end)
        end)
        r.val:SetPoint("RIGHT", r.sw, "LEFT", -10, 0)
    end
    return r
end

local function fillRule(r, d, o)
    local ic = d.icon
    r.icon:Set(type(ic) == "function" and ic(o) or ic)
    r.title:SetText(d.title)
    r.sub:SetText(d.sub)
    r.on = o.rules and o.rules[d.key] ~= nil or false
    r.sw:SetChecked(r.on)
    if r.val then
        r.val:SetText(d.value(o) .. "  " .. UI:AtlasIconText(UI.ICON.chevron, 9))
    end
    r.title:SetTextColor(S:Color(r.on and "TEXT" or "SUB"))
end

-- A rule's switch: on with its value (spec: the one I play now; boss: my target, else this zone), or off.
function WUI:ToggleRule(key, on)
    local o = Selected()
    if not o then return end
    local v
    if on then
        if key == "spec" then
            v = (not W().IsDemo() and ns.BiS and ns.BiS.DetectSpec and ns.BiS:DetectSpec()) or ""
            if v == "" then
                local specs = ns.SPECS and ns.SPECS[MyClass() or ""]
                v = specs and specs[1] and specs[1].label or nil
            end
        elseif key == "boss" then
            local t = UnitExists and UnitExists("target") and UnitName("target")
            if t then v = { kind = "boss", name = t }
            else v = { kind = "zone", name = GetRealZoneText and GetRealZoneText() or "" } end
            if v.name == "" then v = nil end
        else
            v = true
        end
    end
    W():SetRule(o.id, key, v)
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local function SaveWorn()
    if not W():CanAdd() then return end
    local spec = (not W().IsDemo()) and ns.BiS and ns.BiS.DetectSpec and ns.BiS:DetectSpec() or ""
    ns.Popup:Prompt({ title = "Save what I'm wearing", text = "A name for the new outfit.",
        default = W().UniqueName(spec ~= "" and spec or "My gear"), maxLetters = 40, trim = true,
        validate = function(v) return v ~= "" end,
        onAccept = function(v)
            local o = W():SaveWorn(v)
            if o then WUI:Select(o.id) end
        end })
end

local function SaveBiS()
    local o = W():CanAdd() and W():SaveBiS(ns.MyBiS and ns.MyBiS.GetPhase and ns.MyBiS:GetPhase() or 1)
    if o then WUI:Select(o.id)
    else ns:Print("%s", W():CanAdd() and "Your BiS list has no picks yet." or "The wardrobe is full.") end
end

local function EditLayout()
    if ns.MainFrame then ns.MainFrame:Close() end
    if ns.EditMode and ns.EditMode.Open then ns.EditMode:Open() end
end

function WUI:CreatePanel(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints(parent)
    view = v
    WUI.view = v
    local L = UI:CreateLayout("listdetail", v, { listWidth = LIST_W, width = S.PAGE_W,
        banner = { size = "hero", artFw = 0.95, artUnder = true },
        tabs = { { key = "outfit", text = "Outfit" }, { key = "auto", text = "Wear automatically" } },
        onTab = function(key) WUI:SetTab(key) end })
    v.layout = L
    L.toolbar:SetText("Swaps wait until you are out of combat")
    L.toolbar:SetPrimary({ text = "Save what I'm wearing", icon = UI.ICON.plus, width = 178, onClick = SaveWorn,
        tip = { "Save what I'm wearing", "A new outfit of the 17 slots you have on now." } })
    L.toolbar:SetMore(function(root)
        root:CreateButton("Save my BiS list as an outfit", SaveBiS)
        root:CreateButton(W():BarOn() and "Hide the quick-swap bar" or "Show the quick-swap bar",
            function() W():SetBar(not W():BarOn()) end)
        root:CreateButton("Move the bar (Edit layout)", EditLayout)
    end)

    -- outfit rows
    v.rows = {}
    for i = 1, W().MAX do v.rows[i] = newRow(L.list, i) end

    -- the quick-swap bar card at the list's foot
    local qc = UI:CreateCard(L.list, { tone = "inset", width = LIST_W, height = QUICK_H })
    qc:SetPoint("BOTTOMLEFT", L.list, "BOTTOMLEFT", 0, 0)
    qc.t = UI:Text(qc, "emph", "TEXT", { text = "Quick-swap bar" })
    qc.t:SetPoint("TOPLEFT", 12, -10)
    qc.sw = UI:CreateSwitch(qc, function() return W():BarOn() end, function(on) W():SetBar(on) end)
    qc.sw:SetPoint("TOPRIGHT", -10, -8)
    qc.icons = {}
    for i = 1, W().MAX do
        local b = UI:CreateIconTile(qc, 26)
        b:SetPoint("BOTTOMLEFT", 12 + (i - 1) * 32, 12)
        qc.icons[i] = b
    end
    qc.note = UI:Text(qc, "small", "SUB", { text = "Move it in Edit layout" })
    qc.note:SetPoint("BOTTOMRIGHT", -12, 18)
    v.quick = qc

    -- the banner
    v.banner = L.banner
    v.banner.wearAct = { { text = "Wear", kind = "primary", width = 96,
        onClick = function() local o = Selected(); if o then W():Wear(o.id) end end,
        tip = { "Wear this outfit", "Swaps the gold slots now (after combat if you are fighting)." } } }
    v.banner.moreTools = { { icon = "more", title = "More", menu = function(root) WUI:FillOutfitMenu(root) end } }

    -- the Outfit tab body
    local body = CreateFrame("Frame", nil, L.body)
    body:SetPoint("TOPLEFT", 0, 0)
    body:SetSize(BODY_W, 380)
    v.body = body
    body.tiles = {}
    for i = 1, #W().SLOTS do
        local t = newTile(body)
        local col, row = (i <= 9) and 0 or 1, (i <= 9) and (i - 1) or (i - 10)
        t:SetPoint("TOPLEFT", col * (COL_W + GAP), -GAP - row * (TILE_H + TILE_GAP))
        body.tiles[i] = t
    end
    -- the 18th cell (right column, last row): what Wear will do, in the slots' own colours
    local sc = CreateFrame("Frame", nil, body)
    sc:SetSize(COL_W, TILE_H)
    sc:SetPoint("TOPLEFT", COL_W + GAP, -GAP - 8 * (TILE_H + TILE_GAP))
    sc.l1 = UI:Text(sc, "body", "TEXT")
    sc.l1:SetPoint("TOPLEFT", 10, -4)
    sc.l2 = UI:Text(sc, "body", "SUB")
    sc.l2:SetPoint("BOTTOMLEFT", 10, 4)
    body.sum = sc

    -- the rules tab body
    local auto = CreateFrame("Frame", nil, L.body)
    auto:SetPoint("TOPLEFT", 0, 0)
    auto:SetSize(BODY_W, 380)
    auto.rules = {}
    for i, d in ipairs(RULES) do auto.rules[i] = newRule(auto, i, d) end
    auto.note = UI:Text(auto, "small", "SUB", { wrap = true, width = BODY_W - 4 })
    auto.note:SetPoint("TOPLEFT", 2, -4 * 50 - 14)
    auto.note:SetText("All off for a new outfit. A swap never happens in combat: it waits for the fight to end, "
        .. "then puts on only the slots that differ.")
    v.auto = auto
    v:SetScript("OnHide", function() WUI:ClosePopovers() end)
    v:SetScript("OnShow", function() WUI:Refresh() end)
    self:Refresh()
    return v
end

function WUI:Select(id) state.sel = id; self:ClosePopovers(); self:Refresh() end
function WUI:SetTab(key) state.tab = key; self:ClosePopovers(); self:Refresh() end
function WUI:GetState() return state end

function WUI:ClosePopovers()
    if view and view.picker then view.picker:Hide() end
    if view and view.icons then view.icons:Hide() end
end

-- The outfit's More menu (the banner's ··· and a row's right-click).
function WUI:FillOutfitMenu(root)
    local o = Selected()
    if not o then return end
    local demo = W().IsDemo()
    if not demo then root:CreateButton("Save what I'm wearing into it", function() W():Overwrite(o.id) end) end
    root:CreateButton("Rename\226\128\166", function()
        ns.Popup:Prompt({ title = "Rename outfit", default = o.name, maxLetters = 40, trim = true,
            validate = function(v) return v ~= "" end, onAccept = function(v) W():Rename(o.id, v) end })
    end)
    root:CreateButton("Change icon\226\128\166", function() WUI:OpenIcons() end)
    root:CreateButton("Save my BiS list as an outfit", SaveBiS)
    root:CreateButton("Delete", function()
        ns.Popup:Confirm({ title = "Delete outfit", text = ("Delete \"%s\"? Your gear stays as it is."):format(o.name),
            ok = "Delete", danger = true, onAccept = function()
                W():Delete(o.id)
                state.sel = nil
            end })
    end)
end

function WUI:OutfitMenu(owner)
    UI:ContextMenu(owner, function(root) WUI:FillOutfitMenu(root) end)
end

function WUI:Refresh()
    if not view then return end
    local list = W():List()
    local L = view.layout
    L.toolbar:SetPrimary({ text = "Save what I'm wearing", icon = UI.ICON.plus, width = 178, onClick = SaveWorn,
        enabled = W():CanAdd(),
        tip = W():CanAdd() and { "Save what I'm wearing", "A new outfit of the 17 slots you have on now." }
            or { "Save what I'm wearing", ("You have %d outfits, the most a character keeps. Delete one first.")
                :format(W().MAX) } })
    if #list == 0 then
        view.quick:Hide()
        L:ShowEmpty({ glyph = (ns.HasAssets and ns:HasAssets(7)) and UI.ICON.shield or UI.ICON.bag,
            title = "No outfits yet",
            text = "Save what you wear now as your first outfit. One click puts it back on later, "
                .. "or a rule does it for you: a spec switch, a boss, a fishing pole or a mount.",
            action = { text = "Save what I'm wearing", onClick = SaveWorn, width = 178 } })
        return
    end
    if L:IsEmptyShown() then L:HideEmpty() end
    local o = Selected()
    for i, r in ipairs(view.rows) do
        if list[i] then fillRow(r, list[i]) else r:Hide() end
    end
    -- the bar card
    local qc = view.quick
    qc:Show()
    qc.sw:SetChecked(W():BarOn())
    local cur = W():Wearing()
    for i, b in ipairs(qc.icons) do
        local x = list[i]
        if x then
            b:Set(x.icon)
            b.outer:SetColorTexture(x == cur and GOLD[1] or 0, x == cur and GOLD[2] or 0, x == cur and GOLD[3] or 0, 1)
            b:Show()
        else
            b:Hide()
        end
    end
    -- (the note gives way to the icons once there are many)
    qc.note:SetShown(#list <= 4)

    local b = view.banner
    b:SetArt(o.art)
    b:SetKicker("OUTFIT")
    b:SetIcon(o.icon)
    b:SetTitle(o.name)
    local long = W():RuleText(o, true)
    b:SetSub(long and ("Wears itself " .. long) or "You wear it by hand")
    local kind, text = status(o)
    b:SetPill(kind, text)
    local running = W():Running()
    if W():IsWorn(o) then
        b:SetActions(nil)
    else
        local q = W().queued
        local txt = "Wear"
        if q and q.o == o then txt = "After combat"
        elseif running and running.o == o then txt = "Wearing\226\128\166" end
        b.wearAct[1].text = txt
        b:SetActions(b.wearAct)
    end
    b:SetTools(b.moreTools)
    local tabs = view.layout.tabs
    local on = W():RuleCount(o)
    if tabs then
        tabs:SetTabCount("auto", on > 0 and on or nil)
        tabs:SelectTab(state.tab)
    end
    -- the doll
    local body = view.body
    body:SetShown(state.tab == "outfit")
    view.auto:SetShown(state.tab == "auto")
    local slots, c = W():Status(o)
    for i, inv in ipairs(W().SLOTS) do fillTile(body.tiles[i], inv, slots[inv]) end
    local function join(t) return table.concat(t, "  \194\183  ") end
    local l1, l2 = {}, {}
    if c.swap > 0 then l1[#l1 + 1] = hex(GOLD) .. c.swap .. (c.swap == 1 and " slot swaps" or " slots swap") .. "|r" end
    if c.bank > 0 then l1[#l1 + 1] = hex(ORANGE) .. c.bank .. " from the bank|r" end
    if c.missing > 0 then l1[#l1 + 1] = hex(RED) .. c.missing .. " missing|r" end
    if c.worn > 0 then l2[#l2 + 1] = c.worn .. " already worn" end
    if c.keep > 0 then l2[#l2 + 1] = c.keep .. " keep current" end
    if #l1 == 0 then l1[1] = "All worn: nothing to swap" end
    body.sum.l1:SetText(join(l1))
    body.sum.l2:SetText(join(l2))
    for i, d in ipairs(RULES) do fillRule(view.auto.rules[i], d, o) end
end

---------------------------------------------------------------------------
-- The slot picker (a popover from the tile: worn, bags, bank, Keep current)
---------------------------------------------------------------------------
local WHERE = { bank = { "warn", "Bank" }, worn = { "ok", "Worn" }, bags = { "mute", "Bags" } }

-- What fits a slot; demo: the made-up outfits' items for it (worn / bags, the Prot main hand in the bank).
local function PickList(inv)
    if not W().IsDemo() then return W():Candidates(inv) end
    local out, seen = {}, {}
    local function add(id, where)
        if id and not seen[id] then seen[id] = true; out[#out + 1] = { id = id, where = where } end
    end
    if inv == 16 then add(28749, "bank") end
    add(W().DEMO_WORN[inv] or nil, "worn")
    for _, o in ipairs(W():DemoList()) do
        local s = o.slots[inv]
        if type(s) == "table" then add(s.id, "bags") end
    end
    if inv == 16 then add(28430, "bags"); add(29171, "bags") end
    return out
end

function WUI:OpenPicker(tile)
    local p = view.picker
    if not p then
        p = UI:CreatePopover(PICK_W, 10, { close = "catcher", name = "DisasterZoneWardrobePicker" })
        p.head = UI:Text(p, "small", "GOLD")
        p.head:SetPoint("TOPLEFT", 10, -9)
        p.rows = {}
        view.picker = p
    end
    local o = Selected()
    if not o then return end
    local inv = tile.inv
    p.head:SetText((W().SLOT_NAME[inv] .. "  \194\183  " .. "from your bags and bank"):upper())
    local list = PickList(inv)
    local cur = o.slots[inv]
    local y = -26
    local function row(i)
        local r = p.rows[i]
        if not r then
            r = CreateFrame("Button", nil, p)
            r:SetSize(PICK_W - 10, 30)
            UI:DecorateRow(r, { selectable = true })
            r.icon = UI:CreateIconTile(r, 22)
            r.icon:SetPoint("LEFT", 6, 0)
            r.name = UI:Text(r, "body", "TEXT")
            r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
            r.pill = UI:CreatePill(r, 16)
            r.pill:SetPoint("RIGHT", -6, 0)
            r:SetScript("OnClick", function(self)
                p:Hide()
                W():SetSlot(o.id, inv, self.pick)
            end)
            p.rows[i] = r
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 5, y)
        y = y - 30
        return r
    end
    local n = 0
    for _, e in ipairs(list) do
        n = n + 1
        local r = row(n)
        r.pick = { id = e.id, key = e.key }
        r.icon:Set(iconOf(e.id))
        r.icon.tex:SetDesaturated(false)
        local on = type(cur) == "table" and cur.id == e.id and (not cur.key or not e.key or cur.key == e.key)
        r.icon.outer:SetColorTexture(on and GOLD[1] or 0, on and GOLD[2] or 0, on and GOLD[3] or 0, 1)
        r.name:SetText(nameOf(e.id))
        r.name:SetTextColor(qcolor(e.id))
        local w = WHERE[e.where] or WHERE.bags
        r.pill:SetPill(w[1], w[2])
        r:SetSelected(on)
        r:Show()
    end
    if n == 0 then
        n = n + 1
        local r = row(n)
        r.pick = cur
        r.icon:Set(EMPTY_ICON[inv] or 134400)
        r.icon.tex:SetDesaturated(true)
        r.icon.outer:SetColorTexture(0, 0, 0, 1)
        r.name:SetText("Nothing for this slot")
        r.name:SetTextColor(S:Color("SUB"))
        r.pill:SetPill("mute", "bags + bank")
        r:SetSelected(false)
        r:Show()
    end
    -- divider + Keep current
    y = y - 4
    p.div = p.div or p:CreateTexture(nil, "ARTWORK")
    p.div:SetColorTexture(1, 1, 1, 0.08)
    p.div:SetHeight(1)
    p.div:ClearAllPoints()
    p.div:SetPoint("TOPLEFT", 10, y)
    p.div:SetPoint("TOPRIGHT", -10, y)
    y = y - 5
    n = n + 1
    local k = row(n)
    k.pick = nil
    k.icon:Set(EMPTY_ICON[16])
    k.icon.tex:SetDesaturated(true)
    k.icon.outer:SetColorTexture(0, 0, 0, 1)
    k.name:SetText("Keep current")
    k.name:SetTextColor(S:Color("TEXT"))
    k.pill:SetPill("mute", "never touched")
    k:SetSelected(cur == nil)
    k:Show()
    for i = n + 1, #p.rows do p.rows[i]:Hide() end
    p:SetHeight(-y + 6)
    p:ClearAllPoints()
    p:SetPoint("BOTTOMRIGHT", tile, "TOPRIGHT", 0, 2)
    p.owner = tile
    p:Show()
    return p
end

---------------------------------------------------------------------------
-- Change icon (a popover of icons: the outfit's items, then a few of the class's and the trades')
---------------------------------------------------------------------------
local ICONS = { I .. "Spell_Holy_AuraOfLight", I .. "Spell_Holy_DevotionAura", I .. "Spell_Holy_HolyBolt",
    I .. "Ability_Warrior_DefensiveStance", I .. "Ability_Rogue_Eviscerate", I .. "Spell_Nature_ResistNature",
    I .. "Spell_Fire_FireArmor", I .. "Spell_Frost_FrostArmor02", I .. "Spell_Shadow_AntiShadow", I .. "Trade_Fishing",
    I .. "Ability_Mount_Charger", I .. "INV_Misc_Bag_10", I .. "INV_Chest_Plate03", I .. "INV_Sword_39",
    I .. "INV_Shield_06", I .. "Spell_Nature_Lightning" }
local ICON_N, ICON_SZ = 8, 30

function WUI:OpenIcons()
    local o = Selected()
    if not (o and view) then return end
    local p = view.icons
    if not p then
        p = UI:CreatePopover(PAD * 2 + ICON_N * (ICON_SZ + 4) - 4, 10,
            { close = "catcher", name = "DisasterZoneWardrobeIcons" })
        p.head = UI:Text(p, "small", "GOLD", { text = "CHANGE ICON" })
        p.head:SetPoint("TOPLEFT", PAD, -9)
        p.cells = {}
        view.icons = p
    end
    local pool, seen = {}, {}
    local function add(t) if t and not seen[t] then seen[t] = true; pool[#pool + 1] = t end end
    for _, inv in ipairs(W().SLOTS) do
        local s = o.slots[inv]
        if type(s) == "table" then add(iconOf(s.id)) end
    end
    for _, t in ipairs(ICONS) do add(t) end
    while #pool > ICON_N * 4 do table.remove(pool) end
    for i, t in ipairs(pool) do
        local c = p.cells[i]
        if not c then
            c = CreateFrame("Button", nil, p)
            c:SetSize(ICON_SZ, ICON_SZ)
            c.tile = UI:CreateIconTile(c, ICON_SZ)
            c.tile:SetAllPoints()
            c.tile:EnableMouse(false)
            c:SetScript("OnClick", function(self) p:Hide(); W():SetIcon(o.id, self.tex) end)
            p.cells[i] = c
        end
        c:SetScript("OnClick", function(self) p:Hide(); W():SetIcon(o.id, self.tex) end)
        c.tex = t
        c.tile:Set(t)
        local on = t == o.icon
        c.tile.outer:SetColorTexture(on and GOLD[1] or 0, on and GOLD[2] or 0, on and GOLD[3] or 0, 1)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", PAD + ((i - 1) % ICON_N) * (ICON_SZ + 4), -26 - floor((i - 1) / ICON_N) * (ICON_SZ + 4))
        c:Show()
    end
    for i = #pool + 1, #p.cells do p.cells[i]:Hide() end
    p:SetHeight(26 + math.ceil(#pool / ICON_N) * (ICON_SZ + 4) - 4 + PAD)
    p:ClearAllPoints()
    p:SetPoint("TOPRIGHT", view.banner, "BOTTOMRIGHT", 0, -2)
    p:Show()
    return p
end

---------------------------------------------------------------------------
-- The quick-swap bar (a HUD frame; Edit layout moves it)
---------------------------------------------------------------------------
-- One face per outfit in the class tool bars' theme (UI/BarFace.lua: the same setting, classbar.theme): the worn
-- outfit lit gold ("on"), a red count on one with items missing or in the bank. Click = wear. No panel behind it.
local bar
local BAR_ID = "wardrobe"

local function BuildBar()
    bar = UI:CreateHudFrame("DisasterZoneWardrobeBar", { width = 200, height = 50, position = false,
        layout = BAR_ID, look = "none", default = { "BOTTOM", UIParent, "BOTTOM", 0, 190 } })
    -- (no backdrop or edge: the icons float on their own; Edit layout draws its own box to drag it by)
    bar.cells = {}
    bar:Hide()
    WUI.bar = bar
    bar:RestorePlace()
end

local function Cell(i)
    local b = bar.cells[i]
    if b then return b end
    b = CreateFrame("Button", nil, bar)
    b.face = ns.BarFace:New(b)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function(self) if self.o then W():Wear(self.o.id) end end)
    -- (no tooltip: the user asked for none; the face's own hover light stays)
    b:SetScript("OnEnter", function(self) ns.BarFace:Hover(self.face, true) end)
    b:SetScript("OnLeave", function(self) ns.BarFace:Hover(self.face, false) end)
    bar.cells[i] = b
    return b
end

function WUI:BarWanted()
    if self.barPreview then return #W():List() > 0 end
    return W():BarOn() and #W():List() > 0
end

-- Fills and shows (or hides) the bar. theme: a BarFace theme key to draw it in (the mock's sheet; default the
-- setting's).
function WUI:UpdateBar(theme)
    if not bar then BuildBar() end
    if not self:BarWanted() then bar:Hide(); return end
    local list = W():List()
    local cells = {}
    for i, o in ipairs(list) do
        local b = Cell(i)
        b.o = o
        b:Show()
        cells[i] = b
    end
    for i = #list + 1, #bar.cells do bar.cells[i]:Hide(); bar.cells[i].o = nil end
    local t = theme and ns.BarFace.BY_KEY[theme] or nil
    if not (InCombatLockdown and InCombatLockdown()) then ns.BarFace:Place(bar, cells, 0, "h", t) end
    local cur = W():Wearing()                     -- (one gold ring: the outfit on, or on its way)
    for i, o in ipairs(list) do
        local _, c = W():Status(o)
        local n = c.missing + c.bank
        ns.BarFace:Set(cells[i].face, { icon = o.icon, tone = (o == cur) and "on" or nil,
            missing = n > 0 and n or nil })
    end
    bar:Show()
end

function WUI:ShowBar(themeKey, x, y)
    self.barPreview = true
    self:UpdateBar(themeKey)
    if x then
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y)
    end
    return bar
end

function WUI:HideBar()
    self.barPreview = nil
    if bar then bar:Hide() end
end

---------------------------------------------------------------------------
-- Registration & messages
---------------------------------------------------------------------------
local function RequestRefresh()
    ns.Util.Debounce("wardrobe-ui", 0.05, function()
        if view and view:IsVisible() then WUI:Refresh() end
        WUI:UpdateBar()
    end)
end
WUI.RequestRefresh = RequestRefresh

function WUI:OnInit()
    ns.Layout:Register(BAR_ID, { name = "Quick-swap bar", group = "Game frames", order = 40, when = "when switched on",
        frame = function() return bar end, default = { "BOTTOM", 0, 190 },
        preview = function(on)
            WUI.barPreview = on and true or nil
            WUI:UpdateBar()
        end })
end

function WUI:OnLogin()
    ns:On("WARDROBE_UPDATED", RequestRefresh)
    ns:On("ITEMINFO_READY", RequestRefresh)
    ns:On("SETTINGS_CHANGED", function(key) if key == "classbar.theme" then RequestRefresh() end end)
    ns:On("DEMO_TOGGLED", function() state.sel = nil; RequestRefresh() end)
    ns:On("DEMO_PARTS_CHANGED", function(key) if key == "outfits" or key == "stop" then RequestRefresh() end end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", RequestRefresh)
    ns:RegisterSlash("wardrobe", function(rest)
        if rest == "next" then W():WearNext()
        elseif ns.MainFrame then ns.MainFrame:Open("wardrobe") end
    end, "open Gear > Wardrobe (/dz wardrobe next: wear the next outfit)")
    RequestRefresh()
end

if ns.MainFrame and ns.MainFrame.RegisterTab then
    ns.MainFrame:RegisterTab("wardrobe", "Wardrobe", 1.25, function(parent) return WUI:CreatePanel(parent) end,
        nil, { layout = "listdetail" })
end
