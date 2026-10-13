# Boss timers, part A: evidence (2026-10-13)

Raids: Karazhan, Gruul's Lair, Magtheridon's Lair, Serpentshrine Cavern, Tempest Keep. Data files:
`addon/DisasterZone/Data/BossMods/{Karazhan,GruulsLair,MagtheridonsLair,SerpentshrineCavern,TempestKeep}.lua`
(format: DATA_FORMAT.md). `bossmods_check.py` on these five: 25 bosses, 132 alerts, 0 problems.

## Sources and how to read them

| tag | where | what a number means |
|---|---|---|
| DBM | `dev/art/bossmod_src/DBM-BurningCrusade/DBM-Raids-BC/<Raid>/<File>.lua` | `NewCDTimer` earliest, `NewNextTimer`/`NewTimer` exact, `NewVarTimer("vA-B")` a range |
| BW | `dev/art/bossmod_src/BigWigs_BurningCrusade/<Folder>/<File>.lua` | `CDBar` earliest, `Bar` exact |
| CM | cmangos/mangos-tbc master, `src/game/AI/ScriptDevAI/scripts/...` (read 2026-10-13) | ms in the script; `urand(a, b)` a range. Many bosses keep their spells in DB spell lists (`SetSpellList`), which are not in the script repo: shown as "DB" |
| AC | azerothcore-wotlk master, `src/server/scripts/...` | only as a tiebreaker (Prince, Magtheridon) |

CM paths: Karazhan `eastern_kingdoms/karazhan/`, Gruul `outland/gruuls_lair/`, Magtheridon
`outland/hellfire_citadel/magtheridons_lair/`, SSC `outland/coilfang_reservoir/serpent_shrine/`, TK
`outland/tempest_keep/the_eye/`. Game texts for EMOTE triggers come from CM `sql/scriptdev2/scriptdev2.sql`
(Lurker -1548056, Morogrim -1548041) and the DBM/BW locales.

Window rule used: `{ min, max }` when sources differ by more than 1.5 s or one says it varies. The bar counts to
`min`, so a too-early `min` costs (the bar goes "any moment" early), a too-late `max` is cheap (only shows when the
ability really is late). So an outlier that looks wrong is kept out of `min`, but a late outlier may set `max`.

