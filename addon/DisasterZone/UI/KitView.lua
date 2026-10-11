if DisasterZoneBoot and DisasterZoneBoot.Run("UI/KitView.lua", ...) then return end -- DisasterZone: UI/KitView.lua
-- ns.KitView: My BiS > Consumables (the button left of Sim). The shown spec's kit (Core/Kit.lua): the best picks on
-- the left (prog nights), the budget picks on the right (farm nights), and down the middle what each slot is in one
-- line. A card is quiet: the name, what it does (or its DPS once the gear sim ran it) and a check when my bags hold a
-- night's worth; the rest (counts, who makes it, what it costs) is in its tooltip, and the bag button for the
-- shopping list shows under the mouse. The bar at the bottom adds up both kits and fills the shopping list.
-- 1.4: the body of the My BiS panel's Board layout on the Consumables page; shared text styles (on the type scale),
-- Style tokens (D1: gold text, the deep gold for the edges and fills), tooltips through UI:AttachTooltip and the
-- illustrated empty state.
local _, ns = ...

local KitView = {}
ns.KitView = KitView

local S = ns.Style
local floor, max, abs = math.floor, math.max, math.abs

local GOLD = S.C.GOLD                 -- text
local GOLD_EDGE = S.C.GOLD_DEEP       -- the best picks' edge, the bar's top, the progress
local GREEN = S.C.OK
local AMBER = S.C.WARN
local GREY = S.C.SUB
local SOFT = { 0.72, 0.72, 0.75 }
local WHITE = S.C.TEXT
local BAR_BG = { 0.085, 0.085, 0.1, 0.96 }

local TILE_W, TILE_H, GAP, MID_X, MID_W = 262, 56, 6, 270, 230
local HEAD_H = 18
local ROWS = 6
local KITBAR_H = 58
local BAR_X, PIPS_X = 10, 290   -- the bar spans the page: its contents start at the cards' edge (My BiS's PAD)
local READY_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"

local state = { active = false }
local view

local function K() return ns.Kit end

