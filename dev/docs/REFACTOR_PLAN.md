# DisasterZone refactor plan: UI uniformity + DRY (merged 2026-10-11)

This merges two read-only audits from 2026-10-11:
- **UI uniformity audit**: where pages lack a shared structure; global section, component and page types.
- **DRY refactoring opportunities**: duplicated code across the whole addon (sync, class tools, 3D, sim, games, helpers).

Both audits found the same pattern: a feature was built once, then copied for the next one, and the copies drifted apart. Their UI findings overlap: DRY #2 ("one UI toolkit") is the same work as UI layers 0–1, and DRY #4 ("UI components") is UI layers 2–3. Below they are one plan.

Nothing has been built yet. Each phase needs a go before it starts (see the plan-before-build rule).

---

## Phase 0: bug fixes (small, independent, ship first)

| Bug | Where | Status |
|---|---|---|
| Blessing index never range-checked; a bad or newer Pally Power message errors in Report | Core/Blessings.lua:1078, :850 | checked |
| RaidPlan digest capped at 100 after an alphabetical sort, so `O:` keys crowd out teams (`T:`) and series (`S:`) | Core/RaidPlan.lua:81, :1249 | checked |
| Hyjal art key `MountHyjal` vs data key `HyjalSummit`: Hyjal falls back to the generic picture | UI/LootRulesUI.lua:28, UI/PrizedUI.lua:49 | checked |
| Bingo sends on the council channel class instead of `"game"` | Games/Bingo/Bingo.lua:205, :335 | checked |
| `RADIAL` texture path written with single backslashes; the seal halo never loads | UI/MainFrame.lua:691 | checked |
| Events `Commit` can fail when the guild key is unknown | Core/Events | to verify |
| DungeonRuns saves into the "no guild" bucket before the guild key is ready | Core/DungeonRuns | to verify |
| Deleted Events/Polls/Prized records can come back from members offline 30–60+ days | Core | to verify |
| Chess, StrategyMap3D and View ignore the vector form of `GetActiveBoundingBox` | Games/Chess/Board3D.lua:586, UI/StrategyMap3D.lua:911/1592, Render3D/View.lua:259 | to verify |
| MyLog's talent check differs from ClassKit's | UI/MyLog* vs ClassKit | to verify |

---

## Phase 1: foundations (shared homes; mechanical, close to invisible)

Everything later builds on these, so they come first.

### 1A. Design values: `UI/Style.lua`, loaded before Widgets.lua
Covers the DRY #2 `UI.PALETTE` and UI layer 0.

- **Colours**: GOLD, GOLD_DEEP (fills and edges, if kept; decision D1), TEXT, SUB (0.62 grey), DIM, YOU, SURFACE_WINDOW (0.078), SURFACE_CARD (0.10/0.10/0.12/0.92), SURFACE_INSET, EDGE (0.34/0.34/0.38 at 0.55), EDGE_QUIET, HAIRLINE (1,1,1,0.07), HOVER (1,1,1,0.05), SELECT (gold 0.10 plus a 2 px bar), and OK/WARN/BAD/LIVE.
  - Each colour also comes as a `|cff` hex string.
  - Today: ~1,780 literal colour calls vs ~140 token uses. `1,0.82,0` is typed 552 times; `local GOLD` is defined 24 times with 7 values. The card colour is typed by hand 39 times, the edge colour 69 times.
- **Type scale**: caps 9.5, small 10, body 11, emph 12, title 13, page 17, hero 19 (decision D2 on half sizes).
  - Today: 38 sizes across ~974 literal calls.
- **Spacing and sizes**:
  - PAD 10, GAP 8, IN 8.
  - Row heights 22 / 26 / 38, and 50 for art rows.
  - Banner heights 128 (hero) / 84 (tool) / 46 (strip).
  - Page size and content width exposed by MainFrame (today 790×548 is hard-coded in 16 files).
