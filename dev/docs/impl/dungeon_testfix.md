FINAL REPORT (TEST & FIX): Addendum B (dungeon mode) and Addendum C (roll popups close)

The two new suites are written. All 31 suites pass (2 new, 29 existing), with no existing test changed. check.py shows 0 syntax errors and 0 global writes. The scenario tests found no crash or wrong-result bug in the core or UI work. The fixes below are the cross-file needs, two robustness gaps I found while reviewing, and one crash found by fuzzing.

Heads-up: `Core/Guild.lua` and a new suite `tests/guildinfo/test_guildinfo.py` were changed by someone else while I worked (Guild.lua at 02:51), even though I was told I was the only editor. I did not touch either. Both runs were done with that version in place, and guildinfo passes 8/8.

## (1) What I fixed

**Cross-file needs**
- **`UI/Council.lua`**: the Items tree count and `ShowItem` now look at raid sources only (`GetSources(id, "raids")`).
  - Before, a 5-man item was counted under a dungeon boss the tree never shows, so it disappeared from "Other / no raid source".
  - Now it is counted under "Other", and jumping to such an item opens the "Other" node.
- **`Core/Roll.lua`**: `MarkAwardedExternally(id, key, note)` takes an optional note.
  - Control characters and `|` are removed from the note.
  - The log note becomes "offspec; roll 80", at most 64 bytes, without cutting a character in half; the roll part is always kept.
  - **`UI/DropPanel.lua`** `Award` passes the note, so a note typed in "Someone else…" is no longer lost.
- The UI agent had already done every other need: DropPanel through `MarkAwardedExternally` with exactly one log entry, RollFrame showing in a party, the panel for the party leader, Loot Log, Picker, Settings.

**Robustness gaps**
- **`Core/Dungeon.lua`**: a party leader who is not council, turns dungeon mode on, and then passes the lead can now still turn it off for the party.
  - Before, the "off" was never sent, so the party stayed stuck in dungeon mode.
  - Now the "off" goes out if this player had told the party earlier. Receivers accept an "off" from whoever turned it on, or from the leader.
  - Turning it on still requires the party leader or a council member.
- **`Core/Roll.lua`**: the master looter hands the item to X with the normal Blizzard menu, and the council then records Y. The award to Y is still recorded, and the awarder now sees one chat line: "Note: the loot message says X received [item]; recorded as awarded to Y."

**Crash found by fuzzing the new APIs**
- **`Core/ItemDB.lua`**: a NaN item ID caused "table index is NaN". `GetSources`, `ExpandDrop`, `GetEquipLoc` and `GetInfo` now reject it.
- Network input was already validated, so only addon-internal calls could hit this.

**Test changes**
- No existing test was changed.
- New: `tests/dungeon/test_dungeon.py` (17 cases), covering:
  - every item in §22.3;
  - boss names in the drop panel from normal and heroic creature IDs and from chest objects;
  - the quality rules;
  - picker candidates for Mage and Warrior across several slots, with Heroic tags and headers;
  - the My BiS progress card, the council Items tree, `/dz test`, and the lead-handover case.
- New: `tests/rollclose/test_rollclose.py` (15 cases), covering:
  - (a) the Blizzard master-loot hand-out: in a raid, from a plain loot line, from an open roll with the queue moving on, and in a dungeon party with master loot. Also the DisasterZone give path in a party;
  - (b) "Award…" and "Someone else…" (note kept), an award while the roll is open, a queued roll, and a non-council master looter. Exactly one log entry in each;
  - (c) two copies of a token closed in order;
  - (d) no change for items without a roll;
  - hover pauses the fade, including over a child button and while the fade runs; it resumes ~1s after leaving;
  - a new state restarts the countdown; "Rolls closed" still lingers 45s; a winner who closed the popup is told once.
- Every case ends with `world.assert_no_errors()`.
- `find_multiret.py`: 29 sites, all single-return, none hazardous (same count after my changes). No `tinsert(t, <multi-return call>)` sites exist.

## (2) Suite summary lines
```
check.py: -- checked 29 file(s): 0 syntax error(s), 0 global write(s), 4 warning(s), 1 info
  (C_GuildInfo.GetInfoText/SetInfoText, UPDATE_MASTER_LOOT_LIST, ChatFrameUtil.OpenChat were already flagged before; LBIS info)
-- test_access.py: 12 case(s), 12 passed, 0 failed
-- test_boot.py: 12 case(s), 12 passed, 0 failed
-- test_broad.py: 1 case(s), 1 passed, 0 failed
-- test_council_ui.py: 14 case(s), 14 passed, 0 failed
-- test_demo.py: 5 case(s), 5 passed, 0 failed
-- test_lootlog.py: 7 case(s), 7 passed, 0 failed
-- test_mybis.py: 16 case(s), 16 passed, 0 failed
-- test_perf.py: 3 case(s), 3 passed, 0 failed
-- test_settings.py: 9 case(s), 9 passed, 0 failed
-- test_slash.py: 9 case(s), 9 passed, 0 failed
-- test_tooltip.py: 6 case(s), 6 passed, 0 failed
conformance/test_demo_isolation.py: 7/7 passed
conformance/test_ui_xmodule.py: 11/11 passed
-- dungeon mode (Addendum B, end to end): 17 case(s), 17 passed, 0 failed      [NEW]
-- dungeon / core: 16 case(s), 16 passed, 0 failed
-- test_guildinfo.py: 8 case(s), 8 passed, 0 failed
-- loot-roll / award: 17 case(s), 17 passed, 0 failed
-- loot-roll / drops: 17 case(s), 17 passed, 0 failed
-- loot-roll / ledger auto-record: 9 case(s), 9 passed, 0 failed
-- loot-roll / roll close (Addendum C core): 10 case(s), 10 passed, 0 failed
-- loot-roll / rolls: 20 case(s), 20 passed, 0 failed
-- roll popups close (Addendum C, end to end): 15 case(s), 15 passed, 0 failed  [NEW]
-- council membership: 4 passed, 0 failed
-- demo isolation: 5 passed, 0 failed
-- ledger sync: 10 passed, 0 failed
-- sync flows: 18 passed, 0 failed
-- hostile traffic: 13 passed, 0 failed
-- 40-member guild traffic: 2 passed, 0 failed
-- ui / dungeon mode + popup closing: 10 case(s), 10 passed, 0 failed
```

