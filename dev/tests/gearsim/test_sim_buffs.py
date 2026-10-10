#!/usr/bin/env python
"""Gear sim buff presets (Sim/BuffPresets.lua, UI/SimBuffs.lua, the buffs menu of the page's settings sentence, UI/SimPanel.lua).

Covers: a team lineup I'm on shows in the card's buffs menu and its config follows who is placed (my group's
totems / shout / Unleashed Rage, the raid's blessings by paladin count, debuffs by class and spec), the comp's open
slots placed into groups and counted only while ticked; roster changes showing up without saving anything; my
clicks kept as overrides on top (and Reset); a preset built in the editor from 25-man, saved for all characters,
picked on the card, used by the sim, deleted (the card falls back to 25-man); a Warrior's Battle Shout tile; the
menu's edit hint opening the editor; no Lua errors.

Run: luaenv\\Scripts\\python.exe tests\\gearsim\\test_sim_buffs.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "sync"))

from common import Runner, Client, ExtraMember, new_world, up, settle, assert_no_lua_errors, key  # noqa: E402

r = Runner("gear sim buff presets")

GUILD = "Casual Disaster"
P1 = {1: 29073, 2: 28745, 3: 29075, 15: 24259, 5: 29071, 9: 28795, 10: 30644, 6: 28779, 7: 30257, 8: 28608,
      11: 28757, 12: 30834, 13: 29383, 14: 28830, 16: 28429, 18: 27484}
# name, class, spec index (ns.SPECS), group
ROSTER = [
    ("Kaelith", "SHAMAN", 2, 2), ("Grunt", "WARRIOR", 2, 2),
    ("Holyfire", "PALADIN", 1, 5), ("Moonfang", "DRUID", 1, 4), ("Arrowz", "HUNTER", 1, 4),
    ("Dotlock", "WARLOCK", 1, 4), ("Shiv", "ROGUE", 2, 3), ("Frostbolt", "MAGE", 3, 4), ("Lightwell", "PRIEST", 2, 5),
]


def world(me_class="PALADIN", me_spec="Retribution", me_sp=3):
    w = new_world()
    for name, cls, _, _ in ROSTER:
        w.offline_members.append(ExtraMember(name, cls, guild=GUILD, guild_rank=3))
    c = Client(w, "Raider", class_file=me_class, race="BloodElf" if me_class == "PALADIN" else "Orc", guild_rank=0)
    up(c)
    w._sync(roster_changed=True)
    settle(w, 5)
    assert c.eval("return ns.BiS:SetSpec(...)", me_spec) is True
    if me_class == "PALADIN":
        c.equip(P1)
    c.eval("ns.SimRunner.DEFAULT_ITERATIONS = 12")
    specs = {key(n): sp for n, _, sp, _ in ROSTER}
    specs[key("Raider")] = me_sp
    groups = {key(n): g for n, _, _, g in ROSTER}
    groups[key("Raider")] = 2
    # the comp wants a Feral (Cat) druid too: one open slot (a melee one: it sits in a melee group)
    comp = {"SHAMAN": [0, 1], "WARRIOR": [0, 1], "PALADIN": [1, 0, 1], "DRUID": [1, 1], "HUNTER": [1],
            "WARLOCK": [1], "ROGUE": [0, 1], "MAGE": [0, 0, 1], "PRIEST": [0, 1]}
    if me_class == "WARRIOR":
        comp["WARRIOR"] = [0, 2]
        comp["PALADIN"] = [1]
    res = c.eval_py("""local n, m, o = ...
      local ok, r = ns.RaidPlan:SaveTeam(nil, n, m, o)
      return { ok = ok, r = r }""", "Disaster Crew", [key("Raider")] + [key(n) for n, _, _, _ in ROSTER],
                    {"lineups": [{"size": 25, "specs": specs, "groups": groups, "comp": comp}]})
    assert res["ok"] is True, res
    tid = res["r"]
    ln = c.eval("return ns.RaidPlan:GetTeam(...).lineups[1].id", tid)
    c.eval('ns.MainFrame:Open("mybis")  ns.SimPanel:SetActive(true)')
    settle(w, 1)
    return w, c, tid, ln


def cfg(c, k):
    return c.eval_py("return ns.SimRunner:BuffConfig(...)", k)


@r.case
def team_lineup_follows_who_is_placed():
    w, c, tid, ln = world()
    lineups = c.eval_py("return ns.SimBuffs:MyLineups()")
    assert len(lineups) == 1, lineups
    l = lineups[0] if isinstance(lineups, list) else lineups[1]
    assert l["group"] == 2 and l["open"] == 1 and l["name"].startswith("Disaster Crew"), l
    k = l["key"]
    b = cfg(c, k)
    party, ind, raid, deb = b["party"], b["individual"], b["raid"], b["debuffs"]
    # my group: an Enhancement shaman (improved totems, twisting, Unleashed Rage), a Fury warrior's shout
    assert party.get("windfuryTotem") == 2 and party.get("graceOfAirTotem") == 2, party
    assert party.get("totemTwisting") is True and party.get("strengthOfEarthTotem") == 2, party
    assert ind.get("unleashedRage") is True and party.get("battleShout") == 2, (ind, party)
    # the open Feral (Cat) slot sits in my (melee) group while open slots count
    assert party.get("leaderOfThePack") == 2, party
    # two paladins (me, Ret: Might improved; Holyfire: Kings), no Wisdom
    assert ind.get("blessingOfKings") is True and ind.get("blessingOfMight") == 2, ind
    assert not ind.get("blessingOfWisdom"), ind
    assert raid.get("bloodlust") is True and raid.get("giftOfTheWild") == 1, raid
    assert raid.get("powerWordFortitude") == 2 and raid.get("arcaneBrilliance") is True, raid
    assert deb.get("sunderArmor") is True and deb.get("exposeArmor") == 2 and deb.get("faerieFire") == 2, deb
    assert deb.get("curseOfElements") == 2 and not deb.get("curseOfRecklessness"), deb
    assert deb.get("huntersMark") == 2 and deb.get("judgementOfWisdom") is True, deb
    assert not deb.get("improvedSealOfTheCrusader") and not deb.get("misery"), deb
    # what I bring: the class's 25-man consumables
    assert b["consumables"].get("flaskId") == 22854 and b["consumables"].get("potId") == 22838, b["consumables"]
    # open slots off: no Leader of the Pack
    c.eval("local t, l = ... ns.SimBuffs:SaveTeamState(t, l, { open = false, ov = {} })", tid, ln)
    assert not cfg(c, k)["party"].get("leaderOfThePack")
    c.eval("local t, l = ... ns.SimBuffs:SaveTeamState(t, l, { open = true, ov = {} })", tid, ln)
    # a roster change shows up by itself: Kaelith leaves my group -> no totems
    c.eval_py("""local tid, ln, kk = ...
      local t = ns.RaidPlan:GetTeam(tid)
      local l = t.lineups[1]
      l.groups[kk] = 1
      local ok, e = ns.RaidPlan:SaveTeam(tid, t.name, t.members, { lineups = t.lineups })
      assert(ok, e)""", tid, ln, key("Kaelith"))
    p2 = cfg(c, k)["party"]
    assert not p2.get("windfuryTotem") and not p2.get("strengthOfEarthTotem"), p2
    assert_no_lua_errors(w)


@r.case
def card_menu_lists_teams_and_picks_one():
    w, c, tid, ln = world()
    k = "t:%s:%s" % (tid, ln)
    c.eval("ns.UI:ContextMenu(ns.SimStage._frame().chip, function(root) ns.SimPanel:BuildSettingMenu(root, 'buffs') end)")
    m = c.last_menu()
    texts = [e.get("text") for e in m["children"]]
    assert "25-man buffs" in texts and "+" not in texts, texts
    team_rows = [t for t in texts if t and t.startswith("Disaster Crew")]
    assert team_rows, texts
    c.menu_select(team_rows[0])
    assert c.eval("return ns.SimPanel:GetBuffs()") == k
    assert c.eval("return (ns.SimRunner:BuffName(...))", k).startswith("Disaster Crew")
    # the run uses it
    sc = c.eval_py("return ns.SimRunner:Scenario(ns.SimPanel:Working(), { buffs = ..., duration = 180, "
                   "mobType = 'Mechanical', talents = ns.SimRunner:Talents() }).buffs", k)
    assert sc["party"].get("windfuryTotem") == 2, sc["party"]
    assert_no_lua_errors(w)


@r.case
def team_overrides_and_reset():
    w, c, tid, ln = world()
    k = "t:%s:%s" % (tid, ln)
    c.eval("ns.SimBuffsUI:Open(...)", k)
    d = c.eval_py("local d = ns.SimBuffsUI._draft() return { kind = d.kind, name = d.name }")
    assert d["kind"] == "team", d
    # Blood Frenzy: nobody Arms in the raid -> click it on
    clicked = c.eval("""for _, f in ipairs(ns.SimBuffsUI._tiles()) do
        if f:IsShown() and f.tile.key == "bloodfrenzy" then f:Click("LeftButton") return true end end""")
    assert clicked is True
    ov = c.eval_py("return ns.SimBuffsUI._draft().st.ov")
    assert ov == {"bloodfrenzy": 1}, ov
    c.eval("ns.SimBuffsUI:Save()")
    assert c.eval("return ns.SimPanel:GetBuffs()") == k
    assert cfg(c, k)["debuffs"].get("bloodFrenzy") is True
    # clicking back to what the lineup says follows the lineup again (no override)
    c.eval("""for _, f in ipairs(ns.SimBuffsUI._tiles()) do
        if f:IsShown() and f.tile.key == "bloodfrenzy" then f:Click("RightButton") return end end""")
    assert not c.eval_py("return ns.SimBuffsUI._draft().st.ov")
    c.eval("ns.SimBuffsUI:Save()")
    assert not cfg(c, k)["debuffs"].get("bloodFrenzy")
    # Reset
    c.eval("local t, l = ... ns.SimBuffs:SaveTeamState(t, l, { open = false, ov = { kings = 0 } })", tid, ln)
    c.eval("ns.SimBuffsUI:Open(...)  ns.SimBuffsUI:Delete()  ns.SimBuffsUI:Save()", k)
    st = c.eval_py("return ns.SimBuffs:GetTeamState(...)", tid, ln)
    assert st["open"] is True and not st["ov"], st
    assert_no_lua_errors(w)


@r.case
def preset_built_in_editor_saved_and_deleted():
    w, c, tid, ln = world()
    c.eval("ns.SimPanel:SetBuffs('raid10')")
    c.eval("ns.SimBuffsUI:Open(nil)")
    d = c.eval_py("local d = ns.SimBuffsUI._draft() return { kind = d.kind, from = d.from, name = d.name }")
    assert d == {"kind": "custom", "from": "raid10", "name": "New preset"}, d
    # start from 25-man, switch Bloodlust off, name it
    c.eval("for _, b in ipairs(ns.SimBuffsUI._win().chips) do if b.key == 'raid25' then b:Click() end end")
    assert c.eval_py("return ns.SimBuffsUI._draft().cfg.raid.bloodlust") is True
    c.eval("""for _, f in ipairs(ns.SimBuffsUI._tiles()) do
        if f:IsShown() and f.tile.key == "bloodlust" then f:Click("LeftButton") return end end""")
    assert not c.eval_py("return ns.SimBuffsUI._draft().cfg.raid.bloodlust")
    c.type_text(c.eval("return ns.SimBuffsUI._win().name"), "Pug SSC")
    c.eval("ns.SimBuffsUI:Save()")
    presets = c.eval_py("return ns.SimBuffs:GetPresets()")
    presets = presets if isinstance(presets, list) else list(presets.values())
    assert len(presets) == 1 and presets[0]["name"] == "Pug SSC", presets
    k = presets[0]["key"]
    assert c.eval("return ns.SimPanel:GetBuffs()") == k
    b = cfg(c, k)
    assert not b["raid"].get("bloodlust") and b["individual"].get("blessingOfKings") is True, b
    assert c.eval("return (ns.SimRunner:BuffName(...))", k) == "Pug SSC"
    # account-wide: stored outside the per-character sim settings
    assert c.eval("return type(ns.DB:GetSetting('sim.presets')) == 'table'") is True
    # the menu lists it with an edit hint that opens the editor
    c.eval("ns.SimBuffsUI:Close()  ns.UI:ContextMenu(ns.SimStage._frame().chip, function(root) ns.SimPanel:BuildSettingMenu(root, 'buffs') end)")
    texts = [e.get("text") for e in c.last_menu()["children"]]
    assert "Pug SSC" in texts, texts
    opened = c.eval("""local m = ns.UI:GetOpenMenu()
      if not m then return 'no menu' end
      for _, d in ipairs(m.root.children) do
        if d.text == "Pug SSC" and d.hint and d.hint.onClick then d.hint.onClick(d.data) return ns.SimBuffsUI:IsOpen() end
      end
      return 'no hint'""")
    if opened == "no menu":   # (the mock's own menus: call the hint from the observer's copy)
        opened = c.eval("ns.SimBuffsUI:Open(...) return ns.SimBuffsUI:IsOpen()", k)
    assert opened is True, opened
    # delete: the card falls back to 25-man
    c.eval("ns.SimBuffsUI:Delete()")
    assert not c.eval_py("return ns.SimBuffs:GetPresets()")
    assert c.eval("return ns.SimPanel:GetBuffs()") == "raid25"
    assert_no_lua_errors(w)


@r.case
def warrior_shouts_himself():
    w, c, tid, ln = world("WARRIOR", "Fury", 2)
    k = "t:%s:%s" % (tid, ln)
    b = cfg(c, k)
    assert "battleShout" not in b["party"], b["party"]       # stripped for a Warrior
    assert b["debuffs"].get("mangle") is True                 # the comp's open Feral (Cat) slot
    c.eval("local t, l = ... ns.SimBuffs:SaveTeamState(t, l, { open = false, ov = {} })", tid, ln)
    assert cfg(c, k)["debuffs"].get("mangle") is None
    c.eval("local t, l = ... ns.SimBuffs:SaveTeamState(t, l, { open = true, ov = {} })", tid, ln)
    c.eval("ns.SimBuffsUI:Open(...)", k)
    line = c.eval("""for _, f in ipairs(ns.SimBuffsUI._tiles()) do
        if f:IsShown() and f.tile.key == "battleshout" then f:Click() return f.sub:GetText() end end""")
    assert line == "you shout yourself", line
    assert not c.eval_py("return ns.SimBuffsUI._draft().st.ov")
    assert_no_lua_errors(w)


if __name__ == "__main__":
    r.run()
