"""Events edge cases: trust, sync, the calendar, sign-ups, the season and live runs (Core/Events.lua, Core/EventLive.lua).

Each case shows one edge that was wrong (or checks one that was fine) between mock clients: forged records and live
states, accented and long names, deleted results coming back, removing by the GM / officers / guild council,
dismissing and clearing reviews, sign-ups that closed, live events cancelled, moved or taken off the calendar, the
host's /reload, a quiet host taken over by one entrant, states queued behind each other, many watchers, two live events
at once, pauses, offline entrants, invites, tells over the rate, demo mode, retention and the digest's cap.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_edge_live.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all, seed_guild_council  # noqa: E402

HELLO = 50
DAY = 86400
CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]
FIVE = ["Gina", "Bert", "Cora", "Dain", "Eve"]


def K(n):
    return n + "-Thunderstrike"


def guild(names, tick=HELLO, ranks=None, council=None, levels=None, **kw):
    """Clients in one guild: the first is the GM (rank 0), the rest members (rank 3) unless `ranks` says otherwise."""
    w = World(**kw)
    if council:
        seed_guild_council(w, council)
    cs = []
    for i, n in enumerate(names):
        r = ranks[i] if ranks else (0 if i == 0 else 3)
        lv = (levels or {}).get(n, 70)
        cs.append(Client(w, n, guild_rank=r, class_file=CLASSES[i % len(CLASSES)], level=lv))
    for c in cs:
        c.load_addon()
    w.tick(tick)
    return w, cs


def cup(w, host, players, start=True, setup=""):
    """The host saves a starter cup (setup: Lua on `d` first), schedules it, the players sign up, it starts."""
    occ = host.eval("local d = ns.Events:NewDef(true)\n" + setup + "\nassert(ns.Events:SaveDef(d), 'save')\n"
                    "return ns.Events:Schedule(d.id, GetServerTime() + 30)")
    assert occ, "schedule"
    w.tick(3)
    for c in players:
        assert c.eval("return (ns.Events:SignUp(..., true))", occ), c.name
    w.tick(3)
    if start:
        ok = host.eval_py("return { ns.EventLive:Start(...) }", occ)
        assert ok[0] is True, ok
        w.tick(3)
    return occ


def state(c, occ):
    return c.eval_py("local st = ns.EventLive:GetState(...); return st and { phase = st.phase, seq = st.seq, "
                     "host = st.host, n = #st.entrants } or nil", occ)


def playing(c, occ):
    return c.eval_py("""
        local st = ns.EventLive:GetState(...)
        local bk = st and ns.EventEngine:BracketOf(ns.EventLive:GetDef(...), st)
        local out = {}
        if bk then
          for _, mid in ipairs(bk.rounds[bk.r] or {}) do
            local m = bk.m[mid]
            if m.st == "play" then out[#out + 1] = { (m.a:gsub("%-.*", "")), (m.b:gsub("%-.*", "")), m.id } end
          end
        end
        return out""", occ) or []


def games(c, occ, mid):
    return c.eval_py("""
        local occ, mid = ...
        local bk = ns.EventEngine:BracketOf(ns.EventLive:GetDef(occ), ns.EventLive:GetState(occ))
        local m = bk.m[mid]
        return { m.wa, m.wb, m.st }""", occ, mid)


def send(c, msg_lua, dist="GUILD", target=None, cls="data", *args):
    """c sends a raw addon message (a member with a changed addon): msg_lua is a Lua expression of the message."""
    c.eval("local msg = " + msg_lua + "\nns.Comm:Send(msg, '%s', %s, '%s')" % (
        dist, ("'" + target + "'") if target else "nil", cls), *args)


def hosts_of(cs, occ):
    return [c.name for c in cs if c.online and c.runtime is not None and c.eval("return ns.EventLive:IsHostOf(...)", occ)]


def results(c, occ):
    return c.eval_py("local r = ns.Events:GetResult(...); return r and { by = r.by, ranked = r.ranked or false, "
                     "cancel = r.cancel or false } or nil", occ)


def event_msgs(w, since, sender=None):
    return [e for e in w.addon_log[since:] if e["prefix"] in ("CDLe", "CDLf") and (sender is None or e["sender"] == K(sender))]


# ------------------------------------------------------------------------------------------------------------------
# Records: names, deletions, trust
# ------------------------------------------------------------------------------------------------------------------
@case
def accented_and_long_names_sign_up_pick_titles_and_sync():
    # "Zoë" has a letter outside a-z; a 12-letter name on Thunderstrike makes a sign-up id past 40 bytes
    w, cs = guild(["Gina", "Zoë", "Hellscreamba"])
    g, z, hb = cs
    occ = g.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return ns.Events:Schedule(d.id, GetServerTime() + 3600)")
    w.tick(3)
    assert z.eval("return (ns.Events:SignUp(...))", occ, True) is True
    assert hb.eval("return (ns.Events:SignUp(...))", occ, True) is True
    assert z.eval("return ns.Events:SetTitle('')") is True
    w.tick(3)
    assert g.eval_py("return ns.Events:GetSignups(...)", occ) == [K("Gina"), K("Hellscreamba"), K("Zoë")]
    # a member who comes later gets them through the digest (its items are longer than an id)
    late = Client(w, "Late", guild_rank=3)
    late.load_addon()
    w.tick(HELLO + 30)
    assert late.eval_py("return ns.Events:GetSignups(...)", occ) == [K("Gina"), K("Hellscreamba"), K("Zoë")]
    assert late.eval("return ns.Events:GetDigestHash()") == g.eval("return ns.Events:GetDigestHash()")
    w.assert_no_errors()


def _plant_result(cs, occ_id, by="Gina"):
    """Every client holds a finished ranked result (and its calendar event) of `by`, as if synced long ago."""
    for c in cs:
        c.eval("""
            local id, by = ...
            ns.Events:SetTitle('')   -- (makes the guild's store)
            local root = ns.db.events[ns.Guild:GetGuildKey()]
            local now = GetServerTime()
            root.O[id] = { id = id, by = by, h = by, rev = now - 7200, def = ns.EventBlocks:Starter(), at = now - 7200,
              ranked = true }
            root.R[id] = { id = id, by = by, rev = now - 3600, name = 'Cup', at = now - 7000, t1 = now - 3600, ranked = true,
              n = 4, champ = 'Bert-Thunderstrike', points = { ['Bert-Thunderstrike'] = 50 }, badges = {}, moments = {},
              last4 = {}, hosts = { by }, nums = {}, mw = {} }""", occ_id, K(by))


@case
def a_deleted_result_stays_deleted():
    w, cs = guild(["Gina", "Bert", "Cora"])
    g, b, c = cs
    _plant_result(cs, "oplanted1")
    c.logout()   # Cora still has it
    assert g.eval("return ns.Events:DeleteResult('oplanted1')")
    w.tick(3)
    for x in (g, b):
        x.eval("ns.Events:Prune()")   # (the daily prune ran: before, it forgot the deletion at once)
        assert x.eval("return ns.Events:GetResult('oplanted1') == nil")
    c.login()
    w.tick(HELLO + 40)
    for x in cs:
        assert x.eval("return ns.Events:GetResult('oplanted1') == nil"), x.name
    assert b.eval("return #ns.Events:Standings()") == 0
    w.assert_no_errors()


@case
def members_cant_forge_ranked_events_or_results():
    w, cs = guild(["Gina", "Bert", "Cora"])
    g, b, c = cs
    me = "ns.Util.PlayerKey()"
    # a ranked library event (the GM ranks it): anyone may put it on the calendar, ranked
    did = g.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return d.id")
    w.tick(2)
    assert g.eval("return ns.Events:Review(..., true)", did)
    w.tick(2)
    occ_ok = c.eval("return ns.Events:Schedule(..., GetServerTime() + 600)", did)
    w.tick(2)
    assert g.eval("return ns.Events:GetOcc(...).ranked", occ_ok) is True
    # Bert's own event, not reviewed: a calendar entry he marks ranked himself is refused
    bd = b.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return d.id")
    w.tick(2)
    send(b, """(function() local d = ns.Events:GetDef('%s')
        return { t = 'EVU', k = 'O', r = { id = 'oforged1', by = %s, h = %s, rev = GetServerTime(), def = ns.EventBlocks.Copy(d),
          dk = d.id, dr = d.rev, at = GetServerTime() + 60, ranked = true } } end)()""" % (bd, me, me))
    # nor one with the ranked event's name on his own pieces
    send(b, """(function() local d = ns.EventBlocks.Copy(ns.Events:GetDef('%s')); local r = ns.Events:GetDef('%s')
        return { t = 'EVU', k = 'O', r = { id = 'oforged2', by = %s, h = %s, rev = GetServerTime(), def = d, dk = r.id,
          dr = r.rev, at = GetServerTime() + 60, ranked = true } } end)()""" % (bd, did, me, me))
    # a ranked result of no calendar event, with 1000 points for himself
    send(b, """{ t = 'EVU', k = 'R', r = { id = 'rforged1', by = %s, rev = GetServerTime(), name = 'Cup',
        at = GetServerTime() - 60, t1 = GetServerTime(), ranked = true, n = 8, points = { [%s] = 1000 }, badges = {},
        moments = {}, last4 = {}, hosts = { %s }, nums = {} } }""" % (me, me, me))
    w.tick(3)
    for x in (g, c):
        assert x.eval("return ns.Events:GetOcc('oforged1') == nil and ns.Events:GetOcc('oforged2') == nil"), x.name
        assert x.eval("return ns.Events:GetResult('rforged1') == nil"), x.name
        assert x.eval("return #ns.Events:Standings()") == 0, x.name
    # an unranked event of Gina's: Bert claims he took it over and writes a result first (unranked: taken at his
    # word), then Gina's own result comes in and wins, however old; his later one doesn't replace hers
    occ = g.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return ns.Events:Schedule(d.id, GetServerTime() + 60)")
    w.tick(2)
    fake = """{ t = 'EVU', k = 'R', r = { id = '%s', by = %s, rev = GetServerTime() + %d, name = 'Cup', at = GetServerTime(),
        t1 = GetServerTime(), ranked = %s, n = 4, points = {}, badges = {}, moments = {}, last4 = {},
        hosts = { 'Gina-Thunderstrike', %s }, nums = {} } }"""
    send(b, fake % (occ, me, 0, "true", me))   # ranked: the calendar event isn't
    w.tick(2)
    assert g.eval("return ns.Events:GetResult(...) == nil", occ)
    send(b, fake % (occ, me, 0, "nil", me))
    w.tick(2)
    assert results(c, occ)["by"] == K("Bert")
    g.eval("""local occ = ...
        local root = ns.db.events[ns.Guild:GetGuildKey()]
        ns.Comm:Send({ t = 'EVU', k = 'R', r = { id = occ, by = ns.Util.PlayerKey(), rev = GetServerTime() - 30, name = 'Cup',
          at = GetServerTime(), t1 = GetServerTime(), n = 4, points = {}, badges = {}, moments = {}, last4 = {},
          hosts = { ns.Util.PlayerKey() }, nums = {} } }, 'GUILD', nil, 'data')""", occ)
    w.tick(2)
    assert results(c, occ)["by"] == K("Gina")
    send(b, fake % (occ, me, 50, "nil", me))
    w.tick(2)
    assert results(c, occ)["by"] == K("Gina")
    w.assert_no_errors()


@case
def removing_is_for_the_gm_officers_and_the_guild_council():
    # Gina GM, Olaf an officer, Cleo on the guild council, Bert and Mia members
    w, cs = guild(["Gina", "Olaf", "Cleo", "Bert", "Mia"], ranks=[0, 1, 3, 3, 3], council=["Cleo"])
    g, o, cl, b, m = cs
    assert [x.eval("return ns.Events:CanRemove(ns.Util.PlayerKey())") for x in cs] == [True, True, True, False, False]
    # Mia's event in the library, sent in for review; Bert's calendar event
    mid = m.eval("local d = ns.Events:NewDef(true); d.name = 'Mia cup'; ns.Events:SaveDef(d); return d.id")
    w.tick(2)
    assert m.eval("return ns.Events:SubmitForReview(..., 'please')", mid)
    bd = b.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return d.id")
    w.tick(2)
    occ = b.eval("return ns.Events:Schedule(..., GetServerTime() + 7200)", bd)
    w.tick(2)
    # a member's removal of someone else's is refused (here and when forged on the wire)
    assert b.eval("return ns.Events:DeleteDef(...)", mid) is False
    send(b, "{ t = 'EVU', k = 'D', r = { id = '%s', by = ns.Util.PlayerKey(), name = 'x', del = true, rev = GetServerTime() } }" % mid)
    send(b, "{ t = 'EVU', k = 'K', r = { id = '%s', by = ns.Util.PlayerKey(), rev = GetServerTime(), dr = 0, x = 1 } }" % mid)
    w.tick(2)
    assert g.eval("return ns.Events:ReviewState(ns.Events:GetDef(...))", mid) == "review"
    # the guild council takes it out of the waiting list without deciding: a draft again, out of the queue
    assert cl.eval("return ns.Events:DismissReview(...)", mid)
    w.tick(2)
    for x in cs:
        assert x.eval("return ns.Events:ReviewState(ns.Events:GetDef(...))", mid) == "draft", x.name
        assert x.eval("return #ns.Events:GetReviewQueue()") == 0, x.name
    # Mia sends it in again: waiting again; the officer ranks it, then clears it from the decided list: still ranked
    assert m.eval("return ns.Events:SubmitForReview(..., 'again')", mid)
    w.tick(2)
    assert g.eval("return #ns.Events:GetReviewQueue()") == 1
    assert o.eval("return ns.Events:Review(..., true)", mid)
    w.tick(2)
    assert g.eval("return #ns.Events:GetDecided()") == 1
    assert cl.eval("return ns.Events:HideDecision(...)", mid)
    w.tick(2)
    for x in cs:
        assert x.eval("return #ns.Events:GetDecided()") == 0, x.name
        assert x.eval("return ns.Events:ReviewState(ns.Events:GetDef(...))", mid) == "ranked", x.name
    # a later decision is a fresh one, shown again
    m.eval("local d = ns.EventBlocks.Copy(ns.Events:GetDef(...)); d.name = 'Mia cup 2'; ns.Events:SaveDef(d)", mid)
    w.tick(2)
    m.eval("ns.Events:SubmitForReview(...)", mid)
    w.tick(2)
    assert g.eval("return ns.Events:Review(..., false, 'too long')", mid)
    w.tick(2)
    assert b.eval("return #ns.Events:GetDecided()") == 1
    # the council member removes Mia's event, cancels and then removes Bert's calendar event
    assert cl.eval("return ns.Events:CancelOcc(..., 'No room')", occ)
    w.tick(2)
    assert b.eval("return ns.Events:GetOcc(...).cancel", occ) == "No room"
    assert cl.eval("return ns.Events:DeleteOcc(...)", occ)
    assert cl.eval("return ns.Events:DeleteDef(...)", mid)
    w.tick(2)
    for x in cs:
        assert x.eval("return ns.Events:GetOcc(...) == nil and ns.Events:GetDef(...) == nil", occ, mid), x.name
    # and a result
    _plant_result(cs, "oplanted2", by="Bert")
    assert m.eval("return ns.Events:DeleteResult('oplanted2')") is False
    assert cl.eval("return ns.Events:DeleteResult('oplanted2')")
    w.tick(2)
    for x in cs:
        assert x.eval("return ns.Events:GetResult('oplanted2') == nil and ns.Events:GetOcc('oplanted2') == nil"), x.name
    # the season stays with the GM and the officers
    assert cl.eval("return ns.Events:SetSeason('Cleo season', GetServerTime() - 10, GetServerTime() + 99999)") is False
    send(cl, "{ t = 'EVU', k = 'C', r = { id = 'season', by = ns.Util.PlayerKey(), rev = GetServerTime(), n = 'Mine', "
             "from = GetServerTime() - 10, to = GetServerTime() + 99999 } }")
    w.tick(2)
    assert g.eval("return ns.Events:GetSeason().set") is None
    # demo mode: removing changes the demo's data only
    n0 = len(w.addon_log)
    out = m.eval_py("""ns.Demo:SetEnabled(true)
        local ok = ns.Events:DismissReview('edemo3')
        local okH = ns.Events:HideDecision('edemo1')
        local okD = ns.Events:DeleteDef('edemo4')
        local decided = #ns.Events:GetDecided()
        local st = ns.Events:ReviewState(ns.Events:GetDef('edemo3'))
        local d = ns.Events:NewDef(true); d.name = '|cffff0000Red|r cup'; ns.Events:SaveDef(d)
        local name = ns.Events:GetDef(d.id).name
        ns.Demo:SetEnabled(false)
        return { ok, okH, okD, decided, st, ns.Events:GetDef('edemo4') == nil, name, ns.Events:GetDef(d.id) == nil }""")
    assert out == [True, True, True, 1, "draft", True, "cffff0000Redr cup", True], out
    assert not [e for e in w.addon_log[n0:] if e["sender"] == K("Mia") and e["prefix"] == "CDLd"]
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The calendar and sign-ups
# ------------------------------------------------------------------------------------------------------------------
@case
def sign_ups_refuse_cancelled_closed_full_and_low_level():
    w, cs = guild(["Gina", "Bert", "Cora", "Lowbie"], levels={"Lowbie": 62})
    g, b, c, lo = cs
    # sign-up closes 15 minutes before the start: the event starts in 10 minutes
    occ = g.eval("""local d = ns.Events:NewDef(true); d.blocks.b1.set.closes = 'early'; ns.Events:SaveDef(d)
        return ns.Events:Schedule(d.id, GetServerTime() + 600)""")
    w.tick(6)
    assert b.eval_py("return { ns.Events:SignUp(..., true) }", occ) == [False, "Sign-up is closed."]
    # a level 62 character can't sign up for a level 70 event
    occ2 = g.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return ns.Events:Schedule(d.id, GetServerTime() + 3600)")
    w.tick(6)
    got = lo.eval_py("return { ns.Events:SignUp(..., true) }", occ2)
    assert got == [False, "This one is for level 70 characters."], got
    assert c.eval("return (ns.Events:SignUp(..., true))", occ2) is True
    # nor for a cancelled one (leaving is always fine)
    assert g.eval("return ns.Events:CancelOcc(..., 'Rain')", occ2)
    w.tick(6)
    assert b.eval_py("return { ns.Events:SignUp(..., true) }", occ2) == [False, "That event was cancelled."]
    assert c.eval("return (ns.Events:SignUp(..., false))", occ2) is True
    # a full one is full (two spots: Gina and Cora)
    occ4 = g.eval("""local d = ns.Events:NewDef(true); d.blocks.b1.set.spots = 2; ns.Events:SaveDef(d)
        return ns.Events:Schedule(d.id, GetServerTime() + 3600)""")
    w.run_until(lambda: b.eval("return ns.Events:IsSignedUp(..., 'Gina-Thunderstrike')", occ4), timeout=60)
    w.run_until(lambda: c.eval("return ns.Events:GetOcc(...) ~= nil", occ4), timeout=60)
    assert c.eval("return (ns.Events:SignUp(..., true))", occ4) is True
    w.run_until(lambda: b.eval("return ns.Events:IsSignedUp(..., 'Cora-Thunderstrike')", occ4), timeout=60)
    assert b.eval_py("return { ns.Events:SignUp(..., true) }", occ4) == [False, "It's full."]
    # two sign-ups in the same second: the same order everywhere (first come, then by name)
    occ3 = g.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return ns.Events:Schedule(d.id, GetServerTime() + 3600, { noJoin = true })")
    w.run_until(lambda: all(x.eval("return ns.Events:GetOcc(...) ~= nil", occ3) for x in cs), timeout=90)
    c.eval("ns.Events:SignUp(..., true)", occ3)
    b.eval("ns.Events:SignUp(..., true)", occ3)
    w.run_until(lambda: all(len(x.eval_py("return ns.Events:GetSignups(...)", occ3) or []) == 2 for x in cs), timeout=90)
    assert [x.eval_py("return ns.Events:GetSignups(...)", occ3) for x in cs] == [[K("Bert"), K("Cora")]] * 4
    # a level 62 sign-up from an older client is left out when the host starts
    lo.eval("""local occ = ...
        local me = ns.Util.PlayerKey()
        ns.Comm:Send({ t = 'EVU', k = 'J', r = { id = occ .. '/' .. me, by = me, rev = GetServerTime(), o = occ, on = true,
          at = GetServerTime() } }, 'GUILD', nil, 'data')""", occ3)
    w.tick(3)
    assert K("Lowbie") in g.eval_py("return ns.Events:GetSignups(...)", occ3)
    g.eval("ns.Events:SignUp(..., true)", occ3)
    w.tick(1)
    assert g.eval("return (ns.EventLive:Start(...))", occ3)
    w.tick(2)
    assert K("Lowbie") not in g.eval_py("return ns.EventLive:GetState(...).entrants", occ3)
    w.assert_no_errors()


@case
def a_live_event_cant_be_moved_and_cancelling_or_removing_stops_it():
    w, cs = guild(FIVE, ranks=[0, 3, 3, 1, 3])   # Dain is an officer
    g, b, c, d, e = cs
    occ = cup(w, g, [b, c, e])
    assert g.eval("return ns.Events:EditOcc(..., GetServerTime() + 86400)", occ) is False
    # an officer cancels it while it runs: the host's run ends as cancelled, its result says so
    assert d.eval("return ns.Events:CancelOcc(..., 'Server restart')", occ)
    w.tick(5)
    assert state(g, occ)["phase"] == "cancelled"
    assert state(b, occ)["phase"] == "cancelled"
    assert results(e, occ) == {"by": K("Gina"), "ranked": False, "cancel": "Server restart"}
    # another one taken off the calendar while it runs: it stops, keeps no result, and isn't live for anyone
    occ2 = cup(w, g, [b, c, e])
    assert d.eval("return ns.Events:DeleteOcc(...)", occ2)
    w.tick(5)
    assert state(g, occ2)["phase"] == "cancelled"
    for x in cs:
        assert occ2 not in (x.eval_py("return ns.EventLive:GetLiveList()") or []), x.name
        assert x.eval("return ns.Events:GetResult(...) == nil", occ2), x.name
    # (the library event it was made of can go too: the calendar keeps its own copy)
    occ3 = cup(w, g, [b, c, e], start=False)
    g.eval("ns.Events:DeleteDef(ns.Events:GetOcc(...).dk)", occ3)
    w.tick(2)
    assert g.eval("return (ns.EventLive:Start(...))", occ3) is True
    w.assert_no_errors()


@case
def a_sign_up_heard_by_the_host_joins_the_run():
    w, cs = guild(FIVE)
    g, b, c, d, e = cs
    occ = cup(w, g, [b, c, e], setup="d.blocks.b1.set.closes = 'host'; d.blocks.b2.stage = 's3'; "
              "d.stages[3] = { id = 's3', name = 'Later' }")
    # Dain doesn't know who hosts it yet (no state heard): his sign-up still reaches the run
    d.eval("local hosting, seen = ns.EventLive:_State(); seen[...] = nil", occ)
    assert d.eval("return (ns.Events:SignUp(..., true))", occ)
    w.tick(3)
    assert K("Dain") in g.eval_py("return ns.EventLive:GetState(...).entrants", occ)
    # the host can't add a player once the bracket is set, and says why
    occ2 = cup(w, g, [b, c, e])
    assert g.eval_py("return { ns.EventLive:AddPlayer(..., 'Dain-Thunderstrike') }", occ2) == [
        False, "Sign-ups are closed: the bracket is set."]
    assert g.eval_py("return { ns.EventLive:AddPlayer(..., 'Bert-Thunderstrike') }", occ2) == [False, "They're in it already."]
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Season, standings, titles, text
# ------------------------------------------------------------------------------------------------------------------
@case
def season_boundaries_ties_and_lost_titles():
    w, cs = guild(["Gina", "Bert"], tick=5)
    g, b = cs
    out = g.eval_py("""
        local s = ns.Events:GetSeason()
        ns.Events:SetTitle('')
        local root = ns.db.events[ns.Guild:GetGuildKey()]
        local function res(id, at, pts, mw, badge)
          root.R[id] = { id = id, by = 'Gina-Thunderstrike', rev = at, name = id, at = at, t1 = at, ranked = true, n = 4,
            points = pts, badges = badge and { { p = 'Bert-Thunderstrike', n = 'Champ', f = 'gold', ti = 'the Bold' } } or {},
            moments = {}, last4 = {}, hosts = {}, nums = {}, mw = mw or {} }
        end
        -- the season's last second counts, the next one is the next season's
        res('rlast', s.to, { ['Bert-Thunderstrike'] = 10, ['Cora-Thunderstrike'] = 10 }, { ['Cora-Thunderstrike'] = 1 }, true)
        res('rnext', s.to + 1, { ['Bert-Thunderstrike'] = 500 })
        res('rfirst', s.from, { ['Dain-Thunderstrike'] = 10 })
        local rows = {}
        for _, r in ipairs(ns.Events:Standings(s)) do rows[#rows + 1] = { r.key, r.pts, r.wins, r.rank } end
        local t1 = ns.Events:GetTitle('Bert-Thunderstrike')
        root.R.rlast = nil
        local t2 = ns.Events:GetTitle('Bert-Thunderstrike')
        return { rows = rows, t1 = t1, t2 = t2 or false, before = ns.Events:GetSeason().n }""")
    # ties: more match wins first (Cora); the same points and wins share a rank (listed by name)
    assert out["rows"] == [[K("Cora"), 10, 1, 1], [K("Bert"), 10, 0, 2], [K("Dain"), 10, 0, 2]], out
    assert out["t1"] == "the Bold" and out["t2"] is False, out
    # a member can't set the season
    assert b.eval("return ns.Events:SetSeason('Mine', 1, 2)") is False
    w.assert_no_errors()


@case
def texts_are_cut_between_letters_and_notes_keep_lines():
    w, cs = guild(["Gina"], tick=3)
    g = cs[0]
    out = g.eval_py("""
        local d = ns.Events:NewDef(true)
        d.name = string.rep('a', 39) .. 'é' .. 'zz'     -- 'é' is two bytes: bytes 40 and 41
        d.notes = { { st = '*', x = 0, y = 0, text = 'Seekers count to 60.\\r\\nThen go!|r\\7' } }
        local c = ns.Events:CleanDef(d)
        return { #c.name, c.name:byte(#c.name), c.notes[1].text }""")
    # (a note keeps its line breaks, not the rest)
    assert out == [39, ord("a"), "Seekers count to 60.\nThen go!r"], out
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Retention and the digest
# ------------------------------------------------------------------------------------------------------------------
@case
def old_sign_ups_and_reviews_go_and_the_digest_keeps_results():
    w, cs = guild(["Gina"], tick=3)
    g = cs[0]
    out = g.eval_py("""
        ns.Events:SetTitle('')
        local root = ns.db.events[ns.Guild:GetGuildKey()]
        local now = GetServerTime()
        -- an event 10 days ago with a sign-up, one tomorrow with one; a review of an event gone from the library
        root.O.oold1 = { id = 'oold1', by = 'Gina-Thunderstrike', h = 'Gina-Thunderstrike', rev = now, def = {}, at = now - 10 * 86400 }
        root.O.onew1 = { id = 'onew1', by = 'Gina-Thunderstrike', h = 'Gina-Thunderstrike', rev = now, def = {}, at = now + 86400 }
        root.J['oold1/Bert-Thunderstrike'] = { id = 'oold1/Bert-Thunderstrike', by = 'Bert-Thunderstrike', rev = now, o = 'oold1', on = true, at = now }
        root.J['onew1/Bert-Thunderstrike'] = { id = 'onew1/Bert-Thunderstrike', by = 'Bert-Thunderstrike', rev = now, o = 'onew1', on = true, at = now }
        root.K.egone = { id = 'egone', by = 'Gina-Thunderstrike', rev = now, dr = 1, ok = true }
        ns.Events:Prune()
        local kept = { root.J['oold1/Bert-Thunderstrike'] == nil, root.J['onew1/Bert-Thunderstrike'] ~= nil, root.K.egone == nil }
        -- past the digest's cap, sign-ups are left out before results
        for i = 1, 1300 do
          local id = 'onew1/M' .. i .. '-Thunderstrike'
          root.J[id] = { id = id, by = 'M' .. i .. '-Thunderstrike', rev = now, o = 'onew1', on = true, at = now }
        end
        root.R.rkeep = { id = 'rkeep', by = 'Gina-Thunderstrike', rev = now, at = now }
        local dg = ns.Events:GetDigest()
        return { kept = kept, r = dg['R:rkeep'] ~= nil, t = dg['T:Gina-Thunderstrike'] ~= nil }""")
    assert out == {"kept": [True, True, True], "r": True, "t": True}, out
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Live: who may host
# ------------------------------------------------------------------------------------------------------------------
STATE_AS = """(function(occ, seqUp, chain)
    local st = ns.EventBlocks.Copy(ns.EventLive:GetState(occ))
    st.seq = st.seq + seqUp; st.host = ns.Util.PlayerKey()
    return { t = 'EVS', o = occ, h = ns.Util.PlayerKey(), s = st, c = chain }
end)(...)"""


@case
def nobody_hijacks_a_live_event():
    w, cs = guild(FIVE)
    g, b, c, d, e = cs
    occ = cup(w, g, [b, c, e])
    # Dain (not in it) and then Cora (in it) send a newer state naming themselves host, while Gina is there
    for x in (d, c):
        x.eval("local msg = " + STATE_AS + "\nns.Comm:Send(msg, 'GUILD', nil, 'event')", occ, 100,
               [K("Gina"), x.full_name])
        w.tick(3)
        assert hosts_of(cs, occ) == ["Gina"], x.name
        for y in cs:
            assert state(y, occ)["host"] == K("Gina"), (x.name, y.name)
    # a state for an event nobody knows, or for the practice run
    c.eval("local st = ns.EventBlocks.Copy(ns.EventLive:GetState(...)); st.seq = 5\n"
           "ns.Comm:Send({ t = 'EVS', o = 'onope1', h = ns.Util.PlayerKey(), s = st, c = {} }, 'GUILD', nil, 'event')\n"
           "ns.Comm:Send({ t = 'EVS', o = 'practice', h = ns.Util.PlayerKey(), s = st, c = {} }, 'GUILD', nil, 'event')", occ)
    w.tick(2)
    assert d.eval_py("return ns.EventLive:GetLiveList()") == [occ]
    assert d.eval("return ns.EventLive:GetState('practice') == nil")
    # a report of a duel that isn't the sender's, an answer to someone else's ask, ready from outside: nothing
    a, bb, mid = [m for m in playing(g, occ) if "Gina" not in m[:2]][0]
    d.eval("ns.Comm:Send({ t = 'EVF', o = ..., k = 'duel', w = select(2, ...), l = select(3, ...), at = GetServerTime() }, "
           "'WHISPER', 'Gina-Thunderstrike', 'event')", occ, K(a), K(bb))
    d.eval("ns.Comm:Send({ t = 'EVF', o = ..., k = 'ready' }, 'WHISPER', 'Gina-Thunderstrike', 'event')", occ)
    w.tick(12)
    assert games(g, occ, mid)[:2] == [0, 0]
    assert K("Dain") not in (g.eval_py("return ns.EventLive:GetState(...).ready", occ) or {})
    w.assert_no_errors()


@case
def the_host_reloads_and_goes_on():
    w, cs = guild(["Gina", "Bert", "Cora", "Eve"])
    g, b, c, e = cs
    occ = cup(w, g, [b, c, e])
    seq = state(b, occ)["seq"]
    g.relog()
    w.tick(8)
    assert g.eval("return ns.EventLive:IsHostOf(...)", occ)
    assert state(b, occ)["host"] == K("Gina") and state(b, occ)["seq"] > seq
    w.tick(150)
    assert hosts_of(cs, occ) == ["Gina"]
    # it goes on: a loser's report counts on Gina's run
    a, bb, mid = playing(g, occ)[-1]
    by = {x.name: x for x in cs}
    by[bb].fire("CHAT_MSG_SYSTEM", "%s has defeated %s in a duel" % (a, bb))
    w.tick(3)
    assert games(g, occ, mid)[:2] == [1, 0]
    # a relog much later doesn't bring the run back (someone took over, or it is over)
    assert g.eval("return ns.db.eventHosting == nil")
    w.assert_no_errors()


@case
def a_quiet_host_online_is_taken_over_by_one_entrant():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain", "Eve"])
    g = cs[0]
    occ = cup(w, g, cs[1:])
    # Gina stays online, but nothing she sends on the event's channel gets through
    w.addon_fault = lambda entry, rc: False if entry["sender"] == K("Gina") and entry["prefix"] == "CDLe" else None
    took = []
    for t in range(130):
        w.tick(1)
        now = hosts_of(cs[1:], occ)
        if now and not took:
            took = now
    w.addon_fault = None
    # one entrant (the first in name order), not every one at the 90 s mark; and Gina gave it to them
    assert took == ["Bert"], took
    assert hosts_of(cs, occ) == ["Bert"]
    for x in cs:
        assert state(x, occ)["host"] == K("Bert"), x.name
    w.assert_no_errors()


@case
def handover_needs_someone_online():
    w, cs = guild(FIVE)
    g, b, c, d, e = cs
    occ = cup(w, g, [b, c, e])
    d.logout()
    w.tick(3)
    assert g.eval_py("return { ns.EventLive:HandOver(..., 'Dain-Thunderstrike') }", occ) == [False, "They're offline."]
    assert g.eval("return ns.EventLive:HandOver(..., 'Cora-Thunderstrike')", occ)
    w.tick(3)
    assert hosts_of([g, b, c, e], occ) == ["Cora"]
    assert state(e, occ)["host"] == K("Cora")
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Live: traffic
# ------------------------------------------------------------------------------------------------------------------
@case
def states_wait_for_the_last_one_to_go_out():
    w, cs = guild(["Gina", "Bert"])
    g, b = cs
    occ = g.eval("""
        local d = ns.Events:NewDef(true); d.blocks.b1.set.spots = 32; ns.Events:SaveDef(d)
        local occ = ns.Events:Schedule(d.id, GetServerTime() + 10)
        local root = ns.db.events[ns.Guild:GetGuildKey()]
        for i = 1, 24 do
          local k = 'Playername' .. i .. '-Thunderstrike'
          root.J[occ .. '/' .. k] = { id = occ .. '/' .. k, by = k, rev = GetServerTime(), o = occ, on = true, at = GetServerTime() + i }
        end
        return occ""")
    w.tick(3)
    g.eval("ns.EventLive:Start(...)", occ)
    worst_lag, worst_backlog = 0, 0
    for step in range(40):
        # a game every 3 s (a busy first round)
        g.eval("""local h = ns.EventLive:_State()[...]
            local bk = h.run:MainBracket()
            for _, mid in ipairs(bk.rounds[bk.r] or {}) do
              local m = bk.m[mid]
              if m.st == "play" then h.run:Duel(m.a, m.b, true); break end
            end""", occ)
        w.tick(3)
        hs = state(g, occ)["seq"]
        bs = (state(b, occ) or {"seq": 0})["seq"]
        worst_lag = max(worst_lag, hs - bs)
        worst_backlog = max(worst_backlog, g.eval("return ns.Comm:Backlog('event')"))
    # before: the watcher fell 10 states (~45 s) behind and 7.6 KB queued up
    assert worst_lag <= 4, worst_lag
    assert worst_backlog <= 2500, worst_backlog
    w.tick(20)
    assert state(b, occ)["seq"] == state(g, occ)["seq"]
    w.assert_no_errors()


@case
def a_full_cup_state_fits_and_ended_runs_are_let_go():
    w, cs = guild(["Gina"], tick=3)
    g = cs[0]
    out = g.eval_py("""
        local d = ns.EventBlocks:Starter(); d.blocks.b1.set.spots = 64
        local names = {}
        for i = 1, 64 do names[i] = 'Longername' .. i .. '-Thunderstrike' end
        local run = ns.EventEngine:New(d, { id = 'o66abcdef1234', host = names[1], signups = names })
        run:Start()
        for i = 1, 30 do run:Moment('Upset: seed ' .. i .. ' knocked out a seed far above them, in a long duel', 'Interface/Icons/INV_Misc_Head_Dragon_01') end
        local fits, wire = ns.Comm:Fits({ t = 'EVS', o = 'o66abcdef1234', h = names[1], s = run:Snapshot(), c = { names[1] } })
        return { fits, wire, #run.st.entrants }""")
    # (a Sign-up takes 40 at most; EVS may be large, 24000 wire bytes: a full cup is far below, a few parts on the wire)
    assert out[0] is True and out[1] < 6000 and out[2] == 40, out
    # a run I hosted that ended: let go of after 10 minutes (the ticker stops)
    w2, cs2 = guild(["Gina", "Bert", "Cora", "Eve"])
    h = cs2[0]
    occ = cup(w2, h, cs2[1:])
    h.eval("ns.EventLive:EndEvent(...)", occ)
    w2.tick(5)
    assert h.eval("return ns.EventLive:IsHostOf(...)", occ)
    w2.tick(620, step=0.5)
    assert h.eval("return ns.EventLive:IsHostOf(...)", occ) is False
    assert results(cs2[1], occ)["by"] == K("Gina")
    w2.assert_no_errors()
    w.assert_no_errors()


@case
def many_watchers_get_one_state():
    names = ["Gina", "Bert", "Cora", "Eve"] + ["W%d" % i for i in range(10)]
    w, cs = guild(names)
    g = cs[0]
    occ = cup(w, g, cs[1:4])
    n0 = len(w.addon_log)
    for c in cs[4:]:
        c.eval("ns.EventLive:Watch(...)", occ)
    w.tick(5)
    sent = event_msgs(w, n0, "Gina")
    whispers = [e for e in sent if e["chat_type"] == "WHISPER"]
    assert not whispers, len(whispers)
    # one whole state on GUILD for all of them (a few parts), not ten
    assert len(sent) <= 12, len(sent)
    for c in cs[4:]:
        assert state(c, occ)["host"] == K("Gina"), c.name
    assert g.eval("return ns.EventLive:GetState(...).watch", occ) == 10
    w.assert_no_errors()


@case
def a_duel_counts_for_the_event_it_is_a_match_of():
    w, cs = guild(FIVE)
    g, b, c, d, e = cs
    by = {x.name: x for x in cs}
    # Bert and Cora are in both events; in the first they play each other, in the second they don't
    occ1 = cup(w, g, [b, c, e], setup="d.blocks.b2.set.seed = 'order'")
    occ2 = cup(w, d, [b, e], start=False, setup="d.blocks.b2.set.seed = 'order'")
    w.tick(2)
    assert c.eval("return (ns.Events:SignUp(..., true))", occ2)
    w.tick(3)
    assert d.eval("return (ns.EventLive:Start(...))", occ2)
    w.tick(3)
    p1, p2 = playing(g, occ1), playing(d, occ2)
    m1 = [m for m in p1 if set(m[:2]) == {"Bert", "Cora"}]
    assert m1 and not [m for m in p2 if set(m[:2]) == {"Bert", "Cora"}], (p1, p2)
    for n in ("Bert", "Cora"):
        by[n].fire("CHAT_MSG_SYSTEM", "Cora has defeated Bert in a duel")
    w.tick(3)
    assert sorted(games(g, occ1, m1[0][2])[:2]) == [0, 1]
    ready2 = d.eval_py("return ns.EventLive:GetState(...).ready", occ2) or {}
    assert K("Bert") not in ready2 and K("Cora") not in ready2, ready2
    w.assert_no_errors()


@case
def an_event_with_no_sign_up_takes_my_group():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain", "Eve"])
    g, b, c, d, e = cs
    occ = g.eval("""local d = ns.Events:NewDef(true); d.blocks.b1 = nil; d.blocks.b2.set.bo = 1; d.blocks.b2.set.fbo = 1
        d.scripts = {}
        assert(ns.Events:SaveDef(d)); return ns.Events:Schedule(d.id, GetServerTime() + 30)""")
    w.tick(4)
    assert e.eval("return (ns.Events:SignUp(..., true))", occ)   # Eve pressed Join, she isn't in the group
    w.make_party([g, b, c, d], leader=g)
    w.tick(4)
    assert g.eval("return (ns.EventLive:Start(...))", occ)
    w.tick(2)
    assert g.eval_py("return ns.EventLive:GetState(...).entrants", occ) == [K("Gina"), K("Eve"), K("Bert"), K("Cora"), K("Dain")]
    w.assert_no_errors()


@case
def pause_holds_waits_and_offline_entrants_are_noticed():
    w, cs = guild(["Gina", "Bert", "Cora", "Eve"])
    g, b, c, e = cs
    occ = cup(w, g, [b, c, e], setup="""table.insert(d.scripts, { id = 'sw', st = 's2', x = 0, y = 600,
        top = { k = 'ev.start', a = {}, n = { k = 'tm.wait', a = { 60 }, n = { k = 'ch.moment', a = { 'waited' } } } } })
        table.insert(d.scripts, { id = 'so', st = '*', x = 0, y = 700,
        top = { k = 'ev.off', a = {}, n = { k = 'ch.moment', a = { 'gone' } } } })""")

    def moments():
        return g.eval_py("local out = {}; for _, m in ipairs(ns.EventLive:GetState(...).moments) do "
                         "out[#out + 1] = m.text end; return out", occ) or []
    w.tick(10)
    g.eval("ns.EventLive:SetPaused(..., true)", occ)
    w.tick(120)
    g.eval("ns.EventLive:SetPaused(..., false)", occ)
    w.tick(5)
    assert moments().count("waited") == 0, moments()
    w.tick(50)
    assert moments().count("waited") == 1, moments()
    # an entrant logs out: the run hears it ("when an entrant goes offline")
    e.logout()
    w.tick(5)
    assert g.eval("return ns.EventLive:GetState(...).off['Eve-Thunderstrike']", occ) is True
    assert "gone" in moments()
    w.assert_no_errors()


@case
def invites_skip_the_group_and_offline_and_turn_into_a_raid():
    names = ["Gina", "Bert", "Cora", "Dain", "Eve", "Finn", "Gus", "Hal"]
    w, cs = guild(names)
    g = cs[0]
    cs[-1].logout()   # Hal is offline
    w.tick(3)
    occ = cup(w, g, cs[1:-1], start=False, setup="""table.insert(d.scripts, { id = 'si', st = '*', x = 0, y = 600,
        top = { k = 'ev.start', a = {}, n = { k = 'wo.inv', a = { { k = 'pl.all', a = {} } } } } })""")
    # Hal signed up before going offline (as an older client would leave it)
    g.eval("""local occ = ...
        local root = ns.db.events[ns.Guild:GetGuildKey()]
        root.J[occ .. '/Hal-Thunderstrike'] = { id = occ .. '/Hal-Thunderstrike', by = 'Hal-Thunderstrike', rev = 1, o = occ,
          on = true, at = GetServerTime() }""", occ)
    w.make_party([g, cs[1]], leader=g)   # Bert is in my group already
    w.tick(2)
    n0 = len(w.invite_log)
    assert g.eval("return (ns.EventLive:Start(...))", occ)
    w.tick(15)
    invited = [x["target"].split("-")[0] for x in w.invite_log[n0:]]
    assert "Bert" not in invited and "Hal" not in invited and "Gina" not in invited, invited
    assert sorted(invited) == ["Cora", "Dain", "Eve", "Finn", "Gus"], invited
    assert g.eval("return IsInRaid()"), "a party past five turns into a raid first"
    assert w.group and len(w.group["members"]) == 7
    w.assert_no_errors()


@case
def invites_from_no_group_fill_a_party_then_a_raid():
    names = ["Gina", "Bert", "Cora", "Dain", "Eve", "Finn", "Gus"]
    w, cs = guild(names)
    g = cs[0]
    occ = cup(w, g, cs[1:], start=False, setup="""table.insert(d.scripts, { id = 'si', st = '*', x = 0, y = 600,
        top = { k = 'ev.start', a = {}, n = { k = 'wo.inv', a = { { k = 'pl.all', a = {} } } } } })""")
    n0 = len(w.invite_log)
    assert g.eval("return (ns.EventLive:Start(...))", occ)
    w.tick(20)
    invited = [x["target"].split("-")[0] for x in w.invite_log[n0:]]
    # four into a party (no more: a party has five places), the rest once it is a raid, nobody twice
    assert sorted(invited) == sorted(names[1:]), invited
    assert g.eval("return IsInRaid()")
    assert w.group and len(w.group["members"]) == 7
    w.assert_no_errors()


@case
def whispers_are_the_addons_tells_now_and_wait_their_turn():
    # part 1's whisper piece (an event made before part 2) is the addon's "tell" now: a line in the tracker, no chat
    # whisper; one GUILD message for every entrant online, one each for a few (at most 4 a second); offline sign-ups
    # get nothing
    w, cs = guild(FIVE)
    g = cs[0]
    occ = g.eval("""
        local d = ns.EventBlocks:Blank('Whispers')
        d.scripts = {
          { id = 'sw', st = '*', x = 0, y = 0, top = { k = 'ev.start', a = {},
            n = { k = 'ch.wh', a = { { k = 'pl.all', a = {} }, 'Hello there' } } } },
          { id = 'sx', st = '*', x = 0, y = 200, top = { k = 'ev.start', a = {},
            n = { k = 'lo.each', a = { { k = 'pl.all', a = {} } },
                  c1 = { k = 'ch.wh', a = { { k = 'ctx', a = { 'each' } }, 'Just you' } } } } } }
        assert(ns.Events:SaveDef(d))
        local occ = ns.Events:Schedule(d.id, GetServerTime() + 10)
        local root = ns.db.events[ns.Guild:GetGuildKey()]
        for i = 1, 3 do
          local k = 'P' .. i .. '-Thunderstrike'
          root.J[occ .. '/' .. k] = { id = occ .. '/' .. k, by = k, rev = 1, o = occ, on = true, at = GetServerTime() + i }
        end
        return occ""")
    w.tick(3)
    for c in cs[1:]:
        assert c.eval("return (ns.Events:SignUp(..., true))", occ), c.name
    w.tick(3)
    n0, a0 = len(w.chat_log), len(w.addon_log)
    assert g.eval("return (ns.EventLive:Start(...))", occ)
    w.tick(0.5)
    first = [e for e in event_msgs(w, a0, "Gina") if e["chat_type"] == "WHISPER"]
    w.tick(30)
    assert not [x for x in w.chat_log[n0:] if x["chat_type"] == "WHISPER"], w.chat_log[n0:]
    for c in cs:
        feed = c.eval_py("local out = {}; for _, e in ipairs(ns.EventLive:MyFeed(...)) do out[#out + 1] = e.text end; "
                         "return out", occ)
        assert sorted(feed) == ["Hello there", "Just you"], (c.name, feed)
    whispers = [e for e in event_msgs(w, a0, "Gina") if e["chat_type"] == "WHISPER"]
    assert sorted(e["target"] for e in whispers) == ["Bert", "Cora", "Dain", "Eve"] and len(first) <= 4, (first, whispers)
    w.assert_no_errors()


@case
def a_run_nobody_hosts_any_more_is_forgotten():
    w, cs = guild(["Gina", "Bert", "Cora", "Eve", "Wade"])
    g, b, c, e, wa = cs
    occ = cup(w, g, [b, c, e])
    for x in (b, c, e, g):
        x.logout()
    w.tick(300, step=0.5)
    assert wa.eval("return ns.EventLive:IsLive(...)", occ)
    w.tick(400, step=0.5)
    assert wa.eval("return ns.EventLive:IsLive(...)", occ) is False
    assert wa.eval_py("return ns.EventLive:GetLiveList()") == []
    w.assert_no_errors()


@case
def demo_mode_and_practice_send_nothing():
    w, cs = guild(["Gina", "Bert"], tick=5)
    g = cs[0]
    n0, a0 = len(w.chat_log), len(w.addon_log)
    out = g.eval_py("""
        ns.Demo:SetEnabled(true)
        local occ = ns.Events:Schedule('edemo1', GetServerTime() + 10)
        local ok, why = ns.EventLive:Start(occ or 'x')
        local run = ns.EventLive:StartPractice(ns.EventBlocks:Starter(), 8)
        for i = 1, 10 do ns.EventLive:PracticeSkip() end
        ns.EventLive:StopPractice()
        return { ok = ok, why = why }""")
    w.tick(30)
    assert out == {"ok": False, "why": "Demo mode is on: nothing runs for real."}, out
    assert len(w.chat_log) == n0
    assert not event_msgs(w, a0)
    assert not [e for e in w.addon_log[a0:] if e["sender"] == K("Gina") and e["prefix"] == "CDLd"]
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Checked and fine
# ------------------------------------------------------------------------------------------------------------------
@case
def duel_lines_with_realms_accents_and_other_languages():
    w, cs = guild(["Gina"], tick=3)
    g = cs[0]
    out = g.eval_py("""
        local L = ns.EventLive
        local function p(t) local a, b = L:ParseDuel(t); return { a or false, b or false } end
        local pat, order = L._Pattern("%2$s ist vor %1$s aus einem Duell geflohen.")
        local a, b = ("Zoë ist vor Bert-Spineshatter aus einem Duell geflohen."):match(pat)
        return { p("Bert-Spineshatter has defeated Zoë in a duel"), p("Zoë has fled from Bert-Spineshatter in a duel"),
                 p("Bert has defeated Gina in a duel."), p("Bert waves at Gina"), { a, b }, order }""")
    assert out[0] == ["Bert-Spineshatter", K("Zoë")], out
    assert out[1] == ["Bert-Spineshatter", K("Zoë")], out
    assert out[2] == [K("Bert"), K("Gina")], out
    assert out[3] == [False, False], out
    assert out[4] == ["Zoë", "Bert-Spineshatter"] and out[5] == [2, 1], out
    w.assert_no_errors()


@case
def duels_outside_an_event_or_between_others_send_nothing():
    w, cs = guild(FIVE)
    g, b, c, d, e = cs
    a0 = len(w.addon_log)
    # no event live: a duel of mine tells nobody
    b.fire("CHAT_MSG_SYSTEM", "Bert has defeated Cora in a duel")
    w.tick(2)
    assert not event_msgs(w, a0)
    occ = cup(w, g, [b, c, e])
    a1 = len(w.addon_log)
    # Dain only saw it (not his duel), and a duel of two who aren't in it
    d.fire("CHAT_MSG_SYSTEM", "Bert has defeated Cora in a duel")
    w.tick(2)
    assert not event_msgs(w, a1, "Dain")
    st0 = state(g, occ)["seq"]
    d.fire("CHAT_MSG_SYSTEM", "Dain has defeated Wade in a duel")
    w.tick(12)
    assert state(g, occ)["seq"] == st0
    w.assert_no_errors()


@case
def library_edges_copies_own_reviews_and_the_size_cap():
    w, cs = guild(["Gina", "Bert"])
    g, b = cs
    did = g.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return d.id")
    w.tick(2)
    # the GM may rank her own event; a copy of a ranked event (and a copy of the copy) starts as a draft
    assert g.eval("return ns.Events:Review(..., true)", did)
    w.tick(2)
    c1 = b.eval("local d = ns.Events:CopyDef(...); ns.Events:SaveDef(d); return d.id", did)
    w.tick(2)
    c2 = g.eval("local d = ns.Events:CopyDef(...); ns.Events:SaveDef(d); return d.id", c1)
    w.tick(2)
    assert [g.eval("return ns.Events:ReviewState(ns.Events:GetDef(...))", x) for x in (did, c1, c2)] == [
        "ranked", "draft", "draft"]
    assert g.eval("return ns.Events:GetDef(...).from", c2) == c1
    # an event too big to share is refused (and not stored)
    out = b.eval_py("""
        local d = ns.Events:NewDef(true)
        local seed = 1
        local function junk()
          local t = {}
          for i = 1, 190 do seed = (seed * 16807) % 2147483647; t[i] = string.char(65 + math.floor(seed / 65536) % 58) end
          return table.concat(t)
        end
        for i = 1, 20 do d.notes[i] = { st = '*', x = 0, y = 0, text = junk() } end
        for i = 1, 75 do
          local top = { k = 'ev.start', a = {} }
          local cur = top
          for j = 1, 6 do cur.n = { k = 'ch.moment', a = { junk() } }; cur = cur.n end
          d.scripts[#d.scripts + 1] = { id = 'j' .. i, st = '*', x = 0, y = 0, top = top }
        end
        local ok = ns.Events:SaveDef(d)
        return { ok, ns.Events:GetDef(d.id) == nil }""")
    assert out == [False, True], out
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
