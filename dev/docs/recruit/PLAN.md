# Recruitment — build plan (2026-10-15)

Guild > Recruitment: a tool for the GM and officers to keep track of the people they talk to, raiders for the teams as
much as people levelling or coming back, from the first whisper to settling in. Look and flow = the real-code mockup
v7 (https://claude.ai/artifact/CpyCBg6CyUSFv8xnMwiiTy, code `dev/art/casc/recruit_real`: `RecruitMock.lua`,
`patch_mock.py`, `recruit_states.py`). Status: **plan, waiting for approval.**

Ground rules from the user (2026-10-15): recruiting is personal (a conversation, fit over gear: no questionnaires,
scores, trial rank or vote); nobody outside the guild has the addon (applicants only ever see whispers, group invites
and guild invites); raiders and levellers alike, with the nights a raider can make matched to the teams' raid nights.

## Open questions, settled with the proposed answers
- **Friends list: automatic.** Adding someone to Recruitment adds them to *your* friends list (note "DZ recruit"),
  removed again when they join or go to Not now. A switch per officer in Settings turns it off.
- **Not now comes back after 3 months** as a reminder to whoever was talking with them (GM setting: 1 / 3 / 6 months
  / never).
- **Officers see all notes.** One shared card per person for everyone who works on recruits; no private notes.

## What gets built

**Recruitment > People** (listdetail, the guest book's layout). List: search (also adds by name), Talking / Joined /
Not now with counts, sections Unclaimed · Needs you · Talking and Check-in due · Milestones · Gone quiet, art rows
with the class, a date pill and an online dot. Person: page banner (kicker = who is talking / introduced by /
invited by, Online pill, spec · level · zone · tags, Whisper + ···, actions per step), the follow-up as a notice
strip, **What they're looking for** (wants: Raiding / Dungeons / Levelling / Social; spec + off spec; nights on the
Teams week strip + a time; their words), **Fits a team** (every team's core / optional nights against theirs + an
open place in that team's comp), **About**, and the **Story** (notes with author and date, newest first, plus runs,
guest raids, events and milestones the addon adds by itself). Joined people get **Settling in** (level then and now,
last online, dungeons, raids, events) and their team instead of Fits.

**Recruitment > Message**: blocks (guild tag, who we are, what we do, raid nights, classes we're after, your words,
Discord, /w us), classes from one team's open places (team not named; untick any), the Trade preview with the 255
limit, Post now + Post again (Trade, LookingForGroup, GuildRecruitment), officers take turns, and **Lately** (posts
this week, who whispered within 2 h of a post, who joined).

**Ways in**: "Add to Recruitment" in the guest book row menu and in the game's player menus (where "Guest book…"
is); Add someone (toolbar) by name; **Introduce a friend** for every member (Guild menu entry + member card ···).

**Actions**: I'll talk to him / Pass to (claim); Bring along (party invite, guest seat in a team raid via the guest
book's Add to a raid, Groups runs with room, ask a member to take them along); Ask how it went (one question to one
member who was there, the answer lands in the story); Not now; **Invite to the guild** (confirm: welcome line in
guild chat, the team's bench, tell that team's raid leaders, officer note, check-ins).

**Elsewhere**: Notify kind "recruit" (follow-up when they are online, new / unclaimed introduction, check-in,
milestone, gone quiet, left the guild; Home chip "n to talk to"); the raid leaders' ping at 70 for "Wants to raid";
"How she joined" link on a member card's officer note; Settings > Guild > Recruitment; Guild menu page + facts.

## Data

SavedVariables `db.recruit[guildKey]`:
```
p[key] = {                       -- one person (key = Name-Realm)
  c, sp,                         -- class file, spec index (ns.SPECS)
  st = "talk"|"joined"|"notnow"|"gone",
  w  = who is talking (key) | nil (unclaimed),  src = "whisper"|"guest"|"intro"|"name"|"trade",
  ib, it,                        -- introduced by (key), the introduction's line (<= 160)
  wa = bits                      -- wants: 1 raiding, 2 dungeons, 4 levelling, 8 social
  ni = { 4, 7 }, nt = "from 19:00"   -- nights they can raid (1 = Mon), a short time text (<= 24)
  sd = "their words" (<= 200), tg = { "Chill", ... } (tags from the GM's list, <= 4)
  fu = { at, t }                 -- the follow-up: day (epoch at realm noon) + what (<= 80)
  n  = { { by, at, t }, ... }    -- notes, newest first (<= 30, each <= 300)
  lv, la,                        -- level last seen, when (friends list / roster)
  ja, jl, jb, tm,                -- joined at, level at join, invited by, team id (bench)
  ck = { w = true, m = true },   -- check-ins done
  ms = { [58] = at, [70] = at, d = at, r = at },   -- milestones reached
  nn = at,                       -- Not now since (the comeback reminder)
  rev, by, at                    -- record revision, last writer, created
}
x[key] = { rev, by }             -- tombstones (removed people), kept 60 days
```
Story entries for runs / guest raids / events are **not stored**: they are read when the page draws from Groups runs
(`ns.DungeonRuns` history), the guest book (`GuestBook:GetEntry(key).raids`) and Events. Milestones are stored
(`ms`) because the roster only shows the present.

