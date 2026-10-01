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


@case
def empty_page_cards_and_link_pills():
    """A new strategy for Magtheridon: the empty jobs panel suggests a block per creature on the map (the five
    channelers as one block of 5 rows, numbered clockwise, each row linked to its icon), and template cards; a
    target cell that shows a slot's player has the link as a pill, in short."""
    w, c, bob, sid = setup()
    bob.click(bob.eval("return %s.cancelBtn" % W))
    bob.eval("ns.StrategyBoard:NewStrategy('MagtheridonsLair:Magtheridon', 'Cubes')")
    w.tick(0.2)
    blocks = W + ".blocks"
    cards = bob.eval_py("local out = {}; for _, cd in ipairs(%s.cards) do if cd:IsShown() then "
                        "out[#out + 1] = cd.title:GetText() end end; return out" % blocks)
    assert cards[0] == "Tanks on Magtheridon" and cards[1] == "Hellfire Channeler  x5", cards
    assert len(cards) == 2 + 6, cards        # + the templates
    assert bob.eval("return %s.addBtn:IsShown()" % blocks) is False
    bob.click(bob.eval("return %s.cards[2]" % blocks))
    st = "ns.StrategyBoard:GetState().strat"
    k = bob.eval_py("local k = %s.p[1].k[1]; return { n = k.n, r = k.r, l1 = k.d[1][2].l, l5 = k.d[5][2].l, "
                    "i = k.d[3][2].i }" % st)
    assert k["n"] == "Hellfire Channeler" and k["r"] == 5 and k["l1"] == "Hellfire Channeler 1"         and k["l5"] == "Hellfire Channeler 5" and k["i"].startswith("boss:"), k
    links = sorted(e["ln"] for e in elems(bob) if e.get("ln"))
    assert len(links) == 5 and links[0].endswith(".1.1") and all(l.startswith(k and "k") for l in links), links
    # the cards give way to the block; + Add block is back
    assert bob.eval("return %s.cards[1]:IsShown()" % blocks) is False
    assert bob.eval("return %s.addBtn:IsShown()" % blocks) is True
    # a target cell showing another row's player: the link is a short pill ("-> #2"), the label stays
    bob.eval("local k = %s.p[1].k[1]; k.d[1][2].s = k.id .. '.2.1'; ns.StrategyBoard:MarkDirty(true)" % st)
    cell = bob.eval("for _, b in ipairs(%s.blocks) do for _, x in ipairs(b.cells) do "
                    "if x:IsShown() and x.targetInfo and x.targetInfo.row == 1 then return x end end end" % blocks)
    assert strip_codes(bob.eval("local c = ...; return c.pill.fs:GetText()", cell)) == "-> #2"
    assert bob.eval("local c = ...; return c.pill:IsShown()", cell) is True
    w.assert_no_errors()


