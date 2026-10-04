"""Strategy boards, together (Core/StrategyCollab.lua): who has a strategy open (the board's header, the list of
strategies), several editors on one live board (changes travel as the fields they touch, the later change of a field
wins everywhere, a drifted board is fetched again), undo of my own actions only, what the others have selected, one
editor's Save settling all of them, and the warning before saving over a version someone else saved meanwhile. A
collaborator the owner takes off no longer shows as editing, and can't take up the draft he had (1.3).

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_collab.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, K, save_council, COUNCIL  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

W = "_G.DisasterZoneStrategyBoard"
B = "ns.StrategyBoard"
C = "ns.StrategyCollab"
ST = B + ":GetState()"
CONFIRM = "DISASTERZONE_PLAN_CONFIRM"


def names():
    return (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"),
            ("Sam", 3, "ROGUE"), ("Hana", 3, "HUNTER"))


def setup(*editors):
    """Rita owns a strategy and shares it with Sam; the named members open it for editing, one after the other."""
    w, c = world(names())
    rita = c["Rita"]
    sid = save_council(rita)
    w.tick(1)
    res = rita.eval_py("local ok, e = ns.Strategy:AddCollaborator(...); return { ok = ok, e = e }", sid, K("Sam"))
    assert res["ok"] is True, res
    w.tick(2)
    for n in editors:
        c[n].eval(B + ":OpenStrategy(...)", sid, "edit")
        w.tick(4)
    return w, c, sid


def elems(cl, page=None):
    return cl.eval_py("local s = %s; return s.strat.p[... or s.page].e" % ST, page)


def place(cl, x, y=300):
    cl.eval("%s.canvas:Place({ t = 'i', x = ..., y = select(2, ...), i = 'rt1', z = 32 })" % W, x, y)


def change(cl, code, *args):
    """Runs code on the board's strategy (s) and reports it as one finished action."""
    cl.eval("local s = %s.strat; (loadstring(...))(s, select(2, ...)); %s:MarkDirty(true)" % (ST, B),
            "local s = ...; " + code, *args)


def content(cl):
    return cl.eval("return %s:ContentHash(%s.strat)" % (C, ST))


def state(cl):
    return cl.eval_py("local s = %s; return { mode = s.mode, dirty = s.dirty, live = %s:IsLive(), peers = %s:GetPeers() }"
                      % (ST, C, C))


def sub(cl):
    return strip_codes(cl.eval("return %s.sub:GetText()" % W) or "")


def xs(cl):
    return sorted(e["x"] for e in elems(cl))


