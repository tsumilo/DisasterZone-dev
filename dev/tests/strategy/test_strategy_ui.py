"""ADDENDUM K: strategy board UI (Raids > Strategies, the board window, a raid's Assignments tab), on the real addon.

Covers: the Strategies view (authors vs members), building a strategy in the board (new through the prompt, the
instance map as background, a block from a template, a zone linked to a column, pages, Save reaching everyone), the
raid's Assignments tab, filling (Suggest fill, a slot's player menu, click-to-place from the pool, Save), raiders seeing
their jobs and slot tokens with names, carry over to next week's raid, and the unsaved-changes guard.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_ui.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, K, DAY, now, create, signup, save_council, strategies, get_fill  # noqa: E402
from _common import case, run_all, strip_codes, menu_texts  # noqa: E402

BOSS = "BlackTemple:Council"
P = "ns.RaidsUI:GetPanel()"
W = "_G.DisasterZoneStrategyBoard"

HELPERS = r"""
function T_menu_prefix(prefix)
  local found
  local function strip(s) return (s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "") end
  local function walk(d)
    for _, c in ipairs(d.children) do
      if found then return end
      local t = strip(c.text)
      if t:sub(1, #prefix) == prefix and (c.callback or c.setSelected) then found = c; return end
      walk(c)
    end
  end
  walk(__MOCK.last_menu)
  if not found then error("no menu entry starting with " .. prefix) end
  return __MOCK.menu_select(found.text, found.parent)
end
function T_cell(ref)
  for _, b in ipairs(_G.DisasterZoneStrategyBoard.blocks.blocks) do
    for _, c in ipairs(b.cells) do
      if c:IsShown() and c.slotRef == ref then return c end
    end
  end
end
"""


def names():
    return (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"),
            ("Sam", 3, "ROGUE"), ("Hana", 3, "HUNTER"), ("Hugo", 3, "HUNTER"))


def setup():
    w, c = world(names())
    for x in c.values():
        x.eval(HELPERS)
    return w, c


def shown(cl, expr):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr) is True


def board(cl):
    return cl.eval_py("local s = ns.StrategyBoard:GetState(); return { mode = s.mode, occ = s.occ, boss = s.boss, "
                      "page = s.page, dirty = s.dirty, assign = s.assign, name = s.strat and s.strat.n, "
                      "id = s.strat and s.strat.id }")


def open_strategies(w, cl):
    cl.slash("/dz raids")
    w.tick(0.5)
    cl.eval("ns.RaidsUI:SetView('strategies')")
    w.tick(0.5)
    assert shown(cl, P + ".strategies")


def prompt_answer(w, cl, text):
    assert shown(cl, "_G.DisasterZoneStrategyPrompt")
    cl.type_text(cl.eval("return _G.DisasterZoneStrategyPrompt.edit"), text, enter=True)
    w.tick(0.3)


# ------------------------------------------------------------------------------------------------------------------
@case
def author_builds_a_strategy_in_the_board():
    w, c = setup()
    bob, rita = c["Bob"], c["Rita"]
    open_strategies(w, rita)
    rita.eval("ns.StrategiesUI:SelectBoss(...)", BOSS)
    assert shown(rita, P + ".strategies.detail.newBtn")      # 1.0: every member builds strategies
    assert rita.find_text("No strategy for this boss yet", True, True)
    open_strategies(w, bob)
    bob.eval("ns.StrategiesUI:SelectBoss(...)", BOSS)
    assert shown(bob, P + ".strategies.detail.newBtn")
    bob.click(bob.eval("return %s.strategies.detail.newBtn" % P))
    w.tick(0.2)
    prompt_answer(w, bob, "25 farm")
    st = board(bob)
    assert st["mode"] == "edit" and st["name"] == "25 farm" and st["boss"] == BOSS and st["dirty"], st
    assert shown(bob, W)
    # the Council's floor of Black Temple (a map shipped with DisasterZone) is the background: its two textures
    m = bob.eval("return ns.StrategyBoard:GetState().strat.p[1].m")
    assert bob.eval("for _, x in ipairs(ns.Data.RaidMaps) do if x.id == ... then return x.file end end", m) == "BT06"
    tiles = bob.eval_py("local out = {}; for _, t in ipairs(%s.canvas.tiles) do if t:IsShown() then "
                        "out[#out + 1] = t:GetTexture() end end; return out" % W)
    assert tiles == [r"Interface\AddOns\DisasterZone\Media\Maps\BT06_a", r"Interface\AddOns\DisasterZone\Media\Maps\BT06_b"], tiles
    assert bob.find_text("Black Temple - Chamber of Command", True, True)
    # it starts from the Council's starter: the room framed, the four council members where they stand
    st = bob.eval_py("local p = ns.StrategyBoard:GetState().strat.p[1]; local out = { vz = p.vz, i = {} }; "
                     "for _, e in ipairs(p.e) do out.i[#out.i + 1] = e.i end; return out")
    assert st["vz"] == 360 and len(st["i"]) == 4 and all(i.startswith("boss:") for i in st["i"]), st
    # (the drawing checks below start from an empty map)
    bob.eval("wipe(ns.StrategyBoard:GetState().strat.p[1].e); ns.StrategyBoard:Refresh()")
    # a client floor with map art still draws from its 12 tiles
    bob.eval("local p = ns.StrategyBoard:GetState().strat.p[1]; p.m = 339; ns.StrategyBoard:Refresh()")
    assert bob.eval("local n = 0; for _, t in ipairs(%s.canvas.tiles) do if t:IsShown() then n = n + 1 end end; return n" % W) == 12
    bob.eval("local p = ns.StrategyBoard:GetState().strat.p[1]; p.m = ...; ns.StrategyBoard:Refresh()", m)
    # a block from a template
    bob.click(bob.eval("return %s.blocks.addBtn" % W))
    bob.eval("T_menu_prefix('Players with targets')")
    w.tick(0.2)
    k = bob.eval_py("return ns.StrategyBoard:GetState().strat.p[1].k[1]")
    assert k["n"] == "Assignments" and k["r"] == 4 and [x["t"] for x in k["c"]] == ["p", "g"], k
    assert bob.eval("return T_cell('k1.1.1') ~= nil") is True
    # a zone, then linked to the block's player column from its menu
    bob.eval("local cv = %s.canvas; local e = cv:Add({ t = 'z', s = 'c', x = 300, y = 300, w = 100, h = 100, c = 2 });"
             " cv:Changed(); cv:Select(e); cv:ElementMenu(e)" % W)
    bob.eval("T_menu_prefix('Column: Player')")
    w.tick(0.2)
    assert bob.eval("return ns.StrategyBoard:GetState().strat.p[1].e[1].ln") == "k1.1"
    # hovering the column lights the zone
    bob.eval("%s.blocks.opts.onHover('k1.1')" % W)
    assert bob.eval("local cv = %s.canvas; return cv.lit ~= nil and cv.lit[cv.page.e[1]] == true" % W) is True
    # a second page
    bob.click(bob.eval("return %s.addPage" % W))
    w.tick(0.2)
    assert board(bob)["page"] == 2
    assert bob.eval("return #ns.StrategyBoard:GetState().strat.p") == 2
    # Save: view mode, and everyone has it
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(2)
    st = board(bob)
    assert st["mode"] == "view" and not st["dirty"] and st["id"], st
    for n in ("Rita", "Sam", "Gina"):
        ss = strategies(c[n], BOSS)
        assert len(ss) == 1 and ss[0]["n"] == "25 farm" and ss[0]["p"][0]["e"][0]["ln"] == "k1.1", (n, ss)
    rita.eval("ns.StrategiesUI:RefreshLibrary()")
    assert rita.find_text("25 farm", True, True)
    w.assert_no_errors()


@case
def raid_leader_fills_and_raiders_see_their_jobs():
    w, c = setup()
    bob, rita, hana = c["Bob"], c["Rita"], c["Hana"]
    sid = save_council(bob)
    occ = create(bob, i="bt", t=now(bob) + DAY)
    w.tick(2)
    signup(c["Hana"], occ, "A")
    signup(c["Hugo"], occ, "A")
    signup(c["Lee"], occ, "A", 3)      # Protection
    signup(c["Gina"], occ, "A", 2)     # Protection
    w.tick(2)
    # a member sees the raid's Assignments tab (no Assign button)
    rita.slash("/dz raids")
    w.tick(0.5)
    rita.eval("ns.RaidPlanUI:SelectRaid(...); ns.RaidPlanUI:SetDetailTab('assign')", occ)
    w.tick(0.3)
    assert rita.find_text("0 / 10 slots filled", True, True)
    assert rita.find_text("The Illidari Council", True, True)
    # the raid leader assigns
    bob.eval("ns.StrategyBoard:OpenRaid(...)", occ, BOSS, "fill")
    w.tick(0.3)
    st = board(bob)
    assert st["mode"] == "fill" and st["id"] == sid, st
    assert bob.eval("local n = 0; for _, ch in ipairs(%s.pool.chips) do if ch:IsShown() then n = n + 1 end end; return n" % W) == 4
    bob.click(bob.eval("return %s.pool.suggestBtn" % W))
    a = board(bob)["assign"]
    assert {a["tk.1.1"], a["tk.2.1"]} == {K("Lee"), K("Gina")}, a
    assert {a["md.1.2"], a["md.2.2"]} == {K("Hana"), K("Hugo")}, a
    # an open zone slot: its menu lists the raid's players
    bob.click(bob.eval("return T_cell('zn.1.1')"))
    texts = [strip_codes(t[2]) for t in menu_texts(bob.last_menu()) if t[2]]
    assert "Sam" not in texts and "Hana  (1)" in texts, texts
    bob.eval("T_menu_prefix('Hana')")
    # click-to-place: pick Lee in the pool, then click a slot
    bob.eval("for _, ch in ipairs(%s.pool.chips) do if ch.key == ... then ch:Click() end end" % W, K("Lee"))
    bob.click(bob.eval("return T_cell('zn.1.2')"))
    a = board(bob)["assign"]
    assert a["zn.1.1"] == K("Hana") and a["zn.1.2"] == K("Lee"), a
    # right-click clears
    bob.click(bob.eval("return T_cell('zn.1.2')"), "RightButton")
    assert "zn.1.2" not in board(bob)["assign"]
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(2)
    assert board(bob)["mode"] == "view"
    f = get_fill(rita, occ, BOSS)
    assert f["s"] == sid and f["a"]["zn.1.1"] == K("Hana") and len(f["a"]) == 5, f
    # the member's tab counts it
    rita.eval("ns.RaidPlanUI:RefreshUpcoming()")
    assert rita.find_text("5 / 10 slots filled", True, True)
    # Hana opens the board: her jobs, and the slot token shows the tank's name
    hana.eval("ns.StrategyBoard:OpenRaid(...)", occ, BOSS)
    w.tick(0.3)
    mine = strip_codes(hana.eval("return %s.view.mine:GetText()" % W))
    assert "Misdirects" in mine and "Zones · #1 · Zone 1" in mine, mine
    tank = strip_codes(hana.eval("return ns.StrategyBoard:SlotTokenText('tk.1.1')"))
    assert tank in ("Lee", "Gina"), tank
    assert not shown(hana, W + ".fillBtn") and not shown(hana, W + ".editBtn")
    # next week: carry over
    occ2 = create(bob, i="bt", t=now(bob) + 8 * DAY)
    w.tick(2)
    bob.eval("ns.StrategyBoard:OpenRaid(...)", occ2, BOSS, "fill")
    w.tick(0.3)
    assert board(bob)["assign"] == {}
    bob.click(bob.eval("return %s.pool.carryBtn" % W))
    a = board(bob)["assign"]
    assert a == f["a"], a
    # nobody signed up for that raid: the carried names show as missing (red)
    assert "ff5050" in bob.eval("return T_cell('zn.1.1').fs:GetText()")
    w.assert_no_errors()


@case
def unsaved_changes_are_guarded():
    w, c = setup()
    bob = c["Bob"]
    sid = save_council(bob)
    w.tick(1)
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    w.tick(0.2)
    bob.eval("local s = ns.StrategyBoard:GetState(); s.strat.n = 'Changed'; ns.StrategyBoard:MarkDirty()")
    bob.eval("ns.StrategyBoard:NewStrategy('BlackTemple:Illidan', 'Other')")
    w.tick(0.2)
    # nothing is asked and nothing dropped: the unsaved changes stay behind as a draft
    assert "DISASTERZONE_PLAN_CONFIRM" not in bob.popups()
    assert board(bob)["name"] == "Other"
    names = sorted(d["n"] for d in bob.eval_py("return ns.StrategyBoard:GetDrafts()"))
    assert names == ["Changed", "Other"], names
    # editing the strategy again goes on with its draft
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    st = board(bob)
    assert st["name"] == "Changed" and st["dirty"] and st["mode"] == "edit", st
    # closing keeps it on the board; opening the same strategy shows it again
    bob.eval("ns.StrategyBoard:Close()")
    bob.eval("ns.StrategyBoard:OpenStrategy(...)", sid)
    st = board(bob)
    assert st["name"] == "Changed" and st["dirty"] and st["mode"] == "edit", st
    # Cancel drops it
    bob.click(bob.eval("return %s.cancelBtn" % W))
    st = board(bob)
    assert st["name"] == "25 farm" and not st["dirty"] and st["mode"] == "view", st
    w.assert_no_errors()


@case
def members_view_only():
    w, c = setup()
    bob, sam = c["Bob"], c["Sam"]
    sid = save_council(bob)
    w.tick(2)
    sam.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    w.tick(0.2)
    assert board(sam)["mode"] == "view"
    assert not shown(sam, W + ".editBtn") and not shown(sam, W + ".saveBtn")
    assert not shown(sam, W + ".tools")
    # page 2 shows its notes; the tabs switch pages
    sam.eval("ns.StrategyBoard:GetState().page = 2; ns.StrategyBoard:Refresh()")
    assert sam.find_text("Dampen magic pre-pull", True, True)
    # a member's own strategy: a new one, or a copy of someone's
    sam.eval("ns.StrategyBoard:NewStrategy(...)", BOSS)
    st = board(sam)
    assert st["mode"] == "edit" and st.get("id") is None, st
    w.assert_no_errors()


@case
def boss_portraits_icon_resize_and_map_fallback():
    w, c = setup()
    bob = c["Bob"]
    # a floor the client names differently still counts through the raid's known map ids
    bob.eval("__MOCK.dungeon_maps[342] = { name = 'Den of Mortal Delights', floor = 'x', group = 2 }")
    names = bob.eval_py("local out = {}; for _, m in ipairs(ns.StrategyMapUI:MapsFor('BlackTemple:Council')) do "
                        "out[#out + 1] = m.shipped and m.name or m.id end; return out")
    assert names[:8] == ["Black Temple - Illidari Training Grounds", "Black Temple - Karabor Sewers",
                         "Black Temple - Sanctuary of Shadows", "Black Temple - Halls of Anguish",
                         "Black Temple - Gorefiend's Vigil", "Black Temple - Den of Mortal Delights",
                         "Black Temple - Chamber of Command", "Black Temple - Temple Summit"], names
    assert names[8:] == [339, 340, 341, 342], names
    assert len(bob.eval_py("return ns.StrategyMapUI:MapsFor('Karazhan:Attumen')")) == 17

    def default(boss):
        return bob.eval("return ns.StrategyMapUI:MapName(ns.StrategyMapUI:DefaultMap(...))", boss)
    assert default("Karazhan:Attumen") == "Karazhan - Servants' Quarters"
    assert default("Karazhan:Prince") == "Karazhan - Netherspace"
    assert default("BlackTemple:Illidan") == "Black Temple - Temple Summit"
    assert default("SunwellPlateau:Muru") == "Sunwell Plateau - Shrine of the Eclipse"
    assert default("SunwellPlateau:Kalecgos") == "Sunwell Plateau"
    # a page saved with an Atlas map of the first test builds shows the floor that replaced it
    assert bob.eval("return ns.StrategyMapUI:MapName(900010)") == "Black Temple - Chamber of Command"
    bob.eval("ns.StrategyBoard:NewStrategy(...)", BOSS, "Portraits")
    w.tick(0.2)
    bob.eval("wipe(ns.StrategyBoard:GetState().strat.p[1].e); ns.StrategyBoard:Refresh()")   # past the starter
    # the icon menu offers this encounter's portraits only
    bob.eval("local cv = %s.canvas; cv:SetTool('icon'); cv:OnMouseDown('LeftButton')" % W)
    texts = [strip_codes(t[2]) for t in menu_texts(bob.last_menu()) if t[2]]
    assert "This boss: The Illidari Council" in texts, texts
    i = texts.index("This boss: The Illidari Council")
    assert texts[i + 1:i + 5] == ["Gathios the Shatterer", "High Nethermancer Zerevor", "Lady Malande",
                                  "Veras Darkshadow"], texts
    assert not any("Illidan" in t or "Akama" in t for t in texts)
    bob.eval("T_menu_prefix('High Nethermancer Zerevor')")
    e = bob.eval_py("return ns.StrategyBoard:GetState().strat.p[1].e[1]")
    assert e["t"] == "i" and e["i"] == "boss:21417" and e["z"] == 48 and e["l"] == "High Nethermancer Zerevor", e
    assert bob.eval("for _, o in ipairs(%s.canvas.pools.icon) do if o.tex:IsShown() then return o.tex:GetTexture() end end" % W) \
        == "portrait:21417"
    # the selected icon has a resize handle at its corner
    assert bob.eval("local cv = %s.canvas; local e = cv.page.e[1]; return cv:HandleAt(e.x + 24, e.y + 24)" % W) == "isize"
    # multi-creature encounters list the adds too (Attumen rides Midnight)
    att = bob.eval_py("local out = {}; for _, c in ipairs(ns.StrategyMapUI:BossPortraits('Karazhan:Attumen')) do "
                      "out[#out + 1] = c.n end; return out")
    assert att == ["Attumen the Huntsman", "Midnight"], att
    assert bob.eval_py("return ns.StrategyMapUI:BossPortraits('Karazhan:Trash')") == []
    # the portrait survives validation and saving
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(2)
    assert strategies(c["Sam"], BOSS)[0]["p"][0]["e"][0]["i"] == "boss:21417"
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
