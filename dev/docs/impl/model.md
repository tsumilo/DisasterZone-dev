No, nobody you share CDLoot with needs any other addon. The four files I wrote are Core/BiS.lua, Core/Ledger.lua, Core/Loot.lua and Core/Loon.lua. They only use CDLoot's own modules and the libraries bundled in `CDLoot/Libs`. LoonBestInSlot is optional: it is listed only as `## OptionalDeps` in the TOC and read through a guarded `_G.LBIS`. Without it, `Loon:IsAvailable()` returns false, `GetTemplate` returns nil and `GetSpecFunctions` returns `{}`, so only the "Suggest BiS" menu disappears. A test with Loon absent passed.

All four files compile under Lua 5.1 with no global writes, and 81 of 81 functional tests pass against mocks. Templates also build for every Loon spec in all five phases. Nothing has been run in the game client or the multi-client harness yet.

**1. Files written**
All in `C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot\Core\`:
- BiS.lua: 807 lines
- Ledger.lua: 495 lines
- Loot.lua: 484 lines
- Loon.lua: 324 lines

**2. Public API**

BiS (§8):
- `GetRecord()`: before login it returns a throwaway record; after login it creates and repairs `ns.db.chars[me]`.
- `GetData()`
- `GetSlot(phase, sid)` → `main|nil, alt|nil`
- `SetSlot(phase, sid, which, itemID)`: checks `FitsSlot` and prints why an item doesn't fit. **Deviation:** the swap works both ways (setting the alt to the current main swaps too).
- `ClearSlot`, `SwapMainAlt`, `ClearPhase`
- `CopyPhase(from, to, overwrite)`: **decision:** overwrite makes the target an exact copy; otherwise it only fills slots with no main pick.
- `ApplyTemplate(phase, slots, overwrite)`: overwrite replaces the whole phase, skips items that don't fit, and returns the number of slots changed.
- `GetSpec`, `SetSpec(label)` (label must be in `ns.SPECS[class]` or ""), `DetectSpec()` (handles both talent-return orders)
- `GetPhaseItems`, `AllListItems`
- `GetObtainedState(itemID)` → "equipped" / "bags" / "bank" / "token" / "manual" / nil; `IsObtained`; `SetManualObtained`
- `MarkDirty`, `IsDirty`, `NoteSeenRev`
- `Commit()`: **deviation:** a list that was never committed and has no picks is not committed and doesn't count as dirty. This keeps rev at 0 so a fresh install can still be restored automatically.
- `AdoptRestored(entry)`, `MatchItem(itemID)` (sorted as spec'd)
- Also added:
  - `ForceBump()`: Sync calls it (§10.3) but §8.2 doesn't list it.
  - `ScanOwned()`, `ScheduleScan()`, `RebuildDerived()`.
- **Deviation:** opening the bank scans immediately rather than waiting for the debounce. A scan still pending when the bank closes runs before the bank is marked closed.

Ledger (§11):
- `RecordAuto(itemID, winner, bossKey)`: council only, returns the entry. If that id already exists, nothing new is created.
- `Award(itemID, winner, bossKey, note)`: adds a "-2", "-3"… suffix when two manual ids collide.
- `Void(id, voided)`: the void timestamp always increases.
- `Merge(entry, from)`: full validation of the incoming entry. **Deviation:** for an id already held, only the void flag and void timestamp can change; winner, item and the other fields are protected.
- `GetEntries(filter)`: newest first; returns the stored tables, so treat them as read-only; voided entries have `vd = true`.
- `HasAward`, `CountSince` (both cached), `GetDigest`, `SyncFromDigest(X, digest)`
- Handles the A, LW (requests coalesced per sender, 1s) and LG messages.
- Also added: `GetEntry(id)`.
- **Deviations in the de-dupe view:** it is still deterministic, but I added two rules to prevent double-counting:
  - Two *manual* entries for the same winner and item within 120s count once (two council members clicking Award).
  - An auto entry is also hidden if it comes up to 10 minutes *before* a manual one (Award clicked after the item was handed out). The spec only hides autos up to 6h after.
- `SyncFromDigest` only requests days that the peer actually has entries for. The peer requests the rest itself from our digest.

Loot (§10.4):
- `ScanLoot`, `HandleDrop(drop, from)`, `GetHistory`, `GetRecentBossKey`, `SimulateDrop`
- Also added: `ManualDrop(text)`, `ParseLootMessage(text)` → `link, winnerKey`, `IsSeen(sourceKey)`.
- Slash commands `test` and `drop`, registered in OnInit.
- Drop broadcast suppression:
  - Any D received from someone else marks its source key before the dedupe runs, so our delayed send is cancelled.
  - The master looter sends immediately.
  - If two clients do send, receivers dedupe by source key.
- Robustness:
  - `GetLootSourceInfo` is called in pcall and falls back to the dead target's GUID, then to an `UNKNOWN-<30s bucket>` key.
  - The ItemDB boss lookup is also wrapped in pcall.
- Incoming D messages:
  - Must arrive on RAID or PARTY from a group member.
  - At most 16 valid item IDs are kept.
  - An unknown boss key becomes "".
  - A timestamp more than 1h off is replaced with the current time.
- Loot chat patterns are built from the six globalstrings, with every magic character escaped and anchored at both ends.
- Roll drops are not quality-filtered. Test drops are stored in the history.

Loon (§15):
- `IsAvailable`, `GetSpecFunctions(classFile)` (only loaders that actually exist), `GetTemplate(class, spec, phase)` (returns a copy of the cached template).
- Loader names come from `Guides/*.lua`: `Load<Class><Spec>`. Rogue uses `LoadRogueDps` for all three specs; Druid uses `LoadDruidCat` / `LoadDruidBear`. **Decision:** Discipline maps to `LoadPriestHoly`, because Loon has no Discipline guide.
- Slot names are reverse-mapped through `LBIS.L`.
- The capture always restores Loon's original functions; this was tested with a loader that errors part-way through.
- **Addition:** dual-wield guides that list both weapons under "Main Hand" (e.g. Fury) now fill slots 15 and 16.

**3. Spec gaps and assumptions about other modules**
- `ForceBump` exists only because §10.3 references it; Sync can rely on it.
- I call these exactly as the spec defines them:
  - Util: `PlayerKey`, `NormalizeName`, `ShortName`, `Debounce`, `CancelDebounce`, `After`, `RandomDelay`, `CopyTable`, `Hash`, `ItemIDsFromText`, `IsPlayerMasterLooter`, `IsPlayerLeaderOrAssist`, `InRaidInstance`, `IsInMyGroup`.
  - Comm: `Register(t, fn(sender, msg, dist))`, `Send(msg, dist, target, class)`, `SendToCouncil`.
  - Store: `ValidateData` → `ok, err`; `CountWanters(id, opts)`.
  - Guild: `AmICouncil`, `IsCouncil`, `GetViewPhase`.
  - ItemDB: `FitsSlot`, `ExpandDrop`, `IsToken`, `GetLink`, `GetName`, `GetQuality`, `GetSources`, `GetBossRef`, `GetBossBySourceGUID`, `GetBossByEncounter`, `GetRaids`, `GetEquipLoc`.
  - Init: `ns.loggedIn`, `ns:RegisterSlash(sub, fn, help)`.
- My handlers enforce the council gates for A, LW and LG themselves; Comm only does the basic guild/group check.
- The bags scan uses `C_Container.GetContainerItemInfo`, which is proven on this client, instead of the unverified `GetContainerItemID`.

**4. Checker results**
`tools\check.py` did not exist yet, so I compiled each file with Lua 5.1 via `tools\luabc.py`, using my script `SCRATCH\model_check.py`:
- BiS / Ledger / Loot / Loon: all compile OK, global writes: none.
- Unknown global reads, all verified against api.md or installed 20506 addons:
  - Plain calls: `GetInventoryItemID`, `GetTalentTabInfo`, `GetNumTalentTabs`, `C_Container`, `UnitClass`, `GetServerTime`, `GetTime`, `LibStub`.
  - Loot API: `GetLoot*`, `GetNumLootItems`, `GetLootRollItemLink`.
  - Unit / group: `IsInRaid`, `UnitExists`, `UnitGUID`, `UnitIsDead`.
  - FrameXML constants, each with a fallback value: `NUM_BAG_SLOTS`, `NUM_BANKBAGSLOTS`, `BANK_CONTAINER`.
  - `_G.LBIS`, guarded.
- Functional tests (`SCRATCH\modeltest\run.py` with mocks): PASS 81, FAIL 0. They cover edits and revs, scanning, token state, matching, restore, loot-chat parsing, broadcast suppression, the missing / erroring `GetLootSourceInfo` fallback, remote D validation, ledger view determinism across merge orders, void merge rules, digest / LW / LG, and Loon capture and restore on error.
- `loon_all.lua`: every Loon spec builds 16–17 slots in phases 1–5.

**5. For integration to check in game or in the harness**
- Whether `GetLootSourceInfo` returns a GUID under master loot, and whether `ENCOUNTER_END` success arrives as 1 or true (both are handled).
- Whether `C_Container.GetContainerItemInfo(-1, slot)` reads the main bank while it is open.
- That MainFrame calls `ns.BiS:Commit()` on hide, and Sync calls `BiS:ForceBump()` on cancel-restore.
- That `Util.Hash` handles the `{main, alt}` arrays with 0 for empty.
- That Store's validator accepts `ph` slots as `{main, alt}` with 0 allowed for either.
- That DropPanel copes with duplicate item IDs in `drop.i` (two identical tokens) and with `drop.test` / `drop.roll`.
- Loot chat parsing assumes the enUS capture order (name before link).