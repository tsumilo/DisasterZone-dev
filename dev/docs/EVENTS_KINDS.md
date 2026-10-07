# Events, part 2: general building blocks (and the addon instead of chat)

## Why (the user, 2026-10-06)

After the first spec for more kinds of events (hide and seek, races, score chases, contests and quizzes) the user asked:
"are blocks really required in a fashion where we could utilize them for other things, or are they just specific for
this use case? It seems like most blocks are only usable for one certain thing most of the times" and "there's a lot of
raid messages / whispering / guild chatting going on, when we have an addon that could deliver most information in a
more intuitive way". I agreed: the core (when / if / repeat / variables / stages / timers) is general, but most event
pieces existed for one kind of event, and the first spec added ~60 more of those. The user said "Yes please" to:
**rebuild the pieces around a few general building blocks, and let the addon deliver the messages; part 1 (the duel
cup) is rebuilt on them too.** Nothing of part 2 is built; part 1 is unreleased (1.3.2), so changing it is cheap now.

Earlier answers that still hold (AskUserQuestion, 2026-10-06): all four kinds wanted; a hide-and-seek find is a click
(mouseover = target, so a `/target` macro never counts) within about 10 yards, `/point` up close as an alternative,
"targets without clicking" as its own piece for penalties, an optional "no friendly nameplates" piece; places set both
by standing there and on a map; hints both as subzone hints and hot / cold, as separate pieces ("alternatives as
different blocks").

## The idea in one line

An event is made of **players with tags**, **scores**, **places and lists**, **asks and buttons**, **things that happen**
and **matches**; the addon shows all of it itself (tracker, screen, board, prompts). Every piece below works in more
than one kind of event; the "Used by" column of the examples shows it.

## Definitions: what a builder names once and uses everywhere

Listed at the top of their palette category, each with "+ Add" and a small editor (name first). Stored in the def:

| Definition | Stored as | Fields |
|---|---|---|
| Tag (a group a player is in) | `tags[tid]` | `n` name, `c` colour key, `shown` = all / self / host (who sees who has it) |
| Score (a number per player) | `scores[sid]` | `n`, `high` (true: higher wins), `fmt` = num / time / gold, `board` (on the board and tracker), `cap` |
| Place | `places[pid]` | `n`, `map`, `x`, `y` (0..1), `r` yards, `z` / `sz` (zone / subzone when set by standing there) |
| List | `lists[lid]` | `n`, `kind` = text / place / question, `items` (texts, place ids, or `{ q, a = {answers}, pts }`) |
| Ask (a question the addon asks) | `asks[aid]` | `n`, `q` question (may be empty: the piece gives it), `kind` = player / choice / text / yesno / number, `choices`, `from` (for player: entrants or a tag), `votes` 1-3, `self` (may pick oneself), `time` s, `secret` (counts hidden until it closes) |
| Variable | `vars` (as part 1) | |
| Badge | `badges` (as part 1) | |

Built in: the score **Season points** (the season, capped per event as part 1), the tag **Entrants** (everyone in the
event). Timers and buttons are named where they're used (like part 1's timers).

## The pieces

