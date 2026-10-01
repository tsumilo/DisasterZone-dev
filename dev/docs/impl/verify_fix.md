All 28 findings are handled: 27 fixed and 1 deferred (the JSON has 29 entries because the demo announce leak was reported twice). Every test suite passes, and check.py shows 0 syntax errors and 0 global writes. The TOC is now 0.2.0.

**(1) Findings → status**

| # | Finding (severity) | Status | What changed |
|---|---|---|---|
| 1 | Tier token saved as a BiS pick and never counts as obtained (med) | fixed | `SetSlot` and `ApplyTemplate` swap a token for your class's piece when only one fits the slot, otherwise refuse with a message. Token picks already saved by 0.1 count as obtained once you own your class's piece. Core/BiS.lua |
| 2 | "Request sync" buttons say "Sync requested." when nothing was sent (low) | fixed | New `Sync:RequestSync()` gives the same messages as `/dz sync`. The council button only disables itself when a HELLO really went out. Core/Sync.lua, UI/Council.lua, UI/Settings.lua |
| 3 | Items view stays on the old phase's boss (low) | fixed | Changing the phase clears the selected boss. UI/Council.lua |
| 4 | Fake demo member stays in the Member view after demo off (low) | fixed | Turning demo mode on or off clears the selected member, boss and focus. UI/Council.lua |
| 5 | Quick double /reload leaves the client with no council peers (med) | fixed | HELLO now carries a per-session number; reply rate limits count per session, plus a 5 s cap per sender. Core/Sync.lua |
| 6 + 25 | Demo mode posts fake names to raid chat (med/low, duplicate) | fixed | DropPanel announce and the Council "Announce to raid" print `[demo, not sent]` locally instead. UI/DropPanel.lua, UI/Council.lua |
| 7 | Award log is account-wide, so an alt in another guild mixes logs (med) | fixed | Each entry is tagged with its guild; the view, digest, serving and sending use only the current guild's entries. Old 0.1 entries are adopted when the recorder or winner is in the current guild's roster. Core/Ledger.lua, Core/Guild.lua (new `GetGuildKey`) |
| 8 | Own "Shared with council" marker deleted at every login (low) | fixed | The marker now gets a `lastSeen` time. Core/Sync.lua |
| 9 | Promotion HELLO lost to the rate limit (low) | fixed | The promotion HELLO skips the rate limit. Core/Sync.lua |
| 10 | Decompression bomb (low) | fixed, mitigated | Non-council senders are capped at 4,000 wire bytes (a full list is about 1.1 KB); council stays at 24,000. A sender whose payload inflates past the limit is ignored for the rest of the session. A bomb just under 4 KB can still cost one short hitch per sender per session. Core/Comm.lua |
| 11 | "Incompatible version" notice can be spammed (low) | fixed | At most one notice per sender per session; an odd first byte prints as `?`. Core/Sync.lua |
| 12 | One STATE with rev 1e9 makes the list unshareable (low) | fixed | One shared `ns.MAX_REV`; commits are clamped to it; council revs more than 100,000 above yours are ignored. Core/Constants.lua, Store.lua, Sync.lua, BiS.lua |
| 13 | Two council copies of the same rev never reconciled (low) | fixed | STATE and the council login HELLO now carry list hashes. The owner pushes when the rev matches but the hash differs. Hashes are left out of the manifest message so it stays single-part. Core/Sync.lua, Core/Store.lua |
| 14 | Changed lists sent twice to a returning council member (low, efficiency) | deferred | This follows the spec (§10.3) and the test allows two copies. The cheap idea of skipping the reply at rev 0 would break first-time sharing, because that reply is how an owner learns which council members are online. A real fix needs push/pull coordination. |
| 15 | Restarting a roll after /reload gets cancelled raid-wide (med) | fixed | A new roll from the same starter replaces their stale open roll (cancelled if same item, closed otherwise). Core/Roll.lua |
| 16 | Handing the item out before confirming moves the suggestion (med) | fixed | Priority tiers are frozen when the roll opens. Core/Roll.lua |
| 17 | Two simultaneous awards: clients disagree and the item is credited twice (low) | fixed | The award message now carries the award time. Every client keeps the same award (master-loot hand-out first, then earliest, then awarder name). The losing log entry is voided and the awarder gets a chat notice. Core/Roll.lua, Core/Ledger.lua |
| 18 | Fallback drop key uses the local clock, so a second looter duplicates the drop (low) | fixed | The key uses server time and boss. An "unknown source" drop with the same items within 180 s is treated as the same drop. Core/Loot.lua |
| 19 | Sunmote upgrade labelled "via token" (low) | fixed | Shared `ns.VIA_TEXT` used in the toast, the chat line and the roll popup. Constants.lua, DropPanel.lua, RollFrame.lua, Tooltip.lua |
| 20 | Non-council master looter's suggestion ignores BiS (low) | fixed | New message: council clients whisper the BiS tiers (main/alt) of raid members who want the item to a non-council starter or master looter. It is whispered to them only, not sent to the raid. Core/Roll.lua |
| 21 | Non-council master looter's award missing from the log (low) | fixed | Every council client records roll awards under one shared entry id, so they merge instead of duplicating. Core/Roll.lua, Core/Ledger.lua |
| 22 | Suggestion can pick a player who left the raid (low) | fixed | Rolls from players no longer in the group are shown but never suggested. Core/Roll.lua |
| 23 | Real roll awarded while demo is on is lost (med) | fixed | Real rolls always use the real log and the real award message, even in demo mode. Awarding a real roll needs real permissions. Core/Roll.lua, Core/Ledger.lua |
| 24 | Real raid drops ignored while demo mode is on (low) | fixed | Removed the extra demo-aware group check; the transport layer already checks the real group. Core/Loot.lua |
| 26 | Item text's second return value lands in the tooltip colour argument (low) | fixed | The local wrappers return only the text. UI/Council.lua, UI/LootLog.lua |
| 27 | Guild info text read/written through deprecated aliases (med) | fixed | Confirmed in Blizzard's 2.5.6 source. Now uses `C_GuildInfo.GetInfoText`/`SetInfoText`, with the old globals as fallback. Core/Guild.lua |
| 28 | Spec auto-detect uses the deprecated `GetTalentTabInfo` (low) | fixed | Uses `C_SpecializationInfo.GetSpecializationInfo` (points spent is the 7th value), with the old function as fallback. Core/BiS.lua |
| 29 | "→" has no glyph in the default font (low) | fixed | The award line uses "->". The font scan showed · × — … are all present; "▾" was only in a comment and is removed. Core/Roll.lua |

