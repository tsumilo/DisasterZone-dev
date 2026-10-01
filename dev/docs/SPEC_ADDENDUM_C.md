# DisasterZone SPEC — ADDENDUM C: roll popups close once the item is awarded or handed out

User feedback (2026-09-28, in-game): "After a loot has been awarded and given out, the roll windows could close for the raiders after like 5 seconds."

## Root cause (verified in the code)
- `RollFrame` already fades `FADE_AFTER_AWARD = 5` seconds after its session reaches `state == "awarded"`. But only ONE path sets that state: `Roll:Award(id, key)`, the roll-mode "Award to X" button, which broadcasts `RW`.
- `DropPanel:Award(itemID, key, bossKey)` is the plain "Award…" menu, reachable before or after a roll. It only calls `ns.Ledger:Award`; the roll session is never marked, so raider popups sit at "Rolls closed" for `LINGER_AFTER_CLOSE = 45` s.
- When the master looter hands the item out with Blizzard's normal master-loot dropdown, without clicking anything in DisasterZone, no `RW` is ever sent. Every raider does see `CHAT_MSG_LOOT` "X receives loot: [Item]." but `Roll` ignores it.

## 23. Required behaviour
1. **Loot-message closure (every client, council or not):**
   - `Loot` already parses `CHAT_MSG_LOOT` into (winnerKey, itemID). After parsing, and independent of the council/ledger checks, call `ns.Roll:OnItemLooted(itemID, winnerKey)` (guarded).
   - `Roll:OnItemLooted(itemID, key)`:
     - Find the most relevant session for `itemID` that is not awarded or cancelled and was started within the last 15 minutes. Preference order: open → closed → queued; newest first; for duplicate copies, the lowest copy index that is still unresolved.
     - Mark it with the internal `MarkAwarded(ses, key, true, "loot")`: `state="awarded"`, `winner=key`, `given=true`, `via="loot"`, freeze results. If it was open, close it first (no `RE` needed; every client sees the same loot message).
     - Fire `ROLL_UPDATED`.
     - If a queued session for the SAME item+drop copy exists, cancel it.
     - Do not write the ledger here; the ledger auto-record path already handles council clients.
   - **Tokens:** the loot message names the token itself (the same itemID that was rolled), so match by itemID only.
2. **Any explicit award marks the roll:**
   - `DropPanel:Award(itemID, key, bossKey)` (and its "Someone else…" path) must, when a roll session exists for that item and drop copy, go through the roll: call a new non-interactive `Roll:MarkAwardedExternally(id, key)`.
   - `Roll:MarkAwardedExternally(id, key)` performs the same state change as `Roll:Award` step 3: record + `RW` broadcast + announce, respecting `roll.announce`. It skips the give/confirm popups, because the panel already confirmed.
   - Avoid double ledger entries: exactly one manual entry per award.
   - The Loot Log "Add award…" dialog does NOT touch rolls (there is no drop context).
3. **Popup timing (RollFrame):**
   - Awarded → show "Won by Name" (gold "You won [Item]!" for the winner), then fade after 5s.
   - Hovering pauses the fade only while the mouse is over the frame; the fade resumes about 1s after the mouse leaves.
   - "Rolls closed" without an award still lingers (45s) as today, but it now resolves early when the loot message arrives.
   - The drop panel's roll-mode header shows "Awarded to X" (with "(looted)" when `via=="loot"`).
4. **Tests (harness):**
   - (a) A roll is closed, then the ML gives via `GiveMasterLoot` from Blizzard's UI path (simulate `world.broadcast_loot_received(winner, itemID)` without any DisasterZone award click) → every raider popup reaches "Won by X" and hides within 5s + fade.
   - (b) Plain "Award…" from the drop panel while a roll session exists → `RW` sent, popups close, exactly 1 ledger entry.
   - (c) Two copies of the same item: two loot messages close the two sessions in order.
   - (d) A loot message for an item with no session changes nothing.
