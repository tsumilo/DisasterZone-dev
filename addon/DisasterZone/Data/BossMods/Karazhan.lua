if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/Karazhan.lua", ...) then return end -- DisasterZone: boss mods for Karazhan (format: dev/docs/bossmods/DATA_FORMAT.md)
-- Sources per timer in the comments: DBM = DBM-Raids-BC, BW = BigWigs_BurningCrusade, CM = cmangos mangos-tbc
-- scripts, AC = AzerothCore. Numbers only; no code or text from them. Evidence: dev/docs/bossmods/TIMERS_A.md.
-- Chess Event and the Servant Quarters bosses have no mod on purpose.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.BossMods = ns.Data.BossMods or {}
local B = ns.Data.BossMods

B["Karazhan:Attumen"] = {
    enc = { 652, 2444 },
    npc = { 16152, 16151, 15550 },
    phases = { [2] = "Attumen on Midnight" },
    alerts = {
        -- Mount: DBM SUMMON 29799 or the yell, BW SUCCESS 29770, CM Midnight casts 29770 when Attumen is at 25%
        { key = "mount", kind = "warn", spell = 29770, text = "Attumen mounts Midnight", sub = "One target from here on",
          on = { "SUCCESS 29770", "SUMMON 29799", "YELL Come Midnight, let's disperse this petty rabble" },
          setPhase = 2, once = true },
        -- Intangible Presence is cast on the group (BW "on group"); no bar in BW, CM in the DB spell list
        { key = "curse", kind = "warn", spell = 29833, text = "Intangible Presence: decurse", on = "SUCCESS 29833" },
        -- Intangible Presence: DBM 27 on foot, 30.5 mounted (CD timers), BW none, CM DB -> {27, 30.5};
        -- after the mount DBM 20.2 from SUMMON 29799 (the hook)
        { key = "cursebar", kind = "bar", learn = false, spell = 29833, on = "SUCCESS 29833", cd = { 27, 30.5 } },
    },
    fn = {
        ["SUMMON 29799"] = function(m) m:Bar("cursebar", 20.2) end,
    },
}

B["Karazhan:Moroes"] = {
    enc = { 653, 2445 },
    npc = { 15687 },
    alerts = {
        -- Vanish: first DBM 35, BW 35, CM 40 -> {35, 40}; again DBM 35 (its comment: 35.1-51.8), BW 35, CM 42 -> {35, 52}.
        -- No stop at Frenzy: DBM cancels it there, but BW and CM have him keep vanishing below 30%
        { key = "vanish", kind = "bar", spell = 29448, start = { 35, 40 }, on = "AURA 29448", cd = { 35, 52 } },
        -- Garrote after Vanish: CM 9.5 (only source; DBM and BW have no bar) -> 9.5
        { key = "garrote", kind = "bar", spell = 37066, on = "AURA 29448", cd = 9.5 },
        -- Gouge: first DBM 22.6, CM 21 -> {21, 22.6}; again DBM 22.6 (its comment: 22.6-43.6), CM 30-35, BW none
        -- -> {22.6, 43.6}
        { key = "gouge", kind = "bar", spell = 29425, role = "T", start = { 21, 22.6 }, on = "AURA 29425",
          cd = { 22.6, 43.6 } },
        -- Frenzy at 30%: DBM, BW and CM agree; BW: recast after every Vanish, so only the first counts
        { key = "frenzy", kind = "warn", spell = 37023, text = "Frenzy at 30%", sub = "Heal the tank",
          on = "AURA 37023", once = true },
    },
}

B["Karazhan:Maiden"] = {
    enc = { 654, 2446 },
    npc = { 16457 },
    alerts = {
        -- Repentance: DBM var 28-64.7 (pull and repeat; its comment: steady, with one unexplained late cast per
        -- kill), BW first 29.7 then 33 (CD), CM DB spell list -> {28, 64.7} both
        { key = "repentance", kind = "bar", spell = 29511, start = { 28, 64.7 }, on = "CAST 29511", cd = { 28, 64.7 } },
        -- 5 s before the earliest Repentance (28 - 5 = 23)
        { key = "repentsoon", kind = "warn", spell = 29511, role = "H", text = "Repentance soon",
          sub = "Top up the tank", on = { "ENGAGE", "CAST 29511" }, delay = 23 },
        -- Holy Wrath range frame left out: no source gives a jump distance (TIMERS_A.md)
    },
}

