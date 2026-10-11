if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SimNerd.lua", ...) then return end -- DisasterZone: UI/SimNerd.lua
-- ns.SimNerd: the gear sim's Nerd stats (mockup B, dev/art/casc/simflow_mockup): everything about the last run, over
-- the Gear sim page. It opens out of the centre column to the page's width; "< Results" closes it.
--   Overview         the run's numbers, DPS per fight (both sets), how the average settled, swing outcomes, sources
--   Abilities        every ability: DPS, share, vs the target set, casts, crit / miss / dodge / glance, average hit
--                    and crit, the biggest hit; the first 20 seconds of fight 1, cast by cast
--   Buffs & procs    uptime of every proc, cooldown and potion; fight 1's cooldowns on a time line
--   Mana             the mana curve (average and the middle 80% of fights), where mana comes from and goes
--   Stats & weights  the stats the fight starts with (buffs in), stat weights on demand (extra paired sims)
--   The run          fights, seed, time, cache, engine, rotation, talents; the best, worst and most typical fight
-- The numbers come from the sim's metrics (Sim/Character.lua: watched only, never acting on a roll).
local addonName, ns = ...

local Nerd = {}
ns.SimNerd = Nerd

local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt

local FONT = (GameFontNormal and GameFontNormal:GetFont()) or "Fonts\\FRIZQT__.TTF"
local NUM = "Fonts\\ARIALN.TTF"
local W, H = 770, 496
local TOP = 76            -- the pages start here (under the header and the tabs)
local PH = H - TOP        -- a page's height

local C = {
  gold = { 1, 0.82, 0 }, gold2 = { 0.886, 0.702, 0.243 }, light = { 1, 0.953, 0.69 },
  text = { 0.925, 0.925, 0.925 }, sub = { 0.863, 0.863, 0.863 }, dim = { 0.561, 0.561, 0.584 },
  axis = { 0.49, 0.49, 0.522 }, label = { 0.659, 0.659, 0.682 },
  green = { 0.31, 0.83, 0.42 }, red = { 0.88, 0.38, 0.31 }, grey = { 0.49, 0.49, 0.51 },
  card = { 0.106, 0.106, 0.122 }, box = { 0.094, 0.094, 0.11 }, edge = { 0.137, 0.137, 0.157 },
  track = { 0.137, 0.137, 0.157 }, line = { 0.149, 0.149, 0.173 },
  blue = { 0.373, 0.608, 1 }, ref = { 0.722, 0.722, 0.753 },
}
-- melee swing outcomes
local OUT = { { "Miss", { 0.416, 0.416, 0.447 } }, { "Dodge", { 0.541, 0.541, 0.573 } }, { "Glancing", { 0.365, 0.498, 0.69 } },
  { "Crit", { 1, 0.843, 0.353 } }, { "Hit", { 0.788, 0.651, 0.251 } } }

local function R() return ns.SimRunner end
local function P() return ns.SimPanel end
local function Fmt(v) return ns.SimPanel.Fmt(v) end
local function Fmt1(v)
  local s = Fmt(floor(v))
  return s .. ("%.1f"):format(v - floor(v)):sub(2)
end
local function Pct(v) return ("%.1f%%"):format(v * 100) end
local function Signed1(v) return (v >= 0 and "+" or "\226\136\146") .. ("%.1f"):format(abs(v)) end
local function Time(t) return ("%d:%02d"):format(floor(t / 60), floor(t % 60)) end

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

local function Cap(parent, text)
  local fs = Text(parent, 8.5, C.dim)
  fs:SetText(ns.SimStage.Spaced(text))
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

local function Line(parent, layer, c, thick, a)
  local l = parent:CreateLine(nil, layer or "ARTWORK")
  l:SetThickness(thick or 1)
  l:SetColorTexture(c[1], c[2], c[3], a or 1)
  return l
end

local function LineAt(l, parent, x0, y0, x1, y1)
  l:SetStartPoint("TOPLEFT", parent, x0, -y0)
  l:SetEndPoint("TOPLEFT", parent, x1, -y1)
  l:Show()
end

-- a page's box: dark fill, 1 px edge, a spaced caption and an optional note on the right
local function Box(parent, x, y, w, h, title, note)
  local b = CreateFrame("Frame", nil, parent)
  b:SetSize(w, h)
  Put(b, parent, x, y)
  local bg = Tex(b, "BACKGROUND", C.box)
  bg:SetAllPoints()
  if ns.UI.AddEdges then
    ns.UI:AddEdges(b, "BORDER")
    ns.UI:SetEdgeColor(b, C.edge[1], C.edge[2], C.edge[3], 1)
  end
  b.title = Put(Cap(b, title), b, 10, 9)
  if note then
    b.note = Text(b, 9.5, C.dim, "RIGHT")
    b.note:SetPoint("TOPRIGHT", b, "TOPRIGHT", -10, -8)
    b.note:SetText(note)
  end
  return b
end

-- icons: a spell's or an item's, else a few of the sim's own keys
local KEY_ICON = {
  melee = "Interface\\Icons\\INV_Sword_04", melee_oh = "Interface\\Icons\\INV_Sword_04",
  windfury = "Interface\\Icons\\Spell_Nature_Windfury", windfury_totem = "Interface\\Icons\\Spell_Nature_Windfury",
  soc_proc = "Interface\\Icons\\Ability_Warrior_InnerRage", judge_soc = "Interface\\Icons\\Ability_Warrior_InnerRage",
  flame_cap = "Interface\\Icons\\INV_Misc_Herb_19", bloodlust = "Interface\\Icons\\Spell_Nature_Bloodlust",
  drums = "Interface\\Icons\\INV_Misc_Drum_02", drums_own = "Interface\\Icons\\INV_Misc_Drum_02",
}
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local function SpellIcon(id)
  if not id then return nil end
  if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
  return GetSpellTexture and GetSpellTexture(id) or nil
end
local function ItemIcon(id)
  if not id then return nil end
  if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(id) end
  return GetItemIcon and GetItemIcon(id) or nil
end
local function KeyIcon(key, a)
  if KEY_ICON[key] then return KEY_ICON[key] end
  if type(key) == "string" then
    local base = key:match("^melee") and "melee"
    if base then return KEY_ICON.melee end
    local item = tonumber(key:match("^item:(%d+)"))
    if item then return ItemIcon(item) or QUESTION end
    local sp = tonumber(key:match("^(%d+):"))
    if sp then return SpellIcon(sp) or QUESTION end
  end
  if type(key) == "number" then return SpellIcon(key) or QUESTION end
  if a and a.spellId then return SpellIcon(a.spellId) or QUESTION end
  if a and a.itemId then return ItemIcon(a.itemId) or QUESTION end
  return QUESTION
end

local function KeyName(key)
  local name = R().ABILITIES[key]
  if name then return name end
  local id = tonumber(key) or (type(key) == "string" and tonumber(key:match("^(%d+):")))
  if id and GetSpellInfo then name = GetSpellInfo(id) end
  local item = type(key) == "string" and tonumber(key:match("^item:(%d+)"))
  if not name and item and GetItemInfo then name = GetItemInfo(item) end
  return name or tostring(key)
end

local function IconTex(parent, size, path)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetSize(size, size)
  t:SetTexture(path or QUESTION)
  t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  return t
end

-- ---------------------------------------------------------------------------------------------------------------
-- The result's data, prepared once per run
-- ---------------------------------------------------------------------------------------------------------------
local data          -- { res, work, ref, rows, ... } for the shown result

