# Events (1.3.2): the guild's own events, built from pieces

Approved by the user 2026-10-06 ("go for glory"). Mockups (the target look, approved as "amazing"):
`dev/art/casc/events_mockup/events_mockup.html` and its screenshots `dev/art/casc/events_mockup/shots/shot00..16.png`
(section i of the page = shot i). Build them as close to the mockups as the game allows.

## Files

| File | Module | What |
|---|---|---|
| Core/EventBlocks.lua | `ns.EventBlocks` | The pieces catalogue, categories + colours, smart blocks, the starter event, checks, plain words, diff |
| Core/EventEngine.lua | `ns.EventEngine` | The interpreter (a run): stages, scripts (coroutines), timers, Sign-up + Bracket blocks |
| Core/Events.lua | `ns.Events` | Library (D), reviews (K), calendar (O), sign-ups (J), results (R), season (C), titles (T); sync |
| Core/EventLive.lua | `ns.EventLive` | Live runs: host broadcast, duel reports, asks, takeover, host controls, practice runs |
| UI/EventWidgets.lua | `ns.EventUI` | Shared look: art crops, shade, badges, class circles + names, progress line, pills, dates |
| UI/EventPieces.lua | `ns.EventPieces` | Draws pieces (frames) and lays them out (builder, inside view, practice, review) |
| UI/EventBuilder.lua | `ns.EventBuilder` | The builder window (mockup shots 3-6), practice mode (shot 6) |
| UI/EventsTab.lua | `ns.EventsUI` | The Events tab: Upcoming, Library, Season, Review; event page, results, sheets (shots 0-2, 11-14) |
| UI/EventBoard.lua | `ns.EventBoard` | The live board window + host bar + dispute (shots 7-8) |
| UI/EventTracker.lua | `ns.EventTracker` | Tracker under the minimap, match-ready card, result prompts, screen texts (shots 9-10) |

## Data

- **def** (an event): `{ id, rev, by, at, name, icon (texture path), art (EventBlocks.ART key), stages = { {id, name, desc} },
  scripts = { {id, st = stageId | "*", x, y, top = piece} }, blocks = { [bid] = {kind = "signup"|"bracket", stage, x, y, set, inner} },
  vars = { {n, t} }, badges = { [badgeId] = {n, i, f (frame: gold|silver|bronze|fel|arcane|blood), ti (title)} }, notes, review }`.
- **piece**: `{ k, a = {args}, n = next, c1 = inside, c2 = else }`; an arg is nil (empty blank), a number, a string, a piece,
  or `{ j = { "text", piece, ... } }`. Catalogue: `EventBlocks.PIECES[k] = { cat, shape = hat|stack|cap|c|c2|bool|value,
  text = "say {1} in {2}", args = { {t, d, kind} }, gives, vt, inner }`. Palette order: `EventBlocks.PALETTE[cat]`.
- **occurrence** (O, a calendar event): `{ id, h (host), by, at (start), where, note, def (a copy), dk (library id), ranked, cancel }`.
- **run state** (`EventLive:GetState(occId)`): `{ phase = ready|live|done|cancelled, host, stage, seq, entrants = {keys},
  signups, ready = {[key]=true}, off, vars, stats = {[stat] = {[key]=n}}, timers, blocks = {[bid] = state}, moments =
  { {at, text, i} }, awards = { {p, b} }, asks = {[id] = {id, to, opts, ans, q, match, claims}}, ann = {s, text, at},
  cd = {s, n, at, to}, watch, paused }`.
  A bracket state (`EventEngine:BracketOf(def, st)` -> bk, bid): `{ fmt, bo, fbo, seeds = {keys}, rounds = { [r] = {mids} },
  m = { [mid] = {id, r, i, a, b, wa, wb, g, st = wait|play|done|bye, win, bo, t (start), te, final, bronze, wo} }, r (current),
  last (last round), done, champ, second, third, fin = {a, b}, out, elim }`.
- **result** (R): `{ id (= occId), name, icon, art, at, t1, ranked, n (entrants), champ, second, third, points = {[key]=n},
  badges = { {p, n, i, f, ti} }, moments, last4 = { {a, b, wa, wb, win, r, sa, sb, final, bronze} }, nums = {matches, duels,
  longest, watch}, mw = {[key]=match wins}, hosts, cancel }`.

