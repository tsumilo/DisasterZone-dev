Final report: core agent, Addenda E §29/§31–§33 and D §24–§26 (as amended by E)

All the core work is in place. `check.py` is clean and a 15-case smoke scenario passes. With the new council model the existing suites fail wherever they assumed "rank ≤ 1 is council" or used the Guild Info tag. To tell those apart from real regressions, I also ran every suite with each client's guild list seeded with the rank ≤ 1 members. That seeded run's remaining failures are all tag or rank based, or intended design changes. None is a regression.

## Files changed
All paths are under `C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone`.

- **`Core/Guild.lua`** (rewritten):
  - **Roster:** the roster cache is kept, and the GM is taken from `rankIndex == 0` in the live roster. The last GM seen is saved (`db.council.gm`) because offline rows are hidden when "Show Offline Members" is unchecked.
  - **Guild council:** stored in `db.council.guild` with a guild-key stamp `g`. An alt's other-guild list is parked in `db.council.otherGuilds`, so switching characters doesn't refetch and re-trust the list.
  - **`CG` / `CQ`:**
    - GM-direct or relayed acceptance, trust-on-first-use (TOFU), the future-rev cap, and suppression of duplicate replies.
    - A CG with the same rev from a trusted source counts as confirmation and refreshes `recvAt`.
    - A `CQ` is sent 20–40 s after login when my list is missing or older than 7 days.
    - Piggyback: a council rev seen in HELLO/STATE (`OnCouncilRevSeen`) triggers a whispered `CQ`.
  - **Raid council:** in memory, with leader tracking. `CR` (leader only, checked with `GetRaidRosterInfo`) and `CRQ`. The leader re-shares 3 s after taking the lead; members ask 3 s after joining or reloading, plus a fallback 7 s after a leader change.
  - **Council checks:** `IsCouncil` / `AmICouncil` / `GetCouncilSource` follow the E §29 rule. Demo still forces me as council, and the demo's fake officers count too.
  - **Change events:** `CONFIG_UPDATED` fires when the council set, my status, the phase or the GM changes. Its payload is now a snapshot `{phase, gm, guild, raid, council}`.
  - **Removed:** everything that read or wrote Guild Info, the backups, and the popups.
- **`Core/GroupRules.lua`** (new; in the TOC after `Core\Dungeon.lua`):
  - It is a plain self-wiring table like Dungeon. Registering it with `ns:NewModule` at that TOC position would make it module #1 and break the "ItemDB and DB first" rule.
  - Authority, `GS` / `GQ` validation, the 5 s coalesced throttle, a one-time print per group session, and `/dz rules`.
- **`Core/DB.lua`:**
  - Adds `DB:GetEffective(path)` and `DB:IsGroupRulePath`.
  - Defaults: `council = {}` added, `settings.groupPhase` (nil) added, `guildCfg` removed.
  - An idempotent cleanup deletes `guildCfg`, `guildInfoSeen` and `guildInfoBackups`. There is no schema bump, because `test_boot` asserts schema 1. The "no longer uses Guild Info" notice prints once at login, and only if the old cache held a tag.
- **`Core/Sync.lua`:**
  - `cg` rides in HELLO and also in STATE replies; receivers pass it to Guild.
  - The promotion HELLO is kept.
  - Manifests, pulls and the ledger digest are exchanged only between guild-wide council pairs.
  - WANT relays to raid-scope council only cover raid members.
  - A newly recognised raid-scope council member gets my list 10–15 s later, unless their promotion HELLO arrives first.
- **`Core/Dungeon.lua`:**
  - Quality comes from the effective value.
  - `CanTellParty` is now "party leader or loot authority" (was "leader or council").
  - A DM from the current rules' source updates the active `dm` value at once.
  - Status and slash text mention "set by X".
  - Re-evaluates on `GROUP_RULES_CHANGED`.
- **`Core/Util.lua`:** `IsDungeonModeActive` uses `GetEffective("dungeon.enabled")`. The legacy DM switch only counts when the enabler doesn't speak `GS` (a 0.2 client).
- **`Core/Loot.lua`:** the quality threshold uses the effective value.
- **`Core/Roll.lua`:** roll duration uses the effective value.
- **`Core/Init.lua`:** `GROUP_RULES_CHANGED` added to the message catalogue.
- **`DisasterZone.toc`:** adds `Core\GroupRules.lua`.
- **Not changed:** `Comm.lua` and `Demo.lua` needed nothing.

## API
**Added (contract):**
- `Guild`: `GetGM`, `IsGM`, `GetCouncilSource`, `GetGuildCouncil`, `CanEditGuildCouncil`, `SetGuildCouncil`, `GetRaidCouncil`, `GetMyRaidList`, `SetMyRaidList`, `IsRaidLeader`, `AmIRaidLeader`, `GetOnlineMembers`, `GetGuildPhase` / `GetViewPhase` (new semantics).
- `GroupRules`: `GetAuthority`, `IsAuthority`, `GetActive`, `GetStatus`.
- `DB:GetEffective`.

