1. **FILES WRITTEN** (all under `C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot\Core\`)
- `Init.lua`: 361 lines
- `Util.lua`: 528 lines
- `Constants.lua`: 276 lines
- `ItemDB.lua`: 643 lines
- `DB.lua`: 175 lines
- `Demo.lua`: 326 lines

Smoke test (scratch only): `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-CDLoot\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\core_smoke.py`. It runs real Lua 5.1 with WoW mocks. Item class and subclass come from Questie's TBC item DB; the equip slot is guessed from the item name. It prints `ALL CORE CHECKS PASSED`.

**Answer to the user's question (dependencies):** Nobody you share CDLoot with needs any other addon installed.
- Every library it uses has its own copy in `CDLoot/Libs`: LibStub, CallbackHandler, AceComm, ChatThrottleLib, LibSerialize, LibDeflate, LibDataBroker, LibDBIcon and LibCustomGlow.
- The TOC has no `## Dependencies` line. It only has `## OptionalDeps: LoonBestInSlot`.
- Across the addon's code, the only reference to another addon is `Core/Loon.lua`. It checks for `_G.LBIS`, which exists only when LoonBestInSlot is installed, and is used only for the optional "Suggest BiS" feature.
- The loot data in `Data/Items.lua` was generated from other addons' data files but ships inside CDLoot, so nothing is read from them at runtime.
- My six core files reference no other addon.

2. **PUBLIC API** (★ = extra beyond the spec, additive only)

Init
- `CDLoot = ns`, `ns.name`, `ns.version` (from C_AddOns metadata, else "0.0.0"), `ns.PROTO = 1`, `ns.initialized`, `ns.loggedIn`.
- `ns:NewModule(name)`: errors if `ns[name]` already exists.
- Lifecycle: `OnInit` and `OnLogin` are dispatched in TOC order, each call under xpcall. It also handles the addon loading after login.
- `ns:RegisterEvent(event, fn)`: returns true, or false for an event the client doesn't know. Registering the same fn twice does nothing. Skipped events are debug-logged after init.
- `ns:UnregisterEvent(event, fn)`.
- `ns:On`, `ns:Off`, `ns:Fire`: handlers run in xpcall. Message names not in the §3.3 catalogue get a debug line, not an error.
- `ns:Print(fmt, ...)` and `ns:Debug(fmt, ...)`: a bad format or nil argument falls back to plain concatenation instead of erroring.
- Slash commands: `/cdl` and `/cdloot`. `ns:RegisterSlash(sub, fn, help)`. Empty input calls `ns.MainFrame:Toggle()` (guarded). `help` lists commands. Unknown commands print help. `debug` is registered here.
- ★ `ns.SafeCall(fn, ...)`. Plain Lua 5.1 xpcall does not pass extra arguments, so this uses a closure. It looks up `geterrorhandler()` on every call.
- ★ `ns:IsDebug()`, ★ `ns:GetModules()`, ★ `ns:PrintSlashHelp()`.

Util
- Names: `GetPlayerRealm`, `NormalizeName`, `ShortName`, `PlayerKey` (cached after login), `IsMe`.
- Timers: `After`, `Debounce` (restarts on each call), `CancelDebounce`, `RandomDelay`. Callbacks run under SafeCall.
- Tables and text: `CopyTable` (deep copy, handles cycles), `Count`, `Keys` (sorted: numbers, then strings, then booleans), `Canonical`, `Hash`, `ItemIDFromLink`, `ItemIDsFromText` (keeps duplicates), `CompareVersions`, `FormatAgo`, `ColorText` (also accepts an `{r,g,b}` table), `ClassColorHex`.
- Group: `Util.group`, `RefreshGroup`, `IsInMyGroup`, `GetGroupKeys`, `IsPlayerMasterLooter`, `IsPlayerLeaderOrAssist`, `InRaidInstance`.
  - Refresh runs 0.3 s after `GROUP_ROSTER_UPDATE` or `PLAYER_ENTERING_WORLD`.
  - `GROUP_UPDATED` fires only when the set of names changes.
  - Names still showing as "Unknown" trigger a retry after 2 s.
  - `IsInMyGroup` and `GetGroupKeys` return Demo's raid while demo mode is on.
- ★ `Trim`, `Contains`, `KeyLess`, `IsDebouncePending(key)`, `Adler32(str)` (LibDeflate, else a pure-Lua version), `Hex32(n)`.
- Deviations (same output, overflow-safe):
  - `Hash` formats the checksum as two 16-bit halves (`%04x%04x`) instead of `%08x`, because a C long is 32 bits on Windows.
  - `Canonical` uses `%d` only below 2^31; larger integers use `%.0f`.
  - Strings and string keys are encoded with `%q`. NaN and infinity encode as "nan", "inf" and "-inf".

Constants
- Everything in §4.1–4.5 exactly: `SLOTS` (with invTypes sets), `NUM_SLOTS`, `SLOT_BY_KEY`, `INVTYPE_TO_SIDS`, `INVSLOT_TO_SID`, `DOLL_*`, `PHASES`, `PHASE_INFO`, `MAX_PHASE`, `CLASSES`, `SPECS`, `GetSpecRole`, `ROLE_LABELS`, `ARMOR_PRIMARY`, `ARMOR_ALLOWED`, `WEAPON_ALLOWED`, `DUAL_WIELD`, `COLORS`, `TEX`.
- The weapon table is LootReserve's, with its TBC adjustments applied (no 1H axes for rogues, no polearms for druids). Weapon subclass numbering was checked against AtlasLoot's `Enum.ItemWeaponSubclass` usage.
- ★ `ITEM_CLASS_WEAPON = 2`, `ITEM_CLASS_ARMOR = 4`, `ARMOR_SUB`, `WEAPON_SUB`, `WEAPON_RESTRICTED`, `SLOT_PAIR`, `INVTYPE_LABELS`, `CLASS_NAMES`, `ROLES`, `SLOTS[sid].emptyIcon` (fallback icon fileIDs), `TEX.question`.

ItemDB
- All §6 functions: `GetRaids`, `GetBossRef`, `GetSources`, `GetSourceText`, `GetPhase`, `IsToken`, `ExpandDrop`, `GetBossBySourceGUID`, `GetBossByEncounter`, `GetEquipLoc`, `GetSlotsForItem`, `FitsSlot`, `IsUsableBy(id, class, sid)`, `IsPrimaryArmor`, `GetCandidates`, `GetInfo`, `GetIcon`, `GetName`, `GetLink`, `GetQuality`, `Prefetch`, `Search`.
- The indexes are built lazily, so the API also works before `OnInit` runs.
- ★ `GetRaid`, `GetBossRefs`, `GetTokenClasses`, `IsPending`, `Describe`. Each bossRef also carries a `phase` field.
- Deviations:
  - **GetCandidates** also returns Sunmote-upgraded items right after their base item (`via="upgrade"`, `viaItem=baseID`). `filter.includeUpgrades=false` turns this off.
  - Quest-reward pieces have no TierPieceClass entry, so they are not class-filtered. These are the Magtheridon's Head rings and the Verdant Sphere necks.
  - Candidate rows are fresh tables each call. The slot lists are pre-built once per sid for speed.
  - **GetSourceText** prefixes "Token · " for token and arena sources and "Sunmote · " for upgrades. Short mode shows the boss name only; trash shows "<Raid> trash".
  - **ITEMINFO_READY** is throttled, not restart-debounced: it fires 0.25 s after the first item of a burst arrives, so a steady stream of loads can't hold it back forever.
  - A load that fails (`success == false`) does not fire the message and is not requested again for 60 s. Without this, the UI refresh would re-request it in an endless loop.
  - GetSources and ExpandDrop return cached shared arrays; callers must not modify them.

DB
- `OnInit` creates `CDLootDB`, sets `ns.db` first, then fills defaults, then runs migrations by schema. The default fill never overwrites saved values, but replaces a value that should be a table and isn't.
- `GetSetting(path)` falls back to the defaults before SavedVariables load.
- `SetSetting(path, value)` fires `SETTINGS_CHANGED(path)` only when the value actually changed, and returns true or false.
- ★ `GetDefault(path)`.

Demo
- `IsEnabled`, `SetEnabled` (in memory only; needs the player to be logged in; fires `DEMO_TOGGLED` then `LISTS_RESET`), `GetRecords`, `GetRoster`, `IsInDemoRaid`, `/cdl demo [on|off]`.
- ★ `Toggle`, `GetRecord(key)`, `GetMembers()`, `GetRaidKeys()` (me plus the fake raid).
- Deviation: 18 fake members (2 per class) instead of about 16; 10 of them plus me are in the demo raid; ranks 1 (Officer) to 4.
- Lists are generated with `GetCandidates(sid, {maxPhase, class, usableOnly=true, primaryArmorOnly=true})`, preferring items from exactly that phase. A pick sometimes carries over from the previous phase. Two-handers leave the off hand empty. Ring and trinket pairs get distinct items.
- A fixed-seed Park–Miller generator makes the data identical every time. Record timestamps are relative to when demo mode was switched on.

3. **SPEC GAPS / ASSUMPTIONS**
- **BiS:** `IsDirty()` needs to know whether the commit debounce is pending. Use ★`Util.IsDebouncePending("bis-commit")`.
- **Ledger:** the digest should use `Util.Hex32(Util.Adler32(s))` instead of `string.format("%08x", …)`. Values at or above 2^31 may format wrongly on Windows clients.
- **Guild:**
  - It must merge `Demo:GetRoster()` into its roster while demo mode is on. The demo roster does not include the player.
  - Entries have the §13 shape plus `key` and `name`.
  - Demo does not fire `ROSTER_UPDATED`, `CONFIG_UPDATED` or `GROUP_UPDATED`. Guild, Council and MainFrame should react to `DEMO_TOGGLED` and `LISTS_RESET`.
- **Picker:**
  - Rows with `via="upgrade"` exist; if the subtitle shows "via <viaItem name>", that reads fine.
  - Picker should use `ns.INVTYPE_LABELS` for equip-location text.

4. **CHECKER RESULTS**
```
tools/check.py Core/Init.lua Core/Util.lua Core/Constants.lua Core/ItemDB.lua Core/DB.lua Core/Demo.lua
-- checked 6 file(s): 0 syntax error(s), 0 global write(s), 0 warning(s) []
```
- The only global writes are `CDLoot`, `SLASH_CDLOOT1`, `SLASH_CDLOOT2` and `CDLootDB`, all allowed.
- The lupa compile one-liner reports OK for all six files.
- The smoke test covers:
  - the lifecycle and `ns.db` timing
  - event de-duplication and unregistering during dispatch
  - handler errors being routed without stopping other handlers
  - canonical encoding and hash (Adler32 matches the reference value)
  - names, debounce and group tracking
  - token and Sunmote sources, source GUIDs and encounters
  - GetCandidates filtering: class-only tier pieces, no tokens, dedupe, trash, exact phase, priest off hand
  - Search, item-info throttling and failed-load handling
  - Demo generation (about 50 ms, all picks fit their slot, hashes valid) and the slash commands.

5. **FOR THE INTEGRATION AGENT**
- **Test harness:** `C_Item.GetItemInfoInstant` must return equipLoc, classID and subclassID for raid items. Otherwise GetCandidates returns nothing. Equip locations, including misses, are cached for the whole session.
- **In game:**
  - Non-equippable items: I treat `""`, `INVTYPE_NON_EQUIP` and `INVTYPE_NON_EQUIP_IGNORE` as not equippable. Confirm what 2.5.6 actually returns.
  - Confirm `UnitNameUnmodified`. LootReserve uses it; `UnitName` is the fallback.
- **Proficiency check:** hunters can use thrown weapons, following LootReserve (AtlasLoot disagrees). This only affects the ranged-slot "usable" filter.
- **Message names:** a typo only shows up as a `[debug]` line, visible with `/cdl debug`.
- **Group tracking:** the member set is refreshed 0.3 s after roster events, so code that reads it in the same frame as `GROUP_ROSTER_UPDATE` sees the old set until `GROUP_UPDATED` fires.