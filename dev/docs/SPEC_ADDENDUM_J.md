# CDLoot SPEC — ADDENDUM J: raid planning (teams, raid events, sign-ups, group builder)

User request (2026-09-29): a Raid-Helper-style raid planner inside CDLoot, built into the Raids tab. It must be very
easy to find and answer raids. Officers build **teams** and pick which teams a raid is for.

Agreed decisions (2026-09-29):
- **Organizers** = the GM and the guild council (Addendum E). They create and edit raids and teams.
- **Visibility:** everyone sees every raid and anyone may sign up. Invited teams get the login reminder and appear in a
  "No response" list.
- **Weekly repeats** in v1: the next occurrences are always there, with the same teams.
- **Group builder:** manual drag and drop plus one Auto-fill button; "Invite & sort" invites and moves people.
- Deliberately **not** included: per-boss assignments, auto-marking, an assignment solver (the Addendum-less
  assignment module was reverted on 2026-09-28).

Build order: §54-§57 core (step 1), §58 Raids tab rework (step 2), §59 composition (step 3), §60 group builder
(step 4), §61 raid log tie-ins (step 5).

## 54. Concepts and data (`db.raidplan[guildKey]`, account-wide, scoped per guild)

```lua
db.raidplan[guildKey] = {
  T = { [id] = { id, rev, by, n = "Kara Team A", m = { key, ... } (sorted), del = true|nil } },
  S = { [id] = { id, rev, by, t = first occurrence (server time), i = instance key, sz = 10|25, tm = { teamId, ... },
                 ti = title|nil, no = note|nil, u = last week index|nil, x = true|nil (deleted) } },
  E = { [id] = { id, rev, by, t, i, sz, tm, ti, no, x = true|nil (cancelled), grp = { [key] = 1..8 }|nil,
                 sid = seriesId|nil, k = week index|nil } },
  U = { [occId] = { [key] = { st = "A"|"T"|"B"|"X", sp = spec index, c = classFile, n = note|nil, rev } } },
}
db.raidplanSpec[charKey] = spec index last used by that character (a personal preference, never synced)
```

- **Team** (`T`): a named list of at most 40 guild members. A member can be on several teams. Deleting leaves a
  tombstone (`del`) for 30 days so the deletion spreads.
- **Series** (`S`): a weekly raid. Occurrence `k` (0, 1, 2, ...) is at `t + k * 7 days` and has the id `"<sid>#<k>"`.
  Clients generate occurrences locally, so a weekly raid costs no messages per week. Occurrences are shown from 14 days
  back to 14 days ahead (occurrence 0 always). `u` stops the series after that week ("Stop repeating").
- **Event** (`E`): a one-off raid, or an **override** of one series occurrence (`sid` + `k`, id = the occurrence id).
  An override only holds the fields that differ; a missing field follows the series, so a later series edit still
  reaches an occurrence that only has, say, a group layout.
- **Editing a weekly raid:** "this raid only" writes an override; "all raids in the series" edits the series in place
  (sign-ups are keyed by occurrence id, so they are kept).
- **Sign-up** (`U`): per occurrence, per character. Status Accept / Tentative / Bench / Absent, spec index into
  `ns.SPECS[class]` (the role follows from the spec: druids pick Feral (Cat) or Feral (Bear)), class token, optional
  note (at most 40 characters). A character signs up only for itself.
- **Invited** = the union of the members of the occurrence's teams. A raid without teams is for everyone.
- **Instances:** Karazhan (10), Gruul's Lair, Magtheridon's Lair, Serpentshrine Cavern, Tempest Keep, Mount Hyjal,
  Black Temple (25), Zul'Aman (10), Sunwell Plateau (25), and "Other". An optional title overrides the name
  ("Gruul + Mag").
- **Revisions:** every record carries `rev = max(now, previous + 1)` (server time), at most 5 minutes in the future
  when received. Higher rev wins; the same rev settles on the larger record hash, so every client converges.
- **Retention:** occurrences (and their sign-ups and overrides) older than 15 days are dropped; deleted series and
  team tombstones after 30 days; a series whose last week is older than 15 days is dropped.

## 55. Permissions and trust

- Organizers (the GM or on the guild council list) create and edit teams, raids and group layouts. Everyone else can
  only write their own sign-ups.
- Live edits (`RPU`) must come from the editor (`by` = sender); a sign-up (`RPS`) must come from its character.
- **Relays:** any guild member serves what it has to a member who logs in later (`RPG`), so a raid reaches people after
  the organizer went offline. A relay can't be proven to come from the original author; this is the same trust
  level as a guild member typing in guild chat. Everything received is validated (types, lengths, caps, timestamps).
- A raid or team is **shown** only while its last editor (`by`) is an organizer. Records by anyone else are kept (so
  digests still agree) but hidden. Right after a fresh install they show up once the guild council list arrives.

## 56. Sync

