"""Strategy boards 1.0: who builds, who edits, and finding strategies.

Covers: every guild member building strategies, a strategy belonging to its creator (the GM and guild council may edit it; others can't change it, on
their own client or with a forged message), collaborators (invited and removed by the owner only), deleting (the
owner, the GM and the guild council), records from before 1.0, the filters (raid, encounter, guild member, free
search), the library's filter bar and row buttons, and the Share window. 1.3 (user rules 2026-10-04): a deletion wins
over any edit and the owner's change of the collaborators over an edit made on the old list, the same on every client
whatever order things arrive in; deleted strategies don't count toward the 150 / 20 caps.

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


def stored(cl, sid):
    """The stored record, a deletion (tombstone) included."""
    return cl.eval_py("local r = ns.db.strategy and ns.db.strategy[ns.Guild:GetGuildKey()]; return r and r.B[...]", sid)


def deliver(cl, sender, rec):
    """Hands one strategy record (SBU) to that client alone, as from `sender`: the order things arrive in, picked."""
    cl.eval("local sender, r = ...; local LS, LD = LibStub('LibSerialize'), LibStub('LibDeflate'); "
            "local text = tostring(ns.PROTO or 1) .. LD:EncodeForWoWAddonChannel(LD:CompressDeflate("
            "LS:Serialize({ t = 'SBU', k = 'B', r = r }))); ns.Comm:OnCommReceived('CDLd', text, 'GUILD', sender)",
            sender, rec)


def quietly(cl, code, *args):
    """Runs code on that client without anything leaving it (the record stays its own until delivered)."""
    return cl.eval_py("local orig = ns.Comm.Send; ns.Comm.Send = function() return true end; "
                      "local ok, res = pcall(function(...) " + code + " end, ...); ns.Comm.Send = orig; "
                      "assert(ok, res); return res", *args)


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
def a_deletion_wins_over_any_edit_on_every_client():
    """User rule 2026-10-04: a deleted strategy stays deleted (Copy brings one back, under a new id)."""
    w, c = world(names())
    rita, sam, lee, hana, gina = c["Rita"], c["Sam"], c["Lee"], c["Hana"], c["Gina"]
    rid = save_as(rita, "R plan")
    w.tick(2)
    assert call(rita, "AddCollaborator", rid, K("Sam"))["ok"] is True
    w.tick(2)
    old = stored(sam, rid)                       # collaborator Sam's copy, before the deletion
    assert call(gina, "DeleteStrategy", rid)["ok"] is True
    w.tick(2)
    # Sam's client saves the copy it had (the deletion hadn't reached it yet), with a newer rev: it stays deleted
    sam.eval("local d = ...; d.rev = GetServerTime() + 5; d.by = ns.Util.PlayerKey(); d.n = 'R plan v2'; "
             "ns.Comm:Send({ t = 'SBU', k = 'B', r = d }, 'GUILD', nil, 'data')", old)
    w.tick(2)
    for x in c.values():
        assert strat(x, rid) is None and stored(x, rid)["del"] is True, (x.name, stored(x, rid))
    # a deletion that crossed a later edit still deletes it, whichever of the two arrives first
    rid2 = save_as(rita, "Second")
    w.tick(2)
    assert call(rita, "AddCollaborator", rid2, K("Sam"))["ok"] is True
    w.tick(2)
    cur = stored(rita, rid2)
    edit = dict(cur, n="Sam's edit", by=K("Sam"), rev=cur["rev"] + 20)
    gone = {"id": rid2, "rev": cur["rev"] + 1, "by": K("Rita"), "del": True}
    deliver(lee, K("Sam"), edit)
    assert strat(lee, rid2)["n"] == "Sam's edit"
    deliver(lee, K("Rita"), gone)
    deliver(hana, K("Rita"), gone)
    deliver(hana, K("Sam"), edit)
    assert stored(lee, rid2) == gone and stored(hana, rid2) == gone, (stored(lee, rid2), stored(hana, rid2))
    assert call(rita, "DeleteStrategy", rid2)["ok"] is True      # (the others hear of it too)
    w.tick(2)
    # a deletion from anyone else never counts, even where it arrives before the strategy it names
    rid3 = quietly(rita, "local d = (loadstring(...))(); d.n = 'Third'; return assert(select(2, "
                         "ns.Strategy:SaveStrategy(d)))", COUNCIL)
    deliver(lee, K("Sam"), {"id": rid3, "rev": stored(rita, rid3)["rev"] + 50, "by": K("Sam"), "del": True})
    assert stored(lee, rid3)["del"] is True     # (nothing to check it against yet)
    deliver(lee, K("Rita"), stored(rita, rid3))
    assert strat(lee, rid3)["n"] == "Third"
    assert rename(rita, rid3, "Third v2")["ok"] is True
    w.tick(2)
    hashes = {n: x.eval("return ns.Strategy:GetDigestHash()") for n, x in c.items()}
    assert len(set(hashes.values())) == 1, hashes
    w.assert_no_errors()


@case
def the_owners_change_of_collaborators_wins_whatever_arrives_first():
    """An edit made on the collaborators list before the owner's change of it reached the editor loses to that change
    on every client, in either order (Strategy cr: the list's version)."""
    w, c = world(names())
    rita, lee, hana = c["Rita"], c["Lee"], c["Hana"]
    rid = save_as(rita, "R plan")
    w.tick(2)
    assert call(rita, "SetCollaborators", rid, [K("Sam"), K("Bob")])["ok"] is True
    w.tick(2)
    before = stored(lee, rid)
    assert before["co"] == [K("Bob"), K("Sam")] and before["cr"] == before["rev"], before
    # Rita takes Sam off while Sam saves an edit on the list he still has (a newer rev). Lee gets Sam's edit first,
    # Hana the owner's change first: both keep the owner's change
    quietly(rita, "local id, key = ...; assert(ns.Strategy:RemoveCollaborator(id, key))", rid, K("Sam"))
    change = stored(rita, rid)
    assert change["co"] == [K("Bob")] and change["cr"] == change["rev"] > before["cr"], change
    edit = dict(before, n="Sam's edit", by=K("Sam"), rev=change["rev"] + 30)
    deliver(lee, K("Sam"), edit)
    assert strat(lee, rid)["n"] == "Sam's edit"
    deliver(lee, K("Rita"), change)
    deliver(hana, K("Rita"), change)
    deliver(hana, K("Sam"), edit)
    for x in (lee, hana):
        assert stored(x, rid) == change, (x.name, stored(x, rid))
    # an edit made on the new list is newer than the change, as always; a collaborator can't raise the version
    after = dict(change, n="Bob's edit", by=K("Bob"), rev=change["rev"] + 5)
    forged = dict(change, n="Bob's own list", by=K("Bob"), rev=change["rev"] + 9, cr=change["rev"] + 9)
    for x in (lee, hana):
        deliver(x, K("Bob"), after)
        deliver(x, K("Bob"), forged)
        assert strat(x, rid)["n"] == "Bob's edit", x.name
    # an unchanged list keeps its version (no edit is dropped for nothing)
    assert call(rita, "SetCollaborators", rid, [K("Bob")])["ok"] is True
    assert stored(rita, rid)["cr"] == change["cr"]
    w.assert_no_errors()


FILL = r"""
local src, prefix, nLive, nDel, owners, revBase = ...
local g = ns.Guild:GetGuildKey()
ns.db.strategy = ns.db.strategy or {}
local root = ns.db.strategy[g] or { B = {}, F = {}, L = {} }
ns.db.strategy[g] = root
local now = GetServerTime()
for i = 1, nLive + nDel do
    local d = (loadstring(src))()
    d.id, d.rev, d.n = prefix .. i, revBase + i, prefix .. i
    d.by = owners[(i - 1) % #owners + 1]
    d.ow = d.by
    local r = assert(ns.Strategy._CleanStrategy(d, now))
    if i > nLive then r = { id = r.id, rev = r.rev, by = r.by, del = true } end
    root.B[r.id] = r
end
"""

COUNT = ("local n, live = 0, 0; for _, r in pairs(ns.db.strategy[ns.Guild:GetGuildKey()].B) do n = n + 1; "
         "if not r.del then live = live + 1 end end; return { n = n, live = live }")


@case
def deleted_strategies_dont_count_toward_the_caps():
    """User rule 2026-10-04: 150 strategies in the guild and 20 per owner count the strategies there are, not the
    deletions kept for 30 days (180 records at most: a new strategy then forgets the oldest deletion)."""
    w, c = world(names())
    rita, sam, hana = c["Rita"], c["Sam"], c["Hana"]
    t = rita.eval("return GetServerTime()")
    for x in c.values():
        x.eval(FILL, COUNCIL, "sam", 19, 5, [K("Sam")], t - 3000)
    # 20 per owner: the deleted five don't count
    s20 = save_as(sam, "Twentieth")
    res = sam.eval_py("local d = (loadstring(...))(); d.n = 'One more'; local ok, r = ns.Strategy:SaveStrategy(d); "
                      "return { ok = ok, r = r }", COUNCIL)
    assert res["ok"] is False and "20 strategies already" in res["r"], res
    assert call(sam, "DeleteStrategy", "sam1")["ok"] is True
    w.tick(2)
    s21 = save_as(sam, "In its place")
    w.tick(2)
    assert strat(hana, s20) and strat(hana, s21), "the receivers count the same way"
    # 150 in the guild: 20 of Sam's + 129 more, with 25 more deletions = 180 records, the most kept
    owners = ["Own%d-Thunderstrike" % i for i in range(1, 11)]
    for x in c.values():
        x.eval(FILL, COUNCIL, "old", 129, 25, owners, t - 9000)
        assert x.eval_py(COUNT) == {"n": 180, "live": 149}, (x.name, x.eval_py(COUNT))
    a = save_as(rita, "150th")
    w.tick(2)
    for x in (rita, hana):
        assert x.eval_py(COUNT) == {"n": 180, "live": 150}, (x.name, x.eval_py(COUNT))
        assert stored(x, "old130") is None and stored(x, "old131")["del"] is True, x.name   # the oldest deletion went
    assert strat(hana, a)["n"] == "150th"
    res = rita.eval_py("local d = (loadstring(...))(); d.n = '151st'; local ok, r = ns.Strategy:SaveStrategy(d); "
                       "return { ok = ok, r = r }", COUNCIL)
    assert res["ok"] is False and "the guild has 150 strategies already" in res["r"], res
    # deleting one makes room at once, here and for everyone else
    assert call(rita, "DeleteStrategy", a)["ok"] is True
    w.tick(2)
    b = save_as(rita, "Instead")
    w.tick(2)
    assert strat(hana, b)["n"] == "Instead" and hana.eval_py(COUNT)["live"] == 150
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
        "    for _, k in ipairs({ 'open', 'edit', 'copy', 'share', 'collab', 'del' }) do "
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
    # mine: everything; shared with me: edit; someone else's: open and copy; a link in chat for everyone
    assert buttons(sam, "Horse") == ["open", "edit", "copy", "share", "collab", "del"]
    assert buttons(sam, "Prog kite") == ["open", "edit", "copy", "share"]
    assert buttons(sam, "25 farm") == ["open", "copy", "share"]
    assert sam.find_text("33ff99shared with you", True, True)
    # the guild council also edits and deletes (Collaborators stays the owner's; no "shared with you")
    open_library(w, bob)
    assert buttons(bob, "Horse") == ["open", "edit", "copy", "share", "del"]
    assert not bob.find_text("33ff99shared with you", True, True)
    assert buttons(bob, "25 farm") == ["open", "edit", "copy", "share", "collab", "del"]
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
    assert rita.find_text("only you, the GM and the guild council can change it", True, True)
    # (the GM and the guild council delete too, user rule 1.0)
    assert rita.find_text("Only you invite and remove; you, the GM and the guild council delete.", True, True)
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