Spell ids: every id in the five files is in the 2.5.6.69795 SpellName table. Not in the client (so not used):
30629 (Magtheridon debris target), 37866 (Morogrim globules), 38019 / 38242 / 38244 / 38247 (Vashj add summons),
41824 (Al'ar adds), 33362 / 33367 (Solarian agents / priests).

## Karazhan

### Attumen (652, 2444)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| mount (warn, phase 2) | SUMMON 29799 or yell, Attumen.lua:40-55 | SUCCESS 29770, Attumen.lua:27 | Midnight casts 29770 when Attumen is at 25%, boss_midnight.cpp:219-224 | all three triggers | |
| curse (warn) | SpellAnnounce 29833 | "on group", Attumen.lua:39 | DB | warn "decurse" | BW shows it hits the group, not only the tank |
| cursebar | CD 27, mounted 30.5, after mount 20.2 / 25 (Attumen.lua:25,36,44,52) | none | DB | `{27, 30.5}`; 20.2 after SUMMON 29799 (hook) | DBM the only log source; window spans its two values |

### Moroes (653, 2445)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| vanish | CD 35 pull and repeat, comment "35.1-51.8" (Moroes.lua:32) | CDBar 35 (Moroes.lua:36,56) | 40 first, 42 repeat (boss_moroes.cpp:83,118) | start `{35, 40}`, cd `{35, 52}` | DBM's own range for the max |
| garrote | none | none | 9.5 after Vanish (boss_moroes.cpp:245) | 9.5 | CM only |
| gouge (T) | CD 22.6 pull and repeat, comment "22.6-43.6" (Moroes.lua:33) | none | 21 first, 30-35 repeat (boss_moroes.cpp:85,120) | start `{21, 22.6}`, cd `{22.6, 43.6}` | |
| frenzy | AURA 37023 | AURA 37023, removed after first (Moroes.lua:49) | below 30% once | warn, once | |

### Maiden of Virtue (654, 2446)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| repentance | VarTimer 28-64.7 pull and repeat (MaidenOfVirtue.lua:26); TODO: steady with one unexplained reset per kill (:19-20) | CDBar 29.7 first, 33 repeat (Maiden.lua:27,42; "can vary by insane amounts") | DB | `{28, 64.7}` both | measured range from DBM |
| repentsoon (H) | none | none | none | 23 s after pull / each cast | 5 s before the earliest |
| Holy Wrath range | none in this DBM build | none | none | left out | no distance in any source (wowhead lists none for 32445) |

### Opera (655, 2447; ENCOUNTER_START is shared: BigBadWolf.lua:7, TheBigBadWolf.lua:8)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| Wolf engage | combat_yell (BigBadWolf.lua:12) | target/combat | | yell + AURA 30753 / 30752 | spells only the wolf has |
| Wolf hoodbar | Next 30 (BigBadWolf.lua:25) | 30 from applied (TheBigBadWolf.lua:74-75) | DB | 30 | agree |
| Romulo engage | yell RJ_Pull (RomuloAndJulianne.lua:11) | | | yell + CAST 30878 / AURA 30887 | Julianne's spells |
| Romulo act2 | UNIT_DIED 17534 in stage 1 (:85-95) | Death 17534 (RomuloJulianne.lua:72,136) | Julianne drinks poison, Romulo in 12 s (bosses_opera.cpp:678) | DIES 17534, phase 1 | |
| Romulo act3 | yell (:76) | CAST 30951 (:73,146) | Undying Love | both | |
| Romulo revive | both must die within 10 s (:90,100) | none | 10 s self/partner revive (bosses_opera.cpp:686,857,863) | 10 | |
| Oz engage | yell Dorothee (WizardOfOz.lua:11) | yell (WizardofOz.lua engage_trigger) | intro line 2 s after spawn (bosses_opera.cpp:104) | yell only | a spell fallback would start the join bars ~10 s late |
| Roar joins | 12 (WizardOfOz.lua:32) | 15 (WizardofOz.lua:56) | 17 from spawn = 15 from the line (bosses_opera.cpp:291) | `{12, 15}` | |
| Strawman joins | 21 (:33) | 25 (:58) | 27 - 2 = 25 (:178) | `{21, 25}` | |
| Tinhead joins | 29 (:34) | 35 (:60) | 37 - 2 = 35 (:230) | `{29, 35}` | |
| Crone | yell | none | intro 6 s, aggro 9 s | warn on her yell | |

### The Curator (656, 2448)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| evobar | commented out: 109 first, 115 repeat (Curator.lua:27,37); EDIT: "max 115, shorter if sparks die early" (:19) | CDBar 114 first, Bar 115 repeat (Curator.lua:32,43) | flare every 11 s at 10% mana, Evocation at the 10th: about 110 (boss_curator.cpp:90,123,216-229) | start `{109, 115}`, cd 115 | |
| evo / infusion | AURA 30254 / 30403 | SUCCESS 30254 / 30403 | below 15% once | warns | |
| (berserk, not used) | 720 (Curator.lua:29) | 600 (Curator.lua:31) | 10 min (boss_curator.cpp:89) | | DBM is 2 min late |

### Terestian Illhoof (657, 2449)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| sacbar | first commented out "30-50?" (TerestianIllhoof.lua:33); CD 40.4 from the debuff, "40.4-47" (:28) | CDBar 30.5 first; 41 from cast start (Terestian.lua:37,79,94-95) | DB | start `{30.5, 50}`, cd `{40, 47}` | BW 41 from cast start = 40 from the debuff |

### Shade of Aran (658, 2450)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| special | 28.9 from cast start, no first (ShadeOfAran.lua:32) | 5.2 first, 30.6 after (ShadeOfAran.lua:69,96,103,160) | 5-10 first, 30 after (boss_shade_of_aran.cpp:134,424) | start `{5.2, 10}`, cd `{28.9, 30.6}` | |
| wreathend | 20.2 from the debuff (:35) | 21 from the first debuff | | 21 | the later: moving early wipes |
| ae | CAST 29973 | SUCCESS 29979 Massive Magnetic Pull | both cast together | both triggers | |
| drink / pyro | none | Mass Polymorph cast -> Pyroblast 15 (ShadeOfAran.lua:119) | drink stages 2+2+5+1 s, then Pyroblast (boss_shade_of_aran.cpp:295-304,337) | 15 | |
| (berserk, not used) | 900 (:40) | none | 12 min (boss_shade_of_aran.cpp:132) | | DBM 3 min late |

### Netherspite (659, 2451)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| banishbar | 63.5 first, 61.5 after (Netherspite.lua:26,34) | CDBar 60 first, 58 after (Netherspite.lua:81,124) | 60 / 60 (boss_netherspite.cpp:138,270) | start `{60, 63.5}`, cd `{58, 61.5}` | |
| portalbar | 40 (Netherspite.lua:27) | CDBar 30 (Netherspite.lua:132) | 30 (boss_netherspite.cpp:238) | 30 | DBM 10 s late, see findings |
| enrage | 540 | 540 | 9 min (:139) | 540 | agree |

### Prince Malchezaar (661, 2453)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| enfeeblebar | Next 30 pull and repeat (PrinceMalchezaar.lua:37,43) | CDBar 30, 21 after the 9 s debuff (Malchezaar.lua:72,83) | 30 / 30 (boss_prince_malchezaar.cpp:97,280) | 30, phase 1 | none below 30% in all three |
| novabar | none at pull, 30 after (:34,54) | CDBar 33.5 first, 29 after the 2 s cast = 31 (Malchezaar.lua:73,111) | 35.5 first, 5 s after each Enfeeble (:95,281) | start `{33.5, 35.5}`, cd 30 | 1 s spread |
| novabar2 (30%) | 19.2 at the switch, 18.1 after (:34,112) | CDBar 17 at the switch, 16 + 2 (Malchezaar.lua:109,141) | 10 at the switch, then the nova action is disabled (:224,263-266) | start `{17, 19.2}`, cd 18 | CM's phase-3 nova loop looks broken |
| infernal | 14.5 from pull (:42), 44.7 after the line, "44-48" (:86) | yell only, 17 to Hellfire | 40 first, 45 after (:94,254); AC same (boss_prince_malchezaar.cpp:211,236) | no pull bar; cd `{44, 48}` | DBM's TODO (:22) says its timers are retail values; emulators share one lineage |
| infernal2 | 19.3 after the line, 40 at the switch (:86,115) | | 15 at the switch, 17 after (:226,254); AC 15 | cd `{15, 19.3}` | |

### Nightbane (662, 2454)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| lands | 36 from the summon emote; 57 after take-off; 14 left after the landing line (Nightbane.lua:32,34,95-99) | 34 from engage, 57 after take-off, 17 after the last skeleton dies (Nightbane.lua:71,109,122) | air phase 45-55 after reaching the spot (boss_nightbane.cpp:320) | start `{34, 36}`, cd 57, landing line `{14, 17}` (hook) | |
| roar | CD 31.5 (Nightbane.lua:33) | CDBar 37 (Nightbane.lua:94); 36 / 61 after landing | 38-48 post-2.0.3 (boss_nightbane.cpp:380), 10 s after each landing (:307) | cd `{31.5, 48}`, no first bar | first-after-landing: BW 35-60 vs CM 12, no agreement |

## Gruul's Lair

### High King Maulgar (649, 2455)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| wwbar | CD 58 first, 55 after (Maulgar.lua:36,43) | CDBar 59 first, 60 from the buff (Maulgar.lua:76,130-131) | 30 first, 30-40 after (boss_high_king_maulgar.cpp:90,166) | start 58, cd `{55, 60}` | CM disagrees with both logs by ~25 s: left out |
| felhunter | CD 48.5 from SUCCESS (Maulgar.lua:38) | Bar 50 from CAST (Maulgar.lua:109) | 10 first, 25-35 after (:217,234) | `{48.5, 50}` from CAST, stop on Olm's death | CM again far off |
| flurry | none | SUCCESS 33232 (Maulgar.lua:70,148) | below 50% (:145) | SUCCESS 33232 + HP 50 | |

### Gruul (650, 2456), re-checked
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| growth | Next 30 (Gruul.lua:36) | Bar 30 (Gruul.lua:42,60) | 30 (boss_gruul.cpp:72) | 30 | unchanged. BW: after 30 stacks the next is 300 s (Gruul.lua:66); not modelled |
| slam | CD 40 first, 74 after, "74-80" (Gruul.lua:37,45) | CDBar 33 first, 62 after Shatter (Gruul.lua:40,91) | 35-40, 70-80 (boss_gruul.cpp:75,145) | `{33, 40}`, `{72, 80}` | unchanged |
| reverb (H) | commented: 15 s after the 3rd Growth = 105; "32-48" (Gruul.lua:39,74) | CDBar 102 first, 31 after (Gruul.lua:41,72) | 115 first, 35-45 after (boss_gruul.cpp:74,155) | start `{102, 115}` (was 102), cd `{31, 48}` | first one varies across sources |
| range | TODO: 11 / 13 / 18 yd, 18 default (Gruul.lua:22) | none | | 18 (was 15) | Shatter 33671 radius 20 yd (wowhead spell page, client data) |
| hurtful (T) | none | none | 8 (boss_gruul.cpp:168) | 8 | unchanged |

## Magtheridon's Lair (651, 2457)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| free | 120 (Magtheridon.lua:31) | 120 (Magtheridon.lua:88) | | 120; stop AURAGONE 30205 / yell | AC 120 too |
| novabar | CD 54 at release and after (Magtheridon.lua:32,56,70) | CDBar 58 at release, 51 after (Magtheridon.lua:101,152) | DB (boss_magtheridon.cpp:237); AC 3 s + 55.65 first, 54.35-55.4 after, +7 s when Quake delays it (boss_magtheridon.cpp:162,170-175) | start `{54, 59}`, cd `{51, 55.4}` | |
| collapse | Next 15 after the line (Magtheridon.lua:33) | message only | 5 + 8 = 13 (boss_magtheridon.cpp:230-233,284) | `{13, 15}` | AC 15 (boss_magtheridon.cpp:106-113) |
| Debris on you | none | AURA 36449 on you (Magtheridon.lua:70,157) | debris targets a trigger creature (AC boss_magtheridon.cpp:117-120, 30629 not in the client) | left out | 36449 is AC's collapse damage on everyone (boss_magtheridon.cpp:60,113), not a targeted debris |

## Serpentshrine Cavern

### Hydross (623, 2458)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| mark | 16 first and after a form change, 15 after a mark (Hydross.lua:36,54,88,91) | 15 everywhere (Hydross.lua:75,122,138,146) | DB (boss_hydross_the_unstable.cpp:62-64,108) | `{15, 16}` | 1 s, kept as a window so one bar serves both triggers |
| frost / nature (T), adds | SUCCESS 25035 by 22035 / 22036 | SUCCESS 25035 | spawns cast 25035 | src-filtered warns | |
| range | none | proximity 10 in frost form (Hydross.lua:77,139,147) | | 10, toggled by hook | not in the plan list; BW has it, Water Tomb splash |

### The Lurker Below (624, 2459)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| spoutbar | CD 37 first, 50 after (TheLurkerBelow.lua:33,74) | Bar 37 / 50 (Lurker.lua:73,109) | 42 first, 45 after (boss_the_lurker_below.cpp:96,263) | `{37, 42}`, `{45, 50}` | |
| spout after emerging | legacy: 3 s (TheLurkerBelow.lua:65) | 65 after dive vs 64 emerge (Lurker.lua:160-162) | about 5 s (boss_the_lurker_below.cpp:198) | `{1, 5}` (hook) | |
| submerge | 90 first, 105 after emerge (TheLurkerBelow.lua:31,75) | 90 / 90 (Lurker.lua:81,176) | 90 first, 120 after emerge (boss_the_lurker_below.cpp:95,197) | 90, cd `{90, 120}` | |
| emerge | 60 (TheLurkerBelow.lua:32) | 64 (Lurker.lua:160) | 60 + 3 (boss_the_lurker_below.cpp:240) | `{60, 64}` | |

Triggers: Spout = raid emote "%s takes a deep breath!" (CM text -1548056). Submerge = aura 28819 (CM removes it
on emerge); DBM reads it from UNIT_SPELLCAST_SUCCEEDED and asks whether that works in Classic
(TheLurkerBelow.lua:23). Needs an in-game check.

### Leotheras (625, 2460)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| demon | 60 after release, 60 + 60 cycle (Leotheras.lua:42,132,156-157) | 60, then 45 after demon ends (Leotheras.lua:95,134) | 60 / 60 (boss_leotheras_the_blind.cpp:96,311,328) | start 60, cd `{105, 120}` | |
| demonends | 60 | 60 (:145) | 60 | 60 | |
| innerbar | CD 23 (Leotheras.lua:43) | 23 (:144) | 20 (boss_leotheras_the_blind.cpp:330) | `{20, 23}` | |
| whirl | CD 27, 15 first, 22.5 after split (Leotheras.lua:40,131,166) | 15 after release and after each demon form (:122,147) | 18 first, 32 after, 1-10 after human / split (:97,245,310,348) | cd `{27, 32}`; hooks: `{15, 18}`, `{61, 75}`, `{13, 22.5}` | |

### Fathom-Lord Karathress (626, 2461)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| boltbar (H) | none | none | 10 first and after (boss_fathomlord_karathress.cpp:112,190) | 10 | CM only |
| enrage | 600 (Fathomlord.lua:28) | 600 (Karathress.lua:55) | 10 min (:114) | 600 | agree |

### Morogrim Tidewalker (627, 2462)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| murlocs | 41 first, 51 (Tidewalker.lua:30,48) | 40, 51 (Morogrim.lua:72,103) | 40, 50 (boss_morogrim_tidewalker.cpp:108,208) | 40, 51 | 1 s spreads |
| grave | CD 20 first, 28.5 (Tidewalker.lua:29,47) | 20, 28.5 (Morogrim.lua:73,90) | 30, 30 (:110,223) | 20, `{28.5, 30}`; stop at 25% | CM's first is just its repeat value |
| globulebar | none | 36 = how long they last (Morogrim.lua:109) | 25 (:233) | 25 | CM only |

### Lady Vashj (628, 2463)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| elemental | 45, comment "46-57 variation" (Vashj.lua:45,151,186) | 53 at P2 and after death (Vashj.lua:107,147) | 53 at P2, 50 after death or despawn (boss_lady_vashj.cpp:564,375) | `{46, 57}` both | DBM's measured range |
| strider | 63 / 63 (Vashj.lua:46,64,188) | 63 / 63 (:152-154) | 62 / 60 (:563,500) | 63, cd `{60, 63}` | repeat trigger AURA 38257 (Panic Periodic on the strider, CM), untested |
| elite | 47.5 / 47.5 (:47,71) | 47.5 / 47.5 (:158-160) | 47 / 46 (:562,491) | first only: 47.5 | no spawn event for repeats (summon spells not in the client) |
| range | none | proximity 10 on Static Charge (Vashj.lua:127) | Static Charge only in phases 1 and 3 (:471, P2 disables it) | 10, phases 1 and 3 | |
| Persuasion | commented "Pre nerf for classic TBC" (Vashj.lua:35) | none | only under PRENERF_2_0_3 (boss_lady_vashj.cpp:467-469) | left out | 2.5.x is post-nerf |

## Tempest Keep

### Al'ar (730, 2464)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| quillsbar | cast timer 10 (Alar.lua:28) | none | quills replace a platform move at 50% odds (boss_alar.cpp:481) | 10 (how long) | no way to time the next one |
| rebirth | SPELL_HEAL 34342 (Alar.lua:18,120) | scan | | SUCCESS / HIT 34342 | no HEAL trigger in our grammar |
| dive | 30 first, CD 52 (Alar.lua:29,126) | CDBar 52 (Alar.lua:64) | 30 first, 50-60 after (boss_alar.cpp:454,516) | 30, `{52, 60}` | triggers untested: DBM and BW use target scanning |
| (berserk, not used) | 600 from rebirth (Alar.lua:125) | 620 from the pull (Alar.lua:32) | 10 min from rebirth (boss_alar.cpp:453) | | BW counts from the wrong moment |

### Void Reaver (731, 2465)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| pounding | CD 13 pull and repeat (VoidReaver.lua:27) | CDBar 13 (Reaver.lua:61) | 12 first, 14 after (boss_void_reaver.cpp:61,110) | 12, 13 | 1 s spreads |
| enrage | 600 | 600 | 10 min (:60) | 600 | |

### High Astromancer Solarian (732, 2466)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| split | 50 / 90 (Solarian.lua:33,42) | 50 / 90 (Solarian.lua:68,107) | 50; line at +1, next 1 + 5 + 16 + 70 = 92 line to line (boss_astromancer.cpp:123,317,240,249,273) | 50, `{90, 92}` | |
| agents | 4 after the line (:34) | 6 (:112) | 5 (:240) | `{4, 6}` | |
| priests | 20 (:35) | 22 (:116) | 21 (:249) | `{20, 22}` | |
| range | none | none | | 10 yd while Wrath is on you | 42784 explosion radius 8 yd (wowhead spell page) |

### Kael'thas (733, 2467)
| alert | DBM | BigWigs | cmangos | chosen | why |
|---|---|---|---|---|---|
| advisor | Thaladred 32, Sanguinar 12.5, Capernian 7, Telonicus 8.4 (KaelThas.lua:87,223-227) | 32, 13, 7, 8 (Kaelthas.lua:112,203,211,216) | 23 + 7 = 30, 12.5, 7, 8.4 (boss_kaelthas.cpp:274,682,698,714,730) | `{30, 32}`, 12.5, 7, 8 | |
| revivebar | 104.6 from the weapons line (KaelThas.lua:230-232) | 105 (Kaelthas.lua:221) | 120 from the weapons spell, post-2.1 (boss_kaelthas.cpp:481) | `{104.6, 120}` | two logs agree on 105; CM only widens the max |
| kaelbar | 10 + 173 = 183, "123 pre nerf, 183 post nerf" (KaelThas.lua:235-236) | Classic 120, else 180 (Kaelthas.lua:226) | 6 + 180 post-nerf, 120 pre-2.0.3 (boss_kaelthas.cpp:773,791-793) | `{183, 186}` | BW's Classic value is the pre-nerf one |
| phoenix | 50 at P4, CD 45, 137 at P5, 90 in P5 (KaelThas.lua:56,167,243,252) | 45 (Kaelthas.lua:170) | DB | hooks: 50 / 45 / 137 / 90 | |
| barrier | CD 60, 60 at P4 (KaelThas.lua:58,244) | Pyroblast 60 at P4 (Kaelthas.lua:184,230) | DB | 60 / 60 | |
| gravity | Next 92, 60 at P5 (KaelThas.lua:59,251) | 90, 60 at P5 (Kaelthas.lua:176,238) | DB | 60, `{90, 92}` | |

## Findings: where DBM is likely off

1. **Netherspite banish phase.** DBM's banish timer is 40 s (Netherspite.lua:27); BigWigs (Netherspite.lua:132) and
   cmangos (boss_netherspite.cpp:238) both have 30 s. DBM's "portal phase" bar therefore ends ~10 s after the
   portals are back, every cycle. Its first portal-phase bar (63.5, :34) is also 3.5 s later than BW / CM (60).
2. **Oz join timers are early by 3-6 s.** DBM 12 / 21 / 29 (WizardOfOz.lua:32-34) against BW 15 / 25 / 35
   (WizardofOz.lua:56-60) and CM 15 / 25 / 35 counted from the same opening line (bosses_opera.cpp:104,178,230,291).
   The spread grows with each actor, which looks like a wrong base rather than noise.
3. **Wrong berserks.** Curator: DBM 720 (Curator.lua:29) vs BW 600 and CM 10 min. Aran: DBM 900 (ShadeOfAran.lua:40)
   vs CM 12 min. Al'ar: BW 620 from the pull (Alar.lua:32) while DBM and CM count 10 min from the rebirth. (No
   berserk alerts were added for these, per the plan list.)
