# DisasterZone SPEC — ADDENDUM E: picked council (GM + raid leader) replaces the Guild Info tag

User decisions (2026-09-28):
- The council is chosen by picking characters from a **searchable dropdown of online guild members**.
- **Who may pick:** the **Guild Master** and the **current Raid Leader**.
- **Lifetime:** stored "until changed" (overwritten on demand).
- **Remove Guild Information entirely:** DisasterZone no longer reads or writes the Guild Info text. No `CDL{...}` tag, no rank threshold and no phase in the Guild Info.

This supersedes SPEC §13 (the guild config tag), the Settings "Loot Council (guild settings)" editor, and the guild-info safety/backup code added to Core/Guild.lua on 2026-09-28 (`WriteConfig`, `/dz guildinfo`, `DISASTERZONE_GUILDINFO_*` popups). Remove those. Keep `DisasterZoneDB.guildCfg` readable only so a migration can drop it (§33).

## 29. Council model
Two council lists exist, plus two implicit members.

| Source | Set by | Applies to | Stored | Transport |
|---|---|---|---|---|
| **Guild council** | the Guild Master (`rankIndex == 0` in the live guild roster) | every guild member | every client's SavedVariables (`db.council.guild`) | `CG` on GUILD, plus relay (§31) |
| **Raid council** | the current raid leader (`GetRaidRosterInfo` rank == 2) | members of THAT raid only, while in it | the leader's own `db.council.myRaidList` ("until changed"); receivers keep it in memory only for the current raid | `CR` on RAID |
| implicit | — | — | — | the GM is always council (guild-wide); the current raid leader is always council for their raid |

