"""Edge cases of the event UI (UI/EventBuilder.lua, UI/EventPieces.lua, UI/EventWidgets.lua, UI/EventBoard.lua,
UI/EventTracker.lua), one case per bug found and fixed:
class circles after an unknown player; "in 1 day"; the stage progress line and the builder's stage strip inside their
room (many or long stage names), a long event name; opening a missing event, closing a new one untouched; undo / redo
with the picker or a name box open, past an added stage or smart block; typed numbers and text kept as the library
keeps them; stage names clean and unique; deleting a stage keeps the open one; a newer version of the open event from
elsewhere, the open event deleted elsewhere; notes count as a change; the picker on the screen and under its blank; a
search that finds nothing; a new note's focus; dropping on the palette; the orange pill into a smart block's own copy;
undo / redo stay clickable; one gold button inside a smart block; the board's host sheet after handing over; the
tracker's 3rd place line; a question of an event that ended; a player taken out has no match ahead; a bracket with too
few players; Add a player after the sign-up closed.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_edge_ui.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all, printed_since, strip_codes  # noqa: E402

HELLO = 50
CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]

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

STAGES = "local S = ns.EventBuilder:GetState(); local o = {}; for _, s in ipairs(S.def.stages) do o[#o + 1] = s.name end; return o"


def one(name="Gina", rank=0):
    w = World()
    c = Client(w, name, guild_rank=rank, class_file="ROGUE")
    c.load_addon()
    w.tick(3)
    return w, c


def open_starter(c, stage="s2"):
    return c.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); "
                  "ns.EventBuilder:Open(ns.Events:GetDef(d.id), { stage = ... }); return d.id", stage)


def guild(names, tick=HELLO):
    w = World()
    cs = []
    for i, n in enumerate(names):
        cs.append(Client(w, n, guild_rank=0 if i == 0 else 3, class_file=CLASSES[i % len(CLASSES)]))
    for c in cs:
        c.load_addon()
    w.tick(tick)
    return w, cs


def start_cup(names=("Gina", "Bert", "Cora", "Dain", "Wade"), players=("Bert", "Cora", "Dain")):
    """Gina hosts the starter cup (she plays in it too); `players` sign up."""
    w, cs = guild(list(names))
    by = {c.name: c for c in cs}
    host = by["Gina"]
    occ = host.eval_py("local d = ns.Events:NewDef(true); assert(ns.Events:SaveDef(d), 'save'); "
                       "return ns.Events:Schedule(d.id, GetServerTime() + 30)")
    w.tick(5)
    for n in players:
        assert by[n].eval("return ns.Events:SignUp(...)", occ, True)
    w.tick(5)
    ok = host.eval_py("return { ns.EventLive:Start(...) }", occ)
    assert ok[0] is True, ok
    w.tick(5)
    return w, cs, by, host, occ


def playing(c, occ):
    return c.eval_py("""
        local st = ns.EventLive:GetState(...)
        local bk = ns.EventEngine:BracketOf(ns.EventLive:GetDef(...), st)
        local out = {}
        for _, mid in ipairs(bk and bk.rounds[bk.r] or {}) do
          local m = bk.m[mid]
          if m.st == "play" then out[#out + 1] = { (m.a:gsub("%-.*", "")), (m.b:gsub("%-.*", "")), m.id } end
        end
        return out""", occ) or []


def duel(w, by, winner, loser):
    text = "%s has defeated %s in a duel" % (winner, loser)
    for n in (winner, loser):
        by[n].fire("CHAT_MSG_SYSTEM", text)
    w.tick(1)


# ------------------------------------------------------------------------------------------------------------------
# Shared look (UI/EventWidgets.lua)
# ------------------------------------------------------------------------------------------------------------------
@case
def a_class_circle_after_an_unknown_player_is_not_dark():
    w, c = one()
    col = c.eval_py("""
        local t = UIParent:CreateTexture()
        ns.EventUI:SetClass(t, 'Nobody-Nowhere')          -- unknown: the dark disc
        local dark = { t:GetVertexColor() }
        ns.EventUI:SetClass(t, 'Dummy1-Practice')         -- a known class (a dummy's)
        return { dark[1], { t:GetVertexColor() } }""")
    assert col[0] < 0.3, col
    assert col[1][:3] == [1, 1, 1], col
    w.assert_no_errors()


@case
def the_stage_progress_line_fits_its_width():
    w, c = one()
    out = c.eval_py("""
        local d = ns.EventBlocks:Starter()
        d.stages = {}
        for i = 1, 8 do d.stages[i] = { id = 's' .. i, name = 'Quarterfinals and more' } end
        local p = ns.EventUI:CreateProgress(UIParent)
        p:Set(d, { stage = 's3', phase = 'live' }, 'round 2 of 4')
        local wide = p:GetWidth()
        p:SetMaxWidth(420)
        p:Set(d, { stage = 's3', phase = 'live' }, 'round 2 of 4')
        local named = {}
        for i, it in ipairs(p.items) do if it.fs:IsShown() then named[#named + 1] = i end end
        return { wide, p:GetWidth(), named }""")
    assert out[0] > 420, out
    assert out[1] <= 420, out
    assert out[2] == [3], out                 # only the current stage keeps its name
    w.assert_no_errors()


@case
def relative_times_say_one_day_and_round_up_to_the_next_unit():
    w, c = one()
    got = c.eval_py("""
        local now = GetServerTime()
        local out = {}
        for i, d in ipairs({ 30, 600, 3580, -3580, 7200, 86000, 30 * 3600, -30 * 3600, 3 * 86400 }) do
          out[i] = ns.EventUI:Relative(now + d)
        end
        return out""")
    # (it said "in 1 days", "60 min", "24 h")
    assert got == ["now", "in 10 min", "in 1 h", "1 h ago", "in 2 h", "in 1 day", "in 1 day", "1 day ago", "in 3 days"], got
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The builder (UI/EventBuilder.lua)
# ------------------------------------------------------------------------------------------------------------------
@case
def opening_a_missing_event_opens_nothing_and_an_untouched_new_one_is_not_kept():
    w, c = one()
    n0 = len(c.chat_frame)
    assert c.eval("return ns.EventBuilder:Open('no-such-event')") is False
    assert not c.eval("return ns.EventBuilder:IsShown()")
    assert any("isn't in the library" in x for x in printed_since(c, n0)), printed_since(c, n0)
    # a new event closed before anything was done: no empty "New event" in the library (it would sync to the guild)
    c.eval("ns.EventBuilder:Open(nil); ns.EventBuilder:Close()")
    assert c.eval("return #ns.Events:GetDefs()") == 0
    # one that was changed is kept
    c.eval("ns.EventBuilder:Open(nil); ns.EventBuilder:AddNote(20, 20); ns.EventBuilder:Close()")
    assert c.eval("return #ns.Events:GetDefs()") == 1
    w.assert_no_errors()


@case
def undo_and_redo_keep_a_stage_and_a_smart_block_that_exist():
    w, c = one()
    open_starter(c, "s1")
    c.eval("ns.EventBuilder:AddStage()")
    c.eval("local S, ui = ns.EventBuilder:GetState(); ui.ask.field:SetText('Bonus'); ui.ask:Done()")
    assert c.eval("return ns.EventBuilder:GetState().stage") == "s5"
    c.eval("ns.EventBuilder:Undo()")
    # (the canvas said "Nothing runs in ? yet": the stage was gone)
    assert c.eval("return ns.EventBuilder:GetState().stage") == "s1"
    c.eval("ns.EventBuilder:Redo()")
    # a smart block added, opened, then undone: the builder leaves it (RenderTop errored on the missing block)
    c.eval("ns.EventBuilder:SelectStage('s3'); ns.EventBuilder:AddBlock('bracket')")
    bid = c.eval("local S = ns.EventBuilder:GetState(); for id, b in pairs(S.def.blocks) do if b.stage == 's3' then return id end end")
    c.eval("ns.EventBuilder:OpenInside(...)", bid)
    # (with the picker open on one of its pieces: closing it drew the canvas before the open block was checked)
    c.eval("local S = ns.EventBuilder:GetState(); local sc = S.builtIn[...][1]; "
           "ns.EventBuilder:OpenPicker(sc, sc.top, 1, { t = 'any' }, UIParent)", bid)
    c.eval("ns.EventBuilder:Undo()")
    assert c.eval("return ns.EventBuilder:GetState().inside") is None
    w.assert_no_errors()


@case
def undo_closes_the_picker_and_the_name_box():
    w, c = one()
    open_starter(c, "*")
    c.eval("local S = ns.EventBuilder:GetState(); local before = ns.EventBlocks.Copy(S.def); S.def.name = 'X'; "
           "table.insert(S.undo, before)")
    c.eval("""
        local S = ns.EventBuilder:GetState()
        local s
        for _, x in ipairs(S.def.scripts) do if x.id == 'c4' then s = x end end
        ns.EventBuilder:OpenPicker(s, s.top.n, 1, ns.EventBlocks.PIECES['pt.add'].args[1], UIParent)""")
    c.eval("ns.EventBuilder:Undo()")
    # (the picker held a piece of the event before the undo: what it picked went nowhere)
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.picker:IsShown() or S.pick ~= nil") is False
    # a name box open when the window closes doesn't come back over the next event
    c.eval("ns.EventBuilder:AddStage()")
    c.eval("ns.EventBuilder:Close()")
    open_starter(c, "s1")
    assert not c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.ask:IsShown()")
    w.assert_no_errors()


@case
def typed_numbers_and_text_are_kept_as_the_library_keeps_them():
    w, c = one()
    open_starter(c, "*")
    pick_num = """
        local S = ns.EventBuilder:GetState()
        local s
        for _, x in ipairs(S.def.scripts) do if x.id == 'c4' then s = x end end
        ns.EventBuilder:OpenPicker(s, s.top.n, 1, ns.EventBlocks.PIECES['pt.add'].args[1], UIParent)
        ns.EventBuilder:PickTyped(...)
        local S, ui = ns.EventBuilder:GetState()
        return { s.top.n.a[1], ui.picker:IsShown() }"""
    for bad in ("1e999", "99999999999", "nan", "inf"):
        v = c.eval_py(pick_num, bad)
        # refused, the picker stays (the library would have emptied the blank when saving)
        assert v == [5, True], (bad, v)
        c.eval("ns.EventBuilder:ClosePicker()")
    assert c.eval_py(pick_num, "-12")[0] == -12
    # text: no "|" codes, at most 200 bytes, the same as the library keeps
    c.eval("""
        local S = ns.EventBuilder:GetState()
        local p = ns.EventBlocks:New('ch.guild')
        local s = { id = 'zz', st = '*', x = 400, y = 400, top = { k = 'ev.happen', a = { 'duel' }, n = p } }
        table.insert(S.def.scripts, s)
        ns.EventBuilder:Refresh()
        ns.EventBuilder:OpenPicker(s, p, 1, ns.EventBlocks.PIECES['ch.guild'].args[1], UIParent)
        ns.EventBuilder:PickTyped('hi |cffff0000red|r ' .. string.rep('x', 300))
        ns.EventBuilder:Save()""")
    mine = c.eval("local S = ns.EventBuilder:GetState(); for _, x in ipairs(S.def.scripts) do "
                  "if x.id == 'zz' then return x.top.n.a[1] end end")
    lib = c.eval("local S = ns.EventBuilder:GetState(); for _, x in ipairs(ns.Events:GetDef(S.def.id).scripts) do "
                 "if x.id == 'zz' then return x.top.n.a[1] end end")
    assert "|" not in mine and len(mine) == 200, (len(mine), mine[:40])
    assert mine == lib
    w.assert_no_errors()


@case
def stage_names_are_clean_and_unique():
    w, c = one()
    open_starter(c, "s1")
    c.eval("ns.EventBuilder:RenameStage(nil, 's2')")
    c.eval("local S, ui = ns.EventBuilder:GetState(); ui.ask.field:SetText('sign-up'); ui.ask:Done()")
    st = c.eval_py("local S, ui = ns.EventBuilder:GetState(); return { ui.ask:IsShown(), ui.ask.err:GetText() }")
    assert st == [True, "Name already used"], st
    c.eval("local S, ui = ns.EventBuilder:GetState(); ui.ask.field:SetText('Bracket'); ui.ask:Done()")   # its own name
    assert not c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.ask:IsShown()")
    c.eval("ns.EventBuilder:RenameStage(nil, 's3')")
    c.eval("local S, ui = ns.EventBuilder:GetState(); ui.ask.field:SetText('Big |cffff0000final'); ui.ask:Done()")
    assert c.eval_py(STAGES) == ["Sign-up", "Bracket", "Big cffff0000final", "Prizes"]
    c.eval("ns.EventBuilder:AddStage()")
    c.eval("local S, ui = ns.EventBuilder:GetState(); ui.ask.field:SetText('Prizes'); ui.ask:Done()")
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.ask.err:GetText()") == "Name already used"
    w.assert_no_errors()


@case
def deleting_a_stage_keeps_the_open_one_and_takes_its_notes():
    w, c = one()
    open_starter(c, "s2")
    c.eval("ns.EventBuilder:AddNote(30, 30)")
    c.eval("ns.EventBuilder:SelectStage('s3')")
    c.eval("ns.EventBuilder:StageMenu(UIParent, 's2')")
    labels = [ch.get("text") for ch in (c.last_menu() or {}).get("children", [])]
    c.menu_select([t for t in labels if t and "Delete" in t][0])
    assert c.eval("return ns.EventBuilder:GetState().stage") == "s3"     # (it jumped to s1)
    assert c.eval("return #ns.EventBuilder:GetState().def.notes") == 0
    w.assert_no_errors()


@case
def the_stage_strip_fits_between_the_name_and_the_buttons():
    w, c = one()
    c.eval("__MOCK.real_geometry = true")
    fit = """
        local S, ui = ns.EventBuilder:GetState()
        local top, strip = ui.top, S.practice and ui.top.prac.strip or ui.top.strip
        local right = S.practice and top.board:GetLeft() or top.undo:GetLeft()
        local num = {}
        for _, p in ipairs(S.practice and top.prac.pills or top.pills) do
          if p:IsShown() and p.stage and p.stage ~= '*' and not p.fs:IsShown() then num[#num + 1] = p.tipTitle or '?' end
        end
        -- (the name is the banner's title: the strip has the tool row under it)
        return { strip:GetRight(), right, num, top.banner:GetBottom() >= strip:GetTop() and strip:GetLeft() >= top:GetLeft() }"""
    # the starter plus a stage named "Bonus round" pushed Always under undo
    c.eval("local d = ns.Events:NewDef(true); table.insert(d.stages, { id = 's5', name = 'Bonus round' }); "
           "ns.Events:SaveDef(d); ns.EventBuilder:Open(ns.Events:GetDef(d.id), { stage = 's2' })")
    r = c.eval_py(fit)
    assert r[0] <= r[1] and r[3], r
    # 8 long names: stages by number (the farthest from the open one first), their names in the tooltip
    eight = """
        local d = ns.Events:NewDef(true)
        d.name = ...
        d.stages = {}
        for i = 1, 8 do d.stages[i] = { id = 's' .. i, name = 'Long stage name ' .. i } end
        ns.Events:SaveDef(d)
        ns.EventBuilder:Open(ns.Events:GetDef(d.id), { stage = 's4' })"""
    c.eval(eight, "Friday duel cup")
    r = c.eval_py(fit)
    assert r[0] <= r[1] and r[3], r
    assert "Long stage name 8" in r[2] and "Long stage name 4" not in r[2], r
    # and with the longest event name
    c.eval(eight, "W" * 40)
    r = c.eval_py(fit)
    assert r[0] <= r[1] and r[3], r
    # the practice run's strip too
    c.eval("ns.EventBuilder:StartPractice()")
    w.tick(0.5)
    r = c.eval_py(fit)
    assert r[0] <= r[1], r
    c.eval("ns.EventBuilder:StopPractice(); __MOCK.real_geometry = nil")
    w.assert_no_errors()


@case
def a_newer_version_from_elsewhere_comes_into_the_builder():
    w, c = one()
    did = open_starter(c, "s1")
    # my other client saves the event (what the sync stores is the same: a newer revision)
    c.eval("local d = ns.EventBlocks.Copy(ns.Events:GetDef(...)); d.name = 'Changed elsewhere'; ns.Events:SaveDef(d)", did)
    w.tick(1)
    st = c.eval_py("local S = ns.EventBuilder:GetState(); return { S.def.name, S.def.rev == ns.Events:GetDef(S.def.id).rev, S.dirty }")
    assert st == ["Changed elsewhere", True, False], st
    # with unsaved work here: kept, and said once
    c.eval("ns.EventBuilder:AddNote(10, 10)")
    n0 = len(c.chat_frame)
    c.eval("local d = ns.EventBlocks.Copy(ns.Events:GetDef(...)); d.name = 'Again'; ns.Events:SaveDef(d)", did)
    w.tick(1)
    assert c.eval("local S = ns.EventBuilder:GetState(); return #S.def.notes") == 1
    assert any("changed somewhere else" in x for x in printed_since(c, n0)), printed_since(c, n0)
    w.assert_no_errors()


@case
def someone_elses_event_open_read_only_follows_its_owner():
    w = World()
    a = Client(w, "Gina", guild_rank=0)
    b = Client(w, "Bert", guild_rank=3)
    for x in (a, b):
        x.load_addon()
    w.tick(HELLO)
    did = open_starter(a, "s1")
    w.tick(3)
    b.eval("ns.EventBuilder:Open(...)", did)
    a.eval("local S = ns.EventBuilder:GetState(); S.def.name = 'Gina cup 2'; ns.EventBuilder:Save()")
    w.tick(3)
    assert b.eval("return ns.EventBuilder:GetState().def.name") == "Gina cup 2"
    assert b.eval("return ns.EventBuilder:GetState().readOnly") is True
    w.assert_no_errors()


@case
def an_event_deleted_elsewhere_is_saved_as_a_new_one():
    w, c = one()
    did = open_starter(c, "s1")
    c.eval("ns.EventBuilder:AddNote(10, 10)")
    n0 = len(c.chat_frame)
    c.eval("ns.Events:DeleteDef(...)", did)        # (an officer, or my other client)
    w.tick(1)
    assert any("was deleted" in x for x in printed_since(c, n0)), printed_since(c, n0)
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.top.primary:GetText()") == "Save"
    # (the library keeps a deleted event deleted: Save failed without a word, closing lost the work)
    assert c.eval("return ns.EventBuilder:Save()") is True
    new = c.eval("return ns.EventBuilder:GetState().def.id")
    assert new != did and c.eval("return ns.Events:GetDef(...) ~= nil", new)
    assert c.eval("return #ns.Events:GetDef(...).notes", new) == 1
    w.assert_no_errors()


@case
def notes_count_as_a_change():
    w, c = one()
    did = open_starter(c, "s1")
    c.eval("ns.EventBuilder:AddNote(10, 10)")
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return S.dirty and ui.top.primary:GetText()") == "Save"
    c.eval("local S = ns.EventBuilder:GetState(); S.def.notes[1].text = 'hello'; ns.EventBuilder:Close()")
    assert c.eval("return ns.Events:GetDef(...).notes[1].text", did) == "hello"
    w.assert_no_errors()


@case
def the_picker_stays_on_the_screen_and_under_its_blank():
    w, c = one()
    c.eval("__MOCK.real_geometry = true")
    open_starter(c, "*")
    # the window in the screen's bottom right corner, a script with a number blank in the canvas' corner
    r = c.eval_py("""
        local S, ui = ns.EventBuilder:GetState()
        local win = ns.EventBuilder:GetWindow()
        win:ClearAllPoints()
        win:SetPoint('BOTTOMRIGHT', UIParent, 'BOTTOMRIGHT', 0, 0)
        local s
        for _, x in ipairs(S.def.scripts) do if x.id == 'c4' then s = x end end
        s.x, s.y = math.floor(ui.cv:GetWidth() - 120), math.floor(ui.cv:GetHeight() - 60)
        ns.EventBuilder:Refresh()
        ns.EventBuilder:OpenPicker(s, s.top.n, 1, ns.EventBlocks.PIECES['pt.add'].args[1], UIParent)
        local p = ui.picker
        -- the blank it is for, drawn again (the frame first passed is back in the pool)
        local bf
        for _, bl in ipairs(ui.scripts[s].blanks) do if bl.piece == s.top.n and bl.slot == 1 then bf = bl.frame end end
        local _, rel = p:GetPoint(1)
        local k = p:GetEffectiveScale() / UIParent:GetEffectiveScale()
        return { p:GetLeft() * k, p:GetBottom() * k, p:GetRight() * k, p:GetTop() * k, UIParent:GetWidth(), UIParent:GetHeight(),
                 rel == bf }""")
    # (it hung off the screen's right and bottom edges: the code said "over it when there is no room", but wasn't)
    assert r[0] >= 0 and r[1] >= 0 and r[2] <= r[4] + 0.5 and r[3] <= r[5] + 0.5, r
    assert r[6] is True, r
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()


@case
def a_search_that_finds_nothing_says_so():
    w, c = one()
    open_starter(c, "*")
    shown = "local S, ui = ns.EventBuilder:GetState(); return ui.pal.none ~= nil and ui.pal.none:IsShown()"
    for q in ("zzz", "(", "%"):
        c.eval("local S = ns.EventBuilder:GetState(); S.search = ...; ns.EventBuilder:RenderPalette()", q)
        assert c.eval(shown), q
    c.eval("local S = ns.EventBuilder:GetState(); S.search = 'show'; ns.EventBuilder:RenderPalette()")
    assert not c.eval(shown)
    w.assert_no_errors()


@case
def a_new_note_gets_the_focus():
    w, c = one()
    open_starter(c, "s1")
    c.eval("ns.EventBuilder:AddNote(10, 10); ns.EventBuilder:AddNote(10, 100); ns.EventBuilder:AddNote(10, 200)")
    c.eval("ns.EventBuilder:SelectStage('s3'); ns.EventBuilder:AddNote(300, 300)")
    # (the last frame made was focused: a hidden one of another stage)
    r = c.eval_py("local S, ui = ns.EventBuilder:GetState(); local o = {}; for _, f in ipairs(ui.notes) do "
                  "if f.eb:HasFocus() then o[#o + 1] = { f.index, f:IsShown() } end end; return o")
    assert r == [[4, True]], r
    w.assert_no_errors()


@case
def dropping_on_the_palette_takes_it_away():
    w, c = one()
    open_starter(c, "*")
    c.eval("__MOCK.real_geometry = true")
    c.eval(MOUSE)
    count = "return #ns.EventBuilder:GetState().def.scripts"
    n = c.eval(count)
    # a new piece let go over the palette: nothing added
    c.eval("""
        MOUSE_DOWN = true
        MOUSE_X, MOUSE_Y = 0, 0
        ns.EventBuilder:PressNew(ns.EventBlocks:New('ch.tell'))
        MOUSE_X, MOUSE_Y = -100, 100
        ns.EventBuilder:OnCanvasUpdate()
        MOUSE_DOWN = false
        ns.EventBuilder:OnCanvasUpdate()""")
    assert c.eval(count) == n
    # a script dragged onto the palette: gone
    c.eval("""
        local S, ui = ns.EventBuilder:GetState()
        local s
        for x in pairs(ui.scripts) do if x.id == 'c3' then s = x end end
        local pf = ui.scripts[s].at[s.top]
        MOUSE_DOWN = true
        MOUSE_X, MOUSE_Y = s.x + 20, s.y + 20
        pf:GetScript('OnMouseDown')(pf, 'LeftButton')
        MOUSE_X = s.x + 40
        ns.EventBuilder:OnCanvasUpdate()
        MOUSE_X, MOUSE_Y = -100, 100
        ns.EventBuilder:OnCanvasUpdate()
        MOUSE_DOWN = false
        ns.EventBuilder:OnCanvasUpdate()""")
    assert c.eval(count) == n - 1
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()


@case
def the_orange_pill_opens_a_smart_block_with_a_problem():
    w, c = one()
    open_starter(c, "s2")
    c.eval("ns.EventBuilder:OpenInside('b2'); ns.EventBuilder:CopyInner(); ns.EventBuilder:CloseInside()")
    c.eval("""
        local S = ns.EventBuilder:GetState()
        local done
        for _, s in ipairs(S.def.blocks.b2.inner) do
          ns.EventBlocks:Walk(s.top, function(p)
            local pd = ns.EventBlocks.PIECES[p.k]
            for i, a in ipairs(pd and not done and pd.args or {}) do
              if (a.t == 'player' or a.t == 'players') and p.a[i] ~= nil then p.a[i] = nil; done = true end
            end
          end)
        end
        ns.EventBuilder:SelectStage('s1')""")
    # its stage shows the warning dot, the pill takes me into the block (it did nothing: the script is the block's)
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); for _, p in ipairs(ui.top.pills) do "
                  "if p.stage == 's2' then return p.dot:IsShown() end end")
    c.eval("ns.EventBuilder:JumpToProblem()")
    assert c.eval_py("local S = ns.EventBuilder:GetState(); return { S.stage, S.inside }") == ["s2", "b2"]
    w.assert_no_errors()


@case
def undo_and_redo_stay_clickable_and_say_why_nothing_happens():
    w, c = one()
    open_starter(c, "s1")
    st = c.eval_py("local S, ui = ns.EventBuilder:GetState(); return { ui.top.undo:IsEnabled(), ui.top.redo:IsEnabled(), "
                   "ui.top.undo.tipText }")
    assert st[0] and st[1] and "nothing to undo" in st[2], st
    n0 = len(c.chat_frame)
    c.eval("local S, ui = ns.EventBuilder:GetState(); ui.top.undo:Click()")
    assert any("nothing to undo" in x for x in printed_since(c, n0))
    w.assert_no_errors()


@case
def one_gold_button_inside_a_built_in_smart_block():
    w, c = one()
    open_starter(c, "s2")
    c.eval("ns.EventBuilder:OpenInside('b2')")
    gold = "local S, ui = ns.EventBuilder:GetState(); return { ui.top.primary.kind, ui.ribbon.btn.kind }"
    # (Save / Host and Make my own copy were both gold)
    assert c.eval_py(gold) == ["secondary", "primary"], c.eval_py(gold)
    c.eval("ns.EventBuilder:CopyInner()")
    assert c.eval_py(gold) == ["primary", "secondary"], c.eval_py(gold)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The board and the tracker (UI/EventBoard.lua, UI/EventTracker.lua)
# ------------------------------------------------------------------------------------------------------------------
@case
def a_hosts_sheet_goes_when_hosting_is_handed_over():
    w, cs, by, host, occ = start_cup()
    host.eval("ns.EventBoard:Open(...)", occ)
    # Remove a player (its sheet open), then hosting goes to Bert (from my other menu, or a takeover)
    host.eval("ns.EventBoard:GetWindow().hostbar.more:Click()")
    labels = [ch.get("text") for ch in (host.last_menu() or {}).get("children", [])]
    rem = [t for t in labels if t and "Remove a player" in t][0]
    sub = [ch for ch in host.last_menu()["children"] if ch.get("text") == rem][0]
    cora = [ch.get("text") for ch in sub.get("children", []) if "Cora" in strip_codes(ch.get("text") or "")][0]
    host.menu_select(cora)
    assert host.eval("return ns.EventBoard:GetWindow().confirm:IsShown()")
    host.eval("ns.EventLive:HandOver(..., 'Bert-Thunderstrike')", occ)
    w.tick(5)
    # (it stayed, and its Remove did nothing: I don't host any more)
    assert not host.eval("return ns.EventBoard:GetWindow().confirm:IsShown()")
    w.assert_no_errors()


@case
def the_board_header_fits_long_stage_names():
    w, c = one()
    c.eval("""
        local d = ns.EventBlocks:Starter()
        for i, n in ipairs({ 'Sign-up and warm up', 'Quarterfinals and more', 'The finals tonight', 'Prizes and badges' }) do
          d.stages[i].name = n
        end
        for i = 5, 8 do d.stages[i] = { id = 's' .. i, name = 'Long stage name ' .. i } end
        ns.EventLive:StartPractice(d, 8)
        ns.EventBoard:Open('practice')""")
    w.tick(0.5)
    r = c.eval_py("local f = ns.EventBoard:GetWindow(); return { f.hdr.prog:GetWidth(), f.hdr.prog.maxW }")
    assert r[1] and r[0] <= r[1], r
    c.eval("ns.EventLive:StopPractice(); ns.EventBoard:Close()")
    w.assert_no_errors()


@case
def the_tracker_says_loser_of_for_the_3rd_place_match():
    w, cs, by, host, occ = start_cup()
    a, b, mid = [m for m in playing(host, occ) if "Gina" not in m[:2]][0]
    for _ in range(3):
        duel(w, by, a, b)
        w.tick(2)
    l1 = strip_codes(by[b].eval("return ns.EventTracker:GetFrames().tracker.l1:GetText()"))
    # (it said "winner of": the 3rd place match takes the other semifinal's loser)
    assert l1.startswith("3rd place match: you vs loser of"), l1
    w.assert_no_errors()


@case
def a_question_of_an_event_that_ended_goes():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain", "Wade"])
    by = {c.name: c for c in cs}
    occs = []
    for hname in ("Gina", "Wade"):
        occs.append(by[hname].eval_py("local d = ns.Events:NewDef(true); assert(ns.Events:SaveDef(d)); "
                                      "return ns.Events:Schedule(d.id, GetServerTime() + 30)"))
    w.tick(5)
    for occ in occs:
        for n in ("Bert", "Cora", "Dain"):
            by[n].eval("return ns.Events:SignUp(...)", occ, True)
    w.tick(5)
    for hname, occ in zip(("Gina", "Wade"), occs):
        assert by[hname].eval_py("return { ns.EventLive:Start(...) }", occ)[0] is True
    w.tick(5)
    bert = by["Bert"]
    cur = bert.eval("ns.EventTracker:Refresh(); return ns.EventTracker:GetOcc()")
    other = [o for o in occs if o != cur][0]
    # a "who won" question of the other event is up (its game was disputed); then that event ends
    bert.eval("ns.EventTracker:ShowAsk(..., ns.EventLive:GetState(...), nil, { id = 99, opts = { 'Bert-Thunderstrike', "
              "'Cora-Thunderstrike' }, to = { 'Bert-Thunderstrike' }, ans = {} })", other, other)
    host = by["Gina"] if other == occs[0] else by["Wade"]
    host.eval("ns.EventLive:EndEvent(...)", other)
    w.tick(5)
    bert.eval("ns.EventTracker:Refresh()")
    assert bert.eval("return ns.EventTracker:GetOcc()") == cur
    assert not bert.eval("return ns.EventTracker:GetFrames().ask:IsShown()")
    w.assert_no_errors()


@case
def a_removed_player_has_no_match_ahead():
    w, cs, by, host, occ = start_cup()
    # the host takes herself out (she only hosts now): her later matches are walkovers, not hers to play
    host.eval("ns.EventLive:RemovePlayer(..., 'Gina-Thunderstrike')", occ)
    w.tick(3)
    l1 = strip_codes(host.eval("ns.EventTracker:Refresh(); return ns.EventTracker:GetFrames().tracker.l1:GetText()"))
    # (it said "3rd place match: you vs loser of Bert / Cora")
    assert l1.startswith("You're hosting"), l1
    host.eval("ns.EventBoard:Open(...)", occ)
    assert not host.eval("return ns.EventBoard:GetWindow().hdr.chip:IsShown()")
    w.assert_no_errors()


@case
def a_bracket_with_too_few_players_shows_who_was_there():
    w, cs = guild(["Gina", "Bert"])
    host = cs[0]
    occ = host.eval_py("""
        local d = ns.Events:NewDef(true)
        d.scripts = {}; d.blocks.b1 = nil; d.blocks.b2.stage = 's1'      -- the bracket at once, nobody else
        assert(ns.Events:SaveDef(d)); return ns.Events:Schedule(d.id, GetServerTime() + 30)""")
    w.tick(5)
    assert host.eval_py("return { ns.EventLive:Start(...) }", occ)[0] is True
    w.tick(3)
    host.eval("ns.EventBoard:Open(...)", occ)
    w.tick(1)
    r = host.eval_py("""
        local f = ns.EventBoard:GetWindow()
        local rows = 0
        for _, r in ipairs(f.br.rows) do if r:IsShown() then rows = rows + 1 end end
        return { f.br.champ:IsShown(), f.br.note:IsShown() and f.br.note:GetText(), rows }""")
    # (an empty bracket with an empty champion's slot)
    assert r == [False, "Too few players for a bracket.", 1], r
    w.assert_no_errors()


@case
def add_a_player_says_why_once_the_sign_up_has_closed():
    w, cs, by, host, occ = start_cup()
    host.eval("ns.EventBoard:Open(...)", occ)
    host.eval("ns.EventBoard:GetWindow().hostbar.more:Click()")
    entry = [ch for ch in host.last_menu()["children"] if "Add a player" in strip_codes(ch.get("text") or "")][0]
    # (it listed the online members, and adding one always failed: the engine takes nobody after the sign-up)
    assert not entry.get("children"), entry
    n0 = len(host.chat_frame)
    host.menu_select(entry["text"])
    assert any("sign-up has closed" in x for x in printed_since(host, n0)), printed_since(host, n0)
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