- **Live:** an organizer's change is sent on GUILD as `RPU { k = "T"|"S"|"E", r = record }`. A sign-up is sent on GUILD
  as `RPS { l = { { o = occId, s = signup }, ... } }`. At login every client also sends its own sign-ups for occurrences
  still shown (one small message), so a sign-up made while nobody else was online spreads later.
- **Catch-up at login:** the HELLO (`H`, Sync) carries `pd` = one hash over my plan data (0.6 clients ignore it).
  - A client whose hash differs answers after a delay (council 0.5-2.5 s, others 3-8 s) with
    `RPD { to = L, h = my hash, d = { [item] = hash } }` on GUILD. Items: `T:<id>`, `S:<id>`, `O:<occId>` (the
    override plus the sign-ups of one occurrence).
  - Anyone who sees an `RPD` to L with the same hash as theirs during their delay stays quiet, so usually one client
    answers.
  - L answers the first `RPD` only. It whispers `RPW { w = { item, ... } }` for the items that differ, and sends its
    own copy of those items (`RPG`) to the responder. Both sides merge, so both converge.
  - `RPG { T = team }` / `{ S = series }` / `{ o = occId, e = override|nil, u = { [key] = signup } }` is one item per
    message, which keeps members' messages under the non-council size caps.
- Caps: 20 teams, 40 members per team, 12 series, 60 events, 60 sign-ups per occurrence, 80 digest items.
- Message types `RPU RPS RPD RPW RPG` (checked against the existing types, see `tests/conformance`).

## 57. Core API (`ns.RaidPlan`)

`CanOrganize()`, `GetInstances()`, `GetTeams()`, `GetTeam(id)`, `SaveTeam(id|nil, name, members)`,
`DeleteTeam(id)`, `CreateRaid(fields)`, `EditRaid(occId, fields, scope)`, `CancelRaid(occId, scope)`,
`GetRaids(from, to)`, `GetRaid(occId)`, `GetSignups(occId)`, `GetMySignup(occId)`, `SignUp(occId, status, spec, note)`,
`GetInvited(occId)`, `GetUnanswered(days)`, `SetGroups(occId, grp)`, `GetDigest()`, `GetDigestHash()`.
Messages fired: `RAIDPLAN_CHANGED`.

## 58. Raids tab (step 2, built)

- The tab is available to every guild member. Views: **Upcoming** (default), **Teams**, **Raid log** (council only;
  the Addendum I Raids / Players modes). `/cdl raids` opens Upcoming; `/cdl plan` prints the list in chat.
- **Upcoming:** the list is grouped This week / Next week / Later / Recent (started more than 6 h ago, newest first).
  A row shows date, time, raid (size), teams, accepted count and my answer; an orange bar = invited and not answered.
  The raid I still have to answer is selected first.