- **Also changed:**
  - DisasterZone.toc is now `## Version: 0.2.0`. The protocol major stays 1.
  - The additions (HELLO nonce and hashes, hash in STATE, award time and note in the award message, the new tier whisper) are optional fields that 0.1 clients ignore.
- **Test edits:** tests/boot-ui/test_boot.py, test_settings.py and test_slash.py only had "0.1.0" replaced with "0.2.0", because of the version bump.
- **Harness gap fixed:** tools/wowmock/game.lua lacked the native 2.5.6 APIs, so the new code paths were never exercised. I added `C_GuildInfo.GetInfoText`/`SetInfoText` and `C_SpecializationInfo.GetSpecializationInfo`.
- **Unrelated harness failure:** tools/test_harness_selftest.py has one failure (`test_items_guild_group_units_gear`, WristSlot 28477). It fails the same way with the original game.lua.

**(2) Final results**
```
check.py: -- checked 28 file(s): 0 syntax error(s), 0 global write(s), 4 warning(s), 1 info
  (C_GuildInfo.GetInfoText/SetInfoText: exist in Blizzard's 2.5.6 source, but no reference addon reads them;
   UPDATE_MASTER_LOOT_LIST and ChatFrameUtil.OpenChat were already flagged before)
-- test_access.py: 12 case(s), 12 passed, 0 failed
-- test_boot.py: 12 case(s), 12 passed, 0 failed
-- test_broad.py: 1 case(s), 1 passed, 0 failed
-- test_council_ui.py: 14 case(s), 14 passed, 0 failed
-- test_demo.py: 5 case(s), 5 passed, 0 failed
-- test_lootlog.py: 7 case(s), 7 passed, 0 failed
-- test_mybis.py: 16 case(s), 16 passed, 0 failed
-- test_perf.py: 3 case(s), 3 passed, 0 failed
-- test_settings.py: 9 case(s), 9 passed, 0 failed
-- test_slash.py: 9 case(s), 9 passed, 0 failed
-- test_tooltip.py: 6 case(s), 6 passed, 0 failed
conformance/test_demo_isolation.py: 7/7 passed
conformance/test_ui_xmodule.py: 11/11 passed
-- loot-roll / award: 17 case(s), 17 passed, 0 failed
-- loot-roll / drops: 17 case(s), 17 passed, 0 failed
-- loot-roll / ledger auto-record: 9 case(s), 9 passed, 0 failed
-- loot-roll / rolls: 20 case(s), 20 passed, 0 failed
-- council membership: 4 passed, 0 failed
-- demo isolation: 5 passed, 0 failed
-- ledger sync: 10 passed, 0 failed
-- sync flows: 18 passed, 0 failed
-- hostile traffic: 13 passed, 0 failed   (bomb delivery tick now 0.00 s)
-- 40-member guild traffic: 2 passed, 0 failed
```
The hashes cost some traffic. In the in-sync 40-login wave, bytes went from 4,888 to 7,460 and the last message arrived 45 s after the wave instead of 44 s.