4. **Prince's first Infernal.** DBM starts a 14.5 s Infernal bar at the pull (PrinceMalchezaar.lua:42) and its own
   TODO says the timers are retail values that are probably wrong for Classic (:22). CM and AC both say 40 s.
   With no log-based value, we show no pull bar, only the yell-based repeats.
5. **Moroes.** DBM's Gouge cooldown bar is created with the Vanish spell id 29448 (Moroes.lua:33), so it shows up
   as a second "Vanish" bar. DBM also cancels the Vanish bar at Frenzy (Moroes.lua:77-79), but BW notes he
   keeps vanishing and recasting Frenzy after it (Moroes.lua:49) and CM never stops Vanish.
6. **Variance DBM shows as one number.** Moroes Vanish 35 shown, 35.1-51.8 in its comment (Moroes.lua:32);
   Gouge 22.6 vs 22.6-43.6 (:33); Illhoof Sacrifice 40.4 vs 40.4-47 (TerestianIllhoof.lua:28); Vashj Tainted
   Elemental 45 vs "46-57" (Vashj.lua:45, so its bar is 1 s early even at best); Gruul Ground Slam 74 vs 74-80
   (Gruul.lua:37). Maiden is the one place DBM does show a range (28-64.7, MaidenOfVirtue.lua:26). All are
   windows here.
