#!/usr/bin/env python
"""Edit layout (/dz edit, UI/EditMode.lua) and the layout store (Core/Layout.lua), the approved prototype of
2026-10-13: every on-screen frame in one overlay, snapping to the screen's centre, other frames and equal gaps,
mirrored pairs, profiles per character, sharing a profile, and the game's own frames moved through its Edit Mode
layouts (C_EditMode, stubbed here: the mock has no Edit Mode). The quiet look of the same day ("Quiet until picked"):
dashed outlines until a frame is picked, one slim bar at the top (readout, the picked frames' tools, undo / redo,
Grid, Snap, Names, Frames, Done) that steps back when a picked frame is under it and while anything is dragged.

Run: luaenv\\Scripts\\python.exe tests\\editlayout\\test_editlayout.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from harness import World, Client  # noqa: E402
from _common import case, run_all, solo  # noqa: E402

W, H = 1920, 1080


def boot(name="Alice", class_file="PALADIN", **kw):
    w, c = solo(name, class_file=class_file, guild_rank=0, **kw)
    c.eval("__MOCK.real_geometry = true")
    return w, c


def open_edit(w, c):
    c.slash("/dz edit")
    w.tick(0.4)
    assert c.eval("return ns.EditMode:IsActive()") is True


def box(c, id_):
    """The item's box in UIParent units: (l, b, w, h) or None."""
    r = c.eval_py("local l, b, w, h = ns.Layout:Rect(...); if not l then return nil end; return { l, b, w, h }", id_)
    return tuple(round(v, 1) for v in r) if r else None


def drag(w, c, id_, dx, dy, alt=False, steps=3):
    """Presses on the item's mover, moves the cursor by dx, dy (in steps) and lets go."""
    l, b, bw, bh = box(c, id_)
    x0, y0 = l + bw / 2, b + bh / 2
    c.eval("__MOCK.cursor = { ... }", x0, y0)
    if alt:
        c.set_modifiers(alt=True)
    c.eval("ns.EditMode:OnMoverDown(..., 'LeftButton')", id_)
    for i in range(1, steps + 1):
        c.eval("__MOCK.cursor = { ... }", x0 + dx * i / steps, y0 + dy * i / steps)
        w.tick(0.05)
    c.eval("ns.EditMode:EndDrag()")
    if alt:
        c.set_modifiers(alt=False)
    w.tick(0.05)


def entry(c, id_):
    return c.eval_py("return ns.Layout:Entry(...)", id_)


# ------------------------------------------------------------------------------------------------------------------
@case
def places_are_kept_from_the_nearest_corner_side_or_centre():
    w, c = boot()
    for l, b, bw, bh, want in [(10, 20, 100, 40, "BOTTOMLEFT"), (900, 20, 100, 40, "BOTTOM"),
                               (1800, 20, 100, 40, "BOTTOMRIGHT"), (10, 500, 100, 40, "LEFT"),
                               (910, 520, 100, 40, "CENTER"), (1800, 500, 100, 40, "RIGHT"),
                               (10, 1000, 100, 40, "TOPLEFT"), (900, 1000, 100, 40, "TOP"),
                               (1800, 1000, 100, 40, "TOPRIGHT")]:
        p, x, y = c.eval("return ns.Layout.AnchorOf(...)", l, b, bw, bh)
        assert p == want, (l, b, p)
        l2, b2 = c.eval("return ns.Layout.BoxAt(...)", p, x, y, bw, bh)
        assert abs(l2 - l) < 0.2 and abs(b2 - b) < 0.2, (p, l2, b2)
    w.assert_no_errors()


@case
def every_frame_is_an_item_and_edit_layout_shows_the_ones_that_only_come_sometimes():
    w, c = boot()
    ids = c.eval_py("local o = {} for _, d in ipairs(ns.Layout:Items()) do o[#o + 1] = d.id end return o")
    for want in ["meters", "reminder", "toasts", "session", "roll", "bless", "totems", "swing", "shot"]:
        assert want in ids, (want, ids)
    assert box(c, "toasts") is None              # (the pop-ups' anchor is hidden until something pops up)
    open_edit(w, c)
    for id_ in ("toasts", "session", "roll", "reminder"):
        assert box(c, id_) is not None, id_
        assert c.eval("local m = ns.EditMode:Mover(...); return m and m:IsShown() or false", id_) is True, id_
    # the bar is up, the Frames panel waits for its button; opened, it lists them, grouped
    assert c.eval("return ns.EditMode:GetBar():IsShown()") is True
    assert c.eval("return ns.EditMode:GetPanel():IsShown()") is False
    c.eval("ns.EditMode:GetBar().b.frames:Click()")
    assert c.eval("return ns.EditMode:GetPanel():IsShown()") is True
    rows = c.eval_py("local o = {} for _, r in ipairs(ns.EditMode:GetPanel().rows) do "
                     "if r:IsShown() then o[#o + 1] = r.fs:GetText() end end return o")
    for want in ("Raid session bar", "Roll frame", "Pop-ups", "Strategy reminder"):
        assert any(want in (t or "") for t in rows), (want, rows)
    c.slash("/dz edit")
    w.tick(0.3)
    assert c.eval("return ns.EditMode:IsActive()") is False
    for id_ in ("toasts", "session", "roll", "reminder"):
        assert box(c, id_) is None, id_            # (the previews went with it)
    w.assert_no_errors()


@case
def a_drag_snaps_to_the_screen_centre_and_alt_places_freely():
    w, c = boot()
    open_edit(w, c)
    l, b, bw, bh = box(c, "toasts")
    assert abs((l + bw / 2) - W / 2) < 0.6
    drag(w, c, "toasts", 4, -150)                 # (4 px off centre: it stays on the centre line)
    l2, b2, _, _ = box(c, "toasts")
    assert abs((l2 + bw / 2) - W / 2) < 0.6, l2
    assert b2 < b - 100
    e = entry(c, "toasts")
    assert e["p"] in ("TOP", "CENTER") and abs(e["x"]) < 0.6, e
    drag(w, c, "toasts", 4, 0, alt=True)
    l3, _, _, _ = box(c, "toasts")
    assert abs(l3 - (l2 + 4)) < 0.6, (l2, l3)
    w.assert_no_errors()


@case
def the_strategy_reminder_card_stays_while_editing_and_moves():
    # (its own refresh, 4 a second, faded the card out when no reminder was up: gone 2 s in, it couldn't be moved)
    w, c = boot()
    open_edit(w, c)
    l, b, bw, bh = box(c, "reminder")
    w.tick(3.0)
    c.eval("ns.EditMode:Refresh()")
    assert box(c, "reminder") == (l, b, bw, bh)
    assert c.eval("return ns.StrategyReminder:GetFrame():GetAlpha()") == 1
    drag(w, c, "reminder", -300, -200, alt=True)
    l2, b2, _, _ = box(c, "reminder")
    assert abs(l2 - (l - 300)) < 0.6 and abs(b2 - (b - 200)) < 0.6, (l, b, l2, b2)
    assert entry(c, "reminder")["p"], entry(c, "reminder")
    c.slash("/dz edit")
    w.tick(0.3)
    assert box(c, "reminder") is None
    open_edit(w, c)
    l3, b3, _, _ = box(c, "reminder")
    assert abs(l3 - l2) < 0.6 and abs(b3 - b2) < 0.6, (l2, b2, l3, b3)
    w.assert_no_errors()


