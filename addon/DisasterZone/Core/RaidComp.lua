if DisasterZoneBoot and DisasterZoneBoot.Run("Core/RaidComp.lua", ...) then return end -- DisasterZone: Core/RaidComp.lua
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
      air = true, tip = "Melee haste. One air totem per shaman (Windfury or Wrath of Air)." },
    { key = "wrathofair", name = "Wrath of Air Totem", icon = "Spell_Nature_SlowingTotem", scope = "party",
      p = { { "SHAMAN" } }, air = true,
      tip = "Spell damage and healing. One air totem per shaman (Windfury or Wrath of Air)." },
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

-- Who gains from which air totem: "melee" (melee and tanks: Windfury), "spell" (casters and healers: Wrath of Air),
-- or nil (hunters; or a spec that is unknown and the class's specs don't agree).
local function AirKind(classFile, sp)
    local function kind(role)
        if role == "melee" or role == "tank" then return "melee" end
        if role == "caster" or role == "healer" then return "spell" end
        return nil
    end
    local specs = classFile and ns.SPECS[classFile]
    if not specs then return nil end
    if sp and specs[sp] then return kind(specs[sp].role) end
    local k = specs[1] and kind(specs[1].role)
    for _, spec in ipairs(specs) do
        if kind(spec.role) ~= k then return nil end
    end
    return k
end

-- The air totem a group's shamans put down: "windfury" when most of the group is melee, "wrathofair" when most are
-- casters and healers; nil when both show (no shaman, an even split, or two shamans and both kinds to serve).
-- Second value: why, for the buff's tooltip.
function RaidComp:AirTotem(members)
    local shamans, melee, spell = 0, 0, 0
    for _, m in ipairs(members) do
        if m.c == "SHAMAN" then shamans = shamans + 1 end
        local k = AirKind(m.c, m.sp)
        if k == "melee" then melee = melee + 1 elseif k == "spell" then spell = spell + 1 end
    end
    if shamans == 0 then return nil end
    if shamans > 1 and melee > 0 and spell > 0 then return nil, "Two shamans here: one of each air totem." end
    if melee > spell then return "windfury", "Picked for this group: mostly melee." end
    if spell > melee then return "wrathofair", "Picked for this group: mostly casters and healers." end
    return nil, "Melee and casters are even here, so both show."
end

