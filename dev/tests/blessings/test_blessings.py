#!/usr/bin/env python
"""Paladin blessings (Core/Blessings.lua, UI/BlessingsUI.lua, UI/BlessingsBar.lua, Core/ClassKit.lua): paladins find
each other over Pally Power's protocol (PLPWR), a leader's Auto-assign reaches everyone, permissions hold, a Pally
Power peer's plain messages are understood and ours have its exact format, reports, presets, the planner window, the
buff bar and the Settings section."""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from harness import World, Client  # noqa: E402


def txt(x):
    return x.decode() if isinstance(x, bytes) else x


def texts(c, start=""):
    return [txt(e["text"]) for e in c.sent_addon if e["prefix"] == "PLPWR" and txt(e["text"]).startswith(start)]

# spells each paladin knows (highest ranks; greaters; auras)
COMMON = [27142, 27143, 27140, 27141, 1038, 25895, 27144, 27145, 27149, 27150, 19746, 27151, 27152, 27153]
KNOWN = {
    "Caelith": COMMON + [20217, 25898, 27168, 27169, 25780],      # Protection: Kings, Sanctuary, Righteous Fury
    "Gina": COMMON,                                                # Holy
    "Sunniva": COMMON + [20218],                                   # Retribution: Sanctity Aura
}

w = World()
cae = Client(w, "Caelith", class_file="PALADIN", guild_rank=0, talents=(5, 41, 15))
gina = Client(w, "Gina", class_file="PALADIN", guild_rank=2, talents=(41, 20, 0))
sun = Client(w, "Sunniva", class_file="PALADIN", guild_rank=3, talents=(5, 11, 45))
vic = Client(w, "Victhar", class_file="WARRIOR", guild_rank=3, talents=(5, 11, 45))
pp = Client(w, "Holypal", class_file="PRIEST", guild_rank=3)      # plays a Pally Power user: sends plain messages
pals = (cae, gina, sun)
for c in w.clients:
    c.load_addon()
# talents share their spell's icon (Pally Power reads Improved Might / Wisdom that way): give the mock real icons
TALENTS = {"Caelith": (0, 0), "Gina": (0, 2), "Sunniva": (5, 0)}      # (Improved Might, Improved Wisdom)
for c in pals:
    c.eval("""
        local might, wisdom = ...
        local icons = { [19740] = 1002, [19742] = 1001, [20911] = 1006, [465] = 2001, [7294] = 2002 }
        GetSpellTexture = function(id) return icons[id] or 136243 end
        GetNumTalentTabs = function() return 3 end
        GetNumTalents = function() return 1 end
        GetTalentInfo = function(tab)
            if tab == 1 then return 'Improved Blessing of Wisdom', 1001, 1, 1, wisdom, 2 end
            if tab == 3 then return 'Improved Blessing of Might', 1002, 1, 1, might, 5 end
            return 'Improved Devotion Aura', 2001, 1, 1, 0, 5
        end
    """, *TALENTS[c.name])
    c.eval("local ids = ...; for _, id in ipairs(ids) do __MOCK.known_spells[id] = true end; ns.Blessings:ScanSelf()",
           KNOWN[c.name])
assert sun.eval("return ns.Blessings:TalentLine('Sunniva')") == "Imp. Might 5/5"
assert cae.eval("return ns.Blessings:TalentLine('Caelith')") == "Kings · Sanctuary"
w.tick(1)

# class tools: Blessings is for every paladin spec, the swing timer for Retribution only
assert cae.eval("return ns.ClassKit:IsMine('bless')") is True
assert gina.eval("return ns.ClassKit:IsMine('bless')") is True
assert vic.eval("return ns.ClassKit:IsMine('bless')") is False
assert sun.eval("return ns.ClassKit:IsMine('swing')") is True
assert gina.eval("return ns.ClassKit:IsMine('swing')") is False

