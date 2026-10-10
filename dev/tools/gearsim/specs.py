"""The specs the gear sim covers, as the dev tools see them: WoWSims' player options, rotation and preset buffs
(ui/specs/*/presets.ts, P1 settings), and the matching names on the Lua side (Sim/*.lua, Sim/Buffs.lua presets).

wowsims_ref.py builds its request from these; run_lua.py hands the Lua sim the same scenario.
"""
IMP, REG, MISSING = "TristateEffectImproved", "TristateEffectRegular", "TristateEffectMissing"

# ui/specs/paladin/retribution/presets.ts
RET_BUFFS = {
    "raid": {
        "bloodlust": True, "divineSpirit": IMP, "arcaneBrilliance": True, "giftOfTheWild": IMP,
        "powerWordFortitude": IMP, "shadowProtection": True, "thorns": IMP,
    },
    "party": {
        "manaSpringTotem": REG, "leaderOfThePack": IMP, "battleShout": IMP, "strengthOfEarthTotem": IMP,
        "totemTwisting": True, "windfuryTotem": IMP, "graceOfAirTotem": IMP, "drums": "LesserDrumsOfBattle",
        "sanctityAura": MISSING,
    },
    "individual": {"blessingOfKings": True, "blessingOfWisdom": IMP, "blessingOfMight": IMP, "unleashedRage": True},
    "debuffs": {
        "misery": True, "curseOfElements": IMP, "improvedSealOfTheCrusader": IMP, "jocRetribution2pt4": True,
        "judgementOfWisdom": True, "bloodFrenzy": True, "huntersMark": IMP, "curseOfRecklessness": True,
        "sunderArmor": True, "faerieFire": IMP, "exposeArmor": IMP, "exposeWeaknessUptime": 0.9,
        "exposeWeaknessHunterAgility": 1080,
    },
    "consumables": {
        "potId": 22838, "flaskId": 22854, "foodId": 27658, "conjuredId": 12662, "superSapper": True,
        "goblinSapper": True, "scrollAgi": True, "scrollStr": True, "explosiveId": 30217,
    },
}

# ui/specs/warrior/shared/presets.ts + dps/presets.ts (P1 player settings)
WARRIOR_BUFFS = {
    "raid": {"bloodlust": True, "powerWordFortitude": IMP, "giftOfTheWild": IMP},
    "party": {
        "ferociousInspiration": 2, "braidedEterniumChain": True, "graceOfAirTotem": IMP, "strengthOfEarthTotem": IMP,
        "windfuryTotem": IMP, "leaderOfThePack": REG, "totemTwisting": True, "drums": "LesserDrumsOfBattle",
    },
    "individual": {"blessingOfKings": True, "blessingOfMight": IMP, "unleashedRage": True},
    "debuffs": {
        "exposeWeaknessUptime": 0.9, "exposeWeaknessHunterAgility": 1080, "improvedSealOfTheCrusader": IMP,
        "misery": True, "bloodFrenzy": True, "giftOfArthas": True, "mangle": True, "exposeArmor": IMP,
        "faerieFire": IMP, "sunderArmor": True, "curseOfRecklessness": True, "huntersMark": IMP,
    },
    "consumables": {
        "potId": 22838, "flaskId": 22854, "foodId": 27658, "conjuredId": 22788, "explosiveId": 30217,
        "superSapper": True, "goblinSapper": True, "ohImbueId": 29453, "scrollAgi": True, "scrollStr": True,
    },
}
WARRIOR_OPTIONS = {"options": {"classOptions": {
    "queueDelay": 250, "startingRage": 50, "defaultShout": "WarriorShoutBattle",
    "defaultStance": "WarriorStanceBerserker", "hasBsT2": True, "stanceSnapshot": True}}}
WARRIOR_LUA_OPTIONS = {"queueDelay": 0.25, "startingRage": 50, "defaultShout": "Battle", "defaultStance": "Berserker",
                       "hasBsT2": True, "stanceSnapshot": True}

