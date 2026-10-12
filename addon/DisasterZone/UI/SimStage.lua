if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SimStage.lua", ...) then return end -- DisasterZone: UI/SimStage.lua
-- ns.SimStage: the Gear sim page's look (mockup B "Sigil", dev/art/casc/simflow_mockup). ns.SimPanel owns the state
-- (the Working set, settings, runs); this file draws it.
--   Before a run: only the sigil (a dial of 72 ticks round the spec icon, "Run simulation") over the raid's art, and
--     the settings as one sentence whose underlined words are menus. The gear stays hidden.
--   Running: the ticks light up one by one (a bright head, a fading tail), the average so far and its ± settle inside,
--     a running-average line grows under the dial. A run that ends at once (the result cache) still sweeps for a
--     moment, so the dial never just blinks.
--   Result: every tick flashes, the dial rises to the top of the centre column holding the number, the gear slides in
--     from both sides, then two bars (the target, the Working set), the difference, a verdict in words, Nerd stats
--     (UI/SimNerd.lua) and a chip with the settings. The dial stays the button: a click runs again.
--   Changed: a slot changed since the run: the numbers fade back, the ticks grey, "Run again" in the dial.
-- Every move eases (the mock's cubic-bezier(.22,.8,.24,1)); one OnUpdate on the stage drives them while it shows.
-- Shared parts: UI:Text on the type scale, ns.Style tokens, UI:CreateChip (settings), UI:CreateBackLink (Recent
-- runs), UI:CreateNotice (a spec the sim doesn't cover), UI:CreateSleekButton (Nerd stats). The stage fills the body
-- of My BiS's Gear sim view (its toolbar is My BiS's). What stays drawn here is the page's own art, not page
-- structure: the dial (ticks, disc, glow), the settings sentence's underlined words, the running-average line and the
-- two compare bars (Kit.CmpBar, shared with Recent runs).
local addonName, ns = ...

local Stage = {}
ns.SimStage = Stage

local UI, S = ns.UI, ns.Style
local floor, max, min, abs, sqrt, sin, cos, pi = math.floor, math.max, math.min, math.abs, math.sqrt, math.sin, math.cos, math.pi

local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
local DISC, DASH = MEDIA .. "Sim\\disc", MEDIA .. "Sim\\dashring"
local GLASSES = MEDIA .. "Sim\\glasses"
local ICONRING = MEDIA .. "Sim\\iconring"
local SOFT, RADIAL = MEDIA .. "SoftGlow", MEDIA .. "MyBiS\\Radial"
local ART = "Interface\\Glues\\LoadingScreens\\LoadScreenTempestKeep"
local CHECK_OK, CHECK_NO = "Interface\\RaidFrame\\ReadyCheck-Ready", "Interface\\RaidFrame\\ReadyCheck-NotReady"
local NUMFONT = S.FONT_NUM

-- the page's grid (the mock's body: 770 wide, the doll's centre column x 270..500)
local W, H = 770, 496
local CX = 385
local IDLE_Y, DONE_Y, DONE_SCALE = 186, 98, 0.78
local SIG = 220                       -- the sigil's box
local TICKS = 72
local MIN_SWEEP = 1.2                 -- seconds the ticks take at the least for a whole run

-- The sim pages' colours (the stage, Nerd stats, Recent runs: Stage.Kit.C): ns.Style tokens for text, accents and
-- the verdicts; the sigil's own art tones (mockup B: the ticks, the head, the sentence's words) stay its own.
local C = {
  gold = S.C.GOLD, gold2 = S.C.GOLD_DEEP, head = { 1, 0.945, 0.659 },
  tick = { 0.227, 0.227, 0.259 }, tickGrey = { 0.42, 0.42, 0.45 },
  text = S.C.TEXT, dim = S.C.SUB, cap = { 0.749, 0.714, 0.604 },
  word = { 0.941, 0.902, 0.784 }, under = { 0.541, 0.451, 0.188 }, sentence = { 0.663, 0.663, 0.69 },
  green = S.C.OK, red = S.C.BAD, grey = S.C.SUB, warn = S.C.WARN,
  okText = S.C.OK, noText = S.C.BAD, stale = S.C.GOLD,
  barRef = { 0.478, 0.478, 0.51 }, track = { 0.133, 0.133, 0.153 },
  barLo = { 0.604, 0.455, 0.125, 1 }, barHi = { 1, 0.843, 0.353, 1 },   -- the gold bars' gradient
}

local function R() return ns.SimRunner end
local function P() return ns.SimPanel end
local function Fmt(v) return ns.SimPanel.Fmt(v) end