# ------------------------------------------------------------------------------------------------------------------
@case
def diff_and_apply_carry_any_change():
    w, c = world(names())
    bob = c["Bob"]
    res = bob.eval_py(r"""
        local a = (loadstring(...))()
        for _, p in ipairs(a.p) do for i, e in ipairs(p.e) do e._u = "s" .. i end end
        local b = ns.Util.CopyTable(a)
        b.n = "Other"
        b.am = false
        local p = b.p[1]
        p.e[1].x, p.e[1].l = 310, "Moved"                       -- fields of a drawing
        table.remove(p.e, 3)                                     -- one gone
        p.e[#p.e + 1] = { t = "i", x = 10, y = 10, i = "rt2", _u = "new1" }
        p.e[1], p.e[2] = p.e[2], p.e[1]                          -- another order
        p.k[1].d[1][2].l = "Malande"                             -- a cell
        p.k[1].n = "Main tanks"
        p.k[2].r = 3
        p.k[2].d[3] = { [3] = { s = "tk.1.1" } }                 -- a row more
        table.remove(p.k, 4)                                     -- a table gone
        p.no = "Notes now"
        b.p[2].n = "Phase 2"
        b.p[3] = { id = "p3", n = "P3", m = 0, e = { { t = "i", x = 5, y = 5, i = "rt3", _u = "s1" } }, k = {} }
        b.p[2], b.p[3] = b.p[3], b.p[2]
        local C = ns.StrategyCollab
        local ops = C._Diff(a, b)
        local got = ns.Util.CopyTable(a)
        local bad = 0
        for _, op in ipairs(ops) do
            if not C._ValidOp(op) then bad = bad + 1 end
            C._Apply(got, op)
        end
        local order = {}
        for _, e in ipairs(got.p[1].e) do order[#order + 1] = e._u end
        return { n = #ops, bad = bad, same = C:ContentHash(got) == C:ContentHash(b), differs = C:ContentHash(a) ~= C:ContentHash(b),
            order = order, pages = { got.p[1].id, got.p[2].id, got.p[3].id }, none = #C._Diff(b, got) }
    """, COUNCIL)
    assert res["bad"] == 0 and res["same"] is True and res["differs"] is True and res["none"] == 0, res
    assert res["order"] == ["s2", "s1", "s4", "s5", "s6", "new1"], res
    assert res["pages"] == ["p1", "p3", "p2"], res
    # what the wire may not carry
    bad = bob.eval_py(r"""
        local V = ns.StrategyCollab._ValidOp
        local out = {}
        for i, op in ipairs({
            { p = { "id" }, v = "x" }, { p = { "co" }, v = { "A-B" } }, { p = { "p" }, v = {} },
            { p = { "p", "p1", "e", "s1" }, v = { _u = "other", t = "i" } }, { p = { "p", "p1", "_w" }, v = 1 },
            { p = { "p", "p1", "e" }, o = { 1, 2 } }, { p = { "n" }, v = { 1 } }, { p = {}, v = 1 },
            { p = { "p", "p1", "x", "y", "z", "a", "b", "c", "d" }, v = 1 },
        }) do out[i] = V(op) end
        return out
    """)
    assert not any(bad), bad
    w.assert_no_errors()


@case
def presence_shows_who_has_a_strategy_open():
    w, c, sid = setup()
    rita, sam, lee = c["Rita"], c["Sam"], c["Lee"]
    rita.eval(B + ":OpenStrategy(...)", sid, "edit")
    w.tick(3)
    sam.eval(B + ":OpenStrategy(...)", sid)
    w.tick(3)
    assert rita.eval_py("return %s:GetPresence(...)" % C, sid) == [{"key": K("Sam"), "m": "v", "pg": "p1"}]
    seen = sam.eval_py("return %s:GetPresence(...)" % C, sid)
    assert [(e["key"], e["m"]) for e in seen] == [(K("Rita"), "e")], seen
    assert "Rita is editing" in sub(sam), sub(sam)
    assert "Sam is looking" in sub(rita), sub(rita)
    # someone with the list open sees it on the strategy's row
    assert lee.eval_py("return %s:GetEditors(...)" % C, sid) == [K("Rita")]
    lee.slash("/dz raids")
    w.tick(0.5)
    lee.eval("ns.RaidsUI:SetView('strategies')")
    w.tick(1)
    assert lee.find_text("Rita editing"), "the list names the editor"
    # a member who logs in later asks when the list opens
    hana = c["Hana"]
    hana.relog()
    w.tick(1)
    hana.slash("/dz raids")
    w.tick(0.5)
    hana.eval("ns.RaidsUI:SetView('strategies')")
    w.tick(4)
    assert hana.eval_py("return %s:GetEditors(...)" % C, sid) == [K("Rita")]
    # closing the board says so; a board that just disappears is forgotten after a while
    rita.eval(B + ":Close()")
    w.tick(1)
    assert sam.eval_py("return %s:GetPresence(...)" % C, sid) == []
    assert "editing" not in sub(sam), sub(sam)
    sam.eval("ns.Comm.Send = function() return true end")       # Sam's client goes quiet (a disconnect)
    w.tick(50)
    assert lee.eval_py("return %s:GetPresence(...)" % C, sid) == []
    w.assert_no_errors()


