**DisasterZone 0.5.0: fixer report**

All 51 findings are dealt with: 44 fixed and 5 fixed in part, with the rest skipped for a stated reason (1 skipped outright; 2 of the partial fixes skip one piece). All 34 suites are green, including the new regression suite `tests\regressions\test_final_review.py` with 44 cases. Of those 44 cases, 42 fail on the untouched 0.4.0 code, so they really catch the bugs; the other 2 cover mock-only behaviour. The TOC is now 0.5.0 and the wire protocol is unchanged (still 1, no new message fields), so 0.2–0.4 clients still talk to it.

Paths: addon `C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone` (0.4.0 backup and full diff in `scratchpad\fixer\orig_040` and `scratchpad\fixer\final.diff`). Scratchpad = `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad`.

Note for the docs agent: the new `Data\ItemClasses.lua` is generated from AtlasLootClassic `Requirements.lua` (GPL v2), so NOTICE.md needs an entry. Two changes go against the spec text and should get an addendum:
- **Guild council list:** a list from the GM now replaces an unconfirmed (trust-on-first-use) list even at a lower rev, unlike Addendum E §31.
- **Drop messages:** under master loot, a drop message from a plain raider is no longer trusted (SPEC.md:412).

### 1. Findings

| id | status | files |
|---|---|---|
| disenchant-loot-broadcast-as-boss-drop | fixed: loot from items (disenchant, prospecting, lockboxes, bags) and fishing loot is skipped; trade goods and gems that no boss drops are skipped; receivers ignore such drops from older clients. Mounts and Nether Vortex are still tracked. | Core/Loot.lua, Core/ItemDB.lua |
| ledger-view-cached-empty-before-guild-name | fixed: the cached award-log view is rebuilt once the guild name arrives | Core/Ledger.lua, Core/Guild.lua, Core/Init.lua |
| escape-restore-popup-overwrites-newer-copy | fixed: Escape only closes the popup; only a real "Keep mine" click replaces the council's copy. Mock now behaves like Blizzard's Escape and busy-popup handling. | Core/Sync.lua; wowmock/ui.lua, harness.py |
| awards-untagged-before-guild-name | fixed: awards and log entries from before the guild name is known are kept, tagged later and sent (again after the login sync) | Core/Ledger.lua |
| stale-ml-flag-rt-not-sent | fixed: master-looter changes are picked up without a roster change | Core/Util.lua, Core/Roll.lua |
| mock-ismodifiedclick-noarg | fixed in the mock (the addon itself was already correct) | wowmock/game.lua |
| relay-poison-raidscope | fixed: other players' lists are only taken from guild-wide council; a relayed rev far above the stored one is refused; the owner's own push repairs a forged copy; list restores only come from guild council the player asked | Core/Sync.lua, Core/Store.lua |
| award-inject-any-council | fixed: award messages are whisper-only; a raid-scope sender may only add entries under its own name and only touch awards from the last 12 h; future times are refused; void times are clamped and poisoned ones repaired; forged roll-award ids are refused; award times in roll-win messages are bounded | Core/Ledger.lua, Core/Roll.lua |
| cg-tofu-takeover | fixed: lists taken on trust stay unconfirmed and are never passed on; the GM's own list replaces them; the GM's client ignores relayed copies of its list; future-rev slack cut from 300 s to 60 s | Core/Guild.lua, Core/Sync.lua |
| lock-detect-backdated-ts | fixed as a soft warning (what the verifier recommended; nobody loses a suggestion) | Core/Store.lua, UI/DropPanel.lua |
| rw-at-override | fixed: "handed out" only counts from the master looter; a second award is only resolved when it arrives within 30 s; award times are bounded | Core/Roll.lua |
| drop-preclaim-any-raider | fixed: under master loot, drop messages are trusted only from the ML, leader, assistants or council; the ML always broadcasts | Core/Loot.lua |
| decode-cost-storm | fixed: payloads that decompress too far are refused and the sender is ignored for the session | Core/Comm.lua |
| rs-backdated-preempt | fixed: roll start times are bounded to −60/+10 s; a roll open for more than 10 s is never pre-empted | Core/Roll.lua |
| query-debounce-starvation | fixed: council and rules queries are answered at once (at most one answer per 5 s) and never delay the leader's own list | Core/Guild.lua, Core/GroupRules.lua |
| crossguild-whisper-gate | fixed for roll tiers only (the rest is not needed) | Core/Comm.lua |
| ledger-strings-unsanitized | fixed | Core/Ledger.lua |
| copy2-frozen-tier-suggests-previous-winner | fixed: winners of the other copy are demoted, also for a non-council ML | Core/Roll.lua |
| ml-give-refused-recorded-as-given | fixed: an award is recorded only once the server hands the item over; a refusal or no answer within 5 s offers "Award anyway". Mock hand-out now answers asynchronously, can be refused, and uses the real error strings. | Core/Loot.lua, Core/Roll.lua; wowmock/game.lua, harness.py |
| split-raid-awards-bleed-into-drop | fixed: each drop remembers who was in the group; the panel and "Roll all" use the same matching | Core/Loot.lua, Core/Ledger.lua, Core/Roll.lua, UI/DropPanel.lua |
| view-phase-override-changes-suggestion | fixed: roll tiers use the group's phase; a council starter also sends tiers to a non-council ML | Core/Store.lua, Core/Roll.lua |
| earlier-phase-pick-ranks-as-bis | fixed for the disabled-slot case; ranking of outdated picks left as the agreed spec (loot-policy question) | Core/Store.lua, Core/BiS.lua |
| loot-message-contradicting-award-not-reconciled | fixed: flagged in both orders when no spare copy exists; one-click "passes it on" / "keeps it"; voiding an auto entry voids its duplicates | Core/Roll.lua, Core/Ledger.lua, UI/DropPanel.lua |
| demo-purge-deletes-real-awards | fixed: only entries older than 2026-09-29 00:00 UTC | Core/Ledger.lua |
| auto-entry-boss-key-is-last-encounter | fixed: boss taken from the drop that held the item | Core/Loot.lua |
| typed-accented-name-phantom-key | fixed: accent-aware name matching and capitalisation | Core/Util.lua, UI/DropPanel.lua |
| council-items-award-bypasses-roll | fixed: goes through a live roll when there is one | UI/Council.lua |
| award-click-closes-roll-before-confirm | fixed by labelling ("End roll & award to X") and a confirmation before a re-roll that discards rolls; deferring the close was rejected because it causes a wrong hand-out race | UI/DropPanel.lua |
| drop-panel-auto-attach-dead | fixed, with side choice at the screen edge | UI/DropPanel.lua |
| floating-panel-jumps-per-roll | fixed: rows are reserved while a roll is open | UI/DropPanel.lua |
| rollall-winner-not-told | fixed | UI/RollFrame.lua |
| trash-drop-hijacks-panel | fixed: trash loot goes to the trash entry or no boss; a panel with a roll in progress stays put and the pager shows "new" | Core/Loot.lua, Core/ItemDB.lua, UI/DropPanel.lua |
| award-menu-absent-wanters | fixed: absent wanters go under "Not in raid (n)" | UI/DropPanel.lua |
| search-dropdown-focus-trap | fixed | UI/Widgets.lua |
| roll-more-rows-not-awardable | fixed | UI/DropPanel.lua |
| esc-closes-drop-panel-no-reopen | fixed with a Drops button and Shift-click on the minimap icon; key binding skipped (needs a new Bindings.xml) | UI/Council.lua, UI/MainFrame.lua |
| popup-overlap-floating-panel | skipped: no default position avoids the popup, toast, unit/raid frames and action bars at all resolutions; the ML case is covered by the loot-window attach and reserved rows; both windows are draggable and remembered | none |
| text-truncation | fixed | UI/DropPanel.lua, UI/Council.lua, UI/RollFrame.lua, UI/LootLog.lua |
| tooltip-wear-clutter | fixed: "Wearing" lines only while Shift is held | UI/Tooltip.lua |
| count-wording | fixed: "N want" / "wanted by N" | UI/DropPanel.lua, UI/Tooltip.lua |
| index-rebuild-churn | fixed: awards and bag changes no longer rebuild the wanted-item index; own obtained state is read live; online flips don't rebuild | Core/Store.lua, Core/Guild.lua |
| ledger-unbounded | partly: login cleaning keeps entries in place and the view builds more cheaply; pruning and archiving skipped because it would lose "already awarded" history | Core/Ledger.lua |
| auto-award-k2-fanout | fixed: random delay, cancelled when an earlier entry for the same loot line arrives | Core/Ledger.lua |
| ledger-catchup-per-peer | fixed: each day is asked from one peer; newest days first | Core/Ledger.lua |
| roster-rebuild-garbage | fixed: roster updated in place; the automatic re-request is kept | Core/Guild.lua |
| class-restricted-raid-drops-usable-by-all | fixed: new generated data for 910 class-restricted items; such wanters show "can't use" and are never suggested | Data/ItemClasses.lua (new), DisasterZone.toc, Core/ItemDB.lua, Core/Store.lua, Core/Roll.lua, Core/BiS.lua |
| sources-class-restricted-pvp-rep | fixed: same data, plus class names on picker rows | UI/Picker.lua |
| token-wanter-no-class-guard | fixed | Core/Store.lua, Core/Roll.lua, Core/BiS.lua |
| arena-exchange-patch-gate-ignored | fixed: T6 → Season 3 exchange off until raised | Core/ItemDB.lua |
| phase-disagreements | partly: 16 items corrected in the data and pinned in the generator; G'eras P3/P4 and the Friendly Band of Eternity skipped because the sources conflict (Questie documents the P2 ring quest) | Data/Sources.lua, gen_cdloot_sources.py |
| mock-equiploc-fidelity | fixed: 99 inventory types plus quality fixes (legendaries, Medallions, alchemist stones, Void Crystal); slot self-check added to the regression suite | wowmock/items.lua, items_fallback.json, fixer/fix_mock_items.py |

