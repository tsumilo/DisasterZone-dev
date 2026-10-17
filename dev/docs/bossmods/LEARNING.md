# Boss mods that learn: the rules and the saved format (2026-10-13)

The boss mods' timers (Data/BossMods/*.lua, DATA_FORMAT.md) come from DBM, BigWigs and cmangos. Learning measures what
each boss really does in our raids and tightens them. Mockup: dev/art/casc/cleanup_mockup/cleanup_template.html,
section 3 ("Boss mods that learn"). Code:

| file | what |
|---|---|
| `Core/BossLearnMath.lua` | the rules, pure Lua (no game API): the dev kit's tool runs this same file |
| `Core/BossLearn.lua` | the recorder, the saved data, learning after a pull, sharing with the guild, the developer's review |
| `Core/BossMod.lua` | a fight starts with a snapshot of what was learned (`m.lw`), tells the recorder of bar starts / phases |
| `UI/BossLearnUI.lua` | Settings rows, the Bosses list pills, the boss page, the pop-up, Try it's made-up note |
| `UI/BossModUI.lua`, `UI/BossModLooks.lua` | the recording line over the bars, a learned window's striped teal band |
| `dev/tools/bossmods_learned.py` | reads the SavedVariables and prints what to bake into the data files |

## The promises (never fail mid pull)

- **Nothing learned changes a running pull.** A fight copies the applied windows at its start (ENCOUNTER_START, or an
  `engage` trigger); later changes to the saved data never reach it. The compiled data shared across pulls is never
  changed. Bars still restart on the real trigger, so a timer can't drift.
- **The recorder can't break the alerts.** It is a combat-log subscriber of its own (after the alerts'), every call in a
  pcall; an error, or 2,000 recorded events, stops recording for the rest of that pull (one line in `/dz debug` and in
  the saved `log`). The pull is then not clean: never learned from, never shared. The recording line and the band are
  drawn inside their own pcall too.
- **A timer never moves far.** At most 25% outside the data's numbers (the clamp); a window wholly outside that ("far"),
  or wider than max(4 s, 1.25 x the data's width) ("varies"), is not used at all: the data's number stays and the boss
  page says so.
- **Proven before it is used**: 3 or more clean pulls, outliers dropped.
- **Guild data is checked** before it counts, and anything odd drops the whole message.
- Learning off (`bossmods.learn` false): the data's numbers, nothing recorded or shared.

## What is learnable

A data alert of kind `bar` with a `spell`, a `start` and/or a `cd`, not `loop`, not `me`, not `learn = false`.
Every bar an `fn` hook starts with `m:Bar` must say `learn = false` (tests/bosslearn checks the data); a hook that
starts a learnable bar at runtime also marks it in that pull (`hk`), whose samples for it are then ignored.

The **predicted event** of an alert:
- `own`: its `on` names its spell (`on = "CAST 33525"` on Ground Slam): that trigger's sub-events with those ids, and
  its boss lines (`YELL` / `EMOTE` triggers) too: Leotheras's demon form reaches our log only as his line (16 Oct 2026).
- `cast`: otherwise the earliest SPELL_CAST_START / SPELL_CAST_SUCCESS of its spell (a SUCCESS within 10 s of a counted
  START is the same cast). Gruul's Shatter bar is started by Ground Slam's cast and predicts Shatter 33654.

Events of one alert closer than 1.5 s are one (debounce; 5 s for an alert whose line counts: the line and the spell
can be a few seconds apart). Sources a player controls never count; an alert's `src`
applies.

**Samples**, per pull, from the times (seconds from the pull):
- `start`: the first event after the pull (alerts of phase 1 or without `phase`), or after entering one of the alert's
  phases, minus that moment. Only when the event comes before the next phase change.
- `cd`: from the bar's (re)start to the event it predicts, inside one phase (never across a phase change): for `own`
  alerts the gap between two events; for `cast` alerts (and `own` ones with other non-line triggers too) from the latest bar
  start by its trigger (`g` times) to the event.
- **Fixed**: a `cast` alert with no `start` and a single-number `cd` (Shatter 10 s after Ground Slam) is a follow-up the
  game times: measured (the dev tool shows it), never applied. The page says "Fixed · 10 s".

**The window** of one alert's field: samples from usable pulls only (clean, at least 20 s, recorded against the same data
signature). Median; samples outside 0.5x..1.5x of it are dropped (a missed cast doubles an interval). Ready once 3
distinct pulls contribute (else "Learning · n of 3"). [p10, p90] by nearest rank from 10 samples on, else [min, max];
rounded out to 0.5 s (lo down, hi up: the window always holds what was seen). Then the clamp to
[0.75 x data min, 1.25 x data max]; "far" / "varies" as above. A clean pull = a real encounter (ENCOUNTER_START and
ENCOUNTER_END), at least 20 s long, the recorder never stopped. Shorter pulls are not even kept. Not recorded at
all: a fight that starts within 2 s of coming into the world, or with the boss already below 95% health (I came in
mid-pull). A fight that ends without its ENCOUNTER_END (5 s out of the raid, or the boss's next ENCOUNTER_START: a wipe
while released) is not clean.

