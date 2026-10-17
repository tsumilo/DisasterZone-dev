#!/usr/bin/env python
"""Situations for the class tools' rotations (Core/Situation.lua, feedback #30; mockup v3 approved 2026-10-17):
the Warrior, Ret and Hunter timers know one target, a pack and a player. Detection (nameplates in combat within
reach + our multi-target hits, union by GUID, in after inDelay / out after outDelay), crowd control in reach holding
the presses that hit more than the target, an enemy player target at once, bosses left to the key, the switch key
(Automatic -> One target -> Pack -> Player, held until the fight ends), each tool's rotation per situation (warrior:
WoWSims' multi-target branch, Hamstring / Overpower against players, stance dancing within the rage a swap keeps;
Ret: Seal of Command's Judgement on a stunned target; Hunter: Volley / trap in a pack, Concussive / Aimed / sting /
Wing Clip against a player), the chip on the ring, the Settings rows and the Demo page's two moments."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from harness import World, Client  # noqa: E402

w = World()
war = Client(w, "Garrosh", class_file="WARRIOR", guild_rank=0, talents=(44, 17, 0))
pala = Client(w, "Bob", class_file="PALADIN", guild_rank=1, talents=(0, 16, 45))
hunt = Client(w, "Rexx", class_file="HUNTER", guild_rank=1, talents=(20, 41, 0))
for c in w.clients:
    c.load_addon()
w.tick(2)
for c, key in ((war, "war"), (pala, "swing"), (hunt, "shot")):
    c.eval("ns.ClassKit:SetOn('%s', true)" % key)
w.tick(0.3)

# ---------------------------------------------------------------------------------------------------------------
# The tools and their kinds
# ---------------------------------------------------------------------------------------------------------------
KINDS = "local t = ns.Situation:Kinds(...); return table.concat(t, ',')"
assert war.eval(KINDS, "war") == "single,pack,player"
assert war.eval(KINDS, "swing") == "single,player", "no pack for Ret"
assert war.eval(KINDS, "shot") == "single,pack,player"
assert war.eval("return ns.Situation:Tool('war').packFrom, ns.Situation:Tool('shot').packFrom, "
                "ns.Situation:Tool('shot').reach") == (2, 3, "28")
assert war.eval("return ns.Situation:Info('war').kind") == "single"
assert war.eval("return type(DisasterZone_SituationNext), BINDING_NAME_DISASTERZONE_SITUATION ~= nil") == ("function", True)

INFO = """
    local S = ns.Situation
    S:Dirty()
    local i = S:Info(...)
    return i.kind, i.n, i.held and i.held.key or 'none', i.cls or 'none', i.locked and true or false
