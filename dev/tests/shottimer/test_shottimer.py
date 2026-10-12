#!/usr/bin/env python
"""Shot timer (Core/ShotTimer.lua, UI/ShotTimerHUD.lua): every Hunter gets the Auto Shot ring, WoWSims' Hunter
rotation is played from known states (Steady Shot when it fits before the next windup plus the buffer, Multi-Shot,
Arcane Shot, Kill Command off the GCD, aspect hints, clipping pushes the next shot), the HUD draws in every style,
haste is learned from a real Steady Shot cast, shots are classified into a fight report, and demo mode plays it on
any character."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from harness import World, Client  # noqa: E402

w = World()
hunt = Client(w, "Hana", class_file="HUNTER", guild_rank=0, talents=(41, 20, 0))
pala = Client(w, "Bob", class_file="PALADIN", guild_rank=1, talents=(0, 45, 16))
for c in w.clients:
    c.load_addon()
w.tick(2)

NAMES = ("local names = { [75] = 'Auto Shot', [34120] = 'Steady Shot', [27021] = 'Multi-Shot', [27019] = 'Arcane Shot', "
         "[34026] = 'Kill Command', [27044] = 'Aspect of the Hawk', [34074] = 'Aspect of the Viper' }; "
         "local old = GetSpellInfo; GetSpellInfo = function(x, ...) if names[x] then return names[x] end "
         "for _, n in pairs(names) do if n == x then return n end end return old(x, ...) end; "
         "for id, n in pairs(names) do __MOCK.known_spells[id] = true; __MOCK.spell_cd = __MOCK.spell_cd or {}; "
         "__MOCK.spell_cd[n] = { 0, 0 } end; __MOCK.fire('SPELLS_CHANGED')")
hunt.eval(NAMES)

assert hunt.eval("return ns.ShotTimer:IsMine(), ns.ShotTimer.active") == (True, True), "every Hunter spec has it"
assert pala.eval("return ns.ShotTimer.active") is False
assert pala.eval("return DisasterZoneShotTimer == nil") is True, "no shot timer for a Paladin"

# ---------------------------------------------------------------------------------------------------------------
# The rotation from known states: a 3.0 bow at 2.2 s (haste 1.364), 50 ms latency
# ---------------------------------------------------------------------------------------------------------------
RUN = """
    local ST = ns.ShotTimer
    local o = ...
    local speed = o.speed or 2.2
    local h = (o.base or 3.0) / speed
    local w = 0.5 / h
    local last = o.last or 10
    local snap = { now = 10, lastShot = last, speed = speed, cycle = speed, haste = h, windup = w,
      nextStart = o.next or (last - w + speed), buffer = math.min(0.5, 0.25 * speed),
      ct = { steady = 1.5 / h, multi = 0.5 / h }, lat = 0.05, gcdReady = o.gcd or 10, busyUntil = 10, gcd = 1.5,
      cd = { multi = 10, arcane = 6, kc = 5 }, ready = { multi = o.multiAt or 10, arcane = o.arcaneAt or 10 },
      kc = o.kc or false, mana = o.mana or 80, aspect = o.aspect or 'hawk',
      use = { steady = true, multi = o.multi or false, arcane = o.arcane or false, aspect = o.aspects or false,
              viperStart = 5, viperStop = 25 } }
    local steps, shots = ST.Run(snap)
    local out = {}
    for i, st in ipairs(steps) do
      out[i] = st.key .. '@' .. string.format('%.3f', st.at) .. (st.latest and ('<' .. string.format('%.3f', st.latest)) or '')
    end
    local sh = {}
    for i, t in ipairs(shots) do sh[i] = string.format('%.3f', t) end
    return table.concat(out, ' '), table.concat(sh, ' ')