- **Detail:** title, date, teams, organizer, note; the sign-up strip (Accept / Tentative / Bench / Absent, spec dropdown
  preselected from my last sign-up or my BiS list's spec, a note saved with Enter); counts; the roster in four
  columns (Tanks / Healers / Melee / Ranged: accepted then tentative) and lines for spec not set, Bench, Absent and No
  response (invited members without an answer). Organizers get **Edit** and **Cancel...** (cancel / restore, stop
  repeating, delete the weekly raid).
- **New / Edit raid window:** raid, size, title, day (next 60 days), time (15-minute steps, local clock), teams, note,
  Repeat weekly. Editing a weekly raid offers "This week only" (an override holding only the changed fields) and
  "Save every week".
- **Teams:** list + detail; organizers edit a draft (name, members through the guild search picker) and Save / Undo /
  Delete; members see the teams read-only. The detail shows which upcoming raids invite the team.
- **Login reminder:** 45 s after login, one chat line lists my teams' raids in the next 7 days without my answer.

## 58a. Sign-up order (added 2026-09-29)

- A sign-up carries `at` = when the character first answered that raid (validated `1 <= at <= rev`); changing the
  answer keeps it, so the place in line is kept. Sign-ups made before this have no `at` and count from their `rev`.
- `RaidPlan:GetSignupOrder(occId)` = `{ [key] = position }, total`, by `at`, then name.
- Hover in the Sign-ups tab (every roster cell; Bench, Absent and spec-not-set players are now cells under their header
  line too) and on the Groups tab chips: "Sign-up #7 of 23 · Tue 30 Sep 20:14", plus "Changed to Accepted <time>"
  when the answer changed at least a minute later. Each role column lists Accepted before Tentative, first come first.

## 59. Team specs, buffs and the group grid (built 2026-09-29, requested with step 3)

- **Team record** (T) gains `sz` (10 | 25, default 25), `s = { [key] = spec index }` (the spec a member plays in this
  team) and `grp = { [key] = 1..8 }` (the team's group layout). Entries for non-members are dropped when validated.
- **A member's spec** (`RaidPlan:GetMemberSpec`): the team's pick, else their latest sign-up's spec, else their BiS
  list's spec (mine, or a list the council has cached), else unknown. Automatic specs show dimmed.
- **Composition data** (`Core/RaidComp.lua`): spec icons; TBC buffs with scope (party: Bloodlust/Heroism, Windfury,
  Wrath of Air, Totem of Wrath, Unleashed Rage, Mana Tide, Battle Shout, Trueshot, Ferocious Inspiration, Leader of
  the Pack, Moonkin Aura, Vampiric Touch, Sanctity Aura, paladin aura; raid: blessings (counted per paladin),
  Fortitude, Divine Spirit, Mark of the Wild, Arcane Intellect; debuffs: Sunder, Blood Frenzy, Faerie Fire, Hunter's
  Mark, Expose Weakness, Curse of the Elements, Misery, Improved Scorch, Judgement of Wisdom). A member without a known
  spec only counts for buffs every spec of the class has.
- **Group grid** (`UI/RaidGroups.lua`, reused by the raid group builder): raid-wide strip (lit / greyed icons with
  providers in the tooltip), 2 or 5 group boxes of 5 slots with the party buffs present in each group, and a "Not in a
  group" pool. Chips show class icon, spec icon and name. Organizers drag chips, or click a chip and then a group /
  another chip (swap) / the pool; a full group refuses a drop that isn't a swap. Right-click: spec (automatic or a
  pick), move to a group, take out, remove from the team. Members see the grid read-only.
- **Swapping whole groups:** each group header has a "swap" link (organizers): click it, then the other group (its
  link or anywhere on it); every player of the two groups trades places (Teams draft or the raid's layout). Where a
  player sits inside a group can't be set by addons (the game orders players within a group).
- **Teams view:** name, Undo / Save / Delete, the member search, size (10 / 25; shrinking drops groups 3-5) and
  **Auto-fill**, then the grid. All edits are a draft until Save.
- **Auto-fill (§60):** 25-man = tanks / melee / melee / ranged / healers, 10-man = tanks + melee / ranged + healers.
  Shamans first, one per group that wants their totems (Enhancement / Restoration to melee, Elemental to ranged); then
  members who bring a party buff; then the rest by role into the least full group of their role, then any group with
  room. Members who don't fit stay in the pool.

## 60. The raid's groups, Invite & sort (built 2026-09-29)

Agreed with the user: the Upcoming view gets the group view; a raid made for a team adheres to the team's layout; the
leader invites from there in group order; a button re-sorts groups for late joiners. Defaults confirmed: late joiners
are sorted automatically while the run lasts (until the raid session ends), Re-sort is the manual fallback; Tentative
players go to the pool.

- **Layout members** (`RaidPlan:GetLayoutMembers`): Accept, Tentative and Bench sign-ups (Absent left out) plus anyone
  in the saved layout; the UI also lists people in my raid who didn't sign up ("In your raid, no sign-up"), so a late
  joiner can be placed. Non-accepted chips are dimmed.
- **Starting layout** (`RaidPlan:BuildLayout`, used while the raid has no saved layout, so it follows new sign-ups):
  accepted team members keep their team seat (first team first); seats of team members who didn't accept are open to
  accepted players of the same role (role from the team's spec / sign-up); other accepted players join a group whose
  players mostly share their role and has room; the rest stays in the pool. No team layout = Auto-fill of accepted.
  `RaidPlan:GetLayout` = the saved layout (E `grp`, via `SetGroups`) or the starting one.
- **Groups tab** (Upcoming detail, next to Sign-ups): organizers: Auto-fill, From team (back to the starting layout),
  Undo, Save; everyone: the grid read-only. Status line: starting / changed / saved layout, placed count, or the run's
  progress ("18/22 in the raid · 15 sorted · 3 offline (...)", "waiting for combat to end") with Stop.
- **Invite & sort** (`Core/RaidInvite.lua`; organizers, or whoever leads / assists my group): saves an organizer's
  unsaved layout first, then invites every placed player who is online and not in my group (a party or no group:
  at most 4 pending at a time; as soon as someone joined the party becomes a raid via `ConvertToRaid`), then sorts.
  Pressing it again re-invites the missing players.
- **Sorting:** planned players go to their group; unplanned players stay put when their group has room next to the
  planned ones heading there, else move to the free spots of the highest groups (8, 7, 6 ...). Moves use
  `SetRaidSubgroup` into a group with room, else `SwapRaidSubgroup` with someone who doesn't belong there; at most 8
  moves per pass, the next pass follows the roster update (and a 2 s fallback). Needs the raid leader or an assistant;
  nothing moves in combat (it resumes on `PLAYER_REGEN_ENABLED`).
- **The run** lasts until Stop, leaving the group, the raid session ending (Addendum I End raid), or 8 hours; late
  joiners are sorted as they join. Saving the layout during a run updates its plan. A /reload resumes it (sorting only).
  **Re-sort** runs one sort now (and keeps sorting late joiners).
- Mock (dev kit): `World.invite / convert_to_raid / set_raid_subgroup / swap_raid_subgroup`, explicit per-member
  subgroups, `World.auto_accept_invites`, `World.invite_log`, `World.subgroup_of(name)`.

## 61. (Step 5: raid log tie-ins; written when built.)
