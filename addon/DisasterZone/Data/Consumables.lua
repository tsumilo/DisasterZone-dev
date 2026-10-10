if DisasterZoneBoot and DisasterZoneBoot.Run("Data/Consumables.lua", ...) then return end -- DisasterZone: Data/Consumables.lua
-- The consumables kit per spec (My BiS > Consumables, Core/Kit.lua): for each slot of the kit the best pick (prog
-- nights) and a budget pick (farm nights). A budget of "same" means the cheap way is the same thing, false means skip it
-- (skip = why). Picked by hand from WoWSims' raid presets and the usual TBC class guides; the gear sim puts DPS
-- numbers on them where it covers the spec.
local _, ns = ...
ns.Data = ns.Data or {}

local C = {}
ns.Data.Consumables = C

-- item -> { name, short name (for an elixir pair), what it does, kind }
-- kinds: flask, battle, guardian (elixirs), food, stone, oil, potion, scroll, rune (runes, Flame Cap, Thistle Tea)
C.ITEMS = {
  -- flasks
  [22854] = { "Flask of Relentless Assault", "Relentless Assault", "+120 attack power", "flask" },
  [22866] = { "Flask of Pure Death", "Pure Death", "+80 shadow, fire, frost dmg", "flask" },
  [22861] = { "Flask of Blinding Light", "Blinding Light", "+80 arcane, nature, holy dmg", "flask" },
  [22853] = { "Flask of Mighty Restoration", "Mighty Restoration", "+25 mana per 5 sec", "flask" },
  [22851] = { "Flask of Fortification", "Fortification", "+500 health, +10 defense", "flask" },
  -- battle elixirs
  [22824] = { "Elixir of Major Strength", "Strength", "+35 Strength", "battle" },
  [22831] = { "Elixir of Major Agility", "Agility", "+35 Agility, +20 crit", "battle" },
  [28102] = { "Onslaught Elixir", "Onslaught", "+60 attack power", "battle" },
  [28103] = { "Adept's Elixir", "Adept's", "+24 spell damage and crit", "battle" },
  [22833] = { "Elixir of Major Firepower", "Firepower", "+55 fire damage", "battle" },
  [22835] = { "Elixir of Major Shadow Power", "Shadow Power", "+55 shadow damage", "battle" },
  [22827] = { "Elixir of Major Frost Power", "Frost Power", "+55 frost damage", "battle" },
  [22825] = { "Elixir of Healing Power", "Healing Power", "+50 healing", "battle" },
  [28104] = { "Elixir of Mastery", "Mastery", "+15 to all stats", "battle" },
  -- guardian elixirs
  [32062] = { "Elixir of Major Fortitude", "Fortitude", "+250 health", "guardian" },
  [32067] = { "Elixir of Draenic Wisdom", "Wisdom", "+30 Intellect, +30 Spirit", "guardian" },
  [22840] = { "Elixir of Major Mageblood", "Mageblood", "+16 mana per 5 sec", "guardian" },
  [22834] = { "Elixir of Major Defense", "Defense", "+550 armor", "guardian" },
  -- food
  [27658] = { "Roasted Clefthoof", nil, "+20 Strength, +20 Spirit", "food" },
  [27655] = { "Ravager Dog", nil, "+40 attack power", "food" },
  [27664] = { "Grilled Mudfish", nil, "+20 Agility, +20 Spirit", "food" },
  [27659] = { "Warp Burger", nil, "+20 Agility, +20 Spirit", "food" },
  [33872] = { "Spicy Hot Talbuk", nil, "+20 hit rating", "food" },
  [27657] = { "Blackened Basilisk", nil, "+23 spell damage", "food" },
  [27665] = { "Poached Bluefish", nil, "+23 spell damage", "food" },
  [33825] = { "Skullfish Soup", nil, "+20 spell crit rating", "food" },
  [27666] = { "Golden Fish Sticks", nil, "+44 healing", "food" },
  [27663] = { "Blackened Sporefish", nil, "+8 mana per 5 sec", "food" },
  [33052] = { "Fisherman's Feast", nil, "+30 Stamina", "food" },
  [27660] = { "Talbuk Steak", nil, "+20 Stamina", "food" },
  -- weapon stones and oils
  [23529] = { "Adamantite Sharpening Stone", nil, "+12 damage, +14 crit", "stone" },
  [23528] = { "Fel Sharpening Stone", nil, "+12 weapon damage", "stone" },
  [28421] = { "Adamantite Weightstone", nil, "+12 damage, +14 crit", "stone" },
  [28420] = { "Fel Weightstone", nil, "+12 weapon damage", "stone" },
  [20749] = { "Brilliant Wizard Oil", nil, "+36 spell dmg, +14 crit", "oil" },
  [22522] = { "Superior Wizard Oil", nil, "+42 spell damage", "oil" },
  [20748] = { "Brilliant Mana Oil", nil, "+12 mp5, +25 healing", "oil" },
  [22521] = { "Superior Mana Oil", nil, "+14 mana per 5 sec", "oil" },
  -- potions
  [22838] = { "Haste Potion", nil, "+400 haste for 15 sec", "potion" },
  [22828] = { "Insane Strength Potion", nil, "+120 Strength for 15 sec", "potion" },
  [22839] = { "Destruction Potion", nil, "+120 spell dmg for 15 sec", "potion" },
  [22832] = { "Super Mana Potion", nil, "1800 to 3000 mana", "potion" },
  [22829] = { "Super Healing Potion", nil, "1500 to 2500 health", "potion" },
  [22849] = { "Ironshield Potion", nil, "+2500 armor for 2 min", "potion" },
  -- scrolls
  [27503] = { "Scroll of Strength V", "Strength", "+20 Strength", "scroll" },
  [27498] = { "Scroll of Agility V", "Agility", "+20 Agility", "scroll" },
  [27500] = { "Scroll of Protection V", "Protection", "+300 armor", "scroll" },
  -- runes and the like (their own shared 2 minute timer)
  [12662] = { "Demonic Rune", nil, "900 to 1500 mana", "rune" },
  [22788] = { "Flame Cap", nil, "+80 fire damage for 1 min", "rune" },
  [7676] = { "Thistle Tea", nil, "+40 energy", "rune" },
}

