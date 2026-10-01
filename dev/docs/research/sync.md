# DisasterZone data sync layer: survey of installed addons and proposed protocol

I only read files; nothing in the WoW folder was changed. One helper script was written to the scratchpad for the size estimates in §4.8: `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\sizes.py`.

All paths below are relative to `C:\World of Warcraft\_anniversary_\Interface\AddOns\`.

---

## 1. Summary

- **Transport:** use AceComm-3.0 with ChatThrottleLib (CTL) and LibDeflate. Use LibSerialize or a compact positional encoding for list bodies. Every addon that rolled its own chunking has size or collision bugs (RaidHelper_TBC, and TehBoxLootCouncil's raw-send paths).
- **Three prefixes, one priority each:**
  - `CDL` for small control messages.
  - `CDLD` for bulk list data.
  - `CDLA` for loot alerts.
  - This keeps a council member's catch-up transfer from delaying a loot-drop alert, both in CTL and in the client's per-prefix throttle.
  - It also avoids mixing multipart messages of different priorities on one prefix. AceComm queues by prefix only, and the receiver reassembles by `prefix+distribution+sender`.
- **Data model:** each player's list carries a revision number that only the owner's client increases. The highest revision wins. The owner never accepts someone else's copy of its own list, except through an explicit "restore". This is the rule Attune uses (Attune.lua:4438-4448), but with owner-set revision numbers instead of receiver-clock timestamps.
- **Catch-up works like Details' guild sync, reduced to what's actually stale:**
  - A council member logging in broadcasts a small manifest (name and revision per player, 2–4 message parts) on GUILD.
  - Online raiders whose list is newer push it to that council member.
  - For raiders who are offline, the council member asks one online council peer for its manifest, then requests only the entries it's missing.
- **Who is on the council:** a tag in the Guild Information text, e.g. `CDL:r2,+Alice,-Bob`.
  - The server stores it, every guild member can read it, and only ranks allowed to edit guild info can change it.
  - It needs no protocol and works while the GM is offline.
  - Each client checks every incoming council message against the server's guild roster, using the sender name the server attaches, never a name inside the message body.
- **Privacy:** default to council-only. Raiders whisper their lists to online council members; council members relay to each other over OFFICER (if council ranks match officer-chat ranks) or by whisper. The GM can switch the guild to an "open" GUILD mode with a tag flag. Council annotations and the awards ledger always stay council-only.
- **Loot drops:**
  - The master looter's client scans the loot window on `LOOT_READY`.
  - It de-duplicates by corpse GUID and broadcasts a one-part `DROP` (source plus item IDs) to RAID at ALERT priority on `CDLA`.
  - Each client works out "who has this on their BiS list" from its own cache, using a precomputed item-to-players index.
  - Tier tokens need a token-to-pieces mapping.
- **Sizes:** a typical list is 1 message part (~140–250 bytes on the wire). The worst case is 4–5 parts. A manifest for 80 players is 2–4 parts. A brand-new council member downloading all 80 lists needs ~31–76 parts, roughly 12–70 seconds in the background.

---

## 2. Platform facts that shape the design

### 2.1 Size and multipart messages
- Addon messages max out at 255 bytes; bytes beyond that are cut off without warning (Raidify/Libs/Ace3/AceComm-3.0/AceComm-3.0.lua:95).
- AceComm multipart spends 1 byte per part on a control marker, leaving 254 bytes of payload (AceComm-3.0.lua:119-136; Questie/Modules/Network/CommsEncoding.lua:24).
- AceComm's send queue name is just the prefix (AceComm-3.0.lua:96). The receiver's reassembly key is `prefix\tdistribution\tsender` (AceComm-3.0.lua:165,179,200).
  - AceComm's own comment warns that mixed priorities cause out-of-order delivery (AceComm-3.0.lua:84).
  - **Rule for DisasterZone:** each (prefix, distribution) pair carries multipart messages at one priority only.
- AceComm passes `Ambiguate(sender,"none")` to handlers (AceComm-3.0.lua:244): "Name" for your own realm, "Name-Realm" otherwise. DisasterZone should normalize everything to "Name-Realm" to match `GetGuildRosterInfo`.

### 2.2 Throttling
- **ChatThrottleLib v32** (the newest installed, e.g. Raidify/Libs/Ace3/AceComm-3.0/ChatThrottleLib.lua):
  - Limits: `MAX_CPS=800` bytes/s, `MSG_OVERHEAD=40` bytes per message, `BURST=4000` (lines 60-63).
  - A full 255-byte part costs 295 bytes of budget, so a client sustains about 2.7 parts/s, or ~13 parts in one burst.
  - It throttles hard for a few seconds after every `PLAYER_ENTERING_WORLD` (lines 223-224, 436-442).
- **Per-prefix client throttle:** modern Classic clients also throttle each prefix separately.
  - CTL v25 and later detects `Enum.SendAddonMessageResult.AddonMessageThrottle` and moves the queue into a "Blocked" ring to retry later (ChatThrottleLib.lua:198-200, 349-356, 380-406).
  - LootReserve rotates through 41 prefixes (`LootReserve`, `LootReserve1`…`LootReserve40`) to get more budget (LootReserve/Comm.lua:8, 50-65).
  - The exact numbers are commonly cited as a burst of about 10 messages, then about 1/s per prefix. **Verify in game.**

### 2.3 Identity and trust
- The `sender` in `CHAT_MSG_ADDON` is set by the server and can't be forged.
- Guild rank (from `GetGuildRosterInfo`) and raid rank (from `GetRaidRosterInfo`) are server-authoritative.
  - TBCRaidKompass relies on this: "rank in the roster is synced by the game itself – not forgeable" (TBCRaidKompass/NotesSync.lua:470-476, receive check at 355-364).
- A name written inside a payload proves nothing. Attune keys received data by `data[1]` from the payload (Attune.lua:3887), so any guild member can spoof another member's record.

### 2.4 Channels
| Distribution | Who receives | Send cost | Notes |
|---|---|---|---|
| GUILD | every online guild member running an addon on that prefix | 1 send (the server fans it out) | Anyone can read it with a trivial addon |
| OFFICER | members whose rank can listen to officer chat | 1 send | Access is enforced by the server; sending needs officer-chat speak permission. None of the studied addons use it for addon traffic. **Verify it works for addon messages.** |
| WHISPER | 1 player | 1 send per recipient | Whispering someone offline prints a "No player named…" system message. LootReserve checks `IsPlayerOnline` first (Comm.lua:208-213) |
| RAID | the raid group | 1 send | Used for drop alerts |

### 2.5 Config the guild itself can store
- **Guild info text** (`GetGuildInfoText`, and `SetGuildInfoText` if you have `CanEditGuildInfo()`): readable by every member, writable only by ranks with "Modify Guild Info". About 500 characters (**verify**).
- **Officer notes:** only readable with the "View Officer Note" permission, so raiders' clients can't work out the council from them.
- **Public notes:** editable by many ranks, sometimes by players themselves. Never use them for authority.

### 2.6 Serialization and compression libraries available
- AceSerializer and LibDeflate: TehBoxLootCouncil, Raidify, LootReserve.
- LibSerialize and LibDeflate: WeakAuras (WeakAuras/Libs/LibSerialize).
- `LibDeflate:Adler32(str)` provides a checksum function (WeakAuras/Libs/LibDeflate/LibDeflate.lua:401).
- Questie encodes with the client's built-in CBOR and Deflate functions (`C_EncodingUtil`) and raises an error if they're missing (CommsEncoding.lua:1-12, 34-70). Questie-BCC.toc targets Interface 20506, which is strong evidence those functions exist on this client. **Verify** with `/dump C_EncodingUtil ~= nil`.

---

## 3. Survey of installed addons

### 3.1 TehBoxLootCouncil (TBLC)
**Channels**
- Data sync (`TBRTSYNC`) runs over RAID or PARTY, or WHISPER when there's a target (TehBoxLootCouncil_Comms.lua:81-92, 734-768).
- Raid-note sync (`TBRTNOTE`) uses GUILD for the manifest and single edits, WHISPER for requests and notes (Comms.lua:939-958, 1100-1126).
- Council list (`TBRTLC`) goes to RAID or PARTY (LootCouncil.lua:350-366).
- Access-list broadcast is meant for GUILD (Access.lua:332-347).

**Message format**
- `TYPE:` + LibDeflate level 9 compression + `EncodeForWoWAddonChannel` (Comms.lua:81-112).
- The delta payload is custom text: sections separated by `\001`, fields by tabs and `|` (Comms.lua:186-492, 607-626).
- Raw-text paths use `\001`/`\002` separators (Comms.lua:960-962, 1139).
- A global `SendAddonMessage` compatibility shim fills in for the removed global (TehBoxLootCouncil.lua:12-29).

**Chunking**
- AceComm is used for `TBRTSYNC`, `TBRTLC` and `TBRTDATA` (Comms.lua:853-904).
- But `TBRTNOTE` messages, `OFFSYNC` and `LCMEMBERS` are sent raw:
  - `OFFSYNC` cuts its payload to 240 bytes without warning (Comms.lua:835).
  - `LCMEMBERS` deliberately bypasses CTL (LootCouncil.lua:350-366), so a long council list exceeds 255 bytes.
  - `NOTE` and `MANIFEST` can grow past 255 bytes (Comms.lua:1064, 1077, 1103, 1122).

**Throttling and priorities**
- MANIFEST goes at NORMAL, DELTA at BULK (Comms.lua:87-91).
- Council-session messages go at ALERT (Comms.lua:882-888).
- Self-broadcast has a 60 s cooldown (Comms.lua:810-821).
- Sync is manual only (Comms.lua:924-937).

**Versioning and checksums**
- The manifest "checksum" is just a boss count per session (Comms.lua:121-155).
- The note "hash" is length plus the first 8 bytes (Comms.lua:980-988), so edits past byte 8 that keep the length go undetected.
- `LCMEMBERS` and `REQUESTLC` carry a version and are rejected below `MIN_LC_SYNC_VERSION` (LootCouncil.lua:24-30, 1617, 1638-1639).

**Request/response flows**
- Sync: MANIFEST → a consent popup on the responder → WHISPER DELTA after a random 1–4 s delay (Comms.lua:678-719).
- Notes: MANIFEST → REQUEST whisper → NOTE whisper (Comms.lua:1045-1089).
- Council list: REQUESTLC → the leader rebroadcasts LCMEMBERS after 0–2 s of random delay (LootCouncil.lua:1611-1626).
- Version check: VERCHK to RAID; replies are whispered back; results collected for 10 s (Comms.lua:1128-1391).

**Access control**
- The rank cache is rebuilt from `GetGuildRosterInfo` on `GUILD_ROSTER_UPDATE` (Access.lua:46-83).
- A "guild fingerprint" of guild name and realm (Access.lua:95-107).
- GM and rank 1 are trusted automatically (Access.lua:139-143).
- Council membership comes from locally configured rank names or explicit names (Access.lua:163-204; LootCouncil.lua:190-213).
- DELTA is accepted only if the sender's rank is on the receiver's own local whitelist (Comms.lua:65-72, 721-726). That whitelist is set per client in the UI (Settings.lua:1891-1896), so every officer has to configure it the same way.
- `LCMEMBERS` is accepted only from the raid leader or an assistant (LootCouncil.lua:1628-1680).
- **The GM approval broadcast is never wired up:** `TBRT.SendComm` is never defined, and `Access_OnComm` is never registered (Access.lua:344-355). Approvals therefore never sync.
- **No sender check on notes:** `TBRTNOTE` `NOTE` is written with no check of who sent it; only the receiver's own access is checked (Comms.lua:1040, 1081-1089).

**Conflict resolution**
- "Local data is always authoritative; incoming data only fills gaps" (Comms.lua:31-32, 494-595). Edits therefore never propagate.
- Players and notes are always included in a delta, so the "is the delta empty?" check almost never succeeds (Comms.lua:614-634).

### 3.2 LootReserve
**Channels**
- RAID, PARTY or INSTANCE_CHAT, or a whisper to yourself when solo (Comm.lua:215-223).
- In "Blind" mode, session info is whispered to each member instead of broadcast, which is a privacy-by-whisper precedent (Comm.lua:334-343).

**Message format**
- Numeric opcodes (Comm.lua:14-35) and `|`-joined fields (Comm.lua:84-93).
- Opcodes up to `Hello` are never compressed, so the version handshake can always be read (Comm.lua:37-38, 98).
- Payloads over 20 bytes are compressed with LibDeflate and prefixed with their original length; the receiver checks the length after decompressing (Comm.lua:98-107, 162-178).

**Chunking and throttling**
- AceComm at ALERT priority for everything (Comm.lua:126).
- It rotates through 41 prefixes to beat the per-prefix throttle (Comm.lua:50-65).
- It loops its own messages back to itself locally (Comm.lua:109-121).

**Versioning**
- `Version` and `MinAllowedVersion` come from TOC metadata; they are date strings, which compare correctly (LootReserve_TBC.toc:3-7; LootReserve.lua:101-118).
- An incompatible client disables itself (Comm.lua:271-289).

**Request/response**
- `Hello` → everyone replies with their version; the session host whispers `SessionInfo` (Comm.lua:307-313).

**Access control**
- Only the leader or master looter can host (Server.lua:401-403).

**Conflict resolution**
- The session with the newer `StartTime` wins (Comm.lua:446-449).

**Loot detection**
- `LOOT_READY` on the master looter, de-duplicated by the target's GUID or "CHEST" (Server.lua:1149-1175, 1160-1163).
- Received items are parsed from `CHAT_MSG_LOOT` using the Blizzard format strings (Server.lua:1096-1147).

### 3.3 Raidify and Raidify_Loot
**Message format**
- Envelope `{v, t, seq, p}` → AceSerializer → LibDeflate → `EncodeForWoWAddonChannel` → AceComm prefix `Raidify` (Raidify/Sync.lua:1-22, 31-32, 186-204).
- Unknown versions or kinds are silently ignored; this is how the protocol can evolve forward (Sync.lua:231-234).
- Handlers run inside `pcall` (Sync.lua:254-258).
- Sub-addons can register their own message kinds (Sync.lua:269-274).
- A legacy raw-prefix path is still sent alongside for older clients (Sync.lua:34-47).

**Channels and priorities**
- ASSIGN goes to RAID or PARTY at NORMAL; SYNCDATA is whispered to the requester at BULK (Sync.lua:120-150, 325-342).
- The loot mirror goes to RAID only, at BULK (Raidify_Loot/LootSync.lua:84-95).
- Loot broadcasts are coalesced with a 5 s delay (LootSync.lua:32-41, 97-107).
- The payload is kept minimal: item IDs and winners only (LootSync.lua:43-76).

**Conflict resolution**
- `seq = GetServerTime()`, and a single global `lastSyncSeqNumber` de-duplicates messages (Sync.lua:125, 283). Two edits in the same second, or an edit from an officer whose clock is behind, get dropped.
- For the loot mirror, the local session always wins; the mirror is stored separately and only adopted manually after a confirmation (LootSync.lua:147-167, 180-297).

**Access control**
- ASSIGN and SYNCDATA handlers **don't check the sender** (Sync.lua:282-306, 442-460).
- The loot mirror checks that the sender has raid rank above 0 or is master looter (LootSync.lua:116-145).

**Loot detection**
- `LOOT_OPENED`, keyed by `GetLootSourceInfo(slot)` with the slot number as a fallback because the GUID is often nil on Classic (Raidify_Loot/LootSession.lua:423-441, 465-495).
- Quality is the **5th** return value of `GetLootSlotInfo` (LootSession.lua:474-478).

### 3.4 RaidHelper_TBC
- **Format:** custom `TYPE#data` with a shallow custom serializer (RaidHelper_TBC/Sync.lua:27-92, 494-528). Raw `C_ChatInfo.SendAddonMessage`, no CTL (Sync.lua:482-488).
- **Chunking is broken:**
  - Chunks are 250 bytes plus a header of about 11 bytes (`MP#<6-char id>#<n>#`), which goes over 255 (Sync.lua:503-525).
  - Message IDs are the last 6 characters of `GetTime()` and aren't tied to the sender (Sync.lua:515, 535-567).