# ui/specs/shaman/enhancement/presets.ts (P1 settings): the shaman drops his own totems and casts his own drums
ENH_BUFFS = {
    "raid": {"bloodlust": True, "powerWordFortitude": IMP, "giftOfTheWild": IMP, "arcaneBrilliance": True},
    "party": {"ferociousInspiration": 2, "braidedEterniumChain": True, "leaderOfThePack": REG, "battleShout": IMP},
    "individual": {"blessingOfKings": True, "blessingOfMight": IMP},
    "debuffs": {
        "exposeWeaknessUptime": 0.9, "exposeWeaknessHunterAgility": 1080, "improvedSealOfTheCrusader": IMP,
        "judgementOfWisdom": True, "screech": True, "misery": True, "bloodFrenzy": True, "giftOfArthas": True,
        "mangle": True, "exposeArmor": IMP, "faerieFire": IMP, "sunderArmor": True, "curseOfElements": IMP,
        "curseOfRecklessness": True, "huntersMark": IMP,
    },
    "consumables": {
        "potId": 22838, "flaskId": 22854, "foodId": 27658, "drumsId": "LesserDrumsOfBattle", "conjuredId": 22788,
        "explosiveId": 30217, "superSapper": True, "goblinSapper": True, "scrollAgi": True, "scrollStr": True,
    },
}
ENH_OPTIONS = {"options": {"classOptions": {"shieldProcrate": 0, "imbueMh": "WindfuryWeapon"},
                           "imbueOh": "WindfuryWeapon", "syncType": "DelayOffhandSwings"}}
ENH_LUA_OPTIONS = {"shieldProcrate": 0, "imbueMh": "WindfuryWeapon", "imbueOh": "WindfuryWeapon",
                   "syncType": "DelayOffhandSwings"}

# ui/specs/rogue/dps/spec.ts defaults + presets.ts DefaultConsumables (P1)
ROGUE_BUFFS = {
    "raid": {"bloodlust": True, "giftOfTheWild": IMP},
    "party": {"battleShout": IMP, "ferociousInspiration": 1, "strengthOfEarthTotem": IMP, "graceOfAirTotem": IMP,
              "windfuryTotem": IMP, "leaderOfThePack": REG, "totemTwisting": True, "drums": "LesserDrumsOfBattle"},
    "individual": {"blessingOfKings": True, "blessingOfMight": IMP, "unleashedRage": True},
    "debuffs": {
        "exposeWeaknessUptime": 0.9, "exposeWeaknessHunterAgility": 1080, "bloodFrenzy": True, "huntersMark": IMP,
        "improvedSealOfTheCrusader": IMP, "mangle": True, "misery": True, "curseOfRecklessness": True,
        "faerieFire": IMP, "giftOfArthas": True, "sunderArmor": True,
    },
    "consumables": {"battleElixirId": 22831, "guardianElixirId": 32062, "foodId": 33872, "potId": 22838,
                    "conjuredId": 7676, "ohImbueId": 27186},
}

# ui/specs/druid/feralcat/spec.ts defaults + presets.ts DefaultConsumables
CAT_BUFFS = {
    "raid": {"bloodlust": True, "arcaneBrilliance": True, "divineSpirit": IMP, "giftOfTheWild": IMP,
             "powerWordFortitude": IMP, "shadowProtection": True},
    "party": {"drums": "LesserDrumsOfBattle", "ferociousInspiration": 2, "battleShout": IMP, "graceOfAirTotem": IMP,
              "windfuryTotem": IMP, "manaSpringTotem": REG, "strengthOfEarthTotem": IMP, "totemTwisting": True},
    "individual": {"blessingOfKings": True, "blessingOfMight": IMP, "unleashedRage": True},
    "debuffs": {
        "exposeWeaknessUptime": 0.9, "exposeWeaknessHunterAgility": 1080, "bloodFrenzy": True, "exposeArmor": IMP,
        "huntersMark": IMP, "improvedSealOfTheCrusader": IMP, "judgementOfWisdom": True, "misery": True,
        "curseOfRecklessness": True, "faerieFire": IMP, "sunderArmor": True, "giftOfArthas": True,
    },
    "consumables": {"potId": 22838, "battleElixirId": 22831, "guardianElixirId": 32067, "foodId": 27664,
                    "mhImbueId": 34340, "conjuredId": 12662, "superSapper": True, "goblinSapper": True,
                    "scrollAgi": True, "scrollStr": True},
}

# ui/specs/shaman/elemental/presets.ts (P1 settings)
ELE_BUFFS = {
    "raid": {"bloodlust": True, "arcaneBrilliance": True, "giftOfTheWild": IMP, "powerWordFortitude": IMP,
             "divineSpirit": IMP},
    "party": {"moonkinAura": IMP, "chainOfTheTwilightOwl": True, "eyeOfTheNight": True},
    "individual": {"blessingOfKings": True, "blessingOfWisdom": IMP, "shadowPriestDps": 800},
    "debuffs": {
        "bloodFrenzy": True, "curseOfElements": IMP, "curseOfRecklessness": True, "exposeArmor": IMP,
        "faerieFire": IMP, "giftOfArthas": True, "huntersMark": IMP, "improvedSealOfTheCrusader": IMP,
        "judgementOfWisdom": True, "mangle": True, "misery": True, "sunderArmor": True,
    },
    "consumables": {"conjuredId": 12662, "drumsId": "LesserDrumsOfBattle", "flaskId": 22861, "foodId": 27657,
                    "mhImbueId": 25122, "potId": 22839},
}

