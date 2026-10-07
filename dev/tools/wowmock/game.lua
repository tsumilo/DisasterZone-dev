-- wowmock/game.lua : game-state APIs (units, group, guild, instance, items, loot, inventory, talents,
-- addon messaging, chat, constants, global strings). World state is pushed from Python into M.W.
local M, cfg, PY = ...

local _G = _G
local type, tostring, tonumber, select, pairs, ipairs, next = type, tostring, tonumber, select, pairs, ipairs, next
local setmetatable, rawget, rawset, error = setmetatable, rawget, rawset, error
local unpack = unpack
local sformat, sgsub, sfind, ssub, smatch, slower, supper = string.format, string.gsub, string.find, string.sub, string.match, string.lower, string.upper
local tinsert, tremove, tconcat, tsort = table.insert, table.remove, table.concat, table.sort
local safecall, OBJ = M.safecall, M.OBJ

---------------------------------------------------------------------------------------------------
-- Enums & constants
---------------------------------------------------------------------------------------------------
Enum = Enum or {}
Enum.SendAddonMessageResult = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3,
  InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8, GeneralError = 9,
  NotInGuild = 10, AddOnMessageLockdown = 11, TargetOffline = 12 }
Enum.RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 }
Enum.LootMethod = { Freeforall = 0, Roundrobin = 1, Masterlooter = 2, Group = 3, Needbeforegreed = 4, Personal = 5 }
Enum.ItemQuality = { Poor = 0, Common = 1, Standard = 1, Uncommon = 2, Good = 3, Rare = 3, Epic = 4, Superior = 4,
  Legendary = 5, Artifact = 6, Heirloom = 7, WoWToken = 8 }
Enum.ItemClass = { Consumable = 0, Container = 1, Weapon = 2, Gem = 3, Armor = 4, Reagent = 5, Projectile = 6,
  Tradegoods = 7, ItemEnhancement = 8, Recipe = 9, CurrencyTokenObsolete = 10, Quiver = 11, Questitem = 12, Key = 13,
  PermanentObsolete = 14, Miscellaneous = 15, Glyph = 16, Battlepet = 17, WoWToken = 18, Profession = 19 }
Enum.ItemArmorSubclass = { Generic = 0, Cloth = 1, Leather = 2, Mail = 3, Plate = 4, Cosmetic = 5, Shield = 6,
  Libram = 7, Idol = 8, Totem = 9, Sigil = 10, Relic = 11 }
Enum.ItemWeaponSubclass = { Axe1H = 0, Axe2H = 1, Bows = 2, Guns = 3, Mace1H = 4, Mace2H = 5, Polearm = 6, Sword1H = 7,
  Sword2H = 8, Warglaive = 9, Staff = 10, Bearclaw = 11, Catclaw = 12, Unarmed = 13, Generic = 14, Dagger = 15,
  Thrown = 16, Obsolete3 = 17, Crossbow = 18, Wand = 19, Fishingpole = 20 }
Enum.ItemMiscellaneousSubclass = { Junk = 0, Reagent = 1, CompanionPet = 2, Holiday = 3, Other = 4, Mount = 5 }
Enum.ItemRecipeSubclass = { Book = 0, Leatherworking = 1, Tailoring = 2, Engineering = 3, Blacksmithing = 4, Cooking = 5,
  Alchemy = 6, FirstAid = 7, Enchanting = 8, Fishing = 9, Jewelcrafting = 10 }
Enum.InventoryType = { IndexNonEquipType = 0, IndexHeadType = 1, IndexNeckType = 2, IndexShoulderType = 3,
  IndexBodyType = 4, IndexChestType = 5, IndexWaistType = 6, IndexLegsType = 7, IndexFeetType = 8, IndexWristType = 9,
  IndexHandType = 10, IndexFingerType = 11, IndexTrinketType = 12, IndexWeaponType = 13, IndexShieldType = 14,
  IndexRangedType = 15, IndexCloakType = 16, Index2HweaponType = 17, IndexBagType = 18, IndexTabardType = 19,
  IndexRobeType = 20, IndexWeaponmainhandType = 21, IndexWeaponoffhandType = 22, IndexHoldableType = 23,
  IndexAmmoType = 24, IndexThrownType = 25, IndexRangedrightType = 26, IndexQuiverType = 27, IndexRelicType = 28 }
Enum.LootSlotType = { None = 0, Item = 1, Money = 2, Currency = 3 }
Enum.ItemBind = { None = 0, OnAcquire = 1, OnEquip = 2, OnUse = 3, Quest = 4 }
Enum.BagIndex = { Keyring = -2, Bank = -1, Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4,
  BankBag_1 = 5, BankBag_2 = 6, BankBag_3 = 7, BankBag_4 = 8, BankBag_5 = 9, BankBag_6 = 10, BankBag_7 = 11 }
Enum.GameMode = { Standard = 0 }
LE_PARTY_CATEGORY_HOME = 1
LE_PARTY_CATEGORY_INSTANCE = 2
LE_EXPANSION_CLASSIC = 0
LE_EXPANSION_BURNING_CRUSADE = 1
LE_EXPANSION_WRATH_OF_THE_LICH_KING = 2
LE_EXPANSION_LEVEL_CURRENT = 1
LE_ITEM_QUALITY_POOR, LE_ITEM_QUALITY_COMMON, LE_ITEM_QUALITY_UNCOMMON, LE_ITEM_QUALITY_RARE, LE_ITEM_QUALITY_EPIC, LE_ITEM_QUALITY_LEGENDARY = 0, 1, 2, 3, 4, 5
WOW_PROJECT_MAINLINE = 1
WOW_PROJECT_CLASSIC = 2
WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5
WOW_PROJECT_WRATH_CLASSIC = 11
WOW_PROJECT_CATACLYSM_CLASSIC = 14
WOW_PROJECT_MISTS_CLASSIC = 19
WOW_PROJECT_ID = 5
MAX_PLAYER_LEVEL = 70
MAX_RAID_MEMBERS = 40
MAX_PARTY_MEMBERS = 4
NUM_RAID_GROUPS = 8
MEMBERS_PER_RAID_GROUP = 5
NUM_BAG_SLOTS = 4
NUM_BANKBAGSLOTS = 7
NUM_BANKGENERIC_SLOTS = 28
BANK_CONTAINER = -1
BACKPACK_CONTAINER = 0
KEYRING_CONTAINER = -2
MAX_CONTAINER_ITEMS = 36
NUM_CONTAINER_FRAMES = 13
INVSLOT_AMMO, INVSLOT_HEAD, INVSLOT_NECK, INVSLOT_SHOULDER, INVSLOT_BODY, INVSLOT_CHEST, INVSLOT_WAIST, INVSLOT_LEGS,
INVSLOT_FEET, INVSLOT_WRIST, INVSLOT_HAND, INVSLOT_FINGER1, INVSLOT_FINGER2, INVSLOT_TRINKET1, INVSLOT_TRINKET2,
INVSLOT_BACK, INVSLOT_MAINHAND, INVSLOT_OFFHAND, INVSLOT_RANGED, INVSLOT_TABARD =
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19
INVSLOT_FIRST_EQUIPPED, INVSLOT_LAST_EQUIPPED = 1, 19
CONTAINER_BAG_OFFSET = 19