**Tests whose expectations changed on purpose:**
- **Version string:** test_boot, test_settings, test_slash.
- **Council list:** test_council_picker (the GM ignores relays of its own list).
- **Trash rule:** test_dungeon.
- **Drops:** test_drops (raider drop under master loot; toast line).
- **Auto entries:** test_ledger_auto and test_ledger_sync (delayed broadcast).
- **Popup and roll texts:**
  - test_rollclose: conflict flag and "You won it!".
  - test_award, test_roll_close_core, test_ui_dungeon: "You won it!".
  - test_rolls: re-roll confirmation.
- **Tooltip wording and Wearing lines:** test_tooltip, test_perf, test_ui_xmodule.
- **Picker:** test_picker_sources (Medallions are now trinkets; class tags).

Two tool edits: `tf_e\run_all.py` no longer crashes on output encoding, and `tools\check.py` now accepts `IsFishingLoot` (Blizzard's own LootFrame.lua on this client uses it).

### 2. Verification

- **check.py:** `-- checked 32 file(s): 0 syntax error(s), 0 global write(s), 2 warning(s)`. Both warnings were already there in 0.4.0: `UPDATE_MASTER_LOOT_LIST` and `ChatFrameUtil.OpenChat`.
- **find_multiret.py:** 38 sites, the same as 0.4.0; the two new call sites are parenthesised.
- **test_harness_selftest.py:** `-- 13 test(s), 0 failed`.

All 34 suites passed (rc=0):
```
bislock 16/16 · access 12/12 · boot 12/12 · broad 1/1 · council_ui 14/14 · demo 5/5 · lootlog 7/7 · mybis 16/16 · perf 3/3
settings 9/9 · slash 9/9 · tooltip 6/6 · conformance demo_isolation 7/7 · ui_xmodule 11/11 · council_picker 16/16
disabled_slots 8/8 · dungeon 17/17 · dungeon_core 16/16 · grouprules 12/12 · award 17/17 · drops 17/17 · ledger_auto 9/9
roll_close_core 10/10 · rolls 20/20 · picker_sources 13/13 · regressions/final_review 44/44 · rollclose 15/15
council_membership 4/4 · sync demo_isolation 5/5 · ledger_sync 10/10 · sync_flows 18/18 · sync_hostile 13/13
sync_traffic 2/2 · ui_dungeon 10/10
```

### 3. In-game checklist (things only the real client can confirm)

1. Disenchant an epic, prospect, and open a lockbox in a raid. No drop panel or raid-warning sound should appear. With the loot window open, `/dump GetLootSourceInfo(1)` should start with `Item-`.
2. Master-loot to a player with full bags. The red "inventory is full" error shows, then DisasterZone offers "Award … ?". There is no announce and no log entry.
3. A normal give is recorded right after the slot empties. Two identical tokens given back to back are both recorded.
4. Loot a boss with Blizzard's loot window. The drop panel sits beside it, also with Loot Under Mouse on near the right screen edge.
5. With the restore popup up, press Escape. The popup closes and nothing is sent.
6. Loot a trash epic right after Prince while a roll is running. The panel stays on Prince and the pager reads "N/M new".
7. Move master loot to a non-council raider mid-raid. The next roll's suggestion there follows BiS priority.
8. With a master looter from another guild, that player's roll results show BiS tiers.
9. Full login (not /reload) as council. The Loot Log shows the awards within a few seconds.
10. Picker as a druid, trinket slot, "Usable by my class" ticked. No other-class T5 trinkets; Medallion rows name their class.
11. Council tooltip on a raid item reads "wanted by N (M in raid)". "Wearing:" lines appear only while Shift is held.
12. Council > Loot Council: click the ▾, click a name, click the world. WASD then moves the character.
13. Roll all on two items, award the first while the second is open. The winner gets "You won …" in chat.
14. GM on a PC without the saved council list gets the "not saved on this PC" message, and re-saving works.
15. Council Items view > Record award while a roll is open. The menu says "(closes the open roll)" and the roll closes for everyone.

### 4. Changelog 0.5.0

**Loot decisions**
- Disenchanting, prospecting, lockboxes and fishing no longer show up as boss drops or take over the council panel.
- A master-loot give only counts once the server has handed the item over. If it fails (bags full, unique item), you get "Award anyway?" instead of a false announcement.
- A second copy of an item is no longer suggested to the player who just won the first copy.
- Players whose class cannot use an item or token (T5 class trinkets, Warglaives, PvP set pieces, Ashtongue talismans, other classes' tokens) are marked "can't use" and never suggested.
- Roll suggestions use the raid's phase, not a council member's personal view phase. The master looter gets the same ranking even when the roll starter is the only council member in the raid.
- A slot marked "not needed" in the current phase no longer counts through an older phase's pick.
- Another Karazhan group's award of the same item no longer marks your drop as awarded or skips it in "Roll all".
- When the loot message names someone other than the recorded winner, DisasterZone flags it and offers a one-click fix to the log.
- Awarding from Council > Items while a roll is open now goes through the roll.

**Protection against modified clients**
- A raid leader (or a raider) can no longer overwrite lists, inject or void awards, take over the guild council list, cancel running rolls, override awards, claim boss drops, or freeze clients with oversized messages.

**Reliability**
- Pressing Escape on the "newer copy" popup no longer overwrites the council's copy.
- The award log no longer stays empty after a fresh login.
- Changing the master looter is picked up immediately, and a master looter from another guild receives BiS tiers.
- Real awards to pugs whose names look like demo names are no longer deleted.
- Less network traffic after a boss and when a council member catches up on the log; less memory churn.

**Interface**
- The drop panel attaches to the loot window again.
- The panel doesn't grow or jump while rolls come in.
- A drop that is still being decided stays on screen when a new drop arrives.
- "End roll & award to X" says what the button does; Re-roll asks first when rolls would be discarded.
- Rolls hidden under "+N more" can be awarded.
- The Award menu keeps absent players apart.
- New "Drops" button in the Council window, and Shift-click on the minimap icon, to reopen the drop panel.
- The council search box releases keyboard focus.
- Winners of earlier Roll-all items are told.
- Accented names can be typed.
- Clearer counts ("N want").
- "Wearing" lines only while Shift is held.
- Long names no longer cut off.
- Picker rows name the classes of class-restricted items.

**Data**
- Corrected phases for the 2.1 engineering goggles, the 40000-honor Medallions and a few single items.
- T6 tokens no longer count as a way to Season 3 arena gear (not open on Anniversary realms yet).