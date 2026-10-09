if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Unit.lua", ...) then return end -- DisasterZone: Sim/Unit.lua
-- ns.GearSim units: stats with WoWSims' dependency system (stats/deps.go: one fixed order, attributes floored),
-- pseudo stats, haste, mana, auras and their callback lists (aura.go), GCD / rotation timers (gcd.go).
local _, ns = ...
local S = ns.GearSim

local floor, huge, max, min, sqrt = math.floor, math.huge, math.max, math.min, math.sqrt

-- ---------------------------------------------------------------------------------------------------------------
-- Stats. Names follow WoWSims' stats.Stat; only the ones the port uses.
-- ---------------------------------------------------------------------------------------------------------------
local STAT_NAMES = {
  "Strength", "Agility", "Stamina", "Intellect", "Spirit", "BonusArmor", "Armor", "FeralAttackPower",
  "AttackPower", "RangedAttackPower", "SpellDamage", "HealingPower", "Health", "Mana", "MP5",
  "MeleeHasteRating", "MeleeCritRating", "MeleeHitRating", "SpellHitRating", "SpellCritRating", "SpellHasteRating",
  "BlockPercent", "DodgeRating", "ParryRating", "ExpertiseRating", "BlockValue", "ArmorPenetration",
  "SpellPenetration", "SpellCritPercent", "PhysicalCritPercent", "SpellHitPercent", "PhysicalHitPercent",
  -- Not part of the dependency order:
  "DefenseRating", "ResilienceRating", "PhysicalDamage", "ArcaneDamage", "FireDamage", "FrostDamage",
  "HolyDamage", "NatureDamage", "ShadowDamage", "RangedCritPercent", "RangedHitPercent",
  "ArcaneResistance", "FireResistance", "FrostResistance", "NatureResistance", "ShadowResistance",
}
local ST = {}
for i, n in ipairs(STAT_NAMES) do ST[n] = i end
S.ST, S.STAT_NAMES, S.NUM_STATS = ST, STAT_NAMES, #STAT_NAMES
local NUM_STATS = #STAT_NAMES
local DEP_ORDER_LEN = ST.PhysicalHitPercent -- the first 32 entries are deps/stats.go safeDepsOrder, in order

-- Rating conversions (base_stats_auto_gen.go).
S.EXPERTISE_PER_QUARTER = 3.942308
S.DEFENSE_RATING_PER_LEVEL = 2.365385
S.DODGE_RATING_PER_PCT = 18.923079
S.PARRY_RATING_PER_PCT = 23.653847
S.HIT_RATING_PER_PCT = 15.769233
S.SPELL_HIT_RATING_PER_PCT = 12.615385
S.CRIT_RATING_PER_PCT = 22.076923
S.HASTE_RATING_PER_PCT = 15.769233
S.SPELL_HASTE_RATING_PER_PCT = 15.76923

local FLOORED = { [ST.Strength] = true, [ST.Agility] = true, [ST.Stamina] = true, [ST.Intellect] = true, [ST.Spirit] = true }

function S.NewStats(init)
  local s = {}
  for i = 1, NUM_STATS do s[i] = 0 end
  if init then for k, v in pairs(init) do s[type(k) == "string" and ST[k] or k] = v end end
  return s
end
local NewStats = S.NewStats

local function CopyStats(dst, src)
  for i = 1, NUM_STATS do dst[i] = src[i] end
  return dst
end
S.CopyStats = CopyStats

-- ---------------------------------------------------------------------------------------------------------------
-- Unit
-- ---------------------------------------------------------------------------------------------------------------
local Unit = {}
Unit.__index = Unit
S.UnitMT = Unit

