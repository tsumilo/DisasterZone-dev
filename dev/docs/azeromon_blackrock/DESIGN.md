# Azeromon 0.25: Blackrock (badges 6 and 7)

The user picked Blackrock from four pitches and approved a walkable deep-dive mockup (2026-10-15): "we should do all
of this". This file is the build spec. The mockup's source is the design's source of truth for maps and numbers:

- `C:\Users\emilo\CDLoot-dev\dev\art\casc\zone_mockup\blackrock\` (git-ignored folder, read it by absolute path)
  - `region.py`: SPECIES, NEW_EVOS, MOVES, RESOURCES, DROPS, RECIPES, ALCHEMY, LEADERS, SIDE, RAID_RARES, and the 8 maps
    (`MAPS[id]`: rows, stamps, objects, signs, nodes/herbs/ores, npcs with lines/teams, edges, warps, encounters
    `(name, display, type, min, max, dayWeight, nightWeight)`, coast). `python region.py` checks placements.
  - `tiles.py`: the recolour functions and the exact tile list (redridge / steppes / gorge / blackrock + nodes + red roofs).
  - `bake.py`: how the maps were compiled + baked through the mock (themes for the baker, LAVA water palette, lava lights,
    cave darkness (150, 118, 112)).
  - `../scenes.py`: the battle backdrops `redridge`, `steppes`, `gorge`, `depths`, `molten` (painted like azeromon_battle.py).
  - The published mockup: https://claude.ai/artifact/P2M8hAZDh4xB1w6PJDRMnj
- User feedback that binds: maps are organic (ragged forest / cliff edges, winding roads, grass clumps), never boxy.
  The game UI now uses Pixelify Sans (done, commit 1feb82c).

## Ids (shared by both halves of the build)

Map ids (new file `Games/Azeromon/MapsBlackrock.lua`, TOC after MapsStranglethorn.lua):
`threecorners`, `lakeshire`, `everstill`, `stonewatch`, `steppes`, `brm`, `gorge`, `brd` (The Imperial Seat),
plus `moltencore` (new, not in the mockup: a small lava cavern, Magmadar's lair, reached from Lothos Riftwaker in `brm`).
Darkshire gets a north gap in its tree row leading to `threecorners` (edge north), gated on `badge_blackwater`.

Themes: `redridge`, `steppes`, `gorge`, `blackrock` (cave). Battle scenes: redridge->redridge, steppes->steppes,
gorge->gorge, blackrock->depths, moltencore->molten.

Species ids, nums 131-166 (region.SPECIES order): blackwhelp, broodling, blackwyrmkin, ragetalon, mongrel, rrbrute,
rralpha, rrmystic, condor, chatter, spitter, rager, torcher, firegut, fgbrute, fgmage, scaldingdrake, firetail,
burningimp, volchan, glassweb, lavaspider, greaterlava, blazing, inferno, magma, obsidian, temperedgolem, heavygolem,
faultygolem, firewalker, fireguard, flameimp, lavasurger, corehound, magmadar.
Existing species used in encounters: tarantula, greatgoretusk, emberworg, netter, tidecaller, eldercroc.
Rares (rare = true, night/day-only encounters): chatter, volchan, faultygolem, lavasurger.
Legendary (new flag `legendary = true`): magmadar, met once per save as a scripted wild battle in `moltencore`
(Lv 62, catchable; if it faints or you run, it comes back next visit until caught).

New evolutions on existing lines: venomweb -> glassweb (Lv 46); mastiff -> corehound (Lv 58);
watcher + item `darkironbar` -> heavygolem (an item evolution, a branch: Lv 60 -> pummeler stays).

Trainer ids (D.trainers): rrpoacher, yowler, bwgrunt, bwshadow, gath (badge `stonewatch`), nef1, nef2 (rival:
Lord Victor Nefarius), dimaster, senator, warden, thaurissan (badge `darkiron`). Teams and lines: region.MAPS npcs.
Badges: `stonewatch` = "Stonewatch Seal" (order 6), `darkiron` = "Dark Iron Signet" (order 7).
Gates: stonewatch north -> steppes needs badge_stonewatch; Lothos -> moltencore needs badge_darkiron.

Moves (D.moves ids): lavaburst, firenova, conflagrate, moltenarmor, bellowingroar, shadowflame, warstomp, slagtoss,
magmashackles, steamjet, burningweb, panic (intent in region.MOVES; new effect kinds are fine where the engine needs them).

Items: greatpotion (Greater Healing Potion, heal 100), truesilverrod (Truesilver Taming Rod, ball 2, sold at Thorium
Point), darkironbar (Dark Iron Bar: crafting mat + evolution item for watcher), elixirfirepower, elixiragility,
fireprotection, freeaction, flaskflowing, darkironale (Plugger Spazzring's prize: full heal one beast).

Crafting: skill cap 100 -> 175. Journeyman (to 150) from Verner Osgood in Lakeshire, Expert (to 175) from Hansel
Heavyhands at Thorium Point, all four professions. Resources iron, gold, mithril, truesilver, darkiron (ores) and
fadeleaf, kingsblood, firebloom, sungrass (herbs). Dark Iron smelts only at the Black Forge (an object in `brm`).
Beast drops after won wild battles (region.DROPS). Recipes: region.RECIPES + region.ALCHEMY.

Raid rares: Core Hound (Magtheridon kill) in `steppes` Lv 55; Lava Surger (Al'ar kill) in `gorge` Lv 56.

Towns / services: Lakeshire (inn, shop, stable, gryphon Ariena Stormfeather, Journeyman trainer, bounty board),
Morgan's Vigil in the Steppes (gryphon Borgus Stoutarm, rest), Thorium Point in the Gorge (gryphon Lanie Reed,
Expert trainer, shop with the Truesilver rod). Flights: Lakeshire, Morgan's Vigil, Thorium Point join the network.

Changelog 0.25 lines, achievements (Naturalist: Blackrock, the two badges, Magmadar), bounties for the new beasts:
the orchestrating session writes the changelog.

## Interfaces between the two halves (world / beasts+crafting)

- Shops: map NPCs call `G:Shop(name, stockId)`; stockId `"lakeshire"` (adds greatpotion) and `"thorium"` (adds
  truesilverrod, fireprotection). The beasts half adds `D.shopStocks[stockId]` and the optional second argument
  (no stockId = `D.shopStock` as before).
- Legendary: the `moltencore` map has an object/NPC at Magmadar's spot whose script calls
  `G:LegendaryBattle("magmadar", 62)`; it is hidden once `G:Flag("caught_magmadar")`. The beasts half implements it.
- Trainer NPCs use `trainer = "<id>"` with the ids above; leaders `hidden = Vanished(id)` like Kurzen.
- Profession trainers: NPC scripts call `G:ProfessionTrainer("journeyman")` / `G:ProfessionTrainer("expert")`
  (beasts half implements; falls back to the existing trainer screen).
- The Black Forge: an object `{ tile = "forge", station = "blackforge" }` in `brm`; recipes needing it check
  `station == "blackforge"` (beasts half).