@case
def the_grid_counts_from_the_centre():
    w, c = boot()
    c.eval("ns.DB:SetSetting('editlayout.grid', 16)")
    c.eval("ns.DB:SetSetting('editlayout.snapFrames', false)")
    open_edit(w, c)
    drag(w, c, "toasts", 37, -203, steps=2)
    l, b, bw, bh = box(c, "toasts")
    assert abs(((l + bw / 2) - W / 2) % 16) < 0.6 or abs(((l + bw / 2) - W / 2) % 16 - 16) < 0.6, l
    assert abs(((b + bh / 2) - H / 2) % 16) < 0.6 or abs(((b + bh / 2) - H / 2) % 16 - 16) < 0.6, b
    w.assert_no_errors()


@case
def snapping_numbers_lines_and_equal_gaps():
    w, c = boot()
    open_edit(w, c)
    # plain numbers: two boxes on a row, a third dropped near the middle between them lands exactly halfway
    res = c.eval_py("""
        local EM = ns.EditMode
        local bx = EM:Boxes()
        for k in pairs(bx) do bx[k] = nil end
        local function B(l, b, w, h) return { l = l, b = b, w = w, h = h, r = l + w, t = b + h, cx = l + w / 2, cy = b + h / 2 } end
        bx.a = B(100, 300, 100, 40)
        bx.b = B(500, 300, 100, 40)
        ns.DB:SetSetting('editlayout.snapScreen', false)
        local l, b, gx = EM:Snap(298, 300, 60, 40, {})
        return { l = l, b = b, gap = gx ~= nil }
    """)
    # halfway: gap 120 on both sides of a 60 wide box between 200 and 500 -> l = 320 (only if within 6 px)
    assert res["gap"] is False and res["l"] == 298 or res["l"] == 320, res
    res = c.eval_py("""
        local EM = ns.EditMode
        local function B(l, b, w, h) return { l = l, b = b, w = w, h = h, r = l + w, t = b + h, cx = l + w / 2, cy = b + h / 2 } end
        local bx = EM:Boxes()
        for k in pairs(bx) do bx[k] = nil end
        bx.a = B(100, 300, 100, 40); bx.b = B(500, 300, 100, 40)
        local _ = ns.Layout
        local l, b, gx = EM:Snap(317, 302, 60, 40, {})
        return { l = l, b = b, gap = gx ~= nil }
    """)
    assert res["gap"] is True and res["l"] == 320, res
    w.assert_no_errors()


@case
def the_screen_centre_wins_a_near_tie():
    w, c = boot()
    open_edit(w, c)
    res = c.eval_py("""
        local EM = ns.EditMode
        local bx = EM:Boxes()
        for k in pairs(bx) do bx[k] = nil end
        bx.a = { l = 900, b = 100, w = 54, h = 40, r = 954, t = 140, cx = 927, cy = 120 }
        ns.DB:SetSetting('editlayout.snapGaps', false)
        -- a 100 wide box at 905: its left is 5 from the screen's centre line... its centre 4 from... (955 -> 960)
        local l = EM:Snap(906, 400, 100, 40, {})
        return l
    """)
    # its centre (956) is 4 from the screen's centre: the centre wins over the frame edge 954 (2 from its left? no:
    # the left 906 is 6 from 900), so it lands centred
    assert res == 910, res
    w.assert_no_errors()


@case
def a_mirrored_pair_moves_together_across_the_centre():
    w, c = boot()
    open_edit(w, c)
    assert c.eval("return ns.Layout:SetMirror('session', 'reminder')") is True
    w.tick(0.1)
    drag(w, c, "session", -400, -200, steps=4)
    ls, bs, ws, hs = box(c, "session")
    lr, br, wr, hr = box(c, "reminder")
    assert abs(ls - (W - (lr + wr))) < 1.5, (ls, ws, lr, wr)    # mirrored across the centre: equal outer margins
    assert abs((bs + hs) - (br + hr)) < 1.5                                    # level tops
    # the mirror picker: Mirror..., then a click on the partner
    c.eval("ns.Layout:ClearMirror('session')")
    c.eval("ns.EditMode:Select({ 'toasts' })")
    c.eval("ns.EditMode:GetToolbar().b.mirror1:Click()")
    # (the hint shows under the bar, in the middle)
    hint = "ns.EditMode:GetBar().hint"
    assert c.eval("return %s:IsShown()" % hint) is True
    assert "mirrored" in c.eval("return %s.fs:GetText()" % hint)
    assert abs(c.eval("return %s:GetTop()" % hint) - (H - 28 - 6)) < 0.6
    c.eval("ns.EditMode:OnMoverDown('roll', 'LeftButton')")
    c.eval("ns.EditMode:EndDrag()")
    assert c.eval("return ns.Layout:Partner('toasts')") == "roll"
    assert c.eval("return ns.Layout:Partner('roll')") == "toasts"
    assert c.eval("return ns.EditMode:GetBar().hint:IsShown()") is False
    w.assert_no_errors()


@case
def the_toolbar_lines_up_spreads_and_centres_a_selection():
    w, c = boot()
    open_edit(w, c)
    c.eval("ns.Layout:MoveTo('toasts', 200, 700); ns.Layout:MoveTo('session', 260, 500); ns.Layout:MoveTo('roll', 230, 300)")
    w.tick(0.1)
    c.eval("ns.EditMode:Select({ 'toasts', 'session', 'roll' })")
    c.eval("ns.EditMode:Act('al')")
    lefts = {box(c, i)[0] for i in ("toasts", "session", "roll")}
    assert len(lefts) == 1 and abs(lefts.pop() - 200) < 0.6
    c.eval("ns.EditMode:Act('dv')")
    bt, bs, br = box(c, "toasts"), box(c, "session"), box(c, "roll")
    g1 = bs[1] - (br[1] + br[3])
    g2 = bt[1] - (bs[1] + bs[3])
    assert abs(g1 - g2) < 1.5, (g1, g2)
    c.eval("ns.EditMode:Act('ch')")
    l = min(box(c, i)[0] for i in ("toasts", "session", "roll"))
    r = max(box(c, i)[0] + box(c, i)[2] for i in ("toasts", "session", "roll"))
    assert abs((l + r) / 2 - W / 2) < 1, (l, r)
    # undo puts it back where it was before centring
    c.eval("ns.EditMode:Undo()")
    assert abs(min(box(c, i)[0] for i in ("toasts", "session", "roll")) - 200) < 0.6
    c.eval("ns.EditMode:Redo()")
    assert abs(min(box(c, i)[0] for i in ("toasts", "session", "roll")) - l) < 0.6
    w.assert_no_errors()


