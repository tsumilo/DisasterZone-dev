"""The event builder's part 2 (docs/EVENTS_KINDS.md): definitions in the palette and their editors (tags, scores,
asks, lists, the questions sheet), places (set by standing there or on the map sheet, the picker, the card), the new
blanks and their pickers, the Matches card's "Won by", "Start from an example", and practice with the new facts. The
builder is driven as a player would: clicks on its rows, buttons and menus, typed text, a fake mouse for drags.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_kinds_builder.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all, printed_since, strip_codes  # noqa: E402

# A fake mouse: MOUSE_X / MOUSE_Y in canvas content units (x right, y down), MOUSE_DOWN the left button.
MOUSE = r"""
MOUSE_X, MOUSE_Y, MOUSE_DOWN = 0, 0, false
GetCursorPosition = function()
  local c = select(2, ns.EventBuilder:GetState()).content
  local s = c and c:GetEffectiveScale() or 1
  local l, t = c and c:GetLeft() or 0, c and c:GetTop() or 0
  return (l + MOUSE_X) * s, (t - MOUSE_Y) * s
end
IsMouseButtonDown = function() return MOUSE_DOWN end
"""

# Helpers in the client: the builder's state, its editors' forms, a picker row by what it offers, a script's blank.
HELP = r"""
T_B = ns.EventBuilder
T_BK = ns.EventBlocks
function T_S() return (ns.EventBuilder:GetState()) end
function T_D() return T_S().def end
function T_UI() return select(2, ns.EventBuilder:GetState()) end
function T_FORM(kind) return T_UI().dpop.forms[kind] end
-- the stage's scripts in the order they were made
function T_SCRIPTS()
  local out = {}
  for _, s in ipairs(T_D().scripts) do if s.st == T_S().stage then out[#out + 1] = s end end
  return out
end
-- the n-th piece of script s's stack (1 = its top)
function T_PIECE(s, n)
  local p = s.top
  for _ = 2, n do p = p and p.n end
  return p
end
-- clicks the blank (or the value in it) of piece p, slot i, in script s
function T_CLICK(s, p, i)
  local f = T_UI().scripts[s]
  assert(f, 'script not drawn')
  for _, bl in ipairs(f.blanks) do
    if bl.piece == p and bl.slot == i then bl.frame:Click() return end
  end
  local v = p.a[i]
  if type(v) == 'table' and v.k and f.at[v] then
    ns.EventBuilder:TapValue(v, f.at[v])
    return
  end
  error('no blank ' .. tostring(i) .. ' of ' .. tostring(p.k))
end
-- the shown picker rows' words
function T_ROWS()
  local out = {}
  for _, r in ipairs(T_UI().picker.rows) do
    if r:IsShown() then
      local c = r.choice
      local w
      if r.chip then w = T_BK:DefinitionName(T_D(), 'places', r.chip)
      elseif c and c.k == 'ctx' then w = c.a[1]
      elseif c and c.k == 'pl.tagged' then w = 'tag:' .. T_BK:DefinitionName(T_D(), 'tags', c.a[1])
      elseif c and c.k == 'var' then w = 'var:' .. c.a[1]
      elseif c then w = c.k
      else w = r.label:GetText() end
      out[#out + 1] = w
    end
  end
  return out
end
function T_PICK(want)
  for i, w in ipairs(T_ROWS()) do
    if w == want then
      local n = 0
      for _, r in ipairs(T_UI().picker.rows) do
        if r:IsShown() then n = n + 1; if n == i then r:Click() return true end end
      end
    end
  end
  error('no picker row ' .. tostring(want) .. ': ' .. table.concat(T_ROWS(), ', '))
end
"""


def one(name="Gina", rank=0):
    w = World()
    c = Client(w, name, guild_rank=rank, class_file="ROGUE")
    c.load_addon()
    w.tick(3)
    c.eval(HELP)
    return w, c


def open_example(c, key, stage="s1", cat=None):
    did = c.eval("local d = ns.Events:NewDef(false); local ex = ns.EventBlocks:Example(...); for k, v in pairs(ex) do "
                 "d[k] = v end; ns.Events:SaveDef(d); ns.EventBuilder:Open(ns.Events:GetDef(d.id), { stage = select(2, ...) }); "
                 "return d.id", key, stage)
    if cat:
        palette(c, cat)
    return did


def palette(c, cat):
    c.eval("T_S().cat = ...; T_S().search = ''; ns.EventBuilder:RenderPalette()", cat)


def menu_texts(c):
    out = []

    def walk(m):
        for ch in m.get("children", []):
            if ch.get("text"):
                out.append(ch["text"])
            walk(ch)
    walk(c.last_menu() or {})
    return out


def pick_menu(c, words):
    """Selects the entry of the last menu whose text (without codes) ends with these words."""
    texts = menu_texts(c)
    hit = [t for t in texts if strip_codes(t).strip().endswith(words)]
    assert hit, (words, [strip_codes(t) for t in texts])
    c.menu_select(hit[0])


def drag_new(c, key, x, y, piece=None):
    """A new piece from the palette let go with its top-left at x, y on the canvas (content units)."""
    c.eval("""
        MOUSE_DOWN = true
        MOUSE_X, MOUSE_Y = -200, 300
        local p = select(2, ...) or ns.EventBlocks:New((...))
        ns.EventBuilder:PressNew(p)
        MOUSE_X, MOUSE_Y = select(3, ...) + 12, select(4, ...) + 12
        ns.EventBuilder:OnCanvasUpdate()
        ns.EventBuilder:OnCanvasUpdate()
        MOUSE_DOWN = false
        ns.EventBuilder:OnCanvasUpdate()""", key, piece, x, y)


def drop_under(c, script_index, key):
    """A new piece snapped under the last piece of the stage's script_index-th script."""
    x, y, h = c.eval_py("local s = T_SCRIPTS()[...]; local f = T_UI().scripts[s]; return { s.x, s.y, f.h }", script_index)
    drag_new(c, key, x + 2, y + h + 2)


def stack(c, script_index):
    return c.eval_py("""
        local s = T_SCRIPTS()[...]
        local out, p = {}, s.top
        while p do out[#out + 1] = p.k; p = p.n end
        return out""", script_index)


def status(c):
    return c.eval("return T_UI().status.fs:GetText()")


# ------------------------------------------------------------------------------------------------------------------
# The palette
# ------------------------------------------------------------------------------------------------------------------
@case
def the_palette_lists_each_categorys_definitions_first_then_its_pieces():
    w, c = one()
    open_example(c, "hide", "s3", "pl")
    heads = c.eval_py("local o = {}; for _, h in ipairs(T_UI().pal.heads) do if h:IsShown() then o[#o + 1] = h:GetText() end end; "
                      "return o")
    assert heads[:2] == ["Tags", "Pieces"], heads
    # the tags as they were made, the built-in one last; each with its one line
    rows = c.eval_py("""
        local o = {}
        for _, it in ipairs(T_UI().pal.items) do
          if it:IsShown() and it.defId then o[#o + 1] = { it.nm:GetText(), it.sb:GetText() } end
        end
        return o""")
    assert [r[0] for r in rows] == ["Hiders", "Seekers", "Found", "Entrants"], rows
    assert rows[0][1] == "everyone sees it" and "built in" in rows[3][1], rows
    # "+ Add tag" after them
    assert c.eval("return T_UI().pal.rowOf['add:tags']:IsShown() and T_UI().pal.rowOf['add:tags'].fs:GetText()") == "Add tag"
    # every category's definitions: Scores (Season points first), Places, Logic (lists, then variables), Ask
    palette(c, "pt")
    assert c.eval("return T_UI().pal.rowOf['scores:' .. ns.EventBlocks.SEASON] ~= nil")
    palette(c, "lo")
    heads = c.eval_py("local o = {}; for _, h in ipairs(T_UI().pal.heads) do if h:IsShown() then o[#o + 1] = h:GetText() end end; "
                      "return o")
    assert heads == ["Lists", "Variables", "Pieces"], heads
    palette(c, "ch")
    heads = c.eval_py("local o = {}; for _, h in ipairs(T_UI().pal.heads) do if h:IsShown() then o[#o + 1] = h:GetText() end end; "
                      "return o")
    assert heads == ["Messages", "For the guild"], heads
    # the categories' circles in B.CATS' order, with their words
    cats = c.eval_py("local o = {}; for _, b in ipairs(T_UI().pal.cats) do o[#o + 1] = b.fs:GetText() end; return o")
    assert cats == ["Events", "Stages", "Logic", "Players", "Scores", "Places", "Ask", "Messages", "Timers", "World",
                    "Smart"], cats
    w.assert_no_errors()


@case
def a_piece_too_wide_for_the_palette_takes_two_lines_there_and_one_on_the_canvas():
    w, c = one()
    open_example(c, "hide", "s3", "pl")
    r = c.eval_py("""
        local pal = T_UI().pal
        local h
        for _, it in ipairs(pal.items) do
          if it:IsShown() and it.piece and it.piece.k == 'pl.touch' then h = { it.draw.h, it.draw.w, it.draw:GetScale() } end
        end
        -- the same piece on the canvas: one line
        local f = ns.EventPieces:DrawScript(UIParent, ns.EventBlocks:New('pl.touch'), { static = true })
        return { h, f.h, f.w }""")
    palette_h, palette_w, scale = r[0]
    assert scale == 1 and palette_w <= 184 and palette_h > 60, r          # several lines, not shrunk
    assert r[1] == 42 and r[2] > 184, r                                   # one line: a hat 42 high
    w.assert_no_errors()


@case
def a_tag_dragged_from_the_palette_is_its_chip_on_the_canvas():
    w, c = one()
    open_example(c, "hide", "s3", "pl")
    c.eval(MOUSE)
    n0 = c.eval("return #T_D().scripts")
    c.eval("""
        local it = T_UI().pal.rowOf['tags:tg1']
        MOUSE_DOWN = true
        MOUSE_X, MOUSE_Y = -150, 100
        it:GetScript('OnMouseDown')(it, 'LeftButton')
        MOUSE_X, MOUSE_Y = 700, 600
        ns.EventBuilder:OnCanvasUpdate()
        ns.EventBuilder:OnCanvasUpdate()
        MOUSE_DOWN = false
        ns.EventBuilder:OnCanvasUpdate()""")
    top = c.eval_py("local s = T_D().scripts[#T_D().scripts]; return { s.top.k, s.top.a[1] }")
    assert c.eval("return #T_D().scripts") == n0 + 1 and top == ["pl.tagged", "tg1"], top
    # drawn as the chip: the tag's name, not "players with tag"
    words = c.eval_py("""
        local s = T_D().scripts[#T_D().scripts]
        local f = T_UI().scripts[s].at[s.top]
        local o = {}
        for _, fs in ipairs(f.fonts or {}) do if fs:IsShown() then o[#o + 1] = fs:GetText() end end
        return { o, f.texs[21] and f.texs[21]:IsShown() }""")
    assert words == [["Hiders"], True], words
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The definitions' editors
# ------------------------------------------------------------------------------------------------------------------
@case
def each_definition_kind_is_added_and_changed_in_its_editor():
    w, c = one()
    c.eval("ns.EventBuilder:Open(nil)")
    # a tag: "+ Add tag" opens its editor next to the row; name, colour, who sees it, Save
    palette(c, "pl")
    c.eval("T_UI().pal.rowOf['add:tags']:Click()")
    assert c.eval("return T_UI().dpop:IsShown() and T_UI().dpop.title:GetText()") == "New tag"
    c.type_text(c.eval("return T_FORM('tags').name"), "Hiders")
    assert c.eval("return T_UI().dpop.title:GetText()") == "Hiders"
    c.eval("T_FORM('tags').sws[4]:Click(); T_FORM('tags').shown.buttons[2]:Click(); T_UI().dpop.save:Click()")
    tag = c.eval_py("return T_D().tags.tg1")
    assert tag == {"n": "Hiders", "c": "green", "shown": "self"}, tag
    assert not c.eval("return T_UI().dpop:IsShown()")
    # its row says so; changing it: the row opens the editor with its values, the name must stay unique
    assert c.eval("return T_UI().pal.rowOf['tags:tg1'].sb:GetText()") == "only they see it"
    c.eval("T_UI().pal.rowOf['add:tags']:Click()")
    c.type_text(c.eval("return T_FORM('tags').name"), "hiders")
    c.eval("T_UI().dpop.save:Click()")
    assert c.eval("return T_UI().dpop:IsShown() and T_UI().dpop.err:GetText()") == "Name already used"
    c.type_text(c.eval("return T_FORM('tags').name"), "Seekers", True)
    assert c.eval_py("return T_D().tags.tg2.n") == "Seekers"
    c.eval("T_UI().pal.rowOf['tags:tg1']:Click()")
    assert c.eval("return T_FORM('tags').name:GetText()") == "Hiders"
    c.eval("T_FORM('tags').shown.buttons[1]:Click(); T_UI().dpop.save:Click()")
    assert c.eval("return T_D().tags.tg1.shown") == "all"
    # a score: lower wins, a time, off the board, a cap
    palette(c, "pt")
    c.eval("T_UI().pal.rowOf['add:scores']:Click()")
    c.type_text(c.eval("return T_FORM('scores').name"), "Time")
    c.eval("T_FORM('scores').high.buttons[2]:Click(); T_FORM('scores').fmt.buttons[2]:Click(); T_FORM('scores').board:Click()")
    c.eval("T_FORM('scores').cap:Click()")
    pick_menu(c, "5:00")
    c.eval("T_UI().dpop.save:Click()")
    sc = c.eval_py("return T_D().scores.sc1")
    assert sc == {"n": "Time", "high": False, "fmt": "time", "board": False, "cap": 300}, sc
    assert c.eval("return T_UI().pal.rowOf['scores:sc1'].sb:GetText()") == "lower wins · a time"
    # an ask: its question, a choice with its choices, votes, secret
    palette(c, "as")
    c.eval("T_UI().pal.rowOf['add:asks']:Click()")
    form = c.eval("return T_FORM('asks')")
    c.type_text(c.eval("return T_FORM('asks').name"), "Best outfit")
    c.type_text(c.eval("return T_FORM('asks').q"), "Who wore it best?")
    c.eval("T_FORM('asks').kinds[2]:Click()")
    assert c.eval("return T_FORM('asks').choiceRow:IsShown() and not T_FORM('asks').fromRow:IsShown()")
    for ch in ("Red", "Blue", "Green"):
        c.type_text(c.eval("return T_FORM('asks').choices.add"), ch, True)
    c.eval("T_FORM('asks').choices.chips[3]:Click()")               # (its cross: Green goes)
    c.eval("T_FORM('asks').votes:Click()")
    pick_menu(c, "2 each")
    c.eval("T_FORM('asks').secret:Click(); T_UI().dpop.save:Click()")
    ask = c.eval_py("local a = T_D().asks.ak1; return { a.n, a.q, a.kind, a.choices, a.votes, a.secret }")
    assert ask == ["Best outfit", "Who wore it best?", "choice", ["Red", "Blue"], 2, True], ask
    # changed to "a player" from a tag: its choices go
    c.eval("T_UI().pal.rowOf['asks:ak1']:Click(); T_FORM('asks').kinds[1]:Click(); T_FORM('asks').from:Click()")
    pick_menu(c, "Hiders")
    c.eval("T_UI().dpop.save:Click()")
    ask = c.eval_py("local a = T_D().asks.ak1; return { a.kind, a.from, a.choices == nil }")
    assert ask == ["player", "tg1", True], ask
    assert form is not None
    # a list of texts, typed as chips
    palette(c, "lo")
    c.eval("T_UI().pal.rowOf['add:lists']:Click()")
    c.type_text(c.eval("return T_FORM('lists').name"), "Clues")
    for t in ("Near water", "Under a tree"):
        c.type_text(c.eval("return T_FORM('lists').texts.add"), t, True)
    c.eval("T_UI().dpop.save:Click()")
    assert c.eval_py("return T_D().lists.ls1") == {"n": "Clues", "kind": "text", "items": ["Near water", "Under a tree"]}
    assert c.eval("return T_UI().pal.rowOf['lists:ls1'].sb:GetText()") == "2 texts"
    # one undo step a change: back to the ask before "a player", and on again
    c.eval("ns.EventBuilder:Undo()")
    assert c.eval("return T_D().lists == nil or T_D().lists.ls1 == nil")
    c.eval("ns.EventBuilder:Redo()")
    assert c.eval("return T_D().lists.ls1.n") == "Clues"
    w.assert_no_errors()


@case
def a_list_of_questions_is_typed_in_its_sheet():
    w, c = one()
    c.eval("ns.EventBuilder:Open(nil)")
    palette(c, "lo")
    c.eval("T_UI().pal.rowOf['add:lists']:Click()")
    c.type_text(c.eval("return T_FORM('lists').name"), "Questions")
    c.eval("T_FORM('lists').kind.buttons[3]:Click(); T_UI().dpop.save:Click()")
    # the new list's sheet: a first question to type, picked
    assert c.eval("return T_UI().qsheet:IsShown() and T_B.QSheet.cur.sel") == 1
    c.type_text(c.eval("return T_UI().qsheet.rows[1].qe"), "Which zone is Halaa in?")
    c.type_text(c.eval("return T_UI().qsheet.rows[1].box.add"), "Nagrand", True)
    c.eval("T_UI().qsheet.add:Click()")
    assert c.eval("return T_B.QSheet.cur.sel") == 2
    c.type_text(c.eval("return T_UI().qsheet.rows[2].qe"), "What's the highest level?")
    for a in ("70", "seventy"):
        c.type_text(c.eval("return T_UI().qsheet.rows[2].box.add"), a, True)
    c.eval("T_UI().qsheet.rows[2].pts:Click()")
    pick_menu(c, "2")
    # a third one left empty: dropped
    c.eval("T_UI().qsheet.add:Click(); T_UI().qsheet.done:Click()")
    items = c.eval_py("return T_D().lists.ls1.items")
    assert items == [{"q": "Which zone is Halaa in?", "a": ["Nagrand"], "pts": 1},
                     {"q": "What's the highest level?", "a": ["70", "seventy"], "pts": 2}], items
    assert not c.eval("return T_UI().qsheet:IsShown()")
    # the row opens the sheet again; a question goes (its bin), Done
    c.eval("T_UI().pal.rowOf['lists:ls1']:Click()")
    assert c.eval("return T_UI().qsheet:IsShown()")
    c.eval("T_UI().qsheet.rows[1]:Click(); T_UI().qsheet.rows[1].bin:Click(); T_UI().qsheet.done:Click()")
    assert c.eval("return #T_D().lists.ls1.items") == 1
    # a sheet closed with its cross keeps nothing
    c.eval("T_UI().pal.rowOf['lists:ls1']:Click(); T_UI().qsheet.add:Click(); T_UI().qsheet.x:Click()")
    assert c.eval("return #T_D().lists.ls1.items") == 1
    w.assert_no_errors()


@case
def someone_elses_definitions_open_to_read_and_say_why_they_dont_change():
    w, c = one()
    c.eval("local d = ns.Events:NewDef(false); local ex = ns.EventBlocks:Example('hide'); for k, v in pairs(ex) do d[k] = v end; "
           "d.by = 'Victhar-Thunderstrike'; ns.EventBuilder:Open(d, { stage = 's3' })")
    palette(c, "pl")
    c.eval("T_UI().pal.rowOf['tags:tg1']:Click()")
    st = c.eval_py("local f = T_UI().dpop; return { f:IsShown(), f.save:IsShown(), f.bin:IsShown(), f.foot:GetText() }")
    assert st[0] and not st[1] and not st[2] and "make a copy" in st[3], st
    n0 = len(c.chat_frame)
    c.eval("T_FORM('tags').sws[1]:Click()")
    assert any("make a copy" in x for x in printed_since(c, n0)), printed_since(c, n0)
    assert c.eval("return T_D().tags.tg1.c") == "green"
    # "+ Add tag" too
    n0 = len(c.chat_frame)
    c.eval("T_UI().pal.rowOf['add:tags']:Click()")
    assert any("make a copy" in x for x in printed_since(c, n0))
    w.assert_no_errors()


@case
def a_definition_that_pieces_use_is_deleted_only_after_asking():
    w, c = one()
    open_example(c, "hide", "s3", "pl")
    uses = c.eval("return ns.EventBlocks:DefinitionUses(T_D(), 'tags', 'tg1')")
    assert uses > 0
    # the row's menu: Delete asks first, and says how many
    c.eval("T_UI().pal.rowOf['tags:tg1']:Click('RightButton')")
    pick_menu(c, "Delete")
    conf = c.eval_py("return { T_UI().confirm:IsShown(), T_UI().confirm.title:GetText(), T_UI().confirm.text:GetText() }")
    assert conf[0] and conf[1] == "Delete Hiders?" and conf[2].startswith("%d pieces use it" % uses), conf
    assert c.eval("return T_D().tags.tg1 ~= nil")
    c.eval("T_UI().confirm.cancel:Click()")
    assert c.eval("return T_D().tags.tg1 ~= nil")
    # the editor's bin: the same question; yes deletes it, the pieces that used it say so
    c.eval("T_UI().pal.rowOf['tags:tg1']:Click(); T_UI().dpop.bin:Click(); T_UI().confirm.ok:Click()")
    assert c.eval("return T_D().tags.tg1 == nil")
    probs = c.eval_py("local o = {}; for _, p in ipairs(ns.EventBlocks:Problems(T_D())) do o[#o + 1] = p.text end; return o")
    assert "That tag is gone." in probs, probs
    assert "fix" in status(c)
    c.eval("ns.EventBuilder:Undo()")
    assert c.eval("return T_D().tags.tg1.n") == "Hiders"
    # one nothing uses goes at once
    c.eval("ns.EventBlocks:NewDefinition(T_D(), 'tags', { n = 'Spare' }); ns.EventBuilder:Refresh()")
    c.eval("T_B.Defs:Delete('tags', 'tg4')")
    assert c.eval("return T_D().tags.tg4 == nil and not T_UI().confirm:IsShown()")
    # a place leaves the lists of places too
    open_example(c, "race", "s2", "pc")
    n = c.eval("return #T_D().lists.ls1.items")
    c.eval("T_B.MapSheet:Open({ pid = 'pc3' }); T_UI().msheet.bin:Click(); T_UI().confirm.ok:Click()")
    assert c.eval("return T_D().places.pc3 == nil and #T_D().lists.ls1.items") == n - 1
    assert not c.eval("return T_UI().msheet:IsShown()")
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Places
# ------------------------------------------------------------------------------------------------------------------
MAPART = r'''
local ZN = { [1951] = "Nagrand", [1952] = "TerokkarForest" }
local oL, oT = C_Map.GetMapArtLayers, C_Map.GetMapArtLayerTextures
C_Map.GetMapArtLayers = function(id)
  if ZN[id] then return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256, minScale = 1, maxScale = 1 } } end
  return oL(id)
end
C_Map.GetMapArtLayerTextures = function(id, l)
  if ZN[id] then local t = {}; for i = 1, 12 do t[i] = 300000 + id * 100 + i end; return t end
  return oT(id, l)
end
'''


@case
def a_place_is_set_from_where_i_stand_and_refused_in_an_instance():
    w, c = one()
    c.eval("ns.EventBuilder:Open(nil)")
    w.set_position("Gina", 1951, 0.345, 0.385, subzone="Halaa")
    palette(c, "pc")
    c.eval("T_UI().pal.rowOf['add:places']:Click()")
    pick_menu(c, "Set from where I stand")
    sheet = c.eval_py("local f = T_UI().msheet; return { f:IsShown(), f.name:GetText(), f.where:GetText(), f.coords:GetText() }")
    assert sheet == [True, "Halaa", "Halaa, Nagrand", "34.5, 38.5"], sheet
    c.eval("T_UI().msheet.save:Click()")
    pl = c.eval_py("return T_D().places.pc1")
    assert pl["n"] == "Halaa" and pl["map"] == 1951 and abs(pl["x"] - 0.345) < 1e-6 and pl["z"] == "Nagrand" \
        and pl["sz"] == "Halaa" and pl["r"] == 30, pl
    assert c.eval("return T_UI().pal.rowOf['places:pc1'].sb:GetText()") == "Halaa · 30 yd"
    # a second one there: its name must be another
    c.eval("T_UI().pal.rowOf['add:places']:Click()")
    pick_menu(c, "Set from where I stand")
    c.eval("T_UI().msheet.save:Click()")
    assert c.eval("return T_UI().msheet.err:GetText()") == "Name already used"
    c.eval("T_UI().msheet.cancel:Click()")
    # in a dungeon: said plainly, nothing opens
    w.enter_instance("Karazhan")
    n0 = len(c.chat_frame)
    c.eval("T_UI().pal.rowOf['add:places']:Click()")
    pick_menu(c, "Set from where I stand")
    assert not c.eval("return T_UI().msheet:IsShown()")
    assert any("open world" in x for x in printed_since(c, n0)), printed_since(c, n0)
    w.assert_no_errors()


@case
def a_place_is_picked_and_sized_on_the_map_sheet():
    w, c = one()
    c.eval(MAPART)
    w.set_position("Gina", 1951, 0.345, 0.385, subzone="Halaa")
    c.eval("ns.EventBuilder:Open(nil)")
    c.eval("__MOCK.real_geometry = true")
    palette(c, "pc")
    c.eval("T_UI().pal.rowOf['add:places']:Click()")
    pick_menu(c, "Pick on the map")
    assert c.eval("return T_UI().msheet:IsShown() and T_UI().msheet.view.map") == 1951
    assert "Nagrand" in strip_codes(c.eval("return T_UI().msheet.zone:GetText()"))
    # a fake cursor over the map: a click puts the place there, its ring's handle dragged sizes it
    c.eval("""
        CUR_X, CUR_Y, CUR_DOWN = 0, 0, false
        GetCursorPosition = function() local s = UIParent:GetEffectiveScale(); return CUR_X * s, CUR_Y * s end
        IsMouseButtonDown = function() return CUR_DOWN end
        local v = T_UI().msheet.view
        function T_AT(px, py) CUR_X, CUR_Y = v:GetLeft() + px, v:GetTop() - py end
        T_AT(288, 192)
        CUR_DOWN = true; v:GetScript('OnMouseDown')(v, 'LeftButton')
        CUR_DOWN = false; v:GetScript('OnMouseUp')(v, 'LeftButton')""")
    at = c.eval_py("local cur = T_B.MapSheet.cur; return { cur.map, cur.x, cur.y, cur.z, cur.sz or false }")
    assert at[0] == 1951 and abs(at[1] - 0.5) < 0.01 and abs(at[2] - 0.5) < 0.01 and at[3] == "Nagrand" and at[4] is False, at
    r0 = c.eval("return T_B.MapSheet.cur.r")
    c.eval("""
        local v = T_UI().msheet.view
        local h = v.handle
        T_AT(h.x, h.y)
        CUR_DOWN = true; v:GetScript('OnMouseDown')(v, 'LeftButton')
        T_AT(h.x + 60, h.y)
        v:GetScript('OnUpdate')(v)
        CUR_DOWN = false; v:GetScript('OnMouseUp')(v, 'LeftButton')""")
    r1 = c.eval("return T_B.MapSheet.cur.r")
    assert r1 > r0 + 100, (r0, r1)
    assert c.eval("return T_UI().msheet.size:GetText()") == "%d yd" % r1
    # another zone from its menu: the map changes, the place stays where it was until it's clicked again
    c.eval("T_UI().msheet.zone:Click()")
    pick_menu(c, "Terokkar Forest")
    assert c.eval("return T_UI().msheet.view.map") == 1952
    c.type_text(c.eval("return T_UI().msheet.name"), "Play area")
    c.eval("T_UI().msheet.save:Click()")
    pl = c.eval_py("return T_D().places.pc1")
    assert pl["n"] == "Play area" and pl["map"] == 1951 and pl["r"] == r1, pl
    # the map's art is the game's tiles (12 of them)
    tiles = c.eval("local n = 0; for _, t in ipairs(T_UI().msheet.view.tiles) do if t:IsShown() then n = n + 1 end end; return n")
    assert tiles == 0 or tiles == 12, tiles
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()


@case
def a_place_blank_picks_a_place_and_shows_its_card():
    w, c = one()
    open_example(c, "hide", "*", "pc")
    # the leaves hat: its place emptied, then picked again in the picker
    c.eval("for _, s in ipairs(T_SCRIPTS()) do if s.top.k == 'pc.leave' then T_LEAVE = s end end; T_LEAVE.top.a[1] = nil; "
           "ns.EventBuilder:Refresh(); T_CLICK(T_LEAVE, T_LEAVE.top, 1)")
    p = c.eval_py("local p = T_UI().picker; return { p:IsShown(), p.title:GetText(), p.sub:GetText() }")
    assert p == [True, "Pick a place", 'for "leaves"'], p
    rows = c.eval_py("return T_ROWS()")
    assert rows[0] == "Play area" and "place" in rows and rows[-2:] == ["Set from where I stand", "Pick on the map"], rows
    c.eval("T_PICK('Play area')")
    assert c.eval("return T_LEAVE.top.a[1]") == "pc1"
    # its chip: the mouse over it shows the place's card (the pieces that use it)
    c.eval("""
        local f = T_UI().scripts[T_LEAVE]
        for _, bl in ipairs(f.blanks) do if bl.piece == T_LEAVE.top then T_CHIP = bl.frame end end
        T_CHIP:GetScript('OnEnter')(T_CHIP)""")
    card = c.eval_py("local c = T_UI().pcard; return { c:IsShown(), c.m:GetText() }")
    assert card[0] and card[1].startswith("At ") and "3 pieces use it" in card[1], card
    c.eval("T_CHIP:GetScript('OnLeave')(T_CHIP)")
    assert not c.eval("return T_UI().pcard:IsShown()")
    # a new place from the picker: set from where I stand, then the blank holds it
    w.set_position("Gina", 1951, 0.555, 0.37, subzone="Garadar")
    c.eval("T_CLICK(T_LEAVE, T_LEAVE.top, 1); T_PICK('Set from where I stand'); T_UI().msheet.save:Click()")
    assert c.eval("return T_LEAVE.top.a[1]") == "pc2"
    assert c.eval("return T_D().places.pc2.n") == "Garadar"
    w.assert_no_errors()


@case
def a_route_is_reordered_by_its_grips():
    w, c = one()
    open_example(c, "race", "s2", "lo")
    before = c.eval_py("return T_D().lists.ls1.items")
    c.eval("T_UI().pal.rowOf['lists:ls1']:Click()")
    assert c.eval("return T_UI().dpop:IsShown() and T_FORM('lists').items[8]:IsShown()")
    c.eval("__MOCK.real_geometry = true")
    # the first place's grip dragged to below the third
    c.eval("""
        local form = T_FORM('lists')
        local top = form.child:GetTop()
        local s = form.child:GetEffectiveScale()
        GetCursorPosition = function() return 10, (top - 3 * 24 - 2) * s end
        IsMouseButtonDown = function() return true end
        local g = form.items[1].grip
        g:GetScript('OnMouseDown')(g, 'LeftButton')
        form:GetScript('OnUpdate')(form)
        IsMouseButtonDown = function() return false end
        form:GetScript('OnUpdate')(form)""")
    c.eval("__MOCK.real_geometry = nil")
    moved = c.eval_py("return T_B.Defs.cur.work.items")
    assert moved == before[1:3] + [before[0]] + before[3:], (before, moved)
    # a row's menu moves it too
    c.eval("T_FORM('lists').items[1]:Click('RightButton')")
    pick_menu(c, "Move down")
    moved2 = c.eval_py("return T_B.Defs.cur.work.items")
    assert moved2[:2] == [moved[1], moved[0]], moved2
    c.eval("T_UI().dpop.save:Click()")
    assert c.eval_py("return T_D().lists.ls1.items") == moved2
    # the route's numbers: the places in order, the last one gold (the finish)
    c.eval("T_UI().pal.rowOf['lists:ls1']:Click()")
    nums = c.eval_py("local o = {}; for i = 1, 8 do o[i] = T_FORM('lists').items[i].num:GetText() end; return o")
    assert nums == ["1", "2", "3", "4", "5", "6", "7", "F"], nums
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Blanks and pickers
# ------------------------------------------------------------------------------------------------------------------
@case
def every_new_blank_type_is_picked():
    w, c = one()
    open_example(c, "hide", "s3", "ev")
    # a script of every new blank (under one hat, so the picker knows its values)
    c.eval("""
        local N, C = ns.EventBlocks.Build.N, ns.EventBlocks.Build.C
        T_HAT = N('pl.touch')
        local list = { N('pl.has'), N('pt.get'), N('pc.in'), N('pc.yards'), N('lo.lfor'), N('as.press'), N('ch.sound'),
          N('wo.is'), N('tm.since'), N('wo.items'), N('ch.tell') }
        T_P = {}
        for i, p in ipairs(list) do T_P[p.k] = p end
        -- (the yes / no and value pieces sit in a show's text, the stack ones under the hat)
        local show = N('ch.show', N('pl.all'), { j = { T_P['pt.get'], ' ', T_P['pc.yards'], ' ', T_P['tm.since'], ' ', T_P['wo.items'] } })
        local iff = N('lo.if', T_P['pl.has'])
        local iff2 = N('lo.if', T_P['pc.in'])
        local iff3 = N('lo.if', T_P['wo.is'])
        T_HAT.n = show; show.n = iff; iff.n = iff2; iff2.n = iff3; iff3.n = T_P['lo.lfor']; T_P['lo.lfor'].n = T_P['ch.sound']
        T_P['ch.sound'].n = T_P['ch.tell']
        T_S1 = { id = 'tst', st = 's3', x = 900, y = 900, top = T_HAT }
        table.insert(T_D().scripts, T_S1)
        T_P2 = N('as.press')
        T_S2 = { id = 'tst2', st = 's3', x = 900, y = 1400, top = T_P2 }
        table.insert(T_D().scripts, T_S2)
        T_P3 = N('ev.happen')
        T_S3 = { id = 'tst3', st = 's3', x = 1400, y = 1400, top = T_P3 }
        table.insert(T_D().scripts, T_S3)
        ns.EventBuilder:Refresh()""")

    def blank(var, slot):
        c.eval("T_CLICK(T_S1, %s, %d)" % (var, slot))

    # tag: the event's tags and the built-in one, then "+ New tag"
    blank("T_P['pl.has']", 2)
    texts = [strip_codes(t).strip() for t in menu_texts(c)]
    assert texts[:4] == ["Hiders", "Seekers", "Found", "Entrants"] and texts[-1] == "New tag", texts
    pick_menu(c, "Seekers")
    assert c.eval("return T_P['pl.has'].a[2]") == "tg2"
    # + New tag: its editor (the palette shows Players), Save, and the blank holds it
    blank("T_P['pl.has']", 2)
    pick_menu(c, "New tag")
    assert c.eval("return T_UI().dpop:IsShown() and T_S().cat") == "pl"
    c.type_text(c.eval("return T_FORM('tags').name"), "Spotted", True)
    assert c.eval("return T_P['pl.has'].a[2]") == "tg4"
    # score
    c.eval("ns.EventBuilder:Refresh()")
    blank("T_P['pt.get']", 2)
    pick_menu(c, "Finds")
    assert c.eval("return T_P['pt.get'].a[2]") == "sc1"
    # place (a picker of the event's places) and where (places and players)
    blank("T_P['pc.in']", 2)
    c.eval("T_PICK('Play area')")
    assert c.eval("return T_P['pc.in'].a[2]") == "pc1"
    blank("T_P['pc.yards']", 2)
    assert c.eval("return T_UI().picker.title:GetText()") == "A place or a player"
    c.eval("T_PICK('touched')")
    assert c.eval("return T_P['pc.yards'].a[2].k == 'ctx' and T_P['pc.yards'].a[2].a[1]") == "touched"
    # list, sound, state, since
    c.eval("T_BK:NewDefinition(T_D(), 'lists', { n = 'Clues', items = { 'a' } }); ns.EventBuilder:Refresh()")
    blank("T_P['lo.lfor']", 1)
    assert strip_codes(menu_texts(c)[-1]).strip() == "New list"
    pick_menu(c, "Clues")
    assert c.eval("return T_P['lo.lfor'].a[1]") == "ls1"
    blank("T_P['ch.sound']", 1)
    pick_menu(c, "Coins")
    assert c.eval("return T_P['ch.sound'].a[1]") == "coins"
    blank("T_P['wo.is']", 2)
    pick_menu(c, "in combat")
    assert c.eval("return T_P['wo.is'].a[2]") == "combat"
    blank("T_P['tm.since']", 1)
    pick_menu(c, "Seek")
    assert c.eval("return T_P['tm.since'].a[1]") == "Seek"
    # item: typed, or an item's link (its id)
    blank("T_P['wo.items']", 1)
    assert c.eval("return T_UI().picker.title:GetText()") == "An item"
    # (an item shift-clicked while its blank is typed: its link goes in the field, Enter keeps its id)
    c.eval("ChatEdit_InsertLink('|cff1eff00|Hitem:23424::::::::70:::::|h[Fel Iron Ore]|h|r'); "
           "local f = T_UI().picker.field; f:GetScript('OnEnterPressed')(f)")
    assert c.eval("return T_P['wo.items'].a[1]") == 23424
    blank("T_P['wo.items']", 1)
    c.eval("ns.EventBuilder:PickTyped('Mote of Water')")
    assert c.eval("return T_P['wo.items'].a[1]") == "Mote of Water"
    # how: a click, /point, or an emote (one of them)
    c.eval("T_CLICK(T_S1, T_HAT, 3)")
    pick_menu(c, "/point")
    assert c.eval("return T_HAT.a[3]") == "point"
    c.eval("T_CLICK(T_S1, T_HAT, 3)")
    pick_menu(c, "wave")
    assert c.eval_py("return { T_HAT.a[3], T_HAT.a[4] }") == ["emote", "WAVE"]
    # a players blank: the event's tags as their chips ("players with tag ...")
    blank("T_P['ch.tell']", 1)
    rows = c.eval_py("return T_ROWS()")
    assert "tag:Hiders" in rows and "toucher" in rows, rows
    c.eval("T_PICK('tag:Hiders')")
    assert c.eval_py("local v = T_P['ch.tell'].a[1]; return { v.k, v.a[1] }") == ["pl.tagged", "tg1"]
    # a click on the chip opens its blank's picker again (to change it)
    c.eval("T_CLICK(T_S1, T_P['ch.tell'], 1)")
    assert c.eval("return T_UI().picker:IsShown() and T_UI().picker.title:GetText()") == "Pick players"
    c.eval("T_PICK('toucher')")
    assert c.eval("return T_P['ch.tell'].a[1].a[1]") == "toucher"
    # label: typed, the event's buttons offered
    c.eval("T_CLICK(T_S2, T_P2, 1)")
    assert c.eval("return T_UI().picker.title:GetText()") == "A button"
    assert "Hint" in c.eval_py("return T_ROWS()")
    c.eval("ns.EventBuilder:PickTyped('Found it!')")
    assert c.eval("return T_P2.a[1]") == "Found it!"
    # what: the happen choices; one with a second blank: any, or one by name (its picker); an emote's from a list
    c.eval("T_CLICK(T_S3, T_P3, 1)")
    pick_menu(c, "dies")
    assert c.eval_py("return { T_P3.a[1], T_P3.a[2] == nil }") == ["die", True]
    c.eval("T_CLICK(T_S3, T_P3, 1)")
    pick_menu(c, "One creature by name...")
    assert c.eval("return T_P3.a[1]") == "kill"
    assert c.eval("return T_UI().picker:IsShown() and T_UI().picker.title:GetText()") == "A creature"
    c.eval("ns.EventBuilder:PickTyped('Hogger')")
    assert c.eval_py("return { T_P3.a[1], T_P3.a[2] }") == ["kill", "Hogger"]
    words = c.eval_py("""
        local f = T_UI().scripts[T_S3].at[T_P3]
        local o = {}
        local function walk(x)
          for _, fs in ipairs(x.fonts or {}) do if fs:IsShown() then o[#o + 1] = fs:GetText() end end
          for _, k in ipairs(x.kids or {}) do walk(k) end
        end
        walk(f)
        return o""")
    assert "kills" in words and "Hogger" in words, words
    # the filter itself: a click on it changes it
    c.eval("T_CLICK(T_S3, T_P3, 2)")
    c.eval("ns.EventBuilder:PickTyped('Clefthoof')")
    assert c.eval("return T_P3.a[2]") == "Clefthoof"
    c.eval("T_CLICK(T_S3, T_P3, 1)")
    pick_menu(c, "any creature")
    assert c.eval_py("return { T_P3.a[1], T_P3.a[2] == nil }") == ["kill", True]
    c.eval("T_CLICK(T_S3, T_P3, 1)")
    pick_menu(c, "cheer")
    assert c.eval_py("return { T_P3.a[1], T_P3.a[2] }") == ["emote", "CHEER"]
    # ask: the event's asks and "+ New ask"
    c.eval("T_BK:NewDefinition(T_D(), 'asks', { n = 'Vote', q = 'Who?' }); local p = ns.EventBlocks:New('as.close'); "
           "T_P['lo.lfor'].c1 = p; T_ASK = p; ns.EventBuilder:Refresh(); T_CLICK(T_S1, T_ASK, 1)")
    assert strip_codes(menu_texts(c)[-1]).strip() == "New ask"
    pick_menu(c, "Vote")
    assert c.eval("return T_ASK.a[1]") == "ak1"
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The Matches card, Start from
# ------------------------------------------------------------------------------------------------------------------
@case
def the_matches_card_says_what_won_by_the_pieces_means():
    w, c = one()
    open_example(c, "duel", "s2", "sm")
    rows = c.eval_py("""
        local card = T_UI().cards.b2
        local o = {}
        for _, r in ipairs(card.rows) do if r:IsShown() then o[#o + 1] = r.lab:GetText() end end
        return { o, card.note:IsShown() }""")
    assert rows[0] == ["Format", "Best of", "Seeding", "Entrants", "No-show", "At once", "Bronze", "Won by"], rows
    assert rows[1] is False, rows
    c.eval("for _, r in ipairs(T_UI().cards.b2.rows) do if r.key == 'win' then r.dd:Click() end end")
    pick_menu(c, "The pieces")
    note = c.eval_py("local card = T_UI().cards.b2; return { T_D().blocks.b2.set.win, card.note:IsShown(), card.note:GetText() }")
    assert note[0] == "pieces" and note[1] and "Duels don't count" in note[2], note
    # "Best of" and its final on one row
    assert c.eval_py("for _, r in ipairs(T_UI().cards.b2.rows) do if r.key == 'bo' then return { r.dd:GetText(), r.mid:GetText(), "
                     "r.dd2:GetText() } end end") == ["3", "final", "5"]
    w.assert_no_errors()


@case
def a_new_event_starts_from_any_of_the_examples():
    w, c = one()
    exs = c.eval_py("local o = {}; for _, e in ipairs(ns.EventBlocks:Examples()) do o[#o + 1] = { e.key, e.name } end; return o")
    assert len(exs) == 8
    for i, (key, name) in enumerate(exs):
        c.eval("ns.EventBuilder:Open(nil)")
        st = c.eval_py("local sf = T_UI().start; local n = 0; for _, cd in ipairs(sf.cards) do if cd:IsShown() then n = n + 1 end end; "
                       "return { sf:IsShown(), n, sf.cards[...].n:GetText(), T_UI().empty:IsShown() }", i + 1)
        assert st == [True, 8, name, False], (key, st)
        c.eval("T_UI().start.cards[...]:Click()", i + 1)
        got = c.eval_py("""
            local d, ex = T_D(), ns.EventBlocks:Example(...)
            local function n(t) local k = 0; for _ in pairs(t or {}) do k = k + 1 end; return k end
            return { d.name, #d.stages, #d.scripts, #ex.scripts, n(d.tags), n(ex.tags), n(d.places), n(ex.places), n(d.lists),
                     n(ex.lists), n(d.asks), n(ex.asks), #ns.EventBlocks:Problems(d), T_UI().start:IsShown(), T_S().stage }""", key)
        assert got[0] == name and got[2] == got[3] and got[4] == got[5] and got[6] == got[7] and got[8] == got[9] \
            and got[10] == got[11] and got[12] == 0 and got[13] is False and got[14] == "s1", (key, got)
        # one undo: the blank event again, with its examples
        c.eval("ns.EventBuilder:Undo()")
        assert c.eval("return #T_D().scripts == 0 and T_UI().start:IsShown()"), key
    # the old way still works (the Friday duel cup)
    c.eval("ns.EventBuilder:Open(nil); ns.EventBuilder:UseStarter()")
    assert c.eval("return T_D().name") == "Friday duel cup"
    # an example opened as a new event (the Library's Examples menu): closed untouched, nothing is kept
    c.eval("ns.EventBuilder:Close()")
    n0 = c.eval("return #ns.Events:GetDefs()")
    assert c.eval("return ns.EventBuilder:OpenExample('quiz')") is True
    st = c.eval_py("return { T_D().name, T_D().lists.ls1.n, #ns.EventBlocks:Problems(T_D()), ns.EventBuilder:IsUntouched(), "
                   "T_UI().top.primary:GetText() }")
    assert st == ["Trivia night", "Questions", 0, True, "Save"], st
    c.eval("ns.EventBuilder:Close()")
    assert c.eval("return #ns.Events:GetDefs()") == n0
    assert c.eval("return ns.EventBuilder:OpenExample('nope')") is False
    c.eval("ns.EventBuilder:OpenExample('race'); ns.EventBuilder:AddNote(10, 10); ns.EventBuilder:Close()")
    assert c.eval("return #ns.Events:GetDefs()") == n0 + 1
    # someone else's event, or one with pieces: no examples
    open_example(c, "fish", "s3")
    c.eval("ns.EventBuilder:AddStage(); T_UI().ask.field:SetText('Extra'); T_UI().ask:Done()")
    assert c.eval("return T_UI().empty:IsShown() and not T_UI().start:IsShown()")
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Hide and seek from nothing, practised to the end
# ------------------------------------------------------------------------------------------------------------------
@case
def hide_and_seek_is_built_from_nothing_and_practised_to_the_end():
    w, c = one()
    w.set_position("Gina", 1951, 0.415, 0.47, subzone="Halaa")
    c.eval("ns.EventBuilder:Open(nil)")
    c.eval(MOUSE)
    # the tags and the play area, in their editors
    palette(c, "pl")
    for name, colour in (("Hiders", 4), ("Seekers", 1), ("Found", 7)):
        c.eval("T_UI().pal.rowOf['add:tags']:Click()")
        c.type_text(c.eval("return T_FORM('tags').name"), name)
        c.eval("T_FORM('tags').sws[...]:Click(); T_UI().dpop.save:Click()", colour)
    palette(c, "pc")
    c.eval("T_UI().pal.rowOf['add:places']:Click()")
    pick_menu(c, "Set from where I stand")
    c.type_text(c.eval("return T_UI().msheet.name"), "Play area")
    c.eval("T_UI().msheet.save:Click()")
    assert c.eval_py("local o = {}; for id, t in pairs(T_D().tags) do o[id] = t.n end; return o") == \
        {"tg1": "Hiders", "tg2": "Seekers", "tg3": "Found"}
    # stage 1: everyone hides, one seeks, then the next stage
    c.eval("ns.EventBuilder:SelectStage('s1')")
    drag_new(c, "ev.start", 20, 20)
    for k in ("pl.tag", "pl.tag", "pl.untag", "sg.next"):
        drop_under(c, 1, k)
    assert stack(c, 1) == ["ev.start", "pl.tag", "pl.tag", "pl.untag", "sg.next"], stack(c, 1)
    c.eval("T_SC = T_SCRIPTS()[1]")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 2), 1); T_PICK('pl.all')")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 2), 2)")
    pick_menu(c, "Hiders")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 3), 1); T_PICK('pl.rand')")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 3), 2)")
    pick_menu(c, "Seekers")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 4), 1); T_PICK('tag:Seekers')")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 4), 2)")
    pick_menu(c, "Hiders")
    # stage 2: a seeker's click on a hider finds them; no hiders left ends it
    c.eval("ns.EventBuilder:SelectStage('s2')")
    drag_new(c, "pl.touch", 20, 20)
    for k in ("pl.untag", "pl.tag", "pt.add"):
        drop_under(c, 1, k)
    drag_new(c, "pl.notag", 20, 400)
    drop_under(c, 2, "sg.end")
    c.eval("T_SC = T_SCRIPTS()[1]; T_SC2 = T_SCRIPTS()[2]")
    c.eval("T_CLICK(T_SC, T_SC.top, 1); T_PICK('tag:Seekers'); T_CLICK(T_SC, T_SC.top, 2); T_PICK('tag:Hiders')")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 2), 1); T_PICK('touched')")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 2), 2)")
    pick_menu(c, "Hiders")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 3), 1); T_PICK('touched')")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 3), 2)")
    pick_menu(c, "Found")
    # (a score for the finds, made from its blank's "+ New score")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 4), 2)")
    pick_menu(c, "New score")
    c.type_text(c.eval("return T_FORM('scores').name"), "Finds", True)
    c.eval("ns.EventBuilder:Refresh(); T_CLICK(T_SC, T_PIECE(T_SC, 4), 3); T_PICK('toucher')")
    c.eval("T_CLICK(T_SC2, T_SC2.top, 1)")
    pick_menu(c, "Hiders")
    # always: a hider who leaves the play area is told
    c.eval("ns.EventBuilder:SelectStage('*')")
    drag_new(c, "pc.leave", 20, 20)
    drop_under(c, 1, "ch.tell")
    c.eval("T_SC = T_SCRIPTS()[1]")
    c.eval("T_CLICK(T_SC, T_SC.top, 1); T_PICK('Play area')")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 2), 1); T_PICK('player')")
    c.eval("T_CLICK(T_SC, T_PIECE(T_SC, 2), 2); ns.EventBuilder:PickTyped('Go back to the play area')")
    assert c.eval("return #ns.EventBlocks:Problems(T_D())") == 0, \
        c.eval_py("local o = {}; for _, p in ipairs(ns.EventBlocks:Problems(T_D())) do o[#o + 1] = p.text end; return o")
    assert status(c) == "Ready to practice"
    c.eval("ns.EventBuilder:Primary()")          # Save
    assert c.eval("return ns.Events:GetDef(T_D().id) ~= nil")
    # practice: 16 dummies hide, one seeks; the panel makes the seeker touch every hider
    c.eval("ns.EventBuilder:StartPractice()")
    w.tick(0.5)
    st = c.eval_py("local st = ns.EventLive:GetState('practice'); return { st.phase, st.stage }")
    assert st == ["live", "s2"], st
    who = c.eval_py("""
        local st = ns.EventLive:GetState('practice')
        local seekers, hiders = {}, {}
        for k in pairs(st.tags.tg2 or {}) do seekers[#seekers + 1] = k end
        for k in pairs(st.tags.tg1 or {}) do hiders[#hiders + 1] = k end
        table.sort(hiders)
        return { seekers, hiders }""")
    seekers, hiders = who
    assert len(seekers) == 1 and len(hiders) == 15, who
    # the facts menu: the event's own first (touches, leaves a place), the rest under "Something else"
    c.eval("T_UI().dp.kind:Click()")
    texts = [strip_codes(t) for t in menu_texts(c)]
    assert texts[:2] == ["leaves a place", "touches someone"] and "Something else" in texts and "kills a creature" in texts, texts
    # (one leaves a place they're in: first they enter it; out of it already, it says so)
    pick_menu(c, "leaves a place")
    n0 = len(c.chat_frame)
    c.eval("T_S().happen.who = ...; ns.EventBuilder:RenderPractice(); T_UI().dp.doit:Click()", hiders[0])
    assert any("out of Play area already" in x for x in printed_since(c, n0)), printed_since(c, n0)
    c.eval("T_UI().dp.kind:Click()")
    pick_menu(c, "enters a place")
    c.eval("T_UI().dp.doit:Click(); T_UI().dp.kind:Click()")
    pick_menu(c, "leaves a place")
    c.eval("T_UI().dp.doit:Click()")
    w.tick(0.3)
    log = c.eval_py("local o = {}; for _, e in ipairs(T_S().log) do o[#o + 1] = e.text end; return o")
    assert any("Go back to the play area" in t for t in log), log[-6:]
    c.eval("T_UI().dp.kind:Click()")
    pick_menu(c, "touches someone")
    for h in hiders:
        c.eval("T_S().happen.who, T_S().happen.whom = ...; ns.EventBuilder:RenderPractice(); T_UI().dp.doit:Click()", seekers[0], h)
        w.tick(0.2)
    st = c.eval_py("local st = ns.EventLive:GetState('practice'); local n = 0; for _ in pairs(st.tags.tg3 or {}) do n = n + 1 end; "
                   "return { st.phase, n, st.scores.sc1[...] }", seekers[0])
    assert st == ["done", 15, 15], st
    assert c.eval("return (ns.EventBuilder:WasPracticed(T_D().id))") is True
    c.eval("ns.EventBuilder:StopPractice()")
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Practice: every new fact
# ------------------------------------------------------------------------------------------------------------------
@case
def practice_makes_every_new_fact_happen():
    w, c = one()
    open_example(c, "hide", "s1")
    c.eval("ns.EventBuilder:StartPractice()")
    w.tick(0.3)
    calls = c.eval_py("""
        T_CALLS = {}
        local Lv = ns.EventLive
        for _, n in ipairs({ 'PracticeHappen', 'PracticePlace', 'PracticeTouch', 'PracticeRadar', 'PracticePress', 'PracticeAnswer' }) do
          local orig = Lv[n]
          Lv[n] = function(self, ...) T_CALLS[#T_CALLS + 1] = { n, ... }; return orig(self, ...) end
        end
        local facts = {}
        for _, f in ipairs(ns.EventBuilder.facts or {}) do facts[#facts + 1] = f.key end
        return facts""")
    c.eval("T_UI().dp.kind:Click()")
    texts = [strip_codes(t) for t in menu_texts(c)]
    for want in ("a duel ends", "kills a creature", "loots an item", "catches a fish", "dies", "mounts", "dismounts",
                 "starts moving", "stops moving", "does an emote", "enters a place", "leaves a place", "touches someone",
                 "targets someone without clicking", "presses a button", "answers an ask"):
        assert want in texts, (want, texts)
    assert calls == [] or calls is None or len(calls) > 10
    # kills a creature (named), catches a fish, an emote at someone, enters, radar, presses Hint
    def do(kind, **kw):
        c.eval("T_S().happen.kind = ...; ns.EventBuilder:RenderPractice()", kind)
        for k, v in kw.items():
            c.eval("T_S().happen[...] = select(2, ...)", k, v)
        c.eval("ns.EventBuilder:RenderPractice(); T_UI().dp.doit:Click()")
    do("h:kill", who="Dummy1-Practice", name="Hogger")
    do("h:fish", who="Dummy2-Practice", item="Mr. Pinchy")
    do("h:emote", who="Dummy3-Practice", emote="WAVE", other="Dummy4-Practice")
    do("enter", who="Dummy5-Practice")
    do("radar", who="Dummy6-Practice", whom="Dummy7-Practice")
    do("press", who="Dummy8-Practice")
    got = c.eval_py("""
        local o = {}
        for _, x in ipairs(T_CALLS) do
          local d = x[4]
          o[#o + 1] = { x[1], x[2], x[3], type(d) == 'table' and (d.creature or d.name or d.emote) or d }
        end
        return o""")
    assert got[0] == ["PracticeHappen", "Dummy1-Practice", "kill", "Hogger"], got
    assert got[1] == ["PracticeHappen", "Dummy2-Practice", "fish", "Mr. Pinchy"], got
    assert got[2] == ["PracticeHappen", "Dummy3-Practice", "emote", "WAVE"], got
    assert got[3] == ["PracticePlace", "Dummy5-Practice", "pc1", True], got
    assert got[4][:3] == ["PracticeRadar", "Dummy6-Practice", "Dummy7-Practice"], got
    assert got[5][:3] == ["PracticePress", "Dummy8-Practice", "Hint"], got
    # answers an ask (the transmog contest's): its kinds' answers
    c.eval("ns.EventBuilder:StopPractice()")
    open_example(c, "tmog", "s1")
    c.eval("ns.EventBuilder:StartPractice()")
    w.tick(0.3)
    c.eval("""
        T_CALLS = {}
        local Lv = ns.EventLive
        local orig = Lv.PracticeAnswer
        Lv.PracticeAnswer = function(self, ...) T_CALLS[#T_CALLS + 1] = { ... }; return orig(self, ...) end
        T_S().happen.kind = 'answer'
        ns.EventBuilder:RenderPractice()""")
    c.eval("T_S().happen.ask = 'ak2'; ns.EventBuilder:RenderPractice(); T_UI().dp.params[3].dd:Click()")
    pick_menu(c, "7")
    c.eval("T_UI().dp.doit:Click()")
    assert c.eval_py("return T_CALLS[1]") == ["Dummy1-Practice", "ak2", 7]
    # a fact the event can't take yet says so (no place picked: there are none)
    n0 = len(c.chat_frame)
    c.eval("T_S().happen.kind = 'enter'; ns.EventBuilder:RenderPractice(); T_UI().dp.doit:Click()")
    assert any("pick the place first" in x for x in printed_since(c, n0)), printed_since(c, n0)
    c.eval("ns.EventBuilder:StopPractice()")
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
