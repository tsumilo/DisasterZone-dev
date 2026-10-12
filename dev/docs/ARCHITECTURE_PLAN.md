# DisasterZone architecture plan (after 1.4.0)

Source of truth for the architecture and codebase-organization run that started 12 Oct 2026. The proposal page with the
evidence is https://claude.ai/artifact/SQ2yXtY2MFB5cLza1FA6iy. The user accepted every recommended default (12 Oct 2026).

Integration branch: `rf/arch` in worktree `C:\Users\emilo\DZ-wt\arch` (base `disasterzone` @ 9466997). Agent worktrees
branch from `rf/arch` with `DZ-wt/new_wt.sh <name> rf/arch /c/Users/emilo/DZ-wt/arch`. The main checkout (live addon
folder) is in use by other sessions: never edit it from this run.

## Decisions (all defaults)

| # | Decision | Taken |
|---|---|---|
| D1 | Folder layout | Layer first, feature second (`Logic/Raids`, `UI/Raids`) |
| D2 | Sync split | All of it: logic never calls Comm; one `*Net` adapter per feature in `Sync/` (P6) |
| D3 | Ownership | Strategy, Polls and Events owners can act from any character of their account (`Guild:SameAccount`), like RaidPlan/Prized/Attendance |
| D4 | Officer debug role | One rule: the debug role only ever applies to me (`IsOfficer(key, not Util.IsMe(key))`), as Events/Polls do |
| D5 | Deleted strategies | The tombstone fix applies to Strategy too (ends the documented "comes back") |
| D6 | Releases | 1.4.1 in-game update (P1), 1.5.0 full (P2-P5), 1.6.0 full (P6-P7) |
| D7 | Single-use TODO pieces | Build the currency bar (Atlas, 2 uses); slider and pips get a justified `uniformity.ALLOW` entry |
| D8 | Saved-data migrations | Stay lazy where they are, documented in DB.lua; no SCHEMA bump |

## Hard rules (every phase, every agent)

- Saved-variable layout must not change (no key renamed, moved or reshaped; no new top-level saved tables).
- Addon-message formats must not change: message types, field names, field order, 6-hex hashes, tie-breaks, message
  class (= channel prefix). Never tighten a validation check, never lower a receive cap.
- Lua 5.1: at most 200 locals per function (main chunk included), 60 upvalues per closure.
- `Core/BuildInfo.lua`, `Core/Boot.lua` (first two TOC files), `Core/Outbox.lua`, `Core/BootEnd.lua` (last two) never move
  or change. Every other Lua file starts with the line-1 guard; `tools/release.py guards add` writes/fixes it.
- Module names (`ns.X`) never change; tests and other files call modules, not files.
- Demo mode keeps working for every feature (made-up data, nothing sent or cast).
- New user-visible behaviour gets a line in `Data/Changelog.lua` under the next version.

## Agent rules (this machine)

- At most 3 agents at a time. Each agent works in its own worktree and runs tools through
  `bash /c/Users/emilo/DZ-wt/dz.sh <worktree> <script> ...` (it sets the addon dir and `DZ_TEST_SLOTS=3`).
- Tests: `dz.sh <wt> tf_e/run_all.py <outdir> [filters]` = change-based selection. Never `--all`. Never rerun a suite
  that passed on the same sources. An agent that edited nothing runs nothing. Wire-touching work also runs
  `sync/test_mixed_versions.py` and the release-only `scale/test_raid_night.py` by name.
- Known failures on the base are listed in `dev/docs/arch/BASELINE.md` (written from the baseline run); only NEW
  failures count.
- UI changes: compare `ui_audit.py --look` renders against renders of the base made in the same order.
- Commit on your branch with a clear message; do not merge into `rf/arch` yourself (the orchestrator does).
- Python file patches here: write bytes (CRLF files exist, e.g. UI/MainFrame.lua is CRLF; keep each file's endings).

## Target layers (load order = layer order)

| L | Name | Folder | May call |
|---|---|---|---|
| 0 | Platform | `Core/` | nothing above |
| 1 | Game data | `Data/` (paths fixed: generators write them) | L0 |
| 2 | Context | `Logic/Context/`, `Logic/Items/` | L0-1 |
| 3 | Feature logic | `Logic/<Feature>/`, `Sim/` | L0-2, earlier features |
| 4 | Sync | `Sync/` | L0-3 |
| 5 | UI | `UI/Kit/`, `Render3D/`, `UI/Shell/`, `UI/Tours/`, `UI/<Feature>/`, `UI/Dev/` | L0-4 (Kit never names a feature) |
| 6 | Games | `Games/` | L0-5, register through the hub |

Feature order inside L3: Context -> Items -> Gear -> Guild extras -> Raids -> Loot -> {Events, Strategy, Combat,
ClassTools}. Upward communication only through `ns:Fire` messages (catalogue in Core/Init.lua), ports
(`ns.Ask:Confirm/Prompt`, `ns.Nav:Open`; without a UI they answer "no"/do nothing) and registries (games, class tools,
loot stats, buff sources).

Folder map: see the proposal page, section "Folder structure". The exact old -> new path list lives in
`dev/docs/arch/MOVES.json` (written in P3, applied by `tools/move.py` in P4).

## Phases

| Phase | Content | Ships as |
|---|---|---|
| P0 | Dev-kit tooling: `check.py --layers` (+ allowlist that only shrinks), bytecode locals/upvalues check, move-aware testmap, `tools/move.py`, module contract headers -> `dev/docs/MODULES.md` | nothing in game |
| P1 | 8 bugs; raid leaders on `DigestSync.RevList`; `rlr`/`av` as registered HELLO fields; hidden tombstones for Events/Polls/Prized/Strategy; GuildBucket adoption | 1.4.1 in-game update |
| P2 | Shared homes + duplication sweep in place (Core/Time, Core/Wire, DB:Scope, Guild:HasRole, Util.Query, Demo:Cast, Comm:Sender, UI:Refresher, toolbar views, loot kit) + the 25 TODO(refactor) | 1.5.0 full |
| P3 | Untangle layers in place: Ask/Nav ports, game registries, Core->UI calls to messages/ports, Context carved out, logic out of UI files, the 5 cycles broken, Kit stops naming features | 1.5.0 full |
| P4 | The move: one scripted commit (`tools/move.py` + MOVES.json) | 1.5.0 full |
| P5 | Split the giant files (wave 1: EventBuilder, RaidPlanUI, EventsTab, EventBoard, DropPanel, Widgets, Core/RaidPlan, Council; wave 2: EventEngine, Roll, StrategyBoard, StrategyMap3D, MeterPanels, PollsTab, Azeromon/UI) | 1.5.0 full |
| P6 | Sync layer: wire code out of the 24 Core files into `Sync/*Net.lua`; DigestSync takes the per-module glue | 1.6.0 full |
| P7 | Contracts on every module, MODULES.md, lints to error, dead functions | 1.6.0 full |

Releases and pushes need the user's yes right before they happen.

## Module contract header (P0 defines the checker; P2+ writes them)

```lua
if DisasterZoneBoot and DisasterZoneBoot.Run("<path>", ...) then return end
-- Module   <ns name> [(<part>)]                     Layer  <n> · <folder>
-- Owns     <saved tables / state it alone writes>
-- Uses     <modules it calls>
-- Fires    <messages>
-- API
--   Mod:Func(args) -> returns            one-line contract
local addonName, ns = ...
```
The line-1 guard keeps its place; the header follows it (old one-line descriptions after the guard become the header).
