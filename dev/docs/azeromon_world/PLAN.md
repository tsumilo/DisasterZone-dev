# Azeromon on the real Eastern Kingdoms (started 2026-10-08)

User request: remake Azeromon so the overworld matches WoW's real maps 1 to 1 (zones, POIs, NPCs, hubs, cities,
mob placements, levels), start in Northshire, scenarios from each zone's real quests. All current zones (Elwynn /
Goldshire, Westfall, Deadmines, Duskwood, STV to Booty Bay) remade, plus Stormwind City. No Redridge for now.
Fresh saves. Evolutions = real higher-level variants of the same family. Catchable = non-player races and beasts
(kobolds, murlocs, gnolls, trolls, undead...); humans / orcs etc. are fought, never tamed.

Step order (each shipped for an in-game look before the next): 1 pipeline + Northshire, 2 Elwynn + Goldshire,
3 Stormwind, 4 Westfall + Deadmines, 5 Duskwood, 6 STV.

## Sources (all offline once fetched)
- Terrain, water, ground textures, doodads, WMOs: the installed client via casc_local (adt_tools.py, azw_raw.py,
  azw_wmo.py). Maps are split ADTs (root / _tex0 / _obj0), files referenced by FileDataID.
- Spawns, NPC names/titles/flags/levels/factions, waypoints, quests, gossip: cMaNGOS tbc-db full dump
  (dev/art/tbcdb, git-ignored; tbcdb.py parses it into tables.pickle).
- Area names: wago.tools AreaTable CSV (build 2.5.6.69795) in dev/art/tbcdb/db2.

## Grid
One tile = one cell of an ADT chunk's 8x8 grid = 533.333/128 = 4.1667 yd. World grid gx (east) / gy (south) from
the map's north-west corner; gx = (17066.67 - world_y) / TS, gy = (17066.67 - world_x) / TS. At this scale a human
house is ~4x3 tiles and a person 1 tile: Pokemon proportions with nothing stretched. Walking 4 tiles/s = 16.7 yd/s
(WoW run speed 7 yd/s), so Elwynn takes ~3.5 min to cross on foot.

## WMO placement (verified)
local (x, y, z) -> placement (x, z, -y), turned about the vertical by rot.y - 90 deg (Noggit). 81/93 Elwynn WMO
root boxes land on their MODF extents within 1 yd (the rest are tilted / symmetric).

## Design decisions (mine, to show the user)
- The overworld is ONE seamless map ("world") read lazily from 32x32-tile blocks; zones come from the ADT area IDs
  (banner + music on change). Interiors (WMO buildings, caves) stay separate small maps with warps.
- Walkable = WoW walkable: slope < 50 deg (WoW's limit) and not deep water; cliffs drawn as rock faces.
- Mobs are visible on the map at their real spawn points (wander radius = spawndist, respawn = spawntime) instead
  of tall grass; walking into one, or a hostile one noticing you (aggro radius), starts the battle. Every mob is a
  battle species; only the catchable ones can be tamed. Humans (Defias Thug) are fought directly.
- NPCs stand where they stand in WoW with their real name, <title>, role from NpcFlags (vendor -> shop, innkeeper ->
  heal + respawn, stable master, flight master, trainer, quest giver) and their real gossip text.
- Quests are generated from the DB (title, giver, ender, texts, objectives) into a generic quest engine: kill
  objectives = win battles against that creature, item objectives drop from those battles, talk / explore objectives.
- Species come from the creatures themselves (display ID from creature_template.DisplayId1, type/family -> element),
  stats from family + level; evolution chains hand-picked from real variants of a family.

## Open questions for the user
- Starter beasts: the old trio (whelp / murloc / bloodpetal) were imported gifts. Northshire natives are Young Wolf,
  Kobold Vermin, Timber Wolf, critters. Asked at the end of step 1.

## Status 2026-10-08 (step 1: pipeline + Northshire, first in-game test by the user)
Art direction changed mid-step at the user's request: EVERYTHING from WoW's own art, coherent, high res
("it could be more high res, too hard to make out"):
- Ground: azw_ground.py - WoW's terrain textures, blended at tile CORNERS (top-2 textures per corner, 5 levels,
  shared by the 4 tiles around a corner => seamless), 32 px a tile, deduplicated into DXT1 pages
  Media/Azeromon/Ground/<region>_<n>.blp; per-tile 3-char codes in the blocks. Water = WoW lake texture over it.
  (Rejected on the way: 16 px pixel tiles - mush; per-tile texture pairs + VQ masks - square seams.)
- Scenery: azw_scenery.py + azw_render.py (software rasteriser of M2 / WMO with their textures) - every doodad and
  building as a sprite (DXT5 pages Media/Azeromon/Scenery/), OBLIQUE projection (ground plan = map, heights lean up)
  so footprints line up with collision. Renderer yaw = placement rot.y - 180 (verified against MODF transform).
  Trees: one sprite per model, scaled per placement; only tree crowns fade near the player.
- Interiors: the WMO's own floors (clip at head height; caves drop down-facing faces) per level, art drawn under.
- People/creatures: azw_people.py - character models with their BAKED NPC skin (CDIE.BakeMaterialResourcesID ->
  TextureFileData), hair/beard geosets, item geoset groups; creatures with texture variations; one scale
  (15 px/yd); walk frames from the model's own Walk sequence (azw_render.posed_vertices, .anim via AFID).
  Player sprite by UnitRace/UnitSex (a class trainer of that race as the look). Sheet Media/Azeromon/mobs.blp.
- UI: world view fills the whole panel (view frame clips, odd tile counts), depth sorting of scenery + people
  (32 slots BORDER/ARTWORK by y), WoW quest markers (GossipFrame icons, grey/yellow ! ?), QUESTS menu (log).
- Critters (type 8/12) are ambient (k="critter"): not fought, never block. Small props walkable.
- Media size Northshire ~ 30 MB (ground ~7, scenery ~11, interiors ~16 pages!) - interiors need shrinking before
  Elwynn (lower res / tighter crop).

- Class outfits (for Disastercraft): azw_people.outfit / outfit_frames dress a player model from item IDs (skin
  sections painted, item geosets, weapon/shield on attachments 1/0); D.CLASS_SPR in Species.lua (human,
  CharStartOutfit). azw_render.open_blp decodes palettised BLP alpha (Pillow reads it as 0).

Open items / next:
- User: "can't reach certain places because of how the movement works" - ask for the spots (reachability audit
  shows the valley floor ~89% reached; eastern cliffs are cut off as in WoW).
- Starters (Young Wolf / Kobold Vermin from Eagan) and rival: ask the user.
- Herb/ore nodes still Red Voxel tiles: render their GO models.
- Old suites (test_azeromon*.py) run on LEGACY_START via _azero_bot; not re-run after the UI changes.
