# Game packs

From 1.5.5 every minigame is an addon folder of its own, a **game pack**, next to `DisasterZone` in
`Interface\AddOns`. Members keep only the games they play. The launcher installs and removes packs one at a time, and the
release zip holds one folder per pack. The Games hub (`Games/Hub.lua`, `Games/HubUI.lua`) stays in DisasterZone and shows
a poster for every game, installed or not.

| Game id (`Games:Register`) | Folder | Art |
|---|---|---|
| bingo | DisasterZone_Bingo | (none of its own) |
| trainer | DisasterZone_Trainer | (its arenas stay in DisasterZone_Rooms) |
| azeromon | DisasterZone_Azeromon | Media/ |
| chess | DisasterZone_Chess | (none of its own) |
| illidan | DisasterZone_Illidan | Media/ |
| holdtheline | DisasterZone_HoldTheLine | Media/ |

`dev/tools/packs.py` lists them (`PACKS`) and moved the games out of DisasterZone (`packs.py split`). The split is
idempotent: run it again after a merge brings game files to the old places (`Games/<Game>/`, `Media/<Game>/`).

## What a pack looks like

```
DisasterZone_Chess/
  DisasterZone_Chess.toc
  Load.lua          first file: the namespace + the release check (never patched in game)
  Rules.lua ...     the game's own files, each with a folder-qualified line-1 guard
  Done.lua          last file: starts the pack's modules (never patched in game)
  Media/            the pack's art, when it has any
```

The TOC (CRLF line endings):

```
## Interface: 20506
## Title: |cffff8000Disaster|rZone · Karazhan Chess
## Notes: Play Medivh's echo, or a guildmate.
## Dependencies: DisasterZone
## X-DZ-Pack: chess          the game's id
## X-DZ-Kind: game
## X-DZ-Build: dev           release.py writes the pack's stamp here in a release
## IconTexture: Interface\Icons\INV_Misc_Ogrepinata
```

A pack loads at login, after DisasterZone, in folder-name order. It is not load-on-demand: Azeromon, Hold the Line,
Chess and Bingo listen on the guild channel from login.

## How it runs

- **Namespace.** `Load.lua` gives the pack's private namespace a metatable onto the global `DisasterZone`, the same trick
  as `DisasterZone_Rooms/Load.lua`. So `ns.X` reads DisasterZone's modules, and `ns:NewModule` makes DisasterZone modules.
- **Start-up.** DisasterZone's modules get `OnInit` at its own ADDON_LOADED, which comes before the packs load.
  `Done.lua` calls `DisasterZone:PackLoaded(folder, ns)` (`Core/Init.lua`). It runs `OnInit` for the modules the pack
  added, and `OnLogin` too when the login stage has passed.
- **Art paths.** Core art goes through `ns.MEDIA`, the core's `Media\` folder. A pack's own art is built from its folder:
  `"Interface\\AddOns\\" .. addonName .. "\\Media\\"`, where `addonName` is the pack's folder. Never write
  `Interface\AddOns\DisasterZone\Media\...` for a pack's art.
- **One release, matching stamps.** `release.py full` computes each pack's stamp, a hash of its files without its TOC. It
  writes the stamp into the pack's TOC (`X-DZ-Build`) and into `Core/BuildInfo.lua` (`packs = { [folder] = stamp }`).
  `Load.lua` calls `DisasterZoneBoot.CheckPack(folder)` (`Core/Boot.lua`). On a mismatch, the pack is from another
  release: every guard in it returns true, nothing of it runs, and its poster says it needs an update. A development copy
  (build "dev") runs whatever packs it finds. An unchanged pack keeps its stamp, so its folder stays byte-identical from
  release to release.
- **The hub.** `Games.CATALOG` (`Games/Hub.lua`) names all six games. `Games:GetShelf()` is the registered games plus
  stand-ins for the rest, and `Games:PackState(id)` gives one of `ok | missing | off | update | error`. A stand-in poster
  shows grey art, a state kicker and a click that opens "Get the game" (`Games:HowToGet`, plus the releases address to
  copy). The Azeromon and Hold the Line logos have core copies in `Media/Games` (`gen_game_logos.py` keeps them current).
- **Things the core shows for a game** are nil-checked (`ns.Bingo`, `ns.Chess` in `UI/NavMenu.lua`; `ns.AzeroHideout`
  in `Core/RaidLog.lua`). A game's own notification kind belongs in the pack: Chess registers "chessTurn" in `Chess:OnInit`.

## In-game updates

Pack files are tree paths with their folder: `DisasterZone_Chess/Chess.lua`. That one name is used by the guard, the
patch entry and the build id.

An update can carry a pack's Lua: changed, new and deleted files of its TOC. It cannot carry the pack's `Load.lua`,
`Done.lua`, TOC header, art, a new pack or a removed one: those need a full release.

A new file at a pack's end runs at `Boot.EndPack`, from `Done.lua` through `ns:PackLoaded`. A new file before an existing
one runs before that file, as in the core. A patch for a pack that isn't installed simply never runs.

## Tools

- **harness.py** loads the packs next to the addon folder (`packs_for`).
  - `Client(packs=..., packs_off=..., pack_order="early"|"real")`.
  - "early" (the default) runs pack files right after DisasterZone's, so pre-loaded clients hold them too.
  - "real" runs them after ADDON_LOADED, as the client does.
  - `load_files("DisasterZone_Chess/Chess.lua")` loads a pack file with a pack namespace.
- **release.py**
  - `tree_files`, `src_path`, `pack_of` cover the pack paths.
  - `stage_tree` copies and stamps the packs.
  - `check_tree` checks their TOCs.
  - The zip carries every folder plus `Read me.txt`.
  - `publish` passes every zipped folder to the launcher's manifest.
- **check.py / layers.py** check the packs with the addon: the `DisasterZone_` prefix is layer 6, feature Games.
- **testmap**: coverage records pack files with their folder, and `testmap_rec` maps them both ways.
- **ui_audit**: `Games._pretend = { [id] = state }` shows an installed game as missing / off / update. The views
  "Games - not installed", "Games - needs update", "Games - how to get it" and "Games - no games" use it.
- **Generators** (Azeromon art, Hold the Line media and kit, Illidan media) write into the pack folders.

## Adding a game

1. Make `addon/DisasterZone_<Game>/`. In the main checkout, first make the AddOns folder and a junction to it (README).
2. Copy the TOC shape above with a new `X-DZ-Pack` id. List `Load.lua` first and `Done.lua` last, both copied from an
   existing pack.
3. Every Lua file gets the guard `DisasterZoneBoot.Run("DisasterZone_<Game>/<file>", ...)`. `release.py guards add` writes it.
4. Add the game to `PACKS` in `dev/tools/packs.py` and to `CATALOG` in `Games/Hub.lua`. Add its poster logo to
   `Games/HubUI.lua LOGOS`, and to `Media/Games` if the game draws its own.
5. The launcher picks the pack up from the manifest. Add its card art to `launcher/ui/games/`; an unknown id gets a
   generic card.