"""
def info(c, prefix="war"):
    return c.eval(INFO, prefix)


def settle(c, secs, prefix="war"):
    """Time passes with the timer looking every 0.25 s, as the HUD does every frame."""
    t = 0.0
    while t < secs - 1e-9:
        info(c, prefix)
        w.tick(0.25)
        t += 0.25
    return info(c, prefix)

# ---------------------------------------------------------------------------------------------------------------
# A pack: plates in combat within reach, in after 1 s, out after 3 s
# ---------------------------------------------------------------------------------------------------------------
mobs = [w.spawn_npc(18831 + i, "Ogre %d" % i) for i in range(4)]
for g in mobs:
    war.show_nameplate(g)
war.eval("__MOCK.npc_combat = {}")
assert info(war)[:2] == ("single", 0), "plates out of combat do not count"
war.eval("for _, g in ipairs(...) do __MOCK.npc_combat[g] = true end", mobs[:3])
assert info(war)[:2] == ("single", 3), "three fighting: counted, not yet a pack (1 s first)"
settle(war, 0.6)
assert info(war)[0] == "single"
settle(war, 0.6)
assert info(war)[:2] == ("pack", 3), info(war)
# below 2 for less than 3 s: still a pack; then one target
war.eval("__MOCK.npc_combat[select(1, ...)] = nil; __MOCK.npc_combat[select(2, ...)] = nil", mobs[0], mobs[1])
assert info(war)[:2] == ("pack", 1)
settle(war, 2.0)
assert info(war)[0] == "pack"
settle(war, 1.2)
assert info(war)[:2] == ("single", 1), info(war)
# the setting moves the threshold: a pack from 4 ignores three
war.eval("for _, g in ipairs(...) do __MOCK.npc_combat[g] = true end", mobs[:3])
war.eval("ns.DB:SetSetting('war.sit.packFrom', 4)")
settle(war, 1.5)
assert info(war)[:2] == ("single", 3)
war.eval("ns.DB:SetSetting('war.sit.packFrom', nil)")
settle(war, 1.5)
assert info(war)[0] == "pack"
# out of reach (CheckInteractDistance) does not count
war.eval("_G.__oldCID = CheckInteractDistance; CheckInteractDistance = function() return false end")
settle(war, 3.5)
assert info(war)[:2] == ("single", 0), "out of reach: nobody counts"
war.eval("CheckInteractDistance = _G.__oldCID")
settle(war, 1.5)
assert info(war)[0] == "pack"

# count "hits": only what our multi-target attacks hit in the last 3 s (Whirlwind here)
war.eval("ns.DB:SetSetting('war.sit.count', 'hits')")
settle(war, 3.5)
assert info(war)[:2] == ("single", 0)
HIT = ("local me = UnitGUID('player'); local ww = GetSpellInfo(1680); "
       "for _, g in ipairs(...) do ns.Situation.OnCombatLog(nil, 0, 'SPELL_DAMAGE', false, me, 'me', 0, 0, g, 'x', 0, 0, 1680, ww) end")
war.eval(HIT, mobs[:2])
settle(war, 1.1)
assert info(war)[:2] == ("pack", 2), info(war)
# a hit by someone else, or by a one-target attack, does not count
war.eval("local ms = GetSpellInfo(30330); ns.Situation.OnCombatLog(nil, 0, 'SPELL_DAMAGE', false, UnitGUID('player'), 'me', "
         "0, 0, select(1, ...), 'x', 0, 0, 30330, ms)", mobs[3])
assert info(war)[1] == 2
settle(war, 3.2)
assert info(war)[1] == 0, "hits expire after 3 s"
war.eval("ns.DB:SetSetting('war.sit.count', nil)")

# ---------------------------------------------------------------------------------------------------------------
# Crowd control in reach holds the presses that hit more than the target
# ---------------------------------------------------------------------------------------------------------------
settle(war, 4)
assert info(war)[0] == "pack"
CC = ("local guid = ...; local poly = GetSpellInfo(118); _G.__oldUD = _G.__oldUD or UnitDebuff; "
      "UnitDebuff = function(u, i) if i == 1 and UnitGUID(u) == guid then return poly, 136071 end return nil end")
war.eval(CC, mobs[3])          # (the fourth, out of combat: a sheep)
k, n, held, _, _ = info(war)
assert (k, held) == ("pack", "poly") and n == 3, (k, n, held)
war.eval("ns.DB:SetSetting('war.sit.cc.poly', false)")
assert info(war)[2] == "none", "a crowd control switched off in Settings is not guarded"
war.eval("ns.DB:SetSetting('war.sit.cc.poly', nil)")
assert info(war)[2] == "poly"

# ---------------------------------------------------------------------------------------------------------------
# The warrior's snapshot follows: Cleave lamp in a pack, nothing that hits more than the target while held
# ---------------------------------------------------------------------------------------------------------------
NAMES = ("local names = { [29707] = 'Heroic Strike', [25231] = 'Cleave', [30335] = 'Bloodthirst', [1680] = 'Whirlwind', "
         "[25236] = 'Execute', [2048] = 'Battle Shout', [2687] = 'Bloodrage', [25212] = 'Hamstring', "
         "[30330] = 'Mortal Strike', [25242] = 'Slam', [12328] = 'Sweeping Strikes', [11585] = 'Overpower' }; "
         "for id in pairs(names) do __MOCK.known_spells[id] = true end; __MOCK.fire('SPELLS_CHANGED'); "
         "UnitAttackSpeed = function() return 3.6, nil end; GetShapeshiftForm = function() return 3 end")
war.eval(NAMES)
SNAP = """
    ns.Situation:Dirty()
    local s = ns.WarriorSwing:Snapshot(GetTime())
    return s.kind, s.lampKey, s.line, s.use.ww, s.use.sweep, s.use.cleave, s.held
