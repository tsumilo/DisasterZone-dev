Addendum A core-roll work is complete. The checker and my new smoke test pass. One outside test (`uialerts_smoke.py`) now fails because of your parallel `UI/DropPanel.lua` change, not my files. Nothing has been tested in game.

**Files changed / created** (under `C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot\`)
- `Core\Roll.lua` (new, §19.1): sessions, a one-open-at-a-time queue, the RS/RR/RE/RW messages with their gates, `/roll` parsing from `CHAT_MSG_SYSTEM`, results and suggestion, the award flow, both popups, and `/cdl roll <link>` (plus `/cdl roll end`). The TOC already listed it after Loot.lua.
- `Core\Loot.lua` (§19.4): tracks whether the loot window is open and adds the master-loot give helpers. It opens the candidate list with the LootReserve-style fake loot button when needed. Demo review fixes:
  - `/cdl drop` never broadcasts in demo mode.
  - Loot-chat auto records need real council.
  - `/cdl test` drops are removed from saved history at logout and login.
- `Core\Ledger.lua` (§20):
  - In demo mode, reads and user actions (Award/Void) use an in-memory table that is emptied on every toggle, and nothing is sent.
  - Demo awards are purged once the guild roster is ready, with the "removed N demo award(s)" print.
  - Incoming sync rejects demo-name winners who aren't real guild members.
  - All network paths use real council checks.
- `Core\Demo.lua`: `GetFakeNames()` and `SimulateRolls(session)`. Fake players feed through the same `OnSystemMessage` / `OnResponse` path as real ones.
- `Core\Store.lua`: `GetWanters` entries gain `equippedList`; `equipped` is kept.
- `Core\Constants.lua`: `ns.SLOT_GROUP`.
- `Core\DB.lua`: default settings `roll = { duration = 30, announce = true, popup = true }`.
- `Core\Init.lua`: `ROLL_UPDATED` and `ROLL_STARTED` added to the message catalogue.

**Public API** — every §19.1 name and signature is exactly as specified. Additions:
- `Roll:Start(itemID, drop, copyIndex)` and `Roll:GetForItem(itemID, dropS, copyIndex)` take an optional copy index (see note 1).
- `Roll:CanAward()`, `Roll:CanEnd(id)`, `Roll:GetTimeLeft(id)`, `Roll:ConfirmGive(data)`, `Roll:ConfirmAward(data)`.
- `GetResults` rows also carry `min`, `max`, `awarded`, `isMe`, `isWinner`, `name`.
- `Loot:IsLootOpen()` and `Loot:IsLootCandidate(itemID, key)` (returns true, false, or nil when the candidate list isn't loaded yet).
- `Loot:GiveItem(itemID, key, onDone)` returns `true`, `false, reason`, or `nil, "pending"`; in the pending case `onDone(ok, reason)` is called later.
- `Store:GetEquippedList(key, sid)`, `Ledger:IsDemo()`, `Ledger:PurgeDemoAwards()`.

**Notes for the UI agent** (your DropPanel and RollFrame already match these):
1. **Same item twice in one drop:** each copy gets its own session, with field `c` = the k-th occurrence of the item in `drop.i` (the same counting as `CollectAwards`). Pass that copy index to `Start` and `GetForItem`; without it, `GetForItem` returns the latest session of any copy. `StartAll` queues every copy.
2. **Queued items** exist as sessions with `state = "queued"`, returned by `GetForItem` and `GetQueue()`. Cancelled sessions are skipped by `GetForItem` but `Get(id)` still returns them.
3. Awarded sessions return the rows frozen at award time, so they don't reshuffle afterwards.

**How the races are handled**
- **Roll arrives before RS:** unclaimed rolls are buffered for 2s and replayed into the next RS if they arrived in or after its start second. An RR that arrives before its RS is buffered for 15s.
- **Two council members start at once:** the earlier start (server time in RS, then id) wins identically on every client. The loser's starter sends `RE{x=true}` and re-queues its item at the front, unless both rolls were for the same item.
- **RE before the local timer:** the session closes at once and the 2s grace starts from that moment; the later timer does nothing. Other clients close on their own at end + 3s if RE never comes.
- **/reload mid-roll:** the session is simply gone on that client.

**Deviations from the addendum**
- An auto record from a real loot message while demo is on still goes to the real ledger and is sent when demo mode ends, so real raid data isn't lost.
- Incoming sync always merges into the real ledger.
- `roll.announce` controls both the start line and the winner line. When it's off, the winner line is only printed locally.
- Chat uses "->" instead of "→", because the raid-warning font likely has no arrow glyph. Local prints keep "→".
- The start chat line waits 0.5s (and up to 2s more for item data) and is skipped if the roll was cancelled meanwhile.
- A first out-of-range roll is replaced by the player's first valid roll; the count still shows ×2.
- An award does not lower the winner's own tier.
- The ledger entry is written only when the awarder is real council. A non-council master looter's award is recorded by the normal loot-chat auto entry.
- Starting a roll on an already-awarded copy is refused, except for rolls with no drop source.
- Leaving the raid closes open rolls and cancels my queue.

**CROSS-FILE NEEDS**
- `UI\Settings.lua`: expose `roll.duration` (15/20/30/45/60), `roll.announce` and `roll.popup` (UI agent).
- `scratchpad\rolls_smoke\` collided with the UI agent, who overwrote my `mock_extra.lua` and `run.py`. `rolls_smoke\test.lua` is still my test, so their run will execute it until they replace it. My test now lives in `scratchpad\rolls_core_smoke\`.
- `scratchpad\uialerts_smoke.py` now fails with `attempt to index field 'eq'`. It reads DropPanel's old `row.eq`, which the UI agent's change removed.
- `scratchpad\modeltest\mocks.lua` has no `ns:On` or `IsInGuild`, so the original modeltest now fails loading Ledger. A patched copy in `rolls_core_smoke\modeltest_copy\` passes 81/81.

**Results**
- **Checker** on all 8 files: 0 syntax errors, 0 global writes. One warning, for the `UPDATE_MASTER_LOOT_LIST` event; LootReserve registers it on this client.
- **`rolls_core_smoke\run.py`:** all checks pass, 0 Lua errors. It covers:
  - the purge
  - `SLOT_GROUP` / `equippedList`
  - RS/RR/RE/RW, the gates and the tier-then-roll suggestion
  - the grace period and the queue
  - both simultaneous-start directions
  - duplicate copies
  - master-loot give: direct, via the fake loot-button click, and the fallback to the confirm popup
  - `/cdl roll`
  - demo rolls: 2 passes, 1 double roll, 1 invalid roll, 1 silent wanter
  - demo ledger isolation
- An RS encodes to 137 bytes, so it fits one addon message.
- **Earlier suites:** `core_smoke` passes, `sync_sim` 34/34, `uicore_smoke` 0 errors.

**Verify in game**
- The `RANDOM_ROLL_RESULT` parsing, and that `RandomRoll` works solo in demo mode.
- A cross-realm roller (the roll line has no realm; a unique name match is used).
- As master looter: confirm the direct `GetMasterLootCandidate` path works, or that the fake-click path opens and then hides the master-loot list. Check below-threshold items are refused.
- That the "—" in the start line renders in a raid warning.
- Two council members clicking Roll at the same moment.
- That demo awards from 0.1 are purged once the guild roster loads.