-- How many of a kind one night takes (a three hour raid): a flask lasts 2 hours, an elixir 1, food, stones, oils and
-- scrolls 30 minutes; a potion or rune per boss you use it on.
C.NIGHT = { flask = 2, battle = 3, guardian = 3, food = 6, stone = 6, oil = 6, potion = 5, scroll = 6, rune = 4 }

-- The kit's slots, in the order shown; why = the line under the slot's name (a spec can override it).
C.SLOTS = {
  { key = "flask", title = "FLASK", why = "Or two elixirs, never both." },
  { key = "food", title = "FOOD", why = "Well Fed lasts 30 minutes." },
  { key = "weapon", title = "WEAPON", why = "On the weapon for 30 minutes." },
  { key = "potion", title = "POTION", why = "One per fight." },
  { key = "scroll", title = "SCROLLS", why = "Useless if a buff gives the same stat." },
  { key = "extra", title = "EXTRA", why = "Its own timer, apart from potions." },
}

-- A sharpening stone on a blunt weapon is the weightstone.
C.BLUNT = { [23529] = 28421, [23528] = 28420 }

-- For the gear sim (Sim/Buffs.lua ApplyConsumables): weapon imbues by WoWSims' id, scrolls by field. The other kinds
-- go by item id (flaskId, battleElixirId, guardianElixirId, foodId, potId, conjuredId).
C.SIM_IMBUE = { [23529] = 29453, [28421] = 34340, [22522] = 28017, [20749] = 25122, [20748] = 25123 }
C.SIM_SCROLL = { [27503] = "scrollStr", [27498] = "scrollAgi" }
C.SIM_RUNE = { [12662] = true, [22788] = true, [7676] = true }

local SKIP_RUNE = "Farm bosses die before you run dry."
local WF_WHY = "Windfury Totem replaces it."

-- shared rows
local MELEE_STONE = { best = { 23529 }, budget = { 23528 }, why = WF_WHY }
local SCROLLS_PHYS = { best = { 27503, 27498 }, budget = "same", sameWhy = "Cheap enough for every night." }
local SCROLL_AGI = { best = { 27498 }, budget = "same", sameWhy = "Cheap enough for every night." }
local HASTE_SAME = { best = { 22838 }, budget = "same", sameWhy = "Cheap for what it does." }
local CASTER_FOOD = { best = { 27657 }, budget = { 27665 } }
local CASTER_OIL = { best = { 20749 }, budget = { 22522 } }
local CASTER_POT = { best = { 22839 }, budget = { 22832 } }
local CASTER_RUNE = { best = { 12662 }, budget = false, skip = SKIP_RUNE }
local HEAL_FOOD = { best = { 27666 }, budget = { 27663 } }
local HEAL_OIL = { best = { 20748 }, budget = { 22521 } }
local HEAL_POT = { best = { 22832 }, budget = "same", sameWhy = "Mana is the fight for a healer." }
local HEAL_RUNE = { best = { 12662 }, budget = "same", sameWhy = "Mana is the fight for a healer." }
local TANK_FOOD = { best = { 33052 }, budget = { 27660 } }
local TANK_POT = { best = { 22849 }, budget = { 22829 } }
local TANK_SCROLL = { best = { 27500, 27498 }, budget = "same", sameWhy = "Cheap enough for every night." }

local function caster(flask, battle, guardian, extra)
  return { flask = { best = { flask }, budget = { battle, guardian or 32067 } }, food = CASTER_FOOD,
    weapon = CASTER_OIL, potion = CASTER_POT, extra = extra or CASTER_RUNE }
end

local function healer(guardian)
  return { flask = { best = { 22825, guardian }, budget = { 22825 }, budgetWhy = "Just the healing elixir." },
    food = HEAL_FOOD, weapon = HEAL_OIL, potion = HEAL_POT, extra = HEAL_RUNE }
end

