# CDLoot SPEC — ADDENDUM I: raid sessions and the raid log

User request (2026-09-28): a raid log with a history of every raid: attendance, bosses, and the items handed out.
Agreed design: the session is **started and ended explicitly by the raid leader** (no location or timer
heuristics, which break on ghost runs, AFKs and long trash clears). Starting a raid also turns on the existing BiS lock
(Addendum F §38), and a session bar that is hard to miss stays visible until the leader ends the raid.

## 48. Session lifecycle

- **Start Raid** is available to the group authority (Addendum D/E: raid leader first) and to real council members in the
  raid. Places: the session bar's idle state (authority only), the Council tab toolbar, the drop panel footer,
  `/cdl raid start`.
- Start:
  1. creates the session `id = "<starterKey>-<serverTime>"` (deterministic, identical on every client);
  2. sets the BiS lock (F §38) if it isn't already on, with the same announce line;
  3. rides on `GS` as the new optional fields `rs = id`, `rsAt = start time` (0.6 clients ignore unknown fields).
     Mid-raid joiners and /reloads learn the session through `GQ`, exactly like `lk`.
- **End Raid** (the same people): confirmation dialog *"End the raid? Karazhan · 3:12:40 · 11/11 bosses"*, then clears
  `rs` / `rsAt` from `GS`, unlocks the BiS lists, and finalizes the record (`stop = now`).
- **Control follows the group.** If the starter leaves or disconnects, the session continues. Whoever becomes the
  authority (or any council member in the raid) can end it. The session never depends on one client staying online.
- **Safety net (only if nobody pressed End):** the group disbands, or the raid converts to a party → the session ends with
  `stop = last activity` (the last boss kill, award, or roster update with a member in the raid zone, taken from
  `GetRaidRosterInfo` zone). It is marked `autoEnded = true` so the UI can show it.
- **Forgot to start:** `ENCOUNTER_START` in a raid instance with no session → the authority gets a **chat reminder**
  (at most once per 30 min; a popup would get in the way of the pull and the loot windows). The session bar (§51) is
  the visible prompt. A session started after a missed pull is backdated to when the authority entered the instance.
- *Implemented (step 1):* start / end is **authority only** (`GroupRules:SetSession`, `/cdl raid start|end|status`);
  council members who aren't the authority are told who can. Letting them start or end through a request message is
  left for later.
- A lock without a session is still allowed (`/cdl lock` is unchanged). Ending a session always unlocks.

## 49. Data (`db.raids`, account-wide, guild-scoped like the Ledger)

```lua
db.raids[id] = {
  id = , g = guildKey, zone = "Karazhan", instID = 532, lockout = <instance ID if saved>,
  start = ts, stop = ts|nil, by = starterKey, endedBy = key|nil, autoEnded = true|nil,
  bosses = { { enc = 652, name = "Attumen the Huntsman", ts = , roster = { key, ... } } },
  att = { [key] = { c = classToken, j = firstJoin, l = lastLeave|nil, k = killsPresent, b = true|nil (bench),
                    off = { [bossIdx] = true } (offline at that kill) } },
}
```

- **Attendance = group membership**, not location. Join and leave times come from `GROUP_ROSTER_UPDATE`. A ghost running
  back, an AFK or a player outside the instance is still present.
- **Boss credit** = in the group when `ENCOUNTER_END` fires with success. Members who are offline (`UnitIsConnected`)
  are recorded in `off` for the council to review. They are **not** subtracted automatically.
- **Bench:** council can mark players as bench or standby (in or out of the group). Bench counts as full attendance.
  Council can also override credit for a single player and boss.
- **Ledger link:** new ledger entries get an optional `rid` (like `dg`: older clients drop it). It is **not** part of
  the digest (a council member who missed part of the raid would otherwise resync forever); a peer's `rid` fills in a
  missing one on merge. Entries without `rid` are matched to a raid by `start ≤ ts ≤ stop` for display.
- **Retention:** per-boss `roster` / `off` are dropped after 90 days (the totals in `att` stay); whole raids are kept
  according to the setting `raidlog.keepDays` (default 365).

## 50. Sync

- Every council client in the raid records the session locally. There's no single recorder.
- On End (and on login, for sessions from the last 14 days), council members exchange records using the Ledger's model:
  `RW` = the set of raid IDs + hashes per ISO week, and `RG` = records the peer is missing or has different. Only
  guild-wide council members take part (like `LW` / `LG`); raid-scope council members don't receive the guild's history.
- **Merge rules** (the same ID on two clients): attendance is the union, `j` = the minimum, `l` = the maximum,
  `k` = the maximum; bosses are the union by `enc`, with rosters combined; bench and override edits carry an edit
  timestamp and the newer one wins; `stop` = the explicit End if either client has one, otherwise the maximum.
- Records are validated like ledger entries (types, lengths, timestamps not in the future, caps on members and bosses).

## 51. UI

- **Session bar** (every raider with the addon, while `rs` is set): a small movable frame
  *"● Karazhan · 1:42:13 · 4/11 bosses · BiS locked"*. The authority and council see an **End Raid** button on it.
  It is hidden only by ending the raid (you can shrink it to a pill, but not close it). The position is saved.
- **Raids tab** (council):
  - List: date · zone · duration · bosses · attendees · items awarded; `(in progress)` / `(auto-ended)` tags.
  - Detail: boss timeline, the attendance grid (players × bosses; bench / offline / override marks, editable by council),
    and the awards of that raid (the Loot Log filtered by `rid`).
  - Players: attendance % over the last N raids or weeks, items received, items per raid attended, and last item received.
- *Implemented (step 2):* `UI/SessionBar.lua` (session and idle states; the idle "No raid session · Start raid" bar
  shows for the authority inside a raid instance and can be dismissed until the next instance; no shrink-to-pill
  yet) and `UI/RaidsTab.lua` (Raids / Players views, bench via right-click, Start/End in the toolbar, `/cdl raids`).
  Boss totals come from the item database: distinct encounter ids per instance (Chess counts; trash doesn't).
- **Council integration:** the drop panel and Council member view show *"Attendance 92% (last 8)"* next to a wanter.
- **Export:** a copy box with CSV of a raid or the player table.

## 52. Messages

- `GS` + `rs`, `rsAt` (§48). No other live message is needed. Boss kills and roster changes are observed locally by
  every client.
- `RW` / `RG` (§50), guild-wide council only, throttled like `LW` / `LG`.
- Demo mode doesn't affect the raid log: sessions come from the real raid and the real roster (never the demo raid).

## 53. Tests (`tests/raidlog`)

- Start by the RL → every client has the same `rs`, BiS is locked, the bar is shown; End → unlocked, record finalized.
- A non-authority, non-council raider can't start or end (forged `GS` ignored).
- Wipe → half the raid releases and stays out as ghosts → kill: everyone gets boss credit.
- Long trash clear with no kills: nothing ends.
- The RL disconnects mid-raid: the session continues; a new authority ends it.
- The raid disbands without End → auto-ended, `stop` = last activity.
- ENCOUNTER_START with no session → prompt; starting from it backdates to zone entry.
- Mid-raid joiner and /reload learn the session through `GQ`.
- Two council clients with gaps (one DC'd for 20 min) → after sync both have the merged, identical record.
- Awards during the session carry `rid`; the older Ledger digest is unchanged for entries without it.
- Mixed with a 0.6 client: no errors; it ignores `rs` and `rid`.
- Retention prunes rosters after 90 days and keeps the totals.
