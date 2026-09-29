-- CDLoot: Core/RaidComp.lua
-- Raid composition data (Addendum J §59): spec icons, the TBC buffs / debuffs a class and spec brings (party-wide
-- ones matter for the group layout, raid-wide ones for the whole team or raid), roles, and the Auto-fill layout.
-- Pure data + functions; no UI and no network.
local addonName, ns = ...

local RaidComp = ns:NewModule("RaidComp")

local ipairs, pairs, type = ipairs, pairs, type
local tsort = table.sort

local I = "Interface\\Icons\\"

-- Spec icons, by class and spec label (ns.SPECS).
local SPEC_ICONS = {
    WARRIOR = { Arms = "Ability_Warrior_SavageBlow", Fury = "Ability_Warrior_InnerRage",
                Protection = "Ability_Warrior_DefensiveStance" },
    PALADIN = { Holy = "Spell_Holy_HolyBolt", Protection = "Spell_Holy_DevotionAura",
                Retribution = "Spell_Holy_AuraOfLight" },
    HUNTER = { ["Beast Mastery"] = "Ability_Hunter_BeastTaming", Marksmanship = "Ability_Marksmanship",
               Survival = "Ability_Hunter_SwiftStrike" },
    ROGUE = { Assassination = "Ability_Rogue_Eviscerate", Combat = "Ability_BackStab", Subtlety = "Ability_Stealth" },
    PRIEST = { Discipline = "Spell_Holy_WordFortitude", Holy = "Spell_Holy_HolyBolt",
               Shadow = "Spell_Shadow_ShadowWordPain" },
    SHAMAN = { Elemental = "Spell_Nature_Lightning", Enhancement = "Spell_Nature_LightningShield",
               Restoration = "Spell_Nature_MagicImmunity" },
    MAGE = { Arcane = "Spell_Holy_MagicalSentry", Fire = "Spell_Fire_FireBolt02", Frost = "Spell_Frost_FrostBolt02" },
    WARLOCK = { Affliction = "Spell_Shadow_DeathCoil", Demonology = "Spell_Shadow_Metamorphosis",
                Destruction = "Spell_Shadow_RainOfFire" },
    DRUID = { Balance = "Spell_Nature_StarFall", ["Feral (Cat)"] = "Ability_Druid_CatForm",
              ["Feral (Bear)"] = "Ability_Racial_BearForm", Restoration = "Spell_Nature_HealingTouch" },
}

