# CDLoot SPEC — ADDENDUM D: leader-controlled group loot settings

User (2026-09-28): "settings like loot duration, dungeon mode, etc, should be controlled by the party / raid leader (if they are eligible) based on loot council status … and it should sync automatically to the other clients."
Agreed design: settings fall into three tiers.

| Tier | Who decides | Settings | Transport |
|---|---|---|---|
| **Guild** (exists) | GM/officers | council membership, guild phase | `CDL{...}` tag in Guild Info (§13) |
| **Group rules** (NEW) | the group's *loot authority* | `roll.duration`, `qualityThreshold` (raid drop threshold), `dungeon.enabled` (party only), `dungeon.quality` | `GS` message on the group channel |
| **Personal** | each player | `roll.popup`, `alerts.*`, `tooltip.*`, `minimap`, `dropPanelMode`, `announceChannel`, windows, `viewPhase`, debug | never synced |

## 24. Group loot authority
- **Eligibility**, computed locally on every client from server-authoritative data (roster, guild config):
  - **Raid:** the raid leader if (council OR master looter); else the master looter; else nobody. With master loot the ML is always eligible, even if not council, because they are physically distributing loot. A council raid assistant is NOT an authority unless no leader/ML authority exists; then the council assist with the lowest guild rank index wins (ties → name).
  - **Party:** the party leader if council, or if they turned on dungeon mode for the group; else a council member in the party, choosing the lowest guild rank index (ties → name). This replaces the separate `DM` sender gate with the same logic, but keep accepting `DM` from 0.2 clients for compatibility.
- `ns.GroupRules:GetAuthority()` → key|nil — the highest-priority *eligible* member **who has CDLoot** (sent `GS` or answered `GQ` this group session). If the best eligible member has no addon, fall through to the next eligible one; if none has it, there is no authority and everyone uses personal values.
- Re-evaluate on `GROUP_UPDATED`, `PARTY_LOOT_METHOD_CHANGED` / `PARTY_LEADER_CHANGED`, and `CONFIG_UPDATED`.

## 25. Messages (group channel = `Util.GetGroupChannel()`, alert class, single part)
- `GS` = `{t="GS", v=<rulesRev>, rd=rollDuration, q=qualityThreshold, dq=dungeonQuality, dm=bool (party only)}`.
  - **When the authority sends it:**
    - When it becomes the authority (debounced 3s after group/loot-method changes).
    - Whenever it changes one of the group-rule settings.
    - In reply to `GQ`.
    - Rate limit: at most 1 per 5s; queued changes are coalesced.
  - `rulesRev` increments per change and resets per group session.
  - Receivers accept `GS` only if the sender is currently eligible (§24) and has priority ≥ the current authority's. Validate the ranges: `rd` ∈ {15,20,30,45,60}, `q` ∈ {3,4}, `dq` ∈ {3,4}.
  - Store `ns.GroupRules.active = {from=key, rev=, values={...}, at=GetTime()}`. Fire `GROUP_RULES_CHANGED`. Print once per group session for non-authorities: "CDLoot: loot rules set by <Name> (rolls 30s, epics+)".
- `GQ` = `{t="GQ"}`. Sent by a client ~3s after joining a group or /reload while in a group, when it has no active rules. Eligible members with the addon reply with `GS`. Rate-limit replies: 1 per 5s per group.

## 26. Effective settings API (all consumers must use this)
- `ns.DB:GetEffective(path)` → for group-rule paths, if `ns.GroupRules.active` exists and I'm still in that group, return the group value; else `ns.DB:GetSetting(path)`. For other paths it's identical to GetSetting.
- **Replace reads** of group-rule settings in Loot (drop quality threshold), Roll (duration), Dungeon mode (enabled/quality) and anywhere else with `GetEffective`.
  - Exception: my OWN edits in Settings still write my personal value.
  - If I am the authority, my personal value IS the group value; broadcast on change.
- **Leaving the group** (or authority lost with no replacement): clear `active`, fire `GROUP_RULES_CHANGED`. Everyone falls back to personal values.
- **Dungeon mode:** `Util.IsDungeonModeActive()` = in party, not raid, and (`GetEffective("dungeon.enabled")` or legacy `DM`-enabled).

## 27. Settings UI
- The group-rule controls (roll duration, minimum quality, dungeon mode enable, dungeon quality) show a small status line above them:
  - "Your own settings (not in a group / no loot leader with CDLoot)".
  - "You set these for your group" (I'm the authority).
  - "Set by <Name> for this group" (read-only: the controls are disabled and show the group values).
- Personal controls are unaffected.
- `/cdl rules` prints the effective group rules and their source.

## 28. Tests (harness; tests/grouprules/test_grouprules.py)
- A raid with a council raid leader: raiders receive `GS`; their effective duration/quality equal the leader's; the Settings controls are disabled and show "Set by".
- The leader changes the duration → raiders update, and the next roll uses it.
- A non-council leader without master loot → no authority; a non-council ML → authority.
- A raider joining mid-raid gets the rules via `GQ`.
- A /reload mid-raid restores the rules via `GQ`.
- A forged `GS` from an ineligible raider is ignored. Out-of-range values are rejected.
- The leader leaves → the next eligible authority, or personal values.
- Party with dungeon mode: the party leader enables it → every member active; a non-leader non-council member can't enable it.
- Group disband → everything reverts to personal values.
- Mixed with a 0.2 client (no `GS` support): no errors; `DM` compatibility still works.