## Core API (what the UI calls)

Events (`ns.Events`):
- Library: `GetDefs()`, `GetDef(id)`, `IsMine(d)`, `NewDef(starter)` (not saved), `CopyDef(idOrDef)`, `SaveDef(d)` (false if
  not mine / too big), `DeleteDef(id)`, `RunCount(defId) -> n, lastAt`.
- Review: `ReviewState(d)` -> ranked|review|back|changed|draft, `IsRanked(d)`, `SubmitForReview(id, note)`,
  `CanReview(key)`, `AmIReviewer()`, `Review(id, ok, note)`, `GetReviewQueue()`, `GetDecided(n)` -> { {d, k} },
  `GetReview(defId)` -> K record `{by, rev, dr, ok, note}`, `RankedSnapshot(defId)` (the def as ranked; for the diff).
- Calendar: `Schedule(defId, at, {where, note}) -> occId`, `GetOcc(id)`, `GetOccurrences(from, to)`, `HostOf(o)`,
  `CanManageOcc(o)`, `CancelOcc(id, reason)`, `DeleteOcc(id)`, `EditOcc(id, at, where, note)`, `OccState(o)` ->
  planned|live|done|cancelled|missed, `ClosesAt(o)`.
- Sign-ups: `SignUp(occId, on)`, `IsSignedUp(occId [, key])`, `GetSignups(occId)` -> keys (first come first).
- Results: `GetResult(id)`, `GetResults(from, to)`, `DeleteResult(id)` (moderators).
- Season: `GetSeason()` -> {n, from, to}, `SetSeason(n, from, to)` (GM / officers), `Standings()` -> { {key, pts, events, wins,
  badges = {...}, rank} }, `RankOf(key)`, `BadgesOf(key)`, `TitlesOf(key)`, `GetTitle(key)`, `SetTitle(ti)`.
- Roles: `CanModerate(key)` (GM / officers), `CanReview(key)` (GM / officers / guild council).

EventLive (`ns.EventLive`):
- Reading: `GetState(occId)`, `GetDef(occId)`, `GetHost(occId)`, `IsLive(occId)`, `GetLiveList()`, `MyMatch(occId [, key])`
  -> match, bk, st, `MyAsk(occId)` -> ask, st, `IsHostOf(occId)`, `IsPaused(occId)`, `DisplayName(key)` (function, not method).
- Entrant: `Ready(occId)`, `AnswerAsk(occId, askId, winnerKey)`, `Watch(occId)` / `Unwatch()` (the board is open).
- Host: `CanStart(occId) -> ok, why`, `Start(occId)`, `SetPaused(occId, on)`, `DecideMatch(occId, mid, winner)`,
  `HostAnswer(occId, askId, winner)`, `AddPlayer(occId, key)`, `RemovePlayer(occId, key)`, `GoStage(occId, stageId)`,
  `CloseSignup(occId)`, `HandOver(occId, key)`, `EndEvent(occId)`.
- Practice: `StartPractice(def, count) -> run`, `StopPractice()`, `GetPractice() -> run, p`, `PracticeDuel(w, l, agree)`,
  `PracticeOffline(key, off)`, `PracticeReady(key)`, `SetPracticeSpeed(x)`, `SetPracticePaused(on)`, `PracticeSkip()`,
  `DummyClass(key)`. The practice run's occId for GetState / GetDef is `"practice"`.

EventBlocks (`ns.EventBlocks`): `CATS`, `CAT[cat] = {f, f2, e, label}`, `PIECES`, `PALETTE`, `INNER_PALETTE`, `CTX`,
`SMART[kind] = {label, icon, settings, gives}`, `ART` / `ArtPath(key)`, `FRAMES`, `FRAME_COLOR`, `Starter()`, `Blank()`,
`New(key)`, `Walk`, `Problems(d)` -> { {script, piece, slot, text} }, `ProblemsByPiece(d)`, `Describe(d, {closesAt})` ->
{ {id, name, text, rules = { {g, t} }} } (g: group|clock|swords|rank|trophy|eyeo), `Kinds(d)`, `BadgeList(d)`,
`SmartSetting(block, key)`, `BlocksOf(d, kind)`, `BlockLabel(d, bid)`, `Stage(d, id)`, `StageName(d, id)`,
`Diff(old, new)` -> changes, same, `DurationText(sec)`, `SEASON` ("Season points").

