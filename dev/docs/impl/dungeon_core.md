The core of Addendum B (dungeon mode, 5-man data) and Addendum C (§23.1/§23.2) is in place. Every existing suite passes, the new tests pass, and check.py shows 0 syntax errors and 0 global writes. Two existing tests needed small updates because of the new setting and slash command.

## Files changed
Folder: `C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone`
- **DisasterZone.toc**: `Core\Dungeon.lua` added right after `Core\Util.lua`, `Data\Dungeons.lua` right after `Data\Items.lua`.
- **Core/Dungeon.lua (new, `ns.Dungeon`)**: the dungeon-mode switch.
  - It is a plain table like Util, not a lifecycle module. As a module it would register before DB, and `test_boot` requires ItemDB and DB to be the first two modules.
  - DM send/receive with the gate (sender in my party, and party leader or real council).
  - Sends DM{on} when the setting changes (slash or Settings panel) and I am party leader or council.
  - Re-sends DM{on=true} 3 s after the party changes.
  - Clears `groupEnabledBy` when I leave the group, the group becomes a raid, or the enabler leaves.
  - Fires `DUNGEON_MODE_CHANGED(active)` and prints the spec line on receipt, at most one line per 5 s per sender.
  - `/dz dungeon [on|off|rare|epic|status]`.
- **Core/Util.lua**: `IsDungeonModeActive`, `GetGroupChannel`, `InPartyInstance`, `UnitKey`, `GetPartyUnit`, `GetGroupRole`.
- **Core/DB.lua**: default `settings.dungeon = { enabled = false, quality = 3 }`.
- **Core/Init.lua**: `DUNGEON_MODE_CHANGED` added to the message catalogue.
- **Core/ItemDB.lua**:
  - Dungeon bossRefs carry `ref.dungeon = true` and `ref.raid` = the dungeon table.
  - Sources carry `heroic = true` for heroic-list-only items. Normal sources come before heroic ones, and raid sources before dungeon ones.
  - `GetSourceText` gives "Aeonus · The Black Morass (Heroic)" and short "Aeonus (H)".
  - GUID lookup covers dungeon npc and object IDs; raid IDs win if both list one.
  - `GetCandidates` takes `filter.scope`; rows carry `heroic`; the phase filters apply to dungeons too.
- **Core/Loot.lua**:
  - D is sent on `GetGroupChannel()`. A D on PARTY is accepted only while dungeon mode is active for me.
  - The 5-man quality threshold applies inside party instances while the mode is active.
  - Every parsed loot line goes to `Roll:OnItemLooted` (guarded) before the council check.
  - Council auto entries are recorded in 5-man instances too, with dg.
  - `/dz test` in a 5-man with the mode on simulates a heroic drop of 2–3 items. It uses the current dungeon when the instance ID matches, otherwise a random one.
  - A real dungeon boss drop becomes the "recent kill", because dungeon bosses have no encounter IDs.
- **Core/Roll.lua**:
  - All roll messages go on `GetGroupChannel()`. PARTY is accepted only in dungeon mode.
  - `CanStart`: party leader, master looter or council in dungeon mode. The party RS/RW gate uses leader or ML.
  - `ses.party` marks party rolls. Rolls close and the queue is cancelled on `DUNGEON_MODE_CHANGED`.
  - Addendum C is implemented here, including a guard so an award of an already looted item never hands out a second copy.
  - The award-time conflict resolution for two explicit awards is unchanged.
- **Core/Ledger.lua**:
  - `dg` flag: validated as an optional boolean, and only ever added in Merge.
  - Set automatically in dungeon context by `RecordAuto`, `Award` and `RecordRollAward` (explicit param overrides).
  - `CountSince` ignores dg entries unless asked.
  - `GetEntries` takes `excludeDungeon` / `dungeonOnly`.
  - The digest is unchanged.
- Not changed: Core/Comm.lua (the PARTY gate already works), Core/Demo.lua.

## API added
- **Util**: `IsDungeonModeActive()`, `GetGroupChannel()`, `InPartyInstance()`, `UnitKey(unit)`, `GetPartyUnit(key)`, `GetGroupRole(key)` → rank, isML.
- **Dungeon**:
  - Field: `groupEnabledBy`.
  - Methods: `IsActive`, `IsEnabled`, `GetEnabledBy`, `GetQuality`, `GetQualityName`, `CanTellParty`, `SetEnabled(on)`, `ScheduleResend(delay)`.
- **ItemDB**: `GetDungeons()`, `GetDungeon(key)`, `GetBossRefs(scope)`, `GetSources(itemID, scope)`, `IsDungeonItem(itemID)`, `GetCandidates` with `filter.scope`. With no scope, `GetBossRefs` stays raids only, `GetSources` returns raids + dungeons, and `GetCandidates` stays raids only.
- **Roll**:
  - `OnItemLooted(itemID, key)` → the session or nil.
  - `MarkAwardedExternally(id, key)` → `true`, or `false, "unknown"|"denied"|"queued"|"cancelled"|"awarded"`.
  - Session fields: `via` ("loot"), `looted`, `party`, `lootPrev`.
