I built the council picker, the Loot Council view, and the new Settings council summary and group-rules section. My smoke test passes against the real core, including a live raid where the leader shares loot rules. Most existing suites now fail, as expected. I checked a sample of the failures: each one sets up council through a guild rank or a `CDL{...}` tag, and the new council model no longer supports either. I found no failure caused by the UI changes. The three council tests in `test_settings.py` fail only because the old editor is gone.

## Files changed
All under `C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot\UI\`. Backups of the originals are in `scratchpad\ui_e_backup\`.

- **`Widgets.lua`** (additive only): new `UI:CreateSearchDropdown(parent, width, opts)`.
  - A search box with a list panel below it (up to 10 visible rows). Each row has a checkbox, class icon, class-coloured name and a grey note such as the rank.
  - Supports section headers, fixed rows that can't be toggled (the GM, the raid leader) and an optional footer checkbox.
  - Keyboard: typing filters (case-insensitive substring), Enter toggles the highlighted or top match and selects the text, Up/Down/Tab move the highlight, Escape closes and clears.
  - It also closes on a click outside, the same way GudaBags does on this client, when focus is lost, and when it is hidden.
- **`Council.lua`**: new **"Loot Council"** view button next to Roster / Items / Member. The phase, search, filter and footer controls are hidden in this view. It has two sections side by side:
  - **Guild council** (editable by the GM): picker of online guild members with "Show offline members", a phase dropdown, draft rows with a remove "x" (new names marked "not saved"), Save & share / Revert / Clear list, and a status line ("Shared 2m ago · N members · phase P3", "Unsaved changes", "Not shared yet").
  - **This raid's council** (editable by the current raid leader): raid members first, then online guild members. The raid leader is a fixed row. Outside a raid, a saved list shows as "Your raid council list".
  - Everyone else sees read-only lists with a footnote. Drafts follow new saved lists unless they have unsaved edits.
  - The toolbar phase marker says "(group)" instead of "(guild)" when group rules set the phase.
- **`Settings.lua`**: the old guild-tag editor is replaced by a read-only summary visible to everyone:
  - your council status and why ("Guild Master", "raid leader of this raid", …);
  - "Guild council (set by X 3d ago · phase P2):" and, in a raid, "This raid's council (set by raid leader X):", each followed by names with an online dot;
  - an **"Edit council…"** button when allowed, which opens the picker.
- **`Settings.lua`**, new **"Group loot rules"** section: the status line comes first, using the Addendum D §27 wording. Then roll duration, minimum quality, the dungeon mode checkbox, dungeon quality and a **Raid phase** dropdown. That dropdown writes `groupPhase`; its first option is "Use guild phase (Pn)".
  - Controls show the value in effect (`DB:GetEffective`) and write your own setting.
  - They are disabled while the rules come from someone else.
- No changes to `MainFrame.lua`, `DropPanel.lua` or `RollFrame.lua`. No UI file calls a removed Guild API any more.

## API added / removed
- **Added to CouncilUI:** `ShowCouncil`, `CanEditCouncil(kind)`, `RefreshCouncilView`, `GetCouncilDraft`, `IsCouncilDirty`, `ToggleCouncilDraft`, `SetCouncilDraftPhase`, `RevertCouncil`, `SaveCouncil`, `ConfirmClearCouncil`, `ClearCouncil`, `GetCouncilSummary`. `SetView` now accepts `"council"`. New popup `CDLOOT_CLEAR_COUNCIL`.
- **Added to SettingsUI:** `BuildGroupRules`, `RuleDropdown`, `GroupRulesStatus`, `GroupRulesEditable`, `GroupPhaseEditable`, `GroupPhaseSelected`, `GroupRulesStatusText`, `RefreshGroupRules`, `CanEditCouncil`, `OpenCouncilEditor`. New fields: `rulesStatus`, `ruleControls`, `phaseRuleDD`, `dungeonCheck`, `cs.raidSummary`, `cs.raidMembers`, `cs.editBtn`, and `dd.cdlLabel` on dropdowns.
- **Removed from SettingsUI:** `TagOf`, `ResetDraft`, `GetDraft`, `ResolveMember`, `DraftAdd`, `DraftRemove`, `ConfirmSave`, `SaveConfig`, `BuildEditor`, `LayoutEditor`, `LayoutNameRows`, `cs.editor`, and the `CDLOOT_SAVE_CONFIG` popup.

## Deviations
- **"Clear list"** asks for confirmation, then saves and shares an empty list. It does not just empty the draft.
- **Raid list editing:** allowed for the current raid leader, or outside a raid when you have a saved list. Inside someone else's raid you see that raid's council read-only.
- **"Edit council…"** only shows when the Council tab is available. A non-council player whose only saved raid list is from a past raid can't edit it until they lead a raid again.
- **Raid phase dropdown** is enabled only when you are the group's loot leader, or not in a group.
- **Read-only summary layout:** a heading line plus a two-column name grid, rather than one comma-separated line.

## Cross-file needs
- None blocking. Every core call is guarded, and all the core names I use now exist.
- Optional: the phase marker in `MyBiS.lua` still says "Guild's current phase" while group rules set the phase. That file isn't mine.

## check.py
- The three touched files: 0 syntax errors, 0 global writes, 1 warning that was already there (`ChatFrameUtil.OpenChat`, `Widgets.lua:157`).
- Whole addon: 30 files, 0 syntax errors, 0 global writes.

## Suites run
- **My smoke test:** `scratchpad\ui_e_smoke\test_ui_e.py`, 6/6 passing. It covers:
  - GM keyboard filtering, Enter/arrow toggles and the offline toggle;
  - phase change, save, revert, the remove "x", and Clear with cancel then confirm;
  - the raid-leader list and what a raider sees;
  - the Settings summary and "Edit council…";
  - the group-rules status line and disabled controls with faked remote rules;
  - a real leader-shared change that updates the raider's duration and phase.
- **Passing:** `test_tooltip.py` 6/6, conformance 7/7 and 11/11.

**Failing (tag-based):**

| Suite | Result | Failed cases |
|---|---|---|
| boot-ui `test_settings.py` | 6/9 | the three council-editor cases |
| boot-ui `test_access.py` | 3/12 | |
| boot-ui `test_boot.py` | 11/12 | |
| boot-ui `test_broad.py` | 0/1 | |
| boot-ui `test_council_ui.py` | 9/14 | |
| boot-ui `test_demo.py` | 3/5 | |
| boot-ui `test_lootlog.py` | 2/7 | |
| boot-ui `test_mybis.py` | 15/16 | |
| boot-ui `test_perf.py` | 1/3 | |
| boot-ui `test_slash.py` | 6/9 | help list now has `rules` and no `guildinfo` |
| `test_ui_dungeon.py` | 7/10 | |
| `tests/dungeon` | 8/17 and 9/16 | |
| `tests/guildinfo` | 0/8 | this suite is obsolete |
| `tests/loot-roll` | 12/17, 11/17, 0/9, 7/10, 9/20 | |
| `tests/rollclose` | 7/15 | |
| `tests/sync` | 0/4, 4/5, 2/10, 1/17, 0/13, 0/2 | |

Logs are in `scratchpad\out_ui_e\`.