-- "1,000 FIGHTS" -> "1 , 0 0 0   F I G H T S": the mock's letter-spaced captions (a Friz space is about the
-- mock's 2.4 px spacing at this size)
local function Spaced(s)
  local out = {}
  for word in tostring(s):upper():gmatch("%S+") do
    out[#out + 1] = word:gsub("(.)", "%1 "):sub(1, -2)
  end
  return table.concat(out, "   ")
end
Stage.Spaced = Spaced

-- UI:Text's options for the stage's lines (S.STYLE names; display numerals past S.FONT_DISPLAY keep their size):
-- centred, left, right-aligned numerals; all with the shared drop shadow.
local T_C = { justify = "CENTER", shadow = true }
local T_L = { justify = "LEFT", shadow = true }
local T_RN = { justify = "RIGHT", font = NUMFONT, shadow = true }

-- A tooltip's gold title line.
local function TipTitle(tt, text) tt:AddLine(text, C.gold[1], C.gold[2], C.gold[3]) end

local function Color(t, c, a)
  if t.SetVertexColor then t:SetVertexColor(c[1], c[2], c[3], a or 1) end
end

-- A gold bar's fill (gold = the gradient) or a flat one in c.
local function BarFill(tex, gold, c)
  if gold then
    UI:Gradient(tex, "HORIZONTAL", C.barLo, C.barHi)
  else
    tex:SetColorTexture(S:Color(c or C.barRef))
  end
end

-- The verdict of a difference d with standard error se (green / red / grey): its colour and "none" | "close" | "up"
-- | "down" (the stage's result, Recent runs' rows and cards).
local function Verdict(d, se)
  if abs(d) < 0.5 then return C.grey, "none" end
  if abs(d) < 2 * (se or 0) then return C.grey, "close" end
  return d > 0 and C.green or C.red, d > 0 and "up" or "down"
end

-- "+0.9%" / "-2.1%" (a real minus) / "0.0%": d against base.
local function PctText(d, base)
  local pct = d / max(1, base) * 100
  if abs(pct) < 0.05 then return "0.0%" end
  return (pct >= 0 and "+" or "\226\136\146") .. ("%.1f%%"):format(abs(pct))
end

-- The verdict's words under a difference (kind from Verdict): "No difference", "Too close to call  ·  ±31", or a
-- check / cross with `better` / `worse`, in the verdict's colour (grey for the first two); the ± in grey.
local function VerdictLine(fs, kind, se, better, worse)
  local sure = S:Wrap("SUB", "\194\183  \194\177" .. Fmt(2 * (se or 0)))
  local c = C.dim
  if kind == "none" then
    fs:SetText("No difference")
  elseif kind == "close" then
    fs:SetText("Too close to call  " .. sure)
  elseif kind == "up" then
    fs:SetText(("|T%s:12:12:0:0|t %s  %s"):format(CHECK_OK, better, sure))
    c = C.okText
  else
    fs:SetText(("|T%s:12:12:0:0|t %s  %s"):format(CHECK_NO, worse, sure))
    c = C.noText
  end
  fs:SetTextColor(c[1], c[2], c[3])
end

-- The pieces Nerd stats and Recent runs (UI/SimNerd.lua, UI/SimHistory.lua) draw with, as the stage does.
local Kit = { C = C, TipTitle = TipTitle, BarFill = BarFill, Verdict = Verdict, PctText = PctText,
  VerdictLine = VerdictLine, NUM = NUMFONT }
Stage.Kit = Kit

-- A plain texture in colour c (alpha a).
function Kit.Tex(parent, layer, c, a)
  local t = parent:CreateTexture(nil, layer or "ARTWORK")
  local r, g, b = S:Color(c)
  t:SetColorTexture(r, g, b, a or 1)
  return t
end

-- region placed at x, y (down) from parent's top left.
function Kit.Put(region, parent, x, y, point)
  region:ClearAllPoints()
  region:SetPoint(point or "TOPLEFT", parent, "TOPLEFT", x, -y)
  return region
end

-- ---------------------------------------------------------------------------------------------------------------
-- Tweens: tween(key, seconds, fn(e), delay, done) calls fn with an eased 0..1 every frame; a new tween on a key
-- replaces the old one (it jumps to its end first). Finish() puts every running one at its end.
-- ---------------------------------------------------------------------------------------------------------------
local tweens = {}

local function EaseOut(t) return 1 - (1 - t) ^ 3.4 end   -- close to the mock's cubic-bezier(.22,.8,.24,1)

local function Tween(key, dur, fn, delay, done)
  local old = tweens[key]
  if old then
    tweens[key] = nil
    old.fn(1)
    if old.done then old.done() end
  end
  local tw = { t = -(delay or 0), dur = max(0.001, dur), fn = fn, done = done }
  tweens[key] = tw
  fn(0)
end

local function StepTweens(dt)
  local snap = {}
  for key, tw in pairs(tweens) do snap[key] = tw end
  for key, tw in pairs(snap) do
    if tweens[key] ~= tw then
      -- (finished or replaced by an earlier one's callback this frame)
    else
    tw.t = tw.t + dt
    if tw.t >= 0 then
      local p = min(1, tw.t / tw.dur)
      tw.fn(EaseOut(p))
      if p >= 1 then
        if tweens[key] == tw then tweens[key] = nil end
        if tw.done then tw.done() end
      end
    end
    end
  end
end

local function FinishTweens()
  for _ = 1, 4 do
    if not next(tweens) then return end
    local list = tweens
    tweens = {}
    for _, tw in pairs(list) do
      tw.fn(1)
      if tw.done then tw.done() end
    end
  end
end
Stage.FinishTweens = FinishTweens

-- ---------------------------------------------------------------------------------------------------------------
-- The sigil
-- ---------------------------------------------------------------------------------------------------------------
local stage, sigil, doll

local function TickPoints(i, long)
  local a = (i * 5 - 90) * pi / 180
  local r0, r1 = 91, long and 103 or 100
  return cos(a) * r0, -sin(a) * r0, cos(a) * r1, -sin(a) * r1
end

local function MakeLine(parent, layer, x0, y0, x1, y1, thick)
  local l = parent:CreateLine(nil, layer or "ARTWORK")
  l:SetStartPoint("CENTER", parent, x0, y0)
  l:SetEndPoint("CENTER", parent, x1, y1)
  l:SetThickness(thick or 1.6)
  l:SetColorTexture(1, 1, 1, 1)
  return l
end

local function CreateSigil(parent)
  local s = CreateFrame("Button", nil, parent)
  s:SetSize(SIG, SIG)
  s:RegisterForClicks("LeftButtonUp")
  s:SetFrameLevel(parent:GetFrameLevel() + 5)

  s.glow = s:CreateTexture(nil, "BACKGROUND", nil, 1)
  s.glow:SetTexture(SOFT)
  s.glow:SetSize(280, 280)
  s.glow:SetPoint("CENTER")
  s.glow:SetBlendMode("ADD")
  Color(s.glow, C.gold, 0.16)

  s.dash = s:CreateTexture(nil, "BORDER")
  s.dash:SetTexture(DASH)
  s.dash:SetSize(222, 222)
  s.dash:SetPoint("CENTER")
  s.dash:SetVertexColor(0.231, 0.204, 0.141, 1)
  s.dashAngle = 0

  s.ticks, s.glows = {}, {}
  for i = 0, TICKS - 1 do
    local long = i % 6 == 0
    local x0, y0, x1, y1 = TickPoints(i, long)
    local l = MakeLine(s, "ARTWORK", x0, y0, x1, y1, long and 2 or 1.6)
    Color(l, C.tick)
    l.long = long
    s.ticks[i + 1] = l
  end
  -- the head's glow: the last few lit ticks again, thicker and additive
  for j = 1, 8 do
    local l = MakeLine(s, "ARTWORK", 0, 0, 0, 1, 4.5)
    l:SetBlendMode("ADD")
    l:SetAlpha(0)
    s.glows[j] = l
  end

  s.disc = s:CreateTexture(nil, "ARTWORK", nil, 2)
  s.disc:SetTexture(DISC)
  s.disc:SetSize(168, 168)
  s.disc:SetPoint("CENTER")

  s.hover = s:CreateTexture(nil, "ARTWORK", nil, 3)
  s.hover:SetTexture(SOFT)
  s.hover:SetSize(170, 170)
  s.hover:SetPoint("CENTER")
  s.hover:SetBlendMode("ADD")
  Color(s.hover, C.gold, 0)

  s.flash = s:CreateTexture(nil, "OVERLAY", nil, 6)
  s.flash:SetTexture(SOFT)
  s.flash:SetSize(300, 300)
  s.flash:SetPoint("CENTER")
  s.flash:SetBlendMode("ADD")
  Color(s.flash, C.gold, 0)

  -- before a run: the spec icon and the words
  s.specRing = s:CreateTexture(nil, "OVERLAY", nil, 1)
  s.specRing:SetTexture(ICONRING)
  s.specRing:SetSize(52, 52)
  s.specRing:SetPoint("CENTER", s, "TOPLEFT", 110, -76)
  s.specGlow = s:CreateTexture(nil, "OVERLAY", nil, 0)
  s.specGlow:SetTexture(SOFT)
  s.specGlow:SetSize(84, 84)
  s.specGlow:SetPoint("CENTER", s.specRing)
  s.specGlow:SetBlendMode("ADD")
  Color(s.specGlow, C.gold, 0.14)
  s.spec = s:CreateTexture(nil, "OVERLAY", nil, 2)
  s.spec:SetSize(48, 48)
  s.spec:SetPoint("CENTER", s.specRing)

  s.runText = UI:Text(s, "title", C.gold, T_C)
  s.runText:SetPoint("TOP", s, "TOP", 0, -112)
  s.runText:SetShadowColor(0, 0, 0, 1)
  s.runSub = UI:Text(s, "caps", C.cap, T_C)
  s.runSub:SetPoint("TOP", s.runText, "BOTTOM", 0, -4)

  -- running and after: the caption, the number, the line under it
  s.k = UI:Text(s, "caps", C.cap, T_C)
  s.k:SetPoint("TOP", s, "TOP", 0, -76)
  s.n = UI:Text(s, 34, C.text, T_C)
  s.n:SetPoint("TOP", s.k, "BOTTOM", 0, -2)
  s.n:SetShadowOffset(0, -2)
  s.n:SetShadowColor(0, 0, 0, 0.6)
  s.pm = UI:Text(s, "small", C.dim, T_C)
  s.pm:SetPoint("TOP", s.n, "BOTTOM", 0, -1)
  s.again = UI:Text(s, "body", C.gold, T_C)
  s.again:SetPoint("TOP", s, "TOP", 0, -146)
  s.again:SetText("|TInterface\\Buttons\\UI-RefreshButton:12:12:0:0|t Run again")

  s:SetScript("OnEnter", function() Stage:SetHover(true) end)
  s:SetScript("OnLeave", function() Stage:SetHover(false) end)
  UI:AttachTooltip(s, function(_, tt)
    local mode = Stage.mode
    if mode == "run" then
      TipTitle(tt, "Simulating")
      tt:AddLine("Click to stop. It pauses while you are in combat.", 1, 1, 1, true)
    elseif mode == "done" or mode == "stale" then
      TipTitle(tt, "Run again")
      tt:AddLine("Sims the Working set and what it is compared with once more.", 1, 1, 1, true)
    else
      return false
    end
  end)
  s:SetScript("OnClick", function()
    if Stage.mode == "unsupported" then return end
    P():Run()
  end)
  return s
end

-- Lights the ticks up to `lit` (0..72); grey = the ticks of a run that is out of date.
local function PaintTicks(lit, grey, flashing)
  local s = sigil
  local head = lit
  for i, l in ipairs(s.ticks) do
    local idx = i - 1
    if idx < lit then
      local near = head - idx
      if grey then
        Color(l, C.tickGrey)
      elseif near < 6 and lit < TICKS then
        Color(l, C.head)
      else
        Color(l, C.gold2, 0.92)
      end
    else
      Color(l, C.tick)
    end
  end
  for j, g in ipairs(s.glows) do
    local idx = floor(head) - j
    if not grey and lit < TICKS and idx >= 0 and lit > 0 then
      local x0, y0, x1, y1 = TickPoints(idx, idx % 6 == 0)
      g:SetStartPoint("CENTER", s, x0, y0)
      g:SetEndPoint("CENTER", s, x1, y1)
      g:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], (1 - (head - idx) / 8) * 0.9)
      g:SetAlpha(1)
    else
      g:SetAlpha(0)
    end
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The settings sentence: "Sim my [Working set] (1 change) against [My gear], [1,000 fights] of [3:00] on a
-- [level 73 Mechanical] with [25-man buffs]." Every [word] opens its menu (ns.SimPanel:BuildSettingMenu).
-- ---------------------------------------------------------------------------------------------------------------
local SENT_SIZE, LINE_H = "title", 28    -- (the sentence: 13 px on the type scale)