"""
assert war.eval(SNAP) == ("pack", "hs", 80, False, False, False, True), war.eval(SNAP)
war.eval("UnitDebuff = _G.__oldUD")
assert war.eval(SNAP) == ("pack", "cleave", 40, True, True, True, False), war.eval(SNAP)
war.eval("ns.DB:SetSetting('war.cleaveLine', 55); ns.DB:SetSetting('war.pack.sweep', false)")
assert war.eval(SNAP)[2:5] == (55, True, False)
war.eval("ns.DB:SetSetting('war.cleaveLine', nil); ns.DB:SetSetting('war.pack.sweep', nil)")

# ---------------------------------------------------------------------------------------------------------------
# A player target: at once; bosses can be left to the key; mode Off / My key only
# ---------------------------------------------------------------------------------------------------------------
PVP = ("local on = ...; _G.__pvp = on; _G.__oIP = _G.__oIP or UnitIsPlayer; _G.__oCA = _G.__oCA or UnitCanAttack; "
       "_G.__oUC = _G.__oUC or UnitClass; "
       "UnitIsPlayer = function(u) if u == 'target' and __pvp then return true end return __oIP(u) end; "
       "UnitCanAttack = function(a, b) if b == 'target' and __pvp then return true end return __oCA(a, b) end; "
       "UnitClass = function(u) if u == 'target' and __pvp then return 'Priest', 'PRIEST' end return __oUC(u) end")
for c in (war, pala, hunt):
    c.eval("__MOCK.set_npc_target(...)", mobs[0])
    c.eval(PVP, True)
assert info(war)[0] == "player" and info(war)[3] == "PRIEST", info(war)
assert info(pala, "swing")[0] == "player"
assert info(hunt, "shot")[0] == "player"
for c in (war, pala, hunt):
    c.eval(PVP, False)
assert info(war)[0] == "pack", "the pack's own state kept under the player"

war.eval("_G.__oIEP = IsEncounterInProgress; IsEncounterInProgress = function() return true end; "
         "ns.DB:SetSetting('war.sit.bosses', 'key')")
settle(war, 3.5)
assert info(war)[0] == "single", "a boss with 'My key only' stays one target"
war.eval("ns.DB:SetSetting('war.sit.bosses', nil)")
settle(war, 1.2)
assert info(war)[0] == "pack", "Count adds: a boss with adds plays as a pack"
war.eval("IsEncounterInProgress = __oIEP")
war.eval("ns.DB:SetSetting('war.sit.mode', 'key')")
assert info(war)[0] == "single"
war.eval("ns.DB:SetSetting('war.sit.mode', 'off')")
assert info(war)[:3] == ("single", 0, "none"), "Off: one target, nothing counted or held"
war.eval("ns.DB:SetSetting('war.sit.mode', nil)")

# ---------------------------------------------------------------------------------------------------------------
# The switch key
# ---------------------------------------------------------------------------------------------------------------
CYCLE = "return ns.Situation:Cycle() or 'auto'"
assert war.eval("return ns.Situation:ActiveTool()") == "war"
assert [war.eval(CYCLE) for _ in range(4)] == ["single", "pack", "player", "auto"]
assert pala.eval("return ns.Situation:ActiveTool()") == "swing"
assert [pala.eval(CYCLE) for _ in range(3)] == ["single", "player", "auto"], "Ret has no pack on the key"
war.eval("ns.Situation:SetLock('single')")
assert info(war)[0] == "single" and info(war)[4] is True, "the key's pick beats the count"
war.eval("ns.Situation:SetLock('player')")
assert info(war)[0] == "player"
# held until the fight ends (sit.hold "fight"): a fight ran since it was picked
war.eval("__MOCK.combat = true; __MOCK.fire('PLAYER_REGEN_DISABLED')")
war.eval("__MOCK.combat = false; __MOCK.fire('PLAYER_REGEN_ENABLED')")
assert war.eval("return ns.Situation:Lock()") is None
war.eval("ns.DB:SetSetting('sit.hold', 'key'); ns.Situation:SetLock('pack')")
war.eval("__MOCK.combat = true; __MOCK.fire('PLAYER_REGEN_DISABLED')")
war.eval("__MOCK.combat = false; __MOCK.fire('PLAYER_REGEN_ENABLED')")
assert war.eval("return ns.Situation:Lock()") == "pack", "'Until I press it again' keeps it"
war.eval("ns.Situation:SetLock(nil); ns.DB:SetSetting('sit.hold', nil)")
war.eval("for g in pairs(__MOCK.npc_combat) do __MOCK.npc_combat[g] = nil end")

# ---------------------------------------------------------------------------------------------------------------
# The warrior's rotation per situation (now = 10, 50 ms latency)
# ---------------------------------------------------------------------------------------------------------------
RUN = """
    local W = ns.WarriorSwing
    local o = ...
    local use = { bt = false, ms = true, ww = true, exe = true, shout = true, rampage = false, brage = false,
                  ham = false, hs = true, slam = true, sweep = false, cleave = false, op = false, rend = false }
    for k, v in pairs(o.use or {}) do use[k] = v end
    local two = o.two ~= false
    local kind = o.kind or 'single'
    local snap = { now = 10, spec = o.spec or 'arms', twoHand = two, rage = o.rage or 60, stance = o.stance or 3,
      line = o.line or 80, kind = kind, lampKey = o.lamp or 'hs', dance = o.dance or false, keep = o.keep or 10,
      danceRage = o.danceRage or 10, hamLeft = o.hamLeft or 0, hamRefresh = 2, rendLeft = o.rendLeft or 0,
      opUntil = o.opUntil or 0,
      mhNext = o.mh or 12.0, mhSpeed = 3.6, ohNext = (not two) and 10.5 or nil, ohSpeed = (not two) and 2.6 or nil,
      lat = 0.05, gcdReady = 10, gcd = 1.5,
      ready = { bt = o.bt or 10, ms = o.ms or 10, ww = o.ww or 10, brage = 10, sweep = o.sweep or 10, op = 10 },
      use = use, exec = false, queued = nil, shoutLeft = 100, rampageLeft = 30, rampageUsable = false, slamCast = 0.5,
      gainMH = 14, gainOH = (not two) and 7 or 0 }
    local steps, lamp = W.Run(snap)
    local out = {}
    for i, st in ipairs(steps) do
        out[i] = st.key .. '@' .. string.format('%.2f', st.at) .. (st.off and '!' or '') .. (st.stance and ('/' .. st.stance) or '')
    end
    return table.concat(out, ' '), lamp or 'none'
