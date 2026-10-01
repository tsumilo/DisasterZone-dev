The UI side of §35, §36 and §38 is done and works against the core agent's current code. `check.py` reports 0 errors and 0 global writes, and my 7-case smoke test passes. 24 of the 30 suites pass. The other 6 each have 1–3 failing cases, all old assertions that the new spec changes by design; none is a Lua error.

## Files changed
All under `C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone\UI\`. Backups of the originals are in `scratchpad\ui_f_backup\UI\`.

**`Widgets.lua`** (additive only; no existing line changed):
- New `UI:CreateMultiDropdown`: a dropdown of checkboxes whose menu stays open while toggling, with a summary as the button text.
- New lock helpers, all guarded against a core without the lock: `GetBiSLock`, `IsMyListLocked`, `CanSetBiSLock` (raid authority only), `SetBiSLock`, `LockByText` (returns "you" for me), `LockChangedAt`, `AddLockChangedLine`, `CreateBiSLockButton`.
- Icons: `UI.ICON_WARN` (the ⚠ marker) and `UI.ICON_LOCK`, plus `IconText` / `WarnIcon` / `LockIcon`.

**`Picker.lua`** (§35, §38):
- The old scope dropdown is replaced by two controls: a Phase dropdown ("Up to Pn" / "Only Pn" / "All phases") and a Sources checkbox dropdown (Raids, 5-man dungeons, Crafted, Reputation, Badge vendors, PvP, plus a Reset entry).
- The default is Raids + 5-man. The choice is kept for the session and saved per source key under `pickerSources.<key>`. If the ItemDB ignores `filter.sources`, rows are still filtered by kind here.
- Sections appear in first-seen order: raid → boss, "Crafted — Blacksmithing" → specialisation sub-headers (general recipes first), "Reputation — X", "Badge of Justice — G'eras", "PvP — Season / Honor vendors".
- Subtitles come from `ItemDB:FormatSource(row)`, with fallbacks. The tooltip adds the reagents note where there is one.
- Search matches the item name, token, boss and item ID (through `ItemDB:Search`), plus profession, faction, vendor, season, specialisation and the source text.
- `Open` returns false and prints once per 3 s while the list is locked. An open picker closes when a lock starts.

**`PaperDoll.lua`** (§36, §38):
- A disabled tile is desaturated and dimmed, labelled "Disabled — not needed", with its picks kept and a disabled tooltip.
- Council member views show the same state.
- Locked mode changes the tooltips and hides the "+" alt placeholder.

**`MyBiS.lua`** (§36, §37, §38):
- The tile menu gets "Disable/Enable slot (Pn)" and "Disable/Enable in all phases".
- Left-clicking a disabled tile opens that menu. Dropping an item on a disabled slot is refused with a message.
- The progress card leaves disabled slots out ("x / 16", "· n disabled").
- "Still needed from" gets lines for "Crafted (n)", "Reputation (n)", "Badges (n)" and "PvP (n)", each with a hover tooltip.
- While locked: a lock banner shows on the card, the footer text changes, and Spec, Copy, Suggest and Clear phase are disabled. Editing entries in the tile menu are greyed out; "Mark obtained" and "Link" still work.

**`Council.lua`** (§36, §38):
- Disabled slots show a dark "–" cell with a "Disabled by player" tooltip and are left out of the roster counts, the Items-tree demand and the member summary.
- Players who changed their list during the lock get a ⚠ at the end of their roster name (with a tooltip line), a "changed during lock" marker in the Member header, and a ⚠ in the Items view wanters.
- The toolbar's second row gets "Lock/Unlock BiS lists" plus a "Locked by X" status visible to every council member. It refreshes on `BIS_LOCK_CHANGED`.

**`DropPanel.lua`** (§38):
- A small "Lock lists" / "Unlock lists" button in the footer, shown only to the authority.
- ⚠ plus a tooltip line on candidate rows (status column), roll rows (tag column) and the "+N more" tooltips.

**`Settings.lua`** (§38): the group-rules section gets a lock button (shown to everyone, enabled only for the raid authority), a status line ("Locked by X (since hh:mm)" / "unlocked (raids only / raid leader only)") and an explanatory note.

**`Tooltip.lua`**: unchanged; everything it shows goes through the core's `GetWanters` and `MatchItem`.

## API added
- **Picker:**
  - `Open` now returns a boolean.
  - New: `GetSources()`, `SetSourceEnabled(key, on)`, `GetPhaseMode()`.
- **PaperDoll:**
  - New: `PaperDoll:IsSlotDisabled(record, phase, sid)`, `Doll:IsTileDisabled(sid)`, `Doll:SetLocked(bool)`.
  - `Update` accepts `ctx.isDisabled`.
- **MyBiS:** `GetProgress(phase)`.
- **SettingsUI:** `LockStatusText()`, plus the `lockBtn` and `lockStatus` fields.
- **DropPanel:** `lockBtn` field.
- **Council:**
  - Panel fields: `lockBtn`, `lockStatus`, `memberView.lockFlag`.
  - Roster row: `lockWarn`.
  - Cells: `cdlDisabled` and `cdlDash`.
  - Member entries gain `disabled` and `lockChanged`.
- **Widgets:** listed above.

## Deviations
1. The phase filter is its own dropdown next to Sources; the old single dropdown mixed phase and scope.
2. Row subtitles use `ItemDB:FormatSource(row, false)`, the same formatter behind `GetSourceText`. `GetSourceText` describes the item's primary source and adds "+n more", which would mislabel a crafted row whose item also drops from a raid. `GetSourceText` is still the fallback.
3. `pickerSources` is an account-wide setting (the core put it in plain settings, which the contract allows).
4. The lock buttons follow the core: raids only, authority only.
5. The lock banner sits at the top of the progress card; the paper doll leaves no free vertical space at 580 px.
6. The ⚠ and lock markers are textures (`UI-Dialog-Icon-AlertNew`, `PetBattle-LockIcon`) because the game fonts have no U+26A0 glyph; I checked this with `slug_cmap.py`.
7. The menu of a disabled slot leaves out Choose, Swap and Mark obtained.

## Wire compatibility (checked)
0.2 clients accept lists that carry `dx`:
- The 0.3 and 0.2 validators both ignore unknown top-level keys.
- `CheckShape` accepts `dx`: depth 3, boolean values, few nodes.
- The 0.2 `Util.Canonical` is byte-identical to 0.3's and encodes booleans, so the hash matches and a 0.2 client does not reject the list.

## CROSS-FILE NEEDS (Test & Fix agent)
- **`test_mybis.py`**, 3 cases to migrate:
  - The scope dropdown is replaced. `T_dropdown(DisasterZonePicker,'-')` is now the Phase dropdown. Use `ns.Picker:SetSourceEnabled` / `GetSources`, or the Sources dropdown found by its summary text ("Raids + 5-man").
  - The default now includes dungeons.
  - The empty-list text is now "No items match…" / "No sources ticked…".
  - The slot menu adds a divider, "Disable slot (P1)" and "Disable in all phases".
- **`test_dungeon.py` and `test_ui_dungeon.py`**, `picker_dungeon_scopes_headers_and_heroic_tag`: for dungeons only, untick Raids.
- **Core-caused:** `test_boot` (the `pickerSources` default) and `test_slash` (`lock` / `unlock` in help).
- **Core agent:** nothing blocking. Every call into the new core APIs is guarded; my smoke test also runs with those APIs removed.

## check.py
- The 7 touched files: 0 syntax errors, 0 global writes, 1 warning that was already there (`ChatFrameUtil.OpenChat`).
- Whole addon: 31 files, 0 errors, 0 global writes, 2 warnings that were already there.

## Suites (`tf_e\run_all.py`, logs in `tf_e\ui_f3\`)
- **Fully passing (24 of 30):** access, broad, council_ui, demo, lootlog, perf, settings, tooltip, conformance ×2, council_picker, dungeon_core, grouprules, loot-roll ×5, rollclose, sync ×6.
- **Expected failures (6 suites, 7 cases):**
  - `test_mybis` 13/16
  - `test_dungeon` 16/17
  - `test_ui_dungeon` 9/10
  - `test_boot` 11/12
  - `test_slash` 8/9
- **My smoke test** (`scratchpad\ui_f_smoke\test_ui_f.py`), 7/7:
  - picker: sources, PvP faction filter, search, phase modes;
  - disabled slots: tile, menu, card; council "–" cell and member doll;
  - "Still needed from" grouping;
  - full raid lock: buttons, banner, picker refusal, greyed menu, forged edit flagged in roster, member view, drop row and roll row (a flagged player is not suggested), unlock;
  - an open picker closing when the lock starts;
  - guards against a core without the new APIs.