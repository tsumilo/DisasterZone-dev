# WoWSims TBC: buffs / debuffs / consumables / racials spec for the Lua port

Source: `C:\Users\emilo\CDLoot-dev\dev\ext\wowsims-tbc` (commit 5262ff38, 2026-10-07). All paths below are
relative to `sim/core/` unless stated otherwise. Line numbers are from that commit.

Scope: the Retribution Paladin default preset (`ui/specs/paladin/retribution/presets.ts`).

---

## 0. Engine rules you need before anything else

### 0.1 Timeline: reset at t=0, then prepull
`sim.go:400-460`: `reset()` sets `sim.CurrentTime = 0` and runs every unit's reset (aura `OnReset`, unit
`RegisterResetEffect` callbacks, MCD reset). Only **after** that, `PrePull()` moves `CurrentTime` to the first
prepull action's time (Ret default APL: `-18.5s`, the self Sanctity Aura cast) and schedules the prepull actions.
Consequences:
- "Permanent" buffs are activated at reset (time 0, before prepull), i.e. they are up for the whole fight.
- Periodic actions started at reset are scheduled relative to t=0 (e.g. `Period: 10s` first fires at +10s of the fight).
- A periodic action with `TickImmediately: true` started at t=0 is queued at `NextActionAt = 0` (fires at pull).
- The APL (`apl.go:409-413`) does nothing while `sim.CurrentTime < 0`.

### 0.2 Stat buffs (`buffs.go:42-130`)
```go
func makeStatBuff(char *Character, config BuffConfig) *Aura {
	...
	if config.ActionID.Tag == 0 { config.ActionID = config.ActionID.WithTag(-1) }
	baseAura := char.GetOrRegisterAura(Aura{
		Duration:   TernaryDuration(config.Duration > 0, config.Duration, NeverExpires),
		BuildPhase: Ternary(config.ActionID.Tag == -1, CharacterBuildPhaseBuffs, CharacterBuildPhaseNone),
	})
	if config.ExclusiveCategory != "" { registerExlusiveEffects(...) } else { registerStatEffect(...) }
```
- `StatConfig{stat, amount, false}` = flat `AddStatDynamic(stat, +amount)` on gain, `-amount` on expire.
- `StatConfig{stat, amount, true}` = a dynamic **multiply-stat dependency** (`NewDynamicMultiplyStat`), i.e. `stat *= amount` inside the stat-dependency pass (see 0.4).
- With `ExclusiveCategory` set, each stat becomes an ExclusiveEffect in category `<cat><StatName>Add` (flat) or
  `<cat><StatName>Mul` (multiplier), **SingleAura=false**, `Priority = amount`. Only the highest-priority enabled
  effect in a category is applied; the others stay enabled but contribute nothing.
- `MakePermanent(aura)` (`aura_helpers.go:359-375`): sets `Duration = NeverExpires` and activates the aura in `OnReset`.
- `BuildPhase` only matters for the stat-sheet measurement (`character.go:274-338`); the simulation itself gets
  every buff by activating the aura at reset.