@case
def two_editors_share_one_board():
    w, c, sid = setup("Rita", "Sam")
    rita, sam = c["Rita"], c["Sam"]
    assert state(rita) == {"mode": "edit", "dirty": False, "live": True, "peers": [K("Sam")]}, state(rita)
    assert state(sam) == {"mode": "edit", "dirty": False, "live": True, "peers": [K("Rita")]}, state(sam)
    assert "live with Sam" in sub(rita) and "live with Rita" in sub(sam), (sub(rita), sub(sam))
    n0 = len(elems(rita))
    # a new drawing, a moved one, a renamed table, a cell, a page: each lands on the other board
    place(rita, 640)
    w.tick(2)
    assert len(elems(sam)) == n0 + 1 and 640 in xs(sam), xs(sam)
    assert state(sam)["dirty"] is True
    change(sam, "s.p[1].e[1].x = 333; s.p[1].k[1].n = 'Main tanks'; s.p[1].k[1].d[1][2].l = 'Malande'")
    w.tick(2)
    got = rita.eval_py("local s = %s.strat; return { x = s.p[1].e[1].x, n = s.p[1].k[1].n, l = s.p[1].k[1].d[1][2].l }" % ST)
    assert got == {"x": 333, "n": "Main tanks", "l": "Malande"}, got
    rita.eval(B + ":AddPage()")
    w.tick(2)
    assert sam.eval("return #%s.strat.p" % ST) == 3
    assert "live with Rita (P3)" in sub(sam), sub(sam)
    rita.eval("%s.page = 1; %s:Refresh()" % (ST, B))
    # at the same moment: different things both land, the same field ends up the same on both boards
    change(rita, "s.p[1].e[2].l = 'Stack here'")
    change(sam, "s.p[1].e[3].x = 120")
    change(rita, "s.p[1].e[4].x = 701")
    change(sam, "s.p[1].e[4].x = 702")
    w.tick(3)
    for cl in (rita, sam):
        got = cl.eval_py("local e = %s.strat.p[1].e; return { l = e[2].l, x3 = e[3].x }" % ST)
        assert got == {"l": "Stack here", "x3": 120}, got
    assert rita.eval("return %s.strat.p[1].e[4].x" % ST) == sam.eval("return %s.strat.p[1].e[4].x" % ST)
    # deleting what the other one is changing: it stays gone
    change(rita, "table.remove(s.p[1].e, 1)")
    change(sam, "s.p[1].e[1].y = 99")
    w.tick(3)
    assert len(elems(rita)) == n0 and len(elems(sam)) == n0
    assert content(rita) == content(sam)
    # a third editor (the guild council may edit any strategy) gets the board as it is now
    bob = c["Bob"]
    bob.eval(B + ":OpenStrategy(...)", sid, "edit")
    w.tick(5)
    assert state(bob)["live"] is True and state(bob)["peers"] == [K("Rita"), K("Sam")], state(bob)
    assert content(bob) == content(rita)
    place(bob, 77)
    w.tick(2)
    assert 77 in xs(rita) and 77 in xs(sam)
    # one leaves: the others go on
    sam.eval(B + ":Close()")
    w.tick(2)
    assert state(rita)["peers"] == [K("Bob")]
    place(rita, 88)
    w.tick(2)
    assert 88 in xs(bob)
    w.assert_no_errors()