"""
def run(**o):
    return war.eval("local t = {}; for k, v in pairs(...) do t[k] = v end; return (function(...) " + RUN + " end)(t)", o)

# a pack, Arms two-hander: Sweeping Strikes (off the GCD) and Whirlwind first, then Slam after the swing, Mortal Strike
pack = dict(kind="pack", lamp="cleave", line=40, use={"sweep": True, "cleave": True})
seq = run(**pack)[0].split()
assert seq[0] == "sweep@10.00!" and seq[1] == "ww@10.00", seq
assert run(**pack)[1] == "queue", "Cleave from 40 rage in a pack"
assert run(rage=30, **pack)[1] == "hold"
# Fury in a pack: Whirlwind before a ready Bloodthirst (one target: Bloodthirst first)
fury = dict(spec="fury", two=False, use={"bt": True, "ms": False, "slam": False})
assert run(**fury)[0].split()[0] == "bt@10.00"
assert run(kind="pack", **fury)[0].split()[0] == "ww@10.00", run(kind="pack", **fury)
# against a player: Hamstring when it runs out within 2 s; else later
pl = dict(kind="player", use={"ham": True, "slam": False})
assert run(hamLeft=1, **pl)[0].split()[0] == "ham@10.00", run(hamLeft=1, **pl)
seq = run(hamLeft=9, **pl)[0].split()
assert seq[0] == "ms@10.00", seq
# Overpower after a dodge: only in Battle Stance; with stance dancing the press carries the swap (stance 1)
op = dict(kind="player", use={"op": True, "ham": False}, opUntil=14, ms=16, ww=20)
assert run(**op)[0].split()[0] != "op@10.00", "no dancing: Overpower waits for Battle Stance"
assert run(dance=True, rage=20, **op)[0].split()[0] == "op@10.00/1", run(dance=True, rage=20, **op)
# a swap that would throw away more than allowed (60 rage, keeps 10, may lose 10): not now
assert not run(dance=True, rage=60, **op)[0].startswith("op@"), run(dance=True, rage=60, **op)
# ... Tactical Mastery 3/3 keeps 25 and allows 40 lost: fine
assert run(dance=True, rage=60, keep=25, danceRage=40, **op)[0].split()[0] == "op@10.00/1"
# the window closes: no Overpower after it
assert not run(dance=True, rage=20, opUntil=10.02, **{k: v for k, v in op.items() if k != "opUntil"})[0].startswith("op@")
# Rend (opt-in) when it is off the target; in Battle Stance (from Berserker: a swap)
rend = dict(kind="player", use={"rend": True, "ham": False, "ms": False, "ww": False, "slam": False})
assert run(dance=True, rage=20, **rend)[0].split()[0] == "rend@10.00/1"
assert run(dance=True, rage=20, rendLeft=8, **rend)[0].startswith("rend@18.00/1 rend@39.00"), "again when it ends"

# ---------------------------------------------------------------------------------------------------------------
# Ret: Seal of Command's Judgement on a stunned target against a player
# ---------------------------------------------------------------------------------------------------------------
RET = """
    local o = ...
    local S = ns.SwingTimer
    local snap = { now = 10, nextSwing = o.nxt or 12, lastSwing = (o.nxt or 12) - 3.5, speed = 3.5, lat = 0.05,
        gcdReady = 10, seal = o.seal or 'soc', gcd = 1.5, cd = { cs = 6, judge = 10, exo = 15, cons = 8 },
        use = { cs = true, exo = false, cons = false, stunJudge = o.stunJudge or false, hoj = o.hoj or false },
        ready = { cs = 16, judge = o.judge or 10, exo = 10, cons = 10, hoj = o.hojAt or 10 },
        stunUntil = o.stun or 0 }
    local steps = S.Run(snap)
    local out = {}
    for i, st in ipairs(steps) do out[i] = st.key .. '@' .. string.format('%.2f', st.at) end
    return table.concat(out, ' ')
