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
