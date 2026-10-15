#!/usr/bin/env python
"""Key binds (/dz keys, UI/KeyBinds.lua), built 2026-10-15 after the game's Quick Keybind Mode broke on this client:
binders over every bindable button on the screen, a key cap under each, hover + press a key to bind it (modifiers,
the wheel, the side mouse buttons), a key taken from another button moves (rose flash + a note), right-click / Esc on
a button clears it, Esc elsewhere is Done (saved in the binding set), Discard puts every key back, undo / redo, drag an
ability to swap (PickupAction / PlaceAction, never the game's broken call), This character, the Esc menu's button,
a fight closes it, demo mode binds nothing for real.

Run: luaenv\\Scripts\\python.exe tests\\keybinds\\test_keybinds.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "uilook"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

import _common  # noqa: E402
from _common import case, run_all, solo  # noqa: E402

# (the action bars of the Dock's suite; its own cases are not ours to run)
_n = len(_common._CASES)
from test_dock import FAKE_BARS  # noqa: E402
del _common._CASES[_n:]

SEED = """
    __MOCK.bindings = { { 'ACTIONBUTTON1', '1' }, { 'ACTIONBUTTON2', '2' }, { 'ACTIONBUTTON3', '3' },
                        { 'MULTIACTIONBAR1BUTTON1', 'SHIFT-1' } }
    __MOCK.actions[1] = { 'spell', 20271 }
    __MOCK.actions[2] = { 'spell', 35395 }
