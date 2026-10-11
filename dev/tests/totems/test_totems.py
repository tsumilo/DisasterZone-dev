#!/usr/bin/env python
"""Shaman totems (Core/Totems.lua, UI/TotemsUI.lua, UI/TotemBar.lua, Data/Classes/Shaman.lua): shamans find each
other over ShamanPower's protocol (SHPWR), a ShamanPower peer's plain messages are understood and ours have its
format, permissions hold, the leader's Auto-assign reaches everyone, twist / Earth Shield / Heroism / boss changes
sync, raid groups without a shaman are found and fixed, the planner and the bar in demo mode (any class), the
Settings card."""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from harness import World, Client  # noqa: E402


def txt(x):
    return x.decode() if isinstance(x, bytes) else x


def texts(c, start=""):
    return [txt(e["text"]) for e in c.sent_addon if e["prefix"] == "SHPWR" and txt(e["text"]).startswith(start)]


# totems every shaman trains (first ranks, ShamanPower's order) + the talent ones per spec
BASE = [8075, 8071, 8143, 2484, 5730, 2062, 3599, 8190, 1535, 8227, 8181, 2894, 5675, 5394, 8166, 8170, 8184,
        8512, 8835, 3738, 25908, 8177, 10595, 15107, 6495, 32182]
KNOWN = {
    "Khaadun": BASE,                         # Enhancement
    "Iridi": BASE + [30706],                 # Elemental: Totem of Wrath
    "Velaara": BASE + [16190, 974],          # Restoration: Mana Tide, Earth Shield
}

w = World()
kha = Client(w, "Khaadun", class_file="SHAMAN", guild_rank=3, talents=(5, 45, 11))
iri = Client(w, "Iridi", class_file="SHAMAN", guild_rank=3, talents=(45, 11, 5))
vel = Client(w, "Velaara", class_file="SHAMAN", guild_rank=3, talents=(5, 15, 41))
vic = Client(w, "Victhar", class_file="WARRIOR", guild_rank=0, talents=(5, 15, 41))
sp = Client(w, "Spuser", class_file="PRIEST", guild_rank=3)      # plays a ShamanPower user: plain messages
shamans = (kha, iri, vel)
for c in w.clients:
    c.load_addon()
for c in shamans:
    c.eval("local ids = ...; for _, id in ipairs(ids) do __MOCK.known_spells[id] = true end; ns.Totems:ScanSelf()",
           KNOWN[c.name])
w.tick(1)

# class tools: Totems is for every shaman spec, not for a warrior
assert kha.eval("return ns.ClassKit:IsMine('totems')") is True
assert vel.eval("return ns.ClassKit:IsMine('totems')") is True
assert vic.eval("return ns.ClassKit:IsMine('totems')") is False
assert iri.eval("return ns.Totems:SpecOf('Iridi')") == "Elemental"
assert iri.eval("return ns.Totems:TalentLine('Iridi')") == "Totem of Wrath"
assert vel.eval("return ns.Totems:TalentLine('Velaara')") == "Earth Shield · Mana Tide"

# my own record in ShamanPower's SELF format
self_msg = iri.eval("return ns.Totems:EncodeSelf()")
assert re.match(r"^SELF [0-9n]+\|[0-9n]+\|[0-9n]+\|[0-9n]+\|@[0-9n]{4}#[01]:[^$]*\$[01]$", self_msg), self_msg
assert self_msg.startswith("SELF 123456|1234567|12456|12345678|@nnnn#0:$0"), self_msg   # no Mana Tide: 3 missing
assert vel.eval("return ns.Totems:EncodeSelf()").startswith("SELF 123456|234567|123456|12345678|@nnnn#1:"), \
    "Restoration: no Totem of Wrath, Mana Tide and Earth Shield known"

# a raid, 5 per group in order: group 1 Victhar, Khaadun, Spuser, Iridi, Velaara; groups 2 and 3 have no shaman
extra = lambda n, c: {"name": n, "class_file": c}
w.make_raid([vic, kha, sp, iri, vel], leader=vic, extra_members=[
    extra("Brakka", "WARRIOR"), extra("Vexis", "ROGUE"), extra("Faelar", "HUNTER"), extra("Tarrow", "HUNTER"),
    extra("Shade", "ROGUE"), extra("Rhosyn", "DRUID"), extra("Ulfric", "WARRIOR"),
    extra("Embera", "MAGE"), extra("Grumpykat", "WARLOCK"), extra("Nyxa", "PRIEST"),
])
w.tick(10)      # (ChatThrottleLib holds addon messages back for 5 s after login)
for c in w.clients:
    names = sorted(txt(n) for n in c.eval_py("local t = {}; for _, s in ipairs(ns.Totems:Shamans()) do t[#t + 1] = s.name end; return t"))
    assert names == ["Iridi", "Khaadun", "Velaara"], (c.name, names)
