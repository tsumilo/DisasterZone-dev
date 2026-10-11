if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SimHistory.lua", ...) then return end -- DisasterZone: UI/SimHistory.lua
-- ns.SimHistoryUI: the gear sim's Recent runs (Sim/History.lua keeps them, the last 10 per character), over the Gear
-- sim page like Nerd stats ("< Results" goes back). The list on the left, newest first: when, what the run tried
-- (the items it changed against what it was compared with), the Working set's DPS and the difference then. Click
-- runs to pick them (two at most): the card on the right shows one run, or compares two: their DPS on the same rolls,
-- the gear between them and any setting that differs. Open brings a run back on the page (nothing is simmed).
-- A list + detail page (UI:CreateLayout "listdetail") under the page's strip banner; the detail opens with its own
-- banner (D3).
local addonName, ns = ...

local HUI = {}
ns.SimHistoryUI = HUI

local UI, S = ns.UI, ns.Style
local K = ns.SimStage.Kit        -- the stage's shared pieces (UI/SimStage.lua): palette, text, bars, verdicts
local floor, max, min = math.floor, math.max, math.min

local NUM = K.NUM
local W, H = 770, 496
local TOP = S.BANNER.strip + S.GAP  -- the list and the card start here (under the page's banner)
local LIST_W = 466
local ROW_H = S.ROW.rich          -- the list's rows (the shared row look: hairline, hover, the picked one lit)
local CARD_W = W - LIST_W - S.GAP
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

-- The page's palette: the stage's (ns.Style tokens for text and verdicts).
local C = setmetatable({ label = K.C.sentence, warn = S.C.WARN }, { __index = K.C })

local function R() return ns.SimRunner end
local function P() return ns.SimPanel end
local function Hist() return ns.SimHistory end
local function Fmt(v) return ns.SimPanel.Fmt(v) end
local function Signed(v) return ns.SimPanel.Signed(v) end

-- UI:Text's options for the page's lines (S.STYLE names): left / centred, the numerals in the narrow number font;
-- all with the shared drop shadow.
local T_L = { justify = "LEFT", shadow = true }
local T_C = { justify = "CENTER", shadow = true }
local T_RN = { justify = "RIGHT", font = NUM, shadow = true }

local Put, Verdict = K.Put, K.Verdict

local function ItemIcon(id) return id and UI:ItemIcon(id) or QUESTION end

-- an item's name in its quality colour ("Empty" for nothing, "Item 123" while it loads)
local function ItemText(id)
  if not id then return S:Wrap("SUB", "Empty") end
  local text, loading = UI:ItemText(id)
  if loading then return S:Wrap("SUB", "Item " .. id) end
  return text
end

local function Duration(d) d = tonumber(d) or 180 return ("%d:%02d"):format(floor(d / 60), d % 60) end

-- "1,000 × 3:00" (+ the boss when it isn't the usual one)
local function SettingsShort(s)
  s = s or {}
  local out = ("%s \195\151 %s"):format(Fmt(s.fights or 0), Duration(s.duration))
  if s.mobType and s.mobType ~= "Mechanical" then out = out .. "  \194\183  " .. s.mobType end
  return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------------------------
local clip, root, layout, list, card
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
local Row, Card

local function Create()
  if clip then return true end
  local body = Body()
  if not body then return false end
  clip = CreateFrame("Frame", nil, ns.SimStage:OverlayParent() or body)
  clip:SetFrameLevel(ns.SimStage:OverlayLevel(body))
  if clip.SetClipsChildren then clip:SetClipsChildren(true) end
  clip:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  clip:SetPoint("BOTTOMRIGHT", body, "TOPLEFT", W, -H)
  clip:Hide()
  root = CreateFrame("Frame", nil, clip)
  root:SetSize(W, H)
  root:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  root:EnableMouse(true)

  -- the page's banner: the way back, the title and what the list keeps
  root.banner = UI:CreatePageBanner(root, { size = "strip", width = W, title = "Recent runs", titleColor = "GOLD",
    back = { text = "Results", onClick = function() HUI:Close() end } })
  root.banner:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
  root.banner:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, 0)
  root.back = root.banner.back
  root.sub = root.banner.sub

  -- the list and the card: a list + detail page; the card opens with its banner (one run, or the two compared)
  layout = UI:CreateLayout("listdetail", root, { width = W, pad = 0, top = TOP, bottom = 0, toolbar = false,
    listWidth = LIST_W, banner = { size = "strip", title = "Recent runs" } })
  list = layout.list
  card = UI:CreateCard(layout.body, { pad = 0 })
  card:SetAllPoints(layout.body)
  root.layout = layout
  HUI.root = root
  return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- A row of the list
-- ---------------------------------------------------------------------------------------------------------------
local function PaintRow(r)
  local run = r.run
  local at = run and IsPicked(run.id)
  r:SetSelected(at and true or false)
  -- the pick mark: the gold count badge with A / B when picked (A = the later of the two), else an empty box
  local letter
  if at then
    local pr = PickedRuns()
    letter = (#pr == 2 and pr[2].id == run.id) and "B" or "A"
  end
  r.badge:SetLabel(letter)
  r.box:SetShown(not letter)
  r.bin:SetShown(r.hover and true or false)
end

Row = function(i)
  local r = rows[i]
  if r then return r end
  r = CreateFrame("Button", nil, list)
  r:SetSize(LIST_W, ROW_H)
  Put(r, list, 0, (i - 1) * ROW_H)
  r:RegisterForClicks("LeftButtonUp")
  UI:DecorateRow(r, { selectable = true, rule = true })
  -- the pick mark (PaintRow): an empty box on the shared edges, the count badge with the letter once picked
  r.box = CreateFrame("Frame", nil, r)
  r.box:SetSize(16, 16)
  r.box:SetPoint("LEFT", r, "LEFT", 10, 0)
  UI:Fill(r.box, "INSET")
  UI:AddEdges(r.box, "BORDER")
  UI:SetEdgeColor(r.box, S:Color("EDGE"))
  r.badge = UI:CreateCountBadge(r, 16)
  r.badge:SetPoint("CENTER", r.box, "CENTER", 0, 0)
  -- when
  r.time = UI:Text(r, "emph", C.text, T_L)
  r.time:SetPoint("TOPLEFT", r, "TOPLEFT", 36, -6)
  r.day = UI:Text(r, "caps", C.dim, T_L)
  r.day:SetPoint("TOPLEFT", r, "TOPLEFT", 36, -22)
  -- the items it changed
  r.icons = {}
  for k = 1, 2 do
    local t = UI:CreateIconTile(r, 24)
    t:SetPoint("LEFT", r, "LEFT", 92 + (k - 1) * 27, 0)
    r.icons[k] = t
  end
  r.more = UI:Text(r, "caps", C.label, T_C)
  r.more:SetPoint("CENTER", r.icons[2], "CENTER", 0, 0)
  -- what and against what
  r.what = UI:Text(r, "body", C.text, T_L)
  r.what:SetPoint("TOPLEFT", r, "TOPLEFT", 150, -6)
  r.what:SetWidth(222)
  r.vs = UI:Text(r, "caps", C.dim, T_L)
  r.vs:SetPoint("TOPLEFT", r, "TOPLEFT", 150, -22)
  r.vs:SetWidth(222)
  -- numbers
  r.dps = UI:Text(r, "title", C.text, T_RN)
  r.dps:SetPoint("TOPRIGHT", r, "TOPRIGHT", -34, -5)
  r.delta = UI:Text(r, "small", C.grey, T_RN)
  r.delta:SetPoint("TOPRIGHT", r, "TOPRIGHT", -34, -21)
  r.bin = UI:CreateRemoveButton(r, "Remove this run")
  r.bin:SetPoint("RIGHT", r, "RIGHT", -8, 0)
  r.bin:SetScript("OnClick", function()
    if r.run then HUI:Remove(r.run.id) end
  end)
  r.bin:HookScript("OnEnter", function() r.hover = true PaintRow(r) end)
  r.bin:Hide()
  r:SetScript("OnEnter", function(self)
    self.hover = true
    PaintRow(self)
  end)
  r:SetScript("OnLeave", function(self)
    if self.bin:IsMouseOver() then return end
    self.hover = false
    PaintRow(self)
  end)
  -- (a run of another spec says why it can't be picked)
  UI:AttachTooltip(r, function(self, tt)
    if not (self.run and not IsMine(self.run)) then return false end
    K.TipTitle(tt, tostring(self.run.specName or "Another spec"))
    tt:AddLine("A run of another spec: pick that spec in the tabs above to open or compare it.", 1, 1, 1, true)
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
      icon.tex:SetTexture(ItemIcon(c.id or c.was))
      icon.tex:SetDesaturated(not c.id)
      icon:Show()
    elseif k == 2 and #ch > 2 then
      icon.tex:SetColorTexture(S:Color("INSET"))      -- (the "+3" tile)
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
-- The card on the right (under its banner)
-- ---------------------------------------------------------------------------------------------------------------
local function FreshCard()
  if card.inner then card.inner:Hide(); card.inner:SetParent(nil) end
  local f = CreateFrame("Frame", nil, card)
  f:SetAllPoints()
  card.inner = f
  return f
end

-- one of the two bars (the stage's compare bar, UI/SimStage.lua)
local function CmpBar(parent, y, letter, label, value, frac, gold)
  local f = K.CmpBar(parent, gold and C.word or C.label, gold and "gold" or "ref", CARD_W - 24)
  Put(f, parent, 12, y)
  local l = f.l
  local prefix = letter and S:Wrap("GOLD", letter) .. "  " or ""
  if type(label) == "table" then
    l:SetText(prefix .. label[1])
    if UI:TextWidth(l) > CARD_W - 24 - 64 then l:SetText(prefix .. label[2]) end
  else
    l:SetText(prefix .. label)
  end
  f.v:SetText(Fmt(value))
  f:SetFrac(frac)
  return f
end

-- a caps section header across the card (UI:CreateSectionHeader) at y
local function Section(f, y, title)
  local h = UI:CreateSectionHeader(f, title, { style = "caps" })
  h:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -y)
  h:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -y)
  return h
end

-- the big signed difference + percentage, and the verdict under it
local function DeltaBlock(f, y, d, se, base, better, worse)
  local col, kind = Verdict(d, se)
  local a = UI:Text(f, "page", col, T_L)
  a:SetText(Signed(d) .. " DPS")
  local b = UI:Text(f, "title", col, T_L)
  b:SetText(K.PctText(d, base))
  local wa, wb = UI:TextWidth(a), UI:TextWidth(b)
  local x0 = floor((CARD_W - (wa + 6 + wb)) / 2)
  Put(a, f, x0, y)
  b:SetPoint("BOTTOMLEFT", a, "BOTTOMRIGHT", 6, 1)
  local v = UI:Text(f, "small", C.dim, T_C)
  v:SetWidth(CARD_W - 20)
  Put(v, f, 10, y + 26)
  K.VerdictLine(v, kind, se, better, worse)
end

-- gear lines: "[was] > [now] Item name", at most `room` lines (the last says how many more)
local function GearLines(f, y, changes, room)
  local shown = #changes > room and room - 1 or #changes
  for i = 1, shown do
    local c = changes[i]
    local ly = y + (i - 1) * 22
    local was = UI:CreateIconTile(f, 18)
    Put(was, f, 12, ly)
    was.tex:SetTexture(ItemIcon(c.was))
    was.tex:SetDesaturated(true)
    was:SetAlpha(c.was and 0.8 or 0.25)
    local arrow = f:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(8, 8)
    arrow:SetPoint("LEFT", was, "RIGHT", 4, 0)
    UI:SetChevron(arrow, true)
    arrow:SetVertexColor(C.dim[1], C.dim[2], C.dim[3])
    local now = UI:CreateIconTile(f, 18)
    now:SetPoint("LEFT", arrow, "RIGHT", 4, 0)
    now.tex:SetTexture(ItemIcon(c.id))
    now:SetAlpha(c.id and 1 or 0.25)
    local name = UI:Text(f, "small", C.text, T_L)
    name:SetPoint("LEFT", now, "RIGHT", 7, 0)
    name:SetWidth(CARD_W - 86)
    name:SetText(c.id and ItemText(c.id) or S:Wrap("SUB", "No " .. ns.SlotLabel(c.sid):lower()))
  end
  if #changes > shown then
    local more = UI:Text(f, "small", C.dim, T_L)
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

-- the detail banner's actions: Open (one run) or Open A / Open B (the first at the far right; off while a run goes)
local OPEN_TIP = { "Open this run", "Brings it back on the Gear sim page: its Working set, what it was compared with "
  .. "and its settings, with its result. Nothing is simmed." }
local function OpenActions(list)
  local acts = {}
  for _, it in ipairs(list) do
    local run = it[2]
    acts[#acts + 1] = { text = it[1], kind = it[3], tip = OPEN_TIP, enabled = not P()._state().running,
      onClick = function() HUI:OpenRun(run.id) end }
  end
  layout.banner:SetActions(acts)
end

local function OneRun(f, run)
  layout.banner:SetTitle("This run")
  layout.banner:SetSub(P().RunWhen(run.at, true))
  local a, b = run.dps or 0, run.refDps or 0
  local lo, hi = min(a, b) * 0.85, max(a, b) * 1.01
  CmpBar(f, 12, nil, run.targetText or "My gear", b, (b - lo) / max(1, hi - lo), false)
  CmpBar(f, 46, nil, "Working set", a, (a - lo) / max(1, hi - lo), true)
  DeltaBlock(f, 86, run.diff or 0, run.se or 0, b, "A real upgrade", "A downgrade")
  local y = 142
  local ch = P():RunChanges(run)
  Section(f, y, #ch == 0 and "Same gear on both" or "What it tried")
  y = GearLines(f, y + 22, ch, 6)
  y = y + 14
  Section(f, y, "Settings")
  local s = UI:Text(f, "small", C.label, T_L)
  s:SetWidth(CARD_W - 24)
  Put(s, f, 12, y + 22)
  s:SetText(SettingsShort(run.settings) .. "  \194\183  " .. tostring(run.buffsText or ""))
  OpenActions({ { "Open", run, "primary" } })
end

local function TwoRuns(f, A, B)
  layout.banner:SetTitle("Compare")
  layout.banner:SetSub("Working sets")
  local Aw = Hist():Summaries(A)
  local Bw = Hist():Summaries(B)
  local a, b = A.dps or 0, B.dps or 0
  local d, se = a - b, 0
  if Aw and Bw then d, se = Hist().Diff(Aw, Bw, A.seed ~= nil and A.seed == B.seed) end
  local lo, hi = min(a, b) * 0.85, max(a, b) * 1.01
  local function name(run) return { P():RunChangeText(run), "My " .. P().RunWhen(run.at) .. " run" } end
  CmpBar(f, 12, "B", name(B), b, (b - lo) / max(1, hi - lo), false)
  CmpBar(f, 46, "A", name(A), a, (a - lo) / max(1, hi - lo), true)
  DeltaBlock(f, 86, d, se, b, "A is better", "A is worse")
  local y = 142
  -- gear between B and A
  local ch = {}
  for sid = 1, 19 do
    local x, w = A.work and A.work[sid], B.work and B.work[sid]
    if not R():SameEntry(x, w) then ch[#ch + 1] = { sid = sid, id = x and x.id, was = w and w.id } end
  end
  local diffs = SettingDiffs(A, B)
  Section(f, y, #ch == 0 and "Same gear on both" or "From B to A")
  y = GearLines(f, y + 22, ch, #diffs > 0 and 4 or 6)
  if #diffs == 0 then
    y = y + 14
    Section(f, y, "Settings, both")
    local same = UI:Text(f, "small", C.label, T_L)
    same:SetWidth(CARD_W - 24)
    Put(same, f, 12, y + 22)
    same:SetText(SettingsShort(A.settings) .. "  \194\183  " .. tostring(A.buffsText or ""))
  else
    y = y + 8
    local warn = UI:Text(f, "small", C.warn, T_L)
    warn:SetWidth(CARD_W - 24)
    Put(warn, f, 12, y)
    warn:SetText("Not the gear alone: settings differ")
    y = y + 16
    for i = 1, min(#diffs, 3) do
      local l = UI:Text(f, "small", C.label, T_L)
      l:SetWidth(CARD_W - 24)
      Put(l, f, 12, y)
      l:SetText(diffs[i])
      y = y + 15
    end
  end
  OpenActions({ { "Open A", A, "primary" }, { "Open B", B } })
end

-- The detail: one run, two compared, or (none picked) the empty state in its body; no runs: the list's empty state.
local WATCH = "Interface\\Icons\\INV_Misc_PocketWatch_01"
Card = function()
  local f = FreshCard()
  local pr = PickedRuns()
  local runs = #Hist():Runs()
  if runs == 0 then
    layout:ShowEmpty({ region = "list", icon = WATCH, title = "No runs yet",
      text = "Every run of the Gear sim lands here: the last 10 on this character." })
  elseif #pr == 0 then
    layout:ShowEmpty({ region = "body", icon = WATCH, title = "Pick a run",
      text = "Click a run to see it, or two to compare them." })
  else
    layout:HideEmpty()
  end
  if #pr == 2 then
    TwoRuns(f, pr[1], pr[2])
  elseif #pr == 1 then
    OneRun(f, pr[1])
  else
    layout.banner:SetTitle(runs > 0 and "Pick a run" or "Recent runs")
    layout.banner:SetSub(nil)
    layout.banner:SetActions(nil)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Open / close / refresh
-- ---------------------------------------------------------------------------------------------------------------
function HUI:Paint()
  if not root then return end
  TidyPicks()
  local runs = Hist():Runs()
  root.banner:SetBack(P()._state().results and "Results" or "Gear sim", function() HUI:Close() end)
  root.banner:SetSub(("The last %d on this character  \194\183  sets simmed before are not simmed again")
    :format(Hist().MAX_RUNS))
  for i = 1, max(#runs, #rows) do
    local run = runs[i]
    if run then FillRow(Row(i), run) elseif rows[i] then rows[i]:Hide() end
  end
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
