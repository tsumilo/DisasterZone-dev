"""Builder bugs found in game (2026-10-06): pieces left on the canvas that the event doesn't have (a drag cut short by
the window closing or Escape), stray C-piece tabs ("lips") on value pieces drawn from the pool.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_builder_ingame.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

# (as in test_event_builder.py; not imported: that would run its cases here too)
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

# the drawings on the canvas vs the event's scripts of the open stage
COUNT = """
  local S, ui = ns.EventBuilder:GetState()
  local shown = 0
  for _, kid in ipairs({ ui.content:GetChildren() }) do
    if ns.EventPieces:IsDrawn(kid) and kid:IsShown() then shown = shown + 1 end
  end
  local n = 0
  for _, s in ipairs(S.def.scripts) do if s.st == S.stage then n = n + 1 end end
  return { shown, n }"""


def start_new_drag(c, key, x, y):
    c.eval("""
        MOUSE_DOWN = true
        MOUSE_X, MOUSE_Y = -200, 300
        ns.EventBuilder:PressNew(ns.EventBlocks:New(...))""", key)
    c.eval("MOUSE_X, MOUSE_Y = ...; ns.EventBuilder:OnCanvasUpdate()", x, y)
    assert c.eval("local S = ns.EventBuilder:GetState(); return S.drag ~= nil")


@case
def closing_the_window_mid_drag_leaves_no_stray_piece():
    w, c = one()
    c.eval("local d = ns.Events:NewDef(false); ns.Events:SaveDef(d); "
           "ns.EventBuilder:Open(ns.Events:GetDef(d.id), { stage = 's1' })")
    c.eval(MOUSE)
    start_new_drag(c, "lo.or", 300, 200)
    assert c.eval_py(COUNT) == [1, 0]                 # the drag's own drawing
    c.eval("ns.EventBuilder:Close()")
    c.eval("MOUSE_DOWN = false")
    c.eval("local S = ns.EventBuilder:GetState(); ns.EventBuilder:Open(ns.Events:GetDef(S.def.id), { stage = 's1' })")
    assert c.eval_py(COUNT) == [0, 0], c.eval_py(COUNT)
    # (an empty new event offers its examples: "Start from an example", part 2)
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.empty:IsShown() or (ui.start and ui.start:IsShown())")
    w.assert_no_errors()


@case
def escape_mid_drag_cancels_it_and_puts_a_cut_piece_back():
    w, c = one()
    open_starter(c, "*")
    c.eval(MOUSE)
    # the "show" under "when Matches final is set" (c3): pull it out of its script
    c.eval("""
        local S, ui = ns.EventBuilder:GetState()
        local s
        for _, x in ipairs(S.def.scripts) do if x.id == 'c3' then s = x end end
        local f = ui.scripts[s]
        local pf = f.at[s.top.n]
        local ax, ay = ns.EventPieces:Abs(pf)
        MOUSE_DOWN = true
        MOUSE_X, MOUSE_Y = s.x + ax + 20, s.y + ay + 10
        pf:GetScript('OnMouseDown')(pf, 'LeftButton')
        MOUSE_X, MOUSE_Y = MOUSE_X + 120, MOUSE_Y + 160
        ns.EventBuilder:OnCanvasUpdate()""")
    assert c.eval("local S = ns.EventBuilder:GetState(); for _, x in ipairs(S.def.scripts) do "
                  "if x.id == 'c3' then return x.top.n == nil end end")      # cut out while it's dragged
    c.eval("local win = ns.EventBuilder:GetWindow(); win:GetScript('OnKeyDown')(win, 'ESCAPE')")
    assert c.eval("return ns.EventBuilder:IsShown()")
    assert c.eval("local S = ns.EventBuilder:GetState(); return S.drag == nil")
    assert c.eval("local S = ns.EventBuilder:GetState(); for _, x in ipairs(S.def.scripts) do "
                  "if x.id == 'c3' then return x.top.n and x.top.n.k end end") == "ch.show"
    c.eval("MOUSE_DOWN = false; ns.EventBuilder:OnCanvasUpdate()")
    shown, n = c.eval_py(COUNT)
    assert shown == n == 4, (shown, n)
    w.assert_no_errors()


@case
def a_redraw_clears_drawings_nothing_owns():
    w, c = one()
    open_starter(c, "*")
    c.eval("local S, ui = ns.EventBuilder:GetState(); "
           "T_stray = ns.EventPieces:DrawScript(ui.content, ns.EventBlocks:New('lo.or'), { static = true })")
    assert c.eval_py(COUNT) == [5, 4]
    c.eval("ns.EventBuilder:Refresh()")
    assert c.eval_py(COUNT) == [4, 4]
    # (released once: the pool holds it once)
    c.eval("ns.EventPieces:Release(T_stray); ns.EventPieces:Release(T_stray)")
    a = c.eval("local f1 = ns.EventPieces:DrawScript(UIParent, ns.EventBlocks:New('lo.or'), { static = true }); "
               "local f2 = ns.EventPieces:DrawScript(UIParent, ns.EventBlocks:New('lo.or'), { static = true }); "
               "return f1 ~= f2")
    assert a is True
    w.assert_no_errors()


@case
def value_pieces_from_the_pool_have_no_stray_tabs():
    w, c = one()
    n = c.eval("""
        local EP, B = ns.EventPieces, ns.EventBlocks
        -- C pieces first (their tab frames), then their frames go back to the pool
        local cs = {}
        for i = 1, 6 do cs[#cs + 1] = EP:DrawScript(UIParent, B:New(i % 2 == 0 and 'lo.rep' or 'lo.if'), { static = true }) end
        for _, f in ipairs(cs) do EP:Release(f) end
        -- then value pieces, the way the palette draws them
        local tabs = 0
        local function count(f)
          for _, t in pairs(f.tabFrames or {}) do if t:IsShown() then tabs = tabs + 1 end end
          for _, k in ipairs(f.kids or {}) do count(k) end
        end
        for _, k in ipairs({ 'lo.add', 'lo.sub', 'lo.rand', 'lo.or', 'lo.and', 'lo.gt' }) do
          if B.PIECES[k] then count(EP:Draw(UIParent, B:New(k), { static = true })) end
        end
        return tabs""")
    assert n == 0, n
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
