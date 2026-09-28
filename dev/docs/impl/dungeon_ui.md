The UI for Addendum B (dungeon mode) and Addendum C (roll popups close once awarded) is done, and every related test suite passes. The core agent finished its side while I worked, so everything below runs against the real core APIs. The only stand-in is an inactive fallback in my own tests.

**FILES CHANGED** (all under `C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot\UI\`)
- **`Picker.lua`**
  - The scope dropdown gains "5-man dungeons" (`filter.scope="dungeons"`) and "Raids + dungeons" (`"all"`).
  - The existing raid options are unchanged, and default behaviour is unchanged.
  - Dungeon headers get " (5-man)". Items only on a heroic list get an orange "Heroic" tag in their second line.
  - The dungeon scope has its own empty-list text. It also filters out any non-dungeon rows, in case the item database ignores the scope.
- **`RollFrame.lua`**
  - The popup now shows in a party when `Util.IsDungeonModeActive()` is true. It hides when `DUNGEON_MODE_CHANGED` turns the mode off.
  - Fade rework: an awarded roll shows "Won by X" / "You won …!" and fades after 5 s.
  - Hovering keeps the popup only while the mouse is over it, including while the fade is already running (including over its buttons in game). The fade resumes about 1 s after the mouse leaves.
  - A change of state, e.g. "Rolls closed" to "awarded", restarts the 5 s countdown.
  - " (looted)" is added when `session.via == "loot"`.
- **`DropPanel.lua`**
  - The panel opens for council, and for the party leader in dungeon mode. It closes on `CONFIG_UPDATED` / `DUNGEON_MODE_CHANGED` if you no longer have access.
  - `DropPanel:Award` goes through the roll when that item and drop copy has an open or closed roll, or one already resolved by the loot message. It calls `Roll:MarkAwardedExternally` and never also writes the ledger, so there is exactly one entry.
  - Without such a roll, the council writes a plain ledger entry. A queued roll for that copy is cancelled only after that entry is written.
  - The "Someone else…" dialog comes back through the same path.
  - Roll-mode header shows "Awarded to X (looted)".
  - "Award…" is enabled for a non-council master looter or leader only when the item has an open or closed roll.
  - The source line shows the dungeon with " (5-man)". Tooltips and the row status say "party" instead of "raid" in dungeon mode.
- **`LootLog.lua`**
  - Entries with `dg` get a grey "(dungeon)" tag in the boss column and a tooltip line.
  - New "Show dungeon loot" checkbox (default on), with filtered counts and empty text. Searching "dungeon" finds these entries.
  - `OpenAwardDialog(itemID, winner, boss, note, opts)`: `opts.onSave` replaces the plain ledger write. The Loot Log's own "Add award…" never passes it, so it doesn't touch rolls.
- **`Settings.lua`**: new "Dungeon mode" section.
  - Enable checkbox, which goes through `ns.Dungeon:SetEnabled`, or the setting if that is missing.
  - "Dungeon min. quality" dropdown (Rare/Epic).
  - A short explanation.
  - Live status line: "Active — enabled by you/X", "(only for you)" when you enabled it but can't tell the party, and "Inactive (not in a 5-man party / in a raid / not turned on for this party)".
- **`MyBiS.lua`**: the progress card now groups dungeon items into one "5-man dungeons" line after the raids (e.g. "Black Morass 2, …"). The "Other sources" tooltip title no longer says "dungeon".
- **`Tooltip.lua`**: no change needed.

**API ADDED**
- `DropPanel:FindRollSession(itemID, drop, copy)`
- `DropPanel:Award(itemID, key, bossKey, copy, drop, note)`: new optional arguments. Returns `true`, or `false, reason`. `drop=nil` means the drop shown in the panel; `false` means no drop context.
- `DropPanel:AwardSomeoneElse(itemID, bossKey, copy, drop)`
- `LootLogUI:OpenAwardDialog(..., opts)`
- `RollFrame:IsHovered/HoldFade/CheckHold/StopHold/OnMouseEnter/OnMouseLeave`
- `SettingsUI:SetDungeonMode/DungeonStatusText/RefreshDungeon`

**DEVIATIONS**
- Both dungeon scopes also hide items above the phase being edited, like the default raid scope. Magisters' Terrace (P5) only appears from P5.
- In roll mode, a block with a suggested winner still shows "Award to X" instead of "Award…" (existing layout). Picking anyone else from the row menu uses the roll's own award flow with its confirm popup.
- `DropPanel:Award` also routes rolls already resolved by the loot message through `MarkAwardedExternally`. The panel shows no buttons for these, so only direct calls reach this.
- A note typed in the "Someone else…" dialog is lost on the roll path, because `MarkAwardedExternally` takes no note.
- Test edit: `tests\boot-ui\test_mybis.py` checked the scope dropdown for exactly three options. I updated it to the five required by §21.3.

**CROSS-FILE NEEDS**
- Optional: a note argument for `Roll:MarkAwardedExternally(id, key, note)`.
- Nothing blocking. All core names I code against now exist, and every call is guarded.

**check.py**: all 6 touched files, 0 syntax errors, 0 global writes, 0 warnings.

**Suites run** (all passing):

| Suite | Result |
|---|---|
| New `tests\ui-dungeon\test_ui_dungeon.py` (end-to-end party roll, fade/hover, looted, one ledger entry, Someone else… vs Add award…, queued, panel/popup gating, Settings, Picker, Loot Log) | 10/10 |
| boot-ui (access 12, boot 12, broad 1, council_ui 14, demo 5, lootlog 7, mybis 16, perf 3, settings 9, slash 9, tooltip 6) | 94/94 |
| loot-roll (award 17, drops 17, ledger auto-record 9, rolls 20) | 63/63 |
| conformance (demo isolation 7, ui_xmodule 11) | 18/18 |

Backups of the original UI files are in `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-CDLoot\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\ui_b_backup\`.