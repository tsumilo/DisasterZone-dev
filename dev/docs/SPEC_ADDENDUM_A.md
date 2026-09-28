# CDLoot SPEC — ADDENDUM A (after the first in-game test by the user)

Read together with `SPEC.md` (sections 18–20 continue its numbering). Topics: rolls, paired-slot display, demo ledger isolation.

The user loaded v0.1 in game (demo mode + /cdl test) and the drop panel works. New requirements follow.

## 18. Paired-slot "currently wearing" display
For rings, trinkets and weapons, the council must see BOTH currently equipped items of the slot pair, not only the slot the BiS entry sits in.
- `Store:GetWanters` entries gain `equippedList`: an array of equipped itemIDs for the entry's slot group, non-nil values only, in slot order.
  - sid 11/12 → `{eq[11], eq[12]}`
  - sid 13/14 → `{eq[13], eq[14]}`
  - sid 15/16 → `{eq[15], eq[16]}`
  - sid 17 → `{eq[17]}`
  - any other sid → `{eq[sid]}`
  - Keep `equipped` (= eq[sid]) for compatibility.
- Add `ns.SLOT_GROUP[sid]` in Constants: `{11,12}`, `{13,14}` and `{15,16}` for those sids, else `{sid}`.
- DropPanel candidate rows show up to 2 small (14px) equipped icons side by side on the right. Each has its own tooltip line "Currently wearing (Ring 1)" etc.
- Council roster cell tooltips and the council lines of item tooltips show "Wearing: A, B".
- The player's own roll popup (§19.3) shows their own equipped items for that slot group.
- Layout polish from the user's screenshot: spec names are truncated ("Restorati…", "Assassina…").
  - Widen the drop panel (PANEL_W 340 → 400).
  - Give the spec column enough width for "Restoration" / "Beast Mastery".
  - Keep the right-hand icons aligned.

## 19. Rolls (new feature), as decided with the user
Decisions:
- **Everyone in the raid may roll.** Raiders get only **Roll / Pass**, which is a real `/roll 1-100`.
- The addon **suggests a winner**:
  - Priority tier: **BiS main (not obtained)**, then **BiS alt (not obtained)**, then **not listed / already obtained**.
  - Within a tier, the **highest roll** wins.
- The ML or council **confirms** the winner.
- If the confirming player is the **master looter with the loot window open**, CDLoot **hands the item over via master loot after a confirmation popup**. Otherwise it records and announces the award.

### 19.1 Core/Roll.lua — `ns.Roll` (module; add to the TOC after Core/Loot.lua)
Session (one per rolled item):
```lua
session = {
  id = "Emilo-1790000000-1",   -- ShortName(starter) .. "-" .. serverTime .. "-" .. counter
  i = itemID, s = dropSourceKey or "", b = bossRefKey or "",
  starter = key, startedAt = GetServerTime(), duration = 30,
  endsAt = GetTime() + duration,            -- local clock
  state = "open" | "closed" | "awarded" | "cancelled",
  rolls = { [key] = { roll = n, min = 1, max = 100, at = GetTime(), count = 1, invalid = bool } },
  responses = { [key] = "roll" | "pass" },   -- intent sent by addon users (RR)
  winner = key|nil, given = bool,
}
```
**Queueing**
- **Only one session is "open" at a time.** A /roll in chat can't be attributed to an item otherwise.
- `Roll:Start(itemID, drop)` while another session is open → the item is **queued**. When the open session closes, the next queued one starts after 2s.
- `Roll:StartAll(drop)` queues every item of a drop, skipping items already awarded.

**Who may start:** a council member (`ns.Guild:AmICouncil()`), the master looter, or the raid leader/assist. The player must be in a raid. In demo mode starting is always allowed and stays local.

**Starting**
- Broadcast `RS` on RAID (alert class).
- Post one chat line when setting `roll.announce` is on: `"CDLoot: Roll for [Item] now — /roll (30s)"`. Send it via `ns.UI:AnnounceLine`, guarded.
- Handle the session locally too. The starter sees the council view and, if in a raid, also gets the roll popup; the starter may roll as well.

**Reading rolls**
- Rolls come from `CHAT_MSG_SYSTEM`, matched with a pattern built from the globalstring `RANDOM_ROLL_RESULT` (enUS "%s rolls %d (%d-%d)"). Escape magic characters. LootReserve/Server.lua ~3425 is the proven approach on this client.
- The name goes through `Util.NormalizeName`.
- A roll counts for the currently open session if it arrives while the session is open, or within a 2s grace period after `endsAt`. Later rolls are ignored.
- The range must be 1–100. Any other range sets `invalid=true`: the roll is shown but never suggested.
- If a player rolls more than once, keep the FIRST roll and increment `count` (shown as "rolled N×").

**Addon users' intent**
- The raider clicks Roll → `RandomRoll(1, 100)` (a global, used by LootReserve on this client) and send `RR{id, r="roll"}`.
- Pass → `RR{id, r="pass"}`.
- Players without the addon just type /roll.