- **Trust:** ENC pushes are accepted from **anyone**; only the encounter key is validated (Sync.lua:666-672). The "leader" check actually requires rank ≥ 2 (Sync.lua:468-479).
- **Throttling:** a 20 s cooldown, broadcast to the whole group as a `CD` message (Sync.lua:572-603).
- **Version check:** replies are broadcast to the whole group instead of whispered (Sync.lua:650-654).

### 3.5 Questie
**Versioning**
- The message version is major.minor; clients are compatible if the major number matches (Questie/Modules/Network/QuestieComms.lua:40-43, 1056).
- Every packet carries the addon version, and clients nag once when a newer one is seen (QuestieComms.lua:1058-1072, 1085-1094, 1098-1110).

**Throttling and pacing**
- Nothing is broadcast to groups larger than 15 (QuestieComms.lua:997-1000).
- BULK is the default priority (QuestieComms.lua:1001-1003).
- The quest log is split into blocks under 200 bytes, sent one every 3 s after a random 0–3 s start delay (QuestieComms.lua:596-640).
- A 2 s bucket coalesces events (QuestieComms.lua:172).

**Newer modules**
- CBOR + Deflate with a cap of 3 AceComm parts (CommsEncoding.lua:24-27, 74-96).
- Only group members are accepted (CommsRouting.lua:34-41).
- The whole payload is validated before the stored state is replaced in one step (CommsVisibility.lua:142-193).
- Snapshots are debounced with 0–2 s of random delay (CommsVisibility.lua:111-140).

