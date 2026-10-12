if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Setup.lua", ...) then return end -- DisasterZone: Sim/Setup.lua
-- ns.GearSim scenario assembly, in WoWSims' build order (character.go applyAllEffects): race, class spells and
-- talents, item effects and set bonuses, buffs, consumables, debuffs; then finalize stats and load the rotation.
local _, ns = ...
local S = ns.GearSim

-- sc: { race, class, spec, talents, gear (17 slots, WoWSims order), metaActive, buffs (preset name or table),
--       consumables, professions, duration, durationVariation, seed, mobType, targetArmor, reactionTimeMs, distance }
-- db: item data (see Character.lua); apl: the rotation table (WoWSims APL JSON as Lua tables)
local NO_CLASS = {}

function S.NewScenario(sc, db, apl)
  local sim = S.NewSim({ seed = sc.seed or 101, duration = sc.duration or 180, durationVariation = sc.durationVariation or 0,
    execute20 = sc.execute20 })
  local target = S.BuildTarget({ level = 73, mobType = sc.mobType or "Mechanical", armor = sc.targetArmor or 7685 })
  sim.targets = { target }

  local buffs = sc.buffs
  if type(buffs) == "string" then buffs = S.BUFF_PRESETS[buffs] end
  buffs = buffs or {}
  local cons = sc.consumables
  if cons == nil or type(cons) == "string" then cons = (buffs.consumables or {}) end

  local p = S.BuildPlayer(sim, {
    race = sc.race, class = sc.class or "Paladin", gear = sc.gear, metaActive = sc.metaActive,
    reactionTimeMs = sc.reactionTimeMs, distance = sc.distance, channelClipDelayMs = sc.channelClipDelayMs, professions = sc.professions or { "Engineering", "Blacksmithing" },
  }, db)
  p.currentTarget = target
  p.consumables = cons
  p.attackTables[target] = S.NewAttackTable(p, target)
  p.attackTables[p] = S.NewPlayerDefenderTable(p, p)
  target.currentTarget = p

  -- the class (Sim/<Class>.lua S.RegisterClass): constructor before the racials unless order = "afterRacials"
  local C = S.CLASSES[sc.class or "Paladin"] or NO_CLASS
  local talents = sc.talents or ""
  local function classSetup() buffs = C.setup(p, talents, sc.classOptions, cons, buffs) or buffs end
  if C.setup and C.order ~= "afterRacials" then classSetup() end
  S.ApplyRacials(p)
  if C.setup and C.order == "afterRacials" then classSetup() end
  S.ApplyItemEffects(p, sc, db)
  -- stat weights (UI/SimNerd.lua): extra stats as if from gear, so buffs scale them like WoWSims' own
  if sc.bonusStats then p:AddStats(sc.bonusStats) end
  if C.applyTalents then C.applyTalents(p) end
  p.buffRecord = {}
  S.ApplyBuffs(p, buffs)
  p.buffRecordDone, p.buffRecord = p.buffRecord, nil
  for _, pet in ipairs(p.pets or {}) do
    pet.buffRecord = {}
    S.ApplyPetBuffs(pet, buffs)
    pet.buffRecordDone, pet.buffRecord = pet.buffRecord, nil
  end
  S.ApplyConsumables(p, cons, buffs)
  if C.initialize then C.initialize(p) end
  S.ApplyDebuffs(p, target, buffs.debuffs or {})

  p:Finalize()
  target:Finalize()
  if p.pets then S.ShamanFinalizePets(p) end
  for _, fn in ipairs(p.postFinalize) do fn() end
  p:UpdateCastSpeed()

  local resolveSpell = C.resolveSpell or function(pl, ref) return S.ResolveSpell(pl, ref) end
  local resolveAura = C.resolveAura and function(ref) return C.resolveAura(p, ref) end
    or function(ref, unit) return S.ResolveAura(unit or p, ref) end
  local rot = S.NewRotation(p, apl, function(ref) return resolveSpell(p, ref) end, resolveAura)
  rot:RegisterPrepull(sim)
  sim.units = { p }
  return sim, p, target
end

-- apl_helpers.go GetAPLSpell: same ActionID (tag included), spells marked for the APL first; "OtherActionPotion" is
-- the combat potion.
function S.ResolveSpell(p, ref)
  if ref.otherId == "OtherActionPotion" then
    for _, sp in ipairs(p.spellbook) do if S.has(sp.flags, S.F.Potion) then return sp end end
    return nil
  end
  local key = S.ActionKey(ref)
  if not key then return nil end
  local found
  for _, sp in ipairs(p.spellbook) do
    if sp.actionKey == key then
      if S.has(sp.flags, S.F.APL) then return sp end
      found = found or sp
    end
  end
  return found
end

-- GetAuraByID: the first aura registered with that ActionID.
function S.ResolveAura(unit, ref)
  local key = S.ActionKey(ref)
  return key and unit.aurasByKey and unit.aurasByKey[key] or nil
end

-- Run n iterations starting at iteration index `from` (default 1) and summarize.
function S.RunScenario(sim, p, n, from)
  from = from or 1
  for i = from, from + n - 1 do sim:RunOnce(i) end
  return S.Summarize(sim, p)
end