-- Opera: ENCOUNTER_START 655 fires for all three plays well before the play starts (BW); each play's own engage
-- line or spell picks the mod.
B["Karazhan:OperaWolf"] = {
    enc = { 655, 2447 },
    npc = { 17521 },
    engage = { "YELL The better to own you with", "AURA 30753", "AURA 30752" },
    alerts = {
        { key = "hoodyou", kind = "you", spell = 30753, text = "Riding Hood on you: run",
          sub = "Kite the wolf around the stage", on = "AURA 30753", me = true },
        -- Little Red Riding Hood: DBM 30 next, BW 30 (from the debuff), CM DB spell list -> 30
        { key = "hoodbar", kind = "bar", spell = 30753, text = "Next Riding Hood", on = "AURA 30753", cd = 30 },
    },
}

B["Karazhan:OperaRomulo"] = {
    enc = { 655, 2447 },
    npc = { 17533, 17534 },
    engage = { "YELL What devil art thou, that dost torment me thus", "CAST 30878", "AURA 30887" },
    phases = { [2] = "Romulo", [3] = "Both together" },
    alerts = {
        -- Act 2 when Julianne goes down in act 1 (DBM and BW: her death in stage 1)
        { key = "act2", kind = "warn", text = "Julianne down: Romulo comes", on = "DIES 17534", phase = 1,
          setPhase = 2 },
        -- Act 3: Julianne revives Romulo (BW CAST 30951 Undying Love, DBM her yell)
        { key = "act3", kind = "warn", spell = 30951, text = "Both are up: kill them together",
          sub = "Within 10 s of each other",
          on = { "CAST 30951", "YELL Come, gentle night; and give me back my Romulo" }, setPhase = 3, once = true },
        -- Revive: CM 10 s both ways; DBM ends the fight only when both die within 10 s -> 10
        { key = "revive", kind = "bar", text = "Revive", icon = 30951, on = "DIES 17533 17534", phase = 3, cd = 10 },
        { key = "revivewarn", kind = "warn", text = "Revive in 10 s: kill the other", icon = 30951,
          on = "DIES 17533 17534", phase = 3 },
    },
}

B["Karazhan:OperaOz"] = {
    enc = { 655, 2447 },
    npc = { 18168, 17535, 17548, 17543, 17547, 17546 },
    -- yell only: the join bars count from Dorothee's opening line, a later spell would start them late
    engage = { "YELL Oh Tito, we simply must find a way home" },
    alerts = {
        -- Roar joins: DBM 12, BW 15, CM 15 (aggro 17 s after spawn, intro line at 2 s) -> {12, 15}
        { key = "roar", kind = "bar", text = "Roar joins", icon = 31013, start = { 12, 15 } },
        -- Strawman joins: DBM 21, BW 25, CM 25 -> {21, 25}
        { key = "strawman", kind = "bar", text = "Strawman joins", icon = 31046, start = { 21, 25 } },
        -- Tinhead joins: DBM 29, BW 35, CM 35 -> {29, 35}
        { key = "tinhead", kind = "bar", text = "Tinhead joins", icon = 31086, start = { 29, 35 } },
        { key = "crone", kind = "warn", text = "The Crone appears", sub = "Dodge the Cyclone", icon = 32334,
          on = "YELL Woe to each and every one of you, my pretties" },
    },
}

B["Karazhan:Curator"] = {
    enc = { 656, 2448 },
    npc = { 15691 },
    alerts = {
        -- Evocation: first DBM 109 (commented out), BW 114 (CD), CM about 110 (a flare every 11 s at 10% mana)
        -- -> {109, 115}; again DBM 115 (commented out; "can come sooner when sparks die early"), BW 115 -> 115
        { key = "evobar", kind = "bar", spell = 30254, start = { 109, 115 }, on = { "AURA 30254", "SUCCESS 30254" },
          cd = 115, stop = "AURA 30403" },
        { key = "evo", kind = "warn", spell = 30254, text = "Evocation: burn now", sub = "He takes extra damage for 20 s",
          on = "AURA 30254" },
        { key = "infusion", kind = "warn", spell = 30403, text = "Arcane Infusion at 15%",
          sub = "No more Evocation: burn him", on = "AURA 30403", once = true },
    },
}