"""
def ret(**o):
    return pala.eval("local t = {}; for k, v in pairs(...) do t[k] = v end; return (function(...) " + RET + " end)(t)", o)

assert ret().split()[0] != "judge@10.00", "one target: Judgement only after Seal of Blood (the twist)"
assert ret(stunJudge=True, stun=13).split()[0] == "judge@10.00", ret(stunJudge=True, stun=13)
assert ret(stunJudge=True, stun=0).split()[0] != "judge@10.00", "not stunned: the twist as before"
assert ret(stunJudge=True, stun=13, judge=11).split()[0] == "judge@11.00", "when Judgement is back, still stunned"
assert ret(hoj=True, stunJudge=True).split()[:2] == ["hoj@10.00", "judge@10.05"], ret(hoj=True, stunJudge=True)
# the live snapshot: only against a player, and only with the switch on
pala.eval("ns.Situation:Dirty()")
assert pala.eval("return ns.SwingTimer:Snapshot(GetTime()).use.stunJudge") is False
pala.eval(PVP, True)
pala.eval("ns.Situation:Dirty()")
assert pala.eval("return ns.SwingTimer:Snapshot(GetTime()).use.stunJudge") is True
pala.eval("ns.DB:SetSetting('swing.stunJudge', false); ns.Situation:Dirty()")
assert pala.eval("return ns.SwingTimer:Snapshot(GetTime()).use.stunJudge") is False
pala.eval("ns.DB:SetSetting('swing.stunJudge', nil)")
pala.eval(PVP, False)
# the stun list: a Hammer of Justice on the target counts, a Polymorph does not
STUN = ("local name = GetSpellInfo(...); _G.__oUD2 = _G.__oUD2 or UnitDebuff; UnitDebuff = function(u, i) "
        "if u == 'target' and i == 1 then return name, 0, 0, nil, 6, GetTime() + 4 end return nil end; "
        "local v = ns.SwingTimer.StunnedUntil(GetTime()) - GetTime(); UnitDebuff = __oUD2; return v")
assert abs(pala.eval(STUN, 853) - 4) < 0.01
assert pala.eval(STUN, 118) < 0, "a sheep is not a stun"

# ---------------------------------------------------------------------------------------------------------------
# Hunter: a pack's Volley (picked), a player's Concussive / Aimed / Viper Sting / Wing Clip
# ---------------------------------------------------------------------------------------------------------------
HUN = """
    local o = ...
    local S = ns.ShotTimer
    local use = { steady = true, multi = true, arcane = true, aspect = false, viperStart = 5, viperStop = 25 }
    for k, v in pairs(o.use or {}) do use[k] = v end
    local snap = { now = 10, nextStart = o.nxt or 12.0, speed = 3.0, cycle = 3.0, haste = 1, windup = 0.5, buffer = 0.5,
        ct = { steady = 1.5, multi = 0.5, aimed = 2.5, volley = 6 }, lat = 0.05, react = 0, gcdReady = 10,
        busyUntil = 10, gcd = 1.5, cd = { multi = 10, arcane = 6, kc = 5, volley = 60, etrap = 30, conc = 12,
        aimed = 6, vsting = 15 }, readySince = 10,
        ready = { multi = 10, arcane = 10, volley = 10, etrap = 10, conc = 10, aimed = 10, vsting = 10, ssting = 10 },
        kc = false, use = use, mana = 80, aspect = 'hawk', inMelee = o.melee or false,
        left = { conc = o.conc or 0, aimed = o.aimed or 0, wclip = 0, sting = o.sting or 0 } }
    local steps = S.Run(snap)
    local out = {}
    for i, st in ipairs(steps) do out[i] = st.key .. '@' .. string.format('%.2f', st.at) end
    return table.concat(out, ' ')
