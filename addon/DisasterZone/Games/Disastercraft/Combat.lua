if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Combat.lua", ...) then return end -- DisasterZone Games/Disastercraft/Combat.lua
-- Craft.Combat: units (you, your party, creatures), their stats, auto attack, spells, auras, threat, death.
-- WoW TBC's rules as cMaNGOS plays them, kept to what the levels 1-10 use: the one-roll melee table (miss / dodge /
-- parry / glancing / block / crit / hit), spell hit by level difference, armour mitigation, rage from damage,
-- mana regeneration with the five-second rule, the global cooldown, cast times with pushback, channels, missiles
-- that fly, auras that tick, threat with the 110% / 130% rule.
--
-- A unit: { guid, kind = "player" | "remote" | "mob" | "npc" | "critter", name, level, class / entry, map, x, y,
--           face, hp, hpMax, power, powerMax, powerType, stats..., auras = {}, casting, target, threat, ... }
-- Rage is kept in tenths like the client (Heroic Strike costs 150 = 15 rage).
--
-- Who decides what: Combat.Owns(unit) - this client applies damage to the units it owns (itself; the creatures it
-- simulates). Party.lua swaps in the networked version; alone, everything is yours.
local addonName, ns = ...

local Craft = ns.Craft
local D = Craft.D
local Combat = {}
Craft.Combat = Combat

local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt
local Now, Chance, Roll = Craft.Now, Craft.Chance, Craft.Roll
local band = bit and bit.band or function(a, b)
    local r, m = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + m end
        a, b, m = floor(a / 2), floor(b / 2), m * 2
    end
    return r
end
Combat.band = band

Combat.units = {}                       -- guid -> unit (everything that can fight or be targeted)
Combat.missiles = {}                    -- spells in flight { spell, src, dst, arrive, ... }

local SCHOOL_NAMES = { [1] = "Physical", [2] = "Holy", [4] = "Fire", [8] = "Nature", [16] = "Frost", [32] = "Shadow",
                       [64] = "Arcane" }
Combat.SCHOOL_NAMES = SCHOOL_NAMES
Combat.SCHOOL_COLORS = { [1] = { 1, 1, 0 }, [2] = { 1, 0.9, 0.5 }, [4] = { 1, 0.5, 0 }, [8] = { 0.3, 1, 0.3 },
                         [16] = { 0.5, 1, 1 }, [32] = { 0.5, 0.5, 1 }, [64] = { 1, 0.5, 1 } }