assert any(t.startswith("SELF ") for t in texts(kha)), texts(kha)
assert "REQ" in texts(kha), texts(kha)
assert "REQ" in texts(vic), "the leader asks too"
assert "REQ" not in texts(sp), "a non-shaman asks only when it opens the planner"

# groups: 1 = Victhar, Khaadun, Spuser, Iridi, Velaara (all in 1), 2 = Brakka..Shade, 3 = Rhosyn.. (no shaman)
groups = vic.eval_py("local by, order = ns.Totems:Groups(); local t = {}; for _, s in ipairs(order) do "
                     "t[#t + 1] = { s, #by[s].shamans, by[s].kind } end; return t")
assert [g[0] for g in groups] == [1, 2, 3], groups
assert groups[0][1] == 3 and groups[1][1] == 0 and groups[2][1] == 0, groups
# who to move into group 2: group 1 has three shamans, so one of them
assert vic.eval("return ns.Totems:SwapSuggestion(2)") in ("Velaara", "Iridi", "Khaadun")

# a ShamanPower user (plain SELF): their row shows; ESASSIGN in both forms; FREEASSIGN
sp.eval("C_ChatInfo.SendAddonMessage('SHPWR', 'SELF 1234|1234567|123456|12345678|@2512#1:Victhar$0', 'RAID')")
w.tick(1)
assert iri.eval("local t = {}; for el = 1, 4 do t[el] = ns.Totems:GetAssign('Spuser', el) or 0 end; return table.concat(t, ',')") == "2,5,1,2"
assert iri.eval("return ns.Totems:GetES('Spuser')") == "Victhar"
assert iri.eval("return ns.Totems:Knows('Spuser', 2, 1)") is True
sp.eval("C_ChatInfo.SendAddonMessage('SHPWR', 'ESASSIGN|Spuser|Brakka', 'RAID')")
w.tick(1)
assert iri.eval("return ns.Totems:GetES('Spuser')") == "Brakka", "pipe form"
sp.eval("C_ChatInfo.SendAddonMessage('SHPWR', 'ESASSIGN Spuser NONE', 'RAID')")
w.tick(1)
assert iri.eval("return ns.Totems:GetES('Spuser')") is None, "space form, NONE clears"
# a non-leader may not change someone else: Spuser's ASSIGN for Iridi is ignored
sp.eval("C_ChatInfo.SendAddonMessage('SHPWR', 'ASSIGN Iridi 1 3', 'RAID')")
w.tick(1)
assert iri.eval("return ns.Totems:GetAssign('Iridi', 1)") is None
for c in w.clients:
    c.eval("ns.Totems.shamans.Spuser = nil")

# permissions
assert iri.eval("return ns.Totems:CanEdit('Khaadun')") is False
assert iri.eval("return ns.Totems:SetAssign('Khaadun', 1, 2)") is False
assert iri.eval("return ns.Totems:CanEdit('Iridi')") is True, "my own row"
assert vic.eval("return ns.Totems:CanEdit('Iridi')") is True, "the leader"

# the leader auto-assigns; everyone ends up with the same plan
vic.eval("UnitGroupRolesAssigned = function(u) return (GetUnitName(u, true) == 'Victhar') and 'TANK' or 'NONE' end")
assert vic.eval("return ns.Totems:AutoAssign()") is True
w.tick(6)
ROW = "local n = ...; local t = {}; for el = 1, 4 do t[el] = ns.Totems:GetAssign(n, el) or 0 end; return t"
plan = {n: vic.eval_py(ROW, n) for n in ("Khaadun", "Iridi", "Velaara")}
for c in shamans:
    for n in plan:
        assert c.eval_py(ROW, n) == plan[n], (c.name, n, c.eval_py(ROW, n), plan[n])
