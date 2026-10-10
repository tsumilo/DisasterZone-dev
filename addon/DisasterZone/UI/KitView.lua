if DisasterZoneBoot and DisasterZoneBoot.Run("UI/KitView.lua", ...) then return end -- DisasterZone: UI/KitView.lua
-- ns.KitView: My BiS > Consumables (the button left of Sim). The shown spec's kit (Core/Kit.lua): the best picks on
-- the left (prog nights), the budget picks on the right (farm nights), and down the middle what each slot is in one
-- line. A card is quiet: the name, what it does (or its DPS once the gear sim ran it) and a check when my bags hold a
-- night's worth; the rest (counts, who makes it, what it costs) is in its tooltip, and the bag button for the
-- shopping list shows under the mouse. The bar at the bottom adds up both kits and fills the shopping list.
local _, ns = ...

local KitView = {}
ns.KitView = KitView

local floor, max, abs = math.floor, math.max, math.abs

local GOLD = { 0.89, 0.70, 0.24 }
local GREEN = { 0.31, 0.83, 0.42 }
local AMBER = { 0.95, 0.66, 0.26 }
local GREY = { 0.56, 0.56, 0.59 }
local SOFT = { 0.72, 0.72, 0.75 }
local WHITE = { 0.95, 0.95, 0.95 }
local BAR_BG = { 0.085, 0.085, 0.1, 0.96 }

local TILE_W, TILE_H, GAP, MID_X, MID_W = 262, 56, 6, 270, 230
local HEAD_H = 18
local ROWS = 6
local KITBAR_H = 58
local READY_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"

local state = { active = false }
local view

local function K() return ns.Kit end
local FONT = (GameFontNormal and GameFontNormal:GetFont()) or "Fonts\\FRIZQT__.TTF"

