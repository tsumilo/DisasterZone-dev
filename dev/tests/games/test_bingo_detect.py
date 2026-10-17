"""Council Bingo detection (Games/Bingo/Detect.lua) on the real addon.

Covers the core squares (boss timing, kills with few alive, combat log, class moments, the /roll 1 square, ready
checks, releases + idle time, raid chat, enrage kills, three rezzes, mass disconnects, Divine Intervention,
one-shots) and the raid-pool rule engine: every rule kind (damage taken, auras, casts, summons, killing blows by
spell / npc / aura / fall, spreads, deaths in a window or a fight, npc deaths early in a fight, aura stacks, boss
emotes, per-fight tallies at the kill, encounter filters), and that a raid's rules never run outside that raid.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_bingo_detect.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, no_errors, World, Client  # noqa: E402

REALM = "Thunderstrike"
GROUP_PLAYER = 0x400 + 0x4      # TYPE_PLAYER | AFFILIATION_RAID
GROUP_PET = 0x1000 + 0x4
HOSTILE = 0x800 + 0x40 + 0x8    # TYPE_NPC | REACTION_HOSTILE | AFFILIATION_OUTSIDER
TEN = ("Ann", "Cid", "Dee", "Eve", "Fay", "Gus")


def raid(names=("Lee", "Rita", "Sam", "Bob"), leader="Lee", assistants=(), extra=()):
    w = World()
    c = {}
    for n in names:
        c[n] = Client(w, n, guild_rank=3)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    w.make_raid(list(c.values()), leader=c[leader], assistants=[c[a] for a in assistants], extra_members=list(extra))
    w.tick(5)
    return w, c


def hits(cl):
    return cl.eval_py("local g = ns.Bingo:GetGame(); if not g then return {} end; "
                      "local t = {}; for id in pairs(g.hits) do t[#t+1] = id end; table.sort(t); return t") or []


def who(cl, sq):
    return cl.eval("return ns.Bingo:GetWho(...)", sq)


def cleu(cl, sub, src=GROUP_PLAYER, dst=GROUP_PLAYER, *params):
    args = [0, sub, False, "src", "Src", src, 0, "dst", "Dst", dst, 0] + list(params)
    cl._call("combat_log", *args)


def cleu_g(cl, sub, src_guid, src, dst_guid, dst, *params):
    """cleu() with explicit source / destination GUIDs."""
    args = [0, sub, False, src_guid, "Src", src, 0, dst_guid, "Dst", dst, 0] + list(params)
    cl._call("combat_log", *args)


def start(w, c, host="Lee"):
    c[host].slash("/dz bingo start")
    w.tick(2)
    return c[host]


# -- named units for the raid rules: (guid, name, flags) ---------------------------------------------------------

NOBODY = ("", "", 0)


def npc(name, n=1):
    return ("Creature-0-0-0-0-%d-%s" % (n, name.replace(" ", "")), name, HOSTILE)


def pl(c, name):
    return (c[name].guid, name, GROUP_PLAYER)


def ev(cl, sub, src, dst, *params):
    cl._call("combat_log", 0, sub, False, src[0], src[1], src[2], 0, dst[0], dst[1], dst[2], 0, *params)


def dmg(cl, src, dst, sid, name, amount=1000, overkill=-1):
    ev(cl, "SPELL_DAMAGE", src, dst, sid, name, 1, amount, overkill, 1, 0, 0, 0, False, False, False)


def swing(cl, src, dst, amount=1000, overkill=-1):
    ev(cl, "SWING_DAMAGE", src, dst, amount, overkill, 1, 0, 0, 0, False, False, False)


def aura(cl, src, dst, sid, name, sub="SPELL_AURA_APPLIED", stacks=None):
    params = [sid, name, 1, "DEBUFF"] + ([stacks] if stacks is not None else [])
    ev(cl, sub, src, dst, *params)


def cast(cl, src, sid, name, sub="SPELL_CAST_SUCCESS", dst=NOBODY):
    ev(cl, sub, src, dst, sid, name, 1)


def die(cl, unit):
    ev(cl, "UNIT_DIED", NOBODY, unit)


def in_raid(w, c, key):
    """A started game whose host is forced into raid `key` (Detect:SetRaid)."""
    lee = start(w, c)
    lee.eval("ns.BingoDetect:SetRaid(...)", key)
    assert lee.eval("return ns.BingoDetect:GetRaid()") == key
    return lee


# -- core squares (moved from test_bingo.py) ------------------------------------------------------------------------

@case
def encounters_wipes_and_kills():
    w, c = raid()
    start(w, c)
    w.encounter(652, "Attumen", success=False)
    w.tick(1)
    assert "wipe" in hits(c["Sam"]) and "wipe_twice" not in hits(c["Sam"])
    w.encounter(652, "Attumen", success=False)
    w.tick(1)
    assert "wipe_twice" in hits(c["Sam"])
    w.encounter(652, "Attumen", success=True)
    w.tick(1)
    h = set(hits(c["Rita"]))
    assert {"flawless", "speed_kill", "redemption"} <= h, h
    no_errors(w)


@case
def boss_timing_squares():
    w, c = raid()
    lee = start(w, c)
    w.encounter(652, "Attumen", success=False)          # START and END at once
    w.tick(1)
    assert "instant_wipe" in hits(c["Sam"])
    # the kill after that wipe, with a death 5s before the end
    lee.fire("ENCOUNTER_START", 652, "Attumen", 3, 4)
    w.tick(40)
    cleu(lee, "UNIT_DIED")
    w.tick(5)
    lee.fire("ENCOUNTER_END", 652, "Attumen", 3, 4, 1)
    w.tick(1)
    h = set(hits(c["Sam"]))
    assert {"redemption", "late_death"} <= h and "flawless" not in h, h
    no_errors(w)


@case
def clutch_kill_needs_ten_raiders_and_five_alive():
    w, c = raid(extra=TEN)
    lee = start(w, c)
    for n in ("Sam", "Bob", "Ann", "Cid"):
        w.set_dead(n)
    w.encounter(652, "Attumen", success=True)           # 6 of 10 alive
    w.tick(1)
    assert "flawless" in hits(lee) and "clutch" not in hits(lee)
    w.set_dead("Dee", ghost=True)
    w.encounter(653, "Moroes", success=True)            # 5 of 10 alive
    w.tick(1)
    h = set(hits(c["Rita"]))
    assert "clutch" in h and not ({"no_wipe", "last_one"} & h), h
    no_errors(w)


@case
def kills_with_half_the_raid_dead_and_one_left():
    w, c = raid(extra=TEN)
    lee = start(w, c)
    for n in ("Sam", "Bob", "Ann", "Cid", "Dee", "Eve"):
        w.set_dead(n)
    w.encounter(652, "Attumen", success=True)           # 6 of 10 dead: more than half
    w.tick(1)
    h = set(hits(lee))
    assert {"no_wipe", "clutch"} <= h and "last_one" not in h, h
    for n in ("Fay", "Gus", "Rita"):
        w.set_dead(n, ghost=True)
    w.encounter(653, "Moroes", success=True)            # Lee alone
    w.tick(1)
    assert "last_one" in hits(c["Bob"])
    assert who(c["Bob"], "last_one") == "Moroes"
    no_errors(w)


@case
def few_alive_squares_need_ten_raiders():
    w, c = raid()                                       # 4 raiders: never
    lee = start(w, c)
    for n in ("Rita", "Sam", "Bob"):
        w.set_dead(n)
    w.encounter(652, "Attumen", success=True)
    w.tick(1)
    h = set(hits(lee))
    assert not ({"clutch", "no_wipe", "last_one"} & h), h
    no_errors(w)


@case
def combat_log_squares():
    w, c = raid()
    lee = start(w, c)
    sam = c["Sam"].guid
    # near misses: an immune taunt, a small overkill, a fall that doesn't kill
    cleu(lee, "SPELL_MISSED", GROUP_PLAYER, 0, 355, "Taunt", 1, "IMMUNE")
    cleu(lee, "SWING_DAMAGE", 0, GROUP_PLAYER, 3000, 800, 1, 0, 0, 0, False, False, False)
    cleu_g(lee, "ENVIRONMENTAL_DAMAGE", "", 0, sam, GROUP_PLAYER, "Falling", 900, -1)
    w.tick(5)
    h = set(hits(lee))
    assert "fall" in h and not ({"taunt_resist", "overkill", "crushing", "fall_death"} & h), h
    # swing suffix: amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing
    cleu(lee, "SWING_DAMAGE", 0, GROUP_PLAYER, 6000, -1, 1, 0, 0, 0, False, False, True)
    cleu(lee, "SPELL_DAMAGE", 0, GROUP_PLAYER, 30502, "Shadow Nova", 32, 11000, 6000, 32, 0, 0, 0, False, False, False)
    cleu(lee, "SPELL_MISSED", GROUP_PLAYER, 0, 25266, "Mocking Blow", 1, "RESIST")
    cleu_g(lee, "ENVIRONMENTAL_DAMAGE", "", 0, sam, GROUP_PLAYER, "Falling", 4000, -1)
    cleu_g(lee, "UNIT_DIED", "", 0, sam, GROUP_PLAYER)
    cleu(lee, "SPELL_DAMAGE", GROUP_PLAYER, 0, 133, "Fireball", 4, 9000, 0, 4, 0, 0, 0, True)
    cleu(lee, "UNIT_DIED", 0, GROUP_PET)
    cleu_g(lee, "ENVIRONMENTAL_DAMAGE", "", 0, sam, GROUP_PLAYER, "Drowning", 400, -1)
    cleu_g(lee, "ENVIRONMENTAL_DAMAGE", "", 0, sam, GROUP_PLAYER, "Lava", 400, -1)
    w.tick(2)
    assert {"crushing", "overkill", "taunt_resist", "fall_death", "big_crit", "pet_death", "drown",
            "fire", "death_trash"} <= set(hits(c["Rita"])), hits(c["Rita"])
    no_errors(w)


@case
def class_moment_squares():
    w, c = raid()
    lee = start(w, c)
    pala, sam = c["Rita"].guid, c["Sam"].guid

    def cast_(guid, sid, name):
        cleu_g(lee, "SPELL_CAST_SUCCESS", guid, GROUP_PLAYER, "", 0, sid, name, 1)

    cast_(pala, 8690, "Hearthstone")                    # a hearth with no bubble before it
    cast_(pala, 642, "Divine Shield")
    cast_(sam, 8690, "Hearthstone")                     # someone else hearths
    cast_(sam, 27230, "Create Master Healthstone")      # making stones isn't eating one
    lee.fire("ENCOUNTER_START", 652, "Attumen", 3, 4)
    cleu(lee, "SPELL_RESURRECT", GROUP_PLAYER, GROUP_PLAYER, 21169, "Reincarnation", 8)
    w.tick(1)
    h = set(hits(lee))
    assert "ankh" in h and not ({"bubble_hearth", "healthstone", "bres", "divine_intervention"} & h), h
    w.tick(10)
    cast_(pala, 8690, "Hearthstone")                    # 11s after the bubble
    cast_(sam, 351355, "Greater Drums of Battle")       # an id we don't list: matched by name
    cast_(sam, 27154, "Lay on Hands")
    cast_(sam, 27237, "Master Healthstone")
    cast_(pala, 19752, "Divine Intervention")
    cast_(sam, 2825, "Bloodlust")
    # Feign Death 30s before the wipe is too early; 5s before counts
    cast_(sam, 5384, "Feign Death")
    w.tick(30)
    lee.fire("ENCOUNTER_END", 652, "Attumen", 3, 4, 0)
    w.tick(1)
    assert "feign_wipe" not in hits(lee)
    lee.fire("ENCOUNTER_START", 652, "Attumen", 3, 4)
    w.tick(40)
    cast_(sam, 5384, "Feign Death")
    w.tick(5)
    lee.fire("ENCOUNTER_END", 652, "Attumen", 3, 4, 0)
    w.tick(1)
    h = set(hits(c["Bob"]))
    assert {"bubble_hearth", "drums", "loh", "healthstone", "feign_wipe", "divine_intervention",
            "lust"} <= h and "instant_wipe" not in h, h
    assert who(c["Bob"], "divine_intervention") == "Src"
    no_errors(w)


@case
def roll_squares():
    w, c = raid()
    start(w, c)
    for v in (37, 100, 69, 42, 2):
        w.player_roll("Sam", value=v)
        w.tick(1)
    w.player_roll("Sam", value=1, lo=1, hi=1000)        # a 1 on another range isn't the square
    w.tick(1)
    assert hits(c["Bob"]) == [], hits(c["Bob"])
    w.player_roll("Bob", value=1)
    w.tick(1)
    assert hits(c["Bob"]) == ["roll_1"], hits(c["Bob"])
    assert who(c["Rita"], "roll_1") == "Bob"
    no_errors(w)


@case
def ready_check_squares():
    w, c = raid()
    lee = start(w, c)
    # raid1 Lee (started it: auto-ready), raid2 Rita, raid3 Sam, raid4 Bob; Bob never answers
    lee.fire("READY_CHECK", "Lee", 35)
    lee.fire("READY_CHECK_CONFIRM", "raid2", True)
    lee.fire("READY_CHECK_CONFIRM", "raid3", True)
    w.tick(1)
    lee.fire("READY_CHECK_FINISHED", False)
    w.tick(1)
    assert hits(c["Sam"]) == ["rc_asleep"], hits(c["Sam"])
    lee.fire("READY_CHECK", "Lee", 35)
    for u in ("raid2", "raid3", "raid4"):
        lee.fire("READY_CHECK_CONFIRM", u, True)
    lee.fire("READY_CHECK_FINISHED", False)
    w.tick(1)
    assert "rc_all_ready" in hits(c["Sam"]) and "rc_pull" not in hits(c["Sam"])
    lee.fire("READY_CHECK", "Lee", 35)
    lee.fire("READY_CHECK_CONFIRM", "raid3", False)
    w.tick(3)
    w.encounter(652, "Attumen", success=False)
    w.tick(1)
    assert {"rc_pull", "not_ready"} <= set(hits(c["Sam"]))
    no_errors(w)


@case
def premature_release_and_idle_time():
    w, c = raid()
    lee = start(w, c)
    w.set_dead("Bob", ghost=True)                       # still running back from an earlier death
    lee.fire("ENCOUNTER_START", 652, "Attumen", 3, 4)
    w.tick(5)
    cleu_g(lee, "UNIT_DIED", "", 0, c["Sam"].guid, GROUP_PLAYER)
    w.set_dead("Sam")                                   # lying dead is fine
    w.tick(5)
    assert "early_release" not in hits(lee)
    w.set_dead("Sam", ghost=True)
    w.tick(3)
    assert "early_release" in hits(c["Rita"])
    lee.fire("ENCOUNTER_END", 652, "Attumen", 3, 4, 1)
    w.tick(600, step=1)
    cleu(lee, "SWING_DAMAGE", GROUP_PLAYER, 0, 800, -1, 1, 0, 0, 0, False, False, False)
    w.tick(600, step=1)
    assert "idle" not in hits(lee), "fighting resets the idle clock"
    w.tick(320, step=1)
    assert "idle" in hits(c["Rita"])
    no_errors(w)


@case
def raid_chat_squares():
    w, c = raid()
    lee = start(w, c)
    lee.eval("SendChatMessage('OK', 'RAID_WARNING')")
    lee.eval("SendChatMessage('Stack on {skull}', 'RAID_WARNING')")
    c["Sam"].eval("SendChatMessage('sorting my bags, what sorrow', 'RAID')")
    w.tick(1)
    assert hits(lee) == [], hits(lee)
    lee.eval("SendChatMessage('STACK ON {skull} NOW!!', 'RAID_WARNING')")
    c["Sam"].eval("SendChatMessage('oops, sorryyy', 'RAID')")
    w.tick(1)
    assert set(hits(c["Bob"])) == {"caps_warning", "sorry"}, hits(c["Bob"])
    assert who(c["Bob"], "sorry") == "Sam"
    assert who(c["Bob"], "caps_warning") == "Lee"
    no_errors(w)


# -- new core squares -----------------------------------------------------------------------------------------------

@case
def beat_the_clock_needs_a_boss_berserk_and_a_kill():
    w, c = raid()
    lee = start(w, c)
    boss = npc("Void Reaver")
    lee.fire("ENCOUNTER_START", 731, "Void Reaver", 3, 4)
    aura(lee, boss, boss, 26662, "Berserk", sub="SPELL_AURA_APPLIED")
    lee.fire("ENCOUNTER_END", 731, "Void Reaver", 3, 4, 0)      # enraged, but a wipe
    w.tick(1)
    assert "beat_clock" not in hits(lee)
    lee.fire("ENCOUNTER_START", 653, "Moroes", 3, 4)
    aura(lee, npc("Moroes"), npc("Moroes"), 37023, "Enrage")    # Moroes' 30% soft enrage
    aura(lee, pl(c, "Sam"), pl(c, "Sam"), 12880, "Enrage")      # a warrior's own Enrage
    lee.fire("ENCOUNTER_END", 653, "Moroes", 3, 4, 1)
    w.tick(1)
    assert "beat_clock" not in hits(lee)
    lee.fire("ENCOUNTER_START", 731, "Void Reaver", 3, 4)
    aura(lee, boss, boss, 26662, "Berserk")
    w.tick(5)
    lee.fire("ENCOUNTER_END", 731, "Void Reaver", 3, 4, 1)
    w.tick(1)
    assert "beat_clock" in hits(c["Sam"])
    assert who(c["Sam"], "beat_clock") == "Void Reaver"
    no_errors(w)


@case
def phoenix_counts_three_rezzes_in_one_fight():
    w, c = raid()
    lee = start(w, c)
    rita, sam, bob = pl(c, "Rita"), pl(c, "Sam"), pl(c, "Bob")
    ev(lee, "SPELL_RESURRECT", rita, sam, 20748, "Rebirth", 8)          # outside a fight: not counted
    lee.fire("ENCOUNTER_START", 652, "Attumen", 3, 4)
    ev(lee, "SPELL_RESURRECT", rita, sam, 26994, "Rebirth", 8)          # 1
    cast(lee, bob, 20608, "Reincarnation")                              # 2
    ev(lee, "SPELL_RESURRECT", bob, bob, 21169, "Reincarnation", 8)     # (the same ankh)
    ev(lee, "SPELL_RESURRECT", rita, sam, 26994, "Rebirth", 8)          # (Sam again, right away)
    w.tick(1)
    h = set(hits(lee))
    assert {"bres", "ankh"} <= h and "phoenix" not in h, h
    ev(lee, "SPELL_RESURRECT", sam, rita, 27239, "Soulstone Resurrection", 8)    # 3
    w.tick(1)
    assert "phoenix" in hits(c["Bob"])
    assert who(c["Bob"], "phoenix") == "Rita"
    no_errors(w)


@case
def plain_rezzes_after_a_wipe_fill_neither_phoenix_nor_bres():
    # D-1 (2026-10-16): after a wipe the encounter stays open until the boss resets; the raid rezzing up with
    # Resurrection / Redemption / Ancestral Spirit filled Phoenix Down
    w, c = raid()
    lee = start(w, c)
    rita, sam, bob = pl(c, "Rita"), pl(c, "Sam"), pl(c, "Bob")
    lee.fire("ENCOUNTER_START", 652, "Attumen", 3, 4)
    ev(lee, "SPELL_RESURRECT", rita, sam, 25435, "Resurrection", 2)
    ev(lee, "SPELL_RESURRECT", sam, bob, 20773, "Redemption", 2)
    ev(lee, "SPELL_RESURRECT", bob, rita, 20777, "Ancestral Spirit", 8)
    w.tick(1)
    h = set(hits(lee))
    assert not ({"phoenix", "bres"} & h), h
    no_errors(w)


@case
def blizzard_needs_five_different_disconnects_in_ten_seconds():
    w, c = raid(extra=TEN)
    lee = start(w, c)
    for u in ("raid2", "raid3", "raid4", "raid5", "raid2"):
        lee.fire("UNIT_CONNECTION", u, False)
    lee.fire("UNIT_CONNECTION", "raid6", True)                      # coming back isn't a disconnect
    w.tick(1)
    h = set(hits(lee))
    assert "dc" in h and "blizzard" not in h, h
    w.tick(11)
    for u in ("raid6", "raid7", "raid8", "raid9"):
        lee.fire("UNIT_CONNECTION", u, False)
    w.tick(1)
    assert "blizzard" not in hits(lee)                             # the first four were too long ago
    lee.fire("UNIT_CONNECTION", "raid10", False)
    w.tick(1)
    assert "blizzard" in hits(c["Sam"])
    no_errors(w)


@case
def one_shot_needs_a_single_hit_from_full_health():
    # the mock's UnitHealthMax is 100
    w, c = raid()
    lee = start(w, c)
    boss = npc("Gruul the Dragonkiller")
    dmg(lee, boss, pl(c, "Bob"), 33813, "Hurtful Strike", amount=60, overkill=10)    # took 50: not from full
    die(lee, pl(c, "Bob"))
    swing(lee, boss, pl(c, "Rita"), amount=150, overkill=40)                        # 110 from full ...
    w.tick(8)
    die(lee, pl(c, "Rita"))                                                         # ... but not what killed her
    w.tick(1)
    assert "one_shot" not in hits(lee)
    swing(lee, boss, pl(c, "Sam"), amount=150, overkill=52)                         # 98 of 100
    die(lee, pl(c, "Sam"))
    w.tick(1)
    assert "one_shot" in hits(c["Bob"])
    assert who(c["Bob"], "one_shot") == "Sam"
    no_errors(w)


# -- raid pools -----------------------------------------------------------------------------------------------------

@case
def raid_rules_only_run_inside_their_raid():
    w, c = raid()
    lee = start(w, c)
    nightbane, sam = npc("Nightbane"), pl(c, "Sam")
    assert lee.eval("return ns.BingoDetect:GetRaid()") is None
    dmg(lee, nightbane, sam, 30129, "Charred Earth")
    w.tick(1)
    assert hits(lee) == [], hits(lee)
    w.enter_instance("Karazhan", 532)
    w.tick(2)
    assert lee.eval("return ns.BingoDetect:GetRaid()") == "kara"
    dmg(lee, npc("Gruul the Dragonkiller"), sam, 36240, "Cave In")     # Gruul's rule, in Karazhan
    w.tick(1)
    assert hits(lee) == [], hits(lee)
    dmg(lee, nightbane, sam, 30129, "Charred Earth")
    w.tick(1)
    assert hits(c["Rita"]) == ["kara_charred"], hits(c["Rita"])
    assert who(c["Rita"], "kara_charred") == "Sam"
    w.leave_instance()
    w.tick(2)
    assert lee.eval("return ns.BingoDetect:GetRaid()") is None
    w.enter_instance("Gruul's Lair", 565)
    w.tick(2)
    dmg(lee, npc("Gruul the Dragonkiller"), sam, 36240, "Cave In")
    w.tick(1)
    assert "gruul_cavein" in hits(lee)
    no_errors(w)


@case
def raid_damage_aura_cast_and_summon_rules():
    w, c = raid()
    lee = in_raid(w, c, "kara")
    sam, rita = pl(c, "Sam"), pl(c, "Rita")
    dmg(lee, npc("Fiendish Imp"), sam, 30859, "Hellfire")              # Hellfire, but not an infernal's
    dmg(lee, pl(c, "Bob"), sam, 1949, "Hellfire")                      # a warlock's own
    aura(lee, rita, sam, 29538, "Cyclone")                             # from a raider: not the Opera's
    w.tick(1)
    assert hits(lee) == [], hits(lee)
    dmg(lee, npc("Netherspite Infernal"), sam, 30859, "Hellfire")
    aura(lee, npc("Cyclone"), rita, 29538, "Cyclone")
    cast(lee, npc("Echo of Medivh"), 39343, "Fury of Medivh")
    w.tick(1)
    h = set(hits(lee))
    assert h == {"kara_infernal", "kara_cyclone", "kara_medivh"}, h
    assert who(lee, "kara_cyclone") == "Rita" and who(lee, "kara_medivh") == "Echo of Medivh"
    lee.eval("ns.BingoDetect:SetRaid('mag')")
    cast(lee, npc("Hellfire Channeler"), 30511, "Burning Abyssal", sub="SPELL_SUMMON",
         dst=npc("Burning Abyssal", 2))
    cast(lee, npc("Magtheridon"), 30528, "Dark Mending")               # not a channeler
    w.tick(1)
    h = set(hits(lee))
    assert "mag_abyssal" in h and "mag_mending" not in h, h
    cast(lee, npc("Hellfire Channeler"), 30528, "Dark Mending")
    lee.eval("ns.BingoDetect:SetRaid('tk')")
    cast(lee, npc("Lord Sanguinar"), 44863, "Bellowing Roar")
    w.tick(1)
    assert {"mag_mending", "tk_roar"} <= set(hits(c["Sam"]))
    no_errors(w)


@case
def raid_killing_blows_by_spell_npc_and_aura():
    w, c = raid()
    lee = in_raid(w, c, "kara")
    sam, rita, bob = pl(c, "Sam"), pl(c, "Rita"), pl(c, "Bob")
    curator, prince = npc("The Curator"), npc("Prince Malchezaar")
    dmg(lee, curator, sam, 30383, "Hateful Bolt")
    w.tick(6)
    die(lee, sam)                                                      # the bolt was too long ago
    dmg(lee, prince, rita, 30852, "Shadow Nova", overkill=500)         # no Enfeeble on Rita
    die(lee, rita)
    w.tick(1)
    h = set(hits(lee))
    assert not ({"kara_hateful", "kara_enfeebled"} & h), h
    dmg(lee, curator, sam, 30383, "Hateful Bolt", overkill=200)
    die(lee, sam)
    aura(lee, prince, bob, 30843, "Enfeeble")
    w.tick(2)
    aura(lee, prince, bob, 30843, "Enfeeble", sub="SPELL_AURA_REMOVED")
    dmg(lee, prince, bob, 30852, "Shadow Nova", overkill=500)
    die(lee, bob)
    swing(lee, npc("Lady Keira Berrybuck"), rita, overkill=100)
    die(lee, rita)
    w.tick(1)
    h = set(hits(c["Bob"]))
    assert {"kara_hateful", "kara_enfeebled", "kara_dinner"} <= h, h
    assert who(c["Bob"], "kara_enfeebled") == "Bob" and who(c["Bob"], "kara_dinner") == "Rita"
    no_errors(w)


@case
def raid_deaths_with_an_aura_counted_per_fight():
    w, c = raid(extra=TEN)
    lee = in_raid(w, c, "kara")
    wolf = npc("The Big Bad Wolf")
    units = [pl(c, n) for n in ("Rita", "Sam", "Bob")]
    lee.fire("ENCOUNTER_START", 655, "Opera Hall", 3, 10)
    for u in units[:2]:
        aura(lee, wolf, u, 30768, "Little Red Riding Hood")
        swing(lee, wolf, u, overkill=300)
        die(lee, u)
    die(lee, units[2])                                                 # no hood: not eaten
    w.tick(1)
    h = set(hits(lee))
    assert "kara_teeth" in h and "kara_wolfpack" not in h, h
    lee.fire("ENCOUNTER_END", 655, "Opera Hall", 3, 10, 0)
    lee.fire("ENCOUNTER_START", 655, "Opera Hall", 3, 10)              # a new fight: the count starts over
    for u in units[:2]:
        aura(lee, wolf, u, 30753, "Red Riding Hood")
        die(lee, u)
    w.tick(1)
    assert "kara_wolfpack" not in hits(lee)
    aura(lee, wolf, units[2], 30753, "Red Riding Hood")
    die(lee, units[2])
    w.tick(1)
    assert "kara_wolfpack" in hits(c["Sam"])
    no_errors(w)


@case
def raid_spread_and_deaths_in_a_window():
    w, c = raid(extra=TEN)
    lee = in_raid(w, c, "gruul")
    maulgar, gruul = npc("High King Maulgar"), npc("Gruul the Dragonkiller")
    names = ("Rita", "Sam", "Bob", "Ann", "Cid", "Dee")
    units = [pl(c, n) if n in c else (w._member(n).guid, n, GROUP_PLAYER) for n in names]
    dmg(lee, maulgar, units[0], 33239, "Whirlwind")
    dmg(lee, maulgar, units[1], 33239, "Whirlwind")
    dmg(lee, maulgar, units[0], 33239, "Whirlwind")                    # the same raider again
    w.tick(3)
    dmg(lee, maulgar, units[2], 33239, "Whirlwind")                    # the first two were too long ago
    dmg(lee, npc("Krosh Firehand"), units[3], 33239, "Whirlwind")      # not Maulgar's
    w.tick(1)
    assert "gruul_whirl" not in hits(lee)
    dmg(lee, maulgar, units[3], 33239, "Whirlwind")
    dmg(lee, maulgar, units[4], 33239, "Whirlwind")
    w.tick(1)
    assert "gruul_whirl" in hits(lee)
    # Shatter: 2 deaths, a pause, then 3 together
    for u in units[:2]:
        dmg(lee, gruul, u, 33671, "Shatter", overkill=100)
        die(lee, u)
    w.tick(5)
    for u in units[2:5]:
        dmg(lee, units[5], u, 33671, "Shatter", overkill=100)          # (shatter damage from a stoned raider)
        die(lee, u)
    w.tick(1)
    h = set(hits(c["Rita"]))
    assert {"gruul_shatter", "gruul_hug"} <= h and "gruul_rockbottom" not in h, h
    no_errors(w)


@case
def raid_stacks_and_npc_deaths_early_in_a_fight():
    w, c = raid()
    lee = in_raid(w, c, "gruul")
    gruul = npc("Gruul the Dragonkiller")
    aura(lee, gruul, gruul, 36300, "Growth", sub="SPELL_AURA_APPLIED_DOSE", stacks=14)
    w.tick(1)
    assert "gruul_growth" not in hits(lee)
    aura(lee, gruul, gruul, 36300, "Growth", sub="SPELL_AURA_APPLIED_DOSE", stacks=15)
    w.tick(1)
    assert "gruul_growth" in hits(lee) and who(lee, "gruul_growth") == "Gruul the Dragonkiller"
    lee.eval("ns.BingoDetect:SetRaid('mag')")
    for i in range(5):                                                 # outside the encounter: no
        die(lee, npc("Hellfire Channeler", 10 + i))
    lee.fire("ENCOUNTER_START", 651, "Magtheridon", 4, 4)
    for i in range(4):
        die(lee, npc("Hellfire Channeler", i))
    w.tick(121)
    die(lee, npc("Hellfire Channeler", 4))                             # the fifth, too late
    w.tick(1)
    assert "mag_fivedown" not in hits(lee)
    lee.fire("ENCOUNTER_END", 651, "Magtheridon", 4, 4, 0)
    lee.fire("ENCOUNTER_START", 651, "Magtheridon", 4, 4)
    w.tick(30)
    for i in range(5):
        die(lee, npc("Hellfire Channeler", 20 + i))
        w.tick(10)
    assert "mag_fivedown" in hits(c["Sam"])
    no_errors(w)


@case
def mag_counts_blast_novas_to_the_kill():
    w, c = raid()
    lee = in_raid(w, c, "mag")
    mag = npc("Magtheridon")
    sam, bob = pl(c, "Sam"), pl(c, "Bob")
    lee.fire("ENCOUNTER_START", 651, "Magtheridon", 4, 4)
    cast(lee, mag, 30616, "Blast Nova")                                # the cast starts; the cubes stop it
    w.tick(60)
    lee.fire("ENCOUNTER_END", 651, "Magtheridon", 4, 4, 1)
    w.tick(1)
    h = set(hits(lee))
    assert "mag_cubes" in h and not ({"mag_nova", "mag_novaparty"} & h), h
    lee.fire("ENCOUNTER_START", 651, "Magtheridon", 4, 4)
    for _ in range(3):
        dmg(lee, mag, sam, 30613, "Blast Nova")
        dmg(lee, mag, bob, 30613, "Blast Nova")                        # one nova hits everyone at once
        w.tick(5)
        dmg(lee, mag, sam, 30613, "Blast Nova")                        # (still that nova)
        w.tick(55)
    lee.fire("ENCOUNTER_START", 651, "Magtheridon", 4, 4)              # a new pull: the count starts over
    for _ in range(2):
        dmg(lee, mag, sam, 30613, "Blast Nova")
        w.tick(60)
    lee.fire("ENCOUNTER_END", 651, "Magtheridon", 4, 4, 1)
    w.tick(1)
    h = set(hits(lee))
    assert "mag_nova" in h and "mag_novaparty" not in h, h
    lee.fire("ENCOUNTER_START", 651, "Magtheridon", 4, 4)
    for _ in range(3):
        dmg(lee, mag, sam, 30613, "Blast Nova")
        w.tick(60)
    lee.fire("ENCOUNTER_END", 651, "Magtheridon", 4, 4, 1)
    w.tick(1)
    assert "mag_novaparty" in hits(c["Rita"]) and who(c["Rita"], "mag_novaparty") == "Magtheridon"
    no_errors(w)


@case
def raid_boss_emote_names_the_raider():
    w, c = raid()
    lee = in_raid(w, c, "tk")
    lee.fire("CHAT_MSG_RAID_BOSS_EMOTE", "%s casts Gravity Lapse!", "Kael'thas Sunstrider", "", "", "")
    w.tick(1)
    assert hits(lee) == [], hits(lee)
    lee.fire("CHAT_MSG_RAID_BOSS_EMOTE", "Thaladred the Darkener sets eyes on Sam!", "Thaladred the Darkener",
             "", "", "Sam")
    w.tick(1)
    assert "tk_gaze" in hits(c["Bob"]) and who(c["Bob"], "tk_gaze") == "Sam"
    no_errors(w)


@case
def raid_encounter_filters_id_only_auras_and_cast_counts():
    w, c = raid()
    lee = in_raid(w, c, "tk")
    sam, bob = pl(c, "Sam"), pl(c, "Bob")
    trash = npc("Crimson Hand Battle Mage")
    dmg(lee, trash, sam, 36731, "Flamestrike", overkill=100)           # trash Flamestrike: not Kael's fight
    die(lee, sam)
    w.tick(1)
    assert "tk_flamestrike" not in hits(lee)
    lee.fire("ENCOUNTER_START", 733, "Kael'thas Sunstrider", 4, 4)
    dmg(lee, npc("Flamestrike Trigger"), sam, 36731, "Flamestrike", overkill=100)
    die(lee, sam)
    # Gravity Lapse, then a fall that kills
    kael = npc("Kael'thas Sunstrider")
    aura(lee, kael, bob, 34480, "Gravity Lapse")
    w.tick(25)
    aura(lee, kael, bob, 34480, "Gravity Lapse", sub="SPELL_AURA_REMOVED")
    w.tick(3)
    ev(lee, "ENVIRONMENTAL_DAMAGE", NOBODY, bob, "Falling", 9000, 3000)
    die(lee, bob)
    w.tick(1)
    h = set(hits(lee))
    assert {"tk_flamestrike", "tk_lapse", "fall_death"} <= h, h
    lee.eval("ns.BingoDetect:SetRaid('ssc')")
    hydross = npc("Hydross the Unstable")
    aura(lee, hydross, sam, 38218, "Mark of Hydross")                  # 100%
    w.tick(1)
    assert "ssc_marked" not in hits(lee)
    aura(lee, hydross, sam, 38231, "Mark of Hydross")                  # 250%
    lee.eval("ns.BingoDetect:SetRaid('kara')")
    lee.fire("ENCOUNTER_START", 655, "Opera Hall", 3, 4)
    cast(lee, npc("Julianne"), 30951, "Undying Love", dst=npc("Romulo"))   # the phase-3 revive
    w.tick(1)
    h = set(hits(lee))
    assert "ssc_marked" in h and "kara_undying" not in h, h
    cast(lee, npc("Romulo"), 30951, "Undying Love", dst=npc("Julianne"))
    w.tick(1)
    assert "kara_undying" in hits(c["Rita"]) and who(c["Rita"], "kara_undying") == "Romulo"
    no_errors(w)


@case
def every_raid_rule_names_a_square_of_its_pool():
    w, c = raid()
    lee = start(w, c)
    bad = lee.eval_py("""
        local bad = {}
        for _, r in ipairs(ns.BingoDetect.RULES) do
            local sq = ns.BingoSquares:Get(r[1])
            if not sq or not sq.raid then bad[#bad + 1] = tostring(r[1]) end
        end
        return bad""")
    assert bad == [], bad
    # and every raid square has at least one rule
    missing = lee.eval_py("""
        local has, out = {}, {}
        for _, r in ipairs(ns.BingoDetect.RULES) do has[r[1]] = true end
        for _, sq in ipairs(ns.BingoSquares.list) do
            if sq.raid and not has[sq.id] then out[#out + 1] = sq.id end
        end
        return out""")
    assert missing == [], missing
    no_errors(w)


if __name__ == "__main__":
    run_all("games / Council Bingo detection")