@case
def arrows_nudge_and_escape_steps_back():
    w, c = boot()
    open_edit(w, c)
    c.eval("ns.EditMode:Select({ 'session' })")
    l0 = box(c, "session")[0]
    c.eval("ns.EditMode:OnKey('RIGHT')")
    assert abs(box(c, "session")[0] - (l0 + 1)) < 0.6
    c.set_modifiers(shift=True)
    c.eval("ns.EditMode:OnKey('LEFT')")
    c.set_modifiers(shift=False)
    assert abs(box(c, "session")[0] - (l0 - 9)) < 0.6
    assert c.eval("return ns.EditMode:OnKey('ESCAPE')") is True
    assert c.eval("return #ns.EditMode:Selection()") == 0
    c.eval("ns.EditMode:OnKey('ESCAPE')")
    assert c.eval("return ns.EditMode:IsActive()") is False
    w.assert_no_errors()


@case
def hidden_frames_stay_hidden_and_come_back_with_the_eye():
    w, c = boot()
    open_edit(w, c)
    c.eval("ns.EditMode:Select({ 'reminder' })")
    c.eval("ns.EditMode:Act('hide')")
    assert c.eval("return ns.Layout:IsHidden('reminder')") is True
    c.slash("/dz edit"); w.tick(0.2)
    # a reminder that wants to show is hidden again
    c.eval("ns.StrategyReminder = ns.StrategyReminder; local f = ns.StrategyReminder and ns.StrategyReminder:GetFrame(); "
           "if f then f:Show() end")
    assert c.eval("local f = ns.StrategyReminder:GetFrame(); return f and f:IsShown() or false") is False
    c.eval("ns.Layout:SetHidden('reminder', false)")
    assert c.eval("return ns.Layout:IsHidden('reminder')") is False
    w.assert_no_errors()


@case
def profiles_are_per_character_and_switch_every_place():
    w, c = boot()
    open_edit(w, c)
    c.eval("ns.Layout:MoveTo('session', 100, 100)")
    raid = c.eval("return ns.Layout:NewProfile('Raid')")
    assert raid
    c.eval("ns.Layout:Use(...)", raid)
    c.eval("ns.Layout:MoveTo('session', 1400, 800)")
    assert abs(box(c, "session")[0] - 1400) < 0.6
    c.eval("ns.Layout:Use('default')")
    assert abs(box(c, "session")[0] - 100) < 0.6
    c.eval("ns.Layout:Use(...)", raid)
    assert abs(box(c, "session")[0] - 1400) < 0.6
    me = c.eval("return ns.Util.PlayerKey()")
    assert c.eval("return ns.db.layouts.chars[...]", me) == raid
    names = c.eval_py("local o = {} for _, p in ipairs(ns.Layout:Profiles()) do o[#o + 1] = p.name end return o")
    assert names == ["Default", "Raid"], names
    assert c.eval("return ns.Layout:Rename(..., 'Raid night')", raid) is True
    assert c.eval("return ns.Layout:NameTaken('raid night')") is True
    assert c.eval("return ns.Layout:Delete('default')") is False
    assert c.eval("return ns.Layout:Delete(...)", raid) is True
    assert c.eval("return ns.Layout:ActiveId()") == "default"
    assert abs(box(c, "session")[0] - 100) < 0.6
    w.assert_no_errors()


@case
def old_saved_places_are_read_until_a_frame_is_moved():
    w, c = boot()
    c.eval("ns.db.settings.windows = ns.db.settings.windows or {}; "
           "ns.db.settings.windows.DisasterZoneSessionBar = { 'TOPLEFT', 'TOPLEFT', 40, -60 }")
    c.eval("ns.SessionBar:Preview(true)")
    l, b, bw, bh = box(c, "session")
    assert abs(l - 40) < 0.6 and abs((b + bh) - (H - 60)) < 0.6, (l, b, bh)
    assert entry(c, "session") is None
    w.assert_no_errors()


@case
def a_fight_closes_edit_layout_and_offers_it_again_after():
    w, c = boot()
    open_edit(w, c)
    c.set_combat(True)
    w.tick(0.2)
    assert c.eval("return ns.EditMode:IsActive()") is False
    c.slash("/dz edit"); w.tick(0.1)
    assert c.eval("return ns.EditMode:IsActive()") is False      # (not in combat)
    c.set_combat(False)
    w.tick(0.5)
    assert c.eval("return ns.UI:GetToast('editlayout') ~= nil") is True
    w.assert_no_errors()


@case
def a_shared_profile_comes_over_and_can_be_kept():
    w = World()
    a = Client(w, "Alice", class_file="PALADIN", guild_rank=0)
    b = Client(w, "Bob", class_file="WARRIOR", guild_rank=3)
    a.load_addon(); b.load_addon()
    w.tick(3)
    for cl in (a, b):
        cl.eval("__MOCK.real_geometry = true")
    a.eval("ns.Layout:MoveTo('toasts', 300, 300)")      # (no frame yet: nothing to move)
    raid = a.eval("return ns.Layout:NewProfile('Raid')")
    a.eval("ns.Layout:Use(...)", raid)
    a.eval("local p = ns.Layout:Profile(...); p.frames.session = { p = 'TOPLEFT', x = 50, y = -50 }; "
           "p.mirror.session = 'reminder'; p.mirror.reminder = 'session'", raid)
    ref = a.eval("return ns.Layout:ShareRef(...)", raid)
    assert ref.startswith("layout:Alice-")
    # Alice's own link: known, labelled with the profile's name
    assert "Raid" in (a.eval("local d = ns.Share:Describe(...); return d and d.label", ref) or "")
    b.click_link("addon:DisasterZone:" + ref)
    w.tick(3)
    POP = "DISASTERZONE_CONFIRM_layoutshare"
    assert b.popup_text(POP) and "Raid" in b.popup_text(POP), b.popup_text(POP)
    b.accept_popup(POP)
    w.tick(0.5)
    names = b.eval_py("local o = {} for _, p in ipairs(ns.Layout:Profiles()) do o[#o + 1] = p.name end return o")
    assert any(n.startswith("Raid (Alice") for n in names), names
    assert b.eval("return ns.Layout:Active().frames.session.x") == 50
    assert b.eval("return ns.Layout:Partner('session')") == "reminder"
    # an answer nobody asked for is dropped
    b.eval("ns:Fire('LAYOUT_RECEIVED', 'Mallory-Realm', 'x', nil)")
    w.assert_no_errors()


