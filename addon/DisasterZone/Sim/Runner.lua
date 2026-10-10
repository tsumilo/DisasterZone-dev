if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Runner.lua", ...) then return end -- DisasterZone: Sim/Runner.lua
-- ns.SimRunner: the gear sim in the game. Gear sets from what is equipped (gems read off the item links) and from
-- My BiS (picks + gem setups); talents, race and professions of the player; and runs: several sets simmed
-- side by side on the same random rolls (iteration i of every set uses the same seed), a slice per frame so the
-- game keeps its frame rate, paused while in combat.
local _, ns = ...
local S = ns.GearSim

local Runner = {}
ns.SimRunner = Runner

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

Runner.SPECS = { ["PALADIN:Retribution"] = true, ["WARRIOR:Fury"] = true, ["WARRIOR:Arms"] = true,
  ["SHAMAN:Enhancement"] = true, ["ROGUE:Combat"] = true, ["ROGUE:Assassination"] = true, ["ROGUE:Subtlety"] = true,
  ["DRUID:Feral (Cat)"] = true, ["SHAMAN:Elemental"] = true, ["PRIEST:Shadow"] = true,
  ["DRUID:Balance"] = true, ["MAGE:Arcane"] = true, ["MAGE:Fire"] = true, ["MAGE:Frost"] = true }
-- what the sim covers, for the texts that say so
Runner.COVERED = "Retribution Paladins, Fury / Arms Warriors, Enhancement / Elemental Shamans, Rogues, Feral / "
  .. "Balance Druids, Shadow Priests and Mages"
-- class file -> the sim's class
Runner.CLASS_NAMES = { PALADIN = "Paladin", WARRIOR = "Warrior", SHAMAN = "Shaman", ROGUE = "Rogue", DRUID = "Druid",
  PRIEST = "Priest", MAGE = "Mage" }
-- spec key -> what differs from the class: options, WoWSims' default reaction time (ms) and distance (yards)
Runner.SPEC_SETTINGS = {
  ["DRUID:Feral (Cat)"] = { options = { form = "Cat" }, reactionTimeMs = 250, distance = 0, buffs = "wowsims_cat",
    field = "feralCatDruid" },
  ["DRUID:Balance"] = { options = { form = "Moonkin" }, distance = 20, buffs = "wowsims_balance", field = "balanceDruid" },
  -- wsOptions: the class options of the WoWSims export
  ["PRIEST:Shadow"] = { options = { preShadowform = true }, distance = 20, channelClipDelayMs = 100,
    buffs = "wowsims_spriest", field = "dpsPriest", wsOptions = { preShadowform = true } },
  ["SHAMAN:Elemental"] = { options = { elemental = true, imbueMh = "NoImbue", imbueOh = "NoImbue", shieldProcrate = 0 },
    distance = 20, buffs = "wowsims_ele", field = "elementalShaman" },
  -- WoWSims ships an Arcane list only: Fire and Frost run our own (dev/data/apl), checked in both sims
  ["MAGE:Arcane"] = { options = { defaultMageArmor = "MageArmor" }, distance = 20, buffs = "wowsims_mage", field = "mage",
    wsOptions = { defaultMageArmor = "MageArmorMageArmor" } },
  ["MAGE:Fire"] = { options = { defaultMageArmor = "MoltenArmor" }, distance = 20, buffs = "wowsims_mage", field = "mage",
    wsOptions = { defaultMageArmor = "MageArmorMoltenArmor" } },
  ["MAGE:Frost"] = { options = { defaultMageArmor = "MoltenArmor" }, distance = 20, buffs = "wowsims_mage", field = "mage",
    wsOptions = { defaultMageArmor = "MageArmorMoltenArmor" } },
}
-- WoWSims' class options (dps/presets.ts DefaultOptions)
Runner.CLASS_OPTIONS = {
  Shaman = { imbueMh = "WindfuryWeapon", imbueOh = "WindfuryWeapon", syncType = "DelayOffhandSwings", shieldProcrate = 0 },
  Warrior = { queueDelay = 0.25, startingRage = 50, defaultShout = "Battle", defaultStance = "Berserker",
    hasBsT2 = true, stanceSnapshot = true },
}
Runner.DEFAULT_ITERATIONS = 1000
Runner.FRAME_BUDGET_MS = 12

