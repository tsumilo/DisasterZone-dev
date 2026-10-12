# P2 shared homes: API contract

Phase P2 of dev/docs/ARCHITECTURE_PLAN.md. The foundation agent BUILDS these (with tests); the area agents USE them to
migrate every copy listed in the duplication sweep (proposal page, section "Duplication sweep"). A builder may add
optional fields/methods; it must not rename or drop what is listed. Each new function gets a one-line contract comment.

Wire rule for everything below: where a copy feeds message fields, hashes, saved data or what other clients accept, the
caller passes its CURRENT values (caps, character classes, slack, message class) explicitly. Behaviour stays
byte-identical; no check is tightened.

## Core/Time.lua (new, TOC right after Core/Util.lua): `ns.Time`, local alias `local T = ns.Time`
```
T.DAY = 86400, T.WEEK = 604800, T.HOUR = 3600
T.Now()                          -- server time (GetServerTime, falls back to time()); Util.Now stays as an alias
T.DayStart(t)                    -- local midnight of t (date("*t") based, DST-safe)
T.DaysBetween(a, b)              -- whole calendar days from a to b (b later = positive)
T.DayWord(t, opts)               -- "Today" / "Tomorrow" / "Yesterday" / weekday within opts.weekdayWithin (default 6) / date;
                                 -- opts.lower -> lowercase; opts.now
T.Relative(t, opts)              -- "in 3 days", "in 2 h", "now", "2 h ago" ... (EventWidgets EUI:Relative wording)
T.Ago(t, style)                  -- "short" ("5m", "3h", "2d") | "long" ("5 minutes ago"); Util.FormatAgo = T.Ago(t, "long")
T.Clock(sec)                     -- "m:ss" ("1:05"), hours as "h:mm:ss"
T.Span(sec, opts)                -- "2 h 5 min", "45 min", "3 days" (opts.short -> "2h 5m")
T.Fmt(t, kind)                   -- "day" ("Wed 14 Oct"), "dayTime" ("Wed 14 Oct, 20:00"), "time" ("20:00"), "long"
T.Bucket(t, mode, now)           -- "past" | "today" | "week" | "later"; mode "calendar" (Mon-Sun week) | "rolling" (7 days)
```
Display only: replacing a raw `time()` that is STORED or SENT (GuildMap `ts`, Feedback `at`) is out of scope.

## Core/Wire.lua (new, after Core/Time.lua): `ns.Wire`, alias `local W = ns.Wire`
```
W.Key(s, maxLen, badClass)       -- player key or nil; badClass default "[%c|]" (each module passes its own set)
W.IsId(s, maxLen, pattern)       -- bool; pattern default "^[%w%-_]+$" (Events "^[%w%-%/_]+$", RaidPlan "^%w+$", ...)
W.CutUtf8(s, n)                  -- at most n bytes, never splitting a UTF-8 character
W.Text(s, maxLen, opts)          -- cleaned text or nil; opts { mode = "reject" | "scrub", lines = bool, trim = bool }
                                 -- reject: nil when control chars / "|" / too long; scrub: strip them and CutUtf8
W.Rev(v, now, slack)             -- integer rev in 1 .. now + slack, else nil
W.Common(r, now, slack)          -- the shared {id, by, rev} checks of CleanCommon (RaidPlan:632 = Strategy:614)
W.MAX_REV = 2147483647
```

## DB (Core/DB.lua)
```
DB:GetSetting(path, default)     -- existing, gains a default (nil value -> default)
DB:Scope(prefix)                 -- -> get(path, default), set(path, value) bound to "<prefix>." paths
DB:Sub(tbl, key)                 -- tbl[key] as a table, created if missing (replaces the 24 inits)
```

## Permissions (Core/Guild.lua for now; carved into Logic/Context/Perm in P3)
```
Guild:HasRole(key, roles, opts)  -- roles: set or list of "gm","officer","guildCouncil","council","raidPlanner",
                                 -- "raidLogMember","attendanceReviewer"; opts { real = bool, demoMe = bool }
                                 -- demoMe: in demo mode Util.IsMe(key) passes (the 9 hand-written bypasses)
Guild:SamePlayer(a, b)           -- same character or same account (RaidPlan's local SamePlayer)
Guild:IsOwner(rec, key, field)   -- SamePlayer(rec[field or "by"], key)
```
Module entry points (Polls:CanAsk, Events:CanReview, Prized:CanModerate ...) stay, as one line over HasRole, each
keeping today's `real` flag. UI `IsCouncil()` copies become `Guild:AmICouncil()`.

