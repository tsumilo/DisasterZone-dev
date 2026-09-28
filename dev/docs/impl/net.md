1. **Files written** (all under `C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot\Core\`)
   - `Guild.lua`: 500 lines
   - `Store.lua`: 532 lines
   - `Comm.lua`: 355 lines
   - `Sync.lua`: 753 lines

   I also built a test simulation in my scratchpad (not part of the addon): `...\scratchpad\sync_sim\` (`sim.py`, `mock.lua`, `stubs.lua`).

   On the user's question: this layer depends on no other addon. It only uses AceComm-3.0 (with ChatThrottleLib), LibSerialize, LibDeflate and LibStub, all shipped inside `CDLoot\Libs` and loaded by `CDLoot.toc`. The only other addon named anywhere is LoonBestInSlot, and it is optional.

2. **Public API.** Everything in the spec is implemented with the spec's names. Where I added to it, the addition is optional and marked "extension".
   - **Guild**
     - `IsReady`, `GetGuildName`, `GetMember(key, real)`, `IsInGuild(key, real)`, `IsOnline(key, real)`, `GetClass`, `GetRankName`, `GetMembers`, `GetConfig` (returns a copy), `IsCouncil(key, real)`, `AmICouncil(real)`, `GetCouncilMembers`, `GetGuildPhase`, `GetViewPhase`, `CanEditConfig`, `BuildTag(cfg)`, `WriteConfig(cfg)`.
     - Extension: the optional `real` argument ignores Demo data. The sync code always passes it, so a client in demo mode never acts as council over the network.
     - Extensions: `RequestRoster(force)`, `MarkOnline(key)`, `MarkOffline(key)`.
     - `CONFIG_UPDATED` also fires when the resolved council member set changes.
   - **Store**
     - `Get`, `GetAllKeys`, `ValidateData`, `Put(key, entry, via)`, `Remove`, `GetManifest`, `GetWanters(itemID, opts)`, `CountWanters`, `GetPlayerSummary`.
     - Extensions: `GetCached(key)` (the real cached record, never demo) and `opts.mainOnly` in `GetWanters`/`CountWanters`.
     - Each cached record gets a `g` field (guild name), so pruning after 30 days only touches lists from the current guild. The database is account-wide, so alts in other guilds share it.
     - `ValidateData` also limits table size and depth before hashing.
   - **Comm**
     - `Send(msg, dist, target, class)`, `SendToCouncil(msg, class)` (encodes once), `Register`, `RateLimit`, `OnCommReceived`, `stats` (with an extra `dropped` counter).
     - Extension: `GetHeldCount()` for debugging.
     - Deviation: the sender check now runs before decoding and before the protocol check. This stops strangers from forcing decompression work or triggering "incompatible version" chat lines.
     - Messages from senders not yet in the roster are held (up to 40, for 60 seconds) and replayed on `ROSTER_UPDATED`, as sync.md recommends.
     - "No player named ..." system messages are hidden for names this addon whispered in the last 15 seconds, and the player is marked offline.
   - **Sync**
     - `GetOnlineCouncilPeers`, `GetPeer`, `GetStatusText`, `SendHello`, `PushListTo(key, evidence)`, `PullFrom`, `OnCouncilHasNewer`, `NotePeerProtocol`, `GetVersions`, `RequestRestore(from, rev)`, `KeepMine()`.
     - Slash commands: `/cdl sync`, `/cdl version`. Popup: `CDLOOT_RESTORE`.
     - Deviations:
       - The status check mark is a texture escape (`ReadyCheck-Ready`), because the default font has no ✓ character.
       - A fifth status, "Sharing with council…", is shown while a council member is online but hasn't confirmed our current rev yet.
       - `PushListTo` may repeat a push after 30 seconds when a peer shows it lacks our rev. This covers a lost push or a crash before its saved data was written.
       - Automatic restore happens when own rev is 0 **or the list has no picks at all**. Otherwise the popup is shown, once per session. Offers are collected for 3 seconds and the newest copy is used. The spec's rev-0 rule alone would miss reinstalls, because BiS commits an equipment-only rev 1 about 11 seconds after login.
       - Council members swap manifests with one random online council peer every 10 minutes. This uses an M message with `q=true` ("please send yours back"). It repairs lost pushes within a session.
       - Our own share status is saved in `ns.db.peers[me]`.
       - `GetVersions` entries have both named fields and positions 1–4.

3. **Spec gaps and assumptions about other modules**
   - `BiS:ForceBump()` appears only in §10.3, not in the §8.2 list. I call it guarded, with a fallback that does what the spec describes.
   - I assume `BiS:IsDirty`, `Commit` (true/false), `NoteSeenRev`, `AdoptRestored({r, ts, h, d})` and `GetRecord` behave as in §8. Sync commits pending edits before sending, so the hash always matches the data.
   - I assume `Ledger:GetDigest`, `SyncFromDigest`, `HasAward` and `CountSince` exist; all calls are guarded.
   - I assume `Demo:GetRoster()` returns `{[key]={rankIndex, rankName, classFile, online}}` and `Demo:GetRecords()` returns `{[key]=record}`.
   - `Store:GetWanters` works out `via` from `ns.Data.Tokens`, `TokenArenaExchanges` and `Upgrades`, because `ExpandDrop` returns only IDs.

4. **Checker results**
   - `check.py` on the 4 files: 0 syntax errors, 0 global writes, 0 warnings. An earlier run flagged `GetGuildInfoText`, `SetGuildInfoText` and `CanEditGuildInfo` as unknown. The spec requires them and every call is guarded.
   - Simulation: 34/34 checks passed, using 3–4 clients with the real AceComm, LibSerialize and LibDeflate plus stub DB/BiS/Ledger modules.
     - **(a)** An edit reaches C1 in 1 message; C2 logs in later and catches up in 6 message parts.
     - **(b)** R's list reaches C1 when R logs back in (3 parts). C2 then gets it relayed from C1 (5 parts).
     - **(c)** A reinstall restores rev 12 automatically, identical by hash. The next edit becomes rev 13 on both council members.
     - **(c2)** When R already has picks, the popup is shown once. "Keep mine" makes rev 13, which the council accepts.
     - **Login race:** R, C1 and C2 logging in within about 1 second converge.
     - **Forged messages** are all rejected: relay, WANT and STATE from a non-council member, and a relay with a wrong hash. A protocol mismatch is reported once.
     - **Late roster:** a HELLO that arrives before the roster is loaded is held and then processed. A lost push is repaired by the 10-minute council exchange.
     - **Fixed during testing:** if the first roster came back empty, Guild waited 60 seconds. It now retries every 10 seconds until the roster fills.

5. **For the integration agent to double-check**
   - In game:
     - Is `GetGuildInfoText()` filled for normal ranks shortly after login? For the first 60 seconds an empty text falls back to the cached tag.
     - Does `SetGuildInfoText` work for officers?
     - Does the popup's `OnCancel` receive reason `"clicked"` from both "Keep mine" and Escape? Timeout and override reasons are ignored.
     - Does the `ERR_CHAT_PLAYER_NOT_FOUND_S` filter hide only our own whispers?
   - `GetNumGuildMembers()` / `GetGuildRosterInfo` are assumed to cover offline members even with "show offline" unticked (DBM relies on the same).
   - The receive size caps are 24,000 bytes on the wire and 200,000 decompressed. A relay of 8 worst-case lists should fit well inside that.
   - Please rerun `sync_sim\sim.py` once the real `BiS.lua` and `Ledger.lua` exist. Swapping `@stubs` in `ADDON_FILES` for the real files is enough.