**(3) Check in game**
- [ ] The guild config tag loads; as GM, "Save to Guild Information" works. `/dump C_GuildInfo.GetInfoText()` returns the text.
- [ ] Optional: `/console loadDeprecationFallbacks 0`, `/reload`, and check that the council tag, spec auto-detect and Save still work. Set it back to 1 afterwards, because other addons may need it.
- [ ] Spec auto-detect on a fresh character picks the tree with the most points.
- [ ] Shift-click a tier token in the picker: a Paladin gets the refusal message, a Mage gets their piece.
- [ ] With 0.1 and 0.2 clients mixed in the guild: no Lua errors, lists still sync.
- [ ] /reload twice quickly while a 0.2 council member is online: status shows "Shared with council".
- [ ] Non-council master looter starts a roll: within about a second their panel shows BiS main/alt and "Award to <BiS player>". This needs a 0.2 council member in the raid.
- [ ] Give the item from the normal master-loot menu, then click "Award to <suggested>": the suggestion stays, the raid line ends in "BiS", and the log shows one entry.
- [ ] Two officers awarding the same roll at once: every client ends on the same winner and the log shows one entry.
- [ ] Demo on in a real raid: Announce and "Announce to raid" post nothing to raid chat; real boss drops still appear.
- [ ] The award raid line shows "->" correctly.
- [ ] After updating, a council character's loot log still shows old awards once the guild roster loads. Entries whose recorder and winner have both left the guild stay hidden.
- [ ] The login HELLO from council members is larger now; check there is no noticeable lag during a guild login wave.

**(4) Changelog (0.2.0)**
- **BiS lists:**
  - Picking a tier token now picks your class's tier piece, or tells you which item to choose.
  - Token picks saved by the old version count as obtained once you own your class's piece.
  - Spec auto-detect uses the 2.5.6 talent API.
- **Syncing:**
  - "Request sync" now tells you whether a sync was actually sent.
  - Sharing works right after a quick double /reload.
  - "Shared with council" survives /reload.
  - Newly promoted officers get lists straight away.
  - Lists edited on two PCs are repaired automatically.
- **Council window:**
  - Changing the phase jumps to that phase's first boss.
  - Demo members disappear when demo mode is turned off.
- **Award log:** kept per guild, so alts in other guilds no longer mix logs.
- **Rolls:**
  - The suggestion stays with the BiS winner even if the item was already handed out.
  - Players who left the raid are not suggested.
  - A roll restarted after a /reload runs for everyone.
  - Two officers awarding at the same moment end up with one winner.
  - Non-council master looters see BiS priority, and their awards reach the council's log.
  - Awarding a real roll while demo mode is on works properly.
  - The award line uses "->".
- **Demo mode:**
  - Never posts fake names to raid chat.
  - Real boss drops still show while it is on.
- **Drop alerts:** Sunmote upgrades and arena exchanges are labelled correctly.
- **Guild info text:** read and written through the 2.5.6 API.
- **Hardening:**
  - The incompatible-version notice appears once per player.
  - Oversized messages from non-council members are dropped before decompression.
  - Implausible revision numbers are ignored.

Addon folder: C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone. Test logs for the final run are in C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\out_fix\final2\.