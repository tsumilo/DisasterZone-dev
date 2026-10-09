if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Runner.lua", ...) then return end -- DisasterZone: Sim/Runner.lua
-- ns.SimRunner: the gear sim in the game. Gear sets from what is equipped (gems read off the item links) and from
-- My BiS (picks + gem setups); talents, race and professions of the player; and runs: several sets simmed
-- side by side on the same random rolls (iteration i of every set uses the same seed), a slice per frame so the
-- game keeps its frame rate, paused while in combat.
local _, ns = ...
local S = ns.GearSim

local Runner = {}
ns.SimRunner = Runner

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

Runner.SPECS = { ["PALADIN:Retribution"] = true }
Runner.DEFAULT_ITERATIONS = 1000
Runner.FRAME_BUDGET_MS = 12

-- ---------------------------------------------------------------------------------------------------------------
-- Settings: buffs, fight length, boss type
-- ---------------------------------------------------------------------------------------------------------------
Runner.BUFFS = {
  { key = "raid25", text = "25-man buffs",
    tip = "WoWSims' Retribution raid setup: Bloodlust, drums, Windfury and Grace of Air (twisted), Strength of Earth, "
      .. "Battle Shout, Leader of the Pack, Unleashed Rage, all blessings and raid buffs, Sunder / Expose Armor, Faerie "
      .. "Fire, Curse of Recklessness, Blood Frenzy, Misery, Hunter's Mark, Expose Weakness, Judgements of the "
      .. "Crusader and Wisdom; flask, food, scrolls, Haste Potion, Demonic Rune and explosives (Engineering)." },
  { key = "raid10", text = "10-man buffs",
    tip = "A Karazhan-style group: Kings, Might, Wisdom, Gift of the Wild, Fortitude, Arcane Intellect, Battle Shout, "
      .. "Windfury and Strength of Earth totems, Bloodlust, Sunder Armor, Faerie Fire, Curse of Recklessness, "
      .. "Judgement of Wisdom; flask, food, Haste Potion." },
  { key = "solo", text = "No buffs",
    tip = "Only what you bring yourself: flask, food and a Haste Potion; no raid buffs or debuffs." },
}
Runner.DURATIONS = { 60, 120, 180, 240, 300, 420 }
Runner.MOB_TYPES = {
  { key = "Mechanical", text = "Mechanical", tip = "No bonus from Crusade or Exorcism (WoWSims' default boss)." },
  { key = "Demon", text = "Demon", tip = "Crusade and Exorcism apply (Magtheridon, Illidan...)." },
  { key = "Undead", text = "Undead", tip = "Crusade and Exorcism apply." },
  { key = "Humanoid", text = "Humanoid", tip = "Crusade applies." },
  { key = "Elemental", text = "Elemental", tip = "Crusade applies." },
  { key = "Giant", text = "Giant", tip = "No bonus from Crusade." },
  { key = "Dragonkin", text = "Dragonkin", tip = "No bonus from Crusade." },
  { key = "Beast", text = "Beast", tip = "No bonus from Crusade." },
}

local RAID10 = {
  raid = { bloodlust = true, arcaneBrilliance = true, giftOfTheWild = 2, powerWordFortitude = 1 },
  party = { battleShout = 1, windfuryTotem = 1, strengthOfEarthTotem = 1, manaSpringTotem = 1 },
  individual = { blessingOfKings = true, blessingOfWisdom = 1, blessingOfMight = 1 },
  debuffs = { sunderArmor = true, faerieFire = 1, curseOfRecklessness = true, judgementOfWisdom = true },
  consumables = { potId = 22838, flaskId = 22854, foodId = 27658 },
}
local SOLO = {
  raid = {}, party = {}, individual = {}, debuffs = {},
  consumables = { potId = 22838, flaskId = 22854, foodId = 27658 },
}

function Runner:BuffConfig(key)
  if key == "raid10" then return RAID10 end
  if key == "solo" then return SOLO end
  return S.BUFF_PRESETS.wowsims_ret
end

-- ---------------------------------------------------------------------------------------------------------------
-- The player
-- ---------------------------------------------------------------------------------------------------------------
function Runner:Race()
  local _, file = UnitRace("player")
  return file or "Human"