BLIZZ_STUB = r"""
    Enum = Enum or {}
    Enum.EditModeLayoutType = { Preset = 0, Account = 1, Character = 2, Override = 3 }
    _G.__EM = { saves = 0, shown = 0, active = nil }
    local presets = {
        { layoutName = 'Modern', layoutType = 0, systems = { { system = 0, systemIndex = 1,
            anchorInfo = { point = 'TOPLEFT', relativeTo = 'UIParent', relativePoint = 'TOPLEFT', offsetX = 20, offsetY = -10 },
            isInDefaultPosition = true } } },
        { layoutName = 'Classic', layoutType = 0, systems = { { system = 0, systemIndex = 1,
            anchorInfo = { point = 'TOPLEFT', relativeTo = 'UIParent', relativePoint = 'TOPLEFT', offsetX = 20, offsetY = -10 },
            isInDefaultPosition = true } } },
    }
    local saved = { activeLayout = ..., layouts = {} }
    if saved.activeLayout == 3 then
        saved.layouts[1] = { layoutName = 'Mine', layoutType = 1, systems = { { system = 0, systemIndex = 1,
            anchorInfo = { point = 'TOPLEFT', relativeTo = 'UIParent', relativePoint = 'TOPLEFT', offsetX = 20, offsetY = -10 },
            isInDefaultPosition = false } } }
    end
    local function copy(t) if type(t) ~= 'table' then return t end local o = {} for k, v in pairs(t) do o[k] = copy(v) end return o end
    C_EditMode = {
        GetLayouts = function() return copy(saved) end,
        SaveLayouts = function(li)
            __EM.saves = __EM.saves + 1
            local keep = { activeLayout = li.activeLayout, layouts = {} }
            for _, l in ipairs(li.layouts) do if l.layoutType ~= 0 then keep.layouts[#keep.layouts + 1] = copy(l) end end
            saved = keep
            __EM.last = copy(li)
        end,
        SetActiveLayout = function(i) __EM.active = i; saved.activeLayout = i end,
    }
    EditModePresetLayoutManager = {
        GetCopyOfPresetLayouts = function() return copy(presets) end,
        GetDefaultSystemAnchorInfo = function() return copy(presets[1].systems[1].anchorInfo) end,
    }
    EditModeManagerFrame = CreateFrame('Frame', 'EditModeManagerFrame', UIParent)
    EditModeManagerFrame:Hide()
    local pf = CreateFrame('Button', 'PlayerFrame', UIParent)
    pf:SetSize(232, 100)
    pf:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 20, -10)
    pf.system, pf.systemIndex = 0, 1
    -- the game applies its layout when its Edit Mode panel opens and closes: here the stub moves the frame
    local show0 = ShowUIPanel
    ShowUIPanel = function(f, ...)
        if f == EditModeManagerFrame then
            __EM.shown = __EM.shown + 1
            local li = C_EditMode.GetLayouts()
            local a = li.activeLayout and (li.activeLayout - 2)
            local l = li.layouts[a]
            local s = l and l.systems[1]
            if s then
                local ai = s.anchorInfo
                pf:ClearAllPoints()
                pf:SetPoint(ai.point, UIParent, ai.relativePoint, ai.offsetX, ai.offsetY)
            end
            return
        end
        if show0 then return show0(f, ...) end
    end
    HideUIPanel = HideUIPanel or function() end
"""


@case
def the_games_frames_move_through_its_edit_mode_layout():
    w, c = boot()
    c.eval(BLIZZ_STUB, 3)
    c.eval("ns.Layout:RegisterBlizzard()")
    assert c.eval("return ns.Layout:Item('blizz:PlayerFrame') ~= nil") is True
    open_edit(w, c)
    assert box(c, "blizz:PlayerFrame") is not None
    drag(w, c, "blizz:PlayerFrame", 600, -300, alt=True)
    assert c.eval("return __EM.saves") >= 1
    assert c.eval("return __EM.shown") >= 1
    l, b, bw, bh = box(c, "blizz:PlayerFrame")
    assert abs(l - 620) < 1 and abs((b + bh) - (H - 10 - 300)) < 1, (l, b)
    ai = c.eval_py("return __EM.last.layouts[3].systems[1]")
    assert ai["isInDefaultPosition"] is False and ai["anchorInfo"]["relativeTo"] == "UIParent", ai
    # the profile keeps it too (a profile switch / a share moves the game's frames)
    assert entry(c, "blizz:PlayerFrame")["p"]
    w.assert_no_errors()


@case
def on_a_preset_layout_a_character_layout_is_made():
    w, c = boot()
    c.eval(BLIZZ_STUB, 1)
    c.eval("ns.Layout:RegisterBlizzard()")
    assert c.eval("return ns.Layout:MoveTo('blizz:PlayerFrame', 400, 600)") is True
    last = c.eval_py("return __EM.last")
    names = [l["layoutName"] for l in last["layouts"]]
    assert "DisasterZone" in names, names
    new = names.index("DisasterZone") + 1
    assert last["activeLayout"] == new and c.eval("return __EM.active") == new
    assert last["layouts"][new - 1]["layoutType"] == 2
    w.assert_no_errors()


@case
def a_meter_stack_dragged_by_its_header_snaps_too():
    w, c = boot()
    open_edit(w, c)
    res = c.eval_py("""
        local f = CreateFrame('Frame', nil, UIParent)
        f:SetSize(200, 100)
        local x, y = ns.EditMode:SnapBox(f, 857, 700, 200, 100)
        return { x = x, y = y }
    """)
    assert res["x"] == 860, res          # (its centre 957 -> the screen's centre 960)
    w.assert_no_errors()


@case
def settings_layout_section_and_the_locked_switches_are_gone():
    w, c = boot()
    c.eval("ns.MainFrame:Open('settings')")
    w.tick(0.3)
    assert c.eval("return ns.SettingsUI.sections.layout ~= nil") is True
    texts = c.eval_py("local o = {} local function walk(f) for _, r in ipairs({ f:GetRegions() }) do "
                      "if r.GetText and r:GetText() then o[#o + 1] = r:GetText() end end "
                      "for _, ch in ipairs({ f:GetChildren() }) do walk(ch) end end "
                      "walk(ns.SettingsUI.panel) return o")
    assert "Lock panels" not in texts and "Locked" not in texts, [t for t in texts if "ock" in t]
    assert "Edit layout" in texts
    w.assert_no_errors()


@case
def the_window_steps_aside_while_editing_and_comes_back_on_its_page():
    w, c = boot()
    c.eval("ns.MainFrame:Open('settings')")
    w.tick(0.3)
    c.eval("ns.SettingsUI:SelectSection('layout')")
    c.eval("ns.SettingsUI.sections.layout")
    open_edit(w, c)
    assert c.eval("return ns.MainFrame:IsShown()") is False
    c.eval("ns.EditMode:Close()")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:IsShown()") is True
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "settings"
    # opened with the window shut: it stays shut after
    c.eval("ns.MainFrame:Close()")
    open_edit(w, c)
    c.eval("ns.EditMode:Close()")
    assert c.eval("return ns.MainFrame:IsShown()") is False
    # a fight closes editing and leaves the window shut
    c.eval("ns.MainFrame:Open('home')")
    open_edit(w, c)
    c.set_combat(True)
    w.tick(0.2)
    assert c.eval("return ns.MainFrame:IsShown()") is False
    c.set_combat(False)
    w.assert_no_errors()