function GetBuildInfo() return "2.5.6", "69795", "Sep 1 2026", 20506 end
function GetExpansionLevel() return 1 end
function GetClassicExpansionLevel() return 1 end
function GetServerExpansionLevel() return 1 end
function GetMaxPlayerLevel() return 70 end
function GetLocale() return "enUS" end
function GetCurrentRegion() return 3 end
function GetCurrentRegionName() return "EU" end
function IsTestBuild() return false end
function IsBetaBuild() return false end
function IsPublicBuild() return true end
function IsTrialAccount() return false end
function IsVeteranTrialAccount() return false end
function IsRestrictedAccount() return false end
function IsOnTournamentRealm() return false end
function IsLoggedIn() return M.logged_in == true end
function InCombatLockdown() return M.combat == true end
function GetScreenWidth() return 1920 end
function GetScreenHeight() return 1080 end
function GetPhysicalScreenSize() return 1920, 1080 end
function GetScreenDPIScale() return 1 end
function GetCursorPosition() return 960, 540 end
-- the frame under the mouse (M.click_player sets WorldFrame, or a unit frame for a click on a raid frame)
function GetMouseFocus() return M.mouse_focus end
function GetMouseFoci() return { M.mouse_focus } end
function IsMouseButtonDown() return false end
function GetAddOnCPUUsage() return 0 end
function GetAddOnMemoryUsage() return 0 end
function UpdateAddOnMemoryUsage() end
function UpdateAddOnCPUUsage() end
function RequestTimePlayed() end
function Screenshot() end
function ReloadUI() M.reload_requested = true end
function Logout() M.logout_requested = true end
-- DoEmote(token [, target [, hold]]): the server echoes my emote as CHAT_MSG_TEXT_EMOTE ("You point at Bert."),
-- at the named player, else at my target (a player or NPC), else at nobody. English texts for a few tokens.
local EMOTE_TEXTS = {
  POINT = { "You point over yonder.", "You point at %s." }, WAVE = { "You wave.", "You wave at %s." },
  BOW = { "You bow down graciously.", "You bow before %s." }, HUG = { "You need a hug!", "You hug %s." },
  CHEER = { "You cheer!", "You cheer at %s." }, DANCE = { "You burst into dance.", "You dance with %s." },
  LAUGH = { "You laugh.", "You laugh at %s." }, SALUTE = { "You stand at attention and salute.", "You salute %s with respect." },
  THANK = { "You thank everyone around you.", "You thank %s." }, KISS = { "You blow a kiss into the wind.", "You blow a kiss to %s." },
}
M.emotes = {}   -- every DoEmote call: { token, target }
function DoEmote(token, target, hold)
  if type(token) ~= "string" then error("Usage: DoEmote(emote [, target [, hold]])", 2) end
  token = supper(token)
  M.emotes[#M.emotes + 1] = { token, target }
  local who = (type(target) == "string" and target ~= "") and target or nil
  if not who and UnitExists("target") then who = UnitName("target") end
  local t = EMOTE_TEXTS[token] or { "You " .. slower(token) .. ".", "You " .. slower(token) .. " at %s." }
  local text = who and sformat(t[2], who) or t[1]
  local m = M.W.self
  M.after(0.1, function()
    M.line_id = (M.line_id or 0) + 1
    M.fire("CHAT_MSG_TEXT_EMOTE", text, m.full, "", "", m.name, "", 0, 0, "", 0, M.line_id, m.guid or "", 0, false, false,
      false, false)
  end, "DoEmote")
end
function RandomRoll(a, b)
  M.random_rolls = (M.random_rolls or 0) + 1
  if PY and PY.random_roll then PY.random_roll(tonumber(a) or 1, tonumber(b) or 100) end
end
-- saved instances (raid info): tests set __MOCK.saved = { { name, id, reset, difficulty, locked, extended, mostSig,
-- isRaid, maxPlayers, difficultyName, numEncounters, encounterProgress, extendDisabled, instanceId }, ... }
M.saved = {}
function GetNumSavedInstances() return #M.saved end
function GetSavedInstanceInfo(i)
  local s = M.saved[i]
  if not s then return nil end
  return unpack(s, 1, 14)
end
-- quests: tests set __MOCK.quests_on[id] = true (in the quest log) / __MOCK.quests_done[id] = true (done; dailies until
-- the daily reset)
M.quests_on, M.quests_done = {}, {}
C_QuestLog = C_QuestLog or {}
C_QuestLog.IsOnQuest = function(id) return M.quests_on[tonumber(id) or 0] == true end
C_QuestLog.IsQuestFlaggedCompleted = function(id) return M.quests_done[tonumber(id) or 0] == true end
-- reputations: tests set __MOCK.factions[id] = standingID (1 hated .. 8 exalted); any other faction is revered (7)
M.factions = {}
M.FACTION_NAMES = { [946] = "Honor Hold", [947] = "Thrallmar", [942] = "Cenarion Expedition", [1011] = "Lower City",
  [935] = "The Sha'tar", [989] = "Keepers of Time", [1077] = "Shattered Sun Offensive" }
function GetFactionInfoByID(id)
  id = tonumber(id)
  if not id then return nil end
  local standing = M.factions[id] or 7
  return M.FACTION_NAMES[id] or ("Faction " .. id), "", standing, 0, 21000, 0, false, false, false, false, false,
    false, false, id
end
function RequestRaidInfo() end
function GetMoney() return M.money or 0 end
function GetCoinTextureString(copper)
  copper = tonumber(copper) or 0
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local out = {}
  if g > 0 then out[#out + 1] = g .. "g" end
  if s > 0 then out[#out + 1] = s .. "s" end
  if c > 0 or #out == 0 then out[#out + 1] = c .. "c" end
  return tconcat(out, " ")
end
GetMoneyString = GetCoinTextureString
GetCoinText = GetCoinTextureString
function FormatLargeNumber(n) return tostring(n) end
function BreakUpLargeNumbers(n) return tostring(n) end
function SecondsToTime(s)
  s = math.floor(tonumber(s) or 0)
  if s >= 3600 then return sformat("%d Hr %d Min", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
  if s >= 60 then return sformat("%d Min %d Sec", math.floor(s / 60), s % 60) end
  return sformat("%d Sec", s)
end
function SecondsToClock(s) s = math.floor(tonumber(s) or 0); return sformat("%d:%02d", math.floor(s / 60), s % 60) end
function CreateTextureMarkup(file, fw, fh, w, h) return "|T" .. tostring(file) .. ":" .. (h or 0) .. ":" .. (w or 0) .. "|t" end
function CreateAtlasMarkup(atlas, w, h) return "|A:" .. tostring(atlas) .. ":" .. (h or 0) .. ":" .. (w or 0) .. "|a" end
function CreateSimpleTextureMarkup(file, w, h) return "|T" .. tostring(file) .. ":" .. (h or 0) .. ":" .. (w or 0) .. "|t" end
C_Texture = { GetAtlasInfo = function() return nil end, GetFilenameFromFileDataID = function() return nil end }
M.SPELL_NAMES = {
  [2259] = "Alchemy", [2018] = "Blacksmithing", [7411] = "Enchanting", [4036] = "Engineering", [25229] = "Jewelcrafting",
  [2108] = "Leatherworking", [3908] = "Tailoring", [2575] = "Mining", [2656] = "Smelting", [8613] = "Skinning", [2550] = "Cooking",
  [3273] = "First Aid", [7620] = "Fishing", [28675] = "Potion Master", [9788] = "Armorsmith",
  [1766] = "Kick", [6552] = "Pummel", [72] = "Shield Bash", [8042] = "Earth Shock", [2139] = "Counterspell",
  [19244] = "Spell Lock", [16979] = "Feral Charge", [28730] = "Arcane Torrent", [34477] = "Misdirection",
  [2825] = "Bloodlust", [32182] = "Heroism", [10060] = "Power Infusion", [29166] = "Innervate",
  [1714] = "Curse of Tongues", [702] = "Curse of Weakness", [1490] = "Curse of the Elements",
  [704] = "Curse of Recklessness", [603] = "Curse of Doom", [980] = "Curse of Agony",
  [17862] = "Curse of Shadow", [11719] = "Curse of Tongues", [32375] = "Mass Dispel",
  [41455] = "Circle of Healing", [41472] = "Divine Wrath", [41471] = "Empowered Smite",
  [41450] = "Blessing of Protection", [41451] = "Blessing of Spell Warding", [33152] = "Prayer of Healing",
  [33144] = "Heal",
}
-- M.spells_uncached = true: a spell's name is nil until C_Spell.RequestLoadSpellData asked for it (0.1 s later,
-- with SPELL_DATA_LOAD_RESULT), like the real client on the first look at a spell.
M.spell_loaded = {}
function GetSpellInfo(id)
  if id == nil then return nil end
  if M.spells_uncached and not M.spell_loaded[tonumber(id)] then return nil end
  local name = M.SPELL_NAMES[tonumber(id)] or ("Spell " .. tostring(id))
  return name, nil, 136243, 0, 0, 0, tonumber(id) or 0
end
function GetSpellTexture() return 136243 end
-- unit-frame style round portrait of a creature display id (recorded as the texture for tests)
function SetPortraitTextureFromCreatureDisplayID(tex, displayID) tex:SetTexture("portrait:" .. tostring(displayID)) end
function GetSpellLink(id) return "|cff71d5ff|Hspell:" .. tostring(id) .. "|h[Spell " .. tostring(id) .. "]|h|r" end
M.known_spells = {}   -- [spellID] = true (tests: __MOCK.known_spells[28675] = true)
function IsSpellKnown(id) return M.known_spells[tonumber(id)] and true or false end
function IsPlayerSpell(id) return M.known_spells[tonumber(id)] and true or false end

-- Professions: the skill list and the two profession windows (trade skill; craft = Enchanting on 2.5.x).
-- M.skills = { { name = "Professions", header = true [, collapsed = true] }, { name = "Alchemy", rank = 375, max = 375 }, ... }
-- M.tradeskill / M.craft = { name = "Alchemy", rank = 375, max = 375 [, linked = "Name"],
--                            rows = { { name = "Potions", header = true }, { name = "Flask", spell = 28587, item = 22851 }, ... } }
-- (item = nil: the recipe makes no item; its item link is the enchant link, as in the client)
M.skills = {}
local function visible_skills()
  local out, hidden = {}, false
  for _, s in ipairs(M.skills) do
    if s.header then
      hidden = s.collapsed and true or false
      out[#out + 1] = s
    elseif not hidden then
      out[#out + 1] = s
    end
  end
  return out
end
function GetNumSkillLines() return #visible_skills() end
function GetSkillLineInfo(i)
  local s = visible_skills()[tonumber(i)]
  if not s then return nil end
  if s.header then return s.name, true, not s.collapsed, 0, 0, 0, 0, false, 0, 0, 0, 0, "" end
  return s.name, false, false, s.rank or 1, 0, 0, s.max or 75, s.abandon and true or false, 0, 0, 0, 0, ""
end
function ExpandSkillHeader(i)
  local vis = visible_skills()
  for n, s in ipairs(vis) do
    if s.header and (tonumber(i) == 0 or n == tonumber(i)) then s.collapsed = nil end
  end
end
function CollapseSkillHeader(i)
  local vis = visible_skills()
  for n, s in ipairs(vis) do
    if s.header and (tonumber(i) == 0 or n == tonumber(i)) then s.collapsed = true end
  end
end
local function recipe_link(row)
  return "|cffffd000|Henchant:" .. tostring(row.spell) .. "|h[" .. tostring(row.name) .. "]|h|r"
end
local function row_of(win, i)
  local row = win and win.rows and win.rows[tonumber(i)]
  if row and not row.header then return row end
  return nil
end
function GetTradeSkillLine()
  local t = M.tradeskill
  if not t then return "UNKNOWN", 0, 0 end
  return t.name, t.rank or 1, t.max or 75
end
function IsTradeSkillLinked()
  local t = M.tradeskill
  if t and t.linked then return true, t.linked end
  return false
end
function GetNumTradeSkills() return M.tradeskill and #M.tradeskill.rows or 0 end
function GetTradeSkillInfo(i)
  local row = M.tradeskill and M.tradeskill.rows[tonumber(i)]
  if not row then return nil end
  if row.header then return row.name, "header", 0, true, nil, 0, 0, false, 0, 0, 0 end
  return row.name, row.difficulty or "optimal", 0, false, nil, 1, 0, false, 0, 0, 0
end
function GetTradeSkillRecipeLink(i)
  local row = row_of(M.tradeskill, i)
  return row and recipe_link(row) or nil
end
function GetTradeSkillItemLink(i)
  local row = row_of(M.tradeskill, i)
  if not row then return nil end
  if row.item then return "|cffffffff|Hitem:" .. row.item .. "::::::::70:::::::::|h[" .. tostring(row.name) .. "]|h|r" end
  return recipe_link(row)
end
function GetCraftDisplaySkillLine()
  local t = M.craft
  if not t or t.noline then return nil end
  return t.name, t.rank or 1, t.max or 75
end
function GetCraftSkillLine() return M.craft and M.craft.name or nil end
function GetNumCrafts() return M.craft and #M.craft.rows or 0 end
function GetCraftInfo(i)
  local row = M.craft and M.craft.rows[tonumber(i)]
  if not row then return nil end
  if row.header then return row.name, nil, "header", 0, true, 0, 0 end
  return row.name, nil, row.difficulty or "optimal", 0, false, 0, 0
end
function GetCraftItemLink(i)
  local row = row_of(M.craft, i)
  return row and recipe_link(row) or nil
end
GetCraftRecipeLink = GetCraftItemLink
C_Spell = {
  GetSpellInfo = function(id) return { name = "Spell " .. tostring(id), iconID = 136243, spellID = id, castTime = 0, minRange = 0, maxRange = 0 } end,
  GetSpellName = function(id) return (GetSpellInfo(id)) end,
  RequestLoadSpellData = function(id)
    id = tonumber(id)
    M.after(0.1, function()
      M.spell_loaded[id] = true
      M.fire("SPELL_DATA_LOAD_RESULT", id, true)
    end, "RequestLoadSpellData")
  end,
  GetSpellTexture = function() return 136243 end,
  DoesSpellExist = function() return true end,
}

-- CVars
M.cvars = { nameplateShowEnemies = "1", autoLootDefault = "0", lootUnderMouse = "0", Sound_EnableSFX = "1", Sound_EnableAllSound = "1",
  scriptErrors = "1", taintLog = "0", chatStyle = "classic", portal = "EU", textLocale = "enUS", audioLocale = "enUS",
  useUiScale = "0", uiScale = "1", showToastWindow = "1", autoSelfCast = "1", nameplateShowEnemies = "1",
  UberTooltips = "1", alwaysCompareItems = "0", colorblindMode = "0", profanityFilter = "0", nameplateShowFriends = "0",
  nameplateShowAll = "0" }
local CVAR_DEFAULTS = { nameplateShowFriends = "0", nameplateShowEnemies = "1", nameplateShowAll = "0" }
function GetCVar(name)
  local v = M.cvars[name]
  if v == nil then M.warn("GetCVar('" .. tostring(name) .. "') unknown to the mock (returns nil)") end
  return v
end
function GetCVarBool(name) local v = M.cvars[name]; return v == "1" or v == "true" end
function GetCVarDefault(name) return CVAR_DEFAULTS[name] or M.cvars[name] end
-- (name, value): kept as a string (a boolean as "1" / "0"). Nameplate CVars can't change in combat (the client
-- refuses it, like a protected action): nothing changes and the call returns false.
M.cvar_blocked = {}
function SetCVar(name, v)
  if type(name) ~= "string" then error("Usage: SetCVar(name, value)", 2) end
  if M.combat and sfind(name, "^nameplate") then
    M.cvar_blocked[#M.cvar_blocked + 1] = name
    M.warn("SetCVar('" .. name .. "') in combat: blocked like the client does")
    return false
  end
  if type(v) == "boolean" then v = v and "1" or "0" end
  M.cvars[name] = tostring(v)
  return true
end
function RegisterCVar(name, v) if M.cvars[name] == nil then M.cvars[name] = tostring(v or "") end end
C_CVar = { GetCVar = GetCVar, GetCVarBool = GetCVarBool, SetCVar = SetCVar, GetCVarDefault = GetCVarDefault, RegisterCVar = RegisterCVar }

---------------------------------------------------------------------------------------------------
-- Modifiers / cursor / misc UI state
---------------------------------------------------------------------------------------------------
M.mods = { shift = false, ctrl = false, alt = false }
function IsShiftKeyDown() return M.mods.shift end
function IsControlKeyDown() return M.mods.ctrl end
function IsAltKeyDown() return M.mods.alt end
function IsLeftShiftKeyDown() return M.mods.shift end
function IsRightShiftKeyDown() return false end
function IsLeftControlKeyDown() return M.mods.ctrl end
function IsRightControlKeyDown() return false end
function IsLeftAltKeyDown() return M.mods.alt end
function IsRightAltKeyDown() return false end
function IsModifierKeyDown() return M.mods.shift or M.mods.ctrl or M.mods.alt end
function IsMetaKeyDown() return false end
local MODIFIED = { CHATLINK = "shift", DRESSUP = "ctrl", SPLITSTACK = "shift", COMPAREITEMS = "shift",
  AUTOLOOTTOGGLE = "shift", PICKUPACTION = "shift", SOCKETITEM = "shift", EXPANDITEM = "alt", SELFCAST = "alt",
  FOCUSCAST = "none" }
function IsModifiedClick(action)
  -- No action: "any modified click" (Blizzard's ItemRef.lua / AchievementUI use it that way): any modifier held.
  if action == nil then return (M.mods.shift or M.mods.ctrl or M.mods.alt) and true or false end
  local m = MODIFIED[action]
  if m == nil then return false end
  return M.mods[m] == true
end
function GetModifiedClick(action) return MODIFIED[action] and supper(MODIFIED[action]) or "NONE" end
function GetCursorInfo()
  local c = M.cursor
  if not c then return nil end
  return c.kind, c.id, c.link
end
function ClearCursor() M.cursor = nil end
function CursorHasItem() return M.cursor ~= nil and M.cursor.kind == "item" end
function PickupItem(item)
  local id = M.item_id_of(item)
  if id then M.cursor = { kind = "item", id = id, link = M.item_link(id) } end
end
M.itemrefs, M.dressups = {}, {}
-- Port of classic_anniversary Blizzard_UIPanels_Game/Classic/ItemRef.lua SetItemRef: the link handlers first
-- (LinkUtil, UI mock); the item tooltip fallback is not modelled.
function SetItemRef(link, text, button, chatFrame)
  M.itemrefs[#M.itemrefs + 1] = link
  if LinkUtil and type(link) == "string" then LinkUtil.ProcessLink(link, text, { button = button, frame = chatFrame }) end
end
function DressUpItemLink(link) M.dressups[#M.dressups + 1] = link; return true end
function DressUpLink(link) return DressUpItemLink(link) end
-- Port of classic_anniversary Blizzard_ItemButton/Classic/ItemButtonTemplate.lua HandleModifiedItemClick.
function HandleModifiedItemClick(link)
  M.modified_clicks = (M.modified_clicks or 0) + 1
  if not link then return false end
  if IsModifiedClick("CHATLINK") then
    if ChatFrameUtil and ChatFrameUtil.InsertLink(link) then return true end
  end
  if IsModifiedClick("DRESSUP") then return DressUpItemLink(link) end
  return false
end

---------------------------------------------------------------------------------------------------
-- Classes / races / colors
---------------------------------------------------------------------------------------------------
M.CLASS_IDS = { WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8,
  WARLOCK = 9, MONK = 10, DRUID = 11, DEMONHUNTER = 12, EVOKER = 13 }
M.CLASS_BY_ID = {}
for k, v in pairs(M.CLASS_IDS) do M.CLASS_BY_ID[v] = k end
LOCALIZED_CLASS_NAMES_MALE = { WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue",
  PRIEST = "Priest", DEATHKNIGHT = "Death Knight", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock",
  MONK = "Monk", DRUID = "Druid", DEMONHUNTER = "Demon Hunter", EVOKER = "Evoker" }
LOCALIZED_CLASS_NAMES_FEMALE = CopyTable(LOCALIZED_CLASS_NAMES_MALE)
CLASS_SORT_ORDER = { "WARRIOR", "PALADIN", "PRIEST", "SHAMAN", "DRUID", "ROGUE", "MAGE", "WARLOCK", "HUNTER" }
function FillLocalizedClassList(t, female)
  for k, v in pairs(female and LOCALIZED_CLASS_NAMES_FEMALE or LOCALIZED_CLASS_NAMES_MALE) do t[k] = v end
  return t
end
local CLASS_COLOR_VALUES = {
  WARRIOR = { 0.78, 0.61, 0.43, "ffc79c6e" }, PALADIN = { 0.96, 0.55, 0.73, "fff58cba" },
  HUNTER = { 0.67, 0.83, 0.45, "ffabd473" }, ROGUE = { 1.0, 0.96, 0.41, "fffff569" },
  PRIEST = { 1.0, 1.0, 1.0, "ffffffff" }, DEATHKNIGHT = { 0.77, 0.12, 0.23, "ffc41f3b" },
  SHAMAN = { 0.0, 0.44, 0.87, "ff0070de" }, MAGE = { 0.41, 0.8, 0.94, "ff69ccf0" },
  WARLOCK = { 0.58, 0.51, 0.79, "ff9482c9" }, MONK = { 0.0, 1.0, 0.59, "ff00ff96" },
  DRUID = { 1.0, 0.49, 0.04, "ffff7d0a" }, DEMONHUNTER = { 0.64, 0.19, 0.79, "ffa330c9" },
  EVOKER = { 0.2, 0.58, 0.5, "ff33937f" },
}
RAID_CLASS_COLORS = {}
for k, v in pairs(CLASS_COLOR_VALUES) do
  local c = CreateColor(v[1], v[2], v[3], 1)
  c.colorStr = v[4]
  RAID_CLASS_COLORS[k] = c
end
CUSTOM_CLASS_COLORS = nil
C_ClassColor = { GetClassColor = function(classFile) return RAID_CLASS_COLORS[classFile] end }
function GetClassColor(classFile)
  local c = RAID_CLASS_COLORS[classFile]
  if c then return c.r, c.g, c.b, c.colorStr end
  return 1, 1, 1, "ffffffff"
end
function GetClassColorObj(classFile) return RAID_CLASS_COLORS[classFile] end
-- Blizzard's SharedXML (the role icons: UI-LFG-ICON-ROLES is a 256x256 texture of 67x67 cells)
function GetTexCoordsByGrid(xOffset, yOffset, textureWidth, textureHeight, gridWidth, gridHeight)
  local w, h = gridWidth / textureWidth, gridHeight / textureHeight
  return (xOffset - 1) * w, xOffset * w, (yOffset - 1) * h, yOffset * h
end
function GetTexCoordsForRole(role)
  local grid = { GUIDE = { 1, 1 }, TANK = { 1, 2 }, HEALER = { 2, 1 }, DAMAGER = { 2, 2 } }
  local g = grid[role]
  if not g then error("Unknown role: " .. tostring(role), 2) end
  return GetTexCoordsByGrid(g[1], g[2], 256, 256, 67, 67)
end
CLASS_ICON_TCOORDS = {
  WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.49609375, 0, 0.25 }, ROGUE = { 0.49609375, 0.7421875, 0, 0.25 },
  DRUID = { 0.7421875, 0.98828125, 0, 0.25 }, HUNTER = { 0, 0.25, 0.25, 0.5 }, SHAMAN = { 0.25, 0.49609375, 0.25, 0.5 },
  PRIEST = { 0.49609375, 0.7421875, 0.25, 0.5 }, WARLOCK = { 0.7421875, 0.98828125, 0.25, 0.5 },
  PALADIN = { 0, 0.25, 0.5, 0.75 }, DEATHKNIGHT = { 0.25, 0.49609375, 0.5, 0.75 }, MONK = { 0.49609375, 0.7421875, 0.5, 0.75 },
  DEMONHUNTER = { 0.7421875, 0.98828125, 0.5, 0.75 },
}
function GetClassInfo(id)
  local f = M.CLASS_BY_ID[id]
  if not f then return nil end
  return LOCALIZED_CLASS_NAMES_MALE[f], f, id
end
function GetNumClasses() return 11 end
C_CreatureInfo = {
  GetClassInfo = function(id) local f = M.CLASS_BY_ID[id]; if f then return { className = LOCALIZED_CLASS_NAMES_MALE[f], classFile = f, classID = id } end end,
  GetRaceInfo = function(id) return nil end,
  GetFactionInfo = function(id) return nil end,
}
M.RACES = { Human = { "Human", 1 }, Orc = { "Orc", 2 }, Dwarf = { "Dwarf", 3 }, NightElf = { "Night Elf", 4 },
  Scourge = { "Undead", 5 }, Tauren = { "Tauren", 6 }, Gnome = { "Gnome", 7 }, Troll = { "Troll", 8 },
  BloodElf = { "Blood Elf", 10 }, Draenei = { "Draenei", 11 } }

ITEM_QUALITY_COLORS = {}
local QUALITY = { [0] = { 0.62, 0.62, 0.62, "ff9d9d9d" }, [1] = { 1, 1, 1, "ffffffff" }, [2] = { 0.12, 1, 0, "ff1eff00" },
  [3] = { 0, 0.44, 0.87, "ff0070dd" }, [4] = { 0.64, 0.21, 0.93, "ffa335ee" }, [5] = { 1, 0.5, 0, "ffff8000" },
  [6] = { 0.9, 0.8, 0.5, "ffe6cc80" }, [7] = { 0, 0.8, 1, "ff00ccff" }, [8] = { 0, 0.8, 1, "ff00ccff" } }
for q, v in pairs(QUALITY) do
  local c = CreateColor(v[1], v[2], v[3], 1)
  ITEM_QUALITY_COLORS[q] = { r = v[1], g = v[2], b = v[3], hex = "|c" .. v[4], color = c }
end
function GetItemQualityColor(q)
  local v = QUALITY[q] or QUALITY[1]
  return v[1], v[2], v[3], v[4]
end
ITEM_QUALITY0_DESC, ITEM_QUALITY1_DESC, ITEM_QUALITY2_DESC, ITEM_QUALITY3_DESC, ITEM_QUALITY4_DESC, ITEM_QUALITY5_DESC,
ITEM_QUALITY6_DESC, ITEM_QUALITY7_DESC = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom"

---------------------------------------------------------------------------------------------------
-- World state (pushed from Python)
---------------------------------------------------------------------------------------------------
M.W = { self = { name = cfg.name, realm = cfg.realm, full = cfg.name .. "-" .. cfg.realm, class = cfg.class_file,
  level = cfg.level, guid = cfg.guid, online = true }, realm = cfg.realm, realm_display = cfg.realm_display or cfg.realm }
M.guild_loaded = false
M.loaded_addons = {}
M.toc_meta = {}
function M.set_world(state)
  M.W = state
  for _, n in ipairs(state.loaded_addons or {}) do M.loaded_addons[n] = true end
end

local function norm_realm(r) return (sgsub(r or "", "[%s%-]", "")) end
M.norm_realm = norm_realm
local function me() return M.W.self end

local function party_others()
  local g = M.W.group
  if not g then return {} end
  local out, mine = {}, me()
  local my_sub
  for _, m in ipairs(g.members) do if m.full == mine.full then my_sub = m.subgroup end end
  for _, m in ipairs(g.members) do
    if m.full ~= mine.full and (g.kind ~= "raid" or m.subgroup == my_sub) then out[#out + 1] = m end
  end
  return out
end
M.party_others = party_others

-- Name-based unit lookup (WoW: only the player and group members). anyone=true also searches every online
-- player of the World (used for the "target" unit, since any nearby player can be targeted).
function M.unit_by_name(name, anyone)
  if type(name) ~= "string" or name == "" then return nil end
  local n, r = smatch(name, "^([^%-]+)%-(.+)$")
  if not n then n, r = name, nil end
  local ln, lr = slower(n), r and slower(norm_realm(r))
  local function match(m)
    if not m then return false end
    if slower(m.name) ~= ln then return false end
    if lr then return slower(norm_realm(m.realm)) == lr end
    return norm_realm(m.realm) == norm_realm(M.W.realm)
  end
  if match(me()) then return me() end
  local g = M.W.group
  if g then for _, m in ipairs(g.members) do if match(m) then return m end end end
  if anyone and M.W.players then
    for _, m in ipairs(M.W.players) do if match(m) then return m end end
  end
  return nil
end

function M.unit_rec(unit)
  if type(unit) ~= "string" then return nil end
  local u = slower(unit)
  if u == "player" then return me() end
  local n = smatch(u, "^raid(%d+)$")
  if n then
    local g = M.W.group
    if g and g.kind == "raid" then return g.members[tonumber(n)] end
    return nil
  end
  n = smatch(u, "^party(%d+)$")
  if n then return party_others()[tonumber(n)] end
  -- enemy NPCs (world.spawn_npc): nameplate tokens, an NPC target, the mouseover
  if u == "target" and M.target_npc then return M.npcs[M.target_npc] end
  if u == "mouseover" and M.mouseover_npc then return M.npcs[M.mouseover_npc] end
  -- a player under the mouse (M.set_mouseover / M.click_player)
  if u == "mouseover" and M.mouseover then return M.unit_by_name(M.mouseover, true) end
  if smatch(u, "^nameplate%d+$") then
    local guid = M.nameplates[u]
    return guid and M.npcs[guid] or nil
  end
  if u == "target" then return M.target and M.unit_by_name(M.target, true) end
  if u == "npc" and M.trade then return M.unit_by_name(M.trade.partner, true) end   -- the trade partner
  if u == "none" or u == "mouseover" or u == "focus" or u == "npc" or u == "pet" or u == "vehicle"
     or smatch(u, "^nameplate") or smatch(u, "^boss") or smatch(u, "^arena") then return nil end
  return M.unit_by_name(unit)
end
local unit_rec = M.unit_rec

local function same_realm(m) return norm_realm(m.realm) == norm_realm(M.W.realm) end
local function display_name(m) if same_realm(m) then return m.name end return m.name .. "-" .. norm_realm(m.realm) end
M.display_name = display_name

function UnitName(unit)
  local m = unit_rec(unit)
  if not m then return nil end
  if slower(unit) == "player" or same_realm(m) then return m.name, nil end
  return m.name, norm_realm(m.realm)
end
UnitNameUnmodified = UnitName
function UnitFullName(unit)
  local m = unit_rec(unit)
  if not m then return nil end
  if slower(unit) == "player" then return m.name, norm_realm(m.realm) end
  if same_realm(m) then return m.name, nil end
  return m.name, norm_realm(m.realm)
end
function GetUnitName(unit, showServer)
  local m = unit_rec(unit)
  if not m then return nil end
  if showServer and not same_realm(m) then return m.name .. "-" .. norm_realm(m.realm) end
  return m.name
end
function UnitClass(unit)
  local m = unit_rec(unit)
  if not m then return nil end
  return LOCALIZED_CLASS_NAMES_MALE[m.class] or m.class, m.class, M.CLASS_IDS[m.class]
end
function UnitClassBase(unit) local m = unit_rec(unit); if m then return m.class, M.CLASS_IDS[m.class] end end
function UnitLevel(unit) local m = unit_rec(unit); if m then return m.level or 70 end return 0 end
function UnitEffectiveLevel(unit) return UnitLevel(unit) end
function UnitGUID(unit) local m = unit_rec(unit); return m and m.guid or nil end
function UnitRace(unit)
  local m = unit_rec(unit)
  if not m then return nil end
  local r = M.RACES[m.race or "Human"] or { m.race, 0 }
  return r[1], m.race or "Human", r[2]
end
function UnitSex(unit) local m = unit_rec(unit); return m and (m.sex or 2) or nil end
function UnitFactionGroup(unit)
  local m = unit_rec(unit)
  if not m then return nil end
  local f = m.faction or "Alliance"
  return f, f
end
function UnitExists(unit) return unit_rec(unit) ~= nil end
function UnitIsPlayer(unit) local m = unit_rec(unit); return m ~= nil and not m.npc end
function UnitPlayerControlled(unit) return unit_rec(unit) ~= nil end
function UnitIsUnit(a, b)
  local x, y = unit_rec(a), unit_rec(b)
  return x ~= nil and y ~= nil and x.full == y.full
end
function UnitIsConnected(unit) local m = unit_rec(unit); return m ~= nil and m.online ~= false end
function UnitIsDeadOrGhost(unit) local m = unit_rec(unit); return m ~= nil and (m.dead == true or m.ghost == true) end
function UnitIsDead(unit) local m = unit_rec(unit); return m ~= nil and m.dead == true and m.ghost ~= true end
function UnitIsGhost(unit) local m = unit_rec(unit); return m ~= nil and m.ghost == true end
function UnitIsAFK() return false end
function UnitIsDND() return false end
function UnitIsVisible(unit) return unit_rec(unit) ~= nil end
function UnitInRange(unit) return unit_rec(unit) ~= nil, true end
-- (unit, distIndex): 1 inspect 28 yd, 2 trade 11.11 yd, 3 duel 9.9 yd, 4 follow 28 yd. With both positions known
-- (World.set_position) it measures them; else any unit that exists counts as close (the older tests' world).
local INTERACT_YARDS = { 28, 11.11, 9.9, 28 }
function CheckInteractDistance(unit, index)
  local m = unit_rec(unit)
  if not m then return false end
  local range = INTERACT_YARDS[tonumber(index) or 0]
  if not range then error("Usage: CheckInteractDistance(unit, distIndex)", 2) end
  if m.pos or me().pos then
    local d = M.yards_between(me(), m)
    return d ~= nil and d <= range
  end
  return true
end
function UnitIsEnemy() return false end
function UnitIsFriend(a, b) return true end
function UnitCanAttack(a, b) local m = unit_rec(b); return m ~= nil and m.npc == true end
function UnitCanCooperate(a, b) return unit_rec(b) ~= nil end
function UnitReaction() return 5 end
function UnitIsPVP() return false end
function UnitIsTapDenied() return false end
function UnitOnTaxi() return false end
function UnitHealth(unit) local m = unit_rec(unit); if not m then return 0 end; return m.npc and (m.hp or 100) or 100 end
function UnitHealthMax(unit) return unit_rec(unit) and 100 or 0 end
function UnitPower(unit) return unit_rec(unit) and 100 or 0 end
function UnitPowerMax(unit) return unit_rec(unit) and 100 or 0 end
function UnitPowerType() return 0, "MANA" end
function UnitCreatureType() return nil end
function UnitClassification() return "normal" end
function UnitAura() return nil end
function UnitBuff() return nil end
function UnitDebuff() return nil end
function UnitCastingInfo() return nil end
function UnitChannelInfo() return nil end
function UnitStat() return 0, 0, 0, 0 end
function UnitArmor() return 0, 0, 0, 0, 0 end
function UnitAffectingCombat(unit)
  if slower(unit or "") == "player" then return M.combat == true end
  return false
end
function UnitGroupRolesAssigned() return "NONE" end
function UnitIsGroupLeader(unit) local m = unit_rec(unit); return m ~= nil and M.W.group ~= nil and m.group_rank == 2 end
function UnitIsGroupAssistant(unit) local m = unit_rec(unit); return m ~= nil and M.W.group ~= nil and m.group_rank == 1 end
function UnitInRaid(unit)
  local g = M.W.group
  if not g or g.kind ~= "raid" then return nil end
  local m = unit_rec(unit)
  if not m then return nil end
  for i, x in ipairs(g.members) do if x.full == m.full then return i end end
  return nil
end
function UnitInParty(unit)
  local g = M.W.group
  if not g then return false end
  local m = unit_rec(unit)
  if not m then return false end
  if m.full == me().full then return true end
  for _, x in ipairs(party_others()) do if x.full == m.full then return true end end
  return false
end
function UnitInAnyGroup(unit) local g = M.W.group; if not g then return false end local m = unit_rec(unit); if not m then return false end
  for _, x in ipairs(g.members) do if x.full == m.full then return true end end return false end
function UnitPosition() return nil end
function GetPlayerInfoByGUID(guid)
  local function check(m)
    if m and m.guid == guid then
      local r = M.RACES[m.race or "Human"] or { m.race, 0 }
      return LOCALIZED_CLASS_NAMES_MALE[m.class], m.class, r[1], m.race, m.sex or 2, m.name, same_realm(m) and "" or norm_realm(m.realm)
    end
  end
  local a, b, c, d, e, f, g2 = check(me())
  if a then return a, b, c, d, e, f, g2 end
  local g = M.W.group
  if g then for _, m in ipairs(g.members) do a, b, c, d, e, f, g2 = check(m); if a then return a, b, c, d, e, f, g2 end end end
  local G = M.W.guild
  if G then for _, m in ipairs(G.roster) do a, b, c, d, e, f, g2 = check(m); if a then return a, b, c, d, e, f, g2 end end end
  return nil
end
function GetNormalizedRealmName() return norm_realm(M.W.realm) end
function GetRealmName() return M.W.realm_display or M.W.realm end
function GetRealmID() return 4467 end
function Ambiguate(name, context)
  if type(name) ~= "string" then return name end
  local n, r = smatch(name, "^([^%-]+)%-(.+)$")
  if not n then return name end
  context = slower(context or "none")
  if context == "all" or context == "short" then return n end
  if norm_realm(r) == norm_realm(M.W.realm) then return n end
  return name
end
function UnitIsSameServer(unit) local m = unit_rec(unit); return m ~= nil and same_realm(m) end

---------------------------------------------------------------------------------------------------
-- Group / raid / loot method / instance
---------------------------------------------------------------------------------------------------
function IsInRaid(cat)
  if cat == LE_PARTY_CATEGORY_INSTANCE then return false end
  local g = M.W.group
  return g ~= nil and g.kind == "raid"
end
function IsInGroup(cat)
  if cat == LE_PARTY_CATEGORY_INSTANCE then return false end
  return M.W.group ~= nil
end
function IsPartyLFG() return false end
function IsInLFGDungeon() return false end
function HasLFGRestrictions() return false end
function GetNumGroupMembers(cat)
  if cat == LE_PARTY_CATEGORY_INSTANCE then return 0 end
  local g = M.W.group
  return g and #g.members or 0
end
function GetNumSubgroupMembers(cat)
  if cat == LE_PARTY_CATEGORY_INSTANCE then return 0 end
  return #party_others()
end
function GetRaidRosterInfo(i)
  local g = M.W.group
  if not g then return nil end
  local m = g.members[tonumber(i) or 0]
  if not m then return nil end
  return display_name(m), m.group_rank or 0, m.subgroup or 1, m.level or 70, LOCALIZED_CLASS_NAMES_MALE[m.class] or m.class,
    m.class, m.zone or GetRealZoneText(), m.online ~= false, m.dead == true, m.role, m.isML == true, "NONE"
end
function GetPartyAssignment() return false end
-- Raid marks live in the world (Python): SetRaidTarget goes through it (leader / assist in a raid, anyone in a party),
-- and every group client gets RAID_TARGET_UPDATE with the new marks.
M.npcs, M.nameplates, M.marks = {}, {}, {}
function GetRaidTargetIndex(unit)
  local m = unit_rec(unit)
  local guid = m and m.guid
  return guid and M.marks[guid] or nil
end
function SetRaidTarget(unit, index)
  local m = unit_rec(unit)
  if not m or not m.guid then return end
  PY.set_raid_target(m.guid, tonumber(index) or 0)
end
function M.set_marks(t)
  M.marks = {}
  for guid, idx in pairs(t or {}) do M.marks[guid] = idx end
  M.fire("RAID_TARGET_UPDATE")
end
function M.set_npcs(t)
  M.npcs = {}
  for guid, r in pairs(t or {}) do
    M.npcs[guid] = { guid = guid, name = r.name, npc = true, dead = r.dead, hp = r.hp, full = guid, realm = M.W.realm }
  end
end
local plateSeq = 0
function M.add_nameplate(guid)
  for token, g in pairs(M.nameplates) do if g == guid then return token end end
  plateSeq = plateSeq + 1
  local token = "nameplate" .. plateSeq
  M.nameplates[token] = guid
  M.fire("NAME_PLATE_UNIT_ADDED", token)
  return token
end
function M.remove_nameplate(guid)
  for token, g in pairs(M.nameplates) do
    if g == guid then
      M.nameplates[token] = nil
      M.fire("NAME_PLATE_UNIT_REMOVED", token)
    end
  end
end
function M.set_npc_target(guid)
  M.target_npc = guid
  M.fire("PLAYER_TARGET_CHANGED")
end
function M.set_mouseover_npc(guid)
  M.mouseover_npc = guid
  if guid then M.fire("UPDATE_MOUSEOVER_UNIT") end
end
C_NamePlate = {
  GetNamePlates = function()
    local out = {}
    for token in pairs(M.nameplates) do out[#out + 1] = { namePlateUnitToken = token, UnitFrame = { unit = token } } end
    return out
  end,
  GetNamePlateForUnit = function(unit)
    local guid = UnitGUID(unit)
    for token, g in pairs(M.nameplates) do
      if g == guid then return { namePlateUnitToken = token, UnitFrame = { unit = token } } end
    end
    return nil
  end,
}
function DoReadyCheck() end
function GetReadyCheckStatus() return nil end
function ConvertToRaid() if PY and PY.convert_to_raid then PY.convert_to_raid() end end
function ConvertToParty() end
function InviteUnit(name) if PY and PY.invite and type(name) == "string" then PY.invite(name) end end
function SetRaidSubgroup(index, sub) if PY and PY.set_raid_subgroup then PY.set_raid_subgroup(index, sub) end end
function SwapRaidSubgroup(a, b) if PY and PY.swap_raid_subgroup then PY.swap_raid_subgroup(a, b) end end
function UninviteUnit(name) if PY and PY.uninvite and type(name) == "string" then PY.uninvite(name) end end
function LeaveParty() end
-- PromoteToLeader(unit or name): the party / raid leader hands the lead over (world.promote).
function PromoteToLeader(who)
  if type(who) ~= "string" or not (PY and PY.promote) then return end
  local name = UnitExists(who) and GetUnitName(who, true) or who
  if type(name) == "string" and name ~= "" then PY.promote(name) end
end
function PromoteToAssistant() end
function SetEveryoneIsAssistant() end
local function loot_method_info()
  local g = M.W.group
  if not g then return 0, nil, nil end
  local method = g.loot_method or 3
  local ml = g.ml_index
  if method ~= 2 or not ml then return method, nil, nil end
  local mlm = g.members[ml]
  local party_id
  if mlm and mlm.full == me().full then party_id = 0
  else
    for k, x in ipairs(party_others()) do if mlm and x.full == mlm.full then party_id = k end end
  end
  return method, party_id, g.kind == "raid" and ml or nil
end
C_PartyInfo = {
  GetLootMethod = function() return loot_method_info() end,
  SetLootMethod = function() M.warn("C_PartyInfo.SetLootMethod is not simulated; use world.make_raid(master_looter=...)") end,
  InviteUnit = function(name) InviteUnit(name) end, LeaveParty = function() end,
  ConvertToRaid = function() ConvertToRaid() end, ConvertToParty = function() end,
  IsPartyFull = function() return GetNumGroupMembers() >= 5 end, DoCountdown = function() end,
  CanInvite = function() return true end, GetMinLevel = function() return 1 end,
  IsPartyInJailersTower = function() return false end,
}
local LOOT_METHOD_NAMES = { [0] = "freeforall", [1] = "roundrobin", [2] = "master", [3] = "group", [4] = "needbeforegreed", [5] = "personalloot" }
M.legacy.GetLootMethod = function()
  local m, p, r = loot_method_info()
  return LOOT_METHOD_NAMES[m], p, r
end
function GetLootThreshold() local g = M.W.group; return g and g.threshold or 2 end
function SetLootThreshold() end
function GetOptOutOfLoot() return false end

function IsInInstance()
  local inst = M.W.instance
  if inst then return true, inst.type or "raid" end
  return false, "none"
end
function GetInstanceInfo()
  local inst = M.W.instance
  if not inst then return GetRealZoneText(), "none", 0, "", 0, 0, false, 0, 0, nil end
  return inst.name, inst.type or "raid", inst.difficultyID or 3, inst.difficultyName or "10 Player", inst.maxPlayers or 10,
    0, false, inst.instanceID or 0, GetNumGroupMembers(), nil
end
function GetDifficultyInfo(id)
  local names = { [1] = "Normal", [2] = "Heroic", [3] = "10 Player", [4] = "25 Player", [9] = "40 Player", [148] = "20 Player" }
  return names[id] or "Normal", (id == 1 or id == 2) and "party" or "raid", id == 2, false, false, false, nil
end
function GetRealZoneText()
  local inst = M.W.instance
  if inst then return inst.name end
  -- (standing somewhere in the open world, World.set_position: that zone's name, as the game says it)
  local m = me()
  local o = m and m.pos and M.outdoor_maps and M.outdoor_maps[m.pos.map]
  if o and o.mapType == 3 then return o.name end
  return M.W.zone or "Shattrath City"
end
function GetZoneText() return GetRealZoneText() end
-- (a client's subzone: World.set_position(c, ..., subzone=...); "" in the open with none, and in instances)
function GetSubZoneText() local s = me() and me().subzone; return (not M.W.instance and type(s) == "string") and s or "" end
function GetMinimapZoneText()
  local s = GetSubZoneText()
  if s ~= "" then return s end
  return GetRealZoneText()
end
function GetZonePVPInfo() return "sanctuary" end

-- Vector2D (SharedXMLBase/Vector2D.lua): C_Map takes and returns these.
Vector2DMixin = {}
function Vector2DMixin:GetXY() return self.x, self.y end
function Vector2DMixin:SetXY(x, y) self.x, self.y = x, y end
function Vector2DMixin:Clone() return CreateVector2D(self.x, self.y) end
function Vector2DMixin:IsEqualTo(o) return self.x == o.x and self.y == o.y end
function Vector2DMixin:GetLength() return math.sqrt(self.x * self.x + self.y * self.y) end
function CreateVector2D(x, y)
  local v = setmetatable({}, { __index = Vector2DMixin })
  v.x, v.y = x, y
  return v
end

-- Outland's open-world zones (uiMapIDs of the Classic TBC client) with a world rectangle each, as C_Map lays them out:
-- a map position (0..1, x east, y south) is the world point (top - y * h, left - x * w): the world vector's x grows to
-- the north and its y to the west (HereBeDragons reads GetWorldPosFromMapPos(...):GetXY() as top, left). Continent 530.
M.outdoor_maps = {
  [1945] = { name = "Outland", cont = 530, left = 12996.04, top = 5135.42, w = 17464.58, h = 11643.06, mapType = 2, parent = 946 },
  [1944] = { name = "Hellfire Peninsula", cont = 530, left = 5539.58, top = 1481.25, w = 5164.58, h = 3443.75 },
  [1946] = { name = "Zangarmarsh", cont = 530, left = 9475.0, top = 1935.42, w = 5027.08, h = 3352.08 },
  [1948] = { name = "Shadowmoon Valley", cont = 530, left = 4225.0, top = -1364.58, w = 5500.0, h = 3666.67 },
  [1949] = { name = "Blade's Edge Mountains", cont = 530, left = 8845.83, top = 3420.83, w = 5425.0, h = 3616.67 },
  [1951] = { name = "Nagrand", cont = 530, left = 10150.0, top = -1483.33, w = 5525.0, h = 3683.33 },
  [1952] = { name = "Terokkar Forest", cont = 530, left = 7083.33, top = -1608.33, w = 5400.0, h = 3600.0 },
  [1953] = { name = "Netherstorm", cont = 530, left = 7512.5, top = 5341.67, w = 5574.99, h = 3716.67 },
  [1955] = { name = "Shattrath City", cont = 530, left = 6135.42, top = -1031.25, w = 1306.25, h = 870.83 },
}
for id, m in pairs(M.outdoor_maps) do
  m.mapType = m.mapType or 3
  m.parent = m.parent or 1945
end
local function map_to_world(id, x, y)
  local m = M.outdoor_maps[id]
  if not m or type(x) ~= "number" or type(y) ~= "number" then return nil end
  return m.cont, m.top - y * m.h, m.left - x * m.w
end
local function world_to_map(id, cont, wx, wy)
  local m = M.outdoor_maps[id]
  if not m or m.cont ~= cont then return nil end
  return (m.left - wy) / m.w, (m.top - wx) / m.h
end
M.map_to_world, M.world_to_map = map_to_world, world_to_map
-- Where a unit stands (World.set_position): cont, world x, world y; nil when nobody set it, or in an instance.
local function unit_world(m)
  local p = m and m.pos
  if not p or M.W.instance then return nil end
  return map_to_world(p.map, p.x, p.y)
end
M.unit_world = unit_world
-- the yards between two unit records (nil: either one has no position, or other continents)
function M.yards_between(a, b)
  local c1, x1, y1 = unit_world(a)
  local c2, x2, y2 = unit_world(b)
  if not c1 or not c2 or c1 ~= c2 then return nil end
  return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
end

-- Facing (radians, 0 = north, counterclockwise) and movement of the player (tests set __MOCK.facing / speed /
-- mounted / flying / swimming). Position APIs are restricted in instances: GetPlayerFacing and C_Map return nil there.
M.facing, M.speed = 0, 0
function GetPlayerFacing()
  if M.W.instance then return nil end
  return M.facing or 0
end
function GetUnitSpeed(unit)
  if not unit_rec(unit) then return 0, 0, 0, 0 end
  local cur = slower(unit) == "player" and (M.speed or 0) or 0
  return cur, 7, 7, 4.722222
end
function IsMounted() return M.mounted == true end
function IsFlying() return M.flying == true end
function IsSwimming() return M.swimming == true end
function IsFalling() return M.falling == true end
-- The open world zones' map art (the client's world map: 1002 x 668 in 4 x 3 tiles of 256), by their file names.
M.outdoor_art = { [1944] = "Hellfire", [1945] = "Expansion01", [1946] = "Zangarmarsh", [1948] = "ShadowmoonValley",
  [1949] = "BladesEdgeMountains", [1951] = "Nagrand", [1952] = "TerokkarForest", [1953] = "Netherstorm",
  [1955] = "ShattrathCity" }
-- A few instance floors with map art (Enum.UIMapType.Dungeon = 4), as the strategy boards read them: 3 floors of
-- Black Temple in one map group, 1002 x 668 layers of 256px tiles (4 x 3 = 12 file ids each).
M.dungeon_maps = {
  [339] = { name = "Black Temple", floor = "Illidari Training Grounds", group = 1 },
  [340] = { name = "Black Temple", floor = "Karabor Sewers", group = 1 },
  [341] = { name = "Black Temple", floor = "Chamber of Command", group = 1 },
}
C_Map = {
  GetBestMapForUnit = function(unit)
    local m = unit_rec(unit)
    if not m then return nil end
    if M.W.instance then return M.W.instance.uiMapID or 1955 end
    return (m.pos and M.outdoor_maps[m.pos.map]) and m.pos.map or 1955
  end,
  GetMapInfo = function(id)
    local d = M.dungeon_maps[id]
    if d then return { mapID = id, name = d.name, mapType = 4, parentMapID = 1946, flags = 0 } end
    local o = M.outdoor_maps[id]
    if o then return { mapID = id, name = o.name, mapType = o.mapType, parentMapID = o.parent, flags = 0 } end
    return { mapID = id, name = GetRealZoneText(), mapType = 3, parentMapID = 0 }
  end,
  -- (uiMapID, unit) -> Vector2D (0..1 on that map, may fall outside it on the same continent) or nil: nobody set
  -- where the unit stands, another continent, or in an instance (restricted there).
  GetPlayerMapPosition = function(id, unit)
    local cont, wx, wy = unit_world(unit_rec(unit))
    if not cont then return nil end
    local x, y = world_to_map(tonumber(id), cont, wx, wy)
    if not x then return nil end
    return CreateVector2D(x, y)
  end,
  -- (uiMapID, Vector2D) -> continentID, Vector2D in world coordinates (yards)
  GetWorldPosFromMapPos = function(id, pos)
    if type(pos) ~= "table" or not pos.GetXY then error("Usage: C_Map.GetWorldPosFromMapPos(uiMapID, mapPosition)", 2) end
    local x, y = pos:GetXY()
    local cont, wx, wy = map_to_world(tonumber(id), x, y)
    if not cont then return nil end
    return cont, CreateVector2D(wx, wy)
  end,
  -- (continentID, Vector2D [, overrideUiMapID]) -> uiMapID, Vector2D
  GetMapPosFromWorldPos = function(cont, pos, override)
    if type(pos) ~= "table" or not pos.GetXY then error("Usage: C_Map.GetMapPosFromWorldPos(continentID, worldPosition [, overrideUiMapID])", 2) end
    local wx, wy = pos:GetXY()
    local ids = {}
    if override then ids[1] = override else for id in pairs(M.outdoor_maps) do ids[#ids + 1] = id end end
    table.sort(ids, function(a, b) return M.outdoor_maps[a] and M.outdoor_maps[b] and M.outdoor_maps[a].w < M.outdoor_maps[b].w end)
    for _, id in ipairs(ids) do
      local x, y = world_to_map(id, cont, wx, wy)
      if x and (override or (x >= 0 and x <= 1 and y >= 0 and y <= 1)) then return id, CreateVector2D(x, y) end
    end
    return nil
  end,
  GetMapGroupID = function(id) local d = M.dungeon_maps[id]; return d and d.group or nil end,
  GetMapGroupMembersInfo = function(gid)
    local out = {}
    for id, d in pairs(M.dungeon_maps) do
      if d.group == gid then out[#out + 1] = { mapID = id, relativeHeightIndex = id - 338, name = d.floor } end
    end
    table.sort(out, function(a, b) return a.mapID < b.mapID end)
    return out
  end,
  GetMapArtLayers = function(id)
    if not (M.dungeon_maps[id] or M.outdoor_art[id]) then return {} end
    return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256, minScale = 1, maxScale = 1,
               additionalZoomSteps = 0 } }
  end,
  GetMapArtLayerTextures = function(id, layer)
    if layer ~= 1 then return {} end
    local out = {}
    local art = M.outdoor_art[id]
    if art then
      -- (the client's own world map tiles: tools that draw a view read them from the game's files)
      for i = 1, 12 do out[i] = "Interface\\WorldMap\\" .. art .. "\\" .. art .. i end
      return out
    end
    if not M.dungeon_maps[id] then return {} end
    for i = 1, 12 do out[i] = 200000 + id * 100 + i end
    return out
  end,
}

---------------------------------------------------------------------------------------------------
-- Guild
---------------------------------------------------------------------------------------------------
M.show_offline = true
local function guild() return M.W.guild end
local function officer_rank() local G = guild(); return G and G.officer_rank or 1 end
local function roster_view()
  local G = guild()
  if not G or not M.guild_loaded then return {} end
  if M.show_offline then return G.roster end
  local out = {}
  for _, m in ipairs(G.roster) do if m.online then out[#out + 1] = m end end
  return out
end
function IsInGuild() return me().guild ~= nil end
function GetGuildInfo(unit)
  local m = unit_rec(unit)
  if not m or not m.guild then return nil end
  return m.guild, m.guild_rank_name, m.guild_rank, (not same_realm(m)) and norm_realm(m.realm) or nil
end
function GetNumGuildMembers()
  local G = guild()
  if not G or not M.guild_loaded then return 0, 0, 0 end
  local online = 0
  for _, m in ipairs(G.roster) do if m.online then online = online + 1 end end
  return #G.roster, online, online
end
function CanViewOfficerNote() local r = me().guild_rank; return r ~= nil and r <= officer_rank() end
function CanEditOfficerNote() local r = me().guild_rank; return r ~= nil and r <= officer_rank() end
function CanEditPublicNote() return me().guild ~= nil end
function CanEditGuildInfo() local r = me().guild_rank; return r ~= nil and r <= 1 end
function CanEditMOTD() local r = me().guild_rank; return r ~= nil and r <= 1 end
function CanGuildInvite() local r = me().guild_rank; return r ~= nil and r <= officer_rank() end
function CanGuildRemove() return CanGuildInvite() end
function CanGuildPromote() return CanGuildInvite() end
function IsGuildLeader() return me().guild_rank == 0 end
function GetGuildRosterInfo(i)
  local list = roster_view()
  local m = list[tonumber(i) or 0]
  if not m then return nil end
  local G = guild()
  local officer = CanViewOfficerNote() and (m.officer_note or "") or ""
  return m.full, G.ranks[(m.guild_rank or 0) + 1] or "", m.guild_rank or 0, m.level or 70,
    LOCALIZED_CLASS_NAMES_MALE[m.class] or m.class, m.zone or "", m.public_note or "", officer, m.online == true,
    (M.roster_status and M.roster_status[m.full]) or 0,   -- M.roster_status = { ["Name-Realm"] = 1 (AFK) | 2 (DND) }
    m.class, 0, 0, false, false, 4, m.guid
end
function GetGuildRosterLastOnline(i) return 0, 0, 1, 0 end
function GetGuildRosterShowOffline() return M.show_offline end
function SetGuildRosterShowOffline(v) M.show_offline = v and true or false; M.defer("GUILD_ROSTER_UPDATE", false) end
function GetGuildRosterMOTD() local G = guild(); return G and G.motd or "" end
function GetGuildInfoText()
  local G = guild()
  if not G or not M.guild_loaded then return "" end
  return G.info_text or ""
end
function SetGuildInfoText(text)
  if type(text) ~= "string" then error("Usage: SetGuildInfoText(text)", 2) end
  if not CanEditGuildInfo() then
    M.warn("SetGuildInfoText called without permission (rank " .. tostring(me().guild_rank) .. "): ignored like WoW")
    return
  end
  PY.set_guild_info_text(M.hex(text))
end
function GuildControlGetNumRanks() local G = guild(); return G and #G.ranks or 0 end
function GuildControlGetRankName(i) local G = guild(); return G and G.ranks[tonumber(i) or 0] or nil end
function GuildControlGetRankFlags() return false end
function GuildRosterSetPublicNote(i, note)
  local m = roster_view()[tonumber(i) or 0]
  if not m then return end
  PY.set_note(m.full, "public", M.hex(tostring(note or "")))
end
function GuildRosterSetOfficerNote(i, note)
  if not CanEditOfficerNote() then M.warn("GuildRosterSetOfficerNote without permission: ignored"); return end
  local m = roster_view()[tonumber(i) or 0]
  if not m then return end
  PY.set_note(m.full, "officer", M.hex(tostring(note or "")))
end
function M.request_roster()
  if M.roster_pending then return end
  M.roster_pending = true
  M.after(0, function()
    M.roster_pending = false
    M.guild_loaded = true
    M.fire("GUILD_ROSTER_UPDATE", false)
  end, "GuildRoster")
end
function M.roster_changed()
  if M.guild_loaded then M.defer("GUILD_ROSTER_UPDATE", false) end
end
C_GuildInfo = {
  GuildRoster = function() if IsInGuild() then M.request_roster() end end,
  CanEditOfficerNote = CanEditOfficerNote,
  CanViewOfficerNote = CanViewOfficerNote,
  IsGuildOfficer = function() local r = me().guild_rank; return r ~= nil and r <= officer_rank() end,
  CanSpeakInGuildChat = function() return IsInGuild() end,
  GetGuildTabardInfo = function() return nil end,
  IsGuildRankAssignmentAllowed = function() return false end,
  -- 2.5.6 native API (GetGuildInfoText / SetGuildInfoText are deprecation-fallback aliases of these)
  GetInfoText = function() return GetGuildInfoText() end,
  SetInfoText = function(text) return SetGuildInfoText(text) end,
}
M.legacy.GuildRoster = C_GuildInfo.GuildRoster

---------------------------------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------------------------------
M.ITEMS = {}
M.ITEMS_MISS = {}
M.item_cached = {}
M.item_loading = {}
M.item_waiters = {}
M.items_uncached = cfg.items_uncached and true or false
function M.load_items(src)
  local t = assert(loadstring(src, "@wowmock/items.lua"))()
  for id, r in pairs(t) do
    M.ITEMS[id] = { name = r[1], quality = r[2], loc = r[3], cls = r[4], sub = r[5], icon = r[6], ilvl = r[7],
      minlvl = r[8], bind = r[9], stack = r[10] }
  end
end
function M.define_item(id, name, quality, loc, cls, sub, icon, ilvl, minlvl, bind, stack)
  M.ITEMS[id] = { name = name, quality = quality or 4, loc = loc or "INVTYPE_NON_EQUIP_IGNORE", cls = cls or 15, sub = sub or 0,
    icon = icon or (130000 + id % 10000), ilvl = ilvl or 0, minlvl = minlvl or 0, bind = bind or 1, stack = stack or 1 }
  M.ITEMS_MISS[id] = nil
  M.item_by_name_idx = nil
end
function M.item_rec(id)
  if type(id) ~= "number" then return nil end
  local r = M.ITEMS[id]
  if r then return r end
  if M.ITEMS_MISS[id] then return nil end
  if PY and PY.item_lookup then
    local name, q, loc, cls, sub, icon, ilvl, minlvl = PY.item_lookup(id)
    if name then
      r = { name = name, quality = q, loc = loc, cls = cls, sub = sub, icon = icon, ilvl = ilvl, minlvl = minlvl, bind = 1, stack = 1 }
      M.ITEMS[id] = r
      return r
    end
  end
  M.ITEMS_MISS[id] = true
  return nil
end
local item_rec = M.item_rec
function M.item_by_name(name)
  if not M.item_by_name_idx then
    M.item_by_name_idx = {}
    for id, r in pairs(M.ITEMS) do M.item_by_name_idx[slower(r.name)] = id end
  end
  return M.item_by_name_idx[slower(name)]
end
function M.item_id_of(item)
  local t = type(item)
  if t == "number" then return item end
  if t == "string" then
    local id = tonumber(smatch(item, "item:(%-?%d+)"))
    if id then return id end
    id = tonumber(item)
    if id then return id end
    local byname = M.item_by_name(item)
    if byname and M.is_cached(byname) then return byname end
  end
  return nil
end
local item_id_of = M.item_id_of
function M.is_cached(id)
  return (not M.items_uncached) or M.item_cached[id] == true
end
function M.request_item(id)
  if M.is_cached(id) or M.item_loading[id] or not item_rec(id) then return end
  M.item_loading[id] = true
  M.after(0.1, function()
    M.item_loading[id] = nil
    M.item_cached[id] = true
    M.fire("ITEM_DATA_LOAD_RESULT", id, true)
    M.fire("GET_ITEM_INFO_RECEIVED", id, true)
    local w = M.item_waiters[id]
    M.item_waiters[id] = nil
    if w then for _, fn in ipairs(w) do safecall("ContinueOnItemLoad(" .. id .. ")", fn) end end
  end, "item load")
end
function M.item_link(id)
  local r = item_rec(id)
  if not r then return nil end
  local q = ITEM_QUALITY_COLORS[r.quality] or ITEM_QUALITY_COLORS[1]
  return q.hex .. "|Hitem:" .. id .. "::::::::" .. (me().level or 70) .. ":::::::::|h[" .. r.name .. "]|h|r"
end
local CLASS_NAMES = { [0] = "Consumable", [1] = "Container", [2] = "Weapon", [3] = "Gem", [4] = "Armor", [5] = "Reagent",
  [6] = "Projectile", [7] = "Trade Goods", [8] = "Item Enhancement", [9] = "Recipe", [10] = "Money(OBSOLETE)", [11] = "Quiver",
  [12] = "Quest", [13] = "Key", [14] = "Permanent(OBSOLETE)", [15] = "Miscellaneous", [16] = "Glyph" }
local SUBCLASS_NAMES = {
  [2] = { [0] = "One-Handed Axes", [1] = "Two-Handed Axes", [2] = "Bows", [3] = "Guns", [4] = "One-Handed Maces",
    [5] = "Two-Handed Maces", [6] = "Polearms", [7] = "One-Handed Swords", [8] = "Two-Handed Swords", [9] = "Warglaives",
    [10] = "Staves", [13] = "Fist Weapons", [14] = "Miscellaneous", [15] = "Daggers", [16] = "Thrown", [18] = "Crossbows",
    [19] = "Wands", [20] = "Fishing Poles" },
  [4] = { [0] = "Miscellaneous", [1] = "Cloth", [2] = "Leather", [3] = "Mail", [4] = "Plate", [6] = "Shields",
    [7] = "Librams", [8] = "Idols", [9] = "Totems", [11] = "Relic" },
  [9] = { [0] = "Book", [1] = "Leatherworking", [2] = "Tailoring", [3] = "Engineering", [4] = "Blacksmithing",
    [5] = "Cooking", [6] = "Alchemy", [7] = "First Aid", [8] = "Enchanting", [9] = "Fishing", [10] = "Jewelcrafting" },
  [15] = { [0] = "Junk", [1] = "Reagent", [2] = "Pet", [3] = "Holiday", [4] = "Other", [5] = "Mount" },
  [3] = { [0] = "Red", [1] = "Blue", [2] = "Yellow", [3] = "Purple", [4] = "Green", [5] = "Orange", [6] = "Meta", [7] = "Simple", [8] = "Prismatic" },
  [7] = { [0] = "Trade Goods", [1] = "Parts", [2] = "Explosives", [3] = "Devices", [4] = "Jewelcrafting", [5] = "Cloth",
    [6] = "Leather", [7] = "Metal & Stone", [8] = "Meat", [9] = "Herb", [10] = "Elemental", [11] = "Other", [12] = "Enchanting" },
}
function M.item_type_name(cls) return CLASS_NAMES[cls] or "Miscellaneous" end
function M.item_subtype_name(cls, sub) return (SUBCLASS_NAMES[cls] or {})[sub] or "Other" end
local INVTYPE_IDS = { INVTYPE_NON_EQUIP_IGNORE = 0, INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_BODY = 4,
  INVTYPE_CHEST = 5, INVTYPE_WAIST = 6, INVTYPE_LEGS = 7, INVTYPE_FEET = 8, INVTYPE_WRIST = 9, INVTYPE_HAND = 10,
  INVTYPE_FINGER = 11, INVTYPE_TRINKET = 12, INVTYPE_WEAPON = 13, INVTYPE_SHIELD = 14, INVTYPE_RANGED = 15,
  INVTYPE_CLOAK = 16, INVTYPE_2HWEAPON = 17, INVTYPE_BAG = 18, INVTYPE_TABARD = 19, INVTYPE_ROBE = 20,
  INVTYPE_WEAPONMAINHAND = 21, INVTYPE_WEAPONOFFHAND = 22, INVTYPE_HOLDABLE = 23, INVTYPE_AMMO = 24,
  INVTYPE_THROWN = 25, INVTYPE_RANGEDRIGHT = 26, INVTYPE_QUIVER = 27, INVTYPE_RELIC = 28 }
M.INVTYPE_IDS = INVTYPE_IDS

local function check_item_arg(item, fname)
  if item == nil or (type(item) ~= "number" and type(item) ~= "string") then
    error("Usage: " .. fname .. "(itemID|\"itemName\"|\"itemLink\") - got " .. type(item), 3)
  end
end
local function get_item_info(item, fname)
  check_item_arg(item, fname)
  local id = item_id_of(item)
  if not id then return nil end
  local r = item_rec(id)
  if not r then return nil end
  if not M.is_cached(id) then M.request_item(id); return nil end
  local link = M.item_link(id)
  if type(item) == "string" and sfind(item, "|Hitem:", 1, true) then link = item end
  return r.name, link, r.quality, r.ilvl or 0, r.minlvl or 0, M.item_type_name(r.cls), M.item_subtype_name(r.cls, r.sub),
    r.stack or 1, r.loc or "", r.icon, (r.ilvl or 0) * 50, r.cls, r.sub, r.bind or 0, 1, nil, false
end
local function get_item_info_instant(item, fname)
  check_item_arg(item, fname)
  local id = item_id_of(item)
  if not id then return nil end
  local r = item_rec(id)
  if not r then return nil end
  return id, M.item_type_name(r.cls), M.item_subtype_name(r.cls, r.sub), r.loc or "", r.icon, r.cls, r.sub
end
local function equippable(item)
  local id = item_id_of(item)
  local r = id and item_rec(id)
  return r ~= nil and r.loc ~= nil and r.loc ~= "" and r.loc ~= "INVTYPE_NON_EQUIP_IGNORE" and r.loc ~= "INVTYPE_BAG"
end
C_Item = {
  GetItemInfo = function(item) return get_item_info(item, "C_Item.GetItemInfo") end,
  GetItemInfoInstant = function(item) return get_item_info_instant(item, "C_Item.GetItemInfoInstant") end,
  GetItemIconByID = function(id) local r = item_rec(item_id_of(id)); return r and r.icon or nil end,
  GetItemIcon = function(item) local r = item_rec(item_id_of(item)); return r and r.icon or nil end,
  GetItemQualityByID = function(id)
    local i = item_id_of(id)
    local r = item_rec(i)
    if not r then return nil end
    if not M.is_cached(i) then M.request_item(i); return nil end
    return r.quality
  end,
  GetItemNameByID = function(id)
    local i = item_id_of(id)
    local r = item_rec(i)
    if not r then return nil end
    if not M.is_cached(i) then M.request_item(i); return nil end
    return r.name
  end,
  GetItemLinkByGUID = function() return nil end,
  RequestLoadItemDataByID = function(id) local i = item_id_of(id); if i then M.request_item(i) end end,
  RequestLoadItemData = function() end,
  IsItemDataCachedByID = function(id) local i = item_id_of(id); return i ~= nil and item_rec(i) ~= nil and M.is_cached(i) end,
  IsItemDataCached = function() return true end,
  DoesItemExistByID = function(id) local i = item_id_of(id); return i ~= nil and item_rec(i) ~= nil end,
  DoesItemExist = function() return true end,
  GetItemQualityColor = function(q) return GetItemQualityColor(q) end,
  IsEquippableItem = function(item) return equippable(item) end,
  IsEquippedItem = function(item)
    local id = item_id_of(item)
    for s = 0, 19 do if M.inv[s] == id then return true end end
    return false
  end,
  GetItemCount = function(item, includeBank) return M.item_count(item_id_of(item), includeBank) end,
  GetDetailedItemLevelInfo = function(item) local r = item_rec(item_id_of(item)); if r then return r.ilvl, false, r.ilvl end end,
  GetItemClassInfo = function(cls) return CLASS_NAMES[cls] end,
  GetItemSubClassInfo = function(cls, sub) return (SUBCLASS_NAMES[cls] or {})[sub], cls == 4 end,
  GetItemInventoryTypeByID = function(id) local r = item_rec(item_id_of(id)); if r then return INVTYPE_IDS[r.loc] or 0 end end,
  GetItemStats = function() return {} end,
  GetItemSpell = function() return nil end,
  GetItemFamily = function() return 0 end,
  GetItemUniqueness = function() return nil end,
  GetItemCooldown = function() return 0, 0, 0 end,
  GetItemSetInfo = function() return nil end,
  GetItemID = function() return nil end,
}
function GetItemIcon(item) return C_Item.GetItemIcon(item) end
function IsEquippableItem(item) return equippable(item) end
function IsEquippedItem(item) return C_Item.IsEquippedItem(item) end
function GetItemCount(item, includeBank) return C_Item.GetItemCount(item, includeBank) end
function GetDetailedItemLevelInfo(item) return C_Item.GetDetailedItemLevelInfo(item) end
function GetItemClassInfo(cls) return C_Item.GetItemClassInfo(cls) end
function GetItemSubClassInfo(cls, sub) return C_Item.GetItemSubClassInfo(cls, sub) end
function GetItemStats() return {} end
function GetItemSpell() return nil end
function GetItemFamily() return 0 end
M.legacy.GetItemInfo = function(item) return get_item_info(item, "GetItemInfo") end
M.legacy.GetItemInfoInstant = function(item) return get_item_info_instant(item, "GetItemInfoInstant") end

-- Item mixin
ItemMixin = {}
Item = {}
local function new_item(id, link)
  local o = CreateFromMixins(ItemMixin)
  o.itemID, o.itemLink = id, link
  return o
end
function Item:CreateFromItemID(id)
  if type(id) ~= "number" then error("Item:CreateFromItemID: number expected, got " .. type(id), 2) end
  return new_item(id)
end
function Item:CreateFromItemLink(link)
  if type(link) ~= "string" then error("Item:CreateFromItemLink: string expected", 2) end
  return new_item(tonumber(smatch(link, "item:(%d+)")), link)
end
function Item:CreateFromBagAndSlot(bag, slot) return new_item(C_Container.GetContainerItemID(bag, slot)) end
function Item:CreateFromEquipmentSlot(slot) return new_item(M.inv[slot]) end
function ItemMixin:GetItemID() return self.itemID end
function ItemMixin:IsItemEmpty() return self.itemID == nil or item_rec(self.itemID) == nil end
function ItemMixin:IsItemDataCached() return self.itemID ~= nil and M.is_cached(self.itemID) end
function ItemMixin:GetItemName() if self:IsItemDataCached() then local r = item_rec(self.itemID); return r and r.name end end
function ItemMixin:GetItemLink() if self:IsItemDataCached() then return self.itemLink or M.item_link(self.itemID) end end
function ItemMixin:GetItemQuality() if self:IsItemDataCached() then local r = item_rec(self.itemID); return r and r.quality end end
function ItemMixin:GetItemQualityColor() local q = self:GetItemQuality(); return q and ITEM_QUALITY_COLORS[q] end
function ItemMixin:GetItemIcon() local r = self.itemID and item_rec(self.itemID); return r and r.icon end
function ItemMixin:GetCurrentItemLevel() local r = self.itemID and item_rec(self.itemID); return r and r.ilvl end
function ItemMixin:GetInventoryType() local r = self.itemID and item_rec(self.itemID); return r and INVTYPE_IDS[r.loc] end
function ItemMixin:GetInventoryTypeName() local r = self.itemID and item_rec(self.itemID); return r and r.loc end
function ItemMixin:GetItemGUID() return nil end
function ItemMixin:IsItemLocked() return false end
function ItemMixin:Clear() self.itemID, self.itemLink = nil, nil end
function ItemMixin:ContinueOnItemLoad(cb)
  if type(cb) ~= "function" then error("Usage: Item:ContinueOnItemLoad(callbackFunction)", 2) end
  if self:IsItemEmpty() then error("Item:ContinueOnItemLoad: item is empty (itemID " .. tostring(self.itemID) .. ")", 2) end
  if self:IsItemDataCached() then cb(); return end
  local l = M.item_waiters[self.itemID] or {}
  M.item_waiters[self.itemID] = l
  l[#l + 1] = cb
  M.request_item(self.itemID)
end
function ItemMixin:ContinueWithCancelOnItemLoad(cb)
  local cancelled = false
  self:ContinueOnItemLoad(function() if not cancelled then cb() end end)
  return function() cancelled = true end
end
ItemEventListener = { AddCallback = function(self, id, cb) Item:CreateFromItemID(id):ContinueOnItemLoad(cb) end,
  AddCancelableCallback = function(self, id, cb) return Item:CreateFromItemID(id):ContinueWithCancelOnItemLoad(cb) end }

---------------------------------------------------------------------------------------------------
-- Inventory / bags / bank
---------------------------------------------------------------------------------------------------
M.inv = {}
M.bags = {}
M.bank_open = false
M.bank_requires_open = cfg.bank_requires_open ~= false
local SLOT_IDS = { AmmoSlot = 0, HeadSlot = 1, NeckSlot = 2, ShoulderSlot = 3, ShirtSlot = 4, ChestSlot = 5,
  WaistSlot = 6, LegsSlot = 7, FeetSlot = 8, WristSlot = 9, HandsSlot = 10, Finger0Slot = 11, Finger1Slot = 12,
  Trinket0Slot = 13, Trinket1Slot = 14, BackSlot = 15, MainHandSlot = 16, SecondaryHandSlot = 17, RangedSlot = 18,
  TabardSlot = 19, Bag0Slot = 20, Bag1Slot = 21, Bag2Slot = 22, Bag3Slot = 23 }
local SLOT_TEX = { AmmoSlot = 136520, HeadSlot = 136516, NeckSlot = 136519, ShoulderSlot = 136526, ShirtSlot = 136525,
  ChestSlot = 136512, WaistSlot = 136529, LegsSlot = 136517, FeetSlot = 136513, WristSlot = 136530, HandsSlot = 136515,
  Finger0Slot = 136514, Finger1Slot = 136514, Trinket0Slot = 136528, Trinket1Slot = 136528, BackSlot = 136512,
  MainHandSlot = 136518, SecondaryHandSlot = 136524, RangedSlot = 136520, TabardSlot = 136527 }
M.SLOT_IDS = SLOT_IDS
function GetInventorySlotInfo(name)
  local id = SLOT_IDS[name]
  if not id then error("GetInventorySlotInfo: Invalid inventory slot name '" .. tostring(name) .. "'", 2) end
  return id, SLOT_TEX[name] or 136528, name == "RangedSlot"
end
local function player_unit(unit, fname)
  if slower(unit or "") ~= "player" then
    return false
  end
  return true
end
function GetInventoryItemID(unit, slot)
  if not player_unit(unit) then return nil end
  -- The real 2.5.x client returns TWO values (itemID, <number>); code doing
  -- tonumber(GetInventoryItemID(...)) then errors with "base out of range" (seen in game).
  local id = M.inv[tonumber(slot) or -1]
  if id == nil then return nil end
  return id, 0
end
function GetInventoryItemLink(unit, slot)
  local id = GetInventoryItemID(unit, slot)
  return id and M.item_link(id) or nil
end
function GetInventoryItemTexture(unit, slot) local id = GetInventoryItemID(unit, slot); local r = id and item_rec(id); return r and r.icon end
function GetInventoryItemQuality(unit, slot) local id = GetInventoryItemID(unit, slot); local r = id and item_rec(id); return r and r.quality end
function GetInventoryItemCount(unit, slot) return GetInventoryItemID(unit, slot) and 1 or 0 end
function GetInventoryItemDurability() return 100, 100 end
function GetInventoryItemBroken() return false end
function GetInventoryItemCooldown() return 0, 0, 0 end
function GetInventoryItemsForSlot() return {} end
function PickupInventoryItem(slot) local id = M.inv[slot]; if id then M.cursor = { kind = "item", id = id, link = M.item_link(id) } end end
function EquipItemByName() end
function NotifyInspect() end
function ClearInspectPlayer() end
function CanInspect(unit) return unit_rec(unit) ~= nil end
function ContainerIDToInventoryID(bag)
  if bag >= 1 and bag <= 4 then return 19 + bag end
  if bag >= 5 and bag <= 11 then return 63 + bag end
  return nil
end
function BankButtonIDToInvSlotID(id, isBag) if isBag then return 67 + id end return 39 + id end

local function is_bank_bag(bag) return bag == -1 or (bag >= 5 and bag <= 11) end
local function bag_rec(bag)
  bag = tonumber(bag)
  if not bag then return nil end
  if is_bank_bag(bag) and M.bank_requires_open and not M.bank_open then return nil end
  return M.bags[bag]
end
local function bag_size(bag)
  bag = tonumber(bag)
  if not bag then return 0 end
  local b = M.bags[bag]
  if b and b.size then return b.size end
  if bag == 0 then return 16 end
  if bag == -1 then return 28 end
  return 0
end
function M.item_count(id, includeBank)
  if not id then return 0 end
  local n = 0
  for bag, b in pairs(M.bags) do
    if (not is_bank_bag(bag)) or includeBank then
      for _, s in pairs(b.slots) do if s.id == id then n = n + (s.count or 1) end end
    end
  end
  return n
end
C_Container = {
  GetContainerNumSlots = function(bag) return bag_size(bag) end,
  GetContainerNumFreeSlots = function(bag)
    local size, used = bag_size(bag), 0
    local b = bag_rec(bag)
    if b then for _ in pairs(b.slots) do used = used + 1 end end
    return size - used, 0
  end,
  GetContainerItemID = function(bag, slot)
    local b = bag_rec(bag)
    local s = b and b.slots[tonumber(slot) or -1]
    return s and s.id or nil
  end,
  GetContainerItemLink = function(bag, slot)
    local id = C_Container.GetContainerItemID(bag, slot)
    return id and M.item_link(id) or nil
  end,
  GetContainerItemInfo = function(bag, slot)
    local b = bag_rec(bag)
    local s = b and b.slots[tonumber(slot) or -1]
    if not s then return nil end
    local r = item_rec(s.id)
    return { iconFileID = r and r.icon, stackCount = s.count or 1, isLocked = false, quality = r and r.quality,
      isReadable = false, hasLoot = false, hyperlink = M.item_link(s.id), isFiltered = false, hasNoValue = false,
      itemID = s.id, isBound = true }
  end,
  GetBagName = function(bag) if bag == 0 then return "Backpack" end if M.bags[bag] then return "Bag" end return nil end,
  PickupContainerItem = function(bag, slot)
    local id = C_Container.GetContainerItemID(bag, slot)
    if id then M.cursor = { kind = "item", id = id, link = M.item_link(id) } end
  end,
  UseContainerItem = function() end,
  SplitContainerItem = function() end,
  SortBags = function() end,
  SortBankBags = function() end,
  GetContainerItemQuestInfo = function() return { isQuestItem = false, isActive = false } end,
  GetContainerItemCooldown = function() return 0, 0, 0 end,
  IsContainerFiltered = function() return false end,
  SetItemSearch = function() end,
  GetItemCooldown = function() return 0, 0, 0 end,
}
M.legacy.GetContainerNumSlots = C_Container.GetContainerNumSlots
M.legacy.GetContainerItemID = C_Container.GetContainerItemID
M.legacy.GetContainerItemLink = C_Container.GetContainerItemLink
M.legacy.GetContainerNumFreeSlots = C_Container.GetContainerNumFreeSlots
M.legacy.GetContainerItemInfo = function(bag, slot)
  local t = C_Container.GetContainerItemInfo(bag, slot)
  if not t then return nil end
  return t.iconFileID, t.stackCount, t.isLocked, t.quality, t.isReadable, t.hasLoot, t.hyperlink, t.isFiltered, t.hasNoValue, t.itemID
end

-- called from Python helpers
function M.equip(changes)
  local changed = {}
  for slot, id in pairs(changes) do
    slot = tonumber(slot)
    if id == 0 or id == false then id = nil end
    if M.inv[slot] ~= id then M.inv[slot] = id; changed[#changed + 1] = slot end
  end
  tsort(changed)
  for _, slot in ipairs(changed) do M.fire("PLAYER_EQUIPMENT_CHANGED", slot, M.inv[slot] == nil) end
  if #changed > 0 then M.fire("UNIT_INVENTORY_CHANGED", "player") end
end
function M.set_bags(content, bank)
  -- content: { {bag, slot, id, count}, ... }; replaces the given container family
  local touched = {}
  for bag, b in pairs(M.bags) do
    if is_bank_bag(bag) == (bank and true or false) then touched[bag] = true; b.slots = {} end
  end
  for _, e in ipairs(content) do
    local bag, slot, id, count = tonumber(e[1]), tonumber(e[2]), tonumber(e[3]), tonumber(e[4]) or 1
    local b = M.bags[bag]
    if not b then b = { slots = {} }; M.bags[bag] = b end
    if id and id ~= 0 then b.slots[slot] = { id = id, count = count } end
    local size = b.size or bag_size(bag)
    if bag ~= 0 and bag ~= -1 and (b.size == nil or slot > b.size) then b.size = math.max(slot, b.size or 16) end
    if (bag == 0 and slot > 16) or (bag == -1 and slot > 28) then b.size = math.max(slot, b.size or 0) end
    touched[bag] = true
  end
  if bank then
    if not M.bank_open then M.bank_open = true; M.fire("BANKFRAME_OPENED") end
    local list = {}
    for bag in pairs(touched) do list[#list + 1] = bag end
    tsort(list)
    for _, bag in ipairs(list) do
      if bag == -1 then
        for slot = 1, bag_size(-1) do M.fire("PLAYERBANKSLOTS_CHANGED", slot) end
      else
        M.fire("BAG_UPDATE", bag)
      end
    end
    M.fire("BAG_UPDATE_DELAYED")
  else
    local list = {}
    for bag in pairs(touched) do list[#list + 1] = bag end
    tsort(list)
    for _, bag in ipairs(list) do M.fire("BAG_UPDATE", bag) end
    M.fire("BAG_UPDATE_DELAYED")
  end
end
function M.give_item(id, count)
  for bag = 0, 4 do
    local b = M.bags[bag]
    if not b then b = { slots = {} }; M.bags[bag] = b; if bag > 0 then b.size = 16 end end
    for slot = 1, bag_size(bag) do
      if not b.slots[slot] then
        b.slots[slot] = { id = id, count = count or 1 }
        M.fire("BAG_UPDATE", bag)
        M.fire("BAG_UPDATE_DELAYED")
        return bag, slot
      end
    end
  end
  M.warn("give_item: bags full, item " .. tostring(id) .. " not added")
end
-- Trade window (my side only): M.open_trade(partner name), ClickTradeButton with an item on the cursor,
-- M.complete_trade() (both accept: the items leave my bags) / M.cancel_trade().
M.trade = nil
function M.open_trade(partner)
  M.trade = { partner = partner, items = {} }
  M.fire("TRADE_SHOW")
end
function ClickTradeButton(n)
  local t, c = M.trade, M.cursor
  if not t or not c or c.kind ~= "item" or t.items[n] then return end
  t.items[n] = c.id
  M.cursor = nil
  M.fire("TRADE_PLAYER_ITEM_CHANGED", n)
end
function GetTradePlayerItemInfo(n)
  local id = M.trade and M.trade.items[n]
  if not id then return nil end
  local name, _, quality, _, _, _, _, _, _, icon = GetItemInfo(id)
  return name or ("item " .. id), icon, 1, quality, true, nil
end
function GetTradePlayerItemLink(n)
  local id = M.trade and M.trade.items[n]
  return id and M.item_link(id) or nil
end
function M.complete_trade()
  local t = M.trade
  if not t then return {} end
  M.fire("TRADE_ACCEPT_UPDATE", 1, 1)
  local ids = {}
  for n = 1, 7 do
    local id = t.items[n]
    if id then
      ids[#ids + 1] = id
      local done = false
      for bag = 0, 4 do
        local b = M.bags[bag]
        if b and not done then
          for slot, s in pairs(b.slots) do
            if s.id == id then b.slots[slot] = nil; done = true; M.fire("BAG_UPDATE", bag); break end
          end
        end
      end
    end
  end
  M.trade = nil
  M.fire("TRADE_CLOSED")
  M.fire("UI_INFO_MESSAGE", 0, ERR_TRADE_COMPLETE)
  return ids
end
function M.cancel_trade()
  if not M.trade then return end
  M.trade = nil
  M.fire("TRADE_CLOSED")
end
function M.open_bank()
  if not M.bank_open then M.bank_open = true; M.fire("BANKFRAME_OPENED") end
end
function M.close_bank()
  if M.bank_open then M.bank_open = false; M.fire("BANKFRAME_CLOSED") end
end

---------------------------------------------------------------------------------------------------
-- Talents (modern GetTalentTabInfo order)
---------------------------------------------------------------------------------------------------
local TALENT_TABS = {
  WARRIOR = { { 161, "Arms" }, { 164, "Fury" }, { 163, "Protection" } },
  PALADIN = { { 382, "Holy" }, { 383, "Protection" }, { 381, "Retribution" } },
  HUNTER = { { 361, "Beast Mastery" }, { 363, "Marksmanship" }, { 362, "Survival" } },
  ROGUE = { { 182, "Assassination" }, { 181, "Combat" }, { 183, "Subtlety" } },
  PRIEST = { { 201, "Discipline" }, { 202, "Holy" }, { 203, "Shadow" } },
  SHAMAN = { { 261, "Elemental" }, { 263, "Enhancement" }, { 262, "Restoration" } },
  MAGE = { { 81, "Arcane" }, { 41, "Fire" }, { 61, "Frost" } },
  WARLOCK = { { 302, "Affliction" }, { 303, "Demonology" }, { 301, "Destruction" } },
  DRUID = { { 283, "Balance" }, { 281, "Feral Combat" }, { 282, "Restoration" } },
}
M.talents = cfg.talents or { 0, 0, 0 }
function GetNumTalentTabs() return 3 end
function GetTalentTabInfo(tab, isInspect, isPet, group)
  local tabs = TALENT_TABS[me().class] or TALENT_TABS.WARRIOR
  local t = tabs[tonumber(tab) or 0]
  if not t then return nil end
  local src = (tonumber(group) == 2 and M.talents2) or M.talents   -- M.talents2: the secondary talents (dual spec)
  local spent = tonumber(src[tonumber(tab)]) or 0
  return t[1], t[2], t[2] .. " talents", 136243 + tab, spent, me().class .. sgsub(t[2], " ", ""), 0, true
end
-- 2.5.6 native API (GetTalentTabInfo is a deprecation-fallback alias): pointsSpent is the 7th return.
C_SpecializationInfo = {
  GetSpecializationInfo = function(tab, isInspect, isPet, inspectTarget, sex, groupIndex)
    local id, name, desc, icon, spent, bg, preview, unlocked = GetTalentTabInfo(tab, isInspect, isPet, groupIndex)
    return id or 0, name, desc, icon, nil, nil, spent or 0, bg, preview or 0, unlocked ~= false
  end,
}
function GetNumTalents(tab) return 0 end
function GetTalentInfo(tab, index) return nil end
function GetActiveTalentGroup() return 1 end
function GetNumTalentGroups() return M.talents2 and 2 or 1 end
function GetUnspentTalentPoints() return 0 end

---------------------------------------------------------------------------------------------------
-- Loot
---------------------------------------------------------------------------------------------------
M.loot = nil
M.rolls = {}
function M.open_loot(items, guid)
  local slots = {}
  for i, e in ipairs(items) do
    local id, q, count = tonumber(e[1]), tonumber(e[2]), tonumber(e[3]) or 1
    local r = item_rec(id)
    if q == nil and r then q = r.quality end
    slots[i] = { itemID = id, quality = q or 4, count = count, guid = guid }
  end
  M.loot = { slots = slots, open = true, guid = guid }
  M.fire("LOOT_READY", false)
  M.fire("LOOT_OPENED", false, false)
end
function M.close_loot()
  if M.loot and M.loot.open then
    M.loot.open = false
    M.fire("LOOT_CLOSED")
  end
  M.loot = nil
end
local function loot_slot(slot)
  local L = M.loot
  if not L or not L.open then return nil end
  return L.slots[tonumber(slot) or 0]
end
function GetNumLootItems() local L = M.loot; if not L or not L.open then return 0 end return #L.slots end
function GetLootSlotLink(slot) local s = loot_slot(slot); if s and s.itemID then return M.item_link(s.itemID) end return nil end
function GetLootSlotInfo(slot)
  local s = loot_slot(slot)
  if not s or not s.itemID then return nil end
  local r = item_rec(s.itemID)
  return r and r.icon or 134400, r and r.name or ("Item " .. s.itemID), s.count or 1, nil, s.quality or (r and r.quality) or 1,
    false, false, nil, false
end
function GetLootSlotType(slot) local s = loot_slot(slot); if s and s.itemID then return 1 end return 0 end
function GetLootSourceInfo(slot) local s = loot_slot(slot); if s and s.itemID then return s.guid, s.count or 1 end return nil end
function LootSlotHasItem(slot) local s = loot_slot(slot); return s ~= nil and s.itemID ~= nil end
function GetLootInfo()
  local out = {}
  local L = M.loot
  if L and L.open then
    for i, s in ipairs(L.slots) do
      local r = s.itemID and item_rec(s.itemID)
      out[i] = { texture = r and r.icon, item = r and r.name, quantity = s.count or 1, quality = s.quality, locked = false,
        isQuestItem = false, questID = nil, isActive = false, roll = false }
    end
  end
  return out
end
function LootSlot(slot)
  local s = loot_slot(slot)
  if not s or not s.itemID then return end
  local id, count = s.itemID, s.count
  s.itemID = nil
  M.give_item(id, count)
  M.fire("LOOT_SLOT_CLEARED", tonumber(slot))
end
function CloseLoot() M.close_loot() end
function ConfirmLootSlot() end
function ConfirmLootRoll() end
-- the open loot window came from fishing (M.fish_loot opens one)
function IsFishingLoot() return M.fishing_loot == true end
local function ml_candidates()
  local g = M.W.group
  local out = {}
  if not g then return out end
  for _, m in ipairs(g.members) do if m.online ~= false then out[#out + 1] = m end end
  return out
end
function GetMasterLootCandidate(slot, index)
  if not loot_slot(slot) then return nil end
  local c = ml_candidates()[tonumber(index) or 0]
  return c and display_name(c) or nil
end
function GiveMasterLoot(slot, index)
  local s = loot_slot(slot)
  if not s or not s.itemID then error("GiveMasterLoot: invalid loot slot " .. tostring(slot), 2) end
  local method, partyID = loot_method_info()
  if method ~= 2 or partyID ~= 0 then
    M.warn("GiveMasterLoot called but the player is not the master looter: ignored like WoW")
    return
  end
  local c = ml_candidates()[tonumber(index) or 0]
  if not c then error("GiveMasterLoot: invalid candidate index " .. tostring(index), 2) end
  -- Like WoW, GiveMasterLoot only sends a request: the server answers a round trip later. On success the slot
  -- clears (LOOT_SLOT_CLEARED while the window is open) and everyone gets the loot message; on a refusal
  -- (bags full, unique item, ...) the master looter gets UI_ERROR_MESSAGE and the item stays in the slot.
  if s.pending then return end
  s.pending = true
  local L = M.loot
  local refuse = M.ml_refuse[c.full]
  M.after(0.1, function()
    s.pending = nil
    if refuse then
      local msg = _G[M.ml_refuse_errors[refuse] or "ERR_LOOT_MASTER_OTHER"] or ERR_LOOT_MASTER_OTHER
      M.fire("UI_ERROR_MESSAGE", 0, msg)
      return
    end
    if not s.itemID then return end
    local id, count = s.itemID, s.count
    s.itemID = nil
    PY.give_master_loot(c.full, id, count or 1)
    if M.loot == L and L and L.open then M.fire("LOOT_SLOT_CLEARED", tonumber(slot)) end
  end, "GiveMasterLoot")
end
-- Test knob: the server refuses master-loot hand-outs to `full` ("inv_full", "unique", "other", "not_found"; nil = ok).
M.ml_refuse = {}
M.ml_refuse_errors = { inv_full = "ERR_LOOT_MASTER_INV_FULL", unique = "ERR_LOOT_MASTER_UNIQUE_ITEM",
  other = "ERR_LOOT_MASTER_OTHER", not_found = "ERR_LOOT_PLAYER_NOT_FOUND" }
function M.set_ml_refusal(full, kind) M.ml_refuse[full] = kind end
function M.start_roll(rollID, id, quality, count, rollTime)
  local r = item_rec(id)
  M.rolls[rollID] = { itemID = id, quality = quality or (r and r.quality) or 4, count = count or 1,
    started = M.now, duration = (rollTime or 60000) / 1000 }
  M.fire("START_LOOT_ROLL", rollID, rollTime or 60000)
end
function M.cancel_roll(rollID)
  if M.rolls[rollID] then M.rolls[rollID] = nil; M.fire("CANCEL_LOOT_ROLL", rollID) end
end
function GetLootRollItemLink(rollID) local r = M.rolls[rollID]; return r and M.item_link(r.itemID) or nil end
function GetLootRollItemInfo(rollID)
  local x = M.rolls[rollID]
  if not x then return nil end
  local r = item_rec(x.itemID)
  return r and r.icon, r and r.name, x.count, x.quality, (r and r.bind == 1) or false, true, true, false, 0, 0, 0, 0, false
end
function GetLootRollTimeLeft(rollID)
  local x = M.rolls[rollID]
  if not x then return 0 end
  return math.max(0, (x.started + x.duration - M.now) * 1000)
end
function GetActiveLootRollIDs() local out = {} for id in pairs(M.rolls) do out[#out + 1] = id end tsort(out) return out end
M.roll_choices = {}
function RollOnLoot(rollID, rollType) M.roll_choices[#M.roll_choices + 1] = { rollID = rollID, rollType = rollType } end
function M.loot_message(winner_display, winner_full, winner_guid, id, count, is_self, pushed)
  local link = M.item_link(id) or ("[item:" .. tostring(id) .. "]")
  local text
  if pushed then   -- "You receive item" (a trade): only the receiver sees it
    text = sformat(LOOT_ITEM_PUSHED_SELF, link)
  elseif is_self then
    if count and count > 1 then text = sformat(LOOT_ITEM_SELF_MULTIPLE, link, count) else text = sformat(LOOT_ITEM_SELF, link) end
  else
    if count and count > 1 then text = sformat(LOOT_ITEM_MULTIPLE, winner_display, link, count) else text = sformat(LOOT_ITEM, winner_display, link) end
  end
  M.line_id = (M.line_id or 0) + 1
  M.fire("CHAT_MSG_LOOT", text, winner_full, "", "", winner_display, "", 0, 0, "", 0, M.line_id, winner_guid or "", 0, false, false, false, false)
  return text
end

---------------------------------------------------------------------------------------------------
-- Addon messaging + chat
---------------------------------------------------------------------------------------------------
M.prefixes = {}
M.throttle = {}
M.addon_throttle = cfg.addon_throttle ~= false
local R = Enum.SendAddonMessageResult
local VALID_ADDON_CHAT = { PARTY = true, RAID = true, GUILD = true, OFFICER = true, WHISPER = true, CHANNEL = true,
  SAY = true, YELL = true, INSTANCE_CHAT = true, BATTLEGROUND = true }
local function send_addon(fname, logged, prefix, text, chatType, target)
  if type(prefix) ~= "string" then error("Usage: C_ChatInfo." .. fname .. "(prefix, message, chatType [, target]) - prefix must be a string", 3) end
  if type(text) == "number" then text = tostring(text) end
  if type(text) ~= "string" then error("Usage: C_ChatInfo." .. fname .. "(prefix, message, chatType [, target]) - message must be a string", 3) end
  if #prefix > 16 then error("C_ChatInfo." .. fname .. ": prefix '" .. prefix .. "' is " .. #prefix .. " characters (max 16)", 3) end
  if #prefix == 0 then return R.InvalidPrefix end
  if #text > 255 then error("C_ChatInfo." .. fname .. ": message is " .. #text .. " bytes (max 255)", 3) end
  if type(chatType) ~= "string" then error("C_ChatInfo." .. fname .. ": chatType must be a string", 3) end
  local ct = supper(chatType)
  if not VALID_ADDON_CHAT[ct] then return R.InvalidChatType end
  if ct == "WHISPER" and (type(target) ~= "string" or target == "") then return R.TargetRequired end
  if (ct == "RAID" or ct == "PARTY" or ct == "INSTANCE_CHAT") and not M.W.group then return R.NotInGroup end
  if (ct == "GUILD" or ct == "OFFICER") and not me().guild then return R.GeneralError end
  local z = sfind(text, "\0", 1, true)
  if z then
    M.warn("C_ChatInfo." .. fname .. ": message contains \\000; WoW truncates it there")
    text = ssub(text, 1, z - 1)
  end
  if M.addon_throttle then
    local b = M.throttle[prefix]
    if not b then b = { tokens = 10, t = M.now }; M.throttle[prefix] = b end
    b.tokens = math.min(10, b.tokens + (M.now - b.t))
    b.t = M.now
    if b.tokens < 1 then
      M.warn("addon message throttled by the server rate limit (prefix '" .. prefix .. "', >10 msgs burst, 1/s regen)")
      M.throttled = (M.throttled or 0) + 1
      return R.AddonMessageThrottle
    end
    b.tokens = b.tokens - 1
  end
  local res = PY.send_addon(prefix, M.hex(text), ct, target and tostring(target) or nil, logged and true or false)
  return res or R.Success
end
C_ChatInfo = {
  RegisterAddonMessagePrefix = function(prefix)
    if type(prefix) ~= "string" then error("Usage: C_ChatInfo.RegisterAddonMessagePrefix(prefix)", 2) end
    if #prefix == 0 or #prefix > 16 then
      M.warn("C_ChatInfo.RegisterAddonMessagePrefix('" .. prefix .. "'): invalid prefix (1-16 characters)")
      return Enum.RegisterAddonMessagePrefixResult.InvalidPrefix
    end
    if M.prefixes[prefix] then return Enum.RegisterAddonMessagePrefixResult.DuplicatePrefix end
    M.prefixes[prefix] = true
    return Enum.RegisterAddonMessagePrefixResult.Success
  end,
  IsAddonMessagePrefixRegistered = function(prefix) return M.prefixes[prefix] == true end,
  GetRegisteredAddonMessagePrefixes = function() local t = {} for p in pairs(M.prefixes) do t[#t + 1] = p end tsort(t) return t end,
  SendAddonMessage = function(prefix, text, chatType, target) return send_addon("SendAddonMessage", false, prefix, text, chatType, target) end,
  SendAddonMessageLogged = function(prefix, text, chatType, target) return send_addon("SendAddonMessageLogged", true, prefix, text, chatType, target) end,
  InChatMessagingLockdown = function() return false end,
  IsValidChatType = function() return true end,
  GetChannelRosterInfo = function() return nil end,
}
function BNSendGameData() end
function BNGetInfo() return nil end
function BNFeaturesEnabled() return false end
function BNFeaturesEnabledAndConnected() return false end
function BNConnected() return false end
function BNGetNumFriends() return 0, 0 end
C_BattleNet = { GetFriendAccountInfo = function() return nil end, GetAccountInfoByGUID = function() return nil end }
C_FriendList = { IsFriend = function() return false end, GetNumFriends = function() return 0 end, GetNumOnlineFriends = function() return 0 end,
  GetFriendInfoByIndex = function() return nil end, IsIgnored = function() return false end, ShowFriends = function() end }
function IsIgnored() return false end

local CHAT_TYPES = { SAY = true, YELL = true, EMOTE = true, PARTY = true, RAID = true, RAID_WARNING = true, GUILD = true,
  OFFICER = true, WHISPER = true, CHANNEL = true, INSTANCE_CHAT = true, BATTLEGROUND = true, AFK = true, DND = true }
function SendChatMessage(msg, chatType, language, target)
  if type(msg) == "number" then msg = tostring(msg) end
  if type(msg) ~= "string" then error("Usage: SendChatMessage(text [, chatType, languageID, target])", 2) end
  local ct = supper(chatType or "SAY")
  if not CHAT_TYPES[ct] then error("SendChatMessage: invalid chat type '" .. tostring(chatType) .. "'", 2) end
  if #msg > 255 then error("SendChatMessage: message is " .. #msg .. " bytes (max 255)", 2) end
  if sfind(msg, "\n", 1, true) then M.warn("SendChatMessage: message contains a newline (WoW rejects/truncates it)") end
  if ct == "WHISPER" and (type(target) ~= "string" or target == "") then error("SendChatMessage: WHISPER requires a target", 2) end
  if ct == "RAID_WARNING" then
    local g = M.W.group
    local mine = unit_rec("player")
    if not g or (g.kind == "raid" and not (mine.group_rank and mine.group_rank >= 1)) then
      M.warn("SendChatMessage RAID_WARNING without being raid leader/assistant: WoW sends nothing")
      return
    end
  end
  PY.send_chat(M.hex(msg), ct, language, target and tostring(target) or nil)
end
C_ChatInfo.SendChatMessage = SendChatMessage

function M.deliver_addon(prefix, text, chatType, sender, target, logged)
  if not M.prefixes[prefix] then return false end
  M.fire(logged and "CHAT_MSG_ADDON_LOGGED" or "CHAT_MSG_ADDON", prefix, text, chatType, sender, target or "", 0, 0, "", 0)
  return true
end
local CHAT_EVENTS = { SAY = "CHAT_MSG_SAY", YELL = "CHAT_MSG_YELL", EMOTE = "CHAT_MSG_EMOTE", PARTY = "CHAT_MSG_PARTY",
  RAID = "CHAT_MSG_RAID", RAID_WARNING = "CHAT_MSG_RAID_WARNING", GUILD = "CHAT_MSG_GUILD", OFFICER = "CHAT_MSG_OFFICER",
  WHISPER = "CHAT_MSG_WHISPER", INSTANCE_CHAT = "CHAT_MSG_INSTANCE_CHAT" }
function M.deliver_chat(chatType, text, sender_full, sender_display, guid, is_leader, target_display)
  local ev = CHAT_EVENTS[chatType]
  if not ev then return end
  if is_leader and (chatType == "RAID" or chatType == "PARTY") then ev = ev .. "_LEADER" end
  M.line_id = (M.line_id or 0) + 1
  if chatType == "WHISPER_INFORM" then ev = "CHAT_MSG_WHISPER_INFORM" end
  M.fire(ev, text, sender_full, "", "", sender_display, "", 0, 0, "", 0, M.line_id, guid or "", 0, false, false, false, false)
  M.show_chat_event(ev, text, sender_full, "", "", sender_display, "", 0, 0, "", 0, M.line_id, guid or "", 0, false, false, false, false)
  if chatType == "RAID_WARNING" then RaidNotice_AddMessage(RaidWarningFrame, text) end
end
function M.deliver_whisper_inform(text, target_full, target_display, guid)
  M.line_id = (M.line_id or 0) + 1
  M.fire("CHAT_MSG_WHISPER_INFORM", text, target_full, "", "", target_display, "", 0, 0, "", 0, M.line_id, guid or "", 0, false, false, false, false)
  M.show_chat_event("CHAT_MSG_WHISPER_INFORM", text, target_full, "", "", target_display, "", 0, 0, "", 0, M.line_id, guid or "", 0, false, false, false, false)
end
function M.system_message(text)
  M.line_id = (M.line_id or 0) + 1
  DEFAULT_CHAT_FRAME:AddMessage(text)
  M.fire("CHAT_MSG_SYSTEM", text, "", "", "", "", "", 0, 0, "", 0, M.line_id, "", 0, false, false, false, false)
end

---------------------------------------------------------------------------------------------------
-- AddOns metadata
---------------------------------------------------------------------------------------------------
local function addon_meta(addon)
  if type(addon) == "number" then addon = M.addon_order and M.addon_order[addon] end
  return addon and M.toc_meta[addon]
end
C_AddOns = {
  GetAddOnMetadata = function(addon, field)
    if field == nil then error("Usage: C_AddOns.GetAddOnMetadata(addon, field)", 2) end
    local meta = addon_meta(addon)
    if not meta then return nil end
    return meta[slower(field)]
  end,
  IsAddOnLoaded = function(addon)
    if type(addon) == "number" then addon = M.addon_order and M.addon_order[addon] end
    local l = M.loaded_addons[addon] == true
    return l, l
  end,
  GetNumAddOns = function() return #(M.addon_order or {}) end,
  GetAddOnInfo = function(addon)
    local meta = addon_meta(addon)
    if not meta then return nil, nil, nil, false, "MISSING", "INSECURE", false end
    local name = type(addon) == "number" and M.addon_order[addon] or addon
    return name, meta.title or name, meta.notes or "", true, nil, "INSECURE", false
  end,
  LoadAddOn = function(addon)
    if M.loaded_addons[addon] then return true, nil end
    return false, "MISSING"
  end,
  GetAddOnEnableState = function(addon) if addon_meta(addon) or M.loaded_addons[addon] then return 2 end return 0 end,
  DoesAddOnExist = function(addon) return addon_meta(addon) ~= nil or M.loaded_addons[addon] == true end,
  IsAddOnLoadOnDemand = function() return false end,
  EnableAddOn = function() end,
  DisableAddOn = function(addon, character)
    if addon == nil then error("Usage: C_AddOns.DisableAddOn(name [, character])", 2) end
    M.disabled_addons = M.disabled_addons or {}
    M.disabled_addons[addon] = true
  end,
  GetAddOnDependencies = function() return nil end,
}
function IsAddOnLoaded(addon) return C_AddOns.IsAddOnLoaded(addon) end
M.legacy.GetAddOnMetadata = C_AddOns.GetAddOnMetadata
function GetNumAddOns() return C_AddOns.GetNumAddOns() end
function GetAddOnInfo(a) return C_AddOns.GetAddOnInfo(a) end
function LoadAddOn(a) return C_AddOns.LoadAddOn(a) end

---------------------------------------------------------------------------------------------------
-- Combat log
---------------------------------------------------------------------------------------------------
M.cleu = {}
function CombatLogGetCurrentEventInfo() return unpack(M.cleu, 1, M.cleu.n or #M.cleu) end
C_Seasons = { HasActiveSeason = function() return false end, GetActiveSeason = function() return nil end }

---------------------------------------------------------------------------------------------------
-- Global strings
---------------------------------------------------------------------------------------------------
LOOT_ITEM = "%s receives loot: %s."
LOOT_ITEM_MULTIPLE = "%s receives loot: %sx%d."
LOOT_ITEM_SELF = "You receive loot: %s."
LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."
LOOT_ITEM_PUSHED = "%s receives item: %s."
LOOT_ITEM_PUSHED_MULTIPLE = "%s receives item: %sx%d."
LOOT_ITEM_CREATED_SELF = "You create: %s."
LOOT_ROLL_WON = "%s won: %s"
LOOT_ROLL_YOU_WON = "You won: %s"
LOOT_ROLL_NEED = "%s has selected Need for: %s"
LOOT_ROLL_GREED = "%s has selected Greed for: %s"
LOOT_ROLL_PASSED = "%s passed on: %s"
LOOT_ROLL_ROLLED_NEED = "Need Roll - %d for %s by %s"
LOOT_ROLL_ROLLED_GREED = "Greed Roll - %d for %s by %s"
RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)"
ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
-- an invite's answers to the inviter (enUS GlobalStrings; the harness sends these texts)
ERR_DECLINE_GROUP_S = "%s declines your group invitation."
ERR_ALREADY_IN_GROUP_S = "%s is already in a group."
ERR_BAD_PLAYER_NAME_S = "Cannot find player '%s'."
ERR_FRIEND_ONLINE_SS = "|Hplayer:%s|h[%s]|h has come online."
ERR_FRIEND_OFFLINE_S = "%s has gone offline."
ERR_NOT_IN_RAID = "You are not in a raid group"
ERR_NOT_IN_GROUP = "You aren't in a party."
ERR_GUILD_PLAYER_NOT_IN_GUILD = "You are not in a guild."
ERR_NOT_LEADER = "You are not the party leader."
ERR_RAID_MEMBER_ADDED_S = "%s has joined the raid group."
ERR_RAID_MEMBER_REMOVED_S = "%s has left the raid group."
-- GlobalStrings of the classic_anniversary client (enUS)
ERR_LOOT_MASTER_INV_FULL = "That player's inventory is full"
ERR_LOOT_MASTER_OTHER = "Can't assign item to that player"
ERR_LOOT_MASTER_UNIQUE_ITEM = "Player has too many of that item already"
ERR_LOOT_PLAYER_NOT_FOUND = "Player not found"
ERR_TRADE_COMPLETE = "Trade complete."
LOOT = "Loot"; MASTER_LOOTER = "Master Looter"; GROUP_LOOT = "Group Loot"; NEED_BEFORE_GREED = "Need Before Greed"
FREE_FOR_ALL = "Free for All"; ROUND_ROBIN = "Round Robin"; PERSONAL_LOOT = "Personal Loot"
NEED = "Need"; GREED = "Greed"; PASS = "Pass"; ROLL_DISENCHANT = "Disenchant"; TRANSMOGRIFICATION = "Transmogrification"
OKAY = "Okay"; OK = "OK"; CANCEL = "Cancel"; ACCEPT = "Accept"; DECLINE = "Decline"; YES = "Yes"; NO = "No"; CLOSE = "Close"
NONE = "None"; ALL = "All"; UNKNOWN = "Unknown"; UNKNOWNOBJECT = "Unknown"; DEFAULT = "Default"; ENABLE = "Enable"; DISABLE = "Disable"
SAVE = "Save"; DELETE = "Delete"; REMOVE = "Remove"; ADD = "Add"; EDIT = "Edit"; RESET = "Reset"; SETTINGS = "Settings"
OPTIONS = "Options"; SEARCH = "Search"; FILTER = "Filter"; FILTERS = "Filters"; NAME = "Name"; CLASS = "Class"; LEVEL = "Level"
RANK = "Rank"; NOTE = "Note"; ZONE = "Zone"; STATUS = "Status"; TOTAL = "Total"; ITEMS = "Items"; ITEM = "Item"; DATE = "Date"
RAID = "Raid"; PARTY = "Party"; GUILD = "Guild"; OFFICER = "Officer"; WHISPER = "Whisper"; SAY = "Say"; YELL = "Yell"
PLAYER = "Player"; PLAYERS = "Players"; BOSS = "Boss"; BOSSES = "Bosses"; INSTANCE = "Instance"; DUNGEONS = "Dungeons"
RAIDS = "Raids"; SPECIALIZATION = "Specialization"; TALENTS = "Talents"; CHARACTER = "Character"; SLOT = "Slot"
ITEM_LEVEL = "Item Level %d"; ITEM_LEVEL_ABBR = "iLvl"; ITEM_BIND_ON_PICKUP = "Binds when picked up"
ITEM_BIND_ON_EQUIP = "Binds when equipped"; ITEM_SOULBOUND = "Soulbound"; ITEM_UNIQUE = "Unique"
ITEM_CLASSES_ALLOWED = "Classes: %s"; ITEM_MIN_LEVEL = "Requires Level %d"
HEADSLOT = "Head"; NECKSLOT = "Neck"; SHOULDERSLOT = "Shoulder"; BACKSLOT = "Back"; CHESTSLOT = "Chest"; SHIRTSLOT = "Shirt"
TABARDSLOT = "Tabard"; WRISTSLOT = "Wrist"; HANDSSLOT = "Hands"; WAISTSLOT = "Waist"; LEGSSLOT = "Legs"; FEETSLOT = "Feet"
FINGER0SLOT = "Finger"; FINGER1SLOT = "Finger"; TRINKET0SLOT = "Trinket"; TRINKET1SLOT = "Trinket"
MAINHANDSLOT = "Main Hand"; SECONDARYHANDSLOT = "Off Hand"; RANGEDSLOT = "Ranged"; AMMOSLOT = "Ammo"
FINGER0SLOT_UNIQUE = "Finger 1"; FINGER1SLOT_UNIQUE = "Finger 2"; TRINKET0SLOT_UNIQUE = "Trinket 1"; TRINKET1SLOT_UNIQUE = "Trinket 2"
INVTYPE_HEAD = "Head"; INVTYPE_NECK = "Neck"; INVTYPE_SHOULDER = "Shoulder"; INVTYPE_BODY = "Shirt"; INVTYPE_CHEST = "Chest"
INVTYPE_ROBE = "Chest"; INVTYPE_WAIST = "Waist"; INVTYPE_LEGS = "Legs"; INVTYPE_FEET = "Feet"; INVTYPE_WRIST = "Wrist"
INVTYPE_HAND = "Hands"; INVTYPE_FINGER = "Finger"; INVTYPE_TRINKET = "Trinket"; INVTYPE_CLOAK = "Back"
INVTYPE_WEAPON = "One-Hand"; INVTYPE_SHIELD = "Off Hand"; INVTYPE_2HWEAPON = "Two-Hand"; INVTYPE_WEAPONMAINHAND = "Main Hand"
INVTYPE_WEAPONOFFHAND = "Off Hand"; INVTYPE_HOLDABLE = "Held In Off-hand"; INVTYPE_RANGED = "Ranged"; INVTYPE_THROWN = "Thrown"
INVTYPE_RANGEDRIGHT = "Ranged"; INVTYPE_RELIC = "Relic"; INVTYPE_TABARD = "Tabard"; INVTYPE_BAG = "Bag"; INVTYPE_AMMO = "Ammo"
INVTYPE_QUIVER = "Quiver"; INVTYPE_NON_EQUIP_IGNORE = ""
FACTION_ALLIANCE = "Alliance"; FACTION_HORDE = "Horde"
FRIENDS_LIST_ONLINE = "Online"; FRIENDS_LIST_OFFLINE = "Offline"; GUILD_ONLINE_LABEL = "Online"
KEY_BINDINGS = "Key Bindings"; ADDONS = "AddOns"; GAMEOPTIONS_MENU = "Game Menu"
TOOLTIP_DEFAULT_COLOR = { r = 1, g = 1, b = 1 }
TOOLTIP_DEFAULT_BACKGROUND_COLOR = { r = 0.09, g = 0.09, b = 0.19 }
SPELL_FAILED_NOT_READY = "Not yet recovered"
ERR_NOT_IN_COMBAT = "You can't do that while in combat"

---------------------------------------------------------------------------------------------------
-- Party invites (classic_anniversary): AcceptGroup / DeclineGroup answer the invite the world gave this client
-- (world.invite with auto_accept_invites off fires PARTY_INVITE_REQUEST here). UIParent's pop-up is ported from
-- Blizzard_UIParent/TBC/UIParent.lua and Blizzard_StaticPopup_Game/GameDialogDefs.lua: its OnHide declines an invite
-- it did not accept itself.
---------------------------------------------------------------------------------------------------
function AcceptGroup() if PY and PY.accept_group then PY.accept_group() end end
function DeclineGroup() if PY and PY.decline_group then PY.decline_group() end end
function WillAcceptInviteRemoveQueues() return M.invite_removes_queues and true or false end
INVITATION = "%s invites you to a group."
INVITATION_XREALM = "%s invites you to a cross-realm group."
ACCEPTING_INVITE_WILL_REMOVE_QUEUE = "Accepting this invite will remove you from all queues."
StaticPopupDialogs["PARTY_INVITE"] = {
  text = "%s", button1 = ACCEPT, button2 = DECLINE,
  OnShow = function(dialog) dialog.inviteAccepted = nil end,
  OnAccept = function(dialog) AcceptGroup(); dialog.inviteAccepted = 1 end,
  OnCancel = function() DeclineGroup() end,
  OnHide = function(dialog)
    if not dialog.inviteAccepted then
      DeclineGroup()
      dialog:Hide()
    end
  end,
  timeout = 60, whileDead = 1, hideOnEscape = 1,
}
do
  -- UIParent registers its events before any addon loads, so its handler runs first
  local f = CreateFrame("Frame")
  f:RegisterEvent("PARTY_INVITE_REQUEST")
  f:RegisterEvent("PARTY_INVITE_CANCEL")
  f:SetScript("OnEvent", function(_, event, name, tank, healer, damage, isXRealm)
    if event == "PARTY_INVITE_REQUEST" then
      local text = sformat(isXRealm and INVITATION_XREALM or INVITATION, tostring(name))
      if WillAcceptInviteRemoveQueues() then text = text .. "\n\n" .. ACCEPTING_INVITE_WILL_REMOVE_QUEUE end
      StaticPopup_Show("PARTY_INVITE", text)
    else
      StaticPopup_Hide("PARTY_INVITE")
    end
  end)
end

---------------------------------------------------------------------------------------------------
-- Group Finder (C_LFGList, classic_anniversary vanilla style) as one client sees it: the activities (TBC 5-mans
-- normal + heroic, two raids), this client's listing, and the search results tests set with M.lfg_set_results.
-- CreateListing, UpdateListing, RemoveListing and Search need a hardware event (mock.lua M.in_hw: a click, a key, a
-- menu pick): outside one they are blocked like WoW (ADDON_ACTION_BLOCKED, recorded as an error) and do nothing.
-- The comment box is Blizzard's: CreateListing posts M.lfg_comment (what the player typed there last);
-- ClearCreationTextFields empties it. Activity ids are made up (the real ones are the client's).
---------------------------------------------------------------------------------------------------
Enum.PremadeGroupFinderStyle = Enum.PremadeGroupFinderStyle or { Disabled = 0, Retail = 1, Vanilla = 2 }
local LFG_DUNGEONS = {   -- full name, instance map id: activity 1100 + i (normal), 1200 + i (heroic)
  { "Hellfire Ramparts", 543 }, { "The Blood Furnace", 542 }, { "The Shattered Halls", 540 },
  { "The Slave Pens", 547 }, { "The Underbog", 546 }, { "The Steamvault", 545 }, { "Mana-Tombs", 557 },
  { "Auchenai Crypts", 558 }, { "Sethekk Halls", 556 }, { "Shadow Labyrinth", 555 }, { "The Mechanar", 554 },
  { "The Botanica", 553 }, { "The Arcatraz", 552 }, { "Old Hillsbrad Foothills", 560 }, { "The Black Morass", 269 },
  { "Magisters' Terrace", 585 },
}
local function lfg_activity(name, cat, map, size, heroic, order)
  return { fullName = name, shortName = "", categoryID = cat, groupFinderActivityGroupID = cat * 10,
    ilvlSuggestion = 0, filters = 0, minLevel = heroic and 70 or 60, minLevelSuggestion = heroic and 70 or 60,
    maxLevelSuggestion = 70, maxNumPlayers = size, displayType = 1, orderIndex = order, useHonorLevel = false,
    showQuickJoinToast = false, isMythicPlusActivity = false, isRatedPvpActivity = false,
    isCurrentRaidActivity = size > 5, isPvpActivity = false, isMythicActivity = false, allowCrossFaction = false,
    isHeroicActivity = heroic, isNormalActivity = not heroic, mapID = map, difficultyID = heroic and 2 or 1,
    redirectedDifficultyID = 0, useDungeonRoleExpectations = size == 5 }
end
M.lfg_activities = {}
for i, d in ipairs(LFG_DUNGEONS) do
  M.lfg_activities[1100 + i] = lfg_activity(d[1], 2, d[2], 5, false, i)
  M.lfg_activities[1200 + i] = lfg_activity(d[1] .. " (Heroic)", 2, d[2], 5, true, 100 + i)
end
M.lfg_activities[1301] = lfg_activity("Karazhan", 114, 532, 10, false, 1)
M.lfg_activities[1302] = lfg_activity("Gruul's Lair", 114, 565, 25, false, 2)
M.lfg_entry = nil        -- my listing: { activityIDs, comment, ... }
M.lfg_comment = ""       -- Blizzard's comment box
M.lfg_results = {}       -- [resultID] = { name, class, level, roles, comment, area, activityIDs, numMembers, ... }
M.lfg_result_order = {}
M.lfg_shown = {}         -- the result ids of my last search
M.lfg_log = {}           -- { fn = "CreateListing" | "UpdateListing" | "RemoveListing" | "Search", ... }

local function lfg_copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = type(v) == "table" and lfg_copy(v) or v end
  return o
end

local function need_hw(name)
  if (M.hw_depth or 0) > 0 then return true end
  M.record_error("ADDON_ACTION_BLOCKED: an addon called the protected function '" .. name
    .. "()' outside a hardware event (WoW blocks it and does nothing)", name)
  return false
end

local function lfg_entry_changed() C_Timer.After(0, function() M.fire("LFG_LIST_ACTIVE_ENTRY_UPDATE") end) end

C_LFGList = {
  GetAvailableCategories = function() return { 2, 114 } end,
  GetAvailableActivities = function(categoryID, groupID, filter)
    local out = {}
    for id, a in pairs(M.lfg_activities) do
      if categoryID == nil or a.categoryID == categoryID then out[#out + 1] = id end
    end
    tsort(out)
    return out
  end,
  GetActivityInfoTable = function(activityID)
    local a = M.lfg_activities[activityID]
    return a and lfg_copy(a) or nil
  end,
  RequestAvailableActivities = function() end,
  GetPremadeGroupFinderStyle = function() return Enum.PremadeGroupFinderStyle.Vanilla end,
  IsPremadeGroupFinderEnabled = function() return true end,
  HasActiveEntryInfo = function() return M.lfg_entry ~= nil end,
  GetActiveEntryInfo = function() return M.lfg_entry and lfg_copy(M.lfg_entry) or nil end,
  ClearCreationTextFields = function() M.lfg_comment = "" end,
  CopyActiveEntryInfoToCreationFields = function() if M.lfg_entry then M.lfg_comment = M.lfg_entry.comment end end,
  CreateListing = function(data)
    if not need_hw("C_LFGList.CreateListing") then return false end
    if M.lfg_entry or type(data) ~= "table" then return false end
    M.lfg_entry = { activityIDs = lfg_copy(data.activityIDs or {}), comment = M.lfg_comment or "", name = "",
      voiceChat = "", requiredItemLevel = 0, requiredHonorLevel = 0, duration = 1800, autoAccept = false,
      privateGroup = false, isCrossFactionListing = false, newPlayerFriendly = data.newPlayerFriendly and true or false,
      playstyle = 0, generalPlaystyle = 0, requiredDungeonScore = 0, requiredPvpRating = 0 }
    M.lfg_log[#M.lfg_log + 1] = { fn = "CreateListing", activityIDs = lfg_copy(data.activityIDs or {}),
      comment = M.lfg_entry.comment }
    lfg_entry_changed()
    return true
  end,
  UpdateListing = function(data)
    if not need_hw("C_LFGList.UpdateListing") then return false end
    if not M.lfg_entry or type(data) ~= "table" then return false end
    M.lfg_entry.activityIDs = lfg_copy(data.activityIDs or {})
    M.lfg_log[#M.lfg_log + 1] = { fn = "UpdateListing", activityIDs = lfg_copy(data.activityIDs or {}) }
    lfg_entry_changed()
    return true
  end,
  RemoveListing = function()
    if not need_hw("C_LFGList.RemoveListing") then return end
    if not M.lfg_entry then return end
    M.lfg_entry = nil
    M.lfg_log[#M.lfg_log + 1] = { fn = "RemoveListing" }
    lfg_entry_changed()
  end,
  Search = function(categoryID, filter, preferredFilters, languageFilter, crossFaction, advancedFilter, activityIDs)
    if not need_hw("C_LFGList.Search") then return end
    local want = {}
    for _, id in ipairs(type(activityIDs) == "table" and activityIDs or {}) do want[id] = true end
    M.lfg_log[#M.lfg_log + 1] = { fn = "Search", categoryID = categoryID, activityIDs = lfg_copy(activityIDs or {}) }
    C_Timer.After(0.2, function()
      M.lfg_shown = {}
      for _, rid in ipairs(M.lfg_result_order) do
        local r = M.lfg_results[rid]
        local ok = next(want) == nil
        for _, a in ipairs(r.activityIDs) do if want[a] then ok = true end end
        if ok then M.lfg_shown[#M.lfg_shown + 1] = rid end
      end
      M.fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
    end)
  end,
  GetSearchResults = function()
    local out = {}
    for i, rid in ipairs(M.lfg_shown) do out[i] = rid end
    return #out, out
  end,
  GetSearchResultInfo = function(rid)
    local r = M.lfg_results[rid]
    if not r then return nil end
    return { searchResultID = rid, activityIDs = lfg_copy(r.activityIDs), leaderName = r.name, name = "",
      comment = r.comment or "", voiceChat = "", requiredItemLevel = 0, requiredHonorLevel = 0, hasSelf = false,
      numMembers = r.numMembers or 1, numBNetFriends = 0, numCharFriends = 0, numGuildMates = 0,
      isDelisted = r.delisted and true or false, autoAccept = false, isWarMode = false, age = r.age or 60,
      questID = nil, crossFactionListing = false, newPlayerFriendly = false }
  end,
  GetSearchResultPlayerInfo = function(rid, memberIndex)
    local r = M.lfg_results[rid]
    if not r or memberIndex ~= 1 then return nil end
    local roles = r.roles or {}
    return { name = r.name, level = r.level or 70, areaName = r.area or "Shattrath City",
      className = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[r.class] or r.class,
      classFilename = r.class, specName = nil, assignedRole = "NONE",
      lfgRoles = { tank = roles.tank and true or false, healer = roles.healer and true or false,
                   dps = roles.dps and true or false },
      isLeader = true, isLeaver = false }
  end,
}
C_LFGInfo = C_LFGInfo or {}
C_LFGInfo.CanPlayerUsePremadeGroup = function() return M.lfg_usable ~= false end

-- Tests: what other players have listed (the results of my next search). list = { { name = "Pug" or "Pug-Realm",
-- class, level, roles = { tank, healer, dps }, comment, area, activityIDs, numMembers, age } }.
function M.lfg_set_results(list)
  M.lfg_results, M.lfg_result_order = {}, {}
  for i, r in ipairs(list) do
    local rid = 500 + i
    M.lfg_results[rid] = { name = r.name, class = r.class, level = r.level, roles = r.roles or {}, comment = r.comment,
      area = r.area, activityIDs = r.activityIDs or {}, numMembers = r.numMembers or 1, age = r.age }
    M.lfg_result_order[i] = rid
  end
end

-- Tests: a player in my results takes their listing down (the client tells the addon about that result).
function M.lfg_delist(name)
  for rid, r in pairs(M.lfg_results) do
    if r.name == name then
      r.delisted = true
      M.fire("LFG_LIST_SEARCH_RESULT_UPDATED", rid)
    end
  end
end