local function Prepare()
  local st = P()._state()
  local res = st.results
  if not res then data = nil return end
  if data and data.res == res then return end
  local work, ref = res.work, res.ref
  local list = work.iterDps or {}
  local sorted = {}
  for i, v in ipairs(list) do sorted[i] = v end
  table.sort(sorted)
  local n = #sorted
  local median = n > 0 and ((n % 2 == 1) and sorted[(n + 1) / 2] or (sorted[n / 2] + sorted[n / 2 + 1]) / 2) or 0
  local best, worst, bi, wi, ti = -1, math.huge, 1, 1, 1
  local closest = math.huge
  for i, v in ipairs(list) do
    if v > best then best, bi = v, i end
    if v < worst then worst, wi = v, i end
    if abs(v - work.dps) < closest then closest, ti = abs(v - work.dps), i end
  end
  -- abilities grouped by name (a few keys share one: both explosives, both Whirlwind hands)
  local by, rows = {}, {}
  local refBy = {}
  for key, a in pairs(ref.abilities or {}) do
    local name = KeyName(key)
    refBy[name] = (refBy[name] or 0) + a.dps
  end
  for key, a in pairs(work.abilities or {}) do
    if a.dps > 0.05 then
      local name = KeyName(key)
      local r = by[name]
      if not r then
        r = { name = name, key = key, icon = KeyIcon(key, a), dps = 0, casts = 0, hits = 0, crits = 0, glances = 0,
          misses = 0, dodges = 0, damage = 0, critDamage = 0, maxHit = 0 }
        by[name] = r
        rows[#rows + 1] = r
      end
      r.dps = r.dps + a.dps
      r.casts = r.casts + a.casts
      r.hits = r.hits + a.hits
      r.crits = r.crits + a.crits
      r.glances = r.glances + (a.glances or 0)
      r.misses = r.misses + (a.misses or 0)
      r.dodges = r.dodges + (a.dodges or 0)
      r.damage = r.damage + (a.damage or 0)
      r.critDamage = r.critDamage + (a.critDamage or 0)
      r.maxHit = max(r.maxHit, a.maxHit or 0)
      if key == "melee" then r.melee = true end
    end
  end
  for _, r in ipairs(rows) do r.vs = r.dps - (refBy[r.name] or 0) end
  table.sort(rows, function(a, b) return a.dps > b.dps end)
  data = { res = res, work = work, ref = ref, list = list, n = n, median = median, best = best, worst = worst,
    bi = bi, wi = wi, ti = ti, rows = rows, total = work.dps }
end

-- ---------------------------------------------------------------------------------------------------------------
-- The frame
-- ---------------------------------------------------------------------------------------------------------------
local clip, root, pages, tabs, current

local function Body() return ns.SimStage and ns.SimStage._frame() end

local TABS = { { "overview", "Overview" }, { "abilities", "Abilities" }, { "buffs", "Buffs & procs" },
  { "mana", "Mana" }, { "stats", "Stats & weights" }, { "run", "The run" } }

local Build = {}

local function Create()
  if clip then return end
  local body = Body()
  if not body then return end
  clip = CreateFrame("Frame", nil, ns.SimStage:OverlayParent() or body)
  clip:SetFrameLevel(body:GetFrameLevel() + 30)
  if clip.SetClipsChildren then clip:SetClipsChildren(true) end
  clip:Hide()
  root = CreateFrame("Frame", nil, clip)
  root:SetSize(W, H)
  root:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  root:EnableMouse(true)

  -- the back link every page has ("< ALL POLLS", "< ALL RAIDS"): the atlas chevron and small capitals
  local back = CreateFrame("Button", nil, root)
  back:SetSize(80, 14)
  Put(back, root, 0, 0)
  back.icon = back:CreateTexture(nil, "ARTWORK")
  back.icon:SetSize(10, 10)
  back.icon:SetPoint("LEFT", 0, 0)
  ns.UI:SetChevron(back.icon, false)
  back.fs = back:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  back.fs:SetFont((back.fs:GetFont()), 10, "")
  back.fs:SetJustifyH("LEFT")
  back.fs:SetPoint("LEFT", back.icon, "RIGHT", 4, 0)
  back.fs:SetText("RESULTS")
  local function paint(self, on)
    local r, g, bl = 0.65, 0.65, 0.65
    if on then r, g, bl = 1, 0.82, 0 end
    self.fs:SetTextColor(r, g, bl)
    self.icon:SetVertexColor(r, g, bl)
  end
  paint(back, false)
  back:SetScript("OnEnter", function(self) paint(self, true) end)
  back:SetScript("OnLeave", function(self) paint(self, false) end)
  back:SetScript("OnClick", function() Nerd:Close() end)
  root.title = Put(Text(root, 17, C.gold), root, 0, 17)
  root.title:SetText("Nerd stats")
  root.sub = Text(root, 10.5, C.dim)
  root.sub:SetPoint("BOTTOMLEFT", root.title, "BOTTOMRIGHT", 14, 2)
  root.sub:SetPoint("RIGHT", root, "RIGHT", -156, 0)
  root.export = ns.UI:CreateSleekButton(root, "Export to WoWSims", 140, 22, function()
    local Sim = P()
    Sim:ShowExport("Working set", R():WoWSimsSettings(Sim:Working(), Sim:RunSettings()))
  end, "secondary")
  root.export:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, -12)

  tabs = {}
  local x = 0
  for i, t in ipairs(TABS) do
    local b = ns.UI:CreateUnderlineTab(root, t[2], function() Nerd:Show(t[1]) end, "page")
    b:SetPoint("TOPLEFT", root, "TOPLEFT", x - 4, -42)
    x = x + (b:GetWidth() or 80) + 14
    b.key = t[1]
    tabs[i] = b
  end
  local rule = Tex(root, "ARTWORK", C.line)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -66)
  rule:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, -66)
  pages = {}
  Nerd.root = root
end

local function Page(key)
  local pg = pages[key]
  if not pg then
    pg = CreateFrame("Frame", nil, root)
    pg:SetSize(W, PH)
    pg:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -TOP)
    pages[key] = pg
  end
  return pg
end

-- the page as fresh frames for the shown result (old regions are dropped with the old frame)
local function FreshPage(key)
  local old = pages[key]
  if old then old:Hide(); old:SetParent(nil) end
  pages[key] = nil
  local pg = Page(key)
  pg.res = data and data.res
  return pg
end

-- Frames come in like the main window's pages (UI/MainFrame.lua FadeIn): alpha 0 -> 1 over 0.12 s, eased.
local FADE_IN = 0.12
function Nerd.FadeIn(f)
  f:SetAlpha(0)
  local fader = f.dzNerdFader
  if not fader then
    fader = CreateFrame("Frame", nil, f)
    f.dzNerdFader = fader
  end
  fader.t = 0
  fader:SetScript("OnUpdate", function(self, elapsed)
    self.t = self.t + (elapsed or 0)
    local p = min(1, self.t / FADE_IN)
    f:SetAlpha(1 - (1 - p) ^ 3)
    if p >= 1 then self:SetScript("OnUpdate", nil) end
  end)
end

-- Nerd stats in place of the result, as a page swap: it covers the page; going back fades the result in.
local function Reveal(on)
  local body = Body()
  if not body then return end
  clip:SetScript("OnUpdate", nil)
  clip:ClearAllPoints()
  clip:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  clip:SetPoint("BOTTOMRIGHT", body, "TOPLEFT", W, -H)
  clip.inset = on and 0 or nil
  if on then
    clip:Show()
    ns.SimStage:Cover(true)
    Nerd.FadeIn(clip)
  else
    clip:Hide()
    ns.SimStage:Cover(false)
    if ns.SimStage.FadePage then ns.SimStage:FadePage() else Nerd.FadeIn(body) end
  end
end

function Nerd:IsOpen() return clip and clip:IsShown() and self.open or false end

-- Opens Nerd stats on a page (default: the one shown last, else Overview).
function Nerd:Open(key)
  Create()
  if not clip then return end
  Prepare()
  if not data then return end
  local was = clip:IsShown()
  self.open = true
  current = key or current or "overview"
  clip:Show()
  self:Show(current)
  if not was then Reveal(true) end
end

function Nerd:Close(instant)
  self.open = false
  if not clip or not clip:IsShown() then return end
  if instant then
    clip:Hide()
    ns.SimStage:Cover(false)
    return
  end
  Reveal(false)
