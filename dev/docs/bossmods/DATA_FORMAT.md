# Boss mods: the data format (2026-10-13)

The built-in boss mods (plan: claude.ai/artifact/Hns6CtKKusYF5tqwuHbSQ4, looks mockup:
claude.ai/artifact/66LY12B41hTyqt7e8GEXEM) read one data file per raid:

    addon/DisasterZone/Data/BossMods/<RaidKey>.lua      (RaidKey = the raid keys of Data/Items.lua)

The engine (Core/BossMod.lua) turns each boss's alerts into timer bars, warnings and the range frame. A data file
holds no logic beyond the optional `fn` hooks below. Everything a player can switch off in Settings is one alert.

## File shape

```lua
if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/GruulsLair.lua", ...) then return end -- DisasterZone: boss mods for Gruul's Lair (format: dev/docs/bossmods/DATA_FORMAT.md)
-- Sources per timer in the comments: DBM = DBM-Raids-BC, BW = BigWigs_BurningCrusade, CM = cmangos mangos-tbc
-- scripts, AC = AzerothCore. Numbers only; no code or text from them.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.BossMods = ns.Data.BossMods or {}
local B = ns.Data.BossMods

B["GruulsLair:Gruul"] = {
    enc = { 650, 2456 },            -- every ENCOUNTER_START id the sources know for it
    npc = { 19044 },                -- creature ids: the boss (health triggers), plus any add an alert names by id
    alerts = {
        -- Growth: DBM 30 next, BW 30 next, CM 30 -> 30
        { key = "growth", kind = "bar", spell = 36300, text = "Growth (%n)", count = "next",
          start = 30, on = "AURA 36300", cd = 30 },
        -- Ground Slam: first DBM 40, BW 33, CM 35-40 -> {33, 40}; again DBM 74 (cast start; "74-80"), BW 62 after
        -- Shatter (= 72 after the slam), CM 70-80 -> {72, 80}
        { key = "slam", kind = "bar", spell = 33525, start = { 33, 40 }, on = "CAST 33525", cd = { 72, 80 } },
        { key = "slamwarn", kind = "warn", spell = 33525, text = "Ground Slam: spread out", sub = "Shatter in 10 s",
          on = "CAST 33525" },
        { key = "shatter", kind = "bar", spell = 33654, on = "CAST 33525", cd = 10 },
        { key = "cavein", kind = "you", spell = 36240, text = "Cave In on you", sub = "Move out of it",
          on = "AURA 36240", me = true },
        { key = "range", kind = "range", yd = 15, text = "Shatter", on = "CAST 33525", stop = "CAST 33654", after = 1 },
        { key = "hurtful", kind = "bar", spell = 33813, role = "T", on = "SUCCESS 33813", cd = 8 },
        { key = "reverb", kind = "bar", spell = 36297, role = "H", start = 102, on = "SUCCESS 36297", cd = { 31, 48 } },
    },
}
```

