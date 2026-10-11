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
local ROW_H, ROW_GAP = 38, 4
local CARD_W = W - LIST_W - S.GAP
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

-- The page's palette: the stage's (ns.Style tokens for text and verdicts) and its own few tones.
local C = setmetatable({
  label = K.C.sentence, track = { 0.137, 0.137, 0.157 }, warn = { 1, 0.70, 0.35 }, ink = { 0.08, 0.07, 0.05 },
  box = { 0.07, 0.07, 0.08 }, boxEdge = { 0.25, 0.25, 0.27 },
}, { __index = K.C })

local function R() return ns.SimRunner end
local function P() return ns.SimPanel end
local function Hist() return ns.SimHistory end
local function Fmt(v) return ns.SimPanel.Fmt(v) end
local function Signed(v) return ns.SimPanel.Signed(v) end

-- A line of text: a style name or a size of the type scale (UI:Text), left-aligned unless told.
local function Text(parent, size, color, justify, font)
  local fs = K.Text(parent, size, color, justify or "LEFT", font)
  fs:SetShadowColor(0, 0, 0, 0.7)
  return fs
end

local Tex, Put, Cap, Verdict = K.Tex, K.Put, K.Cap, K.Verdict

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
  clip:SetFrameLevel(body:GetFrameLevel() + 30)
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
  -- the pick box: A / B in gold when picked (A = the later of the two)
  local letter
  if at then
    local pr = PickedRuns()
    letter = (#pr == 2 and pr[2].id == run.id) and "B" or "A"
  end
  local box, edge = at and C.gold2 or C.box, at and C.gold2 or C.boxEdge
  r.box:SetColorTexture(box[1], box[2], box[3], 1)
  r.boxEdge:SetColorTexture(edge[1], edge[2], edge[3], 1)
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
  r.bg = UI:Fill(r, "CARD")
  UI:DecorateRow(r, { selectable = true })
  -- pick box
  r.boxEdge = Tex(r, "BORDER", C.boxEdge)
  r.boxEdge:SetSize(16, 16)
  r.boxEdge:SetPoint("LEFT", r, "LEFT", 10, 0)
  r.box = Tex(r, "ARTWORK", C.box)
  r.box:SetPoint("TOPLEFT", r.boxEdge, "TOPLEFT", 1, -1)
  r.box:SetPoint("BOTTOMRIGHT", r.boxEdge, "BOTTOMRIGHT", -1, 1)
  r.letter = Text(r, "small", C.ink, "CENTER")
  r.letter:SetShadowOffset(0, 0)
  r.letter:SetPoint("CENTER", r.boxEdge, "CENTER", 0, 0)
  -- when
  r.time = Text(r, "emph", C.text)
  r.time:SetPoint("TOPLEFT", r, "TOPLEFT", 36, -6)
  r.day = Text(r, "caps", C.dim)
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
  r.more = Text(r, "caps", C.label, "CENTER")
  r.more:SetPoint("CENTER", r.icons[2], "CENTER", 0, 0)
  -- what and against what
  r.what = Text(r, "body", C.text)
  r.what:SetPoint("TOPLEFT", r, "TOPLEFT", 150, -6)
  r.what:SetWidth(222)
  r.vs = Text(r, "caps", C.dim)
  r.vs:SetPoint("TOPLEFT", r, "TOPLEFT", 150, -22)
  r.vs:SetWidth(222)
  -- numbers
  r.dps = Text(r, "title", C.text, "RIGHT", NUM)
  r.dps:SetPoint("TOPRIGHT", r, "TOPRIGHT", -34, -5)
  r.delta = Text(r, "small", C.grey, "RIGHT", NUM)
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
      icon:SetTexture(ItemIcon(c.id or c.was))
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
-- The card on the right (under its banner)
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
  local l = Text(f, "small", gold and C.word or C.label)
  l:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  local prefix = letter and S:Wrap("GOLD", letter) .. "  " or ""
  if type(label) == "table" then
    l:SetText(prefix .. label[1])
    if UI:TextWidth(l) > CARD_W - 24 - 64 then l:SetText(prefix .. label[2]) end
  else
    l:SetText(prefix .. label)
  end
  local v = Text(f, "body", C.text, "RIGHT", NUM)
  v:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 1)
  v:SetText(Fmt(value))
  local track = Tex(f, "ARTWORK", C.track)
  track:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -16)
  track:SetSize(CARD_W - 24, 6)
  local fill = f:CreateTexture(nil, "ARTWORK", nil, 1)
  fill:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
  fill:SetSize(max(1, (CARD_W - 24) * max(0, min(1, frac))), 6)
  K.BarFill(fill, gold)
  return f
end

