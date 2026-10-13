# Boss timers B: Hyjal, Black Temple, Zul'Aman, Sunwell (2026-10-13)

Evidence for `Data/BossMods/HyjalSummit.lua`, `BlackTemple.lua`, `ZulAman.lua`, `SunwellPlateau.lua`. Format:
`DATA_FORMAT.md`. Check: `tools/bossmods_check.py HyjalSummit BlackTemple ZulAman SunwellPlateau` (0 problems,
27 bosses, 160 alerts).

Sources (numbers, spell ids, creature ids and the game's own yell texts only):

- **DBM** = `dev/art/bossmod_src/DBM-BurningCrusade/DBM-Raids-BC/<Raid>/<File>.lua:<line>`. `NewCDTimer` = earliest,
  `NewNextTimer` = exact ("next" below).
- **BW** = `dev/art/bossmod_src/BigWigs_BurningCrusade/<Raid>/<File>.lua:<line>`. `CDBar` = cooldown (earliest),
  `Bar` = exact.
- **CM** = cmangos `mangos-tbc` master, `src/game/AI/ScriptDevAI/scripts/<dir>/<file>.cpp:<line>` (dirs: `hyjal` =
  `kalimdor/caverns_of_time/hyjal`, `black_temple` = `outland/black_temple`, `zulaman` = `eastern_kingdoms/zulaman`,
  `sunwell` = `eastern_kingdoms/sunwell_plateau`). `urand(a, b)` ranges in seconds. Emulator values are evidence, not
  truth: where one is far from both logs or a round placeholder that the logs contradict, it is marked *dropped*.

How a value was chosen: one number when the sources agree within about 1.5 s (the earliest of the log-based ones,
so a bar never ends late); a window `{min, max}` over all credible values when they disagree by more, or when a
source says the ability varies. All spell ids pass the 2.5.6 SpellName check (41951, Supremus' fixate, is not in the
client).

## Against the engine (Core/BossMod.lua, read 2026-10-13)

Still missing:

1. **`WIDGET <id> [id...]` trigger.** Hyjal's waves have no combat-log or chat event; DBM
   (`Hyjal/WaveTimers.lua:62-71`) and BW (`Hyjal/Trash.lua:31`, `:88`) read the wave widget (3121 Classic, 528
   retail) and BW the base's enemy counters (3092 Alliance, 3093 Horde). Proposed: UPDATE_UI_WIDGET for those ids
   when the text changes, `ev.spell` = widget id, `ev.amount` = the first number in the text; engage only when the
   wave number is 1 or more. Until it exists `HyjalSummit:Waves` is armed by zone but never starts (`AddTrigger`
   skips the unknown word). The Waves pull then stays up from one boss's waves to the next (no encounter ends it,
   `OnEncounterEnd` keeps `engage`-only fights); the hook copes with that.
2. **`m.t`**: the format doc promises it, the fight object only has `t0`. The Waves and M'uru hooks fall back to
   `GetTime() - m.t0`.