"""
def run(**o):
    return hunt.eval("local t = {}; for k, v in pairs(...) do t[k] = v end; return (function(...) " + RUN + " end)(t)", o)

# a shot just left: Steady Shot now (it fits: 1.100 <= 11.833 - 10.05 + 0.5); after it nothing fits before the next
# shot (the GCD ends at 11.5), so Steady Shot again the moment that shot leaves (12.2): the 1:1 rotation
steps, shots = run()
seq = steps.split()
assert seq[0] == "steady@10.000<11.183", seq           # latest = 11.833 + 0.5 - 1.1 - 0.05
assert seq[1].startswith("steady@12.200"), seq
assert shots.split()[0] == "12.200", shots
# a 1.5 s swing (haste 2: Steady 0.75 s, windup 0.25 s): the GCD is the limit, Steady right after every shot
steps, shots = run(speed=1.5)
assert steps.split()[0].startswith("steady@10.000") and steps.split()[1].startswith("steady@11.500"), steps
assert shots.split()[0] == "11.500", shots
# late in the swing (shot left 1.3 s ago): Steady Shot no longer fits (0.983 left), Multi-Shot does
assert run(last=8.7, multi=True, arcane=True)[0].split()[0].startswith("multi@10.000"), run(last=8.7, multi=True)
# ... Multi-Shot off or cooling: Arcane Shot (instant)
assert run(last=8.7, arcane=True)[0].split()[0] == "arcane@10.000"
assert run(last=8.7, multi=True, multiAt=15, arcane=True)[0].split()[0] == "arcane@10.000"
# ... nothing on: wait for the shot, Steady after it (shot at 8.7 + 2.2 = 10.9)
assert run(last=8.7)[0].split()[0].startswith("steady@10.900"), run(last=8.7)
# clipping inside the buffer: Steady at 10 ends at 11.15 on the server, after the windup was due (10.833): the shot
# waits for the cast and leaves a windup later (11.517)
steps, shots = run(last=9.0)
assert steps.split()[0].startswith("steady@10.000"), steps
assert shots.split()[0] == "11.517", shots
# Kill Command (off the GCD) first, Steady Shot at the same moment
assert run(kc=True)[0].split()[0:2] == ["kc@10.000", "steady@10.000<11.183"], run(kc=True)
# aspects: Viper when dry, Hawk back once there is mana; off unless the hints are on
assert run(mana=3, aspects=True)[0].split()[0] == "viper@10.000"
assert run(mana=30, aspect="viper", aspects=True)[0].split()[0] == "hawk@10.000"
assert run(mana=3)[0].split()[0].startswith("steady@")
# the planner never stops early on a long horizon (no endless loop, ~2 swings ahead)
assert len(run(multi=True, arcane=True)[0].split()) >= 2

# ---------------------------------------------------------------------------------------------------------------
# Live state: shots, casts, haste
# ---------------------------------------------------------------------------------------------------------------
# a real Steady Shot cast of 1.10 s at a 2.2 s swing teaches the weapon's own speed (3.0) for that weapon
r = hunt.eval_py("""
    local ST = ns.ShotTimer
    GetInventoryItemID = function(unit, slot) if slot == 18 then return 28772 end end
    __MOCK.ranged_speed = 2.2
    local now = GetTime() * 1000
    __MOCK.casting = { 'Steady Shot', now, now + 1100, 'guid' }
    __MOCK.fire('UNIT_SPELLCAST_START', 'player', 'guid', 34120)
    local learned = ns.DB:GetSetting('shot.base')
    local h = ST:Haste()
    local pushed = ST.state.pushTo
    __MOCK.casting = nil
    __MOCK.fire('UNIT_SPELLCAST_STOP', 'player', 'guid', 34120)
    return { base = learned and learned[28772], haste = h, pushed = pushed > GetTime() + 1, after = ST.state.pushTo <= GetTime() }
""")
assert r["base"] == 3.0 and abs(r["haste"] - 3.0 / 2.2) < 0.001 and r["pushed"] and r["after"], r

# no aspect at all: Hawk is the first thing to press (WoWSims' "Hawk from 25% mana"); with Hawk up, the shots
assert hunt.eval("local ST = ns.ShotTimer; ST.state.aspect = nil; ST.state.auto = true; ST.OnShot(GetTime()); "
                 "return ST:Current().plan.steps[1].key") == "hawk"
# Auto Shot on: the ring has a plan; off: it rests
r = hunt.eval_py("""
    local ST = ns.ShotTimer
    ST.state.aspect = 'hawk'
    __MOCK.fire('START_AUTOREPEAT_SPELL')
    __MOCK.fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'g1', 75)
    local c = ST:Current()
    local first = c and c.plan.steps[1] and c.plan.steps[1].key
    __MOCK.fire('STOP_AUTOREPEAT_SPELL')
    local rest = ST:Current() == nil
    __MOCK.fire('START_AUTOREPEAT_SPELL')
    return { first = first, rest = rest }