local ROGUE = {
  flask = { best = { 22854 }, budget = { 22831, 32062 } },
  food = { best = { 33872 }, budget = { 27664 } },
  potion = HASTE_SAME, scroll = SCROLLS_PHYS,
  extra = { best = { 7676 }, budget = "same", sameWhy = "You make it yourself (Cooking)." },
}
local HUNTER = {
  flask = { best = { 22854 }, budget = { 22831, 32067 } },
  food = { best = { 27664 }, budget = { 27659 } },
  potion = HASTE_SAME, scroll = SCROLL_AGI,
  extra = { best = { 12662 }, budget = false, skip = SKIP_RUNE },
}
local TANK_WAR = {
  flask = { best = { 22851 }, budget = { 28104, 22834 } },
  food = TANK_FOOD, weapon = { best = { 23529 }, budget = { 23528 }, why = "More damage, more threat." },
  potion = TANK_POT, scroll = TANK_SCROLL,
}

C.KITS = {
  ["PALADIN:Retribution"] = {
    flask = { best = { 22854 }, budget = { 22824, 32067 } },
    food = { best = { 27658 }, budget = { 27655 } },
    weapon = MELEE_STONE,
    potion = { best = { 22838 }, budget = { 22832 } },
    scroll = SCROLLS_PHYS,
    extra = { best = { 12662 }, budget = false, skip = SKIP_RUNE, why = "Mana when you run dry." },
  },
  ["PALADIN:Holy"] = healer(22840),
  ["PALADIN:Protection"] = {
    flask = { best = { 22851 }, budget = { 28104, 22834 } },
    food = TANK_FOOD,
    weapon = { best = { 22522 }, budget = "same", sameWhy = "Cheap, and it is your threat.",
      why = "Spell damage is your threat." },
    potion = TANK_POT, scroll = TANK_SCROLL,
    extra = { best = { 12662 }, budget = "same", sameWhy = "Mana keeps the threat going." },
  },
  ["WARRIOR:Fury"] = {
    flask = { best = { 22854 }, budget = { 22831, 32062 } },
    food = { best = { 27658 }, budget = { 27655 } },
    weapon = MELEE_STONE, potion = HASTE_SAME, scroll = SCROLLS_PHYS,
    extra = { best = { 22788 }, budget = false, skip = "Nice to have, not needed on farm." },
  },
  ["WARRIOR:Protection"] = TANK_WAR,
  ["SHAMAN:Enhancement"] = {
    flask = { best = { 22854 }, budget = { 22824, 32067 } },
    food = { best = { 27658 }, budget = { 27655 } },
    potion = HASTE_SAME, scroll = SCROLLS_PHYS,
    extra = { best = { 22788 }, budget = false, skip = "Nice to have, not needed on farm." },
  },
  ["SHAMAN:Elemental"] = caster(22861, 28103),
  ["SHAMAN:Restoration"] = healer(22840),
  ["ROGUE:Assassination"] = ROGUE, ["ROGUE:Combat"] = ROGUE, ["ROGUE:Subtlety"] = ROGUE,
  ["HUNTER:Beast Mastery"] = HUNTER, ["HUNTER:Marksmanship"] = HUNTER, ["HUNTER:Survival"] = HUNTER,
  ["DRUID:Feral (Cat)"] = {
    flask = { best = { 22831, 32067 }, budget = "same", sameWhy = "Elixirs beat a flask for a cat: mana to shift." },
    food = { best = { 27664 }, budget = { 27659 } },
    weapon = { best = { 28421 }, budget = false, skip = "Little gain in cat form.", why = WF_WHY },
    potion = HASTE_SAME, scroll = SCROLLS_PHYS,
    extra = { best = { 12662 }, budget = false, skip = SKIP_RUNE, why = "Mana for powershifting." },
  },
  ["DRUID:Feral (Bear)"] = {
    flask = { best = { 22851 }, budget = { 22831, 22834 } },
    food = TANK_FOOD, potion = TANK_POT, scroll = TANK_SCROLL,
  },
  ["DRUID:Balance"] = caster(22861, 28103),
  ["DRUID:Restoration"] = healer(32067),
  ["PRIEST:Shadow"] = caster(22866, 22835),
  ["PRIEST:Holy"] = healer(32067),
  ["PRIEST:Discipline"] = healer(32067),
  ["MAGE:Arcane"] = {
    flask = { best = { 22861 }, budget = { 28103, 32067 } },
    food = CASTER_FOOD, weapon = CASTER_OIL,
    potion = { best = { 22832 }, budget = "same", sameWhy = "Mana is the fight for Arcane." },
    extra = CASTER_RUNE,
  },
  ["MAGE:Fire"] = caster(22866, 22833, nil,
    { best = { 22788 }, budget = false, skip = "Nice to have, not needed on farm.", why = "Fire damage for a minute." }),
  ["MAGE:Frost"] = caster(22866, 22827),
  ["WARLOCK:Affliction"] = caster(22866, 22835, 32062),
  ["WARLOCK:Demonology"] = caster(22866, 22835, 32062),
  ["WARLOCK:Destruction"] = caster(22866, 22835, 32062),
}
C.KITS["WARRIOR:Arms"] = C.KITS["WARRIOR:Fury"]
