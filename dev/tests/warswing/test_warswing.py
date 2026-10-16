#!/usr/bin/env python
"""Warrior swing timer (Core/WarriorSwing.lua, UI/WarriorSwingHUD.lua): Arms and Fury warriors get the ring with the
off-hand cycle, rage and the Heroic Strike lamp; WoWSims' warrior rotations are played from known states (Fury:
Bloodthirst, Whirlwind only with Bloodthirst 1.5 s away, Execute; Arms: Slam right after the swing, Mortal Strike),
presses wait for rage, the lamp follows the Heroic Strike line, only known / stance-legal presses are suggested, the
combat log drives both hands (extra attacks and Heroic Strike handled), the HUD draws in every theme with and
without an off hand, and demo mode plays it on any character."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from harness import World, Client  # noqa: E402

w = World()
war = Client(w, "Garrosh", class_file="WARRIOR", guild_rank=0, talents=(17, 44, 0))
pala = Client(w, "Bob", class_file="PALADIN", guild_rank=1, talents=(0, 45, 16))
for c in w.clients:
    c.load_addon()
w.tick(2)
# class tools start off: switching one on is the player's choice
assert war.eval("return ns.WarriorSwing.active, ns.ClassKit:IsOn('war')") == (False, False)
for c in w.clients:
    c.eval("ns.ClassKit:SetOn('war', true)")
w.tick(0.3)

NAMES = ("local names = { [29707] = 'Heroic Strike', [25231] = 'Cleave', [30335] = 'Bloodthirst', [1680] = 'Whirlwind', "
         "[25236] = 'Execute', [30033] = 'Rampage', [2048] = 'Battle Shout', [2687] = 'Bloodrage', [25212] = 'Hamstring' }; "
         "local old = GetSpellInfo; GetSpellInfo = function(x, ...) if names[x] then return names[x] end "
         "for _, n in pairs(names) do if n == x then return n end end return old(x, ...) end; "
         "for id, n in pairs(names) do __MOCK.known_spells[id] = true; __MOCK.spell_cd = __MOCK.spell_cd or {}; "
         "__MOCK.spell_cd[n] = { 0, 0 } end; __MOCK.fire('SPELLS_CHANGED'); "
         "UnitAttackSpeed = function() return 2.6, 2.6 end; GetShapeshiftForm = function() return 3 end; "
         "__MOCK.fire('UNIT_ATTACK_SPEED', 'player')")
war.eval(NAMES)

assert war.eval("return ns.WarriorSwing:IsMine(), ns.WarriorSwing.active, ns.WarriorSwing:Spec()") == (True, True, "fury")
assert pala.eval("return ns.WarriorSwing.active") is False
assert pala.eval("return DisasterZoneWarriorSwing == nil") is True, "no warrior timer for a Paladin"

# ---------------------------------------------------------------------------------------------------------------
# The rotation from known states (now = 10, 2.6 / 2.6 swings, 50 ms latency)
# ---------------------------------------------------------------------------------------------------------------
RUN = """
    local W = ns.WarriorSwing
    local o = ...
    local use = { bt = true, ww = true, exe = true, shout = true, rampage = false, brage = false, ham = false, hs = true,
                  ms = false, slam = false }
    for k, v in pairs(o.use or {}) do use[k] = v end
    local two = o.two or false
    local snap = { now = 10, spec = o.spec or 'fury', twoHand = two, rage = o.rage or 60, stance = 3,
      line = W:Line(o.spec or 'fury', two),
      mhNext = o.mh or 11.0, mhSpeed = o.mhs or 2.6, ohNext = (not two) and (o.oh or 10.5) or nil,
      ohSpeed = (not two) and 2.6 or nil, lat = 0.05, gcdReady = o.gcd or 10, gcd = 1.5,
      ready = { bt = o.bt or 10, ms = o.ms or 10, ww = o.ww or 10, brage = 10 }, use = use, exec = o.exec or false,
      queued = o.queued, shoutLeft = o.shout or 100, rampageLeft = 30, rampageUsable = false, slamCast = 0.5,
      gainMH = 14, gainOH = (not two) and 7 or 0 }
    local steps, lamp = W.Run(snap)
    local out = {}
    for i, st in ipairs(steps) do out[i] = st.key .. '@' .. string.format('%.2f', st.at) end
    return table.concat(out, ' '), lamp or 'none'