### 0.3 ExclusiveEffect semantics (`exclusive_effect.go`)
- `Activate`: if category `SingleAura` and the current active effect has higher priority (or equal priority and
  longer remaining duration than this aura's Duration) -> the new aura is **blocked** (aura does not activate).
  Otherwise it is enabled; if `Priority >= active.Priority` it becomes the active effect, and if SingleAura the
  previously active effect's **whole aura is deactivated**.
- Exclusive effects are activated **before** the aura's own `OnGain` (`aura.go:691-704`), so auras that set their
  real priority in `OnGain` (Expose Armor, Battle Shout) first enter the category with their initial Priority (0).
- `Deactivate`: the next highest-priority enabled effect becomes active.

### 0.4 Stat-dependency pass and flooring (`stats/deps.go`, `stats/stats.go:300-336`, `unit.go:352-374`)
Every stat change recomputes the full total: `stats = ApplyStatDependencies(statsWithoutDeps)` then
`FloorGameStats()`. Rules:
- Dependencies are evaluated in `safeDepsOrder` = Str, Agi, Sta, Int, Spi, BonusArmor, Armor, FeralAP, AP, RAP,
  SpellDamage, HealingPower, Health, Mana, MP5, MeleeHaste, MeleeCrit, MeleeHit, SpellHit, SpellCrit, SpellHaste,
  BlockPercent, Dodge, Parry, Expertise, BlockValue, ArP, SpellPen, SpellCritPercent, PhysicalCritPercent,
  SpellHitPercent, PhysicalHitPercent. For each source stat the self-multiplier (e.g. Kings, Human Spirit) is applied
  first, then the source feeds its destinations.
- When the source is one of Str/Agi/Sta/Int/Spi, the **floored** source value is used:
  `s[dst] += math.Floor(s[src]) * dep.amount` (`deps.go:281-289`).
- After all deps, Str/Agi/Sta/Int/Spi are floored (`FloorGameStats`). Nothing else is floored (AP, ratings, mana are fractional).
- Static same-pair deps are merged (multipliers multiplied, additive coefficients summed); dynamic deps (buffs) stay separate.

Lua port notes: implement stat totals as `raw stats -> deps in safeDepsOrder (floor attribute sources) -> floor 5 attributes`; buffs add to raw stats or enable multiplier deps; resolve exclusive categories by max priority.

---

## 1. Raid buffs (`applyBuffEffects`, `buffs.go:133-164`)

### 1.1 Arcane Brilliance (`arcaneBrilliance=true`) - `buffs.go:409-418`
```go
Label: "Arcane Brilliance", ActionID: ActionID{SpellID: 27127},
Stats: []StatConfig{ {stats.Intellect, 40, false} },
ExclusiveCategory: StatBuffCategory,   // "StatBuff"
```
Applied with `MakePermanent` (`buffs.go:137-139`). +40 Intellect flat, exclusive with Scroll of Intellect (20) in
category `StatBuffIntellectAdd` -> 40 wins.
Lua port notes: +40 Int permanent.

### 1.2 Divine Spirit, Improved (`divineSpirit=Improved`) - `buffs.go:420-450`
```go
dsSDStatDep := char.NewDynamicStatDependency(stats.Spirit, stats.SpellDamage, 0.1)
dsHPStatDep := char.NewDynamicStatDependency(stats.Spirit, stats.HealingPower, 0.1)
aura := char.GetOrRegisterAura(Aura{ Label: "Divine Spirit Buff", ActionID: ActionID{SpellID: 25312},
	Duration: time.Minute * 30, BuildPhase: CharacterBuildPhaseBuffs,
	OnGain: func(...) { if improved { char.EnableBuildPhaseStatDep(sim, dsSDStatDep); ...dsHPStatDep } }, ...})
makeExclusiveFlatStatBuff(aura, stats.Spirit, 50, StatBuffCategory)
```
`MakePermanent`. +50 Spirit (exclusive category `StatBuffSpiritAdd`, beats Scroll of Spirit 30). Improved adds
`SpellDamage += floor(Spirit)*0.1` and `HealingPower += floor(Spirit)*0.1` (of **total** spirit, after Kings etc.).
Regular (`TristateEffectRegular`): only the +50 Spirit.
Lua port notes: +50 Spi; if improved, SpellDamage and HealingPower += 0.1*floor(total Spirit).

### 1.3 Gift of the Wild, Improved - `buffs.go:452-483`
```go
mod := 1.0; if improved { mod = 1.35 }
statMod := math.Floor(14 * mod)             // improved: 18 (regular 14)
{stats.Armor, math.Floor(340 * mod), false} // improved: 459 (regular 340)
{Stamina, Strength, Agility, Intellect, Spirit: statMod}
resistMod := math.Floor(25 * mod)           // improved: 33 (regular 25), each school, exclusive per school
```
Not exclusive for the attributes (stacks with everything). Resistances use categories
`ResistanceArcane/Fire/Frost/Nature/Shadow` + `<Stat>Add`. Permanent.
Lua port notes: +18 Str/Agi/Sta/Int/Spi, +459 Armor, +33 to each resist (max-per-school with other resist buffs).

### 1.4 Power Word: Fortitude, Improved - `buffs.go:485-499`
`stat := 79.0; if improved { stat = math.Floor(stat * 1.3) }` -> **102 Stamina** (regular 79). Not exclusive. Permanent.

### 1.5 Shadow Protection - `buffs.go:501-510`
+70 ShadowResistance, `ExclusiveCategory: ResistanceCategoryShadow` (beats GotW's 33). Permanent. No DPS effect.

### 1.6 Thorns, Improved (`thorns=Improved`) - `buffs.go:157-160`, `377-407`
```go
MakePermanent(ThornsAura(char, GetTristateValueInt32(raidBuffs.Thorns, 0, 3)))
...
baseDamage := 25 * (1 + 0.25*float64(points))        // improved (points=3): 43.75; regular: 25
spell.CalcAndDealDamage(sim, target, baseDamage, spell.OutcomeMagicHit)
...
Callback: CallbackOnSpellHitTaken, Outcome: OutcomeLanded,
Handler: if spell.SpellSchool.Matches(SpellSchoolPhysical) { procSpell.Cast(sim, spell.Unit) }
```
Spell 26992, Nature, `SpellFlagBinary | SpellFlagPassiveSpell`, ProcMask Empty. Fires only when the player is **hit
by a physical attack** (landed). The Ret player is not the tank by default, so the boss never hits it and Thorns
deals 0 damage in practice. (Damage on the attacker counts towards DPS because the attacker is an opponent.)
Lua port notes: ignore unless you model the boss hitting the player; if so 43.75 nature damage, binary magic hit roll.

### 1.7 Bloodlust (`bloodlust=true`) - see section 7.2.

---

## 2. Party buffs (`buffs.go:166-332`)

### 2.1 Mana Spring Totem, Regular - `buffs.go:1026-1042`
```go
mp5Buff := 50.0
if improved { mp5Buff *= 1.25 }   // 62.5, no truncation
ExclusiveCategory: ManaSpringTotemCategory
```
Regular = **+50 MP5**, permanent, exclusive category `ManaSpringTotemMP5Add`.

### 2.2 Leader of the Pack, Improved - `buffs.go:824-838`
```go
{stats.PhysicalCritPercent, 5, false}
if improved { statsConfig = append(statsConfig, StatConfig{stats.MeleeCritRating, 20, false}) }
```
+5% physical crit (directly in percent) and, improved, +20 MeleeCritRating (= 20/22.076923 = 0.90592%). Not exclusive. Permanent.

### 2.3 Battle Shout, Improved (external) - `buffs.go:183-195`, `624-704`
```go
aura := BattleShoutAura(char, false, 0 /*boomingVoice*/, GetTristateValueFloat(partyBuffs.BattleShout, 1.0, 1.25),
	partyBuffs.BsSolarianSapphire, false)
ApplyFixedShoutAura(char, aura, BattleShoutCategory)
...
baseApBuff := 306.0 ... if isPrepull { if hasSolarianSapphire { apBuff += 70 }; if hasT2 { apBuff += 30 } }
return math.Floor(apBuff * commandingPresenceMultiplier)    // improved: floor(382.5) = 382
...
ActionID: ActionID{SpellID: 2048}.WithTag(1), Duration: 2min * (1+0.1*0) = 2min, BuildPhase: Buffs
OnGain: ee.SetPriority(sim, TernaryFloat64(sim.CurrentTime > 0, apBuff, prepullApBuff))
ee = aura.NewExclusiveEffect(BattleShoutCategory, true, ... AddStatDynamic(stats.AttackPower, ee.Priority) ...)
```
- Value: **+382 AP** (regular 306). Solarian's Sapphire (`bsSolarianSapphire`, not set in preset) adds +70 only
  for a shout cast prepull (`sim.CurrentTime <= 0`).
- Scheduling (`ApplyFixedShoutAura`, `buffs.go:670-704`): there is no player-cast BS on a paladin, so only
  `ApplyFixedUptimeAura(aura, 1, aura.Duration+1, -1)` runs: uptime 1 -> a start action at `t = -1ns` (during prepull)
  activates it for a random duration in `[tickLength, ...]` that collapses to ~2 min, and a periodic action every
  `2min + 1ns` re-activates it with chance 1. Net effect: 382 AP for the whole fight (1 ns gaps are irrelevant).
- Exclusive category `BattleShout` (SingleAura).
Lua port notes: +382 AP permanent.

### 2.4 Strength of Earth Totem, Improved - `buffs.go:1044-1066`
```go
var StrengthOfEarthMultipliers = []float64{1, 1.08, 1.15}
return math.Floor((86.0 + TernaryFloat64(hasEnh2pT4, 12, 0)) * StrengthOfEarthMultipliers[enhancingTotemsPoints])
```
Called with `GetTristateValueInt32(partyBuffs.StrengthOfEarthTotem, 0, 2)` -> improved: floor(86*1.15) = **+98 Str**
(regular 86; with `soeEnhancement2pt4`: floor(98*1.15)=112). Permanent, exclusive `StrengthOfEarthTotemStrengthAdd`.

### 2.5 Grace of Air Totem, Improved + totemTwisting - `buffs.go:247-249`, `987-1022`
```go
agiBuff := 77.0
if improved { agiBuff = math.Floor(agiBuff * 1.15) }  // 88
duration := NeverExpires
if wfActive { duration = time.Second * 9 }            // wfActive = partyBuffs.TotemTwisting
... ExclusiveCategory: GraceOfAirTotemCategory
}).ApplyOnReset(func(aura *Aura, sim *Simulation) {
	if wfActive {
		StartPeriodicAction(sim, PeriodicActionOptions{ Period: time.Second * 10, Priority: ActionPriorityAuto,
			OnAction: func(sim *Simulation) { aura.Activate(sim) } })
	} else { aura.Activate(sim) }
})
```
**Not** `MakePermanent`. With `totemTwisting=true`: the aura is NOT active at reset; first activation at
**t = 10 s**, then every 10 s, each lasting **9 s** -> active in [10,19), [20,29), [30,39) ... ; down in [0,10) and
the last second of every 10 s window. Without twisting: permanent from reset. Note `totemTwisting` only affects GoA;
Windfury itself is always fully up (2.6).
Lua port notes: +88 Agi; with twisting, on in [10k, 10k+9) for k>=1, off otherwise (stat changes are dynamic: re-derive crit/armor/dodge).

### 2.6 Windfury Totem, Improved - see section 7.1 (mechanics).

### 2.7 Drums (`drums=LesserDrumsOfBattle`) - see section 7.3.

### 2.8 Sanctity Aura (party buff) - `buffs.go:275-277`, `930-953`
Preset: **Missing** (the Ret paladin casts its own Sanctity Aura in the APL at -18.5 s; that is class code).
If set as a party buff:
```go
MakePermanent(SanctityAuraBuff(char, false, GetTristateValueInt32(partyBuffs.SanctityAura, 0, 2)))
...
ActionID: ActionID{SpellID: 20218}.WithTag(-1) (external)
}).AttachMultiplicativePseudoStatBuff(&char.PseudoStats.SchoolDamageDealtMultiplier[stats.SchoolIndexHoly], 1.1)
if impSanctityAuraRank > 0 {
	aura.AttachMultiplicativePseudoStatBuff(&char.PseudoStats.DamageDealtMultiplier, 1+0.01*float64(impSanctityAuraRank))
}
aura.NewExclusiveEffect(SanctityAuraCategory, true, ExclusiveEffect{ Priority: paladinAuraPriority(isPlayer) })
```
- Regular: Holy damage dealt x1.10. Improved (rank 2): additionally **all** damage dealt x1.02.
- Category `SanctityAura` is SingleAura; self-cast priority 1, external priority 0: when the paladin casts its own
  Sanctity Aura the external one is deactivated (they never stack); while the self one is active the external is blocked.
Lua port notes: preset = nothing. If enabled: holyMult*=1.1, (improved) allDamageMult*=1.02; never stack with own Sanctity.

### 2.9 Ferocious Inspiration (`ferociousInspiration=N`, not in preset) - `buffs.go:243-245`, `814-822`
```go
dmgBuff := 0.03 * float64(count)
Label: "Ferocious Inspiration", ActionID: ActionID{SpellID: 34460}, Duration: time.Second * 10,
}).AttachMultiplicativePseudoStatBuff(&char.PseudoStats.DamageDealtMultiplier, 1+dmgBuff)
```
`MakePermanent` -> permanent `DamageDealtMultiplier *= 1 + 0.03*N` (all schools). Not exclusive.

### 2.10 Trueshot Aura (not in preset) - `buffs.go:955-966`
+125 AttackPower and +125 RangedAttackPower, flat, not exclusive, permanent.

### 2.11 Braided Eternium Chain (not in preset) - `buffs.go:1249-1258`
+28 MeleeCritRating, exclusive category `Braided Eternium ChainMeleeCritRatingAdd` (so it doesn't double with the
player wearing the chain itself), permanent.

### 2.12 Draenei racial, melee (`draeneiRacialMelee`, not in preset) - `buffs.go:239-241`, `1293-1326`
```go
alliance := []proto.Race{Draenei, Dwarf, Gnome, Human, NightElf}
if !slices.Contains(alliance, char.Race) { return nil }
... Label: "Heroic Presence", ActionID: ActionID{SpellID: 6562},
	Stats: {stats.PhysicalHitPercent, 1, false}, ExclusiveCategory: "Heroic Presence"
return MakePermanent(aura)
```
+1% physical hit, **only if the player's race is Alliance** (Blood Elf gets nothing). Exclusive with the player's
own Draenei racial (same category/label) -> never +2%.

---

## 3. Individual buffs (`buffs.go:334-369`)

### 3.1 Blessing of Kings - `buffs.go:1462-1474`
`{Agility, Strength, Stamina, Intellect, Spirit} x 1.1, IsMultiplicative: true` -> dynamic multiply deps (not exclusive),
applied before the attribute feeds its dependents and before flooring (0.4). Permanent.

### 3.2 Blessing of Wisdom, Improved - `buffs.go:1560-1575`
`mp5Buff := 41.0; if improved { mp5Buff = math.Floor(mp5Buff * 1.20) }` -> **+49 MP5** (regular 41). Not exclusive. Permanent.

### 3.3 Blessing of Might, Improved - `buffs.go:1507-1521`
`apBuff := 220.0; if improved { apBuff *= 1.2 }` -> **+264 AP** and +264 RAP (regular 220). Not exclusive. Permanent.

### 3.4 Unleashed Rage - `buffs.go:367-369`, `968-980`
```go
MakePermanent(UnleashedRageAura(char, -1, 5))
...
Duration: time.Second * 10, ActionID: ActionID{SpellID: 30809}.WithTag(casterIdx),
Stats: []StatConfig{ {stats.AttackPower, 1 + 0.02*float64(points), true} },   // 1.10
ExclusiveCategory: UnleashedRageCategory,
```
Permanent **AttackPower x1.10** (multiplier dep on AP, i.e. applied to total AP after Str->AP). Exclusive category
`UnleashedRageAttackPowerMul` (priority 1.1).

### 3.5 Blessing of Salvation - `buffs.go:1523-1529`
`AttachMultiplicativePseudoStatBuff(&char.PseudoStats.ThreatMultiplier, 0.7)` - threat only, no DPS effect. Permanent.

---

## 4. Debuffs on the target (`debuffs.go:13-183`)

All of these live on the **target** unit. "Damage taken" multipliers multiply the attacker's damage; `BonusAttackPower`
on the target is added to the attacker's AP when attacking that target (`unit.go:217-219`:
`unit.GetStat(stats.AttackPower) + target.PseudoStats.BonusAttackPower + ...`).

### 4.1 Misery - `debuffs.go:114-116`, `644-672`
`MiseryAura(target, 5)`: `multiplier := 1.0 + 0.01*5 = 1.05` applied to `SchoolDamageTakenMultiplier` for
Arcane, Fire, Frost, **Holy**, Nature, Shadow (not Physical). Exclusive `MiseryBonus` (SingleAura). Permanent.

### 4.2 Curse of the Elements, Improved - `debuffs.go:19-22`, `204-233`
`ranks = 3` -> `multiplier := 1.10 + 0.01*3 = 1.13` on Arcane, Fire, Frost, Shadow damage taken (**not Holy, not
Nature**). Also target resistances -88 (Arcane/Fire/Frost/Shadow). Exclusive `CurseOfElements`. Permanent.
(Regular: 1.10.)

### 4.3 Improved Seal of the Crusader, Improved + `jocRetribution2Pt4` - `debuffs.go:90-92`, `488-517`
```go
MakePermanent(ImprovedSealOfTheCrusaderAura(target, -1, GetTristateValueInt32(debuffs.ImprovedSealOfTheCrusader, 0, 3),
	0.0, Ternary(debuffs.JocRetribution_2Pt4, 1.15, 1.0)))
...
holySpellDamageBonus := 219.0*percentBonus + flatBonus     // 219*1.15 = 251.85
aura.NewExclusiveEffect("Improved Seal of the Crusader", true, ExclusiveEffect{
	Priority: holySpellDamageBonus + float64(casterIndex),  // 250.85 for the external one
	OnGain: target.AddReducedCritTakenPercent(float64(-1 * points))                       // -3 -> attackers +3% crit
	        target.PseudoStats.SchoolBonusSpellDamage[stats.SchoolIndexHoly] += holySpellDamageBonus
```
- **+3% crit chance** for every attack and spell against the target (physical: `spell_result.go:188`
  `critPercent := ... - Defender.PseudoStats.ReducedCritTakenPercent`; spell: `spell_result.go:267-273` same).
  Regular tristate gives points=0 -> no crit, only the holy bonus.
- **+251.85 Holy "spell damage"** for spells against the target: added to bonus damage in
  `spell_result.go:205-212` (`... + attackTable.Defender.PseudoStats.SchoolBonusSpellDamage[spell.SchoolIndex]`), so
  it is scaled by each holy spell's spell-power coefficient like normal spell damage (applies only to non-physical spells).
- The paladin's own Judgement of the Crusader uses casterIndex 1 (`paladin/seals.go:610`) -> priority bonus+1, so
  the self one wins and the external one is deactivated while it's up (same SingleAura category). Values are the
  same for the Ret preset (talent/2pT4-dependent), so this only matters if they differ.
Lua port notes: target crit-taken +3 percentage points (melee + spell); holy spell bonus damage +251.85 (x coefficient).

### 4.4 Judgement of Wisdom - `debuffs.go:106-108`, `588-620`
`MakeProcTriggerAura` on the target, `ProcChance: 0.5`, `ProcMask: ProcMaskDirect`, `CallbackOnSpellHitTaken`,
no Outcome filter; handler: `if !spell.ProcMask.Matches(ProcMaskMeleeOrRanged) && !result.Landed() { return }`
(melee/ranged proc even on misses; spells only on landed) then `unit.AddMana(sim, 74.0, ...)` if the attacker has
mana. A Crusader Strike (35395) also refreshes the aura (irrelevant, permanent). No ICD.
Lua port notes: every direct melee/ranged attack (white, WF extra attack, specials; hit or miss) and every landed
direct spell: 50% chance to gain 74 mana. Note `sim.RandomFloat > 0.5` fails, i.e. proc if rand <= 0.5.

### 4.5 Judgement of Light (not in preset; "plus judgementOfLight" requested) - `debuffs.go:102-104`, `564-586`
On landed melee (ProcMaskMelee) against the target: `if sim.Proc(0.5, ...) { spell.Unit.GainHealth(sim, 95.0, ...) }`.
Healing only, no DPS effect.

### 4.6 Blood Frenzy - `debuffs.go:15-17`, `193-201`
`damageTakenDebuff(..., []SchoolIndex{Physical}, 1+0.02*2 = 1.04, NeverExpires)` -> **Physical damage taken x1.04**. Not exclusive.

### 4.7 Hunter's Mark, Improved - `debuffs.go:55-70`, `420-454`
```go
initialBonus := 110.0; bonusPerStack := 11.0
meleeBonus := initialBonus * 0.2 * float64(improved)    // improved=5 -> 110
OnGain: if improved > 0 { target.PseudoStats.BonusAttackPower += meleeBonus }
        target.PseudoStats.BonusRangedAttackPower += ee.Priority   // 110 + 11*stacks (max 30 stacks -> 440)
```
Scheduling: `ApplyFixedUptimeAura(aura, 1, 2min, 1ns)` (activated at t = 1 ns, re-activated every 2 min) plus
`ScheduledAura` ticking every 1 s x5 adding 6 stacks (ranged part only). For melee: **+110 AP** for attacks against
the target from t = 1 ns onwards (effectively the whole fight). Regular: melee +0.
Lua port notes: attacker AP +110 vs target (added after the player's own AP multipliers - it is not multiplied by UR).

### 4.8 Curse of Recklessness - `debuffs.go:24-26`, `235-251`
`statsDebuff(...{stats.Armor: -800, stats.AttackPower: 135}, 2min)` -> **target armor -800** (+135 target AP,
irrelevant). Exclusive `CurseOfRecklessness`. Permanent.

### 4.9 Faerie Fire, Improved - `debuffs.go:43-45`, `352-378`
`FaerieFireAura(target, 3)`: **armor -610** and `ReducedPhysicalHitTakenChance -= 3` -> attackers get **+3%
physical hit** (`spell_result.go:180`: `hitPercent := ... - Defender.PseudoStats.ReducedPhysicalHitTakenChance`).
Regular: -610 armor, no hit. Exclusive `FaerieFireAura` (SingleAura, priority = 3). Permanent.

### 4.10 Sunder Armor + Expose Armor, Improved (shared category) - `debuffs.go:147-174`, `725-782`
```go
// Expose Armor:
aura := MakePermanent(ExposeArmorAura(target, func() int32 { return 5 }, GetTristateValueInt32(debuffs.ExposeArmor, 0, 2)))
ScheduledAura(aura, PeriodicActionOptions{ Period: time.Second * 10, NumTicks: 1, OnAction: aura.Activate }, raid)
...  eaValue := 410.0 * 5 * (1.0 + 0.25*2) = 3075     // regular: 2050
// Sunder Armor:
ScheduledAura(aura, PeriodicActionOptions{ Period: GCDDefault /*1.5s*/, NumTicks: 5, TickImmediately: true,
	Priority: ActionPriorityDOT, OnAction: { aura.Activate(sim); if aura.IsActive() { aura.AddStack(sim) } } }, raid)
... OnStacksChange: effect.SetPriority(sim, -520*float64(newStacks))  // armor += Priority (negative)
```
`ScheduledAura` **replaces** the OnReset set by MakePermanent (`debuffs.go:185-190`), so neither is up at reset.
Both are in `MajorArmorReduction` (SingleAura). Exact timeline:
- t=0, 1.5, 3.0, 4.5, 6.0 s: Sunder 1..5 stacks -> armor -520, -1040, -1560, -2080, **-2600**.
- t=10 s: Expose Armor activates. Its exclusive effect enters with Priority 0, which is >= Sunder's -2600, so the
  **Sunder aura is deactivated**, then EA's OnGain sets priority 3075 -> **armor -3075** for the rest of the fight
  (Sunder is never re-applied: its 5 ticks are over).
Lua port notes: target armor: -520*min(5, floor(t/1.5)+1) for t<10 s (t>=0), -3075 from t=10 s. Not cumulative.

### 4.11 Expose Weakness (uptime 0.9, hunter agility 1080) - `debuffs.go:36-41`, `331-350`
```go
aura := ExposeWeaknessAura(target, func() float64 { return debuffs.ExposeWeaknessHunterAgility })
ApplyFixedUptimeAura(aura, debuffs.ExposeWeaknessUptime, aura.Duration /*7s*/, 1)
...
OnGain: aura.SetStacks(sim, int32(agilityFunc()*0.25))       // int32(270.0) = 270
OnStacksChange: target.PseudoStats.BonusAttackPower += newValue; BonusRangedAttackPower += newValue
```
`ApplyFixedUptimeAura` (`aura_helpers.go:871-901`):
```go
ticksPerAura := float64(auraDuration) / float64(tickLength)          // 7s/7s = 1
chancePerTick := TernaryFloat64(uptime == 1, 1, 1.0-math.Pow(1-uptime, 1/ticksPerAura))   // 0.9
every tickLength (7s, from t=0): if sim.RandomFloat("FixedAura") < chancePerTick { aura.Activate(sim) }
once at startTime (1ns): if sim.RandomFloat("FixedAura") < uptime {
	randomDur := tickLength + time.Duration(float64(auraDuration-tickLength)*sim.RandomFloat("FixedAuraDur"))  // = 7s
	aura.Duration = randomDur; aura.Activate(sim); aura.Duration = auraDuration }
```
So: at t=1 ns, 90% chance of +270 AP (attacker bonus vs target) for 7 s; then at t = 7, 14, 21, ... s an
independent 90% roll re-activates (or refreshes) it for 7 s. Uptime ~90%. (Preset value: the UI default for the
current phase is 1210 agility (Phase 3, `ui/sim/proto/utils.ts:162-169`); 1080 is the Phase 1 value - use whatever the JSON says: stacks = int32(agi*0.25).)
Lua port notes: 7 s windows starting at 0; each window active with p=0.9 (the very first roll happens at 1 ns); active -> attacker AP +floor(agi/4).

### 4.12 Other debuffs referenced in code but not in the preset
- Judgement of Light: 4.5. Demoralizing Shout/Roar, Thunder Clap, Insect Swarm, Scorpid Sting, Screech, Shadow
  Embrace, Winter's Chill, Mangle, Hemorrhage, ISB, Shadow Weaving, Improved Scorch, Gift of Arthas: not in scope.

---

## 5. Consumables (`consumes.go`, data from `assets/database/db.json`)

Stat index order in the DB arrays is the `stats.Stat` enum (`stats/stats.go:21-64`): 0 Str, 1 Agi, 2 Sta, 3 Int,
4 HealingPower, 5 SpellDamage, ... 13 SpellCritRating, 14 SpellHasteRating, 16 Spirit, 17 AttackPower,
18 RangedAttackPower, 20 MeleeHitRating, 21 MeleeCritRating, 22 MeleeHasteRating, ..., 33 Health, 34 Mana, 35 MP5.

### 5.1 Flask of Relentless Assault (`flaskId 22854`) - `consumes.go:33-36`
DB: `{"id": 22854, "type": 2, stats[17]=120, stats[18]=120, "buffDuration": 7200}` -> `character.AddStats(flask.Stats)`:
**+120 AttackPower, +120 RangedAttackPower**, static (part of initial stats, always on).

### 5.2 Food 27658 (Roasted Clefthoof) - `consumes.go:90-93`
DB: `{"id": 27658, "type": 3, stats[0]=20, stats[16]=20}` -> **+20 Strength, +20 Spirit**, static.

### 5.3 Scrolls (`scrollAgi`, `scrollStr`) - `consumes.go:11-23`, `103-118`
```go
aura := character.GetOrRegisterAura(Aura{ Label: label, ActionID: ActionID{ItemID: itemID}, Duration: NeverExpires,
	BuildPhase: CharacterBuildPhaseConsumes })
makeExclusiveFlatStatBuff(aura, stat, amount, StatBuffCategory)
return MakePermanent(aura)
```
Scroll of Agility (27498) **+20 Agi**, Scroll of Strength (27503) **+20 Str**; permanent, exclusive in
`StatBuffAgilityAdd` / `StatBuffStrengthAdd`. No raid buff uses those categories (GotW, Kings, SoE, GoA are not
in `StatBuff`), so both apply in full. (Int scroll 20 loses to AB 40; Spirit scroll 30 loses to DS 50.)

### 5.4 Haste Potion (`potId 22838`) - `consumes.go:157-339`
DB: `{"id": 22838, "type": 1, stats[22]=400, "buffDuration": 15, "categoryCooldownDuration": 120, "categoryId": 4}`.
```go
for _, potionId := range consumes.Potions {           // NOTE: iterates the 'potions' list, not potId
	potion := GetConsumableByID(potionId)
	if potion.Type == proto.ConsumableType_ConsumableTypePotion {
		potMCD := makePotionActivationSpell(potion.Id, character)
		if defaultPotion == potion.Id { potMCD.Spell.Flags |= SpellFlagCombatPotion; character.AddMajorCooldown(potMCD) }
...
cooldownDuration := TernaryDuration(potion.CooldownDuration > 0, potion.CooldownDuration, time.Minute*2)  // 2 min
CD:       Cooldown{ Timer: character.NewTimer(), Duration: cooldownDuration },
SharedCD: Cooldown{ Timer: character.GetPotionCD() /*spell category 4*/, Duration: cooldownDuration },
aura = character.NewTemporaryStatsAura(potion.Name, actionID, potion.Stats, potion.BuffDuration)
mcd.Type = aura.InferCDType()   // DPS (no Armor/Block/Dodge/Parry/Health stat)
```
- Effect: **+400 MeleeHasteRating for 15 s** (= 400/15.769233 = 25.366% melee haste, multiplicative with Bloodlust).
- MCD: Priority 0 (default), Type DPS, `ShouldActivate` true (no resource gains), no GCD, instant.
  2-min CD on its own timer and on the shared potion timer (category 4). One potion per 2 min.
- Prepull use (`sim.CurrentTime < 0`) would set the shared CD to `categoryCooldownDuration` (120 s) from the
  prepull time; the Ret APL has no prepull potion.
- **Caveat**: the potion is registered only if its ID is in `consumes.potions`. The UI fills that list
  (`ui/sim/player/player.ts:684-696`: all potions matching the spec's EP + consumable stats); a hand-written
  protojson for wowsimcli without `"potions":[...]` gets **no potion**. For the port just use `potId`.
- Other potions in the list (e.g. Super Mana Potion 22832) get spells registered but are **not** MCDs, so they are
  never auto-used. Only `potId` is auto-used. If `potId` were a mana potion: `ShouldActivate` =
  `MaxMana - (CurrentMana + ManaRegenPerSecondWhileCasting()*5) >= (min+spread)*stoneMul` (`consumes.go:320-335`);
  Super Mana Potion gains `1799 + rand*1201` (effect 847151). Mighty Rage Potion 13442: +60 Str for 20 s and
  `449 + rand*301` rage units (/10 -> 44.9-75 rage); the UI filters it out for non-warriors
  (`ui/features/settings/components/ConsumesPicker/utils.ts:26-28`). Alchemist's stone x1.4 on resource gains only.
Lua port notes: Haste Potion = MCD prio 0, +400 haste rating 15 s, 120 s CD, auto-used by autocast (section 8).

### 5.5 Conjured: Demonic Rune (`conjuredId 12662`) - `consumes.go:364-546`
DB: `{"id": 12662, "name": "Demonic Rune", "categoryCooldownDuration": 120, "categoryId": 1153, "effectIds": [694074]}`;
effect 694074: `{"spellId": 16666, "type": 30 /*ResourceGain*/, "minEffectSize": 899, "effectSpread": 601, "resourceType": 1 /*Mana*/}`.
```go
for _, conjuredId := range consumes.ConjuredItems {       // again the list, not conjuredId
	...conjuredMCD = makeConjuredActivationSpell(conjuredId, character)
	conjuredMCD.ShouldActivate = func(...) bool { return oldShouldActivate(sim, character) && consumes.ConjuredId == conjuredId }
	character.AddMajorCooldown(conjuredMCD)
...
CD:       Cooldown{ Timer: character.NewTimer(), Duration: cooldownDuration /*2 min default*/ },
SharedCD: Cooldown{ Timer: character.GetOrInitSpellCategoryTimer(conjured.CategoryId) /*1153*/, Duration: time.Minute * 2 },
gain := config.min + TernaryFloat64(config.spread > 1, sim.RandomFloat(conjured.Name)*config.spread, config.spread)  // 899 + rand*601
...
case proto.ResourceType_ResourceTypeMana:
	totalRegen := character.ManaRegenPerSecondWhileCasting() * 5
	manaGain := config.min + config.spread                                    // 1500
	shouldActivate = character.MaxMana()-(character.CurrentMana()+totalRegen) >= manaGain
```
- Gains **899 + U(0,1)*601 mana** (899-1500). No self-damage is modelled. Type Mana, Priority 0, no GCD.
- Used only when `MaxMana - CurrentMana - 5*regenWhileCasting >= 1500`. 2-min CD + 2-min shared category 1153
  (shared with Master Healthstone and Flame Cap; the Ret UI list also registers those, but their ShouldActivate is
  false because `conjuredId` != their ID, so they never fire).
- The UI labels 12662 "Dark Rune" (`ui/sim/settings/conjured.ts`); the DB name is Demonic Rune. Dark Rune 20520 is not handled.
- Same list caveat: needs `"conjuredItems":[12662,...]` in the input proto.
Lua port notes: mana MCD, condition deficit >= 1500 + 5 s casting regen, gain 899+rand*601, 2 min CD.

### 5.6 Engineering explosives (`superSapper`, `goblinSapper`, `explosiveId 30217`) - `consumes.go:548-665`
Requires `Engineering` as profession1 or profession2 (`consumes.go:558-560`; preset: Engineering + Blacksmithing).
```go
drumsBombsSharedTimer := character.NewTimer()                    // consumes.go:149
SuperSapper:  MajorCooldown{ Type: CooldownTypeDPS | CooldownTypeExplosive, Priority: CooldownPriorityLow + 30 }  // -970
GoblinSapper: MajorCooldown{ ..., Priority: CooldownPriorityLow + 20 }                                         // -980
explosiveId:  MajorCooldown{ Spell: filler, ..., Priority: CooldownPriorityLow + 10 }                          // -990
...
DefenseType: DefenseTypeMagic, ProcMask: ProcMaskEmpty, Flags: SpellFlagExplosive, MissileSpeed: speed,
Cast: CastConfig{ DefaultCast: Cast{ CastTime: castTime }, CD: cooldown,
	SharedCD: Cooldown{ Timer: sharedTimer, Duration: time.Minute } },
BonusHitPercent: 100, DamageMultiplier: 1, ThreatMultiplier: 1,
ApplyEffects: baseDamage := sim.Roll(minDamage, maxDamage) * sim.Encounter.AOECapMultiplier()
	spell.CalcAoeDamage(sim, baseDamage, spell.OutcomeMagicHitAndCrit)   // dealt after travel time if speed > 0
	if dealSelfDamage { spell.CalcAndDealDamage(sim, &character.Unit, sim.Roll(minDamage, maxDamage), spell.OutcomeMagicHitAndCrit) }
```
| Item | ActionID | School | Damage | Own CD | Cast time | Missile speed | Prio | Self damage |
|---|---|---|---|---|---|---|---|---|
| Super Sapper Charge | item 23827 | Fire | 900-1500 | 5 min | 0 | 0 | -970 | yes (same range) |
| Goblin Sapper Charge | item 10646 | Fire | 450-750 | 5 min | 0 | 0 | -980 | yes |
| Adamantite Grenade (explosiveId 30217) | item 23737 | Fire | 450-750 | none | 1 s (scaled by cast speed) | 14 yd/s | -990 | no |
| (Fel Iron Bomb, explosiveId 30216) | item 23736 | Fire | 330-770 | none | 1 s | 14 | -990 | no |
- All explosives share **one 1-minute timer** (`SharedCD Duration: time.Minute`). The same timer is the SharedCD
  of *consumable* drums (`drumsId`, 2 min). The **party-buff drums** (`partyBuffs.drums`) do NOT use it.
- `AOECapMultiplier = min(20/numActiveTargets, 1)` = 1 for one target. Hits all targets (`CalcAoeDamage`).
- Hit: `BonusHitPercent 100` -> only the 1% floor miss (`SpellChanceToMiss` returns `max(0.01, ...)`); crit uses the
  player's SpellCritPercent (+ target crit-taken mods such as ISotC +3%); magic crit = 150% damage; normal magic
  damage pipeline (player damage-dealt multipliers, target CoE fire x1.13 and Misery x1.05, partial resists from
  `spell_resistances.go`).
- Grenade travel time = `DistanceFromTarget / 14` s (`spell.go:795-801`; preset distance 5 yd -> 0.357 s).
- Self damage goes to the player (not an opponent), so it is not counted in DPS (`metrics_aggregator.go:422-427`).
- Timing rule (section 8): explosives are autocast only when the **GCD is NOT ready**, i.e. right after the player
  used a GCD ability in the same APL evaluation. The 1 s grenade cast is a hardcast (blocks other casts for 1 s and
  sets the GCD timer to `max(now+castTime, NextGCDAt)`, `cast.go:170-177`); melee swings continue.
- Resulting cadence with all three (T = first eligible moment, all off CD): Super Sapper at T, Goblin Sapper at
  T+60, Grenade at T+120, T+180, T+240, Super Sapper again at T+300 (it and the grenade are both ready; ReadyAt
  equal -> priority), Goblin at T+360, and so on - always "the first evaluation after a GCD ability once the 60 s
  shared timer is up".
Lua port notes: three explosive MCDs with the shared 60 s timer; fire only right after a GCD-triggering cast.

### 5.7 Other consumable fields (not in preset)
`battleElixirId`/`guardianElixirId`: static `AddStats` (Elixir of Demonslaying 9224 = +265 AP vs Demons only).
`mhImbueId` is ignored when Windfury Totem is present (`consumes.go:96`). Adamantite Sharpening Stone/Weightstone
(29453/34340): +14 MeleeCritRating, +12 weapon min/max damage.

---

## 6. Racials (`racials.go`)

Base attribute offsets per race are in section 9. Effects:

### 6.1 Blood Elf - `racials.go:15-63`
- +5 Arcane/Fire/Frost/Nature/Shadow resistance.
- **Arcane Torrent** (mana version, `ActionID{SpellID: 28730}` for a mana user):
```go
Cast: CastConfig{ CD: Cooldown{ Timer: character.NewTimer(), Duration: time.Minute * 2 } },
ApplyEffects: ... } else if spell.Unit.HasManaBar() { spell.Unit.AddMana(sim, 10, resourceMetrics) }
character.AddMajorCooldown(MajorCooldown{ Spell: spell, Type: CooldownTypeDPS, Priority: CooldownPriorityLow /*-1000*/,
	ShouldActivate: func(...) bool { if spell.Unit.HasEnergyBar() { return ... }; return true } })
```
  Restores a flat **10 mana** (Mana Tap charges and the silence are not modelled), 2-min CD, no GCD, no cost.
  Lowest-priority MCD; autocast when the GCD is ready (section 8), i.e. effectively every 2 min after the delay.
Lua port notes: +10 mana every 120 s from the first eligible autocast; otherwise irrelevant.

### 6.2 Human - `racials.go:177-180`, `366-430`
- `character.MultiplyStat(stats.Spirit, 1.10)` - static Spirit x1.10 (multiplicative with Kings x1.1, floored once
  at the end).
- Mace Specialization (20864) and Sword Specialization (20597): `applyWeaponSpecialization(..., oneHand=false, Mace|Sword)`:
  `expertiseBonus := 5 * ExpertisePerQuarterPercentReduction` = **5 * 3.942308 = 19.71154 ExpertiseRating** while
  the main hand is a mace/sword (aura activated at reset via `OnReset` when the mask matches; MH match -> an
  `ExpertiseRating` stat aura). 1H and 2H. Expertise effect: `DodgeParrySuppression =
  floor((ExpertiseRating + spell.BonusExpertiseRating) / 3.942308) / 400` (`spell_result.go:175-178`), so the racial
  alone = 5 expertise = -1.25% dodge and parry. In Lua compute it as `5*3.942308` in doubles so the floor gives 5.

### 6.3 Dwarf - `racials.go:113-173`
- +10 Frost resistance. Gun Specialization (+1% ranged crit with a gun - irrelevant for paladins).
- **No mace specialization/expertise** in this TBC sim (that racial is WotLK).
- **Stoneform** (20594): 3-min CD, **1.5 s GCD**, 8 s `ArmorMultiplier *= 1.1`; registered as
  `MajorCooldown{Spell: spell, Type: CooldownTypeDPS}` (Priority 0, ShouldActivate true), so the autocast action
  **does use it** whenever ready with the GCD ready (it costs a GCD every 3 min, no DPS benefit).
Lua port notes: Dwarf = Stoneform MCD (consumes a 1.5 s GCD every 180 s), nothing else.

### 6.4 Draenei - `racials.go:64-112`
- +10 Shadow resistance.
- Paladin -> `MakePermanent(DraneiRacialAura(character, false))` = **Heroic Presence +1% PhysicalHitPercent**,
  exclusive category "Heroic Presence" (doesn't stack with the `draeneiRacialMelee` party buff).
  (Spell hit +1% "Inspiring Presence" is only for Mage/Priest/Shaman.)
- Gift of the Naaru (28880) is registered as an APL-castable heal (1.5 s cast, 15 s CD) but **not** as an MCD, so
  autocast never uses it.

### 6.5 Professions
`applyProfessionEffects` is empty (`professions.go`). Engineering only gates the explosives (5.6). Blacksmithing
only gates the BS item sets Burning Rage (2pc +20 MeleeHitRating) and Khorium Ward (`common/tbc/items_sets.go:114-138`);
no other effect.

---

## 7. Windfury Totem, Bloodlust, Drums

### 7.1 Windfury Totem, Improved - `buffs.go:323-325`, `1088-1173`
```go
apBonus := 445.0
if isImpoved { apBonus = math.Floor(apBonus * 1.3) }   // 578 (regular 445)
wfProcAura := char.NewTemporaryStatsAura("Windfury Totem Proc", ActionID{SpellID: 25584},
	stats.Stats{stats.AttackPower: apBonus}, time.Millisecond*1500)
wfProcAura.MaxStacks = 2
wfProcAura.AttachProcTrigger(ProcTrigger{ Name: "Windfury Attack", Callback: CallbackOnSpellHitDealt,
	ProcMask: ProcMaskMeleeMHAuto | ProcMaskMeleeOHAuto,
	Handler: if wfProcAura.IsActive() && !spell.ProcMask.Matches(ProcMaskMeleeSpecial) { wfProcAura.RemoveStack(sim) } })
wfProcTrigger := char.MakeProcTriggerAura(ProcTrigger{ Name: "Windfury Totem Trigger",
	MetricsActionID: ActionID{SpellID: 25580, Tag: -1}, IsWeaponProc: true, ProcChance: 0.2, Duration: NeverExpires,
	Outcome: OutcomeLanded, Callback: CallbackOnSpellHitDealt, ProcMask: ProcMaskMeleeMHAuto,
	ICD: time.Millisecond * 1500, TriggerImmediately: true,
	Handler: func(sim, spell, result) {
		wfProcAura.Activate(sim)
		if spell.ProcMask == ProcMaskMeleeMHAuto { wfProcAura.SetStacks(sim, 1) } else { wfProcAura.SetStacks(sim, 2) }
		char.AutoAttacks.MaybeReplaceMHSwing(sim, windfurySpell).Cast(sim, result.Target)
	} })
wfAura := char.GetOrRegisterAura(Aura{ Label: "Windfury Totem", ActionID: ActionID{SpellID: 25587, Tag: -1}, Duration: 10s })
	.ApplyOnInit: config := *char.AutoAttacks.MHConfig(); config.ActionID = config.ActionID.WithTag(25584); windfurySpell = char.GetOrRegisterSpell(config)
	.ApplyOnReset: aura.Activate(sim); StartPeriodicAction(Period: 5s, Priority: ActionPriorityAuto, OnAction: aura.Activate)
wfAura.NewExclusiveEffect(WindfuryTotemCategory, false, ExclusiveEffect{ Priority: apBonus,
	OnGain: wfProcTrigger.Activate(sim), OnExpire: wfProcTrigger.Deactivate(sim); wfAura.Deactivate(sim) })
```
Mechanics (proc logic `aura_helpers.go:113-205`):
- Totem buff: activated at reset, 10 s duration refreshed every 5 s -> **always up** (independent of totemTwisting).
- Trigger: every **landed** (hit/crit/glance/block/crush, `flags.go:122`) **main-hand white swing**
  (`ProcMaskMeleeMHAuto`; specials such as Crusader Strike, seal procs, Judgement do not trigger). Check order:
  proc mask -> outcome -> ICD ready -> `sim.RandomFloat("Windfury Totem Trigger") > 0.2` fails (proc if rand <= 0.2)
  -> ICD.Use (1.5 s) -> handler runs **immediately** (same timestamp).
- Handler: activate the proc aura (+578 AP via `AddStatsDynamic`, so it also gets the Unleashed Rage x1.1 AP
  multiplier), set 1 stack (normal MH swing), then cast one extra MH white attack: a copy of the MH auto-attack spell
  (same weapon-damage formula, `OutcomeMeleeWhite` incl. glancing, ProcMask MeleeMHAuto, ActionID tag 25584). It
  uses current AP **including the bonus**. It does **not** reset or move the swing timer.
- The extra attack can't re-proc WF (ICD started before the handler). It is a normal MH auto for every other proc
  (seals, JoW, item procs, ...).
- The extra attack's hit consumes the stack through the "Windfury Attack" listener, which is **deferred by
  SpellBatchWindow = 10 ms** (no TriggerImmediately) -> the bonus ends 10 ms after the extra attack (1.5 s at most).
  Any other white swing inside those 10 ms would also get it (practically never).
- Two-handed: only the MH exists. totemTwisting affects only Grace of Air (2.5).
Lua port notes: on each landed MH white swing, if now >= wfReadyAt and rand <= 0.2: wfReadyAt = now + 1.5 s; one
extra MH white attack with (AP_raw + 578) * AP multipliers + target AP bonuses.

### 7.2 Bloodlust (raid buff) - `buffs.go:162-164`, `1919-1995`
```go
const BloodlustDuration = time.Second * 40
const BloodlustCD = time.Minute * 10
bloodlustAura := BloodlustAura(character, -1)        // ActionID{SpellID: 2825, Tag: -1}
spell := character.RegisterSpell(SpellConfig{ ActionID: bloodlustAura.ActionID,
	Flags: SpellFlagAPL | SpellFlagNoOnCastComplete | SpellFlagNoMetrics | SpellFlagNoLogs,
	Cast: CastConfig{ CD: Cooldown{ Timer: character.NewTimer(), Duration: BloodlustCD } },
	ApplyEffects: if !character.HasActiveAura(SatedAuraLabel) { bloodlustAura.Activate(sim) } })
character.AddMajorCooldown(MajorCooldown{ Spell: spell, Priority: CooldownPriorityBloodlust /*1000*/, Type: CooldownTypeDPS,
	ShouldActivate: !character.HasActiveAuraWithTag(PowerInfusionAuraTag) && !character.HasActiveAura(SatedAuraLabel) })
...
OnGain: aura.Unit.MultiplyAttackSpeed(sim, 1.3); ...; sated.Activate(sim)     // Sated: 10 min
OnExpire: aura.Unit.MultiplyAttackSpeed(sim, 1/1.3)
multiplyCastSpeedEffect(aura, 1.3)     // exclusive "MultiplyCastSpeed" (non-single), highest multiplier wins (PI is 1.2)
```
- Caster: an abstract external shaman; an MCD on the player with no GCD, no cost, instant.
- When: by the autocast action, i.e. at the **first APL evaluation with `currentTime >= Delay Major CDs (11 s)` and
  the GCD ready**, right after Drums (priority 2000 > 1000) in the same timestamp.
- Effect: `PseudoStats.AttackSpeedMultiplier *= 1.3` for 40 s (the current swing's remaining time is rescaled,
  `attack.go:841-860`), cast speed x1.3. Melee haste multiplier =
  `AttackSpeedMultiplier * MeleeSpeedMultiplier * (1 + MeleeHasteRating/(15.769233*100))` (`unit.go:556-558`),
  multiplicative with rating haste (potion, drums).
- 10-min CD plus Sated (10 min) -> **once per fight** for fights up to 10 min.
Lua port notes: at the first autocast evaluation >= 11 s: swing speed x1.3 for 40 s, once.

### 7.3 Drums of Battle (party buff `drums=LesserDrumsOfBattle`) - `buffs.go:330-332`, `1328-1407`
```go
case proto.Drums_GreaterDrumsOfBattle, proto.Drums_LesserDrumsOfBattle:
	drumLabel = "Drums of Battle"
	drumStats = stats.Stats{stats.MeleeHasteRating: 80, stats.SpellHasteRating: 80}
	duration = time.Second * 30
	actionID = ActionID{SpellID: 35476}
... isExternal -> actionID.WithTag(-1), label "Drums of Battle (External)"
tinnitus := Aura{ Label: "Tinnitus", ActionID: ActionID{SpellID: 369770}, Duration: time.Minute * 2 }
aura.ApplyOnGain: tinnitus.Activate(sim)
ExtraCastCondition: !character.HasActiveAura(TinnitusAuraLabel)
ApplyEffects: if !character.HasActiveAura(TinnitusAuraLabel) { aura.Activate(sim) }
// DrumsBuff:
config.Cast = CastConfig{ CD: Cooldown{ Timer: character.NewTimer(), Duration: time.Minute * 2 } }
character.AddMajorCooldown(MajorCooldown{ Spell: spell, Type: CooldownTypeDPS, Priority: CooldownPriorityDrums /*2000*/ })
```
- Lesser and Greater are identical here: **+80 MeleeHasteRating and +80 SpellHasteRating for 30 s**
  (80/15.769233 = 5.0731% melee haste).
- Party drums: no GCD, no cast time, own 2-min CD (NOT the explosives' shared timer), highest MCD priority (2000)
  -> fired first at the first eligible autocast (>= 11 s, GCD ready), then every 2 min (CD and Tinnitus coincide).
- Consumable drums (`consumes.drumsId`, not in preset) differ: 1.5 s GCD, cast time 0 for Battle/War and 1 s for
  Restoration, 2-min CD + 2-min shared timer with explosives (`consumes.go:667-701`).
Lua port notes: +80 haste rating for 30 s every 120 s starting at the first autocast evaluation >= 11 s.

---

## 8. Major cooldowns and the autocast action

### 8.1 Registration (`major_cooldown.go:250-275`)
`AddMajorCooldown` adds `SpellFlagAPL | SpellFlagMCD`; `SpellFlagReactive` only for Survival MCDs with no cast
time, or with `AllowSpellQueueing`; nil `ShouldActivate` -> always true. Priorities (`major_cooldown.go:11-16`):
`CooldownPriorityLow = -1000, Default = 0, Bloodlust = 1000, Drums = 2000`. CooldownType bits:
`Mana = 2, DPS = 4, Explosive = 8, Survival = 16` (`1 << iota` with iota starting at 1).
Registration order (stable tie-break; `character.go:274-311`, `environment.go:118-139`): race (Arcane Torrent /
Stoneform) -> item effects (on-use trinkets, priority 0) -> talents -> buffs (Bloodlust, party Drums) -> consumes
(potion, conjured, explosives, consumable drums) -> class `Initialize()` (Avenging Wrath:
`Priority: int32(core.CooldownTypeDPS)` = 4, 3-min CD, 8% base mana, +30% damage for 20 s; `paladin/avenging_wrath.go`).
MCDs whose spell is referenced by any APL action are removed from the autocast set (`apl.go:280-288`); the Ret
default APL references none of the buff/consumable MCDs.

### 8.2 The APL action (`apl_actions_casting.go:468-499`)
```go
func (action *APLActionAutocastOtherCooldowns) IsReady(sim *Simulation) bool {
	action.nextReadyMCD = action.character.getFirstReadyMCD(sim)
	return (action.nextReadyMCD != nil) && ((action.character.GCD.IsReady(sim) != action.nextReadyMCD.Type.Matches(CooldownTypeExplosive)) || action.nextReadyMCD.Spell.Flags.Matches(SpellFlagReactive))
}
func (action *APLActionAutocastOtherCooldowns) Execute(sim *Simulation) {
	action.nextReadyMCD.tryActivateHelper(sim, action.character)
	action.character.UpdateMajorCooldowns()
}
```
`getFirstReadyMCD` (`major_cooldown.go:372-387`):
```go
if sim.CurrentTime < mcdm.minReady { return nil }
for _, mcd := range mcdm.majorCooldowns {   // sorted list
	if !mcd.IsReady(sim) { continue }
	if mcd.shouldActivateHelper(sim, mcdm.character) { return mcd }
}
```
`shouldActivateHelper` (`major_cooldown.go:132-148`): `Spell.CanCast` (own CD + shared CD ready, not hardcasting,
GCD ready only if the spell itself has a GCD, ExtraCastCondition) -> user timings (none) -> Survival HP threshold ->
`ShouldActivate`. Sort (`major_cooldown.go:400-407`): `ReadyAt()` ascending (max of own CD and shared CD), ties by
`Priority` descending, stable. Re-sorted at reset and after each autocast execution.

Consequences:
1. Non-explosive MCDs fire only when the **GCD is ready**; explosives only when the **GCD is NOT ready** (right after
   a GCD ability in the same evaluation).
2. Only the **first** ready+eligible MCD in sorted order is considered. If it is an explosive and the GCD is ready,
   the action is not ready this evaluation even if a non-explosive MCD further down is ready (and vice versa). E.g. a
   grenade that came off its shared CD earlier than Avenging Wrath sorts first and holds AW back until the grenade
   is thrown after the next GCD ability.
3. After `Execute`, the APL loop (`apl.go:446-453`) re-evaluates the list from the top in the same timestamp, so all
   eligible MCDs fire back-to-back. First eligible moment for the BE Ret preset: Drums (2000) -> Bloodlust (1000) ->
   Avenging Wrath (4) -> priority-0 MCDs in registration order (on-use trinkets, Haste Potion, Demonic Rune only if
   its mana condition holds) -> the rotation's GCD ability -> Super Sapper (explosive, GCD now busy) -> Arcane
   Torrent (-1000) waits for the next GCD-ready evaluation.
4. Evaluations only happen when the rotation wakes: at GCD-ready times and after reaction-time waits (`apl.go:464-472`:
   next = `max(now + ReactionTime, NextGCDAt)` when not moving). MCDs that come off CD mid-GCD wait for the next one.

### 8.3 "Delay Major CDs" gating (`ui/specs/paladin/retribution/apls/default.apl.json`)
```json
{"action":{"condition":{"cmp":{"op":"OpGe","lhs":{"currentTime":{}},"rhs":{"variableRef":{"name":"Delay Major CDs"}}}},"autocastOtherCooldowns":{}}},
...
{"name":"Delay Major CDs","value":{"const":{"val":"11s"}}},
```
`APLAction.IsReady` = `(condition == nil || condition.GetBool(sim)) && impl.IsReady(sim)` (`apl_action.go:26-28`),
so **every** autocast MCD (Drums, Bloodlust, potion, Demonic Rune, explosives, Arcane Torrent, Avenging Wrath,
trinkets, Stoneform) is suppressed until `currentTime >= 11 s`. Confirmed: the whole action is gated. It is the first
entry of the priority list. The APL does nothing at `t < 0` (`apl.go:410-412`), so this APL has no prepull MCD use.
Lua port notes: autocast list = sorted MCDs; evaluate at each APL wake-up from 11 s with the GCD rules above.

---

## 9. Base stats, race stats, stat dependencies (level 70 Paladin)

### 9.1 Tables (`base_stats.go`, `base_stats_auto_gen.go`)
`BaseStats[race,class] = ClassBaseStats[class] + RaceOffsets[race] + ExtraClassBaseStats[class]` (`base_stats.go:208-210`),
added with `character.AddStats(character.baseStats)` in `NewCharacter` (`character.go:140-143`).
Paladin class row: `Health 3197, Agility 77, Strength 126, Intellect 83, Spirit 89, Stamina 120,
AttackPower 70*3-20 = 190`; extra: `Mana 2953, SpellCritPercent 3.3355, PhysicalCritPercent 0.6520`.
Race offsets: Human 0; Blood Elf Agi+2 Str-3 Int+4 Spi-1 Sta-2; Draenei Agi-3 Str+1 Int+1 Spi+2 Sta-1; Dwarf Agi-4
Str+2 Int-1 Spi-1 Sta+3. Racial multipliers (Human Spirit) are not in the tables; they are applied in `racials.go`.

| Race | Str | Agi | Sta | Int | Spi | Notes |
|---|---|---|---|---|---|---|
| Human | 126 | 77 | 120 | 83 | 89 (x1.10 static -> 97.9, floored 97) | Mace/Sword spec 19.71154 expertise rating |
| Blood Elf | 123 | 79 | 118 | 87 | 88 | +5 all resists; Arcane Torrent |
| Draenei | 127 | 74 | 119 | 84 | 91 | +1% phys hit (Heroic Presence); +10 shadow res |
| Dwarf | 128 | 73 | 123 | 82 | 88 | +10 frost res; Stoneform MCD |
All four also get Health 3197, AP 190, Mana 2953 (before the -280 below), SpellCrit 3.3355%, PhysCrit 0.6520%.

Rating constants (`base_stats_auto_gen.go:12-22`): Expertise 3.942308 per 0.25%; Defense 2.365385; Dodge 18.923079;
Parry 23.653847; Block 7.884615; PhysicalHit 15.769233; SpellHit 12.615385; PhysicalCrit 22.076923;
SpellCrit 22.076923; PhysicalHaste 15.769233; SpellHaste 15.76923. `CritPerAgiMaxLevel[Paladin] = 0.04`,
`CritPerIntMaxLevel[Paladin] = 0.0125`.

### 9.2 Dependencies registered for a Paladin
```go
// unit.go:692-697 (all units)
MeleeHitRating -> PhysicalHitPercent  1/15.769233
SpellHitRating -> SpellHitPercent     1/12.615385
MeleeCritRating -> PhysicalCritPercent 1/22.076923
SpellCritRating -> SpellCritPercent   1/22.076923
// character.go:267-271 (all characters)
Stamina -> Health 10
Agility -> Armor 2
// mana.go:45-55 (EnableManaBar, players)
Intellect -> SpellCritPercent  CritPerIntMaxLevel[Paladin] = 0.0125
character.AddStat(stats.Mana, 20-15*20)          // -280
Intellect -> Mana 15
// paladin/paladin.go:116-131
PseudoStats.BaseDodgeChance += 0.0065; BaseParryChance += 0.05; BaseBlockChance += 0.05
Strength -> AttackPower 2
Agility -> PhysicalCritPercent 0.04
Agility -> DodgeRating 1/25.0*18.923079 (= 0.75692316)
BonusArmor -> Armor 1
```
No Str -> BlockValue dependency exists. Haste rating is not a dependency: melee haste multiplier =
`AttackSpeedMultiplier * MeleeSpeedMultiplier * (1 + MeleeHasteRating/1576.9233)`.
Resulting formulas (attribute sources floored, see 0.4):
- `MaxMana = 2953 - 280 + 15*floor(Int) = 2673 + 15*floor(Int)` (+ gear mana)
- `Health = 3197 + 10*floor(Sta)` (+ gear health)
- `AP = (190 + gear/buff AP + 2*floor(Str)) * AP multipliers (Unleashed Rage 1.1)`; target-side bonuses
  (Hunter's Mark 110, Expose Weakness) are added afterwards and not multiplied.
- `PhysicalCritPercent = 0.652 + 0.04*floor(Agi) + MeleeCritRating/22.076923 + flat % buffs (LotP 5)`
- `SpellCritPercent = 3.3355 + 0.0125*floor(Int) + SpellCritRating/22.076923`
- `PhysicalHitPercent = MeleeHitRating/15.769233 + flat % (Heroic Presence 1)`
Talent multipliers (Divine Strength, Divine Intellect, ...) are class code and out of scope.
Quirk: melee AP vs a target also adds `MobTypeBonusStats[target.MobType][stats.RangedAttackPower]` (`unit.go:217-219`),
which only matters with mob-type bonuses (e.g. Consecrated Sharpening Stone vs Undead).

---

## 10. Mana regeneration (`mana.go`), short

- `SpiritManaRegenPerSecond = 0.001 + Spirit*sqrt(Intellect)*0.009327`; `MP5ManaRegenPerSecond = MP5/5`.
- While "casting" (`CurrentTime < FiveSecondRuleRefreshTime`): `MP5/5 + spiritRegen*SpiritRegenMultiplier*SpiritRegenRateCasting`
  (SpiritRegenRateCasting is 0 by default) times `manaRegenMultiplier` (1). Not casting: `MP5/5 + spiritRegen*SpiritRegenMultiplier`.
- Every mana spend sets `FiveSecondRuleRefreshTime = max(now + 5 s, Hardcast.Expires)` (`mana.go:371-376`).
- One global tick every **2 s** (each tick = 2 x the per-second rate), first at `PrepullStartTime + 2 s` (Ret APL:
  -16.5 s, so in-combat ticks land at 1.5, 3.5, 5.5, ... s). `FiveSecondRuleRefreshTime` starts at 0, so prepull
  ticks (t < 0) use the casting rate.
- Rates are recomputed on any MP5/Int/Spirit change. Mana starts full at reset (after permanent buffs are applied).

---

## 11. Unresolved / caveats

- Partial-resist math for explosives (`spell_resistances.go`, level-based resistance) was not transcribed here.
- On-use trinket MCDs depend on gear (`common/tbc/*`), not covered.
- The exact order of a tracker expiry vs a pending action at the same timestamp (Expose Weakness re-roll at
  t = 7k s, GoA twisting) was not traced; it affects at most a zero-length gap.