**Response suppression (DailyQuestComms, currently disabled)**
- Peers respond after a random 0–8 s delay, and cancel if another peer has already covered the data (DailyQuestComms.lua:131-135, 179).
- The prefix is disabled because of "daily quest comms problems" (DailyQuestComms.lua:48).

### 3.6 WeakAuras (Transmission.lua)
- **Pull-only, over WHISPER.** A client only answers a request (`dR`) for an aura it linked in the last 5 minutes (Transmission.lua:660, 698-699).
- **Receivers only accept data from people they asked** (a `safeSenders` list) (Transmission.lua:578-583, 659-672).
- **Format header** `!WA:2!` identifies the encoding version, then LibSerialize + LibDeflate (Transmission.lua:271-297, 300-350).
- **Priorities:** the bulk data goes at BULK, with progress updates at ALERT on a separate prefix `WeakAurasProg` (Transmission.lua:607-625).
- **Cross-realm:** handled with the Chomp library (Transmission.lua:612-620).

### 3.7 Details (guild sync)
- **Flow:** R → L → G → A.
  - `R` is sent on GUILD (functions/storage.lua:399-401; core/network.lua:743-746).
  - Everyone who has data whispers back `L`, a list of encounter IDs (network.lua:505-521).
  - The requester whispers `G` with only the missing IDs (network.lua:523-531).
  - The data source whispers `A` batches of 3 encounters every 4 s (network.lua:533-560; storage.lua:602-603).