## Sharing

3-12 s after the end (a per-player, per-pull delay from the player's name, not math.random), never in a fight (it waits
and retries every 5 s, up to 2 minutes), only with "Share what we learn" (`bossmods.learnShare`) on: one message on the
GUILD channel, prefix `CDLk` (Comm class `boss`, BULK priority). Skipped when a guildmate's summary of the same pull with
at least as many observations already arrived. A pull is the same pull when boss and leader match and it starts and ends
within 20 s of the other; observations merge as a union (a time within 0.5 s of one already there counts once). Two
copies of one pull where only one end agrees keep the better one: the same end and a start up to 180 s later = it came
in mid-pull (dropped); the same start and a later end, or the same end and a start more than 180 s earlier = it ran
into the next pull (dropped). 16 Oct 2026 had both: a Morogrim kill stored twice (a copy 42 s late) and a Hydross
"pull" of 22 minutes holding the next pull. Stored pulls are tidied by the same rules after login (`BL:Tidy`).

The message (LibSerialize + deflate, like every Comm message; a Gruul pull is about 300-500 bytes on the wire):

```lua
{ t = "BL", v = 1,                 -- the format (BossLearnMath.FORMAT)
  av = "1.4.2",                    -- the sender's DisasterZone (at least 1.4.1)
  b = "GruulsLair:Gruul", ds = "1a2b3c4d",   -- boss key, its data signature (must equal the receiver's)
  at = 1760380000, l = "Kaelor-Thunderstrike",   -- server time of the pull, group leader
  d = 2513, k = 1,                 -- duration in tenths of a second, 1 = a kill
  o = { slam = { 342, 740 } },     -- per learnable alert: event times in tenths, each a step from the one before
  g = { shatter = { 342, 740 } },  -- bar starts by the trigger (cast alerts and mixed ones), same coding
  ph = { 2, 612 },                 -- phase, time (tenths) pairs
  nf = { "cavein" },               -- alerts whose combat-log / yell triggers never fired
  u = { 36241, 4, 501 },           -- unknown hostile casts: id, count, first time (tenths) triples (<= 12)
  y = { 10, 1, "Come... and die." }, -- boss lines no trigger knew: first time, count, text triples (<= 6, 120 bytes)
  hk = { "demon" } }               -- alerts a fight script started in this pull
```

Receivers check, and drop the whole message on any failure: format, version >= 1.4.1, known boss, same data signature,
time within 30 days, leader a plain name, 20 s <= duration <= 3600 s, every alert key learnable for that boss, every time
a whole number >= 0 and within the duration, at most 400 times per alert and 2,000 in all, phases 1..20, the caps of
`u` / `y`, no `|` or control characters in a line. Only from the GUILD channel; while a fight runs messages wait (up to
30) and are taken after it.

## The saved data: `DisasterZoneBossLearnDB` (SavedVariables, account wide)

In `WTF\Account\<account>\SavedVariables\DisasterZone.lua`, next to `DisasterZoneDB`. Stable, versioned (`v`): a new `v`
starts the table over.

