#!/usr/bin/env python
"""The class planners' shared parts (refactor 1.4 phase 4): Core/ClassPlanner.lua and UI/PlannerWindow.lua under the
Blessings and Totems planners. Both windows sit on the Tool window layout with a tool banner; an empty group shows the
empty state; tooltips, dragging and the banner's actions run without errors; the shared core keeps each planner's
own records, prefix, settings and events apart.

Run: luaenv\\Scripts\\python.exe tests\\blessings\\test_planner_window.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from harness import World, Client  # noqa: E402
from _common import case, run_all  # noqa: E402


def txt(x):
    return x.decode() if isinstance(x, bytes) else x


def solo_warrior():
    w = World()
    vic = Client(w, "Victhar", class_file="WARRIOR", guild_rank=3)
    vic.load_addon()
    w.tick(1)
    return w, vic


@case
def both_windows_are_tool_layouts_with_a_banner():
    w, vic = solo_warrior()
    for ui in ("BlessingsUI", "TotemsUI"):
        r = vic.eval_py("""
            local ui = ns[...]
            ui:Open()
            local f = ui:GetFrame()
            return { kind = f.layout.kind, title = f.banner.titleText, kicker = f.banner.kicker:GetText(),
                     auto = f.auto ~= nil and f.auto:IsEnabled(), report = f.report ~= nil and f.report:IsEnabled(),
                     h = f.banner:GetHeight() }
        """, ui)
        assert txt(r["kind"]) == "tool", r
        assert txt(r["title"]) in ("Blessings", "Totems"), r
        assert txt(r["kicker"]) == "SOLO", r
        assert r["auto"] is False and r["report"] is False, r         # (nobody to assign, no group to report to)
        assert r["h"] == 84, r
        vic.eval("ns[...]:Close()", ui)
    w.assert_no_errors()


@case
def no_paladins_and_no_shamans_show_the_empty_state():
    w, vic = solo_warrior()
    vic.eval("ns.BlessingsUI:Open()")
    r = vic.eval_py("local f = ns.BlessingsUI:GetFrame(); return { f.empty:IsShown(), f.empty.title:GetText(), "
                    "f.rule.add ~= nil and f.rule.add:IsShown() or false }")
    assert r[0] is True and txt(r[1]) == "No paladins here yet" and r[2] is False, r
    vic.eval("ns.TotemsUI:Open()")
    r = vic.eval_py("local f = ns.TotemsUI:GetFrame(); return { f.empty:IsShown(), f.empty.title:GetText(), "
                    "f.rule:IsShown() }")
    assert r[0] is True and txt(r[1]) == "No shamans here yet" and r[2] is False, r
    w.assert_no_errors()


@case
def demo_tooltips_drag_and_actions_run_clean():
    w, vic = solo_warrior()
    vic.slash("/dz demo on")
    w.tick(1)
    vic.eval("ns.BlessingsUI:Open()")
    w.tick(0.3)
    out = vic.eval_py("""
        local f = ns.BlessingsUI:GetFrame()
        local function hover(fr) __MOCK.call_script(fr, 'OnEnter')
            local n = GameTooltip:NumLines(); __MOCK.call_script(fr, 'OnLeave'); return n end
        local r = f.rows[1]
        local out = { cell = hover(r.cells[1]), card = hover(r.card), aura = hover(r.card.aura),
                      head = hover(f.heads[1]), pal = hover(f.palette[1]), chip = hover(f.chips[1]),
                      empty = f.empty:IsShown(), add = f.rule.add ~= nil and f.rule.add:IsShown() }
        -- a drag from the palette onto Caelith's card gives him that blessing for every class
        f.palette[1]:GetScript('OnDragStart')(f.palette[1])
        local card
        for _, row in ipairs(f.rows) do if row.name == 'Caelith' then card = row.card end end
        card.IsMouseOver = function() return true end
        ns.BlessingsUI.EndDrag()
        card.IsMouseOver = nil
        out.dropped = ns.Blessings:GetAssign('Caelith', 1)
        return out
    """)
    for k in ("cell", "card", "aura", "head", "pal", "chip"):
        assert out[k] and out[k] > 0, (k, out)
    assert out["empty"] is False and out["add"] is True, out
    assert out["dropped"] == 3, out                                  # (the palette's first: Kings)
    vic.eval("ns.TotemsUI:Open()")
    w.tick(0.3)
    out = vic.eval_py("""
        local f = ns.TotemsUI:GetFrame()
        local function hover(fr) __MOCK.call_script(fr, 'OnEnter')
            local n = GameTooltip:NumLines(); __MOCK.call_script(fr, 'OnLeave'); return n end
        local r = f.rows[1]
        return { cell = hover(r.cells[1]), card = hover(r.card), hero = hover(r.hero), es = hover(r.es),
                 group = hover(r.groupHit), chip = hover(f.chips[1]), raid = hover(f.raidBtn) }
    """)
    for k in ("cell", "card", "hero", "es", "group", "chip", "raid"):
        assert out[k] and out[k] > 0, (k, out)
    # the banner's Report in demo mode prints to me only (nothing on the wire)
    vic.eval("ns.TotemsUI:GetFrame().report:Click(); ns.BlessingsUI:GetFrame().report:Click()")
    sent = [e for e in vic.sent_addon if txt(e["prefix"]) in ("PLPWR", "SHPWR")]
    assert not sent, sent
    w.assert_no_errors()


@case
def each_planner_keeps_its_own_core():
    w, vic = solo_warrior()
    r = vic.eval_py("""
        local B, T = ns.Blessings, ns.Totems
        return { B.PREFIX, T.PREFIX, B.planner.event, T.planner.event, B.planner.records, T.planner.records,
                 B.Store ~= T.Store, B.IsPaladin ~= nil, T.IsShaman ~= nil, B:IsPaladin(), T:IsShaman(),
                 type(B.Store().presets), type(T.Store().boss) }
    """)
    assert [txt(x) if isinstance(x, (bytes, str)) else x for x in r] == [
        "PLPWR", "SHPWR", "BLESSINGS_CHANGED", "TOTEMS_CHANGED", "pals", "shamans", True, True, True, False, False,
        "table", "table"], r
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