-- p = { class, spec label | nil (any spec) }. scope "party" = only the caster's group; "raid" = everyone.
local BUFFS = {
    -- Party-wide (these decide the group layout)
    { key = "heroism", name = "Bloodlust / Heroism", icon = "Spell_Nature_BloodLust", iconA = "Ability_Shaman_Heroism",
      scope = "party", p = { { "SHAMAN" } } },
    { key = "windfury", name = "Windfury Totem", icon = "Spell_Nature_Windfury", scope = "party", p = { { "SHAMAN" } },
      tip = "Melee haste. One air totem per shaman (Windfury or Wrath of Air)." },
    { key = "wrathofair", name = "Wrath of Air Totem", icon = "Spell_Nature_SlowingTotem", scope = "party",
      p = { { "SHAMAN" } }, tip = "Spell damage. One air totem per shaman (Windfury or Wrath of Air)." },
    { key = "totemofwrath", name = "Totem of Wrath", icon = "Spell_Fire_TotemOfWrath", scope = "party",
      p = { { "SHAMAN", "Elemental" } }, tip = "Spell hit and crit." },
    { key = "unleashedrage", name = "Unleashed Rage", icon = "Spell_Nature_UnleashedRage", scope = "party",
      p = { { "SHAMAN", "Enhancement" } }, tip = "Melee attack power." },
    { key = "manatide", name = "Mana Tide Totem", icon = "Spell_Frost_SummonWaterElemental", scope = "party",
      p = { { "SHAMAN", "Restoration" } } },
    { key = "battleshout", name = "Battle Shout", icon = "Ability_Warrior_BattleShout", scope = "party",
      p = { { "WARRIOR" } }, tip = "Melee attack power." },
    { key = "trueshot", name = "Trueshot Aura", icon = "Ability_TrueShot", scope = "party",
      p = { { "HUNTER", "Marksmanship" } }, tip = "Attack power (melee and ranged)." },
    { key = "ferocious", name = "Ferocious Inspiration", icon = "Ability_Hunter_FerociousInspiration", scope = "party",
      p = { { "HUNTER", "Beast Mastery" } }, tip = "Damage done." },
    { key = "lotp", name = "Leader of the Pack", icon = "Spell_Nature_UnyeildingStamina", scope = "party",
      p = { { "DRUID", "Feral (Cat)" }, { "DRUID", "Feral (Bear)" } }, tip = "Melee and ranged crit." },
    { key = "moonkin", name = "Moonkin Aura", icon = "Spell_Nature_MoonGlow", scope = "party",
      p = { { "DRUID", "Balance" } }, tip = "Spell crit." },
    { key = "vampirictouch", name = "Vampiric Touch", icon = "Spell_Holy_Stoicism", scope = "party",
      p = { { "PRIEST", "Shadow" } }, tip = "Mana for the group." },
    { key = "sanctity", name = "Sanctity Aura", icon = "Spell_Holy_MindVision", scope = "party",
      p = { { "PALADIN", "Retribution" } }, tip = "Holy damage." },
    { key = "paladinaura", name = "Paladin aura", icon = "Spell_Holy_DevotionAura", scope = "party",
      p = { { "PALADIN" } }, tip = "Devotion, Concentration or a resistance aura." },
    -- Raid-wide buffs
    { key = "blessings", name = "Paladin blessings", icon = "Spell_Magic_GreaterBlessingofKings", scope = "raid",
      p = { { "PALADIN" } }, count = true, tip = "One Greater Blessing per paladin (Kings, Might, Wisdom, Salvation...)." },
    { key = "fortitude", name = "Power Word: Fortitude", icon = "Spell_Holy_WordFortitude", scope = "raid",
      p = { { "PRIEST" } } },
    { key = "divinespirit", name = "Divine Spirit", icon = "Spell_Holy_DivineSpirit", scope = "raid",
      p = { { "PRIEST", "Discipline" } } },
    { key = "motw", name = "Mark of the Wild", icon = "Spell_Nature_Regeneration", scope = "raid", p = { { "DRUID" } } },
    { key = "arcaneint", name = "Arcane Intellect", icon = "Spell_Holy_MagicalSentry", scope = "raid", p = { { "MAGE" } } },
    -- Raid-wide debuffs on the boss
    { key = "sunder", name = "Sunder Armor", icon = "Ability_Warrior_Sunder", scope = "raid", debuff = true,
      p = { { "WARRIOR" } } },
    { key = "bloodfrenzy", name = "Blood Frenzy", icon = "Ability_Warrior_BloodFrenzy", scope = "raid", debuff = true,
      p = { { "WARRIOR", "Arms" } } },
    { key = "faeriefire", name = "Faerie Fire", icon = "Spell_Nature_FaerieFire", scope = "raid", debuff = true,
      p = { { "DRUID" } } },
    { key = "huntersmark", name = "Hunter's Mark", icon = "Ability_Hunter_SniperShot", scope = "raid", debuff = true,
      p = { { "HUNTER" } } },
    { key = "exposeweakness", name = "Expose Weakness", icon = "Ability_Rogue_FindWeakness", scope = "raid",
      debuff = true, p = { { "HUNTER", "Survival" } } },
    { key = "coe", name = "Curse of the Elements", icon = "Spell_Shadow_ChillTouch", scope = "raid", debuff = true,
      p = { { "WARLOCK" } } },
    { key = "misery", name = "Misery", icon = "Spell_Shadow_Misery", scope = "raid", debuff = true,
      p = { { "PRIEST", "Shadow" } } },
    { key = "impscorch", name = "Improved Scorch", icon = "Spell_Fire_SoulBurn", scope = "raid", debuff = true,
      p = { { "MAGE", "Fire" } } },
    { key = "jow", name = "Judgement of Wisdom", icon = "Spell_Holy_RighteousnessAura", scope = "raid", debuff = true,
      p = { { "PALADIN" } } },
}
local BUFF_BY_KEY = {}
for _, b in ipairs(BUFFS) do BUFF_BY_KEY[b.key] = b end

RaidComp.BUFFS = BUFFS

local function SpecLabel(classFile, sp)
    local specs = classFile and ns.SPECS[classFile]
    local spec = specs and sp and specs[sp]
    return spec and spec.label or nil
end

function RaidComp:SpecLabel(classFile, sp)
    return SpecLabel(classFile, sp)
end

-- Icon path of a spec (nil when unknown).
function RaidComp:SpecIcon(classFile, sp)
    local label = SpecLabel(classFile, sp)
    local icons = classFile and SPEC_ICONS[classFile]
    local name = icons and label and icons[label]
    return name and (I .. name) or nil
end

function RaidComp:BuffIcon(b)
    if type(b) == "string" then b = BUFF_BY_KEY[b] end
    if not b then return nil end
    if b.iconA and UnitFactionGroup and UnitFactionGroup("player") == "Alliance" then return I .. b.iconA end
    return I .. b.icon