"""
def run(**o):
    return war.eval("local t = {}; for k, v in pairs(...) do t[k] = v end; return (function(...) " + RUN + " end)(t)", o)

def first(**o):
    return run(**o)[0].split()[0]

# Fury: Bloodthirst first; Whirlwind while Bloodthirst cools; not when Bloodthirst is back within 1.5 s
assert first() == "bt@10.00", run()
assert first(bt=14) == "ww@10.00", run(bt=14)
assert first(bt=11) == "bt@11.00", run(bt=11)
seq = run()[0].split()
assert seq[0] == "bt@10.00" and seq[1] == "ww@11.50", seq       # Whirlwind after the GCD (Bloodthirst back at 16)
# Execute under 20% after Bloodthirst / Whirlwind, before nothing
assert first(bt=14, ww=14, exec=True) == "exe@10.00", run(bt=14, ww=14, exec=True)
# Battle Shout with 10 s or less left, when nothing better is up
assert first(bt=14, ww=14, shout=8) == "shout@10.00"
assert first(bt=14, ww=14, shout=30) != "shout@10.00"
# not enough rage: Bloodthirst waits for the swings that bring it (10 rage + the off hand at 10.5 -> 17 + the main
# hand at 11.0 -> 31)
assert first(rage=10) == "bt@11.01", run(rage=10)
assert first(rage=10, oh=12.0) == "bt@12.01", run(rage=10, oh=12.0)
# Whirlwind only in Berserker stance and only if known: off -> nothing but Bloodthirst
assert run(bt=14, use={"ww": False})[0].split()[0] == "bt@14.00"

# the Heroic Strike lamp: over the line queue, under it hold, queued stays queued; Execute phase holds
assert run(rage=62)[1] == "queue"
assert run(rage=24)[1] == "hold"
assert run(rage=24, queued="hs")[1] == "queued"
assert run(rage=80, exec=True)[1] == "hold"
assert run(rage=80, use={"hs": False})[1] == "none"

# Arms, two-hander (3.6 s): Slam right after the swing; mid-swing Mortal Strike, Slam after the next swing
assert war.eval("return ns.WarriorSwing:Line('arms', true), ns.WarriorSwing:Line('arms', false), "
                "ns.WarriorSwing:Line('fury', false)") == (80, 40, 40)
arms = dict(spec="arms", two=True, mhs=3.6, use={"bt": False, "ms": True, "slam": True})
assert first(mh=13.55, **arms) == "slam@10.00", run(mh=13.55, **arms)       # the swing landed 0.05 s ago
seq = run(mh=12.0, ww=20, **arms)[0].split()                               # 1.6 s into the swing
assert seq[0] == "ms@10.00" and seq[1] == "slam@12.00", seq
# ... WoWSims' list is greedy: a Whirlwind ready at 11.5 goes first, and the GCD runs through that Slam window
assert run(mh=12.0, **arms)[0].split() == ["ms@10.00", "ww@11.50", "slam@15.60"], run(mh=12.0, **arms)
assert run(rage=70, **arms)[1] == "hold" and run(rage=85, **arms)[1] == "queue", "two-handed Arms: line at 80"
# the setting moves the line
war.eval("ns.DB:SetSetting('war.hsLine', 55)")
assert run(rage=50)[1] == "hold" and run(rage=56)[1] == "queue"
war.eval("ns.DB:SetSetting('war.hsLine', 0)")

# ---------------------------------------------------------------------------------------------------------------
# Live state: the combat log drives both hands
# ---------------------------------------------------------------------------------------------------------------
GUID = war.eval("return UnitGUID('player')")
r = war.eval_py("""
    local W = ns.WarriorSwing
    local guid = UnitGUID('player')
    local now = GetTime()
    W.state.mhLast, W.state.ohLast, W.state.hsAt = nil, nil, nil
    -- a main-hand hit, an off-hand hit, an off-hand miss
    W.OnCombatLog(nil, now, 'SWING_DAMAGE', false, guid, 'x', 0, 0, 'b', 'Boss', 0, 0, 500, 0, 1, 0, 0, 0, nil, nil, nil, false)
    local mh = W.state.mhLast
    W.OnCombatLog(nil, now, 'SWING_DAMAGE', false, guid, 'x', 0, 0, 'b', 'Boss', 0, 0, 300, 0, 1, 0, 0, 0, nil, nil, nil, true)
    local oh = W.state.ohLast
    W.OnCombatLog(nil, now, 'SWING_MISSED', false, guid, 'x', 0, 0, 'b', 'Boss', 0, 0, 'MISS', true)
    -- an extra attack (Sword Specialization) does not restart the main hand
    W.state.mhLast = now - 1
    W.OnCombatLog(nil, now, 'SPELL_EXTRA_ATTACKS', false, guid, 'x', 0, 0, 'b', 'Boss', 0, 0, 12815, 'Sword Specialization', 1, 1)
    W.OnCombatLog(nil, now, 'SWING_DAMAGE', false, guid, 'x', 0, 0, 'b', 'Boss', 0, 0, 500, 0, 1, 0, 0, 0, nil, nil, nil, false)
    local extra = W.state.mhLast == now - 1 and W.state.extraAt == GetTime()
    -- a Heroic Strike landing is the main hand's swing
    W.OnCombatLog(nil, now + 0.1, 'SPELL_DAMAGE', false, guid, 'x', 0, 0, 'b', 'Boss', 0, 0, 29707, 'Heroic Strike', 1, 900)
    local hs = W.state.hsAt ~= nil and W.state.mhLast == W.state.hsAt
    -- someone else's swing changes nothing
    local before = W.state.mhLast
    W.OnCombatLog(nil, now, 'SWING_DAMAGE', false, 'Player-1-other', 'x', 0, 0, 'b', 'Boss', 0, 0, 500, 0, 1, 0, 0, 0, nil, nil, nil, false)
    return { mh = mh ~= nil, oh = oh ~= nil, extra = extra, hs = hs, other = W.state.mhLast == before }