end

function Runner:Class()
  local _, cls = UnitClass("player")
  return cls
end

function Runner:Professions()
  local set = ns.Gems and ns.Gems.ProfessionSet and ns.Gems:ProfessionSet() or {}
  local out = {}
  for name in pairs(set) do out[#out + 1] = name end
  return out
end

-- The talent string in Wowhead / WoWSims order (each tree by row, then column).
function Runner:TalentString()
  if not GetNumTalentTabs then return nil end
  local trees = {}
  for tab = 1, (GetNumTalentTabs() or 0) do
    local list = {}
    for i = 1, (GetNumTalents(tab) or 0) do
      local _, _, tier, column, rank = GetTalentInfo(tab, i)
      list[#list + 1] = { tier = tier or 0, column = column or 0, rank = rank or 0 }
    end
    table.sort(list, function(a, b) if a.tier ~= b.tier then return a.tier < b.tier end return a.column < b.column end)
    local s = {}
    for i, t in ipairs(list) do s[i] = tostring(t.rank) end
    trees[tab] = (table.concat(s):gsub("0+$", ""))
  end
  return table.concat(trees, "-")
end

-- WoWSims' standard Retribution build, for BiS lists and when talents can't be read.
Runner.DEFAULT_TALENTS = { ["PALADIN:Retribution"] = "5-053201-0523005120033125331051" }

-- ---------------------------------------------------------------------------------------------------------------
-- Gear sets: { [sid] = { id = itemID, enchant = effectID, gems = { gem item IDs } } } (sid = ns.SLOTS order)
-- ---------------------------------------------------------------------------------------------------------------
local function ParseLink(link)
  if type(link) ~= "string" then return nil end
  local id, enchant = link:match("item:(%d+):(%d*)")
  id = tonumber(id)
  if not id then return nil end
  local e = { id = id, enchant = tonumber(enchant) or 0, gems = {} }
  if GetItemGem then
    for i = 1, 4 do
      local _, gemLink = GetItemGem(link, i)
      local gid = gemLink and tonumber(gemLink:match("item:(%d+)"))
      if gid then e.gems[i] = gid end
    end
  end
  return e
end
Runner.ParseLink = ParseLink

function Runner:EquippedSet()
  local set = {}
  for sid, s in ipairs(ns.SLOTS or {}) do
    local link = GetInventoryItemLink("player", s.invSlot)
    local e = ParseLink(link)
    if e then set[sid] = e end
  end
  return set
end

function Runner:BiSSet(phase, list)
  local BiS = ns.BiS
  local set = {}
  if not BiS then return set end
  for sid = 1, #(ns.SLOTS or {}) do
    local main = BiS:GetSlot(phase, sid, list)
    if main and main ~= 0 then
      local enchant, gems = BiS:GetGemSetup(main, list)
      local g = {}
      for i, v in pairs(gems or {}) do if v and v ~= 0 then g[i] = v end end
      set[sid] = { id = main, enchant = enchant or 0, gems = g }
    end
  end
  return set
end

function Runner:CopySet(set)
  local out = {}
  for sid, e in pairs(set or {}) do
    local g = {}
    for i, v in pairs(e.gems or {}) do g[i] = v end
    out[sid] = { id = e.id, enchant = e.enchant, gems = g }
  end
  return out
end

function Runner:SameEntry(a, b)
  if not a or not b then return (a == nil) == (b == nil) end
  if a.id ~= b.id or (a.enchant or 0) ~= (b.enchant or 0) then return false end
  for i = 1, 4 do if ((a.gems or {})[i] or 0) ~= ((b.gems or {})[i] or 0) then return false end end
  return true
end

-- Gems and an enchant for an item put into a set by hand: the spec guide's suggestion (as My BiS fills them), the
-- slot's old enchant when it still fits.
function Runner:FillEntry(itemID, sid, old)
  local e = { id = itemID, enchant = 0, gems = {} }
  local G = ns.Gems
  if not G then return e end
  local guide = G.GuideFor and G:GuideFor({ cl = self:Class(), sp = (ns.BiS and ns.BiS:GetSpec()) or "Retribution" })
  local phase = (ns.MyBiS and ns.MyBiS.GetPhase and ns.MyBiS:GetPhase()) or 1
  local ok, enchant, gems = pcall(G.Suggest, G, itemID, sid, guide, phase)
  if ok then
    e.enchant = tonumber(enchant) or 0
    for i, v in pairs(gems or {}) do if v and v ~= 0 then e.gems[i] = v end end
  end
  if old and (old.enchant or 0) ~= 0 and G.EnchantFitsItem and G:EnchantFitsItem(old.enchant, itemID) then
    e.enchant = old.enchant
  end
  return e
end

-- A My BiS pick with its gem setup from the list (else suggested like a new item).
function Runner:FillEntryFromBiS(itemID, phase, list, sid)
  local BiS = ns.BiS
  if BiS then
    local enchant, gems = BiS:GetGemSetup(itemID, list)
    local g, any = {}, (enchant or 0) ~= 0
    for i, v in pairs(gems or {}) do if v and v ~= 0 then g[i] = v; any = true end end
    if any then return { id = itemID, enchant = enchant or 0, gems = g } end
  end
  return self:FillEntry(itemID, sid)
end

-- Whether the head's meta gem is active (its colour rule) in a set.
function Runner:MetaActive(set)
  local G = ns.Gems
  local head = set[1]
  if not (G and head and head.gems) then return true end
  local meta
  for _, gid in pairs(head.gems) do
    local g = G:Gem(gid)
    if g and g.color == "M" then meta = gid end
  end
  if not meta then return true end
  local counts = { R = 0, Y = 0, B = 0 }
  local MIX = { R = "R", Y = "Y", B = "B", O = "RY", P = "RB", G = "YB", X = "RYB" }
  for _, e in pairs(set) do
    for _, gid in pairs(e.gems or {}) do
      local g = G:Gem(gid)
      local c = g and MIX[g.color]
      if c then for ch in c:gmatch(".") do counts[ch] = counts[ch] + 1 end end
    end
  end
  local ok = G:MetaState(meta, counts)
  return ok and true or false
end

-- Items of a set the sim has no data for (left out of the run: their stats and effects).
function Runner:UnknownItems(set)
  local db = self:DB()
  local out = {}
  for sid, e in pairs(set) do
    if e.id and not db.items[e.id] then out[#out + 1] = sid end
  end
  return out
end

function Runner:DB()
  self.db = self.db or S.GameDB()
  return self.db
end

function Runner:SpecKey()
  local spec = (ns.BiS and ns.BiS:GetSpec()) or ""
  return (self:Class() or "") .. ":" .. spec
end

function Runner:IsSupported(key)
  return self.SPECS[key or self:SpecKey()] and true or false
end

-- ---------------------------------------------------------------------------------------------------------------
-- Scenarios and runs
-- ---------------------------------------------------------------------------------------------------------------
function Runner:Scenario(set, settings)
  local gear = {}
  local db = self:DB()
  for sid = 1, 17 do
    local e = set[sid]
    if e and e.id and db.items[e.id] then
      gear[sid] = { id = e.id, enchant = (e.enchant ~= 0) and e.enchant or nil, gems = e.gems }
    end
  end
  local buffs = self:BuffConfig(settings.buffs)
  return {
    race = self:Race(), class = "Paladin", talents = settings.talents, gear = gear, metaActive = self:MetaActive(set),
    buffs = buffs, consumables = buffs.consumables, professions = settings.professions or self:Professions(),
    duration = settings.duration or 180, seed = settings.seed or 101, mobType = settings.mobType or "Mechanical",
    reactionTimeMs = 0, distance = 5,
  }
end

local clock = debugprofilestop or function() return os.clock() * 1000 end

local function InCombat()
  return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player"))
end

-- jobs: { { key = any, set = gear set }, ... }; opts: { iterations, settings, onProgress(done, total, paused),
-- onDone(results) }. results[key] = summary (S.Summarize) + iterDps; results.pairs(a, b) -> mean diff, stderr.
function Runner:Start(jobs, opts)
  self:Cancel()
  local settings = opts.settings or {}
  settings.seed = settings.seed or floor((GetTime and GetTime() or os.time()) * 1000) % 1000000
  local apl = ns.Data and ns.Data.SimAPL and ns.Data.SimAPL[self:SpecKey()]
  if not apl then return false, "No rotation for this spec yet." end
  local runs = {}
  local okAll, err = pcall(function()
    for i, job in ipairs(jobs) do
      local sim, p = S.NewScenario(self:Scenario(job.set, settings), self:DB(), apl)
      runs[i] = { key = job.key, sim = sim, p = p }
    end
  end)
  if not okAll then return false, tostring(err) end
  local n = opts.iterations or self.DEFAULT_ITERATIONS
  local run = { jobs = runs, n = n, done = 0, opts = opts, cancelled = false, nextJob = 1, nextIter = 1 }
  self.run = run
  local total = n * #runs
  local frame = self.frame or CreateFrame("Frame")
  self.frame = frame
  frame:SetScript("OnUpdate", function()
    if run.cancelled then frame:SetScript("OnUpdate", nil) return end
    if InCombat() then
      if opts.onProgress then opts.onProgress(run.done, total, true) end
      return
    end
    local t0 = clock()
    local ok, e = pcall(function()
      while run.nextIter <= n and clock() - t0 < self.FRAME_BUDGET_MS do
        local r = runs[run.nextJob]
        r.sim:RunOnce(run.nextIter)
        run.done = run.done + 1
        run.nextJob = run.nextJob + 1
        if run.nextJob > #runs then run.nextJob, run.nextIter = 1, run.nextIter + 1 end
      end
    end)
    if not ok then
      frame:SetScript("OnUpdate", nil)
      self.run = nil
      if opts.onDone then opts.onDone(nil, tostring(e)) end
      return
    end
    if opts.onProgress then opts.onProgress(run.done, total, false) end
    if run.nextIter > n then
      frame:SetScript("OnUpdate", nil)
      self.run = nil
      if opts.onDone then opts.onDone(self:Results(runs)) end
    end
  end)
  return true
end

function Runner:Cancel()
  if self.run then self.run.cancelled = true end
  self.run = nil
  if self.frame then self.frame:SetScript("OnUpdate", nil) end
end

function Runner:IsRunning() return self.run ~= nil end

-- Finished runs -> results by key; a paired difference between two keys (same iterations, same seeds).
function Runner:Results(runs)
  local out = {}
  for _, r in ipairs(runs) do
    local s = S.Summarize(r.sim, r.p)
    s.iterDps = r.p.metrics.iterDps
    s.stats = r.p.initialStats
    out[r.key] = s
  end
  out.diff = function(a, b)
    local A, B = out[a], out[b]
    if not (A and B) then return nil end
    local n = min(#A.iterDps, #B.iterDps)
    local sum, sq = 0, 0
    for i = 1, n do
      local d = A.iterDps[i] - B.iterDps[i]
      sum, sq = sum + d, sq + d * d
    end
    local mean = sum / n
    local var = max(0, sq / n - mean * mean)
    return mean, sqrt(var / max(1, n - 1))
  end
  return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- Ability names for the breakdown (metrics keys -> text)
-- ---------------------------------------------------------------------------------------------------------------
Runner.ABILITIES = {
  melee = "Melee", windfury = "Windfury", soc_proc = "Seal of Command", judge_soc = "Judgement of Command",
  [31893] = "Seal of Blood", [31898] = "Judgement of Blood", [35395] = "Crusader Strike",
  [27138] = "Exorcism", [27180] = "Hammer of Wrath",
  ["item:23827"] = "Explosives", ["item:10646"] = "Explosives", ["item:23737"] = "Explosives", ["item:23736"] = "Explosives",
}

-- The breakdown: { { name, dps } } merged by name, largest first.
function Runner:Breakdown(summary)
  local by, list = {}, {}
  for key, a in pairs(summary.abilities or {}) do
    if a.dps > 0 then
      local name = self.ABILITIES[key]
      if not name then
        local id = tonumber(key)
        name = (id and GetSpellInfo and GetSpellInfo(id)) or tostring(key)
      end
      if not by[name] then by[name] = { name = name, dps = 0 }; list[#list + 1] = by[name] end
      by[name].dps = by[name].dps + a.dps
    end
  end
  table.sort(list, function(x, y) return x.dps > y.dps end)
  return list
end