-- ---------------------------------------------------------------------------------------------------------------
-- Settings: buffs, fight length, boss type
-- ---------------------------------------------------------------------------------------------------------------
Runner.BUFFS = {
  { key = "raid25", text = "25-man buffs",
    tipShaman = "WoWSims' Enhancement raid setup: Bloodlust, Ferocious Inspiration, Braided Eternium Chain, Leader of the "
      .. "Pack, Battle Shout, Kings and Might, Gift of the Wild, Fortitude, Arcane Intellect, Sunder / Expose Armor, Faerie "
      .. "Fire, Curses of Recklessness and the Elements, Misery, Blood Frenzy, Mangle, Gift of Arthas, Hunter's Mark, "
      .. "Expose Weakness, Judgements of the Crusader and Wisdom; flask, food, scrolls, Haste Potion, Flame Cap, your own "
      .. "drums, explosives (Engineering). You drop your own totems and Fire Elemental.",
    tipBalance = "WoWSims' Balance raid setup: Bloodlust, drums, Totem of Wrath, Wrath of Air, Chain of the Twilight "
      .. "Owl, Eye of the Night, Kings and Wisdom, Gift of the Wild, Fortitude, Arcane Intellect, Divine Spirit, a Shadow "
      .. "Priest's mana, Curse of the Elements, Misery, Judgement of Wisdom and the melee debuffs; Flask of Blinding "
      .. "Light, Blackened Basilisk, Brilliant Wizard Oil, Super Mana Potion, Demonic Rune. You bring your own Moonkin "
      .. "Aura and Faerie Fire.",
    tipPriest = "WoWSims' Shadow Priest raid setup: Bloodlust, drums, Mana Spring and Wrath of Air, Chain of the Twilight "
      .. "Owl, Eye of the Night, Kings and Wisdom, Gift of the Wild, Fortitude, Arcane Intellect, Divine Spirit, Curse of "
      .. "the Elements, Improved Shadow Bolt (72% uptime), Judgements of the Crusader and Wisdom, Faerie Fire, Expose "
      .. "Armor; Flask of Pure Death, Blackened Basilisk, Destruction Potion, Demonic Rune. You bring your own Misery, "
      .. "Shadow Weaving, Vampiric Touch and Shadowfiend.",
    tipMage = "WoWSims' Mage raid setup: Bloodlust, drums, Mana Spring, Mana Tide and Wrath of Air, Kings, Wisdom and "
      .. "Salvation, Gift of the Wild, Fortitude, Arcane Brilliance, Divine Spirit, Shadow Protection, Innervate, a Shadow "
      .. "Priest's mana, Curse of the Elements, Misery, Judgements of the Crusader and Wisdom, Improved Shadow Bolt (72% "
      .. "uptime); Adept's Elixir, Elixir of Draenic Wisdom, Blackened Basilisk, Brilliant Wizard Oil, Super Mana Potion. "
      .. "You bring your own mana gems, Evocation, Improved Scorch, Winter's Chill and Water Elemental.",
    tipElemental = "WoWSims' Elemental raid setup: Bloodlust, drums, Moonkin Aura, Chain of the Twilight Owl, Eye of the "
      .. "Night, Kings and Wisdom, Gift of the Wild, Fortitude, Arcane Intellect, Divine Spirit, a Shadow Priest's mana, "
      .. "Curse of the Elements, Misery, Judgement of Wisdom and the melee debuffs; Flask of Blinding Light, Blackened "
      .. "Basilisk, Brilliant Wizard Oil, Destruction Potion, Demonic Rune. You drop your own Totem of Wrath, Wrath of Air "
      .. "and Mana Spring.",
    tipRogue = "WoWSims' Rogue raid setup: Bloodlust, drums, Windfury and Grace of Air (twisted), Strength of Earth, "
      .. "Battle Shout, Leader of the Pack, Ferocious Inspiration, Unleashed Rage, Kings and Might, Gift of the Wild, "
      .. "Sunder Armor, Faerie Fire, Curse of Recklessness, Blood Frenzy, Mangle, Misery, Gift of Arthas, Hunter's Mark, "
      .. "Expose Weakness, Judgement of the Crusader; Elixirs of Major Agility and Fortitude, Spicy Hot Talbuk, Haste "
      .. "Potion, Thistle Tea, Deadly Poison on the off hand, explosives (Engineering). You keep up your own Expose Armor.",
    tipDruid = "WoWSims' Feral raid setup: Bloodlust, drums, Grace of Air (twisted), Strength of Earth, Battle Shout, "
      .. "Ferocious Inspiration, Unleashed Rage, Kings and Might, Gift of the Wild, Fortitude, Arcane Intellect, Divine "
      .. "Spirit, Sunder / Expose Armor, Faerie Fire, Curse of Recklessness, Blood Frenzy, Misery, Gift of Arthas, "
      .. "Hunter's Mark, Expose Weakness, Judgements of the Crusader and Wisdom; Elixirs of Major Agility and Draenic "
      .. "Wisdom, Grilled Mudfish, scrolls, Haste Potion, Demonic Rune, weightstone, explosives (Engineering). You bring "
      .. "your own Leader of the Pack; cats don't proc Windfury Totem.",
    tipWarrior = "WoWSims' Warrior raid setup: Bloodlust, drums, Windfury and Grace of Air (twisted), Strength of Earth, "
      .. "Leader of the Pack, Ferocious Inspiration, Braided Eternium Chain, Unleashed Rage, Kings and Might, Gift of the "
      .. "Wild, Fortitude, Sunder / Expose Armor, Faerie Fire, Curse of Recklessness, Blood Frenzy, Mangle, Gift of "
      .. "Arthas, Hunter's Mark, Expose Weakness; flask, food, scrolls, Haste Potion, Flame Cap, sharpening stone, "
      .. "explosives (Engineering). You shout yourself.",
    tip = "WoWSims' Retribution raid setup: Bloodlust, drums, Windfury and Grace of Air (twisted), Strength of Earth, "
      .. "Battle Shout, Leader of the Pack, Unleashed Rage, all blessings and raid buffs, Sunder / Expose Armor, Faerie "
      .. "Fire, Curse of Recklessness, Blood Frenzy, Misery, Hunter's Mark, Expose Weakness, Judgements of the "
      .. "Crusader and Wisdom; flask, food, scrolls, Haste Potion, Demonic Rune and explosives (Engineering)." },
  { key = "raid10", text = "10-man buffs",
    tip = "A Karazhan-style group: Kings, Might, Wisdom, Gift of the Wild, Fortitude, Arcane Intellect, Battle Shout, "
      .. "Windfury and Strength of Earth totems, Bloodlust, Sunder Armor, Faerie Fire, Curse of Recklessness, "
      .. "Judgement of Wisdom; flask, food, Haste Potion." },
  { key = "solo", text = "No buffs",
    tip = "Only what you bring yourself: flask, food and a Haste Potion; no raid buffs or debuffs." },
}
Runner.DURATIONS = { 60, 120, 180, 240, 300, 420 }
Runner.MOB_TYPES = {
  { key = "Mechanical", text = "Mechanical", tip = "No bonus from Crusade or Exorcism (WoWSims' default boss)." },
  { key = "Demon", text = "Demon", tip = "Crusade and Exorcism apply (Magtheridon, Illidan...)." },
  { key = "Undead", text = "Undead", tip = "Crusade and Exorcism apply." },
  { key = "Humanoid", text = "Humanoid", tip = "Crusade applies." },
  { key = "Elemental", text = "Elemental", tip = "Crusade applies." },
  { key = "Giant", text = "Giant", tip = "No bonus from Crusade." },
  { key = "Dragonkin", text = "Dragonkin", tip = "No bonus from Crusade." },
  { key = "Beast", text = "Beast", tip = "No bonus from Crusade." },
}

