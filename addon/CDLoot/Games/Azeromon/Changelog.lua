-- CDLoot Games/Azeromon/Changelog.lua
-- What's new, newest release first. The title screen's WHAT'S NEW shows one release per page and marks the entry
-- "new" until the player has read the newest one (CDLootDB.games.azeromon.changelogSeen).
-- To add a release: put a new table at the top. One short line per change (about 60 characters at most),
-- plain words, what the player notices.
local addonName, ns = ...

ns.AzeroChangelog = {
    { version = "0.7", date = "29 September 2026", title = "Professions and polish",
      lines = {
          "Professions: Herbalism, Mining, Alchemy and Blacksmithing.",
          "Learn two at a time from the trainers in Goldshire.",
          "Gear page on the summary: five slots and a flask.",
          "Stable Masters at every inn keep your extra beasts.",
          "Type chart in the menu; moves say how well they'll hit.",
          "Battle boxes show stat changes, status and turns left.",
          "Key hints, one-time tips and a CONTROLS page.",
          "Right-click goes back. Your class perk shows in the menu.",
          "The move list opens on the move you used last.",
          "Fixed: the no-PP message was hidden; Struggle works.",
          "Fixed: you could walk through ore veins.",
      } },
    { version = "0.6", date = "29 September 2026", title = "Guild life",
      lines = {
          "Daily bounties and a weekly guild goal, on every town's board.",
          "Shiny beasts: about 1 in 400 wears a rare skin.",
          "Trade beasts with guildmates. A traded Tunneler evolves.",
          "Gorvin Wildhammer reminds beasts of forgotten moves.",
          "Emberwhelp evolves into the Flamescale Drake.",
          "The game fills its window; the Games tab shows who's playing.",
      } },
    { version = "0.5", date = "29 September 2026", title = "The Deadmines",
      lines = {
          "Moonbrook and the Deadmines, all the way to Edwin VanCleef.",
          "Achievements, with a toast when you earn one.",
          "Day and night follow realm time. Your class gives a perk.",
          "Raid boss kills let rare beasts roam for a while.",
          "Guild Bestiary and guild leaderboards.",
      } },
    { version = "0.4", date = "29 September 2026", title = "Westfall and friends",
      lines = {
          "See guildmates walking around, and battle them.",
          "Hogger at Forest's Edge, then Westfall and Sentinel Hill.",
      } },
}