@case
def undo_takes_back_my_own_actions_only():
    w, c, sid = setup("Rita", "Sam")
    rita, sam = c["Rita"], c["Sam"]
    n0 = len(elems(rita))
    assert rita.eval("return %s:CanUndo()" % B) is False
    place(rita, 610)
    w.tick(1)
    place(sam, 620)
    w.tick(1)
    change(rita, "s.p[1].e[1].x = 301")
    w.tick(2)
    assert len(elems(rita)) == n0 + 2 and len(elems(sam)) == n0 + 2
    # Rita's undo: her move, then her drawing; Sam's stays
    assert rita.eval("return %s:Undo()" % B) is True
    w.tick(2)
    assert sam.eval("return %s.strat.p[1].e[1].x" % ST) == 300
    assert rita.eval("return %s:Undo()" % B) is True
    w.tick(2)
    for cl in (rita, sam):
        assert 610 not in xs(cl) and 620 in xs(cl), xs(cl)
    assert rita.eval("return %s:CanUndo()" % B) is False
    # and redo brings it back for both
    assert rita.eval("return %s:Redo()" % B) is True
    w.tick(2)
    for cl in (rita, sam):
        assert 610 in xs(cl) and 620 in xs(cl), xs(cl)
    assert content(rita) == content(sam)
    w.assert_no_errors()


@case
def selections_show_on_the_other_board():
    w, c, sid = setup("Rita", "Sam")
    rita, sam = c["Rita"], c["Sam"]
    rita.eval("local cv = %s.canvas; cv:Select(%s.strat.p[1].e[2])" % (W, ST))
    w.tick(2)
    sel = sam.eval_py("return %s:RemoteSelections('p1')" % C)
    assert len(sel) == 1 and sel[0]["key"] == K("Rita") and sel[0]["sel"] == {"s2": True}, sel
    assert sam.eval_py("return %s:RemoteSelections('p2')" % C) == []
    # the box on Sam's map wears her name
    tags = sam.eval_py(r"""
        local out = {}
        for _, o in ipairs(%s.canvas.pools.box) do
            if o.holder:IsShown() and o.tag:IsShown() then out[#out + 1] = o.tag:GetText() end
        end
        return out
    """ % W)
    assert tags == ["Rita"], tags
    rita.eval("%s.canvas:ClearSelection()" % W)
    w.tick(2)
    assert sam.eval_py("return %s:RemoteSelections('p1')" % C) == []
    w.assert_no_errors()


@case
def one_save_settles_every_editor():
    w, c, sid = setup("Rita", "Sam")
    rita, sam = c["Rita"], c["Sam"]
    place(rita, 640)
    w.tick(2)
    assert state(sam)["dirty"] is True
    sam.click(sam.eval("return %s.saveBtn" % W))
    w.tick(3)
    assert CONFIRM not in sam.popups()
    assert state(sam)["mode"] == "view"
    # Rita keeps editing; nothing of hers is unsaved, and her draft is gone
    st = state(rita)
    assert st["mode"] == "edit" and st["dirty"] is False and st["peers"] == [], st
    assert rita.eval("return %s:HasDraft()" % B) is False
    saved = rita.eval_py("return ns.Strategy:GetStrategy(...)", sid)
    assert saved["by"] == K("Sam") and any(e["x"] == 640 for e in saved["p"][0]["e"]), saved["by"]
    assert not any("_u" in e for e in saved["p"][0]["e"]), "session ids are not saved"
    # her next save needs no warning: her board builds on what Sam saved
    place(rita, 650)
    rita.click(rita.eval("return %s.saveBtn" % W))
    w.tick(2)
    assert CONFIRM not in rita.popups()
    assert rita.eval_py("return ns.Strategy:GetStrategy(...)", sid)["by"] == K("Rita")
    w.assert_no_errors()