# ui/specs/priest/dps/presets.ts (phase 3 ISB uptime)
SPRIEST_BUFFS = {
    "raid": {"bloodlust": True, "arcaneBrilliance": True, "giftOfTheWild": IMP, "powerWordFortitude": IMP,
             "divineSpirit": IMP},
    "party": {"manaSpringTotem": "TristateEffectRegular", "wrathOfAirTotem": IMP, "eyeOfTheNight": True,
              "chainOfTheTwilightOwl": True},
    "individual": {"blessingOfKings": True, "blessingOfWisdom": IMP, "shadowPriestDps": 0},
    "debuffs": {"improvedSealOfTheCrusader": IMP, "judgementOfWisdom": True, "faerieFire": IMP, "shadowEmbrace": True,
                "curseOfElements": IMP, "exposeArmor": IMP, "isbUptime": 0.72},
    "consumables": {"flaskId": 22866, "foodId": 27657, "conjuredId": 12662, "mhImbueId": 22522, "potId": 22839,
                    "explosiveId": 30217, "drumsId": "LesserDrumsOfBattle"},
}

# ui/specs/druid/balance/presets.ts
BALANCE_BUFFS = {
    "raid": {"bloodlust": True, "arcaneBrilliance": True, "giftOfTheWild": IMP, "powerWordFortitude": IMP,
             "divineSpirit": IMP},
    "party": {"chainOfTheTwilightOwl": True, "draeneiRacialCaster": True, "eyeOfTheNight": True, "totemOfWrath": 1,
              "wrathOfAirTotem": IMP},
    "individual": {"blessingOfKings": True, "blessingOfWisdom": IMP, "shadowPriestDps": 800},
    "debuffs": {"bloodFrenzy": True, "curseOfElements": IMP, "curseOfRecklessness": True, "exposeArmor": IMP,
                "giftOfArthas": True, "huntersMark": IMP, "improvedSealOfTheCrusader": IMP, "judgementOfWisdom": True,
                "mangle": True, "misery": True, "sunderArmor": True},
    "consumables": {"conjuredId": 12662, "flaskId": 22861, "foodId": 27657, "mhImbueId": 25122, "potId": 22832,
                    "drumsId": "LesserDrumsOfBattle"},
}

# ui/specs/mage/dps/presets.ts (phase 3 ISB uptime)
MAGE_BUFFS = {
    "raid": {"bloodlust": True, "divineSpirit": IMP, "arcaneBrilliance": True, "giftOfTheWild": IMP,
             "powerWordFortitude": IMP, "shadowProtection": True},
    "party": {"manaSpringTotem": IMP, "manaTideTotems": 1, "wrathOfAirTotem": "TristateEffectRegular"},
    "individual": {"blessingOfKings": True, "blessingOfWisdom": IMP, "innervates": 1, "blessingOfSalvation": True,
                   "shadowPriestDps": 1400},
    "debuffs": {"misery": True, "curseOfElements": IMP, "improvedSealOfTheCrusader": IMP, "judgementOfWisdom": True,
                "isbUptime": 0.72},
    "consumables": {"guardianElixirId": 32067, "battleElixirId": 28103, "foodId": 27657, "mhImbueId": 25122,
                    "potId": 22832, "drumsId": "LesserDrumsOfBattle"},
}

# ui/specs/warlock/dps/presets.ts (P1 settings, phase 3 ISB / Expose Weakness); the fire build swaps in Flame Cap
# and Improved Scorch
WARLOCK_BUFFS = {
    "raid": {"bloodlust": True, "arcaneBrilliance": True, "giftOfTheWild": IMP, "powerWordFortitude": IMP,
             "divineSpirit": IMP},
    "party": {"manaSpringTotem": REG, "moonkinAura": REG, "totemOfWrath": 1, "wrathOfAirTotem": IMP,
              "eyeOfTheNight": True, "chainOfTheTwilightOwl": True, "drums": "LesserDrumsOfBattle"},
    "individual": {"blessingOfKings": True, "blessingOfWisdom": IMP, "shadowPriestDps": 0},
    "debuffs": {
        "exposeWeaknessUptime": 0.9, "exposeWeaknessHunterAgility": 1210, "isbUptime": 0.72,
        "improvedSealOfTheCrusader": IMP, "judgementOfWisdom": True, "misery": True, "shadowWeaving": True,
        "sunderArmor": True, "screech": True, "faerieFire": IMP, "curseOfRecklessness": True, "shadowEmbrace": True,
        "curseOfElements": IMP, "bloodFrenzy": True, "giftOfArthas": True, "mangle": True, "exposeArmor": IMP,
        "huntersMark": IMP,
    },
    "consumables": {"flaskId": 22866, "foodId": 27657, "conjuredId": 12662, "mhImbueId": 25122, "potId": 22839,
                    "explosiveId": 30217, "petScrollAgi": True, "petScrollStr": True},
}
WARLOCK_FIRE_BUFFS = dict(WARLOCK_BUFFS, debuffs=dict(WARLOCK_BUFFS["debuffs"], improvedScorch=True),
                          consumables=dict(WARLOCK_BUFFS["consumables"], conjuredId=22788))