""")
assert r == {"mh": True, "oh": True, "extra": True, "hs": True, "other": True}, r

# swinging: the HUD has a plan and a lamp; Heroic Strike queued shows "queued"
r = war.eval_py("""
    local W = ns.WarriorSwing
    W.OnMH(GetTime()); W.OnOH(GetTime() - 1.0)
    __MOCK.player_power = { 62, 100 }
    W:MarkDirty()
    local c = W:Current()
    IsCurrentSpell = function(n) return n == 'Heroic Strike' end
    W:MarkDirty()
    local q = W:Current().lamp
    IsCurrentSpell = nil
    W:MarkDirty()
    return { first = c.plan.steps[1].key .. (c.plan.steps[1].off and '(off)' or ''), second = c.plan.steps[2].key,
             lamp = c.lamp, queued = q, oh = c.snap.ohSpeed ~= nil }
""")
# (Bloodrage off the GCD under 90 rage, then Bloodthirst)
assert r == {"first": "brage(off)", "second": "bt", "lamp": "queue", "queued": "queued", "oh": True}, r

# the HUD runs in every theme and style (idle on), both hands and with a two-hander
war.eval("ns.DB:SetSetting('war.idle', true)")
for theme in ("halo", "sigil", "slate", "gilded", "pips", "classic"):
    war.eval("ns.DB:SetSetting('war.theme', ...)", theme)
    for style in ("bar", "both"):
        war.eval("ns.DB:SetSetting('war.style', ...)", style)
        war.eval("local W = ns.WarriorSwing; W.OnMH(GetTime()); W.OnOH(GetTime() - 1); "
                 "for i = 1, 10 do ns.WarriorSwingHUD:Update() end")
        w.tick(1)
    r = war.eval_py("""
        local f = DisasterZoneWarriorSwing
        local x = f.face.extra
        local shown = 0
        for _, d in ipairs(x.oh) do if d:IsShown() then shown = shown + 1 end end
        return { key = f.themeKey, frame = f:IsShown(), oh = shown, lamp = x.lamp:IsShown(),
                 rage = (x.globe or x.bar or x.pips) ~= nil }
    """)
    assert r["key"] == theme and r["frame"] and r["oh"] > 0 and r["lamp"] and r["rage"], (theme, r)
    # a two-hander: no off-hand cycle (the globe grows where there is one)
    r = war.eval_py("""
        UnitAttackSpeed = function() return 3.6, nil end
        __MOCK.fire('UNIT_ATTACK_SPEED', 'player')
        local W = ns.WarriorSwing
        W.OnMH(GetTime()); ns.WarriorSwingHUD:Update()
        local x = DisasterZoneWarriorSwing.face.extra
        local shown = 0
        for _, d in ipairs(x.oh) do if d:IsShown() then shown = shown + 1 end end
        local D = x.D
        UnitAttackSpeed = function() return 2.6, 2.6 end
        __MOCK.fire('UNIT_ATTACK_SPEED', 'player')
        W.OnOH(GetTime()); ns.WarriorSwingHUD:Update()
        return { oh = shown, grew = D == nil or D > x.D }
    """)
    assert r == {"oh": 0, "grew": True}, (theme, r)
assert war.eval("return DisasterZoneWarriorSwing:IsShown()") is True

# the rage moves: a jump from 20 to 80 rage eases in (not there on the next frame, there after a second), the globe's
# bubbles rise while it moves; war.motion off draws the level still (no bubbles, no easing)
war.eval("ns.DB:SetSetting('war.theme', 'halo')")
r = war.eval_py("""
    local W = ns.WarriorSwing
    W.OnMH(GetTime()); W.OnOH(GetTime() - 1)
    __MOCK.player_power = { 20, 100 }
    W:MarkDirty(); ns.WarriorSwingHUD:Update()
    __MOCK.player_power = { 80, 100 }
    W:MarkDirty(); ns.WarriorSwingHUD:Update()
    local x = DisasterZoneWarriorSwing.face.extra
    return { lv = x.lv }