# group 1 is a tank group: Strength of Earth and Windfury from the first shaman; the others take the next ones
assert sorted(p[0] for p in plan.values()) == [1, 2, 3], plan        # no two Earth totems alike in one party
assert plan["Iridi"][1] == 1, "Totem of Wrath from the Elemental"
assert 1 in [p[3] for p in plan.values()], "someone drops Windfury for the tanks"
assert vel.eval("return ns.Totems:GetES('Velaara')") == "Victhar", "Restoration shields the tank"
assert kha.eval("return ns.Totems:GetES('Velaara')") == "Victhar"
assert any(t.startswith("PASSIGN Iridi@") for t in texts(vic)), texts(vic)
# Heroism is raid-wide: one caster (Enhancement first) and one backup, the rest don't cast it
hero = {n: txt(vic.eval("return ns.Totems:GetHero(...)", n)) for n in ("Khaadun", "Iridi", "Velaara")}
assert hero == {"Khaadun": "pull", "Iridi": "backup", "Velaara": "none"}, hero
assert iri.eval("return ns.Totems:GetHero('Khaadun')") == "pull", "synced"
assert iri.eval("return ns.Totems:MissesText(ns.Totems:Groups()[2]):find('Heroism') == nil") is True

# twist, Earth Shield, Heroism timing and a boss change from the leader reach the shamans
vic.eval("ns.Totems:SetAssign('Khaadun', 4, 1); ns.Totems:SetTwist('Khaadun', true)")
vic.eval("ns.Totems:SetHero('Iridi', 'execute')")
vic.eval("ns.Totems:SetBoss('SerpentshrineCavern:Hydross', 'Iridi', 2, 6, false)")
vic.eval("ns.Totems:SetBoss('SerpentshrineCavern:Hydross', 'Iridi', 4, 6, true)")
w.tick(3)
assert kha.eval("return ns.Totems:GetTwist('Khaadun')") is True
assert iri.eval("return ns.Totems:GetHero('Iridi')") == "execute"
o = iri.eval_py("local o = ns.Totems:GetBoss('SerpentshrineCavern:Hydross', 'Iridi', 4); return o and { o.i, o.alt }")
assert o == [6, True], o
assert any(t.startswith("TWIST Khaadun 1") for t in texts(vic)), texts(vic)
assert any(t.startswith("DZBOSS Iridi SerpentshrineCavern:Hydross 4 6 1") for t in texts(vic)), texts(vic)
# what Iridi's bar does against Hydross: fire = Frost Resistance (right-click: the usual), air = the usual
# (right-click: Nature Resistance); with no boss: the plan, Khaadun's air twists
eff = iri.eval_py("local B = 'SerpentshrineCavern:Hydross'; local a, b, c = ns.Totems:Effective('Iridi', 2, B); "
                  "local d, e, f = ns.Totems:Effective('Iridi', 4, B); return { a, b or 0, c, d, e, f }")
assert eff[0] == 6 and eff[1] == plan["Iridi"][1] and txt(eff[2]) == "boss1", eff
assert eff[3] == plan["Iridi"][3] and eff[4] == 6 and txt(eff[5]) == "boss2", eff
tw = kha.eval_py("local a, b, c = ns.Totems:Effective('Khaadun', 4, nil); return { a, b, c }")
assert tw[0] == 1 and tw[1] == 2 and txt(tw[2]) == "twist", tw

# a newcomer's REQ: shamans answer with SELF, the leader with every shaman's extras (Iridi's boss changes)
before = len(texts(vic))
sp.eval("C_ChatInfo.SendAddonMessage('SHPWR', 'REQ', 'RAID')")
w.tick(5)
assert any(t.startswith("DZBOSS Iridi") for t in texts(vic)[before:]), texts(vic)[before:]

# report
lines = [txt(l) for l in vic.eval_py("return ns.Totems:ReportLines()")]
assert lines[0] == "Totems:" and any(l.startswith("Iridi (group 1): ") and "Totem of Wrath" in l for l in lines), lines
assert any(l.startswith("No shaman in group 2, 3") for l in lines), lines