- `EUI.GOLD`, `CARD`, `EDGE`, `PAD`, … become aliases of these.
- Values are picked from the most common existing ones, so migrating is near pixel-identical.

### 1B. UI primitives in Widgets.lua
Covers DRY #2 and UI layer 1.

- **One text factory**: `UI:Text(parent, style, color, opts)` with named styles (title, body, sub, caps, num). Today 26 local copies of `Text` use 5–6 argument orders, plus `Sized`, `setSize`, `newText`, `Label` and others: 68 text helpers in all.
- **One gradient**: `UI:Gradient(tex, orient, …)`. Today there are ~22 local copies with 7 signatures, and the Widgets copy misses `SetColorTexture(1,1,1,1)`.
- **Small shared helpers**:
  - `UI:Rule` (the hairline divider; 192 are hand-written).
  - `UI:FitText` and one `UI:TextWidth` (EUI defines it twice).
  - `UI:AttachTooltip` (196 hand-written GameTooltip blocks).
  - `UI:Pool` / `UI:HideFrom` (~170 hand-rolled row pools).
  - `UI:FitModelCamera`.
- **Side libraries**: `EUI` (EventWidgets), `Board.H` (EventBoard) and `H` (EventsTab, with PollsTab a near-verbatim copy) become thin aliases, then go away.
- **Dead code and duplicate names**:
  - Delete `UI:CreateFlatButton`, `UI:CreatePill` and `UI:CreateLabel` (no callers).
  - Fold the aliases `CreateButton`, `CreateDropdown` and `CreateMenuButton` into the real functions.
  - Remove the duplicate SD_* constants in the search dropdown.

### 1C. Shared data helpers in Util / Constants
Covers DRY #9, #4 and #7.

- **Util**: `Util.Now`, `IsInt`, `DemoOn`, `Jitter`, `NewRng`.
  - Keep each module's own `WireKey` / `IsId` character set, because changing it changes what older clients accept.
- **Constants**:
  - `ns.SlotLabel` (11 copies, 3 fallbacks).
  - `ns.ClassName(cf, localized)` (7 copies, 3 behaviours).
  - Spec icons as a field on `ns.SPECS`.
  - One class list, slot pair table and profession list.
- **Item text**: `UI:ItemText` / `ItemIcon` / `ItemName` / `ItemLabel` are the only versions. All go through ItemDB, with the 134400 icon fallback.
- **Names**: one ShortName / ClassOf / ColoredName (19 copies; the Games copies strip any realm).

### 1D. One table of raid information
Covers DRY #5, and is the art source the banners in phase 2 need.

- Put `short`, `planKey`, `art = {fdid, cx, cy}` (plus the logo crop), `mapNames` and `mapIDs` on each raid entry, in `Data/Items.lua` or a new `Data/Raids.lua`.
- Add `ItemDB:GetRaidByInstance`, `GetRaidByPlanKey`, `RaidShort` and `RaidArt`. `RaidPlanUI:RaidArt` (called from 24 files) moves here.
- Keep both key forms (`HyjalSummit` / `hyjal`), because saved records use them.
- This removes ~25 local tables, including the raid-art map copied 4×, `INST_SHORT` 3×, and `ART_TOP` 5×.

### 1E. Guardrail lint in dev/tools/check.py (warn-only now, error after phase 3)
- Flags new literal token colours (`1, 0.82, 0`, `0.34, 0.34, 0.38`, `0.10, 0.10, 0.12`, …).
- Flags new `local function Text(` / `Gradient(` / `SlotLabel(`.
- Flags numeric `SetFont` sizes outside Style.lua.
- Flags the same raid tables being re-declared.

---

## Phase 2: UI components (the missing section and component types)

Covers DRY #4 and UI layer 2. Each one replaces several hand-built copies.