@case
def the_minimap_pin_and_slash_words_open_it():
    w, c = boot()
    assert "editlayout" in c.eval_py("return ns.MainFrame:GetShownTools()")
    c.eval("ns.MainFrame:Open('editlayout')")
    w.tick(0.2)
    assert c.eval("return ns.EditMode:IsActive()") is True
    c.eval("ns.EditMode:Close()")
    c.slash("/dz swing move")
    w.tick(0.2)
    assert c.eval("return ns.EditMode:IsActive()") is True
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Resizing: handles round the selection, the wheel, a double-click back to 100%
def resize(w, c, hx, hy, dx, dy, shift=False, alt=False, steps=3):
    """Presses the selection's handle (hx, hy), moves the cursor by dx, dy and lets go."""
    l, b, r, t = c.eval("local b = ns.EditMode:SelectionBox(); return b.l, b.b, b.r, b.t")
    x0 = l if hx < 0 else (r if hx > 0 else (l + r) / 2)
    y0 = b if hy < 0 else (t if hy > 0 else (b + t) / 2)
    c.eval("__MOCK.cursor = { ... }", x0, y0)
    c.set_modifiers(shift=shift, alt=alt)
    c.eval("ns.EditMode:StartResize(...)", hx, hy)
    for i in range(1, steps + 1):
        c.eval("__MOCK.cursor = { ... }", x0 + dx * i / steps, y0 + dy * i / steps)
        w.tick(0.05)
    c.eval("ns.EditMode:EndDrag()")
    c.set_modifiers(shift=False, alt=False)
    w.tick(0.05)


STRETCHY = """
    local f = CreateFrame('Frame', 'DZTestStretch', UIParent)
    f:SetSize(200, 20)
    f:Show()
    ns.Layout:Register('test.stretch', { name = 'Stretchy', group = 'Raid', default = { 'CENTER', 0, -300 },
        frame = function() return f end,
        stretch = { x = { 100, 600 }, apply = function() f:SetWidth(ns.Layout:Size('test.stretch') or 200) end } })
"""


@case
def a_corner_handle_scales_evenly_from_the_opposite_corner():
    w, c = boot()
    open_edit(w, c)
    c.eval("ns.Layout:MoveTo('roll', 600, 400)")
    c.eval("ns.EditMode:Select({ 'roll' })")
    l, b, bw, bh = box(c, "roll")
    resize(w, c, 1, -1, bw * 0.5, 0, alt=True)                     # bottom-right corner, half again as wide
    l2, b2, bw2, bh2 = box(c, "roll")
    assert abs(c.eval("return ns.Layout:Scale('roll')") - 1.5) < 0.011
    assert abs(bw2 - bw * 1.5) < 2 and abs(bh2 - bh * 1.5) < 2, (bw2, bh2)
    assert abs(l2 - l) < 1 and abs((b2 + bh2) - (b + bh)) < 1, (l2, b2)   # the top-left corner stayed
    # Shift: from the centre
    cx, cy = l2 + bw2 / 2, b2 + bh2 / 2
    resize(w, c, -1, 0, bw2 * 0.25, 0, shift=True, alt=True)       # the left side pulled in: smaller both ways
    l3, b3, bw3, bh3 = box(c, "roll")
    assert bw3 < bw2 - 10
    assert abs((l3 + bw3 / 2) - cx) < 1.5 and abs((b3 + bh3 / 2) - cy) < 1.5
    # undo: the size before
    c.eval("ns.EditMode:Undo()")
    assert abs(box(c, "roll")[2] - bw2) < 1
    w.assert_no_errors()


@case
def a_side_handle_stretches_a_frame_that_lays_itself_out():
    w, c = boot()
    c.eval(STRETCHY)
    open_edit(w, c)
    c.eval("ns.EditMode:Select({ 'test.stretch' })")
    l, b, bw, bh = box(c, "test.stretch")
    resize(w, c, 1, 0, 120, 0, alt=True)
    l2, b2, bw2, bh2 = box(c, "test.stretch")
    assert abs(bw2 - (bw + 120)) < 1.5 and abs(bh2 - bh) < 0.6, (bw2, bh2)    # wider, not taller
    assert abs(l2 - l) < 1                                                      # the left edge stayed
    assert entry(c, "test.stretch")["w"] == round(bw + 120)
    assert abs(c.eval("return ns.Layout:Scale('test.stretch')") - 1) < 0.001
    # a stretch snaps its moving edge to the screen's centre line
    resize(w, c, -1, 0, (W / 2 - l2) - 3, 0)
    assert abs(box(c, "test.stretch")[0] - W / 2) < 0.6
    # clamped to its range; a double-click on the side: its natural width
    resize(w, c, 1, 0, 2000, 0, alt=True)
    assert entry(c, "test.stretch")["w"] == 600
    c.eval("ns.EditMode:ResetSize(1, 0)")
    assert abs(box(c, "test.stretch")[2] - 200) < 0.6, (box(c, "test.stretch"), entry(c, "test.stretch"))
    assert entry(c, "test.stretch").get("w") is None, entry(c, "test.stretch")
    w.assert_no_errors()


@case
def several_picked_resize_as_one_with_their_gaps():
    w, c = boot()
    open_edit(w, c)
    c.eval("ns.Layout:MoveTo('session', 400, 600); ns.Layout:MoveTo('roll', 400, 300)")
    c.eval("ns.EditMode:Select({ 'session', 'roll' })")
    gap0 = box(c, "session")[1] - (box(c, "roll")[1] + box(c, "roll")[3])
    resize(w, c, 1, 1, 0, 400, alt=True)                    # top-right corner up: the group grows from bottom-left
    s1, s2 = c.eval("return ns.Layout:Scale('session'), ns.Layout:Scale('roll')")
    assert abs(s1 - s2) < 0.011 and s1 > 1.2, (s1, s2)
    gap1 = box(c, "session")[1] - (box(c, "roll")[1] + box(c, "roll")[3])
    assert abs(gap1 - gap0 * s1) < 3, (gap0, gap1, s1)
    assert abs(box(c, "roll")[0] - 400) < 1.5 and abs(box(c, "roll")[1] - 300) < 1.5   # the anchor corner stayed
    w.assert_no_errors()


