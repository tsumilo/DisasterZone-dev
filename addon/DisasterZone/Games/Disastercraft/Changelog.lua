if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Changelog.lua", ...) then return end -- DisasterZone Games/Disastercraft/Changelog.lua
-- ns.CraftChangelog: Disastercraft's "What's new" on the character screen, newest release first. One short,
-- plain line per change (at most ~60 characters).
local addonName, ns = ...

ns.CraftChangelog = {
    {
        version = "0.1", date = "2026-10-08",
        changes = {
            "Azeromon is now Disastercraft: a little World of Warcraft",
            "Pick a class: Warrior, Mage or Priest (Human)",
            "Real-time combat: auto attack, spells, global cooldown",
            "WoW's own spells, ranks, mana, rage and trainers",
            "Bags, gear slots and your stats on the character sheet",
            "Northshire's real quests, loot tables and vendors",
            "Creatures aggro, call friends, flee, and come back",
            "Die, run back as a ghost, and resurrect",
            "Old Pokemon-style saves are gone: everyone starts fresh",
        },
    },
}