-- the big signed difference + percentage, and the verdict under it
local function DeltaBlock(f, y, d, se, base, better, worse)
  local col, kind = Verdict(d, se)
  local a = Text(f, "page", col)
  a:SetText(Signed(d) .. " DPS")
  local b = Text(f, "title", col)
  b:SetText(K.PctText(d, base))
  local wa, wb = UI:TextWidth(a), UI:TextWidth(b)
  local x0 = floor((CARD_W - (wa + 6 + wb)) / 2)
  Put(a, f, x0, y)
  b:SetPoint("BOTTOMLEFT", a, "BOTTOMRIGHT", 6, 1)
  local v = Text(f, "small", C.dim, "CENTER")
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
    local was = f:CreateTexture(nil, "ARTWORK")
    was:SetSize(18, 18)
    Put(was, f, 12, ly)
    was:SetTexture(ItemIcon(c.was))
    was:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    was:SetDesaturated(true)
    was:SetAlpha(c.was and 0.8 or 0.25)
    local arrow = f:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(8, 8)
    arrow:SetPoint("LEFT", was, "RIGHT", 4, 0)
    UI:SetChevron(arrow, true)
    arrow:SetVertexColor(C.dim[1], C.dim[2], C.dim[3])
    local now = f:CreateTexture(nil, "ARTWORK")
    now:SetSize(18, 18)
    now:SetPoint("LEFT", arrow, "RIGHT", 4, 0)
    now:SetTexture(ItemIcon(c.id))
    now:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    now:SetAlpha(c.id and 1 or 0.25)
    local name = Text(f, "small", C.text)
    name:SetPoint("LEFT", now, "RIGHT", 7, 0)
    name:SetWidth(CARD_W - 86)
    name:SetText(c.id and ItemText(c.id) or S:Wrap("SUB", "No " .. ns.SlotLabel(c.sid):lower()))
  end
  if #changes > shown then
    local more = Text(f, "small", C.dim)
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

-- an Open button along the card's foot (disabled while a run goes)
local function OpenButton(f, label, run, x, w, kind)
  local b = UI:CreateSleekButton(f, label, w, S.BTN_H, function()
    HUI:OpenRun(run.id)
  end, kind or "secondary")
  b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, 12)
  UI:AttachTooltip(b, "Open this run", { "Brings it back on the Gear sim page: its Working set, what it was compared "
    .. "with and its settings, with its result. Nothing is simmed." }, { anchor = "ANCHOR_TOP" })
  if P()._state().running then b:Disable() end
  return b
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
  Put(Cap(f, #ch == 0 and "Same gear on both" or "What it tried"), f, 12, y)
  y = GearLines(f, y + 18, ch, 6)
  y = y + 14
  Put(Cap(f, "Settings"), f, 12, y)
  local s = Text(f, "small", C.label)
  s:SetWidth(CARD_W - 24)
  Put(s, f, 12, y + 18)
  s:SetText(SettingsShort(run.settings) .. "  \194\183  " .. tostring(run.buffsText or ""))
  OpenButton(f, "Open", run, 12, CARD_W - 24, "primary")
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
  Put(Cap(f, #ch == 0 and "Same gear on both" or "From B to A"), f, 12, y)
  y = GearLines(f, y + 18, ch, #diffs > 0 and 4 or 6)
  if #diffs == 0 then
    y = y + 14
    Put(Cap(f, "Settings, both"), f, 12, y)
    local same = Text(f, "small", C.label)
    same:SetWidth(CARD_W - 24)
    Put(same, f, 12, y + 18)
    same:SetText(SettingsShort(A.settings) .. "  \194\183  " .. tostring(A.buffsText or ""))
  else
    y = y + 8
    local warn = Text(f, "small", C.warn)
    warn:SetWidth(CARD_W - 24)
    Put(warn, f, 12, y)
    warn:SetText("Not the gear alone: settings differ")
    y = y + 16
    for i = 1, min(#diffs, 3) do
      local l = Text(f, "small", C.label)
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
    local any = #Hist():Runs() > 0
    layout.banner:SetTitle(any and "Pick a run" or "Recent runs")
    layout.banner:SetSub(nil)
    local t = Text(f, "body", C.dim, "CENTER")
    t:SetWidth(CARD_W - 40)
    t:SetWordWrap(true)
    t:SetPoint("TOP", f, "TOP", 0, -126)
    t:SetText(any and "Click a run to see it, or two to compare them." or "")
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
  if #runs == 0 then
    layout:ShowEmpty({ region = "list", icon = "Interface\\Icons\\INV_Misc_PocketWatch_01", title = "No runs yet",
      text = "Every run of the Gear sim lands here: the last 10 on this character." })
  else
    layout:HideEmpty()
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