# my own record: ranks + talents as Pally Power encodes them (Kings rank 1, no Sanctuary for Gina)
self_msg = cae.eval("return ns.Blessings:EncodeSelf()")
assert re.match(r"^SELF [0-9a-fn]{12}@[0-9n]{9}$", self_msg), self_msg
assert self_msg.startswith("SELF 7080101040"), self_msg          # Wisdom R7, Might R8, Kings, Salvation, Light R4
assert gina.eval("return ns.Blessings:EncodeSelf()").startswith("SELF 7280nn1040nn"), "Imp. Wisdom 2; no Kings, Sanctuary"
assert sun.eval("return ns.Blessings:EncodeSelf()").startswith("SELF 7085nn1040nn"), "Imp. Might 5"

# a raid: Caelith leads; everyone says hello (SELF / ASELF / FREEASSIGN) and asks (REQ)
w.make_raid([cae, gina, sun, vic, pp], leader=cae,
            extra_members=[{"name": "Shadowmelder", "class_file": "ROGUE"}, {"name": "Isolde", "class_file": "PRIEST"},
                           {"name": "Embera", "class_file": "MAGE"}, {"name": "Moonwhisper", "class_file": "DRUID"}])
w.tick(10)      # (ChatThrottleLib holds addon messages back for 5 s after login, as in game)
for c in w.clients:
    names = sorted(txt(n) for n in c.eval_py("local t = {}; for _, p in ipairs(ns.Blessings:Paladins()) do t[#t + 1] = p.name end; return t"))
    assert names == ["Caelith", "Gina", "Sunniva"], (c.name, names)
print("\n".join(w.errors())[:3000])
sent = texts(cae)
assert any(t.startswith("PPLEADER Caelith") for t in sent), sent
assert any(t.startswith("ASELF ") for t in sent), sent
assert any(re.match(r"^FREEASSIGN NO \| SYMCOUNT \d+ \| COOLDOWNS", t) for t in sent), sent
assert "REQ" in sent, sent
assert "REQ" not in texts(vic), "a non-paladin asks only when it opens the planner"

# a Pally Power user: plain SELF (Kings to all but Hunters) + ASELF; DisasterZone shows them
pp.eval("C_ChatInfo.SendAddonMessage('PLPWR', 'SELF 7280101040nn@33333n333', 'RAID')")
pp.eval("C_ChatInfo.SendAddonMessage('PLPWR', 'ASELF 856210404040nn10@3', 'RAID')")
pp.eval("C_ChatInfo.SendAddonMessage('PLPWR', 'FREEASSIGN NO | SYMCOUNT 12 | COOLDOWNS:0:0:0:0', 'RAID')")
w.tick(1)
assert gina.eval("return ns.Blessings:GetAssign('Holypal', 1)") == 3
assert gina.eval("return ns.Blessings:GetAssign('Holypal', 6)") is None, "hunters: none"
assert gina.eval("return ns.Blessings:GetAura('Holypal')") == 3, "Concentration"
assert gina.eval("return ns.Blessings.pals.Holypal.symbols") == 12
assert gina.eval("return ns.Blessings.pals.Holypal.bless[1][2]") == 2, "Improved Wisdom 2/2"
# a non-leader may not change Holypal; a raw ASSIGN from a non-leader for someone else is ignored
vic.eval("C_ChatInfo.SendAddonMessage('PLPWR', 'ASSIGN Holypal 1 2', 'RAID')")
w.tick(1)
assert gina.eval("return ns.Blessings:GetAssign('Holypal', 1)") == 3
# drop the Pally Power user again for the rest (they would take a blessing slot)
for c in w.clients:
    c.eval("ns.Blessings.pals.Holypal = nil")

# Victhar tanks (the raid plan / group role says so on the leader's client)
cae.eval("UnitGroupRolesAssigned = function(u) return (GetUnitName(u, true) == 'Victhar') and 'TANK' or 'NONE' end")

