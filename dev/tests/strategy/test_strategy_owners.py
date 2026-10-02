"""Strategy boards 1.0: who builds, who edits, and finding strategies.

Covers: every guild member building strategies, a strategy belonging to its creator (the GM and guild council may edit it; others can't change it, on
their own client or with a forged message), collaborators (invited and removed by the owner only), deleting (the
owner, the GM and the guild council), records from before 1.0, the filters (raid, encounter, guild member, free
search), the library's filter bar and row buttons, and the Share window.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_owners.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, K, save_council, strategies, COUNCIL  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

BOSS = "BlackTemple:Council"
P = "ns.RaidsUI:GetPanel()"


def names():
    return (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"),
            ("Sam", 3, "ROGUE"), ("Hana", 3, "HUNTER"))


def strat(cl, sid):
    return cl.eval_py("return ns.Strategy:GetStrategy(...)", sid)


def rename(cl, sid, name):
    return cl.eval_py("local id, n = ...; local s = ns.Strategy:GetStrategy(id); s.n = n; "
                      "local ok, e = ns.Strategy:SaveStrategy(s); return { ok = ok, e = e }", sid, name)


def call(cl, fn, *args):
    return cl.eval_py("local fn = ...; local ok, e = ns.Strategy[fn](ns.Strategy, select(2, ...)); "
                      "return { ok = ok, e = e }", fn, *args)


def forge(cl, sid, patch):
    """Sends a changed copy of a strategy under the sender's own name, past the local checks."""
    cl.eval("local id, code = ...; local d = ns.Strategy:GetStrategy(id); d.rev = d.rev + 10; "
            "d.by = ns.Util.PlayerKey(); loadstring(code)(d); "
            "ns.Comm:Send({ t = 'SBU', k = 'B', r = d }, 'GUILD', nil, 'data')", sid, "local d = ...; " + patch)


def find(cl, **f):
    return [s["n"] for s in cl.eval_py("return ns.Strategy:Find(...)", f)]


def save_as(cl, name, boss=None):
    res = cl.eval_py("local src, n, b = ...; local d = (loadstring(src))(); d.n = n; if b then d.b = b end; "
                     "local ok, r = ns.Strategy:SaveStrategy(d); return { ok = ok, r = r }", COUNCIL, name, boss)
    assert res["ok"] is True, res
    return res["r"]


# ------------------------------------------------------------------------------------------------------------------
@case
def every_member_builds_and_only_the_owner_changes_it():
    w, c = world(names())
    rita, sam, bob, lee = c["Rita"], c["Sam"], c["Bob"], c["Lee"]
    rid = save_council(rita)
    w.tick(2)
    for n, x in c.items():
        s = strat(x, rid)
        assert s and s["ow"] == K("Rita") and s["by"] == K("Rita"), (n, s)
        assert x.eval("return ns.Strategy:GetOwner(...)", rid) == K("Rita")
        # the owner; and, as an exception, the GM (Gina) and the guild council (Bob)
        assert x.eval("return ns.Strategy:CanEditStrategy(...)", rid) is (n in ("Rita", "Gina", "Bob")), n
    # not the owner: refused on their own client
    res = rename(sam, rid, "Mine now")
    assert res["ok"] is False and "owner" in res["e"], res
    # picking the collaborators is the owner's alone, also for the GM and the guild council
    for x in (sam, bob, c["Gina"]):
        assert call(x, "SetCollaborators", rid, [K("Sam")])["ok"] is False
    # and a forged edit / a forged change of owner is dropped by everyone else
    forge(sam, rid, "d.n = 'Hacked'")
    forge(sam, rid, "d.n = 'Stolen'; d.ow = 'Sam-Thunderstrike'")
    w.tick(2)
    for x in (lee, rita, bob):
        s = strat(x, rid)
        assert s["n"] == "25 farm" and s["ow"] == K("Rita"), s
    # the owner's own edit still lands
    assert rename(rita, rid, "25 prog")["ok"] is True
    w.tick(2)
    assert strat(lee, rid)["n"] == "25 prog"
    # the GM and the guild council edit anyone's strategy: it stays the owner's, with the owner's collaborators
    assert call(rita, "AddCollaborator", rid, K("Hana"))["ok"] is True
    w.tick(2)
    assert rename(bob, rid, "Council fix")["ok"] is True
    w.tick(2)
    s = strat(lee, rid)
    assert s["n"] == "Council fix" and s["ow"] == K("Rita") and s["by"] == K("Bob") and s["co"] == [K("Hana")], s
    assert rename(c["Gina"], rid, "GM fix")["ok"] is True
    w.tick(2)
    assert strat(lee, rid)["n"] == "GM fix" and strat(lee, rid)["ow"] == K("Rita")
    forge(bob, rid, "d.co = { 'Bob-Thunderstrike' }")
    forge(bob, rid, "d.ow = 'Bob-Thunderstrike'")
    w.tick(2)
    s = strat(lee, rid)
    assert s["ow"] == K("Rita") and s["co"] == [K("Hana")], s
    assert rename(rita, rid, "25 prog")["ok"] is True
    w.tick(2)
    # a copy belongs to whoever copied it
    res = sam.eval_py("local ok, id = ns.Strategy:CopyStrategy(..., 'Sam variant'); return { ok = ok, id = id }", rid)
    assert res["ok"] is True, res
    w.tick(2)
    s = strat(lee, res["id"])
    assert s["ow"] == K("Sam") and s.get("co") is None, s
    assert rename(sam, res["id"], "Sam v2")["ok"] is True
    w.assert_no_errors()