# the bar: Khaadun's buttons are Heroism + his four totems; the Air button twists (castsequence), right-click GoA
kha.eval("ns.TotemBar:Update()")
w.tick(0.5)
assert kha.eval("return DisasterZoneTotemBar:IsShown()") is True
assert kha.eval("return DisasterZoneTotem_el4:GetAttribute('type1')") == "macro"
mt = txt(kha.eval("return DisasterZoneTotem_el4:GetAttribute('macrotext1')"))
assert mt.startswith("/castsequence reset=combat ") and "," in mt, mt
assert kha.eval("return DisasterZoneTotem_el4:GetAttribute('type2')") == "spell"
assert vic.eval("return DisasterZoneTotemBar == nil or not DisasterZoneTotemBar:IsShown()") is True, "not for a warrior"
# my totems come from the game's totem slots (earth = slot 2); none down: nothing
assert kha.eval("return ns.Totems:MyTotem(1)") is None
kha.eval("__MOCK.totems = { [2] = { 'Strength of Earth Totem', GetTime() - 10, 120, '' } }")
assert kha.eval("local n, s, d = ns.Totems:MyTotem(1); return n == 'Strength of Earth Totem' and d == 120") is True
kha.eval("__MOCK.totems = nil")
# Velaara: Earth Shield on Victhar as a /cast [@Victhar] macro, Mana Tide when it isn't the planned water totem
vel.eval("ns.TotemBar:Update()")
w.tick(0.5)
assert "[@Victhar]" in txt(vel.eval("return DisasterZoneTotem_es:GetAttribute('macrotext1')") or "")
assert vel.eval("return DisasterZoneTotem_tide:IsShown()") is True

# the planner (Iridi, not leading): rows by group + "No shaman" rows for groups 2 and 3; others' rows read only
iri.eval("ns.TotemsUI:Open()")
w.tick(0.5)
rows = iri.eval_py("local t = {}; for _, r in ipairs(ns.TotemsUI:GetFrame().rows) do if r:IsShown() then "
                   "t[#t + 1] = r.name or ('empty' .. r.emptySub) end end; return t")
assert [txt(r) for r in rows][-2:] == ["empty2", "empty3"] and len(rows) == 5, rows
iri.eval("ns.TotemsUI:Close()")

# demo mode, on a warrior: the whole tool shows with the made-up Serpentshrine raid; nothing is sent
before = len(texts(vic))
vic.slash("/dz demo on")
w.tick(1)
assert vic.eval("return ns.ClassKit:IsMine('totems')") is True
vic.eval("ns.TotemsUI:Open()")
w.tick(0.5)
demo_rows = vic.eval_py("local t = {}; for _, r in ipairs(ns.TotemsUI:GetFrame().rows) do if r:IsShown() then "
                        "t[#t + 1] = r.name or ('empty' .. r.emptySub) end end; return t")
assert [txt(r) for r in demo_rows] == ["Ornaar", "Victhar", "Iridi", "empty4", "Velaara"], demo_rows
assert vic.eval("return ns.Totems:SwapSuggestion(4)") == "Velaara", "the healers lose least"
assert vic.eval("return ns.Totems.Groups and ns.Totems:Groups()[4].kind") == "ranged"
assert vic.eval("return ns.Totems:MoveShaman('Velaara', 4)") is True
assert vic.eval("return ns.Totems:SubgroupOf('Velaara')") == 4
vic.eval("ns.TotemsUI:SetBossTab('SerpentshrineCavern:Hydross')")
w.tick(0.3)
assert vic.eval("return ns.TotemsUI:GetFrame().bossStrip:IsShown()") is True
ch = vic.eval_py("local t = {}; for _, e in ipairs(ns.Totems:BossChanges()) do t[#t + 1] = { e.el, e.i, e.alt, #e.names, e.was or 0 } end; return t")
assert ch == [[2, 6, False, 4, 2], [4, 6, True, 4, 1]], ch
vic.eval("ns.TotemBar:Update()")
w.tick(0.5)
kinds = [txt(k) for k in vic.eval_py("local t = {}; for _, p in ipairs(ns.TotemBar:Plan()) do "
                                     "t[#t + 1] = p.kind end; return t")]
