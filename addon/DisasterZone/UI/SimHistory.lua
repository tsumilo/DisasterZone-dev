if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SimHistory.lua", ...) then return end -- DisasterZone: UI/SimHistory.lua
-- ns.SimHistoryUI: the gear sim's Recent runs (Sim/History.lua keeps them, the last 10 per character), over the Gear
-- sim page like Nerd stats ("< Results" goes back). The list on the left, newest first: when, what the run tried
-- (the items it changed against what it was compared with), the Working set's DPS and the difference then. Click
-- runs to pick them (two at most): the card on the right shows one run, or compares two: their DPS on the same rolls,
-- the gear between them and any setting that differs. Open brings a run back on the page (nothing is simmed).
local addonName, ns = ...

local HUI = {}
ns.SimHistoryUI = HUI

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local FONT = (GameFontNormal and GameFontNormal:GetFont()) or "Fonts\\FRIZQT__.TTF"
local NUM = "Fonts\\ARIALN.TTF"
local W, H = 770, 496
local TOP = 56                -- the list and the card start here (under the title and the rule)
local LIST_W = 466
local ROW_H, ROW_GAP = 38, 4
local CARD_X = LIST_W + 16
local CARD_W = W - CARD_X
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local CHECK_OK, CHECK_NO = "Interface\\RaidFrame\\ReadyCheck-Ready", "Interface\\RaidFrame\\ReadyCheck-NotReady"

local C = {
  gold = { 1, 0.82, 0 }, gold2 = { 0.886, 0.702, 0.243 }, text = { 0.925, 0.925, 0.925 },
  dim = { 0.561, 0.561, 0.584 }, label = { 0.659, 0.659, 0.682 }, green = { 0.31, 0.83, 0.42 },
  red = { 0.88, 0.38, 0.31 }, grey = { 0.49, 0.49, 0.51 }, row = { 0.106, 0.106, 0.122 },
  rowHover = { 0.133, 0.133, 0.153 }, rowPicked = { 0.149, 0.133, 0.098 }, box = { 0.094, 0.094, 0.11 },
  edge = { 0.137, 0.137, 0.157 }, line = { 0.149, 0.149, 0.173 }, track = { 0.137, 0.137, 0.157 },
  barRef = { 0.478, 0.478, 0.51 }, okText = { 0.659, 0.847, 0.69 }, noText = { 0.92, 0.62, 0.58 },
  warn = { 1, 0.70, 0.35 }, ink = { 0.08, 0.07, 0.05 },
}

local function R() return ns.SimRunner end
local function P() return ns.SimPanel end
local function Hist() return ns.SimHistory end
local function Fmt(v) return ns.SimPanel.Fmt(v) end
local function Signed(v) return ns.SimPanel.Signed(v) end

local function Text(parent, size, color, justify, font)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(font or FONT, size, "")
  fs:SetShadowOffset(1, -1)
  fs:SetShadowColor(0, 0, 0, 0.7)
  if color then fs:SetTextColor(color[1], color[2], color[3]) end
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

local function Tex(parent, layer, c, a)
  local t = parent:CreateTexture(nil, layer or "ARTWORK")
  t:SetColorTexture(c[1], c[2], c[3], a or 1)
  return t
end

local function Put(region, parent, x, y, point)
  region:ClearAllPoints()
  region:SetPoint(point or "TOPLEFT", parent, "TOPLEFT", x, -y)
  return region
end

local function Cap(parent, text)
  local fs = Text(parent, 8.5, C.dim)
  fs:SetText(ns.SimStage.Spaced(text))
  return fs
end

local function ItemIcon(id)
  if not id then return nil end
  if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(id) end
  return GetItemIcon and GetItemIcon(id) or nil
end

