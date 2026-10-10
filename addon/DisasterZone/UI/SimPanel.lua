if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SimPanel.lua", ...) then return end -- DisasterZone: UI/SimPanel.lua
-- ns.SimPanel: the Gear sim page (My BiS's panel in Sim mode). The slots show a Working set (a copy of the gear you
-- wear to start with) that you change slot by slot; a run sims it (Sim/*.lua, ns.SimRunner) against My gear or a
-- My BiS phase on the same random rolls. This file holds the state, the settings and the runs; UI/SimStage.lua draws
-- the page (the sigil, the settings sentence, the result) and UI/SimNerd.lua the Nerd stats. A slot click opens My
-- BiS's item picker (UI/Picker.lua) for the Working set: your gear and bags on top, then every source, and "Best for
-- this slot" sims what it lists. Runs only when asked (a click on the sigil).
local _, ns = ...

local SimPanel = {}
ns.SimPanel = SimPanel

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local GOLD = { 0.89, 0.70, 0.24 }
local GREEN = { 0.31, 0.83, 0.42 }
local RED = { 0.88, 0.38, 0.31 }
local GREY = { 0.56, 0.56, 0.59 }
SimPanel.PICK_ITERATIONS = 300
SimPanel.MAX_PICK_RUN = 30

local state = {
  active = false,
  working = nil,       -- gear set (ns.SimRunner sets)
  target = "gear",     -- what the Working set is compared to: "gear" | phase number (My BiS)
  results = nil,       -- the last run: { work = summary, ref = summary, diff, se, at }
  stale = true,
  running = false,
  serial = 0,          -- +1 for every finished run (the stage tells a finished run from a stopped one)
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
    mobType = s.mobType or DEFAULTS.mobType, fights = s.fights or ns.SimRunner.DEFAULT_ITERATIONS }
end
SimPanel.FIGHTS = { { n = 300, text = "Quick" }, { n = 1000, text = "Normal" }, { n = 3000, text = "Precise" } }
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
-- The last run's results ({ work, ref, diff, se, target }), nil before one.
function SimPanel:GetResults() return state.results end

-- Sim mode on / off, nothing else: the Gear sim page sets it (UI/MyBiS.lua's ApplyView, which refreshes).
function SimPanel:SetMode(on)
  on = on and true or false
  if on == state.active then return end
  state.active = on
  if not on then
    if R() then R():Cancel() end
    state.running = false
    SimPanel:ClosePicker()
    if ns.SimBuffsUI then ns.SimBuffsUI:Close() end
  end
end

-- Opens the Gear sim page (on) or goes back to My BiS (off).
function SimPanel:SetActive(on)
  if ns.MyBiS and ns.MyBiS.OpenView then
    ns.MyBiS:OpenView(on and "sim" or "list")
    return
  end
  self:SetMode(on)
end

-- The card's buffs setting: "raid25" | "raid10" | "solo" | "p:<id>" (my preset) | "t:<team>:<lineup>" (ns.SimBuffs).
function SimPanel:GetBuffs() return Settings().buffs end

function SimPanel:SetBuffs(key)
  SetSetting("buffs", key)
  state.stale = true
  self:UpdateCard()
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
SimPanel.Settings = Settings

-- The card's settings for a run (the consumables view sims with them too).
function SimPanel:RunSettings() return RunSettings() end

local function Now() return debugprofilestop and debugprofilestop() or ((GetTime and GetTime() or 0) * 1000) end

function SimPanel:Run()
  if state.running then
    R():Cancel()
    state.running = false
    self:UpdateCard()
    return
  end
  if not R():IsSupported() then return end
  local fights = Settings().fights
  state.running = true
  state.progress, state.paused, state.total = 0, false, fights
  local info = { started = Now(), frames = 0, pausedEver = false, fights = fights }
  state.info = info
  local ok, err = R():Start({ { key = "work", set = self:Working() }, { key = "ref", set = self:TargetSet() } }, {
    iterations = fights,
    settings = RunSettings(),
    onProgress = function(done, total, paused)
      state.progress, state.paused = done / max(1, total), paused
      info.frames = info.frames + 1
      if paused then info.pausedEver = true end
      info.simmed = total
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
        info.ms = Now() - info.started
        info.cached = res.cached
        info.settings = RunSettings()
        state.results = { work = res.work, ref = res.ref, diff = d, se = se, target = state.target, info = info }
        state.stale = false
        state.serial = state.serial + 1
        -- (a run that ended while the page was out of sight shows its result at once, no sweep)
        state.doneSeen = ns.SimStage and ns.SimStage.frame and ns.SimStage.frame:IsVisible() or false
        if info.simmed and info.simmed > 0 and info.ms > 0 then state.msPerFight = info.ms / info.simmed end
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

-- Nerd stats' "Run 3,000 fights": that many fights from now on, and a run at once.
function SimPanel.SetFightsAndRun(n)
  SetSetting("fights", n)
  state.stale = true
  if ns.SimNerd then ns.SimNerd:Close() end
  if not state.running then SimPanel:Run() end
end

-- The Working set's fights simmed so far in the running (or last) run, and the run's fight count.
function SimPanel:LiveList()
  local list = R().LiveList and R():LiveList("work")
  if not list and state.results then list = state.results.work.iterDps end
  return list, state.total or (state.results and state.results.work.iterations)
end

-- ---------------------------------------------------------------------------------------------------------------
-- The page (UI/SimStage.lua draws it)
-- ---------------------------------------------------------------------------------------------------------------
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
SimPanel.Signed = Signed

local function Duration(d) return ("%d:%02d"):format(floor(d / 60), d % 60) end
local function MobText(key)
  for _, m in ipairs(R().MOB_TYPES) do if m.key == key then return m.text, m end end
  return key
end

-- body: the page's body; doll: the paper doll (the Working set).
function SimPanel:CreateCard(body, doll)
  card = ns.SimStage:Create(body, doll)
  return card
end

-- The settings' words for the sentence and the chip.
function SimPanel:SettingWords()
  local s = Settings()
  local n = 0
  if R():IsSupported() then for _ in pairs(self:Changed()) do n = n + 1 end end
  local buffs = (R():BuffName(s.buffs))
  local mob = MobText(s.mobType)
  return {
    changes = n, target = self:TargetText(), fights = Fmt(s.fights) .. " fights", duration = Duration(s.duration),
    boss = "level 73 " .. mob, buffs = buffs,
    chip = ("%s \195\151 %s  \194\183  %s"):format(Fmt(s.fights), Duration(s.duration), mob),
  }
end

-- About how long a run of n fights takes (both sets), from the last run's speed.
function SimPanel:EstimateText(n)
  local ms = state.msPerFight
  if not ms then return nil end
  local sec = ms * n * 2 / 1000
  if sec < 1.5 then return "about a second" end
  if sec < 90 then return ("about %d s"):format(floor(sec + 0.5)) end
  return ("about %d min"):format(floor(sec / 60 + 0.5))
end

SimPanel.WordTip = {
  working = function(tt)
    tt:AddLine("Working set", 1, 0.82, 0)
    tt:AddLine("The gear the sim tries: your own to start with. After a run its slots show on both sides; click one "
      .. "to try another item.", 1, 1, 1, true)
  end,
  target = function(tt)
    tt:AddLine("Compared with", 1, 0.82, 0)
    tt:AddLine("Both sets fight the same fights, roll for roll, so the difference is the gear alone.", 1, 1, 1, true)
  end,
  fights = function(tt)
    tt:AddLine("Fights", 1, 0.82, 0)
    tt:AddLine("More fights pin the average down closer (the \194\177 shrinks) but take longer.", 1, 1, 1, true)
  end,
  duration = function(tt)
    tt:AddLine("Fight length", 1, 0.82, 0)
    tt:AddLine("Longer fights spread cooldowns, drums and potions thinner over the fight.", 1, 1, 1, true)
  end,
  mob = function(tt)
    local _, m = MobText(Settings().mobType)
    tt:AddLine("Boss type", 1, 0.82, 0)
    tt:AddLine(m and m.tip or "", 1, 1, 1, true)
  end,
  buffs = function(tt) SimPanel:BuffsTooltip(tt, Settings().buffs) end,
}

local function SettingChanged()
  state.stale = true
  SimPanel:UpdateCard()
end

-- One setting's menu (a word of the sentence, or a submenu of the chip's menu).
function SimPanel:BuildSettingMenu(root, key)
  local close = MenuResponse and MenuResponse.Close or nil
  if key == "working" then
    root:CreateTitle("Working set")
    root:CreateButton("Start over from my gear", function() self:ResetTo(R():EquippedSet()) end)
    local p = Phase()
    local label = "My BiS " .. (ns.PhaseLabel and ns.PhaseLabel(p) or ("P" .. p))
    root:CreateButton("Start over from " .. label, function() self:ResetTo(R():BiSSet(p, List())) end)
  elseif key == "target" then
    root:CreateTitle("Compare with")
    local function isSel(v) return tostring(state.target) == v end
    local function pick(v)
      state.target = (v == "gear") and "gear" or tonumber(v)
      state.stale = true
      if ns.MyBiS then ns.MyBiS:Refresh() end
      self:UpdateCard()
      return close
    end
    root:CreateRadio("My gear", isSel, pick, "gear")
    for p = 0, (ns.MAX_PHASE or 5) do root:CreateRadio(self:TargetText(p), isSel, pick, tostring(p)) end
  elseif key == "fights" then
    root:CreateTitle("Fights")
    local function isSel(v) return Settings().fights == v end
    local function pick(v) SetSetting("fights", v); SettingChanged(); return close end
    for _, f in ipairs(SimPanel.FIGHTS) do
      local e = root:CreateRadio(("%s  \194\183  %s"):format(f.text, Fmt(f.n)), isSel, pick, f.n)
      local est = self:EstimateText(f.n)
      if est and e.SetHint then e:SetHint(est) end
    end
  elseif key == "duration" then
    root:CreateTitle("Fight length")
    local function isSel(v) return Settings().duration == v end
    local function pick(v) SetSetting("duration", v); SettingChanged(); return close end
    for _, d in ipairs(R().DURATIONS) do root:CreateRadio(Duration(d), isSel, pick, d) end
  elseif key == "mob" then
    root:CreateTitle("Boss type")
    local function isSel(v) return Settings().mobType == v end
    local function pick(v) SetSetting("mobType", v); SettingChanged(); return close end
    for _, m in ipairs(R().MOB_TYPES) do
      local e = root:CreateRadio(m.text, isSel, pick, m.key)
      e:SetTooltip(function(tt) tt:AddLine(m.text, 1, 0.82, 0) tt:AddLine(m.tip, 1, 1, 1, true) end)
    end
  elseif key == "buffs" then
    self:BuildBuffsMenu(root)
  end
end

-- The result chip's menu: every setting as a submenu.
function SimPanel:BuildSettingsMenu(root)
  local w = self:SettingWords()
  root:CreateTitle("Settings")
  local function sub(label, value, key)
    local e = root:CreateButton(label .. "  |cff8f8f95" .. value .. "|r")
    self:BuildSettingMenu(e, key)
  end
  sub("Compare with", w.target, "target")
  sub("Fights", Fmt(Settings().fights), "fights")
  sub("Fight length", w.duration, "duration")
  sub("Boss", (MobText(Settings().mobType)), "mob")
  sub("Buffs", w.buffs, "buffs")
  root:CreateDivider()
  sub("Working set", w.changes == 1 and "1 change" or (w.changes .. " changes"), "working")
end

-- "Meta gem off: needs ..." when a set's meta gem is switched off (it explains a drop the stats alone don't).
function SimPanel:MetaWarning()
  local _, workMeta = R():MetaOff(self:Working())
  local _, refMeta = R():MetaOff(self:TargetSet())
  if not (workMeta or refMeta) then return nil end
  local where = (workMeta and refMeta) and "Both sets: " or (workMeta and "" or (self:TargetText() .. ": "))
  local need = (workMeta or refMeta):gsub("^at least ", ""):gsub(" gems$", ""):gsub(" and ", ", ")
  return ("%sMeta gem off: needs %s"):format(where, need)
end

-- The buffs menu: WoWSims' three, my presets (edit on the right), my teams' lineups (where I stand on the right; a
-- click there opens the editor), then New preset.
function SimPanel:BuildBuffsMenu(root)
  local SB = ns.SimBuffs
  local function isSel(key) return Settings().buffs == key end
  local function pick(key)
    SimPanel:SetBuffs(key)
    return MenuResponse and MenuResponse.Close or nil
  end
  local function edit(key) if ns.SimBuffsUI then ns.SimBuffsUI:Open(key) end end
  root:CreateTitle("WoWSims presets")
  for _, b in ipairs(R().BUFFS) do
    local e = root:CreateRadio(b.text, isSel, pick, b.key)
    if e.SetHint and b.key == "raid25" then e:SetHint("WoWSims' raid setup") end
    e:SetTooltip(function(tt) SimPanel:BuffsTooltip(tt, b.key) end)
  end
  local presets = SB and SB:GetPresets() or {}
  if #presets > 0 then
    root:CreateDivider()
    root:CreateTitle("My presets")
    for _, p in ipairs(presets) do
      local e = root:CreateRadio(p.name, isSel, pick, p.key)
      if e.SetHint then e:SetHint("edit", edit) end
      e:SetTooltip(function(tt) SimPanel:BuffsTooltip(tt, p.key) end)
    end
  end
  local lineups = SB and SB:MyLineups() or {}
  if #lineups > 0 then
    root:CreateDivider()
    root:CreateTitle("My teams \194\183 follow who is there")
    for _, l in ipairs(lineups) do
      local e = root:CreateRadio(l.name, isSel, pick, l.key)
      local where = l.group and ("group " .. l.group) or "no group yet"
      if l.open > 0 then where = where .. (" \194\183 %d open slot%s"):format(l.open, l.open == 1 and "" or "s") end
      if e.SetHint then e:SetHint(where, edit) end
      e:SetTooltip(function(tt) SimPanel:BuffsTooltip(tt, l.key) end)
    end
  end
  root:CreateDivider()
  root:CreateButton("|cffe2b33e+|r  New preset...", function() edit(nil) end)
end

-- What a buffs setting holds, for a tooltip.
function SimPanel:BuffsTooltip(tt, key)
  for _, b in ipairs(R().BUFFS) do
    if b.key == key then
      tt:AddLine(b.text, 1, 0.82, 0)
      local cls = R():Class()
      tt:AddLine((R():Spec() == "Elemental" and b.tipElemental) or (R():Spec() == "Balance" and b.tipBalance) or (cls == "WARRIOR" and b.tipWarrior) or (cls == "SHAMAN" and b.tipShaman) or (cls == "ROGUE" and b.tipRogue) or (cls == "DRUID" and b.tipDruid) or (cls == "PRIEST" and b.tipPriest) or (cls == "MAGE" and b.tipMage) or (cls == "WARLOCK" and b.tipWarlock) or (cls == "HUNTER" and b.tipHunter) or b.tip, 1, 1, 1, true)
      return
    end
  end
  local SB = ns.SimBuffs
  local _, cls = UnitClass("player")
  local cfg, info, name = nil, nil, nil
  if SB then cfg, info, name = SB:Resolve(key, cls, R():BaseConfig("raid25")) end
  if not cfg then
    tt:AddLine("25-man buffs", 1, 0.82, 0)
    tt:AddLine("The preset or team you picked is gone; the sim uses WoWSims' 25-man setup.", 1, 1, 1, true)
    return
  end
  tt:AddLine(name, 1, 0.82, 0)
  if info then
    local where = info.group and ("You're in group " .. info.group .. ".") or "You're in no group of this lineup yet: no party buffs."
    tt:AddLine("Follows who is placed in this team lineup. " .. where, 1, 1, 1, true)
  else
    tt:AddLine("Your preset (saved for all your characters).", 1, 1, 1, true)
  end
  local on = {}
  for _, t in ipairs(SB:Tiles(cls)) do
    local v = SB:Get(cfg, t)
    if v > 0 then
      local s = t.name
      if t.kind == "tri" and v == 2 then s = s .. " (improved)" end
      if t.states then s = t.states[v + 1] end
      on[#on + 1] = s
    end
  end
  tt:AddLine(#on > 0 and table.concat(on, ", ") or "Nothing on.", 0.8, 0.8, 0.8, true)
  tt:AddLine("Click \"edit\" in the list to change it.", 0.56, 0.56, 0.59, true)
end

function SimPanel:ShowCard(on)
  if ns.SimStage then ns.SimStage:Show(on) end
end

function SimPanel:UpdateProgress() end

function SimPanel:UpdateCard()
  if ns.SimStage then ns.SimStage:Sync(true) end
  if ns.SimNerd and ns.SimNerd.Refresh then ns.SimNerd:Refresh() end
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
    local free = {}
    for i, g in pairs(filled.gems or {}) do
      if not e.gems[i] or e.gems[i] == 0 then e.gems[i] = g; free[i] = true end
    end
    return R():KeepMetaActive(SimPanel:Working(), sid, e, free)
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
  local e = R():FillEntry(itemID, sid, SimPanel:Working()[sid])
  local free = {}
  for i in pairs(e.gems or {}) do free[i] = true end
  return R():KeepMetaActive(SimPanel:Working(), sid, e, free)
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
  if ns.SimBuffsUI then ns.SimBuffsUI:Close() end
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
  local e = R():FillEntry(itemID, sid, self:Working()[sid])
  local free = {}
  for i in pairs(e.gems or {}) do free[i] = true end
  self:SetWorkingSlot(sid, R():KeepMetaActive(self:Working(), sid, e, free))
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
    local sf = ns.UI:CreateScrollFrame(c)
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
