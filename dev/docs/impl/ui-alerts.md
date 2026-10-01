1. Files written
- C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone\UI\DropPanel.lua (1397 lines)
- C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone\UI\Tooltip.lua (304 lines)
- C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone\UI\Settings.lua (880 lines)

A throwaway smoke test is in scratch only: `SCRATCH\uialerts_smoke.py`.

**Answer to the user's question (no dependency on other addons):** none of these three files needs another addon. They use only the libraries that ship inside `DisasterZone/Libs`: LibCustomGlow through `ns.UI:Glow`, and LibDBIcon through `LibStub(..., true)` with a guard. LoonBestInSlot is only read through a guarded `ns.Loon:IsAvailable()` call. The Settings "About" section now shows the line "Standalone: all libraries are built in", followed by whether Loon was detected (it is optional and only used for BiS suggestions). People the addon is shared with need nothing else installed.

2. Public API implemented

**ns.DropPanel** (module "DropPanel")
- `OnInit`: subscribes to DROP, the refresh messages and CONFIG_UPDATED. Registers the slash command `/dz drops`.
- `OnLogin`: calls `HookLootFrame`.
- `ShowDrop(drop)`, `ShowHistory()`, `Hide()`, `Page(delta)`, `Render()`, `RequestRefresh()`.
- `OnDrop(drop)`, `HandlePersonal(drop, items, soundPlayed)`, `PrintOwnDrop(itemID, match, test, tries)`.
- `AnnounceItem(itemID, test)`, `AnnounceAll()`, `BuildAnnounceLine(itemID)`.
- `Award(itemID, key, bossKey)`, `AwardSomeoneElse(itemID, bossKey)`, `AwardByName(data, text)`, `OpenAwardMenu(block, owner)`.
- `QueueToast`, `ShowNextToast`, `RefreshToastText`, `StartToastTimer`, `ToastTimeout`, `FinishToast`, `DismissToast`, `GetToast`.
- `HookLootFrame()`, `DecorateLootButton(index)`, `UpdateAllLootButtons()`, `ClearLootButtons()`, `ClearLootButton(btn)`.

**ns.Tooltip**
- `OnInit` / `OnLogin`: hooks the 6 tooltips and MODIFIER_STATE_CHANGED.
- `HookTooltip(tt)`, `AddLines(tt, itemID)`, `Invalidate()`.

**ns.SettingsUI**
- `OnInit`: calls `MainFrame:RegisterTab("settings", "Settings", 4, ...)`.
- `OnLogin`: calls `RegisterBlizzardCategory()`, which uses `Settings.RegisterCanvasLayoutCategory` and has an "Open DisasterZone settings" button.
- `CreatePanel(parent)`, `Refresh()`, `RequestRefresh()`, `RefreshCouncil()`, `RefreshAbout()`.
- Draft handling: `ResetDraft`, `GetDraft`, `TagOf`, `ResolveMember`, `DraftAdd`, `DraftRemove`, `ConfirmSave` (opens the DISASTERZONE_SAVE_CONFIG popup), `SaveConfig(cfg)` (calls `ns.Guild:WriteConfig`).

**Deviations from the spec, and why:**
- **Glyphs:** the default WoW fonts have no ★, ✓, ▾, ◀, ▶ or → characters. I used texture escapes instead: the raid star (`ns.TEX.star` path) and the ReadyCheck check mark. The pager uses spellbook page buttons. Button text uses ASCII (for example "Award...") and " - " replaces "—" in text that may be sent to chat.
- **Loot-button badge placement:** the badge is a small dark strip at the top-left of the icon, not right-aligned. The classic LootButton name text sits at x≈37..130 and a right-aligned badge would cover it.
- **Council badge extras:** it shows "Alt ×m" when nobody has the item as main BiS. It gets a star prefix when the item is also on my own list.
- **Toast and chat line:** these fire only for a match I have not obtained yet. The same item is suppressed for 90 seconds, so a corpse drop followed by a group-loot roll alerts once. Test drops are never suppressed.
- **Test (simulated) drops:** Award is disabled and Announce only prints locally, so nothing fake reaches the ledger or raid chat.
- **Announce line:** it lists only in-raid wanters while I am in a group, and everyone when solo.
- **Additions:**
  - The Award menu has an "Other group member" submenu and a "Void the award to X" entry.
  - The council tooltip lists players who already obtained the item last, with "obtained" on the right.
  - Settings has "Recent drops", "Request sync", a debug checkbox and "Revert".
  - `/dz drops` reopens the drop panel.