@case
def collaborators_are_invited_and_removed_by_the_owner():
    w, c = world(names())
    rita, sam, lee, hana = c["Rita"], c["Sam"], c["Lee"], c["Hana"]
    rid = save_council(rita)
    w.tick(2)
    assert call(rita, "AddCollaborator", rid, K("Sam"))["ok"] is True
    w.tick(2)
    assert strat(lee, rid)["co"] == [K("Sam")]
    assert sam.eval("return ns.Strategy:CanEditStrategy(...)", rid) is True
    assert lee.eval("return ns.Strategy:CanEditStrategy(...)", rid) is False
    assert sam.eval("return ns.Strategy:IsOwner(...)", rid) is False
    # the collaborator's edit reaches everyone; owner and collaborators stay what they were
    assert rename(sam, rid, "With Sam")["ok"] is True
    w.tick(2)
    s = strat(hana, rid)
    assert s["n"] == "With Sam" and s["ow"] == K("Rita") and s["by"] == K("Sam") and s["co"] == [K("Sam")], s
    # a collaborator can't invite, remove or delete: not locally, not with a forged record
    assert call(sam, "AddCollaborator", rid, K("Lee"))["ok"] is False
    assert call(sam, "DeleteStrategy", rid)["ok"] is False
    forge(sam, rid, "d.co = { 'Lee-Thunderstrike', 'Sam-Thunderstrike' }")
    w.tick(2)
    assert strat(hana, rid)["co"] == [K("Sam")]
    assert lee.eval("return ns.Strategy:CanEditStrategy(...)", rid) is False
    # only guild members, at most MAX_COLLAB, never the owner
    res = call(rita, "AddCollaborator", rid, "Nobody-Thunderstrike")
    assert res["ok"] is False and "not in the guild" in res["e"], res
    assert call(rita, "SetCollaborators", rid, [K("Sam"), K("Rita"), K("Lee")])["ok"] is True
    w.tick(2)
    assert strat(hana, rid)["co"] == [K("Lee"), K("Sam")]
    # removed: the edit of the one who was taken off is refused, here and by the others
    assert call(rita, "RemoveCollaborator", rid, K("Sam"))["ok"] is True
    w.tick(2)
    assert sam.eval("return ns.Strategy:CanEditStrategy(...)", rid) is False
    assert rename(sam, rid, "Still mine?")["ok"] is False
    forge(sam, rid, "d.n = 'Still mine?'")
    w.tick(2)
    s = strat(hana, rid)
    assert s["n"] == "With Sam" and s["co"] == [K("Lee")], s
    assert rename(lee, rid, "With Lee")["ok"] is True
    w.tick(2)
    assert strat(hana, rid)["n"] == "With Lee"
    w.assert_no_errors()


