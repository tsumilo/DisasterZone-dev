"""My Log (Core/MyLog.lua): the opt-in personal combat log.

Covers: off by default (nothing recorded, the combat log not even listened to); raids recorded once on, heroics only
with the heroic switch, normal dungeons and the open world never; damage done counted as amount + absorbed (overkill too)
with crits, resists, blocks, glancing hits and misses; pets and totems (the MINE flag) apart from other players' pets;
other players' events ignored; effective healing, overhealing and shields (both SPELL_ABSORBED forms); damage taken
with avoidance, crushing blows and hits a shield took whole; healing received per healer; casts, interrupts, dispels,
resource gains; buff and debuff uptime (buffs up at the pull counted from the pull); the 5-second timeline; active
time and idle gaps from casts, channels, interrupted casts and swings; a death recap holding only the last 10 seconds
and naming the killing blow, feign death ignored, alive time after a battle res; wipes; a /reload mid-pull saved as cut
short; turning it off mid-pull dropping the pull; Delete; the detail kept for the newest pulls and kills of a boss
and pulls past keepWeeks dropped; /dz mylog; nothing ever sent to anyone.

Run: luaenv\\Scripts\\python.exe tests\\mylog\\test_mylog.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import World, Client, case, run_all, solo, install_helpers  # noqa: E402

ME_FLAGS = 0x511         # mine | friendly | player-controlled | player
PET_FLAGS = 0x1111       # mine | friendly | player-controlled | pet
GUARD_FLAGS = 0x2111     # mine | guardian (totems, Shadowfiend)
RAID_FLAGS = 0x514       # raid member
OTHER_PET = 0x1114       # someone else's pet
BOSS_FLAGS = 0xA48
BOSS = "Creature-0-4000-548-100-21216-0000AB1234"       # Hydross
ADD = "Creature-0-4000-548-100-22036-0000AB1299"
PET = "Pet-0-4000-548-100-17252-0100AB0001"              # Felguard
TOTEM = "Creature-0-4000-548-100-15439-0000AB2222"
HEALER = "Player-4000-0BEEF001"


class Fight:
    """A player in a raid with My Log on. ev() fires one combat log line with the 2.5.x payload layout."""

    def __init__(self, enabled=True, instance="raid", difficulty=4, cls="WARLOCK", heroics=False):
        w = World()
        w.auto_session = False
        cl = Client(w, "Lux", class_file=cls, guild_rank=3)
        cl.load_addon()
        w.tick(3)
        if enabled:
            cl.eval("ns.DB:SetSetting('mylog.enabled', true)")
        if heroics:
            cl.eval("ns.DB:SetSetting('mylog.heroics', true)")
        if instance == "raid":
            w.enter_instance("Serpentshrine Cavern", 548, "raid", 25, difficulty_id=4)
        elif instance:
            w.enter_instance("The Botanica", 553, "party", 5, difficulty_id=difficulty)
        w.tick(1)
        self.w, self.cl = w, cl
        self.me = cl.eval("return UnitGUID('player')")

    def ev(self, sub, src, src_name, src_flags, dst, dst_name, dst_flags, *rest):
        self.cl.combat_log(self.cl.eval("return GetTime()"), sub, False, src or "", src_name or "", src_flags, 0,
                           dst or "", dst_name or "", dst_flags, 0, *rest)

    def mine(self, sub, dst, dst_name, *rest):
        self.ev(sub, self.me, "Lux", ME_FLAGS, dst, dst_name, BOSS_FLAGS, *rest)

    def at_me(self, sub, src, src_name, *rest):
        self.ev(sub, src, src_name, BOSS_FLAGS, self.me, "Lux", ME_FLAGS, *rest)

    def start(self, enc=623, name="Hydross the Unstable"):
        self.cl.fire("ENCOUNTER_START", enc, name, 4, 25)

    def end(self, kill=True, enc=623, name="Hydross the Unstable"):
        self.cl.fire("ENCOUNTER_END", enc, name, 4, 25, 1 if kill else 0)

    def tick(self, s):
        self.w.tick(s)

    def pulls(self):
        return self.cl.eval_py("return ns.MyLog:GetPulls()") or []

    def last(self):
        p = self.pulls()
        assert p, "no pull stored"
        return p[-1]


def dmg_spell(f, spell, name, amount, overkill=-1, resisted=0, blocked=0, absorbed=0, crit=False, dst=BOSS,
              dst_name="Hydross the Unstable", sub="SPELL_DAMAGE"):
    f.mine(sub, dst, dst_name, spell, name, 32, amount, overkill, 32, resisted or None, blocked or None,
           absorbed or None, crit, False, False, False)


@case
def off_by_default_records_nothing():
    f = Fight(enabled=False)
    assert f.cl.eval("return ns.MyLog:IsEnabled()") is False
    f.start()
    assert f.cl.eval("return ns.MyLog:IsRecording()") is False
    dmg_spell(f, 27209, "Shadow Bolt", 2000)
    f.tick(10)
    f.end()
    assert f.pulls() == []
    assert f.cl.eval("return ns.MyLog:IsRecording()") is False


@case
def talents_read_like_the_class_tools_read_them():
    """A pull's talent string reads the points the way ClassKit does (2.5.6's C_SpecializationInfo first): a client
    without the old GetTalentTabInfo alias still records 41/20/0, not 0/0/0."""
    f = Fight(cls="WARLOCK")
    f.cl.eval("""
        local pts = { 41, 20, 0 }
        C_SpecializationInfo = { GetSpecializationInfo = function(tab)
            return tab, 'Tab' .. tab, '', 0, nil, nil, pts[tab] or 0, '', 0, true
        end }
        GetTalentTabInfo = nil
    """)
    assert f.cl.eval("return ns.ClassKit:MyTab()") == 1
    f.start()
    f.tick(5)
    f.end(kill=True)
    p = f.last()
    assert p["tal"] == "41/20/0", p["tal"]
    assert p["spec"] == f.cl.eval("return ns.BiS:DetectSpec()") and p["spec"] != "", p["spec"]


@case
def nothing_is_ever_sent():
    """My Log has no wire code at all: no addon messages, no chat, no Comm / Outbox calls."""
    import harness
    src = open(os.path.join(harness.ADDON_DIR, "Core", "MyLog.lua"), encoding="utf-8").read()
    for word in ("SendAddonMessage", "SendChatMessage", "ns.Comm", "Comm:", "Outbox", "C_ChatInfo"):
        assert word not in src, word


@case
def kill_totals_match_the_combat_log():
    f = Fight()
    f.start()
    assert f.cl.eval("return ns.MyLog:IsRecording()") is True
    f.tick(1)
    dmg_spell(f, 27209, "Shadow Bolt", 2000)
    dmg_spell(f, 27209, "Shadow Bolt", 3100, crit=True)
    dmg_spell(f, 27209, "Shadow Bolt", 1500, resisted=500)
    dmg_spell(f, 27216, "Corruption", 300, absorbed=100, sub="SPELL_PERIODIC_DAMAGE")
    f.mine("SPELL_MISSED", BOSS, "Hydross the Unstable", 27209, "Shadow Bolt", 32, "RESIST", False, 1700)
    # the killing blow on an add: its 800 overkill counts too (D5, as Meters count it), kept apart as o
    dmg_spell(f, 27209, "Shadow Bolt", 1800, overkill=800, dst=ADD, dst_name="Tainted Spawn of Hydross")
    f.tick(1)
    # my pet and my totem count; someone else's pet and another raider do not
    f.ev("SWING_DAMAGE", PET, "Grimgor", PET_FLAGS, BOSS, "Hydross the Unstable", BOSS_FLAGS,
         400, -1, 1, None, None, None, False, True, False, False)
    f.ev("SPELL_DAMAGE", TOTEM, "Searing Totem", GUARD_FLAGS, BOSS, "Hydross the Unstable", BOSS_FLAGS,
         25530, "Attack", 4, 100, -1, 4, None, None, None, False, False, False, False)
    f.ev("SWING_DAMAGE", "Pet-0-4000-548-100-1-0100AB9999", "Wolf", OTHER_PET, BOSS, "Hydross the Unstable",
         BOSS_FLAGS, 9999, -1, 1, None, None, None, False, False, False, False)
    f.ev("SPELL_DAMAGE", "Player-4000-0BEEF002", "Bob", RAID_FLAGS, BOSS, "Hydross the Unstable", BOSS_FLAGS,
         27209, "Shadow Bolt", 32, 9999, -1, 32, None, None, None, False, False, False, False)
    f.tick(8)
    f.end(kill=True)
    p = f.last()
    assert p["kill"] is True and p["boss"] == "Hydross the Unstable" and p["enc"] == 623
    assert p["zone"] == "Serpentshrine Cavern" and p["cls"] == "WARLOCK"
    assert abs(p["dur"] - 10) < 0.2, p["dur"]
    sb = p["dmg"]["27209"]
    assert sb["n"] == 4 and sb["c"] == 1 and sb["ca"] == 3100 and sb["r"] == 500 and sb["o"] == 800, sb
    assert sb["a"] == 2000 + 3100 + 1500 + 1800 and sb["mx"] == 3100
    assert sb["m"] == {"RESIST": 1} and sb["ma"] == 1700
    cor = p["dmg"]["27216"]
    assert cor["a"] == 300 and cor["ab"] == 100
    assert p["pet"]["p0"]["a"] == 400 and p["pet"]["p0"]["g"] == 1
    assert p["pet"]["p25530"]["a"] == 100
    assert p["names"]["p0"] == "Grimgor melee" and p["names"]["27209"] == "Shadow Bolt"
    useful = (2000 + 3100 + 1500 + 1800) + (300 + 100) + 400 + 100
    assert p["s"]["d"] == useful, (p["s"], useful)
    assert abs(p["s"]["dps"] - useful / p["dur"]) < 0.1
    assert p["tgt"][21216]["a"] == 2000 + 3100 + 1500 + 400 + 400 + 100
    assert p["tgt"][22036]["a"] == 1800 and p["tgt"][22036]["n"] == "Tainted Spawn of Hydross"
    tl = p["tl"]["d"]
    assert sum(tl.values() if isinstance(tl, dict) else tl) == useful
    assert p["spec"] is not None and p["tal"].count("/") == 2


@case
def healing_overhealing_and_shields():
    f = Fight(cls="PRIEST")
    f.start()
    f.tick(1)
    me = f.me
    # heal on another raider: 3000 landed, 1200 of it overheal; a crit
    f.ev("SPELL_HEAL", me, "Lux", ME_FLAGS, HEALER, "Holyvee", RAID_FLAGS, 25235, "Flash Heal", 2, 3000, 1200, 0, True)
    f.ev("SPELL_PERIODIC_HEAL", me, "Lux", ME_FLAGS, HEALER, "Holyvee", RAID_FLAGS, 25222, "Renew", 2, 500, 0, 0, False)
    # my shield took a swing (swing form) and a spell (spell form)
    f.ev("SPELL_ABSORBED", BOSS, "Hydross", BOSS_FLAGS, HEALER, "Holyvee", RAID_FLAGS,
         me, "Lux", ME_FLAGS, 0, 25218, "Power Word: Shield", 2, 900)
    f.ev("SPELL_ABSORBED", BOSS, "Hydross", BOSS_FLAGS, HEALER, "Holyvee", RAID_FLAGS,
         38235, "Water Tomb", 16, me, "Lux", ME_FLAGS, 0, 25218, "Power Word: Shield", 2, 600)
    # someone else's shield: not mine
    f.ev("SPELL_ABSORBED", BOSS, "Hydross", BOSS_FLAGS, me, "Lux", ME_FLAGS,
         HEALER, "Holyvee", RAID_FLAGS, 0, 25218, "Power Word: Shield", 2, 5000)
    # healing I received
    f.ev("SPELL_HEAL", HEALER, "Holyvee", RAID_FLAGS, me, "Lux", ME_FLAGS, 25235, "Flash Heal", 2, 2000, 500, 0, False)
    f.tick(9)
    f.end()
    p = f.last()
    fh = p["heal"]["25235"]
    assert fh["a"] == 1800 and fh["oh"] == 1200 and fh["c"] == 1, fh
    assert p["heal"]["25222"]["a"] == 500
    assert p["shield"]["25218"]["a"] == 1500 and p["shield"]["25218"]["n"] == 2
    assert p["healIn"]["Holyvee"] == 1500
    assert p["s"]["h"] == 2300 and p["s"]["oh"] == 1200 and p["s"]["sh"] == 1500
    assert abs(p["s"]["hps"] - 3800 / p["dur"]) < 0.1


@case
def damage_taken_and_avoidance():
    f = Fight(cls="WARRIOR")
    f.start()
    f.tick(1)
    f.at_me("SWING_DAMAGE", BOSS, "Hydross the Unstable", 4000, -1, 1, None, 600, None, False, False, True, False)
    f.at_me("SWING_DAMAGE", BOSS, "Hydross the Unstable", 2000, -1, 1, None, None, 500, True, False, False, False)
    for miss in ("DODGE", "PARRY", "PARRY", "MISS"):
        f.at_me("SWING_MISSED", BOSS, "Hydross the Unstable", miss, False)
    f.at_me("SWING_MISSED", BOSS, "Hydross the Unstable", "ABSORB", False, 3000)
    f.at_me("SPELL_DAMAGE", BOSS, "Hydross the Unstable", 38235, "Water Tomb", 16, 1000, -1, 16, 250, None, None,
            False, False, False, False)
    f.ev("ENVIRONMENTAL_DAMAGE", "", "", 0, f.me, "Lux", ME_FLAGS, "Falling", 700, -1, 1, None, None, None,
         False, False, False, False)
    f.tick(9)
    f.end()
    p = f.last()
    melee = p["taken"]["m21216"]
    assert melee["n"] == 2 and melee["a"] == 6000 and melee["b"] == 600 and melee["cr"] == 1 and melee["c"] == 1
    assert melee["ab"] == 500 and melee["src"] == "Hydross the Unstable"
    assert melee["m"] == {"DODGE": 1, "PARRY": 2, "MISS": 1, "ABSORB": 1}
    assert p["avoid"] == {"DODGE": 1, "PARRY": 2, "MISS": 1, "ABSORB": 1}
    assert p["taken"]["38235"]["r"] == 250
    assert p["taken"]["eFalling"]["a"] == 700
    assert p["s"]["t"] == 6000 + 500 + 3000 + 1000 + 700, p["s"]


@case
def casts_kicks_dispels_gains_and_uptime():
    f = Fight()
    f.cl.eval("__MOCK.player_auras = { { 'Flask of Pure Death', 17628 }, { 'Blessing of Kings', 25898 } }")
    f.start()
    f.tick(1)
    for _ in range(3):
        f.mine("SPELL_CAST_SUCCESS", BOSS, "Hydross", 27209, "Shadow Bolt", 32)
    f.mine("SPELL_INTERRUPT", BOSS, "Hydross", 19647, "Spell Lock", 32, 38235, "Water Tomb", 16)
    f.mine("SPELL_DISPEL", ADD, "Spawn", 27276, "Devour Magic", 32, 12345, "Some Buff", 1, "BUFF")
    f.ev("SPELL_ENERGIZE", f.me, "Lux", ME_FLAGS, f.me, "Lux", ME_FLAGS, 27222, "Life Tap", 32, 1200, 200, 0)
    # a debuff I keep on the boss: up 1..5 and 7..10; Bloodlust buff on me from 2 to 6
    f.mine("SPELL_AURA_APPLIED", BOSS, "Hydross", 27228, "Curse of the Elements", 32, "DEBUFF")
    f.ev("SPELL_AURA_APPLIED", HEALER, "Holyvee", RAID_FLAGS, f.me, "Lux", ME_FLAGS, 2825, "Bloodlust", 8, "BUFF")
    f.tick(1)
    f.tick(3)
    f.ev("SPELL_AURA_REMOVED", HEALER, "Holyvee", RAID_FLAGS, f.me, "Lux", ME_FLAGS, 2825, "Bloodlust", 8, "BUFF")
    f.mine("SPELL_AURA_REMOVED", BOSS, "Hydross", 27228, "Curse of the Elements", 32, "DEBUFF")
    f.tick(2)
    f.mine("SPELL_AURA_APPLIED", BOSS, "Hydross", 27228, "Curse of the Elements", 32, "DEBUFF")
    f.tick(3)
    f.end()
    p = f.last()
    assert p["casts"][27209] == 3 and p["kicks"][38235] == 1 and p["disp"][12345] == 1
    assert p["gain"][27222] == {"n": 1, "a": 1200, "o": 200}
    assert sorted(p["buffs"]) == [17628, 25898]
    up = p["up"]
    assert abs(up["out"][27228] - 7) < 0.2, up
    assert abs(up["me"][2825] - 4) < 0.2, up
    assert abs(up["me"][17628] - p["dur"]) < 0.2, up   # up all fight (seeded at the pull)


@case
def active_time_and_gaps():
    f = Fight()
    f.cl.eval("__MOCK.gcd = 1.5")
    f.start()
    # a 2.5 s cast at 0, an instant at 2.5 (1.5 GCD) -> busy 0..4; idle 4..10 (gap 6); a channel 10..13 cut at 12;
    # then idle to the end at 16 (gap 4)
    cl = f.cl
    cl.eval("local n = GetTime(); __MOCK.casting = { 'Shadow Bolt', n * 1000, (n + 2.5) * 1000, 27209 }")
    cl.fire("UNIT_SPELLCAST_START", "player", "c1", 27209)
    f.tick(2.5)
    cl.eval("__MOCK.casting = nil")
    cl.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", 27209)
    cl.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c2", 27216)
    f.tick(7.5)
    cl.eval("local n = GetTime(); __MOCK.channel = { 'Drain Soul', n * 1000, (n + 3) * 1000, 27217 }")
    cl.fire("UNIT_SPELLCAST_CHANNEL_START", "player", "c3", 27217)
    f.tick(2)
    cl.eval("__MOCK.channel = nil")
    cl.fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c3", 27217)
    f.tick(4)
    f.end()
    p = f.last()
    assert abs(p["dur"] - 16) < 0.2, p["dur"]
    assert abs(p["actSec"] - 6) < 0.2, p["actSec"]          # 0..4 + 10..12
    gaps = [(g["at"], g["len"]) for g in p["gaps"]]
    assert len(gaps) == 2 and abs(gaps[0][0] - 4) < 0.2 and abs(gaps[0][1] - 6) < 0.2, gaps
    assert abs(gaps[1][1] - 4) < 0.2, gaps
    assert abs(p["s"]["act"] - 6 / 16) < 0.02, p["s"]


@case
def a_refused_cast_does_not_cut_the_running_one():
    f = Fight()
    f.start()
    cl = f.cl
    cl.eval("local n = GetTime(); __MOCK.casting = { 'Shadow Bolt', n * 1000, (n + 3) * 1000, 27209 }")
    cl.fire("UNIT_SPELLCAST_START", "player", "c1", 27209)
    f.tick(1)
    cl.fire("UNIT_SPELLCAST_FAILED", "player", "c9", 27216)     # "another action is in progress"
    f.tick(2)
    cl.eval("__MOCK.casting = nil")
    cl.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", 27209)
    f.end()
    p = f.last()
    assert abs(p["actSec"] - 3) < 0.2, p["actSec"]


@case
def swings_cover_their_weapon_speed():
    f = Fight(cls="WARRIOR")
    f.cl.eval("__MOCK.swing_speed = 3.6")
    f.start()
    for _ in range(3):
        f.mine("SWING_DAMAGE", BOSS, "Hydross", 1000, -1, 1, None, None, None, False, False, False, False)
        f.tick(3.6)
    f.tick(3.2)
    f.end()
    p = f.last()
    assert abs(p["actSec"] - 10.8) < 0.2, p
    assert p["dmg"]["0"]["a"] == 3000 and p["names"]["0"] == "Melee"


@case
def death_recap_keeps_the_last_ten_seconds():
    f = Fight()
    f.start()
    f.at_me("SPELL_DAMAGE", ADD, "Tainted Elemental", 38253, "Poison Bolt", 8, 1111, -1, 8, None, None, None,
            False, False, False, False)
    f.tick(5.5)
    f.ev("SPELL_HEAL", HEALER, "Holyvee", RAID_FLAGS, f.me, "Lux", ME_FLAGS, 33076, "Prayer of Mending", 2,
         1840, 0, 0, False)
    f.tick(1)
    f.at_me("SPELL_DAMAGE", ADD, "Tainted Elemental", 38253, "Poison Bolt", 8, 2410, -1, 8, None, None, None,
            False, False, False, False)
    f.mine("SPELL_CAST_SUCCESS", f.me, "Lux", 27222, "Life Tap", 32)
    f.tick(4)
    f.at_me("SPELL_DAMAGE", BOSS, "Lady Vashj", 38575, "Toxic Spores", 8, 3130, 1206, 8, None, None, None,
            False, False, False, False)
    f.ev("UNIT_DIED", "", "", 0, f.me, "Lux", ME_FLAGS)
    f.tick(5)
    f.end(kill=False)
    p = f.last()
    assert p["kill"] is False and len(p["deaths"]) == 1
    d = p["deaths"][0]
    assert abs(d["t"] - 10.5) < 0.2 and d["by"] == "38575", d
    kinds = [e[1] for e in d["ring"]]
    assert kinds == ["h", "d", "c", "d"], d["ring"]        # the first Poison Bolt (10 s+ earlier) is gone
    assert d["ring"][-1][3] == 3130 and d["ring"][-1][5] == "Lady Vashj"
    assert p["s"]["dc"] == 1
    assert p["dead"] is not None


@case
def feign_death_is_not_a_death():
    f = Fight(cls="HUNTER")
    f.start()
    f.tick(2)
    f.cl.eval("__MOCK.feigning = true")
    f.ev("UNIT_DIED", "", "", 0, f.me, "Lux", ME_FLAGS)
    f.cl.eval("__MOCK.feigning = false")
    f.tick(2)
    f.end()
    assert f.last()["deaths"] == []


@case
def battle_res_resumes_alive_time():
    f = Fight()
    f.start()
    cl = f.cl
    cl.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 1)
    f.tick(2)
    f.ev("UNIT_DIED", "", "", 0, f.me, "Lux", ME_FLAGS)
    f.tick(10)
    cl.fire("PLAYER_ALIVE")
    for _ in range(4):
        cl.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 1)
        f.tick(1.5)
    f.tick(2)
    f.end()
    p = f.last()
    assert p.get("dead") is None and abs(p["deadFor"] - 10) < 0.2, p
    # alive 2 + 8 s, busy 1.5 + 6
    assert abs(p["s"]["act"] - 7.5 / 10) < 0.03, p["s"]


@case
def heroics_only_with_the_switch():
    f = Fight(instance="party", difficulty=2)
    f.start(enc=1234, name="Warp Splinter")
    assert f.cl.eval("return ns.MyLog:IsRecording()") is False
    f.end(enc=1234, name="Warp Splinter")
    f = Fight(instance="party", difficulty=2, heroics=True)
    f.start(enc=1234, name="Warp Splinter")
    f.tick(3)
    f.end(enc=1234, name="Warp Splinter")
    assert f.last()["heroic"] is True
    f = Fight(instance="party", difficulty=1, heroics=True)
    f.start(enc=1234, name="Warp Splinter")
    assert f.cl.eval("return ns.MyLog:IsRecording()") is False
    f = Fight(instance=None)
    f.start(enc=1, name="Doom Lord Kazzak")
    assert f.cl.eval("return ns.MyLog:IsRecording()") is False


@case
def reload_mid_pull_is_saved_as_cut_short():
    f = Fight()
    f.start()
    dmg_spell(f, 27209, "Shadow Bolt", 2000)
    f.tick(4)
    f.cl.relog(reload=True)
    f.w.tick(2)
    p = f.last()
    assert p["cut"] is True and p["kill"] is False and p["dmg"]["27209"]["a"] == 2000
    assert f.cl.eval("return ns.MyLog:IsRecording()") is False


@case
def turning_it_off_mid_pull_drops_the_pull():
    f = Fight()
    f.start()
    dmg_spell(f, 27209, "Shadow Bolt", 2000)
    f.cl.eval("ns.DB:SetSetting('mylog.enabled', false)")
    assert f.cl.eval("return ns.MyLog:IsRecording()") is False
    f.end()
    assert f.pulls() == []


@case
def delete_all_clears_every_pull():
    f = Fight()
    for _ in range(2):
        f.start()
        f.tick(2)
        f.end()
    assert len(f.pulls()) == 2
    f.cl.eval("ns.MyLog:DeleteAll()")
    assert f.pulls() == []
    f.cl.relog(reload=True)
    f.w.tick(2)
    assert f.pulls() == []


@case
def old_pulls_lose_detail_then_go():
    f = Fight()
    # 7 wipes then 4 kills of one boss: detail stays on the newest 5 pulls and the newest 3 kills
    for i in range(11):
        f.start()
        dmg_spell(f, 27209, "Shadow Bolt", 1000 + i)
        f.tick(2)
        f.end(kill=i >= 7)
    pulls = f.pulls()
    detail = [p["id"] for p in pulls if "dmg" in p]
    assert detail == [7, 8, 9, 10, 11], detail
    assert all("s" in p for p in pulls)
    # an old kill falls out of the 3 newest kills but... the pull summary stays
    assert pulls[0]["s"]["d"] == 1000
    # keepWeeks: pulls older than that are dropped at the next trim
    f.cl.eval("local p = ns.MyLog:GetPulls(); p[1].at = p[1].at - 13 * 7 * 86400; ns.MyLog:Trim()")
    assert [p["id"] for p in f.pulls()][0] == 2


@case
def other_encounters_end_does_not_close_the_pull():
    f = Fight()
    f.start()
    f.cl.fire("ENCOUNTER_END", 999, "Something else", 4, 25, 1)
    assert f.cl.eval("return ns.MyLog:IsRecording()") is True
    f.end()
    assert len(f.pulls()) == 1


@case
def slash_mylog():
    f = Fight(enabled=False)
    f.cl.slash("/dz mylog on")
    assert f.cl.eval("return ns.MyLog:IsEnabled()") is True
    f.start()
    dmg_spell(f, 27209, "Shadow Bolt", 5000)
    f.tick(5)
    f.end()
    f.cl.slash("/dz mylog last")
    f.cl.slash("/dz mylog off")
    assert f.cl.eval("return ns.MyLog:IsEnabled()") is False


@case
def boss_mechanics_are_marked_once_per_cast():
    f = Fight()
    f.start(enc=625, name="Leotheras the Blind")
    f.tick(10)
    leo = "Creature-0-4000-548-100-21215-0000AB7777"
    # Whirlwind goes on Leotheras (an aura from the strategy board's list): one mark, even if it lands twice
    f.ev("SPELL_AURA_APPLIED", leo, "Leotheras the Blind", BOSS_FLAGS, leo, "Leotheras the Blind", BOSS_FLAGS,
         37640, "Whirlwind", 1, "BUFF")
    f.ev("SPELL_AURA_APPLIED", leo, "Leotheras the Blind", BOSS_FLAGS, leo, "Leotheras the Blind", BOSS_FLAGS,
         37640, "Whirlwind", 1, "BUFF")
    # a spell that is not on the list is not a mark
    f.ev("SPELL_CAST_SUCCESS", leo, "Leotheras the Blind", BOSS_FLAGS, "", "", 0, 12345, "Something", 1)
    f.tick(50)
    f.ev("SPELL_AURA_APPLIED", leo, "Leotheras the Blind", BOSS_FLAGS, leo, "Leotheras the Blind", BOSS_FLAGS,
         37640, "Whirlwind", 1, "BUFF")
    f.cl.eval("__MOCK.player_hp = 4000")
    f.ev("UNIT_DIED", "", "", 0, f.me, "Lux", ME_FLAGS)
    f.tick(2)
    f.end(enc=625, name="Leotheras the Blind")
    p = f.last()
    marks = [(round(m[0]), m[1]) for m in p["mech"]]
    assert marks == [(10, 37640), (60, 37640)], marks
    assert p["names"]["37640"] == "Whirlwind"
    assert p["deaths"][0]["hpMax"] == 100
    assert f.cl.eval("return ns.MyLog:BossDisplayId('Leotheras the Blind')") == 20514


@case
def the_boss_side_of_the_fight_is_logged():
    f = Fight()
    f.start(enc=625, name="Leotheras the Blind")
    leo = "Creature-0-4000-548-100-21215-0000AB7777"
    shadow = "Creature-0-4000-548-100-21875-0000AB8888"
    trash = "Creature-0-4000-548-100-99999-0000AB9999"
    f.tick(5)
    # any cast by an encounter creature, once per cast however many it hits
    f.ev("SPELL_CAST_START", leo, "Leotheras the Blind", BOSS_FLAGS, "", "", 0, 37675, "Chaos Blast", 32)
    f.ev("SPELL_CAST_SUCCESS", leo, "Leotheras the Blind", BOSS_FLAGS, "", "", 0, 37675, "Chaos Blast", 32)
    # a creature outside the encounter: nothing
    f.ev("SPELL_CAST_START", trash, "Coilfang Trash", BOSS_FLAGS, "", "", 0, 11111, "Frostbolt", 16)
    f.tick(5)
    # Whirlwind on Leotheras for 12 s: an aura entry with its length; my curse on him is not the boss's
    f.ev("SPELL_AURA_APPLIED", leo, "Leotheras the Blind", BOSS_FLAGS, leo, "Leotheras the Blind", BOSS_FLAGS,
         37640, "Whirlwind", 1, "BUFF")
    f.mine("SPELL_AURA_APPLIED", leo, "Leotheras the Blind", 27228, "Curse of the Elements", 32, "DEBUFF")
    f.tick(12)
    f.ev("SPELL_AURA_REMOVED", leo, "Leotheras the Blind", BOSS_FLAGS, leo, "Leotheras the Blind", BOSS_FLAGS,
         37640, "Whirlwind", 1, "BUFF")
    # the demon form's shadow dies; a yell marks a phase
    f.ev("SPELL_SUMMON", leo, "Leotheras the Blind", BOSS_FLAGS, shadow, "Shadow of Leotheras", BOSS_FLAGS,
         37676, "Insidious Whisper", 32)
    f.cl.fire("CHAT_MSG_MONSTER_YELL", "Be gone, trifling elf. I am in control now!", "Leotheras the Blind")
    f.tick(3)
    f.ev("UNIT_DIED", "", "", 0, shadow, "Shadow of Leotheras", BOSS_FLAGS)
    f.tick(2)
    f.end(enc=625, name="Leotheras the Blind")
    bev = [(round(e[0]), e[1], e[2], e[3] if len(e) > 3 else None) for e in f.last()["bev"]]
    assert bev == [(5, "c", 37675, None), (10, "a", 37640, 12), (22, "s", 37676, None),
                   (22, "y", "Leotheras the Blind", "Be gone, trifling elf. I am in control now!"),
                   (25, "d", 21875, None)], bev
    assert f.last()["names"]["n21875"] == "Shadow of Leotheras"


@case
def my_casts_are_logged_in_order_with_their_length():
    f = Fight()
    f.start()
    cl = f.cl
    # a 2.5 s Shadow Bolt
    cl.eval("local n = GetTime(); __MOCK.casting = { 'Shadow Bolt', n * 1000, (n + 2.5) * 1000, 27209 }")
    cl.fire("UNIT_SPELLCAST_START", "player", "c1", 27209)
    f.tick(2.5)
    cl.eval("__MOCK.casting = nil")
    f.mine("SPELL_CAST_SUCCESS", BOSS, "Hydross", 27209, "Shadow Bolt", 32)
    cl.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", 27209)
    # an instant
    f.tick(0.5)
    f.mine("SPELL_CAST_SUCCESS", BOSS, "Hydross", 27216, "Corruption", 32)
    # a 3 s channel (the log names it when it starts)
    f.tick(1)
    cl.eval("local n = GetTime(); __MOCK.channel = { 'Drain Life', n * 1000, (n + 5) * 1000, 27220 }")
    cl.fire("UNIT_SPELLCAST_CHANNEL_START", "player", "c3", 27220)
    f.mine("SPELL_CAST_SUCCESS", BOSS, "Hydross", 27220, "Drain Life", 32)
    f.tick(3)
    cl.eval("__MOCK.channel = nil")
    cl.fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c3", 27220)
    f.tick(1)
    f.end()
    ct = [(round(e[0], 1), e[1], (round(e[2], 1) if len(e) > 2 and e[2] is not None else None)) for e in f.last()["ct"]]
    assert ct == [(0.0, 27209, 2.5), (3.0, 27216, None), (4.0, 27220, 3.0)], ct


@case
def settings_section_switches_and_deletes():
    w, c = solo("Lux", class_file="WARLOCK", tick=3)
    install_helpers(c)
    c.eval("function T_settings() return ns.MainFrame:GetPanel('settings') end")
    c.slash("/dz settings")
    w.tick(0.5)
    c.eval("ns.SettingsUI:SelectSection('mylog')")
    w.tick(0.2)
    sw = c.eval("return T_checkbox(T_settings(), 'Record my raid performance')")
    assert sw is not None
    assert c.eval("local b = ...; return b:GetChecked()", sw) is False
    c.click(sw)
    assert c.eval("return ns.MyLog:IsEnabled()") is True
    w.enter_instance("Serpentshrine Cavern", 548, "raid", 25, difficulty_id=4)
    w.tick(1)
    c.fire("ENCOUNTER_START", 623, "Hydross the Unstable", 4, 25)
    w.tick(3)
    c.fire("ENCOUNTER_END", 623, "Hydross the Unstable", 4, 25, 1)
    w.tick(0.5)
    btn = c.eval("return T_button(T_settings(), 'Delete all my logs')")
    assert btn is not None
    c.click(btn)
    assert len(c.eval_py("return ns.MyLog:GetPulls()") or []) == 1      # first click only asks
    assert c.eval("local b = ...; return b:GetText()", btn) == "Click again to delete"
    c.click(btn)
    assert (c.eval_py("return ns.MyLog:GetPulls()") or []) == []
    # an unanswered ask goes away
    c.fire("ENCOUNTER_START", 623, "Hydross the Unstable", 4, 25)
    w.tick(1)
    c.fire("ENCOUNTER_END", 623, "Hydross the Unstable", 4, 25, 1)
    c.click(btn)
    w.tick(5)
    assert c.eval("local b = ...; return b:GetText()", btn) == "Delete all my logs"
    assert len(c.eval_py("return ns.MyLog:GetPulls()") or []) == 1


if __name__ == "__main__":
    run_all()
