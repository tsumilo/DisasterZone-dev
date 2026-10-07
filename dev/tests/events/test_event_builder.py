"""The event builder (UI/EventBuilder.lua, UI/EventPieces.lua): opening events, the picker, drag and drop (the cursor
and the mouse button are stubbed: the mock has no mouse), saving and syncing, someone else's event read-only, practice
runs, opening a smart block and making its own copy, undo / redo.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_event_builder.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

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


def one(name="Gina", rank=0):
    w = World()
    c = Client(w, name, guild_rank=rank, class_file="ROGUE")
    c.load_addon()
    w.tick(3)
    return w, c


def open_starter(c, stage="s2"):
    return c.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); "
                  "ns.EventBuilder:Open(ns.Events:GetDef(d.id), { stage = ... }); return d.id", stage)


def script_of(c, sid):
    return c.eval_py("local S = ns.EventBuilder:GetState(); for _, s in ipairs(S.def.scripts) do "
                     "if s.id == ... then return { x = s.x, y = s.y, k = s.top.k, n = s.top.n and s.top.n.k, "
                     "nn = s.top.n and s.top.n.n and s.top.n.n.k } end end", sid)


@case
def it_opens_every_stage_of_the_starter():
    w, c = one()
    open_starter(c, "s1")
    for st in ("s1", "s2", "s3", "s4", "*"):
        c.eval("ns.EventBuilder:SelectStage(...)", st)
        w.tick(0.2)
    n = c.eval("local S, ui = ns.EventBuilder:GetState(); local n = 0; for _ in pairs(ui.scripts) do n = n + 1 end; return n")
    assert n == 4, n          # Always: final is set, match ends, goes offline, Matches done
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.status.fs:GetText()") == "Ready to practice"
    w.assert_no_errors()


@case
def the_picker_fills_a_blank():
    w, c = one()
    open_starter(c, "*")
    # empty the "show"'s players (under "when Matches final is set"), then pick "both players" for it in the picker
    c.eval("""
        local S = ns.EventBuilder:GetState()
        local s
        for _, x in ipairs(S.def.scripts) do if x.id == 'c3' then s = x end end
        s.top.n.a[1] = nil
        ns.EventBuilder:Refresh()
        local B = ns.EventBlocks
        ns.EventBuilder:OpenPicker(s, s.top.n, 1, B.PIECES['ch.show'].args[1], UIParent)""")
    status = c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.status.fs:GetText()")
    assert "needs" in status, status
    rows = c.eval_py("local S, ui = ns.EventBuilder:GetState(); local out = {}; for _, r in ipairs(ui.picker.rows) do "
                     "if r:IsShown() then out[#out + 1] = r.choice.k == 'ctx' and r.choice.a[1] or r.choice.k end end; return out")
    assert rows[:3] == ["player1", "player2", "both"], rows
    c.eval("local S, ui = ns.EventBuilder:GetState(); for _, r in ipairs(ui.picker.rows) do "
           "if r:IsShown() and r.choice.k == 'ctx' and r.choice.a[1] == 'both' then r:Click() end end")
    w.tick(0.2)
    assert c.eval("local S = ns.EventBuilder:GetState(); for _, x in ipairs(S.def.scripts) do "
                  "if x.id == 'c3' then return x.top.n.a[1].a[1] end end") == "both"
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.status.fs:GetText()") == "Ready to practice"
    # a typed number
    c.eval("""
        local S = ns.EventBuilder:GetState()
        local s
        for _, x in ipairs(S.def.scripts) do if x.id == 'c4' then s = x end end
        ns.EventBuilder:OpenPicker(s, s.top.n, 1, ns.EventBlocks.PIECES['pt.add'].args[1], UIParent)
        ns.EventBuilder:PickTyped('7')""")
    assert c.eval("local S = ns.EventBuilder:GetState(); for _, x in ipairs(S.def.scripts) do "
                  "if x.id == 'c4' then return x.top.n.a[1] end end") == 7
    w.assert_no_errors()


@case
def a_dragged_piece_snaps_under_a_hat():
    w, c = one()
    open_starter(c, "*")
    c.eval(MOUSE)
    before = script_of(c, "c3")
    assert before["n"] == "ch.show"
    # a "tell" from the palette, dropped just under "when Matches final is set" (wherever the example puts it: its
    # body ends 42 under its top)
    c.eval("""
        MOUSE_DOWN = true
        MOUSE_X, MOUSE_Y = 0, 0
        ns.EventBuilder:PressNew(ns.EventBlocks:New('ch.tell'))
        local c3
        for _, s in ipairs(ns.EventBuilder:GetState().def.scripts) do if s.id == 'c3' then c3 = s end end
        MOUSE_X, MOUSE_Y = c3.x + 12 + 4, c3.y + 42 + 12 + 3
        ns.EventBuilder:OnCanvasUpdate()
        ns.EventBuilder:OnCanvasUpdate()""")
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.ghost:IsShown()")
    c.eval("MOUSE_DOWN = false; ns.EventBuilder:OnCanvasUpdate()")
    after = script_of(c, "c3")
    assert after["n"] == "ch.tell" and after["nn"] == "ch.show", after
    # dropped far from everything: a script of its own
    c.eval("""
        MOUSE_DOWN = true
        MOUSE_X, MOUSE_Y = 0, 0
        ns.EventBuilder:PressNew(ns.EventBlocks:New('ev.happen'))
        MOUSE_X, MOUSE_Y = 600, 450
        ns.EventBuilder:OnCanvasUpdate()
        MOUSE_DOWN = false
        ns.EventBuilder:OnCanvasUpdate()""")
    n = c.eval("local S = ns.EventBuilder:GetState(); local n = 0; for _, s in ipairs(S.def.scripts) do "
               "if s.st == '*' then n = n + 1 end end; return n")
    assert n == 5, n
    # undo takes the last one back, redo puts it again
    c.eval("ns.EventBuilder:Undo()")
    n2 = c.eval("local S = ns.EventBuilder:GetState(); local n = 0; for _, s in ipairs(S.def.scripts) do "
                "if s.st == '*' then n = n + 1 end end; return n")
    assert n2 == 4, n2
    c.eval("ns.EventBuilder:Redo()")
    w.assert_no_errors()


@case
def a_value_drops_into_a_blank_that_takes_it():
    w, c = one()
    open_starter(c, "*")
    c.eval(MOUSE)
    # the "show"'s players blank: find where it is, drop "the host" on it
    pos = c.eval_py("""
        local S, ui = ns.EventBuilder:GetState()
        for s, f in pairs(ui.scripts) do
          if s.id == 'c3' then
            for _, bl in ipairs(f.blanks) do
              if bl.piece.k == 'ch.show' and bl.slot == 1 then
                local x, y = ns.EventPieces:Abs(bl.frame)
                return { s.x + x + 8, s.y + y + 6 }
              end
            end
            -- the blank holds a value piece: its frame
            for p, pf in pairs(f.at) do
              if p.k == 'pl.tagged' then   -- ("players with tag Entrants")
                local x, y = ns.EventPieces:Abs(pf)
                return { s.x + x + 8, s.y + y + 6, 'value' }
              end
            end
          end
        end""")
    assert pos, pos
    # empty it first, so the blank is a blank
    c.eval("local S = ns.EventBuilder:GetState(); for _, x in ipairs(S.def.scripts) do if x.id == 'c3' then x.top.n.a[1] = nil end end; "
           "ns.EventBuilder:Refresh()")
    pos = c.eval_py("""
        local S, ui = ns.EventBuilder:GetState()
        for s, f in pairs(ui.scripts) do
          if s.id == 'c3' then
            for _, bl in ipairs(f.blanks) do
              if bl.piece.k == 'ch.show' and bl.slot == 1 then
                local x, y = ns.EventPieces:Abs(bl.frame)
                return { s.x + x + 8, s.y + y + 6 }
              end
            end
          end
        end""")
    c.eval("""
        MOUSE_DOWN = true
        MOUSE_X, MOUSE_Y = 0, 0
        ns.EventBuilder:PressNew(ns.EventBlocks:New('pl.host'))
        MOUSE_X, MOUSE_Y = ...
        ns.EventBuilder:OnCanvasUpdate()
        ns.EventBuilder:OnCanvasUpdate()""", pos[0], pos[1])
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.slotHl:IsShown()")
    c.eval("MOUSE_DOWN = false; ns.EventBuilder:OnCanvasUpdate()")
    assert c.eval("local S = ns.EventBuilder:GetState(); for _, x in ipairs(S.def.scripts) do "
                  "if x.id == 'c3' then return x.top.n.a[1].k end end") == "pl.host"
    w.assert_no_errors()


@case
def saving_syncs_and_others_see_it_read_only():
    w = World()
    a = Client(w, "Gina", guild_rank=0)
    b = Client(w, "Bert", guild_rank=3)
    for x in (a, b):
        x.load_addon()
    w.tick(50)
    def_id = open_starter(a, "s1")
    a.eval("local S = ns.EventBuilder:GetState(); S.def.name = 'Gina cup'; ns.EventBuilder:Save()")
    w.tick(3)
    assert b.eval("return ns.Events:GetDef(...).name", def_id) == "Gina cup"
    b.eval("ns.EventBuilder:Open(...)", def_id)
    assert b.eval("local S, ui = ns.EventBuilder:GetState(); return S.readOnly and ui.top.primary:GetText()") == "Make a copy"
    b.eval("ns.EventBuilder:Primary()")
    w.tick(3)
    mine = b.eval_py("local S = ns.EventBuilder:GetState(); return { S.def.by, S.def.from, S.readOnly or false }")
    assert mine == ["Bert-Thunderstrike", def_id, False], mine
    assert a.eval("local n = 0; for _, d in ipairs(ns.Events:GetDefs()) do n = n + 1 end; return n") == 2
    w.assert_no_errors()


@case
def practice_runs_glow_and_log_and_count_as_practised():
    w, c = one()
    def_id = open_starter(c, "s1")
    c.eval("local S = ns.EventBuilder:GetState(); S.def.blocks.b2.set.bo = 1; S.def.blocks.b2.set.fbo = 1; "
           "ns.EventBuilder:Save(); ns.EventBuilder:StartPractice()")
    w.tick(1)
    st = c.eval_py("local st = ns.EventLive:GetState('practice'); return { st.phase, st.stage, #st.entrants }")
    assert st == ["live", "s2", 16], st
    shown = c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.dp:IsShown() and ui.log:IsShown() and not ui.pal:IsShown()")
    assert shown
    # play it out with the panel's buttons
    for guard in range(40):
        live = c.eval("return ns.EventLive:GetState('practice').phase")
        if live != "live":
            break
        c.eval("local S, ui = ns.EventBuilder:GetState(); local m = ui.dp.matches[1]; if m:IsShown() then m.b1:Click() "
               "else ns.EventLive:PracticeSkip() end")
        w.tick(0.3)
    assert c.eval("return ns.EventLive:GetState('practice').phase") == "done"
    log = c.eval_py("local S = ns.EventBuilder:GetState(); local out = {}; for _, e in ipairs(S.log) do out[#out + 1] = e.text end; "
                    "return out")
    assert any("wins the Friday duel cup" in t for t in log), log[-6:]
    assert c.eval("return (ns.EventBuilder:WasPracticed(...))", def_id) is True
    c.eval("ns.EventBuilder:StopPractice()")
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.pal:IsShown()")
    w.assert_no_errors()


@case
def opening_the_bracket_shows_its_own_pieces_locked_until_copied():
    w, c = one()
    open_starter(c, "s2")
    c.eval("ns.EventBuilder:OpenInside('b2')")
    n = c.eval("local S, ui = ns.EventBuilder:GetState(); local n = 0; for _ in pairs(ui.scripts) do n = n + 1 end; return n")
    assert n == 5, n
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.ribbon:IsShown() and ui.ribbon.btn:GetText()") == \
        "Make my own copy"
    c.eval("ns.EventBuilder:CopyInner()")
    assert c.eval("local S = ns.EventBuilder:GetState(); return #S.def.blocks.b2.inner") == 5
    # its own copy runs (a practice run goes through)
    c.eval("ns.EventBuilder:CloseInside(); local S = ns.EventBuilder:GetState(); S.def.blocks.b2.set.bo = 1; "
           "S.def.blocks.b2.set.fbo = 1; ns.EventBuilder:StartPractice()")
    for guard in range(40):
        if c.eval("return ns.EventLive:GetState('practice').phase") != "live":
            break
        c.eval("local run = ns.EventLive:GetPractice(); local bk = run:MainBracket(); "
               "for _, mid in ipairs(bk.rounds[bk.r] or {}) do local m = bk.m[mid]; if m.st == 'play' then "
               "ns.EventLive:PracticeDuel(m.a, m.b) end end; ns.EventLive:PracticeSkip()")
    assert c.eval("return ns.EventLive:GetState('practice').phase") == "done"
    w.assert_no_errors()


@case
def stages_are_added_renamed_and_deleted():
    w, c = one()
    open_starter(c, "s1")
    c.eval("ns.EventBuilder:AddStage()")
    c.eval("local S, ui = ns.EventBuilder:GetState(); ui.ask.field:SetText('Bonus'); ui.ask:Done()")
    names = c.eval_py("local S = ns.EventBuilder:GetState(); local out = {}; for _, s in ipairs(S.def.stages) do "
                      "out[#out + 1] = s.name end; return out")
    assert names == ["Sign-up", "Bracket", "Finals", "Prizes", "Bonus"], names
    assert c.eval("local S = ns.EventBuilder:GetState(); return S.stage") == "s5"
    w.assert_no_errors()


@case
def zoom_steps_ease_and_keep_the_point_under_the_cursor():
    w, c = one()
    open_starter(c, "*")
    c.eval("__MOCK.real_geometry = true")
    # a fake cursor in UI units, over the canvas
    c.eval("""
        CUR_X, CUR_Y = 0, 0
        GetCursorPosition = function() local s = UIParent:GetEffectiveScale(); return CUR_X * s, CUR_Y * s end
        local S, ui = ns.EventBuilder:GetState()
        CUR_X = ui.cv:GetLeft() + 300
        CUR_Y = ui.cv:GetTop() - 200""")
    under = ("local S, ui = ns.EventBuilder:GetState(); local c = ui.content; local s = c:GetEffectiveScale(); "
             "local x, y = GetCursorPosition(); return { x / s - c:GetLeft(), c:GetTop() - y / s }")
    before = c.eval_py(under)
    c.eval("ns.EventBuilder:Zoom(1, true)")
    w.tick(0.05)
    mid = c.eval("local S = ns.EventBuilder:GetState(); return S.view.z")
    assert 1 < mid < 1.1, mid                      # still easing
    w.tick(0.5)
    assert c.eval("local S = ns.EventBuilder:GetState(); return S.view.z") == 1.1
    after = c.eval_py(under)
    assert abs(after[0] - before[0]) < 0.5 and abs(after[1] - before[1]) < 0.5, (before, after)
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.zoom.pct:GetText()") == "110%"
    # quick wheel steps add up: two more in go to 150%, and out again lands on the round steps
    c.eval("ns.EventBuilder:Zoom(1, true); ns.EventBuilder:Zoom(1, true)")
    w.tick(0.5)
    assert c.eval("local S = ns.EventBuilder:GetState(); return S.view.z") == 1.5
    c.eval("ns.EventBuilder:Zoom(1, true)")       # past the top: stays
    w.tick(0.5)
    assert c.eval("local S = ns.EventBuilder:GetState(); return S.view.z") == 1.5
    for z in (1.25, 1.1, 1, 0.9, 0.8, 0.67, 0.5, 0.5):
        c.eval("ns.EventBuilder:Zoom(-1)")
        w.tick(0.5)
        assert c.eval("local S = ns.EventBuilder:GetState(); return S.view.z") == z, z
    # the percentage takes it back to 100%
    c.eval("local S, ui = ns.EventBuilder:GetState(); ui.zoom.reset:Click()")
    w.tick(0.5)
    assert c.eval("local S = ns.EventBuilder:GetState(); return S.view.z") == 1
    # panning follows the mouse one to one at any zoom
    c.eval("ns.EventBuilder:ZoomTo(0.67, nil, nil, true)")
    before = c.eval_py(under)
    c.eval("""
        IsMouseButtonDown = function() return true end
        local S, ui = ns.EventBuilder:GetState()
        ui.cv:GetScript('OnMouseDown')(ui.cv, 'LeftButton')
        CUR_X = CUR_X + 100; CUR_Y = CUR_Y - 50
        ns.EventBuilder:OnCanvasUpdate()
        IsMouseButtonDown = function() return false end
        ns.EventBuilder:OnCanvasUpdate()""")
    after = c.eval_py(under)
    # the same content point is still under the cursor that moved with it
    assert abs(after[0] - before[0]) < 0.5 and abs(after[1] - before[1]) < 0.5, (before, after)
    # zoom to fit shows everything inside the canvas (the rebuilt starter's Always stage is wider than the canvas: it
    # fits below 100%, so the scripts' edges are read in the canvas' own scale)
    c.eval("ns.EventBuilder:ZoomToFit()")
    w.tick(0.5)
    inside = c.eval_py("""
        local S, ui = ns.EventBuilder:GetState()
        local l, t, r, b = ui.cv:GetLeft(), ui.cv:GetTop(), ui.cv:GetRight(), ui.cv:GetBottom()
        local out = {}
        for s, f in pairs(ui.scripts) do
          local k = f:GetEffectiveScale() / ui.cv:GetEffectiveScale()
          out[#out + 1] = f:GetLeft() * k >= l - 0.5 and f:GetRight() * k <= r + 0.5 and f:GetTop() * k <= t + 0.5
            and f:GetBottom() * k >= b - 0.5
        end
        return { out, S.view.z < 1 }""")
    assert inside and all(inside[0]) and len(inside[0]) == 4 and inside[1], inside
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
