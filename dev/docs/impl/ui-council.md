ANSWER TO THE USER'S QUESTION (please pass this on): No. DisasterZone does not need any other addon installed, for you or for anyone you share it with.
- The libraries it uses (LibStub, AceComm/ChatThrottleLib, LibSerialize, LibDeflate, LibDataBroker, LibDBIcon, LibCustomGlow) are copied inside `DisasterZone\Libs` and loaded by `DisasterZone.toc`.
- The only other addon mentioned is LoonBestInSlot. It is listed as `OptionalDeps` and only adds the "Suggest BiS" templates. Without it, that menu simply doesn't appear.
- My two files only call the Blizzard API and DisasterZone's own modules. A search for `LibStub`, `LBIS` and `LoonBestInSlot` in them finds nothing.

FINAL REPORT (ui-council)

1. FILES WRITTEN
- `C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone\UI\Council.lua` (1861 lines)
- `C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone\UI\LootLog.lua` (822 lines)
- Scratch only, not part of the addon: `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\ui-council-smoke\smoke.lua`. It is a runtime smoke test: the real Constants, Widgets and PaperDoll files plus my two files, with a widget mock and fake core modules shaped like the spec.

2. PUBLIC API
ns.CouncilUI (module "CouncilUI"):
- `OnInit()`: registers tab "council" ("Council", order 2) and subscribes to LIST_UPDATED, LISTS_RESET, LEDGER_UPDATED, GROUP_UPDATED, ROSTER_UPDATED, ITEMINFO_READY, CONFIG_UPDATED, DEMO_TOGGLED, PEERS_UPDATED, MYLIST_CHANGED, MYLIST_COMMITTED, OWNED_UPDATED, and SETTINGS_CHANGED (viewPhase only).
- `CreatePanel(parent)`: the tab's create function. Builds the Roster view up front; the Items and Member views are built the first time they are opened.
- `Refresh(resetScroll, keepTreeScroll)` and `RequestRefresh()`: RequestRefresh debounces 0.2s under the key "council-ui". If the panel is hidden, both just set `panel.dirty`.
- `IsAvailable()`: `AmICouncil()` or demo mode.
- `SetView("roster"|"items"|"member")`, `GetView()`.
- `OpenPanel()`, `ShowMember(key)`, `ShowItem(itemID, fromKey)`, `ShowBoss(bossKey)`: not in the spec; added so other modules can jump into the Council views. The Loot Log uses `ShowMember`.

ns.LootLogUI (module "LootLogUI"):
- `OnInit()`: registers tab "loot" ("Loot Log", order 3) and subscribes to LEDGER_UPDATED, ITEMINFO_READY, ROSTER_UPDATED, LISTS_RESET, DEMO_TOGGLED.
- `CreatePanel(parent)`, `Refresh(resetScroll)`, `RequestRefresh()` (debounce key "lootlog-ui"), `IsAvailable()`.
- `OpenAwardDialog(itemID, winnerKey, bossKey, note)`: all arguments optional. DropPanel already calls it as `OpenAwardDialog(itemID, nil, bossKey)`, which matches. `ShowAwardDialog` is an alias. There is also `CloseAwardDialog()`.

Deviations from the spec, and why:
- **Winner field in the award dialog:** it is an EditBox plus a "Choose" button that opens a context menu, not a WowStyle1 radio dropdown. A guild can have 500+ members, which is too many for one radio list.
  - Menu order: raid/party members first, then a "Guild - online" submenu, then "Guild - all".
  - Long submenus use `SetScrollMode(400)` when available, otherwise they are split into chunks of 25.
  - Typed names are matched against raid and guild keys, ignoring case; otherwise they go through `NormalizeName`.
- **Items view tree:** it shows the chosen phase's raids first, then raids from other phases only if someone wants something from them (P2+ lists often include Kara items). Trash bosses appear only if someone wants something from them.
- **"Hide obtained" in the Roster view:** obtained cells are dimmed to 35% alpha (the check overlay stays) rather than hidden. It is ticked by default, which matches the Items view default `includeObtained=false`.
- **Extras:**
  - The Name, Need and Age column headers are clickable to sort (Name toggles between presence and name).
  - Clicking an Items row opens a menu:
    - Link in chat.
    - Announce: uses `UI:AnnounceLine` with a 2s cooldown per item.
    - Show member.
    - Record award to one of the wanters, or "Someone else..." which opens the award dialog.
  - Right-clicking a roster cell opens the Member view.
- **Award dialog boss:** the boss passed in by the caller wins. Otherwise it uses the recent kill if that boss drops the item, then the item's first source, then "".

3. SPEC GAPS / ASSUMPTIONS
- No cross-module Council or LootLog API was in the spec. The functions listed above are additions.
- **Member view paper doll:** other players only sync `ob` and `eq`, not bag or bank details. So `ctx.obtainedState` returns "equipped" (item is in eq) or "obtained". I checked PaperDoll.lua: it falls back to the label "Obtained" and the obtained button state.
- **Widgets extensions:** I checked Widgets.lua and use its `list:SetData(rows, resetScroll)` (scroll position is kept by default) and `UI:LinkInChat` (opens chat if none is active), each with a guarded fallback.
- **Ledger:Award:** it returns nil on failure and prints its own message for non-council players. The dialog treats nil as failure and shows a status line.
- **New named frames:** DisasterZoneCouncilPanel, DisasterZoneLootLogPanel, DisasterZoneAwardDialog. All use the allowed prefix.

4. CHECKER RESULTS
`tools\check.py UI/Council.lua UI/LootLog.lua`:
```
-- checked 2 file(s): 0 syntax error(s), 0 global write(s), 0 warning(s), 0 info []
```
Smoke test: `DONE: 0 error(s)`. It exercised the roster (malformed records, filters, sorting, cell tooltips and clicks), the Items view (token focus, tree, menus, announce, awards), the member view (arrows, unknown or malformed keys), the dirty-on-hide refresh, the Loot Log (void and restore, search, show member) and the award dialog (shift-click link, drag, typed ID, winner menu, typed names, prefill, save validation).

5. FOR THE INTEGRATION AGENT TO CHECK IN GAME
- **Layout:** it assumes the content area is about 784×546.
  - Toolbar rows sit at y -16 and -44. Check that the WowStyle1 dropdowns and checkboxes line up.
  - Member view: the paper doll (about 426px tall) sits in a holder about 450px tall. The member header replaces toolbar row 2, and the footer is hidden in this view.
- **Jump from a roster cell:** clicking a cell jumps to its boss using `ScrollBox:FindElementDataIndexByPredicate` and `ScrollToElementDataIndex` (both proven by Auctionator).
- **Items view text:** item rows use `_G[equipLoc]` for type labels. Check that the "·" middle dot renders in the game font.
- **Winner menu:** check `SetScrollMode` on the submenus (seen in RareScanner and DBM-GUI) with a large guild.
- **Award dialog:**
  - Shift-clicking an item while the item box has focus goes through a `hooksecurefunc(ChatFrameUtil, "InsertLink")` hook.
  - Dragging an item onto the box, the dialog, or its item button should set it.
  - The dialog uses DIALOG strata, above the main window's HIGH.
- **Performance:** check the Roster view with 60+ members and several ITEMINFO_READY bursts. Each refresh rebuilds the roster data once and keeps the scroll position; `HasAward` lookups are O(1), per visible cell.