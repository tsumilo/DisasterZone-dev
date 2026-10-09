if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SimPanel.lua", ...) then return end -- DisasterZone: UI/SimPanel.lua
-- ns.SimPanel: My BiS in Sim mode (the Sim button in the top bar). The slots show a Working set (a copy of the gear
-- you wear to start with) that you change slot by slot; the centre runs the gear sim (Sim/*.lua, ns.SimRunner) for it
-- against My gear or a My BiS phase, on the same random rolls, and shows the difference, the damage by ability and
-- the key stats. A slot click opens My BiS's item picker (UI/Picker.lua) for the Working set: your gear and bags on
-- top, then every source, and "Best for this slot" sims what it lists. Runs only when asked (the Run sim button).
local _, ns = ...

local SimPanel = {}
ns.SimPanel = SimPanel

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local GOLD = { 0.89, 0.70, 0.24 }
local GREEN = { 0.31, 0.83, 0.42 }
local RED = { 0.88, 0.38, 0.31 }
local GREY = { 0.56, 0.56, 0.59 }
local CARD_BG = { 0.085, 0.085, 0.1, 0.96 }
local EDGE = { 0.34, 0.34, 0.38, 0.5 }
local BAR_BG = { 0.15, 0.15, 0.17, 1 }
local BAR_FG = { 0.79, 0.65, 0.25, 1 }
local MAX_ABILITIES = 6
SimPanel.PICK_ITERATIONS = 300
SimPanel.MAX_PICK_RUN = 30

local state = {
  active = false,
  working = nil,       -- gear set (ns.SimRunner sets)
  target = "gear",     -- what the Working set is compared to: "gear" | phase number (My BiS)
  results = nil,       -- the last run: { work = summary, ref = summary, diff, se, at }
  stale = true,
  running = false,
}
local card

-- ---------------------------------------------------------------------------------------------------------------
-- Saved state (per character)
-- ---------------------------------------------------------------------------------------------------------------
local function CharKey()
  local key = ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() or (UnitName("player") or "me")
  return (tostring(key):gsub("%.", "_"))
end

-- Nothing is written until the player changes something (create = true): opening the page saves nothing.
local EMPTY = {}
local function Saved(create)
  local DB = ns.DB
  if not DB then return {} end
  local path = "sim.chars." .. CharKey()
  local t = DB:GetSetting(path)
  if type(t) ~= "table" then
    if not create then return EMPTY end
    DB:SetSetting(path, {})
    t = DB:GetSetting(path) or {}
  end
  return t
end

local DEFAULTS = { buffs = "raid25", duration = 180, mobType = "Mechanical" }
local function Settings()
  local s = Saved()
  return { buffs = s.buffs or DEFAULTS.buffs, duration = s.duration or DEFAULTS.duration,
    mobType = s.mobType or DEFAULTS.mobType }
end
local function SetSetting(key, v) Saved(true)[key] = v end

local function SaveWorking()
  Saved(true).working = state.working
end

local R = function() return ns.SimRunner end

-- ---------------------------------------------------------------------------------------------------------------
-- Sets
-- ---------------------------------------------------------------------------------------------------------------
local function Phase() return (ns.MyBiS and ns.MyBiS:GetPhase()) or 1 end
local function List() return (ns.MyBiS and ns.MyBiS.GetList and ns.MyBiS:GetList() == "os") and "os" or nil end

function SimPanel:Working()
  if not state.working then
    local saved = Saved().working
    state.working = (type(saved) == "table" and next(saved)) and saved or R():EquippedSet()
  end
  return state.working
end

function SimPanel:TargetSet()
  if state.target == "gear" then return R():EquippedSet() end
  return R():BiSSet(tonumber(state.target) or Phase(), List())
end

function SimPanel:TargetText(t)
  t = t or state.target
  if t == "gear" then return "My gear" end
  return "My BiS " .. (ns.PhaseLabel and ns.PhaseLabel(tonumber(t)) or ("P" .. tostring(t)))
end

function SimPanel:SetWorkingSlot(sid, entry)
  local w = self:Working()
  w[sid] = entry
  -- a two-hander empties the off hand
  if sid == 15 and entry and ns.ItemDB and ns.ItemDB.GetEquipLoc and ns.ItemDB:GetEquipLoc(entry.id) == "INVTYPE_2HWEAPON" then
    w[16] = nil
  end
  SaveWorking()
  state.stale = true
  if ns.MyBiS then ns.MyBiS:Refresh() end
end

function SimPanel:ResetTo(set)
  state.working = R():CopySet(set)
  SaveWorking()
  state.stale = true
  if ns.MyBiS then ns.MyBiS:Refresh() end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Mode
-- ---------------------------------------------------------------------------------------------------------------
function SimPanel:IsActive() return state.active end

function SimPanel:SetActive(on)
  state.active = on and true or false
  if not on then
    if R() then R():Cancel() end
    state.running = false
    SimPanel:ClosePicker()
  end
  if ns.MyBiS then ns.MyBiS:Refresh() end
end

function SimPanel:Toggle() self:SetActive(not state.active) end

-- The paper doll's record and context while in Sim mode: the Working set with its gems, changes against the target.
function SimPanel:Record()
  local w = self:Working()
  local ph, ge = {}, {}
  for sid, e in pairs(w) do
    if e and e.id then
      ph[sid] = { e.id }
      local g = e.gems or {}
      ge[e.id] = ("%d:%d:%d:%d:%d"):format(e.enchant or 0, g[1] or 0, g[2] or 0, g[3] or 0, g[4] or 0)
    end
  end
  local eq = {}
  for sid, e in pairs(R():EquippedSet()) do eq[sid] = e.id end
  local data = ns.BiS and ns.BiS:GetData() or {}
  return { data = { v = data.v, cl = data.cl, sp = data.sp, ph = { [Phase()] = ph }, ge = ge, eq = eq } }
end

function SimPanel:Changed()
  local w, t = self:Working(), self:TargetSet()
  local out = {}
  for sid = 1, 17 do
    if not R():SameEntry(w[sid], t[sid]) then out[sid] = true end
  end
  return out
end

function SimPanel:Ctx(sourceFn)
  local changed = self:Changed()
  self.changed = changed
  return {
    showEquipped = true,
    gems = true,
    isDisabled = function() return false end,
    source = function(itemID, sid, fs, width)
      if not changed[sid] then return sourceFn and sourceFn(itemID, sid, fs, width) or nil end
      local prefix = "Changed  ·  "
      local room = width
      if fs and width then
        fs:SetText(prefix)
        room = width - (fs:GetStringWidth() or 0)
      end
      local text = sourceFn and sourceFn(itemID, sid, fs, room) or nil
      if text and fs and room then
        fs:SetText(text)
        local tw = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
        if (tonumber(tw) or 0) > room then text = nil end   -- too long even short: "Changed" alone
      end
      return ns.UI:Colorize("Changed", GOLD) .. (text and ("  ·  " .. text) or "")
    end,
  }
end

-- Gold edges on the changed slots (after the doll painted).
function SimPanel:MarkDoll(doll)
  local changed = self.changed or {}
  for sid, tile in pairs(doll.tiles or {}) do
    if not tile.simMark then
      tile.simMark = tile:CreateTexture(nil, "OVERLAY")
      tile.simMark:SetWidth(3)
      tile.simMark:SetPoint("TOP", tile, "TOP", 0, 0)
      tile.simMark:SetPoint("BOTTOM", tile, "BOTTOM", 0, 0)
      if tile.side == "R" then tile.simMark:SetPoint("RIGHT", tile, "RIGHT", 0, 0)
      else tile.simMark:SetPoint("LEFT", tile, "LEFT", 0, 0) end
      tile.simMark:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    end
    tile.simMark:SetShown(state.active and changed[sid] and true or false)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Runs
-- ---------------------------------------------------------------------------------------------------------------
local function RunSettings()
  local s = Settings()
  return { buffs = s.buffs, duration = s.duration, mobType = s.mobType, talents = (R():Talents()) }
end

function SimPanel:Run()
  if state.running then
    R():Cancel()
    state.running = false
    self:UpdateCard()
    return
  end
  if not R():IsSupported() then return end
  state.running = true
  state.progress = 0
  local ok, err = R():Start({ { key = "work", set = self:Working() }, { key = "ref", set = self:TargetSet() } }, {
    settings = RunSettings(),
    onProgress = function(done, total, paused)
      state.progress, state.paused = done / max(1, total), paused
      self:UpdateProgress()
    end,
    onCancel = function()
      state.running = false
      self:UpdateCard()
    end,
    onDone = function(res, e)
      state.running = false
      if not res then
        ns:Print("The gear sim stopped: %s", tostring(e))
      else
        local d, se = res.diff("work", "ref")
        state.results = { work = res.work, ref = res.ref, diff = d, se = se, target = state.target }
        state.stale = false
      end
      self:UpdateCard()
    end,
  })
  if not ok then
    state.running = false
    ns:Print("The gear sim can't run: %s", tostring(err))
  end
  self:UpdateCard()
end

-- ---------------------------------------------------------------------------------------------------------------
-- The centre card
-- ---------------------------------------------------------------------------------------------------------------
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

local function Fmt(v)
  v = floor(v + 0.5)
  local s = tostring(abs(v))
  while true do
    local n
    s, n = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
    if n == 0 then break end
  end
  return s
end
SimPanel.Fmt = Fmt

local function Signed(v)
  if v >= 0.5 then return "+" .. Fmt(v) elseif v <= -0.5 then return "\226\136\146" .. Fmt(v) end
  return "0"
end

function SimPanel:CreateCard(parent, w, h)
  local UI = ns.UI
  local c = CreateFrame("Frame", nil, parent)
  c:SetAllPoints(parent)
  c:Hide()
  card = c
  local bg = c:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(CARD_BG[1], CARD_BG[2], CARD_BG[3], CARD_BG[4])
  local PADX = 13

  c.cap = Text(c, 9, GREY)
  c.cap:SetPoint("TOPLEFT", c, "TOPLEFT", PADX, -11)
  c.cap:SetText("WORKING SET")

  c.big = Text(c, 30, { 0.94, 0.94, 0.94 })
  c.big:SetPoint("TOPLEFT", c.cap, "BOTTOMLEFT", -1, -4)
  c.unit = Text(c, 12, GREY)
  c.unit:SetPoint("BOTTOMLEFT", c.big, "BOTTOMRIGHT", 4, 3)
  c.unit:SetText("DPS")

  c.vs = Text(c, 11, { 0.66, 0.66, 0.66 })
  c.vs:SetPoint("TOPLEFT", c.big, "BOTTOMLEFT", 1, -12)
  c.vs:SetText("vs")
  c.target = UI:CreateSleekDropdown(c, 92, function()
    local opts = { { value = "gear", text = "My gear" } }
    for p = 0, (ns.MAX_PHASE or 5) do
      opts[#opts + 1] = { value = tostring(p), text = SimPanel:TargetText(p) }
    end
    return opts
  end, function() return tostring(state.target) end, function(v)
    state.target = (v == "gear") and "gear" or tonumber(v)
    state.stale = true
    if ns.MyBiS then ns.MyBiS:Refresh() end
  end)
  c.target:SetHeight(20)
  c.target:SetPoint("LEFT", c.vs, "RIGHT", 5, 0)
  c.refValue = Text(c, 11, { 0.66, 0.66, 0.66 })
  c.refValue:SetPoint("LEFT", c.target, "RIGHT", 6, 0)

  c.delta = Text(c, 16, GREY)
  c.delta:SetPoint("TOPLEFT", c.vs, "BOTTOMLEFT", 0, -13)
  c.sure = Text(c, 9, GREY)
  c.sure:SetPoint("BOTTOMLEFT", c.delta, "BOTTOMRIGHT", 6, 1)
  c.sure:SetPoint("RIGHT", c, "RIGHT", -PADX, 0)
  c.sureHit = CreateFrame("Frame", nil, c)
  c.sureHit:SetAllPoints(c.sure)
  c.sureHit:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("How sure", 1, 0.82, 0)
    GameTooltip:AddLine("The real difference is within this range of the number shown, 19 times out of 20. "
      .. "\"within\" means the two sets are too close to call: run more fights or call it a tie.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  c.sureHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

  c.run = UI:CreateSleekButton(c, "Run sim", w - 2 * PADX, 28, function() SimPanel:Run() end, "primary")
  c.run:SetPoint("TOPLEFT", c, "TOPLEFT", PADX, -116)
  c.run:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Run sim", 1, 0.82, 0)
    GameTooltip:AddLine(("Simulates %s fights of each set with the same random rolls. Paused while you are in "
      .. "combat."):format(Fmt(R().DEFAULT_ITERATIONS)), 1, 1, 1, true)
    GameTooltip:Show()
  end)
  c.run:HookScript("OnLeave", function() GameTooltip:Hide() end)

  c.progress = c:CreateTexture(nil, "OVERLAY")
  c.progress:SetPoint("TOPLEFT", c.run, "BOTTOMLEFT", 0, -2)
  c.progress:SetHeight(2)
  c.progress:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
  c.sub = Text(c, 9, GREY, "CENTER")
  c.sub:SetPoint("TOP", c.run, "BOTTOM", 0, -7)
  c.sub:SetWidth(w - 2 * PADX)

  c.sect1 = Text(c, 9, GREY)
  c.sect1:SetPoint("TOPLEFT", c, "TOPLEFT", PADX, -170)
  c.sect1:SetText("WHERE THE DAMAGE COMES FROM")
  c.rows = {}
  for i = 1, MAX_ABILITIES do
    local r = CreateFrame("Frame", nil, c)
    r:SetSize(w - 2 * PADX, 21)
    r:SetPoint("TOPLEFT", c.sect1, "BOTTOMLEFT", 0, -5 - (i - 1) * 22)
    r.name = Text(r, 11, { 0.85, 0.85, 0.85 })
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    r.delta = Text(r, 10, GREY, "RIGHT")
    r.delta:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, -1)
    r.delta:SetWidth(30)
    r.value = Text(r, 11, { 0.9, 0.9, 0.9 }, "RIGHT")
    r.value:SetPoint("TOPRIGHT", r, "TOPRIGHT", -32, 0)
    r.value:SetWidth(44)
    r.name:SetPoint("RIGHT", r.value, "LEFT", -4, 0)
    r.track = r:CreateTexture(nil, "ARTWORK")
    r.track:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 2)
    r.track:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 2)
    r.track:SetHeight(2)
    r.track:SetColorTexture(BAR_BG[1], BAR_BG[2], BAR_BG[3], BAR_BG[4])
    r.bar = r:CreateTexture(nil, "OVERLAY")
    r.bar:SetPoint("BOTTOMLEFT", r.track, "BOTTOMLEFT", 0, 0)
    r.bar:SetHeight(2)
    r.bar:SetColorTexture(BAR_FG[1], BAR_FG[2], BAR_FG[3], BAR_FG[4])
    c.rows[i] = r
  end

  c.sect2 = Text(c, 9, GREY)
  c.sect2:SetPoint("TOPLEFT", c, "TOPLEFT", PADX, -318)
  c.sect2:SetText("STATS")
  c.stats = {}
  for i = 1, 4 do
    local fs = Text(c, 10, { 0.8, 0.8, 0.8 })
    local col, row = (i - 1) % 2, floor((i - 1) / 2)
    local leftW = floor((w - 2 * PADX) * 0.44)
    fs:SetPoint("TOPLEFT", c.sect2, "BOTTOMLEFT", col * leftW, -5 - row * 15)
    fs:SetWidth(col == 0 and leftW - 4 or (w - 2 * PADX) - leftW)
    c.stats[i] = fs
  end

  c.note = Text(c, 10, GREY, "CENTER")
  c.note:SetPoint("TOPLEFT", c, "TOPLEFT", PADX, -176)
  c.note:SetPoint("TOPRIGHT", c, "TOPRIGHT", -PADX, -176)
  c.note:SetWordWrap(true)

  -- settings: buffs, fight length, boss type
  local function dd(width, options, get, set, tipFn)
    local b = UI:CreateSleekDropdown(c, width, options, get, function(v)
      set(v)
      state.stale = true
      SimPanel:UpdateCard()
    end)
    b:SetHeight(20)
    if tipFn then
      b:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        tipFn(GameTooltip)
        GameTooltip:Show()
      end)
      b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return b
  end
  local inner = w - 2 * PADX
  local half = floor((inner - 4) / 2)
  c.buffs = dd(half, function()
    local o = {}
    for _, b in ipairs(R().BUFFS) do o[#o + 1] = { value = b.key, text = b.text } end
    return o
  end, function() return Settings().buffs end, function(v) SetSetting("buffs", v) end, function(tt)
    for _, b in ipairs(R().BUFFS) do
      if b.key == Settings().buffs then
        tt:AddLine(b.text, 1, 0.82, 0)
        tt:AddLine(b.tip, 1, 1, 1, true)
      end
    end
  end)
  c.buffs:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", PADX, 34)
  c.duration = dd(inner - half - 4, function()
    local o = {}
    for _, d in ipairs(R().DURATIONS) do o[#o + 1] = { value = d, text = ("%d:%02d"):format(floor(d / 60), d % 60) } end
    return o
  end, function() return Settings().duration end, function(v) SetSetting("duration", v) end, function(tt)
    tt:AddLine("Fight length", 1, 0.82, 0)
    tt:AddLine("Longer fights spread cooldowns, drums and potions thinner over the fight.", 1, 1, 1, true)
  end)
  c.duration:SetPoint("LEFT", c.buffs, "RIGHT", 4, 0)
  c.mob = dd(half, function()
    local o = {}
    for _, m in ipairs(R().MOB_TYPES) do o[#o + 1] = { value = m.key, text = m.text } end
    return o
  end, function() return Settings().mobType end, function(v) SetSetting("mobType", v) end, function(tt)
    for _, m in ipairs(R().MOB_TYPES) do
      if m.key == Settings().mobType then
        tt:AddLine("Boss type: " .. m.text, 1, 0.82, 0)
        tt:AddLine(m.tip, 1, 1, 1, true)
      end
    end
  end)
  c.mob:SetPoint("TOPLEFT", c.buffs, "BOTTOMLEFT", 0, -4)
  return c
end

function SimPanel:ShowCard(on)
  if card then card:SetShown(on and true or false) end
  if on then self:UpdateCard() end
end

function SimPanel:UpdateProgress()
  if not card then return end
  local w = card.run:GetWidth() or 200
  if state.running then
    card.progress:Show()
    card.progress:SetWidth(max(1, w * (state.progress or 0)))
    card.sub:SetText(state.paused and "Paused while you are in combat"
      or ("Simming...  %d%%"):format(floor((state.progress or 0) * 100)))
  else
    card.progress:Hide()
  end
end

function SimPanel:UpdateCard()
  local c = card
  if not c or not c:IsShown() then return end
  local supported = R():IsSupported()
  local res = state.results
  c.run:SetText(state.running and "Cancel" or "Run sim")
  if c.run.SetKind then c.run:SetKind(state.running and "secondary" or "primary") end
  c.run:SetEnabled(supported and true or false)
  c.target:Refresh()
  c.buffs:Refresh(); c.duration:Refresh(); c.mob:Refresh()

  local function showRows(on)
    c.sect1:SetShown(on); c.sect2:SetShown(on)
    for _, r in ipairs(c.rows) do r:SetShown(on) end
    for _, s in ipairs(c.stats) do s:SetShown(on) end
  end
  if not supported then
    c.big:SetText("\226\128\148"); c.delta:SetText(""); c.sure:SetText(""); c.refValue:SetText("")
    showRows(false)
    c.note:Show()
    c.note:SetText("The gear sim covers Retribution for now. Switch the list to Retribution to sim it.")
    c.sub:SetText("")
    self:UpdateProgress()
    return
  end
  if not res then
    c.big:SetText("\226\128\148"); c.delta:SetText(""); c.sure:SetText(""); c.refValue:SetText("")
    showRows(false)
    c.note:Show()
    c.note:SetText(("Change slots on the left and right, then Run sim: it compares your Working set with %s.")
      :format(self:TargetText()))
    c.sub:SetText(("%s fights  ·  same rolls for both sets"):format(Fmt(R().DEFAULT_ITERATIONS)))
    self:UpdateProgress()
    return
  end
  c.note:Hide()
  showRows(true)
  local stale = state.stale and not state.running
  local fade = stale and 0.45 or 1
  c.big:SetText(Fmt(res.work.dps))
  c.big:SetAlpha(fade)
  c.refValue:SetText(Fmt(res.ref.dps))
  local d, se = res.diff, res.se
  local color = (abs(d) < 2 * se) and GREY or (d > 0 and GREEN or RED)
  local pct = d / res.ref.dps * 100
  c.delta:SetText(Signed(d) .. " DPS  " .. (pct >= 0 and "+" or "\226\136\146") .. ("%.1f%%"):format(abs(pct)))
  c.delta:SetTextColor(color[1], color[2], color[3])
  c.delta:SetAlpha(fade)
  c.sure:SetText((abs(d) < 2 * se and "within \194\177" or "\194\177") .. Fmt(2 * se))
  if stale then
    c.sub:SetText("Changed since the last run: Run sim again")
  else
    c.sub:SetText(("%s fights  ·  same rolls for both sets"):format(Fmt(res.work.iterations)))
  end
  -- abilities
  local work, ref = R():Breakdown(res.work), R():Breakdown(res.ref)
  local refBy = {}
  for _, a in ipairs(ref) do refBy[a.name] = a.dps end
  local top = work[1] and work[1].dps or 1
  local rw = c.rows[1]:GetWidth() or 200
  for i, r in ipairs(c.rows) do
    local a = work[i]
    if a then
      r:Show()
      r.name:SetText(a.name)
      r.value:SetText(Fmt(a.dps))
      local dd = a.dps - (refBy[a.name] or 0)
      r.delta:SetText(abs(dd) < 0.5 and "\194\183" or Signed(dd))
      local col = abs(dd) < 0.5 and GREY or (dd > 0 and GREEN or RED)
      r.delta:SetTextColor(col[1], col[2], col[3])
      r.bar:SetWidth(max(1, rw * a.dps / top))
      r:SetAlpha(fade)
    else
      r:Hide()
    end
  end
  -- stats (the Working set's, buffs included, before procs)
  local ST = ns.GearSim.ST
  local st = res.work.stats or {}
  local hit = st[ST.PhysicalHitPercent] or 0
  local hitCap = 9 - ((Settings().buffs ~= "solo") and 3 or 0)  -- Improved Faerie Fire covers 3%
  local expertise = floor((st[ST.ExpertiseRating] or 0) / ns.GearSim.EXPERTISE_PER_QUARTER)
  local function line(fs, label, value, col)
    fs:SetText("|cff8f8f95" .. label .. "|r  " .. value)
    fs:SetAlpha(fade)
  end
  line(c.stats[1], "Hit", hit >= hitCap and "|cff4fd36bcapped|r" or ("%.1f%% of %d%%"):format(hit, hitCap))
  line(c.stats[2], "Expertise", tostring(expertise))
  line(c.stats[3], "Crit", ("%.1f%%"):format(st[ST.PhysicalCritPercent] or 0))
  line(c.stats[4], "Attack power", Fmt(st[ST.AttackPower] or 0))
  self:UpdateProgress()
end

-- ---------------------------------------------------------------------------------------------------------------
-- The slot picker: My BiS's own (UI/Picker.lua), with the Working set as its host
-- ---------------------------------------------------------------------------------------------------------------
local pstate = { sid = nil, results = nil, ranked = nil, running = false, status = nil, known = {} }
local PAIR = { [11] = 12, [12] = 11, [13] = 14, [14] = 13 }
local SID_MH, SID_OH = 15, 16

local function SlotLabel(sid) return ns.SLOTS and ns.SLOTS[sid] and ns.SLOTS[sid].label or ("Slot " .. sid) end

local function IsTwoHander(itemID)
  return itemID and ns.ItemDB and ns.ItemDB.GetEquipLoc and ns.ItemDB:GetEquipLoc(itemID) == "INVTYPE_2HWEAPON"
end

local function FitsSlot(itemID, sid)
  local s = ns.SLOTS and ns.SLOTS[sid]
  if not s then return false end
  local loc
  if ns.ItemDB and ns.ItemDB.GetEquipLoc then loc = ns.ItemDB:GetEquipLoc(itemID) end
  if not loc and C_Item and C_Item.GetItemInfoInstant then
    local _, _, _, l = C_Item.GetItemInfoInstant(itemID)
    loc = l
  end
  return loc and s.invTypes and s.invTypes[loc] and true or false
end

local function BagItems(sid)
  local out = {}
  local numSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
  local getLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
  if not (numSlots and getLink) then return out end
  for bag = 0, 4 do
    for slot = 1, (numSlots(bag) or 0) do
      local e = R().ParseLink(getLink(bag, slot))
      if e and FitsSlot(e.id, sid) then out[#out + 1] = e end
    end
  end
  return out
end

-- The set entry for an item picked into a slot: the copy you own (its gems and enchant), else its My BiS setup,
-- else the guide's gems with the slot's enchant kept. An owned spare is compared set up: its empty sockets get the
-- guide's gems and a missing enchant the slot's one (a bag copy is rarely enchanted).
local function EntryFor(itemID, sid)
  local known = pstate.known[itemID]
  if known then
    local e = R():CopySet({ known })[1]
    local filled = R():FillEntry(itemID, sid, SimPanel:Working()[sid])
    if (e.enchant or 0) == 0 then e.enchant = filled.enchant end
    e.gems = e.gems or {}
    for i, g in pairs(filled.gems or {}) do
      if not e.gems[i] or e.gems[i] == 0 then e.gems[i] = g end
    end
    return e
  end
  local BiS = ns.BiS
  if BiS then
    local phases = { Phase() }
    for p = 0, (ns.MAX_PHASE or 5) do if p ~= Phase() then phases[#phases + 1] = p end end
    for _, p in ipairs(phases) do
      for _, s in ipairs({ sid, PAIR[sid] }) do
        if BiS:GetSlot(p, s, List()) == itemID then return R():FillEntryFromBiS(itemID, p, List(), s) end
      end
    end
  end
  return R():FillEntry(itemID, sid, SimPanel:Working()[sid])
end

-- The picker's first section: what you wear and carry for the slot.
local function MineSection(sid)
  local items, seen = {}, {}
  pstate.known = {}
  local function add(e, sub)
    if e and e.id and not seen[e.id] then
      seen[e.id] = true
      pstate.known[e.id] = e
      items[#items + 1] = { itemID = e.id, sub = sub }
    end
  end
  local eq = R():EquippedSet()
  add(eq[sid], "Equipped")
  if PAIR[sid] then add(eq[PAIR[sid]], "Equipped  ·  " .. SlotLabel(PAIR[sid])) end
  for _, e in ipairs(BagItems(sid)) do add(e, "In your bags") end
  return { name = "Your gear and bags", items = items }
end

local function RefreshPicker()
  if ns.Picker and ns.Picker:GetHost() == pstate.host then ns.Picker:RefreshHost() end
end

local function RunBest()
  if pstate.running then
    R():Cancel()
    pstate.running, pstate.status = false, nil
    RefreshPicker()
    return
  end
  local sid = pstate.sid
  local base = SimPanel:Working()
  local cur = base[sid]
  local db = R():DB()
  local jobs = { { key = "ref", set = base } }
  for _, id in ipairs(ns.Picker:VisibleItems()) do
    if #jobs > SimPanel.MAX_PICK_RUN then break end
    if db.items[id] and not (cur and cur.id == id) then
      local set = R():CopySet(base)
      set[sid] = EntryFor(id, sid)
      if sid == SID_MH and IsTwoHander(id) then set[SID_OH] = nil end
      jobs[#jobs + 1] = { key = id, set = set }
    end
  end
  if #jobs == 1 then
    pstate.status = "Nothing listed that the sim knows: change the filters."
    RefreshPicker()
    return
  end
  pstate.running, pstate.results, pstate.ranked = true, nil, nil
  local curName = cur and ns.ItemDB and ns.ItemDB:GetName(cur.id) or "an empty slot"
  local ok, err = R():Start(jobs, {
    iterations = SimPanel.PICK_ITERATIONS, settings = RunSettings(),
    onProgress = function(done, total, paused)
      pstate.status = paused and "Paused while you are in combat"
        or ("Simming %d items...  %d%%"):format(#jobs - 1, floor(done / max(1, total) * 100))
      if ns.Picker.RefreshHostBar then ns.Picker:RefreshHostBar() end
    end,
    onCancel = function()
      pstate.running, pstate.status = false, nil
      RefreshPicker()
    end,
    onDone = function(res, e)
      pstate.running = false
      if res then
        local r = { ref = res.ref.dps }
        local ranked = {}
        for k, s in pairs(res) do
          if type(k) == "number" then r[k] = s.dps; ranked[#ranked + 1] = k end
        end
        if cur then r[cur.id] = res.ref.dps; ranked[#ranked + 1] = cur.id end
        table.sort(ranked, function(a, b) return r[a] > r[b] end)
        pstate.results, pstate.ranked = r, ranked
        pstate.status = ("%d items, %s fights each, against %s"):format(#jobs - 1, Fmt(SimPanel.PICK_ITERATIONS), curName)
      else
        pstate.status = "Stopped: " .. tostring(e)
      end
      RefreshPicker()
    end,
  })
  if not ok then
    pstate.running = false
    pstate.status = tostring(err)
  end
  RefreshPicker()
end

local function NewHost()
  local host = {}
  host.title = function(label) return label .. "  ·  Working set" end
  host.current = function()
    local e = SimPanel:Working()[pstate.sid]
    return e and e.id
  end
  host.pick = function(itemID)
    if not FitsSlot(itemID, pstate.sid) then return false end
    SimPanel:SetWorkingSlot(pstate.sid, EntryFor(itemID, pstate.sid))
  end
  host.clear = function() SimPanel:SetWorkingSlot(pstate.sid, nil) end
  host.sections = function(sid)
    local secs = {}
    local mine = MineSection(sid)
    if pstate.ranked then
      local items, inRank = {}, {}
      for i, id in ipairs(pstate.ranked) do
        inRank[id] = true
        local sub = (i == 1) and "Best for this slot" or ""
        if host.current() == id then sub = (sub ~= "" and (sub .. "  ·  ") or "") .. "In the Working set" end
        items[#items + 1] = { itemID = id, sub = sub ~= "" and sub or (ns.ItemDB and ns.ItemDB:GetSourceText(id, true) or "") }
      end
      secs[#secs + 1] = { name = "Simmed, best first", items = items }
      local rest = {}
      for _, it in ipairs(mine.items) do if not inRank[it.itemID] then rest[#rest + 1] = it end end
      mine.items = rest
    end
    secs[#secs + 1] = mine
    return secs
  end
  host.value = function(itemID)
    local r = pstate.results
    local v = r and r[itemID]
    if not v then return nil end
    local d = v - r.ref
    local col = abs(d) < 0.5 and GREY or (d > 0 and GREEN or RED)
    return Fmt(v) .. " DPS", (abs(d) < 0.5 and "\194\183" or Signed(d)), col
  end
  host.button = {
    text = function() return pstate.running and "Cancel" or "Best for this slot" end,
    onClick = RunBest,
    tooltip = function(tt)
      tt:AddLine("Best for this slot", 1, 0.82, 0)
      tt:AddLine(("Sims the first %d items listed here in this slot, with the rest of the Working set as it is, and "
        .. "ranks them against the slot's item. The filters and the search choose which."):format(SimPanel.MAX_PICK_RUN),
        1, 1, 1, true)
    end,
  }
  host.status = function()
    return pstate.status or ("Sims the first %d items listed, %s fights each."):format(SimPanel.MAX_PICK_RUN, Fmt(SimPanel.PICK_ITERATIONS))
  end
  host.onClose = function()
    if pstate.running then R():Cancel() end
    pstate.running, pstate.results, pstate.ranked, pstate.status = false, nil, nil, nil
  end
  return host
end

function SimPanel:OpenPicker(sid, anchor)
  if not (ns.Picker and ns.Picker.Open) then return end
  if pstate.running then R():Cancel() end
  pstate.sid, pstate.results, pstate.ranked, pstate.status, pstate.running = sid, nil, nil, nil, false
  pstate.host = NewHost()
  ns.Picker:Open(Phase(), sid, "main", anchor, List(), pstate.host)
end

function SimPanel:IsPickerOpen() return ns.Picker and ns.Picker:GetHost() ~= nil and ns.Picker:GetHost() == pstate.host end
function SimPanel:ClosePicker() if self:IsPickerOpen() then ns.Picker:Close() end end

-- The off hand can't be changed while the Working set holds a two-hander (as in the game: choose a one-hander).
function SimPanel:OffHandBlocked()
  local mh = self:Working()[SID_MH]
  return mh and IsTwoHander(mh.id) and true or false
end

-- Slot clicks in Sim mode: left = the picker, right = a menu.
function SimPanel:OnSlotClick(sid, which, mouseButton, tile, parent)
  if sid == SID_OH and self:OffHandBlocked() then
    ns:Print("The Working set holds a two-hander: choose a one-hander in the main hand first.")
    return
  end
  if mouseButton ~= "RightButton" then
    self:OpenPicker(sid, tile)
    return
  end
  local eq = R():EquippedSet()[sid]
  local bis = ns.BiS and ns.BiS:GetSlot(Phase(), sid, List())
  ns.UI:ContextMenu(tile, function(root)
    root:CreateTitle((ns.SLOTS[sid] and ns.SLOTS[sid].label or "") .. "  ·  Working set")
    root:CreateButton("Choose item...", function() self:OpenPicker(sid, tile) end)
    if eq then root:CreateButton("Use my gear's item", function() self:SetWorkingSlot(sid, R():CopySet({ eq })[1]) end) end
    if bis then
      root:CreateButton("Use My BiS item", function() self:SetWorkingSlot(sid, R():FillEntryFromBiS(bis, Phase(), List(), sid)) end)
    end
    if self:Working()[sid] then root:CreateButton("Empty slot", function() self:SetWorkingSlot(sid, nil) end) end
  end)
end

function SimPanel:OnSlotReceiveItem(sid, itemID)
  if not FitsSlot(itemID, sid) then return end
  if sid == SID_OH and self:OffHandBlocked() then return end
  self:SetWorkingSlot(sid, R():FillEntry(itemID, sid, self:Working()[sid]))
end

-- More menu entries in Sim mode.
function SimPanel:BuildMoreEntries(root, entry, GOLDC)
  entry(ns.UI.ICON.copy or 1, "My gear", GOLDC, "Starts the Working set over from the gear you wear.", function()
    self:ResetTo(R():EquippedSet())
  end)
  local p = Phase()
  local label = "My BiS " .. (ns.PhaseLabel and ns.PhaseLabel(p) or ("P" .. p))
  entry(ns.UI.ICON.copy or 1, label, GOLDC, "Starts the Working set over from " .. label .. " (its gems and enchants).",
    function() self:ResetTo(R():BiSSet(p, List())) end)
  if root.CreateDivider then root:CreateDivider() end
  local tip = "Everything this sim uses (gear, gems, enchants, race, talents, professions, buffs, consumables, boss "
    .. "and rotation) as WoWSims settings: on wowsims.com/tbc open your spec's sim, Import > JSON, paste. Both sims "
    .. "then run the same fight."
  entry(ns.UI.ICON.export or 33, "WoWSims: Working set", GOLDC, tip, function()
    self:ShowExport("Working set", R():WoWSimsSettings(self:Working(), RunSettings()))
  end)
  entry(ns.UI.ICON.export or 33, "WoWSims: " .. self:TargetText(), GOLDC, tip, function()
    self:ShowExport(self:TargetText(), R():WoWSimsSettings(self:TargetSet(), RunSettings()))
  end)
end

-- A window with the export text selected for Ctrl+C.
local exportWin
function SimPanel:ShowExport(what, text)
  local UI = ns.UI
  if not exportWin then
    local f = UI:CreateWindow("DisasterZoneSimExport", "WoWSims settings", 460, 300, { noSavePosition = true })
    f:SetPoint("CENTER")
    local c = f.content or f
    f.help = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.help:SetPoint("TOPLEFT", c, "TOPLEFT", 8, -8)
    f.help:SetPoint("RIGHT", c, "RIGHT", -8, 0)
    f.help:SetJustifyH("LEFT")
    f.help:SetWordWrap(true)
    local sf = CreateFrame("ScrollFrame", nil, c, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", c, "TOPLEFT", 8, -52)
    sf:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -28, 8)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject("ChatFontSmall")
    eb:SetWidth(400)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    eb:SetScript("OnTextChanged", function(self, user) if user then self:SetText(f.text or "") self:HighlightText() end end)
    sf:SetScrollChild(eb)
    f.box = eb
    exportWin = f
  end
  exportWin.text = text
  exportWin.help:SetText(("%s: on wowsims.com/tbc open your spec's sim, click Import > JSON and paste (Ctrl+C copies "
    .. "it, it is selected). WoWSims then sims the same gear, talents, buffs, boss and rotation as this sim."):format(what))
  exportWin.box:SetText(text)
  exportWin:Show()
  exportWin:Raise()
  exportWin.box:SetFocus()
  exportWin.box:HighlightText()
end

-- Bag changes while the picker is open: its "Your gear and bags" section.
ns:RegisterEvent("BAG_UPDATE_DELAYED", function() if SimPanel:IsPickerOpen() then ns.Picker:RefreshHost() end end)

-- test hooks
function SimPanel._state() return state end
function SimPanel._pstate() return pstate end
function SimPanel._card() return card end
function SimPanel._runBest() RunBest() end