**Added (extras):**
- `Guild:IsGuildCouncil`, `Guild:GetCouncilPhase` (already used by the UI agent), `Guild:GetGuildCouncilRev`, `Guild:OnCouncilRevSeen`.
- `GroupRules:GetRemoteValue`, `GroupRules:GetRulePhase`, `GroupRules:IsSpeaker`, `GroupRules:OnDungeonSwitch`.
- `DB:IsGroupRulePath`, and the `/dz rules` slash command.

**Removed:** `GetConfig`, `BuildTag`, `WriteConfig`, `CanEditConfig`, `ParseConfig`, `GetInfoBackups`, `RestoreInfoBackup`, `NoteInfoTextSeen`, `OnInfoTextMaybeLoaded`, `/dz guildinfo`, and the `DISASTERZONE_GUILDINFO_*` popups. Nothing in Core or UI still references Guild Info.

## Deviations from the addenda, and why
1. **`GS`/`GQ` channel:** they go on RAID or PARTY by group type, not `Util.GetGroupChannel()`. That function returns nil in a party until dungeon mode is on, and the rules are what decide dungeon mode, so using it would be circular.
2. **Future-rev cap:** also applied to GM-direct `CG`, not only relays. This is stricter; a real GM rev is always ≤ now.
3. **`CQ` fields and replies:**
   - It carries an optional `r` (my rev); a responder answers only if its rev ≥ `r`.
   - The "1 reply per 60 s" limit is per requester, plus suppression on GUILD, which the GM also honours.
4. **`cg` in STATE:** added so that a member who was picked while offline, and whose stored list is less than 7 days old, still learns the new list.
5. **`CR` handling:**
   - Every `CR` from the current leader is accepted, with no rev ordering.
   - A leader without a list sends an empty `CR` (rev 0), so members know there is none.
6. **`GQ` replies:** only the member that considers itself the authority answers. If every eligible member answered, a lower-priority member's rules could win on the joiner's client.
7. **Who counts as having DisasterZone:** a member that sent `GS` or `GQ` (a `GQ` proves it supports group rules).
8. **Rev ordering for `GS`:** none. The rev resets per session and on /reload.
9. **Eligibility (E §33):**
   - The D raid fallback ("council assist with the lowest rank") is dropped.
   - In a party, the "council member" fallback includes the GM, ordered by rank index, then name.
10. **Send-side clamping:** `rd` snaps to 15/20/30/45/60, and `q`/`dq` clamp to 3–4, so a local value outside those sets never gets my rules rejected by receivers.
11. **Stepping down:** a non-council party leader who turns dungeon mode off sends one final, unthrottled `GS` so the party drops their rules.
12. **Legacy DM:** "legacy DM-enabled" only counts when the enabler is a 0.2 client (see the Util entry above). Without this, a leader handing over to the GM left the old enabler off while everyone else stayed on.
13. **Raid-scope sync:** raid-scope council members get raid members' lists only, never guild-wide relays. This isn't stated in E, but it follows the §29 raid-scope rule.

## Races (analysed and covered by smoke cases)
- **GM and a relaying council member both answer a `CQ`:**
  - The GM answers after 0.2–1 s, a relayer after 2–8 s. A relayer skips if a trusted `CG` with the same rev was seen on GUILD after the `CQ` arrived.
  - Whispered `CQ`s have a single target.
  - A duplicate is harmless: the second copy has an equal rev, so it only refreshes `recvAt`.
- **Leader change mid-raid:**
  - Every client clears the old leader's raid council on `GROUP_ROSTER_UPDATE` / `PARTY_LEADER_CHANGED`. A late `CR` from the old leader fails the live rank-2 check.
  - The new leader sends its list after 3 s; a fallback `CRQ` goes out at 7 s.
  - Group rules follow the same priority. The old source's rules stay only while it is still eligible (for example as master looter), until the new leader's `GS` replaces them.
- **/reload while raid leader:**
  - The raid council is rebuilt from `db.council.myRaidList` and re-sent after 3 s; members already hold the same rev.
  - `GS` is re-announced with a reset rev, which members accept.
- **Raid → party → raid:**
  - Raid council and raid-leader council status are cleared on the conversion, and raid-scope council loses its status.
  - The group-rules session continues, but candidates are recomputed and the authority re-announces (adding or removing `dm`). The party DM switch is cleared.
  - Converting back to a raid re-shares the raid list: the leader sends after 3 s and members ask with `CRQ`.
- **Two clients each believe they are the authority:** priority is deterministic (leader before master looter). A fall-through authority waits 7 s instead of 3 s before announcing. When a higher-priority `GS` arrives, the lower one yields and every receiver accepts the higher one. Tested with the leader and master looter in the same raid.
- **Stale `CG` relayed after the GM removed someone:**
  - Revs never go backwards.
  - A removed member's copy can only raise an older client's rev as an intermediate step, which a newer rev later supersedes.
  - Their forged newer revs fail the relay check on any client whose list excludes them.
  - Residual risk: a brand-new client (no stored list) can be fooled through TOFU. The damage is capped by the ≤ now+300 s rule, and the GM's next save wins.