**Closing**
- The starter's client closes the session when `endsAt` passes (C_Timer) and broadcasts `RE{id}`.
- Other clients close on `RE`, or at their own `endsAt + 3s` as a fallback.
- The starter or a council member can close early with `Roll:End(id)`.

**Suggestion:** `Roll:GetResults(id)` returns a sorted array of rows:
```lua
{ key, roll, invalid, count, response, tier, which, phase, obtained, inRaid,
  classFile, spec, equippedList, wonTonight, suggested=bool, tie=bool }
```
- Rows are built from rolls ∪ responses ∪ BiS wanters currently in the raid. Wanters who haven't rolled appear with `roll=nil`, shown as "waiting…" or "no roll".
- `tier` comes from that player's `ns.Store:GetWanters(itemID)` entry:
  - 1 = main & not obtained
  - 2 = alt & not obtained
  - 3 = anything else (not listed, or obtained)
- Sort order: valid rolls first → tier ascending → roll descending → name. Passes go last.
- `suggested` = the first valid row. If more than one row shares its tier and roll, set `tie=true` on all of them.

**Award:** `Roll:Award(id, key)`. Any council member, ML or leader may award. It is typically done from the panel after the session closes; it is allowed while the session is open, and then it closes the session first.
1. If `ns.Loot:CanGiveItem(itemID)` is true (I am master looter, `LootFrame` is open, the item is in a loot slot, and `key` is a master-loot candidate for that slot), show StaticPopup `CDLOOT_GIVE_ITEM`: "Give [Item] to Name?".
   - On accept, call `ns.Loot:GiveItem(itemID, key)` (§19.4). On success, continue with step 3.
   - On failure, print why, then fall through to step 2's confirmation.
2. Otherwise show StaticPopup `CDLOOT_CONFIRM_AWARD`: "Award [Item] to Name? (hand it out via master loot or trade)".
3. Record and announce:
   - `ns.Ledger:Award(itemID, key, session.b, "roll " .. roll)` creates a manual entry. The later CHAT_MSG_LOOT auto entry is hidden by the §11 de-dupe rule.
   - Set `state="awarded"`, `winner=key`, `given=bool`.
   - Broadcast `RW{id, w=key, g=given}`.
   - Announce `"CDLoot: [Item] → Name (rolled 87, BiS)"`. The tier word is "BiS", "BiS alt" or "roll".

**Messages:** all RAID / alert class `CDLa`, single part. Register them with `Comm:Register`.

| t | fields | gate on receipt |
|---|---|---|
| `RS` | `id, i, s, b, d` | sender in my raid AND (IsCouncil(sender) or sender is raid leader/assist or master looter per `GetRaidRosterInfo`) |
| `RR` | `id, r` ("roll"/"pass") | sender in my raid |
| `RE` | `id` | sender == session.starter or IsCouncil(sender) |
| `RW` | `id, w, g` | sender == session.starter or IsCouncil(sender) or sender is leader/assist/ML |

**Other rules**
- New internal messages, added to the §3.3 catalogue:
  - `ROLL_UPDATED(sessionID)`: any change (start, new roll, response, close, award).
  - `ROLL_STARTED(session)`: used by the raider popup.
- API: `Roll:Start(itemID, drop)`, `Roll:StartAll(drop)`, `Roll:End(id)`, `Roll:Award(id, key)`, `Roll:Get(id)`, `Roll:GetActive()` (the open session or nil), `Roll:GetForItem(itemID, dropS)` (latest session for that item and drop), `Roll:GetQueue()`, `Roll:GetResults(id)`, `Roll:RespondRoll(id)`, `Roll:RespondPass(id)`, `Roll:CanStart()`, `Roll:OnSystemMessage(text)`, `Roll:OnResponse(key, id, r)`.
- Sessions are in memory only (not saved), pruned after 2h.
- Settings, added to DB defaults: `roll = { duration = 30, announce = true, popup = true }`. Expose them in the Settings UI: duration dropdown 15/20/30/45/60, and checkboxes.
- Slash: `/cdl roll <itemlink>` starts a roll for a linked item (council/lead/ML).

### 19.2 Demo rolls
When `ns.Demo:IsEnabled()`:
- `Roll:Start` stays local: no RS broadcast and no chat line (print locally instead).
- `ns.Demo:SimulateRolls(session)` schedules fake raid members' outcomes over 2–12s, using the seeded PRNG:
  - most demo-raid members roll 1–100
  - 2 of them pass (via RR "pass")
  - 1 BiS wanter never responds
  - 1 player rolls twice (the second roll is ignored and flagged)
  - 1 player rolls 1–50 (invalid)
- Feed these through the SAME parsing path as real rolls: `Roll:OnSystemMessage(string.format(RANDOM_ROLL_RESULT, shortName, n, 1, 100))` and `Roll:OnResponse(key, id, "pass")`.
- The player's own popup also shows. In game, clicking Roll calls `RandomRoll`, which produces a real system message that is parsed normally, even solo.

