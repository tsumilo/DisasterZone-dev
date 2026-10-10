if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Portal/Kit.lua", ...) then return end -- DisasterZone Games/Portal/Kit.lua
-- What every Portal place shares (2026-10-10): your abilities (the same on the hub's practice dummy as in a dungeon),
-- one-shot animations, and the client's animation and spell-effect ids.
--   ns.PortalKit.Abilities(hit) -> the ability list; hit(sim, attacker, unit, amount) lands a blow (each place
--     decides what a hit does: a dungeon adds threat, the hub's dummy counts damage)
--   Anim(sim, u, anim, dur), Busy(sim, u): a one-shot animation (Games/Portal/UI.lua plays it over walking and
--     standing; a new one restarts it) and whether one still plays
-- Animations (the client's AnimationData ids): Attack1H 17, Attack2H 18, CombatWound 9, SpellCastOmni 54; effects
-- (spell model files): bloodyexplosion 165737, cleave_impact_chest 165798, heal_low_base 166292,
-- holy_precast_low_hand 166336.
local addonName, ns = ...

local min = math.min

local K = {}
ns.PortalKit = K

K.MELEE = 4.5
K.ANIM_1H, K.ANIM_2H, K.ANIM_WOUND, K.ANIM_CAST = 17, 18, 9, 54
K.FX_BLOOD, K.FX_CLEAVE, K.FX_HEAL, K.FX_PRECAST = 165737, 165798, 166292, 166336

function K.Anim(sim, u, anim, dur) u.oneShot = { anim = anim, untilT = sim.time + dur } end
function K.Busy(sim, u) return u.oneShot and sim.time < u.oneShot.untilT end

local function SpellIcon(id, fallback) return (GetSpellTexture and GetSpellTexture(id)) or ("Interface\\Icons\\" .. fallback) end
K.SpellIcon = SpellIcon

function K.Abilities(hit)
    return {
        { id = "strike", key = "1", name = "Heroic Strike", icon = SpellIcon(29707, "Ability_Rogue_Ambush"), gcd = 1.5,
          range = K.MELEE + 1, needsTarget = true,
          tip = "A heavy blow to your target.",
          use = function(sim, ab, target)
              K.Anim(sim, sim.player, K.ANIM_2H, 0.9)
              hit(sim, sim.player, target, sim:Random(650, 800))
              sim:Fx({ kind = "model", fdid = K.FX_BLOOD, unit = target, attach = "chest" }, 0.8)
          end },
        { id = "cleave", key = "2", name = "Cleave", icon = SpellIcon(25231, "Ability_Warrior_Cleave"), gcd = 1.5,
          cooldown = 6, tip = "Hits every enemy within 8 yd in front of you.",
          use = function(sim)
              local p = sim.player
              K.Anim(sim, p, K.ANIM_2H, 0.9)
              for _, u in ipairs(sim:UnitsInRange(p.x, p.y, 8, "mob")) do
                  hit(sim, p, u, sim:Random(380, 460))
                  sim:Fx({ kind = "model", fdid = K.FX_CLEAVE, unit = u, attach = "chest" }, 0.8)
              end
          end },
        { id = "heal", key = "3", name = "Bandage", icon = SpellIcon(27031, "INV_Misc_Bandage_12"), cooldown = 20,
          tip = "Heals you for 30% of your health.",
          use = function(sim)
              local p = sim.player
              p.hp = min(p.hpMax, p.hp + math.floor(p.hpMax * 0.3))
              sim:Fx({ kind = "model", fdid = K.FX_HEAL, unit = p }, 1.2)
          end },
    }
end