GM rules ride the guild leaders' record (`Guild` LeadersRec, the same `RLL` sync as attendance and loot rules):
`rec.rc = { wk = { gm, officer, leader }, intro, unc = days, ck = { 7, 30 }, ms = { 58, 70, d, r }, q = days,
nn = days, rl = bool, tags = { ... }, wl = welcome template, on = officer note template }`; `Guild:GetRecruitRules()` /
`SetRecruitRules(t)` (GM only), defaults in `Guild.RECRUIT_RULES`.

Per character (not synced): `db.recruitMine = { friends = true, added = { [key] = true } }` (only friends we added
are ever removed), the message draft and post times.

## Sync

Who is a **recruiter**: `Recruit:IsRecruiter(key)` = GM, or real officer rank (`Guild:IsOfficer(key, true)`), or a
listed raid leader when the rules say so. Nobody else ever receives records.

Modelled on `Core/OfficerNotes.lua` (whispers between recruiters only, never a channel):
- `RC  { k, r = record, v = rev }`        one person (sent to every online recruiter on change)
- `RCI { i = { [key] = rev }, r }`        my index on login (30 s) and when a recruiter comes online; the receiver
                                          sends what is newer and, unless `r`, its own RCI
- `RCX { k, v }`                          a removal (tombstone)
Newer `rev` wins; same rev: the larger digest wins (as polls). Records from a non-recruiter are dropped; a recruiter
who loses the rank stops getting them and their copy is purged on their own client (as BiS lists after a raid).

Member to recruiters:
- `RCN { k, c, t, at }`  Introduce a friend. Sent by whisper to every online recruiter; kept in
  `db.recruitIntro` on the member's client until one answers `RCNA { k }` (retried when a recruiter comes online,
  GUILD_ROSTER_UPDATE). The member gets a toast "Gina will get in touch" and, later, `RCJ { k }` when the friend joins.
- `RCQ { k, at, run }` Ask how it went (recruiter -> member, a Notify item with a one-line answer field);
  `RCW { k, at, t }` the answer back (to the asker, who folds it into the story as a note by the member).
- `RCT { k }` / `RCTA { k, yes }` Take them along (recruiter -> member, Sure / Not tonight).

Message turns: `RCP { at }` on GUILD when someone posts the recruitment message (a 20-byte line), so the next post
waits for whoever's turn it is; nothing else of recruitment ever goes over GUILD.

## Game APIs (unverified until in game)
- Friends: `C_FriendList.AddFriend(name, "DZ recruit")`, `RemoveFriend`, `GetFriendInfoByIndex` (connected, level,
  area), `FRIENDLIST_UPDATE`. Same faction only; the list's cap shows on People when full.
- Invite: `GuildInvite(name)` from the button click; the answers come as system messages (`ERR_GUILD_INVITE_S`,
  `ERR_ALREADY_IN_GUILD_S`, `ERR_GUILD_DECLINE_S`, `ERR_GUILD_PLAYER_NOT_FOUND_S`, `ERR_GUILD_JOIN_S`) read by a
  CHAT_MSG_SYSTEM handler (localised patterns built from the globals). Offline -> "Invite when online" (queued, sent on
  FRIENDLIST_UPDATE connected + the officer's next click: a toast with Invite, since the invite needs a click).
- Officer note: `GuildRosterSetOfficerNote(index, text)` when `CanEditOfficerNote()`; the addon's own officer note
  (`ns.OfficerNotes:Set`) as well.
- Welcome: `SendChatMessage(text, "GUILD")` after ERR_GUILD_JOIN_S for that name.
- Roster: `GetGuildRosterInfo` (level), `GetGuildRosterLastOnline` (quiet), join seen by the roster diff.
- Posting: channel posts need a hardware event: the Groups poster (`GroupsLFG` READY/POSTED) does the same here.

## Files

New
- `Core/Recruit.lua` — records, rules access, IsRecruiter, claim / pass / not now / invite flow, milestones and
  quiet checks (on GUILD_ROSTER_UPDATE, throttled), fit (`Fit(key, team)` from RaidNights + `RaidPlan:GetTeamOpenSlots`),
  friends list keeping, system-message parser, the sync above.
- `Core/RecruitIntro.lua` — the member side: Introduce a friend, the retry, Ask how it went / Take along answers
  (small, loaded for everyone).
- `UI/Recruit.lua` — the page (People + Message), from `RecruitMock.lua` with real data instead of `__mock`.
- `UI/RecruitDialogs.lua` — Introduce, Invite confirm, Pass to / Bring along menus, the answer prompt.
- `dev/tests/recruit/` — see Testing.

Changed
- `Core/GroupsLFG.lua` + `UI/GroupsMessage.lua` — the blocks / Compose / poster take a *source* (today: my group run;
  new: the recruitment message), so both pages share them. Groups' behaviour stays the same (its tests unchanged).
- `Core/Guild.lua` — `rc` on the leaders record, Get/SetRecruitRules, defaults.
- `UI/MainFrame.lua` — `recruit` in `grp:guild` after polls, page tip; `UI/NavMenu.lua` INFO + FACTS.
- `UI/GuestBook.lua` — "Add to Recruitment" in the row menu and `ModifyPlayerMenu`.
- `UI/Members.lua` — "How she joined" on the officer note (recruiters, when a record exists); ··· Introduce a friend.
- `UI/Settings.lua` — card `recruit` in Guild (`BuildRecruit`); per-officer friends switch in it.
- `UI/NotifySources.lua` — kind `recruit` + source (follow-ups gated on online, intros, unclaimed, check-ins,
  milestones, quiet, left, Not now comeback); kind `recruitAsk` for members (Ask how it went / Take along).
- `UI/Share.lua` — ref `recruit` (page) only; never a person (recruit data stays with recruiters).
- `Core/Demo.lua` — demo people (below); `UI/WelcomeTour.lua` — one officer step "Recruitment".
- `DisasterZone.toc`, `UI/Changelog.lua` (new section "Recruitment"), `dev/tools/ui_audit_states.py`.

Main-chunk locals: put helpers on a table (`H`) as in GuestBook; RaidPlan.lua is near the 200-locals limit and is
not touched.

## Demo mode
`Recruit:BuildDemo()` (cleared on DEMO_TOGGLED, nothing sent, as Polls): the mockup's eight people (Kaelthorn raider
who fits Main team, Aurelith leveller, Darkstalkerr guest with some nights, Thalric unclaimed introduction, Nortok
milestone 70, Bramble check-in due, Fennick gone quiet, Stabbystab Not now), the demo guild's teams for the fit, a
fake friends list (online states), a recruitment message with Lately numbers. Demo invite/introduce/ask show their
toasts and print what would be sent. In demo mode every member sees the page (as other features).

