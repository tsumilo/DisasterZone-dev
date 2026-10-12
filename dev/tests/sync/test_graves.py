"""Deletions outlive their time in the digest (1.4.1, Core/DigestSync.lua "Graves"): a deleted library event (and its
review), poll, prized item or strategy is no longer brought back by a member who was away longer than its tombstone
was in the digest (30 days; prized items 60).

Each case follows tests/raidplan/test_raidplan_edges.py's pruned-deletion case: a member logs out holding the record,
it is deleted, the server clock moves past the horizon, everyone online prunes, the member logs back in.
  events_polls_strategies_away_45_days   the returning member gives its live copies; they are refused and the
                                         deletions go back to it (XXG); every digest hash ends equal, and a later
                                         login sends no digest at all
  prized_away_70_days                    the same for a prized item (60 days in the digest)
  a_returning_member_who_answers_gets_the_deletion   the member comes back while nobody is online, and answers the
                                         next login with its digest: the newcomer gives the deletion back instead of
                                         asking for the copy (OnDigest)
  graves_stay_out_of_the_digest_and_are_capped      the digest's items and hash ignore graves; Prune drops the
                                         oldest past maxGraves and every one past graveKeep, never a visible deletion
  records_past_their_keep_are_not_taken_back        a relayed calendar event or poll Prune would drop, and a review of
                                         an event deleted long ago, are refused
  a_fresh_install_converges_in_one_round one digest, the same hash, no grave sent
Run: luaenv\\Scripts\\python.exe tests\\sync\\test_graves.py [-k name]   (from dev)"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "strategy"))
sys.path.insert(0, os.path.join(TESTS, "loot-roll"))

from _common import World, Client, case, run_all  # noqa: E402
from st_common import COUNCIL  # noqa: E402
import lr_common as lr  # noqa: E402

DAY = 86400
REALM = "Thunderstrike"
GK = "Casual Disaster-Thunderstrike"
ITEM = 28830                     # Dragonspine Trophy
DIGESTS = ("EVD", "PLD", "PZD", "SBD")
NAMES = (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Uma", 3, "HUNTER"))


def K(n):
    return "%s-%s" % (n, REALM)


def world(names=NAMES):
    w = World()
    c = {}
    for name, rank, cls in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(60)
    return w, c


def write(gina, members, prized=False):
    """Gina (GM) writes a library event she reviews (D + K), a poll closing 60 days on (asking `members`), a strategy
    and (prized) a prized item; plus a second event that stays (so a login has something to sync)."""
    out = gina.eval_py("""
        local members, council, prized, item = ...
        local out = {}
        local d = ns.Events:NewDef(true); d.name = 'Gone cup'
        out.def = ns.Events:SaveDef(d) and d.id or false
        out.rev = out.def and ns.Events:Review(d.id, true) or false
        local keep = ns.Events:NewDef(true); keep.name = 'Kept cup'
        out.keep = ns.Events:SaveDef(keep) and keep.id or false
        local targets = {}
        for i, k in ipairs(members) do targets[i] = { 'p', k } end
        out.poll = ns.Polls:Create({ q = 'Night?', k = 'one', o = { 'Wed', 'Thu' }, a = targets,
                                     cl = GetServerTime() + 60 * 86400 - 60, rv = 'live', ch = true, mx = 0 }) or false
        local s = (loadstring(council))(); s.n = 'Gone plan'
        local ok, sid = ns.Strategy:SaveStrategy(s)
        out.strat = ok and sid or false
        if prized then
            local rec = ns.Prized:Add({ item }, { main = { m = 'r' } })
            out.prized = rec and rec.id or false
        end
        return out""", [K(m) for m in members], COUNCIL, prized, ITEM)
    assert all(v not in (False, None) for v in out.values()), out
    return out


def delete(gina, ids):
    res = gina.eval_py("""
        local ids = ...
        local out = { def = ns.Events:DeleteDef(ids.def) and true or false,
                      poll = ns.Polls:Delete(ids.poll) and true or false,
                      strat = (ns.Strategy:DeleteStrategy(ids.strat)) and true or false }
        if ids.prized then out.prized = ns.Prized:Remove(ids.prized) end
        return out""", ids)
    assert all(v is True for v in res.values()), res


HOLDS = """
    local ids = ...
    local function get(bucket, kind, id)
        local b = ns.db[bucket] and ns.db[bucket]['%s']
        local r = b and b[kind] and id and b[kind][id]
        if not r then return 'none' end
        return r.del and 'del' or 'live'
    end
    return { D = get('events', 'D', ids.def), K = get('events', 'K', ids.def), P = get('polls', 'P', ids.poll),
             B = get('strategy', 'B', ids.strat), I = get('prized', 'I', ids.prized) }""" % GK

HASHES = """
    local function h(m) return m:GetDigestHash() end
    return { ev = h(ns.Events), po = h(ns.Polls), pz = h(ns.Prized), sb = h(ns.Strategy) }"""


def holds(cl, ids):
    return cl.eval_py(HOLDS, ids)


def shown(cl, ids):
    """What the UI reads: is the record there (not deleted)?"""
    return cl.eval_py("""
        local ids = ...
        return { D = ns.Events:GetDef(ids.def) ~= nil, P = ns.Polls:GetPoll(ids.poll) ~= nil and not ns.Polls:GetPoll(ids.poll).del,
                 B = ns.Strategy:GetStrategy(ids.strat) ~= nil,
                 I = ids.prized ~= nil and ns.Prized:Get(ids.prized) ~= nil and not ns.Prized:Get(ids.prized).del }""", ids)


def hashes(cl):
    return cl.eval_py(HASHES)


def digests_to(w, key, mark):
    out = {}
    for t in DIGESTS:
        for m in lr.msgs_of_type(w, t, mark, whole=True):
            if m.get("to") == key:
                out.setdefault(t, set()).add(m["_sender"])
    return out


def away(w, c, who, days, ids):
    """`who` logs out, Gina deletes everything, the clock moves `days` on, everyone online prunes."""
    c[who].logout()
    w.tick(2)
    delete(c["Gina"], ids)
    w.tick(5)
    w.server_time0 += days * DAY
    for x in c.values():
        if x.online:
            x.eval("ns.Events:Prune(); ns.Polls:Prune(); ns.Prized:Prune(); ns.Strategy:Prune()")


def everyone_equal(c, what):
    hs = {n: hashes(x) for n, x in c.items() if x.online}
    assert len({tuple(sorted(h.items())) for h in hs.values()}) == 1, (what, hs)
    return next(iter(hs.values()))


@case
def events_polls_strategies_away_45_days():
    w, c = world()
    gina, uma = c["Gina"], c["Uma"]
    ids = write(gina, ["Lee", "Uma"])
    w.tick(10)
    assert holds(uma, ids) == {"D": "live", "K": "live", "P": "live", "B": "live", "I": "none"}, holds(uma, ids)
    away(w, c, "Uma", 45, ids)
    for n in ("Gina", "Bob", "Lee"):
        # graves: still held, out of the digest; the review went with its event
        assert holds(c[n], ids) == {"D": "del", "K": "none", "P": "del", "B": "del", "I": "none"}, (n, holds(c[n], ids))
        dg = c[n].eval_py("""local ids = ...
            local e, p, s = ns.Events:GetDigest(), ns.Polls:GetDigest(), ns.Strategy:GetDigest()
            return { e['D:' .. ids.def] or false, e['K:' .. ids.def] or false, p['P:' .. ids.poll] or false,
                     s['B:' .. ids.strat] or false }""", ids)
        assert dg == [False, False, False, False], (n, dg)
    mark = len(w.addon_log)
    uma.login()                      # still holds the event, its review, the poll and the strategy
    w.tick(90)
    for n, x in c.items():
        assert shown(x, ids) == {"D": False, "P": False, "B": False, "I": False}, (n, shown(x, ids))
    for n in ("Gina", "Bob", "Lee"):
        assert holds(c[n], ids)["D"] == "del" and holds(c[n], ids)["P"] == "del" and holds(c[n], ids)["B"] == "del", n
    # Uma got the deletions back (XXG from the members she gave her copies to)
    back = {t: [m for m in lr.msgs_of_type(w, t, mark, whole=True) if m["_chat_type"] == "WHISPER"
                and m.get("r", {}).get("del")] for t in ("EVG", "PLG", "SBG")}
    assert all(back[t] for t in back), {t: len(v) for t, v in back.items()}
    h = holds(uma, ids)
    assert h["D"] == "del" and h["P"] == "del" and h["B"] == "del" and h["K"] == "none", h
    everyone_equal(c, "after the return")
    # steady state: a login is not answered with a digest (every hash is the same)
    mark = len(w.addon_log)
    c["Lee"].relog(reload=False)
    w.tick(60)
    assert digests_to(w, K("Lee"), mark) == {}, digests_to(w, K("Lee"), mark)
    w.assert_no_errors()


@case
def prized_away_70_days():
    w, c = world()
    gina, uma = c["Gina"], c["Uma"]
    ids = write(gina, ["Lee", "Uma"], prized=True)
    w.tick(10)
    assert holds(uma, ids)["I"] == "live"
    away(w, c, "Uma", 70, ids)
    assert holds(gina, ids)["I"] == "del"
    assert gina.eval("return ns.Prized:GetDigest()['I:' .. ...] == nil", ids["prized"]) is True
    uma.login()
    w.tick(90)
    for n, x in c.items():
        assert shown(x, ids)["I"] is False, n
    assert holds(uma, ids)["I"] == "del", holds(uma, ids)
    everyone_equal(c, "after the return")
    w.assert_no_errors()


@case
def a_returning_member_who_answers_gets_the_deletion():
    w, c = world()
    gina, lee, uma = c["Gina"], c["Lee"], c["Uma"]
    ids = gina.eval_py("""
        local d = ns.Events:NewDef(true); d.name = 'Gone cup'
        ns.Events:SaveDef(d)
        return { def = d.id }""")
    w.tick(10)
    uma.logout()
    w.tick(2)
    assert gina.eval("return ns.Events:DeleteDef(...)", ids["def"])
    w.tick(5)
    lee.logout()
    w.server_time0 += 45 * DAY
    for x in (gina, c["Bob"]):
        x.eval("ns.Events:Prune()")
        assert x.eval("return ns.Events:GetDigestHash()") == "0"      # only a grave
        x.logout()
    w.tick(2)
    uma.login()                     # alone: nobody answers her HELLO
    w.tick(60)
    assert holds(uma, ids)["D"] == "live"
    mark = len(w.addon_log)
    lee.login()                     # Uma answers Lee's HELLO with her digest; Lee gives the deletion back
    w.tick(60)
    got = digests_to(w, K("Lee"), mark)
    assert got == {"EVD": {K("Uma")}}, got
    wants = [m for m in lr.msgs_of_type(w, "EVW", mark) if m["_sender"] == K("Lee")]
    assert not wants, wants                                             # Lee didn't ask for the live copy
    assert holds(uma, ids)["D"] == "del", holds(uma, ids)
    assert holds(lee, ids)["D"] == "del", holds(lee, ids)
    for x in (lee, uma):
        assert x.eval("return ns.Events:GetDigestHash()") == "0", x.name
    w.assert_no_errors()


@case
def graves_stay_out_of_the_digest_and_are_capped():
    w, c = world((("Gina", 0, "PALADIN"),))
    gina = c["Gina"]
    write(gina, ["Gina"])
    w.tick(2)
    before = gina.eval_py("local n = 0; for _ in pairs(ns.Events:GetDigest()) do n = n + 1 end;"
                          " return { n = n, h = ns.Events:GetDigestHash() }")
    out = gina.eval_py("""
        local root = ns.db.events['%s']
        local now = GetServerTime()
        for i = 1, 310 do
            local id = 'egrave' .. i
            root.D[id] = { id = id, by = 'Gina-Thunderstrike', rev = now - 40 * 86400 - i * 60, at = 0, name = 'x', del = true }
        end
        root.O.ograve = { id = 'ograve', by = 'Gina-Thunderstrike', rev = now - 31 * 86400, del = true }
        root.D.eold = { id = 'eold', by = 'Gina-Thunderstrike', rev = now - 400 * 86400, at = 0, name = 'x', del = true }
        local n = 0; for _ in pairs(ns.Events:GetDigest()) do n = n + 1 end
        local mid = { n = n, h = ns.Events:GetDigestHash() }
        root.D.efresh = { id = 'efresh', by = 'Gina-Thunderstrike', rev = now - 86400, at = 0, name = 'x', del = true }
        local withFresh = ns.Events:GetDigest()['D:efresh'] ~= nil
        ns.Events:Prune()
        local left = 0
        for id, r in pairs(root.D) do if r.del and id ~= 'efresh' then left = left + 1 end end
        for _, r in pairs(root.O) do if r.del then left = left + 1 end end
        return { mid = mid, fresh = withFresh, left = left, old = root.D.eold == nil, kept = root.D.efresh ~= nil,
                 oldest = root.D.egrave310 == nil and root.D.egrave301 == nil, newest = root.D.egrave1 ~= nil,
                 o = root.O.ograve ~= nil }""" % GK)
    assert out["mid"] == before, (out["mid"], before)     # graves change neither the items nor the hash
    assert out["fresh"] is True                          # a deletion within its 30 days is in the digest
    assert out["left"] == 300, out                       # maxGraves (Events: 300), the oldest dropped first
    assert out["old"] and out["kept"] and out["oldest"] and out["newest"] and out["o"], out
    w.assert_no_errors()


@case
def records_past_their_keep_are_not_taken_back():
    """A calendar event Prune drops (60 days after its day), a poll closed for longer than polls are kept (60 days)
    and a review of a library event deleted long ago (a grave) are refused when someone's store relays them (XXG)."""
    w, c = world((("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR")))
    gina, lee = c["Gina"], c["Lee"]
    ids = write(gina, ["Lee"])
    w.tick(5)
    assert gina.eval("return ns.Events:DeleteDef(...)", ids["def"])
    w.tick(3)
    w.server_time0 += 45 * DAY
    gina.eval("ns.Events:Prune()")
    out = lee.eval_py("""
        local def, gk = ...
        local now = GetServerTime()
        local d = ns.EventBlocks:Starter(); d.id = 'eold'; d.by = 'Gina-Thunderstrike'; d.rev = now - 70 * 86400
        local function give(t, k, r) ns.Comm:Send({ t = t, k = k, r = r }, 'WHISPER', 'Gina-Thunderstrike', 'data') end
        give('EVG', 'O', { id = 'oold', by = 'Gina-Thunderstrike', h = 'Gina-Thunderstrike', rev = now - 70 * 86400,
                           def = d, at = now - 61 * 86400 })
        give('EVG', 'O', { id = 'orecent', by = 'Gina-Thunderstrike', h = 'Gina-Thunderstrike', rev = now - 50 * 86400,
                           def = d, at = now - 59 * 86400 })
        give('PLG', 'P', { id = 'pold', by = 'Gina-Thunderstrike', rev = now - 130 * 86400, q = 'Old?', k = 'one',
                           o = { 'a', 'b' }, mx = 0, at = now - 130 * 86400, cl = now - 61 * 86400, rv = 'live',
                           ch = true, a = { { 'p', 'Lee-Thunderstrike' } }, m = { 'Lee-Thunderstrike' } })
        give('EVG', 'K', { id = def, by = 'Gina-Thunderstrike', rev = now - 10, dr = 1, ok = true })
        return true""", ids["def"], GK)
    assert out is True
    w.tick(3)
    got = gina.eval_py("""
        local def = ...
        local e, p = ns.db.events['%s'], ns.db.polls['%s']
        return { oold = e.O.oold ~= nil, orecent = e.O.orecent ~= nil, pold = p.P.pold ~= nil, k = e.K[def] ~= nil,
                 d = e.D[def] and e.D[def].del or false }""" % (GK, GK), ids["def"])
    assert got == {"oold": False, "orecent": True, "pold": False, "k": False, "d": True}, got
    w.assert_no_errors()