local RAID10 = {
  raid = { bloodlust = true, arcaneBrilliance = true, giftOfTheWild = 2, powerWordFortitude = 1 },
  party = { battleShout = 1, windfuryTotem = 1, strengthOfEarthTotem = 1, manaSpringTotem = 1 },
  individual = { blessingOfKings = true, blessingOfWisdom = 1, blessingOfMight = 1 },
  debuffs = { sunderArmor = true, faerieFire = 1, curseOfRecklessness = true, judgementOfWisdom = true },
  consumables = { potId = 22838, flaskId = 22854, foodId = 27658 },
}
local SOLO = {
  raid = {}, party = {}, individual = {}, debuffs = {},
  consumables = { potId = 22838, flaskId = 22854, foodId = 27658 },
}

-- A Warrior shouts himself: the group's Battle Shout goes (WoWSims would let his own win anyway).
local function WithoutShout(cfg)
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end
  local party = {}
  for k, v in pairs(cfg.party or {}) do if k ~= "battleShout" then party[k] = v end end
  out.party = party
  return out
end

-- WoWSims' three setups for the class: "raid25" | "raid10" | "solo".
-- A Shaman drops his own totems: the group's go (in WoWSims the shaman's own would take their place).
local SHAMAN_OWN = { windfuryTotem = true, graceOfAirTotem = true, strengthOfEarthTotem = true, manaSpringTotem = true,
  totemTwisting = true }
-- An Elemental Shaman drops Totem of Wrath, Wrath of Air and Mana Spring himself.
local ELE_OWN = { totemOfWrath = true, wrathOfAirTotem = true, manaSpringTotem = true }
local function WithoutTotems(cfg, own)
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end
  local party, ind = {}, {}
  for k, v in pairs(cfg.party or {}) do if not (own or SHAMAN_OWN)[k] then party[k] = v end end
  for k, v in pairs(cfg.individual or {}) do if k ~= "unleashedRage" then ind[k] = v end end
  out.party, out.individual = party, ind
  return out
end

-- A Rogue always has poisons on (Deadly Poison on the off hand, WoWSims' default, unless the setup names its own)
-- and keeps up his own Expose Armor: the group's goes.
-- A Shadow Priest's own Vampiric Touch feeds himself: no other shadow priest's mana (his Misery is his own too:
-- Buffs.lua S.ApplyDebuffs).
local function PriestOwn(cfg)
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end
  local ind = {}
  for k, v in pairs(cfg.individual or {}) do if k ~= "shadowPriestDps" then ind[k] = v end end
  out.individual = ind
  return out
end

local function RogueOwn(cfg)
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end
  local c = cfg.consumables or {}
  if (c.mhImbueId or 0) == 0 and (c.ohImbueId or 0) == 0 then
    local cons = {}
    for k, v in pairs(c) do cons[k] = v end
    cons.ohImbueId = 27186
    out.consumables = cons
  end
  local debuffs = {}
  for k, v in pairs(cfg.debuffs or {}) do if k ~= "exposeArmor" then debuffs[k] = v end end
  out.debuffs = debuffs
  return out
end

function Runner:BaseConfig(key)
  local cls = self:Class()
  if key == "raid10" then return RAID10 end
  if key == "solo" then return SOLO end
  local ss = self.SPEC_SETTINGS[self:SpecKey()]
  if ss and ss.buffs then return S.BUFF_PRESETS[ss.buffs] end
  if cls == "WARRIOR" then return S.BUFF_PRESETS.wowsims_warrior end
  if cls == "SHAMAN" then return S.BUFF_PRESETS.wowsims_enh end
  if cls == "ROGUE" then return S.BUFF_PRESETS.wowsims_rogue end
  return S.BUFF_PRESETS.wowsims_ret
end

function Runner:IsBaseKey(key)
  return key == "raid25" or key == "raid10" or key == "solo"
end

-- The buff config of a buffs setting: WoWSims' three, a preset of mine ("p:<id>") or a team lineup ("t:<team>:<ln>",
-- ns.SimBuffs). A preset or lineup that is gone falls back to 25-man buffs.
function Runner:BuffConfig(key)
  local cfg
  if self:IsBaseKey(key) then
    cfg = self:BaseConfig(key)
  else
    local SB = ns.SimBuffs
    cfg = SB and (SB:Resolve(key, self:Class(), self:BaseConfig("raid25"))) or nil
    cfg = cfg or self:BaseConfig("raid25")
  end
  if self:Class() == "WARRIOR" then cfg = WithoutShout(cfg) end
  if self:Class() == "SHAMAN" then cfg = WithoutTotems(cfg, self:Spec() == "Elemental" and ELE_OWN or nil) end
  if self:Class() == "ROGUE" then cfg = RogueOwn(cfg) end
  if self:Class() == "PRIEST" then cfg = PriestOwn(cfg) end
  return cfg
end

-- The name the card shows for a buffs setting, and whether it still exists.
function Runner:BuffName(key)
  for _, b in ipairs(self.BUFFS) do if b.key == key then return b.text, true end end
  local SB = ns.SimBuffs
  local cfg, _, name = nil, nil, nil
  if SB then cfg, _, name = SB:Resolve(key, self:Class(), self:BaseConfig("raid25")) end
  if cfg then return name, true end
  return self.BUFFS[1].text, false
end

-- ---------------------------------------------------------------------------------------------------------------
-- The player
-- ---------------------------------------------------------------------------------------------------------------
function Runner:Race()
  local _, file = UnitRace("player")
  if file == "Scourge" then return "Undead" end
  return file or "Human"
end

function Runner:Class()
  local _, cls = UnitClass("player")
  return cls
end