local function CreateSentence(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(690, 2 * LINE_H)
  f.pieces, f.words, f.dashes = {}, {}, {}
  return f
end

local function DashPool(f, i)
  local d = f.dashes[i]
  if not d then
    d = f:CreateTexture(nil, "ARTWORK")
    d:SetColorTexture(1, 1, 1, 1)
    d:SetSize(3, 1)
    f.dashes[i] = d
  end
  return d
end

local function WordButton(f, i)
  local b = f.words[i]
  if b then return b end
  b = CreateFrame("Button", nil, f)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.fs = UI:Text(b, SENT_SIZE, C.word, T_L)
  b.fs:SetPoint("LEFT", b, "LEFT", 0, 0)
  b.dashes = {}
  b:SetScript("OnEnter", function(self)
    self.fs:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    for _, d in ipairs(self.dashes) do Color(d, C.gold) end
  end)
  b:SetScript("OnLeave", function(self)
    self.fs:SetTextColor(C.word[1], C.word[2], C.word[3])
    for _, d in ipairs(self.dashes) do Color(d, C.under) end
  end)
  UI:AttachTooltip(b, function(self, tt)
    if not self.tip then return false end
    self.tip(tt)
  end, nil, { anchor = "ANCHOR_TOP" })
  b:SetScript("OnClick", function(self)
    GameTooltip:Hide()
    if self.key then UI:ContextMenu(self, function(root) P():BuildSettingMenu(root, self.key) end) end
  end)
  f.words[i] = b
  return b
end

local function PieceText(f, i)
  local fs = f.pieces[i]
  if not fs then
    fs = UI:Text(f, SENT_SIZE, C.sentence, T_L)
    f.pieces[i] = fs
  end
  return fs
end

-- lines: { { { text, key = setting key | nil, small = true | nil, tight = no space before }, ... }, ... }
local SPACE = 4
local function LayoutSentence(f, lines)
  local np, nw, nd = 0, 0, 0
  for li, line in ipairs(lines) do
    -- measure, then centre the line
    local items, total = {}, 0
    for _, part in ipairs(line) do
      local fs
      if part.key then
        nw = nw + 1
        local b = WordButton(f, nw)
        b.key, b.tip = part.key, part.tip
        b.fs:SetText(part[1])
        fs = b.fs
        items[#items + 1] = { b = b, fs = fs }
      else
        np = np + 1
        fs = PieceText(f, np)
        UI:SetTextStyle(fs, part.small and "small" or SENT_SIZE, part.small and C.dim or C.sentence)
        fs:SetText(part[1])
        items[#items + 1] = { fs = fs, small = part.small }
      end
      local w = tonumber(fs:GetStringWidth()) or 0
      if w <= 0 then w = #part[1] * 7 end
      items[#items].w = w
      items[#items].gap = (#items > 1 and not part.tight) and SPACE or 0
      total = total + w + items[#items].gap
    end
    local x = floor((f:GetWidth() - total) / 2 + 0.5)
    local y = -(li - 1) * LINE_H
    for _, it in ipairs(items) do
      x = x + it.gap
      if it.b then
        local b = it.b
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        b:SetSize(max(1, it.w), 20)
        b:Show()
        -- the dashed underline
        for _, d in ipairs(b.dashes) do d:Hide() end
        b.dashes = {}
        local dx = 0
        while dx < it.w - 1 do
          nd = nd + 1
          local d = DashPool(f, nd)
          d:ClearAllPoints()
          d:SetPoint("TOPLEFT", b, "BOTTOMLEFT", dx, 1)
          d:SetWidth(min(3, it.w - dx))
          Color(d, C.under)
          d:Show()
          b.dashes[#b.dashes + 1] = d
          dx = dx + 5
        end
      else
        it.fs:ClearAllPoints()
        it.fs:SetPoint("LEFT", f, "TOPLEFT", x, y - 10 - (it.small and 1 or 0))
        it.fs:Show()
      end
      x = x + it.w
    end
  end
  for i = np + 1, #f.pieces do f.pieces[i]:Hide() end
  for i = nw + 1, #f.words do f.words[i]:Hide() end
  for i = nd + 1, #f.dashes do f.dashes[i]:Hide() end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The running-average line under the dial (and its ± band as thin columns)
-- ---------------------------------------------------------------------------------------------------------------
local SPARK_W, SPARK_H, SPARK_PTS = 300, 54, 100

local function CreateSpark(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(SPARK_W, 70)
  f.base = f:CreateLine(nil, "BORDER")
  f.base:SetThickness(1)
  f.base:SetColorTexture(C.tick[1], C.tick[2], C.tick[3], 1)
  f.lines, f.band = {}, {}
  for i = 1, SPARK_PTS do
    local l = f:CreateLine(nil, "ARTWORK")
    l:SetThickness(1.6)
    l:SetColorTexture(C.barHi[1], C.barHi[2], C.barHi[3], 1)
    l:Hide()
    f.lines[i] = l
    local b = f:CreateTexture(nil, "BACKGROUND")
    b:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.1)
    b:Hide()
    f.band[i] = b
  end
  f.cap = UI:Text(f, "caps", C.dim, T_L)
  f.cap:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  f.cap:SetText(Spaced("Running average"))
  f.count = UI:Text(f, "small", C.dim, T_RN)
  f.count:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  return f
end

-- list: the fights' DPS so far (k of them shown), total: the run's fights.
local function PaintSpark(f, list, k, total)
  if not f.lo and k >= 8 then
    local s, q = 0, 0
    for i = 1, k do s = s + list[i]; q = q + list[i] ^ 2 end
    local m = s / k
    local sd = sqrt(max(0, q / k - m * m))
    local half = max(m * 0.02, 2.4 * sd / sqrt(8))
    f.lo, f.hi = m - half, m + half
  end
  local lo, hi = f.lo, f.hi
  f.count:SetText(("%s fights"):format(Fmt(k)))
  if not lo or k < 2 then
    for i = 1, SPARK_PTS do f.lines[i]:Hide(); f.band[i]:Hide() end
    f.base:Hide()
    return
  end
  local function Y(v) return -(SPARK_H - (min(hi, max(lo, v)) - lo) / (hi - lo) * SPARK_H) end
  local step = max(1, total / SPARK_PTS)
  local s, q, n, j = 0, 0, 0, 0
  local px, py
  local mean
  for idx = 1, k do
    s, q, n = s + list[idx], q + list[idx] ^ 2, n + 1
    mean = s / n
    if idx == k or idx >= (j + 1) * step then
      j = j + 1
      if j > SPARK_PTS then break end
      local x = idx / total * SPARK_W
      local y = Y(mean)
      local sd = sqrt(max(0, q / n - mean * mean))
      local ci = 2 * sd / sqrt(n)
      local b = f.band[j]
      local top, bot = Y(mean + ci), Y(mean - ci)
      local x0 = px or 0
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", f, "TOPLEFT", x0, top)
      b:SetSize(max(0.5, x - x0 + 0.3), max(1, top - bot))
      b:Show()
      local l = f.lines[j]
      if px then
        l:SetStartPoint("TOPLEFT", f, px, py)
        l:SetEndPoint("TOPLEFT", f, x, y)
        l:Show()
      else
        l:Hide()
      end
      px, py = x, y
    end
  end
  for i = j + 1, SPARK_PTS do f.lines[i]:Hide(); f.band[i]:Hide() end
  f.base:SetStartPoint("TOPLEFT", f, 0, Y(mean))
  f.base:SetEndPoint("TOPLEFT", f, SPARK_W, Y(mean))
  f.base:Show()
end

-- ---------------------------------------------------------------------------------------------------------------
-- The result column
-- ---------------------------------------------------------------------------------------------------------------
local function Reveal(f, y, x)
  f.revealY, f.revealX = y, x
  return f
end

-- A comparison bar (the stage's two, Recent runs' card): the label on the left, the DPS on the right, a 6 px track
-- with the fill under them (gold: the gradient). f:SetFrac(frac [, e]) sizes the fill (e: an eased share of it).
local function CreateCmpBar(parent, labelColor, fill, w)
  w = w or 206
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(w, 30)
  f.w = w
  f.l = UI:Text(f, "small", labelColor, T_L)
  f.l:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  f.v = UI:Text(f, "body", C.text, T_RN)
  f.v:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 1)
  f.t = f:CreateTexture(nil, "ARTWORK")
  f.t:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -16)
  f.t:SetSize(w, 6)
  f.t:SetColorTexture(C.track[1], C.track[2], C.track[3], 1)
  f.f = f:CreateTexture(nil, "ARTWORK", nil, 1)
  f.f:SetPoint("TOPLEFT", f.t, "TOPLEFT", 0, 0)
  f.f:SetSize(1, 6)
  BarFill(f.f, fill == "gold")
  f.frac = 0
  function f:SetFrac(frac, e)
    if frac then self.frac = frac end
    self.f:SetWidth(max(1, self.w * max(0, min(1, self.frac)) * (e or 1)))
  end
  return f
end
Kit.CmpBar = CreateCmpBar

-- The settings chip under the result (UI:CreateChip): the cog (an atlas glyph, tinted) and the settings in a few
-- words; a click drops the settings menu.
local function CreateChip(parent)
  local b = UI:CreateChip(parent, { onClick = function(self)
    GameTooltip:Hide()
    UI:ContextMenu(self, function(root) P():BuildSettingsMenu(root) end)
  end })
  b:SetIcon(UI.ICON_ATLAS, UI:IconCoords(UI.ICON.gear), { C.sentence[1], C.sentence[2], C.sentence[3], 1 })
  function b:SetLabel(text, short)
    self:Set(text)
    if short and self:GetWidth() > 242 then self:Set(short) end
    self.revealX = CX - floor(self:GetWidth() / 2 + 0.5)
  end
  UI:AttachTooltip(b, "Settings", { "Fights, fight length, boss, buffs and what the Working set is compared with." },
    { anchor = "ANCHOR_BOTTOM" })
  return b
end

local function CreateNerdButton(parent)
  local b = UI:CreateSleekButton(parent, "Nerd stats", 210, S.BTN_H, function()
    if ns.SimNerd then ns.SimNerd:Open() end
  end, "secondary")
  local fs = b:GetFontString()
  if fs then
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", b, "CENTER", 14, 0)
  end
  b.glasses = b:CreateTexture(nil, "OVERLAY")
  b.glasses:SetTexture(GLASSES)
  b.glasses:SetSize(22, 11)
  b.glasses:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 1)
  if fs then b.glasses:SetPoint("RIGHT", fs, "LEFT", -7, 0) else b.glasses:SetPoint("CENTER", b, "CENTER", -34, 0) end
  UI:AttachTooltip(b, "Nerd stats", { "Everything about this run: DPS per fight, every ability, swing outcomes, procs and "
    .. "buffs, mana, stats and the run itself." }, { anchor = "ANCHOR_BOTTOM" })
  return b
end

-- "RECENT RUNS  4 >" under the sentence (before a run) or the chip (after one): opens UI/SimHistory.lua. The shared
-- back link (UI:CreateBackLink: grey caps, gold under the mouse) with its chevron after the words, pointing on.
local function CreateRecentLink(parent)
  local b = UI:CreateBackLink(parent, "Recent runs", function() if ns.SimHistoryUI then ns.SimHistoryUI:Open() end end,
    { forward = true })
  function b:SetCount(n) self:SetText(("Recent runs   %d"):format(n)) end
  UI:AttachTooltip(b, "Recent runs", { "Your last runs on this character: open one again (nothing is simmed) or compare "
    .. "two." }, { anchor = "ANCHOR_BOTTOM" })
  b:Hide()
  return b
end

-- ---------------------------------------------------------------------------------------------------------------
-- Building the stage
-- ---------------------------------------------------------------------------------------------------------------
local function At(f, x, y, point)
  f:ClearAllPoints()
  f:SetPoint(point or "TOPLEFT", stage, "TOPLEFT", x, -y)
end

local function PlaceSigil(cy, scale)
  sigil:SetScale(scale)
  sigil:ClearAllPoints()
  sigil:SetPoint("CENTER", stage, "TOPLEFT", CX / scale, -cy / scale)
end

-- body: the page's body (770 x 496); dollFrame: the paper doll that shows the Working set.
function Stage:Create(body, dollFrame)
  if stage then return stage end
  doll = dollFrame
  stage = CreateFrame("Frame", nil, body)
  stage:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  stage:SetSize(W, H)
  stage:SetFrameLevel((dollFrame and dollFrame:GetFrameLevel() or body:GetFrameLevel()) + 2)
  stage:Hide()

  -- the raid's art behind the dial, fading out in a soft ellipse
  stage.artFrame = CreateFrame("Frame", nil, stage)
  stage.artFrame:SetPoint("TOPLEFT", stage, "TOPLEFT", -25, 8)
  stage.artFrame:SetSize(820, 531)
  stage.artFrame:SetFrameLevel(stage:GetFrameLevel())
  stage.art = stage.artFrame:CreateTexture(nil, "BACKGROUND", nil, -6)
  stage.art:SetAllPoints()
  stage.art:SetTexture(ART)
  stage.art:SetTexCoord(0.0764, 0.9236, 0.28, 0.8285)
  stage.art:SetVertexColor(0.42, 0.42, 0.44)
  if stage.artFrame.CreateMaskTexture then
    local m = stage.artFrame:CreateMaskTexture()
    m:SetTexture(RADIAL, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    m:SetPoint("CENTER", stage.artFrame, "TOPLEFT", 410, -223)
    m:SetSize(852, 616)
    if stage.art.AddMaskTexture then stage.art:AddMaskTexture(m) end
    stage.artMask = m
  end
  stage.artFrame:SetAlpha(0)

  sigil = CreateSigil(stage)
  PlaceSigil(IDLE_Y, 1)

  stage.sentence = CreateSentence(stage)
  At(stage.sentence, 40, 322)
  -- (a spec the sim doesn't cover: says so in the shared info notice; stage.note is its text)
  stage.notice = UI:CreateNotice(stage, "info", "")
  stage.notice:SetWidth(560)
  At(stage.notice, 105, 326)
  stage.notice:Hide()
  stage.note = stage.notice.text

  stage.spark = CreateSpark(stage)
  At(stage.spark, 235, 314)
  stage.spark:SetAlpha(0)

  -- the result column (x 270..500)
  local res = {}
  stage.cmpRef = Reveal(CreateCmpBar(stage, C.sentence, "ref"), 186, 282)
  stage.cmpWork = Reveal(CreateCmpBar(stage, C.word, "gold"), 220, 282)
  stage.cmpWork.l:SetText("Working set")
  for _, f in ipairs({ stage.cmpRef, stage.cmpWork }) do At(f, f.revealX, f.revealY); res[#res + 1] = f end

  stage.delta = Reveal(CreateFrame("Frame", nil, stage), 256, 270)
  stage.delta:SetSize(230, 22)
  stage.delta.a = UI:Text(stage.delta, "page", C.green, T_L)
  stage.delta.b = UI:Text(stage.delta, "title", C.green, T_L)
  At(stage.delta, 270, 256)
  res[#res + 1] = stage.delta

  stage.verdict = Reveal(CreateFrame("Frame", nil, stage), 280, 270)
  stage.verdict:SetSize(230, 16)
  stage.verdict.fs = UI:Text(stage.verdict, "small", C.okText, T_C)
  stage.verdict.fs:SetPoint("TOP", stage.verdict, "TOP", 0, 0)
  At(stage.verdict, 270, 280)
  res[#res + 1] = stage.verdict

  stage.staleNote = UI:Text(stage, "small", C.stale, T_C)
  stage.staleNote:SetPoint("TOP", stage, "TOPLEFT", CX, -280)
  stage.staleNote:SetText("Working set changed  \194\183  click the circle")
  stage.staleNote:Hide()

  stage.meta = UI:Text(stage, "caps", C.warn, T_C)
  stage.meta:SetPoint("TOP", stage, "TOPLEFT", CX, -298)
  stage.meta:SetWidth(230)

  stage.nerd = Reveal(CreateNerdButton(stage), 318, 280)
  At(stage.nerd, 280, 318)
  res[#res + 1] = stage.nerd

  stage.chip = Reveal(CreateChip(stage), 361, 276)
  At(stage.chip, 276, 361)
  res[#res + 1] = stage.chip
  stage.res = res
  for _, f in ipairs(res) do f:SetAlpha(0); f:Hide() end

  stage.recent = CreateRecentLink(stage)

  stage:SetScript("OnUpdate", function(_, dt) Stage:OnUpdate(dt) end)
  stage:SetScript("OnHide", function() FinishTweens() end)

  -- (tests: what SimPanel used to call its card)
  stage.big = sigil.n
  stage.run = sigil
  stage.sigil = sigil
  Stage.frame = stage
  return stage
end

-- ---------------------------------------------------------------------------------------------------------------
-- States
-- ---------------------------------------------------------------------------------------------------------------
Stage.mode = nil       -- "idle" | "run" | "done" | "stale" | "unsupported"

function Stage:SetHover(on)
  self.hovering = on
  local a = 0
  if on and (self.mode == "idle" or self.mode == "done" or self.mode == "stale") then a = 0.10 end
  Tween("hover", 0.2, function(e)
    local from = sigil.hoverA or 0
    sigil.hover:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], from + (a - from) * e)
    if e >= 1 then sigil.hoverA = a end
  end)
end

local function SetSpecIcon()
  local RC = ns.RaidComp
  local _, cls = UnitClass("player")
  local path
  if RC and RC.SpecIcon and ns.SPECS and ns.SPECS[cls] then
    for i, s in ipairs(ns.SPECS[cls]) do
      if s.label == R():Spec() then path = RC:SpecIcon(cls, i) end
    end
  end
  path = path or "Interface\\Icons\\INV_Misc_QuestionMark"
  if sigil.specPath == path then return end
  sigil.specPath = path
  if SetPortraitToTexture and type(path) == "string" then
    SetPortraitToTexture(sigil.spec, path)
  else
    sigil.spec:SetTexture(path)
    sigil.spec:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  end
end

-- the words of the sentence and the chip (ns.SimPanel:SettingWords gives the values)
function Stage:RefreshSettings()
  local w = P():SettingWords()
  local changes = w.changes > 0 and (w.changes == 1 and "(1 change)" or ("(%d changes)"):format(w.changes)) or nil
  local line1 = { { "Sim my" }, { "Working set", key = "working", tip = P().WordTip.working } }
  if changes then line1[#line1 + 1] = { changes, small = true } end
  line1[#line1 + 1] = { "against" }
  line1[#line1 + 1] = { w.target, key = "target", tip = P().WordTip.target }
  line1[#line1 + 1] = { ",", tight = true }
  local line2 = {
    { w.fights, key = "fights", tip = P().WordTip.fights }, { "of" },
    { w.duration, key = "duration", tip = P().WordTip.duration }, { "on a" },
    { w.boss, key = "mob", tip = P().WordTip.mob }, { "with" },
    { w.buffs, key = "buffs", tip = P().WordTip.buffs }, { ".", tight = true },
  }
  LayoutSentence(stage.sentence, { line1, line2 })
  stage.chip:SetLabel(w.chip)
  if stage.chip:IsShown() then At(stage.chip, stage.chip.revealX, stage.chip.revealY) end
  sigil.runSub:SetText(Spaced(w.fights))
end

-- What the page should show now.
local function Wanted()
  local Sim = P()
  if not Sim:IsActive() then return nil end
  if not R():IsSupported() then return "unsupported" end
  local st = Sim._state()
  if st.running then return "run" end
  if st.results then return st.stale and "stale" or "done" end
  return "idle"
end

-- Doll: hidden before a result; slides in (tiles from their sides, staggered) when one arrives.
local function DollShown(on, animate)
  if not doll then return end
  FinishTweens()
  if not on then
    if animate and doll:IsShown() then
      Tween("doll", 0.28, function(e) doll:SetAlpha(1 - e) end, 0, function() doll:Hide(); doll:SetAlpha(1) end)
    else
      doll:Hide()
    end
    return
  end
  doll:SetAlpha(1)
  doll:Show()
  if not animate then return end
  for sid, tile in pairs(doll.tiles or {}) do
    local p, rel, rp, x, y = tile:GetPoint(1)
    if p then
      local row = floor(-(tonumber(y) or 0) / 62 + 0.5)
      local side = tile.side or "L"
      local dx = side == "L" and -18 or (side == "R" and 18 or 0)
      local dy = side == "C" and -14 or 0
      local delay = (side == "C" and 9 or row) * 0.032
      tile:SetAlpha(0)
      Tween("tile" .. sid, 0.55, function(e)
        tile:SetAlpha(min(1, e * 1.25))
        tile:SetPoint(p, rel, rp, x + dx * (1 - e), y + dy * (1 - e))
      end, delay)
    end
  end
end

local function ShowResults(on, animate)
  for i, f in ipairs(stage.res) do
    local y0 = f.revealY
    if on then
      f:Show()
      if animate then
        f:SetAlpha(0)
        Tween("res" .. i, 0.5, function(e)
          f:SetAlpha(e)
          At(f, f.revealX, y0 + 8 * (1 - e))
        end, 0.22 + (i - 1) * 0.08)
      else
        f:SetAlpha(1)
        At(f, f.revealX, y0)
      end
    else
      if animate and f:IsShown() then
        Tween("res" .. i, 0.2, function(e) f:SetAlpha(1 - e) end, 0, function() f:Hide() end)
      else
        f:SetAlpha(0)
        f:Hide()
      end
    end
  end
end

local function ArtShown(alpha, animate)
  local from = stage.artFrame:GetAlpha()
  if animate then
    Tween("art", 0.9, function(e) stage.artFrame:SetAlpha(from + (alpha - from) * e) end)
  else
    stage.artFrame:SetAlpha(alpha)
  end
end

-- a frame fading in or out (hidden at the end of a fade out)
local function Fade(key, f, on, animate, dur)
  if on then f:Show() end
  if animate and (on or f:IsShown()) then
    local from = f:GetAlpha()
    Tween(key, dur or 0.35, function(e) f:SetAlpha(from + ((on and 1 or 0) - from) * e) end, 0,
      function() if not on then f:Hide() end end)
  else
    f:SetAlpha(on and 1 or 0)
    f:SetShown(on and true or false)
  end
end

local function SentenceShown(on, animate) Fade("sentence", stage.sentence, on, animate, 0.35) end
local function SparkShown(on, animate) Fade("spark", stage.spark, on, animate, 0.4) end

local function SigilTo(where, animate)
  local cy0, s0 = sigil.cy or IDLE_Y, sigil.sc or 1
  local cy1, s1 = where == "top" and DONE_Y or IDLE_Y, where == "top" and DONE_SCALE or 1
  if animate then
    Tween("sigil", 0.8, function(e)
      local cy, sc = cy0 + (cy1 - cy0) * e, s0 + (s1 - s0) * e
      sigil.cy, sigil.sc = cy, sc
      PlaceSigil(cy, sc)
    end)
  else
    sigil.cy, sigil.sc = cy1, s1
    PlaceSigil(cy1, s1)
  end
end

-- The inside of the dial for a mode.
local function Inside(mode)
  local before = mode == "idle" or mode == "unsupported"
  sigil.spec:SetShown(before); sigil.specRing:SetShown(before); sigil.specGlow:SetShown(before)
  sigil.runText:SetShown(before); sigil.runSub:SetShown(before and mode ~= "unsupported")
  sigil.k:SetShown(not before); sigil.n:SetShown(not before); sigil.pm:SetShown(not before)
  sigil.again:SetShown(mode == "stale")
  sigil:SetEnabled(mode ~= "unsupported")
  UI:SetTextStyle(sigil.n, (mode == "done" or mode == "stale") and 42 or 34, C.text)
  sigil.n:SetAlpha(mode == "stale" and 0.35 or 1)
  sigil.pm:SetAlpha(mode == "stale" and 0.35 or 1)
  if mode == "unsupported" then
    sigil.runText:SetText("Not covered yet")
    sigil.runText:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
    sigil.spec:SetDesaturated(true)
  else
    sigil.runText:SetText("Run simulation")
    sigil.runText:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    sigil.spec:SetDesaturated(false)
  end
end

-- The Recent runs link: before a run under the sentence, after one under the chip; not while a run goes or with
-- nothing to show.
local RECENT_Y = { idle = 404, done = 396, stale = 396 }
local function RecentShown(mode, animate)
  local f = stage.recent
  local n = ns.SimHistory and #ns.SimHistory:Runs() or 0
  local y = RECENT_Y[mode]
  if not y or n == 0 then
    Fade("recent", f, false, animate, 0.2)
    return
  end
  f:SetCount(n)
  At(f, CX - floor(f:GetWidth() / 2 + 0.5), y)
  if not f:IsShown() then
    Fade("recent", f, true, animate, 0.4)
  end
end

-- the result's numbers into the column and the dial
local function FillResults()
  local Sim = P()
  local res = Sim._state().results
  if not res then return end
  sigil.k:SetText(Spaced("Working set"))
  sigil.n:SetText(Fmt(res.work.dps))
  sigil.pm:SetText("DPS")
  local a, b = res.ref.dps, res.work.dps
  local lo, hi = min(a, b) * 0.85, max(a, b) * 1.01
  stage.cmpRef.l:SetText(Sim:TargetText(res.target))
  stage.cmpRef.v:SetText(Fmt(a))
  stage.cmpWork.v:SetText(Fmt(b))
  stage.cmpRef.frac = (a - lo) / (hi - lo)
  stage.cmpWork.frac = (b - lo) / (hi - lo)
  local d, se = res.diff, res.se
  local col, kind = Verdict(d, se)              -- (none: the same gear, or as good as: nothing to call)
  local da, db = stage.delta.a, stage.delta.b
  da:SetText(ns.SimPanel.Signed(d) .. " DPS")
  db:SetText(PctText(d, a))
  da:SetTextColor(col[1], col[2], col[3]); db:SetTextColor(col[1], col[2], col[3])
  local wa, wb = tonumber(da:GetStringWidth()) or 70, tonumber(db:GetStringWidth()) or 40
  local x0 = (230 - (wa + 6 + wb)) / 2
  da:ClearAllPoints(); da:SetPoint("BOTTOMLEFT", stage.delta, "BOTTOMLEFT", x0, 2)
  db:ClearAllPoints(); db:SetPoint("BOTTOMLEFT", da, "BOTTOMRIGHT", 6, 1)
  VerdictLine(stage.verdict.fs, kind, se, "A real upgrade", "A downgrade")
  stage.meta:SetText(Sim:MetaWarning() or "")
end

local function PaintBars(e)
  for _, f in ipairs({ stage.cmpRef, stage.cmpWork }) do
    f:SetFrac(nil, e)
  end
end

local function StaleLook(on)
  local a = on and 0.32 or 1
  for _, f in ipairs({ stage.cmpRef, stage.cmpWork, stage.delta }) do
    if f:IsShown() then f:SetAlpha(a) end
  end
  stage.verdict:SetShown(not on and stage.cmpRef:IsShown())
  if on then
    stage.staleNote:SetText((P()._state().staleWhy or "Working set changed") .. "  \194\183  click the circle")
  end
  stage.staleNote:SetShown(on)
  stage.meta:SetShown(not on)
end

-- Puts the page in `mode`; animate = the moves between modes (else at once, e.g. when the page opens).
function Stage:Apply(mode, animate)
  local from = self.mode
  self.mode = mode
  if mode == "run" then
    self.sweep, self.k, self.lit = 0, 0, 0
    self.runSerial = P()._state().serial or 0
    self.finishing = nil
    stage.spark.lo, stage.spark.hi = nil, nil
    PaintSpark(stage.spark, {}, 0, 1)
  end
  Inside(mode)
  if mode == "idle" or mode == "unsupported" then
    SetSpecIcon()
    self:RefreshSettings()
    DollShown(false, animate)
    ShowResults(false, animate)
    SigilTo("centre", animate and from ~= nil)
    ArtShown(0.55, animate)
    SentenceShown(mode == "idle", animate)
    if mode == "unsupported" then
      stage.notice:SetNotice("info", ("The gear sim covers %s for now. Pick such a spec in the tabs above to sim it.")
        :format(R().COVERED))
    end
    stage.notice:SetShown(mode == "unsupported")
    SparkShown(false, animate)
    StaleLook(false)
    stage.meta:Hide()
    PaintTicks(0)
  elseif mode == "run" then
    if ns.SimNerd then ns.SimNerd:Close(true) end
    if ns.SimHistoryUI then ns.SimHistoryUI:Close(true) end
    stage.notice:Hide()
    sigil.k:SetText(Spaced("Simulating"))
    sigil.n:SetText("\226\128\148")
    sigil.pm:SetText("")
    DollShown(false, animate)
    ShowResults(false, animate)
    SigilTo("centre", animate)
    ArtShown(0.75, animate)
    SentenceShown(false, animate)
    SparkShown(true, animate)
    StaleLook(false)
    stage.meta:Hide()
    PaintTicks(0)
  else -- done / stale
    stage.notice:Hide()
    self:RefreshSettings()
    FillResults()
    local entering = from ~= "done" and from ~= "stale"
    if entering then
      DollShown(true, animate)
      SigilTo("top", animate)
      ArtShown(0, animate)
      SentenceShown(false, animate)
      SparkShown(false, animate)
      ShowResults(true, animate)
      if animate then
        Tween("bars", 1.0, function(e) PaintBars(e) end, 0.45)
      else
        PaintBars(1)
      end
    else
      PaintBars(1)
    end
    PaintTicks(TICKS, mode == "stale")
    StaleLook(mode == "stale")
  end
  RecentShown(mode, animate)
  if self.hovering then self:SetHover(true) end
end

-- The end of a run: the ticks flash, then the result moves in.
function Stage:Finish()
  self.finishing = true
  PaintTicks(TICKS)
  local s = sigil
  for i, l in ipairs(s.ticks) do
    local delay = (i - 1) * 0.004
    Tween("flash" .. i, 0.5, function(e)
      local c = { C.head[1] + (C.gold2[1] - C.head[1]) * e, C.head[2] + (C.gold2[2] - C.head[2]) * e,
        C.head[3] + (C.gold2[3] - C.head[3]) * e }
      l:SetVertexColor(c[1], c[2], c[3], 1)
    end, delay)
  end
  Tween("flashglow", 0.52, function(e)
    local a = e < 0.4 and (e / 0.4) or (1 - (e - 0.4) / 0.6)
    s.flash:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.55 * a)
  end)
  Tween("finishwait", 0.38, function() end, 0, function()
    if self.mode == "run" then
      local want = Wanted()
      if want == "done" or want == "stale" then self:Apply(want, true) else self:Apply(want or "idle", true) end
    end
  end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Per frame: the tweens, the turning ring, a run's sweep
-- ---------------------------------------------------------------------------------------------------------------
function Stage:OnUpdate(dt)
  dt = min(dt or 0, 0.1)
  StepTweens(dt)
  -- the outer ring turns: a full turn in 40 s, 7 s while simming
  local speed = (self.mode == "run") and (2 * pi / 7) or (2 * pi / 40)
  sigil.dashAngle = (sigil.dashAngle + speed * dt) % (2 * pi)
  sigil.dash:SetRotation(-sigil.dashAngle)
  if self.mode == "run" and not self.finishing then self:StepRun(dt) end
end

-- The sweep follows the run's real progress, at most a whole dial in MIN_SWEEP seconds. A run stopped before its
-- end goes straight back (to the old result or the start).
function Stage:StepRun(dt)
  local st = P()._state()
  local finished = (st.serial or 0) ~= (self.runSerial or 0)
  if not st.running and not finished then
    self:Apply(Wanted() or "idle", true)
    return
  end
  local real = finished and 1 or (st.progress or 0)
  self.sweep = min(real, (self.sweep or 0) + dt / MIN_SWEEP)
  if self.holdAt then self.sweep, finished = min(self.holdAt, (self.sweep or 0) + dt / MIN_SWEEP), false end
  local list, total = P():LiveList()
  list = list or {}
  total = max(1, total or #list)
  local k = min(#list, floor(self.sweep * total + 0.5))
  self.lit = self.sweep * TICKS
  PaintTicks(self.lit)
  if k > 0 then
    local s, q = 0, 0
    for i = 1, k do s = s + list[i]; q = q + list[i] ^ 2 end
    local m = s / k
    local sd = sqrt(max(0, q / k - m * m))
    sigil.n:SetText(Fmt(m))
    if st.paused and st.running then
      sigil.pm:SetText("Paused  \194\183  in combat")
    else
      sigil.pm:SetText(("\194\177 %s  \194\183  %s / %s"):format(Fmt(2 * sd / sqrt(k)), Fmt(k), Fmt(total)))
    end
    PaintSpark(stage.spark, list, k, total)
  elseif st.paused and st.running then
    sigil.pm:SetText("Paused  \194\183  in combat")
  end
  if finished and self.sweep >= 1 then self:Finish() end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The calls ns.SimPanel makes
-- ---------------------------------------------------------------------------------------------------------------
-- Shows the stage for the Gear sim page (on) or hides it and gives the doll back to the lists (off).
function Stage:Show(on)
  if not stage then return end
  if not on then
    FinishTweens()
    stage:Hide()
    self.mode = nil
    self.covered = nil
    -- (the doll comes back at full alpha but is not shown here: My BiS's repaint shows it for the lists and keeps it
    -- hidden for Consumables, which calls this after hiding it)
    if doll then
      doll:SetAlpha(1)
      for _, tile in pairs(doll.tiles or {}) do tile:SetAlpha(1) end
    end
    self.dollCovered = nil
    if ns.SimNerd then ns.SimNerd:Close(true) end
    if ns.SimHistoryUI then ns.SimHistoryUI:Close(true) end
    return
  end
  if self.covered then return end       -- (under Nerd stats / Recent runs: Cover(false) brings it back)
  local first = not stage:IsShown()
  stage:Show()
  self:Sync(not first)
end

-- Brings the page to what SimPanel's state says (animated unless it just opened).
function Stage:Sync(animate)
  -- (a run starting under Nerd stats / Recent runs: they close and the page shows it)
  if stage and self.covered and Wanted() == "run" then
    if ns.SimNerd then ns.SimNerd:Close(true) end
    if ns.SimHistoryUI then ns.SimHistoryUI:Close(true) end
  end
  if not stage or not stage:IsShown() then return end
  local want = Wanted()
  if not want then return end
  local cur = self.mode
  -- (My BiS shows the doll on every repaint: before a result it stays hidden)
  if (cur == "idle" or cur == "run" or cur == "unsupported") and doll and doll:IsShown() and not tweens.doll then
    doll:Hide()
  end
  if cur == "run" and want ~= "run" then
    -- a finished run sweeps to its end first (StepRun, then Finish); a stopped one goes back now
    local finished = (P()._state().serial or 0) ~= (self.runSerial or 0)
    if finished and animate ~= false and stage:IsVisible() and P()._state().doneSeen then return end
    if self.finishing and animate ~= false then return end
    FinishTweens()
    self:Apply(want, animate and not finished)
    return
  end
  if want == cur then
    if want == "done" or want == "stale" then FillResults(); PaintBars(1); self:RefreshSettings() end
    if want == "idle" then self:RefreshSettings() end
    if want == "done" or want == "stale" then StaleLook(want == "stale") end
    RecentShown(want, false)
    if (want == "idle" or want == "run" or want == "unsupported") and doll and not tweens.doll then doll:Hide() end
    return
  end
  self:Apply(want, animate and cur ~= nil)
end

-- Nerd stats / Recent runs open over the page (on) or closed at once (off): they have no fill of their own (the
-- window's background shows through), so the page's own pieces and the doll go out of sight under them (hidden, at
-- alpha 0 for the fade back) and come back as the page's state wants them. Their frames sit beside the stage
-- (Stage:OverlayParent), not in it.
function Stage:OverlayParent() return stage and stage:GetParent() end

-- Their frame level: over the page's body, the stage (the dial is a button) and the doll's tiles, so nothing of the
-- page under them takes the mouse.
function Stage:OverlayLevel(body)
  local l = body and body:GetFrameLevel() or 0
  if stage then l = max(l, stage:GetFrameLevel() + 10) end
  if doll then l = max(l, doll:GetFrameLevel() + 10) end
  return l + 30
end

function Stage:Cover(on)
  if not stage then return end
  stage:SetAlpha(on and 0 or 1)
  if on then
    if not self.covered and stage:IsShown() then
      self.covered = true
      stage:Hide()
      if doll and doll:IsShown() then
        doll:SetAlpha(0)
        doll:Hide()
        self.dollCovered = true
      end
    end
    return
  end
  local was, dollWas = self.covered, self.dollCovered
  self.covered, self.dollCovered = nil, nil
  if doll and (dollWas or doll:IsShown()) then doll:SetAlpha(1) end
  if not was or not P():IsActive() then
    if dollWas and doll then doll:Show() end
    return
  end
  stage:Show()
  if dollWas and doll and (self.mode == "done" or self.mode == "stale") then doll:Show() end
  self:Sync(false)
end

-- Back from Nerd stats: the result page fades in like a page of the main window.
function Stage:FadePage()
  if not (stage and ns.SimNerd and ns.SimNerd.FadeIn) then return end
  ns.SimNerd.FadeIn(stage)
  if doll and doll:IsShown() then ns.SimNerd.FadeIn(doll) end
end

-- (tests) the stage's mode, sweep and the frames.
function Stage._frame() return stage end
function Stage._doll() return doll end
function Stage._tweens() return tweens end
function Stage._sigil() return sigil end