## Testing (dev/tests/recruit/, harness clients on one guild)
- `test_recruit_sync`: a record reaches online officers only; a member and a pug never get it; newer rev wins; RCI
  catch-up on login; removal tombstone; officer demoted -> purged locally, gets nothing new.
- `test_recruit_intro`: member introduces with no officer online -> kept, sent when Gina logs in, acked once;
  "joined" note back to the member.
- `test_recruit_fit`: nights vs core / optional nights, open place from a team comp, no nights, team without nights.
- `test_recruit_invite`: the system-message parser for every answer (incl. localised format strings from the mock),
  offline queue, already in a guild, declined -> back to Talking, join -> welcome line, officer note, bench, raid
  leaders notified, friend removed.
- `test_recruit_milestones`: roster level steps -> 58 / 70 once each; Wants to raid at 70 -> raid leaders' item;
  quiet after 14 days; left the guild; Not now comeback after the rule's days.
- `test_recruit_message`: shared blocks with Groups (Groups tests unchanged), 255 cut, classes from a team, RCP turns.
- `test_recruit_notify`: follow-up waits for online; chip grouping "n to talk to"; nothing for non-recruiters.
- ui_audit states: the mockup's 15 (`recruit_states.py` moved into `ui_audit_states.py` on demo data) + empty page,
  friends list full, invite waiting, introduce toast for the member. Rendered with `--look` and checked.
- `check.py` uniformity clean; selection runs during work, one broad run at the end.

## Order (each step usable on its own)
1. **Core + sync**: `Core/Recruit.lua` records, rules, IsRecruiter, RC/RCI/RCX, demo people; tests sync + fit.
2. **People page**: `UI/Recruit.lua` People view, ways in (guest book, player menus, Add someone), claim / pass /
   not now, notes, follow-ups; Guild menu + Settings card; ui_audit states.
3. **Friends + invite**: friends list keeping, online states, invite flow + system messages, welcome, officer note,
   bench, raid leaders; tests invite.
4. **Members' side**: Introduce a friend, Ask how it went, Take along; Notify kinds and Home chip; tests intro +
   notify.
5. **Settling in**: milestones, check-ins, quiet, left, Not now comeback, Settling in strip, "How she joined";
   tests milestones.
6. **Message**: GroupsLFG blocks split into a shared source, the Message view, turns, Lately; tests message.
7. Welcome tour step, Share ref, changelog, full release (new files and the toc: not hot-patchable).

## Unverified until in game
GuildInvite from an addon click on this client; the exact ERR_GUILD_* texts; C_FriendList on the Anniversary
client (cap, cross-realm names, area text); GuildRosterSetOfficerNote rights for officers who can't edit officer
notes in the guild's rank settings; the GuildRecruitment channel being joined only in cities.

## Out of scope (decided)
Applications, questionnaires, applicant forms or guild cards for outsiders, trial ranks, votes, gear / item level
scores, a raid-wide consumables check, meter numbers.
