# Adding a zone to Azeromon

A **zone** has two parts:
- a **theme**, which is the zone's look: its tiles in `Game.lua` THEMES (Elwynn, Westfall, Duskwood, Stranglethorn's `jungle`, Redridge, ...);
- the **maps** that use that theme.

This guide lists everything a new zone needs, in the order to do it.

Most per-zone tables fail quietly when a key is missing. You get no mood, no rain, no ambience, Elwynn's battle backdrop, or grass footsteps on a cave floor. Nothing errors, so the gap only shows when someone plays.

**`dev/tests/games/test_azeromon_zones.py` is the safety net.** Run it early and often; it names each missing piece and the file to fix.
- A gap you leave on purpose goes in that test's `ALLOWED` table, with the reason.
- If you add a new per-zone table anywhere, add a step here and a check in that test, in the same commit. That is how this guide stays complete.

All commands run from `C:\Users\emilo\CDLoot-dev\dev` with `luaenv\Scripts\python.exe`. `PACK` means `addon/DisasterZone_Azeromon`, a junction to the live game folder, so every bake lands in the game.

---

## 0. Before any code

1. **Mockup first, and get the user's go.**
   - Build it under `dev/art/casc/zone_mockup/<zone>/` (git-ignored; Blackrock is the model):
     - `region.py`: the design source (maps, species, trainers, items, encounters). `python region.py` checks placement and that everything can be reached.
     - `tiles.py`: the colour changes for the new tiles.
     - `bake.py`: bakes the maps through the game's own baker.
     - `build.py`: builds the page from `template.html`.
   - Publish the page, then build only what the user approves.
   - Maps must be organic, never boxy. Use the `Land` painter in `blackrock/region.py` (blobs, winding roads, ragged edges).
2. **Write the build spec:** `dev/docs/azeromon_<zone>/DESIGN.md`, like `azeromon_blackrock/DESIGN.md`. It fixes the ids every half of the build shares:
   - map ids and themes;
   - species and their `num` range;
   - trainers, badges, items, flags and flights;
   - the interfaces between parts built in parallel.
3. **Work in a worktree** (`/c/Users/emilo/DZ-wt/new_wt.sh`), and commit with explicit paths.
4. **Real WoW only:** creature `display` ids and names from Wowhead (bulk NPC search), and sounds and music from the client by FileDataID.
5. **New art is hand-shaded.** Placements are checked against the real map, not eyeballed.

## 1. The maps

1. **New file `PACK/Maps<Zone>.lua`.**
   - Line 1 is the boot guard (`tools\release.py guards add` writes it):
     ```lua
     if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/Maps<Zone>.lua", ...) then return end
     ```
   - List it in `DisasterZone_Azeromon.toc` (CRLF line endings) after `MapsBlackrock.lua` and before `Game.lua`.
   - **The generators and tests only see maps whose file is in the TOC.**
2. **Each map:** `Maps.<id> = { ... }`. The format is documented at the top of `Maps.lua`.
   - **Required:** `name` and `rows` (rows of equal width).
   - **Usually:**
     - `theme`: none means Elwynn.
     - `outdoor = true`.
     - `music`: a key in `Sound.lua` `S.TRACKS`; none means silence.
     - `edges`, `warps`, `stamps`, `npcs`, `encounters`.
   - **Optional:**

     | Field | What it does |
     |---|---|
     | `coastEncounters` | encounters on `;` shore grass |
     | `cave = { rate = n }` | every open tile can start an encounter; mine ambience |
     | `shallows = { {x,y} }` | `w` tiles you can wade into |
     | `gloom` | caps the sky's brightness; no cloud shadows |
     | `lamps` | lamp posts, lit by the routine clock |
     | `seats` | rooms only: where visitors sit |
     | `signs` | readable signs |
     | `chests` | chests to open |
     | `objects` | interactable tiles; `station` makes a crafting station |
     | `triggers` | story gates and scripted spots |
     | `herbs`, `ores`, `nodes` | gathering nodes |
     | `fishing` | overrides the theme's fish table |
     | `rev` | the map's layout revision (see section 6) |

3. **Tiles.**
   - The legend of tile characters is at the top of `Maps.lua`; `G.Compile` (`Game.lua`) reads them. Besides that legend: `;` shore grass, `R` rock, `S` timber, `D` deck, `s` sand, `L` ladder, and the prop characters in `OVER_CHARS`.
   - A new character goes into `SOLID_CHARS` and `OVER_CHARS`.
4. **Stamps.**
   - Every kind needs `STAMP_SIZE`; a missing kind errors.
   - A building needs `HOUSES` and `IsDoor` for its door.
   - A building with a room needs `inside = <room map>`, or `inn =` for an inn. That gives the inn lute, the window glow and thicker chimney smoke as the room fills.
   - Smoke comes from `UI.lua` `Amb.CHIMNEY_KINDS`.
   - A new composite building also goes in `dev/generators/azeromon_buildings.py`.
