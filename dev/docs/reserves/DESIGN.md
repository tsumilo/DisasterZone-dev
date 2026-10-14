# Loot reserves (unreleased 1.4.3)

User's rules (2026-10-14, mockup claude.ai/artifact/FXPwfnvVHD3QPkNRGv5UKr v2):

- **Soft reserve**: whoever reserved an item rolls on it, highest roll wins. One reserver: theirs, no roll.
- **Nobody reserved it**: up for grabs, everyone rolls, highest wins.
- **Guild hard reserves** (items the leader marks): the loot council decides among guild members, as today.
  Nobody from the guild wants it: up for grabs for everyone.
- Soft reserves per player: set per raid, 1-3 (default from raid size: 10 -> 1, 25 -> 2). One per item (no
  multireserve). No SR+, no +1, no reserving ahead: reserves open on the night from the session bar and close at
  the first pull (the leader can still change them after).
- Items someone else reserved: no roll pop-up, a 5 s line instead.
- Ways in: the DisasterZone picker, whispers (!sr / !res / !reserve [item], list, cancel, rules), LootReserve
  clients (we answer as a LootReserve host), softres.it CSV and Gargul string import. Exports: CSV (softres /
  LootReserve columns), Gargul string, raid chat post.
- Two-way LootReserve: when someone else in the raid hosts a LootReserve session, we read its reserves instead
  of hosting (and never answer Hello then).

## Pieces

| File | What |
|---|---|
| Core/Reserves.lua | the reserve session: rules, reserve / cancel / lock, guild HR list, sync to the raid, who decides an item (Decide), award bookkeeping, wrap-up, demo night |
| Core/ReserveChat.lua | whisper / raid chat commands for players without the addon, announcements |
| Core/ReserveLR.lua | LootReserve protocol: host (Hello, SessionInfo, ReserveItem/Result, Cancel, RequestRoll, SendWinner) and reader |
| Core/ReserveIO.lua | softres.it CSV, Gargul string, LootReserve CSV import; CSV / Gargul / chat export |
| UI/Reserves.lua | picker (raider), list (leader), wrap-up, import box |
| hooks | GroupRules feature `reserve`, SessionBar toggle + drawer rules, Roll: reserve-limited plain rolls + council among guild members, DropPanel reserve rows, RollFrame lines + suppression, Demo |

## LootReserve protocol (vendored source dev/thirdparty/LootReserve, d0afcf1c 2026-09-04)

AceComm prefixes `LootReserve` and `LootReserve1`..`LootReserve40`. Message `op|a|b|...|`; ops > 3 carry
`len|payload` (len < 0: raw, len > 0: LibDeflate deflate + EncodeForWoWAddonChannel, len = raw length).
Hello (3) has no payload beyond `3|`. Players are short names (same realm).
Category ids (TBC): Kara 2010, Gruul 2020, Mag 2030, SSC 2040, TK 2050, Hyjal 2060, BT 2070, ZA 2080, SWP 2090.
ItemConditions pack: `-` hidden (used for the guild's hard reserves).
ReserveResult codes: 0 OK, 3 NotAccepting, 4 NotMember, 5 ItemNotReservable, 6 AlreadyReserved, 7 NoReservesLeft,
9 Locked. CancelReserveResult: 0 OK, 6 NotReserved, 7 Forced, 8 Locked.

## Built (2026-10-14, branch rf/reserves)

- Wire: RVS (whole list, host -> RAID), RVQ (ask, only after a login / reload inside a raid, 8 s later, retried),
  RVR (a member's reserve / cancel -> host). The host pushes RVS when the raid grows. A list from a sender not yet
  placed is kept 30 s and retried. GS `rv = 1` carries the reserve feature (rf keeps "lrk" for older clients).
- RS `rv` / `rk`: how reserves decide the roll and who reserved it (receivers don't need the list). Solo reserve =
  a 5 s session that suggests the reserver (suggestedBy "reserve"). Rows: `unres` (didn't reserve), `notGuild`
  (a guest on a guild item) never suggested, votes for them don't count. `Roll:StartUpForGrabs` re-rolls a guild
  item for everyone (drop panel ··· > Up for grabs).
- Settings: reserves.lootReserve (default on), reserves.showWhispers (default off). Slash /dz reserves
  [open|list|wrap|import|demo]. Demo: Settings > Demo a roll > Loot reserves, or /dz reserves demo.
- Data/Raids.lua RaidMeta `lr` = LootReserve's category id.

## Tests (dev/tests/reserves)

test_reserves (list, rules, sync, whispers, rolls, reload / handover), test_lootreserve (LootReserve's real Comm.lua
and Constants.lua in a pug client: host and reader), test_io (softres CSV, Gargul string, LootReserve / Gargul CSV,
read-backs, wrap-up), test_edges (new leader, 40-player list size, stray chat, pop-ups, reserves off), test_demo (all
7 steps x 3 views, nothing sent). Audit views "Reserves - ...".

## Not verifiable outside the game

- LootReserve's real window (XML) reacting to our SessionInfo (PendOpen, loot list for the category, hidden items).
- Gargul's actual softres export strings (format taken from its importer; standard Base64 assumed).
- ChatFrame_AddMessageEventFilter hiding the host's !sr whispers and [DZ] answers.
- Raid warning permission (assist) for the announcements; whisper rate with 25 pugs at once.
- Toast and roll pop-up stacking at the first boss; the demo panel position on small screens.