3. SPEC GAPS / assumptions
- **"Someone else…" in the Award menu:** it calls `ns.LootLogUI:OpenAwardDialog(itemID, nil, bossKey)` (guarded). That function is not in the spec, but LootLog.lua implements it with the signature (itemID, winnerKey, bossKey, note), which I checked. The fallback is my own popup `StaticPopupDialogs.DISASTERZONE_AWARD_OTHER` with an edit box.
- **`ns.UI:RestorePosition(f)`:** this is a Widgets extension, used guarded to return to the floating position. The fallback reads `windows[name] = {point, relPoint, x, y}` directly.
- **`ns.UI:ItemText`** returns two values. I cut it to one where it goes into `SetText`.
- **Checked against the real code:** Widgets callback signatures (`setter(checked)`, `onSelect(value)`), the Store:GetWanters fields, BiS:MatchItem, the Ledger:GetEntries `since` filter, Guild BuildTag/WriteConfig/GetConfig (including `raw`), DB:SetSetting, Loot:GetHistory and HandleDrop (sets `from`, appends to history before firing), and LibDBIcon being registered as "DisasterZone".

4. Checker results
- `tools\check.py` on the three files: `-- checked 3 file(s): 0 syntax error(s), 0 global write(s), 0 warning(s), 0 info []`
- Lua 5.1 smoke test with stubbed ns and frames (`SCRATCH\uialerts_smoke.py`): **SMOKE OK**. It exercised:
  - DROP leading to the panel and the toast, and duplicate items getting their awards matched per copy.
  - The pager, Announce all, every Award menu action, the award popup, and the toast's click and timeout paths.
  - Test and roll drops, the loot-button hook and LOOT_CLOSED, and tooltip dedupe plus Shift-expand.
  - Every settings checkbox and dropdown, add/exclude, the save popup leading to WriteConfig, and the not-in-guild path.

5. For the integration agent to double-check in game or in the harness
- **Loot frame:** confirm `LootFrame_UpdateButton` exists. If it does not, repainting falls back to LOOT_OPENED/LOOT_SLOT_CLEARED. Also check how the badge strip and the ButtonGlow look on LootButton1..4 and across pages.
- **Drop panel scrolling:** `UIPanelScrollFrameTemplate` with `scrollBarHideable` should hide the bar when nothing scrolls. Check the height that fits the content (150–520) and that the panel attaches to LootFrame +4,0 in "auto" mode.
- **Toast:** confirm the Alpha fade animation (SetFromAlpha/SetToAlpha) works, and that clicking links the item. `ChatFrameUtil.InsertLink` is called first, then `ChatFrameUtil.OpenChat` or `ChatFrame_OpenChat`.
- **Tooltip Shift-expand:** it rewrites the "+K more" line's TextLeft/TextRight and appends the remaining names, without re-setting the tooltip. Check that the right-hand text shows correctly.
- **Blizzard Settings entry:** check that the canvas renders and that the button runs `HideUIPanel(SettingsPanel)` and then opens the DisasterZone "settings" tab.
- **Council editor:** check that the rank dropdown gets its ranks from `GuildControlGetNumRanks` and `GuildControlGetRankName(i+1)`, and that saving writes the tag. The draft resyncs when `CONFIG_UPDATED` fires unless there are unsaved edits.