| Component | Replaces |
|---|---|
| `UI:CreatePageBanner{art, kicker, title, sub, pill, back, actions, size}` on `EUI:AddShade` | ~12 banners: the 6 `BuildBanner`s, raid log, guests, prized, feedback, events, polls, drop panel, meter detail, strategy board, Atlas source, changelog (shade alpha 0.7–0.94, width 240–360) |
| `UI:CreateBackLink` | 7+ copies (3 sizes, 3 greys, 2 chevron helpers) |
| `UI:CreateSectionHeader(title, {count, right, divider, action})` in two styles: **title** (gold 12–13 with a divider) and **caps** (grey small caps) | 9+ heading styles |
| `UI:CreateCard{tone = card / inset / quiet, head, pad}` | ~10 local card/box/panel helpers, 7+ fills |
| `UI:DecorateRow(row, {hover, selectable, stripe})` + `UI:CreateArtRow` (64×38 thumbnail + icon badge) | 5 selection looks and ~26 hover setups. The art row is used by Events, Polls, raid log, Strategies and Guests |
| `UI:CreateEmptyState{icon, title, text, action}` + `UI:CreateNotice(read-only / locked / loading)` | ~25 hand-made empty labels. Today missing permission states mean hidden buttons or chat prints. Model: My Log's illustrated empty state |
| `UI:CreateRailNav` | Settings `NewNavItem` + Notify `RailItem` (identical) |
| `UI:CreateSegments` | EUI / Kit.Segment / CouncilRules Seg / EventBuilder Segmented / PollsTab SegBar / GemEditor |
| One `UI:CreatePill(kind)` + one `UI:CreateChip` | 3 `newPill`s, 7 `NewChip`s, ~20 local builders, 4 pill colour tables; `EUI`'s live/rank looks move into Widgets |
| `UI:CreateSheet`, `UI:Toast`, `Popup:Confirm` / `Popup:Prompt` | 3 sheet shells, 4 toasts, 3 custom confirms, hand-written `dialogs.X` |
| `UI:CreateHudFrame` + one Save/RestorePosition | RollFrame, SessionBar, MeterDetail and Tour chrome; 4 position-save systems; 4 close-button sizes |
| One theme registry + `UI:CreateThemeTiles` | MeterTheme and BarFace (same theme names, copy-pasted ~70-line tile picker) |
| `UI/MapArt.lua`: `MapArt.Layer` / `Tiles` / `Yards` (DRY #5 of the 3D audit) | Map tile drawing ×3–4 (StrategyMap, EventWidgets, GuildMapUI, EventBuilder) |

Plus a **component gallery**: a dev-only view in `ui_audit_states.py` that renders each component once, so look changes are reviewed in one place.

---

## Phase 3: page templates (the shared page structure)

`MainFrame:RegisterTab` takes a `layout`. The template owns the toolbar row (tabs on the left, filters, and one primary action on the right at a single height; today it is 22/24/26/28 and placed in 3 different spots), the margins and the empty/notice slots.

| Template | Shape | Pages |
|---|---|---|
| **Board** | toolbar → grouped sections, optional side card, hero card for the top item | Upcoming, Events, Polls, Dungeons, Strategies, Teams board |
| **List + detail** | fixed-width list → detail with a banner and tabs at its foot | Guests, Raid log, Prized, Members, Feedback, Loot rules, Sim recent runs; Atlas as a 3-column variant |
| **Detail page** | back link → hero banner → tabs → body | raid page, event page, team page, poll page, loot-rule item |
| **Rail** | side menu → titled sections of rows | Settings, Notifications |
| **Tool window** | CreateWindow → banner → body | Blessings / Totems planner, Swing practice, drop panel, meter detail |

**Migration order**, each area with `ui_audit --look` before/after:
1. Raids (most copies).
2. Events / Guild. EventsTab's `H` kit is retired here.
3. Gear.
4. Home / Settings / misc.
5. Standalone windows.

Then the phase 1E lint goes from warn to error.

---

## Phase 4: feature cores (DRY items that are not UI-first)

- **Blessings + Totems class planner** (DRY #3, ~750–900 lines):
  - `Core/ClassPlanner.lua` holds the store, send queue, permissions, roster, lifecycle, report, slash command and demo.
  - The window becomes the **Tool window** template built from phase 2 parts, rather than a third copy of the planner chrome.
  - PLPWR/SHPWR messages don't change; each class keeps its own encoders and planning logic.
  - The core can start any time after phase 1. The UI part waits for phase 2 so it is only migrated once.
- **Combat log** (DRY #6): one shared reader for Meter / MyLog / SwingTimer, and one death-recap recorder (today fields 5 and 6 are swapped between the two). Decision D5 first.
- **3D** (DRY #7):
  - `R3.NewOrbitController`, `View:CalibrateOrbit` / `SyncDepthMode` / `DrawFrame`.
  - `R3.SettleBody`, `R3.NewFollowCam`, `R3.Spring`.
  - `R3.ActorBox` (also fixes the vector bounding-box form), `R3.ANIM`, one `R3.DISPLAYS`, and `R3.Bend`.
  - Needs an in-game check of Chess, the strategy board and the Trainer. Decision D6.
- **Sim** (DRY #8): `S.RegisterClass(...)` with an explicit `order` (Paladin after racials). Shared spell-mask builder, `equipped`, `Travel` and `TickDot`. Check against the reference DPS.
- **Games**: `Games:Send(id, msg, dist, to)` (sets class `"game"`) and `Games:PeekData(id)`. The Whisper ×4 and ShortName ×8 copies go. The games UI uses `UI:Label` / `UI:Gradient`.

## Phase 5: sync engine (last, in the dev kit against the scale suite)

- **DRY #1**: `Core/DigestSync.lua`, set up per module (Events, Polls, Prized, RaidPlan, Strategy: ~120 lines each today).
  - Plus `DB:GuildBucket()` (~20 accessor copies) and `Sync:RegisterHelloField()`.
- **Hard rules**:
  - Keep every message type and field name, the 6-hex hashes and each module's tie-break.
  - Never lower a receive cap; older clients drop the whole digest.
- **Then the smaller sync clusters**:
  - the rev-list handshake (raid leaders, blacklist, guest book);
  - Ledger / RaidLog bucket sync;
  - scattered migrations moved into the empty `MIGRATIONS` table in DB.lua.

---

## Decisions needed before the phases they block

| # | Decision | Blocks |
|---|---|---|
| D1 | Gold: `1, 0.82, 0` for text/accents and the warmer `0.91, 0.73, 0.14` only for fills/edges, or one gold everywhere? | 1A |
| D2 | Half font sizes (9.5, 10.5, 11.5 …): snap to the scale (small shifts) or keep them? | 1A |
| D3 | Banners: every list-and-detail profile gets a banner (e.g. Members like Guests), Board pages get a hero card, Settings stays bannerless? | 2–3 |
| D4 | Sunwell short name: `SWP` or `Sunwell`? | 1D |
| D5 | Overkill: Meter counts it in damage and MyLog doesn't. Which one wins? | 4 combat log |
| D6 | 3D feel: one zoom step and one ease (today 0.88 linear vs 0.82 log), or keep per-view options? | 4 3D |
| D7 | Release: ship the refactor as its own release (e.g. 1.4.0) or fold it into ongoing releases? | all |

## Size and risk (rough; the audits' estimates overlap)

| Phase | Lines removable | Risk |
|---|---|---|
| 0 | n/a | low |
| 1 | ~3,000 (toolkit + helpers + raid info) | low per change, touches many files |
| 2–3 | ~1,500–2,000 | medium (visible, on purpose: needs `--look` checks) |
| 4 | ~1,500 (planner ~800, combat log ~225, 3D ~350, sim ~165, games ~85) | medium (in-game / reference checks) |
| 5 | ~1,000 | medium–high (wire formats) |

Total is roughly 7–8k lines, and every page ends up on one of five templates.