-- members: array of { key, c = classFile, sp = spec index|nil }. scope: "party" | "raid".
-- Returns an array (in BUFFS order) of { buff = b, providers = { key, ... }, note = text|nil } for every buff of that
-- scope. In a party, the shamans' air totem follows the group (AirTotem): the other one has no providers.
function RaidComp:Coverage(members, scope)
    local air, why
    if scope == "party" then air, why = self:AirTotem(members) end
    local out = {}
    for _, b in ipairs(BUFFS) do
        if b.scope == scope then
            local providers = {}
            if not (b.air and air and air ~= b.key) then
                for _, m in ipairs(members) do
                    if Provides(b, m.c, m.sp) then providers[#providers + 1] = m.key end
                end
            end
            tsort(providers)
            out[#out + 1] = { buff = b, providers = providers, note = b.air and #providers > 0 and why or nil }
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

-- Where a comp's open slots would sit (the Teams page shows them as ghosts in the free seats): each open slot goes to
-- the group with room that already has the most of its role (players and slots placed before it), the least full
-- on a tie; a shaman's slot first looks for a group without a shaman. Shamans' slots go first, then the rest in comp
-- order. byGroup = { [g] = { member, ... } } (members { c, sp }), open = { { c, sp, ... }, ... } (one per slot),
-- n = the group count. Returns { [g] = { slot, ... } } (slots that find no room are left out).
function RaidComp:PlaceOpen(byGroup, open, n)
    local out, count, roles, shaman = {}, {}, {}, {}
    for g = 1, n do
        out[g], count[g], roles[g] = {}, 0, {}
        for _, m in ipairs(byGroup[g] or {}) do
            count[g] = count[g] + 1
            local role = RaidComp:RoleOf(m.c, m.sp)
            if role then roles[g][role] = (roles[g][role] or 0) + 1 end
            if m.c == "SHAMAN" then shaman[g] = true end
        end
    end
    local list = {}
    for i, s in ipairs(open or {}) do list[#list + 1] = { s = s, i = i } end
    tsort(list, function(a, b)
        local sa, sb = a.s.c == "SHAMAN", b.s.c == "SHAMAN"
        if sa ~= sb then return sa end
        return a.i < b.i
    end)
    for _, e in ipairs(list) do
        local s = e.s
        local role = RaidComp:RoleOf(s.c, s.sp)
        local pick, best
        for g = 1, n do
            if count[g] < GROUP_SIZE then
                local score = (role and roles[g][role] or 0) * 10 - count[g]
                if s.c == "SHAMAN" and not shaman[g] then score = score + 100 end
                if not best or score > best then pick, best = g, score end
            end
        end
        if pick then
            local l = out[pick]
            l[#l + 1] = s
            count[pick] = count[pick] + 1
            if role then roles[pick][role] = (roles[pick][role] or 0) + 1 end
            if s.c == "SHAMAN" then shaman[pick] = true end
        end
    end
    return out
end

function RaidComp:GroupCount(size)
    return size == 10 and 2 or 5
end

RaidComp.GROUP_SIZE = GROUP_SIZE

---------------------------------------------------------------------------
-- Target comp (1.3.1): the specs a team wants, matched with who it has. Every slot names a spec (class + spec
-- index of ns.SPECS; Feral (Cat) and Feral (Bear) are DRUID 2 and 3). A comp is stored as counts per spec:
--   cp = { PALADIN = { 2, 1, 1 }, DRUID = { 1, 1, 1, 1 }, ... }   (trailing zeros trimmed, classes without a slot
--   left out; about 110 bytes for a full 25)
-- on the team record (Core/RaidPlan.lua, field cp of T) and synced with it. The presets are bundled data, never
-- synced: "Start from" copies their counts, so changing a preset later changes no team. Who fills which slot, the
-- bench, the open slots and who could fill one are computed on each client from the same data, sorted by fixed keys
-- (never left to chance).
--
-- API contract for the UI (the Teams page and the raid page):
--   Shapes
--     cp      { [CLASS] = { n1, n2, n3[, n4] } }: slots per spec index (0..25 each, at most the team's size in all)
--     member  { key, c = classFile|nil, sp = spec index|nil, seated = true: fills first (in a group / Accepted),
--               source = "team"|"signup"|"bis"|nil }
--     slot    { c, sp, role = "tank"|"healer"|"melee"|"ranged", name = "Holy Paladin", key = who fills it|nil,
--               member = that member|nil }
--     open    { c, sp, role, name, n = open slots of that spec }, in comp order
--     team    a team id, a GetTeam table, or the Teams page's draft { id, members = set|array, s|specs, grp|groups,
--             sz|size, cp|comp }
--     cand    a can-fill candidate { key, c, sp|nil, online, other = true: the class in another (or unknown) spec,
--             of = the team member it is an alt of (alts), team / teamId (other teams), st = "B" (raid: on the bench) }
--   Comp order: the columns tank, healer, melee, ranged; in each, classes in ns.CLASSES order, then spec index.
--   RaidComp (pure)
--     RaidComp.COLUMNS / RaidComp.PRESETS      { "tank", "healer", "melee", "ranged" } / the bundled presets
--     RaidComp:GetPresets([size])              { { key = "std25"|"kara10", name, size, cp }, ... } (copies)
--     RaidComp:GetPreset(key)                  one preset (a copy) or nil
--     RaidComp:CleanComp(cp[, maxTotal])       canonical copy, total; nil = no comp (nil, or no slot); false =
--                                              invalid (unknown class or spec, count not 0..25, total > maxTotal)
--     RaidComp:CopyComp(cp)                    canonical copy (nil for nil)
--     RaidComp:SameComp(a, b)                  same counts (nil and {} are the same)
--     RaidComp:CompSize(cp) / GetCount(cp, c, sp) / RoleCounts(cp)   slots in all / of one spec / per column
--     RaidComp:SetCount(cp, c, sp, n)          sets one spec's slots (0..25; 0 takes it out) in place, cp a table
--                                              (a draft starts from {}); returns cp
--     RaidComp:SlotName(c, sp) / ClassName(c)  "Holy Paladin", "Feral Druid (Bear)" / "Paladin"
--     RaidComp:CompSlots(cp)                   every slot in comp order { c, sp, role, name }
--     RaidComp:MatchComp(cp, members)          { columns = { tank = { slot, ... }, healer, melee, ranged },
--                                              slots = { slot, ... }, bench = { member, ... }, open = { open, ... },
--                                              filled, total, openCount }. A member fills a slot of their own spec
--                                              only; per spec seated first, then by key. Bench = the members no slot
--                                              takes (not an error), by column then key, unknown spec last.
--     RaidComp:OpenSlots(cp, members)          open list, number of open slots
--     RaidComp:CompFromMembers(members, size)  "the team as it is": a slot per member's spec (members without one
--                                              left out; seated first, then by key, at most `size`); nil when none
--     RaidComp:BuffStates(have, planned)       the raid-buff strip, in BUFFS order (scope "raid"): { key, buff,
--                                              state = "have"|"planned"|"off", providers = { key, ... },
--                                              slots = { { c, sp, name }, ... } (open slots that would bring it),
--                                              count = #providers, bringers = { { c, sp|nil, name }, ... } }.
--                                              have = members who are there; planned = open slots ({ c, sp }).
--     RaidComp:ShortRaidName(v)                "SSC", "Kara", ... (a raid view; Other: its title)
--     RaidComp:LFLine(guild, open, when)       "<Guild> LF Holy Paladin ×2, Survival Hunter · SSC Sun 20:00 · /w me"
--                                              (at most 255 bytes: the last specs become "+n more"); nil without open
--   RaidPlan (Core/RaidPlan.lua, section "Target comp")
--     GetTeam(id).comp                         the saved comp (a copy) or nil
--     SaveTeam(id, name, members, { ..., comp = cp|false })   nil keeps the comp, false (or a comp without a
--                                              slot) clears it; refused when it has more slots than the team's size
--                                              (a 25 -> 10 change: start again from Kara 10)
--     SetTeamComp(id, cp|false) / GetTeamComp(id)   save only the comp (GM + guild council) / a copy or nil
--     GetCompStarts(team)                      the "Start from" tiles: { { key, kind = "preset"|"team"|"copy",
--                                              name, size, cp, teamId (copy) }, ... }: the preset of the team's size,
--                                              the team as it is (when a member's spec is known), other teams' comps
--                                              of the same size (by name)
--     ResolveTeam(team)                        { id, name, members (sorted), specs, groups, size, comp } or nil
--     GetTeamMembers(team)                     { member, ... } by key (spec as the Teams page decides:
--                                              GetMemberSpec(key, team)); seated = in one of the team's groups
--     GetTeamPlaced(team)                      placed, benched: the members in a group / in none. Benched members
--                                              (the Teams page's "Benched") never count: no slot, no raid buff, not
--                                              in "the team as it is"
--     CompFromTeam(team)                       the team as it is (cp, from the members in a group) or nil
--     MatchTeam(team)                          MatchComp of the team's comp and its members in a group, plus
--                                              benched = { member, ... } (in no group; bench order); nil without a comp
--     GetTeamOpenSlots(team)                   open list, count ({}, 0 without a comp)
--     CanFill(team, c, sp)                     { bench, extra, alts, guild, teams = { cand, ... } }: the team's
--                                              benched members, its members in a group beyond the comp (that class),
--                                              alts of its members (level 70), the rest of the guild (level 70, on no
--                                              team, spec from sign-ups / BiS list), members of other teams (that spec
--                                              there). bench and alts also list the class in another spec (other =
--                                              true); guild and teams that spec only. A player shows once. Each list:
--                                              that spec first, online first, by key.
--     GetSpecIndex()                           { bySpec = { ["CLASS:sp"] = { key, ... } }, byKey = { [key] =
--                                              { c, sp, src } } }: level-70 guild members (cached, dropped on changes)
--     GetRaidCompTeam(occ)                     the team whose comp a raid uses: its first team (tm order) with a comp
--                                              and the raid's size; nil = no open slots
--     GetRaidOpenSlots(occ)                    nil, or { teamId, teamName, size, wanted, filled, openCount,
--                                              open = { open, ... }, slots = { { c, sp, role, name }, ... } (one per
--                                              open slot, comp order), match }: what the comp asks minus the
--                                              Accepted and Tentative answers of each spec (guests count by their
--                                              class and spec; Accepted fill first). Nil for a cancelled raid.
--     RaidCanFill(occ, c, sp)                  { unanswered = { cand }, guild = { cand } }: team members of that
--                                              spec who haven't answered, then level-70 guild members of that spec
--                                              who haven't answered (or are on the bench: st = "B")
--     GetTeamBuffStates(team)                  BuffStates(filled slots, open slots); without a comp: the members in a
--                                              group
--     GetRaidBuffStates(occ[, have])           BuffStates(have, default Accepted + Tentative; its open slots)
--     GetTeamNextRaid(teamId)                  the team's next raid (a view; not cancelled, started < 6 h ago) or nil
--     GetLFMessage(team)                       the LF line for the open slots and the next raid, or nil without open
--                                              slots. The UI puts it in the chat box (ChatFrame_OpenChat); no sending.
---------------------------------------------------------------------------

local floor, min, max, tonumber, tostring, tconcat = math.floor, math.min, math.max, tonumber, tostring, table.concat

local COLUMNS = { "tank", "healer", "melee", "ranged" }
local COLUMN_INDEX = { tank = 1, healer = 2, melee = 3, ranged = 4 }
local MAX_COUNT = 25                -- slots of one spec
local MAX_COMP = 25                 -- slots of a comp (the largest team)
local LF_MAX = 255                  -- a chat line (bytes)

-- The bundled presets (user decision 2026-10-05). Spec indexes of ns.SPECS.
local PRESETS = {
    { key = "std25", name = "Standard 25", size = 25, cp = {
        WARRIOR = { 0, 1, 1 },          -- Fury, Protection
        PALADIN = { 2, 1, 1 },          -- Holy x2, Protection, Retribution
        HUNTER = { 0, 1, 1 },           -- Marksmanship, Survival
        ROGUE = { 0, 2 },               -- Combat x2
        PRIEST = { 0, 1, 1 },           -- Holy, Shadow
        SHAMAN = { 1, 2, 2 },           -- Elemental, Enhancement x2, Restoration x2
        MAGE = { 1, 1 },                -- Arcane, Fire
        WARLOCK = { 1, 0, 1 },          -- Affliction, Destruction
        DRUID = { 1, 1, 1, 1 },         -- Balance, Feral (Cat), Feral (Bear), Restoration
    } },
    { key = "kara10", name = "Kara 10", size = 10, cp = {
        WARRIOR = { 0, 0, 1 },          -- Protection
        PALADIN = { 1, 1 },             -- Holy, Protection
        HUNTER = { 0, 1 },              -- Marksmanship
        ROGUE = { 0, 1 },               -- Combat
        PRIEST = { 0, 1 },              -- Holy
        SHAMAN = { 0, 1 },              -- Enhancement
        MAGE = { 0, 1 },                -- Fire
        WARLOCK = { 0, 0, 1 },          -- Destruction
        DRUID = { 0, 0, 0, 1 },         -- Restoration
    } },
}

local RAID_SHORT = { kara = "Kara", gruul = "Gruul", mag = "Mag", ssc = "SSC", tk = "TK", hyjal = "Hyjal", bt = "BT",
                     za = "ZA", swp = "SWP" }

RaidComp.COLUMNS = COLUMNS
RaidComp.PRESETS = PRESETS
RaidComp.MAX_COUNT = MAX_COUNT

-- The column of a spec (tank / healer / melee / ranged), or nil for an unknown class or spec.
local function Role(classFile, sp)
    local specs = type(classFile) == "string" and ns.SPECS[classFile]
    local spec = specs and type(sp) == "number" and specs[sp]
    if not spec then return nil end
    return spec.role == "caster" and "ranged" or spec.role
end

local function ClassName(classFile)
    return type(classFile) == "string" and (ns.CLASS_NAMES and ns.CLASS_NAMES[classFile] or classFile) or nil
end

-- "Holy Paladin", "Feral Druid (Bear)"; the class name alone without a known spec.
local function SlotName(classFile, sp)
    local cls = ClassName(classFile)
    local label = type(sp) == "number" and SpecLabel(classFile, sp)
    if not cls or not label then return cls end
    local form = label:match("^Feral %((.+)%)$")
    if form then return "Feral " .. cls .. " (" .. form .. ")" end
    return label .. " " .. cls
end

local function SpecIndex(classFile, label)
    for i, spec in ipairs(ns.SPECS[classFile] or {}) do
        if spec.label == label then return i end
    end
    return nil
end

-- Slots of one spec in a comp (0 for anything unknown).
local function Count(cp, classFile, sp)
    local counts = type(cp) == "table" and cp[classFile]
    local n = type(counts) == "table" and counts[sp]
    return type(n) == "number" and n or 0
end

-- A comp in its stored form, built from any comp of known classes: holes 0, trailing zeros trimmed, classes without a
-- slot left out (a new table).
local function Canon(cp)
    local out = {}
    for _, c in ipairs(ns.CLASSES) do
        local last = 0
        for sp = 1, #ns.SPECS[c] do
            if Count(cp, c, sp) > 0 then last = sp end
        end
        if last > 0 then
            local arr = {}
            for sp = 1, last do arr[sp] = Count(cp, c, sp) end
            out[c] = arr
        end
    end
    return out
end

local function IsCount(n)
    return type(n) == "number" and n == floor(n) and n >= 0 and n <= MAX_COUNT
end

-- An untrusted comp (the network, the UI) -> its canonical copy and total; nil when there is none (nil, or not one
-- slot); false when invalid: not a table, an unknown class or spec index, a count that is not 0..25, or more slots in
-- all than maxTotal (default 25).
local function CleanComp(cp, maxTotal)
    if cp == nil then return nil end
    if type(cp) ~= "table" then return false end
    local total = 0
    for c, counts in pairs(cp) do
        local specs = type(c) == "string" and ns.SPECS[c]
        if not specs or type(counts) ~= "table" then return false end
        for sp, n in pairs(counts) do
            if type(sp) ~= "number" or sp ~= floor(sp) or sp < 1 or sp > #specs or not IsCount(n) then return false end
            total = total + n
        end
    end
    if total > (tonumber(maxTotal) or MAX_COMP) then return false end
    if total == 0 then return nil end
    return Canon(cp), total
end

-- fn(classFile, sp, role, n) for every spec with slots, in comp order.
local function EachSpec(cp, fn)
    if type(cp) ~= "table" then return end
    for _, role in ipairs(COLUMNS) do
        for _, c in ipairs(ns.CLASSES) do
            for sp = 1, #ns.SPECS[c] do
                local n = min(floor(Count(cp, c, sp)), MAX_COUNT)
                if n > 0 and Role(c, sp) == role then fn(c, sp, role, n) end
            end
        end
    end
end

-- Who takes a slot first: seated (in a group; for a raid: Accepted), then by key.
local function SeatedFirst(a, b)
    local sa, sb = a.seated and 1 or 0, b.seated and 1 or 0
    if sa ~= sb then return sa > sb end
    return a.key < b.key
end

-- members -> those with a key, each key once (the first), in the order given.
local function UniqueMembers(members)
    local out, seen = {}, {}
    for _, m in ipairs(type(members) == "table" and members or {}) do
        if type(m) == "table" and type(m.key) == "string" and not seen[m.key] then
            seen[m.key] = true
            out[#out + 1] = m
        end
    end
    return out
end

function RaidComp:GetPresets(size)
    local out = {}
    for _, p in ipairs(PRESETS) do
        if size == nil or p.size == size then
            out[#out + 1] = { key = p.key, name = p.name, size = p.size, cp = Canon(p.cp) }
        end
    end
    return out
end

function RaidComp:GetPreset(key)
    for _, p in ipairs(PRESETS) do
        if p.key == key then return { key = p.key, name = p.name, size = p.size, cp = Canon(p.cp) } end
    end
    return nil
end

function RaidComp:CleanComp(cp, maxTotal)
    return CleanComp(cp, maxTotal)
end

function RaidComp:CopyComp(cp)
    if type(cp) ~= "table" then return nil end
    return Canon(cp)
end

function RaidComp:SameComp(a, b)
    for _, c in ipairs(ns.CLASSES) do
        for sp = 1, #ns.SPECS[c] do
            if Count(a, c, sp) ~= Count(b, c, sp) then return false end
        end
    end
    return true
end

function RaidComp:CompSize(cp)
    local n = 0
    EachSpec(cp, function(_, _, _, k) n = n + k end)
    return n
end

function RaidComp:GetCount(cp, classFile, sp)
    return Count(cp, classFile, sp)
end

function RaidComp:RoleCounts(cp)
    local out = { tank = 0, healer = 0, melee = 0, ranged = 0 }
    EachSpec(cp, function(_, _, role, n) out[role] = out[role] + n end)
    return out
end

-- Sets the slots of one spec (0 takes it out) in place, keeping the stored form. Returns cp.
function RaidComp:SetCount(cp, classFile, sp, n)
    if type(cp) ~= "table" or not Role(classFile, sp) then return cp end
    n = max(0, min(MAX_COUNT, floor(tonumber(n) or 0)))
    local canon = Canon(cp)
    canon[classFile] = canon[classFile] or {}
    canon[classFile][sp] = n
    canon = Canon(canon)
    for k in pairs(cp) do cp[k] = nil end
    for k, v in pairs(canon) do cp[k] = v end
    return cp
end

function RaidComp:SlotName(classFile, sp)
    return SlotName(classFile, sp)
end

function RaidComp:ClassName(classFile)
    return ClassName(classFile)
end

function RaidComp:CompSlots(cp)
    local out = {}
    EachSpec(cp, function(c, sp, role, n)
        for _ = 1, n do out[#out + 1] = { c = c, sp = sp, role = role, name = SlotName(c, sp) } end
    end)
    return out
end

function RaidComp:MatchComp(cp, members)
    local res = { columns = {}, slots = {}, bench = {}, open = {}, filled = 0, total = 0, openCount = 0 }
    for _, role in ipairs(COLUMNS) do res.columns[role] = {} end
    local list = UniqueMembers(members)
    local bySpec = {}
    for _, m in ipairs(list) do
        if Role(m.c, m.sp) then
            local k = m.c .. ":" .. m.sp
            bySpec[k] = bySpec[k] or {}
            bySpec[k][#bySpec[k] + 1] = m
        end
    end
    for _, l in pairs(bySpec) do tsort(l, SeatedFirst) end
    local used = {}
    EachSpec(cp, function(c, sp, role, n)
        local cand = bySpec[c .. ":" .. sp] or {}
        local name = SlotName(c, sp)
        local open = 0
        for i = 1, n do
            local m = cand[i]
            local slot = { c = c, sp = sp, role = role, name = name, key = m and m.key or nil, member = m }
            local col = res.columns[role]
            col[#col + 1] = slot
            res.slots[#res.slots + 1] = slot
            res.total = res.total + 1
            if m then
                used[m.key] = true
                res.filled = res.filled + 1
            else
                open = open + 1
            end
        end
        if open > 0 then res.open[#res.open + 1] = { c = c, sp = sp, role = role, name = name, n = open } end
    end)
    res.openCount = res.total - res.filled
    for _, m in ipairs(list) do
        if not used[m.key] then res.bench[#res.bench + 1] = m end
    end
    tsort(res.bench, function(a, b)
        local ra, rb = COLUMN_INDEX[Role(a.c, a.sp) or ""] or 5, COLUMN_INDEX[Role(b.c, b.sp) or ""] or 5
        if ra ~= rb then return ra < rb end
        return a.key < b.key
    end)
    return res
end

function RaidComp:OpenSlots(cp, members)
    local m = self:MatchComp(cp, members)
    return m.open, m.openCount
end

function RaidComp:CompFromMembers(members, size)
    local list = {}
    for _, m in ipairs(UniqueMembers(members)) do
        if Role(m.c, m.sp) then list[#list + 1] = m end
    end
    tsort(list, SeatedFirst)
    local cap = (size == 10 or size == 25) and size or MAX_COMP
    local cp, n = {}, 0
    for _, m in ipairs(list) do
        if n >= cap then break end
        cp[m.c] = cp[m.c] or {}
        cp[m.c][m.sp] = (cp[m.c][m.sp] or 0) + 1
        n = n + 1
    end
    if n == 0 then return nil end
    return Canon(cp), n
end

function RaidComp:BuffStates(have, planned)
    local out = {}
    for _, b in ipairs(BUFFS) do
        if b.scope == "raid" then
            local providers, slots, seen = {}, {}, {}
            for _, m in ipairs(type(have) == "table" and have or {}) do
                if type(m) == "table" and type(m.key) == "string" and Provides(b, m.c, m.sp) then
                    providers[#providers + 1] = m.key
                end
            end
            tsort(providers)
            for _, s in ipairs(type(planned) == "table" and planned or {}) do
                if type(s) == "table" and Role(s.c, s.sp) and Provides(b, s.c, s.sp) then
                    local k = s.c .. ":" .. s.sp
                    if not seen[k] then
                        seen[k] = true
                        slots[#slots + 1] = { c = s.c, sp = s.sp, name = SlotName(s.c, s.sp) }
                    end
                end
            end
            local bringers = {}
            for _, p in ipairs(b.p) do
                local sp = p[2] and SpecIndex(p[1], p[2]) or nil
                bringers[#bringers + 1] = { c = p[1], sp = sp, name = sp and SlotName(p[1], sp) or ClassName(p[1]) }
            end
            local state = (#providers > 0 and "have") or (#slots > 0 and "planned") or "off"
            out[#out + 1] = { key = b.key, buff = b, state = state, providers = providers, slots = slots,
                              count = #providers, bringers = bringers }
        end
    end
    return out
end

function RaidComp:ShortRaidName(v)
    if type(v) ~= "table" then return nil end
    -- (1.3.2: a raid of several instances, "Gruul + Mag")
    if type(v.ix) == "table" and v.ix[1] and RAID_SHORT[v.i] then
        local list = { v.i }
        for _, key in ipairs(v.ix) do if key ~= v.i then list[#list + 1] = key end end
        return self:ShortInstanceNames(list)
    end
    return RAID_SHORT[v.i] or v.ti or "Raid"
end

-- Instance keys -> "Gruul + Mag" (an instance without a short name: "Other").
function RaidComp:ShortInstanceNames(list)
    local names = {}
    for i, key in ipairs(type(list) == "table" and list or {}) do names[i] = RAID_SHORT[key] or "Other" end
    return tconcat(names, " + ")
end

function RaidComp:LFLine(guild, open, when)
    if type(open) ~= "table" or #open == 0 then return nil end
    local head = (type(guild) == "string" and guild ~= "" and ("<" .. guild .. "> ") or "") .. "LF "
    local tail = (type(when) == "string" and when ~= "" and (" · " .. when) or "") .. " · /w me"
    local parts = {}
    for i, o in ipairs(open) do
        local n = tonumber(o.n) or 1
        parts[i] = tostring(o.name or SlotName(o.c, o.sp) or "?") .. (n > 1 and (" ×" .. n) or "")
    end
    for keep = #parts, 1, -1 do
        local list = {}
        for i = 1, keep do list[i] = parts[i] end
        if keep < #parts then list[#list + 1] = "+" .. (#parts - keep) .. " more" end
        local line = head .. tconcat(list, ", ") .. tail
        if #line <= LF_MAX then return line end
    end
    return ("LF " .. parts[1]):sub(1, LF_MAX)
end