end

-- A new result while it is open: the shown page follows it.
function Nerd:Refresh()
  if not self:IsOpen() then return end
  Prepare()
  if not data then self:Close(true) return end
  self:Show(current)
end

function Nerd:Show(key)
  if not root then return end
  current = key
  for _, b in ipairs(tabs) do b:SetActive(b.key == key) end
  for k, pg in pairs(pages) do pg:SetShown(k == key) end
  local w = data.res.info and data.res.info.settings or P():RunSettings()
  local words = P():SettingWords()
  root.sub:SetText(("%s fights \195\151 2 sets  \194\183  %s  \194\183  Lv 73 %s")
    :format(Fmt(data.n), Time(w.duration or 180), w.mobType or "Mechanical"))
  local pg = pages[key]
  if not pg or pg.res ~= data.res or pg.dirty then
    pg = FreshPage(key)
    Build[key](pg)
  end
  pg:Show()
  Nerd.FadeIn(pg)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Pieces the pages share
-- ---------------------------------------------------------------------------------------------------------------
local function Kpis(pg, list)
  local gap = 6
  local w = (W - (#list - 1) * gap) / #list
  for i, k in ipairs(list) do
    local f = CreateFrame("Frame", nil, pg)
    f:SetSize(w, 50)
    Put(f, pg, (i - 1) * (w + gap), 0)
    local bg = Tex(f, "BACKGROUND", C.card)
    bg:SetAllPoints()
    Put(Cap(f, k[1]), f, 10, 8)
    local v = Put(Text(f, 19, k[4] or C.text, "LEFT", NUM), f, 10, 22)
    v:SetText(k[2])
    if k[3] then
      local s = Text(f, 11, C.dim, "LEFT", NUM)
      s:SetPoint("BOTTOMLEFT", v, "BOTTOMRIGHT", 4, 1)
      s:SetText(k[3])
    end
  end
end

-- a share bar: track + fill
local function Bar(parent, x, y, w, h, frac, c, gradient)
  local t = Put(Tex(parent, "ARTWORK", C.track), parent, x, y)
  t:SetSize(w, h)
  local f = parent:CreateTexture(nil, "ARTWORK", nil, 1)
  f:SetColorTexture(1, 1, 1, 1)
  Put(f, parent, x, y)
  f:SetSize(max(1, w * max(0, min(1, frac))), h)
  if gradient and f.SetGradient and CreateColor then
    f:SetGradient("HORIZONTAL", CreateColor(0.604, 0.455, 0.125, 1), CreateColor(1, 0.843, 0.353, 1))
  else
    f:SetVertexColor(c[1], c[2], c[3], 1)
  end
  return t, f
end

local function Num(parent, x, y, text, size, color, justify)
  local fs = Text(parent, size or 12, color or C.text, justify or "RIGHT", NUM)
  if (justify or "RIGHT") == "RIGHT" then
    fs:SetPoint("TOPRIGHT", parent, "TOPLEFT", x, -y)
  else
    Put(fs, parent, x, y)
  end
  fs:SetText(text)
  return fs
end

local function Label(parent, x, y, text, size, color)
  local fs = Put(Text(parent, size or 11, color or C.sub), parent, x, y)
  fs:SetText(text)
  return fs
end

local function Para(parent, x, y, w, text)
  local fs = Put(Text(parent, 10, C.label), parent, x, y)
  fs:SetWidth(w)
  fs:SetWordWrap(true)
  fs:SetSpacing(3)
  fs:SetText(text)
  return fs
end

local function Dashed(parent, x, y0, y1, c)
  local y = y0
  while y < y1 do
    local d = Put(Tex(parent, "OVERLAY", c, 0.9), parent, x, y)
    d:SetSize(1.2, min(3, y1 - y))
    y = y + 5
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Overview
-- ---------------------------------------------------------------------------------------------------------------
function Build.overview(pg)
  local d, res = data, data.res
  local se2 = 2 * d.work.stderr
  local close = abs(res.diff) < 2 * res.se
  Kpis(pg, {
    { "Average", Fmt1(d.work.dps), "DPS" }, { "Median", Fmt1(d.median) }, { "Spread (sd)", Fmt1(d.work.stdev) },
    { "Sure to", "\194\177" .. ("%.1f"):format(se2), "95%" }, { "Worst fight", Fmt(d.worst) }, { "Best fight", Fmt(d.best) },
    { "vs " .. P():TargetText(res.target), Signed1(res.diff), "\194\177" .. ("%.1f"):format(2 * res.se),
      close and C.dim or (res.diff > 0 and C.green or C.red) },
  })

  -- DPS per fight: the Working set's bars, the target's outline
  local box = Box(pg, 0, 60, 470, 206, "DPS per fight")
  local lg = CreateFrame("Frame", nil, box)
  lg:SetSize(200, 12)
  lg:SetPoint("TOPRIGHT", box, "TOPRIGHT", -10, -8)
  local s1 = Tex(lg, "ARTWORK", C.gold2); s1:SetSize(9, 9)
  local l1 = Text(lg, 10, C.label, "LEFT"); l1:SetText("Working set")
  local s2 = lg:CreateTexture(nil, "ARTWORK"); s2:SetSize(9, 9)
  if ns.UI.AddEdges then
    local hold = CreateFrame("Frame", nil, lg); hold:SetSize(9, 9)
    ns.UI:AddEdges(hold, "ARTWORK"); ns.UI:SetEdgeColor(hold, C.ref[1], C.ref[2], C.ref[3], 1)
    s2 = hold
  end
  local l2 = Text(lg, 10, C.label, "LEFT"); l2:SetText(P():TargetText(res.target))
  l2:SetPoint("RIGHT", lg, "RIGHT", 0, 0)
  s2:SetPoint("RIGHT", l2, "LEFT", -5, 0)
  l1:SetPoint("RIGHT", s2, "LEFT", -12, 0)
  s1:SetPoint("RIGHT", l1, "LEFT", -5, 0)

  local a, b = d.list, d.ref.iterDps or {}
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(a) do lo, hi = min(lo, v), max(hi, v) end
  for _, v in ipairs(b) do lo, hi = min(lo, v), max(hi, v) end
  if lo >= hi then lo, hi = lo - 50, hi + 50 end
  local span = hi - lo
  local stepTick = span > 600 and 200 or (span > 250 and 100 or 50)
  lo = floor(lo / stepTick) * stepTick
  hi = (floor(hi / stepTick) + 1) * stepTick
  local bins = 28
  local bw = (hi - lo) / bins
  local function hist(list)
    local c = {}
    for i = 1, bins do c[i] = 0 end
    for _, v in ipairs(list) do
      local k = min(bins, max(1, floor((v - lo) / bw) + 1))
      c[k] = c[k] + 1
    end
    return c
  end
  local hw, hr = hist(a), hist(b)
  local mx = 1
  for i = 1, bins do mx = max(mx, hw[i], hr[i]) end
  local GX, GY, GW, GH = 12, 34, 446, 140
  local colW = GW / bins
  for i = 1, bins do
    local hh = hw[i] / mx * GH
    if hh > 0 then
      local t = Put(Tex(box, "ARTWORK", C.gold2, 0.85), box, GX + (i - 1) * colW + 1, GY + GH - hh)
      t:SetSize(colW - 2, hh)
    end
  end
  local px, py = GX, GY + GH
  for i = 1, bins do
    local y = GY + GH - hr[i] / mx * GH
    local x0, x1 = GX + (i - 1) * colW, GX + i * colW
    LineAt(Line(box, "OVERLAY", C.ref, 1.2), box, px, py, x0, y)
    LineAt(Line(box, "OVERLAY", C.ref, 1.2), box, x0, y, x1, y)
    px, py = x1, y
  end
  LineAt(Line(box, "OVERLAY", C.ref, 1.2), box, px, py, GX + GW, GY + GH)
  local mxX = GX + (d.work.dps - lo) / (hi - lo) * GW
  Dashed(box, mxX, GY - 4, GY + GH, C.light)
  Num(box, mxX + 4, GY - 4, Fmt(d.work.dps), 10.5, C.light, "LEFT")
  local base = Put(Tex(box, "ARTWORK", { 0.227, 0.227, 0.259 }), box, GX, GY + GH)
  base:SetSize(GW, 1)
  for v = lo, hi, stepTick do
    local fs = Text(box, 10, C.axis, "CENTER", NUM)
    fs:SetPoint("TOP", box, "TOPLEFT", GX + (v - lo) / (hi - lo) * GW, -(GY + GH + 5))
    fs:SetText(Fmt(v))
  end

  -- the average as fights finish
  local cb = Box(pg, 478, 60, 292, 206, "Average as fights finish")
  local CX0, CW = 12, 268
  local n = #a
  if n > 1 then
    local s, q = 0, 0
    local m8, sd8
    local means, cis = {}, {}
    for i, v in ipairs(a) do
      s, q = s + v, q + v * v
      means[i] = s / i
      local sd = sqrt(max(0, q / i - means[i] ^ 2))
      cis[i] = 2 * sd / sqrt(i)
      if i == min(n, 8) then m8, sd8 = means[i], sd end
    end
    local half = max(d.work.dps * 0.02, 2.4 * (sd8 or 50) / sqrt(8))
    local ylo, yhi = d.work.dps - half, d.work.dps + half
    local function Y(v) return GY + GH - (min(yhi, max(ylo, v)) - ylo) / (yhi - ylo) * GH end
    local steps = min(n, 120)
    local lx, ly
    for k = 1, steps do
      local i = max(1, floor(k / steps * n + 0.5))
      local x = CX0 + i / n * CW
      local y = Y(means[i])
      local band = cb:CreateTexture(nil, "BACKGROUND", nil, 2)
      band:SetColorTexture(1, 0.82, 0, 0.12)
      local top, bot = Y(means[i] + cis[i]), Y(means[i] - cis[i])
      Put(band, cb, lx or CX0, top)
      band:SetSize(max(0.6, x - (lx or CX0) + 0.3), max(1, bot - top))
      if lx then LineAt(Line(cb, "OVERLAY", { 1, 0.843, 0.353 }, 1.5), cb, lx, ly, x, y) end
      lx, ly = x, y
    end
    local yf = Y(d.work.dps)
    local x = CX0
    while x < CX0 + CW do
      local dsh = Put(Tex(cb, "ARTWORK", { 0.333, 0.333, 0.361 }), cb, x, yf)
      dsh:SetSize(min(3, CX0 + CW - x), 1)
      x = x + 6
    end
    Num(cb, CX0 + CW, yf - 14, Fmt(d.work.dps), 10, C.label)
  end
  local cbase = Put(Tex(cb, "ARTWORK", { 0.227, 0.227, 0.259 }), cb, CX0, GY + GH)
  cbase:SetSize(CW, 1)
  for k = 0, 5 do
    local fs = Text(cb, 10, C.axis, "CENTER", NUM)
    fs:SetPoint("TOP", cb, "TOPLEFT", CX0 + k / 5 * CW, -(GY + GH + 5))
    fs:SetText(Fmt(k / 5 * n))
  end

  -- swing outcomes (melee) or the top spell's
  local ob = Box(pg, 0, 274, 470, 142, "Melee swing outcomes", "boss level 73  \194\183  from behind")
  local melee
  for _, r in ipairs(d.rows) do if r.melee then melee = r end end
  if not melee then
    melee = d.rows[1]
    if melee then
      ob.title:SetText(ns.SimStage.Spaced("Outcomes  \194\183  " .. melee.name))
      ob.note:SetText("")
    end
  end
  if melee then
    local landed = melee.hits + melee.crits + melee.glances
    local all = landed + melee.misses + melee.dodges
    if all > 0 then
      local vals = { melee.misses / all, melee.dodges / all, melee.glances / all, melee.crits / all, melee.hits / all }
      local x = 12
      for i, o in ipairs(OUT) do
        local w = vals[i] * 446
        if w >= 0.5 then
          local t = Put(Tex(ob, "ARTWORK", o[2]), ob, x, 34)
          t:SetSize(max(1, w - 1), 22)
          if w > 34 then
            Label(ob, x, 62, o[1], 10, C.label)
            Num(ob, x, 75, Pct(vals[i]), 12, C.text, "LEFT")
          end
        end
        x = x + w
      end
      local stats = d.work.stats or {}
      local ST = ns.GearSim and ns.GearSim.ST or {}
      local hit = stats[ST.PhysicalHitPercent] or 0
      local cfg = R():BuffConfig(P():GetBuffs())
      local iff = cfg and cfg.debuffs and (cfg.debuffs.faerieFire == 2)
      local cap = 9 - (iff and 3 or 0)
      local exp = floor((stats[ST.ExpertiseRating] or 0) / (ns.GearSim and ns.GearSim.EXPERTISE_PER_QUARTER or 3.94))
      local text
      if melee.melee then
        local need = max(0, cap - hit)
        text = ("Miss %s  \194\183  Dodge %s  \226\128\148  %s, expertise %d (dodge %s left). Glancing blows hit for 75%%.")
          :format(Pct(vals[1]), Pct(vals[2]),
            need > 0.05 and ("|cffe6e6e6%.1f%% hit (%d rating) to the cap|r"):format(need, floor(need * 15.77 + 0.5))
              or "|cff4fd36bhit capped|r", exp, Pct(vals[2]))
      else
        text = ("%s of %s casts land as crits; %s miss."):format(Pct(vals[4]), Fmt(melee.casts), Pct(vals[1]))
      end
      Para(ob, 12, 104, 446, text)
    end
  end

  -- damage by source: the top four and the rest
  local sb = Box(pg, 478, 274, 292, 142, "Damage by source")
  local total = max(1, d.total)
  local other = total
  for i = 1, min(4, #d.rows) do
    local r = d.rows[i]
    other = other - r.dps
    local y = 32 + (i - 1) * 21
    Label(sb, 12, y, r.name, 11)
    Bar(sb, 132, y + 5, 106, 6, r.dps / total / 0.5, C.gold2, i <= 2)
    Num(sb, 280, y - 1, Pct(r.dps / total), 12.5)
  end
  if #d.rows > 4 then
    local y = 32 + 4 * 21
    Label(sb, 12, y, "Everything else", 11, C.label)
    Bar(sb, 132, y + 5, 106, 6, other / total / 0.5, { 0.416, 0.416, 0.447 })
    Num(sb, 280, y - 1, Pct(other / total), 12.5)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Abilities
-- ---------------------------------------------------------------------------------------------------------------
local COLS = { { "DPS", 282 }, { "Share", 328 }, { "vs gear", 378 }, { "Casts", 424 }, { "/ min", 464 }, { "Crit", 510 },
  { "Miss", 552 }, { "Dodge", 596 }, { "Glance", 642 }, { "Avg hit", 688 }, { "Avg crit", 732 }, { "Max", 770 } }
local MAX_ROWS = 9

function Build.abilities(pg)
  local d = data
  local dur = (d.work.duration or 180) / 60
  local hdr = CreateFrame("Frame", nil, pg)
  hdr:SetSize(W, 18)
  Put(hdr, pg, 0, 0)
  Put(Cap(hdr, "Ability"), hdr, 28, 3)
  local vsName = P():TargetText(d.res.target) == "My gear" and "vs gear" or "vs BiS"
  for _, c in ipairs(COLS) do
    local fs = Text(hdr, 8, C.dim, "RIGHT")
    fs:SetPoint("TOPRIGHT", hdr, "TOPLEFT", c[2], -3)
    fs:SetText((c[1] == "vs gear" and vsName or c[1]):upper())
  end
  local top = d.rows[1] and d.rows[1].dps or 1
  local shown = min(MAX_ROWS, #d.rows)
  for i = 1, shown do
    local r = d.rows[i]
    local y = 18 + (i - 1) * 27
    local row = CreateFrame("Frame", nil, pg)
    row:SetSize(W, 27)
    Put(row, pg, 0, y)
    local rule = Put(Tex(row, "BACKGROUND", { 0.133, 0.133, 0.153 }), row, 0, 0)
    rule:SetSize(W, 1)
    local ic = Put(IconTex(row, 19, r.icon), row, 2, 4)
    local nm = Put(Text(row, 11.5, C.text), row, 28, 5)
    nm:SetText(r.name)
    nm:SetWidth(210)
    local sh = Put(Tex(row, "ARTWORK", C.gold2, 0.8), row, 28, 20)
    sh:SetSize(max(1, r.dps / top * 140), 2)
    local landed = r.hits + r.crits + r.glances
    local swings = landed + r.misses + r.dodges
    local function pct(v) return swings > 0 and v > 0 and Pct(v / swings) or "\226\128\147" end
    local avgHit = (r.hits + r.glances) > 0 and (r.damage - r.critDamage) / (r.hits + r.glances) or 0
    local avgCrit = r.crits > 0 and r.critDamage / r.crits or 0
    local vals = {
      Fmt1(r.dps), Pct(r.dps / max(1, d.total)), abs(r.vs) < 0.05 and "\194\183" or Signed1(r.vs),
      ("%.1f"):format(r.casts), ("%.1f"):format(r.casts / dur), pct(r.crits), pct(r.misses), pct(r.dodges), pct(r.glances),
      avgHit > 0 and Fmt(avgHit) or "\226\128\147", avgCrit > 0 and Fmt(avgCrit) or "\226\128\147",
      r.maxHit > 0 and Fmt(r.maxHit) or "\226\128\147",
    }
    for j, c in ipairs(COLS) do
      local col = C.sub
      if j == 3 then col = abs(r.vs) < 0.05 and C.grey or (r.vs > 0 and C.green or C.red) end
      Num(row, c[2], 7, vals[j], 12, col)
    end
  end
  local ty = 18 + shown * 27
  local tot = CreateFrame("Frame", nil, pg)
  tot:SetSize(W, 22)
  Put(tot, pg, 0, ty)
  local rule = Put(Tex(tot, "BACKGROUND", { 0.227, 0.227, 0.259 }), tot, 0, 0)
  rule:SetSize(W, 1)
  Put(Text(tot, 11.5, C.gold), tot, 28, 5):SetText(#d.rows > shown and ("Total  |cff8f8f95(%d more below 0.1%%)|r"):format(#d.rows - shown) or "Total")
  Num(tot, COLS[1][2], 6, Fmt1(d.total), 12)
  Num(tot, COLS[2][2], 6, "100%", 12)
  local diff = d.res.diff
  Num(tot, COLS[3][2], 6, Signed1(diff), 12, abs(diff) < 2 * d.res.se and C.grey or (diff > 0 and C.green or C.red))

  -- the first 20 seconds of fight 1
  local box = Box(pg, 0, 296, W, 120, "The first 20 seconds of fight 1", "every cast in order  \194\183  gold edge = crit")
  local X0, XW = 64, 690
  local function sx(t) return X0 + t / 20 * XW end
  Label(box, 12, 33, "GCD", 9.5, C.axis)
  Label(box, 12, 61, "Free", 9.5, C.axis)
  local axis = Put(Tex(box, "ARTWORK", { 0.18, 0.18, 0.208 }), box, X0, 90)
  axis:SetSize(XW, 1)
  for t = 0, 20, 5 do
    local fs = Text(box, 10, C.axis, "CENTER", NUM)
    fs:SetPoint("TOP", box, "TOPLEFT", sx(t), -96)
    fs:SetText(("0:%02d"):format(t))
  end
  local tl = d.work.timeline and d.work.timeline.casts or {}
  local lastG, lastF = -99, -99
  for _, c in ipairs(tl) do
    if c.t <= 20 then
      local key = c.key
      if type(key) == "string" and key:match("^melee") then
        local tick = Put(Tex(box, "ARTWORK", { 0.604, 0.604, 0.635 }), box, sx(c.t), 85)
        tick:SetSize(1, 6)
      else
        local lane = c.gcd and 0 or 1
        local x = sx(c.t) - 11
        if lane == 0 then x = max(x, lastG + 24); lastG = x else x = max(x, lastF + 24); lastF = x end
        if x < X0 + XW - 10 then
          local ic = Put(IconTex(box, 22, KeyIcon(key, { spellId = c.spellId })), box, x, 28 + lane * 28)
          if c.crit then
            local ring = box:CreateTexture(nil, "OVERLAY")
            ring:SetColorTexture(1, 0.82, 0, 1)
            ring:SetPoint("TOPLEFT", ic, "TOPLEFT", -2, 2)
            ring:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", 2, -2)
            ring:SetDrawLayer("BORDER")
          end
        end
      end
    end
  end
  Label(box, X0, 66, #tl == 0 and "No casts recorded." or "", 9.5, C.axis)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Buffs & procs
-- ---------------------------------------------------------------------------------------------------------------
local function ItemName(itemId)
  local name = GetItemInfo and GetItemInfo(itemId)
  if (not name or name == "") and ns.ItemDB and ns.ItemDB.GetName then name = ns.ItemDB:GetName(itemId) end
  return (name ~= "") and name or nil
end

local function AuraName(r)
  local id = r.actionId
  local name
  if id and id.spellId and GetSpellInfo then name = GetSpellInfo(id.spellId) end
  if (not name or name == "") and id and id.itemId then name = ItemName(id.itemId) end
  -- an item's stat proc: "proc <item>:<buff>"
  local procItem = tonumber(tostring(r.label or ""):match("^proc (%d+):"))
  if (not name or name == "") and procItem then name = ItemName(procItem) end
  if not name or name == "" then
    name = tostring(r.label or "?"):gsub("%-?%d+:%-?%d+$", ""):gsub("^proc ", ""):gsub("(%l)(%u)", "%1 %2")
  end
  -- a hand or a copy number at the end ("Lightning Speed MH", "Seal of Command 1")
  name = name:gsub(" [MO]H$", ""):gsub(" %d+$", "")
  return name
end

-- auras the sim registers without an action id: their icon by name (spell id, or item: an item's own icon)
local NAMED = {
  ["Vengeance"] = 20059, ["Grace of Air"] = 25359, ["Strength of Earth"] = 25528, ["Seal of Blood"] = 31892,
  ["Seal of Command"] = 20375, ["Avenging Wrath"] = 31884, ["Haste Potion"] = "item:22838",
  ["Destruction Potion"] = "item:22839", ["Lightning Speed"] = 28093, ["Justice"] = "item:27484",
  ["Bloodlust"] = 2825, ["Heroism"] = 32182, ["Drums of Battle"] = 35476, ["Flurry"] = 12974, ["Rampage"] = 30033,
  ["Death Wish"] = 12292, ["Recklessness"] = 1719, ["Blade Flurry"] = 13877, ["Adrenaline Rush"] = 13750,
  ["Slice and Dice"] = 6774, ["Unleashed Rage"] = 30811, ["Shamanistic Focus"] = 43339, ["Elemental Mastery"] = 16166,
  ["Tiger's Fury"] = 9846, ["Shadowform"] = 15473, ["Arcane Power"] = 12042, ["Icy Veins"] = 12472,
  ["Combustion"] = 11129, ["Power Infusion"] = 10060, ["Innervate"] = 29166, ["Mana Tide"] = 16190,
  ["Flame Cap"] = "item:22788", ["Berserking"] = 26297, ["Blood Fury"] = 20572, ["Windfury Totem"] = 25587,
  ["Battle Shout"] = 2048, ["Enrage"] = 12880, ["Sanctity Aura"] = 20218, ["Crusader"] = 20034,
  ["Executioner"] = 42976, ["Mongoose"] = 28093, ["Berserking (weapon)"] = 59620,
}

local function NamedIcon(name)
  local v = name and NAMED[name]
  if type(v) == "number" then return SpellIcon(v) end
  if type(v) == "string" then return ItemIcon(tonumber(v:match("%d+"))) end
  if name and GetSpellTexture then
    local ok, tex = pcall(GetSpellTexture, name)
    if ok and tex then return tex end
  end
  return nil
end

-- the "can't have it again yet" markers say nothing about the gear
local MARKERS = { Sated = true, Exhaustion = true, Tinnitus = true, Forbearance = true, ["Weakened Soul"] = true }
local function Marker(r)
  return MARKERS[AuraName(r)] or MARKERS[tostring(r.label or "")] or false
end

local function AuraIcon(r)
  local id = r.actionId
  local tex
  if id and id.spellId then tex = SpellIcon(id.spellId) end
  if not tex and id and id.itemId then tex = ItemIcon(id.itemId) end
  local procItem = tonumber(tostring(r.label or ""):match("^proc (%d+):"))
  if not tex and procItem then tex = ItemIcon(procItem) end
  if not tex then tex = NamedIcon(AuraName(r)) end
  if not tex and data then
    -- an ability of the same name (a seal's aura and its damage)
    for _, row in ipairs(data.rows or {}) do if row.name == AuraName(r) then tex = row.icon end end
  end
  return tex or QUESTION
end

function Build.buffs(pg)
  local d = data
  local list = {}
  for key, a in pairs(d.work.auras or {}) do
    if a.uptime > 0.001 and not Marker(a) then list[#list + 1] = { key = key, a = a, name = AuraName(a), icon = AuraIcon(a) } end
  end
  table.sort(list, function(x, y) return x.a.uptime > y.a.uptime end)
  local L = Box(pg, 0, 0, 376, PH, "Uptime", "share of the fight")
  if #list == 0 then Label(L, 12, 34, "No procs or cooldowns in this fight.", 10.5, C.label) end
  for i = 1, min(12, #list) do
    local it = list[i]
    local y = 30 + (i - 1) * 29
    Put(IconTex(L, 20, it.icon), L, 10, y + 3)
    local nm = Label(L, 38, y + 1, it.name, 11, C.sub)
    nm:SetWidth(150)
    local g = it.a.gains
    local sub = g >= 1.95 and ("%.1f a fight"):format(g) or (g >= 0.95 and "once a fight" or ("%d%% of fights"):format(floor(g * 100 + 0.5)))
    Label(L, 38, y + 15, sub, 9, C.dim)
    Bar(L, 188, y + 9, 134, 7, it.a.uptime, C.gold2, it.a.uptime < 0.999)
    Num(L, 366, y + 4, Pct(it.a.uptime), 12.5)
  end

  -- fight 1: when each went up
  local T = Box(pg, 384, 0, 386, PH, "Cooldowns in fight 1", "0:00 \226\128\147 " .. Time(d.work.duration or 180))
  local dur = d.work.duration or 180
  local lanes, byKey = {}, {}
  for _, iv in ipairs(d.work.timeline and d.work.timeline.auras or {}) do
    local lane = byKey[iv.key]
    if not lane then
      local a = d.work.auras and d.work.auras[iv.key]
      if a and a.uptime < 0.97 and not Marker(a) then
        lane = { key = iv.key, a = a, segs = {} }
        byKey[iv.key] = lane
        lanes[#lanes + 1] = lane
      end
    end
    if lane then lane.segs[#lane.segs + 1] = iv end
  end
  table.sort(lanes, function(x, y) return x.a.uptime > y.a.uptime end)
  local X0, XW = 146, 226
  local function sx(t) return X0 + min(dur, max(0, t)) / dur * XW end
  local nl = min(8, #lanes)
  for s = 0, dur, dur >= 240 and 60 or 30 do
    local g = Put(Tex(T, "BACKGROUND", { 0.125, 0.125, 0.145 }, 1), T, sx(s), 34)
    g:SetSize(1, nl * 40 + 6)
    local fs = Text(T, 10, C.axis, "CENTER", NUM)
    fs:SetPoint("TOP", T, "TOPLEFT", sx(s), -(44 + nl * 40))
    fs:SetText(Time(s))
  end
  local palette = { { 1, 0.843, 0.353 }, { 0.373, 0.659, 1 }, { 0.788, 0.651, 0.251 }, { 0.878, 0.38, 0.31 },
    { 0.639, 0.208, 0.933 }, { 0.31, 0.83, 0.42 }, { 0.239, 0.42, 0.847 }, { 0.92, 0.6, 0.3 } }
  for i = 1, nl do
    local lane = lanes[i]
    local y = 40 + (i - 1) * 40
    Put(IconTex(T, 20, AuraIcon(lane.a)), T, 10, y)
    local nm = Label(T, 36, y + 4, AuraName(lane.a), 10, C.sub)
    nm:SetWidth(106)
    local tr = Put(Tex(T, "ARTWORK", { 0.122, 0.122, 0.141 }), T, X0, y + 7)
    tr:SetSize(XW, 6)
    local c = palette[i]
    for _, sg in ipairs(lane.segs) do
      local seg = Put(Tex(T, "ARTWORK", c, 0.9), T, sx(sg.from), y + 4)
      seg:SetDrawLayer("ARTWORK", 2)
      seg:SetSize(max(3, sx(sg.to) - sx(sg.from)), 12)
    end
  end
  if nl == 0 then Label(T, 12, 34, "Nothing came and went in fight 1.", 10.5, C.label) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Mana
-- ---------------------------------------------------------------------------------------------------------------
local MANA_NAMES = { regen = "Mana regeneration", potion = "Mana potion", demonic_rune = "Dark Rune",
  judgement_of_wisdom = "Judgement of Wisdom", sanctified_judgement = "Sanctified Judgement",
  spiritual_attunement = "Spiritual Attunement", shadowfiend = "Shadowfiend", vampiric_touch_own = "Vampiric Touch",
  shamanistic_rage = "Shamanistic Rage", mana_gem = "Mana gem", evocation = "Evocation" }
local function ManaName(k)
  if MANA_NAMES[k] then return MANA_NAMES[k] end
  local s = tostring(k):gsub("_", " ")
  return (s:gsub("^%l", string.upper))
end

function Build.mana(pg)
  local d = data
  local cv = d.work.manaCurve
  if not cv then
    local b = Box(pg, 0, 0, W, PH, "Mana")
    Para(b, 12, 34, 500, "This spec runs on rage or energy: there is no mana to show.")
    return
  end
  local dur = d.work.duration or 180
  local last = cv.mean[floor(dur / cv.step + 0.5)] or cv.mean[floor(dur / cv.step)] or 0
  local gain, spend = 0, 0
  for _, v in pairs(d.work.mana or {}) do gain = gain + v end
  for _, v in pairs(d.work.manaSpent or {}) do spend = spend + v end
  Kpis(pg, {
    { "Out of mana", Fmt(cv.outFights), "of " .. Fmt(cv.fights) .. " fights", cv.outFights == 0 and C.green or C.red },
    { "Lowest (average)", Fmt(cv.low) }, { "Mana in", Fmt(gain / dur * 5), "per 5 s" }, { "Mana out", Fmt(spend / dur * 5), "per 5 s" },
    { "Ends with", Fmt(last), ("%d%%"):format(floor(last / max(1, cv.max) * 100 + 0.5)) },
  })
  local b = Box(pg, 0, 60, 518, PH - 60, "Mana over the fight")
  local lg = Text(b, 10, C.label, "RIGHT")
  lg:SetPoint("TOPRIGHT", b, "TOPRIGHT", -10, -8)
  lg:SetText("|cff5f9bffaverage|r   |cff3d5f99middle 80% of fights|r")
  local GX, GY, GW, GH = 42, 34, 460, PH - 60 - 70
  local mx = max(1, cv.max)
  local function sx(t) return GX + t / dur * GW end
  local function sy(m) return GY + GH - max(0, min(mx, m)) / mx * GH end
  for m = 0, mx, mx > 6000 and 2000 or 1000 do
    local g = Put(Tex(b, "BACKGROUND", { 0.125, 0.125, 0.145 }), b, GX, sy(m))
    g:SetSize(GW, 1)
    local fs = Text(b, 10, C.axis, "RIGHT", NUM)
    fs:SetPoint("RIGHT", b, "TOPLEFT", GX - 6, -sy(m))
    fs:SetText(m == 0 and "0" or (("%gk"):format(m / 1000)))
  end
  for t = 0, dur, dur >= 240 and 60 or 30 do
    local fs = Text(b, 10, C.axis, "CENTER", NUM)
    fs:SetPoint("TOP", b, "TOPLEFT", sx(t), -(GY + GH + 4))
    fs:SetText(Time(t))
  end
  local lx, ly
  local nb = floor(dur / cv.step)
  for k = 0, nb do
    local m = cv.mean[k]
    if m then
      local x, y = sx(k * cv.step), sy(m)
      local band = (cv.sd[k] or 0) * 1.28
      if lx then
        local col = b:CreateTexture(nil, "BACKGROUND", nil, 2)
        col:SetColorTexture(0.239, 0.482, 1, 0.16)
        local top, bot = sy(m + band), sy(m - band)
        Put(col, b, lx, top)
        col:SetSize(x - lx + 0.3, max(1, bot - top))
        LineAt(Line(b, "OVERLAY", C.blue, 1.8), b, lx, ly, x, y)
      end
      lx, ly = x, y
    end
  end

  local r = Box(pg, 526, 60, 244, PH - 60, "Where it comes from")
  local function rows(map, y0, col, names)
    local list, total = {}, 0
    for k, v in pairs(map or {}) do if v > 0 then list[#list + 1] = { k = k, v = v }; total = total + v end end
    table.sort(list, function(a, b2) return a.v > b2.v end)
    for i = 1, min(5, #list) do
      local y = y0 + (i - 1) * 22
      local nm = Label(r, 10, y, names(list[i].k), 10.5, C.sub)
      nm:SetWidth(118)
      Bar(r, 132, y + 5, 64, 6, list[i].v / total, col)
      Num(r, 234, y - 1, ("%d%%"):format(floor(list[i].v / total * 100 + 0.5)), 12)
    end
    return #list
  end
  rows(d.work.mana, 32, C.blue, ManaName)
  Put(Cap(r, "Where it goes"), r, 10, 156)
  rows(d.work.manaSpent, 178, { 0.541, 0.541, 0.573 }, KeyName)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Stats & weights
-- ---------------------------------------------------------------------------------------------------------------
local CASTERS = { Elemental = true, Shadow = true, Balance = true, Arcane = true, Fire = true, Frost = true }
local WEIGHTS = {
  melee = { { "Hit rating", "MeleeHitRating", 25 }, { "Expertise rating", "ExpertiseRating", 25 },
    { "Strength", "Strength", 50 }, { "Crit rating", "MeleeCritRating", 50 }, { "Haste rating", "MeleeHasteRating", 50 },
    { "Agility", "Agility", 50 }, { "Attack power", "AttackPower", 100 }, { "Armor penetration", "ArmorPenetration", 200 },
    { "Spell power", "SpellDamage", 100 } },
  caster = { { "Spell hit rating", "SpellHitRating", 25 }, { "Spell power", "SpellDamage", 100 },
    { "Spell crit rating", "SpellCritRating", 50 }, { "Spell haste rating", "SpellHasteRating", 50 },
    { "Intellect", "Intellect", 50 }, { "Spirit", "Spirit", 50 } },
}
local weights = { running = false }

local function WeightKind() return CASTERS[R():Spec()] and "caster" or "melee" end

-- Stat weights: the Working set once as it is and once per stat with a little more of it, on the same rolls.
function Nerd:CalcWeights()
  if weights.running then R():Cancel() return end
  local Sim = P()
  local kind = WeightKind()
  local fights = min(1000, Sim.Settings().fights)
  local jobs = { { key = "base", set = Sim:Working() } }
  for _, w in ipairs(WEIGHTS[kind]) do jobs[#jobs + 1] = { key = w[2], set = Sim:Working(), bonus = { [w[2]] = w[3] } } end
  weights.running, weights.progress = true, 0
  local serial = Sim._state().serial
  local ok, err = R():Start(jobs, {
    iterations = fights, settings = Sim:RunSettings(),
    onProgress = function(done, total) weights.progress = done / max(1, total); Nerd:RefreshWeights() end,
    onCancel = function() weights.running = false; Nerd:RefreshWeights() end,
    onDone = function(res, e)
      weights.running = false
      if res then
        local out = { kind = kind, serial = serial, fights = fights, list = {} }
        local norm
        for _, w in ipairs(WEIGHTS[kind]) do
          local dd, se = res.diff(w[2], "base")
          local per = (dd or 0) / w[3]
          out.list[#out.list + 1] = { name = w[1], stat = w[2], per = per, se = (se or 0) / w[3] }
          if (kind == "melee" and w[2] == "AttackPower") or (kind == "caster" and w[2] == "SpellDamage") then norm = per end
        end
        out.norm = (norm and norm > 0) and norm or nil
        weights.result = out
      else
        ns:Print("The stat weights stopped: %s", tostring(e))
      end
      Nerd:RefreshWeights(true)
    end,
  })
  if not ok then weights.running = false; ns:Print("Stat weights can't run: %s", tostring(err)) end
  self:RefreshWeights()
end

function Nerd:RefreshWeights(rebuild)
  local pg = pages and pages.stats
  if not pg then return end
  if rebuild or not pg.weightsBtn then pg.dirty = true; if current == "stats" and self:IsOpen() then self:Show("stats") end return end
  pg.weightsBtn:SetText(weights.running and "Stop" or (weights.result and "Recalculate" or "Calculate"))
  if weights.running then
    pg.weightsNote:SetText(("Simming...  %d%%"):format(floor((weights.progress or 0) * 100)))
  end
end

function Build.stats(pg)
  local d = data
  local ST = ns.GearSim and ns.GearSim.ST or {}
  local st = d.work.stats or {}
  local caster = WeightKind() == "caster"
  local L = Box(pg, 0, 0, 376, PH, "In combat, with buffs", "before procs and cooldowns")
  local rows
  local talents, own = R():Talents()
  local function v(k) return st[ST[k]] or 0 end
  if caster then
    rows = { { "Intellect", Fmt(v("Intellect")) }, { "Spirit", Fmt(v("Spirit")) }, { "Spell power", Fmt(v("SpellDamage")) },
      { "Spell crit", ("%.1f%%"):format(v("SpellCritPercent")) }, { "Spell hit", ("%.1f%%  |cff7d7d85(cap 16%%)|r"):format(v("SpellHitPercent")) },
      { "Spell haste rating", Fmt(v("SpellHasteRating")) }, { "Mana", Fmt(v("Mana")) }, { "MP5", Fmt(v("MP5")) } }
  else
    local exp = floor(v("ExpertiseRating") / (ns.GearSim and ns.GearSim.EXPERTISE_PER_QUARTER or 3.94))
    rows = { { "Strength", Fmt(v("Strength")) }, { "Agility", Fmt(v("Agility")) }, { "Attack power", Fmt(v("AttackPower")) },
      { "Melee crit", ("%.1f%%"):format(v("PhysicalCritPercent")) }, { "Melee hit", ("%.1f%%  |cff7d7d85(cap 9%%)|r"):format(v("PhysicalHitPercent")) },
      { "Expertise", ("%d  |cff7d7d85(\226\136\146%.2f%% dodge)|r"):format(exp, exp * 0.25) },
      { "Melee haste rating", Fmt(v("MeleeHasteRating")) }, { "Armor penetration", Fmt(v("ArmorPenetration")) } }
    if v("Mana") > 0 then rows[#rows + 1] = { "Spell power", Fmt(v("SpellDamage")) }; rows[#rows + 1] = { "Mana", Fmt(v("Mana")) } end
  end
  rows[#rows + 1] = { "Stamina", Fmt(v("Stamina")) }
  rows[#rows + 1] = { "Race", R():Race() }
  rows[#rows + 1] = { "Talents", own and "yours" or "the standard build" }
  for i, r in ipairs(rows) do
    local y = 30 + (i - 1) * 21
    local rule = Put(Tex(L, "ARTWORK", { 0.125, 0.125, 0.145 }), L, 12, y + 20)
    rule:SetSize(352, 1)
    Label(L, 12, y + 4, r[1], 11, C.dim)
    local fs = Text(L, 12.5, C.text, "RIGHT", NUM)
    fs:SetPoint("TOPRIGHT", L, "TOPLEFT", 364, -(y + 3))
    fs:SetText(r[2])
  end

  local Rb = Box(pg, 384, 0, 386, PH, "Stat weights", caster and "per point  \194\183  spell power = 1.00" or "per point  \194\183  attack power = 1.00")
  local res = weights.result
  if res and res.kind == WeightKind() then
    local norm = res.norm or 1
    local top = 0.01
    for _, w in ipairs(res.list) do top = max(top, w.per / norm) end
    for i, w in ipairs(res.list) do
      local y = 34 + (i - 1) * 30
      Label(Rb, 12, y, w.name, 11, C.sub)
      local note = ("%s DPS per 10"):format(("%.1f"):format(w.per * 10))
      if w.stat:match("HitRating") then note = note .. "  \194\183  until the cap" end
      Label(Rb, 12, y + 14, note, 9, C.dim)
      Bar(Rb, 150, y + 5, 170, 8, (w.per / norm) / top, C.gold2, true)
      Num(Rb, 374, y + 1, ("%.2f"):format(w.per / norm), 13)
    end
    local stale = res.serial ~= P()._state().serial
    Para(Rb, 12, 34 + #res.list * 30 + 6, 362, ("Each weight is its own pair of sims on the same rolls (%s fights)%s.")
      :format(Fmt(res.fights), stale and ", from before the last run" or ""))
  else
    Para(Rb, 12, 34, 362, "How much DPS one more point of each stat is worth for this Working set, as WoWSims counts it: "
      .. "the set simmed once as it is and once per stat with a little more of it, on the same rolls.")
  end
  local n = #WEIGHTS[WeightKind()]
  pg.weightsBtn = ns.UI:CreateSleekButton(Rb, weights.running and "Stop" or (res and "Recalculate" or "Calculate"), 110, 22,
    function() Nerd:CalcWeights() end, "primary")
  Put(pg.weightsBtn, Rb, 12, PH - 44)
  pg.weightsNote = Label(Rb, 132, PH - 40, "", 10, C.dim)
  local est = P():EstimateText(min(1000, P().Settings().fights) * (n + 1) / 2)
  pg.weightsNote:SetText(weights.running and "Simming..." or (("%d extra sims%s"):format(n + 1, est and ("  \194\183  " .. est) or "")))
end

-- ---------------------------------------------------------------------------------------------------------------
-- The run
-- ---------------------------------------------------------------------------------------------------------------
function Build.run(pg)
  local d = data
  local info = d.res.info or {}
  local set = info.settings or P():RunSettings()
  local L = Box(pg, 0, 0, 376, PH, "This run")
  local talents, own = R():Talents()
  local cached = {}
  for k in pairs(info.cached or {}) do
    local name = k == "work" and "Working set" or P():TargetText(d.res.target)
    if info.stored and info.stored[k] then name = name .. " (saved)" end
    cached[#cached + 1] = name
  end
  local simmed = info.simmed or (d.n * 2)
  local rows = {
    { "Fights", ("%s \195\151 2 sets"):format(Fmt(d.n)) },
    { "Same rolls for both sets", ("yes  \194\183  seed %d"):format(set.seed or R():SessionSeed()) },
    { "Time taken", info.ms and ("%.1f s"):format(info.ms / 1000) or "\226\128\147" },
    { "Per fight", (info.ms and simmed > 0) and ("%.1f ms"):format(info.ms / simmed) or "\226\128\147" },
    { "Frames used", info.frames and ("%s  \194\183  %d ms each"):format(Fmt(info.frames), R().FRAME_BUDGET_MS) or "\226\128\147" },
    { "Paused for combat", info.pausedEver and "yes" or "no" },
    { "Reused from earlier runs", #cached > 0 and table.concat(cached, ", ") or "nothing" },
    { "Engine", "WoWSims TBC, ported  \194\183  " .. tostring(ns.version or "") },
    { "Rotation", "WoWSims' " .. R():Spec() .. " rotation" },
    { "Talents", own and "yours" or "the standard build" },
    { "Talent string", tostring(talents or "") },
    { "Target", "Lv 73  \194\183  " .. tostring(set.mobType or "Mechanical") },
    { "Fight length", Time(set.duration or 180) .. "  \194\183  1 target" },
  }
  for i, r in ipairs(rows) do
    local y = 30 + (i - 1) * 21
    local rule = Put(Tex(L, "ARTWORK", { 0.125, 0.125, 0.145 }), L, 12, y + 20)
    rule:SetSize(352, 1)
    Label(L, 12, y + 4, r[1], 11, C.dim)
    local fs = Text(L, 11.5, C.text, "RIGHT", NUM)
    fs:SetPoint("TOPRIGHT", L, "TOPLEFT", 364, -(y + 3))
    fs:SetText(r[2])
  end

  local Rb = Box(pg, 384, 0, 386, PH, "Fights worth a look")
  local function rank(v)
    local below = 0
    for _, x in ipairs(d.list) do if x < v then below = below + 1 end end
    return below
  end
  local picks = {
    { "Best fight", d.bi, d.best, ("better than the other %s"):format(Fmt(d.n - 1)) },
    { "Worst fight", d.wi, d.worst, ("%s below the average"):format(Fmt(d.work.dps - d.worst)) },
    { "Most typical", d.ti, d.list[d.ti] or d.work.dps, ("closest to the average  \194\183  %d%% did better"):format(
      floor((d.n - 1 - rank(d.list[d.ti] or 0)) / max(1, d.n) * 100 + 0.5)) },
  }
  for i, p in ipairs(picks) do
    local y = 32 + (i - 1) * 64
    local card = CreateFrame("Frame", nil, Rb)
    card:SetSize(362, 56)
    Put(card, Rb, 12, y)
    Tex(card, "BACKGROUND", { 0.114, 0.114, 0.133 }):SetAllPoints()
    Label(card, 12, 9, ("%s  |cff7d7d85#%d|r"):format(p[1], p[2]), 12, C.text)
    Label(card, 12, 29, p[4], 10, C.label)
    Num(card, 350, 10, Fmt(p[3]), 18, C.text)
  end
  Para(Rb, 12, 236, 362, "Fight 1 is the one the Abilities and Buffs pages draw cast by cast. More fights pin the average "
    .. "down closer; sets you simmed before are kept (those of your last 10 runs between sessions too), so a rerun of the "
    .. "same gear is free.")
  local b1 = ns.UI:CreateSleekButton(Rb, "Export to WoWSims", 140, 22, function()
    local Sim = P()
    Sim:ShowExport("Working set", R():WoWSimsSettings(Sim:Working(), Sim:RunSettings()))
  end, "secondary")
  Put(b1, Rb, 12, 300)
  local precise = P().FIGHTS[#P().FIGHTS].n
  local b2 = ns.UI:CreateSleekButton(Rb, ("Run %s fights"):format(Fmt(precise)), 124, 22, function()
    P().SetFightsAndRun(precise)
  end, "secondary")
  b2:SetPoint("LEFT", b1, "RIGHT", 8, 0)
end

-- (tests) the shown page and the prepared numbers
function Nerd._page() return current, pages and pages[current] end
function Nerd._data() Prepare() return data end
function Nerd._weights() return weights end