def _warlock(apl, summon, sacrifice, curse, buffs, lua_buffs):
    return {"class": "Warlock", "wsClass": "ClassWarlock", "field": "warlock",
            "options": {"options": {"classOptions": {"armor": "FelArmor", "curseOptions": curse, "summon": summon,
                                                     "sacrificeSummon": sacrifice}}},
            "apl": "ui/specs/warlock/dps/apls/%s.apl.json" % apl, "buffs": buffs, "luaBuffs": lua_buffs,
            "luaOptions": {"armor": "FelArmor", "curse": curse, "summon": summon, "sacrificeSummon": sacrifice}}


# ui/specs/hunter/dps/builds/phase_N/*.build.json (all phases share the buffs; ammo varies, set per scenario)
HUNTER_BUFFS = {
    "raid": {"arcaneBrilliance": True, "powerWordFortitude": IMP, "shadowProtection": True, "divineSpirit": IMP,
             "giftOfTheWild": IMP, "bloodlust": True},
    "party": {"ferociousInspiration": 1, "leaderOfThePack": IMP, "braidedEterniumChain": True, "graceOfAirTotem": IMP,
              "strengthOfEarthTotem": IMP, "windfuryTotem": IMP, "totemTwisting": True, "battleShout": IMP,
              "drums": "LesserDrumsOfBattle"},
    "individual": {"blessingOfKings": True, "blessingOfWisdom": IMP, "blessingOfMight": IMP, "unleashedRage": True},
    "debuffs": {"judgementOfWisdom": True, "judgementOfLight": True, "improvedSealOfTheCrusader": IMP, "misery": True,
                "bloodFrenzy": True, "giftOfArthas": True, "mangle": True, "exposeArmor": IMP, "faerieFire": IMP,
                "sunderArmor": True, "curseOfRecklessness": True, "huntersMark": IMP, "exposeWeaknessUptime": 0.9,
                "exposeWeaknessHunterAgility": 1080, "insectSwarm": True},
    "consumables": {"potId": 22838, "battleElixirId": 22831, "guardianElixirId": 22840, "foodId": 27659,
                    "conjuredId": 12662, "explosiveId": 30217, "superSapper": True, "goblinSapper": True,
                    "scrollAgi": True, "scrollStr": True, "petScrollAgi": True, "petScrollStr": True,
                    "petFoodId": 33874},
}
HUNTER_OPTIONS = {"quiverBonus": "Speed15", "ammo": "WardensArrow", "petType": "Ravager", "petUptime": 1}