### 19.3 UI/RollFrame.lua — `ns.RollFrame` (raider popup; add to the TOC after UI/DropPanel.lua)
**Behaviour**
- Listens to `ROLL_STARTED`, and to `ROLL_UPDATED` to update or close.
- Shown to everyone in the raid (including council) when the `roll.popup` setting is on.

**Frame**
- `CDLootRollFrame`, about 380 × 96, movable, position saved (default top-centre, y=-220), DIALOG strata.
- Styled like Blizzard's group-loot roll frame: dark backdrop, gold border.

**Contents**
- A 36px item icon (tooltip; shift-click links it) and the item name in quality colour.
- Line 2: own BiS status from `ns.BiS:MatchItem(itemID)`:
  - "★ Your P2 BiS (main) — Head" in gold
  - "Your P3 alt — Ring 1" in blue
  - "Not on your BiS list" in grey
- Line 3: "Wearing:" followed by up to 2 × 16px icons of the player's own equipped items for the slot group (`GetInventoryItemID("player", invSlot)`).
- A countdown StatusBar showing time left.
- Buttons **Roll** and **Pass**.

**States**
- After responding, the buttons hide. The text shows "Rolling…" until the roll is parsed, then "You rolled 87", or "Passed".
- When the session closes: "Rolls closed".
- When awarded: "Won by Name", or gold "You won [Item]!" if it's me. The frame then fades after 5s.
- Queued sessions: show the next one when it starts.
- No protected actions are involved, so it is OK to show in combat.

### 19.4 Loot.lua additions (master-loot give)
- `Loot:FindLootSlot(itemID)` → the slot index if the loot window is open and `GetLootSlotLink(slot)` has that itemID. "Open" means `LootFrame:IsShown()`, or a tracked `lootOpen` flag between LOOT_OPENED and LOOT_CLOSED.
- `Loot:CanGiveItem(itemID)` → `Util.IsPlayerMasterLooter()` and `FindLootSlot(itemID) ~= nil`.
- `Loot:GiveItem(itemID, key)` → returns `true` or `false, reason`, and never throws:
  - Find the slot.
  - Iterate candidate indices 1..40 with `GetMasterLootCandidate(slot, i)`, comparing `Util.NormalizeName(name) == key`.
  - Call `GiveMasterLoot(slot, i)`.
  - Study LootReserve/Server.lua ~4076–4144. It opens the master-loot list with a fake `LootButton_OnClick` first, because candidate data may need `OPEN_MASTER_LOOT_LIST`. Replicate that approach if needed, guarded.

### 19.5 DropPanel integration (council / ML / lead view)
**Buttons**
- Each item block gets a new **Roll** button, next to Announce / Award…, visible when `ns.Roll:CanStart()`.
- The footer gets **Roll all**.

**Roll mode.** When an item has a roll session (`Roll:GetForItem(itemID, drop.s)`), its block switches to roll mode:
- The header line shows the session state:
  - "Rolling — 0:18 left", a live countdown driven by a 0.5s ticker that runs only while the session is open
  - "Queued"
  - "Rolls closed"
  - "Awarded to X"
- Rows come from `Roll:GetResults(id)`. Each row shows:
  - presence dot, class icon, name, spec
  - BiS badge: `[BiS]` / `[Alt]` + phase / `—`
  - the roll number, large and right-aligned: grey "…" while waiting, grey "pass", red "(1-50)" if invalid, "×2" if rolled more than once
  - 2 equipped icons and "won N"
- The `suggested` row gets a gold highlight and a "Suggested" tag. With a tie, every tied row is marked "tie".
- Buttons in roll mode:
  - **End roll**, while open.
  - **Award to <suggested>**, the primary button, enabled once closed (or at any time).
  - Clicking a row opens a context menu: "Award to Name" and "Link item".

**Other**
- Awarded items show "Awarded to Name" in green in both modes.
- Refresh on `ROLL_UPDATED`, debounced 0.1s.

## 20. Demo isolation of the award log (bug)
Currently, awards made in demo mode (to fake members) are written to the REAL ledger and would sync to other council members. Fix:
- `Ledger`: while `ns.Demo:IsEnabled()`, all reads and writes use an in-memory `demoEntries` table (empty on each enable), and nothing is sent (no A/LW/LG). Disabling demo discards it.
- On `OnLogin`, purge demo awards from `ns.db.ledger`:
  - Remove any entry whose winner key's name part is one of the Demo fake names (add the API `ns.Demo:GetFakeNames()`) AND whose key is not a real guild roster member.
  - Defer the purge until the roster is ready.
  - If N > 0, print "CDLoot: removed N demo award(s) from the loot log."
- Make sure no other demo data leaks into SavedVariables or comms (review Store/Sync/Loot for demo keys).
