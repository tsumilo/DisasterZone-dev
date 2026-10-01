**DisasterZone raid-loot database: build report**

All 10 raids are generated and cross-checked against four other installed addons, and the tier-token mapping was found locally and fully verified (nothing built from memory). There is no Lua runtime on this machine, so the Lua file is checked by my own parser only; `luac -p` or an in-game `/reload` is still needed. Nothing was written inside the WoW folder.

**(a) Paths**
- Generator: `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\gen_cdloot_data.py`
- Generated file: `...\scratchpad\DisasterZone_Data_generated.lua` (1,975 lines)
- Report of skips, cross-checks and shared items: `...\scratchpad\gen_report.json`
- Syntax check script: `...\scratchpad\validate_lua.py`
- Runtimes: Python 3.13 (`C:\Users\emilo\AppData\Local\Programs\Python\Python313\python`) and node (`C:\nvm4w\nodejs\node`). No lua, luajit or luac anywhere.

**What was checked**
- **Syntax:** `validate_lua.py` parses the whole file with a strict parser for the few statement forms it uses. It also checks brace balance, unique boss keys and integer IDs, and that every token and upgrade base item is dropped by some boss. Result: OK, 10 raids, 67 bosses, 915 item rows, 838 unique items.
- **Spot-checks:** all pass.
  - Prince Malchezaar: 28770 Nathrezim Mindblade
  - Gruul: 28794 Axe of the Gronn Lords
  - Illidan: 32837 and 32838 Warglaive of Azzinoth
  - Kil'jaeden: 34334 Thori'dal
- **Cross-checks against other addons:**
  - AtlasLoot's own reverse map (`AtlasLootClassic_Data/source-tbc.lua`): 887 of 889 boss attributions match. The 2 differences are Nether Vortex being listed at Vashj and Kael'thas.
  - LoonBestInSlot `ItemSources.lua`: 734 agree, 0 real disagreements once boss-name spellings are aliased.
  - LootReserve `Data.lua`: item sets match per raid. Its extra items are covered by our Tokens table or the supplements below.
  - Questie `tbcItemDB`: every real boss has at least one NPC or chest ID that actually carries loot.

**Structure of AtlasLoot's `data-tbc.lua`**
- **Difficulties** are defined at lines 22–27 as `NORMAL_DIFF`, `HEROIC_DIFF`, `RAID10_DIFF`, `RAID10H_DIFF`, `RAID25_DIFF` and `RAID25H_DIFF`. Raids only ever use `[NORMAL_DIFF]`.
- **Raids** look like `data["X"] = { MapID, InstanceID, ContentType, ContentPhaseBC, items = { boss... } }`.
- **Bosses** have `name = AL["English"]`, `npcID` as a number or a table, and optionally `ObjectID`, `ExtraList`, `nameFormat` or `specialType`.
- **Loot rows** are `{ idx, itemID }` with the item name as a trailing comment. `idx` is the display slot: 1–15 for the left column, 16–30 for the right.
- **Rows that are not items:**
  - Header rows like `{ idx, "INV_Box_01", nil, text }`.
  - Commented-out rows (`--{...}`).
  - Faction variants `[ATLASLOOT_IT_ALLIANCE] = id` (only in the dungeon Keys table).
  - The `T4_SET`/`T5_SET`/`T6_SET` tables, whose numbers are set IDs, not items.
  - Wrath-only entries wrapped in `AtlasLoot:GameVersion_GE(...)`.
  - Other string row types exist in AtlasLoot ("ac", "f", "i", "l", "prof", "set") but none appear in TBC raid tables.

**(b) Counts per raid** (pseudo-bosses: Trash, Patterns, Timed Chests)

| Raid | Phase | Bosses (incl. pseudo) | Item rows | Unique items |
|---|---|---|---|---|
| Karazhan | 1 | 17 | 187 | 175 |
| Gruul's Lair | 1 | 2 | 26 | 26 |
| Magtheridon's Lair | 1 | 1 | 19 | 19 |
| World Bosses (Doomwalker, Kazzak) | 1 | 2 | 20 | 20 |
| Serpentshrine Cavern | 2 | 7 | 99 | 98 |
| Tempest Keep | 2 | 5 | 79 | 78 |
| Mount Hyjal | 3 | 6 | 96 | 96 |
| Black Temple | 3 | 11 | 153 | 153 |
| Zul'Aman | 4 | 8 | 87 | 82 |
| Sunwell Plateau | 5 | 8 | 149 | 140 |

Beyond the shape you gave, the file adds some fields and tables:
- **Raid:** `instanceID`
- **Boss:** `objectIDs`, `encounterID`, `group` ("Opera Event" / "Servant Quarters"), `isTrash`, `isChest`, and `unconfirmed` (a set of disputed item IDs).
- **Extra tables:** `ns.Data.TokenClasses`, `ns.Data.Upgrades` and `ns.Data.TokenArenaExchanges`.

**(c) Skipped rows and why**
- 41 commented-out rows: 13 Badge of Justice in Karazhan and 28 Sunwell "Sunmote" variants. The Sunmote variants are the upgraded items you get by trading the drop plus a Sunmote; they are covered by `ns.Data.Upgrades` instead.
- 6 Badge of Justice rows in Zul'Aman: it's a currency every player gets, never loot-councilled.
- 4 header rows in Zul'Aman's Timed Chest table: kept as Lua comments.
- 8 tier-set tables: their rows are set IDs, not items.
- 1 Wrath-only boss: Prince Tenris Mirkblood.
- Tempest Keep "Legendaries": Kael'thas's fight weapons vanish when you leave, so they aren't real loot.
- Not shipped, because only LoonBestInSlot lists them and Questie shows no drop source:
  - 31323 Don Santos' Famous Hunting Rifle (note: Loon's hunter guides list it as an "Alt" pick)
  - 31333 The Night Watchman
  - 32895 Scroll of the Maelstrom
  - 32896 Scroll of the Sun