- **Ledger**:
  - `RecordAuto(itemID, winner, boss, dg)`, `Award(itemID, winner, boss, note, dg)`, `RecordRollAward(..., broadcast, dg)`.
  - `CountSince(key, ts, includeDungeon)`, `IsDungeonContext()`.
- **Loot**: `SimulateDungeonDrop()`.

## Deviations
1. **dg on roll awards** follows the session (`ses.party`) rather than "inside a 5-man instance", so every council client writes the same entry. A party roll outside an instance also gets dg.
2. **Explicit award after a loot-message closure**: a session closed by a loot message (`via == "loot"`) can still be awarded by `Roll:Award`, `MarkAwardedExternally` or an RW. This turns it into a recorded award, with no conflict notice. Without this, the existing test `handed_out_before_confirming_keeps_bis_winner` fails.
3. **Loot-message matching and duplicate copies**:
   - A loot line first resolves an explicit award to the same player that no loot line has matched yet.
   - If an explicit award of copy 2 names the player a loot line had matched to copy 1, copy 1 goes back to "closed".
4. **DM additions beyond the spec**:
   - A DM `{q = true}` (after a /reload in a party) asks the enablers to re-send; older clients ignore it.
   - The group switch also clears when the enabler leaves the party.
   - DM{on=false} clears the switch only when it comes from the enabler or the party leader.
5. **`/dz test` dungeon choice**: it prefers the current dungeon when the instance ID matches, instead of always picking a random one.
6. **Wire compatibility**: 0.2 clients already accept D on PARTY, so in a dungeon-mode party they will show the drops. Their Ledger drops the `dg` field.
7. **Test edits**: `tests/boot-ui/test_boot.py` expects the new `dungeon` default, and `tests/boot-ui/test_slash.py` lists `dungeon` in the subcommands.

## CROSS-FILE NEEDS
- **UI/DropPanel.lua `Award` / "Someone else…"**: when `ns.Roll:GetForItem(itemID, drop.s, copy)` returns a session, call `ns.Roll:MarkAwardedExternally(ses.id, key)`. Only call `ns.Ledger:Award` if it returns false, otherwise the award is logged twice.
- **UI/Council.lua `count()` (~line 407) and `ShowItem` (~line 1861)**: these need `GetSources(id, "raids")`. Otherwise wanted dungeon items are counted under dungeon boss keys the Items tree never shows, and they vanish from "Other / no raid source".
- **UI/RollFrame.lua (~line 78)**: show when `Util.GetGroupChannel() ~= nil`, not raid only. The "(looted)" text is already there.
- **UI/DropPanel.lua**: the panel should open for the party leader in dungeon mode. Roll-mode "Awarded to X (looted)" when `via == "loot"`.
- **UI/LootLog.lua**: "(dungeon)" tag from `e.dg`, and the "Show dungeon loot" filter (`GetEntries{excludeDungeon=true}`).
- **UI/Picker.lua**: scope dropdown, "(5-man)" headers, "Heroic" tag.
- **UI/Settings.lua**: Dungeon mode section. Writing through `DB:SetSetting("dungeon.enabled"/"dungeon.quality")` or `Dungeon:SetEnabled` is enough; the DM goes out automatically.

## check.py
- Owned files (11 incl. Data/Dungeons.lua): 0 syntax errors, 0 global writes, 1 warning (`UPDATE_MASTER_LOOT_LIST`, which was already flagged before).
- Whole addon (29 files): 0 syntax errors, 0 global writes, 4 warnings and 1 info, the same as before.

## Suites (all passing)
- **boot-ui**: access 12/12, boot 12/12, broad 1/1, council_ui 14/14, demo 5/5, lootlog 7/7, mybis 16/16, perf 3/3, settings 9/9, slash 9/9, tooltip 6/6.
- **conformance**: demo_isolation 7/7, ui_xmodule 11/11.
- **loot-roll**: award 17/17, drops 17/17, ledger_auto 9/9, rolls 20/20.
- **sync**: council_membership 4, demo_isolation 5, ledger_sync 10, sync_flows 18, hostile 13, traffic 2.
- **New**:
  - `tests/dungeon/test_dungeon_core.py` 16/16: ItemDB scope/heroic/GUID; DM propagation, gate, re-send, reload query, disband and raid conversion; party D and threshold; party roll → dg ledger entry; `/dz test`; Merge of dg.
  - `tests/loot-roll/test_roll_close_core.py` 10/10: Addendum C cases (a)–(d) plus loot-then-award, wrong-copy reclaim, no second give, open session with the queue, the 15-minute window.
- Logs: `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\out_dungeon\`