EventUI (`ns.EventUI`): `SetArt(tex, artKey, w, h, cx, cy, fw)`, `AddShade(frame [, "card"])`, `CreateBadge(parent, size)`
(`:SetBadge(bd)`), `SetClass(tex, key)`, `ClassOf(key)`, `Name(key [, real])` ("You" in blue), `Plain(key)`,
`CreatePill(parent, h)` (`:SetKind(text, kind)`), `ReviewPill(state)`, `CreateProgress(parent)` (`:Set(def, st, sub, done)`),
`StageSub(def, st)`, `RoundName(bk, r)`, `When(t)`, `Day(t)`, `Relative(t)`, `Glyph(tex, UI.ICON.x, r, g, b)`, colours
`GOLD, YOU, GREY, DIM, TEXT, LIVE, CARD, EDGE`, grid `PAD = 10, GAP = 8`.

New atlas icons (UI.ICON): `play, pause, skip, flag, trophy, lock, infinity, bracket` (art pack 4, unreleased: fine).

## Messages (ns:On)

`EVENTS_UPDATED` (library / calendar / results / season changed), `EVENT_LIVE_UPDATED (occId)`,
`EVENT_ANNOUNCE (occId, text)` (show it big, like a raid warning, to me), `EVENT_COUNTDOWN (occId, seconds)`,
`EVENT_PRACTICE_UPDATED`, `EVENT_PRACTICE_LOG (kind, text)`, `EVENT_PRACTICE_RAN (scriptId, blockId)`, `DEMO_TOGGLED`.

## Demo mode

`/dz demo on`: `Events` serves made-up data (`Events:BuildDemo`): a library (the starter Friday duel cup ranked, a 2v2 cup,
my Hide and seek in review, Ring of Blood night), calendar events (`odemo1` started 40 min ago, `odemo2` in 3 days with 7
sign-ups, `odemo3` in 5 days), two results, standings. `EventLive:IsLive("odemo1")` is true in demo mode but it has no state:
the UI's demo view of a live event must build a state itself (e.g. by running a practice-like engine run on demo names);
keep any such fake state in the UI module, never send it.

## Rules (the user's, from the memory notes)

- The flat style: `UI:CreateSleekButton(parent, text, w, h, onClick, kind)` with kinds primary (gold, ONE per view) /
  secondary / chosen / danger; `UI:CreateTipIconButton(parent, size, UI.ICON.x, title, text, onClick)` for icon actions
  (tooltips); `UI:CreateUnderlineTab(parent, text, onClick, size)` for tabs; `UI:CreateSleekMenuButton`, `UI:ContextMenu`
  (UI/Menu.lua) for menus; `UI:CreateSleekEditBox`, `UI:SetEditPlaceholder`, `UI:CreateSearchBox`, `UI:CreateScrollFrame`,
  `UI:CreateSwitch`, `UI:CreateTagPill`. No red Blizzard buttons, no disabled buttons (keep enabled, explain on click).
- No overflow: nothing cut with "...": shorter words or two lines. Every element has a purpose; no labels / counts the
  icons or columns already say. One spacing grid per page: PAD 10 at the sides, GAP 8 between cards / columns, 12 inside
  banners; left / right edges line up. Occasional actions go in a More menu (icon + one word, explanation in the tooltip).
- A frame anchored by one corner with no width or height draws NOTHING in the game (it does in the mock): size it.
- Text that wraps: SetWordWrap / SetWidth before SetText.
- Never send anything in demo mode. Never touch loot council state.

## Tests and checks

- `luaenv\Scripts\python.exe tests\events\test_events.py` (from dev): core + network (12 cases).
- `tools\check.py <files>`: syntax + globals. `tools\release.py guards check`: line-1 guards and the TOC.
- `tools\ui_audit.py tf_e/ui_audit -k Events --look`: renders views from the mock with the real textures and font and
  flags cut / overlapping text. Add states in `tools\ui_audit_states.py` (and new windows to `close_all`).
