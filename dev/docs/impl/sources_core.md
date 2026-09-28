FINAL REPORT: core agent, Addendum F (§35 core, §36, §37, §38)

The core work is done. check.py reports 0 errors and 0 global writes. My dev smokes all pass. Of the 30 suites, 25 pass and 5 fail (6 cases). All 6 failures come from intended contract changes (new settings default, new slash commands) or the UI agent's in-progress Picker / context-menu work. The Test & Fix agent needs to update those tests.

## Files changed (addon root `C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot`)

- **`CDLoot.toc`:** `Data\Sources.lua` added after `Data\Dungeons.lua`.

- **`Core/ItemDB.lua` (§37):**
  - **Lazy indexes:** built once from `ns.Data.Crafted/Reputation/Badges/PvP`, and only on first use of the new kinds:
    - per-item source entries;
    - per-kind entries;
    - per-kind, per-slot picker rows.
  - **`GetSources(id[, scope])`:**
    - Every entry now has `kind` and `phase`. Raid and dungeon entries also get `groupKey` / `groupName`.
    - New entries:
      - craft: `craft, skill, spec, subgroup, bop, reagentsNote, spell, professionID`
      - rep: `rep, standing, factionID, faction` (the faction's side)
      - badge: `badge, cost, npcID`
      - pvp: `pvp, season 1..4, cost, rating, faction`
    - Order is raid, dungeon, craft, rep, badge, pvp.
    - Scopes: `"all"` (the default, every kind), `"drops"` (raids + dungeons, the old default), `"raids"`, `"dungeons"`, and one scope per new kind (`"craft"`, `"rep"`, `"badge"`, `"pvp"`; `"crafted"`, `"reputation"`, `"badges"` also work).
  - **`GetSourceText`** covers every kind:
    - "Blacksmithing (375)"; the long form adds " · Armorsmith" and " · BoP" when known.
    - "The Sha'tar — Exalted", "G'eras — 50 badges".
    - PvP long: "Arena Season 2 (Merciless Gladiator)"; short: "Arena Season 2"; "Honor vendors — 8000 honor (Alliance)".
  - **Primary source:** for `GetSourceText` / `GetSourceKind`, a Gladiator piece reachable only through a tier token's arena exchange is described by its PvP entry, not by the raid token.
  - **`GetCandidates(sid, filter)`:**
    - `filter.sources` replaces `scope` when present; `scope` still works.
    - Section order: raids, dungeons, crafted (profession, then specialisation), rep, badges, PvP.
    - Every row has `kind, phase, groupKey, groupName`; new-kind rows also have `subgroup` plus the source fields.
    - The phase filters apply to every source; items without a phase count as P1.
    - Faction-tagged rows are shown only for `UnitFactionGroup("player")`; `filter.faction = "Alliance" | "Horde" | "any"` overrides this.
  - **`Search`** also matches group name (profession, faction, vendor, season), specialisation, standing and faction.
  - **`GetPhase`** covers every kind.

- **`Core/BiS.lua` (§36, §38):**
  - **Disabled slots:**
    - `dx` is sanitized (P1..5, slots 1..17, `true` values only) and left out when empty, so hashes of lists without `dx` don't change.
    - `MatchItem` skips disabled slots.
    - `CopyPhase` and `ApplyTemplate` (which covers Loon suggestions) never fill a disabled slot; with overwrite they keep the picks already in it.
    - `GetPhaseItems` entries gain `disabled=true`.
  - **Lock enforcement:** every editing API refuses while locked and returns false, printing "BiS lists are locked by X during the raid." at most once per 3 s. `ApplyTemplate` also returns false when locked. The raid leader is locked too (the message tells them `/cdl unlock`).
  - **Still allowed while locked:** obtained / equipped scanning and manual "Mark obtained".
  - **While locked:** automatic spec detection at login is skipped.
  - **When the lock arrives:** a pending edit is committed at once.

- **`Core/Store.lua` (§36, §38):**
  - **Validation:** `ValidateData` checks `dx` (P1..5, slots 1..17, `true` only).
  - **Disabled slots:** the wanted-item index leaves them out, so `GetWanters` and drop alerts skip them. `GetPlayerSummary` excludes them and returns `disabled = n` and `total = 17 - n`.
  - **Lock snapshots:** when the lock starts, a council client snapshots `Hash{ph, dx, sp}` for every member of the real group from its cached copy. Members who join later, or who had no cached list, get their snapshot on the next list or group change.
  - **Flagging:** in `Put`, a list whose picks differ from the snapshot is flagged with the server time (memory only) and one council warning is printed per player. The list is still accepted.
  - **Grace window:** a list the owner committed no more than 3 s after the lock started only refreshes the snapshot (see deviation 4).
  - **Clearing:** flags and snapshots clear on `BIS_LOCK_CHANGED(false)`.
  - **`GetWanters`** rows gain `lockChanged`.

- **`Core/GroupRules.lua` (§38):**
  - **Lock state:**
    - The authority's GS carries `lk = true` and `lkAt` (raids only).
    - A malformed `lk` / `lkAt` is dropped instead of rejecting the rules.
    - A lock received on PARTY is ignored.
    - A missing `lkAt` falls back to the time the lock was first seen.
  - **`SetLocked`:** only the raid's authority can call it. It sends the GS immediately, not on the 5 s throttle.
  - **Lock announce:** "CDLoot: BiS lists are locked for this raid." goes to RAID once, if `roll.announce` is on.
  - **Status messages:** everyone's client prints a local line when the lock turns on or off.
  - **`BIS_LOCK_CHANGED`** fires on every change; the lock state is also part of the `GROUP_RULES_CHANGED` signature.
  - **When the lock ends:** on unlock, on disband, when I lose the authority, when the raid becomes a party, or when another authority's GS is accepted.
  - **Reload:** the authority's lock is saved in `CDLootDB.groupLock` and restored after its own `/reload` (at most 12 h old).
  - **Joiners:** a raider who joins or reloads mid-raid learns the lock through GQ.
  - **Slash:** `/cdl lock` and `/cdl unlock` are new; `/cdl rules` shows the lock.

- **`Core/Roll.lua`:**
  - `GetResults` rows gain `lockChanged`.
  - The suggestion is the best group-1 row that is not flagged; ties are among unflagged rows only.
  - RT gains an optional `lc = {[key]=1}`, so a non-council starter or master looter skips flagged players too. Older clients ignore it, and remote flags only count while locked.

- **`Core/DB.lua`:**
  - New default `settings.pickerSources = {raids=true, dungeons=true, crafted=false, rep=false, badges=false, pvp=false}`.
  - A comment documents the `groupLock` saved key.

- **`Core/Init.lua`:** `BIS_LOCK_CHANGED` added to the message catalogue.

- **Not changed:** `Demo.lua` and `Sync.lua` needed nothing.

## API added
- **ItemDB:**
  - `GetSourceKind(id)`
  - `FormatSource(entryOrRow, short)` (extra; the UI already uses it)
  - `GetSourceGroups(kind)` (extra)
  - The new fields and scopes on `GetSources` / `GetCandidates` described above.
- **BiS:** `IsLocked()` (returns bool, `{by, at}`), `IsSlotDisabled`, `SetSlotDisabled`, `SetSlotDisabledAllPhases`, and `GetDisabledSlots(phase)` (extra).
- **Store:** `IsSlotDisabled(record|data|key, phase, sid)`, `GetLockFlag(key)`, and `GetLockFlags()` (extra).
- **GroupRules:** `IsLocked`, `GetLockInfo`, `SetLocked`; `GetActive().values` gains `lk` / `lkAt`.

## Deviations, and why
1. **`GetSources` default scope** now returns every kind (the contract implies it, and the UI relies on it). Raid and dungeon entries still come first, so existing `sources[1].ref` callers are unchanged; `"drops"` gives the old behaviour.
2. **Side-only reputations** (Thrallmar, Honor Hold, Mag'har, Kurenai) are filtered by faction the same way as PvP rows.
3. **Lock scope and the RL:** the lock is raid-only, and the raid leader is locked too.
4. **3 s grace plus flush-on-lock:** without them, an edit made just before the lock (whose commit waits on the 8 s debounce), or an older copy arriving late, would be flagged falsely. A forged edit more than 3 s after the lock is still flagged. A test that forges an edit within 3 s of locking will not see a flag.
5. **Lock survives the RL's /reload** (persisted `groupLock`); the spec lists only disband, authority leaving and unlock as end conditions.
6. **Lock flags are kept in a Store-side table**, not on the cached record, because records in `db.lists` are saved to SavedVariables and the spec says "memory".
7. **Wire compatibility:** no schema bump. The 0.2 fixture's `Store.lua` is byte-identical to 0.3's: it ignores unknown top-level keys, and its `CheckShape` and `Util.Canonical` handle boolean values. Verified live: a 0.2 council client stored a 0.4 list with `dx` (hash matched), and a 0.2 client in a locked raid logged no errors. Older 0.3 clients ignore GS `lk` and RT `lc`.

## CROSS-FILE NEEDS
- **`Core/Loot.lua` `ItemQualifies`:** should use `GetSources(id, "drops")` to keep its "drops from a boss" meaning. Today a crafted / rep / badge / PvP item received inside a raid would qualify; this is practically unreachable, since there are no gear vendors in raids and "You create" messages aren't parsed.
- **UI agent:**
  - Settings / Council / DropPanel lock buttons: enable with `GroupRules:IsAuthority()` and `IsInRaid()`, and refresh on `BIS_LOCK_CHANGED` / `GROUP_RULES_CHANGED`.
  - Picker section headers: `row.groupName` / `row.subgroup`, with `GetSourceGroups(kind)` for group order.
  - Use `Store:GetPlayerSummary().disabled` or `Store:IsSlotDisabled` for "x / 16".
- **Test & Fix:**
  - `test_boot` `EXPECTED_SETTINGS` needs `pickerSources`.
  - `test_slash` `SUBCOMMANDS` needs `lock` and `unlock`.
  - The picker tests (`test_mybis` ×3, `dungeon` / `ui-dungeon` `picker_dungeon_scopes…`) need migrating from the old scope dropdown and context menu to the UI agent's new controls.
  - Forged-edit lock tests should tick at least 4 s after locking before the forged commit (deviation 4).
- **Optional:** demo data could carry a disabled slot so the "–" matrix cell can be seen solo. I left `Demo.lua` alone because the council-UI tests compare demo counts.

## check.py
- Touched files (7 Core files + `Data/Sources.lua`): 0 syntax errors, 0 global writes, 0 warnings.
- Whole addon (31 files): 0 errors, 0 global writes, 2 warnings, both already there before this change (`UPDATE_MASTER_LOOT_LIST`, `ChatFrameUtil.OpenChat`), 1 info.

## Suites
**Baseline before my changes:** 30/30 green.

**After** (the UI agent was editing UI files concurrently):
- **All passing:**
  - access 12, broad 1, council_ui 14, demo 5, lootlog 7, perf 3, settings 9, tooltip 6
  - conformance 7 + 11, council_picker 16, dungeon_core 16, grouprules 12
  - award 17, drops 17, ledger_auto 9, roll_close_core 10, rolls 20, rollclose 15
  - all six sync suites (4 / 5 / 10 / 18 / 13 / 2)
- **Failing, all expected:**

| Suite | Result | Failing case(s) | Cause |
|---|---|---|---|
| `test_boot` | 11/12 | `fresh_boot_defaults_and_globals` | new `pickerSources` default |
| `test_slash` | 8/9 | help list | `lock` / `unlock` added |
| `test_mybis` | 13/16 | `picker_every_slot_main_and_alt_every_class`, `picker_search_scope_filters_and_clear`, `context_menu_swap_mark_clear_link` | UI agent's new Sources dropdown and context menu |
| `dungeon` | 16/17 | `picker_dungeon_scopes_headers_and_heroic_tag` | same UI changes |
| `ui-dungeon` | 9/10 | `picker_dungeon_scopes_headers_and_heroic_tag` | same UI changes |

  To confirm the UI cause, I ran `test_mybis` with the old Core plus the current UI: 6 cases fail, so the new UI needs the new Core, and the 3 remaining failures are UI-side.

**My dev smokes** (in `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-CDLoot\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\core_f\`):
- **`smoke_lock.py`:** 7/7. Covers:
  - disabled-slot model, sync, summary, wanters, copy / template and the validator;
  - full lock flow: every API refuses, chat announce, obtained items still sync, forged edit flagged on the guild council and the RL, a single warning;
  - a flagged player is not suggested;
  - joiner via GQ, forged GS ignored, RL and raider reload, disband;
  - an edit just before the lock is not flagged;
  - a non-council ML gets flags via RT `lc`;
  - a party can't lock.
- **`smoke_compat.py`:** a 0.2 council client accepts `dx` with a matching hash.
- **`smoke_itemdb.py` / `perf_build.py`:** texts, sections, faction filter and search checked.
  - First all-sources `GetCandidates` (the full one-time index build): 12.9 ms (target ~15 ms), measured after warming the mock's own item lookups (about 21 ms more when cold).
  - After that: about 0.4–0.6 ms per slot, with 87–384 rows.
  - `GetSourceText`: about 0.001 ms.

**Backups** of the pre-change files are in `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-CDLoot\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\core_f_backup\`. Suite logs are in `…\scratchpad\tf_e\f_base\` (baseline) and `…\scratchpad\tf_e\f_run2\` (after).