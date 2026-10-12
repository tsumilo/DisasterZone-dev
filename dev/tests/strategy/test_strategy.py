"""ADDENDUM K: strategy boards core (strategies, fills, sync), on the real addon.

Covers: an author's strategy reaching every guild member, members refused and forged / non-author records hidden,
malformed records rejected, slots (labels, filters, shared across pages), fills per raid + boss (carry over, suggest,
duplicates), a late login catching up through the digest, copy / delete, and pruning. 1.3: a member's strategy may be
as large as a council member's message (user rule 2026-10-04), and one too big to send is refused when saved.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import (world, K, DAY, GUILD_KEY, now, create, signup, save_council, strategies, fill,  # noqa: E402
                       get_fill, COUNCIL)
from _common import case, run_all  # noqa: E402
import lr_common as lr  # noqa: E402

BOSS = "BlackTemple:Council"


def names():
    return (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"),
            ("Sam", 3, "ROGUE"), ("Hana", 3, "HUNTER"), ("Hugo", 3, "HUNTER"))


# ------------------------------------------------------------------------------------------------------------------
@case
def author_strategy_reaches_everyone():
    w, c = world(names())
    bob = c["Bob"]
    assert bob.eval("return ns.Strategy:CanAssign()") is True
    assert c["Gina"].eval("return ns.Strategy:CanAssign()") is True
    assert c["Rita"].eval("return ns.Strategy:CanAssign()") is False
    assert c["Rita"].eval("return ns.Strategy:CanBuild()") is True      # 1.0: every member builds strategies
    sid = save_council(bob)
    w.tick(2)
    # (the SBU itself is a multi-part AceComm message; the log decoder only reads single-part ones)
    for n, x in c.items():
        ss = strategies(x, BOSS)
        assert len(ss) == 1 and ss[0]["id"] == sid and ss[0]["n"] == "25 farm", (n, ss)
        assert len(ss[0]["p"]) == 2 and len(ss[0]["p"][0]["e"]) == 6 and len(ss[0]["p"][0]["k"]) == 4, n
        assert ss[0]["p"][1]["no"] == "Dampen magic pre-pull"
    assert c["Sam"].eval_py("return ns.Strategy:CountByBoss()") == {BOSS: 1}
    assert c["Sam"].eval("return ns.Strategy:GetBossName(...)", BOSS) == "The Illidari Council"
    bosses = c["Sam"].eval_py("return ns.Strategy:GetBosses('bt')")
    assert bosses[0]["ref"] == "BlackTemple:Najentus" and any(b["ref"] == BOSS for b in bosses), bosses
    assert not any(b["ref"].endswith(":Trash") for b in bosses)
    # an edit (rename) and a copy
    res = bob.eval_py("local s = ns.Strategy:GetStrategy(...); s.n = 'Farm'; local ok, e = ns.Strategy:SaveStrategy(s);"
                      " return { ok = ok, e = e }", sid)
    assert res["ok"] is True, res
    res = bob.eval_py("local ok, id = ns.Strategy:CopyStrategy(..., 'Prog'); return { ok = ok, id = id }", sid)
    assert res["ok"] is True
    w.tick(2)
    assert sorted(s["n"] for s in strategies(c["Lee"], BOSS)) == ["Farm", "Prog"]
    # delete: gone for everyone
    assert bob.eval("return ns.Strategy:DeleteStrategy(...)", res["id"]) is True
    w.tick(2)
    assert [s["n"] for s in strategies(c["Lee"])] == ["Farm"]
    w.assert_no_errors()


@case
def members_build_and_forged_records_are_dropped():
    w, c = world(names())
    rita, sam = c["Rita"], c["Sam"]
    res = rita.eval_py("local d = (loadstring(...))(); local ok, e = ns.Strategy:SaveStrategy(d); return { ok = ok, e = e }",
                       COUNCIL)
    assert res["ok"] is True, res
    rid = res["e"]
    # forged editor name: dropped; a member's own record: stored and shown (1.0: every member builds)
    rita.eval("local d = (loadstring(...))(); d.id = 'f1'; d.rev = GetServerTime(); d.by = 'Bob-Thunderstrike';"
              " ns.Comm:Send({ t = 'SBU', k = 'B', r = d }, 'GUILD', nil, 'data')", COUNCIL)
    rita.eval("local d = (loadstring(...))(); d.id = 'f2'; d.rev = GetServerTime(); d.by = 'Rita-Thunderstrike';"
              " ns.Comm:Send({ t = 'SBU', k = 'B', r = d }, 'GUILD', nil, 'data')", COUNCIL)
    w.tick(2)
    root = "ns.db.strategy['%s']" % GUILD_KEY
    assert sam.eval("return %s.B.f1" % root) is None
    assert sam.eval("return %s.B.f2 ~= nil" % root) is True
    assert sorted(s["id"] for s in strategies(sam)) == sorted(["f2", rid])
    # malformed: bad boss ref, unknown element, pipe in a label, too many pages, duplicate block ids, bad filter
    bad = [
        "d.b = 'Black Temple'",
        "d.p[1].e[1].t = 'q'",
        "d.p[1].e[1].l = 'a|cffff0000b'",
        "for i = 3, 7 do d.p[i] = { id = 'q' .. i, n = 'X', m = 0 } end",
        "d.p[2].k = { { id = 'tk', n = 'Again', r = 1, c = { { t = 'p' } } } }",
        "d.p[1].k[1].c[1].f = 'WIZARD'",
        "d.p[1].k[1].r = 30",
        "d.p[1].e[6].r = 'tk.1'",
    ]
    for i, patch in enumerate(bad):
        rita.eval("local d = (loadstring(...))(); d.id = 'b%d'; d.rev = GetServerTime(); d.by = 'Rita-Thunderstrike';"
                  " %s; ns.Comm:Send({ t = 'SBU', k = 'B', r = d }, 'GUILD', nil, 'data')" % (i, patch), COUNCIL)
    w.tick(2)
    stored = sam.eval_py("local out = {}; for id in pairs(%s.B) do out[#out + 1] = id end; table.sort(out); return out"
                         % root)
    assert sorted(stored) == sorted(["f2", rid]), stored
    # the author's own validation says why
    assert c["Bob"].eval("local d = (loadstring(...))(); d.p[1].e[1].l = 'x|y'; return (ns.Strategy:Validate(d))",
                         COUNCIL) is None
    w.assert_no_errors()


@case
def slots_labels_filters_and_suggest():
    w, c = world(names())
    bob = c["Bob"]
    sid = save_council(bob)
    slots = bob.eval_py("return ns.Strategy:GetSlots(ns.Strategy:GetStrategy(...))", sid)
    refs = [s["ref"] for s in slots]
    assert refs == ["tk.1.1", "tk.2.1", "md.1.2", "md.2.2", "zn.1.1", "zn.1.2", "zn.2.1", "zn.2.2", "zn.3.1",
                    "zn.3.2"], refs
    assert slots[0]["label"] == "Tanks · Gathios · Player", slots[0]
    assert slots[2]["label"] == "Misdirects · #1 · Hunter", slots[2]
    assert slots[2]["f"] == "HUNTER" and slots[0]["f"] == "tank" and slots[4].get("f") is None
    assert bob.eval("return ns.Strategy:MatchFilter('HUNTER', 'HUNTER', nil)") is True
    assert bob.eval("return ns.Strategy:MatchFilter('tank', 'WARRIOR', 3)") is True
    assert bob.eval("return ns.Strategy:MatchFilter('tank', 'WARRIOR', 1)") is False
    assert bob.eval("return ns.Strategy:MatchFilter('tank,HUNTER', 'WARRIOR', nil)") is False
    assert bob.eval("return ns.Strategy:FilterText('tank,HUNTER')") == "Tank or Hunter"
    members = [{"key": K("Lee"), "c": "WARRIOR", "sp": 3}, {"key": K("Gina"), "c": "PALADIN", "sp": 2},
               {"key": K("Hana"), "c": "HUNTER"}, {"key": K("Hugo"), "c": "HUNTER"}, {"key": K("Sam"), "c": "ROGUE", "sp": 1}]
    res = bob.eval_py("local s = ns.Strategy:GetStrategy(...); local a, n = ns.Strategy:SuggestFill(s, { ['md.1.2'] = "
                      "'Hugo-Thunderstrike' }, select(2, ...)); return { a = a, n = n }", sid, members)
    a = res["a"]
    assert a["tk.1.1"] in (K("Lee"), K("Gina")) and a["tk.2.1"] in (K("Lee"), K("Gina")) and a["tk.1.1"] != a["tk.2.1"], a
    assert a["md.1.2"] == K("Hugo") and a["md.2.2"] == K("Hana"), a     # kept, then the other hunter
    assert not any(r.startswith("zn.") for r in a), a                     # open slots stay for the raid leader
    assert res["n"] == 3
    dup = bob.eval_py("return ns.Strategy:FindDuplicates(ns.Strategy:GetStrategy(...), { ['zn.1.1'] = 'A-X', "
                      "['zn.2.2'] = 'A-X', ['zn.3.1'] = 'B-X', ['tk.1.1'] = 'A-X' })", sid)
    assert sorted(dup) == ["zn.1.1", "zn.2.2"], dup
    w.assert_no_errors()


@case
def fills_sync_and_carry_over():
    w, c = world(names())
    bob, sam = c["Bob"], c["Sam"]
    sid = save_council(bob)
    t0 = now(bob) + DAY
    occ1 = create(bob, i="bt", t=t0)
    occ2 = create(bob, i="bt", t=t0 + 7 * DAY)
    w.tick(2)
    # nothing picked yet: the boss' only strategy is the raid's
    assert sam.eval("local s = ns.Strategy:GetRaidStrategy(...); return s and s.id", occ1, BOSS) == sid
    assert fill(bob, occ1, BOSS, sid, {"tk.1.1": K("Lee"), "md.1.2": K("Hana")})["ok"] is True
    res = fill(c["Rita"], occ1, BOSS, sid, {"tk.1.1": K("Rita")})
    assert res["ok"] is False and "raid leaders" in res["e"], res
    w.tick(2)
    for n in ("Sam", "Gina", "Rita"):
        f = get_fill(c[n], occ1, BOSS)
        assert f["s"] == sid and f["a"] == {"tk.1.1": K("Lee"), "md.1.2": K("Hana")}, (n, f)
    # carry over for next week's raid: last week's names (not its own)
    a = sam.eval_py("return (ns.Strategy:GetLastFill(...))", sid, occ2)
    assert a == {"tk.1.1": K("Lee"), "md.1.2": K("Hana")}, a
    assert sam.eval("return ns.Strategy:GetLastFill(...)", sid, occ1) is None
    # members of the raid come from the sign-ups
    signup(c["Hugo"], occ2, "A")
    signup(c["Lee"], occ2, "T")
    signup(c["Sam"], occ2, "X")
    w.tick(2)
    ms = bob.eval_py("return ns.Strategy:GetRaidMembers(...)", occ2)
    assert [m["key"] for m in ms] == [K("Hugo"), K("Lee")], ms
    w.assert_no_errors()


@case
def late_login_catches_up():
    w, c = world(names())
    bob, hugo = c["Bob"], c["Hugo"]
    hugo.logout()
    w.tick(2)
    sid = save_council(bob)
    occ = create(bob, i="bt", t=now(bob) + DAY)
    fill(bob, occ, BOSS, sid, {"tk.1.1": K("Lee")})
    w.tick(2)
    bob.logout()
    w.tick(2)
    mark = len(w.addon_log)
    hugo.login()
    w.tick(40)
    assert [s["id"] for s in strategies(hugo)] == [sid]
    assert get_fill(hugo, occ, BOSS)["a"] == {"tk.1.1": K("Lee")}
    h = [m for m in lr.msgs_of_type(w, "H", mark) if m["_sender"] == K("Hugo")]
    assert h and isinstance(h[0]["sd"], str), h
    sbd = [m for m in lr.msgs_of_type(w, "SBD", mark) if m["to"] == K("Hugo")]
    assert len(sbd) == 1, sbd
    hashes = {n: x.eval("return ns.Strategy:GetDigestHash()") for n, x in c.items() if x.online}
    assert len(set(hashes.values())) == 1, hashes
    w.assert_no_errors()


@case
def old_fills_and_tombstones_are_pruned():
    w, c = world(names())
    bob = c["Bob"]
    sid = save_council(bob)
    occ = create(bob, i="bt", t=now(bob) + DAY)
    fill(bob, occ, BOSS, sid, {"tk.1.1": K("Lee")})
    sid2 = save_council(bob, "Old")
    bob.eval("return ns.Strategy:DeleteStrategy(...)", sid2)
    w.tick(2)
    later = now(bob) + 60 * DAY
    bob.eval("ns.Strategy:Prune(...)", later)
    root = "ns.db.strategy['%s']" % GUILD_KEY
    assert bob.eval("local n = 0; for _ in pairs(%s.F) do n = n + 1 end; return n" % root) == 0
    # 1.4.1: past its 30 days in the digest the deletion is a grave (kept, out of the digest) for a year
    assert bob.eval("return %s.B[...].del" % root, sid2) is True
    # the last fill survives for carry over
    assert bob.eval_py("return (ns.Strategy:GetLastFill(...))", sid, "other") == {"tk.1.1": K("Lee")}
    bob.eval("ns.Strategy:Prune(...)", now(bob) + 370 * DAY)
    assert bob.eval("return %s.B[...]" % root, sid2) is None
    w.assert_no_errors()


# A strategy of nPages pages with nElems texts each on the map; random: words nobody repeats (packs ~1.6:1), else
# near-equal lines (pack ~24:1, past the receivers' 16:1 inflate ratio). Saved by that client: { ok, r }.
TEXTS = r"""
local src, name, nPages, nElems, random = ...
local d = (loadstring(src))()
d.n, d.p = name, {}
local x = 7
local function word()
    local t = {}
    for i = 1, 5 do x = x * 16807 % 2147483647; t[i] = string.char(97 + x % 26) end
    return table.concat(t)