""")
assert r["first"] == "steady" and r["rest"] is True, r

# the HUD runs through a whole shot in every style, out of combat (idle on)
hunt.eval("ns.DB:SetSetting('shot.idle', true)")
for style in ("bar", "lane", "both"):
    hunt.eval("ns.DB:SetSetting('shot.style', ...)", style)
    hunt.eval("""
        local ST = ns.ShotTimer
        ST.OnShot(GetTime())
        for i = 1, 20 do ns.ShotTimerHUD:Update() end
    """)
    w.tick(1)
    w.tick(1.5)
assert hunt.eval("return DisasterZoneShotTimer:IsShown()") is True
# the ring's window is the Steady Shot press, hot (the next press) right after a shot
r = hunt.eval_py("""
    local ST = ns.ShotTimer
    ST.OnShot(GetTime())
    local cur = ST:Current()
    local D = ns.ShotTimerHUD.ring.D
    local f = D:Face(cur, GetTime())
    return { hot = f.hot, z0 = f.z0 ~= nil, before = f.z1 < f.red0, red = f.red0 < f.to, from = f.from == ST.state.last }
""")
assert r == {"hot": True, "z0": True, "before": True, "red": True, "from": True}, r

# a fight: on time, a clipped shot (0.4 s late), one held by moving -> the report
r = hunt.eval_py("""
    local ST = ns.ShotTimer
    __MOCK.ranged_speed = 2.2
    ST.StartFight()
    local t = 100
    ST.state.last, ST.state.cycle = nil, nil
    ST.OnShot(t)
    for _, gap in ipairs({ 2.2, 2.25, 2.6, 2.2 }) do t = t + gap; ST.OnShot(t) end
    ST.state.moving, ST.state.movedSince = true, true
    t = t + 3.1; ST.OnShot(t)
    ST.state.moving = false
    t = t + 2.2; ST.OnShot(t)
    ST.EndFight()
    local rep = ST:Reports()[1]
    return { clean = rep.counts.clean, clip = rep.counts.clip, moved = rep.counts.moved, lost = rep.lost }
""")
assert r == {"clean": 4, "clip": 1, "moved": 1, "lost": 0.4}, r

# Settings > Class tools: the Hunter's card, closed at first; its switch is shot.enabled
hunt.slash("/dz settings")
w.tick(0.5)
assert hunt.eval("return ns.SettingsUI:KitShown('shot')") is True
CARD = ("for _, c in ipairs(ns.SettingsUI.sections.classtools.cards) do if c.kit.key == 'shot' then "
        "return c.body:IsShown(), c.head.sub:GetText() end end")
assert hunt.eval(CARD)[0] is False and "not your spec" not in hunt.eval(CARD)[1]
hunt.eval(CARD.replace("return c.body:IsShown(), c.head.sub:GetText()", "c.head.switch:Click()"))
assert hunt.eval("return ns.DB:GetSetting('shot.enabled'), ns.ShotTimer.active") == (False, False)
assert hunt.eval("return DisasterZoneShotTimer:IsShown()") is False
hunt.eval(CARD.replace("return c.body:IsShown(), c.head.sub:GetText()", "c.head.switch:Click()"))
assert hunt.eval("return ns.ShotTimer.active") is True
hunt.eval("ns.SettingsUI:SelectSection('shot')")
assert hunt.eval(CARD)[0] is True, "opening a card by its key opens it"

# /dz shot prints the haste and the latency
hunt.slash("/dz shot")
hunt.slash("/dz shot report")

# ---------------------------------------------------------------------------------------------------------------
# Demo mode on a Paladin: the shot timer shows beside the swing timer and plays the rotation by itself
# ---------------------------------------------------------------------------------------------------------------
pala.slash("/dz demo on")
w.tick(0.5)
assert pala.eval("return ns.ShotTimer.active, ns.SwingTimer.active") == (True, True)
w.tick(6)
r = pala.eval_py("""
    local ST = ns.ShotTimer
    local cur = ST:Current()
    local _, _, _, x = DisasterZoneShotTimer:GetPoint()
    return { shot = ST.state.last ~= nil, plan = cur ~= nil and #cur.plan.steps > 0,
             shown = DisasterZoneShotTimer:IsShown(), x = x }
""")
assert r["shot"] and r["plan"] and r["shown"] and r["x"] == 280, r
pala.slash("/dz demo off")
w.tick(0.5)
assert pala.eval("return ns.ShotTimer.active, ns.ShotTimer.state.last == nil") == (False, True)

w.assert_no_errors()
print(w.report())
print("ok")
