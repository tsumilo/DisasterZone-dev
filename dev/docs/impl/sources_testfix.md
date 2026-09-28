I've finished the Test & Fix pass for Addendum F. All 33 suites pass (the original 30 plus three new ones), `check.py` shows 0 errors and 0 global writes, and the TOC is now 0.4.0. I found and fixed two real bugs and cleaned up two misleading messages.

## (1) Fixes (addon root `C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot`)

- **`Core/BiS.lua`, false "changed during lock" flag (reproduced, then fixed).**
  - **Symptom:** a raider whose spec was never detected who reloads in a locked raid gets flagged by the council.
  - **Cause:** the login timer filled in the empty spec 3 s after login, before the raider's client had learned about the lock.
  - **Fix:** a new `AutoDetectSpec` waits (up to 3 × 5 s) for the raid's rules when you're in a raid and not the loot leader. While locked it leaves the spec alone.
- **`UI/MyBiS.lua`, "Replace all" popup.** If you accepted it after the lock started, the list was correctly left alone but it still printed "Replaced P1 with LoonBestInSlot's … suggestions." It now returns quietly when refused. The auto-detect spec option now only prints "Spec detected" when the spec was actually saved.
- **`Core/Loot.lua` (core agent's cross-file need):** `ItemQualifies` now uses `GetSources(id, "drops")`, so a crafted/rep/badge/PvP item handed out in a raid is no longer auto-recorded as boss loot.
- **`CDLoot.toc`:** Version 0.4.0.
- **Other cross-file needs:** all the test-side ones are handled below. The core agent's optional idea of putting a disabled slot in the demo data is not done, because the council-UI tests compare demo counts.

**Wire compatibility (checked):** the 0.2 fixture's `Store.lua` is byte-identical to 0.3's. It ignores unknown top-level keys, and its shape and hash checks accept `dx`. In a new test, a 0.2 council member stores a list with `dx`, the hash matches, and it relays that list to a 0.4 council member with `dx` still intact. No schema bump was needed. Older clients ignore GS `lk`/`lkAt` and RT `lc`.

## (2) Tests (under `…\scratchpad\tests`)

**Added:**
- **`picker_sources\test_picker_sources.py`, 13 cases:**
  - Data file loaded in the right TOC order with no globals.
  - Default sources are raids + 5-man, and old `scope` callers still work.
  - 18 class/slot/kind combinations, each checked against an independent walk of `ns.Data`.
  - Alliance vs Horde filtering for PvP and side-only reputations.
  - Sections and sub-headers appear in order when sources are ticked; the Reset entry and the "No sources ticked" text work.
  - Source choice kept for the session, across /reload and logout, and repaired if the saved value is damaged; 0.3 SavedVariables get the defaults.
  - Search by profession, specialisation, faction, standing, vendor and season.
  - Source texts, row subtitles and the "Needs 2x Nether Vortex" tooltip line.
  - The phase filter applies to every source; items with no phase count as P1; bad data entries are skipped.
  - `GetSources` scopes, plus the auto-ledger check for the Loot fix.
  - Speed: about 16 ms for the first all-sources call, about 0.6 ms per slot after that.
- **`disabled_slots\test_disabled_slots.py`, 8 cases:**
  - API and `dx` shape, hash coverage, picks kept, survives a relog.
  - Tile menu, greyed tile, "x / 16", enable/disable in all phases, drops onto a disabled tile refused.
  - `MatchItem`, `GetWanters` and the player summary skip the slot; the council shows the "–" cell, its tooltip and the greyed member view.
  - No drop alert or toast for the slot, and it's left out of the council panel; alerts return after re-enabling.
  - Copy phase and LoonBestInSlot suggestions never fill a disabled slot.
  - Validator limits, and a damaged saved `dx` is cleaned up on load.
  - The 0.2 council compatibility case above.
- **`bislock\test_bislock.py`, 16 cases:**
  - The lock reaches everyone: GS fields, one raid chat line, status lines, `/cdl rules`.
  - Every editing API refuses, with one message per 3 s; obtained/equipped/"Mark obtained" still sync.
  - The My BiS banner, greyed controls and picker refusal.
  - A forged edit is flagged across roster, member view, drop panel and `GetWanters`, with a single council warning.
  - A flagged player is not suggested but can still be awarded; a non-council master looter learns the flags through RT `lc`.
  - Unlock clears everything.
  - The lock ends on disband, change of leader, or the raid turning into a party.
  - Only the loot leader can lock: raider and council attempts are refused, a forged GS is ignored, a malformed GS field is dropped without losing the rules, and a lock on PARTY is ignored.
  - The master looter is the loot leader when the raid leader has no CDLoot.
  - A mid-raid joiner learns the lock, and so do reloads of a raider, the leader and a council member.
  - The two regression cases for the fixes above.
  - An edit just before the lock is not flagged.
  - A 0.2 raider in a locked raid can still edit, but the council flags it.

**Changed (only where Addendum F changed behaviour on purpose):**
- **`test_boot`:** `EXPECTED_SETTINGS` gets `pickerSources`; version 0.4.0.
- **`test_slash`:** the help list includes `lock` and `unlock`; version 0.4.0.
- **`test_settings`:** version 0.4.0.
- **`test_mybis`:** three cases moved from the old scope dropdown to the new phase dropdown and Sources checkboxes (default now includes dungeons); new empty-list text; the slot menu has the new divider and the two disable entries.
- **`test_dungeon` and `test_ui_dungeon`:** `picker_dungeon_scopes…` now unticks Raids or 5-man in the Sources dropdown instead of choosing a scope.

## (3) Results

```
bislock__test_bislock                  16 case(s), 16 passed, 0 failed
boot-ui__test_access                   12/12      boot-ui__test_boot        12/12
boot-ui__test_broad                     1/1       boot-ui__test_council_ui  14/14
boot-ui__test_demo                      5/5       boot-ui__test_lootlog      7/7
boot-ui__test_mybis                    16/16      boot-ui__test_perf         3/3
boot-ui__test_settings                  9/9       boot-ui__test_slash        9/9
boot-ui__test_tooltip                   6/6
conformance__test_demo_isolation        7/7       conformance__test_ui_xmodule 11/11
council__test_council_picker           16/16
disabled_slots__test_disabled_slots     8/8
dungeon__test_dungeon                  17/17      dungeon__test_dungeon_core 16/16
grouprules__test_grouprules            12/12
loot-roll: award 17/17, drops 17/17, ledger_auto 9/9, roll_close_core 10/10, rolls 20/20
picker_sources__test_picker_sources    13/13
rollclose__test_rollclose              15/15
sync: council_membership 4, demo_isolation 5, ledger_sync 10, sync_flows 18, sync_hostile 13, sync_traffic 2 (all passed)
ui-dungeon__test_ui_dungeon            10/10
check.py: 31 files, 0 syntax errors, 0 global writes, 2 warnings (pre-existing: UPDATE_MASTER_LOOT_LIST, ChatFrameUtil.OpenChat), 1 info
find_multiret.py: 38 sites, all single-return callees, no hazards (same count as before)
```

The other agents' dev smokes still pass (`smoke_lock` 7/7, `smoke_compat` OK, `test_ui_f` 7/7). `tools\test_harness_selftest.py` has one failure (`test_items_guild_group_units_gear`) that has nothing to do with the addon. The mock's `GetInventoryItemID` now returns two values and that self-test wasn't updated. It lives in `tools\`, which is outside my scope.

**Known limitations, left as designed:**
- A modified client that fakes its list timestamp to just before the lock is not flagged, because of the core's 3 s grace window. The spec defines a forged edit as a direct data change plus commit, and that is detected.
- An edit made up to about 8 s before joining a locked raid can be flagged.
- Flags live in memory, so the leader's own client forgets them after its /reload; other council clients keep theirs.
- 0.2 and 0.3 clients ignore `dx` and the lock.
- The test mock guesses some item slots, for example goggles show up as chests. This affects only the tests, not the game.

## (4) In-game checklist

1. Log in and check the addon version shows 0.4.0 and there are no Lua errors.
2. Open the picker on any slot: the default is Raids + 5-man.
3. Tick Crafted, Reputation, Badge vendors and PvP.
   - While you tick them, check that the Sources button text updates ("Raids + 2 more", "All sources"). The mock can't show this.
   - Headers should read "Crafted — Blacksmithing" with an Armorsmith sub-header, "Reputation — …", "Badge of Justice — G'eras", "PvP — Arena Season 1 (Gladiator)" and "PvP — Honor vendors".
   - Row subtitles look like "Blacksmithing (375) · Armorsmith", "G'eras — 50 badges".
   - Only your faction's Marshal's or General's items appear.
4. Search "blacksmithing", "sha'tar", "g'eras", "season 2". Then /reload and check the ticked sources are kept.
5. Check the phase dropdown: "Only P2" and "All phases" change the crafted, badge and PvP rows too.
6. Right-click a filled tile, choose "Disable slot (P1)":
   - the tile goes grey and reads "Disabled — not needed";
   - progress shows "x / 16" and "1 disabled";
   - a left click offers "Enable slot";
   - dragging an item onto it is refused.
   - Try "Disable in all phases" too.
7. As a council member, the roster shows a dark "–" with the tooltip "Disabled by player". A drop of that item gives no toast for that player and doesn't list them.
8. As raid leader:
   - **Lock:** use `/cdl lock` or the Settings, Council toolbar or drop-panel button. Raid chat gets "CDLoot: BiS lists are locked for this raid." and raiders see the lock banner; edits, spec and the picker are refused, but "Mark obtained" and looting still update.
   - **Forged edit (optional):** with a second account, ~10 s later edit via `/run` (direct data change + commit). Council clients should show ⚠ in the roster, member view and drop rows, plus one chat warning, and a roll must not suggest that player.
   - **Unlock:** `/cdl unlock` clears everything.
9. The lock ends when the raid disbands, the lead moves to someone else, or the raid becomes a party. A /reload by the leader keeps it.

## (5) Changelog (0.4.0)

- **Item picker:** new Sources dropdown with Raids, 5-man dungeons, Crafted, Reputation, Badge vendors and PvP. Raids + 5-man is the default and your choice is remembered. Crafted, reputation, badge and PvP gear is grouped by profession, faction, vendor and season, with the skill, standing, cost and faction shown. PvP items appear for your faction only. The phase filter works on every source.
- **My BiS:** right-click a slot to disable it for one phase or all phases. A disabled slot is greyed out, left out of your progress, the council's counts and drop alerts, and its pick is kept. "Still needed from" now lists Crafted, Reputation, Badges and PvP items.
- **Raid lock:** the raid leader (the raid's loot leader) can lock or unlock every BiS list for the raid with `/cdl lock` / `/cdl unlock` or the buttons in Settings, the Council tab and the drop panel. Locked lists can't be edited, but obtained items still update. Council members see a ⚠ on anyone whose list changes anyway, and those players are never suggested as roll winners.
- **Fixes:** crafted, rep, badge and PvP items handed out in a raid are no longer recorded as boss loot. A /reload during a locked raid no longer falsely flags a raider whose spec had never been set.

All new and changed test files are in `…\scratchpad\tests\` (`picker_sources\`, `disabled_slots\`, `bislock\`, `boot-ui\`, `dungeon\`, `ui-dungeon\`). Suite logs for this run are in `…\scratchpad\tf_e\tf_f_final\`.