"""
def hun(**o):
    return hunt.eval("local t = {}; for k, v in pairs(...) do t[k] = v end; return (function(...) " + HUN + " end)(t)", o)

assert hun().split()[0] == "steady@10.00"
assert hun(use={"volley": True}).split()[0] == "volley@10.00", "a pack with Volley picked"
assert hun(use={"conc": True}).split()[0] == "conc@10.00", "Concussive before Steady"
assert hun(use={"conc": True}, conc=3).split()[0] == "steady@10.00", "already Dazed"
assert hun(use={"aimed": True, "conc": False}).split()[0] == "aimed@10.00"
assert hun(use={"sting": "vsting"}).split()[0] == "vsting@10.00"
assert hun(use={"sting": "vsting"}, sting=5).split()[0] == "steady@10.00"
assert hun(use={"wclip": True}, melee=True).split()[0] == "wclip@10.00"
assert hun(use={"wclip": True}, melee=False).split()[0] == "steady@10.00", "Wing Clip only in melee range"
# held: no Multi-Shot / Volley (snapshot)
for g in mobs:
    hunt.show_nameplate(g)
hunt.eval("__MOCK.npc_combat = {}; for _, g in ipairs(...) do __MOCK.npc_combat[g] = true end", mobs[:3])
hunt.eval("for _, id in ipairs({ 27021, 1510, 34120 }) do __MOCK.known_spells[id] = true end; __MOCK.fire('SPELLS_CHANGED')")
hunt.eval("ns.DB:SetSetting('shot.volley', true)")
settle(hunt, 1.3, "shot")
assert info(hunt, "shot")[0] == "pack", info(hunt, "shot")
assert hunt.eval("ns.Situation:Dirty(); local s = ns.ShotTimer:Snapshot(GetTime()); return s.kind, s.use.multi, s.use.volley") == ("pack", True, True)
hunt.eval(CC, mobs[3])
assert hunt.eval("ns.Situation:Dirty(); local s = ns.ShotTimer:Snapshot(GetTime()); return s.use.multi, s.use.volley") == (False, False)
hunt.eval("UnitDebuff = _G.__oldUD; __MOCK.npc_combat = {}; ns.DB:SetSetting('shot.volley', nil)")

# ---------------------------------------------------------------------------------------------------------------
# The chip on the ring (the Demo page's moments play a pack and a duel on your timer)
# ---------------------------------------------------------------------------------------------------------------
assert war.eval("local ok = ns.Demo:Play('sitpack'); return ok") is True
w.tick(1.0)
CHIP = """
    local f = _G[...]
    if not (f and f:IsShown()) then return 'no frame' end
    local c = f.chip
    if not c then return 'no chip' end
    return c:IsShown() and c.text:GetText() or 'hidden', c.lock:IsShown()
