"""ADDENDUM K: editing on the strategy board (the UX pass), on the real addon.

Covers: keyboard (Del, Ctrl+Z / Ctrl+Y, Ctrl+C / Ctrl+V, Ctrl+D, Ctrl+A, Ctrl+G, Esc, arrows; unused keys go on to the
game), groups (select / move / link as one), linking a drawing by Shift-dragging it onto a table cell, the names
under linked drawings, raid mark badges, table rows (insert / move / delete keep links on the same cells), dragging a
player cell onto the map, undo while assigning, and duplicating a block / copying it to other pages.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_edit.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, K, DAY, now, create, signup, save_council, strategies  # noqa: E402
from _common import case, run_all, strip_codes, menu_texts  # noqa: E402

BOSS = "BlackTemple:Council"
W = "_G.CDLootStrategyBoard"
CV = W + ".canvas"

HELPERS = r"""
function T_menu_prefix(prefix)
  local found
  local function strip(s)
    return ((s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("^%s+", ""))
  end
  local function walk(d)
    for _, c in ipairs(d.children) do
      if found then return end
      if strip(c.text):sub(1, #prefix) == prefix and (c.callback or c.setSelected) then found = c; return end
      walk(c)
    end
  end
  walk(__MOCK.last_menu)
  if not found then error("no menu entry starting with " .. prefix) end
  return __MOCK.menu_select(found.text, found.parent)
end
function T_key(key)
  local w = _G.CDLootStrategyBoard
  w:GetScript("OnKeyDown")(w, key)
end
function T_cell(ref)
  for _, b in ipairs(_G.CDLootStrategyBoard.blocks.blocks) do
    for _, c in ipairs(b.cells) do
      if c:IsShown() and (c.slotRef == ref or c.headRef == ref) then return c end
    end
  end
end
function T_elems() return ns.StrategyBoard:GetState().strat.p[ns.StrategyBoard:GetState().page].e end
"""


def setup():
    w, c = world()
    for x in c.values():
        x.eval(HELPERS)
    bob = c["Bob"]
    sid = save_council(bob)
    w.tick(1)
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    w.tick(0.2)
    return w, c, bob, sid


def elems(cl):
    return cl.eval_py("return T_elems()")


def select(cl, *idx, add=False):
    for n, i in enumerate(idx):
        cl.eval("local cv = %s; cv:Select(T_elems()[...], select(2, ...))" % CV, i, add or n > 0)


def key(cl, k, shift=False, ctrl=False, alt=False):
    cl.set_modifiers(shift, ctrl, alt)
    cl.eval("T_key(...)", k)
    cl.set_modifiers(False, False, False)


# ------------------------------------------------------------------------------------------------------------------
@case
def keyboard_delete_undo_redo_copy_paste():
    w, c, bob, sid = setup()
    n0 = len(elems(bob))
    assert bob.eval("return %s:IsKeyboardEnabled()" % W) is True
    select(bob, 4)                              # the skull icon
    key(bob, "DELETE")
    assert len(elems(bob)) == n0 - 1
    key(bob, "Z", ctrl=True)
    assert len(elems(bob)) == n0 and elems(bob)[3]["i"] == "rt8"
    key(bob, "Y", ctrl=True)
    assert len(elems(bob)) == n0 - 1
    key(bob, "Z", shift=True, ctrl=True)       # Ctrl+Shift+Z = redo: nothing left to redo
    key(bob, "Z", ctrl=True)
    assert len(elems(bob)) == n0
    # copy + paste: an offset copy, selected
    select(bob, 4)
    key(bob, "C", ctrl=True)
    key(bob, "V", ctrl=True)
    es = elems(bob)
    assert len(es) == n0 + 1 and es[-1]["i"] == "rt8" and es[-1]["x"] == es[3]["x"] + 20, es[-1]
    assert bob.eval("return %s:SelectionCount()" % CV) == 1
    key(bob, "D", ctrl=True)                    # duplicate the pasted one
    assert len(elems(bob)) == n0 + 2
    # arrows nudge the selection (Shift = 10)
    x0 = elems(bob)[-1]["x"]
    key(bob, "RIGHT", shift=True)
    assert elems(bob)[-1]["x"] == x0 + 10
    # Esc clears the selection; then the arrows go to the game (the propagate flag is set back)
    key(bob, "ESCAPE")
    assert bob.eval("return %s:SelectionCount()" % CV) == 0
    assert bob.eval("return ns.StrategyBoard:OnKey('LEFT')") is False
    assert bob.eval("return ns.StrategyBoard:OnKey('W')") is False
    # Ctrl+A selects everything, Del removes it all, one undo brings it all back
    key(bob, "A", ctrl=True)
    key(bob, "DELETE")
    assert elems(bob) == []
    key(bob, "Z", ctrl=True)
    assert len(elems(bob)) == n0 + 2
    # view mode: no keyboard
    bob.click(bob.eval("return %s.cancelBtn" % W))
    assert bob.eval("return %s:IsKeyboardEnabled()" % W) is False
    w.assert_no_errors()


@case
def groups_select_move_and_link_as_one():
    w, c, bob, sid = setup()
    # two icons: a tank role icon and a mage class icon, next to each other
    bob.eval("local cv = %s; cv:Place({ t = 'i', x = 600, y = 300, i = 'role:tank', z = 32 });"
             " cv:Place({ t = 'i', x = 640, y = 300, i = 'cls:MAGE', z = 32 })" % CV)
    n = len(elems(bob))
    select(bob, n - 1, n)
    key(bob, "G", ctrl=True)
    es = elems(bob)
    assert es[-1]["g"] and es[-1]["g"] == es[-2]["g"], es[-2:]
    # clicking one selects the group
    bob.eval("%s:ClearSelection(); %s:Select(T_elems()[%d])" % (CV, CV, n))
    assert bob.eval("return %s:SelectionCount()" % CV) == 2
    # moving: both move
    key(bob, "DOWN", shift=True)
    es = elems(bob)
    assert es[-1]["y"] == 310 and es[-2]["y"] == 310
    # Shift-drag onto a table cell: the whole group links to that slot
    bob.eval("local c = T_cell('tk.2.1'); c.IsMouseOver = function() return true end")
    bob.eval("local cv = %s; local e = T_elems()[%d]; cv.drag = { mode = 'link', el = e }; cv:OnMouseUp('LeftButton')" % (CV, n))
    bob.eval("local c = T_cell('tk.2.1'); c.IsMouseOver = nil")
    es = elems(bob)
    assert es[-1]["ln"] == "tk.2.1" and es[-2]["ln"] == "tk.2.1", es[-2:]
    # editing: the link shows under the group once
    texts = [strip_codes(t) for t in bob.eval_py("local out = {}; for _, o in ipairs(%s.pools.link) do "
                                                 "if o.fs:IsShown() then out[#out + 1] = o.fs:GetText() end end; "
                                                 "return out" % CV)]
    assert texts.count("-> Tanks · Veras · Player") == 1, texts
    # hovering the slot lights both icons
    bob.eval("%s.blocks.opts.onHover('tk.2.1')" % W)
    assert bob.eval("local cv = %s; local e = T_elems(); return cv.lit[e[#e]] and cv.lit[e[#e - 1]] and true" % CV) is True
    # ungroup
    key(bob, "G", shift=True, ctrl=True)
    assert "g" not in elems(bob)[-1]
    # save, then in a raid the assigned tank's name is under them
    bob.click(bob.eval("return %s.saveBtn" % W))
    occ = create(bob, i="bt", t=now(bob) + DAY)
    w.tick(1)
    bob.eval("local o, b, s = ...; ns.Strategy:SaveFill(o, b, s, { ['tk.2.1'] = 'Lee-Thunderstrike' })", occ, BOSS, sid)
    w.tick(1)
    bob.eval("ns.StrategyBoard:OpenRaid(...)", occ, BOSS)
    texts = [strip_codes(t) for t in bob.eval_py("local out = {}; for _, o in ipairs(%s.pools.link) do "
                                                 "if o.fs:IsShown() then out[#out + 1] = o.fs:GetText() end end; "
                                                 "return out" % CV)]
    assert "Lee" in texts, texts
    w.assert_no_errors()


@case
def raid_mark_badge_and_add_here_menu():
    w, c, bob, sid = setup()
    # right-click empty map: Add here > Icon > This boss > Veras
    bob.eval("local cv = %s; cv:BackgroundMenu(500, 100)" % CV)
    texts = [strip_codes(t[2]) for t in menu_texts(bob.last_menu()) if t[2]]
    assert texts[0] == "Add here" and "This boss: The Illidari Council" in texts, texts
    bob.eval("T_menu_prefix('Veras Darkshadow')")
    e = elems(bob)[-1]
    assert e["i"] == "boss:21418" and e["x"] == 500 and e["y"] == 100 and e["l"] == "Veras Darkshadow", e
    # right-click it: Raid mark > Cross
    bob.eval("local cv = %s; local e = T_elems(); cv:Select(e[#e]); cv:ElementMenu(e[#e])" % CV)
    bob.eval("T_menu_prefix('Cross')")
    assert elems(bob)[-1]["rm"] == 7
    badge = bob.eval_py("for _, o in ipairs(%s.pools.icon) do if o.badge and o.badge:IsShown() then "
                        "return o.badge:GetTexture() end end" % CV)
    assert badge == "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7", badge
    # it survives saving
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(2)
    assert strategies(c["Sam"], BOSS)[0]["p"][0]["e"][-1]["rm"] == 7
    w.assert_no_errors()


@case
def rows_keep_links_and_cells_drop_on_the_map():
    w, c, bob, sid = setup()
    blocks = W + ".blocks"
    # the zone linked to Zones column 1, the token showing Tanks row 1; the misdirect targets show Tanks rows 1 / 2
    bob.eval("T_elems()[2].ln = 'zn.1.1'")
    # insert a row above Tanks row 1: every reference to the tanks moves down one row
    bob.eval("local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'tk'); %s:InsertRow(k, 1)" % blocks)
    st = bob.eval_py("return ns.StrategyBoard:GetState().strat")
    assert bob.eval("return ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'tk').r") == 3
    assert bob.eval("return ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'tk').d[2][2].l") == "Gathios"
    assert st["p"][0]["e"][5]["r"] == "tk.2.1", st["p"][0]["e"][5]
    assert st["p"][1]["e"][0]["r"] == "tk.3.1"
    targets = bob.eval_py("local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'md');"
                          " return { k.d[1][3].s, k.d[2][3].s }")
    assert targets == ["tk.2.1", "tk.3.1"], targets
    # delete that new (empty) row again: back to the old refs; deleting a linked row drops the links / markers
    bob.eval("local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'tk'); %s:DeleteRow(k, 1)" % blocks)
    assert bob.eval("return T_elems()[6].r") == "tk.1.1"
    bob.eval("local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'tk'); %s:DeleteRow(k, 1)" % blocks)
    assert not any(e.get("r") == "tk.1.1" for e in elems(bob))
    # undo brings the row and the marker back
    key(bob, "Z", ctrl=True)
    assert bob.eval("return T_elems()[6].r") == "tk.1.1"
    # the + row button adds one at the end
    bob.eval("for _, b in ipairs(%s.blocks) do if b.blockId == 'zn' then b.addRow:Click() end end" % blocks)
    assert bob.eval("return ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'zn').r") == 4
    # the row menu (right-click a cell)
    bob.click(bob.eval("return T_cell('zn.4.1')"), "RightButton")
    texts = [strip_codes(t[2]) for t in menu_texts(bob.last_menu()) if t[2]]
    assert "Insert a row above" in texts and "Delete row" in texts, texts
    # drag a player cell onto empty map: a name marker; onto a drawing: links it
    n = len(elems(bob))
    bob.eval("local cv = %s; cv.frame.IsMouseOver = function() return true end; cv.Cursor = function() return 900, 600 end" % CV)
    bob.eval("%s.opts.onCellDrop('zn.2.2')" % blocks)
    es = elems(bob)
    assert len(es) == n + 1 and es[-1]["t"] == "s" and es[-1]["r"] == "zn.2.2", es[-1]
    bob.eval("local cv = %s; cv.Cursor = function() return 700, 300 end" % CV)       # the skull icon
    bob.eval("%s.opts.onCellDrop('zn.3.1')" % blocks)
    assert elems(bob)[3]["ln"] == "zn.3.1"
    w.assert_no_errors()


@case
def undo_while_assigning():
    w, c, bob, sid = setup()
    bob.click(bob.eval("return %s.cancelBtn" % W))
    occ = create(bob, i="bt", t=now(bob) + DAY)
    w.tick(1)
    signup(c["Lee"], occ, "A", 3)
    w.tick(1)
    bob.eval("ns.StrategyBoard:OpenRaid(...)", occ, BOSS, "fill")
    bob.eval("ns.StrategyBoard:Assign('zn.1.1', 'Lee-Thunderstrike')")
    bob.eval("ns.StrategyBoard:Assign('zn.1.2', 'Lee-Thunderstrike')")
    key(bob, "Z", ctrl=True)
    a = bob.eval_py("return ns.StrategyBoard:GetState().assign")
    assert a == {"zn.1.1": K("Lee")}, a
    key(bob, "Y", ctrl=True)
    assert len(bob.eval_py("return ns.StrategyBoard:GetState().assign")) == 2
    w.assert_no_errors()


@case
def stacking_follows_bring_to_front_and_send_to_back():
    w, c, bob, sid = setup()
    # two overlapping icons; each drawing's frame level is its place in the stack
    bob.eval("local cv = %s; cv:Place({ t = 'i', x = 400, y = 400, i = 'rt1', z = 48 });"
             " cv:Place({ t = 'i', x = 410, y = 405, i = 'rt2', z = 48 })" % CV)

    def levels():
        return bob.eval_py("local r = {}; for _, o in ipairs(%s.pools.icon) do if o.holder:IsShown() then "
                           "r[o.tex:GetTexture():sub(-1)] = o.holder:GetFrameLevel() end end; return r" % CV)
    lv = levels()
    assert lv["2"] > lv["1"] > lv["8"], lv            # page order: skull (rt8) first, star, then circle
    # Send the circle (rt2) to the back: under the other icons
    bob.eval("local cv = %s; local e = T_elems(); cv:Select(e[#e]); cv:Reorder({ e[#e] }, false)" % CV)
    lv = levels()
    assert lv["2"] < lv["1"] and lv["2"] < lv["8"], lv
    # Bring the skull to the front
    bob.eval("local cv = %s; for _, e in ipairs(T_elems()) do if e.i == 'rt8' then cv:Reorder({ e }, true) end end" % CV)
    lv = levels()
    assert lv["8"] > lv["1"] > lv["2"], lv
    # zones stay under icons whatever their order; selection boxes sit above everything
    zone = bob.eval("for _, o in ipairs(%s.pools.zone) do if o.holder:IsShown() then return o.holder:GetFrameLevel() end end" % CV)
    assert zone < min(lv.values())
    assert bob.eval("return %s.top:GetFrameLevel()" % CV) > max(lv.values())
    w.assert_no_errors()


@case
def dropping_a_portrait_on_a_target_cell():
    w, c, bob, sid = setup()
    # Veras' portrait on the map, Shift-dragged onto the Tanks block's Target cell of row 2
    bob.eval("local cv = %s; cv:Place({ t = 'i', x = 300, y = 500, i = 'boss:21418', z = 48, l = 'Veras Darkshadow' })" % CV)
    n = len(elems(bob))
    bob.eval("for _, b in ipairs(%s.blocks.blocks) do for _, c in ipairs(b.cells) do "
             "if c.targetInfo and c.targetInfo.k.id == 'tk' and c.targetInfo.row == 2 then "
             "c.IsMouseOver = function() return true end end end end" % W)
    bob.eval("local cv = %s; local e = T_elems()[%d]; cv.drag = { mode = 'link', el = e }; cv:OnMouseUp('LeftButton')" % (CV, n))
    cell = bob.eval_py("return ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'tk').d[2][2]")
    assert cell == {"i": "boss:21418", "l": "Veras Darkshadow"}, cell
    # the portrait now shows the tank of that row
    assert elems(bob)[n - 1]["ln"] == "tk.2.1"
    # one undo takes back both the cell and the link
    key(bob, "Z", ctrl=True)
    assert bob.eval("return ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'tk').d[2][2].l") == "Veras"
    assert "ln" not in elems(bob)[n - 1]
    w.assert_no_errors()


@case
def portrait_names_come_from_the_encounter():
    w, c, bob, sid = setup()
    # two encounters listing the same model: the name is the one of the encounter being built
    bob.eval("ns.Data.BossPortraits['T:A'] = { { d = 99, n = 'First' } }; ns.Data.BossPortraits['T:B'] = { { d = 99, n = 'Second' } }")
    assert bob.eval("return ns.StrategyMapUI:PortraitName(99, 'T:B')") == "Second"
    assert bob.eval("return ns.StrategyMapUI:PortraitName(99, 'T:A')") == "First"
    # every creature of an encounter has its own model
    dup = bob.eval_py("local out = {}; for ref, list in pairs(ns.Data.BossPortraits) do local seen = {}; "
                      "for _, c in ipairs(list) do if seen[c.d] then out[#out + 1] = ref .. ':' .. c.n end; "
                      "seen[c.d] = true end end; return out")
    assert dup == [], dup
    w.assert_no_errors()


@case
def duplicate_a_block_and_copy_it_to_another_page():
    w, c, bob, sid = setup()
    blocks = W + ".blocks"
    st = "ns.StrategyBoard:GetState().strat"
    # a tank cell showing another tank row of the same block: the copies show their own row
    bob.eval("ns.Strategy:FindBlock(%s, 'tk').d[1][2].s = 'tk.2.1'" % st)
    # Duplicate (block menu): right after the original, "(copy)", a new id, same cells
    bob.eval("local p = %s.p[1]; %s:BlockMenu(nil, p, p.k[2], 2)" % (st, blocks))
    bob.eval("T_menu_prefix('Duplicate')")
    k = bob.eval_py("local p = %s.p[1]; local out = {}; for _, k in ipairs(p.k) do out[#out + 1] = k.id .. '=' .. k.n "
                    "end; return out" % st)
    assert k[:3] == ["tk=Tanks", "md=Misdirects", "k1=Misdirects (copy)"], k
    assert bob.eval("return ns.Strategy:FindBlock(%s, 'k1').d[2][3].s" % st) == "tk.2.1"
    # Copy to page: the tanks onto P2, same title, its own slots
    bob.eval("local p = %s.p[1]; %s:BlockMenu(nil, p, p.k[1], 1)" % (st, blocks))
    assert "All other pages" in [strip_codes(t[2]) for t in menu_texts(bob.last_menu()) if t[2]]
    bob.eval("T_menu_prefix('2. P2')")
    k2 = bob.eval_py("local k = %s.p[2].k[1]; return { id = k.id, n = k.n, r = k.r, s = k.d[1][2].s, "
                     "l = k.d[2][2].l }" % st)
    assert k2 == {"id": "k2", "n": "Tanks", "r": 2, "s": "k2.2.1", "l": "Veras"}, k2
    # undo takes the copy back; redo puts it again; the strategy saves
    key(bob, "Z", ctrl=True)
    assert bob.eval("return #%s.p[2].k" % st) == 0
    key(bob, "Y", ctrl=True)
    assert bob.eval("return #%s.p[2].k" % st) == 1
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(2)
    ss = strategies(c["Rita"], BOSS)
    assert len(ss) == 1 and len(ss[0]["p"][0]["k"]) == 5 and ss[0]["p"][1]["k"][0]["id"] == "k2", ss
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
