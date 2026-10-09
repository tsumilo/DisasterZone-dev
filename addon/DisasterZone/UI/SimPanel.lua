if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SimPanel.lua", ...) then return end -- DisasterZone: UI/SimPanel.lua
-- ns.SimPanel: My BiS in Sim mode (the Sim button in the top bar). The slots show a Working set (a copy of the gear
-- you wear to start with) that you change slot by slot; the centre runs the gear sim (Sim/*.lua, ns.SimRunner) for it
-- against My gear or a My BiS phase, on the same random rolls, and shows the difference, the damage by ability and
-- the key stats. A slot click opens the slot's picker: your gear, bags and BiS picks, or every item for the slot, each
-- simmed on demand ("Best for this slot"). Runs only when asked (the Run sim button).
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
local card, picker

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
    if picker then picker:Hide() end
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
  local talents = R():TalentString()
  if not talents or not talents:find("[1-5]") then talents = nil end
  return { buffs = s.buffs, duration = s.duration, mobType = s.mobType,
    talents = talents or R().DEFAULT_TALENTS[R():SpecKey()] }
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
-- The slot picker
-- ---------------------------------------------------------------------------------------------------------------
local pstate = { sid = nil, tab = "mine", search = "", rows = {}, results = nil, running = false }

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
      local link = getLink(bag, slot)
      local e = R().ParseLink(link)
      if e and FitsSlot(e.id, sid) then out[#out + 1] = { entry = e, from = "Bags" } end
    end
  end
  return out
end

-- Rows: { entry = set entry, from = text }
local function MineRows(sid)
  local rows, seen = {}, {}
  local function add(entry, from)
    if entry and entry.id and not seen[entry.id] then
      seen[entry.id] = true
      rows[#rows + 1] = { entry = entry, from = from }
    end
  end
  local w = SimPanel:Working()
  add(w[sid], "Working set")
  local eq = R():EquippedSet()
  local pair = ({ [11] = 12, [12] = 11, [13] = 14, [14] = 13 })[sid]
  add(eq[sid], "My gear")
  if pair then add(eq[pair], "My gear") end
  for _, r in ipairs(BagItems(sid)) do add(r.entry, r.from) end
  local BiS = ns.BiS
  if BiS then
    for p = 0, (ns.MAX_PHASE or 5) do
      for _, s in ipairs({ sid, pair }) do
        local main, alt = BiS:GetSlot(p, s, List())
        local label = "My BiS " .. (ns.PhaseLabel and ns.PhaseLabel(p) or ("P" .. p))
        if main then add(R():FillEntryFromBiS(main, p, List(), s), label) end
        if alt then add(R():FillEntry(alt, s), label .. " (alt)") end
      end
    end
  end
  return rows
end

local function AllRows(sid)
  local rows = {}
  local ItemDB = ns.ItemDB
  if not (ItemDB and ItemDB.GetCandidates) then return rows end
  local _, cls = UnitClass("player")
  local armor = ({ [1] = true, [3] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true, [10] = true })[sid]
  local cands = ItemDB:GetCandidates(sid, { includeTrash = true, maxPhase = max(1, Phase()), scope = "all",
    sources = { raids = true, dungeons = true, crafted = true, rep = true, badges = true, pvp = false },
    class = cls, usableOnly = true, primaryArmorOnly = armor and true or false }) or {}
  local db = R():DB()
  local seen = {}
  for _, c in ipairs(cands) do
    local id = tonumber(c.itemID)
    if id and not seen[id] and db.items[id] then
      seen[id] = true
      rows[#rows + 1] = { entry = R():FillEntry(id, sid), from = ItemDB.GetSourceText and ItemDB:GetSourceText(id, true) or "" }
    end
  end
  return rows
end

local function FilteredRows()
  local rows = pstate.tab == "all" and AllRows(pstate.sid) or MineRows(pstate.sid)
  local needle = (pstate.search or ""):lower()
  if needle ~= "" then
    local out = {}
    for _, r in ipairs(rows) do
      local name = (GetItemInfo and GetItemInfo(r.entry.id)) or ""
      if name:lower():find(needle, 1, true) then out[#out + 1] = r end
    end
    rows = out
  end
  return rows
end

local function PickerRefresh(resetScroll)
  if not picker then return end
  pstate.rows = FilteredRows()
  if pstate.results then
    table.sort(pstate.rows, function(a, b)
      local x, y = pstate.results[a.entry.id], pstate.results[b.entry.id]
      if x and y then return x > y end
      return x ~= nil and y == nil
    end)
  end
  picker.list:SetData(pstate.rows, resetScroll)
  picker.best:SetText(pstate.running and "Cancel" or "Best for this slot")
  picker.status:SetText(pstate.status or "")
end

local function InitPickRow(row, d)
  local UI = ns.UI
  if not row.icon then
    row:RegisterForClicks("LeftButtonUp")
    row:SetHighlightTexture(UI:Tex("rowHilight"), "ADD")
    row.icon = UI:CreateItemButton(row, 30)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -1)
    row.name:SetPoint("RIGHT", row, "RIGHT", -96, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 1)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -96, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row.dps = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.dps:SetPoint("RIGHT", row, "RIGHT", -48, 0)
    row.dps:SetJustifyH("RIGHT")
    row.delta = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.delta:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.delta:SetJustifyH("RIGHT")
    row:SetScript("OnClick", function(self)
      local r = self.data
      if not r then return end
      if UI.HandleModifiedItemClick and UI:HandleModifiedItemClick(r.entry.id) then return end
      SimPanel:SetWorkingSlot(pstate.sid, R():CopySet({ r.entry })[1])
      picker:Hide()
    end)
    row:SetScript("OnEnter", function(self)
      if self.data then UI:SetItemTooltip(self, ns.Gems and ns.Gems:Link(self.data.entry.id, self.data.entry.enchant, self.data.entry.gems) or self.data.entry.id) end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.icon.onClick = function() row:Click() end
  end
  row.data = d
  local e = d.entry
  row.icon:SetItem(e.id)
  row.name:SetText((UI:ItemText(e.id)))
  local w = SimPanel:Working()[pstate.sid]
  local inUse = w and w.id == e.id
  row.sub:SetText((d.from or "") .. (inUse and ("  ·  " .. UI:Colorize("in use", GOLD)) or ""))
  local v = pstate.results and pstate.results[e.id]
  local ref = pstate.results and pstate.results.ref
  if v and ref then
    row.dps:SetText(Fmt(v))
    local dd = v - ref
    row.delta:SetText(abs(dd) < 0.5 and "\194\183" or Signed(dd))
    local col = abs(dd) < 0.5 and GREY or (dd > 0 and GREEN or RED)
    row.delta:SetTextColor(col[1], col[2], col[3])
  else
    row.dps:SetText("")
    row.delta:SetText("")
  end
end

local function RunBest()
  if pstate.running then
    R():Cancel()
    pstate.running = false
    pstate.status = nil
    PickerRefresh(false)
    return
  end
  local rows = pstate.rows
  local jobs = { { key = "ref", set = SimPanel:TargetSet() } }
  local base = SimPanel:Working()
  for i, r in ipairs(rows) do
    if i > SimPanel.MAX_PICK_RUN then break end
    local set = R():CopySet(base)
    set[pstate.sid] = R():CopySet({ r.entry })[1]
    jobs[#jobs + 1] = { key = r.entry.id, set = set }
  end
  pstate.running = true
  pstate.results = nil
  local ok, err = R():Start(jobs, {
    iterations = SimPanel.PICK_ITERATIONS, settings = RunSettings(),
    onProgress = function(done, total, paused)
      pstate.status = paused and "Paused while you are in combat" or ("Simming %d items...  %d%%"):format(#jobs - 1, floor(done / max(1, total) * 100))
      if picker then picker.status:SetText(pstate.status) end
    end,
    onDone = function(res, e)
      pstate.running = false
      if res then
        pstate.results = { ref = res.ref.dps }
        for k, s in pairs(res) do if type(k) == "number" then pstate.results[k] = s.dps end end
        pstate.status = ("%s fights each  ·  same rolls  ·  vs %s"):format(Fmt(SimPanel.PICK_ITERATIONS), SimPanel:TargetText())
      else
        pstate.status = "Stopped: " .. tostring(e)
      end
      PickerRefresh(false)
    end,
  })
  if not ok then
    pstate.running = false
    pstate.status = tostring(err)
  end
  PickerRefresh(false)
end

local function EnsurePicker(parent)
  if picker then return picker end
  local UI = ns.UI
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)
  f:SetFrameStrata("DIALOG")
  f:EnableMouse(true)
  f:SetScript("OnMouseDown", function(self) self:Hide() end)
  local shade = f:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints()
  shade:SetColorTexture(0, 0, 0, 0.45)
  local box = CreateFrame("Frame", nil, f)
  box:SetSize(320, 380)
  box:SetPoint("CENTER", f, "CENTER", 0, -10)
  box:EnableMouse(true)
  local bg = box:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.09, 0.09, 0.105, 0.98)
  local edge = box:CreateTexture(nil, "BACKGROUND", nil, -1)
  edge:SetPoint("TOPLEFT", -1, 1)
  edge:SetPoint("BOTTOMRIGHT", 1, -1)
  edge:SetColorTexture(EDGE[1], EDGE[2], EDGE[3], 0.9)
  local inner = box:CreateTexture(nil, "BACKGROUND", nil, 1)
  inner:SetAllPoints()
  inner:SetColorTexture(0.09, 0.09, 0.105, 1)
  f.box = box

  f.title = Text(box, 14, { 0.94, 0.94, 0.94 })
  f.title:SetPoint("TOPLEFT", box, "TOPLEFT", 12, -12)
  f.best = UI:CreateSleekButton(box, "Best for this slot", 128, 22, RunBest)
  f.best:SetPoint("TOPRIGHT", box, "TOPRIGHT", -10, -8)
  f.best:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Best for this slot", 1, 0.82, 0)
    GameTooltip:AddLine(("Sims every item in the list (up to %d) in this slot, with the rest of the Working set, "
      .. "and ranks them."):format(SimPanel.MAX_PICK_RUN), 1, 1, 1, true)
    GameTooltip:Show()
  end)
  f.best:HookScript("OnLeave", function() GameTooltip:Hide() end)

  f.tabs = {}
  local function tab(key, text)
    local t = UI:CreateUnderlineTab(box, text, function()
      pstate.tab = key
      pstate.results = nil
      for k, b in pairs(f.tabs) do b:SetActive(k == key) end
      PickerRefresh(true)
    end, "small")
    f.tabs[key] = t
    return t
  end
  tab("mine", "Mine"):SetPoint("TOPLEFT", box, "TOPLEFT", 8, -38)
  tab("all", "All items"):SetPoint("LEFT", f.tabs.mine, "RIGHT", 10, 0)
  f.search = UI:CreateSearchBox(box, 120, function(text)
    pstate.search = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    PickerRefresh(true)
  end, "Search")
  f.search:SetPoint("TOPRIGHT", box, "TOPRIGHT", -10, -40)

  local hdr = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hdr:SetPoint("TOPRIGHT", box, "TOPRIGHT", -16, -68)
  hdr:SetText("DPS     vs target")
  f.list = UI:CreateScrollList(box, 38, InitPickRow)
  f.list.frame:SetPoint("TOPLEFT", box, "TOPLEFT", 6, -82)
  f.list.frame:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -2, 26)
  f.list:SetEmptyText("No items for this slot here. Try All items, or drag an item onto the slot.")
  f.status = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.status:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 10, 8)
  f.status:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -10, 8)
  f.status:SetJustifyH("LEFT")
  f:SetScript("OnHide", function()
    if pstate.running then R():Cancel(); pstate.running = false end
  end)
  picker = f
  return f
end

function SimPanel:OpenPicker(sid, parent)
  local f = EnsurePicker(parent)
  pstate.sid, pstate.results, pstate.status, pstate.search = sid, nil, nil, ""
  local label = ns.SLOTS and ns.SLOTS[sid] and ns.SLOTS[sid].label or ("Slot " .. sid)
  f.title:SetText(label)
  f.search:SetText("")
  for k, b in pairs(f.tabs) do b:SetActive(k == pstate.tab) end
  f:Show()
  f:Raise()
  PickerRefresh(true)
end

function SimPanel:ClosePicker() if picker then picker:Hide() end end
function SimPanel:IsPickerOpen() return picker and picker:IsShown() and true or false end
function SimPanel:PickerRows() return pstate.rows end

-- Slot clicks in Sim mode: left = the picker, right = a menu.
function SimPanel:OnSlotClick(sid, which, mouseButton, tile, parent)
  if mouseButton ~= "RightButton" then
    self:OpenPicker(sid, parent)
    return
  end
  local eq = R():EquippedSet()[sid]
  local bis = ns.BiS and ns.BiS:GetSlot(Phase(), sid, List())
  ns.UI:ContextMenu(tile, function(root)
    root:CreateTitle((ns.SLOTS[sid] and ns.SLOTS[sid].label or "") .. "  ·  Working set")
    root:CreateButton("Choose item...", function() self:OpenPicker(sid, parent) end)
    if eq then root:CreateButton("Use my gear's item", function() self:SetWorkingSlot(sid, R():CopySet({ eq })[1]) end) end
    if bis then
      root:CreateButton("Use My BiS item", function() self:SetWorkingSlot(sid, R():FillEntryFromBiS(bis, Phase(), List(), sid)) end)
    end
    if self:Working()[sid] then root:CreateButton("Empty slot", function() self:SetWorkingSlot(sid, nil) end) end
  end)
end

function SimPanel:OnSlotReceiveItem(sid, itemID)
  if not FitsSlot(itemID, sid) then return end
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
end

-- Item changes in bags or gear: the picker's Mine tab.
-- test hooks
function SimPanel._state() return state end
function SimPanel._pstate() return pstate end
function SimPanel._runBest() RunBest() end

ns:RegisterEvent("BAG_UPDATE_DELAYED", function() if SimPanel:IsPickerOpen() and pstate.tab == "mine" then PickerRefresh(false) end end)
ns:On("ITEMINFO_READY", function() if SimPanel:IsPickerOpen() then picker.list:Refresh() end end)