@case
def the_wheel_steps_five_percent_and_a_double_click_goes_back_to_100():
    w, c = boot()
    open_edit(w, c)
    c.eval("ns.Layout:MoveTo('roll', 600, 400)")
    c.eval("ns.EditMode:Select({ 'roll' })")
    l, b, bw, bh = box(c, "roll")
    c.eval("ns.EditMode:Wheel('roll', 1)")
    c.eval("ns.EditMode:Wheel('roll', 1)")
    assert abs(c.eval("return ns.Layout:Scale('roll')") - 1.1) < 0.001
    l2, b2, bw2, bh2 = box(c, "roll")
    assert abs((l2 + bw2 / 2) - (l + bw / 2)) < 1 and abs((b2 + bh2 / 2) - (b + bh / 2)) < 1   # about its middle
    c.eval("ns.EditMode:Wheel('session', 1)")                    # (not picked: nothing)
    assert abs(c.eval("return ns.Layout:Scale('session')") - 1) < 0.001
    c.eval("ns.EditMode:ResetSize(1, 1)")
    assert abs(c.eval("return ns.Layout:Scale('roll')") - 1) < 0.001
    c.eval("ns.EditMode:Undo()")
    assert abs(c.eval("return ns.Layout:Scale('roll')") - 1.1) < 0.001
    # the handles sit round the selection (corners always; sides when the frame is big enough)
    assert c.eval("return ns.EditMode:HandlesShown()") >= 4
    c.eval("ns.EditMode:Select({})")
    assert c.eval("return ns.EditMode:HandlesShown()") == 0
    w.assert_no_errors()


@case
def the_games_frames_resize_through_their_edit_mode_size():
    w, c = boot()
    c.eval(BLIZZ_STUB, 3)
    c.eval("""
        Enum = Enum or {}
        Enum.EditModeSystem = { UnitFrame = 0 }
        Enum.EditModeUnitFrameSetting = { FrameSize = 7 }
        EditModeSettingDisplayInfoManager = { systemSettingDisplayInfo = { [0] = {
            { setting = 7, minValue = 100, maxValue = 200, stepSize = 5 } } } }
    """)
    c.eval("ns.Layout:RegisterBlizzard()")
    open_edit(w, c)
    lo, hi, step = c.eval("return ns.Layout:ScaleRange('blizz:PlayerFrame')")
    assert (round(lo, 2), round(hi, 2), round(step, 2)) == (1.0, 2.0, 0.05)
    c.eval("ns.EditMode:Select({ 'blizz:PlayerFrame' })")
    l, b, bw, bh = box(c, "blizz:PlayerFrame")
    saves = c.eval("return __EM.saves")
    resize(w, c, 1, -1, bw * 0.32, 0, alt=True)
    assert c.eval("return __EM.saves") > saves
    s = c.eval_py("return __EM.last.layouts[3].systems[1].settings")
    assert s and s[0]["setting"] == 7 and s[0]["value"] == 6, s          # 130% = (130 - 100) / 5
    assert abs(entry(c, "blizz:PlayerFrame")["s"] - 1.3) < 0.001
    # below its slider's minimum it stops at 100%
    resize(w, c, 1, -1, -bw, 0, alt=True)
    s = c.eval_py("return __EM.last.layouts[3].systems[1].settings")
    assert s[0]["value"] == 0, s
    w.assert_no_errors()


@case
def the_roll_frame_and_the_session_bar_keep_their_place_after_a_reload():
    w, c = boot()
    open_edit(w, c)
    c.eval("ns.Layout:MoveTo('roll', 300, 250); ns.Layout:MoveTo('session', 1400, 800)")
    c.eval("ns.EditMode:Close()")
    c.relog()
    w.tick(2)
    c.eval("__MOCK.real_geometry = true")
    # (both are built the first time they show: the roll frame for a roll, the bar in a raid)
    c.eval("ns.RollFrame:GetFrame():Show()")
    c.eval("ns.SessionBar:Preview(true)")
    w.tick(0.1)
    l, b, _, _ = box(c, "roll")
    assert abs(l - 300) < 1 and abs(b - 250) < 1, (l, b)
    l, b, _, _ = box(c, "session")
    assert abs(l - 1400) < 1 and abs(b - 800) < 1, (l, b)
    w.assert_no_errors()

# ------------------------------------------------------------------------------------------------------------------
# The quiet look: outlines until picked, one slim bar at the top, guides only while dragging
BAR = "ns.EditMode:GetBar()"


def plain(t):
    """Text without colour codes."""
    import re
    return re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", t or "")


def readout(c):
    return plain(c.eval("return %s.read:GetText()" % BAR))


def tools(c):
    """The bar's buttons that show now (their keys in bar.b), sorted."""
    return c.eval_py("local o = {} for k, b in pairs(%s.b) do if b:IsShown() then o[#o + 1] = k end end "
                     "table.sort(o) return o" % BAR)


def chips(c):
    """{ id: chip shown } of every mover on the screen."""
    return c.eval_py("local o = {} for _, d in ipairs(ns.Layout:Items()) do local m = ns.EditMode:Mover(d.id) "
                     "if m and m:IsShown() then o[d.id] = m.tag:IsShown() end end return o")


def signed(v):
    return ("+%d" % v) if v > 0 else ("%d" % v)


@case
def one_slim_bar_at_the_top_reads_out_the_pick_and_holds_its_tools():
    w, c = boot()
    open_edit(w, c)
    # flush to the top edge, in the middle, 28 tall; no toolbar floating over the frames, no banner
    top, cx, h = c.eval("local b = %s; return b:GetTop(), (b:GetLeft() + b:GetRight()) / 2, b:GetHeight()" % BAR)
    assert abs(top - H) < 0.6 and abs(cx - W / 2) < 0.6 and h == 28, (top, cx, h)
    assert c.eval("return DisasterZoneEditToolbar == nil") is True
    assert c.eval("return ns.EditMode:GetToolbar() == ns.EditMode:GetBar()") is True
    assert readout(c) == "Click a frame to pick it"
    assert tools(c) == sorted(["undo", "redo", "grid", "snap", "names", "frames", "done"]), tools(c)
    # one picked: its name, its centre from the screen's centre, its size; its tools in the bar
    c.eval("ns.EditMode:Select({ 'session' })")
    l, b, bw, bh = box(c, "session")
    dx, dy = round(l + bw / 2 - W / 2), round(b + bh / 2 - H / 2)
    assert readout(c) == "Raid session bar  \u00b7  centre %s, %s  \u00b7  100%%" % (signed(dx), signed(dy)), readout(c)
    assert set(tools(c)) >= {"ch", "cv", "mirror1", "reset", "hide"}, tools(c)
    assert not set(tools(c)) & {"al", "dh", "mirror2", "unmirror"}, tools(c)
    assert c.eval("local B = %s; return B.b.ch:GetParent() == B and B.b.reset:GetParent() == B" % BAR) is True
    # it stays put at the top edge (only its width follows what is picked, centred)
    assert abs(c.eval("return %s:GetTop()" % BAR) - H) < 0.6
    # the size reads out after a notch of the wheel
    c.eval("ns.EditMode:Wheel('session', 1)")
    assert readout(c).endswith("105%"), readout(c)
    # several: a count and the line-ups; a pair: Mirror
    c.eval("ns.EditMode:Select({ 'session', 'roll', 'reminder' })")
    assert readout(c) == "3 frames picked", readout(c)
    for k in ("al", "ac", "ar", "at", "am", "ab", "dh", "dv", "ch", "cv"):
        assert k in tools(c), (k, tools(c))
    assert "mirror2" not in tools(c) and "mirror1" not in tools(c)
    c.eval("ns.EditMode:Select({ 'session', 'roll' })")
    assert "mirror2" in tools(c) and c.eval("return %s.b.dh:IsEnabled()" % BAR) is False
    # undo / redo follow the history
    assert c.eval("return %s.b.undo:IsEnabled()" % BAR) is True          # (the wheel)
    assert c.eval("return %s.b.redo:IsEnabled()" % BAR) is False
    c.eval("%s.b.undo:Click()" % BAR)
    assert c.eval("return %s.b.redo:IsEnabled()" % BAR) is True
    # Done closes
    c.eval("%s.b.done:Click()" % BAR)
    assert c.eval("return ns.EditMode:IsActive()") is False
    w.assert_no_errors()