-- an item's name in its quality colour ("Empty" for nothing)
local function ItemText(id)
  if not id then return "|cff8f8f95Empty|r" end
  local name, _, q
  if ns.ItemDB then name, _, q = ns.ItemDB:GetInfo(id) end
  if not name then return "|cff8f8f95Item " .. id .. "|r" end
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
  if c and c.hex then return c.hex .. name .. "|r" end
  return name
end

local function SlotLabel(sid) return ns.SLOTS and ns.SLOTS[sid] and ns.SLOTS[sid].label or ("Slot " .. sid) end

local function Duration(d) d = tonumber(d) or 180 return ("%d:%02d"):format(floor(d / 60), d % 60) end

-- "1,000 × 3:00" (+ the boss when it isn't the usual one)
local function SettingsShort(s)
  s = s or {}
  local out = ("%s \195\151 %s"):format(Fmt(s.fights or 0), Duration(s.duration))
  if s.mobType and s.mobType ~= "Mechanical" then out = out .. "  \194\183  " .. s.mobType end
  return out
end

-- green / red / grey for a difference and its error: the stage's rule (UI/SimStage.lua FillResults)
local function Verdict(d, se)
  if abs(d) < 0.5 then return C.grey, "none" end
  if abs(d) < 2 * (se or 0) then return C.grey, "close" end
  return d > 0 and C.green or C.red, d > 0 and "up" or "down"
end

local function Pct(d, base)
  local pct = d / max(1, base) * 100
  if abs(pct) < 0.05 then return "0.0%" end
  return (pct >= 0 and "+" or "\226\136\146") .. ("%.1f%%"):format(abs(pct))
end

-- ---------------------------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------------------------
local clip, root, list, card
local rows = {}
local picked = {}            -- run ids picked (two at most, in the order picked)

local function Body() return ns.SimStage and ns.SimStage._frame() end

local function IsMine(run) return run and run.spec == R():SpecKey() end

local function IsPicked(id)
  for i, v in ipairs(picked) do if v == id then return i end end
  return nil
end

-- The picked runs, newest first (A = the later one).
local function PickedRuns()
  local out = {}
  for _, run in ipairs(Hist():Runs()) do
    if IsPicked(run.id) then out[#out + 1] = run end
  end
  return out
end

-- picks that are gone (removed, pushed out of the list) go too
local function TidyPicks()
  local keep = {}
  for _, id in ipairs(picked) do
    if Hist():Get(id) then keep[#keep + 1] = id end
  end
  picked = keep
end

-- ---------------------------------------------------------------------------------------------------------------
-- The frame
-- ---------------------------------------------------------------------------------------------------------------
local function BackLink(parent)
  local back = CreateFrame("Button", nil, parent)
  back:SetSize(90, 14)
  Put(back, parent, 0, 0)
  back.icon = back:CreateTexture(nil, "ARTWORK")
  back.icon:SetSize(10, 10)
  back.icon:SetPoint("LEFT", 0, 0)
  ns.UI:SetChevron(back.icon, false)
  back.fs = back:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  back.fs:SetFont((back.fs:GetFont()), 10, "")
  back.fs:SetJustifyH("LEFT")
  back.fs:SetPoint("LEFT", back.icon, "RIGHT", 4, 0)
  local function paint(self, on)
    local r, g, bl = 0.65, 0.65, 0.65
    if on then r, g, bl = 1, 0.82, 0 end
    self.fs:SetTextColor(r, g, bl)
    self.icon:SetVertexColor(r, g, bl)
  end
  paint(back, false)
  back:SetScript("OnEnter", function(self) paint(self, true) end)
  back:SetScript("OnLeave", function(self) paint(self, false) end)
  back:SetScript("OnClick", function() HUI:Close() end)
  return back
end

local Row, Card

local function Create()
  if clip then return true end
  local body = Body()
  if not body then return false end
  clip = CreateFrame("Frame", nil, ns.SimStage:OverlayParent() or body)
  clip:SetFrameLevel(body:GetFrameLevel() + 30)
  if clip.SetClipsChildren then clip:SetClipsChildren(true) end
  clip:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  clip:SetPoint("BOTTOMRIGHT", body, "TOPLEFT", W, -H)
  clip:Hide()
  root = CreateFrame("Frame", nil, clip)
  root:SetSize(W, H)
  root:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  root:EnableMouse(true)

  root.back = BackLink(root)
  root.title = Put(Text(root, 17, C.gold), root, 0, 17)
  root.title:SetText("Recent runs")
  root.sub = Text(root, 10.5, C.dim)
  root.sub:SetPoint("BOTTOMLEFT", root.title, "BOTTOMRIGHT", 14, 2)
  root.sub:SetPoint("RIGHT", root, "RIGHT", 0, 0)
  local rule = Tex(root, "ARTWORK", C.line)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -44)
  rule:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, -44)

  list = CreateFrame("Frame", nil, root)
  list:SetSize(LIST_W, H - TOP)
  Put(list, root, 0, TOP)
  list.empty = Text(list, 11.5, C.dim, "CENTER")
  list.empty:SetWidth(LIST_W - 40)
  list.empty:SetWordWrap(true)
  list.empty:SetPoint("TOP", list, "TOP", 0, -120)
  list.empty:SetText("No runs yet. Every run of the Gear sim lands here: the last 10 on this character.")

  card = CreateFrame("Frame", nil, root)
  card:SetSize(CARD_W, H - TOP)
  Put(card, root, CARD_X, TOP)
  Tex(card, "BACKGROUND", C.box):SetAllPoints()
  if ns.UI.AddEdges then
    ns.UI:AddEdges(card, "BORDER")
    ns.UI:SetEdgeColor(card, C.edge[1], C.edge[2], C.edge[3], 1)
  end
  HUI.root = root
  return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- A row of the list
-- ---------------------------------------------------------------------------------------------------------------
local function PaintRow(r)
  local run = r.run
  local at = run and IsPicked(run.id)
  local c = at and C.rowPicked or (r.hover and C.rowHover or C.row)
  r.bg:SetColorTexture(c[1], c[2], c[3], 1)
  r.edge:SetShown(at and true or false)
  -- the pick box: A / B in gold when picked (A = the later of the two)
  local letter
  if at then
    local pr = PickedRuns()
    letter = (#pr == 2 and pr[2].id == run.id) and "B" or "A"
  end
  r.box:SetColorTexture(at and C.gold2[1] or 0.07, at and C.gold2[2] or 0.07, at and C.gold2[3] or 0.08, 1)
  r.boxEdge:SetColorTexture(at and C.gold2[1] or 0.25, at and C.gold2[2] or 0.25, at and C.gold2[3] or 0.27, 1)
  r.letter:SetText(letter or "")
  r.bin:SetShown(r.hover and true or false)
end

Row = function(i)
  local r = rows[i]
  if r then return r end
  r = CreateFrame("Button", nil, list)
  r:SetSize(LIST_W, ROW_H)
  Put(r, list, 0, (i - 1) * (ROW_H + ROW_GAP))
  r:RegisterForClicks("LeftButtonUp")
  r.bg = Tex(r, "BACKGROUND", C.row)
  r.bg:SetAllPoints()
  r.edge = Tex(r, "BORDER", C.gold2)
  r.edge:SetPoint("TOPLEFT"); r.edge:SetPoint("BOTTOMLEFT"); r.edge:SetWidth(2)
  -- pick box
  r.boxEdge = Tex(r, "BORDER", { 0.25, 0.25, 0.27 })
  r.boxEdge:SetSize(16, 16)
  r.boxEdge:SetPoint("LEFT", r, "LEFT", 10, 0)
  r.box = Tex(r, "ARTWORK", { 0.07, 0.07, 0.08 })
  r.box:SetPoint("TOPLEFT", r.boxEdge, "TOPLEFT", 1, -1)
  r.box:SetPoint("BOTTOMRIGHT", r.boxEdge, "BOTTOMRIGHT", -1, 1)
  r.letter = Text(r, 10, C.ink, "CENTER")
  r.letter:SetShadowOffset(0, 0)
  r.letter:SetPoint("CENTER", r.boxEdge, "CENTER", 0, 0)
  -- when
  r.time = Text(r, 12, C.text)
  r.time:SetPoint("TOPLEFT", r, "TOPLEFT", 36, -6)
  r.day = Text(r, 9.5, C.dim)
  r.day:SetPoint("TOPLEFT", r, "TOPLEFT", 36, -22)
  -- the items it changed
  r.icons = {}
  for k = 1, 2 do
    local t = r:CreateTexture(nil, "ARTWORK")
    t:SetSize(24, 24)
    t:SetPoint("LEFT", r, "LEFT", 92 + (k - 1) * 27, 0)
    t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.icons[k] = t
  end
  r.more = Text(r, 9.5, C.label, "CENTER")
  r.more:SetPoint("CENTER", r.icons[2], "CENTER", 0, 0)
  -- what and against what
  r.what = Text(r, 11.5, C.text)
  r.what:SetPoint("TOPLEFT", r, "TOPLEFT", 150, -6)
  r.what:SetWidth(222)
  r.vs = Text(r, 9.5, C.dim)
  r.vs:SetPoint("TOPLEFT", r, "TOPLEFT", 150, -22)
  r.vs:SetWidth(222)
  -- numbers
  r.dps = Text(r, 13, C.text, "RIGHT", NUM)
  r.dps:SetPoint("TOPRIGHT", r, "TOPRIGHT", -34, -5)
  r.delta = Text(r, 10.5, C.grey, "RIGHT", NUM)
  r.delta:SetPoint("TOPRIGHT", r, "TOPRIGHT", -34, -21)
  r.bin = ns.UI:CreateRemoveButton(r, "Remove this run")
  r.bin:SetPoint("RIGHT", r, "RIGHT", -8, 0)
  r.bin:SetScript("OnClick", function()
    if r.run then HUI:Remove(r.run.id) end
  end)
  r.bin:HookScript("OnEnter", function() r.hover = true PaintRow(r) end)
  r.bin:Hide()
  r:SetScript("OnEnter", function(self)
    self.hover = true
    PaintRow(self)
    if self.run and not IsMine(self.run) then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(tostring(self.run.specName or "Another spec"), 1, 0.82, 0)
      GameTooltip:AddLine("A run of another spec: pick that spec in the tabs above to open or compare it.", 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  r:SetScript("OnLeave", function(self)
    if self.bin:IsMouseOver() then return end
    self.hover = false
    PaintRow(self)
    GameTooltip:Hide()
  end)
  r:SetScript("OnClick", function(self)
    if self.run and IsMine(self.run) then HUI:Pick(self.run.id) end
  end)
  rows[i] = r
  return r
end

local function FillRow(r, run)
  r.run = run
  local mine = IsMine(run)
  r:SetAlpha(mine and 1 or 0.45)
  local when = P().RunWhen(run.at)
  local today = date and date("*t", time()) or {}
  local d = date and date("*t", run.at or 0) or {}
  if d.yday == today.yday and d.year == today.year then
    r.time:SetText(when)
    r.day:SetText("Today")
  elseif (time() - (run.at or 0)) < 6 * 86400 then
    r.time:SetText(("%d:%02d"):format(d.hour or 0, d.min or 0))
    r.day:SetText(date("%A", run.at))
  else
    r.time:SetText(("%d %s"):format(d.day or 0, date("%b", run.at)))
    r.day:SetText(("%d:%02d"):format(d.hour or 0, d.min or 0))
  end
  local ch = P():RunChanges(run)
  for k = 1, 2 do
    local c = ch[k]
    local icon = r.icons[k]
    if c and not (k == 2 and #ch > 2) then
      icon:SetTexture(ItemIcon(c.id or c.was) or QUESTION)
      icon:SetDesaturated(not c.id)
      icon:SetVertexColor(1, 1, 1, 1)
      icon:Show()
    elseif k == 2 and #ch > 2 then
      icon:SetColorTexture(0.16, 0.16, 0.18, 1)
      icon:Show()
    else
      icon:Hide()
    end
  end
  r.more:SetText(#ch > 2 and ("+" .. (#ch - 1)) or "")
  r.what:SetText(P():RunChangeText(run))
  local vs = "vs " .. (run.targetText or "My gear")
  if not mine then vs = tostring(run.specName or "") .. "  \194\183  " .. vs end
  r.vs:SetText(vs .. "  \194\183  " .. SettingsShort(run.settings))
  r.dps:SetText(Fmt(run.dps or 0))
  local col, kind = Verdict(run.diff or 0, run.se or 0)
  r.delta:SetText(kind == "none" and "\194\177 0" or Signed(run.diff or 0))
  r.delta:SetTextColor(col[1], col[2], col[3])
  r:Show()
  PaintRow(r)
end

-- ---------------------------------------------------------------------------------------------------------------
-- The card on the right
-- ---------------------------------------------------------------------------------------------------------------
local function FreshCard()
  if card.inner then card.inner:Hide(); card.inner:SetParent(nil) end
  local f = CreateFrame("Frame", nil, card)
  f:SetAllPoints()
  card.inner = f
  return f
end

local function CmpBar(parent, y, letter, label, value, frac, gold)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(CARD_W - 24, 30)
  Put(f, parent, 12, y)
  local l = Text(f, 10.5, gold and { 0.941, 0.902, 0.784 } or C.label)
  l:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  local prefix = letter and ("|cffe2b33e" .. letter .. "|r  ") or ""
  if type(label) == "table" then
    l:SetText(prefix .. label[1])
    if (tonumber(l:GetStringWidth()) or 0) > CARD_W - 24 - 64 then l:SetText(prefix .. label[2]) end
  else
    l:SetText(prefix .. label)
  end
  local v = Text(f, 11.5, C.text, "RIGHT", NUM)
  v:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 1)
  v:SetText(Fmt(value))
  local track = Tex(f, "ARTWORK", C.track)
  track:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -16)
  track:SetSize(CARD_W - 24, 6)
  local fill = f:CreateTexture(nil, "ARTWORK", nil, 1)
  fill:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
  fill:SetSize(max(1, (CARD_W - 24) * max(0, min(1, frac))), 6)
  if gold then
    fill:SetColorTexture(1, 1, 1, 1)
    if fill.SetGradient and CreateColor then
      fill:SetGradient("HORIZONTAL", CreateColor(0.604, 0.455, 0.125, 1), CreateColor(1, 0.843, 0.353, 1))
    else
      fill:SetVertexColor(C.gold2[1], C.gold2[2], C.gold2[3], 1)
    end
  else
    fill:SetColorTexture(C.barRef[1], C.barRef[2], C.barRef[3], 1)
  end
  return f
end

-- the big signed difference + percentage, and the verdict under it
local function DeltaBlock(f, y, d, se, base, better, worse)
  local col, kind = Verdict(d, se)
  local a = Text(f, 17, col)
  a:SetText(Signed(d) .. " DPS")
  local b = Text(f, 13, col)
  b:SetText(Pct(d, base))
  local wa, wb = tonumber(a:GetStringWidth()) or 70, tonumber(b:GetStringWidth()) or 40
  local x0 = floor((CARD_W - (wa + 6 + wb)) / 2)
  Put(a, f, x0, y)
  b:SetPoint("BOTTOMLEFT", a, "BOTTOMRIGHT", 6, 1)
  local v = Text(f, 10.5, C.dim, "CENTER")
  v:SetWidth(CARD_W - 20)
  Put(v, f, 10, y + 26)
  local sure = ("\194\177%s"):format(Fmt(2 * (se or 0)))
  if kind == "none" then
    v:SetText("No difference")
  elseif kind == "close" then
    v:SetText("Too close to call  |cff8f8f95\194\183  " .. sure .. "|r")
  elseif kind == "up" then
    v:SetText(("|T%s:12:12:0:0|t %s  |cff8f8f95\194\183  %s|r"):format(CHECK_OK, better, sure))
    v:SetTextColor(C.okText[1], C.okText[2], C.okText[3])
  else
    v:SetText(("|T%s:12:12:0:0|t %s  |cff8f8f95\194\183  %s|r"):format(CHECK_NO, worse, sure))
    v:SetTextColor(C.noText[1], C.noText[2], C.noText[3])
  end
end

-- gear lines: "[was] > [now] Item name", at most `room` lines (the last says how many more)
local function GearLines(f, y, changes, room)
  local shown = #changes > room and room - 1 or #changes
  for i = 1, shown do
    local c = changes[i]
    local ly = y + (i - 1) * 22
    local was = f:CreateTexture(nil, "ARTWORK")
    was:SetSize(18, 18)
    Put(was, f, 12, ly)
    was:SetTexture(ItemIcon(c.was) or QUESTION)
    was:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    was:SetDesaturated(true)
    was:SetAlpha(c.was and 0.8 or 0.25)
    local arrow = f:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(8, 8)
    arrow:SetPoint("LEFT", was, "RIGHT", 4, 0)
    ns.UI:SetChevron(arrow, true)
    arrow:SetVertexColor(C.dim[1], C.dim[2], C.dim[3])
    local now = f:CreateTexture(nil, "ARTWORK")
    now:SetSize(18, 18)
    now:SetPoint("LEFT", arrow, "RIGHT", 4, 0)
    now:SetTexture(ItemIcon(c.id) or QUESTION)
    now:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    now:SetAlpha(c.id and 1 or 0.25)
    local name = Text(f, 10.5, C.text)
    name:SetPoint("LEFT", now, "RIGHT", 7, 0)
    name:SetWidth(CARD_W - 86)
    name:SetText(c.id and ItemText(c.id) or ("|cff8f8f95No " .. SlotLabel(c.sid):lower() .. "|r"))
  end
  if #changes > shown then
    local more = Text(f, 10, C.dim)
    Put(more, f, 12, y + shown * 22 + 3)
    more:SetText(("and %d more"):format(#changes - shown))
  end
  return y + min(#changes, room) * 22
end

-- the settings two runs don't share: { "Buffs  25-man > 10-man", ... }
local function SettingDiffs(a, b)
  local out = {}
  local sa, sb = a.settings or {}, b.settings or {}
  if sa.fights ~= sb.fights then out[#out + 1] = ("Fights  %s \226\128\186 %s"):format(Fmt(sb.fights or 0), Fmt(sa.fights or 0)) end
  if sa.duration ~= sb.duration then
    out[#out + 1] = ("Fight length  %s \226\128\186 %s"):format(Duration(sb.duration), Duration(sa.duration))
  end
  if sa.mobType ~= sb.mobType then out[#out + 1] = ("Boss  %s \226\128\186 %s"):format(tostring(sb.mobType), tostring(sa.mobType)) end
  if sa.buffs ~= sb.buffs then
    out[#out + 1] = ("Buffs  %s \226\128\186 %s"):format(tostring(b.buffsText or sb.buffs), tostring(a.buffsText or sa.buffs))
  end
  if sa.talents ~= sb.talents then out[#out + 1] = "Talents changed" end
  if a.version ~= b.version then
    out[#out + 1] = ("Addon version  %s \226\128\186 %s"):format(tostring(b.version or "?"), tostring(a.version or "?"))
  end
  return out
end

local function OpenButton(f, label, run, x, w, kind)
  local b = ns.UI:CreateSleekButton(f, label, w, 24, function()
    HUI:OpenRun(run.id)
  end, kind or "secondary")
  Put(b, f, x, H - TOP - 36)
  b:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Open this run", 1, 0.82, 0)
    GameTooltip:AddLine("Brings it back on the Gear sim page: its Working set, what it was compared with and its "
      .. "settings, with its result. Nothing is simmed.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  b:HookScript("OnLeave", function() GameTooltip:Hide() end)
  if P()._state().running then b:Disable() end
  return b
end

local function OneRun(f, run)
  local cap = Put(Cap(f, "This run"), f, 12, 11)
  local when = Text(f, 9.5, C.dim, "RIGHT")
  when:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -10)
  when:SetText(P().RunWhen(run.at, true))
  local a, b = run.dps or 0, run.refDps or 0
  local lo, hi = min(a, b) * 0.85, max(a, b) * 1.01
  CmpBar(f, 34, nil, run.targetText or "My gear", b, (b - lo) / max(1, hi - lo), false)
  CmpBar(f, 68, nil, "Working set", a, (a - lo) / max(1, hi - lo), true)
  DeltaBlock(f, 108, run.diff or 0, run.se or 0, b, "A real upgrade", "A downgrade")
  local y = 164
  local ch = P():RunChanges(run)
  Put(Cap(f, #ch == 0 and "Same gear on both" or "What it tried"), f, 12, y)
  y = GearLines(f, y + 18, ch, 6)
  y = y + 14
  Put(Cap(f, "Settings"), f, 12, y)
  local s = Text(f, 10.5, C.label)
  s:SetWidth(CARD_W - 24)
  Put(s, f, 12, y + 18)
  s:SetText(SettingsShort(run.settings) .. "  \194\183  " .. tostring(run.buffsText or ""))
  OpenButton(f, "Open", run, 12, CARD_W - 24, "primary")
  return cap
end

local function TwoRuns(f, A, B)
  Put(Cap(f, "Compare"), f, 12, 11)
  local hint = Text(f, 9.5, C.dim, "RIGHT")
  hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -10)
  hint:SetText("Working sets")
  local Aw = Hist():Summaries(A)
  local Bw = Hist():Summaries(B)
  local a, b = A.dps or 0, B.dps or 0
  local d, se = a - b, 0
  if Aw and Bw then d, se = Hist().Diff(Aw, Bw, A.seed ~= nil and A.seed == B.seed) end
  local lo, hi = min(a, b) * 0.85, max(a, b) * 1.01
  local function name(run) return { P():RunChangeText(run), "My " .. P().RunWhen(run.at) .. " run" } end
  CmpBar(f, 34, "B", name(B), b, (b - lo) / max(1, hi - lo), false)
  CmpBar(f, 68, "A", name(A), a, (a - lo) / max(1, hi - lo), true)
  DeltaBlock(f, 108, d, se, b, "A is better", "A is worse")
  local y = 164
  -- gear between B and A
  local ch = {}
  for sid = 1, 19 do
    local x, w = A.work and A.work[sid], B.work and B.work[sid]
    if not R():SameEntry(x, w) then ch[#ch + 1] = { sid = sid, id = x and x.id, was = w and w.id } end
  end
  local diffs = SettingDiffs(A, B)
  Put(Cap(f, #ch == 0 and "Same gear on both" or "From B to A"), f, 12, y)
  y = GearLines(f, y + 18, ch, #diffs > 0 and 4 or 6)
  if #diffs == 0 then
    y = y + 14
    Put(Cap(f, "Settings, both"), f, 12, y)
    local same = Text(f, 10.5, C.label)
    same:SetWidth(CARD_W - 24)
    Put(same, f, 12, y + 18)
    same:SetText(SettingsShort(A.settings) .. "  \194\183  " .. tostring(A.buffsText or ""))
  else
    y = y + 8
    local warn = Text(f, 10, C.warn)
    warn:SetWidth(CARD_W - 24)
    Put(warn, f, 12, y)
    warn:SetText("Not the gear alone: settings differ")
    y = y + 16
    for i = 1, min(#diffs, 3) do
      local l = Text(f, 10, C.label)
      l:SetWidth(CARD_W - 24)
      Put(l, f, 12, y)
      l:SetText(diffs[i])
      y = y + 15
    end
  end
  local half = floor((CARD_W - 24 - 8) / 2)
  OpenButton(f, "Open A", A, 12, half)
  OpenButton(f, "Open B", B, 12 + half + 8, half)
end

Card = function()
  local f = FreshCard()
  local pr = PickedRuns()
  if #pr == 2 then
    TwoRuns(f, pr[1], pr[2])
  elseif #pr == 1 then
    OneRun(f, pr[1])
  else
    local t = Text(f, 11, C.dim, "CENTER")
    t:SetWidth(CARD_W - 40)
    t:SetWordWrap(true)
    t:SetPoint("TOP", f, "TOP", 0, -150)
    t:SetText(#Hist():Runs() > 0 and "Click a run to see it, or two to compare them." or "")
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Open / close / refresh
-- ---------------------------------------------------------------------------------------------------------------
function HUI:Paint()
  if not root then return end
  TidyPicks()
  local runs = Hist():Runs()
  local mine = 0
  for _, run in ipairs(runs) do if IsMine(run) then mine = mine + 1 end end
  root.back.fs:SetText(P()._state().results and "RESULTS" or "GEAR SIM")
  root.sub:SetText(("The last %d on this character  \194\183  sets simmed before are not simmed again")
    :format(Hist().MAX_RUNS))
  for i = 1, max(#runs, #rows) do
    local run = runs[i]
    if run then FillRow(Row(i), run) elseif rows[i] then rows[i]:Hide() end
  end
  list.empty:SetShown(#runs == 0)
  Card()
end

function HUI:IsOpen() return clip and clip:IsShown() and self.open or false end

-- Opens the page with the two newest runs of this spec picked (the newest alone when there is one).
function HUI:Open()
  if ns.SimNerd and ns.SimNerd.IsOpen and ns.SimNerd:IsOpen() then ns.SimNerd:Close(true) end
  if not Create() then return end
  picked = {}
  for _, run in ipairs(Hist():Runs()) do
    if IsMine(run) and #picked < 2 then picked[#picked + 1] = run.id end
  end
  self.open = true
  local was = clip:IsShown()
  clip:Show()
  ns.SimStage:Cover(true)
  self:Paint()
  if not was and ns.SimNerd and ns.SimNerd.FadeIn then ns.SimNerd.FadeIn(clip) end
end

function HUI:Close(instant)
  self.open = false
  if not clip or not clip:IsShown() then return end
  clip:Hide()
  ns.SimStage:Cover(false)
  if not instant and ns.SimStage and ns.SimStage.FadePage then ns.SimStage:FadePage() end
end

-- A new run saved while the page is open (or one removed): the list follows.
function HUI:Refresh()
  if self:IsOpen() then self:Paint() end
end

-- A click on a run: picked (two at most: a third replaces the one picked first) or unpicked.
function HUI:Pick(id)
  local at = IsPicked(id)
  if at then
    table.remove(picked, at)
  else
    picked[#picked + 1] = id
    if #picked > 2 then table.remove(picked, 1) end
  end
  for _, r in ipairs(rows) do if r:IsShown() then PaintRow(r) end end
  Card()
end

function HUI:Remove(id)
  Hist():Remove(id)
  if P()._state().target == "run:" .. id then P()._state().target = "gear" end
  self:Paint()
  if ns.SimStage and ns.SimStage.Sync then ns.SimStage:Sync(false) end
end

function HUI:OpenRun(id)
  if P():OpenRun(id) then self:Close() end
end

-- (tests) the picked ids and the rows
function HUI._picked() return picked end
function HUI._rows() return rows end
function HUI._card() return card end
