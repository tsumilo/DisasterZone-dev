**Final report: Test & Fix agent (Addenda D and E, DisasterZone 0.3.0)**

All 30 suites pass, `check.py` reports 0 errors and 0 global writes, and `find_multiret.py` shows no hazards. The other agents' dev scripts also pass: `smoke_e` 15/15, `mixed_e` 3/3 and `test_ui_e` 6/6.

## (1) Fixes
Addon root: `C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone`.

**Cross-file needs**
- **`Core\Ledger.lua`**
  - The log-sync messages (LW/LG) and `SyncFromDigest` now run only between guild-wide council pairs (new `IsGuildCouncilPair`), matching Sync's manifest rule.
  - Single award messages (`A`) still pass between any council members, so a raid leader's picks share that raid's awards.
  - A raid leader auto-recording loot is kept, per E §29.
  - Before this, a raid-scope pick, possibly from another guild, received the guild's full award history. The new council case catches that; I reverted the fix, confirmed the case failed, then restored it.
- **`UI\MyBiS.lua`:** the phase tooltip now reads "Your group's current phase (set by X / you)" when group rules set the phase.
- **`DisasterZone.toc`:** version bumped to 0.3.0 so 0.2 users see the "newer version" notice. The test version strings are updated.

**Bugs found by the new tests**
- **`Core\Sync.lua` `OnState`**
  - The piggybacked guild council rev (`cg`) was dropped whenever the sender wasn't yet known as council.
  - As a result, a member who joined a guild while online never learned that guild's list.
  - Now the rev is noted before the council gate, and guild members who answer my HELLO are marked as seen, so pushes start once the list arrives.
- **`Core\Guild.lua`**
  - **Rev piggyback (`OnCouncilRevSeen`):** it now only accepts senders who are in the guild roster.
  - **Login query after a guild change:** the login `CQ` is re-armed per guild key (debounced). Before, it was never scheduled again after a guild change.
  - **CQ reply rate limit:** it is now per requester and per rev. Before, a member who logged in again within 60 s after the GM changed the list never got the new one.
  - **Typed names:** new `CanonicalKey` makes `SetGuildCouncil` and `SetMyRaidList` resolve typed names case-insensitively to the roster or group spelling ("dövid" becomes "Dövid-Thunderstrike").

## (2) Tests
**Shared helpers:** new `tests\cdl_council.py`, imported by every suite's common module. It provides:
- `seed_guild_council`: the GM's list stored on every client, replacing the old ambient tag. It only applies to worlds that opt in and respects revs.
- `gm_pick`: a live `SetGuildCouncil` that sends `CG`.
- `raid_pick`, `council_of`, `GUILD_INFO_SPY` and `guild_info_calls`.

**Migrated (intent kept)**
- **Common modules:**
  - `_common.solo(council=, phase=)` replaces `info_text`.
  - `sync/common.new_world(council=COUNCIL)` replaces the tag.
  - `lr_common.setup_council` (used by loot-roll, rollclose, dungeon and ui-dungeon): the rank-0 client picks the rank-1 members.
- **boot-ui:**
  - `test_boot`: late load uses a stored list; version 0.3.0.
  - `test_broad`: the GM picks the officer; the Council tab's new picker view is added to the session.
  - `test_council_ui`, `test_demo`, `test_lootlog`, `test_perf`: seeded list.
  - `test_mybis`: the phase comes from the list.
  - `test_slash`: `rules` added and `guildinfo` removed from the help list.
- **conformance:** both suites seed Alice.
- **sync:**
  - `test_council_membership`: an online GM picks and unpicks.
  - `test_ledger_sync`: a council member leads the raid (a raider leading is now council); guild B's council is seeded, plus a non-vacuity assert.
  - `test_sync_flows`: guild B has an offline GM and a seeded list.
- **dungeon (D semantics):**
  - Plain-member cases now use a party without a loot authority.
  - The "council member enables" case uses a party whose only council member is Bob.
  - `enabler_who_passed_the_lead_can_still_turn_it_off` was rewritten as `…_no_longer_decides`: after the lead passes, the next authority's rules or everyone's personal values apply.
  - The settings case asserts the dungeon control is read-only while someone else sets the rules.
- **ui-dungeon:** council setup added.