```lua
DisasterZoneBossLearnDB = {
  v = 1,                                   -- the format
  pulls = {                                -- [boss key] = pulls, oldest first: 30 a boss, 2,000 in all (oldest go)
    ["GruulsLair:Gruul"] = {
      { id = "GruulsLair:Gruul|Kaelor-Thunderstrike|1760380000",   -- boss | leader | server time
        at = 1760380000, leader = "Kaelor-Thunderstrike",
        dur = 251.3, kill = true,
        clean = true,                      -- usable for learning (see above); a stopped one keeps no times
        stop = nil,                        -- why the recording stopped ("error: ...", "2,000 events"), when it did
        ds = "1a2b3c4d",                   -- the boss data's signature when recorded (BossLearnMath.Signature)
        av = "1.4.2",                      -- the recording DisasterZone
        from = "me",                       -- "me", or the guildmate whose summary it came from
        src = 2,                           -- summaries merged into it (mine counts 1)
        mine = 14,                         -- (own pulls) how many event times I recorded (the sharing check)
        sent = true,                       -- (own pulls) true / "heard" (a guildmate had sent it) once handled
        o = { growth = { 30.1, 60.2 }, slam = { 34.2 }, shatter = { 44.3 } },   -- event times, s from the pull
        g = { shatter = { 34.2 } },        -- bar starts by the trigger (cast / mixed alerts)
        ph = { { n = 2, t = 61.2 } },      -- phase changes
        nf = { "cavein", "reverb" },       -- alerts with combat-log / yell triggers that never fired
        u = { { id = 36241, n = 4, t = 50.1, name = "Cave In" } },        -- hostile casts / auras not in the data
        y = { { t = 1.0, n = 1, text = "Come... and die.", kind = "yell" } },   -- boss lines no trigger matched
        hk = { demon = true },             -- alerts a fight script started
        ov = { cavein = true },            -- (developer) alerts recorded while a "Use <id>" fix applied: not shared
      },
    },
  },
  learned = {                              -- worked out again after every pull, guild summary and login
    ["GruulsLair:Gruul"] = {
      ds = "1a2b3c4d", at = 1760381000, pulls = 7,   -- signature, when, usable pulls
      alerts = {
        slam = {
          start = { state = "ok", applied = true, lo = 34, hi = 37,      -- what a pull starts with
                    mlo = 34, mhi = 37, n = 7, p = 7, dropped = 0,       -- measured, samples, pulls, outliers
                    src = { 33, 40 }, clamped = nil },                   -- the data's number
          cd = { state = "wait", n = 3, p = 2, src = { 72, 80 } },       -- "ok" | "wait" | "far" | "varies" | "fixed"
        },
        shatter = { fixed = true, cd = { state = "fixed", mlo = 10, mhi = 10.5, n = 6, p = 6, src = { 10, 10 } } },
      },
    },
  },
  review = {                               -- the developer's (Tsumil) only; others keep it empty
    decisions = {                          -- what to bake into the data (the dev tool prints them)
      ["GruulsLair:Gruul"] = {
        ["spell:cavein"] = { use = 36241, from = 36240, alert = "cavein", name = "Cave In", at = 1760390000,
                             by = "Tsumil-Thunderstrike" },
        ["cast:33572"] = { ignore = true, what = "Gronn Lord's Grasp", at = 1760390000, by = "Tsumil-Thunderstrike" },
        ["yell:Come... and die."] = { ignore = true, what = "Come... and die.", at = 1760390000 },
      },
    },
    suggest = {                            -- the open suggestions, worked out after each pull
      ["GruulsLair:Gruul"] = {
        { kind = "spell", key = "spell:cavein", alert = "cavein", from = 36240, use = 36241, name = "Cave In",
          pulls = 3, seen = 3 },           -- never fired in 3 pulls; the boss cast "Cave In" as 36241 in 3
        { kind = "cast", key = "cast:33572", id = 33572, name = "Gronn Lord's Grasp", pulls = 5, n = 210 },
        { kind = "yell", key = "yell:Come... and die.", text = "Come... and die.", pulls = 4 },
      },
    },
    never = { ["GruulsLair:Gruul"] = { cavein = 3 } },   -- alerts that never fired (pulls checked)
  },
  log = { "2026-10-13 21:42 GruulsLair:Gruul pull 5: recording stopped (2,000 events)" },   -- the last 20
}
```

Suggestions (developer only): an alert silent in every usable pull of at least 2, while the boss cast a spell of the
same name under another id ("Use 36241" / "Ignore"); an unknown cast seen in at least 2 pulls and half of them (5 at
most); a boss line no trigger knows in at least 2 pulls (3 at most). **Use** makes the alert's triggers for the old id
listen to the new one on the developer's client only (from the next fight); everyone else gets the fix with a data
release or hot patch.

## The data signature

`BossLearnMath.Signature(def)`: an Adler-32 of the learnable alerts' key, spell, `on`, `phase`, `src`, `once` and which
of `start` / `cd` it has. Not the numbers: baking better numbers into the data keeps every pull; changing what an
alert listens to starts its boss over (old pulls stay saved, unused, until they age out; the dev tool counts them).

## Baking what was learned into the data (the developer, with Claude)

    luaenv\Scripts\python.exe tools\bossmods_learned.py              (every DisasterZone*.lua under WTF\Account)
    luaenv\Scripts\python.exe tools\bossmods_learned.py <file> --raid GruulsLair
    luaenv\Scripts\python.exe tools\bossmods_learned.py --json --boss GruulsLair:Gruul

Per raid and boss: data number against the learned window (APPLIED, or far / varies / fixed with what was measured),
pulls and samples, alerts that never fired with the same-named casts the boss used instead, unknown casts and lines,
the developer's decisions and open suggestions, the saved log. The windows are worked out again by running
`Core/BossLearnMath.lua` itself (lupa), so they are the game's. Baking a window: put its lo/hi into the alert's
`start` / `cd` with a comment naming the pulls ("ours: 34-37 over 7 pulls"); a "Use" decision: change the trigger's id.
