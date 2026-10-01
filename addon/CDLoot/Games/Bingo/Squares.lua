if CDLootBoot and CDLootBoot.Run("Games/Bingo/Squares.lua", ...) then return end -- CDLoot Games/Bingo/Squares.lua
-- ns.BingoSquares: the Council Bingo square pool. Every square is detected automatically from raid events
-- (Games/Bingo/Detect.lua). Deliberately nothing about loot or council decisions.
-- rarity: "c" common, "r" rare, "l" legendary (colour + glow). hint: optional tooltip line.
-- Card art, first that applies: spell = spell id (its icon), item = item id (its icon), icon = a file in
-- Interface\Icons, tex = a full texture path. item2 = small second icon in the corner, badge = text on the icon.
local addonName, ns = ...

local Squares = ns:NewModule("BingoSquares")

Squares.FREE = "FREE"
Squares.FREE_ICON = "Interface\\Icons\\Spell_Fire_SelfDestruct"
Squares.FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

Squares.list = {
    -- deaths
    { id = "death_trash", text = "Someone dies to trash",              rarity = "c", icon = "INV_Misc_Bone_ElfSkull_01" },
    { id = "death_first", text = "A death in the first 30s of a pull", rarity = "r", spell = 1719 },
    { id = "mass_death",  text = "3 deaths within 5 seconds",          rarity = "r", spell = 11113 },
    { id = "five_deaths", text = "5+ deaths in one boss fight",        rarity = "c", spell = 20707 },
    { id = "ten_deaths",  text = "10 deaths tonight",                  rarity = "c", icon = "Spell_Shadow_RaiseDead" },
    { id = "pet_death",   text = "A pet bites the dust",               rarity = "c", spell = 136 },
    { id = "late_death",  text = "Someone dies in the last 10s of a kill", rarity = "r", spell = 20711 },
    { id = "overkill",    text = "Deleted: 5,000+ overkill on a raider", rarity = "r", spell = 5308 },
    { id = "early_release", text = "Premature release",                rarity = "r", spell = 8326,
      hint = "Someone dies and releases while the boss is still up." },
    -- bosses
    { id = "wipe",        text = "Wipe!",                              rarity = "c", icon = "INV_Misc_Bone_HumanSkull_01" },
    { id = "wipe_twice",  text = "Wipe twice on the same boss",        rarity = "r", spell = 603 },
    { id = "instant_wipe", text = "Instant wipe (under 20s)",          rarity = "r", spell = 1449 },
    { id = "boss_kill",   text = "Boss down",                          rarity = "c", icon = "INV_Misc_Head_Dragon_01" },
    { id = "redemption",  text = "Redemption: kill a boss you wiped on", rarity = "c", spell = 7328 },
    { id = "flawless",    text = "Boss kill with no deaths",           rarity = "r", spell = 17 },
    { id = "clutch",      text = "Clutch kill: 5 or fewer alive",      rarity = "l", spell = 12975,
      hint = "Counts in groups of 10 or more." },
    { id = "speed_kill",  text = "Boss dies in under 2 minutes",       rarity = "r", spell = 2983 },
    { id = "long_fight",  text = "Boss fight lasts over 6 minutes",    rarity = "r", icon = "INV_Misc_PocketWatch_01" },
    -- combat
    { id = "bres",        text = "Battle rez mid-fight",               rarity = "r", spell = 20484 },
    { id = "lust",        text = "Bloodlust / Heroism popped",         rarity = "c", spell = 2825 },
    { id = "interrupts",  text = "10 interrupts in one fight",         rarity = "r", spell = 1766 },
    { id = "big_crit",    text = "An 8,000+ crit",                     rarity = "r", icon = "Ability_CriticalStrike" },
    { id = "crushing",    text = "Someone takes a crushing blow",      rarity = "r", spell = 2565 },
    { id = "taunt_resist", text = "A taunt gets resisted",             rarity = "r", spell = 355 },
    -- class moments
    { id = "bubble_hearth", text = "Bubble-hearth",                    rarity = "l", spell = 642, item2 = 6948,
      hint = "A paladin bubbles, then hearths out." },
    { id = "ankh",        text = "Ankh!",                              rarity = "l", spell = 20608,
      hint = "A shaman uses Reincarnation." },
    { id = "feign_wipe",  text = "A hunter feigns out of a wipe",      rarity = "r", spell = 5384,
      hint = "Feign Death in the last 20 seconds before a wipe." },
    { id = "drums",       text = "Drums!",                             rarity = "c", item = 29529,
      hint = "Drums of Battle, War, Restoration, Speed or Panic." },
    { id = "loh",         text = "Lay on Hands",                       rarity = "r", spell = 633 },
    { id = "healthstone", text = "Healthstone chugged",                rarity = "c", icon = "INV_Stone_04" },
    -- environment
    { id = "fall",        text = "Someone takes fall damage",          rarity = "c", spell = 130 },
    { id = "fall_death",  text = "Death by gravity",                   rarity = "l", spell = 1706,
      hint = "Someone dies from fall damage." },
    { id = "fire",        text = "Someone stands in fire / lava",      rarity = "r", spell = 5740 },
    { id = "drown",       text = "Someone drowns",                     rarity = "l", spell = 131 },
    -- rolls (any /roll 1-100 in the raid unless noted)
    { id = "roll_1",      text = "Someone rolls a 1",                  rarity = "l", icon = "INV_Misc_Dice_01", badge = "1" },
    { id = "roll_100",    text = "Someone rolls 100",                  rarity = "l", icon = "INV_Misc_Dice_02", badge = "100" },
    { id = "roll_low",    text = "Someone rolls 5 or lower",           rarity = "r", icon = "INV_Misc_Dice_01", badge = "<6" },
    { id = "roll_69",     text = "Someone rolls 69",                   rarity = "r", icon = "INV_Misc_Dice_02", badge = "69" },
    { id = "roll_42",     text = "Someone rolls 42",                   rarity = "r", icon = "INV_Misc_Dice_01", badge = "42" },
    { id = "roll_doubles", text = "Someone rolls doubles (11, 22 ... 99)", rarity = "c", icon = "INV_Misc_Dice_02", badge = "22" },
    { id = "roll_twins",  text = "Roll twins: same number twice in a row", rarity = "r", icon = "INV_Misc_Dice_01", badge = "==",
      hint = "Two different raiders roll the same number back to back." },
    { id = "odd_roll",    text = "Someone does a non-standard roll",   rarity = "c", icon = "INV_Misc_Dice_02", badge = "1k",
      hint = "Anything other than /roll 1-100, like /roll 1000." },
    -- raid logistics
    { id = "not_ready",   text = "Someone isn't ready at a ready check", rarity = "c", tex = "Interface\\RaidFrame\\ReadyCheck-NotReady" },
    { id = "rc_asleep",   text = "Someone sleeps through a ready check", rarity = "c", icon = "Spell_Nature_Sleep",
      hint = "The check ends while someone online never answered." },
    { id = "rc_all_ready", text = "Everyone ready on the first check", rarity = "r", tex = "Interface\\RaidFrame\\ReadyCheck-Ready",
      hint = "A ready check where every raider clicks Ready." },
    { id = "rc_pull",     text = "Boss pulled during a ready check",   rarity = "l", tex = "Interface\\RaidFrame\\ReadyCheck-Waiting" },
    { id = "idle",        text = "15 minutes without a pull",          rarity = "c", spell = 12051,
      hint = "Nobody in the group fights anything for 15 minutes." },
    { id = "dc",          text = "Someone disconnects",                rarity = "r", tex = "Interface\\CharacterFrame\\Disconnect-Icon" },
    -- raid chat
    { id = "caps_warning", text = "ALL-CAPS raid warning",             rarity = "c", icon = "Ability_Warrior_BattleShout" },
    { id = "sorry",       text = "Someone says sorry in raid chat",    rarity = "c", spell = 20066 },
}

Squares.byId = {}
for _, sq in ipairs(Squares.list) do Squares.byId[sq.id] = sq end

function Squares:Get(id) return self.byId[id] end

local function ItemIcon(id)
    local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
    if not icon and GetItemIcon then icon = GetItemIcon(id) end
    return icon
end

-- Texture (path or file id) of a square's card art, plus its corner icon (or nil).
function Squares:Icon(sq)
    if type(sq) == "string" then sq = self.byId[sq] end
    if not sq then return self.FALLBACK_ICON end
    local icon
    if sq.spell and GetSpellTexture then icon = GetSpellTexture(sq.spell) end
    if not icon and sq.item then icon = ItemIcon(sq.item) end
    if not icon and sq.icon then icon = "Interface\\Icons\\" .. sq.icon end
    if not icon and sq.tex then icon = sq.tex end
    return icon or self.FALLBACK_ICON, sq.item2 and ItemIcon(sq.item2) or nil
end

-- Array of every square id (pool order).
function Squares:Ids()
    local out = {}
    for i, sq in ipairs(self.list) do out[i] = sq.id end
    return out
end
