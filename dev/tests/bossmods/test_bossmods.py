#!/usr/bin/env python
"""Boss mods (Core/BossMod.lua, UI/BossModUI.lua, UI/BossModLooks.lua, Data/BossMods/*.lua): the plan
claude.ai/artifact/Hns6CtKKusYF5tqwuHbSQ4 and the looks mockup claude.ai/artifact/66LY12B41hTyqt7e8GEXEM.

Covers: off by default (no fight, the combat log not read); a Gruul pull from ENCOUNTER_START to ENCOUNTER_END (first
timers, a window bar counting to its min and then "within n s", Growth's next count from the stack, Ground Slam's
warning and the Shatter bar, the combat log read only during the fight); Cave In only when it lands on me (red, an
alarm); tank and healer bars only for that role (my role from settings, "Alerts for other roles"); one alert
switched off; the game's pull countdown (START_PLAYER_COUNTDOWN / CANCEL) as a bar and the 5..1 countdown; DBM's and
BigWigs' break messages from the leader (one bar for both, nothing from a non-assist) and /dz break sending both;
Try it in every look (no errors, the hosts reused), demo mode; Edit layout's four spots; every data file passing
tools/bossmods_check.py; the Lurker going under (his adds' first sign, or his Submerge Visual seen on a unit) and
coming back (his first sign after 20 s gone); a fight ending 5 s out of its raid or on the boss's next
ENCOUNTER_START (a wipe while released, 16 Oct 2026); Gruul's Hurtful Strike from its hit and Vashj's Strider bar
looping without drift (17 Oct 2026).

Run: luaenv\\Scripts\\python.exe tests\\bossmods\\test_bossmods.py [-k name]
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.join(HERE, "..", "..")
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(DEV, "tools"))

from _common import case, run_all, solo  # noqa: E402

LOOKS = ("flat", "halo", "sigil", "slate", "gilded", "classic")
BOSS_FLAGS = 0xA48
ME_FLAGS = 0x511
GRUUL = 19044


class Fight:
    """Alice (paladin, Retribution talents = damage) with boss mods on, at Gruul; warnings logged."""

    def __init__(self, on=True, npc=GRUUL, name="Gruul the Dragonkiller", **settings):
        w, c = solo("Alice", class_file="PALADIN", guild_rank=0, talents=(0, 5, 41))
        if on:
            c.eval("ns.DB:SetSetting('bossmods.on', true)")
        for k, v in settings.items():
            c.eval("ns.DB:SetSetting(...)", "bossmods." + k, v)
        c.eval("__warns = {}; ns:On('BOSSMOD_WARN', function(w) __warns[#__warns + 1] = w end)")
        w.tick(0.2)
        self.w, self.c = w, c
        self.me = c.eval("return UnitGUID('player')")
        self.boss = w.spawn_npc(npc, name)

    def start(self):
        self.c.fire("ENCOUNTER_START", 650, "Gruul the Dragonkiller", 4, 25)
        self.w.tick(0.1)

    def end(self, success=0):
        self.c.fire("ENCOUNTER_END", 650, "Gruul the Dragonkiller", 4, 25, success)
        self.w.tick(0.1)

    def log(self, sub, spell, name, dst=None, dst_name=None, *rest):
        c = self.c
        c.combat_log(c.eval("return GetTime()"), sub, False, self.boss, "Gruul the Dragonkiller", BOSS_FLAGS, 0,
                     dst or "", dst_name or "", ME_FLAGS if dst == self.me else 0x514, 0, spell, name, 1, *rest)
        self.w.tick(0.05)

    def bars(self):
        return self.c.eval_py("local o = {}; for _, b in ipairs(ns.BossMod:Bars()) do o[#o + 1] = { text = b.text, "
                              "rem = b.rem, win = b.win, key = b.key, kind = b.kind, role = b.role } end; return o")

    def bar(self, key):
        return next((b for b in self.bars() if b.get("key") == key), None)

    def warns(self):
        return self.c.eval_py("local o = {}; for _, w in ipairs(__warns) do o[#o + 1] = { kind = w.kind, text = w.text, "
                              "sub = w.sub } end; return o")

    def key_of(self, spell, kind="bar"):
        return self.c.eval("for _, a in ipairs(ns.BossMod:Mod('GruulsLair:Gruul').alerts) do "
                           "if a.spell == ... and a.kind == select(2, ...) then return a.key end end", spell, kind)


@case
def off_by_default_nothing_runs():
    f = Fight(on=False)
    c = f.c
    assert c.eval("return ns.BossMod:IsOn()") is False
    f.start()
    assert c.eval("return ns.BossMod:Active()") is None
    assert c.eval("return ns.CombatLog:IsSubscribed('bossmods')") is False
    assert f.bars() == []
    f.w.assert_no_errors()


@case
def a_gruul_pull_from_start_to_end():
    f = Fight()
    c = f.c
    assert c.eval("return ns.CombatLog:IsSubscribed('bossmods')") is False
    f.start()
    assert c.eval("return ns.BossMod:Active().def.key") == "GruulsLair:Gruul"
    assert c.eval("return ns.CombatLog:IsSubscribed('bossmods')") is True
    growth, slam = f.key_of(36300), f.key_of(33525)
    assert f.bar(growth)["text"] == "Growth (1)"
    assert 29 < f.bar(growth)["rem"] <= 30
    s = f.bar(slam)
    assert s and s.get("win") is None and s["rem"] > 30
    # Growth's next count comes from the stack it put on
    f.log("SPELL_AURA_APPLIED_DOSE", 36300, "Growth", f.boss, "Gruul the Dragonkiller", "BUFF", 4)
    assert f.bar(growth)["text"] == "Growth (5)"
    # the first Ground Slam is a window: it counts to its min, then says "within n s"
    lo = c.eval("local a = ns.BossMod:Mod('GruulsLair:Gruul').byKey[...]; return type(a.start) == 'table' and a.start[1] or a.start", slam)
    hi = c.eval("local a = ns.BossMod:Mod('GruulsLair:Gruul').byKey[...]; return type(a.start) == 'table' and a.start[2] or a.start", slam)
    f.w.tick(lo + 0.5)
    s = f.bar(slam)
    if hi > lo:
        assert s["rem"] == 0 and 0 < s["win"] < hi - lo, s
    # Ground Slam: the warning, the Shatter bar, the next slam
    f.log("SPELL_CAST_START", 33525, "Ground Slam")
    assert any("Ground Slam" in w["text"] and w["kind"] == "warn" for w in f.warns()), f.warns()
    sh = f.bar(f.key_of(33654))
    assert sh and 9 < sh["rem"] <= 10
    assert f.bar(slam)["rem"] > 60
    f.end()
    assert c.eval("return ns.BossMod:Active()") is None
    assert f.bars() == []
    assert c.eval("return ns.CombatLog:IsSubscribed('bossmods')") is False
    f.w.assert_no_errors()


@case
def cave_in_warns_only_when_it_is_on_me():
    f = Fight()
    f.start()
    f.log("SPELL_AURA_APPLIED", 36240, "Cave In", "Player-1-00000077", "Bob", "DEBUFF")
    assert not any(w["kind"] == "you" for w in f.warns())
    n0 = f.c.eval("return #__MOCK.sounds")
    f.log("SPELL_AURA_APPLIED", 36240, "Cave In", f.me, "Alice", "DEBUFF")
    ws = [w for w in f.warns() if w["kind"] == "you"]
    assert ws and "Cave In" in ws[0]["text"], f.warns()
    assert f.c.eval("return __MOCK.sounds[#__MOCK.sounds]") == 12889 and f.c.eval("return #__MOCK.sounds") > n0
    f.w.assert_no_errors()


@case
def tank_and_healer_bars_only_for_that_role():
    f = Fight()
    c = f.c
    f.start()
    hurt, rev = f.key_of(33813), f.key_of(36297)
    f.log("SPELL_CAST_SUCCESS", 33813, "Hurtful Strike", "Player-1-00000077", "Victhar")
    f.log("SPELL_CAST_SUCCESS", 36297, "Reverberation")
    assert c.eval("return ns.BossMod:MyRole()") == "dps"
    assert f.bar(hurt) is None and f.bar(rev) is None
    c.eval("ns.DB:SetSetting('bossmods.role', 'healer')")
    assert f.bar(rev) is not None and f.bar(hurt) is None
    c.eval("ns.DB:SetSetting('bossmods.role', 'tank')")
    assert f.bar(hurt) is not None and f.bar(rev) is None
    c.eval("ns.DB:SetSetting('bossmods.role', 'auto'); ns.DB:SetSetting('bossmods.roles', true)")
    assert f.bar(hurt) is not None and f.bar(rev) is not None
    f.w.assert_no_errors()


@case
def an_alert_switched_off_shows_nothing():
    f = Fight()
    c = f.c
    slam = f.key_of(33525, "warn")
    c.eval("ns.BossMod:SetAlertOn('GruulsLair:Gruul', ..., false)", slam)
    f.start()
    f.log("SPELL_CAST_START", 33525, "Ground Slam")
    assert not any("Ground Slam" in w["text"] for w in f.warns())
    assert f.bar(f.key_of(33654)) is not None          # (the others still run)
    assert c.eval("return ns.BossMod:AlertOn('GruulsLair:Gruul', ...)", slam) is False
    f.w.assert_no_errors()


@case
def the_games_pull_countdown_is_a_bar_and_a_countdown():
    f = Fight()
    c = f.c
    c.fire("START_PLAYER_COUNTDOWN", "Player-1-00000042", 10, 10)
    b = next(x for x in f.bars() if x.get("kind") == "pull")
    assert b["text"].startswith("Pull") and 9 < b["rem"] <= 10
    assert 9 < c.eval("return ns.BossMod:Countdown()") <= 10
    f.w.tick(6)
    assert c.eval("return ns.BossModUI:IsAwake()") is True
    c.fire("CANCEL_PLAYER_COUNTDOWN", "Player-1-00000042")
    assert not any(x.get("kind") == "pull" for x in f.bars())
    assert c.eval("return ns.BossMod:Countdown()") is None
    f.w.assert_no_errors()


@case
def dbm_and_bigwigs_breaks_from_the_leader_make_one_bar():
    f = Fight()
    w, c = f.w, f.c
    from harness import Client
    bob = Client(w, "Bob", class_file="WARRIOR", guild_rank=3)
    bob.load_addon()
    w.make_raid([bob, c], leader=bob)
    w.tick(0.5)
    bob.eval("C_ChatInfo.SendAddonMessage('D5', 'Bob-Realm\\t1\\tBT\\t300', 'RAID')")
    bob.eval("C_ChatInfo.SendAddonMessage('BigWigs', 'P^Break^300', 'RAID')")
    w.tick(0.5)
    breaks = [x for x in f.bars() if x.get("kind") == "break"]
    assert len(breaks) == 1 and breaks[0]["text"] == "Break · Bob" and 290 < breaks[0]["rem"] <= 300, breaks
    assert any(x["text"].startswith("Break for 5 minutes") for x in f.warns())
    # a member who is neither leader nor assist can't start one
    c.eval("ns.BossMod:StartBreak(0, 'Bob')")
    c.fire("CHAT_MSG_ADDON", "D5", "Carl-Realm\t1\tBT\t120", "RAID", "Carl")
    assert not any(x.get("kind") == "break" for x in f.bars())
    w.assert_no_errors()


@case
def dz_break_sends_both_formats_as_leader():
    f = Fight()
    w, c = f.w, f.c
    from harness import Client
    bob = Client(w, "Bob", class_file="WARRIOR", guild_rank=3)
    bob.load_addon()
    w.make_raid([c, bob], leader=c)
    w.tick(0.5)
    c.slash("/dz break 5")
    w.tick(0.2)
    sent = [(e["prefix"], e["text"].decode() if isinstance(e["text"], bytes) else e["text"]) for e in c.sent_addon
            if e["prefix"] in ("D5", "BigWigs")]
    assert ("BigWigs", "P^Break^300") in sent, sent
    assert any(p == "D5" and t.endswith("\t1\tBT\t300") and t.startswith("Alice-") for p, t in sent), sent
    assert bob.eval("return ns.BossMod:Bars()[1] == nil")       # (Bob has boss mods off)
    bob.eval("ns.DB:SetSetting('bossmods.on', true)")
    c.slash("/dz break 2")
    w.tick(0.2)
    assert bob.eval("local b = ns.BossMod:Bars()[1]; return b and b.text") == "Break · Alice"
    w.assert_no_errors()


@case
def try_it_in_every_look():
    for look in LOOKS:
        w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
        c.eval("ns.DB:SetSetting('ui.bossmods.look', ...)", look)
        assert c.eval("return ns.BossModUI:LookKey()") == look
        c.eval("ns.BossModUI:TryIt()")
        hosts = 0
        for _ in range(26):
            w.tick(1.0)
            hosts = max(hosts, c.eval("local n = 0; for _ in pairs(ns.BossModUI) do n = n + 1 end; return n"))
        assert c.eval("return ns.BossMod.preview") is False
        assert c.eval("return ns.BossMod:Active()") is None
        w.assert_no_errors()


@case
def blizzard_look_wears_classic():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    assert c.eval("return ns.BossModUI:LookKey()") == "classic"
    c.eval("ns.DB:SetSetting('ui.look', 'halo')")
    assert c.eval("return ns.BossModUI:LookKey()") == "halo"
    c.eval("ns.DB:SetSetting('ui.bossmods.look', 'gilded')")
    assert c.eval("return ns.BossModUI:LookKey()") == "gilded"
    w.assert_no_errors()


@case
def edit_layout_has_the_four_spots_with_a_preview():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    for k in ("bars", "warns", "count", "range"):
        assert c.eval("return ns.Layout:Item(...) ~= nil", "bossmods." + k), k
    c.eval("ns.Layout:Item('bossmods.bars').preview(true)")
    w.tick(8)
    assert c.eval("return ns.BossMod.preview") is True
    assert c.eval("return #ns.BossMod:Bars() > 0") is True
    c.eval("ns.Layout:Item('bossmods.bars').preview(false)")
    assert c.eval("return ns.BossMod.preview") is False
    w.assert_no_errors()


@case
def settings_combat_has_the_boss_mods_card_and_a_looks_page():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.slash("/dz settings")
    w.tick(0.5)
    # off (as it comes): the page is one box that says so, Switch on and Try it
    c.eval("ns.SettingsUI:OpenBossMods('GruulsLair')")
    w.tick(0.5)
    assert c.eval("return ns.SettingsUI.cards.bossmods.off:IsVisible() and ns.SettingsUI.cards.bossmods.off.title:GetText()")         == "Boss mods is off"
    assert c.eval("return ns.SettingsUI.sections.bossmods:IsShown()") is False
    # on, with More options open
    c.eval("ns.DB:SetSetting('bossmods.on', true); ns.DB:SetSetting('settingsMore.bossmods', true); ns.SettingsUI:Refresh()")
    c.eval("ns.SettingsUI:OpenBossMods('GruulsLair')")
    w.tick(0.5)
    texts = c.eval_py("local o = {}; local function walk(f) for _, r in ipairs({ f:GetRegions() }) do "
                      "if r.GetText and r:IsVisible() and r:GetText() then o[#o + 1] = r:GetText() end end; "
                      "for _, k in ipairs({ f:GetChildren() }) do walk(k) end end; walk(UIParent); return o")
    for t in ("Boss mods", "Timer bars", "Warnings", "Range frame", "My role", "Alerts for other roles",
              "DBM and BigWigs timers", "Try it", "Bosses", "Gruul's Lair", "Gruul the Dragonkiller"):
        assert t in texts, t
    # an alert's switch turns that alert off
    key = c.eval("return ns.BossMod:Mod('GruulsLair:Gruul').alerts[1].key")
    assert c.eval("return ns.BossMod:AlertOn('GruulsLair:Gruul', ...)", key) is True
    c.eval("ns.BossMod:SetAlertOn('GruulsLair:Gruul', ..., false)", key)
    assert c.eval("return ns.BossMod:AlertOn('GruulsLair:Gruul', ...)", key) is False
    # Interface > Looks > Boss mods
    c.eval("ns.SettingsUI:SelectSection('look.bossmods')")
    w.tick(0.5)
    texts = c.eval_py("local o = {}; local function walk(f) for _, r in ipairs({ f:GetRegions() }) do "
                      "if r.GetText and r:IsVisible() and r:GetText() then o[#o + 1] = r:GetText() end end; "
                      "for _, k in ipairs({ f:GetChildren() }) do walk(k) end end; walk(UIParent); return o")
    assert "Boss mods" in texts and "Try it" in texts, texts
    w.assert_no_errors()


@case
def every_boss_has_a_try_it_that_plays_its_alerts():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.bossmods.look', 'halo'); __warns = {}; "
           "ns:On('BOSSMOD_WARN', function(w) __warns[#__warns + 1] = w end)")
    keys = c.eval_py("local o = {}; for _, d in ipairs(ns.BossMod:Mods()) do o[#o + 1] = d.key end; return o")
    assert len(keys) >= 50, len(keys)
    quiet = []
    for key in keys:
        c.eval("__warns = {}; __bars = 0")
        ok, length = c.eval_py("return { ns.BossModUI:TryBoss(...) }", key)
        assert ok, key
        seen = 0
        t = 0.0
        while t < length + 1:
            w.tick(0.5)
            t += 0.5
            seen = max(seen, c.eval("return #ns.BossMod:Bars()"))
        warns = c.eval("return #__warns")
        if warns == 0 and seen == 0:
            quiet.append(key)
        assert c.eval("return ns.BossMod:Active()") is None, key
        assert c.eval("return ns.BossMod.preview") is False, key
    assert not quiet, quiet
    w.assert_no_errors()


@case
def a_long_fight_tries_in_every_look():
    for look in LOOKS:
        w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
        c.eval("ns.DB:SetSetting('ui.bossmods.look', ...)", look)
        for key in ("BlackTemple:Illidan", "SerpentshrineCavern:Vashj"):
            ok, length = c.eval_py("return { ns.BossModUI:TryBoss(...) }", key)
            assert ok, key
            for _ in range(int((length + 1) / 0.5) + 1):
                w.tick(0.5)
        w.assert_no_errors()


LURKER, AMBUSHER, GUARDIAN = 21217, 21865, 21873


def lurker():
    f = Fight(npc=LURKER, name="The Lurker Below")
    f.c.fire("ENCOUNTER_START", 624, "The Lurker Below", 4, 25)
    f.w.tick(0.1)
    f.t0 = f.c.eval("return ns.BossMod:Active().t0")
    return f


def at(f, t):
    dt = f.t0 + t - f.c.eval("return GetTime()")
    if dt > 1e-6:
        f.w.tick(dt, step=min(0.5, dt))


def swing(f, src, dst, src_flags=BOSS_FLAGS):
    c = f.c
    c.combat_log(c.eval("return GetTime()"), "SWING_DAMAGE", False, src, "x", src_flags, 0, dst, "y", 0x514, 0, 100)
    f.w.tick(0.05)


def phase(f):
    return f.c.eval("return ns.BossMod:Active().phase")


def keys(f):
    return sorted(b["key"] for b in f.bars())


def unders(f):
    return [x["text"] for x in f.warns() if x["text"] == "Lurker submerged: adds"]


@case
def the_lurker_goes_under_with_his_adds_and_comes_back():
    f = lurker()
    assert keys(f) == ["spoutbar", "submerge"], keys(f)
    for t in range(5, 90, 5):
        at(f, t)
        swing(f, f.me, f.boss, ME_FLAGS)
    # no Submerge Visual in the log (16 Oct): his adds coming up say he went under
    at(f, 92)
    add1 = f.w.spawn_npc(AMBUSHER, "Coilfang Ambusher")
    swing(f, add1, f.me)
    assert unders(f) == ["Lurker submerged: adds"] and phase(f) == 2, (f.warns(), phase(f))
    assert keys(f) == ["emerge"], keys(f)
    # a spell still in flight lands on him; more adds: nothing more
    swing(f, f.me, f.boss, ME_FLAGS)
    add2 = f.w.spawn_npc(GUARDIAN, "Coilfang Guardian")
    swing(f, add2, f.me)
    for t in range(100, 150, 5):
        at(f, t)
        swing(f, f.me, add1, ME_FLAGS)
    assert phase(f) == 2 and len(unders(f)) == 1
    # his first sign after 20 s gone: he is back (submerge bar from now, Spout in 1-5 s)
    at(f, 152)
    swing(f, f.me, f.boss, ME_FLAGS)
    assert phase(f) == 1 and "Lurker is back" in [x["text"] for x in f.warns()], (phase(f), f.warns())
    assert keys(f) == ["spoutbar", "submerge"], keys(f)
    sub, spout = f.bar("submerge"), f.bar("spoutbar")
    assert 89 <= sub["rem"] <= 90.5 and spout["rem"] <= 5, (sub, spout)
    # an add still alive is no new submerge; a new one next time is
    at(f, 155)
    swing(f, add1, f.me)
    assert phase(f) == 1 and len(unders(f)) == 1
    at(f, 245)
    add3 = f.w.spawn_npc(AMBUSHER, "Coilfang Ambusher")
    swing(f, f.me, add3, ME_FLAGS)
    assert phase(f) == 2 and len(unders(f)) == 2, (phase(f), unders(f))
    f.c.fire("ENCOUNTER_END", 624, "The Lurker Below", 4, 25, 1)
    f.w.tick(0.1)
    f.w.assert_no_errors()


@case
def the_lurkers_submerge_seen_on_a_unit_sends_him_under():
    f = lurker()
    at(f, 30)
    f.c.target_npc(f.boss)
    # (a player's cast of the same spell is not his)
    f.c.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-4000-548-100-28819-0000000001", 28819)
    f.w.tick(0.1)
    assert phase(f) == 1
    f.c.fire("UNIT_SPELLCAST_SUCCEEDED", "target", "Cast-3-4000-548-100-28819-0000000002", 28819)
    f.w.tick(0.1)
    assert phase(f) == 2 and unders(f) == ["Lurker submerged: adds"], (phase(f), f.warns())
    assert keys(f) == ["emerge"], keys(f)
    f.w.assert_no_errors()


@case
def a_fight_ends_out_of_its_raid_or_on_the_bosss_next_pull():
    f = Fight()
    w, c = f.w, f.c
    w.enter_instance(name="Gruul's Lair", instance_id=565, max_players=25)
    w.tick(1)
    f.start()
    first = c.eval("return ns.BossMod:Active().id")
    w.tick(5)
    # (an ENCOUNTER_START again this soon is the same pull)
    f.start()
    assert c.eval("return ns.BossMod:Active().id") == first
    # released outside: no ENCOUNTER_END reaches me, the fight ends after 5 s out
    w.leave_instance()
    w.tick(4)
    assert c.eval("return ns.BossMod:Active() ~= nil") is True
    w.tick(1.5)
    assert c.eval("return ns.BossMod:Active()") is None
    assert f.bars() == [], f.bars()
    # inside, the ENCOUNTER_END missed some other way: the boss's next ENCOUNTER_START is a new pull
    w.enter_instance(name="Gruul's Lair", instance_id=565, max_players=25)
    w.tick(1)
    f.start()
    old = c.eval("return ns.BossMod:Active().id")
    w.tick(40)
    f.start()
    assert c.eval("return #ns.BossMod:Fights()") == 1
    assert c.eval("return ns.BossMod:Active().id") != old
    growth = next(x for x in f.bars() if x["key"] == f.key_of(36300))
    assert growth["rem"] > 29, growth
    f.end()
    w.assert_no_errors()


@case
def hurtful_strike_restarts_on_its_hit_and_the_strider_bar_loops():
    # Gruul, 17 Oct: Hurtful Strike logged no SPELL_CAST_SUCCESS; its hit (or a parry) restarts the tank bar
    f = Fight(role="tank")
    f.start()
    hurt = f.key_of(33813)
    f.w.tick(20)
    assert f.bar(hurt) is None
    f.log("SPELL_MISSED", 33813, "Hurtful Strike", f.me, "Alice", "PARRY")
    b = f.bar(hurt)
    assert b is not None and 7.5 <= b["rem"] <= 8, b
    f.w.tick(5)
    f.log("SPELL_DAMAGE", 33813, "Hurtful Strike", f.me, "Alice", 9000)
    assert 7.5 <= f.bar(hurt)["rem"] <= 8, f.bar(hurt)
    f.end()
    f.w.assert_no_errors()
    # Vashj, 17 Oct: no spawn event for the Striders; the bar loops every 63 s from the shield phase, as DBM and BW do
    v = Fight(npc=21212, name="Lady Vashj")
    c = v.c
    c.fire("ENCOUNTER_START", 628, "Lady Vashj", 4, 25)
    v.w.tick(0.1)
    m = "ns.BossMod:Active()"
    c.eval("ns.BossMod:Inject(" + m + ", 'PHASE 2')")
    t0 = c.eval("return GetTime()")
    assert 62.5 <= v.bar("strider")["rem"] <= 63, v.bar("strider")
    # four rounds later the bar is still on the 63 s beat (the ticker's half seconds don't add up)
    v.w.tick(63 * 4 + 10, step=0.5)
    now = c.eval("return GetTime()")
    rem = v.bar("strider")["rem"]
    assert abs((now - t0 + rem) - 63 * 5) < 0.2, (now - t0, rem)
    # phase 3 ends it
    c.eval("ns.BossMod:Inject(" + m + ", 'PHASE 3')")
    assert v.bar("strider") is None
    v.w.assert_no_errors()


@case
def every_data_file_passes_the_check():
    r = subprocess.run([sys.executable, os.path.join(DEV, "tools", "bossmods_check.py")], capture_output=True, text=True,
                       cwd=DEV)
    assert r.returncode == 0, r.stdout + r.stderr


if __name__ == "__main__":
    run_all()