Categories (palette order): Events, Stages, Logic, Players, Scores, Places, Ask, Messages, Timers, World, Smart. Colours:
the part 1 ones (Chat becomes Messages, Points becomes Scores), Places cyan-teal (f2 #0c6b78), Ask rose (f2 #a8486a).
Each category holds its own hats ("when ..."), so a builder finds a whole idea in one place; Events holds the general
ones. `gives` = what the piece hands to the pieces under it.

**Events**
- `ev.start` when this stage starts
- `ev.happen` when an entrant {what}: one hat, a choice of what happened (gives player + what that choice gives):
  wins a duel (other = the loser), loses a duel (other), kills a creature (creature), loots an item (item, count),
  catches a fish (item, count), dies, mounts, dismounts, starts moving, stops moving, goes offline, comes back, is
  ready, does an emote (emote, other = its target). A second blank filters when it makes sense ("kills {Hogger}",
  "loots {Fel Iron Ore}"; empty = any).
- `ev.timer` when timer {name} runs out · `ev.every` every {duration}

**Stages** (part 1): go to stage · go to the next stage · end the event · cancel the event: {reason}

**Logic** (part 1 plus lists and variables)
- if / if else / repeat {n} times / for each player in {players} / stop this script / and / or / not / > / < / = / is set /
  + / - / pick random {a} to {b}
- set {variable} to {value} (moved here from Points)
- lists: for each {item} in {list} (gives item) · item {n} of {list} · a random item of {list} · how many in {list}
- walking a list per player (routes, riddle chains, a quiz at one's own pace): move {player} on in {list} ·
  {player}'s item in {list} · {player}'s place in {list} · hat when someone reaches the end of {list} (gives player)
- {text} matches {answers} (yes / no: case and spaces don't count; answers = a question item's answers or "a / b / c")

**Players** (players and tags)
- values: the ones a hat gives, the host, every entrant, a random entrant, entrant #{n}, players with tag {tag},
  top {n} by {score}, how many in {players}
- yes / no: {player} is online · is ready · {player} is {player} · {player} is one of {players} · {player} has tag {tag}
- tag {players} as {tag} · untag {players} from {tag} · split {players} into {tags} (evenly, at random)
- hats: when one of {players} touches one of {players} (how: clicks up close / /points at up close / {emote} up close;
  gives toucher, touched) · when one of {players} targets one of {players} without clicking (gives who, whom) ·
  when someone gets tag {tag} (gives player) · when no one has tag {tag}

**Scores**
- add {n} to {player}'s {score} (n may be negative) · set {player}'s {score} to {n} · give {player} the badge {badge}
- values: {player}'s {score} · {player}'s place by {score} · the total {score} of {players} (team scores)
- hat: when someone's {score} reaches {n} (gives player)

**Places**
- hats: when an entrant enters {place} · when an entrant leaves {place} (gives player)
- {player} is in {place} · yards from {player} to {place or player} · the nearest of {players} to {player} ·
  {player}'s subzone · {player}'s zone · {player} is warmer or colder to {player} (text: warmer / colder / the same,
  since this piece last asked about that pair)
- point {players} to {place} (the tracker's arrow, until they're there or another point) · stop pointing {players}

**Ask** (asks and buttons)
- ask {players} {ask} · ask {players} {ask} with {text} (the question from a value: a quiz item) · close {ask}
- values: {player}'s answer to {ask} · the most picked answer to {ask} · how many picked {answer} in {ask}
- hats: when someone answers {ask} (gives player, answer) · when {ask} closes (time up or everyone answered)
- give {players} the button {label} · take the button {label} from {players} · hat when someone presses {label}
  (gives player). Buttons show in the tracker (Hint, Found it!, I'm ready, Next question).

**Messages** (the addon shows them; chat is the exception)
- show {players} {text}: a banner in the middle of their screen, in the event's look (part 1's "raid warning")
- tell {players} {text}: a line in their tracker and its feed (part 1's "whisper")
- add a moment: {text} (the board's feed and the results)
- play {sound} for {players}
- post in guild chat: {text}: for people outside the event (hype, the champion). Only the host's client sends it, at
  most once every 10 s and 20 times an event; the examples use it once (the winner).

**Timers** (part 1 plus): wait · start timer {d} named {name} · ... for {player} · stop timer · count down {n} for
{players} · seconds since {this stage started / timer name} · time left on timer {name} · show timer {name} on the board

**World**: {player} is mounted / flying / swimming / dead / in combat / moving · how many {item} {player} has ·
{player}'s gold gained · invite {players} to a group · mark {player} with {marker} · hide friendly nameplates for
{players} (put back when the event ends)

**Smart**
- **Sign-up** (part 1)
- **Matches** (part 1's Bracket, general): single elimination or round robin, best of, final best of, seeding, no-show,
  at once, bronze. New setting **won by** = a duel (as part 1) / the pieces (duels don't count; "award the match to
  {player}" decides it). So the same block runs duel cups, fishing duels, quiz duels, 1v1 races. Its pieces (part 1):
  when a match starts / game ends / match ends / final is set / is done, award the match to, take out of the matches,
  is still in, was seeded n below, and its own inside pieces.

Pieces that go: `ch.say` (-> post in guild chat for Guild, else show), `ch.wh` (-> tell), `ch.rw` (-> show), `ev.duel`,
`ev.off`, `ev.on`, `ev.ready` (-> `ev.happen` choices), `pt.*` (-> Scores, the variable piece -> Logic), the Bracket's
name. `EventBlocks:Migrate(def)` rewrites old keys when an event is loaded or received (the user's test events, the
demo data, other members' copies).

## What the addon shows by itself (no pieces needed)

- **Tracker**: the event and stage, my tags (if shown to me), my scores with my place (scores with `board`), my match
  (Matches), the arrow and yards to a pointed place, my buttons, my open ask, the last "tell" lines.
- **Board**: views from what the event has: Matches -> the bracket; scores with `board` -> leaderboards (tabs when more
  than one); tags -> a column a tag (when there are no matches); places -> the map (the places, never where players
  are unless a piece points them out); a list walked per player -> progress bars (a race); shown timers -> time left;
  moments; an ask's result once it closes.
- **Results**: the scores' tables, the matches, moments, badges.
- **Prompts**: an ask opens a card for the asked players (pick a player with their class circle and an Inspect button,
  pick a choice, type, yes / no, 1-10), with its time ring; closes by itself.
- The match card (part 1) already says "you're up vs X": the starter's whisper goes.

## Examples ("Start from")

The empty stage's "Start from the Friday duel cup" becomes "Start from" a short list. Each one teaches the blocks:

| Example | Built from | Used by others too |
|---|---|---|
| Friday duel cup | Sign-up, Matches (won by a duel), moments, Season points, one guild chat post | Matches, show, moment |
| Hide and seek in Nagrand | tags Hiders / Seekers / Found, "a Seeker touches a Hider" -> tag Found, place Play area + "leaves", button Hint -> tell a Hider's subzone, timer | tags, touch, places, buttons, tell |
| Infection | the same, but the touched player is tagged Seeker; "when no one has tag Hiders" | tags, touch |
| Mount race | list Route of places walked per player, score Time (low wins), point to the next place, "dismounts" -> take out | lists, places, scores, point |
| Fishing derby | "catches a fish" -> add 1 to Fish, a 30 min timer shown, top 3 by Fish get badges | happen, scores, timers |
| Transmog contest | for each entrant: show everyone the player, ask Judges "Score 1-10" -> add to Votes; top 3 by Votes | asks, scores, show |
| Trivia night | list Questions; for each item: ask everyone with its question, "answer matches" -> add 1 to Right | lists, asks, matches-text, scores |
| Red light, green light | variable Light flipped by a timer, show Red light!, "starts moving" while red -> tag Out | happen, tags, variables |

## Data and wire

- Run state adds `tags = { [tid] = { [key] = true } }`, `scores = { [sid] = { [key] = n } }` (Season points stay in
  `stats` as part 1), `lists = { [lid] = { [key] = index } }`, `asks = { [aid] = { open, to, at, ans = { [key] = v } } }`
  (part 1's dispute asks stay as they are), `buttons = { [label] = { keys } }`, `point = { [key] = pid }`,
  `pos = { [key] = { map, x, y, z, sz, at } }` (host only; never broadcast).
- Facts from entrants to the host (EVF `k`): `h` (what, other, item, count, creature, emote), `place` (pid, in),
  `touch` (whom, how, near), `radar` (whom), `ans` (aid, value), `press` (label), `pos` (only while the def uses a
  distance / nearest / warmer piece: every 5 s or after 20 yd). Server time `at` on each; at most 4 a second; the host
  drops facts from non-entrants and facts the def doesn't use. Clients only sense what the running def uses.
- The senses and their APIs, all checked against addons installed on this client (Questie, RXPGuides): `C_Map.GetBestMapForUnit` / `GetPlayerMapPosition` / `GetWorldPosFromMapPos` /
  `GetMapArtLayers` / `GetMapArtLayerTextures` / `GetMapChildrenInfo`, `GetPlayerFacing`, `CheckInteractDistance(unit, 3)`,
  `UnitIsUnit("mouseover", "target")`, `CHAT_MSG_TEXT_EMOTE`, `COMBAT_LOG_EVENT_UNFILTERED` `PARTY_KILL`,
  `CHAT_MSG_LOOT`, `LOOT_OPENED` + `IsFishingLoot`, `PLAYER_DEAD`, `GetUnitSpeed`, `IsMounted`, `IsFlying`, `IsSwimming`,
  `GetItemCount`, `GetMoney`, `SetCVar("nameplateShowFriends")`. Places work in the open world, not in instances.

## Interfaces between the parts (the contract the build agents share)

Value types for blanks (EventBlocks `args[i].t`): part 1's plus `tag`, `score`, `place` (a pid or a player for "yards
from"), `list`, `ask`, `label` (a button's label, typed), `what` (the happen choice), `how` (the touch choice), `sound`,
`item` (an item id or name), `creature` (a name), `emote` (an emote token). Definition blanks show a dropdown of the
event's definitions plus "+ New ...".

**EventBlocks (Core/EventBlocks.lua)**
- `B.CATS` (11 categories as above), `B.PIECES`, `B.PALETTE[cat]`, definitions: `B:Defs(d, kind)` -> sorted
  `{ {id, ...} }` for kind = tags / scores / places / lists / asks; `B:NewDefinition(d, kind, fields)` -> id;
  `B:DefinitionName(d, kind, id)`.
- `B.HAPPEN` = ordered `{ key, label, gives = {...}, filter = t }` (wins a duel, loses a duel, kills a creature, loots an
  item, catches a fish, dies, mounts, dismounts, starts moving, stops moving, goes offline, comes back, is ready, does an
  emote); `B.TOUCH` = { click, point, emote }; `B.SOUNDS`.
- `B:Migrate(d)` (old keys -> new, in place; idempotent), `B:Senses(d)` -> `{ happen = { [what] = true }, places = {
  [pid] = true }, touch = { [how] = true }, radar = bool, pos = bool, asks = bool, buttons = bool }` (what an entrant's
  client must watch), `B:Examples()` -> `{ {key, name, icon, art, desc, def} }` (the 8), `B:Starter()` = the rebuilt
  duel cup (= `Examples()[1].def`).
- `Problems`, `Describe`, `Diff`, `Kinds`, `MaxSeasonGrant` know the new pieces and definitions.

**EventEngine (Core/EventEngine.lua)**: new run inputs (all no-ops unless the run is live and the key an entrant):
- `run:Happen(key, what, data)` (data: `other`, `item`, `name`, `count`, `creature`, `emote`); part 1's `run:Duel(w, l)`
  also fires `wins a duel` / `loses a duel`; `SetOnline` / `SetReady` fire `goes offline` / `comes back` / `is ready`.
- `run:Place(key, pid, inside)`, `run:Touch(who, whom, how)`, `run:Radar(who, whom)`, `run:Pos(key, pos)`,
  `run:AskAnswer(aid, key, value)`, `run:Press(key, label)`.
- State (in `run.st`, synced by EVS except `pos`): `tags[tid][key] = true`, `scores[sid][key] = n`, `lists[lid][key] = i`,
  `qa[aid] = { open, who = { [key] = true }, q, at, ends, ans = { [key] = v } }`, `buttons[label] = { [key] = true }`,
  `point[key] = pid`, `pos[key]` (host only), `shown[timer] = true`.
- New `out` adapter calls (EventLive and practice implement them): `out.show(keys, text)`, `out.tell(keys, text)`,
  `out.sound(keys, sound)`, `out.guild(text)`, `out.plates(keys, off)`. Asks, buttons and points are state (the UI
  reads them); `out.changed()` as part 1.
- Matches setting `win` = "duel" | "pieces" (with "pieces", `Duel` doesn't count for matches).

**Settled by the mockups (sections 17-25, 2026-10-06)**
- Score stacks read for one player or many (part 1's form): "add {n} {score} to {players}", "set {score} of
  {players} to {value}"; the value stays "{player}'s {score}" (one player). (The mockups' "add 1 to toucher's Finds"
  breaks with "both players": the "players's" problem.)
- New general hat: "when the lead in {score} changes" (gives player: the new leader). Score chases, races.
- Matches gives: "is done" -> champion, second, third; "final is set" -> player 1, player 2.
- A tag in a players blank is the value "players with tag {tag}", drawn as the tag's chip (colour dot + name).
- The touch hat's "how" is a dropdown at its end ("... touches one of {Hiders} by a click").
- Pieces longer than the palette column (about 185 px) take two lines in the palette, one on the canvas.
- The tracker also shows a walked list's progress ("Route 3 of 8" + a bar); a pointed place draws its ring on the
  minimap; "tell" lines newest first.
- Definition editors are popovers next to their palette row (name first, "N pieces use it", bin, Save); the
  Questions list opens as a wide sheet.

**EventLive (Core/EventLive.lua) + EventSensors (Core/EventSensors.lua, new)**
- Sensors run on an entrant's client while one of their events is live (`B:Senses` of its def) and send facts with
  `Live:SendFact(occ, fact)` (EVF to the host). The host's `OnFact` calls the run inputs above.
- The host delivers `show` / `tell` / `sound` / `plates` to the players named with a new message **EVM**
  `{ occ, to = keys | "all", k = show | tell | sound | plates, text, at }` (GUILD when "all", else whispers; at most 4 a
  second); `guild` goes through the chat queue (rate: once / 10 s, 20 an event, never in demo or practice).
- Messages for the UI (ns:Fire): `EVENT_SHOW (occ, text)`, `EVENT_TELL (occ, text)`, `EVENT_SOUND (occ, sound)`
  (to me only), plus part 1's `EVENT_LIVE_UPDATED`. Practice fires them locally for "me" and logs every message.
- `Live:Press(occ, label)`, `Live:AnswerAsk2(occ, aid, value)` (my answer to an ask), `Live:MyAsks(occ)` -> open asks
  for me, `Live:MyButtons(occ)`, `Live:MyTags(occ)`, `Live:MyScores(occ)` -> `{ {sid, n, place} }`, `Live:MyPoint(occ)`
  -> pid, yards, bearing (radians) for the tracker's arrow.
- Practice: `PracticeHappen(key, what, data)`, `PracticePlace(key, pid, in)`, `PracticeTouch(who, whom, how)`,
  `PracticeAnswer(key, aid, value)`, `PracticePress(key, label)`; dummies answer asks after a few seconds by themselves.
- Events.lua's `CleanDef` keeps the new definitions (tags, scores, places, lists, asks) with their limits (names 24,
  question 120, answers 6 x 40, items 40 a list, places 24 an event).

**Settled by the live build (EventSensors / EventLive / Events, 2026-10-07; the gaps the contract left)**
- `B.HAPPEN` keys: `duel` ("wins a duel"), `lose`, `kill`, `loot`, `fish`, `die`, `mount`, `dismount`, `move`, `stop`,
  `off`, `on`, `ready`, `emote`. An entrant's client senses only `kill loot fish die mount dismount move stop emote`
  (`EventSensors.SENSED`); the host refuses an `h` fact for any other `what` (a client can't claim a duel win,
  readiness or presence: duels stay with the duel reports, off / on / ready with SetOnline / SetReady). Practice's
  "Make something happen" (`PracticeHappen`) may pass any of the 14.
- EVF facts (each carries `at`, the sender's server time): `h { what, other, item (id), name (item name), count,
  creature, emote (token, e.g. "POINT") }`, `place { pid, in }`, `touch { whom, how, near, emote }`, `radar { whom }`,
  `pos { map, x, y, cont, wx, wy, z, sz, fl, sw, cb, mt, mv, dd, items = { [item] = n }, gold }` (any of them: what
  changed), `ans { aid, v }`, `press { label }`, and `b { f = { fact ... } }` (the facts of one moment together, 8 at
  most, each counted). A fishing catch is also an item looted (`fish` and `loot` both, when the def senses both).
- Rates: a client sends its facts a frame after they happen (one message for those of one moment), 6 messages at once
  and then 1 a second (an addon prefix carries about that: 10 at once, then 1 a second), at most 24 waiting (a newer
  `pos` joins the waiting one). The host takes 16 facts at once from an entrant, then 4 a second, from entrants only,
  for what the def uses (`B:Senses`), WHISPER only.
- `pos` parts by the def's senses: the position (map, x, y and the world cont, wx, wy) only while it uses distances
  (`pos`): every 5 s when I moved 2 yd, after 20 yd (2.5 s apart at least), every 30 s anyway; zone / subzone for
  `zone` (or with a position); all six flags for `flags`; `mt` / `mv` / `dd` once for a def whose happenings keep them
  (mount, move, die); item counts every 2 s for `items`, gold gained (copper since the event began for me, kept in
  `db.eventMoney` across a /reload) for `gold`. Each part when it changes, and all of it again for a new host (a
  takeover or handover: those parts are host-only and never in a state). The host strips what the def doesn't use.
- Places: a client sends a place's change (in / out, 2 yd of slack before "out"), `in` for the places it is in as
  sensing starts (never a first `out`), and those `in` again to a new host. Inside = within `r` yards (default 30) of
  `map/x/y` in world yards (`EventSensors.World`, an affine map -> world fit from three C_Map points), or, for a place
  without coordinates, the subzone `sz` (else the zone `z`). Entering an instance sends `out` for every place it was in;
  places and positions stay off there.
- Touches: a click = the target changed while the mouse was over them in the world (not on a unit frame: a raid frame
  click is radar), or the mouse went down (GLOBAL_MOUSE_DOWN) over the player who is my target already; near =
  `CheckInteractDistance(unit, 3)`. Emotes: the token from hooking `DoEmote` (and `C_ChatInfo.PerformEmote` where it
  exists; its target: a name as typed, first letter made capital, else my target), confirmed by its CHAT_MSG_TEXT_EMOTE
  echo; without the hook, English "You <verb> at <name>." Only near
  touches reach the run: `run:Touch(who, whom, how, emote)` (a /point is how = "point", and how = "emote" with "POINT"
  too). The same touch again within 2 s, or radar on the same player within 5 s, is one.
- EVM on the wire: `{ t = "EVM", o = occId, to = "all" | {keys} | nil, k = "show" | "tell" | "sound" | "plates", text,
  off, at }`: GUILD for every entrant online (`to = "all"`) or for 4+ players (`to` = their keys), else a whisper each
  (`to` = nil: the receiver), 4 a second at most (it shares the event prefix with the states: a line can take a few
  seconds while a big state goes out). Taken only from the host the receiver knows; one that comes before the state
  naming its sender (a run's first messages, a takeover's) waits 10 s for it. `show` and `sound` older than 20 s are
  dropped. `sound` = a `B.SOUNDS` key: the receiving client plays it (SOUNDKIT, else the fallback id), then fires
  `EVENT_SOUND` (the UI doesn't play it again). `plates`: `off = true` hides friendly nameplates (the CVar
  `nameplateShowFriends`, its old value in `db.eventPlates`), `false` puts them back; while hidden they're hidden again
  if the player turns them on; back by themselves when the event ends or I'm not in it, at logout (hidden again after a
  /reload while it runs), and at the next login if a crash left them hidden; never changed in combat (at its end).
- Guild posts: the host's client only, one every 10 s, 20 an event (`st.gpost = { n, at }` in the state, so a host who
  takes over goes on counting; the engine counts `st.gp` too), 3 waiting at most (past that the oldest waiting one goes),
  never in demo mode or practice. Part 1's say / whisper adapters are gone: the engine has no chat but this.
- Me-API: `MyAsks(occ)` -> `{ {id, n, q, kind, choices, players (kind player: who may be picked), votes, self, secret,
  ends, at, seq, answered, mine} }` (the open asks put to me, oldest first; `answered` once I answered, `mine` my answer);
  `AnswerAsk2(occ, aid, v)` refuses (false) an answer the run wouldn't take (the engine's CheckAnswer: myself without
  `self`, a choice it hasn't, 11 ...) and a second one; v = a key (or up to `votes` keys), a choice's text, text (120
  bytes), true / false, a number 1-10. `MyButtons(occ)` -> labels (sorted); `Press(occ, label)` false for a button I
  haven't. `MyTags(occ)` -> `{ {id, n, c, shown} }` (mine shown to me: all / self; the host also sees its "host" ones).
  `MyScores(occ)` -> `{ {sid, n, place, name, fmt, high, board} }` (every score of the def in `B:Defs` order; `place` as
  the run ranks them, among who has the score, ties alike, nil without one; `n` 0 for a higher-wins score I have none
  of). `MyPoint(occ)` -> `pid, yards, bearing` (relative to where I face, counterclockwise: 0 ahead, pi/2 to my left;
  just pid where positions are unknown, e.g. instances). `MyFeed(occ)` -> `{ {at, text} }` (the tell lines to me, newest
  first, 20). `MyLiveEvents()` -> `{ [occId] = state }` (the live events I'm an entrant of). Distances for the UI:
  `ns.EventSensors.Yards(a, b)`, `.Bearing(a, b)` (0 = north, counterclockwise), `.World(map, x, y)`, `:MyPos()`,
  `.Facing()`; `PlatesHidden()`.
- Practice: `PracticeHappen / PracticePlace / PracticeTouch(who, whom, how, emote) / PracticeRadar / PracticePos /
  PracticeAnswer / PracticePress`; dummies answer every ask put to them 2-6 s later (faster at a higher speed): a
  player they may pick (votes: as many), a choice, yes or no, 1-10, a quiz question's first answer 6 times in 10. The
  run logs every message itself (EVENT_PRACTICE_LOG); a message for me also fires EVENT_SHOW / TELL / SOUND for
  "practice"; nothing changes in my game (no nameplates) and nothing is sent.
- CleanDef keeps the definitions: names 24; a question 120; choices and answers 6 of 40; tags / scores / lists / asks
  `LIMITS.defs` (24) each, places 24; list items 40 a list and 80 in all the event's lists (`LIMITS.allItems`, else
  `Events.ALL_ITEMS`: the editors should stop there, `B:NewDefinition` doesn't count items); tag colours / shown, score
  fmt, list kind, ask kind checked against EventBlocks' lists. A def with every definition at its limit (realistic
  words, the starter's pieces besides) is about 13 KB on the wire (the cap is 21.6 KB); all of it random letters is too
  big: SaveDef refuses it and says so. Such a def takes ~50 s to reach every member (one part a second).
- `B:Migrate` runs on every def that comes in: at the end of CleanDef (so every received D / O record, and RankedNow's
  hash, see a migrated def), once at login on every stored one (`Events:MigrateStored`: D, O copies, a reviewer's
  ranked snapshots, every guild), on demo mode's defs, and in E:Restore.
- Results (R) also keep `scores = { {id, n, high, fmt, v = { [key] = n }} }` (8 at most, the board's first, then the
  others; B:Defs order) and `tags = { {id, n, c, shown, k = { keys }} }` (8), 40 players each; a result too big for one
  message drops tags, then the last scores. Both only when the event had them (older records hash as they did).
- Demo data: the library's "Hide and seek in Shattrath" (mine, in review) is the hide and seek example in Shattrath;
  the calendar has a fishing derby (odemo4, 2 days, 9 sign-ups) and a trivia night (odemo5); `rdemo3` is last week's
  derby with its Fish table.

**Settled by the core build (EventBlocks / EventEngine, 2026-10-07; what the UI builds on)**
- Category keys: `ev sg lo pl pt pc as ch tm wo sm` (as the mockups: `pt` is Scores, `ch` Messages, `pc` Places, `as`
  Ask). `B.CAT_DEFS = { pl = "tags", pt = "scores", pc = "places", lo = "lists", as = "asks" }`: the definitions a
  category lists above its pieces (variables stay in Logic). Smart block kind `bracket` keeps its key; its label is
  "Matches", its new setting `win` = "duel" | "pieces" (Won by: A duel / The pieces).
- Piece keys kept where the words and blanks didn't change (no migration needed): `pt.add` "add {n} {score} to
  {players}", `pt.set` "set {score} of {players} to {n}", `pt.get` "{player}'s {score}", `pt.badge` (args badge,
  players: "give {players} the badge {badge}" - the words may put blanks in any order), `ch.moment`, `pl.top` (its
  blank 2 is a `score` now). Season points is the score id `B.SEASON` ("Season points"), the tag Entrants the id
  `B.ENTRANTS` ("entrants"); both built in (`B.BUILTIN`), never stored in a def.
- New keys: Events `ev.happen` (blank 1 `what`, blank 2 `filter`); Logic `lo.vset` (was `pt.vset`), lists `lo.lfor
  lo.litem lo.lrand lo.lcount lo.lnext lo.lmine lo.lpos lo.lend`, `lo.match`; Players `pl.tagged pl.howmany pl.has pl.tag
  pl.untag pl.split pl.touch pl.radar pl.gettag pl.notag`; Scores `pt.place pt.total pt.reach pt.lead`; Places `pc.enter
  pc.leave pc.in pc.yards pc.near pc.sub pc.zone pc.warm pc.point pc.unpoint`; Ask `as.ask as.askq as.close as.answer
  as.top as.count as.on as.closed as.give as.take as.press`; Messages `ch.show ch.tell ch.sound ch.guild`; Timers
  `tm.since tm.show`; World `wo.is wo.items wo.gold wo.plates`. Kept, off the palette (`hide`): `pl.count`, `wo.zone`
  (part 1's roster zone check). Gone (Migrate turns them into the new ones): `ch.say ch.wh ch.rw ev.duel ev.off ev.on
  ev.ready pt.vset`.
- Value types added to the list above: `where` (a place or a player: "yards from", "warmer or colder"; `place` itself
  takes places only: "point to", "is in"), `state` (World's mounted / flying / swimming / dead / in combat / moving,
  `B.STATES`), `since` ("stage" or a timer's name), `filter` (a second blank whose type is its choice's: `B:ArgType(p,
  i)` -> "creature" / "item" / "emote" or nil = not shown; `B.HAPPEN[i].filter`, `B.TOUCH[i].filter`). A blank with
  `opt = true` may stay empty, meaning any (the place of "enters" / "leaves", the players of "touches" / "targets",
  every filter). `B:Fits(t, "any")` is true for any blank but yes / no (variables, answers, list items fit anywhere);
  `B:TakesPieces` adds `place` and `where`.
- What a hat gives: `B:Gives(p)` (use it, not `PIECES[k].gives`: "happen" gives by its choice). New CTX names: `other,
  creature, item, count, emote, toucher, touched, who, whom, place`; `answer` is of type any; `runnerup` reads
  "second"; "final is set" gives `player1, player2, both` (part 1's finalist1 / 2 are migrated). A list item is a text,
  a place's id, or a question `{ ql = list id, qi = n, q = its words, pts }` (never its answers): as text it reads as
  its words, as a number its points, in "matches" its answers.
- Definitions API: `B:Defs(d, kind [, own])` (built-in ones first, flagged `builtin`, unless `own`; then the event's
  by name), `B:Definition(d, kind, id)`, `B:DefinitionName`, `B:NewDefinition(d, kind, fields)` -> "tg1", "sc1", "pc1",
  "ls1", "ak1" (defaults: tag c blue / shown all; score high, fmt num, board; place r 30; list kind text; ask kind
  player, from entrants, votes 1, self false, time 60, secret false; nil past 24 a kind), `B:RemoveDefinition`,
  `B:DefinitionUses(d, kind, id)` ("N pieces use it"), `B:FormatScore(d, sid, n)` (time m:ss, gold 1g 20s, number),
  `B.TAG_COLORS` / `B:TagColor(c)`, `B.TAG_SHOWN`, `B.SCORE_FMT`, `B.ASK_KINDS`, `B.LIST_KINDS`, `B.EMOTES`,
  `B.SOUNDS = { {key, words, SOUNDKIT name, fallback id} }`, `B.LIMITS`, `B:Labels(d)` (the button labels used),
  `B:Words(d, p)` / `B:BlankWords(d, p, i)` (a piece's words with its picked blanks filled in).
- `B:Kinds(d)` is part 1's (smart block kinds); `B:Kinds(d, true)` adds the definitions it has ("tags", "scores",
  "places", "lists", "asks"), named by `B:KindLabel(k)` (so the current library chips, which read `SMART[k].label`, keep
  working until the UI moves to KindLabel).
- `B:Senses(d)` also has `zone` (zone / subzone pieces), `flags` (flying / swimming / in combat / dead), `items = {
  [item] = true }` (`wo.items`), `gold` (`wo.gold`); "happen" there never lists duel / lose / off / on / ready.
- `B:Migrate(d)` returns true when it changed something; it also turns part 1's stat names into score definitions
  (by name; "Season points" stays) and renames a migrated hat's values (a duel's winner / loser -> player / other).
  EventBlocks' checks (Problems, Describe, Diff, Kinds, MaxSeasonGrant, Senses) call it on what they're given, so a def
  with nothing old is never touched; stored records should be migrated when they enter (CleanDef) and once at load, so
  every client hashes the same.
- `B:Examples()` -> the 8 in the "Start from" order (duel, hide, infect, race, fish, tmog, quiz, redlight); `B:Example(key)`
  -> one def. The race and red light keep their sign-up open until the host closes it (players gather at the start,
  pointed there); the others close it when the event starts.
- Run inputs: `Touch` / `Radar` take `whom` = an entrant or the host; `Pos` keeps `cont, wx, wy` when sent and merges a
  fact that carries only some fields; `AskAnswer(aid, key, v)`: the asked players only (the host too when asked), one
  answer each (the first stands), a choice in any case, text up to 120 bytes, a number 1 to 10 (whole), votes > 1 kept as
  a players list `{ list = true, ... }`. Answer and close hats run before the script that asked goes on.
- Run helpers for the live layer: `run:Snapshot()` leaves out the host-only parts (`pos, inplace, warm, flags`) and a
  secret open ask's answers (shown as `true`); `run:Snapshot(true)` is all of it (the host's own /reload save);
  `run:Shift(sec)` after a pause (timers, waits, "every", asks' ends, "seconds since"); `E:Reader(def, st)` reads a
  snapshot (GetScore, PlaceBy, Ranked, Tagged ...) without running it; `E:TagsOf / ScoresOf / AsksFor / ButtonsOf /
  PointOf`. Optional `out.asked(aid, qa)` when an ask opens (practice dummies). State also has `inplace[pid][key]`,
  `warm`, `flags[key]` (host only), `plates[key]` (put back at the end: `out.plates(keys, false)`), `tstart[timer]`,
  `stageAt`, `lead[sid]`, `qaSeq`, `gp` (the engine's own count: at most 20 guild posts a run, none sent in practice).
- `run:Result()` also gives `scores`, `tags`, and, for an event with no Matches block, its placings from the first
  score on the board (by name; `res.by` = that score). `pl.top` and every ranking count only who has the score.
- Distances: the engine uses `ns.EventSensors.World` (the same map -> world as the clients) and E:New's
  `opts.worldPos(map, x, y)` in tests; "yards from" reads 9999 when a position isn't known.

**Settled by the board / tracker build (UI/EventBoard.lua, UI/EventTracker.lua, UI/EventWidgets.lua, 2026-10-07)**
- Two small engine additions (state, synced like the rest; seconds since the run began, `t0`): `st.lt[lid][key][i]` =
  when a player passed item i of a list (Run:ListNext: the race board's splits, its gaps to the leader there, the
  racers' dots on their leg), and `st.last[key] = { w = fish | loot | kill, i = item id, n = item / creature name,
  at }` (Run:Happen: the leaderboard's "Last catch"). Both in STATE_TABLES (Restore keeps only tables there).
- The board's layout per event (`EventBoard:Views(def, st)` -> `{ layout, tags, scores, main, places, walked, list,
  signup }`): Matches -> part 1's bracket; a list walked per player (lo.lnext / lmine / lpos / lend) -> "race" (a
  progress table: #, player, the list's segments, the first board score, the gap; my splits under my row; a places
  list adds the route's map); two tags or more (or one and no score) -> "columns" (a column a tag in the order the
  event made them, the board score most of a column's players have next to the names; the places map above when the
  event has places); board scores -> "scores" (a leaderboard, tabs for several; "Last catch" when the def senses
  fish / loot / kills, else a bar and the player's tag); a sign-up still open -> who signed up (the map stays). The
  rail: asking now (the newest open ask, answered n of m), time left on the shown timers (what ends when, "then
  <stage>" from that timer's script), prizes (from the pieces giving each badge: 1st / 2nd / 3rd for one score's
  podium, else "most Finds", "longest Hidden"), the last ask's result (a quiz question's right answers green),
  moments. The header chip: my match (part 1), else my place ("You're 3rd") in a race / score chase, else my tag
  ("You: Hiders").
- Shared widgets (EventWidgets, for the builder's map sheet too): `EUI:CreateZoneMap(parent, w, h)` (C_Map art layer
  tiles, `SetMap / Fit / SetView / P / Px / Place(i, x, y, yd, name, look) / Done(n)`; a dark grid where a map has no
  art), `EUI:CreateCircle(parent)` (`Set(r, { stroke, width, shadow, fill, dot, clip = { x, y, R } })`: lines, any
  size, clipped to a circle for the minimap), `CreateChip`, `CreateSegments`, `CreateTimeLeft`, `CreateMedal`,
  `Narrow(fs, size)`, `ItemIcon`, `Ago`.
- Demo mode: `EventBoard:OpenDemo("kdemo-hide" | "kdemo-race" | "kdemo-fish")` (also in the board's More menu, "Other
  boards"): the examples run by the engine here with no output adapters at all (nothing is sent), with me in them;
  the tracker shows the demo board last opened.
- Prompts: `EventTracker:AnswerAsk2(occ, aid, v)` / `:Press(occ, label)` (the practice run's own inputs for the
  builder's practice, where I'm its host); three ask cards at most, two results (in the order the asks closed, a
  minute at most); cards stack in one column, or two side by side when they don't fit.
- EVENT_SOUND: EventLive plays the sound; the UI adds nothing (no second play).
- A state from another client is only read: `EventBoard.H.Clean(st)` (in `EventBoard:StateOf`, which the tracker
  uses too) makes every part 2 field of the wrong shape read as empty, once a state change.
- Tools: the mock's C_Map has the open world zones' art layers (the client's world map tiles by path, so a render
  draws the real map); ui_look draws Line regions and texture rotation; ui_audit states "Events - board hide and
  seek / race / fishing derby / sign-up with places", "Events - tracker hide and seek / race / fishing derby",
  "Events - ask prompts / ask result / banner and yes or no"; tests in tests/events/test_kinds_board.py.

**Settled by the Events tab build (UI/EventsTab.lua, 2026-10-07)**
- `B:DescribeStage` (so `B:Describe`) rules also name what they are about, for the event page's chips (the texts and
  the stage words are unchanged): the tags rule has `tags = { tid ... }` (the page draws a chip per tag in its
  colour), a score's `score = sid`, a place's `place = pid`, a walked list's `list = lid`, an ask's `ask = aid`, a
  button's `button = label`. Matches add one rule: "won by a duel" / "won by the event's rules" (`win = "duel" |
  "pieces"`).
- The page and the review also describe what runs the whole event: `B:DescribeStage(d, { id = "*", name = "Always" })`
  (an Always row when it has rules or words). After a place or a route of places the page adds "open world only".
- Rewards (page, results, review) are read from the pieces stack by stack: a badge's season points are the "add n
  Season points" of the same stack to the same players; where it goes: Matches' champion / second / third, "if each
  player's place by S = n" inside a "for each player", "top 1 by S", a variable's name; badges placed by more than
  one score say which ("most Finds", "2nd by Hidden"). Season points no badge goes with: a match won (`bk.end`'s
  winner), playing (for each entrant); the rest by where they go.
- Results without Matches: placings are the record's champ / second / third (the run's Result), else the first board
  score's table ranked (ties share a place); a podium line is the player's score ("31 Fish", "Time 4:37"). With no
  badges and several board scores, the awards are each score's leader ("Most Finds", "Longest Hidden").
- "Examples" (the Library's, and Upcoming's beside New event) opens the builder on `Events:CopyDef(B:Example(key))`: a
  new event of mine, kept only when the builder saves it.

**Settled by the builder build (UI/EventBuilder.lua, UI/EventPieces.lua, 2026-10-07)**
- Palette: each category's definitions first in the order they were made (the built-in Entrants last, Season points
  first), "+ Add ..." (Places: a menu, Set from where I stand / Pick on the map), then "Pieces" (Logic: Lists,
  Variables, Pieces; Messages: Messages, For the guild). A tag's row drags onto the canvas as "players with tag ...".
  A piece wider than the column (184) is drawn in lines there (`EP:Draw(..., { wrap = w })`: breaks between words, a
  line never starts with a lone blank nor ends on "an" / "of"); on the canvas always one line.
- Blanks: an empty one says what it takes ("player", "tag", "place"); a tag or a place picked is its chip, and so is
  "players with tag X"; a click on a value in a blank opens that blank's picker. A choice's second blank (`filter`) is
  drawn only when it holds something ("kills [Hogger]"); empty, the choice says it ("kills a creature"); it's set from
  the choice's menu (a submenu: any, one by name..., or the emotes). Places / where open a picker (the event's places,
  the script's place values, players for where, Set from where I stand, Pick on the map); label / item / creature are
  typed (label offers the event's buttons; an item shift-clicked goes in as its id).
- Editors: a popover by its palette row (tags, scores, asks, lists; a working copy, Save = one undo step; the name is
  unique per kind); places edit in the map sheet; a list of questions in the questions sheet (Done keeps it). Deleting
  what pieces use asks first ("N pieces use it"); a place deleted leaves the lists of places, a tag an ask picked from
  goes back to the entrants. Someone else's event: the editors open to read, every change says why not.
- Start from: a new event's empty stage shows `B:Examples()` as cards; `Builder:UseExample(key)` loads one (undo goes
  back), `Builder:OpenExample(key)` opens one as a new event (closed untouched, nothing is kept: for the Library's
  Examples menu).
- Practice: "Make something happen" lists the facts the event listens for first (the rest under "Something else");
  leaves / enters a place a dummy is already out of / in says so instead of doing nothing.

## UI to mock up (sections 17+, replacing the first drafts where the pieces changed)

- 17 the builder: the new categories, Players with its tags listed and "+ Add tag", the hide and seek example.
- 18 places and the map picker (the first draft fits; piece wording updated).
- 19 the definition editors (tag, score, list with questions, ask) and the Matches card with "won by".
- 20-22 boards (first drafts fit; captions say what they're drawn from: tags + places, a walked list + a Time score,
  a Fish score).
- 23 the ask prompts: pick a player (the catwalk), a typed answer (trivia), 1-10 (judges), yes / no; their results.
- 24 trackers (first drafts fit; tags and scores lines, buttons, the arrow).
- 25 the duel cup rebuilt (its Always stage: moments, show, one guild post) and the "Start from" examples list.

## Build plan (after the mockups are approved)

1. Core/EventBlocks.lua: categories, definitions, pieces, `Migrate`, checks (a tag / score / list / ask / place that's
   gone, an ask with no question), Describe rules for the event page. Core/EventEngine.lua: tags, scores, lists, asks,
   buttons, points, the happen / place / touch / radar / answer / press hats, Matches "won by the pieces".
2. Core/EventSensors.lua (new) + Core/EventLive.lua: the senses (only what the running def uses), the facts, privacy,
   rate limits, practice facts (the dummies panel's "Make something happen" gets every new fact).
3. UI/EventBuilder.lua (+ EventPieces): the palette with definitions, the editors, the map picker, the Matches card.
4. UI/EventBoard.lua + UI/EventTracker.lua: the views from definitions, the tracker lines, the ask prompts, buttons,
   the arrow, the show banner and the tell feed.
5. UI/EventsTab.lua: event page rules and rewards for the new blocks, results with scores, library chips.
6. The examples (EventBlocks: one def each), the changelog, the tests (one suite per area plus an end-to-end run of
   every example with dummies).