function Runner:Professions()
  local set = ns.Gems and ns.Gems.ProfessionSet and ns.Gems:ProfessionSet() or {}
  local out = {}
  for name in pairs(set) do out[#out + 1] = name end
  return out
end

-- The talent string in Wowhead / WoWSims order (each tree by row, then column).
function Runner:TalentString()
  if not GetNumTalentTabs then return nil end
  local trees = {}
  for tab = 1, (GetNumTalentTabs() or 0) do
    local list = {}
    for i = 1, (GetNumTalents(tab) or 0) do
      local _, _, tier, column, rank = GetTalentInfo(tab, i)
      list[#list + 1] = { tier = tier or 0, column = column or 0, rank = rank or 0 }
    end
    table.sort(list, function(a, b) if a.tier ~= b.tier then return a.tier < b.tier end return a.column < b.column end)
    local s = {}
    for i, t in ipairs(list) do s[i] = tostring(t.rank) end
    trees[tab] = (table.concat(s):gsub("0+$", ""))
  end
  return table.concat(trees, "-")
end

-- WoWSims' standard Retribution build, for BiS lists and when talents can't be read.
Runner.DEFAULT_TALENTS = {
  ["PALADIN:Retribution"] = "5-053201-0523005120033125331051",
  ["WARRIOR:Fury"] = "3400502130201-05050005505012050115",
  ["WARRIOR:Arms"] = "32005011352010500221-0550000500521203",
  ["SHAMAN:Enhancement"] = "03-500502210501133531151-50005301",
  ["ROGUE:Combat"] = "0053201252-023305200005015002321151",
  -- no WoWSims preset for these two: standard Mutilate (41/20/0) and Hemorrhage builds, checked against WoWSims
  ["ROGUE:Assassination"] = "005323105500102521051-003305000054",
  ["ROGUE:Subtlety"] = "0053201-023305000005015-0500001000301210500050",
  ["DRUID:Feral (Cat)"] = "-503032132322105301251-05503301",
  ["SHAMAN:Elemental"] = "55003105100213351051--05105301005",
  ["PRIEST:Shadow"] = "500230013--503250510240103051451",
  ["DRUID:Balance"] = "510022312503135231351--520033",
  ["MAGE:Arcane"] = "2500052300030150330125--053500031003001",
  -- no WoWSims preset for these two: standard Fire (10/48/3) and Frost (10/0/51) builds, checked against WoWSims
  ["MAGE:Fire"] = "2-505202012303331053125-043000001",
  ["MAGE:Frost"] = "230005--0535000310035310251551",
}

-- ---------------------------------------------------------------------------------------------------------------
-- Gear sets: { [sid] = { id = itemID, enchant = effectID, gems = { gem item IDs } } } (sid = ns.SLOTS order)
-- ---------------------------------------------------------------------------------------------------------------
local function ParseLink(link)
  if type(link) ~= "string" then return nil end
  local id, enchant = link:match("item:(%d+):(%d*)")
  id = tonumber(id)
  if not id then return nil end
  local e = { id = id, enchant = tonumber(enchant) or 0, gems = {} }
  -- item:id:enchant:gem1:gem2:gem3:gem4:suffix: a random suffix ("of the Bandit") is a negative id, as in WoWSims
  local suffix = tonumber(link:match("item:%d+:%-?%d*:%-?%d*:%-?%d*:%-?%d*:%-?%d*:(%-?%d+)") or "")
  if suffix and suffix ~= 0 then e.randomSuffix = suffix end
  if GetItemGem then
    for i = 1, 4 do
      local _, gemLink = GetItemGem(link, i)
      local gid = gemLink and tonumber(gemLink:match("item:(%d+)"))
      if gid then e.gems[i] = gid end
    end
  end
  return e
end
Runner.ParseLink = ParseLink

function Runner:EquippedSet()
  local set = {}
  for sid, s in ipairs(ns.SLOTS or {}) do
    local link = GetInventoryItemLink("player", s.invSlot)
    local e = ParseLink(link)
    if e then set[sid] = e end
  end
  return set
end

function Runner:BiSSet(phase, list)
  local BiS = ns.BiS
  local set = {}
  if not BiS then return set end
  for sid = 1, #(ns.SLOTS or {}) do
    local main = BiS:GetSlot(phase, sid, list)
    if main and main ~= 0 then
      local enchant, gems = BiS:GetGemSetup(main, list)
      local g = {}
      for i, v in pairs(gems or {}) do if v and v ~= 0 then g[i] = v end end
      set[sid] = { id = main, enchant = enchant or 0, gems = g }
    end
  end
  return set
end

function Runner:CopySet(set)
  local out = {}
  for sid, e in pairs(set or {}) do
    local g = {}
    for i, v in pairs(e.gems or {}) do g[i] = v end
    out[sid] = { id = e.id, enchant = e.enchant, gems = g, randomSuffix = e.randomSuffix }
  end
  return out
end

function Runner:SameEntry(a, b)
  if not a or not b then return (a == nil) == (b == nil) end
  if a.id ~= b.id or (a.enchant or 0) ~= (b.enchant or 0) or (a.randomSuffix or 0) ~= (b.randomSuffix or 0) then return false end
  for i = 1, 4 do if ((a.gems or {})[i] or 0) ~= ((b.gems or {})[i] or 0) then return false end end
  return true
end

-- Gems and an enchant for an item put into a set by hand: the spec guide's suggestion (as My BiS fills them), the
-- slot's old enchant when it still fits.
function Runner:FillEntry(itemID, sid, old)
  local e = { id = itemID, enchant = 0, gems = {} }
  local G = ns.Gems
  if not G then return e end
  local guide = G.GuideFor and G:GuideFor({ cl = self:Class(), sp = (ns.BiS and ns.BiS:GetSpec()) or "Retribution" })
  local phase = (ns.MyBiS and ns.MyBiS.GetPhase and ns.MyBiS:GetPhase()) or 1
  local ok, enchant, gems = pcall(G.Suggest, G, itemID, sid, guide, phase)
  if ok then
    e.enchant = tonumber(enchant) or 0
    for i, v in pairs(gems or {}) do if v and v ~= 0 then e.gems[i] = v end end
  end
  if old and (old.enchant or 0) ~= 0 and G.EnchantFitsItem and G:EnchantFitsItem(old.enchant, itemID) then
    e.enchant = old.enchant
  end
  return e
end

-- A My BiS pick with its gem setup from the list (else suggested like a new item).
function Runner:FillEntryFromBiS(itemID, phase, list, sid)
  local BiS = ns.BiS
  if BiS then
    local enchant, gems = BiS:GetGemSetup(itemID, list)
    local g, any = {}, (enchant or 0) ~= 0
    for i, v in pairs(gems or {}) do if v and v ~= 0 then g[i] = v; any = true end end
    if any then return { id = itemID, enchant = enchant or 0, gems = g } end
  end
  return self:FillEntry(itemID, sid)
end

-- Whether the head's meta gem is active (its colour rule) in a set.
-- Keeps the set's meta gem on: when the gems just put into `entry` (in slot sid; free = { [socket] = true }) would
-- switch it off, those sockets get the cheapest gems that keep its rule (Gems:MeetMetaRule); others are left alone.
function Runner:KeepMetaActive(set, sid, entry, free)
  local G = ns.Gems
  if not (G and G.MeetMetaRule and entry and next(free or {})) then return entry end
  local trial = self:CopySet(set)
  trial[sid] = entry
  if self:MetaActive(trial) then return entry end
  local guide = G.GuideFor and G:GuideFor({ cl = self:Class(), sp = self:Spec() })
  if not guide then return entry end
  local phase = (ns.MyBiS and ns.MyBiS.GetPhase and ns.MyBiS:GetPhase()) or 1
  local setups, frees = {}, {}
  for s, e in pairs(trial) do
    if e.id and not setups[e.id] then
      local g = {}
      for i, v in pairs(e.gems or {}) do g[i] = v end
      setups[e.id] = { gems = g }
    end
  end
  frees[entry.id] = free
  local ok = G:MeetMetaRule(setups, frees, G:GuideData(guide, phase), phase,
    G.ProfessionSet and G:ProfessionSet() or {})
  if ok then
    local out = self:CopySet({ entry })[1]
    for i in pairs(free) do out.gems[i] = setups[entry.id].gems[i] end
    return out
  end
  return entry
end

-- The set's meta gem when its rule isn't met: gemID, what it needs (text). nil when it is on (or there is none).
function Runner:MetaOff(set)
  local G = ns.Gems
  local head = set[1]
  if not (G and head and head.gems) or self:MetaActive(set) then return nil end
  for _, gid in pairs(head.gems) do
    local g = G:Gem(gid)
    if g and g.color == "M" then
      local _, words = G:MetaState(gid, {})
      return gid, words
    end
  end
  return nil
end

function Runner:MetaActive(set)
  local G = ns.Gems
  local head = set[1]
  if not (G and head and head.gems) then return true end
  local meta
  for _, gid in pairs(head.gems) do
    local g = G:Gem(gid)
    if g and g.color == "M" then meta = gid end
  end
  if not meta then return true end
  local counts = { R = 0, Y = 0, B = 0 }
  local MIX = { R = "R", Y = "Y", B = "B", O = "RY", P = "RB", G = "YB", X = "RYB" }
  for _, e in pairs(set) do
    for _, gid in pairs(e.gems or {}) do
      local g = G:Gem(gid)
      local c = g and MIX[g.color]
      if c then for ch in c:gmatch(".") do counts[ch] = counts[ch] + 1 end end
    end
  end
  local ok = G:MetaState(meta, counts)
  return ok and true or false
end

-- Items of a set the sim has no data for (left out of the run: their stats and effects).
function Runner:UnknownItems(set)
  local db = self:DB()
  local out = {}
  for sid, e in pairs(set) do
    if e.id and not db.items[e.id] then out[#out + 1] = sid end
  end
  return out
end

function Runner:DB()
  self.db = self.db or S.GameDB()
  return self.db
end

-- The spec of the list My BiS shows (the off-spec list's when that one is open).
function Runner:Spec()
  local list = (ns.MyBiS and ns.MyBiS.GetList and ns.MyBiS:GetList() == "os") and "os" or nil
  return (ns.BiS and ns.BiS:GetSpec(list)) or ""
end

function Runner:SpecKey()
  return (self:Class() or "") .. ":" .. self:Spec()
end

-- Your own talents when you are specced into the spec being simmed, else WoWSims' standard build for it.
function Runner:Talents()
  local spec = self:Spec()
  if ns.BiS and ns.BiS.DetectSpec and ns.BiS:DetectSpec() == spec then
    local t = self:TalentString()
    if t and t:find("[1-5]") then return t, true end
  end
  return self.DEFAULT_TALENTS[self:SpecKey()], false
end

function Runner:IsSupported(key)
  return self.SPECS[key or self:SpecKey()] and true or false
end

-- ---------------------------------------------------------------------------------------------------------------
-- Scenarios and runs
-- ---------------------------------------------------------------------------------------------------------------
-- cons: the consumables to sim instead of the buffs setting's own (My BiS > Consumables, Core/Kit.lua).
function Runner:Scenario(set, settings, cons)
  local gear = {}
  local db = self:DB()
  local ss = self.SPEC_SETTINGS[self:SpecKey()] or {}
  for sid = 1, 17 do
    local e = set[sid]
    if e and e.id and db.items[e.id] then
      gear[sid] = { id = e.id, enchant = (e.enchant ~= 0) and e.enchant or nil, gems = e.gems, randomSuffix = e.randomSuffix }
    end
  end
  local buffs = self:BuffConfig(settings.buffs)
  local class = self.CLASS_NAMES[self:Class() or ""] or "Paladin"
  return {
    race = self:Race(), class = class, classOptions = ss.options or self.CLASS_OPTIONS[class], talents = settings.talents,
    gear = gear,
    metaActive = self:MetaActive(set),
    buffs = buffs, consumables = cons or buffs.consumables, professions = settings.professions or self:Professions(),
    duration = settings.duration or 180, seed = settings.seed or 101, mobType = settings.mobType or "Mechanical",
    reactionTimeMs = ss.reactionTimeMs or 0, distance = ss.distance or 5, channelClipDelayMs = ss.channelClipDelayMs or 0,
  }
end

local clock = debugprofilestop or function() return os.clock() * 1000 end

local function InCombat()
  return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player"))
end

-- Finished sets, so a set is never simmed twice: iteration i of a set depends only on its scenario, the seed and i
-- (Sim:RunOnce seeds every iteration), so the same scenario, seed and fight count give exactly the same result.
-- One seed per session keeps that true from run to run; the least recently used go first past CACHE_SIZE.
Runner.CACHE_SIZE = 40
Runner.cache, Runner.cacheOrder = {}, {}

function Runner:SessionSeed()
  self.seed = self.seed or floor((GetTime and GetTime() or os.time()) * 1000) % 1000000
  return self.seed
end

-- A table as text with its keys in order (nil if it holds anything but numbers, strings, booleans and tables).
local function Serialize(v, out)
  local t = type(v)
  if t == "number" then out[#out + 1] = ("%.17g"):format(v)
  elseif t == "string" then out[#out + 1] = ("%q"):format(v)
  elseif t == "boolean" then out[#out + 1] = v and "T" or "F"
  elseif t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return a < b
    end)
    out[#out + 1] = "{"
    for _, k in ipairs(keys) do
      if not Serialize(k, out) then return false end
      out[#out + 1] = "="
      if not Serialize(v[k], out) then return false end
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  else
    return false
  end
  return true
end

function Runner:CacheKey(scenario, n)
  local out = { self:SpecKey(), "|", tostring(n), "|" }
  if not Serialize(scenario, out) then return nil end
  return table.concat(out)
end

-- A cached result (moved to the back of the line: the sets in use stay).
function Runner:CacheGet(key)
  local v = key and self.cache[key]
  if not v then return nil end
  local order = self.cacheOrder
  for i = 1, #order do
    if order[i] == key then table.remove(order, i) break end
  end
  order[#order + 1] = key
  return v
end

function Runner:CachePut(key, summary)
  if not key or self.cache[key] then return end
  self.cache[key] = summary
  local order = self.cacheOrder
  order[#order + 1] = key
  while #order > self.CACHE_SIZE do
    self.cache[table.remove(order, 1)] = nil
  end
end

function Runner:ClearCache()
  self.cache, self.cacheOrder = {}, {}
end

-- jobs: { { key = any, set = gear set, cons = consumables (optional) }, ... }; opts: { iterations, settings, onProgress(done, total, paused),
-- onDone(results), onCancel() }. results[key] = summary (S.Summarize) + iterDps; results.pairs(a, b) -> mean diff, stderr.
-- Sets simmed before (same scenario, seed and fight count) and sets listed twice are not simmed again.
function Runner:Start(jobs, opts)
  self:Cancel()
  local settings = opts.settings or {}
  settings.seed = settings.seed or self:SessionSeed()
  local apl = ns.Data and ns.Data.SimAPL and ns.Data.SimAPL[self:SpecKey()]
  if not apl then return false, "No rotation for this spec yet." end
  local n = opts.iterations or self.DEFAULT_ITERATIONS
  local all, sims, byCache = {}, {}, {}
  local okAll, err = pcall(function()
    for i, job in ipairs(jobs) do
      local scenario = self:Scenario(job.set, settings, job.cons)
      if job.bonus then scenario.bonusStats = job.bonus end
      local ck = self:CacheKey(scenario, n)
      local r = { key = job.key, cacheKey = ck }
      all[i] = r
      local hit = self:CacheGet(ck)
      if hit then
        r.summary = hit
      elseif ck and byCache[ck] then
        r.same = byCache[ck]
      else
        r.sim, r.p = S.NewScenario(scenario, self:DB(), apl)
        sims[#sims + 1] = r
        if ck then byCache[ck] = r end
      end
    end
  end)
  if not okAll then return false, tostring(err) end
  local run = { jobs = all, sims = sims, n = n, done = 0, opts = opts, cancelled = false, nextJob = 1, nextIter = 1 }
  self.run = run
  local total = n * #sims
  local frame = self.frame or CreateFrame("Frame")
  self.frame = frame
  frame:SetScript("OnUpdate", function()
    if run.cancelled then frame:SetScript("OnUpdate", nil) return end
    if #sims > 0 and run.nextIter <= n then
      if InCombat() then
        if opts.onProgress then opts.onProgress(run.done, total, true) end
        return
      end
      local t0 = clock()
      local ok, e = pcall(function()
        -- at least one fight a frame, then as many as fit in the budget
        repeat
          local r = sims[run.nextJob]
          r.sim:RunOnce(run.nextIter)
          run.done = run.done + 1
          run.nextJob = run.nextJob + 1
          if run.nextJob > #sims then run.nextJob, run.nextIter = 1, run.nextIter + 1 end
        until run.nextIter > n or clock() - t0 >= self.FRAME_BUDGET_MS
      end)
      if not ok then
        frame:SetScript("OnUpdate", nil)
        self.run = nil
        if opts.onDone then opts.onDone(nil, tostring(e)) end
        return
      end
      if opts.onProgress then opts.onProgress(run.done, total, false) end
    end
    if #sims == 0 or run.nextIter > n then
      frame:SetScript("OnUpdate", nil)
      self.run = nil
      if opts.onDone then opts.onDone(self:Results(all)) end
    end
  end)
  return true
end

-- Stops the run (a new Start stops the one before): its owner hears it through opts.onCancel.
function Runner:Cancel()
  local run = self.run
  if run then run.cancelled = true end
  self.run = nil
  if self.frame then self.frame:SetScript("OnUpdate", nil) end
  if run and run.opts.onCancel then run.opts.onCancel() end
end

function Runner:IsRunning() return self.run ~= nil end

-- The fights' DPS so far of the running job `key` (a cached or repeated set: its whole list), nil without a run.
function Runner:LiveList(key)
  local run = self.run
  if not run then return nil end
  for _, r in ipairs(run.jobs) do
    if r.key == key then
      local src = r.same or r
      if src.p then return src.p.metrics.iterDps end
      if src.summary then return src.summary.iterDps end
      return nil
    end
  end
end

-- Finished runs -> results by key; a paired difference between two keys (same iterations, same seeds).
function Runner:Results(runs)
  local out = {}
  for _, r in ipairs(runs) do
    if r.sim then
      local s = S.Summarize(r.sim, r.p)
      s.iterDps = r.p.metrics.iterDps
      s.stats = r.p.initialStats
      r.summary = s
      self:CachePut(r.cacheKey, s)
    end
  end
  out.cached = {}
  for _, r in ipairs(runs) do
    out[r.key] = r.summary or r.same.summary
    if not r.sim then out.cached[r.key] = true end
  end
  out.diff = function(a, b)
    local A, B = out[a], out[b]
    if not (A and B) then return nil end
    local n = min(#A.iterDps, #B.iterDps)
    local sum, sq = 0, 0
    for i = 1, n do
      local d = A.iterDps[i] - B.iterDps[i]
      sum, sq = sum + d, sq + d * d
    end
    local mean = sum / n
    local var = max(0, sq / n - mean * mean)
    return mean, sqrt(var / max(1, n - 1))
  end
  return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- Ability names for the breakdown (metrics keys -> text)
-- ---------------------------------------------------------------------------------------------------------------
Runner.ABILITIES = {
  melee = "Melee", windfury = "Windfury", soc_proc = "Seal of Command", judge_soc = "Judgement of Command",
  [31893] = "Seal of Blood", [31898] = "Judgement of Blood", [35395] = "Crusader Strike",
  [27138] = "Exorcism", [27180] = "Hammer of Wrath",
  ["item:23827"] = "Explosives", ["item:10646"] = "Explosives", ["item:23737"] = "Explosives", ["item:23736"] = "Explosives",
  -- Warriors
  melee_oh = "Off-hand melee", melee_12281 = "Sword Specialization", flame_cap = "Flame Cap",
  [29707] = "Heroic Strike", [25231] = "Cleave", [30335] = "Bloodthirst", [30330] = "Mortal Strike",
  [25236] = "Execute", ["1680:1"] = "Whirlwind", ["1680:2"] = "Whirlwind", [11585] = "Overpower", [25242] = "Slam",
  [12867] = "Deep Wounds", [25212] = "Hamstring", [25208] = "Rend",
  -- Shamans (the Fire Elemental's attacks count as one)
  ["25505:1"] = "Windfury Weapon", ["25505:2"] = "Windfury Weapon", ["17364:1"] = "Stormstrike",
  ["17364:2"] = "Stormstrike", [25454] = "Earth Shock", [25457] = "Flame Shock", ["25457:1"] = "Flame Shock",
  [25464] = "Frost Shock", [25537] = "Fire Nova Totem", [25550] = "Magma Totem", [25530] = "Searing Totem",
  [25489] = "Flametongue Weapon", windfury_totem = "Windfury Totem",
  pet_fire_elemental_melee = "Fire Elemental", pet_fire_elemental_13339 = "Fire Elemental",
  pet_fire_elemental_12470 = "Fire Elemental", pet_fire_elemental_13376 = "Fire Elemental",
  [25449] = "Lightning Bolt", ["25449:6"] = "Lightning Bolt", [25442] = "Chain Lightning", ["25442:6"] = "Chain Lightning",
  [37661] = "Lightning Capacitor",
  -- Priests
  [25387] = "Mind Flay", [25375] = "Mind Blast", [25372] = "Mind Blast", [25368] = "Shadow Word: Pain",
  [34917] = "Vampiric Touch", [32996] = "Shadow Word: Death", [25446] = "Starshards", [25467] = "Devouring Plague",
  pet_shadowfiend_melee = "Shadowfiend",
  -- Balance Druids
  [26986] = "Starfire", [9876] = "Starfire", [26988] = "Moonfire", ["26988:1"] = "Moonfire", [27013] = "Insect Swarm",
  [26985] = "Wrath", pet_treant_melee = "Treants",
  -- Mages
  [30451] = "Arcane Blast", [38699] = "Arcane Missiles", ["38699:1"] = "Arcane Missiles", [27072] = "Frostbolt",
  [27070] = "Fireball", ["27070:1"] = "Fireball", [12846] = "Ignite", [27079] = "Fire Blast", [27074] = "Scorch",
  [33938] = "Pyroblast", ["33938:1"] = "Pyroblast", [33933] = "Blast Wave", [33043] = "Dragon's Breath",
  pet_water_elemental_31707 = "Water Elemental",
  -- Rogues
  [26862] = "Sinister Strike", [26863] = "Backstab", [26864] = "Hemorrhage", [26865] = "Eviscerate",
  [26867] = "Rupture", [5938] = "Shiv", [27187] = "Deadly Poison", ["27187:1"] = "Deadly Poison",
  [26890] = "Instant Poison", ["26890:1"] = "Instant Poison", [27189] = "Wound Poison", ["27189:1"] = "Wound Poison",
  ["34413:1"] = "Mutilate", ["34413:2"] = "Mutilate", [14278] = "Ghostly Strike",
  -- Druids
  [27002] = "Shred", [27008] = "Rip", [24248] = "Ferocious Bite", [33983] = "Mangle", [27003] = "Rake",
  [27011] = "Faerie Fire",
}

-- The breakdown: { { name, dps } } merged by name, largest first.
function Runner:Breakdown(summary)
  local by, list = {}, {}
  for key, a in pairs(summary.abilities or {}) do
    if a.dps > 0 then
      local name = self.ABILITIES[key]
      if not name then
        local id = tonumber(key)
        name = (id and GetSpellInfo and GetSpellInfo(id)) or tostring(key)
      end
      if not by[name] then by[name] = { name = name, dps = 0 }; list[#list + 1] = by[name] end
      by[name].dps = by[name].dps + a.dps
    end
  end
  table.sort(list, function(x, y) return x.dps > y.dps end)
  return list
end

-- ---------------------------------------------------------------------------------------------------------------
-- WoWSims settings export: exactly what a run sims (gear, gems, enchants, race, talents, professions, buffs,
-- consumables, boss, rotation) as WoWSims' settings JSON (wowsims.com/tbc: Import > JSON), so both sims can be run
-- on the same input.
-- ---------------------------------------------------------------------------------------------------------------
local TRISTATE = {}
for _, k in ipairs({ "divineSpirit", "giftOfTheWild", "powerWordFortitude", "thorns", "manaSpringTotem",
  "leaderOfThePack", "battleShout", "strengthOfEarthTotem", "windfuryTotem", "graceOfAirTotem", "sanctityAura",
  "blessingOfWisdom", "blessingOfMight", "curseOfElements", "improvedSealOfTheCrusader", "huntersMark", "faerieFire",
  "exposeArmor", "demoralizingShout", "demoralizingRoar", "devotionAura", "retributionAura", "concentrationAura",
  "moonkinAura", "wrathOfAirTotem", "bloodPact", "commandingShout", "thunderClap" }) do TRISTATE[k] = true end
local TRI_NAMES = { [0] = "TristateEffectMissing", [1] = "TristateEffectRegular", [2] = "TristateEffectImproved" }

-- fields that are lists in WoWSims' protos (an empty one must stay [], an empty message {})
local LISTS = {}
for _, k in ipairs({ "vals", "actions", "groups", "priorityList", "prepullActions", "valueVariables", "variables",
  "items", "gems", "targets", "potions", "conjuredItems", "stats", "cooldowns" }) do LISTS[k] = true end

local function JStr(s)
  return '"' .. tostring(s):gsub('[%c"\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\n" end
    return ("\u%04x"):format(c:byte())
  end) .. '"'
end

local function Encode(v, key, out)
  local tv = type(v)
  if tv == "table" then
    local isList = LISTS[key] or v[1] ~= nil
    if isList then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        Encode(v[i], nil, out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = JStr(k) .. ":"
        local x = v[k]
        if x == nil then x = v[tonumber(k)] end
        Encode(x, k, out)
      end
      out[#out + 1] = "}"
    end
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    out[#out + 1] = (v == floor(v) and math.abs(v) < 1e15) and ("%d"):format(v) or ("%.10g"):format(v)
  elseif v == nil then
    out[#out + 1] = "null"
  else
    out[#out + 1] = JStr(v)
  end
end
Runner.EncodeSettings = function(t)
  local out = {}
  Encode(t, nil, out)
  return table.concat(out)
end

local function ProtoBuffs(t)
  local o = {}
  for k, v in pairs(t or {}) do
    if TRISTATE[k] then
      local n = (v == true) and 1 or (tonumber(v) or 0)
      if n > 0 then o[k] = TRI_NAMES[n] end
    elseif v ~= false and v ~= 0 then
      o[k] = v
    end
  end
  return o
end

-- class -> WoWSims player spec field and options
Runner.WOWSIMS_SPEC = {
  Shaman = { class = "ClassShaman", field = "enhancementShaman", options = { options = {
    classOptions = { shieldProcrate = 0, imbueMh = "WindfuryWeapon" }, imbueOh = "WindfuryWeapon",
    syncType = "DelayOffhandSwings" } } },
  Paladin = { class = "ClassPaladin", field = "retributionPaladin", options = { options = { classOptions = {} } } },
  Rogue = { class = "ClassRogue", field = "rogue", options = { options = { classOptions = {} } } },
  Druid = { class = "ClassDruid", field = "feralCatDruid", options = { options = { classOptions = {} } } },
  Priest = { class = "ClassPriest", field = "dpsPriest", options = { options = { classOptions = { preShadowform = true } } } },
  Mage = { class = "ClassMage", field = "mage", options = { options = { classOptions = {
    defaultMageArmor = "MageArmorMageArmor" } } } },
  Warrior = { class = "ClassWarrior", field = "dpsWarrior", options = { options = { classOptions = {
    queueDelay = 250, startingRage = 50, defaultShout = "WarriorShoutBattle", defaultStance = "WarriorStanceBerserker",
    hasBsT2 = true, stanceSnapshot = true } } } },
}

-- set: a gear set; settings: as for Start. Returns the JSON text.
function Runner:WoWSimsSettings(set, settings)
  local sc = self:Scenario(set, settings)
  local ws = self.WOWSIMS_SPEC[sc.class] or self.WOWSIMS_SPEC.Paladin
  local ss = self.SPEC_SETTINGS[self:SpecKey()]
  if ss and ss.field then
    local co = {}
    for k, v in pairs(ss.wsOptions or {}) do co[k] = v end
    ws = { class = ws and ws.class, field = ss.field, options = { options = { classOptions = co } } }
  end
  local items = {}
  for sid = 1, 17 do
    local g = sc.gear[sid]
    local it = {}
    if g then
      it.id = g.id
      if g.randomSuffix and g.randomSuffix ~= 0 then it.randomSuffix = g.randomSuffix end
      if g.enchant and g.enchant ~= 0 then it.enchant = g.enchant end
      local gems, last = {}, 0
      for i = 1, 4 do if g.gems and g.gems[i] and g.gems[i] ~= 0 then last = i end end
      for i = 1, last do gems[i] = (g.gems and g.gems[i]) or 0 end
      if last > 0 then it.gems = gems end
    end
    items[sid] = it
  end
  local cons = {}
  for k, v in pairs(sc.consumables or {}) do cons[k] = v end
  if cons.potId then cons.potions = { cons.potId } end
  if cons.conjuredId then cons.conjuredItems = { cons.conjuredId } end
  local profs = sc.professions or {}
  local race = sc.race == "Scourge" and "Undead" or sc.race
  local stats = {}
  for i = 1, 60 do stats[i] = 0 end
  stats[31 + 1] = sc.targetArmor or 7685   -- StatArmor
  stats[17 + 1] = 320                      -- StatAttackPower
  local player = {
    name = UnitName and UnitName("player") or "Player",
    race = "Race" .. race, class = ws.class,
    equipment = { items = items },
    consumables = cons,
    buffs = ProtoBuffs(sc.buffs.individual),
    talentsString = sc.talents or "",
    profession1 = profs[1], profession2 = profs[2],
    rotation = ns.Data and ns.Data.SimAPL and ns.Data.SimAPL[self:SpecKey()],
    reactionTimeMs = sc.reactionTimeMs or 0,
    distanceFromTarget = sc.distance or 5,
    channelClipDelayMs = sc.channelClipDelayMs or 0,
  }
  player[ws.field] = ws.options
  local doc = {
    apiVersion = 15,
    player = player,
    raidBuffs = ProtoBuffs(sc.buffs.raid),
    partyBuffs = ProtoBuffs(sc.buffs.party),
    debuffs = ProtoBuffs(sc.buffs.debuffs),
    encounter = {
      apiVersion = 15, duration = sc.duration, durationVariation = 0, executeProportion20 = 0.2,
      executeProportion25 = 0.25, executeProportion35 = 0.35, executeProportion45 = 0.45, executeProportion90 = 0.9,
      targets = { { level = 73, mobType = "MobType" .. (sc.mobType or "Mechanical"), swingSpeed = 2,
        minBaseDamage = 15113, parryHaste = true, canCrush = true, damageSpread = 0.5, stats = stats } },
    },
    settings = { iterations = 10000, randomSeed = settings.seed or 101 },
  }
  return self.EncodeSettings(doc)
end