@case
def saving_over_someone_elses_version_asks_first():
    w, c, sid = setup()
    rita, sam = c["Rita"], c["Sam"]
    # Rita starts a change and puts the board away; Sam changes and saves the strategy meanwhile
    rita.eval(B + ":OpenStrategy(...)", sid, "edit")
    w.tick(3)
    place(rita, 640)
    rita.eval(B + ":Close()")
    w.tick(2)
    sam.eval(B + ":OpenStrategy(...)", sid, "edit")
    w.tick(3)
    assert state(sam)["live"] is False
    place(sam, 150)
    sam.click(sam.eval("return %s.saveBtn" % W))
    w.tick(2)
    sam.eval(B + ":Close()")
    w.tick(2)
    # her draft says so, and Save asks before it replaces Sam's version
    assert rita.eval("return %s:OpenDraft()" % B) is True
    w.tick(3)
    assert "Sam saved a newer version" in sub(rita), sub(rita)
    rita.click(rita.eval("return %s.saveBtn" % W))
    assert CONFIRM in rita.popups()
    assert rita.eval_py("return ns.Strategy:GetStrategy(...)", sid)["by"] == K("Sam")
    assert state(rita)["mode"] == "edit"
    rita.accept_popup(CONFIRM)
    w.tick(2)
    saved = sam.eval_py("return ns.Strategy:GetStrategy(...)", sid)
    assert saved["by"] == K("Rita") and any(e["x"] == 640 for e in saved["p"][0]["e"]), saved["by"]
    assert not any(e["x"] == 150 for e in saved["p"][0]["e"])
    # a change of the collaborators alone is no other version
    rita.eval(B + ":OpenStrategy(...)", sid, "edit")
    w.tick(3)
    place(rita, 660)
    rita.eval("ns.Strategy:AddCollaborator(...)", sid, K("Hana"))
    w.tick(1)
    rita.click(rita.eval("return %s.saveBtn" % W))
    assert CONFIRM not in rita.popups()
    w.assert_no_errors()


@case
def joining_with_unsaved_work_of_my_own_asks_first():
    w, c, sid = setup()
    rita, sam = c["Rita"], c["Sam"]
    rita.eval(B + ":OpenStrategy(...)", sid, "edit")
    w.tick(3)
    place(rita, 640)
    rita.eval(B + ":Close()")
    w.tick(2)
    sam.eval(B + ":OpenStrategy(...)", sid, "edit")
    w.tick(3)
    place(sam, 150)
    w.tick(1)
    # Rita comes back to her draft while Sam is editing: her board stays hers until she says so
    assert rita.eval("return %s:OpenDraft()" % B) is True
    w.tick(4)
    assert CONFIRM in rita.popups()
    assert state(rita)["live"] is False and 640 in xs(rita)
    assert "Sam is editing" in sub(rita), sub(rita)
    place(rita, 641)
    w.tick(2)
    assert 641 not in xs(sam)
    rita.accept_popup(CONFIRM)
    w.tick(4)
    assert state(rita)["live"] is True and state(sam)["peers"] == [K("Rita")], (state(rita), state(sam))
    assert 640 not in xs(rita) and 150 in xs(rita), xs(rita)
    assert content(rita) == content(sam)
    # putting the shared board away and coming back needs no question
    rita.eval(B + ":Close()")
    w.tick(2)
    place(sam, 160)
    w.tick(1)
    assert rita.eval("return %s:OpenDraft()" % B) is True
    w.tick(5)
    assert CONFIRM not in rita.popups()
    assert state(rita)["live"] is True and 160 in xs(rita), (state(rita), xs(rita))
    w.assert_no_errors()


@case
def a_lost_change_heals():
    w, c, sid = setup("Rita", "Sam")
    rita, sam = c["Rita"], c["Sam"]
    # one of Rita's changes never arrives
    rita.eval("T_send = ns.Comm.Send; ns.Comm.Send = function() return true end")
    place(rita, 640)
    w.tick(1)
    rita.eval("ns.Comm.Send = T_send")
    assert 640 not in xs(sam)
    # both boards idle and different: the later name (Sam) fetches the other board
    w.tick(45)
    assert 640 in xs(sam), xs(sam)
    assert content(rita) == content(sam)
    assert state(sam)["live"] is True and state(rita)["peers"] == [K("Sam")]
    # and they still edit together
    place(sam, 150)
    w.tick(2)
    assert 150 in xs(rita)
    w.assert_no_errors()