"""


def boot():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval(FAKE_BARS)
    c.eval(SEED)
    return w, c


def open_keys(w, c):
    c.slash("/dz keys")
    w.tick(0.6)
    assert c.eval("return ns.KeyBinds:IsActive()") is True


def keys(c, cmd):
    return c.eval_py("return ns.KeyBinds:Keys(...)", cmd) or []


def hover(c, button):
    c.eval("local bd = ns.KeyBinds:Binder(_G[...]); bd:GetScript('OnEnter')(bd)", button)


def unhover(c, button):
    c.eval("local bd = ns.KeyBinds:Binder(_G[...]); bd:GetScript('OnLeave')(bd)", button)


def press(c, key):
    c.eval("DisasterZoneKeyBinds:GetScript('OnKeyDown')(DisasterZoneKeyBinds, ...)", key)


def mouse(c, button, which):
    c.eval("local bd = ns.KeyBinds:Binder(_G[...]); bd:GetScript('OnMouseDown')(bd, select(2, ...))", button, which)


@case
def binders_cover_the_shown_buttons_with_their_keys():
    w, c = boot()
    open_keys(w, c)
    # (shown bars only: MultiBarLeft and the pet bar are hidden, stance buttons 4-10 too)
    assert c.eval("return ns.KeyBinds:Binder(ActionButton1):IsShown()") is True
    assert c.eval("return ns.KeyBinds:Binder(MultiBarRightButton12):IsShown()") is True
    assert c.eval("return ns.KeyBinds:Binder(MultiBarLeftButton1) == nil") is True
    assert c.eval("return ns.KeyBinds:Binder(StanceButton5) == nil") is True
    assert c.eval("return ns.KeyBinds:Binder(ActionButton1).cap.fs:GetText()") == "1"
    cap = c.eval("return ns.KeyBinds:Binder(MultiBarBottomLeftButton1).cap.fs:GetText()")
    assert cap.endswith("s|r1"), cap
    assert c.eval("return ns.KeyBinds:Binder(ActionButton4).cap:IsShown()") is False


@case
def a_key_pressed_over_a_button_binds_it():
    w, c = boot()
    open_keys(w, c)
    hover(c, "ActionButton4")
    assert "Action bar 4" in c.eval("return ns.KeyBinds:Readout()")
    press(c, "F")
    assert keys(c, "ACTIONBUTTON4") == ["F"]
    assert c.eval("return ns.KeyBinds:Binder(ActionButton4).cap.fs:GetText()") == "F"
    # a new key replaces the button's old one
    press(c, "G")
    assert keys(c, "ACTIONBUTTON4") == ["G"]
    assert c.eval("return GetBindingAction('F')") == ""
    # modifiers held make a chord; holding a modifier alone binds nothing
    c.set_modifiers(shift=True, ctrl=True)
    press(c, "LSHIFT")
    assert keys(c, "ACTIONBUTTON4") == ["G"]
    press(c, "Q")
    c.set_modifiers()
    assert keys(c, "ACTIONBUTTON4") == ["CTRL-SHIFT-Q"]


@case
def the_wheel_and_side_mouse_buttons_bind_too():
    w, c = boot()
    open_keys(w, c)
    hover(c, "ActionButton5")
    c.set_modifiers(alt=True)
    c.eval("local bd = ns.KeyBinds:Binder(ActionButton5); bd:GetScript('OnMouseWheel')(bd, 1)")
    c.set_modifiers()
    assert keys(c, "ACTIONBUTTON5") == ["ALT-MOUSEWHEELUP"]
    mouse(c, "ActionButton6", "Button4")
    assert keys(c, "ACTIONBUTTON6") == ["BUTTON4"]
    mouse(c, "ActionButton7", "MiddleButton")
    assert keys(c, "ACTIONBUTTON7") == ["BUTTON3"]
    # the left button never binds (it clicks / drags)
    mouse(c, "ActionButton8", "LeftButton")
    assert keys(c, "ACTIONBUTTON8") == []


@case
def a_key_from_another_button_moves_and_says_where_from():
    w, c = boot()
    open_keys(w, c)
    hover(c, "ActionButton9")
    press(c, "1")
    assert keys(c, "ACTIONBUTTON9") == ["1"]
    assert keys(c, "ACTIONBUTTON1") == []
    assert "from Action bar 1" in c.eval("return ns.KeyBinds:NoteText()")
    assert c.eval("return ns.KeyBinds:Binder(ActionButton1).warnAt ~= nil") is True
    assert c.eval("return ns.KeyBinds:Binder(ActionButton1).cap:IsShown()") is False
    # the note fades away
    w.tick(5)
    assert c.eval("return ns.KeyBinds:NoteText()") is None


@case
def undo_and_redo_put_keys_back_where_they_were():
    w, c = boot()
    open_keys(w, c)
    hover(c, "ActionButton9")
    press(c, "1")
    c.eval("ns.KeyBinds:Undo()")
    assert keys(c, "ACTIONBUTTON1") == ["1"]
    assert keys(c, "ACTIONBUTTON9") == []
    c.eval("ns.KeyBinds:Redo()")
    assert keys(c, "ACTIONBUTTON9") == ["1"]
    assert keys(c, "ACTIONBUTTON1") == []
    # Ctrl+Z with nothing under the mouse
    unhover(c, "ActionButton9")
    c.set_modifiers(ctrl=True)
    press(c, "Z")
    c.set_modifiers()
    assert keys(c, "ACTIONBUTTON1") == ["1"]
    # a replaced key comes back with undo too
    hover(c, "ActionButton2")
    press(c, "T")
    c.eval("ns.KeyBinds:Undo()")
    assert keys(c, "ACTIONBUTTON2") == ["2"]


@case
def right_click_or_esc_on_a_button_clears_it():
    w, c = boot()
    open_keys(w, c)
    mouse(c, "ActionButton2", "RightButton")
    assert keys(c, "ACTIONBUTTON2") == []
    assert c.eval("return ns.KeyBinds:NoteText()") == "2 cleared"
    hover(c, "ActionButton3")
    press(c, "ESCAPE")
    assert keys(c, "ACTIONBUTTON3") == []
    assert c.eval("return ns.KeyBinds:IsActive()") is True


@case
def esc_elsewhere_is_done_and_saves_the_keys():
    w, c = boot()
    c.eval("__MOCK.binding_set = 1")
    open_keys(w, c)
    hover(c, "ActionButton4")
    press(c, "F")
    unhover(c, "ActionButton4")
    press(c, "ESCAPE")
    assert c.eval("return ns.KeyBinds:IsActive()") is False
    saved = c.eval_py("return __MOCK.saved_binding_sets[1]")
    assert ["ACTIONBUTTON4", "F"] in saved, saved
    # closing without a change saves nothing
    c.eval("__MOCK.saved_binding_sets = {}")
    open_keys(w, c)
    c.eval("ns.KeyBinds:Close(true)")
    assert c.eval("return next(__MOCK.saved_binding_sets) == nil") is True


@case
def discard_puts_every_key_back():
    w, c = boot()
    open_keys(w, c)
    hover(c, "ActionButton9")
    press(c, "1")
    press(c, "2")
    mouse(c, "ActionButton3", "RightButton")
    c.eval("DisasterZoneKeyBindsBar.b.discard:Click()")
    assert c.eval("return ns.KeyBinds:IsActive()") is False
    assert keys(c, "ACTIONBUTTON1") == ["1"]
    assert keys(c, "ACTIONBUTTON2") == ["2"]
    assert keys(c, "ACTIONBUTTON3") == ["3"]
    assert keys(c, "ACTIONBUTTON9") == []


@case
def this_character_saves_into_the_character_set():
    w, c = boot()
    c.eval("__MOCK.binding_set = 1")
    open_keys(w, c)
    c.eval("DisasterZoneKeyBindsBar.b.char:Click()")
    assert c.eval("return ns.KeyBinds:TargetSet()") == 2
    assert c.eval("return DisasterZoneKeyBindsBar.b.char.lit") is True
    c.eval("ns.KeyBinds:Close(true)")
    assert c.eval("return __MOCK.binding_set") == 2
    assert c.eval("return __MOCK.saved_binding_sets[2] ~= nil") is True
    # off again: asked first, then the account's keys come back
    c.eval("__MOCK.saved_binding_sets[1] = { { 'ACTIONBUTTON1', 'Y' } }")
    open_keys(w, c)
    c.eval("DisasterZoneKeyBindsBar.b.char:Click()")
    dlg = "local f = ns.Popup:FindVisible('DISASTERZONE_CONFIRM_KEYBINDS_ACCOUNT')"
    assert c.eval(dlg + "; return f ~= nil") is True
    c.eval(dlg + "; ns.Popup:Click(f, 1)")
    assert c.eval("return __MOCK.binding_set") == 1
    assert keys(c, "ACTIONBUTTON1") == ["Y"]


@case
def dragging_an_ability_swaps_it_without_the_games_call():
    w, c = boot()
    open_keys(w, c)
    c.eval("local bd = ns.KeyBinds:Binder(ActionButton1); bd:GetScript('OnDragStart')(bd)")
    assert c.eval("return select(2, GetCursorInfo())") == 20271
    c.eval("local bd = ns.KeyBinds:Binder(ActionButton2); bd:GetScript('OnReceiveDrag')(bd)")
    assert c.eval_py("return __MOCK.actions[2]") == ["spell", 20271]
    # the old one is on the cursor, as a drag in the game leaves it; a click drops it
    assert c.eval("return select(2, GetCursorInfo())") == 35395
    c.eval("local bd = ns.KeyBinds:Binder(ActionButton1); bd:GetScript('OnMouseUp')(bd, 'LeftButton')")
    assert c.eval_py("return __MOCK.actions[1]") == ["spell", 35395]
    assert c.eval("return GetCursorInfo() == nil") is True


@case
def a_fight_closes_it_and_keeps_the_keys():
    w, c = boot()
    open_keys(w, c)
    hover(c, "ActionButton4")
    press(c, "F")
    c.set_combat(True)
    w.tick(0.2)
    assert c.eval("return ns.KeyBinds:IsActive()") is False
    assert keys(c, "ACTIONBUTTON4") == ["F"]
    c.slash("/dz keys")
    assert c.eval("return ns.KeyBinds:IsActive()") is False
    c.set_combat(False)


@case
def demo_mode_binds_nothing_for_real():
    w, c = boot()
    c.eval("ns.Demo:SetEnabled(true)")
    open_keys(w, c)
    assert keys(c, "MULTIACTIONBAR1BUTTON6") == ["Q"]
    assert c.eval("return DisasterZoneKeyBindsBar.demo:IsShown()") is True
    hover(c, "ActionButton4")
    press(c, "F")
    assert keys(c, "ACTIONBUTTON4") == ["F"]
    c.eval("ns.KeyBinds:Close(true)")
    assert c.eval("return GetBindingKey('ACTIONBUTTON4') == nil") is True
    assert c.eval("return next(__MOCK.saved_binding_sets) == nil") is True


@case
def the_esc_menu_has_key_binds_under_the_layout_button():
    w, c = boot()
    c.eval("GameMenuFrame:InitButtons()")
    texts = c.eval_py("""
        local out = {}
        local list = {}
        for b in GameMenuFrame.buttonPool:EnumerateActive() do list[#list + 1] = b end
        table.sort(list, function(a, b) return a.layoutIndex < b.layoutIndex end)
        for _, b in ipairs(list) do out[#out + 1] = b:GetText() end
        return out
    """)
    assert "DisasterZone key binds" in texts, texts
    assert texts.index("DisasterZone key binds") == texts.index("DisasterZone layout") + 1, texts
    c.eval("""for b in GameMenuFrame.buttonPool:EnumerateActive() do
        if b:GetText() == 'DisasterZone key binds' then b:Click() end end""")
    w.tick(0.3)
    assert c.eval("return ns.KeyBinds:IsActive()") is True


@case
def other_ways_in_open_it():
    w, c = boot()
    c.eval("DisasterZone_ToggleKeyBinds()")
    assert c.eval("return ns.KeyBinds:IsActive()") is True
    c.eval("DisasterZone_ToggleKeyBinds()")
    assert c.eval("return ns.KeyBinds:IsActive()") is False
    assert "keybinds" in c.eval_py("return ns.MainFrame:GetShownTools()")
    # Edit layout and Key binds never share the screen
    c.slash("/dz edit")
    w.tick(0.3)
    c.slash("/dz keys")
    w.tick(0.3)
    assert c.eval("return ns.EditMode:IsActive()") is False
    assert c.eval("return ns.KeyBinds:IsActive()") is True


if __name__ == "__main__":
    sys.exit(run_all())