@case
def the_bar_fits_a_1280_wide_screen_whatever_is_picked():
    w, c = boot()
    open_edit(w, c)
    c.eval("ns.DB:SetSetting('editlayout.all', true); ns.EditMode:SetPreviews(); ns.EditMode:Refresh()")
    ids = c.eval_py("local o = {} for _, d in ipairs(ns.Layout:Items()) do local m = ns.EditMode:Mover(d.id) "
                    "if m and m:IsShown() then o[#o + 1] = d.id end end return o")
    assert len(ids) >= 6, ids
    widest = 0
    for i in ids:
        c.eval("ns.EditMode:Select({ ... })", i)
        widest = max(widest, c.eval("return %s:GetWidth()" % BAR))
    for n in (2, 3):
        c.eval("ns.EditMode:Select({ ... })", *ids[:n])
        widest = max(widest, c.eval("return %s:GetWidth()" % BAR))
    # (the mock measures text at 6 units a letter, wider than the game's font: what fits here fits there)
    assert widest < 1200, widest
    w.assert_no_errors()


@case
def grid_snap_and_names_switch_from_the_bar():
    w, c = boot()
    open_edit(w, c)
    B = BAR + ".b"
    c.eval("ns.DB:SetSetting('editlayout.grid', 0); ns.EditMode:Refresh()")
    assert plain(c.eval("return %s.grid.fs:GetText()" % B)) == "Grid  Off"
    seen = []
    for _ in range(4):
        c.eval("%s.grid:Click()" % B)
        seen.append(c.eval("return ns.DB:GetSetting('editlayout.grid')"))
    assert seen == [8, 16, 32, 0], seen
    c.eval("%s.grid:Click()" % B)
    assert plain(c.eval("return %s.grid.fs:GetText()" % B)) == "Grid  8"
    # Snap: all three kinds off; on again, the ones that were on
    c.eval("ns.DB:SetSetting('editlayout.snapGaps', false); ns.EditMode:Refresh()")
    assert plain(c.eval("return %s.snap.fs:GetText()" % B)) == "Snap  On"
    c.eval("%s.snap:Click()" % B)
    snaps = c.eval("return ns.DB:GetSetting('editlayout.snapScreen'), ns.DB:GetSetting('editlayout.snapFrames'), "
                   "ns.DB:GetSetting('editlayout.snapGaps')")
    assert list(snaps) == [False, False, False], snaps
    assert plain(c.eval("return %s.snap.fs:GetText()" % B)) == "Snap  Off"
    # (nothing snaps now: 4 px off the centre stays 4 px off; the grid off too)
    c.eval("ns.DB:SetSetting('editlayout.grid', 0)")
    l0 = box(c, "toasts")[0]
    drag(w, c, "toasts", 4, -100)
    assert abs(box(c, "toasts")[0] - (l0 + 4)) < 0.6
    c.eval("%s.snap:Click()" % B)
    snaps = c.eval("return ns.DB:GetSetting('editlayout.snapScreen'), ns.DB:GetSetting('editlayout.snapFrames'), "
                   "ns.DB:GetSetting('editlayout.snapGaps')")
    assert list(snaps) == [True, True, False], snaps
    # Names: every frame's chip, not only the picked one's
    c.eval("ns.EditMode:Select({ 'session' })")
    ch = chips(c)
    assert ch["session"] is True and not any(v for k, v in ch.items() if k != "session"), ch
    c.eval("%s.names:Click()" % B)
    assert all(chips(c).values()), chips(c)
    assert c.eval("return %s.names.lit" % B) is True
    c.eval("%s.names:Click()" % B)
    assert sum(1 for v in chips(c).values() if v) == 1
    w.assert_no_errors()


@case
def frames_opens_a_panel_under_the_bar_with_profiles_snaps_and_the_list():
    w, c = boot()
    open_edit(w, c)
    P = "ns.EditMode:GetPanel()"
    assert c.eval("return %s:IsShown()" % P) is False
    c.eval("%s.b.frames:Click()" % BAR)
    assert c.eval("return %s:IsShown()" % P) is True
    assert c.eval("return %s.b.frames.lit" % BAR) is True
    top, right, bar_right = c.eval("return %s:GetTop(), %s:GetRight(), %s:GetRight()" % (P, P, BAR))
    assert abs(top - (H - 28 - 4)) < 0.6 and abs(right - bar_right) < 1, (top, right, bar_right)
    texts = c.eval_py("local o = {} local function walk(f) for _, r in ipairs({ f:GetRegions() }) do "
                      "if r.GetText and r:GetText() and r:IsVisible() then o[#o + 1] = r:GetText() end end "
                      "for _, ch in ipairs({ f:GetChildren() }) do walk(ch) end end walk(%s) return o" % P)
    for want in ("Profile", "Default", "Screen centre and edges", "Other frames", "Equal gaps", "My character",
                 "Everything", "Reset all\u2026", "Raid session bar", "Roll frame"):
        assert any(want in plain(t) for t in texts), (want, texts)
    # not undo / redo / grid / done: those are in the bar
    assert not any(plain(t) in ("Undo", "Redo", "Done", "Grid") for t in texts), texts
    # one kind switched off in the panel: the bar's Snap still says On (the other two are)
    c.eval("local cb = %s.snaps[3]; cb:Click()" % P)
    assert c.eval("return ns.DB:GetSetting('editlayout.snapGaps')") is False
    assert plain(c.eval("return %s.b.snap.fs:GetText()" % BAR)) == "Snap  On"
    # a row picks its frame; the panel stays where it opened while the bar grows
    c.eval("for _, r in ipairs(%s.rows) do if r.id == 'roll' and r:IsShown() then r:Click() end end" % P)
    assert c.eval_py("return ns.EditMode:Selection()") == ["roll"]
    assert readout(c).startswith("Roll frame")
    assert abs(c.eval("return %s:GetRight()" % P) - right) < 0.6
    # Esc: the panel first, then the pick, then done
    assert c.eval("return ns.EditMode:OnKey('ESCAPE')") is True
    assert c.eval("return %s:IsShown()" % P) is False and c.eval("return #ns.EditMode:Selection()") == 1
    assert c.eval("return %s.b.frames.lit" % BAR) is not True
    c.eval("ns.EditMode:OnKey('ESCAPE')")
    assert c.eval("return #ns.EditMode:Selection()") == 0 and c.eval("return ns.EditMode:IsActive()") is True
    c.eval("ns.EditMode:OnKey('ESCAPE')")
    assert c.eval("return ns.EditMode:IsActive()") is False
    w.assert_no_errors()


