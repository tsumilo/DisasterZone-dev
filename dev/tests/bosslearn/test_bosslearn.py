#!/usr/bin/env python
"""Boss mods that learn from the guild's own pulls (Core/BossLearn.lua, Core/BossLearnMath.lua, UI/BossLearnUI.lua,
tools/bossmods_learned.py; mockup cleanup_template.html section 3; format dev/docs/bossmods/LEARNING.md).

Covers: the recorder on a simulated Gruul pull (the predicted events of each learnable bar, Shatter from its own cast
paired with Ground Slam's bar start, the 1.5 s debounce, players' casts ignored, unknown casts and boss lines with
their caps, alerts that never fired, phase times, kill and duration), a short wipe not kept, the 2,000-event cap,
an error in the recorder (the alerts carry on, recording stops, one debug line), nothing learned changing a running
pull, the learning rules (3 clean pulls, outliers, p10/p90, the clamp, too wide, far, fixed, phase-relative samples),
sharing with the guild (one summary per pull, its size and delay, suppression, the union of observations, nothing
sent in a fight, every odd or old message dropped), the storage caps, the developer's review (only for Tsumil, Use
applies the new id on that client only), the Settings rows, the boss pills and page, Try it's recording line and
made-up note (nothing saved or sent), the pop-up after a pull, the data's hook-driven bars marked learn = false,
and the dev tool against a fixture SavedVariables file. From the 16 Oct 2026 raid: an alert learning from its boss
line when its spell never shows (Leotheras's demon form), two copies of one pull keeping the better one (a copy that
came in mid-pull, one that ran into the next pull; stored ones tidied), no recording when the boss is already hurt,
and a pull that outlives a wipe while released not being clean.

Run: luaenv\\Scripts\\python.exe tests\\bosslearn\\test_bosslearn.py [-k name]
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(DEV, "tools"))

from _common import case, run_all, solo  # noqa: E402

import harness  # noqa: E402

ADDON = harness.ADDON_DIR
BOSS_FLAGS = 0xA48
ME_FLAGS = 0x511
GRUUL = 19044
KEY = "GruulsLair:Gruul"


class Fight:
    """A Gruul pull fed to one or more clients (all in the same world, so the same clock)."""

    def __init__(self, w, clients, boss):
        self.w, self.cs, self.boss = w, list(clients), boss

    def now(self):
        return self.cs[0].eval("return GetTime()")

    def start(self):
        for c in self.cs:
            c.fire("ENCOUNTER_START", 650, "Gruul the Dragonkiller", 4, 25)
        self.t0 = self.cs[0].eval("return ns.BossMod:Active().t0")
        return self

    def to(self, t, step=0.25):
        dt = self.t0 + t - self.now()
        if dt > 1e-6:
            self.w.tick(dt, step=min(step, dt))

    def log(self, sub, spell, name, flags=BOSS_FLAGS, src=None, dst="", dst_name="", *rest):
        for c in self.cs:
            c.combat_log(c.eval("return GetTime()"), sub, False, src or self.boss, "Gruul the Dragonkiller", flags, 0,
                         dst, dst_name, 0x514, 0, spell, name, 1, *rest)

    def yell(self, text, event="CHAT_MSG_MONSTER_YELL"):
        for c in self.cs:
            c.fire(event, text, "Gruul the Dragonkiller", "", "", "")

    def end(self, success=1):
        for c in self.cs:
            c.fire("ENCOUNTER_END", 650, "Gruul the Dragonkiller", 4, 25, success)
        self.w.tick(0.1)


def gruul(w, c, **settings):
    c.eval("ns.DB:SetSetting('bossmods.on', true)")
    for k, v in settings.items():
        c.eval("ns.DB:SetSetting(...)", "bossmods." + k, v)
    c.eval("__warns = {}; ns:On('BOSSMOD_WARN', function(x) __warns[#__warns + 1] = x end)")
    w.tick(0.2)
    return w.spawn_npc(GRUUL, "Gruul the Dragonkiller")


def standard_pull(f, end_at=70, success=1, extra=None):
    """Growth 30 / 60, Ground Slam 35 with Shatter 45, Hurtful Strike 50 / 58; extra(f) runs at 20 s."""
    f.to(20)
    if extra:
        extra(f)
    f.to(30)
    f.log("SPELL_AURA_APPLIED", 36300, "Growth", BOSS_FLAGS, None, f.boss, "Gruul the Dragonkiller", "BUFF")
    f.to(30.4)
    f.log("SPELL_AURA_APPLIED_DOSE", 36300, "Growth", BOSS_FLAGS, None, f.boss, "Gruul the Dragonkiller", "BUFF", 2)
    f.to(35)
    f.log("SPELL_CAST_START", 33525, "Ground Slam")
    f.to(45)
    f.log("SPELL_CAST_START", 33654, "Shatter")
    f.to(46)
    f.log("SPELL_CAST_SUCCESS", 33654, "Shatter")
    f.to(50)
    f.log("SPELL_CAST_SUCCESS", 33813, "Hurtful Strike")
    f.to(58)
    f.log("SPELL_CAST_SUCCESS", 33813, "Hurtful Strike")
    f.to(60)
    f.log("SPELL_AURA_APPLIED_DOSE", 36300, "Growth", BOSS_FLAGS, None, f.boss, "Gruul the Dragonkiller", "BUFF", 3)
    f.to(end_at)
    f.end(success)


def pulls(c, boss=KEY):
    return c.eval_py("return DisasterZoneBossLearnDB and DisasterZoneBossLearnDB.pulls[...] or {}", boss)


def close(a, b, tol=0.15):
    return a is not None and b is not None and abs(a - b) <= tol


def times(lst):
    return [round(x, 1) for x in (lst or [])]


def seed_pulls(c, n, slam=(34.2, 35.0, 36.8), leader="Kaelor-Thunderstrike", at0=None):
    """n clean Gruul pulls stored as if recorded earlier (Ground Slam's first at slam[i], Growth every 30 s)."""
    c.eval("""
        local n, slams, leader, at0 = ...
        local BL, def = ns.BossLearn, ns.BossMod:Mod('GruulsLair:Gruul')
        local ds = BL.Plan(def).ds
        for i = 1, n do
            local s = slams[(i - 1) % #slams + 1]
            BL:AddPull('GruulsLair:Gruul', { id = 'GruulsLair:Gruul|' .. leader .. '|' .. (at0 + i * 1000), at = at0 + i * 1000,
                leader = leader, dur = 120, kill = true, clean = true, ds = ds, av = ns.version, from = 'me', src = 1,
                o = { growth = { 30, 60, 90 }, slam = { s }, shatter = { s + 10 } }, g = { shatter = { s } },
                nf = { 'cavein' } })
        end
        BL:Relearn('GruulsLair:Gruul')
    """, n, c._to_lua(list(slam)), leader, at0 or c.eval("return GetServerTime()") - 100000)


# ------------------------------------------------------------------------------------------------------------------
# the recorder
# ------------------------------------------------------------------------------------------------------------------
@case
def the_recorder_notes_a_gruul_pull():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    boss = gruul(w, c)
    f = Fight(w, [c], boss).start()
    assert c.eval("return ns.BossMod:Active().rec ~= nil") is True
    assert c.eval("return ns.CombatLog:IsSubscribed('bosslearn')") is True

    def extra(f):
        # a raider's Growth (same id) is not Gruul's; 13 different unknown boss casts (12 kept), one of them thrice
        f.log("SPELL_AURA_APPLIED", 36300, "Growth", ME_FLAGS, c.eval("return UnitGUID('player')"))
        for i in range(13):
            f.log("SPELL_CAST_SUCCESS", 99001 + i, "Mystery %d" % i)
        f.log("SPELL_CAST_SUCCESS", 99001, "Mystery 0")
        f.log("SPELL_CAST_SUCCESS", 99001, "Mystery 0")
        # boss lines no trigger knows: 7 different (6 kept), one twice, one too long (cut to 120 bytes)
        f.yell("Come... and die.")
        f.yell("Come... and die.")
        f.yell("x" * 130)
        for i in range(5):
            f.yell("Line %d" % i, "CHAT_MSG_RAID_BOSS_EMOTE")
    standard_pull(f, extra=extra)
    assert c.eval("return ns.CombatLog:IsSubscribed('bosslearn')") is False
    w.tick(0.5)
    ps = pulls(c)
    assert len(ps) == 1, ps
    p = ps[0]
    assert p["clean"] is True and p["kill"] is True and close(p["dur"], 70, 0.3), p
    assert p["leader"] == c.eval("return ns.Util.PlayerKey()"), p["leader"]
    o = p["o"]
    assert times(o["growth"]) == [30.0, 60.0], o            # (30.4: within 1.5 s, one event; the raider's ignored)
    assert times(o["slam"]) == [35.0], o
    assert times(o["shatter"]) == [45.0], o                 # (its SUCCESS 1 s after the START: the same cast)
    assert times(p["g"]["shatter"]) == [35.0], p.get("g")   # (Shatter's bar started by Ground Slam's cast)
    assert times(o["hurtful"]) == [50.0, 58.0], o
    assert "reverb" not in o
    assert set(p["nf"]) >= {"cavein", "reverb"} and "slam" not in p["nf"], p["nf"]
    u = p["u"]
    assert len(u) == 12, u
    first = next(x for x in u if x["id"] == 99001)
    assert first["n"] == 3 and first["name"] == "Mystery 0", first
    y = p["y"]
    assert len(y) == 6, y
    assert y[0]["text"] == "Come... and die." and y[0]["n"] == 2, y
    assert len(y[1]["text"]) == 120, len(y[1]["text"])
    assert p["ds"] == c.eval("return ns.BossLearn.Plan(ns.BossMod:Mod('GruulsLair:Gruul')).ds")
    w.assert_no_errors()


@case
def a_wipe_under_20_s_is_not_kept_and_phases_are_noted():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    boss = gruul(w, c)
    f = Fight(w, [c], boss).start()
    f.to(12)
    f.log("SPELL_CAST_START", 33525, "Ground Slam")
    f.to(15)
    f.end(0)
    w.tick(1)
    assert pulls(c) == [], pulls(c)
    # a longer pull with a phase change: its time is kept
    f.start()
    f.to(40)
    c.eval("ns.BossMod:Inject(ns.BossMod:Active(), 'PHASE 2')")
    f.to(41)
    f.end(0)
    w.tick(1)
    ps = pulls(c)
    assert len(ps) == 1 and ps[0]["kill"] is False and ps[0]["clean"] is True, ps
    assert [(x["n"], round(x["t"])) for x in ps[0]["ph"]] == [(2, 40)], ps[0].get("ph")
    w.assert_no_errors()


@case
def a_fight_that_starts_as_i_come_in_is_not_recorded():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    boss = gruul(w, c)
    c.fire("PLAYER_ENTERING_WORLD", False, False)
    f = Fight(w, [c], boss).start()
    assert c.eval("return ns.BossMod:Active().rec == nil") is True
    assert c.eval("return ns.BossMod:Active().def.key") == KEY     # (the alerts run as ever)
    f.to(30)
    f.end(1)
    w.tick(0.5)
    assert pulls(c) == []
    w.tick(3)
    f.start()
    assert c.eval("return ns.BossMod:Active().rec ~= nil") is True
    f.end(0)
    w.assert_no_errors()


@case
def the_recorder_stops_at_2000_events():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    boss = gruul(w, c)
    f = Fight(w, [c], boss).start()
    f.to(25)
    # (2,100 Growths 1.6 s apart on a clock of its own: each one a recorded event until the cap)
    c.eval("""
        local guid = ...
        local real, k, t0 = GetTime, 0, GetTime()
        GetTime = function() return t0 + k end
        for i = 1, 2100 do
            k = k + 1.6
            ns.BossLearn.OnLog(nil, nil, 'SPELL_AURA_APPLIED', nil, guid, 'Gruul', 0xA48, 0, guid, 'Gruul', 0, 0, 36300, 'Growth')
        end
        GetTime = real
    """, boss)
    r = c.eval_py("local r = ns.BossMod:Active().rec; return { on = r.on, n = r.n, stop = r.stop, o = #r.o[1] }")
    assert r["on"] is False and r["n"] == 2000 and "2,000" in r["stop"], r
    assert c.eval("return ns.CombatLog:IsSubscribed('bosslearn')") is False
    # the alerts still run
    f.log("SPELL_CAST_START", 33525, "Ground Slam")
    assert c.eval("for _, x in ipairs(__warns) do if x.text:find('Ground Slam') then return true end end return false")
    f.end(1)
    w.tick(0.5)
    ps = pulls(c)
    assert len(ps) == 1 and ps[0]["clean"] is False and "2,000" in ps[0]["stop"], [(p["clean"], p.get("stop")) for p in ps]
    # (not clean: never learned from, never shared)
    assert c.eval("return ns.BossLearn:BossStatus('GruulsLair:Gruul').usable") == 0
    w.assert_no_errors()


@case
def an_error_in_the_recorder_stops_only_the_recording():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('debug', true)")
    boss = gruul(w, c)
    f = Fight(w, [c], boss).start()
    f.to(21)
    n0 = len(c.chat_frame)
    # (the recorder's lookup table breaks: a copy of its plan whose combat-log table throws)
    c.eval("local r = ns.BossMod:Active().rec; local real = r.plan; "
           "r.plan = setmetatable({ watch = setmetatable({}, { __index = function() error('boom') end }) }, { __index = real })")
    f.log("SPELL_CAST_START", 33525, "Ground Slam")
    f.log("SPELL_CAST_START", 33654, "Shatter")
    # the alerts went on: the warning, the Shatter bar, the slam bar again
    assert c.eval("for _, x in ipairs(__warns) do if x.text:find('Ground Slam') then return true end end return false")
    bars = c.eval_py("local o = {}; for _, b in ipairs(ns.BossMod:Bars()) do o[#o + 1] = b.key end; return o")
    assert "shatter" in bars and "slam" in bars, bars
    st = c.eval_py("local r = ns.BossMod:Active().rec; return { on = r.on, stop = r.stop }")
    assert st["on"] is False and "boom" in st["stop"], st
    lines = [str(x) for x in c.chat_frame[n0:] if "boss learning" in str(x)]
    assert len(lines) == 1 and "recording stopped" in lines[0], lines
    assert c.eval("return #DisasterZoneBossLearnDB.log") == 1
    # the screen side too: a broken recording line or band never stops the bars, warnings or range frame drawing
    c.eval("ns.BossModUI:Setup(); local real = ns.BossLearnUI.RecLine; ns.BossLearnUI.RecLine = function() error('line') end; "
           "for _, b in ipairs(ns.BossMod:Bars()) do b.learned = true; b.hi = b.lo + 3 end; "
           "local L = ns.BossModUI:Look(); local track = L.track; L.track = function() error('band') end; "
           "ns.BossModUI:Draw(0); ns.BossLearnUI.RecLine = real; L.track = track")
    f.end(1)
    w.tick(0.5)
    assert pulls(c)[0]["clean"] is False
    w.assert_no_errors()


@case
def nothing_learned_changes_a_running_pull():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    boss = gruul(w, c)
    seed_pulls(c, 3)
    lw = c.eval_py("return ns.BossLearn:Snapshot(ns.BossMod:Mod('GruulsLair:Gruul'))")
    assert lw["slam"]["start"] == [34, 37], lw
    f = Fight(w, [c], boss).start()
    b = c.eval_py("for _, b in ipairs(ns.BossMod:Bars()) do if b.key == 'slam' then return { rem = b.rem, l = b.learned } end end")
    assert 33.5 < b["rem"] <= 34 and b["l"] is True, b
    # learning moves on in the middle of the pull (as if a guild summary landed): the pull keeps its numbers
    c.eval("local e = DisasterZoneBossLearnDB.learned['GruulsLair:Gruul'].alerts.slam; e.start.lo, e.start.hi = 38, 40; "
           "e.cd = { state = 'ok', applied = true, lo = 70, hi = 74, p = 3, n = 3 }")
    f.to(36)
    f.log("SPELL_CAST_START", 33525, "Ground Slam")
    b = c.eval_py("for _, b in ipairs(ns.BossMod:Bars()) do if b.key == 'slam' then return { rem = b.rem, l = b.learned } end end")
    assert 71.5 < b["rem"] <= 72 and not b.get("l"), b         # (the data's 72-80: the pull started without a cd)
    assert c.eval_py("return ns.BossMod:Active().lw.slam.start") == [34, 37]
    f.end(1)
    w.tick(0.2)
    # the next pull starts with what is learned now (the seeded change, or what the last pull taught)
    c.eval("DisasterZoneBossLearnDB.learned['GruulsLair:Gruul'].alerts.slam.start = { state = 'ok', applied = true, "
           "lo = 38, hi = 40, p = 3, n = 3 }")
    f.start()
    b = c.eval_py("for _, b in ipairs(ns.BossMod:Bars()) do if b.key == 'slam' then return { rem = b.rem } end end")
    assert 37.5 < b["rem"] <= 38, b
    f.end(0)
    # learning off: the data's numbers, nothing recorded
    c.eval("ns.DB:SetSetting('bossmods.learn', false)")
    f.start()
    b = c.eval_py("for _, b in ipairs(ns.BossMod:Bars()) do if b.key == 'slam' then return { rem = b.rem } end end")
    assert 32.5 < b["rem"] <= 33, b
    assert c.eval("return ns.BossMod:Active().rec == nil and ns.BossMod:Active().lw == nil") is True
    f.end(0)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# the rules
# ------------------------------------------------------------------------------------------------------------------
@case
def the_learning_rules():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    r = c.eval_py("""
        local M = ns.BossLearnMath
        local function S(list) local o = {}; for i, v in ipairs(list) do o[i] = { v = v[1], p = v[2] } end; return o end
        local out = {}
        -- 2 clean pulls: still the data's
        out.two = M.Fit(S({ { 35, 'a' }, { 36, 'b' }, { 35.5, 'b' } }), { 33, 40 })
        -- 3: [min, max] rounded out to 0.5 s; a missed cast (an interval twice as long) is dropped
        out.three = M.Fit(S({ { 34.2, 'a' }, { 35, 'b' }, { 36.8, 'c' }, { 70, 'c' } }), { 33, 40 })
        -- 10 samples or more: [p10, p90]
        local s = {}
        for i = 1, 12 do s[i] = { 29 + i, 'p' .. (i % 4) } end
        out.pct = M.Fit(S(s), { 30, 45 })
        -- partly below 0.75 x the data's min: clamped
        out.clamp = M.Fit(S({ { 24, 'a' }, { 25, 'b' }, { 26, 'c' } }), { 33, 40 })
        -- wholly outside: far, not used
        out.far = M.Fit(S({ { 60, 'a' }, { 61, 'b' }, { 62, 'c' } }), { 102, 115 })
        -- wider than max(4 s, 1.25 x the data's width): varies, not used
        out.wide = M.Fit(S({ { 26, 'a' }, { 30, 'b' }, { 32.5, 'c' } }), { 30, 30 })
        -- a fixed follow-up: measured, never used
        out.fixed = M.Fit(S({ { 10, 'a' }, { 10.1, 'b' }, { 10.2, 'c' } }), { 10, 10 }, true)
        -- a pull shorter than 20 s or not clean never counts
        out.short = M.Usable({ clean = true, dur = 15, ds = 'x' }, 'x')
        out.dirty = M.Usable({ clean = false, dur = 100, ds = 'x' }, 'x')
        out.stale = M.Usable({ clean = true, dur = 100, ds = 'y' }, 'x')
        out.ok = M.Usable({ clean = true, dur = 100, ds = 'x' }, 'x')
        -- phase-relative samples; nothing across a phase change
        local spec = M.Spec({ key = 'x', kind = 'bar', spell = 1, on = 'CAST 1', start = { 10, 12 }, cd = 20, phase = 2 })
        out.ps, out.pc = M.Samples(spec, { dur = 200, o = { x = { 5, 61, 81.5 } }, ph = { { n = 2, t = 50 } } })
        local any = M.Spec({ key = 'y', kind = 'bar', spell = 2, on = 'CAST 2', cd = 30 })
        out.as, out.ac = M.Samples(any, { dur = 200, o = { y = { 10, 40, 75, 105 } }, ph = { { n = 2, t = 50 } } })
        -- Shatter: from Ground Slam's bar start to its own cast
        local sh = M.Spec(ns.BossMod:Mod('GruulsLair:Gruul').byKey.shatter)
        out.shmode, out.shfixed = sh.mode, sh.fixed
        out.ss, out.sc = M.Samples(sh, { dur = 200, o = { shatter = { 45, 117 } }, g = { shatter = { 35, 107.2 } } })
        -- not learnable
        local bm = ns.BossMod:Mod('GruulsLair:Gruul').byKey
        out.warn = M.Learnable(bm.slamwarn)
        out.loop = M.Learnable({ key = 'l', kind = 'bar', spell = 3, cd = 5, loop = true })
        out.off = M.Learnable({ key = 'l', kind = 'bar', spell = 3, cd = 5, learn = false })
        return out
    """)
    assert r["two"]["state"] == "wait" and r["two"]["p"] == 2 and not r["two"].get("applied"), r["two"]
    t = r["three"]
    assert t["state"] == "ok" and t["applied"] and (t["lo"], t["hi"]) == (34, 37) and t["dropped"] == 1, t
    p = r["pct"]
    assert (p["mlo"], p["mhi"]) == (31, 40) and p["n"] == 12, p
    cl = r["clamp"]
    assert cl["state"] == "ok" and cl["lo"] == 24.75 and cl["hi"] == 26 and cl["clamped"], cl
    assert r["far"]["state"] == "far" and not r["far"].get("applied"), r["far"]
    assert r["wide"]["state"] == "varies" and not r["wide"].get("applied"), r["wide"]
    assert r["fixed"]["state"] == "fixed" and not r["fixed"].get("applied") and r["fixed"]["mlo"] == 10, r["fixed"]
    assert r["short"] is False and r["dirty"] is False and r["stale"] is False and r["ok"] is True
    assert r["ps"] == [11] and r["pc"] == [20.5], (r["ps"], r["pc"])
    assert r["as"] == [] and r["ac"] == [30, 30], (r["as"], r["ac"])   # (40 -> 75 crosses the phase change)
    assert r["shmode"] == "cast" and r["shfixed"] is True
    assert r["ss"] == [] and r["sc"] == [10, 9.8], (r["ss"], r["sc"])
    assert r["warn"] is False and r["loop"] is False and r["off"] is False
    w.assert_no_errors()


@case
def every_bar_a_fight_script_starts_is_not_learned():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    found = []
    folder = os.path.join(ADDON, "Data", "BossMods")
    for fn in sorted(os.listdir(folder)):
        src = open(os.path.join(folder, fn), encoding="utf-8").read()
        for block in re.split(r'\nB\["', src)[1:]:
            boss = block.split('"', 1)[0]
            parts = block.split("fn = {", 1)
            if len(parts) < 2:
                continue
            for key in sorted(set(re.findall(r'm:Bar\("([a-z0-9]+)"', parts[1]))):
                found.append((boss, key))
    assert len(found) >= 10, found
    for boss, key in found:
        ok = c.eval("local d = ns.BossMod:Mod(...); local a = d and d.byKey[select(2, ...)]; "
                    "return a ~= nil and ns.BossLearnMath.Learnable(a)", boss, key)
        assert ok is False, (boss, key, "a hook starts this bar: give it learn = false")
    # (a hook that starts a learnable bar at runtime marks it in the pull: never learned from that pull)
    boss = gruul(w, c)
    f = Fight(w, [c], boss).start()
    f.to(21)
    c.eval("local m = ns.BossMod:Active(); m.inHook = true; m:Bar('slam', 5); m.inHook = nil")
    f.end(1)
    w.tick(0.5)
    assert pulls(c)[0]["hk"] == {"slam": True}
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# sharing
# ------------------------------------------------------------------------------------------------------------------
def three(w_kwargs=None):
    from harness import Client
    w, a = solo("Alice", class_file="PALADIN", guild_rank=0)
    b = Client(w, "Bob", class_file="WARRIOR", guild_rank=3)
    b.load_addon()
    cl = Client(w, "Carol", class_file="MAGE", guild_rank=3)
    cl.load_addon()
    w.tick(2)
    for x in (a, b, cl):
        x.eval("ns.DB:SetSetting('bossmods.on', true)")
    w.make_raid([a, b], leader=a)
    w.tick(1)
    boss = w.spawn_npc(GRUUL, "Gruul the Dragonkiller")
    return w, a, b, cl, boss


def summaries(w):
    """The boss learning messages sent (AceComm parts of one message joined): [(sender, time, chat type, bytes)]."""
    out = []
    for e in w.addon_log:
        if e["prefix"] != "CDLk":
            continue
        t = e["text"].encode("latin-1", "replace") if isinstance(e["text"], str) else e["text"]
        if t[:1] in (b"\x02", b"\x03") and out and out[-1]["sender"] == e["sender"]:
            out[-1]["bytes"] += len(t)
            continue
        out.append({"sender": e["sender"], "time": e["time"], "chat_type": e["chat_type"], "bytes": len(t)})
    return out


@case
def a_pull_is_shared_once_after_it_and_the_guild_learns_from_it():
    w, a, b, cl, boss = three()
    f = Fight(w, [a, b], boss).start()
    standard_pull(f, extra=None)
    end_at = w.now
    assert summaries(w) == []
    w.tick(2.5)
    assert summaries(w) == [], "sent before 3 s"
    w.tick(10)
    sent = summaries(w)
    assert len(sent) == 1, [(e["sender"], e["time"]) for e in sent]
    e = sent[0]
    assert e["chat_type"] == "GUILD" and 3 <= e["time"] - end_at <= 12.2, (e["chat_type"], e["time"] - end_at)
    assert e["bytes"] < 600, e["bytes"]          # (a few hundred bytes)
    w.tick(5)
    # the one who didn't send heard it, merged it and held back; Carol (not in the raid) stored the pull
    for x in (a, b):
        ps = pulls(x)
        mine = e["sender"] == x.full_name
        assert len(ps) == 1 and ps[0]["src"] == (1 if mine else 2), (x.full_name, ps)
    pc = pulls(cl)
    assert len(pc) == 1 and pc[0]["from"] == e["sender"] and pc[0]["clean"] is True, pc
    assert times(pc[0]["o"]["slam"]) == [35.0] and times(pc[0]["o"]["growth"]) == [30.0, 60.0], pc[0]["o"]
    assert pc[0]["leader"] == a.eval("return ns.Util.PlayerKey()")
    w.assert_no_errors()


@case
def summaries_merge_as_a_union_and_wait_out_a_fight():
    w, a, b, cl, boss = three()
    msg = a.eval_py("""
        local BL = ns.BossLearn
        local ds = BL.Plan(ns.BossMod:Mod('GruulsLair:Gruul')).ds
        return { t = 'BL', v = 1, av = ns.version, b = 'GruulsLair:Gruul', ds = ds, at = GetServerTime() - 60,
                 l = 'Kaelor-Thunderstrike', d = 1200, k = 1, o = { growth = { 300, 300 }, slam = { 350 } },
                 g = { shatter = { 350 } }, ph = { 2, 400 }, nf = { 'cavein' }, u = { 36241, 3, 500 } }
    """)
    # a guildmate's summary of the same pull with one more Growth and a Shatter, 0.3 s off: one union
    msg2 = dict(msg)
    msg2["o"] = {"growth": [303, 300, 300], "shatter": [453]}
    msg2["at"] = msg["at"] + 4
    cl.eval("__MOCK.combat = true")
    ok = cl.eval("local m = ...; ns.BossLearn:OnMessage('Bob-Thunderstrike', m, 'GUILD'); return #ns.BossLearn.inbox",
                 cl._to_lua(msg))
    assert ok == 1
    w.tick(1)
    assert pulls(cl) == [], "merged during a fight"
    cl.eval("__MOCK.combat = false")
    cl.fire("PLAYER_REGEN_ENABLED")
    w.tick(1)
    assert len(pulls(cl)) == 1
    cl.eval("local m = ...; ns.BossLearn:OnMessage('Dave-Thunderstrike', m, 'GUILD')", cl._to_lua(msg2))
    w.tick(1)
    ps = pulls(cl)
    assert len(ps) == 1 and ps[0]["src"] == 2, ps
    assert times(ps[0]["o"]["growth"]) == [30.0, 60.0, 90.3], ps[0]["o"]     # (30.3 and 60.3: seen already)
    assert times(ps[0]["o"]["shatter"]) == [45.3], ps[0]["o"]
    assert [(x["n"], x["t"]) for x in ps[0]["ph"]] == [(2, 40.0)]
    # the same pull timed from another start (2 s off: someone who came in late): dropped, never merged
    msg3 = dict(msg)
    msg3["o"] = {"growth": [320, 300, 300], "slam": [370]}
    cl.eval("local m = ...; ns.BossLearn:OnMessage('Erin-Thunderstrike', m, 'GUILD')", cl._to_lua(msg3))
    w.tick(1)
    ps = pulls(cl)
    assert len(ps) == 1 and ps[0]["src"] == 2 and times(ps[0]["o"]["growth"]) == [30.0, 60.0, 90.3], ps
    assert cl.eval("return DisasterZoneBossLearnDB.log[#DisasterZoneBossLearnDB.log]").find("clock") > 0
    # a recording that stopped never spoils a clean record; a clean one takes the place of a stopped one
    r = cl.eval_py("""
        local BL = ns.BossLearn
        local a = { id = 'x|L|100', at = 100, leader = 'L', dur = 60, clean = true, o = { slam = { 35 } } }
        BL:AddPull('GruulsLair:Gruul', a)
        BL:AddPull('GruulsLair:Gruul', { id = 'x|L|101', at = 101, leader = 'L', dur = 60, clean = false, from = 'me',
            stop = 'error: x', o = {} })
        local b = { id = 'y|L|500', at = 500, leader = 'L', dur = 60, clean = false, from = 'me', stop = 'error: y', o = {} }
        BL:AddPull('GruulsLair:Gruul', b)
        BL:AddPull('GruulsLair:Gruul', { id = 'y|L|505', at = 505, leader = 'L', dur = 60, clean = true, o = { slam = { 36 } } })
        return { a = { clean = a.clean, src = a.src, slam = a.o.slam }, b = { clean = b.clean, src = b.src, slam = b.o.slam } }
    """)
    assert r["a"] == {"clean": True, "src": 2, "slam": [35]}, r
    assert r["b"] == {"clean": True, "src": 2, "slam": [36]}, r
    w.assert_no_errors()


@case
def odd_or_old_summaries_are_dropped_whole():
    w, a, b, cl, boss = three()
    base = cl.eval_py("""
        local ds = ns.BossLearn.Plan(ns.BossMod:Mod('GruulsLair:Gruul')).ds
        return { t = 'BL', v = 1, av = ns.version, b = 'GruulsLair:Gruul', ds = ds, at = GetServerTime() - 60,
                 l = 'Kaelor-Thunderstrike', d = 1200, k = 1, o = { growth = { 300, 300 } } }
    """)
    bad = {
        "old version": {"av": "1.3.5"},
        "format": {"v": 2},
        "boss": {"b": "GruulsLair:Nobody"},
        "signature": {"ds": "deadbeef"},
        "past the pull": {"o": {"growth": [300, 300, 700]}},
        "negative": {"o": {"growth": [300, -5]}},
        "alert": {"o": {"slamwarn": [300]}},
        "duration": {"d": 40000},
        "short": {"d": 150},
        "phase": {"ph": [2, 99999]},
        "yell": {"y": [10, 1, "a|cffff0000red|r"]},
        "casts": {"u": [36241, 3]},
        "leader": {"l": ""},
    }
    for why, change in bad.items():
        m = dict(base)
        m.update(change)
        res = cl.eval_py("local m = ...; return { ns.BossLearn:Validate(m) }", cl._to_lua(m))
        assert not res or res[0] is None, (why, res)
    ok = cl.eval_py("local m = ...; return { ns.BossLearn:Validate(m) }", cl._to_lua(base))
    assert ok[0] is not None, ok
    # through the guild channel: the bad ones never reach the store
    for why, change in bad.items():
        m = dict(base)
        m.update(change)
        cl.eval("local m = ...; ns.BossLearn:OnMessage('Bob-Thunderstrike', m, 'GUILD')", cl._to_lua(m))
        w.tick(0.2)
    assert pulls(cl) == [], pulls(cl)
    # not from the guild channel: ignored
    cl.eval("local m = ...; ns.BossLearn:OnMessage('Bob-Thunderstrike', m, 'RAID')", cl._to_lua(base))
    w.tick(0.2)
    assert pulls(cl) == []
    # a summary that makes the code itself fail (here: the merge throws) is logged and dropped, never thrown; the
    # summaries after it still count, and so does learning from the time after a pull
    log0 = cl.eval("return #ns.BossLearn.Store().log")
    cl.eval("__realAccept = ns.BossLearn.Accept; ns.BossLearn.Accept = function(self, s, m) "
            "if m.l == 'Boom-Thunderstrike' then error('merge broke') end return __realAccept(self, s, m) end")
    boom = dict(base)
    boom["l"] = "Boom-Thunderstrike"
    cl.eval("local a, b = ...; ns.BossLearn:OnMessage('Bob-Thunderstrike', a, 'GUILD'); "
            "ns.BossLearn:OnMessage('Bob-Thunderstrike', b, 'GUILD')", cl._to_lua(boom), cl._to_lua(base))
    w.tick(0.2)
    cl.eval("ns.BossLearn.Accept = __realAccept")
    assert len(pulls(cl)) == 1, pulls(cl)
    logs = cl.eval_py("local o = {}; for i, l in ipairs(ns.BossLearn.Store().log) do if i > %d then o[#o + 1] = l end end "
                      "return o" % log0)
    assert any("merge broke" in str(l) for l in logs), logs
    cl.eval("__realAfter = ns.BossLearn.AfterPull; ns.BossLearn.AfterPull = function() error('after broke') end")
    f = Fight(w, [cl], boss).start()
    f.to(25)
    f.end(1)
    w.tick(0.5)
    cl.eval("ns.BossLearn.AfterPull = __realAfter")
    assert any("after broke" in str(l) for l in cl.eval_py("return ns.BossLearn.Store().log")), "logged, not thrown"
    # sharing off: nothing taken
    cl.eval("ns.DB:SetSetting('bossmods.learnShare', false)")
    n = len(pulls(cl))
    cl.eval("local m = ...; ns.BossLearn:OnMessage('Bob-Thunderstrike', m, 'GUILD')", cl._to_lua(base))
    w.tick(0.2)
    assert len(pulls(cl)) == n
    w.assert_no_errors()


@case
def nothing_is_sent_in_a_fight_or_with_sharing_off():
    w, a, b, cl, boss = three()
    b.eval("ns.DB:SetSetting('bossmods.learnShare', false)")
    f = Fight(w, [a, b], boss).start()
    standard_pull(f)
    a.eval("__MOCK.combat = true")
    w.tick(14)
    assert summaries(w) == [], "sent in combat"
    a.eval("__MOCK.combat = false")
    w.tick(6)
    sent = summaries(w)
    assert len(sent) == 1 and sent[0]["sender"].startswith("Alice"), [(e["sender"]) for e in sent]
    w.tick(1)
    assert len(pulls(b)) == 1 and pulls(b)[0]["src"] == 1     # (Bob: sharing off, his own pull only)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# storage
# ------------------------------------------------------------------------------------------------------------------
@case
def storage_keeps_30_pulls_a_boss_and_2000_in_all():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    r = c.eval_py("""
        local BL = ns.BossLearn
        local function rec(boss, i) return { id = boss .. '|L|' .. i, at = 1000000 + i * 100, leader = 'L', dur = 60,
            kill = true, clean = true, ds = 'x', o = {} } end
        for i = 1, 35 do BL:AddPull('GruulsLair:Gruul', rec('GruulsLair:Gruul', i)) end
        local g = DisasterZoneBossLearnDB.pulls['GruulsLair:Gruul']
        local out = { n = #g, first = g[1].at }
        for b = 1, 70 do for i = 1, 30 do BL:AddPull('X:' .. b, rec('X:' .. b, b * 1000 + i)) end end
        local total = 0
        for _, l in pairs(DisasterZoneBossLearnDB.pulls) do total = total + #l end
        out.total = total
        out.gruul = DisasterZoneBossLearnDB.pulls['GruulsLair:Gruul'] and #DisasterZoneBossLearnDB.pulls['GruulsLair:Gruul'] or 0
        out.last = #DisasterZoneBossLearnDB.pulls['X:70']
        return out
    """)
    assert r["n"] == 30 and r["first"] == 1000000 + 6 * 100, r
    assert r["total"] == 2000 and r["gruul"] == 0 and r["last"] == 30, r     # (the oldest anywhere went first)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# what the 16 Oct 2026 raid showed
# ------------------------------------------------------------------------------------------------------------------
LEO = "SerpentshrineCavern:Leotheras"


@case
def an_alert_learns_from_its_boss_line_when_its_spell_never_shows():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('bossmods.on', true)")
    w.tick(3)
    boss = w.spawn_npc(21215, "Leotheras the Blind")
    c.fire("ENCOUNTER_START", 625, "Leotheras the Blind", 4, 25)
    t0 = c.eval("return ns.BossMod:Active().t0")

    def to(t):
        dt = t0 + t - c.eval("return GetTime()")
        if dt > 1e-6:
            w.tick(dt, step=min(0.5, dt))

    def yell(text):
        c.fire("CHAT_MSG_MONSTER_YELL", text, "Leotheras the Blind", "", "", "")

    to(30)
    yell("Finally, my banishment ends!")
    to(91)
    yell("Be gone, trifling elf. I am in control now!")
    # (where his Metamorphosis aura does show, 2 s after the line: the same event)
    to(93)
    c.combat_log(c.eval("return GetTime()"), "SPELL_AURA_APPLIED", False, boss, "Leotheras the Blind", BOSS_FLAGS, 0,
                 boss, "Leotheras the Blind", BOSS_FLAGS, 0, 37673, "Metamorphosis", 1, "BUFF")
    to(196.5)
    yell("Be gone, trifling elf. I am in control now!")
    to(301.5)
    yell("Be gone, trifling elf. I am in control now!")
    to(330)
    c.fire("ENCOUNTER_END", 625, "Leotheras the Blind", 4, 25, 0)
    w.tick(1)
    ps = pulls(c, LEO)
    assert len(ps) == 1 and times(ps[0]["o"]["demon"]) == [91.0, 196.5, 301.5], ps
    r = c.eval_py("""
        local M, def = ns.BossLearnMath, ns.BossMod:Mod(...)
        local s = M.Spec(def.byKey.demon)
        local st, cd = M.Samples(s, DisasterZoneBossLearnDB.pulls[...][1])
        return { st = st, cd = cd, chat = s.chat, mixed = s.mixed or false }
    """, LEO)
    assert r == {"st": [61.0], "cd": [105.5, 105.0], "chat": True, "mixed": False}, r
    # a 1.5.5 sender still times the demon bar's starts: its summary counts, those starts are not kept
    msg = c.eval_py("""
        local key = ...
        local ds = ns.BossLearn.Plan(ns.BossMod:Mod(key)).ds
        return { t = 'BL', v = 1, av = '1.5.5', b = key, ds = ds, at = GetServerTime() - 3000, l = 'Victhar-Thunderstrike',
                 d = 3633, k = 1, o = { innerbar = { 1184, 1002 } }, g = { demon = { 910, 1051 }, innerbar = { 910, 1051 } },
                 ph = { 2, 296 } }
    """, LEO)
    rec = c.eval_py("local r, why = ns.BossLearn:Validate(...); return r and { g = r.g } or { why = why }", c._to_lua(msg))
    assert rec.get("g") and "demon" not in rec["g"] and times(rec["g"]["innerbar"]) == [91.0, 196.1], rec
    w.assert_no_errors()


@case
def two_copies_of_one_pull_keep_the_better_one():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    r = c.eval_py("""
        local BL = ns.BossLearn
        local function rec(at, dur, from) return { id = 'GruulsLair:Gruul|L|' .. at, at = at, leader = 'L', dur = dur,
            kill = true, clean = true, ds = 'x', from = from, src = 1, o = { slam = { 35 } } } end
        local function add(...) BL:AddPull('GruulsLair:Gruul', rec(...)) end
        local function list()
            local o = {}
            for _, x in ipairs(DisasterZoneBossLearnDB.pulls['GruulsLair:Gruul'] or {}) do o[#o + 1] = x.from .. '@' .. x.at end
            return o
        end
        -- Morogrim, 16 Oct: my whole kill, then a guildmate's copy that started 42 s late (it came in mid-pull)
        add(10000, 386.9, 'me'); add(10042, 344.3, 'Tudis')
        -- the late copy stored first: the whole one takes its place
        add(20042, 344.3, 'me'); add(20000, 386.9, 'Victhar')
        -- Hydross, 16 Oct: a copy that missed the wipe's end and ran on into the next pull (same start, 22 minutes)
        add(30000, 260, 'me'); add(30002, 1327.5, 'Bob')
        -- the same overrun stored first (an older client's), then the next pull it swallowed: the real pull stays
        add(40000, 1328.4, 'Bob'); add(41026, 301.7, 'me')
        -- two pulls a few minutes apart are two pulls
        add(50000, 120, 'me'); add(50300, 120, 'me')
        return list()
    """)
    assert r == ["me@10000", "Victhar@20000", "me@30000", "me@41026", "me@50000", "me@50300"], r
    # the guild's late copy is dropped before it is stored, with a line in the log
    msg = c.eval_py("""
        local BL = ns.BossLearn
        local ds = BL.Plan(ns.BossMod:Mod('GruulsLair:Gruul')).ds
        local at = GetServerTime() - 1000
        BL:AddPull('GruulsLair:Gruul', { id = 'GruulsLair:Gruul|Kaelor-Thunderstrike|' .. at, at = at,
            leader = 'Kaelor-Thunderstrike', dur = 386.9, kill = true, clean = true, ds = ds, from = 'me', src = 1,
            o = { slam = { 38.7 } } })
        return { t = 'BL', v = 1, av = ns.version, b = 'GruulsLair:Gruul', ds = ds, at = at + 42,
                 l = 'Kaelor-Thunderstrike', d = 3443, k = 1, o = { slam = { 25 } } }
    """)
    ok = c.eval_py("return { ns.BossLearn:Accept('Tudis-Thunderstrike', ...) }", c._to_lua(msg))
    assert ok == [False, "late"], ok
    assert "came in mid-pull" in c.eval("return DisasterZoneBossLearnDB.log[#DisasterZoneBossLearnDB.log]")
    # stored before these rules: tidied after login
    t = c.eval_py("""
        local BL = ns.BossLearn
        local function rec(at, dur, from) return { id = 'X|L|' .. at, at = at, leader = 'L', dur = dur, clean = true,
            ds = 'x', from = from, src = 1, o = {} } end
        local P = DisasterZoneBossLearnDB.pulls
        P['SerpentshrineCavern:Morogrim'] = { rec(6443, 386.9, 'me'), rec(6485, 344.3, 'Tudis') }
        P['SerpentshrineCavern:Hydross'] = { rec(6245, 1327.5, 'me'), rec(7271, 301.7, 'me') }
        local n = BL:Tidy()
        local m, h = P['SerpentshrineCavern:Morogrim'], P['SerpentshrineCavern:Hydross']
        return { n = n, m = m[1].from .. '@' .. m[1].at .. '/' .. #m, h = h[1].at .. '/' .. #h }
    """)
    assert t == {"n": 2, "m": "me@6443/1", "h": "7271/1"}, t
    w.assert_no_errors()


@case
def a_fight_with_the_boss_already_hurt_is_not_recorded():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    boss = gruul(w, c)
    w.tick(3)
    c.target_npc(boss)
    w.set_npc_hp(boss, 80)
    f = Fight(w, [c], boss).start()
    assert c.eval("return ns.BossMod:Active().rec == nil") is True
    assert "before I came in" in c.eval("return DisasterZoneBossLearnDB.log[#DisasterZoneBossLearnDB.log]")
    f.to(30)
    f.end(1)
    w.tick(1)
    assert pulls(c) == []
    w.set_npc_hp(boss, 100)
    f.start()
    assert c.eval("return ns.BossMod:Active().rec ~= nil") is True
    f.end(0)
    w.assert_no_errors()


@case
def a_pull_that_outlives_a_wipe_while_released_is_not_clean():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    boss = gruul(w, c)
    w.enter_instance(name="Gruul's Lair", instance_id=565, max_players=25)
    w.tick(3)
    f = Fight(w, [c], boss).start()
    assert c.eval("return ns.BossMod:Active().rec ~= nil") is True
    f.to(35)
    f.log("SPELL_CAST_START", 33525, "Ground Slam")
    f.to(40)
    w.leave_instance()
    w.tick(6)
    assert c.eval("return ns.BossMod:Active()") is None
    w.tick(20)
    ps = pulls(c)
    assert len(ps) == 1 and ps[0]["clean"] is False and not ps[0].get("o"), ps
    assert summaries(w) == []
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# the developer's review and the screens
# ------------------------------------------------------------------------------------------------------------------
NAMES = ("local N = { [36240] = 'Cave In', [36241] = 'Cave In', [33525] = 'Ground Slam', [36300] = 'Growth', "
         "[33654] = 'Shatter', [33813] = 'Hurtful Strike', [36297] = 'Reverberation' }; local gsi = GetSpellInfo; "
         "GetSpellInfo = function(id, ...) if N[id] then return N[id], nil, 136243 end; return gsi(id, ...) end")


def seed_review(c):
    c.eval(NAMES)
    c.eval("""
        local BL = ns.BossLearn
        local ds = BL.Plan(ns.BossMod:Mod('GruulsLair:Gruul')).ds
        for i = 1, 3 do
            BL:AddPull('GruulsLair:Gruul', { id = 'g|' .. i, at = 1000 + i * 1000, leader = 'L', dur = 120, kill = true,
                clean = true, ds = ds, o = { slam = { 34 + i } }, nf = { 'cavein' },
                u = { { id = 36241, n = 4, t = 50, name = 'Cave In' }, { id = 33572, n = 30, t = 2, name = "Gronn Lord's Grasp" } },
                y = { { t = 1, n = 1, text = 'Come... and die.' } } })
        end
        BL:Relearn('GruulsLair:Gruul')
    """)


def page_texts(c):
    return c.eval_py("local o = {}; local p = ns.BossLearnUI:GetPage(); local function walk(f) for _, r in ipairs({ f:GetRegions() }) do "
                     "if r.GetText and r:IsVisible() and r:GetText() then o[#o + 1] = r:GetText() end end; "
                     "for _, k in ipairs({ f:GetChildren() }) do walk(k) end end; if p then walk(p) end; return o")


@case
def the_review_is_the_developers_only():
    for name in ("Alice", "Tsumil"):
        w, c = solo(name, class_file="PALADIN", guild_rank=0)
        c.eval("ns.DB:SetSetting('bossmods.on', true)")
        seed_review(c)
        dev = name == "Tsumil"
        assert c.eval("return ns.BossLearn:IsDev()") is dev
        sug = c.eval_py("return ns.BossLearn:Suggestions('GruulsLair:Gruul')")
        kinds = sorted(s["kind"] for s in (sug or []))
        assert kinds == (["cast", "spell", "yell"] if dev else []), sug
        assert (c.eval("return DisasterZoneBossLearnDB.review.suggest['GruulsLair:Gruul'] ~= nil") is True) is dev
        c.slash("/dz settings")
        w.tick(0.5)
        c.eval("ns.BossLearnUI:Open('GruulsLair:Gruul')")
        w.tick(0.3)
        t = page_texts(c)
        assert "Gruul the Dragonkiller" in t and "Ground Slam, first" in t and "Learned 35–37 s" in t, t
        has_fix = any("never fired" in x for x in t)
        assert has_fix is dev and (("Use 36241" in t) is dev), t
        assert ("Never fired" in t) is dev, t
        pill = c.eval_py("return { ns.BossLearnUI:BossPill('GruulsLair:Gruul') }")
        assert ("fix" in pill[1]) is dev, pill
        if dev:
            # Use: decided, saved, and the alert listens to 36241 on this client from now on
            c.eval("for _, n in ipairs(ns.BossLearnUI:GetPage().notices) do if n:IsShown() and n.use:IsShown() then n.use:Click() end end")
            w.tick(0.3)
            d = c.eval_py("return DisasterZoneBossLearnDB.review.decisions['GruulsLair:Gruul']['spell:cavein']")
            assert d["use"] == 36241 and d["from"] == 36240 and d["alert"] == "cavein", d
            assert c.eval("local l = ns.BossMod:Mod('GruulsLair:Gruul')._t.cleu.SPELL_AURA_APPLIED[36241]; "
                          "return l ~= nil and l[1].a.key == 'cavein'") is True
            assert not any(s["kind"] == "spell" for s in c.eval_py("return ns.BossLearn:Suggestions('GruulsLair:Gruul')"))
            # (Ignore takes the others away)
            for s in c.eval_py("return ns.BossLearn:Suggestions('GruulsLair:Gruul')"):
                assert c.eval("return ns.BossLearn:Decide('GruulsLair:Gruul', ..., 'ignore')", s["key"]) is True
            assert c.eval_py("return ns.BossLearn:Suggestions('GruulsLair:Gruul')") in ([], None, {})
        else:
            assert c.eval("return ns.BossLearn:Decide('GruulsLair:Gruul', 'spell:cavein', 'use')") is False
            assert c.eval("return ns.BossMod:Mod('GruulsLair:Gruul')._t.cleu.SPELL_AURA_APPLIED[36241] == nil") is True
        w.assert_no_errors()


@case
def settings_rows_pills_and_the_boss_page():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('bossmods.on', true)")
    c.eval(NAMES)
    c.slash("/dz settings")
    w.tick(0.5)
    c.eval("ns.SettingsUI:OpenBossMods('GruulsLair')")
    w.tick(0.5)
    texts = c.eval_py("local o = {}; local function walk(f) for _, r in ipairs({ f:GetRegions() }) do "
                      "if r.GetText and r:IsVisible() and r:GetText() then o[#o + 1] = r:GetText() end end; "
                      "for _, k in ipairs({ f:GetChildren() }) do walk(k) end end; walk(UIParent); return o")
    for t in ("Learn from our pulls", "Share what we learn",
              "Timers tighten after 3 clean pulls that agree. Nothing changes during a pull."):
        assert t in texts, t
    assert not any(x.startswith("Learning ·") or x.startswith("Learned ·") for x in texts), "a pill before any pull"
    # (both are essentials, not in More options; sharing is hidden while learning is off)
    rows = "local o = {}; for _, r in ipairs(ns.SettingsUI.sections.bossmods.rows) do o[r.title:GetText() or ''] = { " \
           "shown = r:IsShown(), more = r.more and true or false } end; return o"
    st = c.eval_py(rows)
    assert st["Learn from our pulls"] == {"shown": True, "more": False}, st.get("Learn from our pulls")
    assert st["Share what we learn"] == {"shown": True, "more": False}, st.get("Share what we learn")
    c.eval("for _, r in ipairs(ns.SettingsUI.sections.bossmods.rows) do "
           "if r.title:GetText() == 'Learn from our pulls' then r.control:Click() end end")
    w.tick(0.3)
    assert c.eval("return ns.DB:GetSetting('bossmods.learn')") is False
    assert c.eval_py(rows)["Share what we learn"]["shown"] is False
    c.eval("for _, r in ipairs(ns.SettingsUI.sections.bossmods.rows) do "
           "if r.title:GetText() == 'Learn from our pulls' then r.control:Click() end end")
    w.tick(0.3)
    assert c.eval_py(rows)["Share what we learn"]["shown"] is True
    # (the raid list moves with the More options fold: the heads keep their pills and their way in)
    c.eval("local sec = ns.SettingsUI.sections.bossmods; ns.SettingsUI:SetMoreOpen(sec, true)")
    w.tick(0.2)
    seed_pulls(c, 2)
    pill = c.eval_py("return { ns.BossLearnUI:BossPill('GruulsLair:Gruul') }")
    assert pill == ["mute", "Learning · 2 of 3"], pill
    seed_pulls(c, 1, slam=(36.8,), at0=c.eval("return GetServerTime()") - 50000)
    pill = c.eval_py("return { ns.BossLearnUI:BossPill('GruulsLair:Gruul') }")
    assert pill == ["ok", "Learned · 3 pulls"], pill
    # the list's head wears it; a click opens the page
    c.eval("ns.BossLearnUI:RefreshHeads()")
    shown = c.eval_py("local o = {}; local function walk(f) for _, k in ipairs({ f:GetChildren() }) do "
                      "if k.dzBoss and k:IsVisible() then o[#o + 1] = { k.dzBoss, k.dzPill:IsShown() and k.dzPill.fs:GetText() or '' } end; "
                      "walk(k) end end; walk(UIParent); return o")
    assert [KEY, "Learned · 3 pulls"] in shown, shown
    c.eval("local function find(f) for _, k in ipairs({ f:GetChildren() }) do "
           "if k.dzBoss == 'GruulsLair:Gruul' and k:IsVisible() then k.dzOpen:Click() return true end; "
           "if find(k) then return true end end end; find(UIParent)")
    w.tick(0.3)
    assert c.eval("return ns.BossLearnUI:IsOpen()") == KEY
    t = page_texts(c)
    for want in ("Gruul the Dragonkiller", "Learned · 3 pulls", "Ground Slam, first", "Learned 34–37 s",
                 "Growth, again", "Fixed · 10 s", "Hurtful Strike", "Learning · 0 of 3", "What we know"):
        assert want in t, (want, t)
    assert not any("never fired" in x.lower() for x in t), t
    # the back link (and another section) closes it
    c.eval("ns.BossLearnUI:GetPage().back:Click()")
    assert c.eval("return ns.BossLearnUI:IsOpen()") is None
    c.eval("ns.BossLearnUI:Open('GruulsLair:Gruul'); ns.SettingsUI:SelectSection('meters')")
    assert c.eval("return ns.BossLearnUI:IsOpen()") is None
    w.assert_no_errors()


@case
def try_it_shows_the_recording_line_and_a_made_up_note():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('bossmods.on', true)")
    c.eval("ns.BossModUI:TryIt()")
    w.tick(8)
    rl = c.eval_py("return ns.BossLearnUI:RecLine(ns.BossModUI.tryLearn)")
    assert rl["text"] == "Recording pull 7" and rl["sub"] == "learning waits for the end", rl
    w.tick(5)
    rl = c.eval_py("return ns.BossLearnUI:RecLine(ns.BossModUI.tryLearn)")
    assert rl["sub"] == "learning waits for the end", rl        # (the noted cast is the developer's)
    assert c.eval("return ns.BossModUI:IsAwake()") is True
    w.tick(10.2)
    t = c.eval_py("local t = ns.UI:GetToast('bosslearn:demo'); return t and { t.title:GetText(), t.text:GetText() }")
    assert t and t[0] == "Gruul · what we learned" and "Ground Slam, first" in t[1], t
    assert c.eval("return next(DisasterZoneBossLearnDB.pulls) == nil") is True
    assert summaries(w) == []
    assert c.eval("return ns.BossLearnUI:RecLine(ns.BossModUI.tryLearn) == nil") is True
    # (the developer also sees the made-up unknown cast once the pull is 10.5 s in)
    w2, d = solo("Tsumil", class_file="PALADIN", guild_rank=0)
    d.eval("ns.DB:SetSetting('bossmods.on', true); ns.BossModUI:TryIt()")
    w2.tick(5 + 11)
    rl = d.eval_py("return ns.BossLearnUI:RecLine(ns.BossModUI.tryLearn)")
    assert rl["noted"] is True and rl["sub"] == "1 cast we don't know, noted", rl
    w.assert_no_errors()
    w2.assert_no_errors()


@case
def a_real_pull_shows_its_recording_line_and_a_note_after():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    boss = gruul(w, c)
    c.eval(NAMES)
    # two earlier pulls with the first Ground Slam at 35 and 36: this one (35) makes three
    seed_pulls(c, 2, slam=(35.6, 36.1))
    kinds = c.eval_py("local o = {}; for _, k in ipairs(ns.Notify:GetKinds()) do o[#o + 1] = k.kind end; return o")
    assert "bossLearned" in kinds
    f = Fight(w, [c], boss).start()
    f.to(22)
    rl = c.eval_py("return ns.BossLearnUI:RecLine()")
    assert rl["text"] == "Recording pull 3" and rl["sub"] == "learning waits for the end", rl
    standard_pull(f)
    w.tick(16)
    items = c.eval_py("local o = {}; for _, it in ipairs(ns.Notify:List({ kind = 'bossLearned' })) do "
                      "o[#o + 1] = { it.title, it.text } end; return o")
    assert len(items) == 1 and items[0][0] == "Gruul the Dragonkiller · what we learned", items
    assert "Ground Slam, first: 35–36.5 s, was 33–40 s" in items[0][1], items[0][1]
    assert "Nothing changed during this one." in items[0][1]
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# the dev tool
# ------------------------------------------------------------------------------------------------------------------
@case
def the_dev_tool_reads_a_saved_variables_file():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    ds = c.eval("return ns.BossLearn.Plan(ns.BossMod:Mod('GruulsLair:Gruul')).ds")
    src = open(os.path.join(HERE, "fixture_sv.lua"), encoding="utf-8").read().replace("@GRUUL_DS@", ds)
    tmp = tempfile.mkdtemp(prefix="bosslearn_")
    path = os.path.join(tmp, "DisasterZone.lua")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)
    tool = os.path.join(DEV, "tools", "bossmods_learned.py")
    env = dict(os.environ, DISASTERZONE_ADDON_DIR=ADDON)
    r = subprocess.run([sys.executable, tool, path, "--no-names"], capture_output=True, text=True, encoding="utf-8",
                       cwd=DEV, env=env)
    out = r.stdout
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Gruul's Lair" in out and "GruulsLair:Gruul" in out and "4 pulls stored, 3 usable" in out, out
    assert "1 recorded against older data" in out, out
    slam = next(x for x in out.splitlines() if x.strip().startswith("slam") and " start " in x)
    assert "learned 34–37 s" in slam and "APPLIED" in slam and "3 pulls" in slam, slam
    rev = next(x for x in out.splitlines() if x.strip().startswith("reverb") and " start " in x)
    assert "far from the data" in rev and "NOT applied" in rev, rev
    sh = next(x for x in out.splitlines() if x.strip().startswith("shatter"))
    assert "fixed, measured 10–10.5 s" in sh, sh
    nf = next(x for x in out.splitlines() if "NEVER FIRED cavein" in x)
    assert "36240" in nf and "36241" in nf and "in 3 pulls" in nf, nf
    assert "unknown casts: 33572 Gronn Lord's Grasp (3 pulls, 116x)" in out, out
    assert "DECISION cast:33572: ignore" in out and '"Come... and die."' in out and "recording stopped" in out, out
    # --json, one boss
    r = subprocess.run([sys.executable, tool, path, "--json", "--no-names", "--boss", KEY], capture_output=True,
                       text=True, encoding="utf-8", cwd=DEV, env=env)
    assert r.returncode == 0, r.stderr
    j = json.loads(r.stdout)[path]["bosses"][KEY]
    assert j["usable"] == 3 and j["alerts"]["slam"]["fields"]["start"]["lo"] == 34, j["alerts"]["slam"]
    assert j["alerts"]["growth"]["fields"]["cd"]["applied"] is True
    assert j["alerts"]["slamwarn"]["learnable"] is False
    assert j["never_fired"]["cavein"]["pulls"] == 3
    # the tool's windows are the game's (the same rules, the same file)
    game = c.eval_py("""
        local src = ...
        local f, env = loadstring(src), {}
        setfenv(f, env); f()
        DisasterZoneBossLearnDB = env.DisasterZoneBossLearnDB
        return ns.BossLearn:Relearn('GruulsLair:Gruul').alerts.slam.start
    """, src)
    assert (game["lo"], game["hi"], game["state"]) == (34, 37, "ok"), game
    # no file with the table: exit 2
    empty = os.path.join(tmp, "Other.lua")
    open(empty, "w").write("Other = {}\n")
    r = subprocess.run([sys.executable, tool, empty], capture_output=True, text=True, cwd=DEV, env=env)
    assert r.returncode == 2, r.stdout
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