-- the spell effects (SpellEffect.Effect, 2.5.6 numbering) and auras (EffectAura) the engine plays
local E_DAMAGE, E_DUMMY, E_AURA, E_HEAL, E_WEAPON, E_CREATE, E_ENERGIZE, E_WEAPON_PCT = 2, 3, 6, 10, 17, 24, 30, 31
local E_WEAPON_DMG, E_TRIGGER, E_ATTACK, E_CHARGE, E_NORM_WEAPON, E_TELEPORT, E_RESURRECT = 58, 64, 78, 96, 121, 252, 329
local A_DUMMY, A_CONFUSE, A_STUN, A_PDMG, A_PHEAL, A_STAT, A_RESIST, A_PTRIGGER, A_PENERGIZE = 4, 5, 12, 3, 8, 29, 22, 23, 24
local A_ROOT, A_SLOW, A_SHAPESHIFT, A_PROC, A_TRANSFORM, A_ABSORB, A_REGEN, A_POWER_REGEN = 26, 33, 36, 42, 56, 69, 84, 85
local A_AP, A_THREAT, A_HASTE, A_RESIST_PCT, A_DMG_DONE, A_PDUMMY, A_MOD_HP = 99, 103, 138, 101, 13, 226, 34
-- the talents' auras: threat by school, parry / dodge / block / crit / hit chances, a skill (Defense), the spell
-- modifiers (flat / percent), crit chance by school (the 2.5 client's Holy Specialization)
local A_MOD_THREAT, A_PARRY, A_DODGE, A_BLOCK, A_CRIT, A_HIT, A_SPELL_HIT, A_SPELL_CRIT = 10, 47, 49, 51, 52, 54, 55, 57
local A_SKILL, A_SKILL_TALENT, A_FLAT_MOD, A_PCT_MOD, A_SCHOOL_CRIT = 30, 98, 107, 108, 552
-- buffs on the character sheet: stat percent (Blessing of Kings, Arcane Mind), mana (MOD_INCREASE_ENERGY), healing
-- done, ranged attack power
local A_STAT_PCT, A_TOTAL_STAT_PCT, A_MOD_MANA, A_HEAL_DONE, A_RANGED_AP = 80, 137, 35, 135, 124
-- the talent rows' percent auras: damage done / taken by school, healing taken / done, cast speed, mana cost by
-- school, maximum mana, armor from items, armor from Intellect (Arcane Fortitude)
local A_DMG_PCT, A_DMG_TAKEN_PCT, A_HEAL_TAKEN_PCT, A_HEAL_DONE_PCT = 79, 87, 118, 136
local A_CAST_SPEED, A_COST_PCT, A_MANA_PCT, A_ARMOR_ITEMS_PCT, A_ARMOR_OF_INT = 65, 72, 132, 142, 571
-- what a spell modifier changes (SpellModOp)
local MOD_DAMAGE, MOD_DURATION, MOD_THREAT, MOD_EFFECT1, MOD_RANGE, MOD_RADIUS, MOD_CRIT, MOD_ALL_EFFECTS =
    0, 1, 2, 3, 5, 6, 7, 8
local MOD_PUSHBACK, MOD_CAST_TIME, MOD_COOLDOWN, MOD_EFFECT2, MOD_COST, MOD_HIT, MOD_DOT, MOD_EFFECT3 =
    9, 10, 11, 12, 14, 16, 22, 23
local MOD_OF_EFFECT = { [0] = MOD_EFFECT1, [1] = MOD_EFFECT2, [2] = MOD_EFFECT3 }
-- proc flags (SpellAuraOptions.ProcTypeMask)
local PROC_KILL, PROC_DEAL_SWING, PROC_TAKE_SWING, PROC_DEAL_MELEE_ABILITY, PROC_TAKE_MELEE_ABILITY =
    0x2, 0x4, 0x8, 0x10, 0x20
local PROC_DEAL_HARMFUL_SPELL, PROC_TAKE_HARMFUL_SPELL = 0x10000, 0x20000
Combat.PROC = { KILL = PROC_KILL, DEAL_SWING = PROC_DEAL_SWING, TAKE_SWING = PROC_TAKE_SWING,
                DEAL_MELEE_ABILITY = PROC_DEAL_MELEE_ABILITY, TAKE_MELEE_ABILITY = PROC_TAKE_MELEE_ABILITY,
                DEAL_HARMFUL_SPELL = PROC_DEAL_HARMFUL_SPELL, TAKE_HARMFUL_SPELL = PROC_TAKE_HARMFUL_SPELL }

---------------------------------------------------------------------------
-- Units
---------------------------------------------------------------------------

function Combat.Add(u)
    u.auras = u.auras or {}
    u.cooldowns = u.cooldowns or {}
    u.threat = u.threat or {}
    Combat.units[u.guid] = u
    return u
end

function Combat.Remove(u)
    if not u then return end
    Combat.units[u.guid] = nil
    for _, o in pairs(Combat.units) do
        if o.target == u then o.target = nil o.attacking = false end
        if o.threat then o.threat[u.guid] = nil end
    end
end

function Combat.Get(guid) return Combat.units[guid] end

function Combat.IsPlayer(u) return u and (u.kind == "player" or u.kind == "remote") end
function Combat.IsCreature(u) return u and (u.kind == "mob" or u.kind == "npc" or u.kind == "critter") end

-- reaction of a to b: "hostile" | "neutral" | "friendly"
function Combat.Reaction(a, b)
    if not a or not b then return "neutral" end
    if Combat.IsPlayer(a) and Combat.IsPlayer(b) then return "friendly" end
    local pa, pb = Combat.IsPlayer(a), Combat.IsPlayer(b)
    if pa or pb then
        local c = pa and b or a
        if c.kind == "npc" then return "friendly" end
        if c.kind == "critter" then return "neutral" end
        if c.hostile then return "hostile" end
        return "neutral"
    end
    -- creature to creature: friends unless one is a player's foe and the other a guard (not played yet)
    return "friendly"
end

function Combat.CanAttack(a, b)
    if not b or b.dead or b == a then return false end
    if b.kind == "npc" then return false end
    if Combat.IsPlayer(a) and Combat.IsPlayer(b) then return false end
    if Combat.IsCreature(a) and Combat.IsCreature(b) then return false end
    return true
end

function Combat.Owns(u)
    return u.kind == "player" or u.kind == "mob" or u.kind == "critter" or u.kind == "npc"
end

---------------------------------------------------------------------------
-- Stats (players: class base per level + gear + auras; creatures: their template)
---------------------------------------------------------------------------

local function AuraSum(u, aura, misc)
    local s = 0
    for _, a in ipairs(u.auras) do
        for _, e in ipairs(a.fx) do
            if e.a == aura and (misc == nil or e.misc == misc or (aura == A_STAT and e.misc == -1)) then
                s = s + (e.amount or 0)
            end
        end
    end
    return s
end
Combat.AuraSum = AuraSum

local function AuraMult(u, aura)
    local m = 1
    for _, a in ipairs(u.auras) do
        for _, e in ipairs(a.fx) do
            if e.a == aura then m = m * (1 + (e.amount or 0) / 100) end
        end
    end
    return m
end

-- auras whose misc is a school mask (resistances: bit 1 = armor; damage / healing done): the sum of those that
-- take in any of the bits
local function AuraSumMask(u, aura, bits)
    local s = 0
    for _, a in ipairs(u.auras) do
        for _, e in ipairs(a.fx) do
            if e.a == aura and band(e.misc or 0, bits) ~= 0 then s = s + (e.amount or 0) end
        end
    end
    return s
end

-- percent auras whose misc is a school mask (none: every school), as a factor for a school
local function PctMask(u, aura, bits)
    local m = 1
    for _, a in ipairs(u and u.auras or {}) do
        for _, e in ipairs(a.fx) do
            if e.a == aura and (not e.misc or e.misc == 0 or band(e.misc, bits or 1) ~= 0) then
                m = m * (1 + (e.amount or 0) / 100)
            end
        end
    end
    return m
end
Combat.PctMask = PctMask

-- a stat's percent auras (MOD_PERCENT_STAT, MOD_TOTAL_STAT_PERCENTAGE: misc = the stat, -1 = all) as a factor
local function StatMult(u, stat)
    local m = 1
    for _, a in ipairs(u.auras) do
        for _, e in ipairs(a.fx) do
            if (e.a == A_STAT_PCT or e.a == A_TOTAL_STAT_PCT) and (e.misc == stat or e.misc == -1) then
                m = m * (1 + (e.amount or 0) / 100)
            end
        end
    end
    return m
end

-- does an aura effect's class mask take in this spell (same class family, a shared bit)?
local function MaskMatches(e, sp, src)
    if not (e.cm and sp and sp.cm) then return false end
    if src and src.set and sp.set and src.set ~= sp.set then return false end
    for k = 1, 3 do
        if band(e.cm[k] or 0, sp.cm[k] or 0) ~= 0 then return true end
    end
    return false
end
Combat.MaskMatches = MaskMatches

-- the talents' spell modifiers (SPELL_AURA_ADD_FLAT_MODIFIER / ADD_PCT_MODIFIER): an aura on u whose class mask
-- takes in the spell changes one of its numbers. op: SpellModOp. -> v, changed
function Combat.SpellMod(u, sp, op, v)
    if not (u and u.auras and sp and sp.cm) then return v end
    local flat, pct = 0, 0
    for _, a in ipairs(u.auras) do
        local src
        for _, e in ipairs(a.fx) do
            if (e.a == A_FLAT_MOD or e.a == A_PCT_MOD) and e.misc == op and e.cm then
                src = src or D.spells[a.spell]
                if MaskMatches(e, sp, src) then
                    if e.a == A_FLAT_MOD then flat = flat + (e.amount or 0) else pct = pct + (e.amount or 0) end
                end
            end
        end
    end
    if flat == 0 and pct == 0 then return v end
    return (v + flat) * (1 + pct / 100)
end

-- a spell's crit chance for u: the spell crit, its modifiers, crit by school (Holy Specialization)
function Combat.SpellCritChance(u, sp)
    local c = (u.spellCrit or 0) + Combat.SpellMod(u, sp, MOD_CRIT, 0)
    for _, a in ipairs(u.auras or {}) do
        for _, e in ipairs(a.fx) do
            if e.a == A_SCHOOL_CRIT and ((e.misc and band(e.misc, sp.school or 1) ~= 0) or MaskMatches(e, sp)) then
                c = c + (e.amount or 0)
            end
        end
    end
    return c
end

-- threat from u's damage of this school / spell (Arcane Subtlety's -threat, the spell's own threat modifiers)
local function ThreatMult(u, school, sp)
    local m = 1
    for _, a in ipairs(u.auras or {}) do
        for _, e in ipairs(a.fx) do
            if e.a == A_MOD_THREAT and (not e.misc or band(e.misc, school or 1) ~= 0) then m = m * (1 + (e.amount or 0) / 100) end
        end
    end
    if sp then m = m * Combat.SpellMod(u, sp, MOD_THREAT, 1) end
    return m
end

function Combat.HasAura(u, auraType)
    for _, a in ipairs(u.auras) do
        for _, e in ipairs(a.fx) do if e.a == auraType then return a end end
    end
    return nil
end

function Combat.FindAura(u, spellId, caster)
    for i, a in ipairs(u.auras) do
        if a.spell == spellId and (not caster or a.caster == caster.guid) then return a, i end
    end
end

-- crit chance from agility / intellect at low levels (TBC's per-class ratios, base included)
local MELEE_CRIT = { [1] = { 0, 20 }, [5] = { 3, 20 }, [8] = { 3.2, 20 } }
local SPELL_CRIT = { [1] = { 0, 0 }, [5] = { 1.24, 60 }, [8] = { 0.91, 60 } }

function Combat.Recalc(u)
    if u.kind == "player" or u.kind == "remote" then
        local c = u.char
        local cd = D.classes[u.class]
        local lv = cd and cd.levels[min(u.level, #cd.levels)] or { 50, 0, 20, 20, 20, 20, 20 }
        local g = (u.kind == "player" and Craft.Items.GearStats(c)) or u.gear or Craft.Items.GearStats({ equip = {} })
        u.gearStats = g
        -- what buffs and debuffs add to each number (the character sheet shows those green / red, as WoW)
        local bonus = {}
        u.statBonus = bonus
        for i, k in ipairs({ "str", "agi", "sta", "int", "spi" }) do
            local base = lv[i + 2] + g[k]
            u[k] = floor((base + AuraSum(u, A_STAT, i - 1)) * StatMult(u, i - 1) + 0.5)
            bonus[k] = u[k] - base
        end
        local hpFromSta = min(20, u.sta) + max(0, u.sta - 20) * 10
        local old = u.hpMax
        u.hpMax = lv[1] + hpFromSta + g.hpBonus + AuraSum(u, A_MOD_HP)
        if old and u.hp then u.hp = min(u.hp, u.hpMax) end
        if u.class == 1 then
            u.powerType, u.powerMax = Craft.POWER_RAGE, 1000
        else
            u.powerType = Craft.POWER_MANA
            local oldP = u.powerMax
            u.powerMax = lv[2] + min(20, u.int) + max(0, u.int - 20) * 15 + g.manaBonus + AuraSum(u, A_MOD_MANA, 0)
            u.powerMax = floor(u.powerMax * PctMask(u, A_MANA_PCT, 1) + 0.5)    -- (Mental Strength)
            if oldP and u.power then u.power = min(u.power, u.powerMax) end
        end
        local armorBase = g.armor + (u.agi - bonus.agi) * 2
        -- (Toughness: armor from items; Arcane Fortitude: a share of Intellect)
        local itemArmor = g.armor * PctMask(u, A_ARMOR_ITEMS_PCT, 1)
        local intArmor = AuraSum(u, A_ARMOR_OF_INT) * u.int / 100
        u.armor = floor((itemArmor + intArmor + u.agi * 2 + AuraSumMask(u, A_RESIST, 1)) * AuraMult(u, A_RESIST_PCT))
        bonus.armor = u.armor - armorBase
        local function MeleeAP(str) return u.class == 1 and (u.level * 3 + str * 2 - 20) or max(0, str - 10) end
        u.ap = MeleeAP(u.str) + g.ap + AuraSum(u, A_AP)
        bonus.ap = u.ap - (MeleeAP(u.str - bonus.str) + g.ap)
        u.rap = max(0, u.level + u.agi * 2 - 10) + (g.rap or 0) + AuraSum(u, A_RANGED_AP)
        -- spell damage / healing from buffs (MOD_DAMAGE_DONE on a magic school; a physical one is melee damage)
        local spBuff = AuraSumMask(u, A_DMG_DONE, 126)
        u.sp = (g.sp or 0) + spBuff
        u.heal = (g.heal or g.sp or 0) + AuraSumMask(u, A_HEAL_DONE, 127)
        bonus.sp, bonus.heal = spBuff, u.heal - (g.heal or g.sp or 0)
        -- resistances (holy 1 .. arcane 6, as Items.GearStats) with the buffs' (Mark of the Wild, Shadow Protection)
        local res = {}
        for school = 1, 6 do
            res[school] = ((g.res or {})[school] or 0) + AuraSumMask(u, A_RESIST, 2 ^ school)
        end
        u.res = res
        local mc = MELEE_CRIT[u.class] or { 0, 20 }
        u.crit = mc[1] + u.agi / mc[2] + (u.class == 1 and 5 or 0) + (g.critR or 0) / 14 + AuraSum(u, A_CRIT)
        local sc = SPELL_CRIT[u.class] or { 0, 0 }
        u.spellCrit = sc[1] + (sc[2] > 0 and u.int / sc[2] or 0) + (g.spellCritR or 0) / 14 + AuraSum(u, A_SPELL_CRIT)
        -- Defense above the level's (Anticipation, gear): 0.04% dodge, parry, block and miss each, 0.04% less crit
        u.defense = (u.level or 1) * 5 + (g.defense or 0) + AuraSum(u, A_SKILL_TALENT, 95) + AuraSum(u, A_SKILL, 95)
        u.defBonus = max(0, u.defense - (u.level or 1) * 5) * 0.04
        u.dodge = 1 + u.agi / 20 + (g.dodgeR or 0) / 12 + AuraSum(u, A_DODGE) + u.defBonus
        u.parry = (u.spells and u.spells[3127]) and (5 + AuraSum(u, A_PARRY) + u.defBonus) or 0
        u.block = (u.char and u.char.equip[17] and D.items[u.char.equip[17]] and D.items[u.char.equip[17]].s == 6
                   and D.items[u.char.equip[17]].c == 4) and (5 + AuraSum(u, A_BLOCK) + u.defBonus) or 0
        u.blockValue = floor(u.str / 20) + (g.block or 0)
        u.hit = (g.hitR or 0) / 12 + AuraSum(u, A_HIT)
        u.spellHit = AuraSum(u, A_SPELL_HIT)
        -- weapons (unarmed: 1-2 at 2.0 s)
        local mh = g.mh or { 1, 2, 0, 2.0 }
        u.mh = { mh[1], mh[2], (mh[3] or 0) == 0 and 1 or (2 ^ mh[3]), mh[4] }
        u.oh = nil
        u.ranged = g.ranged and { g.ranged[1], g.ranged[2], (g.ranged[3] or 0) == 0 and 1 or (2 ^ g.ranged[3]),
                                  g.ranged[4], g.ranged[5] } or nil
    else
        local cr = u.cr or {}
        u.armor = floor(((cr.armor or 0) + AuraSum(u, A_RESIST, 1)) * AuraMult(u, A_RESIST_PCT))
        u.ap = (cr.ap or 0) + AuraSum(u, A_AP)
        local spd = (cr.spd or 2000) / 1000
        u.mh = { cr.dmg and cr.dmg[1] or 1, cr.dmg and cr.dmg[2] or 2, cr.school and (2 ^ cr.school) or 1, spd }
        u.crit, u.spellCrit = 5, 0
        u.dodge = 5
        u.parry = (cr.type == 7) and 5 or 0             -- (humanoids parry; beasts don't)
        u.block = 0
        u.hit = 0
        u.res = cr.resist
    end
    u.speedMult = 1
    for _, a in ipairs(u.auras) do
        for _, e in ipairs(a.fx) do
            if e.a == A_SLOW then u.speedMult = min(u.speedMult, 1 + (e.amount or 0) / 100) end
        end
    end
    u.hasteMult = AuraMult(u, A_HASTE)                  -- (< 1 = slower attacks)
end

-- a fresh player unit for the logged in character
function Combat.NewPlayer(c)
    local u = { guid = "P:" .. (c.name or "you"), kind = "player", name = c.name, level = c.level, class = c.class,
                char = c, spells = c.spells, map = c.map, x = c.x, y = c.y, face = c.face or "down" }
    Combat.Add(u)
    Combat.Recalc(u)
    u.hp = c.hp and min(c.hp, u.hpMax) or u.hpMax
    if u.powerType == Craft.POWER_RAGE then u.power = 0 else u.power = c.power and min(c.power, u.powerMax) or u.powerMax end
    if c.dead then u.dead = true u.hp = 0 end
    if c.ghost then u.ghost = true end
    -- the stance a warrior is born in
    if u.class == 1 and c.spells[2457] then Combat.ApplyAura(u, u, 2457, true) end
    if Craft.Talents then Craft.Talents.ApplyAll(u) end
    return u
end

-- a creature unit for a spawn (level rolled in its range, health scaled to it)
function Combat.NewCreature(guid, kind, entry, e)
    local cr = D.creatures[entry] or { n = e and e.n or "?", lv = { 1, 1 }, hp = { 40, 40 }, dmg = { 1, 2 }, spd = 2000 }
    local lv1, lv2 = cr.lv[1], cr.lv[2]
    if e and e.lv then lv1, lv2 = e.lv[1], e.lv[2] end
    local level = Roll(lv1, max(lv1, lv2))
    local hp = cr.hp[1]
    if cr.hp[2] and lv2 > lv1 then hp = floor(cr.hp[1] + (cr.hp[2] - cr.hp[1]) * (level - lv1) / (lv2 - lv1) + 0.5) end
    local u = { guid = guid, kind = kind, entry = entry, cr = cr, name = cr.n, level = level,
                hp = max(1, hp), hpMax = max(1, hp), powerType = Craft.POWER_MANA,
                hostile = (cr.hostile or (e and e.h)) and true or false, elite = (cr.rank or 0) > 0 }
    if cr.mana then u.powerMax = cr.mana[1] u.power = u.powerMax else u.powerMax, u.power = 0, 0 end
    Combat.Add(u)
    Combat.Recalc(u)
    return u
end

---------------------------------------------------------------------------
-- Spells: numbers, targets, costs
---------------------------------------------------------------------------

function Combat.Spell(id) return D.spells[id] end

local function SpellLevel(sp) return sp.baseLvl or sp.lvl or 1 end

-- an effect's value at the caster's level: bp + 1..die, plus the per-level growth up to the spell's max level
function Combat.EffectValue(sp, e, caster, roll)
    local v = e.bp or 0
    if e.rplv and caster then
        local lvl = caster.level or 1
        if sp.maxLvl and sp.maxLvl > 0 then lvl = min(lvl, sp.maxLvl) end
        v = v + floor(e.rplv * max(0, lvl - SpellLevel(sp)))
    end
    local die = e.die or 0
    if die > 0 then v = v + (roll == false and 1 or Roll(1, die)) end
    if caster and sp.cm then
        v = Combat.SpellMod(caster, sp, MOD_ALL_EFFECTS, v)
        if MOD_OF_EFFECT[e.i or 0] then v = Combat.SpellMod(caster, sp, MOD_OF_EFFECT[e.i or 0], v) end
    end
    return v
end

-- the range of an effect's value (for tooltips): min, max
function Combat.EffectRange(sp, e, caster)
    local v = e.bp or 0
    if e.rplv and caster then
        local lvl = caster.level or 1
        if sp.maxLvl and sp.maxLvl > 0 then lvl = min(lvl, sp.maxLvl) end
        v = v + floor(e.rplv * max(0, lvl - SpellLevel(sp)))
    end
    local die = e.die or 0
    if die > 0 then return v + 1, v + die end
    return v, v
end

function Combat.Duration(sp, caster)
    local d = sp.dur
    if not d then return nil end
    if d < 0 then return -1 end
    if sp.durLv and caster then d = d + sp.durLv * max(0, (caster.level or 1) - SpellLevel(sp)) end
    if sp.durMax and sp.durMax > 0 then d = min(d, sp.durMax) end
    if caster then d = Combat.SpellMod(caster, sp, MOD_DURATION, d) end
    return d / 1000
end

-- seconds (u: the caster - its Improved Fireball and the like)
function Combat.CastTime(sp, u)
    local ms = sp.cast or 0
    if u and ms > 0 then
        ms = max(0, Combat.SpellMod(u, sp, MOD_CAST_TIME, ms))
        ms = ms / PctMask(u, A_CAST_SPEED, sp.school or 1)          -- (Icy Veins, Power Infusion)
    end
    return ms / 1000
end

-- the spell's reach for u (yards)
function Combat.Range(sp, u)
    local r = sp.range or Craft.MELEE_RANGE
    if u and sp.range then r = Combat.SpellMod(u, sp, MOD_RANGE, r) end
    return r
end

function Combat.Cost(sp, u)
    if not sp.pt and not sp.cost and not sp.costPct then return 0, nil end
    local pt = sp.pt or 0
    local cost = sp.cost or 0
    if sp.costLv and u then cost = cost + sp.costLv * max(0, (u.level or 1) - SpellLevel(sp)) end
    if sp.costPct and sp.costPct > 0 and u then
        local base
        if pt == -2 then base = (D.classes[u.class] and D.classes[u.class].levels[min(u.level, 10)][1]) or u.hpMax
        else base = (D.classes[u.class] and D.classes[u.class].levels[min(u.level, 10)][2]) or u.powerMax end
        cost = cost + floor(base * sp.costPct / 100)
    end
    if u then
        cost = Combat.SpellMod(u, sp, MOD_COST, cost) * PctMask(u, A_COST_PCT, sp.school or 1)
        cost = max(0, floor(cost + 0.5))
    end
    return cost, pt
end

local function IsChannel(sp)
    local a1 = sp.attr and sp.attr[2] or 0
    return band(a1, 0x4) ~= 0 or band(a1, 0x40) ~= 0
end
Combat.IsChannel = IsChannel

local function IsNextSwing(sp)
    local a0 = sp.attr and sp.attr[1] or 0
    return band(a0, 0x4) ~= 0 or band(a0, 0x400) ~= 0
end
Combat.IsNextSwing = IsNextSwing

local function IsPassive(sp)
    local a0 = sp.attr and sp.attr[1] or 0
    return band(a0, 0x40) ~= 0
end
Combat.IsPassive = IsPassive

-- what a spell wants as its target: "enemy" | "friend" | "self" | "none"
local ENEMY_T = { [6] = true, [25] = true, [77] = true, [53] = true }
local FRIEND_T = { [21] = true, [57] = true, [35] = true }
function Combat.TargetKind(sp)
    if sp.fx then
        for _, e in ipairs(sp.fx) do
            if e.e == E_ATTACK then return "enemy" end
            if e.t1 and ENEMY_T[e.t1] then return "enemy" end
        end
        for _, e in ipairs(sp.fx) do
            if e.t1 and FRIEND_T[e.t1] then return "friend" end
        end
    end
    if sp.fx and sp.fx[1] and sp.fx[1].e == E_WEAPON then return "enemy" end
    return "self"
end

---------------------------------------------------------------------------
-- Combat state, threat
---------------------------------------------------------------------------

local COMBAT_LINGER = 5

function Combat.EnterCombat(u, foe)
    if not u or u.dead then return end
    if not u.inCombat then
        u.inCombat = true
        if u.kind == "player" then
            Craft:Emit("combat", true)
            -- eating and drinking stop
            Combat.RemoveAurasByInterrupt(u, 0x40000)
        end
    end
    u.combatUntil = Now() + COMBAT_LINGER
    if foe and Combat.IsCreature(u) and Combat.CanAttack(u, foe) then
        if not u.threat[foe.guid] then u.threat[foe.guid] = 0 end
        u.engaged = u.engaged or Now()
        if not u.target then u.target = foe end
    end
end

-- threat of `from` on creature `mob`
function Combat.AddThreat(mob, from, amount)
    if not mob or mob.dead or not Combat.IsCreature(mob) or not from or from.dead then return end
    if Combat.IsCreature(from) then return end
    local mult = 1
    if from.class == 1 then mult = 0.8 end             -- (battle stance)
    for _, a in ipairs(from.auras) do
        for _, e in ipairs(a.fx) do
            if e.a == A_THREAT then mult = mult * (1 + (e.amount or 0) / 100) end
        end
    end
    mob.threat[from.guid] = max(0, (mob.threat[from.guid] or 0) + amount * mult)
    Combat.EnterCombat(mob, from)
    Combat.EnterCombat(from, mob)
end

-- the creature's pick: the highest threat, but a new one must beat the current by 10% (in melee) or 30%
function Combat.PickTarget(mob)
    local cur = mob.target
    local curT = cur and not cur.dead and mob.threat[cur.guid] or nil
    local best, bestT
    for guid, t in pairs(mob.threat) do
        local u = Combat.units[guid]
        if u and not u.dead and not u.ghost and u.map == mob.map then
            if not bestT or t > bestT then best, bestT = u, t end
        else
            mob.threat[guid] = nil
        end
    end
    if not best then return nil end
    if curT and best ~= cur then
        local need = (Craft.UnitDist(mob, best) <= Craft.MELEE_RANGE + 1) and 1.1 or 1.3
        if bestT < curT * need then return cur end
    end
    return best
end

---------------------------------------------------------------------------
-- Damage and healing
---------------------------------------------------------------------------

-- rage for dealing / taking damage (TBC: 15d/4c + f*s/2 for melee hits, 2.5d/c for damage taken)
local function RageC(level) return 0.0091107836 * level * level + 3.225598133 * level + 4.2652911 end

function Combat.GainPower(u, amount, ptype)
    if not u or u.dead then return end
    if ptype ~= nil and ptype ~= u.powerType then return end
    u.power = Craft.Clamp((u.power or 0) + amount, 0, u.powerMax or 0)
end

-- absorbs (Power Word: Shield) eat into the damage first
local function Absorb(dst, amount, school)
    local absorbed = 0
    for i = #dst.auras, 1, -1 do
        local a = dst.auras[i]
        for _, e in ipairs(a.fx) do
            if e.a == A_ABSORB and (not e.misc or band(e.misc, school) ~= 0) and (e.amount or 0) > 0 and amount > 0 then
                local take = min(e.amount, amount)
                e.amount = e.amount - take
                amount = amount - take
                absorbed = absorbed + take
                if e.amount <= 0 then Combat.RemoveAura(dst, a, "absorbed") end
            end
        end
    end
    return amount, absorbed
end

-- the one place damage lands. info = { school, spell, kind = "melee"|"spell"|"dot"|"ranged", result, crit,
-- glancing, blocked, swing (weapon speed) }
function Combat.Damage(src, dst, amount, info)
    if not dst or dst.dead then return 0 end
    info = info or {}
    local school = info.school or 1
    -- damage done (Enrage, Arcane Instability, Shadowform) and taken (Shadowform) by school
    if src and src ~= dst then amount = amount * PctMask(src, A_DMG_PCT, school) end
    amount = amount * PctMask(dst, A_DMG_TAKEN_PCT, school)
    amount = max(0, floor(amount + 0.5))
    local absorbed = 0
    amount, absorbed = Absorb(dst, amount, school)
    info.absorbed = absorbed > 0 and absorbed or nil
    if Combat.Net and not Combat.Owns(dst) then
        -- someone else's unit: tell its owner; show it now (the owner's answer corrects the health)
        Combat.Net.Damage(src, dst, amount, info)
    end
    local before = dst.hp
    dst.hp = max(0, dst.hp - amount)
    local dealt = before - dst.hp
    -- threat, combat, rage
    if src and src ~= dst then
        Combat.EnterCombat(dst, src)
        Combat.EnterCombat(src, dst)
        if Combat.IsCreature(dst) then
            local th = (amount + (info.threat or 0)) * ThreatMult(src, school, info.spell and D.spells[info.spell])
            Combat.AddThreat(dst, src, th)
        end
        if src.powerType == Craft.POWER_RAGE and info.kind == "melee" and amount > 0 then
            local c = RageC(src.level or 1)
            local f = info.crit and 7 or 3.5
            local r = 15 * amount / (4 * c) + f * (info.swing or 2) / 2
            r = min(r, 15 * amount / c)
            Combat.GainPower(src, floor(r * 10))
        end
    end
    if dst.powerType == Craft.POWER_RAGE and amount > 0 and src ~= dst then
        Combat.GainPower(dst, floor(2.5 * amount / RageC(dst.level or 1) * 10))
    end
    -- what damage breaks: polymorph, roots (some), eating; casts get pushed back
    if amount > 0 and src ~= dst then
        for i = #dst.auras, 1, -1 do
            local a = dst.auras[i]
            for _, e in ipairs(a.fx) do
                if e.a == A_CONFUSE or e.a == A_TRANSFORM then Combat.RemoveAura(dst, a, "broken") break end
                if e.a == A_ROOT and info.kind ~= "dot" and Chance(25) then Combat.RemoveAura(dst, a, "broken") break end
            end
        end
        Combat.RemoveAurasByInterrupt(dst, 0x2)        -- (AURA_INTERRUPT damage: food, drink)
        Combat.Pushback(dst)
    end
    Craft:Emit("damage", src, dst, amount, info)
    if dst.hp <= 0 then Combat.Die(dst, src) end
    return dealt
end

function Combat.Heal(src, dst, amount, info)
    if not dst or dst.dead then return 0 end
    info = info or {}
    -- healing done (Spiritual Healing) and taken (Mortal Strike's wound)
    if src then amount = amount * PctMask(src, A_HEAL_DONE_PCT, 127) end
    amount = amount * PctMask(dst, A_HEAL_TAKEN_PCT, 127)
    amount = max(0, floor(amount + 0.5))
    if Combat.Net and not Combat.Owns(dst) then Combat.Net.Heal(src, dst, amount, info) end
    local before = dst.hp
    dst.hp = min(dst.hpMax, dst.hp + amount)
    local healed = dst.hp - before
    -- healing threat: half the effective healing, shared among the creatures fighting the healer
    if src and Combat.IsPlayer(src) and healed > 0 and dst.inCombat then
        local mobs = {}
        for _, m in pairs(Combat.units) do
            if Combat.IsCreature(m) and not m.dead and m.threat[dst.guid] or (m.threat and m.threat[src.guid]) then
                mobs[#mobs + 1] = m
            end
        end
        for _, m in ipairs(mobs) do Combat.AddThreat(m, src, healed * 0.5 / #mobs) end
    end
    info.overheal = amount - healed
    Craft:Emit("heal", src, dst, healed, info)
    return healed
end

function Combat.Die(u, killer)
    if u.dead then return end
    u.dead = true
    u.hp = 0
    u.casting = nil
    u.attacking = false
    u.deathAt = Now()
    for i = #u.auras, 1, -1 do
        local a = u.auras[i]
        if not a.passive then table.remove(u.auras, i) end
    end
    Combat.Recalc(u)
    -- nobody keeps fighting a dead unit
    for _, o in pairs(Combat.units) do
        if o.threat then o.threat[u.guid] = nil end
        if o.target == u and Combat.IsCreature(o) then o.target = nil end
        if o.target == u and o.attacking then o.attacking = false end
    end
    if u.kind == "player" then
        u.inCombat = false
        Craft:Emit("combat", false)
        if u.char then u.char.dead = true u.char.corpse = { map = u.map, x = u.x, y = u.y } end
    end
    -- a kill that yields experience (Spirit Tap)
    if killer and killer ~= u and Combat.IsPlayer(killer) and Combat.IsCreature(u)
       and Craft.KillXP(killer.level or 1, u.level or 1, u.elite) > 0 then
        Combat.Proc(killer, PROC_KILL, u, nil, { result = "kill" })
    end
    Craft:Emit("death", u, killer)
end

---------------------------------------------------------------------------
-- Attack rolls
---------------------------------------------------------------------------

-- the melee table for a white swing (special = a yellow attack: no glancing, crit rolled apart)
function Combat.MeleeRoll(a, d, special)
    local diff = (d.level or 1) - (a.level or 1)
    local miss = max(0, 5 + (diff > 0 and (diff >= 3 and 3 or diff * 0.5) or diff * 0.5) - (a.hit or 0) + (d.defBonus or 0))
    if special then miss = max(0, miss) end
    local dodge = max(0, (d.dodge or 0) + diff * 0.5)
    local parry = (d.parry or 0) > 0 and max(0, d.parry + diff * 0.5) or 0
    local glance = 0
    if not special and Combat.IsPlayer(a) and Combat.IsCreature(d) then glance = max(0, 10 + diff * 10) end
    local block = (d.block or 0) > 0 and (d.block + diff * 0.5) or 0
    local crit = max(0, (a.crit or 5) - (diff > 0 and diff or 0) * (Combat.IsPlayer(a) and 1 or 0.2) - (d.defBonus or 0))
    if (d.stunned or d.cc) then dodge, parry, block = 0, 0, 0 end
    local r = Craft.rng() * 100
    if r < miss then return "miss" end
    r = r - miss
    if r < dodge then return "dodge" end
    r = r - dodge
    if r < parry then return "parry" end
    r = r - parry
    if r < glance then return "glancing" end
    r = r - glance
    if r < block then return "block" end
    r = r - block
    if not special and r < crit then return "crit" end
    if special and Chance(crit) then return "crit" end
    return "hit"
end

function Combat.SpellHit(a, d, sp)
    if not Combat.IsPlayer(d) and Combat.IsCreature(a) then return true end
    local diff = (d.level or 1) - (a.level or 1)
    local miss
    if diff >= 3 then miss = 17 + (diff - 3) * 11
    elseif diff >= 0 then miss = 4 + diff
    else miss = max(1, 4 + diff) end
    miss = miss - (a.spellHit or 0) - (sp and Combat.SpellMod(a, sp, MOD_HIT, 0) or 0)
    return not Chance(max(1, miss))
end

function Combat.ArmorReduce(armor, attackerLevel)
    armor = max(0, armor or 0)
    local dr = armor / (armor + 400 + 85 * (attackerLevel or 1))
    return min(0.75, dr)
end

local function Mitigate(a, d, amount, school)
    if school == 1 then
        return amount * (1 - Combat.ArmorReduce(d.armor, a.level))
    end
    return amount
end
Combat.Mitigate = Mitigate

-- one weapon swing's raw damage (before armour)
function Combat.WeaponDamage(u, weapon, normalized)
    weapon = weapon or u.mh
    local base = Roll(floor(weapon[1]), max(floor(weapon[1]), floor(weapon[2] + 0.5)))
    local speed = normalized or weapon[4] or 2
    return base + (u.ap or 0) / 14 * speed
end

-- a melee swing (white, or with the queued "next swing" spell)
function Combat.Swing(a, d)
    if not a or not d or a.dead or d.dead then return end
    local queued = a.nextSwing
    a.nextSwing = nil
    local sp = queued and D.spells[queued]
    if sp then
        local cost, pt = Combat.Cost(sp, a)
        if (a.power or 0) < cost then sp = nil
        else Combat.GainPower(a, -cost) end
    end
    local result = Combat.MeleeRoll(a, d, sp ~= nil)
    local speed = (a.mh and a.mh[4] or 2) / (a.hasteMult or 1)
    local info = { kind = "melee", school = a.mh and a.mh[3] or 1, result = result, spell = sp and queued or nil,
                   swing = speed }
    if result == "miss" or result == "dodge" or result == "parry" then
        Craft:Emit("damage", a, d, 0, info)
        Combat.EnterCombat(d, a)
        Combat.EnterCombat(a, d)
        if Combat.IsCreature(d) then Combat.AddThreat(d, a, 0) end
        -- (a parry speeds up the defender's next swing, like WoW)
        if result == "parry" and d.swingAt then d.swingAt = d.swingAt - (d.mh and d.mh[4] or 2) * 0.4 end
        Combat.AfterSwing(a, d, info)
        return
    end
    local dmg = Combat.WeaponDamage(a)
    if sp then
        for _, e in ipairs(sp.fx) do
            if e.e == E_WEAPON or e.e == E_WEAPON_DMG then dmg = dmg + Combat.EffectValue(sp, e, a) end
        end
        if sp.threat then info.threat = sp.threat[1] end
        Craft:Emit("spellhit", a, queued, d)
    end
    if result == "crit" then dmg = dmg * 2 info.crit = true end
    if result == "glancing" then
        local diff = max(0, (d.level or 1) - (a.level or 1))
        dmg = dmg * max(0.65, 0.95 - 0.1 * diff)
        info.glancing = true
    end
    dmg = Mitigate(a, d, dmg, info.school)
    if result == "block" then
        info.blocked = min(dmg, d.blockValue or 0)
        dmg = dmg - info.blocked
    end
    for _, x in ipairs(a.auras) do                      -- (Hex of Weakness and the like)
        for _, e in ipairs(x.fx) do
            if e.a == A_DMG_DONE and band(e.misc or 1, 1) ~= 0 then dmg = dmg + (e.amount or 0) end
        end
    end
    Combat.Damage(a, d, max(1, dmg), info)
    Combat.AfterSwing(a, d, info)
end

-- after a swing: the swinger's and the struck one's procs
function Combat.AfterSwing(a, d, info)
    if info.result == "miss" then return end
    if info.spell then Combat.Proc(a, PROC_DEAL_MELEE_ABILITY, d, info.spell, info)
    else Combat.Proc(a, PROC_DEAL_SWING, d, nil, info) end
    if not d.dead then
        Combat.Proc(d, info.spell and PROC_TAKE_MELEE_ABILITY or PROC_TAKE_SWING, a, info.spell, info)
    end
end

-- what a proc needs beyond its flags (the client's hit masks): Shield Specialization's rage on a block
local PROC_NEEDS = { [12298] = "block" }

-- u's proc auras (SPELL_AURA_PROC_TRIGGER_SPELL) for an event: flag = PROC_*, other = the unit on the other end,
-- spellId = the spell that did it (its class mask must match the proc's, when the proc has one)
function Combat.Proc(u, flag, other, spellId, info)
    if not u or u.dead then return end
    local by = spellId and D.spells[spellId]
    for _, x in ipairs(u.auras) do
        local sp = D.spells[x.spell]
        for _, e in ipairs(x.fx) do
            if e.a == A_PROC and e.trig and sp then
                -- (no flags in the data: an old-style "when struck in melee" proc, like Frost Armor's)
                local flags = sp.procFlags or (PROC_TAKE_SWING + PROC_TAKE_MELEE_ABILITY)
                local need = PROC_NEEDS[sp.first or x.spell]
                if band(flags, flag) ~= 0 and (not e.cm or MaskMatches(e, by, sp))
                   and (not need or (info and info.result == need)) then
                    local chance = (sp.procChance and sp.procChance <= 100) and sp.procChance or 100
                    if Chance(chance) then
                        local t = D.spells[e.trig] and Combat.TargetKind(D.spells[e.trig]) == "enemy" and other or u
                        if t and not t.dead then Combat.CastSpell(u, e.trig, t, { triggered = true, noMiss = true }) end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Auras
---------------------------------------------------------------------------

local function AuraKey(sp, spellId, caster, helpful)
    local base = sp.first or spellId
    return helpful and ("b" .. base) or ("d" .. base .. "|" .. (caster and caster.guid or ""))
end

-- applies spell's aura effects to target (from caster); returns the aura
function Combat.ApplyAura(caster, target, spellId, helpful, onlyIdx)
    local sp = D.spells[spellId]
    if not sp or not target or target.dead then return nil end
    if helpful == nil then helpful = Combat.Reaction(caster, target) ~= "hostile" end
    local fx = {}
    for _, e in ipairs(sp.fx or {}) do
        if e.e == E_AURA and e.a and (not onlyIdx or onlyIdx[e.i]) then
            local amount = Combat.EffectValue(sp, e, caster)
            if (e.a == A_PDMG or e.a == A_PHEAL) and caster then amount = Combat.SpellMod(caster, sp, MOD_DOT, amount) end
            local x = { a = e.a, misc = e.misc, amount = amount, per = e.per and e.per / 1000 or nil, trig = e.trig,
                        i = e.i, cm = e.cm }
            if e.per then x.next = Now() + e.per / 1000 end
            if e.a == A_REGEN or e.a == A_POWER_REGEN or (e.a == A_PDUMMY and spellId and sp.n == "Drink") then
                x.per, x.next = 1, Now() + 1                  -- (food / drink: a fifth of the value every second)
            end
            if e.a == A_ABSORB and e.coef and caster then x.amount = x.amount + floor((caster.sp or 0) * e.coef) end
            fx[#fx + 1] = x
        end
    end
    if #fx == 0 then return nil end
    local dur = Combat.Duration(sp, caster)
    local key = AuraKey(sp, spellId, caster, helpful)
    -- a stance replaces the other stance; a buff replaces its weaker rank
    for i = #target.auras, 1, -1 do
        local o = target.auras[i]
        if o.key == key then table.remove(target.auras, i) end
    end
    local a = { key = key, spell = spellId, caster = caster and caster.guid, helpful = helpful, fx = fx,
                applied = Now(), dur = dur, expires = (dur and dur > 0) and (Now() + dur) or nil,
                passive = IsPassive(sp) or dur == -1 }
    table.insert(target.auras, a)
    Combat.Recalc(target)
    -- control effects
    for _, x in ipairs(fx) do
        if x.a == A_STUN then target.stunned = true target.casting = nil end
        if x.a == A_CONFUSE or x.a == A_TRANSFORM then target.cc = true target.casting = nil target.attacking = false end
        if x.a == A_ROOT then target.rooted = true end
        if x.a == A_SHAPESHIFT and target.kind == "player" then target.stance = x.misc end
    end
    Craft:Emit("aura", target, a, true)
    return a
end

local function RefreshControl(u)
    u.stunned, u.cc, u.rooted = nil, nil, nil
    for _, a in ipairs(u.auras) do
        for _, x in ipairs(a.fx) do
            if x.a == A_STUN then u.stunned = true end
            if x.a == A_CONFUSE or x.a == A_TRANSFORM then u.cc = true end
            if x.a == A_ROOT then u.rooted = true end
        end
    end
end

function Combat.RemoveAura(u, a, why)
    for i, o in ipairs(u.auras) do
        if o == a then
            table.remove(u.auras, i)
            RefreshControl(u)
            Combat.Recalc(u)
            Craft:Emit("aura", u, a, false, why)
            return true
        end
    end
    return false
end

-- auras that end on an event (spell AuraInterruptFlags: 0x2 damage, 0x8 moving, 0x40000 standing up / combat ...)
function Combat.RemoveAurasByInterrupt(u, flag)
    for i = #u.auras, 1, -1 do
        local a = u.auras[i]
        local sp = D.spells[a.spell]
        if sp and sp.auraIntr and band(sp.auraIntr, flag) ~= 0 then Combat.RemoveAura(u, a, "interrupt") end
    end
end

-- right-click on a buff: cancel it (helpful ones only, like WoW)
function Combat.CancelAura(u, a)
    if a and a.helpful and not a.passive then Combat.RemoveAura(u, a, "cancel") end
end

local function TickAura(u, a, x, now)
    local caster = a.caster and Combat.units[a.caster] or nil
    local sp = D.spells[a.spell]
    if x.a == A_PDMG then
        local amt = x.amount
        if sp and caster then
            for _, e in ipairs(sp.fx) do
                if e.i == x.i and e.coef then amt = amt + (caster.sp or 0) * e.coef / max(1, (a.dur or 1) / (x.per or 3)) end
            end
        end
        if caster == nil or Combat.Owns(u) or (caster and caster.kind == "player") then
            Combat.Damage(caster, u, amt, { kind = "dot", school = sp and sp.school or 1, spell = a.spell })
        end
    elseif x.a == A_PHEAL then
        Combat.Heal(caster, u, x.amount, { kind = "hot", spell = a.spell })
    elseif x.a == 20 then                                   -- (OBS_MOD_HEALTH: a share of max health - Blood Craze)
        Combat.Heal(caster or u, u, (u.hpMax or 0) * (x.amount or 0) / 100, { kind = "hot", spell = a.spell })
    elseif x.a == A_REGEN then
        if u.kind == "player" and u.hp < u.hpMax then
            u.regenAcc = (u.regenAcc or 0) + x.amount / 5
            local whole = floor(u.regenAcc)
            u.regenAcc = u.regenAcc - whole
            u.hp = min(u.hpMax, u.hp + whole)
        end
    elseif x.a == A_POWER_REGEN or x.a == A_PDUMMY then
        if u.powerType == Craft.POWER_MANA and x.amount > 0 then
            u.manaAcc = (u.manaAcc or 0) + x.amount / 5
            local whole = floor(u.manaAcc)
            u.manaAcc = u.manaAcc - whole
            u.power = min(u.powerMax, u.power + whole)
        end
    elseif x.a == A_PENERGIZE then
        Combat.GainPower(u, x.amount, x.misc)
    elseif x.a == A_PTRIGGER and x.trig then
        -- a channel's ticks (Arcane Missiles): the trigger spell flies at the channel's target
        local tgt = u.casting and u.casting.target or (u.target)
        if tgt and not tgt.dead then Combat.CastSpell(u, x.trig, tgt, { triggered = true }) end
    end
end

---------------------------------------------------------------------------
-- Casting
---------------------------------------------------------------------------

function Combat.OnCooldown(u, sp, id)
    local now = Now()
    local t = u.cooldowns[id]
    if t and t > now then return t - now end
    if sp.cat and u.cooldowns["c" .. sp.cat] and u.cooldowns["c" .. sp.cat] > now then
        return u.cooldowns["c" .. sp.cat] - now
    end
    return nil
end

function Combat.CooldownLeft(u, id)
    local sp = D.spells[id]
    if not sp then return 0, 0 end
    local now = Now()
    local best, total = 0, 0
    local t = u.cooldowns[id]
    if t and t > now then best, total = t - now, (u.cdTotal and u.cdTotal[id] or 0) end
    local ct = sp.cat and u.cooldowns["c" .. sp.cat]
    if ct and ct > now and ct - now > best then best, total = ct - now, (u.cdTotal and u.cdTotal["c" .. sp.cat] or 0) end
    if (sp.gcd or 0) > 0 and u.gcdEnd and u.gcdEnd > now and u.gcdEnd - now > best then
        best, total = u.gcdEnd - now, u.gcdLen or Craft.GCD
    end
    return best, total
end

local function StartCooldown(u, sp, id, opts)
    u.cdTotal = u.cdTotal or {}
    local now = Now()
    local cd = (sp.cd or 0) > 0 and Combat.SpellMod(u, sp, MOD_COOLDOWN, sp.cd) or 0
    if cd > 0 then u.cooldowns[id] = now + cd / 1000 u.cdTotal[id] = cd / 1000 end
    if sp.cat and (sp.catCd or 0) > 0 then
        u.cooldowns["c" .. sp.cat] = now + sp.catCd / 1000
        u.cdTotal["c" .. sp.cat] = sp.catCd / 1000
    end
    local icd = opts and opts.itemCd
    if icd and icd[5] and icd[5] > 0 and icd[6] and icd[6] > 0 then
        u.cooldowns["c" .. icd[5]] = now + icd[6] / 1000
        u.cdTotal["c" .. icd[5]] = icd[6] / 1000
    end
end

-- range check in yards between edges (a little reach for both)
function Combat.InRange(a, b, maxYd, minYd)
    local d = Craft.UnitDist(a, b)
    if maxYd and maxYd > 0 and d > maxYd + 1.5 then return false, "far" end
    if minYd and minYd > 0 and d < minYd then return false, "near" end
    return true
end

local ERRORS = {
    mana = "Not enough mana", rage = "Not enough rage", energy = "Not enough energy", health = "Not enough health",
    far = "Out of range.", near = "Target too close.", target = "Invalid target", dead = "You are dead.",
    busy = "Another action is in progress", cd = "Spell is not ready yet.", gcd = "Ability is not ready yet.",
    moving = "You can't do that while moving.", combat = "You are in combat.", stunned = "Can't do that while stunned",
    notarget = "You have no target.", friendly = "Can only use on friendly targets.",
    enemy = "You cannot attack that target.", weapon = "Must have a Ranged Weapon equipped",
    targetDead = "Your target is dead.",
}
Combat.ERRORS = ERRORS

-- Casts spell id. target: the unit (nil = the caster's target / self as the spell wants). Returns true when the
-- cast started or went off. opts: { triggered = true (no costs / checks), item = id, b, s, itemCd }
function Combat.CastSpell(u, id, target, opts)
    local sp = D.spells[id]
    if not sp or not u then return false end
    opts = opts or {}
    local trig = opts.triggered or opts.ai              -- (a creature's script times its own spells)
    local function fail(key)
        if u.kind == "player" and not trig then Craft:Error(ERRORS[key] or key) end
        return false
    end
    if u.dead then return fail("dead") end
    if not trig then
        if u.stunned or u.cc then return fail("stunned") end
        if u.casting then return fail("busy") end
    end
    -- the target this spell needs
    local kind = Combat.TargetKind(sp)
    if kind == "enemy" then
        target = target or u.target
        if not target then return fail("notarget") end
        if target.dead then return fail("targetDead") end
        if not Combat.CanAttack(u, target) then return fail("enemy") end
    elseif kind == "friend" then
        if not target then
            target = u.target
            if not target or Combat.Reaction(u, target) == "hostile" or Combat.IsCreature(target) then target = u end
        end
        if target.dead and not (sp.fx[1] and sp.fx[1].e == E_RESURRECT) then return fail("targetDead") end
    else
        target = target or u
    end
    if not trig then
        -- Charge: not in combat
        if id == 100 and u.inCombat then return fail("combat") end
        if id == 5019 and not u.ranged then return fail("weapon") end
        local cd = Combat.OnCooldown(u, sp, id)
        if cd then return fail("cd") end
        if (sp.gcd or 0) > 0 and u.gcdEnd and u.gcdEnd > Now() then return fail("gcd") end
        local cost, pt = Combat.Cost(sp, u)
        if cost > 0 then
            if pt == -2 then
                if u.hp <= cost then return fail("health") end
            elseif (u.power or 0) < cost then
                return fail(pt == Craft.POWER_RAGE and "rage" or (pt == Craft.POWER_ENERGY and "energy" or "mana"))
            end
        end
        if target ~= u then
            local ok, why = Combat.InRange(u, target, Combat.Range(sp, u), sp.minRange)
            if not ok then return fail(why) end
        end
        if (sp.cast or 0) > 0 and u.moving then return fail("moving") end
        if IsChannel(sp) and u.moving then return fail("moving") end
    end
    -- on the next swing (Heroic Strike): queue it; the rage goes when the swing lands
    if IsNextSwing(sp) and not trig and Combat.TargetKind(sp) == "enemy" and u.kind ~= "mob" then
        if u.nextSwing == id then u.nextSwing = nil return true end
        u.nextSwing = id
        u.target = target
        if not u.attacking then Combat.StartAttack(u, target) end
        Craft:Emit("queued", u, id)
        return true
    end
    if Combat.IsCreature(target) and target ~= u and kind == "enemy" then u.target = target end
    -- face the target
    if target ~= u and target.x then Combat.Face(u, target) end
    if opts.ai and target ~= u then
        local ok = Combat.InRange(u, target, sp.range or Craft.MELEE_RANGE, sp.minRange)
        if not ok then return false end
    end
    local castTime = opts.triggered and 0 or Combat.CastTime(sp, u)
    if not trig and (sp.gcd or 0) > 0 then
        u.gcdLen = sp.gcd / 1000
        u.gcdEnd = Now() + u.gcdLen
    end
    if castTime > 0 then
        u.casting = { spell = id, target = target, start = Now(), ends = Now() + castTime, opts = opts, push = 0 }
        Craft:Emit("cast", u, id, "start", target)
        if Combat.Net and u.kind == "player" then Combat.Net.Cast(u, id, target, castTime) end
        return true
    end
    if IsChannel(sp) and not trig then
        local dur = Combat.Duration(sp, u) or 1
        Combat.PayCost(u, sp)
        u.casting = { spell = id, target = target, start = Now(), ends = Now() + dur, channel = true, opts = opts,
                      push = 0 }
        -- a channel whose effects hit the enemy (Mind Flay: its damage and slow) puts its aura on the target; one
        -- that fires something every tick (Arcane Missiles) keeps it on the caster
        local trigger = false
        for _, e in ipairs(sp.fx or {}) do if e.a == A_PTRIGGER then trigger = true end end
        if not trigger and target and target ~= u and Combat.TargetKind(sp) == "enemy" then
            u.casting.tAura = Combat.ApplyAura(u, target, id, false)
        else
            Combat.ApplyAura(u, u, id, true)
        end
        StartCooldown(u, sp, id, opts)
        Craft:Emit("cast", u, id, "channel", target)
        if Combat.Net and u.kind == "player" then Combat.Net.Cast(u, id, target, dur, true) end
        return true
    end
    return Combat.FinishCast(u, id, target, opts)
end

function Combat.PayCost(u, sp)
    if Combat.IsCreature(u) then return end
    local cost, pt = Combat.Cost(sp, u)
    if cost <= 0 then return end
    if pt == -2 then
        u.hp = max(1, u.hp - cost)
    else
        Combat.GainPower(u, -cost)
        if pt == Craft.POWER_MANA then u.lastManaSpend = Now() end
    end
end

-- the cast is done: pay, cool down, and let it fly (or land)
function Combat.FinishCast(u, id, target, opts)
    local sp = D.spells[id]
    opts = opts or {}
    u.casting = nil
    if target and target.dead and Combat.TargetKind(sp) == "enemy" then return false end
    if not opts.triggered then
        if target and target ~= u then
            local ok, why = Combat.InRange(u, target, Combat.Range(sp, u))
            if not ok then
                if u.kind == "player" then Craft:Error(ERRORS[why]) end
                Craft:Emit("cast", u, id, "failed", target)
                return false
            end
        end
        Combat.PayCost(u, sp)
        StartCooldown(u, sp, id, opts)
        if opts.item then Craft.Items.Consume(opts) end
    end
    Craft:Emit("cast", u, id, "done", target)
    if Combat.Net and u.kind == "player" and not opts.triggered then Combat.Net.CastDone(u, id, target) end
    -- missiles fly at their speed (yards / second); everything else lands now
    if sp.speed and sp.speed > 0 and target and target ~= u then
        local d = Craft.UnitDist(u, target)
        local m = { spell = id, src = u, dst = target, from = { u.x, u.y }, start = Now(),
                    arrive = Now() + d / sp.speed, opts = opts }
        Combat.missiles[#Combat.missiles + 1] = m
        Craft:Emit("missile", m)
        return true
    end
    Combat.Apply(u, id, target, opts)
    return true
end

function Combat.Face(u, t)
    local dx, dy = t.x - u.x, t.y - u.y
    if abs(dx) > abs(dy) then u.face = dx > 0 and "right" or "left" else u.face = dy > 0 and "down" or "up" end
end

-- units around a point (enemies of caster within r yards)
function Combat.Around(caster, x, y, map, r, enemies)
    local out = {}
    for _, o in pairs(Combat.units) do
        if not o.dead and o.map == map and Craft.Dist(o.x, o.y, x, y) <= r then
            if enemies then
                if Combat.CanAttack(caster, o) and (o.kind ~= "critter") and
                   (o.hostile or o.inCombat or Combat.IsPlayer(o) or Combat.IsPlayer(caster) == false) then
                    out[#out + 1] = o
                end
            elseif Combat.Reaction(caster, o) == "friendly" and Combat.IsPlayer(o) then
                out[#out + 1] = o
            end
        end
    end
    return out
end

-- the effects of spell id from u on target
function Combat.Apply(u, id, target, opts)
    local sp = D.spells[id]
    if not sp then return end
    opts = opts or {}
    Craft:Emit("spellhit", u, id, target)
    local hostile = target and Combat.Reaction(u, target) == "hostile" and target ~= u
    -- who each effect hits
    local function targetsOf(e)
        local t1, t2 = e.t1 or 0, e.t2 or 0
        if t1 == 1 then return { u } end
        if t1 == 20 or t1 == 33 or t2 == 33 then          -- party around the caster
            local list = Combat.Around(u, u.x, u.y, u.map, Combat.SpellMod(u, sp, MOD_RADIUS, e.rad or 30), false)
            local seen = false
            for _, o in ipairs(list) do if o == u then seen = true end end
            if not seen then list[#list + 1] = u end
            return list
        end
        if t2 == 15 or t1 == 15 or t1 == 22 and t2 ~= 0 then
            return Combat.Around(u, u.x, u.y, u.map, Combat.SpellMod(u, sp, MOD_RADIUS, e.rad or 8), true)
        end
        return { target or u }
    end
    -- a spell that misses (enemy, magic or ranged): nothing of it lands
    if hostile and Combat.IsPlayer(u) and sp.defType ~= 2 and not opts.noMiss then
        if not Combat.SpellHit(u, target, sp) then
            Craft:Emit("damage", u, target, 0, { kind = "spell", school = sp.school, spell = id, result = "resist" })
            Combat.EnterCombat(target, u)
            if Combat.IsCreature(target) then Combat.AddThreat(target, u, 0) end
            return
        end
    end
    -- a physical special (Hamstring, Thunder Clap): the yellow melee roll
    local physRoll
    if hostile and sp.defType == 2 and Combat.IsPlayer(u) then
        physRoll = Combat.MeleeRoll(u, target, true)
        if physRoll == "miss" or physRoll == "dodge" or physRoll == "parry" then
            Craft:Emit("damage", u, target, 0, { kind = "melee", school = 1, spell = id, result = physRoll })
            Combat.EnterCombat(target, u)
            if Combat.IsCreature(target) then Combat.AddThreat(target, u, sp.threat and sp.threat[1] or 0) end
            return
        end
    end
    local auraIdx = {}
    local auraTargets = {}
    for _, e in ipairs(sp.fx or {}) do
        local list = targetsOf(e)
        if e.e == E_DAMAGE then
            for _, t in ipairs(list) do
                if Combat.CanAttack(u, t) or t == target and hostile then
                    local amt = Combat.SpellMod(u, sp, MOD_DAMAGE, Combat.EffectValue(sp, e, u) + (u.sp or 0) * (e.coef or 0))
                    local info = { kind = "spell", school = sp.school or 1, spell = id }
                    local crit = (sp.school == 1) and (physRoll == "crit") or Chance(Combat.SpellCritChance(u, sp))
                    if crit then amt = amt * (sp.school == 1 and 2 or 1.5) info.crit = true end
                    if sp.school == 1 then amt = Mitigate(u, t, amt, 1) end
                    if sp.threat then info.threat = sp.threat[1] end
                    if id == 6343 then info.threat = (info.threat or 0) + amt * 0.75 end   -- (Thunder Clap's extra)
                    Combat.Damage(u, t, amt, info)
                end
            end
        elseif e.e == E_HEAL then
            for _, t in ipairs(list) do
                local amt = Combat.SpellMod(u, sp, MOD_DAMAGE, Combat.EffectValue(sp, e, u) + (u.heal or u.sp or 0) * (e.coef or 0))
                local info = { kind = "spell", spell = id }
                if Chance(Combat.SpellCritChance(u, sp)) then amt = amt * 1.5 info.crit = true end
                Combat.Heal(u, t, amt, info)
            end
        elseif e.e == E_WEAPON or e.e == E_WEAPON_DMG or e.e == E_NORM_WEAPON or e.e == E_WEAPON_PCT then
            for _, t in ipairs(list) do
                if id == 5019 then                          -- Shoot: the wand's damage
                    local w = u.ranged
                    if w then
                        local amt = Combat.SpellMod(u, sp, MOD_DAMAGE, Roll(floor(w[1]), max(floor(w[1]), floor(w[2]))))
                        local info = { kind = "ranged", school = w[3] or 1, spell = id }
                        if Chance(Combat.SpellCritChance(u, sp)) then amt = amt * 1.5 info.crit = true end
                        Combat.Damage(u, t, amt, info)
                    end
                else
                    local amt = Combat.WeaponDamage(u, u.mh, e.e == E_NORM_WEAPON and 2.4 or nil)
                    if e.e == E_WEAPON_PCT then amt = amt * (Combat.EffectValue(sp, e, u) / 100)
                    else amt = amt + Combat.EffectValue(sp, e, u) end
                    local info = { kind = "melee", school = 1, spell = id, swing = u.mh and u.mh[4] or 2 }
                    if physRoll == "crit" then amt = amt * 2 info.crit = true end
                    if sp.threat then info.threat = sp.threat[1] end
                    Combat.Damage(u, t, Mitigate(u, t, amt, 1), info)
                end
            end
        elseif e.e == E_AURA then
            for _, t in ipairs(list) do
                auraTargets[t] = true
                auraIdx[e.i] = true
            end
        elseif e.e == E_ENERGIZE then
            for _, t in ipairs(list) do Combat.GainPower(t, Combat.EffectValue(sp, e, u), e.misc) end
        elseif e.e == E_DUMMY then
            if id == 100 or (sp.first == 100) then Combat.GainPower(u, Combat.EffectValue(sp, e, u)) end
        elseif e.e == E_TRIGGER and e.trig then
            local tt = (e.t1 == 1) and u or target
            if tt then Combat.CastSpell(u, e.trig, tt, { triggered = true, noMiss = true }) end
        elseif e.e == E_CHARGE then
            if target and Craft.World and Craft.World.Charge then Craft.World.Charge(u, target) end
        elseif e.e == E_ATTACK then
            Combat.StartAttack(u, target)
        elseif e.e == E_CREATE and e.item and u.kind == "player" then
            local n = (e.bp or 0) + max(1, e.die or 1)
            Craft.Items.Add(e.item, n, "create")
        elseif e.e == E_TELEPORT then
            if id == 8690 and u.kind == "player" and Craft.World then Craft.World.Hearth() end
        elseif e.e == E_RESURRECT then
            if target and target.dead and Combat.IsPlayer(target) and Craft.Party then
                Craft.Party.OfferResurrect(u, target, Combat.EffectValue(sp, e, u))
            end
        end
    end
    if hostile and not opts.triggered then
        local phys = sp.defType == 2
        Combat.Proc(u, phys and PROC_DEAL_MELEE_ABILITY or PROC_DEAL_HARMFUL_SPELL, target, id, { result = physRoll or "hit" })
        Combat.Proc(target, phys and PROC_TAKE_MELEE_ABILITY or PROC_TAKE_HARMFUL_SPELL, u, id, { result = physRoll or "hit" })
    end
    -- the spell's auras (all its aura effects in one aura per target)
    for t in pairs(auraTargets) do
        local helpful = Combat.Reaction(u, t) ~= "hostile"
        if t == u then helpful = true end
        local a = Combat.ApplyAura(u, t, id, helpful, auraIdx)
        if a and Combat.Net and u.kind == "player" and t ~= u then Combat.Net.Aura(u, t, id, a) end
        if hostile and t ~= u then
            Combat.EnterCombat(t, u)
            Combat.EnterCombat(u, t)
            if Combat.IsCreature(t) then Combat.AddThreat(t, u, sp.threat and sp.threat[1] or 0) end
        end
        if helpful and t ~= u and t.inCombat and Combat.IsPlayer(u) then
            -- buffing someone in a fight: a little threat on everything they fight
            for _, m in pairs(Combat.units) do
                if Combat.IsCreature(m) and m.threat[t.guid] then Combat.AddThreat(m, u, 10) end
            end
        end
    end
end

-- casts in progress lose time when hit (0.5 s, twice at most); channels lose duration
function Combat.Pushback(u)
    local c = u.casting
    if not c then return end
    if Combat.HasAura(u, A_ABSORB) and u.class == 5 then return end    -- (PW:Shield: no pushback)
    if (c.push or 0) >= 2 then return end
    local keep = Combat.SpellMod(u, D.spells[c.spell], MOD_PUSHBACK, 0)
    if keep > 0 and Chance(keep) then return end
    c.push = (c.push or 0) + 1
    if c.channel then
        c.ends = c.ends - (c.ends - c.start) * 0.25
    else
        c.ends = min(c.ends + 0.5, c.start + (c.ends - c.start) + 0.5)
    end
    Craft:Emit("cast", u, c.spell, "pushback")
end

function Combat.Interrupt(u, why)
    local c = u.casting
    if not c then return end
    u.casting = nil
    if c.channel then
        local a = Combat.FindAura(u, c.spell)
        if a then Combat.RemoveAura(u, a, "interrupt") end
        if c.tAura and c.target then Combat.RemoveAura(c.target, c.tAura, "interrupt") end
    end
    -- (a cast stopped before it finished: the GCD is given back, like WoW)
    if not c.channel and u.gcdEnd then u.gcdEnd = Now() end
    Craft:Emit("cast", u, c.spell, "interrupted", c.target)
    if Combat.Net and u.kind == "player" then Combat.Net.Cast(u, c.spell, c.target, 0) end
end

---------------------------------------------------------------------------
-- Auto attack
---------------------------------------------------------------------------

function Combat.StartAttack(u, target)
    target = target or u.target
    if not target or not Combat.CanAttack(u, target) then
        if u.kind == "player" then Craft:Error(ERRORS.enemy) end
        return false
    end
    u.target = target
    if not u.attacking then
        u.attacking = true
        u.swingAt = max(u.swingAt or 0, Now() + 0.1)
    end
    Combat.EnterCombat(u, target)
    if Combat.IsCreature(target) then Combat.AddThreat(target, u, 0) end
    Craft:Emit("attack", u, true)
    return true
end

function Combat.StopAttack(u)
    if u.attacking then
        u.attacking = false
        u.nextSwing = nil
        Craft:Emit("attack", u, false)
    end
end

---------------------------------------------------------------------------
-- The clock: casts, swings, auras, missiles, regeneration (every 2 s, WoW's tick), leaving combat
---------------------------------------------------------------------------

local regenAt = 0

local function Regen(u)
    if u.dead or u.ghost then return end
    if u.kind == "player" then
        local now = Now()
        if not u.inCombat and u.hp < u.hpMax then
            local per = max(1, floor(u.spi * 0.25 + u.level * 0.5))
            if u.sitting then per = per * 1.33 end
            u.hp = min(u.hpMax, u.hp + floor(per))
        end
        if u.powerType == Craft.POWER_MANA then
            local per = 12.5 + u.spi / 4
            if u.lastManaSpend and now - u.lastManaSpend < 5 then per = 0 end      -- (the five-second rule)
            u.power = min(u.powerMax, u.power + floor(per))
        elseif u.powerType == Craft.POWER_RAGE and not u.inCombat then
            u.power = max(0, u.power - 25)                -- (2.5 rage a tick out of combat)
        end
    elseif Combat.IsCreature(u) and not u.inCombat and u.hp < u.hpMax then
        u.hp = min(u.hpMax, u.hp + max(1, floor(u.hpMax / 3)))
    end
end

function Combat.Update(dt)
    local now = Now()
    -- missiles land
    local ms = Combat.missiles
    for i = #ms, 1, -1 do
        local m = ms[i]
        local d = m.dst
        -- (it chases a moving target: arrival time stretches to the new distance)
        if d and not d.dead then
            local sp = D.spells[m.spell]
            local left = Craft.UnitDist(m.src, d)
            local traveled = (now - m.start) * (sp.speed or 20)
            if traveled >= left or now >= m.arrive + 1.5 then
                table.remove(ms, i)
                Combat.Apply(m.src, m.spell, d, m.opts)
                Craft:Emit("impact", m)
            end
        else
            table.remove(ms, i)
        end
    end
    local tick = now >= regenAt
    if tick then regenAt = now + 2 end
    for _, u in pairs(Combat.units) do
        if not u.dead then
            -- casts
            local c = u.casting
            if c and c.opening then
                if now >= c.ends and Craft.Quests then Craft.Quests.FinishOpening(u) end
            elseif c then
                if c.target and c.target.dead and Combat.TargetKind(D.spells[c.spell]) == "enemy" then
                    Combat.Interrupt(u, "dead")
                elseif now >= c.ends then
                    if c.channel then
                        u.casting = nil
                        local a = Combat.FindAura(u, c.spell)
                        if a then Combat.RemoveAura(u, a, "expired") end
                        if c.tAura and c.target then Combat.RemoveAura(c.target, c.tAura, "expired") end
                        Craft:Emit("cast", u, c.spell, "done", c.target)
                    else
                        Combat.FinishCast(u, c.spell, c.target, c.opts)
                    end
                end
            end
            -- auto attack (melee): in reach, not casting, not controlled
            if u.attacking and u.target and not u.casting and not u.stunned and not u.cc then
                local t = u.target
                if t.dead or not Combat.CanAttack(u, t) then
                    Combat.StopAttack(u)
                elseif u.autoShot then
                    -- (wands: Shoot repeats while it is on)
                elseif now >= (u.swingAt or 0) then
                    local d = Craft.UnitDist(u, t)
                    if d <= Craft.MELEE_RANGE + 0.5 then
                        Combat.Face(u, t)
                        Combat.Swing(u, t)
                        u.swingAt = now + (u.mh and u.mh[4] or 2) / (u.hasteMult or 1)
                    elseif u.kind == "player" and d > Craft.MELEE_RANGE + 0.5 and (u.tooFarAt or 0) < now then
                        u.tooFarAt = now + 3
                        if d < 40 then Craft:Error("You are too far away!") end
                    end
                end
            end
            -- auras: ticks and expiry
            for i = #u.auras, 1, -1 do
                local a = u.auras[i]
                if a then
                    for _, x in ipairs(a.fx) do
                        if x.next and now >= x.next then
                            x.next = x.next + (x.per or 1)
                            TickAura(u, a, x, now)
                            if u.dead then break end
                        end
                    end
                    if u.dead then break end
                    if a.expires and now >= a.expires then
                        -- (the last tick of a dot that ends on its period)
                        for _, x in ipairs(a.fx) do
                            if x.next and x.next <= a.expires + 0.05 and x.a ~= A_PTRIGGER then TickAura(u, a, x, now) end
                        end
                        Combat.RemoveAura(u, a, "expired")
                    end
                end
            end
            if tick then Regen(u) end
            -- leaving combat: a player when nothing fights them any more; a creature when its list is empty
            if u.inCombat then
                if u.kind == "player" or u.kind == "remote" then
                    local fought = false
                    for _, m in pairs(Combat.units) do
                        if Combat.IsCreature(m) and not m.dead and m.threat[u.guid] then fought = true break end
                    end
                    if not fought and now >= (u.combatUntil or 0) then
                        u.inCombat = false
                        if u.kind == "player" then Craft:Emit("combat", false) end
                    end
                elseif not next(u.threat) and now >= (u.combatUntil or 0) then
                    u.inCombat = false
                    u.engaged = nil
                end
            end
        end
    end
end

-- a spell's icon as the client shows it: Attack wears your main-hand weapon (a fist when you have none) instead of
-- its own placeholder art; Shoot wears the wand
function Combat.SpellIcon(id, c)
    local sp = D.spells[id]
    c = c or Craft.char
    if id == 6603 then
        local w = c and c.equip and c.equip[16]
        return w and Craft.Items.Icon(w) or "Interface\\Icons\\INV_Gauntlets_04"
    elseif id == 5019 then
        local w = c and c.equip and c.equip[18]
        if w then return Craft.Items.Icon(w) end
    end
    return sp and sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

---------------------------------------------------------------------------
-- Tooltip text for a spell (WoW's $s1 / $o1 / $d / $t1 placeholders)
---------------------------------------------------------------------------

function Combat.SpellText(id, u, aura)
    local sp = D.spells[id]
    if not sp then return "" end
    local text = (aura and sp.auraDesc) or sp.desc or ""
    local function fx(i, spell)
        local s = spell or sp
        for _, e in ipairs(s.fx or {}) do if e.i == i - 1 then return e, s end end
    end
    local function val(i, spell, mode)
        local e, s = fx(i, spell)
        if not e then return "0" end
        local lo, hi = Combat.EffectRange(s, e, u)
        lo, hi = abs(lo), abs(hi)
        if mode == "o" then
            local dur = Combat.Duration(s, u) or 0
            local per = (e.per or 3000) / 1000
            local ticks = (per > 0 and dur > 0) and floor(dur / per + 0.5) or 1
            if e.a == A_REGEN or e.a == A_POWER_REGEN then ticks = dur / 5 end
            return tostring(floor(lo * ticks + 0.5))
        end
        if mode == "t" then return tostring((e.per or 0) / 1000) end
        if lo ~= hi then return lo .. " to " .. hi end
        return tostring(lo)
    end
    text = text:gsub("%$(%d*)([soOtTmMdDaAzZ])(%d?)", function(ref, kind, idx)
        local spell = ref ~= "" and D.spells[tonumber(ref)] or nil
        kind = kind:lower()
        local i = tonumber(idx) or 1
        if kind == "s" or kind == "m" then return val(i, spell) end
        if kind == "o" then return val(i, spell, "o") end
        if kind == "t" then return val(i, spell, "t") end
        if kind == "d" then
            local d = Combat.Duration(spell or sp, u)
            if not d or d < 0 then return "until cancelled" end
            if d >= 60 then return floor(d / 60 + 0.5) .. " min" end
            return d .. " sec"
        end
        if kind == "a" then local e = fx(i, spell) return tostring(e and e.rad or 0) end
        if kind == "z" then return (Craft.char and Craft.char.bind and Craft.char.bind.name) or "Northshire Abbey" end
        return ""
    end)
    text = text:gsub("%${([^}]*)}", function(expr) return expr:match("^[%d%.]+$") and expr or "" end)
    text = text:gsub("%$/(%d+);(%d*)([sSoO])(%d?)", function(div, ref, kind, idx)
        local spell = ref ~= "" and D.spells[tonumber(ref)] or nil
        local v = tonumber((val(tonumber(idx) or 1, spell, kind:lower() == "o" and "o" or nil)):match("%d+")) or 0
        return tostring(floor(v / tonumber(div) + 0.5))
    end)
    text = text:gsub("%$l([^:]*):([^;]*);", "%2"):gsub("%$g([^:]*):([^;]*);", "%1"):gsub("%$[%a]", "")
    return text
end
