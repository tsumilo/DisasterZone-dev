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

Runner.SPECS = { ["PALADIN:Retribution"] = true, ["WARRIOR:Fury"] = true, ["WARRIOR:Arms"] = true }
-- what the sim covers, for the texts that say so
Runner.COVERED = "Retribution Paladins and Fury / Arms Warriors"
-- class file -> the sim's class
Runner.CLASS_NAMES = { PALADIN = "Paladin", WARRIOR = "Warrior" }
-- WoWSims' class options (dps/presets.ts DefaultOptions)
Runner.CLASS_OPTIONS = {
  Warrior = { queueDelay = 0.25, startingRage = 50, defaultShout = "Battle", defaultStance = "Berserker",
    hasBsT2 = true, stanceSnapshot = true },
}
Runner.DEFAULT_ITERATIONS = 1000
Runner.FRAME_BUDGET_MS = 12

-- ---------------------------------------------------------------------------------------------------------------
-- Settings: buffs, fight length, boss type
-- ---------------------------------------------------------------------------------------------------------------
Runner.BUFFS = {
  { key = "raid25", text = "25-man buffs",
    tipWarrior = "WoWSims' Warrior raid setup: Bloodlust, drums, Windfury and Grace of Air (twisted), Strength of Earth, "
      .. "Leader of the Pack, Ferocious Inspiration, Braided Eternium Chain, Unleashed Rage, Kings and Might, Gift of the "
      .. "Wild, Fortitude, Sunder / Expose Armor, Faerie Fire, Curse of Recklessness, Blood Frenzy, Mangle, Gift of "
      .. "Arthas, Hunter's Mark, Expose Weakness; flask, food, scrolls, Haste Potion, Flame Cap, sharpening stone, "
      .. "explosives (Engineering). You shout yourself.",
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

-- A Warrior shouts himself: the group's Battle Shout goes (WoWSims would let his own win anyway).
local function WithoutShout(cfg)
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end
  local party = {}
  for k, v in pairs(cfg.party or {}) do if k ~= "battleShout" then party[k] = v end end
  out.party = party
  return out
end

-- WoWSims' three setups for the class: "raid25" | "raid10" | "solo".
function Runner:BaseConfig(key)
  local warrior = self:Class() == "WARRIOR"
  if key == "raid10" then return RAID10 end
  if key == "solo" then return SOLO end
  if warrior then return S.BUFF_PRESETS.wowsims_warrior end
  return S.BUFF_PRESETS.wowsims_ret
end

function Runner:IsBaseKey(key)
  return key == "raid25" or key == "raid10" or key == "solo"
end

-- The buff config of a buffs setting: WoWSims' three, a preset of mine ("p:<id>") or a team lineup ("t:<team>:<ln>",
-- ns.SimBuffs). A preset or lineup that is gone falls back to 25-man buffs.
function Runner:BuffConfig(key)
  local cfg
  if self:IsBaseKey(key) then
    cfg = self:BaseConfig(key)
  else
    local SB = ns.SimBuffs
    cfg = SB and (SB:Resolve(key, self:Class(), self:BaseConfig("raid25"))) or nil
    cfg = cfg or self:BaseConfig("raid25")
  end
  if self:Class() == "WARRIOR" then cfg = WithoutShout(cfg) end
  return cfg
end

-- The name the card shows for a buffs setting, and whether it still exists.
function Runner:BuffName(key)
  for _, b in ipairs(self.BUFFS) do if b.key == key then return b.text, true end end
  local SB = ns.SimBuffs
  local cfg, _, name = nil, nil, nil
  if SB then cfg, _, name = SB:Resolve(key, self:Class(), self:BaseConfig("raid25")) end
  if cfg then return name, true end
  return self.BUFFS[1].text, false
end

-- ---------------------------------------------------------------------------------------------------------------
-- The player
-- ---------------------------------------------------------------------------------------------------------------
function Runner:Race()
  local _, file = UnitRace("player")
  if file == "Scourge" then return "Undead" end
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
Runner.DEFAULT_TALENTS = {
  ["PALADIN:Retribution"] = "5-053201-0523005120033125331051",
  ["WARRIOR:Fury"] = "3400502130201-05050005505012050115",
  ["WARRIOR:Arms"] = "32005011352010500221-0550000500521203",
}

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
-- Keeps the set's meta gem on: when the gems just put into `entry` (in slot sid; free = { [socket] = true }) would
-- switch it off, those sockets get the cheapest gems that keep its rule (Gems:MeetMetaRule); others are left alone.
function Runner:KeepMetaActive(set, sid, entry, free)
  local G = ns.Gems
  if not (G and G.MeetMetaRule and entry and next(free or {})) then return entry end
  local trial = self:CopySet(set)
  trial[sid] = entry
  if self:MetaActive(trial) then return entry end
  local guide = G.GuideFor and G:GuideFor({ cl = self:Class(), sp = self:Spec() })
  if not guide then return entry end
  local phase = (ns.MyBiS and ns.MyBiS.GetPhase and ns.MyBiS:GetPhase()) or 1
  local setups, frees = {}, {}
  for s, e in pairs(trial) do
    if e.id and not setups[e.id] then
      local g = {}
      for i, v in pairs(e.gems or {}) do g[i] = v end
      setups[e.id] = { gems = g }
    end
  end
  frees[entry.id] = free
  local ok = G:MeetMetaRule(setups, frees, G:GuideData(guide, phase), phase,
    G.ProfessionSet and G:ProfessionSet() or {})
  if ok then
    local out = self:CopySet({ entry })[1]
    for i in pairs(free) do out.gems[i] = setups[entry.id].gems[i] end
    return out
  end
  return entry
end

-- The set's meta gem when its rule isn't met: gemID, what it needs (text). nil when it is on (or there is none).
function Runner:MetaOff(set)
  local G = ns.Gems
  local head = set[1]
  if not (G and head and head.gems) or self:MetaActive(set) then return nil end
  for _, gid in pairs(head.gems) do
    local g = G:Gem(gid)
    if g and g.color == "M" then
      local _, words = G:MetaState(gid, {})
      return gid, words
    end
  end
  return nil
end

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

-- The spec of the list My BiS shows (the off-spec list's when that one is open).
function Runner:Spec()
  local list = (ns.MyBiS and ns.MyBiS.GetList and ns.MyBiS:GetList() == "os") and "os" or nil
  return (ns.BiS and ns.BiS:GetSpec(list)) or ""
end

function Runner:SpecKey()
  return (self:Class() or "") .. ":" .. self:Spec()
end

-- Your own talents when you are specced into the spec being simmed, else WoWSims' standard build for it.
function Runner:Talents()
  local spec = self:Spec()
  if ns.BiS and ns.BiS.DetectSpec and ns.BiS:DetectSpec() == spec then
    local t = self:TalentString()
    if t and t:find("[1-5]") then return t, true end
  end
  return self.DEFAULT_TALENTS[self:SpecKey()], false
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
  local class = self.CLASS_NAMES[self:Class() or ""] or "Paladin"
  return {
    race = self:Race(), class = class, classOptions = self.CLASS_OPTIONS[class], talents = settings.talents, gear = gear,
    metaActive = self:MetaActive(set),
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
-- onDone(results), onCancel() }. results[key] = summary (S.Summarize) + iterDps; results.pairs(a, b) -> mean diff, stderr.
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
      -- at least one fight a frame, then as many as fit in the budget
      repeat
        local r = runs[run.nextJob]
        r.sim:RunOnce(run.nextIter)
        run.done = run.done + 1
        run.nextJob = run.nextJob + 1
        if run.nextJob > #runs then run.nextJob, run.nextIter = 1, run.nextIter + 1 end
      until run.nextIter > n or clock() - t0 >= self.FRAME_BUDGET_MS
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

-- Stops the run (a new Start stops the one before): its owner hears it through opts.onCancel.
function Runner:Cancel()
  local run = self.run
  if run then run.cancelled = true end
  self.run = nil
  if self.frame then self.frame:SetScript("OnUpdate", nil) end
  if run and run.opts.onCancel then run.opts.onCancel() end
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
  -- Warriors
  melee_oh = "Off-hand melee", melee_12281 = "Sword Specialization", flame_cap = "Flame Cap",
  [29707] = "Heroic Strike", [25231] = "Cleave", [30335] = "Bloodthirst", [30330] = "Mortal Strike",
  [25236] = "Execute", ["1680:1"] = "Whirlwind", ["1680:2"] = "Whirlwind", [11585] = "Overpower", [25242] = "Slam",
  [12867] = "Deep Wounds", [25212] = "Hamstring", [25208] = "Rend",
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

-- ---------------------------------------------------------------------------------------------------------------
-- WoWSims settings export: exactly what a run sims (gear, gems, enchants, race, talents, professions, buffs,
-- consumables, boss, rotation) as WoWSims' settings JSON (wowsims.com/tbc: Import > JSON), so both sims can be run
-- on the same input.
-- ---------------------------------------------------------------------------------------------------------------
local TRISTATE = {}
for _, k in ipairs({ "divineSpirit", "giftOfTheWild", "powerWordFortitude", "thorns", "manaSpringTotem",
  "leaderOfThePack", "battleShout", "strengthOfEarthTotem", "windfuryTotem", "graceOfAirTotem", "sanctityAura",
  "blessingOfWisdom", "blessingOfMight", "curseOfElements", "improvedSealOfTheCrusader", "huntersMark", "faerieFire",
  "exposeArmor", "demoralizingShout", "demoralizingRoar", "devotionAura", "retributionAura", "concentrationAura",
  "moonkinAura", "wrathOfAirTotem", "bloodPact", "commandingShout", "thunderClap" }) do TRISTATE[k] = true end
local TRI_NAMES = { [0] = "TristateEffectMissing", [1] = "TristateEffectRegular", [2] = "TristateEffectImproved" }

-- fields that are lists in WoWSims' protos (an empty one must stay [], an empty message {})
local LISTS = {}
for _, k in ipairs({ "vals", "actions", "groups", "priorityList", "prepullActions", "valueVariables", "variables",
  "items", "gems", "targets", "potions", "conjuredItems", "stats", "cooldowns" }) do LISTS[k] = true end

local function JStr(s)
  return '"' .. tostring(s):gsub('[%c"\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\n" end
    return ("\u%04x"):format(c:byte())
  end) .. '"'
end

local function Encode(v, key, out)
  local tv = type(v)
  if tv == "table" then
    local isList = LISTS[key] or v[1] ~= nil
    if isList then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        Encode(v[i], nil, out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = JStr(k) .. ":"
        local x = v[k]
        if x == nil then x = v[tonumber(k)] end
        Encode(x, k, out)
      end
      out[#out + 1] = "}"
    end
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    out[#out + 1] = (v == floor(v) and math.abs(v) < 1e15) and ("%d"):format(v) or ("%.10g"):format(v)
  elseif v == nil then
    out[#out + 1] = "null"
  else
    out[#out + 1] = JStr(v)
  end
end
Runner.EncodeSettings = function(t)
  local out = {}
  Encode(t, nil, out)
  return table.concat(out)
end

local function ProtoBuffs(t)
  local o = {}
  for k, v in pairs(t or {}) do
    if TRISTATE[k] then
      local n = (v == true) and 1 or (tonumber(v) or 0)
      if n > 0 then o[k] = TRI_NAMES[n] end
    elseif v ~= false and v ~= 0 then
      o[k] = v
    end
  end
  return o
end

-- class -> WoWSims player spec field and options
Runner.WOWSIMS_SPEC = {
  Paladin = { class = "ClassPaladin", field = "retributionPaladin", options = { options = { classOptions = {} } } },
  Warrior = { class = "ClassWarrior", field = "dpsWarrior", options = { options = { classOptions = {
    queueDelay = 250, startingRage = 50, defaultShout = "WarriorShoutBattle", defaultStance = "WarriorStanceBerserker",
    hasBsT2 = true, stanceSnapshot = true } } } },
}

-- set: a gear set; settings: as for Start. Returns the JSON text.
function Runner:WoWSimsSettings(set, settings)
  local sc = self:Scenario(set, settings)
  local ws = self.WOWSIMS_SPEC[sc.class] or self.WOWSIMS_SPEC.Paladin
  local items = {}
  for sid = 1, 17 do
    local g = sc.gear[sid]
    local it = {}
    if g then
      it.id = g.id
      if g.enchant and g.enchant ~= 0 then it.enchant = g.enchant end
      local gems, last = {}, 0
      for i = 1, 4 do if g.gems and g.gems[i] and g.gems[i] ~= 0 then last = i end end
      for i = 1, last do gems[i] = (g.gems and g.gems[i]) or 0 end
      if last > 0 then it.gems = gems end
    end
    items[sid] = it
  end
  local cons = {}
  for k, v in pairs(sc.consumables or {}) do cons[k] = v end
  if cons.potId then cons.potions = { cons.potId } end
  if cons.conjuredId then cons.conjuredItems = { cons.conjuredId } end
  local profs = sc.professions or {}
  local race = sc.race == "Scourge" and "Undead" or sc.race
  local stats = {}
  for i = 1, 60 do stats[i] = 0 end
  stats[31 + 1] = sc.targetArmor or 7685   -- StatArmor
  stats[17 + 1] = 320                      -- StatAttackPower
  local player = {
    name = UnitName and UnitName("player") or "Player",
    race = "Race" .. race, class = ws.class,
    equipment = { items = items },
    consumables = cons,
    buffs = ProtoBuffs(sc.buffs.individual),
    talentsString = sc.talents or "",
    profession1 = profs[1], profession2 = profs[2],
    rotation = ns.Data and ns.Data.SimAPL and ns.Data.SimAPL[self:SpecKey()],
    reactionTimeMs = sc.reactionTimeMs or 0,
    distanceFromTarget = sc.distance or 5,
  }
  player[ws.field] = ws.options
  local doc = {
    apiVersion = 15,
    player = player,
    raidBuffs = ProtoBuffs(sc.buffs.raid),
    partyBuffs = ProtoBuffs(sc.buffs.party),
    debuffs = ProtoBuffs(sc.buffs.debuffs),
    encounter = {
      apiVersion = 15, duration = sc.duration, durationVariation = 0, executeProportion20 = 0.2,
      executeProportion25 = 0.25, executeProportion35 = 0.35, executeProportion45 = 0.45, executeProportion90 = 0.9,
      targets = { { level = 73, mobType = "MobType" .. (sc.mobType or "Mechanical"), swingSpeed = 2,
        minBaseDamage = 15113, parryHaste = true, canCrush = true, damageSpread = 0.5, stats = stats } },
    },
    settings = { iterations = 10000, randomSeed = settings.seed or 101 },
  }
  return self.EncodeSettings(doc)
end