function S.NewUnit(kind, label)
  local u = setmetatable({
    kind = kind, -- "player" | "enemy"
    label = label,
    level = 70,
    stats = NewStats(),
    statsWithoutDeps = NewStats(),
    deps = {},           -- registered dependencies (sorted at Finalize)
    sortedDeps = nil,
    ps = S.NewPseudoStats(),
    auras = {},          -- every registered aura
    activeAuras = {},    -- active auras with a finite duration
    onSpellHitDealt = {}, onSpellHitTaken = {}, onPeriodicDamageDealt = {}, onCastComplete = {},
    onApplyEffects = {}, onEncounterStart = {},
    minExpires = huge,
    spellbook = {},
    spellRegistered = {}, -- handlers (spell mods) run for every registered spell
    resetEffects = {},
    attackTables = {},
    reactionTime = 0.010,
    GCD = S.NewTimer(),
    RotationTimer = S.NewTimer(),
    hardcastExpires = -huge,
    castSpeed = 1,
    enabled = true,
    distance = 5,
    mobType = "Mechanical",
    onAttackSpeedChanged = {},
  }, Unit)
  return u
end

function S.NewPseudoStats()
  return {
    DamageDealtMultiplier = 1,
    SchoolDamageDealtMultiplier = { 1, 1, 1, 1, 1, 1, 1, 1 },
    DamageTakenMultiplier = 1,
    SchoolDamageTakenMultiplier = { 1, 1, 1, 1, 1, 1, 1, 1 },
    PeriodicPhysicalDamageTakenMultiplier = 1,
    BonusPhysicalDamageTaken = 0,
    BonusSpellDamageTaken = 0,
    SchoolBonusSpellDamage = { 0, 0, 0, 0, 0, 0, 0, 0 },
    SchoolBonusHitChance = { 0, 0, 0, 0, 0, 0, 0, 0 },
    BonusAttackPower = 0,         -- on a target: extra AP for attackers (Hunter's Mark, Expose Weakness)
    BonusRangedAttackPower = 0,
    ReducedCritTakenPercent = 0,
    ReducedPhysicalHitTakenChance = 0,
    CritDamageMultiplier = 1,
    ThreatMultiplier = 1,
    AttackSpeedMultiplier = 1,
    MeleeSpeedMultiplier = 1,
    RangedSpeedMultiplier = 1,
    RangedHasteMultiplier = 1,
    CastSpeedMultiplier = 1,
    ArmorMultiplier = 1,
    SpellCostPercentModifier = 100,
    SpiritRegenMultiplier = 1,
    SpiritRegenRateCasting = 0,
    ForceFullSpiritRegen = false,
    FiveSecondRuleRefreshTime = 0,
    DotDamageMultiplierAdditive = 1,
    BonusMHDps = 0, BonusOHDps = 0, BonusRangedDps = 0,
    DodgeReduction = 0,
    InFrontOfTarget = false,
    DisableDWMissPenalty = false,
    Stunned = false,
    CanBlock = false, CanParry = false,
    IncreasedMissChance = 0,
    BlockValueMultiplier = 1,
  }
end

local function DeepCopy(t)
  local c = {}
  for k, v in pairs(t) do
    if type(v) == "table" then c[k] = DeepCopy(v) else c[k] = v end
  end
  return c
end
S.DeepCopy = DeepCopy

function Unit:Stat(i) return self.stats[i] end

-- Build-phase stat changes (before Finalize).
function Unit:AddStat(i, v)
  if type(i) == "string" then i = ST[i] end
  self.stats[i] = self.stats[i] + v
end

function Unit:AddStats(t)
  for k, v in pairs(t) do self:AddStat(k, v) end
end

function Unit:AddStatDependency(src, dst, amount)
  self.deps[#self.deps + 1] = { src = src, dst = dst, amount = amount, enabled = true }
end

function Unit:MultiplyStat(s, amount)
  self.deps[#self.deps + 1] = { src = s, dst = s, amount = amount, enabled = true }
end

function Unit:NewDynamicStatDependency(src, dst, amount)
  local d = { src = src, dst = dst, amount = amount, enabled = false, dynamic = true }
  self.deps[#self.deps + 1] = d
  return d
end

function Unit:NewDynamicMultiplyStat(s, amount)
  return self:NewDynamicStatDependency(s, s, amount)
end

-- deps.go sortDeps: for every (src, dst) pair in dependency order, dynamic deps in registration order, then the
-- static ones combined (multiplied for src == dst, summed otherwise).
local function SortDeps(deps)
  local out = {}
  for si = 1, DEP_ORDER_LEN do
    for di = si, DEP_ORDER_LEN do
      local start = (si == di) and 1 or 0
      local amount = start
      for _, d in ipairs(deps) do
        if d.src == si and d.dst == di then
          if d.dynamic then
            out[#out + 1] = d
          elseif si == di then
            amount = amount * d.amount
          else
            amount = amount + d.amount
          end
        end
      end
      if amount ~= start then
        out[#out + 1] = { src = si, dst = di, amount = amount, enabled = true }
      end
    end
  end
  return out
end

local function ApplyDeps(sorted, s)
  for i = 1, #sorted do
    local d = sorted[i]
    if d.enabled then
      if d.src == d.dst then
        s[d.dst] = s[d.dst] * d.amount
      elseif FLOORED[d.src] then
        s[d.dst] = s[d.dst] + floor(s[d.src]) * d.amount
      else
        s[d.dst] = s[d.dst] + s[d.src] * d.amount
      end
    end
  end
  for k in pairs(FLOORED) do s[k] = floor(s[k]) end
  return s
end
S.ApplyDeps = ApplyDeps

-- Called once after gear, buffs and talents have added their build-phase stats (unit.go finalize).
function Unit:Finalize()
  self:AddStatDependency(ST.MeleeHitRating, ST.PhysicalHitPercent, 1 / S.HIT_RATING_PER_PCT)
  self:AddStatDependency(ST.SpellHitRating, ST.SpellHitPercent, 1 / S.SPELL_HIT_RATING_PER_PCT)
  self:AddStatDependency(ST.MeleeCritRating, ST.PhysicalCritPercent, 1 / S.CRIT_RATING_PER_PCT)
  self:AddStatDependency(ST.SpellCritRating, ST.SpellCritPercent, 1 / S.CRIT_RATING_PER_PCT)
  self.initialStatsWithoutDeps = CopyStats(NewStats(), self.stats)
  self.initialPS = DeepCopy(self.ps)
  self.sortedDeps = SortDeps(self.deps)
  self.initialStats = ApplyDeps(self.sortedDeps, CopyStats(NewStats(), self.initialStatsWithoutDeps))
  self.statsWithoutDeps = CopyStats(NewStats(), self.initialStatsWithoutDeps)
  self.stats = CopyStats(NewStats(), self.initialStats)
  self.finalized = true
end

local scratch = nil
local delta = nil

-- unit.go addStatsDynamic recomputes the whole total from the dependency-free stats (attributes are floored).
-- A change that touches no attribute (Str/Agi/Sta/Int/Spi) can't move a floor, and every other dependency is
-- linear, so it is propagated through precomputed factors instead: same totals, a fraction of the work.
local REGEN, MANA, MHASTE, SHASTE = ST.MP5, ST.Mana, ST.MeleeHasteRating, ST.SpellHasteRating

-- For stat `src` (not an attribute): the list { dst1, f1, dst2, f2, ... } of total changes per point.
function Unit:LinearFactors(src)
  local cache = self.linearCache
  if not cache then cache = {}; self.linearCache = cache end
  local l = cache[src]
  if l then return l end
  local v = {}
  for i = 1, NUM_STATS do v[i] = 0 end
  v[src] = 1
  local sorted = self.sortedDeps
  for i = 1, #sorted do
    local d = sorted[i]
    if d.enabled then
      if d.src == d.dst then v[d.dst] = v[d.dst] * d.amount else v[d.dst] = v[d.dst] + v[d.src] * d.amount end
    end
  end
  l = {}
  local flags = 0
  for i = 1, NUM_STATS do
    if v[i] ~= 0 then
      l[#l + 1] = i
      l[#l + 1] = v[i]
    end
  end
  l.regen = v[REGEN] ~= 0 or v[ST.Intellect] ~= 0 or v[ST.Spirit] ~= 0
  l.mana = v[MANA] ~= 0
  l.mhaste = v[MHASTE] ~= 0
  l.shaste = v[SHASTE] ~= 0
  cache[src] = l
  return l
end

local function AddLinear(self, stat, amount)
  local l = self:LinearFactors(stat)
  local st = self.stats
  for i = 1, #l, 2 do
    local dst = l[i]
    st[dst] = st[dst] + amount * l[i + 1]
  end
  return l
end

function Unit:AddStatsDynamic(sim, bonus)
  local swd = self.statsWithoutDeps
  local attr = false
  for k in pairs(bonus) do if FLOORED[k] then attr = true; break end end
  if attr then
    for k, v in pairs(bonus) do swd[k] = swd[k] + v end
    self:RecomputeStats(sim)
    return
  end
  local regen, mana, mh, sh = false, false, false, false
  for k, v in pairs(bonus) do
    swd[k] = swd[k] + v
    local l = AddLinear(self, k, v)
    regen = regen or l.regen; mana = mana or l.mana; mh = mh or l.mhaste; sh = sh or l.shaste
  end
  self:ReactToStatChange(sim, regen, mana, mh, sh)
end

function Unit:AddStatDynamic(sim, stat, amount)
  local swd = self.statsWithoutDeps
  swd[stat] = swd[stat] + amount
  if FLOORED[stat] then
    self:RecomputeStats(sim)
    return
  end
  local l = AddLinear(self, stat, amount)
  self:ReactToStatChange(sim, l.regen, l.mana, l.mhaste, l.shaste)
end

function Unit:ReactToStatChange(sim, regen, mana, mhaste, shaste)
  if regen then self:UpdateManaRegenRates() end
  if mana and self.hasMana and self.mana > self.stats[MANA] then self.mana = self.stats[MANA] end
  if mhaste and self.autoAttacks then self.autoAttacks:UpdateSwingTimers(sim) end
  if shaste then self:UpdateCastSpeed() end
end

function Unit:RecomputeStats(sim)
  scratch = scratch or NewStats()
  delta = delta or NewStats()
  CopyStats(scratch, self.statsWithoutDeps)
  ApplyDeps(self.sortedDeps, scratch)
  local old = self.stats
  for i = 1, NUM_STATS do
    delta[i] = scratch[i] - old[i]
    old[i] = scratch[i]
  end
  self:ProcessDynamicBonus(sim, delta)
end

function Unit:EnableDynamicStatDep(sim, dep)
  if not dep.enabled then
    dep.enabled = true
    self.linearCache = nil
    self:RecomputeStats(sim)
  end
end

function Unit:DisableDynamicStatDep(sim, dep)
  if dep.enabled then
    dep.enabled = false
    self.linearCache = nil
    self:RecomputeStats(sim)
  end
end

function Unit:ProcessDynamicBonus(sim, b)
  if b[ST.MP5] ~= 0 or b[ST.Intellect] ~= 0 or b[ST.Spirit] ~= 0 then self:UpdateManaRegenRates() end
  if b[ST.Mana] ~= 0 and self.hasMana then
    if self.mana > self.stats[ST.Mana] then self.mana = self.stats[ST.Mana] end
  end
  if b[ST.MeleeHasteRating] ~= 0 then
    if self.autoAttacks then self.autoAttacks:UpdateSwingTimers(sim) end
  end
  if b[ST.SpellHasteRating] ~= 0 then self:UpdateCastSpeed() end
end

-- Haste (unit.go)
function Unit:TotalMeleeHasteMultiplier()
  local ps = self.ps
  return ps.AttackSpeedMultiplier * ps.MeleeSpeedMultiplier * (1 + self.stats[ST.MeleeHasteRating] / (S.HASTE_RATING_PER_PCT * 100))
end

function Unit:TotalSpellHasteMultiplier()
  return self.ps.CastSpeedMultiplier * (1 + self.stats[ST.SpellHasteRating] / (S.SPELL_HASTE_RATING_PER_PCT * 100))
end

function Unit:UpdateCastSpeed()
  self.castSpeed = 1 / self:TotalSpellHasteMultiplier()
end

function Unit:MultiplyCastSpeed(sim, amount)
  self.ps.CastSpeedMultiplier = self.ps.CastSpeedMultiplier * amount
  self:UpdateCastSpeed()
end

function Unit:MultiplyMeleeSpeed(sim, amount)
  self.ps.MeleeSpeedMultiplier = self.ps.MeleeSpeedMultiplier * amount
  if self.autoAttacks then self.autoAttacks:UpdateSwingTimers(sim) end
end

function Unit:MultiplyAttackSpeed(sim, amount)
  self.ps.AttackSpeedMultiplier = self.ps.AttackSpeedMultiplier * amount
  if self.autoAttacks then self.autoAttacks:UpdateSwingTimers(sim) end
end

-- Durations rounded to the millisecond, as cast.go does for hasted GCDs and cast times.
local function RoundMs(t) return floor(t * 1000 + 0.5) / 1000 end
S.RoundMs = RoundMs

function Unit:ApplyCastSpeed(d) return d * self.castSpeed end

function Unit:SpellGCD() return max(S.GCD_MIN, self:ApplyCastSpeed(S.GCD_DEFAULT)) end

function Unit:Armor() return self.ps.ArmorMultiplier * self.stats[ST.Armor] end

-- ---------------------------------------------------------------------------------------------------------------
-- Mana (mana.go)
-- ---------------------------------------------------------------------------------------------------------------
function Unit:EnableManaBar(baseMana)
  self.hasMana = true
  self.baseMana = baseMana
  self.mana = 0
  self.manaRegenMultiplier = 1
end

function Unit:MaxMana() return self.stats[ST.Mana] end

function Unit:AddMana(sim, amount, metric)
  if amount < 0 then error("negative mana") end
  local old = self.mana
  local new = min(old + amount, self.stats[ST.Mana])
  self.mana = new
  if metric and self.metrics then self.metrics:ManaGain(metric, new - old) end
end

function Unit:SpendMana(sim, amount)
  self.mana = self.mana - amount
end

function Unit:SpiritRegenPerSecond()
  return 0.001 + self.stats[ST.Spirit] * sqrt(self.stats[ST.Intellect]) * 0.009327
end

function Unit:UpdateManaRegenRates()
  if not self.hasMana then return end
  local ps = self.ps
  local mp5 = self.stats[ST.MP5] / 5
  local casting = mp5
  if ps.SpiritRegenRateCasting ~= 0 or ps.ForceFullSpiritRegen then
    local sp = self:SpiritRegenPerSecond() * ps.SpiritRegenMultiplier
    if not ps.ForceFullSpiritRegen then sp = sp * ps.SpiritRegenRateCasting end
    casting = casting + sp
  end
  casting = casting * self.manaRegenMultiplier
  local notCasting = (mp5 + self:SpiritRegenPerSecond() * ps.SpiritRegenMultiplier) * self.manaRegenMultiplier
  self.manaTickCasting = casting * 2
  self.manaTickNotCasting = notCasting * 2
end

function Unit:ManaTick(sim)
  if sim.now < self.ps.FiveSecondRuleRefreshTime then
    self:AddMana(sim, max(0, self.manaTickCasting), "regen")
  else
    self:AddMana(sim, max(0, self.manaTickNotCasting), "regen")
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Auras (aura.go). An aura: { label, duration, maxStacks, onGain, onExpire, onStacksChange, onReset,
-- onSpellHitDealt, onSpellHitTaken, onPeriodicDamageDealt, onCastComplete, onApplyEffects, onEncounterStart }.
-- ---------------------------------------------------------------------------------------------------------------
local Aura = {}
Aura.__index = Aura
S.AuraMT = Aura

local CALLBACK_LISTS = {
  "onApplyEffects", "onCastComplete", "onSpellHitDealt", "onSpellHitTaken", "onPeriodicDamageDealt", "onEncounterStart",
}

function Unit:RegisterAura(cfg)
  local a = setmetatable(cfg, Aura)
  a.unit = self
  a.active = false
  a.stacks = 0
  a.expires = 0
  a.startTime = 0
  a.duration = a.duration or huge
  self.auras[#self.auras + 1] = a
  if a.label then self.aurasByLabel = self.aurasByLabel or {}; self.aurasByLabel[a.label] = a end
  return a
end

function Unit:GetAura(label) return self.aurasByLabel and self.aurasByLabel[label] end

function Aura:IsActive() return self.active end

function Aura:Refresh(sim)
  if self.duration == huge then
    self.expires = huge
  else
    self.expires = sim.now + self.duration
    local u = self.unit
    if self.expires < u.minExpires then
      u.minExpires = self.expires
      sim:RescheduleTracker(self.expires)
    end
  end
end

local function RemoveFromList(list, a)
  for i = 1, #list do
    if list[i] == a then
      -- Go removes by swapping the last element into the hole; order matters for callback order.
      local n = #list
      list[i] = list[n]
      list[n] = nil
      return
    end
  end
end

function Aura:Activate(sim)
  if self.metricsProcs then self.metricsProcs = self.metricsProcs + 1 end
  if self.active then
    self:Refresh(sim)
    return
  end
  if self.exclusive then
    for i, ee in ipairs(self.exclusive) do
      if not ee:Activate(sim) then
        for j = 1, i - 1 do self.exclusive[j]:Deactivate(sim) end
        return
      end
    end
  end
  self.active = true
  self.startTime = sim.now
  self:Refresh(sim)
  local u = self.unit
  if self.duration ~= huge then u.activeAuras[#u.activeAuras + 1] = self end
  for i = 1, #CALLBACK_LISTS do
    local name = CALLBACK_LISTS[i]
    if self[name] then
      local l = u[name]
      l[#l + 1] = self
    end
  end
  if self.onGain then self.onGain(self, sim) end
end

function Aura:Deactivate(sim)
  if not self.active then return end
  self.active = false
  if self.uptime then
    local endAt = (sim.now > self.expires) and self.expires or sim.now
    self.uptime = self.uptime + endAt - max(self.startTime, 0)
  end
  self.expires = 0
  self.fadeTime = sim.now
  local u = self.unit
  if self.duration ~= huge then RemoveFromList(u.activeAuras, self) end
  for i = 1, #CALLBACK_LISTS do
    local name = CALLBACK_LISTS[i]
    if self[name] then RemoveFromList(u[name], self) end
  end
  if self.stacks ~= 0 then self:SetStacks(sim, 0) end
  if self.exclusive then
    for _, ee in ipairs(self.exclusive) do ee:Deactivate(sim) end
  end
  if self.onExpire then self.onExpire(self, sim) end
end

function Aura:SetStacks(sim, n)
  if not self.active and n ~= 0 then error("stacks on inactive aura " .. tostring(self.label)) end
  local old = self.stacks
  if n > self.maxStacks then n = self.maxStacks end
  if old == n then return end
  self.stacks = n
  if self.onStacksChange then self.onStacksChange(self, sim, old, n) end
  if self.stacks == 0 then self:Deactivate(sim) end
end

function Aura:AddStack(sim) self:SetStacks(sim, self.stacks + 1) end
function Aura:RemoveStack(sim) self:SetStacks(sim, max(0, self.stacks - 1)) end

function Aura:RemainingDuration(sim)
  if not self.active then return 0 end
  if self.expires == huge then return huge end
  return self.expires - sim.now
end

-- aura.go auraTracker.advance: expire everything due, then report the next expiry.
function Unit:AdvanceAuras(sim)
  if sim.now < self.minExpires then return self.minExpires end
  local restart = true
  while restart do
    restart = false
    self.minExpires = huge
    local list = self.activeAuras
    for i = 1, #list do
      local a = list[i]
      if a.expires <= sim.now then
        a:Deactivate(sim)
        restart = true -- activeAuras changed
        break
      end
      if a.expires < self.minExpires then self.minExpires = a.expires end
    end
  end
  return self.minExpires
end

-- Aura helpers (aura_helpers.go)
function Aura:AttachStatBuff(stat, amount)
  local og, oe = self.onGain, self.onExpire
  self.onGain = function(a, sim)
    a.unit:AddStatDynamic(sim, stat, amount)
    if og then og(a, sim) end
  end
  self.onExpire = function(a, sim)
    a.unit:AddStatDynamic(sim, stat, -amount)
    if oe then oe(a, sim) end
  end
  return self
end

function Aura:AttachStatsBuff(bonus)
  local neg = {}
  for k, v in pairs(bonus) do neg[k] = -v end
  local og, oe = self.onGain, self.onExpire
  self.onGain = function(a, sim)
    a.unit:AddStatsDynamic(sim, bonus)
    if og then og(a, sim) end
  end
  self.onExpire = function(a, sim)
    a.unit:AddStatsDynamic(sim, neg)
    if oe then oe(a, sim) end
  end
  return self
end

-- Multiplies a pseudo stat (dotted path within ps, e.g. "DamageDealtMultiplier" or {"SchoolDamageDealtMultiplier", 3}).
function Aura:AttachMultiplicativePseudoStatBuff(field, amount, index)
  local og, oe = self.onGain, self.onExpire
  self.onGain = function(a, sim)
    local ps = a.unit.ps
    if index then ps[field][index] = ps[field][index] * amount else ps[field] = ps[field] * amount end
    if og then og(a, sim) end
  end
  self.onExpire = function(a, sim)
    local ps = a.unit.ps
    if index then ps[field][index] = ps[field][index] / amount else ps[field] = ps[field] / amount end
    if oe then oe(a, sim) end
  end
  return self
end

function Aura:AttachAdditivePseudoStatBuff(field, amount, index)
  local og, oe = self.onGain, self.onExpire
  self.onGain = function(a, sim)
    local ps = a.unit.ps
    if index then ps[field][index] = ps[field][index] + amount else ps[field] = ps[field] + amount end
    if og then og(a, sim) end
  end
  self.onExpire = function(a, sim)
    local ps = a.unit.ps
    if index then ps[field][index] = ps[field][index] - amount else ps[field] = ps[field] - amount end
    if oe then oe(a, sim) end
  end
  return self
end

function Aura:AttachMultiplyMeleeSpeed(amount)
  local og, oe = self.onGain, self.onExpire
  self.onGain = function(a, sim)
    a.unit:MultiplyMeleeSpeed(sim, amount)
    if og then og(a, sim) end
  end
  self.onExpire = function(a, sim)
    a.unit:MultiplyMeleeSpeed(sim, 1 / amount)
    if oe then oe(a, sim) end
  end
  return self
end

function Aura:AttachMultiplyAttackSpeed(amount)
  local og, oe = self.onGain, self.onExpire
  self.onGain = function(a, sim)
    a.unit:MultiplyAttackSpeed(sim, amount)
    if og then og(a, sim) end
  end
  self.onExpire = function(a, sim)
    a.unit:MultiplyAttackSpeed(sim, 1 / amount)
    if oe then oe(a, sim) end
  end
  return self
end

function Aura:AttachSpellMod(cfg)
  local mod = self.unit:AddDynamicMod(cfg)
  local og, oe = self.onGain, self.onExpire
  self.onGain = function(a, sim)
    mod:Activate()
    if og then og(a, sim) end
  end
  self.onExpire = function(a, sim)
    mod:Deactivate()
    if oe then oe(a, sim) end
  end
  return self
end

-- A permanent aura that switches itself on at every reset (MakePermanent).
function S.MakePermanent(a)
  a.duration = huge
  local old = a.onReset
  a.onReset = function(aura, sim)
    if old then old(aura, sim) end
    aura:Activate(sim)
  end
  return a
end

-- ---------------------------------------------------------------------------------------------------------------
-- Exclusive effects (exclusive_effect.go): buffs of one category don't stack; the strongest active one applies.
-- ---------------------------------------------------------------------------------------------------------------
function Unit:GetExclusiveCategory(name)
  self.exclusiveCategories = self.exclusiveCategories or {}
  local c = self.exclusiveCategories[name]
  if not c then
    c = { name = name, effects = {}, active = nil }
    self.exclusiveCategories[name] = c
  end
  return c
end

-- ee = { category, priority, onGain(ee, sim), onExpire(ee, sim), aura, isEnabled } (exclusive_effect.go)
local EE = {}
EE.__index = EE
local NOOP = function() end

function Aura:NewExclusiveEffect(categoryName, singleAura, priority, onGain, onExpire)
  local cat = self.unit:GetExclusiveCategory(categoryName)
  cat.singleAura = singleAura
  for _, e in ipairs(cat.effects) do if e.aura == self then return e end end
  local ee = setmetatable({ category = cat, priority = priority, onGain = onGain or NOOP, onExpire = onExpire or NOOP,
    aura = self, isEnabled = false }, EE)
  cat.effects[#cat.effects + 1] = ee
  self.exclusive = self.exclusive or {}
  self.exclusive[#self.exclusive + 1] = ee
  return ee
end

local function SetActive(cat, sim, e)
  if e == cat.active then return end
  if cat.active then cat.active.onExpire(cat.active, sim) end
  cat.active = e
  if e then e.onGain(e, sim) end
end

local function HighestEnabled(cat)
  local best
  for _, e in ipairs(cat.effects) do
    if e.isEnabled and (not best or e.priority > best.priority) then best = e end
  end
  return best
end

function EE:IsActive() return self.category.active == self end

-- Returns false when a single-aura category already holds a stronger effect (the aura is then blocked).
function EE:Activate(sim)
  if self.isEnabled then return true end
  local cat = self.category
  local cur = cat.active
  if cat.singleAura and cur and cur ~= self and (cur.priority > self.priority or
      (self.priority == cur.priority and cur.aura:RemainingDuration(sim) > self.aura.duration)) then
    return false
  end
  self.isEnabled = true
  if not cur then
    SetActive(cat, sim, self)
  elseif self.priority >= cur.priority then
    if cat.singleAura and cur ~= self then cur.aura:Deactivate(sim) end
    SetActive(cat, sim, self)
  end
  return true
end

function EE:Deactivate(sim)
  if not self.isEnabled then return end
  self.isEnabled = false
  local cat = self.category
  if cat.active == self then SetActive(cat, sim, HighestEnabled(cat)) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Callback dispatch (aura.go auraTracker.OnSpellHitDealt etc.): skip auras deactivated mid-iteration.
-- ---------------------------------------------------------------------------------------------------------------
-- Go ranges over the slice as it was when the event started: auras gained during the event don't hear it, auras
-- lost during it are skipped. Iterate a snapshot (one reusable buffer per nesting depth).
local buffers, depth = {}, 0
local function Dispatch(list, name, sim, spell, result)
  local n = #list
  if n == 0 then return end
  depth = depth + 1
  local buf = buffers[depth]
  if not buf then buf = {}; buffers[depth] = buf end
  for i = 1, n do buf[i] = list[i] end
  for i = 1, n do
    local a = buf[i]
    buf[i] = nil
    if a.active then a[name](a, sim, spell, result) end
  end
  depth = depth - 1
end

function Unit:OnSpellHitDealt(sim, spell, result) Dispatch(self.onSpellHitDealt, "onSpellHitDealt", sim, spell, result) end
function Unit:OnSpellHitTaken(sim, spell, result) Dispatch(self.onSpellHitTaken, "onSpellHitTaken", sim, spell, result) end
function Unit:OnPeriodicDamageDealt(sim, spell, result) Dispatch(self.onPeriodicDamageDealt, "onPeriodicDamageDealt", sim, spell, result) end
function Unit:OnCastComplete(sim, spell) Dispatch(self.onCastComplete, "onCastComplete", sim, spell) end
function Unit:OnApplyEffects(sim, target, spell)
  local list = self.onApplyEffects
  local i = 1
  while i <= #list do
    local a = list[i]
    if a.active then a.onApplyEffects(a, sim, target, spell) end
    if list[i] == a then i = i + 1 end
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Reset between iterations (unit.go reset)
-- ---------------------------------------------------------------------------------------------------------------
function Unit:ResetAuras(sim)
  self.activeAuras = {}
  for i = 1, #CALLBACK_LISTS do self[CALLBACK_LISTS[i]] = {} end
  if self.exclusiveCategories then
    for _, c in pairs(self.exclusiveCategories) do
      c.active = nil
      for _, e in ipairs(c.effects) do e.isEnabled = false end
    end
  end
  for _, fn in ipairs(self.resetEffects) do fn(sim) end
  self.minExpires = huge
  for _, a in ipairs(self.auras) do
    a.active = false
    a.stacks = 0
    a.expires = 0
    a.startTime = 0
    a.fadeTime = -huge
    if a.onReset then a.onReset(a, sim) end
  end
end

function Unit:RegisterResetEffect(fn) self.resetEffects[#self.resetEffects + 1] = fn end