- **De-duplication:** the requester doesn't ask for an ID it already requested from another responder (storage.lua:427-436, 537-543).
- **Validation:** received records are validated field by field (storage.lua:657).
- **Disabled checks:** the 60 s response cooldown is set but its check is commented out (network.lua:509, 520). The version check is commented out (network.lua:502).
- **Serializer:** AceSerializer-style (`Details:Serialize`).

### 3.8 Other installed addons worth noting
**Attune** (the closest analogue to DisasterZone: per-member data cached for offline guild members)
- On login it announces its version on GUILD and YELL (Attune.lua:646-656).
- A `SILENTSURVEY` on GUILD makes every member whisper a `TOON` message, one `DONE` message per step, then `OVER` (Attune.lua:665, 3796-3808). That's hundreds of messages per survey.
- It trusts the name inside the payload (Attune.lua:3887) and stamps records with the receiver's local clock (Attune.lua:3913).
- Peer-to-peer database sync uses a handshake (SYNCREQ, SYNCOK/NOK/BUSY) with a consent popup, and sends the whole database as one message (Attune.lua:4380-4413).
- Merge rule: the newest `survey` time wins, and the player's own characters are never overwritten (Attune.lua:4438-4448).
- Versions are compared as strings (Attune.lua:852).

**TBCRaidKompass NotesSync**
- Checks the sender's raid rank on receipt (NotesSync.lua:355-364).
- Throws away incomplete chunk sets after 5 s (NotesSync.lua:8-18, 595).
- Notes that `UnitIsRaidLeader` is missing on Anniversary and reads the rank from the roster instead (NotesSync.lua:255-266).

**PallyPower**
- A `REQ` makes each paladin send its own data (`SELF`). The reply is whispered if the requester isn't the leader, otherwise broadcast (PallyPower.lua:1401, 1432).
- Assignments are packed 5 per message (PallyPower.lua:1467).

**No sync code**
- GatherMate2: the installed copy has no sharing; the separate GatherMate2_Sharing module isn't installed.
- NovaConsumesHelper: no addon messages at all.

### 3.9 Comparison matrix
| Addon | Channel | Format | Chunking | Priority/throttle | Version/hash | Sender check on receive | Conflict rule |
|---|---|---|---|---|---|---|---|
| TBLC | RAID, GUILD, WHISPER | custom text + Deflate | AceComm (some raw paths) | NORMAL/BULK/ALERT, 60 s cooldown | boss-count / length hash | guild rank, local whitelist (not on notes) | local always wins |
| LootReserve | RAID, WHISPER | opcode + `\|` fields + Deflate + length | AceComm, 41 prefixes | ALERT for everything | TOC min-version, disables itself | leader/ML (hosting) | newer StartTime |
| Raidify | RAID, WHISPER | AceSerializer envelope + Deflate | AceComm | NORMAL/BULK, 5 s coalesce | `v` in envelope | loot only | server-second seq |
| RaidHelper | RAID, WHISPER | custom `#` | custom (broken) | none | none | none | overwrite |
| Questie | party/raid, whisper | serializer / CBOR+Deflate | AceComm, <200 B blocks | BULK, 3 s ticker, random delay | major.minor | group member | full snapshot replace |
| WeakAuras | WHISPER only | LibSerialize + Deflate | AceComm / Chomp | BULK data, ALERT progress | `!WA:N!` | only people you asked | n/a |
| Details | GUILD request, WHISPER data | AceSerializer | AceComm, batches of 3 per 4 s | default | (disabled) | none | union by ID |
| Attune | GUILD, WHISPER | custom text | AceComm | default | string compare | none (trusts payload) | newest survey, own data never overwritten |

