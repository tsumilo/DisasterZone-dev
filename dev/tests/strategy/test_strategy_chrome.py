"""The strategy board's chrome (makeover 2026-10-06): the header, the page tabs, the map link, the dock, the panel.

Covers: Discard asks (another text for a strategy never saved), Done while nothing changed, "Saved just now" after
Save; the page tabs (the open tab's menu, rename in place, Delete asks and Ctrl+Z brings the page back, no + at six
pages); the name and the page's notes typed in place, and a refresh (a live board's) never throwing a half-typed word
away; undo / redo shown only when usable; the drawings count from 60 (orange from 72, "is full" at 80, a drawing tool
saying why it does nothing); the map menu (pictures, who is fought on a floor, a submenu per raid, Reset zoom); the More
menu per mode; my jobs as chips that open their page; the raids that use a strategy as links; the raid's players on the
panel while assigning (a drag still lands, the map stays 840 wide in every mode); presence circles and page dots; the
keys card; switching a raid's strategy asks when names would drop.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_chrome.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, K, DAY, now, create, signup, save_council, fill  # noqa: E402
from _common import case, run_all, strip_codes, menu_texts  # noqa: E402

BOSS = "BlackTemple:Council"
W = "_G.DisasterZoneStrategyBoard"
B = "ns.StrategyBoard"
ST = B + ":GetState()"

HELPERS = r"""
-- the entry of the last menu whose words (icons, colours and leading spaces aside) start with prefix
function T_entry(prefix, root)
  local found
  local function strip(s) return ((s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("^%s+", "")) end
  local function walk(d)
    for _, c in ipairs(d.children) do
      if found then return end
      if strip(c.text):sub(1, #prefix) == prefix then found = c; return end
      walk(c)
    end
  end
  walk(root or __MOCK.last_menu)
  return found
end
function T_pick(prefix)
  local e = T_entry(prefix)
  if not e then error("no menu entry starting with " .. prefix) end
  return __MOCK.menu_select(e.text, e.parent)
end
function T_words(root)
  local out = {}
  local function strip(s) return ((s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("^%s+", "")) end
  for _, c in ipairs((root or __MOCK.last_menu).children) do
    if c.text then out[#out + 1] = strip(c.text) end
  end
  return out
end
"""


def names():
    return (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"),
            ("Sam", 3, "ROGUE"), ("Hana", 3, "HUNTER"))


def setup():
    w, c = world(names())
    for x in c.values():
        x.eval(HELPERS)
    return w, c


def shown(cl, expr):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr) is True


def st(cl):
    return cl.eval_py("local s = %s; return { mode = s.mode, dirty = s.dirty, page = s.page, n = s.strat and s.strat.n, "
                      "id = s.strat and s.strat.id, pages = s.strat and #s.strat.p }" % ST)


def change(cl, code):
    cl.eval("local s = %s.strat; (loadstring('local s = ...; ' .. ...))(s); %s:MarkDirty(true)" % (ST, B), code)


def words(cl):
    return cl.eval_py("return T_words()")


# ------------------------------------------------------------------------------------------------------------------
@case
def discard_asks_done_while_clean_and_saved_just_now():
    w, c = setup()
    bob = c["Bob"]
    # a strategy never saved: Discard says it is gone for good; Keep editing keeps it
    bob.eval(B + ":NewStrategy(...)", BOSS, "Fresh")
    assert shown(bob, W + ".cancelBtn") and shown(bob, W + ".saveBtn") and not shown(bob, W + ".doneBtn")
    assert bob.eval("return %s.cancelBtn:GetText()" % W) == "Discard"
    assert strip_codes(bob.eval("return %s.stateTag.fs:GetText()" % W)) == "Unsaved"
    bob.click(bob.eval("return %s.cancelBtn" % W))
    pop = bob.eval_py("return __MOCK.popup_log[#__MOCK.popup_log]")
    assert pop["which"] == "DISASTERZONE_STRAT_DISCARD" and "never saved" in pop["text"], pop
    bob.cancel_popup("DISASTERZONE_STRAT_DISCARD")
    assert st(bob)["n"] == "Fresh" and shown(bob, W)
    bob.click(bob.eval("return %s.cancelBtn" % W))
    bob.accept_popup("DISASTERZONE_STRAT_DISCARD")
    assert not shown(bob, W)
    # a saved one: editing with nothing changed shows Done (no Save, no Discard, no tag), and goes back to reading
    sid = save_council(bob)
    w.tick(1)
    bob.eval(B + ":OpenStrategy(..., 'edit')", sid)
    assert shown(bob, W + ".doneBtn") and not shown(bob, W + ".saveBtn") and not shown(bob, W + ".cancelBtn")
    assert not shown(bob, W + ".stateTag")
    bob.click(bob.eval("return %s.doneBtn" % W))
    assert st(bob)["mode"] == "view" and shown(bob, W + ".editBtn")
    # a change, then Discard: the saved version stays
    bob.click(bob.eval("return %s.editBtn" % W))
    change(bob, "s.n = 'Changed'")
    bob.click(bob.eval("return %s.cancelBtn" % W))
    pop = bob.eval_py("return __MOCK.popup_log[#__MOCK.popup_log]")
    assert "saved version stays" in pop["text"], pop
    bob.accept_popup("DISASTERZONE_STRAT_DISCARD")
    assert st(bob)["n"] == "25 farm" and st(bob)["mode"] == "view"
    # Save: back to reading it, "Saved just now" beside the name
    bob.click(bob.eval("return %s.editBtn" % W))
    change(bob, "s.n = 'Renamed'")
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(1)
    assert st(bob)["mode"] == "view"
    assert strip_codes(bob.eval("return %s.meta:GetText()" % W)) == "Saved just now"
    # someone else's: who made it and when, no Edit
    rita = c["Rita"]
    rita.eval(B + ":OpenStrategy(...)", sid)
    meta = strip_codes(rita.eval("return %s.meta:GetText()" % W))
    assert meta.startswith("by Bob"), meta
    assert not shown(rita, W + ".editBtn") and shown(rita, W + ".shareBtn") and shown(rita, W + ".moreBtn")
    w.assert_no_errors()


@case
def page_tabs_menu_rename_in_place_and_delete_asks():
    w, c = setup()
    bob = c["Bob"]
    sid = save_council(bob)
    w.tick(1)
    bob.eval(B + ":OpenStrategy(..., 'edit')", sid)
    # the open tab carries the chevron; a click on it opens the page menu, a click on another tab goes there
    assert bob.eval("return %s.tabs[1].chev:IsShown() and not %s.tabs[2].chev:IsShown()" % (W, W)) is True
    bob.click(bob.eval("return %s.tabs[1]" % W))
    assert words(bob)[:2] == ["P1", "Rename"], words(bob)
    assert "Delete" in words(bob) and not any("..." in x for x in words(bob)), words(bob)
    bob.click(bob.eval("return %s.tabs[2]" % W))
    assert st(bob)["page"] == 2
    # rename in place: the tab is the field; Enter keeps the name, Esc goes back
    bob.eval(B + ":RenamePage(2)")
    E = W + ".tabEdit"
    assert bob.eval("return %s:IsShown() and %s:HasFocus() and %s:GetText()" % (E, E, E)) == "P2"
    bob.type_text(bob.eval("return %s" % E), "Collapse", enter=True)
    assert bob.eval("return %s.strat.p[2].n" % ST) == "Collapse" and not shown(bob, E)
    bob.eval(B + ":RenamePage(2)")
    bob.type_text(bob.eval("return %s" % E), "Nope")
    bob.press_escape(bob.eval("return %s" % E))
    assert bob.eval("return %s.strat.p[2].n" % ST) == "Collapse"
    # Delete asks, with what goes along; Ctrl+Z brings the page back
    bob.eval(B + ":PageMenu(UIParent, 2)")
    bob.eval("T_pick('Delete')")
    pop = bob.eval_py("return __MOCK.popup_log[#__MOCK.popup_log]")
    assert pop["which"] == "DISASTERZONE_STRAT_DELETE_PAGE" and "Collapse" in pop["text"], pop
    assert "notes go with it" in strip_codes(pop["text"]) and "Ctrl+Z" in pop["text"], pop
    assert st(bob)["pages"] == 2
    bob.accept_popup("DISASTERZONE_STRAT_DELETE_PAGE")
    assert st(bob)["pages"] == 1
    bob.eval(B + ":Undo()")
    assert st(bob)["pages"] == 2
    # six pages, the most a strategy holds: no +
    for _ in range(4):
        bob.eval(B + ":AddPage()")
    assert st(bob)["pages"] == 6 and not shown(bob, W + ".addPage")
    w.assert_no_errors()


@case
def the_name_and_the_notes_are_typed_in_place_and_a_refresh_keeps_them():
    w, c = setup()
    bob = c["Bob"]
    sid = save_council(bob)
    w.tick(1)
    bob.eval(B + ":OpenStrategy(..., 'edit')", sid)
    # the name: a click turns it into a field; a refresh (a live board's) while typing keeps the field and the word
    bob.click(bob.eval("return %s.titleBtn" % W))
    T = W + ".titleEdit"
    assert bob.eval("return %s:IsShown() and %s:HasFocus()" % (T, T)) is True
    bob.type_text(bob.eval("return %s" % T), "Half-typ")
    change(bob, "s.p[1].e[1].x = 333")          # (as a change from the live board would)
    bob.eval(B + ":Refresh()")
    assert bob.eval("return %s:IsShown() and %s:HasFocus() and %s:GetText()" % (T, T, T)) == "Half-typ"
    assert not shown(bob, W + ".title")
    assert st(bob)["n"] == "25 farm"            # nothing goes out per key
    bob.type_text(bob.eval("return %s" % T), "Half-typed", enter=True)
    assert st(bob)["n"] == "Half-typed" and shown(bob, W + ".title")
    # the notes: page 2 has some; a click on them types in place, a refresh keeps the text, focus lost keeps it
    bob.eval("%s.page = 2; %s:Refresh()" % (ST, B))
    N = W + ".blocks.notesCard"
    assert shown(bob, N) and strip_codes(bob.eval("return %s.text:GetText()" % N)) == "Dampen magic pre-pull"
    bob.click(bob.eval("return %s.hit" % N))
    assert bob.eval("return %s.edit:IsShown() and %s.edit:HasFocus()" % (N, N)) is True
    bob.type_text(bob.eval("return %s.edit" % N), "Dampen magic pre-pull, then")
    bob.eval("local s = %s; s.strat.p[1].e[1].x = 444; %s:Refresh()" % (ST, B))
    assert bob.eval("return %s.edit:HasFocus() and %s.edit:GetText()" % (N, N)) == "Dampen magic pre-pull, then"
    assert bob.eval("return %s.strat.p[2].no" % ST) == "Dampen magic pre-pull"
    bob.eval("%s.edit:ClearFocus()" % N)
    assert bob.eval("return %s.strat.p[2].no" % ST) == "Dampen magic pre-pull, then"
    # Esc goes back; a page without notes offers them under Add a block
    bob.click(bob.eval("return %s.hit" % N))
    bob.type_text(bob.eval("return %s.edit" % N), "gone")
    bob.press_escape(bob.eval("return %s.edit" % N))
    assert bob.eval("return %s.strat.p[2].no" % ST) == "Dampen magic pre-pull, then"
    bob.eval("%s.page = 1; %s:Refresh()" % (ST, B))
    cell = bob.eval("return %s.blocks.notesBtn" % W)
    assert bob.eval("local c = ...; return c.title and c.title:GetText()", cell) == "Page notes"
    bob.click(cell)
    bob.type_text(bob.eval("return %s.edit" % N), "Stack on the skull")
    bob.eval("%s.edit:ClearFocus()" % N)
    assert bob.eval("return %s.strat.p[1].no" % ST) == "Stack on the skull"
    w.assert_no_errors()


@case
def undo_redo_and_the_drawings_count():
    w, c = setup()
    bob = c["Bob"]
    sid = save_council(bob)
    w.tick(1)
    bob.eval(B + ":OpenStrategy(..., 'edit')", sid)
    U, R = W + ".tools.undoBtn", W + ".tools.redoBtn"
    assert not shown(bob, U) and not shown(bob, R)
    change(bob, "s.p[1].e[1].x = 310")
    assert shown(bob, U) and not shown(bob, R)
    bob.eval(B + ":Undo()")
    assert not shown(bob, U) and shown(bob, R)
    # the count: nothing under 60, grey from 60, orange from 72, "P1 is full" at 80
    def count(n):
        bob.eval("local p = %s.strat.p[1]; while #p.e > ... do table.remove(p.e) end; "
                 "while #p.e < ... do p.e[#p.e + 1] = { t = 'i', x = 100, y = 100, i = 'rt1', z = 20 } end; "
                 "%s:MarkDirty(true)" % (ST, B), n)
        if not shown(bob, W + ".countBtn"):
            return None
        fs = W + ".countFs"
        r, g, b = bob.eval_py("return { %s:GetTextColor() }" % fs)[:3]
        return strip_codes(bob.eval("return %s:GetText()" % fs)), round(r, 2), round(g, 2)
    assert count(59) is None
    assert count(60) == ("60 of 80 drawings", 0.62, 0.62)
    assert count(72) == ("72 of 80 drawings", 1.0, 0.6)
    assert count(80) == ("P1 is full: 80 drawings", 1.0, 0.42)
    # a drawing tool says why it does nothing; select still works
    bob.click(bob.eval("return %s.tools.btns[3]" % W))
    assert bob.eval("return %s.canvas.tool" % W) == "select"
    assert bob.eval("return GameTooltip:IsShown()") is True
    w.assert_no_errors()


@case
def the_map_menu_and_the_more_menu():
    w, c = setup()
    bob, rita = c["Bob"], c["Rita"]
    sid = save_council(bob)
    w.tick(1)
    bob.eval(B + ":OpenStrategy(..., 'edit')", sid)
    bob.eval("%s.strat.p[1].m = 900129; %s:Refresh()" % (ST, B))        # the Council's floor
    assert strip_codes(bob.eval("return %s.mapBtn.fs:GetText()" % W)) == "Chamber of Command"
    bob.eval("%s.mapBtn:OpenMenu()" % W)
    menu = bob.last_menu()
    texts = [t[2] for t in menu_texts(menu) if t[2]]
    assert strip_codes(texts[0]) == "Map of P1", texts
    teron = [t for t in texts if "Gorefiend's Vigil" in t]
    assert teron and "Media\\Maps\\BT04_a" in teron[0] and "Teron" in strip_codes(teron[0]), teron
    assert any(strip_codes(t).strip() == "Map ID" for t in texts) and any("Reset zoom" in t for t in texts)
    kara = bob.eval_py("local o = T_entry('Other raids'); local k = T_entry('Karazhan', o); local out = {}; "
                       "for _, ch in ipairs(k.children) do out[#out + 1] = ch.text end; return out")
    assert any("Servants' Quarters" in x and "Attumen" in strip_codes(x) for x in kara), kara
    # More: while editing, Auto-mark and Practice (Collaborators for the owner)
    bob.click(bob.eval("return %s.moreBtn" % W))
    assert words(bob) == ["25 farm", "Auto-mark", "Practice", "Collaborators"], words(bob)
    # reading it, mine: Practice, Copy, Collaborators, Delete
    bob.click(bob.eval("return %s.doneBtn" % W))
    bob.click(bob.eval("return %s.moreBtn" % W))
    assert [x for x in words(bob) if x] == ["25 farm", "Practice", "Copy", "Collaborators", "Delete"], words(bob)
    # someone else's, read by a member: Practice and Copy
    rita.eval(B + ":OpenStrategy(...)", sid)
    rita.click(rita.eval("return %s.moreBtn" % W))
    assert [x for x in words(rita) if x] == ["25 farm", "Practice", "Copy"], words(rita)
    w.assert_no_errors()


@case
def jobs_chips_in_raids_links_and_the_players_on_the_panel():
    w, c = setup()
    bob, hana, gina = c["Bob"], c["Hana"], c["Gina"]
    sid = save_council(bob)
    occ = create(bob, i="bt", t=now(bob) + DAY)
    w.tick(2)
    for n, sp in (("Hana", None), ("Lee", 3), ("Gina", 2), ("Sam", None)):
        signup(c[n], occ, "A", sp)
    w.tick(2)
    # assigning: the raid's players on the panel's top, by role; the tables under them; the map stays 840 wide
    bob.eval(B + ":OpenRaid(...)", occ, BOSS, "fill")
    assert bob.eval("return %s.canvas.frame:GetWidth()" % W) == 840
    assert shown(bob, W + ".pool") and bob.eval("return #%s.pool.heads" % W) == 4
    names = bob.eval_py("local out = {}; for _, ch in ipairs(%s.pool.chips) do if ch:IsShown() then "
                        "out[#out + 1] = ch.key end end; return out" % W)
    assert sorted(names) == sorted([K("Hana"), K("Lee"), K("Gina"), K("Sam")]), names
    h = bob.eval("return %s.pool.h" % W)
    pt = bob.eval_py("local _, _, _, x, y = %s.blocks.scroll:GetPoint(1); return { x, y }" % W)
    assert pt == [858, -(84 + h + 8)], (pt, h)
    # a drag onto a slot lands there; the chip fades once placed
    bob.eval("%s.blocks.SlotUnderCursor = function() return 'zn.1.1' end" % W)
    chip = bob.eval("for _, ch in ipairs(%s.pool.chips) do if ch.key == ... then return ch end end" % W, K("Hana"))
    bob.eval("local ch = ...; ch:GetScript('OnDragStart')(ch); ch:GetScript('OnDragStop')(ch)", chip)
    assert bob.eval("return %s.assign['zn.1.1']" % ST) == K("Hana")
    assert abs(bob.eval("local ch = ...; return ch:GetAlpha()", chip) - 0.5) < 0.01
    assert "1 of 10 slots filled" in strip_codes(bob.eval("return %s.slotsFs:GetText()" % W))
    bob.eval("%s.blocks.SlotUnderCursor = nil" % W)
    # Hana tanks Veras too, saved; she reads it: her jobs as chips (the row's target or the column, the page), a click
    # goes to the page and lights the row
    bob.eval("local s = %s; s.assign['tk.2.1'] = ...; %s:MarkDirty(true); %s:Save()" % (ST, B, B), K("Hana"))
    w.tick(2)
    assert bob.eval("return %s.canvas.frame:GetWidth()" % W) == 840
    hana.eval(B + ":OpenRaid(...)", occ, BOSS)
    assert hana.eval("return %s.canvas.frame:GetWidth()" % W) == 840
    chips = hana.eval_py("local out = {}; for _, ch in ipairs(%s.jobs.chips) do if ch:IsShown() then "
                         "out[#out + 1] = { t = ch.fs:GetText(), n = ch.note:IsShown() and ch.note:GetText(), r = ch.ref } "
                         "end end; return out" % W)
    assert sorted(x["t"] for x in chips) == ["Veras", "Zone 1"] and all(x["n"] == "P1" for x in chips), chips
    hana.eval("%s.page = 2; %s:Refresh()" % (ST, B))
    zone = hana.eval("for _, ch in ipairs(%s.jobs.chips) do if ch.ref == 'zn.1.1' then return ch end end" % W)
    hana.click(zone)
    assert hana.eval("return %s.page" % ST) == 1
    assert hana.eval("return %s.blocks.lit" % W) == "zn.1.1"
    # the strategy on its own: the raids coming up that use it, as links to their boards
    hana.eval(B + ":OpenStrategy(...)", sid)
    assert shown(hana, W + ".inRaids") and not shown(hana, W + ".jobs")
    link = hana.eval("return %s.inRaids.chips[1]" % W)
    assert hana.eval("local c = ...; return c.occ", link) == occ
    hana.click(link)
    assert hana.eval("return %s.occ" % ST) == occ
    w.assert_no_errors()


@case
def presence_circles_page_dots_and_the_keys_card():
    w, c = setup()
    bob, gina = c["Bob"], c["Gina"]
    sid = save_council(bob)
    w.tick(1)
    res = bob.eval_py("local ok, e = ns.Strategy:AddCollaborator(...); return { ok = ok }", sid, K("Rita"))
    assert res["ok"] is True
    w.tick(2)
    rita = c["Rita"]
    for x in (bob, rita):
        x.eval(B + ":OpenStrategy(...)", sid, "edit")
        w.tick(4)
    rita.eval("%s.page = 2; %s:Refresh()" % (ST, B))
    w.tick(3)
    bob.eval(B + ":Refresh()")
    assert shown(bob, W + ".live") and bob.eval("return %s.live.fs:IsShown()" % W) is True
    assert bob.eval("local n = 0; for _, f in ipairs(%s.live.faces) do if f:IsShown() then n = n + 1 end end; "
                    "return n" % W) == 1
    assert "live with Rita (P2)" in strip_codes(bob.eval("return %s:PresenceText()" % B))
    assert bob.eval("return %s.tabs[2].dots[1] ~= nil and %s.tabs[2].dots[1]:IsShown()" % (W, W)) is True
    # the keys card: under ?, its x or ? again closes it, and Esc closes only the card
    bob.eval(B + ":ShowKeys()")
    assert shown(bob, "_G.DisasterZoneStrategyKeys")
    bob.eval(B + ":ShowKeys()")
    assert not shown(bob, "_G.DisasterZoneStrategyKeys")
    bob.eval(B + ":ShowKeys()")
    bob.eval("local k = _G.DisasterZoneStrategyKeys; k:GetScript('OnKeyDown')(k, 'ESCAPE')")
    assert not shown(bob, "_G.DisasterZoneStrategyKeys") and shown(bob, W)
    w.assert_no_errors()


@case
def switching_a_raids_strategy_asks_when_names_drop():
    w, c = setup()
    bob = c["Bob"]
    a = save_council(bob, "A plan")
    b = bob.eval_py("local d = ns.Util.CopyTable(ns.Strategy:GetStrategy(...)); d.id = nil; d.n = 'Small'; "
                    "d.p[1].k = { d.p[1].k[1] }; local ok, r = ns.Strategy:SaveStrategy(d); return r", a)
    occ = create(bob, i="bt", t=now(bob) + DAY)
    w.tick(2)
    assert fill(bob, occ, BOSS, a, {"tk.1.1": K("Lee"), "zn.1.1": K("Sam")})["ok"] is True
    w.tick(1)
    bob.eval(B + ":OpenRaid(...)", occ, BOSS, "fill")
    assert shown(bob, W + ".stratDD")
    bob.eval(B + ":UseStrategy(...)", b)
    pop = bob.eval_py("return __MOCK.popup_log[#__MOCK.popup_log]")
    assert pop["which"] == "DISASTERZONE_STRAT_SWITCH" and "1 of your names has no slot there" in pop["text"], pop
    assert bob.eval("return %s.strat.id" % ST) == a
    bob.accept_popup("DISASTERZONE_STRAT_SWITCH")
    assert bob.eval("return %s.strat.id" % ST) == b
    assert bob.eval_py("return %s.assign" % ST) == {"tk.1.1": K("Lee")}
    # nothing to lose: no question
    bob.eval(B + ":UseStrategy(...)", a)
    assert bob.eval("return %s.strat.id" % ST) == a
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