@case
def text_resizes_at_its_corner():
    w, c, bob, sid = setup()
    # the text of the Council fixture: 'Major Nature Protection Potion' at 800, 500, normal size
    select(bob, 5)
    e = elems(bob)[4]
    assert e["t"] == "x" and e["z"] == 2, e
    box = bob.eval_py("local e = T_elems()[5]; return { w = e._w, h = e._h }")
    hx, hy = e["x"] + box["w"] / 2, e["y"] + box["h"] / 2
    assert bob.eval("return %s:HandleAt(...)" % CV, hx, hy) == "xsize"
    assert bob.eval("return %s:HandleAt(...)" % CV, e["x"], e["y"]) is None

    def drag(x, y, shift=False):
        bob.eval("local cv, x, y = %s, ...; cv.Cursor = function() return x, y end; "
                 "_G.IsMouseButtonDown = function() return true end" % CV, hx, hy)
        bob.eval("%s:OnMouseDown('LeftButton')" % CV)
        bob.set_modifiers(shift, False, False)
        bob.eval("local cv, x, y = %s, ...; cv.Cursor = function() return x, y end; cv:OnDragUpdate()" % CV, x, y)
        bob.eval("_G.IsMouseButtonDown = function() return false end; %s:OnMouseUp('LeftButton'); %s.Cursor = nil"
                 % (CV, CV))
        bob.set_modifiers(False, False, False)

    # twice as far from the centre: twice the size (13 -> 26); no box width of its own
    drag(e["x"] + box["w"], e["y"] + box["h"])
    e2 = elems(bob)[4]
    assert e2["z"] == 26 and "w" not in e2, e2
    # far away: capped; back with one undo
    box = bob.eval_py("local e = T_elems()[5]; return { w = e._w, h = e._h }")
    hx, hy = e["x"] + box["w"] / 2, e["y"] + box["h"] / 2
    drag(e["x"] + 5000, e["y"])
    assert elems(bob)[4]["z"] == 48
    key(bob, "Z", ctrl=True)
    assert elems(bob)[4]["z"] == 26
    # Shift: the width of the box, the size stays
    select(bob, 5)
    box = bob.eval_py("local e = T_elems()[5]; return { w = e._w, h = e._h }")
    hx, hy = e["x"] + box["w"] / 2, e["y"] + box["h"] / 2
    drag(e["x"] + 60, hy, shift=True)
    e3 = elems(bob)[4]
    assert e3["z"] == 26 and e3["w"] == 120, e3
    bw = bob.eval("return T_elems()[5]._w")
    assert abs(bw - 120) < 0.01, bw
    # saved and synced with its size and box
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(3)
    for name in ("Bob", "Lee"):
        se = strategies(c[name], BOSS)[0]["p"][0]["e"][4]
        assert se["z"] == 26 and se["w"] == 120, (name, se)
    # out of range: not valid
    for bad in ("e.z = 5", "e.z = 49", "e.w = 39", "e.w = 1001"):
        res = bob.eval_py("local s = ns.Strategy:GetStrategy(...); local e = s.p[1].e[5]; %s; "
                          "local ok, err = ns.Strategy:SaveStrategy(s); return { ok = ok }" % bad, sid)
        assert res["ok"] is False, bad
    w.assert_no_errors()


@case
def text_alignment_buttons():
    w, c, bob, sid = setup()
    btns = W + ".tools.alignBtns"

    def state():
        return bob.eval_py("local out = {}; for _, b in ipairs(%s) do out[b.align] = { b:IsShown(), b.active or false } end; "
                           "return out" % btns)

    def press(j):
        bob.click(bob.eval("for _, b in ipairs(%s) do if b.align == ... then return b end end" % btns, j))

    def justify():
        return bob.eval("for _, o in ipairs(%s.pools.text) do if o.fs:IsShown() then return o.fs:GetJustifyH() end end" % CV)

    # only with a text selected
    select(bob, 4)                              # the skull icon
    assert all(not v[0] for v in state().values()), state()
    select(bob, 5)                              # the text: centred until told otherwise
    st = state()
    assert all(v[0] for v in st.values()) and st["c"][1] and not st["l"][1], st
    assert justify() == "CENTER"
    press("l")
    assert elems(bob)[4]["j"] == "l" and justify() == "LEFT"
    assert state()["l"][1] and not state()["c"][1]
    press("r")
    assert elems(bob)[4]["j"] == "r" and justify() == "RIGHT"
    key(bob, "Z", ctrl=True)
    assert elems(bob)[4]["j"] == "l"
    # centre is the default: nothing stored
    select(bob, 5)
    press("c")
    assert "j" not in elems(bob)[4] and justify() == "CENTER"
    # several texts at once (the icon in the selection is left alone)
    bob.eval("%s:Place({ t = 'x', x = 300, y = 500, l = 'One\\nTwo lines', z = 2 })" % CV)
    n = len(elems(bob))
    select(bob, 4, 5, n)
    press("r")
    es = elems(bob)
    assert es[4]["j"] == "r" and es[-1]["j"] == "r" and "j" not in es[3], es
    # saved and synced; anything else is not valid
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(3)
    for name in ("Bob", "Lee"):
        assert strategies(c[name], BOSS)[0]["p"][0]["e"][4]["j"] == "r", name
    res = bob.eval_py("local s = ns.Strategy:GetStrategy(...); s.p[1].e[5].j = 'x'; "
                      "local ok = ns.Strategy:SaveStrategy(s); return { ok = ok }", sid)
    assert res["ok"] is False
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
