"""ADDENDUM K: the strategy board's unsaved work is a draft: it survives a /reload, a logout and a disconnect (it sits
in the saved variables, undo history included), several can wait at once, and Raids > Strategies lists them under
their boss. Also the longer texts (text cells, texts on the map, page notes).

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_draft.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, K, DAY, now, create, save_council, strategies  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402
from rp_common import gm_pick, set_raid_leaders  # noqa: E402

BOSS = "BlackTemple:Council"
W = "_G.DisasterZoneStrategyBoard"
B = "ns.StrategyBoard"
ST = B + ":GetState()"
LONG = "When Attumen spawns threat is reset. The tank needs to reestablish aggro"


def setup(mode="edit"):
    w, c = world()
    bob = c["Bob"]
    bob.eval(HELPERS)
    sid = save_council(bob)
    w.tick(1)
    bob.eval(B + ":OpenStrategy(...)", sid, mode)
    w.tick(0.2)
    return w, c, bob, sid


def key(cl, k, shift=False, ctrl=False):
    cl.set_modifiers(shift, ctrl, False)
    cl.eval("local w = %s; w:GetScript('OnKeyDown')(w, ...)" % W, k)
    cl.set_modifiers(False, False, False)


def elems(cl):
    return cl.eval_py("local s = %s; return s.strat.p[s.page].e" % ST)


HELPERS = "function T_last() local s = ns.StrategyBoard:GetState(); local e = s.strat.p[s.page].e; return e[#e] end"


def ndrafts(cl):
    return cl.eval("local n = 0; for _ in pairs(ns.db.strategyDraft[ns.Util.PlayerKey()] or {}) do n = n + 1 end; "
                   "return n")


def drafts(cl, boss=None):
    return list(cl.eval_py("return %s:GetDrafts(...)" % B, boss) or [])


def place(cl, x):
    cl.eval("%s.canvas:Place({ t = 'i', x = ..., y = 300, i = 'rt1', z = 32 })" % W, x)


# ------------------------------------------------------------------------------------------------------------------
@case
def edit_draft_survives_a_reload_with_its_undo_history():
    w, c, bob, sid = setup()
    n0 = len(elems(bob))
    place(bob, 600)
    place(bob, 650)
    place(bob, 700)
    key(bob, "Z", ctrl=True)                    # one step back: two placed, one to redo
    assert len(elems(bob)) == n0 + 2
    bob.relog()                                 # /reload (a disconnect saves the same way)
    w.tick(1)
    assert bob.eval("return %s:HasDraft()" % B) is True
    assert bob.eval("return %s:IsShown()" % B) is False
    w.tick(8)
    assert any("1 unsaved strategy draft:" in p and "/dz strat draft" in p for p in bob.chat_frame), bob.chat_frame[-5:]
    assert bob.eval("return %s:OpenDraft()" % B) is True
    w.tick(0.2)
    st = bob.eval_py("local s = %s; return { mode = s.mode, dirty = s.dirty, id = s.strat.id }" % ST)
    assert st == {"mode": "edit", "dirty": True, "id": sid}, st
    assert len(elems(bob)) == n0 + 2
    # the history came along: redo, then undo all the way back
    key(bob, "Y", ctrl=True)
    assert len(elems(bob)) == n0 + 3
    for _ in range(3):
        key(bob, "Z", ctrl=True)
    assert len(elems(bob)) == n0
    assert bob.eval("return %s:CanUndo()" % B) is False
    key(bob, "Y", ctrl=True)
    # saving publishes it and takes the draft out of the saved variables
    bob.click(bob.eval("return %s.saveBtn" % W))
    assert ndrafts(bob) == 0
    assert len(strategies(bob, BOSS)[0]["p"][0]["e"]) == n0 + 1
    bob.relog()
    w.tick(1)
    assert bob.eval("return %s:HasDraft()" % B) is False
    w.assert_no_errors()


@case
def a_new_unsaved_strategy_survives_a_logout():
    w, c = world()
    bob = c["Bob"]
    bob.eval(B + ":NewStrategy(...)", BOSS, "Fresh")
    w.tick(0.2)
    place(bob, 500)
    n = len(elems(bob))
    bob.relog(reload=False)
    w.tick(1)
    assert bob.eval("return %s:HasDraft()" % B) is True
    bob.slash("/dz strat draft")
    w.tick(0.2)
    assert bob.eval("return %s:IsShown()" % B) is True
    st = bob.eval_py("local s = %s; return { mode = s.mode, n = s.strat.n, id = s.strat.id }" % ST)
    assert st == {"mode": "edit", "n": "Fresh"}, st
    assert len(elems(bob)) == n
    key(bob, "Z", ctrl=True)
    assert len(elems(bob)) == n - 1
    w.assert_no_errors()


@case
def cancel_and_dropping_the_changes_forget_the_draft():
    w, c, bob, sid = setup()
    place(bob, 600)
    assert ndrafts(bob) == 1
    # Discard asks first; keeping on editing keeps the draft
    bob.click(bob.eval("return %s.cancelBtn" % W))
    assert ndrafts(bob) == 1
    bob.cancel_popup("DISASTERZONE_CONFIRM_STRAT_DISCARD")
    assert ndrafts(bob) == 1
    bob.click(bob.eval("return %s.cancelBtn" % W))
    bob.accept_popup("DISASTERZONE_CONFIRM_STRAT_DISCARD")
    assert ndrafts(bob) == 0
    bob.relog()
    w.tick(1)
    assert bob.eval("return %s:HasDraft()" % B) is False
    # nothing changed: nothing kept
    bob.eval(B + ":OpenStrategy(...)", sid, "edit")
    assert ndrafts(bob) == 0
    w.assert_no_errors()


@case
def assigning_survives_a_reload():
    w, c, bob, sid = setup("view")
    occ = create(bob, i="bt", t=now(bob) + DAY)
    w.tick(1)
    bob.eval(B + ":OpenRaid(...)", occ, BOSS, "fill")
    w.tick(0.2)
    bob.eval(B + ":Assign('tk.1.1', 'Lee-Thunderstrike')")
    bob.eval(B + ":Assign('tk.2.1', 'Bob-Thunderstrike')")
    bob.relog()
    w.tick(1)
    assert bob.eval("return %s:OpenDraft()" % B) is True
    w.tick(0.2)
    st = bob.eval_py("local s = %s; return { mode = s.mode, occ = s.occ, a = s.assign }" % ST)
    assert st["mode"] == "fill" and st["occ"] == occ, st
    assert st["a"] == {"tk.1.1": "Lee-Thunderstrike", "tk.2.1": "Bob-Thunderstrike"}, st
    key(bob, "Z", ctrl=True)
    assert bob.eval_py("return %s.assign" % ST) == {"tk.1.1": "Lee-Thunderstrike"}
    w.assert_no_errors()


@case
def a_damaged_draft_is_dropped_quietly():
    w, c, bob, sid = setup()
    place(bob, 600)
    bob.eval("local d = ns.db.strategyDraft[ns.Util.PlayerKey()]; ns.db.strategyDraft[ns.Util.PlayerKey()] = "
             "{ mode = 'edit', strat = { n = 'x', p = 'broken' }, assign = {}, dirty = true }")
    bob.relog()
    w.tick(1)
    assert bob.eval("return %s:HasDraft()" % B) is False
    assert ndrafts(bob) == 0
    # a broken history: the draft comes back, the history starts over
    bob.eval(B + ":OpenStrategy(...)", sid, "edit")
    place(bob, 600)
    bob.eval("%s.hist[1] = 'junk'" % ST)
    bob.relog()
    w.tick(1)
    assert bob.eval("return %s:HasDraft()" % B) is True
    assert bob.eval("return %s:OpenDraft()" % B) is True
    assert bob.eval("return %s:CanUndo()" % B) is False
    w.assert_no_errors()


@case
def several_drafts_wait_in_the_list_of_their_boss():
    w, c = world()
    bob, lee = c["Bob"], c["Lee"]
    bob.eval(HELPERS)
    sid = save_council(bob)
    w.tick(1)
    # two new strategies for the boss, one after the other: the first stays behind as a draft, nothing is asked
    bob.eval(B + ":NewStrategy(...)", BOSS, "Plan A")
    place(bob, 500)
    w.tick(1)
    bob.eval(B + ":NewStrategy(...)", BOSS, "Plan B")
    place(bob, 510)
    place(bob, 520)
    w.tick(1)
    # and changes to the saved one
    bob.eval(B + ":OpenStrategy(...)", sid, "edit")
    place(bob, 530)
    w.tick(1)
    ds = drafts(bob, BOSS)
    assert sorted(d["n"] for d in ds) == ["25 farm", "Plan A", "Plan B"], ds
    assert [d.get("open", False) for d in ds].count(True) == 1 and ds[0]["n"] == "25 farm" and ds[0]["id"] == sid, ds
    assert drafts(bob, "Karazhan:Attumen") == []
    assert len(strategies(bob, BOSS)) == 1 and len(strategies(lee, BOSS)) == 1     # drafts are mine alone
    # a disconnect: all three are there, in the list of the boss, above the saved strategy
    bob.relog(reload=False)
    w.tick(8)
    assert any("3 unsaved strategy drafts" in p for p in bob.chat_frame), bob.chat_frame[-5:]
    assert len(drafts(bob, BOSS)) == 3
    bob.slash("/dz raids")
    w.tick(0.5)
    bob.eval("ns.RaidsUI:SetView('strategies')")
    w.tick(0.5)
    bob.eval("ns.StrategiesUI:SelectBoss(...)", BOSS)
    w.tick(0.5)
    rows = bob.eval_py(r"""
        local out = {}
        local function walk(f)
            for _, ch in ipairs({ f:GetChildren() }) do
                if ch.l1 and ch.l2 and ch.edit and ch.more and ch:IsVisible() then
                    -- (a card: Edit / Continue on it, the rest in its More menu, a draft's "Draft" tag)
                    out[#out + 1] = { l1 = ch.l1:GetText(), l2 = ch.l2:GetText(), edit = ch.edit.tipTitle,
                        more = ch.more.tipText,
                        draft = ch.pill:IsShown() and (ch.pill.fs:GetText() or ""):find("Draft") ~= nil }
                end
                walk(ch)
            end
        end
        walk(UIParent)
        return out
    """)
    rows = sorted(rows, key=lambda r: (not r["draft"], strip_codes(r["l1"])))
    names = [strip_codes(r["l1"]) + ("  Draft" if r["draft"] else "") for r in rows]
    assert names == ["25 farm  Draft", "Plan A  Draft", "Plan B  Draft", "25 farm"], names
    assert rows[0]["edit"] == "Continue" and rows[0]["more"] == "Discard", rows[0]
    assert "unsaved changes" in rows[0]["l2"] and "not saved yet" in rows[1]["l2"], rows[:2]
    assert rows[3]["edit"] == "Edit" and "Delete" in rows[3]["more"] and rows[3]["draft"] is False, rows[3]
    # the boss in the list on the left says so too (its count, and the drafts as an orange "+3")
    # (1.4: the orange is the WARN token)
    assert bob.find_text("1 " + bob.eval("return ns.Style:Wrap('WARN', '+3')")), "the boss row shows its drafts"
    # Continue on a draft's row opens it
    cont = bob.eval(r"""
        local function walk(f)
            for _, ch in ipairs({ f:GetChildren() }) do
                if ch.l1 and ch.edit and ch:IsVisible() and ch.l1:GetText():find("Plan B", 1, true) then return ch.edit end
                local r = walk(ch)
                if r then return r end
            end
        end
        return walk(UIParent)
    """)
    bob.click(cont)
    assert bob.eval("return %s:IsShown() and %s.strat.n" % (B, ST)) == "Plan B"
    bob.eval("%s:Close()" % B)
    # continue Plan A, undo works (it kept its history), save: a real strategy, the draft is gone
    plan_a = [d for d in drafts(bob, BOSS) if d["n"] == "Plan A"][0]
    assert bob.eval("return %s:OpenDraft(...)" % B, plan_a["did"]) is True
    n = len(elems(bob))
    key(bob, "Z", ctrl=True)
    assert len(elems(bob)) == n - 1
    key(bob, "Y", ctrl=True)
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(3)
    assert sorted(x["n"] for x in strategies(lee, BOSS)) == ["25 farm", "Plan A"]
    assert sorted(d["n"] for d in drafts(bob, BOSS)) == ["25 farm", "Plan B"]
    # Edit on the saved strategy goes on with its draft; Open shows the saved one and leaves the draft alone
    bob.eval(B + ":OpenStrategy(...)", sid, "edit")
    st = bob.eval_py("local s = %s; return { dirty = s.dirty, mode = s.mode, n = #s.strat.p[1].e }" % ST)
    saved_n = len(strategies(bob, BOSS)[0]["p"][0]["e"]) if strategies(bob, BOSS)[0]["n"] == "25 farm" \
        else len(strategies(bob, BOSS)[1]["p"][0]["e"])
    assert st["dirty"] is True and st["mode"] == "edit" and st["n"] == saved_n + 1, st
    plan_b = [d for d in drafts(bob, BOSS) if d["n"] == "Plan B"][0]
    bob.eval(B + ":OpenDraft(...)", plan_b["did"])
    assert bob.eval("return %s.strat.n" % ST) == "Plan B" and len(drafts(bob, BOSS)) == 2
    # discard: the one on the board (the window closes: it was never saved) and a parked one
    bob.eval(B + ":DiscardDraft(...)", plan_b["did"])
    assert bob.eval("return %s:IsShown()" % B) is False
    assert [d["n"] for d in drafts(bob, BOSS)] == ["25 farm"]
    bob.eval(B + ":DiscardDraft(...)", drafts(bob, BOSS)[0]["did"])
    assert drafts(bob, BOSS) == [] and ndrafts(bob) == 0
    assert bob.eval("return %s:OpenDraft()" % B) is False
    w.assert_no_errors()


@case
def only_the_latest_parked_drafts_keep_their_history_and_there_is_a_cap():
    w, c = world()
    bob = c["Bob"]
    for i in range(12):
        bob.eval(B + ":NewStrategy(...)", BOSS, "Plan %d" % i)
        place(bob, 400 + i)
        w.tick(1)
    assert ndrafts(bob) == 12
    bob.eval(B + ":NewStrategy(...)", BOSS, "One too many")
    assert ndrafts(bob) == 12 and any("12 unsaved drafts" in p for p in bob.chat_frame)
    with_hist = bob.eval("local n = 0; for _, d in pairs(ns.db.strategyDraft[ns.Util.PlayerKey()]) do "
                         "if d.hist then n = n + 1 end end; return n")
    assert with_hist == 3, with_hist
    # an old one still opens, its history starts over
    old = [d for d in drafts(bob, BOSS) if d["n"] == "Plan 0"][0]
    assert bob.eval("return %s:OpenDraft(...)" % B, old["did"]) is True
    assert bob.eval("return %s:CanUndo()" % B) is False and bob.eval("return %s.strat.n" % ST) == "Plan 0"
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
@case
def long_texts_fit_and_reach_the_guild():
    w, c, bob, sid = setup()
    assert len(LONG) > 64
    # a text cell (the Notes block): a box of several lines takes it, the cell wraps
    P = "ns.StrategyBoard:GetPrompt()"
    bob.eval("local p = %s.blocks; local page = p.opts.page(); p:CellMenu(nil, page.k[4], 1, 1)" % W)
    multi = bob.eval("return %s.multi" % P)
    assert bob.eval("return %s.multi:IsVisible() and not %s.editBox:IsShown()" % (P, P)) is True
    assert bob.eval("return %s.multi:GetMaxLetters()" % P) == 160
    # the keyboard is in the box right away, above the board; a click anywhere in the box goes to it too
    assert bob.eval("return %s.multi:HasFocus()" % P) is True
    assert bob.eval("return %s:GetFrameStrata()" % P) == "FULLSCREEN_DIALOG"
    bob.eval("%s.multi:ClearFocus(); %s.multiScroll:GetScript('OnMouseDown')(%s.multiScroll, 'LeftButton')" % (P, P, P))
    assert bob.eval("return %s.multi:HasFocus()" % P) is True
    bob.eval("%s.multi:SetText('')" % P)
    bob.type_text(multi, LONG)
    bob.click(bob.eval("return %s.button1" % P))
    assert bob.eval("return %s.strat.p[1].k[4].d[1][1]" % ST) == LONG
    wrap = bob.eval("for _, b in ipairs(%s.blocks.blocks) do for _, x in ipairs(b.cells) do "
                    "if x:IsShown() and x.fs:GetText() == ... then return x.fs:CanWordWrap() end end end" % W, LONG)
    assert wrap is True
    # a text on the map
    bob.eval("%s.canvas:TextAt(400, 400)" % W)
    assert bob.eval("return %s.multi:IsVisible() and %s.multi:GetMaxLetters()" % (P, P)) == 160
    bob.type_text(multi, LONG)
    bob.click(bob.eval("return %s.button1" % P))
    assert elems(bob)[-1]["l"] == LONG
    # Enter starts a new line, Ctrl+Enter is OK; odd characters and | are cleaned away
    bob.eval("%s.canvas:TextAt(300, 300)" % W)
    bob.type_text(multi, "Tanks left ", enter=True)
    assert bob.eval("return %s.multi:GetText()" % P) == "Tanks left \n"
    bob.eval("%s.multi:Insert(...)" % P, "Healers |right\t!")
    assert bob.eval("return %s:IsShown()" % P) is True
    bob.set_modifiers(False, True, False)
    bob.press_enter(multi)
    bob.set_modifiers(False, False, False)
    assert bob.eval("return %s == nil" % P) is True     # (GetPrompt: nil once it closed)
    assert elems(bob)[-1]["l"] == "Tanks left \nHealers right !", elems(bob)[-1]
    two = bob.eval("return T_last()._h") / bob.eval("local e = T_last(); e = %s.strat.p[1].e; return e[#e - 1]._h" % ST)
    assert abs(two - 2) < 0.01, two
    bob.eval("local e = %s.strat.p[1].e; table.remove(e); %s:MarkDirty(true)" % (ST, B))
    # the name is typed in place, in the header, at its own limit; Esc goes back
    bob.eval(B + ":RenameStrategy()")
    T = W + ".titleEdit"
    assert bob.eval("return %s:IsVisible() and %s:HasFocus() and %s:GetMaxLetters()" % (T, T, T)) == 32
    assert bob.eval("return %s:GetText()" % T) == bob.eval("return %s.strat.n" % ST)
    bob.press_escape(bob.eval("return %s" % T))
    assert bob.eval("return %s:IsShown()" % T) is False
    # page notes: 1000 characters
    notes = ("Line of notes. " * 60).strip()
    assert 400 < len(notes) <= 1000
    bob.eval("%s.strat.p[1].no = ...; %s:MarkDirty(true)" % (ST, B), notes)
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(3)
    for name in ("Bob", "Lee"):
        s = strategies(c[name], BOSS)[0]
        assert s["p"][0]["k"][3]["d"][0][0] == LONG, (name, s["p"][0]["k"][3])
        assert s["p"][0]["e"][-1]["l"] == LONG and s["p"][0]["no"] == notes, name
    # past the limit (the prompts never let it through): the cell is left out, as any invalid cell
    res = bob.eval_py("local s = ns.Strategy:GetStrategy(...); s.p[1].k[4].d[1][1] = ('x'):rep(161); "
                      "local ok, e = ns.Strategy:SaveStrategy(s); return { ok = ok, d = ns.Strategy:GetStrategy(...).p[1].k[4].d }", sid)
    assert res["ok"] is True and not res.get("d"), res
    # too many lines, a tab: not valid; a label stays one line
    for bad in ("s.p[1].e[5].l = ('a\\n'):rep(8) .. 'a'", "s.p[1].e[5].l = 'a\\tb'", "s.p[1].e[1].l = 'a\\nb'"):
        res = bob.eval_py("local s = ns.Strategy:GetStrategy(...); %s; "
                          "local ok, e = ns.Strategy:SaveStrategy(s); return { ok = ok }" % bad, sid)
        assert res["ok"] is False, bad
    assert bob.eval("return ns.Strategy.TidyText(('a\\n'):rep(12) .. 'b', 160)").count("\n") == 7
    # a zone / icon label keeps its short limit
    res = bob.eval_py("local s = ns.Strategy:GetStrategy(...); s.p[1].e[1].l = ('x'):rep(49); "
                      "local ok, e = ns.Strategy:SaveStrategy(s); return { ok = ok, e = e }", sid)
    assert res["ok"] is False, res
    w.assert_no_errors()


@case
def a_builder_keeps_the_drafts_without_a_raid_role():
    """1.0: building strategies is for every guild member, so losing the council seat / the raid leader spot keeps
    the strategy drafts (only assigning a raid's players needs the role)."""
    w, c, bob, sid = setup()
    place(bob, 600)
    w.tick(1)
    assert len(drafts(bob)) == 1 and bob.eval("return %s:HasDraft()" % B) is True
    did = drafts(bob)[0]["did"]
    bob.eval("%s:Close()" % B)
    # Bob loses the guild council seat and the raid leader spot
    gm_pick(w, c["Gina"], [])
    set_raid_leaders(w, c["Gina"], [])
    w.tick(3)
    assert bob.eval("return ns.Strategy:CanAssign()") is False
    assert bob.eval("return ns.Strategy:CanBuild()") is True
    assert len(drafts(bob)) == 1 and len(drafts(bob, BOSS)) == 1
    assert bob.eval("return %s:HasDraft()" % B) is True
    bob.slash("/dz raids")
    bob.eval("ns.RaidsUI:SetView('strategies')")
    w.tick(1)
    # the draft's card is there with its two icons, Continue and More (Discard) (what they do is in their tooltips)
    assert bob.eval(r"""
        local function walk(f)
            for _, ch in ipairs({ f:GetChildren() }) do
                if ch.l1 and ch.edit and ch.more and ch:IsVisible() and ch.pill:IsShown() then
                    return ch.edit:IsShown() and ch.more:IsShown() and ch.edit.tipTitle == "Continue"
                        and ch.more.tipText == "Discard"
                end
                local r = walk(ch)
                if r ~= nil then return r end
            end
        end
        return walk(UIParent)
    """) is True
    assert bob.eval("return %s:OpenDraft(...)" % B, did) is True
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