## (3) In-game checklist
**Dungeon mode (5-man party)**
- [ ] As party leader, tick Settings → "Enable dungeon mode". Every member sees one line: "DisasterZone: dungeon mode enabled by <you> (5-man loot sharing & rolls)". Their Settings status reads "Active — enabled by <you>".
- [ ] A member who is neither leader nor council runs `/dz dungeon on`. It says only their client uses it, and nobody else changes.
- [ ] Kill a boss and open the loot. Blue items show in the drop panel for the leader and council, with the boss name and "<Dungeon> (5-man)". Members with the item on their BiS list get the toast.
- [ ] Try a chest boss: Nazan's chest in Ramparts, or Ikiss's coffer in Sethekk.
- [ ] Click Roll on an item. Popups show for everyone; members roll or pass, and the leader's panel shows the suggestion.
- [ ] Award it. The line "->" goes to party chat, and the popups say "Won by X" and fade after about 6 s.
- [ ] Loot Log shows the award with "(dungeon)". Unticking "Show dungeon loot" hides it.
- [ ] "Won N tonight" in a later raid ignores dungeon awards.
- [ ] Pass the lead, then turn dungeon mode off. Everyone goes inactive.
- [ ] Leaving the party, or converting it to a raid, turns the mode off.
- [ ] `/dz dungeon epic` means rares are no longer shared. Outside the instance, only epics are shared.
- [ ] `/dz test` inside the dungeon simulates 2–3 heroic items from that dungeon.
- [ ] Picker → "5-man dungeons" / "Raids + dungeons": headers end in "(5-man)", heroic-only items show an orange "Heroic" tag.

**Roll popups closing**
- [ ] Roll an item and close it, then hand it out with the normal Blizzard master-loot menu. Every raider sees "Won by X (looted)" and the popup disappears after about 6 s. The panel header reads "Awarded to X (looted)".
- [ ] A roll closed with nobody rolling → "Award…" → pick a player. Popups close, and the Loot Log has exactly one entry, also on a second council member's client.
- [ ] "Someone else…" with a note: the log note reads "<note>; roll: …".
- [ ] Hover the popup while "Won by": it stays. Move the mouse away (including off the X button): it fades about 1 s later.
- [ ] Two copies of a token handed out one after the other resolve copy 1, then copy 2.
- [ ] Handing out an item that was never rolled leaves the open popups untouched.

## (4) Changelog (user-facing)
- **Dungeon mode for 5-man parties** (`/dz dungeon on|off|rare|epic|status`, or Settings → Dungeon mode):
  - The party leader or a council member turns it on for the whole party.
  - Boss drops are shared, with rares included by default.
  - Rolls run in party chat, and the leader gets the drop panel.
  - Awards are tagged "(dungeon)" in the loot log and don't count as "won tonight".
- **5-man loot data:**
  - The item picker gains "5-man dungeons" and "Raids + dungeons", with a Heroic tag on heroic-only items.
  - Tooltips and the drop panel name dungeon bosses.
  - My BiS lists dungeon items on their own line.
- **Roll popups now close once the item is handed out:**
  - This works whether the item is given through Blizzard's loot menu or through DisasterZone's Award… menu.
  - The popup shows "Won by X" and fades after 5 s.
  - Hovering keeps it open.
- **Awards made outside the roll:**
  - "Award…" and "Someone else…" now close the roll and log exactly one entry.
  - A typed note is kept.
- If the loot message shows the item went to someone else than the recorded winner, the awarder gets a note in chat.
- **Fixes:**
  - Wanted 5-man items now appear under "Other" in the council Items view.
  - The player who turned dungeon mode on can still turn it off after passing the lead.

Files are in `C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone`:
- `UI\Council.lua`
- `UI\DropPanel.lua`
- `Core\Roll.lua`
- `Core\Dungeon.lua`
- `Core\ItemDB.lua`

New tests are in `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\tests`:
- `dungeon\test_dungeon.py`
- `rollclose\test_rollclose.py`

Test logs are in `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\out_tf\run2\`.