end
for i = 1, nPages do
    local e = {}
    for j = 1, nElems do
        local l
        if random then
            local w = {}
            for k = 1, 26 do w[k] = word() end
            l = table.concat(w, ' '):sub(1, 158)
        else
            l = ('Line %d of page %d: everyone stack here behind the boss\nthen move left when the fire comes\nand kick'
                 .. ' every cast'):format(j, i)
        end
        e[j] = { t = 'x', x = 10 + j * 7, y = 20 + (j % 9) * 50, l = l, z = 14 }
    end
    d.p[i] = { id = 'p' .. i, n = 'P' .. i, m = 0, e = e, k = {} }
end
local ok, r = ns.Strategy:SaveStrategy(d)
return { ok = ok, r = r }
"""

RATIO = ("local r = ns.Strategy:GetStrategy(...); local LS, LD = LibStub('LibSerialize'), LibStub('LibDeflate'); "
         "local s = LS:Serialize({ t = 'SBU', k = 'B', r = r }); return { ser = #s, ratio = #s / #LD:CompressDeflate(s) }")


@case
def a_members_big_strategy_reaches_everyone():
    """Everyone builds strategies (user rule 2026-10-04): a member's may be as large as a council member's message
    (the member caps were 16 KB inflated: the sender was ignored for the session, later messages too)."""
    w, c = world(names())
    sam = c["Sam"]
    assert sam.eval("return ns.Guild:IsRaidLogMember(ns.Util.PlayerKey())") is False     # a plain member
    others = [x for n, x in c.items() if n != "Sam"]
    dropped = {x.name: x.eval("return ns.Comm.stats.dropped") for x in others}
    big = sam.eval_py(TEXTS, COUNCIL, "Big", 6, 80, False)
    assert big["ok"] is True, big
    size = sam.eval_py(RATIO, big["r"])
    assert size["ser"] > 60000 and size["ratio"] > 20, size        # (packed past 16:1: Comm pads it)
    w.tick(30)
    for x in others:
        s = x.eval_py("return ns.Strategy:GetStrategy(...)", big["r"])
        assert s and len(s["p"]) == 6 and all(len(p["e"]) == 80 for p in s["p"]), x.name
    # his next one arrives too: nobody ignores him
    small = sam.eval_py("local d = (loadstring(...))(); d.n = 'Small'; local ok, r = ns.Strategy:SaveStrategy(d); "
                        "return { ok = ok, r = r }", COUNCIL)
    assert small["ok"] is True
    w.tick(5)
    for x in others:
        assert x.eval("return ns.Strategy:GetStrategy(...) ~= nil", small["r"]) is True, x.name
        assert x.eval("return ns.Comm.stats.dropped") == dropped[x.name], x.name
    # one too big for anyone to take is refused when saved, with a message: nothing is dropped unseen
    n0 = len(strategies(sam))
    res = sam.eval_py(TEXTS, COUNCIL, "Huge", 6, 80, True)
    assert res["ok"] is False and "too big to send to the guild" in res["r"], res
    assert len(strategies(sam)) == n0
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