# permissions
assert gina.eval("return ns.Blessings:CanEdit('Sunniva')") is False
assert gina.eval("return ns.Blessings:SetAssign('Sunniva', 1, 2)") is False
assert cae.eval("return ns.Blessings:CanEdit('Sunniva')") is True, "the leader may"
assert gina.eval("return ns.Blessings:CanEdit('Gina')") is True, "my own row"

# the leader auto-assigns: Kings from the Protection paladin to everyone, Might from the Ret, Wisdom from Holy
assert cae.eval("return ns.Blessings:AutoAssign()") is True
w.tick(6)
ROW = "local n = ...; local t = {}; for ci = 1, 9 do t[ci] = ns.Blessings:GetAssign(n, ci) or 0 end; return t"
expect = {}
for name in ("Caelith", "Gina", "Sunniva"):
    expect[name] = cae.eval_py(ROW, name)
assert expect["Caelith"] == [3] * 9, expect
# Might from the Ret (5/5) for warriors, rogues, hunters (ci 1, 2, 6), Wisdom from the Holy (2/2) for priests,
# mages, warlocks (3, 7, 8); classes that want neither get the next thing they want (warriors: Salvation)
assert expect["Sunniva"][0] == 2 and expect["Sunniva"][1] == 2 and expect["Sunniva"][5] == 2, expect
assert expect["Gina"][2] == 1 and expect["Gina"][6] == 1 and expect["Gina"][7] == 1, expect
assert expect["Gina"][0] == 4, expect
for c in w.clients:
    for name in ("Caelith", "Gina", "Sunniva"):
        assert c.eval_py(ROW, name) == expect[name], (c.name, name, c.eval_py(ROW, name), expect[name])
# PASSIGN on the wire, in Pally Power's format
passign = texts(cae, "PASSIGN ")
assert "PASSIGN Caelith@333333333" in passign, passign
# no class gets the same blessing twice
for ci in range(9):
    given = [expect[n][ci] for n in expect if expect[n][ci]]
    assert len(given) == len(set(given)), (ci, given)
# the tank keeps no Salvation: whoever gives warriors Salvation gives Victhar something else
salv = [n for n in expect if expect[n][0] == 4]
if salv:
    single = gina.eval("return ns.Blessings:GetSingle(...)", salv[0], 1, "Victhar")
    assert single and single != 4, single
# auras: different ones (they share a party), Sanctity for the Ret
auras = {n: cae.eval("return ns.Blessings:GetAura(...)", n) for n in expect}
assert len(set(auras.values())) == 3, auras
assert auras["Sunniva"] == 7, auras

# Gina changes her own row: everybody sees it (ASSIGN after the short delay)
gina.eval("ns.Blessings:SetAssign('Gina', 9, 5)")
w.tick(2)
assert "ASSIGN Gina 9 5" in texts(gina), texts(gina)[-5:]
assert sun.eval("return ns.Blessings:GetAssign('Gina', 9)") == 5

# Free Assignment: Sunniva lets anyone assign her; Gina may then change her row
sun.eval("ns.DB:SetSetting('bless.free', true)")
w.tick(1)
assert gina.eval("return ns.Blessings:CanEdit('Sunniva')") is True
gina.eval("ns.Blessings:SetAssign('Sunniva', 4, 5)")
w.tick(2)
assert sun.eval("return ns.Blessings:GetAssign('Sunniva', 4)") == 5

# exceptions on the wire: NASSIGN, cleared with 0
cae.eval("ns.Blessings:SetSingle('Gina', 2, 'Shadowmelder', 5)")
w.tick(2)
assert sun.eval("return ns.Blessings:GetSingle('Gina', 2, 'Shadowmelder')") == 5
cae.eval("ns.Blessings:SetSingle('Gina', 2, 'Shadowmelder', 0)")
w.tick(2)
assert sun.eval("return ns.Blessings:GetSingle('Gina', 2, 'Shadowmelder')") is None