B["Karazhan:Illhoof"] = {
    enc = { 657, 2449 },
    npc = { 15688 },
    alerts = {
        -- Sacrifice: first BW 30.5 (CD), DBM commented out ("30-50?"), CM DB -> {30.5, 50}; again DBM 40.4 from the
        -- debuff ("40.4-47"), BW 41 from cast start (= 40 from the debuff) -> {40, 47}
        { key = "sacbar", kind = "bar", spell = 30115, start = { 30.5, 50 }, on = "AURA 30115", cd = { 40, 47 } },
        { key = "sacrifice", kind = "warn", spell = 30115, text = "Sacrifice on %t: break the chains",
          on = "AURA 30115" },
    },
}

B["Karazhan:Aran"] = {
    enc = { 658, 2450 },
    npc = { 16524 },
    alerts = {
        -- Next special: first BW 5.2, CM 5-10 -> {5.2, 10}; again DBM 28.9, BW 30.6, CM 30 -> {28.9, 30.6}
        { key = "special", kind = "bar", text = "Next special", icon = 30004, start = { 5.2, 10 },
          on = { "CAST 30004", "CAST 29969", "CAST 29973", "SUCCESS 29979" }, cd = { 28.9, 30.6 }, throttle = 5 },
        { key = "wreath", kind = "warn", spell = 30004, text = "Flame Wreath: stand still",
          sub = "Nobody moves until it ends", on = "CAST 30004" },
        -- Flame Wreath ends: DBM 20.2 from the debuff, BW 21 -> 21 (the later one: moving early wipes the raid)
        { key = "wreathend", kind = "bar", spell = 30004, text = "Flame Wreath ends", on = "AURA 29946", cd = 21,
          throttle = 5 },
        -- Arcane Explosion: DBM CAST 29973, BW SUCCESS 29979 (Massive Magnetic Pull, same moment in CM)
        { key = "ae", kind = "warn", spell = 29973, text = "Arcane Explosion: run to the walls",
          on = { "CAST 29973", "SUCCESS 29979" } },
        -- Drinking: BW Mass Polymorph cast -> Pyroblast 15; CM drink stages end with Pyroblast at 10 s + cast -> 15
        { key = "drink", kind = "warn", spell = 29963, text = "Drinking: Pyroblast next", sub = "Heal everyone to full",
          on = "CAST 29963" },
        { key = "pyro", kind = "bar", spell = 29978, on = "CAST 29963", cd = 15 },
        { key = "elementals", kind = "warn", spell = 29962, text = "Water Elementals at 40%",
          on = { "SUCCESS 29962", "SUMMON 29962 37051 37052 37053" }, once = true },
    },
}