**Items added beyond AtlasLoot (tagged in comments)**
- 32386 Magtheridon's Head, the other-faction version. LootReserve, Loon and Questie all list it.
- 16 Black Temple crafting patterns also added to Mount Hyjal trash, per LootReserve.
- The 9 Sunwell bracer/belt/boots tokens added to Eredar Twins and marked `unconfirmed`. Loon and Questie both say the Twins drop them; AtlasLoot and LootReserve don't list them there. To drop them, set `INCLUDE_DISPUTED = False` in the generator.

**(d) Token mapping: found locally and fully verified**
- **Source:** `AtlasLootClassic\Data\Token.lua`, table `TOKEN_DATA.BCC`, entries with `type = 6`. Format: `[token] = { ICONS.PALADIN, id, id, 0, ICONS.ROGUE, id, ... }`, where `0` is a line break and `ICONS.X` marks the class.
- **Coverage:** 54 tokens and 306 tier pieces, covering T4, T5, T6 and the Sunwell bracers, belts and boots.
- **Verification:**
  - 292 pieces agree across three sources: `Token.lua`, AtlasLoot's reverse map (piece → token) and Loon's "Tier Token" entries.
  - The other 14 pieces aren't in Loon but agree in AtlasLoot's two files.
  - Independently, all 54 tokens match LootReserve's token table exactly.
  - There are 0 unverified pieces and 0 conflicts.
- **Quest items** in `ns.Data.Tokens`: Magtheridon's Head 32385/32386 → the four rings, and Verdant Sphere 32405 → the four necks.
- **`ns.Data.Upgrades`** has 28 Sunmote pairs (dropped item → upgraded item); all 28 match LootReserve.
- **`ns.Data.TokenArenaExchanges`** (45 tokens) comes from LootReserve only. There, tier tokens can also be exchanged for Gladiator arena pieces: T4 from patch 2.2, T5 from 2.3, T6 from 2.5. Treat it as single-source.

**LoonBestInSlot `ItemSources.lua` (question 3)**
- Format: `[id] = { Name, SourceType, Source, SourceNumber, SourceLocation, SourceFaction }`, with English strings via `LBIS.L[...]`.
- Source types: Drop 1,420, Profession 759, PvP 689, Tier Token 292, Dungeon Token 253 (badge vendors G'eras / Smith Hauthaa, with the badge cost), Quest 244, Reputation 225, Token 54, Transmute 28, Vendor 2.
- Yes, DisasterZone could ship a generated subset of it to label where non-raid BiS items come from. It has no license file, though, so check before redistributing. AtlasLoot's data is GPL v2, which applies to the file generated here.

**(e) Caveats**
- **Chest encounters:**
  - Chess: `objectIDs = {185119}` (the chest; Questie calls it "Dust Covered Chest"). Its `npcIDs` are the two chess kings from DBM, which carry no loot.
  - Zul'Aman: one "Timed Reward Chests" pseudo-boss. Its `objectIDs` are the four hostage chests from Questie: 186648 Tanzar's Trunk, 186667 Kraz's Package, 186672 Ashli's Bag and 187021 Harkor's Satchel. Which chest holds which item set isn't in any local file. The chest-number comments keep AtlasLoot's 1, 3, 2, 4 order.
- **Opera:** three separate bosses with `group = "Opera Event"`. The 6 shared items appear in all three, and all three use encounter ID 655.
- **Encounter IDs:** taken from the first argument of DBM's `SetEncounterID`. TehBoxLootCouncil and RaidHelper_TBC, installed here, use the same IDs. I dropped DBM's second ID because DBM gives Reliquary and Shahraz the same one (2478). World bosses have no encounter ID and no instance ID, and I set their size to 40.
- **Multi-NPC fights:** `npcIDs` combine AtlasLoot's and DBM's IDs, plus 15550 (Attumen on foot). The NPC that actually carries the loot, per Questie:

  | Boss | Loot is on |
  |---|---|
  | Attumen | 16152 (mounted) |
  | Illidari Council | 22950 |
  | Reliquary | 23420 (Essence of Anger) |
  | Kalecgos | 24892 (Sathrovarr) |
  | M'uru | 25840 (Entropius) |
  | Eredar Twins, Romulo and Julianne | both NPCs |

- **Shared items:** 63 item IDs appear under more than one boss (Opera, the Executioner formula at all six Zul'Aman bosses, Nether Vortex four times, trash shared between SSC/TK, Hyjal/BT and BT/Sunwell, the disputed Twins tokens). DisasterZone needs an itemID → list-of-sources lookup.
- **Drop alerts:** match on the itemIDs actually in the loot window, expanded through Tokens, Upgrades and TokenArenaExchanges, not on which boss died. Some BiS items won't have a known source, so handle that gracefully.
- **Non-equippable items are kept:** patterns, mounts, quest items and gems are in the lists; filter them at runtime if needed.

Also relevant for design: TehBoxLootCouncil, an existing loot-council addon, is installed here and has BiS buttons and an encounter table.