7. **First timers missing or disabled in DBM.** Curator Evocation (commented out, Curator.lua:27,37), Illhoof
   Sacrifice (commented out, TerestianIllhoof.lua:33), Shade of Aran first special (none; BW 5.2, CM 5-10),
   Prince Shadow Nova (none at the pull; BW 33.5, CM 35.5), Gruul Reverberation (commented out). All have a
   start window here.
8. **Kael'thas phase 3 to 4.** DBM 183 (KaelThas.lua:236) and CM 186 agree on the post-nerf value; BigWigs uses
   120 on Classic (Kaelthas.lua:226), which is the pre-nerf number in both DBM's comment and CM's #ifdef. Phase 2
   to 3: DBM 104.6 / BW 105 vs CM 120.
9. **Things DBM listens to that need care.** Lurker submerge comes from UNIT_SPELLCAST_SUCCEEDED and its own
   comment doubts it works in Classic (TheLurkerBelow.lua:23); Al'ar's dive bomb and platforms come from target
   scanning (Alar.lua:41-43 says it is inaccurate); Al'ar phase 2 from SPELL_HEAL only. Vashj adds and Lurker
   emerge are blind loops (Vashj.lua:60-72), so they drift from reality after the first spawn.
10. **Emulator values that look made up.** Maulgar Whirlwind 30 / 30-40 and Felhunter 10 / 25-35 (CM) contradict
    both log sources by ~25 s; Morogrim's first Watery Grave 30 is just its repeat value; Prince's phase-3 nova
    loop disables itself after one cast (boss_prince_malchezaar.cpp:263-266). Kept out of `min`.