## CROSS-FILE NEEDS
- **`Core/Ledger.lua` (not mine):**
  - Ledger gates use `IsCouncil`, so raid-scope council in the same raid can exchange the award log (A/LW/LG).
  - The raid leader is now council (E §29), so they auto-record loot lines in raid instances.
  - If the full log should stay guild-council only, gate LW/LG on `Guild:IsGuildCouncil`.
- **UI agent:**
  - Use `Guild:GetCouncilPhase()` for the guild phase.
  - Use `DB:GetEffective` plus `GroupRules:GetStatus()` for the Settings controls; `GROUP_RULES_CHANGED` fires on every status change.
  - `/dz rules` is new and `/dz guildinfo` is gone.
- **TOC version:** I suggest bumping it to 0.3.0 so 0.2 users get the "newer version" notice. I left it alone because `test_boot` asserts 0.2.0.
- **Test & Fix agent:** the migrations are listed under the suites below.

## check.py
- `Core`: 17 files, 0 syntax errors, 0 global writes, 1 warning (`UPDATE_MASTER_LOOT_LIST`, pre-existing).
- Whole addon: 30 files, 0/0, 2 warnings (`UPDATE_MASTER_LOOT_LIST`, `ChatFrameUtil.OpenChat`, both pre-existing), 1 info. The old `C_GuildInfo.GetInfoText` warning is gone.

## Suites run (all 29 test files)
**Plain run.** Only these pass fully: `test_tooltip` 6/6, `conformance/demo_isolation` 7/7, `conformance/ui_xmodule` 11/11. Everything else fails wherever a rank-1 officer was assumed to be council or the Guild Info tag was used:
- `boot-ui`: `test_access`, `test_boot`, `test_broad`, `test_council_ui`, `test_demo`, `test_lootlog`, `test_mybis`, `test_perf`, `test_settings`, `test_slash`.
- `guildinfo` 0/8 (the feature is removed).
- `loot-roll`: all five files.
- `rollclose`.
- `sync`: all six files.
- `dungeon`: `test_dungeon`, `test_dungeon_core`.
- `ui-dungeon`.

**Seeded run** (rank ≤ 1 members put on the guild list, as the old default tag did):
- **All passing:** loot-roll (award 17, drops 17, ledger_auto 9, roll_close_core 10, rolls 20), rollclose 15, ui-dungeon 10, sync_hostile 13, sync_traffic 2, sync demo_isolation 5, `test_council_ui` 14, `test_demo` 5, `test_lootlog` 7, `test_perf` 3, `test_broad` 1, `test_tooltip` 6, both conformance suites.
- **Remaining failures, all expected, for the Test & Fix agent:**
  - **Tag or rank based:** `guildinfo` (8); `test_access` (8 tag/rank cases); `test_settings` (3, the Guild Info editor); `test_boot` `late_load` (the tag set phase 2); `test_mybis` phase (tag); sync `council_membership` (4, promotion via tag); `sync_flows` `j_guildless_then_guild_change` (tag phase).
  - **New slash list:** `test_slash` help (`rules` added, `guildinfo` removed).
  - **Seeding artefact:** `test_boot` idempotency (the seed rewrites `recvAt` on every load; it passes in the plain run).
  - **E semantics:** `ledger_sync` `g_awards_recorded_while_c2_offline` (the raider in that test leads the raid, so it is council and records).
  - **D semantics:** 6 dungeon cases (see below).

**The 6 dungeon cases (D semantics):**
- `dm_from_plain_member_is_ignored`
- `party_without_dungeon_mode_keeps_todays_behaviour`
- `council_member_can_enable_and_non_council_leader_too`
- `enabler_leaving_the_party_clears_it`
- `enabler_who_passed_the_lead_can_still_turn_it_off`
- `plain_member_cannot_enable_it_for_the_party` (the Settings control is disabled while the rules come from someone else)

The reason in all six: while the party has a loot authority, a member's own dungeon-mode switch no longer turns the mode on for themselves, and a council member who isn't the authority can't turn it on for the party.

**Extra checks:**
- A mixed 0.2/0.3 run (0.2 party leader DM, 0.3 leader to a 0.2 member, 0.2 raid leader with a 0.3 master looter as authority) passes 3/3 with no Lua errors.
- The smoke scenario covers picking the guild council, CQ relay/TOFU, forged and future-rev `CG`, raid council lifecycle (CRQ, disband, re-share, leader change), group rules (raid, master-looter fall-through, reload, forged or out-of-range `GS`, disband), party dungeon mode and stepping down, migration, raid-scope list sync, stale relays, the HELLO/STATE piggyback, alt guild parking, dual authority, and raid↔party conversion.

Everything is in `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad`:
- Dev scripts in `core_e_backup\`: `smoke_e.py`, `mixed_e.py`, `seeded.py`, `run_all.py`.
- Pre-change backups: `core_e_backup\Core\`, `core_e_backup\DisasterZone.toc`.
- Logs: `out_core_e\final_plain\`, `out_core_e\final_seeded\`.