**Deleted, with reasons**
- **`tests\guildinfo\` (all 8 cases):** Guild Info writing, backups and popups were removed by E §33.
- **`test_access`:** four tag or rank cases no longer apply under E §31/§33:
  - `council_by_rank_threshold`
  - `council_via_plus_name_and_exclusion_via_minus_name`
  - `late_guild_info_text_applies_tag`
  - `cached_tag_used_until_text_arrives_after_relog`

  They are replaced by cases for GM plus list (not rank), unknown names, roster arrival, and a relog that keeps the stored list and ignores other guilds.
- **`test_access` `promotion_and_demotion_by_guild_rank…`:** replaced by a case showing rank changes don't matter, only the list and a GM handover do.
- **`test_settings`:** two editor cases were removed because the editor and the 500-character limit are gone:
  - `gm_council_editor_writes_the_guild_info_tag`
  - `gm_save_refused_when_guild_info_would_exceed_500_chars`

  They are replaced by "Edit council… → picker → summary on every client" (with the spy) and "40-name, name and phase limits; Guild Info untouched". `non_gm_sees_read_only_council_section` was rewritten.
- **sync `e_demoted_by_rank_while_online`:** replaced by `e_removed_then_picked_again_while_online`.

**Added**
- **`tests\council\test_council_picker.py`, 16 cases covering all of E §34:**
  - the GM picks, and an offline member gets the list from the GM, or relayed while the GM is offline (TOFU);
  - forged, relayed, TOFU, future-rev, malformed and older-rev `CG`s;
  - removal closes the Council tab and whisper gates;
  - raid-scope picks, disband, re-share, leader change, `CRQ` on join and reload, forged `CR`, a pug raid leader;
  - the raid leader's Council tab;
  - the dropdown UI (filter, toggle, Save, Revert, Clear, show offline, raid members first);
  - migration and the one-time notice;
  - the Guild Info spy plus a static scan of the addon source;
  - raid-scope sync;
  - the new ledger scope case.
- **`tests\grouprules\test_grouprules.py`, 12 cases covering D §28 as adjusted by E §33, plus the phase rule, `/dz rules`, party eligibility order, and a mixed 0.2 run.**
- **Fixture `tests\grouprules\addon02\DisasterZone`:** a copy of DisasterZone 0.2.0 used by the mixed test.

## (3) Summary lines
```
check.py: checked 31 file(s): 0 syntax error(s), 0 global write(s), 2 warning(s) (UPDATE_MASTER_LOOT_LIST, ChatFrameUtil.OpenChat, pre-existing), 1 info
find_multiret.py: 38 sites, all single-return callees -> no hazards; no tinsert(<multi-return>) sites
boot-ui: access 12/12, boot 12/12, broad 1/1, council_ui 14/14, demo 5/5, lootlog 7/7, mybis 16/16, perf 3/3, settings 9/9, slash 9/9, tooltip 6/6
conformance: demo_isolation 7/7, ui_xmodule 11/11
council: test_council_picker 16/16      grouprules: test_grouprules 12/12
dungeon: test_dungeon 17/17, test_dungeon_core 16/16      ui-dungeon 10/10      rollclose 15/15
loot-roll: award 17/17, drops 17/17, ledger_auto 9/9, roll_close_core 10/10, rolls 20/20
sync: council_membership 4/4, demo_isolation 5/5, ledger_sync 10/10, sync_flows 18/18, sync_hostile 13/13, sync_traffic 2/2
```

## (4) In-game checklist
**Council picker**
1. As GM: Council tab → "Loot Council". Type part of a name: the list filters, Enter toggles, arrow keys move the highlight, Escape closes.
2. Tick "Show offline members", pick someone, and set a phase. Save & share only becomes enabled after a change.
3. On another character: Settings shows "Guild council (set by GM … · phase Pn)" and the picked member gets the Council tab.
4. Revert, the row "x", and Clear list (with its confirmation).
5. Log a picked character out, change the list, log it back in: it has the new list within about a minute.
6. As a non-officer raid leader: pick two raiders, and check that a guildie outside the raid doesn't see them as council. Disband, lead a new raid (the list is re-shared), then pass the lead.
7. `/reload` a raider mid-raid: the raid council comes back.
8. Nothing should change your Guild Info text. The old CDL{} line can be deleted; the one-time notice says so.

**Group rules**
1. Raid leader sets Roll duration 45 and Raid phase P4: raiders' Settings show "Set by <leader>" with greyed controls, `/dz rules` shows them, and the next roll lasts 45 s.
2. With master loot, a leader who doesn't run DisasterZone, and the ML running DisasterZone: the ML's rules apply.
3. Party: the leader runs `/dz dungeon on` and every member becomes active. A plain member's switch does nothing for the party.
4. Disband: everyone is back on their own values.

## (5) Changelog (0.3.0)
- **Loot Council is picked in DisasterZone:** the Guild Master chooses the guild council from a searchable list of guild members, with a phase. Raid leaders can add council members for their own raid.
- **Guild Info not used:** DisasterZone no longer reads or writes the Guild Information text, so the CDL{…} line can be deleted.
- **Group loot rules:** the raid leader (or master looter) sets roll time, minimum quality, the raid phase and dungeon mode for the group. Everyone else's Settings show "Set by …". New command: `/dz rules`.
- **Fixes:**
  - Joining a guild picks up that guild's council list.
  - Re-login shortly after a council change gets the new list.
  - Raid-only council members share that raid's awards but not the guild's full loot history.
  - The phase tooltip tells guild phase and group phase apart.

Dev aids are in `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\tf_e\` (`run_all.py`, logs in `tf_e\final\`).