Abilities that truly vary (window is honest, not a guess): Maiden Repentance, Moroes Vanish and Gouge, Illhoof
Sacrifice, Vashj Tainted Elemental, Nightbane Bellowing Roar (CM urand 38-48), Gruul Ground Slam and
Reverberation, Lurker submerge cycle, Al'ar Dive Bomb (CM urand 50-60), Magtheridon Blast Nova (AC: 54-55 s plus
Quake delays).

## Not sourced / not possible with the format

- **Maiden Holy Wrath range frame**: no source gives a distance (no DBM range frame in this build, BW none,
  wowhead lists no radius or jump range for 32445). Left out; the plan wants it.
- **Magtheridon "Debris on you"**: no player-targeted event exists (see the table). Left out.
- **Vashj Persuasion**: pre-2.0.3 only. Left out; replaced by "Toxic Spores under you" (DBM has it).
- **Prince first Infernal** and **Nightbane first Roar after landing**: sources disagree with no log anchor. No bar.
- **Repeating timers with no event** (Vashj Coilfang Elite every 46-47.5 s; DBM and BW just loop): the format has
  no self-repeating bar, and the summon spells (38242 / 38247) are not in the 2.5.6 client. First spawn only. A
  `loop = true` bar field (restart itself after `cd`) would cover it.
- **Untested triggers** (chosen from emulator spell ids, need one in-game pull): Lurker AURA / AURAGONE 28819,
  Vashj AURA 38257 (strider spawn), Al'ar SUCCESS / AURA 35367 and SUCCESS / HIT 35181 (dive bomb), Al'ar
  SUCCESS / HIT 34342 (rebirth), Netherspite AURA / AURAGONE 38542 (Shadowform, next to the emotes), Leotheras
  AURAGONE 37546 / AURA 37673 (next to the yells), Kael CAST / SUCCESS 36976 and 36450.
- **Language**: Opera Oz and Romulo engage, Solarian splits, Kael's phase 4 and advisor lines, Vashj phase 3 are
  English yells only (no spell or health mark exists for them).

## Engine assumptions these files rely on

- `start` on an alert with a single `phase` counts from that phase's start. No alert combines `start` with a
  phase list.
- `fn` keys that appear in no alert's `on` (Kael's advisor lines, Leotheras's `PHASE 2/3`, Nightbane's landing
  lines) are still listened to.
- `ev.npc` in a hook is the source creature id (Hydross's range toggle).
- `%t` and `me` work for EMOTE triggers through the emote's target name (Kael's gaze), like DBM's 5th argument.