5. **Getting there.**
   - **Edges** must point back: if A's east edge goes to B, B's west edge goes to A (the zones test checks).
   - **Story gates:** use an edge's `open`/`closed`, or a trigger, plus a `G:<Zone>Gate` in `Game.lua`.
   - **Warps** are not moved onto open ground, so land them on an open tile.
   - **Gryphons** are hand-coded per NPC (Blackrock's `Gryphons(...)` helper in `MapsBlackrock.lua`) with an `fp_<place>` flag.
   - Each flight also needs an entry in `WorldMap.lua` `W.FLIGHTS`, kept in the same order as the generated `WorldArt.lua` flights. `W.Backfill` hard-codes the `fp_*` flags for old saves.
6. **NPCs.**
   - `role` (inn, rest, shop, stable, gryphon, profession, pettrainer, arena) gives the world-map tags and nameplate titles.
   - `trainer = <D.trainers id>`.
   - Routines are the `day` entries, plus `says` and `lamps`.
   - Inns use `G:InnChoice(...)` and `G:SetRespawn(...)`.
   - Shops use `G:Shop(name, stockId)` with `D.shopStocks[stockId]`.
7. **Interiors.**
   - Give each room a dressing in `azeromon_interiors.py` `DRESSING_OF`; without one it gets the Guild Hall's.
   - Pseudo-rooms used only in routines get a name in `Routine.lua` `R.HOME_NAMES`.

## 2. The theme (only for a new look)

1. **`Game.lua` THEMES:**
   ```lua
   <theme> = { grass1 = ..., grass2 = ..., tall = "<x>tall_", path = "<x>path_", tree = ...,
               wall, rock, fence, rails, water = { ... }, stamps = { kind = art } }
   ```
   Every tile name must exist in `Atlas.lua`; a missing tile draws nothing.
2. **The tiles:** `gen_azeromon_art.py`.
   - **Append only.** Earlier atlas slots must never move. 820 of 1024 slots are used; the build stops with "atlas full".
   - Put the colour changes in a module like `azeromon_blackrock_art.py` (`recipes()`).
   - Hand-shaded props go in `azeromon_props.py` `PROPS`.
   - Optional `<grass1>_forest` and `<grass1>_shade` tiles are the off-map forest fill. If you add them, add them to the hard-coded list in `test_azeromon_ground.py` `the_atlas_has_the_shade_and_shadow_tiles`.
   - A new art module must be added to `gen_azeromon_ground.py` `_src_digest`. Otherwise changing it never makes the grounds stale.

## 3. Bake, in this order

| # | Command | When | Before you run it |
|---|---|---|---|
| 1 | `generators\gen_azeromon_art.py` | new tiles or props | section 2 |
| 2 | `generators\gen_azeromon_beasts.py <species...>` then `generators\gen_azeromon_beast_rim.py` | new species (needs the WoW client) | `Data.lua` species with `display` ids |
| 3 | `generators\gen_azeromon_ground.py` | always after map or tile changes; re-bakes every map | `GROUND_THEMES` and `THEMES` (below) |
| 4 | `generators\gen_azeromon_water.py` | **always after ground**: it copies each map's ground version | nothing (picks maps itself; lava never reflects) |
| 5 | `generators\gen_azeromon_battle.py` | new theme or scene, or after art | `azeromon_battle.py` and the painters (below) |
| 6 | `generators\gen_azeromon_worldmap.py` | new maps, places, roads or flights, or after art | `WorldMap.lua` and the generator's zone tables (below) |
| 7 | `generators\gen_azeromon_steps.py` | only for a new kind of ground sound (needs the client and `pip install soundfile`) | `GROUNDS` / `WET` in the generator |

**Ground (`gen_azeromon_ground.py`).**
- Add the theme to `GROUND_THEMES`, or its maps are never baked.
- Add it to `THEMES`: `g1`, `g2`, `tall`, `path`, `tree`, `walls`, `decor` (flowers, edge, tree, bank), and either a water palette or `water="lava"`.
- Optional keys: `sparse`, `cave=True` with `dark=(r,g,b)`, `vines`, `rails`.
- Lights come from `LIGHT_TILES`; houses get lit windows by stamp kind.
- It deletes every file it didn't just write in `Media/Ground`.

**Battle.**
- In `azeromon_battle.py`:
  - add a `SCENES` entry (the painted backdrop);
  - add `SCENE_OF[theme]`. A map id can override its theme, as `moltencore` does.
- In `gen_azeromon_battle.py`:
  - add the key to the painters list;
  - add a `FLAT` entry for a cave or indoor scene, with its lights;
  - set `dark_sky`, `flies` and `blades` as needed.
- **Spots** are battles that take the place you stood: a pond, lake, road or town.
  - Each needs a `spot_<name>()` painter, the painters list, and the `spots = {...}` string in `write_lua`.
  - `BattleScene.SpotFor` chooses among them.

**World map.**
- In `WorldMap.lua`:
  - `W.PLACES`: every map must be in exactly one place;
  - `W.ZONES` and `W.FLIGHTS`;
  - `W.LABELS` for the zone ribbon.
- In `gen_azeromon_worldmap.py`:
  - `ZONE_IDS` and `SHAPES`;
  - the per-zone tables keyed by `ZONE_IDS` index: lakes, lava, `GROUND`, `PATH`, forest density, `CLIFF`, `TREE`/`STEP` and mountains;
  - `town()` per place.

**What makes a bake stale.**

| You changed | Re-run |
|---|---|
| `atlas.tga` | ground, water, battle, worldmap |
| `azeromon_props.py` | art, ground, battle, worldmap, then water |
| `azeromon_battle.py` | ground, battle, then water |
| `azeromon_interiors.py`, `azeromon_blackrock_art.py`, your new art module | ground, then water |
| any map's rows, stamps, chests, NPC spots or theme | ground, then water |
| edges, warps, `W.PLACES` / `ZONES` / `FLIGHTS` | worldmap |
| a species' `display` | beasts, then beast_rim |

## 4. Life, light and sound

| Table | File | Without it |
|---|---|---|
| `Amb.MOODS[theme]` (tint, motes, `rain = true`, leaves, mist, ash, embers, fireflies) | `UI.lua` | no tint, particles or weather. Without `rain = true` it never rains: no rain sound, no wet footsteps |
| `Amb.GLINT[theme]` | `UI.lua` | Elwynn's water glint |
| `Amb.CRITTERS[theme]` | `UI.lua` | no butterflies or birds |
| dusty themes in `Amb.Steps` | `UI.lua` | no footstep dust off the paths |
| `S.TRACKS[def.music]` | `Sound.lua` | silence |
| `S.BEDS[theme]` (day and night loop) **plus `S.LEN` for each new loop id** | `Sound.lua` | no ambience; a loop with no length restarts every 30 s |
| `S.MAP_BED[map]` | `Sound.lua` | (overrides the theme's bed for one map) |
| `S.WIND_THEMES`, `S.FROG_THEMES`, `S.OWL_THEMES` | `Sound.lua` | no wind at the tree edge, no frogs, no owls |
| `D.fishWaters[theme]` (or the map's `fishing`) | `Fishing.lua` | no fishing, no fish schools, no water lapping, no frogs. Lava zones leave it out |
| `S.THEME_GROUND[theme]` (one of the StepsArt grounds) | `Steps.lua` | grass footsteps; a new kind of tile also needs a `PREFIX` entry |
| `def.lamps`, lantern NPCs, `LIGHT_TILES` | maps, ground baker | dark nights |
| `P.SHOTS` / `MOODS` | `Poster.lua` | (optional: a title-screen and hub-poster shot; needs the map baked) |
| `A.MAPS[map]` | `Aftermath.lua` | (optional: how the world changes after a win) |

`UI.lua` `BATTLE_THEMES` is a legacy fallback that is only used when a painted backdrop can't load.

## 5. Beasts, trainers and rewards

- **Species.** `Data.lua` `D.species`:
  - `num` continues after the highest;
  - `display` comes from Wowhead;
  - evolutions can be an `evolve` level or an `evolveItem`.
  - Then bake (section 3, step 2).
- **Trainers and badges.**
  - Trainers: `D.trainers` (team, lines, `badge`, `class`).
  - Badges: `D.badges` (order); the flag is `badge_<id>`.
  - Titles: `Game.lua` `CLASS_TITLES`, `TRAINER_TITLES`, `NPC_TITLES`.
  - Boss HP: `D.BOSS_HP` / `D.TEAM_HP`, set by running `tests\games\azero_balance.py` (not a test file; run it by hand).
- **Moves and fights.**
  - A boss with its own attack wind-up goes in `FxMoves.lua` `BOSS_FAMILY`.
  - New moves go in `D.moves`.
  - New effect kinds need engine support.
- **Rewards.**
  - `Achievements.lua`: a Naturalist list for the region (`A.<REGION>`) plus its badge achievements.
  - `People.lua` `P.BADGE_VERSES`: the bard's lines.
  - Also `D.raidRares` and `D.shopStocks` (`Data.lua`), and `D.beastDrops` (`Crafting.lua`).
- **Hard-coded in tests** (update them with the zone):
  - `test_azeromon_blackrock_beasts.py`: species total 166;
  - `test_azeromon_worldmap.py`: the exact roads list;
  - `test_azeromon_people.py`: `BADGES`;
  - `test_azeromon_whos.py`: towns with an inn;
  - `test_azeromon_fx.py`: `SHAPES` and `BOSS_FAMILY`.

## 6. Changing a map that has already shipped

- **Saved spots.** A saved spot is moved to the nearest open tile, but a saved respawn (an inn) is not. Write a migration like `G.MigrateGoldshire` and raise `D.SAVE_VERSION` (`Data.lua`).
- **Guildmates.** Raise the map's `rev`, so guildmates still on the old layout show as "elsewhere" (`Net.lua`, `Marks.lua`).
- **Coordinates.** Crafting nodes are saved by `mapId:x:y`, and Aftermath fields are coordinates. Moving them orphans what was saved.

## 7. Tests and looks

1. **`tests\games\test_azeromon_zones.py`**: every theme and map has every piece (section intro).
2. **Free checks.** These cover every map already:
   - `test_azeromon.py`: tiles in the atlas, warps, NPCs on open ground, each road off a map leading into the next;
   - the ground, water, battle-scene and worldmap freshness checks;
   - `every_map_belongs_to_exactly_one_place`;
   - craft nodes, routines on open ground, sound loop lengths, beast art.
3. **A region test** like `test_azeromon_blackrock_world.py`, with a `MAPS` list. It checks:
   - the maps compile with the zone's look;
   - edges, walked both ways;
   - warps lead back;
   - every NPC, sign, object and node can be reached;
   - gates block until their flag is set;
   - gryphons and world-map places;
   - encounter species exist and every new species can be met;
   - fresh grounds and battle scenes;
   - the moods.
   A beasts file goes with it, like `test_azeromon_blackrock_beasts.py`.
4. **Looks.**
   - Add views to `tools\ui_audit_states.py` (`azero_at`, `azero_lit`, `azero_battle`), and look at them:
     ```
     tools\ui_audit.py <out> -k "Games - Azeromon <zone>" --look
     ```
   - Render map views on their own with `-k`, because they pick up a leftover battle when run after the battle views.
5. **Run:**
   ```
   tf_e\run_all.py <out> azeromon
   tools\check.py
   ```

## 8. Release

- **Art.** Art changed means:
  - raise `assetPack` in `addon/DisasterZone/Core/BuildInfo.lua`, and the generators' `ASSET` constants with it (battle, water, beast_rim, steps, and `LIGHT_ASSET` in art);
  - gate the new code with `ns:HasAssets(n)`;
  - ship a full release. Art can't travel as an in-game update; `release.py` refuses.
- **Changelogs.**
  - `PACK/Changelog.lua`: a new top entry with the next version. Lines are 64 characters at most, 11 lines at most.
  - Release notes in `addon/DisasterZone/Data/Changelog.lua`: `area = "games"`, `kind = "new"`, lead and lines 90 characters at most.
- **Plan.** `tools\feedback.py plan add "Azeromon 0.xx: <zone>" --to <version>`.

---

## Checklist

```
[ ] mockup approved; dev/docs/azeromon_<zone>/DESIGN.md written
[ ] Maps<Zone>.lua: guard line, TOC entry; name, rows, theme, outdoor, music, encounters
[ ] edges both ways, gates, warps on open ground, flights (+ W.FLIGHTS order, Backfill fp_ flag)
[ ] stamps: STAMP_SIZE, HOUSES/IsDoor, inside/inn, CHIMNEY_KINDS; interiors: DRESSING_OF
[ ] Game.lua THEMES; new chars in SOLID_CHARS/OVER_CHARS
[ ] art: gen_azeromon_art.py (append), art module in ground's _src_digest, _forest/_shade + test list
[ ] species + display ids -> beasts -> beast_rim
[ ] ground: GROUND_THEMES + THEMES -> bake; then water
[ ] battle: SCENES + SCENE_OF, painter, FLAT / spots -> bake
[ ] world map: W.PLACES / ZONES / FLIGHTS / LABELS + generator zone tables -> bake
[ ] UI: Amb.MOODS (rain!), GLINT, CRITTERS, dust themes
[ ] Sound: TRACKS, BEDS + LEN, MAP_BED, WIND / FROG / OWL
[ ] Fishing: D.fishWaters (not for lava)
[ ] Steps: S.THEME_GROUND (+ PREFIX for new tile kinds)
[ ] lamps, lanterns, Poster SHOTS, Aftermath (optional)
[ ] trainers, badges, titles, BOSS_HP (azero_balance.py), BOSS_FAMILY, achievements, verses, shops, drops
[ ] shipped map changed: migration + SAVE_VERSION, rev, nodes / aftermath coords
[ ] tests: test_azeromon_zones.py green, region world + beasts tests, hard-coded counts updated
[ ] ui_audit views + --look; run_all azeromon; check.py
[ ] assetPack + ASSET constants + HasAssets gate; changelogs; plan item
```