assert kinds == ["el1", "el2", "el3", "el4"], kinds
assert vic.eval("return DisasterZoneTotem_hero:IsShown()") is True, "Heroism in the header"
assert vic.eval("return DisasterZoneTotem_el1:GetAttribute('spell1')") is None, "demo: nothing to cast"
assert vic.eval("local s = ns.TotemBar:Button('el3').state; return s and #s.missing") == 1, "Sunniva is out of range"
# Settings > Class tools shows the Totems card (demo shows every class's tools)
vic.eval("ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('totems')")
w.tick(0.3)
assert vic.eval("return ns.SettingsUI:KitShown('totems')") is True
# themes (UI/BarFace.lua): the totem cells follow the account's theme, the same size and gap on both axes; a click
# on a Settings tile sets it for both bars
THEMES = """
    local F, out = ns.BarFace, {}
    for _, t in ipairs(F.THEMES) do
        for _, lay in ipairs({ 'vertical', 'horizontal' }) do
            ns.DB:SetSetting('totems.layout', lay)
            ns.DB:SetSetting('classbar.theme', t.key)
            ns.TotemBar:Update()
            local a, b = DisasterZoneTotem_el1, DisasterZoneTotem_el2
            local _, _, _, x1, y1 = a:GetPoint(1)
            local _, _, _, x2, y2 = b:GetPoint(1)
            local w, h = a:GetSize()
            local step = lay == 'vertical' and (y1 - y2) or (x2 - x1)
            out[#out + 1] = (w == t.W and h == t.H and step == (lay == 'vertical' and t.H or t.W) + t.GAP
                and a.face.theme.key == t.key and DisasterZoneTotem_hero.face.theme.key == t.key) and 'ok'
                or (t.key .. ' ' .. lay .. ' ' .. w .. 'x' .. h .. ' step ' .. step)
        end
    end
    return out
"""
assert all(txt(x) == "ok" for x in vic.eval_py(THEMES)), vic.eval_py(THEMES)
TILE = """
    local hit
    local function walk(f)
        if hit then return end
        if f.key == 'gilded' and f.preview and f:IsVisible() then hit = f return end
        for _, c in ipairs({ f:GetChildren() }) do walk(c) end
    end
    ns.SettingsUI:OpenKit('totems')
    walk(UIParent)
    if not hit then return 'no tile' end
    hit:Click()
    return { ns.DB:GetSetting('classbar.theme'), DisasterZoneTotem_el1.face.theme.key }
"""
assert [txt(x) for x in vic.eval_py(TILE)] == ["gilded", "gilded"], vic.eval_py(TILE)
vic.eval("ns.DB:SetSetting('classbar.theme', 'halo'); ns.DB:SetSetting('totems.layout', 'vertical')")
# the bar's first cell opens the planner (a plain button: it never casts); a minimap pin's key opens the window; the
# Raids menu does not list the planners (the user didn't want them there)
PLAN = """
    ns.TotemBar:Update()
    local f = ns.TotemBar:GetFrame()
    local p, h = f.plan, DisasterZoneTotem_hero
    local _, _, _, _, py = p:GetPoint(1)
    local _, _, _, _, hy = h:GetPoint(1)
    ns.TotemsUI:Close()
    p:Click()
    local opened = ns.TotemsUI:IsShown()
    ns.TotemsUI:Close()
    ns.MainFrame:Open('totems')
    local pinned = ns.TotemsUI:IsShown()
    ns.TotemsUI:Close()
    ns.MainFrame:Open('home')
    ns.MainFrame:OpenGroupMenu('grp:raids')
    local pages = ns.NavMenu:GetPages()
    ns.NavMenu:Close()
    return { first = py > hy, secure = p.GetAttribute ~= nil and p:GetAttribute('type') or false, opened = opened,
             pinned = pinned, pages = pages, label = ns.MainFrame:GetPageLabel('blessings') }
"""
pl = vic.eval_py(PLAN)
assert pl["first"] is True and pl["secure"] in (False, None) and pl["opened"] is True and pl["pinned"] is True, pl
pages = [txt(x) for x in pl["pages"]]
assert "Blessings" not in pages and "Totems" not in pages and pages, pages
assert txt(pl["label"]) == "Blessings", pl
assert len(texts(vic)) == before, texts(vic)[before:]
vic.slash("/dz demo off")
w.tick(1)
assert vic.eval("return ns.Totems.shamans.Khaadun ~= nil") is True, "the real raid's shamans are back"
assert vic.eval("return DisasterZoneTotemBar:IsShown()") is False
# outside demo mode only my class's planner can be pinned: a warrior none (its pin does nothing), a shaman Totems
MENU = """
    ns.MainFrame:Open('home')
    ns.MainFrame:OpenGroupMenu('grp:raids')
    local pages = ns.NavMenu:GetPages()
    ns.NavMenu:Close()
    ns.MainFrame:Open('totems')
    local shown = ns.TotemsUI ~= nil and ns.TotemsUI:IsShown() or false
    if ns.TotemsUI then ns.TotemsUI:Close() end
    return { pages = pages, shown = shown, tools = ns.MainFrame:GetShownTools() }
"""
m = vic.eval_py(MENU)
assert not any(txt(x) in ("Blessings", "Totems") for x in m["pages"]) and m["shown"] is False and not m["tools"], m
m = kha.eval_py(MENU)
pages = [txt(x) for x in m["pages"]]
assert "Totems" not in pages and "Blessings" not in pages and m["shown"] is True, m
assert [txt(x) for x in m["tools"]] == ["totems"], m

w.assert_no_errors()
print(w.report())
print("ok")