""")
assert 0.19 <= r["lv"] < 0.5, r
w.tick(0.1)
w.tick(1.0)
r = war.eval_py("""
    local W = ns.WarriorSwing
    W.OnMH(GetTime()); W:MarkDirty(); ns.WarriorSwingHUD:Update()
    local x = DisasterZoneWarriorSwing.face.extra
    local bubbles = 0
    for _, b in ipairs(x.globe.bubbles) do if b:IsShown() then bubbles = bubbles + 1 end end
    ns.DB:SetSetting('war.motion', false)
    __MOCK.player_power = { 30, 100 }
    W:MarkDirty(); ns.WarriorSwingHUD:Update()
    local still = 0
    for _, b in ipairs(x.globe.bubbles) do if b:IsShown() then still = still + 1 end end
    local lvStill = x.lv
    ns.DB:SetSetting('war.motion', true)
    return { lv = x.lv, bubbles = bubbles, still = still, lvStill = lvStill }
""")
assert r["bubbles"] == 4 and r["still"] == 0 and abs(r["lvStill"] - 0.3) < 0.001, r

# resting: the ring empty, no lamp
r = war.eval_py("""
    local W = ns.WarriorSwing
    W.state.mhLast, W.state.ohLast = GetTime() - 30, GetTime() - 30
    ns.WarriorSwingHUD:Update()
    return { cur = W:Current() == nil, lamp = DisasterZoneWarriorSwing.face.extra.lamp:IsShown() }
""")
assert r == {"cur": True, "lamp": False}, r

# a fight report
r = war.eval_py("""
    local W = ns.WarriorSwing
    W.StartFight()
    for i = 1, 5 do W.OnMH(100 + i * 2.6, i % 2 == 0) end
    W.EndFight()
    local rep = W:Reports()[1]
    return { mh = rep.mh, hs = rep.hs }
""")
assert r == {"mh": 5, "hs": 2}, r

# Settings > Class tools: the warrior's card; its switch is war.enabled
war.slash("/dz settings")
w.tick(0.5)
assert war.eval("return ns.SettingsUI:KitShown('war')") is True
CARD = ("for _, c in ipairs(ns.SettingsUI.sections.classtools.cards) do if c.kit.key == 'war' then "
        "return c.body:IsShown() end end")
war.eval(CARD.replace("return c.body:IsShown()", "c.head.switch:Click()"))
assert war.eval("return ns.DB:GetSetting('war.enabled'), ns.WarriorSwing.active") == (False, False)
assert war.eval("return DisasterZoneWarriorSwing:IsShown()") is False
war.eval(CARD.replace("return c.body:IsShown()", "c.head.switch:Click()"))
assert war.eval("return ns.WarriorSwing.active") is True
war.eval("ns.SettingsUI:SelectSection('war')")
assert war.eval(CARD) is True, "opening a card by its key opens it"
war.slash("/dz war")
war.slash("/dz war report")

# a Protection warrior does not get it
prot = Client(w, "Tank", class_file="WARRIOR", guild_rank=1, talents=(5, 10, 46))
prot.load_addon()
w.tick(1)
prot.eval("ns.ClassKit:SetOn('war', true)")      # (on, and still not for a Protection warrior)
w.tick(0.3)
assert prot.eval("return ns.WarriorSwing.active") is False

# ---------------------------------------------------------------------------------------------------------------
# Demo mode on a Paladin: the warrior ring plays by itself, left of the others
# ---------------------------------------------------------------------------------------------------------------
pala.slash("/dz demo on")
w.tick(0.5)
assert pala.eval("return ns.WarriorSwing.active") is True
w.tick(8)
r = pala.eval_py("""
    local W = ns.WarriorSwing
    local cur = W:Current()
    local _, _, _, x = DisasterZoneWarriorSwing:GetPoint()
    local d = W.DemoState()
    return { swings = W.state.mhLast ~= nil and W.state.ohLast ~= nil, plan = cur ~= nil and #cur.plan.steps > 0,
             shown = DisasterZoneWarriorSwing:IsShown(), x = x, rage = d.rage >= 0 and d.rage <= 100,
             pressed = (d.ready.bt or 0) > 0 }
""")
assert r["swings"] and r["plan"] and r["shown"] and r["rage"] and r["x"] == -300, r
assert r["pressed"], "the demo bot presses Bloodthirst"
pala.slash("/dz demo off")
w.tick(0.5)
assert pala.eval("return ns.WarriorSwing.active, ns.WarriorSwing.state.mhLast == nil") == (False, True)

w.assert_no_errors()
print(w.report())
print("ok")