@case
def the_bar_steps_back_over_a_picked_frame_and_while_dragging():
    w, c = boot()
    open_edit(w, c)
    alpha = "return %s:GetAlpha()" % BAR
    assert c.eval(alpha) == 1
    # the session bar moved up under the bar and picked: 32%, full again under the mouse
    l, b, bw, bh = box(c, "session")
    c.eval("ns.Layout:MoveTo('session', ...)", l, H - bh - 6)
    c.eval("ns.EditMode:Select({ 'session' })")
    w.tick(0.5)
    assert abs(c.eval(alpha) - 0.32) < 0.01, c.eval(alpha)
    c.eval("%s.IsMouseOver = function() return true end" % BAR)
    w.tick(0.5)
    assert abs(c.eval(alpha) - 1) < 0.01
    c.eval("%s.IsMouseOver = nil" % BAR)
    w.tick(0.5)
    assert abs(c.eval(alpha) - 0.32) < 0.01
    # (the Frames panel open: full too)
    c.eval("ns.EditMode:ShowFrames(true)")
    w.tick(0.5)
    assert abs(c.eval(alpha) - 1) < 0.01
    c.eval("ns.EditMode:ShowFrames(false)")
    # a frame away from the bar picked: full
    c.eval("ns.EditMode:Select({ 'roll' })")
    w.tick(0.5)
    assert abs(c.eval(alpha) - 1) < 0.01
    # the centre cross and the grid only while something moves
    c.eval("ns.DB:SetSetting('editlayout.grid', 16); ns.EditMode:DrawGrid()")
    shown = "local o = DisasterZoneEditMode; return o.axisV:IsShown(), o.axisH:IsShown(), o.gridLayer:IsShown()"
    assert list(c.eval(shown)) == [False, False, False]
    l, b, bw, bh = box(c, "roll")
    c.eval("__MOCK.cursor = { ... }", l + bw / 2, b + bh / 2)
    c.eval("ns.EditMode:OnMoverDown('roll', 'LeftButton')")
    w.tick(0.1)
    assert c.eval(alpha) == 1                          # (a press is not a drag yet)
    c.eval("__MOCK.cursor = { ... }", l + bw / 2 + 40, b + bh / 2 - 80)
    w.tick(0.5)
    assert abs(c.eval(alpha) - 0.18) < 0.01, c.eval(alpha)
    assert list(c.eval(shown)) == [True, True, True]
    assert c.eval("return ns.EditMode:Mover('roll').tag:IsShown()") is False      # (out of the guides' way)
    c.eval("ns.EditMode:EndDrag()")
    w.tick(0.5)
    assert abs(c.eval(alpha) - 1) < 0.01
    assert list(c.eval(shown)) == [False, False, False]
    assert c.eval("return ns.EditMode:Mover('roll').tag:IsShown()") is True
    # a resize fades it too
    c.eval("ns.EditMode:StartResize(1, -1)")
    w.tick(0.5)
    assert abs(c.eval(alpha) - 0.18) < 0.01
    c.eval("ns.EditMode:EndDrag()")
    w.tick(0.5)
    # a meter stack dragged by its header (MeterPanels asks EditMode:SnapBox each step) as well
    c.eval("local f = CreateFrame('Frame', nil, UIParent); f:SetSize(200, 100); "
           "ns.EditMode:SnapBox(f, 857, 700, 200, 100)")
    w.tick(0.1)
    assert c.eval(alpha) < 0.6
    w.tick(0.6)
    assert abs(c.eval(alpha) - 1) < 0.01
    w.assert_no_errors()


@case
def boxes_are_quiet_until_picked():
    w, c = boot()
    open_edit(w, c)
    M = "ns.EditMode:Mover('roll')"
    edge = ("local e = ns.EditMode:Mover(...).edges[1]; local st = __MOCK.OBJ[e]; local r, g, b, a = e:GetVertexColor(); "
            "local ulx, uly, llx, lly, urx = e:GetTexCoord(); return e:GetTexture(), st.hwrap, a, urx, e:GetHeight()")
    # not picked: a faint dashed outline (the dash tile repeated along the edge), no fill, no name
    tex, wrap, a, right, thick = c.eval(edge, "roll")
    assert "Media\\Edit\\dash_h" in tex and wrap == "REPEAT" and abs(a - 0.2) < 0.01, (tex, wrap, a)
    bw = box(c, "roll")[2]
    assert abs(right - (bw + 6) / 6) < 0.05, (right, bw)                 # (a dash and a gap every 6 units)
    assert c.eval("return ns.EditMode:Mover(...).edges[3]:GetTexture()", "roll").endswith("dash_v")
    assert list(c.eval("return %s.state, %s.tag:IsShown(), %s.wash:IsShown()" % (M, M, M))) == ["quiet", False, False]
    # under the mouse: a gold outline and its name
    c.eval("local m = %s; m.IsMouseOver = function() return true end; m:GetScript('OnEnter')(m)" % M)
    assert list(c.eval("return %s.state, %s.tag:IsShown()" % (M, M))) == ["hover", True]
    c.eval("local m = %s; m.IsMouseOver = nil; m:GetScript('OnLeave')(m)" % M)
    assert list(c.eval("return %s.state, %s.tag:IsShown()" % (M, M))) == ["quiet", False]
    # picked: a solid gold edge 1.5 wide, a faint fill, a glow, its name in a dark chip with a gold edge
    c.eval("ns.EditMode:Select({ 'roll' })")
    tex, wrap, a, right, thick = c.eval(edge, "roll")
    assert tex == "Color" and thick == 1.5, (tex, thick)
    got = c.eval("local m = %s; return m.state, m.tag:IsShown(), m.wash:IsShown(), m.glow[1]:IsShown()" % M)
    assert list(got) == ["picked", True, True, True], got
    assert c.eval("return __MOCK.OBJ[%s.tag.bg].color[4]" % M) > 0.9
    # its mirrored partner: dashed gold
    c.eval("ns.Layout:SetMirror('roll', 'toasts'); ns.EditMode:Refresh()")
    assert c.eval("return ns.EditMode:Mover('toasts').state") == "partner"
    tex, wrap, a, right, thick = c.eval(edge, "toasts")
    assert "dash_h" in tex and thick == 1.5
    # the world is dimmed lightly
    assert c.eval("return __MOCK.OBJ[DisasterZoneEditMode.dim].color[4]") <= 0.12
    # a chip keeps out from under the bar: a frame at the top has its name under it
    l, b, bw, bh = box(c, "session")
    c.eval("ns.Layout:MoveTo('session', ...)", l, H - bh - 6)
    c.eval("ns.EditMode:Select({ 'session' })")
    tag_top = c.eval("return ns.EditMode:Mover('session').tag:GetTop()")
    assert tag_top < H - bh - 6, tag_top
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