@case
def the_owner_the_gm_and_the_guild_council_delete():
    # Bob = guild council, Lee = raid leader only
    w, c = world(names(), planners=("Bob", "Lee"))
    rita, sam, bob, lee, gina = c["Rita"], c["Sam"], c["Bob"], c["Lee"], c["Gina"]
    a, b, d = save_as(rita, "A"), save_as(rita, "B"), save_as(rita, "D")
    w.tick(2)
    for x in (sam, lee):
        assert x.eval("return ns.Strategy:CanDeleteStrategy(...)", a) is False
        res = call(x, "DeleteStrategy", a)
        assert res["ok"] is False and "owner" in res["e"], res
    # a forged tombstone from a member is dropped
    sam.eval("local id = ...; local cur = ns.Strategy:GetStrategy(id); ns.Comm:Send({ t = 'SBU', k = 'B', "
             "r = { id = id, rev = cur.rev + 10, by = ns.Util.PlayerKey(), del = true } }, 'GUILD', nil, 'data')", a)
    w.tick(2)
    assert sorted(find(c["Hana"])) == ["A", "B", "D"]
    assert call(bob, "DeleteStrategy", a)["ok"] is True          # guild council
    assert call(gina, "DeleteStrategy", b)["ok"] is True         # GM
    assert call(rita, "DeleteStrategy", d)["ok"] is True         # the owner
    w.tick(2)
    for x in c.values():
        assert strategies(x) == []
    w.assert_no_errors()


@case
def a_strategy_from_before_1_0_belongs_to_its_last_editor():
    w, c = world(names())
    bob, sam, lee = c["Bob"], c["Sam"], c["Lee"]
    for x in c.values():
        x.eval("local d = (loadstring(...))(); d.id = 'old1'; d.rev = GetServerTime() - 100; d.by = 'Bob-Thunderstrike'; "
               "local r = assert(ns.Strategy._CleanStrategy(d, GetServerTime())); ns.db.strategy = ns.db.strategy or {}; "
               "local g = ns.Guild:GetGuildKey(); "
               "ns.db.strategy[g] = ns.db.strategy[g] or { B = {}, F = {}, L = {}, OK = {} }; "
               "ns.db.strategy[g].B.old1 = r", COUNCIL)
    s = strat(lee, "old1")
    assert s and s.get("ow") is None, s
    assert lee.eval("return ns.Strategy:GetOwner('old1')") == K("Bob")
    assert sam.eval("return ns.Strategy:CanEditStrategy('old1')") is False
    forge(sam, "old1", "d.n = 'Hacked'")
    w.tick(2)
    assert strat(lee, "old1")["n"] == "25 farm"
    # his next save writes the owner down
    assert rename(bob, "old1", "Kept")["ok"] is True
    w.tick(2)
    s = strat(lee, "old1")
    assert s["n"] == "Kept" and s["ow"] == K("Bob"), s
    w.assert_no_errors()