# report lines
lines = cae.eval_py("return ns.Blessings:ReportLines()")
assert lines[0] == "Blessings:" and any(l.startswith("Caelith: Kings to everyone") for l in lines), lines

# presets: save, change, load back
cae.eval("ns.Blessings:SavePreset('Black Temple')")
cae.eval("ns.Blessings:SetRow('Caelith', 6)")
assert cae.eval("return ns.Blessings:GetAssign('Caelith', 1)") == 6
cae.eval("ns.Blessings:LoadPreset('Black Temple')")
w.tick(2)
assert cae.eval("return ns.Blessings:GetAssign('Caelith', 1)") == 3
assert gina.eval("return ns.Blessings:GetAssign('Caelith', 5)") == 3

# the planner window: one row per paladin, a cell per class; a warrior (raid leader would be fine) can open it too
for c in (cae, vic):
    c.slash("/dz bless")
w.tick(0.5)
assert cae.eval("return ns.BlessingsUI:IsShown()") is True
assert cae.eval("local n = 0; for _, r in ipairs(ns.BlessingsUI:GetFrame().rows) do if r:IsShown() then n = n + 1 end end; return n") == 3
assert vic.eval("return ns.BlessingsUI:IsShown()") is True

# the buff bar: paladins in a group get it, with a row per class they bless
assert gina.eval("return DisasterZoneBlessBar ~= nil and DisasterZoneBlessBar:IsShown()") is True
assert gina.eval("local n = 0; for _, r in ipairs(ns.BlessingsBar:MyRows()) do n = n + 1 end; return n") >= 3
assert vic.eval("return DisasterZoneBlessBar == nil") is True, "no bar for a warrior"

# Settings > Class tools: a Blessings card for paladins; no Class tools at all for a warrior (no tools yet)
for c in (gina, vic):
    c.slash("/dz settings")
w.tick(0.5)
assert gina.eval("return ns.SettingsUI:KitShown('bless')") is True
assert vic.eval("return ns.SettingsUI.nav.classtools:IsShown()") is False
# cards fold: closing one shortens the section
gina.eval("ns.SettingsUI:SelectSection('classtools')")
h_open = gina.eval("return ns.SettingsUI.sections.classtools.height")
gina.eval("for _, c in ipairs(ns.SettingsUI.sections.classtools.cards) do if c.kit.key == 'bless' then "
          "c.head:Click() end end")
assert gina.eval("return ns.SettingsUI.sections.classtools.height") < h_open

# demo mode: the warrior gets every class's tools, a made-up raid in the planner (they lead, four paladins), the
# buff bar with nothing to cast, and the swing timer swinging on its own; nothing goes on the wire
before = len(texts(vic))
vic.slash("/dz demo on")
w.tick(1)
assert vic.eval("return ns.SettingsUI.nav.classtools:IsShown()") is True
assert vic.eval("return ns.SettingsUI:KitShown('bless') and ns.SettingsUI:KitShown('swing')") is True
vic.eval("ns.BlessingsUI:Open()")
w.tick(0.5)
assert vic.eval("local n = 0; for _, r in ipairs(ns.BlessingsUI:GetFrame().rows) do if r:IsShown() then n = n + 1 end end; return n") == 4
assert vic.eval("return ns.Blessings:CanEdit('Caelith') and ns.Blessings:IsLeader('Victhar')") is True
vic.eval("ns.Blessings:SetAssign('Caelith', 1, 6); ns.Blessings:AutoAssign()")
w.tick(2)
assert vic.eval("return DisasterZoneBlessBar ~= nil and DisasterZoneBlessBar:IsShown()") is True
assert vic.eval("return DisasterZoneBlessRow1:GetAttribute('spell1') == nil") is True, "nothing to cast in demo"
# the hunters' players: the wheel on one gives them a single blessing of mine instead (and back again)
vic.eval("ns.Blessings:SetAssign('Victhar', 6, 1)")
w.tick(1)
vic.eval("for i = 1, 20 do local r = _G['DisasterZoneBlessRow' .. i]; if r and r.data and r.data.cls == 'HUNTER' then "
         "ns.BlessingsBar:TogglePop(r, true) end end")