Line 1 is the boot guard every addon file has (copy it, with the file's own path). Keys of `B` are
`"<RaidKey>:<BossKey>"` exactly as in Data/Items.lua and Data/BossAbilities.lua (Opera: `Karazhan:OperaWolf`,
`Karazhan:OperaRomulo`, `Karazhan:OperaOz`). Hyjal's trash waves are `HyjalSummit:Waves`.

## Boss fields

| field | meaning |
|---|---|
| `enc` | list of ENCOUNTER_START ids (DBM's SetEncounterID values, BW's SetEncounterID, Data/Items.lua's encounterID) |
| `npc` | creature ids. First = the boss whose health `HP` triggers read unless an `HP` trigger names its own |
| `alerts` | the list below, in the order Settings shows them (bars first is fine, any order works) |
| `fn` | optional `{ [triggerName] = function(m, ev) ... end }` for logic the fields can't say (see Hooks) |
| `phases` | optional `{ [2] = "Phase 2: Midnight joins", ... }` names, only for Settings and the demo |
| `engage` | optional trigger list that starts the fight when the game has no ENCOUNTER_START for it (Opera parts: the creature, Hyjal waves) |

## Alert fields

| field | meaning |
|---|---|
| `key` | stable id, lowercase, unique in the boss. Saved settings use it: never rename one later |
| `kind` | `"bar"` timer bar, `"warn"` warning for everyone, `"you"` warning only when it's on the player, `"range"` the range frame |
| `spell` | spell id: the icon, and the name when `text` is nil (the client's own, localized) |
| `icon` | optional other spell id for the icon |
| `text` | the label (English). `%s` = spell name, `%n` = count, `%t` = the target's name. Nil = the spell's name |
| `sub` | a warning's second line (short) |
| `role` | `"T"` tanks only, `"H"` healers only, nil = everyone |
| `on` | trigger or list of triggers (grammar below). A bar (re)starts with `cd`; a warning shows; a range frame opens |
| `start` | bars: seconds from the pull (or from the start of `phase`) to the first one. Number or `{ min, max }` |
| `cd` | bars: seconds from the trigger to the next one. Number or `{ min, max }` |
| `stop` | trigger(s) that end a bar or close a range frame |
| `after` | range: seconds it stays open after `stop` (default 0) |
| `dur` | range / warning: open for this long after `on` (range default: until `stop`, the phase ends, or the fight ends) |
| `yd` | range: the distance in yards |
| `me` | only when the event's target is the player (auras, casts with a target) |
| `meText` | a `warn` with a target: when the target is the player, show this instead, red, as a `you` alert |
| `phase` | number or list: the alert only works in these phases (phase 1 is the pull) |
| `setPhase` | when this alert's trigger fires, the fight moves to this phase (its bars with `start` begin) |
| `count` | `"stack"` = %n is the aura's stack count; `"next"` = %n is the number of the NEXT one (Growth (5) after the 4th); `true` = %n counts this alert's triggers from 1 |
| `src` | list of creature ids: the event's caster must be one of them (when players or adds share the spell id) |
| `once` | true = only the first trigger in a pull counts |
| `delay` | warning: show it this many seconds after the trigger |
| `throttle` | seconds a repeat is ignored (default: 2 for warnings, 0 for bars) |
| `loop` | bars: when it runs out with no trigger, it starts again with `cd` (adds that come on their own timer) |
| `learn` | bars: `false` = never learned from our pulls (LEARNING.md). Required on every bar an `fn` hook starts with `m:Bar` (tests/bosslearn checks it): the hook's numbers are not the data's |

Windows: `{ min, max }` means the sources disagree or the ability really varies. The bar counts to `min`; between
`min` and `max` it shows "any moment". Use a window instead of guessing one number whenever the sources disagree
by more than ~1.5 s, or a source says it varies.

## Trigger grammar

One string per trigger: a word, then numbers or text.

| trigger | fires on |
|---|---|
| `CAST <id> [id...]` | SPELL_CAST_START |
| `SUCCESS <id> [id...]` | SPELL_CAST_SUCCESS |
| `AURA <id> [id...]` | SPELL_AURA_APPLIED and SPELL_AURA_APPLIED_DOSE |
| `AURAGONE <id> [id...]` | SPELL_AURA_REMOVED |
| `SUMMON <id> [id...]` | SPELL_SUMMON |
| `HIT <id> [id...]` | SPELL_DAMAGE / SPELL_MISSED (use with `throttle`) |
| `HEAL <id> [id...]` | SPELL_HEAL |
| `DIES <npc> [npc...]` | UNIT_DIED of that creature id |
| `WIDGET <id> [id...]` | UPDATE_UI_WIDGET: that widget's text changed (ev.amount = its first number; an `engage` fires once it is 1 or more) |
| `UCAST <id> [id...]` | UNIT_SPELLCAST_SUCCEEDED of a creature seen as a unit (boss1-5, target, focus, mouseover, nameplates), once per cast: casts the combat log never shows (the Lurker's Submerge Visual) |
| `SPAWN <npc> [npc...]` | a creature of that id in the combat log for the first time (each one, by its GUID: adds coming up) |
| `BACK <npc> [npc...]` | that creature in the combat log again after 20 s without any sign of it (the Lurker emerging) |
| `HP <pct> [npc]` | the boss (or that creature) drops to `pct`% health or below; fires once per pull |
| `YELL <text>` | CHAT_MSG_MONSTER_YELL containing the text (English, plain find, case-insensitive) |
| `EMOTE <text>` | CHAT_MSG_RAID_BOSS_EMOTE / CHAT_MSG_MONSTER_EMOTE containing the text |
| `ENGAGE` | the pull |
| `PHASE <n>` | the fight entering phase n |

Prefer spell ids over yells: yells are English only. When a phase change has no spell, use `HP`, then `DIES`, then
`YELL`. An ability that never reaches the combat log (check a saved pull with tools/bossmods_learned.py): `UCAST` for
the boss's own cast, `SPAWN` / `BACK` for creatures coming and going. Every spell id must exist in the 2.5.6 client: check with `generators`' spell table
(`spell_visuals.table("SpellName")`, build 2.5.6.69795).

## Hooks (`fn`)

For the few fights the fields can't say (Hydross's forms, Leotheras's demon phase, Vashj's core, Kael'thas's
advisors, Illidan, Hyjal's waves). Keys are trigger strings or `"ENGAGE"`; the function gets the mod `m` and the
event `ev` (`ev.spell`, `ev.src`, `ev.dst`, `ev.dstName`, `ev.me`, `ev.amount`, `ev.npc`, `ev.text`):

    m:Bar(key, secs, text)    start / restart an alert's bar (secs number or { min, max }; text overrides)
    m:Stop(key)               end a bar
    m:Warn(key, text, sub)    show an alert's warning
    m:Phase(n)                move to phase n
    m:Range(key, open)        open / close an alert's range frame
    m:Count(key)              the alert's trigger count so far
    m.phase, m.t              the phase, seconds since the pull

Keep hooks short. A hook only acts on alerts the boss lists (so each still has its Settings switch).

## What to aim for

Only the mechanics that wipe raids or kill people (the plan's list, below). 3 to 6 alerts for most bosses, more only
for long multi-phase fights. Interrupt calls are left out on purpose (the strategy board's rotation does them).
English text, short, the plan's wording style: "Ground Slam: spread out", "Cave In on you", "Enfeeble on you: stay
away from him". No exclamation marks.

## The alert list per boss (from the plan page; adjust where the sources show a better choice, say why)

Karazhan: Attumen (mounts at 25% / Midnight; Intangible Presence on tank: decurse) · Moroes (Vanish then Garrote bar;
Gouge T; Enrage 30%) · Maiden (Repentance bar; Repentance in 5 s H) · Opera Wolf (Little Red Riding Hood: run, you;
next Riding Hood bar) · Opera Romulo (revive in 10 s: kill the other; both together phase 3) · Opera Oz (Roar /
Strawman / Tinhead join bars; The Crone appears) · Curator (Evocation bar; Evocation: burn now; Arcane Infusion 15%) ·
Illhoof (Sacrifice bar; Sacrifice on %t: break the chains) · Aran (Flame Wreath: stand still; Flame Wreath ends bar;
Arcane Explosion: run to the walls; Drinking: Pyroblast next; Elementals 40%) · Netherspite (portal / banish phase
bars; phase change; enrage) · Prince (Enfeeble on you; Shadow Nova; Enfeeble bar; Infernal bar; Phase 3 30%) ·
Nightbane (air phase 75/50/25; lands bar; Bellowing Roar bar; Charred Earth on you).
Gruul's Lair: Maulgar (Whirlwind bar + melee out; Felhunter bar; Maulgar 50%) · Gruul (as in the example above).
Magtheridon: breaks free 2:00; Blast Nova bar + click the cubes; ceiling collapse 30%; Debris on you.
SSC: Hydross (Mark stacks up bar; form change T; adds) · Lurker (Spout bar + dodge; submerge / emerge bar) ·
Leotheras (Demon form bar; Inner Demon on you; Whirlwind; split 15%) · Karathress (Spitfire Totem; Cataclysmic Bolt on
%t H; enrage) · Morogrim (Murlocs bar; Watery Grave bar + on %t; Water Globules 25%) · Vashj (Static Charge on you;
phase 2 70%; Tainted Elemental / Strider / Elite bars; Tainted Core on %t: pass it; phase 3; Persuasion on %t).
TK: Al'ar (Flame Quills bar + off the platform; phase 2 rebirth; Dive Bomb bar; Flame Patch on you) · Void Reaver
(Pounding bar; Arcane Orb on you; Enrage 10:00) · Solarian (Wrath on you: run out; split bar; agents / priests;
Voidwalker 20%) · Kael'thas (Thaladred's gaze on you; weapons phase; advisors revived; Phoenix bar; Shock Barrier +
Pyroblast; Mind control on %t; Gravity Lapse bar).
Hyjal: Waves (next wave bar "Wave x of 8" + a warning per wave) · Winterchill (Death and Decay on you; Icebolt on %t H)
· Anetheron (Infernal bar + on you; Carrion Swarm bar) · Kaz'rogal (Mark bar, shorter each time; Mark + low mana) ·
Azgalor (Doom on you; Howl bar; Rain of Fire on you) · Archimonde (Fear bar; Air Burst on %t; Doomfire on you; Grip
of the Legion: decurse).
BT: Naj'entus (Tidal Shield bar + throw a spine; Impaling Spine on %t) · Supremus (phase bar; fixates you: run;
Volcano under you) · Shade of Akama (channelers down: Shade active) · Teron (Shadow of Death on you 55 s; Shadow of
Death per player H) · Bloodboil (Bloodboil bar; Fel Rage phase bar; Fel Rage on you; Eject T) · Reliquary (Suffering
Frenzy bar; Desire Rune Shield: purge; Deaden bar; Spite on %t H; next essence) · Shahraz (Fatal Attraction on you
+ bar; enrage 10%; berserk) · Council (Veras vanished; Gathios shielded: purge; Consecration / Blizzard /
Flamestrike under you; berserk) · Illidan (Parasitic Shadowfiend on you; phase 2 65%; Eye Blast bar; Dark Barrage on
%t H; phase 3; Demon form bar; Shadow Demons; Agonizing Flames on you; phase 4 30% Maiev; berserk).
ZA: Akil'zon (Electrical Storm bar + on %t: stack under) · Nalorakk (bear / troll form bar; form change T) · Jan'alai
(Hatchers bar; Fire Bombs; 35% every egg) · Halazzi (split 75/50/25; Lightning Totem; Frenzy: tranquilize) · Hex Lord
(Spirit Bolts bar + warning) · Zul'jin (next form 80/60/40/20; Grievous Throw on %t H; Creeping Paralysis; Claw Rage
on you).
Sunwell: Kalecgos (Spectral Blast bar + on you; Curse of Boundless Agony; enrage 10%) · Brutallus (Burn on you + bar;
Meteor Slash bar; Stomp T; Berserk 6:00) · Felmyst (air / ground phase bar; Encapsulate on %t; Demonic Vapor on you;
Deep Breath; berserk) · Eredar Twins (Conflagration on you; Shadow Nova on you; Pyrogenics: spellsteal; berserk) ·
M'uru (Humanoids bar; Void Sentinel bar; Darkness bar; phase 2 Entropius) · Kil'jaeden (Fire Bloom on you; Shield
Orbs bar; Darkness of a Thousand Souls bar + hide behind the shield; Sinister Reflections; Armageddon under you).

Range frames (kind "range"): Maiden (Holy Wrath), Gruul (Ground Slam to Shatter), Vashj (phase 1), Solarian (Wrath),
Naj'entus (Needle Spine), Shahraz (whole fight), Illidan (phase 4), Akil'zon (Static Disruption), Brutallus (Burn),
Felmyst (ground phase), Eredar Twins (whole fight), Kil'jaeden (Fire Bloom). Distances from the sources (DBM
RangeFrame / BW proximity), each cited.