Already as the files need (checked in the code): an event's alerts run before its `fn` hook (`Compile` adds `on`
entries first), so `m:Count` includes the event and a hook's `m:Bar` wins; `m:Phase` starts the new phase's `start`
bars and fires PHASE n; `engage` on a boss with an encounter id waits after ENCOUNTER_START for its own trigger
(Brutallus: ENCOUNTER_START fires at the Madrigosa scene, DBM `Sunwell/Brutallus.lua:10`); YELL / EMOTE carry the
message's target (the Twins' emotes name it at cast start, DBM `Sunwell/EredarTwins.lua:127-129`); `loop` bars.
Two engine facts the data works around: `%s` is the alert's own spell (so no `%s` over several spells), and `me` on
SUMMON compares the summoned unit, not the summoner (Felmyst's vapor uses the debuffs instead).

## Hyjal Summit

### Waves (`HyjalSummit:Waves`)

Gap after wave n (seconds). A wave also comes as soon as every mob of the last one is dead (CM
`hyjal/hyjal.cpp:1137-1138`), so the bar is the latest it can come.

| set | DBM (`WaveTimers.lua:103-110`, `:151-161`) | BW (`Trash.lua:19-22`) | CM (`hyjal.cpp`) | chosen | why |
|---|---|---|---|---|---|
| Winterchill w1-7 | 125 | 127.5 | 130 (`:49-137`) | {125, 130} | 5 s spread |
| Winterchill w8 → boss | 140 | 185 | 190 (`:152`) | {185, 190} | DBM 45 s short, BW and CM agree |
| Anetheron w1-7 / w8 | 125 / 140 | 127.5 / 185 | 130 / 190 (`:174-277`) | same as Winterchill | identical sets |
| Kaz'rogal w1-8 | 135 165 160 165 135 135 195 225 | 135 160 190 165 140 130 195 222 | 130 155 130 155 130 130 155 225 (`:299-410`) | see Horde | |
| Azgalor w1-8 | DBM uses the Kaz'rogal table | 135 190 190 195 140 165 195 225 | 130 190 190 190 130 155 190 225 (`:434-528`) | see Horde | |
| Horde base (both) | | | | {130,135} {155,190} {130,190} {155,195} {130,140} {130,165} {155,195} {222,225} | which boss is next only shows in the gossip (DBM `:34-59`, BW `:127-158`); windows over both bosses |

Wave 1 starts the moment the gossip is picked (CM `hyjal.cpp:1472-1500`); the counter reads 0 when the boss
spawns (CM `:1324-1330`).

### Rage Winterchill

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Death & Decay first | none | none | 21-28 (`boss_rage_winterchill.cpp:74`) | {21, 28} | CM only |
| Death & Decay again | 32 CD, "set to 32 for TBC Classic, maybe 46 on retail" (`RageWinterchill.lua:28`) | none | 45 (`:87`) | {32, 45} | DBM doubts its own value |
| Berserk | 600 (`:30`) | 600 (`Winterchill.lua:30`) | 600 (`:75`) | 600 | agree |

### Anetheron

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Inferno first | none | none | 30-48 (`boss_anetheron.cpp:63`) | {30, 48} | CM only |
| Inferno again | 51 CD, "~55?" (`Anetheron.lua:37`) | 50 CD (`Anetheron.lua:61`) | 50-55 (`:101`) | {50, 55} | DBM unsure |
| Inferno target | target scan at cast start (`:68-71`) | target after 0.7 s (`:62`) | | cast end (SUCCESS) | no scanning in the grammar |
| Carrion Swarm first / again | none | none / 11 CD (`:44`) | 20-28 / 10-15 (`:61`, `:99`) | {20, 28} / {10, 15} | |
| Berserk | none | 600 (`:30`) | 600 (`:64`) | 600 | |

### Kaz'rogal

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Mark first | 45 (`Kazrogal.lua:37`) | 45 (`Kazrogal.lua:45`) | 45 (`boss_kazrogal.cpp:76`) | 45 | agree |
| Mark again | 5 s shorter, stops at 10 (`:43-48`) | 45 - n*5, stops at 5 (`:54-55`) | 45 - min(n,7)*5 = stops at 10 (`:89`, `:135`) | 45 - 5n, stops at 10 (hook) | BW wrong after the 8th Mark |

DBM bug: `OnCombatStart` starts `timerMark` (the 6.2 s "Mark fades" timer, `:28`) with 45 s (`:37`) instead of
`timerMarkCD` (`:29`), so the first Mark bar runs under the wrong option and label.

### Azgalor

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Howl first | none | none | 30 (`boss_azgalor.cpp:78`) | 30 | CM only |
| Howl again | 16.7 CD (`Azgalor.lua:31`) | 16 (`Azgalor.lua:63`) | 18-20 (`:91`) | {16, 20} | |
| Berserk | 600 (`:33`) | 600 (`:43`) | 600 (`:80`) | 600 | |

Doom (20 s, `you`) and Rain of Fire (`you`) are warnings only; CM Doom 45-55 (`:79`, `:92`) has no log support.

### Archimonde

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Fear first | 40 (`Archimonde.lua:51`) | 40 (`Archimonde.lua:47`) | 42-50 (`boss_archimonde.cpp:114`) | {40, 50} | |
| Fear again | 41 CD (`:29`) | 41.5 CD (`:60`) | 42-50 (`:167`) | {41, 50} | |
| Air Burst target | target scan (`:67`) | target after 0.7 s (`:76`) | 30 CD (`:166`) | cast end (SUCCESS) | no scanning |
| Doomfire on you | none | none | 31945 the fire (`:58`) | AURA 31944 + HIT 31945 | 31944 is the client's other "Doomfire" (the burn that stays on you); neither id is in DBM or BW |
| Berserk | 600 (`:32`) | 600 (`:45`) | 600 Hand of Death (`:118`) | 600 | |

## Black Temple

### High Warlord Naj'entus

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Tidal Shield first | 55.5 (`Najentus.lua:41`) | 55, "55-60" (`Najentus.lua:51`) | 60 (`boss_warlord_najentus.cpp:96`) | {55, 60} | BW says it varies |
| Tidal Shield again | 56 CD (`:32`) | 56, "56-60" (`:63`) | 60 (`:108`) | {56, 60} | |
| Impaling Spine | AURA (`:56`) | SUCCESS, faster than the debuff (`:37`) | | both, throttle 3 | |
| Range | none | 8 yd Needle Spine (`:53`) | | 8 | |
| Berserk | 480 (`:34`) | 480 (`:52`) | 480 (`:97`) | 480 | |

### Supremus

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Phase change | 60 (`Supremus.lua:33`) | 60 (`Supremus.lua:72`, `:160`, `:163`) | 60 (`boss_supremus.cpp:129`, `:143`) | 60 | agree |
| Fixate | target scan; 41951 not in Classic (`:25`) | target scan (`:41`) | 41951 server-side (`:49`) | emote "acquires a new target" warn | cannot tell who without scanning |
| Berserk | 900 (`:35`) | 900 (`:70`) | 900 (`:130`) | 900 | |

### Shade of Akama

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Shade active | UNIT_SPELLCAST 40607/40955 (`ShadeOfAkama.lua:124-136`) | first swing (`ShadeOfAkama.lua:169-174`) | Akama casts Fixate 40607 (`boss_shade_of_akama.cpp:248`) | SUCCESS 40607 40955 or the Shade's HP 99 | grammar has no swing trigger |
| Sorcerer | at +1, then 25 (`:65-70`, `:90`) | at the pull, then 25.5 (`:69`, `:126-127`) | | second 25.5, then 25, `loop` | no spawn event, so the bar repeats on its own |
| Defender | at +1, then 30 (`:72-77`, `:89`) | at the pull, 32, then 29.7 (`:68`, `:72`, `:121-122`) | | second 31, then 29.7, `loop` | |
| Side waves | 47 (51 the 2nd) from +1, 51 from +18 (`:43-63`, `:91-93`) | 45 from the pull, 52 from +15 (`:70-71`, `:131-137`) | | left out | the two drift apart |

### Teron Gorefiend

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Shadow of Death first | 9.6, "9.6-13?" (`TeronGorefiend.lua:56`) | 10 (`Teron.lua:34`) | 10 (`boss_teron_gorefiend.cpp:124`) | {9.6, 13} | DBM range |
| Shadow of Death again | 24.5, "24.5-40" (`:39`) | 32, "32-40" (`:44`) | 30-50 (`:137`) | {24.5, 40} | both logs top out at 40 |
| You die | 55 (`:40`) | 55 on Classic (`:54`) | | 55 | |
| Berserk | none | 600 (`:33`) | 600 (`:126`) | 600 | |

### Gurtogg Bloodboil

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Bloodboil first | 10.9 (`Bloodboil.lua:61`) | 10.5 (`Gurtogg.lua:50`) | 11 (`boss_bloodboil.cpp:132`) | 10.5 | |
| Bloodboil again | 10, "10-12, mostly 11" (`:48-49`) | 10 (`:67`) | 11 (`:146`) | {10, 12.5} | merged with the after-rage value |
| Bloodboil after Fel Rage | 12.5 (`:125`) | 10 (`:93`) | 10 (`:230`) | {10, 12.5} | |
| Fel Rage first | 52, "52-58" (`:63`) | 58 (`:53`) | 60 (`:130`) | {52, 60} | |
| Fel Rage again (from its end) | 52 (`:127`) | 52, "52-55" (`:94`) | 60 (`:145`) | {52, 60} | |
| Eject (T) | none | none | 10 then 15, 30 after rage (`:136`, `:150`, `:234`) | 10 / 15 | CM only |
| Berserk | 600 (`:54`) | 600 (`:49`) | 600 (`:131`) | 600 | |

### Reliquary of Souls

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Frenzy first | 49 next (`EssenceOfSouls.lua:78`) | 48 (`Souls.lua:88`) | 45 from the essence's aggro (`boss_reliquary_of_souls.cpp:367`) | 48 | |
| Frenzy again (from its end) | 40 next (`:152`) | 40.5 (`:160`) | 45 from the cast = 37 from the end (`:377`) | 40 | CM's flat 45 *dropped* |
| Next essence | 41 (`:55`, `:184`) | 40 (`:123`, `:128`) | 41 (`:258`) | 40 | |
| Rune Shield first / again | 12.1 / 15 (`:102`, `:67`) | 13 / 15.7 (`:173`, `:178`) | 10-15 / 15 (`:445`, `:456`) | {10, 15} / 15 | |
| Deaden first / again | 26.7 / 31 (`:103`, `:60`) | 27.6 / 31.5 (`:172`, `:183`) | 15 / 30 (`:446`, `:457`) | 26.7 / {30, 31.5} | CM first 15 *dropped* |
| Mana 0 | 160 (`:61`) | 160 (`:171`) | | 160 | |

### Mother Shahraz

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Fatal Attraction first | 24.4 (`Shahraz.lua:94`) | 25 (`Shahraz.lua:50`) | 22-29 (`boss_mother_shahraz.cpp:111`) | {22, 29} | |
| Fatal Attraction again | 20.7, "20-51" (`:42`); its pull log 20.7-28.0 over 16 casts (`:203`) | 24, "extreme variance 24-40+" (`:67`) | 22-40 (`:123`) | {20.7, 28} | the long gaps are casts nobody saw: the cast is not in the log and a full resist leaves no debuff (DBM `:209`) |
| Range | none | 15 on the targets (`:63`) | | 15 all fight | plan |
| Enrage | her emote | none | below 10% (`:159`) | HP 10 | |
| Berserk | none | 600 (`:51`) | 600 (`:110`) | 600 | |

DBM gives Shahraz encounter ids 607 and 2478 (`Shahraz.lua:13`); 2478 is the Reliquary's (`EssenceOfSouls.lua:13`).
Only 607 is used.

### Illidari Council

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Veras returns | 31 (`IllidariCouncil.lua:38`) | 30 (`Council.lua:106`) | | 30 | |
| Berserk | 900 (`:46`) | 900 (`:96`) | 900 (`illidari_council.cpp:160`) | 900 | |

### Illidan Stormrage

| alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Dark Barrage first (from the glaive) | 85 (`Illidan.lua:176`) | 95 (`Illidan.lua:184`) | 77 after the lift-off (`boss_illidan.cpp:503`) | {85, 95} | |
| Dark Barrage again | 44 CD (`:62`) | 50, "50-70 with Eye Blast" (`:208`) | 43-60 (`:1318`) | {44, 70} | |
| Eye Blast again | none | none | 37-65 (`:1309`) | {37, 65} | CM only |
| First Demon Form after the flames | 76 (`:220`) | 14 + 61 = 75 (`:216-220`) | | {75, 76} | |
| Demon Form again (from his line) | 74 human + 60 demon (`:66-67`, `:236`) | 60 + 60 from the form, 14 s after the line (`:297-303`) | 60 human (`:495`) | 134 | DBM and BW agree once the offset is in |
| Demon Form ends | 74 from the line (`:66`) | 60 from the form | 48 + change back (`:895`) | 74 | |
| Shadow Demons | 34 from the line (`:65`) | 25 from the form (`:297`) | 20 after the change (`:498`) | 34 | |
| Demon after Maiev | 92 (`:200`, `:249`) | 30 + 60 = 90 (`:266`, `:275`) | | {90, 92} | |
| Range | 10 in phases 3 and 4 (option text, `localization.en.lua:373`; no range code left in the mod) | none | | 10, phases 3-4 | plan said phase 4 only |
| Berserk | 1500 (`:74`) | 1500 (`:134`) | 1500 (`:408`) | 1500 | |

## Zul'Aman

| boss · alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Akil'zon · Storm first | 46.9 (`Akilzon.lua:32`) | 50 (`Akilzon.lua:29`) | 42 + 8.5 = 50.5 (`boss_akilzon.cpp:94`, `:244`) | {46.9, 50.5} | |
| Akil'zon · Storm again (debuff to debuff) | 34.1, "34-55" (`:24`) | 40 after the 8 s storm = 48 (`:52`) | 54-60 (`:243`) | {34, 60} | DBM's own range is 21 s wide |
| Akil'zon · Range | none | 5 yd Static Disruption (`:30`) | | 5 | |
| Nalorakk · Bear / Troll | 45 / 30 (`Nalorakk.lua:23-24`) | 45 / 30 (`Nalorakk.lua:42`, `:54`) | 45 / 30 (`boss_nalorakk.cpp:176`, `:193`) | 45 / 30 | agree |
| Jan'alai · Hatchers first / again | none / 92 commented out (`Janalai.lua:27`) | 12 / 92 (`Janalai.lua:41`, `:67`) | 10 / 90 (`boss_janalai.cpp:107`, `:292`) | {10, 12} / {90, 92} | |
| Jan'alai · Bombs explode | 12 (`:26`) | 12 (`:71`) | | 12 | |
| Jan'alai · Next Fire Bombs | none | none | 55 then 30 (`:108`, `:303`) | left out | CM only, no log support |
| Jan'alai · Enrage | none | 300 (`:42`) | 300 or 20% (`:105`, `:260`) | 300 | |
| Halazzi · Split | his yell | UNIT_SPELLCAST 43143 | at 25*n % (`boss_halazzi.cpp:258`) | HP 75/50/25 + yell | |
| Malacrass · Spirit Bolts first / again | 30 / 41 CD (`Malacrass.lua:42`, `:37`) | 30 / 40 (`Malacrass.lua:50`, `:59`) | 30 / 10 bolts + 30 (`boss_malacrass.cpp:227`, `:445`) | 30 / 40 | |
| Zul'jin · Creeping Paralysis | 27 CD (`Zuljin.lua:28`) | 27 (`Zuljin.lua:66`) | 27 (`boss_zuljin.cpp:465`) | 27 | agree |
| Zul'jin · Forms | his yells (`Zuljin.lua:59-78`) | CAST 42594/42606/42607/42608 (`Zuljin.lua:45`) | at 80/60/40/20% (`boss_zuljin.cpp:116-119`) | one warning per form on the cast, each sets the phase | |
| Berserk (Akil'zon, Nalorakk, Jan'alai, Halazzi) | 600 | 600 (not Halazzi) | 600 | 600 | |

## Sunwell Plateau

| boss · alert | DBM | BW | CM | chosen | why |
|---|---|---|---|---|---|
| Kalecgos · Spectral Blast first | none | 20 (`Kalecgos.lua:124`) | 15-18 (`boss_kalecgos.cpp:118`) | {15, 20} | |
| Kalecgos · Spectral Blast again | 25 next (`Kalecgos.lua:32`) | 20 (`:315`) | 21-26 (`:306`) | {20, 26} | DBM's "exact" 25 vs BW 20 |
| Brutallus · Burn | 20 / 20 (`Brutallus.lua:39`, `:57`) | 20 / 20 (`Brutallus.lua:65`, `:78`) | 20 (`boss_brutallus.cpp:144`) | 20 | agree |
| Brutallus · Meteor Slash | 12 from cast start (`:36`) | 12 (`:105`) | 11 first and again (`:142`) | first 11, again 12 | first is CM only |
| Brutallus · Stomp | 31 / 31 (`:37`, `:58`) | 30 / 30.5 (`:67`, `:111`) | 30 (`:143`) | 30 | |
| Brutallus · Range | none | 5 yd while burning (`:84`) | | 5, 60 s | |
| Brutallus · Berserk | 360 (`:41`) | 360 (`:64`) | 360 (`:141`) | 360 | |
| Felmyst · Air phase first | 60 (`Felmyst.lua:40`, `:53`) | 60 (`Felmyst.lua:109`) | 60 (`boss_felmyst.cpp:125`) | 60 | |
| Felmyst · Landing | 99 (`:119`) | 100 (`:129`) | | {99, 100} | |
| Felmyst · Deep Breath | 42 then 17 (`:118`, `:39`) | 40.5 then 17 (`:135`, `:122`) | | {40.5, 42} then 17 | |
| Felmyst · Gas Nova first / again | 17 / 19 CD (`:52`, `:36`) | none / 20 (`:86`) | 18-20 / 16-20 after landing (`:129`, `:381`) | {17, 20} / {19, 20} | |
| Felmyst · Encapsulate first / again | none | 30 (`:112`) / none | 20-30 / 30-45 (`:126`, `:457`) | {20, 30} / {30, 45} | repeat is CM only |
| Felmyst · Range | none | 18 yd (`:77`) | | 18 on the ground | |
| Felmyst · Demonic Vapor on you | SUMMON 45392, source = the player (`:89-91`) | same (`:61`, `:90`) | 45399 trail periodic on the player (`boss_felmyst.cpp:70`) | AURA 45399 45402, `me` | the engine's `me` reads the target, not the summoner |
| Twins · Conflagration again | 31 CD (`EredarTwins.lua:41`) | 32 (`Twins.lua:170`) | 35 (`boss_eredar_twins.cpp:267`) | {31, 35} | first only CM 15 (`:125`), left out |
| Twins · Shadow Nova again | 31 CD (`:42`) | none | 35 (`:451`) | {31, 35} | first only CM 35, left out |
| Twins · Range | none | 10 yd (`:70`) | | 10 | |
| M'uru · Humanoids | 15 then 60 (`M'uru.lua:63`, `:29`) | 10 then 60 (`Muru.lua:86`, `:128`) | 15 then 60 (`boss_muru.cpp:37`, `:118`) | {10, 15} then 60, `loop` | DBM and BW run it as a clock; Darkness re-syncs it |
| M'uru · Void Sentinel | 36.5 then 30 (`:64`, `:30`) | 30 then 30 (`:82`, `:121`) | portal at 30 + the summoner (`:34`) | {30, 36.5} then 30, `loop` | as above |
| M'uru · Darkness | 45 next (`:65`, `:31`) | 45 (`:78`, `:104`) | 45 (`:33`) | 45 | |
| M'uru · Black Hole first / again | 22.6 / 15 (`:86`, `:32`) | 27 / 15 (`:143`, `:148`) | 6 + 15 / 11-30 (`:279`, `:321`, `:382`) | {21, 27} / 15 | CM repeat *dropped* (casts Summon Darkness) |
| Kil'jaeden · Fire Bloom first / again | 13.5 from his line / 20 (`Kil'jaeden.lua:84`, `:42`) | none / 20 (`KilJaeden.lua:150`) | 6-10 after he rises / 20-23 (`boss_kiljaeden.cpp:609`, `:893`) | {6, 13.5} / {20, 23} | |
| Kil'jaeden · Darkness after 85/55% | 77 (`:153`, `:161`) | none | 31 s scene + 45 = 76 (`:172-181`, `:743`) | 77 | |
| Kil'jaeden · Darkness after 25% | 57.8 (`:168`) | none | 46 s scene + 17 = 63 (`:184-195`, `:780`) | {57.8, 63} | |
| Kil'jaeden · Darkness again | 45 / 25 last phase (`:45`, `:124`) | 46 / 25 (`:204`, `:207`) | 45 / 25 (`:880`) | 45 / 25 | |
| Kil'jaeden · Shield Orbs | none | none | every 45 s while under the cap (`:914`) | warning only | no reliable bar |
| Kil'jaeden · Berserk | 900 (`:49`) | none | 900 (`:539`) | 900 | |
| Eredar Twins / M'uru · Berserk | 360 / 600 | 360 / 600 | 360 / none | 360 / 600 | |

ENCOUNTER_START for Kil'jaeden fires when he rises, not for the Deceivers (BW `KilJaeden.lua:80`), so his bars use
it; Brutallus uses his pull line (see "engine needs" 6).

## Findings

**Where DBM is likely off**

1. **Hyjal waves.** Before Winterchill's and Anetheron's boss DBM counts 140 s after wave 8 (`WaveTimers.lua:109`),
   BW 185 and CM 190: DBM's bar ends 45 s before the boss. DBM also uses one table for both Horde bosses
   (`:151-161`), while BW and CM give Azgalor's waves 2, 3, 4 and 6 25-35 s longer gaps. And every wave comes early
   when the last one is fully dead (CM `hyjal.cpp:1137`), so all wave bars are "at the latest".
2. **Akil'zon's Electrical Storm** shows as one 34.1 s cooldown, but DBM's own comment says 34-55 (`Akilzon.lua:24`),
   BW sees 48 and CM scripts 54-60: most storms land 15-25 s after DBM's bar ends. Window {34, 60}.
3. **Shahraz's Fatal Attraction**: DBM's comment says 20-51 and BW's 24-40+, but DBM's own 16-cast log is 20.7-28.0
   (`Shahraz.lua:203`). The long gaps are casts no mod saw (no cast event; a full resist leaves no debuff, `:209`).
   Window {20.7, 28}.
4. **Teron's Shadow of Death** cooldown 24.5 hides 24.5-40 (`TeronGorefiend.lua:39`); BW 32-40, CM 30-50.
5. **Kaz'rogal**: DBM starts the 6.2 s "Mark fades" timer with 45 s at the pull (`Kazrogal.lua:37`) instead of the
   next-Mark timer, so the first bar sits under the wrong option. (BW instead shortens the Mark to 5 s after the 8th
   cast; DBM and CM stop at 10.)
6. **Illidan's Dark Barrage**: DBM 44 s, BW 50-70 ("depending on Eye Blast"), CM 43-60; first after the glaive
   DBM 85, BW 95. Window {44, 70} and {85, 95}.
7. **Rage Winterchill's Death & Decay**: DBM 32 with a comment doubting it ("maybe 46"), CM 45. Window {32, 45}.
8. **Kalecgos' Spectral Blast**: DBM claims an exact 25 (`NewNextTimer`), BW 20, CM 21-26. Window {20, 26}.
9. **Archimonde's Fear**: DBM 40/41, CM 42-50 every time. Window {40, 50} / {41, 50}.
10. **Shahraz's encounter id**: DBM lists 2478, the Reliquary's id, for her too (`Shahraz.lua:13`).

**Timers that truly vary** (a window is honest): Akil'zon's storm, Shahraz's Fatal Attraction, Teron's Shadow of
Death, Illidan's Dark Barrage and Eye Blast, Archimonde's Fear, Kalecgos' Spectral Blast, Anetheron's Inferno,
Bloodboil's Fel Rage ({52, 60}: DBM 52-58, BW 52-55, CM 60), Fire Bloom ({20, 23}) and every Hyjal wave.

**Steady ones** (one number; DBM, BW and CM agree within 1.5 s): Supremus' phases (60), Nalorakk's forms (45/30),
Brutallus' Burn (20) and Stomp (30), Zul'jin's paralysis (27), Malacrass' bolts (40), Kaz'rogal's Mark, Gas Nova,
Deep Breath (17), M'uru's Darkness (45), all berserks.

**Where the target comes late**: DBM and BW read the boss's target at cast start for Anetheron's Inferno,
Archimonde's Air Burst, Kil'jaeden's Armageddon and Supremus' fixate. The grammar has no target scan, so these use
the cast's end (or, for Supremus, only the "new target" emote).

**Could not source / left out**: which Horde boss's waves are running (gossip only); Supremus' fixate target
(41951 is not in 2.5.6); Shade of Akama's add waves (DBM and BW disagree and nothing in the log repeats them);
Jan'alai's next Fire Bombs and the first Conflagration / Shadow Nova (CM only); a Shield Orb bar (no source); a
Doom bar for Azgalor (CM only). **CM only but kept** (marked in the files): Eye Blast {37, 65}, Bloodboil's Eject,
Brutallus' first Meteor Slash, Felmyst's repeat Encapsulate, Winterchill's first Death & Decay, Anetheron's first
Inferno and Carrion Swarm, Azgalor's first Howl. **Unverified in a log**: M'uru's add summon spells (46037-46040,
45988; the bars loop and the Darkness hook re-syncs them from the pull clock), the Shade's Fixate 40607 cast,
Doomfire 31944/31945, Felmyst's vapor debuffs 45399/45402, the sorcerer channel 40401/40520.