## Search, sort, names (Core/Util.lua; Constants)
```
Util.Query(text)                 -- matcher m(...) -> bool: FoldCase, trim, multi-word AND over all args; nil text = match all
                                 -- opts on CreateSearchBox: normalize = true
Util.NameLess(a, b)              -- FoldCase name, then key
Util.SortBy(list, ...)           -- stable sort by key functions / field names
Util.NextRev(cur)                -- max(Now(), (cur or 0) + 1); DigestSync's Engine.NextRev re-exports it
Util.ClassOf(key, known)         -- class file: known -> me -> guild -> group -> BiS store -> registered resolvers
Util.RegisterClassResolver(fn)   -- EventLive dummies, GuildMap demo, game rosters
ns.Spec(classFile, sp)           -- -> spec key, index (accepts index, key or label)
ns.RoleOf(classFile, sp, scheme) -- scheme "raw" | "four" (tank/heal/melee/ranged) | "three" (tank/heal/dps)
ns.CLASS_ROLE, ns.ROLE_ICON      -- the single tables
RaidComp.ROLE_INDEX              -- exported column order
RaidPlan.STATUS_ORDER, RaidPlan.PAST_GRACE (= 6*3600), RaidPlan:IsPast(raid, now)
```

## Demo (Core/Demo.lua)
```
Demo:Cast(n, opts)               -- list of {name, key, class, spec, role}; opts { classes, specs, withMe, avoid, seed }
                                 -- one name list (consistent classes); GetFakeNames() keeps returning the OLD frozen list
                                 -- (Ledger.lua:179 purges old fake awards with it)
Demo:Cache(key, buildFn)         -- built once, dropped on DEMO_TOGGLED
Demo:Day(offset)                 -- T.DayStart(now) + offset days
Demo:Rng(salt)                   -- deterministic RNG (Util.NewRng)
```
Every `ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()` becomes `Util.DemoOn()`.

## Comm (Core/Comm.lua)
```
Comm:Sender(opts)                -- -> send(msg, dist, target); opts { class = <today's class>, demoGate = bool,
                                 --    dist = default distribution, whisperOnly = bool, rateKey = fn|nil }
```
Each module passes exactly the class and demo gating its local `Send` has today.

## UI (UI/Widgets.lua, UI/Comp/*)
```
UI:Refresher(frame, fn, opts)    -- -> r; r:Request() (debounced while shown, opts.delay, opts.maxWait),
                                 --    r:Dirty() (mark; painted on next show), r:Now(); catches up on show by itself
layout:SetRefresh(fn, events)    -- a Refresher bound to the layout's page + an ns:On list (replaces the 6 event loops)
toolbar:SetTabs(tabs, onSelect, { views = { key = createFn } })
                                 -- lazy view creation + SetShown per key; layout:GetView(key)
UI:ColoredName(key, cls, opts)   -- opts { you = true ("You" in blue), guestTag = bool }; uses Util.ClassOf
UI:ClassOf(key, known)           -- delegates to Util.ClassOf
S:Hex(color)                     -- the one hex formatter (round half up); UI:ColorHex / Util.ColorText route through it
UI:ItemIcon(id, opts)            -- opts.noFallback -> nil instead of 134400 (EUI:ItemIcon behaviour)
```
Components asked for by the 25 TODO(refactor) markers (see the leftovers report in the proposal):
```
UI:CreateChip opts += { removable, onRemove, count, iconOnly, shape = "square", wrap, lead = glyph }
UI:CreateSheet opts += { eatWheel, anchor = frame (popover beside a row, pointer) }
Popup:Prompt opts += { withWindow = frame }, handle:GetField(), handle:SetError(text)
UI:CreatePageBanner opts += { pills = {...}, slotBL = true, actionChip, stats = {...}, editTitle = fn }
UI:CreateUnderlineTab / layout toolbar tab opts += { icon, themeFont, expand }
UI:CreateSegments opts += { look = "stepper" }
toolbar:SetFilterRow(frame)
UI:CreateDatePicker opts += { range = true }
UI:CreateCard opts += { onReceiveDrag }
UI:CreateZoomControl(parent, opts), UI:CreateCurrencyBar(parent, opts)
```
Slider and pips (single use) get a justified `uniformity.ALLOW` entry instead (decision D7).

## Loot page kit (UI/LootKit.lua, new, before UI/Council.lua) + Core/LootView.lua (new, after Core/Roll.lua)
```
LootKit.Paint, ColoredName, ItemText, Setting (DB:Scope), SLOT_GROUP_FALLBACK, UniqueWanters, LockChanged, WarnIcon,
Presence(key) -- one copy of what Council, DropPanel, LootLog, RollFrame and Tooltip each re-make today
```

## Games (Games/Hub.lua)
```
Games:Register(t, fn)            -- receive wrapper (sets the "game" class), mirrors Games:Send
```
Keep: the 4 Park-Miller RNGs and the djb2 hashes (lockstep / checksum inputs between clients).

## Module headers
Every file a P2 agent rewrites substantially gets its contract header (format in ARCHITECTURE_PLAN.md).
`check.py --headers` lists what is missing.