@case
def a_fresh_install_converges_in_one_round():
    w, c = world()
    gina = c["Gina"]
    ids = write(gina, ["Lee"], prized=True)
    w.tick(10)
    delete(gina, ids)
    w.tick(5)
    w.server_time0 += 70 * DAY
    for x in c.values():
        x.eval("ns.Events:Prune(); ns.Polls:Prune(); ns.Prized:Prune(); ns.Strategy:Prune()")
    assert gina.eval_py("local s = ...; return ns.Events:GetDef(s)", ids["keep"]) is not None
    mark = len(w.addon_log)
    nia = Client(w, "Nia", guild_rank=3, class_file="DRUID")
    nia.load_addon()
    w.tick(120)
    got = digests_to(w, K("Nia"), mark)
    assert all(len(v) == 1 for v in got.values()) and "EVD" in got, got
    assert hashes(nia) == hashes(gina), (hashes(nia), hashes(gina))
    assert holds(nia, ids) == {"D": "none", "K": "none", "P": "none", "B": "none", "I": "none"}, holds(nia, ids)
    gives = [m for t in ("EVG", "PLG", "PZG", "SBG") for m in lr.msgs_of_type(w, t, mark, whole=True)
             if m.get("r", {}).get("del")]
    assert not gives, gives                              # no grave travels
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