end

function RaidComp:GetBuff(key) return BUFF_BY_KEY[key] end

-- tank / healer / melee / ranged (casters and hunters), or nil without a spec.
function RaidComp:RoleOf(classFile, sp)
    local specs = classFile and ns.SPECS[classFile]
    local spec = specs and sp and specs[sp]
    if not spec then return nil end
    return spec.role == "caster" and "ranged" or spec.role
end

-- True when a member of this class and spec brings buff b. A member without a known spec brings only the buffs any
-- spec of their class has.
local function Provides(b, classFile, sp)
    local label = SpecLabel(classFile, sp)
    for _, p in ipairs(b.p) do
        if p[1] == classFile and (p[2] == nil or p[2] == label) then return true end
    end
    return false
end

function RaidComp:Provides(buffKey, classFile, sp)
    local b = BUFF_BY_KEY[buffKey]
    return b ~= nil and Provides(b, classFile, sp)
end

-- members: array of { key, c = classFile, sp = spec index|nil }. scope: "party" | "raid".
-- Returns an array (in BUFFS order) of { buff = b, providers = { key, ... } } for every buff of that scope.
function RaidComp:Coverage(members, scope)
    local out = {}
    for _, b in ipairs(BUFFS) do
        if b.scope == scope then
            local providers = {}
            for _, m in ipairs(members) do
                if Provides(b, m.c, m.sp) then providers[#providers + 1] = m.key end
            end
            tsort(providers)
            out[#out + 1] = { buff = b, providers = providers }
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Auto-fill (§60): a sensible starting layout the organizer then adjusts.
-- 25-man: group 1 tanks, groups 2-3 melee, group 4 ranged, group 5 healers; 10-man: 1 tanks + melee, 2 ranged +
-- healers. Shamans go first, one per group that wants their totems (Enhancement and Restoration to the melee groups,
-- Elemental to the ranged group). Everyone else joins the least full group of their role, then any group with room.
---------------------------------------------------------------------------

local THEMES = {
    [25] = { { tank = true }, { melee = true }, { melee = true }, { ranged = true }, { healer = true } },
    [10] = { { tank = true, melee = true }, { ranged = true, healer = true } },
}
local GROUP_SIZE = 5

-- members: array of { key, c, sp }. Returns { [key] = group } (members that don't fit stay out).
function RaidComp:AutoFill(members, size)
    local themes = THEMES[size == 10 and 10 or 25]
    local count, grp = {}, {}
    for g = 1, #themes do count[g] = 0 end
    local function place(key, g)
        grp[key] = g
        count[g] = count[g] + 1
    end
    -- the least full group matching `want` (a role, or a function(g) -> bool); nil when all are full
    local function best(want)
        local pick
        for g = 1, #themes do
            local ok = type(want) == "function" and want(g) or (want == nil or themes[g][want])
            if ok and count[g] < GROUP_SIZE and (not pick or count[g] < count[pick]) then pick = g end
        end
        return pick
    end
    local list = {}
    for _, m in ipairs(members) do list[#list + 1] = m end
    tsort(list, function(a, b) return a.key < b.key end)
    local rest = {}
    local hasShaman = {}
    -- 1. shamans spread over the groups that want their totems
    for _, m in ipairs(list) do
        if m.c == "SHAMAN" then
            local label = SpecLabel(m.c, m.sp)
            local want = label == "Elemental" and "ranged" or "melee"
            local g = best(function(x) return themes[x][want] and not hasShaman[x] end)
                or best(function(x) return not hasShaman[x] and (themes[x].melee or themes[x].ranged) end)
                or best(RaidComp:RoleOf(m.c, m.sp)) or best(nil)
            if g then
                place(m.key, g)
                hasShaman[g] = true
            end
        else
            rest[#rest + 1] = m
        end
    end
    -- 2. everyone else by role: members who bring a party buff first (they matter most for their group), members
    --    without a spec last
    local function rank(m)
        if not RaidComp:RoleOf(m.c, m.sp) then return 2 end
        for _, buff in ipairs(BUFFS) do
            if buff.scope == "party" and Provides(buff, m.c, m.sp) then return 0 end
        end
        return 1
    end
    tsort(rest, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a.key < b.key
    end)
    for _, m in ipairs(rest) do
        local role = RaidComp:RoleOf(m.c, m.sp)
        local g = (role and best(role)) or best(nil)
        if g then place(m.key, g) end
    end
    return grp
end

function RaidComp:GroupCount(size)
    return size == 10 and 2 or 5
end

RaidComp.GROUP_SIZE = GROUP_SIZE