-- A text in a style of the type scale (with the game's drop shadow, as the cards always had).
local function Label(parent, style, color, justify)
  return ns.UI:Text(parent, style, color, { justify = justify, shadow = true })
end

local function Col(text, c) return ns.UI:Colorize(text, c) end

-- 12g / 40s (a night's worth rounded the way people say it)
local function Money(copper)
  if not copper then return nil end
  if copper >= 10000 then return ("%dg"):format(floor(copper / 10000 + 0.5)) end
  if copper >= 100 then return ("%ds"):format(floor(copper / 100 + 0.5)) end
  return ("%dc"):format(copper)
end
local function Signed(v)
  v = floor(v + 0.5)
  if v > 0 then return "+" .. v end
  if v < 0 then return "\226\136\146" .. abs(v) end
  return "+0"
end

-- ---------------------------------------------------------------------------------------------------------------
-- Mode
-- ---------------------------------------------------------------------------------------------------------------
function KitView:IsActive() return state.active end

-- The view on / off, nothing else: the Consumables page sets it (UI/MyBiS.lua's ApplyView, which refreshes).
function KitView:SetMode(on)
  on = on and true or false
  if on == state.active then return end
  state.active = on
  if not on and K() and K():IsRunning() then K():Cancel() end
end

-- Opens the Consumables page (on) or goes back to My BiS (off).
function KitView:SetActive(on)
  if ns.MyBiS and ns.MyBiS.OpenView then
    ns.MyBiS:OpenView(on and "kit" or "list")
    return
  end
  self:SetMode(on)
end

function KitView:Toggle() self:SetActive(not state.active) end

-- ---------------------------------------------------------------------------------------------------------------
-- Cards
-- ---------------------------------------------------------------------------------------------------------------
local function NameOf(ids)
  local Kt = K()
  if #ids == 1 then return Kt:Name(ids[1]) end
  local parts = {}
  for i, id in ipairs(ids) do
    local it = Kt:Item(id)
    parts[i] = it and it[2] or Kt:Name(id)
  end
  return table.concat(parts, " + ")
end

-- The card's tooltip: the item (or each of a pair), what my bags hold of a night's worth, my bank, who makes it,
-- what a night costs; for Same / Skip it why.
local KIT_NAME = { best = "prog kit", budget = "farm kit" }

local function CardTooltip(c, tt)
  local Kt = K()
  if not c.row then return false end
  local row, s = c.row, c.row and c.row[c.sideKey]
  if not s then return false end
  local gr, gg, gb = S:Color("GOLD")
  if c.off then
    tt:AddLine(NameOf(Kt:SideIds(row, c.sideKey)), 0.7, 0.7, 0.72)
    tt:AddLine("Left out of your " .. KIT_NAME[c.sideKey] .. ": not counted and not added to the shopping list.",
      1, 1, 1, true)
    tt:AddLine("Click: put it back", 0.5, 0.5, 0.52)
    return
  end
  if s.kind == "skip" or s.kind == "same" then
    tt:AddLine(s.kind == "skip" and "Skip it" or "Same as the best pick", gr, gg, gb)
    if s.text and s.text ~= "" then tt:AddLine(s.text, 1, 1, 1, true) end
    tt:AddLine("Click: choose your own  \194\183  Right-click: more", 0.5, 0.5, 0.52)
    return
  end
  local ids = c.ids or {}
  if #ids == 1 and tt.SetItemByID then
    tt:SetItemByID(ids[1])
    tt:AddLine(" ")
  else
    tt:AddLine(NameOf(ids), gr, gg, gb)
  end
  if s.text and s.text ~= "" then tt:AddLine(s.text, 1, 1, 1, true) end
  for _, id in ipairs(ids) do
    local have, need = Kt:Have(id), Kt:Need(id)
    local hc = have >= need and GREEN or AMBER
    tt:AddDoubleLine((#ids > 1 and (Kt:Name(id) .. "  ") or "") .. Col(Kt:Effect(id), SOFT),
      Col(("%d of %d in bags"):format(have, need), hc), 1, 1, 1)
    local bank = Kt:InBank(id)
    if bank > 0 then tt:AddLine(("%d more in your bank"):format(bank), 0.6, 0.6, 0.62) end
    local who = Kt:Crafter(id)
    if who == "me" then
      tt:AddLine("You can make it", 0.6, 0.6, 0.62)
    elseif who then
      tt:AddLine("Made by " .. (ns.UI.ColoredName and ns.UI:ColoredName(who) or who), 0.6, 0.6, 0.62)
    elseif not Kt:CanList(id) then
      tt:AddLine("No craft makes it: the auction house", 0.6, 0.6, 0.62)
    end
    local p = Kt:Price(id)
    if p then tt:AddLine((Money(p * need) or "") .. " a night (Auctionator)", 0.6, 0.6, 0.62) end
  end
  if s.custom then
    local def = s.default and #s.default > 0 and NameOf(s.default)
      or (s.defaultKind == "same" and "same as the prog kit") or "skip it"
    tt:AddLine("Your own pick  \194\183  the guide's: " .. def, gr, gg, gb, true)
  end
  tt:AddLine("A night: a three hour raid.  Shift-click an icon to link it.", 0.5, 0.5, 0.52, true)
  tt:AddLine("Click: choose another  \194\183  Right-click: more", 0.5, 0.5, 0.52)
end

-- The bag button shows under the mouse (on the card or its icons) while the shopping list can take something.
local function ShowBag(c, on)
  c.bag:SetShown(on and c.canList and true or false)
end

local function Hovered(c)
  return c:IsMouseOver() or c.bag:IsMouseOver()
end

-- ---------------------------------------------------------------------------------------------------------------
-- My own pick for a slot: My BiS's item picker (UI/Picker.lua) with only consumables in it
-- ---------------------------------------------------------------------------------------------------------------
local pstate = {}

local function Cap(title) return title:sub(1, 1) .. title:sub(2):lower() end

local function CurrentRow()
  for _, row in ipairs(K():Get() or {}) do
    if row.key == pstate.slot then return row end
  end
  return nil
end

local function NewHost()
  local Kt = K()
  local side, slot = pstate.side, pstate.slot
  local host = { only = true, clearText = "Default", searchHint = "Search consumables...", emptyIcon = "Interface\\Icons\\INV_Misc_QuestionMark" }
  local function ids()
    local row = CurrentRow()
    return row and Kt:SideIds(row, side) or {}
  end
  host.title = function()
    local row = CurrentRow()
    return Cap(row and row.title or slot) .. "  \194\183  " .. Cap(KIT_NAME[side])
  end
  host.current = function() return ids()[1] end
  host.currentSub = function()
    local row = CurrentRow()
    local s = row and row[side]
    local cur = ids()
    local name = #cur > 0 and NameOf(cur) or Col("Skip it", GREY)
    if s and s.custom then
      local def = s.default and #s.default > 0 and NameOf(s.default)
        or (s.defaultKind == "same" and "same as the prog kit") or "skip it"
      return name, "Your pick  \194\183  the guide's: " .. def, true
    end
    return name, "The guide's pick", false
  end
  host.clear = function() Kt:SetPick(side, slot, nil) end
  -- a flask or a single pick closes the picker; an elixir or a scroll keeps it open for the second one
  host.pick = function(itemID)
    if Kt:SlotOf(itemID) ~= slot then
      ns:Print("%s doesn't go in this slot.", Kt:Name(itemID))
      return false
    end
    if Kt:PickInto(side, slot, itemID) then return false end
  end
  host.sections = function()
    local secs = {}
    local row = CurrentRow()
    local mine, guide, seen = {}, {}, {}
    -- the guide's picks for the slot (both kits)
    for _, sk in ipairs({ "best", "budget" }) do
      local d = row and row[sk] and row[sk].default
      for _, id in ipairs(d or {}) do
        if not seen[id] then
          seen[id] = true
          guide[#guide + 1] = { itemID = id, sub = Kt:Effect(id) .. "  \194\183  " .. (sk == "best" and "prog" or "farm") }
        end
      end
    end
    for _, grp in ipairs(Kt:Candidates(slot)) do
      for _, id in ipairs(grp.ids) do
        if Kt:Have(id) > 0 then mine[#mine + 1] = { itemID = id, sub = Kt:Effect(id) } end
      end
    end
    if #mine > 0 then secs[#secs + 1] = { name = "In your bags", items = mine } end
    if #guide > 0 then secs[#secs + 1] = { name = "The guide's picks", items = guide } end
    for _, grp in ipairs(Kt:Candidates(slot)) do
      local items = {}
      for _, id in ipairs(grp.ids) do items[#items + 1] = { itemID = id, sub = Kt:Effect(id) } end
      secs[#secs + 1] = { name = Kt.KIND_NAMES[grp.kind] or grp.kind, items = items }
    end
    return secs
  end
  host.value = function(itemID)
    local n = Kt:Have(itemID)
    if n <= 0 then return nil end
    return Col(n .. " in bags", n >= Kt:Need(itemID) and GREEN or SOFT), ""
  end
  host.onClose = function() pstate.host = nil end
  return host
end

function KitView:OpenPicker(side, slot, anchor)
  if not (ns.Picker and ns.Picker.Open) then return end
  pstate.side, pstate.slot = side, slot
  pstate.host = NewHost()
  ns.Picker:Open(1, 1, "main", anchor, nil, pstate.host)
end

function KitView:IsPickerOpen()
  return ns.Picker and pstate.host ~= nil and ns.Picker:GetHost() == pstate.host or false
end

function KitView:ClosePicker()
  if self:IsPickerOpen() then ns.Picker:Close() end
end

-- Click: choose another item for the slot (a left-out card: put it back). Right-click: a menu (choose, the guide's
-- pick back, leave out / put back).
local function CardClick(c, button)
  local s = c.row and c.row[c.sideKey]
  if not s then return end
  local Kt, slot, side = K(), c.row.key, c.sideKey
  if button == "RightButton" then
    local off = Kt:IsOff(side, slot)
    ns.UI:ContextMenu(c, function(root)
      root:CreateTitle(Cap(c.row.title) .. "  \194\183  " .. KIT_NAME[side])
      root:CreateButton("Choose item...", function() KitView:OpenPicker(side, slot, c) end)
      if s.custom then
        root:CreateButton("Use the guide's pick", function() Kt:SetPick(side, slot, nil) end)
      end
      if s.kind ~= "skip" then
        root:CreateButton(off and "Put back in the kit" or "Leave out of the kit", function()
          Kt:SetOff(side, slot, not off)
        end)
      end
    end)
  elseif c.off then
    Kt:SetOff(side, slot, false)
  else
    KitView:OpenPicker(side, slot, c)
  end
end

local function CreateCard(parent, side)
  local UI = ns.UI
  local c = CreateFrame("Frame", nil, parent)
  c:SetSize(TILE_W, TILE_H)
  c:EnableMouse(true)
  c.side = side
  local right = side == "R"
  c.bg = c:CreateTexture(nil, "BACKGROUND")
  c.bg:SetAllPoints()
  -- (the quiet tile look of My BiS's doll: a lift fading toward the middle)
  local a = 0.11
  local far, near = { 0.55, 0.55, 0.62, a }, { 0.55, 0.55, 0.62, a * 0.25 }
  if right then UI:Gradient(c.bg, "HORIZONTAL", near, far) else UI:Gradient(c.bg, "HORIZONTAL", far, near) end
  -- the best picks: a gold edge on the outer side
  c.edge = c:CreateTexture(nil, "BORDER")
  c.edge:SetWidth(2)
  c.edge:SetPoint("TOP", c, "TOP", 0, 0)
  c.edge:SetPoint("BOTTOM", c, "BOTTOM", 0, 0)
  c.edge:SetPoint(right and "RIGHT" or "LEFT", c, right and "RIGHT" or "LEFT", 0, 0)
  c.edge:SetColorTexture(GOLD_EDGE[1], GOLD_EDGE[2], GOLD_EDGE[3], 0.9)
  c.edge:SetShown(not right)

  c.icon = UI:CreateItemButton(c, 40)
  c.icon:SetPoint(right and "RIGHT" or "LEFT", c, right and "RIGHT" or "LEFT", right and -8 or 8, 0)
  c.sub = UI:CreateItemButton(c, 18)
  c.sub:SetFrameLevel(c.icon:GetFrameLevel() + 2)
  -- an elixir pair's second item on the main icon's inner bottom corner (clear of the name)
  c.sub:SetPoint(right and "BOTTOMLEFT" or "BOTTOMRIGHT", c.icon, right and "BOTTOMLEFT" or "BOTTOMRIGHT",
    right and -3 or 3, -3)
  if UI.AddEdges then UI:AddEdges(c.sub, "OVERLAY"); UI:SetEdgeColor(c.sub, 0.6, 0.6, 0.64, 0.9) end

  local textX = 8 + 40 + 10
  local room = TILE_W - textX - 8
  c.name = Label(c, "emph", WHITE, right and "RIGHT" or "LEFT")
  c.name:SetPoint(right and "TOPRIGHT" or "TOPLEFT", c, right and "TOPRIGHT" or "TOPLEFT", right and -textX or textX, -12)
  c.name:SetWidth(room)
  c.line = Label(c, "small", SOFT, right and "RIGHT" or "LEFT")
  c.line:SetPoint(right and "TOPRIGHT" or "TOPLEFT", c, right and "TOPRIGHT" or "TOPLEFT", right and -textX or textX, -31)
  c.line:SetWidth(room - 24)

  -- a night's worth in my bags: a check on the inner side
  c.check = c:CreateTexture(nil, "OVERLAY")
  c.check:SetSize(14, 14)
  c.check:SetTexture(READY_TEX)
  c.check:SetPoint(right and "LEFT" or "RIGHT", c, right and "LEFT" or "RIGHT", right and 10 or -10, 0)

  -- the shopping list (under the mouse only)
  c.bag = UI:CreateTipIconButton(c, 18, UI.ICON.bagAdd, "Shopping list", nil, function()
    local Kt = K()
    for id, miss in pairs(Kt:Missing(c.ids or {})) do
      if Kt:CanList(id) then
        local onList = ns.Shop:GetAmount(id) or 0
        if miss > onList then ns.Shop:Add(id, miss - onList) end
      end
    end
    KitView:Update()
  end)
  c.bag:SetPoint(right and "LEFT" or "RIGHT", c, right and "LEFT" or "RIGHT", right and 8 or -8, 0)
  c.bag:SetFrameLevel(c.icon:GetFrameLevel() + 3)
  c.bag:Hide()
  UI:AttachTooltip(c.bag, function(_, tt)
    tt:AddLine("Shopping list", S:Color("GOLD"))
    local Kt = K()
    for id, miss in pairs(Kt:Missing(c.ids or {})) do
      if Kt:CanList(id) then
        local have = ns.Shop:GetAmount(id) or 0
        tt:AddDoubleLine(Kt:Name(id), have >= miss and ("on your list (" .. have .. ")") or ("add " .. (miss - have)),
          1, 1, 1, 0.65, 0.65, 0.68)
      end
    end
    tt:AddLine("Puts what your bags lack for a night on your shopping list (Atlas).", 0.5, 0.5, 0.52, true)
  end, nil, { anchor = "ANCHOR_TOP" })
  c.bag:HookScript("OnLeave", function() if not Hovered(c) then ShowBag(c, false) end end)

  c:SetScript("OnMouseUp", function(self, button) if self:IsMouseOver() then CardClick(self, button) end end)
  c.icon.onClick = function(_, button) CardClick(c, button) end
  c.sub.onClick = function(_, button) CardClick(c, button) end
  local function enter() ShowBag(c, true) end
  local function leave()
    if not Hovered(c) then ShowBag(c, false) end
  end
  -- the card's tooltip, on the card and its icons alike (beside the card, away from the middle)
  local tipOpts = { anchor = right and "ANCHOR_LEFT" or "ANCHOR_RIGHT", owner = c }
  local function tip(_, tt) return CardTooltip(c, tt) end
  c:SetScript("OnEnter", enter)
  c:SetScript("OnLeave", leave)
  UI:AttachTooltip(c, tip, nil, tipOpts)
  for _, b in ipairs({ c.icon, c.sub }) do
    b:SetScript("OnEnter", enter)
    b:SetScript("OnLeave", leave)
    UI:AttachTooltip(b, tip, nil, tipOpts)
  end
  return c
end

-- The second line: the DPS (after a run) or what it does.
local function LineOf(ids, dps, se)
  local Kt = K()
  if dps and se and abs(dps) <= 2 * se and abs(dps) >= 0.5 then return Col("no clear gain", GREY) end
  if dps then return Col(Signed(dps) .. " DPS", dps >= 0.5 and GREEN or GREY) end
  if #ids == 1 then return Kt:Effect(ids[1]) end
  local it = Kt:Item(ids[1])
  return (it and it[4] == "scroll") and "Scrolls" or "Elixirs"
end

local function SetCard(c, row, sideKey, dps, se)
  local Kt = K()
  local s = row[sideKey]
  c.row, c.sideKey = row, sideKey
  c.off = s.kind ~= "skip" and Kt:IsOff(sideKey, row.key) or false
  c:Show()
  c:SetAlpha(c.off and 0.4 or 1)
  c.check:Hide()
  c.canList = false
  c.name:ClearAllPoints()
  local right = c.side == "R"
  local textX = 8 + 40 + 10
  if s.kind == "skip" or s.kind == "same" then
    -- one quiet word, the why in the tooltip
    c.ids = nil
    c.name:SetPoint(right and "RIGHT" or "LEFT", c, right and "RIGHT" or "LEFT", right and -textX or textX, 0)
    c.line:SetText("")
    if s.kind == "skip" then
      c.icon:Hide(); c.sub:Hide()
      c.name:SetText(Col("Skip it", GREY))
      c.bg:SetAlpha(0.55)
    else
      c.bg:SetAlpha(1)
      local ids = Kt:SideIds(row, sideKey)
      c.icon:Show(); c.icon:SetItem(ids[1]); c.icon:SetAlpha(0.5)
      c.sub:SetShown(ids[2] ~= nil)
      if ids[2] then c.sub:SetItem(ids[2]); c.sub:SetAlpha(0.5) end
      c.name:SetText(Col(c.off and "Left out" or "Same", GREY))
    end
    ShowBag(c, false)
    return
  end
  c.name:SetPoint(right and "TOPRIGHT" or "TOPLEFT", c, right and "TOPRIGHT" or "TOPLEFT", right and -textX or textX, -12)
  c.bg:SetAlpha(1)
  local ids = Kt:SideIds(row, sideKey)
  c.ids = ids
  c.icon:Show(); c.icon:SetItem(ids[1]); c.icon:SetAlpha(1)
  c.sub:SetShown(ids[2] ~= nil)
  if ids[2] then c.sub:SetItem(ids[2]); c.sub:SetAlpha(1) end
  c.name:SetText(NameOf(ids))
  if c.off then
    c.line:SetText(Col("Left out", GREY))
    ShowBag(c, false)
    return
  end
  c.line:SetText(LineOf(ids, dps, se))
  local ready = Kt:Ready(ids)
  c.check:SetShown(ready)
  if not ready then
    for id in pairs(Kt:Missing(ids)) do if Kt:CanList(id) then c.canList = true end end
  end
  ShowBag(c, Hovered(c))
end

-- ---------------------------------------------------------------------------------------------------------------
-- The view
-- ---------------------------------------------------------------------------------------------------------------
local function CreateSpine(parent)
  local s = CreateFrame("Frame", nil, parent)
  s:SetSize(MID_W, TILE_H)
  s.title = Label(s, "small", GOLD, "CENTER")
  s.title:SetPoint("TOP", s, "TOP", 0, -15)
  s.why = Label(s, "small", GREY, "CENTER")
  s.why:SetPoint("TOP", s.title, "BOTTOM", 0, -5)
  s.why:SetWidth(MID_W - 20)
  return s
end

local function KitBlock(parent, caps, color)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(120, 40)
  b.caps = Label(b, "caps", color)
  b.caps:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  b.caps:SetText(caps)
  b.big = Label(b, "page", GREEN)
  b.big:SetPoint("TOPLEFT", b.caps, "BOTTOMLEFT", -1, -3)
  return b
end

-- parent: My BiS's body (the cards); page: the whole page (the bar runs along its bottom, edge to edge).
function KitView:Create(parent, page)
  if view then return view end
  local UI = ns.UI
  local v = CreateFrame("Frame", nil, parent)
  v:SetAllPoints(parent)
  v:Hide()
  view = v

  v.hBest = Label(v, "caps", GOLD)
  v.hBest:SetPoint("TOPLEFT", v, "TOPLEFT", 1, -2)
  v.hBest:SetText("PROG NIGHTS")
  v.hBudget = Label(v, "caps", GREY, "RIGHT")
  v.hBudget:SetPoint("TOPRIGHT", v, "TOPRIGHT", -1, -2)
  v.hBudget:SetText("FARM NIGHTS")

  v.rows = {}
  for i = 1, ROWS do
    local y = -HEAD_H - (i - 1) * (TILE_H + GAP)
    local r = {}
    r.best = CreateCard(v, "L")
    r.best:SetPoint("TOPLEFT", v, "TOPLEFT", 0, y)
    r.budget = CreateCard(v, "R")
    r.budget:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, y)
    r.spine = CreateSpine(v)
    r.spine:SetPoint("TOPLEFT", v, "TOPLEFT", MID_X, y)
    v.rows[i] = r
  end

  -- no list for the spec: the illustrated empty state (v.empty = its text, v.emptyState = the state)
  v.emptyState = UI:CreateEmptyState(v, { glyph = ns:HasAssets(6) and UI.ICON.flask or UI.ICON.bag, width = 460 })
  v.emptyState:SetPoint("TOP", v, "TOP", 0, -110)
  v.emptyState:Hide()
  v.empty = v.emptyState.text

  -- the kit bar
  local bar = CreateFrame("Frame", nil, v)
  bar:SetPoint("BOTTOMLEFT", page or v, "BOTTOMLEFT", 0, 0)
  bar:SetPoint("BOTTOMRIGHT", page or v, "BOTTOMRIGHT", 0, 0)
  bar:SetHeight(KITBAR_H)
  v.bar = bar
  UI:Fill(bar, BAR_BG)
  local top = bar:CreateTexture(nil, "ARTWORK")
  top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT")
  top:SetHeight(2)
  top:SetColorTexture(GOLD_EDGE[1], GOLD_EDGE[2], GOLD_EDGE[3], 0.9)

  bar.prog = KitBlock(bar, "PROG KIT", GOLD)
  bar.prog:SetPoint("LEFT", bar, "LEFT", BAR_X + 8, 0)
  bar.farm = KitBlock(bar, "FARM KIT", GREY)
  bar.farm:SetPoint("LEFT", bar, "LEFT", BAR_X + 134, 0)
  for _, b in ipairs({ bar.prog, bar.farm }) do
    b:SetScript("OnClick", function() KitView:Run() end)
    UI:AttachTooltip(b, function(self, tt)
      local Kt = K()
      local r = Kt:Results()
      tt:AddLine(self == bar.prog and "Prog kit" or "Farm kit", S:Color("GOLD"))
      if r then
        tt:AddLine(("The whole kit against none, with the gear you wear: %d fights, ±%d."):format(
          Kt.ITERATIONS, floor(2 * ((self == bar.prog and r.progSE or r.farmSE) or 0) + 0.5)), 1, 1, 1, true)
      end
      local cost = Kt:Summary(Kt:Get(), self == bar.prog and "best" or "budget").cost
      if cost then tt:AddLine("About " .. Money(cost) .. " a night (Auctionator).", 1, 1, 1, true) end
      tt:AddLine("Click: sim again", 0.5, 0.5, 0.52)
    end, nil, { anchor = "ANCHOR_TOP" })
  end
  -- before a run: the Sim button in the blocks' place
  bar.sim = UI:CreateSleekButton(bar, "Sim the kit", 110, 24, function() KitView:Run() end)
  bar.sim:SetPoint("LEFT", bar, "LEFT", BAR_X + 8, 0)
  UI:AttachTooltip(bar.sim, "Sim the kit", function()
    return { ("The gear sim gives every pick its DPS: the kit with and without it, %d fights each, with "
      .. "the gear you wear and the Sim card's buffs. Paused while you are in combat."):format(K().ITERATIONS) }
  end, { anchor = "ANCHOR_TOP" })
  bar.simNote = Label(bar, "small", GREY)
  bar.simNote:SetPoint("LEFT", bar.sim, "RIGHT", 10, 0)
  bar.progress = bar:CreateTexture(nil, "OVERLAY")
  bar.progress:SetPoint("TOPLEFT", bar.sim, "BOTTOMLEFT", 0, -2)
  bar.progress:SetHeight(2)
  bar.progress:SetColorTexture(GOLD_EDGE[1], GOLD_EDGE[2], GOLD_EDGE[3], 1)

  -- the prog kit in my bags: a pip per slot and "3 of 6 in your bags"
  bar.pips = {}
  for i = 1, ROWS do
    local p = bar:CreateTexture(nil, "ARTWORK")
    p:SetSize(9, 9)
    p:SetPoint("LEFT", bar, "LEFT", BAR_X + PIPS_X + (i - 1) * 12, 0)
    bar.pips[i] = p
  end
  bar.bags = Label(bar, "body", SOFT)
  bar.bags:SetPoint("LEFT", bar, "LEFT", BAR_X + PIPS_X + ROWS * 12 + 6, 0)
  local hit = CreateFrame("Frame", nil, bar)
  hit:SetPoint("LEFT", bar, "LEFT", BAR_X + PIPS_X - 6, 0)
  hit:SetSize(230, 30)
  UI:AttachTooltip(hit, function(_, tt)
    local Kt = K()
    local sum = Kt:Summary(Kt:Get(), "best")
    tt:AddLine("The prog kit in your bags", S:Color("GOLD"))
    tt:AddLine("A pip per slot, green with a night's worth in your bags.", 1, 1, 1, true)
    if sum.listCount + sum.other > 0 then
      tt:AddLine(("%d to get%s."):format(sum.listCount + sum.other,
        sum.crafted > 0 and (", " .. sum.crafted .. " made by a guildie") or ""), 0.7, 0.7, 0.72, true)
    end
  end, nil, { anchor = "ANCHOR_TOP" })

  bar.addProg = UI:CreateSleekButton(bar, "Add prog kit", 124, 26, function() KitView:AddKit("best") end, "primary")
  bar.addProg:SetPoint("RIGHT", bar, "RIGHT", -BAR_X - 8, 0)
  bar.addFarm = UI:CreateSleekButton(bar, "Add farm kit", 124, 26, function() KitView:AddKit("budget") end)
  bar.addFarm:SetPoint("RIGHT", bar.addProg, "LEFT", -6, 0)
  for _, b in ipairs({ bar.addProg, bar.addFarm }) do
    UI:AttachTooltip(b, function(self, tt)
      local side = self == bar.addProg and "best" or "budget"
      local Kt = K()
      local sum = Kt:Summary(Kt:Get(), side)
      tt:AddLine(self == bar.addProg and "Add the prog kit" or "Add the farm kit", S:Color("GOLD"))
      if sum.listCount > 0 then
        tt:AddLine("Puts what your bags lack for a night on your shopping list (Atlas):", 1, 1, 1, true)
        for id, n in pairs(sum.toList) do tt:AddDoubleLine(Kt:Name(id), tostring(n), 1, 1, 1, 0.7, 0.7, 0.7) end
      else
        tt:AddLine("Nothing to add: your bags or your list hold what a craft makes.", 1, 1, 1, true)
      end
      if sum.other > 0 then
        tt:AddLine("No craft makes the rest (scrolls, runes): the auction house.", 0.6, 0.6, 0.62, true)
      end
      if sum.cost then tt:AddLine("About " .. Money(sum.cost) .. " a night (Auctionator).", 0.6, 0.6, 0.62) end
    end, nil, { anchor = "ANCHOR_TOP" })
  end

  v:SetScript("OnShow", function() KitView:Update() end)
  return v
end

function KitView:Show(on)
  if not view then return end
  if not on then self:ClosePicker() end
  view:SetShown(on and true or false)
  if on then self:Update() end
end

function KitView:Run()
  local Kt = K()
  local ok, err = Kt:Run(function() KitView:UpdateBar(); if not Kt:IsRunning() then KitView:Update() end end)
  if not ok and err then ns:Print("%s", tostring(err)) end
  self:Update()
end

function KitView:AddKit(side)
  local Kt = K()
  local n = Kt:AddToList(Kt:Get(), side)
  if n > 0 then
    ns:Print("%d %s on your shopping list (Atlas).", n, n == 1 and "item is" or "items are")
  end
  self:Update()
end

-- The bar: the two kits' DPS after a run (else the Sim button; nothing for a spec the sim doesn't cover), the prog kit
-- in my bags, the buttons.
function KitView:UpdateBar()
  if not (view and view:IsShown()) then return end
  local bar, Kt = view.bar, K()
  local rows = Kt:Get() or {}
  local res = Kt:Results()
  local running = Kt:IsRunning()
  local canSim = Kt:CanSim()
  local showSim = canSim and (running or not res)
  bar.sim:SetShown(showSim)
  bar.prog:SetShown(res and not showSim and true or false)
  bar.farm:SetShown(res and not showSim and true or false)
  bar.simNote:SetShown(running)
  bar.progress:SetShown(running)
  if showSim then
    bar.sim:SetText(running and "Stop" or "Sim the kit")
    if running then
      local f, paused = Kt:Progress()
      bar.progress:SetWidth(max(1, floor(110 * f + 0.5)))
      bar.simNote:SetText(paused and "Paused in combat" or ("%d%%"):format(floor(f * 100)))
    end
  elseif res then
    bar.prog.big:SetText(Signed(res.prog or 0) .. " DPS")
    bar.farm.big:SetText(Signed(res.farm or 0) .. " DPS")
    -- a slot left out or put back since: the totals are old (click to sim again)
    for _, b in ipairs({ bar.prog, bar.farm }) do
      local col = res.stale and GREY or GREEN
      b.big:SetTextColor(col[1], col[2], col[3])
    end
  end
  local prog, farm = Kt:Summary(rows, "best"), Kt:Summary(rows, "budget")
  local n = 0
  for _, row in ipairs(rows) do
    local ids = Kt:SideIds(row, "best")
    if #ids > 0 and not Kt:IsOff("best", row.key) then
      n = n + 1
      local p = bar.pips[n]
      p:Show()
      if Kt:Ready(ids) then p:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 1)
      else p:SetColorTexture(0.2, 0.2, 0.23, 1) end
    end
  end
  for i = n + 1, ROWS do bar.pips[i]:Hide() end
  bar.bags:ClearAllPoints()
  bar.bags:SetPoint("LEFT", bar, "LEFT", BAR_X + PIPS_X + n * 12 + (n > 0 and 6 or 0), 0)
  bar.bags:SetText(prog.ready == prog.slots and prog.slots > 0 and Col("Ready for tonight", GREEN)
    or ("%d of %d in your bags"):format(prog.ready, prog.slots))
  bar.addProg:SetText(prog.listCount > 0 and ("Add prog kit \194\183 " .. prog.listCount) or "Add prog kit")
  bar.addFarm:SetText(farm.listCount > 0 and ("Add farm kit \194\183 " .. farm.listCount) or "Add farm kit")
  bar.addProg:SetEnabled(prog.listCount > 0)
  bar.addFarm:SetEnabled(farm.listCount > 0)
  if bar.addProg.SetKind then bar.addProg:SetKind(prog.listCount > 0 and "primary" or "secondary") end
end

function KitView:Update()
  if not (view and view:IsShown()) then return end
  local Kt = K()
  local key = Kt:SpecKey()
  local rows = Kt:Get(key)
  local spec = Kt:Spec()
  if not rows then
    for _, r in ipairs(view.rows) do r.best:Hide(); r.budget:Hide(); r.spine:Hide() end
    view.bar:Hide()
    view.emptyState:SetContent({ glyph = ns:HasAssets(6) and ns.UI.ICON.flask or ns.UI.ICON.bag,
      title = spec == "" and "Pick your spec" or "No consumables list yet",
      text = spec == "" and "Pick your spec in the spec tabs above to see its consumables."
        or ("No consumables list for " .. spec .. " yet.") })
    view.emptyState:Show()
    return
  end
  view.emptyState:Hide()
  view.bar:Show()
  local res = Kt:Results(key)
  for i, r in ipairs(view.rows) do
    local row = rows[i]
    if row then
      SetCard(r.best, row, "best", res and res.best[row.key], res and res.bestSE and res.bestSE[row.key])
      SetCard(r.budget, row, "budget", res and res.budget[row.key], res and res.budgetSE and res.budgetSE[row.key])
      r.spine:Show()
      r.spine.title:SetText(row.title)
      r.spine.why:SetText(row.why or "")
    else
      r.best:Hide(); r.budget:Hide(); r.spine:Hide()
    end
  end
  self:UpdateBar()
end

-- (tests) what the view shows: { rows = { { title, best = name, bestLine, bestReady, budget = name, budgetLine } },
-- bar = {...} }
local function Plain(s) return ((s or ""):gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
function KitView:Snapshot()
  if not view then return nil end
  local out = { shown = view:IsShown(), rows = {},
    empty = view.emptyState:IsShown() and Plain(view.empty:GetText()) or nil }
  for _, r in ipairs(view.rows) do
    if r.spine:IsShown() then
      out.rows[#out.rows + 1] = {
        title = Plain(r.spine.title:GetText()), why = Plain(r.spine.why:GetText()),
        best = Plain(r.best.name:GetText()), bestLine = Plain(r.best.line:GetText()),
        bestReady = r.best.check:IsShown(), bestCanList = r.best.canList, bestOff = r.best.off,
        budgetOff = r.budget.off,
        bestCustom = r.best.row and r.best.row.best.custom or false,
        budgetCustom = r.budget.row and r.budget.row.budget.custom or false,
        budget = Plain(r.budget.name:GetText()), budgetLine = Plain(r.budget.line:GetText()),
      }
    end
  end
  local bar = view.bar
  local pips = 0
  for _, pip in ipairs(bar.pips) do if pip:IsShown() then pips = pips + 1 end end
  out.bar = { pips = pips, sim = bar.sim:IsShown(), progShown = bar.prog:IsShown(), prog = Plain(bar.prog.big:GetText()),
    farm = Plain(bar.farm.big:GetText()), bags = Plain(bar.bags:GetText()), addProg = Plain(bar.addProg:GetText()),
    addFarm = Plain(bar.addFarm:GetText()) }
  return out
end

local function Later()
  if view and view:IsShown() and ns.Util and ns.Util.Debounce then
    ns.Util.Debounce("kitview", 0.1, function() KitView:Update() end)
  elseif view and view:IsShown() then
    KitView:Update()
  end
end
ns:RegisterEvent("BAG_UPDATE_DELAYED", Later)
ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", Later)
ns:On("SHOP_UPDATED", Later)
ns:On("KIT_CHANGED", function()
  if view and view:IsShown() then KitView:Update() end
  if KitView:IsPickerOpen() then ns.Picker:RefreshHost() end
end)