### 3.10 Patterns to copy, and mistakes to avoid
**Copy**
- A version envelope that ignores unknown versions (Raidify).
- Keeping the version and type readable without decoding the body (LootReserve).
- Validating the whole payload, then replacing state in one step (Questie).
- `pcall` around every handler.
- Random delays before responding and on login broadcasts (Questie, TBLC, Attune).
- Coalescing bursts (Raidify_Loot).
- Manifest → want-list → data, with de-duplication across responders (Details).
- "Own data is never overwritten; newest wins" (Attune).
- Checking the sender against server-authoritative rosters (TBCRaidKompass, Raidify_Loot).
- Whispering instead of broadcasting for privacy (LootReserve Blind mode).
- Only whispering players who are online (LootReserve).
- BULK for data, ALERT for small time-sensitive messages (WeakAuras, TBLC).

**Avoid**
- Raw sends that can exceed 255 bytes (TBLC, RaidHelper).
- Accepting data without checking the sender (Raidify ASSIGN, RaidHelper ENC, TBLC notes).
- Trusting names inside the payload (Attune).
- Wall-clock timestamps as version numbers (Raidify; Attune's receiver clock).
- Weak hashes (TBLC).
- "Fill gaps only" merging, which drops updates (TBLC).
- Council configuration that lives separately on each client (TBLC).
- Broadcasting version replies to the whole group (RaidHelper).
- Every member answering a GUILD survey (Attune).

---

## 4. Proposed DisasterZone sync protocol

### 4.1 Principles
1. **Owners are the only writers.** A player's list is written only by that player's client, and each edit bumps a revision number `rev`.
   - Council clients cache and relay lists but never edit them.
   - The owner's client ignores incoming copies of its own list, except for an explicit restore.
   - On every save: `rev = max(own.rev, own.highestSeenRev) + 1`.
2. **Checks on receipt use only server-authoritative facts:** the sender name from `CHAT_MSG_ADDON` and the guild or raid roster. Names inside payloads are ignored.
3. **Send only what's stale.** Manifests (name → rev) decide what moves; full lists are sent only when requested or changed.
4. **Separate traffic classes** by prefix and priority.
5. **Don't send immediately after zoning or login.** CTL throttles hard then, and the network is busy.

### 4.2 Council membership: how it's defined and distributed
**Recommended: a tag in the Guild Information text**, maintained through a GM/officer UI in DisasterZone that calls `SetGuildInfoText`, preserving the rest of the text.

Example tag: `CDL:r2,+Alice,+Bob,-Carl,a1,p2,mc`

| Token | Meaning |
|---|---|
| `rN` | Guild ranks with index ≤ N are council (index 0 is GM). Use indices, not rank names; TBLC stores names (Settings.lua:1896), which break when a rank is renamed. |
| `+Name` / `-Name` | Explicit additions or exclusions (realm assumed to be the guild's) |
| `aN` | "Admin" rank threshold: who may edit DisasterZone guild settings in the UI. The server also enforces this through the Modify Guild Info permission. |
| `pN` | Current raid phase, used when sorting drop matches |
| `mc` / `mo` / `mx` | Privacy mode: council-only / open (GUILD) / council-only via OFFICER |

Why this option:
- It's tamper-resistant, because the server enforces who can write it.
- Every member can read it, so raiders know who to whisper.
- It works while the GM is offline, needs no sync protocol, and costs about 30–80 characters.

Client behaviour:
- Parse the tag after `GUILD_ROSTER_UPDATE`, requesting the roster with `C_GuildInfo.GuildRoster()`.
- Cache the parsed result in SavedVariables with a `fetchedAt` time for the window before the roster loads.
- `IsCouncil(key)` = (roster rank index ≤ N, or on the `+` list) and not on the `-` list, and currently in the guild roster.
- If a message arrives from a sender who isn't in the cached roster yet, hold it and re-check after the next roster update. Don't drop it silently and don't trust it.

**Alternatives considered**
| Option | Tamper-resistant | Raiders can read | Works with GM offline | Verdict |
|---|---|---|---|---|
| Guild info tag | yes (server) | yes | yes | **Recommended** |
| Officer-note tag `[CDLC]` | yes (server) | **no** (needs View Officer Note) | yes | Council clients only; raiders can't find the council |
| Addon-synced list, sender's rank checked on receipt (like TBLC LCMEMBERS / Access_Broadcast) | only while the admin is online; relayed copies can't be verified (no signatures) | yes | cached copies go stale | Fallback if the GM won't edit guild info: accept `CFG{rev,list}` only if the sender's live rank ≤ `a`; only admins may relay it |
| Rank threshold configured on each client (TBLC) | n/a | n/a | yes | Rejected: configurations drift apart |

For OFFICER transport (`mx`), the council has to equal the ranks that can listen to officer chat. Any `+` members outside those ranks also get whispered. Reading rank permissions (`GuildControlGetRankFlags`) may need permissions a normal member doesn't have, so the GM declares `mx` explicitly. **Verify.**

### 4.3 Data model (SavedVariables)

```lua
DisasterZoneDB = {                         -- account-wide
  schema = 1,
  guildKey = "Casual Disaster-<Realm>",
  own   = { ["Name-Realm"] = { rev=37, ts=1790123456, hash="2a9f3c11", data=<list>,
                               pendingPush=true, highestSeenRev=37, ackedBy={["Officer-Realm"]=37} } },
  lists = { ["Name-Realm"] = { rev=37, ts=..., hash=..., data=<list>, via="direct"|"Officer-Realm",
                               recvAt=GetServerTime(), conflict=nil } },   -- only filled when the local char is council
  ledger = { [awardId] = { item=, winner=, src=, by=, ts=, void=nil } },   -- council-only
  peers = { ["Name-Realm"] = { ver="1.2.0", lastSeen=... } },
  cfgCache = { raw="CDL:r2,...", parsed={...}, fetchedAt=... },
}
```

**List payload (schema v1):**
- Positional, with a fixed slot order: 1 Head, 2 Neck, 3 Shoulder, 4 Back, 5 Chest, 6 Wrist, 7 Hands, 8 Waist, 9 Legs, 10 Feet, 11 Ring1, 12 Ring2, 13 Trinket1, 14 Trinket2, 15 MainHand, 16 OffHand, 17 Ranged/Relic.

```lua
{ v=1, sp="RET",                        -- spec/role tag (optional); main="Mainname" (optional alt link)
  ph = { [1] = {28765, 0, {29000,29001}, ... 17 entries}, [2] = {...} },   -- itemID | 0 (empty) | {main, alt1, alt2}
  ob = {28765, 30011},                  -- items the owner has obtained
  nt = { ["1.13"] = "over trinket X" } } -- notes, max 20 × 60 characters
```

- `hash` = `LibDeflate:Adler32` of the canonical serialized `data`, so it covers content only, not `rev` or `ts`.
- `ts` = `GetServerTime()` at save, used only for display ("updated 3 days ago") and as the last tie-breaker.

### 4.4 Transport
| Prefix | Use | Priority | Parts |
|---|---|---|---|
| `CDL` | control: HELLO, WANT, ACK, HAVE, SYNC, VERQ/VER | NORMAL | always single-part; stay under ~240 bytes |
| `CDLD` | data: LIST, RELAY, MAN (on GUILD, WHISPER or OFFICER) | BULK | multipart |
| `CDLA` | alerts: DROP, AWARD | ALERT | single-part |

- **Framing** (the header is plain ASCII, so the type and major version can be read without decoding, like LootReserve):
  - Control: `<TYPE>|<major>|field|field…`, not compressed.
  - Data: `<TYPE>|<major>|~` + `EncodeForWoWAddonChannel(CompressDeflate(LibSerialize(body)))`.
- **Receiving:** a different major version is ignored, with a one-time warning (Questie and Raidify patterns). Handlers run in `pcall`. Validate everything, then apply in one step.
- **Libraries:** embed AceComm-3.0, ChatThrottleLib, LibDeflate and LibSerialize inside DisasterZone (or AceSerializer, costing about 25% more bytes, see §4.8). DisasterZone must not depend on other addons' copies.

### 4.5 Message catalogue
| Msg | Prefix / dist | Direction | Payload | Size |
|---|---|---|---|---|
| `H` HELLO | CDL / GUILD | every member → guild, once per `PLAYER_LOGIN` | `H\|1\|rev\|hash\|ts\|addonVer` | ~40 B, 1 part |
| `M` MAN (council manifest) | CDLD / GUILD (login), WHISPER (reply to SYNC) | council → all / peer | `{c=1, root=<adler of sorted name:rev>, e={Name=rev,…}}` | 460 B → 2 parts (80 players) |
| `W` WANT | CDL / WHISPER | council → owner (`W\|1\|self`) or council → peer (`W\|1\|n1,n2…`, ≤15 names per message) | names | 1 part |
| `L` LIST | CDLD / WHISPER (council-only mode) or GUILD (open mode) | owner → council | `{rev, ts, hash, d=<list>}` | 1–5 parts |
| `R` RELAY | CDLD / WHISPER or OFFICER | council → council | `{{o="Name-Realm", rev, ts, hash, d}, …}`, up to ~1.5 KB compressed per message | 1–6 parts |
| `A` ACK | CDL / WHISPER | council → owner | `A\|1\|rev` | 1 part |
| `V` HAVE | CDL / WHISPER | one elected council member → owner | `V\|1\|rev\|hash\|ts\|via` | 1 part |
| `S` SYNC | CDL / WHISPER | council → one peer | `S\|1\|root\|count` | 1 part |
| `D` DROP | CDLA / RAID (+ OFFICER option for council outside the raid) | master looter / first council looter → raid | `D\|1\|srcKey\|encOrNpcId\|id,id,id\|ts` | 30–80 B |
| `X` AWARD | CDLA / OFFICER or WHISPER to council | council → council | `X\|1\|id\|itemID\|winner\|srcKey\|ts\|void` | 1 part |
| `Q`/`q` VERQ/VER | CDL / RAID, reply by WHISPER | council → raid; replies whispered | `q\|1\|ver\|hasList\|rev` | 1 part each |

### 4.6 Flows

**A. Raider login (HELLO)**
1. On `PLAYER_LOGIN` only (not on every `PLAYER_ENTERING_WORLD`), wait for guild roster and config, then another 20–40 s of random delay. CTL throttles hard after zoning; for comparison Attune waits 11–13 s and TBLC initializes after 2 s.
2. Send `H` on GUILD.
3. Each council client compares the HELLO with its cache:
   - **Cached rev lower, or equal rev with a different hash:** wait 0–3 s at random, then whisper `W|1|self`. The owner replies with `L` to that council member only.
     - In `mx` mode, only the elected council member (online, has the addon, alphabetically first) sends WANT. After receiving the list, it relays one `R` on OFFICER.
   - **Cached rev higher** (the owner lost their SavedVariables): only the elected council member whispers `V` (HAVE). The owner offers "Restore your list (rev 37, 3 days old, via Bob)?"
     - If the owner declines, the owner sets `highestSeenRev=37`, so its next save becomes rev 38 and overrides.
4. The owner answers `W` **only if the sender is council**. Non-council players can't pull lists.

**B. Raider edits their list**
1. Debounce: send 10–15 s after the last change, or immediately when the BiS window closes. This produces one rev bump per burst of edits (Raidify_Loot coalesces the same way).
2. Set `rev++`, `ts`, `hash`, and `pendingPush=true`.
3. Council-only mode: whisper `L` to each council member who is **online according to the guild roster and has been seen with the addon** this session (they sent H or M). Typically 3–8 people.
   - Open mode: one `L` on GUILD.
4. Each council member replies with `A` (ACK). Once at least one ACK arrives for the current rev, clear `pendingPush`; council relay takes over from there.
5. If `pendingPush` is still set when a council member's `M` is seen, push to that member.

**C. Council member logs in and catches up**
1. After the same 20–40 s delay, send `M` on GUILD. It also tells everyone "council member online with the addon".
2. **Online raiders:** each one checks `M.e[self]`. If their own rev is higher (or missing), they whisper `L` to that council member after a random 2–15 s delay. Up-to-date raiders send nothing.
3. **Offline raiders, via council peers:**
   - Pick one peer: an online council member with the addon, preferring the one seen most recently, otherwise alphabetical.
   - Whisper it `S` with the local root hash. If the hashes match, stop.
   - Otherwise the peer whispers back its own `M`.
   - Compute `WANT = {name : peer.rev > mine}` and send `W` in batches. The peer streams `R` messages at BULK, several players per message.
   - For the reverse direction (`mine > peer.rev`), the peer pulls from us with `W` in the same way.
   - If the peer doesn't answer within 20 s, try the next one.
   - Track `requested[name]=rev` so the same entry is never requested from two peers (Details, storage.lua:537-543).
4. Other online council peers see the same `M` on GUILD. If any of them is missing entries that the new council member has newer, it pulls them with `W`. This is pull-based, so nothing gets pushed twice.

**D. Periodic check.** Every 15 minutes, while no bulk transfer is in progress, send `S` (root hash only) to one random online council peer. Run flow C step 3 only if the hashes differ.

**E. Restore and forgery repair**
- If an owner sees its own name with `rev > own.rev` in any `M` or `V`, it sets `highestSeenRev` and immediately re-pushes as `max+1`.
- This fixes an old restored copy or a value forged by a council member whenever the owner is online.

**F. Raid drop alert**
1. **Who broadcasts:**
   - The master looter's client (`GetLootMethod()=="master"` and the player is the master looter) handles `LOOT_READY` (LootReserve Server.lua:1149).
   - Under group loot, the first council member to open the corpse broadcasts, after a random 0–1 s delay, and cancels if a `D` for the same source arrives first (Questie suppression pattern).
2. **Collect items:**
   - For each loot slot with `GetLootSlotType==1`, read the link and the 5th return of `GetLootSlotInfo` (quality), and keep items at or above the threshold (default Epic).
   - Source key = `GetLootSourceInfo(slot)`, falling back to the target GUID if it's dead and hostile, then to `"CHEST"` (Raidify_Loot LootSession.lua:423-441, 491; LootReserve Server.lua:1158-1164).
   - De-duplicate with `seen[srcKey]` (and `srcKey:itemID:slot` for duplicate items).
3. **Send** `D` on `CDLA`/RAID at ALERT. It's one part, and a separate prefix, so it's never stuck behind catch-up traffic.
   - Optionally also send on OFFICER so council members outside the raid get it.
4. **Receiving:**
   - Accept only if the sender is master looter, raid rank ≥ 1, or council (checked with `GetRaidRosterInfo`, as in LootSync.lua:125-137).
   - Council clients look up an item-to-players index that's rebuilt whenever lists change.
   - The drop panel shows each item → players **currently in the raid** who have it as BiS, grouped current phase, other phases, then alternates. It also shows class colour, obtained status, list age and previous awards.
   - Non-council clients only show "on your BiS list".
   - **Tier tokens:** the drop is a token (T4–T6), so the lookup needs a token-to-class-pieces table (hand-coded, or from AtlasLootClassic data; **verify**).

**G. Obtained items and awards**
- **Obtained is owned by the player.** Their client watches `CHAT_MSG_LOOT` for its own receive lines, using the `LOOT_ITEM_SELF` / `LOOT_ITEM_SELF_MULTIPLE` format strings (LootReserve Server.lua:1096-1127) and token mappings. On a match it sets `ob`, bumps `rev`, and syncs normally.
- **Council awards** go in a separate append-only ledger.
  - Entry ID = `ts:mlName:itemID:srcKey`; entries are merged as a union, and removed via a `void` marker.
  - Sent as `X` on OFFICER, or by whisper to council members, never on GUILD.

**H. Version checks**
- HELLO and MAN carry the addon version, so the council UI shows each member's version and last-seen time without extra traffic.
- A one-time "newer version available" notice (Questie/Attune pattern). Compare versions numerically, not as strings (Attune.lua:852 compares strings).
- A TOC field `X-CDL-MinProtocol` and the envelope major version. Older clients ignore messages they can't handle and don't corrupt state.
- An optional raid-night `Q` (VERQ) to RAID with whispered `q` replies, collected for 10 s (TBLC pattern), to list raiders who don't have the addon.

### 4.7 Merge rules

```lua
function Accept(kind, ownerKey, e, sender)          -- e = {rev, ts, hash, d}
  if ownerKey == MyKey() then return OnOwnEcho(e, sender) end        -- owner authoritative
  if not IsCouncil(MyKey()) then return end                          -- only council caches others
  if kind == "L" and sender ~= ownerKey then return end              -- a list only from its owner
  if kind == "R" and not IsCouncil(sender) then return end           -- a relay only from council
  if not InGuildRoster(ownerKey) then return end                     -- blocks junk names
  if not ValidateList(e.d) or Adler32(Canon(e.d)) ~= e.hash then return end
  local cur = DisasterZoneDB.lists[ownerKey]
  if not cur or e.rev > cur.rev then return Store(ownerKey, e, kind == "L" and "direct" or sender) end
  if e.rev == cur.rev and e.hash ~= cur.hash then
    if kind == "L" then return Store(ownerKey, e, "direct") end      -- a direct copy wins a fork
    cur.conflict = true                                              -- resolve by WANT to owner when online
  end
end
```

- Relays for an owner who is currently online are not accepted; ask the owner directly with `W` instead.
- Remove lists of players who have been out of the guild roster for more than 30 days. Only players still in the roster are ever relayed.

### 4.8 Size estimates
Measured with the scratchpad script using zlib raw deflate at level 9 (equivalent to LibDeflate level 9) plus the WoW-channel escaping. Item IDs are random between 28000 and 35200, so these are **pessimistic**: real lists share many items and compress better.

| List profile | AceSerializer → wire bytes (parts) | Compact positional → wire bytes (parts) |
|---|---|---|
| 2 phases, main item only | 740 → 250 (1) | 266 → 137 (1) |
| 5 phases, main only, 3 notes | 1922 → 508 (2) | 784 → 325 (2) |
| 5 phases, 1 alternate per slot, 10 notes | 2934 → 824 (4) | 1451 → 611 (3) |
| 5 phases, 2 alternates per slot, 20 notes (worst case) | 4108 → 1192 (5) | 2261 → 912 (4) |

| Other messages | Wire bytes (parts) |
|---|---|
| HELLO | ~21–45 B (1) |
| Manifest, 80 players, name + rev | 861 → 460 (2) |
| Manifest, 80 players, name + rev + 8-hex hash | 1577 → 915 (4). Use root hash + rev only. |
| Full catch-up, 80 players with 2-phase lists | 22 409 → 7 793 (31) |
| Full catch-up, 80 players with 5-phase lists | 60 883 → 19 250 (76) |

Recommendation: a compact positional table serialized with LibSerialize, batching several players per `R` to get the snapshot-level compression (~97–241 bytes per player). Keep a list under 5 parts by capping alternates at 2 and notes at 20 × 60 characters.

### 4.9 Throttle safety at login spikes (40–80 member guild)
| Event | Messages / parts | Where | Load |
|---|---|---|---|
| 25–40 raiders log in within ~15 min | 1 HELLO each | GUILD, spread by the 20–40 s random delay | trivial (~2 KB total, fanned out by the server) |
| Council reaction to stale HELLOs (rare) | WANT 1 part + LIST 1–4 parts × online council (≤8) | WHISPER | ≤32 parts for one raider, well within the burst budget |
| Council member logs in | MAN 2 parts on GUILD, plus LISTs only from raiders who are newer | GUILD + WHISPER | a handful of parts |
| New council member, all 80 lists stale | SYNC + MAN + WANT + 31–76 parts of relays | WHISPER BULK on `CDLD` | ~12–28 s at ~2.7 parts/s under CTL; ~25–70 s if the per-prefix limit is ~1/s after a 10-message burst. Runs in the background with progress shown and partial results usable |
| Drop | 1 part | RAID ALERT on `CDLA` | never queued behind the data prefix |

Guard rails:
- No automatic sends within 20 s of `PLAYER_ENTERING_WORLD`, no data re-sends while a bulk transfer is running, and no peer SYNC while in combat.
- Whisper only players who are online in the roster, to avoid "No player named…" spam.
- Consider filtering `ERR_CHAT_PLAYER_NOT_FOUND_S` for names DisasterZone just whispered.

### 4.10 Privacy
- **How sensitive the data is:** BiS lists themselves are low sensitivity; guilds often post them on Discord or in sheets. Council annotations, priorities and awards are sensitive.
- **GUILD traffic is readable by any guild member** with a five-line addon registered on the prefix. Treat anything sent on GUILD as public within the guild.
- **Recommended default (`mc`):** lists go only to the council by whisper; relays between council members use OFFICER (`mx`) or whispers. HELLO and MAN still go on GUILD, but they only reveal names and revision numbers.
  - Cost: raiders send K small whispers per edit.
  - Benefit: fewer "why does X think they deserve my item" arguments before council decides.
- **Open mode (`mo`):** GM-selectable. Lists go on GUILD, raiders can browse each other's lists, and it's the cheapest option. Annotations, ledger and awards remain council-only in every mode.
- **Limits of council-only:** it isn't cryptographic. Any council client can leak data, and SavedVariables are plain text on disk (TBLC says the same, Access.lua:18-21). The goal is to stop casual reading, not a determined insider.

### 4.11 Receive-side validation checklist
- `pcall` around every handler; check the prefix and the major version first.
- Sender rules:
  - Must be in the guild roster, for anything received on GUILD or WHISPER.
  - Council rules as in §4.2.
  - LIST: the sender must be the owner.
  - RELAY, MAN reply, AWARD: the sender must be council.
  - DROP: master looter, raid assistant or leader, or council, in the current raid.
- Payload limits: ≤6 phases, ≤17 slots, ≤3 items per slot, item IDs between 1 and 200000, ≤20 notes of ≤60 characters, ≤~40 names per WANT batch. The hash must match. Reject the whole message if anything fails; don't clean it up partially.
- Normalize names to "Name-Realm" before any comparison.
- Rate-limit replies to repeated WANT or SYNC from the same sender (e.g. 1 per 10 s per name).

### 4.12 To verify in game before building
1. `/dump C_EncodingUtil ~= nil` (Questie's evidence suggests yes).
2. Whether `C_ChatInfo.SendAddonMessage(prefix, msg, "OFFICER")` delivers only to officer-chat listeners, and what non-officers get when they try to send on it.
3. The guild info text length limit, and whether `GetGuildInfoText` is populated for normal ranks right after login.
4. The per-prefix throttle numbers: send 30 messages back to back and log the `SendAddonMessage` results.
5. Whether `GetLootSourceInfo` works on 2.5.x (Raidify_Loot reports it's often nil); fall back to the target GUID.
6. The source for the tier-token-to-pieces table (AtlasLootClassic_DungeonsAndRaids, or hand-coded).