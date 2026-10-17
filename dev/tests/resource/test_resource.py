#!/usr/bin/env python
"""Resource bar (Core/Resource.lua, UI/ResourceBar.lua, UI/ResourceFace.lua; feedback #26, #27's combo points): a class
tool for every class, off until switched on; it shows the power the character spends (rage, energy, mana; druids by
form) with marks at the costs of picked presses (none until picked; the client's cost wins over the data file's),
the swing timer's Heroic Strike line and a queued Heroic Strike's rage, energy ticks and the five-second rule, combo
points, druid mana under the forms and a capping warning; it draws in all six looks as a bar, upright and a globe,
Edit layout stretches the bar, its demo part plays on any character, and its Settings card lists the presses."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from harness import World, Client  # noqa: E402

w = World()
war = Client(w, "Garrosh", class_file="WARRIOR", guild_rank=0, talents=(17, 44, 0))
rog = Client(w, "Vanessa", class_file="ROGUE", guild_rank=1, talents=(20, 41, 0))
dru = Client(w, "Hamuul", class_file="DRUID", guild_rank=1, talents=(0, 41, 20))
pri = Client(w, "Anduin", class_file="PRIEST", guild_rank=1, talents=(0, 21, 40))
pala = Client(w, "Bob", class_file="PALADIN", guild_rank=1, talents=(0, 45, 16))
for c in w.clients:
    c.load_addon()
w.tick(2)

# ---------------------------------------------------------------------------------------------------------------
# A class tool for every class, off until switched on
# ---------------------------------------------------------------------------------------------------------------
for c in w.clients:
    r = c.eval_py("""
        local CK = ns.ClassKit
        local listed = false
        for _, k in ipairs(CK:List(CK:MyClass())) do if k.key == 'power' then listed = true end end
        return { mine = CK:IsMine('power'), on = CK:IsOn('power'), live = CK:IsLive('power'), listed = listed,
                 who = CK:ForWhom('power'), shown = DisasterZoneResourceBar:IsShown() }
    """)
    assert r == {"mine": True, "on": False, "live": False, "listed": True, "who": "Every class", "shown": False}, (c.name, r)
    c.eval("ns.ClassKit:SetOn('power', true)")
w.tick(0.3)

# The power, by type (the mock's UnitPower ignores the type): each test sets __P[type] = { now, max }
POWER = ("__P = __P or {}; local ptype = ...; "
         "UnitPowerType = function() return ptype, ({ [0] = 'MANA', [1] = 'RAGE', [3] = 'ENERGY' })[ptype] end; "
         "UnitPower = function(u, t) local p = __P[t or ptype] or { 0, 100 }; return p[1] end; "
         "UnitPowerMax = function(u, t) local p = __P[t or ptype] or { 0, 100 }; return p[2] end; "
         "__MOCK.fire('UNIT_DISPLAYPOWER', 'player')")


def set_power(c, ptype, now, most, token=None):
    c.eval("__P = __P or {}; __P[...] = { select(2, ...), select(3, ...) }", ptype, now, most)
    c.eval("__MOCK.fire('UNIT_POWER_FREQUENT', 'player', ...)", token or {0: "MANA", 1: "RAGE", 3: "ENERGY"}[ptype])


SNAP = """
    local s = ns.Resource:Snapshot()
    local marks = {}
    for _, m in ipairs(s.marks) do marks[#marks + 1] = m.key .. '=' .. m.cost end
    return { kind = s.kind, v = s.v, mx = s.mx, line = s.line, held = s.held, tick = s.tick, rule = s.rule,
             ghost = s.ghost, cap = s.cap or false, cp = s.cp, marks = table.concat(marks, ' '),
             mana = s.mana and math.floor(s.mana.pct + 0.5), rest = s.rest }
"""

# ---------------------------------------------------------------------------------------------------------------
# Warrior: rage, marks (none until picked), the Heroic Strike line, a queued Heroic Strike
# ---------------------------------------------------------------------------------------------------------------
war.eval(POWER, 1)
war.eval("""
    local names = { [29707] = 'Heroic Strike', [30335] = 'Bloodthirst', [1680] = 'Whirlwind', [25236] = 'Execute' }
    local old = GetSpellInfo
    GetSpellInfo = function(x, ...)
        if names[x] then return names[x], nil, nil, nil, nil, nil, x end
        for id, n in pairs(names) do if n == x then return n, nil, nil, nil, nil, nil, id end end
        return old(x, ...)
    end
    for id in pairs(names) do __MOCK.known_spells[id] = true end
    __MOCK.fire('SPELLS_CHANGED')
""")
set_power(war, 1, 62, 100)
war.eval("UnitAffectingCombat = function() return true end")
war.eval("__MOCK.fire('PLAYER_REGEN_DISABLED')")
w.tick(0.2)
s = war.eval_py(SNAP)
assert s["kind"] == "rage" and s["v"] == 62 and s["mx"] == 100, s
assert s["marks"] == "", "no marks until the player picks presses: %r" % s
assert s.get("line") == 40, "the Fury Heroic Strike line from the swing timer: %r" % s
assert war.eval("return DisasterZoneResourceBar:IsShown()") is True
assert war.eval("return ns.ResourceBar:Face().theme, ns.ResourceBar:Face().shape") == ("halo", "bar")

war.eval("ns.Resource:SetPicked('ww', true); ns.Resource:SetPicked('bt', true); ns.Resource:SetPicked('exe', true)")
s = war.eval_py(SNAP)
assert s["marks"] == "bt=30 ww=25 exe=15", "picked marks with the data file's costs: %r" % s
# the client's cost wins (talents count)
war.eval("GetSpellPowerCost = function(x) if x == 'Execute' then return { { type = 1, cost = 10 } } end return {} end")
s = war.eval_py(SNAP)
assert "exe=10" in s["marks"], s
war.eval("ns.Resource:SetPicked('exe', false)")
# a queued Heroic Strike: its rage is held
war.eval("IsCurrentSpell = function(n) return n == 'Heroic Strike' end")
s = war.eval_py(SNAP)
assert s.get("held") == 15, s
war.eval("IsCurrentSpell = function() return false end")
r = war.eval_py("""
    ns.ResourceBar:Update()
    local p = ns.ResourceBar:Face().p
    local shown = 0
    for _, m in ipairs(p.marks) do if m.peg:IsShown() then shown = shown + 1 end end
    return { fill = p.fill:IsShown(), over = p.over:IsShown(), hsl = p.hsl:IsShown(), marks = shown,
             peg1 = p.marks[1].peg:IsShown(), num = p.num:GetText() }
""")
assert r == {"fill": True, "over": True, "hsl": True, "marks": 2, "peg1": True, "num": "62"}, r
# rage full: the capping glow
set_power(war, 1, 100, 100)
assert war.eval_py(SNAP)["cap"] is True
set_power(war, 1, 62, 100)
# the next swing's rage is opt-in
assert war.eval_py(SNAP).get("ghost") is None
war.eval("ns.DB:SetSetting('power.swing', true)")
assert war.eval("return ns.Resource:Snapshot().swing") == 14
war.eval("ns.DB:SetSetting('power.swing', false)")

# ---------------------------------------------------------------------------------------------------------------
# Every look in every shape builds and paints (rage, energy, mana)
# ---------------------------------------------------------------------------------------------------------------
LOOKS = """
    local out = {}
    for _, t in ipairs(ns.ResourceFace.THEMES) do
        for _, sh in ipairs(ns.ResourceFace.SHAPES) do
            ns.DB:SetSetting('power.theme', t.key)
            ns.DB:SetSetting('power.shape', sh.key)
            ns.ResourceBar:Refresh()
            local f = ns.ResourceBar:Face()
            local W, H = DisasterZoneResourceBar:GetSize()
            if f.theme ~= t.key or f.shape ~= sh.key or not (W > 0 and H > 0) then
                out[#out + 1] = t.key .. '/' .. sh.key
            end
            if sh.key == 'upright' and not (H > W) then out[#out + 1] = 'upright not upright: ' .. t.key end
        end
    end
    ns.DB:SetSetting('power.theme', 'halo'); ns.DB:SetSetting('power.shape', 'bar'); ns.ResourceBar:Refresh()
    return table.concat(out, ', ')
"""
assert war.eval(LOOKS) == "", war.eval(LOOKS)

# Edit layout stretches the bar along its length
r = war.eval_py("""
    ns.Layout:SetSize('power', 300)
    local f = ns.ResourceBar:Face()
    local w1 = f.len
    ns.Layout:SetSize('power', false)
    return { stretched = w1, back = ns.ResourceBar:Face().len }
""")
assert r == {"stretched": 300 - 31, "back": 180}, r

# ---------------------------------------------------------------------------------------------------------------
# Rogue: energy ticks, the next tick's gain, combo points, capping
# ---------------------------------------------------------------------------------------------------------------
rog.eval(POWER, 3)
rog.eval("GetComboPoints = function() return 3 end; UnitAffectingCombat = function() return true end; "
         "__MOCK.fire('PLAYER_REGEN_DISABLED')")
set_power(rog, 3, 31, 100)
s = rog.eval_py(SNAP)
assert s["kind"] == "energy" and s.get("tick") is None and s.get("cp") == 3, s
set_power(rog, 3, 51, 100)        # +20: a tick
s = rog.eval_py(SNAP)
assert s.get("tick") is not None and s.get("tick") < 0.05 and s.get("ghost") == 20, s
w.tick(1.0)
s = rog.eval_py(SNAP)
assert 0.45 < s.get("tick") < 0.6, s
set_power(rog, 3, 11, 100)        # a spend is no tick
assert 0.45 < rog.eval_py(SNAP)["tick"] < 0.6
set_power(rog, 3, 94, 100)        # (a big jump is not a tick either: Thistle Tea)
w.tick(0.5)                       # 0.5 s to the next tick: 94 + 20 would spill over
s = rog.eval_py(SNAP)
assert s["cap"] is True, s
assert rog.eval("ns.ResourceBar:Update(); return ns.ResourceBar:Face().p.cp[3]:IsShown()") is True

# ---------------------------------------------------------------------------------------------------------------
# Druid in Cat form: energy, combo points and the mana under the form
# ---------------------------------------------------------------------------------------------------------------
dru.eval(POWER, 3)
dru.eval("GetComboPoints = function() return 4 end; __P[0] = { 6100, 10000 }")
set_power(dru, 3, 58, 100)
s = dru.eval_py(SNAP)
assert s["kind"] == "energy" and s.get("cp") == 4 and s.get("mana") == 61, s
dru.eval(POWER, 0)                # caster form: mana, no combo points
set_power(dru, 0, 6100, 10000)
s = dru.eval_py(SNAP)
assert s["kind"] == "mana" and s.get("cp") is None and s.get("mana") is None, s

# ---------------------------------------------------------------------------------------------------------------
# Priest: mana with the five-second rule, then regen ticks
# ---------------------------------------------------------------------------------------------------------------
pri.eval(POWER, 0)
pri.eval("UnitAffectingCombat = function() return true end; __MOCK.fire('PLAYER_REGEN_DISABLED')")
set_power(pri, 0, 9000, 10000)
set_power(pri, 0, 8400, 10000)    # a cast spent mana
w.tick(2)
s = pri.eval_py(SNAP)
assert s.get("rule") is not None and 0.35 < s.get("rule") < 0.45, s
w.tick(3.2)
set_power(pri, 0, 8460, 10000)    # a regen tick once the rule is over
s = pri.eval_py(SNAP)
assert s.get("rule") is None and s.get("tick") is not None and s.get("ghost") == 60, s
assert pri.eval("ns.ResourceBar:Update(); return ns.ResourceBar:Face().p.num:GetText()") == "85%"

# ---------------------------------------------------------------------------------------------------------------
# Show: at rest out of combat it hides; "always" keeps it, at the out-of-combat opacity
# ---------------------------------------------------------------------------------------------------------------
war.eval("UnitAffectingCombat = function() return false end; __MOCK.fire('PLAYER_REGEN_ENABLED')")
set_power(war, 1, 0, 100)
w.tick(0.2)
assert war.eval("return DisasterZoneResourceBar:IsShown()") is False
war.eval("ns.DB:SetSetting('power.show', 'always')")
w.tick(0.2)
assert war.eval("return DisasterZoneResourceBar:IsShown(), DisasterZoneResourceBar:GetAlpha()") == (True, 0.4)
war.eval("ns.DB:SetSetting('power.show', 'active')")

# ---------------------------------------------------------------------------------------------------------------
# D-10: the Warrior swing timer's "Rage in the timer" switch: off, no globe and the next press takes the middle;
# with the rotation hidden too, the main-hand weapon sits there
# ---------------------------------------------------------------------------------------------------------------
r = war.eval_py("""
    UnitAttackSpeed = function() return 2.6, 2.6 end
    ns.DB:SetSetting('war.idle', true); ns.ClassKit:SetOn('war', true); ns.WarriorSwing:Refresh()
    ns.WarriorSwingHUD:Refresh(); ns.WarriorSwingHUD:Update()
    local before = DisasterZoneWarriorSwing.face.extra.globe ~= nil
    ns.DB:SetSetting('war.rage', false)
    ns.WarriorSwingHUD:Refresh(); ns.WarriorSwingHUD:Update()
    local f = DisasterZoneWarriorSwing.face
    return { before = before, after = f.extra.globe ~= nil, bar = f.extra.bar ~= nil,
             middle = f.geo.big[2] == 0 and f.geo.big[3] == 0, weapon = f.geo.middleWeapon == true }
""")
assert r == {"before": True, "after": False, "bar": False, "middle": True, "weapon": True}, r
r = war.eval_py("""
    UnitAffectingCombat = function() return true end
    __MOCK.fire('PLAYER_REGEN_DISABLED')
    GetInventoryItemTexture = function(_, slot) if slot == 16 then return 'Interface/Icons/INV_Sword_27' end end
    ns.DB:SetSetting('war.rotation', false)
    ns.WarriorSwing.OnMH(GetTime() - 1.0)
    ns.WarriorSwingHUD:Refresh(); ns.WarriorSwingHUD:Update()
    local big = DisasterZoneWarriorSwing.face.big
    return { shown = big:IsShown(), icon = big.icon:GetTexture(), name = big.name:GetText() or '' }
""")
assert r == {"shown": True, "icon": "Interface/Icons/INV_Sword_27", "name": ""}, r
war.eval("ns.DB:SetSetting('war.rotation', true); ns.DB:SetSetting('war.rage', true); ns.ClassKit:SetOn('war', false); "
         "UnitAffectingCombat = function() return false end; __MOCK.fire('PLAYER_REGEN_ENABLED')")
w.tick(0.3)

# ---------------------------------------------------------------------------------------------------------------
# Switched off: nothing on screen
# ---------------------------------------------------------------------------------------------------------------
rog.eval("ns.ClassKit:SetOn('power', false)")
w.tick(0.2)
assert rog.eval("return DisasterZoneResourceBar:IsShown()") is False

# ---------------------------------------------------------------------------------------------------------------
# The Settings card: the presses this warrior knows, none picked on a new character
# ---------------------------------------------------------------------------------------------------------------
war.slash("/dz settings")
w.tick(0.5)
war.eval("ns.SettingsUI:SelectSection('power')")
w.tick(0.2)
r = war.eval_py("""
    local card
    for _, c in ipairs(ns.SettingsUI.sections.classtools.cards) do if c.kit.key == 'power' then card = c end end
    local labels, chosen = {}, 0
    local function walk(f)
        for _, ch in ipairs({ f:GetChildren() }) do
            if ch.key and ch.SetKind and ch.GetText and ch:IsShown() then
                labels[#labels + 1] = ch:GetText()
                if ns.Resource:Picked()[ch.key] then chosen = chosen + 1 end
            end
            walk(ch)
        end
    end
    walk(card.body)
    table.sort(labels)
    return { shown = ns.SettingsUI:KitShown('power'), open = card.body:IsShown(), presses = table.concat(labels, ', '),
             chosen = chosen }
""")
assert r["shown"] is True and r["open"] is True, r
assert r["presses"] == "Bloodthirst 30, Execute 10, Heroic Strike 15, Whirlwind 25", r
assert r["chosen"] == 2, r

# rows for another class's power stay hidden; the More options fold works inside a class tool's card
ROWS = """
    local card
    for _, cd in ipairs(ns.SettingsUI.sections.classtools.cards) do if cd.kit.key == 'power' then card = cd end end
    local out = {}
    for _, it in ipairs(card.body.items or {}) do
        if it.isRow and it.f:IsShown() and it.f.title then out[#out + 1] = it.f.title:GetText() end
    end
    return table.concat(out, '|'), card.body.height
"""
rows, h1 = war.eval(ROWS)
assert "Heroic Strike line" in rows and "Five-second rule" not in rows and "Combo points" not in rows, rows
assert "Spell icons on marks" not in rows, "folded under More options: %s" % rows
war.eval("for _, cd in ipairs(ns.SettingsUI.sections.classtools.cards) do if cd.kit.key == 'power' then "
         "ns.SettingsUI:SetMoreOpen(cd.body, true) end end")
rows2, h2 = war.eval(ROWS)
assert "Spell icons on marks" in rows2 and h2 > h1, (rows2, h1, h2)
pri.slash("/dz settings")
w.tick(0.5)
pri.eval("ns.SettingsUI:SelectSection('power')")
w.tick(0.2)
rows, _ = pri.eval(ROWS)
assert "Five-second rule" in rows and "Heroic Strike line" not in rows and "Next energy tick" not in rows, rows

# ---------------------------------------------------------------------------------------------------------------
# Demo on a Paladin with the tool off: the part plays a made-up mana fight
# ---------------------------------------------------------------------------------------------------------------
pala.eval("ns.Demo:SetOn('power', true); ns.Demo:StartPull()")
w.tick(3)
r = pala.eval_py("local s = ns.Resource:Snapshot(); return { shown = DisasterZoneResourceBar:IsShown(), kind = s.kind, "
                 "demo = s.demo }")
assert r == {"shown": True, "kind": "mana", "demo": True}, r
pala.eval("ns.Demo:StopAll()")
w.tick(0.5)
assert pala.eval("return DisasterZoneResourceBar:IsShown()") is False

w.assert_no_errors()
print(w.report())
print("ok")