"""
r = war.eval(CHIP, "DisasterZoneWarriorSwing")
assert r == ("Pack · 4", False), r
war.eval("ns.Demo:StopMoment()")
w.tick(0.5)
assert war.eval("return ns.Situation:Demo()") is None
assert war.eval("local ok = ns.Demo:Play('sitduel'); return ok") is True
w.tick(1.0)
r = war.eval(CHIP, "DisasterZoneWarriorSwing")
assert r[0].startswith("Player · "), r
war.eval("ns.Demo:StopMoment()")
# a Paladin's pack pull shows the Warrior's timer (Ret has no pack); the duel plays on the Ret timer
assert pala.eval("local ok = ns.Demo:Play('sitpack'); return ok") is True
w.tick(1.0)
assert pala.eval(CHIP, "DisasterZoneWarriorSwing") == ("Pack · 4", False)
pala.eval("ns.Demo:StopMoment()")
assert pala.eval("local ok = ns.Demo:Play('sitduel'); return ok") is True
w.tick(1.0)
assert pala.eval(CHIP, "DisasterZoneSwingTimer")[0].startswith("Player · ")
pala.eval("ns.Demo:StopMoment(); ns.Demo:StopAll()")
war.eval("ns.Demo:StopAll()")

# ---------------------------------------------------------------------------------------------------------------
# Settings > Class tools: the Situations rows on each timer's card
# ---------------------------------------------------------------------------------------------------------------
ROWS = """
    ns.MainFrame:Open('settings')
    ns.SettingsUI:SelectSection(...)
    local seen = {}
    for _, e in ipairs(ns.SettingsUI.index or {}) do
        if e.kit == select(1, ...) then seen[#seen + 1] = e.title end
    end
    return table.concat(seen, '|')
"""
rows = war.eval(ROWS, "war").split("|")
for t in ("Switch by situation", "Show the situation", "Switch key", "Your pick holds", "Sound on a switch",
          "Pack from", "Reach", "Count", "Switch to a pack after", "Back to one target after", "On bosses",
          "Keep crowd control safe", "Cleave line", "Pack presses", "Stance dancing", "Most rage a swap may cost",
          "Refresh Hamstring", "Heroic Strike line", "Player presses"):
    assert t in rows, (t, rows)
rows = pala.eval(ROWS, "swing").split("|")
assert "Judge Command on a stun" in rows and "Hammer of Justice" in rows and "Pack from" not in rows, rows
rows = hunt.eval(ROWS, "shot").split("|")
for t in ("Pack from", "Volley", "Explosive Trap", "Concussive before Steady", "Aimed Shot", "Sting", "Wing Clip"):
    assert t in rows, (t, rows)

# the card's More options fold: shut, the pack's and player's rows take no room; open, they show and the card grows;
# Off hides the rows that need the switch
FOLD = """
    ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('war'); ns.SettingsUI:Refresh()
    local body
    for _, c in ipairs(ns.SettingsUI.sections.classtools.cards) do if c.kit.key == 'war' then body = c.body end end
    local function shown(title)
        for _, r in ipairs(body.rows) do if r.title:GetText() == title then return r:IsShown() end end
        return 'missing'
    end
    local h0 = body.height
    local shut = shown('Pack from')
    ns.SettingsUI:SetMoreOpen(body, true)
    local open, h1 = shown('Pack from'), body.height
    ns.DB:SetSetting('war.sit.mode', 'off'); ns.SettingsUI:Refresh()
    local offShow, offPack = shown('Show the situation'), shown('Pack from')
    ns.DB:SetSetting('war.sit.mode', nil); ns.SettingsUI:SetMoreOpen(body, false); ns.SettingsUI:Refresh()
    return shown('Switch by situation'), shut, open, h1 > h0, offShow, offPack, shown('Show the situation')
"""
assert war.eval(FOLD) == (True, False, True, True, False, False, True), war.eval(FOLD)
print("ok")