@case
def find_by_raid_encounter_member_and_free_search():
    w, c = world(names())
    bob, rita, sam, lee = c["Bob"], c["Rita"], c["Sam"], c["Lee"]
    save_as(bob, "25 farm")
    rid = save_as(rita, "Prog kite")
    save_as(sam, "Horse", "Karazhan:Attumen")
    save_as(sam, "Gruul standard", "GruulsLair:Gruul")
    w.tick(3)
    # raid order, then boss order, then name
    assert find(lee) == ["Horse", "Gruul standard", "25 farm", "Prog kite"], find(lee)
    assert find(lee, raid="BlackTemple") == ["25 farm", "Prog kite"]
    assert find(lee, raid="Karazhan") == ["Horse"]
    assert find(lee, boss=BOSS) == ["25 farm", "Prog kite"]
    assert find(lee, boss="BlackTemple:Najentus") == []
    assert find(lee, by=K("Sam")) == ["Horse", "Gruul standard"]
    assert find(lee, by=K("Sam"), raid="Karazhan") == ["Horse"]
    assert find(lee, by=K("Lee")) == []
    # free search: the name, the boss, the raid, the owner, a table's name; every word must match
    assert find(lee, text="horse") == ["Horse"]
    assert find(lee, text="  KITE ") == ["Prog kite"]
    assert find(lee, text="illidari") == ["25 farm", "Prog kite"]
    assert find(lee, text="karazhan") == ["Horse"]
    assert find(lee, text="rita") == ["Prog kite"]
    assert find(lee, text="misdirects") == ["Horse", "Gruul standard", "25 farm", "Prog kite"]
    assert find(lee, text="council farm") == ["25 farm"]
    assert find(lee, text="council horse") == []
    assert find(lee, text="farm", by=K("Rita")) == []
    # shared with a member
    assert find(lee, co=K("Lee")) == []
    assert call(rita, "AddCollaborator", rid, K("Lee"))["ok"] is True
    w.tick(2)
    assert find(lee, co=K("Lee")) == ["Prog kite"]
    assert find(sam, text="lee") == ["Prog kite"]
    authors = lee.eval_py("return ns.Strategy:GetAuthors()")
    assert [(a["key"], a["n"]) for a in authors] == [(K("Bob"), 1), (K("Rita"), 1), (K("Sam"), 2)], authors
    w.assert_no_errors()


def open_library(w, cl):
    cl.slash("/dz raids")
    w.tick(0.5)
    cl.eval("ns.RaidsUI:SetView('strategies')")
    w.tick(0.5)


def lib_rows(cl):
    tree, rows = cl.eval_py("local t, r = ns.StrategiesUI:GetRows(); return { t, r }")
    return list(tree or []), list(rows or [])


def row_names(cl):
    return [(r.get("s") or r.get("draft"))["n"] for r in lib_rows(cl)[1]]


def tree_count(cl, name):
    for r in lib_rows(cl)[0]:
        if r["name"] == name:
            return r["count"]
    return None


def buttons(cl, name):
    """The buttons shown on a strategy's row in the library."""
    return cl.eval_py(
        "local want = ...; local out = {}; "
        "ns.RaidsUI:GetPanel().strategies.detail.list.box:ForEachFrame(function(row) "
        "  local d = row.__cdlData; if d and d.s and d.s.n == want then "
        "    for _, k in ipairs({ 'open', 'edit', 'copy', 'share', 'del' }) do "
        "      if row[k]:IsShown() then out[#out + 1] = k end end end end); return out", name)