SPECS = {
    "ret": {"class": "Paladin", "wsClass": "ClassPaladin", "field": "retributionPaladin",
            "options": {"options": {"classOptions": {}}}, "apl": "ui/specs/paladin/retribution/apls/default.apl.json",
            "buffs": RET_BUFFS, "luaBuffs": "wowsims_ret"},
    "fury": {"class": "Warrior", "wsClass": "ClassWarrior", "field": "dpsWarrior", "options": WARRIOR_OPTIONS,
             "apl": "ui/specs/warrior/dps/apls/fury.apl.json", "buffs": WARRIOR_BUFFS, "luaBuffs": "wowsims_warrior",
             "luaOptions": WARRIOR_LUA_OPTIONS},
    "arms": {"class": "Warrior", "wsClass": "ClassWarrior", "field": "dpsWarrior", "options": WARRIOR_OPTIONS,
             "apl": "ui/specs/warrior/dps/apls/arms.apl.json", "buffs": WARRIOR_BUFFS, "luaBuffs": "wowsims_warrior",
             "luaOptions": WARRIOR_LUA_OPTIONS},
    "enh": {"class": "Shaman", "wsClass": "ClassShaman", "field": "enhancementShaman", "options": ENH_OPTIONS,
            "apl": "ui/specs/shaman/enhancement/apls/default.apl.json", "buffs": ENH_BUFFS, "luaBuffs": "wowsims_enh",
            "luaOptions": ENH_LUA_OPTIONS},
    "rogue": {"class": "Rogue", "wsClass": "ClassRogue", "field": "rogue", "options": {"options": {"classOptions": {}}},
              "apl": "ui/specs/rogue/dps/apls/swords.apl.json", "buffs": ROGUE_BUFFS, "luaBuffs": "wowsims_rogue"},
    "cat": {"class": "Druid", "wsClass": "ClassDruid", "field": "feralCatDruid",
            "options": {"options": {"classOptions": {}}}, "apl": "ui/specs/druid/feralcat/apls/default.apl.json",
            "buffs": CAT_BUFFS, "luaBuffs": "wowsims_cat", "luaOptions": {"form": "Cat"}},
    "arcane": {"class": "Mage", "wsClass": "ClassMage", "field": "mage",
               "options": {"options": {"classOptions": {"defaultMageArmor": "MageArmorMageArmor"}}},
               "apl": "ui/specs/mage/dps/apls/arcane.apl.json", "buffs": MAGE_BUFFS, "luaBuffs": "wowsims_mage",
               "luaOptions": {"defaultMageArmor": "MageArmor"}},
    # WoWSims ships no Fire / Frost list: our own (dev/data/apl), simmed by both sims alike
    "fire": {"class": "Mage", "wsClass": "ClassMage", "field": "mage",
             "options": {"options": {"classOptions": {"defaultMageArmor": "MageArmorMoltenArmor"}}},
             "apl": "C:/Users/emilo/CDLoot-dev/dev/data/apl/mage_fire.apl.json", "buffs": MAGE_BUFFS, "luaBuffs": "wowsims_mage",
             "luaOptions": {"defaultMageArmor": "MoltenArmor"}},
    "frost": {"class": "Mage", "wsClass": "ClassMage", "field": "mage",
              "options": {"options": {"classOptions": {"defaultMageArmor": "MageArmorMoltenArmor"}}},
              "apl": "C:/Users/emilo/CDLoot-dev/dev/data/apl/mage_frost.apl.json", "buffs": MAGE_BUFFS, "luaBuffs": "wowsims_mage",
              "luaOptions": {"defaultMageArmor": "MoltenArmor"}},
    "affliction": _warlock("affliction", "Imp", False, "Elements", WARLOCK_BUFFS, "wowsims_warlock"),
    "demonology": _warlock("demonology", "Succubus", False, "Recklessness", WARLOCK_BUFFS, "wowsims_warlock"),
    "destruction": _warlock("destruction", "Succubus", True, "Recklessness", WARLOCK_BUFFS, "wowsims_warlock"),
    "destrofire": _warlock("destro_fire", "Imp", True, "Recklessness", WARLOCK_FIRE_BUFFS, "wowsims_warlock_fire"),
    # WoWSims' list with its "Melee weave" switch off (scenarios set aplVariables): the sim doesn't move
    "hunter": {"class": "Hunter", "wsClass": "ClassHunter", "field": "hunter",
               "options": {"options": {"classOptions": HUNTER_OPTIONS}},
               "apl": "ui/specs/hunter/dps/apls/default.apl.json", "buffs": HUNTER_BUFFS, "luaBuffs": "wowsims_hunter",
               "luaOptions": HUNTER_OPTIONS},
    "balance": {"class": "Druid", "wsClass": "ClassDruid", "field": "balanceDruid",
                "options": {"options": {"classOptions": {}}},
                "apl": "ui/specs/druid/balance/apls/default.apl.json", "buffs": BALANCE_BUFFS, "luaBuffs": "wowsims_balance",
                "luaOptions": {"form": "Moonkin"}},
    "spriest": {"class": "Priest", "wsClass": "ClassPriest", "field": "dpsPriest",
                "options": {"options": {"classOptions": {"preShadowform": True}}},
                "apl": "ui/specs/priest/dps/apls/default.apl.json", "buffs": SPRIEST_BUFFS, "luaBuffs": "wowsims_spriest",
                "luaOptions": {"preShadowform": True}},
    "ele": {"class": "Shaman", "wsClass": "ClassShaman", "field": "elementalShaman",
            "options": {"options": {"classOptions": {"shieldProcrate": 0}}},
            "apl": "ui/specs/shaman/elemental/apls/default.apl.json", "buffs": ELE_BUFFS, "luaBuffs": "wowsims_ele",
            "luaOptions": {"elemental": True, "imbueMh": "NoImbue", "imbueOh": "NoImbue", "shieldProcrate": 0}},
}