@case
def only_the_strategys_editors_take_part():
    w, c, sid = setup("Rita", "Sam")
    rita, sam, lee = c["Rita"], c["Sam"], c["Lee"]
    before = content(rita)
    k = rita.eval("return %s:GetSession()" % C)
    assert k and k == sam.eval("return %s:GetSession()" % C)
    # Lee may not edit this strategy: his changes, his older "session" and his request for the board go nowhere
    lee.eval(r"""
        local id, to, k = ...
        local C = ns.Comm
        C:Send({ t = "SBP", id = id, m = "e", k = "0000000001zzzz" }, "GUILD", nil, "live")
        C:Send({ t = "SBP", id = id, m = "e", k = k }, "GUILD", nil, "live")
        C:Send({ t = "SBO", id = id, k = k, c = 99999, o = { { p = { "n" }, v = "Hacked" } } }, "WHISPER", to, "live")
        C:Send({ t = "SBJ", id = id, k = k }, "WHISPER", to, "live")
    """, sid, K("Rita"), k)
    w.tick(4)
    assert state(rita)["peers"] == [K("Sam")] and state(sam)["peers"] == [K("Rita")]
    assert CONFIRM not in rita.popups() and CONFIRM not in sam.popups()
    assert content(rita) == before and content(sam) == before
    # (and nobody sees Lee editing: he may not)
    assert [(e["key"], e["m"]) for e in rita.eval_py("return %s:GetPresence(...)" % C, sid)] == [(K("Sam"), "e"),
                                                                                                (K("Lee"), "v")]
    w.assert_no_errors()


@case
def a_collaborator_taken_off_stops_editing():
    """Rita takes Sam off while his board has unsaved changes: nobody sees him editing any more (whatever his board
    says), and his draft can't be taken up again: it is dropped with a message and the strategy opens read-only."""
    w, c, sid = setup("Rita", "Sam")
    rita, sam, lee = c["Rita"], c["Sam"], c["Lee"]
    other = save_council(lee, "Other")
    lee.eval(B + ":OpenStrategy(...)", sid)
    w.tick(3)
    seen = lee.eval_py("return %s:GetPresence(...)" % C, sid)
    assert [(e["key"], e["m"]) for e in seen] == [(K("Rita"), "e"), (K("Sam"), "e")], seen
    place(sam, 640)
    w.tick(2)
    did = sam.eval("return %s.did" % ST)
    assert did and sam.eval("return %s.dirty" % ST) is True
    assert rita.eval_py("local ok, e = ns.Strategy:RemoveCollaborator(...); return { ok = ok, e = e }",
                        sid, K("Sam"))["ok"] is True
    w.tick(2)
    for x in (rita, lee):
        seen = x.eval_py("return %s:GetPresence(...)" % C, sid)
        assert (K("Sam"), "v") in [(e["key"], e["m"]) for e in seen], (x.name, seen)
        assert x.eval_py("return %s:GetEditors(...)" % C, sid) in ([K("Rita")], []), x.name
    assert "Sam is looking" in sub(lee) and "Sam is editing" not in sub(lee), sub(lee)
    # Sam moves on to another strategy; his draft stays behind, and can't be taken up again
    sam.eval(B + ":OpenStrategy(...)", other)
    w.tick(1)
    assert [d["did"] for d in sam.eval_py("return %s:GetDrafts()" % B) or []] == [did]
    n0 = len(sam.chat_frame)
    assert sam.eval("return %s:OpenDraft(...)" % B, did) is False
    assert any("can no longer change" in str(x) for x in sam.chat_frame[n0:]), sam.chat_frame[n0:]
    assert (sam.eval_py("return %s:GetDrafts()" % B) or []) == []
    st = sam.eval_py("local s = %s; return { mode = s.mode, dirty = s.dirty, id = s.strat.id }" % ST)
    assert st == {"mode": "view", "dirty": False, "id": sid}, st
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
