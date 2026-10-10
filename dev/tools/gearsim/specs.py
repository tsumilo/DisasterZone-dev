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
        "misery": True, "curseOfElements": IMP, "improvedSealOfTheCrusader": IMP, "jocRetribution2Pt4": True,
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
}