- `Guild:IsCouncil(key)` =
  - (`key` is the GM), or
  - `key` ∈ the guild council, or
  - (I am in a raid AND (`key` is the current raid leader OR `key` ∈ the accepted raid council of my current raid)).
  - Exclusions: none (there's no "-name" any more). The key must be in the guild roster, except the raid leader and raid-council members, who only need to be in my raid (cross-guild pugs still work for raid-scope).
- `Guild:AmICouncil()` uses the same rule for me. Demo mode keeps forcing true.
- `Guild:GetCouncilSource(key)` → `"gm" | "guild" | "raidleader" | "raid" | nil` (for UI labels).
- `CONFIG_UPDATED` fires whenever the effective council set or my own status changes (guild list accepted, raid list accepted or cleared, raid leader changed, joined or left a raid, GM changed).
- **Raid-scope caveat:** a guild member outside that raid does NOT treat raid-council members as council. So whisper gates (`L`/`R`/`M`/etc.) from a raid-council member are accepted only by clients in the same raid. That is intended.

## 30. The picker UI (Council tab → "Loot Council" sub-view or a panel at the top of the Council tab; also reachable from Settings)
- **Visibility and editing:**
  - Visible to everyone.
  - Editable when I am the GM (guild list) or the current raid leader (raid list).
  - When I am both: two sections ("Guild council — everyone, until changed" and "This raid's council — for raid members").
- **Searchable dropdown:** a `SearchBoxTemplate` edit box plus a dropdown panel below it (a ScrollBox list of max ~10 visible rows).
  - The list holds **online guild members** sorted by name, filtered by the search text (case-insensitive substring; accents as typed).
  - Each row: class icon, class-coloured name, rank name (grey), and a checkbox showing whether they are on the list being edited.
  - A "Show offline members" checkbox includes offline members (for the guild list).
  - For the raid list, current raid members come first, then online guild members.
  - Clicking a row toggles membership in the **draft**.
- **The draft list:**
  - Shown as chips/rows with a remove "x".
  - Buttons: **Save & share** (disabled until the draft differs), **Revert**, **Clear list** (with confirmation).
  - Status line: "Shared 2m ago · N members" / "Not shared yet".
- **Read-only view** for everyone else: "Guild council: A, B, C (set by <GM> 3d ago)" and, when in a raid, "This raid's council: D, E (set by raid leader <RL>)". Every name is class-coloured, with an online dot.
- The Settings panel's old "Loot Council (guild settings)" section is replaced by the same read-only summary + a button "Edit council…" that opens the picker (when allowed).

## 31. Messages & trust
- **`CG` (guild council)**, GUILD, ctrl class. Fields: `{t="CG", rev=<GM server time when saved>, m={keys...}, ph=phase (1..5), by=<GM key>}`.
  - **Sending:** the GM sends it on Save, and replies to `CQ` (below).
  - **Accept directly from the sender** when the sender is the GM per the live roster (`rankIndex == 0`) and `rev` > the stored rev.
  - **Accept a relayed copy** (the sender is not the GM) when all of these hold:
    - `by` is the current GM per the roster;
    - the relaying sender is council under my CURRENTLY accepted guild list, or (trust-on-first-use) I have no accepted guild list at all AND the relaying sender is listed in the relayed `m`;
    - `rev` > the stored rev;
    - `rev` ≤ GetServerTime() + 300 (reject implausible future revs).
  - **Validation:** `m` ≤ 40 keys, all strings ≤ 48 chars; `ph` in 1..5; unknown keys (not in the roster) are allowed but ignored for council checks until they appear.
  - **Stored as** `db.council.guild = {rev, members={[key]=true}, phase, by, recvAt}`.
- **`CQ` (query)**, GUILD, ctrl class. Sent once, ~20–40s after login (random delay), when my stored guild list is older than 7 days or missing. Replies: the GM replies with `CG`. Council members with a stored list reply after a random 2–8s, and only if no other `CG` for the same rev was seen in the meantime (suppression). Rate-limit: 1 reply per 60s per client.
- **Guild HELLO piggyback:** council clients include `cg=<rev>` in HELLO. Anyone whose stored rev is lower sends `CQ` (whisper to that council member).
- **`CR` (raid council)**, RAID, alert class. Fields: `{t="CR", rev=<leader server time when saved>, m={keys...}}`.
  - **Sending:** the raid leader sends it when they become leader of a raid (debounced 3s after GROUP_UPDATED / PARTY_LEADER_CHANGED), whenever they save a change, and in reply to `CRQ`.
  - **Accept only when the sender is the current raid leader per `GetRaidRosterInfo`.**
  - **Store:** in memory only, `raidCouncil = {leader=senderKey, rev, members}`. Clear it when I leave the raid or the leader changes. A new leader's `CR` replaces it; if the new leader has none, the raid council is empty.
- **`CRQ`**, RAID, ctrl class. Sent by a client ~3s after joining a raid or /reload while in a raid, when it has no raid council. The raid leader replies with `CR`.
- **Leader's own list:** `db.council.myRaidList = {rev, members={...}}` persists "until changed"; it is re-shared automatically each time that player leads a raid. Only the leader's client stores it; others hold it in memory for the raid.
- **Removed:** Guild Info reading/parsing and the `rN`/`pN`/`+`/`-` tag grammar.

## 32. Phase
- The guild default phase is `db.council.guild.phase`, set by the GM in the picker (a phase dropdown next to Save; default 1).
- Raid override: add `ph` to the Addendum-D group rules (`GS`). The raid leader sets the phase for the raid; it's shown in Settings as a group rule ("Set by <RL> for this group").
- `Guild:GetGuildPhase()` → the group-rules phase if in a group with rules, else the guild phase, else 1. `GetViewPhase()` keeps the personal override on top.

## 33. Migration & cleanup
- On login, if `db.guildCfg` exists → delete it (one time). Print once, only if it contained a tag: "DisasterZone no longer uses the Guild Information text. You can delete the CDL{...} line from your Guild Info."
- Remove: `Guild:WriteConfig`, `BuildTag`, `ParseConfig`, the info-text readers/writers, `/dz guildinfo`, the `DISASTERZONE_SAVE_CONFIG` and `DISASTERZONE_GUILDINFO_*` popups, `db.guildInfoSeen`, and `db.guildInfoBackups` (delete these on migration too). Remove the obsolete tests (tests/guildinfo, and tag-based parts of tests/boot-ui/test_access.py, test_settings.py, sync council-membership) and REPLACE them with picker/council-model tests (§34).
- Group-rules authority (Addendum D §24): the raid leader is now always council for their raid, so the "raid leader if council" eligibility simplifies to "raid leader; else master looter". Party: party leader if council (guild list/GM) or if they enabled dungeon mode; else a guild-list council member in the party.

## 34. Tests (tests/council/test_council_picker.py + updates to the existing suites)
- The GM picks 3 online members → `CG` → all online clients show them as council; an offline member logs in later and gets it via `CQ` (the GM online, or relay from a council member while the GM is offline).
- A forged `CG` from a non-GM claiming `by=GM` with a new rev: rejected unless the relayer is council under the receiver's current list; TOFU on a fresh client only if the relayer is in the relayed list. A future rev > now+300 is rejected.
- The GM edits the list (remove one) → that member loses council status everywhere: tabs hide, and whisper gates reject.
- Raid leader flow:
  - The RL (non-officer) picks 2 raiders → only raid members treat them as council; a guild member outside the raid does not.
  - The raid disbands → the raid council is cleared everywhere.
  - The same RL leads a new raid → the list is re-shared automatically.
  - The leader changes mid-raid → the new leader's list (or empty) applies.
- The raid leader is council for their raid (the Council tab is visible to them in the raid, hidden after leaving unless on the guild list).
- A client joining mid-raid, or doing /reload, gets `CR` via `CRQ`.
- The searchable dropdown: filters by substring, toggles the draft, Save & share is disabled until changed, Revert, Clear with confirmation, "show offline".
- Migration: an old `guildCfg` is removed, the notice prints once, and nothing reads Guild Info (assert `C_GuildInfo.GetInfoText` is never called — spy on it).
- Sync still works: a raid-council member receives raid members' lists after being picked (the promotion HELLO path); guild-list council receives everyone's lists.