local function Text(parent, size, color, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(FONT, size, "")
  fs:SetShadowOffset(1, -1)
  fs:SetShadowColor(0, 0, 0, 0.8)
  if color then fs:SetTextColor(color[1], color[2], color[3]) end
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

local function Hex(c) return ("%02x%02x%02x"):format(floor(c[1] * 255), floor(c[2] * 255), floor(c[3] * 255)) end
local function Col(text, c) return "|cff" .. Hex(c) .. text .. "|r" end

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

-- quiet = no refresh (Sim mode turning it off on its way in)
function KitView:SetActive(on, quiet)
  on = on and true or false
  if on == state.active then
    if not quiet and ns.MyBiS then ns.MyBiS:Refresh() end
    return
  end
  state.active = on
  if on and ns.SimPanel and ns.SimPanel:IsActive() then
    ns.SimPanel:SetActive(false)   -- (refreshes My BiS, with this view already on)
    return
  end
  if not on and K() and K():IsRunning() then K():Cancel() end
  if not quiet and ns.MyBiS then ns.MyBiS:Refresh() end
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
local function CardTooltip(c)
  local Kt = K()
  local row, s = c.row, c.row and c.row[c.sideKey]
  if not s then return end
  GameTooltip:SetOwner(c, c.side == "R" and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
  if s.kind == "skip" or s.kind == "same" then
    GameTooltip:AddLine(s.kind == "skip" and "Skip it" or "Same as the best pick", 1, 0.82, 0)
    if s.text and s.text ~= "" then GameTooltip:AddLine(s.text, 1, 1, 1, true) end
    GameTooltip:Show()
    return
  end
  local ids = c.ids or {}
  if #ids == 1 and GameTooltip.SetItemByID then
    GameTooltip:SetItemByID(ids[1])
    GameTooltip:AddLine(" ")
  else
    GameTooltip:AddLine(NameOf(ids), 1, 0.82, 0)
  end
  if s.text and s.text ~= "" then GameTooltip:AddLine(s.text, 1, 1, 1, true) end
  for _, id in ipairs(ids) do
    local have, need = Kt:Have(id), Kt:Need(id)
    local hc = have >= need and GREEN or AMBER
    GameTooltip:AddDoubleLine((#ids > 1 and (Kt:Name(id) .. "  ") or "") .. Col(Kt:Effect(id), SOFT),
      Col(("%d of %d in bags"):format(have, need), hc), 1, 1, 1)
    local bank = Kt:InBank(id)
    if bank > 0 then GameTooltip:AddLine(("%d more in your bank"):format(bank), 0.6, 0.6, 0.62) end
    local who = Kt:Crafter(id)
    if who == "me" then
      GameTooltip:AddLine("You can make it", 0.6, 0.6, 0.62)
    elseif who then
      GameTooltip:AddLine("Made by " .. (ns.UI.ColoredName and ns.UI:ColoredName(who) or who), 0.6, 0.6, 0.62)
    elseif not Kt:CanList(id) then
      GameTooltip:AddLine("No craft makes it: the auction house", 0.6, 0.6, 0.62)
    end
    local p = Kt:Price(id)
    if p then GameTooltip:AddLine((Money(p * need) or "") .. " a night (Auctionator)", 0.6, 0.6, 0.62) end
  end
  GameTooltip:AddLine("A night: a three hour raid.  Shift-click an icon to link it.", 0.5, 0.5, 0.52, true)
  GameTooltip:Show()
end

-- The bag button shows under the mouse (on the card or its icons) while the shopping list can take something.
local function ShowBag(c, on)
  c.bag:SetShown(on and c.canList and true or false)
end

local function Hovered(c)
  return c:IsMouseOver() or c.bag:IsMouseOver()
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
  c.bg:SetColorTexture(1, 1, 1, 1)
  local a = 0.11
  if c.bg.SetGradient and CreateColor then
    local far, near = CreateColor(0.55, 0.55, 0.62, a), CreateColor(0.55, 0.55, 0.62, a * 0.25)
    if right then c.bg:SetGradient("HORIZONTAL", near, far) else c.bg:SetGradient("HORIZONTAL", far, near) end
  else
    c.bg:SetColorTexture(0.55, 0.55, 0.62, a * 0.6)
  end
  -- the best picks: a gold edge on the outer side
  c.edge = c:CreateTexture(nil, "BORDER")
  c.edge:SetWidth(2)
  c.edge:SetPoint("TOP", c, "TOP", 0, 0)
  c.edge:SetPoint("BOTTOM", c, "BOTTOM", 0, 0)
  c.edge:SetPoint(right and "RIGHT" or "LEFT", c, right and "RIGHT" or "LEFT", 0, 0)
  c.edge:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.9)
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
  c.name = Text(c, 12, WHITE, right and "RIGHT" or "LEFT")
  c.name:SetPoint(right and "TOPRIGHT" or "TOPLEFT", c, right and "TOPRIGHT" or "TOPLEFT", right and -textX or textX, -12)
  c.name:SetWidth(room)
  c.line = Text(c, 10, SOFT, right and "RIGHT" or "LEFT")
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
  c.bag:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Shopping list", 1, 0.82, 0)
    local Kt = K()
    for id, miss in pairs(Kt:Missing(c.ids or {})) do
      if Kt:CanList(id) then
        local have = ns.Shop:GetAmount(id) or 0
        GameTooltip:AddDoubleLine(Kt:Name(id), have >= miss and ("on your list (" .. have .. ")") or ("add " .. (miss - have)),
          1, 1, 1, 0.65, 0.65, 0.68)
      end
    end
    GameTooltip:AddLine("Puts what your bags lack for a night on your shopping list (Atlas).", 0.5, 0.5, 0.52, true)
    GameTooltip:Show()
  end)
  c.bag:HookScript("OnLeave", function() if not Hovered(c) then ShowBag(c, false) end end)

  local function enter() ShowBag(c, true); CardTooltip(c) end
  local function leave()
    GameTooltip:Hide()
    if not Hovered(c) then ShowBag(c, false) end
  end
  c:SetScript("OnEnter", enter)
  c:SetScript("OnLeave", leave)
  for _, b in ipairs({ c.icon, c.sub }) do
    b:SetScript("OnEnter", enter)
    b:SetScript("OnLeave", leave)
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
  c:Show()
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
      c.name:SetText(Col("Same", GREY))
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
  s.title = Text(s, 10, GOLD, "CENTER")
  s.title:SetPoint("TOP", s, "TOP", 0, -15)
  s.why = Text(s, 10, GREY, "CENTER")
  s.why:SetPoint("TOP", s.title, "BOTTOM", 0, -5)
  s.why:SetWidth(MID_W - 20)
  return s
end

local function KitBlock(parent, caps, color)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(120, 40)
  b.caps = Text(b, 9, color)
  b.caps:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  b.caps:SetText(caps)
  b.big = Text(b, 18, GREEN)
  b.big:SetPoint("TOPLEFT", b.caps, "BOTTOMLEFT", -1, -3)
  return b
end

function KitView:Create(parent)
  if view then return view end
  local UI = ns.UI
  local v = CreateFrame("Frame", nil, parent)
  v:SetAllPoints(parent)
  v:Hide()
  view = v

  v.hBest = Text(v, 9, GOLD)
  v.hBest:SetPoint("TOPLEFT", v, "TOPLEFT", 1, -2)
  v.hBest:SetText("PROG NIGHTS")
  v.hBudget = Text(v, 9, GREY, "RIGHT")
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

  v.empty = Text(v, 12, GREY, "CENTER")
  v.empty:SetPoint("CENTER", v, "CENTER", 0, 30)
  v.empty:SetWidth(460)
  v.empty:SetWordWrap(true)

  -- the kit bar
  local bar = CreateFrame("Frame", nil, v)
  bar:SetPoint("BOTTOMLEFT", v, "BOTTOMLEFT", 0, 0)
  bar:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", 0, 0)
  bar:SetHeight(KITBAR_H)
  v.bar = bar
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(BAR_BG[1], BAR_BG[2], BAR_BG[3], BAR_BG[4])
  local top = bar:CreateTexture(nil, "ARTWORK")
  top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT")
  top:SetHeight(2)
  top:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.9)

  bar.prog = KitBlock(bar, "PROG KIT", GOLD)
  bar.prog:SetPoint("LEFT", bar, "LEFT", 14, 0)
  bar.farm = KitBlock(bar, "FARM KIT", GREY)
  bar.farm:SetPoint("LEFT", bar, "LEFT", 140, 0)
  for _, b in ipairs({ bar.prog, bar.farm }) do
    b:SetScript("OnClick", function() KitView:Run() end)
    b:SetScript("OnEnter", function(self)
      local Kt = K()
      local r = Kt:Results()
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(self == bar.prog and "Prog kit" or "Farm kit", 1, 0.82, 0)
      if r then
        GameTooltip:AddLine(("The whole kit against none, with the gear you wear: %d fights, ±%d."):format(
          Kt.ITERATIONS, floor(2 * ((self == bar.prog and r.progSE or r.farmSE) or 0) + 0.5)), 1, 1, 1, true)
      end
      local cost = Kt:Summary(Kt:Get(), self == bar.prog and "best" or "budget").cost
      if cost then GameTooltip:AddLine("About " .. Money(cost) .. " a night (Auctionator).", 1, 1, 1, true) end
      GameTooltip:AddLine("Click: sim again", 0.5, 0.5, 0.52)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  -- before a run: the Sim button in the blocks' place
  bar.sim = UI:CreateSleekButton(bar, "Sim the kit", 110, 24, function() KitView:Run() end)
  bar.sim:SetPoint("LEFT", bar, "LEFT", 14, 0)
  bar.sim:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Sim the kit", 1, 0.82, 0)
    GameTooltip:AddLine(("The gear sim gives every pick its DPS: the kit with and without it, %d fights each, with "
      .. "the gear you wear and the Sim card's buffs. Paused while you are in combat."):format(K().ITERATIONS),
      1, 1, 1, true)
    GameTooltip:Show()
  end)
  bar.sim:HookScript("OnLeave", function() GameTooltip:Hide() end)
  bar.simNote = Text(bar, 10, GREY)
  bar.simNote:SetPoint("LEFT", bar.sim, "RIGHT", 10, 0)
  bar.progress = bar:CreateTexture(nil, "OVERLAY")
  bar.progress:SetPoint("TOPLEFT", bar.sim, "BOTTOMLEFT", 0, -2)
  bar.progress:SetHeight(2)
  bar.progress:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)

  -- the prog kit in my bags: a pip per slot and "3 of 6 in your bags"
  bar.pips = {}
  for i = 1, ROWS do
    local p = bar:CreateTexture(nil, "ARTWORK")
    p:SetSize(9, 9)
    p:SetPoint("LEFT", bar, "LEFT", 296 + (i - 1) * 12, 0)
    bar.pips[i] = p
  end
  bar.bags = Text(bar, 11, SOFT)
  bar.bags:SetPoint("LEFT", bar, "LEFT", 296 + ROWS * 12 + 6, 0)
  local hit = CreateFrame("Frame", nil, bar)
  hit:SetPoint("LEFT", bar, "LEFT", 290, 0)
  hit:SetSize(230, 30)
  hit:SetScript("OnEnter", function(self)
    local Kt = K()
    local sum = Kt:Summary(Kt:Get(), "best")
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("The prog kit in your bags", 1, 0.82, 0)
    GameTooltip:AddLine("A pip per slot, green with a night's worth in your bags.", 1, 1, 1, true)
    if sum.listCount + sum.other > 0 then
      GameTooltip:AddLine(("%d to get%s."):format(sum.listCount + sum.other,
        sum.crafted > 0 and (", " .. sum.crafted .. " made by a guildie") or ""), 0.7, 0.7, 0.72, true)
    end
    GameTooltip:Show()
  end)
  hit:SetScript("OnLeave", function() GameTooltip:Hide() end)

  bar.addProg = UI:CreateSleekButton(bar, "Add prog kit", 124, 26, function() KitView:AddKit("best") end, "primary")
  bar.addProg:SetPoint("RIGHT", bar, "RIGHT", -14, 0)
  bar.addFarm = UI:CreateSleekButton(bar, "Add farm kit", 124, 26, function() KitView:AddKit("budget") end)
  bar.addFarm:SetPoint("RIGHT", bar.addProg, "LEFT", -6, 0)
  for _, b in ipairs({ bar.addProg, bar.addFarm }) do
    b:HookScript("OnEnter", function(self)
      local side = self == bar.addProg and "best" or "budget"
      local Kt = K()
      local sum = Kt:Summary(Kt:Get(), side)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(self == bar.addProg and "Add the prog kit" or "Add the farm kit", 1, 0.82, 0)
      if sum.listCount > 0 then
        GameTooltip:AddLine("Puts what your bags lack for a night on your shopping list (Atlas):", 1, 1, 1, true)
        for id, n in pairs(sum.toList) do GameTooltip:AddDoubleLine(Kt:Name(id), tostring(n), 1, 1, 1, 0.7, 0.7, 0.7) end
      else
        GameTooltip:AddLine("Nothing to add: your bags or your list hold what a craft makes.", 1, 1, 1, true)
      end
      if sum.other > 0 then
        GameTooltip:AddLine("No craft makes the rest (scrolls, runes): the auction house.", 0.6, 0.6, 0.62, true)
      end
      if sum.cost then GameTooltip:AddLine("About " .. Money(sum.cost) .. " a night (Auctionator).", 0.6, 0.6, 0.62) end
      GameTooltip:Show()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
  end

  v:SetScript("OnShow", function() KitView:Update() end)
  return v
end

function KitView:Show(on)
  if not view then return end
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
  end
  local prog, farm = Kt:Summary(rows, "best"), Kt:Summary(rows, "budget")
  for i, p in ipairs(bar.pips) do
    local row = rows[i]
    if row then
      p:Show()
      if Kt:Ready(Kt:SideIds(row, "best")) then p:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 1)
      else p:SetColorTexture(0.2, 0.2, 0.23, 1) end
    else
      p:Hide()
    end
  end
  for i = #rows + 1, ROWS do bar.pips[i]:Hide() end
  bar.bags:ClearAllPoints()
  bar.bags:SetPoint("LEFT", bar, "LEFT", 296 + #rows * 12 + 6, 0)
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
    view.empty:Show()
    view.empty:SetText(spec == "" and "Pick your spec in the spec tabs above to see its consumables."
      or ("No consumables list for " .. spec .. " yet."))
    return
  end
  view.empty:Hide()
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
  local out = { shown = view:IsShown(), rows = {}, empty = view.empty:IsShown() and Plain(view.empty:GetText()) or nil }
  for _, r in ipairs(view.rows) do
    if r.spine:IsShown() then
      out.rows[#out.rows + 1] = {
        title = Plain(r.spine.title:GetText()), why = Plain(r.spine.why:GetText()),
        best = Plain(r.best.name:GetText()), bestLine = Plain(r.best.line:GetText()),
        bestReady = r.best.check:IsShown(), bestCanList = r.best.canList,
        budget = Plain(r.budget.name:GetText()), budgetLine = Plain(r.budget.line:GetText()),
      }
    end
  end
  local bar = view.bar
  out.bar = { sim = bar.sim:IsShown(), progShown = bar.prog:IsShown(), prog = Plain(bar.prog.big:GetText()),
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