@case
def the_library_filters_and_shows_what_a_member_may_do():
    w, c = world(names())
    bob, rita, sam, lee = c["Bob"], c["Rita"], c["Sam"], c["Lee"]
    save_as(bob, "25 farm")
    rid = save_as(rita, "Prog kite")
    sid = save_as(sam, "Horse", "Karazhan:Attumen")
    call(rita, "AddCollaborator", rid, K("Sam"))
    w.tick(3)
    open_library(w, sam)
    # everything, across the raids; the tree counts
    assert row_names(sam) == ["Horse", "25 farm", "Prog kite"], row_names(sam)
    assert tree_count(sam, "All raids") == 3 and tree_count(sam, "Black Temple") == 2
    assert tree_count(sam, "Karazhan") == 1 and tree_count(sam, "The Illidari Council") == 2
    assert sam.eval("return %s.strategies.detail.newBtn:IsShown()" % P) is True
    # mine: everything; shared with me: edit; someone else's: open and copy
    assert buttons(sam, "Horse") == ["open", "edit", "copy", "share", "del"]
    assert buttons(sam, "Prog kite") == ["open", "edit", "copy"]
    assert buttons(sam, "25 farm") == ["open", "copy"]
    assert sam.find_text("33ff99shared with you", True, True)
    # the guild council also edits and deletes (Share stays the owner's; no "shared with you")
    open_library(w, bob)
    assert buttons(bob, "Horse") == ["open", "edit", "copy", "del"]
    assert not bob.find_text("33ff99shared with you", True, True)
    assert buttons(bob, "25 farm") == ["open", "edit", "copy", "share", "del"]
    # raid and encounter (the tree), member, free search
    sam.eval("ns.StrategiesUI:SelectRaid('BlackTemple')")
    assert row_names(sam) == ["25 farm", "Prog kite"]
    sam.eval("ns.StrategiesUI:SelectBoss('Karazhan:Attumen')")
    assert row_names(sam) == ["Horse"]
    sam.eval("ns.StrategiesUI:SetFilter({ by = '@me' })")
    assert row_names(sam) == ["Horse"] and tree_count(sam, "All raids") == 1
    sam.eval("ns.StrategiesUI:SetFilter({ by = '@co' })")
    assert row_names(sam) == ["Prog kite"]
    sam.eval("ns.StrategiesUI:SetFilter({ by = ... })", K("Bob"))
    assert row_names(sam) == ["25 farm"]
    assert sam.eval("return %s.strategies.clear:IsShown()" % P) is True
    sam.eval("ns.StrategiesUI:SetFilter({ by = ..., raid = 'Karazhan' })", K("Bob"))
    assert row_names(sam) == [] and sam.find_text("No strategy matches the filters", True, True)
    assert tree_count(sam, "All raids") == 1               # the tree shows where the matches are
    # typing in the search box
    sam.eval("ns.StrategiesUI:SetFilter({})")
    sam.type_text(sam.eval("return %s.strategies.search" % P), "kite")
    w.tick(0.5)
    assert row_names(sam) == ["Prog kite"], row_names(sam)
    assert sam.eval_py("return ns.StrategiesUI:GetFilter()")["text"] == "kite"
    sam.click(sam.eval("return %s.strategies.clear" % P))
    w.tick(0.5)
    assert len(row_names(sam)) == 3
    assert sam.eval("return %s.strategies.clear:IsShown()" % P) is False
    # opening someone else's for editing stays a view; a shared one opens for editing
    sam.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", rid)
    assert sam.eval("return ns.StrategyBoard:GetState().mode") == "edit"
    sam.eval("ns.StrategyBoard:Close()")
    lee.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", rid)
    assert lee.eval("return ns.StrategyBoard:GetState().mode") == "view"
    assert lee.eval("local w = _G.DisasterZoneStrategyBoard; return w.editBtn:IsShown()") is False
    w.assert_no_errors()


@case
def the_share_window_invites_and_removes():
    w, c = world(names())
    rita, sam, lee = c["Rita"], c["Sam"], c["Lee"]
    rid = save_council(rita)
    w.tick(2)
    open_library(w, sam)
    n0 = len(sam.chat_frame)
    assert sam.eval("return ns.StrategiesUI:OpenShare(...)", rid) is False
    assert any("owner" in str(x) for x in sam.chat_frame[n0:])
    open_library(w, rita)
    assert rita.eval("return ns.StrategiesUI:OpenShare(...)", rid) is True
    win = "ns.StrategiesUI:GetShareWindow()"
    assert rita.eval("return %s:IsShown()" % win) is True
    assert rita.find_text("only you can change this strategy", True, True)
    assert rita.eval("return ns.StrategiesUI:ToggleCollaborator(...)", K("Lee")) is True
    assert rita.eval("return ns.StrategiesUI:ToggleCollaborator(...)", K("Sam")) is True
    w.tick(2)
    assert strat(sam, rid)["co"] == [K("Lee"), K("Sam")]
    assert [r["key"] for r in rita.eval_py("return %s.list:GetData()" % win)] == [K("Lee"), K("Sam")]
    assert rita.find_text("2 / 10 collaborators", True, True)
    assert lee.eval("return ns.Strategy:CanEditStrategy(...)", rid) is True
    # the X of a row takes that member off
    rita.eval("local key = ...; local w = %s; w.list.box:ForEachFrame(function(row) if row.__cdlData.key == key then "
              "row.remove:GetScript('OnClick')(row.remove) end end)" % win, K("Lee"))
    w.tick(2)
    assert strat(sam, rid)["co"] == [K("Sam")]
    assert lee.eval("return ns.Strategy:CanEditStrategy(...)", rid) is False
    # the strategy is deleted: the window closes
    assert call(rita, "DeleteStrategy", rid)["ok"] is True
    w.tick(1)
    assert rita.eval("return %s:IsShown()" % win) is False
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