B["Karazhan:Netherspite"] = {
    enc = { 659, 2451 },
    npc = { 15689 },
    alerts = {
        -- Banish phase: first DBM 63.5, BW 60, CM 60 -> {60, 63.5}; after the portal phase starts DBM 61.5, BW 58,
        -- CM 60 -> {58, 61.5}. Shadowform 38542 (CM) as a language-free second trigger
        { key = "banishbar", kind = "bar", text = "Banish phase", icon = 38542, start = { 60, 63.5 },
          on = { "EMOTE cries out in withdrawal", "AURAGONE 38542" }, cd = { 58, 61.5 }, throttle = 5 },
        -- Portal phase back: DBM 40, BW 30, CM 30 -> 30 (DBM's 40 contradicts both, see TIMERS_A.md)
        { key = "portalbar", kind = "bar", text = "Portal phase", icon = 30421,
          on = { "EMOTE goes into a nether-fed rage", "AURA 38542" }, cd = 30, throttle = 5 },
        { key = "banish", kind = "warn", text = "Banish phase: spread out", sub = "Netherbreath hits a cone",
          icon = 38523, on = { "EMOTE goes into a nether-fed rage", "AURA 38542" } },
        { key = "portal", kind = "warn", text = "Portal phase: block the beams", icon = 30421,
          on = { "EMOTE cries out in withdrawal", "AURAGONE 38542" } },
        -- Enrage: DBM 540, BW 540, CM 540 (9 min) -> 540
        { key = "enrage", kind = "bar", text = "Enrage", icon = 38688, start = 540 },
    },
}

B["Karazhan:Prince"] = {
    enc = { 661, 2453 },
    npc = { 15690 },
    -- the 60% axe phase changes no timer (DBM), so phase 2 here is the 30% flying-axes part
    phases = { [2] = "Flying axes (30%)" },
    alerts = {
        { key = "enfeeble", kind = "you", spell = 30843, text = "Enfeeble on you: stay away from him",
          sub = "Shadow Nova follows", on = "AURA 30843", me = true },
        -- Enfeeble: DBM 30 next, BW 30, CM 30 (pull and repeat) -> 30; none at 30% (all three)
        { key = "enfeeblebar", kind = "bar", spell = 30843, phase = 1, start = 30, on = "SUCCESS 30843", cd = 30 },
        { key = "nova", kind = "warn", spell = 30852, text = "Shadow Nova", sub = "Enfeebled: stay away from him",
          on = "CAST 30852" },
        -- Shadow Nova: first BW 33.5, CM 35.5 (5 s after Enfeeble) -> {33.5, 35.5}; again DBM 30, BW 31, CM 30 -> 30
        { key = "novabar", kind = "bar", spell = 30852, phase = 1, start = { 33.5, 35.5 }, on = "CAST 30852", cd = 30 },
        -- Shadow Nova below 30%: first DBM 19.2, BW 17, CM 10 (its loop then stops novas: looks broken) -> {17, 19.2};
        -- again DBM 18.1, BW 18 -> 18
        { key = "novabar2", kind = "bar", spell = 30852, phase = 2, start = { 17, 19.2 }, on = "CAST 30852", cd = 18 },
        -- Infernal: no bar from the pull (DBM 14.5, which its own TODO calls a retail value; CM and AC 40)
        -- again DBM 44.7 ("44-48"), CM 45, AC 45 -> {44, 48}
        { key = "infernal", kind = "bar", spell = 37277, text = "Next Infernal", phase = 1,
          on = { "YELL All realities, all dimensions are open to me", "YELL but the legions I command" },
          cd = { 44, 48 } },
        -- Infernal below 30%: DBM 19.3, CM 17, AC 15 -> {15, 19.3}
        { key = "infernal2", kind = "bar", spell = 37277, text = "Next Infernal", phase = 2,
          on = { "YELL All realities, all dimensions are open to me", "YELL but the legions I command" },
          cd = { 15, 19.3 } },
        { key = "axes", kind = "warn", spell = 30891, text = "30%: flying axes", sub = "Faster Infernals, no Enfeeble",
          on = { "HP 30", "YELL How can you hope to stand against such overwhelming power" }, setPhase = 2,
          once = true },
    },
}

B["Karazhan:Nightbane"] = {
    enc = { 662, 2454 },
    npc = { 17225 },
    phases = { [2] = "In the air", [3] = "Landed again" },
    alerts = {
        -- Lands after the pull: BW 34 (from ENCOUNTER_START), DBM 36 (from the summon emote) -> {34, 36};
        -- after take-off DBM 57, BW 57 (CM 45-55 after reaching the air spot) -> 57; landing line -> 14 s (hook)
        { key = "lands", kind = "bar", text = "Nightbane lands", icon = 37098, start = { 34, 36 },
          on = { "YELL Miserable vermin. I shall exterminate you from the air", "HP 75", "HP 50", "HP 25" }, cd = 57,
          throttle = 5 },
        { key = "air", kind = "warn", text = "Nightbane takes off", sub = "Kill the skeletons", icon = 37098,
          on = { "YELL Miserable vermin. I shall exterminate you from the air", "HP 75", "HP 50", "HP 25" },
          setPhase = 2 },
        -- Bellowing Roar: DBM 31.5 (CD), BW 37 (CD), CM 38-48 (post-2.0.3) -> {31.5, 48}; ground only
        { key = "roar", kind = "bar", spell = 36922, phase = { 1, 3 }, on = "CAST 36922", cd = { 31.5, 48 } },
        { key = "charred", kind = "you", spell = 30129, text = "Charred Earth under you: move", on = "AURA 30129",
          me = true },
    },
    fn = {
        -- landing lines: DBM 14 s left (43 of 57 gone), BW 17 after the last skeleton dies -> {14, 17}
        ["YELL Enough! I shall land and crush you myself"] = function(m) m:Bar("lands", { 14, 17 }); m:Phase(3) end,
        ["YELL Insects! Let me show you my strength up close"] = function(m) m:Bar("lands", { 14, 17 }); m:Phase(3) end,
    },
}