assert vic.eval("return DisasterZoneBlessPopout:IsShown()") is True
vic.eval("DisasterZoneBlessPop1:GetScript('OnMouseWheel')(DisasterZoneBlessPop1, -1)")
single = vic.eval("return ns.Blessings:GetSingle('Victhar', 6, 'Faelar')")
assert single and single != 1, single
vic.eval("local f = DisasterZoneBlessPop1:GetScript('OnMouseWheel'); f(DisasterZoneBlessPop1, 1)")
assert vic.eval("return ns.Blessings:GetSingle('Victhar', 6, 'Faelar')") is None, "back to the class's"
assert vic.eval("return ns.SwingTimer.active and DisasterZoneSwingTimer ~= nil and DisasterZoneSwingTimer:IsShown()") is True
# motion: the urgent class eases back to calm when blessed again, with one bloom that fades out
MOTION = """
    local f
    for i = 1, 20 do local r = _G['DisasterZoneBlessRow' .. i]; if r and r.face.wasHot then f = r.face end end
    if not f then return 'no urgent row' end
    ns.BlessingsBar.Aim(f, { hot = 0, lift = 0, line = 1 }, true)
    local out = {}
    for i = 1, 40 do
        ns.BlessingsBar.Step(f, 0.05)
        if i == 3 then out.midHot, out.midBloom = f.motion.cur.hot, f.bloom:IsShown() end
    end
    out.endHot, out.endBloom, out.label = f.motion.cur.hot, f.bloom:IsShown(), f.label:IsShown()
    return out
"""
mo = vic.eval_py(MOTION)
assert isinstance(mo, dict), mo
assert 0 < mo["midHot"] < 1 and mo["midBloom"] is True, mo
assert mo["endHot"] == 0 and mo["endBloom"] is False and mo["label"] is False, mo
assert len(texts(vic)) == before, texts(vic)[before:]
vic.slash("/dz demo off")
w.tick(1)
assert vic.eval("return ns.SwingTimer.active") is False
assert vic.eval("return DisasterZoneBlessBar:IsShown()") is False
assert vic.eval("return ns.Blessings.pals.Caelith ~= nil") is True, "the real raid's paladins are back"

# leaving the group: other paladins and singles go, my row stays
gina.eval("ns.Blessings:OnGroupLeft()")
assert gina.eval("local n = 0; for _ in pairs(ns.Blessings.pals) do n = n + 1 end; return n") == 1

# solo with the bar set to "Always": my own class, with the blessing my spec wants (Holy: Wisdom)
lone = Client(w, "Lonely", class_file="PALADIN", guild_rank=3, talents=(41, 20, 0))
lone.load_addon()
w.tick(1)
lone.eval("local ids = ...; for _, id in ipairs(ids) do __MOCK.known_spells[id] = true end; ns.Blessings:ScanSelf()",
          KNOWN["Gina"])
assert lone.eval("return DisasterZoneBlessBar == nil or not DisasterZoneBlessBar:IsShown()") is True, "not solo by default"
lone.eval("ns.DB:SetSetting('bless.bar', 'always'); ns.BlessingsBar:Update()")
w.tick(0.5)
assert lone.eval("return DisasterZoneBlessBar:IsShown()") is True
rows = lone.eval_py("local t = {}; for _, r in ipairs(ns.BlessingsBar:MyRows()) do t[#t + 1] = { r.cls, r.bi, r.unit } end; return t")
assert len(rows) == 1 and txt(rows[0][0]) == "PALADIN" and rows[0][1] == 1 and txt(rows[0][2]) == "player", rows

w.assert_no_errors()
print(w.report())
print("ok")
