if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Setup.lua", ...) then return end -- DisasterZone: Sim/Setup.lua
-- ns.GearSim scenario assembly, in WoWSims' build order (character.go applyAllEffects): race, class spells and
-- talents, item effects and set bonuses, buffs, consumables, debuffs; then finalize stats and load the rotation.
local _, ns = ...
local S = ns.GearSim

-- sc: { race, class, spec, talents, gear (17 slots, WoWSims order), metaActive, buffs (preset name or table),
--       consumables, professions, duration, durationVariation, seed, mobType, targetArmor, reactionTimeMs, distance }
-- db: item data (see Character.lua); apl: the rotation table (WoWSims APL JSON as Lua tables)
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
    reactionTimeMs = sc.reactionTimeMs, distance = sc.distance, professions = sc.professions or { "Engineering", "Blacksmithing" },
  }, db)
  p.currentTarget = target
  p.attackTables[target] = S.NewAttackTable(p, target)
  p.attackTables[p] = S.NewPlayerDefenderTable(p, p)
  target.currentTarget = p

  S.ApplyRacials(p)
  if (sc.class or "Paladin") == "Paladin" then S.SetupPaladin(p, sc.talents or "") end
  S.ApplyItemEffects(p, sc, db)
  S.ApplyBuffs(p, buffs)
  S.ApplyConsumables(p, cons, buffs)
  S.ApplyDebuffs(p, target, buffs.debuffs or {})

  p:Finalize()
  target:Finalize()
  for _, fn in ipairs(p.postFinalize) do fn() end
  p:UpdateCastSpeed()

  local rot = S.NewRotation(p, apl,
    function(ref) return S.PaladinResolveSpell(p, ref) end,
    function(ref) return S.PaladinResolveAura(p, ref) end)
  rot:RegisterPrepull(sim)
  sim.units = { p }
  return sim, p, target
end

-- Run n iterations starting at iteration index `from` (default 1) and summarize.
function S.RunScenario(sim, p, n, from)
  from = from or 1
  for i = from, from + n - 1 do sim:RunOnce(i) end
  return S.Summarize(sim, p)
end
